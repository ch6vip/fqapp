# R8 keep rules for the JNI contracts and the Flutter embedding.
#
# Both bundled native libraries resolve Java symbols by NAME, so obfuscation
# breaks them at runtime with an UnsatisfiedLinkError -- the build still
# succeeds, which is why these keeps are written out explicitly rather than
# relying on the transitive consumer rules that androidx.annotation ships for
# @Keep. A JNI contract must not depend on an indirect dependency.

# --- liblegacy.so (Go, -buildmode=c-shared) -------------------------------
# Exports, verified by reading the dynamic symbols out of the built library:
#   Java_com_fqapp_fqapp_BackendNative_startBackend
#   Java_com_fqapp_fqapp_BackendNative_stopBackend
#   Java_com_fqapp_fqapp_BackendNative_status
# Note: this class carries no @Keep annotation in the source.
-keep class com.fqapp.fqapp.BackendNative { *; }

# --- libshortplay_crypto.so (native/android/jni_bridge.c) ----------------
# Exports Java_com_example_shortplay_CryptoNative_*. The package name is part
# of the exported symbol, so it must survive obfuscation.
-keep class com.example.shortplay.CryptoNative { *; }

# jni_bridge.c resolves these five static methods on the class handed to
# nativeInit() through GetStaticMethodID, i.e. by the literal strings
# "httpSize", "streamPrepare", "streamConnect", "streamRead", "streamClose".
# Renaming or changing any signature makes nativeInit fail with
# "HttpBridge does not implement the native streaming I/O contract".
-keep class com.example.shortplay.HttpBridge { *; }

# --- generic JNI safety net ---------------------------------------------
# Keeps the class and method name of every native method, which is what the
# JNI naming convention depends on.
-keepclasseswithmembernames class * {
    native <methods>;
}

# --- Flutter plugins registered from MainActivity ------------------------
# These are referenced directly so R8 keeps them alive, but their channel
# handlers are wired at runtime. Keeping the names makes stack traces and
# channel diagnostics readable after obfuscation.
-keep class com.fqapp.fqapp.MainActivity { *; }
-keep class com.fqapp.fqapp.NativePlayerPlugin { *; }
-keep class com.fqapp.fqapp.ReaderDevicePlugin { *; }
-keep class com.fqapp.fqapp.NativeVideoOutput { *; }
-keep class com.fqapp.fqapp.ReaderBrightnessSession { *; }

# --- Flutter embedding ---------------------------------------------------
# The embedding is reached from the generated registrant and from native code
# in libflutter.so; keep it whole, as the Flutter release guidance advises.
-keep class io.flutter.app.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }

# --- optional Play Core integration -------------------------------------
# Flutter's PlayStoreDeferredComponentManager references the Play Core split
# install API, which is only on the classpath when the app opts into deferred
# components. This app ships a single APK and declares none, so the code path
# is unreachable and the references are safe to silence. Without this, R8 fails
# the build with "Missing classes detected" listing 11
# com.google.android.play.core.* types.
-dontwarn com.google.android.play.core.**

# --- attributes ----------------------------------------------------------
# Signature/annotations are needed by reflection in the AndroidX and Media3
# stack; EnclosingMethod/InnerClasses keep Kotlin lambdas and nested types
# consistent in crash reports.
-keepattributes Signature, InnerClasses, EnclosingMethod, *Annotation*
