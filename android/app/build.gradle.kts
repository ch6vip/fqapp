import java.io.DataInputStream
import java.io.IOException

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.fqapp.fqapp"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

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
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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

// Both libraries are external build inputs. Validate them only when Android
// native libraries are assembled, so pure JVM tests can run in a clean checkout.
val verifyRequiredNativeLibraries = tasks.register("verifyRequiredNativeLibraries") {
    group = "verification"
    description = "Checks the required Android ARM64 JNI libraries before packaging."
    val nativeFiles = listOf("liblegacy.so", "libshortplay_crypto.so").map { name ->
        layout.projectDirectory.file("src/main/jniLibs/arm64-v8a/$name").asFile
    }
    // Optional inputs let the task report missing files with setup guidance,
    // instead of Gradle failing input validation before our check can run.
    inputs.files(nativeFiles).withPropertyName("requiredNativeLibraries").optional()
    doLast {
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
                    "build_backend -Jni/--jni builds liblegacy.so; " +
                    "libshortplay_crypto.so must be provided separately."
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
