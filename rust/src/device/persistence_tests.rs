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
