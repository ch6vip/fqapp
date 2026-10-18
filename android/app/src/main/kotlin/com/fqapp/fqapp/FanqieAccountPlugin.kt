package com.fqapp.fqapp

import android.annotation.SuppressLint
import android.app.Dialog
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.net.http.SslError
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import android.webkit.CookieManager
import android.webkit.SslErrorHandler
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebStorage
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/** Official login owns credentials and verification. Cookies stay in Android's
 * private WebView store until explicit logout; requests receive an in-memory copy.
 * Presentation-only JavaScript never reads inputs, cookies or captcha answers.
 */
class FanqieAccountPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var binding: ActivityPluginBinding? = null
    private var dialog: Dialog? = null
    private var webView: WebView? = null
    private var pending: MethodChannel.Result? = null
    private var clearing = false
    private val handler = Handler(Looper.getMainLooper())
    private var viewportPoll: Runnable? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "fqapp/fanqie_account")
        channel.setMethodCallHandler(this)
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) { this.binding = binding }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivityForConfigChanges() { finish(null); binding = null }
    override fun onDetachedFromActivity() = onDetachedFromActivityForConfigChanges()
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        finish(null)
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "login" -> showLogin(result, call.argument<Boolean>("dark"), call.argument<Boolean>("eink") == true)
            "cancelLogin" -> { finish(null); result.success(null) }
            "clearSession" -> {
                if (pending != null || clearing) {
                    result.error("LOGIN_BUSY", "登录窗口正在处理", null)
                    return
                }
                clearing = true
                CookieManager.getInstance().removeAllCookies {
                    CookieManager.getInstance().flush()
                    WebStorage.getInstance().deleteAllData()
                    clearing = false
                    result.success(null)
                }
            }
            else -> result.notImplemented()
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun showLogin(result: MethodChannel.Result, preferredDark: Boolean?, eink: Boolean) {
        val activity = binding?.activity
        if (activity == null) { result.error("NO_ACTIVITY", "应用窗口不可用", null); return }
        if (pending != null || clearing) { result.error("LOGIN_BUSY", "登录窗口正在处理", null); return }
        pending = result
        fun dp(value: Int) = (value * activity.resources.displayMetrics.density).toInt()
        val systemDark = activity.resources.configuration.uiMode and
            android.content.res.Configuration.UI_MODE_NIGHT_MASK == android.content.res.Configuration.UI_MODE_NIGHT_YES
        val dark = !eink && (preferredDark ?: systemDark)
        val canvas = Color.parseColor(if (eink) "#FFFFFF" else if (dark) "#151517" else "#FCFAF7")
        val ink = Color.parseColor(if (eink) "#000000" else if (dark) "#F5F1EB" else "#262522")
        val muted = Color.parseColor(if (eink) "#000000" else if (dark) "#A7A39E" else "#706C66")
        val accent = Color.parseColor(if (eink) "#000000" else "#C73D29")
        val layout = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(canvas)
            fitsSystemWindows = true
        }
        val toolbar = LinearLayout(activity).apply {
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(8), dp(4), dp(8), dp(4))
        }
        fun textButton(label: String, action: () -> Unit) = Button(activity).apply {
            text = label; isAllCaps = false; setTextColor(ink); textSize = 13f
            setBackgroundColor(Color.TRANSPARENT)
            minWidth = dp(48); minimumHeight = dp(48)
            setOnClickListener { action() }
        }
        toolbar.addView(textButton("返回") { finish(null) })
        toolbar.addView(TextView(activity).apply {
            text = "番茄官方登录"; textSize = 17f; setTextColor(ink)
            setTypeface(typeface, Typeface.BOLD); gravity = Gravity.CENTER
        }, LinearLayout.LayoutParams(0, dp(48), 1f))
        toolbar.addView(textButton("适应全页") { fitViewport(force = true) })
        layout.addView(toolbar)
        val hint = TextView(activity).apply {
            text = if (sessionCookie() != null) "已保留上次登录，可直接读取书架。验证时会自动缩放。"
                else "登录状态会在本机保留。验证时自动缩放，也可双指放大。"
            setTextColor(muted); textSize = 12f
            setPadding(dp(16), dp(4), dp(16), dp(12))
        }
        layout.addView(hint)
        val progress = ProgressBar(activity, null, android.R.attr.progressBarStyleHorizontal).apply {
            isIndeterminate = true
        }
        layout.addView(progress, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(2)))
        val browser = WebView(activity).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.useWideViewPort = true
            settings.loadWithOverviewMode = true
            settings.setSupportZoom(true)
            settings.builtInZoomControls = true
            settings.displayZoomControls = false
            settings.allowFileAccess = false
            settings.allowContentAccess = false
            settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            settings.cacheMode = WebSettings.LOAD_DEFAULT
            settings.setSupportMultipleWindows(false)
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
                    !allowed(request.url)
                @Deprecated("Used by Android 7 WebView implementations")
                override fun shouldOverrideUrlLoading(view: WebView, url: String): Boolean = !allowed(Uri.parse(url))
                override fun onPageStarted(view: WebView, url: String?, favicon: android.graphics.Bitmap?) {
                    progress.visibility = View.VISIBLE
                }
                override fun onPageFinished(view: WebView, url: String?) {
                    progress.visibility = View.GONE
                    CookieManager.getInstance().flush()
                    startViewportPolling()
                }
                override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) {
                    handler.cancel(); progress.visibility = View.GONE
                    hint.text = "官方页面安全连接失败，请返回后重试。"
                }
            }
        }
        CookieManager.getInstance().apply {
            setAcceptCookie(true)
            setAcceptThirdPartyCookies(browser, false)
        }
        webView = browser
        layout.addView(browser, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        val footer = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(8), dp(16), dp(12))
        }
        footer.addView(Button(activity).apply {
            text = "完成登录，读取书架"; isAllCaps = false; textSize = 15f
            setTextColor(Color.WHITE); minimumHeight = dp(50)
            background = GradientDrawable().apply { setColor(accent); cornerRadius = dp(14).toFloat() }
            setOnClickListener {
                val cookie = sessionCookie()
                if (cookie != null) finish(cookie)
                else hint.text = "请先完成手机号登录和验证，再点击下方按钮。"
            }
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        footer.addView(TextView(activity).apply {
            text = "登录与人机验证请在官方页面内完成"; textSize = 11f
            setTextColor(muted); gravity = Gravity.CENTER; setPadding(0, dp(8), 0, 0)
        })
        layout.addView(footer)
        dialog = Dialog(activity, if (dark) android.R.style.Theme_Material_NoActionBar else
            android.R.style.Theme_Material_Light_NoActionBar).apply {
            setContentView(layout)
            setOnCancelListener { finish(null) }
            show()
            window?.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
            window?.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        }
        browser.loadUrl("https://fanqienovel.com/main/writer/login")
    }

    private fun startViewportPolling() {
        viewportPoll?.let(handler::removeCallbacks)
        val poll = object : Runnable {
            override fun run() {
                if (webView == null || pending == null) return
                fitViewport(force = false)
                handler.postDelayed(this, 650)
            }
        }
        viewportPoll = poll
        handler.post(poll)
    }

    private fun fitViewport(force: Boolean) {
        val browser = webView ?: return
        if (!allowed(Uri.parse(browser.url ?: return))) return
        // Only layout metrics cross this boundary. Never access iframe contents,
        // input values, session storage, cookies or verification responses.
        browser.evaluateJavascript(VIEWPORT_SCRIPT) { raw ->
            if (webView !== browser || pending == null) return@evaluateJavascript
            val metrics = runCatching { JSONObject(raw) }.getOrNull() ?: return@evaluateJavascript
            if (!force && (!metrics.optBoolean("fit") || metrics.optBoolean("editing"))) return@evaluateJavascript
            if (metrics.optBoolean("verification")) {
                (browser.context.getSystemService(android.content.Context.INPUT_METHOD_SERVICE) as? InputMethodManager)
                    ?.hideSoftInputFromWindow(browser.windowToken, 0)
            }
            val factor = metrics.optDouble("factor", 1.0).toFloat()
            if (factor.isFinite() && factor < .98f) browser.zoomBy(factor.coerceIn(.1f, 1f))
            if (force && !metrics.optBoolean("verification")) browser.scrollTo(0, 0)
        }
    }

    private fun finish(cookie: String?) {
        val result = pending
        pending = null
        viewportPoll?.let(handler::removeCallbacks)
        viewportPoll = null
        dialog?.setOnCancelListener(null)
        dialog?.dismiss(); dialog = null
        webView?.apply {
            stopLoading()
            (parent as? ViewGroup)?.removeView(this)
            destroy()
        }
        webView = null
        // Preserve the official session; only clearSession performs logout.
        CookieManager.getInstance().flush()
        result?.success(cookie)
    }

    private fun sessionCookie(): String? {
        val cookie = CookieManager.getInstance().getCookie(OFFICIAL_HOME).orEmpty()
        if (cookie.length > 12 * 1024) return null
        return cookie.takeIf {
            cookie.split(';').any { part ->
                val pair = part.trim().split('=', limit = 2)
                pair.size == 2 && pair[0] in setOf("sessionid", "sessionid_ss", "sid_tt") && pair[1].isNotEmpty()
            }
        }
    }

    private fun allowed(uri: Uri): Boolean {
        val host = uri.host.orEmpty().lowercase()
        return uri.scheme == "https" && uri.userInfo == null &&
            listOf("fanqienovel.com", "snssdk.com", "bytedance.com", "zijieapi.com").any {
                host == it || host.endsWith(".$it")
            }
    }

    companion object {
        private const val OFFICIAL_HOME = "https://fanqienovel.com/"
        private val VIEWPORT_SCRIPT = """
            (() => {
              if (!window.__fqViewport) {
                window.__fqViewport = {sent: 0, seen: 0};
                const editable = el => el instanceof Element &&
                  (el.matches('input,textarea') || el.isContentEditable);
                document.addEventListener('focusin', event => {
                  // Typing supersedes a send click not yet consumed by polling.
                  if (editable(event.target)) window.__fqViewport.seen = window.__fqViewport.sent;
                }, true);
                document.addEventListener('click', event => {
                  if (editable(event.target)) return;
                  const path = event.composedPath ? event.composedPath() : [event.target];
                  const send = path.find(el => el instanceof Element &&
                    /^(发送验证码|获取验证码|重新发送)$/.test((el.textContent || '').replace(/\s+/g, '')));
                  if (!send) return;
                  if (editable(document.activeElement)) document.activeElement.blur();
                  window.__fqViewport.sent++;
                }, true);
              }
              const state = window.__fqViewport;
              const candidates = [...document.querySelectorAll(
                '[id*="captcha"],[class*="captcha"],iframe[src*="captcha"],iframe[src*="verify"],[id*="verify-bar"]')];
              const rects = candidates.map(el => el.getBoundingClientRect())
                .filter(r => r.width > 100 && r.height > 80 && r.bottom > 0 && r.right > 0);
              const width = Math.max(document.documentElement.scrollWidth, document.body ? document.body.scrollWidth : 0,
                ...rects.map(r => r.right + Math.max(0, -r.left)));
              const height = rects.length ? Math.max(...rects.map(r => r.height)) : 0;
              const viewport = window.visualViewport;
              const vw = viewport ? viewport.width : window.innerWidth;
              const vh = viewport ? viewport.height : window.innerHeight;
              const active = document.activeElement;
              const editing = active instanceof Element &&
                (active.matches('input,textarea') || active.isContentEditable);
              // Layout changes and captcha visibility never initiate a fit.
              const fit = state.sent !== state.seen && !editing;
              state.seen = state.sent;
              return {fit, editing, verification: rects.length > 0 || fit,
                factor: Math.min(1, vw / (width + 16), height > 0 ? vh / (height + 24) : 1)};
            })()
        """.trimIndent()
    }
}
