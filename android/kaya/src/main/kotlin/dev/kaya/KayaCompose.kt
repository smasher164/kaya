package dev.kaya

import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Button
import androidx.compose.material3.Text
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
    val children = mutableStateListOf<KayaNode>()
}

object KayaSceneModel {
    var root by mutableStateOf<KayaNode?>(null)
    val nodes = HashMap<Long, KayaNode>() // UI thread only
    val parents = HashMap<Long, Long>()
    var firstButton: KayaNode? = null
    var lastButton: KayaNode? = null
    var firstLabel: KayaNode? = null
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
                }
                APPLY_SET_PROP -> {
                    val id = b.long
                    b.int // prop: text is the only one so far
                    b.int // pad
                    KayaSceneModel.nodes[id]!!.text = readString(b)
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

    /**
     * Drives the round trip without a human, matching every backend's
     * selftest: two clicks on the scene's driver button (stamping
     * groups, items, and the When), one on the most recently stamped
     * button, and the status label proves the whole loop. Results go to
     * logcat; halt rather than exit so no teardown hook races the
     * render threads.
     */
    private fun startSelftest(activity: ComponentActivity) {
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
                val code = if (text == "removed g2/a") {
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
        KayaCompose.KIND_LABEL -> Text(node.text)
    }
}

@Composable
fun KayaRoot() {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        KayaSceneModel.root?.let { KayaRender(it) }
    }
}
