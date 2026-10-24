package com.fqapp.fqapp

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 媒体通知大图的缓存规则（issue #123）。
 *
 * 对应官方 `dn2/i.java`（`PlayNotificationImpl`）的两个静态字段：URL 没变就复用
 * 已解码的 Bitmap，切书则清空重下，迟到的旧结果按 URL 丢弃。
 */
class CoverBitmapCacheTest {
    @Test fun sameUrlReusesTheDecodedBitmap() {
        val cache = CoverBitmapCache<String>()
        assertTrue("首次选封面应当被判为需要加载", cache.select("a.jpg"))
        assertTrue(cache.accept("a.jpg", "bitmap-a"))
        assertEquals("bitmap-a", cache.value)

        // 同一个 URL 再选一次：不重下、不清空。
        assertFalse(cache.select("a.jpg"))
        assertEquals("bitmap-a", cache.value)
    }

    @Test fun switchingBooksDropsTheOldBitmap() {
        val cache = CoverBitmapCache<String>()
        cache.select("a.jpg")
        cache.accept("a.jpg", "bitmap-a")

        assertTrue("换书应当被判为需要重新加载", cache.select("b.jpg"))
        assertNull("换书后旧封面必须立刻失效", cache.value)
    }

    @Test fun aLateResultForThePreviousBookIsDiscarded() {
        val cache = CoverBitmapCache<String>()
        cache.select("a.jpg")
        // 用户在下载途中切到了另一本。
        cache.select("b.jpg")

        assertFalse("旧书的结果必须被丢弃", cache.accept("a.jpg", "bitmap-a"))
        assertNull(cache.value)

        assertTrue(cache.accept("b.jpg", "bitmap-b"))
        assertEquals("bitmap-b", cache.value)
    }

    @Test fun aFailedDownloadLeavesNoCover() {
        val cache = CoverBitmapCache<String>()
        cache.select("a.jpg")
        assertTrue("失败也要收下这份结果，否则会一直重试", cache.accept("a.jpg", null))
        assertNull(cache.value)
    }

    @Test fun emptyUrlClearsTheCover() {
        val cache = CoverBitmapCache<String>()
        cache.select("a.jpg")
        cache.accept("a.jpg", "bitmap-a")

        // 切到没有封面的一集：清空，通知回退成应用图标。
        assertTrue(cache.select(""))
        assertNull(cache.value)
        // 空 URL 之后再选空 URL 不做任何事。
        assertFalse(cache.select(""))
    }
}
