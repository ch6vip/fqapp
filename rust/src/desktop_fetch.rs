// CDN range requests for desktop media sessions: one shared connection pool,
// per-attempt timeouts and retries for transient failures.
use reqwest::{blocking::Client, header};
use std::{
    io::Read,
    sync::{
        atomic::{AtomicBool, Ordering},
        OnceLock,
    },
    thread,
    time::Duration,
};

/// Why a CDN range request failed. Dart maps these onto the Media3 error codes
/// the Android player already reports, so both platforms share one message.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum FetchError {
    Connect,
    Timeout,
    Status(u16),
    /// Malformed or short range response.
    Protocol,
    Cancelled,
}
impl FetchError {
    fn from_reqwest(error: &reqwest::Error) -> Self {
        // Connection resets and other transport failures count as Connect.
        if error.is_timeout() {
            Self::Timeout
        } else {
            Self::Connect
        }
    }
    /// One stalled CDN node or an expired keep-alive connection must not fail
    /// the whole episode; 4xx answers (expired or forbidden URLs) are final.
    pub(crate) fn retryable(self) -> bool {
        match self {
            Self::Connect | Self::Timeout | Self::Protocol => true,
            Self::Status(code) => code == 408 || code == 429 || code >= 500,
            Self::Cancelled => false,
        }
    }
}

/// Media failure reported to Dart: a fixed user-facing message plus the
/// category it came from. Never contains the URL or key.
#[derive(Debug)]
pub(crate) struct OpenError {
    pub(crate) message: &'static str,
    pub(crate) kind: &'static str,
    pub(crate) status: Option<u16>,
}
impl OpenError {
    pub(crate) fn new(message: &'static str, kind: &'static str) -> Self {
        Self {
            message,
            kind,
            status: None,
        }
    }
    pub(crate) fn fetch(error: FetchError) -> Self {
        match error {
            FetchError::Connect => Self::new("媒体连接失败", "connect"),
            FetchError::Timeout | FetchError::Cancelled => Self::new("媒体连接超时", "timeout"),
            FetchError::Status(status) => Self {
                message: "媒体服务器拒绝请求",
                kind: "http",
                status: Some(status),
            },
            FetchError::Protocol => Self::new("媒体服务器不支持分段读取", "range"),
        }
    }
}

pub(crate) const PROBE_TIMEOUT: Duration = Duration::from_secs(6);
pub(crate) const CHUNK_TIMEOUT: Duration = Duration::from_secs(12);
const ATTEMPTS: usize = 3;
const BACKOFF: [Duration; 2] = [Duration::from_millis(300), Duration::from_millis(800)];

/// One pool for every session: switching episodes reuses the CDN connection
/// (and its TLS session) of the previous episode instead of a new handshake.
pub(crate) fn shared_client() -> Option<&'static Client> {
    static CLIENT: OnceLock<Client> = OnceLock::new();
    if let Some(client) = CLIENT.get() {
        return Some(client);
    }
    let _ = rustls::crypto::ring::default_provider().install_default();
    let client = Client::builder()
        .connect_timeout(Duration::from_secs(5))
        .pool_idle_timeout(Duration::from_secs(120))
        .build()
        .ok()?;
    let _ = CLIENT.set(client);
    CLIENT.get()
}

/// Fetches `bytes=start-end` and checks the answer describes exactly that span.
/// Returns the body and the total length from `Content-Range`.
pub(crate) fn fetch_range(
    client: &Client,
    url: &str,
    start: u64,
    end: u64,
    timeout: Duration,
) -> Result<(Vec<u8>, u64), FetchError> {
    fetch_range_checked(client, url, start, end, timeout, None)
}

pub(crate) fn fetch_known_range(
    client: &Client,
    url: &str,
    start: u64,
    end: u64,
    timeout: Duration,
    total: u64,
) -> Result<Vec<u8>, FetchError> {
    fetch_range_checked(client, url, start, end, timeout, Some(total)).map(|(data, _)| data)
}

fn fetch_range_checked(
    client: &Client,
    url: &str,
    start: u64,
    end: u64,
    timeout: Duration,
    known_total: Option<u64>,
) -> Result<(Vec<u8>, u64), FetchError> {
    if start > end || known_total.is_some_and(|total| total == 0 || start >= total) {
        return Err(FetchError::Protocol);
    }
    let response = client
        .get(url)
        .header(header::RANGE, format!("bytes={start}-{end}"))
        .header(header::ACCEPT_ENCODING, "identity")
        .timeout(timeout)
        .send()
        .map_err(|e| FetchError::from_reqwest(&e))?;
    let status = response.status().as_u16();
    if status != 206 {
        return Err(FetchError::Status(status));
    }
    let (actual_start, actual_end, total) = response
        .headers()
        .get(header::CONTENT_RANGE)
        .and_then(|v| v.to_str().ok())
        .and_then(content_range)
        .ok_or(FetchError::Protocol)?;
    let wanted_end = end.min(total - 1);
    if actual_start != start
        || actual_end != wanted_end
        || known_total.is_some_and(|known| known != total)
        || response
            .headers()
            .get(header::CONTENT_ENCODING)
            .is_some_and(|v| v != "identity")
    {
        return Err(FetchError::Protocol);
    }
    let expected = actual_end
        .checked_sub(actual_start)
        .and_then(|length| length.checked_add(1))
        .ok_or(FetchError::Protocol)?;
    let read_limit = expected.checked_add(1).ok_or(FetchError::Protocol)?;
    if usize::try_from(read_limit).is_err() || read_limit > isize::MAX as u64 {
        return Err(FetchError::Protocol);
    }
    let mut data = Vec::new();
    response
        .take(read_limit)
        .read_to_end(&mut data)
        .map_err(|_| FetchError::Timeout)?;
    if data.len() as u64 != expected {
        return Err(FetchError::Protocol);
    }
    Ok((data, total))
}

/// Runs `attempt` until it succeeds, fails for good, or the session closes.
pub(crate) fn with_retries<T>(
    cancelled: &AtomicBool,
    mut attempt: impl FnMut() -> Result<T, FetchError>,
) -> Result<T, FetchError> {
    let mut last = FetchError::Cancelled;
    for round in 0..ATTEMPTS {
        if cancelled.load(Ordering::Acquire) {
            return Err(FetchError::Cancelled);
        }
        match attempt() {
            Ok(value) => {
                return if cancelled.load(Ordering::Acquire) {
                    Err(FetchError::Cancelled)
                } else {
                    Ok(value)
                }
            }
            Err(error) if error.retryable() => last = error,
            Err(error) => return Err(error),
        }
        if let Some(delay) = BACKOFF.get(round) {
            thread::sleep(*delay);
        }
    }
    Err(if cancelled.load(Ordering::Acquire) {
        FetchError::Cancelled
    } else {
        last
    })
}

fn content_range(value: &str) -> Option<(u64, u64, u64)> {
    let (range, total) = value.strip_prefix("bytes ")?.split_once('/')?;
    let (start, end) = range.split_once('-')?;
    let (start, end, total) = (start.parse().ok()?, end.parse().ok()?, total.parse().ok()?);
    (start <= end && end < total).then_some((start, end, total))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::{Read, Write},
        net::TcpListener,
    };

    /// Serves one canned response per connection, in order.
    fn upstream(responses: Vec<&'static str>) -> String {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let url = format!("http://{}/v", listener.local_addr().unwrap());
        thread::spawn(move || {
            for response in responses {
                let (mut socket, _) = listener.accept().unwrap();
                let mut request = Vec::new();
                let mut byte = [0];
                while !request.ends_with(b"\r\n\r\n") && socket.read(&mut byte).unwrap() > 0 {
                    request.push(byte[0]);
                }
                let _ = socket.write_all(response.as_bytes());
            }
        });
        url
    }

    const PARTIAL: &str = "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-0/42\r\nContent-Length: 1\r\nConnection: close\r\n\r\nx";

    #[test]
    fn transient_failures_are_retried() {
        let url = upstream(vec![
            "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            PARTIAL,
        ]);
        let client = shared_client().unwrap();
        let cancelled = AtomicBool::new(false);
        let (data, total) = with_retries(&cancelled, || {
            fetch_range(client, &url, 0, 0, PROBE_TIMEOUT)
        })
        .unwrap();
        assert_eq!((data.as_slice(), total), (&b"x"[..], 42));
    }

    #[test]
    fn forbidden_is_final() {
        let url = upstream(vec![
            "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            PARTIAL,
        ]);
        let client = shared_client().unwrap();
        let cancelled = AtomicBool::new(false);
        let error = with_retries(&cancelled, || {
            fetch_range(client, &url, 0, 0, PROBE_TIMEOUT)
        })
        .unwrap_err();
        assert_eq!(error, FetchError::Status(403));
    }

    #[test]
    fn closed_session_stops_retrying() {
        let cancelled = AtomicBool::new(true);
        let mut calls = 0;
        let result: Result<(), _> = with_retries(&cancelled, || {
            calls += 1;
            Err(FetchError::Timeout)
        });
        assert_eq!((result, calls), (Err(FetchError::Cancelled), 0));
    }

    #[test]
    fn plain_200_is_not_a_range_answer() {
        let url = upstream(vec![
            "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: close\r\n\r\nx",
        ]);
        let client = shared_client().unwrap();
        let cancelled = AtomicBool::new(false);
        let error = with_retries(&cancelled, || {
            fetch_range(client, &url, 0, 0, PROBE_TIMEOUT)
        })
        .unwrap_err();
        assert_eq!(error, FetchError::Status(200));
    }

    #[test]
    fn http_failures_keep_their_status() {
        let reported = OpenError::fetch(FetchError::Status(403));
        assert_eq!((reported.kind, reported.status), ("http", Some(403)));
    }
}
