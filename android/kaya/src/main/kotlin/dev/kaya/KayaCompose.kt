package dev.kaya

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.ContentResolver
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Environment
import android.os.PersistableBundle
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.util.Base64
import android.util.Log
import android.view.KeyEvent
import android.webkit.MimeTypeMap
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.compose.setContent
import androidx.compose.foundation.Image
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
// The entry/textarea path (docs/undo-plan.md §1.4): the foundation field
// that owns a TextFieldState, plus the M3 dressing that makes it look
// like the TextField it replaced. `undoState` and its five members are
// the ONLY experimental surface here at foundation 1.7.5 — measured, by
// removing the opt-in and reading the 21 errors.
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.input.TextFieldLineLimits
import androidx.compose.foundation.text.input.setTextAndPlaceCursorAtEnd
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
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
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
// Material 3 adaptive: Android's OWN list-detail container and the
// arrangement it lays out from. Imported rather than written out
// inline because the swap touches a dozen of these names, and two of
// them do not live where they read like they should:
// calculatePaneScaffoldDirective is in `.layout`, not in `.adaptive`
// beside currentWindowAdaptiveInfo.
import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfo
import androidx.compose.material3.adaptive.layout.AnimatedPane
import androidx.compose.material3.adaptive.layout.ListDetailPaneScaffold
import androidx.compose.material3.adaptive.layout.ListDetailPaneScaffoldDefaults
import androidx.compose.material3.adaptive.layout.ListDetailPaneScaffoldRole
import androidx.compose.material3.adaptive.layout.PaneAdaptedValue
import androidx.compose.material3.adaptive.layout.PaneScaffoldDirective
import androidx.compose.material3.adaptive.layout.ThreePaneScaffoldDestinationItem
import androidx.compose.material3.adaptive.layout.ThreePaneScaffoldValue
import androidx.compose.material3.adaptive.layout.calculatePaneScaffoldDirective
import androidx.compose.material3.adaptive.layout.calculateThreePaneScaffoldValue
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
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
import androidx.compose.ui.node.RootForTest
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.VisualTransformation
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
    /**
     * KAYA'S MODEL MIRROR of the widget's text — what the app was last
     * told, and what a label renders.
     *
     * For an entry or a textarea this is NO LONGER what the field reads
     * from: [textState] is. The two are written together by
     * [kayaWriteText] on kaya's side and reconciled by the observer in
     * KayaTextField on the widget's side, and the DIFFERENCE between
     * them is load-bearing rather than incidental — it is what tells a
     * user edit apart from the echo of kaya's own write (the echo
     * doctrine; docs/undo-plan.md §1.4's "two new failure classes").
     */
    var text by mutableStateOf("")

    /**
     * THE TEXT WIDGET'S OWN STATE (entry/textarea only), and the reason
     * this backend moved off `TextField(value:, onValueChange:)`.
     *
     * The legacy path is DISQUALIFIED, measured rather than argued
     * (docs/undo-plan.md §1.4): `CoreTextField` remembers an INTERNAL
     * `UndoManager` — unreachable by type, `it is internal in file` —
     * Ctrl+Z drives it today, and kaya's programmatic writes ENTER it.
     * Worst case measured on the emulator: a field the user never
     * touched, one app write, one Ctrl+Z, and the field is EMPTY with
     * `onValueChange` firing — i.e. kaya emits a phantom `text_changed`
     * for an edit nobody made and the app's own write is lost, with the
     * app's model dutifully following it down. There is no knob, no
     * `canUndo`, and no `undo()` on that path, so neither D7 nor D6's
     * native tier is expressible there at all.
     *
     * `TextFieldState` answers all three: a programmatic write CLEARS
     * the history (D7 for free, both spellings), and
     * `undoState.canUndo/undo()/redo()` are readable and callable, which
     * is what D6's routing needs on the one platform where kaya's own
     * menu item is the ONLY undo affordance a phone has (no hardware
     * keyboard, and the text toolbar offers Copy/Paste/Cut with no Undo
     * at API 35).
     *
     * `by lazy` because only two of the fourteen kinds have text to
     * edit, and a `TextFieldState` per label would be a state object per
     * node for nothing. NOT thread-safe by choice: every touch is on the
     * UI thread (apply hops there, the harness goes through `onUi`),
     * which is the same rule the rest of this model already keeps.
     */
    val textState by lazy(LazyThreadSafetyMode.NONE) {
        androidx.compose.foundation.text.input.TextFieldState("")
    }
    // The accessibility identifier and label (universal props). The
    // identifier is never spoken — it lowers to Modifier.testTag, which
    // is what surfaces as the automation key — while the label IS what
    // TalkBack reads (contentDescription). Empty means unset: the
    // platform keeps whatever it derives from the control's own content.
    var a11yId by mutableStateOf("")
    var a11yLabel by mutableStateOf("")
    var a11yHint by mutableStateOf("")

    /** The widget's accept list, verbatim. Recorded here because the
     * paste hook and the standard commands' enablement both read it off
     * the focused node. Empty means the widget takes nothing. */
    var accepts by mutableStateOf("")
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

// THE DEPTH-STUB HELPER IS GONE AGAIN, and its own doc asked for this:
// it lived here through the clipboard depth slice, was removed the day
// those arms landed, came back for the undo slice, and is removed now
// that the undo arm's last call site is gone. Dead code kept "for later"
// is what a reader has to reason about for nothing.
//
// The next Compose depth slice re-adds it, in exactly this shape — a
// CALL and not a sentence, because tools/check-stubs.sh and
// tools/check-steps.sh both read the call and neither can see a backend
// that refuses in its own words:
//
//     internal fun depthStub(scene: String): Nothing =
//         error("kaya: the $scene scene is not yet materialized on this " +
//               "backend — it is a depth slice; see CLAUDE.md's sequencing")

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
    /// A counter bumped whenever what the system clipboard OFFERS may
    /// have moved (a copy went out, a foreign seed landed). It carries
    /// no information; reading it is what SUBSCRIBES a composition to
    /// clipboard changes.
    ///
    /// It exists because the clipboard is not snapshot state and
    /// OnPrimaryClipChangedListener cannot stand in for one: dispatch
    /// is itself focus-gated, per listener, with no catch-up callback
    /// on regaining focus (docs/clipboard-plan.md §7, measured in
    /// ClipboardService's own source). So enablement is RE-DERIVED
    /// rather than pushed — at activation, on focus change (focusedId
    /// and accepts are both observable already), and here.
    var clipboardGeneration by mutableStateOf(0)
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
    /// Does this window ASK for list-detail (wprop 6). Whether it GETS
    /// it is the size class's answer, resolved in the render arm.
    var listDetail by mutableStateOf(false)
    /// The list-detail presentation the render arm ACTUALLY took —
    /// stamped by the arm that ran, never derived from `listDetail` or
    /// the width, so expect_split cannot agree with the lowering by
    /// construction (docs/traps.md).
    var splitPresentation = "stacked" // split | stacked
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
    // NAMED entryWidgets, not `entries`: the navigation stack is
    // `navEntries`, and while this registry was also called `entries` the
    // wrong one compiled clean — both are lists, so a harness verb that
    // meant "how deep is the nav stack" silently counted text-entry
    // WIDGETS instead. Caught in review, not by any compiler. The fix is
    // the name, because no gate can see a type-correct wrong field.
    val entryWidgets = ArrayList<KayaNode>()
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

/**
 * One representation as this side holds it, before it crosses to the
 * core. FLATTENED at the boundary rather than marshalled as a struct —
 * [KayaPresent.emitClipboardResult] and [KayaPresent.emitPasted] take
 * the fields as parallel arguments, exactly as emitFileDialogResult
 * takes parallel arrays, and the JNI thunk assembles the C struct.
 *
 * Which field carries what is the closed sum's spelling here: text and
 * html ride `text`, an image rides `bytes`, a CUSTOM format's id rides
 * `text` with its payload in `bytes`, and files ride `locators` (the
 * documents' own `content://` URIs) beside `names` of the same length.
 */
internal class KayaClipValue(
    val clip: Int,
    val text: String = "",
    val bytes: ByteArray = ByteArray(0),
    val locators: Array<String> = emptyArray(),
    val names: Array<String> = emptyArray(),
)

/**
 * Split an accept list into the closed kinds it names and the custom
 * ids it names, in the order the list gave them.
 *
 * The mirror of wire.rs's parse_accept_list (and of KayaSwiftUI's
 * kayaParseAcceptList): the STRING is the contract, so a second reading
 * of it would be a second contract. A token that is not one of the four
 * closed names IS a custom format id — the set is half open-ended,
 * which is why an accept list is not a mask.
 */
internal fun kayaParseAcceptList(list: String): Pair<Int, List<String>> {
    var kinds = 0
    val custom = ArrayList<String>()
    for (token in list.split(' ', '\t', '\n').filter { it.isNotEmpty() }) {
        when (token) {
            "text" -> kinds = kinds or KayaCompose.CLIP_TEXT
            "html" -> kinds = kinds or KayaCompose.CLIP_HTML
            "image" -> kinds = kinds or KayaCompose.CLIP_IMAGE
            "files" -> kinds = kinds or KayaCompose.CLIP_FILES
            else -> custom.add(token)
        }
    }
    return Pair(kinds, custom)
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
    private const val SPEC_HASH: ULong = 0x69c07d5216db7eb8uL

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
    private const val APPLY_PRESENT_FILE_DIALOG = 24

    /** The clipboard pair: a copy going out, and the privileged read
     * asking for one back. */
    private const val APPLY_COPY = 25
    private const val APPLY_READ_CLIPBOARD = 26

    /**
     * A1's clear (docs/undo-plan.md §3): a core undo group committed, so
     * the FOCUSED editable's native text-undo history goes with it.
     *
     * TARGETLESS ON THE WIRE BY DESIGN — the record names a window and
     * nothing else, because the core does not know what holds focus and
     * this backend does. It is the keystone of the ledger's total order:
     * the episode was banked before the clear, so every episode begins
     * with an EMPTY native stack, the native stack can never reach past
     * the current episode's start, and "ask the focused text first" IS
     * "ask the most recent first".
     */
    private const val APPLY_CLEAR_UNDO = 27
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
    private const val WPROP_LIST_DETAIL = 6
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
    private const val PROP_A11Y_HINT = 14

    /** Which clip representations this widget accepts: the ACCEPT
     * LIST, a space-separated string of the closed kind names and any
     * custom format ids. Not a mask — half the set is open-ended. */
    private const val PROP_ACCEPTS = 15
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
     * The clip representation masks (wire.rs's CLIP_*). BIT POSITIONS,
     * not an ordinal: a copy carries several at once and a widget
     * accepts several, so both ride as a mask. Their descending order —
     * custom, files, image, html, text — is the CANONICAL one, which is
     * richness order and therefore preference order (wire.rs,
     * write_clip_fields).
     *
     * A PRIVATE MIRROR, like KayaSwiftUI's (kayaClipText … kayaClipCustom).
     * check-verbs' general constant sweep matches the
     * APPLY_/KIND_/PROP_/COMMAND_/VALUE_/MENU_KIND_/MPROP_ prefixes and
     * stops, so this family had nothing holding it to the Rust at all;
     * it is now pinned by that gate's own clip_mirrors clause, name and
     * value together, against crates/kaya/src/wire.rs. Every rust-native
     * backend reads the source instead (gtk.rs says
     * `crate::wire::CLIP_FILES` and the compiler holds it there), which
     * an interpreter cannot — and the drift would be SILENT: `present
     * and CLIP_IMAGE` against a copy that spells image 8 reads the FILES
     * slot as a picture, and the leg fails describing the wrong content
     * one layer away from the wrong constant.
     */
    internal const val CLIP_TEXT = 1
    internal const val CLIP_HTML = 2
    internal const val CLIP_IMAGE = 4
    internal const val CLIP_FILES = 8
    internal const val CLIP_CUSTOM = 16

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
            // COPY CARRIES BLOBS TOO — the image, and every custom
            // format's bytes — and they die with the batch exactly as a
            // prop's do. WITHOUT THIS ARM THE MISS IS SILENT: the
            // handles resolve to null on the UI thread, the copy ships
            // text and html only, and nothing anywhere names the cause.
            // (KayaSwiftUI had to add exactly this arm, for exactly
            // this reason.)
            //
            // Walked GENERICALLY off the header's slot count rather
            // than by representation: the header says how many values
            // follow, and a value that is not a blob is skipped by the
            // same arithmetic. Absolute reads, so the record cursor
            // above is untouched.
            if (kind == APPLY_COPY) {
                val body = start + 8
                val slots = b.getInt(body + 16)
                var at = body + 24
                repeat(slots) {
                    val type = b.getInt(at)
                    val len = b.getInt(at + 4)
                    if (type == VALUE_BLOB) {
                        val handle = b.getLong(at + 8)
                        KayaPresent.blobData(handle)?.let { blobs[handle] = it }
                    }
                    // Values self-pad to 8 (wire.rs, write_value).
                    at += 8 + len
                    if (at % 8 != 0) at += 8 - at % 8
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
                        KIND_ENTRY -> KayaSceneModel.entryWidgets.add(node)
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
                        // D7 + A3 ride HERE, in the apply arm, rather
                        // than at the authoring site: an inverse the
                        // CORE writes (§3's coarse episode restore) is
                        // an ordinary SetProp Text record, so it travels
                        // the same clear a forward write does with
                        // nothing special-casing it.
                        PROP_TEXT ->
                            kayaWriteText(KayaSceneModel.nodes[id]!!, kayaLf(readString(b)))
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
                        PROP_A11Y_HINT ->
                            KayaSceneModel.nodes[id]!!.a11yHint = readString(b)
                        PROP_ACCEPTS ->
                            // The ACCEPT LIST verbatim: kind names and
                            // custom ids, space separated. Not a mask —
                            // half the set is open-ended. Stored
                            // unparsed, exactly as the mac and GTK arms
                            // store it, because the STRING is the
                            // contract: kayaParseAcceptList splits it at
                            // each use (the paste split, and Paste's
                            // enablement), and a second stored form
                            // would be a second contract. EMPTY IS
                            // UNSET, and it is not the same as "takes
                            // nothing": an undeclared widget still
                            // pastes, through the platform's own
                            // insertion.
                            KayaSceneModel.nodes[id]!!.accepts = readString(b)
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
                        WPROP_LIST_DETAIL -> KayaSceneModel.listDetail = readBool(b)
                        else -> error("kaya: unknown window prop $prop")
                    }
                }
                // The scene core rejects create_window on this host
                // (no KAYA_CAP_AUX_WINDOWS) before any apply is
                // emitted; reaching these arms means the core and
                // this interpreter disagree — fail loudly.
                APPLY_CREATE_WINDOW -> error("kaya: aux window apply on a capability-less host")
                APPLY_DESTROY_WINDOW -> error("kaya: aux window apply on a capability-less host")
                APPLY_COPY -> {
                    // { u32 present; u32 file_count; u32 custom_count;
                    // u32 reserved; u32 slots; u32 reserved } then a
                    // Values block in the CANONICAL ORDER: custom
                    // pairs, files, image, html, text — descending clip
                    // value, which is descending richness. Read in that
                    // order and the preference order is right for free.
                    val present = b.int
                    val fileCount = b.int
                    val customCount = b.int
                    b.int // reserved
                    b.int // slots — the prefetch walk's business
                    b.int // reserved
                    val custom = ArrayList<Pair<String, ByteArray>>(customCount)
                    repeat(customCount) {
                        val id = readString(b)
                        // The bytes rode as a batch-local handle; the
                        // pump prefetched them before the table turned
                        // over (see collectBlobs).
                        custom.add(Pair(id, blobs[readBlobHandle(b)] ?: ByteArray(0)))
                    }
                    // LOCATORS, not kaya handles — and on this platform
                    // a locator IS the `content://` URI the document
                    // already has (android.rs, UriSource::locator).
                    val files = (0 until fileCount).map { readString(b) }
                    val image =
                        if (present and CLIP_IMAGE != 0) blobs[readBlobHandle(b)] else null
                    val html = if (present and CLIP_HTML != 0) readString(b) else null
                    val text = if (present and CLIP_TEXT != 0) readString(b) else null
                    kayaCopyToClipboard(text, html, image, files, custom)
                }
                APPLY_READ_CLIPBOARD -> {
                    // { u64 request } then one Str: the accept list.
                    val request = b.long
                    val accepting = readString(b)
                    kayaAnswerClipboardRead(request, accepting)
                }
                APPLY_CLEAR_UNDO -> {
                    // A1 (docs/undo-plan.md §3): { u64 window }, and
                    // nothing else — the record is TARGETLESS because the
                    // core cannot know what holds focus and this backend
                    // can. Android is one Activity and one surface, so
                    // the window is read and dropped: there is no second
                    // surface for a focused field to be in.
                    b.long // window
                    kayaClearUndoForGroup()
                }
                APPLY_PRESENT_FILE_DIALOG -> {
                    b.long // window: 0, the one surface on this host
                    val dialog = b.long
                    val multiple = b.int != 0
                    b.int // pad
                    val filterValues = b.int
                    b.int // pad
                    // Read IN PAIRS: label then extensions, the grouping
                    // IS the encoding (KayaSwiftUI decodes it the same
                    // way). The label is the panel's own affordance and
                    // an intent has nowhere to put it; the extensions
                    // are space-separated and may carry dots. ADVISORY
                    // on every platform — a default view, never a
                    // guarantee, so the guest still validates what it
                    // got.
                    val extensions = mutableListOf<String>()
                    repeat(filterValues / 2) {
                        readString(b) // the label
                        readString(b).split(" ").forEach { ext ->
                            val trimmed = ext.trim('.')
                            if (trimmed.isNotEmpty()) extensions.add(trimmed)
                        }
                    }
                    kayaPresentFileDialog(dialog, multiple, extensions)
                }
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
                        // — but the role CHANGES BEHAVIOR, and that
                        // half is not cosmetic: activation performs
                        // cut/copy/paste on the focused widget instead
                        // of reporting to the app
                        // (kayaPerformClipboardRole), and enablement
                        // becomes the intersection of what the
                        // clipboard offers and what the focused widget
                        // accepts (kayaRoleEnabled). Snapshot state, so
                        // a role arriving after the bar was built
                        // recomposes the rows that read it.
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
                            //
                            // THE EMISSION IS EXPLICIT AND THE OBSERVER
                            // IS SILENT, which is the migration's shape
                            // everywhere: kayaWriteText moves the model
                            // and the widget together, so the snapshot
                            // observer sees them agree and reports
                            // nothing. A clear that emitted twice would
                            // bank two episodes for one act.
                            val node = KayaSceneModel.nodes[id]!!
                            kayaWriteText(node, "")
                            KayaPresent.emitTextChanged(
                                node.tag, "", KayaSceneModel.focusedId == id, false)
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
    /**
     * THE REAL-KEYSTROKE TYPING VERB (harness.rs `Stage::type_text`,
     * whose six numbered points this implements), on Android.
     *
     * POINT 1 — THE PLATFORM'S OWN INPUT PATH. An app may not INJECT
     * events (that is `INJECT_EVENTS`, a signature permission), but it
     * may DISPATCH one into its own window, and measured, that reaches
     * the focused field's key handler and drives the field's real undo
     * stack: `dispatchKeyEvent(KEYCODE_Z + META_CTRL_ON)` undid typed
     * text on both text paths (probe §4/H). So the verb needs no adb, no
     * permission and no instrumentation here — which is more than GTK
     * offers, and is what makes the delegated tier testable on this lane.
     * The keycodes and meta state come from the platform's own
     * `KeyCharacterMap`, so a capital letter really does arrive as
     * shift-down, key-down, key-up, shift-up.
     *
     * POINT 2 — WHATEVER HOLDS FOCUS RECEIVES IT: the events go into the
     * Activity's dispatch, and the platform resolves the destination. A
     * keystroke's destination is the routing question D6 asks, and
     * answering it here in kaya would make the verb agree with itself.
     *
     * POINT 3 — IT APPENDS, and on this platform it appends WITHOUT a
     * caret move, which is measured rather than assumed. macOS is what
     * makes point 3 a contract (making a field first responder SELECTS
     * ITS WHOLE CONTENTS); Compose does no such thing — typing `tea`,
     * focusing away, focusing back and typing `s` gives `teas`, and so
     * does typing after a programmatic `setTextAndPlaceCursorAtEnd`. AND
     * AN EXPLICIT CARET MOVE WOULD BE WRONG HERE: the only way to place
     * the cursor from app code is `TextFieldState.edit {}`, which commits
     * and therefore CLEARS the undo history — the verb would destroy the
     * very stack it exists to build.
     *
     * POINT 4 — IT BLOCKS UNTIL THE TEXT HAS LANDED, past the widget AND
     * past this backend's own observation, so the app has heard every
     * keystroke before the next step runs. This is an ACTION, and actions
     * are not retried: a following `menu_activate "Edit>Undo"` has none
     * of the POLL_DEADLINE cover an `expect` would give it, and a race
     * there reads as a broken undo rather than a missed keystroke.
     *
     * POINT 6 — PRINTABLE ASCII ONLY, and a character this keyboard
     * layout cannot generate is a loud step failure rather than a
     * silently dropped keystroke.
     */
    private fun kayaTypeAtFocus(activity: ComponentActivity, text: String): String? {
        if (text.isEmpty()) return "type wants some text to type"
        val map = android.view.KeyCharacterMap.load(
            android.view.KeyCharacterMap.VIRTUAL_KEYBOARD)
        for (c in text) {
            val events = map.getEvents(charArrayOf(c))
                ?: return "type: this keyboard layout cannot generate ${c.code} ($c)"
            // ONE UI-THREAD HOP PER CHARACTER, so a runloop turn passes
            // between them exactly as it does between a user's keystrokes.
            onUi(activity) {
                val now = android.os.SystemClock.uptimeMillis()
                for (e in events) {
                    // Rebuilt rather than replayed: the events a
                    // KeyCharacterMap hands back carry zeroed timestamps
                    // and no input source, and a key event with no source
                    // is not the thing a keyboard delivers.
                    activity.dispatchKeyEvent(
                        KeyEvent(
                            now, now, e.action, e.keyCode, 0, e.metaState,
                            android.view.KeyCharacterMap.VIRTUAL_KEYBOARD, e.scanCode, 0,
                            android.view.InputDevice.SOURCE_KEYBOARD,
                        ),
                    )
                }
            }
        }
        kayaSettleTypedText(activity)
        return null
    }

    /**
     * Point 4's wait: the typing has landed when this backend's MODEL has
     * caught up with the WIDGET, because that is one turn past the
     * emission — the observer in KayaTextField assigns `node.text` and
     * emits in the same step, so an agreeing pair means the app has heard
     * every keystroke.
     *
     * A TIMEOUT IS NOT A VERDICT. Nothing focused is legitimate under the
     * contract (point 2), and a following assertion is what reports the
     * mismatch; this says so on the record and returns.
     */
    private fun kayaSettleTypedText(activity: ComponentActivity) {
        repeat(200) {
            val settled = onUi(activity) {
                val node = kayaFocusedTextNode() ?: return@onUi true
                node.text == kayaLf(node.textState.text.toString())
            }
            if (settled) return
            Thread.sleep(5)
        }
        Log.e(
            "kaya",
            "KAYA_UNDO_TRACE: typed text never settled — the model and the widget " +
                "still disagree after 1s, so the app has not heard the last keystrokes"
        )
    }

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
    /// What the live picker is REALLY showing, or null when none is —
    /// read out of DocumentsUI's own tree through the harness
    /// accessibility service, because the picker is ANOTHER APP and
    /// there is nothing in this process to ask.
    ///
    /// Null when the service is not enabled, which fails every
    /// expect_file_dialog rather than passing quietly: a leg the runner
    /// forgot to arm must look like a failure, not like a picker that
    /// never appeared.
    private fun kayaFileDialogState(): Pair<String, List<String>>? =
        KayaHarnessAccessibility.live?.pickerState()

    /// The directory THE GUEST WILL USE — and on Android that is NOT the
    /// temp directory, which is the one thing this had to get right.
    ///
    /// `java.io.tmpdir` and the `TMPDIR` environment variable are the
    /// same string here (the app's cache dir), so a JVM guest and a Rust
    /// guest really do agree on it without runner involvement — the old
    /// comment was correct. It is still the wrong answer: DocumentsUI
    /// browses document PROVIDERS, and no provider exposes another app's
    /// private storage, so a picker aimed at the cache dir is aimed at
    /// somewhere it cannot go and lands on Recent instead — silently,
    /// with no error anywhere (measured).
    ///
    /// The shared Documents collection is the directory that satisfies
    /// both halves: an app targeting 35 can create and fill directories
    /// under it with ordinary file I/O and no storage permission
    /// (measured), and it is exactly what the ExternalStorage provider
    /// publishes. The guest computes the same place from the
    /// `EXTERNAL_STORAGE` environment variable, which Android sets in
    /// every app process.
    private fun kayaTempDir(): String =
        android.os.Environment
            .getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_DOCUMENTS)
            .path
            .trimEnd('/')

    /// `$TMP` and `$PID` in a scene path — the same vocabulary
    /// KayaSwiftUI expands, enforced across both by check-verbs. An
    /// interpreter that leaves a token alone uses it as a LITERAL path
    /// segment, which is a directory that cannot exist, and a picker
    /// pointed at one silently shows somewhere else (docs/traps.md).
    ///
    /// WHOLE NAMES, not prefixes: replacing "$TMP" by text also eats the
    /// front of "$TMPDIR" and leaves "<tmp>DIR", a path wrong in a way
    /// that reads as the scene author's typo rather than the expander's.
    private fun kayaExpandPath(path: String): String {
        val known = mapOf("TMP" to kayaTempDir(), "PID" to android.os.Process.myPid().toString())
        val out = StringBuilder()
        var i = 0
        while (i < path.length) {
            if (path[i] != '$') {
                out.append(path[i])
                i += 1
                continue
            }
            var end = i + 1
            while (end < path.length && (path[end].isUpperCase() || path[end] == '_')) {
                end += 1
            }
            val name = path.substring(i + 1, end)
            out.append(known[name] ?: "$" + name)
            i = end
        }
        return out.toString()
    }

    /// Where the NEXT picker opens. Armed by file_dialog_goto and
    /// applied at presentation, exactly as the mac arm does it: the
    /// initial location rides the INTENT, so it can only be said while
    /// the intent is being built.
    private var kayaPendingPickerDirectory: String? = null

    /// The live picker's dialog id, held so a second present can be
    /// refused and so the launcher can be released once. Null when none
    /// is up.
    private var kayaLivePickerDialog: Long? = null
    private var kayaLivePickerLauncher: ActivityResultLauncher<Intent>? = null

    /// Point the next picker at a directory. The harness placing the app
    /// where a user would have navigated — set_text's tier, not a stamp:
    /// expect_file_dialog reads the breadcrumb back, so a directory that
    /// did not take effect fails the scene.
    private fun kayaFileDialogGoto(path: String) {
        kayaPendingPickerDirectory = kayaExpandPath(path)
    }

    /// Choose the named row, or dismiss. Returns null on success and the
    /// failure's sentence otherwise, because both halves of this are
    /// silent-by-design and only their absence is observable.
    ///
    /// RUNS OFF THE MAIN THREAD, which the service asserts: it reads
    /// getWindows(), refreshed on the main looper, so a drive that
    /// blocked main would watch a frozen list. The scene's verbs already
    /// run on the harness thread — this is the one place it matters.
    private fun kayaFileDialogDrive(name: String): String? {
        val svc = KayaHarnessAccessibility.live
            ?: return "no harness accessibility service — the runner did not enable it"
        if (name == "cancel") {
            return if (svc.dismiss()) null
            else "the picker would not dismiss; windows are ${svc.windowPackages()}"
        }
        if (!svc.choose(name)) {
            return "no row named \"$name\"; the picker is showing ${svc.pickerState()?.second}"
        }
        // THE CLICK IS THE ANSWER on this platform, so the picker being
        // gone is the proof it landed. A click that arrives before the
        // list is interactive is swallowed with no error anywhere.
        return if (svc.waitForPickerGone()) null
        else "the picker was still up after clicking \"$name\" — the click was swallowed"
    }

    /**
     * Present the platform's REAL picker and answer exactly once.
     *
     * ACTION_OPEN_DOCUMENT, which hands off to DocumentsUI — a separate
     * app, which is why the harness needs an accessibility service to
     * see it at all. The answer is `content://` URIs and NOT paths: the
     * document may not be a file on this device, so the core wraps each
     * URI in a source that opens it through the ContentResolver.
     *
     * `multiple` rides the request as a FLAG here, an EXTRA on the
     * intent; macOS spells the same choice as a property and GTK and
     * WinUI as a different method — one field on the wire, four
     * spellings under it. A single tap answers either way (measured):
     * with ALLOW_MULTIPLE set, one chosen file still comes back through
     * `data.data` with an empty clipData.
     */
    private fun kayaPresentFileDialog(
        dialog: Long,
        multiple: Boolean,
        extensions: List<String>,
    ) {
        val activity = mountedActivity ?: error("kaya: a picker with no mounted activity")
        check(kayaLivePickerDialog == null) {
            "kaya: a second file dialog while $kayaLivePickerDialog is still up"
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("*/*")
            // WRITE as well as read: the vocabulary lets a guest reopen
            // a picked handle for writing, and the grant is decided HERE
            // — asking later is not possible.
            .addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        if (multiple) {
            intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        // The wire carries EXTENSIONS and an intent wants MIME types.
        // A filter nothing maps to is dropped rather than guessed at:
        // it is advisory, and an invented type would hide the file.
        val mimes = extensions.mapNotNull {
            MimeTypeMap.getSingleton().getMimeTypeFromExtension(it.lowercase())
        }
        if (mimes.isNotEmpty()) {
            intent.putExtra(Intent.EXTRA_MIME_TYPES, mimes.toTypedArray())
        }
        kayaPendingPickerDirectory?.let {
            intent.putExtra(DocumentsContract.EXTRA_INITIAL_URI, initialUri(it))
        }

        // register() and launch() in the same breath, from a RESUMED
        // activity — measured to work, and the reason this needs no
        // lifecycle-scoped registration in the shell Activity. The key
        // carries the dialog id so a leaked registration cannot collide
        // with the next picker.
        kayaLivePickerDialog = dialog
        kayaLivePickerLauncher = activity.activityResultRegistry.register(
            "kaya-file-dialog-$dialog",
            ActivityResultContracts.StartActivityForResult(),
        ) { result ->
            kayaLivePickerDialog = null
            kayaLivePickerLauncher?.unregister()
            kayaLivePickerLauncher = null
            kayaAnswerFileDialog(activity, dialog, result.data)
        }
        kayaLivePickerLauncher?.launch(intent)
    }

    /// The picked documents, or the EMPTY list for cancel — faithfully,
    /// because no platform can confirm an empty selection and there is
    /// no sentinel to invent. A cancelled picker arrives here with a
    /// null Intent.
    private fun kayaAnswerFileDialog(
        activity: ComponentActivity,
        dialog: Long,
        data: Intent?,
    ) {
        val clip = data?.clipData
        val uris = when {
            data?.data != null -> listOf(data.data!!)
            clip != null -> (0 until clip.itemCount).map { clip.getItemAt(it).uri }
            else -> emptyList()
        }
        // The DISPLAY NAME, not the last URI segment: the segment is the
        // provider's document id, which is a path fragment on the
        // ExternalStorage provider and an opaque key on others.
        val names = uris.map { uri ->
            var name = ""
            try {
                activity.contentResolver.query(uri, null, null, null, null)?.use { c ->
                    val i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (c.moveToFirst() && i >= 0) name = c.getString(i) ?: ""
                }
            } catch (e: Exception) {
                Log.w("kaya", "kaya: reading the picked name failed: $e")
            }
            name
        }
        KayaPresent.emitFileDialogResult(
            dialog,
            uris.map { it.toString() }.toTypedArray(),
            names.toTypedArray(),
        )
    }

    /// The ExternalStorage provider's document uri for a directory under
    /// the primary volume, which is what EXTRA_INITIAL_URI wants — a
    /// filesystem path in that extra is ignored.
    ///
    /// AIMED SOMEWHERE THE PLATFORM HIDES, the extra is accepted and the
    /// picker SILENTLY opens on Recent instead (measured, with
    /// `Android/data/...`). Nothing reports it; expect_file_dialog
    /// reading the breadcrumb back is what catches it.
    private fun initialUri(dir: String): Uri {
        val root = Environment.getExternalStorageDirectory().path.trimEnd('/')
        val rel = dir.removePrefix("$root/")
        return DocumentsContract.buildDocumentUri(EXTERNAL_STORAGE_AUTHORITY, "primary:$rel")
    }

    /**
     * The provider that publishes the device's own storage — the one
     * EXTRA_INITIAL_URI's document ids are minted against. Not the
     * picker's package: DocumentsUI is the browser, this is the
     * provider it browses.
     */
    private const val EXTERNAL_STORAGE_AUTHORITY = "com.android.externalstorage.documents"

    /**
     * The Activity whose ContentResolver redeems a picked URI, for
     * [KayaPresent.openPickedUri] — which the CORE calls, from whatever
     * thread the guest opened on, so it cannot be handed one.
     */
    internal fun pickerContext(): ComponentActivity? = mountedActivity

    // -----------------------------------------------------------------
    // Clipboard (DESIGN.md, Clipboard; docs/clipboard-plan.md §7 for
    // what this platform was measured to charge).
    //
    // The COPY arm builds ONE ClipData BY HAND — every offered mime
    // listed in the description explicitly, because newHtmlText
    // advertises text/html ALONE and a consumer gating on text/plain
    // would see nothing. ClipData.Item carries text, an html string, a
    // Uri or an Intent and NO byte array at any API level, so the image
    // and every custom format ride `content://` URIs served by this
    // app's own provider; the payloads are spilled to disk at copy time
    // because a provider is created on demand and may be restarted into
    // a fresh process long after this one is gone, while the clip in
    // system_server holds nothing but the URI string.
    //
    // The READ arm consults the DESCRIPTION for the offer, materializes
    // exactly the one representation it chooses, and answers exactly
    // once; a null primary clip is simply the empty answer.
    //
    // MATERIALIZE INSIDE THE READ, ALWAYS. The read grant
    // ClipboardService issues to a pasting package is revoked the
    // moment the clip changes (measured cross-package, §7), so a
    // stashed URI answers SecurityException later. Nothing here holds
    // one past the call that opened it.
    // -----------------------------------------------------------------

    /**
     * SystemUI's overlay-suppression extra. Honoured when the device is
     * an emulator or the clip's source is the shell — it exists so the
     * emulator's own clipboard bridge does not flash the API 33+ copy
     * preview — so on a real device this is inert and production
     * behavior is exactly what it was. On the lane it is the difference
     * between a system window sitting over the surface the harness is
     * asserting against for several seconds and not (§7 finding 4;
     * every helper seed carries it too).
     */
    private const val CLIP_SUPPRESS_OVERLAY = "com.android.systemui.SUPPRESS_CLIPBOARD_OVERLAY"

    /// The lane's FOREIGN clipboard app: a separate package, uid and
    /// process using the ordinary ClipboardManager API. See
    /// tools/android/cliphelper.
    private const val HELPER_PACKAGE = "dev.kaya.cliphelper"
    private const val HELPER_SEED_ACTION = "dev.kaya.cliphelper.SEED"
    private const val HELPER_SEED_RECEIVER = "dev.kaya.cliphelper.SeedReceiver"
    private const val HELPER_READ_ACTION = "dev.kaya.cliphelper.READ"
    private const val HELPER_READ_RECEIVER = "dev.kaya.cliphelper.ReadReceiver"

    /// Every helper answer is prefixed, so a result that is merely the
    /// broadcast's initial data — which is what comes back when nothing
    /// received it at all — cannot be mistaken for content.
    private const val HELPER_RESULT_PREFIX = "KAYAHELPER "

    /// Five seconds, the same bound the mac and GTK arms give their
    /// foreign tools.
    private const val CLIP_TIMEOUT_MS = 5_000L

    /**
     * Put one clip on the system clipboard.
     *
     * ONE ClipData, its ClipDescription listing every offered mime in
     * the canonical order — custom ids, text/uri-list, image/png,
     * text/html, text/plain, which is descending clip value and so
     * descending richness. Built by hand for two reasons measured in
     * AOSP's own source: `newHtmlText` advertises text/html and never
     * text/plain, and `addItem(item)` does not touch the type list at
     * all (only the resolver overload does, and it would re-derive
     * types this arm already knows).
     *
     * ITEM 0 CARRIES TEXT AND HTML INLINE, and three separate things
     * want it that way round: most foreign readers look at item 0
     * alone, `coerceToText` answers the EMPTY STRING for a
     * content:// item (contradicting its own javadoc), and SystemUI
     * previews item 0.
     */
    private fun kayaCopyToClipboard(
        text: String?,
        html: String?,
        image: ByteArray?,
        files: List<String>,
        custom: List<Pair<String, ByteArray>>,
    ) {
        val activity = mountedActivity ?: error("kaya: a copy with no mounted activity")
        val mimes = ArrayList<String>()
        custom.forEach { mimes.add(it.first) }
        if (files.isNotEmpty()) mimes.add(ClipDescription.MIMETYPE_TEXT_URILIST)
        if (image != null) mimes.add("image/png")
        if (html != null) mimes.add(ClipDescription.MIMETYPE_TEXT_HTML)
        if (text != null) mimes.add(ClipDescription.MIMETYPE_TEXT_PLAIN)
        val description = ClipDescription("kaya", mimes.toTypedArray())
        description.extras = PersistableBundle().apply {
            putBoolean(CLIP_SUPPRESS_OVERLAY, true)
        }

        val items = ArrayList<ClipData.Item>()
        if (text != null || html != null) {
            // The plain text must be supplied whenever html is (the
            // Item constructor enforces it), so an html-only clip
            // carries an empty string beside it.
            items.add(ClipData.Item(text ?: "", html))
        }
        // The last clip's payloads go first: the platform never says a
        // clip was replaced, so a shorter clip would otherwise leave a
        // richer one's slots on disk under names it does not advertise.
        KayaClipProvider.clear(activity)
        custom.forEachIndexed { i, pair ->
            KayaClipProvider.customPayload(activity, i).writeBytes(pair.second)
            // The id is the GUEST's own string and nothing on this path
            // validates or normalizes a mime type, so it rides beside
            // the bytes verbatim for the provider's getType to answer.
            KayaClipProvider.customMimeSidecar(activity, i).writeText(pair.first)
            items.add(ClipData.Item(KayaClipProvider.customUri(activity, i)))
        }
        // A FILE LOCATOR IS ALREADY THE DOCUMENT'S OWN `content://` URI
        // on this platform (android.rs, UriSource::locator), so a file
        // item names THE DOCUMENT and never a copy of it through this
        // app's provider. Three things follow, and each is a reason:
        // the paster gets the document's real type and display name
        // rather than a flat one this app invented; a pasted file stays
        // the SAME capability the picker returns; and the copy arm
        // never reads a file's bytes on the main thread, which an
        // arbitrarily large document would stall. kaya may re-grant a
        // URI it holds, which is the ordinary "share what you picked"
        // path.
        files.forEach { items.add(ClipData.Item(Uri.parse(it))) }
        if (image != null) {
            KayaClipProvider.imagePayload(activity).writeBytes(image)
            items.add(ClipData.Item(KayaClipProvider.imageUri(activity)))
        }
        check(items.isNotEmpty()) {
            "kaya: a copy record carrying no representation reached the interpreter"
        }
        val clip = ClipData(description, items[0])
        // The no-resolver overload deliberately: the description above
        // IS the offer, and the resolver overload would append types
        // derived from a provider round-trip per item.
        for (i in 1 until items.size) clip.addItem(items[i])
        activity.getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
        kayaClipboardChanged()
    }

    /// Answer a privileged read EXACTLY ONCE. `clip == 0` is the
    /// universal no — denied, absent, unfocused and nothing-accepted
    /// alike, which no platform tells apart and this one does not
    /// pretend to.
    private fun kayaAnswerClipboardRead(request: Long, accepting: String) {
        val value = kayaMaterializeClipboard(accepting)
        if (value == null) {
            KayaPresent.emitClipboardResult(
                request, 0, "", ByteArray(0), emptyArray(), emptyArray())
        } else {
            KayaPresent.emitClipboardResult(
                request, value.clip, value.text, value.bytes, value.locators, value.names)
        }
    }

    /**
     * Choose the RICHEST representation the clipboard offers that the
     * accept list takes, materialize exactly that one, and answer —
     * null for no intersection, the universal no. Shared by the
     * privileged read and by the declared-paste delivery, because the
     * two differ in their trigger and never in what they can
     * materialize.
     *
     * Descending clip value — custom (in accept-list order), files,
     * image, html, text.
     *
     * MAIN THREAD, like every other apply arm; the menu route reaches
     * it from composition or from an onUi hop.
     */
    private fun kayaMaterializeClipboard(accepting: String): KayaClipValue? {
        val activity = mountedActivity ?: return null
        val cm = activity.getSystemService(ClipboardManager::class.java) ?: return null
        val resolver = activity.contentResolver
        val (kinds, custom) = kayaParseAcceptList(accepting)
        val clip = cm.primaryClip ?: return null
        val description = clip.description
        val items = (0 until clip.itemCount).map { clip.getItemAt(it) }

        // The description's mime list is a SNAPSHOT taken at copy time;
        // ContentResolver.getType is the live answer, and it is the one
        // SystemUI's own overlay uses. Both are consulted: the
        // description says what is OFFERED, the resolver says which
        // item carries it.
        for (id in custom) {
            if (!description.hasMimeType(id)) continue
            for (item in items) {
                val uri = item.uri ?: continue
                if (resolver.getType(uri) != id) continue
                val bytes = kayaUriBytes(resolver, uri) ?: continue
                return KayaClipValue(CLIP_CUSTOM, text = id, bytes = bytes)
            }
        }
        if (kinds and CLIP_FILES != 0) {
            // A URI item IS a file here: the picker's capability
            // arriving through a second door, and the core wraps each
            // locator in the source that opens it — so the guest
            // redeems a pasted document exactly as it redeems a picked
            // one.
            val locators = ArrayList<String>()
            val names = ArrayList<String>()
            for (item in items) {
                val uri = item.uri ?: continue
                if (uri.scheme != ContentResolver.SCHEME_CONTENT) continue
                // AN IMAGE RIDES A content:// DOCUMENT ON THIS PLATFORM
                // TOO. Without this line an image clip would answer a
                // files-only read, which no sibling arm does — macOS
                // reads NSURL objects, GTK requires text/uri-list — and
                // a divergence in what a read ANSWERS is the kind the
                // scene cannot see, because both sides would be kaya.
                if (resolver.getType(uri)?.startsWith("image/") == true) continue
                locators.add(uri.toString())
                names.add(kayaDocumentName(resolver, uri))
            }
            if (locators.isNotEmpty()) {
                return KayaClipValue(
                    CLIP_FILES,
                    locators = locators.toTypedArray(),
                    names = names.toTypedArray())
            }
        }
        if (kinds and CLIP_IMAGE != 0) {
            for (item in items) {
                val uri = item.uri ?: continue
                if (resolver.getType(uri) != "image/png") continue
                val bytes = kayaUriBytes(resolver, uri) ?: continue
                return KayaClipValue(CLIP_IMAGE, bytes = bytes)
            }
        }
        if (kinds and CLIP_HTML != 0 &&
            description.hasMimeType(ClipDescription.MIMETYPE_TEXT_HTML)
        ) {
            // Verbatim: htmlText is a plain String field the platform
            // neither sanitizes nor re-serializes.
            val html = items.firstNotNullOfOrNull { it.htmlText }
            if (html != null) return KayaClipValue(CLIP_HTML, text = html)
        }
        if (kinds and CLIP_TEXT != 0 &&
            description.hasMimeType(ClipDescription.MIMETYPE_TEXT_PLAIN)
        ) {
            // coerceToText is what a platform text view's own paste
            // reads, so this is the same string a foreign editor would
            // receive.
            val plain = items.firstOrNull()?.coerceToText(activity)?.toString()
            if (!plain.isNullOrEmpty()) return KayaClipValue(CLIP_TEXT, text = plain)
        }
        return null
    }

    /// The clipboard's current OFFER — the description, never the data.
    /// Deliberately: only `getPrimaryClip` raises the platform's access
    /// notification and notes the app op, while the description and
    /// hasPrimaryClip merely check it, so deciding enablement costs
    /// nothing and says nothing about the app. It is focus-gated the
    /// same way, and null while unfocused is the honest "cannot say".
    private fun kayaClipboardOffer(): ClipDescription? {
        // A SUBSCRIBING READ, and looking pointless is exactly what it
        // is for: the clipboard is not snapshot state, so without this
        // a Paste row rendered before the clip arrived would stay grey
        // until something unrelated recomposed. See
        // KayaSceneModel.clipboardGeneration.
        @Suppress("UNUSED_EXPRESSION")
        KayaSceneModel.clipboardGeneration
        val activity = mountedActivity ?: return null
        return activity.getSystemService(ClipboardManager::class.java)?.primaryClipDescription
    }

    /// What the clipboard offers may have moved. Every site that can
    /// move it comes through here — a copy going out, a foreign seed
    /// landing — and the rows that read enablement recompose. Focus
    /// changes need no bump: focusedId and the accepts prop are both
    /// observable already, so a focus move recomposes them anyway.
    private fun kayaClipboardChanged() {
        KayaSceneModel.clipboardGeneration += 1
    }

    /// A document's display name — OpenableColumns is the picker
    /// capability's Android spelling, and a pasted document answers it
    /// exactly as a picked one does. Never the last path segment when
    /// the provider will say: that segment is the document id, which is
    /// a path fragment on ExternalStorage and an opaque key elsewhere.
    private fun kayaDocumentName(resolver: ContentResolver, uri: Uri): String {
        try {
            resolver.query(uri, null, null, null, null)?.use { c ->
                val i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (c.moveToFirst() && i >= 0) {
                    val name = c.getString(i)
                    if (!name.isNullOrEmpty()) return name
                }
            }
        } catch (e: Exception) {
            Log.w("kaya", "kaya: naming the pasted $uri failed: $e")
        }
        return uri.lastPathSegment ?: ""
    }

    /// One `content://` item's bytes, whole, inside the read that owns
    /// the grant. Null for a transfer the platform refused — the
    /// universal no, one representation at a time.
    private fun kayaUriBytes(resolver: ContentResolver, uri: Uri): ByteArray? =
        try {
            resolver.openInputStream(uri)?.use { it.readBytes() }
        } catch (e: Exception) {
            Log.w("kaya", "kaya: reading the pasted $uri failed: $e")
            null
        }

    /**
     * Whether a clipboard role's command can act right now; a non-role
     * item answers true and pays nothing.
     *
     * THE SAME RULE AS THE MAC AND GTK ARMS, spelled Compose: paste is
     * the INTERSECTION of what the clipboard offers and what the
     * focused widget accepts — and a widget that declared NOTHING still
     * pastes, because the platform inserts and the change handler
     * reports it, so an undeclared target enables on the text offer
     * alone. Cut and copy need a focused editable to take a selection
     * from; the field's own action refuses the rest.
     *
     * NOT A BUILD-TIME FACT: both halves move long after the bar was
     * built. Every affordance on this host reads
     * kayaMenuEffectivelyEnabled, which ends here, so rendered rows,
     * shortcuts, expect_menu and the activation gate all see one
     * answer.
     */
    internal fun kayaRoleEnabled(role: String): Boolean {
        when (role) {
            "cut", "copy" -> {
                val id = KayaSceneModel.focusedId ?: return false
                return KayaSceneModel.entryWidgets.any { it.id == id } ||
                    KayaSceneModel.textareas.any { it.id == id }
            }
            "paste" -> {
                val id = KayaSceneModel.focusedId ?: return false
                val node = KayaSceneModel.nodes[id] ?: return false
                val offer = kayaClipboardOffer() ?: return false
                if (node.accepts.isEmpty()) {
                    return offer.hasMimeType(ClipDescription.MIMETYPE_TEXT_PLAIN)
                }
                val (kinds, custom) = kayaParseAcceptList(node.accepts)
                if (custom.any { offer.hasMimeType(it) }) return true
                return (kinds and CLIP_FILES != 0 &&
                    offer.hasMimeType(ClipDescription.MIMETYPE_TEXT_URILIST)) ||
                    (kinds and CLIP_IMAGE != 0 && offer.hasMimeType("image/png")) ||
                    (kinds and CLIP_HTML != 0 &&
                        offer.hasMimeType(ClipDescription.MIMETYPE_TEXT_HTML)) ||
                    (kinds and CLIP_TEXT != 0 &&
                        offer.hasMimeType(ClipDescription.MIMETYPE_TEXT_PLAIN))
            }
            // ASKED ONCE AND USED TWICE. `nothing` IS what a disabled
            // Edit>Undo means (D6: "enablement is that same question,
            // computed live at activation"), so the routing function
            // answers both the enablement question and the activation
            // question and the two cannot drift — which is A4's whole
            // point, and why there is no second predicate here.
            "undo" -> return kayaUndoRoute() != KayaUndoRoute.NOTHING
            "redo" -> return kayaRedoRoute() != KayaUndoRoute.NOTHING
            else -> return true
        }
    }

    /**
     * Perform a clipboard role on the focused widget. Answers whether
     * it WAS one, so a plain action falls through to its own dispatch.
     *
     * THE PASTE SPLIT, and it is the rule the whole gesture layer turns
     * on (DESIGN.md): a widget that DECLARED what it accepts takes the
     * content itself — kaya reads the clipboard and delivers it to the
     * paste hook — while one that declared nothing gets the platform's
     * own insertion and its ordinary change handler reports the result.
     * A plain text editor writes none of this and works.
     */
    internal fun kayaPerformClipboardRole(role: String): Boolean {
        when (role) {
            "cut", "copy" -> {
                kayaEditFocusedText(role)
                return true
            }
            "paste" -> {
                val id = KayaSceneModel.focusedId ?: return true
                val node = KayaSceneModel.nodes[id] ?: return true
                if (node.accepts.isEmpty()) {
                    // THE PLATFORM'S OWN INSERTION, spelled the way
                    // COMMAND_CLEAR is: this host has no responder
                    // chain and the MODEL owns the field's text, so
                    // the insertion is a write into the model plus the
                    // same emission the TextField's own change would
                    // make. Appended, because kaya has no selection API
                    // and this lowering hands Compose a String rather
                    // than a TextFieldValue — the end of the field is
                    // the only caret position the model knows, and it
                    // is where Compose leaves the caret after a
                    // programmatic write.
                    //
                    // AND IT COSTS THE FIELD'S TYPING HISTORY, which is
                    // a judgement this arm has to make out loud rather
                    // than inherit (docs/undo-plan.md §1.4 names this
                    // exact site). On every other platform kaya's paste
                    // is a USER act and lands IN the native stack; on
                    // TextFieldState there is measurably no public way to
                    // make an app write undoable, so the insertion clears
                    // the stack like any other write. What that costs is
                    // GRANULARITY, not history: the episode was banked
                    // off the observation stream before the clear, so the
                    // ledger still walks the typing back — in one coarse
                    // step instead of the platform's. That is A1's trade
                    // arriving one site early, not a hole.
                    val pasted = kayaClipboardPlainText() ?: return true
                    kayaWriteText(node, kayaLf(node.text + pasted))
                    KayaPresent.emitTextChanged(
                        node.tag, node.text, KayaSceneModel.focusedId == node.id, false)
                    return true
                }
                // The same walk the privileged read makes, and
                // deliberately the same code. A paste that delivered
                // nothing is NOT an occurrence — the read owns the
                // empty answer — which is also what kaya_emit_pasted
                // asserts on the other side.
                val value = kayaMaterializeClipboard(node.accepts) ?: return true
                KayaPresent.emitPasted(
                    node.tag, value.clip, value.text, value.bytes, value.locators, value.names)
                return true
            }
            else -> return false
        }
    }

    /**
     * Perform an undo/redo role on the focused surface. Answers whether
     * it WAS one, so a plain action falls through to its own dispatch —
     * [kayaPerformClipboardRole]'s contract, for the same reason: a role
     * item is the PLATFORM's command, not the app's action.
     *
     * A SEPARATE FUNCTION because an undo is not a clipboard command;
     * tools/check-roles.sh anticipates the split (its perform anchor is
     * the UNION of the `kayaPerform*Role` functions).
     *
     * ROUTING IS KAYA'S HERE, all of it (docs/undo-plan.md §1's table:
     * "GTK and Compose route in kaya"), and Android leaves it no choice:
     * measured, a focused text field CONSUMES Ctrl+Z whether or not it
     * has anything to undo, and the Activity's shortcut route never sees
     * it — so the platform gives D6's first half for free and its second
     * half never. On a phone there is no hardware keyboard and the text
     * toolbar carries no Undo at all, which makes THIS menu item the only
     * undo affordance that exists on the platform.
     */
    internal fun kayaPerformUndoRole(role: String): Boolean {
        when (role) {
            "undo" -> {
                when (kayaUndoRoute()) {
                    KayaUndoRoute.NATIVE -> kayaNativeUndo(redo = false)
                    KayaUndoRoute.CORE -> kayaCoreUndo()
                    KayaUndoRoute.NOTHING -> {}
                }
                return true
            }
            "redo" -> {
                when (kayaRedoRoute()) {
                    KayaUndoRoute.NATIVE -> kayaNativeUndo(redo = true)
                    KayaUndoRoute.CORE -> kayaCoreRedo()
                    KayaUndoRoute.NOTHING -> {}
                }
                return true
            }
            else -> return false
        }
    }

    /// The plain text a platform text view's own paste would insert.
    private fun kayaClipboardPlainText(): String? {
        val activity = mountedActivity ?: return null
        val cm = activity.getSystemService(ClipboardManager::class.java) ?: return null
        val clip = cm.primaryClip ?: return null
        if (clip.itemCount == 0) return null
        return clip.getItemAt(0).coerceToText(activity).toString().ifEmpty { null }
    }

    /**
     * Cut and Copy, acting on the FOCUSED FIELD'S SELECTION through the
     * one selection-level hook this interpreter's fields have.
     *
     * kaya holds no caret and no selection: the model carries a bare
     * `String`, so nothing on this side names a range to cut — which is
     * exactly why these had to be platform COMMANDS rather than
     * something an app assembles out of the data layer. (The field's
     * `TextFieldState` DOES carry a selection since the undo migration,
     * and reaching for it would be the wrong fix: `edit {}` commits, and
     * a commit CLEARS the field's undo history — D7's clear firing for a
     * read.) What Compose does publish is
     * SemanticsActions.CutText / CopyText on the field's own node,
     * present only while a selection exists, and invoking one runs
     * BasicTextField's own cut/copy — the same action the platform's
     * text toolbar and TalkBack invoke. That is this host's responder
     * chain: the platform's command reaching the platform's selection,
     * with nothing of kaya's invented in between.
     *
     * A field with no selection publishes neither action and the role
     * then does nothing, exactly as a responder chain that refuses
     * does. MAIN THREAD ONLY — Compose owns its semantics tree from the
     * thread that lays out, and reading it from the harness thread is a
     * hard crash rather than a wrong answer (see kayaAx).
     */
    private fun kayaEditFocusedText(role: String) {
        val activity = mountedActivity ?: return
        val view = kayaComposeRoot(activity.window.decorView) ?: return
        val owner = (view as RootForTest).semanticsOwner
        val node = kayaFocusedSemanticsNode(owner.rootSemanticsNode) ?: return
        val action =
            if (role == "cut") node.config.getOrNull(SemanticsActions.CutText)
            else node.config.getOrNull(SemanticsActions.CopyText)
        action?.action?.invoke()
    }

    /// The merged semantics node that holds focus — the platform's own
    /// answer, not the model's mirror, because the command has to act
    /// on whatever the platform will actually cut from.
    private fun kayaFocusedSemanticsNode(node: SemanticsNode, depth: Int = 0): SemanticsNode? {
        if (depth > 64) return null
        if (node.config.getOrNull(SemanticsProperties.Focused) == true) return node
        for (child in node.children) {
            kayaFocusedSemanticsNode(child, depth + 1)?.let { return it }
        }
        return null
    }

    /**
     * Put content on the clipboard FROM OUTSIDE THIS APP, through the
     * helper APK — a separate package, uid and process using the
     * ordinary ClipboardManager API (tools/android/cliphelper).
     *
     * FOREIGN ON PURPOSE, and it is the whole value of this verb: the
     * lowerings are the hard part, and a check where kaya reads what
     * kaya wrote parses its own malformed lowering perfectly happily.
     * Android has no `cmd clipboard` and no host-side path that carries
     * more than text (§7), so the outside process has to be a real app.
     *
     * The seed never moves focus: background WRITES are unrestricted
     * (`case OP_WRITE_CLIPBOARD: allowed = true`, unchanged across API
     * 10..15 and confirmed on this pool), so a plain BroadcastReceiver
     * is enough.
     *
     * AND IT WAITS UNTIL THE CONTENT IS REALLY THERE, twice: the
     * ordered broadcast's result says the helper ran and what it did,
     * and then this polls THIS process's own view of the offer until
     * the seeded type shows up. A verb that returns before its own work
     * is visible makes every step after it race — measured first on
     * macOS, where osascript's exit did not mean the pasteboard had
     * settled and one run in three read empty.
     */
    private fun kayaClipboardSeed(kind: String, argument: String) {
        val arg = kayaExpandPath(argument)
        val extras = android.os.Bundle()
        val expected: String
        val payload: ByteArray
        when (kind) {
            "text" -> {
                payload = arg.toByteArray()
                expected = ClipDescription.MIMETYPE_TEXT_PLAIN
            }
            "html" -> {
                payload = arg.toByteArray()
                expected = ClipDescription.MIMETYPE_TEXT_HTML
            }
            "image" -> {
                payload = kayaSeedFile(kind, arg)
                expected = "image/png"
            }
            "files" -> {
                payload = kayaSeedFile(kind, arg)
                // The helper serves the seeded bytes from its own
                // provider under this display name, which is what the
                // guest reads back through OpenableColumns.
                extras.putString("name", java.io.File(arg).name)
                expected = ClipDescription.MIMETYPE_TEXT_URILIST
            }
            else -> error(
                "kaya: clipboard_seed cannot write \"$kind\" from outside the app — " +
                    "no stock tool writes an app-defined format, and a helper kaya " +
                    "wrote would be foreign in name only")
        }
        extras.putString("kind", kind)
        // Base64 so binary is first-class: the same string crosses a
        // shell (`am broadcast --es`) and a binder extra unchanged, and
        // no quoting layer can corrupt a byte.
        extras.putString("b64", Base64.encodeToString(payload, Base64.NO_WRAP))
        // THE OFFERED TYPE ALONE IS NOT A VERIFICATION, and this is
        // where that could have gone quietly wrong: the clip the seed
        // REPLACES may advertise the same type — kaya's own copy offers
        // text/plain and the scene's next step seeds text — so a poll on
        // the mime would be satisfied by the very clip the seed was
        // meant to displace. That is a check that cannot fail. The
        // service stamps every installed clip, so the question asked
        // below is the discriminating one: a DIFFERENT clip, offering
        // what was asked for.
        val before = kayaClipboardOffer()?.timestamp ?: 0L
        val answer = kayaHelperCall(HELPER_SEED_ACTION, HELPER_SEED_RECEIVER, extras)
        check(answer != null && answer.startsWith(HELPER_RESULT_PREFIX)) {
            "kaya: clipboard_seed $kind: the helper answered ${answer ?: "nothing"} — " +
                "$HELPER_PACKAGE is the lane's foreign clipboard app and must be installed"
        }
        val deadline = System.nanoTime() + CLIP_TIMEOUT_MS * 1_000_000L
        while (System.nanoTime() < deadline) {
            val offer = kayaClipboardOffer()
            if (offer != null && offer.timestamp != before && offer.hasMimeType(expected)) {
                kayaClipboardChanged()
                return
            }
            Thread.sleep(10)
        }
        error("kaya: clipboard_seed $kind never appeared on the clipboard")
    }

    private fun kayaSeedFile(kind: String, path: String): ByteArray {
        val file = java.io.File(path)
        check(file.isFile) {
            "kaya: clipboard_seed $kind cannot read \"$path\" — the guest writes the " +
                "scene's files before it shows anything, so a missing one means the " +
                "path never expanded or the two sides disagree on the scene root"
        }
        return file.readBytes()
    }

    /**
     * Read the clipboard back FROM OUTSIDE this app, in one
     * representation. Empty when it holds nothing of that kind.
     *
     * THE HELPER READS WITHOUT TOUCHING THE GUEST'S FOCUS, which is
     * what lets this verb sit between two clicks: it owns the selected
     * input method for the length of the lane run, and ClipboardService
     * admits the default IME's reads before it ever checks focus (§7
     * finding 1, and the same branch exempts it from the access
     * notification). The guest stays frontmost throughout.
     */
    private fun kayaClipboardRead(kind: String): String {
        val extras = android.os.Bundle()
        // The closed kinds by name; ANYTHING ELSE IS A CUSTOM FORMAT
        // ID, which rides as the mime the helper asks the resolver for.
        if (kind == "text" || kind == "html" || kind == "image" || kind == "files") {
            extras.putString("kind", kind)
        } else {
            extras.putString("kind", "custom")
            extras.putString("mime", kind)
        }
        val answer = kayaHelperCall(HELPER_READ_ACTION, HELPER_READ_RECEIVER, extras)
        // A SENTINEL VALUE, never a silent empty string: "" is a real
        // answer here (an unsatisfiable read), so a helper that never
        // ran must not be able to look like one. The comparison fails
        // with this text in hand and names its own cause.
        if (answer == null || !answer.startsWith(HELPER_RESULT_PREFIX)) {
            return "<$HELPER_PACKAGE never answered>"
        }
        return answer.removePrefix(HELPER_RESULT_PREFIX)
    }

    /**
     * One ordered broadcast to the helper, and its answer.
     *
     * An ordered broadcast's result data is a synchronous, host-free
     * channel — `am broadcast` prints it on stdout and a result
     * receiver gets it app-to-app — which is what lets these two verbs
     * stay symmetric with every other lane's: no adb round trip, no
     * runner involvement, no logcat scraping with its stale-line
     * hazard.
     *
     * AN EXPLICIT COMPONENT, always. An implicit broadcast has not
     * reached a manifest receiver since API 26, and the
     * stopped-package exclusion AMS adds unconditionally applies to
     * implicit broadcasts only — so naming the class reaches a helper
     * that has never been launched (measured, §7), and no warm-up
     * launch is needed.
     *
     * RUNS OFF THE MAIN THREAD, deliberately: this blocks on another
     * process while the result receiver is dispatched on main, so
     * waiting inside an onUi hop would deadlock on the very thread the
     * answer needs. The harness thread is where every verb already
     * runs, and kayaFileDialogDrive documents the same rule.
     */
    private fun kayaHelperCall(
        action: String,
        receiver: String,
        extras: android.os.Bundle,
    ): String? {
        val activity = mountedActivity ?: error("kaya: a clipboard verb with no mounted activity")
        val intent = Intent(action)
            .setClassName(HELPER_PACKAGE, receiver)
            .addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES)
            .putExtras(extras)
        val done = java.util.concurrent.CountDownLatch(1)
        var answer: String? = null
        activity.sendOrderedBroadcast(
            intent,
            null,
            object : android.content.BroadcastReceiver() {
                override fun onReceive(context: android.content.Context, received: Intent?) {
                    answer = resultData
                    done.countDown()
                }
            },
            null,
            0,
            null,
            null,
        )
        if (!done.await(CLIP_TIMEOUT_MS, java.util.concurrent.TimeUnit.MILLISECONDS)) {
            return null
        }
        return answer
    }

    private fun kayaWidgetTarget(spec: String): KayaNode? {
        val kind = spec.substringBefore('#')
        val registry = when (kind) {
            "button" -> KayaSceneModel.buttons
            "checkbox" -> KayaSceneModel.checkboxes
            "slider" -> KayaSceneModel.sliders
            "entry" -> KayaSceneModel.entryWidgets
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

    /**
     * Normalize what Compose classified this node as into the harness's
     * closed role set. The point of the verb is that the PLATFORM
     * classified the control, so anything kaya has no name for reports
     * `unknown` rather than being guessed at — an honest "the platform
     * said something else" is a finding, and a guess would hide one.
     *
     * TWO SOURCES, in the order Compose itself trusts them:
     *
     *  * `Role` is Compose's own classification of its own widgets, and
     *    it is what the accessibility delegate turns into a class name
     *    for a service. Reading it is asking Compose, not asking kaya:
     *    nothing in kaya's model has a notion of Role, and Compose says
     *    `Role.Button` because the thing really is a button.
     *  * `className` for the controls Compose classifies WITHOUT a Role.
     *    A slider and a progress bar are the same semantics
     *    (ProgressBarRangeInfo) told apart by whether the range can be
     *    set, and Compose already draws that distinction when it fills
     *    in SeekBar vs ProgressBar. Text fields and text are the same
     *    shape of case. Deriving those here from the raw semantics
     *    would be kaya reclassifying; taking the class name is still
     *    Compose's answer.
     *
     * Android has no group class: a node with no Role and no class of
     * its own comes out as the generic `android.view.View`. A generic
     * node WITH children is what a group is here; a generic LEAF is a
     * control we failed to classify, and stays `unknown`.
     */
    private fun kayaAxRole(role: Role?, className: CharSequence?, childCount: Int): String {
        val byRole =
            when (role) {
                Role.Button -> "button"
                Role.Checkbox -> "checkbox"
                Role.Image -> "image"
                // The chooser, which every platform spells its own way
                // (AXPopUpButton on macOS, ComboBox on AT-SPI and UIA).
                Role.DropdownList -> "combobox"
                // Role.Switch, Role.RadioButton and Role.Tab are
                // deliberately NOT mapped: the closed set has no name
                // for them, and inventing one would report a role no
                // scene can spell. They fall through to the class name.
                else -> null
            }
        if (byRole != null) return byRole
        val byClass =
            when (className?.toString()) {
                "android.widget.Button" -> "button"
                "android.widget.TextView" -> "label"
                "android.widget.EditText" -> "field"
                "android.widget.CheckBox" -> "checkbox"
                "android.widget.SeekBar" -> "slider"
                "android.widget.ImageView" -> "image"
                "android.widget.ProgressBar" -> "progress"
                "android.widget.Spinner" -> "combobox"
                else -> null
            }
        if (byClass != null) return byClass
        return if (childCount > 0) "group" else "unknown"
    }

    /**
     * The name a service would speak for this node: the authored
     * description first, then whatever the control derived from its own
     * content — the same precedence every other backend reads (a
     * derived name is the free-by-construction half of the wrap-native
     * bet, an authored one overrides it).
     *
     * The first two properties are LISTS after merging, because merging
     * is what gathers a control's own text plus its descendants'.
     * Joined with a space: a service reads them as one utterance.
     *
     * THE THIRD SOURCE IS THE FIELD'S OWN VALUE, and every other
     * backend already chains to it under a different name: macOS falls
     * through to kAXValueAttribute, GTK to the AT-SPI Text interface,
     * WinUI to ValuePattern. A Compose TextField's edited content lives
     * in EditableText and NOT in Text — `Text` carries the
     * label/placeholder, which this lowering passes neither — so a
     * field named by nothing but what the user typed read back as
     * `field/` until this arm existed. The accessibility scene never
     * caught it because both of its field reads name the widget through
     * a11y_label; the clipboard scene's does not.
     */
    private fun kayaAxName(node: SemanticsNode): String {
        val described = node.config.getOrNull(SemanticsProperties.ContentDescription)
        if (!described.isNullOrEmpty()) return described.joinToString(" ")
        val text = node.config.getOrNull(SemanticsProperties.Text)
        if (!text.isNullOrEmpty()) return text.joinToString(" ") { it.text }
        return node.config.getOrNull(SemanticsProperties.EditableText)?.text ?: ""
    }

    private fun kayaComposeRoot(v: android.view.View): android.view.View? {
        if (v is RootForTest) return v
        if (v is android.view.ViewGroup) {
            for (i in 0 until v.childCount) {
                kayaComposeRoot(v.getChildAt(i))?.let { return it }
            }
        }
        return null
    }

    /**
     * Read the MERGED semantics tree — the post-merge truth an
     * assistive client consumes.
     *
     * Compose does not hand a service a finished tree. It sends the
     * UNMERGED nodes plus `mergeDescendants` instructions and the
     * SERVICE does the merging, so `createAccessibilityNodeInfo(id)` —
     * the obvious "what does the platform publish" call — returns a
     * pre-merge node that no client ever sees as such. Reading that is
     * how a Button came back as a nameless generic view with children:
     * its `Role` sat on a node the service would have folded into its
     * parent. `SemanticsOwner.rootSemanticsNode` is merging-enabled, so
     * walking it IS the merged view, one node per thing a client
     * focuses.
     *
     * This is the same trap the macOS backend documents from the other
     * side: reading the server side instead of what the client sees.
     *
     * Identity is the merged `TestTag`, which is where `a11y_id` lands
     * and what Compose's own test framework matches on. The node info
     * is consulted for ONE thing — the class name of the controls
     * Compose classifies without a Role (see [kayaAxRole]).
     */
    private fun kayaAxFind(node: SemanticsNode, tag: String, depth: Int = 0): SemanticsNode? {
        if (depth > 64) return null
        if (node.config.getOrNull(SemanticsProperties.TestTag) == tag) return node
        for (child in node.children) {
            kayaAxFind(child, tag, depth + 1)?.let { return it }
        }
        return null
    }

    /**
     * What the walk actually saw, for the miss path. A silent "not
     * found" is the shape that costs a whole emulator round-trip to
     * diagnose; naming every merged node's id, tag, role, class name
     * and name turns one run into the answer.
     */
    private fun kayaAxDump(activity: ComponentActivity): String {
        val view = kayaComposeRoot(activity.window.decorView)
            ?: return "no Compose root under decorView"
        val provider = view.accessibilityNodeProvider
        val owner = (view as RootForTest).semanticsOwner
        val out = StringBuilder()
        var seen = 0
        fun walk(node: SemanticsNode, depth: Int) {
            if (depth > 64) return
            seen++
            out.append(" [").append(node.id)
                .append(" tag=").append(node.config.getOrNull(SemanticsProperties.TestTag))
                .append(" role=").append(node.config.getOrNull(SemanticsProperties.Role))
                .append(" class=")
                .append(provider?.createAccessibilityNodeInfo(node.id)?.className ?: "no-info")
                .append(" name=").append(kayaAxName(node))
                .append(" kids=").append(node.children.size)
                .append(']')
            node.children.forEach { walk(it, depth + 1) }
        }
        walk(owner.rootSemanticsNode, 0)
        return "walked " + seen + " merged nodes:" + out
    }

    /**
     * MAIN THREAD ONLY (callers go through [onUi]). Compose owns its
     * semantics tree from the thread that measures and lays out, and
     * reading it from the selftest thread trips
     * SnapshotStateObserver's multithreaded-access check — measured, as
     * a hard crash rather than a wrong answer.
     */
    private fun kayaAx(activity: ComponentActivity, tag: String): String? {
        val view = kayaComposeRoot(activity.window.decorView) ?: return null
        val owner = (view as RootForTest).semanticsOwner
        val node = kayaAxFind(owner.rootSemanticsNode, tag) ?: return null
        val className = view.accessibilityNodeProvider?.createAccessibilityNodeInfo(node.id)
            ?.className
        val role = node.config.getOrNull(SemanticsProperties.Role)
        return kayaAxRole(role, className, node.children.size) + "/" + kayaAxName(node)
    }

    /**
     * MAIN THREAD ONLY (callers go through [onUi]). The HINT as a
     * service would hear it: the click action's label, which is where
     * the lowering puts it and what TalkBack speaks after "double tap
     * to".
     */
    private fun kayaAxHint(activity: ComponentActivity, tag: String): String? {
        val view = kayaComposeRoot(activity.window.decorView) ?: return null
        val owner = (view as RootForTest).semanticsOwner
        val node = kayaAxFind(owner.rootSemanticsNode, tag) ?: return null
        return node.config.getOrNull(SemanticsActions.OnClick)?.label ?: ""
    }

    /**
     * The two inputs [kayaAxRole] weighs, for a MISMATCH. `unknown/…`
     * says the platform classified the control as something the closed
     * set has no name for, and the next question is always which
     * something — one emulator round-trip per answer without this, and
     * the whole point of reading the real tree is that its answers are
     * not guessable from here.
     */
    private fun kayaAxWhy(activity: ComponentActivity, tag: String): String {
        val view = kayaComposeRoot(activity.window.decorView) ?: return ""
        val owner = (view as RootForTest).semanticsOwner
        val node = kayaAxFind(owner.rootSemanticsNode, tag) ?: return ""
        val className = view.accessibilityNodeProvider?.createAccessibilityNodeInfo(node.id)
            ?.className
        return " (role=" + node.config.getOrNull(SemanticsProperties.Role) +
            " class=" + className + " kids=" + node.children.size + ")"
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
                    // The core's watchdog reading. Polled like every
                    // other expectation — the watchdog needs its
                    // threshold to elapse before it says anything, and
                    // the retry above re-evaluates until the deadline.
                    // Reported in the verdict rather than merely
                    // passed, so a green leg still shows how long the
                    // app was gone.
                    "expect_stall" -> {
                        val stalledMs = KayaPresent.stalledMs()
                        if (stalledMs > 0) {
                            observed.add("stalled ${stalledMs}ms")
                        } else {
                            failures.add(
                                "the app thread is keeping up — no pending occurrences have " +
                                    "gone unclaimed, so the stall watchdog has nothing to report"
                            )
                        }
                    }
                    // THE OTHER HALF OF THE SAME CLAIM, and the half
                    // nothing asserted for four milestones: a watchdog
                    // that reports a stall about a HEALTHY app is worse
                    // than none, because the line is read as evidence. It
                    // shipped that way — the five languages that read the
                    // occurrence ring directly reported a stall on every
                    // green leg — and this arm is what refuses it.
                    "expect_no_stall" -> {
                        val idleMs = KayaPresent.stalledMs()
                        if (idleMs == 0L) {
                            observed.add("the app thread is keeping up")
                        } else {
                            failures.add(
                                "the stall watchdog reports ${idleMs}ms of unclaimed " +
                                    "occurrences about an app that is answering this scene — " +
                                    "either the app thread really is gone, or the watchdog " +
                                    "cannot see this guest's transport " +
                                    "(crates/kaya/src/stall.rs)"
                            )
                        }
                    }
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
                    // THE REAL-KEYSTROKE TYPING VERB (docs/undo-plan.md
                    // A8), whose whole reason for existing is that a
                    // stand-in would LIE: writing the text would look
                    // like typing and would CLEAR the native history the
                    // scene came to observe, so a leg built out of
                    // set_text would destroy what it came to see and pass
                    // anyway.
                    "type" ->
                        kayaTypeAtFocus(activity, quoted(parts.drop(1)))?.let {
                            failures.add(it)
                        }
                    "set_text" -> {
                        val ok = onUi(activity) {
                            val node =
                                if (parts[1].startsWith("textarea"))
                                    target(parts[1], "textarea", KayaSceneModel.textareas)
                                else target(parts[1], "entry", KayaSceneModel.entryWidgets)
                            node?.also {
                                // Through kayaWriteText like every other
                                // programmatic write: set_text IS one, and
                                // it carries D7 with it — which is exactly
                                // why the scene above cannot be written
                                // with it.
                                kayaWriteText(it, kayaLf(quoted(parts.drop(2))))
                                KayaPresent.emitTextChanged(
                                    it.tag, it.text, KayaSceneModel.focusedId == it.id, false)
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
                        //
                        // THE TEXT KINDS READ THE WIDGET, not the model
                        // mirror, and that became possible with the
                        // migration: `TextFieldState` IS what the field
                        // renders from. read_text's contract asks for
                        // "what the user sees in the field, read from the
                        // toolkit" precisely so the occurrence fold alone
                        // cannot prove the screen — and a model read here
                        // could no longer see a native undo that moved
                        // the widget and not yet the mirror.
                        val got = onUi(activity) {
                            if (parts[1].startsWith("textarea"))
                                target(parts[1], "textarea", KayaSceneModel.textareas)?.let {
                                    kayaLf(it.textState.text.toString())
                                }
                            else if (parts[1].startsWith("entry"))
                                target(parts[1], "entry", KayaSceneModel.entryWidgets)?.let {
                                    kayaLf(it.textState.text.toString())
                                }
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
                            else target(parts[1], "entry", KayaSceneModel.entryWidgets))
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
                    "expect_file_dialog" -> {
                        // Expanded like the goto's argument, so a scene
                        // can name the same directory in both places and
                        // the pid stays out of the script. An
                        // interpreter that expanded only the goto reads
                        // the RIGHT directory back and compares it to
                        // the literal "$PID".
                        val wantDir = kayaExpandPath(parts.getOrNull(1) ?: "")
                        val wantNames = parts.drop(2)
                        // A LEFTOVER $ means the expansion did not
                        // happen, and an unexpanded expectation is the
                        // WORST shape of this bug: the picker is aimed
                        // correctly, shows the right directory, and the
                        // comparison fails against a literal "$PID" —
                        // which reads as a broken picker. Measured
                        // here, wiring this arm.
                        if (wantDir.contains("$")) {
                            failures.add(
                                "expect_file_dialog $wantDir: unexpanded substitution — " +
                                    "only \$TMP and \$PID exist",
                            )
                        }
                        // Reads the REAL picker: the directory it is
                        // showing and the names its list holds. Both
                        // matter — a panel aimed at the wrong place, or
                        // filtered down to nothing, presents perfectly
                        // and is useless.
                        val state = kayaFileDialogState()
                        if (state == null) {
                            failures.add("no file dialog live, wanted \"$wantDir\"")
                        } else {
                            val (where, rows) = state
                            val missing = wantNames.firstOrNull { !rows.contains(it) }
                            when {
                                wantDir.isEmpty() -> observed.add("file dialog live")
                                !where.endsWith(wantDir) ->
                                    failures.add(
                                        "file dialog showing \"$where\", wanted \"$wantDir\""
                                    )
                                missing != null ->
                                    failures.add(
                                        "file dialog list has $rows, missing \"$missing\""
                                    )
                                else -> observed.add("file dialog \"$wantDir\" $wantNames")
                            }
                        }
                    }
                    "clipboard_seed" -> {
                        // An action, silent like click — expect_clipboard
                        // or the guest's own read is what says whether it
                        // landed. Android's foreign writer is the helper
                        // APK: there is no `cmd clipboard` and no
                        // host-side path that carries more than text, so
                        // the outside process has to be a real app.
                        //
                        // OFF THE MAIN THREAD, where every verb already
                        // runs: this blocks on another process, and the
                        // ordered broadcast's result lands on main.
                        if (parts.size > 2) {
                            kayaClipboardSeed(parts[1], quoted(parts.drop(2)))
                        } else {
                            failures.add("clipboard_seed wants a kind and its content")
                        }
                    }
                    "expect_clipboard" -> {
                        if (parts.size > 2) {
                            val kind = parts[1]
                            val want = quoted(parts.drop(2))
                            // POLLED by the generic expect wrapper below:
                            // the copy went out on the apply pump, so the
                            // clipboard changes a moment after the click
                            // that asked for it.
                            val got = kayaClipboardRead(kind)
                            if (got == want) {
                                observed.add("clipboard $kind \"$got\"")
                            } else {
                                failures.add(
                                    "the clipboard's $kind reads \"$got\", wanted \"$want\"")
                            }
                        } else {
                            failures.add("expect_clipboard wants a kind and the expected content")
                        }
                    }
                    "file_dialog_goto" -> {
                        // Silent like click: the observable is where the
                        // NEXT picker opens, which expect_file_dialog
                        // reads back off the platform.
                        kayaFileDialogGoto(parts.getOrNull(1) ?: "")
                    }
                    "file_choose" -> {
                        // Silent like click: the observable is the
                        // guest's reaction to the result.
                        //
                        // EXCEPT that the row must be THERE, the same
                        // rule harness.rs and KayaSwiftUI apply: a name
                        // matching nothing skips the selection and
                        // presses Open anyway, and the picker completes
                        // with whatever was already selected — a silent
                        // wrong file. Measured on GTK.
                        val want = parts.getOrNull(1) ?: ""
                        val rows = kayaFileDialogState()?.second
                        if (want.isNotEmpty() && want != "cancel" && rows != null &&
                            !rows.contains(want)
                        ) {
                            failures.add(
                                "file_choose $want: the dialog lists $rows — selecting " +
                                    "nothing and pressing Open anyway returns a file, so " +
                                    "this would pick the wrong one silently",
                            )
                            // Dismiss it anyway: refusing alone leaves the
                            // picker up and the next show trips the
                            // one-per-process guard, whose abort takes
                            // this failure list with it.
                            kayaFileDialogDrive("cancel")
                        } else {
                            kayaFileDialogDrive(want)?.let {
                                failures.add("file_choose $want: $it")
                            }
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
                        //
                        // AND ONLY WHERE IT WOULD RUN. With both panes
                        // on screen the BackHandler is DISABLED and the
                        // gesture goes to the system, so nothing in
                        // kaya pops; calling kayaUserBack regardless
                        // pops a detail that covers nothing and blanks
                        // the trailing pane. Until this leg reached a
                        // 1280dp device, no lane ran Compose's split
                        // arm, so the verb and the real gesture had
                        // been disagreeing unobserved.
                        //
                        // Keyed on the SCAFFOLD ARRANGEMENT rather than
                        // on the handler's `enabled` expression, which
                        // would be the more literal mirror: `enabled`
                        // is computed during composition, this verb
                        // posts straight to the UI thread, and a read
                        // taken between a push and its recomposition
                        // would see the pre-push value and refuse a pop
                        // it owed. This spelling has the same truth
                        // value — the arrangement IS the disabling
                        // condition, and the empty-stack half is
                        // kayaUserBack's own early return — and its
                        // stale value is the harmless one.
                        onUi(activity) {
                            if (KayaSceneModel.splitPresentation != "split") kayaUserBack()
                        }
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
                        val want = quoted(parts.drop(2))
                        val node = kayaWidgetTarget(parts[1])
                        when {
                            node == null ->
                                failures.add("no such target ${parts[1]}")
                            node.a11yId.isEmpty() ->
                                failures.add(
                                    "ax ${parts[1]}: no a11y_id to find it by"
                                )
                            else -> {
                                val got = onUi(activity) { kayaAx(activity, node.a11yId) }
                                if (got == null) {
                                    failures.add(
                                        "ax ${parts[1]}: nothing carries " +
                                            "test tag \"${node.a11yId}\"; " +
                                            onUi(activity) { kayaAxDump(activity) }
                                    )
                                } else if (got != want) {
                                    failures.add(
                                        "ax \"$got\", wanted \"$want\"" +
                                            onUi(activity) { kayaAxWhy(activity, node.a11yId) }
                                    )
                                } else {
                                    observed.add("ax \"$want\"")
                                }
                            }
                        }
                    }
                    "expect_ax_hint" -> {
                        val want = quoted(parts.drop(2))
                        val node = kayaWidgetTarget(parts[1])
                        when {
                            node == null ->
                                failures.add("no such target ${parts[1]}")
                            node.a11yId.isEmpty() ->
                                failures.add(
                                    "ax hint ${parts[1]}: no a11y_id to find it by"
                                )
                            else -> {
                                val got = onUi(activity) { kayaAxHint(activity, node.a11yId) }
                                if (got == null) {
                                    failures.add(
                                        "ax hint ${parts[1]}: nothing carries " +
                                            "test tag \"${node.a11yId}\""
                                    )
                                } else if (got != want) {
                                    failures.add("ax hint \"$got\", wanted \"$want\"")
                                } else {
                                    observed.add("ax hint \"$want\"")
                                }
                            }
                        }
                    }
                    "resize_window" -> {
                        // Android does not command window size — the
                        // system owns it (DESIGN.md, Windows). Loud
                        // rather than a silent no-op: a scene that
                        // resizes here is asking this host something it
                        // cannot answer, and check-stubs keeps a runner
                        // from wiring legs against that.
                        failures.add("resize_window: this host does not command window size")
                    }
                    "expect_split" -> {
                        // `<size class>/<presentation>`: the platform's
                        // width reading, and the arm that rendered.
                        val want = quotedHead(line.substring(parts[0].length))?.first ?: ""
                        val got =
                            onUi(activity) {
                                KayaSceneModel.formFactor +
                                    "/" +
                                    KayaSceneModel.splitPresentation
                            }
                        if (want.isEmpty()) {
                            val halves = got.split("/", limit = 2)
                            // navEntries, NOT entries: `entries` is the
                            // entry-WIDGET registry, and the wrong one
                            // compiles clean because both are lists.
                            val stack = onUi(activity) { KayaSceneModel.navEntries.size }
                            if (halves.size == 2 &&
                                halves[0] == "regular" &&
                                halves[1] == "stacked" &&
                                stack >= 1
                            ) {
                                failures.add(
                                    "presentation $got: a regular window must not show " +
                                        "one pane while its stack holds two")
                            } else {
                                observed.add("split fits")
                            }
                        } else if (got == want) {
                            observed.add("split $want")
                        } else {
                            failures.add("split $got, wanted $want")
                        }
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
 * into it — user edits through onValueChange, the wire's property
 * write, the harness's set_text, and the platform-insertion half of the
 * paste split (which writes the model directly, so no onValueChange
 * runs) — and reads need none.
 *
 * NOT on the delivered half of the paste split, deliberately: content
 * handed to the app's own paste hook crosses as a REPRESENTATION and
 * not as this field's text, and the mac and GTK arms hand it over
 * unnormalized too.
 */
private fun kayaLf(s: String): String =
    if (s.contains('\r')) s.replace("\r\n", "\n").replace('\r', '\n') else s

// ---- The native text-undo tier ------------------------------------
//
// TWO TIERS, ONE SURFACE (docs/undo-plan.md D1): text-local undo
// delegates to the platform's own stack the way Cut/Copy/Paste do, and
// app-state undo is the core's ledger. This section carries the
// delegated half plus the three facts the core needs from a backend.
//
// §3a WAS ANSWERED BY MEASUREMENT HERE, NOT INHERITED, and the answer is
// the OPPOSITE of the mac arm's. §0 argues for delegation partly on "a
// native undo emits the ordinary text_changed — the channel already
// exists"; §3a records that measured FALSE under SwiftUI, where the undo
// runs on the field editor's own manager and never calls the binding's
// setter. On Compose it is TRUE, and structurally rather than luckily:
// `TextFieldState.text` IS snapshot state, `undoState.undo()` writes that
// same state, and the observation this backend emits from is a snapshot
// observer — there is no separate commit path for an undo to bypass.
// Measured on emulator-5558, foundation 1.7.5:
//
//     type "abc"                -> tfsObserved=4 canUndo=true
//     undoState.undo()          -> tfsObserved=5 text=""   canUndo=false
//     undoState.redo()          -> tfsObserved=6 text="abc"
//     hardware Ctrl+Z           -> tfsObserved=5 text=""
//     programmatic write "PROG" -> tfsObserved=4 text="PROG" canUndo=false
//
// So this arm does NOT write the node's text itself the way the mac one
// must. It rides the ordinary channel and brackets it ledger-quiet, which
// is precisely what Q2's flag was built for.

/**
 * EVERY TOUCH OF `undoState`, in one place — which is what keeps the
 * file's experimental opt-in to a single annotation at the smallest scope
 * that covers it, instead of one per call site where a future
 * experimental API could ride in unnoticed.
 *
 * `undoState` and its five members are the ONLY `@ExperimentalFoundationApi`
 * surface this file uses at foundation 1.7.5 (measured: removing the
 * opt-in in the probe produced 21 errors, all of them that one message,
 * at exactly the `undoState`/`canUndo`/`canRedo`/`undo`/`redo`/
 * `clearHistory` sites; `TextFieldState`, `edit {}`,
 * `setTextAndPlaceCursorAtEnd`, `BasicTextField(state=)`,
 * `TextFieldLineLimits` and `decorator` are all STABLE there).
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
private object KayaUndoState {
    fun canUndo(node: KayaNode): Boolean = node.textState.undoState.canUndo
    fun canRedo(node: KayaNode): Boolean = node.textState.undoState.canRedo
    fun undo(node: KayaNode) = node.textState.undoState.undo()
    fun redo(node: KayaNode) = node.textState.undoState.redo()
    fun clearHistory(node: KayaNode) = node.textState.undoState.clearHistory()
}

/**
 * KAYA WRITES A TEXT WIDGET: the model and the widget together, and D7 +
 * A3 with them.
 *
 * D7 (an app overwrite invalidates the field's edit history) is FREE on
 * this backend and that is the whole reason for the migration:
 * `setTextAndPlaceCursorAtEnd` calls `commitEdit`, which calls
 * `TextUndoManager.clearHistory()`. The explicit `clearHistory()` beside
 * it is a measured no-op kept as the RULE'S SPELLING — the same call the
 * Windows arm makes for the same reason — so a reader looking for D7 on
 * this backend finds a call rather than an inference.
 *
 * A3 IS THE GUARD AND IT IS NOT TIDINESS. Measured: even a no-op rewrite
 * of identical text clears the history (B6). An app that mirrors a
 * field's text into a signal and writes it back would therefore lose the
 * user's typing history on EVERY KEYSTROKE. So the write itself is
 * skipped when the text has not moved — on this platform the guard has to
 * sit in front of the WRITE, not in front of the clear, because here the
 * write IS the clear.
 *
 * The model is assigned either way, and assigned FIRST: the observer in
 * KayaTextField reports what makes the two DIFFER, so a model that lagged
 * the widget by even one collector turn would emit kaya's own write back
 * to the app as if the user had typed it.
 */
internal fun kayaWriteText(node: KayaNode, next: String) {
    node.text = next
    // PROP_TEXT reaches labels and buttons too, and they have no field
    // to write into: touching `textState` here would mint a state object
    // per label for nothing and would spend a clear on a widget with no
    // history. The model assignment above is the whole write for them,
    // exactly as it was before the migration.
    if (node.kind != KayaCompose.KIND_ENTRY && node.kind != KayaCompose.KIND_TEXTAREA) return
    if (node.textState.text.contentEquals(next)) return
    node.textState.setTextAndPlaceCursorAtEnd(next)
    KayaUndoState.clearHistory(node)
}

/**
 * A1 (docs/undo-plan.md §3): a core undo group committed, so the focused
 * editable's native history goes with it — the episode was banked off the
 * observation stream before the clear, so nothing is lost but
 * granularity.
 *
 * THIS IS THE ONE SITE THAT NEEDS AN EXPLICIT `clearHistory()`. Every
 * other clear in this arm is a write and clears by construction; this one
 * must clear WITHOUT touching the text, and `undoState.clearHistory()` is
 * measured to empty BOTH stacks while leaving the field's content alone.
 *
 * It is the keystone of the ledger's total order: every episode begins
 * with an empty native stack, so the native stack can never reach past
 * the current episode's start, and the interleave the literature calls
 * selective undo becomes unconstructible rather than merely unlikely.
 */
internal fun kayaClearUndoForGroup() {
    kayaFocusedTextNode()?.let { KayaUndoState.clearHistory(it) }
}

/**
 * The focused widget, if it is one this arm's text tier applies to.
 *
 * The MODEL's focus and not the platform's, deliberately: kaya's focus is
 * what every other command on this host acts through
 * ([KayaCompose.kayaRoleEnabled]'s cut/copy/paste arms read the same
 * thing), and the two agree because the model is what drives the
 * FocusRequester in the first place.
 */
internal fun kayaFocusedTextNode(): KayaNode? {
    val id = KayaSceneModel.focusedId ?: return null
    val node = KayaSceneModel.nodes[id] ?: return null
    return if (node.kind == KayaCompose.KIND_ENTRY || node.kind == KayaCompose.KIND_TEXTAREA) {
        node
    } else {
        null
    }
}

/**
 * A4's ONE named query — "can the focused widget undo?" — answered in
 * this platform's vocabulary and asked nowhere else in this file.
 *
 * D6 already named four hard-coded role filters as silent-failure sites;
 * a fifth expression of this same question is the shape A4 exists to
 * refuse. The core's `route_undo` consumes the answer.
 */
internal fun kayaFocusedCanUndo(): Boolean =
    kayaFocusedTextNode()?.let { KayaUndoState.canUndo(it) } == true

/** Redo's twin, same contract. */
internal fun kayaFocusedCanRedo(): Boolean =
    kayaFocusedTextNode()?.let { KayaUndoState.canRedo(it) } == true

/**
 * Where an undo can go: the focused text's own stack, the core's ledger,
 * or nowhere — `Scene::route_undo`'s three answers, mirrored.
 */
enum class KayaUndoRoute {
    NOTHING,
    NATIVE,
    CORE,
}

/**
 * The ledger-quiet bracket around a native undo this backend ROUTED (§3,
 * and the "report it once" rule): node id -> the text the walk left in
 * the widget, recorded when the sample was taken.
 *
 * A BRACKET AND NOT A FLAG-WITH-A-TIMER, because the two reports of one
 * native undo are not adjacent in time: the sample is taken the instant
 * `undo()` returns, and the snapshot observer delivers the same text one
 * frame LATER. A boolean set and cleared around the call would be long
 * gone by then. Matching on the text the sample saw is exact, needs no
 * clock, and self-clears — the entry is consumed by the edit it was
 * written for. UI thread only, like the rest of this model.
 */
private val kayaNativeUndoEcho = HashMap<Long, String>()

/** Is this edit the echo of a routed native undo? Consumes the record if
 *  so — one bracket, one edit. */
internal fun kayaTakeNativeUndoEcho(id: Long, text: String): Boolean {
    if (kayaNativeUndoEcho[id] != text) return false
    kayaNativeUndoEcho.remove(id)
    return true
}

/**
 * THE NATIVE TIER, performed: hand the walk to the field's own stack and
 * report it to the ledger ONCE.
 *
 * The sample is taken IMMEDIATELY after the walk, from the widget rather
 * than from the model, because the model is exactly one collector turn
 * stale right here — and the same three facts the core needs
 * (`note_native_undo`: the field, the text the walk landed on, whether it
 * can still undo) are true only at that instant.
 *
 * THE THIRD FACT IS `canUndo` IN BOTH DIRECTIONS, deliberately, exactly
 * as the mac arm sends it. It is not "did this walk have more to give" —
 * it is the core's test for the one case A1's clear is meant to make
 * unreachable, a platform that coalesced ACROSS the episode's start. A
 * redo reporting `canRedo` there would answer false at the end of a
 * forward walk and send the core backwards.
 */
internal fun kayaNativeUndo(redo: Boolean) {
    val node = kayaFocusedTextNode() ?: return
    if (redo) KayaUndoState.redo(node) else KayaUndoState.undo(node)
    val text = kayaLf(node.textState.text.toString())
    kayaNativeUndoEcho[node.id] = text
    kayaNoteNativeUndo(node, text, KayaUndoState.canUndo(node))
}

// ---- The seam to the core's ledger --------------------------------
//
// The five entries below are this host's spelling of KayaHostApi's undo
// rows: `undoRoute`, `redoRoute`, `undo`, `redo`, `noteNativeUndo`,
// declared in KayaPresent.kt and registered by
// `register_present_natives` in crates/kaya/src/android.rs. Kotlin
// cannot call a C symbol without one — there is no generic bridge here,
// and every core query on this host (specHash, stalledMs, nextCommands,
// blobData) is a registered native. tools/check-jni.sh pins both
// directions of that pairing.
//
// THE WINDOW IS 0 EVERYWHERE HERE, stated rather than crossed: Android is
// one Activity and one surface, which android.rs already says for the
// emit. macOS asks `kayaPresentedMenuWindow` because it has a key window
// and a global menu bar; this platform has neither.

/**
 * Where an undo would go RIGHT NOW.
 *
 * ASKED ONCE AND USED TWICE — enablement and activation are the same
 * question (D6), and NOTHING is what a disabled Edit>Undo means. Two
 * expressions of it would drift, which is A4's whole point.
 *
 * AND THE ANSWER IS THE CORE'S, not this layer's. What the backend
 * contributes is the pair only it can see — what is focused, and whether
 * that field's own stack has anything ([kayaFocusedCanUndo]) — and the
 * ledger decides against them. A routing rule written here would be a
 * fifth hard-coded predicate of exactly the kind D6 records as the
 * silent-failure shape.
 */
internal fun kayaUndoRoute(): KayaUndoRoute =
    kayaRouteCode(
        KayaPresent.undoRoute(0, KayaSceneModel.focusedId ?: 0, kayaFocusedCanUndo()))

/**
 * Redo's twin. On the frontier episode redo stays NATIVE while the
 * episode is partly undone — the platform still holds those steps, and
 * taking them back coarsely would throw away granularity the user sees.
 * That judgement is the ledger's too; this asks with `canRedo`.
 */
internal fun kayaRedoRoute(): KayaUndoRoute =
    kayaRouteCode(
        KayaPresent.redoRoute(0, KayaSceneModel.focusedId ?: 0, kayaFocusedCanRedo()))

/**
 * The core's three-way answer, in this file's vocabulary. An unknown code
 * is a PROTOCOL DRIFT, not a "nothing to do": the core and this
 * interpreter would disagree about routing, silently, on every
 * activation — and "nothing to do" is the one wrong answer that looks
 * exactly like the right one. `undo_route_code` in
 * crates/kaya/src/capi.rs is the authority for the mapping.
 */
internal fun kayaRouteCode(code: Int): KayaUndoRoute =
    when (code) {
        0 -> KayaUndoRoute.NOTHING
        1 -> KayaUndoRoute.NATIVE
        2 -> KayaUndoRoute.CORE
        else -> error(
            "kaya: unknown undo route $code from the core — the JNI surface and " +
                "this interpreter disagree")
    }

/**
 * THE ONE REPORT OF A ROUTED NATIVE UNDO (§3). The core walks its
 * frontier episode from three facts and ends the walk three ways —
 * consumed at the before-image, still open with more to give, or
 * exhausted short of it (the case A1's clear is supposed to make
 * unreachable). All three are the core's to decide.
 *
 * ONE REPORT AND NOT TWO, on a backend where BOTH channels fire. §3a
 * demands each arm measure whether a native undo reaches kaya's model,
 * and this one answered YES where the mac arm answered no
 * (scratchpad/undo-fan-compose.md §1 Q-a, re-measured on the shipped
 * source at §3 point 6): `undoState.undo()` writes the same snapshot
 * state the field's collector observes, so the ordinary `text_changed`
 * arrives a frame later on its own. That emission is bracketed
 * LEDGER-QUIET ([kayaNativeUndoEcho]) and this call is the report, which
 * is Q2's one-reporter rule with the two platforms differing only in
 * which of the two reports they suppress.
 */
internal fun kayaNoteNativeUndo(node: KayaNode, text: String, canUndo: Boolean) {
    KayaPresent.noteNativeUndo(0, node.id, text, canUndo)
}

/**
 * The CORE tier: routing cases 2 and 3 (§3) — the ledger's newest entry
 * is a group, or an episode that is no longer frontier-live, and the core
 * applies the inverse itself.
 *
 * NOTHING COMES BACK, and that is the shape rather than an omission.
 * Applying the inverse produces ordinary apply records, which reach this
 * interpreter through the pump like every other write; the app hears one
 * `undone` carrying the whole restored state. So the call is a request,
 * the effects arrive on the two channels that already exist, and this
 * layer keeps no copy of the ledger to disagree with.
 */
internal fun kayaCoreUndo() {
    KayaPresent.undo(0)
}

/** Redo's twin, symmetric in every respect (the forward delta was
 *  computed at apply beside the inverse, so nothing is re-run). */
internal fun kayaCoreRedo() {
    KayaPresent.redo(0)
}

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
    // THE UNIVERSAL ACCESSIBILITY PROPS, folded into the base modifier
    // every kind already threads.
    //
    // contentDescription is the semantics property a service speaks, so
    // a11y_label reaches assistive tech directly.
    //
    // a11y_id is a plain testTag. Android has no accessibility-identifier
    // concept the way accessibilityIdentifier (AppKit) and AutomationId
    // (WinUI) are genuine platform properties; the testTag is the
    // identity slot in the semantics tree, and it is what Compose's own
    // test framework matches on. The detour worth naming is
    // testTagsAsResourceId, which additionally copies the tag into the
    // node's resource-id: it is experimental, and it exists for
    // out-of-process clients like UIAutomator, which can only match on
    // properties that survive into AccessibilityNodeInfo. The read here
    // is in-process against the merged semantics tree, so it would cost
    // an experimental opt-in to buy nothing.
    //
    // Empty stays unset: Compose derives a control's description from
    // its own content, and writing "" would silence it.
    //
    // The two halves are separately named because ONE kind cannot take
    // the name this way: Image publishes Role.Image only when the name
    // rides its own contentDescription PARAMETER (measured 2026-07-25 —
    // an image named through the modifier read `unknown/Logo`, since
    // `contentDescription = null` is Compose's spelling of "decorative,
    // hide me"). That arm takes a11yTag and hands the name to Image
    // itself; everything else takes both through `a11y`.
    val a11yTag = if (node.a11yId.isNotEmpty()) Modifier.testTag(node.a11yId) else Modifier
    val a11yName =
        if (node.a11yLabel.isNotEmpty()) {
            Modifier.semantics { contentDescription = node.a11yLabel }
        } else {
            Modifier
        }
    // THE HINT rides the CLICK ACTION'S LABEL, which is Android's
    // author-supplied hint: TalkBack speaks it as "double tap to
    // <label>". Measured 2026-07-25 on a Material3 Button — layering a
    // label-only semantics node relabels the action and KEEPS it
    // (clickLabel=ours, clickAction=true, role and name untouched),
    // because the OnClick key's merge policy takes the parent's label
    // and the child's action. `action = null` is what says "I am only
    // naming what the control already does".
    //
    // Nothing else on Android carries a hint: there is no hint
    // SemanticsProperty, and AccessibilityNodeInfo.hintText is the
    // editable-field placeholder, not a description. That is why the
    // root scopes this prop to activation kinds.
    val a11yHint =
        if (node.a11yHint.isNotEmpty()) {
            Modifier.semantics { onClick(label = node.a11yHint, action = null) }
        } else {
            Modifier
        }
    val a11y = a11yTag.then(a11yName).then(a11yHint)
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
                    modifier = a11y.menuAnchor(),
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
                modifier = a11y,
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
            Column(modifier = a11y.selectableGroup()) {
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
                androidx.compose.material3.LinearProgressIndicator(modifier = a11y)
            } else {
                androidx.compose.material3.LinearProgressIndicator(
                    modifier = a11y,
                    progress = { node.value.toFloat() })
            }
        KayaCompose.KIND_SCROLL ->
            // The vertical scroll viewport over its ONE child (the
            // scene enforces the count): verticalScroll over the
            // node's own ScrollState — the toolkit's real scrolling
            // machinery, which the runner's verbs read and drive.
            Box(
                rootFill.then(a11y).verticalScroll(node.scrollState)
            ) {
                node.children.firstOrNull()?.let { KayaRender(it) }
            }
        KayaCompose.KIND_COLUMN ->
            // Normalized default: children packed to the top at natural
            // size, leading-aligned (Alignment.Start), 8 dp between them.
            Column(
                modifier = rootFill.then(a11y).onGloballyPositioned {
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
            Button(onClick = { KayaPresent.emitClicked(node.tag) }, modifier = a11y) {
                Text(node.text)
            }
        KayaCompose.KIND_ROW ->
            // Normalized default: children packed to the leading edge at
            // natural size, top-aligned (Alignment.Top), 8 dp between them.
            Row(
                modifier = rootFill.then(a11y).onGloballyPositioned {
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
        KayaCompose.KIND_LABEL -> Text(node.text, modifier = a11y)
        KayaCompose.KIND_CHECKBOX ->
            // Uncontrolled toward the app, the entry's shape: the node
            // mirrors the box's state (Compose needs it), and every
            // flip is emitted with the box's identity tag. The caption
            // rides beside the box, the labeled-checkbox idiom.
            //
            // The TOGGLE LIVES ON THE ROW, not on the box, and the box
            // takes onCheckedChange = null — Material's own labeled
            // checkbox recipe, and here it is what makes the control ONE
            // thing to an assistive client. A box with its own
            // onCheckedChange is independently screen-reader-focusable,
            // and Compose's merging deliberately STOPS at such a node
            // (an independently focusable descendant is not absorbed):
            // measured 2026-07-25, the caption row then read
            // `group/Details` with a separate unnamed checkbox inside
            // it, instead of the single `checkbox/Details` every other
            // backend publishes. Moving the toggle up also makes the
            // whole row the hit target, which is what the caption
            // beside a box means everywhere else.
            Row(
                modifier = a11y
                    .toggleable(
                        value = node.checked,
                        role = Role.Checkbox,
                        onValueChange = { newValue ->
                            node.checked = newValue
                            KayaPresent.emitToggled(node.tag, newValue)
                        },
                    )
                    .semantics(mergeDescendants = true) {},
                horizontalArrangement = Arrangement.spacedBy(4.dp, Alignment.CenterHorizontally),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Checkbox(checked = node.checked, onCheckedChange = null)
                Text(node.text)
            }
        KayaCompose.KIND_SLIDER ->
            // Uncontrolled toward the app, the entry's shape: the node
            // mirrors the slider's position (Compose needs the state),
            // and every move is emitted with the slider's identity tag.
            Slider(
                modifier = a11y,
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
            //
            // The one kind whose NAME does not ride the shared modifier:
            // Image's own contentDescription parameter is what declares
            // Role.Image, and null there is Compose's spelling of "this
            // is decoration, hide it from assistive tech" — which is the
            // right default for an unnamed image and the wrong answer
            // for a named one.
            node.imageBitmap?.let { bitmap ->
                Image(
                    bitmap = bitmap,
                    contentDescription = node.a11yLabel.ifEmpty { null },
                    modifier = a11yTag,
                )
            }
        // The multi-line editor: the entry's exact contract
        // (uncontrolled state, identity-tag emits, model-driven focus)
        // over a multiline field. One composable serves both kinds —
        // they differed only in two arguments, and a second copy is a
        // second place for the echo guard to be got wrong.
        KayaCompose.KIND_TEXTAREA -> KayaTextField(node, a11y, singleLine = false)
        KayaCompose.KIND_ENTRY -> KayaTextField(node, a11y, singleLine = true)
    }
}

/**
 * THE ENTRY AND THE TEXTAREA, on `BasicTextField(state:)` with M3
 * dressing (docs/undo-plan.md §1.4).
 *
 * WHY NOT `TextField(value:, onValueChange:)` any more: that path's undo
 * stack is an INTERNAL `UndoManager` the app cannot see, clear or ask,
 * Ctrl+Z drives it, and kaya's writes enter it — see [KayaNode.textState]
 * for the measured worst case. This shape is the only one on which D7
 * (an app write invalidates the field's edit history) and D6's native
 * tier (`undoState.canUndo` / `undo()`) can be expressed at all.
 *
 * AND IT NEEDS NO PIN BUMP, which was the open question §1.4 closed:
 * material3 1.3.1 has no `TextField(state:)` overload (compile-proven —
 * "None of the following candidates is applicable"), but
 * `BasicTextField(state=)` + `TextFieldDefaults.DecorationBox` compiles
 * and renders as a proper M3 filled field at kaya's own BOM. The cost is
 * two opt-ins, each proven required by removing it.
 *
 * THE ECHO GUARD IS THE ONE NEW FAILURE CLASS, and it is why the
 * observation is a comparison rather than a flag. `TextFieldState` has no
 * `onValueChange`; the observation is `snapshotFlow { state.text }`, and
 * MEASURED that channel fires for kaya's OWN writes too (the legacy
 * path's `onValueChange` never did). Under the echo doctrine a
 * programmatic write must not emit, so [kayaWriteText] moves the model
 * and the widget together and this collector reports only what makes them
 * DIFFER — which is exactly the set of edits kaya did not perform. A
 * boolean set around the write would have to survive an unknown number of
 * frames; the comparison is exact and self-clearing.
 */
// The M3 dressing is the file's SECOND and last experimental opt-in, and
// it is proven required rather than assumed: removing it fails the
// compile with "This material API is experimental" at the DecorationBox
// call, one error, at material3 1.3.1.
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun KayaTextField(node: KayaNode, a11y: Modifier, singleLine: Boolean) {
    val focusRequester = remember { FocusRequester() }
    val interaction = remember { MutableInteractionSource() }
    // ONE COLLECTOR PER NODE, keyed by the node itself: a destroy and
    // re-create at the same id would otherwise keep observing a state
    // nobody reads.
    LaunchedEffect(node) {
        snapshotFlow { node.textState.text.toString() }.collect { raw ->
            val value = kayaLf(raw)
            // The echo of kaya's own write: the model already says this.
            if (value == node.text) return@collect
            node.text = value
            // Q2's LEDGER-QUIET bracket (docs/undo-plan.md §3a): if this
            // edit is the echo of a native undo THIS BACKEND ROUTED, the
            // change was already reported to the ledger once, with the
            // sample taken at the moment it was true. The app still hears
            // it — the field is uncontrolled and the app's model must
            // follow — and only the banking is suppressed.
            val quiet = kayaTakeNativeUndoEcho(node.id, value)
            KayaPresent.emitTextChanged(
                node.tag, value, KayaSceneModel.focusedId == node.id, quiet)
        }
    }
    BasicTextField(
        state = node.textState,
        lineLimits =
            if (singleLine) TextFieldLineLimits.SingleLine
            else TextFieldLineLimits.MultiLine(minHeightInLines = 3),
        interactionSource = interaction,
        textStyle = LocalTextStyle.current.copy(color = LocalContentColor.current),
        modifier = a11y
            .focusRequester(focusRequester)
            // Gain-only back-propagation: onFocusChanged also fires with
            // the initial unfocused state at attach, and a loss branch
            // there would clear a focusedId the LaunchedEffect below has
            // not yet requested.
            .onFocusChanged { state ->
                if (state.isFocused) KayaSceneModel.focusedId = node.id
            },
        // The M3 clothes the bare foundation field does not bring:
        // container, indicator line and padding, so the two kinds look
        // exactly as they did before the migration.
        decorator = { inner ->
            TextFieldDefaults.DecorationBox(
                value = node.textState.text.toString(),
                innerTextField = inner,
                enabled = true,
                singleLine = singleLine,
                visualTransformation = VisualTransformation.None,
                interactionSource = interaction,
                contentPadding = TextFieldDefaults.contentPaddingWithoutLabel(),
            )
        },
    )
    LaunchedEffect(KayaSceneModel.focusedId) {
        if (KayaSceneModel.focusedId == node.id) focusRequester.requestFocus()
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
    //
    // And DISABLED while both panes are on screen. Back reveals what
    // the top entry covers, and in the split arm it covers nothing: the
    // leading pane is already beside it. Leaving the handler enabled
    // would pop to a blank detail pane. This is Compose's own rule,
    // where canNavigateBack reports false once both panes are visible;
    // disabling the handler is how that is spelled here, and it lets
    // back reach the system exactly as it would in a Material app.
    androidx.activity.compose.BackHandler(
        enabled = KayaSceneModel.navEntries.isNotEmpty() && !kayaSplitArm()
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

/** How many panes this window may show side by side, and how wide they
 * may be: MATERIAL'S answer, from the real window.
 *
 * kaya does not draw the one-pane/two-pane line and no prop moves it —
 * the app declares list_detail and the platform decides presentation.
 * The standard directive grants a second horizontal partition at
 * 840dp, so 840dp is Android's threshold, chosen by Android. */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
internal fun kayaPaneDirective(): PaneScaffoldDirective =
    calculatePaneScaffoldDirective(currentWindowAdaptiveInfo())

/** The pane arrangement [ListDetailPaneScaffold] lays out from: which
 * roles are expanded and which are hidden.
 *
 * SUPPLIED, NOT OWNED, which is why adaptive-navigation is deliberately
 * not a dependency: its navigator would hold a destination history, and
 * kaya's core owns the stack (DESIGN.md, Navigation). The wrapper is
 * told the ONE fact it needs — is a detail open — and nothing else, so
 * the guest's pop and the widget's pop cannot become two truths.
 *
 * Everything past that fact is Material's: the directive is Material's
 * reading of the window, the adapt strategies are the list-detail
 * defaults, and which panes survive is `calculateThreePaneScaffoldValue`'s
 * call. That is what makes reading this back an observation rather than
 * an echo. */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
internal fun kayaScaffoldValue(directive: PaneScaffoldDirective): ThreePaneScaffoldValue =
    calculateThreePaneScaffoldValue(
        directive.maxHorizontalPartitions,
        ListDetailPaneScaffoldDefaults.adaptStrategies(),
        ThreePaneScaffoldDestinationItem<Nothing>(
            if (KayaSceneModel.navEntries.isEmpty()) {
                ListDetailPaneScaffoldRole.List
            } else {
                ListDetailPaneScaffoldRole.Detail
            }
        ),
    )

/** Is the scaffold showing BOTH list-detail panes: the arrangement
 * question, asked of the arrangement.
 *
 * Named role by role rather than counted, because "both panes are on
 * screen" is exactly what the two roles say — and `expandedCount`,
 * which would say it in one word, is internal to the library in
 * 1.0.0. */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
internal fun kayaBothPanesExpanded(value: ThreePaneScaffoldValue): Boolean =
    value[ListDetailPaneScaffoldRole.List] == PaneAdaptedValue.Expanded &&
        value[ListDetailPaneScaffoldRole.Detail] == PaneAdaptedValue.Expanded

/** Whether this window is presenting its entry stack as list-detail
 * right now, meaning both panes are on screen.
 *
 * ONE source, read by the arm that renders and by the back rule that
 * depends on it. Two copies of this condition drift, and the drift is
 * invisible: the arm would show two panes while back still popped, or
 * the reverse, and each half would look correct on its own.
 *
 * Compose's own `canNavigateBack` is false in exactly this state —
 * back reveals what the top entry covers, and here it covers nothing —
 * and disabling the BackHandler is how that rule is spelled here. */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
internal fun kayaSplitArm(value: ThreePaneScaffoldValue): Boolean =
    KayaSceneModel.listDetail && kayaBothPanesExpanded(value)

/** The same question asked where only the window is in hand. */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
internal fun kayaSplitArm(): Boolean = kayaSplitArm(kayaScaffoldValue(kayaPaneDirective()))

/** The one scene surface (sections scaffold | nav top | mounted root),
 * exactly the pre-menus KayaRoot body: the menus top bar stacks ABOVE
 * this so a catalog never disturbs the measured offer the layout
 * observations read. */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
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
        // ADAPTIVE LIST-DETAIL (DESIGN.md): Android's OWN container,
        // ListDetailPaneScaffold, entered on the app's declaration
        // alone. WHETHER it shows one pane or two is the scaffold's
        // call, not a branch here — that is what "each platform decides
        // where one pane becomes two" means, and it is why the arm is
        // no longer gated on a width kaya picked.
        //
        // It also buys what the hand-built Row could not: the platform's
        // own pane proportions and spacing, and the collapse/expand
        // ANIMATION between them. The 25%-clamped-to-180..280dp leading
        // width this arm used to compute is gone with it — that number
        // was libadwaita's default, borrowed because nothing here knew
        // Material's.
        //
        // No `topEntry != null` requirement: an empty stack on a regular
        // window shows the leading pane and an EMPTY trailing one, the
        // same rule GTK and mac follow. Requiring an entry here reported
        // `stacked` where they report `split` for one scene, which is a
        // semantics divergence rather than a backend's call.
        if (KayaSceneModel.listDetail) {
            val directive = kayaPaneDirective()
            val scaffoldValue = kayaScaffoldValue(directive)
            // THE SCAFFOLD'S OWN ARRANGEMENT, not a value the arm
            // stamped about itself. The old spelling wrote "split"
            // inside the branch that had just tested for it, so the
            // observation restated the condition and agreed with the
            // lowering by construction; this reports how many panes
            // Material resolved, for BOTH outcomes, from the one value
            // the scaffold below is laid out from. GTK reads
            // is_collapsed and Windows reads TwoPaneView's Mode for
            // exactly this reason.
            KayaSceneModel.splitPresentation =
                if (kayaBothPanesExpanded(scaffoldValue)) "split" else "stacked"
            ListDetailPaneScaffold(
                directive = directive,
                value = scaffoldValue,
                // AnimatedPane is what carries the motion; the panes
                // are otherwise the same two roots as before — the
                // mounted root leads, the stack's top is the detail.
                listPane = {
                    AnimatedPane {
                        KayaSceneModel.root?.let { KayaRender(it, isRoot = true) }
                    }
                },
                detailPane = {
                    AnimatedPane {
                        topEntry?.root?.let { KayaRender(it, isRoot = true) }
                    }
                },
            )
        } else if (topEntry != null) {
            // The serial arm stamps too: an observation only one arm
            // writes is derived-by-default in the other.
            KayaSceneModel.splitPresentation = "stacked"
            // The stack's top is the one visible screen; the covered
            // root below stays alive (retained-until-popped).
            topEntry.root?.let { KayaRender(it, isRoot = true) }
        } else {
            KayaSceneModel.splitPresentation = "stacked"
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
 * expect_menu asserts, and what lifts when the ancestor re-enables —
 * AND, for a standard command, only while its role can act.
 *
 * The role factor is not a build-time fact: it is the intersection of
 * what the clipboard offers and what the focused widget accepts, and
 * both move long after the bar was built (docs/clipboard-plan.md §3).
 * It goes here because every affordance on this host already reads this
 * one helper — bar actions, overflow rows, drill-ins, context rows,
 * shortcuts, expect_menu, and the activation gate — so one clause
 * reaches all of them and none of them can disagree. */
fun kayaMenuEffectivelyEnabled(item: KayaMenuItem): Boolean {
    var cur: KayaMenuItem? = item
    while (cur != null) {
        if (!cur.enabled) return false
        cur = cur.parent
    }
    return KayaCompose.kayaRoleEnabled(item.role)
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
        KayaCompose.MENU_KIND_ACTION -> {
            // A ROLE ITEM IS THE PLATFORM'S COMMAND, not the app's
            // action: it acts on the focused widget and emits nothing of
            // its own, because there is nothing for the app to decide.
            // kaya has no selection API, which is exactly why these had
            // to be commands. Enablement was re-derived one line above,
            // live — that is this host's "refresh before a harness
            // activation", satisfied by construction.
            // An undo is asked FIRST and separately: it is not a
            // clipboard command, and the two perform paths are disjoint
            // by role so the order is documentation rather than
            // precedence.
            if (KayaCompose.kayaPerformUndoRole(item.role)) return
            if (KayaCompose.kayaPerformClipboardRole(item.role)) return
            KayaPresent.emitMenuActivated(item.id, noun)
        }
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
