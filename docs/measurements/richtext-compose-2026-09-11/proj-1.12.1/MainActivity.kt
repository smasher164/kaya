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
import androidx.compose.foundation.ComposeFoundationFlags
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.input.ExpandPolicy
import androidx.compose.foundation.text.input.InputTransformation
import androidx.compose.foundation.text.input.OutputTransformation
import androidx.compose.foundation.text.input.TextFieldBuffer
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.text.input.delete
import androidx.compose.foundation.text.input.insert
import androidx.compose.foundation.text.input.setTextAndPlaceCursorAtEnd
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

private const val TAG = "RTPROBE"

private fun log(s: String) = Log.i(TAG, s)

class MainActivity : ComponentActivity() {

    private val state = TextFieldState("Hello world")
    private val focus = FocusRequester()
    private var outMode by mutableStateOf("none")
    private var inTrans by mutableStateOf(true)
    private lateinit var receiver: BroadcastReceiver

    private fun spanSummary(s: SpanStyle): String {
        val parts = mutableListOf<String>()
        s.fontWeight?.let { parts.add("w=${it.weight}") }
        s.fontStyle?.let { parts.add("style=$it") }
        s.textDecoration?.let { parts.add("dec=$it") }
        s.fontFamily?.let { parts.add("ff=$it") }
        if (s.fontSize != androidx.compose.ui.unit.TextUnit.Unspecified) parts.add("size=${s.fontSize}")
        if (s.color != Color.Unspecified) parts.add("color=${s.color.value.toString(16)}")
        return parts.joinToString(",")
    }

    /** The state-level view: what TextFieldState.textStyles answers. */
    private fun dumpState(label: String) {
        val text = state.text.toString()
        val spans = state.textStyles.getSpanStyles(TextRange(0, text.length))
        val paras = state.textStyles.getParagraphStyles(TextRange(0, text.length))
        log(
            "DUMP $label text=${q(text)} len16=${text.length} " +
                "cps=${text.codePointCount(0, text.length)} " +
                "utf8=${text.toByteArray(Charsets.UTF_8).size} " +
                "sel=${state.selection} " +
                "canUndo=${state.undoState.canUndo} canRedo=${state.undoState.canRedo} " +
                "styledFlag=${ComposeFoundationFlags.isBasicTextFieldStyledTextEnabled}"
        )
        log("DUMP $label spanCount=${spans.size} " +
            spans.joinToString(" ") { "[${it.start},${it.end})${spanSummary(it.item)}" })
        if (paras.isNotEmpty()) {
            log("DUMP $label paraCount=${paras.size} " +
                paras.joinToString(" ") { "[${it.start},${it.end})${it.item}" })
        }
    }

    /** The buffer-level view: TrackedRanges, their policy, validity, and the ChangeList. */
    private fun dumpBuffer(label: String) {
        state.edit {
            val trs = getSpanStyles(TextRange(0, length))
            log("BUF $label trackedCount=${trs.size} " +
                trs.joinToString(" ") { tr ->
                    "[${tr.textRange.start},${tr.textRange.end})" +
                        "${spanSummary(tr.spanStyle)}" +
                        "/policy=${policyName(tr.expandPolicy)}/valid=${tr.isValid}"
                })
            log("BUF $label changeCount=${changes.changeCount} " +
                (0 until changes.changeCount).joinToString(" ") {
                    "new=${changes.getRange(it)}orig=${changes.getOriginalRange(it)}"
                } + " originalText=${q(originalText.toString())}")
        }
    }

    private fun policyName(p: ExpandPolicy): String = when (p) {
        ExpandPolicy.InsideOnly -> "InsideOnly"
        ExpandPolicy.AtStart -> "AtStart"
        ExpandPolicy.AtEnd -> "AtEnd"
        ExpandPolicy.AtBoth -> "AtBoth"
        else -> "?"
    }

    private fun styleOf(kind: String): SpanStyle = when (kind) {
        "bold" -> SpanStyle(fontWeight = FontWeight.Bold)
        "italic" -> SpanStyle(fontStyle = FontStyle.Italic)
        "underline" -> SpanStyle(textDecoration = TextDecoration.Underline)
        "strike" -> SpanStyle(textDecoration = TextDecoration.LineThrough)
        "mono" -> SpanStyle(fontFamily = FontFamily.Monospace)
        "heading" -> SpanStyle(fontSize = 28.sp, fontWeight = FontWeight.Bold)
        "linklook" -> SpanStyle(color = Color(0xFF1A73E8), textDecoration = TextDecoration.Underline)
        else -> SpanStyle(fontWeight = FontWeight.Bold)
    }

    private fun policyOf(name: String?): ExpandPolicy = when (name) {
        "InsideOnly" -> ExpandPolicy.InsideOnly
        "AtStart" -> ExpandPolicy.AtStart
        "AtBoth" -> ExpandPolicy.AtBoth
        else -> ExpandPolicy.AtEnd
    }

    private fun q(s: String): String = "\"" + s.replace("\"", "\\\"") + "\""

    /** The only route to a non-style annotation on a buffer: an internal function. */
    private fun addAnnotationReflectively(
        buf: TextFieldBuffer,
        ann: AnnotatedString.Annotation,
        start: Int,
        end: Int,
    ) {
        val m = TextFieldBuffer::class.java.declaredMethods.firstOrNull {
            it.name.startsWith("addAnnotation") && it.parameterTypes.size == 3
        }
        if (m == null) {
            log("LINK no addAnnotation method on TextFieldBuffer; methods=" +
                TextFieldBuffer::class.java.declaredMethods.filter {
                    it.name.contains("nnotation") || it.name.contains("addStyle")
                }.joinToString(",") { it.name })
            return
        }
        m.isAccessible = true
        try {
            m.invoke(buf, ann, start, end)
            log("LINK addAnnotation(${m.name}) ok [$start,$end) $ann")
        } catch (t: Throwable) {
            log("LINK addAnnotation(${m.name}) threw ${t.cause ?: t}")
        }
    }

    private fun cmd(line: String) {
        val a = line.trim().split(" ")
        try {
            when (a[0]) {
                "settext" -> state.setTextAndPlaceCursorAtEnd(line.substringAfter("settext "))
                "insert" -> state.edit { insert(a[1].toInt(), line.split(" ", limit = 3)[2]) }
                "replace" -> state.edit {
                    replace(a[1].toInt(), a[2].toInt(), line.split(" ", limit = 4)[3])
                }
                "delete" -> state.edit { delete(a[1].toInt(), a[2].toInt()) }
                "select" -> state.edit { selection = TextRange(a[1].toInt(), a[2].toInt()) }
                "style" -> state.edit {
                    val tr = addStyle(
                        styleOf(a[3]),
                        TextRange(a[1].toInt(), a[2].toInt()),
                        policyOf(a.getOrNull(4)),
                    )
                    log("STYLE added ${a[3]} ${tr.textRange} policy=${policyName(tr.expandPolicy)}" +
                        " valid=${tr.isValid}")
                }
                // The start/end overload, which the KDoc says behaves as AtEnd.
                "style2" -> state.edit { addStyle(styleOf(a[3]), a[1].toInt(), a[2].toInt()) }
                // addStyle and read the ChangeList inside the SAME edit block.
                "stylechanges" -> state.edit {
                    log("SC before changeCount=${changes.changeCount}")
                    val tr = addStyle(
                        styleOf(a[3]),
                        TextRange(a[1].toInt(), a[2].toInt()),
                        policyOf(a.getOrNull(4)),
                    )
                    log("SC after changeCount=${changes.changeCount} " +
                        (0 until changes.changeCount).joinToString(" ") {
                            "new=${changes.getRange(it)}orig=${changes.getOriginalRange(it)}"
                        } + " tr=${tr.textRange} valid=${tr.isValid}" +
                        " originalText=${q(originalText.toString())}" +
                        " text=${q(asCharSequence().toString())}")
                }
                // A replace and an addStyle in one edit: two changes or one?
                "editboth" -> state.edit {
                    replace(a[1].toInt(), a[2].toInt(), line.split(" ", limit = 4)[3])
                    addStyle(SpanStyle(fontWeight = FontWeight.Bold), a[1].toInt(), a[2].toInt())
                    log("EB changeCount=${changes.changeCount} " +
                        (0 until changes.changeCount).joinToString(" ") {
                            "new=${changes.getRange(it)}orig=${changes.getOriginalRange(it)}"
                        })
                }
                // A multi-byte literal, set without passing through the shell.
                "mb" -> {
                    val t = "h\u00E9llo \uD83D\uDC4B world"
                    state.setTextAndPlaceCursorAtEnd(t)
                    log("MB set len16=${t.length} cps=${t.codePointCount(0, t.length)} " +
                        "utf8=${t.toByteArray(Charsets.UTF_8).size}")
                }
                "rmstyle" -> state.edit {
                    val trs = getSpanStyles(TextRange(0, length))
                    val i = a[1].toInt()
                    if (i < trs.size) log("RMSTYLE i=$i ok=${removeStyle(trs[i])}")
                    else log("RMSTYLE i=$i out of ${trs.size}")
                }
                "dump" -> { dumpState(a.getOrElse(1) { "-" }); dumpBuffer(a.getOrElse(1) { "-" }) }
                "undo" -> { state.undoState.undo(); log("UNDO done") }
                "redo" -> { state.undoState.redo(); log("REDO done") }
                "clearhistory" -> { state.undoState.clearHistory(); log("CLEARHISTORY done") }
                "flag" -> {
                    ComposeFoundationFlags.isBasicTextFieldStyledTextEnabled = a[1] == "on"
                    log("FLAG isBasicTextFieldStyledTextEnabled=" +
                        "${ComposeFoundationFlags.isBasicTextFieldStyledTextEnabled}")
                }
                "outtrans" -> { outMode = a[1]; log("OUTTRANS mode=$outMode") }
                "intrans" -> { inTrans = a[1] == "on"; log("INTRANS $inTrans") }
                "focus" -> { focus.requestFocus(); log("FOCUS requested") }
                "ax" -> axDump()
                else -> log("CMD unknown ${a[0]}")
            }
            log("CMD ok: $line")
        } catch (t: Throwable) {
            log("CMD threw on '$line': $t")
        }
    }

    /** What a screen reader would be handed, read through the real node provider. */
    private fun axDump() {
        val composeView = findComposeView(window.decorView)
        if (composeView == null) { log("AX no AndroidComposeView"); return }
        val provider = composeView.accessibilityNodeProvider
        if (provider == null) { log("AX no node provider"); return }
        var found = 0
        for (id in -1..400) {
            val info = try { provider.createAccessibilityNodeInfo(id) } catch (t: Throwable) { null }
                ?: continue
            val text = info.text
            val desc = info.contentDescription
            if (text == null && desc == null) continue
            found++
            val spanned = text as? Spanned
            val spans = spanned?.getSpans(0, spanned.length, Any::class.java)?.joinToString(" ") {
                "${it.javaClass.simpleName}[${spanned.getSpanStart(it)},${spanned.getSpanEnd(it)})"
            } ?: "<not Spanned>"
            log("AX id=$id cls=${info.className} textClass=${text?.javaClass?.name} " +
                "text=${q(text?.toString() ?: "")} desc=${q(desc?.toString() ?: "")} " +
                "editable=${info.isEditable} spans=$spans")
        }
        log("AX nodesWithText=$found")
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
        log("BOOT flagStyled=${ComposeFoundationFlags.isBasicTextFieldStyledTextEnabled} " +
            "sdk=${Build.VERSION.SDK_INT}")
        receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context?, i: Intent?) {
                i?.getStringExtra("cmd")?.let { cmd(it) }
            }
        }
        val filter = IntentFilter("dev.kayaprobe.RT")
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(receiver, filter)
        }

        val inputTransformation = InputTransformation {
            if (!inTrans) return@InputTransformation
            val trs = getSpanStyles(TextRange(0, length))
            log("IN changeCount=${changes.changeCount} " +
                (0 until changes.changeCount).joinToString(" ") {
                    "new=${changes.getRange(it)}orig=${changes.getOriginalRange(it)}"
                } +
                " originalText=${q(originalText.toString())} newText=${q(asCharSequence().toString())}" +
                " sel=$selection")
            log("IN spans=" + trs.joinToString(" ") {
                "[${it.textRange.start},${it.textRange.end})${spanSummary(it.spanStyle)}" +
                    "/${policyName(it.expandPolicy)}"
            })
        }

        setContent {
            val out: OutputTransformation? = when (outMode) {
                "none" -> null
                "linkreflect" -> OutputTransformation {
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
                "clickreflect" -> OutputTransformation {
                    addAnnotationReflectively(
                        this,
                        LinkAnnotation.Clickable(
                            "tag",
                            TextLinkStyles(
                                SpanStyle(
                                    color = Color(0xFF1A73E8),
                                    textDecoration = TextDecoration.Underline,
                                )
                            ),
                        ) { log("LINK clicked clickable") },
                        0,
                        length,
                    )
                }
                "boldstyle" -> OutputTransformation {
                    addStyle(SpanStyle(fontWeight = FontWeight.Bold), 0, minOf(5, length))
                }
                else -> null
            }
            Column(Modifier.padding(16.dp)) {
                BasicText("rtprobe", style = TextStyle(fontSize = 12.sp))
                // The read-only twin of the field's content: the same three runs
                // plus a real LinkAnnotation, which a Text CAN carry.
                BasicText(
                    buildAnnotatedString {
                        append("Bold ")
                        withLink(
                            LinkAnnotation.Url(
                                "https://example.com",
                                TextLinkStyles(
                                    SpanStyle(
                                        color = Color(0xFF1A73E8),
                                        textDecoration = TextDecoration.Underline,
                                    )
                                ),
                            ) { log("LINK clicked on BasicText") }
                        ) { append("LINK") }
                        append(" Head")
                        addStyle(SpanStyle(fontWeight = FontWeight.Bold), 0, 4)
                        addStyle(SpanStyle(fontSize = 28.sp, fontWeight = FontWeight.Bold), 10, 14)
                    },
                    style = TextStyle(fontSize = 20.sp, color = Color.Black),
                )
                BasicTextField(
                    state = state,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(220.dp)
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
