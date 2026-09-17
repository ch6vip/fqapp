// Note: Storage failures must not stop reading or playback. See
// .agents/notes/implemented/bug-fix/2026-09-17-reviewed-runtime-boundaries.md.
(function (root) {
    "use strict";

    const pending = new Map();
    const maxEntries = 128;
    const maxCharacters = 1024 * 1024;
    let characters = 0;

    function forget(key) {
        if (!pending.has(key)) return;
        characters -= key.length + (pending.get(key)?.length || 0);
        pending.delete(key);
    }

    function remember(key, value) {
        forget(key);
        // An oversized cache entry must not evict all in-page preferences.
        if (key.length + (value?.length || 0) > maxCharacters) value = null;
        if (key.length > maxCharacters) return;
        pending.set(key, value);
        characters += key.length + (value?.length || 0);
        while (pending.size > maxEntries || characters > maxCharacters) {
            forget(pending.keys().next().value);
        }
    }

    root.appStorage = Object.freeze({
        getItem(key) {
            key = String(key);
            if (pending.has(key)) return pending.get(key);
            try { return root.localStorage.getItem(key); }
            catch (_) { return null; }
        },
        setItem(key, value) {
            key = String(key);
            value = String(value);
            try {
                root.localStorage.setItem(key, value);
                forget(key);
            } catch (_) {
                remember(key, value);
            }
        },
        removeItem(key) {
            key = String(key);
            try {
                root.localStorage.removeItem(key);
                forget(key);
            } catch (_) {
                // Shadow a failed persistent deletion for the current page.
                remember(key, null);
            }
        },
        keys() {
            const keys = new Set();
            try {
                const storage = root.localStorage;
                for (let i = 0; i < storage.length; i += 1) {
                    const key = storage.key(i);
                    if (key !== null) keys.add(key);
                }
            } catch (_) { /* Persistence is optional. */ }
            pending.forEach((value, key) => {
                if (value === null) keys.delete(key);
                else keys.add(key);
            });
            return [...keys];
        },
    });
})(window);
