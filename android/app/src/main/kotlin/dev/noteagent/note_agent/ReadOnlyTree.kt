package dev.noteagent.note_agent

import android.content.ContentResolver
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import java.io.IOException

/**
 * A SAF tree picked once for the old-vault backup comparison. Only provider
 * queries are issued: nothing is opened for writing, created, moved or deleted,
 * and no persisted permission is taken.
 */
internal class ReadOnlyTree(private val resolver: ContentResolver, private val tree: Uri) {
    /** Relative path (dot-folders included, like the desktop comparison) to size in bytes. */
    fun inventory(): Map<String, Long> {
        val result = mutableMapOf<String, Long>()
        fun walk(documentId: String, prefix: String) {
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, documentId)
            resolver.query(children, arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME,
                Document.COLUMN_MIME_TYPE, Document.COLUMN_SIZE), null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    val path = prefix + cursor.getString(1)
                    if (cursor.getString(2) == Document.MIME_TYPE_DIR) walk(cursor.getString(0), "$path/")
                    else result[path] = if (cursor.isNull(3)) 0L else cursor.getLong(3)
                }
            } ?: throw IOException("无法读取所选文件夹，请重新选择。")
        }
        walk(DocumentsContract.getTreeDocumentId(tree), "")
        return result
    }
}
