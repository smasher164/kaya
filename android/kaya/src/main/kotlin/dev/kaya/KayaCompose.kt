package dev.kaya

import android.app.UiModeManager
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.ContentResolver
import android.content.res.Configuration
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.Drawable
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.util.Base64
import android.util.Log
import android.view.KeyEvent
import android.view.ViewTreeObserver
import android.webkit.MimeTypeMap
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.compose.setContent
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.draganddrop.dragAndDropSource
import androidx.compose.foundation.draganddrop.dragAndDropTarget
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.ScrollableDefaults
import androidx.compose.foundation.gestures.ScrollableState
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.gestures.scrollable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.PressInteraction
// The entry/textarea path (docs/undo-plan.md §1.4). `undoState` and its
// five members are the ONLY experimental surface here at foundation
// 1.7.5.
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
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
// THE SEMANTIC ICON VOCABULARY's glyphs (docs/styling-plan.md D6), one
// import per concept. IMPORTED, never written out at the callsite: each
// is an extension property Kotlin cannot spell fully qualified, so a
// name that does not exist fails the COMPILER. back/forward come from
// `automirrored`; the pre-1.6 spellings still compile and point the
// wrong way in a right-to-left layout.
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.DateRange
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
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.foundation.clickable
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDefaults
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SelectableDates
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.SideEffect
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.PlainTooltip
import androidx.compose.material3.TimePicker
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TooltipBox
import androidx.compose.material3.TooltipDefaults
import androidx.compose.material3.Typography
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.material3.rememberTooltipState
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
// Material 3 adaptive: Android's OWN list-detail container
// (docs/multicolumn-plan.md). calculatePaneScaffoldDirective lives in
// `.layout`, not in `.adaptive` beside currentWindowAdaptiveInfo, whose
// Large/XL opt-in carries the third partition at 1200dp.
import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfo
import androidx.compose.material3.adaptive.layout.AdaptStrategy
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
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.colorspace.ColorSpaces
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.layout
import androidx.compose.ui.draganddrop.DragAndDropEvent
import androidx.compose.ui.draganddrop.DragAndDropTarget
import androidx.compose.ui.draganddrop.DragAndDropTransferData
import androidx.compose.ui.draganddrop.toAndroidDragEvent
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInParent
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.node.RootForTest
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.SemanticsPropertyKey
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.onLongClick
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.DeviceFontFamilyName
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.createFontFamilyResolver
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread
import kotlinx.coroutines.launch

/**
 * KayaCompose: the Kotlin half of the Compose backend, an interpreter of
 * resolved apply-op records (KayaSwiftUI.swift is its sibling). The pump
 * blocks in nextCommands on its own thread and HOPS TO THE UI THREAD to
 * apply; signals, collections and templates never reach this layer, and
 * a click tag is opaque bytes stored and emitted verbatim.
 */
class KayaNode(val id: Long, val kind: Int, val tag: ByteArray) {
    /**
     * TABLE (docs/tables-plan.md): the declared header bar, stored by
     * the apply pump. tableSorted is a column index or the wire's u32
     * no-column sentinel; sortTag is what a header click hands to
     * kaya_emit_sort_requested verbatim.
     */
    var tableColumns: List<String> = emptyList()
    var tableSorted: Int = -1
    var tableDirection: Int = 0
    var sortTag: ByteArray = ByteArray(0)

    /**
     * What the TABLE PATH actually presented — written by the render,
     * never a model echo (the SwiftUI twin's rule), so expect_columns
     * proves the header rendered rather than that the wire arrived.
     * Headers render at EVERY width (docs/tables-plan.md), so there is
     * no size-class prefix.
     */
    var tablePresented by mutableStateOf("")

    /**
     * Cell leading edges in dp, window space, keyed by declaration
     * generation and "<rowId>/<col>" ("h/<col>" for kaya's own header
     * cells); the generation keeps a re-declaration from reading the
     * preceding layout's bounds. Concurrent because the harness thread
     * reads while the UI thread writes.
     */
    val cellEdgeX = java.util.concurrent.ConcurrentHashMap<String, Float>()
    val cellEdgeRightX = java.util.concurrent.ConcurrentHashMap<String, Float>()
    /**
     * COMPOSE STATE, not a plain field: the table's own measure READS
     * it, so a bump forces the re-measure that republishes the geometry
     * it cleared. Otherwise every later expect_column_edges answers "no
     * live table viewport geometry" (measured 2026-08-28,
     * docs/traps.md; tools/check-table-tier.py holds SwiftUI's twin).
     */
    var tableGeometryGeneration by mutableLongStateOf(0L)

    /**
     * The table's assigned track, laid-out viewport and raw content
     * span, in dp (-1 before layout). [tableDrawnW] is COERCED into the
     * constraints, so only [tableContentW] shows a resolved-column
     * overflow. Volatile: written at layout, read by the harness thread.
     */
    @Volatile var tableTrackW = -1f
    @Volatile var tableDrawnW = -1f
    @Volatile var tableContentW = -1f
    /** The generation the three widths above were measured under. */
    @Volatile var tableGeometryAt = -1L
    @Volatile var tableViewportLeftX = -1f
    @Volatile var tableViewportRightX = -1f
    @Volatile var tableViewportH = -1f
    @Volatile var tableContentH = -1f

    /**
     * THE COLUMNS' AXIS (docs/tables-plan.md): the offset both header
     * and row cells are placed at, the furthest it may go, and their
     * divisor, in device pixels; reach is EXACTLY zero when the columns
     * fit. Snapshot state on the offset because the table's PLACEMENT
     * reads it — a scroll re-places and never re-measures.
     */
    var tableScrollX by mutableFloatStateOf(0f)
    @Volatile var tableReachX = 0f
    @Volatile var tableDensity = 1f

    /**
     * ONE CLAMP for the finger and for `scroll_end` alike — a harness
     * that wrote the offset itself could park at a column no gesture can
     * reach, which is the shape of an assertion that proves nothing.
     * `by lazy` and not thread-safe for [textState]'s reason: every touch
     * is on the UI thread.
     */
    val tableColumnScroll: ScrollableState by lazy(LazyThreadSafetyMode.NONE) {
        ScrollableState { delta ->
            val before = tableScrollX
            val next = (before + delta).coerceIn(0f, tableReachX)
            tableScrollX = next
            next - before
        }
    }

    /**
     * KAYA'S MODEL MIRROR of the widget's text; an entry or textarea
     * reads from [textState] instead. The two are written together by
     * [kayaWriteText], and THE DIFFERENCE BETWEEN THEM tells a user edit
     * from the echo of kaya's own write (docs/undo-plan.md §1.4).
     */
    var text by mutableStateOf("")

    /**
     * THE TEXT WIDGET'S OWN STATE (entry/textarea only). The legacy
     * `TextField(value:, onValueChange:)` path is DISQUALIFIED
     * (docs/undo-plan.md §1.4): its internal `UndoManager` has no
     * `canUndo` and no `undo()`. `by lazy`, not thread-safe by choice —
     * every touch is on the UI thread.
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

    /** HELP (docs/tooltip-plan.md T1): what this control is or does, drawn
     * by the platform's own tooltip. Composition state — [KayaRenderHelped]
     * draws from it. */
    var help by mutableStateOf("")

    /** The widget's accept list, verbatim. Recorded here because the
     * paste hook and the standard commands' enablement both read it off
     * the focused node. Empty means the widget takes nothing. */
    var accepts by mutableStateOf("")

    /**
     * THE DRAG-AND-DROP DECLARATIONS (docs/dnd-plan.md D1, D8), all
     * composition state because the surface appears and withdraws with
     * them: what this widget hands over and which operations it allows,
     * which operations it will perform on a drop (0 = not a
     * destination), and whether its stamped rows drag within their own
     * collection. WHAT it receives is [accepts], the one vocabulary a
     * paste and a drop share.
     */
    internal var dragPayload by mutableStateOf<KayaDragPayload?>(null)
    var dragOps by mutableStateOf(0)
    var dropOps by mutableStateOf(0)
    var reorderable by mutableStateOf(false)

    /** The reorderable For this node is a stamped row of, if any (D8):
     * its surface then drags and takes rows. Written by the two apply
     * arms that can make it true — the container's own declaration and
     * a later add_child — so the row needs no walk up a parent map the
     * composition cannot recompose on. */
    var reorderIn by mutableStateOf<KayaNode?>(null)

    /** The identity bytes the three dnd apply twins carried. */
    var dndTag by mutableStateOf(ByteArray(0))

    /** What an occurrence from this node rides under: the dnd
     * declaration's own tag, else the create tag (the mac arm's
     * `identityTag`). */
    val identityTag: ByteArray get() = if (dndTag.isEmpty()) tag else dndTag

    /** Semantic emphasis (docs/styling-plan.md D4), 0 = none. The
     * render layer lowers it to M3's own emphasis ladder, NEVER to a
     * colour this file chose. */
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

    /**
     * THE SLIDER'S granularity and drawn ticks (0 = none), and the value
     * the last gesture SETTLED ON — what value_committed compares against
     * (docs/slider-plan.md S1, S2, S5). Composition state: the arm draws
     * its stops and its ticks from the first two.
     */
    var step by mutableStateOf(0.0)
    var tickSpacing by mutableStateOf(0.0)
    var committed by mutableStateOf(0.0)

    /**
     * THE PICKERS' SLOTS (docs/datetime-plan.md D2), packed decimal:
     * [date], [minDate] and [maxDate] as YYYYMMDD (0 = no bound),
     * [time] as HHMM, [minuteStep] the count Compose has no native
     * increment for (D3, snapped in the commit path). Composition
     * state: the field draws from them.
     */
    var date by mutableLongStateOf(0L)
    var minDate by mutableLongStateOf(0L)
    var maxDate by mutableLongStateOf(0L)
    var time by mutableLongStateOf(0L)
    var minuteStep by mutableIntStateOf(1)

    /**
     * WHAT THE PICKER FIELD ACTUALLY PRESENTED, in fixed digits, stamped
     * by the composable that formatted it — `expect_picker`'s reading
     * (docs/datetime-plan.md D8), never a model echo, the
     * [tablePresented] rule one kind over. Empty means no picker body
     * has rendered, which is a different answer from a wrong value.
     * Volatile: written at composition, read by the harness thread.
     */
    @Volatile var pickerPresented = ""
    // The image slot: the decoded bitmap (null is the placeholder
    // class) and its size as the harness's "WxH" observation string
    // ("0x0" before a source lands or after a failed decode).
    var imageBitmap by mutableStateOf<ImageBitmap?>(null)
    var imageSize by mutableStateOf("0x0")
    // The canvas slot (docs/canvas-plan.md §8): the core's raster as an
    // ImageBitmap, and the scale it was drawn at — device pixels over
    // this number is the drawing's size in dp.
    var drawing by mutableStateOf<ImageBitmap?>(null)
    var drawingScale by mutableStateOf(1.0)
    // The toolkit's own ScrollState is both the observation source
    // (maxValue > 0 = overflow; value == maxValue = at end) and what
    // scroll_end drives.
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

    /// The arrangement axis (null = the creation kind's own — row
    /// horizontal, column vertical). One node, two constructor
    /// spellings (docs/adaptive-layout-plan.md D1).
    var axis by mutableStateOf<Long?>(null)
    /**
     * THE DECLARED SET OF DECORATED RANGES (textarea only), and the text
     * it was declared against. The PAIR is what makes D2's clear-on-edit
     * structural: the draw scope paints the set only while the field
     * still holds [highlightsFor], and a compare made on the pass that
     * paints cannot arrive late where a message from the core could.
     */
    var highlights by mutableStateOf<List<KayaRange>>(emptyList())
    var highlightsFor by mutableStateOf<String?>(null)
    /**
     * The REVEAL one-shot: the range to scroll into view plus a sequence
     * number, because a scroll needs the field's own TextLayoutResult
     * and that exists only after a layout pass. Keyed on [revealSeq], so
     * an unrelated recomposition re-runs nothing while a second reveal
     * of the SAME range still runs.
     */
    var revealRequest by mutableStateOf<KayaRange?>(null)
    var revealSeq by mutableStateOf(0)
    val children = mutableStateListOf<KayaNode>()

    /**
     * The stacked fold (docs/adaptive-layout-plan.md D7): non-zero = the
     * table whose viewport this node renders inside. Identity stays here
     * — only layout moves. State, so the flip recomposes both homes.
     */
    var foldedInto by mutableStateOf(0L)

    /** The table side: folded content in sibling order, rendered above
     * row 0 inside this table's scroll. */
    val foldedChildren = mutableStateListOf<KayaNode>()

    /** The children this container LAYS OUT — a folded child renders in
     * its table's viewport instead, while every harness read keeps
     * seeing [children]. */
    val laidOut: List<KayaNode> get() = children.filter { it.foldedInto == 0L }
}

/**
 * WHAT THE DRAW SCOPE ACTUALLY PAINTED, by node id, in UTF-16 code
 * units — written inside the draw lambda, the only place the answer is
 * true. NOT the declared set ([KayaNode.highlights]), which a verb would
 * agree with by construction and pass with the paint deleted.
 */
val kayaPaintedRanges = HashMap<Long, List<KayaRange>>()

/**
 * The field's own text layout, by node id. KEPT AS A LAMBDA rather than
 * a result so reading it stays in the LAYOUT/DRAW phase and never
 * invalidates composition (range-probe-android.md §1c measured the naive
 * spelling recomposing the field 200 times in 200 frames). A plain map
 * and not snapshot state for the same reason.
 */
val kayaTextLayouts = HashMap<Long, () -> androidx.compose.ui.text.TextLayoutResult?>()

/**
 * Where each textarea's viewport sits IN THE WINDOW, which is NOT
 * `PixelCopy`'s SURFACE space: the two agree only while nothing has
 * panned the window (measured 2026-08-10 with the keyboard up,
 * `getLocationInWindow()` (0, -199) and the witness photographing 199px
 * low). `kayaPhotograph` is the one place that crosses.
 */
val kayaTextBoxes = HashMap<Long, android.graphics.Rect>()

/**
 * Where each canvas sits IN THE WINDOW — the rectangle `expect_ink`
 * photographs (docs/canvas-plan.md §7.2). Same space, and the same
 * caveat, as [kayaTextBoxes] above: `PixelCopy` wants SURFACE
 * coordinates, and `kayaPhotograph` is the one place that crosses.
 */
val kayaCanvasBoxes = HashMap<Long, android.graphics.Rect>()

/**
 * Whether the scene's `frame` verb owns the tick clock, so the canvas
 * arm attaches no `withFrameNanos` driver of its own (docs/canvas-plan.md
 * §15.4). The same discriminator the startup deadline reads.
 */
private val kayaHarnessDrivesFrames = System.getenv("KAYA_SELFTEST") != null

/**
 * The selection background each textarea is painted UNDER, ARGB, by node
 * id: the platform's wash sits on top of kaya's decoration and the
 * witness composites what it expects. RESOLVED BY THE COMPOSITION — the
 * colour differs between an app that wraps a MaterialTheme and one that
 * does not.
 */
val kayaSelectionWash = HashMap<Long, Int>()

/**
 * How many apply batches this interpreter has finished — the signal an
 * ACTION verb waits on (KayaCompose.kayaAwaitAnswer). `@Volatile`
 * because it is written on the UI thread and read on the harness one;
 * an unpublished counter makes the wait either instant or forever.
 */
@Volatile
var kayaBatches = 0
/** The last `click` verb: its target, the batch count it saw, and when —
 * for expect_title's refusal (the android portfolio WATCH's instrument). */
var kayaLastClick: Triple<String, Int, Long>? = null

/**
 * The main-axis extent each node was allocated, by node id — what
 * `expect_shares` reads back. Measured from the LAID-OUT TRACK
 * (onGloballyPositioned on the cell), never from the child's own drawn
 * size: the layout rect and the drawing box differ, and only the first
 * is what the grow contract talks about.
 */
val kayaMainExtents = HashMap<Long, Double>()

/**
 * The main-axis extent each CONTAINER rendered at, by node id — what
 * `expect_fills` compares its children's tracks against. Same
 * measured-geometry discipline as the track extents.
 */
val kayaContainerExtents = HashMap<Long, Double>()

/**
 * The container-inset measurement pair (docs/styling-plan.md D3): OUTER
 * is the container's box before its own padding, INNER the content box
 * inside it, and `expect_inset <target>` reads the halved gap in DP.
 * Both record unconditionally, so a step can also assert FLUSH (0).
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

/** The axis each container RENDERED with (true = vertical), recorded at
 * layout time — expect_axis's observation, never the model's field. */
val kayaContainerAxis = HashMap<Long, Boolean>()
val kayaCrossRects = HashMap<Long, Pair<Double, Double>>()
val kayaBaselineOffsets = HashMap<Long, Double>()

/**
 * The main-axis extent each flex child DREW at — what `expect_fills`
 * compares against that child's track. DELIBERATELY NOT
 * [kayaMainExtents], the weighted cell: a widget drawing at a hard size
 * in a correct cell renders wrong (measured, a grow(1) textarea stuck
 * at 96 units tall).
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

// NO depth-stub helper lives here: it comes back as a CALL, never a
// sentence, the next time a scene lands mac-first. tools/check-stubs.py
// and tools/check-steps.py both read the call, and neither can see a
// backend that refuses in its own words.

/**
 * TEXT RANGES. `start`/`stop` are UTF-16 CODE UNITS — what the core
 * converted to before lowering (docs/ranges-units.md §7) and what a
 * Kotlin `CharSequence` indexes. NOTHING ON THE LOWERING PATH CONVERTS;
 * the one conversion is the READING direction, where a verb answers in
 * the protocol's own unit.
 */
data class KayaRange(val start: Int, val stop: Int)

object KayaSceneModel {
    var root by mutableStateOf<KayaNode?>(null)
    // The title materializes on TWO surfaces — the Activity task label
    // and the top bar's title slot — and expect_title asserts both.
    // Width/height are advisory only. A COMPOSITION STATE AND NOT A
    // PLAIN FIELD: the bar's title slot reads it, so a plain field
    // composes once and never again (docs/deferred.md).
    var windowTitle by mutableStateOf("")
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
     * THE REQUESTED BRAND ACCENT, packed 0xRRGGBB, or null (apply 32;
     * docs/styling-plan.md D1/D2). A composition STATE because the theme
     * reads it and the brand arrives AFTER the first composition, where
     * a plain field would leave Material's baseline standing. SET ONCE,
     * BEFORE THE FIRST MOUNT — the root refuses a second write.
     */
    var brandSeed by mutableStateOf<Int?>(null)

    /**
     * THE DECLARED IDENTITY AS IT ARRIVED ON THE WIRE (apply 34;
     * docs/app-identity-plan.md), or null. `expect_app_icon` reports the
     * PACKAGE's icon and uses these only as a REQUIREMENT, since the
     * launcher icon is in the APK whether a guest declared one or not.
     * Not composition state: nothing composes them.
     */
    var appIdentityName: String? = null
    var appIdentityIcon: ByteArray? = null

    // THE REQUESTED FAMILY IS NOT STORED, and its absence is the point
    // (docs/styling-plan.md Slice 2b): a field holding the REQUEST is
    // the one read `expect_typeface` must never make. The arm's own
    // diagnostics carry the asked-for name inline, where it cannot be
    // mistaken for a resolution.

    /**
     * THE BRAND TYPEFACE AS RESOLVED, or null. A FontFamily OBJECT and
     * not a name: Android has NO app-font registry, and after the bytes
     * load `Typeface.create("Noto Serif", …)` still returns Roboto
     * (docs/styling/typeface-compose.md §6.2). Composition STATE.
     */
    var typefaceFamily by mutableStateOf<FontFamily?>(null)
    /// A counter bumped whenever what the system clipboard OFFERS may
    /// have moved: it carries no information, and READING IT SUBSCRIBES
    /// a composition to clipboard changes. The clipboard is not snapshot
    /// state and OnPrimaryClipChangedListener is itself focus-gated with
    /// no catch-up callback (docs/clipboard-plan.md §7), so enablement is
    /// RE-DERIVED rather than pushed.
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
    // (DESIGN.md, Navigation). Android has one surface, so this is THE
    // stack.
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
    // The window's command catalog in menubar-append order, plus every
    // menu item by id. Menu items are their OWN id space (c_menu_item),
    // never widget, node or surface ids (DESIGN.md, Menus).
    val menuItems = HashMap<Long, KayaMenuItem>() // UI thread only
    val menubar = androidx.compose.runtime.mutableStateListOf<KayaMenuItem>()
    // The window's live FORM FACTOR and the catalog lowering that
    // ACTUALLY rendered, the two halves expect_menu_presentation reads.
    // The adaptivity axis is the window's size class, never the
    // operating system. NEITHER IS DERIVED FROM THE OTHER: deriving
    // would make the harness verb agree with the lowering by
    // construction, and the two disagreeing is the failure being gated.
    var formFactor = "unknown" // unknown | compact | regular
    var menuPresentation = "none" // none | bar | overflow
    /// Does this window ASK for list-detail (wprop 6). Whether it GETS
    /// it is the size class's answer, resolved in the render arm.
    var panes by mutableStateOf(1L)
    /// The list-detail presentation the render arm ACTUALLY took —
    /// stamped by the arm that ran, never derived from `panes` or
    /// the width, so expect_split cannot agree with the lowering by
    /// construction (docs/traps.md).
    var splitPresentation = "stacked" // split3 | split | stacked
    /// The ThreePaneScaffoldValue the scaffold was LAST LAID OUT from —
    /// stashed by the render arm so expect_panes reads the arrangement
    /// that really rendered, role by role, rather than recomputing one
    /// the screen never took. Null until a pane arm has run.
    @OptIn(ExperimentalMaterial3AdaptiveApi::class)
    var paneValue: ThreePaneScaffoldValue? = null
    /// Does this surface hold UNSAVED WORK (wprop 7;
    /// docs/dirty-plan.md). PLAIN STATE, AND THAT IS THE WHOLE LOWERING
    /// (D4): Android has no window chrome to mark, so nothing draws from
    /// it. `expect_dirty` still reads it, so a backend that dropped the
    /// prop fails. The title is NEVER rewritten (D1).
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
     * THE OVERFLOW ⋮'s presentation state, and the submenu it is drilled
     * into (0 = at its roots). HOISTED OUT OF THE COMPOSABLE so a
     * harness read can MATERIALIZE a row — Compose composes a
     * DropdownMenu's content only while it is open. THE TAP ROUTE AND
     * THE READ ROUTE DRIVE ONE STATE.
     */
    var menuOverflowOpen by mutableStateOf(false)
    var menuOverflowDrilled by mutableStateOf(0L)
    /// Did a HARNESS READ present the overflow, rather than a tap. Only
    /// what a read opened may a read close.
    var menuOverflowPresentedForRead = false
    /**
     * THE COMPOSE ROOTS OF THE OPEN MENU POPUPS — UI thread only,
     * registered by the popup's own content. A Compose `Popup` (a
     * DropdownMenu is one) is a SEPARATE WINDOW under the WindowManager,
     * not under `decorView`, so [kayaComposeRoot]'s walk cannot see one
     * row of an open menu.
     */
    val menuPopupViews = ArrayList<android.view.View>()
    // Per-kind registries in creation order (stamped copies included):
    // the harness names targets as kind#index.
    val buttons = ArrayList<KayaNode>()
    val checkboxes = ArrayList<KayaNode>()
    val labels = ArrayList<KayaNode>()
    // NAMED entryWidgets, not `entries`: the navigation stack is
    // `navEntries`, both are lists, and a harness verb meaning "how
    // deep is the nav stack" that reached the wrong one would compile
    // clean and count text-entry WIDGETS. No gate sees a type-correct
    // wrong field, so the name is the guard.
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
    val canvases = ArrayList<KayaNode>()
    val datePickers = ArrayList<KayaNode>()
    val timePickers = ArrayList<KayaNode>()
    /**
     * The appearance the core last rastered with — written by the ONE
     * reading the presentation report sends (KayaRoot), so
     * `expect_ink`'s answer and the report cannot disagree
     * (docs/canvas-plan.md §6).
     */
    var presentationDark = false
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
    // (docs/styling-plan.md D6), drawn in the NavigationBarItem's icon
    // slot.
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
 * mutable props are snapshot state. This model is also the backend's
 * USER-STATE MIRROR: a user toggle/radio pick lands in checked/value
 * here (and emits), the guest may not echo it back, and an unrelated
 * prop write must not clobber it. */
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
     * The SEMANTIC ICON's wire value, 0 = none (docs/styling-plan.md D6).
     * Unlike [iconBitmap] it reaches EVERY affordance the item
     * materializes as. WHEN AN ITEM CARRIES BOTH, THE SYMBOL WINS, so
     * this backend and macOS show the same thing for one declaration.
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
 * One representation as this side holds it, FLATTENED at the boundary.
 * Text and html ride `text`, an image `bytes`, a CUSTOM format's id
 * `text` with its payload in `bytes`, and files `locators` (the
 * documents' own `content://` URIs) beside `names` of equal length.
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
 * ids it names, in the order the list gave them. The mirror of
 * wire.rs's parse_accept_list. A token that is not one of the four
 * closed names IS a custom format id, which is why an accept list is
 * not a mask.
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

/**
 * A drag source's declared payload — the copy record's representations
 * (docs/dnd-plan.md D1), in the canonical descending-clip-value order.
 */
internal class KayaDragPayload(
    val text: String? = null,
    val html: String? = null,
    val image: ByteArray? = null,
    val files: List<String> = emptyList(),
    val custom: List<Pair<String, ByteArray>> = emptyList(),
)

/**
 * ONE LIVE DRAG THIS PROCESS STARTED, carried as the DragEvent's LOCAL
 * STATE — Android's own process-local channel, which the platform hands
 * back inside this process and nowhere else, so it is both the payload
 * table a ClipData cannot be for custom and image bytes AND the
 * discriminator that says a source is local (docs/dnd-plan.md D9;
 * phones are same-app only).
 *
 * Written on the UI thread; the counters exist so the `drag` verb's
 * expiry sentence can print what it measured rather than a guess.
 */
internal class KayaDragSession(
    val sourceId: Long,
    val payload: KayaDragPayload,
    val ops: Int,
    /** The reorderable For this source is a row of, 0 for a data drag. */
    val rowOf: Long,
) {
    @Volatile var operation = KayaCompose.DRAG_OP_NONE
    @Volatile var started = 0
    @Volatile var entered = 0
    @Volatile var dropped = 0
    @Volatile var ended = false
}

@Volatile
internal var kayaDragSession: KayaDragSession? = null

/** How many drags this process has seen end — the `drag` verb's ack
 * counter, so a second drag from the same source is not mistaken for the
 * first (docs/dnd-plan.md D10). */
@Volatile
internal var kayaDragEndings = 0

/**
 * Where each drag-and-drop surface sits, published by its own layout
 * reader. ROOT space is what a DragEvent's point is in; WINDOW space is
 * what the `drag` verb turns into screen pixels for `input draganddrop`
 * (docs/dnd-plan.md D10). Concurrent because the harness thread reads
 * what the UI thread wrote.
 */
internal class KayaDragBox(
    val rootLeft: Float,
    val rootTop: Float,
    val windowLeft: Float,
    val windowTop: Float,
    val width: Float,
    val height: Float,
)

internal val kayaDragBoxes = java.util.concurrent.ConcurrentHashMap<Long, KayaDragBox>()

/// A layout trace, off unless asked for (KAYA_LAYOUT_TRACE=1), matching
/// the SwiftUI interpreter's channel of the same name.
val kayaLayoutTrace: Boolean = System.getenv("KAYA_LAYOUT_TRACE") != null

/**
 * THE VERB TRACE, this interpreter's copy of crates/kaya/src/vtrace.rs:
 * every attempt of every step, in a ring, written ONLY WHEN THE RUN
 * FAILS to the file `KAYA_VERB_TRACE` names. A RELATIVE name resolves
 * under the app's files directory, the one place `run-as` can read.
 * tools/check-verbs.py holds the three rings level.
 */
object KayaVTrace {
    const val CAP = 2048
    private class Rec(val atMs: Long, val step: Int, val verb: String, val attempt: Int, val what: String)
    private val lock = Object()
    private var on = false
    private var named: String? = null
    private var filesDir: (() -> java.io.File?)? = null
    private var start = 0L
    private var step = 0
    private val steps = ArrayList<String>()
    private val recs = ArrayList<Rec>()
    private var head = 0
    private var dropped = 0L

    fun begin(startNanos: Long, filesDir: () -> java.io.File?) {
        synchronized(lock) {
            val env = System.getenv("KAYA_VERB_TRACE")
            on = !env.isNullOrEmpty()
            named = env
            this.filesDir = filesDir
            start = startNanos
            step = 0
            steps.clear()
            recs.clear()
            head = 0
            dropped = 0
        }
    }

    fun step(ordinal: Int, text: String) {
        synchronized(lock) {
            if (!on) return
            step = ordinal
            while (steps.size <= ordinal) steps.add("")
            steps[ordinal] = text
        }
    }

    /** One attempt of a step, numbered from 1 (the retry wrapper is the attempt point). */
    fun attempt(verb: String, n: Int, what: String) {
        synchronized(lock) {
            if (!on) return
            val rec = Rec((System.nanoTime() - start) / 1_000_000, step, verb, n, what)
            if (recs.size < CAP) {
                recs.add(rec)
            } else {
                recs[head] = rec
                head = (head + 1) % CAP
                dropped++
            }
        }
    }

    private fun quoted(s: String): String =
        "\"" + s.replace('"', '\'').replace('\n', ' ').replace('\r', ' ') + "\""

    /** Append the whole ring under `reason`. FAILURE ONLY — the failed verdict and the watchdog's fire path. */
    fun dump(reason: String) {
        synchronized(lock) {
            if (!on) return
            val env = named ?: return
            // Resolved HERE, not at begin: the activity mounts after the
            // script thread starts, so its files dir is known only now.
            val p = if (env.startsWith("/")) {
                env
            } else {
                val dir = filesDir?.invoke() ?: java.io.File(System.getProperty("java.io.tmpdir"))
                java.io.File(dir, env).path
            }
            val now = (System.nanoTime() - start) / 1_000_000
            val sb = StringBuilder()
            sb.append("KAYA_VERB_TRACE: dump reason=${quoted(reason)} t=$now records=${recs.size} dropped=$dropped steps=${steps.size}\n")
            for ((i, text) in steps.withIndex()) {
                sb.append("KAYA_VERB_TRACE: step=$i text=${quoted(text)}\n")
            }
            for (i in 0 until recs.size) {
                val r = recs[(head + i) % recs.size]
                sb.append("KAYA_VERB_TRACE: t=${r.atMs} step=${r.step} verb=${r.verb} try=${r.attempt} what=${quoted(r.what)}\n")
            }
            // Append mode and ONE write, the Rust ring's rule.
            try {
                java.io.FileOutputStream(p, true).use { it.write(sb.toString().toByteArray(Charsets.UTF_8)) }
            } catch (e: java.io.IOException) {
                Log.e("kaya", "KAYA_HARNESS: verb trace could not be appended to $p: $e")
                return
            }
            Log.e("kaya", "KAYA_HARNESS: verb trace (${recs.size} records, $dropped dropped) appended to $p")
        }
    }
}

/// The height a scroll viewport claims when it is measured with NO bound
/// (see the clamp in KayaTableSurface). The display's own pixel height:
/// an unbounded ask cannot be answered from the constraint, and a window
/// onto larger content that is bigger than the screen is not a window.
val kayaUnboundedViewportPx: Int
    get() = android.content.res.Resources.getSystem().displayMetrics.heightPixels

object KayaCompose {
    // Pinned to the KAYA_APPLY_* / KAYA_KIND_* / KAYA_VALUE_* constants
    // in kaya.h. The protocol fingerprint (KAYA_SPEC_HASH) is asserted
    // against the core at mount: check-verbs holds the SOURCE current,
    // but only the runtime assert catches a stale compiled APK against
    // a new libkaya. ULong because the fingerprint's high bit is fair
    // game and a Kotlin Long hex literal cannot express it.
    private const val SPEC_HASH: ULong = 0x07f8f30026825b06uL

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
     * The SAVE dialog's request (docs/save-plan.md D2). A SECOND
     * REQUEST AND THE SAME ANSWER: it resolves on the picker's own
     * file_dialog_result and shares its id space and one-live-dialog
     * slot.
     */
    private const val APPLY_PRESENT_SAVE_DIALOG = 31
    private const val APPLY_SET_BRAND = 32
    private const val APPLY_SET_TYPEFACE = 33

    /**
     * The app's declared identity (docs/app-identity-plan.md). THE
     * CONSTANT IS HERE AND THE LOWERING IS NOT: the launcher icon
     * belongs to the installed package, and the running app's one route
     * to a picture is refused by the plan's I6. This record's Android
     * reader is the APK build, and the arm below skips it.
     */
    private const val APPLY_SET_APP_IDENTITY = 34
    private const val APPLY_SET_COLUMN_HEADERS = 35

    /**
     * The raster a canvas's declaration produced (docs/canvas-plan.md
     * §1.1): premultiplied RGBA8 device pixels this backend blits into
     * an ImageBitmap. It is also read by the BLOB PREFETCH, one pass
     * ahead of the apply, because a handle dies with its batch.
     */
    private const val APPLY_SET_DRAWING = 36

    /**
     * The stacked fold (docs/adaptive-layout-plan.md D7): { u64 child;
     * u64 table } — render the child inside the grown table's viewport
     * as scroll-away content above row 0; table 0 restores it.
     * Core-derived; identity and addressing stay with the structural
     * parent.
     */
    private const val APPLY_FOLD = 37
    /** The drag declarations (docs/dnd-plan.md D1, D8); the arms are a depth slice. */
    private const val APPLY_SET_DRAG_SOURCE = 38
    private const val APPLY_SET_DROP_TARGET = 39
    private const val APPLY_SET_REORDERABLE = 40
    /** What a drop settles on (the wire's drag_op). */
    internal const val DRAG_OP_NONE = 0
    internal const val DRAG_OP_COPY = 1
    internal const val DRAG_OP_MOVE = 2

    /** kaya's row payload for a reorder (docs/dnd-plan.md D8): the moved
     * row's key path, dot-joined, under a kaya-private id. */
    internal const val ROW_DRAG_TYPE = "dev.kaya/row"

    /** The clipboard pair: a copy going out, and the privileged read
     * asking for one back. */
    private const val APPLY_COPY = 25
    private const val APPLY_READ_CLIPBOARD = 26

    /**
     * A1's clear (docs/undo-plan.md §3): a core undo group committed, so
     * the FOCUSED editable's native text-undo history goes with it.
     * TARGETLESS ON THE WIRE — the core does not know what holds focus
     * and this backend does — so every episode begins with an EMPTY
     * native stack and can never reach past its own start.
     */
    private const val APPLY_CLEAR_UNDO = 27

    /**
     * The three text-range records (docs/ranges-plan.md). THE OFFSETS
     * THAT ARRIVE HERE ARE UTF-16 CODE UNITS, already converted by the
     * core, so nothing on this path counts characters.
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
    private const val WPROP_PANES = 6
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

    /**
     * THE CHROME'S OWN TAGS: they scope `expect_toolbar` to the composed
     * `TopAppBar`, so a promoted button fallen into the page is not
     * "found". [TOOLBAR_MORE_TAG] is the ⋮ anchor, synthesized because
     * material3 1.3.1 has none — anchored IN the bar, which is why this
     * backend reports `overflow` and not `more`.
     */
    const val TOOLBAR_TAG = "kaya:toolbar"
    const val TOOLBAR_MORE_TAG = "kaya:toolbar-more"

    /**
     * THE BAR'S TITLE SLOT, tagged so `expect_title` reads the string
     * the user is looking at. TAGGED AND NOT FOUND BY SHAPE: the bar's
     * `actions` slot composes `TextButton`s whose labels are `Text`
     * too, so "the first Text under the chrome" moves when a promoted
     * item loses its symbol.
     */
    const val TOOLBAR_TITLE_TAG = "kaya:toolbar-title"

    /** The prefix every SECTION SWITCHER ROW's test tag carries —
     * [kayaSectionTag]'s half that the read scopes on, so the walk can
     * collect every row without knowing any section id. A PREFIX and not
     * one shared tag, because two rows sharing a tag are two rows the
     * tree cannot tell apart. */
    const val SECTION_TAG_PREFIX = "kaya:section#"
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
    const val KIND_CANVAS = 15
    const val KIND_DATE_PICKER = 16
    const val KIND_TIME_PICKER = 17
    private const val PROP_TEXT = 1
    private const val PROP_CHECKED = 2
    private const val PROP_VALUE = 3
    private const val PROP_MIN = 4
    private const val PROP_MAX = 5
    private const val PROP_SOURCE = 6
    private const val PROP_GROW = 7
    private const val PROP_SPACING = 8
    private const val PROP_ALIGN = 9
    private const val PROP_AXIS = 18
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
     * MEANS, never how it looks. The root refuses a role on a kind it
     * does not fit, so every value arriving here is already legal. */
    private const val PROP_ROLE = 16
    private const val PROP_INSET = 17

    // The pickers' slots (docs/datetime-plan.md D2/D3/D4): three packed
    // decimal I64s — YYYYMMDD for a date, HHMM for a time — and a count.
    private const val PROP_DATE = 19
    private const val PROP_TIME = 20
    private const val PROP_MIN_DATE = 21
    private const val PROP_MAX_DATE = 22
    private const val PROP_MINUTE_STEP = 23
    // The slider's step and tick spacing (docs/slider-plan.md S1, S5).
    private const val PROP_STEP = 24
    private const val PROP_TICK_SPACING = 25
    // Help text (docs/tooltip-plan.md T1), universal like the a11y props.
    private const val PROP_HELP = 26
    // The role enum's wire values (spec enum "role"). Long, because the
    // prop rides as an i64 and the render arms compare against the
    // node's own field.
    const val ROLE_DESTRUCTIVE = 1L
    const val ROLE_PROMINENT = 2L
    const val ROLE_HEADING = 3L
    const val ROLE_CAPTION = 4L
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
     * THE MATERIAL COLUMN: (wire value, semantic name, glyph);
     * `kayaSymbolTable` is the SwiftUI sibling. No version floor to
     * check, unlike the SF column — a missing ImageVector is a compile
     * error. The semantic name is what TalkBack speaks and what
     * expect_menu_symbol reads off the composed row.
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

    // The five canvas enums (spec enums; wire.rs's DRAW_OPS, PAINTS,
    // FILL_RULES, TEXT_ALIGNS, TEXT_BASELINES). Long, like the role and
    // symbol values: they ride the op stream as i64.
    private const val DRAW_MOVE_TO = 1L
    private const val DRAW_LINE_TO = 2L
    private const val DRAW_CLOSE = 3L
    private const val DRAW_STROKE = 4L
    private const val DRAW_FILL = 5L
    private const val DRAW_FONT = 6L
    private const val DRAW_TEXT = 7L
    private const val PAINT_SERIES = 1L
    private const val PAINT_SERIES_FILL = 2L
    private const val PAINT_GRID = 3L
    private const val PAINT_AXIS = 4L
    private const val PAINT_GROUND = 5L
    private const val FILL_NONZERO = 0L
    private const val FILL_EVEN_ODD = 1L
    private const val TEXT_ALIGN_START = 0L
    private const val TEXT_ALIGN_MIDDLE = 1L
    private const val TEXT_ALIGN_END = 2L
    private const val TEXT_BASELINE_ALPHABETIC = 0L
    private const val TEXT_BASELINE_MIDDLE = 1L
    private const val TEXT_BASELINE_TOP = 2L
    private const val TEXT_BASELINE_BOTTOM = 3L

    /**
     * THE CANVAS WIRE VOCABULARY THIS BACKEND DOES NOT READ: the core
     * rasterizes and a backend blits (docs/canvas-plan.md §1.1). The
     * copies exist so a drifted number fails a gate rather than a lane,
     * and naming them once here is what keeps check-detekt off them.
     */
    val CANVAS_VOCABULARY: List<Long> = listOf(
        APPLY_SET_DRAWING.toLong(),
        DRAW_MOVE_TO, DRAW_LINE_TO, DRAW_CLOSE, DRAW_STROKE, DRAW_FILL, DRAW_FONT, DRAW_TEXT,
        PAINT_SERIES, PAINT_SERIES_FILL, PAINT_GRID, PAINT_AXIS, PAINT_GROUND,
        FILL_NONZERO, FILL_EVEN_ODD,
        TEXT_ALIGN_START, TEXT_ALIGN_MIDDLE, TEXT_ALIGN_END,
        TEXT_BASELINE_ALPHABETIC, TEXT_BASELINE_MIDDLE, TEXT_BASELINE_TOP,
        TEXT_BASELINE_BOTTOM,
    )
    private const val VALUE_BOOL = 1
    private const val VALUE_I64 = 2
    private const val VALUE_F64 = 3
    private const val VALUE_STR = 4
    private const val VALUE_BLOB = 5

    /**
     * The clip masks (wire.rs's CLIP_*): BIT POSITIONS in the CANONICAL
     * descending order — custom, files, image, html, text — which is
     * richness and so preference order. A private mirror, pinned by
     * check-verbs' clip_mirrors clause because a drift is SILENT.
     */
    internal const val CLIP_TEXT = 1
    internal const val CLIP_HTML = 2
    internal const val CLIP_IMAGE = 4
    internal const val CLIP_FILES = 8
    internal const val CLIP_CUSTOM = 16

    /**
     * The Activity this process is currently presenting into, or null
     * between a destroy and the next mount. SWAPPED, never re-created:
     * every activity-needing verb reads it fresh, so a picker or a
     * clipboard call in the gap refuses through its own null check
     * instead of touching a destroyed one.
     */
    @JvmStatic
    private var mountedActivity: ComponentActivity? = null

    /**
     * THE BUILD-ONCE LATCH (docs/deferred.md's mount entry). Android
     * relaunches an activity for any configuration change it does not
     * declare, so `onCreate` runs again in ONE process: everything
     * per-PROCESS (the pump, the guest, the harness thread) is taken
     * once here while everything per-WINDOW is re-applied.
     */
    private var mounted = false

    /**
     * The pump's hop to the UI thread. A main-looper Handler and NOT a
     * captured `activity.runOnUiThread`: the pump outlives every
     * activity, and a captured one posts into a destroyed window's
     * handler after a recreation.
     */
    private val mainThread = Handler(Looper.getMainLooper())

    /**
     * The forced appearance for this process, or null. Read by
     * `KayaAppearance` below; written before every `setContent`, so a
     * fresh composition after a relaunch reads the same answer.
     */
    internal var appearanceOverride: String? = null

    /**
     * `KAYA_APPEARANCE=light|dark` (CLAUDE.md's check-appearance
     * paragraph). UNSET INSTALLS NOTHING; a value that is neither word
     * dies here. BOTH HALVES MOVE DIRECTLY, WITHOUT A RELAUNCH, and both
     * are required — `isSystemInDarkTheme()` alone leaves the MANIFEST
     * theme's background light, the half-dark app D1 fixed.
     */
    private fun applyAppearanceOverride(activity: ComponentActivity) {
        val want = System.getenv("KAYA_APPEARANCE") ?: return
        check(want == "light" || want == "dark") {
            "kaya: KAYA_APPEARANCE=$want is not a mode; use light or dark"
        }
        appearanceOverride = want
        // THE WINDOW BACKGROUND HALF. createConfigurationContext gives the
        // app's own resources under the forced night bits; setting the
        // manifest theme on it resolves values-night/themes.xml exactly as
        // the system would have on a night device.
        val forced = Configuration(activity.resources.configuration).apply {
            uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or nightBits(want)
        }
        val themed = activity.createConfigurationContext(forced)
        themed.setTheme(activity.applicationInfo.theme)
        val attrs = themed.obtainStyledAttributes(intArrayOf(android.R.attr.windowBackground))
        val background = attrs.getDrawable(0) ?: ColorDrawable(attrs.getColor(0, 0))
        attrs.recycle()
        activity.window.setBackgroundDrawable(background)
        appearanceAppliedTo = activity
    }

    /**
     * The window the override's background write last landed on: that
     * half is per-WINDOW, and a re-created window carries the manifest
     * theme's background again. `kayaRecreate` reads this back, the only
     * witness there is (tools/check-appearance.py holds the rest).
     */
    private var appearanceAppliedTo: ComponentActivity? = null

    internal fun nightBits(want: String): Int =
        if (want == "dark") Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO

    /**
     * Mount the interpreter into `activity`, from onCreate when
     * [Kaya.attach] returns [Kaya.PRESENT_GUEST]. RE-ENTRANT ACROSS A
     * RELAUNCH, and `mounted` decides the split: a later onCreate
     * RE-ATTACHES ONLY. The core is not resynced — KayaSceneModel is
     * process-global and a fresh composition re-projects all of it.
     */
    fun mount(activity: ComponentActivity) {
        val first = !mounted
        mounted = true
        mountedActivity = activity
        // PER WINDOW, so it runs on every attach: the override's second
        // half is a window-background write and the new window has the
        // manifest theme's again (tools/check-appearance.py).
        applyAppearanceOverride(activity)
        // THE LAG-FREE HALF OF THE STRAGGLER-BACK GATE
        // (KayaHarnessAccessibility.dismiss): a dialog on top means this
        // activity is PAUSED, and onActivityResult precedes onResume by
        // OS contract. Read in-process rather than from the
        // accessibility window list, which lags both ways
        // (docs/deferred.md's dialog-family WATCH).
        activity.lifecycle.addObserver(
            LifecycleEventObserver { source, event ->
                when (event) {
                    Lifecycle.Event.ON_RESUME -> KayaHarnessAccessibility.appResumed = true
                    Lifecycle.Event.ON_PAUSE -> KayaHarnessAccessibility.appResumed = false
                    // IDENTITY-GUARDED: the newcomer's onCreate can
                    // precede the incumbent's onDestroy, and clearing
                    // the slot then would blind every verb for the rest
                    // of the run.
                    Lifecycle.Event.ON_DESTROY ->
                        if (mountedActivity === source) mountedActivity = null
                    else -> Unit
                }
            },
        )
        if (first) {
            KayaSceneModel.windowTitle = activity.title?.toString() ?: ""
            val host = KayaPresent.specHash()
            check(host.toULong() == SPEC_HASH) {
                "kaya: stale Compose interpreter — its spec hash %016x does not match the core's %016x; rebuild the APK".format(SPEC_HASH, host)
            }
            startPump()
        }
        // THE TITLE IS MATERIALIZED ON THE ACTIVITY (expect_title reads
        // `activity.title`), so a re-created one carries the MANIFEST
        // label until the model is written back onto it.
        refreshNavTitle()
        // The ONE place this backend's theme is installed: every scene,
        // dialog and dropdown is a sub-composition of this one.
        activity.setContent { KayaAppearance { KayaTheme { KayaRoot() } } }
        // ONCE PER PROCESS: a second admission starts a second script
        // runner, and two harness threads race one scene to two verdicts.
        if (first && System.getenv("KAYA_SELFTEST") != null) admitSelftestOnFirstDraw(activity)
    }

    /** The visible title: the top entry's while the stack is covered
     * (materialized as the Activity task label, the surface-title
     * path expect_title reads), the window's own when it empties. */
    internal fun refreshNavTitle() {
        val top = KayaSceneModel.navEntries.lastOrNull()
        mountedActivity?.title = top?.title ?: KayaSceneModel.windowTitle
    }

    /**
     * The hardware-keyboard shortcut route (ChromeOS/DeX). Drives the
     * SAME catalog table and activation helper a rendered row uses, so
     * a chord and a tap are one dispatch path. The shell Activity
     * forwards here ON THE UI THREAD. True when a catalog action owned
     * the chord.
     */
    @JvmStatic
    fun dispatchKeyShortcutEvent(event: KeyEvent): Boolean {
        val spelling = kayaShortcutSpelling(event) ?: return false
        return kayaDispatchShortcut(spelling)
    }

    /**
     * A key event's canonical wire spelling — lowercase, modifiers in
     * `primary`, `shift`, `alt` order, one key from the closed floor.
     * `primary` is ctrl off Apple hosts. Escape never maps (the root
     * rejects the spelling outright) and bare alphanumerics are typing,
     * never chords; an unmapped event falls through to the platform.
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

    private fun startPump() {
        thread(name = "kaya-compose-pump") {
            while (true) {
                // THE CORE SIZES THE BATCH (KayaPresent.nextCommands).
                val batch = KayaPresent.nextCommands() ?: break
                // Blob handles are batch-local: the next nextCommands
                // call replaces the core's table, and the UI-thread
                // apply may run after that. Fetch every referenced blob
                // here, on the pump thread, within the batch; the bytes
                // travel with it.
                val blobs = collectBlobs()
                mainThread.post { apply(batch, blobs) }
            }
        }
    }

    /**
     * Every blob the batch registered, fetched on the pump thread before
     * the next nextCommands call invalidates the handles: the table is the
     * whole truth, so no record layout decides what arrives (docs/traps.md:
     * A BLOB HANDLE DIES WITH ITS BATCH).
     */
    private fun collectBlobs(): Map<Long, ByteArray> {
        val blobs = HashMap<Long, ByteArray>()
        val count = KayaPresent.blobCount()
        var handle = 1L
        while (handle <= count) {
            KayaPresent.blobData(handle)?.let { blobs[handle] = it }
            handle += 1
        }
        return blobs
    }

    private fun apply(batch: ByteArray, blobs: Map<Long, ByteArray>) {
        val b = ByteBuffer.wrap(batch).order(ByteOrder.LITTLE_ENDIAN)
        // THE BATCH'S DESTROYED IDS, AND THE PARENTS THAT HELD THEM —
        // detached once at the end rather than one by one. MEASURED
        // 2026-08-25: a SnapshotStateList removal copies the whole list,
        // so N removals from one parent are O(N^2) with an allocation
        // per element, and per-widget removal of a 2,000-row table's
        // first band (~1,950 rows, 5,850 widgets, ONE batch) wedged the
        // UI thread past the harness's 60s step ceiling.
        val doomed = HashSet<Long>()
        val bereaved = HashSet<Long>()
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
                        KIND_CANVAS -> KayaSceneModel.canvases.add(node)
                        KIND_DATE_PICKER -> KayaSceneModel.datePickers.add(node)
                        KIND_TIME_PICKER -> KayaSceneModel.timePickers.add(node)
                    }
                }
                APPLY_SET_PROP -> {
                    val id = b.long
                    val prop = b.int
                    b.int // pad
                    when (prop) {
                        // D7 + A3 ride HERE rather than at the authoring
                        // site: an inverse the CORE writes is an
                        // ordinary SetProp Text record, so it travels
                        // the same clear a forward write does.
                        PROP_TEXT ->
                            kayaWriteText(KayaSceneModel.nodes[id]!!, kayaLf(readString(b)))
                        PROP_CHECKED -> KayaSceneModel.nodes[id]!!.checked = readBool(b)
                        PROP_VALUE -> {
                            // A PROGRAMMATIC WRITE IS ALSO THE SETTLED
                            // VALUE (docs/slider-plan.md S2): it echoes
                            // nothing, and the next gesture's commit
                            // compares against what the app just wrote.
                            val node = KayaSceneModel.nodes[id]!!
                            node.value = readF64(b)
                            node.committed = node.value
                        }
                        PROP_MIN -> KayaSceneModel.nodes[id]!!.minValue = readF64(b)
                        PROP_MAX -> KayaSceneModel.nodes[id]!!.maxValue = readF64(b)
                        PROP_GROW -> KayaSceneModel.nodes[id]!!.grow = readF64(b)
                        PROP_SPACING ->
                            KayaSceneModel.nodes[id]!!.spacing = readF64(b)
                        PROP_ALIGN ->
                            KayaSceneModel.nodes[id]!!.align = readI64(b)
                        PROP_AXIS ->
                            KayaSceneModel.nodes[id]!!.axis = readI64(b)
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
                            // Stored UNPARSED: the STRING is the
                            // contract, and kayaParseAcceptList splits
                            // it at each use. EMPTY IS UNSET, which is
                            // not "takes nothing" — an undeclared widget
                            // still pastes through the platform's own
                            // insertion.
                            KayaSceneModel.nodes[id]!!.accepts = readString(b)
                        PROP_ROLE ->
                            KayaSceneModel.nodes[id]!!.role = readI64(b)
                        PROP_INSET ->
                            KayaSceneModel.nodes[id]!!.inset = readF64(b)
                        PROP_DATE -> KayaSceneModel.nodes[id]!!.date = readI64(b)
                        PROP_TIME -> KayaSceneModel.nodes[id]!!.time = readI64(b)
                        PROP_MIN_DATE -> KayaSceneModel.nodes[id]!!.minDate = readI64(b)
                        PROP_MAX_DATE -> KayaSceneModel.nodes[id]!!.maxDate = readI64(b)
                        PROP_MINUTE_STEP ->
                            KayaSceneModel.nodes[id]!!.minuteStep = readF64(b).toInt()
                        PROP_HELP ->
                            KayaSceneModel.nodes[id]!!.help = readString(b)
                        PROP_STEP -> KayaSceneModel.nodes[id]!!.step = readF64(b)
                        PROP_TICK_SPACING ->
                            KayaSceneModel.nodes[id]!!.tickSpacing = readF64(b)
                        PROP_SOURCE -> {
                            // A null bitmap is the PLACEHOLDER class,
                            // never a crash — imageSize stays "0x0".
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
                        WPROP_PANES -> KayaSceneModel.panes = readI64(b)
                        // The unsaved-work mark (docs/dirty-plan.md D4).
                        // It APPLIES and lowers to NO CHROME, which is
                        // not being ignored: expect_dirty reads the
                        // value back, so a prop dropped on the wire
                        // fails. NOT INTO THE TITLE, on any platform —
                        // the task label stays the app's own string.
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
                    // Values block of 2*count I64s, read IN PAIRS, in
                    // UTF-16 code units. RECORDED WITH THE TEXT IT WAS
                    // DECLARED AGAINST (D2's clear-on-edit): an earlier
                    // text write in this batch has already landed,
                    // because kayaWriteText writes the state
                    // synchronously.
                    val hid = b.long
                    val hcount = b.int
                    b.int // reserved
                    // The Values block's OWN header — a slot count and
                    // a pad before the first value, 2*count here.
                    // Reading it as a value's type tag fails with
                    // `expected an i64 value, got type 6`.
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
                    // PERFORMED WHERE IT IS DECODED, unlike the reveal
                    // below: a selection needs no layout. THAT ORDER IS
                    // REQUIRED — kaya's own write places the cursor at
                    // the end and would undo the selection.
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
                    // A1 (docs/undo-plan.md §3): { u64 window } and
                    // nothing else. Android is one Activity and one
                    // surface, so the window is read and dropped.
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
                    // IS the encoding. The label is the panel's own
                    // affordance and an intent has nowhere to put it;
                    // the extensions are space-separated and may carry
                    // dots. ADVISORY on every platform.
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
                    // A STR AND THEN A LIST, a body shape no other apply
                    // record has: the suggested name is a Value
                    // (self-padded to 8) and the filter pairs follow, so
                    // the count is read from wherever the NAME ended. A
                    // decoder assuming the picker's fixed header reads
                    // the name's padding as the count.
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
                        // A standard-command role. Nothing relocates —
                        // Android has no application menu — but the role
                        // CHANGES BEHAVIOR: activation performs
                        // cut/copy/paste on the focused widget, and
                        // enablement intersects what the clipboard offers
                        // with what that widget accepts. Snapshot state.
                        MPROP_ROLE -> item.role = readString(b)
                        MPROP_ICON -> {
                            // A null decode is the placeholder class,
                            // never a crash.
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
                    // A choice widget's label children are its OPTIONS,
                    // not standalone widgets, so they leave the
                    // harness's label#N registry — their create arm
                    // appended before this parent was known, and
                    // without this every later label shifts index.
                    val parentNode = KayaSceneModel.nodes[parent]!!
                    val parentKind = parentNode.kind
                    if (parentKind == KIND_SELECT || parentKind == KIND_RADIO) {
                        KayaSceneModel.labels.removeAll { it.id == child }
                    }
                    // A row stamped into a reorderable For after the
                    // declaration landed (docs/dnd-plan.md D8).
                    if (parentNode.reorderable) {
                        KayaSceneModel.nodes[child]!!.reorderIn = parentNode
                    }
                }
                APPLY_SET_DRAG_SOURCE -> {
                    // { u64 id; u32 present; u32 file_count; u32
                    // custom_count; u32 operations; u32 tag_len; u32
                    // reserved } then a Values block in the copy
                    // record's canonical order — custom pairs, files,
                    // image, html, text — and the identity tag after it.
                    val id = b.long
                    val present = b.int
                    val fileCount = b.int
                    val customCount = b.int
                    val ops = b.int
                    val tagLen = b.int
                    b.int // reserved
                    b.int // slots — the prefetch walk's business
                    b.int // reserved
                    val custom = ArrayList<Pair<String, ByteArray>>(customCount)
                    repeat(customCount) {
                        val cid = readString(b)
                        custom.add(Pair(cid, blobs[readBlobHandle(b)] ?: ByteArray(0)))
                    }
                    val files = (0 until fileCount).map { readString(b) }
                    val image =
                        if (present and CLIP_IMAGE != 0) blobs[readBlobHandle(b)] else null
                    val html = if (present and CLIP_HTML != 0) readString(b) else null
                    val text = if (present and CLIP_TEXT != 0) readString(b) else null
                    val tag = ByteArray(tagLen).also { b.get(it) }
                    val node = KayaSceneModel.nodes[id]
                        ?: error("kaya: set_drag_source targets unknown widget $id")
                    // A ZERO present WITH NO FILES AND NO CUSTOM
                    // WITHDRAWS the declaration (the record's own rule).
                    val empty = present == 0 && files.isEmpty() && custom.isEmpty()
                    node.dragPayload =
                        if (empty) null
                        else KayaDragPayload(text, html, image, files, custom)
                    node.dragOps = if (empty) 0 else ops
                    node.dndTag = tag
                }
                APPLY_SET_DROP_TARGET -> {
                    // { u64 id; u32 operations; u32 tag_len; tag }
                    val id = b.long
                    val ops = b.int
                    val tagLen = b.int
                    val tag = ByteArray(tagLen).also { b.get(it) }
                    val node = KayaSceneModel.nodes[id]
                        ?: error("kaya: set_drop_target targets unknown widget $id")
                    node.dropOps = ops
                    node.dndTag = tag
                }
                APPLY_SET_REORDERABLE -> {
                    // { u64 id; u32 enabled; u32 tag_len; tag } — the tag
                    // is the CONTAINER's, so a landing's identity is the
                    // For the app registered on (D8, amended).
                    val id = b.long
                    val enabled = b.int
                    val tagLen = b.int
                    val tag = ByteArray(tagLen).also { b.get(it) }
                    val node = KayaSceneModel.nodes[id]
                        ?: error("kaya: set_reorderable targets unknown widget $id")
                    node.reorderable = enabled != 0
                    node.dndTag = tag
                    // The rows already stamped; a later one takes it at
                    // add_child.
                    node.children.forEach { it.reorderIn = if (enabled != 0) node else null }
                }
                APPLY_FOLD -> {
                    // The stacked fold (D7). Order is the core's
                    // emission order — the row's declaration order — so
                    // add() holds sibling order.
                    val child = b.long
                    val table = b.long
                    val node = KayaSceneModel.nodes[child]
                    if (node != null) {
                        if (node.foldedInto != 0L) {
                            KayaSceneModel.nodes[node.foldedInto]
                                ?.foldedChildren?.removeAll { it.id == child }
                        }
                        node.foldedInto = table
                        if (table != 0L) {
                            KayaSceneModel.nodes[table]?.foldedChildren?.add(node)
                        }
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
                        doomed.add(id)
                        bereaved.add(parent)
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
                            // THE EMISSION IS EXPLICIT AND THE OBSERVER
                            // IS SILENT: kayaWriteText moves the model
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
                APPLY_SET_BRAND ->
                    // ELEVEN packed sRGB words in the wire's fixed
                    // order: seed, light's five, dark's five. THIS
                    // BACKEND READS THE FIRST AND NOTHING ELSE
                    // (docs/styling-plan.md D1) — Material derives the
                    // rest from a seed. The other ten are skipped by the
                    // record cursor at the bottom of this loop.
                    KayaSceneModel.brandSeed = b.int
                APPLY_SET_APP_IDENTITY -> {
                    // { u32 mask; u32 reserved } then the name, then the
                    // icon slot — always written, the mask says whether
                    // it means anything (wire.rs's write_app_identity).
                    val mask = b.int
                    b.int // reserved
                    val name = readString(b)
                    val icon =
                        if (mask and 1 != 0) {
                            blobs[readBlobHandle(b)]
                        } else {
                            skipValue(b)
                            null
                        }
                    // NOTHING IS DRAWN FROM HERE, BY RULING
                    // (docs/app-identity-plan.md I6). DECODED FOR THE
                    // READ: the package carries the mark whether or not
                    // a guest declared one, so without these two fields
                    // `expect_app_icon` would pass on a run that
                    // declared nothing.
                    KayaSceneModel.appIdentityName = name
                    KayaSceneModel.appIdentityIcon = icon
                }
                APPLY_SET_COLUMN_HEADERS -> {
                    // { u64 id; u32 sorted; u32 direction; u32 count;
                    // u32 tag_len; Values titles; tag bytes }. STORED,
                    // NOT YET DRAWN: the synthesized-header lowering is
                    // the Compose breadth slice (docs/tables-plan.md);
                    // decoding now keeps the pump total over the apply
                    // vocabulary and feeds the verbs when they land.
                    val id = b.long
                    val sorted = b.int
                    val direction = b.int
                    val count = b.int
                    val tagLen = b.int
                    b.int // the Values run's own count
                    b.int // reserved
                    val titles = (0 until count).map { readString(b) }
                    val tag = ByteArray(tagLen).also { b.get(it) }
                    while (b.position() % 8 != 0) b.get()
                    val node = KayaSceneModel.nodes[id]
                        ?: error("kaya: set_columns targets unknown widget $id")
                    node.tableGeometryGeneration += 1
                    node.cellEdgeX.clear()
                    node.cellEdgeRightX.clear()
                    node.tableTrackW = -1f
                    node.tableDrawnW = -1f
                    node.tableContentW = -1f
                    node.tableViewportLeftX = -1f
                    node.tableViewportRightX = -1f
                    node.tableViewportH = -1f
                    node.tableContentH = -1f
                    node.tableColumns = titles
                    node.tableSorted = sorted
                    node.tableDirection = direction
                    node.sortTag = tag
                }
                APPLY_SET_DRAWING -> {
                    // THE RASTER, not the ops: { u64 id; u32 width;
                    // u32 height; Value scale; Value pixels } —
                    // premultiplied RGBA8 the core produced
                    // (docs/canvas-plan.md §1.1). This backend
                    // interprets no draw op and owns no drawing API;
                    // its arm is the raw-pixel sibling of the image
                    // arm's decode.
                    val id = b.long
                    val width = b.int
                    val height = b.int
                    b.int // the scale value's type
                    b.int // its len
                    val scale = b.double
                    val handle = readBlobHandle(b)
                    val node = KayaSceneModel.nodes[id]
                        ?: error("kaya: set_drawing targets unknown widget $id")
                    node.drawingScale = if (scale.isFinite() && scale > 0.0) scale else 1.0
                    node.drawing = kayaDrawingBitmap(blobs[handle], width, height)
                }
                APPLY_SET_TYPEFACE -> {
                    // { u32 mask; u32 platform } then the default
                    // family, the per-platform pairs, and the font slot
                    // — the request UNRESOLVED, because resolving it is
                    // this side's job (docs/styling-plan.md Slice 2b).
                    val mask = b.int
                    // WHICH ROW IS MINE, stamped by the core. This file
                    // keeps NO copy of the platform vocabulary — a
                    // private copy here and another in Swift is the
                    // CLIP_* mirror trap.
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
        for (parent in bereaved) {
            KayaSceneModel.nodes[parent]?.children?.removeAll { it.id in doomed }
        }
        // THE APP ANSWERED. An action verb waits for this before it
        // returns (see kayaAwaitAnswer) — written last, so the count
        // moves only once everything in the batch has landed.
        kayaBatches += 1
    }

    /**
     * AN ACTION RETURNS ONCE THE APP HAS ANSWERED IT — watched
     * 2026-08-06: deleted, a step asserting select_range did NOT move
     * the caret still passed, because the read landed first. BOUNDED AND
     * SILENT (some actions produce no batch), and the bound is a CLOCK:
     * 60 sleeps of 5ms ran to 2400ms under load (docs/traps.md).
     */
    private fun kayaAwaitAnswer(seen: Int) {
        var last = seen
        var quiet = 0
        val silentUntil = System.nanoTime() + 1_000_000_000L
        repeat(60) {
            val now = kayaBatches
            when {
                now != last -> { last = now; quiet = 0 }
                // A BATCH IS NOT ENOUGH, IT HAS TO BE THE LAST ONE: the
                // app may still be answering something from BEFORE this
                // action, and returning on that batch leaves the
                // action's own answer in flight. Wait for the batches to
                // STOP rather than for one to arrive.
                now != seen -> { quiet += 1; if (quiet >= 3) return }
                // Nothing has arrived at all, so nothing is in flight.
                System.nanoTime() > silentUntil -> return
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
        // parse. A reader that stops at the payload's end misparses the
        // next value as type 0.
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

    private fun admitSelftestOnFirstDraw(activity: ComponentActivity) {
        val decor = activity.window.decorView
        decor.viewTreeObserver.addOnPreDrawListener(
            object : ViewTreeObserver.OnPreDrawListener {
                override fun onPreDraw(): Boolean {
                    decor.viewTreeObserver.removeOnPreDrawListener(this)
                    startSelftest(activity)
                    return true
                }
            },
        )
    }

    /**
     * The harness's Kotlin interpreter: the grammar the Rust backends
     * embed from tools/scenes, targets as kind#index, and `;` accepted
     * as a newline stand-in — THE INTENT-EXTRA TRANSPORT CANNOT CARRY
     * NEWLINES. Results go to logcat; halt rather than exit, so no
     * teardown hook races the render threads.
     */
    private fun startSelftest(activity: ComponentActivity) {
        val script = System.getenv("KAYA_SELFTEST_SCRIPT")
        if (script == null) {
            Log.e("kaya", "KAYA_SELFTEST: FAILED (no KAYA_SELFTEST_SCRIPT in the environment)")
            activity.finishAndRemoveTask()
            Runtime.getRuntime().halt(1)
            return
        }
        thread(name = "kaya-selftest") { runScript(script) }
    }

    /**
     * THE ACTIVITY THE HARNESS IS TALKING TO RIGHT NOW — a getter, not a
     * captured value, which is what makes `runScript` survive a
     * relaunch (docs/deferred.md's mount entry). Every OTHER caller
     * keeps its own `mountedActivity ?: <refusal>`: those run off the
     * harness thread, where the destroy-to-mount gap is theirs.
     */
    private val activity: ComponentActivity
        get() = mountedActivity
            ?: error("kaya: the harness has no mounted activity")

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

    /** One `drag` verb's request line, or the sentence that stopped it. */
    private class KayaDragPlan(
        val error: String?,
        val line: String = "",
        val sourceId: Long = 0L,
        val seq: Int = 0,
    )

    /**
     * WAIT FOR THE LAYOUT THE LAST BATCH IMPLIES. Every drag-and-drop
     * surface publishes its box from `onGloballyPositioned`, which runs
     * in a frame's layout phase — so a `drag` issued in the same
     * millisecond an `expect_order` read the MODEL back would aim at the
     * PREVIOUS arrangement's boxes, which is measured: the second
     * reorder injected the rows' pre-reorder centres and dropped a row
     * onto itself (docs/traps.md). Two frames, because a posted callback
     * fires at the START of a frame and the layout follows inside it.
     * AND THE WAIT IS FOR THE FRAME, NOT FOR A SECOND: under a five-lane
     * matrix (host load past 100) an emulator frame can take longer than
     * the 1s this once gave up after, silently, and the verb then aimed at
     * the previous arrangement's boxes — the drop landed in a gap and the
     * drag ended "none", three matrices running (docs/deferred.md's android
     * drag WATCH, decoded by KAYA_DRAG_EVENT 2026-09-04). A frame that never
     * comes in 10s is said out loud instead.
     */
    private fun kayaAwaitFrames(activity: ComponentActivity, frames: Int) {
        repeat(frames) { n ->
            val done = java.util.concurrent.CountDownLatch(1)
            activity.runOnUiThread {
                android.view.Choreographer.getInstance().postFrameCallback {
                    done.countDown()
                }
            }
            if (!done.await(10, java.util.concurrent.TimeUnit.SECONDS)) {
                Log.i("kaya", "KAYA_DRAG_EVENT: frame ${n + 1} of $frames never came in 10s")
            }
        }
    }

    /**
     * Wait until a widget's drag box reads the same on two consecutive frames
     * — the layout has settled where the pointer is about to go — or say so
     * after 10s. The box is what `onGloballyPositioned` last wrote.
     */
    private fun kayaAwaitSettledBox(activity: ComponentActivity, nodeId: Long) {
        val deadline = System.nanoTime() + 10_000_000_000L
        var previous = onUi(activity) { kayaDragBoxes[nodeId]?.let { listOf(it.windowLeft, it.windowTop, it.width, it.height) } }
        var frames = 0
        while (System.nanoTime() < deadline) {
            kayaAwaitFrames(activity, 1)
            frames += 1
            val now = onUi(activity) { kayaDragBoxes[nodeId]?.let { listOf(it.windowLeft, it.windowTop, it.width, it.height) } }
            if (now != null && now == previous) {
                Log.i("kaya", "KAYA_DRAG_EVENT: destination node=$nodeId box=$now settled after $frames frame(s)")
                return
            }
            previous = now
        }
        Log.i("kaya", "KAYA_DRAG_EVENT: destination node=$nodeId box=$previous still moving after 10s")
    }

    /**
     * THE REQUEST THE RUNNER EXECUTES (docs/dnd-plan.md D10): the two
     * widgets' centres in SCREEN PIXELS — each surface's own
     * `boundsInWindow` plus the decor view's location on screen — on the
     * tag the per-leg logcat poll already reads. A reorder aims at the
     * landed row's upper or lower QUARTER, so the before/onto bit is the
     * pointer's own half with room to spare. Main thread.
     */
    private fun kayaDragPlan(
        activity: ComponentActivity,
        sourceSpec: String,
        destinationSpec: String,
        reorder: Boolean?,
    ): KayaDragPlan {
        val source = kayaWidgetTarget(sourceSpec)
            ?: return KayaDragPlan("no such source $sourceSpec")
        val destination = kayaWidgetTarget(destinationSpec)
            ?: return KayaDragPlan("no such destination $destinationSpec")
        val from = kayaDragBoxes[source.id] ?: return KayaDragPlan(
            "$sourceSpec is not a drag source — it declares no payload " +
                "(set_drag_source) and sits in no reorderable For")
        val to = kayaDragBoxes[destination.id] ?: return KayaDragPlan(
            "$destinationSpec is not a drop destination — it declares no " +
                "drop_target and sits in no reorderable For")
        val corner = IntArray(2)
        activity.window.decorView.getLocationOnScreen(corner)
        val x1 = (corner[0] + from.windowLeft + from.width / 2f).toInt()
        val y1 = (corner[1] + from.windowTop + from.height / 2f).toInt()
        val x2 = (corner[0] + to.windowLeft + to.width / 2f).toInt()
        val landing = when (reorder) {
            true -> to.height / 4f
            false -> to.height * 3f / 4f
            null -> to.height / 2f
        }
        val y2 = (corner[1] + to.windowTop + landing).toInt()
        kayaDragRequests += 1
        return KayaDragPlan(
            null,
            "KAYA_REQUEST: draganddrop $kayaDragRequests $x1 $y1 $x2 $y2 $DRAG_INJECT_MS",
            source.id,
            kayaDragRequests)
    }

    /**
     * THE ACK: the platform's own ACTION_DRAG_ENDED for the session this
     * source started, which is the one signal that says the injected
     * gesture ran end to end — a REFUSED drop acks too, since the source
     * still reads `none`, so no ack means no gesture reached the app and
     * the runner may inject again (docs/dnd-plan.md D10). Null when it
     * landed; otherwise ONE sentence carrying the four counters this run
     * measured — a drag that never started reads started=0, which is the
     * whole discriminator.
     */
    private fun kayaAwaitDragEnd(sourceId: Long, endingsBefore: Int): String? {
        val deadline = System.nanoTime() + DRAG_ACK_MS * 1_000_000
        while (System.nanoTime() < deadline) {
            val session = kayaDragSession
            if (kayaDragEndings != endingsBefore && session != null &&
                session.sourceId == sourceId && session.ended
            ) {
                return null
            }
            Thread.sleep(RETRY_PERIOD_MS)
        }
        val session = kayaDragSession?.takeIf { it.sourceId == sourceId }
        return "the injected gesture did not finish in ${DRAG_ACK_MS}ms — " +
            "started=${session?.started ?: 0} entered=${session?.entered ?: 0} " +
            "dropped=${session?.dropped ?: 0} ended=${session?.ended ?: false} " +
            "(the runner runs `input draganddrop` off the KAYA_REQUEST line)"
    }

    /**
     * THE REAL-KEYSTROKE TYPING VERB — harness.rs `Stage::type_text`'s
     * six points. An app may not INJECT events but may DISPATCH into its
     * own window, which drives the field's real undo stack (probe §4/H);
     * it APPENDS with NO caret move, since `edit {}` commits and CLEARS
     * that history; it blocks past this backend's own observation.
     */
    private fun kayaTypeAtFocus(activity: ComponentActivity, text: String): String? {
        if (text.isEmpty()) return "type wants some text to type"
        // CONTRACT POINT 3: TYPING APPENDS, so the caret is collapsed
        // to the end BEFORE the keys and not between them — a selection
        // change mid-run breaks the field's own edit coalescing, which
        // is the granularity the delegated undo tier is made of.
        // Skipped when the caret is already there, or an unconditional
        // edit spends a state commit per `type` to change nothing.
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
            // A KEY NOTHING CONSUMED WAS NOT TYPED, so it is sent again
            // (measured 2026-08-06, two runs in six: a leg's FIRST
            // key-down came back handled=false with the model already
            // reporting focus). The signal is the FIELD'S OWN LENGTH and
            // not dispatchKeyEvent's return — every character here is
            // printable ASCII onto a collapsed caret, so each grows the
            // text by exactly one.
            var tries = 0
            while (true) {
                val was = onUi(activity) { kayaFocusedTextNode()?.textState?.text?.length }
                // ONE UI-THREAD HOP PER CHARACTER, so a runloop turn
                // passes between them exactly as it does between a
                // user's keystrokes.
                onUi(activity) {
                    val now = android.os.SystemClock.uptimeMillis()
                    for (e in events) {
                        // REBUILT RATHER THAN REPLAYED: KeyCharacterMap
                        // hands back events with zeroed timestamps and
                        // no input source, and a key event with no
                        // source is not what a keyboard delivers.
                        activity.dispatchKeyEvent(
                            KeyEvent(
                                now, now, e.action, e.keyCode, 0, e.metaState,
                                android.view.KeyCharacterMap.VIRTUAL_KEYBOARD, e.scanCode, 0,
                                android.view.InputDevice.SOURCE_KEYBOARD,
                            ),
                        )
                    }
                }
                // Nothing focused is legitimate under point 2, so there
                // is nothing to confirm and nothing to retry.
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
     * Point 4's wait: the typing has landed when the MODEL has caught up
     * with the WIDGET, and then HELD STILL — the first is true the
     * instant the collector catches the FIRST keystroke, so a
     * two-character `type` could return with one in flight (measured
     * 2026-08-06, one run in three). A timeout is not a verdict.
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

    internal data class TableStamp(val node: Long, val keys: List<String>)

    internal fun tableStamp(tag: ByteArray): TableStamp? {
        if (tag.size < 16) return null
        val b = ByteBuffer.wrap(tag).order(ByteOrder.LITTLE_ENDIAN)
        val node = b.long
        val count = b.int.toLong() and 0xffff_ffffL
        b.int // reserved
        if (count == 0L || count > ((tag.size - 16) / 8).toLong()) return null
        val keys = ArrayList<String>(count.toInt())
        repeat(count.toInt()) {
            if (b.remaining() < 8) return null
            val type = b.int
            val len = b.int.toLong() and 0xffff_ffffL
            if (type != VALUE_STR || len > b.remaining().toLong()) return null
            val bytes = ByteArray(len.toInt())
            b.get(bytes)
            val padding = (8 - b.position() % 8) % 8
            if (b.remaining() < padding) return null
            b.position(b.position() + padding)
            val key = try {
                Charsets.UTF_8.newDecoder()
                    .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
                    .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes))
                    .toString()
            } catch (_: java.nio.charset.CharacterCodingException) {
                return null
            }
            keys.add(key)
        }
        if (b.hasRemaining()) return null
        return TableStamp(node, keys)
    }

    /**
     * A TABLE TARGET READS ITS COLUMNS' AXIS (docs/tables-plan.md): the
     * target's KIND decides which axis expect_overflow, scroll_end and
     * expect_at_end are about, so none of the three needs an axis word.
     * Null when the spec names no table; every number is read on the UI
     * thread, where the layout wrote it.
     */
    private fun columnsAxis(activity: ComponentActivity, spec: String): KayaColumnsAxis? =
        onUi(activity) {
            target(spec, "column", KayaSceneModel.columns)?.let {
                KayaColumnsAxis(
                    it.tableTrackW, it.tableContentW, it.tableReachX, it.tableScrollX)
            }
        }

    private fun target(spec: String, kind: String, registry: List<KayaNode>): KayaNode? {
        // harness.rs's Target spelling; sortTag is the stamped table identity.
        val at = spec.indexOf('@')
        if (at >= 0) {
            if (spec.substring(0, at) != kind) return null
            val authored = spec.substring(at + 1)
            val open = authored.indexOf('[')
            val id: String
            val keys: List<String>?
            if (open >= 0) {
                if (!authored.endsWith(']')) return null
                val keyText = authored.substring(open + 1, authored.length - 1)
                if (keyText.contains('[') || keyText.contains(']')) return null
                id = authored.substring(0, open)
                if (id.any { it == '[' || it == ']' || it == '@' }) return null
                keys = keyText.split('.')
                if (keyText.isEmpty() || keys.any { it.isEmpty() }) return null
            } else {
                if (authored.any { it == ']' || it == '@' }) return null
                id = authored
                keys = null
            }
            if (id.isEmpty()) return null
            // A DESTROYED NODE MAY NOT ANSWER A TARGET: the registries are
            // append-only and `nodes` is the liveness record, so a stamped
            // copy that left the band would otherwise answer with the empty
            // children its teardown left. The keyed arm below has always
            // filtered this way (docs/virtualization-plan.md §1).
            if (keys == null) {
                return registry.firstOrNull {
                    KayaSceneModel.nodes[it.id] === it && it.a11yId == id
                }
            }
            // A stamped copy of ANY tagged kind resolves by key: the table's
            // sort tag and a widget's occurrence tag carry the same
            // node-and-keys encoding (the keyed-target entry, 2026-09-01).
            val stampOf = { n: KayaNode -> tableStamp(if (kind == "column") n.sortTag else n.tag) }
            val live = registry.filter { KayaSceneModel.nodes[it.id] === it }
            // EVERY copy carrying the id is a candidate, whichever template
            // stamped it: the key path names the copy (tools/scenes/tasks.steps).
            val hits = live.filter { it.a11yId == id && stampOf(it)?.keys == keys }
            if (hits.size != 1) {
                Log.i(
                    "kaya",
                    "KAYA_DIAG keyed target $spec ${if (hits.isEmpty()) "unresolved" else "ambiguous"}: " +
                        "${live.size} live ${kind}s, ${live.count { it.a11yId == id }} carrying id $id")
                return null
            }
            return hits[0]
        }
        val hash = spec.indexOf('#')
        if (hash < 0 || hash != spec.lastIndexOf('#') || spec.substring(0, hash) != kind) {
            return null
        }
        val index = spec.substring(hash + 1)
        if (index == "last") return registry.lastOrNull()
        val i = index.toIntOrNull() ?: return null
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

    /// What the live picker is REALLY showing, or null when none is —
    /// read out of DocumentsUI's own tree through the harness
    /// accessibility service, because the picker is ANOTHER APP.
    ///
    /// Null when the service is not enabled, which FAILS every
    /// expect_file_dialog rather than passing quietly.
    private fun kayaFileDialogState(): Pair<String, List<String>>? =
        KayaHarnessAccessibility.live?.pickerState()?.also {
            kayaNoteDialogSeen(DIALOG_KIND_OPEN)
        }

    /// What the live SAVE panel is really showing: its directory and the
    /// name in its name field, null when none is up. The picker's reader
    /// one dialog over — and the service is what keeps the two from
    /// seeing each other's panel, since DocumentsUI serves both.
    private fun kayaSaveDialogState(): Pair<String, String>? =
        KayaHarnessAccessibility.live?.saveState()?.also {
            kayaNoteDialogSeen(DIALOG_KIND_SAVE)
        }

    /// The save panel's state, WAITED FOR. `expect_save_dialog` gets the
    /// generic retry every expect gets, but the two ACTIONS do not —
    /// and typing into a panel that has not presented does nothing,
    /// after which the leg saves under the SUGGESTED name with every
    /// byte assertion downstream still green.
    private fun kayaAwaitSaveDialogState(): Pair<String, String>? {
        for (i in 0 until SAVE_PANEL_TRIES) {
            kayaSaveDialogState()?.let { return it }
            Thread.sleep(SAVE_PANEL_SETTLE_MS)
        }
        val last = kayaSaveDialogState()
        if (last == null) kayaNoteDialogUnseen(DIALOG_KIND_SAVE)
        return last
    }

    /// THE PRESENTATION INSTRUMENTS (docs/deferred.md's dialog-family
    /// WATCH): nothing else tells a dialog that presented LATE from one
    /// that presented on time and could not be READ — matrix6's picker
    /// was Displayed in 1.06s and answered null reads for 7.4s after.
    /// One line each way, at most once per presentation: KAYA_DIALOG_SEEN
    /// on the first a11y read that sees it, KAYA_DIALOG_UNSEEN on a
    /// reader's budget running out.
    private class KayaDialogPresentation(val dialog: Long, val kind: String) {
        val atMs: Long = android.os.SystemClock.elapsedRealtime()

        @Volatile
        var seen = false

        @Volatile
        var unseenLogged = false
    }

    @Volatile
    private var kayaDialogPresented: KayaDialogPresentation? = null

    private const val DIALOG_KIND_OPEN = "open"
    private const val DIALOG_KIND_SAVE = "save"

    /// What DocumentsUI is showing — or, when no window of its could be
    /// read, that and the window census. The service's own sentence,
    /// with the no-service case spelled here because a missing service
    /// is a runner fault and not a dialog fault.
    private fun kayaDialogReport(): String =
        KayaHarnessAccessibility.live?.dialogReport()
            ?: "no harness accessibility service — the runner did not enable it"

    /// Armed at launch(), so the elapsed milliseconds are measured from
    /// the moment the OS was asked for the dialog.
    private fun kayaNoteDialogPresented(dialog: Long, kind: String) {
        kayaDialogPresented = KayaDialogPresentation(dialog, kind)
    }

    private fun kayaNoteDialogSeen(kind: String) {
        val presented = kayaDialogPresented ?: return
        if (presented.kind != kind || presented.seen) return
        presented.seen = true
        Log.i(
            "kaya",
            "KAYA_DIALOG_SEEN: dialog=${presented.dialog} kind=${presented.kind} " +
                "ms=${android.os.SystemClock.elapsedRealtime() - presented.atMs}",
        )
    }

    /// THE CENSUS IS THE POINT OF THIS ONE: unseen has two causes, a
    /// dialog that never presented and one nobody could read, and only
    /// the window list can say which — with the ids system_server's own
    /// `wait for adding window timeout` names.
    private fun kayaNoteDialogUnseen(kind: String) {
        val presented = kayaDialogPresented ?: return
        if (presented.kind != kind || presented.seen || presented.unseenLogged) return
        presented.unseenLogged = true
        val census = KayaHarnessAccessibility.live?.windowCensus()
            ?: "no harness accessibility service — the runner did not enable it"
        Log.w(
            "kaya",
            "KAYA_DIALOG_UNSEEN: dialog=${presented.dialog} kind=${presented.kind} " +
                "ms=${android.os.SystemClock.elapsedRealtime() - presented.atMs} $census",
        )
    }

    /// How long a save panel is given to present, and how long each look
    /// costs. DocumentsUI is another app being started, so this is a
    /// process launch and not a frame.
    private const val SAVE_PANEL_TRIES = 25
    private const val SAVE_PANEL_SETTLE_MS = 200L

    /// The directory THE GUEST WILL USE — and on Android that is NOT
    /// the temp directory (docs/traps.md): DocumentsUI browses document
    /// PROVIDERS and none exposes app-private storage, so a picker
    /// aimed at the cache dir lands on Recent with no error anywhere.
    /// The shared Documents collection satisfies both halves, and the
    /// guest computes the same place from `EXTERNAL_STORAGE`.
    private fun kayaTempDir(): String =
        android.os.Environment
            .getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_DOCUMENTS)
            .path
            .trimEnd('/')

    /// `$TMP` and `$PID` in a scene path — the same vocabulary
    /// KayaSwiftUI expands, enforced across both by check-verbs. An
    /// unexpanded token becomes a LITERAL path segment, and a picker
    /// pointed at one silently shows somewhere else (docs/traps.md).
    ///
    /// WHOLE NAMES, not prefixes: a textual "$TMP" replacement also
    /// eats the front of "$TMPDIR" and leaves "<tmp>DIR".
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

    /// Choose the named row, or dismiss. Null on success, the failure's
    /// sentence otherwise.
    ///
    /// RUNS OFF THE MAIN THREAD, which the service asserts: it reads
    /// getWindows(), refreshed on the main looper, so a drive that
    /// blocked main would watch a frozen list.
    private fun kayaFileDialogDrive(name: String): String? {
        val svc = KayaHarnessAccessibility.live
            ?: return "no harness accessibility service — the runner did not enable it"
        if (name == "cancel") return svc.dismiss()
        // ROUNDS, NOT ONE SHOT (2026-08-20): under a loaded matrix the
        // picker can be UP with its list still unreadable — DocumentsUI's
        // own log showed its provider cache lock contended — and a
        // one-shot choose() misses instantly into a failure string
        // nobody prints until scene end. The picker being GONE stays the
        // only proof a click landed.
        var clicked = false
        var last: String? = null
        for (round in 0 until 6) {
            if (svc.choose(name)) {
                clicked = true
                kayaNoteDialogSeen(DIALOG_KIND_OPEN)
                if (svc.waitForPickerGone()) return null
                last = "the picker was still up after clicking \"$name\" — the click was swallowed"
            } else {
                if (clicked && svc.waitForPickerGone()) return null
                // WHICH NULL IT WAS: a list that came back empty and a
                // tree nobody could read used to print the same
                // "showing null" (docs/deferred.md's WATCH entry,
                // 2026-08-21 matrix6).
                val listed = kayaFileDialogState()?.second
                last = if (listed != null) {
                    "no row named \"$name\"; the picker lists $listed"
                } else {
                    "no row named \"$name\"; ${svc.dialogReport()}"
                }
                Thread.sleep(500)
            }
        }
        kayaNoteDialogUnseen(DIALOG_KIND_OPEN)
        return last
    }

    /**
     * Present the platform's REAL picker and answer exactly once.
     * ACTION_OPEN_DOCUMENT answers `content://` URIs and NOT paths: the
     * document may not be a file on this device. A single tap answers
     * either way (measured): with ALLOW_MULTIPLE set, one chosen file
     * still comes back through `data.data` with an empty clipData.
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
        // A FINISHING ACTIVITY CAN NEVER RECEIVE THE RESULT — the OS
        // drops it with no line anywhere (measured 2026-08-20: a stray
        // BACK finish()ed the activity mid-scene and the next dialog's
        // result simply vanished; the WATCH entry in docs/deferred.md).
        // Answered honestly HERE, as a cancel with its cause named,
        // instead of floating forever.
        if (activity.isFinishing) {
            Log.w(
                "kaya",
                "KAYA_DIALOG_DOOMED: file dialog $dialog requested from a finishing " +
                    "activity — a result could never arrive; answering cancelled",
            )
            kayaAnswerFileDialog(activity, dialog, null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("*/*")
            // WRITE as well as read: the vocabulary lets a guest reopen
            // a picked handle for writing, and THE GRANT IS DECIDED
            // HERE — asking later is not possible.
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
        // activity — measured to work, which is why no lifecycle-scoped
        // registration is needed in the shell Activity. The key carries
        // the dialog id so a leaked registration cannot collide.
        kayaLivePickerDialog = dialog
        kayaLivePickerLauncher = activity.activityResultRegistry.register(
            "kaya-file-dialog-$dialog",
            ActivityResultContracts.StartActivityForResult(),
        ) { result ->
            // The save dialog's sibling line, same discriminator (see
            // the save launcher below).
            Log.i(
                "kaya",
                "KAYA_PICK_RESULT: dialog=$dialog code=${result.resultCode} " +
                    "uri=${result.data?.data != null}",
            )
            kayaLivePickerDialog = null
            kayaLivePickerLauncher?.unregister()
            kayaLivePickerLauncher = null
            kayaAnswerFileDialog(activity, dialog, result.data)
        }
        // A fresh dialog invalidates prior removal announcements, so a
        // reused window id cannot vouch for a window that is still alive.
        KayaHarnessAccessibility.clearRemovals()
        kayaNoteDialogPresented(dialog, DIALOG_KIND_OPEN)
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

    /// The DISPLAY NAME, not the last URI segment, which is the
    /// provider's document id — a path fragment on ExternalStorage and
    /// an opaque key elsewhere. A SAVED DOCUMENT NEEDS THIS MOST: SAF
    /// appends an extension for the mime type and renames on collision,
    /// `picked.txt` becoming `picked (1).txt` with no prompt (measured),
    /// so only the provider knows the name the document HAS.
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
     * Present the platform's REAL save dialog and answer exactly once,
     * through `ACTION_CREATE_DOCUMENT`. IT ANSWERS WITH A DOCUMENT THAT
     * ALREADY EXISTS, which docs/save-plan.md D1 absorbs in the core,
     * and THE NAME IS A SUGGESTION the platform may not keep — so the
     * frozen scene asserts BYTES and never a file's name.
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
        // ONE TYPE, NOT A LIST: the picker's EXTRA_MIME_TYPES filters
        // what is SHOWN, while a create request's type is what the
        // document will BE. `*/*` when the guest named no filter, which
        // maps to no extension so SAF appends none.
        val mimes = extensions.mapNotNull {
            MimeTypeMap.getSingleton().getMimeTypeFromExtension(it.lowercase())
        }
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType(mimes.firstOrNull() ?: "*/*")
            .putExtra(Intent.EXTRA_TITLE, suggestedName)
            // WRITE as well as read: THE GRANT IS DECIDED HERE and
            // asking later is not possible.
            .addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        kayaPendingPickerDirectory?.let {
            intent.putExtra(DocumentsContract.EXTRA_INITIAL_URI, initialUri(it))
        }

        // The picker's doomed-dialog guard, same wording and reason.
        if (activity.isFinishing) {
            Log.w(
                "kaya",
                "KAYA_DIALOG_DOOMED: save dialog $dialog requested from a finishing " +
                    "activity — a result could never arrive; answering cancelled",
            )
            kayaAnswerSaveDialog(activity, dialog, null)
            return
        }
        kayaLivePickerDialog = dialog
        kayaLivePickerLauncher = activity.activityResultRegistry.register(
            "kaya-save-dialog-$dialog",
            ActivityResultContracts.StartActivityForResult(),
        ) { result ->
            // The save-jvm WATCH's discriminator (docs/deferred.md): a
            // lost third-save result reads the same as a CANCELED one,
            // because the guest's cancel arm rewrites the string the
            // label already shows. This line in the on-FAIL dump splits
            // them: present with code=0 means DocumentsUI answered
            // cancel; absent means delivery itself was lost.
            Log.i(
                "kaya",
                "KAYA_SAVE_RESULT: dialog=$dialog code=${result.resultCode} " +
                    "uri=${result.data?.data != null}",
            )
            kayaLivePickerDialog = null
            kayaLivePickerLauncher?.unregister()
            kayaLivePickerLauncher = null
            kayaAnswerSaveDialog(activity, dialog, result.data)
        }
        KayaHarnessAccessibility.clearRemovals()
        kayaNoteDialogPresented(dialog, DIALOG_KIND_SAVE)
        kayaLivePickerLauncher?.launch(intent)
    }

    /// The created document, or NOTHING for cancel — a null locator
    /// rather than an empty array, because the save entry takes ONE.
    ///
    /// ANSWERED ON `emitSaveDialogResult` AND NOT THE PICKER'S ENTRY,
    /// even though this platform's two sources coincide: the core
    /// decides what a destination IS from which entry it arrives on
    /// (`register_saved` vs `register_picked`).
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
    /// filesystem path there is ignored. AIMED SOMEWHERE THE PLATFORM
    /// HIDES, the extra is accepted and the picker SILENTLY opens on
    /// Recent (measured with `Android/data/...`); only
    /// expect_file_dialog's breadcrumb read catches it.
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

    // Clipboard (docs/clipboard-plan.md §7). MATERIALIZE INSIDE THE
    // READ, ALWAYS: the read grant is revoked the moment the clip
    // changes, so a stashed URI answers SecurityException later.

    /**
     * SystemUI's overlay-suppression extra. Honoured on an emulator (or
     * when the clip's source is the shell) and INERT ON A REAL DEVICE,
     * so production behaviour is unchanged. On the lane it keeps the
     * API 33+ copy preview off the surface the harness is asserting
     * against (docs/clipboard-plan.md §7).
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
     * Put one clip on the system clipboard: ONE ClipData listing every
     * offered mime in descending richness, BUILT BY HAND because
     * `newHtmlText` never advertises text/plain. ITEM 0 CARRIES TEXT AND
     * HTML INLINE — foreign readers look there alone, `coerceToText`
     * answers "" for a content:// item, and SystemUI previews item 0.
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
            // validates or normalizes a mime type, so it rides verbatim.
            KayaClipProvider.customMimeSidecar(activity, i).writeText(pair.first)
            items.add(ClipData.Item(KayaClipProvider.customUri(activity, i)))
        }
        // A FILE LOCATOR IS ALREADY THE DOCUMENT'S OWN `content://` URI
        // on this platform (android.rs, UriSource::locator), so a file
        // item names THE DOCUMENT and never a copy of it through this
        // app's provider: the paster gets the real type and display
        // name, a pasted file stays the SAME capability the picker
        // returns, and the copy arm never reads a file's bytes on the
        // main thread.
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
        // IS the offer, and the resolver overload appends types derived
        // from a provider round-trip per item.
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
     * accept list takes, materialize that one, and answer — null for no
     * intersection. Shared by the privileged read and the declared-paste
     * delivery; descending clip value, MAIN THREAD like every apply arm.
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
            // A URI item IS a file here, so the guest redeems a pasted
            // document exactly as it redeems a picked one.
            val locators = ArrayList<String>()
            val names = ArrayList<String>()
            for (item in items) {
                val uri = item.uri ?: continue
                if (uri.scheme != ContentResolver.SCHEME_CONTENT) continue
                // AN IMAGE RIDES A content:// DOCUMENT HERE TOO, so
                // without this line an image clip answers a files-only
                // read, which no sibling arm does.
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

    /// The clipboard's current OFFER — the description, NEVER the data:
    /// only `getPrimaryClip` raises the platform's access notification
    /// and notes the app op, so deciding enablement costs nothing.
    /// Focus-gated the same way, and null while unfocused.
    private fun kayaClipboardOffer(): ClipDescription? {
        // A SUBSCRIBING READ. The clipboard is not snapshot state, so
        // without this a Paste row rendered before the clip arrived
        // stays grey until something unrelated recomposes. See
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

    /// A document's display name. NEVER the last path segment when the
    /// provider will say: that segment is the document id, a path
    /// fragment on ExternalStorage and an opaque key elsewhere.
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
     * Whether a clipboard role's command can act right now. THE SAME
     * RULE AS THE MAC AND GTK ARMS: paste is the INTERSECTION of the
     * clipboard's offer and the focused widget's accept list, and one
     * that declared NOTHING still pastes on the text offer. NOT A
     * BUILD-TIME FACT — both halves move after the bar was built.
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
            // ASKED ONCE AND USED TWICE (A4): the routing function
            // answers both the enablement question and the activation
            // question, so the two cannot drift. No second predicate.
            "undo" -> return kayaUndoRoute() != KayaUndoRoute.NOTHING
            "redo" -> return kayaRedoRoute() != KayaUndoRoute.NOTHING
            else -> return true
        }
    }

    /**
     * Perform a clipboard role on the focused widget; answers whether it
     * WAS one, so a plain action falls through. THE PASTE SPLIT
     * (DESIGN.md): a widget that DECLARED what it accepts takes the
     * content through the paste hook, one that declared nothing gets the
     * platform's own insertion.
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
                    // THE PLATFORM'S OWN INSERTION: no responder chain
                    // here, and the MODEL owns the field's text.
                    // APPENDED, because kaya has no selection API. IT
                    // COSTS THE FIELD'S TYPING HISTORY — on
                    // TextFieldState no public API makes an app write
                    // undoable (docs/undo-plan.md §1.4 names this site),
                    // so this costs granularity, not history.
                    val pasted = kayaClipboardPlainText() ?: return true
                    kayaWriteText(node, kayaLf(node.text + pasted))
                    KayaPresent.emitTextChanged(
                        node.tag, node.text, KayaSceneModel.focusedId == node.id, false)
                    return true
                }
                // The privileged read's walk, deliberately the same
                // code. A PASTE THAT DELIVERED NOTHING IS NOT AN
                // OCCURRENCE, which kaya_emit_pasted also asserts.
                val value = kayaMaterializeClipboard(node.accepts) ?: return true
                KayaPresent.emitPasted(
                    node.tag, value.clip, value.text, value.bytes, value.locators, value.names)
                return true
            }
            else -> return false
        }
    }

    /**
     * Perform an undo/redo role on the focused surface. A SEPARATE
     * FUNCTION from [kayaPerformClipboardRole]: tools/check-roles.py
     * anchors on the UNION of the `kayaPerform*Role` functions. ROUTING
     * IS KAYA'S HERE (docs/undo-plan.md §1) — a focused field CONSUMES
     * Ctrl+Z whether or not it has anything to undo.
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
     * Cut and Copy on the FOCUSED FIELD'S SELECTION, through
     * SemanticsActions.CutText/CopyText — present ONLY while a selection
     * exists. `edit {}` leaves `canUndo` true when it changes only the
     * SELECTION (range-probe-android.md §2), which is why D7's clear is
     * keyed on the text moving. MAIN THREAD ONLY.
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
     * THE TEXT-RANGE READS, all three, off the platform. The a11y id is
     * how a leg finds a control in the semantics tree, so a textarea
     * with no `a11y_id` cannot be asserted about. MAIN THREAD ONLY
     * (kayaAx's own note).
     */
    private fun kayaSelectionRead(activity: ComponentActivity, spec: String): String {
        val node = kayaTextTarget(spec) ?: return "<no such target>"
        if (node.a11yId.isEmpty()) return "<no a11y_id authored on this widget>"
        val semantics = kayaSemanticsByTag(activity, node.a11yId)
            ?: return "<not in the semantics tree>"
        // THE FIELD'S OWN TEXT, as the platform publishes it. Slicing
        // THIS with the range the platform is holding is what keeps the
        // covered half free of arithmetic.
        val text = kayaSemanticsValue(semantics, SemanticsProperties.EditableText)?.text
            ?: return "<no editable text>"
        val selection = kayaSemanticsValue(semantics, SemanticsProperties.TextSelectionRange)
            ?: return "<no selection>"
        return kayaRangeSpelling(text, listOf(KayaRange(selection.start, selection.end)))
    }

    /**
     * THE HIGHLIGHT READ, AND ITS PAINT WITNESS: every on-screen range is
     * photographed and must contain the decoration, since the record
     * alone stayed GREEN with `drawPath` deleted (docs/traps.md: "The
     * Compose highlight witness composites what it expects, and aims in
     * surface space"). NOT ON THE UI THREAD — `PixelCopy` deadlocks.
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

    /** The photograph, with the space it was taken in carried beside
     * it, so a caller reads pixels by the WINDOW coordinate it has and
     * never by an offset it computed itself. */
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
        // ways: a colour the witness cannot TELL APART from that is one
        // it must not accept. Watched — with the highlight's alpha at
        // zero the decoration composites to the background exactly and
        // the leg passed with nothing on screen. An invisible decoration
        // is an undecorated range and is reported as one.
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
            // NOT SEEN IS NOT THE SAME AS NOT PAINTED: conflating them
            // makes this read accuse the lowering of a defect the
            // window manager committed.
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

    /** `src` composited over an opaque `dst`: the arithmetic that turns
     * kaya's declared colours into the pixel the photograph must
     * contain. */
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

    /** The field's viewport, out of the window's own surface. THE
     * SRCRECT IS IN SURFACE SPACE where the caller's rectangle is in
     * window space, differing by `decorView`'s location; clipped to the
     * surface too, since a panned window puts part of the field outside
     * it and the rest is still worth photographing. */
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
        // THE PLATFORM'S OWN LAYOUT, through the semantics action an
        // accessibility service uses — NOT the provider this backend
        // keeps for the draw, so the read shares no copy with the
        // lowering.
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
     * Start an input-method composition, leaving `text` MARKED —
     * uncommitted and invisible to the app. No adb command can open a
     * composing region (measured, §5), so the harness takes the
     * connection `onCreateInputConnection` hands out, WHICH ONLY EXISTS
     * WHILE A FIELD IS FOCUSED. Blocks until the composition is live.
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
    private fun kayaCanvasTarget(spec: String): KayaNode? =
        target(spec, "canvas", KayaSceneModel.canvases)

    /**
     * `expect_ink` compares WITHIN ±1 PER CHANNEL (docs/canvas-plan.md
     * §7.2): this backend reports the core's own bytes while a macOS
     * backing store carries the DISPLAY's profile and reads D2E3F7 back
     * as D2E2F7 (docs/traps.md). harness.rs and KayaSwiftUI.swift carry
     * their own copies; tools/check-verbs.py pins all three at 1.
     */
    private const val INK_TOLERANCE = 1

    /**
     * The half of a PER-MODE expectation that names [mode], out of
     * `"light FFFFFF/D2E3F7 dark 16181C/2B3B4F"` (docs/canvas-plan.md
     * §7.2): ONE SPELLING CARRYING BOTH MODES keeps a frozen expectation
     * off the host's appearance setting. Copies in harness.rs's
     * `ink_for_mode` and KayaSwiftUI.swift's `kayaInkForMode`.
     */
    private fun kayaInkForMode(want: String, mode: String): String? {
        val words = want.split(" ").filter { it.isNotEmpty() }
        var i = 0
        while (i + 1 < words.size) {
            if (words[i] == mode) return words[i + 1]
            i += 2
        }
        return null
    }

    /**
     * The reported mode's colours, every channel within [INK_TOLERANCE].
     * An answer that does not parse — every `<...>` diagnostic below —
     * never matches, so it reaches the failure text whole.
     */
    private fun kayaInkMatches(got: String, want: String): Boolean {
        fun channels(hex: String): IntArray? {
            if (hex.length != 6) return null
            val out = IntArray(3)
            for (i in out.indices) {
                out[i] = hex.substring(i * 2, i * 2 + 2).toIntOrNull(16) ?: return null
            }
            return out
        }
        val gotParts = got.split(" ", limit = 2)
        if (gotParts.size != 2) return false
        val wanted = kayaInkForMode(want, gotParts[0]) ?: return false
        val gotInk = gotParts[1].split("/")
        val wantInk = wanted.split("/")
        if (gotInk.size != wantInk.size) return false
        for (i in gotInk.indices) {
            val g = channels(gotInk[i]) ?: return false
            val w = channels(wantInk[i]) ?: return false
            for (c in g.indices) {
                if (kotlin.math.abs(g[c] - w[c]) > INK_TOLERANCE) return false
            }
        }
        return true
    }

    /**
     * THE BLIT, sampled off the WINDOW'S OWN RENDERED PIXELS at the
     * probe points (docs/canvas-plan.md §7.2) — the only canvas read
     * that fails when the buffer never reached the ImageBitmap. THE
     * APPEARANCE RIDES THE ANSWER (§6). Not on the UI thread, for
     * `kayaHighlightRead`'s reason.
     */
    private fun kayaCanvasInk(
        activity: ComponentActivity,
        spec: String,
        points: String,
    ): String {
        val mode = if (KayaSceneModel.presentationDark) "dark" else "light"
        val wanted = points.split(" ").mapNotNull { pair ->
            val xy = pair.split(",")
            val x = xy.getOrNull(0)?.trim()?.toDoubleOrNull()
            val y = xy.getOrNull(1)?.trim()?.toDoubleOrNull()
            if (xy.size == 2 && x != null && y != null) Pair(x, y) else null
        }
        if (wanted.isEmpty()) return "<no probe points in $points>"
        val gathered = onUi(activity) {
            val node = kayaCanvasTarget(spec)
            val decor = activity.window.decorView
            val loc = IntArray(2)
            decor.getLocationInWindow(loc)
            Triple(
                node?.let { kayaCanvasBoxes[it.id] },
                android.graphics.Point(loc[0], loc[1]),
                android.graphics.Point(decor.width, decor.height),
            )
        }
        val box = gathered.first
            ?: return "<no canvas $spec, or it has not been laid out>"
        if (box.width() <= 0 || box.height() <= 0) {
            return "<the canvas laid out at ${box.width()}x${box.height()}>"
        }
        val src = android.graphics.Rect(box)
        src.offset(gathered.second.x, gathered.second.y)
        if (!src.intersect(0, 0, gathered.third.x, gathered.third.y)) {
            return "<the canvas sits outside the window's own surface: $src of " +
                "${gathered.third.x}x${gathered.third.y}>"
        }
        val bitmap = android.graphics.Bitmap.createBitmap(
            src.width(), src.height(), android.graphics.Bitmap.Config.ARGB_8888)
        val latch = java.util.concurrent.CountDownLatch(1)
        var result = -1
        android.view.PixelCopy.request(
            activity.window,
            src,
            bitmap,
            { code ->
                result = code
                latch.countDown()
            },
            android.os.Handler(android.os.Looper.getMainLooper()),
        )
        latch.await(2, java.util.concurrent.TimeUnit.SECONDS)
        if (result != android.view.PixelCopy.SUCCESS) {
            bitmap.recycle()
            return "<PixelCopy answered $result for $src>"
        }
        val samples = wanted.joinToString("/") { (px, py) ->
            val x = ((bitmap.width * px / 100.0).toInt()).coerceIn(0, bitmap.width - 1)
            val y = ((bitmap.height * py / 100.0).toInt()).coerceIn(0, bitmap.height - 1)
            val pixel = bitmap.getPixel(x, y)
            String.format(
                "%02X%02X%02X",
                (pixel shr 16) and 0xFF,
                (pixel shr 8) and 0xFF,
                pixel and 0xFF,
            )
        }
        bitmap.recycle()
        return "$mode $samples"
    }

    private fun kayaTextTarget(spec: String): KayaNode? =
        if (spec.startsWith("textarea")) target(spec, "textarea", KayaSceneModel.textareas)
        else target(spec, "entry", KayaSceneModel.entryWidgets)

    /** The merged semantics node carrying this test tag — [kayaAxFind]'s
     * walk, which the accessibility verbs already use. */
    // The opt-in covers exactly the `measureAndLayoutForTest` call, and
    // is proven required: removing it fails the compile at that call,
    // one error, at compose-ui 1.7.5.
    @OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)
    private fun kayaSemanticsByTag(activity: ComponentActivity, tag: String): SemanticsNode? {
        val view = kayaComposeRoot(activity.window.decorView) ?: return null
        val root = view as RootForTest
        // THE TREE IS BROUGHT UP TO DATE FIRST: Compose publishes
        // semantics on the pass that lays out, so a read between an
        // apply and the next frame answers with the state BEFORE it —
        // fatal when the assertion was already true. Measured
        // 2026-08-06: the tree reported the old caret for ~400ms after
        // `TextFieldState` had moved.
        root.measureAndLayoutForTest()
        return kayaAxFind(root.semanticsOwner.rootSemanticsNode, tag)
    }

    /**
     * A property off this node OR the subtree under it. Whether a text
     * field's editable text, selection and layout action land on the
     * SAME semantics node as the caller's `testTag` is Compose's
     * business and has changed across versions, so this searches down
     * from the tagged node rather than depending on it.
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
     * helper APK (tools/android/cliphelper). FOREIGN ON PURPOSE: kaya
     * reading what kaya wrote parses its own malformed lowering happily
     * (docs/clipboard-plan.md §7). IT WAITS UNTIL THE CONTENT IS REALLY
     * THERE, twice, or every step after it races.
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
        // THE OFFERED TYPE ALONE IS NOT A VERIFICATION: the clip the
        // seed REPLACES may advertise the same type, so a poll on the
        // mime would be satisfied by the clip the seed was meant to
        // displace. The service stamps every installed clip, so the
        // discriminating question is a DIFFERENT clip offering what was
        // asked for.
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
     * representation; empty when it holds nothing of that kind. THE
     * HELPER READS WITHOUT TOUCHING THE GUEST'S FOCUS: it owns the
     * selected input method, and ClipboardService admits the default
     * IME's reads before it checks focus (docs/clipboard-plan.md §7).
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
        // ran must not look like one.
        if (answer == null || !answer.startsWith(HELPER_RESULT_PREFIX)) {
            return "<$HELPER_PACKAGE never answered>"
        }
        return answer.removePrefix(HELPER_RESULT_PREFIX)
    }

    /**
     * One ordered broadcast to the helper, and its answer. AN EXPLICIT
     * COMPONENT, ALWAYS: an implicit broadcast has not reached a
     * manifest receiver since API 26, and naming the class reaches a
     * helper never launched (measured). RUNS OFF THE MAIN THREAD, where
     * the result receiver is dispatched.
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
        val delimiter = spec.indexOfAny(charArrayOf('#', '@'))
        if (delimiter < 0) return null
        val kind = spec.substring(0, delimiter)
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
            "date_picker" -> KayaSceneModel.datePickers
            "time_picker" -> KayaSceneModel.timePickers
            // Every kind is addressable for accessibility — that is what
            // makes a universal prop universal — so this table is the
            // core's parse_target_kind list, not the subset of kinds some
            // verb happens to reach (tools/check-verbs.py censuses it).
            "canvas" -> KayaSceneModel.canvases
            else -> return null
        }
        return target(spec, kind, registry)
    }

    /**
     * Compose's classification, normalized into the harness's closed
     * role set; anything unnamed reports `unknown`. Sources in order:
     * `heading` off the published node info (never the config, which
     * says only what was ASKED for), `Role`, then `className`. A generic
     * view with children is a group; a generic LEAF is `unknown`.
     */
    private fun kayaAxRole(
        role: Role?,
        className: CharSequence?,
        childCount: Int,
        heading: Boolean,
        published: String? = null,
    ): String {
        if (heading) return "heading"
        // What the node PUBLISHED about itself, ahead of role and class:
        // the pickers' `datetime` has no native source at compose-ui
        // 1.7.5 (docs/datetime-plan.md P4, [KayaPickerKind]).
        if (published != null) return published
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
     * The name a service would speak: the authored description first,
     * then what the control derived from its own content — every
     * backend's precedence. The first two properties are LISTS after
     * merging, joined with a space. THE THIRD SOURCE IS THE FIELD'S OWN
     * VALUE, which on Compose is EditableText and NOT Text.
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
     * Read the MERGED semantics tree — the post-merge truth a client
     * consumes. Compose sends UNMERGED nodes plus `mergeDescendants` and
     * the SERVICE merges, so `createAccessibilityNodeInfo(id)` returns a
     * pre-merge node no client sees as such. Identity is the merged
     * `TestTag`; the node info serves [kayaAxRole]'s class name alone.
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
     * What the walk actually saw, for the miss path — every merged
     * node's id, tag, role, class name and name, so a "not found" does
     * not cost an emulator round trip to diagnose.
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
                .append(" published=").append(node.config.getOrNull(KayaPickerKind))
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
        val published = node.config.getOrNull(KayaPickerKind)
        // THE SEMANTICS-ONLY FALLBACK, computed on every read but
        // consulted only after the provider's leash expires (see the
        // expect_ax arm): the same platform-owned tree the provider
        // derives its answer FROM, one layer closer.
        val cfg = node.config
        val fallbackRole = when {
            cfg.getOrNull(SemanticsProperties.Heading) != null -> "heading"
            // AHEAD OF THE FIELD ARM, and the two routes cannot be
            // allowed to disagree — docs/traps.md, "compose-ui 1.7.5 has
            // no picker Role, and the Material date field publishes an
            // EditText".
            published != null -> published
            cfg.getOrNull(SemanticsProperties.EditableText) != null -> "field"
            else -> kayaAxRole(role, null, node.children.size, false, published)
        }
        // A TEXT NODE THAT CARRIES A CONTENT DESCRIPTION HAS NO CLASS:
        // the provider names android.widget.TextView for a plain Text and
        // nothing at all once a contentDescription rides it, so an
        // authored label read `unknown/<name>` (measured 2026-09-02).
        // The node's own Text semantics is what the class stood for.
        val className = info?.className
            ?: if (cfg.getOrNull(SemanticsProperties.Text) != null) "android.widget.TextView" else null
        return KayaAxRead(
            kayaAxRole(role, className, node.children.size, kayaAxHeading(info), published) +
                "/" + kayaAxName(node),
            infoServed = info != null,
            fallback = fallbackRole + "/" + kayaAxName(node),
        )
    }

    /**
     * One ax read, with the PROVIDER'S SILENCE carried out-of-band: the
     * semantics tree always answers where createAccessibilityNodeInfo
     * can return null past a step's whole 5s deadline under contention
     * (measured 2026-08-12; WHY is deliberately not claimed).
     * [infoServed] false measured NO classification.
     */
    private data class KayaAxRead(
        val spec: String,
        val infoServed: Boolean,
        val fallback: String,
    )


    /**
     * Whether the platform publishes this node as a HEADING. The
     * framework getter arrived in API 28 against kaya's floor of 26, and
     * below it the honest answer is false: there was no heading bit to
     * publish, and Compose stashes it in an extras bundle no service of
     * that era reads.
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
     * THE expect_menu_symbol READ (docs/styling-plan.md D6): the content
     * description on the row's MERGED node, not `KayaMenuItem.symbol`,
     * which would agree with itself. THE ROW MUST BE PRESENTED FIRST —
     * Compose composes a DropdownMenu's content only while it is open —
     * so this drives the same state the ⋮ tap does. MAIN THREAD ONLY.
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
            // description is the item's LABEL.
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
        // Everything else in the window catalog lives behind the ⋮. The
        // flag is claimed only by the call that actually OPENS it:
        // ONLY WHAT A READ OPENED MAY A READ CLOSE.
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
     * window this host can show one in: the activity's tree, then each
     * open menu popup. MERGED trees only ([kayaAxFind]'s rule) — the
     * row's description and its tag land on one node because the row
     * merges its descendants.
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
     * "not composed" has three causes it must tell apart: never
     * presented, presented but one drill deeper than this arm jumped, or
     * the lowering stopped tagging its rows. Printed only after the
     * step's whole deadline, when the frame excuse is gone.
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
     * The invariant the BARE expect_toolbar step asserts. MIRRORED FROM
     * harness.rs's `toolbar_chrome_fits` SENTENCE FOR SENTENCE — keep
     * the words identical. Null means it fits; the failure NAMES THE
     * MEASURED NUMBERS, which the byte-compared pass observation cannot.
     */
    private fun kayaToolbarChromeFits(spelling: String): String? {
        val homes = listOf("menubar", "more", "overflow", "none")
        val parts = spelling.split("/")
        val found = parts.getOrNull(0)?.toIntOrNull()
        val promoted = parts.getOrNull(1)?.toIntOrNull()
        val items = parts.getOrNull(2)?.toIntOrNull()
        if (parts.size != 4 || found == null || promoted == null || items == null ||
            !homes.contains(parts[3])
        ) {
            return "chrome reads \"$spelling\", which is not " +
                "<promoted found>/<promoted>/<items>/<remainder's home>"
        }
        if (found != promoted) {
            return "the window's chrome holds $items items, and $found of the " +
                "$promoted promoted actions are among them in catalog preorder"
        }
        if (parts[3] == "none") {
            return "the chrome holds the $found promoted actions and the remainder " +
                "of the catalog has no home in this window"
        }
        return null
    }

    /**
     * The composed `TopAppBar` — THE CHROME, and only it. MAIN THREAD
     * ONLY. Deliberately NOT [kayaMenuRowNode]'s search, which also
     * walks every open menu popup: a promoted button fallen into the
     * overflow would be "found" by the wider walk, and WHERE the button
     * is is the whole question.
     */
    private fun kayaToolbarNode(activity: ComponentActivity): SemanticsNode? {
        val view = kayaComposeRoot(activity.window.decorView) ?: return null
        return kayaAxFind((view as RootForTest).semanticsOwner.rootSemanticsNode, TOOLBAR_TAG)
    }

    /**
     * THE TITLE THE CHROME REALLY DREW, off the merged semantics node,
     * or null when this window composed no title node. MAIN THREAD ONLY.
     * THE CALLER MUST PAIR IT WITH [kayaWindowHasChrome]: null means both
     * "no bar and never should have" and "the bar is gone", and only the
     * MODEL's catalog condition tells those apart.
     */
    private fun kayaChromeTitle(activity: ComponentActivity): String? {
        val bar = kayaToolbarNode(activity) ?: return null
        val node = kayaAxFind(bar, TOOLBAR_TITLE_TAG) ?: return null
        return kayaAxName(node)
    }

    /**
     * Whether this window is SUPPOSED to be showing chrome with a title
     * in it — the condition [KayaRoot] itself branches on, read from
     * the model rather than restated here. A scene that declares no
     * command catalog gets no phantom bar, so on those scenes the task
     * label is the only surface expect_title can assert.
     */
    private fun kayaWindowHasChrome(): Boolean = KayaSceneModel.menubar.isNotEmpty()

    /**
     * What the chrome HOLDS: every node under the bar carrying
     * `SemanticsActions.OnClick`, in tree order. In a MERGED tree a node
     * that merges its descendants has no children, so a button
     * contributes exactly one entry. THE COUNT INCLUDES THE ⋮ ANCHOR, so
     * a bar that lost its promoted buttons still holds 1.
     */
    private fun kayaToolbarAffordances(node: SemanticsNode, depth: Int = 0): List<SemanticsNode> {
        if (depth > 64) return emptyList()
        val out = ArrayList<SemanticsNode>()
        for (child in node.children) {
            if (child.config.contains(SemanticsActions.OnClick)) {
                out.add(child)
            } else {
                out.addAll(kayaToolbarAffordances(child, depth + 1))
            }
        }
        return out
    }

    /**
     * EVERY SECTION SWITCHER ROW THE BAR REALLY COMPOSED, in tree order.
     * BOTH HALVES COME FROM THE RENDER — the label slot and the icon's
     * `ContentDescription`, never [KayaSection]'s own fields. The tag is
     * on EVERY row: "drew no icon" and "no row is there" are different
     * measurements.
     */
    private fun kayaSectionRows(activity: ComponentActivity): List<SemanticsNode> {
        val view = kayaComposeRoot(activity.window.decorView) ?: return emptyList()
        // THE UNMERGED TREE, and this is the one place in this file that
        // wants it — see [kayaSectionProp] for the measurement that
        // forced it. Every other read here is on the merged tree because
        // that is what a service consumes; a NavigationBarItem's icon
        // never reaches that tree at all, so a merged read of a section
        // row could only ever answer "no icon".
        val root = (view as RootForTest).semanticsOwner.unmergedRootSemanticsNode
        val out = ArrayList<SemanticsNode>()
        fun walk(node: SemanticsNode, depth: Int) {
            if (depth > 64) return
            val tag = node.config.getOrNull(SemanticsProperties.TestTag)
            if (tag != null && tag.startsWith(SECTION_TAG_PREFIX)) {
                out.add(node)
                return
            }
            node.children.forEach { walk(it, depth + 1) }
        }
        walk(root, 0)
        return out
    }

    /**
     * One property off a section row's SUBTREE, a MEASURED shape:
     * NavigationBarItem does not carry its icon slot's description into
     * the merged node, so a bar drawing icons has NO ContentDescription
     * where a TalkBack user focuses (2026-08-17). The answer is the
     * first the UNMERGED subtree publishes — the render, not the model.
     */
    private fun kayaSectionProp(
        node: SemanticsNode,
        read: (SemanticsNode) -> String?,
        depth: Int = 0,
    ): String {
        if (depth > 16) return ""
        val here = read(node)
        if (!here.isNullOrEmpty()) return here
        for (child in node.children) {
            val found = kayaSectionProp(child, read, depth + 1)
            if (found.isNotEmpty()) return found
        }
        return ""
    }

    private fun kayaSectionTitleOf(node: SemanticsNode): String =
        kayaSectionProp(node, { it.config.getOrNull(SemanticsProperties.Text)
            ?.joinToString(" ") { t -> t.text } })

    private fun kayaSectionSymbolOf(node: SemanticsNode): String =
        kayaSectionProp(node, { it.config.getOrNull(SemanticsProperties.ContentDescription)
            ?.joinToString(" ") })

    /**
     * THE expect_section_symbol READ: the semantic name the REAL
     * switcher row titled [title] draws. MAIN THREAD ONLY, and TOTAL
     * like [kayaToolbarItemRead] — every failure is a short measured
     * sentence and a retryable non-match. No presentation step: a bottom
     * bar is composed as long as the sections are.
     */
    private fun kayaSectionSymbolRead(activity: ComponentActivity, title: String): String {
        val rows = kayaSectionRows(activity)
        val hit = rows.firstOrNull { kayaSectionTitleOf(it) == title }
        if (hit == null) {
            if (rows.isEmpty()) return "the window has no section switcher"
            // MEASURED, not guessed: the bar is composed and carries no
            // row with this title. What it DOES carry rides the
            // sentence, because "the title never landed" and "the row is
            // under another name" are different bugs.
            val shown = rows.joinToString(", ") { kayaSectionTitleOf(it) }
            return "no section row titled $title (the switchers carry: $shown)"
        }
        val described = kayaSectionSymbolOf(hit)
        if (described.isEmpty()) {
            // The row composed and nothing in its subtree publishes a
            // content description. It deliberately does NOT say whether
            // the app asked for a symbol: this reader cannot tell "none
            // declared" from "declared and never lowered" (invariant 3).
            // The subtree's size rides the sentence, because a row that
            // composed EMPTY is a different bug.
            return "no icon on the section row (it has ${hit.children.size} child nodes)"
        }
        if (!isSymbolName(described)) {
            // A description outside the twenty came from something other
            // than the symbol lowering.
            return "the section row describes itself \"$described\", which is not a symbol name"
        }
        return described
    }

    /** The first catalog item with this label, in CATALOG PREORDER —
     * the same walk [kayaPromotedActions] takes. THE WHOLE CATALOG and
     * not the promoted list: an item that fell out of the chrome must
     * still RESOLVE, or the read cannot tell "this lowering stopped
     * promoting" from "no such item". */
    private fun kayaCatalogItemLabelled(label: String): KayaMenuItem? {
        val flat = ArrayList<KayaMenuItem>()
        fun walk(item: KayaMenuItem) {
            flat.add(item)
            item.children.forEach { walk(it) }
        }
        KayaSceneModel.menubar.forEach { walk(it) }
        return flat.firstOrNull { it.label == label }
    }

    /**
     * THE expect_toolbar READ: `<promoted in the chrome>/<promoted in
     * the catalog>/<items held>/<remainder's home>`, MAIN THREAD ONLY.
     * The first number walks the COMPOSED bar in tree order, so a right
     * set in the WRONG SEQUENCE does not count. TWO DIFFERENT SIDES on
     * purpose — one answer reported twice agrees with itself.
     */
    private fun kayaToolbarChromeRead(activity: ComponentActivity): String {
        val promoted = kayaPromotedActions()
        val bar = kayaToolbarNode(activity)
        val held = if (bar == null) emptyList() else kayaToolbarAffordances(bar)
        var matched = 0
        for (node in held) {
            if (matched < promoted.size &&
                node.config.getOrNull(SemanticsProperties.TestTag) ==
                kayaMenuTag(promoted[matched].id)
            ) {
                matched += 1
            }
        }
        val home =
            if (held.any {
                    it.config.getOrNull(SemanticsProperties.TestTag) == TOOLBAR_MORE_TAG
                }
            ) {
                "overflow"
            } else {
                "none"
            }
        return "$matched/${promoted.size}/${held.size}/$home"
    }

    /**
     * THE expect_toolbar_item READ, off the MERGED tree: PRESENCE from
     * the node tagged `kaya:menu#<id>` in the bar's subtree (never the
     * promotion list, which is what is checked), the SYMBOL from its
     * content description, ENABLEMENT from `Disabled`. The ADDRESS comes
     * through the catalog (docs/chrome/toolbar-android.md §6).
     */
    private fun kayaToolbarItemRead(
        activity: ComponentActivity,
        label: String,
        aspect: String,
    ): String {
        val bar = kayaToolbarNode(activity) ?: return "the window has no toolbar"
        val item = kayaCatalogItemLabelled(label)
            ?: return "no catalog item is labelled $label"
        val node = kayaAxFind(bar, kayaMenuTag(item.id))
        if (node == null) {
            // MEASURED, not guessed: the bar is composed and this item's
            // affordance is not in it. What the bar DOES carry is
            // printed, because "the promotion never happened" and "the
            // button is there under another name" are different bugs.
            val shown = kayaToolbarAffordances(bar).joinToString(", ") { kayaAxName(it) }
            return "no toolbar item labelled $label (the toolbar carries: $shown)"
        }
        if (aspect == "enabled" || aspect == "disabled") {
            return if (node.config.contains(SemanticsProperties.Disabled)) {
                "disabled"
            } else {
                "enabled"
            }
        }
        val described = node.config.getOrNull(SemanticsProperties.ContentDescription)
        if (described.isNullOrEmpty()) {
            // The button composed and carries no content description.
            // Its accessible name rides the sentence: that is what tells
            // "the symbol arm did not draw" (a text button, named by its
            // label) from "nothing drew at all".
            return "the toolbar button $label carries no content description " +
                "(it names itself \"${kayaAxName(node)}\")"
        }
        val name = described.joinToString(" ")
        if (!isSymbolName(name)) {
            // A description that is not one of the twenty came from
            // something other than the symbol lowering — an icon blob's
            // description is the item's LABEL.
            return "the toolbar button $label describes itself \"$name\", " +
                "which is not a symbol name"
        }
        return name
    }

    /**
     * The inputs [kayaAxRole] weighs, for a MISMATCH. EVERY input is
     * printed, heading included: a sentence that omits one cannot tell
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

    /**
     * Cut one script LINE into statements at `;`, the newline stand-in
     * for the intent extra every leg arrives in. QUOTE-AWARE, because
     * kaya's asset miss sentence carries a semicolon; harness.rs's
     * `split_statements` and KayaSwiftUI's `kayaSplitStatements` are the
     * other two. BALANCED QUOTES required (tools/check-steps.py).
     */
    private fun kayaSplitStatements(line: String): List<String> {
        val out = ArrayList<String>()
        val current = StringBuilder()
        var quoted = false
        for (c in line) {
            when {
                c == '"' -> { quoted = !quoted; current.append(c) }
                c == ';' && !quoted -> { out.add(current.toString()); current.setLength(0) }
                else -> current.append(c)
            }
        }
        out.add(current.toString())
        return out
    }

    /// How long the bounded-retry wrapper below waits between looks.
    /// Named because an arm has to know it: one that pays for an
    /// expensive diagnosis only on the final look needs the period to
    /// tell which look that is.
    private const val RETRY_PERIOD_MS = 20L

    /**
     * The `drag` verb's two numbers (docs/dnd-plan.md D10, docs/traps.md:
     * `input draganddrop` holds the long press itself). The INJECTION is
     * how long the pointer takes from source to destination once the
     * press has been held; the ACK is how long the verb waits for the
     * platform's ACTION_DRAG_ENDED, which covers the runner's own poll
     * period and adb on top of the gesture.
     */
    private const val DRAG_INJECT_MS = 1500
    private const val DRAG_ACK_MS = 20_000L

    /** The request sequence, so the runner never runs one line twice. */
    private var kayaDragRequests = 0
    private const val RETRY_PERIOD_NS = RETRY_PERIOD_MS * 1_000_000

    /**
     * A DIALOG THAT IS NOT UP YET IS WAITING ON AN APP LAUNCH, not a
     * frame: the FIRST dialog a scene opens pays DocumentsUI's COLD
     * start (measured 2026-08-30, docs/traps.md — a11y-readable at
     * 6983ms against a 5s budget, warm panels after it at 160ms and
     * 74ms). Spent only while a dialog arm is missing its dialog.
     */
    private const val DIALOG_LAUNCH_BUDGET_NS = 20_000_000_000L

    /**
     * THE CEILING ON ONE STEP, HOP INCLUDED — one number in all three
     * harnesses (tools/check-harness-ceiling.py). The retry deadline
     * above is read only AFTER a step returns and every step blocks in
     * `onUi`, so a saturated UI thread prints no verdict at all
     * (measured 2026-08-24, docs/measurements/choke-*-2026-08-24.txt).
     */
    private const val STEP_CEILING_MS = 60_000L

    /**
     * Once a verdict is published the process leaves within this
     * whether or not the UI thread ever runs the halt below
     * (harness.rs's EXIT_GRACE).
     */
    private const val EXIT_GRACE_MS = 3_000L

    private fun stepCeilingMs(): Long =
        System.getenv("KAYA_STEP_CEILING_MS")?.toLongOrNull()?.takeIf { it > 0 } ?: STEP_CEILING_MS

    /**
     * ANDROID'S ONE EXTRA HARNESS KNOB: `KAYA_RECREATE_AFTER=<n>` drives
     * a REAL Activity recreation after the n-th statement. Not a
     * `.steps` verb — recreation exists on no other platform
     * (docs/deferred.md's mount entry). The statement is LOGGED WITH ITS
     * TEXT, which run-emulator.py greps for.
     */
    private fun recreateAfter(): Int =
        System.getenv("KAYA_RECREATE_AFTER")?.toIntOrNull()?.takeIf { it > 0 } ?: 0

    /** How long the harness waits for the re-created Activity to mount. */
    private const val REMOUNT_CEILING_MS = 20_000L

    /**
     * Drive the platform's own relaunch (`wm_on_destroy` + `wm_on_create`
     * in ONE process) and wait for the new Activity to mount and draw.
     * Returns null on success, or the sentence to fail the leg with.
     */
    private fun kayaRecreate(after: Int, line: String): String? {
        val old = mountedActivity ?: return "recreate: no activity is mounted"
        Log.i("kaya", "KAYA_REMOUNT: recreating after step $after ($line)")
        old.runOnUiThread { old.recreate() }
        val deadline = System.nanoTime() + REMOUNT_CEILING_MS * 1_000_000
        while (System.nanoTime() < deadline) {
            val now = mountedActivity
            // IDENTITY, never null-ness: the destroy and the create are
            // two events and the gap between them is not the answer.
            if (now != null && now !== old) {
                // The first draw of the new surface, so the step after
                // this one reads a laid-out tree rather than racing it.
                val drawn = System.nanoTime() + REMOUNT_CEILING_MS * 1_000_000
                while (System.nanoTime() < drawn) {
                    if (onUi(now) { kayaComposeRoot(now.window.decorView) != null }) {
                        val twins = kayaSecondMountThreads()
                        if (twins != null) return twins
                        if (appearanceOverride != null && appearanceAppliedTo !== now) {
                            return "recreate: KAYA_APPEARANCE=$appearanceOverride but the " +
                                "override's window background was never applied to the " +
                                "re-created window — it is per-window, and this one " +
                                "carries the manifest theme's"
                        }
                        Log.i("kaya", "KAYA_REMOUNT: re-attached")
                        return null
                    }
                    Thread.sleep(RETRY_PERIOD_MS)
                }
                return "recreate: the re-created activity mounted but never drew " +
                    "within ${REMOUNT_CEILING_MS / 1000}s"
            }
            Thread.sleep(RETRY_PERIOD_MS)
        }
        return "recreate: no new activity mounted within ${REMOUNT_CEILING_MS / 1000}s " +
            "(the process still holds ${if (mountedActivity === old) "the old one" else "none"})"
    }

    /**
     * THE SECOND-MOUNT WITNESS, counting THREADS: a re-attach that
     * started a second pump or runner is invisible to every assertion a
     * scene can make, since two runners publish the same green verdict
     * (measured 2026-08-27). BOUNDED-SETTLE — a thread on its way out is
     * not the defect; a twin still there at the end is.
     */
    private fun kayaSecondMountThreads(): String? {
        val singletons = listOf("kaya-compose-pump", "kaya-selftest", "kaya-app")
        val deadline = System.nanoTime() + REMOUNT_SETTLE_MS * 1_000_000
        while (true) {
            val names = Thread.getAllStackTraces().keys.filter { it.isAlive }.map { it.name }
            // EVERY offender, not the last one found: a re-attach that
            // doubled two things would otherwise send the next reader
            // after one of them.
            val twins = singletons
                .map { it to names.count { name -> name == it } }
                .filter { it.second > 1 }
            if (twins.isEmpty()) return null
            if (System.nanoTime() >= deadline) {
                val said = twins.joinToString(", ") { "${it.second} named ${it.first}" }
                return "recreate: ${REMOUNT_SETTLE_MS}ms after the re-attach this process " +
                    "still has $said — the second mount started one of each, and no scene " +
                    "can see it"
            }
            Thread.sleep(RETRY_PERIOD_MS)
        }
    }

    /** How long a re-attach's leftover threads have to finish leaving. */
    private const val REMOUNT_SETTLE_MS = 2_000L

    /**
     * The sentence a wedged step ends its run with — harness.rs's
     * `wedge_verdict` and KayaSwiftUI.swift's `kayaWedgeVerdict` are the
     * same text. It prints only what it measured and says out loud what
     * it cannot tell apart. Steps that already failed are not repeated:
     * each was printed the moment it became final.
     */
    private fun wedgeVerdict(step: String, waitedMs: Long): String =
        "KAYA_SELFTEST: FAILED (no verdict — the harness entered step $step " +
            String.format(java.util.Locale.ROOT, "%.1f", waitedMs / 1000.0) +
            "s ago and has not come back from it. A step blocks in its hop to the " +
            "platform's UI thread, so nothing answered from there; a wedged UI thread " +
            "and a merely slow one look the same from here and this does not claim to " +
            "tell them apart. Ended by the harness step ceiling, which is the cover a " +
            "step's own retry deadline cannot give: that one is read only after a step " +
            "returns.)"

    /**
     * The thread that makes those two ceilings real. NOT the harness
     * thread: the failure class IS the harness thread stuck in a call
     * that never returns. `halt`, never `exit` — shutdown hooks run on a
     * pool this process can no longer schedule, and the Activity's
     * teardown wants the UI thread that is not answering.
     */
    private class StepWatchdog(private val ceilingMs: Long) {
        private val lock = Object()
        private var step: String? = null
        private var leaving: Int? = null
        private var since = System.nanoTime()

        fun start() {
            thread(name = "kaya-step-ceiling", isDaemon = true) {
                while (true) {
                    Thread.sleep(RETRY_PERIOD_MS)
                    val step: String?
                    val leaving: Int?
                    val waitedMs: Long
                    synchronized(lock) {
                        step = this.step
                        leaving = this.leaving
                        waitedMs = (System.nanoTime() - since) / 1_000_000
                    }
                    if (leaving != null && waitedMs >= EXIT_GRACE_MS) {
                        // NOT a second verdict: the leg's own is already
                        // out, and replacing it would lose the answer
                        // the run reached.
                        Log.e(
                            "kaya",
                            "KAYA_HARNESS: the verdict is published and the platform's exit " +
                                "path has not run ${EXIT_GRACE_MS / 1000}s later — leaving " +
                                "under the verdict's own code (the harness exit grace)",
                        )
                        Runtime.getRuntime().halt(leaving)
                    }
                    if (step != null && waitedMs >= ceilingMs) {
                        // THE WEDGE IS WHAT THE TRACE IS FOR (crates/kaya/src/
                        // vtrace.rs); the failed-verdict path dumps its own.
                        KayaVTrace.dump("the step ceiling fired: no verdict")
                        Log.e("kaya", wedgeVerdict(step, waitedMs))
                        Runtime.getRuntime().halt(1)
                    }
                }
            }
        }

        fun enter(step: String) = synchronized(lock) {
            this.step = step
            leaving = null
            since = System.nanoTime()
        }

        fun published(code: Int) = synchronized(lock) {
            step = null
            leaving = code
            since = System.nanoTime()
        }
    }

    private fun runScript(script: String) {
        // Watched, before any step (crates/kaya/src/fault.rs; the fault
        // census holds all three runners to this call).
        KayaPresent.faultWatch()
        val observed = ArrayList<String>()
        val failures = ArrayList<String>()
        // THE CEILING THAT COVERS THE HOP: armed at every step below and
        // again over the exit, so this run cannot end in silence.
        val watchdog = StepWatchdog(stepCeilingMs())
        watchdog.start()
        val start = System.nanoTime()
        Log.i("kaya", "KAYA_HARNESS: epoch ${System.currentTimeMillis()}")
        // The verb trace counts from the same zero (crates/kaya/src/vtrace.rs).
        KayaVTrace.begin(start) { mountedActivity?.filesDir }
        // Whether the run already carried the core's fault into
        // `failures`, so the sweep after the loop cannot report the same
        // one twice.
        var reportedFault = false
        // The android-only recreation phase (see `recreateAfter`).
        val remountAfter = recreateAfter()
        var statements = 0
        // Labelled for the one thing that ends a script early: the core
        // latching a fault (KayaPresent.fault).
        scriptLines@ for (rawLine in script.split('\n')) {
            val trimmedLine = rawLine.trim()
            if (trimmedLine.isEmpty() || trimmedLine.startsWith("#")) continue
            for (raw in kayaSplitStatements(trimmedLine)) {
                val line = raw.trim()
                if (line.isEmpty() || line.startsWith("#")) continue
                val parts = line.split(' ').filter { it.isNotEmpty() }
                val offset = (System.nanoTime() - start) / 1_000_000
                Log.i("kaya", "KAYA_HARNESS: +${offset}ms $line")
                watchdog.enter(line)
                KayaVTrace.step(statements, line)
                // The observation contract (harness.rs is the norm):
                // every expect is a BOUNDED RETRY — each verb case
                // appends exactly one failure on a miss, the wrapper
                // retracts it and re-runs until it passes or the
                // deadline lands the last text. Actions never re-run;
                // the FIRST expect doubles as the scene-ready wait.
                val stepStart = System.nanoTime()
                var stepDeadline = stepStart + 5_000_000_000L
                var retryStep = true
                var attempt = 0
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
                        kayaLastClick = Triple(parts[1], answered, System.nanoTime())
                        val ok = onUi(activity) {
                            // A click on a TEXT KIND focuses it — what a
                            // native tap does, and the only way a scene
                            // can focus a STAMPED copy. ROUTED THROUGH
                            // focusedId, like COMMAND_FOCUS: the model
                            // drives the FocusRequester here, and a
                            // direct requestFocus would fight it.
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
                        else {
                            kayaAwaitAnswer(answered)
                            // THE WATCH'S INSTRUMENT (docs/deferred.md, the
                            // android portfolio title entry): a click the
                            // app never answered is said here, at the
                            // click, rather than deduced three steps later
                            // from a title that did not move.
                            if (kayaBatches == answered) {
                                Log.i(
                                    "kaya",
                                    "KAYA_DIAG click ${parts[1]} was emitted and no batch " +
                                        "answered it within the wait; entries=" +
                                        "${onUi(activity) { KayaSceneModel.navEntries.size }}"
                                )
                            }
                        }
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
                        // THROUGH THE COMMIT PATH a user's gesture takes
                        // (docs/slider-plan.md S8), as one finished
                        // gesture: the step's snap, the range's clamp,
                        // the live emit and the committed one all run.
                        val ok = onUi(activity) {
                            target(parts[1], "slider", KayaSceneModel.sliders)?.also { node ->
                                kayaSliderCommitted(node, parts[2].toDouble(), final = true)
                            } != null
                        }
                        if (!ok) failures.add("no such target ${parts[1]}")
                    }
                    "set_date", "set_time" -> {
                        // THROUGH THE COMMIT PATH a user's confirm takes
                        // (docs/datetime-plan.md D8): the clamp and the
                        // minute snap run, the node the field draws from
                        // moves, and the occurrence fires — the toggle
                        // arm's shape, one kind over.
                        val isTime = parts[0] == "set_time"
                        val spelled = parts[2]
                        val packed =
                            if (isTime) kayaParseTime(spelled) else kayaParseDate(spelled)
                        if (packed == null) {
                            failures.add(
                                "${parts[0]} wants " +
                                    (if (isTime) "HH:MM" else "YYYY-MM-DD") +
                                    ", got $spelled"
                            )
                        } else {
                            val ok = onUi(activity) {
                                val node =
                                    if (isTime) {
                                        target(parts[1], "time_picker",
                                               KayaSceneModel.timePickers)
                                    } else {
                                        target(parts[1], "date_picker",
                                               KayaSceneModel.datePickers)
                                    }
                                node?.also { kayaPickerCommitted(it, isTime, packed) } != null
                            }
                            if (!ok) failures.add("no such target ${parts[1]}")
                        }
                    }
                    "expect_slider" -> {
                        // The slider's value in the one fixed spelling
                        // (docs/slider-plan.md S8): the state the composable
                        // draws from IS the control's value here.
                        val want = quoted(parts.drop(2))
                        val got = onUi(activity) {
                            target(parts[1], "slider", KayaSceneModel.sliders)?.let {
                                kayaSpelledSlider(it.value)
                            }
                        }
                        when {
                            got == null -> failures.add("no such target ${parts[1]}")
                            got == want -> observed.add(got)
                            else -> failures.add("${parts[1]} holds \"$got\", wanted \"$want\"")
                        }
                    }
                    "expect_picker" -> {
                        // THE CONTROL'S value, in fixed digits — the one
                        // observation for the silent cases
                        // (docs/datetime-plan.md D8), read off the stamp
                        // the picker body wrote and never off the model.
                        val want = quoted(parts.drop(2))
                        val isTime = parts[1].startsWith("time_picker")
                        val node = onUi(activity) {
                            if (isTime) {
                                target(parts[1], "time_picker", KayaSceneModel.timePickers)
                            } else {
                                target(parts[1], "date_picker", KayaSceneModel.datePickers)
                            }
                        }
                        val got = node?.pickerPresented
                        when {
                            node == null -> failures.add("no such target ${parts[1]}")
                            got.isNullOrEmpty() -> failures.add(
                                "${parts[1]} has drawn no picker field yet, so nothing " +
                                    "has a value to read"
                            )
                            got == want -> observed.add(got)
                            else -> failures.add(
                                "${parts[1]} holds \"$got\", wanted \"$want\""
                            )
                        }
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
                        // stamp the render body wrote — NEVER derived
                        // from the declared prop (the expect_split
                        // rule). window#N addresses an aux window.
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
                    "expect_section_symbol" -> {
                        // THE SEMANTIC ICON on the REAL switcher row.
                        // ITS OWN ARM rather than a second label on
                        // "expect_section": check-verbs reads each
                        // `"expect_*" ->` head, so a verb sharing
                        // another's head is one the sweep never sees.
                        val head = quotedHead(line.substring(parts[0].length))
                        val want = head?.let { quotedHead(it.second) }
                        if (head == null || want == null || want.second.isNotEmpty()) {
                            failures.add(
                                "expect_section_symbol wants a quoted section title and a " +
                                    "quoted symbol name: $line")
                        } else {
                            val got = onUi(activity) {
                                kayaSectionSymbolRead(activity, head.first)
                            }
                            if (got == want.first) {
                                observed.add("section \"${head.first}\" symbol \"${want.first}\"")
                            } else {
                                // The measured answer rides the failure:
                                // it tells a wrong glyph from a row that
                                // drew none from a switcher not built.
                                failures.add(
                                    "section \"${head.first}\" symbol \"$got\", " +
                                        "wanted \"${want.first}\"")
                            }
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
                        // Mirrors the item's own onClick: write the state
                        // the control reads, emit with the identity tag.
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
                    // A8). A stand-in would LIE: writing the text
                    // CLEARS the native history the scene came to
                    // observe, and the leg would pass anyway.
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
                                // programmatic write, so it carries D7
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
                        // The target kind picks the observation —
                        // harness.rs's routing. THE TEXT KINDS READ THE
                        // WIDGET, not the model mirror: `TextFieldState`
                        // IS what the field renders from, and a model
                        // read could not see a native undo that moved
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
                            // Kind picks the registry: A ROW TARGET MUST
                            // NEVER READ A COLUMN.
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
                    "expect_columns" -> {
                        // The header bar as the TABLE PATH presented it
                        // — the render's own record, never the model
                        // echo; headers render at every width
                        // (docs/tables-plan.md).
                        val want = quoted(parts.drop(2))
                        val got = onUi(activity) {
                            target(parts[1], "column", KayaSceneModel.columns)
                                ?.tablePresented
                        }
                        when {
                            got == null -> failures.add("no such target ${parts[1]}")
                            got == want -> observed.add(got)
                            else ->
                                failures.add(
                                    "${parts[1]} presents \"$got\", wanted \"$want\""
                                )
                        }
                    }
                    "expect_rows" -> {
                        // Per-row cell label texts, rows |-joined in the
                        // tree's child order, cells ,-joined — the
                        // two-level expect_order, for the celled shape
                        // whose moves creation-order registries cannot
                        // see.
                        val want = quoted(parts.drop(2))
                        val got = onUi(activity) {
                            target(parts[1], "column", KayaSceneModel.columns)
                                ?.children
                                ?.joinToString("|") { row ->
                                    row.children
                                        .filter { it.kind == KIND_LABEL }
                                        .joinToString(",") { it.text }
                                }
                        }
                        when {
                            got == null -> failures.add("no such target ${parts[1]}")
                            got == want -> observed.add(got)
                            else ->
                                failures.add(
                                    "${parts[1]} rows \"$got\", wanted \"$want\""
                                )
                        }
                    }
                    "expect_column_edges" -> {
                        // The uniform GEOMETRY claim, both halves: the
                        // cells' leading edges form exactly N clusters
                        // within two units, AND the table spans its
                        // assigned track — the regression a
                        // content-hugging layout slips past every
                        // model-side observable.
                        val want = parts.getOrNull(2)?.toIntOrNull() ?: -1
                        val truthTable = kayaTableHorizontalSelftest()
                        data class EdgeRead(
                            val clusters: List<Float>,
                            val aligned: Boolean,
                            val ordered: Boolean,
                            val found: Int,
                            val expected: Int,
                            val left: Float,
                            val right: Float,
                            val viewportLeft: Float,
                            val viewportRight: Float,
                            val track: Float,
                            val drawn: Float,
                            val content: Float,
                            val reach: Float,
                            val at: Float,
                            val stale: Boolean,
                        )
                        val read = onUi(activity) {
                            target(parts[1], "column", KayaSceneModel.columns)?.let { node ->
                                val generation = "${node.tableGeometryGeneration}:"
                                val keys = buildList {
                                    node.tableColumns.indices.forEach { add("${generation}h/$it") }
                                    node.children.forEach { row ->
                                        node.tableColumns.indices.forEach {
                                            add("$generation${row.id}/$it")
                                        }
                                    }
                                }
                                val starts = keys.mapNotNull { node.cellEdgeX[it] }
                                val rights = keys.mapNotNull { node.cellEdgeRightX[it] }
                                val byColumn = node.tableColumns.indices.map { column ->
                                    buildList {
                                        node.cellEdgeX["${generation}h/$column"]?.let { add(it) }
                                        node.children.forEach { row ->
                                            node.cellEdgeX["$generation${row.id}/$column"]?.let { add(it) }
                                        }
                                    }
                                }
                                val reps = byColumn.mapNotNull { it.minOrNull() }
                                EdgeRead(
                                    reps,
                                    byColumn.all { xs ->
                                        xs.size == node.children.size + 1 &&
                                            (xs.maxOrNull()!! - xs.minOrNull()!!) <= 2f
                                    },
                                    reps.zipWithNext().all { (left, right) -> right - left > 2f },
                                    minOf(starts.size, rights.size),
                                    keys.size,
                                    starts.minOrNull() ?: -1f,
                                    rights.maxOrNull() ?: -1f,
                                    node.tableViewportLeftX,
                                    node.tableViewportRightX,
                                    node.tableTrackW,
                                    node.tableDrawnW,
                                    node.tableContentW,
                                    // The granted scroll and the offset
                                    // it stands at, in the dp the widths
                                    // beside them are in.
                                    node.tableReachX / node.tableDensity,
                                    node.tableScrollX / node.tableDensity,
                                    node.tableGeometryAt != node.tableGeometryGeneration,
                                )
                            }
                        }
                        when {
                            truthTable != null -> failures.add(truthTable)
                            read == null ->
                                failures.add("no such target ${parts[1]}")
                            read.found != read.expected || read.expected == 0 ->
                                failures.add(
                                    "${parts[1]} has ${read.found} of ${read.expected} live cell bounds"
                                )
                            read.clusters.size != want || !read.aligned || !read.ordered ->
                                failures.add(
                                    "${parts[1]} cell edges cluster at " +
                                        read.clusters.map { it.toInt() } +
                                        ", wanted ${parts.getOrNull(2)} columns"
                                )
                            // ONE CAUSE PER SENTENCE (kayaTableHorizontalComplaint's
                            // rule): geometry measured under an earlier header
                            // generation is a republish that never happened, and
                            // reads differently from never having any.
                            read.stale ->
                                failures.add(
                                    "${parts[1]} geometry was measured before the current header"
                                )
                            // TWO MEASUREMENTS, TWO SENTENCES, EACH NAMING ITS
                            // OWN NUMBERS: the measure block writes the track
                            // trio and the position reader writes the viewport,
                            // so one sentence for both sent a reader after the
                            // wrong half (invariant 3).
                            read.track <= 0f || read.drawn <= 0f || read.content <= 0f ->
                                failures.add(
                                    "${parts[1]} has no live table track " +
                                        "(track ${read.track.toInt()}dp, drawn " +
                                        "${read.drawn.toInt()}dp, content " +
                                        "${read.content.toInt()}dp)"
                                )
                            read.viewportRight <= read.viewportLeft ->
                                failures.add(
                                    "${parts[1]} has no live table viewport " +
                                        "(${read.viewportLeft.toInt()}dp to " +
                                        "${read.viewportRight.toInt()}dp)"
                                )
                            else -> {
                                // The ink in the CONTENT's own space:
                                // the live offset is added back, so a
                                // table read after a scroll is measured
                                // where its columns were laid out rather
                                // than convicted of the displacement the
                                // reader asked for. At rest the offset
                                // is 0.
                                val complaint = kayaTableHorizontalComplaint(
                                    read.drawn,
                                    read.content,
                                    read.track,
                                    read.viewportRight - read.viewportLeft,
                                    read.left - read.viewportLeft + read.at,
                                    read.right - read.viewportLeft + read.at,
                                    read.reach,
                                )
                                if (complaint == null) {
                                    observed.add("${parts[1]} column edges $want")
                                } else {
                                    failures.add("${parts[1]} $complaint")
                                }
                            }
                        }
                    }
                    "header_click" -> {
                        // The user's route: what the header tap's own
                        // handler does — the sort tag verbatim plus the
                        // column index, and NO model change: the
                        // indicator moves when the guest re-declares.
                        val index = parts.getOrNull(2)?.toIntOrNull() ?: -1
                        val off = onUi(activity) {
                            val node = target(parts[1], "column", KayaSceneModel.columns)
                            when {
                                node == null -> "no such target ${parts[1]}"
                                node.tableColumns.isEmpty() ->
                                    "${parts[1]} declares no columns"
                                index !in node.tableColumns.indices ->
                                    "column ${parts.getOrNull(2)} of ${node.tableColumns.size}"
                                else -> {
                                    KayaPresent.emitSortRequested(node.sortTag, index)
                                    null
                                }
                            }
                        }
                        if (off != null) failures.add("header_click: $off")
                    }
                    "expect_window" -> {
                        // THE FIRST VISIBLE ROW AND THE DECLARED TOTAL
                        // (docs/virtualization-plan.md §5). The WINDOWED
                        // tier is the declared table, asked for the row
                        // a reader can see off the edges it laid out. An
                        // unwindowed For realizes the whole collection
                        // and its first row is visible at rest, which is
                        // what "0 n" says — true, not a stub.
                        val want = parts.drop(2).joinToString(" ")
                        val got = onUi(activity) {
                            target(parts[1], "column", KayaSceneModel.columns)?.let { node ->
                                val window = kayaTableWindows[node.id]
                                if (window != null) {
                                    val seen = window.firstVisible(node.children.size)
                                    "${seen.first} ${seen.second}"
                                } else {
                                    "0 ${node.children.size}"
                                }
                            }
                        }
                        if (got != null && got == want) {
                            observed.add("${parts[1]} window $want")
                        } else if (got != null) {
                            failures.add("${parts[1]} windows \"$got\", wanted \"$want\"")
                        } else {
                            failures.add("no such target ${parts[1]}")
                        }
                    }
                    "drag" -> {
                        // drag <source> to <destination> [before|onto].
                        // THE HARNESS RUNS INSIDE THE APP AND CANNOT
                        // INJECT A SYSTEM DRAG, so the verb is a RUNNER
                        // CHANNEL (docs/dnd-plan.md D10): it prints the
                        // two screen-pixel centres and the runner's own
                        // per-leg logcat poll executes
                        // `input draganddrop` on the leg's device. A
                        // refused drop is not this verb's failure — the
                        // source reads `none`.
                        var words = parts.drop(1)
                        var reorder: Boolean? = null
                        if (words.lastOrNull() == "before") {
                            reorder = true
                            words = words.dropLast(1)
                        } else if (words.lastOrNull() == "onto") {
                            reorder = false
                            words = words.dropLast(1)
                        }
                        if (words.size != 3 || words[1] != "to") {
                            failures.add(
                                "drag wants `<source> to <destination> [before|onto]`")
                        } else {
                            kayaAwaitFrames(activity, 2)
                            // THE BOX MUST HAVE SETTLED (docs/deferred.md's
                            // android drag WATCH, sightings four and five):
                            // two frames passed and the verb still aimed at
                            // the previous arrangement under load, so the
                            // wait is for the destination's own box to hold
                            // still across frames, not for frames.
                            val destinationId = onUi(activity) { kayaWidgetTarget(words[2])?.id }
                            if (destinationId != null) kayaAwaitSettledBox(activity, destinationId)
                            val plan = onUi(activity) {
                                kayaDragPlan(activity, words[0], words[2], reorder)
                            }
                            if (plan.error != null) {
                                failures.add("drag: ${plan.error}")
                            } else {
                                val endings = kayaDragEndings
                                Log.i("kaya", plan.line)
                                val off = kayaAwaitDragEnd(plan.sourceId, endings)
                                if (off != null) {
                                    failures.add("drag: $off")
                                } else {
                                    // THE ACK the runner stops re-injecting on.
                                    Log.i("kaya", "KAYA_ACK: draganddrop ${plan.seq}")
                                }
                            }
                        }
                    }
                    "drag_file" -> {
                        // A foreign file drop (docs/dnd-plan.md D6) — no
                        // foreign source reaches a phone's app (D9), so
                        // the lane cuts the step rather than fake one.
                        failures.add("drag_file is a depth slice on android (docs/dnd-plan.md §5)")
                    }
                    "scroll_to_row" -> {
                        // The core maps the KEY to an index in the
                        // current order and the tier scrolls that row to
                        // the viewport's TOP. An action, silent like
                        // click. Addresses the ROW, so an unrealized row
                        // scrolls exactly like a realized one — the band
                        // moves first, the park follows the correction.
                        val rawKey = parts.drop(2).joinToString(" ")
                        val key = if (rawKey.startsWith("\"")) quoted(parts.drop(2)) else rawKey
                        val off = onUi(activity) {
                            val node = target(parts[1], "column", KayaSceneModel.columns)
                            val window = node?.let { kayaTableWindows[it.id] }
                            when {
                                node == null -> "no such target ${parts[1]}"
                                window == null ->
                                    "${parts[1]} is not a windowed tier on this backend"
                                else -> {
                                    val index = KayaPresent.scrollToRow(node.id, key)
                                    if (index == KayaPresent.ROW_NOT_FOUND) {
                                        "no row of ${parts[1]} carries the key \"$key\""
                                    } else {
                                        window.park(index.toInt())
                                        null
                                    }
                                }
                            }
                        }
                        if (off != null) failures.add("scroll_to_row: $off")
                    }
                    "expect_shares" -> {
                        // Percent of the CHILDREN'S SUM, not of the
                        // container, so spacing and padding (platform
                        // metrics both) stay out of the number. THE
                        // ROUNDING MATCHES harness::shares EXACTLY —
                        // expect_shares compares byte-for-byte across
                        // all seven backends.
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
                        // THE UNSAVED-WORK MARK (docs/dirty-plan.md D5).
                        // Every other backend reads its CHROME; HERE THE
                        // MODEL IS THE HONEST ANSWER, the stated
                        // carve-out (D4), since this platform has no
                        // chrome to publish it in. Not vacuous — the
                        // value came over the wire.
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
                            // THE CENSUS ONLY ON THE LAST LOOKS: this
                            // arm re-runs until the deadline and the
                            // wrapper RETRACTS every earlier failure, so
                            // an UNSEEN on the first look would be about
                            // a dialog still coming up. The margin is the
                            // wrapper's own retry period.
                            stepDeadline = maxOf(
                                stepDeadline,
                                stepStart + DIALOG_LAUNCH_BUDGET_NS,
                            )
                            val lastLook = System.nanoTime() + RETRY_PERIOD_NS >= stepDeadline
                            if (lastLook) kayaNoteDialogUnseen(DIALOG_KIND_OPEN)
                            failures.add(
                                "no file dialog live, wanted \"$wantDir\"" +
                                    (if (lastLook) "; ${kayaDialogReport()}" else "")
                            )
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
                        // The REAL save panel, out of DocumentsUI's own
                        // tree: its directory AND the name in its name
                        // field. The name half catches a backend that
                        // ignored the name it was told, which saves under
                        // the SUGGESTED one while every byte assertion
                        // downstream passes on the wrong file.
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
                                // WHAT IS ON SCREEN INSTEAD: "no save
                                // dialog live" is the same sentence for
                                // a panel that never presented and for
                                // a reader that cannot see the one that
                                // did, and those want opposite fixes.
                                // The census only on the last looks, for
                                // expect_file_dialog's reason above.
                                stepDeadline = maxOf(
                                    stepDeadline,
                                    stepStart + DIALOG_LAUNCH_BUDGET_NS,
                                )
                                val lastLook = System.nanoTime() + RETRY_PERIOD_NS >= stepDeadline
                                if (lastLook) kayaNoteDialogUnseen(DIALOG_KIND_SAVE)
                                failures.add(
                                    "no save dialog live" +
                                        (if (lastLook) "; ${kayaDialogReport()}" else "")
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
                        // Press the panel's own SAVE, or dismiss it, so
                        // DocumentsUI's own create-and-answer runs.
                        // Silent; the observable is the guest's
                        // reaction to the result.
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
                            // CANCEL IS BACK on this platform — there is
                            // no Cancel button in either dialog.
                            saveArg == "cancel" ->
                                svc.dismiss()?.let { failures.add("file_save cancel: $it") }
                            !svc.confirmSave() ->
                                failures.add("file_save: the panel's SAVE button refused the press")
                            // AND THE PANEL MUST BE GONE: a press that
                            // lands before the panel is interactive is
                            // swallowed with no error anywhere, and the
                            // leg then fails three steps later on an
                            // assertion about the GUEST.
                            !svc.waitForPickerGone() -> {
                                // A null name here is not an empty name
                                // field: it is a panel nobody could read,
                                // and printing it as `naming "null"` sends
                                // the next reader after the wrong thing.
                                val naming = kayaSaveDialogState()?.second
                                failures.add(
                                    "file_save: the panel is still up " +
                                        (if (naming != null) "(naming \"$naming\")"
                                        else "(${kayaDialogReport()})") +
                                        " — the press was swallowed, which the panel " +
                                        "cannot tell you"
                                )
                                // Dismissed so the scene's continuation
                                // cannot trip the one-per-process abort
                                // and destroy this failure list
                                // (file_choose's 2026-08-20 lesson).
                                svc.dismiss()
                            }
                        }
                    }
                    "clipboard_seed" -> {
                        // An action, silent like click. OFF THE MAIN
                        // THREAD, where every verb already runs: this
                        // blocks on another process, and the ordered
                        // broadcast's result lands on main.
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
                            // POLLED by the generic expect wrapper: the
                            // copy went out on the apply pump, so the
                            // clipboard changes a moment after the click.
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
                        // Silent like click. EXCEPT that the row must
                        // be THERE, the same rule harness.rs and
                        // KayaSwiftUI apply: a name matching nothing
                        // skips the selection and presses Open anyway,
                        // and the picker completes with whatever was
                        // already selected — a silent wrong file.
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
                                // Dismiss here too, the wrong-name arm's
                                // rule: a picker left up turns the next
                                // show into the one-per-process abort,
                                // which destroys this failure list —
                                // measured 2026-08-20, filedialog-jvm's
                                // SIGABRT ate exactly this evidence.
                                kayaFileDialogDrive("cancel")
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
                        // The implicit stack is the ACTIVE surface's: the
                        // selected section's when sections are present
                        // (kayaUserBack routes the same way); window#N
                        // names a surface, window or section.
                        val got = onUi(activity) {
                            val explicitId = target.removePrefix("window#").toLongOrNull()
                            val sid =
                                if (explicit) explicitId
                                else KayaSceneModel.selectedSection?.takeIf { KayaSceneModel.sections.isNotEmpty() }
                            (sid?.let { KayaSceneModel.sectionIndex[it] }?.entries ?: KayaSceneModel.navEntries).size
                        }
                        if (got == want) {
                            observed.add("${prefix}entries $want")
                        } else {
                            failures.add("${prefix}entries $got, wanted $want")
                        }
                    }
                    "back" -> {
                        // Drive the SAME path the system back dispatch
                        // runs — AND ONLY WHERE IT WOULD RUN, since with
                        // both panes on screen the BackHandler is
                        // DISABLED. Keyed on the SCAFFOLD ARRANGEMENT,
                        // not the handler's composition-time `enabled`.
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
                        val spec = parts.getOrNull(1) ?: ""
                        val st = onUi(activity) {
                            target(spec, "scroll", KayaSceneModel.scrolls)?.scrollState
                        }
                        val axis = if (st != null) null else columnsAxis(activity, spec)
                        when {
                            st != null && st.maxValue > 0 -> observed.add("$spec overflows")
                            st != null -> failures.add("$spec fits (maxValue 0)")
                            axis == null -> failures.add("no such target $spec")
                            !axis.measured ->
                                failures.add("$spec records no columns' axis on this tier")
                            axis.reach > 0f -> observed.add("$spec overflows")
                            else -> failures.add(
                                "$spec fits (columns ${axis.content.toInt()}dp in a " +
                                    "${axis.track.toInt()}dp track)")
                        }
                    }
                    "scroll_end" -> {
                        // The REAL scrolling API, driven to its end.
                        // Silent, like click.
                        val spec = parts.getOrNull(1) ?: ""
                        onUi(activity) {
                            val rows = target(spec, "scroll", KayaSceneModel.scrolls)
                            if (rows != null) {
                                kotlinx.coroutines.MainScope().launch {
                                    rows.scrollState.scrollTo(rows.scrollState.maxValue)
                                }
                            } else {
                                // The table arm, expect_overflow's rule:
                                // the COLUMNS. Through the same
                                // ScrollableState the finger drives, so
                                // this cannot park where a gesture
                                // could not.
                                target(spec, "column", KayaSceneModel.columns)?.let { node ->
                                    kotlinx.coroutines.MainScope().launch {
                                        node.tableColumnScroll.scrollBy(
                                            node.tableReachX - node.tableScrollX)
                                    }
                                }
                            }
                        }
                    }
                    "expect_at_end" -> {
                        val spec = parts.getOrNull(1) ?: ""
                        val st = onUi(activity) {
                            target(spec, "scroll", KayaSceneModel.scrolls)?.scrollState
                        }
                        val axis = if (st != null) null else columnsAxis(activity, spec)
                        when {
                            st != null && st.maxValue - st.value <= 2 ->
                                observed.add("$spec at end")
                            st != null -> failures.add(
                                "$spec short of end (${st.value} of ${st.maxValue})")
                            axis == null -> failures.add("no such target $spec")
                            !axis.measured ->
                                failures.add("$spec records no columns' axis on this tier")
                            axis.reach - axis.at <= 2f -> observed.add("$spec at end")
                            else -> failures.add(
                                "$spec short of end (${axis.at.toInt()} of " +
                                    "${axis.reach.toInt()} column px)")
                        }
                    }
                    // THE THREE TEXT-RANGE READS go to the platform for
                    // the half it can. HIGHLIGHT IS THE ONE WITH NO
                    // PLATFORM CHANNEL — Android publishes no
                    // accessibility property carrying a background span
                    // (range-probe-android.md §4) — so it reads what the
                    // DRAW SCOPE painted, never the declaration.
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
                        // much context a scroll leaves is native
                        // behaviour, while "is my range on screen" is the
                        // same question everywhere. The `offscreen`
                        // spelling keeps this from being vacuous — a
                        // scene asserts it BEFORE the reveal.
                        val want = parts[3]
                        val got = onUi(activity) {
                            kayaRevealedRead(activity, parts[1], parts[2])
                        }
                        if (got == want) observed.add("${parts[2]} $want")
                        else failures.add("${parts[2]} is $got, wanted $want")
                    }
                    "compose" -> {
                        // The state a user is in mid-word with an IME,
                        // which no other verb reaches: `type` is
                        // printable ASCII by contract. This goes through
                        // the field's own InputConnection, so the text is
                        // DISPLAYED, UNCOMMITTED and invisible to the
                        // app — the state select_range must refuse.
                        kayaComposeMarkedText(activity, parts[1], quoted(parts.drop(2)))
                            ?.let { failures.add("compose: $it") }
                    }
                    "expect_title" -> {
                        // BOTH REAL MATERIALIZATIONS, never the model's
                        // copy: a title lands on the task label AND the
                        // composed TopAppBar, and reading one lets the
                        // other drift (the android film caught "notes"
                        // over "untitled" with all five title assertions
                        // passing, docs/deferred.md).
                        val target = parts.getOrNull(1) ?: ""
                        val explicit = target.startsWith("window#")
                        val wid = if (explicit) target.removePrefix("window#").toLongOrNull() ?: -1 else 0L
                        val prefix = if (explicit) "window#$wid " else ""
                        val want = quoted(parts.drop(if (explicit) 2 else 1))
                        val primary = wid == 0L
                        val got = onUi(activity) {
                            if (primary) activity.title?.toString() ?: "" else ""
                        }
                        val hasChrome = primary && onUi(activity) { kayaWindowHasChrome() }
                        val chrome =
                            if (hasChrome) onUi(activity) { kayaChromeTitle(activity) } else null
                        if (got != want) {
                            // The model's own view rides the refusal: the
                            // stack depth, the top entry's title, and how
                            // the last click was answered — which tells a
                            // push that never reached the model apart from
                            // a title the surfaces have not caught up to.
                            val model = onUi(activity) {
                                val entries = KayaSceneModel.navEntries
                                "entries=${entries.size} top=\"${entries.lastOrNull()?.title ?: ""}\""
                            }
                            val click = kayaLastClick?.let { (target, seen, at) ->
                                val ms = (System.nanoTime() - at) / 1_000_000
                                "last click $target ${ms}ms ago, batches since=${kayaBatches - seen}"
                            } ?: "no click yet"
                            failures.add(
                                "${prefix}title \"$got\", wanted \"$want\" ($model; $click)"
                            )
                        } else if (!hasChrome) {
                            // No catalog, no bar: the task label is the
                            // only surface this title has, and saying so
                            // is what keeps the pass honest.
                            observed.add("${prefix}title \"$want\"")
                        } else if (chrome == null) {
                            failures.add(
                                "${prefix}the task label reads \"$got\" and the window's " +
                                    "catalog composed no title in its chrome"
                            )
                        } else if (chrome != want) {
                            failures.add(
                                "${prefix}the chrome's title reads \"$chrome\" while the task " +
                                    "label reads \"$got\", wanted \"$want\""
                            )
                        } else {
                            observed.add("${prefix}title \"$want\"")
                        }
                    }
                    "expect_typeface" -> {
                        // THE RESOLVED FAMILY, off the real text nodes,
                        // named by the font's own OpenType name table.
                        // NEVER THE REQUEST — the two reads that look
                        // right both echo it, and an echo reports a
                        // perfect swap for a family the device does not
                        // have (docs/styling/typeface-compose.md §2.1).
                        val want = quoted(parts.drop(1))
                        val got = onUi(activity) { kayaResolvedTypeface() }
                        if (got == want) {
                            observed.add("typeface $want")
                        } else {
                            failures.add("typeface $got, wanted $want")
                        }
                    }
                    "expect_app_icon" -> {
                        // THE PICTURE THE LAUNCHER DRAWS, in pixels,
                        // resolved by the system's PackageManager out
                        // of the INSTALLED PACKAGE — never off kaya's
                        // model, which holds no icon here
                        // (docs/app-identity-plan.md, ruling 3 and I8).
                        val want = quoted(parts.drop(1))
                        val got = onUi(activity) { kayaAppIconSamples(activity) }
                        if (got == want) {
                            observed.add("app icon $want")
                        } else {
                            failures.add("app icon $got, wanted $want")
                        }
                    }
                    // THE CANONICAL RASTER, asked of the CORE
                    // (docs/canvas-plan.md §7.1): every backend answers
                    // the same way, since the point is that five
                    // platforms' libkaya drew one picture. The hash verb
                    // compares the hash and prints the legible facts
                    // beside it, which a hash alone cannot give.
                    "expect_drawing_hash", "expect_drawing" -> {
                        val want = quoted(parts.drop(2))
                        val probe = onUi(activity) {
                            val node = kayaCanvasTarget(parts[1])
                            if (node == null) "" else KayaPresent.canvasProbe(node.id)
                        }
                        val cut = probe.indexOf(' ')
                        val hash =
                            if (cut < 0) "<no canvas ${parts[1]}>" else probe.substring(0, cut)
                        val measured =
                            if (cut < 0) "<no canvas ${parts[1]}>" else probe.substring(cut + 1)
                        if (parts[0] == "expect_drawing_hash") {
                            if (hash == want) {
                                observed.add("drawing hash $want")
                            } else {
                                failures.add("drawing hash $hash ($measured), wanted $want")
                            }
                        } else if (measured == want) {
                            observed.add("drawing $want")
                        } else {
                            failures.add("drawing $measured, wanted $want")
                        }
                    }
                    // WHICH SIZE THE RASTER IS (docs/canvas-plan.md
                    // §3.2.1), asked of the CORE: the TRACK is what this
                    // backend measured, the VIEWBOX what the guest
                    // declared. The only canvas read a size policy can
                    // move — the hash and ink bounds come from the
                    // CANONICAL raster, taken at the viewbox, so a
                    // stretched buffer answers those identically.
                    "expect_raster" -> {
                        val want = quoted(parts.drop(2))
                        val got = onUi(activity) {
                            val node = kayaCanvasTarget(parts[1])
                            if (node == null) "<no canvas ${parts[1]}>"
                            else KayaPresent.canvasRasterShape(node.id)
                        }
                        if (got == want) {
                            observed.add("raster $want")
                        } else {
                            failures.add("raster $got, wanted $want")
                        }
                    }
                    // ADVANCE THE FRAME CLOCK (§15.4). A VERB, never wall
                    // clock: the core owns the step, so a leg's frame
                    // count is part of the scene and not a fact about the
                    // load on the machine that ran it.
                    "frame" -> {
                        val frames = if (parts.size > 1) (parts[1].toIntOrNull() ?: 1) else 1
                        onUi(activity) {
                            repeat(maxOf(frames, 1)) { KayaPresent.harnessFrame() }
                        }
                        observed.add("frame $frames")
                    }
                    // THE BLIT, sampled off the window's own rendered
                    // pixels (§7.2) — the one canvas read that fails when
                    // the buffer never reached the platform's image
                    // object. Both modes are named in the expectation, so
                    // it does not depend on the host's appearance
                    // (kayaInkForMode).
                    "expect_ink" -> {
                        val spec = quoted(parts.drop(2))
                        val halves = spec.split(" = ")
                        val points = halves.firstOrNull() ?: ""
                        val want = if (halves.size == 2) halves[1] else ""
                        val got = kayaCanvasInk(activity, parts[1], points)
                        // THE OBSERVATION IS THE WANTED TEXT, not what
                        // was read: inside the tolerance the platforms
                        // legitimately answer different bytes, and the
                        // verdict is byte-compared across all of them.
                        if (kayaInkMatches(got, want)) {
                            observed.add("ink $want")
                        } else {
                            failures.add("ink $got at $points, wanted $want")
                        }
                    }
                    "expect_window_size" -> {
                        // The surface's REAL extent against the advisory
                        // request. Android never honors a size request,
                        // so this verb fails honestly with the real
                        // numbers; the window scene is a desktop scene.
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
                        // The window content inset, MEASURED: the halved
                        // gap between the padding container's outer
                        // extent and the offer inside it, in DP, RELATIVE
                        // because absolute offers cannot be byte-frozen
                        // across platforms (docs/styling-plan.md D3).
                        // `expect_inset N` is the WINDOW's pair,
                        // `expect_inset <target> N` a CONTAINER's own.
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
                    "expect_axis" -> {
                        // The axis the render actually used, recorded at
                        // layout time (kayaContainerAxis) — never the
                        // model's field: a backend that ignored the write
                        // must fail (the expect_aligned rule, one prop
                        // over; harness.rs Step::ExpectAxis is the
                        // sentence's source of truth).
                        val want = quoted(parts.drop(2))
                        val got = onUi(activity) {
                            val isRow = parts[1].startsWith("row")
                            target(
                                parts[1], if (isRow) "row" else "column",
                                if (isRow) KayaSceneModel.rows else KayaSceneModel.columns,
                            )?.let { container ->
                                when (kayaContainerAxis[container.id]) {
                                    null -> "no container layout recorded"
                                    true -> "vertical"
                                    false -> "horizontal"
                                }
                            }
                        }
                        when {
                            got == null -> failures.add("no such target " + parts[1])
                            got == want -> observed.add(parts[1] + " axis " + want)
                            else ->
                                failures.add(
                                    parts[1] + " axis \"" + got + "\", wanted \"" + want + "\""
                                )
                        }
                    }
                    "expect_folded" -> {
                        // The stacked fold (D7), read off the state the
                        // render consumes directly — laidOut and
                        // foldedChildren ARE the composition's inputs, so
                        // this is the render's own record, membership
                        // checked on BOTH ends. harness.rs
                        // Step::ExpectFolded is the sentence's source of
                        // truth.
                        val tableSpec = parts[2]
                        val got = onUi(activity) {
                            val child =
                                target(parts[1], "column", KayaSceneModel.columns)
                            when {
                                child == null -> null
                                tableSpec == "none" ->
                                    if (child.foldedInto == 0L) "not folded" else "folded"
                                else -> {
                                    val table =
                                        target(parts[2], "column", KayaSceneModel.columns)
                                    val held =
                                        table?.foldedChildren?.any { it.id == child.id }
                                            ?: false
                                    when {
                                        table == null -> "<no such table target>"
                                        child.foldedInto == table.id && held -> "folded"
                                        child.foldedInto == 0L -> "not folded"
                                        else ->
                                            "stamped folded, but rendered outside " +
                                                "that table's viewport"
                                    }
                                }
                            }
                        }
                        when {
                            got == null -> failures.add("no such target " + parts[1])
                            got == "folded" && tableSpec != "none" ->
                                observed.add(parts[1] + " folded into " + tableSpec)
                            got == "not folded" && tableSpec == "none" ->
                                observed.add(parts[1] + " not folded")
                            tableSpec == "none" ->
                                failures.add(
                                    parts[1] + " fold reads \"" + got +
                                        "\", wanted it not folded"
                                )
                            else ->
                                failures.add(
                                    parts[1] + " fold reads \"" + got +
                                        "\", wanted it folded into " + tableSpec
                                )
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
                                    } else if (rects.all {
                                        kotlin.math.abs(it.first) <= 2.0 &&
                                            kotlin.math.abs(it.second - inner) <= 2.0
                                    }) {
                                        // STRETCH FIRST, and alone: spanning
                                        // geometry is DEGENERATE — a child at
                                        // (0, inner) satisfies start, center
                                        // and end too. The positional modes
                                        // classify only a container with a
                                        // non-spanning child.
                                        "stretch"
                                    } else {
                                        // Multi-match is ambiguity, and
                                        // ambiguity fails loudly — a
                                        // first-match answer lets an
                                        // unseparated scene pass while
                                        // proving nothing.
                                        val matches = mutableListOf<String>()
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
                    "expect_breadth" -> {
                        // The cross-axis twin of expect_fills' widget half
                        // (harness.rs Step::ExpectBreadth): the widget's
                        // recorded cross rect against its container's
                        // recorded cross breadth, the readers expect_aligned
                        // classifies from. A container target is refused as
                        // harness.rs refuses it.
                        val short = onUi(activity) {
                            if (parts[1].startsWith("row") || parts[1].startsWith("column")) {
                                return@onUi "${parts[1]} is a container; expect_breadth reads a widget"
                            }
                            kayaWidgetTarget(parts[1])?.let { widget ->
                                val parent = (KayaSceneModel.columns + KayaSceneModel.rows)
                                    .firstOrNull { c -> c.children.any { it.id == widget.id } }
                                    ?: return@let "no parent — not a flex child"
                                val inner = kayaContainerCross[parent.id] ?: 0.0
                                if (inner <= 0.0) return@let "no container layout recorded"
                                val rect = kayaCrossRects[widget.id]
                                    ?: return@let "no cross box recorded — not a flex child"
                                if (rect.second >= inner - 2.0) {
                                    ""
                                } else {
                                    "spans ${Math.round(rect.second)}px of its parent's " +
                                        "${Math.round(inner)}px breadth"
                                }
                            }
                        }
                        if (short == null) {
                            failures.add("no such target: ${parts[1]}")
                        } else if (short.isEmpty()) {
                            observed.add("${parts[1]} spans its breadth")
                        } else {
                            failures.add("${parts[1]} is short of its breadth ($short)")
                        }
                    }
                    "expect_fills" -> {
                        // ONE VERB, TWO SUBJECTS (harness.rs
                        // Step::ExpectFills). A CONTAINER's children span
                        // its content box — the leftover-consumption half
                        // of the grow contract. A WIDGET spans the cell
                        // its weight earned, so a control drawing small
                        // inside a correct cell is caught; an overflow is
                        // not a leftover, so that test is one-sided.
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
                                val ownTrack = kayaMainExtents[container.id] ?: 0.0
                                val ownDrawn = kayaDrawnExtents[container.id] ?: 0.0
                                val extent = kayaContainerExtents[container.id] ?: 0.0
                                val tracks = container.children
                                    .map { kayaMainExtents[it.id] }
                                // THE BREADTH CLAUSE'S TWO NUMBERS. The
                                // parent is looked up among containers of the
                                // OTHER kind, so a row in a row is skipped —
                                // only a CROSSING container owes its parent's
                                // breadth. The cross rect stays nullable: an
                                // unrecorded one is not a zero.
                                val crossParent =
                                    (if (isRow) KayaSceneModel.columns
                                    else KayaSceneModel.rows)
                                        .firstOrNull { p ->
                                            p.children.any { it.id == container.id }
                                        }
                                val parentInner =
                                    crossParent?.let { kayaContainerCross[it.id] } ?: 0.0
                                val ownCross = kayaCrossRects[container.id]?.second
                                when {
                                    // A grown container is a flex CHILD too:
                                    // its own box must span the track its
                                    // weight earned before its children can
                                    // span anything (docs/deferred.md's
                                    // nested-container GAP). One-sided, and
                                    // skipped where no track was recorded.
                                    ownTrack > 0.0 && ownDrawn < ownTrack - 2.0 ->
                                        "draws ${Math.round(ownDrawn)}px of its own " +
                                            "${Math.round(ownTrack)}px track"
                                    // THE BREADTH CLAUSE (2026-08-22): a
                                    // CROSSING container spans its parent's
                                    // inner breadth under EVERY align mode.
                                    // Skipped honestly when the parent is not
                                    // a recorded container of the other kind,
                                    // or when either number is missing.
                                    parentInner > 0.0 && ownCross != null &&
                                        ownCross < parentInner - 2.0 ->
                                        "spans ${Math.round(ownCross)}px of its parent's " +
                                            "${Math.round(parentInner)}px breadth"
                                    container.tableColumns.isNotEmpty() &&
                                        (container.tableViewportH <= 0f ||
                                            container.tableContentH <= 0f) ->
                                        "no table layout recorded"
                                    container.tableColumns.isNotEmpty() &&
                                        container.tableContentH > container.tableViewportH + 2f ->
                                        "children span ${Math.round(container.tableContentH)}dp " +
                                            "inside a ${Math.round(container.tableViewportH)}dp viewport"
                                    container.tableColumns.isNotEmpty() -> ""
                                    extent <= 0.0 -> "no container layout recorded"
                                    // Summing unrecorded tracks as zeros
                                    // reports a leftover built from nothing;
                                    // a verdict may only claim what it
                                    // measured (CLAUDE.md invariant 3).
                                    container.children.isNotEmpty() &&
                                        tracks.any { it == null } ->
                                        "no child tracks recorded — not a flex container"
                                    else -> {
                                        val span = tracks.filterNotNull().sum() +
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
                                    // VERDICT, ahead of the comparison: no
                                    // AccessibilityNodeInfo measured no
                                    // classification ([KayaAxRead]). It earns
                                    // a longer leash once per step — the
                                    // disagreement outlived the 5s deadline in
                                    // three matrix runs, solo-green in every.
                                    !got.infoServed &&
                                        System.nanoTime() >= stepStart + 20_000_000_000L &&
                                        got.fallback == want -> {
                                        // THE LEASH EXPIRED WITH THE PROVIDER
                                        // STILL SILENT, and the SEMANTICS TREE
                                        // — its own source — answers what the
                                        // step asks. The observation stays
                                        // byte-identical (invariant 6); the
                                        // evidence downgrade is logged here
                                        // (ruled 2026-08-16).
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
                    "expect_help" -> {
                        // The state the platform's own tooltip draws
                        // from (docs/tooltip-plan.md T5): the wrapper in
                        // [KayaRenderHelped] reads this same field.
                        val want = quoted(parts.drop(2))
                        val node = kayaWidgetTarget(parts[1])
                        if (node == null) {
                            failures.add("no such target ${parts[1]}")
                        } else {
                            val got = onUi(activity) { node.help }
                            if (got == want) {
                                observed.add("help \"$want\"")
                            } else {
                                failures.add("help \"$got\", wanted \"$want\"")
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
                        // system owns it (DESIGN.md, Windows). LOUD
                        // rather than a silent no-op.
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
                    "expect_panes" -> {
                        // `<size class>/<positions>` (docs/multicolumn-plan.md
                        // D4). Positions from the ThreePaneScaffoldValue the
                        // scaffold was really laid out from, role by role —
                        // an EMPTY slot contributes no position (D1: a pane
                        // is a surface from the stack). The serial arm has
                        // no arrangement and reads its top.
                        val want = quotedHead(line.substring(parts[0].length))?.first ?: ""
                        val stamped =
                            onUi(activity) {
                                KayaSceneModel.formFactor +
                                    "/" +
                                    KayaSceneModel.splitPresentation
                            }
                        val stack = onUi(activity) { KayaSceneModel.navEntries.size }
                        val halves = stamped.split("/", limit = 2)
                        if (want.isEmpty()) {
                            // The bare form: expect_split's asymmetric
                            // invariant, on the ARM stamp.
                            if (halves.size == 2 &&
                                halves[0] == "regular" &&
                                halves[1] == "stacked" &&
                                stack >= 1
                            ) {
                                failures.add(
                                    "presentation $stamped: a regular window must not " +
                                        "show one pane while its stack holds two")
                            } else {
                                observed.add("panes fit")
                            }
                        } else {
                            val positions =
                                onUi(activity) { kayaPanePositions() }
                            val got = halves[0] + "/" + positions
                            if (got == want) {
                                observed.add("panes $want")
                            } else {
                                failures.add("panes $got, wanted $want")
                            }
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
                            // byte-for-byte, so it cannot echo a value
                            // that legitimately differs. Asymmetric on
                            // purpose: a compact window with a bar is
                            // fine.
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
                        // BARE, like expect_menu_presentation: capacity k
                        // is this platform's own number, so the pass
                        // observation is the LANE-INDEPENDENT word and
                        // the measured counts ride the failure. The
                        // reading is a walk of the composed TopAppBar
                        // (kayaToolbarChromeRead); the rule is mirrored
                        // from harness.rs (kayaToolbarChromeFits).
                        val got = onUi(activity) { kayaToolbarChromeRead(activity) }
                        val why = kayaToolbarChromeFits(got)
                        if (why == null) observed.add("toolbar")
                        else failures.add(why)
                    }
                    "expect_toolbar_item" -> {
                        // ITS OWN ARM rather than a second label on the
                        // one above: check-verbs reads each `"expect_*"
                        // ->` head, so a verb sharing another's head is
                        // one the sweep never sees.
                        //
                        // Quoted label, then quoted aspect — a symbol
                        // name, or enabled/disabled.
                        val head = quotedHead(line.substring(parts[0].length))
                        val want = head?.let { quotedHead(it.second) }
                        if (head == null || want == null || want.second.isNotEmpty()) {
                            failures.add(
                                "expect_toolbar_item wants a quoted label and a quoted " +
                                    "aspect: $line")
                        } else {
                            val got = onUi(activity) {
                                kayaToolbarItemRead(activity, head.first, want.first)
                            }
                            if (got == want.first) {
                                observed.add("toolbar item ${head.first} ${want.first}")
                            } else {
                                // The measured answer rides the failure,
                                // telling a wrong glyph from a button
                                // that is not in the chrome.
                                failures.add(
                                    "toolbar item ${head.first} reads \"$got\", " +
                                        "wanted \"${want.first}\"")
                            }
                        }
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
                        // read off the composed row's merged semantics.
                        val head = quotedHead(line.substring(parts[0].length))
                        val want = head?.let { quotedHead(it.second) }
                        if (head == null || want == null || want.second.isNotEmpty()) {
                            failures.add(
                                "expect_menu_symbol wants a quoted path and a quoted " +
                                    "symbol name: $line")
                        } else {
                            val got = onUi(activity) { kayaMenuSymbolRead(activity, head.first) }
                            if (got == want.first) {
                                // Put the overflow back, so the next step
                                // sees the surface the scene left. ONLY
                                // ON THE HIT: a miss is retried, and
                                // closing between attempts would take
                                // the row away each time.
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
                        // helper every rendered row calls. Silent, like
                        // click.
                        val head = quotedHead(line.substring(parts[0].length))
                        if (head == null || head.second.isNotEmpty()) {
                            failures.add("menu_activate wants a quoted path: $line")
                        } else {
                            val ok = onUi(activity) {
                                val hit = kayaResolveMenuPath(head.first)
                                if (hit != null) {
                                    // The leaf firing closes the open
                                    // menu, so CLOSE BEFORE THE FIRE.
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
                        val kind = spec.takeWhile { it != '#' && it != '@' }
                        if (kind == "entry" || kind == "textarea") {
                            // Editable text keeps its native edit menu
                            // as dress; probing a menu that cannot
                            // exist is the false-verdict class.
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
                        // The catalog walk the hardware-key route
                        // traverses, emitting the SAME menu_activated a
                        // row does: ONE dispatch path.
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
                attempt++
                KayaVTrace.attempt(
                    parts[0], attempt,
                    if (failures.size > failuresBefore) {
                        "<- not yet: " + failures.subList(failuresBefore, failures.size).joinToString("; ")
                    } else {
                        "<- ok"
                    },
                )
                val fault = KayaPresent.fault()?.toString(Charsets.UTF_8)
                if (fault != null) {
                    // THE CORE FAULTED: nothing after this is applied, so
                    // the retry below is dead time and every following step
                    // would fail for a reason three removes from this one.
                    // The in-flight attempt is RETRACTED — it never reached
                    // its deadline, and a non-final read printed beside the
                    // cause sends the next reader after the wrong thing.
                    while (failures.size > failuresBefore) failures.removeAt(failures.size - 1)
                    failures.add(fault)
                    Log.e("kaya", "KAYA_HARNESS: step-failed $fault")
                    reportedFault = true
                    break@scriptLines
                }
                if (failures.size > failuresBefore && parts[0].startsWith("expect") &&
                    System.nanoTime() < stepDeadline
                ) {
                    while (failures.size > failuresBefore) failures.removeAt(failures.size - 1)
                    Thread.sleep(RETRY_PERIOD_MS)
                    retryStep = true
                } else if (failures.size > failuresBefore) {
                    // THE EVIDENCE MUST OUTLIVE THE PROCESS: an abort before
                    // the verdict takes `failures` with it and leaves a crash
                    // with no reason. So a failure is printed the moment it is
                    // FINAL — an expect past its deadline, or any action.
                    // check-verbs.py holds this level with harness.rs and
                    // KayaSwiftUI.swift.
                    for (i in failuresBefore until failures.size) {
                        Log.i("kaya", "KAYA_HARNESS: step-failed ${failures[i]}")
                    }
                }
                }
                statements++
                if (statements == remountAfter) {
                    val stuck = kayaRecreate(statements, line)
                    if (stuck != null) {
                        failures.add(stuck)
                        Log.e("kaya", "KAYA_HARNESS: step-failed $stuck")
                        break@scriptLines
                    }
                }
            }
        }
        // THE LAST STEP CAN FAULT TOO, and a fault must never leave a
        // green verdict behind it.
        if (!reportedFault) {
            val late = KayaPresent.fault()?.toString(Charsets.UTF_8)
            if (late != null) {
                failures.add(late)
                Log.e("kaya", "KAYA_HARNESS: step-failed $late")
            }
        }
        if (failures.isEmpty() && observed.isEmpty()) {
            failures.add("script has no expects")
        }
        // A recreation phase that never recreated is a GREEN LEG THAT
        // TESTED NOTHING — the count outran the script, or the run ended
        // early. Refused here as well as in the runner's grep.
        if (remountAfter > 0 && statements < remountAfter) {
            failures.add(
                "KAYA_RECREATE_AFTER=$remountAfter but the script ran only " +
                    "$statements statements, so nothing was recreated",
            )
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
            // THE UNMOUNTED-SCENE DIAGNOSIS (docs/traps.md): a scene
            // that never mounts a root renders an EMPTY surface, and
            // target resolution cannot catch it because the widgets
            // exist in the model. ON THE FAILURE PATH, so it cannot
            // fire before the guest's transactions arrive.
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
            // FAILURE ONLY, and BEFORE the publish: after it the watchdog
            // may end the process at any moment (crates/kaya/src/vtrace.rs).
            KayaVTrace.dump("the verdict failed: KAYA_SELFTEST: FAILED (${reported.joinToString("; ")})")
            Log.e("kaya", "KAYA_SELFTEST: FAILED (${reported.joinToString("; ")})")
            1
        }
        // The halt below hops to the UI thread, which is the thread that
        // may be answering nothing; the grace leaves under the verdict
        // either way.
        watchdog.published(code)
        // READ ONCE, and nullable: a relaunch may be in flight, and the
        // halt is what ends this process either way.
        val leaving = mountedActivity
        mainThread.post {
            leaving?.finishAndRemoveTask()
            Runtime.getRuntime().halt(code)
        }
    }
}

/** The interpreter's render: the node tree as Compose declarations. */
// The exposed-dropdown family is still behind M3's experimental gate.
/**
 * Guest-visible text uses LF on every platform. NORMALIZE AT EVERY WRITE
 * into the model, so reads need none — but NOT on the DELIVERED half of
 * the paste split, where content crosses as a REPRESENTATION.
 */

/**
 * THE BLIT'S BYTES (docs/canvas-plan.md §8). `Bitmap.Config.ARGB_8888`
 * IS RGBA IN MEMORY ORDER on Android and premultiplied by default, so
 * this arm swizzles nothing and `expect_ink` fails if that stops being
 * true. Null for a short buffer — the render keeps the node present
 * either way (tools/check-empty-child.py).
 */
private fun kayaDrawingBitmap(bytes: ByteArray?, width: Int, height: Int): ImageBitmap? {
    if (bytes == null || width <= 0 || height <= 0) return null
    val want = width * height * 4
    if (bytes.size < want) return null
    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(bytes, 0, want))
    return bitmap.asImageBitmap()
}

private fun kayaLf(s: String): String =
    if (s.contains('\r')) s.replace("\r\n", "\n").replace('\r', '\n') else s

// ---- The native text-undo tier (docs/undo-plan.md D1) ---------------
//
// A NATIVE UNDO DOES EMIT THE ORDINARY text_changed HERE, the opposite
// of the mac arm and structural: `undoState.undo()` writes the same
// snapshot state this backend's observer emits from (measured,
// emulator-5558, foundation 1.7.5). So this arm rides the ordinary
// channel and brackets it ledger-quiet.

/**
 * EVERY TOUCH OF `undoState`, in one place, so the file's experimental
 * opt-in stays one annotation at the smallest scope covering it:
 * `undoState` and its five members are the ONLY
 * `@ExperimentalFoundationApi` surface this file uses at foundation
 * 1.7.5.
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
 * KAYA WRITES A TEXT WIDGET: the model and the widget together, D7 and
 * A3 with them. D7 is FREE, and the explicit `clearHistory()` beside it
 * is the RULE'S SPELLING. A3 IS THE GUARD IN FRONT OF THE WRITE, since
 * even a no-op rewrite clears the history (B6). The model is assigned
 * FIRST, or a lagging mirror emits kaya's write back as a user edit.
 */
internal fun kayaWriteText(node: KayaNode, next: String) {
    node.text = next
    // PROP_TEXT reaches labels and buttons too, and they have no field
    // to write into: touching `textState` would mint a state object per
    // label for nothing. The model assignment above is their whole
    // write.
    if (node.kind != KayaCompose.KIND_ENTRY && node.kind != KayaCompose.KIND_TEXTAREA) return
    if (node.textState.text.contentEquals(next)) return
    node.textState.setTextAndPlaceCursorAtEnd(next)
    KayaUndoState.clearHistory(node)
}

// ---- Text ranges: the ONE place this file converts an offset ---------
//
// THE LOWERING PATH DOES NO ARITHMETIC (offsets arrive in UTF-16 code
// units) while a READ answers in the PROTOCOL's UTF-8 byte offsets
// (docs/ranges-units.md §7). BOTH CONVERSIONS REFUSE A SPLIT CHARACTER:
// `substring` across a surrogate pair hands back a LONE SURROGATE, which
// encodes to a single `?` with no error anywhere (§4).

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
 * `<start>:<end>=<covered text>` per range, `|`-joined, ascending. THE
 * COVERED TEXT IS NOT DECORATION: offsets alone let a wrong lowering
 * report its own numbers back unharmed, while the covered half has NO
 * ARITHMETIC in it and shows up as the wrong CHARACTERS.
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
 * THE REFUSAL ASKS THE PLATFORM: an `edit {}` selection over a live
 * composing region DESTROYS it (range-probe-android.md §5). A no-op
 * under a named reason. Route A rather than the semantics
 * `SetSelection`, which preserves the region and would still owe it.
 */
internal fun kayaSelectRange(node: KayaNode, range: KayaRange) {
    val length = node.textState.text.length
    // Bounds re-checked against the LIVE field: Compose THROWS
    // IllegalArgumentException on an out-of-bounds selection
    // (`requireValidRange`), and the field's length is a fact only this
    // side holds at this instant.
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
 * REVEAL one range: scroll the textarea's viewport until the range's box
 * is inside it. THE GEOMETRY IS THE PLATFORM'S, so nothing here models
 * where text is; it scrolls MINIMALLY, landing the range at the EDGE,
 * which is why the observable kaya fixes is CONTAINMENT. A PURE EFFECT
 * touching no selection and no composition (measured, §5).
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
 * THE VIEWPORT'S HEIGHT, in the one spelling this field publishes:
 * content height minus how far it can scroll. `ScrollState.viewportSize`
 * IS NOT IT and reads 0 — `TextFieldCoreModifier` sets `maxValue` (548
 * for a 644px layout in a 96px box) and never touches it (measured
 * 2026-08-06).
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
 * editable's native history goes with it. THE ONE SITE THAT NEEDS AN
 * EXPLICIT `clearHistory()`, since every other clear here is a write —
 * this one must clear WITHOUT touching the text. Every episode then
 * begins with an empty native stack.
 */
internal fun kayaClearUndoForGroup() {
    kayaFocusedTextNode()?.let { KayaUndoState.clearHistory(it) }
}

/**
 * The focused widget, if it is one this arm's text tier applies to.
 * THE MODEL'S FOCUS and not the platform's: every other command on this
 * host acts through it, and the two agree because the model is what
 * drives the FocusRequester.
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
 * this platform's vocabulary and ASKED NOWHERE ELSE in this file. The
 * core's `route_undo` consumes the answer.
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
 * The ledger-quiet bracket around a native undo this backend ROUTED
 * (§3): node id -> the text the walk left in the widget. A BRACKET AND
 * NOT A FLAG-WITH-A-TIMER, because the two reports are NOT adjacent in
 * time — the observer delivers the same text a frame later, so a boolean
 * around the call would be gone. UI thread only.
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
 * report it ONCE, sampling FROM THE WIDGET immediately after — the model
 * is one collector turn stale. THE THIRD FACT IS `canUndo` IN BOTH
 * DIRECTIONS, where `canRedo` would answer false at the end of a forward
 * walk and send the core backwards.
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
// This host's spelling of KayaHostApi's undo rows, declared in
// KayaPresent.kt and registered by `register_present_natives`
// (crates/kaya/src/android.rs); tools/check-jni.py pins both directions.
// THE WINDOW IS 0 EVERYWHERE HERE — Android is one Activity.

/**
 * Where an undo would go RIGHT NOW. ASKED ONCE AND USED TWICE —
 * enablement and activation are the same question (D6). THE ANSWER IS
 * THE CORE'S: the backend contributes only what it alone can see, what
 * is focused and whether that field's stack has anything.
 */
internal fun kayaUndoRoute(): KayaUndoRoute =
    kayaRouteCode(
        KayaPresent.undoRoute(0, KayaSceneModel.focusedId ?: 0, kayaFocusedCanUndo()))

/** Redo's twin, asking with `canRedo`. */
internal fun kayaRedoRoute(): KayaUndoRoute =
    kayaRouteCode(
        KayaPresent.redoRoute(0, KayaSceneModel.focusedId ?: 0, kayaFocusedCanRedo()))

/**
 * The core's three-way answer, in this file's vocabulary. AN UNKNOWN
 * CODE IS A PROTOCOL DRIFT, never a "nothing to do" — that is the one
 * wrong answer that looks exactly like the right one. `undo_route_code`
 * in crates/kaya/src/capi.rs is the authority for the mapping.
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
 * THE ONE REPORT OF A ROUTED NATIVE UNDO (§3), on a backend where BOTH
 * channels fire: `undoState.undo()` writes the same snapshot state the
 * field's collector observes, so the ordinary `text_changed` arrives a
 * frame later on its own (docs/probes/undo-fan-compose.md §1 Q-a). That
 * emission is bracketed LEDGER-QUIET and this call is the report.
 */
internal fun kayaNoteNativeUndo(node: KayaNode, text: String, canUndo: Boolean) {
    KayaPresent.noteNativeUndo(0, node.id, text, canUndo)
}

/**
 * The CORE tier: routing cases 2 and 3 (§3), where the core applies the
 * inverse itself. NOTHING COMES BACK — the inverse produces ordinary
 * apply records that arrive through the pump, so this layer keeps no
 * copy of the ledger to disagree with.
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
 * ONE TABLE'S COLUMNS' AXIS as the three scroll verbs read it: track and
 * resolved columns in dp, granted scroll and current offset in device
 * pixels. [measured] is the guard the three share — a table whose layout
 * has not run records no track, and "fits" would then be a claim about a
 * measurement nobody took.
 */
private data class KayaColumnsAxis(
    val track: Float,
    val content: Float,
    val reach: Float,
    val at: Float,
) {
    val measured: Boolean get() = track > 0f && content > 0f
}

/**
 * ONE CAUSE PER SENTENCE for expect_column_edges' horizontal half
 * (invariant 3). THE ORDER IS gtk.rs's — track, LEADING edge, trailing —
 * since a table displaced at its start also ends wrong. GTK's
 * `ContentUnderfill` is missing because the INSTRUMENT is: a cell's box
 * here is its INK (docs/deferred.md's leading-edge UNDERFILL entry).
 */
private enum class KayaTableHorizontalIssue {
    TrackUnderfill,
    ColumnsUnreachable,
    ContentLeftUnderfill,
    ContentLeftOverflow,
    ContentOverflow,
}

/**
 * [drawn] the laid-out width, [content] the columns BEFORE the coerce,
 * [track] the parent's offer, [viewport] the table's width, [left]/
 * [right] the cell ink, [reach] the granted scroll. COLUMNS PAST THE
 * TRACK ARE NORMAL, so the defect is columns the reader CANNOT REACH —
 * hence [reach] measured, not computed as `content - track`.
 */
private fun kayaTableHorizontalIssue(
    drawn: Float,
    content: Float,
    track: Float,
    viewport: Float,
    left: Float,
    right: Float,
    reach: Float,
): KayaTableHorizontalIssue? = when {
    drawn < track - 2 -> KayaTableHorizontalIssue.TrackUnderfill
    content > track + reach + 2 -> KayaTableHorizontalIssue.ColumnsUnreachable
    left > 2 -> KayaTableHorizontalIssue.ContentLeftUnderfill
    left < -2 -> KayaTableHorizontalIssue.ContentLeftOverflow
    right > viewport + reach + 2 -> KayaTableHorizontalIssue.ContentOverflow
    else -> null
}

/** The convicting sentence for each cause, or null when there is none. */
private fun kayaTableHorizontalComplaint(
    drawn: Float,
    content: Float,
    track: Float,
    viewport: Float,
    left: Float,
    right: Float,
    reach: Float,
): String? = when (
    kayaTableHorizontalIssue(drawn, content, track, viewport, left, right, reach)
) {
    KayaTableHorizontalIssue.TrackUnderfill ->
        "draws ${drawn.toInt()}dp of a ${track.toInt()}dp track"
    KayaTableHorizontalIssue.ColumnsUnreachable ->
        "columns resolve to ${content.toInt()}dp in a ${track.toInt()}dp track " +
            "that scrolls ${reach.toInt()}dp"
    KayaTableHorizontalIssue.ContentLeftUnderfill ->
        "cells start at ${left.toInt()}dp inside a ${viewport.toInt()}dp viewport"
    KayaTableHorizontalIssue.ContentLeftOverflow ->
        "cells start at ${left.toInt()}dp outside a ${viewport.toInt()}dp viewport"
    KayaTableHorizontalIssue.ContentOverflow ->
        "cells end at ${right.toInt()}dp outside a ${viewport.toInt()}dp viewport " +
            "that scrolls ${reach.toInt()}dp"
    null -> null
}

/**
 * THE TRUTH TABLE, ON THE UNAVOIDABLE PATH: expect_column_edges runs it
 * before reading any geometry, so a backend whose sentences stopped
 * discriminating reddens the leg rather than being believed. A sentence
 * and not a throw (runScript's thread has no catch); each is read off
 * six PAIRWISE DISTINCT numbers, so a wrong arm is not a coincidence.
 */
private fun kayaTableHorizontalSelftest(): String? {
    // A table that CANNOT scroll its columns is the default here, which
    // is what every claim written before the 2026-08-29 ruling assumed.
    fun issue(d: Float, c: Float, t: Float, v: Float, l: Float, r: Float, reach: Float = 0f) =
        kayaTableHorizontalIssue(d, c, t, v, l, r, reach)
    fun say(d: Float, c: Float, t: Float, v: Float, l: Float, r: Float, reach: Float = 0f) =
        kayaTableHorizontalComplaint(d, c, t, v, l, r, reach)
    val claims = listOf(
        "a table filling its track, its viewport and its ink is silent" to
            (issue(100f, 100f, 100f, 100f, 0f, 100f) == null &&
                say(100f, 100f, 100f, 100f, 0f, 100f) == null),
        // Both sides of every 2dp slack — the slack is what keeps a
        // subpixel arrange from reddening a correct table.
        "2dp short of the track is inside the slack" to
            (issue(98f, 98f, 100f, 100f, 0f, 98f) == null),
        "any further short of the track is a track underfill" to
            (issue(97.9f, 97.9f, 100f, 100f, 0f, 97.9f) ==
                KayaTableHorizontalIssue.TrackUnderfill),
        "columns 2dp over the track are inside the slack" to
            (issue(100f, 102f, 100f, 100f, 0f, 100f) == null),
        "columns any further over an unscrollable track are unreachable" to
            (issue(100f, 102.1f, 100f, 100f, 0f, 100f) ==
                KayaTableHorizontalIssue.ColumnsUnreachable),
        // THE RULING OF 2026-08-29, both sides of it: columns past the
        // track are what a scrolling table looks like, and are a defect
        // only where the scroll does not go far enough to reach them.
        "columns past a track that scrolls to them are silent" to
            (issue(100f, 140f, 100f, 100f, 0f, 140f, 40f) == null),
        "2dp past what the scroll reaches is still inside the slack" to
            (issue(100f, 142f, 100f, 100f, 0f, 100f, 40f) == null),
        "columns any further than the scroll reaches are unreachable" to
            (issue(100f, 142.1f, 100f, 100f, 0f, 100f, 40f) ==
                KayaTableHorizontalIssue.ColumnsUnreachable),
        "ink past a viewport the reader can scroll is silent" to
            (issue(100f, 100f, 100f, 100f, 0f, 142f, 40f) == null),
        "ink past what the reader can reach is a trailing-edge overflow" to
            (issue(100f, 100f, 100f, 100f, 0f, 142.1f, 40f) ==
                KayaTableHorizontalIssue.ContentOverflow),
        "cells 2dp inside the viewport are inside the slack" to
            (issue(100f, 100f, 100f, 100f, 2f, 100f) == null),
        "cells any further inside are a leading-edge underfill" to
            (issue(100f, 100f, 100f, 100f, 2.1f, 100f) ==
                KayaTableHorizontalIssue.ContentLeftUnderfill),
        "cells 2dp left of the viewport are inside the slack" to
            (issue(100f, 100f, 100f, 100f, -2f, 100f) == null),
        "cells any further left are a leading-edge overflow" to
            (issue(100f, 100f, 100f, 100f, -2.1f, 100f) ==
                KayaTableHorizontalIssue.ContentLeftOverflow),
        "cells 2dp past the viewport are inside the slack" to
            (issue(100f, 100f, 100f, 100f, 0f, 102f) == null),
        "cells any further past are a trailing-edge overflow" to
            (issue(100f, 100f, 100f, 100f, 0f, 102.1f) ==
                KayaTableHorizontalIssue.ContentOverflow),
        // The four sentences, each naming the number that convicts it.
        "the track-underfill sentence names the drawn width and the track" to
            (say(80f, 85f, 120f, 100f, 0f, 70f) == "draws 80dp of a 120dp track"),
        "the unreachable-columns sentence names the columns, the track and the reach" to
            (say(119f, 140f, 120f, 110f, 0f, 130f, 7f) ==
                "columns resolve to 140dp in a 120dp track that scrolls 7dp"),
        "the leading-underfill sentence names the cell start and the viewport" to
            (say(98f, 95f, 99f, 100f, 40f, 90f) ==
                "cells start at 40dp inside a 100dp viewport"),
        "the leading-edge sentence names the cell start and the viewport" to
            (say(98f, 95f, 99f, 100f, -40f, 90f) ==
                "cells start at -40dp outside a 100dp viewport"),
        // The leading edge here is 1dp and not the 5dp it was until
        // 2026-08-25: 5dp inside its own viewport is a CONVICTABLE state
        // now, so the case stopped isolating the sentence it pins. The
        // number had no other job — six pairwise-distinct numbers, so an
        // arm printing the wrong one is a red rather than a coincidence.
        "the trailing-edge sentence names the cell end, the viewport and the reach" to
            (say(98f, 95f, 99f, 100f, 1f, 140f, 7f) ==
                "cells end at 140dp outside a 100dp viewport that scrolls 7dp"),
        // Precedence where several hold at once, which is the ordinary
        // case: the ROOT is reported, never its symptom.
        "a table short of its track is convicted of that first" to
            (issue(80f, 200f, 120f, 100f, -40f, 200f) ==
                KayaTableHorizontalIssue.TrackUnderfill),
        "unreachable columns outrank the ink overflow they cause" to
            (issue(100f, 140f, 100f, 100f, 0f, 140f) ==
                KayaTableHorizontalIssue.ColumnsUnreachable),
        "a table shifted left is not convicted of overflowing right" to
            (issue(100f, 100f, 100f, 100f, -40f, 140f) ==
                KayaTableHorizontalIssue.ContentLeftOverflow),
        "a table drawn INSIDE its viewport is not convicted of overflowing" to
            (issue(100f, 100f, 100f, 100f, 40f, 140f) ==
                KayaTableHorizontalIssue.ContentLeftUnderfill),
        // THE CARDED SCROLL CLIP YIELDS THE CELLS' OWN BOX: the segmented
        // containers and their interior are CONTENT, so a 232dp clip with
        // this card's 16dp interior is a 200dp box starting at x+16 — the
        // frame every claim below is read in.
        "the carded scroll clip yields the cells' own box" to
            (kayaTableCellsBox(0f, 232f, 16f) == Pair(16f, 216f)),
        "an uncarded clip is its own cells' box" to
            (kayaTableCellsBox(0f, 232f, 0f) == Pair(0f, 232f)),
        // A PADDED CARD CONVICTS NOTHING (docs/deferred.md's table-card
        // entry). ONE physical table, read twice: a 232dp outer box, this
        // card's own 16dp interior per side, 200dp of content inside it.
        // The reported viewport IS that content box — kayaTableCellsBox
        // insets the clip — so every number is that box's and the leading
        // edge is 0.
        "a padded card read in its own content box is silent" to
            (issue(200f, 200f, 200f, 200f, 0f, 200f) == null),
        // The SAME table read at the CLIP instead of the cells' box: the
        // track and the viewport are the segments' outer box, the content
        // is not, and 16dp of card interior convicts a correct table.
        "a viewport read outside the card's padding convicts it" to
            (issue(200f, 200f, 232f, 232f, 16f, 216f) ==
                KayaTableHorizontalIssue.TrackUnderfill),
        // The shape the WinUI half was MEASURED failing on: 310dp of
        // columns in a 300dp track whose ink runs 5..295, where the
        // pre-split sentence printed "cells span 290dp inside a 300dp
        // viewport" — two numbers asserting the opposite of the failure.
        // Held here too, because the two backends answer one rule.
        "an unreachable table names its columns, not a compliant-looking span" to
            (say(300f, 310f, 300f, 300f, 5f, 295f) ==
                "columns resolve to 310dp in a 300dp track that scrolls 0dp"),
    )
    val broken = claims.firstOrNull { !it.second } ?: return null
    return "the table containment truth table broke: ${broken.first}"
}

/**
 * A row showing less than this is not visible. The first-visible row is
 * read from laid-out edges against a scroll offset the platform rounds
 * to whole pixels, so an exact `bottom > scroll` names the row ABOVE
 * whenever a scroll_to_row lands half a pixel low.
 */
private const val KAYA_WINDOW_VISIBLE_PX = 1.0

/** Every live windowed table, by node id — what the harness's
 *  expect_window and scroll_to_row arms reach. UI thread only (they go
 *  through `onUi`, and the composition is there too). */
internal val kayaTableWindows = HashMap<Long, KayaTableWindow>()

/**
 * ONE TABLE'S WINDOW: the report loop, the spacers' numbers, the anchor
 * (docs/virtualization-plan.md §2.4, §3). Nothing here estimates a row
 * height, and reports go out only where this tier disagrees with the
 * core, which stops the report -> stamp -> layout cycle. THE REPORT
 * NEVER RUNS INSIDE MEASURE OR PLACEMENT.
 */
internal class KayaTableWindow(private val node: KayaNode) {
    /**
     * THE SPACERS' NUMBERS, and the only place the composition learns
     * them. Published HERE by the report loop, so no layout pass calls
     * across the ABI and a correction that moved only the arithmetic
     * still re-cuts the spacers.
     */
    var bandStart by mutableStateOf(0)
        private set
    var bandCount by mutableStateOf(0)
        private set
    var offsetPx by mutableStateOf(0.0)
        private set
    var extentPx by mutableStateOf(0.0)
        private set

    private val slots = DoubleArray(KayaPresent.GEOMETRY_SLOTS)
    private val scope = kotlinx.coroutines.MainScope()

    // What the LAYOUT wrote, for the report that follows it. Plain
    // fields: written during measure, read on the next main-looper hop.
    /** Where the collection's row 0 sits inside the scrolled content: the
     *  header segment, the segment gap, and the body segment's own top
     *  interior. */
    @Volatile var rowsTopPx = 0
    /** The band THIS LAYOUT drew, and the realized rows' tops (in rows
     *  space, the core's offset included) and extents — each row's
     *  top-to-top repeat distance, spacing included, which is what §2.1
     *  means by pitch. */
    @Volatile var laidOutFirst = 0
    @Volatile var rowTops: IntArray = IntArray(0)
    @Volatile var rowExtents: IntArray = IntArray(0)
    /** The scroll container's own height — the viewport, read one
     *  modifier OUTSIDE the scroll, where the box is what the reader
     *  sees rather than what the content asked for. */
    @Volatile var viewportPx = 0
    /** THE COLUMNS' AXIS'S BOX as the last layout measured it: the
     *  resolved columns and the interior track they were laid out in. */
    @Volatile var hContentPx = 0
    @Volatile var hTrackPx = 0

    private var lastHContent = -1
    private var lastHTrack = -1
    private var lastFirst = -1
    private var lastCount = -1
    private var anchorRow = -1
    private var anchorScroll = -1
    private var scheduled = false

    fun schedule() {
        if (scheduled) return
        scheduled = true
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            scheduled = false
            report()
        }
    }

    /**
     * §2.4: `scroll_to_row` parks a ROW. THE BAND MOVES FIRST — the
     * target may be a row no layout has realized, and only a realized
     * row has a laid-out top to scroll to — and every correction cycle
     * after this re-parks on the same row.
     */
    fun park(row: Int) {
        anchorRow = row
        anchorScroll = -1
        val count = if (lastCount > 0) lastCount else 1
        lastFirst = row
        lastCount = count
        KayaPresent.windowMoved(node.id, row.toLong(), count.toLong())
        schedule()
    }

    /** The laid-out top of a realized row, in the scrolled content's own
     *  space; -1 while that row is not realized. */
    private fun contentTopOf(row: Int): Int {
        val at = row - laidOutFirst
        val tops = rowTops
        if (at < 0 || at >= tops.size) return -1
        return rowsTopPx + tops[at]
    }

    /**
     * The rows this viewport actually shows, as COLLECTION indices, read
     * off the edges THIS TIER LAID OUT. The fallback under it is for a
     * viewport that left the band entirely — a fling or a resize, where
     * nothing laid out can be read — and the CORE's own extents answer
     * instead until the next report brings the band back.
     */
    private fun visibleRange(scroll: Int): Pair<Int, Int> {
        val tops = rowTops
        val extents = rowExtents
        var first = -1
        var count = 0
        for (at in tops.indices) {
            val top = rowsTopPx + tops[at]
            val bottom = top + extents[at]
            if (bottom - scroll > KAYA_WINDOW_VISIBLE_PX && top < scroll + viewportPx) {
                if (first < 0) first = laidOutFirst + at
                count++
            }
        }
        if (first >= 0) return Pair(first, count)
        val total = slots[KayaPresent.GEOMETRY_TOTAL].toInt()
        val pitch = if (total > 0) KayaPresent.rowExtent(node.id, 0) else 0.0
        if (pitch <= 0.0) return Pair(0, 0)
        val want = (scroll - rowsTopPx).toDouble().coerceAtLeast(0.0)
        var index = laidOutFirst.coerceIn(0, total - 1)
        if (slots[KayaPresent.GEOMETRY_CORRECTED] == 0.0) {
            index = (want / pitch).toInt()
        } else {
            var y = slots[KayaPresent.GEOMETRY_OFFSET]
            while (y > want && index > 0) {
                index--
                y -= KayaPresent.rowExtent(node.id, index.toLong())
            }
            var next = KayaPresent.rowExtent(node.id, index.toLong())
            while (y + next <= want && index < total - 1) {
                y += next
                index++
                next = KayaPresent.rowExtent(node.id, index.toLong())
            }
        }
        return Pair(index.coerceIn(0, total - 1), (viewportPx / pitch).toInt().coerceAtLeast(1))
    }

    /**
     * A TABLE JUST LAID OUT SHOWS ITS FIRST COLUMN: either half of the
     * columns' box moving resets the offset, while a recomposition that
     * moved neither keeps the reader's scroll. Without it `expect_at_end`
     * passes before anything scrolled (docs/deferred.md). ON THE
     * MAIN-LOOPER HOP AND NEVER FROM MEASURE, [report]'s own rule.
     */
    private fun settleColumns() {
        if (hContentPx != lastHContent || hTrackPx != lastHTrack) {
            lastHContent = hContentPx
            lastHTrack = hTrackPx
            node.tableScrollX = 0f
        } else {
            node.tableScrollX = node.tableScrollX.coerceIn(0f, node.tableReachX)
        }
    }

    fun report() {
        settleColumns()
        if (viewportPx <= 0) return
        // PUBLISHED BEFORE ANY EARLY RETURN. The park below waits for
        // the band it just asked for, and the band only ever arrives
        // through these four numbers: publishing them last deadlocked
        // the wait against itself (measured — scroll_to_row r200 sat at
        // "0 400" until the step's deadline, the layout never learning
        // the band the core had already moved).
        publish()
        val scroll = node.scrollState.value
        if (anchorRow >= 0) {
            if (anchorScroll >= 0 && scroll != anchorScroll) {
                // A scroll this tier did not issue: the reader owns free
                // scrolling, and the park yields to it.
                anchorRow = -1
            } else {
                val want = contentTopOf(anchorRow)
                // NOTHING IS REPORTED WHILE A PARK IS OUTSTANDING. The
                // parked row may not be laid out yet — [park] moved the
                // band and its stamps are still in flight — and the
                // range this viewport shows meanwhile is the one the
                // park is leaving, so reporting it would send the band
                // straight back where it came from (measured: scroll to
                // r200 landed on "0 400" every time).
                if (want < 0) return
                if (want != scroll) {
                    val state = node.scrollState
                    scope.launch {
                        state.scrollTo(want)
                        anchorScroll = state.value
                        // A scroll clamped at the collection's end
                        // cannot honour the park, and re-trying it is a
                        // live loop; the park yields (§5's unasserted
                        // end-scroll).
                        if (state.value != want) anchorRow = -1
                        schedule()
                    }
                    return
                }
            }
        }
        val (first, count) = visibleRange(scroll)
        if (first != lastFirst || count != lastCount) {
            lastFirst = first
            lastCount = count
            KayaPresent.windowMoved(node.id, first.toLong(), count.toLong())
        }
        val extents = rowExtents
        if (extents.isNotEmpty()) {
            val heights = DoubleArray(extents.size)
            var moved = false
            for (at in extents.indices) {
                heights[at] = extents[at].toDouble()
                if (KayaPresent.rowExtent(node.id, (laidOutFirst + at).toLong()) != heights[at]) {
                    moved = true
                }
            }
            if (moved) KayaPresent.rowsMeasured(node.id, laidOutFirst.toLong(), heights)
        }
        publish()
    }

    /** The core's answer, into the four snapshot fields the composition
     *  cuts its spacers from. */
    private fun publish() {
        KayaPresent.windowGeometry(node.id, slots)
        bandStart = slots[KayaPresent.GEOMETRY_FIRST].toInt()
        bandCount = slots[KayaPresent.GEOMETRY_COUNT].toInt()
        offsetPx = slots[KayaPresent.GEOMETRY_OFFSET]
        extentPx = slots[KayaPresent.GEOMETRY_EXTENT]
    }

    /** What expect_window compares: the first VISIBLE row and the
     *  DECLARED total. The band's width is a viewport metric and left the
     *  verb (ruled 2026-08-25). */
    fun firstVisible(children: Int): Pair<Int, Int> {
        KayaPresent.windowGeometry(node.id, slots)
        val total = slots[KayaPresent.GEOMETRY_TOTAL].toInt()
        if (total <= 0) return Pair(0, children)
        return Pair(visibleRange(node.scrollState.value).first, total)
    }
}

/**
 * The declared table's surface (docs/tables-plan.md): a synthesized
 * header over CONTENT-SIZED columns sharing widths found in one measure
 * pass, which expect_column_edges reads back. Headers render at EVERY
 * width, a header tap is a REQUEST, and this is THE WINDOWED TIER
 * (docs/virtualization-plan.md §4, §7). The segmented grouped container
 * below takes androidx's own corner numbers (docs/deferred.md).
 */
private val KAYA_TABLE_SEGMENT_OUTER = 16.dp
private val KAYA_TABLE_SEGMENT_INNER = 4.dp
private val KAYA_TABLE_SEGMENT_GAP = 2.dp

/**
 * THE FOLD SEAM (docs/adaptive-layout-plan.md D7): the gap between the
 * last folded child and the table's own grammar. A SECTION gap, not the
 * 2dp segment gap — the folded summary and the ledger are two grouped
 * surfaces, and at the segment gap they read as one (the maintainer's
 * 2026-08-30 read of the phone captures). One number, four backends.
 */
private val KAYA_FOLD_SEAM_GAP = 16.dp
private val KAYA_TABLE_HEADER_SEGMENT_SHAPE = RoundedCornerShape(
    topStart = KAYA_TABLE_SEGMENT_OUTER,
    topEnd = KAYA_TABLE_SEGMENT_OUTER,
    bottomStart = KAYA_TABLE_SEGMENT_INNER,
    bottomEnd = KAYA_TABLE_SEGMENT_INNER,
)
private val KAYA_TABLE_BODY_SEGMENT_SHAPE = RoundedCornerShape(
    topStart = KAYA_TABLE_SEGMENT_INNER,
    topEnd = KAYA_TABLE_SEGMENT_INNER,
    bottomStart = KAYA_TABLE_SEGMENT_OUTER,
    bottomEnd = KAYA_TABLE_SEGMENT_OUTER,
)

/**
 * ONE SEGMENT'S interior. 16 dp horizontal is Material's own content
 * inset; 8 dp vertical is the apron, and NOT a row metric — it is the
 * segment's padding and no row's.
 */
private val KAYA_TABLE_CARD_PAD_X = 16.dp
private val KAYA_TABLE_CARD_PAD_Y = 8.dp

/**
 * ONE SEGMENT'S FILL: filled, borderless, elevation 0. The grouped idiom
 * draws no stroke anywhere — tools/check-table-card.py refuses one here.
 */
@Composable
private fun KayaTableSegment(shape: RoundedCornerShape) {
    Box(Modifier.background(MaterialTheme.colorScheme.surfaceContainer, shape))
}

/**
 * THE CELLS' BOX INSIDE THE SCROLL CLIP (swift/KayaSwiftUI.swift's
 * `kayaTableCellsBox` in this backend's spelling): the segments and their
 * interior are CONTENT, so the clip is [interior] wider on each side than
 * the box the cells lay out in. Reported raw, every table starts
 * [interior] inside its own viewport at expect_column_edges.
 */
internal fun kayaTableCellsBox(clipLeft: Float, clipWidth: Float, interior: Float):
    Pair<Float, Float> = Pair(clipLeft + interior, clipLeft + clipWidth - interior)

@Composable
private fun KayaTableSurface(node: KayaNode, modifier: Modifier) {
    // The presented record expect_columns reads — written by THIS path,
    // so the observation proves the header rendered, never that the
    // wire arrived.
    val presented = buildString {
        append(node.tableColumns.joinToString("|"))
        if (node.tableSorted >= 0) {
            append(if (node.tableDirection == 0) " ^" else " v")
            append(node.tableSorted)
        }
    }
    SideEffect { node.tablePresented = presented }
    val window = remember(node.id) { KayaTableWindow(node) }
    DisposableEffect(window) {
        kayaTableWindows[node.id] = window
        onDispose { if (kayaTableWindows[node.id] === window) kayaTableWindows.remove(node.id) }
    }
    // A scroll moves nothing this composition reads, so nothing else
    // here would notice one.
    LaunchedEffect(window) {
        snapshotFlow { node.scrollState.value }.collect { window.schedule() }
    }
    // THE CORE'S ARITHMETIC, and the composition's dependency on it: a
    // correction moves these without moving `children`, and the spacers
    // below are cut from them.
    val bandFirst = window.bandStart
    val offsetPx = window.offsetPx
    val extentPx = window.extentPx
    // EVERY REALIZED ROW, no cap of this tier's own: the core seeds a
    // declared table's band at a screenful before any layout can report
    // one (docs/deferred.md, the declares-windowing entry), so
    // `children` is a band's worth from the first frame.
    val rows = node.children
    // THE FOLD (D7): a stacked row's hugging children render inside this
    // viewport, above row 0, and scroll away with the rows — this
    // backend cannot nest a second vertical scrollable, so they join the
    // table's own Layout rather than wrapping it. One snapshot, so the
    // content and measure lambdas agree on the count.
    val folded = node.foldedChildren.toList()
    val cols = node.tableColumns.size
    val geometryGeneration = "${node.tableGeometryGeneration}:"
    val density = LocalDensity.current.density
    val colGapPx = with(LocalDensity.current) { 24.dp.roundToPx() }
    val rowGapPx = with(LocalDensity.current) { node.spacing.dp.roundToPx() }
    fun Modifier.edge(key: String): Modifier = onGloballyPositioned {
        val left = it.positionInWindow().x / density
        node.cellEdgeX[key] = left
        node.cellEdgeRightX[key] = left + it.size.width / density
    }
    Layout(
        content = {
            // FIRST IN THE CONTENT: the folded children, in sibling
            // order; every index below starts past them.
            folded.forEach { KayaRender(it) }
            node.tableColumns.forEachIndexed { index, title ->
                val indicator = when {
                    node.tableSorted != index -> ""
                    node.tableDirection == 0 -> " ▲"
                    else -> " ▼"
                }
                Text(
                    title + indicator,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier
                        .clickable {
                            KayaPresent.emitSortRequested(node.sortTag, index)
                        }
                        .edge("${geometryGeneration}h/$index"),
                )
            }
            Spacer(Modifier)
            rows.forEach { row ->
                row.children.forEachIndexed { index, cell ->
                    Box(Modifier.edge("$geometryGeneration${row.id}/$index")) { KayaRender(cell) }
                }
            }
            Spacer(Modifier)
            // LAST IN THE CONTENT AND FIRST IN THE PLACEMENT: placement
            // order is draw order, so these paint BEHIND every row, and
            // every index in the measure block below counts from the end.
            KayaTableSegment(KAYA_TABLE_HEADER_SEGMENT_SHAPE)
            KayaTableSegment(KAYA_TABLE_BODY_SEGMENT_SHAPE)
        },
        modifier = modifier
            // NOTHING ON THIS CHAIN PAINTS OR PADS. The container is
            // CONTENT (docs/deferred.md's table-card entry; ruled
            // 2026-08-25): a fill here is the scroll VIEWPORT's, which
            // runs to the bottom of the screen under a three-row table
            // and cannot scroll with a tall one.
            .onGloballyPositioned {
                val (left, right) = kayaTableCellsBox(
                    it.positionInWindow().x / density,
                    it.size.width / density,
                    KAYA_TABLE_CARD_PAD_X.value,
                )
                node.tableViewportLeftX = left
                node.tableViewportRightX = right
                node.tableViewportH = it.size.height / density
                kayaContainerExtents[node.id] = it.size.height.toDouble()
                kayaContainerCross[node.id] = it.size.width.toDouble()
                window.viewportPx = it.size.height
                window.schedule()
            }
            // THE COLUMNS' AXIS (docs/tables-plan.md), NOT
            // Modifier.horizontalScroll, which proposes an infinite width
            // the leftover distribution would lose its track to
            // (docs/probes/table-overflow-2026.md §4.2). The clip is this
            // backend's own, since verticalScroll's INFLATES the cross
            // axis. A VIEWPORT ASKED FOR NO BOUND TAKES THE SCREEN, since
            // Compose HARD THROWS on an infinite maximum along its axis.
            .layout { measurable, constraints ->
                val bounded =
                    if (constraints.hasBoundedHeight) constraints
                    else constraints.copy(maxHeight = kayaUnboundedViewportPx)
                if (kayaLayoutTrace) {
                    Log.i("kaya", "KAYA_TRACE table#${node.id} maxH=" +
                        (if (constraints.hasBoundedHeight) "${constraints.maxHeight}"
                         else "INFINITY->${bounded.maxHeight}") +
                        " minW=${constraints.minWidth} maxW=" +
                        (if (constraints.hasBoundedWidth) "${constraints.maxWidth}"
                         else "INFINITY"))
                }
                val placeable = measurable.measure(bounded)
                layout(placeable.width, placeable.height) { placeable.place(0, 0) }
            }
            .clipToBounds()
            .scrollable(
                state = node.tableColumnScroll,
                orientation = Orientation.Horizontal,
                reverseDirection = ScrollableDefaults.reverseDirection(
                    LocalLayoutDirection.current, Orientation.Horizontal, false),
            )
            .verticalScroll(node.scrollState),
    ) { measurables, constraints ->
        // Children arrive in content order: cols headers, the top spacer,
        // the realized band's cells row-major (the core held every row to
        // the declared arity, so the % below cannot skew), the bottom
        // spacer, then the two segment fills. NO HEADER RULE — the 2dp gap
        // between the segments IS the separator in the grouped idiom
        // (ruled 2026-08-26; tools/check-table-card.py pins its absence).
        val padX = KAYA_TABLE_CARD_PAD_X.roundToPx()
        val padY = KAYA_TABLE_CARD_PAD_Y.roundToPx()
        val gap = KAYA_TABLE_SEGMENT_GAP.roundToPx()
        // The folded children lead the content (D7), so every positional
        // index shifts past them; the segments keep counting from the end.
        val nFolded = folded.size
        val headers =
            measurables.subList(nFolded, nFolded + cols).map { it.measure(Constraints()) }
        val cells = measurables.subList(nFolded + cols + 1, measurables.size - 3)
            .map { it.measure(Constraints()) }
        val colWidth = IntArray(cols)
        headers.forEachIndexed { c, p -> colWidth[c] = maxOf(colWidth[c], p.width) }
        cells.forEachIndexed { i, p ->
            colWidth[i % cols] = maxOf(colWidth[i % cols], p.width)
        }
        // A table spans its viewport: content width is each column's
        // FLOOR, and leftover track width is distributed across the
        // columns — the native macOS Table's resting look, stated as a
        // rule (docs/tables-plan.md decision 6; the span half of
        // expect_column_edges holds it). The leftover is measured in the
        // SEGMENT'S INTERIOR, which is the box the cells lay out in.
        if (constraints.hasBoundedWidth) {
            val leftover =
                constraints.maxWidth - 2 * padX - colWidth.sum() - colGapPx * (cols - 1)
            if (leftover > 0) {
                val per = leftover / cols
                val rem = leftover % cols
                for (c in 0 until cols) colWidth[c] += per + if (c < rem) 1 else 0
            }
        }
        // The columns' RESTING lefts. `colX` below is these shifted by
        // the live offset, and it is built in the PLACEMENT block so a
        // scroll re-places without re-measuring.
        val colLeft = IntArray(cols)
        var acc = 0
        for (c in 0 until cols) {
            colLeft[c] = acc
            acc += colWidth[c] + if (c < cols - 1) colGapPx else 0
        }
        // A REPRESENTABLE CONSTRAINT OR NOTHING: Compose packs width and
        // height into one long, so a giant height beside a tiny width is
        // an IllegalArgumentException. A zero-width track made the
        // windowed spacers tower past the packing and this measure THREW
        // during first composition. fitPrioritizingWidth clamps only past
        // the packing's edge, where nothing is visible anyway.
        fun kayaFixedRepresentable(w: Int, h: Int) =
            Constraints.fitPrioritizingWidth(w, w, h.coerceAtLeast(0), h.coerceAtLeast(0))
        val totalW = (acc + 2 * padX).coerceIn(constraints.minWidth, constraints.maxWidth)
        val innerW = (totalW - 2 * padX).coerceAtLeast(0)
        // THE CARD'S OWN SPAN COMES OFF THE TRACK: the segments span the
        // outer box and the cells the interior, so a raw track convicts
        // every carded table of a 32dp underfill. THE REPUBLISH
        // SUBSCRIPTION: reading the generation inside measure subscribes
        // this layout to it, so APPLY_SET_COLUMNS' clear re-runs the
        // block even when the box did not move.
        val geometryAt = node.tableGeometryGeneration
        node.tableTrackW =
            if (constraints.hasBoundedWidth) (constraints.maxWidth - 2 * padX) / density else -1f
        node.tableDrawnW = innerW / density
        node.tableContentW = acc / density
        node.tableGeometryAt = geometryAt
        // WHAT THE TRACK COULD NOT HOLD IS WHAT THE READER SCROLLS TO
        // (the ruling). Exactly 0 when the columns fit — the leftover
        // above is distributed to the pixel — so no slack is needed on
        // top of it. The two numbers under it are the box the reset
        // watches: a table just laid out shows its first column.
        node.tableReachX = (acc - innerW).coerceAtLeast(0).toFloat()
        node.tableDensity = density
        window.hContentPx = acc
        window.hTrackPx = innerW
        // The folded children measure at the table's own width — bounded,
        // which is what makes their labels wrap — and their block sits
        // above the header segment, one segment gap between.
        val foldedPlaceables = folded.indices.map {
            measurables[it].measure(Constraints(minWidth = totalW, maxWidth = totalW))
        }
        val foldedH = foldedPlaceables.sumOf { it.height }
        val foldedBlock =
            if (foldedH > 0) foldedH + KAYA_FOLD_SEAM_GAP.roundToPx() else 0
        val headerH = headers.maxOfOrNull { it.height } ?: 0
        // A ROW'S EXTENT IS ITS TOP-TO-TOP REPEAT DISTANCE, spacing
        // included (§2.1): a sum of these IS where the next row starts,
        // so the core's prefix sums and this placement are ONE
        // arithmetic. Uniform rows therefore never leave the exact path.
        val rowHeights = cells.chunked(cols).map { row -> row.maxOfOrNull { it.height } ?: 0 }
        val rowExtents = IntArray(rowHeights.size) { rowHeights[it] + rowGapPx }
        val bandH = rowExtents.sum()
        // The trailing gap the last row of the COLLECTION does not draw:
        // the extent counts one per row, the layout draws one BETWEEN
        // them, and taking it off the bottom keeps a table that fits its
        // viewport exactly as tall as it was before it could scroll.
        val tail = if (rowExtents.isEmpty()) 0 else rowGapPx
        val spacers = kayaWindowSpacers(offsetPx, extentPx, bandH, tail)
        val topH = spacers.first
        val top =
            measurables[nFolded + cols].measure(kayaFixedRepresentable(totalW, spacers.first))
        val bottom = measurables[measurables.size - 3]
            .measure(kayaFixedRepresentable(totalW, spacers.second))
        // TWO SEGMENTS: the header row is its own container, then the gap,
        // then ONE container for every body row. The interior is inside
        // each, which is the whole of why the reported viewport is the
        // cells' box and not this clip. The folded block shifts the whole
        // grammar down; rowsTop carries it into the band arithmetic, which
        // is why the window's own code never changes.
        val headerSegH = padY + headerH + padY
        val bodyTop = foldedBlock + headerSegH + gap
        val rowsTop = bodyTop + padY
        val contentH = rowsTop + topH + bandH - tail + spacers.second + padY
        val totalH = contentH.coerceIn(constraints.minHeight, constraints.maxHeight)
        node.tableContentH = contentH / density
        // SIZED TO THE WHOLE EXTENT, spacers included: a short table's
        // container ends at its last row and a tall one's scrolls with the
        // rows, ONE rounded rectangle each rather than one per band.
        val headerSeg = measurables[measurables.size - 2]
            .measure(kayaFixedRepresentable(totalW, headerSegH))
        val bodySeg = measurables[measurables.size - 1]
            .measure(kayaFixedRepresentable(totalW, contentH - bodyTop))
        val tops = IntArray(rowExtents.size)
        var y = topH
        for (r in rowExtents.indices) {
            tops[r] = y
            y += rowExtents[r]
        }
        window.rowsTopPx = rowsTop
        window.laidOutFirst = bandFirst
        window.rowExtents = rowExtents
        window.rowTops = tops
        window.schedule()
        layout(totalW, totalH) {
            // THE HEADER IS LOCKED TO THE BODY because ONE offset moves
            // both — the two `colX` reads below are the same array. THE
            // CARD STAYS WITH THE VIEWPORT: sliding the segments off
            // would run the rows over bare ground while the boundary sat
            // somewhere the reader cannot see.
            val colX = IntArray(cols) { colLeft[it] - Math.round(node.tableScrollX) }
            headerSeg.place(0, foldedBlock)
            bodySeg.place(0, bodyTop)
            // The folded children, above everything, at the content's
            // top — they scroll away exactly as a row does.
            var foldedY = 0
            foldedPlaceables.forEach { p ->
                p.place(0, foldedY)
                foldedY += p.height
            }
            headers.forEachIndexed { c, p -> p.place(padX + colX[c], foldedBlock + padY) }
            top.place(0, rowsTop)
            cells.chunked(cols).forEachIndexed { r, row ->
                row.forEachIndexed { c, p -> p.place(padX + colX[c], rowsTop + tops[r]) }
            }
            bottom.place(0, rowsTop + topH + bandH - tail)
        }
    }
}

/**
 * THE TWO SPACERS, from the CORE'S ARITHMETIC AND NOTHING ELSE
 * (docs/virtualization-plan.md §4). ITS OWN FUNCTION BECAUSE NO SCENE
 * CAN SEE IT — with both spacers zeroed the windowed scene stays green
 * (measured 2026-08-25), so tools/check-verbs.py holds the call site
 * with that perturbation as its self-test.
 */
internal fun kayaWindowSpacers(offset: Double, extent: Double, band: Int, tail: Int):
    Pair<Int, Int> {
    val top = Math.round(offset).toInt().coerceAtLeast(0)
    val bottom =
        (Math.round(extent - offset).toInt().coerceAtLeast(band) - band - tail)
            .coerceAtLeast(0)
    return Pair(top, bottom)
}

/**
 * The ClipData a declared payload travels on. THE DESCRIPTION IS THE
 * OFFER every destination reads (docs/dnd-plan.md D1) — a custom id is a
 * mime type verbatim, and the bytes behind image and custom ride the
 * session instead, since a same-app ClipData has nowhere to put them
 * that a foreign reader could use anyway (D9).
 */
private fun kayaDragClipData(payload: KayaDragPayload): ClipData {
    val mimes = ArrayList<String>()
    payload.custom.forEach { mimes.add(it.first) }
    if (payload.files.isNotEmpty()) mimes.add(ClipDescription.MIMETYPE_TEXT_URILIST)
    if (payload.image != null) mimes.add("image/png")
    if (payload.html != null) mimes.add(ClipDescription.MIMETYPE_TEXT_HTML)
    if (payload.text != null || payload.files.isNotEmpty()) {
        mimes.add(ClipDescription.MIMETYPE_TEXT_PLAIN)
    }
    // ClipDescription refuses an empty mime array, and a payload of
    // custom bytes alone is a legal declaration.
    if (mimes.isEmpty()) mimes.add(ClipDescription.MIMETYPE_TEXT_PLAIN)
    // A file list's text rendition is DERIVED HERE, only when the clip
    // offers none — kayaCopyToClipboard's rule, one surface over.
    val text = payload.text ?: payload.files.joinToString("\n")
    val clip = ClipData(
        ClipDescription("kaya", mimes.toTypedArray()),
        ClipData.Item(
            text, payload.html, null,
            payload.files.firstOrNull()?.let { Uri.parse(it) }),
    )
    payload.files.drop(1).forEach { clip.addItem(ClipData.Item(Uri.parse(it))) }
    return clip
}

/**
 * What a drag offers, in kaya's vocabulary: the closed kinds as a mask
 * and the custom ids among [accepted] the description carries. A FOREIGN
 * DRAG OFFERS NEITHER IMAGE NOR CUSTOM — their bytes live in this
 * process's own session and nowhere the platform would hand over — so
 * they are NOT ON OFFER rather than offered and empty (D9).
 */
private fun kayaDragOffer(
    event: DragAndDropEvent,
    accepted: List<String>,
    local: Boolean,
): Pair<Int, List<String>> {
    val description = event.toAndroidDragEvent().clipDescription
        ?: return Pair(0, emptyList())
    var mask = 0
    if (description.hasMimeType(ClipDescription.MIMETYPE_TEXT_PLAIN)) {
        mask = mask or KayaCompose.CLIP_TEXT
    }
    if (description.hasMimeType(ClipDescription.MIMETYPE_TEXT_HTML)) {
        mask = mask or KayaCompose.CLIP_HTML
    }
    if (description.hasMimeType(ClipDescription.MIMETYPE_TEXT_URILIST)) {
        mask = mask or KayaCompose.CLIP_FILES
    }
    if (local && description.hasMimeType("image/png")) {
        mask = mask or KayaCompose.CLIP_IMAGE
    }
    if (!local) return Pair(mask, emptyList())
    return Pair(mask, accepted.filter { description.hasMimeType(it) })
}

/**
 * The hover and drop verdict for one node — THE CORE'S ONE PURE
 * FUNCTION and nothing this file decides (docs/dnd-plan.md D2). A row of
 * a reorderable For answers its own question first: a local row of the
 * SAME container is a move, anything else is nothing (D8).
 */
private fun kayaDropVerdict(
    node: KayaNode,
    reorderIn: KayaNode?,
    event: DragAndDropEvent,
): Int {
    val drag = event.toAndroidDragEvent()
    val session = drag.localState as? KayaDragSession
    val description = drag.clipDescription
    if (reorderIn != null && description?.hasMimeType(KayaCompose.ROW_DRAG_TYPE) == true) {
        if (session == null || session.rowOf != reorderIn.id) return KayaCompose.DRAG_OP_NONE
        return if (KayaCompose.tableStamp(node.tag) == null) {
            KayaCompose.DRAG_OP_NONE
        } else {
            KayaCompose.DRAG_OP_MOVE
        }
    }
    if (node.dropOps == 0) return KayaCompose.DRAG_OP_NONE
    val (_, custom) = kayaParseAcceptList(node.accepts)
    val (offered, offeredCustom) = kayaDragOffer(event, custom, session != null)
    return KayaPresent.dragVerdict(
        node.accepts, node.dropOps, offered, offeredCustom.joinToString(" "),
        session?.ops ?: 0, session != null)
}

/**
 * The representation a drop delivers, richest accepted first — the
 * accept list's own order for custom ids, then files, image, html, text
 * (kayaMaterializeClipboard's walk, over the drag instead of the board).
 * A LOCAL drag is read off the SOURCE'S OWN DECLARATION, which is where
 * the bytes are; a foreign one off the ClipData, which is all there is.
 */
private fun kayaReadDropValue(
    accepting: String,
    drag: android.view.DragEvent,
): KayaClipValue? {
    val (kinds, custom) = kayaParseAcceptList(accepting)
    val payload = (drag.localState as? KayaDragSession)?.payload
    if (payload != null) {
        for (id in custom) {
            payload.custom.firstOrNull { it.first == id }?.let {
                return KayaClipValue(KayaCompose.CLIP_CUSTOM, text = it.first, bytes = it.second)
            }
        }
        if (kinds and KayaCompose.CLIP_FILES != 0 && payload.files.isNotEmpty()) {
            return KayaClipValue(
                KayaCompose.CLIP_FILES,
                locators = payload.files.toTypedArray(),
                names = payload.files
                    .map { Uri.parse(it).lastPathSegment ?: it }
                    .toTypedArray())
        }
        if (kinds and KayaCompose.CLIP_IMAGE != 0 && payload.image != null) {
            return KayaClipValue(KayaCompose.CLIP_IMAGE, bytes = payload.image)
        }
        if (kinds and KayaCompose.CLIP_HTML != 0 && payload.html != null) {
            return KayaClipValue(KayaCompose.CLIP_HTML, text = payload.html)
        }
        if (kinds and KayaCompose.CLIP_TEXT != 0 && payload.text != null) {
            return KayaClipValue(KayaCompose.CLIP_TEXT, text = payload.text)
        }
        return null
    }
    val clip = drag.clipData ?: return null
    val items = (0 until clip.itemCount).map { clip.getItemAt(it) }
    if (kinds and KayaCompose.CLIP_FILES != 0) {
        val locators = items.mapNotNull { it.uri?.toString() }
        if (locators.isNotEmpty()) {
            return KayaClipValue(
                KayaCompose.CLIP_FILES,
                locators = locators.toTypedArray(),
                names = locators
                    .map { Uri.parse(it).lastPathSegment ?: it }
                    .toTypedArray())
        }
    }
    if (kinds and KayaCompose.CLIP_HTML != 0) {
        items.firstNotNullOfOrNull { it.htmlText }?.let {
            return KayaClipValue(KayaCompose.CLIP_HTML, text = it)
        }
    }
    if (kinds and KayaCompose.CLIP_TEXT != 0) {
        val plain = items.firstOrNull()?.text?.toString()
        if (!plain.isNullOrEmpty()) return KayaClipValue(KayaCompose.CLIP_TEXT, text = plain)
    }
    return null
}

/**
 * Take the drop, or refuse it. The point rides in the DESTINATION'S OWN
 * top-left space, in DP — the logical unit every other kaya coordinate
 * on this backend is in — and a reorder's before bit is the pointer in
 * the landed row's upper half (docs/dnd-plan.md D8).
 */
private fun kayaPerformDrop(
    node: KayaNode,
    reorderIn: KayaNode?,
    event: DragAndDropEvent,
): Boolean {
    val operation = kayaDropVerdict(node, reorderIn, event)
    if (operation == KayaCompose.DRAG_OP_NONE) return false
    val drag = event.toAndroidDragEvent()
    val session = drag.localState as? KayaDragSession
    val box = kayaDragBoxes[node.id]
    val density = if (kayaDensity > 0.0) kayaDensity else 1.0
    val localX = (drag.x - (box?.rootLeft ?: 0f)) / density
    val localY = (drag.y - (box?.rootTop ?: 0f)) / density
    session?.operation = operation
    session?.let { it.dropped += 1 }
    if (reorderIn != null && session != null &&
        drag.clipDescription?.hasMimeType(KayaCompose.ROW_DRAG_TYPE) == true
    ) {
        val moved = session.payload.custom
            .firstOrNull { it.first == KayaCompose.ROW_DRAG_TYPE }
            ?: return false
        val before = (drag.y - (box?.rootTop ?: 0f)) < (box?.height ?: 0f) / 2f
        // THE LANDING'S IDENTITY IS THE CONTAINER, the moved key rides in
        // the clip and the landed row's own tag is the anchor (D8).
        KayaPresent.emitDropped(
            reorderIn.identityTag, localX, localY, KayaCompose.DRAG_OP_MOVE,
            node.identityTag, before, KayaCompose.CLIP_CUSTOM, moved.first,
            moved.second, emptyArray(), emptyArray())
        return true
    }
    val value = kayaReadDropValue(node.accepts, drag) ?: return false
    KayaPresent.emitDropped(
        node.identityTag, localX, localY, operation, ByteArray(0), false,
        value.clip, value.text, value.bytes, value.locators, value.names)
    return true
}

/**
 * THE DRAG-AND-DROP SURFACE behind a node that declares a payload, an
 * operation mask, or is a row of a reorderable For — null for every
 * other node, so a scene that declares nothing composes exactly as it
 * did. The mac arm's KayaMacDragDropSurface, in Compose's own two
 * modifiers (docs/dnd-plan.md D1, D8).
 *
 * A SOURCE IS ALSO A TARGET, deliberately: `onEnded` reaches only the
 * nodes whose `shouldStartDragAndDrop` accepted the transfer, and the
 * source is where `drag_ended` has to be emitted from.
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun kayaDragAndDropSurface(node: KayaNode): Modifier? {
    val reorderIn = node.reorderIn
    val payload = node.dragPayload
    if (payload == null && node.dropOps == 0 && reorderIn == null) return null
    val target = remember(node, reorderIn) {
        object : DragAndDropTarget {
            override fun onStarted(event: DragAndDropEvent) {
                (event.toAndroidDragEvent().localState as? KayaDragSession)
                    ?.let { if (it.sourceId == node.id) it.started += 1 }
            }

            override fun onEntered(event: DragAndDropEvent) {
                (event.toAndroidDragEvent().localState as? KayaDragSession)
                    ?.let { it.entered += 1 }
                val e = event.toAndroidDragEvent()
                // The android drag WATCH's instrument (docs/deferred.md): where the
                // platform says the pointer is, per target, so a drag that ends
                // "none" under a matrix names the target it never entered.
                Log.i("kaya", "KAYA_DRAG_EVENT: entered node=${node.id} at=${e.x.toInt()},${e.y.toInt()}")
            }

            override fun onDrop(event: DragAndDropEvent): Boolean {
                val e = event.toAndroidDragEvent()
                val taken = kayaPerformDrop(node, reorderIn, event)
                Log.i("kaya", "KAYA_DRAG_EVENT: drop node=${node.id} at=${e.x.toInt()},${e.y.toInt()} taken=$taken")
                return taken
            }

            override fun onEnded(event: DragAndDropEvent) {
                val session = event.toAndroidDragEvent().localState as? KayaDragSession
                    ?: return
                if (session.sourceId != node.id || session.ended) return
                session.ended = true
                Log.i("kaya", "KAYA_DRAG_EVENT: ended node=${node.id} op=${session.operation} entered=${session.entered}")
                KayaPresent.emitDragEnded(node.identityTag, session.operation)
                kayaDragEndings += 1
            }
        }
    }
    var modifier: Modifier = Modifier.onGloballyPositioned {
        val root = it.boundsInRoot()
        val window = it.boundsInWindow()
        kayaDragBoxes[node.id] = KayaDragBox(
            root.left, root.top, window.left, window.top,
            it.size.width.toFloat(), it.size.height.toFloat())
    }
    if (payload != null || reorderIn != null) {
        // THE PLATFORM'S OWN GESTURE STARTS IT (D8): the default start
        // detector of this overload is a LONG PRESS on touch, which is
        // the phone's affordance and what `input draganddrop` injects.
        modifier = modifier.dragAndDropSource(transferData = {
            val declared = payload ?: KayaDragPayload(
                custom = listOf(
                    Pair(
                        KayaCompose.ROW_DRAG_TYPE,
                        (KayaCompose.tableStamp(node.tag)?.keys ?: emptyList())
                            .joinToString(".").toByteArray(Charsets.UTF_8))))
            val ops = if (payload != null) node.dragOps else KayaCompose.DRAG_OP_MOVE
            val session = KayaDragSession(node.id, declared, ops, reorderIn?.id ?: 0L)
            kayaDragSession = session
            // The gesture took: the runner stops re-injecting on this, so a
            // slow-ending drag under load is not clobbered by a fresh one
            // (docs/traps.md: The android drag re-injection raced a slow end).
            Log.i("kaya", "KAYA_DRAG_STARTED: draganddrop")
            // NO GLOBAL FLAG: a phone drag is same-app (D9).
            DragAndDropTransferData(kayaDragClipData(declared), session, 0)
        })
    }
    return modifier.dragAndDropTarget(
        shouldStartDragAndDrop = { event ->
            // A SOURCE ACCEPTS ITS OWN DRAG (docs/traps.md: A Compose drag
            // source must be a drop target of its own drag): a transfer
            // nobody accepts gets no ACTION_DRAG_ENDED at all, and the
            // source would never learn the answer was `none`.
            val session = event.toAndroidDragEvent().localState as? KayaDragSession
            (session != null && session.sourceId == node.id) ||
                kayaDropVerdict(node, reorderIn, event) != KayaCompose.DRAG_OP_NONE
        },
        target = target,
    )
}

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun KayaRender(
    node: KayaNode,
    isRoot: Boolean = false,
    flexVertical: Boolean? = null,
    flexStretch: Boolean = false,
    flexAlign: Long = KayaCompose.ALIGN_START,
) {
    val dnd = kayaDragAndDropSurface(node)
    if (dnd == null) {
        KayaRenderHelped(node, isRoot, flexVertical, flexStretch, flexAlign)
        return
    }
    Box(modifier = dnd) {
        KayaRenderHelped(node, isRoot, flexVertical, flexStretch, flexAlign)
    }
}

/**
 * HELP, the platform's own tooltip (docs/tooltip-plan.md T1/T2/T4): one
 * wrapper every render arm passes through — a tooltip is a COMPOSABLE and
 * not a modifier, so it cannot ride `a11y` the way the other two universal
 * props do (tools/check-universal-props.py holds both shapes). Material's
 * box brings its own triggers, long press and mouse hover, and kaya adds no
 * gesture of its own; PLAIN only, since T4 refuses titles, actions and
 * images. A node that declares no help never gets the wrapper, the
 * drag-and-drop surface's and the context anchor's rule.
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun KayaRenderHelped(
    node: KayaNode,
    isRoot: Boolean,
    flexVertical: Boolean?,
    flexStretch: Boolean,
    flexAlign: Long,
) {
    if (node.help.isEmpty()) {
        KayaRenderAnchored(node, isRoot, flexVertical, flexStretch, flexAlign)
        return
    }
    TooltipBox(
        positionProvider = TooltipDefaults.rememberPlainTooltipPositionProvider(),
        tooltip = { PlainTooltip { Text(node.help) } },
        state = rememberTooltipState(),
        // MATERIAL'S ANCHOR MERGES ITS DESCENDANTS, so a widget that is no
        // merging root of its own — a plain label — IS the node a reader
        // focuses, and material labels its long press "show tooltip". The
        // label is relabelled here and the action left alone (the action
        // key's merge policy: the outer label, the inner action), so the
        // help is what the reader hears on either node (measured,
        // docs/tooltip-plan.md §6).
        modifier = Modifier.semantics { onLongClick(label = node.help, action = null) },
    ) {
        KayaRenderAnchored(node, isRoot, flexVertical, flexStretch, flexAlign)
    }
}

/** The context catalog's anchor, one wrapper inside the drag-and-drop
 * surface: both are wrappers a node that declares neither never gets. */
@Composable
private fun KayaRenderAnchored(
    node: KayaNode,
    isRoot: Boolean,
    flexVertical: Boolean?,
    flexStretch: Boolean,
    flexAlign: Long,
) {
    val attachment = KayaSceneModel.contextMenus[node.id]
    if (attachment == null) {
        KayaRenderCore(node, isRoot, flexVertical, flexStretch, flexAlign)
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
        KayaRenderCore(node, isRoot, flexVertical, flexStretch, flexAlign)
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

/**
 * A HUGGING CONTAINER PINS ITSELF TO ITS CONTENT before the breadth
 * ruling's fill resolves against it: `fillMaxWidth()` takes the
 * CONSTRAINT a parent handed down where GTK, XAML and SwiftUI mean "as
 * tall as my parent ENDED UP", so under an unpinned parent it claims the
 * window. IntrinsicSize is Compose's own answer.
 */
private fun kayaHugCross(
    node: KayaNode,
    isRoot: Boolean,
    flexVertical: Boolean?,
    flexStretch: Boolean,
): Modifier {
    val crossVertical = node.kind == KayaCompose.KIND_ROW
    if (!crossVertical && node.kind != KayaCompose.KIND_COLUMN) return Modifier
    val pinned =
        isRoot || if (flexVertical == crossVertical) node.grow > 0 else flexStretch
    val crossingKind =
        if (crossVertical) KayaCompose.KIND_COLUMN else KayaCompose.KIND_ROW
    if (pinned || node.children.none { it.kind == crossingKind }) return Modifier
    return if (crossVertical) {
        Modifier.height(IntrinsicSize.Min)
    } else {
        Modifier.width(IntrinsicSize.Max)
    }
}


@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun KayaRenderCore(
    node: KayaNode,
    isRoot: Boolean = false,
    /**
     * The MAIN AXIS of the flex container this node is a child of — true
     * inside a column, false inside a row, null where grow has no
     * meaning. A grower fills only that axis; filling both would take the
     * cross axis, which is align's business.
     */
    flexVertical: Boolean? = null,
    /**
     * Whether that container aligns its children `stretch` — the CROSS
     * axis's half of what [flexVertical] answers for the main one. A
     * fixed-size control needs it, and so does a NESTED CONTAINER: both
     * hug a box they were handed unless told (docs/deferred.md's
     * nested-container GAP).
     */
    flexStretch: Boolean = false,
    /**
     * That container's align MODE, for the one kind whose cross-axis
     * default is not the container's: a scroll spans under start and
     * stretch (ruled 2026-09-02) and is positioned by center and end.
     */
    flexAlign: Long = KayaCompose.ALIGN_START,
) {
    // The mounted root fills its window — the same normalization GTK
    // and UIKit needed. A Compose Column wraps its width even when
    // weighted children have forced its height, so the grow scene's
    // 25/75 held over a content-wide strip while every other backend
    // spanned the window.
    val rootFill = if (isRoot) Modifier.fillMaxSize() else Modifier
    // AND EVERY NODE ADOPTS THE BOX IT WAS HANDED (docs/deferred.md,
    // tools/scenes/align.steps): a grower spans its track on the parent's
    // MAIN axis, `stretch` the cross axis, and with neither it hugs. This
    // is the CONTENT inside the cell, LEAF AND CONTAINER ALIKE — a grown
    // label drew 23 of its 109pt track on the backend told only about
    // containers. A CROSSING CONTAINER joins the stretch arm.
    var boxFill = rootFill
    if (flexVertical != null) {
        val crossing =
            if (flexVertical) node.kind == KayaCompose.KIND_ROW
            else node.kind == KayaCompose.KIND_COLUMN
        if (node.grow > 0) {
            boxFill =
                if (flexVertical) boxFill.fillMaxHeight() else boxFill.fillMaxWidth()
        }
        // A SCROLL SPANS ITS PARENT'S CROSS AXIS under the default mode and
        // under stretch (ruled 2026-09-02): a viewport is a region, not
        // content — hugging left a 79pt pannable strip in a 375pt window
        // on iOS (docs/traps.md). Center and end still position a hugging
        // one; the scene's expect_breadth holds this on every lane.
        val scrollSpans = node.kind == KayaCompose.KIND_SCROLL &&
            (flexAlign == KayaCompose.ALIGN_START || flexAlign == KayaCompose.ALIGN_STRETCH)
        if (flexStretch || crossing || scrollSpans) {
            boxFill =
                if (flexVertical) boxFill.fillMaxWidth() else boxFill.fillMaxHeight()
        }
    }
    val hugCross = kayaHugCross(node, isRoot, flexVertical, flexStretch)
    // THE UNIVERSAL ACCESSIBILITY PROPS. a11y_id is a plain testTag,
    // Android having no accessibility-identifier property. EMPTY STAYS
    // UNSET, or the control's own derived description is silenced. The
    // two halves are separately named because Image publishes Role.Image
    // only when the name rides its own contentDescription PARAMETER
    // (measured 2026-07-25: through the modifier it read `unknown/Logo`).
    val a11yTag = if (node.a11yId.isNotEmpty()) Modifier.testTag(node.a11yId) else Modifier
    val a11yName =
        if (node.a11yLabel.isNotEmpty()) {
            Modifier.semantics { contentDescription = node.a11yLabel }
        } else {
            Modifier
        }
    // THE HINT rides the CLICK ACTION'S LABEL, Android's author-supplied
    // hint: layering a label-only semantics node relabels the action and
    // KEEPS it, because the OnClick key's merge policy takes the parent's
    // label and the child's action (measured 2026-07-25). `action = null`
    // says "I am only naming what the control already does". Nothing else
    // on Android carries a hint, which is why the root scopes this prop
    // to activation kinds.
    val a11yHint =
        if (node.a11yHint.isNotEmpty()) {
            Modifier.semantics { onClick(label = node.a11yHint, action = null) }
        } else {
            Modifier
        }
    // HELP REACHES THE READER through the LONG-PRESS ACTION'S LABEL, the
    // hint's mechanism one key over: Compose publishes no tooltip text to
    // AccessibilityNodeInfo at all (measured, docs/tooltip-plan.md §6), and
    // material3's own anchor labels that action "show tooltip" on a node no
    // service focuses. The label rides the FOCUSED node here, and
    // `action = null` names what the long press already does.
    val a11yHelp =
        if (node.help.isNotEmpty()) {
            Modifier.semantics { onLongClick(label = node.help, action = null) }
        } else {
            Modifier
        }
    val a11y = a11yTag.then(a11yName).then(a11yHint).then(a11yHelp)
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
                    // The fill rides the FIELD, not the anchor box: a box
                    // that spans while its control hugs is the false green
                    // kayaDrawnExtents exists to catch.
                    modifier = boxFill.then(a11y).menuAnchor(),
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
                modifier = boxFill.then(a11y).onGloballyPositioned {
                    kayaInsetOuter[node.id] =
                        Pair(it.size.width.toDouble(), it.size.height.toDouble())
                }.padding(node.inset.dp).onGloballyPositioned {
                    kayaInsetInner[node.id] =
                        Pair(it.size.width.toDouble(), it.size.height.toDouble())
                },
            ) { measurables, constraints ->
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
                // Coerced into the incoming constraints, so a GROWN grid
                // takes the track the fill above fixed for it — a Layout
                // that reports its own size regardless would leave the
                // fill dead (the 2026-08-22 ruling: a grower renders at
                // its track, leaf or container). Cells still place from
                // the leading edge, so the extra is trailing slack.
                val width = (colW.sum() + gapPx * (cols - 1).coerceAtLeast(0))
                    .coerceAtLeast(constraints.minWidth)
                val height = (rowH.sum() + gapPx * (rows - 1).coerceAtLeast(0))
                    .coerceAtLeast(constraints.minHeight)
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
            Column(modifier = boxFill.then(a11y).selectableGroup()) {
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
                androidx.compose.material3.LinearProgressIndicator(
                    modifier = boxFill.then(a11y))
            } else {
                androidx.compose.material3.LinearProgressIndicator(
                    modifier = boxFill.then(a11y),
                    progress = { node.value.toFloat() })
            }
        KayaCompose.KIND_SCROLL ->
            // The vertical scroll viewport over its ONE child (the
            // scene enforces the count): verticalScroll over the
            // node's own ScrollState — the toolkit's real scrolling
            // machinery, which the runner's verbs read and drive.
            Box(
                boxFill.then(a11y).verticalScroll(node.scrollState)
            ) {
                node.children.firstOrNull()?.let { KayaRender(it) }
            }
        KayaCompose.KIND_COLUMN, KayaCompose.KIND_ROW -> {
            // ONE NODE, TWO CONSTRUCTOR SPELLINGS (docs/adaptive-layout-plan.md
            // D1): the kind names the INITIAL axis and the harness's
            // address; the axis prop, when set, is the arrangement truth.
            // Normalized default: children packed to the start at natural
            // size, cross-axis start, 8 dp between them. A vertical
            // container with a declared header bar takes the TABLE surface
            // instead (docs/tables-plan.md).
            val kayaVertical =
                (node.axis ?: if (node.kind == KayaCompose.KIND_COLUMN) 1L else 0L) == 1L
            if (kayaVertical && node.tableColumns.isNotEmpty()) {
                KayaTableSurface(node, boxFill.then(a11y))
            } else if (kayaVertical) Column(
                // The inset pair brackets the container's own padding:
                // outer box, then padding, then the content readers, so
                // the extents shares divide are the CONTENT box.
                modifier = boxFill.then(hugCross).then(a11y).onGloballyPositioned {
                    kayaInsetOuter[node.id] =
                        Pair(it.size.width.toDouble(), it.size.height.toDouble())
                }.padding(node.inset.dp).onGloballyPositioned {
                    kayaInsetInner[node.id] =
                        Pair(it.size.width.toDouble(), it.size.height.toDouble())
                    kayaContainerExtents[node.id] = it.size.height.toDouble()
                    kayaContainerCross[node.id] = it.size.width.toDouble()
                    kayaContainerAxis[node.id] = true
                },
                verticalArrangement = Arrangement.spacedBy(node.spacing.dp),
                horizontalAlignment = when (node.align) {
                    KayaCompose.ALIGN_CENTER -> Alignment.CenterHorizontally
                    KayaCompose.ALIGN_END -> Alignment.End
                    else -> Alignment.Start
                },
            ) {
                node.laidOut.forEach { child ->
                    // Every child rides in a cell, grown or not: the
                    // cell carries Modifier.weight (Compose's own
                    // per-child weight, so the contract needs no
                    // arithmetic here) and it is the track whose
                    // measured height expect_shares reads.
                    var cell = Modifier.onGloballyPositioned {
                        kayaMainExtents[child.id] = it.size.height.toDouble()
                        kayaCrossRects[child.id] = Pair(
                            it.positionInParent().x.toDouble(),
                            it.size.width.toDouble(),
                        )
                    }
                    if (child.grow > 0) cell = cell.weight(child.grow.toFloat())
                    // The track a crossing ROW spans is the whole breadth,
                    // under every align mode (the 2026-08-22 breadth
                    // ruling) — beside stretch, which spans every child's.
                    if (node.align == KayaCompose.ALIGN_STRETCH ||
                        child.kind == KayaCompose.KIND_ROW
                    ) {
                        cell = cell.fillMaxWidth()
                    }
                    // BOTH READERS: the one inside the cell sees what
                    // the child drew, the one on the cell sees the
                    // track. Without both, expect_fills on a widget
                    // cannot tell a control that filled its cell from
                    // one that ignored it.
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
                                flexAlign = node.align,
                            )
                        }
                    }
                }
            }
            else Row(
                // The inset pair brackets the padding (see the column's
                // note).
                modifier = boxFill.then(hugCross).then(a11y).onGloballyPositioned {
                    kayaInsetOuter[node.id] =
                        Pair(it.size.width.toDouble(), it.size.height.toDouble())
                }.padding(node.inset.dp).onGloballyPositioned {
                    kayaInsetInner[node.id] =
                        Pair(it.size.width.toDouble(), it.size.height.toDouble())
                    kayaContainerExtents[node.id] = it.size.width.toDouble()
                    kayaContainerCross[node.id] = it.size.height.toDouble()
                    kayaContainerAxis[node.id] = false
                },
                horizontalArrangement = Arrangement.spacedBy(node.spacing.dp),
                verticalAlignment = when (node.align) {
                    KayaCompose.ALIGN_CENTER -> Alignment.CenterVertically
                    KayaCompose.ALIGN_END -> Alignment.Bottom
                    else -> Alignment.Top
                },
            ) {
                node.laidOut.forEach { child ->
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
                    // The crossing COLUMN's track — the column arm's
                    // sibling, one axis over.
                    if (node.align == KayaCompose.ALIGN_STRETCH ||
                        child.kind == KayaCompose.KIND_COLUMN
                    ) {
                        cell = cell.fillMaxHeight()
                    }
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
                                flexAlign = node.align,
                            )
                        }
                    }
                }
            }
        }
        KayaCompose.KIND_BUTTON ->
            // THE ROLE TIER, in M3's own emphasis ladder
            // (docs/styling-plan.md D4). THE FLOOR IS OUTLINED, filled
            // reserved for `prominent`, or a roleless button would leave
            // `prominent` nowhere to go. DESTRUCTIVE takes the error-role
            // CONTAINER, fixed by Material rather than derived from the
            // brand, so red keeps meaning destructive in a red-branded app.
            when (node.role) {
                KayaCompose.ROLE_PROMINENT ->
                    Button(
                        onClick = { KayaPresent.emitClicked(node.tag) },
                        modifier = boxFill.then(a11y),
                    ) {
                        // A button's label is Material's OWN rung
                        // (`Button` provides labelLarge internally), so
                        // this samples the ramp route through a
                        // component kaya never styles.
                        Text(node.text, onTextLayout = { kayaTypefaceSites["button"] = it })
                    }
                KayaCompose.ROLE_DESTRUCTIVE ->
                    Button(
                        onClick = { KayaPresent.emitClicked(node.tag) },
                        modifier = boxFill.then(a11y),
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
                        // THE BEZEL IS THE CHILD, not a natural-width
                        // control inside a grown box: Material takes this
                        // modifier onto the Surface, so the chrome spans
                        // the track the way GTK's Fill and XAML's Stretch
                        // already do (grow.steps' button#0).
                        modifier = boxFill.then(a11y),
                    ) {
                        Text(node.text, onTextLayout = { kayaTypefaceSites["button"] = it })
                    }
            }
        KayaCompose.KIND_LABEL ->
            // The heading role is BOTH facts at once (docs/styling-plan.md
            // D4): Compose's `heading()` semantics, which is the half
            // every platform publishes and the half the styling scene
            // freezes, plus a tier of Material's own type ramp. PICKING
            // A TIER IS NOT CHANGING THE SCALE.
            if (node.role == KayaCompose.ROLE_HEADING) {
                Text(
                    node.text,
                    style = MaterialTheme.typography.titleLarge,
                    // A SAMPLE OF THE RAMP ROUTE for expect_typeface:
                    // this label takes its style from `typography`, so
                    // it goes on reading the platform face if the
                    // theme's first write is missing.
                    onTextLayout = { kayaTypefaceSites["heading"] = it },
                    modifier = boxFill.then(a11y).semantics { heading() },
                )
            } else if (node.role == KayaCompose.ROLE_CAPTION) {
                // The caption role: Material's supporting-text reading —
                // bodySmall on the variant colour. No semantics half:
                // Compose (like UIA and Apple) has no caption fact to
                // publish, the carve-out a11yrows.steps records.
                Text(
                    node.text,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    onTextLayout = { kayaTypefaceSites["caption"] = it },
                    modifier = boxFill.then(a11y),
                )
            } else {
                // A role with no arm above is REFUSED, not quietly worn as
                // a plain label — the interpreters are the historic miss
                // layer, and the Rust backends' catch-alls already panic.
                check(node.role == 0L) {
                    "kaya: label role ${node.role} has no compose arm"
                }
                // And the AMBIENT route's sample: a plain label reads
                // LocalTextStyle, the write the ramp cannot stand in for.
                Text(
                    node.text,
                    onTextLayout = { kayaTypefaceSites["label"] = it },
                    modifier = boxFill.then(a11y),
                )
            }
        KayaCompose.KIND_CHECKBOX ->
            // Uncontrolled toward the app, the entry's shape. The TOGGLE
            // LIVES ON THE ROW and the box takes onCheckedChange = null:
            // a box with its own handler is independently focusable and
            // Compose's merging STOPS there, so the row read
            // `group/Details` with a separate unnamed checkbox instead of
            // one `checkbox/Details` (measured 2026-07-25).
            Row(
                modifier = boxFill.then(a11y)
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
        KayaCompose.KIND_SLIDER -> KayaSliderSurface(node, boxFill.then(a11y))
        KayaCompose.KIND_IMAGE -> {
            // Fixed to the decoded bitmap's intrinsic size. The one kind
            // whose NAME does not ride the shared modifier: Image's own
            // contentDescription declares Role.Image, null there meaning
            // "decoration". A FAILED DECODE IS PRESENT AND EMPTY, NOT
            // ABSENT — emit nothing and everything counting children
            // POSITIONALLY reads the wrong one (tools/check-empty-child.py
            // perturbs these two lines verbatim).
            val bitmap = node.imageBitmap
            if (bitmap != null) {
                Image(
                    bitmap = bitmap,
                    contentDescription = node.a11yLabel.ifEmpty { null },
                    modifier = boxFill.then(a11yTag),
                )
            } else {
                Box(modifier = a11yTag)
            }
        }
        // The multi-line editor: the entry's exact contract
        // (uncontrolled state, identity-tag emits, model-driven focus)
        // over a multiline field. One composable serves both kinds —
        // they differed only in two arguments, and a second copy is a
        // second place for the echo guard to be got wrong.
        KayaCompose.KIND_TEXTAREA -> KayaTextField(node, a11y, boxFill, singleLine = false)
        KayaCompose.KIND_ENTRY -> KayaTextField(node, a11y, boxFill, singleLine = true)
        KayaCompose.KIND_DATE_PICKER, KayaCompose.KIND_TIME_PICKER ->
            KayaPickerField(node, a11y, boxFill)
        KayaCompose.KIND_CANVAS -> {
            // THE BLIT (docs/canvas-plan.md §8), interpreting no draw op.
            // STRICTLY 1:1, NEVER STRETCHED (§3.2.1 ruling 2), and THE
            // TRACK IS THIS LAYOUT'S OWN SIZE — reading the image would
            // make track and raster agree by construction. A GROWER TAKES
            // THE WHOLE OFFERED BOX (docs/traps.md, "A `redraw` canvas
            // sized from its own buffer NEVER STARTS"); an UNGROWN one is
            // CLAMPED. THE TAG RIDES THE IMAGE, not this Layout.
            val drawing = node.drawing
            val canvasDensity = LocalDensity.current.density.toDouble()
            Layout(
                content = {
                    if (drawing != null) {
                        Image(
                            bitmap = drawing,
                            contentDescription = node.a11yLabel.ifEmpty { null },
                            contentScale = ContentScale.None,
                            modifier = a11yTag,
                        )
                    } else {
                        Box(modifier = a11yTag)
                    }
                },
                modifier = boxFill.onGloballyPositioned {
                    val r = it.boundsInWindow()
                    kayaCanvasBoxes[node.id] = android.graphics.Rect(
                        r.left.toInt(), r.top.toInt(), r.right.toInt(), r.bottom.toInt())
                    KayaPresent.canvasTrack(
                        node.id,
                        it.size.width.toDouble() / canvasDensity,
                        it.size.height.toDouble() / canvasDensity,
                    )
                },
            ) { measurables, constraints ->
                val placeables = measurables.map { it.measure(Constraints()) }
                val grown = node.grow > 0
                val width = if (grown && constraints.hasBoundedWidth) {
                    constraints.maxWidth
                } else {
                    (placeables.maxOfOrNull { it.width } ?: 0)
                        .coerceIn(constraints.minWidth, constraints.maxWidth)
                }
                val height = if (grown && constraints.hasBoundedHeight) {
                    constraints.maxHeight
                } else {
                    (placeables.maxOfOrNull { it.height } ?: 0)
                        .coerceIn(constraints.minHeight, constraints.maxHeight)
                }
                layout(width, height) {
                    // CENTRED, which is the letterbox: `scale` fits its
                    // figure inside the track and `fixed` sits in the
                    // middle of one it refused to adapt to.
                    placeables.forEach {
                        it.placeRelative((width - it.width) / 2, (height - it.height) / 2)
                    }
                }
            }
            // THE PLATFORM'S FRAME DRIVE, outside the harness
            // (docs/canvas-plan.md §15.4). `withFrameNanos` hands back the
            // frame's timestamp, which is what the tick must carry — a
            // clock read inside the callback re-imports the jitter the
            // frame time removes. NOT UNDER THE HARNESS, or a second
            // clock would make every animation leg a question about load.
            // ONE PER CANVAS, since this backend is not told which tick.
            if (!kayaHarnessDrivesFrames) {
                LaunchedEffect(node.id) {
                    while (true) {
                        withFrameNanos { KayaPresent.frame(it / 1_000_000_000.0) }
                    }
                }
            }
        }
    }
}

/**
 * THE ENTRY AND THE TEXTAREA, on `BasicTextField(state:)` with M3
 * dressing (docs/undo-plan.md §1.4) — NOT `TextField(value:,
 * onValueChange:)`, whose undo stack no app can see. THE ECHO GUARD:
 * `snapshotFlow { state.text }` fires for kaya's OWN writes too, so this
 * collector reports only what makes model and widget DIFFER.
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun KayaTextField(
    node: KayaNode,
    a11y: Modifier,
    /**
     * [KayaRenderCore]'s `boxFill` — the grow/stretch/crossing fill every
     * kind rides. THE LINE LIMITS BELOW ARE A FLOOR AND A CEILING IN
     * LINES, which bounds an unweighted field; a grower's size is the
     * cell its weight earned, and a field ignoring that cell rendered
     * three lines tall inside one expect_shares read as exactly right.
     */
    fill: Modifier,
    singleLine: Boolean,
) {
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
        // THE TEXTAREA IS A BOUNDED EDITOR WITH ITS OWN VIEWPORT, as
        // every other backend's already is. `MultiLine(minHeightInLines)`
        // leaves the maximum at Int.MAX_VALUE, so a 40-line document
        // rendered 2496px tall with nothing able to scroll it (measured,
        // range-probe-android.md §0.2) and `expect_revealed offscreen`
        // would be true forever. Bounded through the field's OWN scroll,
        // which a verticalScroll wrapper would cost.
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
            .then(fill)
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
 * THE DECORATED RANGES, painted behind the text: there is NO STYLING
 * HOOK on this field, and the trap is that `state.edit { replace(0,
 * length, annotated) }` COMPILES CLEAN and paints NOTHING
 * (range-probe-android.md §1a). PHASE DISCIPLINE IS THE RULE HERE — a
 * hoisted read recomposes the field 200 times in 200 frames.
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
            // D2's CLEAR-ON-EDIT, made structural: the set is painted
            // ONLY while the field still holds the text it was declared
            // against, so a compare made on the pass that paints cannot
            // arrive late where a message from the core could. Stale
            // offsets here are a WRONG highlight rather than a crash
            // (measured, §1c).
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
 * TONE, the number Material's colour system is built on: HCT's T is CIE
 * L*, so a TONE DIFFERENCE IS A CONTRAST GUARANTEE — the property every
 * rule below leans on. Read through Compose's own colour-space
 * machinery, so this is the number material3 itself works in.
 */
private fun Color.kayaTone(): Float = convert(ColorSpaces.CieLab).red

/**
 * The seed's palette AT A TONE: Material's own `setLuminance` plus THE
 * GAMUT LOOP, without which a saturated seed at tone 90 has no sRGB
 * representative and CLIPS to another lightness (measured, Adwaita blue
 * #3584E4 at tone 90 comes back at L* 78). So this bisects the seed's
 * chroma for the most colourful candidate at the tone asked for.
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
 * A ROLE'S TONE: the nominal one if it meets its curve's contrast, else
 * what `DynamicColor.foregroundTone` picks, walked a tone at a time.
 * BOTH DIRECTIONS ARE WEIGHED, measured: at high contrast a rule walking
 * only away from the background took onPrimaryContainer down to black
 * (3.9:1) where white above it was 5.4:1. Either candidate CLAMPS.
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
 * The colour schemes this backend composes under. THIS BACKEND DERIVES,
 * against the rule elsewhere, because Material's colour system IS a
 * published derivation from one seed (docs/styling-plan.md D1). ALL FIVE
 * palettes follow the brand except ERROR (docs/deferred.md "THE FULL M3
 * SCHEME"; KayaColorSchemesTest is the wall).
 */
internal object KayaColorSchemes {
    val light: ColorScheme = lightColorScheme()
    val dark: ColorScheme = darkColorScheme()

    /**
     * @param seed the brand accent, packed 0xRRGGBB, or null for
     *   Material's baseline — NOT the wallpaper palette (D2).
     * @param dark the appearance to build for.
     * @param contrast the system level, -1..1, which a STATIC scheme
     *   silently ignores (MDC #3524).
     */
    fun of(seed: Int?, dark: Boolean, contrast: Float): ColorScheme {
        val base = if (dark) this.dark else this.light
        if (seed == null) return base
        val key = Color(0xFF000000.toInt() or seed)
        // The four HCT palettes (a2/a3/n1/n2; a1 stays kayaToneOf's so
        // the primary family's bytes do not move under the ruling).
        val core = com.materialkolor.palettes.CorePalette.of(0xFF000000.toInt() or seed)
        fun com.materialkolor.palettes.TonalPalette.at(tone: Float): Color =
            Color(this.tone(kotlin.math.round(tone).toInt().coerceIn(0, 100)))
        // The background the accent roles are read against IS the
        // derived neutral surface now — spec tone 98/6, from n1.
        val surfaceTone = if (dark) 6f else 98f
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
        // The neutral grounds, spec tones verbatim (backgrounds carry
        // no contrast curve in color_spec_2021.ts):
        //   surface/background      98/6      inverseSurface  20/90
        //   surfaceDim              87/6      surfaceBright   98/24
        //   surfaceContainerLowest 100/4      surfaceContainerLow 96/10
        //   surfaceContainer        94/12     surfaceContainerHigh 92/17
        //   surfaceContainerHighest 90/22     surfaceVariant (n2) 90/30
        //   scrim 0
        val inverseSurfaceTone = if (dark) 90f else 20f
        val inverseTone = kayaRoleTone(
            nominal = if (dark) 40f else 80f,
            background = inverseSurfaceTone,
            desired = kayaContrastAt(contrast, 3f, 4.5f, 7f, 7f),
        )
        val primary = kayaToneOf(key, primaryTone)
        val onPrimary = kayaToneOf(key, onPrimaryTone)
        val container = kayaToneOf(key, containerTone)
        val onContainer = kayaToneOf(key, onContainerTone)
        val inverse = kayaToneOf(key, inverseTone)
        // The a2/a3 accent families ride the same tones and curves as
        // the primary family (color_spec_2021.ts gives all three
        // TONAL_SPOT accents one shape; only the palette differs):
        fun accent(p: com.materialkolor.palettes.TonalPalette): Array<Color> {
            val roleTone = kayaRoleTone(
                nominal = if (dark) 80f else 40f,
                background = surfaceTone,
                desired = kayaContrastAt(contrast, 3f, 4.5f, 7f, 7f),
            )
            val onRoleTone = kayaRoleTone(
                nominal = if (dark) 20f else 100f,
                background = roleTone,
                desired = kayaContrastAt(contrast, 4.5f, 7f, 11f, 21f),
            )
            val containerRoleTone = kayaRoleTone(
                nominal = if (dark) 30f else 90f,
                background = surfaceTone,
                desired = kayaContrastAt(contrast, 1f, 1f, 3f, 4.5f),
            )
            val onContainerRoleTone = kayaRoleTone(
                nominal = if (dark) 90f else 30f,
                background = containerRoleTone,
                desired = kayaContrastAt(contrast, 3f, 4.5f, 7f, 11f),
            )
            return arrayOf(
                p.at(roleTone), p.at(onRoleTone),
                p.at(containerRoleTone), p.at(onContainerRoleTone),
            )
        }
        val (secondary, onSecondary, secondaryContainer, onSecondaryContainer) = accent(core.a2)
        val (tertiary, onTertiary, tertiaryContainer, onTertiaryContainer) = accent(core.a3)
        // The neutral foregrounds and lines, tones and curves verbatim
        // from color_spec_2021.ts:
        //   onBackground     10/90, ContrastCurve(3, 3, 4.5, 7)
        //   onSurface        10/90, ContrastCurve(4.5, 7, 11, 21)
        //   onSurfaceVariant 30/80, ContrastCurve(3, 4.5, 7, 11)
        //   inverseOnSurface 95/20, ContrastCurve(4.5, 7, 11, 21)
        //   outline          50/60, ContrastCurve(1.5, 3, 4.5, 7)
        //   outlineVariant   80/30, ContrastCurve(1, 1, 3, 4.5)
        val onBackgroundTone = kayaRoleTone(
            nominal = if (dark) 90f else 10f,
            background = surfaceTone,
            desired = kayaContrastAt(contrast, 3f, 3f, 4.5f, 7f),
        )
        val onSurfaceTone = kayaRoleTone(
            nominal = if (dark) 90f else 10f,
            background = surfaceTone,
            desired = kayaContrastAt(contrast, 4.5f, 7f, 11f, 21f),
        )
        val onSurfaceVariantTone = kayaRoleTone(
            nominal = if (dark) 80f else 30f,
            background = if (dark) 30f else 90f,
            desired = kayaContrastAt(contrast, 3f, 4.5f, 7f, 11f),
        )
        val inverseOnSurfaceTone = kayaRoleTone(
            nominal = if (dark) 20f else 95f,
            background = inverseSurfaceTone,
            desired = kayaContrastAt(contrast, 4.5f, 7f, 11f, 21f),
        )
        val outlineTone = kayaRoleTone(
            nominal = if (dark) 60f else 50f,
            background = surfaceTone,
            desired = kayaContrastAt(contrast, 1.5f, 3f, 4.5f, 7f),
        )
        val outlineVariantTone = kayaRoleTone(
            nominal = if (dark) 30f else 80f,
            background = surfaceTone,
            desired = kayaContrastAt(contrast, 1f, 1f, 3f, 4.5f),
        )
        // The ERROR family is deliberately absent from both builder
        // calls below: red means destructive under any brand, and the
        // builders' defaults are exactly the baseline error roles.
        // surfaceTint IS primary in Material's spec (same palette, same
        // tone), which is how an elevated surface picks up the brand.
        val surface = core.n1.at(surfaceTone)
        val onSurface = core.n1.at(onSurfaceTone)
        return if (dark) {
            darkColorScheme(
                primary = primary,
                onPrimary = onPrimary,
                primaryContainer = container,
                onPrimaryContainer = onContainer,
                inversePrimary = inverse,
                surfaceTint = primary,
                secondary = secondary,
                onSecondary = onSecondary,
                secondaryContainer = secondaryContainer,
                onSecondaryContainer = onSecondaryContainer,
                tertiary = tertiary,
                onTertiary = onTertiary,
                tertiaryContainer = tertiaryContainer,
                onTertiaryContainer = onTertiaryContainer,
                background = surface,
                onBackground = core.n1.at(onBackgroundTone),
                surface = surface,
                onSurface = onSurface,
                surfaceVariant = core.n2.at(30f),
                onSurfaceVariant = core.n2.at(onSurfaceVariantTone),
                inverseSurface = core.n1.at(inverseSurfaceTone),
                inverseOnSurface = core.n1.at(inverseOnSurfaceTone),
                outline = core.n2.at(outlineTone),
                outlineVariant = core.n2.at(outlineVariantTone),
                scrim = core.n1.at(0f),
                surfaceDim = core.n1.at(6f),
                surfaceBright = core.n1.at(24f),
                surfaceContainerLowest = core.n1.at(4f),
                surfaceContainerLow = core.n1.at(10f),
                surfaceContainer = core.n1.at(12f),
                surfaceContainerHigh = core.n1.at(17f),
                surfaceContainerHighest = core.n1.at(22f),
            )
        } else {
            lightColorScheme(
                primary = primary,
                onPrimary = onPrimary,
                primaryContainer = container,
                onPrimaryContainer = onContainer,
                inversePrimary = inverse,
                surfaceTint = primary,
                secondary = secondary,
                onSecondary = onSecondary,
                secondaryContainer = secondaryContainer,
                onSecondaryContainer = onSecondaryContainer,
                tertiary = tertiary,
                onTertiary = onTertiary,
                tertiaryContainer = tertiaryContainer,
                onTertiaryContainer = onTertiaryContainer,
                background = surface,
                onBackground = core.n1.at(onBackgroundTone),
                surface = surface,
                onSurface = onSurface,
                surfaceVariant = core.n2.at(90f),
                onSurfaceVariant = core.n2.at(onSurfaceVariantTone),
                inverseSurface = core.n1.at(inverseSurfaceTone),
                inverseOnSurface = core.n1.at(inverseOnSurfaceTone),
                outline = core.n2.at(outlineTone),
                outlineVariant = core.n2.at(outlineVariantTone),
                scrim = core.n1.at(0f),
                surfaceDim = core.n1.at(87f),
                surfaceBright = core.n1.at(98f),
                surfaceContainerLowest = core.n1.at(100f),
                surfaceContainerLow = core.n1.at(96f),
                surfaceContainer = core.n1.at(94f),
                surfaceContainerHigh = core.n1.at(92f),
                surfaceContainerHighest = core.n1.at(90f),
            )
        }
    }
}

// --- THE BRAND TYPEFACE (docs/styling-plan.md Slice 2b) --------------
// Three measured findings shape it (docs/styling/typeface-compose.md).
// ONE WRITE IS NOT ENOUGH: `typography` brands Material's OWN components
// while kaya's labels read `LocalTextStyle`. THE READS THAT LOOK RIGHT
// ARE ECHOES OF THE REQUEST, so the honest read is the shaped glyph
// run's own font FILE. THE FALLBACK IS TOTAL AND SILENT — a missing
// family renders as Roboto and `preload` accepted every nonsense name.

/**
 * The string the resolved-face reads shape. Latin, because every UI face
 * on every lane covers it: a probe the resolved font lacks would be
 * shaped by a FALLBACK font and report the fallback's family, which is a
 * true answer to the wrong question.
 */
private const val KAYA_TYPEFACE_PROBE = "Handgloves"

/**
 * TWO SENTINELS, which makes the apply-time miss detector
 * device-independent (docs/styling/typeface-compose.md §3.2): a
 * FontFamily falls through when a name does not load, so landing on a
 * sentinel IS the miss. One face means it loaded, two means it did not —
 * and the detector checks HERE that A and B differ.
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
 * The FAMILY NAME out of a font file's OpenType `name` table — the link
 * in the read that cannot echo. nameID 16 when the font has one, else
 * nameID 1, since 16 groups a family whose weights carry their own.
 * Windows and Unicode records are UTF-16BE, the Macintosh one a byte
 * encoding. Null reads as a mismatch rather than a pass.
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
 * THE HONEST READ, one face: shape [KAYA_TYPEFACE_PROBE] and ask the
 * glyph run which FONT it came from (docs/styling/typeface-compose.md
 * §2.2). `TextRunShaper` is API 31, and below it the honest answer is
 * null — which callers turn into a sentence naming the API level, never
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
 * kept apart because a diagnostic may only print what it measured and a
 * single "cannot tell" would name one cause for the other's state
 * (caught by the negative that made this branch print: it blamed the API
 * level for a device whose sentinels had collided).
 */
private enum class KayaPresence { PRESENT, ABSENT, NO_SHAPED_READ, SENTINELS_ALIKE }

/**
 * DOES THIS DEVICE HAVE THIS FAMILY? — asked where the lowering applies
 * it, on the path nobody can avoid. The two not-knowing answers are
 * real: below API 31 there is no shaped-run read, or the sentinels
 * resolved alike. NOT `preload`, which returned ok for every nonsense
 * family, and NOT `getSystemFontFamilyName()`, an echo of the request.
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
 * The BYTES form: the blob to an app-private file and a `FontFamily`
 * over it, null when the bytes are not a font. WHY THE CHECK IS
 * `Typeface.Builder`, MEASURED: a corrupt blob makes Compose's own
 * `Font(File)` THROW at RESOLVE, inside composition, where
 * `Typeface.Builder(file).build()` returns null (§6.3).
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
 * converge on the `FontFamily` OBJECT rather than a name: Android has no
 * app-font registry (docs/styling/typeface-compose.md §6.2). PRECEDENCE
 * IS THE APPLE ARM'S — the bytes, this platform's row, the default.
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
 * into the theme, since the two writes are what come apart — `label`
 * reads `LocalTextStyle` where `heading` reads the ramp. Written during
 * LAYOUT, so a plain map and not snapshot state. A sample outliving its
 * node can only manufacture a DISAGREEMENT, which fails loudly.
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
 * ended up with — NEVER THE MODEL AND NEVER THE REQUEST. Both halves of
 * the resolution come out of a `TextLayoutResult` a real layout pass
 * produced. THE SITES MUST AGREE, or a lowering that reached the ramp
 * and not the ambient style would hide; a disagreement is reported AS one.
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
 * THE HONEST READ, for `expect_app_icon`: the four quadrant centres of
 * the picture the LAUNCHER draws, plus a requirement that the guest's
 * declaration agrees. The picture comes from PackageManager
 * (docs/app-identity-plan.md ruling 3), never from kaya's model; THE
 * DECLARATION IS ALSO REQUIRED, since the packaged icon is there
 * whatever a guest declared. A sentence is wrapped in `<…>` and the
 * samples never are, which is how a failure rides back through a String.
 *
 * THE SENTENCES, and what each one MEASURED (invariant 3):
 *
 *   no declaration    no set_app_identity record was decoded in this
 *                     process.
 *   no icon declared  the record arrived with no blob in its mask.
 *   undecodable       BitmapFactory refused the declared bytes; the byte
 *                     count is printed because it is what was refused.
 *   no launcher       queryIntentActivities found no MAIN/LAUNCHER
 *                     activity for this package at all.
 *   no packaged icon  getIconResource() is 0, so the system would hand
 *                     back its own default with no complaint. Measured,
 *                     never inferred from pixels.
 *   disagreement      both sides sampled and differ; both are printed,
 *                     since which is wrong is the reader's decision.
 */
internal fun kayaAppIconSamples(activity: ComponentActivity): String {
    val name = KayaSceneModel.appIdentityName
        ?: return "<no set_app_identity record reached this process: the guest " +
            "declared no identity, and the launcher icon is compiled into the APK " +
            "whether it did or not>"
    val declared = KayaSceneModel.appIdentityIcon
        ?: return "<the identity \"$name\" arrived with no icon: the record's mask " +
            "carried no blob, so there is nothing declared for the packaged picture " +
            "to be equal to>"
    val declaredBitmap = BitmapFactory.decodeByteArray(declared, 0, declared.size)
        ?: return "<the declared icon bytes are not an image this platform can " +
            "decode: BitmapFactory refused ${declared.size} bytes>"

    val pm = activity.packageManager
    val pkg = activity.packageName
    val launcher = Intent(Intent.ACTION_MAIN)
        .addCategory(Intent.CATEGORY_LAUNCHER)
        .setPackage(pkg)
    @Suppress("DEPRECATION")
    val resolved = pm.queryIntentActivities(launcher, 0).firstOrNull()
        ?: return "<the installed package $pkg publishes no MAIN/LAUNCHER activity, " +
            "so no launcher has an icon to draw for it>"
    if (resolved.iconResource == 0) {
        return "<the installed package $pkg declares no launcher icon: the resolved " +
            "activity's icon resource id is 0, so android:icon reached neither the " +
            "activity nor the application and the launcher draws the system default>"
    }
    val packagedSamples = kayaDrawableSamples(resolved.loadIcon(pm), "the packaged icon")
    if (packagedSamples.startsWith("<")) return packagedSamples
    val declaredSamples = kayaBitmapSamples(declaredBitmap, "the declared bytes")
    if (declaredSamples.startsWith("<")) return declaredSamples
    if (packagedSamples != declaredSamples) {
        return "<the packaged icon and the declared bytes disagree: the package's " +
            "launcher resource samples $packagedSamples, the ${declared.size} bytes " +
            "the guest declared sample $declaredSamples>"
    }
    return packagedSamples
}

/** A drawable rasterized at its intrinsic size and sampled. Always
 *  through a Canvas, so an adaptive or vector icon is measured as the
 *  system would compose it rather than skipped, and so no hardware
 *  bitmap reaches [kayaBitmapSamples] (getPixel throws on one). */
private fun kayaDrawableSamples(icon: Drawable, what: String): String {
    val w = icon.intrinsicWidth
    val h = icon.intrinsicHeight
    if (w <= 1 || h <= 1) {
        return "<$what rasterizes to ${w}x${h}, too small to sample four quadrants>"
    }
    val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
    icon.setBounds(0, 0, w, h)
    icon.draw(Canvas(out))
    return kayaBitmapSamples(out, what)
}

/**
 * `RRGGBB/RRGGBB/RRGGBB/RRGGBB` — top-left, top-right, bottom-left,
 * bottom-right, every backend's reading order. CENTRES AND NOT CORNERS:
 * any rescale between the declared 64x64 PNG and the size a platform
 * rasterizes at blurs the quadrant BOUNDARIES, and Android does rescale
 * (an unqualified mipmap is mdpi, and the emulator's 320dpi doubles it).
 */
private fun kayaBitmapSamples(bitmap: Bitmap, what: String): String {
    val w = bitmap.width
    val h = bitmap.height
    if (w <= 1 || h <= 1) {
        return "<$what decoded to ${w}x${h}, too small to sample four quadrants>"
    }
    fun sample(qx: Int, qy: Int): String {
        val x = (w * (1 + 2 * qx) / 4).coerceIn(0, w - 1)
        val y = (h * (1 + 2 * qy) / 4).coerceIn(0, h - 1)
        return String.format(java.util.Locale.ROOT, "%06X", bitmap.getPixel(x, y) and 0xFFFFFF)
    }
    return "${sample(0, 0)}/${sample(1, 0)}/${sample(0, 1)}/${sample(1, 1)}"
}

/**
 * Material's ramp with the FAMILY swapped and nothing else touched, so
 * `fontSize`, `lineHeight`, `fontWeight` and `letterSpacing` stay what
 * Material set — "the family swaps, the ramp never does" (DESIGN.md),
 * checked: all fifteen rungs read byte-identical across the unbranded,
 * `serif` and `cursive` legs (docs/styling/typeface-compose.md §1.3).
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
 * The composition half of `KAYA_APPEARANCE` (KayaCompose.mount holds the
 * other half and the reasoning). `isSystemInDarkTheme()` reads
 * `LocalConfiguration`'s night bits and NOTHING ELSE, so forcing those
 * bits moves every reading at once; unset provides nothing. The rest of
 * the configuration is COPIED, since the size class reads screenWidthDp.
 */
@Composable
internal fun KayaAppearance(content: @Composable () -> Unit) {
    val want = KayaCompose.appearanceOverride
    if (want == null) {
        content()
        return
    }
    val base = LocalConfiguration.current
    val forced = remember(base, want) {
        Configuration(base).apply {
            uiMode = (uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                KayaCompose.nightBits(want)
        }
    }
    CompositionLocalProvider(LocalConfiguration provides forced, content = content)
}

/**
 * THE THEME ROOT, where this backend's appearance is decided, from three
 * inputs none of which are assumed: the brand SEED, the APPEARANCE and
 * the CONTRAST level (MDC #3524). MaterialTheme ALSO PROVIDES A TEXT
 * STYLE at 16sp where `LocalTextStyle` outside a theme is UNSPECIFIED,
 * so accepting it would change the type SCALE (DESIGN.md).
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
        // AND THE SECOND WRITE, which the probe measured: kaya's own
        // labels and fields read this local and NOT the ramp, so setting
        // `typography` alone brands Material's components and leaves
        // every kaya label on the platform face. FAMILY ONLY — the size
        // stays Unspecified, since a brand typeface substitutes the
        // family and never the scale (DESIGN.md).
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
 * accessibility slider, on Material's own scale. LIVE, not sampled once:
 * the slider is not a Configuration field, so a composition reading it
 * at startup would keep the old scheme for the process's life. Below API
 * 34 there is no slider and the honest answer is 0.
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
    // THE WINDOW'S SCALE AND APPEARANCE, reported to the core, which
    // re-rasters every canvas at them (docs/canvas-plan.md §5, §6); no
    // platform colour reaches a drawing. COMPOSITION IS THE CHANNEL, so
    // a display move or a night-mode flip re-runs this for free. The
    // density IS the scale kaya reports, which lands the canvas arm's
    // intrinsic sizing on the viewbox with no arithmetic.
    val presentationScale = LocalDensity.current.density.toDouble()
    val presentationDark = isSystemInDarkTheme()
    LaunchedEffect(presentationScale, presentationDark) {
        KayaSceneModel.presentationDark = presentationDark
        // ONE LINE PER REPORT, and the recreation leg COUNTS THEM
        // (tools/android/run-emulator.py): a relaunch builds a fresh
        // composition, and if this effect did not run again the core
        // would keep rasterizing at the OLD scale and appearance after a
        // rotation. Nothing observable would move — the core latches the
        // last report — so the count is the only witness.
        Log.i("kaya", "KAYA_PRESENTATION: scale=$presentationScale dark=$presentationDark")
        KayaPresent.presentation(presentationScale, presentationDark)
    }
    // The size class, from the platform's own width in dp against the
    // 600dp boundary — the same boundary androidx's WindowSizeClass
    // draws, taken directly so the interpreter needs no extra artifact.
    KayaSceneModel.formFactor =
        if (LocalConfiguration.current.screenWidthDp >= 600) "regular" else "compact"
    // The window's content size, reported for breakpoint evaluation
    // (docs/adaptive-layout-plan.md D3) — a composition local, so a
    // rotation re-reports for free; the core latches and same-width
    // reports are silent.
    val metricsWidth = LocalConfiguration.current.screenWidthDp.toDouble()
    val metricsHeight = LocalConfiguration.current.screenHeightDp.toDouble()
    LaunchedEffect(metricsWidth, metricsHeight) {
        KayaPresent.windowMetrics(0, metricsWidth, metricsHeight)
    }
    // THE SYSTEM'S OWN CHROME IS AN INSET THIS SURFACE CONSUMES, all of
    // it: the status bar, the navigation bar, a display cutout and the
    // soft keyboard, whose union `safeDrawing` is.
    // THE KEYBOARD HALF is the older half — without it the system PANS
    // the whole window up for a focused field low in it (measured
    // 2026-08-10, `getLocationInWindow()` = (0, -199)), putting the menu
    // bar and first line ABOVE the window, never drawn, while the model,
    // the semantics tree and the field's viewport all still read
    // correctly, so only a PIXEL read notices.
    // THE SYSTEM BARS joined 2026-09-03 (docs/traps.md: THE TOP 24px OF
    // AN ANDROID KAYA WINDOW WAS THE STATUS BAR'S): these apps target
    // SDK 35, where Android 15 forces edge to edge, so kaya's first row
    // drew under the status bar and its last under the gesture bar — and
    // that strip is the status bar's TOUCHABLE region, so no real input
    // could reach it either. No lane could see it: every `click` is
    // programmatic, and the dnd lane's real `input draganddrop` is the
    // first injected touch this backend ever had.
    Box(modifier = Modifier.fillMaxSize().safeDrawingPadding()) {
        if (KayaSceneModel.menubar.isEmpty()) {
            // No catalog: the surface keeps its exact pre-menus shape (no
            // phantom bar over scenes that declared no commands).
            KayaSceneModel.menuPresentation = "none"
            KayaSurface()
        } else {
            // The window catalog's phone lowering (DESIGN.md, Menus).
            // STAMPED BY THE ARM THAT RENDERS, not inferred from the
            // size class. Android has no menu-bar lowering, so this is
            // `overflow` in BOTH classes — the honest report, which a
            // tablet-width assertion would correctly fail on.
            KayaSceneModel.menuPresentation = "overflow"
            Column(modifier = Modifier.fillMaxSize()) {
                KayaMenuTopBar()
                Box(modifier = Modifier.weight(1f)) { KayaSurface() }
            }
        }
    }

    // The system back gesture, the user-sovereign POP: enabled only
    // while the stack has entries, and DISABLED while both panes are on
    // screen — in the split arm the top entry covers nothing, so an
    // enabled handler pops to a blank detail pane. Compose's own rule,
    // where canNavigateBack reports false once both panes are visible.
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
 * the app declares a panes ceiling and the platform decides presentation.
 * The standard directive grants a second horizontal partition at
 * 840dp, so 840dp is Android's threshold, chosen by Android. */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
internal fun kayaPaneDirective(): PaneScaffoldDirective =
    calculatePaneScaffoldDirective(
        currentWindowAdaptiveInfo(supportLargeAndXLargeWidth = true))

/** The pane arrangement [ListDetailPaneScaffold] lays out from.
 * SUPPLIED, NOT OWNED, which is why adaptive-navigation is deliberately
 * not a dependency: its navigator would hold a destination history and
 * kaya's core owns the stack (DESIGN.md, Navigation). The wrapper is
 * told the ONE fact it needs. Everything past that is Material's, which
 * is what makes reading it back an observation rather than an echo. */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
internal fun kayaScaffoldValue(directive: PaneScaffoldDirective): ThreePaneScaffoldValue =
    calculateThreePaneScaffoldValue(
        // THE CEILING IS A CAP (docs/multicolumn-plan.md D2): `panes 2`
        // on a 1200dp window is a real thing to say and is honored
        // here — which is also what keeps the V2 breakpoints' third
        // partition away from every two-pane window, so the existing
        // tablet legs render exactly as they did before the 1.2.0 bump.
        minOf(directive.maxHorizontalPartitions, KayaSceneModel.panes.toInt()),
        // The list-detail defaults are all Hide today; SPELLED so an
        // upstream default change cannot flip collapse semantics
        // silently — the SupportingPane sibling defaults to Reflow,
        // which keeps both roots on screen stacked, a state kaya's
        // model has no word for (docs/multicolumn-plan.md D3).
        ListDetailPaneScaffoldDefaults.adaptStrategies(
            detailPaneAdaptStrategy = AdaptStrategy.Hide,
            listPaneAdaptStrategy = AdaptStrategy.Hide,
            extraPaneAdaptStrategy = AdaptStrategy.Hide,
        ),
        kayaPaneHistory(),
    )

/** THE HISTORY IS THE STACK (docs/multicolumn-plan.md D1/D3): fed the
 * stack's own order, newest first, this walk IS "the shallowest pane
 * sheds first", and at one partition the newest destination alone
 * survives. A synthesized single item is right for two roles and
 * silently wrong for three — with a history that can never name Extra,
 * Material hides the pane the user navigated to. */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
internal fun kayaPaneHistory(): List<ThreePaneScaffoldDestinationItem<Nothing>> =
    buildList {
        add(ThreePaneScaffoldDestinationItem(ListDetailPaneScaffoldRole.List))
        if (KayaSceneModel.navEntries.isNotEmpty()) {
            add(ThreePaneScaffoldDestinationItem(ListDetailPaneScaffoldRole.Detail))
        }
        if (KayaSceneModel.panes >= 3 && KayaSceneModel.navEntries.size >= 2) {
            add(ThreePaneScaffoldDestinationItem(ListDetailPaneScaffoldRole.Extra))
        }
    }

/** How many pane roles the arrangement expanded: the arrangement
 * question, asked of the arrangement. */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
internal fun kayaExpandedPanes(value: ThreePaneScaffoldValue): Int =
    listOf(
        ListDetailPaneScaffoldRole.List,
        ListDetailPaneScaffoldRole.Detail,
        ListDetailPaneScaffoldRole.Extra,
    ).count { value[it] == PaneAdaptedValue.Expanded }

@OptIn(ExperimentalMaterial3AdaptiveApi::class)
internal fun kayaBothPanesExpanded(value: ThreePaneScaffoldValue): Boolean =
    kayaExpandedPanes(value) >= 2

/** expect_panes' position half (docs/multicolumn-plan.md D4): the stack
 * indices on screen, ascending, comma-joined. Each expanded role maps
 * to the slot it holds — List the base root, Detail the first entry at
 * a ceiling of 3 or the top at 2, Extra the top — and an expanded role
 * over an EMPTY slot contributes nothing. With no scaffold laid out
 * (the serial arm) the top alone is on screen. */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
internal fun kayaPanePositions(): String {
    val entries = KayaSceneModel.navEntries.size
    val value = KayaSceneModel.paneValue ?: return "$entries"
    val third = KayaSceneModel.panes >= 3
    val positions = buildList {
        if (value[ListDetailPaneScaffoldRole.List] == PaneAdaptedValue.Expanded) add(0)
        if (value[ListDetailPaneScaffoldRole.Detail] == PaneAdaptedValue.Expanded &&
            entries >= 1
        ) {
            add(if (third) 1 else entries)
        }
        if (value[ListDetailPaneScaffoldRole.Extra] == PaneAdaptedValue.Expanded &&
            entries >= 2
        ) {
            add(entries)
        }
    }
    return if (positions.isEmpty()) "-" else positions.sorted().joinToString(",")
}

/** Whether this window is presenting its entry stack as list-detail
 * right now. ONE source, read by the arm that renders AND by the back
 * rule: two copies of this condition drift invisibly, one pane count
 * against the other's pop, each half looking correct alone. Compose's
 * own `canNavigateBack` is false in exactly this state. */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
internal fun kayaSplitArm(value: ThreePaneScaffoldValue): Boolean =
    // BRIDGE (docs/multicolumn-plan.md): ceiling >= 2 takes the
    // two-pane split until the three-pane slice lands.
    KayaSceneModel.panes >= 2 && kayaBothPanesExpanded(value)

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
        // entered on the app's declaration alone, and WHETHER it shows
        // one pane or two is the scaffold's call. No `topEntry != null`
        // requirement — an empty stack on a regular window shows the
        // leading pane and an EMPTY trailing one, as GTK and mac do.
        if (KayaSceneModel.panes >= 2) {
            val directive = kayaPaneDirective()
            val scaffoldValue = kayaScaffoldValue(directive)
            // THE SCAFFOLD'S OWN ARRANGEMENT, not a value the arm
            // stamped about itself: writing "split" inside the branch
            // that tested for it would restate the condition and agree
            // with the lowering by construction. This reports how many
            // panes Material resolved, for BOTH outcomes, from the value
            // the scaffold is laid out from — GTK reads is_collapsed and
            // Windows TwoPaneView's Mode for the same reason.
            KayaSceneModel.paneValue = scaffoldValue
            KayaSceneModel.splitPresentation =
                when (kayaExpandedPanes(scaffoldValue)) {
                    3 -> "split3"
                    2 -> "split"
                    else -> "stacked"
                }
            // WHICH SLOT EACH ROLE HOLDS is the ceiling's call (D1):
            // at 2 the detail is the TOP of the stack; at 3 the detail
            // is the FIRST entry and the extra pane holds the rest's
            // top — the last pane always holds the top of the stack.
            val third = KayaSceneModel.panes >= 3
            val detailEntry =
                if (third) KayaSceneModel.navEntries.firstOrNull() else topEntry
            ListDetailPaneScaffold(
                directive = directive,
                value = scaffoldValue,
                // AnimatedPane is what carries the motion; the panes
                // are otherwise the same roots as before — the mounted
                // root leads.
                listPane = {
                    AnimatedPane {
                        KayaSceneModel.root?.let { KayaRender(it, isRoot = true) }
                    }
                },
                detailPane = {
                    AnimatedPane {
                        detailEntry?.root?.let { KayaRender(it, isRoot = true) }
                    }
                },
                extraPane =
                    if (third) {
                        {
                            AnimatedPane {
                                if (KayaSceneModel.navEntries.size >= 2) {
                                    topEntry?.root?.let { KayaRender(it, isRoot = true) }
                                }
                            }
                        }
                    } else {
                        null
                    },
            )
        } else if (topEntry != null) {
            // The serial arm stamps too: an observation only one arm
            // writes is derived-by-default in the other. No scaffold is
            // laid out here, so no stale arrangement may linger for
            // expect_panes to read.
            KayaSceneModel.splitPresentation = "stacked"
            KayaSceneModel.paneValue = null
            // The stack's top is the one visible screen; the covered
            // root below stays alive (retained-until-popped).
            topEntry.root?.let { KayaRender(it, isRoot = true) }
        } else {
            KayaSceneModel.splitPresentation = "stacked"
            KayaSceneModel.paneValue = null
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
 * item's id — what makes the symbol read an OBSERVATION, the tagged
 * node's content description having come from the [Icon] the lowering
 * drew. On EVERY affordance, symbol or not: "the row carries no icon"
 * and "no row exists" are different measurements.
 */
fun kayaMenuTag(id: Long): String = "kaya:menu#$id"

/** THE TAG EVERY MATERIALIZED SECTION ROW CARRIES, keyed by the
 * section's id — [kayaMenuTag] one construct over and for its reason:
 * the content description on the tagged merged node got there from the
 * [Icon] the lowering drew, not from the field a wrong decode fills with
 * garbage while every lane stays green. */
fun kayaSectionTag(id: Long): String = "${KayaCompose.SECTION_TAG_PREFIX}$id"

/** The SEMANTIC ICON, drawn once in one place, so every kind gets
 * identical treatment and an unset symbol is simply no icon.
 * `contentDescription` IS the semantic name: the whole observation
 * channel on this backend, and correct accessibility besides. */
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
 * Hands the harness a handle on the WINDOW this menu is composed in. A
 * Compose `Popup` is its own window under the WindowManager, so nothing
 * under `decorView` leads to it and a11y reads starting there see an
 * open menu as an empty screen. Called at the TOP of each menu's
 * content, and dropped on dispose so a closed menu leaves no stale root.
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
 * SEMANTIC ICON, then the icon blob, then text — and the overflow ⋮
 * holding the ENTIRE catalog. Every affordance routes through
 * [kayaActivateMenuItem]: one dispatch path.
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun KayaMenuTopBar() {
    TopAppBar(
        // The tag IS the chrome's identity for the toolbar reads: they
        // search this subtree and nowhere else, so "the promoted set
        // reached the chrome" is a question about the bar rather than
        // about the window (see KayaCompose.TOOLBAR_TAG).
        modifier = Modifier.testTag(KayaCompose.TOOLBAR_TAG),
        title = {
            // Tagged because expect_title READS THIS NODE — the bar is
            // the title's visible materialization on this platform, and
            // the task label is the other one (see TOOLBAR_TITLE_TAG).
            Text(
                KayaSceneModel.navEntries.lastOrNull()?.title
                    ?: KayaSceneModel.windowTitle,
                modifier = Modifier.testTag(KayaCompose.TOOLBAR_TITLE_TAG),
            )
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
        IconButton(
            onClick = {
                KayaSceneModel.menuOverflowDrilled = 0L
                KayaSceneModel.menuOverflowOpen = true
            },
            // Tagged so the remainder's home is MEASURED off the bar
            // rather than asserted from the model: expect_toolbar reads
            // `none` when this anchor is not composed, which is the one
            // reading harness.rs treats as a failure outright.
            modifier = Modifier.testTag(KayaCompose.TOOLBAR_MORE_TAG),
        ) { Text("⋮") }
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
 * catalog, a drilled submenu and a context menu. `noun` is the anchor's
 * key path, empty off the window catalog; every leaf routes through
 * [kayaActivateMenuItem] and closes the menu. `promoted` ids render no
 * row here, promotion having moved them OUT of overflow.
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

/** A radio group's options as RadioButton rows, inline wherever the
 * group appears. A pick routes through [kayaActivateMenuItem], which
 * emits on the GROUP with the option's index — the Choice contract.
 * THE ONE ROW WHOSE SEMANTIC ICON IS TRAILING, since the leading slot
 * holds the selection mark; the icon is the same [Icon] on the same
 * merged node, so the read cannot tell which slot it came from. */
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
 * PREORDER — grouping nodes in menubar-append order, then each node's
 * children depth-first, creation time being irrelevant. k is
 * [KayaCompose.MENU_PROMOTED_CAPACITY]. Call from composition, where the
 * observable reads recompute the set on every catalog mutation.
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
 * ancestor grouping node is enabled, and, for a standard command, only
 * while its role can act. The role factor is not a build-time fact — it
 * is the intersection of what the clipboard offers and what the focused
 * widget accepts (docs/clipboard-plan.md §3) — and it goes HERE because
 * every affordance on this host already reads this one helper. */
fun kayaMenuEffectivelyEnabled(item: KayaMenuItem): Boolean {
    var cur: KayaMenuItem? = item
    while (cur != null) {
        if (!cur.enabled) return false
        cur = cur.parent
    }
    return KayaCompose.kayaRoleEnabled(item.role)
}

/**
 * THE activation route — every affordance lands here: a rendered row,
 * the harness's menu_activate, and a shortcut. Chrome emits (the user
 * route) and programmatic prop writes never come here; the model mirrors
 * the user state as the checkbox nodes do, and the noun rides every
 * emission verbatim.
 */
fun kayaActivateMenuItem(item: KayaMenuItem, noun: ByteArray) {
    // A disabled item's row is inert and its chord fires nothing —
    // the native menu behavior, uniform across the routes.
    if (!kayaMenuEffectivelyEnabled(item)) return
    when (item.kind) {
        KayaCompose.MENU_KIND_ACTION -> {
            // A ROLE ITEM IS THE PLATFORM'S COMMAND, not the app's
            // action: it acts on the focused widget and emits nothing,
            // there being nothing for the app to decide. Enablement was
            // re-derived one line above, live. An undo is asked FIRST and
            // separately, the two perform paths being disjoint by role,
            // so the order is documentation rather than precedence.
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
 * actions matched on their canonical spelling. Both the hardware-key
 * route and the harness's verb land here and activate through
 * [kayaActivateMenuItem] — the SAME menu_activated a row emits. False
 * when no catalog action owns the chord.
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
 * Resolve a `>`-joined label path wherever the item SURFACED. While a
 * context menu is OPEN it owns resolution EXCLUSIVELY — paths walk the
 * attached roots and a miss is a miss, never a bar fallback — otherwise
 * the window catalog, bar and overflow being one semantic tree here.
 * Returns the item plus the noun its anchor stamps.
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

/** The sections materialization: the M3 bottom NavigationBar (hints are
 * ignored here by physics). The bar's item taps are the USER route,
 * moving the selection and emitting section_selected, where a
 * programmatic select_section lands in the model quietly. */
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
                    // THE ROW'S OWN TAG, so the harness can address this
                    // row in the merged semantics tree — the one thing
                    // that makes expect_section_symbol read the render
                    // instead of the model (kayaSectionTag).
                    modifier = Modifier.testTag(kayaSectionTag(section.id)),
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

/** THE ONE SPELLING every harness reads a slider back in (harness.rs
 * spelled_slider): six decimals, trailing zeros and point dropped. */
fun kayaSpelledSlider(value: Double): String {
    val rounded = Math.round(value * 1_000_000.0) / 1_000_000.0
    var s = String.format(java.util.Locale.ROOT, "%.6f", rounded).trimEnd('0').trimEnd('.')
    if (s.isEmpty() || s == "-" || s == "-0") s = "0"
    return s
}

// ---- the slider (docs/slider-plan.md) ---------------------------------------

/** Where the thumb may rest: on the step's lattice from the minimum,
 * inside the range. */
internal fun kayaSnappedSlider(
    raw: Double,
    min: Double,
    max: Double,
    step: Double,
): Double {
    val v = if (step > 0) min + Math.round((raw - min) / step) * step else raw
    return v.coerceIn(min, max)
}

/** Material counts the INTERIOR stops, so a step that divides the range
 * into n intervals is n − 1 (the core has already refused a step that
 * does not divide it). */
internal fun kayaSliderSteps(min: Double, max: Double, step: Double): Int =
    if (step > 0 && max > min) (Math.round((max - min) / step).toInt() - 1).coerceAtLeast(0) else 0

/** Where kaya draws a tick, as a fraction of the track: every spacing
 * from the minimum, both ends included; none when the spacing is 0 (S5 —
 * ticks are EXPLICIT, so a stepped slider without a spacing has none). */
internal fun kayaSliderTickFractions(
    min: Double,
    max: Double,
    tickSpacing: Double,
): List<Float> {
    val span = max - min
    if (tickSpacing <= 0 || span <= 0) return emptyList()
    val count = Math.round(span / tickSpacing).toInt()
    return (0..count).map { (it * tickSpacing / span).toFloat().coerceIn(0f, 1f) }
}

/**
 * THE ONE COMMIT PATH, a user's gesture and a driven `set_value` alike
 * (docs/slider-plan.md S1, S2, S8): snap to the step's lattice, clamp to
 * the range, mirror the node the Slider draws from, emit the live move,
 * and when the gesture is over the committed value — once, and only when
 * it differs from the last committed one.
 */
internal fun kayaSliderCommitted(node: KayaNode, raw: Double, final: Boolean) {
    val v = kayaSnappedSlider(raw, node.minValue, node.maxValue, node.step)
    if (v != node.value) {
        node.value = v
        KayaPresent.emitValueChanged(node.tag, v)
    }
    if (final && v != node.committed) {
        node.committed = v
        KayaPresent.emitValueCommitted(node.tag, v)
    }
}

/**
 * The platform's own slider, uncontrolled toward the app (the entry's
 * shape) over the commit path above: `steps` puts Material's stops on
 * the declared step, the drag emits live and the lift commits.
 *
 * KAYA DRAWS THE TICKS. Material's indicators sit only on stops and are
 * reachable only through `steps`, so they can say nothing about a
 * spacing coarser than the step or about a continuous slider with marks
 * (docs/slider-plan.md S5) — one painter for all four shapes, in the
 * Track's own draw scope, whose width is the span Material lerps its own
 * ticks across, so a kaya tick lands where a Material tick would.
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun KayaSliderSurface(node: KayaNode, modifier: Modifier) {
    val colors = SliderDefaults.colors()
    val tickSize = SliderDefaults.TickSize
    Slider(
        modifier = modifier,
        value = node.value.toFloat(),
        onValueChange = { kayaSliderCommitted(node, it.toDouble(), final = false) },
        // The end of the gesture carries no value: the last move already
        // mirrored the settled one.
        onValueChangeFinished = { kayaSliderCommitted(node, node.value, final = true) },
        steps = kayaSliderSteps(node.minValue, node.maxValue, node.step),
        valueRange = node.minValue.toFloat()..node.maxValue.toFloat(),
        colors = colors,
        track = { state ->
            val fractions =
                kayaSliderTickFractions(node.minValue, node.maxValue, node.tickSpacing)
            SliderDefaults.Track(
                sliderState = state,
                colors = colors,
                drawTick = { _, _ -> },
                modifier = Modifier.drawWithContent {
                    drawContent()
                    val span = node.maxValue - node.minValue
                    val reached =
                        if (span > 0) ((node.value - node.minValue) / span).toFloat() else 0f
                    for (fraction in fractions) {
                        drawCircle(
                            color = if (fraction <= reached) colors.activeTickColor
                            else colors.inactiveTickColor,
                            radius = tickSize.toPx() / 2f,
                            center = Offset(size.width * fraction, size.height / 2f),
                        )
                    }
                },
            )
        },
    )
}

// ---- the pickers (docs/datetime-plan.md) ------------------------------------
// The wire packs a date as YYYYMMDD and a time as HHMM (D2). Compose's
// DatePickerState stores its selection as UTC MIDNIGHT MILLIS, so both
// directions go through ZoneOffset.UTC: reading it back through the
// device's zone is the off-by-one-day genre P2 exists to keep out.

/**
 * THE PICKER'S PUBLISHED CLASSIFICATION (docs/datetime-plan.md P4;
 * docs/traps.md, "compose-ui 1.7.5 has no picker Role, and the Material
 * date field publishes an EditText"). Read back by [KayaCompose]'s role
 * reader on BOTH its routes.
 */
val KayaPickerKind = SemanticsPropertyKey<String>("KayaPickerKind")

/** The fixed-digit spellings every scene reads (harness.rs's Date and
 * Time Display); nothing asserts what the field displays (D9). */
internal fun kayaSpelledDate(packed: Long): String = String.format(
    java.util.Locale.ROOT, "%04d-%02d-%02d",
    packed / 10_000, (packed / 100) % 100, packed % 100)

internal fun kayaSpelledTime(packed: Long): String = String.format(
    java.util.Locale.ROOT, "%02d:%02d", packed / 100, packed % 100)

/** `YYYY-MM-DD` to packed, refusing what is not a date (the leap rule
 * java.time knows; a shape the digits do not fit). */
internal fun kayaParseDate(spelled: String): Long? {
    val parts = spelled.split("-")
    if (parts.size != 3 || parts[0].length != 4 ||
        parts[1].length != 2 || parts[2].length != 2
    ) {
        return null
    }
    val year = parts[0].toIntOrNull() ?: return null
    val month = parts[1].toIntOrNull() ?: return null
    val day = parts[2].toIntOrNull() ?: return null
    if (month !in 1..12 || day < 1 ||
        day > java.time.YearMonth.of(year, month).lengthOfMonth()
    ) {
        return null
    }
    return (year * 10_000 + month * 100 + day).toLong()
}

internal fun kayaParseTime(spelled: String): Long? {
    val parts = spelled.split(":")
    if (parts.size != 2 || parts[0].length != 2 || parts[1].length != 2) return null
    val hour = parts[0].toIntOrNull() ?: return null
    val minute = parts[1].toIntOrNull() ?: return null
    if (hour !in 0..23 || minute !in 0..59) return null
    return (hour * 100 + minute).toLong()
}

/** The state's own convention (P2): UTC midnight, never the device's.
 * Held by KayaPickerUtcTest, which check-compose runs — docs/traps.md,
 * "A round-trip test of a SYMMETRIC conversion measures nothing". */
internal fun kayaUtcMillisOf(packed: Long): Long =
    java.time.LocalDate.of(
        (packed / 10_000).toInt(), ((packed / 100) % 100).toInt(), (packed % 100).toInt())
        .atStartOfDay(java.time.ZoneOffset.UTC).toInstant().toEpochMilli()

internal fun kayaPackedOfUtcMillis(millis: Long): Long {
    val date = java.time.Instant.ofEpochMilli(millis)
        .atZone(java.time.ZoneOffset.UTC).toLocalDate()
    return (date.year * 10_000 + date.monthValue * 100 + date.dayOfMonth).toLong()
}

/** The PLATFORM rendering the value in the user's locale and clock
 * preference (D9): kaya spells no format. Noon, so no zone's midnight
 * can move the day. */
private fun kayaShownDate(context: android.content.Context, packed: Long): String {
    val cal = java.util.Calendar.getInstance()
    cal.set((packed / 10_000).toInt(), ((packed / 100) % 100).toInt() - 1,
            (packed % 100).toInt(), 12, 0, 0)
    return android.text.format.DateFormat.getDateFormat(context).format(cal.time)
}

private fun kayaShownTime(context: android.content.Context, packed: Long): String {
    val cal = java.util.Calendar.getInstance()
    cal.set(java.util.Calendar.HOUR_OF_DAY, (packed / 100).toInt())
    cal.set(java.util.Calendar.MINUTE, (packed % 100).toInt())
    return android.text.format.DateFormat.getTimeFormat(context).format(cal.time)
}

/**
 * THE ONE COMMIT PATH, a user's confirm and a driven pick alike
 * (docs/datetime-plan.md D7, D8): CLAMP the date to its bounds (D4, the
 * clamp AppKit performs of its own accord), SNAP the minute to the step
 * (D3 — Compose's TimePicker has no MinuteIncrement, so the arm
 * emulates it), mirror the node the field draws from, emit. A pick that
 * lands on the value already held emits nothing.
 */
internal fun kayaPickerCommitted(node: KayaNode, isTime: Boolean, raw: Long) {
    if (isTime) {
        var packed = raw
        val step = maxOf(1, node.minuteStep)
        if (step > 1) {
            var hour = (raw / 100).toInt()
            var minute = ((raw % 100).toInt() + step / 2) / step * step
            if (minute >= 60) {
                minute = 0
                hour = (hour + 1) % 24
            }
            packed = (hour * 100 + minute).toLong()
        }
        if (packed == node.time) return
        node.time = packed
        KayaPresent.emitTimeChanged(node.tag, packed)
    } else {
        var packed = raw
        if (node.minDate != 0L && packed < node.minDate) packed = node.minDate
        if (node.maxDate != 0L && packed > node.maxDate) packed = node.maxDate
        if (packed == node.date) return
        node.date = packed
        KayaPresent.emitDateChanged(node.tag, packed)
    }
}

/**
 * THE COMPACT FIELD (docs/datetime-plan.md D6) in the one Material
 * idiom material3 1.3.1 has: a read-only field showing the platform's
 * own rendering of the value, with a trailing calendar or clock icon
 * whose tap opens `DatePickerDialog` or a dialog around `TimePicker`
 * (`TimePickerDialog` arrives only in 1.4.0). The dialog's CONFIRM is
 * the commit; a dismissal emits nothing.
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun KayaPickerField(node: KayaNode, a11y: Modifier, boxFill: Modifier) {
    val isTime = node.kind == KayaCompose.KIND_TIME_PICKER
    val packed = if (isTime) node.time else node.date
    val context = LocalContext.current
    // WHAT THIS BODY FORMATTED, stamped for expect_picker: the reading
    // is of the field that rendered, never of a model copy nothing drew
    // from (the tablePresented rule).
    val spelled = if (isTime) kayaSpelledTime(packed) else kayaSpelledDate(packed)
    SideEffect { node.pickerPresented = spelled }
    var open by remember { mutableStateOf(false) }
    val press = remember { MutableInteractionSource() }
    LaunchedEffect(press) {
        press.interactions.collect {
            if (it is PressInteraction.Release) open = true
        }
    }
    OutlinedTextField(
        value = if (isTime) kayaShownTime(context, packed) else kayaShownDate(context, packed),
        onValueChange = {},
        readOnly = true,
        singleLine = true,
        interactionSource = press,
        // The fill rides the FIELD, the select arm's rule. The merge
        // makes the field and its icon ONE node, so an authored label
        // names the control instead of leaving an unnamed box beside it
        // (the checkbox arm's measurement).
        modifier = boxFill.then(a11y)
            .semantics(mergeDescendants = true) { this[KayaPickerKind] = "datetime" },
        trailingIcon = {
            IconButton(onClick = { open = true }) {
                Icon(
                    if (isTime) Icons.Filled.Schedule else Icons.Filled.DateRange,
                    contentDescription = null,
                )
            }
        },
    )
    if (!open) return
    if (isTime) {
        val timeState = rememberTimePickerState(
            initialHour = (packed / 100).toInt(),
            initialMinute = (packed % 100).toInt(),
            is24Hour = android.text.format.DateFormat.is24HourFormat(context),
        )
        AlertDialog(
            onDismissRequest = { open = false },
            confirmButton = {
                TextButton(onClick = {
                    open = false
                    kayaPickerCommitted(
                        node, true, (timeState.hour * 100 + timeState.minute).toLong())
                }) { Text("OK") }
            },
            dismissButton = { TextButton(onClick = { open = false }) { Text("Cancel") } },
            text = { TimePicker(state = timeState) },
        )
        return
    }
    val minYear = if (node.minDate != 0L) {
        (node.minDate / 10_000).toInt()
    } else {
        DatePickerDefaults.YearRange.first
    }
    val maxYear = if (node.maxDate != 0L) {
        (node.maxDate / 10_000).toInt()
    } else {
        DatePickerDefaults.YearRange.last
    }
    val bounds = remember(node.minDate, node.maxDate, minYear, maxYear) {
        object : SelectableDates {
            override fun isSelectableDate(utcTimeMillis: Long): Boolean {
                val day = kayaPackedOfUtcMillis(utcTimeMillis)
                return (node.minDate == 0L || day >= node.minDate) &&
                    (node.maxDate == 0L || day <= node.maxDate)
            }

            override fun isSelectableYear(year: Int): Boolean = year in minYear..maxYear
        }
    }
    val dateState = rememberDatePickerState(
        initialSelectedDateMillis = kayaUtcMillisOf(packed),
        yearRange = minYear..maxYear,
        selectableDates = bounds,
    )
    DatePickerDialog(
        onDismissRequest = { open = false },
        confirmButton = {
            TextButton(onClick = {
                open = false
                dateState.selectedDateMillis?.let {
                    kayaPickerCommitted(node, false, kayaPackedOfUtcMillis(it))
                }
            }) { Text("OK") }
        },
        dismissButton = { TextButton(onClick = { open = false }) { Text("Cancel") } },
    ) {
        DatePicker(state = dateState)
    }
}
