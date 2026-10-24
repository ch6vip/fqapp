package com.fqapp.fqapp

/**
 * 媒体通知大图的单条缓存：只记住「当前这一张封面」。
 *
 * 官方 `dn2/i.java`（`PlayNotificationImpl`）用两个静态字段做同一件事——`f` 记
 * 封面 URL、`g` 记解码好的 Bitmap：URL 没变就复用，变了先清空再异步下载，迟到的
 * 旧结果按 URL 丢弃，免得切书后闪回上一本的封面。
 *
 * 抽成独立类是为了能在 JVM 单测里验证「同 URL 复用 / 换书丢弃迟到结果」这两条
 * 规则，不必把 Bitmap 拖进 Robolectric。
 */
internal class CoverBitmapCache<T> {
    var url: String? = null
        private set

    var value: T? = null
        private set

    /**
     * 宣告「现在要显示的封面是 [candidate]」。
     *
     * 返回 true 表示缓存被判失效（URL 变了），调用方应当重新加载。
     */
    fun select(candidate: String): Boolean {
        if (candidate == url) return false
        url = candidate
        value = null
        return true
    }

    /**
     * 收下异步加载的结果。返回 true 表示这份结果与当前封面一致、已经采纳；
     * false 表示加载期间又换了书，这份结果必须丢掉。
     */
    fun accept(candidate: String, bitmap: T?): Boolean {
        if (candidate != url) return false
        value = bitmap
        return true
    }
}
