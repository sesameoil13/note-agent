package dev.noteagent.note_agent

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val preferences by lazy { getSharedPreferences("note_workspace", MODE_PRIVATE) }
    private val io = Executors.newSingleThreadExecutor()
    private var pendingPicker: MethodChannel.Result? = null
    private val readWrite = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.noteagent/workspace")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "chooseLocation" -> chooseLocation(result)
                    "openInObsidian" -> openInObsidian(call, result)
                    else -> io.execute {
                        try {
                            val value: Any? = when (call.method) {
                                "restoreLocation" -> location()
                                "vaultExists" -> vault(call).exists(path(call))
                                "vaultReadText" -> vault(call).readText(path(call))
                                "vaultPublishText" -> {
                                    vault(call).publishText(path(call), text(call), operation(call)); null
                                }
                                "vaultListNotePaths" -> vault(call).listNotePaths()
                                "vaultReplaceText" -> {
                                    vault(call).replaceText(path(call), expected(call), text(call), operation(call)); null
                                }
                                "vaultDeleteText" -> { vault(call).deleteText(path(call), expected(call)); null }
                                else -> { runOnUiThread { result.notImplemented() }; return@execute }
                            }
                            runOnUiThread { result.success(value) }
                        } catch (error: Exception) {
                            runOnUiThread {
                                result.error("directory_access", error.message ?: "笔记库授权已失效，请重新选择；原文已保留。", null)
                            }
                        }
                    }
                }
            }
    }

    override fun onDestroy() {
        io.shutdown()
        super.onDestroy()
    }

    private fun path(call: MethodCall) = requireNotNull(call.argument<String>("relativePath"))
    private fun text(call: MethodCall) = requireNotNull(call.argument<String>("text"))
    private fun expected(call: MethodCall) = requireNotNull(call.argument<String>("expectedText"))
    private fun operation(call: MethodCall) = requireNotNull(call.argument<String>("operationId"))

    private fun vault(call: MethodCall): SafVault {
        val requested = call.argument<String>("vaultUri")
        require(requested != null && requested == preferences.getString("vaultUri", null)) {
            "请通过系统选择器重新授权此笔记库；原文已保留。"
        }
        val uri = Uri.parse(requested)
        require(contentResolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission && it.isWritePermission }) {
            "笔记库读写授权已失效，请重新选择同一目录；原文已保留。"
        }
        return SafVault(contentResolver, uri).also { it.verifyRoot() }
    }

    private fun location(): Map<String, String> {
        val local = File(filesDir, "workspace")
        check(local.isDirectory || local.mkdirs()) { "无法打开本机存储位置。" }
        val data = mutableMapOf(
            "localDirectory" to local.absolutePath,
            "deviceInfo" to "${Build.MANUFACTURER} ${Build.MODEL} · Android ${Build.VERSION.RELEASE} · API ${Build.VERSION.SDK_INT}"
        )
        preferences.getString("vaultUri", null)?.let { saved ->
            data["vaultUri"] = saved
            data["vaultName"] = preferences.getString("vaultName", "笔记库")!!
            try {
                val uri = Uri.parse(saved)
                check(contentResolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission && it.isWritePermission })
                SafVault(contentResolver, uri).verifyRoot()
            } catch (_: Exception) {
                data["authorizationError"] = "笔记库授权已失效或目录已移动，请重新选择同一目录。已收集的原文仍保留在本机。"
            }
        }
        return data
    }

    @Suppress("DEPRECATION")
    private fun chooseLocation(result: MethodChannel.Result) {
        if (pendingPicker != null) {
            result.error("picker_busy", "系统目录选择器已打开。", null); return
        }
        pendingPicker = result
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(readWrite or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                putExtra(Intent.EXTRA_LOCAL_ONLY, true)
                if (Build.VERSION.SDK_INT >= 26) {
                    preferences.getString("vaultUri", null)?.let {
                        putExtra(DocumentsContract.EXTRA_INITIAL_URI, Uri.parse(it))
                    }
                }
            }
            startActivityForResult(intent, 2002)
        } catch (_: Exception) {
            pendingPicker = null
            result.error("picker_unavailable", "无法打开系统目录选择器，输入已保留。", null)
        }
    }

    @Deprecated("Activity result API retained for FlutterActivity's system picker bridge")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 2002) return
        val result = pendingPicker ?: return
        pendingPicker = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return }
        io.execute {
            try {
                // Obsidian's Android vault must be a local shared-storage directory.
                require(uri.scheme == "content" && uri.authority == "com.android.externalstorage.documents") {
                    "请选择手机共享存储中的 Obsidian 笔记库目录；暂不支持云端文档提供方。输入已保留。"
                }
                val flags = (data?.flags ?: 0) and readWrite
                require(flags == readWrite) { "需要此目录的读取和写入授权。输入已保留。" }
                contentResolver.takePersistableUriPermission(uri, flags)
                val vault = SafVault(contentResolver, uri)
                vault.verifyRoot()
                check(preferences.edit().putString("vaultUri", uri.toString()).putString("vaultName", vault.displayName()).commit()) {
                    "无法保存目录授权，请重试。"
                }
                val restored = location()
                runOnUiThread { result.success(restored) }
            } catch (error: Exception) {
                runOnUiThread { result.error("directory_access", error.message ?: "无法获得目录授权，输入已保留。", null) }
            }
        }
    }

    private fun openInObsidian(call: MethodCall, result: MethodChannel.Result) {
        io.execute {
            try {
                val storage = vault(call)
                val relative = path(call)
                check(storage.exists(relative)) { "笔记文件尚未写入笔记库。" }
                val uri = Uri.Builder().scheme("obsidian").authority("open")
                    .appendQueryParameter("vault", storage.displayName())
                    .appendQueryParameter("file", relative).build()
                runOnUiThread {
                    try {
                        startActivity(Intent(Intent.ACTION_VIEW, uri))
                        result.success(null)
                    } catch (_: Exception) {
                        result.error("obsidian_unavailable", "请安装 Obsidian，并先将同一目录作为笔记库打开。", null)
                    }
                }
            } catch (error: Exception) {
                runOnUiThread { result.error("note_path", error.message, null) }
            }
        }
    }
}
