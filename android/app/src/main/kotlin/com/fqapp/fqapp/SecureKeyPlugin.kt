package com.fqapp.fqapp

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * 本机密钥库（Android）。
 *
 * 取代 `flutter_secure_storage`：它把 `win32` 钉在 5.x，挡住了
 * `wakelock_plus` / `package_info_plus` 的 Built-in Kotlin 版本（#205）。
 *
 * 实现要点：
 * - AES-256 密钥由 AndroidKeyStore 生成且不可导出，只有 Keystore 能使用；
 * - 每次写入用 GCM 随机 IV，密文以 `Base64(IV || ciphertext)` 存在应用私有
 *   SharedPreferences；
 * - 条目名作为 AAD，密文被搬到别的 key 名下会直接解密失败，不会串值；
 * - 不使用 `setUserAuthenticationRequired(true)`：朗读/后台播放期间不能弹指纹，
 *   且用户改锁屏密码不应让整个书库失联；
 * - 任何 Keystore 异常都回报错误，由 Dart 侧按失败处理（fail closed），绝不
 *   回落明文。
 */
class SecureKeyPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }

    override fun onMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val name = call.argument<String>("key")
        if (name.isNullOrEmpty()) {
            result.error(ERROR, "缺少 key", null)
            return
        }
        when (call.method) {
            "read" -> {
                submit(result) { read(name) }
            }

            "write" -> {
                val value = call.argument<String>("value")
                if (value == null) {
                    result.error(ERROR, "缺少 value", null)
                    return
                }
                submit(result) {
                    write(name, value)
                    null
                }
            }

            "delete" -> {
                submit(result) {
                    delete(name)
                    null
                }
            }

            else -> {
                result.notImplemented()
            }
        }
    }

    /** Crypto runs off the platform thread; results still arrive on it. */
    private fun submit(
        result: MethodChannel.Result,
        body: () -> String?,
    ) {
        worker.execute {
            try {
                val value: String? = body()
                main.post { result.success(value) }
            } catch (error: Throwable) {
                val message = error.message ?: error.javaClass.simpleName
                // Keystore failures can be Errors on some OEM builds; catching
                // Throwable keeps a wedged key from killing the process.
                main.post { result.error(ERROR, message, null) }
            }
        }
    }

    private fun read(name: String): String? {
        val encoded = preferences().getString(name, null) ?: return null
        return decrypt(name, encoded)
    }

    private fun write(
        name: String,
        value: String,
    ) {
        val committed =
            preferences()
                .edit()
                .putString(name, encrypt(name, value))
                .commit()
        if (!committed) throw IllegalStateException("密钥写入失败")
    }

    private fun delete(name: String) {
        preferences().edit().remove(name).commit()
    }

    private fun preferences() = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    private fun encrypt(
        name: String,
        value: String,
    ): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        cipher.updateAAD(name.toByteArray(Charsets.UTF_8))
        val ciphertext = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val iv = cipher.iv
        val blob = ByteArray(iv.size + ciphertext.size)
        System.arraycopy(iv, 0, blob, 0, iv.size)
        System.arraycopy(ciphertext, 0, blob, iv.size, ciphertext.size)
        return Base64.encodeToString(blob, Base64.NO_WRAP)
    }

    private fun decrypt(
        name: String,
        encoded: String,
    ): String {
        val blob = Base64.decode(encoded, Base64.NO_WRAP)
        if (blob.size <= IV_BYTES) throw IllegalStateException("密钥条目损坏")
        val iv = blob.copyOfRange(0, IV_BYTES)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(TAG_BITS, iv))
        cipher.updateAAD(name.toByteArray(Charsets.UTF_8))
        return String(cipher.doFinal(blob.copyOfRange(IV_BYTES, blob.size)), Charsets.UTF_8)
    }

    /**
     * Keystore 里的 AES 密钥，首次使用时创建。`getEntry` 返回 null 说明应用数据被
     * 清过或系统删除了密钥：此时新建密钥会让旧密文解不开，Dart 侧按“密钥丢失”
     * 处理（`EncryptedHive` 会隔离旧箱文件而不是删除）。
     */
    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        val existing = keyStore.getEntry(ALIAS, null)
        if (existing is KeyStore.SecretKeyEntry) return existing.secretKey
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec
                .Builder(
                    ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private companion object {
        const val CHANNEL = "fqapp/secure_keys"
        const val ERROR = "KEYSTORE"
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val ALIAS = "fqapp_secure_keys_v1"
        const val PREFERENCES = "fqapp_secure_keys"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
        const val TAG_BITS = 128
    }
}
