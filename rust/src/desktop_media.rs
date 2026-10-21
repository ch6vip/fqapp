// The desktop player receives clear bytes over a per-player loopback capability.
// Keys and original URLs stay inside the process; no decrypted movie is written.
use reqwest::{blocking::Client, header};
use serde::Deserialize;
use std::{
    collections::HashMap,
    ffi::{c_char, c_void, CStr, CString},
    fs::File,
    io::{Read, Seek, SeekFrom, Write},
    net::{TcpListener, TcpStream},
    ptr,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, OnceLock,
    },
    thread,
    time::Duration,
};

#[repr(C)]
struct SpError {
    code: i32,
    message: [c_char; 192],
}
#[repr(C)]
struct SpIo {
    user: *mut c_void,
    size: extern "C" fn(*mut c_void) -> i64,
    read_at: extern "C" fn(*mut c_void, u64, *mut u8, usize) -> isize,
    cancel: extern "C" fn(*mut c_void),
    close: extern "C" fn(*mut c_void),
}
unsafe extern "C" {
    fn sp_stream_open(io: *const SpIo, key: *const u8, error: *mut SpError) -> *mut c_void;
    fn sp_stream_read(
        stream: *mut c_void,
        buffer: *mut u8,
        length: usize,
        error: *mut SpError,
    ) -> isize;
    fn sp_stream_seek(stream: *mut c_void, position: i64, error: *mut SpError) -> i64;
    fn sp_stream_size(stream: *const c_void) -> i64;
    fn sp_stream_close(stream: *mut c_void);
}

struct Source {
    file: Option<File>,
    client: Client,
    url: String,
    size: u64,
    cache_start: u64,
    cache: Vec<u8>,
}
impl Source {
    fn open(url: String) -> Result<Self, String> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let client = Client::builder()
            .connect_timeout(Duration::from_secs(8))
            .timeout(Duration::from_secs(15))
            .build()
            .map_err(|_| "无法初始化媒体连接")?;
        let file = if url.starts_with("file:") {
            let path = url::Url::parse(&url)
                .map_err(|_| "离线文件地址无效")?
                .to_file_path()
                .map_err(|_| "离线文件地址无效")?;
            Some(File::open(path).map_err(|_| "离线文件不存在或无法读取")?)
        } else if !url.starts_with("https://") && !url.starts_with("http://") {
            Some(File::open(&url).map_err(|_| "离线文件不存在或无法读取")?)
        } else {
            None
        };
        let size = if let Some(file) = &file {
            file.metadata().map_err(|_| "无法读取文件长度")?.len()
        } else {
            let response = client
                .get(&url)
                .header(header::RANGE, "bytes=0-0")
                .header(header::ACCEPT_ENCODING, "identity")
                .send()
                .map_err(|_| "媒体连接失败或超时")?;
            if response.status() != 206 {
                return Err("媒体服务器不支持分段读取".into());
            }
            let range = response
                .headers()
                .get(header::CONTENT_RANGE)
                .and_then(|v| v.to_str().ok())
                .ok_or("媒体长度未知")?;
            let (start, end, total) = content_range(range).ok_or("媒体范围响应无效")?;
            if start != 0 || end != 0 {
                return Err("媒体范围响应无效".into());
            }
            total
        };
        if size == 0 || size > i64::MAX as u64 {
            return Err("媒体文件长度无效".into());
        }
        Ok(Self {
            file,
            client,
            url,
            size,
            cache_start: 0,
            cache: Vec::new(),
        })
    }
    fn read_at(&mut self, offset: u64, bytes: &mut [u8]) -> Result<usize, ()> {
        if offset >= self.size {
            return Ok(0);
        }
        if let Some(file) = &mut self.file {
            file.seek(SeekFrom::Start(offset)).map_err(|_| ())?;
            return file.read(bytes).map_err(|_| ());
        }
        let cache_end = self.cache_start + self.cache.len() as u64;
        if offset < self.cache_start || offset >= cache_end {
            let end = (offset + 1024 * 1024 - 1).min(self.size - 1);
            let response = self
                .client
                .get(&self.url)
                .header(header::RANGE, format!("bytes={offset}-{end}"))
                .header(header::ACCEPT_ENCODING, "identity")
                .send()
                .map_err(|_| ())?;
            if response.status() != 206 {
                return Err(());
            }
            let actual = response
                .headers()
                .get(header::CONTENT_RANGE)
                .and_then(|v| v.to_str().ok())
                .and_then(content_range)
                .ok_or(())?;
            if actual != (offset, end, self.size)
                || response
                    .headers()
                    .get(header::CONTENT_ENCODING)
                    .is_some_and(|v| v != "identity")
            {
                return Err(());
            }
            let expected = end - offset + 1;
            let mut data = Vec::new();
            response
                .take(expected + 1)
                .read_to_end(&mut data)
                .map_err(|_| ())?;
            if data.len() as u64 != expected {
                return Err(());
            }
            self.cache_start = offset;
            self.cache = data;
        }
        let start = (offset - self.cache_start) as usize;
        let count = bytes.len().min(self.cache.len() - start);
        bytes[..count].copy_from_slice(&self.cache[start..start + count]);
        Ok(count)
    }
}
fn content_range(value: &str) -> Option<(u64, u64, u64)> {
    let (range, total) = value.strip_prefix("bytes ")?.split_once('/')?;
    let (start, end) = range.split_once('-')?;
    Some((start.parse().ok()?, end.parse().ok()?, total.parse().ok()?))
}
extern "C" fn io_size(user: *mut c_void) -> i64 {
    unsafe { (*(user as *mut Source)).size as i64 }
}
extern "C" fn io_read(user: *mut c_void, offset: u64, buffer: *mut u8, length: usize) -> isize {
    std::panic::catch_unwind(|| unsafe {
        let source = &mut *(user as *mut Source);
        source
            .read_at(offset, std::slice::from_raw_parts_mut(buffer, length))
            .map(|n| n as isize)
            .unwrap_or(-1)
    })
    .unwrap_or(-1)
}
extern "C" fn io_cancel(_: *mut c_void) {}
extern "C" fn io_close(user: *mut c_void) {
    unsafe {
        drop(Box::from_raw(user as *mut Source));
    }
}

enum Reader {
    Clear(Box<Source>),
    Encrypted(*mut c_void),
}
// Every operation, including Drop, is protected by the session mutex.
unsafe impl Send for Reader {}
impl Drop for Reader {
    fn drop(&mut self) {
        if let Self::Encrypted(stream) = self {
            unsafe {
                sp_stream_close(*stream);
            }
        }
    }
}
impl Reader {
    fn size(&self) -> u64 {
        match self {
            Self::Clear(source) => source.size,
            Self::Encrypted(stream) => unsafe { sp_stream_size(*stream) as u64 },
        }
    }
    fn read_at(&mut self, offset: u64, bytes: &mut [u8]) -> Result<usize, ()> {
        match self {
            Self::Clear(source) => source.read_at(offset, bytes),
            Self::Encrypted(stream) => unsafe {
                let mut error = SpError {
                    code: 0,
                    message: [0; 192],
                };
                if sp_stream_seek(*stream, offset as i64, &mut error) < 0 {
                    return Err(());
                }
                let n = sp_stream_read(*stream, bytes.as_mut_ptr(), bytes.len(), &mut error);
                if n < 0 {
                    Err(())
                } else {
                    Ok(n as usize)
                }
            },
        }
    }
}
struct Session {
    reader: Mutex<Reader>,
    stop: AtomicBool,
    size: u64,
    authority: String,
    path: String,
}
static SESSIONS: OnceLock<Mutex<HashMap<String, Arc<Session>>>> = OnceLock::new();
fn sessions() -> &'static Mutex<HashMap<String, Arc<Session>>> {
    SESSIONS.get_or_init(Default::default)
}

fn parse_range(header: Option<&str>, size: u64) -> Result<(u64, u64, bool), ()> {
    let Some(value) = header else {
        return Ok((0, size - 1, false));
    };
    let (start, end) = value
        .strip_prefix("bytes=")
        .ok_or(())?
        .split_once('-')
        .ok_or(())?;
    if end.contains(',') {
        return Err(());
    }
    let (start, end) = if start.is_empty() {
        let suffix: u64 = end.parse().map_err(|_| ())?;
        if suffix == 0 {
            return Err(());
        }
        (size.saturating_sub(suffix), size - 1)
    } else {
        (
            start.parse::<u64>().map_err(|_| ())?,
            if end.is_empty() {
                size - 1
            } else {
                end.parse::<u64>().map_err(|_| ())?.min(size - 1)
            },
        )
    };
    if start > end || start >= size {
        return Err(());
    }
    Ok((start, end, true))
}
fn serve(mut socket: TcpStream, session: Arc<Session>) -> std::io::Result<()> {
    // Winsock can inherit FIONBIO from the nonblocking listener. Accepted
    // connections are handled by dedicated workers and must perform blocking
    // reads; otherwise a partially arrived HTTP header is mistaken for EOF.
    socket.set_nonblocking(false)?;
    socket.set_read_timeout(Some(Duration::from_secs(3)))?;
    socket.set_write_timeout(Some(Duration::from_secs(3)))?;
    let mut request = Vec::new();
    while !request.ends_with(b"\r\n\r\n") {
        let mut byte = [0];
        if request.len() >= 16384 || socket.read(&mut byte)? == 0 {
            return Ok(());
        }
        request.push(byte[0]);
    }
    let request = String::from_utf8_lossy(&request);
    let mut lines = request.split("\r\n");
    let first: Vec<_> = lines.next().unwrap_or("").split_whitespace().collect();
    let mut host = None;
    let mut range = None;
    let mut origin = false;
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            match name.to_ascii_lowercase().as_str() {
                "host" => host = Some(value.trim()),
                "range" => range = Some(value.trim()),
                "origin" => origin = true,
                _ => (),
            }
        }
    }
    if first.len() != 3
        || !matches!(first[0], "GET" | "HEAD")
        || first[1] != session.path
        || host != Some(session.authority.as_str())
        || origin
        || session.stop.load(Ordering::Acquire)
    {
        return socket.write_all(
            b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        );
    }
    let (mut position, end, partial) = match parse_range(range, session.size) {
        Ok(range) => range,
        Err(_) => return write!(socket, "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", session.size),
    };
    let status = if partial {
        "206 Partial Content"
    } else {
        "200 OK"
    };
    write!(socket, "HTTP/1.1 {status}\r\nContent-Type: application/octet-stream\r\nAccept-Ranges: bytes\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n", end - position + 1)?;
    if partial {
        write!(
            socket,
            "Content-Range: bytes {position}-{end}/{}\r\n",
            session.size
        )?;
    }
    socket.write_all(b"\r\n")?;
    if first[0] == "HEAD" {
        return Ok(());
    }
    let mut bytes = vec![0; 64 * 1024];
    while position <= end && !session.stop.load(Ordering::Acquire) {
        let count = bytes.len().min((end - position + 1) as usize);
        let n = session
            .reader
            .lock()
            .map_err(|_| std::io::Error::other("media lock"))?
            .read_at(position, &mut bytes[..count])
            .map_err(|_| std::io::Error::other("media read"))?;
        if n == 0 {
            return Err(std::io::Error::other("unexpected media EOF"));
        }
        socket.write_all(&bytes[..n])?;
        position += n as u64;
    }
    Ok(())
}
#[derive(Deserialize)]
struct OpenRequest {
    url: String,
    #[serde(default)]
    key: String,
}
fn open(request: OpenRequest) -> Result<serde_json::Value, String> {
    let source = Box::new(Source::open(request.url)?);
    let reader = if request.key.is_empty() {
        Reader::Clear(source)
    } else {
        let key = hex::decode(&request.key).map_err(|_| "媒体密钥无效")?;
        if key.len() != 16 {
            return Err("媒体密钥无效".into());
        }
        let user = Box::into_raw(source) as *mut c_void;
        let io = SpIo {
            user,
            size: io_size,
            read_at: io_read,
            cancel: io_cancel,
            close: io_close,
        };
        let mut error = SpError {
            code: 0,
            message: [0; 192],
        };
        let stream = unsafe { sp_stream_open(&io, key.as_ptr(), &mut error) };
        if stream.is_null() {
            io_close(user);
            return Err("无法打开加密媒体，请重试或切换清晰度".into());
        }
        Reader::Encrypted(stream)
    };
    let listener = TcpListener::bind(("127.0.0.1", 0)).map_err(|_| "无法打开本机媒体端口")?;
    listener
        .set_nonblocking(true)
        .map_err(|_| "无法初始化媒体端口")?;
    let authority = listener
        .local_addr()
        .map_err(|_| "媒体端口不可用")?
        .to_string();
    let token = hex::encode(rand::random::<[u8; 32]>());
    let path = format!("/media/{token}");
    let url = format!("http://{authority}{path}");
    let session = Arc::new(Session {
        size: reader.size(),
        reader: Mutex::new(reader),
        stop: AtomicBool::new(false),
        authority,
        path,
    });
    sessions()
        .lock()
        .map_err(|_| "媒体会话不可用")?
        .insert(token.clone(), session.clone());
    thread::spawn(move || {
        while !session.stop.load(Ordering::Acquire) {
            match listener.accept() {
                Ok((socket, address)) if address.ip().is_loopback() => {
                    let session = session.clone();
                    thread::spawn(move || {
                        let _ = serve(socket, session);
                    });
                }
                Ok(_) => (),
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(20))
                }
                Err(_) => break,
            }
        }
    });
    Ok(serde_json::json!({"id": token, "url": url}))
}
#[no_mangle]
pub unsafe extern "C" fn fq_desktop_media_open(request: *const c_char) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        if request.is_null() {
            return Err("媒体请求无效".to_string());
        }
        let request: OpenRequest = serde_json::from_slice(CStr::from_ptr(request).to_bytes())
            .map_err(|_| "媒体请求无效".to_string())?;
        open(request)
    })
    .unwrap_or_else(|_| Err("媒体初始化失败".into()));
    let value = match result {
        Ok(value) => value,
        Err(error) => serde_json::json!({"error": error}),
    };
    CString::new(value.to_string())
        .map(CString::into_raw)
        .unwrap_or(ptr::null_mut())
}
#[no_mangle]
pub unsafe extern "C" fn fq_desktop_media_close(id: *const c_char) {
    if id.is_null() {
        return;
    }
    if let Ok(id) = CStr::from_ptr(id).to_str() {
        if let Ok(mut sessions) = sessions().lock() {
            if let Some(session) = sessions.remove(id) {
                session.stop.store(true, Ordering::Release);
            }
        }
    }
}
#[no_mangle]
pub unsafe extern "C" fn fq_desktop_media_free(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn range_contract() {
        assert_eq!(parse_range(None, 100), Ok((0, 99, false)));
        assert_eq!(parse_range(Some("bytes=10-19"), 100), Ok((10, 19, true)));
        assert_eq!(parse_range(Some("bytes=90-"), 100), Ok((90, 99, true)));
        assert_eq!(parse_range(Some("bytes=-8"), 100), Ok((92, 99, true)));
        for bad in ["bytes=100-", "bytes=9-2", "bytes=0-1,4-5", "bytes=-0"] {
            assert!(parse_range(Some(bad), 100).is_err());
        }
    }
}
