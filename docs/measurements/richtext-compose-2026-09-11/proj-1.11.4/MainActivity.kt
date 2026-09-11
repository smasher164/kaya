@file:OptIn(ExperimentalFoundationApi::class)

package dev.kayaprobe.richtext

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import android.text.Spanned
import android.util.Log
import android.view.View
import android.view.ViewGroup
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.input.InputTransformation
import androidx.compose.foundation.text.input.OutputTransformation
import androidx.compose.foundation.text.input.TextFieldBuffer
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.text.input.delete
import androidx.compose.foundation.text.input.insert
import androidx.compose.foundation.text.input.setTextAndPlaceCursorAtEnd
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

private const val TAG = "RTPROBE"

private fun log(s: String) = Log.i(TAG, s)

/** The app-owned run model — what kaya's core would hold. */
private data class Run(val start: Int, val end: Int, val kind: String)

class MainActivity : ComponentActivity() {

    private val state = TextFieldState("Hello world")
    private val focus = FocusRequester()
    private val runs = mutableListOf<Run>()
    private var version by mutableStateOf(0)
    private var linkOn by mutableStateOf(false)
    private lateinit var receiver: BroadcastReceiver

    private fun q(s: String): String = "\"" + s.replace("\"", "\\\"") + "\""

    private fun styleOf(kind: String): SpanStyle = when (kind) {
        "bold" -> SpanStyle(fontWeight = FontWeight.Bold)
        "italic" -> SpanStyle(fontStyle = FontStyle.Italic)
        "linklook" -> SpanStyle(color = Color(0xFF1A73E8), textDecoration = TextDecoration.Underline)
        else -> SpanStyle(fontWeight = FontWeight.Bold)
    }

    private fun addAnnotationReflectively(
        buf: TextFieldBuffer,
        ann: AnnotatedString.Annotation,
        start: Int,
        end: Int,
    ) {
        val m = TextFieldBuffer::class.java.declaredMethods.firstOrNull {
            it.name.startsWith("addAnnotation") && it.parameterTypes.size == 3
        }
        if (m == null) { log("LINK no addAnnotation on TextFieldBuffer"); return }
        m.isAccessible = true
        try {
            m.invoke(buf, ann, start, end)
            log("LINK addAnnotation(${m.name}) ok [$start,$end)")
        } catch (t: Throwable) {
            log("LINK addAnnotation threw ${t.cause ?: t}")
        }
    }

    private fun dump(label: String) {
        val text = state.text.toString()
        log("DUMP $label text=${q(text)} len16=${text.length} sel=${state.selection} " +
            "canUndo=${state.undoState.canUndo} appRuns=" +
            runs.joinToString(" ") { "[${it.start},${it.end})${it.kind}" })
    }

    private fun cmd(line: String) {
        val a = line.trim().split(" ")
        try {
            when (a[0]) {
                "settext" -> { state.setTextAndPlaceCursorAtEnd(line.substringAfter("settext ")) }
                "insert" -> state.edit { insert(a[1].toInt(), line.split(" ", limit = 3)[2]) }
                "delete" -> state.edit { delete(a[1].toInt(), a[2].toInt()) }
                "select" -> state.edit { selection = TextRange(a[1].toInt(), a[2].toInt()) }
                "style" -> { runs.add(Run(a[1].toInt(), a[2].toInt(), a[3])); version++ }
                "clearruns" -> { runs.clear(); version++ }
                "link" -> { linkOn = a[1] == "on"; version++; log("LINK mode=$linkOn") }
                // What the 1.12 API's editable route would be: refused here.
                "styledit" -> state.edit {
                    try {
                        addStyle(SpanStyle(fontWeight = FontWeight.Bold), a[1].toInt(), a[2].toInt())
                        log("STYLEDIT addStyle inside state.edit SUCCEEDED")
                    } catch (t: Throwable) {
                        log("STYLEDIT addStyle inside state.edit threw $t")
                    }
                }
                "dump" -> dump(a.getOrElse(1) { "-" })
                "undo" -> { state.undoState.undo(); log("UNDO done") }
                "clearhistory" -> { state.undoState.clearHistory(); log("CLEARHISTORY done") }
                "focus" -> { focus.requestFocus(); log("FOCUS requested") }
                "ax" -> axDump()
                else -> log("CMD unknown ${a[0]}")
            }
            log("CMD ok: $line")
        } catch (t: Throwable) {
            log("CMD threw on '$line': $t")
        }
    }

    private fun axDump() {
        val composeView = findComposeView(window.decorView) ?: run { log("AX no view"); return }
        val provider = composeView.accessibilityNodeProvider ?: run { log("AX no provider"); return }
        for (id in -1..400) {
            val info = try { provider.createAccessibilityNodeInfo(id) } catch (t: Throwable) { null }
                ?: continue
            val text = info.text ?: continue
            val spanned = text as? Spanned
            val spans = spanned?.getSpans(0, spanned.length, Any::class.java)?.joinToString(" ") {
                "${it.javaClass.simpleName}[${spanned.getSpanStart(it)},${spanned.getSpanEnd(it)})"
            } ?: "<not Spanned>"
            log("AX id=$id cls=${info.className} textClass=${text.javaClass.name} " +
                "text=${q(text.toString())} editable=${info.isEditable} spans=$spans")
        }
    }

    private fun findComposeView(v: View): View? {
        if (v.javaClass.simpleName == "AndroidComposeView") return v
        if (v is ViewGroup) {
            for (i in 0 until v.childCount) findComposeView(v.getChildAt(i))?.let { return it }
        }
        return null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        log("BOOT foundation=1.11.4 sdk=${Build.VERSION.SDK_INT}")
        receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context?, i: Intent?) { i?.getStringExtra("cmd")?.let { cmd(it) } }
        }
        val filter = IntentFilter("dev.kayaprobe.RT")
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(receiver, filter)
        }

        val inputTransformation = InputTransformation {
            log("IN changeCount=${changes.changeCount} " +
                (0 until changes.changeCount).joinToString(" ") {
                    "new=${changes.getRange(it)}orig=${changes.getOriginalRange(it)}"
                } +
                " originalText=${q(originalText.toString())} newText=${q(asCharSequence().toString())}")
        }

        setContent {
            val v = version
            val out = remember(v) {
                OutputTransformation {
                    runs.forEach { r ->
                        if (r.start in 0..length && r.end in 0..length && r.start <= r.end) {
                            addStyle(styleOf(r.kind), r.start, r.end)
                        }
                    }
                    if (linkOn) {
                        addAnnotationReflectively(
                            this,
                            LinkAnnotation.Url(
                                "https://example.com",
                                TextLinkStyles(
                                    SpanStyle(
                                        color = Color(0xFF1A73E8),
                                        textDecoration = TextDecoration.Underline,
                                    )
                                ),
                            ) { log("LINK clicked url") },
                            0,
                            length,
                        )
                    }
                }
            }
            Column(Modifier.padding(16.dp)) {
                BasicText("rtprobe11", style = TextStyle(fontSize = 12.sp))
                BasicTextField(
                    state = state,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(200.dp)
                        .background(Color(0xFFEFEFEF))
                        .focusRequester(focus),
                    textStyle = TextStyle(fontSize = 20.sp, color = Color.Black),
                    inputTransformation = inputTransformation,
                    outputTransformation = out,
                )
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        try { unregisterReceiver(receiver) } catch (_: Throwable) {}
    }
}
