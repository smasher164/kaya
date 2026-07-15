package dev.kaya

import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
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
    val children = mutableStateListOf<KayaNode>()
}

object KayaSceneModel {
    var root by mutableStateOf<KayaNode?>(null)
    val nodes = HashMap<Long, KayaNode>() // UI thread only
    val parents = HashMap<Long, Long>()
    var firstButton: KayaNode? = null
    var lastButton: KayaNode? = null
    var firstLabel: KayaNode? = null
    var firstEntry: KayaNode? = null
    var firstCheckbox: KayaNode? = null
}

object KayaCompose {
    // Pinned to the KAYA_APPLY_* / KAYA_KIND_* / KAYA_VALUE_* constants
    // in kaya.h.
    private const val APPLY_CREATE = 1
    private const val APPLY_SET_PROP = 2
    private const val APPLY_ADD_CHILD = 3
    private const val APPLY_MOUNT = 4
    private const val APPLY_DESTROY = 5
    const val KIND_COLUMN = 1
    const val KIND_BUTTON = 2
    const val KIND_LABEL = 3
    const val KIND_ENTRY = 4
    const val KIND_ROW = 5
    const val KIND_CHECKBOX = 6
    private const val PROP_TEXT = 1
    private const val PROP_CHECKED = 2
    private const val VALUE_BOOL = 1
    private const val VALUE_STR = 4

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
                activity.runOnUiThread { apply(batch) }
            }
        }
    }

    private fun apply(batch: ByteArray) {
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
                    if (widgetKind == KIND_BUTTON) {
                        if (KayaSceneModel.firstButton == null) {
                            KayaSceneModel.firstButton = node
                        }
                        KayaSceneModel.lastButton = node
                    }
                    if (widgetKind == KIND_LABEL && KayaSceneModel.firstLabel == null) {
                        KayaSceneModel.firstLabel = node
                    }
                    if (widgetKind == KIND_ENTRY && KayaSceneModel.firstEntry == null) {
                        KayaSceneModel.firstEntry = node
                    }
                    if (widgetKind == KIND_CHECKBOX && KayaSceneModel.firstCheckbox == null) {
                        KayaSceneModel.firstCheckbox = node
                    }
                }
                APPLY_SET_PROP -> {
                    val id = b.long
                    val prop = b.int
                    b.int // pad
                    when (prop) {
                        PROP_TEXT -> KayaSceneModel.nodes[id]!!.text = readString(b)
                        PROP_CHECKED -> KayaSceneModel.nodes[id]!!.checked = readBool(b)
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
                APPLY_DESTROY -> {
                    val id = b.long
                    KayaSceneModel.parents.remove(id)?.let { parent ->
                        KayaSceneModel.nodes[parent]?.children?.removeAll { it.id == id }
                    }
                    KayaSceneModel.nodes.remove(id)
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

    private fun readBool(b: ByteBuffer): Boolean {
        val type = b.int
        b.int // len
        check(type == VALUE_BOOL) { "kaya: expected a bool value, got type $type" }
        return b.get() != 0.toByte()
    }

    /**
     * Drives the round trip without a human, matching every backend's
     * selftest: two clicks on the scene's driver button (stamping
     * groups, items, and the When), one on the most recently stamped
     * button, and the status label proves the whole loop. Results go to
     * logcat; halt rather than exit so no teardown hook races the
     * render threads.
     */
    private fun startSelftest(activity: ComponentActivity) {
        if (System.getenv("KAYA_SELFTEST") == "entry") {
            startEntrySelftest(activity)
            return
        }
        if (System.getenv("KAYA_SELFTEST") == "gallery") {
            startGallerySelftest(activity)
            return
        }
        thread(name = "kaya-selftest") {
            Thread.sleep(1500)
            KayaSceneModel.firstButton?.let { KayaPresent.emitClicked(it.tag) }
            Thread.sleep(300)
            KayaSceneModel.firstButton?.let { KayaPresent.emitClicked(it.tag) }
            Thread.sleep(400)
            KayaSceneModel.lastButton?.let { KayaPresent.emitClicked(it.tag) }
            Thread.sleep(700)
            activity.runOnUiThread {
                val text = KayaSceneModel.firstLabel?.text ?: "(no label)"
                val code = if (text == "removed g2/a, 0 left") {
                    Log.i("kaya", "KAYA_SELFTEST: OK ($text)")
                    0
                } else {
                    Log.e("kaya", "KAYA_SELFTEST: FAILED (label reads $text)")
                    1
                }
                activity.finishAndRemoveTask()
                Runtime.getRuntime().halt(code)
            }
        }
    }

    /**
     * The entry scene's round trip (KAYA_SELFTEST=entry): drive the
     * same emission path a keystroke takes, click add, read the status
     * label.
     */
    private fun startEntrySelftest(activity: ComponentActivity) {
        thread(name = "kaya-selftest") {
            Thread.sleep(1500)
            activity.runOnUiThread {
                KayaSceneModel.firstEntry?.let { entry ->
                    entry.text = "milk"
                    KayaPresent.emitTextChanged(entry.tag, "milk")
                }
            }
            Thread.sleep(400)
            KayaSceneModel.firstButton?.let { KayaPresent.emitClicked(it.tag) }
            Thread.sleep(700)
            activity.runOnUiThread {
                val text = KayaSceneModel.firstLabel?.text ?: "(no label)"
                val code = if (text == "added milk, 1 total") {
                    Log.i("kaya", "KAYA_SELFTEST: OK ($text)")
                    0
                } else {
                    Log.e("kaya", "KAYA_SELFTEST: FAILED (label reads $text)")
                    1
                }
                activity.finishAndRemoveTask()
                Runtime.getRuntime().halt(code)
            }
        }
    }

    /**
     * The gallery scene's round trip (KAYA_SELFTEST=gallery): drive the
     * same emission path a tap takes — flip the node, emit toggled —
     * then read the status label.
     */
    private fun startGallerySelftest(activity: ComponentActivity) {
        thread(name = "kaya-selftest") {
            Thread.sleep(1500)
            activity.runOnUiThread {
                KayaSceneModel.firstCheckbox?.let { box ->
                    box.checked = true
                    KayaPresent.emitToggled(box.tag, true)
                }
            }
            Thread.sleep(700)
            activity.runOnUiThread {
                val text = KayaSceneModel.firstLabel?.text ?: "(no label)"
                val code = if (text == "urgent: true") {
                    Log.i("kaya", "KAYA_SELFTEST: OK ($text)")
                    0
                } else {
                    Log.e("kaya", "KAYA_SELFTEST: FAILED (label reads $text)")
                    1
                }
                activity.finishAndRemoveTask()
                Runtime.getRuntime().halt(code)
            }
        }
    }
}

/** The interpreter's render: the node tree as Compose declarations. */
@Composable
fun KayaRender(node: KayaNode) {
    when (node.kind) {
        KayaCompose.KIND_COLUMN ->
            Column(
                verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                node.children.forEach { KayaRender(it) }
            }
        KayaCompose.KIND_BUTTON ->
            Button(onClick = { KayaPresent.emitClicked(node.tag) }) {
                Text(node.text)
            }
        KayaCompose.KIND_ROW ->
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                node.children.forEach { KayaRender(it) }
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
        KayaCompose.KIND_ENTRY ->
            // Uncontrolled toward the app: the node mirrors what the
            // user types (Compose needs the state), and every edit is
            // emitted with the entry's identity tag for the app to fold
            // into its own model — nothing here is read back.
            TextField(
                value = node.text,
                onValueChange = { newValue ->
                    node.text = newValue
                    KayaPresent.emitTextChanged(node.tag, newValue)
                },
            )
    }
}

@Composable
fun KayaRoot() {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        KayaSceneModel.root?.let { KayaRender(it) }
    }
}
