package dev.kaya.clipprobe

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.File

// The byte side of an Android clip. ClipData.Item carries text,
// htmlText, a Uri or an Intent — NO byte array — so image and custom
// payloads ride content:// URIs served by a provider, and the
// consumer's read is contentResolver.getType + openInputStream. This
// is the pattern the Compose arm will use; the probe measures it
// first, grants included.
class ProbeProvider : ContentProvider() {
    override fun onCreate() = true

    private fun fileFor(uri: Uri): File? = when (uri.path) {
        "/custom" -> File(context!!.filesDir, "custom.bin")
        "/pixel" -> File(context!!.filesDir, "pixel.png")
        "/pasted" -> File(context!!.filesDir, "pasted.txt")
        else -> null
    }

    override fun getType(uri: Uri): String? = when (uri.path) {
        "/custom" -> "dev.kaya/note"
        "/pixel" -> "image/png"
        "/pasted" -> "text/plain"
        else -> null
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
        val f = fileFor(uri) ?: return null
        return ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun query(
        uri: Uri, projection: Array<String>?, selection: String?,
        selectionArgs: Array<String>?, sortOrder: String?,
    ): Cursor? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<String>?) = 0
    override fun update(
        uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<String>?,
    ) = 0
}
