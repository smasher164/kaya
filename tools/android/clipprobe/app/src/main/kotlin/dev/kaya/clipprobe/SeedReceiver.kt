package dev.kaya.clipprobe

import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PersistableBundle
import java.io.File

// The BACKGROUND seed: writes are not focus-gated
// (docs/clipboard-plan.md §7), so a broadcast receiver can put content
// on the clipboard while the guest keeps the foreground. The result
// rides an ORDERED broadcast's result data, which `am broadcast`
// prints on stdout — no logcat race.
class SeedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val kind = intent.getStringExtra("kind") ?: "text"
        val payload = intent.getStringExtra("payload") ?: ""
        val result = try {
            when (kind) {
                "text" -> {
                    cm.setPrimaryClip(ClipData.newPlainText("kayaprobe", payload))
                    "seeded text"
                }
                "fiverep" -> {
                    // One clip, several representations, built BY HAND:
                    // newHtmlText advertises text/html alone, so the
                    // description lists every offered mime explicitly
                    // (docs/clipboard-plan.md §7).
                    File(context.filesDir, "custom.bin").writeBytes("note=1".toByteArray())
                    File(context.filesDir, "pixel.png").writeBytes(PIXEL_PNG)
                    val description = ClipDescription(
                        "kayaprobe",
                        arrayOf(
                            "dev.kaya/note",
                            "image/png",
                            ClipDescription.MIMETYPE_TEXT_HTML,
                            ClipDescription.MIMETYPE_TEXT_PLAIN,
                        ),
                    )
                    // The API 33+ copy overlay is suppressible on an
                    // emulator (docs/clipboard-plan.md §7).
                    description.extras = PersistableBundle().apply {
                        putBoolean("com.android.systemui.SUPPRESS_CLIPBOARD_OVERLAY", true)
                    }
                    val first = ClipData.Item("kaya clip", "<b>kaya</b> clip")
                    val clip = ClipData(description, first)
                    clip.addItem(ClipData.Item(Uri.parse("content://dev.kaya.clipprobe/custom")))
                    clip.addItem(ClipData.Item(Uri.parse("content://dev.kaya.clipprobe/pixel")))
                    cm.setPrimaryClip(clip)
                    "seeded fiverep"
                }
                "ungrantable" -> {
                    // A URI no provider serves, to provoke the
                    // documented-nowhere clear-the-whole-clipboard
                    // failure (docs/clipboard-plan.md §7: unconfirmed
                    // on API 35).
                    val clip = ClipData(
                        ClipDescription("kayaprobe", arrayOf("application/octet-stream")),
                        ClipData.Item(Uri.parse("content://dev.kaya.clipprobe.bogus/x")),
                    )
                    cm.setPrimaryClip(clip)
                    "seeded ungrantable"
                }
                else -> "unknown kind $kind"
            }
        } catch (e: Exception) {
            "SEED FAILED: ${e.javaClass.simpleName}: ${e.message}"
        }
        resultData = "KAYAPROBE $result"
    }

    companion object {
        // The same valid 4x4 PNG the guests embed (77 bytes).
        val PIXEL_PNG = byteArrayOf(
            0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x26, 0x93.toByte(), 0x09,
            0x29, 0x00, 0x00, 0x00, 0x14, 0x49, 0x44, 0x41,
            0x54, 0x78, 0xDA.toByte(), 0x63, 0xF8.toByte(), 0xCF.toByte(), 0xC0.toByte(), 0x00,
            0x47, 0x48, 0x4C, 0x74, 0xDE.toByte(), 0x7F, 0x24, 0x00,
            0x00, 0xD2.toByte(), 0x6F, 0x17, 0xE9.toByte(), 0x51, 0xBB.toByte(), 0x23,
            0x2D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
            0x44, 0xAE.toByte(), 0x42, 0x60, 0x82.toByte(),
        )
    }
}
