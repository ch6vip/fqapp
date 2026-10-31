//! Bounded-concurrency download pass for manga chapter images.

use futures::future::join_all;

use super::*;

/// How many chapter images are downloaded, decrypted and written at once.
/// Each image is independent and network-bound, so a small window hides the
/// round-trip latency without opening an unbounded number of connections.
const IMAGE_DOWNLOAD_CONCURRENCY: usize = 4;

/// Maps `items` through `run` in batches of at most `limit`, polling every
/// future in a batch at the same time, and returns the results in input order.
pub(super) async fn bounded_map<T, U, F, Fut>(
    items: &[T],
    limit: usize,
    mut run: F,
) -> Vec<Option<U>>
where
    F: FnMut(&T) -> Fut,
    Fut: std::future::Future<Output = Option<U>>,
{
    let mut out = Vec::with_capacity(items.len());
    for batch in items.chunks(limit.max(1)) {
        out.extend(join_all(batch.iter().map(&mut run)).await);
    }
    out
}

/// Downloads and decrypts `pic_infos` in bounded batches and returns
/// `(picInfos index, content-addressed file name)` for every picture that made
/// it to disk. Batches preserve picInfos order, so the served URLs and the
/// HTML stay stable. Any per-picture failure is skipped, like the serial loop
/// this replaced.
pub(super) async fn download_pictures(
    ctx: &Ctx,
    key_bytes: &[u8],
    pic_infos: &[MangaPicInfo],
) -> Vec<Option<(usize, String)>> {
    let indexed: Vec<(usize, &MangaPicInfo)> = pic_infos.iter().enumerate().collect();
    bounded_map(
        &indexed,
        IMAGE_DOWNLOAD_CONCURRENCY,
        |&(i, pic)| async move {
            if pic.pic_url.is_empty() {
                return None;
            }
            let enc = download_image(ctx, &pic.pic_url).await.ok()?;
            if enc.len() <= 100 {
                return None;
            }
            let dec = decrypt_manga_image(&enc, key_bytes).ok()?;
            let format = detect_image_format(&dec, &pic.pic_url);
            // Note: content-addressed manga files prevent chapter URL basename
            // collisions; see .agents/notes/implemented/bug-fix/2026-09-28-manga-image-collisions.md.
            let name = image_file_name(&dec, &format);
            let fp = std::path::Path::new(&ctx.src_dir).join(&name);
            write_image_once(&fp, &dec).await.ok()?;
            Some((i, name))
        },
    )
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    /// Every batch must have its whole window in flight at once, and the
    /// results must come back in input order (the serial loop did the first
    /// part by accident: one at a time, so it can never reach the window).
    #[tokio::test]
    async fn bounded_map_runs_a_full_window_at_once_and_keeps_the_input_order() {
        let in_flight = Arc::new(AtomicUsize::new(0));
        let max_in_flight = Arc::new(AtomicUsize::new(0));
        let items: Vec<usize> = (0..7).collect();

        let out = bounded_map(&items, IMAGE_DOWNLOAD_CONCURRENCY, |&i| {
            let in_flight = in_flight.clone();
            let max_in_flight = max_in_flight.clone();
            async move {
                let now = in_flight.fetch_add(1, Ordering::SeqCst) + 1;
                max_in_flight.fetch_max(now, Ordering::SeqCst);
                // Let the rest of the batch start before this one finishes.
                for _ in 0..3 {
                    tokio::task::yield_now().await;
                }
                in_flight.fetch_sub(1, Ordering::SeqCst);
                Some(i)
            }
        })
        .await;

        assert_eq!(out, (0..7).map(Some).collect::<Vec<_>>());
        let max = max_in_flight.load(Ordering::SeqCst);
        assert!(
            max >= 2,
            "the download pass must overlap requests instead of running them one at a time"
        );
        assert!(
            max <= IMAGE_DOWNLOAD_CONCURRENCY,
            "more downloads than the configured window ran at once: {max}"
        );
    }

    #[tokio::test]
    async fn bounded_map_skips_failures_without_reordering() {
        let items = [1usize, 2, 3, 4];
        let out = bounded_map(&items, 2, |&i| async move { (i % 2 == 1).then_some(i) }).await;
        assert_eq!(out, vec![Some(1), None, Some(3), None]);
    }
}
