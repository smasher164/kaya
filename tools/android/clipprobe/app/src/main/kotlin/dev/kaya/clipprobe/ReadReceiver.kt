package dev.kaya.clipprobe

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri

// The BACKGROUND read — which the platform normally refuses (reads
// are focus-gated since 10). THE CELL UNDER TEST: when this package
// is the DEFAULT IME (`adb shell ime enable/set`), ClipboardService's
// isDefaultIme branch admits the read with no focus and no window —
// the Appium pattern, and the shape the helper APK will take if it
// measures true. Results ride the ordered broadcast's result data.
class ReadReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE)
            as android.content.ClipboardManager
        val kind = intent.getStringExtra("kind") ?: "dump"
        val result = try {
            when (kind) {
                "dump" -> {
                    val clip = cm.primaryClip
                    if (clip == null) "clip=null (denied or empty)"
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
                "text" -> cm.primaryClip?.getItemAt(0)?.text?.toString() ?: "null"
                "html" -> {
                    val item = cm.primaryClip?.getItemAt(0)
                    "html=${item?.htmlText} coerce=${item?.coerceToText(context)}"
                }
                "custom", "image" -> {
                    val wanted = if (kind == "custom") "dev.kaya/note" else "image/png"
                    val clip = cm.primaryClip
                    var answer = "no item with $wanted"
                    if (clip == null) answer = "clip=null"
                    else for (i in 0 until clip.itemCount) {
                        val uri = clip.getItemAt(i).uri ?: continue
                        val type = context.contentResolver.getType(uri)
                        if (type != wanted) continue
                        val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                        answer = if (bytes == null) "openInputStream null for $uri"
                        else if (kind == "image") {
                            val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                            "uri=$uri bytes=${bytes.size} decoded=${bmp?.width}x${bmp?.height}"
                        } else {
                            "uri=$uri bytes=${bytes.size} text=${String(bytes)}"
                        }
                        break
                    }
                    answer
                }
                "reopen" -> {
                    // The revocation cell: re-open a URI captured from
                    // an EARLIER clip, after the clip has changed. The
                    // grant is revoked on every clip change (measured
                    // in ClipboardService.revokeUris) — this proves it
                    // from the outside.
                    val uri = Uri.parse(intent.getStringExtra("uri") ?: "")
                    val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                    "reopened $uri -> ${bytes?.size} bytes"
                }
                else -> "unknown kind $kind"
            }
        } catch (e: Exception) {
            "READ FAILED: ${e.javaClass.simpleName}: ${e.message}"
        }
        resultData = "KAYAPROBE $result"
    }
}
