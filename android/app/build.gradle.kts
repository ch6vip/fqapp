import java.io.DataInputStream
import java.io.IOException
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing material is deliberately optional: without it the release
// build still succeeds but produces an UNSIGNED package, so the task stays
// usable for someone who only wants to inspect the build. What must never
// happen is a release silently signed with the public debug key, so the
// expected certificate is pinned in CI as RELEASE_SIGNER_SHA256 instead.
//
// Local builds read android/keystore.properties, which is git-ignored and kept
// outside version control. CI supplies the same four values as environment
// variables. See docs/release-signing.md.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("keystore.properties")
    if (file.isFile) file.inputStream().use { load(it) }
}

fun signingValue(key: String, vararg environmentNames: String): String? =
    keystoreProperties.getProperty(key)?.takeIf { it.isNotBlank() }
        ?: environmentNames.firstNotNullOfOrNull { name ->
            System.getenv(name)?.takeIf { it.isNotBlank() }
        }

val releaseStoreFile = signingValue("storeFile", "RELEASE_KEYSTORE_FILE")
val releaseStorePassword = signingValue("storePassword", "RELEASE_STORE_PASSWORD")
val releaseKeyAlias = signingValue("keyAlias", "RELEASE_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "RELEASE_KEY_PASSWORD")
val hasReleaseSigning = listOf(
    releaseStoreFile,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { it != null }

android {
    namespace = "com.fqapp.fqapp"
    compileSdk = flutter.compileSdkVersion
    // Compile the in-repository crypto core with the NDK's 16 KiB support.
    ndkVersion = "28.2.13676358"

    externalNativeBuild {
        cmake {
            path = file("../../native/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.fqapp.fqapp"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // No ndk.abiFilters here on purpose: `flutter build apk
        // --split-per-abi` makes the Flutter Gradle plugin configure AGP
        // splits, and AGP rejects abiFilters whenever splits are set
        // ("abiFilters cannot be present when splits abi filters are set").
        // The split APKs therefore contain exactly the ABIs Flutter was
        // asked to build (--target-platform android-arm,android-arm64).
        // The guards against a backend-less slice are the packaging check
        // below (both libfqapi_core.so files must exist and match their
        // ABI) and scripts/verify_android_apk.py --abi, which rejects any
        // unexpected ABI in the APK. Always build with the documented
        // split command; a plain fat `flutter build apk` would include an
        // x86_64 slice with no Rust backend.
        //
        // NOTE: do not re-add abiFilters to "restrict" the build. It breaks
        // every split build at configuration time.
        externalNativeBuild {
            cmake {
                targets += "shortplay_crypto"
            }
        }
    }

    signingConfigs {
        getByName("debug") {
            // CI supplies an absolute path instead of relying on the runner's
            // Android user-directory defaults for debug.keystore.
            providers.environmentVariable("FQAPP_DEBUG_KEYSTORE").orNull?.let { keystorePath ->
                storeFile = file(keystorePath)
            }
        }
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
                // minSdk is 24, so V2 alone installs on every supported device;
                // V1 stays enabled because some OEM installers on Android 7
                // still verify it.
                enableV1Signing = true
                enableV2Signing = true
            }
        }
    }

    buildTypes {
        debug {
            // Opt-in local runs may coexist with an installed release whose
            // signing certificate cannot be replaced by the debug key.
            val debugSuffix = providers.gradleProperty("fqappDebugApplicationIdSuffix")
                .orElse(providers.environmentVariable("FQAPP_DEBUG_APPLICATION_ID_SUFFIX"))
                .orNull
            if (debugSuffix == ".debug") {
                applicationIdSuffix = ".debug"
            }
        }
        release {
            // The release APK carries its own signing identity. Debug builds
            // keep the debug key so `flutter run` and overwrite-installing a
            // local test build keep working. A package signed by the older test
            // key cannot be overwritten by these -- it must be uninstalled.
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // OkHttp powers HttpBridge.httpRange, the range fetcher the C crypto
    // core calls back into for streaming CENC decrypt.
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // Media3 ExoPlayer — NativePlayerPlugin host for short-drama playback.
    val media3Version = "1.4.1"
    implementation("androidx.media3:media3-exoplayer:$media3Version")
    implementation("androidx.media3:media3-common:$media3Version")
    implementation("androidx.media3:media3-datasource:$media3Version")

    // MediaStyle + MediaSessionCompat for the listen-mode foreground notification.
    // Without a media session the notification is a plain one: on Android 12+ its
    // action buttons stay hidden until the user expands it, and the app never shows
    // up in the system media controls (Quick Settings card, lock screen, headset keys).
    implementation("androidx.media:media:1.7.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.mockito:mockito-core:5.23.0")
}

flutter {
    source = "../.."
}

// The Rust core library is the only external native build input. The crypto
// library is compiled from native/ by externalNativeBuild. Keep this check at
// packaging time so pure JVM tests can still run without the Rust artifact
// (scripts/build_rust_backend.ps1 / .sh produce it).
val verifyRequiredNativeLibraries = tasks.register("verifyRequiredNativeLibraries") {
    group = "verification"
    description = "Checks the external Android Rust core libraries (ARM64 + ARMv7) before packaging."
    // ABI directory -> (ELF class byte, e_machine). arm64-v8a is ELF64/AArch64
    // (class 2, machine 183); armeabi-v7a is ELF32/ARM (class 1, machine 40).
    val nativeLibraries = listOf(
        Triple("arm64-v8a", 2, 183),
        Triple("armeabi-v7a", 1, 40),
    )
    val nativeFiles = nativeLibraries.map { (abi, _, _) ->
        layout.projectDirectory.file("src/main/jniLibs/$abi/libfqapi_core.so").asFile
    }
    // Optional inputs let the task report missing files with setup guidance,
    // instead of Gradle failing input validation before our check can run.
    inputs.files(nativeFiles).withPropertyName("requiredNativeLibraries").optional()
    doLast {
        // The legacy prebuilt crypto library must not come back in either ABI
        // directory: native/ now builds it automatically for every ABI.
        for ((abi, _, _) in nativeLibraries) {
            val legacyCrypto = layout.projectDirectory.file(
                "src/main/jniLibs/$abi/libshortplay_crypto.so"
            ).asFile
            if (legacyCrypto.exists()) {
                throw GradleException(
                    "Remove the legacy prebuilt crypto library from jniLibs before packaging: " +
                        legacyCrypto.path +
                        ". Keep a backup outside jniLibs; native/ now builds this library automatically."
                )
            }
        }
        val failures = nativeLibraries.mapIndexedNotNull { index, (abi, elfClass, machine) ->
            val library = nativeFiles[index]
            when {
                !library.isFile -> "${library.name} ($abi): missing (${library.path})"
                library.length() == 0L -> "${library.name} ($abi): empty file"
                library.length() < 64L -> "${library.name} ($abi): truncated ELF header"
                else -> {
                    try {
                        val header = ByteArray(64)
                        DataInputStream(library.inputStream()).use { it.readFully(header) }
                        fun byteAt(index: Int) = header[index].toInt() and 0xff
                        fun shortAt(index: Int) = byteAt(index) or (byteAt(index + 1) shl 8)
                        val compatible = byteAt(0) == 0x7f &&
                            byteAt(1) == 'E'.code && byteAt(2) == 'L'.code && byteAt(3) == 'F'.code &&
                            byteAt(4) == elfClass && byteAt(5) == 1 && byteAt(6) == 1 &&
                            shortAt(16) == 3 && shortAt(18) == machine
                        if (compatible) null else
                            "${library.name} ($abi): expected an " +
                                (if (elfClass == 2) "ELF64 little-endian AArch64" else "ELF32 little-endian ARM") +
                                " shared object"
                    } catch (error: IOException) {
                        "${library.name} ($abi): cannot read ELF header (${error.message})"
                    }
                }
            }
        }
        if (failures.isNotEmpty()) {
            throw GradleException(
                "Required Android native libraries are missing or incompatible:\n" +
                    failures.joinToString("\n") +
                    "\nSee the native library setup in the repository README.md. " +
                    "scripts/build_rust_backend.ps1 / .sh build libfqapi_core.so. " +
                    "The crypto library is built automatically from native/."
            )
        }
    }
}

tasks.configureEach {
    if (name.startsWith("merge") && name.endsWith("NativeLibs")) {
        dependsOn(verifyRequiredNativeLibraries)
    }
}

// NOTE: the Rust core runs in-process over flutter_rust_bridge, so there is no
// standalone backend executable to strip from the Flutter asset bundle anymore.
// The Android packaging path only needs jniLibs (libfqapi_core.so) plus the
// crypto library built from native/.
