package dev.noteagent.note_agent

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Only authenticated ciphertext is persisted; its key stays in Android Keystore. */
class SecureCredentials(context: Context, messenger: BinaryMessenger) {
    private val storage = context.getSharedPreferences("encrypted_connection", Context.MODE_PRIVATE)
    private val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private val channel = MethodChannel(messenger, "dev.noteagent/credentials")
    init {
        channel.setMethodCallHandler { call, result ->
            try {
                val slot = call.argument<String>("slot") ?: "default"
                require(Regex("^[a-zA-Z0-9_-]{1,40}$").matches(slot))
                val alias = "dev.noteagent.connection.$slot"
                when (call.method) {
                    "read" -> {
                        val encoded = storage.getString(slot, null)
                        if (encoded == null) result.success(null)
                        else {
                            val bytes = Base64.decode(encoded, Base64.NO_WRAP)
                            require(bytes.size in 28..20000)
                            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                            // An absent key is an error; never replace a lost key during read.
                            val key = keyStore.getKey(alias, null) as? SecretKey ?: error("Keystore unavailable")
                            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
                            cipher.updateAAD(alias.toByteArray(Charsets.UTF_8))
                            result.success(String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8))
                        }
                    }
                    "write" -> {
                        val value = requireNotNull(call.argument<String>("value")).toByteArray(Charsets.UTF_8)
                        require(value.size <= 16384)
                        val key = (keyStore.getKey(alias, null) as? SecretKey) ?: KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
                            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                                .setKeySize(256).setRandomizedEncryptionRequired(true).build())
                            generateKey()
                        }
                        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                        cipher.init(Cipher.ENCRYPT_MODE, key)
                        cipher.updateAAD(alias.toByteArray(Charsets.UTF_8))
                        val sealed = cipher.iv + cipher.doFinal(value)
                        check(storage.edit().putString(slot, Base64.encodeToString(sealed, Base64.NO_WRAP)).commit())
                        result.success(null)
                    }
                    "delete" -> {
                        check(storage.edit().remove(slot).commit())
                        if (keyStore.containsAlias(alias)) keyStore.deleteEntry(alias)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                result.error("secure_store", "系统安全存储暂时不可用，请解锁设备后重试。", null)
            }
        }
    }
}
