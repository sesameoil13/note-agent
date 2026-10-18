package dev.noteagent.note_agent

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val preferences by lazy { getSharedPreferences("note_workspace", MODE_PRIVATE) }
    private val io = Executors.newSingleThreadExecutor()
    private var secureCredentials: SecureCredentials? = null
    private var pendingPicker: MethodChannel.Result? = null
    private val readWrite = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        secureCredentials = SecureCredentials(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.noteagent/workspace")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "chooseLocation" -> chooseLocation(result)
                    "chooseSourceFile" -> chooseSourceFile(call, result)
                    "revealLocalSource" -> revealLocalSource(call, result)
                    "openInObsidian" -> openInObsidian(call, result)
                    "openSyncPlans" -> {
                        try {
                            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://obsidian.md/help/sync/plans")))
                            result.success(null)
                        } catch (error: Exception) {
                            result.error("open_url", "无法打开官方套餐说明。", null)
                        }
                    }
                    else -> io.execute {
                        try {
                            val value: Any? = when (call.method) {
                                "restoreLocation" -> location()
                                "vaultExists" -> vault(call).exists(path(call))
                                "vaultReadText" -> vault(call).readText(path(call))
                                "vaultPublishText" -> {
                                    vault(call).publishText(path(call), text(call), operation(call)); null
                                }
                                "vaultPublishFile" -> {
                                    val source = privateSource(requireNotNull(call.argument<String>("sourcePath")))
                                    vault(call).publishFile(path(call), source, operation(call)); null
                                }
                                "releaseSourceFile" -> {
                                    val source = File(requireNotNull(call.argument<String>("path"))).canonicalFile
                                    val root = File(cacheDir, "selected-sources").canonicalFile
                                    require(source.path.startsWith(root.path + File.separator)) { "来源位置无效。" }
                                    source.delete(); source.parentFile?.delete(); null
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
        if (requestCode != 2002 && requestCode != 2003) return
        val result = pendingPicker ?: return
        pendingPicker = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return }
        if (requestCode == 2003) {
            io.execute {
                var destination: File? = null
                try {
                    require(uri.scheme == "content") { "请选择系统文档提供方中的文件。" }
                    val name = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                        if (it.moveToFirst()) it.getString(0) else null
                    } ?: "document.pdf"
                    val safeName = name.replace(Regex("[\\\\/\\p{Cntrl}]"), "_").take(180).ifBlank { "document.pdf" }
                    val folder = File(cacheDir, "selected-sources/${UUID.randomUUID()}")
                    check(folder.mkdirs()) { "无法准备本机来源副本。" }
                    val selected = File(folder, safeName)
                    destination = selected
                    contentResolver.openInputStream(uri)?.use { input ->
                        FileOutputStream(selected).use { output -> input.copyTo(output, 65536); output.fd.sync() }
                    } ?: error("无法读取所选文件。")
                    val selectedPath = selected.absolutePath
                    runOnUiThread { result.success(selectedPath) }
                } catch (error: Exception) {
                    destination?.delete(); destination?.parentFile?.delete()
                    runOnUiThread { result.error("source_access", error.message ?: "无法完整保留所选来源，请重新选择。", null) }
                }
            }
            return
        }
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

    @Suppress("DEPRECATION")
    private fun chooseSourceFile(call: MethodCall, result: MethodChannel.Result) {
        if (pendingPicker != null) { result.error("picker_busy", "系统选择器已打开。", null); return }
        pendingPicker = result
        try {
            startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                type = when {
                    call.argument<Boolean>("pdfOnly") == true -> "application/pdf"
                    call.argument<Boolean>("audioOnly") == true -> "audio/*"
                    else -> "*/*"
                }
                addCategory(Intent.CATEGORY_OPENABLE)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                putExtra(Intent.EXTRA_LOCAL_ONLY, true)
            }, 2003)
        } catch (_: Exception) {
            pendingPicker = null
            result.error("picker_unavailable", "无法打开系统文件选择器。", null)
        }
    }

    private fun privateSource(path: String): File {
        val source = File(path).canonicalFile
        val allowed = listOf("originals", "copies", "recordings", "audio-sources").any {
            val root = File(filesDir, "workspace/$it").canonicalFile
            source.path.startsWith(root.path + File.separator)
        }
        require(source.isFile && allowed) { "本机原件位置无效。" }
        return source
    }

    private fun revealLocalSource(call: MethodCall, result: MethodChannel.Result) {
        try {
            val source = privateSource(requireNotNull(call.argument<String>("path")))
            val uri = FileProvider.getUriForFile(this, "$packageName.sources", source)
            val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(source.extension.lowercase()) ?: "application/octet-stream"
            startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
            result.success(null)
        } catch (_: Exception) { result.error("source_open", "无法打开原件，请安装相应文档阅读工具。原件继续保留。", null) }
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
