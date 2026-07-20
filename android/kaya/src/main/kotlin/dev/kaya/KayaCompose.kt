package dev.kaya

import android.graphics.BitmapFactory
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.unit.dp
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread

/**
 * KayaCompose: the Kotlin half of the Compose backend, the Android
 * sibling of KayaSwiftUI.swift — an interpreter of resolved apply-op
 * records:
 *
 *   create/add_child/mount/destroy -> a snapshot-state node tree
 *   set_prop                       -> observable writes on the nodes
 *   occurrence                     <- Compose onClick -> KayaPresent.emitClicked
 *
 * The pump blocks in nextCommands on its own thread and hops to the UI
 * thread to apply — the doorbell equivalent, no polling, no callbacks
 * across the ABI. Signals, collections, and templates never reach this
 * layer; the core resolves them before the records leave
 * kaya_next_commands. A button's create record carries a click tag —
 * opaque bytes this layer stores and emits verbatim; identity stays a
 * core concern.
 */
class KayaNode(val id: Long, val kind: Int, val tag: ByteArray) {
    var text by mutableStateOf("")
    var checked by mutableStateOf(false)
    var value by mutableStateOf(0.0)
    var minValue by mutableStateOf(0.0)
    var maxValue by mutableStateOf(1.0)
    // The image slot: the decoded bitmap (null is the placeholder
    // class) and its size as the harness's "WxH" observation string
    // ("0x0" before a source lands or after a failed decode).
    var imageBitmap by mutableStateOf<ImageBitmap?>(null)
    var imageSize by mutableStateOf("0x0")
    /**
     * This child's flex weight within its enclosing row/column. 0 is
     * natural size; positive weights divide the leftover main-axis space
     * in proportion. See Prop::Grow in protocol.rs.
     */
    var grow by mutableStateOf(0.0)
    val children = mutableStateListOf<KayaNode>()
}

/**
 * The main-axis extent each node was allocated, by node id — what
 * `expect_shares` reads back.
 *
 * Measured from the laid-out track (onGloballyPositioned on the cell),
 * never from the child's own drawn size: on every backend the layout
 * rect and the drawing box differ, and only the first is what the grow
 * contract talks about.
 */
val kayaMainExtents = HashMap<Long, Double>()

object KayaSceneModel {
    var root by mutableStateOf<KayaNode?>(null)
    val nodes = HashMap<Long, KayaNode>() // UI thread only
    val parents = HashMap<Long, Long>()
    // The focus command's landing spot: the entry's FocusRequester
    // walks it into the platform focus system, and expect_focused
    // reads it back.
    var focusedId by mutableStateOf<Long?>(null)
    // Per-kind registries in creation order (stamped copies included):
    // the harness names targets as kind#index.
    val buttons = ArrayList<KayaNode>()
    val checkboxes = ArrayList<KayaNode>()
    val labels = ArrayList<KayaNode>()
    val entries = ArrayList<KayaNode>()
    val sliders = ArrayList<KayaNode>()
    val images = ArrayList<KayaNode>()
    val columns = ArrayList<KayaNode>()
}

object KayaCompose {
    // Pinned to the KAYA_APPLY_* / KAYA_KIND_* / KAYA_VALUE_* constants
    // in kaya.h.
    private const val APPLY_CREATE = 1
    private const val APPLY_SET_PROP = 2
    private const val APPLY_ADD_CHILD = 3
    private const val APPLY_MOUNT = 4
    private const val APPLY_DESTROY = 5
    private const val APPLY_MOVE_CHILD = 6
    private const val APPLY_COMMAND = 7
    private const val COMMAND_CLEAR = 1
    private const val COMMAND_FOCUS = 2
    const val KIND_COLUMN = 1
    const val KIND_BUTTON = 2
    const val KIND_LABEL = 3
    const val KIND_ENTRY = 4
    const val KIND_ROW = 5
    const val KIND_CHECKBOX = 6
    const val KIND_SLIDER = 7
    const val KIND_IMAGE = 8
    private const val PROP_TEXT = 1
    private const val PROP_CHECKED = 2
    private const val PROP_VALUE = 3
    private const val PROP_MIN = 4
    private const val PROP_MAX = 5
    private const val PROP_SOURCE = 6
    private const val PROP_GROW = 7
    private const val VALUE_BOOL = 1
    private const val VALUE_F64 = 3
    private const val VALUE_STR = 4
    private const val VALUE_BLOB = 5

    /**
     * Start the pump and mount the interpreter. Call from onCreate when
     * [Kaya.attach] returns [Kaya.PRESENT_GUEST].
     */
    @JvmStatic
    fun mount(activity: ComponentActivity) {
        startPump(activity)
        activity.setContent { KayaRoot() }
        if (System.getenv("KAYA_SELFTEST") != null) startSelftest(activity)
    }

    private fun startPump(activity: ComponentActivity) {
        thread(name = "kaya-compose-pump") {
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val length = KayaPresent.nextCommands(buffer)
                if (length == 0) break
                val batch = buffer.copyOf(length)
                // Blob handles are batch-local: the next nextCommands
                // call replaces the core's table, and the UI-thread
                // apply may run after that. Fetch every referenced blob
                // here, on the pump thread, within the batch; the bytes
                // travel with it.
                val blobs = collectBlobs(batch)
                activity.runOnUiThread { apply(batch, blobs) }
            }
        }
    }

    /**
     * Pre-fetch the batch's blob payloads (SET_PROP values of type
     * blob) through [KayaPresent.blobData], keyed by wire handle. Runs
     * on the pump thread, before the next nextCommands call
     * invalidates the handles.
     */
    private fun collectBlobs(batch: ByteArray): Map<Long, ByteArray> {
        val blobs = HashMap<Long, ByteArray>()
        val b = ByteBuffer.wrap(batch).order(ByteOrder.LITTLE_ENDIAN)
        while (b.remaining() >= 8) {
            val start = b.position()
            val size = b.int
            val kind = b.short.toInt()
            b.short // flags
            if (kind == APPLY_SET_PROP) {
                b.long // widget id
                b.int // prop
                b.int // pad
                val type = b.int
                b.int // len
                if (type == VALUE_BLOB) {
                    val handle = b.long
                    KayaPresent.blobData(handle)?.let { blobs[handle] = it }
                }
            }
            b.position(start + size)
        }
        return blobs
    }

    private fun apply(batch: ByteArray, blobs: Map<Long, ByteArray>) {
        val b = ByteBuffer.wrap(batch).order(ByteOrder.LITTLE_ENDIAN)
        while (b.remaining() >= 8) {
            val start = b.position()
            val size = b.int
            val kind = b.short.toInt()
            b.short // flags
            when (kind) {
                APPLY_CREATE -> {
                    val id = b.long
                    val widgetKind = b.int
                    val tagLen = b.int
                    val tag = ByteArray(tagLen)
                    b.get(tag)
                    val node = KayaNode(id, widgetKind, tag)
                    KayaSceneModel.nodes[id] = node
                    when (widgetKind) {
                        KIND_BUTTON -> KayaSceneModel.buttons.add(node)
                        KIND_LABEL -> KayaSceneModel.labels.add(node)
                        KIND_SLIDER -> KayaSceneModel.sliders.add(node)
                        KIND_ENTRY -> KayaSceneModel.entries.add(node)
                        KIND_CHECKBOX -> KayaSceneModel.checkboxes.add(node)
                        KIND_IMAGE -> KayaSceneModel.images.add(node)
                        KIND_COLUMN -> KayaSceneModel.columns.add(node)
                    }
                }
                APPLY_SET_PROP -> {
                    val id = b.long
                    val prop = b.int
                    b.int // pad
                    when (prop) {
                        PROP_TEXT -> KayaSceneModel.nodes[id]!!.text = readString(b)
                        PROP_CHECKED -> KayaSceneModel.nodes[id]!!.checked = readBool(b)
                        PROP_VALUE -> KayaSceneModel.nodes[id]!!.value = readF64(b)
                        PROP_MIN -> KayaSceneModel.nodes[id]!!.minValue = readF64(b)
                        PROP_MAX -> KayaSceneModel.nodes[id]!!.maxValue = readF64(b)
                        PROP_GROW -> KayaSceneModel.nodes[id]!!.grow = readF64(b)
                        PROP_SOURCE -> {
                            // The value's payload is a u64 batch-local
                            // handle; the pump prefetched the bytes into
                            // `blobs`. Native decode:
                            // BitmapFactory.decodeByteArray; a null
                            // bitmap is the placeholder class, never a
                            // crash — imageSize stays "0x0".
                            val handle = readBlobHandle(b)
                            val node = KayaSceneModel.nodes[id]!!
                            val bytes = blobs[handle]
                            val bitmap = bytes?.let {
                                BitmapFactory.decodeByteArray(it, 0, it.size)
                            }
                            if (bitmap != null) {
                                node.imageBitmap = bitmap.asImageBitmap()
                                node.imageSize = "${bitmap.width}x${bitmap.height}"
                            } else {
                                node.imageBitmap = null
                                node.imageSize = "0x0"
                            }
                        }
                        else -> error("kaya: unknown prop $prop")
                    }
                }
                APPLY_ADD_CHILD -> {
                    val parent = b.long
                    val child = b.long
                    KayaSceneModel.nodes[parent]!!.children
                        .add(KayaSceneModel.nodes[child]!!)
                    KayaSceneModel.parents[child] = parent
                }
                APPLY_MOUNT -> {
                    b.long // window: the default until the window vocabulary
                    val root = b.long
                    KayaSceneModel.root = KayaSceneModel.nodes[root]
                }
                APPLY_MOVE_CHILD -> {
                    val parent = b.long
                    val child = b.long
                    val before = b.long
                    val parentNode = KayaSceneModel.nodes[parent]!!
                    val childNode = KayaSceneModel.nodes[child]!!
                    parentNode.children.removeAll { it.id == child }
                    // before == 0L: the end sentinel (widget ids start at 1).
                    val at = if (before != 0L)
                        parentNode.children.indexOfFirst { it.id == before } else -1
                    if (at >= 0) parentNode.children.add(at, childNode)
                    else parentNode.children.add(childNode)
                }
                APPLY_DESTROY -> {
                    val id = b.long
                    KayaSceneModel.parents.remove(id)?.let { parent ->
                        KayaSceneModel.nodes[parent]?.children?.removeAll { it.id == id }
                    }
                    KayaSceneModel.nodes.remove(id)
                }
                APPLY_COMMAND -> {
                    val id = b.long
                    val command = b.int
                    b.int // pad
                    when (command) {
                        COMMAND_CLEAR -> {
                            // Model-driven, like set_text: the node's
                            // text is the field's text, and the app
                            // hears the empty edit through the same
                            // emission the TextField's change would
                            // make.
                            val node = KayaSceneModel.nodes[id]!!
                            node.text = ""
                            KayaPresent.emitTextChanged(node.tag, "")
                        }
                        COMMAND_FOCUS -> KayaSceneModel.focusedId = id
                        else -> error("kaya: unknown command $command")
                    }
                }
            }
            b.position(start + size)
        }
    }

    private fun readString(b: ByteBuffer): String {
        val type = b.int
        val len = b.int
        val bytes = ByteArray(len)
        b.get(bytes)
        check(type == VALUE_STR) { "kaya: expected a string value, got type $type" }
        return String(bytes, Charsets.UTF_8)
    }

    private fun readF64(b: ByteBuffer): Double {
        val type = b.int
        b.int // len
        check(type == VALUE_F64) { "kaya: expected an f64 value, got type $type" }
        return b.double
    }

    private fun readBool(b: ByteBuffer): Boolean {
        val type = b.int
        b.int // len
        check(type == VALUE_BOOL) { "kaya: expected a bool value, got type $type" }
        return b.get() != 0.toByte()
    }

    private fun readBlobHandle(b: ByteBuffer): Long {
        val type = b.int
        b.int // len
        check(type == VALUE_BLOB) { "kaya: expected a blob value, got type $type" }
        return b.long
    }

    /**
     * The interaction harness's Kotlin interpreter: the same
     * line-oriented grammar the Rust backends embed from tools/scenes
     * (settle / click / toggle / set_value / set_text / expect /
     * expect_order / expect_focused,
     * targets as kind#index, `;` accepted as a newline stand-in — the
     * intent-extra transport cannot carry newlines). Steps drive the
     * node tree exactly as a gesture would: flip the snapshot state,
     * emit through KayaPresent. Results go to logcat; halt rather than
     * exit so no teardown hook races the render threads.
     */
    private fun startSelftest(activity: ComponentActivity) {
        val script = System.getenv("KAYA_SELFTEST_SCRIPT")
        if (script == null) {
            Log.e("kaya", "KAYA_SELFTEST: FAILED (no KAYA_SELFTEST_SCRIPT in the environment)")
            activity.finishAndRemoveTask()
            Runtime.getRuntime().halt(1)
            return
        }
        thread(name = "kaya-selftest") { runScript(activity, script) }
    }

    private fun <T> onUi(activity: ComponentActivity, f: () -> T): T {
        var out: T? = null
        val done = java.util.concurrent.CountDownLatch(1)
        activity.runOnUiThread {
            out = f()
            done.countDown()
        }
        done.await()
        @Suppress("UNCHECKED_CAST")
        return out as T
    }

    /**
     * Resolves `kind#index` against the registry the verb reads,
     * mirroring harness.rs's parse_target: a kind that names a
     * different registry, a malformed index, or one out of range is a
     * loud step failure — never an exception, and never a silently
     * misresolved read (`row#0` once indexed the COLUMNS registry,
     * which is the false-verdict class).
     */
    private fun target(spec: String, kind: String, registry: List<KayaNode>): KayaNode? {
        val bits = spec.split('#')
        if (bits.size != 2 || bits[0] != kind) return null
        if (bits[1] == "last") return registry.lastOrNull()
        val i = bits[1].toIntOrNull() ?: return null
        return registry.getOrNull(i)
    }

    private fun quoted(parts: List<String>): String =
        parts.joinToString(" ").removeSurrounding("\"")

    private fun runScript(activity: ComponentActivity, script: String) {
        val observed = ArrayList<String>()
        val failures = ArrayList<String>()
        val start = System.nanoTime()
        Log.i("kaya", "KAYA_HARNESS: epoch ${System.currentTimeMillis()}")
        for (rawLine in script.split('\n')) {
            val trimmedLine = rawLine.trim()
            if (trimmedLine.isEmpty() || trimmedLine.startsWith("#")) continue
            for (raw in trimmedLine.split(';')) {
                val line = raw.trim()
                if (line.isEmpty() || line.startsWith("#")) continue
                val parts = line.split(' ').filter { it.isNotEmpty() }
                val offset = (System.nanoTime() - start) / 1_000_000
                Log.i("kaya", "KAYA_HARNESS: +${offset}ms $line")
                when (parts[0]) {
                    "settle" -> Thread.sleep(parts[1].toLong())
                    "click" -> {
                        val ok = onUi(activity) {
                            target(parts[1], "button", KayaSceneModel.buttons)
                                ?.also { KayaPresent.emitClicked(it.tag) } != null
                        }
                        if (!ok) failures.add("no such target ${parts[1]}")
                    }
                    "toggle" -> {
                        val ok = onUi(activity) {
                            target(parts[1], "checkbox", KayaSceneModel.checkboxes)?.also { node ->
                                node.checked = parts[2] == "on"
                                KayaPresent.emitToggled(node.tag, node.checked)
                            } != null
                        }
                        if (!ok) failures.add("no such target ${parts[1]}")
                    }
                    "set_value" -> {
                        val ok = onUi(activity) {
                            target(parts[1], "slider", KayaSceneModel.sliders)?.also { node ->
                                node.value = parts[2].toDouble()
                                KayaPresent.emitValueChanged(node.tag, node.value)
                            } != null
                        }
                        if (!ok) failures.add("no such target ${parts[1]}")
                    }
                    "set_text" -> {
                        val ok = onUi(activity) {
                            target(parts[1], "entry", KayaSceneModel.entries)?.also { node ->
                                node.text = quoted(parts.drop(2))
                                KayaPresent.emitTextChanged(node.tag, node.text)
                            } != null
                        }
                        if (!ok) failures.add("no such target ${parts[1]}")
                    }
                    "expect" -> {
                        val want = quoted(parts.drop(2))
                        // The target kind picks the observation: an
                        // entry reads the field's own displayed text,
                        // an image its decoded size ("WxH"/"0x0"),
                        // everything else reads label text —
                        // harness.rs's routing.
                        val got = onUi(activity) {
                            if (parts[1].startsWith("entry"))
                                target(parts[1], "entry", KayaSceneModel.entries)?.text
                            else if (parts[1].startsWith("image"))
                                target(parts[1], "image", KayaSceneModel.images)?.imageSize
                            else target(parts[1], "label", KayaSceneModel.labels)?.text
                        }
                        when {
                            got == null -> failures.add("no such target ${parts[1]}")
                            got == want -> observed.add(got)
                            else -> failures.add("${parts[1]} reads \"$got\", wanted \"$want\"")
                        }
                    }
                    "expect_focused" -> {
                        // The model's focusedId is the observation the
                        // focus command lands as (the entry's
                        // FocusRequester walks it into the platform).
                        // Counts as an expect for the zero-expect
                        // rule, exactly as in harness.rs.
                        val focused = onUi(activity) {
                            target(parts[1], "entry", KayaSceneModel.entries)
                                ?.let { KayaSceneModel.focusedId == it.id }
                        }
                        when (focused) {
                            true -> observed.add("${parts[1]} focused")
                            false -> failures.add("${parts[1]} does not hold focus")
                            null -> failures.add("no such target ${parts[1]}")
                        }
                    }
                    "expect_order" -> {
                        // Child order as the interpreter's tree holds
                        // it — the registries are creation-ordered and
                        // cannot observe a move.
                        val want = quoted(parts.drop(2))
                        val got = onUi(activity) {
                            target(parts[1], "column", KayaSceneModel.columns)?.children
                                ?.filter { it.kind == KIND_LABEL }
                                ?.joinToString("|") { it.text }
                        }
                        when {
                            got == null -> failures.add("no such target ${parts[1]}")
                            got == want -> observed.add(got)
                            else ->
                                failures.add("${parts[1]} children read \"$got\", wanted \"$want\"")
                        }
                    }
                    "expect_shares" -> {
                        // The container's children as whole-percentage
                        // shares of their sum — the observation grow
                        // weights are verified by. Percent of the
                        // children's sum and not of the container, so
                        // spacing and padding (platform metrics both)
                        // stay out of the number; the rounding matches
                        // harness::shares exactly, because expect_shares
                        // compares byte-for-byte across all seven
                        // backends.
                        val want = quoted(parts.drop(2))
                        val got = onUi(activity) {
                            target(parts[1], "column", KayaSceneModel.columns)?.let { container ->
                                val extents = container.children
                                    .map { kayaMainExtents[it.id] ?: 0.0 }
                                val total = extents.sum()
                                if (total <= 0.0) {
                                    ""
                                } else {
                                    extents.joinToString(",") {
                                        Math.round((it / total) * 100).toString()
                                    }
                                }
                            }
                        }
                        when {
                            got == null -> failures.add("no such target ${parts[1]}")
                            got == want -> observed.add(got)
                            else -> failures.add("${parts[1]} splits \"$got\", wanted \"$want\"")
                        }
                    }
                    else -> failures.add("unknown step $line")
                }
            }
        }
        if (failures.isEmpty() && observed.isEmpty()) {
            failures.add("script has no expects")
        }
        val code = if (failures.isEmpty()) {
            Log.i("kaya", "KAYA_SELFTEST: OK (${observed.joinToString(", ")})")
            0
        } else {
            Log.e("kaya", "KAYA_SELFTEST: FAILED (${failures.joinToString("; ")})")
            1
        }
        activity.runOnUiThread {
            activity.finishAndRemoveTask()
            Runtime.getRuntime().halt(code)
        }
    }
}

/** The interpreter's render: the node tree as Compose declarations. */
@Composable
fun KayaRender(node: KayaNode) {
    when (node.kind) {
        KayaCompose.KIND_COLUMN ->
            // Normalized default: children packed to the top at natural
            // size, leading-aligned (Alignment.Start), 8 dp between them.
            Column(
                verticalArrangement = Arrangement.spacedBy(8.dp),
                horizontalAlignment = Alignment.Start,
            ) {
                node.children.forEach { child ->
                    // Every child rides in a cell, whether it grows or
                    // not: the cell is what carries Modifier.weight —
                    // Compose's native per-child weight, which already
                    // means "divide the leftover in proportion", so the
                    // contract needs no arithmetic here — and it is also
                    // the track whose measured height expect_shares
                    // reads. A weightless cell just wraps its content.
                    var cell = Modifier.onGloballyPositioned {
                        kayaMainExtents[child.id] = it.size.height.toDouble()
                    }
                    if (child.grow > 0) cell = cell.weight(child.grow.toFloat())
                    Box(cell) { KayaRender(child) }
                }
            }
        KayaCompose.KIND_BUTTON ->
            Button(onClick = { KayaPresent.emitClicked(node.tag) }) {
                Text(node.text)
            }
        KayaCompose.KIND_ROW ->
            // Normalized default: children packed to the leading edge at
            // natural size, top-aligned (Alignment.Top), 8 dp between them.
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.Top,
            ) {
                node.children.forEach { child ->
                    var cell = Modifier.onGloballyPositioned {
                        kayaMainExtents[child.id] = it.size.width.toDouble()
                    }
                    if (child.grow > 0) cell = cell.weight(child.grow.toFloat())
                    Box(cell) { KayaRender(child) }
                }
            }
        KayaCompose.KIND_LABEL -> Text(node.text)
        KayaCompose.KIND_CHECKBOX ->
            // Uncontrolled toward the app, the entry's shape: the node
            // mirrors the box's state (Compose needs it), and every
            // flip is emitted with the box's identity tag. The caption
            // rides beside the box, the labeled-checkbox idiom.
            Row(
                horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterHorizontally),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Checkbox(
                    checked = node.checked,
                    onCheckedChange = { newValue ->
                        node.checked = newValue
                        KayaPresent.emitToggled(node.tag, newValue)
                    },
                )
                Text(node.text)
            }
        KayaCompose.KIND_SLIDER ->
            // Uncontrolled toward the app, the entry's shape: the node
            // mirrors the slider's position (Compose needs the state),
            // and every move is emitted with the slider's identity tag.
            Slider(
                value = node.value.toFloat(),
                onValueChange = { newValue ->
                    node.value = newValue.toDouble()
                    KayaPresent.emitValueChanged(node.tag, newValue.toDouble())
                },
                valueRange = node.minValue.toFloat()..node.maxValue.toFloat(),
            )
        KayaCompose.KIND_IMAGE ->
            // Fixed to the decoded bitmap's intrinsic size (Image
            // defaults to it), matching the harness's size
            // observation; null is the placeholder class — nothing
            // renders.
            node.imageBitmap?.let { bitmap ->
                Image(bitmap = bitmap, contentDescription = null)
            }
        KayaCompose.KIND_ENTRY -> {
            // Uncontrolled toward the app: the node mirrors what the
            // user types (Compose needs the state), and every edit is
            // emitted with the entry's identity tag for the app to fold
            // into its own model — nothing here is read back. Focus is
            // model-driven the same way: the focus command lands as the
            // scene's focusedId, walked into the platform focus system
            // here, and a user-driven change flows back so the model
            // stays truthful.
            val focusRequester = remember { FocusRequester() }
            TextField(
                value = node.text,
                onValueChange = { newValue ->
                    node.text = newValue
                    KayaPresent.emitTextChanged(node.tag, newValue)
                },
                modifier = Modifier
                    .focusRequester(focusRequester)
                    // Gain-only back-propagation: onFocusChanged also
                    // fires with the initial unfocused state at attach,
                    // and a loss branch there would clear a focusedId
                    // the LaunchedEffect below has not yet requested.
                    .onFocusChanged { state ->
                        if (state.isFocused) KayaSceneModel.focusedId = node.id
                    },
            )
            LaunchedEffect(KayaSceneModel.focusedId) {
                if (KayaSceneModel.focusedId == node.id) focusRequester.requestFocus()
            }
        }
    }
}

@Composable
fun KayaRoot() {
    // Normalized default: the root is pinned to the top-leading corner,
    // not centered, so the scene packs into the top-left like AppKit/SwiftUI.
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.TopStart) {
        KayaSceneModel.root?.let { KayaRender(it) }
    }
}
