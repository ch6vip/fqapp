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
        // The bundled Go JNI backend is currently built for arm64 only. An
        // explicit filter prevents installing an APK on an ABI where the
        // native backend cannot start and Process.start is blocked by SELinux.
        ndk {
            abiFilters += setOf("arm64-v8a")
        }
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

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.mockito:mockito-core:5.23.0")
}

flutter {
    source = "../.."
}

// The Go library is the only external native build input. The crypto library
// is compiled from native/ by externalNativeBuild. Keep this check at packaging
// time so pure JVM tests can still run without the Go backend artifact.
val verifyRequiredNativeLibraries = tasks.register("verifyRequiredNativeLibraries") {
    group = "verification"
    description = "Checks the external Android ARM64 Go JNI library before packaging."
    val nativeFiles = listOf("liblegacy.so").map { name ->
        layout.projectDirectory.file("src/main/jniLibs/arm64-v8a/$name").asFile
    }
    // Optional inputs let the task report missing files with setup guidance,
    // instead of Gradle failing input validation before our check can run.
    inputs.files(nativeFiles).withPropertyName("requiredNativeLibraries").optional()
    doLast {
        val legacyCrypto = layout.projectDirectory.file(
            "src/main/jniLibs/arm64-v8a/libshortplay_crypto.so"
        ).asFile
        if (legacyCrypto.exists()) {
            throw GradleException(
                "Remove the legacy prebuilt crypto library from jniLibs before packaging: " +
                    legacyCrypto.path +
                    ". Keep a backup outside jniLibs; native/ now builds this library automatically."
            )
        }
        val failures = nativeFiles.mapNotNull { library ->
            when {
                !library.isFile -> "${library.name}: missing (${library.path})"
                library.length() == 0L -> "${library.name}: empty file"
                library.length() < 64L -> "${library.name}: truncated ELF64 header"
                else -> {
                    try {
                        val header = ByteArray(64)
                        DataInputStream(library.inputStream()).use { it.readFully(header) }
                        fun byteAt(index: Int) = header[index].toInt() and 0xff
                        fun shortAt(index: Int) = byteAt(index) or (byteAt(index + 1) shl 8)
                        val compatible = byteAt(0) == 0x7f &&
                            byteAt(1) == 'E'.code && byteAt(2) == 'L'.code && byteAt(3) == 'F'.code &&
                            byteAt(4) == 2 && byteAt(5) == 1 && byteAt(6) == 1 &&
                            shortAt(16) == 3 && shortAt(18) == 183
                        if (compatible) null else
                            "${library.name}: expected an ELF64 little-endian AArch64 shared object"
                    } catch (error: IOException) {
                        "${library.name}: cannot read ELF header (${error.message})"
                    }
                }
            }
        }
        if (failures.isNotEmpty()) {
            throw GradleException(
                "Required Android native libraries are missing or incompatible:\n" +
                    failures.joinToString("\n") +
                    "\nSee the native library setup in the repository README.md. " +
                    "build_backend -Jni/--jni builds liblegacy.so. " +
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

// Flutter's generated asset directory bypasses androidResources' ignore
// pattern. Strip the desktop-only executable from the generated Android
// bundle before Flutter copies it into AGP's merged-assets directory. The
// source asset remains available to Windows/Linux/macOS builds.
listOf("Debug", "Profile", "Release").forEach { variant ->
    val variantDirectory = variant.lowercase()
    val stripTask = tasks.register("strip${variant}StandaloneBackend") {
        dependsOn("compileFlutterBuild$variant")
        outputs.upToDateWhen { false }
        doLast {
            delete(
                layout.buildDirectory.file(
                    "intermediates/flutter/$variantDirectory/flutter_assets/assets/bin/"
                )
            )
        }
    }
    tasks.configureEach {
        if (name == "copyFlutterAssets$variant") {
            dependsOn(stripTask)
        }
    }
}
