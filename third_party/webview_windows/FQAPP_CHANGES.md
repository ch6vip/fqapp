Based on webview_windows 0.4.0, copyright jnschulze and contributors (see LICENSE).

The local fork adds getFanqieCookies, a fixed-origin WebView2 cookie-manager
operation for https://fanqienovel.com/ only. It includes HttpOnly cookies so the
read-only account importer can use the official login session without reading
password fields or requesting credentials from JavaScript. The caller validates
the domain/session and keeps the returned cookie only in memory. This is not a
general browser-cookie export API. Upstream's normal APIs are unchanged.

The Windows build uses standard C++20 coroutines instead of MSVC /await, which
selects the retired coroutine TS and fails with Visual Studio 2026.
