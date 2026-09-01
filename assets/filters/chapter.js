// Chapter content filter — transforms raw API response back to simplified format.
// data: the original API response JSON object (content already decrypted by Go).
// Must return the filtered result.

function filter(data) {
    if (!data || !data.data) return data;
    var d = data.data;

    // ── Case 1: full/v API — {data: {content: "..."}} → {content: "..."}
    if (typeof d.content === 'string' && !d.novel_data && !d.item_infos) {
        return { content: d.content };
    }

    // ── Case 2: Toutiao API — {data: {content, novel_data: {...}}}
    // → {data: {author, book_id, book_name, chapter_title, item_id, next_item_id, thumb_url, content}}
    if (d.novel_data) {
        var nd = d.novel_data;
        return {
            data: {
                author:        nd.author,
                book_id:       nd.book_id,
                book_name:     nd.book_name,
                chapter_title: nd.chapter_title,
                item_id:       nd.item_id,
                next_item_id:  nd.next_item_id,
                thumb_url:     nd.thumb_url,
                content:       d.content
            }
        };
    }

    // ── Case 3: Full API POST — {data: {item_infos: {id: {key, content, title}}}}
    // → {chapters: [{item_id, title, content}]}
    if (d.item_infos) {
        var chapters = [];
        var infos = d.item_infos;
        for (var id in infos) {
            var ch = infos[id];
            if (ch && typeof ch === 'object' && ch.content) {
                chapters.push({
                    item_id: id,
                    title:   ch.title || '',
                    content: ch.content
                });
            }
        }
        return { chapters: chapters };
    }

    // ── Case 4: batch_full/v API — {data: {item_id: {title, content, ...}, ...}}
    // → [{item_id, title, content}] or single {item_id, title, content}
    var batchChapters = [];
    for (var key in d) {
        var ch = d[key];
        if (ch && typeof ch === 'object' && typeof ch.content === 'string') {
            batchChapters.push({
                item_id: key,
                title:   ch.title || '',
                content: ch.content
            });
        }
    }
    if (batchChapters.length === 1) return batchChapters[0];
    if (batchChapters.length > 0)  return batchChapters;

    // Unknown structure — pass through unchanged
    return data;
}
