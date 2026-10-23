package dev.noteagent.note_agent

import android.content.ContentResolver
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.webkit.MimeTypeMap
import java.util.Locale
import java.io.IOException
import java.io.File
import java.io.InputStream
import java.security.MessageDigest

/** All external reads/writes stay on provider URIs, never inferred filesystem paths. */
internal class SafVault(private val resolver: ContentResolver, private val tree: Uri) {
    private data class Entry(val uri: Uri, val name: String, val mime: String, val flags: Long)
    private val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))

    fun verifyRoot() {
        val item = entry(root)
        check(item.mime == Document.MIME_TYPE_DIR && item.flags and Document.FLAG_DIR_SUPPORTS_CREATE.toLong() != 0L) {
            "此目录不可写或已移动，请重新选择可写笔记库；原文已保留。"
        }
    }

    fun displayName(): String = entry(root).name
    private fun safe(path: String): List<String> {
        val parts = path.split('/')
        require(parts.all { it.isNotEmpty() && it != "." && it != ".." && !it.contains('\\') && !it.contains('\u0000') }) {
            "笔记位置必须位于授权目录内。"
        }
        return parts
    }

    private fun entry(uri: Uri): Entry = resolver.query(uri,
        arrayOf(Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE, Document.COLUMN_FLAGS), null, null, null
    )?.use { cursor ->
        if (!cursor.moveToFirst()) throw IOException("笔记库或文件已移动，请重新选择目录。")
        Entry(uri, cursor.getString(0), cursor.getString(1), cursor.getLong(2))
    } ?: throw IOException("无法读取笔记库，请重新授权。")

    private fun children(parent: Uri): List<Entry> {
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getDocumentId(parent))
        return resolver.query(uri, arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE, Document.COLUMN_FLAGS), null, null, null)?.use { cursor ->
            val result = mutableListOf<Entry>()
            while (cursor.moveToNext()) {
                result.add(Entry(DocumentsContract.buildDocumentUriUsingTree(tree, cursor.getString(0)),
                    cursor.getString(1), cursor.getString(2), cursor.getLong(3)))
            }
            result
        } ?: throw IOException("无法列出笔记库内容，请重新授权。")
    }

    private fun child(parent: Uri, name: String): Entry? {
        val matches = children(parent).filter { it.name == name }
        check(matches.size <= 1) { "目录中存在重复名称，请先在文件管理器中处理。" }
        return matches.singleOrNull()
    }

    private fun directory(parts: List<String>, create: Boolean): Uri? {
        var current = root
        for (part in parts) {
            val item = child(current, part)
            if (item != null) {
                check(item.mime == Document.MIME_TYPE_DIR) { "笔记库写入位置不是目录；原文已保留。" }
                current = item.uri
            } else {
                if (!create) return null
                val created = DocumentsContract.createDocument(resolver, current, Document.MIME_TYPE_DIR, part)
                    ?: throw IOException("无法创建笔记库子目录。")
                check(entry(created).name == part) { "文档提供方更改了目录名，未写入笔记。" }
                current = created
            }
        }
        return current
    }

    private fun find(path: String): Entry? {
        val parts = safe(path)
        val parent = directory(parts.dropLast(1), false) ?: return null
        return child(parent, parts.last())
    }
    fun exists(path: String): Boolean = find(path) != null
    private fun read(uri: Uri): String = resolver.openInputStream(uri)?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }
        ?: throw IOException("无法读取原文。")
    /** Provider-reported last modification (epoch millis), or null if unknown. */
    fun modifiedTime(path: String): Long? {
        val uri = find(path)?.uri ?: return null
        return resolver.query(uri, arrayOf(Document.COLUMN_LAST_MODIFIED), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getLong(0) else null
        }
    }
    fun readText(path: String): String = read(find(path)?.uri ?: throw IOException("笔记文件不存在。"))

    private fun staging(path: String, text: String, operation: String): Pair<Uri, Uri> {
        safe(operation).also { require(it.size == 1) }
        val key = MessageDigest.getInstance("SHA-256").digest(path.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        val parent = directory(listOf(".note-agent-staging", operation, key), true)!!
        val name = safe(path).last()
        val existing = child(parent, name)
        // A forced text/plain MIME can turn "note.md" into "note.md.txt" in
        // ExternalStorageProvider. Match Android's extension map; an unknown
        // extension uses octet-stream so the exact requested name is preserved.
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(
            name.substringAfterLast('.', "").lowercase(Locale.ROOT)
        ) ?: "application/octet-stream"
        val uri = existing?.uri ?: DocumentsContract.createDocument(resolver, parent, mime, name)
            ?: throw IOException("无法准备完整笔记。")
        check(entry(uri).name == name) { "文档提供方更改了文件名，未写入笔记。" }
        resolver.openOutputStream(uri, "wt")?.bufferedWriter(Charsets.UTF_8)?.use { it.write(text) }
            ?: throw IOException("无法写入笔记；原文已保留。")
        check(read(uri) == text) { "笔记写入校验失败；原文已保留。" }
        return Pair(parent, uri)
    }

    private fun move(uri: Uri, parent: Uri, target: Uri, name: String): Uri {
        val moved = DocumentsContract.moveDocument(resolver, uri, parent, target)
            ?: throw IOException("文档提供方无法发布完整笔记。")
        if (entry(moved).name != name) {
            DocumentsContract.deleteDocument(resolver, moved)
            throw IOException("目标已存在，未覆盖原笔记；请重试。")
        }
        return moved
    }

    fun publishText(path: String, text: String, operation: String) {
        val parts = safe(path)
        val target = directory(parts.dropLast(1), true)!!
        child(target, parts.last())?.let {
            check(it.mime != Document.MIME_TYPE_DIR && read(it.uri) == text) {
                "已有同名笔记，未覆盖原文件；原文已保留。"
            }
            return
        }
        val (stageParent, staged) = staging(path, text, operation)
        check(child(target, parts.last()) == null) { "已有同名笔记，未覆盖原文件。" }
        val published = move(staged, stageParent, target, parts.last())
        check(read(published) == text) { "笔记写入校验失败；原文已保留。" }
        // Only this operation's empty private directory is removed.
        DocumentsContract.deleteDocument(resolver, stageParent)
    }

    /** Stream the app-private immutable original to SAF; never interpret a URI as a File. */
    fun publishFile(path: String, source: File, operation: String) {
        require(source.length() <= 5_000_000) { "来源超过 Standard 单文件 5 MB，原件继续保留在本机。" }
        fun digest(stream: InputStream): ByteArray = stream.use {
            val hash = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(65536)
            while (true) { val count = it.read(buffer); if (count < 0) break; hash.update(buffer, 0, count) }
            hash.digest()
        }
        fun matches(uri: Uri, expected: ByteArray): Boolean = resolver.openInputStream(uri)?.let { digest(it).contentEquals(expected) } ?: false
        val expected = digest(source.inputStream())
        val parts = safe(path)
        val target = directory(parts.dropLast(1), true)!!
        child(target, parts.last())?.let {
            check(it.mime != Document.MIME_TYPE_DIR && matches(it.uri, expected)) { "已有不同的来源文件，未覆盖原文件。" }
            return
        }
        safe(operation).also { require(it.size == 1) }
        val key = MessageDigest.getInstance("SHA-256").digest(path.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
        val parent = directory(listOf(".note-agent-staging", operation, key), true)!!
        val name = parts.last()
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase(Locale.ROOT)) ?: "application/octet-stream"
        val staged = child(parent, name)?.uri ?: DocumentsContract.createDocument(resolver, parent, mime, name) ?: throw IOException("无法准备完整来源文件。")
        check(entry(staged).name == name) { "文档提供方更改了来源文件名。" }
        resolver.openOutputStream(staged, "wt")?.use { output -> source.inputStream().use { it.copyTo(output, 65536) } } ?: throw IOException("无法写入来源文件。")
        check(matches(staged, expected)) { "来源文件写入校验未通过，原件继续保留。" }
        check(child(target, name) == null) { "已有同名来源文件，未覆盖原文件。" }
        val published = move(staged, parent, target, name)
        check(matches(published, expected)) { "来源文件写入校验未通过，原件继续保留。" }
        DocumentsContract.deleteDocument(resolver, parent)
    }

    fun listNotePaths(): List<String> {
        val result = mutableListOf<String>()
        fun walk(parent: Uri, prefix: String) {
            for (item in children(parent)) {
                if (item.name.startsWith('.')) continue
                val path = prefix + item.name
                if (item.mime == Document.MIME_TYPE_DIR) walk(item.uri, "$path/")
                else if (item.name.endsWith(".md", ignoreCase = true)) result.add(path)
            }
        }
        walk(root, "")
        return result.sorted()
    }

    /** Provider moves preserve a backup while replacing; a retry resumes after interruption. */
    fun replaceText(path: String, expected: String, text: String, operation: String) {
        val parts = safe(path)
        val target = directory(parts.dropLast(1), false) ?: throw IOException("笔记目录已移动。")
        val (stageParent, staged) = staging(path, text, operation)
        val backupParent = child(stageParent, "backup")?.uri
            ?: DocumentsContract.createDocument(resolver, stageParent, Document.MIME_TYPE_DIR, "backup")
            ?: throw IOException("无法保留修改前的笔记。")
        var backup = child(backupParent, parts.last())
        val current = child(target, parts.last())
        if (current != null && read(current.uri) == text) {
            DocumentsContract.deleteDocument(resolver, stageParent)
            return
        }
        if (current != null) {
            check(read(current.uri) == expected) { "笔记已在其他位置修改，请重新读取后重试。" }
            check(backup == null) { "保留的旧版本需要恢复，请重试或检查笔记库。" }
            val moved = move(current.uri, target, backupParent, parts.last())
            backup = entry(moved)
        }
        val original = backup ?: throw IOException("笔记已移动，未改写其他内容。")
        check(read(original.uri) == expected) { "笔记已在其他位置修改，保留旧版本。" }
        try {
            check(child(target, parts.last()) == null) { "笔记已在其他位置修改，保留原文件。" }
            val published = move(staged, stageParent, target, parts.last())
            check(read(published) == text) { "笔记写入校验失败，旧版本已保留。" }
            DocumentsContract.deleteDocument(resolver, stageParent)
        } catch (error: Exception) {
            if (child(target, parts.last()) == null) {
                move(original.uri, backupParent, target, parts.last())
            }
            throw error
        }
    }

    fun deleteText(path: String, expected: String) {
        val item = find(path) ?: return
        check(read(item.uri) == expected) { "笔记已在其他位置修改，保留原文件。" }
        check(DocumentsContract.deleteDocument(resolver, item.uri)) { "无法移除旧笔记。" }
    }
}
