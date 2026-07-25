package dev.kaya

import android.graphics.BitmapFactory
import android.util.Log
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.Image
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.IconButton
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TopAppBar
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
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInParent
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread
import kotlinx.coroutines.launch

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
    // The accessibility identifier and label (universal props). The
    // identifier is never spoken — it lowers to Modifier.testTag, which
    // is what surfaces as the automation key — while the label IS what
    // TalkBack reads (contentDescription). Empty means unset: the
    // platform keeps whatever it derives from the control's own content.
    var a11yId by mutableStateOf("")
    var a11yLabel by mutableStateOf("")
    var checked by mutableStateOf(false)
    var value by mutableStateOf(0.0)
    var minValue by mutableStateOf(0.0)
    var maxValue by mutableStateOf(1.0)
    // The image slot: the decoded bitmap (null is the placeholder
    // class) and its size as the harness's "WxH" observation string
    // ("0x0" before a source lands or after a failed decode).
    var imageBitmap by mutableStateOf<ImageBitmap?>(null)
    var imageSize by mutableStateOf("0x0")
    // The scroll viewport's REAL state (scroll nodes only): the
    // toolkit's own ScrollState is both the observation source
    // (maxValue > 0 = overflow; value == maxValue = at end) and the
    // API scroll_end drives.
    val scrollState = androidx.compose.foundation.ScrollState(0)
    // Progress-only: the platform's activity mode (value carries the
    // determinate fraction, reused from the slider).
    var indeterminate by mutableStateOf(false)
    var columns by mutableStateOf(1)
    /**
     * This child's flex weight within its enclosing row/column. 0 is
     * natural size; positive weights divide the leftover main-axis space
     * in proportion. See Prop::Grow in protocol.rs.
     */
    var grow by mutableStateOf(0.0)
    /**
     * This container's inter-child gap on its main axis (containers
     * only; the normalized default is 8 dp). See Prop::Spacing.
     */
    var spacing by mutableStateOf(8.0)
    /**
     * This container's cross-axis child placement (containers only;
     * wire values of the align spec enum; 0 = start, the normalized
     * default). See Prop::Align.
     */
    var align by mutableStateOf(0L)
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

/**
 * The main-axis extent each CONTAINER rendered at, by node id — what
 * `expect_fills` compares its children's tracks against. Same
 * measured-geometry discipline as the track extents.
 */
val kayaContainerExtents = HashMap<Long, Double>()

/**
 * Cross-axis observations for expect_aligned: each container's cross
 * extent, each cell's cross (start, extent) from positionInParent,
 * and each text child's baseline offset from its own top (a font
 * metric, pass-invariant) captured by a layout modifier.
 */
val kayaContainerCross = HashMap<Long, Double>()
val kayaCrossRects = HashMap<Long, Pair<Double, Double>>()
val kayaBaselineOffsets = HashMap<Long, Double>()

/**
 * The display density, recorded at composition (the runner thread has
 * none to convert with): expect_fills turns each container's dp
 * spacing into the pixels its measured tracks are laid out in.
 * Written by KayaRoot.
 */
var kayaDensity = 1.0

/**
 * The mounted root's laid-out size and the area offered to it — what
 * `expect_root_fills` compares. Both read from onGloballyPositioned:
 * the offer from KayaRoot's fillMaxSize box, the root from the wrapper
 * hugging the mounted container.
 */
var kayaRootSize = androidx.compose.ui.unit.IntSize.Zero
var kayaAvailableSize = androidx.compose.ui.unit.IntSize.Zero

object KayaSceneModel {
    var root by mutableStateOf<KayaNode?>(null)
    // The primary surface's properties. The title materializes as the
    // Activity task label; width/height record the advisory size
    // request only — the system owns surface geometry on Android
    // (DESIGN.md, Presentation contexts).
    var windowTitle: String = ""
    var windowWidth: Double? = null
    var windowHeight: Double? = null
    val nodes = HashMap<Long, KayaNode>() // UI thread only
    val parents = HashMap<Long, Long>()
    // The focus command's landing spot: the entry's FocusRequester
    // walks it into the platform focus system, and expect_focused
    // reads it back.
    var focusedId by mutableStateOf<Long?>(null)
    // The live modal alert (one per process): identity + spec for the
    // M3 dialog and the runner's reads; null = none. The fields
    // change together with alertId, which is the recomposition key.
    var alertId by mutableStateOf<Long?>(null)
    var alertTitle: String = ""
    var alertMessage: String = ""
    var alertActions: List<String> = emptyList()
    var alertCancel: String = ""
    // The primary surface's navigation stack, bottom to top
    // (DESIGN.md, Navigation): the core owns the stack; exactly one
    // entry visible (the top; the root when empty). Android has one
    // surface, so this is THE stack.
    val navEntries = androidx.compose.runtime.mutableStateListOf<KayaNavEntry>()
    val navIndex = HashMap<Long, KayaNavEntry>()
    // The window's section set (add order) and selection; non-empty
    // sections render as the M3 bottom NavigationBar — the phones'
    // physics regardless of the ADVISORY hint, which is recorded only.
    val sections = androidx.compose.runtime.mutableStateListOf<KayaSection>()
    val sectionIndex = HashMap<Long, KayaSection>()
    var selectedSection by mutableStateOf<Long?>(null)
    var sectionsPresentation: Long = 0
    // The window's command catalog (window 0 — this host's one
    // surface) in menubar-append order, plus every menu item by id.
    // Menu items are their OWN id space (c_menu_item), never widget,
    // node, or surface ids (DESIGN.md, Menus).
    val menuItems = HashMap<Long, KayaMenuItem>() // UI thread only
    val menubar = androidx.compose.runtime.mutableStateListOf<KayaMenuItem>()
    // The window's live FORM FACTOR and the catalog lowering that
    // ACTUALLY rendered, the two halves expect_menu_presentation reads
    // (DESIGN.md, "Form factor and adaptivity"). The adaptivity axis is
    // the window's size class, never the operating system. Nothing
    // derives one of these from the other: deriving would make the
    // harness verb agree with the lowering by construction, and the
    // failure being gated is exactly the two disagreeing.
    var formFactor = "unknown" // unknown | compact | regular
    var menuPresentation = "none" // none | bar | overflow
    // Context catalogs by anchored WIDGET id. Each attach APPENDS one
    // root — a widget's roots ACCUMULATE in attach order (the bindings
    // emit one attach per root), never replace. A template attachment
    // arrives once per stamped copy, carrying that copy's key path —
    // the noun every activation from the anchor stamps. Observable so
    // an attach landing after first composition still wraps its node.
    val contextMenus =
        androidx.compose.runtime.mutableStateMapOf<Long, KayaContextAttachment>()
    // The OPEN context menu's anchor widget. The long-press gesture
    // and the harness's context_open drive this SAME state (one
    // presentation route); menu_activate resolves against it, and
    // closing — dismissal or a leaf firing — clears it.
    var openContextWidget by mutableStateOf<Long?>(null)
    // Per-kind registries in creation order (stamped copies included):
    // the harness names targets as kind#index.
    val buttons = ArrayList<KayaNode>()
    val checkboxes = ArrayList<KayaNode>()
    val labels = ArrayList<KayaNode>()
    val entries = ArrayList<KayaNode>()
    val sliders = ArrayList<KayaNode>()
    val images = ArrayList<KayaNode>()
    val columns = ArrayList<KayaNode>()
    val rows = ArrayList<KayaNode>()
    val scrolls = ArrayList<KayaNode>()
    val progresses = ArrayList<KayaNode>()
    val selects = ArrayList<KayaNode>()
    val radios = ArrayList<KayaNode>()
    val grids = ArrayList<KayaNode>()
    val textareas = ArrayList<KayaNode>()
    // Grid cell leading edges by child node id, grid-local (recorded
    // at place time): the expect_grid_columns observation clusters
    // these — geometry, never the model's columns copy.
    val cellMinX = HashMap<Long, Int>()
}

/** One section: a peer root in the primary window's section set —
 * presentation context, not lifecycle: ALL retained, never destroyed
 * (a section dies only with its window, and this host has one).
 * Carries its own navigation stack: stacks are per-surface
 * (DESIGN.md, Sections). */
class KayaSection(val id: Long) {
    var root by mutableStateOf<KayaNode?>(null)
    var title by mutableStateOf("")
    val entries = androidx.compose.runtime.mutableStateListOf<KayaNavEntry>()
}

/** One navigation entry: a pushed scene root, retained while covered,
 * destroyed at pop. interceptBack is the close-veto class transplanted
 * to POP. */
class KayaNavEntry(val id: Long) {
    var root by mutableStateOf<KayaNode?>(null)
    var title by mutableStateOf("")
    var interceptBack by mutableStateOf(false)
}

/** One menu item — a VERB, never a place (DESIGN.md, Menus). All
 * mutable props are snapshot state: label/enabled writes recompose
 * live, and a catalog rebuild recomputes promotion automatically
 * because the promoted walk reads observable children/primary. This
 * model is also the backend's user-state mirror: a user toggle/radio
 * pick lands in checked/value here (and emits), the guest deliberately
 * may not echo it back, and an unrelated prop write must not clobber
 * it. */
class KayaMenuItem(val id: Long, val kind: Int) {
    var label by mutableStateOf("")
    // Own enablement only; what a row shows is the EFFECTIVE state —
    // an item under a disabled grouping node reads disabled and lifts
    // when the ancestor does (kayaMenuEffectivelyEnabled).
    var enabled by mutableStateOf(true)
    // Toggle only: the Checkbox contract (programmatic writes QUIET).
    var checked by mutableStateOf(false)
    // Radio group only: the Choice contract's integral option index.
    var value by mutableStateOf(0.0)
    // Action only: the phone-promotion hint (inert on desktops).
    var primary by mutableStateOf(false)
    // Window-anchored action only: the canonical wire spelling; the
    // catalog walk IS the dispatch table.
    var shortcut by mutableStateOf("")
    /// A standard-command role, "" = none. Recorded for parity; this
    /// host has no dress-owned menu to relocate an item into.
    var role by mutableStateOf("")
    // Optional icon blob, decoded like Image; promoted bar actions
    // show it, overflow rows stay textual (native menu dress).
    var iconBitmap by mutableStateOf<ImageBitmap?>(null)
    // Single-parent (the root validates); set at append. Bar-level
    // items keep null.
    var parent: KayaMenuItem? = null
    val children = mutableStateListOf<KayaMenuItem>()
}

/** A context catalog attachment: the anchored ROOTS in attach order —
 * every CONTEXT_ATTACH(_NODE) appends one root; roots accumulate,
 * never replace (an observable list, so a late root joins a rendered
 * menu) — plus the anchor copy's raw wire key path `{ u32 count; u32
 * reserved; count values }` as CONTEXT_ATTACH_NODE delivered it,
 * handed back VERBATIM as the noun of every emission from this anchor
 * (empty for a live widget). */
class KayaContextAttachment {
    val roots = androidx.compose.runtime.mutableStateListOf<KayaMenuItem>()
    var noun: ByteArray = ByteArray(0)
}

object KayaCompose {
    // Pinned to the KAYA_APPLY_* / KAYA_KIND_* / KAYA_VALUE_* constants
    // in kaya.h.
    // The protocol fingerprint this interpreter was written against
    // (KAYA_SPEC_HASH); asserted against the core at mount. check-verbs
    // holds the SOURCE current, but only the runtime assert catches a
    // stale compiled APK against a new libkaya.
    // ULong: the fingerprint's high bit is fair game, and a Kotlin
    // Long hex literal cannot express it.
    private const val SPEC_HASH: ULong = 0x55065c142eebf54buL

    private const val APPLY_CREATE = 1
    private const val APPLY_SET_PROP = 2
    private const val APPLY_ADD_CHILD = 3
    private const val APPLY_MOUNT = 4
    private const val APPLY_DESTROY = 5
    private const val APPLY_MOVE_CHILD = 6
    private const val APPLY_COMMAND = 7
    private const val APPLY_SET_WINDOW_PROP = 8
    private const val APPLY_CREATE_WINDOW = 9
    private const val APPLY_DESTROY_WINDOW = 10
    private const val APPLY_PRESENT_ALERT = 11
    private const val APPLY_PUSH_ENTRY = 12
    private const val APPLY_POP_ENTRY = 13
    private const val APPLY_SET_ENTRY_PROP = 14
    private const val APPLY_ADD_SECTION = 15
    private const val APPLY_SELECT_SECTION = 16
    private const val APPLY_SET_SECTION_PROP = 17
    private const val APPLY_MENU_ITEM_CREATE = 18
    private const val APPLY_MENU_ITEM_APPEND = 19
    private const val APPLY_MENUBAR_APPEND = 20
    private const val APPLY_CONTEXT_ATTACH = 21
    private const val APPLY_CONTEXT_ATTACH_NODE = 22
    private const val APPLY_SET_MENU_PROP = 23

    /// The alert_choice cancel sentinel: the wire's u32 0xFFFFFFFF is
    /// Kotlin's Int -1 (two's complement — the java-int spelling the
    /// generated bindings share).
    internal const val ALERT_CHOICE_CANCEL = -1

    // Window properties: their own namespace — windows are not
    // widgets; window 0 is the primary surface.
    private const val WPROP_TITLE = 1
    private const val WPROP_WIDTH = 2
    private const val WPROP_HEIGHT = 3
    private const val WPROP_VETO_CLOSE = 4
    private const val WPROP_SECTIONS_PRESENTATION = 5
    private const val SPROP_TITLE = 1
    private const val SPROP_ICON = 2
    // Navigation-entry properties: their own typed table;
    // intercept_back is the close-veto class transplanted to POP.
    private const val EPROP_TITLE = 1
    private const val EPROP_INTERCEPT_BACK = 2
    private const val COMMAND_CLEAR = 1
    private const val COMMAND_FOCUS = 2
    // Menu item kinds (spec enum "menu_kind"; DESIGN.md, Menus): menu
    // and radio_group are the grouping nodes, the rest are leaves.
    const val MENU_KIND_MENU = 1
    const val MENU_KIND_ACTION = 2
    const val MENU_KIND_TOGGLE = 3
    const val MENU_KIND_RADIO_GROUP = 4
    const val MENU_KIND_RADIO_OPTION = 5
    const val MENU_KIND_SEPARATOR = 6
    // Menu properties (spec::MENU_PROPS) — their own typed surface,
    // separate from widget/window/entry/section props.
    private const val MPROP_LABEL = 1
    private const val MPROP_ENABLED = 2
    private const val MPROP_CHECKED = 3
    private const val MPROP_VALUE = 4
    private const val MPROP_ICON = 5
    private const val MPROP_PRIMARY = 6
    private const val MPROP_SHORTCUT = 7
    private const val MPROP_ROLE = 8
    /**
     * How many promoted primary actions the top bar carries: k is this
     * PLATFORM's idiom, never computed by kaya (DESIGN.md, Menus). M3
     * tolerates up to three top-bar actions; one slot stays the
     * overflow anchor, so two remain for promoted primaries. The rest
     * of the catalog is always reachable through overflow.
     */
    const val MENU_PROMOTED_CAPACITY = 2
    const val KIND_COLUMN = 1
    const val KIND_BUTTON = 2
    const val KIND_LABEL = 3
    const val KIND_ENTRY = 4
    const val KIND_ROW = 5
    const val KIND_CHECKBOX = 6
    const val KIND_SLIDER = 7
    const val KIND_IMAGE = 8
    const val KIND_SCROLL = 9
    const val KIND_PROGRESS = 10
    const val KIND_SELECT = 11
    const val KIND_RADIO = 12
    const val KIND_GRID = 13
    const val KIND_TEXTAREA = 14
    private const val PROP_TEXT = 1
    private const val PROP_CHECKED = 2
    private const val PROP_VALUE = 3
    private const val PROP_MIN = 4
    private const val PROP_MAX = 5
    private const val PROP_SOURCE = 6
    private const val PROP_GROW = 7
    private const val PROP_SPACING = 8
    private const val PROP_ALIGN = 9
    private const val PROP_INDETERMINATE = 10
    private const val PROP_COLUMNS = 11
    // The accessibility identifier (never spoken) and label (spoken).
    // Universal: every widget kind carries both.
    private const val PROP_A11Y_ID = 12
    private const val PROP_A11Y_LABEL = 13
    // The align enum's wire values (spec enum "align").
    const val ALIGN_START = 0L
    const val ALIGN_CENTER = 1L
    const val ALIGN_END = 2L
    const val ALIGN_STRETCH = 3L
    const val ALIGN_BASELINE = 4L
    private const val VALUE_BOOL = 1
    private const val VALUE_I64 = 2
    private const val VALUE_F64 = 3
    private const val VALUE_STR = 4
    private const val VALUE_BLOB = 5

    /**
     * Start the pump and mount the interpreter. Call from onCreate when
     * [Kaya.attach] returns [Kaya.PRESENT_GUEST].
     */
    @JvmStatic
    private var mountedActivity: ComponentActivity? = null

    fun mount(activity: ComponentActivity) {
        mountedActivity = activity
        KayaSceneModel.windowTitle = activity.title?.toString() ?: ""
        val host = KayaPresent.specHash()
        check(host.toULong() == SPEC_HASH) {
            "kaya: stale Compose interpreter — its spec hash %016x does not match the core's %016x; rebuild the APK".format(SPEC_HASH, host)
        }
        startPump(activity)
        activity.setContent { KayaRoot() }
        if (System.getenv("KAYA_SELFTEST") != null) startSelftest(activity)
    }

    /** The visible title: the top entry's while the stack is covered
     * (materialized as the Activity task label, the surface-title
     * path expect_title reads), the window's own when it empties. */
    internal fun refreshNavTitle() {
        val top = KayaSceneModel.navEntries.lastOrNull()
        mountedActivity?.title = top?.title ?: KayaSceneModel.windowTitle
    }

    /**
     * The hardware-keyboard shortcut route (ChromeOS/DeX): map the key
     * event to its canonical spelling and drive the SAME catalog table
     * and activation helper a rendered row uses — one dispatch path,
     * one menu_activated occurrence (the shortcut is another
     * affordance of the same item). The shell Activity overrides
     * [android.app.Activity.dispatchKeyShortcutEvent] and forwards
     * here on the UI thread — both app modules (the rust host and the
     * JVM guest host) carry that one-line override beside their scene
     * plumbing. Returns true when a catalog action owned the chord.
     */
    @JvmStatic
    fun dispatchKeyShortcutEvent(event: KeyEvent): Boolean {
        val spelling = kayaShortcutSpelling(event) ?: return false
        return kayaDispatchShortcut(spelling)
    }

    /**
     * A key event's canonical wire spelling — lowercase, modifiers in
     * `primary`, `shift`, `alt` order, one key from the closed floor
     * (ASCII alphanumerics and the named set). `primary` is ctrl off
     * Apple hosts. escape never maps: it is the platforms' universal
     * dismiss key and the root rejects the spelling outright; bare
     * alphanumerics are typing, never chords (the root enforces the
     * same floor, so an unmapped event simply falls through to the
     * platform).
     */
    private fun kayaShortcutSpelling(event: KeyEvent): String? {
        if (event.action != KeyEvent.ACTION_DOWN) return null
        val key = when (event.keyCode) {
            in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z ->
                ('a' + (event.keyCode - KeyEvent.KEYCODE_A)).toString()
            in KeyEvent.KEYCODE_0..KeyEvent.KEYCODE_9 ->
                ('0' + (event.keyCode - KeyEvent.KEYCODE_0)).toString()
            KeyEvent.KEYCODE_ENTER -> "enter"
            KeyEvent.KEYCODE_DEL, KeyEvent.KEYCODE_FORWARD_DEL -> "delete"
            in KeyEvent.KEYCODE_F1..KeyEvent.KEYCODE_F12 ->
                "f${event.keyCode - KeyEvent.KEYCODE_F1 + 1}"
            KeyEvent.KEYCODE_DPAD_LEFT -> "left"
            KeyEvent.KEYCODE_DPAD_RIGHT -> "right"
            KeyEvent.KEYCODE_DPAD_UP -> "up"
            KeyEvent.KEYCODE_DPAD_DOWN -> "down"
            // The punctuation set names UNSHIFTED US positions, which
            // is exactly what these key codes are.
            KeyEvent.KEYCODE_COMMA -> "comma"
            KeyEvent.KEYCODE_PERIOD -> "period"
            KeyEvent.KEYCODE_SLASH -> "slash"
            KeyEvent.KEYCODE_BACKSLASH -> "backslash"
            KeyEvent.KEYCODE_MINUS -> "minus"
            KeyEvent.KEYCODE_EQUALS -> "equal"
            KeyEvent.KEYCODE_LEFT_BRACKET -> "leftbracket"
            KeyEvent.KEYCODE_RIGHT_BRACKET -> "rightbracket"
            else -> return null
        }
        val mods = StringBuilder()
        if (event.isCtrlPressed) mods.append("primary+")
        if (event.isShiftPressed) mods.append("shift+")
        if (event.isAltPressed) mods.append("alt+")
        if (mods.isEmpty() && key.length == 1) return null
        return mods.toString() + key
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
            // SET_PROP and SET_MENU_PROP share the body shape (u64 id,
            // u32 prop, u32 pad, value); a menu item's icon rides the
            // same batch-local blob table as an image source.
            if (kind == APPLY_SET_PROP || kind == APPLY_SET_MENU_PROP) {
                b.long // widget or menu item id
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
                        KIND_ROW -> KayaSceneModel.rows.add(node)
                        KIND_SCROLL -> KayaSceneModel.scrolls.add(node)
                        KIND_PROGRESS -> KayaSceneModel.progresses.add(node)
                        KIND_SELECT -> KayaSceneModel.selects.add(node)
                        KIND_RADIO -> KayaSceneModel.radios.add(node)
                        KIND_GRID -> KayaSceneModel.grids.add(node)
                        KIND_TEXTAREA -> KayaSceneModel.textareas.add(node)
                    }
                }
                APPLY_SET_PROP -> {
                    val id = b.long
                    val prop = b.int
                    b.int // pad
                    when (prop) {
                        PROP_TEXT -> KayaSceneModel.nodes[id]!!.text = kayaLf(readString(b))
                        PROP_CHECKED -> KayaSceneModel.nodes[id]!!.checked = readBool(b)
                        PROP_VALUE -> KayaSceneModel.nodes[id]!!.value = readF64(b)
                        PROP_MIN -> KayaSceneModel.nodes[id]!!.minValue = readF64(b)
                        PROP_MAX -> KayaSceneModel.nodes[id]!!.maxValue = readF64(b)
                        PROP_GROW -> KayaSceneModel.nodes[id]!!.grow = readF64(b)
                        PROP_SPACING ->
                            KayaSceneModel.nodes[id]!!.spacing = readF64(b)
                        PROP_ALIGN ->
                            KayaSceneModel.nodes[id]!!.align = readI64(b)
                        PROP_INDETERMINATE ->
                            KayaSceneModel.nodes[id]!!.indeterminate = readBool(b)
                        PROP_COLUMNS ->
                            KayaSceneModel.nodes[id]!!.columns = readF64(b).toInt()
                        PROP_A11Y_ID ->
                            KayaSceneModel.nodes[id]!!.a11yId = readString(b)
                        PROP_A11Y_LABEL ->
                            KayaSceneModel.nodes[id]!!.a11yLabel = readString(b)
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
                APPLY_SET_WINDOW_PROP -> {
                    b.long // window: 0 = the primary surface
                    val prop = b.int
                    b.int // pad
                    when (prop) {
                        WPROP_TITLE -> {
                            val title = readString(b)
                            KayaSceneModel.windowTitle = title
                            // The task-label materialization of a
                            // surface title; while a navigation entry
                            // covers it the entry's title shows.
                            if (KayaSceneModel.navEntries.isEmpty()) {
                                mountedActivity?.title = title
                            }
                        }
                        WPROP_WIDTH -> KayaSceneModel.windowWidth = readF64(b)
                        WPROP_HEIGHT -> KayaSceneModel.windowHeight = readF64(b)
                        // veto_close is inert on Android by physics:
                        // no chrome close, and back is not close
                        // (DESIGN.md, Presentation contexts).
                        WPROP_VETO_CLOSE -> readBool(b)
                        WPROP_SECTIONS_PRESENTATION ->
                            KayaSceneModel.sectionsPresentation = readI64(b)
                        else -> error("kaya: unknown window prop $prop")
                    }
                }
                // The scene core rejects create_window on this host
                // (no KAYA_CAP_AUX_WINDOWS) before any apply is
                // emitted; reaching these arms means the core and
                // this interpreter disagree — fail loudly.
                APPLY_CREATE_WINDOW -> error("kaya: aux window apply on a capability-less host")
                APPLY_DESTROY_WINDOW -> error("kaya: aux window apply on a capability-less host")
                APPLY_PRESENT_ALERT -> {
                    // The platform's REAL modal dialog (M3
                    // AlertDialog, rendered by KayaRoot off alertId);
                    // phones have alerts natively — no capability
                    // carve-out here.
                    b.long // window: 0, the one surface on this host
                    val alert = b.long
                    val actions = b.int
                    b.int // pad
                    val title = readString(b)
                    val message = readString(b)
                    val action0 = readString(b)
                    val action1 = readString(b)
                    val cancel = readString(b)
                    KayaSceneModel.alertTitle = title
                    KayaSceneModel.alertMessage = message
                    KayaSceneModel.alertActions = buildList {
                        if (actions >= 1) add(action0)
                        if (actions == 2) add(action1)
                    }
                    KayaSceneModel.alertCancel = cancel
                    KayaSceneModel.alertId = alert
                }
                APPLY_PUSH_ENTRY -> {
                    // Materializes covered/incoming: on the stack now,
                    // the mount fills it; the top of navEntries is the
                    // visible screen and recomposition animates the
                    // push.
                    // The host surface may be the window (0) or a
                    // section — stacks are per-surface.
                    val host = b.long
                    val eid = b.long
                    val entry = KayaNavEntry(eid)
                    KayaSceneModel.navIndex[eid] = entry
                    val hostSection = KayaSceneModel.sectionIndex[host]
                    if (hostSection != null) hostSection.entries.add(entry)
                    else KayaSceneModel.navEntries.add(entry)
                }
                APPLY_POP_ENTRY -> {
                    // Programmatic pop: the core already reconciled;
                    // the batch's NET stack change recomposes as one
                    // transition (the multi-pop obligation).
                    val host = b.long
                    val hostSection = KayaSceneModel.sectionIndex[host]
                    val entry =
                        if (hostSection != null)
                            hostSection.entries.removeAt(hostSection.entries.size - 1)
                        else
                            KayaSceneModel.navEntries.removeAt(
                                KayaSceneModel.navEntries.size - 1)
                    KayaSceneModel.navIndex.remove(entry.id)
                    refreshNavTitle()
                }
                APPLY_SET_ENTRY_PROP -> {
                    val eid = b.long
                    val prop = b.int
                    b.int // pad
                    val entry = KayaSceneModel.navIndex[eid]!!
                    when (prop) {
                        EPROP_TITLE -> {
                            entry.title = readString(b)
                            refreshNavTitle()
                        }
                        EPROP_INTERCEPT_BACK -> entry.interceptBack = readBool(b)
                        else -> error("kaya: unknown entry prop $prop")
                    }
                }
                APPLY_ADD_SECTION -> {
                    // Append-only; mirror the core's first-added-is-
                    // selected so the bar shows a selection at once.
                    b.long // window: 0, the one surface on this host
                    val sid = b.long
                    val section = KayaSection(sid)
                    KayaSceneModel.sectionIndex[sid] = section
                    KayaSceneModel.sections.add(section)
                    if (KayaSceneModel.selectedSection == null) {
                        KayaSceneModel.selectedSection = sid
                    }
                }
                APPLY_SELECT_SECTION -> {
                    // Programmatic and QUIET (the echo doctrine).
                    b.long // window
                    KayaSceneModel.selectedSection = b.long
                }
                APPLY_SET_SECTION_PROP -> {
                    val sid = b.long
                    val prop = b.int
                    b.int // pad
                    val section = KayaSceneModel.sectionIndex[sid]!!
                    when (prop) {
                        SPROP_TITLE -> section.title = readString(b)
                        // Day-one slot: accepted; the bar item's TITLE
                        // is the harness observable.
                        SPROP_ICON -> skipValue(b)
                        else -> error("kaya: unknown section prop $prop")
                    }
                }
                APPLY_MENU_ITEM_CREATE -> {
                    // u64 item, u32 menu_kind, u32 pad — its OWN id
                    // space (c_menu_item); append-only, never removed.
                    val item = b.long
                    val menuKind = b.int
                    b.int // pad
                    KayaSceneModel.menuItems[item] = KayaMenuItem(item, menuKind)
                }
                APPLY_MENU_ITEM_APPEND -> {
                    // u64 parent, u64 child — the closed grammar and
                    // single-parent rule were validated at the root.
                    val parent = b.long
                    val child = b.long
                    val parentItem = KayaSceneModel.menuItems[parent]!!
                    val childItem = KayaSceneModel.menuItems[child]!!
                    childItem.parent = parentItem
                    parentItem.children.add(childItem)
                }
                APPLY_MENUBAR_APPEND -> {
                    // u64 window (0 — this host's one surface), u64
                    // item: a top-level grouping node joins the window
                    // catalog; the top bar folds it into overflow.
                    b.long // window
                    val item = b.long
                    KayaSceneModel.menubar.add(KayaSceneModel.menuItems[item]!!)
                }
                APPLY_CONTEXT_ATTACH -> {
                    // u64 widget, u64 item — the same vocabulary
                    // scoped to a live-widget noun; empty noun path.
                    // One attach per ROOT: append, never replace.
                    val widget = b.long
                    val item = b.long
                    KayaSceneModel.contextMenus
                        .getOrPut(widget) { KayaContextAttachment() }
                        .roots.add(KayaSceneModel.menuItems[item]!!)
                }
                APPLY_CONTEXT_ATTACH_NODE -> {
                    // u64 widget (the STAMPED copy), u64 item, then the
                    // copy's key path { u32 count; u32 reserved; count
                    // values }. The raw path bytes ARE the noun: they
                    // ride back verbatim in every emission from this
                    // anchor (menu_tag consumes them unchanged), so the
                    // slice is captured, never re-encoded.
                    val widget = b.long
                    val item = b.long
                    val pathStart = b.position()
                    val count = b.int
                    b.int // reserved
                    repeat(count) { skipValue(b) }
                    val noun = batch.copyOfRange(pathStart, b.position())
                    // One attach per ROOT: append, never replace (the
                    // copy's noun is per-anchor, identical across its
                    // roots).
                    val attachment = KayaSceneModel.contextMenus
                        .getOrPut(widget) { KayaContextAttachment() }
                    attachment.roots.add(KayaSceneModel.menuItems[item]!!)
                    attachment.noun = noun
                }
                APPLY_SET_MENU_PROP -> {
                    // u64 item, u32 mprop, u32 pad, value (resolved).
                    // The echo doctrine: checked/value writes here are
                    // CONFIGURATION — they land in the model and emit
                    // nothing (user rows/verbs are the emitting route).
                    val id = b.long
                    val prop = b.int
                    b.int // pad
                    val item = KayaSceneModel.menuItems[id]!!
                    when (prop) {
                        MPROP_LABEL -> item.label = readString(b)
                        MPROP_ENABLED -> item.enabled = readBool(b)
                        MPROP_CHECKED -> item.checked = readBool(b)
                        MPROP_VALUE -> item.value = readF64(b)
                        MPROP_PRIMARY -> item.primary = readBool(b)
                        MPROP_SHORTCUT -> item.shortcut = readString(b)
                        // A standard-command role. Android has no
                        // application menu to relocate into, so the
                        // item stays exactly where the app declared it
                        // — the role is recorded, never materialized.
                        MPROP_ROLE -> item.role = readString(b)
                        MPROP_ICON -> {
                            // The image-source path's twin: a
                            // batch-local blob handle the pump
                            // prefetched; a null decode is the
                            // placeholder class, never a crash.
                            val handle = readBlobHandle(b)
                            val bytes = blobs[handle]
                            item.iconBitmap = bytes?.let {
                                BitmapFactory.decodeByteArray(it, 0, it.size)
                            }?.asImageBitmap()
                        }
                        else -> error("kaya: unknown menu prop $prop")
                    }
                }
                APPLY_ADD_CHILD -> {
                    val parent = b.long
                    val child = b.long
                    KayaSceneModel.nodes[parent]!!.children
                        .add(KayaSceneModel.nodes[child]!!)
                    KayaSceneModel.parents[child] = parent
                    // A choice widget's label children are its
                    // OPTIONS — rows of the dropdown / entries of the
                    // radio group, not standalone widgets — so they
                    // leave the harness's label#N registry (their
                    // create arm appended before this parent was
                    // known). Without this, every label after one
                    // would shift index.
                    val parentKind = KayaSceneModel.nodes[parent]!!.kind
                    if (parentKind == KIND_SELECT || parentKind == KIND_RADIO) {
                        KayaSceneModel.labels.removeAll { it.id == child }
                    }
                }
                APPLY_MOUNT -> {
                    // The target is a SURFACE: the primary (0) or a
                    // pushed navigation entry (aux windows are
                    // capability-rejected on this host).
                    val wid = b.long
                    val root = b.long
                    val entry = KayaSceneModel.navIndex[wid]
                    val section = KayaSceneModel.sectionIndex[wid]
                    if (entry != null) entry.root = KayaSceneModel.nodes[root]
                    else if (section != null) section.root = KayaSceneModel.nodes[root]
                    else KayaSceneModel.root = KayaSceneModel.nodes[root]
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
                    // A destroyed anchor takes its context attachment
                    // with it (menu ITEMS are never destroyed; the
                    // anchor map entry is): a For-row removal must not
                    // leave the harness's open-menu pointer dangling
                    // (the SwiftUI sibling's order).
                    if (KayaSceneModel.contextMenus.remove(id) != null &&
                        KayaSceneModel.openContextWidget == id
                    ) {
                        KayaSceneModel.openContextWidget = null
                    }
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
                // A record kind this interpreter does not know is a
                // core/interpreter disagreement — fail LOUDLY (the
                // SwiftUI sibling's fatalError); a silent skip is the
                // false-verdict class.
                else -> error("kaya: unknown apply record kind $kind")
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
        // Values self-pad to 8; consume it HERE so sequential values
        // parse (a reader that stops at the payload's end misparses
        // the next value as type 0 — the confirm-compose leg caught
        // it when the alert record brought the first 5-value body).
        while (b.position() % 8 != 0) b.get()
        return String(bytes, Charsets.UTF_8)
    }

    private fun readF64(b: ByteBuffer): Double {
        val type = b.int
        b.int // len
        check(type == VALUE_F64) { "kaya: expected an f64 value, got type $type" }
        return b.double
    }

    private fun readI64(b: ByteBuffer): Long {
        val type = b.int
        b.int // len
        check(type == VALUE_I64) { "kaya: expected an i64 value, got type $type" }
        return b.long
    }

    private fun skipValue(b: ByteBuffer) {
        b.int // type
        val len = b.int
        b.position(b.position() + ((len + 7) and (7.inv())))
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

    /**
     * The quoted-head split (harness.rs's split_quoted_head): the
     * verbs whose quoted argument comes FIRST — expect_menu's path,
     * menu_activate's path, shortcut's spelling — may carry spaces
     * inside the quotes, so scan to the closing quote and return
     * (inner, trimmed tail). Null when the head is not quoted.
     */
    private fun quotedHead(rest: String): Pair<String, String>? {
        val s = rest.trim()
        if (!s.startsWith("\"")) return null
        val end = s.indexOf('"', 1)
        if (end < 0) return null
        return Pair(s.substring(1, end), s.substring(end + 1).trim())
    }

    /**
     * Resolve any `kind#index` widget target across the per-kind
     * registries — context_open accepts every targetable kind, so the
     * kind names the registry exactly as harness.rs's parse_target
     * does (a kind that names a different registry is the
     * false-verdict class the [target] helper guards).
     */
    private fun kayaWidgetTarget(spec: String): KayaNode? {
        val kind = spec.substringBefore('#')
        val registry = when (kind) {
            "button" -> KayaSceneModel.buttons
            "checkbox" -> KayaSceneModel.checkboxes
            "slider" -> KayaSceneModel.sliders
            "entry" -> KayaSceneModel.entries
            "label" -> KayaSceneModel.labels
            "column" -> KayaSceneModel.columns
            "row" -> KayaSceneModel.rows
            "image" -> KayaSceneModel.images
            "scroll" -> KayaSceneModel.scrolls
            "progress" -> KayaSceneModel.progresses
            "select" -> KayaSceneModel.selects
            "radio" -> KayaSceneModel.radios
            "grid" -> KayaSceneModel.grids
            "textarea" -> KayaSceneModel.textareas
            else -> return null
        }
        return target(spec, kind, registry)
    }

    private fun quoted(parts: List<String>): String {
        val inner = parts.joinToString(" ").removeSurrounding("\"")
        // The grammar's escapes (harness.rs is the norm): \\n ->
        // newline, \\r -> carriage return (the paste stand-in for the
        // LF-contract proof), \\\\ -> backslash.
        val out = StringBuilder(inner.length)
        var i = 0
        while (i < inner.length) {
            val c = inner[i]
            if (c == '\\' && i + 1 < inner.length) {
                when (inner[i + 1]) {
                    'n' -> { out.append('\n'); i += 2 }
                    'r' -> { out.append('\r'); i += 2 }
                    '\\' -> { out.append('\\'); i += 2 }
                    else -> { out.append(c); i += 1 }
                }
            } else {
                out.append(c)
                i += 1
            }
        }
        return out.toString()
    }

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
                // The observation contract (harness.rs is the norm):
                // every expect is a BOUNDED RETRY — each verb case
                // appends exactly one failure on a miss, so the
                // wrapper retracts it and re-runs the case until it
                // passes or the deadline lands the last failure
                // text. Actions never re-run; the FIRST expect
                // doubles as the scene-ready wait (scripts open
                // with one).
                val stepDeadline = System.nanoTime() + 5_000_000_000L
                var retryStep = true
                while (retryStep) {
                retryStep = false
                val failuresBefore = failures.size
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
                    "expect_sections" -> {
                        val want = parts[1].toInt()
                        val got = onUi(activity) { KayaSceneModel.sections.size }
                        if (got == want) observed.add("$want sections")
                        else failures.add("$got sections, wanted $want")
                    }
                    "expect_section" -> {
                        val want = quoted(parts.drop(1))
                        val got = onUi(activity) {
                            KayaSceneModel.selectedSection
                                ?.let { KayaSceneModel.sectionIndex[it]?.title } ?: ""
                        }
                        if (got == want) observed.add("section \"$want\"")
                        else failures.add("section \"$got\", wanted \"$want\"")
                    }
                    "select_section" -> {
                        val index = parts[1].toInt()
                        val ok = onUi(activity) {
                            val section = KayaSceneModel.sections.getOrNull(index)
                            if (section != null) kayaUserSelectsSection(section.id)
                            section != null
                        }
                        if (!ok) failures.add("no such section ${parts[1]}")
                    }
                    "choose" -> {
                        // The choice widget's real change route in
                        // this interpreter is the item's onClick —
                        // mirrored here exactly as set_value mirrors
                        // the slider's binding: write the state the
                        // control reads, emit with the identity tag.
                        val ok = onUi(activity) {
                            val node =
                                if (parts[1].startsWith("radio"))
                                    target(parts[1], "radio", KayaSceneModel.radios)
                                else target(parts[1], "select", KayaSceneModel.selects)
                            node?.also {
                                it.value = parts[2].toDouble()
                                KayaPresent.emitValueChanged(it.tag, it.value)
                            } != null
                        }
                        if (!ok) failures.add("no such target ${parts[1]}")
                    }
                    "set_text" -> {
                        val ok = onUi(activity) {
                            val node =
                                if (parts[1].startsWith("textarea"))
                                    target(parts[1], "textarea", KayaSceneModel.textareas)
                                else target(parts[1], "entry", KayaSceneModel.entries)
                            node?.also {
                                it.text = kayaLf(quoted(parts.drop(2)))
                                KayaPresent.emitTextChanged(it.tag, it.text)
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
                            if (parts[1].startsWith("textarea"))
                                target(parts[1], "textarea", KayaSceneModel.textareas)?.text
                            else if (parts[1].startsWith("entry"))
                                target(parts[1], "entry", KayaSceneModel.entries)?.text
                            else if (parts[1].startsWith("image"))
                                target(parts[1], "image", KayaSceneModel.images)?.imageSize
                            else if (parts[1].startsWith("progress"))
                                target(parts[1], "progress", KayaSceneModel.progresses)?.let {
                                    if (it.indeterminate) "indeterminate"
                                    else "${Math.round(it.value * 100)}%"
                                }
                            else if (parts[1].startsWith("select") || parts[1].startsWith("radio"))
                                // The selected option's LABEL — what
                                // the control shows (child order is
                                // option order).
                                (if (parts[1].startsWith("radio"))
                                    target(parts[1], "radio", KayaSceneModel.radios)
                                else target(parts[1], "select", KayaSceneModel.selects))?.let {
                                    it.children.getOrNull(it.value.toInt())?.text ?: ""
                                }
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
                            (if (parts[1].startsWith("textarea"))
                                target(parts[1], "textarea", KayaSceneModel.textareas)
                            else target(parts[1], "entry", KayaSceneModel.entries))
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
                            // Kind picks the registry, exactly as in the
                            // Rust harness: a row target must never read
                            // a column.
                            val isRow = parts[1].startsWith("row")
                            target(
                                parts[1], if (isRow) "row" else "column",
                                if (isRow) KayaSceneModel.rows else KayaSceneModel.columns,
                            )?.children
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
                            val isRow = parts[1].startsWith("row")
                            target(
                                parts[1], if (isRow) "row" else "column",
                                if (isRow) KayaSceneModel.rows else KayaSceneModel.columns,
                            )?.let { container ->
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
                    "close_window" -> {
                        // No chrome close on this host: the system
                        // owns surfaces, and back is not close
                        // (DESIGN.md, Presentation contexts).
                        failures.add("close_window: this host has no chrome close")
                    }
                    "expect_windows" -> {
                        val want = parts[1].toIntOrNull() ?: -1
                        // The primary is the one surface; the core
                        // rejects create_window here.
                        if (want == 1) {
                            observed.add("windows 1")
                        } else {
                            failures.add("windows 1, wanted $want")
                        }
                    }
                    "expect_alert" -> {
                        // The presented dialog's title off the model
                        // that renders it (alertId is the M3 dialog's
                        // existence), window#0 = the one surface.
                        val target = parts.getOrNull(1) ?: ""
                        val explicit = target.startsWith("window#")
                        val wid =
                            if (explicit) target.removePrefix("window#").toLongOrNull() ?: -1
                            else 0L
                        val prefix = if (explicit) "window#$wid " else ""
                        val want = quoted(parts.drop(if (explicit) 2 else 1))
                        val got = onUi(activity) {
                            if (wid == 0L && KayaSceneModel.alertId != null)
                                KayaSceneModel.alertTitle
                            else null
                        }
                        if (got == want) {
                            observed.add("${prefix}alert \"$want\"")
                        } else if (got != null) {
                            failures.add("${prefix}alert \"$got\", wanted \"$want\"")
                        } else {
                            failures.add("${prefix}no alert live, wanted \"$want\"")
                        }
                    }
                    "alert_choose" -> {
                        // Drive the SAME answer path the dialog's
                        // buttons run — the runner drives the model
                        // exactly as click does here. Silent.
                        val arg = parts.getOrNull(1) ?: ""
                        onUi(activity) {
                            val alert = KayaSceneModel.alertId
                            if (alert != null) {
                                when (arg) {
                                    "0" ->
                                        if (KayaSceneModel.alertActions.isNotEmpty())
                                            kayaAnswerAlert(alert, 0)
                                    "1" ->
                                        if (KayaSceneModel.alertActions.size >= 2)
                                            kayaAnswerAlert(alert, 1)
                                    "cancel" -> kayaAnswerAlert(alert, ALERT_CHOICE_CANCEL)
                                }
                            }
                        }
                    }
                    "expect_alerts" -> {
                        val want = parts[1].toIntOrNull() ?: -1
                        val got =
                            onUi(activity) { if (KayaSceneModel.alertId != null) 1 else 0 }
                        if (got == want) {
                            observed.add("alerts $want")
                        } else {
                            failures.add("alerts $got, wanted $want")
                        }
                    }
                    "expect_entries" -> {
                        // The navigation-stack depth (window#0 is the
                        // one surface; the implicit form is the
                        // canonical spelling here).
                        val target = parts.getOrNull(1) ?: ""
                        val explicit = target.startsWith("window#")
                        val prefix = if (explicit) "$target " else ""
                        val arg = if (explicit) parts.getOrNull(2) else parts.getOrNull(1)
                        val want = arg?.toIntOrNull() ?: -1
                        val got = onUi(activity) { KayaSceneModel.navEntries.size }
                        if (got == want) {
                            observed.add("${prefix}entries $want")
                        } else {
                            failures.add("${prefix}entries $got, wanted $want")
                        }
                    }
                    "back" -> {
                        // The user's back affordance: drive the SAME
                        // path the system back dispatch runs (the
                        // BackHandler's body), so interception and the
                        // post-fact reconcile fire exactly as a real
                        // gesture. Silent, like click.
                        onUi(activity) { kayaUserBack() }
                    }
                    "expect_grid_columns" -> {
                        val want = parts[2].toInt()
                        val off = onUi(activity) {
                            val grid = target(parts[1], "grid", KayaSceneModel.grids)
                                ?: return@onUi "no such target"
                            // Geometry, never the model's columns
                            // copy: distinct leading-edge clusters of
                            // the cells ARE the columns.
                            val edges = grid.children.map {
                                KayaSceneModel.cellMinX[it.id]
                                    ?: return@onUi "cell geometry not recorded"
                            }.sorted()
                            if (edges.isEmpty()) return@onUi "no cells"
                            var clusters = 0
                            var last = Int.MIN_VALUE
                            for (x in edges) {
                                if (clusters == 0 || x - last > 2) {
                                    clusters++
                                    last = x
                                }
                            }
                            if (clusters == want) ""
                            else "$clusters column edges, wanted $want"
                        }
                        when (off) {
                            "" -> observed.add("${parts[1]} columns $want")
                            "no such target" -> failures.add("no such target ${parts[1]}")
                            else -> failures.add("${parts[1]} misaligned ($off)")
                        }
                    }
                    "expect_overflow" -> {
                        // The toolkit's own ScrollState: maxValue > 0
                        // IS overflow.
                        val target = parts.getOrNull(1) ?: ""
                        val st = onUi(activity) { scrollTarget(target)?.scrollState }
                        if (st == null) {
                            failures.add("no such target $target")
                        } else if (st.maxValue > 0) {
                            observed.add("$target overflows")
                        } else {
                            failures.add("$target fits (maxValue 0)")
                        }
                    }
                    "scroll_end" -> {
                        // The REAL scrolling API, driven to its end.
                        // Silent, like click.
                        val target = parts.getOrNull(1) ?: ""
                        onUi(activity) {
                            scrollTarget(target)?.scrollState?.let { st ->
                                kotlinx.coroutines.MainScope().launch {
                                    st.scrollTo(st.maxValue)
                                }
                            }
                        }
                    }
                    "expect_at_end" -> {
                        val target = parts.getOrNull(1) ?: ""
                        val st = onUi(activity) { scrollTarget(target)?.scrollState }
                        if (st == null) {
                            failures.add("no such target $target")
                        } else if (st.maxValue - st.value <= 2) {
                            observed.add("$target at end")
                        } else {
                            failures.add(
                                "$target short of end (${st.value} of ${st.maxValue})")
                        }
                    }
                    "expect_title" -> {
                        // The REAL materialized title (the Activity
                        // label), never only the model's copy — a
                        // backend that ignored the write must fail.
                        val target = parts.getOrNull(1) ?: ""
                        val explicit = target.startsWith("window#")
                        val wid = if (explicit) target.removePrefix("window#").toLongOrNull() ?: -1 else 0L
                        val prefix = if (explicit) "window#$wid " else ""
                        val want = quoted(parts.drop(if (explicit) 2 else 1))
                        val got = onUi(activity) {
                            if (wid == 0L) activity.title?.toString() ?: "" else ""
                        }
                        if (got == want) {
                            observed.add("${prefix}title \"$want\"")
                        } else {
                            failures.add("${prefix}title \"$got\", wanted \"$want\"")
                        }
                    }
                    "expect_window_size" -> {
                        // The surface's REAL extent against the
                        // advisory request. Android never honors a
                        // size request (the system owns geometry), so
                        // on a phone this verb fails honestly with
                        // the real numbers; the window scene is a
                        // desktop scene.
                        val dims = parts[1].split("x")
                        val wantW = dims[0].toDoubleOrNull() ?: -1.0
                        val wantH = dims[1].toDoubleOrNull() ?: -1.0
                        val got = onUi(activity) {
                            val v = activity.window.decorView
                            Pair(v.width.toDouble(), v.height.toDouble())
                        }
                        if (kotlin.math.abs(got.first - wantW) <= 2 &&
                            kotlin.math.abs(got.second - wantH) <= 2
                        ) {
                            observed.add("window ${wantW.toInt()}x${wantH.toInt()}")
                        } else {
                            failures.add(
                                "window ${got.first.toInt()}x${got.second.toInt()}, " +
                                    "wanted ${wantW.toInt()}x${wantH.toInt()}")
                        }
                    }
                    "expect_root_fills" -> {
                        // The mounted root fills the area offered to it
                        // — the observation shares can never make: a
                        // share is a percentage of the children's sum,
                        // total-invariant by construction, so a hugging
                        // root still splits 25/75.
                        val hug = onUi(activity) {
                            val root = kayaRootSize
                            val area = kayaAvailableSize
                            if (area.width <= 0 || area.height <= 0) {
                                "no root layout recorded"
                            } else if (
                                kotlin.math.abs(root.width - area.width) <= 2 &&
                                kotlin.math.abs(root.height - area.height) <= 2
                            ) {
                                ""
                            } else {
                                "${root.width}x${root.height}px " +
                                    "inside ${area.width}x${area.height}px"
                            }
                        }
                        if (hug.isEmpty()) {
                            observed.add("root fills")
                        } else {
                            failures.add("root hugs ($hug)")
                        }
                    }
                    "expect_aligned" -> {
                        // Classified from measured geometry, never the
                        // model's align field.
                        val want = quoted(parts.drop(2))
                        val got = onUi(activity) {
                            val isRow = parts[1].startsWith("row")
                            target(
                                parts[1], if (isRow) "row" else "column",
                                if (isRow) KayaSceneModel.rows else KayaSceneModel.columns,
                            )?.let { container ->
                                val inner = kayaContainerCross[container.id] ?: 0.0
                                if (inner <= 0.0) {
                                    "no container layout recorded"
                                } else {
                                    val rects = container.children
                                        .mapNotNull { kayaCrossRects[it.id] }
                                    val baselines = container.children.mapNotNull { c ->
                                        val r = kayaCrossRects[c.id] ?: return@mapNotNull null
                                        kayaBaselineOffsets[c.id]?.let { r.first + it }
                                    }
                                    if (rects.isEmpty()) {
                                        "no children"
                                    } else {
                                        // Multi-match is ambiguity, and
                                        // ambiguity fails loudly — a
                                        // first-match answer lets an
                                        // unseparated scene pass while
                                        // proving nothing.
                                        val matches = mutableListOf<String>()
                                        if (rects.all {
                                            kotlin.math.abs(it.second - inner) <= 2.0
                                        }) matches.add("stretch")
                                        if (rects.all {
                                            kotlin.math.abs(it.first) <= 2.0
                                        }) matches.add("start")
                                        if (rects.all {
                                            kotlin.math.abs(2 * it.first + it.second - inner) <= 4.0
                                        }) matches.add("center")
                                        if (rects.all {
                                            kotlin.math.abs(it.first + it.second - inner) <= 2.0
                                        }) matches.add("end")
                                        if (isRow && baselines.size >= 2 && baselines.all {
                                            kotlin.math.abs(it - baselines[0]) <= 2.0
                                        }) matches.add("baseline")
                                        when (matches.size) {
                                            1 -> matches[0]
                                            // A baseline-looking row reading mixed is
                                            // usually the recording, not the geometry —
                                            // name the recorded count in the verdict.
                                            0 -> "mixed (cross rects " + rects + " in " + inner + "px" +
                                                (if (isRow) "; " + baselines.size + " baselines recorded" else "") + ")"
                                            else -> "ambiguous (" + matches.joinToString("|") + ")"
                                        }
                                    }
                                }
                            }
                        }
                        when {
                            got == null -> failures.add("no such target " + parts[1])
                            got == want -> observed.add(parts[1] + " aligns " + want)
                            else ->
                                failures.add(
                                    parts[1] + " aligns \"" + got + "\", wanted \"" + want + "\""
                                )
                        }
                    }
                    "expect_fills" -> {
                        // The container's children span its content box
                        // — the leftover-consumption half of the grow
                        // contract, which shares (total-invariant) and
                        // root_fills (root-level only) can never see.
                        // Span = the measured cell tracks plus the 8-dp
                        // gaps, against the container's own rendered
                        // extent; the pass observation matches
                        // harness.rs byte-for-byte.
                        val slack = onUi(activity) {
                            val isRow = parts[1].startsWith("row")
                            target(
                                parts[1], if (isRow) "row" else "column",
                                if (isRow) KayaSceneModel.rows else KayaSceneModel.columns,
                            )?.let { container ->
                                val extent = kayaContainerExtents[container.id] ?: 0.0
                                if (extent <= 0.0) {
                                    "no container layout recorded"
                                } else {
                                    val tracks = container.children
                                        .map { kayaMainExtents[it.id] ?: 0.0 }
                                    val span = tracks.sum() +
                                        container.spacing * kayaDensity *
                                        maxOf(0, tracks.size - 1)
                                    if (kotlin.math.abs(span - extent) <= 2.0) {
                                        ""
                                    } else {
                                        "children span ${Math.round(span)}px " +
                                            "of ${Math.round(extent)}px"
                                    }
                                }
                            }
                        }
                        when {
                            slack == null -> failures.add("no such target ${parts[1]}")
                            slack.isEmpty() -> observed.add("${parts[1]} fills")
                            else ->
                                failures.add("${parts[1]} leaves leftover ($slack)")
                        }
                    }
                    "expect_menus" -> {
                        // The top-level catalog count — the observation
                        // menubar_append's topology is verified by.
                        val want = parts[1].toInt()
                        val got = onUi(activity) { KayaSceneModel.menubar.size }
                        if (got == want) observed.add("$want menus")
                        else failures.add("$got menus, wanted $want")
                    }
                    "expect_ax" -> {
                        // FAN-OUT PENDING (depth slice is SwiftUI on
                        // mac). The verb is declared here so check-verbs
                        // holds the remaining work open — a gate that is
                        // MEANT to stay red mid-milestone — and reports
                        // honestly rather than silently passing. Compose
                        // reads its real semantics tree via
                        // SemanticsNode when this lands.
                        failures.add(
                            "ax: the Compose accessibility read is not implemented yet"
                        )
                    }
                    "expect_menu_presentation" -> {
                        // `<size class>/<presentation>`: the platform's
                        // width reading, and the lowering that actually
                        // rendered.
                        val want = quotedHead(line.substring(parts[0].length))?.first ?: ""
                        val got =
                            onUi(activity) {
                                KayaSceneModel.formFactor +
                                    "/" +
                                    KayaSceneModel.menuPresentation
                            }
                        if (want.isEmpty()) {
                            // The BARE form: the invariant only, with a
                            // LANE-INDEPENDENT observation string — a
                            // shared scene compares observations
                            // byte-for-byte across platforms, so it
                            // cannot echo a value that legitimately
                            // differs. Asymmetric on purpose: a compact
                            // window showing a bar is fine.
                            val halves = got.split("/", limit = 2)
                            if (halves.size == 2 &&
                                halves[0] == "regular" &&
                                halves[1] == "overflow"
                            ) {
                                failures.add(
                                    "presentation $got: a regular window must not " +
                                        "hide its catalog behind the compact overflow"
                                )
                            } else {
                                observed.add("presentation fits")
                            }
                        } else if (got == want) observed.add("presentation $want")
                        else failures.add("presentation $got, wanted $want")
                    }
                    "expect_menu" -> {
                        // Quoted path first, then the state token(s);
                        // the token names WHICH axis is read (an item
                        // has several at once) — harness.rs's
                        // MenuState/MenuAspect split.
                        val head = quotedHead(line.substring(parts[0].length))
                        val want = head?.second ?: ""
                        val wantValid = want == "enabled" || want == "disabled" ||
                            want == "checked" || want == "unchecked" ||
                            Regex("value \\d+").matches(want)
                        if (head == null || !wantValid) {
                            failures.add(
                                "expect_menu wants a quoted path and " +
                                    "enabled|disabled|checked|unchecked|value N: $line")
                        } else {
                            val path = head.first
                            val got = onUi(activity) {
                                kayaResolveMenuPath(path)?.first?.let { item ->
                                    when {
                                        want == "enabled" || want == "disabled" ->
                                            // The EFFECTIVE read: inherited
                                            // disabled counts, and lifts with
                                            // the ancestor.
                                            if (kayaMenuEffectivelyEnabled(item)) "enabled"
                                            else "disabled"
                                        want == "checked" || want == "unchecked" ->
                                            if (item.checked) "checked" else "unchecked"
                                        else -> "value ${item.value.toInt()}"
                                    }
                                }
                            }
                            when {
                                // Retried by the expect wrapper: the miss
                                // doubles as the wait for a catalog
                                // rebuild (or a late append) to land.
                                got == null -> failures.add("no menu item at \"$path\"")
                                got == want -> observed.add("menu \"$path\" $want")
                                else -> failures.add(
                                    "menu \"$path\" reads \"$got\", wanted \"$want\"")
                            }
                        }
                    }
                    "menu_activate" -> {
                        // Drive the REAL activation route — the same
                        // helper every rendered row calls — wherever
                        // the item surfaced (catalog, or the OPEN
                        // context menu). Silent, like click; the leaf
                        // firing closes the open menu.
                        val head = quotedHead(line.substring(parts[0].length))
                        if (head == null || head.second.isNotEmpty()) {
                            failures.add("menu_activate wants a quoted path: $line")
                        } else {
                            val ok = onUi(activity) {
                                val hit = kayaResolveMenuPath(head.first)
                                if (hit != null) {
                                    // The leaf firing closes the open
                                    // menu: close BEFORE the fire (the
                                    // SwiftUI sibling's order).
                                    KayaSceneModel.openContextWidget = null
                                    kayaActivateMenuItem(hit.first, hit.second)
                                }
                                hit != null
                            }
                            if (!ok) failures.add("no menu item at \"${head.first}\"")
                        }
                    }
                    "context_open" -> {
                        // Open the attached context menu through the
                        // model state the long-press gesture drives —
                        // the SAME presentation route. No emission.
                        val spec = parts.getOrNull(1) ?: ""
                        if (spec.startsWith("entry#") || spec.startsWith("textarea#")) {
                            // v1: editable text keeps its native edit
                            // menu as dress — probing a menu that
                            // cannot exist is the false-verdict class.
                            failures.add(
                                "$spec is editable text — its context menu is dress, " +
                                    "not a context_open target")
                        } else {
                            val miss = onUi(activity) {
                                val node = kayaWidgetTarget(spec)
                                    ?: return@onUi "no such target $spec"
                                if (!KayaSceneModel.contextMenus.containsKey(node.id)) {
                                    "no context menu attached to $spec"
                                } else {
                                    KayaSceneModel.openContextWidget = node.id
                                    ""
                                }
                            }
                            if (miss.isNotEmpty()) failures.add(miss)
                        }
                    }
                    "shortcut" -> {
                        // The platform dispatch table — the catalog
                        // walk the hardware-key route traverses — and
                        // the SAME menu_activated the row emits: one
                        // dispatch path, proven by the scene's fold.
                        val head = quotedHead(line.substring(parts[0].length))
                        val spelling = head?.first ?: ""
                        if (head == null || head.second.isNotEmpty() ||
                            spelling.isEmpty() || spelling.any { it.isWhitespace() }
                        ) {
                            failures.add("shortcut wants a quoted spelling: $line")
                        } else {
                            // The hardware-key route leaves an unowned
                            // chord alone (the dress must never swallow
                            // it), but a SCRIPT asking for one is an
                            // error said out loud: a silent pass makes
                            // a never-pressed key look like a platform
                            // that ignored it (docs/traps.md).
                            val owned = onUi(activity) { kayaDispatchShortcut(spelling) }
                            if (!owned) {
                                failures.add(
                                    "shortcut $spelling: no catalog item owns this chord")
                            }
                        }
                    }
                    else -> failures.add("unknown step $line")
                }
                if (failures.size > failuresBefore && parts[0].startsWith("expect") &&
                    System.nanoTime() < stepDeadline
                ) {
                    while (failures.size > failuresBefore) failures.removeAt(failures.size - 1)
                    Thread.sleep(20)
                    retryStep = true
                }
                }
            }
        }
        if (failures.isEmpty() && observed.isEmpty()) {
            failures.add("script has no expects")
        }
        // A recorded leg must outlive its last sample time — see
        // harness.rs's record_linger; same contract, same constant.
        if (System.getenv("KAYA_RECORD") != null || System.getenv("KAYA_HARNESS_GATE") != null) {
            Thread.sleep(750)
        }
        val code = if (failures.isEmpty()) {
            Log.i("kaya", "KAYA_SELFTEST: OK (${observed.joinToString(", ")})")
            0
        } else {
            // THE UNMOUNTED-SCENE DIAGNOSIS (the SwiftUI sibling —
            // docs/traps.md). A scene that creates widgets and never
            // mounts a root renders an EMPTY surface, and every
            // assertion then measures an invisible app. Target
            // resolution cannot catch it: the widgets exist in the
            // model, so kind#index resolves and the reads describe
            // nothing. Reported on the FAILURE path so it cannot fire
            // before the guest's transactions have arrived, and cannot
            // false-positive on a scene that mounts late.
            val reported =
                if (KayaSceneModel.nodes.isNotEmpty() &&
                    KayaSceneModel.root == null &&
                    KayaSceneModel.sections.isEmpty()
                ) {
                    listOf(
                        "${KayaSceneModel.nodes.size} widgets exist but NO ROOT IS " +
                            "MOUNTED — the scene never called mount(root), so every " +
                            "assertion above measured an empty surface"
                    ) + failures
                } else {
                    failures
                }
            Log.e("kaya", "KAYA_SELFTEST: FAILED (${reported.joinToString("; ")})")
            1
        }
        activity.runOnUiThread {
            activity.finishAndRemoveTask()
            Runtime.getRuntime().halt(code)
        }
    }
}

/** The interpreter's render: the node tree as Compose declarations. */
// The exposed-dropdown family (the select's dressed floor) is still
// behind M3's experimental gate.
/**
 * Guest-visible text uses LF as its line separator on every platform
 * (strings are compared byte-for-byte across languages). The model
 * owns this backend's text, so normalization happens at every WRITE
 * into it — user edits and pastes through onValueChange, the wire's
 * property write, the harness's set_text — and reads need none.
 */
private fun kayaLf(s: String): String =
    if (s.contains('\r')) s.replace("\r\n", "\n").replace('\r', '\n') else s

/**
 * The context-menu anchor (DESIGN.md, Menus): a node carrying a
 * context catalog renders inside a long-press wrapper — the platform's
 * own gesture — anchoring an M3 DropdownMenu with the attached rows.
 * The open state is the MODEL's ([KayaSceneModel.openContextWidget]):
 * the gesture and the harness's context_open drive the same route, and
 * a leaf firing or a dismissal closes it. Stamped rows carry their
 * copy's key path as the noun of every emission (the keys ARE the
 * noun).
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun KayaRender(node: KayaNode, isRoot: Boolean = false) {
    val attachment = KayaSceneModel.contextMenus[node.id]
    if (attachment == null) {
        KayaRenderCore(node, isRoot)
        return
    }
    Box(
        Modifier.combinedClickable(
            // The wrapper's plain click is inert: the anchored widget
            // owns its own activation route.
            onClick = {},
            onLongClick = { KayaSceneModel.openContextWidget = node.id },
        )
    ) {
        KayaRenderCore(node, isRoot)
        val open = KayaSceneModel.openContextWidget == node.id
        DropdownMenu(
            expanded = open,
            onDismissRequest = { KayaSceneModel.openContextWidget = null },
        ) {
            val close = { KayaSceneModel.openContextWidget = null }
            // The drill-in state resets on every (re)open: the menu
            // always surfaces at its roots.
            var drilled by remember(open) { mutableStateOf<KayaMenuItem?>(null) }
            val sub = drilled
            if (sub == null) {
                // The attached roots in attach order — the semantic
                // tree's first level. A grouping root (menu or
                // radio_group) is a labeled drill-in: its label IS a
                // path segment ("Stuff>Rename"); a leaf root is its
                // own row ("Rename" resolves bare only then).
                // Separators between roots come from the catalog
                // itself — nothing is added here.
                attachment.roots.forEach { root ->
                    when (root.kind) {
                        KayaCompose.MENU_KIND_MENU,
                        KayaCompose.MENU_KIND_RADIO_GROUP ->
                            DropdownMenuItem(
                                text = { Text(root.label) },
                                trailingIcon = { Text("▸") },
                                enabled = kayaMenuEffectivelyEnabled(root),
                                onClick = { drilled = root },
                            )
                        else ->
                            KayaMenuRows(
                                listOf(root), attachment.noun,
                                onDrill = { drilled = it }, onClose = close)
                    }
                }
            } else {
                // The drill-in: a back row over the grouping root's
                // rows (the overflow's idiom). Deeper grouping cannot
                // occur: the root's closed grammar caps context depth
                // at root items + one grouping-node level.
                DropdownMenuItem(
                    text = { Text("‹ ${sub.label}") },
                    onClick = { drilled = null },
                )
                HorizontalDivider()
                if (sub.kind == KayaCompose.MENU_KIND_RADIO_GROUP) {
                    // The options with the platform's checkmark idiom.
                    KayaRadioRows(sub, attachment.noun, close)
                } else {
                    KayaMenuRows(
                        sub.children.toList(), attachment.noun,
                        onDrill = { drilled = it }, onClose = close)
                }
            }
        }
    }
}

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun KayaRenderCore(node: KayaNode, isRoot: Boolean = false) {
    // The mounted root fills its window — the same normalization GTK
    // and UIKit needed. A Compose Column wraps its width even when
    // weighted children have forced its height, so the grow scene's
    // 25/75 held over a content-wide strip while every other backend
    // spanned the window; nested containers keep wrapping, exactly as
    // everywhere else.
    val rootFill = if (isRoot) Modifier.fillMaxSize() else Modifier
    when (node.kind) {
        KayaCompose.KIND_SELECT -> {
            // The dressed floor: M3's exposed dropdown menu — the
            // collapsed field shows the selected option's label
            // (child order is option order); every pick is emitted
            // with the select's identity tag — the slider's
            // uncontrolled contract.
            var expanded by remember { mutableStateOf(false) }
            val selectedLabel =
                node.children.getOrNull(node.value.toInt())?.text ?: ""
            androidx.compose.material3.ExposedDropdownMenuBox(
                expanded = expanded,
                onExpandedChange = { expanded = it },
            ) {
                TextField(
                    value = selectedLabel,
                    onValueChange = {},
                    readOnly = true,
                    modifier = Modifier.menuAnchor(),
                )
                ExposedDropdownMenu(
                    expanded = expanded,
                    onDismissRequest = { expanded = false },
                ) {
                    node.children.forEachIndexed { i, option ->
                        androidx.compose.material3.DropdownMenuItem(
                            text = { Text(option.text) },
                            onClick = {
                                expanded = false
                                node.value = i.toDouble()
                                KayaPresent.emitValueChanged(node.tag, i.toDouble())
                            })
                    }
                }
            }
        }
        KayaCompose.KIND_GRID -> {
            // The 2D layout contract: Compose has no grid primitive,
            // so this Layout IS the policy — children measure at
            // natural size, column widths are per-column maxima
            // (aligned across rows by construction), children fill
            // row-major. Each cell's leading edge is recorded at
            // place time for the geometry observation.
            val cols = maxOf(1, node.columns)
            val gapPx = with(LocalDensity.current) { node.spacing.dp.roundToPx() }
            androidx.compose.ui.layout.Layout(
                content = { node.children.forEach { child -> KayaRender(child) } },
            ) { measurables, _ ->
                val placeables = measurables.map {
                    it.measure(androidx.compose.ui.unit.Constraints())
                }
                val rows = (placeables.size + cols - 1) / cols
                val colW = IntArray(cols)
                val rowH = IntArray(rows)
                placeables.forEachIndexed { i, p ->
                    colW[i % cols] = maxOf(colW[i % cols], p.width)
                    rowH[i / cols] = maxOf(rowH[i / cols], p.height)
                }
                val width = colW.sum() + gapPx * (cols - 1).coerceAtLeast(0)
                val height = rowH.sum() + gapPx * (rows - 1).coerceAtLeast(0)
                layout(width, height) {
                    var y = 0
                    for (r in 0 until rows) {
                        var x = 0
                        for (c in 0 until cols) {
                            val i = r * cols + c
                            if (i >= placeables.size) break
                            placeables[i].placeRelative(x, y)
                            KayaSceneModel.cellMinX[node.children[i].id] = x
                            x += colW[c] + gapPx
                        }
                        y += rowH[r] + gapPx
                    }
                }
            }
        }
        KayaCompose.KIND_RADIO ->
            // The choice contract inline: M3's radio idiom is a
            // selectable group of RadioButton rows. Every USER pick
            // emits with the group's identity tag — the select's
            // uncontrolled contract.
            Column(modifier = Modifier.selectableGroup()) {
                node.children.forEachIndexed { i, option ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier =
                            Modifier.selectable(
                                selected = node.value.toInt() == i,
                                onClick = {
                                    node.value = i.toDouble()
                                    KayaPresent.emitValueChanged(node.tag, i.toDouble())
                                },
                            ),
                    ) {
                        androidx.compose.material3.RadioButton(
                            selected = node.value.toInt() == i,
                            onClick = null,
                        )
                        Text(option.text)
                    }
                }
            }
        KayaCompose.KIND_PROGRESS ->
            // The dressed floor: M3's own LinearProgressIndicator —
            // determinate over the 0..=1 fraction, or the activity
            // flavor while indeterminate is on.
            if (node.indeterminate) {
                androidx.compose.material3.LinearProgressIndicator()
            } else {
                androidx.compose.material3.LinearProgressIndicator(
                    progress = { node.value.toFloat() })
            }
        KayaCompose.KIND_SCROLL ->
            // The vertical scroll viewport over its ONE child (the
            // scene enforces the count): verticalScroll over the
            // node's own ScrollState — the toolkit's real scrolling
            // machinery, which the runner's verbs read and drive.
            Box(
                rootFill.verticalScroll(node.scrollState)
            ) {
                node.children.firstOrNull()?.let { KayaRender(it) }
            }
        KayaCompose.KIND_COLUMN ->
            // Normalized default: children packed to the top at natural
            // size, leading-aligned (Alignment.Start), 8 dp between them.
            Column(
                modifier = rootFill.onGloballyPositioned {
                    kayaContainerExtents[node.id] = it.size.height.toDouble()
                    kayaContainerCross[node.id] = it.size.width.toDouble()
                },
                verticalArrangement = Arrangement.spacedBy(node.spacing.dp),
                horizontalAlignment = when (node.align) {
                    KayaCompose.ALIGN_CENTER -> Alignment.CenterHorizontally
                    KayaCompose.ALIGN_END -> Alignment.End
                    else -> Alignment.Start
                },
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
                        kayaCrossRects[child.id] = Pair(
                            it.positionInParent().x.toDouble(),
                            it.size.width.toDouble(),
                        )
                    }
                    if (child.grow > 0) cell = cell.weight(child.grow.toFloat())
                    if (node.align == KayaCompose.ALIGN_STRETCH) cell = cell.fillMaxWidth()
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
                modifier = rootFill.onGloballyPositioned {
                    kayaContainerExtents[node.id] = it.size.width.toDouble()
                    kayaContainerCross[node.id] = it.size.height.toDouble()
                },
                horizontalArrangement = Arrangement.spacedBy(node.spacing.dp),
                verticalAlignment = when (node.align) {
                    KayaCompose.ALIGN_CENTER -> Alignment.CenterVertically
                    KayaCompose.ALIGN_END -> Alignment.Bottom
                    else -> Alignment.Top
                },
            ) {
                node.children.forEach { child ->
                    var cell = Modifier.onGloballyPositioned {
                        kayaMainExtents[child.id] = it.size.width.toDouble()
                        kayaCrossRects[child.id] = Pair(
                            it.positionInParent().y.toDouble(),
                            it.size.height.toDouble(),
                        )
                    }
                    cell = cell.layout { measurable, constraints ->
                        val placeable = measurable.measure(constraints)
                        val fb = placeable[androidx.compose.ui.layout.FirstBaseline]
                        if (fb != androidx.compose.ui.layout.AlignmentLine.Unspecified) {
                            kayaBaselineOffsets[child.id] = fb.toDouble()
                        }
                        layout(placeable.width, placeable.height) { placeable.place(0, 0) }
                    }
                    if (child.grow > 0) cell = cell.weight(child.grow.toFloat())
                    if (node.align == KayaCompose.ALIGN_STRETCH) cell = cell.fillMaxHeight()
                    if (node.align == KayaCompose.ALIGN_BASELINE) cell = cell.alignByBaseline()
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
        KayaCompose.KIND_TEXTAREA -> {
            // The multi-line editor: the entry's exact contract
            // (uncontrolled state, identity-tag emits, model-driven
            // focus) over a multiline M3 TextField.
            val focusRequester = remember { FocusRequester() }
            TextField(
                value = node.text,
                onValueChange = { newValue ->
                    val value = kayaLf(newValue)
                    node.text = value
                    KayaPresent.emitTextChanged(node.tag, value)
                },
                singleLine = false,
                minLines = 3,
                modifier = Modifier
                    .focusRequester(focusRequester)
                    .onFocusChanged { state ->
                        if (state.isFocused) KayaSceneModel.focusedId = node.id
                    },
            )
            LaunchedEffect(KayaSceneModel.focusedId) {
                if (KayaSceneModel.focusedId == node.id) focusRequester.requestFocus()
            }
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
                    val value = kayaLf(newValue)
                    node.text = value
                    KayaPresent.emitTextChanged(node.tag, value)
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
    // The runner thread has no density; convert the 8-dp gap here,
    // where composition provides one (expect_fills sums it between
    // tracks).
    kayaDensity = LocalDensity.current.density.toDouble()
    // The size class, from the platform's own width in dp against the
    // 600dp boundary — the same boundary androidx's WindowSizeClass
    // draws, taken directly so the interpreter needs no extra artifact.
    KayaSceneModel.formFactor =
        if (LocalConfiguration.current.screenWidthDp >= 600) "regular" else "compact"
    if (KayaSceneModel.menubar.isEmpty()) {
        // No catalog: the surface keeps its exact pre-menus shape (no
        // phantom bar over scenes that declared no commands).
        KayaSceneModel.menuPresentation = "none"
        KayaSurface()
    } else {
        // The window catalog's phone lowering (DESIGN.md, Menus): the
        // catalog folds into the top app bar — promoted primaries as
        // real bar actions, everything in the overflow ⋮.
        // Stamped by the arm that renders, not inferred from the size
        // class above. Android has no menu-bar lowering yet, so this is
        // `overflow` in BOTH classes — which is the honest report, and
        // is what a tablet-width assertion would correctly fail on.
        KayaSceneModel.menuPresentation = "overflow"
        Column(modifier = Modifier.fillMaxSize()) {
            KayaMenuTopBar()
            Box(modifier = Modifier.weight(1f)) { KayaSurface() }
        }
    }

    // The system back gesture, the user-sovereign POP: enabled only
    // while the stack has entries (declared-ahead, the platform's own
    // OnBackPressedCallback model — the root's back still leaves the
    // app).
    androidx.activity.compose.BackHandler(
        enabled = KayaSceneModel.navEntries.isNotEmpty()
    ) { kayaUserBack() }

    KayaSceneModel.alertId?.let { alert ->
        // The platform's REAL modal dialog: M3 AlertDialog. Every
        // native dismissal (back, outside tap) IS the cancel slot;
        // the action row and the cancel button run the same answer
        // path the runner's alert_choose drives.
        AlertDialog(
            onDismissRequest = { kayaAnswerAlert(alert, KayaCompose.ALERT_CHOICE_CANCEL) },
            title = { Text(KayaSceneModel.alertTitle) },
            text = { Text(KayaSceneModel.alertMessage) },
            confirmButton = {
                Row {
                    KayaSceneModel.alertActions.forEachIndexed { index, label ->
                        TextButton(onClick = { kayaAnswerAlert(alert, index) }) {
                            Text(label)
                        }
                    }
                }
            },
            dismissButton = {
                TextButton(onClick = { kayaAnswerAlert(alert, KayaCompose.ALERT_CHOICE_CANCEL) }) {
                    Text(KayaSceneModel.alertCancel)
                }
            },
        )
    }
}

/** The one scene surface (sections scaffold | nav top | mounted root),
 * exactly the pre-menus KayaRoot body: the menus top bar stacks ABOVE
 * this so a catalog never disturbs the measured offer the layout
 * observations read. */
@Composable
private fun KayaSurface() {
    // Normalized default: the root is pinned to the top-leading corner,
    // not centered, so the scene packs into the top-left like AppKit/SwiftUI.
    Box(
        modifier = Modifier
            .fillMaxSize()
            // The normalized root inset: 16 units, applied before the
            // offer is measured so the available area is the content
            // box, exactly as the SwiftUI interpreter reads it.
            .padding(16.dp)
            .onGloballyPositioned { kayaAvailableSize = it.size },
        contentAlignment = Alignment.TopStart,
    ) {
        val activeSection =
            KayaSceneModel.selectedSection?.let { KayaSceneModel.sectionIndex[it] }
        if (KayaSceneModel.sections.isNotEmpty() && activeSection != null) {
            // Sections present: the M3 bottom bar is the phones'
            // idiom regardless of the ADVISORY hint (physics). Each
            // pane shows ITS stack's top (stacks are per-surface);
            // covered panes stay in the model, retained.
            KayaSectionsScaffold(activeSection)
        } else {
        val topEntry = KayaSceneModel.navEntries.lastOrNull()
        if (topEntry != null) {
            // The stack's top is the one visible screen; the covered
            // root below stays alive (retained-until-popped).
            topEntry.root?.let { KayaRender(it, isRoot = true) }
        } else {
            KayaSceneModel.root?.let { root ->
                // The wrapper hugs the mounted container, so its size IS
                // the root's — what expect_root_fills compares against the
                // offer recorded above.
                Box(Modifier.onGloballyPositioned { kayaRootSize = it.size }) {
                    KayaRender(root, isRoot = true)
                }
            }
        }
        }
    }
}

/**
 * The window catalog's phone materialization (DESIGN.md, Menus): an M3
 * TopAppBar whose actions slot carries the promoted primaries — icon
 * blob when present, text otherwise — and the overflow ⋮ holding the
 * ENTIRE catalog. Every affordance here routes through
 * [kayaActivateMenuItem]: chrome emits, one dispatch path.
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun KayaMenuTopBar() {
    TopAppBar(
        title = {
            Text(KayaSceneModel.navEntries.lastOrNull()?.title ?: KayaSceneModel.windowTitle)
        },
        actions = {
            // Promotion is CATALOG PREORDER, recomputed on every
            // catalog mutation: the walk below reads observable
            // children/primary snapshot state, so a structural append
            // or primary flip invalidates this composition — the
            // recompute IS the recomposition.
            kayaPromotedActions().forEach { item ->
                val enabled = kayaMenuEffectivelyEnabled(item)
                val icon = item.iconBitmap
                if (icon != null) {
                    IconButton(
                        onClick = { kayaActivateMenuItem(item, ByteArray(0)) },
                        enabled = enabled,
                    ) {
                        Image(bitmap = icon, contentDescription = item.label)
                    }
                } else {
                    TextButton(
                        onClick = { kayaActivateMenuItem(item, ByteArray(0)) },
                        enabled = enabled,
                    ) {
                        Text(item.label)
                    }
                }
            }
            KayaOverflowMenu()
        },
    )
}

/**
 * The overflow ⋮: one M3 DropdownMenu carrying the catalog. Top-level
 * grouping nodes render as labeled groups with dividers (the M3
 * dropdown's group idiom); a nested `menu` survives as a drill-in —
 * deterministic content swap with a back row, no cascade gymnastics —
 * and a nested `radio_group` stays inline with radio rows.
 */
@Composable
private fun KayaOverflowMenu() {
    var expanded by remember { mutableStateOf(false) }
    var drilled by remember { mutableStateOf<KayaMenuItem?>(null) }
    Box {
        IconButton(onClick = {
            drilled = null
            expanded = true
        }) { Text("⋮") }
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = {
                expanded = false
                drilled = null
            },
        ) {
            val close = {
                expanded = false
                drilled = null
            }
            // Promotion moves an action OUT of overflow: the promoted
            // set renders as real bar actions and is excluded from
            // every overflow row run (drill-ins included).
            val promotedIds = kayaPromotedActions().map { it.id }.toSet()
            val sub = drilled
            if (sub == null) {
                KayaSceneModel.menubar.forEachIndexed { i, group ->
                    if (i > 0) HorizontalDivider()
                    Text(
                        group.label,
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
                    )
                    if (group.kind == KayaCompose.MENU_KIND_RADIO_GROUP) {
                        // A bar-level radio group: a labeled group
                        // whose options use the checkmark idiom.
                        KayaRadioRows(group, ByteArray(0), close)
                    } else {
                        KayaMenuRows(
                            group.children.toList(),
                            ByteArray(0),
                            onDrill = { drilled = it },
                            onClose = close,
                            promoted = promotedIds,
                        )
                    }
                }
            } else {
                // The drill-in: a back row over the submenu's rows.
                DropdownMenuItem(
                    text = { Text("‹ ${sub.label}") },
                    onClick = { drilled = null },
                )
                HorizontalDivider()
                KayaMenuRows(
                    sub.children.toList(),
                    ByteArray(0),
                    onDrill = { drilled = it },
                    onClose = close,
                    promoted = promotedIds,
                )
            }
        }
    }
}

/**
 * One run of menu rows — the shared materialization for the overflow
 * catalog, a drilled submenu, and a context menu. `noun` is the
 * anchor's key path (empty off the window catalog); every leaf routes
 * through [kayaActivateMenuItem] and closes the menu (a leaf command
 * fires exactly one occurrence and the menu closes). `promoted` is the
 * promoted-primary id set: promotion moves an action OUT of overflow,
 * so those ids render no row here (empty off the window catalog —
 * context items are never promoted).
 */
@Composable
fun KayaMenuRows(
    items: List<KayaMenuItem>,
    noun: ByteArray,
    onDrill: (KayaMenuItem) -> Unit,
    onClose: () -> Unit,
    promoted: Set<Long> = emptySet(),
) {
    items.forEach { item ->
        when (item.kind) {
            KayaCompose.MENU_KIND_SEPARATOR -> HorizontalDivider()
            KayaCompose.MENU_KIND_MENU ->
                DropdownMenuItem(
                    text = { Text(item.label) },
                    trailingIcon = { Text("▸") },
                    enabled = kayaMenuEffectivelyEnabled(item),
                    onClick = { onDrill(item) },
                )
            KayaCompose.MENU_KIND_RADIO_GROUP -> KayaRadioRows(item, noun, onClose)
            KayaCompose.MENU_KIND_TOGGLE ->
                DropdownMenuItem(
                    text = { Text(item.label) },
                    // The platform's checkmark idiom: a trailing mark
                    // while checked, nothing while not.
                    trailingIcon = { if (item.checked) Text("✓") },
                    enabled = kayaMenuEffectivelyEnabled(item),
                    onClick = {
                        onClose()
                        kayaActivateMenuItem(item, noun)
                    },
                )
            KayaCompose.MENU_KIND_ACTION ->
                // A promoted primary renders in the bar, not here.
                if (!promoted.contains(item.id)) {
                    DropdownMenuItem(
                        text = { Text(item.label) },
                        enabled = kayaMenuEffectivelyEnabled(item),
                        onClick = {
                            onClose()
                            kayaActivateMenuItem(item, noun)
                        },
                    )
                }
            else ->
                DropdownMenuItem(
                    text = { Text(item.label) },
                    enabled = kayaMenuEffectivelyEnabled(item),
                    onClick = {
                        onClose()
                        kayaActivateMenuItem(item, noun)
                    },
                )
        }
    }
}

/** A radio group's options as RadioButton rows (inline wherever the
 * group appears — bar level or nested; the platform's checkmark
 * idiom). A pick routes through [kayaActivateMenuItem], which emits on
 * the GROUP with the option's index — the Choice contract. */
@Composable
fun KayaRadioRows(group: KayaMenuItem, noun: ByteArray, onClose: () -> Unit) {
    group.children.forEachIndexed { i, option ->
        DropdownMenuItem(
            text = { Text(option.label) },
            leadingIcon = {
                androidx.compose.material3.RadioButton(
                    selected = group.value.toInt() == i,
                    onClick = null,
                )
            },
            enabled = kayaMenuEffectivelyEnabled(option),
            onClick = {
                onClose()
                kayaActivateMenuItem(option, noun)
            },
        )
    }
}

/**
 * The promoted primaries: the first k primary actions in CATALOG
 * PREORDER — top-level grouping nodes in menubar-append order, then
 * each node's children in append order, depth-first; creation time is
 * irrelevant. k = [KayaCompose.MENU_PROMOTED_CAPACITY], this
 * platform's own idiom. Call from composition: the observable reads
 * make every catalog mutation recompute the set.
 */
fun kayaPromotedActions(): List<KayaMenuItem> {
    val promoted = ArrayList<KayaMenuItem>()
    fun walk(item: KayaMenuItem) {
        if (item.kind == KayaCompose.MENU_KIND_ACTION && item.primary) promoted.add(item)
        item.children.forEach { walk(it) }
    }
    KayaSceneModel.menubar.forEach { walk(it) }
    return promoted.take(KayaCompose.MENU_PROMOTED_CAPACITY)
}

/** Effective enablement: an item is reachable only while it AND every
 * ancestor grouping node is enabled — the inherited-disabled read
 * expect_menu asserts, and what lifts when the ancestor re-enables. */
fun kayaMenuEffectivelyEnabled(item: KayaMenuItem): Boolean {
    var cur: KayaMenuItem? = item
    while (cur != null) {
        if (!cur.enabled) return false
        cur = cur.parent
    }
    return true
}

/**
 * THE activation route — every affordance lands here: a rendered row
 * (bar action, overflow, drill-in, context), the harness's
 * menu_activate, and a shortcut. Chrome emits (the user route);
 * programmatic prop writes never come here. The model mirrors the
 * user state exactly as the checkbox/slider nodes do, and the noun
 * rides every emission verbatim.
 */
fun kayaActivateMenuItem(item: KayaMenuItem, noun: ByteArray) {
    // A disabled item's row is inert and its chord fires nothing —
    // the native menu behavior, uniform across the routes.
    if (!kayaMenuEffectivelyEnabled(item)) return
    when (item.kind) {
        KayaCompose.MENU_KIND_ACTION -> KayaPresent.emitMenuActivated(item.id, noun)
        KayaCompose.MENU_KIND_TOGGLE -> {
            item.checked = !item.checked
            KayaPresent.emitMenuToggled(item.id, noun, item.checked)
        }
        KayaCompose.MENU_KIND_RADIO_OPTION -> {
            // The Choice contract: keyed by the GROUP, integral index
            // — and re-selecting the selected option is NOT a change:
            // no write, no emission (the platform's own change route
            // behaves exactly so).
            val group = item.parent ?: return
            val index = group.children.indexOfFirst { it.id == item.id }
            if (index < 0 || group.value.toInt() == index) return
            group.value = index.toDouble()
            KayaPresent.emitMenuValueChanged(group.id, noun, index.toDouble())
        }
    }
}

/**
 * The shortcut dispatch table IS the window catalog: window-anchored
 * actions matched on their canonical spelling (the root already
 * rejected shortcuts anywhere else, and context items never carry
 * one). Both the hardware-key route and the harness's shortcut verb
 * land here, and the hit activates through [kayaActivateMenuItem] —
 * the SAME menu_activated the row emits. Returns false when no
 * catalog action owns the chord.
 */
fun kayaDispatchShortcut(spelling: String): Boolean {
    fun find(items: List<KayaMenuItem>): KayaMenuItem? {
        for (item in items) {
            if (item.shortcut == spelling &&
                (item.kind == KayaCompose.MENU_KIND_ACTION ||
                    item.kind == KayaCompose.MENU_KIND_TOGGLE ||
                    item.kind == KayaCompose.MENU_KIND_RADIO_OPTION)
            ) {
                return item
            }
            find(item.children)?.let { return it }
        }
        return null
    }
    val item = find(KayaSceneModel.menubar) ?: return false
    // A disabled item owns its chord but fires nothing (the helper's
    // enablement gate — native menu behavior).
    kayaActivateMenuItem(item, ByteArray(0))
    return true
}

/**
 * Resolve a `>`-joined label path wherever the item SURFACED: while a
 * context menu is OPEN it owns resolution EXCLUSIVELY — paths walk the
 * attached roots (a grouping root's label IS a path segment, exactly
 * as the drill-in surfaces it), and a miss is a miss, never a bar
 * fallback; otherwise the window catalog — bar and overflow are one
 * semantic tree on this host. Returns the item plus the noun its
 * anchor stamps.
 */
fun kayaResolveMenuPath(path: String): Pair<KayaMenuItem, ByteArray>? {
    val segments = path.split('>')
    if (segments.isEmpty() || segments.any { it.isEmpty() }) return null
    val openWidget = KayaSceneModel.openContextWidget
    if (openWidget != null) {
        val attachment = KayaSceneModel.contextMenus[openWidget] ?: return null
        return kayaMenuDescend(attachment.roots.toList(), segments)
            ?.let { Pair(it, attachment.noun) }
    }
    return kayaMenuDescend(KayaSceneModel.menubar.toList(), segments)
        ?.let { Pair(it, ByteArray(0)) }
}

/** Walk one label path through the semantic tree (separators have no
 * label and never match). Paths address the tree directly:
 * "Sort>Date" is option Date in group Sort, "Sort" the group. */
private fun kayaMenuDescend(
    roots: List<KayaMenuItem>,
    segments: List<String>,
): KayaMenuItem? {
    var candidates = roots
    var current: KayaMenuItem? = null
    for (segment in segments) {
        current = candidates.firstOrNull {
            it.kind != KayaCompose.MENU_KIND_SEPARATOR && it.label == segment
        } ?: return null
        candidates = current.children
    }
    return current
}

/// A user-driven back on the top entry: an intercept_back-armed top
/// emits back_requested and nothing pops (the veto class); an unarmed
/// top pops here and reconciles the core post-fact.
/** Resolve a `scroll#i` target against the creation-order registry. */
internal fun scrollTarget(spec: String): KayaNode? {
    val bits = spec.split("#")
    if (bits.size != 2 || bits[0] != "scroll") return null
    if (bits[1] == "last") return KayaSceneModel.scrolls.lastOrNull()
    val i = bits[1].toIntOrNull() ?: return null
    return KayaSceneModel.scrolls.getOrNull(i)
}

/** The sections materialization: the M3 bottom NavigationBar (the
 * platform's dominant idiom — hints are ignored here by physics).
 * The bar's item taps are the USER route: they move the selection
 * and emit section_selected; a programmatic select_section lands in
 * the model quietly. Each pane renders its own stack's top. */
@Composable
fun KayaSectionsScaffold(active: KayaSection) {
    Column(modifier = Modifier.fillMaxSize()) {
        Box(modifier = Modifier.weight(1f)) {
            val top = active.entries.lastOrNull()
            val pane = top?.root ?: active.root
            pane?.let { KayaRender(it, isRoot = true) }
        }
        NavigationBar {
            KayaSceneModel.sections.forEach { section ->
                NavigationBarItem(
                    selected = section.id == active.id,
                    onClick = { kayaUserSelectsSection(section.id) },
                    icon = {},
                    label = { Text(section.title) },
                )
            }
        }
    }
}

/** The user's switch: selection moves and EMITS (the bar-tap route —
 * the harness's select_section drives this same path). */
fun kayaUserSelectsSection(sid: Long) {
    if (KayaSceneModel.selectedSection == sid) return
    KayaSceneModel.selectedSection = sid
    KayaPresent.emitSectionSelected(0, sid)
}

fun kayaUserBack() {
    // Back routes to the ACTIVE section's stack when sections are
    // present (back never switches sections — DESIGN.md, Sections).
    val activeStack =
        KayaSceneModel.selectedSection
            ?.let { KayaSceneModel.sectionIndex[it] }
            ?.entries
            ?.takeIf { KayaSceneModel.sections.isNotEmpty() }
    if (activeStack != null) {
        val top = activeStack.lastOrNull() ?: return
        if (top.interceptBack) {
            KayaPresent.emitBackRequested(top.id)
        } else {
            activeStack.removeAt(activeStack.size - 1)
            KayaSceneModel.navIndex.remove(top.id)
            KayaPresent.emitEntryPopped(top.id)
        }
        return
    }
    val top = KayaSceneModel.navEntries.lastOrNull() ?: return
    if (top.interceptBack) {
        KayaPresent.emitBackRequested(top.id)
    } else {
        KayaSceneModel.navEntries.removeAt(KayaSceneModel.navEntries.size - 1)
        KayaSceneModel.navIndex.remove(top.id)
        KayaCompose.refreshNavTitle()
        KayaPresent.emitEntryPopped(top.id)
    }
}

/// The one answer path: clear the model (the dialog leaves the tree)
/// and emit — an action index or the cancel sentinel.
fun kayaAnswerAlert(alert: Long, choice: Int) {
    KayaSceneModel.alertId = null
    KayaPresent.emitAlertResult(alert, choice)
}
