//! Persistent device pool plus the registration flow (`register` submodule).
//!
//! Differences from the Go original (recorded in the migration contract):
//! registration is never performed while the pool lock is held, and saves are
//! version-guarded so an in-flight registration cannot overwrite newer state.

pub mod crypto;
pub mod pool_crypto;
pub mod register;

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;

use register::Registrar;

pub const MIN_POOL_SIZE: usize = 5;
pub const MAX_POOL_SIZE: usize = 20;

/// How often usage counters (`last_used`, `use_count`) are written back.
///
/// Only the write-back of usage hints is debounced; device additions,
/// replacements and removals still commit immediately.
const USAGE_SAVE_INTERVAL: Duration = Duration::from_secs(30);

/// Distinguishes concurrent pool instances in temp file names.
static POOL_INSTANCES: AtomicU64 = AtomicU64::new(0);

/// Owns the final file commit and the retirement decision.
///
/// A retired pool must not be able to replace the device file after the next
/// instance has taken over. The guarantee comes from *one* mechanism: the gate
/// lock is held for the whole write + rename, and `retire()` takes the same
/// lock. Therefore, once `retire()` returns, every commit that had started has
/// finished its rename, and every commit that has not started yet will observe
/// `retired` and refuse. Re-reading `retired` next to the rename would not be
/// enough on its own - the flag and the rename have to be mutually exclusive.
///
/// The commit itself runs in its own task (see `DevicePool::save`): dropping
/// the caller's future detaches it instead of releasing the lock while a
/// blocking file operation is still queued.
struct CommitGate {
    lock: Mutex<()>,
    retired: AtomicBool,
    /// Per-instance counter for temp file names. Two pools in the same process
    /// share a runtime directory, so a fixed `<file>.tmp` would let one
    /// instance's temp file be renamed by the other.
    instance: u64,
    tmp_seq: AtomicU64,
}

impl CommitGate {
    fn new() -> Self {
        CommitGate {
            lock: Mutex::new(()),
            retired: AtomicBool::new(false),
            instance: POOL_INSTANCES.fetch_add(1, Ordering::SeqCst),
            tmp_seq: AtomicU64::new(0),
        }
    }

    fn is_retired(&self) -> bool {
        self.retired.load(Ordering::SeqCst)
    }

    /// Commits `data` as the pool file unless the pool is retired or a newer
    /// snapshot exists.
    ///
    /// `plaintext_without_key` says the payload was written without a pool key
    /// (the documented fallback). Taking the gate is still the first thing this
    /// does, and the encrypted-file backup runs under it, so a backup and its
    /// write are one unit against a racing `retire()`.
    async fn commit(
        &self,
        file: &Path,
        state: &Mutex<PoolState>,
        version: u64,
        data: &[u8],
        plaintext_without_key: bool,
    ) -> Result<(), String> {
        let _guard = self.lock.lock().await;
        if self.is_retired() {
            return Ok(());
        }
        if state.lock().await.version != version {
            // A newer snapshot landed while this one was being serialized.
            return Ok(());
        }
        // pool_crypto's contract is that an encrypted pool file is never
        // silently overwritten with plaintext - that would destroy the device
        // identities with no way back. The pool is deliberately *left in place*
        // on the no-key load path (so a later session that does get the key can
        // still decrypt it), which makes this write the destructive step. The
        // move-aside is self-limiting: once the path is gone the check stops
        // matching and the documented plaintext fallback proceeds.
        if plaintext_without_key {
            back_up_encrypted_pool_file(file).await;
        }
        if let Some(parent) = file.parent() {
            let _ = tokio::fs::create_dir_all(parent).await;
        }
        let tmp = PathBuf::from(format!(
            "{}.{}.{}.tmp",
            file.display(),
            self.instance,
            self.tmp_seq.fetch_add(1, Ordering::SeqCst)
        ));
        if let Err(e) = tokio::fs::write(&tmp, data).await {
            let _ = tokio::fs::remove_file(&tmp).await;
            return Err(e.to_string());
        }
        // The lock is still held, so a concurrent `retire()` is blocked here
        // rather than setting the flag between the check and the rename.
        match tokio::fs::rename(&tmp, file).await {
            Ok(()) => Ok(()),
            Err(e) => {
                let _ = tokio::fs::remove_file(&tmp).await;
                Err(e.to_string())
            }
        }
    }
}

/// Moves an encrypted pool file aside just before a plaintext save would
/// clobber it; a no-op when the file is missing or already plaintext.
async fn back_up_encrypted_pool_file(file: &Path) {
    let Ok(data) = tokio::fs::read(file).await else {
        return;
    };
    if pool_crypto::pool_file_is_encrypted(&data) {
        DevicePool::backup_corrupt_file(file, "is encrypted but the save has no key").await;
    }
}

/// One registered device in the pool.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Device {
    pub device_id: String,
    pub install_id: String,
    pub secret_key: String,
    pub platform: String,
    pub status: String,
    pub created_time: String,
    pub last_used: String,
    pub use_count: i64,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub cdid: String,
    /// Per-installation OpenUDID, generated at registration. It is a device
    /// scoped identifier, so it must come from this device's own registration
    /// rather than a value baked into the source. `serde(default)` keeps pools
    /// written before this field existed loadable; `device_id` stands in until
    /// the device is registered again.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub openudid: String,
}

/// The on-disk JSON shape (mirrors device_pool.json).
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct PoolFile {
    #[serde(default)]
    android: Vec<Device>,
    #[serde(default)]
    last_update: String,
}

#[derive(Debug, Default)]
struct PoolState {
    devices: Vec<Device>,
    version: u64,
    last_update: String,
    /// Usage counters changed since the last snapshot was taken.
    dirty: bool,
    /// When the last snapshot was taken; bounds how often usage-only updates
    /// are written back.
    last_save: Option<Instant>,
}

pub struct DevicePool {
    file: PathBuf,
    /// Shared with the commit task, which re-checks the snapshot version.
    state: Arc<Mutex<PoolState>>,
    registrar: Registrar,
    /// Serializes network registration without holding the pool lock.
    register_lock: Mutex<()>,
    /// Serializes pool-size maintenance while network registration is in flight.
    /// `Arc` so a background top-up can own the lock while it runs.
    maintenance_lock: Arc<Mutex<()>>,
    /// Serializes the final file commit against retirement.
    commit: Arc<CommitGate>,
}

impl DevicePool {
    pub async fn new(file: impl AsRef<Path>) -> Result<Arc<Self>, String> {
        Self::build(file, None).await
    }

    /// Pool whose registration traffic is redirected to a local mock origin.
    pub async fn with_mock_origin(
        file: impl AsRef<Path>,
        origin: impl Into<String>,
    ) -> Result<Arc<Self>, String> {
        Self::build(file, Some(origin.into())).await
    }

    /// Renames `file` to `<file>.corrupt-<unix-seconds>` and logs `reason`.
    /// Best effort: a failed rename leaves the file for the next save to
    /// overwrite.
    async fn backup_corrupt_file(file: &Path, reason: &str) {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let backup = PathBuf::from(format!("{}.corrupt-{stamp}", file.display()));
        match tokio::fs::rename(file, &backup).await {
            Ok(()) => log::warn!("device pool {reason}, backed up to {}", backup.display()),
            Err(rename_err) => {
                log::warn!("device pool {reason}, backup failed: {rename_err}")
            }
        }
    }

    async fn build(
        file: impl AsRef<Path>,
        mock_origin: Option<String>,
    ) -> Result<Arc<Self>, String> {
        let file = file.as_ref().to_path_buf();
        let mut devices = Vec::new();
        if let Ok(data) = tokio::fs::read(&file).await {
            if pool_crypto::pool_file_is_encrypted(&data) {
                // P1-2: encrypted pool file. Decrypt with the provisioned
                // key; an undecryptable file (wrong key, tampering) is
                // backed up per P2-14 and the pool starts empty. With no
                // key provisioned yet (Dart provisions at startup), leave
                // the file untouched and start empty — the pool refills by
                // re-registering, and if a plaintext save follows, that save
                // moves this file aside before writing (see `save`), so the
                // identities stay recoverable instead of being clobbered.
                match pool_crypto::decrypt_pool_file(&data) {
                    Ok(plain) => match serde_json::from_slice::<PoolFile>(&plain) {
                        Ok(pf) => {
                            devices = pf.android;
                        }
                        Err(e) => {
                            Self::backup_corrupt_file(
                                &file,
                                &format!("decrypted pool JSON invalid: {e}"),
                            )
                            .await;
                        }
                    },
                    Err(e) => {
                        if pool_crypto::pool_key().is_some() {
                            Self::backup_corrupt_file(
                                &file,
                                &format!("pool file undecryptable: {e}"),
                            )
                            .await;
                        } else {
                            log::warn!(
                                "device pool file is encrypted but no pool key provisioned; starting empty"
                            );
                        }
                    }
                }
            } else {
                // Legacy plaintext JSON (or garbage). A plaintext file
                // loads normally and is encrypted on the next save once a
                // key is provisioned (migration on save).
                match serde_json::from_slice::<PoolFile>(&data) {
                    Ok(pf) => {
                        devices = pf.android;
                    }
                    Err(e) => {
                        // P2-14: a corrupt pool file (torn write,
                        // truncation, garbage) must never be silently
                        // discarded. Back it up next to the original with
                        // a timestamp, log the parse failure, and start
                        // empty; the pool refills by re-registering. If
                        // the rename itself fails, the corrupt file stays
                        // and the next save overwrites it.
                        Self::backup_corrupt_file(&file, &format!("pool file unparseable: {e}"))
                            .await;
                    }
                }
            }
        }
        devices.truncate(MAX_POOL_SIZE);
        Ok(Arc::new(DevicePool {
            file,
            state: Arc::new(Mutex::new(PoolState {
                devices,
                version: 0,
                last_update: String::new(),
                dirty: false,
                last_save: None,
            })),
            registrar: match mock_origin {
                Some(origin) => Registrar::with_mock_origin(origin)?,
                None => Registrar::new()?,
            },
            register_lock: Mutex::new(()),
            maintenance_lock: Arc::new(Mutex::new(())),
            commit: Arc::new(CommitGate::new()),
        }))
    }

    /// Least-recently-used device, refilling the pool when needed.
    ///
    /// Only an empty pool waits for a registration. A pool that still has a
    /// device hands it out immediately and tops itself up in the background:
    /// one registration is several network round trips plus a deliberate
    /// pacing delay, so a request must not queue behind it while a usable
    /// device exists.
    pub async fn get(self: &Arc<Self>) -> Result<Device, String> {
        let (empty, below_min) = {
            let s = self.state.lock().await;
            (s.devices.is_empty(), s.devices.len() < MIN_POOL_SIZE)
        };
        let mut refill_err = None;
        if empty {
            // Nothing to hand out: this caller waits for at least one device.
            refill_err = self.check_and_refill().await.err();
        } else if below_min {
            self.schedule_refill();
        }

        // Least-recently-used selection, with the emptiness check and the pick
        // inside ONE lock scope. These used to be two separate `state` locks,
        // and the empty-key branch below can drain the pool in between (it
        // `retain`s the selected device away and then re-registers it over a
        // multi-second network round trip), so `devices[0]` could index an
        // empty vec and panic the whole call.
        let mut dev = {
            let mut s = self.state.lock().await;
            s.devices.sort_by(|a, b| a.last_used.cmp(&b.last_used));
            match s.devices.first().cloned() {
                Some(dev) => dev,
                None => {
                    return Err(match refill_err {
                        Some(e) => e,
                        None => "device pool empty".to_string(),
                    });
                }
            }
        };

        if dev.secret_key.is_empty() {
            let _maintenance = self.maintenance_lock.lock().await;
            let current = {
                self.state
                    .lock()
                    .await
                    .devices
                    .iter()
                    .find(|d| d.device_id == dev.device_id)
                    .cloned()
            };
            match current {
                Some(current) if !current.secret_key.is_empty() => dev = current,
                Some(current) => {
                    self.state
                        .lock()
                        .await
                        .devices
                        .retain(|d| d.device_id != current.device_id);
                    // `register()`-level success is not the same as a usable
                    // device: when `registerKey` fails it still returns
                    // `Ok(Device { secret_key: "" })` (register.rs). Handing
                    // that out makes every decrypting request fail with
                    // "bad secret key" and persists the bad device, so mirror
                    // the `replace_failed` guard and fail instead.
                    let new_dev = match self.register_one().await {
                        Ok(device) if !device.secret_key.is_empty() => device,
                        Ok(_) => {
                            self.state.lock().await.devices.push(current);
                            return Err(
                                "re-register empty-key device: replacement has no secret key"
                                    .to_string(),
                            );
                        }
                        Err(error) => {
                            self.state.lock().await.devices.push(current);
                            return Err(format!("re-register empty-key device: {error}"));
                        }
                    };
                    self.state.lock().await.devices.push(new_dev.clone());
                    self.save()
                        .await
                        .map_err(|error| format!("persist re-registered device: {error}"))?;
                    dev = new_dev;
                }
                None => {
                    let mut s = self.state.lock().await;
                    s.devices.sort_by(|a, b| a.last_used.cmp(&b.last_used));
                    dev = s
                        .devices
                        .iter()
                        .find(|device| !device.secret_key.is_empty())
                        .cloned()
                        .ok_or_else(|| "device pool has no usable device".to_string())?;
                }
            }
        }

        let flush_usage = {
            let mut s = self.state.lock().await;
            let updated =
                if let Some(d) = s.devices.iter_mut().find(|d| d.device_id == dev.device_id) {
                    d.last_used = crate::timeutil::now_string();
                    d.use_count += 1;
                    dev = d.clone();
                    true
                } else {
                    false
                };
            if updated {
                s.dirty = true;
            }
            updated && Self::usage_save_due(&s)
        };
        if flush_usage {
            // Usage counters are rotation hints; failing to persist them must
            // not fail the request that just got a device.
            let _ = self.save().await;
        }
        Ok(dev)
    }

    /// Returns the pooled device with the given id without touching rotation
    /// order. Recommendation sessions are bound to the device that opened them.
    pub async fn get_by_id(&self, device_id: &str) -> Result<Device, String> {
        let (found, flush_usage) = {
            let mut s = self.state.lock().await;
            let found = s
                .devices
                .iter_mut()
                .find(|d| d.device_id == device_id)
                .map(|d| {
                    d.last_used = crate::timeutil::now_string();
                    d.use_count += 1;
                    d.clone()
                });
            let flush_usage = if found.is_some() {
                s.dirty = true;
                Self::usage_save_due(&s)
            } else {
                false
            };
            (found, flush_usage)
        };
        match found {
            Some(d) => {
                if flush_usage {
                    let _ = self.save().await;
                }
                Ok(d)
            }
            None => Err(format!("device {device_id} not found in pool")),
        }
    }

    /// Registers a fresh device and swaps it in for a failed one.
    pub async fn replace_failed(&self, device_id: &str) -> Result<Device, String> {
        let _maintenance = self.maintenance_lock.lock().await;
        const MAX_ATTEMPTS: usize = 5;
        for attempt in 1..=MAX_ATTEMPTS {
            match self.register_one().await {
                Ok(nd) if !nd.secret_key.is_empty() => {
                    let previous = {
                        let mut s = self.state.lock().await;
                        match s.devices.iter().position(|d| d.device_id == device_id) {
                            Some(idx) => {
                                let previous = s.devices[idx].clone();
                                s.devices[idx] = nd.clone();
                                Some(previous)
                            }
                            None if s.devices.len() < MAX_POOL_SIZE => {
                                s.devices.push(nd.clone());
                                None
                            }
                            None => {
                                return Err(format!(
                                    "replace device {device_id}: pool is at capacity"
                                ));
                            }
                        }
                    };
                    if let Err(error) = self.save().await {
                        let mut s = self.state.lock().await;
                        match previous {
                            Some(old) => {
                                if let Some(current) = s
                                    .devices
                                    .iter_mut()
                                    .find(|device| device.device_id == nd.device_id)
                                {
                                    *current = old;
                                }
                            }
                            None => s.devices.retain(|device| device.device_id != nd.device_id),
                        }
                        return Err(format!(
                            "replace device {device_id}: failed to persist replacement: {error}"
                        ));
                    }
                    return Ok(nd);
                }
                _ => {
                    let backoff = attempt.min(5);
                    tokio::time::sleep(std::time::Duration::from_secs(backoff as u64)).await;
                }
            }
        }
        Err(format!("replace device {device_id}: exhausted retries"))
    }

    /// Retires the pool: from the moment this returns, no commit belonging to
    /// this instance can replace the device file.
    ///
    /// It waits for a commit that already started (the gate lock is held across
    /// the write and the rename), so `shutdown()` - which awaits this - cannot
    /// return while an old rename is still able to land. Idempotent.
    pub async fn retire(&self) {
        let _guard = self.commit.lock.lock().await;
        self.commit.retired.store(true, Ordering::SeqCst);
    }

    pub fn is_retired(&self) -> bool {
        self.commit.is_retired()
    }

    /// Reports pool counts for the device_pool admin view and /health.
    pub async fn status(&self) -> serde_json::Value {
        let count = self.state.lock().await.devices.len();
        serde_json::json!({
            "android_count": count,
            "min_pool_size": MIN_POOL_SIZE,
            "max_pool_size": MAX_POOL_SIZE,
        })
    }

    pub async fn count(&self) -> usize {
        self.state.lock().await.devices.len()
    }

    /// Manually adds `count` devices to the pool.
    pub async fn refill(&self, count: usize) -> Result<(), String> {
        let _maintenance = self.maintenance_lock.lock().await;
        let room = {
            let s = self.state.lock().await;
            MAX_POOL_SIZE.saturating_sub(s.devices.len()).min(count)
        };
        let mut last_err = None;
        for _ in 0..room {
            match self.register_one().await {
                // Registration can "succeed" with an empty `secret_key` when
                // `registerKey` fails (register.rs). Such a device still takes
                // a pool slot under MAX_POOL_SIZE and counts as healthy in
                // `status()`, while every decrypting request against it fails,
                // so it is reported as an error instead of admitted.
                Ok(dev) if !dev.secret_key.is_empty() => {
                    let mut s = self.state.lock().await;
                    s.devices.push(dev);
                }
                Ok(_) => last_err = Some("registered device has no secret key".to_string()),
                Err(e) => last_err = Some(e),
            }
        }
        if !self.state.lock().await.devices.is_empty() {
            self.save().await?;
        }
        match last_err {
            Some(e) => Err(e),
            None => Ok(()),
        }
    }

    /// Number of registrations needed to bring the pool back to
    /// `MIN_POOL_SIZE`.
    async fn missing_devices(&self) -> usize {
        let s = self.state.lock().await;
        MIN_POOL_SIZE
            .saturating_sub(s.devices.len())
            .min(MAX_POOL_SIZE.saturating_sub(s.devices.len()))
    }

    async fn check_and_refill(&self) -> Result<(), String> {
        // The need check happens before `maintenance_lock` is taken: a healthy
        // pool must not queue behind a slow registration. The count is checked
        // again under the lock because another maintenance path may have
        // topped the pool up in the meantime.
        if self.missing_devices().await == 0 {
            return Ok(());
        }
        let _maintenance = self.maintenance_lock.lock().await;
        self.refill_to_min().await
    }

    /// Queues a top-up while the caller keeps using the device it has.
    ///
    /// Taking `maintenance_lock` with `try_lock_owned` before spawning means
    /// at most one top-up is outstanding, and the lock is released even if the
    /// task unwinds.
    fn schedule_refill(self: &Arc<Self>) {
        let Ok(maintenance) = Arc::clone(&self.maintenance_lock).try_lock_owned() else {
            return;
        };
        let pool = Arc::clone(self);
        tokio::spawn(async move {
            let _maintenance = maintenance;
            if let Err(error) = pool.refill_to_min().await {
                log::warn!("device pool background refill failed: {error}");
            }
        });
    }

    /// Registers devices until the pool reaches `MIN_POOL_SIZE`. Callers must
    /// hold `maintenance_lock`.
    async fn refill_to_min(&self) -> Result<(), String> {
        let need = self.missing_devices().await;
        if need == 0 {
            return Ok(());
        }
        let mut last_err = None;
        for _ in 0..need {
            match self.register_one().await {
                // Registration can "succeed" with an empty `secret_key` when
                // `registerKey` fails (register.rs). Such a device still takes
                // a pool slot under MAX_POOL_SIZE and counts as healthy in
                // `status()`, while every decrypting request against it fails,
                // so it is reported as an error instead of admitted.
                Ok(dev) if !dev.secret_key.is_empty() => {
                    let mut s = self.state.lock().await;
                    s.devices.push(dev);
                }
                Ok(_) => last_err = Some("registered device has no secret key".to_string()),
                Err(e) => last_err = Some(e),
            }
        }
        let has_any = {
            let s = self.state.lock().await;
            !s.devices.is_empty()
        };
        if has_any {
            self.save().await?;
            return Ok(());
        }
        match last_err {
            Some(e) => Err(e),
            None => Ok(()),
        }
    }

    async fn register_one(&self) -> Result<Device, String> {
        let _guard = self.register_lock.lock().await;
        self.registrar.register().await
    }

    /// Whether usage-only updates are due to be written back.
    fn usage_save_due(s: &PoolState) -> bool {
        s.dirty
            && s.last_save
                .is_none_or(|at| at.elapsed() >= USAGE_SAVE_INTERVAL)
    }

    /// Atomic write (temp file + rename), guarded by a version snapshot so an
    /// in-flight registration cannot clobber newer state.
    ///
    /// Only in-memory work happens in the calling future: the snapshot is taken
    /// here and the file commit is handed to a dedicated task. Dropping this
    /// future - a cancelled request, an aborted dispatch - therefore detaches
    /// the commit instead of releasing a lock while `tokio::fs` still has a
    /// blocking write and rename queued. `retire()` synchronizes with that task
    /// through the same gate lock.
    async fn save(&self) -> Result<(), String> {
        if self.is_retired() {
            return Ok(());
        }
        // Clone the state under the lock, but serialize and encrypt outside it:
        // every device pick takes this lock, and a full-pool JSON dump plus
        // AES/HMAC is far more expensive than the pick itself.
        let (version, snapshot) = {
            let mut s = self.state.lock().await;
            let now = crate::timeutil::now_string();
            s.last_update = now.clone();
            s.version += 1;
            s.dirty = false;
            s.last_save = Some(Instant::now());
            (
                s.version,
                PoolFile {
                    android: s.devices.clone(),
                    last_update: now,
                },
            )
        };
        let json = serde_json::to_vec_pretty(&snapshot).map_err(|e| e.to_string())?;
        // P1-2: encrypt the pool file when a key is provisioned; this
        // is also what migrates a legacy plaintext file to encrypted
        // on the first save after provisioning. With no key, keep
        // the old plaintext behavior and warn once per process.
        let (data, plaintext_without_key) = if pool_crypto::pool_key().is_some() {
            (pool_crypto::encrypt_pool_file(&json)?, false)
        } else {
            static WARNED: std::sync::Once = std::sync::Once::new();
            WARNED.call_once(|| {
                log::warn!("saving device pool unencrypted: no pool key provisioned");
            });
            (json, true)
        };

        let gate = Arc::clone(&self.commit);
        let state = Arc::clone(&self.state);
        let file = self.file.clone();
        let handle = tokio::spawn(async move {
            gate.commit(&file, &state, version, &data, plaintext_without_key)
                .await
        });
        match handle.await {
            Ok(result) => result,
            // The commit task is never aborted, but a panic or a cancelled
            // handle must not be reported as a successful save.
            Err(join) if join.is_cancelled() => Ok(()),
            Err(join) => Err(join.to_string()),
        }
    }
}

#[cfg(test)]
mod persistence_tests {
    //! White-box regressions for the persistence ownership rules (F3-R).
    //!
    //! These live next to the implementation because the commit gate is private:
    //! observing that the commit task holds the gate is what makes the ordering
    //! deterministic instead of timing-dependent.

    use super::*;
    use std::sync::mpsc;
    use std::time::{Duration, Instant};

    static TEMP_SEQ: AtomicU64 = AtomicU64::new(0);

    fn temp_dir(tag: &str) -> PathBuf {
        let mut path = std::env::temp_dir();
        path.push(format!(
            "fqapp-pool-{}-{}-{}",
            tag,
            std::process::id(),
            TEMP_SEQ.fetch_add(1, Ordering::SeqCst)
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("temp dir");
        path
    }

    fn pool_json(n: usize) -> String {
        let android = (0..n)
            .map(|i| Device {
                device_id: format!("{i:016}"),
                install_id: format!("{}", 9_000_000_000_000_000_000u64 + i as u64),
                secret_key: format!("{i:032x}"),
                platform: "android".to_string(),
                status: "active".to_string(),
                created_time: "2026-01-01 00:00:00".to_string(),
                last_used: format!("2026-01-01 00:00:0{i}"),
                use_count: i as i64,
                cdid: format!("cdid-{i}"),
                openudid: format!("{i:016}"),
            })
            .collect();
        serde_json::to_string(&PoolFile {
            android,
            last_update: "2026-01-01 00:00:00".to_string(),
        })
        .expect("pool json")
    }

    fn temp_files(dir: &Path) -> Vec<String> {
        std::fs::read_dir(dir)
            .expect("read dir")
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.ends_with(".tmp"))
            .collect()
    }

    /// F3-R: a file commit that has already been handed to the runtime must not
    /// be able to replace the next instance's device state.
    ///
    /// Ordering (the review's reproduction, made deterministic):
    ///  1. occupy the single blocking thread, so every tokio::fs call queues;
    ///  2. start get() - its commit task takes the commit gate and then blocks
    ///     on the queued file write (asserted via the gate, not slept on);
    ///  3. cancel the get() future (the 499 path); this must not release it;
    ///  4. retire() must wait for that commit instead of returning early;
    ///  5. release the file work and await retirement;
    ///  6. the next instance writes its state - and every later old-pool
    ///     operation must leave that state intact.
    #[test]
    fn a_commit_already_handed_to_the_runtime_cannot_replace_the_next_instance() {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .max_blocking_threads(1)
            .enable_all()
            .build()
            .expect("runtime");

        runtime.block_on(async {
            let dir = temp_dir("retire-race");
            let path = dir.join("device_pool.json");
            tokio::fs::write(&path, pool_json(5))
                .await
                .expect("seed pool");
            let pool = DevicePool::new(&path).await.expect("pool");

            // 1. Occupy the only blocking thread.
            let (started_tx, started_rx) = mpsc::channel::<()>();
            let (release_tx, release_rx) = mpsc::channel::<()>();
            let blocker = tokio::task::spawn_blocking(move || {
                let _ = started_tx.send(());
                let _ = release_rx.recv();
            });
            started_rx
                .recv_timeout(Duration::from_secs(5))
                .expect("the blocking thread must be occupied");

            // 2. Start the old save and wait until its commit task owns the gate.
            let old_pool = Arc::clone(&pool);
            let old_get = tokio::spawn(async move { old_pool.get().await });
            let deadline = Instant::now() + Duration::from_secs(5);
            while pool.commit.lock.try_lock().is_ok() {
                assert!(
                    Instant::now() < deadline,
                    "the commit task must take the commit gate"
                );
                tokio::time::sleep(Duration::from_millis(5)).await;
            }

            // 3. Cancel the old request. The detached commit task keeps the gate.
            old_get.abort();
            let _ = old_get.await;

            // 4. Retirement cannot complete while that commit is still pending.
            let retiring = {
                let p = Arc::clone(&pool);
                tokio::spawn(async move { p.retire().await })
            };
            tokio::time::sleep(Duration::from_millis(200)).await;
            assert!(
                !retiring.is_finished(),
                "retire() must wait for the already-submitted commit"
            );

            // 5. Release the queued file work and let retirement settle.
            release_tx.send(()).expect("release latch");
            tokio::time::timeout(Duration::from_secs(5), retiring)
                .await
                .expect("retirement must finish")
                .expect("join retire");
            blocker.await.expect("blocker");
            assert!(pool.is_retired());

            // The commit that had already started was allowed to finish *before*
            // retirement returned - that is the ordering the fix promises.
            let committed = std::fs::read_to_string(&path).expect("pool file");
            let landed: PoolFile = serde_json::from_str(&committed).expect("valid pool json");
            assert_eq!(
                landed.android.len(),
                5,
                "the submitted commit must have completed before retire() returned"
            );

            // 7. The next instance takes the file over.
            let marker = "{\"android\":[],\"last_update\":\"NEW_CORE_MARKER\"}";
            tokio::fs::write(&path, marker)
                .await
                .expect("new instance writes");

            // Every old-pool operation that would otherwise persist is a no-op.
            let device = pool.get().await.expect("the retired pool still reads");
            assert!(!device.device_id.is_empty());
            let _ = pool.get_by_id(&device.device_id).await;
            let _ = pool.refill(0).await;
            pool.retire().await;

            assert_eq!(
                std::fs::read_to_string(&path).expect("pool file"),
                marker,
                "the retired pool must not replace the next instance's state"
            );
            assert!(
                temp_files(&dir).is_empty(),
                "no temporary file may be left behind: {:?}",
                temp_files(&dir)
            );
            let _ = std::fs::remove_dir_all(&dir);
        });
    }

    /// Two pools over one file must never rename each other's temp file.
    #[test]
    fn concurrent_instances_do_not_share_a_temp_file() {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("runtime");

        runtime.block_on(async {
            let dir = temp_dir("tmp-collision");
            let path = dir.join("device_pool.json");
            tokio::fs::write(&path, pool_json(5))
                .await
                .expect("seed pool");
            let first = DevicePool::new(&path).await.expect("first");
            let second = DevicePool::new(&path).await.expect("second");

            let (a, b) = tokio::join!(first.refill(0), second.refill(0));
            a.expect("first save");
            b.expect("second save");

            assert!(
                temp_files(&dir).is_empty(),
                "temp files must be renamed away: {:?}",
                temp_files(&dir)
            );
            let content = std::fs::read_to_string(&path).expect("pool file");
            assert!(
                content.contains("android"),
                "the file stays valid: {content}"
            );
            let _ = std::fs::remove_dir_all(&dir);
        });
    }

    /// P2-14: a corrupt pool file is backed up, not silently discarded.
    #[test]
    fn corrupt_pool_file_is_backed_up_not_silently_discarded() {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("runtime");

        runtime.block_on(async {
            let dir = temp_dir("pool-corrupt");
            let path = dir.join("device_pool.json");
            tokio::fs::write(&path, b"{not json, truncated")
                .await
                .expect("seed corrupt pool");
            let pool = DevicePool::new(&path).await.expect("pool");
            assert_eq!(pool.count().await, 0, "corrupt pool starts empty");

            // The original bytes survive next to the pool file.
            let mut backups = std::fs::read_dir(&dir)
                .expect("read dir")
                .filter_map(|e| e.ok())
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .filter(|n| n.starts_with("device_pool.json.corrupt-"))
                .collect::<Vec<_>>();
            assert_eq!(backups.len(), 1, "exactly one backup: {backups:?}");
            let backup = dir.join(backups.pop().expect("backup"));
            assert_eq!(
                std::fs::read(&backup).expect("backup bytes"),
                b"{not json, truncated"
            );
            assert!(
                !path.exists(),
                "the corrupt file is renamed away, not left in place"
            );
            let _ = std::fs::remove_dir_all(&dir);
        });
    }

    #[test]
    fn loading_and_manual_refill_never_exceed_pool_capacity() {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("runtime");
        runtime.block_on(async {
            let dir = temp_dir("pool-capacity");
            let path = dir.join("device_pool.json");
            tokio::fs::write(&path, pool_json(MAX_POOL_SIZE + 3))
                .await
                .expect("seed oversized pool");
            let pool = DevicePool::new(&path).await.expect("pool");
            assert_eq!(pool.count().await, MAX_POOL_SIZE);

            pool.refill(4).await.expect("refill at capacity is a no-op");
            assert_eq!(pool.count().await, MAX_POOL_SIZE);
            let persisted = tokio::fs::read_to_string(&path).await.expect("saved pool");
            let persisted: PoolFile = serde_json::from_str(&persisted).expect("valid pool");
            assert_eq!(persisted.android.len(), MAX_POOL_SIZE);
            let _ = std::fs::remove_dir_all(&dir);
        });
    }

    /// A pool that still has a device must not queue its picks behind a slow
    /// refill or replacement: those hold `maintenance_lock` across their
    /// network registrations.
    #[tokio::test]
    async fn a_full_pool_hands_out_devices_while_maintenance_is_running() {
        let dir = temp_dir("maintenance-no-wait");
        let path = dir.join("device_pool.json");
        tokio::fs::write(&path, pool_json(MIN_POOL_SIZE))
            .await
            .expect("seed pool");
        let pool = DevicePool::new(&path).await.expect("pool");

        let _maintenance = pool.maintenance_lock.lock().await;
        let device = tokio::time::timeout(Duration::from_secs(2), pool.get())
            .await
            .expect("get() must not wait for maintenance while a device is available")
            .expect("pick");
        assert_eq!(device.device_id, "0000000000000000");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Usage counters are rotation hints, so they are kept in memory and
    /// written back on a timer instead of on every pick; a structural change
    /// still commits them immediately.
    #[tokio::test]
    async fn usage_only_picks_are_debounced_until_a_structural_save() {
        let dir = temp_dir("usage-debounce");
        let path = dir.join("device_pool.json");
        tokio::fs::write(&path, pool_json(MIN_POOL_SIZE))
            .await
            .expect("seed pool");
        let pool = DevicePool::new(&path).await.expect("pool");
        let initial_use_count: i64 = {
            let s = pool.state.lock().await;
            s.devices.iter().map(|d| d.use_count).sum()
        };

        // The first pick has no earlier snapshot to debounce against, so it
        // writes immediately.
        pool.get().await.expect("first pick");
        let version_after_first = pool.state.lock().await.version;

        for _ in 0..4 {
            pool.get().await.expect("pick");
        }
        pool.get_by_id("0000000000000000")
            .await
            .expect("pinned pick");

        {
            let s = pool.state.lock().await;
            assert_eq!(
                s.version, version_after_first,
                "usage-only picks must not write the pool file every time"
            );
            assert!(s.dirty, "the usage updates wait for the debounce window");
            assert_eq!(
                s.devices.iter().map(|d| d.use_count).sum::<i64>(),
                initial_use_count + 6,
                "every pick still updates the in-memory counter"
            );
        }

        // A structural save (a zero-room refill is the cheapest one) commits
        // the pending counters.
        pool.refill(0).await.expect("structural save");
        assert!(
            !pool.state.lock().await.dirty,
            "the save must clear the dirty flag"
        );
        let persisted: PoolFile =
            serde_json::from_str(&tokio::fs::read_to_string(&path).await.expect("pool file"))
                .expect("valid pool json");
        assert_eq!(
            persisted.android.iter().map(|d| d.use_count).sum::<i64>(),
            initial_use_count + 6,
            "the structural save must include the pending usage updates"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
