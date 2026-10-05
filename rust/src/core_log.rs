// Rust 核心日志：Android 上 logcat + 落盘副本双写。
//
// 为什么要有落盘副本：`log` 宏原先只经 `android_logger` 写 logcat，而 Android 应用
// **读不到自己的 logcat**（READ_LOGS 是系统权限），真机上排障等于没有观测面。落盘
// 文件放在 `init` 传入的运行时目录（Dart 侧 `BackendService` 用的是同一个目录），
// 由 Dart 日志页的「Rust」视图读取。
//
// 行格式与 Dart 侧 `app.log` 同形（`[级别] ISO标签: 消息`），Dart 因此可以复用同一个
// 解析器；标签固定为 `core`（冒号无关），模块路径放进消息里，避免被解析截断。
//
// 桌面/测试构建不安装 logger（`install` 只在 Android 分支调用），log 宏保持 no-op。

use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

use log::{Log, Metadata, Record};

/// 落盘文件名（Dart 侧按同名读取）。
pub const LOG_FILE_NAME: &str = "rust.log";
/// 单文件上限，与 Dart 侧 `app.log` 同一预算。
const MAX_BYTES: u64 = 1 << 20;
/// 备份份数。
const MAX_BACKUPS: usize = 1;
/// logcat 标签，与迁移前的 `android_logger` 配置保持一致。
#[cfg(target_os = "android")]
const LOGCAT_TAG: &str = "fqapi_core";

/// 追加写 + 大小轮换的日志文件。
///
/// 独立于全局 logger，因此在主机上也能单测轮换与格式（只有 Android 才装 logger）。
pub struct RotatingFile {
    dir: PathBuf,
    max_bytes: u64,
    max_backups: usize,
    file: Option<File>,
    size: u64,
}

impl RotatingFile {
    pub fn open(dir: &Path, max_bytes: u64, max_backups: usize) -> std::io::Result<Self> {
        fs::create_dir_all(dir)?;
        let path = dir.join(LOG_FILE_NAME);
        let size = fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
        let file = OpenOptions::new().create(true).append(true).open(&path)?;
        Ok(Self {
            dir: dir.to_path_buf(),
            max_bytes,
            max_backups,
            file: Some(file),
            size,
        })
    }

    /// 当前文件路径。
    pub fn path(&self) -> PathBuf {
        self.dir.join(LOG_FILE_NAME)
    }

    /// 追加一行。任何 IO 失败都只丢这一行——日志不能反过来拖垮核心。
    pub fn write_line(&mut self, line: &str) {
        if self.file.is_none() {
            return;
        }
        let bytes = line.len() as u64 + 1;
        if self.size + bytes > self.max_bytes {
            self.rotate();
        }
        if let Some(file) = self.file.as_mut() {
            let written = file.write_all(line.as_bytes()).is_ok() && file.write_all(b"\n").is_ok();
            if written {
                let _ = file.flush();
                self.size += bytes;
            }
        }
    }

    fn backup_path(&self, index: usize) -> PathBuf {
        self.dir.join(format!("{LOG_FILE_NAME}.{index}"))
    }

    fn rotate(&mut self) {
        // 先关句柄再改名：Windows 上被占用的文件改名会失败。
        self.file = None;
        let _ = fs::remove_file(self.backup_path(self.max_backups));
        for index in (1..self.max_backups).rev() {
            let from = self.backup_path(index);
            if from.exists() {
                let _ = fs::rename(&from, self.backup_path(index + 1));
            }
        }
        let current = self.path();
        if current.exists() {
            let _ = fs::rename(&current, self.backup_path(1));
        }
        self.size = 0;
        self.file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&current)
            .ok();
    }
}

/// 全局 logger：文件为主，Android 上再镜像一份到 logcat（保留既有观感）。
pub struct CoreLogger {
    file: Mutex<RotatingFile>,
    #[cfg(target_os = "android")]
    android: android_logger::AndroidLogger,
}

impl CoreLogger {
    pub fn new(file: RotatingFile) -> Self {
        Self {
            file: Mutex::new(file),
            #[cfg(target_os = "android")]
            android: android_logger::AndroidLogger::new(
                android_logger::Config::default().with_tag(LOGCAT_TAG),
            ),
        }
    }

    /// 单条日志的行格式。与 Dart 侧 `app.log` 同形，便于共用解析器。
    pub fn format_line(record: &Record) -> String {
        format!(
            "[{}] {} core: {}: {}",
            level_token(record.level()),
            iso_utc_now(),
            record.target(),
            record.args()
        )
    }
}

impl Log for CoreLogger {
    fn enabled(&self, metadata: &Metadata) -> bool {
        metadata.level() <= log::max_level()
    }

    fn log(&self, record: &Record) {
        if !self.enabled(record.metadata()) {
            return;
        }
        if let Ok(mut file) = self.file.lock() {
            file.write_line(&Self::format_line(record));
        }
        #[cfg(target_os = "android")]
        self.android.log(record);
    }

    fn flush(&self) {
        #[cfg(target_os = "android")]
        self.android.flush();
    }
}

/// 全局 logger 的持有者：`log::set_logger` 要 `&'static dyn Log`，而本 crate 未开
/// `log/alloc`（`set_boxed_logger` 用不了），因此用 `OnceLock` 取静态引用。
static LOGGER: OnceLock<CoreLogger> = OnceLock::new();

/// 安装全局 logger：落盘 + （Android）logcat。已在别处安装过则保持原样。
pub fn install(runtime_dir: &Path) {
    let file = match RotatingFile::open(runtime_dir, MAX_BYTES, MAX_BACKUPS) {
        Ok(file) => file,
        // 落盘不可用时退回 logcat-only，不影响核心启动。
        Err(_) => return,
    };
    let logger = LOGGER.get_or_init(|| CoreLogger::new(file));
    if log::set_logger(logger).is_ok() {
        // 与迁移前的 android_logger 配置同一级别（Info 及以上）。
        log::set_max_level(log::LevelFilter::Info);
    }
}

fn level_token(level: log::Level) -> char {
    match level {
        log::Level::Error => 'E',
        log::Level::Warn => 'W',
        log::Level::Info => 'I',
        log::Level::Debug => 'D',
        log::Level::Trace => 'D',
    }
}

/// `YYYY-MM-DDTHH:MM:SS`（UTC）。`T` 分隔让 Dart 的 `DateTime.tryParse` 与
/// 日志解析正则都能直接吃下（`timeutil` 默认用空格，这里换成 ISO 形态）。
fn iso_utc_now() -> String {
    crate::timeutil::format_unix(crate::timeutil::now_secs()).replacen(' ', "T", 1)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("fqapi-core-log-{}-{tag}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn rotating_file_keeps_backup_and_bounds_current_file() {
        let dir = temp_dir("rotate");
        let mut file = RotatingFile::open(&dir, 60, 1).expect("open");
        for index in 0..12 {
            file.write_line(&format!("line-{index}-xxxxxxxxxxxxxxxx"));
        }
        assert!(file.path().exists(), "current file must exist");
        assert!(
            dir.join(format!("{LOG_FILE_NAME}.1")).exists(),
            "backup must be kept"
        );
        let current = fs::metadata(file.path()).expect("metadata").len();
        assert!(
            current < 60,
            "rotated file must be back under the cap: {current}"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn rotating_file_appends_across_open() {
        let dir = temp_dir("append");
        {
            let mut file = RotatingFile::open(&dir, 1 << 20, 1).expect("open");
            file.write_line("first");
        }
        let mut file = RotatingFile::open(&dir, 1 << 20, 1).expect("reopen");
        file.write_line("second");
        let content = fs::read_to_string(file.path()).expect("read");
        assert!(
            content.contains("first"),
            "reopen must append, not truncate"
        );
        assert!(content.contains("second"));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn line_format_matches_the_dart_parser_shape() {
        // Dart 侧 `_parseHistoryLines` 的正则是 `^\[([DIWE])\] (\S+) ([^:]*): (.*)$`，
        // 这里用等价的手写判定守住同一形态（级别单字符、时间戳无空格、标签无冒号）。
        let record = Record::builder()
            .args(format_args!("boom"))
            .level(log::Level::Warn)
            .target("fqapi_core::upstream")
            .build();
        let line = CoreLogger::format_line(&record);

        // 形态：[W] <iso> core: <target>: <msg>
        assert!(line.starts_with("[W] "), "level token first: {line}");
        let rest = &line[4..];
        let (stamp, tail) = rest.split_once(' ').expect("timestamp then rest");
        assert!(stamp.contains('T'), "ISO timestamp expected: {stamp}");
        assert!(
            !stamp.contains(' '),
            "timestamp must be space-free: {stamp}"
        );
        let (tag, message) = tail.split_once(' ').expect("tag then message");
        assert_eq!(tag, "core:", "tag must be the colon-terminated literal");
        assert!(
            message.starts_with("fqapi_core::upstream: "),
            "target kept in message: {message}"
        );
        assert!(message.ends_with("boom"), "message kept: {message}");
    }
}
