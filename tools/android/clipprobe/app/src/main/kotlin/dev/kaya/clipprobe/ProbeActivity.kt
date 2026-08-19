package dev.kaya.clipprobe

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.widget.LinearLayout
import android.widget.TextView

// ClipProbe — what does Android charge for a clipboard read, and what
// does it PUT ON SCREEN when one happens? The host cannot ask: there is
// no `cmd clipboard`, and Android 10+ gives an unfocused reader
// nothing, which the shell always is. Findings:
// docs/clipboard-plan.md §7.
//
//  Q1 Does a FOCUSED app read what it wrote?
//  Q2 Does it still read after it LOSES focus?
//  Q3 WHAT APPEARS ON SCREEN — an overlay would sit on top of the
//     guest while the harness asserts against it.
//  Q4 Does a read see content the app did NOT write?
//
// Answers go to logcat under the "kayaprobe" tag.
class ProbeActivity : Activity() {
    private val tag = "kayaprobe"
    private fun say(s: String) = Log.i(tag, "PROBE $s")

    override fun onCreate(saved: Bundle?) {
        super.onCreate(saved)
        val text = TextView(this).apply { text = "clipprobe" }
        setContentView(LinearLayout(this).apply { addView(text) })

        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val seeded = intent.getStringExtra("seed")
        say("==== begin, sdk ${android.os.Build.VERSION.SDK_INT}, seed=${seeded ?: "none"}")

        // AT onCreate THE WINDOW DOES NOT HAVE FOCUS YET, and focus is
        // the clipboard's whole gate (docs/traps.md).
        say("Q0 read at onCreate (focus=${hasWindowFocus()}) -> " +
            "${cm.primaryClip?.getItemAt(0)?.text?.toString() ?: "null"}")

        Handler(Looper.getMainLooper()).postDelayed({
            say("Q3 window has focus: ${hasWindowFocus()}")

            // Q4: whatever is there BEFORE we touch it, read now that
            // focus has landed — the cross-app read when run.sh seeded
            // from an earlier process.
            val before = cm.primaryClip
            say("Q4 pre-existing clip: items=${before?.itemCount ?: -1} " +
                "text=${before?.getItemAt(0)?.text?.toString() ?: "null"} " +
                "mime=${before?.description?.let { d ->
                    (0 until d.mimeTypeCount).map { d.getMimeType(it) } }}")

            // Q1: write, then read back, focused.
            cm.setPrimaryClip(ClipData.newPlainText("kaya", "kaya-own-content"))
            val t0 = System.currentTimeMillis()
            val mine = cm.primaryClip
            say("Q1 own read took ${System.currentTimeMillis() - t0}ms -> " +
                "${mine?.getItemAt(0)?.text?.toString() ?: "null"}")
            say("Q3 (see the screenshot run.sh took for any overlay)")
        }, 2500)

        // Q2: read again once focus is gone. run.sh starts another app
        // over this one; the read below happens while that one is in
        // front.
        Handler(Looper.getMainLooper()).postDelayed({
            val unfocused = cm.primaryClip
            say("Q2 focus=${hasWindowFocus()} read -> " +
                "${unfocused?.getItemAt(0)?.text?.toString() ?: "null"}")

            // Q5: can an app WRITE while unfocused? It decides whether
            // a seeding helper must come to the foreground and steal
            // focus from the guest mid-scene.
            cm.setPrimaryClip(ClipData.newPlainText("kaya", "written-while-unfocused"))
            say("Q5 wrote while focus=${hasWindowFocus()}; run 2 says if it landed")
            say("==== end")
        }, 7000)
    }
}
