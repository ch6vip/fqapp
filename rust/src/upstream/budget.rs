//! The caller's absolute deadline, shared by nested requests and retries.

use std::future::Future;
use std::time::Duration;

use tokio::time::Instant;

pub(crate) const HTTP_REQUEST_TIMEOUT: Duration = Duration::from_secs(20);

tokio::task_local! {
    static DEADLINE: Instant;
}

pub(crate) async fn within<F: Future>(limit: Duration, work: F) -> Result<F::Output, ()> {
    let deadline = Instant::now() + limit;
    DEADLINE
        .scope(deadline, async {
            let result = tokio::time::timeout_at(deadline, work)
                .await
                .map_err(|_| ())?;
            // CPU work can finish after the deadline without yielding to the timer.
            if Instant::now() >= deadline {
                Err(())
            } else {
                Ok(result)
            }
        })
        .await
}

pub(crate) fn remaining() -> Option<Duration> {
    DEADLINE
        .try_with(|deadline| deadline.saturating_duration_since(Instant::now()))
        .ok()
}

pub(crate) fn cap_timeout(limit: Duration) -> Duration {
    remaining().map_or(limit, |left| left.min(limit))
}

pub(crate) async fn retry_pause(delay: Duration) -> bool {
    if remaining().is_some_and(|left| left <= delay) {
        return false;
    }
    tokio::time::sleep(delay).await;
    !remaining().is_some_and(|left| left.is_zero())
}
