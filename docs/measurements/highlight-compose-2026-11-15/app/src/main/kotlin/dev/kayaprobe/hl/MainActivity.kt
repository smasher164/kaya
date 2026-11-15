package dev.kayaprobe.hl

// docs/highlight-plan.md §3: the mark drawn BEHIND a BasicTextField (kaya's
// KayaHighlightLayer route) under the field's own selection wash, and what the
// accessibility node carries for it, against a control field whose word wears
// SpanStyle(background) through an OutputTransformation.

import android.os.Bundle
import android.util.Log
import android.view.View
import android.view.ViewGroup
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.input.OutputTransformation
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.text.selection.LocalTextSelectionColors
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.ViewCompat
import kotlinx.coroutines.delay

private const val TAG = "HLPROBE"
private fun log(s: String) = Log.i(TAG, s)
private const val TEXT = "plain MARKED plain"
private const val S = 6
private const val E = 12

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val dark = intent.getStringExtra("dark") == "1"
        val mark = if (dark) Color(0xFF594C1A) else Color(0xFFF7E8AF)
        val page = if (dark) Color(0xFF1E1E1E) else Color.White
        setContent {
            MaterialTheme(colorScheme = if (dark) darkColorScheme() else lightColorScheme()) {
                val ink = MaterialTheme.colorScheme.onSurface
                val drawn = remember { TextFieldState(TEXT, TextRange(S, E)) }
                val spanned = remember { TextFieldState(TEXT) }
                val layout = remember { mutableStateOf<(() -> TextLayoutResult?)?>(null) }
                val focus = remember { FocusRequester() }
                val wash = LocalTextSelectionColors.current.backgroundColor
                Column(Modifier.fillMaxSize().background(page).padding(24.dp)) {
                    Box(Modifier
                        .onGloballyPositioned { c ->
                            val p = c.positionInWindow()
                            val box = layout.value?.invoke()?.let { r ->
                                val a = r.getBoundingBox(S); val b = r.getBoundingBox(E - 1)
                                "word px left=${(p.x + a.left).toInt()} top=${(p.y + a.top).toInt()} right=${(p.x + b.right).toInt()} bottom=${(p.y + a.bottom).toInt()}"
                            }
                            if (box != null) log("DRAWN $box wash=${Integer.toHexString(wash.toArgb())} ink=${Integer.toHexString(ink.toArgb())}")
                        }
                        .drawBehind {
                            val r = layout.value?.invoke() ?: return@drawBehind
                            val a = r.getBoundingBox(S); val b = r.getBoundingBox(E - 1)
                            drawRect(mark, Offset(a.left, r.getLineTop(0)), Size(b.right - a.left, r.getLineBottom(0) - r.getLineTop(0)))
                        }) {
                        BasicTextField(
                            drawn,
                            modifier = Modifier.fillMaxWidth().focusRequester(focus),
                            textStyle = TextStyle(fontSize = 24.sp, color = ink),
                            onTextLayout = { get -> layout.value = get },
                        )
                    }
                    BasicTextField(
                        spanned,
                        modifier = Modifier.fillMaxWidth().padding(top = 24.dp),
                        textStyle = TextStyle(fontSize = 24.sp, color = ink),
                        outputTransformation = OutputTransformation { addStyle(SpanStyle(background = mark), S, E) },
                    )
                }
                LaunchedEffect(Unit) {
                    focus.requestFocus()
                    delay(1500)
                    dumpA11y()
                    log("READY")
                }
            }
        }
    }

    /** The virtual nodes the compose view publishes, with every span on their text. */
    private fun dumpA11y() {
        fun find(v: View): View? {
            if (v.javaClass.name.contains("AndroidComposeView")) return v
            if (v is ViewGroup) for (i in 0 until v.childCount) find(v.getChildAt(i))?.let { return it }
            return null
        }
        val view = find(window.decorView) ?: run { log("A11Y no compose view"); return }
        val provider = ViewCompat.getAccessibilityDelegate(view)?.getAccessibilityNodeProvider(view)
        if (provider == null) { log("A11Y no provider"); return }
        var seen = 0
        for (id in 0..200) {
            val info = provider.createAccessibilityNodeInfo(id) ?: continue
            val text = info.text ?: continue
            if (!text.toString().contains("MARKED")) continue
            seen++
            val spans = (text as? android.text.Spanned)?.let { sp ->
                sp.getSpans(0, sp.length, Any::class.java).joinToString { s ->
                    "${s.javaClass.simpleName}[${sp.getSpanStart(s)},${sp.getSpanEnd(s)})" +
                        if (s is android.text.style.BackgroundColorSpan) " #" + Integer.toHexString(s.backgroundColor) else ""
                }
            } ?: "(not Spanned: ${text.javaClass.simpleName})"
            log("A11Y node $id class=${info.className} text='$text' spans=[$spans]")
        }
        log("A11Y nodes with the word: $seen")
    }
}
