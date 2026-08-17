package dev.kaya

import android.app.UiModeManager
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.ContentResolver
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
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
import androidx.compose.foundation.isSystemInDarkTheme
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
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
// THE SEMANTIC ICON VOCABULARY's glyphs (docs/styling-plan.md D6), one
// import per concept. Every identifier here was taken from the measured
// name lists beside styling/symbols-material-symbols.md — never from
// memory — and set-membership against `core-filled.txt` /
// `ext-filled.txt` is what decided which artifact each one ships in.
//
// THEY MUST BE IMPORTED, not written out at the callsite: every one is
// an EXTENSION PROPERTY on `Icons.Filled` (or on `Icons.AutoMirrored
// .Filled`) declared in its own package, and Kotlin has no way to spell
// an extension property fully qualified. So the import list IS the
// mapping table's other half, and a name that does not exist fails the
// COMPILER rather than drawing nothing at runtime.
//
// back/forward COME FROM `automirrored`, and that is the column's one
// real trap. The pre-1.6 spellings `Icons.Filled.ArrowBack` /
// `ArrowForward` still exist and still compile — they are only
// @Deprecated, with a ReplaceWith pointing here — so an arm that
// imported those would build clean, run clean, and point the wrong way
// in a right-to-left layout, which no test in this tree looks at.
// (styling/symbols-material-symbols.md §3.1, §4.1.)
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Done
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
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
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
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
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.colorspace.ColorSpaces
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInParent
import androidx.compose.ui.node.RootForTest
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.DeviceFontFamilyName
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.createFontFamilyResolver
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

    /** Semantic emphasis (docs/styling-plan.md D4), 0 = none. The
     * render layer lowers it to M3's own emphasis ladder — never to a
     * colour this file chose: prominent is the filled button, the floor
     * is the outlined one, destructive takes the error-role container,
     * and heading is Compose's heading semantics plus a tier of
     * Material's own type ramp. */
    var role by mutableStateOf(0L)

    /**
     * A container's own padding (docs/styling-plan.md D3, the window
     * inset one level down): DIP between its bounds and its children,
     * uniform all sides. 0 = flush, every container's default.
     */
    var inset by mutableStateOf(0.0)
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
    /**
     * THE DECLARED SET OF DECORATED RANGES (textarea only), and the text
     * it was declared against.
     *
     * The PAIR is what makes D2's clear-on-edit structural rather than a
     * message: the draw scope paints the set only while the field still
     * holds [highlightsFor], so a keystroke, a programmatic write or a
     * native undo drops it at paint time with nothing sent and nothing
     * remembered. A message from the core could not do this job — the
     * measured hazard of this whole milestone is a text change arriving
     * AFTER the thing declared over it (range-probe-mac.md H2), and a
     * compare made on the pass that paints cannot arrive late. The
     * invariant it buys: PAINTED OFFSETS WERE VALIDATED AGAINST THE TEXT
     * THEY ARE PAINTED ON.
     */
    var highlights by mutableStateOf<List<KayaRange>>(emptyList())
    var highlightsFor by mutableStateOf<String?>(null)
    /**
     * The REVEAL one-shot: the range to scroll into view, and a sequence
     * number rather than a consumed optional.
     *
     * A scroll needs the field's own [androidx.compose.ui.text.TextLayoutResult],
     * which exists only after a layout pass, so this cannot be performed
     * where it is decoded the way the selection can. The effect that
     * performs it is keyed on [revealSeq]: a recomposition for any other
     * reason re-runs nothing, and a second reveal of the SAME range still
     * runs, which a nullable request alone could not express.
     */
    var revealRequest by mutableStateOf<KayaRange?>(null)
    var revealSeq by mutableStateOf(0)
    val children = mutableStateListOf<KayaNode>()
}

/**
 * WHAT THE DRAW SCOPE ACTUALLY PAINTED, by node id, in UTF-16 code
 * units — written inside the draw lambda beside the `drawPath` calls,
 * which is the only place the answer is true.
 *
 * NOT the declared set: the declaration is [KayaNode.highlights], and a
 * verb that read it would agree with the apply arm by construction and
 * pass with the whole paint deleted — the exact shape of the trap the
 * android probe measured (§1a: pushing an `AnnotatedString` into the
 * state compiles clean, stores a plain String and paints NOTHING). This
 * is written after the staleness compare, from the ranges the platform's
 * own `getPathForRange` was handed, so a dropped set and a stale set
 * both show up here as they show up on screen.
 *
 * Android has no accessibility channel carrying a background span (the
 * probe's §4 searched for one), so this is the honest in-process read;
 * the harness pairs it with the FIELD'S OWN text for the covered half,
 * which is where a wrong offset shows up as wrong characters.
 */
val kayaPaintedRanges = HashMap<Long, List<KayaRange>>()

/**
 * The field's own text layout, by node id — the `onTextLayout` provider
 * `BasicTextField(state=)` hands out, kept as a lambda rather than a
 * result so reading it stays in the LAYOUT/DRAW phase and never
 * invalidates composition (range-probe-android.md §1c measured the
 * naive spelling recomposing the field 200 times in 200 frames).
 *
 * A plain map and not snapshot state for the same reason: it is written
 * during layout, and a snapshot write there would invalidate the pass
 * that wrote it.
 */
val kayaTextLayouts = HashMap<Long, () -> androidx.compose.ui.text.TextLayoutResult?>()

/**
 * Where each textarea's viewport sits IN THE WINDOW — the rectangle the
 * paint witness photographs.
 *
 * WINDOW coordinates, which is what `boundsInWindow()` answers and which
 * is NOT what `PixelCopy` takes: its srcRect is in the window's SURFACE
 * space, and the two agree only while nothing has panned the window.
 * Measured 2026-08-10 with the soft keyboard up,
 * `decorView.getLocationInWindow()` was (0, -199) and a witness that
 * handed these numbers straight to `PixelCopy` photographed 199px below
 * the field. The conversion lives in `kayaPhotograph`, which is the one
 * place that crosses between the two spaces.
 *
 * Measured from the laid-out node rather than computed from anything
 * kaya knows, in the same discipline the layout observations already
 * keep (`kayaCrossRects` and friends).
 */
val kayaTextBoxes = HashMap<Long, android.graphics.Rect>()

/**
 * The selection background each textarea is painted UNDER, ARGB, by node
 * id — published from the draw beside [kayaPaintedRanges], because the
 * paint witness has to composite what it expects to photograph and the
 * platform's wash sits on top of kaya's decoration.
 *
 * Resolved by the composition rather than assumed: an app that wraps a
 * MaterialTheme gets that theme's selection colour, and one that does not
 * gets foundation's default. The witness would refuse a correctly painted
 * highlight under either if it guessed the wrong one.
 */
val kayaSelectionWash = HashMap<Long, Int>()

/**
 * How many apply batches this interpreter has finished — the signal an
 * ACTION verb waits on so the app's answer lands before the next step
 * reads (see KayaCompose.kayaAwaitAnswer).
 *
 * `@Volatile` because it is written on the UI thread and read on the
 * harness thread, which is every other cross-thread read in this file's
 * arrangement — and an unpublished counter would make the wait either
 * instant or forever.
 */
@Volatile
var kayaBatches = 0

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
 * The container-inset measurement pair (docs/styling-plan.md D3, one
 * level down from the window's kayaOuterSize/kayaAvailableSize): OUTER
 * is the container's box before its own padding, INNER the content box
 * inside it, and `expect_inset <target>` reads the halved gap in DP —
 * RELATIVE for the window measurement's exact reason. Both record
 * unconditionally, so a step can also assert a container is FLUSH (0).
 */
val kayaInsetOuter = HashMap<Long, Pair<Double, Double>>()
val kayaInsetInner = HashMap<Long, Pair<Double, Double>>()

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
 * The main-axis extent each flex child DREW at, by node id — what
 * `expect_fills` compares against that child's track on a widget target.
 *
 * THE TRACK'S SIBLING, AND DELIBERATELY NOT THE SAME NUMBER.
 * [kayaMainExtents] is the weighted cell, which is the layout rect the
 * grow arithmetic decided; this is the box the control took inside it.
 * A widget that draws at a hard size in a correct cell splits its
 * container exactly right and renders wrong — measured on two backends
 * at once when a textarea with grow(1) stayed 96 units tall — and the
 * gap between these two maps is the only place that shows.
 */
val kayaDrawnExtents = HashMap<Long, Double>()

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

/** The padding container's OUTER size — captured before the window
 * inset is taken; (outer - available)/2 is the measured inset the
 * harness asserts (docs/styling-plan.md D3). */
var kayaOuterSize = androidx.compose.ui.unit.IntSize.Zero

// THE DEPTH-STUB HELPER IS BACK, the eighth time it has come and gone —
// for the toolbar slice (docs/chrome-plan.md C2), which lands mac first
// and reaches this backend in its own slice. A CALL and not a sentence:
// tools/check-stubs.sh and tools/check-steps.sh both read the call, and
// neither can see a backend that refuses in its own words. It leaves
// again with the last stub that uses it — dead code kept "for later" is
// what a reader has to reason about for nothing.
internal fun depthStub(scene: String): Nothing =
    error("kaya: the $scene scene is not yet materialized on this " +
          "backend — it is a depth slice; see CLAUDE.md's sequencing")

/**
 * TEXT RANGES, in the unit this backend counts.
 *
 * `start`/`stop` are UTF-16 CODE UNITS — the offsets the core converted
 * to before lowering (scratchpad/ranges-units.md §7), and the unit a
 * Kotlin `CharSequence` indexes, which is what every Compose text API
 * takes. NOTHING ON THE LOWERING PATH CONVERTS: this interpreter is
 * string-matched rather than compile-checked, so Unicode arithmetic in
 * an apply arm is the shape that ships wrong and stays wrong. The one
 * place this file does convert is the READING direction, where a
 * harness verb has to answer in the protocol's own unit so one frozen
 * scene compares byte-for-byte on five lanes.
 *
 * Its own type rather than a pair of Ints so a lowering cannot take two
 * loose integers in the wrong order, and so the unit has a name a
 * reader can look up.
 */
data class KayaRange(val start: Int, val stop: Int)

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
    /** The window content inset (wprop 8, docs/styling-plan.md D3), in
     * DP — layout, not appearance; 0 is full bleed. */
    var windowInset by mutableStateOf(16.0)

    /**
     * THE REQUESTED BRAND ACCENT, packed 0xRRGGBB, or null for "the app
     * asked for nothing" (apply 32; docs/styling-plan.md D1/D2).
     *
     * A composition STATE and not a plain field, because the theme is
     * what reads it: the brand arrives in an apply batch, which is
     * after the first composition on any scene that mounts before it,
     * and a plain field would leave the scheme at Material's baseline
     * until something unrelated recomposed. Set once, before the first
     * mount — the root refuses a second write, so nothing here has to
     * un-apply a brand.
     */
    var brandSeed by mutableStateOf<Int?>(null)

    // THE REQUESTED FAMILY IS NOT STORED, and its absence is the point
    // (docs/styling-plan.md Slice 2b). It existed here while the record
    // decoded into a backend that could not apply it; now that the arm
    // resolves, a field holding the REQUEST is a loaded gun pointed at
    // the observation — the one read `expect_typeface` must never make
    // is the one that would be easiest to make from here. The arm's own
    // diagnostics carry the asked-for name inline, where it cannot be
    // mistaken for a resolution.

    /**
     * THE BRAND TYPEFACE AS RESOLVED — the `FontFamily` the theme hands
     * to both of its writes, or null for "no typeface is in force",
     * which is what a brandless app and a family this device does not
     * have both get.
     *
     * A FontFamily OBJECT and not a name, and the probe is what settled
     * that (styling/typeface-compose.md §6.2): Android has NO app-font
     * registry, so the plan's "register the blob, then let the name
     * machinery take over" cannot hold here — after the bytes are loaded
     * and rendering, `Typeface.create("Noto Serif", …)` still returns
     * Roboto, both through the platform and through Compose. So the two
     * wire forms converge one layer lower than on Apple: at the
     * FontFamily the theme holds. One resolution, one observation, one
     * fallback — just not at a name.
     *
     * Composition STATE, brandSeed's reason exactly: the typeface
     * arrives in an apply batch, which is after the first composition on
     * any scene that mounts before it, and a plain field would leave the
     * ramp at Material's baseline until something unrelated recomposed.
     */
    var typefaceFamily by mutableStateOf<FontFamily?>(null)
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
    /// The sections arm that ACTUALLY rendered, "bar" or "sidebar" —
    /// stamped by the body that ran, never derived from
    /// `sectionsPresentation` or the width, so
    /// expect_sections_presentation cannot agree with the lowering by
    /// construction (the expect_split rule, docs/traps.md). Empty
    /// means no sections body has rendered at all, which is a
    /// different answer from either arm and is reported as one.
    var sectionsRendered = ""
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
    /// Does this surface hold UNSAVED WORK (wprop 7;
    /// docs/dirty-plan.md). Declared by the app, never inferred from a
    /// signal — kaya does not watch your document for you.
    ///
    /// PLAIN STATE, AND THAT IS THE WHOLE LOWERING HERE (D4). Android
    /// has no window chrome to put an unsaved-work mark in: there is no
    /// title bar, no close button, and the platform's unsaved-state
    /// affordances are FLOW ones (the predictive-back confirmation),
    /// which kaya already spells through veto_close and navigation. So
    /// nothing reads this field to draw with — deliberately — and it is
    /// not a `mutableStateOf`, because no composition depends on it.
    ///
    /// It is still what `expect_dirty` reads, and that read is not
    /// vacuous: the value arrives over the wire through the apply arm,
    /// so a backend that dropped the prop fails the assertion. The
    /// title is NEVER rewritten (D1 — Qt's `[*]` template is the named
    /// rejection), on this platform or any other.
    var windowDirty = false
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
    /**
     * THE OVERFLOW ⋮'s presentation state, and the id of the submenu it
     * is drilled into (0 = at its roots).
     *
     * HOISTED OUT OF THE COMPOSABLE for D6, and the reason is the same
     * one that put [openContextWidget] here: a harness read of a menu
     * row has to be able to MATERIALIZE that row, because on this
     * platform an overflow row does not exist until the menu is
     * presented — Compose composes a DropdownMenu's content only while
     * it is open, in a popup window of its own. While these lived in
     * `remember` locals the only thing outside composition could do was
     * ask the model what it had decoded, which is the read that agrees
     * with itself.
     *
     * The tap route and the read route now drive ONE state, exactly as
     * context_open and the long-press do.
     */
    var menuOverflowOpen by mutableStateOf(false)
    var menuOverflowDrilled by mutableStateOf(0L)
    /// Did a HARNESS READ present the overflow, rather than a tap. Only
    /// what a read opened may a read close.
    var menuOverflowPresentedForRead = false
    /**
     * THE COMPOSE ROOTS OF THE OPEN MENU POPUPS — UI thread only,
     * registered by the popup's own content and dropped when it leaves.
     *
     * A Compose `Popup` (which is what a DropdownMenu is) is a SEPARATE
     * WINDOW: its view is added straight to the WindowManager and is not
     * under `activity.window.decorView`, so [kayaComposeRoot]'s walk —
     * the one every other semantics read starts from — cannot see one
     * row of an open menu. `LocalView.current` INSIDE the popup's
     * content is that window's AndroidComposeView, which is the public
     * way to get a handle on it, and one line of registration turns the
     * menu into a surface the a11y reads can reach.
     */
    val menuPopupViews = ArrayList<android.view.View>()
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
    // The switcher item's SEMANTIC ICON, 0 = none
    // (docs/styling-plan.md D6). Drawn in the NavigationBarItem's icon
    // slot — which this host was passing an EMPTY lambda until D6, so
    // the bar had labels and nothing above them.
    var symbol by mutableStateOf(0L)
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
    /**
     * The SEMANTIC ICON's wire value, 0 = none (docs/styling-plan.md
     * D6). Unlike [iconBitmap] this one reaches EVERY affordance the
     * item materializes as — the promoted bar button, the overflow row,
     * a drilled row, a context row, a radio option and a top-level
     * group's header — because a concept the app named is a concept the
     * platform can draw anywhere, while an app's own bitmap is dress
     * that only the bar has room for.
     *
     * WHEN AN ITEM CARRIES BOTH, THE SYMBOL WINS. Nothing in the tree
     * sets both today, so the rule is a choice rather than a
     * compatibility fact, and the reason is uniformity: macOS puts the
     * symbol on the NSMenuItem and never draws a blob in a menu at all,
     * so "symbol first" is the reading that keeps the two backends
     * showing the same thing for the same declaration.
     */
    var symbol by mutableStateOf(0L)
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
    private const val SPEC_HASH: ULong = 0x7c7a23e2127c3801uL

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

    /**
     * The SAVE dialog's request (docs/save-plan.md D2). A SECOND REQUEST
     * AND THE SAME ANSWER: it resolves on the picker's own
     * file_dialog_result, shares its id space and its one-live-dialog
     * slot, so this constant is the only new number the breadth arms
     * carry.
     */
    private const val APPLY_PRESENT_SAVE_DIALOG = 31
    private const val APPLY_SET_BRAND = 32
    private const val APPLY_SET_TYPEFACE = 33

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

    /**
     * The three text-range records (docs/ranges-plan.md). THE OFFSETS
     * THAT ARRIVE HERE ARE UTF-16 CODE UNITS — the core converted them
     * from the guest's UTF-8 byte offsets against the same text it
     * validated them against — so nothing on this path counts
     * characters, and nothing on this path may start.
     */
    private const val APPLY_HIGHLIGHT_RANGES = 28
    private const val APPLY_SELECT_RANGE = 29
    private const val APPLY_REVEAL_RANGE = 30
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
    private const val WPROP_DIRTY = 7
    private const val WPROP_INSET = 8
    private const val SPROP_TITLE = 1
    private const val SPROP_ICON = 2
    private const val SPROP_SYMBOL = 3
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
    private const val MPROP_SYMBOL = 9
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

    /** SEMANTIC EMPHASIS (docs/styling-plan.md D4): what the widget
     * MEANS, never how it looks. destructive/prominent on buttons,
     * heading on labels; the root refuses a role on a kind it does not
     * fit, so every value that arrives here is already legal for its
     * kind. */
    private const val PROP_ROLE = 16
    private const val PROP_INSET = 17
    // The role enum's wire values (spec enum "role"). Long, because the
    // prop rides as an i64 and the render arms compare against the
    // node's own field.
    const val ROLE_DESTRUCTIVE = 1L
    const val ROLE_PROMINENT = 2L
    const val ROLE_HEADING = 3L
    // THE SEMANTIC ICON VOCABULARY (spec enum "symbol";
    // docs/styling-plan.md D6). Long, like the role values: the prop
    // rides as an i64 and the model's field is what the render arms
    // compare against.
    const val SYMBOL_ADD = 1L
    const val SYMBOL_REMOVE = 2L
    const val SYMBOL_DELETE = 3L
    const val SYMBOL_EDIT = 4L
    const val SYMBOL_DONE = 5L
    const val SYMBOL_CLOSE = 6L
    const val SYMBOL_SEARCH = 7L
    const val SYMBOL_SETTINGS = 8L
    const val SYMBOL_REFRESH = 9L
    const val SYMBOL_INFO = 10L
    const val SYMBOL_WARNING = 11L
    const val SYMBOL_BACK = 12L
    const val SYMBOL_FORWARD = 13L
    const val SYMBOL_MORE = 14L
    const val SYMBOL_COPY = 15L
    const val SYMBOL_PASTE = 16L
    const val SYMBOL_STAR = 17L
    const val SYMBOL_LOCK = 18L
    const val SYMBOL_PERSON = 19L
    const val SYMBOL_HOME = 20L

    /**
     * THE MATERIAL COLUMN: (wire value, semantic name, the glyph this
     * platform draws for it). The KayaSwiftUI sibling of this table is
     * `kayaSymbolTable`, spelled with SF names; same shape, same rule.
     *
     * The Compose column was NOT recalled. It comes from
     * styling/symbols-material-symbols.md, which enumerated
     * material-icons-core 1.7.8 and material-icons-extended 1.7.8
     * class-by-class out of the aars themselves and decided glyph
     * identity by comparing bytecode path data, not catalog pictures.
     * Three of the twenty (remove, copy, paste) are in extended; the
     * other seventeen are in core.
     *
     * WHAT NEEDS NO GATE HERE, and this is the interesting difference
     * from the SF column: there is no version floor to check. These are
     * Kotlin ImageVector builders COMPILED INTO THE APK, not platform
     * assets resolved by name at runtime, so a name that does not exist
     * is a compile error (see the import block) and a name that does
     * exist draws on every API level the app runs on. The SF column's
     * whole hazard — a spelling that resolves on the machine you develop
     * on and blanks on the deployment floor — cannot occur on this one.
     * What CAN occur is the auto-mirrored trap, and the import block is
     * where that is held.
     *
     * The semantic name is the SECOND column for the same reason macOS
     * puts it in the image's accessibility description: it is what the
     * icon MEANS, it is what a TalkBack user hears, and it is what
     * expect_menu_symbol reads back off the composed row.
     */
    val SYMBOLS: List<Triple<Long, String, ImageVector>> = listOf(
        Triple(SYMBOL_ADD, "add", Icons.Default.Add),
        Triple(SYMBOL_REMOVE, "remove", Icons.Default.Remove),
        Triple(SYMBOL_DELETE, "delete", Icons.Default.Delete),
        Triple(SYMBOL_EDIT, "edit", Icons.Default.Edit),
        Triple(SYMBOL_DONE, "done", Icons.Default.Done),
        Triple(SYMBOL_CLOSE, "close", Icons.Default.Close),
        Triple(SYMBOL_SEARCH, "search", Icons.Default.Search),
        Triple(SYMBOL_SETTINGS, "settings", Icons.Default.Settings),
        Triple(SYMBOL_REFRESH, "refresh", Icons.Default.Refresh),
        Triple(SYMBOL_INFO, "info", Icons.Default.Info),
        Triple(SYMBOL_WARNING, "warning", Icons.Default.Warning),
        Triple(SYMBOL_BACK, "back", Icons.AutoMirrored.Filled.ArrowBack),
        Triple(SYMBOL_FORWARD, "forward", Icons.AutoMirrored.Filled.ArrowForward),
        Triple(SYMBOL_MORE, "more", Icons.Default.MoreVert),
        Triple(SYMBOL_COPY, "copy", Icons.Default.ContentCopy),
        Triple(SYMBOL_PASTE, "paste", Icons.Default.ContentPaste),
        Triple(SYMBOL_STAR, "star", Icons.Default.Star),
        Triple(SYMBOL_LOCK, "lock", Icons.Default.Lock),
        Triple(SYMBOL_PERSON, "person", Icons.Default.Person),
        Triple(SYMBOL_HOME, "home", Icons.Default.Home),
    )

    /** The SEMANTIC NAME of a wire symbol value, or null for a value
     * outside the vocabulary. The root's value wall already refused
     * those at declare time, so null here means this interpreter's
     * table has drifted from the spec — which is a different failure
     * from "no symbol", and the read says so. */
    fun symbolName(value: Long): String? = SYMBOLS.firstOrNull { it.first == value }?.second

    /** The glyph for a wire symbol value. */
    fun symbolIcon(value: Long): ImageVector? = SYMBOLS.firstOrNull { it.first == value }?.third

    /** Is this string one of the twenty names — the question that tells
     * a symbol's description apart from any OTHER content description a
     * row might carry (an icon blob's, whose description is the item's
     * label). The read needs it to avoid reporting "Share" as though it
     * were a symbol nobody has heard of. */
    fun isSymbolName(text: String): Boolean = SYMBOLS.any { it.second == text }

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
        // The composition root, and the ONE place this backend's theme is
        // installed — every scene, every dialog and every dropdown is a
        // sub-composition of this one, so they all read the same scheme
        // (see KayaTheme).
        activity.setContent { KayaTheme { KayaRoot() } }
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
            // SET_TYPEFACE CARRIES A BLOB TOO — the font file's bytes,
            // which ride the same batch-local table as an image's and
            // die with the batch just as fast (docs/styling-plan.md
            // Slice 2b: "a font is one vector file whose bytes arrive in
            // the first build transaction"). Without this arm the handle
            // resolves to null on the UI thread and the app silently
            // falls back to the NAME, which is the miss class this whole
            // slice is about.
            //
            // The slot sits after two variable-length fields, so the
            // walk is the record's own — skip mask+stamp, skip the
            // family, skip the pair list, and the font is what is left.
            // Absolute reads, so the record cursor is untouched.
            if (kind == APPLY_SET_TYPEFACE) {
                var at = start + 8 + 8
                fun skipAt() {
                    val len = b.getInt(at + 4)
                    at += 8 + len
                    if (at % 8 != 0) at += 8 - at % 8
                }
                skipAt() // the default family
                val pairs = b.getInt(at)
                at += 8
                repeat(pairs) { skipAt() } // tag, family, tag, family …
                if (b.getInt(at) == VALUE_BLOB) {
                    val handle = b.getLong(at + 8)
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
                        PROP_ROLE ->
                            KayaSceneModel.nodes[id]!!.role = readI64(b)
                        PROP_INSET ->
                            KayaSceneModel.nodes[id]!!.inset = readF64(b)
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
                        // The unsaved-work mark (docs/dirty-plan.md D4).
                        // It APPLIES and it lowers to NO CHROME, which
                        // is not the same as being ignored: the value
                        // lands in the model, expect_dirty reads it
                        // back, and a prop dropped on the wire fails
                        // that assertion. What Android has no room for
                        // is the CHROME — no title bar, no close
                        // button, and the platform's own unsaved-state
                        // affordance is the predictive-back
                        // confirmation, which is veto_close and
                        // navigation's business, not this prop's.
                        // Synthesizing a marker here would express what
                        // no native app expresses.
                        //
                        // NOT INTO THE TITLE, on any platform. The task
                        // label stays exactly the string the app
                        // declared (D1).
                        WPROP_DIRTY -> KayaSceneModel.windowDirty = readBool(b)
                        WPROP_INSET -> KayaSceneModel.windowInset = readF64(b)
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
                APPLY_HIGHLIGHT_RANGES -> {
                    // { u64 widget_id; u32 count; u32 reserved } then a
                    // Values block of 2*count I64s, read IN PAIRS —
                    // start then end — already in UTF-16 code units.
                    //
                    // RECORDED WITH THE TEXT IT WAS DECLARED AGAINST,
                    // which is the whole of D2's clear-on-edit: the
                    // field's text at THIS moment is the text the core
                    // validated these offsets against, because a text
                    // write earlier in this same batch has already
                    // landed on the field (kayaWriteText writes the
                    // TextFieldState synchronously, and the core reads
                    // the batch's own writes for exactly this reason).
                    val hid = b.long
                    val hcount = b.int
                    b.int // reserved
                    // The Values block's own header, exactly as the copy
                    // record's is read: a slot count and a pad before
                    // the first value. It is 2*count here and reading it
                    // as a value's type tag is how this arm failed the
                    // first time (`expected an i64 value, got type 6`,
                    // which was three ranges' six slots).
                    b.int // slots
                    b.int // reserved
                    val declared = ArrayList<KayaRange>(hcount)
                    repeat(hcount) {
                        val from = readI64(b).toInt()
                        val to = readI64(b).toInt()
                        declared.add(KayaRange(from, to))
                    }
                    val hnode = KayaSceneModel.nodes[hid]
                        ?: error("kaya: highlight_ranges on an unknown widget $hid")
                    hnode.highlights = declared
                    hnode.highlightsFor = hnode.textState.text.toString()
                }
                APPLY_SELECT_RANGE -> {
                    // { u64 widget_id; u64 start; u64 stop }, UTF-16.
                    //
                    // PERFORMED WHERE IT IS DECODED, unlike the reveal
                    // below: a selection needs no layout, this arm
                    // already runs on the UI thread, and any text write
                    // of the same transaction has already landed — which
                    // is the order this has to happen in, because kaya's
                    // own write places the cursor at the end
                    // (setTextAndPlaceCursorAtEnd) and would otherwise
                    // undo the selection it was asked for.
                    val sid = b.long
                    val sstart = b.long.toInt()
                    val sstop = b.long.toInt()
                    val snode = KayaSceneModel.nodes[sid]
                        ?: error("kaya: select_range on an unknown widget $sid")
                    kayaSelectRange(snode, KayaRange(sstart, sstop))
                }
                APPLY_REVEAL_RANGE -> {
                    // { u64 widget_id; u64 start; u64 stop }, UTF-16.
                    // A REQUEST and not an action: scrolling a range
                    // into view needs the field's own TextLayoutResult,
                    // which exists only after a layout pass, so the
                    // effect keyed on the sequence number performs it.
                    val rid = b.long
                    val rstart = b.long.toInt()
                    val rstop = b.long.toInt()
                    val rnode = KayaSceneModel.nodes[rid]
                        ?: error("kaya: reveal_range on an unknown widget $rid")
                    rnode.revealRequest = KayaRange(rstart, rstop)
                    rnode.revealSeq += 1
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
                APPLY_PRESENT_SAVE_DIALOG -> {
                    // A STR AND THEN A LIST, which is a body shape no
                    // other apply record has: the suggested name is a
                    // Value (tag, length, bytes, self-padded to 8) and
                    // the filter pairs follow, so the count below is
                    // read from wherever the NAME ended rather than from
                    // a fixed offset. A decoder that assumed the
                    // picker's fixed header would read the name's
                    // padding as the count and build a filter list of
                    // garbage length.
                    b.long // window: 0, the one surface on this host
                    val saveDialog = b.long
                    val suggested = readString(b)
                    val saveFilterValues = b.int
                    b.int // pad
                    val saveExtensions = mutableListOf<String>()
                    repeat(saveFilterValues / 2) {
                        readString(b) // the label, an affordance an intent has nowhere to put
                        readString(b).split(" ").forEach { ext ->
                            val trimmed = ext.trim('.')
                            if (trimmed.isNotEmpty()) saveExtensions.add(trimmed)
                        }
                    }
                    kayaPresentSaveDialog(saveDialog, suggested, saveExtensions)
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
                        // The SEMANTIC ICON: drawn in the bar item's
                        // icon slot (docs/styling-plan.md D6).
                        SPROP_SYMBOL -> section.symbol = readI64(b)
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
                        // The SEMANTIC ICON: drawn on every affordance
                        // this item materializes as, and read back off
                        // the composed row by expect_menu_symbol
                        // (docs/styling-plan.md D6).
                        MPROP_SYMBOL -> item.symbol = readI64(b)
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
                APPLY_SET_BRAND ->
                    // ELEVEN packed sRGB words in the wire's fixed
                    // order: seed, light's five (fill, on_fill,
                    // standalone, hover, pressed), dark's five. THIS
                    // BACKEND READS THE FIRST ONE AND NOTHING ELSE, and
                    // that is the design rather than laziness
                    // (docs/styling-plan.md D1): every other backend
                    // applies the core's derived VALUES because its
                    // platform has no derivation of its own, while
                    // Material's whole colour system is "one seed hex,
                    // one deterministic role scheme" — so kaya hands
                    // Material the seed and defers, exactly as it
                    // defers to libadwaita's clamp on GTK. The other
                    // ten words are skipped by the record cursor at the
                    // bottom of this loop.
                    KayaSceneModel.brandSeed = b.int
                APPLY_SET_TYPEFACE -> {
                    // { u32 mask; u32 platform } then the default
                    // family, the per-platform pairs, and the font slot
                    // — the request UNRESOLVED, because resolving it is
                    // THIS side's job: a lowering is its platform, which
                    // is why the pairs travel at all
                    // (docs/styling-plan.md Slice 2b).
                    val mask = b.int
                    // WHICH ROW IS MINE, stamped by the core: the tag of
                    // the platform it was compiled for. This file keeps
                    // NO copy of the platform vocabulary — a private
                    // copy here and another in Swift is the CLIP_*
                    // mirror trap, a drifted value picking the wrong row
                    // with nothing pinning either side.
                    val mine = b.int
                    val defaultFamily = readString(b)
                    val pairCount = b.int
                    b.int // reserved
                    var picked: String? = null
                    repeat(pairCount / 2) {
                        val tag = readI64(b)
                        val family = readString(b)
                        // FIRST MATCH WINS, and the root refuses a
                        // repeated platform so there is never a second.
                        if (tag.toInt() == mine && picked == null) {
                            picked = family
                        }
                    }
                    // The font slot is always written; the mask says
                    // whether it means anything.
                    val fontBytes =
                        if (mask and 1 != 0) {
                            blobs[readBlobHandle(b)]
                        } else {
                            skipValue(b)
                            null
                        }
                    kayaApplyTypeface(
                        mountedActivity, defaultFamily, picked, fontBytes)
                }
                else -> error("kaya: unknown apply record kind $kind")
            }
            b.position(start + size)
        }
        // THE APP ANSWERED. An action verb waits for this before it
        // returns (see kayaAwaitAnswer) — written last, so the count
        // moves only once everything in the batch has landed.
        kayaBatches += 1
    }

    /**
     * AN ACTION RETURNS ONCE THE APP HAS ANSWERED IT.
     *
     * `click` emits an occurrence and the guest answers on its own
     * thread, so without this the next step runs against the scene as it
     * was BEFORE the click. Every `expect` is a bounded retry, which
     * hides that completely — until the assertion is one that was
     * ALREADY TRUE, and then the retry passes on its first sample and
     * the step verified nothing.
     *
     * Measured 2026-08-06, and it is why this exists: the ranges scene's
     * last step asserts that a select_range arriving mid-composition did
     * NOT move the caret (D4). The caret is already there when the click
     * is sent, so with the refusal DELETED the leg still passed — the
     * read landed before the app's answer did. A guard nobody has
     * watched fail is worse than none, and this is what made that one
     * watchable.
     *
     * BOUNDED AND SILENT. Some actions legitimately produce no batch at
     * all (a click the app ignores), so a timeout here is not a verdict
     * — it is the normal end of the wait for those, and the following
     * assertion is what reports anything wrong.
     */
    private fun kayaAwaitAnswer(seen: Int) {
        var last = seen
        var quiet = 0
        repeat(60) {
            val now = kayaBatches
            when {
                now != last -> { last = now; quiet = 0 }
                // A BATCH IS NOT ENOUGH, IT HAS TO BE THE LAST ONE. The
                // app may still have been answering something that
                // happened BEFORE this action — the ranges scene's
                // `compose` provokes a text_changed whose reply lands
                // right about when the next click is sent — and
                // returning on that batch leaves the action's own answer
                // in flight, which is the vacuous pass all over again.
                // Wait for the batches to stop instead of for one to
                // arrive.
                now != seen -> { quiet += 1; if (quiet >= 3) return }
            }
            Thread.sleep(5)
        }
    }

    /** The app has nothing left to say. Called BEFORE an action so the
     * wait after it cannot mistake the previous answer for this one. */
    private fun kayaAwaitQuiet() {
        var last = kayaBatches
        var quiet = 0
        repeat(40) {
            val now = kayaBatches
            if (now != last) { last = now; quiet = 0 } else { quiet += 1; if (quiet >= 3) return }
            Thread.sleep(5)
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
        // CONTRACT POINT 3: TYPING APPENDS. Keys arriving at a non-empty
        // selection REPLACE what is there, so the same script would
        // append on a lane whose caret sits at the end and replace on
        // one whose does — and one script is compared byte-for-byte
        // across all five (invariant 6). Both Swift arms do exactly
        // this, in as many words; this backend never needed it because
        // nothing before text ranges could leave a selection in a field,
        // and `select_range` now can.
        //
        // Before the keys and not between them: a selection change
        // mid-run would break the field's own edit coalescing, which is
        // the granularity the delegated undo tier is made of.
        //
        // SKIPPED WHEN THE CARET IS ALREADY THERE, which is every scene
        // that existed before this one: kaya's own write places the
        // cursor at the end, so an unconditional edit would spend a
        // state commit per `type` on eleven legs to change nothing.
        onUi(activity) {
            kayaFocusedTextNode()?.let { node ->
                val end = node.textState.text.length
                val at = node.textState.selection
                if (at.start != end || at.end != end) {
                    node.textState.edit {
                        selection = androidx.compose.ui.text.TextRange(end, end)
                    }
                }
            }
        }
        // The text before the first key, so the settle below can tell
        // "landed" from "has not started yet".
        val before = onUi(activity) { kayaFocusedTextNode()?.text }
        val map = android.view.KeyCharacterMap.load(
            android.view.KeyCharacterMap.VIRTUAL_KEYBOARD)
        for (c in text) {
            val events = map.getEvents(charArrayOf(c))
                ?: return "type: this keyboard layout cannot generate ${c.code} ($c)"
            // A KEY NOTHING CONSUMED WAS NOT TYPED, so it is sent again.
            //
            // Measured 2026-08-06, two runs in six: the FIRST key-down of
            // a leg came back `handled=false` and the field's text did
            // not move — the focus had been requested and the model
            // reported it, but the field was not yet taking keys.
            // Everything before this scene hid it, because the step after
            // a `type` is normally an `expect` and an expect POLLS: the
            // remaining characters landed inside the retry window and the
            // leg passed. `compose` is an ACTION that inserts at the end
            // of the CURRENT text, so a swallowed keystroke moved every
            // offset after it and the failure surfaced two verbs later
            // as an off-by-one caret.
            //
            // The signal is the FIELD'S OWN LENGTH rather than
            // dispatchKeyEvent's return, because "somebody consumed this"
            // and "the text I am typing into changed" are different
            // claims and only the second is the one point 4 makes. Every
            // character this verb may send is printable ASCII (point 6)
            // and the caret was collapsed above, so each one grows the
            // text by exactly one — there is no character for which
            // "nothing moved" is a correct outcome.
            var tries = 0
            while (true) {
                val was = onUi(activity) { kayaFocusedTextNode()?.textState?.text?.length }
                // ONE UI-THREAD HOP PER CHARACTER, so a runloop turn
                // passes between them exactly as it does between a
                // user's keystrokes.
                onUi(activity) {
                    val now = android.os.SystemClock.uptimeMillis()
                    for (e in events) {
                        // Rebuilt rather than replayed: the events a
                        // KeyCharacterMap hands back carry zeroed
                        // timestamps and no input source, and a key event
                        // with no source is not the thing a keyboard
                        // delivers.
                        activity.dispatchKeyEvent(
                            KeyEvent(
                                now, now, e.action, e.keyCode, 0, e.metaState,
                                android.view.KeyCharacterMap.VIRTUAL_KEYBOARD, e.scanCode, 0,
                                android.view.InputDevice.SOURCE_KEYBOARD,
                            ),
                        )
                    }
                }
                // Nothing focused is a legitimate state under point 2 —
                // the keys go where the platform sends them and a
                // following assertion reports the mismatch — so there is
                // nothing to confirm and nothing to retry.
                if (was == null || kayaKeyLanded(activity, was)) break
                tries += 1
                if (tries >= 10) {
                    Log.e(
                        "kaya",
                        "KAYA_UNDO_TRACE: the keystroke '$c' was dispatched 10 times and " +
                            "the focused field's text never moved — either nothing is " +
                            "taking keys or this key does not insert"
                    )
                    break
                }
            }
        }
        kayaSettleTypedText(activity, before)
        return null
    }

    /** Did the last dispatched key reach the focused field? Bounded, and
     * free in the common case: the field applies a key on the turn it is
     * dispatched, so the first sample already differs. */
    private fun kayaKeyLanded(activity: ComponentActivity, was: Int): Boolean {
        repeat(20) {
            val now = onUi(activity) { kayaFocusedTextNode()?.textState?.text?.length }
            if (now != was) return true
            Thread.sleep(5)
        }
        return false
    }

    /**
     * Point 4's wait: the typing has landed when this backend's MODEL has
     * caught up with the WIDGET, because that is one turn past the
     * emission — the observer in KayaTextField assigns `node.text` and
     * emits in the same step, so an agreeing pair means the app has heard
     * every keystroke.
     *
     * AND THEN HELD STILL, which the first version of this did not
     * require and which cost a flaky leg. "Model equals widget" is true
     * the instant the collector catches up with the FIRST keystroke, so
     * a two-character `type` could return with one character delivered
     * and one still in flight. Every scene before text ranges hid it:
     * the step after a `type` is normally an `expect`, and an expect
     * POLLS, so the late keystroke arrived inside the retry window and
     * nothing ever failed. `compose` is an ACTION with no retry that
     * inserts at the end of the current text, so a keystroke still in
     * flight moved every offset after it — measured on this backend
     * 2026-08-06, one run in three.
     *
     * MOVED THEN STABLE, the shape both Swift arms already use: wait for
     * the text to change at all, then for two consecutive samples that
     * agree. A stability window cannot be replaced by a longer single
     * wait, because the thing being waited for is an ABSENCE of further
     * changes.
     *
     * A TIMEOUT IS NOT A VERDICT. Nothing focused is legitimate under the
     * contract (point 2), and a following assertion is what reports the
     * mismatch; this says so on the record and returns.
     */
    private fun kayaSettleTypedText(activity: ComponentActivity, before: String?) {
        var last: String? = null
        var stable = 0
        var moved = false
        repeat(200) {
            val now = onUi(activity) {
                val node = kayaFocusedTextNode() ?: return@onUi null
                if (node.text != kayaLf(node.textState.text.toString())) return@onUi null
                node.text
            }
            // Nothing focused is a legitimate state; so is a widget the
            // model has not caught up with yet. Both read as "not settled".
            if (now != null) {
                moved = moved || now != before
                if (moved) {
                    stable = if (now == last) stable + 1 else 0
                    if (stable >= 2) return
                }
                last = now
            }
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

    /// What the live SAVE panel is really showing: its directory and the
    /// name in its name field, null when none is up. The picker's reader
    /// one dialog over — and the service is what keeps the two from
    /// seeing each other's panel, since DocumentsUI serves both.
    private fun kayaSaveDialogState(): Pair<String, String>? =
        KayaHarnessAccessibility.live?.saveState()

    /// The save panel's state, WAITED FOR. `expect_save_dialog` gets the
    /// generic 5s retry like every other expect, but the two ACTIONS do
    /// not — and typing into a panel that has not presented yet does
    /// nothing at all, after which the leg saves under the SUGGESTED name
    /// with every byte assertion downstream still green. So the wait
    /// lives here, where both actions reach it.
    ///
    /// Bounded by the picker's own gone-wait constants rather than a new
    /// pair: this is the same DocumentsUI hand-off, from the other side.
    private fun kayaAwaitSaveDialogState(): Pair<String, String>? {
        for (i in 0 until SAVE_PANEL_TRIES) {
            kayaSaveDialogState()?.let { return it }
            Thread.sleep(SAVE_PANEL_SETTLE_MS)
        }
        return kayaSaveDialogState()
    }

    /// How long a save panel is given to present, and how long each look
    /// costs. DocumentsUI is another app being started, so this is a
    /// process launch and not a frame.
    private const val SAVE_PANEL_TRIES = 25
    private const val SAVE_PANEL_SETTLE_MS = 200L

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
        val names = uris.map { displayName(activity, it) }
        KayaPresent.emitFileDialogResult(
            dialog,
            uris.map { it.toString() }.toTypedArray(),
            names.toTypedArray(),
        )
    }

    /// The DISPLAY NAME, not the last URI segment: the segment is the
    /// provider's document id, which is a path fragment on the
    /// ExternalStorage provider and an opaque key on others.
    ///
    /// A SAVED DOCUMENT NEEDS THIS MORE THAN A PICKED ONE DOES. SAF
    /// appends an extension matching the request's mime type when it
    /// creates the file, and it renames on collision — `picked.txt`
    /// becomes `picked (1).txt` with no prompt (measured). So the name
    /// the user typed and the name the document HAS are routinely
    /// different, and only the provider knows which is which.
    private fun displayName(activity: ComponentActivity, uri: Uri): String {
        var name = ""
        try {
            activity.contentResolver.query(uri, null, null, null, null)?.use { c ->
                val i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (c.moveToFirst() && i >= 0) name = c.getString(i) ?: ""
            }
        } catch (e: Exception) {
            Log.w("kaya", "kaya: reading the document's name failed: $e")
        }
        return name
    }

    /**
     * Present the platform's REAL save dialog and answer exactly once.
     *
     * `ACTION_CREATE_DOCUMENT`, which is the picker's own hand-off to
     * DocumentsUI with the mode flipped — the same registry, the same
     * result path, the same accessibility service reading the same
     * breadcrumb, and the same live slot, because one dialog per process
     * is a rule about the USER's attention and not about a kind.
     *
     * IT ANSWERS WITH A DOCUMENT THAT ALREADY EXISTS, which is where
     * this platform and the desktops disagree and where docs/save-plan.md
     * D1 says the core absorbs it: DocumentsUI creates the file when SAVE
     * is pressed, so the first `wt` open reports size 0 and the guest's
     * write lands (measured, scratchpad/save-probe-android.md). mac,
     * linux and windows hand back a name for a file nobody has made, and
     * the core's `SaveDestination` creates it there. Nothing here needs
     * to know that; the entry this answers on is what carries the
     * difference.
     *
     * THE NAME IS A SUGGESTION AND THE PLATFORM MAY NOT KEEP IT — SAF
     * appends an extension for the mime type and renames on collision
     * rather than prompting. That is why the frozen scene asserts the
     * BYTES a handle reads back and never a file's name
     * (scratchpad/save-depth.md §8).
     */
    private fun kayaPresentSaveDialog(
        dialog: Long,
        suggestedName: String,
        extensions: List<String>,
    ) {
        val activity = mountedActivity ?: error("kaya: a save dialog with no mounted activity")
        check(kayaLivePickerDialog == null) {
            "kaya: a second file dialog while $kayaLivePickerDialog is still up"
        }
        // ONE TYPE, NOT A LIST. The picker's EXTRA_MIME_TYPES filters what
        // is SHOWN; a create request's type is what the document will BE,
        // so a second one has nothing to mean. `*/*` when the guest named
        // no filter, which is also the case the save scene sends: it maps
        // to no extension, so SAF appends none.
        val mimes = extensions.mapNotNull {
            MimeTypeMap.getSingleton().getMimeTypeFromExtension(it.lowercase())
        }
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType(mimes.firstOrNull() ?: "*/*")
            .putExtra(Intent.EXTRA_TITLE, suggestedName)
            // WRITE as well as read, exactly as the picker asks: a save
            // destination the guest cannot write to is not a destination,
            // and the grant is decided HERE — asking later is not
            // possible.
            .addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        kayaPendingPickerDirectory?.let {
            intent.putExtra(DocumentsContract.EXTRA_INITIAL_URI, initialUri(it))
        }

        kayaLivePickerDialog = dialog
        kayaLivePickerLauncher = activity.activityResultRegistry.register(
            "kaya-save-dialog-$dialog",
            ActivityResultContracts.StartActivityForResult(),
        ) { result ->
            kayaLivePickerDialog = null
            kayaLivePickerLauncher?.unregister()
            kayaLivePickerLauncher = null
            kayaAnswerSaveDialog(activity, dialog, result.data)
        }
        kayaLivePickerLauncher?.launch(intent)
    }

    /// The created document, or NOTHING for cancel — and nothing is a
    /// null locator rather than an empty array, because the save entry
    /// takes ONE locator. A cancelled panel arrives here with a null
    /// Intent, the same shape the picker's cancel has.
    ///
    /// ANSWERED ON `emitSaveDialogResult` AND NOT THE PICKER'S ENTRY,
    /// even though this platform's two sources happen to coincide: the
    /// core decides what a destination IS from which entry it arrives on
    /// (`register_saved` vs `register_picked`), so a backend that
    /// answered a save request on the picker's entry would be asking for
    /// the picker's semantics and getting away with it here by luck.
    private fun kayaAnswerSaveDialog(
        activity: ComponentActivity,
        dialog: Long,
        data: Intent?,
    ) {
        val uri = data?.data
        if (uri == null) {
            KayaPresent.emitSaveDialogResult(dialog, null, null)
            return
        }
        KayaPresent.emitSaveDialogResult(dialog, uri.toString(), displayName(activity, uri))
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
     * and reaching for it would still be the wrong fix — a cut is the
     * platform's own edit and its own undo entry, not a read plus a
     * write kaya assembles. It is NOT wrong for the reason this comment
     * used to give: `edit {}` was measured
     * (range-probe-android.md §2) to leave `canUndo` true when it
     * changes only the SELECTION, so D7's clear is keyed on the text
     * moving and not on `edit {}` being called — which is what let
     * `select_range` be lowered on that call.) What Compose does publish is
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

    /**
     * THE TEXT-RANGE READS, all three, off the platform.
     *
     * The a11y id is how a leg finds a control in the semantics tree, so
     * a textarea with no `a11y_id` cannot be asserted about — the same
     * requirement every other backend's range reads make, and the ranges
     * guest authors one for exactly this reason.
     *
     * MAIN THREAD ONLY, like every other read in this backend: Compose
     * owns its semantics tree from the thread that lays out, and reading
     * it from the harness thread is a hard crash rather than a wrong
     * answer (kayaAx's own note).
     */
    private fun kayaSelectionRead(activity: ComponentActivity, spec: String): String {
        val node = kayaTextTarget(spec) ?: return "<no such target>"
        if (node.a11yId.isEmpty()) return "<no a11y_id authored on this widget>"
        val semantics = kayaSemanticsByTag(activity, node.a11yId)
            ?: return "<not in the semantics tree>"
        // THE FIELD'S OWN TEXT, as the platform publishes it — the same
        // property TalkBack reads a field's content from. Slicing THIS
        // with the range the platform is holding is what makes the
        // covered half free of arithmetic.
        val text = kayaSemanticsValue(semantics, SemanticsProperties.EditableText)?.text
            ?: return "<no editable text>"
        val selection = kayaSemanticsValue(semantics, SemanticsProperties.TextSelectionRange)
            ?: return "<no selection>"
        return kayaRangeSpelling(text, listOf(KayaRange(selection.start, selection.end)))
    }

    /**
     * THE HIGHLIGHT READ, AND ITS PAINT WITNESS.
     *
     * The record alone is not enough and this arm proved it rather than
     * assuming it: deleting the `drawPath` call and leaving everything
     * else — the apply arm, the staleness compare, the record — left the
     * leg GREEN with nothing decorated on screen (flip proof 1, watched
     * failing to fail on 2026-08-06). That is the same silent shape the
     * android probe measured from the other side: pushing an
     * `AnnotatedString` into the state compiles clean, stores a plain
     * String and paints zero pixels. A read that cannot tell those apart
     * is a gate satisfiable without exercising the real thing.
     *
     * So every range whose box is ON SCREEN is photographed:
     * `PixelCopy` reads the field's own viewport out of the window —
     * in process, no adb, no screenshot tool, API 24 against kaya's
     * floor of 26 — and the range's rectangle must actually contain the
     * decoration. A range scrolled out of the viewport cannot be
     * witnessed by anything on screen and is reported on the record
     * alone; the scene keeps that from being a loophole, because at
     * every `expect_highlights` with a non-empty set at least one match
     * is inside the viewport.
     *
     * THE PREDICATE IS COMPUTED FROM THE COLOURS IN PLAY, not guessed at
     * and not hard-coded. It used to be "much more red and green than
     * blue", which is what the decoration alone blends to (#F4E689: the
     * highlight over this field's #E6E0E9 container, and exactly what
     * 0x8CFFEB3B over that background computes to). That predicate is
     * BLIND TO THE ONE RANGE EVERY FIND BAR HAS — the current match,
     * which is highlighted AND selected. The platform paints its
     * selection wash on top of this layer, so the pixel is the highlight
     * seen THROUGH the wash, measured 2026-08-10 on the editor scene as
     * #ACC0B4 (r-b = -8, g-b = 12: both clauses fail) — and the leg
     * accused the lowering of painting nothing.
     *
     * So the witness composites what it expects instead: the field's own
     * undecorated background is SAMPLED from the photograph, the
     * decoration is that background under KAYA_HIGHLIGHT_COLOR, and the
     * washed form is the decoration under the platform's own selection
     * background (read from the composition, not assumed — this app wraps
     * no MaterialTheme, so foundation's default 0xFF4286F4 at 0.4 is what
     * actually paints). Both computed values reproduced the measured
     * pixels to within one level. A pixel matching either is the
     * decoration; nothing else the field paints is within reach of them —
     * the wash over the BARE container computes to #A4BCED, 57 levels of
     * blue away from #ACC0B4, so "selected but not highlighted" is still
     * refused, which is the whole point of photographing at all.
     *
     * AND THE PHOTOGRAPH IS AIMED IN THE RIGHT SPACE. `PixelCopy` takes
     * its srcRect in the window's SURFACE space; `boundsInWindow()`
     * answers in WINDOW space; those are the same numbers only while
     * nothing has panned the window. Measured on the same leg with the
     * soft keyboard up, `decorView.getLocationInWindow()` was (0, -199)
     * and the witness photographed 199px below the field — a flat block
     * of the app's background, which it then reported as "the lowering
     * painted nothing". A read that cannot see the thing must say so
     * (`offwindow@`) and never accuse the paint.
     *
     * NOT ON THE UI THREAD: `PixelCopy` answers on a main-thread
     * callback, so waiting for it there would deadlock. The semantics
     * and geometry are gathered in one UI hop, the photograph is taken
     * from the harness thread, and the spelling is assembled after.
     */
    private fun kayaHighlightRead(activity: ComponentActivity, spec: String): String {
        val gathered = onUi(activity) { kayaGatherHighlights(activity, spec) }
        if (gathered.trouble != null) return gathered.trouble
        val (unpainted, offwindow) = kayaUnwitnessed(activity, gathered)
        return kayaRangeSpelling(gathered.text, gathered.ranges, unpainted, offwindow)
    }

    /** Everything the witness needs, read in ONE main-thread hop: the
     * platform's text, what the draw scope recorded, the viewport's
     * rectangle in the window, each range's rectangle inside it, the
     * window-to-surface offset the photograph is aimed with, and the
     * selection wash the platform paints over this layer. */
    private class KayaHighlights(
        val trouble: String? = null,
        val text: String = "",
        val ranges: List<KayaRange> = emptyList(),
        val viewport: android.graphics.Rect? = null,
        // Per range, its rectangle in WINDOW coordinates, or null when
        // the range is scrolled out of the viewport.
        val onScreen: List<android.graphics.Rect?> = emptyList(),
        // WINDOW space plus this is SURFACE space — `decorView`'s own
        // location in the window, which is (0,0) until something pans
        // the window and (0,-199) when the soft keyboard has. Read here
        // because it is a View read and this is the UI hop.
        val surfaceOffset: android.graphics.Point = android.graphics.Point(0, 0),
        // The window's drawn area, surface space: nothing outside it is
        // in the app's own rendering at all.
        val surfaceSize: android.graphics.Point = android.graphics.Point(0, 0),
        // The platform's selection background, ARGB, as the composition
        // resolved it — the wash this layer is painted under.
        val wash: Int = 0,
    )

    private fun kayaGatherHighlights(
        activity: ComponentActivity,
        spec: String,
    ): KayaHighlights {
        val node = kayaTextTarget(spec) ?: return KayaHighlights("<no such target>")
        if (node.a11yId.isEmpty()) {
            return KayaHighlights("<no a11y_id authored on this widget>")
        }
        val semantics = kayaSemanticsByTag(activity, node.a11yId)
            ?: return KayaHighlights("<not in the semantics tree>")
        val text = kayaSemanticsValue(semantics, SemanticsProperties.EditableText)?.text
            ?: return KayaHighlights("<no editable text>")
        val ranges = kayaPaintedRanges[node.id] ?: emptyList()
        val box = kayaTextBoxes[node.id]
        val layout = kayaTextLayouts[node.id]?.invoke()
        val decor = activity.window.decorView
        val loc = IntArray(2)
        decor.getLocationInWindow(loc)
        val offset = android.graphics.Point(loc[0], loc[1])
        val surface = android.graphics.Point(decor.width, decor.height)
        val wash = kayaSelectionWash[node.id] ?: 0
        if (box == null || layout == null || ranges.isEmpty()) {
            return KayaHighlights(text = text, ranges = ranges)
        }
        val scroll = node.scrollState.value
        val rects = ranges.map { r ->
            if (r.start < 0 || r.start > r.stop || r.stop > text.length) return@map null
            val bounds = layout.getPathForRange(r.start, r.stop).getBounds()
            // Text coordinates -> the scrolled viewport -> the window.
            val top = (bounds.top - scroll).toInt() + box.top
            val bottom = (bounds.bottom - scroll).toInt() + box.top
            val clipped = android.graphics.Rect(
                bounds.left.toInt() + box.left,
                maxOf(top, box.top),
                bounds.right.toInt() + box.left,
                minOf(bottom, box.bottom),
            )
            if (clipped.width() <= 0 || clipped.height() <= 0) null else clipped
        }
        return KayaHighlights(
            text = text, ranges = ranges, viewport = box, onScreen = rects,
            surfaceOffset = offset, surfaceSize = surface, wash = wash)
    }

    /** The photograph, with the space it was taken in carried beside it
     * so a caller reads pixels by the WINDOW coordinate it has and never
     * by an offset it computed itself — the whole defect this class
     * exists to make unspellable. */
    private class KayaShot(
        val bitmap: android.graphics.Bitmap,
        // Surface coordinates of the bitmap's (0,0).
        val originX: Int,
        val originY: Int,
        // Window coordinates plus this is surface coordinates.
        val offsetX: Int,
        val offsetY: Int,
    ) {
        /** The pixel at a WINDOW coordinate, or null when the window's
         * own surface does not hold it. */
        fun at(wx: Int, wy: Int): Int? {
            val x = wx + offsetX - originX
            val y = wy + offsetY - originY
            if (x < 0 || y < 0 || x >= bitmap.width || y >= bitmap.height) return null
            return bitmap.getPixel(x, y)
        }
    }

    /** The ranges that are on screen and are NOT actually decorated
     * there, and the ranges the window itself does not hold — empty when
     * everything the record claims is really painted. */
    private fun kayaUnwitnessed(
        activity: ComponentActivity,
        read: KayaHighlights,
    ): Pair<Set<KayaRange>, Set<KayaRange>> {
        val none = Pair(emptySet<KayaRange>(), emptySet<KayaRange>())
        val box = read.viewport ?: return none
        if (read.onScreen.all { it == null }) return none
        val shot = kayaPhotograph(activity, box, read) ?: return none
        // THE FIELD'S OWN BACKGROUND, sampled rather than assumed: what
        // this field paints where nothing is decorated. Sampling is what
        // makes the two expected colours below follow the theme (a dark
        // scheme moves every one of them) instead of pinning the witness
        // to one palette.
        val base = kayaModalColour(shot, box, read.onScreen)
        val deco = kayaOver(KAYA_HIGHLIGHT_COLOR.toArgb(), base)
        val washed = kayaOver(read.wash, deco)
        // AND WHAT THE FIELD PAINTS WITH NO DECORATION AT ALL, both
        // ways, because a colour the witness cannot TELL APART from that
        // is a colour it must not accept. This is the clause the flip
        // proof paid for: with the highlight's alpha set to zero the
        // decoration composites to the background exactly, every
        // background pixel matched the expectation, and the leg passed
        // with nothing on screen — the same false green this whole
        // witness exists to refuse (watched failing to fail 2026-08-10,
        // and again 2026-08-06 for the deleted drawPath). An invisible
        // decoration is an undecorated range, and it is reported as one.
        val bare = kayaOver(read.wash, base)
        val decoShows = !kayaSameColour(deco, base)
        val washedShows = !kayaSameColour(washed, bare)
        val missing = HashSet<KayaRange>()
        val offwindow = HashSet<KayaRange>()
        for ((i, rect) in read.onScreen.withIndex()) {
            if (rect == null) continue
            var found = false
            var seen = false
            var y = rect.top
            while (y < rect.bottom && !found) {
                var x = rect.left
                while (x < rect.right) {
                    val p = shot.at(x, y)
                    if (p != null) {
                        seen = true
                        if ((decoShows && kayaSameColour(p, deco)) ||
                            (washedShows && kayaSameColour(p, washed))) {
                            found = true
                            break
                        }
                    }
                    x += 1
                }
                y += 1
            }
            // NOT SEEN IS NOT THE SAME AS NOT PAINTED, and conflating
            // them is how this read once accused the lowering of a defect
            // the window manager had committed.
            if (!seen) offwindow.add(read.ranges[i])
            else if (!found) missing.add(read.ranges[i])
        }
        shot.bitmap.recycle()
        return Pair(missing, offwindow)
    }

    /** The commonest colour the photograph holds OUTSIDE every declared
     * range — the field's own undecorated background. Falls back to the
     * commonest colour anywhere in it when every pixel is inside some
     * range, which no scene does today and which would otherwise sample
     * the decoration as if it were the background. */
    private fun kayaModalColour(
        shot: KayaShot,
        box: android.graphics.Rect,
        rects: List<android.graphics.Rect?>,
    ): Int {
        val outside = HashMap<Int, Int>()
        val everywhere = HashMap<Int, Int>()
        var y = box.top
        while (y < box.bottom) {
            var x = box.left
            while (x < box.right) {
                val p = shot.at(x, y)
                if (p != null) {
                    everywhere[p] = (everywhere[p] ?: 0) + 1
                    if (rects.none { it != null && it.contains(x, y) }) {
                        outside[p] = (outside[p] ?: 0) + 1
                    }
                }
                x += 1
            }
            y += 1
        }
        val pick = if (outside.isNotEmpty()) outside else everywhere
        return pick.maxByOrNull { it.value }?.key ?: 0
    }

    /** `src` composited over an opaque `dst`, the platform's own alpha
     * blend — the arithmetic that turns kaya's declared colours into the
     * pixel the photograph must contain. */
    private fun kayaOver(src: Int, dst: Int): Int {
        val a = ((src ushr 24) and 0xFF) / 255.0
        if (a <= 0.0) return dst
        fun mix(shift: Int): Int {
            val s = (src shr shift) and 0xFF
            val d = (dst shr shift) and 0xFF
            return Math.round(a * s + (1 - a) * d).toInt().coerceIn(0, 255)
        }
        return (0xFF shl 24) or (mix(16) shl 16) or (mix(8) shl 8) or mix(0)
    }

    /** Equal to within the rounding two composites can differ by. The
     * blends this compares are FLAT fills, so the tolerance covers
     * arithmetic and nothing else — every measured match was exact or
     * one level off. */
    private fun kayaSameColour(a: Int, b: Int): Boolean {
        for (shift in intArrayOf(16, 8, 0)) {
            val da = (a shr shift) and 0xFF
            val db = (b shr shift) and 0xFF
            if (da - db > 6 || db - da > 6) return false
        }
        return true
    }

    /** The field's viewport, out of the window's own surface.
     *
     * THE SRCRECT IS IN SURFACE SPACE and the caller's rectangle is in
     * window space; they differ by `decorView`'s location in the window,
     * which the gather hop read. Clipped to the surface as well, because
     * `PixelCopy` is given a rectangle it can actually copy — a panned
     * window puts part of the field outside it, and the pixels that are
     * left are still worth photographing. */
    private fun kayaPhotograph(
        activity: ComponentActivity,
        box: android.graphics.Rect,
        read: KayaHighlights,
    ): KayaShot? {
        if (box.width() <= 0 || box.height() <= 0) return null
        val src = android.graphics.Rect(box)
        src.offset(read.surfaceOffset.x, read.surfaceOffset.y)
        if (!src.intersect(0, 0, read.surfaceSize.x, read.surfaceSize.y)) return null
        if (src.width() <= 0 || src.height() <= 0) return null
        val bitmap = android.graphics.Bitmap.createBitmap(
            src.width(), src.height(), android.graphics.Bitmap.Config.ARGB_8888)
        val latch = java.util.concurrent.CountDownLatch(1)
        var ok = false
        android.view.PixelCopy.request(
            activity.window,
            src,
            bitmap,
            { result ->
                ok = result == android.view.PixelCopy.SUCCESS
                latch.countDown()
            },
            android.os.Handler(android.os.Looper.getMainLooper()),
        )
        latch.await(2, java.util.concurrent.TimeUnit.SECONDS)
        if (!ok) {
            bitmap.recycle()
            return null
        }
        return KayaShot(
            bitmap, src.left, src.top, read.surfaceOffset.x, read.surfaceOffset.y)
    }

    /** `visible` when the byte range is inside the textarea's viewport,
     * `offscreen` when it is not. */
    private fun kayaRevealedRead(
        activity: ComponentActivity,
        spec: String,
        range: String,
    ): String {
        val node = kayaTextTarget(spec) ?: return "<no such target>"
        if (node.a11yId.isEmpty()) return "<no a11y_id authored on this widget>"
        val semantics = kayaSemanticsByTag(activity, node.a11yId)
            ?: return "<not in the semantics tree>"
        val text = kayaSemanticsValue(semantics, SemanticsProperties.EditableText)?.text
            ?: return "<no editable text>"
        val bounds = range.split(":")
        if (bounds.size != 2) return "<malformed range>"
        // The verb carries BYTE offsets — the protocol's unit, so one
        // frozen scene compares on five lanes — and the layout indexes
        // UTF-16, so this is the reading-direction conversion.
        val from = kayaUtf16Offset(text, bounds[0].toIntOrNull() ?: -1)
        val to = kayaUtf16Offset(text, bounds[1].toIntOrNull() ?: -1)
        if (from < 0 || to < 0) return "<offset splits a character>"
        // THE PLATFORM'S OWN LAYOUT, fetched through the semantics
        // action an accessibility service uses to ask where text is —
        // not the provider this backend keeps for the draw, so the read
        // does not share the lowering's copy of anything.
        val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
        semantics.config.getOrNull(SemanticsActions.GetTextLayoutResult)
            ?.action?.invoke(layouts)
        val layout = layouts.firstOrNull() ?: return "<no text layout>"
        val length = text.length
        if (length == 0) return "<empty field>"
        val first = from.coerceIn(0, length - 1)
        val last = (if (to > from) to - 1 else from).coerceIn(0, length - 1)
        val top = minOf(layout.getBoundingBox(first).top, layout.getBoundingBox(last).top)
        val bottom =
            maxOf(layout.getBoundingBox(first).bottom, layout.getBoundingBox(last).bottom)
        val scroll = node.scrollState
        val viewport = kayaViewportHeight(layout, scroll)
        if (viewport <= 0) return "<no viewport>"
        return if (top >= scroll.value && bottom <= scroll.value + viewport) "visible"
        else "offscreen"
    }

    /**
     * Start an input-method composition in the target, leaving `text`
     * MARKED — displayed, uncommitted, invisible to the app.
     *
     * THE PLATFORM'S OWN ENTRY POINT AND NOT A TEXT WRITE. No adb
     * command can open a composing region (`input text` injects key
     * events and never calls `setComposingText` — measured, §5), but the
     * harness runs INSIDE the app, so it can take the very connection
     * the input method holds: `AndroidComposeView.onCreateInputConnection`
     * hands out the current text-input session's connection, which only
     * exists while a field is focused. A backend that faked this with a
     * plain insertion would prove nothing about D4.
     *
     * The caret goes to the end first, explicitly, so `compose` inserts
     * at the end of the current text on every lane — the frozen scene's
     * caret arithmetic is the same number everywhere or it is not one
     * assertion.
     *
     * BLOCKS UNTIL THE COMPOSITION IS LIVE, like `type`: the step after
     * this one is what observes the refusal, and a composition still in
     * flight would read as a backend that honoured the selection.
     */
    private fun kayaComposeMarkedText(
        activity: ComponentActivity,
        spec: String,
        marked: String,
    ): String? {
        val opened = onUi(activity) {
            val node = kayaTextTarget(spec) ?: return@onUi "no such target $spec"
            val view = kayaComposeRoot(activity.window.decorView)
                ?: return@onUi "no compose view"
            val connection =
                view.onCreateInputConnection(android.view.inputmethod.EditorInfo())
                    ?: return@onUi "no input connection — nothing has an input session " +
                        "(a field must be focused before it can compose)"
            val end = node.textState.text.length
            connection.setSelection(end, end)
            connection.setComposingText(marked, 1)
            null
        }
        if (opened != null) return opened
        repeat(200) {
            val live = onUi(activity) {
                kayaTextTarget(spec)?.textState?.composition != null
            }
            if (live) return null
            Thread.sleep(5)
        }
        return "the field never reported a composing region after setComposingText"
    }

    /** The textarea (or entry) a range verb names. */
    private fun kayaTextTarget(spec: String): KayaNode? =
        if (spec.startsWith("textarea")) target(spec, "textarea", KayaSceneModel.textareas)
        else target(spec, "entry", KayaSceneModel.entryWidgets)

    /** The merged semantics node carrying this test tag — [kayaAxFind]'s
     * walk, because "the node a leg names" is one question with one
     * answer and the accessibility verbs already ask it. */
    // THE FILE'S THIRD AND LAST EXPERIMENTAL OPT-IN, at the smallest
    // scope that covers it and proven required rather than assumed:
    // removing it fails the compile with "This API is experimental and
    // is likely to change in the future" at exactly the
    // `measureAndLayoutForTest` call, one error, at compose-ui 1.7.5.
    // What it buys is in the call's own comment — a semantics read that
    // is not a frame behind the apply it is asserting about.
    @OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
    private fun kayaSemanticsByTag(activity: ComponentActivity, tag: String): SemanticsNode? {
        val view = kayaComposeRoot(activity.window.decorView) ?: return null
        val root = view as RootForTest
        // THE TREE IS BROUGHT UP TO DATE FIRST, which is not tidiness:
        // Compose publishes semantics on the pass that lays out, so a
        // read taken between an apply and the next frame answers with
        // the state BEFORE the apply. That is invisible while an
        // assertion is waiting for a value to CHANGE — the retry covers
        // it — and fatal when the assertion is one that was already
        // true, because the stale answer matches and the step verifies
        // nothing. Measured 2026-08-06: with D4's refusal deleted the
        // selection really did move, `TextFieldState` said so
        // immediately, and this tree still reported the old caret for
        // ~400ms — long enough for the leg to pass having watched the
        // defect happen. `measureAndLayoutForTest` is the same call
        // Compose's own test framework makes before it reads.
        root.measureAndLayoutForTest()
        return kayaAxFind(root.semanticsOwner.rootSemanticsNode, tag)
    }

    /**
     * A property off this node OR the subtree under it.
     *
     * A text field publishes its editable text, its selection and its
     * layout action from the modifier chain, and whether those land on
     * the same semantics node as the caller's `testTag` is Compose's
     * business and has changed across versions. Searching down from the
     * tagged node is the spelling that does not depend on it.
     */
    private fun <T> kayaSemanticsValue(
        node: SemanticsNode,
        key: androidx.compose.ui.semantics.SemanticsPropertyKey<T>,
    ): T? = kayaSemanticsWith(node) { it.config.getOrNull(key) != null }?.config?.getOrNull(key)

    private fun kayaSemanticsWith(
        node: SemanticsNode,
        depth: Int = 0,
        match: (SemanticsNode) -> Boolean,
    ): SemanticsNode? {
        if (depth > 64) return null
        if (match(node)) return node
        for (child in node.children) {
            kayaSemanticsWith(child, depth + 1, match)?.let { return it }
        }
        return null
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
     *
     * A THIRD SOURCE, ahead of both, for the one role that is not a
     * control kind: `heading` is a PROPERTY a text node carries, and it
     * is read from the published AccessibilityNodeInfo rather than from
     * the semantics config this interpreter wrote — the config would only
     * tell us what we asked for, and what a service receives is the
     * question (the read-backs-lie rule).
     */
    private fun kayaAxRole(
        role: Role?,
        className: CharSequence?,
        childCount: Int,
        heading: Boolean,
    ): String {
        if (heading) return "heading"
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
    private fun kayaAx(activity: ComponentActivity, tag: String): KayaAxRead? {
        val view = kayaComposeRoot(activity.window.decorView) ?: return null
        val owner = (view as RootForTest).semanticsOwner
        val node = kayaAxFind(owner.rootSemanticsNode, tag) ?: return null
        val info = view.accessibilityNodeProvider?.createAccessibilityNodeInfo(node.id)
        val role = node.config.getOrNull(SemanticsProperties.Role)
        // THE SEMANTICS-ONLY FALLBACK, computed on every read but
        // consulted only after the provider's leash expires (see the
        // expect_ax arm): the same platform-owned tree the provider
        // derives its answer FROM, one layer closer — heading and role
        // are semantics properties outright, and an editable text is a
        // field by the property the provider itself keys on.
        val cfg = node.config
        val fallbackRole = when {
            cfg.getOrNull(SemanticsProperties.Heading) != null -> "heading"
            cfg.getOrNull(SemanticsProperties.EditableText) != null -> "field"
            else -> kayaAxRole(role, null, node.children.size, false)
        }
        return KayaAxRead(
            kayaAxRole(role, info?.className, node.children.size, kayaAxHeading(info)) +
                "/" + kayaAxName(node),
            infoServed = info != null,
            fallback = fallbackRole + "/" + kayaAxName(node),
        )
    }

    /**
     * One ax read, with the PROVIDER'S SILENCE carried out-of-band. The
     * semantics tree is in-process and always answers; the provider
     * serves AccessibilityNodeInfo from its own view of that tree, and
     * the two can DISAGREE: three straight 2026-08-12 matrix runs had
     * clipboard-jvm's pasted field findable by tag while
     * createAccessibilityNodeInfo returned null past the step's whole
     * 5s deadline — under five-lane host contention only, solo green
     * every time. WHY the provider lags that far is deliberately not
     * claimed here (the on-device probe DISPROVED the obvious story:
     * with accessibility disabled outright, regular node infos are
     * still served — and the root node's id never is, which is also
     * why no readiness probe of the root can stand in for the real
     * read). What is measured is the disagreement itself, so it is
     * carried as its own state instead of being conflated with a
     * classification: a read with [infoServed] false measured NO
     * classification, and reporting it as `unknown/…` sends the reader
     * after a lowering that was never consulted.
     */
    private data class KayaAxRead(
        val spec: String,
        val infoServed: Boolean,
        val fallback: String,
    )


    /**
     * Whether the platform publishes this node as a HEADING. The
     * framework getter arrived in API 28 and kaya's floor is 26, so
     * below it the answer is the honest one for the pre-28 platform:
     * there was no heading bit on an AccessibilityNodeInfo to publish,
     * and Compose stashes it in an extras bundle no service of that era
     * reads.
     */
    private fun kayaAxHeading(info: android.view.accessibility.AccessibilityNodeInfo?): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && info?.isHeading == true

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
     * THE expect_menu_symbol READ (docs/styling-plan.md D6): the
     * semantic name the item's REAL row carries, off the merged
     * semantics tree — the post-merge node a service focuses and speaks.
     *
     * MAIN THREAD ONLY (callers go through [onUi]).
     *
     * WHY THIS AND NOT THE MODEL. `KayaMenuItem.symbol` is right there,
     * and answering from it would make the verb agree with itself: the
     * apply arm decoded a number, the read would hand the same number
     * back, and a backend that drew nothing would be green. What is read
     * instead is the content description on the row's merged node, and
     * it got there from the [Icon] the lowering drew. Delete
     * [KayaSymbolIcon]'s body and every assertion fails.
     *
     * WHY THE ROW HAS TO BE PRESENTED FIRST, which is the shape of this
     * platform rather than a choice. macOS can read a menu that is shut,
     * because NSMenuItem is a retained object AppKit hands you whether
     * or not the menu is on screen. Compose composes a DropdownMenu's
     * content ONLY while it is open — an overflow row that nobody is
     * looking at does not exist, in any tree, at all. So the read drives
     * the same presentation state the ⋮ tap drives ([kayaPresentMenuRow])
     * and then reads what got composed. It is the one non-vacuous
     * observation available here, and it is stronger than the iOS arm's,
     * which can only confirm that a name resolves.
     *
     * TOTAL, like [kayaMenuStateRead]'s siblings: every failure is a
     * short sentence and a retryable non-match, never an exception. The
     * step wrapper re-runs it every 20ms, which is also what absorbs the
     * frame the presentation needs.
     */
    private fun kayaMenuSymbolRead(activity: ComponentActivity, path: String): String {
        val item = kayaResolveMenuPath(path)?.first ?: return "no such item"
        kayaPresentMenuRow(item)
        val node = kayaMenuRowNode(activity, kayaMenuTag(item.id))
            ?: return kayaMenuRowMissing(item)
        val described = node.config.getOrNull(SemanticsProperties.ContentDescription)
        if (described.isNullOrEmpty()) {
            // WHAT THIS MEASURED: the row is composed and the node a
            // service focuses carries no description. It deliberately
            // does NOT say whether the app asked for a symbol — this
            // reader cannot tell "none declared" from "declared and
            // never lowered", and a diagnostic may only print what it
            // measured (CLAUDE.md invariant 3).
            return "no icon on the menu row"
        }
        val name = described.joinToString(" ")
        if (!isSymbolName(name)) {
            // A description that is not one of the twenty came from
            // something other than the symbol lowering — an icon blob's
            // description is the item's LABEL, and reporting "Share" as
            // though it were a symbol nobody recognises would send the
            // reader after the vocabulary instead of the row.
            return "the row's content description is \"$name\", which is not a symbol name"
        }
        return name
    }

    /**
     * Present the surface this item's row materializes on, so there is
     * something for [kayaMenuSymbolRead] to read. Idempotent: the step
     * wrapper calls the read again every 20ms until the frame lands.
     */
    private fun kayaPresentMenuRow(item: KayaMenuItem) {
        // An OPEN context menu owns resolution exclusively (the state
        // read's rule verbatim) and context_open already presented it;
        // nothing to drive.
        if (KayaSceneModel.openContextWidget != null) return
        // A promoted primary is a real bar action — composed whenever
        // the bar is, menu open or shut.
        if (kayaPromotedActions().any { it.id == item.id }) return
        // Everything else in the window catalog lives behind the ⋮.
        // The flag is claimed only by the call that actually OPENS it —
        // a menu already on screen was somebody else's, and the closing
        // rule is "only what a read opened may a read close".
        if (!KayaSceneModel.menuOverflowOpen) {
            KayaSceneModel.menuOverflowOpen = true
            KayaSceneModel.menuOverflowPresentedForRead = true
        }
        // A row under a nested `menu` exists only inside that menu's
        // drill-in — and the drill is a JUMP, not a path, so one hop
        // reaches any depth. A top-level group's header and its direct
        // children are at the overflow's root, and so are a radio
        // group's options, which render inline wherever the group does.
        val parent = item.parent
        KayaSceneModel.menuOverflowDrilled =
            if (parent != null && parent.parent != null &&
                parent.kind == MENU_KIND_MENU
            ) {
                parent.id
            } else {
                0L
            }
    }

    /** Put the overflow back the way the scene left it, once a read has
     * had its answer. Only if THIS is what opened it: a menu the user's
     * tap opened is the user's, and a read must not close it. */
    private fun kayaDismissPresentedMenuRow() {
        if (!KayaSceneModel.menuOverflowPresentedForRead) return
        KayaSceneModel.menuOverflowPresentedForRead = false
        KayaSceneModel.menuOverflowOpen = false
        KayaSceneModel.menuOverflowDrilled = 0L
    }

    /**
     * The tagged node for a materialized menu affordance, across every
     * window this host can be showing one in: the activity's own tree
     * (the bar), then each open menu popup (the overflow, a drill-in, a
     * context menu).
     *
     * MERGED trees only — [kayaAxFind]'s rule, for [kayaAxFind]'s
     * reason: what a client consumes is the post-merge view, and the
     * row's description and the row's tag land on the same merged node
     * precisely because the row merges its descendants.
     */
    private fun kayaMenuRowNode(activity: ComponentActivity, tag: String): SemanticsNode? {
        kayaComposeRoot(activity.window.decorView)?.let { view ->
            kayaAxFind((view as RootForTest).semanticsOwner.rootSemanticsNode, tag)
                ?.let { return it }
        }
        for (popup in KayaSceneModel.menuPopupViews) {
            val root = kayaComposeRoot(popup) ?: continue
            kayaAxFind((root as RootForTest).semanticsOwner.rootSemanticsNode, tag)
                ?.let { return it }
        }
        return null
    }

    /**
     * Why no row was found — every input this reader weighed, because
     * "not composed" has three quite different causes here and the
     * sentence a reader chases has to tell them apart: the menu was
     * never presented, it was presented but the row is one drill deeper
     * than this arm jumped, or the lowering stopped tagging its rows.
     * Printed only after the step's whole deadline, by which time the
     * frame excuse is gone.
     */
    private fun kayaMenuRowMissing(item: KayaMenuItem): String =
        "no composed row carries " + kayaMenuTag(item.id) +
            " (overflow open=" + KayaSceneModel.menuOverflowOpen +
            " drilled=" + KayaSceneModel.menuOverflowDrilled +
            " context=" + KayaSceneModel.openContextWidget +
            " promoted=" + kayaPromotedActions().any { it.id == item.id } +
            " menu popups=" + KayaSceneModel.menuPopupViews.size +
            "); on this host an overflow or context row is composed only " +
            "while its menu is presented"

    /**
     * The inputs [kayaAxRole] weighs, for a MISMATCH. `unknown/…` says
     * the platform classified the control as something the closed set
     * has no name for, and the next question is always which something —
     * one emulator round-trip per answer without this, and the whole
     * point of reading the real tree is that its answers are not
     * guessable from here. Every input it weighs is printed, heading
     * included: a sentence that omits one is a sentence that cannot tell
     * a wrong classification from a missing heading bit.
     */
    private fun kayaAxWhy(activity: ComponentActivity, tag: String): String {
        val view = kayaComposeRoot(activity.window.decorView) ?: return ""
        val owner = (view as RootForTest).semanticsOwner
        val node = kayaAxFind(owner.rootSemanticsNode, tag) ?: return ""
        val info = view.accessibilityNodeProvider?.createAccessibilityNodeInfo(node.id)
        return " (role=" + node.config.getOrNull(SemanticsProperties.Role) +
            " class=" + info?.className + " kids=" + node.children.size +
            " heading=" + kayaAxHeading(info) + ")"
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
                val stepStart = System.nanoTime()
                var stepDeadline = stepStart + 5_000_000_000L
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
                        kayaAwaitQuiet()
                        val answered = kayaBatches
                        val ok = onUi(activity) {
                            // A click on a TEXT KIND focuses it — what a
                            // native tap does to a field, and the only
                            // way a scene can put focus on a STAMPED
                            // copy (no instance-addressed focus command
                            // exists for a guest to call). Routed
                            // through focusedId exactly as the wire's
                            // COMMAND_FOCUS arm is: the model drives
                            // the FocusRequester in this interpreter,
                            // and a direct requestFocus here would
                            // fight it.
                            val text = target(parts[1], "entry", KayaSceneModel.entryWidgets)
                                ?: target(parts[1], "textarea", KayaSceneModel.textareas)
                            if (text != null) {
                                KayaSceneModel.focusedId = text.id
                                true
                            } else {
                                target(parts[1], "button", KayaSceneModel.buttons)
                                    ?.also { KayaPresent.emitClicked(it.tag) } != null
                            }
                        }
                        if (!ok) failures.add("no such target ${parts[1]}")
                        else kayaAwaitAnswer(answered)
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
                    "expect_sections_presentation" -> {
                        // THE ARM THE SECTIONS RENDER TOOK, off the
                        // stamp the render body wrote — never derived
                        // from the declared prop, which would agree
                        // with the lowering by construction (the
                        // expect_split rule). window#N addresses an aux
                        // window; the implicit form is the primary.
                        val target = parts.getOrNull(1) ?: ""
                        val explicit = target.startsWith("window#")
                        val wid =
                            if (explicit) target.removePrefix("window#").toLongOrNull() ?: -1
                            else 0L
                        val prefix = if (explicit) "window#$wid " else ""
                        val want = quoted(parts.drop(if (explicit) 2 else 1))
                        val got = onUi(activity) {
                            when {
                                // window 0 is the one surface this host
                                // has (the core rejects create_window),
                                // so a named aux window is UNREADABLE —
                                // never an arm name, or a sidebar
                                // assertion could pass off a window
                                // that does not exist.
                                wid != 0L -> "no such window"
                                KayaSceneModel.sectionsRendered.isEmpty() ->
                                    "nothing stamped — no sections body rendered"
                                else -> KayaSceneModel.sectionsRendered
                            }
                        }
                        if (got == want) {
                            observed.add("${prefix}sections $want")
                        } else {
                            failures.add("${prefix}sections presentation $got, wanted $want")
                        }
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
                    "expect_dirty" -> {
                        // THE UNSAVED-WORK MARK (docs/dirty-plan.md
                        // D5, and Stage::window_dirty's table in
                        // crates/kaya/src/harness.rs carries the row).
                        // Every backend answers the same question off
                        // its own surface; on the desktops that means
                        // the chrome — the close button's AXEdited on
                        // macOS, the caption's leading `*` on Windows,
                        // the header-bar marker on GTK — because
                        // reading kaya's own model where chrome exists
                        // would make the verb agree with itself and
                        // never catch a lowering that stopped short of
                        // the window.
                        //
                        // HERE THE MODEL IS THE HONEST ANSWER, and
                        // that is the stated carve-out rather than a
                        // shortcut (D4): this platform has no chrome to
                        // publish the mark in, so the applied prop is
                        // the only observable there is. It is not
                        // vacuous — the value came over the wire
                        // through the apply arm, so a dropped prop
                        // fails here, and the negative test watched it
                        // do exactly that.
                        val target = parts.getOrNull(1) ?: ""
                        val explicit = target.startsWith("window#")
                        val wid =
                            if (explicit) target.removePrefix("window#").toLongOrNull() ?: -1
                            else 0L
                        val prefix = if (explicit) "window#$wid " else ""
                        val want = parts.getOrNull(if (explicit) 2 else 1) == "true"
                        // window 0 is the one surface this host has
                        // (the core rejects create_window). A named
                        // window that cannot exist is UNREADABLE, never
                        // `false`: a clean-window assertion must not
                        // pass because the read had nothing to read.
                        if (wid != 0L) {
                            failures.add("${prefix}dirty unreadable, wanted $want")
                        } else {
                            val got = onUi(activity) { KayaSceneModel.windowDirty }
                            if (got == want) {
                                observed.add("${prefix}dirty $want")
                            } else {
                                failures.add("${prefix}dirty $got, wanted $want")
                            }
                        }
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
                    "expect_save_dialog" -> {
                        // The REAL save panel, read out of DocumentsUI's
                        // own tree: the directory it is showing AND the
                        // name in its name field. The name half is the
                        // one that catches a backend which ignored the
                        // name it was told — that saves under the
                        // SUGGESTED name, where every byte assertion
                        // downstream still passes and points at the
                        // wrong file.
                        val wantSaveDir = kayaExpandPath(parts.getOrNull(1) ?: "")
                        val wantSaveName = parts.getOrNull(2) ?: ""
                        if (wantSaveDir.contains("$")) {
                            // The picker's guard, verbatim: an
                            // unexpanded expectation is aimed correctly,
                            // reads the right directory back, and fails
                            // against a literal "$PID" — which reads as
                            // a broken dialog rather than a broken
                            // script.
                            failures.add(
                                "expect_save_dialog $wantSaveDir: unexpanded substitution — " +
                                    "only \$TMP and \$PID exist",
                            )
                        } else if (wantSaveDir.isEmpty() || wantSaveName.isEmpty()) {
                            failures.add("expect_save_dialog wants a directory and a name")
                        } else {
                            val saveState = kayaSaveDialogState()
                            if (saveState == null) {
                                // WHAT IS ON SCREEN INSTEAD, because "no
                                // save dialog live" is the same sentence
                                // for a panel that never presented and
                                // for a reader that cannot see the one
                                // that did — and those want opposite
                                // fixes. Measured here: the reader was
                                // keyed on the wrong package's
                                // container id and said this about a
                                // panel that was up and correct.
                                failures.add(
                                    "no save dialog live; DocumentsUI is showing " +
                                        "${KayaHarnessAccessibility.live?.dialogShape()}"
                                )
                            } else {
                                val (where, name) = saveState
                                when {
                                    !where.endsWith(wantSaveDir) ->
                                        failures.add(
                                            "save dialog showing \"$where\", " +
                                                "wanted \"$wantSaveDir\""
                                        )
                                    name != wantSaveName ->
                                        failures.add(
                                            "save dialog names \"$name\", wanted \"$wantSaveName\""
                                        )
                                    else ->
                                        observed.add(
                                            "save dialog \"$wantSaveDir\" \"$wantSaveName\""
                                        )
                                }
                            }
                        }
                    }
                    "file_dialog_name" -> {
                        // Silent like click — expect_save_dialog reads it
                        // back. EXCEPT that the panel must BE there:
                        // typing into one that has not presented yet does
                        // nothing at all, and the leg then saves under
                        // the suggested name with every downstream
                        // assertion still green.
                        val saveName = parts.getOrNull(1) ?: ""
                        when {
                            saveName.isEmpty() ->
                                failures.add("file_dialog_name wants a file name")
                            kayaAwaitSaveDialogState() == null ->
                                failures.add("file_dialog_name $saveName: no save dialog is live")
                            KayaHarnessAccessibility.live?.setSaveName(saveName) != true ->
                                failures.add(
                                    "file_dialog_name $saveName: the panel's name field " +
                                        "refused the text"
                                )
                        }
                    }
                    "file_save" -> {
                        // Press the panel's own SAVE, or dismiss it — the
                        // same controls a user works, so DocumentsUI's
                        // own create-and-answer runs and nothing is
                        // synthesized. Silent; the observable is the
                        // guest's reaction to the result.
                        val saveArg = parts.getOrNull(1) ?: ""
                        val svc = KayaHarnessAccessibility.live
                        when {
                            saveArg != "" && saveArg != "cancel" ->
                                failures.add(
                                    "file_save takes nothing or `cancel`, got $saveArg"
                                )
                            svc == null ->
                                failures.add(
                                    "file_save: no harness accessibility service — the " +
                                        "runner did not enable it"
                                )
                            kayaAwaitSaveDialogState() == null ->
                                failures.add("file_save: no save dialog is live")
                            // CANCEL IS BACK on this platform, the same
                            // affordance and the same bounded walk the
                            // picker's cancel takes — there is no Cancel
                            // button in either dialog.
                            saveArg == "cancel" ->
                                if (!svc.dismiss()) {
                                    failures.add(
                                        "file_save cancel: the panel would not dismiss; " +
                                            "windows are ${svc.windowPackages()}"
                                    )
                                }
                            !svc.confirmSave() ->
                                failures.add("file_save: the panel's SAVE button refused the press")
                            // AND THE PANEL MUST BE GONE — the picker's
                            // postcondition and the same reason: a press
                            // that lands before the panel is interactive
                            // is swallowed with no error anywhere, and
                            // the leg then fails three steps later on an
                            // assertion about the GUEST.
                            !svc.waitForPickerGone() ->
                                failures.add(
                                    "file_save: the panel is still up (naming " +
                                        "\"${kayaSaveDialogState()?.second}\") — the press was " +
                                        "swallowed, which the panel cannot tell you"
                                )
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
                    // THE THREE TEXT-RANGE READS. Every one of them goes
                    // to the platform for the half it can: the SELECTION
                    // and the field's own TEXT come out of the merged
                    // semantics tree (the data an assistive client
                    // receives, and TalkBack's own channel), the
                    // VIEWPORT geometry out of the field's own
                    // TextLayoutResult and ScrollState.
                    //
                    // HIGHLIGHT IS THE ONE WITH NO PLATFORM CHANNEL:
                    // Android publishes no accessibility property
                    // carrying a background span (range-probe-android.md
                    // §4 went looking). So it reads what the DRAW SCOPE
                    // painted — recorded beside the drawPath calls,
                    // after the staleness compare — and never the
                    // declaration, which would agree with the apply arm
                    // by construction and pass with the paint deleted.
                    // That failure is not hypothetical here: pushing an
                    // AnnotatedString into the state compiles clean and
                    // paints nothing (§1a).
                    "expect_highlights", "expect_selection" -> {
                        val want = quoted(parts.drop(2))
                        val got =
                            if (parts[0] == "expect_highlights") {
                                kayaHighlightRead(activity, parts[1])
                            } else {
                                onUi(activity) { kayaSelectionRead(activity, parts[1]) }
                            }
                        if (got == want) observed.add("${parts[0]} $want")
                        else failures.add("${parts[0]} $got, wanted $want")
                    }
                    "expect_revealed" -> {
                        // CONTAINMENT, never the viewport itself: how
                        // much context a scroll leaves around a range is
                        // native behaviour and differs per lane, while
                        // "is my range on screen" is the same question
                        // everywhere. The `offscreen` spelling is what
                        // keeps this from being vacuous — a scene
                        // asserts it BEFORE the reveal, so a document
                        // short enough to be entirely visible fails
                        // rather than passes.
                        val want = parts[3]
                        val got = onUi(activity) {
                            kayaRevealedRead(activity, parts[1], parts[2])
                        }
                        if (got == want) observed.add("${parts[2]} $want")
                        else failures.add("${parts[2]} is $got, wanted $want")
                    }
                    "compose" -> {
                        // The state a user is in mid-word with an IME,
                        // which no other verb can reach: `type` is
                        // printable ASCII by contract, precisely because
                        // a composed character is an input-method
                        // question and not a verb argument. This goes
                        // through the field's own InputConnection —
                        // `setComposingText`, the call an IME makes — so
                        // the text is DISPLAYED, UNCOMMITTED and
                        // invisible to the app, which is exactly the
                        // state select_range must refuse to run over.
                        kayaComposeMarkedText(activity, parts[1], quoted(parts.drop(2)))
                            ?.let { failures.add("compose: $it") }
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
                    "expect_typeface" -> {
                        // THE RESOLVED FAMILY, off the real text nodes:
                        // the font the SHAPER picked, named by its own
                        // file's OpenType name table. Never the request
                        // — on this backend the two reads that look
                        // right both echo it
                        // (styling/typeface-compose.md §2.1), and an
                        // echo would report a perfect swap for a family
                        // the device does not have, which is the whole
                        // failure this slice exists to catch.
                        //
                        // The family is a QUOTED string in the grammar
                        // and the observation is byte-compared against
                        // harness.rs ("typeface Georgia"), so the quotes
                        // come off here and stay off in both sentences.
                        val want = quoted(parts.drop(1))
                        val got = onUi(activity) { kayaResolvedTypeface() }
                        if (got == want) {
                            observed.add("typeface $want")
                        } else {
                            failures.add("typeface $got, wanted $want")
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
                    "expect_inset" -> {
                        // The window content inset, MEASURED: the
                        // halved gap between the padding container's
                        // outer extent and the offer inside it, in DP
                        // (the scene's layout unit; densities differ
                        // per device while the inset number does not) —
                        // RELATIVE deliberately, because absolute
                        // offers cannot be byte-frozen across platforms
                        // (docs/styling-plan.md D3).
                        // TWO FORMS, one measurement: `expect_inset N`
                        // reads the WINDOW's pair, `expect_inset
                        // <target> N` reads a CONTAINER's own
                        // (kayaInsetOuter/Inner around its padding) —
                        // the prop one level down, born from the
                        // editor's full-bleed window taking the status
                        // row's margin with it.
                        if (parts.size >= 3) {
                            val spec = parts[1]
                            val want = parts[2]
                            val node = kayaWidgetTarget(spec)
                            val got = if (node == null) {
                                "no such target $spec"
                            } else {
                                onUi(activity) {
                                    val density =
                                        activity.resources.displayMetrics.density
                                    val outer = kayaInsetOuter[node.id]
                                    val inner = kayaInsetInner[node.id]
                                    if (outer == null || inner == null) {
                                        "no layout recorded for $spec"
                                    } else {
                                        val x = Math.round(
                                            (outer.first - inner.first) / 2 / density)
                                        val y = Math.round(
                                            (outer.second - inner.second) / 2 / density)
                                        if (x == y) "$x" else "${x}x$y (axes disagree)"
                                    }
                                }
                            }
                            if (got == want) observed.add("inset $spec $want")
                            else failures.add("inset $spec $got, wanted $want")
                        } else {
                            val want = parts[1]
                            val got = onUi(activity) {
                                val density = activity.resources.displayMetrics.density
                                val outer = kayaOuterSize
                                val inner = kayaAvailableSize
                                if (outer.width <= 0 || inner.width <= 0) {
                                    "no layout recorded"
                                } else {
                                    val x = Math.round((outer.width - inner.width) / 2 / density)
                                    val y = Math.round((outer.height - inner.height) / 2 / density)
                                    if (x == y) "$x" else "${x}x$y (axes disagree)"
                                }
                            }
                            if (got == want) observed.add("inset $want")
                            else failures.add("inset $got, wanted $want")
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
                        // ONE VERB, TWO SUBJECTS (harness.rs
                        // Step::ExpectFills).
                        //
                        // A CONTAINER's children span its content box —
                        // the leftover-consumption half of the grow
                        // contract, which shares (total-invariant) and
                        // root_fills (root-level only) can never see.
                        // Span = the measured cell tracks plus the 8-dp
                        // gaps, against the container's own rendered
                        // extent.
                        //
                        // A WIDGET spans the cell its weight earned, on
                        // its container's main axis — the half shares
                        // cannot see either, and for the opposite
                        // reason: kayaMainExtents is the CELL, so a
                        // control drawing three lines tall inside a
                        // correct cell splits the column exactly right
                        // and renders a small box. An overflow is not a
                        // leftover, so that test is one-sided.
                        //
                        // The pass observation matches harness.rs
                        // byte-for-byte in both cases.
                        val isContainer = parts[1].startsWith("row") ||
                            parts[1].startsWith("column")
                        val slack = onUi(activity) {
                            if (!isContainer) {
                                return@onUi kayaWidgetTarget(parts[1])?.let { widget ->
                                    val track = kayaMainExtents[widget.id] ?: 0.0
                                    if (track <= 0.0) {
                                        "no track recorded — not a flex child"
                                    } else {
                                        val drawn = kayaDrawnExtents[widget.id] ?: 0.0
                                        if (drawn >= track - 2.0) {
                                            ""
                                        } else {
                                            "draws ${Math.round(drawn)}px of a " +
                                                "${Math.round(track)}px track"
                                        }
                                    }
                                }
                            }
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
                            isContainer ->
                                failures.add("${parts[1]} leaves leftover ($slack)")
                            else ->
                                failures.add("${parts[1]} is short of its track ($slack)")
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
                                when {
                                    got == null -> failures.add(
                                        "ax ${parts[1]}: nothing carries " +
                                            "test tag \"${node.a11yId}\"; " +
                                            onUi(activity) { kayaAxDump(activity) }
                                    )
                                    // THE PROVIDER'S SILENCE IS ITS OWN
                                    // VERDICT, ahead of the comparison: a
                                    // read that got no AccessibilityNodeInfo
                                    // measured no classification, so it must
                                    // not print as one (see [KayaAxRead]).
                                    // It also earns a longer leash, once per
                                    // step: the disagreement outlived the
                                    // whole 5s deadline in three straight
                                    // matrix runs and resolved on its own in
                                    // every solo run, so the retry is what
                                    // absorbs it — and only the extended
                                    // deadline turns this sentence into a
                                    // failure, naming the state that was
                                    // actually seen.
                                    !got.infoServed &&
                                        System.nanoTime() >= stepStart + 20_000_000_000L &&
                                        got.fallback == want -> {
                                        // THE LEASH EXPIRED WITH THE PROVIDER
                                        // STILL SILENT, and the SEMANTICS
                                        // TREE — the provider's own source —
                                        // answers what the step asks. The
                                        // observation stays byte-identical
                                        // (invariant 6); the evidence
                                        // downgrade is printed HERE, the
                                        // channel the phone cuts already use
                                        // for what a verdict cannot carry.
                                        // Ruled by the maintainer 2026-08-16
                                        // after the silence outlived the
                                        // leash in two straight matrices,
                                        // solo-green every time.
                                        Log.i(
                                            "kaya",
                                            "KAYA_HARNESS: ax ${parts[1]} served from " +
                                                "the semantics tree after " +
                                                "${(System.nanoTime() - stepStart) / 1_000_000}ms " +
                                                "of provider silence",
                                        )
                                        observed.add("ax \"$want\"")
                                    }
                                    !got.infoServed -> {
                                        stepDeadline = maxOf(
                                            stepDeadline,
                                            stepStart + 20_000_000_000L,
                                        )
                                        failures.add(
                                            "ax ${parts[1]}: the accessibility " +
                                                "provider served no node info " +
                                                "for tag \"${node.a11yId}\" " +
                                                "though its semantics node " +
                                                "exists — no classification " +
                                                "was published to read " +
                                                "(retried ${(System.nanoTime() - stepStart) / 1_000_000}ms)"
                                        )
                                    }
                                    got.spec != want -> failures.add(
                                        "ax \"${got.spec}\", wanted \"$want\"" +
                                            onUi(activity) { kayaAxWhy(activity, node.a11yId) }
                                    )
                                    else -> observed.add("ax \"$want\"")
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
                    "expect_toolbar" -> {
                        // THE TOOLBAR IS A DEPTH SLICE, mac first
                        // (docs/chrome-plan.md C2). This backend already
                        // promotes the `primary` bit into the
                        // TopAppBar's actions slot, so the LOWERING is
                        // here; what is missing is the READ off the
                        // composed bar — the row's merged semantics, the
                        // way kayaMenuSymbolRead reads a menu row — and
                        // a read that answered off the promotion list
                        // instead would be the exact defect the iOS
                        // symbol gap was (toolbar-repo.md §2.4).
                        //
                        // The refusal goes through the helper both gates
                        // read: it holds every android toolbar leg off
                        // run-emulator.sh until the read lands, and it
                        // cannot pass vacuously because it cannot pass.
                        depthStub("toolbar")
                    }
                    "expect_toolbar_item" -> {
                        // Its own arm rather than a second label on the
                        // one above: check-verbs reads each `"expect_*"
                        // ->` head and demands that arm record or
                        // refuse, and a verb sharing another's head is
                        // a verb the sweep never looks at.
                        depthStub("toolbar")
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
                    "expect_menu_symbol" -> {
                        // THE SEMANTIC ICON (docs/styling-plan.md D6),
                        // read off the composed row's merged semantics —
                        // see kayaMenuSymbolRead for why it is that and
                        // not the model field sitting next to it, and
                        // why the read presents the menu first.
                        val head = quotedHead(line.substring(parts[0].length))
                        val want = head?.let { quotedHead(it.second) }
                        if (head == null || want == null || want.second.isNotEmpty()) {
                            failures.add(
                                "expect_menu_symbol wants a quoted path and a quoted " +
                                    "symbol name: $line")
                        } else {
                            val got = onUi(activity) { kayaMenuSymbolRead(activity, head.first) }
                            if (got == want.first) {
                                // The read presented the overflow to
                                // materialize the row; put it back now
                                // that it has its answer, so the next
                                // step sees the surface the scene left.
                                // Only on the hit: a miss is retried,
                                // and closing between attempts would
                                // take the row away each time.
                                onUi(activity) { kayaDismissPresentedMenuRow() }
                                observed.add("menu \"${head.first}\" symbol \"${want.first}\"")
                            } else {
                                failures.add(
                                    "menu \"${head.first}\" symbol \"$got\", " +
                                        "wanted \"${want.first}\"")
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

// ---- Text ranges: the ONE place this file converts an offset ---------
//
// The LOWERING path does no arithmetic and must not: offsets arrive from
// the core already in UTF-16 code units, converted against the same text
// the core validated them against (scratchpad/ranges-units.md §7). This
// interpreter is a string-matched layer the compiler cannot hold to the
// Rust source, so Unicode arithmetic in an apply arm is the shape that
// ships wrong and stays wrong.
//
// THE READING DIRECTION IS DIFFERENT AND IS DELIBERATE. A harness verb
// compares one frozen string on five lanes (invariant 6), so a read must
// answer in the PROTOCOL's unit — UTF-8 byte offsets — and the only
// party holding the widget's real text is this side.
//
// BOTH CONVERSIONS REFUSE A SPLIT CHARACTER RATHER THAN ROUNDING, which
// on this runtime is not pedantry: `String.substring` across a surrogate
// pair hands back a LONE SURROGATE, and encoding that to UTF-8 yields a
// single `?` (0x3F) with no error anywhere (scratchpad/ranges-units.md
// §4 measured exactly this on the JVM). A silent one-byte answer where
// four were owed is the kind of wrong number that reads like a real one.

/** A UTF-16 code-unit offset as a UTF-8 byte offset into the same text,
 * or -1 when the offset splits a character — which can only mean the
 * lowering handed the platform an offset the core would have refused. */
internal fun kayaByteOffset(text: String, utf16: Int): Int {
    if (utf16 < 0 || utf16 > text.length) return -1
    // The low half of a surrogate pair at this index IS the split: the
    // prefix would end on a lone high surrogate.
    if (utf16 < text.length && Character.isLowSurrogate(text[utf16])) return -1
    return text.substring(0, utf16).toByteArray(Charsets.UTF_8).size
}

/** The inverse, for the one verb that arrives carrying byte offsets:
 * expect_revealed asks whether a range is on screen, so the range has to
 * be expressed in the layout's unit before it can be compared. */
internal fun kayaUtf16Offset(text: String, byte: Int): Int {
    if (byte < 0) return -1
    val bytes = text.toByteArray(Charsets.UTF_8)
    if (byte > bytes.size) return -1
    // A continuation byte (10xxxxxx) is inside a character.
    if (byte < bytes.size && (bytes[byte].toInt() and 0xC0) == 0x80) return -1
    return String(bytes, 0, byte, Charsets.UTF_8).length
}

/**
 * A set of platform ranges in the harness's spelling:
 * `<start>:<end>=<covered text>` per range, `|`-joined, ascending.
 *
 * THE COVERED TEXT IS NOT DECORATION. Offsets alone would let a wrong
 * lowering report its own wrong numbers back unharmed; the covered half
 * has no arithmetic in it — the platform slices its own string with the
 * range it is actually holding — so a backend that forwarded kaya's byte
 * offsets as if they were UTF-16 shows up as the wrong CHARACTERS, which
 * is a failure nobody can read as a rounding difference.
 */
internal fun kayaRangeSpelling(
    text: String,
    ranges: List<KayaRange>,
    unpainted: Set<KayaRange> = emptySet(),
    offwindow: Set<KayaRange> = emptySet(),
): String =
    ranges.sortedBy { it.start }.joinToString("|") { r ->
        val from = kayaByteOffset(text, r.start)
        val to = kayaByteOffset(text, r.stop)
        when {
            // Named, not silently coerced: no scene will ever expect
            // any of these, and each says which defect it is.
            from < 0 || to < 0 || r.start > r.stop -> "split@${r.start}:${r.stop}="
            // The range sits where the app's own window does not reach —
            // something outside the app moved the window out from under
            // the field (the soft keyboard's pan is the measured case).
            // NOT a claim about the paint: the photograph never saw the
            // field, so it may not accuse the lowering, and it may not
            // pass either.
            offwindow.contains(r) -> "offwindow@${r.start}:${r.stop}="
            // The range was declared, was recorded as painted, the
            // photograph really is of the field, and the pixels where the
            // decoration should be say otherwise.
            unpainted.contains(r) -> "unpainted@${r.start}:${r.stop}="
            else -> "$from:$to=" + text.substring(r.start, r.stop)
        }
    }

/**
 * SELECT one range — and REFUSE while an input method is composing (D4).
 *
 * THE REFUSAL ASKS THE PLATFORM, not the harness. `TextFieldState`
 * publishes the composing region (`composition`), so this backend can
 * see the state the core never will: composition is on no kaya channel
 * and never will be, so the app cannot avoid the race and the core
 * cannot know about it. Measured on this backend
 * (range-probe-android.md §5): a `state.edit {}` selection while a
 * composing region is live DESTROYS it — a half-typed word is committed
 * and its underline vanishes, an in-progress kana conversion is
 * force-committed. That is data loss shaped like a feature.
 *
 * A NO-OP UNDER A NAMED REASON AND NOT A PANIC. The app wrote correct
 * code and lost a race with a human being; the app that wants the
 * selection waits for the composition to end, which `text_changed`
 * announces anyway.
 *
 * ROUTE A (`edit { selection = }`) rather than the semantics
 * `SetSelection` action, and the reason is D4 itself: the semantics
 * route PRESERVES a composing region, so it would move the selection
 * mid-composition — which is the thing that must not happen — and the
 * explicit refusal would still be owed. Given that, the public mutator
 * on the state API is the simpler of the two, and it needs neither
 * focus nor a live semantics node. Its one recorded hazard does not
 * apply: a SELECTION-ONLY `edit {}` leaves the field's undo history
 * intact (measured, §2 — D7's clear is keyed on the TEXT changing, not
 * on `edit {}` being called).
 */
internal fun kayaSelectRange(node: KayaNode, range: KayaRange) {
    val length = node.textState.text.length
    // Bounds are re-checked against the LIVE field, and this is not
    // distrust of the core: Compose THROWS IllegalArgumentException on
    // an out-of-bounds selection (documented `requireValidRange`,
    // scratchpad/ranges-units.md §3), and the field's length is a fact
    // only this side holds at this instant.
    if (range.start < 0 || range.start > range.stop || range.stop > length) return
    if (node.textState.composition != null) {
        Log.i(
            "kaya",
            "KAYA_DIAG select_range refused: ime_composition (widget ${node.id})")
        return
    }
    node.textState.edit {
        selection = androidx.compose.ui.text.TextRange(range.start, range.stop)
    }
}

/**
 * REVEAL one range: scroll the textarea's own viewport until the range's
 * box is inside it.
 *
 * THE GEOMETRY IS THE PLATFORM'S — `TextLayoutResult.getBoundingBox`
 * over the layout `BasicTextField` handed out, and the field's own
 * `ScrollState` — so nothing here models where text is. It scrolls
 * MINIMALLY, which is what every other backend's scroll-to-range does
 * and what `bringIntoView` measured on this one (range-probe-android.md
 * §3): the range lands at the viewport edge, not centred. How much
 * context that leaves is native behaviour, which is exactly why the
 * observable kaya fixes is CONTAINMENT and never the viewport itself.
 *
 * A PURE EFFECT: it touches no selection and no composition (measured,
 * §5 — only the selection route disturbs a composing region), so reveal
 * has no refusal arm and needs none.
 */
internal suspend fun kayaRevealRange(node: KayaNode, range: KayaRange) {
    val layout = kayaTextLayouts[node.id]?.invoke() ?: return
    val box = kayaRangeBox(node, range) ?: return
    val scroll = node.scrollState
    val viewport = kayaViewportHeight(layout, scroll)
    if (viewport <= 0) return
    val at = scroll.value
    val target =
        when {
            box.first < at -> box.first
            box.second > at + viewport -> box.second - viewport
            else -> return
        }
    scroll.scrollTo(target.coerceIn(0, scroll.maxValue))
}

/**
 * The (top, bottom) of a range in the field's own text coordinates, from
 * the layout the platform published — null when there is no layout yet.
 *
 * ONE HELPER FOR BOTH DIRECTIONS, deliberately: the reveal scrolls until
 * this box is inside the viewport and `expect_revealed` asks whether it
 * is, so the two cannot disagree about what "the range" means while
 * disagreeing about whether it is on screen.
 */
/**
 * THE VIEWPORT'S HEIGHT, in the one spelling this field publishes:
 * content height minus how far it can scroll.
 *
 * `ScrollState.viewportSize` IS NOT IT and reads 0 here — measured
 * 2026-08-06 on this backend: `TextFieldCoreModifier` sets `maxValue`
 * (548 for a 644px layout in a 96px box) and never touches
 * `viewportSize`, which only `Modifier.verticalScroll`'s own measure
 * policy writes. A read that trusted that field would call every range
 * `<no viewport>` forever, which is how this was found.
 *
 * Both numbers are the platform's, so the arithmetic states a fact
 * rather than modelling one: content - scrollable = what fits. When the
 * content fits entirely, maxValue is 0 and this is the content height,
 * so containment is true for every range — which is the right answer.
 */
internal fun kayaViewportHeight(
    layout: androidx.compose.ui.text.TextLayoutResult,
    scroll: androidx.compose.foundation.ScrollState,
): Int = layout.size.height - scroll.maxValue

internal fun kayaRangeBox(node: KayaNode, range: KayaRange): Pair<Int, Int>? {
    val layout = kayaTextLayouts[node.id]?.invoke() ?: return null
    val length = node.textState.text.length
    if (length == 0) return null
    // getBoundingBox indexes a CHARACTER, so a half-open range's end is
    // one past the last one it covers, and a degenerate range (a caret)
    // still names the character it sits before.
    val first = range.start.coerceIn(0, length - 1)
    val last = (if (range.stop > range.start) range.stop - 1 else range.start)
        .coerceIn(0, length - 1)
    val a = layout.getBoundingBox(first)
    val b = layout.getBoundingBox(last)
    return Pair(minOf(a.top, b.top).toInt(), maxOf(a.bottom, b.bottom).toInt())
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
fun KayaRender(
    node: KayaNode,
    isRoot: Boolean = false,
    flexVertical: Boolean? = null,
    flexStretch: Boolean = false,
) {
    val attachment = KayaSceneModel.contextMenus[node.id]
    if (attachment == null) {
        KayaRenderCore(node, isRoot, flexVertical, flexStretch)
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
        KayaRenderCore(node, isRoot, flexVertical, flexStretch)
        val open = KayaSceneModel.openContextWidget == node.id
        DropdownMenu(
            expanded = open,
            onDismissRequest = { KayaSceneModel.openContextWidget = null },
        ) {
            KayaMenuPopupRoot()
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
                                modifier = Modifier.testTag(kayaMenuTag(root.id)),
                                leadingIcon = kayaSymbolSlot(root.symbol),
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
private fun KayaRenderCore(
    node: KayaNode,
    isRoot: Boolean = false,
    /**
     * The MAIN AXIS of the flex container this node is a child of —
     * true inside a column, false inside a row — and null wherever grow
     * has no meaning: a grid cell, a scroll's content, the mounted root.
     *
     * A control whose natural size is a fixed box needs this to honour
     * grow: a grower's extent is the cell its weight earned on THIS
     * axis, and the control can only fill the right dimension if it
     * knows which one that is. Filling both would take the cross axis
     * too, which is align's business — GTK gives a grown textarea its
     * natural 240 across a start-aligned column, and this backend must
     * not disagree.
     */
    flexVertical: Boolean? = null,
    /**
     * Whether that container aligns its children `stretch` — the CROSS
     * axis's half of the same question [flexVertical] answers for the
     * main one. Only controls whose natural size is a fixed box need it;
     * everything else already fills the cell it is given.
     */
    flexStretch: Boolean = false,
) {
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
                // The inset pair brackets the padding (see the column's
                // note).
                modifier = a11y.onGloballyPositioned {
                    kayaInsetOuter[node.id] =
                        Pair(it.size.width.toDouble(), it.size.height.toDouble())
                }.padding(node.inset.dp).onGloballyPositioned {
                    kayaInsetInner[node.id] =
                        Pair(it.size.width.toDouble(), it.size.height.toDouble())
                },
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
                // The inset pair brackets the container's own padding
                // (see kayaInsetOuter): outer box, then padding, then
                // the content readers — so the extents shares divide
                // are the CONTENT box, which is identical at inset 0.
                modifier = rootFill.then(a11y).onGloballyPositioned {
                    kayaInsetOuter[node.id] =
                        Pair(it.size.width.toDouble(), it.size.height.toDouble())
                }.padding(node.inset.dp).onGloballyPositioned {
                    kayaInsetInner[node.id] =
                        Pair(it.size.width.toDouble(), it.size.height.toDouble())
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
                    // The reader INSIDE the cell sees what the child
                    // drew; the one on the cell sees the track. Both, or
                    // expect_fills on a widget cannot tell a control
                    // that filled its cell from one that ignored it.
                    Box(cell) {
                        Box(
                            Modifier.onGloballyPositioned {
                                kayaDrawnExtents[child.id] = it.size.height.toDouble()
                            }
                        ) {
                            KayaRender(
                                child,
                                flexVertical = true,
                                flexStretch = node.align == KayaCompose.ALIGN_STRETCH,
                            )
                        }
                    }
                }
            }
        KayaCompose.KIND_BUTTON ->
            // THE ROLE TIER, in M3's own emphasis ladder
            // (docs/styling-plan.md D4). Material's buttons are one
            // component with four dressings, and the ladder is the
            // platform's, not kaya's: filled is the highest emphasis
            // Material offers, outlined the medium one.
            //
            // Which puts the FLOOR at outlined, and that is a deliberate
            // move rather than a leftover: a roleless button used to be
            // the filled one, which left `prominent` with nowhere to go
            // — the same button, and a role that changed nothing is
            // exactly the silent no-op this pass exists to refuse. It
            // also puts this backend where the other three already are
            // (bordered -> borderedProminent on Apple, plain ->
            // .suggested-action on GTK, standard -> AccentButtonStyle on
            // WinUI): a neutral floor, and the accent reserved for the
            // one primary action.
            //
            // DESTRUCTIVE takes the error-role container. Material has no
            // destructive button either, but unlike Fluent it has a
            // colour PAIR that means error and carries its own legible
            // foreground, and that pair is fixed by Material rather than
            // derived from the brand — red keeps meaning destructive in a
            // red-branded app. Never `Color.Red`: the role, so the
            // platform stays the judge of the shade.
            when (node.role) {
                KayaCompose.ROLE_PROMINENT ->
                    Button(onClick = { KayaPresent.emitClicked(node.tag) }, modifier = a11y) {
                        // A button's label is Material's OWN rung —
                        // `Button` provides labelLarge internally — so
                        // this is the ramp route sampled through a
                        // component kaya never styles (see
                        // kayaTypefaceSites).
                        Text(node.text, onTextLayout = { kayaTypefaceSites["button"] = it })
                    }
                KayaCompose.ROLE_DESTRUCTIVE ->
                    Button(
                        onClick = { KayaPresent.emitClicked(node.tag) },
                        modifier = a11y,
                        colors = ButtonDefaults.buttonColors(
                            containerColor = MaterialTheme.colorScheme.errorContainer,
                            contentColor = MaterialTheme.colorScheme.onErrorContainer,
                        ),
                    ) {
                        Text(node.text, onTextLayout = { kayaTypefaceSites["button"] = it })
                    }
                else ->
                    OutlinedButton(
                        onClick = { KayaPresent.emitClicked(node.tag) },
                        modifier = a11y,
                    ) {
                        Text(node.text, onTextLayout = { kayaTypefaceSites["button"] = it })
                    }
            }
        KayaCompose.KIND_ROW ->
            // Normalized default: children packed to the leading edge at
            // natural size, top-aligned (Alignment.Top), 8 dp between them.
            Row(
                // The inset pair brackets the padding (see the column's
                // note).
                modifier = rootFill.then(a11y).onGloballyPositioned {
                    kayaInsetOuter[node.id] =
                        Pair(it.size.width.toDouble(), it.size.height.toDouble())
                }.padding(node.inset.dp).onGloballyPositioned {
                    kayaInsetInner[node.id] =
                        Pair(it.size.width.toDouble(), it.size.height.toDouble())
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
                    // The drawn-extent reader, the column arm's sibling.
                    Box(cell) {
                        Box(
                            Modifier.onGloballyPositioned {
                                kayaDrawnExtents[child.id] = it.size.width.toDouble()
                            }
                        ) {
                            KayaRender(
                                child,
                                flexVertical = false,
                                flexStretch = node.align == KayaCompose.ALIGN_STRETCH,
                            )
                        }
                    }
                }
            }
        KayaCompose.KIND_LABEL ->
            // The heading role is BOTH facts at once (docs/styling-plan.md
            // D4): Compose's `heading()` semantics — which is how an
            // assistive user SKIMS, and the half every platform publishes,
            // so it is the half the styling scene freezes on every lane —
            // and a tier of Material's own type ramp. titleLarge is the
            // ramp's own section-heading tier; picking a tier is not
            // changing the scale, which is the line DESIGN.md draws and
            // KayaTheme's note keeps.
            if (node.role == KayaCompose.ROLE_HEADING) {
                Text(
                    node.text,
                    style = MaterialTheme.typography.titleLarge,
                    // A SAMPLE OF THE RAMP ROUTE for expect_typeface's
                    // read (see kayaTypefaceSites): this label is the
                    // one that takes its style from `typography`, so it
                    // is the site that goes on reading the platform face
                    // if the theme's first write is missing.
                    onTextLayout = { kayaTypefaceSites["heading"] = it },
                    modifier = a11y.semantics { heading() },
                )
            } else {
                // And the AMBIENT route's sample: a plain label reads
                // LocalTextStyle, the write the ramp cannot stand in for.
                Text(
                    node.text,
                    onTextLayout = { kayaTypefaceSites["label"] = it },
                    modifier = a11y,
                )
            }
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
        KayaCompose.KIND_TEXTAREA ->
            KayaTextField(
                node,
                a11y,
                singleLine = false,
                flexVertical = flexVertical,
                flexStretch = flexStretch,
            )
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
fun KayaTextField(
    node: KayaNode,
    a11y: Modifier,
    singleLine: Boolean,
    flexVertical: Boolean? = null,
    flexStretch: Boolean = false,
) {
    // THE TEXTAREA'S LAYOUT FLOOR, AND THE ONE PLACE `grow` REACHES IT.
    //
    // The line limits below are a FLOOR AND A CEILING in lines, which is
    // what bounds an unweighted field — but a GROWER's size is the cell
    // its weight earned, and a field that ignored that cell rendered
    // three lines tall inside it while the cell (which expect_shares
    // reads) was exactly right. So a grower fills its cell on the
    // container's MAIN AXIS, and only there: the cross axis is align's
    // business, and the other backends give a grown textarea its natural
    // breadth across a start-aligned container.
    val grown = when {
        node.grow <= 0 -> Modifier
        flexVertical == true -> Modifier.fillMaxHeight()
        flexVertical == false -> Modifier.fillMaxWidth()
        else -> Modifier
    }
    // AND THE CROSS AXIS IS ALIGN'S, by the same argument one axis over:
    // `stretch` says every child spans the container's breadth, and a
    // control with a fixed natural box has to be told, exactly as a
    // grower does. GTK's size request and WinUI's MinWidth are minima
    // their FILL/Stretch alignment already grows from; this arm and the
    // SwiftUI one had to say it.
    val stretched = when {
        !flexStretch -> Modifier
        flexVertical == true -> Modifier.fillMaxWidth()
        flexVertical == false -> Modifier.fillMaxHeight()
        else -> Modifier
    }
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
        // THE TEXTAREA IS A BOUNDED EDITOR WITH ITS OWN VIEWPORT, which
        // is what every other backend's already is — macOS an NSTextView
        // in its scroll view at 240x96, GTK a GtkTextView inside the
        // GtkScrolledWindow the textarea foundation gave it at the same
        // size, WinUI a RichEditBox. Compose's was the one that GREW:
        // `MultiLine(minHeightInLines = 3)` leaves the maximum at
        // Int.MAX_VALUE, so a 40-line document rendered 2496px tall
        // (measured, range-probe-android.md §0.2) with nothing able to
        // scroll it — and reveal is then not a hard feature, it is an
        // UNRUNNABLE one: `expect_revealed offscreen` would be true
        // forever. Bounding it here uses the field's OWN scroll rather
        // than a verticalScroll wrapper, which would also cost the
        // field's keep-the-caret-visible behaviour while typing.
        lineLimits =
            if (singleLine) TextFieldLineLimits.SingleLine
            else TextFieldLineLimits.MultiLine(
                minHeightInLines = 3, maxHeightInLines = KAYA_TEXTAREA_LINES),
        // The viewport's REAL state, owned here rather than remembered
        // inside the field, because reveal drives it and expect_revealed
        // reads it — the same ScrollState `expect_at_end` already reads
        // off a scroll node.
        scrollState = node.scrollState,
        // The platform's own text layout, kept as the PROVIDER LAMBDA
        // and not as a result: reading it stays in the layout/draw phase
        // and never invalidates composition. Measured on this backend
        // (§1c): the naive spelling — hoist the ranges into the
        // composable body — recomposed the field 200 times in 200
        // frames, where the draw-scope read recomposes zero times and
        // re-lays-out zero times.
        onTextLayout = { layout -> kayaTextLayouts[node.id] = layout },
        interactionSource = interaction,
        textStyle = LocalTextStyle.current.copy(color = LocalContentColor.current),
        modifier = a11y
            .then(grown)
            .then(stretched)
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
                // THE HIGHLIGHT LAYER GOES AROUND THE INNER FIELD, not
                // around the decoration: the inner field IS the scrolling
                // viewport, so a decoration-level draw would sit still
                // while the text moved under it.
                innerTextField = { KayaHighlightLayer(node, inner) },
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
    // THE REVEAL ONE-SHOT, keyed on the sequence rather than consuming
    // the request: a recomposition for any other reason re-runs nothing,
    // and a second reveal of the SAME range still runs. It has to be an
    // effect rather than an apply arm because a scroll needs the field's
    // layout, which does not exist until a pass has run.
    LaunchedEffect(node.revealSeq) {
        if (node.revealSeq > 0) node.revealRequest?.let { kayaRevealRange(node, it) }
    }
}

/**
 * THE DECORATED RANGES, painted behind the text from the platform's own
 * layout — the whole highlight lowering, and the reason it is a DRAW and
 * not a styled string.
 *
 * THERE IS NO STYLING HOOK ON THIS FIELD, compile-proven at kaya's pins
 * (range-probe-android.md §1a): `BasicTextField(state=)` has no
 * `visualTransformation` — that parameter exists only on the
 * `value:`/`TextFieldValue:` overloads the undo milestone deliberately
 * left — `OutputTransformation` can only EDIT text
 * (`TextFieldBuffer` has no style API at all), and the
 * `TextHighlightType` the state does carry is one range, Kotlin-internal,
 * and means stylus preview. THE TRAP IS THE FOURTH ROUTE: an
 * `AnnotatedString` IS a `CharSequence`, so `state.edit { replace(0,
 * length, annotated) }` COMPILES CLEAN, and the state stores it as a
 * plain String and paints NOTHING — measured, zero highlight pixels. A
 * backend that "supported" highlight that way would pass every compile
 * gate in this repo and decorate nothing on screen.
 *
 * So the ranges are drawn, and drawn onto `getPathForRange`, which
 * handles a wrapped range and bidi where a hand-rolled per-line rect
 * does not — the probe's own rect helper got a range crossing a line
 * break subtly wrong while the path matched the pixels to within one.
 *
 * PHASE DISCIPLINE IS THE RULE THIS PLACE EXISTS TO KEEP. Everything the
 * paint depends on is read INSIDE the draw lambda: the declared set, the
 * text it was declared against, the live text and the scroll offset. A
 * read hoisted into the composable body recomposes the field on every
 * re-declaration (measured: 200 recompositions in 200 frames, against
 * zero here), and at 40 lines it would still fit inside a frame — so it
 * would never fail a lane and would only ever show up on somebody's real
 * document.
 */
@Composable
private fun KayaHighlightLayer(node: KayaNode, inner: @Composable () -> Unit) {
    // THE WASH THIS LAYER IS PAINTED UNDER, taken from the composition
    // that will paint it. Read in the body because a CompositionLocal can
    // only be read here — it is not snapshot state that moves per
    // declaration, so the phase rule below is untouched — and PUBLISHED
    // inside the draw, beside the record, so the witness never reads a
    // colour from a composition that did not draw.
    val wash = androidx.compose.foundation.text.selection.LocalTextSelectionColors
        .current.backgroundColor.toArgb()
    androidx.compose.foundation.layout.Box(
        propagateMinConstraints = true,
        modifier = Modifier
            // The viewport's rectangle in the window, for the paint
            // witness. This box IS the scrolling viewport — measured
            // 2026-08-06: 96px tall around a 644px layout — so it is
            // both what gets clipped and what a photograph must cover.
            .onGloballyPositioned {
                val r = it.boundsInWindow()
                kayaTextBoxes[node.id] = android.graphics.Rect(
                    r.left.toInt(), r.top.toInt(), r.right.toInt(), r.bottom.toInt())
            }
            .drawBehind {
            // D2's CLEAR-ON-EDIT, made structural. The set is painted
            // only while the field still holds the text it was declared
            // against, so a keystroke, a programmatic write or a native
            // undo drops it HERE, at paint time, with nothing sent and
            // nothing remembered. A message from the core could not do
            // this job: the measured hazard of this milestone is a text
            // change arriving after the thing declared over it, and a
            // compare made on the pass that paints cannot arrive late.
            //
            // It is also not belt-and-braces for the platform. Stale
            // offsets on this backend are a WRONG highlight rather than
            // a crash — measured (§1c): after prepending three
            // characters the old offsets kept painting at the old glyph
            // positions until re-declared. Painting a stale set is
            // exactly what D2 refuses to ship.
            val live = node.textState.text.toString()
            val paint =
                if (node.highlightsFor == live) node.highlights else emptyList()
            // WHAT WAS ACTUALLY PAINTED, published from the only place
            // the answer is true. expect_highlights reads this and not
            // the declaration, so a verb cannot pass on kaya's intent.
            kayaPaintedRanges[node.id] = paint
            kayaSelectionWash[node.id] = wash
            if (paint.isEmpty()) return@drawBehind
            val layout = kayaTextLayouts[node.id]?.invoke() ?: return@drawBehind
            // The field scrolls its text inside this box, so the paint
            // moves with it. Clipped for the same reason: a range below
            // the viewport must not bleed over the decoration.
            val scrolled = node.scrollState.value.toFloat()
            clipRect {
                translate(top = -scrolled) {
                    for (r in paint) {
                        if (r.start < 0 || r.start > r.stop || r.stop > live.length) continue
                        drawPath(
                            layout.getPathForRange(r.start, r.stop),
                            KAYA_HIGHLIGHT_COLOR)
                    }
                }
            }
        },
    ) {
        inner()
    }
}

/** How many lines of the textarea are on screen at once — this host's
 * spelling of the 240x96 viewport the desktop backends give it. */
private const val KAYA_TEXTAREA_LINES = 6

/** The decoration itself. A background wash under the glyphs, which is
 * the same thing every other backend paints (NSTextStorage's
 * .backgroundColor, a GtkTextTag, CharacterFormat.BackColor) — chosen
 * there because it is what accessibility publishes, and matched here so
 * one scene describes one appearance. */
private val KAYA_HIGHLIGHT_COLOR = androidx.compose.ui.graphics.Color(0x8CFFEB3B)

/**
 * TONE, the number Material's whole colour system is built on: HCT's T
 * is CIE L*, so a tone is perceptual lightness and a TONE DIFFERENCE IS
 * A CONTRAST GUARANTEE — that is the property every rule below leans on.
 *
 * Read through Compose's own colour-space machinery (`ColorSpaces.CieLab`
 * is D50, and the connector Bradford-adapts sRGB's D65 into it), so the
 * number here is the number material3 itself works in.
 */
private fun Color.kayaTone(): Float = convert(ColorSpaces.CieLab).red

/**
 * The seed's palette AT A TONE — the one piece of colour maths this
 * backend does, and it is Material's own: material3 computes the tones
 * the platform does not publish exactly this way (`setLuminance` in
 * DynamicTonalPalette.android.kt — convert to CIELab, keep the a and b
 * axes, set L), and this is that function with one thing added.
 *
 * THE THING ADDED IS THE GAMUT LOOP, and without it the derivation is
 * wrong in the direction that matters. A saturated seed at tone 90 has
 * no sRGB representative: the conversion CLIPS, and a clipped colour
 * lands at some other lightness — measured, Adwaita blue #3584E4 at tone
 * 90 comes back at L* 78 unclipped-naive, which quietly destroys the
 * contrast the tone was chosen for. HCT solves this by keeping the tone
 * and giving up chroma (that IS its "closest in-gamut colour at this
 * tone"), so this bisects the seed's chroma for the most colourful
 * candidate whose REALIZED tone is the one asked for, within half a
 * tone. Aim, measure, correct — the same shape as the core's own
 * danger-band clamp (crates/kaya/src/brand.rs), for the same reason:
 * a number nobody measured back is a number nobody has.
 *
 * Degenerate seeds fall out right: white and black have no chroma to
 * keep, so every tone of them is the grey at that tone.
 */
private fun kayaToneOf(seed: Color, tone: Float): Color {
    val lab = seed.convert(ColorSpaces.CieLab)
    // The chroma-free candidate always realizes its tone exactly; it is
    // the floor the bisection falls back to.
    var best = Color(tone, 0f, 0f, colorSpace = ColorSpaces.CieLab).convert(ColorSpaces.Srgb)
    var lo = 0f
    var hi = 1f
    repeat(12) {
        val mid = (lo + hi) / 2f
        val candidate =
            Color(tone, lab.green * mid, lab.blue * mid, colorSpace = ColorSpaces.CieLab)
                .convert(ColorSpaces.Srgb)
        if (kotlin.math.abs(candidate.kayaTone() - tone) <= 0.5f) {
            best = candidate
            lo = mid
        } else {
            hi = mid
        }
    }
    return best
}

/** Y (relative luminance, 0..100) at a tone — CIE's own inverse, and
 * what a contrast ratio is computed from. */
private fun kayaYFromTone(tone: Float): Float {
    val ft = (tone + 16f) / 116f
    val cubed = ft * ft * ft
    return 100f * if (cubed > 216f / 24389f) cubed else (116f * ft - 16f) / (24389f / 27f)
}

/** The contrast ratio between two tones, the WCAG formula on Y. */
private fun kayaRatioOfTones(a: Float, b: Float): Float {
    val hi = kotlin.math.max(kayaYFromTone(a), kayaYFromTone(b))
    val lo = kotlin.math.min(kayaYFromTone(a), kayaYFromTone(b))
    return (hi + 5f) / (lo + 5f)
}

/**
 * A CONTRAST CURVE — Material's own type, four values indexed by the
 * contrast level (its class doc: "The four values correspond to values
 * for contrast levels -1.0, 0.0, 0.5, and 1.0"), linearly interpolated
 * between them. Every role below carries the curve
 * material-color-utilities gives it, quoted in the derivation.
 */
private fun kayaContrastAt(
    level: Float,
    low: Float,
    normal: Float,
    medium: Float,
    high: Float,
): Float = when {
    level <= -1f -> low
    level < 0f -> low + (normal - low) * (level + 1f)
    level < 0.5f -> normal + (medium - normal) * (level / 0.5f)
    level < 1f -> medium + (high - medium) * ((level - 0.5f) / 0.5f)
    else -> high
}

/**
 * A ROLE'S TONE: the nominal one if it already meets the contrast its
 * curve asks for against its own background, else the one
 * `DynamicColor.foregroundTone` would pick — walked a tone at a time
 * rather than solved analytically (the two agree to within a tone, and a
 * walk cannot return an out-of-range answer).
 *
 * BOTH DIRECTIONS ARE WEIGHED, and that is not a refinement: walking one
 * way is wrong in exactly the case the contrast slider creates, measured
 * on emulator-5554 before this rule had the second half. At high
 * contrast the container tone is pulled down to ~45 to clear the page,
 * and a rule that only walked "away from the background" then took
 * onPrimaryContainer DOWN to black — 3.9:1 — when white above it was
 * 5.4:1. So: a background below tone 60 wants a LIGHT foreground and one
 * at or above it wants a dark one (Material's
 * `tonePrefersLightForeground`), and the other side wins anyway when the
 * preferred one cannot reach the ratio and it can.
 *
 * Either candidate CLAMPS at 0 or 100 rather than failing, which is
 * Material's `lighterUnsafe`/`darkerUnsafe`: its own light `onPrimary` is
 * tone 100 against a tone-40 primary — 6.1:1 where the curve asks 7 —
 * because there is nothing lighter than white.
 */
private fun kayaRoleTone(nominal: Float, background: Float, desired: Float): Float {
    if (kayaRatioOfTones(nominal, background) >= desired) return nominal
    var lighter = 100f
    var tone = background
    while (tone < 100f) {
        tone += 1f
        if (kayaRatioOfTones(tone, background) >= desired) {
            lighter = tone
            break
        }
    }
    var darker = 0f
    tone = background
    while (tone > 0f) {
        tone -= 1f
        if (kayaRatioOfTones(tone, background) >= desired) {
            darker = tone
            break
        }
    }
    val lighterRatio = kayaRatioOfTones(lighter, background)
    val darkerRatio = kayaRatioOfTones(darker, background)
    return if (background < 60f) {
        if (lighterRatio >= desired || lighterRatio >= darkerRatio) lighter else darker
    } else {
        if (darkerRatio >= desired || darkerRatio >= lighterRatio) darker else lighter
    }
}

/**
 * The colour schemes this backend composes under — Material's baseline
 * until an app requests a brand, and the SEED'S OWN SCHEME once it does.
 *
 * WHY THIS BACKEND DERIVES AT ALL, when the rule everywhere else is that
 * the core derives and backends apply values (docs/styling-plan.md D1):
 * Material's colour system IS a derivation from one seed hex, published
 * and deterministic, and kaya defers to a platform's own model wherever
 * one exists rather than fighting it. So the wire's ten derived words are
 * for the backends whose platforms have no such model, and this one takes
 * the seed.
 *
 * WHAT IS DERIVED, AND WHAT DELIBERATELY IS NOT. The PRIMARY family —
 * the accent — is computed from the seed: primary, onPrimary,
 * primaryContainer, onPrimaryContainer, inversePrimary and surfaceTint,
 * at the tones color_spec_2021.ts assigns them, with each role's own
 * contrast curve. The secondary/tertiary/neutral palettes and the error
 * palette stay Material's baseline. Two different reasons, and neither is
 * "not yet":
 *
 *  - The ERROR palette is fixed by Material itself (SchemeTonalSpot
 *    hands it a fixed palette rather than deriving one), because red
 *    means destructive whatever an app's brand is. kaya's destructive
 *    role reads those roles, and they must not follow the seed.
 *  - The NEUTRALS carry chroma 4 and 8 in Material's own scheme, i.e.
 *    they are grey with a hint of the seed — the visible difference
 *    between one seed's surfaces and another's is a couple of levels per
 *    channel. Reproducing that hint needs HCT's chroma clamping, which is
 *    a dependency question (material-color-utilities is not published as
 *    a first-party Maven artifact; MDC bundles it @RestrictTo) rather
 *    than a coding one, and it is recorded for Akhil rather than decided
 *    here. What the accent buys and the neutrals do not is the reason the
 *    split is defensible: every other backend applies the accent to its
 *    accent slots and nothing else.
 *
 * Not a composable and not remembered: a scheme is a value. The caller
 * keys it on (seed, appearance, contrast) — the three inputs it has.
 */
internal object KayaColorSchemes {
    val light: ColorScheme = lightColorScheme()
    val dark: ColorScheme = darkColorScheme()

    /**
     * @param seed the requested brand accent, packed 0xRRGGBB, or null
     *   for "the app asked for nothing" — which is Material's baseline,
     *   NOT the wallpaper palette: opting into dynamic colour is a
     *   ratified non-goal for v1 (docs/styling-plan.md D2).
     * @param dark the appearance to build for.
     * @param contrast the system contrast level, -1..1, 0 = default —
     *   Material's own scale, and the input a STATIC scheme silently
     *   ignores (MDC #3524). Every role's tone below moves with it.
     */
    fun of(seed: Int?, dark: Boolean, contrast: Float): ColorScheme {
        val base = if (dark) this.dark else this.light
        if (seed == null) return base
        val key = Color(0xFF000000.toInt() or seed)
        // The background these roles are read against. MEASURED off the
        // scheme actually in force rather than assumed from the spec's
        // surface tones, because this scheme's neutrals are Material's
        // and a tone written down here would be a second copy of them.
        val surfaceTone = base.surface.kayaTone()
        // Tones and curves verbatim from color_spec_2021.ts (the
        // TONAL_SPOT arm; kaya never exposes another variant):
        //   primary            40/80, ContrastCurve(3, 4.5, 7, 7)
        //   onPrimary          100/20, ContrastCurve(4.5, 7, 11, 21)
        //   primaryContainer   90/30, ContrastCurve(1, 1, 3, 4.5)
        //   onPrimaryContainer 30/90, ContrastCurve(3, 4.5, 7, 11)
        //   inversePrimary     80/40, ContrastCurve(3, 4.5, 7, 7)
        //   surfaceTint        = primary's tone, no curve (a background)
        val primaryTone = kayaRoleTone(
            nominal = if (dark) 80f else 40f,
            background = surfaceTone,
            desired = kayaContrastAt(contrast, 3f, 4.5f, 7f, 7f),
        )
        val onPrimaryTone = kayaRoleTone(
            nominal = if (dark) 20f else 100f,
            background = primaryTone,
            desired = kayaContrastAt(contrast, 4.5f, 7f, 11f, 21f),
        )
        val containerTone = kayaRoleTone(
            nominal = if (dark) 30f else 90f,
            background = surfaceTone,
            desired = kayaContrastAt(contrast, 1f, 1f, 3f, 4.5f),
        )
        val onContainerTone = kayaRoleTone(
            nominal = if (dark) 90f else 30f,
            background = containerTone,
            desired = kayaContrastAt(contrast, 3f, 4.5f, 7f, 11f),
        )
        val inverseTone = kayaRoleTone(
            nominal = if (dark) 40f else 80f,
            background = base.inverseSurface.kayaTone(),
            desired = kayaContrastAt(contrast, 3f, 4.5f, 7f, 7f),
        )
        val primary = kayaToneOf(key, primaryTone)
        val onPrimary = kayaToneOf(key, onPrimaryTone)
        val container = kayaToneOf(key, containerTone)
        val onContainer = kayaToneOf(key, onContainerTone)
        val inverse = kayaToneOf(key, inverseTone)
        // Every role NOT named here keeps its default, and the defaults
        // of these two builders are exactly the baseline scheme above —
        // so "the rest stays Material's" is what the call itself says,
        // rather than thirty copied fields that could drift from it.
        // surfaceTint IS primary in Material's spec (same palette, same
        // tone), which is how an elevated surface picks up the brand.
        return if (dark) {
            darkColorScheme(
                primary = primary,
                onPrimary = onPrimary,
                primaryContainer = container,
                onPrimaryContainer = onContainer,
                inversePrimary = inverse,
                surfaceTint = primary,
            )
        } else {
            lightColorScheme(
                primary = primary,
                onPrimary = onPrimary,
                primaryContainer = container,
                onPrimaryContainer = onContainer,
                inversePrimary = inverse,
                surfaceTint = primary,
            )
        }
    }
}

// --- THE BRAND TYPEFACE (docs/styling-plan.md Slice 2b) --------------
//
// Measured before written (styling/typeface-compose.md, on the lane's
// own API 35 image), and three of those findings decide the shape of
// everything below.
//
// ONE WRITE IS NOT ENOUGH — this backend needs TWO, and the measurement
// is what says so. `MaterialTheme`'s `typography` argument brands
// Material's OWN components; kaya's labels and text fields never read
// it, because KayaTheme deliberately holds `LocalTextStyle` at its
// PRE-theme value (see its note) and that local is what
// `KIND_LABEL -> Text(…)` and `textStyle = LocalTextStyle.current…`
// read. Measured with `typography` alone: the Button moved to Noto Serif
// while the plain label stayed on ROBOTO at exactly its unbranded width
// — a half-branded window that still looks branded, which is the state a
// coarse observation calls applied.
//
// THE READS THAT LOOK RIGHT ARE ECHOES OF THE REQUEST.
// `layoutInput.style.fontFamily` is the request by construction, and
// `Typeface.getSystemFontFamilyName()` — which has the right type and
// reads like a resolved-face read — returns the KEY the Typeface was
// created with: `georgia` for a font that shaped as Noto Serif,
// `courier new` for one that shaped as Cutive Mono, and null for a face
// loaded from bytes. The honest read is the shaped glyph run's own font
// FILE, named out of that file's OpenType `name` table; nothing in that
// chain can carry the requested string.
//
// THE FALLBACK IS TOTAL AND SILENT. A family this device does not have
// renders as Roboto, pixel-identical to declaring no brand at all (three
// screenshots sharing one md5), and `FontFamily.Resolver.preload` — the
// API that documents itself as throwing for a font that cannot load —
// returned ok for every nonsense name. The sentinel probe below is what
// actually detects it.

/**
 * The string the resolved-face reads shape. Latin, because every UI face
 * on every lane covers it: a probe the resolved font lacks would be
 * shaped by a FALLBACK font and report the fallback's family, which is a
 * true answer to the wrong question.
 */
private const val KAYA_TYPEFACE_PROBE = "Handgloves"

/**
 * TWO SENTINELS, which is what makes the apply-time miss detector
 * device-independent.
 *
 * The mechanism (styling/typeface-compose.md §3.2): Compose's
 * `DeviceFontFamilyName` loader returns null for a family the device
 * does not have, and the FontFamily then falls through to the next font
 * in its list — so landing on a sentinel IS the miss. ONE sentinel would
 * need a name-vs-face comparison to spot the landing, and would
 * misreport the app that asks for the sentinel's own family; two need
 * neither. Resolve the requested name with A appended, and again with B
 * appended: if the name loads, both shape in the SAME face; if it does
 * not, one shapes as A and the other as B.
 *
 * They are two of the four AOSP-baseline generic names, the only font
 * vocabulary Android guarantees on an arbitrary device — and the
 * detector still refuses a verdict rather than assuming it, by checking
 * HERE that A and B are different faces (a device resolving both to one
 * face would otherwise make every family look present).
 */
private const val KAYA_TYPEFACE_SENTINEL_A = "cursive"
private const val KAYA_TYPEFACE_SENTINEL_B = "monospace"

/** A resolved face as the shaper reports it: the family out of the
 *  font's own `name` table, the file it came from, and the variation
 *  axes that pick the instance. The family ALONE cannot always tell two
 *  device families apart — Android 15 ships Roboto as a variable font,
 *  so `sans-serif` and `sans-serif-condensed` are one FILE at wdth=100
 *  and wdth=75 — so the identity carries all three: the observation
 *  reports the family, and the rest is logged beside it. */
internal class KayaFace(val family: String, val file: String, val axes: String) {
    override fun toString(): String = "$family (file=$file axes=[$axes])"
}

/**
 * The FAMILY NAME out of a font file's OpenType `name` table.
 *
 * This is the link in the read that cannot echo: the buffer is the file
 * the shaper picked, and the name comes out of that file's own bytes.
 * nameID 16 (typographic family) when the font has one, else nameID 1
 * (font family) — 16 is what groups a family whose weights carry their
 * own nameID 1 ("Roboto Condensed Light"). Windows and Unicode records
 * are UTF-16BE; the Macintosh record is a byte encoding whose ASCII
 * range is all a family name uses in practice.
 *
 * Null when the buffer is not a font this parser can walk, which is a
 * real answer and reads as a mismatch rather than as a pass.
 */
private fun kayaFontFamilyName(buffer: java.nio.ByteBuffer, ttcIndex: Int): String? {
    val b = buffer.duplicate().order(ByteOrder.BIG_ENDIAN)
    fun u16(at: Int) = b.getShort(at).toInt() and 0xffff
    return try {
        var base = 0
        // A collection: 'ttcf', then version, count, and the offsets.
        if (b.limit() >= 16 && b.getInt(0) == 0x74746366) {
            if (ttcIndex >= b.getInt(8)) return null
            base = b.getInt(12 + 4 * ttcIndex)
        }
        var nameAt = -1
        for (i in 0 until u16(base + 4)) {
            val rec = base + 12 + 16 * i
            if (b.getInt(rec) == 0x6e616d65) { // 'name'
                nameAt = b.getInt(rec + 8)
                break
            }
        }
        if (nameAt < 0) return null
        val count = u16(nameAt + 2)
        val storage = nameAt + u16(nameAt + 4)
        var best: String? = null
        var bestScore = -1
        for (i in 0 until count) {
            val rec = nameAt + 6 + 12 * i
            val platform = u16(rec)
            val nameId = u16(rec + 6)
            if (nameId != 1 && nameId != 16) continue
            // Preference, highest first: the typographic family over the
            // plain one, a Unicode-encoded record over a byte one.
            val unicode = platform == 3 || platform == 0
            val score = (if (nameId == 16) 2 else 0) + (if (unicode) 1 else 0)
            if (score <= bestScore) continue
            val len = u16(rec + 8)
            val at = storage + u16(rec + 10)
            val bytes = ByteArray(len)
            for (j in 0 until len) bytes[j] = b.get(at + j)
            best = String(bytes, if (unicode) Charsets.UTF_16BE else Charsets.ISO_8859_1)
            bestScore = score
        }
        best
    } catch (e: IndexOutOfBoundsException) {
        // A truncated or malformed table, said rather than crashed. The
        // caller turns null into a sentence no scene can assert.
        Log.w("kaya", "kaya: the font's name table could not be read: $e")
        null
    }
}

/**
 * THE HONEST READ, one face: shape [KAYA_TYPEFACE_PROBE] with a resolved
 * `Typeface` and ask the resulting glyph run which FONT it came from
 * (styling/typeface-compose.md §2.2).
 *
 * `TextRunShaper` is API 31. Below that the platform offers no supported
 * way to ask which font a run used, and the honest answer is null —
 * which the callers turn into a sentence naming the API level, never
 * into a family name nobody measured.
 */
private fun kayaShapedFace(typeface: android.graphics.Typeface): KayaFace? {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return null
    val paint = android.graphics.Paint().apply {
        this.typeface = typeface
        textSize = 100f
    }
    val glyphs = android.graphics.text.TextRunShaper.shapeTextRun(
        KAYA_TYPEFACE_PROBE, 0, KAYA_TYPEFACE_PROBE.length,
        0, KAYA_TYPEFACE_PROBE.length, 0f, 0f, false, paint,
    )
    if (glyphs.glyphCount() == 0) return null
    val font = glyphs.getFont(0)
    val axes = font.axes?.joinToString(" ") { "${it.tag}=${it.styleValue}" } ?: ""
    val family = kayaFontFamilyName(font.buffer, font.ttcIndex)
    return KayaFace(
        family ?: "the font's name table could not be read",
        font.file?.path ?: "<in memory>",
        axes,
    )
}

/** The face a `FontFamily` resolves to through [resolver], shaped and
 *  identified — the same two steps the read below takes, but against a
 *  resolver of this process's own rather than a render's, because the
 *  question here is about the DEVICE and not about a composition. */
private fun kayaResolveFace(resolver: FontFamily.Resolver, family: FontFamily): KayaFace? {
    val typeface = resolver.resolve(family, FontWeight.Normal, FontStyle.Normal).value
        as? android.graphics.Typeface ?: return null
    return kayaShapedFace(typeface)
}

/**
 * What the presence detector below can answer. TWO ways of not knowing,
 * kept apart on purpose: a diagnostic may only print what it measured,
 * and a single "cannot tell" would make the arm name one cause for a
 * state produced by the other. (Caught by the negative that forced this
 * branch to print: it blamed the API level for a device whose sentinels
 * had collided.)
 */
private enum class KayaPresence { PRESENT, ABSENT, NO_SHAPED_READ, SENTINELS_ALIKE }

/**
 * DOES THIS DEVICE HAVE THIS FAMILY? — asked at the moment the lowering
 * applies it, which is the wall invariant 3 asks for: not one more thing
 * to remember to assert in a scene, but a fact the code establishes on
 * the path nobody can avoid.
 *
 * The two not-knowing answers are real answers rather than a shrug: this
 * device cannot be asked at all (below API 31 there is no shaped-run
 * read), or the detector's own precondition does not hold here (the two
 * sentinels resolve to one face, so every family would look present). A
 * detector that guessed in either case would be printing a verdict it
 * never measured.
 *
 * NOT `preload`, which returned ok for every nonsense family, and NOT
 * `getSystemFontFamilyName()`, which is a string comparison against the
 * request (styling/typeface-compose.md §3.2).
 */
private fun kayaDeviceFamilyPresent(
    context: android.content.Context,
    name: String,
): KayaPresence {
    val resolver = createFontFamilyResolver(context)
    fun face(vararg names: String): KayaFace? =
        kayaResolveFace(resolver, FontFamily(names.map { Font(DeviceFontFamilyName(it)) }))
    val sentinelA = face(KAYA_TYPEFACE_SENTINEL_A) ?: return KayaPresence.NO_SHAPED_READ
    val sentinelB = face(KAYA_TYPEFACE_SENTINEL_B) ?: return KayaPresence.NO_SHAPED_READ
    if (sentinelA.toString() == sentinelB.toString()) return KayaPresence.SENTINELS_ALIKE
    val withA = face(name, KAYA_TYPEFACE_SENTINEL_A) ?: return KayaPresence.NO_SHAPED_READ
    val withB = face(name, KAYA_TYPEFACE_SENTINEL_B) ?: return KayaPresence.NO_SHAPED_READ
    return if (withA.toString() == withB.toString()) {
        KayaPresence.PRESENT
    } else {
        KayaPresence.ABSENT
    }
}

/**
 * The BYTES form: the blob to an app-private file, and a `FontFamily`
 * over that file. Null when the bytes are not a font.
 *
 * WHY THE CHECK IS `Typeface.Builder`, MEASURED: a corrupt blob makes
 * Compose's own `Font(File)` THROW `IllegalStateException` at RESOLVE —
 * that is, inside composition, taking the app down — while
 * `Typeface.Builder(file).build()` returns null for the same bytes
 * (styling/typeface-compose.md §6.3). So the platform's non-throwing
 * check runs first and Compose never sees a file it would die on. The
 * two request forms then fail the same way: a bad name and bad bytes
 * both fall back, neither is fatal.
 */
private fun kayaFontFromBytes(context: android.content.Context, bytes: ByteArray): FontFamily? {
    return try {
        // ONE FILE, overwritten: the brand is set once before the first
        // mount, so there is never a second font in flight.
        val file = java.io.File(context.filesDir, "kaya-brand-font")
        file.writeBytes(bytes)
        if (android.graphics.Typeface.Builder(file).build() == null) {
            Log.w("kaya", "kaya: the brand typeface's ${bytes.size} bytes are not " +
                "a font this platform can load — falling back to the family name")
            null
        } else {
            FontFamily(Font(file))
        }
    } catch (e: java.io.IOException) {
        Log.w("kaya", "kaya: the brand typeface's bytes could not be staged: $e")
        null
    }
}

/**
 * The brand typeface, RESOLVED and applied (apply 33). Both wire forms
 * land here, and on this backend they converge on the `FontFamily`
 * OBJECT rather than on a name: Android has no app-font registry at all,
 * so the plan's "register the bytes, then let the name machinery take
 * over" cannot hold here — after a blob is loaded and rendering,
 * `Typeface.create(itsFamilyName, …)` still answers Roboto
 * (styling/typeface-compose.md §6.2). One resolution, one observation,
 * one fallback; just one layer lower than on Apple.
 *
 * PRECEDENCE IS THE APPLE ARM'S, to the word: the bytes, then this
 * platform's row, then the default family. Bytes that are not a font
 * fall through to the name, exactly as a registration that failed does
 * there.
 */
internal fun kayaApplyTypeface(
    context: android.content.Context?,
    defaultFamily: String,
    picked: String?,
    fontBytes: ByteArray?,
) {
    val wanted = picked ?: defaultFamily
    if (context == null) {
        // mount() sets the activity before the pump starts, so this is
        // unreachable through it. Said rather than assumed: the
        // alternative is a brandless render with nothing anywhere naming
        // a cause.
        Log.w("kaya", "kaya: typeface $wanted arrived before the activity was " +
            "mounted — the platform ramp stands")
        KayaSceneModel.typefaceFamily = null
        return
    }
    if (fontBytes != null) {
        val fromBytes = kayaFontFromBytes(context, fontBytes)
        if (fromBytes != null) {
            KayaSceneModel.typefaceFamily = fromBytes
            return
        }
    }
    // THE PRESENCE GATE: the Apple arm's semantics on Android's
    // mechanics. A family this device does not have leaves the
    // platform's own ramp standing, and says so. Both branches render
    // the SAME pixels here — Compose's fallback for a missing family is
    // the platform default, which is what "the ramp stands" means too —
    // so what the gate buys is the sentence, on the one platform where a
    // wrong family is otherwise undetectable from inside the app.
    val present = kayaDeviceFamilyPresent(context, wanted)
    if (present == KayaPresence.ABSENT) {
        KayaSceneModel.typefaceFamily = null
        Log.w("kaya", "kaya: typeface $wanted is not installed — the platform ramp stands")
        return
    }
    // Every other answer APPLIES the family, including the two that
    // could not check it: applying is the app's instruction, and
    // refusing on a measurement nobody could take would be this file
    // inventing a policy. What each of those two says is what it
    // MEASURED, never one sentence for both states.
    KayaSceneModel.typefaceFamily = FontFamily(Font(DeviceFontFamilyName(wanted)))
    when (present) {
        KayaPresence.NO_SHAPED_READ -> Log.w("kaya",
            "kaya: typeface $wanted applied unverified — this device (API " +
                "${Build.VERSION.SDK_INT}) has no shaped-run read (TextRunShaper is " +
                "API 31), so a family it does not have would fall back with nothing " +
                "able to say so")
        KayaPresence.SENTINELS_ALIKE -> Log.w("kaya",
            "kaya: typeface $wanted applied unverified — the fallback probe's two " +
                "sentinels ($KAYA_TYPEFACE_SENTINEL_A, $KAYA_TYPEFACE_SENTINEL_B) " +
                "resolve to ONE face on this device, so a missing family is " +
                "indistinguishable from a present one here")
        else -> Unit
    }
}

/**
 * WHERE THE READ TAKES ITS SAMPLES: one real laid-out text per ROUTE
 * into the theme, keyed by the site that produced it.
 *
 * A ROUTE and not a widget, because the two writes are what can come
 * apart: `label` and the text fields read `LocalTextStyle`, while
 * `heading` and `button` read the typography ramp (Material's own
 * components provide their rung internally). A read that sampled one
 * side would call a half-applied lowering applied — the measured failure
 * mode the two writes exist for.
 *
 * Written during LAYOUT, so a plain map like [kayaTextLayouts] and not
 * snapshot state: a snapshot write in the layout pass invalidates the
 * pass that wrote it.
 *
 * A sample can OUTLIVE the node that made it — nothing removes an entry
 * when a label leaves the tree — and that is safe here for a reason
 * worth stating rather than assuming: the key is a ROUTE, not a widget,
 * and the brand typeface is set ONCE before the first mount, so every
 * sample a route ever produces in this process carries that route's one
 * answer. The residual case (a sample taken before the brand applied,
 * from a node since removed) can only ever manufacture a DISAGREEMENT,
 * which fails loudly — never a false agreement, which would pass.
 */
val kayaTypefaceSites = HashMap<String, androidx.compose.ui.text.TextLayoutResult>()

/** The last face identity this process printed, so the read below logs
 *  ONE LINE PER STATE CHANGE. `expect_typeface` is a bounded retry like
 *  every observation, so a line per read is a thousand lines per failing
 *  leg — which buries the one line that says what changed. (The GTK arm
 *  landed the same rule for the same reason.) */
private var kayaTypefaceSaid: String? = null

/**
 * THE HONEST READ, for `expect_typeface`: the family the TEXT SYSTEM
 * ended up with, off the real text on screen.
 *
 * NEVER THE MODEL AND NEVER THE REQUEST. Each sample is a
 * `TextLayoutResult` a real layout pass produced, and BOTH halves of the
 * resolution come out of it — the style that layout used, and the
 * `fontFamilyResolver` that layout used — so the answer is about the
 * render rather than about `KayaSceneModel`. From there the face is
 * shaped and named out of the font file's own name table.
 *
 * THE SITES MUST AGREE, for [kayaTypefaceSites]' reason: reporting the
 * first one found would hide a lowering that reached the typography ramp
 * and not the ambient style, which on this backend is one missing line
 * rather than an exotic failure. A disagreement is reported AS a
 * disagreement, naming each site — a string no scene can assert.
 */
internal fun kayaResolvedTypeface(): String {
    val samples = LinkedHashMap<String, androidx.compose.ui.text.TextLayoutResult>()
    samples.putAll(kayaTypefaceSites)
    // The two editable kinds read the ambient style as a label does, but
    // through a different composable — and their layout is already
    // published, for the range verbs.
    for (node in KayaSceneModel.entryWidgets) {
        kayaTextLayouts[node.id]?.invoke()?.let { samples["entry"] = it }
    }
    for (node in KayaSceneModel.textareas) {
        kayaTextLayouts[node.id]?.invoke()?.let { samples["textarea"] = it }
    }
    if (samples.isEmpty()) {
        // A REAL ANSWER, not an empty string: no text has laid out to
        // read, which is a different thing from a font that failed to
        // apply, and the sentence says which one it is.
        return "no laid-out text on screen"
    }
    val families = sortedSetOf<String>()
    val bySite = ArrayList<String>()
    val identities = ArrayList<String>()
    for ((site, layout) in samples.entries.sortedBy { it.key }) {
        val input = layout.layoutInput
        val typeface = input.fontFamilyResolver.resolve(
            input.style.fontFamily,
            input.style.fontWeight ?: FontWeight.Normal,
            input.style.fontStyle ?: FontStyle.Normal,
        ).value as? android.graphics.Typeface
            ?: return "$site resolved to no platform typeface"
        val face = kayaShapedFace(typeface)
            ?: return "the shaped font cannot be read on API " +
                "${Build.VERSION.SDK_INT} (TextRunShaper is API 31)"
        families.add(face.family)
        bySite.add("$site=${face.family}")
        identities.add("$site $face")
    }
    // The WHOLE identity in the transcript, because the answer is the
    // family name alone and a family name cannot always tell two device
    // families apart: `sans-serif` and `sans-serif-condensed` are one
    // file at two widths. What the read measured is here; what it
    // asserts is returned. One line per state CHANGE (kayaTypefaceSaid).
    val identity = identities.joinToString("; ")
    if (identity != kayaTypefaceSaid) {
        kayaTypefaceSaid = identity
        Log.i("kaya", "KAYA_TYPEFACE: $identity")
    }
    if (families.size > 1) return "sites disagree: " + bySite.joinToString(", ")
    return families.first()
}

/**
 * Material's ramp with the FAMILY swapped and nothing else touched.
 *
 * `copy` moves one field, so `fontSize`, `lineHeight`, `fontWeight` and
 * `letterSpacing` stay exactly what Material set. That is the whole of
 * "the family swaps, the ramp never does" (DESIGN.md), and it was
 * checked rather than asserted: all fifteen rungs read byte-identical
 * across the unbranded, `serif` and `cursive` legs, and the rendered
 * line boxes with them (styling/typeface-compose.md §1.3).
 */
private fun Typography.kayaWithFamily(f: FontFamily) = Typography(
    displayLarge = displayLarge.copy(fontFamily = f),
    displayMedium = displayMedium.copy(fontFamily = f),
    displaySmall = displaySmall.copy(fontFamily = f),
    headlineLarge = headlineLarge.copy(fontFamily = f),
    headlineMedium = headlineMedium.copy(fontFamily = f),
    headlineSmall = headlineSmall.copy(fontFamily = f),
    titleLarge = titleLarge.copy(fontFamily = f),
    titleMedium = titleMedium.copy(fontFamily = f),
    titleSmall = titleSmall.copy(fontFamily = f),
    bodyLarge = bodyLarge.copy(fontFamily = f),
    bodyMedium = bodyMedium.copy(fontFamily = f),
    bodySmall = bodySmall.copy(fontFamily = f),
    labelLarge = labelLarge.copy(fontFamily = f),
    labelMedium = labelMedium.copy(fontFamily = f),
    labelSmall = labelSmall.copy(fontFamily = f),
)

/**
 * THE THEME ROOT — the one place this backend's appearance is decided.
 *
 * There was none until now, and the reason it was survivable is also the
 * reason it had to change: an unthemed composition still renders, because
 * every Material component falls back to `LocalColorScheme`'s default,
 * which IS `lightColorScheme()` (read off material3 1.3.1's bytecode, not
 * assumed). So the pixels were fine and there was simply NOTHING TO WRITE
 * TO — no scheme in kaya's hands, so nowhere for a brand accent to land
 * and nowhere for a contrast level to be read into. Android could not
 * take one line of the styling pass before this existed
 * (docs/styling-plan.md §3 step 3).
 *
 * ITS THREE INPUTS, all of them read from the platform or the app and
 * none of them assumed: the brand SEED (apply 32, or null), the
 * APPEARANCE (the system's, no longer pinned — see below), and the
 * CONTRAST level (Android 14's slider; a static scheme ignores it
 * silently, MDC #3524, which is the read-backs-lie rule with a Material
 * spelling). The typeface (D6, slice 2) is MaterialTheme's `typography`
 * argument, and the note on the text style below is the thing to read
 * before touching it.
 *
 * THE APPEARANCE UNPINS HERE, and it took three changes rather than one.
 * The foundation measured why: with the scheme following the system, the
 * window stayed #FAFAFA in BOTH appearances while the primary role moved
 * #6750A4 -> #D0BCFF — dark-scheme controls on a light page, because the
 * window background came from the platform theme each app declares in its
 * manifest, where no Compose theme reaches. So all three moved together:
 * the manifests now name kaya's own DayNight theme
 * (android/kaya/src/main/res/values{,-night}/themes.xml), this wrapper
 * paints `colorScheme.background` and takes the matching content colour
 * (a black label on a dark page is the other half of that same bug), and
 * the appearance follows `isSystemInDarkTheme()`. The lane still runs
 * `notnight` on all four AVDs, so the dark arm is proven the way the
 * foundation proved it: the whole lane re-run with every device forced to
 * night mode, with the setting read back before and after.
 *
 * MaterialTheme ALSO PROVIDES A TEXT STYLE, and that one is not a
 * fallback anybody was already getting: it ends in
 * `ProvideTextStyle(typography.bodyLarge)`. Without a theme
 * `LocalTextStyle` is material3's `DefaultTextStyle`, whose font size
 * is UNSPECIFIED and lays out at the text layer's own default;
 * bodyLarge is 16sp on a 24sp line. Every label
 * (`KIND_LABEL -> Text(node.text, …)`) and every text field
 * (`textStyle = LocalTextStyle.current.copy(…)`) in this interpreter
 * reads that local, so accepting it would resize all of them. That is
 * a change to the type SCALE, which is precisely what DESIGN.md says a
 * brand typeface may never make. The ambient style is therefore held at
 * whatever it was outside this theme; moving it is the typeface slice's
 * ratified decision, made in this one line. The heading role reaches
 * into `typography` for ITS tier and nothing else does — a tier picked
 * per widget is not a scale changed under everything.
 */
@Composable
internal fun KayaTheme(content: @Composable () -> Unit) {
    // Read BEFORE the theme, which is what makes them the pre-theme
    // values: inside MaterialTheme this local is already bodyLarge, and
    // the ramp is already whatever this call passed.
    val ambientTextStyle = LocalTextStyle.current
    val baseTypography = MaterialTheme.typography
    val dark = isSystemInDarkTheme()
    val contrast = kayaSystemContrast()
    val seed = KayaSceneModel.brandSeed
    val scheme = remember(seed, dark, contrast) { KayaColorSchemes.of(seed, dark, contrast) }
    // THE BRAND TYPEFACE'S FIRST WRITE (docs/styling-plan.md Slice 2b):
    // Material's own ramp, family swapped, everything else Material's.
    // It is what every M3 component picks its rung out of — a Button
    // does its own ProvideTextStyle(labelLarge) internally — and the
    // `heading` role's titleLarge is kaya's one direct read of it.
    val family = KayaSceneModel.typefaceFamily
    val typography = remember(family, baseTypography) {
        if (family == null) baseTypography else baseTypography.kayaWithFamily(family)
    }
    MaterialTheme(colorScheme = scheme, typography = typography) {
        // AND THE SECOND WRITE, which is the one a reader would not
        // predict and the probe measured: kaya's own labels and text
        // fields read this local and NOT the ramp, so a lowering that
        // set `typography` alone would brand Material's components and
        // leave every kaya label on the platform face — half branded,
        // and still branded-looking enough to pass a coarse look.
        //
        // FAMILY ONLY. The size stays Unspecified, which is this local's
        // whole reason for being held at its pre-theme value: a brand
        // typeface substitutes the family and never the scale
        // (DESIGN.md), so the note above survives the typeface slice
        // rather than being spent by it.
        CompositionLocalProvider(
            LocalTextStyle provides
                if (family == null) ambientTextStyle
                else ambientTextStyle.copy(fontFamily = family)
        ) {
            // The page itself, in the scheme's own colours: `Surface`
            // paints `background` AND provides the content colour that
            // goes with it, which is the pair every label and field in
            // this interpreter reads. Material's own composable rather
            // than a Box with a background, because "the surface decides
            // what its content colour is" is the M3 contract and kaya
            // wraps the platform's idiom rather than restating it.
            Surface(modifier = Modifier.fillMaxSize(), color = scheme.background) {
                content()
            }
        }
    }
}

/**
 * THE SYSTEM CONTRAST LEVEL, -1..1 with 0 the default — Android 14's
 * accessibility slider (Settings -> Accessibility -> Colour and motion),
 * on Material's own scale, which is why it can be handed to the
 * derivation unconverted.
 *
 * LIVE, not sampled once: the slider is not a Configuration field, so a
 * composition that read it at startup would keep the old scheme for the
 * life of the process — the silent no-op of MDC #3524 rebuilt one layer
 * up. `addContrastChangeListener` is the platform's own answer and this
 * is the whole of it.
 *
 * Below API 34 there is no slider and no listener, and the honest answer
 * is Material's default rather than a guess: 0.
 */
@Composable
private fun kayaSystemContrast(): Float {
    val context = LocalContext.current
    val manager =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            context.getSystemService(UiModeManager::class.java)
        } else {
            null
        }
    var contrast by remember(manager) { mutableFloatStateOf(manager?.contrast ?: 0f) }
    DisposableEffect(manager) {
        if (manager == null) return@DisposableEffect onDispose {}
        val listener = UiModeManager.ContrastChangeListener { level -> contrast = level }
        manager.addContrastChangeListener(context.mainExecutor, listener)
        onDispose { manager.removeContrastChangeListener(listener) }
    }
    return contrast
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
    // THE SOFT KEYBOARD IS AN INSET THIS SURFACE CONSUMES, and the
    // measurement is what put it here. Without it the system's answer to
    // a focused field low in the window is to PAN the whole window up:
    // measured 2026-08-10 on the editor scene with the find bar focused,
    // `decorView.getLocationInWindow()` = (0, -199), which puts the menu
    // bar and the document's first line ABOVE the window — not clipped on
    // screen, NEVER DRAWN, absent from the app's own surface. An editor
    // whose Find hides the document it is finding in is the half a person
    // sees; the half nobody sees is that kaya's model, the semantics tree
    // and the field's own viewport all still read correctly, so only a
    // PIXEL read ever notices. Consuming the inset resizes the content
    // instead, which is the platform's own guidance for API 30 and up and
    // what every other backend already does by having a window manager.
    Box(modifier = Modifier.fillMaxSize().imePadding()) {
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
            // The OUTER half of the measured-inset observation: this
            // capture sits before the padding, its twin after, and the
            // halved difference is the inset the harness asserts.
            .onGloballyPositioned { kayaOuterSize = it.size }
            // The normalized root inset — now the window's OWN (wprop
            // 8, docs/styling-plan.md D3): 16 unless the app says
            // otherwise, applied before the offer is measured so the
            // available area is the content box, exactly as the
            // SwiftUI interpreter reads it.
            .padding(KayaSceneModel.windowInset.dp)
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
 * THE TEST TAG EVERY MATERIALIZED MENU AFFORDANCE CARRIES, keyed by the
 * item's own id.
 *
 * It is what makes the symbol read an OBSERVATION: the tag says "this
 * row is the row for item N", the merged semantics node it lands on is
 * the node a TalkBack user focuses, and the content description on that
 * node got there from the [Icon] the lowering drew — not from the field
 * the apply arm decoded. An item with no row composed has no node with
 * this tag, and the read reports that as its own state rather than
 * guessing.
 *
 * On EVERY affordance, symbol or not, deliberately: "the row exists and
 * carries no icon" and "no row exists" are different measurements, and a
 * tag only on the icon-bearing rows would collapse them into one.
 */
fun kayaMenuTag(id: Long): String = "kaya:menu#$id"

/** The SEMANTIC ICON, drawn once, in one place — the kayaApplySymbol
 * precedent from the macOS arm, so every kind gets identical treatment
 * and an unset symbol is simply no icon.
 *
 * `contentDescription` IS the semantic name. That is the whole
 * observation channel on this backend, and it is also just correct
 * accessibility: an icon that means something has to say what it means,
 * and "done" is what the item's checkmark glyph means. */
@Composable
fun KayaSymbolIcon(symbol: Long) {
    val icon = KayaCompose.symbolIcon(symbol) ?: return
    Icon(imageVector = icon, contentDescription = KayaCompose.symbolName(symbol))
}

/** The same icon as a SLOT — null when the item declares no symbol, so
 * a row with none passes `null` to `leadingIcon` and Material lays it
 * out exactly as it did before D6 rather than reserving an empty box. */
fun kayaSymbolSlot(symbol: Long): (@Composable () -> Unit)? =
    if (symbol == 0L) null else { -> KayaSymbolIcon(symbol) }

/**
 * Hands the harness a handle on the WINDOW this menu is composed in.
 *
 * A Compose `Popup` — and every DropdownMenu is one — is its own window,
 * added straight to the WindowManager, so nothing under
 * `activity.window.decorView` leads to it and the a11y reads that start
 * there see an open menu as an empty screen. Inside the popup's content
 * `LocalView.current` IS that window's AndroidComposeView, which makes
 * this two lines instead of a hunt through WindowManagerGlobal.
 *
 * Called at the TOP of each menu's content, so the registration outlives
 * every row below it, and dropped on dispose so a closed menu leaves no
 * stale root for a later read to walk.
 */
@Composable
private fun KayaMenuPopupRoot() {
    val view = LocalView.current
    DisposableEffect(view) {
        KayaSceneModel.menuPopupViews.add(view)
        onDispose { KayaSceneModel.menuPopupViews.remove(view) }
    }
}

/**
 * The window catalog's phone materialization (DESIGN.md, Menus): an M3
 * TopAppBar whose actions slot carries the promoted primaries — the
 * SEMANTIC ICON when the item names one, then the icon blob, then text
 * — and the overflow ⋮ holding the ENTIRE catalog. Every affordance
 * here routes through [kayaActivateMenuItem]: chrome emits, one
 * dispatch path.
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
                val tag = Modifier.testTag(kayaMenuTag(item.id))
                if (item.symbol != 0L) {
                    IconButton(
                        onClick = { kayaActivateMenuItem(item, ByteArray(0)) },
                        enabled = enabled,
                        modifier = tag,
                    ) {
                        KayaSymbolIcon(item.symbol)
                    }
                } else if (icon != null) {
                    IconButton(
                        onClick = { kayaActivateMenuItem(item, ByteArray(0)) },
                        enabled = enabled,
                        modifier = tag,
                    ) {
                        Image(bitmap = icon, contentDescription = item.label)
                    }
                } else {
                    TextButton(
                        onClick = { kayaActivateMenuItem(item, ByteArray(0)) },
                        enabled = enabled,
                        modifier = tag,
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
    Box {
        IconButton(onClick = {
            KayaSceneModel.menuOverflowDrilled = 0L
            KayaSceneModel.menuOverflowOpen = true
        }) { Text("⋮") }
        DropdownMenu(
            expanded = KayaSceneModel.menuOverflowOpen,
            onDismissRequest = {
                KayaSceneModel.menuOverflowOpen = false
                KayaSceneModel.menuOverflowDrilled = 0L
            },
        ) {
            KayaMenuPopupRoot()
            val close = {
                KayaSceneModel.menuOverflowOpen = false
                KayaSceneModel.menuOverflowDrilled = 0L
            }
            // Promotion moves an action OUT of overflow: the promoted
            // set renders as real bar actions and is excluded from
            // every overflow row run (drill-ins included).
            val promotedIds = kayaPromotedActions().map { it.id }.toSet()
            val sub = KayaSceneModel.menuItems[KayaSceneModel.menuOverflowDrilled]
            if (sub == null) {
                KayaSceneModel.menubar.forEachIndexed { i, group ->
                    if (i > 0) HorizontalDivider()
                    // A GROUPING NODE'S HEADER IS AN AFFORDANCE TOO: it
                    // carries the group's own symbol and its own tag, so
                    // `expect_menu_symbol "File"` reads the same surface
                    // a leaf's row does. Merged deliberately — the icon
                    // and the label are one utterance to a service, and
                    // a header that did not merge would hand the read a
                    // node with a tag and no description on it.
                    Row(
                        modifier = Modifier
                            .padding(horizontal = 12.dp, vertical = 4.dp)
                            .testTag(kayaMenuTag(group.id))
                            .semantics(mergeDescendants = true) {},
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        KayaSymbolIcon(group.symbol)
                        Text(group.label)
                    }
                    if (group.kind == KayaCompose.MENU_KIND_RADIO_GROUP) {
                        // A bar-level radio group: a labeled group
                        // whose options use the checkmark idiom.
                        KayaRadioRows(group, ByteArray(0), close)
                    } else {
                        KayaMenuRows(
                            group.children.toList(),
                            ByteArray(0),
                            onDrill = { KayaSceneModel.menuOverflowDrilled = it.id },
                            onClose = close,
                            promoted = promotedIds,
                        )
                    }
                }
            } else {
                // The drill-in: a back row over the submenu's rows.
                DropdownMenuItem(
                    text = { Text("‹ ${sub.label}") },
                    onClick = { KayaSceneModel.menuOverflowDrilled = 0L },
                )
                HorizontalDivider()
                KayaMenuRows(
                    sub.children.toList(),
                    ByteArray(0),
                    onDrill = { KayaSceneModel.menuOverflowDrilled = it.id },
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
        // The SEMANTIC ICON rides the LEADING slot on every row kind
        // that has one free — which is all of them here; a toggle's
        // checkmark and a submenu's ▸ are trailing marks, and neither
        // competes with it. (A radio option is the one row whose
        // leading slot is taken; KayaRadioRows says what happens
        // there.) A separator has no label, no id and no icon.
        val symbol = kayaSymbolSlot(item.symbol)
        val tag = Modifier.testTag(kayaMenuTag(item.id))
        when (item.kind) {
            KayaCompose.MENU_KIND_SEPARATOR -> HorizontalDivider()
            KayaCompose.MENU_KIND_MENU ->
                DropdownMenuItem(
                    text = { Text(item.label) },
                    modifier = tag,
                    leadingIcon = symbol,
                    trailingIcon = { Text("▸") },
                    enabled = kayaMenuEffectivelyEnabled(item),
                    onClick = { onDrill(item) },
                )
            KayaCompose.MENU_KIND_RADIO_GROUP -> KayaRadioRows(item, noun, onClose)
            KayaCompose.MENU_KIND_TOGGLE ->
                DropdownMenuItem(
                    text = { Text(item.label) },
                    modifier = tag,
                    leadingIcon = symbol,
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
                        modifier = tag,
                        leadingIcon = symbol,
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
                    modifier = tag,
                    leadingIcon = symbol,
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
 * the GROUP with the option's index — the Choice contract.
 *
 * THE ONE ROW WHOSE SEMANTIC ICON IS TRAILING, not leading: the
 * leading slot holds the selection mark, which is the row's whole
 * point, and moving that to make room for an icon would break the
 * checkmark idiom this arm exists to keep. Nothing else changes — the
 * icon is the same [Icon] with the same content description on the
 * same merged node, so the read does not know or care which slot it
 * came out of. */
@Composable
fun KayaRadioRows(group: KayaMenuItem, noun: ByteArray, onClose: () -> Unit) {
    group.children.forEachIndexed { i, option ->
        DropdownMenuItem(
            text = { Text(option.label) },
            modifier = Modifier.testTag(kayaMenuTag(option.id)),
            leadingIcon = {
                androidx.compose.material3.RadioButton(
                    selected = group.value.toInt() == i,
                    onClick = null,
                )
            },
            trailingIcon = kayaSymbolSlot(option.symbol),
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
    // THE STAMP, written by the arm that runs — there is exactly one
    // here, so it is unconditionally "bar" (a phone has no leading
    // sidebar to give the hint; physics decides). Written where the
    // bar is BUILT rather than computed from `sectionsPresentation`,
    // which is the whole point: a lowering that stopped honoring the
    // hint must be able to disagree with the app's declaration. A
    // second arm, if this host ever grows one, stamps its own name.
    KayaSceneModel.sectionsRendered = "bar"
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
                    // THE SEMANTIC ICON (docs/styling-plan.md D6). An
                    // empty lambda until now, which is what an M3
                    // NavigationBar looks like with the one thing it is
                    // designed around missing: the icon is the primary
                    // affordance and the label is the caption under it.
                    // A section that declares no symbol still passes an
                    // empty slot, exactly as before.
                    icon = { KayaSymbolIcon(section.symbol) },
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
