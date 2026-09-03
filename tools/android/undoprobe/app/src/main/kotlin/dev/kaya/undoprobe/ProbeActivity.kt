// At foundation 1.7.5 the ONLY experimental surface here is
// `TextFieldState.undoState` and UndoState's five members
// (docs/undo-plan.md).
@file:OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)

package dev.kaya.undoprobe

// P3-compose (docs/undo-plan.md §0, D7): does a programmatic write enter
// the Compose text widgets' native undo history, and can it be cleared?
// Two fields side by side on the pins kaya ships — the legacy M3
// TextField and BasicTextField(state:) — driven through ORDERED
// broadcasts so there is no logcat race.
// THROWAWAY. Nothing in the validation ladder calls this.

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.input.TextFieldLineLimits
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.text.input.setTextAndPlaceCursorAtEnd
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.nativeKeyCode
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.unit.dp

/** The probe's whole observable state; a plain object so the receiver
 *  can read and write it without threading it through composition. */
object P {
    // The LEGACY field's app-side mirror — kaya's `node.text`.
    var legacy by mutableStateOf("")

    // The only lever the legacy path leaves: bumping this composition
    // key REMOUNTS the field, throwing away the CoreTextField and the
    // UndoManager it `remember`s.
    var legacyKey by mutableStateOf(0)

    // Every onValueChange the legacy field delivers — what kaya turns
    // into `text_changed`, so it answers "does an undo echo?".
    var legacyEmits = 0

    // The candidate path's state. One instance for the process' life.
    val tfs = TextFieldState("")

    // The TFS path has no onValueChange; the idiomatic observation is a
    // snapshotFlow over state.text. Counted because the echo doctrine
    // turns on WHICH writes this channel reports.
    var tfsObserved = 0
    var tfsLastObserved = ""

    // Key events seen by each field's onPreviewKeyEvent (pass-through:
    // the handler always returns false). Answers "did the chord reach
    // the app?" separately from "did it do anything?".
    val keys = ArrayList<String>()

    fun note(where: String, kind: String) {
        keys.add("$where:$kind")
        while (keys.size > 24) keys.removeAt(0)
    }

    fun report(): String {
        val u = tfs.undoState
        return "legacy=[${legacy}] emits=${legacyEmits} " +
            "tfs=[${tfs.text}] canUndo=${u.canUndo} canRedo=${u.canRedo} " +
            "tfsObserved=${tfsObserved} tfsLast=[${tfsLastObserved}] " +
            "keys=[${keys.joinToString(";")}]"
    }
}

class ProbeActivity : ComponentActivity() {
    private var receiver: BroadcastReceiver? = null
    private val legacyFocus = FocusRequester()
    private val tfsFocus = FocusRequester()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                androidx.compose.runtime.LaunchedEffect(Unit) {
                    androidx.compose.runtime.snapshotFlow { P.tfs.text.toString() }
                        .collect { v ->
                            P.tfsObserved++
                            P.tfsLastObserved = v
                        }
                }
                Column(modifier = Modifier.fillMaxSize().padding(4.dp)) {
                    LegacyField()
                    TfsField()
                    Text("L=[${P.legacy}] T=[${P.tfs.text}] " +
                        "u=${P.tfs.undoState.canUndo} r=${P.tfs.undoState.canRedo}")
                }
            }
        }
        val r = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val pending = goAsync()
                val cmd = intent.getStringExtra("cmd") ?: "state"
                val text = intent.getStringExtra("text") ?: ""
                val note = runCatching { apply(cmd, text) }
                    .getOrElse { "EXCEPTION ${it::class.java.simpleName}: ${it.message}" }
                // Two frames, then answer: a programmatic write must
                // have recomposed before the report claims anything.
                Handler(Looper.getMainLooper()).postDelayed({
                    pending.setResultData("cmd=$cmd note=$note ${P.report()}")
                    pending.finish()
                }, 350)
            }
        }
        receiver = r
        val f = IntentFilter("dev.kaya.undoprobe.CMD")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(r, f, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(r, f)
        }
    }

    // kaya's own accelerator route on Android. The platform calls this
    // ONLY for a ctrl-modified key that normal dispatch left
    // unconsumed, which is P5's double-fire question: would a kaya
    // Ctrl+Z fire beside the field's own undo, or only when the field
    // declined it?
    override fun dispatchKeyShortcutEvent(event: android.view.KeyEvent): Boolean {
        if (event.action == android.view.KeyEvent.ACTION_DOWN) {
            P.note("S", "${event.keyCode}${if (event.isCtrlPressed) "+C" else ""}")
        }
        return super.dispatchKeyShortcutEvent(event)
    }

    override fun onDestroy() {
        receiver?.let { unregisterReceiver(it) }
        receiver = null
        super.onDestroy()
    }

    /** The command table. Every write here is a PROGRAMMATIC write —
     *  kaya's apply path, not a user gesture. */
    private fun apply(cmd: String, text: String): String = when (cmd) {
        "state" -> "ok"
        "reset" -> {
            P.legacy = ""
            P.legacyEmits = 0
            P.keys.clear()
            P.tfs.setTextAndPlaceCursorAtEnd("")
            P.tfs.undoState.clearHistory()
            "ok"
        }
        // kaya's KIND_ENTRY apply arm, exactly: assign the mirror.
        "write_legacy" -> { P.legacy = text; "ok" }
        // The same write, plus a remount of the field.
        "write_legacy_remount" -> {
            P.legacy = text
            P.legacyKey++
            "remounted key=${P.legacyKey}"
        }
        // The two candidate spellings of a programmatic write.
        "tfs_settext" -> { P.tfs.setTextAndPlaceCursorAtEnd(text); "ok" }
        "tfs_edit" -> {
            P.tfs.edit { replace(0, length, text) }
            "ok"
        }
        // The kaya-shaped no-op write: an apply arm that does not diff.
        "tfs_edit_same" -> {
            val same = P.tfs.text.toString()
            P.tfs.edit { replace(0, length, same) }
            "rewrote [$same]"
        }
        "tfs_clearhistory" -> { P.tfs.undoState.clearHistory(); "ok" }
        "tfs_undo" -> {
            if (P.tfs.undoState.canUndo) { P.tfs.undoState.undo(); "undone" } else "canUndo=false"
        }
        "tfs_redo" -> {
            if (P.tfs.undoState.canRedo) { P.tfs.undoState.redo(); "redone" } else "canRedo=false"
        }
        // THE HARNESS HOLE: no kaya verb can press a chord at a native
        // widget. An app may not INJECT events, but it may DISPATCH one
        // into its own window — if that reaches the focused field's key
        // handler, a harness verb can drive the delegated tier with no
        // adb and no permission.
        "synth_ctrlz" -> {
            val t = android.os.SystemClock.uptimeMillis()
            val meta = android.view.KeyEvent.META_CTRL_ON or
                android.view.KeyEvent.META_CTRL_LEFT_ON
            for (action in intArrayOf(
                android.view.KeyEvent.ACTION_DOWN,
                android.view.KeyEvent.ACTION_UP,
            )) {
                dispatchKeyEvent(
                    android.view.KeyEvent(
                        t, t, action, android.view.KeyEvent.KEYCODE_Z, 0, meta,
                        android.view.KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0,
                        android.view.InputDevice.SOURCE_KEYBOARD,
                    ),
                )
            }
            "dispatched"
        }
        "focus_legacy" -> { legacyFocus.requestFocus(); "ok" }
        "focus_tfs" -> { tfsFocus.requestFocus(); "ok" }
        "clearkeys" -> { P.keys.clear(); "ok" }
        else -> "UNKNOWN COMMAND"
    }

    @androidx.compose.runtime.Composable
    private fun LegacyField() = androidx.compose.runtime.key(P.legacyKey) {
        TextField(
            value = P.legacy,
            onValueChange = { v ->
                P.legacyEmits++
                P.legacy = v
            },
            singleLine = true,
            modifier = Modifier
                .focusRequester(legacyFocus)
                .onPreviewKeyEvent { e ->
                    if (e.type == KeyEventType.KeyDown) {
                        P.note("L", "${e.key.nativeKeyCode}${if (isCtrl(e)) "+C" else ""}")
                    }
                    false
                },
        )
    }

    @OptIn(ExperimentalMaterial3Api::class)
    @androidx.compose.runtime.Composable
    private fun TfsField() {
        val interaction = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }
        BasicTextField(
            state = P.tfs,
            lineLimits = TextFieldLineLimits.SingleLine,
            interactionSource = interaction,
            modifier = Modifier
                .focusRequester(tfsFocus)
                .onPreviewKeyEvent { e ->
                    if (e.type == KeyEventType.KeyDown) {
                        P.note("T", "${e.key.nativeKeyCode}${if (isCtrl(e)) "+C" else ""}")
                    }
                    false
                },
            // The M3 dressing at material3 1.3.1, which has no
            // TextField(state:) overload — the shape a kaya arm has to
            // take without a pin bump.
            decorator = { inner ->
                TextFieldDefaults.DecorationBox(
                    value = P.tfs.text.toString(),
                    innerTextField = inner,
                    enabled = true,
                    singleLine = true,
                    visualTransformation =
                        androidx.compose.ui.text.input.VisualTransformation.None,
                    interactionSource = interaction,
                    contentPadding = TextFieldDefaults.contentPaddingWithoutLabel(),
                )
            },
        )
    }

    private fun isCtrl(e: androidx.compose.ui.input.key.KeyEvent): Boolean =
        e.nativeKeyEvent.isCtrlPressed
}
