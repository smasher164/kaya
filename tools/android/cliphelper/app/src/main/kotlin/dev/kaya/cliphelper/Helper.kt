package dev.kaya.cliphelper

import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.inputmethodservice.InputMethodService
import android.net.Uri
import android.os.PersistableBundle
import android.util.Base64

// The Android lane's FOREIGN clipboard app (docs/clipboard-plan.md
// §0e): seeds from the BACKGROUND (writes are not focus-gated) and
// reads as the DEFAULT IME, whose reads are admitted before focus is
// checked — so the guest keeps focus for the whole leg. Results ride
// ORDERED broadcast result data, which `am broadcast` prints.
private const val SUPPRESS = "com.android.systemui.SUPPRESS_CLIPBOARD_OVERLAY"

class SeedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val kind = intent.getStringExtra("kind") ?: "text"
        // Payloads arrive as base64 so binary is first-class and no
        // shell quoting layer can corrupt a byte (`am broadcast --es`
        // and app-to-app extras take the same string).
        val payload = intent.getStringExtra("b64")?.let { Base64.decode(it, Base64.NO_WRAP) }
            ?: ByteArray(0)
        val result = try {
            val clip = when (kind) {
                "text" -> ClipData(
                    suppressed(arrayOf(ClipDescription.MIMETYPE_TEXT_PLAIN)),
                    ClipData.Item(String(payload)),
                )
                "html" -> {
                    // BY HAND, both mimes: newHtmlText advertises
                    // text/html alone, and a consumer gating on
                    // text/plain would see nothing.
                    val html = String(payload)
                    ClipData(
                        suppressed(
                            arrayOf(
                                ClipDescription.MIMETYPE_TEXT_HTML,
                                ClipDescription.MIMETYPE_TEXT_PLAIN,
                            ),
                        ),
                        ClipData.Item(html, html),
                    )
                }
                "image" -> {
                    // The helper OWNS the seeded bytes, so the guest's
                    // read exercises the real cross-app grant path.
                    java.io.File(context.filesDir, "seed.png").writeBytes(payload)
                    ClipData(
                        suppressed(arrayOf("image/png")),
                        ClipData.Item(Uri.parse("content://dev.kaya.cliphelper/seed.png")),
                    )
                }
                "files" -> {
                    java.io.File(context.filesDir, "seed.bin").writeBytes(payload)
                    val name = intent.getStringExtra("name") ?: "seed.bin"
                    ClipData(
                        suppressed(arrayOf("text/uri-list")),
                        ClipData.Item(
                            Uri.parse("content://dev.kaya.cliphelper/seed.bin?name=$name"),
                        ),
                    )
                }
                else -> null
            }
            if (clip == null) "unknown kind $kind"
            else {
                cm.setPrimaryClip(clip)
                "seeded $kind"
            }
        } catch (e: Exception) {
            "SEED FAILED: ${e.javaClass.simpleName}: ${e.message}"
        }
        resultData = "KAYAHELPER $result"
    }

    private fun suppressed(mimes: Array<String>): ClipDescription =
        ClipDescription("kayahelper", mimes).apply {
            extras = PersistableBundle().apply { putBoolean(SUPPRESS, true) }
        }
}

class ReadReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val kind = intent.getStringExtra("kind") ?: "dump"
        val result = try {
            when (kind) {
                "dump" -> {
                    val clip = cm.primaryClip
                    if (clip == null) "clip=null"
                    else {
                        val d = clip.description
                        val mimes = (0 until d.mimeTypeCount).map { d.getMimeType(it) }
                        val items = (0 until clip.itemCount).map { i ->
                            val item = clip.getItemAt(i)
                            "item$i(text=${item.text != null} html=${item.htmlText != null} uri=${item.uri})"
                        }
                        "mimes=$mimes ${items.joinToString(" ")}"
                    }
                }
                "text" -> cm.primaryClip?.getItemAt(0)?.text?.toString() ?: ""
                "html" -> cm.primaryClip?.getItemAt(0)?.htmlText?.toString() ?: ""
                "custom", "image" -> {
                    val wanted = intent.getStringExtra("mime")
                        ?: if (kind == "custom") "dev.kaya/note" else "image/png"
                    val clip = cm.primaryClip
                    var answer = ""
                    if (clip != null) for (i in 0 until clip.itemCount) {
                        val uri = clip.getItemAt(i).uri ?: continue
                        if (context.contentResolver.getType(uri) != wanted) continue
                        val bytes =
                            context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                                ?: continue
                        answer = if (kind == "image") {
                            val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                            if (bmp == null) "<${bytes.size} bytes of $wanted that decode rejects>"
                            else "${bmp.width}x${bmp.height}"
                        } else {
                            String(bytes)
                        }
                        break
                    }
                    answer
                }
                "reopen" -> {
                    val uri = Uri.parse(intent.getStringExtra("uri") ?: "")
                    val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                    "reopened $uri -> ${bytes?.size} bytes"
                }
                else -> "unknown kind $kind"
            }
        } catch (e: Exception) {
            "READ FAILED: ${e.javaClass.simpleName}: ${e.message}"
        }
        resultData = "KAYAHELPER $result"
    }
}

/// Serves the helper's OWN seeded bytes back to whoever pastes them.
class HelperProvider : android.content.ContentProvider() {
    override fun onCreate() = true
    private fun fileFor(uri: Uri): java.io.File? = when (uri.path) {
        "/seed.png" -> java.io.File(context!!.filesDir, "seed.png")
        "/seed.bin" -> java.io.File(context!!.filesDir, "seed.bin")
        else -> null
    }

    override fun getType(uri: Uri): String? = when (uri.path) {
        "/seed.png" -> "image/png"
        "/seed.bin" -> "text/plain"
        else -> null
    }

    override fun openFile(uri: Uri, mode: String): android.os.ParcelFileDescriptor? {
        val f = fileFor(uri) ?: return null
        return android.os.ParcelFileDescriptor.open(
            f,
            android.os.ParcelFileDescriptor.MODE_READ_ONLY,
        )
    }

    override fun query(
        uri: Uri, projection: Array<String>?, selection: String?,
        selectionArgs: Array<String>?, sortOrder: String?,
    ): android.database.Cursor? {
        // OpenableColumns, for consumers that ask a pasted file its
        // display name.
        val name = uri.getQueryParameter("name") ?: uri.lastPathSegment ?: "seed.bin"
        val cursor = android.database.MatrixCursor(
            arrayOf(
                android.provider.OpenableColumns.DISPLAY_NAME,
                android.provider.OpenableColumns.SIZE,
            ),
        )
        cursor.addRow(arrayOf(name, fileFor(uri)?.length() ?: 0))
        return cursor
    }

    override fun insert(uri: Uri, values: android.content.ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<String>?) = 0
    override fun update(
        uri: Uri, values: android.content.ContentValues?, selection: String?,
        selectionArgs: Array<String>?,
    ) = 0
}

/// Never shown, never bound: being the DEFAULT IME is what exempts
/// this package's reads from the focus gate.
class HelperIme : InputMethodService()
