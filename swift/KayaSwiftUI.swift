// KayaSwiftUI: the Swift half of the SwiftUI backend — an interpreter of
// resolved apply-op records over the presentation-side C ABI.

import SwiftUI
import UniformTypeIdentifiers

// Pinned to the KAYA_APPLY_* / KAYA_KIND_* / KAYA_VALUE_* constants in
// kaya.h; spelled here for use in switch patterns.
/// KAYA_SPEC_HASH, asserted against the host's kaya_spec_hash at entry —
/// the runtime half of the stale-artifact guard, presentation side.
let kayaSpecHash: UInt64 = 0x78077d8d3ee2fc37

private let applyCreate: UInt16 = 1
private let applySetProp: UInt16 = 2
private let applyAddChild: UInt16 = 3
private let applyMount: UInt16 = 4
private let applyDestroy: UInt16 = 5
private let applyMoveChild: UInt16 = 6
private let applyCommand: UInt16 = 7
private let applySetWindowProp: UInt16 = 8
private let applyCreateWindow: UInt16 = 9
private let applyDestroyWindow: UInt16 = 10
private let applyPresentAlert: UInt16 = 11
private let applyPresentFileDialog: UInt16 = 24
private let applyCopy: UInt16 = 25
private let applyReadClipboard: UInt16 = 26
/// A1's clear (docs/undo-plan.md §3). TARGETLESS BY DESIGN: the core does
/// not know what is focused and this backend does (kayaScene.focusedId).
private let applyClearUndo: UInt16 = 27
/// The three text-range records (docs/ranges-plan.md). OFFSETS ARRIVING
/// HERE ARE UTF-16 CODE UNITS; the read side is the one place this file
/// converts back to bytes.
private let applyHighlightRanges: UInt16 = 28
private let applySelectRange: UInt16 = 29
private let applyRevealRange: UInt16 = 30
private let applyPresentSaveDialog: UInt16 = 31
private let applySetBrand: UInt16 = 32
private let applySetTypeface: UInt16 = 33
/// The app's declared identity (docs/app-identity-plan.md). The lowering
/// is mac-only; see the `expect_app_icon` arm.
private let applySetAppIdentity: UInt16 = 34
private let applySetColumnHeaders: UInt16 = 35
private let applySetDrawing: UInt16 = 36
/// The stacked fold (docs/adaptive-layout-plan.md D7): { u64 child; u64
/// table } — the child renders inside the grown table's viewport above
/// row 0; table 0 restores it.
private let applyFold: UInt16 = 37
/// The drag declarations (docs/dnd-plan.md D1, D8); the arms are a depth slice.
private let applySetDragSource: UInt16 = 38
private let applySetDropTarget: UInt16 = 39
private let applySetReorderable: UInt16 = 40
/// What a drop settles on (the wire's drag_op).
let kayaDragOpNone: UInt32 = 0
let kayaDragOpCopy: UInt32 = 1
let kayaDragOpMove: UInt32 = 2
/// `tableSorted`'s no-column sentinel (the wire's SORT_NONE).
let kayaSortNone: UInt32 = 0xFFFF_FFFF
private let applyPushEntry: UInt16 = 12
private let applyPopEntry: UInt16 = 13
private let applySetEntryProp: UInt16 = 14
private let applyAddSection: UInt16 = 15
private let applySelectSection: UInt16 = 16
private let applySetSectionProp: UInt16 = 17
private let applyMenuItemCreate: UInt16 = 18
private let applyMenuItemAppend: UInt16 = 19
private let applyMenubarAppend: UInt16 = 20
private let applyContextAttach: UInt16 = 21
private let applyContextAttachNode: UInt16 = 22
private let applySetMenuProp: UInt16 = 23
/// The alert_choice cancel sentinel (deliberately not an index).
private let kayaAlertChoiceCancel: UInt32 = 0xFFFF_FFFF

/// Window properties — their own namespace; window 0 is the primary surface.
private let wpropTitle: UInt32 = 1
private let wpropWidth: UInt32 = 2
private let wpropHeight: UInt32 = 3
private let wpropVetoClose: UInt32 = 4
private let wpropSectionsPresentation: UInt32 = 5
private let wpropPanes: UInt32 = 6
private let wpropDirty: UInt32 = 7
private let wpropInset: UInt32 = 8
private let spropTitle: UInt32 = 1
private let spropIcon: UInt32 = 2
private let spropSymbol: UInt32 = 3
private let sectionsPresentationAuto: Int64 = 0
private let sectionsPresentationBar: Int64 = 1
private let sectionsPresentationSidebar: Int64 = 2
/// Navigation-entry properties — their own typed table.
private let epropTitle: UInt32 = 1
private let epropInterceptBack: UInt32 = 2
/// The menu item vocabulary (spec enum "menu_kind").
private let menuKindMenu: UInt32 = 1
private let menuKindAction: UInt32 = 2
private let menuKindToggle: UInt32 = 3
private let menuKindRadioGroup: UInt32 = 4
private let menuKindRadioOption: UInt32 = 5
private let menuKindSeparator: UInt32 = 6
/// Menu properties (spec::MENU_PROPS) — their own typed table.
private let mpropLabel: UInt32 = 1
private let mpropEnabled: UInt32 = 2
private let mpropChecked: UInt32 = 3
private let mpropValue: UInt32 = 4
private let mpropIcon: UInt32 = 5
private let mpropPrimary: UInt32 = 6
private let mpropShortcut: UInt32 = 7
private let mpropRole: UInt32 = 8
private let mpropSymbol: UInt32 = 9
private let commandClear: UInt32 = 1
private let commandFocus: UInt32 = 2
private let kindColumn: UInt32 = 1
private let kindButton: UInt32 = 2
private let kindLabel: UInt32 = 3
private let kindEntry: UInt32 = 4
private let kindRow: UInt32 = 5
private let kindCheckbox: UInt32 = 6
private let kindSlider: UInt32 = 7
private let kindImage: UInt32 = 8
private let kindScroll: UInt32 = 9
private let kindProgress: UInt32 = 10
private let kindSelect: UInt32 = 11
private let kindRadio: UInt32 = 12
private let kindGrid: UInt32 = 13
private let kindTextarea: UInt32 = 14
private let kindCanvas: UInt32 = 15
private let kindDatePicker: UInt32 = 16
private let kindTimePicker: UInt32 = 17
private let kindLabeled: UInt32 = 18
private let propText: UInt32 = 1
private let propChecked: UInt32 = 2
private let propColumns: UInt32 = 11
/// The accessibility identifier (never spoken) and label (spoken).
private let propA11yId: UInt32 = 12
private let propA11yLabel: UInt32 = 13
private let propA11yHint: UInt32 = 14
/// Help text (docs/tooltip-plan.md T1): the Mac's tooltip, the accessibility hint everywhere; iPadOS draws no tooltip at all.
private let propHelp: UInt32 = 26
/// Which clip representations this widget accepts: a space-separated string
/// of closed kind names and custom format ids. Not a mask.
private let propAccepts: UInt32 = 15
/// Semantic emphasis (docs/styling-plan.md D4); the variant values follow.
private let propRole: UInt32 = 16
private let propInset: UInt32 = 17
/// The pickers' slots (docs/datetime-plan.md D2): packed-decimal I64s —
/// YYYYMMDD for the three dates, HHMM for the time — and a minute count.
private let propDate: UInt32 = 19
private let propTime: UInt32 = 20
private let propMinDate: UInt32 = 21
private let propMaxDate: UInt32 = 22
private let propMinuteStep: UInt32 = 23
/// The slider's step and tick spacing (docs/slider-plan.md S1, S5).
private let propStep: UInt32 = 24
private let propTickSpacing: UInt32 = 25
private let roleDestructive: Int64 = 1
private let roleProminent: Int64 = 2
private let roleHeading: Int64 = 3
private let roleCaption: Int64 = 4
private let rolePlain: Int64 = 5
/// THE SEMANTIC ICON VOCABULARY (spec enum "symbol"). APPEND-ONLY wire
/// values; the SF Symbols spelling each maps to is kayaSFSymbol below.
private let symbolAdd: Int64 = 1
private let symbolRemove: Int64 = 2
private let symbolDelete: Int64 = 3
private let symbolEdit: Int64 = 4
private let symbolDone: Int64 = 5
private let symbolClose: Int64 = 6
private let symbolSearch: Int64 = 7
private let symbolSettings: Int64 = 8
private let symbolRefresh: Int64 = 9
private let symbolInfo: Int64 = 10
private let symbolWarning: Int64 = 11
private let symbolBack: Int64 = 12
private let symbolForward: Int64 = 13
private let symbolMore: Int64 = 14
private let symbolCopy: Int64 = 15
private let symbolPaste: Int64 = 16
private let symbolStar: Int64 = 17
private let symbolLock: Int64 = 18
private let symbolPerson: Int64 = 19
private let symbolHome: Int64 = 20
private let propValue: UInt32 = 3
private let propMin: UInt32 = 4
private let propMax: UInt32 = 5
private let propSource: UInt32 = 6
private let propGrow: UInt32 = 7
private let propSpacing: UInt32 = 8
private let propAlign: UInt32 = 9
private let propAxis: UInt32 = 18
private let propIndeterminate: UInt32 = 10
private let propFill: UInt32 = 27
private let propMinColumnWidth: UInt32 = 28
private let propWrap: UInt32 = 29
// The align enum's wire values (spec enum "align").
private let alignStart: Int64 = 0
private let alignCenter: Int64 = 1
private let alignEnd: Int64 = 2
private let alignStretch: Int64 = 3
private let alignBaseline: Int64 = 4
// THE CANVAS VOCABULARIES, hand-copied APPEND-ONLY wire values held against the
// core's by tools/check-verbs.py. This backend BLITS and never interprets an op
// (docs/canvas-plan.md §1.1), so the render reads none of them.
private let drawMoveTo: Int64 = 1
private let drawLineTo: Int64 = 2
private let drawClose: Int64 = 3
private let drawStroke: Int64 = 4
private let drawFill: Int64 = 5
private let drawFont: Int64 = 6
private let drawText: Int64 = 7
private let paintSeries: Int64 = 1
private let paintSeriesFill: Int64 = 2
private let paintGrid: Int64 = 3
private let paintAxis: Int64 = 4
private let paintGround: Int64 = 5
private let fillNonzero: Int64 = 0
private let fillEvenOdd: Int64 = 1
private let textAlignStart: Int64 = 0
private let textAlignMiddle: Int64 = 1
private let textAlignEnd: Int64 = 2
private let textBaselineAlphabetic: Int64 = 0
private let textBaselineMiddle: Int64 = 1
private let textBaselineTop: Int64 = 2
private let textBaselineBottom: Int64 = 3
/// Named once so the compiler does not report the vocabulary above
/// unused; nothing reads this array.
let kayaCanvasVocabulary: [Int64] = [
    drawMoveTo, drawLineTo, drawClose, drawStroke, drawFill, drawFont, drawText,
    paintSeries, paintSeriesFill, paintGrid, paintAxis, paintGround,
    fillNonzero, fillEvenOdd,
    textAlignStart, textAlignMiddle, textAlignEnd,
    textBaselineAlphabetic, textBaselineMiddle, textBaselineTop, textBaselineBottom,
]
private let valueBool: UInt32 = 1
private let valueI64: UInt32 = 2
private let valueF64: UInt32 = 3
private let valueStr: UInt32 = 4
private let valueBlob: UInt32 = 5

#if os(macOS)
    typealias KayaPlatformImage = NSImage
#else
    typealias KayaPlatformImage = UIImage
#endif

/// THE SEMANTIC ICON TABLE (docs/styling-plan.md D6); `rendered` is the
/// canonical name SwiftUI publishes where it differs (docs/chrome/sf-rendered-names.md).
/// NEVER EDIT `sf` FROM THE SF SYMBOLS APP — tools/check-symbols.py holds it.
let kayaSymbolTable: [(value: Int64, name: String, sf: String, rendered: String?)] = [
    (symbolAdd, "add", "plus", nil),
    (symbolRemove, "remove", "minus", nil),
    (symbolDelete, "delete", "trash", nil),
    (symbolEdit, "edit", "pencil", nil),
    (symbolDone, "done", "checkmark", nil),
    (symbolClose, "close", "xmark", nil),
    (symbolSearch, "search", "magnifyingglass", nil),
    (symbolSettings, "settings", "gearshape", nil),
    (symbolRefresh, "refresh", "arrow.clockwise", nil),
    (symbolInfo, "info", "info.circle", nil),
    (symbolWarning, "warning", "exclamationmark.triangle", nil),
    (symbolBack, "back", "chevron.backward", nil),
    (symbolForward, "forward", "chevron.forward", nil),
    (symbolMore, "more", "ellipsis.circle", nil),
    (symbolCopy, "copy", "doc.on.doc", "document.on.document"),
    (symbolPaste, "paste", "doc.on.clipboard", "document.on.clipboard"),
    (symbolStar, "star", "star", nil),
    (symbolLock, "lock", "lock", nil),
    (symbolPerson, "person", "person", nil),
    (symbolHome, "home", "house", nil),
]

/// The SEMANTIC NAME of a wire symbol value; nil means this interpreter and
/// the core disagree, which the spec hash exists to make impossible.
func kayaSymbolName(_ value: Int64) -> String? {
    kayaSymbolTable.first { $0.value == value }?.name
}

/// The SF Symbols spelling for a wire symbol value.
func kayaSFSymbol(_ value: Int64) -> String? {
    kayaSymbolTable.first { $0.value == value }?.sf
}

/// Why a declared symbol could not be drawn as a glyph. Two causes this
/// reader can tell apart: a value this interpreter's table does not carry,
/// or a row whose SF spelling this OS refuses (the rename trap's blank
/// image), which is why resolution is checked in the RENDER path too.
func kayaPromotedSymbolWhyNot(_ symbol: Int64) -> String {
    guard let sf = kayaSFSymbol(symbol) else {
        return "symbol \(symbol) is not in this interpreter's table"
    }
    return "SF symbol \(sf) does not resolve on this OS"
}

#if os(macOS)
    /// The platform image for a symbol, with THE SEMANTIC NAME as its
    /// accessibility description — which is also the harness's observation
    /// channel. nil when the name does not resolve on this OS.
    func kayaSymbolImage(_ value: Int64) -> NSImage? {
        guard let sf = kayaSFSymbol(value), let name = kayaSymbolName(value) else { return nil }
        return NSImage(systemSymbolName: sf, accessibilityDescription: name)
    }
#endif

@Observable
final class KayaNode: Identifiable {
    let id: UInt64
    let kind: UInt32
    let tag: [UInt8]
    var text = ""
    /// a11yId lowers to accessibilityIdentifier and is never spoken;
    /// a11yLabel IS what VoiceOver reads. Empty means unset.
    var a11yId = ""
    var a11yLabel = ""
    var a11yHint = ""
    var help = ""
    /// One child's cross-axis stretch (docs/layout-knobs-plan.md §1): nil
    /// leaves the kind's default to the arm that draws it.
    var fill: Bool? = nil
    /// An auto grid's floor, read when `columns` is 0
    /// (docs/layout-knobs-plan.md §3).
    var minColumnWidth: Double = 0
    /// A row that flows its children onto new lines
    /// (docs/layout-knobs-plan.md §2).
    var wrap = false
    /// Semantic emphasis (docs/styling-plan.md D4), 0 = none — never a raw
    /// color.
    var role: Int64 = 0
    /// A container's own padding (docs/styling-plan.md D3): DIP between its
    /// bounds and its children, uniform. 0 = flush, every container's default.
    var inset: Double = 0
    /// The widget's accept list, verbatim; empty means it takes nothing.
    var accepts = ""
    /// The drag declarations (docs/dnd-plan.md D1, D8): what this widget hands
    /// over and allows, what it performs as a destination, and whether its
    /// rows reorder within their collection.
    var dragPayload: KayaDragPayload?
    var dragOps: UInt32 = 0
    var dropOps: UInt32 = 0
    var reorderable = false
    /// The identity the dnd apply twins carry for a kind whose create
    /// tag is empty (docs/dnd-plan.md D1): what the emits hand back.
    var dndTag: [UInt8] = []
    var identityTag: [UInt8] { dndTag.isEmpty ? tag : dndTag }
    var checked = false
    var value = 0.0
    var minValue = 0.0
    var maxValue = 1.0
    /// The slider's granularity and drawn ticks (0 = none), and the value the
    /// last gesture SETTLED ON — what value_committed compares against
    /// (docs/slider-plan.md S1, S2, S5).
    var step = 0.0
    var tickSpacing = 0.0
    var committed = 0.0
    /// The pickers' packed values (docs/datetime-plan.md D2); 0 is "no
    /// bound" for the range, and 1 the step's default.
    var date: Int64 = 0
    var minDate: Int64 = 0
    var maxDate: Int64 = 0
    var time: Int64 = 0
    var minuteStep = 1
    // The decoded native image (nil is the placeholder class) and its size
    // as the harness's "WxH" observation ("0x0" before a source lands or
    // after a failed decode).
    var image: KayaPlatformImage?
    var imageSize = "0x0"
    // THE CANVAS BUFFER the core rasterized (docs/canvas-plan.md §1.1):
    // premultiplied RGBA8 with the scale it was drawn at. nil is
    // declared-and-empty, which stays PRESENT (tools/check-empty-child.py).
    var drawing: CGImage?
    var drawingScale: CGFloat = 1
    // The scroll observations (scroll viewports only), recorded by the
    // render's readers, never a model copy.
    var scrollViewportH = 0.0
    /// The ScrollView's OWN width — the real scrolling surface, which
    /// expect_breadth reads for a scroll instead of its flex cell.
    var scrollViewportW = 0.0
    var scrollContentH = 0.0
    var scrollContentMaxY = 0.0
    /// Progress-only: the platform's activity mode (Value carries the
    /// determinate fraction).
    var indeterminate = false
    /// Grid-only: how many columns children fill row-major.
    var columns = 1
    /// This child's flex weight within its row/column; 0 is natural size.
    /// See Prop::Grow in protocol.rs.
    var grow = 0.0
    /// This container's inter-child gap on its main axis (default 8).
    var spacing = 8.0
    /// This container's cross-axis child placement (align wire values;
    /// 0 = start, the normalized default).
    var align: Int64 = 0
    /// This container's arrangement axis (axis wire values; nil = the
    /// creation kind's own — row horizontal, column vertical). One node,
    /// two constructor spellings (docs/adaptive-layout-plan.md D1).
    var axis: Int64? = nil
    /// TEXT RANGES (textarea only), in UTF-16 code units — the unit NSRange
    /// speaks. `highlightsFor` is the text they were declared against: the
    /// lowering paints only while the widget still holds it, so any edit
    /// drops them (spec.rs's Prop::Highlights, docs/ranges-plan.md).
    var highlights: [NSRange] = []
    var highlightsFor: String?
    /// The two one-shot effects carry a SEQUENCE NUMBER rather than a
    /// consumed optional: `updateNSView` runs many times for one model change
    /// and must not write the model back.
    var selectRequest: NSRange?
    var selectSeq = 0
    var revealRequest: NSRange?
    var revealSeq = 0
    var children: [KayaNode] = []
    /// The stacked fold (D7): non-zero = the table whose viewport this
    /// node renders inside. Identity stays here — only layout moves.
    var foldedInto: UInt64 = 0
    /// The table side of the same record: folded content in sibling
    /// order, rendered above row 0 inside this table's scroll.
    var foldedChildren: [KayaNode] = []
    /// The children this container LAYS OUT — a folded child renders in
    /// its table's viewport instead, while every harness read and
    /// addressing path keeps seeing `children`.
    var laidOut: [KayaNode] { children.filter { $0.foldedInto == 0 } }
    /// TABLE (docs/tables-plan.md): the declared header bar — titles in
    /// visual order, the indicator column (kayaSortNone for none) and
    /// its direction, and the core-minted sort tag a header click hands
    /// back verbatim. Empty titles = not a table.
    var tableColumns: [String] = []
    var tableSorted: UInt32 = 0xFFFF_FFFF
    var tableDirection: UInt32 = 0
    var sortTag: [UInt8] = []
    /// What the TABLE PATH actually presented — written by the render,
    /// never a model echo (the scroll-geometry precedent), so
    /// expect_columns proves the table rendered rather than that the
    /// wire arrived.
    var tablePresented = ""
    /// THE MAC NATIVE TIER'S CONTENT WIDTH, published by the tier that laid
    /// the columns out so the hugging container above can widen to it; 0 =
    /// nothing measured yet (docs/deferred.md's native-ellipsize entry).
    var tableContentWidth: Double = 0
    /// docs/traps.md, "A table viewport contains rows".
    var tableGeometryEpoch = 0
    var tableCellFrames: [String: KayaTableCellObservation] = [:]
    var tableViewport: KayaTableViewportObservation?

    init(id: UInt64, kind: UInt32, tag: [UInt8]) {
        self.id = id
        self.kind = kind
        self.tag = tag
    }
}

struct KayaTableCellObservation {
    let generation: Int
    let frame: CGRect
}

struct KayaTableViewportObservation {
    let generation: Int
    let frame: CGRect
    let synthesized: Bool
}

/// One presentation surface: the primary (id 0, always present) or a created
/// auxiliary. Materializes hidden; mounting a root presents it.
@Observable
final class KayaWindowModel: Identifiable {
    let id: UInt64
    var root: KayaNode?
    var title: String
    var width: Double?
    var height: Double?
    /// Who owns the chrome close — see WindowProp::VetoClose.
    var vetoClose = false
    /// The window's navigation stack, bottom to top (DESIGN.md, Navigation).
    /// NavigationStack's path derives from this; the core-owned stack is the
    /// source of truth.
    var entries: [KayaEntryModel] = []
    /// The window's section set (add order) and selection: presentation
    /// context, not lifecycle — every section's root stays alive while
    /// covered.
    var sections: [KayaSectionModel] = []
    var selectedSection: UInt64?
    /// The pane CEILING this window asks for (wprop 6; DESIGN.md,
    /// Adaptive panes). How many materialize is the platform's answer.
    var panes: Int64 = 1
    /// Whether this surface holds UNSAVED WORK (wprop 7; docs/dirty-plan.md).
    /// macOS lowers it to NSWindow.isDocumentEdited and nothing else; iOS
    /// lowers it to nothing. The declared title is never rewritten.
    var dirty = false
    /// The window CONTENT INSET (wprop 8; docs/styling-plan.md D3) — LAYOUT,
    /// not appearance: padding inside the mounted root, 16 unless the app says
    /// otherwise, 0 for full bleed. Every render site reads this.
    var inset: Double = 16
    /// The presentation the view layer ACTUALLY rendered — "split",
    /// "split3" or "stacked" — stamped by the arm that ran, never derived
    /// from `panes` or `formFactor` (check-verbs' stamped-observation rule).
    var splitPresentation = "stacked"
    /// THE ARM THE SECTIONS RENDER ACTUALLY TOOK — "bar" or "sidebar",
    /// stamped by the body that rendered (the stamped-observation rule).
    var sectionsRendered = ""
    /// The ADVISORY presentation hint (wprop 5): auto | bar | sidebar.
    var sectionsPresentation: Int64 = 0
    /// The window's command catalog (DESIGN.md, Menus): top-level grouping
    /// nodes in menubar-append order.
    var menubar: [KayaMenuItemModel] = []
    /// The window's live FORM FACTOR — the adaptivity axis, never the operating
    /// system (DESIGN.md, "Form factor and adaptivity"). `unknown` is the
    /// pre-appearance value and NO LOWERING MAY BRANCH ON IT.
    var formFactor: KayaFormFactor = .unknown
    /// Which catalog lowering ACTUALLY rendered for this window; each arm
    /// stamps its own value and nothing derives it from `formFactor`
    /// (the stamped-observation rule).
    var menuPresentation: KayaMenuPresentation = .none

    init(id: UInt64, title: String = "") {
        self.id = id
        self.title = title
    }
}

/// The window size classes kaya lowers against: the two-valued intersection
/// of what every backend already exposes, rather than a new scale.
enum KayaFormFactor: String {
    case unknown
    case compact
    case regular
}

/// How a window's command catalog is currently materialized. `bar` is a real
/// menu bar, `overflow` the compact top-bar treatment, `none` an empty
/// catalog.
enum KayaMenuPresentation: String {
    case none
    case bar
    case overflow
}

/// One menu item: kind fixed at create, every applicable prop live. This
/// model is the backend's retained MIRROR — user chrome writes checked/value
/// here BEFORE emitting, because a native rebuild must start from the
/// post-user mirror (docs/traps.md).
@Observable
final class KayaMenuItemModel: Identifiable {
    let id: UInt64
    let kind: UInt32
    var label = ""
    var enabled = true
    /// Toggle only (the checkbox contract).
    var checked = false
    /// Radio group only: the selected option index (choice contract).
    var value = 0.0
    /// Phone-promotion hint on actions; INERT on desktops.
    var primary = false
    /// The canonical shortcut spelling (root-validated), "" = none.
    var shortcut = ""
    /// A standard-command role from the closed vocabulary, "" = none. macOS
    /// relocates `settings` into the application menu; the item keeps its
    /// authored place in the model.
    var role = ""
    /// Optional icon, used by phone promotion.
    var icon: KayaPlatformImage?
    /// The SEMANTIC ICON's wire value, 0 = none (docs/styling-plan.md D6).
    /// Stored as the VALUE and resolved to a glyph at build time: the mac bar
    /// is rebuilt from this model on every catalog mutation, and a cached
    /// image would survive a lowering that stopped working.
    var symbol: Int64 = 0
    var children: [KayaMenuItemModel] = []

    init(id: UInt64, kind: UInt32) {
        self.id = id
        self.kind = kind
    }
}

/// One section: a peer root inside a window's section set, ALL retained —
/// switching is selection, not lifecycle. Carries its own navigation stack
/// (DESIGN.md, Sections).
@Observable
final class KayaSectionModel: Identifiable {
    let id: UInt64
    var root: KayaNode?
    var title = ""
    /// The switcher item's SEMANTIC ICON, 0 = none.
    var symbol: Int64 = 0
    var entries: [KayaEntryModel] = []

    init(id: UInt64) {
        self.id = id
    }
}

/// One navigation entry: a pushed scene root inside a window's stack.
/// Retained while covered (its widgets stay live); destroyed at pop.
@Observable
final class KayaEntryModel: Identifiable {
    let id: UInt64
    var root: KayaNode?
    var title = ""
    /// The close-veto class transplanted to POP: armed, the back affordance
    /// emits back_requested and nothing pops until the app answers.
    var interceptBack = false

    init(id: UInt64) {
        self.id = id
    }
}

@Observable
final class KayaSceneModel {
    /// Live surfaces by id; the primary starts with the process name as its
    /// title, exactly what an untitled WindowGroup shows.
    var windows: [UInt64: KayaWindowModel] = [
        0: KayaWindowModel(id: 0, title: ProcessInfo.processInfo.processName)
    ]

    var nodes: [UInt64: KayaNode] = [:]  // main actor only
    var parents: [UInt64: UInt64] = [:]
    /// Live navigation entries by surface id. `navEntries`, not `entries` —
    /// that name is the ENTRY-widget registry below.
    var navEntries: [UInt64: KayaEntryModel] = [:]
    /// GROUPED SCREENS (docs/adaptive-layout-plan.md D7.5): the sets the
    /// surface roots consult; `groupedFlows` names each grouped screen's
    /// PRIMARY FLOW, whose children become the section stream. Rewritten
    /// at every apply batch tail, never derived in a body.
    var groupedEntries: Set<UInt64> = []
    var groupedWindows: Set<UInt64> = []
    var groupedFlows: Set<UInt64> = []
    /// entry id -> the window whose stack holds it.
    var entryWindow: [UInt64: UInt64] = [:]
    /// Live sections by surface id (the one surface namespace), and section
    /// id -> hosting window.
    var sectionsById: [UInt64: KayaSectionModel] = [:]
    var sectionWindow: [UInt64: UInt64] = [:]
    /// Menu items by id — their OWN id space, never widget, node or surface
    /// ids.
    var menuItems: [UInt64: KayaMenuItemModel] = [:]
    /// child item id -> parent item id: the enablement AND-chain walks this.
    var menuParents: [UInt64: UInt64] = [:]
    /// Context catalogs by ANCHOR widget id, in attach order.
    var contextRoots: [UInt64: [KayaMenuItemModel]] = [:]
    /// The anchor copy's key-path bytes by widget id — the NOUN every
    /// activation from that anchor stamps; absent for live-widget anchors.
    var contextNouns: [UInt64: [UInt8]] = [:]
    // The focus command's landing spot; expect_focused reads it back.
    var focusedId: UInt64?
    /// The DERIVED brand accent (apply 32), eleven packed sRGB words — seed +
    /// light five + dark five, in the wire's order. A REQUEST, uniformly
    /// (docs/styling-plan.md D2): the system accent wins unless the user chose
    /// multicolor.
    var brand: [UInt32]?
    /// The RESOLVED brand typeface family (apply 33), or nil — deliberately
    /// one state for "no app asked" and "this platform has not got that
    /// family" (docs/styling-plan.md Slice 2b). Written ONCE, by the apply
    /// arm, after the blob registration and the presence gate.
    var typefaceFamily: String?
    /// What the app ASKED for, kept only so a failed resolution can say so.
    /// NEVER read by a lowering and never by the observation — a request
    /// echoed back looks exactly like a swap that happened.
    var typefaceRequested: String?
    /// The DECLARED app identity (apply 34), or nil. Both halves are the
    /// request as it arrived, never a resolution (docs/app-identity-plan.md
    /// I8).
    var appIdentityName: String?
    var appIdentityIcon: Data?
    // Per-kind registries in creation order; the harness names targets as
    // kind#index.
    var buttons: [KayaNode] = []
    var checkboxes: [KayaNode] = []
    var labels: [KayaNode] = []
    /// NAMED entryWidgets, not `entries`: a window's `entries` is its
    /// NAVIGATION STACK, and while this shared the name the wrong one
    /// compiled clean.
    var entryWidgets: [KayaNode] = []
    var sliders: [KayaNode] = []
    var datePickers: [KayaNode] = []
    var timePickers: [KayaNode] = []
    var images: [KayaNode] = []
    var canvases: [KayaNode] = []
    var columns: [KayaNode] = []
    var rows: [KayaNode] = []
    var scrolls: [KayaNode] = []
    var progresses: [KayaNode] = []
    var selects: [KayaNode] = []
    var radios: [KayaNode] = []
    var grids: [KayaNode] = []
    var textareas: [KayaNode] = []
    var labeleds: [KayaNode] = []
}

// The single-window spellings, forwarding to the primary surface. An
// extension keeps them out of @Observable's macro expansion.
extension KayaSceneModel {
    var root: KayaNode? {
        get { windows[0]?.root }
        set { windows[0]?.root = newValue }
    }
    var windowTitle: String {
        get { windows[0]?.title ?? "" }
        set { windows[0]?.title = newValue }
    }
    var windowWidth: Double? {
        get { windows[0]?.width }
        set { windows[0]?.width = newValue }
    }
    var windowHeight: Double? {
        get { windows[0]?.height }
        set { windows[0]?.height = newValue }
    }
}

/// Presentation actions and native handles, stashed from the view side
/// (main actor only).
var kayaOpenWindow: ((UInt64) -> Void)?
var kayaDismissWindow: ((UInt64) -> Void)?
/// The live ScrollViewReader proxies by scroll node id (main actor).
var kayaScrollProxies: [UInt64: ScrollViewProxy] = [:]
/// Grid cell leading edges by child node id, in the grid's own coordinate
/// space (main actor): geometry, never the model's columns copy.
var kayaCellMinX: [UInt64: Double] = [:]
/// Mounts that arrived before the environment actions were stashed; drained
/// by KayaRoot's onAppear.
var kayaPendingOpens: [UInt64] = []
enum KayaSelftestAdmissionState: Equatable {
    case waiting
    case grace
    case started
}

enum KayaSelftestAdmissionEffect: Equatable {
    case none
    case armGrace
    case start
}

// docs/traps.md, "A vacuous opening expect is not Swift scene admission".
func kayaSelftestAdmissionTransition(
    _ state: KayaSelftestAdmissionState,
    mounted: Bool,
    hasNodes: Bool,
    graceExpired: Bool,
    startupExpired: Bool = false
) -> (KayaSelftestAdmissionState, KayaSelftestAdmissionEffect) {
    if state == .started { return (.started, .none) }
    if mounted { return (.started, .start) }
    // THE STARTUP RESCUE — docs/traps.md, "A guest that never sends a
    // node-bearing batch is silent for its whole leg": the deadline
    // forces the start, and the script's own expects then say why.
    if startupExpired { return (.started, .start) }
    if graceExpired {
        return state == .grace ? (.started, .start) : (state, .none)
    }
    if state == .waiting && hasNodes { return (.grace, .armGrace) }
    return (state, .none)
}

private var kayaSelftestAdmissionState = KayaSelftestAdmissionState.waiting
private let kayaSelftestUnmountedGrace: TimeInterval = 5.0
/// The startup rescue's deadline: generous against slow guests (whose
/// batches admit them far earlier anyway), tiny against the 120s leg
/// timeout the silence used to burn whole.
private let kayaSelftestStartupDeadline: TimeInterval = 10.0
private var kayaSelftestStartupArmed = false

/// Armed ONCE from the root's appear — batch-independent, so a guest
/// that never sends one still reaches a verdict.
func kayaArmSelftestStartupDeadline() {
    dispatchPrecondition(condition: .onQueue(.main))
    guard !kayaSelftestStartupArmed else { return }
    kayaSelftestStartupArmed = true
    guard ProcessInfo.processInfo.environment["KAYA_SELFTEST"] != nil else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + kayaSelftestStartupDeadline) {
        kayaDriveSelftestAdmission(startupExpired: true)
    }
}

/// A LAYOUT TRACE, off unless asked for: one run shows the whole chain —
/// flex extent, cell bounds, scroll box proposal, the clip the viewport
/// reporter sees (docs/deferred.md, the grown-table entry).
let kayaTraceOn = ProcessInfo.processInfo.environment["KAYA_LAYOUT_TRACE"] != nil
@inline(__always) func kayaTrace(_ msg: @autoclosure () -> String) {
    if kayaTraceOn { kayaDiag("TRACE " + msg()) }
}

/// THE TITLE WATCH'S INSTRUMENT (docs/deferred.md, the mac portfolio
/// entry; the android one carries the same): the last pop's time, and
/// the last click with the stack depth it saw, so a title that did not
/// move says whether the push reached the model or the surface lagged.
nonisolated(unsafe) var kayaLastPopAt: Double = 0
nonisolated(unsafe) var kayaLastClick: (target: String, at: Double, entries: Int)? = nil

func kayaDiag(_ msg: String) {
    let line = String(format: "KAYA_DIAG %.3f %@\n", Date().timeIntervalSince1970, msg)
    FileHandle.standardError.write(line.data(using: .utf8)!)
}

/// THE VERB TRACE, this interpreter's copy of crates/kaya/src/vtrace.rs: every
/// attempt of every step, in a ring, written ONLY WHEN THE RUN FAILS to
/// `KAYA_VERB_TRACE`'s file (relative: under kayaTempDir()). tools/check-verbs.py.
enum KayaVTrace {
    static let cap = 2048
    private static let lock = NSLock()
    nonisolated(unsafe) private static var on = false
    nonisolated(unsafe) private static var path = ""
    nonisolated(unsafe) private static var start = Date()
    nonisolated(unsafe) private static var step = 0
    nonisolated(unsafe) private static var steps: [String] = []
    nonisolated(unsafe) private static var recs:
        [(atMs: Int, step: Int, verb: String, attempt: Int, what: String)] = []
    nonisolated(unsafe) private static var head = 0
    nonisolated(unsafe) private static var dropped = 0

    static func begin(_ at: Date) {
        let named = ProcessInfo.processInfo.environment["KAYA_VERB_TRACE"] ?? ""
        lock.lock()
        defer { lock.unlock() }
        on = !named.isEmpty
        path =
            named.isEmpty || named.hasPrefix("/")
            ? named : (kayaTempDir() as NSString).appendingPathComponent(named)
        start = at
        step = 0
        steps = []
        recs = []
        head = 0
        dropped = 0
    }

    static func step(_ ordinal: Int, _ text: String) {
        lock.lock()
        defer { lock.unlock() }
        if !on { return }
        step = ordinal
        while steps.count <= ordinal { steps.append("") }
        steps[ordinal] = text
    }

    /// One attempt of a step, numbered from 1 (the retry wrapper is the
    /// attempt point, so every step's attempts are on the record).
    static func attempt(_ verb: String, _ n: Int, _ what: String) {
        lock.lock()
        defer { lock.unlock() }
        if !on { return }
        let rec = (
            atMs: Int(Date().timeIntervalSince(start) * 1000), step: step, verb: verb,
            attempt: n, what: what
        )
        if recs.count < cap {
            recs.append(rec)
        } else {
            recs[head] = rec
            head = (head + 1) % cap
            dropped += 1
        }
    }

    private static func quoted(_ s: String) -> String {
        "\""
            + s.replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ") + "\""
    }

    /// Append the whole ring under `reason`. FAILURE ONLY — the failed
    /// verdict and the step watchdog's fire path are the two callers.
    static func dump(_ reason: String) {
        lock.lock()
        defer { lock.unlock() }
        if !on || path.isEmpty { return }
        let now = Int(Date().timeIntervalSince(start) * 1000)
        var out =
            "KAYA_VERB_TRACE: dump reason=\(quoted(reason)) t=\(now) records=\(recs.count) dropped=\(dropped) steps=\(steps.count)\n"
        for (i, text) in steps.enumerated() {
            out += "KAYA_VERB_TRACE: step=\(i) text=\(quoted(text))\n"
        }
        for r in Array(recs[head...]) + Array(recs[..<head]) {
            out += "KAYA_VERB_TRACE: t=\(r.atMs) step=\(r.step) verb=\(r.verb) try=\(r.attempt) what=\(quoted(r.what))\n"
        }
        // O_APPEND and ONE write, the Rust ring's rule.
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        if fd < 0 { return }
        let bytes = Array(out.utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        FileHandle.standardError.write(
            Data(
                "KAYA_HARNESS: verb trace (\(recs.count) records, \(dropped) dropped) appended to \(path)\n"
                    .utf8))
    }
}

#if os(macOS)
    /// The app-side state that could explain a dropped scene request.
    func kayaDiagAppState() -> String {
        let app = NSApplication.shared
        let wins = app.windows.map {
            "num=\($0.windowNumber),t='\($0.title)',vis=\($0.isVisible),cls=\(type(of: $0))"
        }.joined(separator: " | ")
        return "active=\(app.isActive) policy=\(app.activationPolicy().rawValue) "
            + "modal=\(app.modalWindow?.windowNumber ?? -1) "
            + "registered=\(Array(kayaNSWindows.keys).sorted()) "
            + "sceneWindows=\(Array(kayaScene.windows.keys).sorted()) "
            + "appWindows=[\(wins)]"
    }
#endif
/// The temp directory THE GUEST WILL USE — `$TMPDIR` or `/tmp`, which is what
/// every guest language's own API returns. DELIBERATELY NOT
/// NSTemporaryDirectory(), which ignores `$TMPDIR` and so disagrees with the
/// guest under `nix develop` (docs/traps.md).
func kayaTempDir() -> String {
    #if os(iOS)
        // NOT the temp directory on iOS: `TMPDIR` is inside the container and
        // the picker browses PROVIDERS, so a picker aimed there opens somewhere
        // else with no error (docs/file-dialogs-plan.md, tools/ios/Info.plist.in).
        return (NSHomeDirectory() as NSString).appendingPathComponent("Documents")
    #else
        return ProcessInfo.processInfo.environment["TMPDIR"].map {
            ($0 as NSString).standardizingPath
        } ?? "/tmp"
    #endif
}

// ---- Text ranges: the ONE place this file converts an offset -------
//
// A READ answers in UTF-8 bytes and refuses an offset inside a character rather
// than moving it: `String.Index(utf16Offset:in:)` ROUNDS (docs/ranges-units.md §7).

/// A UTF-16 code-unit offset as a UTF-8 byte offset into the same text.
/// Negative when the offset is not on a character boundary.
func kayaByteOffset(_ text: String, _ utf16: Int) -> Int {
    guard utf16 >= 0, utf16 <= (text as NSString).length else { return -1 }
    let index = String.Index(utf16Offset: utf16, in: text)
    guard let scalar = index.samePosition(in: text.unicodeScalars) else { return -1 }
    return text.utf8.distance(from: text.startIndex, to: scalar)
}

/// The inverse, for the one verb that arrives carrying byte offsets
/// (expect_revealed, which compares against the viewport's unit).
func kayaUtf16Offset(_ text: String, _ byte: Int) -> Int {
    guard byte >= 0, byte <= text.utf8.count else { return -1 }
    guard
        let index = text.utf8.index(
            text.startIndex, offsetBy: byte, limitedBy: text.endIndex),
        let scalar = index.samePosition(in: text.unicodeScalars)
    else { return -1 }
    return scalar.utf16Offset(in: text)
}

/// A set of platform ranges in the harness's spelling:
/// `<start>:<end>=<covered text>` per range, `|`-joined, ascending. THE COVERED
/// TEXT IS NOT DECORATION: offsets alone invert the lowering's own conversion.
func kayaRangeSpelling(_ text: String, _ ranges: [NSRange]) -> String {
    let ns = text as NSString
    return
        ranges
        .sorted { $0.location < $1.location }
        .map { range -> String in
            let start = kayaByteOffset(text, range.location)
            let end = kayaByteOffset(text, range.location + range.length)
            guard start >= 0, end >= 0 else {
                // Named, not silently coerced: it says which endpoint
                // split a character.
                return "split@\(range.location):\(range.location + range.length)="
            }
            return "\(start):\(end)=" + ns.substring(with: range)
        }
        .joined(separator: "|")
}

// A depth stub is a CALL, never a sentence — tools/check-stubs.py reads
// it; the platform argument exists because this one file serves mac AND iOS.
func kayaDepthStub(_ scene: String, on platform: String) -> Never {
    fatalError(
        "kaya: the \(scene) scene is not yet materialized on \(platform) — "
            + "it is a depth slice; see CLAUDE.md's sequencing")
}

// ---- The clipboard ------------------------------------------------
//
// Values arrive in kaya's canonical order, which IS a pasteboard consumer's
// preference order, so this writes them as it reads them (docs/clipboard-plan.md).

/// One representation as the Swift side holds it. Swift owns the storage; the
/// C struct only ever borrows it for the length of one call.
struct KayaClipValue {
    var clip: UInt32
    var text: String?
    var id: String?
    var bytes: Data?
    var locators: [String] = []
    var names: [String] = []
}

/// Lend a `KayaClipValue` to the C struct for the length of one call. strdup
/// because the C side reads the strings during the call and nothing may
/// outlive it; freed on the way out.
func kayaWithRepresentation<T>(
    _ value: KayaClipValue?, _ body: (UnsafePointer<KayaRepresentation>?) -> T
) -> T {
    guard let value else { return body(nil) }
    let textBuf = value.text.map { strdup($0) } ?? nil
    let idBuf = value.id.map { strdup($0) } ?? nil
    let locatorBufs: [UnsafeMutablePointer<CChar>?] = value.locators.map { strdup($0) }
    let nameBufs: [UnsafeMutablePointer<CChar>?] = value.names.map { strdup($0) }
    defer {
        free(textBuf)
        free(idBuf)
        for b in locatorBufs { free(b) }
        for b in nameBufs { free(b) }
    }
    var locators: [UnsafePointer<CChar>?] = locatorBufs.map { $0.map { UnsafePointer($0) } }
    var names: [UnsafePointer<CChar>?] = nameBufs.map { $0.map { UnsafePointer($0) } }
    let bytes = value.bytes ?? Data()
    return bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        locators.withUnsafeMutableBufferPointer { l in
            names.withUnsafeMutableBufferPointer { n in
                var rep = KayaRepresentation(
                    clip: value.clip,
                    text: textBuf.map { UnsafePointer($0) },
                    id: idBuf.map { UnsafePointer($0) },
                    bytes: value.bytes == nil ? nil : raw.bindMemory(to: UInt8.self).baseAddress,
                    len: UInt(bytes.count),
                    locators: l.baseAddress,
                    names: n.baseAddress,
                    count: UInt(value.locators.count))
                return withUnsafePointer(to: &rep) { body($0) }
            }
        }
    }
}

/// The four closed kinds by the names an accept list spells them — the same
/// vocabulary the core parses (wire.rs, parse_accept_list).
private let kayaClipText: UInt32 = 1
private let kayaClipHtml: UInt32 = 2
private let kayaClipImage: UInt32 = 4
private let kayaClipFiles: UInt32 = 8
private let kayaClipCustom: UInt32 = 16

/// Split an accept list into the closed kinds and the custom ids it names, in
/// the order the list gave them.
func kayaParseAcceptList(_ list: String) -> (kinds: UInt32, custom: [String]) {
    var kinds: UInt32 = 0
    var custom: [String] = []
    for token in list.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
        switch token {
        case "text": kinds |= kayaClipText
        case "html": kinds |= kayaClipHtml
        case "image": kinds |= kayaClipImage
        case "files": kinds |= kayaClipFiles
        default: custom.append(token)
        }
    }
    return (kinds, custom)
}

/// A drag source's declared payload: the copy record's representations
/// (docs/dnd-plan.md D1).
struct KayaDragPayload {
    var text: String?
    var html: String?
    var image: Data?
    var files: [String] = []
    var custom: [(String, Data)] = []
}

#if os(macOS)
    /// Every live drag-and-drop surface's view, by widget id — main thread
    /// only, like every registry here; the `drag` verb drives the real arms
    /// through it (docs/dnd-plan.md D10).
    nonisolated(unsafe) var kayaDragSurfaces: [UInt64: KayaDragDropView] = [:]

    /// kaya's row payload for a reorder (docs/dnd-plan.md D8): the moved
    /// row's key path, dot-joined, under a kaya-private id.
    let kayaRowDragType = "dev.kaya/row"

    func kayaDragOpMask(_ op: NSDragOperation) -> UInt32 {
        var mask: UInt32 = 0
        if op.contains(.copy) { mask |= kayaDragOpCopy }
        if op.contains(.move) { mask |= kayaDragOpMove }
        return mask
    }

    func kayaNSDragOperation(_ mask: UInt32) -> NSDragOperation {
        var op: NSDragOperation = []
        if mask & kayaDragOpCopy != 0 { op.insert(.copy) }
        if mask & kayaDragOpMove != 0 { op.insert(.move) }
        return op
    }

    /// Write a payload onto a board AT BOARD LEVEL — the clipboard arm's route
    /// and the only one that carries a MIME-shaped id (docs/traps.md: A
    /// MIME-shaped id is not a UTI on macOS).
    func kayaWriteDragPayload(_ board: NSPasteboard, _ payload: KayaDragPayload) {
        let urls = payload.files.compactMap { URL(string: $0) }
        board.clearContents()
        var types: [NSPasteboard.PasteboardType] = payload.custom.map { .init($0.0) }
        if !urls.isEmpty { types.append(.fileURL) }
        if payload.image != nil { types.append(.png) }
        if payload.html != nil { types.append(.html) }
        if payload.text != nil || !urls.isEmpty { types.append(.string) }
        board.declareTypes(types, owner: nil)
        for (id, bytes) in payload.custom {
            board.setData(bytes, forType: NSPasteboard.PasteboardType(id))
        }
        if let url = urls.first { board.setString(url.absoluteString, forType: .fileURL) }
        if let image = payload.image { board.setData(image, forType: .png) }
        if let html = payload.html { board.setString(html, forType: .html) }
        if let text = payload.text {
            board.setString(text, forType: .string)
        } else if !urls.isEmpty {
            board.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        }
    }

    /// What a board offers, in kaya's vocabulary: the closed kinds as a mask
    /// and the custom ids among `accepted` it carries.
    func kayaBoardOffer(_ board: NSPasteboard, customAccepted: [String]) -> (UInt32, [String]) {
        let types = board.types?.map(\.rawValue) ?? []
        var mask: UInt32 = 0
        if types.contains(kayaClipUTI("text")) || types.contains(NSPasteboard.PasteboardType.string.rawValue) {
            mask |= kayaClipText
        }
        if types.contains(kayaClipUTI("html")) { mask |= kayaClipHtml }
        if types.contains(kayaClipUTI("image")) || types.contains(NSPasteboard.PasteboardType.tiff.rawValue) {
            mask |= kayaClipImage
        }
        if types.contains(kayaClipUTI("files")) { mask |= kayaClipFiles }
        return (mask, customAccepted.filter { types.contains($0) })
    }

    /// The one AppKit view behind a drag-and-drop widget: a SOURCE when its
    /// node declares a payload, a DESTINATION when its node declares
    /// operations, and BOTH for a row of a reorderable For (docs/dnd-plan.md
    /// D7, D8). The verdict is the core's one pure function; nothing here
    /// decides.
    final class KayaDragDropView: NSView, NSDraggingSource {
        weak var node: KayaNode?
        weak var reorderIn: KayaNode?
        private var pressedAt: NSPoint?

        override var acceptsFirstResponder: Bool { false }

        func refreshRegistration() {
            guard let node else { return }
            var types: [NSPasteboard.PasteboardType] = []
            if node.dropOps != 0 {
                let (kinds, custom) = kayaParseAcceptList(node.accepts)
                types += custom.map { .init($0) }
                if kinds & kayaClipText != 0 { types.append(.string) }
                if kinds & kayaClipHtml != 0 { types.append(.html) }
                if kinds & kayaClipImage != 0 { types += [.png, .tiff] }
                if kinds & kayaClipFiles != 0 { types.append(.fileURL) }
            }
            if reorderIn != nil { types.append(.init(kayaRowDragType)) }
            if types.isEmpty { unregisterDraggedTypes() } else { registerForDraggedTypes(types) }
        }

        // ---- the source half
        private var sourcePayload: KayaDragPayload? {
            if let node, let payload = node.dragPayload { return payload }
            if let node, reorderIn != nil, let stamp = kayaTableStamp(node.tag) {
                var payload = KayaDragPayload()
                payload.custom = [(kayaRowDragType, Data(stamp.keys.joined(separator: ".").utf8))]
                return payload
            }
            return nil
        }

        private var sourceOps: UInt32 {
            if let node, node.dragPayload != nil { return node.dragOps }
            return reorderIn != nil ? kayaDragOpMove : 0
        }

        override func mouseDown(with event: NSEvent) {
            pressedAt = sourcePayload == nil ? nil : convert(event.locationInWindow, from: nil)
        }

        /// THE WRITER MUST CARRY A TYPE. An empty NSPasteboardItem is ZERO
        /// pasteboard items and AppKit throws NSGenericException — "There
        /// are 0 items on the pasteboard, but 1 drag images" — the moment a
        /// REAL gesture starts the session (measured 2026-09-03 with
        /// tools/mac/dragwitness; docs/traps.md). The payload itself is
        /// written at BOARD level in willBeginAt below, which AppKit calls
        /// only once the drag really begins.
        private func dragWriter(_ payload: KayaDragPayload) -> NSPasteboardItem {
            let writer = NSPasteboardItem()
            writer.setString(payload.text ?? "", forType: .string)
            return writer
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = pressedAt, let payload = sourcePayload else { return }
            let now = convert(event.locationInWindow, from: nil)
            guard hypot(now.x - start.x, now.y - start.y) >= 4 else { return }
            pressedAt = nil
            let item = NSDraggingItem(pasteboardWriter: dragWriter(payload))
            item.setDraggingFrame(bounds, contents: nil)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            kayaNSDragOperation(sourceOps)
        }

        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            // The payload goes on the SESSION's own board, at board level
            // (probe 3): the item writer above carries nothing.
            if let payload = sourcePayload { kayaWriteDragPayload(session.draggingPasteboard, payload) }
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            guard let node else { return }
            KayaHost.emitDragEnded(node.identityTag, kayaDragOpMask(operation))
        }

        // ---- the destination half
        private func verdict(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard let node else { return [] }
            let board = sender.draggingPasteboard
            let sourceOps = kayaDragOpMask(sender.draggingSourceOperationMask)
            let local = sender.draggingSource != nil
            if let container = reorderIn, board.types?.contains(.init(kayaRowDragType)) == true {
                // A row of a reorderable For onto another row of the same For:
                // move, or nothing (docs/dnd-plan.md D8).
                guard local, let stamp = kayaTableStamp(node.tag),
                    let own = kayaTableStamp(container.children.first?.tag ?? []),
                    stamp.node == own.node
                else { return [] }
                return .move
            }
            guard node.dropOps != 0 else { return [] }
            let (_, custom) = kayaParseAcceptList(node.accepts)
            let (offered, offeredCustom) = kayaBoardOffer(board, customAccepted: custom)
            let mask = KayaHost.dragVerdict(
                accepts: node.accepts, targetOps: node.dropOps, offered: offered,
                custom: offeredCustom, sourceOps: sourceOps, local: local)
            return kayaNSDragOperation(mask)
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { verdict(sender) }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { verdict(sender) }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard let node else { return false }
            let op = verdict(sender)
            guard op != [] else { return false }
            let where_ = convert(sender.draggingLocation, from: nil)
            let board = sender.draggingPasteboard
            if let container = reorderIn, let keys = board.string(forType: .init(kayaRowDragType)) {
                // The anchor is THIS row; before when the pointer is in its
                // upper half (AppKit's origin is bottom-left).
                let before = where_.y > bounds.midY
                let value = KayaClipValue(clip: kayaClipCustom, id: kayaRowDragType, bytes: Data(keys.utf8))
                KayaHost.emitDropped(
                    container.identityTag, CGPoint(x: where_.x, y: bounds.height - where_.y),
                    kayaDragOpMove, anchor: node.identityTag, before: before, value)
                return true
            }
            guard let value = kayaReadBoardValue(board, accepting: node.accepts) else { return false }
            KayaHost.emitDropped(
                node.identityTag, CGPoint(x: where_.x, y: bounds.height - where_.y),
                kayaDragOpMask(op), anchor: [], before: false, value)
            return true
        }
    }

    struct KayaMacDragDropSurface: NSViewRepresentable {
        let node: KayaNode
        let reorderIn: KayaNode?

        func makeNSView(context: Context) -> KayaDragDropView {
            let view = KayaDragDropView()
            view.node = node
            view.reorderIn = reorderIn
            view.refreshRegistration()
            kayaDragSurfaces[node.id] = view
            return view
        }

        func updateNSView(_ view: KayaDragDropView, context: Context) {
            view.node = node
            view.reorderIn = reorderIn
            view.refreshRegistration()
            kayaDragSurfaces[node.id] = view
        }

        static func dismantleNSView(_ view: KayaDragDropView, coordinator: ()) {
            if let id = view.node?.id, kayaDragSurfaces[id] === view {
                kayaDragSurfaces.removeValue(forKey: id)
            }
        }
    }

    /// An NSDraggingInfo the `drag` verb hands to the real destination arms:
    /// a real pasteboard, the source's mask, a non-nil source (local), and
    /// the destination's centre as the location (docs/dnd-plan.md D10).
    final class KayaDragInfo: NSObject, NSDraggingInfo {
        let board: NSPasteboard
        let mask: NSDragOperation
        let location: NSPoint
        weak var window: NSWindow?
        /// nil `draggingSource` is AppKit's own spelling of a foreign drag,
        /// which is what `drag_file` presents (docs/dnd-plan.md D6).
        let local: Bool
        init(
            board: NSPasteboard, mask: NSDragOperation, location: NSPoint, window: NSWindow?,
            local: Bool = true
        ) {
            self.board = board
            self.mask = mask
            self.location = location
            self.window = window
            self.local = local
        }
        var draggingDestinationWindow: NSWindow? { window }
        var draggingSourceOperationMask: NSDragOperation { mask }
        var draggingLocation: NSPoint { location }
        var draggedImageLocation: NSPoint { location }
        var draggedImage: NSImage? { nil }
        var draggingPasteboard: NSPasteboard { board }
        var draggingSource: Any? { local ? self : nil }
        var draggingSequenceNumber: Int { 0 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        func enumerateDraggingItems(
            options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
            classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
            using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
        ) {}
        var animatesToDestination: Bool {
            get { false }
            set {}
        }
        var numberOfValidItemsForDrop: Int {
            get { 1 }
            set {}
        }
        var draggingFormation: NSDraggingFormation {
            get { .default }
            set {}
        }
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    /// Drive one drag in-process (docs/dnd-plan.md D10): the source's
    /// declaration on a real named pasteboard, the destination's real
    /// arms called in AppKit's order, the source told the outcome. nil when
    /// it ran (a refusal included — the source reads `none`), else the
    /// sentence naming what stopped it. Main thread.
    /// A view's frame on the screen in CGEvent's coordinates (origin top
    /// left of the main screen): the geometry instrument the mac witness
    /// legs read to aim a real pointer (tools/mac/dragwitness-leg.py).
    func kayaScreenFrameCG(_ v: NSView) -> String {
        guard let window = v.window else { return "(none)" }
        let screen = window.convertToScreen(v.convert(v.bounds, to: nil))
        let height = NSScreen.screens.first?.frame.height ?? 0
        return "(\(Int(screen.origin.x)), \(Int(height - screen.origin.y - screen.height)), \(Int(screen.width)), \(Int(screen.height)))"
    }

    func kayaDriveDrag(source: KayaNode, destination: KayaNode, reorder: Bool?) -> String? {
        guard let view = kayaDragSurfaces[destination.id] else {
            return "\(destination.kind == kindLabel ? "label" : "widget") \(destination.id) is not a drop destination — it declares no drop_target and sits in no reorderable For"
        }
        if let window = view.window {
            let frame = window.frame
            let height = NSScreen.screens.first?.frame.height ?? 0
            let sourceFrame = kayaDragSurfaces[source.id].map(kayaScreenFrameCG) ?? "(none)"
            kayaDiag(
                "dragdrive: source \(sourceFrame) destination \(kayaScreenFrameCG(view)) window "
                    + "(\(Int(frame.origin.x)), \(Int(height - frame.origin.y - frame.height)), \(Int(frame.width)), \(Int(frame.height))) "
                    + "screen (\(Int(NSScreen.screens.first?.frame.width ?? 0)), \(Int(height)))")
        }
        let payload: KayaDragPayload
        let ops: UInt32
        if reorder != nil {
            guard let stamp = kayaTableStamp(source.tag) else {
                return "the source is not a stamped row, and a reorder drags rows"
            }
            payload = KayaDragPayload(custom: [(kayaRowDragType, Data(stamp.keys.joined(separator: ".").utf8))])
            ops = kayaDragOpMove
        } else {
            guard let declared = source.dragPayload else {
                return "the source declares no drag payload (set_drag_source)"
            }
            payload = declared
            ops = source.dragOps
        }
        let board = NSPasteboard(name: .init("dev.kaya.drag.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        kayaWriteDragPayload(board, payload)
        // A reorder lands where the scene says: before is the upper half.
        let point: NSPoint
        if let before = reorder {
            point = NSPoint(x: view.bounds.midX, y: before ? view.bounds.maxY - 1 : view.bounds.minY + 1)
        } else {
            point = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        }
        let inWindow = view.convert(point, to: nil)
        let info = KayaDragInfo(board: board, mask: kayaNSDragOperation(ops), location: inWindow, window: view.window)
        var op = view.draggingEntered(info)
        if op != [] { op = view.draggingUpdated(info) }
        if op != [] {
            if !view.performDragOperation(info) { op = [] }
        }
        KayaHost.emitDragEnded(source.identityTag, kayaDragOpMask(op))
        return nil
    }

    /// Drop `path` on the destination as a FOREIGN source would (docs/
    /// dnd-plan.md D6): a real named pasteboard carrying the file URL, no
    /// source of ours, so the verdict answers `local: false` and the
    /// picked-table redemption is the whole observable. Main thread.
    func kayaDriveFileDrop(path: String, destination: KayaNode) -> String? {
        guard let view = kayaDragSurfaces[destination.id] else {
            return "\(destination.kind == kindLabel ? "label" : "widget") \(destination.id) is not a drop destination — it declares no drop_target and sits in no reorderable For"
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return "no file at \(path) — the scene's guest writes the file it drops (clipboard_seed's rule)"
        }
        let board = NSPasteboard(name: .init("dev.kaya.dragfile.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.declareTypes([.fileURL], owner: nil)
        board.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
        let point = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        let info = KayaDragInfo(
            board: board, mask: [.copy], location: view.convert(point, to: nil),
            window: view.window, local: false)
        var op = view.draggingEntered(info)
        if op != [] { op = view.draggingUpdated(info) }
        if op != [] {
            if !view.performDragOperation(info) { op = [] }
        }
        return nil
    }
#endif

#if !os(macOS)
    /// Every live drag-and-drop surface's view, by widget id — main thread
    /// only, like every registry here; the `drag` verb drives the real arms
    /// through it (docs/dnd-plan.md D10).
    nonisolated(unsafe) var kayaDragSurfaces: [UInt64: KayaDragDropView] = [:]

    /// kaya's row payload for a reorder (docs/dnd-plan.md D8): the moved
    /// row's key path, dot-joined, under a kaya-private id.
    let kayaRowDragType = "dev.kaya/row"

    func kayaDragOpMask(_ op: UIDropOperation) -> UInt32 {
        switch op {
        case .copy: return kayaDragOpCopy
        case .move: return kayaDragOpMove
        default: return kayaDragOpNone
        }
    }

    /// A UIDropProposal carries ONE operation where AppKit carries a mask; the
    /// core's verdict is already one (wire.rs, drop_verdict).
    func kayaUIDropOperation(_ mask: UInt32) -> UIDropOperation {
        if mask & kayaDragOpMove != 0 { return .move }
        if mask & kayaDragOpCopy != 0 { return .copy }
        return .cancel
    }

    /// ONE ITEM PER DRAG (docs/dnd-plan.md D5): every representation the
    /// payload declares on one provider, in kaya's canonical order. A custom
    /// id rides VERBATIM, where macOS's item level refuses one —
    /// docs/traps.md: A MIME-shaped custom id registers verbatim on iOS, and
    /// no private mapping is needed
    func kayaDragItemProvider(_ payload: KayaDragPayload) -> NSItemProvider {
        let provider = NSItemProvider()
        func data(_ id: String, _ bytes: Data) {
            provider.registerDataRepresentation(forTypeIdentifier: id, visibility: .all) {
                done in
                done(bytes, nil)
                return nil
            }
        }
        for (id, bytes) in payload.custom { data(id, bytes) }
        let urls = payload.files.compactMap { URL(string: $0) }
        if let url = urls.first { provider.registerObject(url as NSURL, visibility: .all) }
        if let image = payload.image { data(kayaClipUTI("image"), image) }
        if let html = payload.html { data(kayaClipUTI("html"), Data(html.utf8)) }
        if let text = payload.text {
            data(kayaClipUTI("text"), Data(text.utf8))
        } else if !urls.isEmpty {
            data(kayaClipUTI("text"), Data(urls.map(\.path).joined(separator: "\n").utf8))
        }
        return provider
    }

    /// A provider whose item is a FILE. NO `public.file-url` COMES OFF A REAL
    /// FOREIGN DROP — measured on the pad 2026-09-03
    /// (docs/probes/dnd-probe-ios-2026-09-03.md measurement 3, docs/traps.md):
    /// the stock Files app offers `com.apple.DocumentManager.FINode.File` and
    /// the content type, so a file is told by its suggested NAME plus a
    /// representation `loadFileRepresentation` can copy.
    func kayaProviderIsFile(_ provider: NSItemProvider) -> Bool {
        if provider.registeredTypeIdentifiers.contains(kayaClipUTI("files")) { return true }
        guard let name = provider.suggestedName, !name.isEmpty else { return false }
        return provider.hasItemConformingToTypeIdentifier("public.data")
    }

    /// What a session offers, in kaya's vocabulary: the closed kinds as a mask
    /// and the custom ids among `accepted` it carries. THE TYPES ANSWER, never
    /// the bytes — the hover verdict is synchronous (docs/dnd-plan.md §0).
    func kayaProviderOffer(
        _ providers: [NSItemProvider], customAccepted: [String]
    ) -> (UInt32, [String]) {
        var types: Set<String> = []
        for provider in providers { types.formUnion(provider.registeredTypeIdentifiers) }
        var mask: UInt32 = 0
        if types.contains(kayaClipUTI("text")) { mask |= kayaClipText }
        if types.contains(kayaClipUTI("html")) { mask |= kayaClipHtml }
        if types.contains(kayaClipUTI("image")) || types.contains("public.tiff") {
            mask |= kayaClipImage
        }
        if providers.contains(where: kayaProviderIsFile) { mask |= kayaClipFiles }
        return (mask, customAccepted.filter { types.contains($0) })
    }

    /// The drop read — kayaReadBoardValue's precedence over item providers:
    /// the accept list's own order, richest representation first. EVERY LOAD
    /// STARTS INSIDE performDrop —
    /// docs/traps.md: A dropped item's provider is dead three seconds after
    /// `performDrop` returns. The answer lands on the main queue.
    func kayaReadDropValue(
        _ providers: [NSItemProvider], accepting: String,
        _ answer: @escaping (KayaClipValue?) -> Void
    ) {
        let (kinds, custom) = kayaParseAcceptList(accepting)
        func deliver(_ value: KayaClipValue?) {
            DispatchQueue.main.async { answer(value) }
        }
        func offering(_ id: String) -> NSItemProvider? {
            providers.first { $0.registeredTypeIdentifiers.contains(id) }
        }
        for id in custom {
            guard let provider = offering(id) else { continue }
            _ = provider.loadDataRepresentation(forTypeIdentifier: id) { bytes, _ in
                deliver(bytes.map { KayaClipValue(clip: kayaClipCustom, id: id, bytes: $0) })
            }
            return
        }
        if kinds & kayaClipFiles != 0, let provider = providers.first(where: kayaProviderIsFile) {
            // THE BYTES ARE KEPT, NOT THE HANDLE (docs/dnd-plan.md D6): the
            // provider's copy dies when this callback returns, so the arm
            // copies it into the container and registers THAT with the picked
            // table, exactly as the picker registers a picked URL.
            _ = provider.loadFileRepresentation(forTypeIdentifier: "public.item") { url, _ in
                guard let url else { return deliver(nil) }
                // THE NAME IS THE PROVIDER'S, NOT THE TEMP COPY'S: measured
                // 2026-09-03 (docs/traps.md) — a provider that resolves the
                // file through a DATA representation writes a copy named
                // after the TYPE (`text.txt`), and only `suggestedName`
                // carries what the user dropped.
                let name = provider.suggestedName ?? url.lastPathComponent
                let kept = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("kaya-drop-\(UUID().uuidString)")
                    .appendingPathComponent(name)
                do {
                    try FileManager.default.createDirectory(
                        at: kept.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: kept)
                } catch {
                    return deliver(nil)
                }
                DispatchQueue.main.async {
                    kayaPickedURLs[kept.absoluteString] = kept
                    answer(
                        KayaClipValue(
                            clip: kayaClipFiles, locators: [kept.absoluteString],
                            names: [name]))
                }
            }
            return
        }
        if kinds & kayaClipImage != 0 {
            for id in [kayaClipUTI("image"), "public.tiff"] {
                guard let provider = offering(id) else { continue }
                _ = provider.loadDataRepresentation(forTypeIdentifier: id) { bytes, _ in
                    deliver(bytes.map { KayaClipValue(clip: kayaClipImage, bytes: $0) })
                }
                return
            }
        }
        for (kind, clip) in [(kayaClipUTI("html"), kayaClipHtml), (kayaClipUTI("text"), kayaClipText)]
        where kinds & clip != 0 {
            guard let provider = offering(kind) else { continue }
            _ = provider.loadDataRepresentation(forTypeIdentifier: kind) { bytes, _ in
                deliver(
                    bytes.map {
                        KayaClipValue(clip: clip, text: String(decoding: $0, as: UTF8.self))
                    })
            }
            return
        }
        deliver(nil)
    }

    /// The one UIKit view behind a drag-and-drop widget: a SOURCE when its
    /// node declares a payload, a DESTINATION when its node declares
    /// operations, and BOTH for a row of a reorderable For (docs/dnd-plan.md
    /// D8). The verdict is the core's one pure function; nothing here decides.
    final class KayaDragDropView: UIView, UIDragInteractionDelegate, UIDropInteractionDelegate {
        weak var node: KayaNode?
        weak var reorderIn: KayaNode?
        private(set) var dragSite: UIDragInteraction?
        private(set) var dropSite: UIDropInteraction?

        func refreshRegistration() {
            guard let node else { return }
            let source = node.dragPayload != nil || reorderIn != nil
            let destination = node.dropOps != 0 || reorderIn != nil
            if source, dragSite == nil {
                let site = UIDragInteraction(delegate: self)
                site.isEnabled = true
                addInteraction(site)
                dragSite = site
            } else if !source, let site = dragSite {
                removeInteraction(site)
                dragSite = nil
            }
            if destination, dropSite == nil {
                let site = UIDropInteraction(delegate: self)
                addInteraction(site)
                dropSite = site
            } else if !destination, let site = dropSite {
                removeInteraction(site)
                dropSite = nil
            }
        }

        // ---- the source half
        private var sourcePayload: KayaDragPayload? {
            if let node, let payload = node.dragPayload { return payload }
            if let node, reorderIn != nil, let stamp = kayaTableStamp(node.tag) {
                var payload = KayaDragPayload()
                payload.custom = [(kayaRowDragType, Data(stamp.keys.joined(separator: ".").utf8))]
                return payload
            }
            return nil
        }

        private var sourceOps: UInt32 {
            if let node, node.dragPayload != nil { return node.dragOps }
            return reorderIn != nil ? kayaDragOpMove : 0
        }

        func dragInteraction(
            _ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession
        ) -> [UIDragItem] {
            guard let payload = sourcePayload else { return [] }
            // THE SOURCE'S DECLARED MASK RIDES THE SESSION: iOS reduces a
            // source's operations to one `allowsMoveOperation` bool, which
            // cannot say "move but not copy", so a LOCAL drop reads the real
            // mask back off localContext and answers what the mac answers.
            session.localContext = sourceOps
            return [UIDragItem(itemProvider: kayaDragItemProvider(payload))]
        }

        func dragInteraction(
            _ interaction: UIDragInteraction, sessionAllowsMoveOperation session: UIDragSession
        ) -> Bool {
            sourceOps & kayaDragOpMove != 0
        }

        func dragInteraction(
            _ interaction: UIDragInteraction, session: UIDragSession,
            willEndWith operation: UIDropOperation
        ) {
            guard let node else { return }
            KayaHost.emitDragEnded(node.identityTag, kayaDragOpMask(operation))
        }

        // ---- the destination half
        private func verdict(_ session: UIDropSession) -> UInt32 {
            guard let node else { return kayaDragOpNone }
            let providers = session.items.map(\.itemProvider)
            let local = session.localDragSession != nil
            if let container = reorderIn,
                providers.contains(where: {
                    $0.registeredTypeIdentifiers.contains(kayaRowDragType)
                })
            {
                // A row of a reorderable For onto another row of the same For:
                // move, or nothing (docs/dnd-plan.md D8).
                guard local, let stamp = kayaTableStamp(node.tag),
                    let own = kayaTableStamp(container.children.first?.tag ?? []),
                    stamp.node == own.node
                else { return kayaDragOpNone }
                return kayaDragOpMove
            }
            guard node.dropOps != 0 else { return kayaDragOpNone }
            let declared = session.localDragSession?.localContext as? UInt32
            let sourceOps =
                declared
                ?? (session.allowsMoveOperation
                    ? kayaDragOpCopy | kayaDragOpMove : kayaDragOpCopy)
            let (_, custom) = kayaParseAcceptList(node.accepts)
            let (offered, offeredCustom) = kayaProviderOffer(providers, customAccepted: custom)
            return KayaHost.dragVerdict(
                accepts: node.accepts, targetOps: node.dropOps, offered: offered,
                custom: offeredCustom, sourceOps: sourceOps, local: local)
        }

        func dropInteraction(
            _ interaction: UIDropInteraction, canHandle session: UIDropSession
        ) -> Bool {
            verdict(session) != kayaDragOpNone
        }

        func dropInteraction(
            _ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession
        ) -> UIDropProposal {
            UIDropProposal(operation: kayaUIDropOperation(verdict(session)))
        }

        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
            guard let node else { return }
            let op = verdict(session)
            guard op != kayaDragOpNone else { return }
            let providers = session.items.map(\.itemProvider)
            let where_ = session.location(in: self)
            if let container = reorderIn,
                let provider = providers.first(where: {
                    $0.registeredTypeIdentifiers.contains(kayaRowDragType)
                })
            {
                // The anchor is THIS row; before when the pointer is in its
                // upper half, which on UIKit's top-left origin is the small y.
                let before = where_.y < bounds.midY
                _ = provider.loadDataRepresentation(forTypeIdentifier: kayaRowDragType) {
                    bytes, _ in
                    guard let bytes else { return }
                    DispatchQueue.main.async {
                        let value = KayaClipValue(
                            clip: kayaClipCustom, id: kayaRowDragType, bytes: bytes)
                        KayaHost.emitDropped(
                            container.identityTag, where_, kayaDragOpMove,
                            anchor: node.identityTag, before: before, value)
                    }
                }
                return
            }
            kayaReadDropValue(providers, accepting: node.accepts) { value in
                guard let value else { return }
                KayaHost.emitDropped(
                    node.identityTag, where_, op, anchor: [], before: false, value)
            }
        }
    }

    struct KayaPhoneDragDropSurface: UIViewRepresentable {
        let node: KayaNode
        let reorderIn: KayaNode?

        func makeUIView(context: Context) -> KayaDragDropView {
            let view = KayaDragDropView()
            view.node = node
            view.reorderIn = reorderIn
            view.refreshRegistration()
            kayaDragSurfaces[node.id] = view
            return view
        }

        func updateUIView(_ view: KayaDragDropView, context: Context) {
            view.node = node
            view.reorderIn = reorderIn
            view.refreshRegistration()
            kayaDragSurfaces[node.id] = view
        }

        static func dismantleUIView(_ view: KayaDragDropView, coordinator: ()) {
            if let id = view.node?.id, kayaDragSurfaces[id] === view {
                kayaDragSurfaces.removeValue(forKey: id)
            }
        }
    }

    func kayaSessionConforms(_ items: [UIDragItem], _ typeIdentifiers: [String]) -> Bool {
        items.contains { item in
            typeIdentifiers.contains { item.itemProvider.hasItemConformingToTypeIdentifier($0) }
        }
    }

    /// The drag session the `drag` verb's drop double reports as its local
    /// one, so a driven drop reads `local` and the source's declared mask
    /// exactly as a real session does (docs/dnd-plan.md D10).
    final class KayaDragSessionDouble: NSObject, UIDragSession {
        let items: [UIDragItem]
        let point: CGPoint
        let allowsMoveOperation: Bool
        var localContext: Any?

        init(items: [UIDragItem], point: CGPoint, ops: UInt32) {
            self.items = items
            self.point = point
            self.allowsMoveOperation = ops & kayaDragOpMove != 0
            self.localContext = ops
        }

        var isRestrictedToDraggingApplication: Bool { false }
        func location(in view: UIView) -> CGPoint { point }
        func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool {
            kayaSessionConforms(items, typeIdentifiers)
        }
        func canLoadObjects(ofClass aClass: any NSItemProviderReading.Type) -> Bool {
            items.contains { $0.itemProvider.canLoadObject(ofClass: aClass) }
        }
    }

    /// A UIDropSession the `drag` verb hands to the real destination arms
    /// (docs/dnd-plan.md D10): real NSItemProviders built from the source's
    /// declaration, a local drag session behind `localDragSession`, and the
    /// destination's own point as the location.
    final class KayaDropSessionDouble: NSObject, UIDropSession {
        let items: [UIDragItem]
        let point: CGPoint
        /// nil `localDragSession` is UIKit's own spelling of a foreign drag,
        /// which is what `drag_file` presents (docs/dnd-plan.md D6).
        let local: KayaDragSessionDouble?
        let progress = Progress()
        var progressIndicatorStyle: UIDropSessionProgressIndicatorStyle = .none

        init(items: [UIDragItem], point: CGPoint, local: KayaDragSessionDouble?) {
            self.items = items
            self.point = point
            self.local = local
        }

        var localDragSession: (any UIDragSession)? { local }
        var allowsMoveOperation: Bool { local?.allowsMoveOperation ?? false }
        var isRestrictedToDraggingApplication: Bool { false }
        func location(in view: UIView) -> CGPoint { point }
        func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool {
            kayaSessionConforms(items, typeIdentifiers)
        }
        func canLoadObjects(ofClass aClass: any NSItemProviderReading.Type) -> Bool {
            items.contains { $0.itemProvider.canLoadObject(ofClass: aClass) }
        }

        func loadObjects(
            ofClass aClass: any NSItemProviderReading.Type,
            completion: @escaping ([any NSItemProviderReading]) -> Void
        ) -> Progress {
            let group = DispatchGroup()
            let lock = NSLock()
            var loaded: [any NSItemProviderReading] = []
            for item in items where item.itemProvider.canLoadObject(ofClass: aClass) {
                group.enter()
                _ = item.itemProvider.loadObject(ofClass: aClass) { object, _ in
                    if let object {
                        lock.lock()
                        loaded.append(object)
                        lock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) { completion(loaded) }
            return progress
        }
    }

    /// Drive one drag in-process (docs/dnd-plan.md D10): the source's
    /// declaration on real item providers, the destination's real delegate
    /// arms called in UIKit's order, the source told the outcome. nil when it
    /// ran (a refusal included — the source reads `none`), else the sentence
    /// naming what stopped it. Main thread.
    func kayaDriveDrag(source: KayaNode, destination: KayaNode, reorder: Bool?) -> String? {
        guard let view = kayaDragSurfaces[destination.id], let site = view.dropSite else {
            return "\(destination.kind == kindLabel ? "label" : "widget") \(destination.id) is not a drop destination — it declares no drop_target and sits in no reorderable For"
        }
        let payload: KayaDragPayload
        let ops: UInt32
        if reorder != nil {
            guard let stamp = kayaTableStamp(source.tag) else {
                return "the source is not a stamped row, and a reorder drags rows"
            }
            payload = KayaDragPayload(
                custom: [(kayaRowDragType, Data(stamp.keys.joined(separator: ".").utf8))])
            ops = kayaDragOpMove
        } else {
            guard let declared = source.dragPayload else {
                return "the source declares no drag payload (set_drag_source)"
            }
            payload = declared
            ops = source.dragOps
        }
        // A reorder lands where the scene says: before is the upper half, the
        // small y on UIKit's top-left origin.
        let point: CGPoint
        if let before = reorder {
            point = CGPoint(
                x: view.bounds.midX, y: before ? view.bounds.minY + 1 : view.bounds.maxY - 1)
        } else {
            point = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        }
        let items = [UIDragItem(itemProvider: kayaDragItemProvider(payload))]
        let dragging = KayaDragSessionDouble(items: items, point: point, ops: ops)
        let session = KayaDropSessionDouble(items: items, point: point, local: dragging)
        var op = kayaDragOpNone
        if view.dropInteraction(site, canHandle: session) {
            op = kayaDragOpMask(view.dropInteraction(site, sessionDidUpdate: session).operation)
            if op != kayaDragOpNone { view.dropInteraction(site, performDrop: session) }
        }
        KayaHost.emitDragEnded(source.identityTag, op)
        return nil
    }

    /// Drop `path` on the destination as a FOREIGN source would (docs/
    /// dnd-plan.md D6): a real `NSItemProvider` over the file with NO drag
    /// session behind it, which is UIKit's spelling of foreign, so the verdict
    /// answers `local: false` and the picked-table redemption is the whole
    /// observable. No source of ours, so no `drag_ended`. Main thread.
    func kayaDriveFileDrop(path: String, destination: KayaNode) -> String? {
        guard let view = kayaDragSurfaces[destination.id], let site = view.dropSite else {
            return
                "\(destination.kind == kindLabel ? "label" : "widget") \(destination.id) is not a drop destination — it declares no drop_target and sits in no reorderable For"
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return "no file at \(path) — the scene's guest writes the file it drops"
        }
        let url = URL(fileURLWithPath: path)
        guard let provider = NSItemProvider(contentsOf: url) else {
            return "no NSItemProvider for \(path)"
        }
        // A REAL foreign file provider carries the file's name (probe 5's
        // Files-app measurement); `NSItemProvider(contentsOf:)` leaves
        // suggestedName nil, so the double would be unfaithful without this.
        provider.suggestedName = url.lastPathComponent
        let point = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        let session = KayaDropSessionDouble(
            items: [UIDragItem(itemProvider: provider)], point: point, local: nil)
        guard view.dropInteraction(site, canHandle: session) else { return nil }
        let op = view.dropInteraction(site, sessionDidUpdate: session).operation
        if kayaDragOpMask(op) != kayaDragOpNone {
            view.dropInteraction(site, performDrop: session)
        }
        return nil
    }
#endif

/// Put one clip on the system clipboard. SEVERAL FILES MEANS SEVERAL ITEMS
/// here: item 0 carries every single-valued representation plus the first file.
/// A file list's text rendition is DERIVED HERE, only when the clip offers none.
func kayaCopyToPasteboard(
    text: String?, html: String?, image: Data?, files: [String],
    custom: [(String, Data)]
) {
    // The stage opens here and closes at kayaClipOwned below, so no consumer
    // reads this board halfway written (kayaClipStages).
    kayaClipStaging()
    #if os(macOS)
        let urls = files.compactMap { URL(string: $0) }
        let board = NSPasteboard.general
        board.clearContents()
        // ITEM 0 GOES THROUGH THE PASTEBOARD-LEVEL PATH, NEVER NSPasteboardItem:
        // the item path VALIDATES type strings as UTIs and DROPS a mime-shaped
        // custom id with only a console log (docs/clipboard-plan.md §5b).
        var types: [NSPasteboard.PasteboardType] = custom.map { .init($0.0) }
        if !urls.isEmpty { types.append(.fileURL) }
        if image != nil { types.append(.png) }
        if html != nil { types.append(.html) }
        if text != nil || !urls.isEmpty { types.append(.string) }
        board.declareTypes(types, owner: nil)
        for (id, bytes) in custom {
            board.setData(bytes, forType: NSPasteboard.PasteboardType(id))
        }
        if let url = urls.first {
            board.setString(url.absoluteString, forType: .fileURL)
        }
        if let image {
            board.setData(image, forType: .png)
        }
        if let html {
            board.setString(html, forType: .html)
        }
        if let text {
            board.setString(text, forType: .string)
        } else if !urls.isEmpty {
            board.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        }
        // SEVERAL FILES MEANS SEVERAL ITEMS on this platform (§1b finding 3).
        // writeObjects appends — clearContents above is the one clear.
        for url in urls.dropFirst() {
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            board.writeObjects([item])
        }
    #else
        // ONE WRITE PATH here: `items` takes an arbitrary type string VERBATIM,
        // the slashed custom id included (docs/clipboard-plan.md §8 finding 1).
        // A dictionary keeps no order; every consumer asks for a type by name.
        var item: [String: Any] = [:]
        for (id, bytes) in custom { item[id] = bytes }
        if let image { item[kayaClipUTI("image")] = image }
        if let html { item[kayaClipUTI("html")] = Data(html.utf8) }
        let urls = files.compactMap { URL(string: $0) }
        if let text {
            item[kayaClipUTI("text")] = Data(text.utf8)
        } else if !urls.isEmpty {
            item[kayaClipUTI("text")] = Data(
                urls.map(\.path).joined(separator: "\n").utf8)
        }
        // AND KAYA'S OWN MARKER, on item 0: the whole of the witness's evidence
        // here (kayaClipMarkerType). It answers no read — every arm gates on the
        // ACCEPT LIST, which never names kaya's namespace.
        item[kayaClipMarkerType] = kayaClipMarkerBytes
        // SEVERAL FILES MEANS SEVERAL ITEMS here too, and here EVERY file is
        // its own item rather than the first riding along: this write owns the
        // items directly, where declareTypes owns the BOARD.
        var items: [[String: Any]] = [item]
        for url in urls { items.append([kayaClipUTI("files"): url]) }
        // The assignment IS the clear — `items` replaces the board.
        UIPasteboard.general.items = items
    #endif
    // THE BOARD KAYA NOW OWNS: anything that moves it after this line was
    // somebody else, and the diagnostics say so by name. Composed here, so
    // on iOS the marker above must be on the board it reads back.
    kayaClipOwned(kayaClipBoardNow(), composed: true)
}

/// Answer a privileged read with the FIRST accepted representation in
/// descending richness — custom ids first, in the order the accept list named
/// them, then files, image, html, text. Answering EMPTY is always correct.
func kayaReadClipboard(request: UInt64, accepting: String) {
    #if os(macOS)
        KayaHost.emitClipboardResult(request, kayaReadClipboardValue(accepting: accepting))
    #else
        kayaReadOffThread(accepting: accepting) { value in
            KayaHost.emitClipboardResult(request, value)
        }
    #endif
}

#if !os(macOS)
    /// Materialize a clip OFF THE CALLING THREAD and answer on the main queue: a
    /// DATA READ OF FOREIGN CONTENT BLOCKS ON A PROMPT (docs/clipboard-plan.md
    /// §0e finding 2), and a parked main thread stops drawing the alert.
    func kayaReadOffThread(
        accepting: String, then deliver: @escaping (KayaClipValue?) -> Void
    ) {
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let value = kayaReadClipboardValue(accepting: accepting)
            finished.signal()
            DispatchQueue.main.async { deliver(value) }
        }
        kayaPressPasteWhileBusy(finished)
    }

    /// Answer the paste prompt from the host while a read is in flight. THE
    /// PROMPT IS PER-CLIP (§8 finding 2) and its alert is an out-of-process
    /// overlay, so only the host can reach it; "nothing to press" is ordinary.
    func kayaPressPasteWhileBusy(_ finished: DispatchSemaphore) {
        DispatchQueue.global(qos: .utility).async {
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                if finished.wait(timeout: .now() + 0.25) == .success { return }
                let (ok, lines) = KayaSimdrive.ask("clip_press", timeout: 20)
                if ok, lines.first == "pressed" { return }
            }
        }
    }
#endif

/// ONE LINE WHEN A READ ANSWERS NOTHING, naming what was asked for and what the
/// clipboard held: empty has four indistinguishable causes the GUEST cannot tell
/// apart and the backend can (docs/clipboard-plan.md §8 finding 7).
func kayaClipNote(
    _ answer: KayaClipValue?, accepting: String, offered: [String]
) -> KayaClipValue? {
    if answer == nil {
        let note =
            "KAYA_CLIP_TRACE: read of [\(accepting)] answered empty; "
            + "the clipboard offered \(offered)\(kayaClipOwnerClause())\n"
        FileHandle.standardError.write(Data(note.utf8))
    }
    return answer
}

/// THE PRIVATE TYPE EVERY CLIP KAYA COMPOSES CARRIES ON iOS, and the whole of
/// the witness's evidence there (docs/traps.md, "UIPasteboard's changeCount is a
/// PER-PROCESS number"). macOS carries none. THE BYTES ARE NEVER READ.
let kayaClipMarkerType = "dev.kaya/staged"
let kayaClipMarkerBytes = Data("staged".utf8)

/// What the board this leg staged has been replaced by, in the terms the
/// PLATFORM ACTUALLY MEASURED: the evidence travels as a value and each case
/// renders itself, so no sentence claims a fact its platform never measured.
enum KayaClipDrift {
    /// macOS: the count kaya left on the board, and the count there now.
    case count(staged: Int, now: Int)
    /// iOS: kaya's marker type is no longer among the board's types.
    case markerGone(marker: String)

    /// The evidence, as the clause a failed step opens with.
    var said: String {
        switch self {
        case let .count(staged, now):
            return
                "the pasteboard changed under this leg "
                + "(changeCount \(staged) -> \(now))"
        case let .markerGone(marker):
            return "kaya's staged marker (\(marker)) is gone from the board"
        }
    }

    /// The same evidence as a trailing clause, for a trace line that has
    /// already said what it was reading.
    var clause: String {
        switch self {
        case let .count(staged, now):
            return
                " — AND THE BOARD HAS MOVED SINCE KAYA WROTE IT "
                + "(cc \(staged) -> \(now)): another process is writing this clipboard"
        case let .markerGone(marker):
            return
                " — AND KAYA'S STAGED MARKER (\(marker)) IS GONE FROM THIS BOARD: "
                + "another process replaced the clip this leg staged"
        }
    }
}

/// THE CHANGE COUNT KAYA ITSELF LAST PUT ON THE BOARD. Written from the app
/// thread (the copy) and the harness thread (the seed), so it takes a lock
/// rather than pretending an Int is atomic.
private let kayaClipOwnerLock = NSLock()
private var kayaClipOwnerChange = -1
/// AND WHETHER THAT BOARD CARRIED KAYA'S MARKER — iOS's half of the same
/// record. Set from what the stage SAW on the board, never from what the write
/// intended: a stage that left no marker makes the witness stand down rather
/// than fire.
private var kayaClipOwnerMarked = false
/// Stages this leg is in the middle of. A stage is not one instruction — the
/// board is cleared, filled, and only then recorded — so a consumer that looks
/// inside that window would name a foreign writer for kaya's own write. Every
/// stage runs kayaClipStaging() … kayaClipOwned().
private var kayaClipStages = 0
/// The first breach the witness saw, kept for the harness to fail on.
private var kayaClipBreach: String?

/// A stage is starting: this leg is about to write the board.
func kayaClipStaging() {
    kayaClipOwnerLock.lock()
    kayaClipStages += 1
    kayaClipOwnerLock.unlock()
}

/// Remember the board kaya just produced, and close the stage that produced it.
/// `composed` means the ITEMS were built by a writer kaya controls, the only
/// clip expected to carry kaya's marker; a composed stage that lost it FAILS
/// THE LEG (docs/traps.md).
func kayaClipOwned(_ board: (change: Int, types: [String]), composed: Bool) {
    kayaClipOwnerLock.lock()
    kayaClipOwnerChange = board.change
    if kayaClipStages > 0 { kayaClipStages -= 1 }
    #if !os(macOS)
        kayaClipOwnerMarked = board.types.contains(kayaClipMarkerType)
        if composed, !kayaClipOwnerMarked, kayaClipBreach == nil {
            kayaClipBreach =
                "kaya's stage closed on a board that does not carry its marker "
                + "(\(kayaClipMarkerType)): a writer kaya controls composed this clip, "
                + "so the marker should be among the board's types — and the board "
                + "offers \(board.types). The witness reads that marker and nothing "
                + "else on this platform, so this stage is unwitnessable"
        }
    #endif
    kayaClipOwnerLock.unlock()
}

/// The record the last stage left, taken under the lock in one go: reading the
/// three separately could pair one stage's count with the next's marker flag.
private func kayaClipStaged() -> (change: Int, marked: Bool, staging: Int) {
    kayaClipOwnerLock.lock()
    defer { kayaClipOwnerLock.unlock() }
    return (kayaClipOwnerChange, kayaClipOwnerMarked, kayaClipStages)
}

/// The board this leg staged against the board there now, nil when they are one.
/// THE TWO PLATFORMS MEASURE DIFFERENT FACTS — macOS the change count, iOS the
/// marker (docs/traps.md, "UIPasteboard's changeCount is a PER-PROCESS number").
/// THE MARKER CANNOT SEE an appended item or a clip carrying kaya's own marker.
func kayaClipDrifted() -> (drift: KayaClipDrift, offered: [String])? {
    let staged = kayaClipStaged()
    if staged.staging > 0 { return nil }
    #if !os(macOS)
        if !staged.marked { return nil }
        let now = kayaClipBoardNow()
        if now.types.contains(kayaClipMarkerType) { return nil }
        return (.markerGone(marker: kayaClipMarkerType), now.types)
    #else
        if staged.change < 0 { return nil }
        let now = kayaClipBoardNow()
        if staged.change == now.change { return nil }
        return (.count(staged: staged.change, now: now.change), now.types)
    #endif
}

/// A clause naming a board that has changed since kaya last wrote it, or "".
/// A pasteboard has no "who wrote it", so a second principal's doing arrives as
/// kaya's own step reading the wrong thing (docs/traps.md).
func kayaClipOwnerClause() -> String {
    if let drifted = kayaClipDrifted() { return drifted.drift.clause }
    #if !os(macOS)
        let staged = kayaClipStaged()
        if staged.marked, staged.staging == 0,
            kayaClipBoardNow().types.contains(kayaClipMarkerType)
        {
            return
                " — and the board still carries kaya's staged marker "
                + "(\(kayaClipMarkerType)), so it is the clip this leg staged"
        }
    #endif
    return ""
}

/// THE WITNESS, called by every read and paste that consumes what this leg
/// staged: a foreign replacement prints the same sentence a broken paste does
/// (docs/traps.md), so the separating evidence is read here. IT SAYS WHAT IT
/// MEASURED AND STOPS THERE — no API answers WHO, so this names nobody.
func kayaClipWitness(_ consumer: String) {
    guard let drifted = kayaClipDrifted() else { return }
    kayaClipOwnerLock.lock()
    if kayaClipBreach == nil {
        kayaClipBreach =
            drifted.drift.said
            + ": a foreign writer replaced the staged content"
            + " — \(consumer) is reading a board this leg did not stage, "
            + "and it now offers \(drifted.offered)"
    }
    kayaClipOwnerLock.unlock()
}

/// The breach the witness latched, for the harness to fail a step with. A
/// PEEK, never a take: an expect retries, and a sentence taken on one attempt
/// would be gone from the attempt that finally reports.
func kayaClipBreachNote() -> String? {
    kayaClipOwnerLock.lock()
    defer { kayaClipOwnerLock.unlock() }
    return kayaClipBreach
}

/// The core's latched fault, for the harness to end a run with
/// (crates/kaya/src/fault.rs). SIZED, THEN READ, or a guessed buffer cuts the
/// half naming the cause; a PEEK, or the run's last look reports a green leg.
func kayaCoreFaultNote() -> String? {
    let len = KayaHost.api.fault(nil, 0)
    if len == 0 { return nil }
    var sentence = [UInt8](repeating: 0, count: Int(len))
    sentence.withUnsafeMutableBufferPointer { out in
        _ = KayaHost.api.fault(out.baseAddress, len)
    }
    return String(decoding: sentence, as: UTF8.self)
}

/// The walk itself, shared by the privileged read and by a paste landing on a
/// widget that declared what it accepts — ONE implementation.
func kayaReadClipboardValue(accepting: String) -> KayaClipValue? {
    // The consumption both triggers share, so the witness sits here once.
    kayaClipWitness("the read of [\(accepting)]")
    #if os(macOS)
        return kayaReadBoardValue(NSPasteboard.general, accepting: accepting)
    #else
        return kayaReadPlatformClipboardValue(accepting: accepting)
    #endif
}

#if os(macOS)
/// The mac read over ANY board — the general one for a paste or a read, a
/// drag session's own for a drop — richest accepted representation first.
func kayaReadBoardValue(_ board: NSPasteboard, accepting: String) -> KayaClipValue? {
        let (kinds, custom) = kayaParseAcceptList(accepting)
        var answer: KayaClipValue?

        for id in custom {
            if let bytes = board.data(forType: NSPasteboard.PasteboardType(id)) {
                answer = KayaClipValue(clip: kayaClipCustom, id: id, bytes: bytes)
                break
            }
        }
        if answer == nil, kinds & kayaClipFiles != 0 {
            let urls = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
            let files = urls.filter(\.isFileURL)
            if !files.isEmpty {
                answer = KayaClipValue(
                    clip: kayaClipFiles,
                    locators: files.map(\.path),
                    names: files.map(\.lastPathComponent))
            }
        }
        if answer == nil, kinds & kayaClipImage != 0 {
            // PNG first because that is what a guest hands over; the system
            // synthesizes it from a tiff-only clip.
            if let bytes = board.data(forType: .png) ?? board.data(forType: .tiff) {
                answer = KayaClipValue(clip: kayaClipImage, bytes: bytes)
            }
        }
        if answer == nil, kinds & kayaClipHtml != 0, let html = board.string(forType: .html) {
            answer = KayaClipValue(clip: kayaClipHtml, text: html)
        }
        if answer == nil, kinds & kayaClipText != 0, let text = board.string(forType: .string) {
            answer = KayaClipValue(clip: kayaClipText, text: text)
        }
        return kayaClipNote(
            answer, accepting: accepting,
            offered: board.types?.map(\.rawValue) ?? [])
}
#endif

#if !os(macOS)
func kayaReadPlatformClipboardValue(accepting: String) -> KayaClipValue? {
        let (kinds, custom) = kayaParseAcceptList(accepting)
        let board = UIPasteboard.general
        var answer: KayaClipValue?

        // TYPES FIRST, EVERY TIME: the type list answers free at every stage
        // while touching a VALUE of foreign content blocks on the paste
        // prompt (§8 finding 2). So an unsatisfiable read decides from the
        // offer alone, with no alert raised and so nothing to press.
        let offered = Set(board.types)

        for id in custom where offered.contains(id) {
            if let bytes = board.data(forPasteboardType: id) {
                answer = KayaClipValue(clip: kayaClipCustom, id: id, bytes: bytes)
                break
            }
        }
        if answer == nil, kinds & kayaClipFiles != 0,
            offered.contains(kayaClipUTI("files"))
        {
            let files = (board.urls ?? []).filter(\.isFileURL)
            if !files.isEmpty {
                // THE LOCATOR IS THE URL'S OWN STRING here, never its path:
                // kaya_swiftui_open_picked looks the key up among the picked
                // URLs and falls back to URL(string:), and a bare path is not
                // a URL.
                answer = KayaClipValue(
                    clip: kayaClipFiles,
                    locators: files.map(\.absoluteString),
                    names: files.map(\.lastPathComponent))
            }
        }
        if answer == nil, kinds & kayaClipImage != 0 {
            // PNG first because that is what a guest hands over.
            for type in [kayaClipUTI("image"), "public.tiff"] where offered.contains(type) {
                if let bytes = board.data(forPasteboardType: type) {
                    answer = KayaClipValue(clip: kayaClipImage, bytes: bytes)
                    break
                }
            }
        }
        if answer == nil, kinds & kayaClipHtml != 0,
            offered.contains(kayaClipUTI("html")),
            let bytes = board.data(forPasteboardType: kayaClipUTI("html"))
        {
            answer = KayaClipValue(
                clip: kayaClipHtml, text: String(decoding: bytes, as: UTF8.self))
        }
        if answer == nil, kinds & kayaClipText != 0,
            offered.contains(kayaClipUTI("text")), let text = board.string
        {
            answer = KayaClipValue(clip: kayaClipText, text: text)
        }
        return kayaClipNote(answer, accepting: accepting, offered: Array(offered))
}
#endif

/// What a child tool DID, not merely what it printed. A TOOL THAT FAILED AND A
/// TOOL THAT SUCCEEDED SILENTLY ARE THE SAME EMPTY STRING, so the status and
/// the stderr ride along here and a failure can quote the tool.
struct KayaToolRun {
    let args: [String]
    let out: String
    let status: Int32
    /// Whatever the tool wrote to stderr, or — when it never started —
    /// this side's account of why.
    let said: String
    let signalled: Bool

    var ok: Bool { status == 0 && !signalled }

    /// The tool's own account of itself, in one line, for an error that has to
    /// explain a failure to a session with no context.
    var note: String {
        let name = args.first ?? "?"
        let words = said.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "; ")
        let verdict =
            signalled
            ? "\(name) was killed by signal \(status)"
            : "\(name) exited \(status)"
        return words.isEmpty ? "\(verdict) and said nothing" : "\(verdict): \(words)"
    }
}

/// Run one of Apple's own clipboard tools as a CHILD PROCESS — never a tool kaya
/// wrote, whose assumptions would be ours. NOT `@discardableResult`: that missing
/// attribute is the guard, since the COMPILER then refuses a dropped answer.
func kayaRunTool(_ args: [String], stdin: Data? = nil) -> KayaToolRun {
    #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let input = Pipe()
        if stdin != nil { process.standardInput = input }
        do { try process.run() } catch {
            return KayaToolRun(
                args: args, out: "", status: -1,
                said: "never started: \(error)", signalled: false)
        }
        if let stdin {
            input.fileHandleForWriting.write(stdin)
            input.fileHandleForWriting.closeFile()
        }
        // BOTH PIPES DRAIN AT ONCE. A child that fills the stderr buffer
        // while this thread is still reading stdout to EOF stops writing and
        // never exits.
        let drained = DispatchGroup()
        var errBytes = Data()
        DispatchQueue.global(qos: .userInitiated).async(group: drained) {
            errBytes = err.fileHandleForReading.readDataToEndOfFile()
        }
        let outBytes = out.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()
        return KayaToolRun(
            args: args,
            out: String(decoding: outBytes, as: UTF8.self),
            status: process.terminationStatus,
            said: String(decoding: errBytes, as: UTF8.self),
            signalled: process.terminationReason == .uncaughtSignal)
    #else
        _ = stdin
        return KayaToolRun(
            args: args, out: "", status: -1,
            said: "this platform runs no child processes", signalled: false)
    #endif
}

/// The UTI each closed kind reads and writes under on this platform. A
/// custom id IS its own type, verbatim — kaya's narrow promise.
private func kayaClipUTI(_ kind: String) -> String {
    switch kind {
    case "text": return "public.utf8-plain-text"
    case "html": return "public.html"
    case "image": return "public.png"
    case "files": return "public.file-url"
    default: return kind
    }
}

/// The clipboard as a settle sees it: the changeCount and the type list. THE
/// ONE PLACE THE TWO BOARDS DIFFER, so nothing built on it can drift between
/// the platforms this file serves.
func kayaClipBoardNow() -> (change: Int, types: [String]) {
    #if os(macOS)
        let board = NSPasteboard.general
        return (board.changeCount, board.types?.map(\.rawValue) ?? [])
    #else
        return (UIPasteboard.general.changeCount, UIPasteboard.general.types)
    #endif
}

/// Put the content on the clipboard ONCE, by the platform's own means. Answers
/// nil when the attempt went through, or the sentence to fail with when the
/// MECHANISM refused — which is never worth retrying.
private func kayaClipSeedOnce(kind: String, arg: String) -> String? {
    #if os(macOS)
        let ran: KayaToolRun
        switch kind {
        case "text":
            ran = kayaRunTool(["pbcopy"], stdin: Data(arg.utf8))
        case "html":
            // An AppleScript data literal: «data» plus the four-character
            // class code, then hex — the only stock-tool route to a TYPED
            // payload.
            let hex = arg.utf8.map { String(format: "%02X", $0) }.joined()
            ran = kayaRunTool(["osascript", "-e", "set the clipboard to «data HTML\(hex)»"])
        case "image":
            ran = kayaRunTool([
                "osascript", "-e",
                "set the clipboard to (read (POSIX file \"\(arg)\") as «class PNGf»)",
            ])
        default:
            ran = kayaRunTool(["osascript", "-e", "set the clipboard to POSIX file \"\(arg)\""])
        }
        return ran.ok ? nil : ran.note
    #else
        // THE SEED IS A SPAWNED WRITER ON THIS DEVICE (tools/ios/clipctl over
        // the host bridge), whose write is visible to other processes before
        // the spawn exits (§8 finding 6). base64: the watcher word-splits.
        let payload = Data(arg.utf8).base64EncodedString()
        let (ok, lines) = KayaSimdrive.ask("clip_seed \(kind) \(payload)")
        return ok ? nil : (lines.first ?? "the host refused without saying why")
    #endif
}

/// Put content on the clipboard FROM OUTSIDE this app. CUSTOM FORMATS ARE NOT
/// SEEDABLE: no Apple tool writes an app-defined type. ONE BODY FOR BOTH
/// PLATFORMS — the verb returns only when the content is really there
/// (docs/clipboard-plan.md §8 finding 6).
func kayaClipboardSeed(kind: String, argument: String) {
    guard ["text", "html", "image", "files"].contains(kind) else {
        fatalError(
            "kaya: clipboard_seed cannot write \(kind) from outside the app — no stock "
                + "tool writes an app-defined format, and a helper kaya wrote would be "
                + "foreign in name only")
    }
    let arg = kayaExpandPath(argument)
    // A FILE THAT IS NOT THERE IS NOT A CLIPBOARD PROBLEM, and nothing
    // downstream will say so: `set the clipboard to POSIX file "<missing>"`
    // exits 0, prints nothing and leaves the board untouched (docs/traps.md).
    // Both path-taking kinds check here, on both platforms.
    if kind == "image" || kind == "files", !FileManager.default.fileExists(atPath: arg) {
        fatalError("kaya: clipboard_seed \(kind) — there is no file at \(arg)")
    }

    // WAIT UNTIL THE BOARD IS REALLY *NEW* — a union clip satisfies a type-only
    // poll from the STALE board, and on iOS the count moves on focus — AND
    // RE-ISSUE A WRITE THAT DID NOT LAND (docs/traps.md).
    kayaClipStaging()
    let want = kayaClipUTI(kind)
    let before = kayaClipBoardNow().change
    let started = Date()
    // EVERY BOARD THIS WAIT SEES, one entry per distinct clip: a bare timeout
    // cannot tell "nothing was written" from "something else is writing too".
    var clips: [String] = []
    var last = before
    var seen = 0
    var attempts = 0
    while true {
        attempts += 1
        if let refused = kayaClipSeedOnce(kind: kind, arg: arg) {
            fatalError("kaya: clipboard_seed \(kind) — \(refused)")
        }
        let window = Date().addingTimeInterval(1)
        while true {
            let board = kayaClipBoardNow()
            if board.change != last || clips.isEmpty {
                last = board.change
                seen += 1
                if clips.count < 12 {
                    clips.append(
                        "+\(Int(Date().timeIntervalSince(started) * 1000))ms "
                            + "cc=\(board.change) \(board.types)")
                }
            }
            if board.change != before, board.types.contains(want) {
                // COMPOSED: the writer behind both platforms' seeds is one
                // kaya controls, so on iOS clipctl's marker has to be on this
                // board and a settle that closed without it fails the leg.
                kayaClipOwned(board, composed: true)
                return
            }
            if Date() >= window { break }
            usleep(10_000)
        }
        if Date().timeIntervalSince(started) >= 15 { break }
    }
    fatalError(
        "kaya: clipboard_seed \(kind) never "
            + (last == before
                ? "moved the clipboard's changeCount"
                : "appeared on the clipboard")
            + " — \(attempts) writes over 15s from cc=\(before), \(seen) clips seen: "
            + clips.joined(separator: " | "))
}

/// ONE LINE WHEN A CLIPBOARD TOOL DID NOT SUCCEED, quoting it. A foreign read
/// answers a STRING the scene compares byte for byte, so a tool that failed
/// and a clipboard holding nothing of that kind arrive as the same "".
/// kayaClipNote's sibling for the side kaya spawns; not a failure by itself.
@discardableResult
func kayaToolNote(_ ran: KayaToolRun) -> KayaToolRun {
    if !ran.ok {
        FileHandle.standardError.write(Data("KAYA_CLIP_TRACE: \(ran.note)\n".utf8))
    }
    return ran
}

/// Read the clipboard back FROM OUTSIDE this app, in one
/// representation. Empty when it holds nothing of that kind.
func kayaClipboardRead(_ kind: String) -> String {
    #if os(macOS)
        switch kind {
        case "files":
            // The first file URL, which is all `pbpaste` exposes. Basenames,
            // never paths: the expected string is compared byte for byte
            // across lanes whose temp directories differ.
            let raw = kayaToolNote(kayaRunTool(["pbpaste", "-Prefer", kayaClipUTI(kind)])).out
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let url = URL(string: raw) else { return "" }
            return url.lastPathComponent
        case "image":
            // TWO OF APPLE'S TOOLS, because no single one decodes: osascript
            // writes the clipboard's png out, sips reports the pixel size. The
            // observation is WxH because the hosts re-encode freely.
            let scratch = kayaTempDir() + "/kaya-clipread-\(getpid()).png"
            try? FileManager.default.removeItem(atPath: scratch)
            kayaToolNote(
                kayaRunTool([
                    "osascript",
                    "-e",
                    "set f to open for access POSIX file \"\(scratch)\" with write permission",
                    "-e", "set eof f to 0",
                    "-e", "write (the clipboard as «class PNGf») to f",
                    "-e", "close access f",
                ]))
            guard FileManager.default.fileExists(atPath: scratch) else { return "" }
            let sized = kayaToolNote(
                kayaRunTool(["sips", "-g", "pixelWidth", "-g", "pixelHeight", scratch])
            ).out
            try? FileManager.default.removeItem(atPath: scratch)
            let numbers = sized.split(separator: "\n").compactMap { line -> String? in
                guard let colon = line.lastIndex(of: ":") else { return nil }
                return String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
            }
            guard numbers.count == 2 else { return "" }
            return "\(numbers[0])x\(numbers[1])"
        default:
            return kayaToolNote(kayaRunTool(["pbpaste", "-Prefer", kayaClipUTI(kind)])).out
        }
    #else
        // ONE MECHANISM FOR EVERY KIND, the host's: a device-side CLI is the
        // only reader that sees the custom id — device->host sync drops
        // app-defined types and simctl's pbpaste reads a union clip as empty
        // (§8 findings 3 and 4).
        let (ok, lines) = KayaSimdrive.ask(
            "clip_read \(Data(kind.utf8).base64EncodedString())")
        guard ok, let encoded = lines.first,
            let bytes = Data(base64Encoded: encoded)
        else {
            // A HOST THAT COULD NOT ANSWER IS NOT AN EMPTY CLIPBOARD, and
            // the step's own text cannot tell them apart.
            let why = lines.first ?? "no answer from the simdrive watcher"
            FileHandle.standardError.write(
                Data("KAYA_CLIP_TRACE: clip_read \(kind) — \(why)\n".utf8))
            return ""
        }
        return String(decoding: bytes, as: UTF8.self)
    #endif
}

func kayaExpandPath(_ path: String) -> String {
    // WHOLE NAMES, not prefixes: a plain replace of "$TMP" also eats the
    // first four characters of "$TMPDIR" and leaves a plausible-looking path
    // that does not exist. An unknown name survives intact and trips the
    // leftover-$ check.
    let known = ["TMP": kayaTempDir(), "PID": String(getpid())]
    var out = ""
    var rest = Substring(path)
    while let dollar = rest.firstIndex(of: "$") {
        out += rest[rest.startIndex..<dollar]
        let after = rest.index(after: dollar)
        let nameEnd =
            rest[after...].firstIndex { !$0.isUppercase && $0 != "_" } ?? rest.endIndex
        let name = String(rest[after..<nameEnd])
        out += known[name] ?? "$\(name)"
        rest = rest[nameEnd...]
    }
    return out + rest
}

#if os(macOS)
    /// The AX identifiers NSOpenPanel publishes, measured rather than assumed
    /// (docs/traps.md, the macOS a11y read).
    private let kayaPanelSheetId = "open-panel"
    private let kayaPanelWhereId = "where popup"
    private let kayaPanelOkId = "OKButton"
    private let kayaPanelCancelId = "CancelButton"

    /// The SAVE panel, measured the same way (docs/save-plan.md). Only the
    /// SHEET and the name field are new: `OKButton`, `CancelButton` and
    /// `where popup` are the identical identifiers the open panel publishes,
    /// so the press machinery ports over untouched.
    private let kayaSavePanelSheetId = "save-panel"
    /// The name field, and it is AX-SETTABLE — verified three ways in the
    /// probe: the set returned err 0, the element read the name back, and the
    /// URL the completion delivered carried it.
    private let kayaSavePanelNameId = "saveAsNameTextField"

    /// THE FILE BROWSER HAS THREE SPELLINGS, ONE PER VIEW MODE, set machine-wide
    /// (docs/traps.md, "The mac open panel has THREE shapes"). AN ENUM, so both
    /// switches below are exhaustive and a fourth mode fails the build.
    private enum KayaPanelShape: String, CaseIterable {
        case list = "ListView"
        case icons = "IconView"
        case columns = "ColumnView"
    }
    private let kayaPanelBrowserIds = KayaPanelShape.allCases.map { $0.rawValue }

    /// Roles that carry CONTENT rather than structure. No panel lookup ever
    /// descends into one: every attribute read is a mach round trip and an
    /// ancestor column here held 8362 items (docs/traps.md, "The mac open
    /// panel has THREE shapes").
    private let kayaPanelOpaqueRoles: Set<String> = [
        "AXRow", "AXCell", "AXStaticText", "AXImage", "AXTextField", "AXGroup",
        "AXColumn", "AXMenuButton", "AXButton", "AXPopUpButton", "AXScrollBar",
        "AXList", "AXOutline", "AXBrowser", "AXToolbar", "AXCheckBox", "AXMenuBar",
    ]

    /// The panel's own identifier search: the FIRST match wins, an identifier
    /// is checked before the role is pruned (the browsers are themselves
    /// opaque roles), and the walk never enters an item.
    private func kayaPanelFind(
        _ node: AXUIElement, _ identifiers: [String], _ depth: Int = 0
    ) -> AXUIElement? {
        if depth > 12 { return nil }
        if let ident = kayaAxCopy(node, kAXIdentifierAttribute) as? String,
            identifiers.contains(ident)
        {
            return node
        }
        if depth > 0, let role = kayaAxCopy(node, kAXRoleAttribute) as? String,
            kayaPanelOpaqueRoles.contains(role)
        {
            return nil
        }
        for child in kayaAxKids(node) {
            if let hit = kayaPanelFind(child, identifiers, depth + 1) { return hit }
        }
        return nil
    }

    /// Every identifier the sheet publishes above the item level. Only the
    /// diagnostic uses this — when the browser is a shape this reader does not
    /// know, the message says what the sheet DID publish.
    private func kayaPanelIdentifiers(
        _ node: AXUIElement, _ depth: Int = 0
    ) -> [String] {
        if depth > 12 { return [] }
        var out: [String] = []
        if let ident = kayaAxCopy(node, kAXIdentifierAttribute) as? String, !ident.isEmpty {
            out.append(ident)
        }
        if depth > 0, let role = kayaAxCopy(node, kAXRoleAttribute) as? String,
            kayaPanelOpaqueRoles.contains(role)
        {
            return out
        }
        for child in kayaAxKids(node) {
            out.append(contentsOf: kayaPanelIdentifiers(child, depth + 1))
        }
        return out
    }

    /// The app element with the announce dance done. macOS builds the tree
    /// LAZILY, so without these two attributes the walk returns nothing.
    private func kayaPanelAxApp() -> AXUIElement {
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 2.0)
        if !kayaAxAnnounced {
            kayaAxAnnounced = true
            AXUIElementSetAttributeValue(
                app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(
                app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        return app
    }

    /// Every string under an element. A row's filename sits in a cell's static
    /// text at a depth that varies with the view mode, so the read collects
    /// rather than indexes.
    private func kayaPanelTexts(_ e: AXUIElement, _ depth: Int = 0) -> [String] {
        if depth > 6 { return [] }
        var out: [String] = []
        if let v = kayaAxCopy(e, kAXValueAttribute) as? String, !v.isEmpty { out.append(v) }
        if let t = kayaAxCopy(e, kAXTitleAttribute) as? String, !t.isEmpty { out.append(t) }
        for c in (kayaAxCopy(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            out.append(contentsOf: kayaPanelTexts(c, depth + 1))
        }
        return out
    }

    /// The panel's file browser in whatever view mode the machine is set to,
    /// with the files already extracted and — the part that differs per shape
    /// — the element a SELECTION goes through.
    private struct KayaPanelBrowser {
        /// The view mode this panel is in; the failure messages name it.
        let kind: KayaPanelShape
        /// Where the selection is set. The same element as the browser for
        /// list and icons; the LAST COLUMN for columns, since an NSBrowser
        /// selects per column and the current directory is the rightmost one.
        let container: AXUIElement
        let rows: [(element: AXUIElement, name: String)]
    }

    private func kayaPanelBrowser(_ sheet: AXUIElement) -> KayaPanelBrowser? {
        guard let browser = kayaPanelFind(sheet, kayaPanelBrowserIds) else { return nil }
        guard let ident = kayaAxCopy(browser, kAXIdentifierAttribute) as? String,
            let kind = KayaPanelShape(rawValue: ident)
        else { return nil }
        switch kind {
        case .list:
            // THE COLUMN HEADER IS A ROW TOO, role AXRow and subrole
            // AXOutlineRow like a file; AXDisclosureLevel separates them (0
            // header, 1 file). Icons and columns have no header row.
            var rows: [(AXUIElement, String)] = []
            let all =
                (kayaAxCopy(browser, kAXRowsAttribute) as? [AXUIElement])
                ?? (kayaAxCopy(browser, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            for row in all {
                if let level = kayaAxCopy(row, "AXDisclosureLevel") as? Int, level == 0 {
                    continue
                }
                if let first = kayaPanelTexts(row).first { rows.append((row, first)) }
            }
            return KayaPanelBrowser(kind: kind, container: browser, rows: rows)
        case .icons:
            // A collection view with its items one AXSectionList down, and
            // THE NAME IS THE IDENTIFIER: the item is an AXGroup whose id is
            // "picked.txt", whose only text lives on the AXImage inside it.
            var items: [(AXUIElement, String)] = []
            func collect(_ e: AXUIElement, _ depth: Int) {
                if depth > 3 { return }
                for child in kayaAxKids(e) {
                    if (kayaAxCopy(child, kAXRoleAttribute) as? String) == "AXList" {
                        collect(child, depth + 1)
                    } else if let ident = kayaAxCopy(child, kAXIdentifierAttribute) as? String,
                        !ident.isEmpty
                    {
                        items.append((child, ident))
                    } else if let first = kayaPanelTexts(child).first {
                        items.append((child, first))
                    }
                }
            }
            collect(browser, 0)
            return KayaPanelBrowser(kind: kind, container: browser, rows: items)
        case .columns:
            // One AXList per path component, and ONLY THE LAST ONE IS THIS
            // DIRECTORY. Never walk the others (docs/traps.md).
            var columns: [AXUIElement] = []
            func hunt(_ e: AXUIElement, _ depth: Int) {
                if depth > 4 { return }
                for child in kayaAxKids(e) {
                    switch kayaAxCopy(child, kAXRoleAttribute) as? String {
                    case "AXList": columns.append(child)
                    case "AXScrollArea": hunt(child, depth + 1)
                    default: break
                    }
                }
            }
            hunt(browser, 0)
            guard let last = columns.last else {
                return KayaPanelBrowser(kind: kind, container: browser, rows: [])
            }
            var items: [(AXUIElement, String)] = []
            for child in kayaAxKids(last) {
                if let first = kayaPanelTexts(child).first { items.append((child, first)) }
            }
            return KayaPanelBrowser(kind: kind, container: last, rows: items)
        }
    }

    /// Why the panel could not be read, IN MEASUREMENTS: every clause prints
    /// something this process just observed and names no cause it cannot see
    /// (CLAUDE.md invariant 3; tools/check-diagnostics.py holds the shape).
    func kayaOpenPanelWhyNot() -> String {
        guard let panel = kayaLiveOpenPanel else { return "no panel was requested" }
        let app = kayaPanelAxApp()
        guard let sheet = kayaPanelFind(app, [kayaPanelSheetId]) else {
            // The three facts anyone would ask for next, and no story
            // about them. Presentation needs NONE of them to be true.
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "<none>"
            return
                "a panel is up (visible=\(panel.isVisible)) but published no "
                + "\"\(kayaPanelSheetId)\" accessibility sheet — app active="
                + "\(NSApplication.shared.isActive), frontmost=\(front), "
                + "windows=\(NSApp.windows.count)"
        }
        guard let browser = kayaPanelBrowser(sheet) else {
            let ids = Set(kayaPanelIdentifiers(sheet)).sorted()
            // TWO CAUSES, told apart by a measurement made here: macOS 26.6.2
            // refuses the AX hop into the panel SERVICE for an untrusted
            // process, which reads exactly like an unnameable browser
            // (docs/traps.md; it cost the 2026-08-28 lane 17 legs).
            if !AXIsProcessTrusted() {
                return
                    "the panel's sheet is up but AXIsProcessTrusted=false, and "
                    + "macOS 26.6.2 gates the AX hop into the open/save panel "
                    + "service on the Accessibility grant — the sheet publishes "
                    + "\(ids) and its bridged content answers nothing; grant "
                    + "Accessibility to the app hosting this process (System "
                    + "Settings > Privacy & Security > Accessibility) and re-run "
                    + "(docs/traps.md)"
            }
            return
                "the panel's sheet is up (AXIsProcessTrusted=true) but its file "
                + "browser is none of "
                + "\(kayaPanelBrowserIds.joined(separator: "/")) — the sheet publishes "
                + "\(ids). The view mode is the machine-wide NSGlobalDomain "
                + "NSNavPanelFileListModeForOpenMode2 (1 columns, 2 list, 3 icons), "
                + "so a fourth shape means a new arm in kayaPanelBrowser"
        }
        return
            "the panel's \(browser.kind.rawValue) browser lists \(browser.rows.map { $0.name }) "
            + "— the read that failed raced the panel"
    }

    /// What the live panel is REALLY showing: its directory, and the file
    /// names its browser holds, in any view mode. nil when no panel is live or
    /// the tree is not readable — and then kayaOpenPanelWhyNot says which.
    func kayaOpenPanelState() -> (String, [String])? {
        guard kayaLiveOpenPanel != nil else { return nil }
        let app = kayaPanelAxApp()
        guard let sheet = kayaPanelFind(app, [kayaPanelSheetId]) else { return nil }
        guard let browser = kayaPanelBrowser(sheet) else { return nil }
        let where_ =
            kayaPanelFind(sheet, [kayaPanelWhereId])
            .flatMap { kayaAxCopy($0, kAXValueAttribute) as? String } ?? ""
        return (where_, browser.rows.map { $0.name })
    }

    /// How long a read waits for a PRESENTED panel's browser to publish its
    /// contents: main-queue turns 20ms apart, so a wedged sync reports rather
    /// than hangs. Measured fill after the panel presents: under 0.5s in every
    /// mode.
    private let kayaPanelFillTurns = 100
    private let kayaSavePanelFillTurns = 250

    /// The panel's state, WAITED FOR — the browser exists before its contents do
    /// and THE STEP'S OWN RETRY CANNOT COVER THIS ONE (docs/traps.md, "A RETRY
    /// BUDGET SPENT WAITING ON THE MAIN QUEUE IS NOT A RETRY BUDGET").
    /// `requireRows` IS NOT ALWAYS TRUE: an empty list is a legitimate answer.
    func kayaAwaitOpenPanelState(requireRows: Bool) -> (String, [String])? {
        var state = DispatchQueue.main.sync { kayaOpenPanelState() }
        guard requireRows else { return state }
        for _ in 0..<kayaPanelFillTurns {
            guard let (_, rows) = state, rows.isEmpty else { return state }
            Thread.sleep(forTimeInterval: 0.02)
            state = DispatchQueue.main.sync { kayaOpenPanelState() }
        }
        return state
    }

    /// Point the live panel at a directory: the harness placing the app where
    /// a user would have navigated — set_text's tier, not a stamp, since
    /// expect_file_dialog reads the "where" popup back.
    func kayaOpenPanelGoto(_ path: String) {
        kayaPendingPanelDirectory = kayaExpandPath(path)
    }

    /// Select the named row and press Open, or press Cancel. PRESSING OPEN
    /// RETURNS -25204 AND THAT IS NOT A FAILURE (columns-mode selection lies the
    /// same way with -25205): the completion is the proof (docs/traps.md). nil
    /// means DELIVERED, not landed — the caller re-presses on the DISMISSAL.
    @discardableResult
    func kayaOpenPanelDrive(_ name: String) -> String? {
        guard kayaLiveOpenPanel != nil else { return "no live open panel" }
        let app = kayaPanelAxApp()
        guard let sheet = kayaPanelFind(app, [kayaPanelSheetId]) else {
            return "the panel's AX sheet is not findable"
        }
        if name == "cancel" {
            guard let cancel = kayaPanelFind(sheet, [kayaPanelCancelId]) else {
                return "no Cancel button in the AX sheet"
            }
            let err = AXUIElementPerformAction(cancel, kAXPressAction as CFString)
            return err == .success ? nil : "Cancel press returned AXError \(err.rawValue)"
        }
        guard let browser = kayaPanelBrowser(sheet) else {
            return "the panel publishes no browser (list/icons/columns)"
        }
        guard let row = browser.rows.last(where: { $0.name == name }) else {
            return "no row named \(name) in the browser"
        }
        // A ROW IS SELECTED WHERE ITS CONTAINER SAYS: an AXOutline takes
        // AXSelectedRows, while a collection view and an NSBrowser column take
        // AXSelectedChildren and IGNORE AXSelectedRows, silently returning
        // success (docs/traps.md).
        switch browser.kind {
        case .list:
            AXUIElementSetAttributeValue(
                browser.container, kAXSelectedRowsAttribute as CFString,
                [row.element] as CFArray)
        case .icons, .columns:
            AXUIElementSetAttributeValue(
                browser.container, kAXSelectedChildrenAttribute as CFString,
                [row.element] as CFArray)
        }
        guard let ok = kayaPanelFind(sheet, [kayaPanelOkId]) else {
            return "no Open button in the AX sheet"
        }
        let err = AXUIElementPerformAction(ok, kAXPressAction as CFString)
        return err == .success ? nil : "Open press returned AXError \(err.rawValue)"
    }

    /// What the live SAVE panel is really showing: its directory and its name
    /// field, nil when none is live. NO BROWSER IS REQUIRED, AND THAT IS THE
    /// MEASUREMENT — the COLLAPSED form is the default and publishes none, under
    /// a machine-wide `NSNavPanelExpandedStateForSaveMode` no gate reads.
    func kayaSavePanelState() -> (String, String)? {
        guard kayaLiveSavePanel != nil else { return nil }
        let app = kayaPanelAxApp()
        guard let sheet = kayaPanelFind(app, [kayaSavePanelSheetId]) else { return nil }
        guard let field = kayaPanelFind(sheet, [kayaSavePanelNameId]),
            let name = kayaAxCopy(field, kAXValueAttribute) as? String
        else { return nil }
        let where_ =
            kayaPanelFind(sheet, [kayaPanelWhereId])
            .flatMap { kayaAxCopy($0, kAXValueAttribute) as? String } ?? ""
        return (where_, name)
    }

    /// The save-panel sibling of the blocked-hop trap in docs/traps.md;
    /// it waits for the sheet, never for rows.
    func kayaAwaitSavePanelState() -> (String, String)? {
        var state = DispatchQueue.main.sync { kayaSavePanelState() }
        for _ in 0..<kayaSavePanelFillTurns {
            if state != nil { return state }
            Thread.sleep(forTimeInterval: 0.02)
            state = DispatchQueue.main.sync { kayaSavePanelState() }
        }
        return state
    }

    /// Type a name into the live save panel's name field THROUGH THE
    /// ACCESSIBILITY VALUE, what a user's keyboard reaches: setting the panel's
    /// property directly would prove only that Swift can assign a string.
    func kayaSavePanelName(_ name: String) {
        guard kayaLiveSavePanel != nil else { return }
        let app = kayaPanelAxApp()
        guard let sheet = kayaPanelFind(app, [kayaSavePanelSheetId]) else { return }
        guard let field = kayaPanelFind(sheet, [kayaSavePanelNameId]) else { return }
        AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, name as CFTypeRef)
    }

    /// Press the live save panel's own Save or Cancel — the same buttons the
    /// open panel uses, and the same rule about their return codes. The
    /// completion firing is the proof; the caller checks the panel is gone.
    func kayaSavePanelDrive(save: Bool) {
        guard kayaLiveSavePanel != nil else { return }
        let app = kayaPanelAxApp()
        guard let sheet = kayaPanelFind(app, [kayaSavePanelSheetId]) else { return }
        let id = save ? kayaPanelOkId : kayaPanelCancelId
        if let button = kayaPanelFind(sheet, [id]) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }
#endif

/// Present the platform's real file picker and answer exactly once. THE ANSWER
/// IS PATHS on macOS, where a path IS the capability, and the security-scoped
/// URL on iOS (DESIGN.md, File dialogs). Cancel is an EMPTY list.
func kayaPresentFileDialog(
    window: UInt64, dialog: UInt64, allowsMultiple: Bool, extensions: [String]
) {
    #if os(macOS)
        let panel = NSOpenPanel()
        kayaLivePanel = panel
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        // Armed by file_dialog_goto, applied HERE — the one moment the
        // platform honors it. Always set under the harness, so a run can never
        // inherit a location some earlier process left behind.
        if let pending = kayaPendingPanelDirectory {
            panel.directoryURL = URL(fileURLWithPath: pending)
        }
        panel.allowsMultipleSelection = allowsMultiple
        if !extensions.isEmpty {
            // ADVISORY on every platform: a default view, never a guarantee,
            // so the guest still validates what it got.
            panel.allowedContentTypes = extensions.compactMap {
                UTType(filenameExtension: $0)
            }
        }
        func answer(_ urls: [URL]) {
            kayaLivePanel = nil
            // strdup because the C side reads the strings during the
            // call and nothing may outlive it; freed on the way out.
            let pathBufs: [UnsafeMutablePointer<CChar>?] = urls.map { strdup($0.path) }
            let nameBufs: [UnsafeMutablePointer<CChar>?] = urls.map {
                strdup($0.lastPathComponent)
            }
            defer {
                for b in pathBufs { free(b) }
                for b in nameBufs { free(b) }
            }
            var paths: [UnsafePointer<CChar>?] = []
            var names: [UnsafePointer<CChar>?] = []
            for b in pathBufs { paths.append(b.map { UnsafePointer($0) }) }
            for b in nameBufs { names.append(b.map { UnsafePointer($0) }) }
            paths.withUnsafeBufferPointer { p in
                names.withUnsafeBufferPointer { n in
                    KayaHost.api.emit_file_dialog_result(
                        dialog, p.baseAddress, n.baseAddress, UInt(urls.count))
                }
            }
        }

        if let host = kayaNSWindows[window] ?? NSApp.keyWindow {
            panel.beginSheetModal(for: host) { response in
                answer(response == .OK ? panel.urls : [])
            }
        } else {
            panel.begin { response in
                answer(response == .OK ? panel.urls : [])
            }
        }
    #else
        // UIDocumentPickerViewController hands off to a REMOTE view
        // controller — the picker's UI lives in another process, which is why
        // the harness reaches it from the host (tools/ios/simdrive,
        // docs/traps.md).
        _ = window
        let types: [UTType] =
            extensions.isEmpty
            ? [UTType.item]
            : extensions.compactMap { UTType(filenameExtension: $0) }
        let panel = UIDocumentPickerViewController(
            forOpeningContentTypes: types.isEmpty ? [UTType.item] : types)
        panel.allowsMultipleSelection = allowsMultiple
        // Armed by file_dialog_goto and applied HERE, the same rule NSOpenPanel
        // needs: the initial location is honoured at presentation and nowhere
        // else.
        if let pending = kayaPendingPanelDirectory {
            panel.directoryURL = URL(fileURLWithPath: pending)
        }
        let delegate = KayaPickerDelegate(dialog: dialog, save: false)
        panel.delegate = delegate
        kayaLivePickerDelegate = delegate
        kayaLiveDocumentPicker = panel
        let scenes = UIApplication.shared.connectedScenes
        let ws = scenes.compactMap { $0 as? UIWindowScene }.first
        let host = ws?.windows.first?.rootViewController
        kayaPickerNote(
            "present dialog=\(dialog) at \(kayaPendingPanelDirectory ?? "<none>") "
                + "multiple=\(allowsMultiple) host=\(host.map { String(describing: type(of: $0)) } ?? "<none>")")
        host?.present(panel, animated: false) {
            // The completion is the presentation ACTUALLY finishing, and
            // "present returned" says nothing about that.
            kayaPickerNote("presented dialog=\(dialog)")
        }
    #endif
}

/// Present the platform's real SAVE dialog and answer exactly once. IT ANSWERS
/// WITH ONE URL AND CREATES NOTHING (measured: `exists=false` after a clean Save,
/// and Replace leaves the old bytes), so the core registers the destination.
func kayaPresentSaveDialog(
    window: UInt64, dialog: UInt64, suggestedName: String, extensions: [String]
) {
    #if os(macOS)
        let panel = NSSavePanel()
        kayaLivePanel = panel
        // Armed by file_dialog_goto and applied HERE — the one moment
        // either panel honors it.
        if let pending = kayaPendingPanelDirectory {
            panel.directoryURL = URL(fileURLWithPath: pending)
        }
        panel.nameFieldStringValue = suggestedName
        // THE EXTENSION STAYS VISIBLE, since the harness reads that field back
        // byte for byte and hiding it is the USER'S Finder preference — a
        // machine-wide setting would otherwise decide a lane's colour.
        panel.isExtensionHidden = false
        panel.canCreateDirectories = true
        if !extensions.isEmpty {
            // ADVISORY, exactly as the picker's are.
            panel.allowedContentTypes = extensions.compactMap {
                UTType(filenameExtension: $0)
            }
        }
        func answer(_ url: URL?) {
            kayaLivePanel = nil
            // ONE LOCATOR OR NONE — the C entry takes a single pointer,
            // so cancel is a null one rather than a count of zero.
            guard let url else {
                KayaHost.api.emit_save_dialog_result(dialog, nil, nil)
                return
            }
            // strdup because the C side reads the strings during the
            // call and nothing may outlive it; freed on the way out.
            let pathBuf = strdup(url.path)
            let nameBuf = strdup(url.lastPathComponent)
            defer {
                free(pathBuf)
                free(nameBuf)
            }
            KayaHost.api.emit_save_dialog_result(
                dialog, pathBuf.map { UnsafePointer($0) }, nameBuf.map { UnsafePointer($0) })
        }

        if let host = kayaNSWindows[window] ?? NSApp.keyWindow {
            panel.beginSheetModal(for: host) { response in
                answer(response == .OK ? panel.url : nil)
            }
        } else {
            panel.begin { response in
                answer(response == .OK ? panel.url : nil)
            }
        }
    #else
        // iOS HAS NO "CREATE A FILE WITH THIS NAME" PICKER, so a destination is
        // made by EXPORTING a zero-byte file (docs/save-plan.md D1). STAGED IN
        // THE APP'S PRIVATE TMPDIR, not kayaTempDir(): that is `Documents`, the
        // directory the picker BROWSES.
        _ = (window, extensions)
        let staging = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("kaya-save-export-\(dialog)")
        let manager = FileManager.default
        try? manager.removeItem(atPath: staging)
        try? manager.createDirectory(
            atPath: staging, withIntermediateDirectories: true)
        // A nameless export would throw on the createFile below and present
        // nothing at all; the panel's own placeholder is the honest stand-in.
        let stagedName = suggestedName.isEmpty ? "untitled" : suggestedName
        let source = URL(
            fileURLWithPath: (staging as NSString).appendingPathComponent(stagedName))
        guard manager.createFile(atPath: source.path, contents: Data()) else {
            kayaPickerNote("save dialog=\(dialog) could not stage \(source.path)")
            KayaHost.api.emit_save_dialog_result(dialog, nil, nil)
            return
        }
        let panel = UIDocumentPickerViewController(forExporting: [source], asCopy: true)
        // THE EXTENSION STAYS VISIBLE for the reason the mac arm spells out:
        // the harness reads this field back byte for byte, so the field must
        // not inherit a machine-wide preference.
        panel.shouldShowFileExtensions = true
        // ARMED BY file_dialog_goto AND MEASURED NOT TO TAKE: the EXPORT sheet
        // resumes wherever the Files browser last was, and that memory outlives
        // the process (docs/traps.md), so `expect_save_dialog` reads the
        // BROWSER's location, which the scene's own `file_choose` puts there.
        if let pending = kayaPendingPanelDirectory {
            panel.directoryURL = URL(fileURLWithPath: pending)
        }
        let delegate = KayaPickerDelegate(dialog: dialog, save: true)
        panel.delegate = delegate
        kayaLivePickerDelegate = delegate
        kayaLiveDocumentPicker = panel
        kayaLiveSaveStaging = staging
        let scenes = UIApplication.shared.connectedScenes
        let ws = scenes.compactMap { $0 as? UIWindowScene }.first
        let host = ws?.windows.first?.rootViewController
        kayaPickerNote(
            "present save dialog=\(dialog) at \(kayaPendingPanelDirectory ?? "<none>") "
                + "named \(stagedName) host=\(host.map { String(describing: type(of: $0)) } ?? "<none>")")
        host?.present(panel, animated: false) {
            // The completion is the presentation ACTUALLY finishing —
            // "present returned" says nothing about that.
            kayaPickerNote("presented save dialog=\(dialog)")
        }
    #endif
}

#if !os(macOS)
    /// THE HARNESS'S REACH OUT TO THE HOST: `UIDocumentPickerViewController` is a
    /// remote view controller publishing zero accessibility elements
    /// (docs/traps.md), so the eyes live in tools/ios/simdrive and the two sides
    /// meet through a file each way in the app's container.
    enum KayaSimdrive {
        static var directory: String { kayaTempDir() }
        static var requestPath: String {
            (directory as NSString).appendingPathComponent("kaya-simdrive-request")
        }
        static var responsePath: String {
            (directory as NSString).appendingPathComponent("kaya-simdrive-response")
        }

        /// ONE REQUEST FILE AND ONE RESPONSE FILE means the exchange is a
        /// critical section: the clipboard's asks are not single-threaded, and
        /// two interleaved on the same two paths would swap answers.
        private static let turn = NSLock()

        /// Ask the host for something and wait for its answer. Returns
        /// (ok, lines). A timeout is a FAILURE with a sentence, never a silent
        /// empty read that would report the guest's state for a broken harness.
        static func ask(_ verb: String, timeout: TimeInterval = 60) -> (Bool, [String]) {
            turn.lock()
            defer { turn.unlock() }
            let fm = FileManager.default
            try? fm.removeItem(atPath: responsePath)
            guard fm.createFile(atPath: requestPath, contents: Data(verb.utf8)) else {
                return (false, ["could not write the simdrive request to \(requestPath)"])
            }
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let data = fm.contents(atPath: responsePath),
                    let text = String(data: data, encoding: .utf8), text.hasSuffix("\n")
                {
                    // The trailing newline is the COMMIT: the watcher writes
                    // the body and then the newline, so a partial read cannot
                    // be mistaken for a complete answer.
                    try? fm.removeItem(atPath: responsePath)
                    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                        .map(String.init)
                    if lines.last == "" { lines.removeLast() }
                    let ok = lines.first == "ok"
                    return (ok, Array(lines.dropFirst()))
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            try? fm.removeItem(atPath: requestPath)
            return (false, ["the simdrive watcher did not answer \(verb) within \(Int(timeout))s"])
        }
    }

    /// What the live picker is really showing, read on the host: the directory
    /// and the row names. Nil when no picker is up, which FAILS every
    /// expect_file_dialog rather than passing quietly.
    func kayaSimdriveState() -> (String, [String])? {
        let (ok, lines) = KayaSimdrive.ask("state")
        guard ok, let directory = lines.first, !directory.isEmpty else { return nil }
        return (directory, Array(lines.dropFirst()))
    }

    /// Choose a row or cancel. Nil on success, the failure's sentence otherwise
    /// — simdrive refuses a name the picker does not list and says what it DID
    /// list, and requires the picker to be gone afterwards, so both guards live
    /// on the host with the eyes.
    func kayaSimdriveDrive(_ argument: String) -> String? {
        let verb = argument == "cancel" ? "cancel" : "choose \(argument)"
        let (ok, lines) = KayaSimdrive.ask(verb)
        return ok ? nil : (lines.first ?? "simdrive refused \(verb) without saying why")
    }

    /// What the live SAVE dialog is really showing, read on the host: the
    /// directory and the name in its "Save as" field. Nil state PLUS the
    /// sentence to report, because a refusal from the host would otherwise read
    /// as "no save dialog live" and send the next reader to the guest.
    func kayaSimdriveSaveState() -> ((String, String)?, String) {
        let (ok, lines) = KayaSimdrive.ask("savestate")
        guard ok else {
            return (nil, lines.first ?? "simdrive refused savestate without saying why")
        }
        guard lines.count >= 2, !lines[0].isEmpty, !lines[1].isEmpty else {
            return (nil, "no save dialog live")
        }
        return ((lines[0], lines[1]), "")
    }

    /// Type a name into the live save dialog's name field. Nil on success, the
    /// failure's sentence otherwise — the host refuses when no save sheet is
    /// up and when the field does not read the name back, so both guards live
    /// with the eyes.
    func kayaSimdriveSaveName(_ name: String) -> String? {
        let (ok, lines) = KayaSimdrive.ask("savename \(name)")
        return ok ? nil : (lines.first ?? "simdrive refused savename \(name) without saying why")
    }

    /// Press the live save dialog's own Save or Cancel. The host requires the
    /// sheet to be gone afterwards, the same postcondition `choose` carries
    /// and for the same reason: a tap that lands before the sheet is
    /// interactive is swallowed with no error anywhere.
    func kayaSimdriveSaveDrive(cancel: Bool) -> String? {
        let verb = cancel ? "savecancel" : "savepress"
        let (ok, lines) = KayaSimdrive.ask(verb)
        return ok ? nil : (lines.first ?? "simdrive refused \(verb) without saying why")
    }

    /// ONE LINE PER PICKER LIFECYCLE EVENT, on stderr, because this picker is
    /// the one piece of UI in this backend NOBODY IN THIS PROCESS CAN SEE:
    /// presented, picked, cancelled, emitted, so "the tap never landed" and
    /// "the delegate never fired" are told apart.
    func kayaPickerNote(_ what: String) {
        FileHandle.standardError.write(Data("KAYA_PICKER_TRACE: \(what)\n".utf8))
    }

    /// The live picker and the delegate that answers it. Held because a
    /// UIDocumentPickerViewController's delegate is UNOWNED — dropped on the
    /// floor it is deallocated before the user picks anything, and the result
    /// silently never arrives.
    var kayaLiveDocumentPicker: UIDocumentPickerViewController?
    var kayaLivePickerDelegate: KayaPickerDelegate?

    /// Where the live SAVE dialog's zero-byte export was staged, so the answer
    /// can delete it. Nil for an open picker. Cleared with the delegate.
    var kayaLiveSaveStaging: String?

    /// The picked URLs, by the locator handed to the core. THE OBJECT IS THE
    /// CAPABILITY here: the path EPERMs the moment its security scope drops and
    /// only the URL re-acquires it (DESIGN.md, measurements 4 and 5).
    var kayaPickedURLs: [String: URL] = [:]

    /// The last open's failure, kept alive for the length of the call
    /// that reports it — the core copies the string inside that call.
    var kayaPickedOpenError: [CChar] = []

    final class KayaPickerDelegate: NSObject, UIDocumentPickerDelegate {
        let dialog: UInt64
        /// WHICH DIALOG THIS IS, carried rather than asked: iOS presents both
        /// from one `UIDocumentPickerViewController`, where macOS has two panel
        /// CLASSES to interrogate. No default — set where a picker is presented.
        let save: Bool
        init(dialog: UInt64, save: Bool) {
            self.dialog = dialog
            self.save = save
            super.init()
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
        ) {
            kayaPickerNote(
                "didPick dialog=\(dialog) save=\(save) \(urls.map { $0.lastPathComponent })")
            answer(urls)
        }

        /// Cancel is the EMPTY LIST, faithfully — no platform can
        /// confirm an empty selection, so there is no sentinel.
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            kayaPickerNote("cancelled dialog=\(dialog) save=\(save)")
            answer([])
        }

        private func answer(_ urls: [URL]) {
            kayaLiveDocumentPicker = nil
            kayaLivePickerDelegate = nil
            // The staged export has done its job the moment the platform has
            // answered: it was a zero-byte carrier for a NAME, and the
            // destination is a copy of it. Cleared here, so a run leaves the
            // container as it found it.
            if let staging = kayaLiveSaveStaging {
                kayaLiveSaveStaging = nil
                try? FileManager.default.removeItem(atPath: staging)
            }
            if save {
                // ONE LOCATOR OR NONE — the C entry takes a single pointer,
                // so cancel is a null one rather than a count of zero.
                guard let url = urls.first else {
                    KayaHost.api.emit_save_dialog_result(dialog, nil, nil)
                    kayaPickerNote("emitted save dialog=\(dialog) cancelled")
                    return
                }
                let key = url.absoluteString
                kayaPickedURLs[key] = url
                let locatorBuf = strdup(key)
                let nameBuf = strdup(url.lastPathComponent)
                defer {
                    free(locatorBuf)
                    free(nameBuf)
                }
                KayaHost.api.emit_save_dialog_result(
                    dialog, locatorBuf.map { UnsafePointer($0) },
                    nameBuf.map { UnsafePointer($0) })
                kayaPickerNote("emitted save dialog=\(dialog) \(url.lastPathComponent)")
                return
            }
            // The locator is the URL's own string, and the object is retained
            // beside it — handing the core a PATH would work in the simulator,
            // which enforces no sandbox, and fail on a device (docs/traps.md).
            var locators: [String] = []
            var names: [String] = []
            for url in urls {
                let key = url.absoluteString
                kayaPickedURLs[key] = url
                locators.append(key)
                names.append(url.lastPathComponent)
            }
            let locatorBufs = locators.map { strdup($0) }
            let nameBufs = names.map { strdup($0) }
            defer {
                for b in locatorBufs { free(b) }
                for b in nameBufs { free(b) }
            }
            let lp: [UnsafePointer<CChar>?] = locatorBufs.map { $0.map { UnsafePointer($0) } }
            let np: [UnsafePointer<CChar>?] = nameBufs.map { $0.map { UnsafePointer($0) } }
            lp.withUnsafeBufferPointer { l in
                np.withUnsafeBufferPointer { n in
                    KayaHost.api.emit_file_dialog_result(
                        dialog, l.baseAddress, n.baseAddress, UInt(urls.count))
                }
            }
            kayaPickerNote("emitted dialog=\(dialog) \(urls.count) file(s)")
        }
    }

    /// Redeem a picked file; the core calls this from whatever thread the guest
    /// opened on. START, OPEN, STOP all inside this call: the scope has a
    /// concurrency limit that leaks if held, and the descriptor OUTLIVES it
    /// (DESIGN.md, measurements 2 and 3).
    @_cdecl("kaya_swiftui_open_picked")
    public func kayaSwiftUIOpenPicked(
        _ locator: UnsafePointer<CChar>,
        _ mode: UInt32,
        _ outSeekable: UnsafeMutablePointer<UInt32>,
        _ outError: UnsafeMutablePointer<UnsafePointer<CChar>?>
    ) -> Int64 {
        func refuse(_ why: String) -> Int64 {
            kayaPickedOpenError = Array(why.utf8CString)
            kayaPickedOpenError.withUnsafeBufferPointer { outError.pointee = $0.baseAddress }
            return -1
        }
        let key = String(cString: locator)
        guard let url = kayaPickedURLs[key] ?? URL(string: key) else {
            return refuse("no picked file named \(key)")
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // The three values protocol.rs's picked_mode_code names. Write
        // truncates, exactly as PathSource's does on the desktops.
        let flags: Int32
        switch mode {
        case 0: flags = O_RDONLY
        case 1: flags = O_WRONLY | O_CREAT | O_TRUNC
        case 2: flags = O_RDWR
        default: return refuse("unknown open mode \(mode)")
        }
        let fd = open(url.path, flags, 0o644)
        if fd < 0 {
            return refuse("opening \(url.lastPathComponent) failed: \(String(cString: strerror(errno)))")
        }
        // Seekability rides the OPEN because only the descriptor knows — a
        // provider may hand back a pipe where the same name gave a regular
        // file before.
        var info = stat()
        outSeekable.pointee = (fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG) ? 1 : 0
        return Int64(fd)
    }
#endif


/// Present an auxiliary surface AT-LEAST-ONCE. Belt, not the fix (that is
/// KayaWindowAccessor's event-driven registration): free and idempotent, since
/// a value-identified WindowGroup is unique per value.
func kayaEnsureOpen(_ wid: UInt64, _ open: @escaping (UInt64) -> Void, attempt: Int = 0) {
    #if os(macOS)
        kayaDiag("ensureOpen wid=\(wid) attempt=\(attempt) \(kayaDiagAppState())")
    #endif
    open(wid)
    #if os(macOS)
        let delays: [Double] = [0.3, 0.8, 1.5, 2.0]
        guard attempt < delays.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) {
            guard kayaNSWindows[wid] == nil, kayaScene.windows[wid] != nil,
                !kayaTearingDown.contains(wid)
            else { return }
            if attempt + 1 < delays.count {
                kayaEnsureOpen(wid, open, attempt: attempt + 1)
            } else {
                // Terminal, and self-diagnosing: a matching window in
                // appWindows below means the scene request landed and the
                // REGISTRATION path failed; its absence means the request
                // itself was dropped, a class never yet observed.
                kayaDiag("ensureOpen EXHAUSTED wid=\(wid) \(kayaDiagAppState())")
            }
        }
    #endif
}

/// The live modal alert (one per process): the request's identity for the
/// runner's reads and the emit. Cleared when the one result fires.
struct KayaLiveAlert {
    let id: UInt64
    let window: UInt64
    let actions: Int
}
var kayaLiveAlert: KayaLiveAlert?

/// Where the NEXT picker opens. Applied AT PRESENTATION on both Apple platforms,
/// the only moment either picker honors it: set on a panel already up it is
/// ignored, and NSOpenPanel then restores its last location (measured — a run
/// inherited a directory an unrelated probe binary left).
var kayaPendingPanelDirectory: String?

#if !os(macOS)
    var kayaLiveAlertController: UIAlertController?
    /// UIKit exposes no public button-press for UIAlertController, so
    /// alert_choose drives the REAL dismissal and then the SAME
    /// closure the pressed action would run (stored here at build).
    var kayaAlertAnswers: [String: () -> Void] = [:]
#endif
/// App-initiated teardown (destroy_window) bypasses the chrome-close grammar:
/// dismissWindow re-enters windowShouldClose, and without this a veto window
/// would emit a second close_requested for its own confirmed destruction.
var kayaTearingDown: Set<UInt64> = []
#if os(macOS)
    var kayaLiveNSAlert: NSAlert?
    /// The live panel of EITHER kind, held so the harness verbs can read and
    /// drive the REAL thing rather than a copy of the request. ONE SLOT, TYPED
    /// AS THE SUPERCLASS (`NSOpenPanel` IS an `NSSavePanel`), which mirrors the
    /// core's one-live-dialog-per-process rule.
    var kayaLivePanel: NSSavePanel?

    /// The two readers each see ONLY their own kind, asking the TYPE rather
    /// than a flag someone must remember to set: a save panel publishes no
    /// `open-panel` sheet and no file browser, so an open-panel read that could
    /// see it would poll forever.
    var kayaLiveOpenPanel: NSOpenPanel? { kayaLivePanel as? NSOpenPanel }
    var kayaLiveSavePanel: NSSavePanel? {
        kayaLivePanel is NSOpenPanel ? nil : kayaLivePanel
    }
    var kayaNSWindows: [UInt64: NSWindow] = [:]
    /// Parked waiters for window materialization, keyed by surface id
    /// (main-thread state like the registry): registration signals them, so an
    /// awaiting runner wakes ON the event rather than polling — the deadline
    /// below is only the failure bound.
    var kayaWindowWaiters: [UInt64: [DispatchSemaphore]] = [:]
    var kayaWindowDelegates: [UInt64: KayaWindowDelegate] = [:]

    /// Registers the hosting NSWindow for a surface id and installs the
    /// close-veto delegate proxy. Registration is EVENT-DRIVEN on window
    /// attachment (viewDidMoveToWindow), so it cannot race window creation.
    private struct KayaWindowAccessor: NSViewRepresentable {
        let windowId: UInt64

        final class AttachView: NSView {
            var onAttach: () -> Void = {}
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if window != nil { onAttach() }
            }
        }

        func makeNSView(context: Context) -> AttachView {
            let view = AttachView()
            view.onAttach = { [weak view] in
                if let view { register(view) }
            }
            return view
        }

        func updateNSView(_ view: AttachView, context: Context) {
            register(view)
        }

        private func register(_ view: NSView) {
            guard let window = view.window else { return }
            if kayaNSWindows[windowId] !== window {
                kayaDiag("register wid=\(windowId) num=\(window.windowNumber)")
                kayaNSWindows[windowId] = window
                // THE HAND RUN'S KNOB (tools/mac/dragwitness/run.py --hand): an
                // accessory app's window opens behind the terminal that launched
                // it, and a person cannot drag onto what they cannot see. The
                // lanes never set it.
                if ProcessInfo.processInfo.environment["KAYA_WINDOW_FRONT"] == "1" {
                    NSApp.activate(ignoringOtherApps: true)
                    window.level = .floating
                    window.orderFrontRegardless()
                    let f = window.frame
                    let s = NSScreen.screens.first?.frame ?? .zero
                    kayaDiag("windowfront wid=\(windowId) pid=\(getpid()) frame=\(Int(f.origin.x)),\(Int(s.height - f.origin.y - f.height)),\(Int(f.width)),\(Int(f.height)) screen=\(Int(s.width)),\(Int(s.height))")
                }
                // Wake anyone parked on this surface's materialization
                // (kayaAwaitWindow): this signal IS the event.
                for waiter in kayaWindowWaiters.removeValue(forKey: windowId) ?? [] {
                    waiter.signal()
                }
                let proxy = KayaWindowDelegate(
                    windowId: windowId, original: window.delegate)
                kayaWindowDelegates[windowId] = proxy
                window.delegate = proxy
                // The advisory size may predate the native window (props
                // apply while a surface is still hidden); honor it now.
                kayaApplyWindowSize(windowId)
                // Same for the dirty flag: it lives on the AppKit object, so
                // a surface that was marked before it materialized — or one
                // dismissed and re-opened, which comes back with a FRESH
                // NSWindow — would silently lose it.
                kayaApplyWindowDirty(windowId)
            }
        }
    }

    final class KayaWindowDelegate: NSObject, NSWindowDelegate {
        let windowId: UInt64
        weak var original: (any NSWindowDelegate)?

        init(windowId: UInt64, original: (any NSWindowDelegate)?) {
            self.windowId = windowId
            self.original = original
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if kayaTearingDown.contains(windowId) {
                return true
            }
            if kayaScene.windows[windowId]?.vetoClose == true {
                // The veto class: nothing closes; the app answers
                // with destroy_window if it agrees.
                KayaHost.emitCloseRequested(windowId)
                return false
            }
            if windowId == 0 {
                // The primary is the process's surface: closing it
                // exits the app, uniformly with the other desktops.
                DispatchQueue.main.async {
                    NSApplication.shared.terminate(nil)
                }
                return true
            }
            KayaHost.emitWindowClosed(windowId)
            return true
        }

        override func responds(to sel: Selector!) -> Bool {
            super.responds(to: sel) || (original?.responds(to: sel) ?? false)
        }

        override func forwardingTarget(for sel: Selector!) -> Any? {
            if original?.responds(to: sel) == true { return original }
            return super.forwardingTarget(for: sel)
        }
    }
#endif

let kayaScene = KayaSceneModel()

/// The presentation-side functions, handed over by the host kaya rather than
/// resolved through the dynamic linker: hosts may carry kaya statically or
/// load it RTLD_LOCAL, so the vtable pins the one live instance.
enum KayaHost {
    nonisolated(unsafe) static var api: KayaHostApi!

    static func emit(_ tag: [UInt8]) {
        tag.withUnsafeBufferPointer { buffer in
            api.emit_clicked(buffer.baseAddress, UInt(buffer.count))
        }
    }

    static func emitCloseRequested(_ window: UInt64) {
        api.emit_close_requested(window)
    }

    static func emitWindowClosed(_ window: UInt64) {
        api.emit_window_closed(window)
    }

    static func emitAlertResult(_ alert: UInt64, _ choice: UInt32) {
        api.emit_alert_result(alert, choice)
    }

    /// The user's back affordance popped an entry natively — the
    /// core's stack reconciles inside this call (post-fact).
    static func emitEntryPopped(_ entry: UInt64) {
        api.emit_entry_popped(entry)
    }

    /// The user drove back on an intercept_back-armed entry: nothing
    /// popped; the app answers with pop_entry if it agrees.
    static func emitBackRequested(_ entry: UInt64) {
        api.emit_back_requested(entry)
    }

    /// The user switched sections through the platform switcher — post-fact.
    /// Programmatic selection never comes here (echo doctrine).
    static func emitSectionSelected(_ window: UInt64, _ section: UInt64) {
        api.emit_section_selected(window, section)
    }

    /// A column-header click: the SET_COLUMNS sort tag verbatim plus
    /// the 0-based column index — a REQUEST; the guest sorts.
    static func emitSortRequested(_ tag: [UInt8], _ column: UInt32) {
        tag.withUnsafeBufferPointer { buffer in
            api.emit_sort_requested(buffer.baseAddress, UInt(buffer.count), column)
        }
    }

    static func emitToggled(_ tag: [UInt8], _ checked: Bool) {
        tag.withUnsafeBufferPointer { buffer in
            api.emit_toggled(buffer.baseAddress, UInt(buffer.count), checked ? 1 : 0)
        }
    }

    /// A menu action fired — chrome click, shortcut, or harness verb: ONE
    /// occurrence, one dispatch path. `noun` is the wire path bytes
    /// CONTEXT_ATTACH_NODE delivered for a node-anchored context item (empty
    /// for bar and live-widget items).
    static func emitMenuActivated(_ item: UInt64, _ noun: [UInt8]) {
        noun.withUnsafeBufferPointer { buffer in
            api.emit_menu_activated(item, buffer.baseAddress, UInt(buffer.count))
        }
    }

    /// A toggle item flipped by the user; `checked` is the NEW state (the
    /// model mirror was updated first — the post-user mirror rule).
    /// Programmatic checked writes never come here.
    static func emitMenuToggled(_ item: UInt64, _ noun: [UInt8], _ checked: Bool) {
        noun.withUnsafeBufferPointer { buffer in
            api.emit_menu_toggled(item, buffer.baseAddress, UInt(buffer.count), checked ? 1 : 0)
        }
    }

    /// A radio group's selection changed by the user; keyed by the
    /// GROUP's id, index integral (the choice contract).
    static func emitMenuValueChanged(_ group: UInt64, _ noun: [UInt8], _ index: Double) {
        noun.withUnsafeBufferPointer { buffer in
            api.emit_menu_value_changed(group, buffer.baseAddress, UInt(buffer.count), index)
        }
    }

    static func emitValue(_ tag: [UInt8], _ value: Double) {
        tag.withUnsafeBufferPointer { buffer in
            api.emit_value_changed(buffer.baseAddress, UInt(buffer.count), value)
        }
    }

    /// The value a slider gesture settled on (docs/slider-plan.md S2).
    static func emitValueCommitted(_ tag: [UInt8], _ value: Double) {
        tag.withUnsafeBufferPointer { buffer in
            api.emit_value_committed(buffer.baseAddress, UInt(buffer.count), value)
        }
    }

    /// A picker's COMMITTED value, packed (docs/datetime-plan.md D7).
    static func emitDateChanged(_ tag: [UInt8], _ packed: Int64) {
        tag.withUnsafeBufferPointer { buffer in
            api.emit_date_changed(buffer.baseAddress, UInt(buffer.count), packed)
        }
    }

    static func emitTimeChanged(_ tag: [UInt8], _ packed: Int64) {
        tag.withUnsafeBufferPointer { buffer in
            api.emit_time_changed(buffer.baseAddress, UInt(buffer.count), packed)
        }
    }

    // --- ROW WINDOWING (docs/virtualization-plan.md §3) ---------------
    //
    // EVERY ONE IS NIL-GUARDED: the tools/checks probes host this render path
    // with no core behind it, so an unguarded call crashes the gate.

    /// A For's visible range changed: scroll, resize or first layout.
    static func windowMoved(_ container: UInt64, _ first: Int, _ count: Int) {
        guard api != nil else { return }
        api.window_moved(container, UInt64(max(0, first)), UInt64(max(0, count)))
    }

    /// The extents this tier laid out for the realized rows at `first…`.
    static func rowsMeasured(_ container: UInt64, _ first: Int, _ heights: [Double]) {
        guard api != nil, !heights.isEmpty else { return }
        heights.withUnsafeBufferPointer { buffer in
            api.rows_measured(container, UInt64(max(0, first)), buffer.baseAddress, UInt(buffer.count))
        }
    }

    /// The keyed row's index in the collection's CURRENT order; nil when
    /// there is no answer (the core's fault carries the sentence).
    static func scrollToRow(_ container: UInt64, _ key: String) -> Int? {
        guard api != nil else { return nil }
        let bytes = Array(key.utf8)
        let answer = bytes.withUnsafeBufferPointer { buffer in
            api.scroll_to_row_str(container, buffer.baseAddress, UInt(buffer.count))
        }
        return answer == KAYA_ROW_NOT_FOUND ? nil : Int(answer)
    }

    /// The band, the declared total and the arithmetic the core owns.
    /// nil when there is no core; a `total` of 0 is an answer about a
    /// For this core does not know, which reads the same way.
    static func windowGeometry(_ container: UInt64) -> KayaWindowGeometry? {
        guard api != nil else { return nil }
        var geometry = KayaWindowGeometry()
        api.window_geometry(container, &geometry)
        return geometry
    }

    /// One row's height, measured or presumed — the row-height
    /// delegate's question. 0 means the core has nothing to say yet and
    /// the tier's own floor stands.
    static func rowExtent(_ container: UInt64, _ index: Int) -> Double {
        guard api != nil, index >= 0 else { return 0 }
        return api.row_extent(container, UInt64(index))
    }

    /// THE WINDOW'S SCALE AND APPEARANCE (docs/canvas-plan.md §5, §6).
    /// The core re-rasters every canvas at what this reports; a report
    /// that changes nothing emits nothing. Only the two numbers cross —
    /// no platform colour reaches a drawing.
    static func presentation(_ scale: CGFloat, _ dark: Bool) {
        guard api != nil else { return }
        api.presentation(Double(scale), dark)
    }

    /// One canvas's CANONICAL raster, read back out of the core:
    /// `"<16 hex> <ops>/<l>,<t>,<r>,<b>"` (§7.1). Empty when the id
    /// names no canvas that has been drawn.
    static func canvasProbe(_ widget: UInt64) -> String {
        guard api != nil else { return "" }
        var buffer = [UInt8](repeating: 0, count: 128)
        let wrote = buffer.withUnsafeMutableBufferPointer { buf in
            api.canvas_probe(widget, buf.baseAddress, UInt(buf.count))
        }
        guard wrote > 0 else { return "" }
        return String(decoding: buffer[0..<Int(wrote)], as: UTF8.self)
    }

    /// THE METRICS A BREAKPOINT WAITS ON, and when they arrived: a phone never
    /// resizes, so the FIRST report is the only one it gets (docs/deferred.md's
    /// ios-flaky entry). `sizeClass` is the platform's on iOS and _NONE on
    /// macOS, where the core derives it from width (ruled 2026-08-31).
    static func windowMetrics(_ window: UInt64, _ size: CGSize, _ sizeClass: Int64) {
        kayaDiag(
            "metrics window=\(window) \(Int(size.width))x\(Int(size.height)) class=\(sizeClass)")
        api.window_metrics(window, Double(size.width), Double(size.height), sizeClass)
    }

    /// WHAT LAYOUT ASSIGNED ONE CANVAS, in points (docs/canvas-plan.md
    /// §3.2.1): a fact this backend measured, going the other way from every
    /// apply record. What the core does with it is the size policy.
    static func canvasTrack(_ widget: UInt64, _ size: CGSize) {
        guard api != nil else { return }
        api.canvas_track(widget, Double(size.width), Double(size.height))
    }

    /// A FRAME at the platform's own timestamp (§15.4). CADisplayLink
    /// fixes `targetTimestamp` at schedule time, which is why it is
    /// passed through rather than read here.
    static func frame(_ time: CFTimeInterval) {
        guard api != nil else { return }
        api.frame(Double(time))
    }

    /// THE HARNESS'S FRAME, at the CORE'S deterministic step. No time
    /// crosses: a leg's frame count has to be one number everywhere (§15.4).
    static func harnessFrame() {
        guard api != nil else { return }
        api.harness_frame()
    }

    /// WHICH SIZE one canvas's raster is — `"track"` or `"viewbox"`, or a
    /// sentence naming all three numbers (§3.2.1). Empty when the id
    /// names no canvas that has been drawn.
    static func canvasRasterShape(_ widget: UInt64) -> String {
        guard api != nil else { return "" }
        var buffer = [UInt8](repeating: 0, count: 160)
        let wrote = buffer.withUnsafeMutableBufferPointer { buf in
            api.canvas_raster_shape(widget, buf.baseAddress, UInt(buf.count))
        }
        guard wrote > 0 else { return "" }
        return String(decoding: buffer[0..<Int(wrote)], as: UTF8.self)
    }

    /// An entry edit, with the three facts the core's undo ledger cannot derive
    /// (docs/undo-plan.md §3): the window, focus, and whether the edit is
    /// LEDGER-QUIET — a native undo this backend ROUTED must not be banked
    /// twice, though the app still hears it. TAKES THE NODE, NOT THE TAG.
    static func emitText(_ node: KayaNode, _ text: String) {
        let utf8 = Array(text.utf8)
        let quiet = kayaTakeNativeUndoEcho(node.id, text)
        let focused = kayaScene.focusedId == node.id
        let window = kayaWindowOf(node.id)
        node.tag.withUnsafeBufferPointer { t in
            utf8.withUnsafeBufferPointer { s in
                api.emit_text_changed(
                    t.baseAddress, UInt(t.count), s.baseAddress, UInt(s.count),
                    window, focused ? 1 : 0, quiet ? 1 : 0)
            }
        }
    }

    /// The privileged read's one answer; nil is the universal no.
    static func emitClipboardResult(_ request: UInt64, _ value: KayaClipValue?) {
        kayaWithRepresentation(value) { rep in
            api.emit_clipboard_result(request, rep)
        }
    }

    /// Content arriving at a widget because the USER pasted. The tag is the
    /// widget's own identity bytes, verbatim — one path for a live widget and
    /// a stamped copy alike.
    static func emitPasted(_ tag: [UInt8], _ value: KayaClipValue) {
        kayaWithRepresentation(value) { rep in
            tag.withUnsafeBufferPointer { t in
                api.emit_pasted(t.baseAddress, UInt(t.count), rep)
            }
        }
    }

    /// A drop on the tagged destination (docs/dnd-plan.md D1): the point in
    /// its own coordinates, the verdict, the anchor row's tag for a reorder.
    static func emitDropped(
        _ tag: [UInt8], _ point: CGPoint, _ op: UInt32, anchor: [UInt8], before: Bool,
        _ value: KayaClipValue
    ) {
        kayaWithRepresentation(value) { rep in
            tag.withUnsafeBufferPointer { t in
                anchor.withUnsafeBufferPointer { a in
                    api.emit_dropped(
                        t.baseAddress, UInt(t.count), point.x, point.y, op,
                        a.baseAddress, UInt(a.count), before ? 1 : 0, rep)
                }
            }
        }
    }

    static func emitDragEnded(_ tag: [UInt8], _ op: UInt32) {
        tag.withUnsafeBufferPointer { t in
            api.emit_drag_ended(t.baseAddress, UInt(t.count), op)
        }
    }

    /// The core's one pure verdict (docs/dnd-plan.md D2).
    static func dragVerdict(
        accepts: String, targetOps: UInt32, offered: UInt32, custom: [String],
        sourceOps: UInt32, local: Bool
    ) -> UInt32 {
        accepts.withCString { a in
            custom.joined(separator: " ").withCString { c in
                api.drag_verdict(a, targetOps, offered, c, sourceOps, local ? 1 : 0)
            }
        }
    }

    /// Blocks until the next transaction resolves, then borrows out that
    /// batch's records: the core owns the bytes and they die at the next
    /// call. 0 (pointer NULLed) is shutdown.
    static func nextCommands(_ batch: UnsafeMutablePointer<UnsafePointer<UInt8>?>) -> Int {
        Int(api.next_commands(batch))
    }

    /// Fetch a blob's bytes by the handle an apply record carried, copied out
    /// of core memory. Handles are batch-local, so callers fetch on the pump
    /// thread, within the batch. Nil for a dead handle.
    static func blobCount() -> UInt64 { api.blob_count() }

    static func blobData(_ handle: UInt64) -> Data? {
        var length: UInt = 0
        guard let bytes = api.blob_data(handle, &length) else { return nil }
        return Data(bytes: bytes, count: Int(length))
    }
}

func kayaStartCommandPump() {
    let thread = Thread {
        while true {
            // THE CORE SIZES THE BATCH and owns its bytes until the next
            // call here, so this copies before doing anything else. A pump
            // that sized its own buffer aborted the process at 161 rows in
            // one transaction (docs/deferred.md, the 64 KiB pump wall).
            var bytes: UnsafePointer<UInt8>?
            let length = KayaHost.nextCommands(&bytes)
            guard length > 0, let bytes else { break }
            let batch = Data(bytes: bytes, count: length)
            // Blob handles are batch-local: the next nextCommands call
            // replaces the core's table and the main-queue apply may run after
            // that, so every referenced blob is fetched here.
            let blobs = kayaCollectBlobs()
            DispatchQueue.main.async {
                kayaApply(batch, blobs)
            }
        }
    }
    thread.start()
}

/// Every blob the batch registered, fetched on the pump thread before the
/// next nextCommands call invalidates the handles: the table is the whole
/// truth, so no record layout decides what arrives (docs/traps.md: A BLOB
/// HANDLE DIES WITH ITS BATCH).
private func kayaCollectBlobs() -> [UInt64: Data] {
    var blobs: [UInt64: Data] = [:]
    let count = KayaHost.blobCount()
    if count > 0 {
        for handle in 1...count {
            blobs[handle] = KayaHost.blobData(handle)
        }
    }
    return blobs
}

/// The size request's macOS materialization: resize the primary window's
/// CONTENT to the requested DIP, keeping the current extent on any axis the
/// scene has not requested. iOS applies nothing — the system owns geometry.
#if os(macOS)
func kayaSetWindowContentSize(_ window: NSWindow, _ size: NSSize) {
    kayaInvalidateTableGeometry()
    window.setContentSize(size)
}
#endif

private func kayaApplyWindowSize(_ windowId: UInt64) {
    #if os(macOS)
        let window = kayaNSWindows[windowId]
            ?? (windowId == 0 ? NSApp.windows.first : nil)
        guard let window else { return }
        let model = kayaScene.windows[windowId]
        let current = window.contentRect(forFrameRect: window.frame).size
        let size = NSSize(
            width: model?.width ?? current.width,
            height: model?.height ?? current.height)
        kayaSetWindowContentSize(window, size)
    #endif
}

/// The dirty flag's macOS materialization: NSWindow.isDocumentEdited, the dot in
/// the close button, measured as the WHOLE of the chrome change (88 backing
/// pixels). The system attaches NO behavior to it (docs/dirty-plan.md D3); iOS
/// applies NOTHING, the stated carve-out (D4).
private func kayaApplyWindowDirty(_ windowId: UInt64) {
    #if os(macOS)
        // The same re-application hazard the size request has: a prop may be
        // set while the surface is still hidden, and the flag lives on the
        // AppKit object. register() calls this for exactly that reason.
        let window = kayaNSWindows[windowId]
            ?? (windowId == 0 ? NSApp.windows.first : nil)
        guard let window else { return }
        window.isDocumentEdited = kayaScene.windows[windowId]?.dirty ?? false
    #endif
}

private func kayaApply(_ batch: Data, _ blobs: [UInt64: Data]) {
    kayaInvalidateTableGeometry()
    // Coalesced menu re-assert: any record that touches the command
    // catalog re-syncs the native chrome ONCE at the batch boundary
    // (the macOS NSMenu segment, the shortcut dispatch table).
    var menusTouched = false
    batch.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        var at = 0
        while at + 8 <= raw.count {
            let size = Int(raw.loadUnaligned(fromByteOffset: at, as: UInt32.self))
            let kind = raw.loadUnaligned(fromByteOffset: at + 4, as: UInt16.self)
            let body = at + 8
            switch kind {
            case applyCreate:
                let id = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let widgetKind = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt32.self)
                let tagLen = Int(raw.loadUnaligned(fromByteOffset: body + 12, as: UInt32.self))
                let tag = [UInt8](raw[(body + 16)..<(body + 16 + tagLen)])
                let node = KayaNode(id: id, kind: widgetKind, tag: tag)
                kayaScene.nodes[id] = node
                switch widgetKind {
                case kindButton: kayaScene.buttons.append(node)
                case kindLabel: kayaScene.labels.append(node)
                case kindSlider: kayaScene.sliders.append(node)
                case kindDatePicker: kayaScene.datePickers.append(node)
                case kindTimePicker: kayaScene.timePickers.append(node)
                case kindEntry: kayaScene.entryWidgets.append(node)
                case kindCheckbox: kayaScene.checkboxes.append(node)
                case kindImage: kayaScene.images.append(node)
                case kindCanvas: kayaScene.canvases.append(node)
                case kindColumn: kayaScene.columns.append(node)
                case kindRow: kayaScene.rows.append(node)
                case kindScroll: kayaScene.scrolls.append(node)
                case kindProgress: kayaScene.progresses.append(node)
                case kindSelect: kayaScene.selects.append(node)
                case kindRadio: kayaScene.radios.append(node)
                case kindGrid: kayaScene.grids.append(node)
                case kindTextarea: kayaScene.textareas.append(node)
                case kindLabeled: kayaScene.labeleds.append(node)
                default: break
                }
            case applySetWindowProp:
                // window (u64; 0 = the primary surface), prop (u32), pad,
                // value. Size is an advisory request: macOS resizes, iOS
                // records (DESIGN.md, Presentation contexts).
                let wid = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let prop = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt32.self)
                let wvType = raw.loadUnaligned(fromByteOffset: body + 16, as: UInt32.self)
                let wvLen = Int(raw.loadUnaligned(fromByteOffset: body + 20, as: UInt32.self))
                let model = kayaScene.windows[wid]
                switch (prop, wvType) {
                case (wpropTitle, valueStr):
                    let bytes = raw[(body + 24)..<(body + 24 + wvLen)]
                    let title = String(decoding: bytes, as: UTF8.self)
                    model?.title = title
                    #if os(iOS)
                        // The switcher/Stage Manager label — iOS's
                        // materialization of a surface title.
                        if wid == 0 {
                            for uiScene in UIApplication.shared.connectedScenes {
                                (uiScene as? UIWindowScene)?.title = title
                            }
                        }
                    #endif
                case (wpropWidth, valueF64):
                    model?.width =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Double.self)
                    kayaApplyWindowSize(wid)
                case (wpropHeight, valueF64):
                    model?.height =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Double.self)
                    kayaApplyWindowSize(wid)
                case (wpropVetoClose, valueBool):
                    model?.vetoClose = raw[body + 24] != 0
                case (wpropPanes, valueI64):
                    model?.panes =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Int64.self)
                case (wpropDirty, valueBool):
                    model?.dirty = raw[body + 24] != 0
                    kayaApplyWindowDirty(wid)
                case (wpropInset, valueF64):
                    model?.inset =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Double.self)
                case (wpropSectionsPresentation, valueI64):
                    // ADVISORY (the width/height precedent): honored
                    // where this platform has the idiom.
                    model?.sectionsPresentation =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Int64.self)
                default:
                    fatalError("kaya: bad window prop \(prop) value type \(wvType)")
                }
            case applyCreateWindow:
                // Materializes hidden: the model exists, no scene
                // instance until a mount presents it.
                let wid = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                kayaScene.windows[wid] = KayaWindowModel(id: wid)
            case applyDestroyWindow:
                let wid = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                kayaTearingDown.insert(wid)
                kayaDismissWindow?(wid)
                kayaTearingDown.remove(wid)
                #if os(macOS)
                    kayaNSWindows.removeValue(forKey: wid)
                    kayaWindowDelegates.removeValue(forKey: wid)
                #endif
                kayaScene.windows.removeValue(forKey: wid)
            case applyCopy:
                // { u32 present; u32 file_count; u32 custom_count; u32
                // reserved } then a Values block in the canonical order:
                // custom pairs, files, image, html, text. Read in that
                // order and the preference order is right for free.
                let present = raw.loadUnaligned(fromByteOffset: body, as: UInt32.self)
                let fileCount = Int(raw.loadUnaligned(fromByteOffset: body + 4, as: UInt32.self))
                let customCount = Int(
                    raw.loadUnaligned(fromByteOffset: body + 8, as: UInt32.self))
                var cat = body + 24
                func nextClipValue() -> (UInt32, Range<Int>) {
                    let type = raw.loadUnaligned(fromByteOffset: cat, as: UInt32.self)
                    let len = Int(raw.loadUnaligned(fromByteOffset: cat + 4, as: UInt32.self))
                    let payload = (cat + 8)..<(cat + 8 + len)
                    cat += 8 + len
                    if cat % 8 != 0 { cat += 8 - cat % 8 }
                    return (type, payload)
                }
                func nextClipString() -> String {
                    String(decoding: raw[nextClipValue().1], as: UTF8.self)
                }
                func nextClipBytes() -> Data {
                    // A blob rides as a batch-local handle; the pump
                    // prefetched the bytes before the table turned over.
                    let handle = raw.loadUnaligned(
                        fromByteOffset: nextClipValue().1.lowerBound, as: UInt64.self)
                    return blobs[handle] ?? Data()
                }
                var custom: [(String, Data)] = []
                for _ in 0..<customCount { custom.append((nextClipString(), nextClipBytes())) }
                var files: [String] = []
                for _ in 0..<fileCount { files.append(nextClipString()) }
                let image = present & kayaClipImage != 0 ? nextClipBytes() : nil
                let html = present & kayaClipHtml != 0 ? nextClipString() : nil
                let text = present & kayaClipText != 0 ? nextClipString() : nil
                kayaCopyToPasteboard(
                    text: text, html: html, image: image, files: files, custom: custom)
            case applyClearUndo:
                // A1 (docs/undo-plan.md §3): a core undo group committed.
                // TARGETLESS — the record names the window and nothing else.
                let undoWindow = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                kayaClearUndoForGroup(undoWindow)
            case applyHighlightRanges:
                // THE DECLARED SET, replacing whatever was declared before:
                // a flat Values list of I64s read IN PAIRS, already UTF-16.
                // RECORDED WITH THE TEXT IT WAS DECLARED AGAINST (D2's
                // clear-on-edit), which this batch has already landed.
                let hid = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let hcount = Int(raw.loadUnaligned(fromByteOffset: body + 8, as: UInt32.self))
                var hat = body + 24
                func nextRangeOffset() -> Int {
                    let n = raw.loadUnaligned(fromByteOffset: hat + 8, as: Int64.self)
                    hat += 16
                    return Int(n)
                }
                var declared: [NSRange] = []
                for _ in 0..<hcount {
                    let start = nextRangeOffset()
                    let end = nextRangeOffset()
                    declared.append(NSRange(location: start, length: end - start))
                }
                let hnode = kayaScene.nodes[hid]!
                hnode.highlights = declared
                hnode.highlightsFor = hnode.text
            case applySelectRange:
                let sid = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let sstart = Int(raw.loadUnaligned(fromByteOffset: body + 8, as: UInt64.self))
                let send = Int(raw.loadUnaligned(fromByteOffset: body + 16, as: UInt64.self))
                let snode = kayaScene.nodes[sid]!
                snode.selectRequest = NSRange(location: sstart, length: send - sstart)
                snode.selectSeq += 1
            case applyRevealRange:
                let rid = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let rstart = Int(raw.loadUnaligned(fromByteOffset: body + 8, as: UInt64.self))
                let rend = Int(raw.loadUnaligned(fromByteOffset: body + 16, as: UInt64.self))
                let rnode = kayaScene.nodes[rid]!
                rnode.revealRequest = NSRange(location: rstart, length: rend - rstart)
                rnode.revealSeq += 1
            case applyReadClipboard:
                let request = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let acceptLen = Int(raw.loadUnaligned(fromByteOffset: body + 12, as: UInt32.self))
                let accepting = String(
                    decoding: raw[(body + 16)..<(body + 16 + acceptLen)], as: UTF8.self)
                kayaReadClipboard(request: request, accepting: accepting)
            case applyPresentFileDialog:
                // The platform's REAL picker (NSOpenPanel), answered exactly
                // once through kaya_emit_file_dialog_result — the chosen
                // files, or an EMPTY list for cancel.
                let dialogWindow = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let dialogId = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt64.self)
                let allowsMultiple =
                    raw.loadUnaligned(fromByteOffset: body + 16, as: UInt32.self) != 0
                let filterCount = Int(
                    raw.loadUnaligned(fromByteOffset: body + 24, as: UInt32.self))
                var fat = body + 32
                func nextFilterStr() -> String {
                    let len = Int(raw.loadUnaligned(fromByteOffset: fat + 4, as: UInt32.self))
                    let bytes = raw[(fat + 8)..<(fat + 8 + len)]
                    fat += 8 + len
                    if fat % 8 != 0 { fat += 8 - fat % 8 }
                    return String(decoding: bytes, as: UTF8.self)
                }
                // Read IN PAIRS: label then extensions. The grouping is
                // the encoding.
                var extensions: [String] = []
                for _ in 0..<(filterCount / 2) {
                    _ = nextFilterStr()  // the label, shown by the panel itself
                    extensions.append(contentsOf:
                        nextFilterStr().split(separator: " ").map {
                            String($0).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                        })
                }
                kayaPresentFileDialog(
                    window: dialogWindow,
                    dialog: dialogId,
                    allowsMultiple: allowsMultiple,
                    extensions: extensions)
            case applySetBrand:
                // Eleven packed sRGB words in the wire's fixed order: seed,
                // light's five (fill, on_fill, standalone, hover, pressed),
                // dark's five. VALUES — the core derived, nothing here
                // re-computes (docs/styling-plan.md D1).
                var brand: [UInt32] = []
                brand.reserveCapacity(11)
                for i in 0..<11 {
                    brand.append(
                        raw.loadUnaligned(fromByteOffset: body + i * 4, as: UInt32.self))
                }
                kayaScene.brand = brand
            case applySetTypeface:
                // THE REQUEST, UNRESOLVED: mask, the core's platform stamp,
                // the default family, the per-platform pairs, then the font
                // slot. Resolving it is THIS SIDE's job — a lowering is its
                // platform (docs/styling-plan.md Slice 2b).
                var tat = body + 8
                func nextTypefaceValue() -> (UInt32, Int, Int) {
                    let type = raw.loadUnaligned(fromByteOffset: tat, as: UInt32.self)
                    let len = Int(raw.loadUnaligned(fromByteOffset: tat + 4, as: UInt32.self))
                    let at = tat + 8
                    tat += 8 + len
                    if tat % 8 != 0 { tat += 8 - tat % 8 }
                    return (type, at, len)
                }
                func nextTypefaceStr() -> String {
                    let (_, at, len) = nextTypefaceValue()
                    return String(decoding: raw[at..<(at + len)], as: UTF8.self)
                }
                let mask = raw.loadUnaligned(fromByteOffset: body, as: UInt32.self)
                // WHICH ROW IS MINE, stamped by the core: the tag of the
                // platform it was compiled for. This file serves macOS AND iOS
                // and carries NO copy of the platform vocabulary (the CLIP_*
                // mirror trap).
                let mine = Int64(raw.loadUnaligned(fromByteOffset: body + 4, as: UInt32.self))
                let defaultFamily = nextTypefaceStr()
                let pairCount = Int(raw.loadUnaligned(fromByteOffset: tat, as: UInt32.self))
                tat += 8
                var picked: String?
                for _ in 0..<(pairCount / 2) {
                    let (_, tagAt, _) = nextTypefaceValue()
                    let tag = raw.loadUnaligned(fromByteOffset: tagAt, as: Int64.self)
                    let family = nextTypefaceStr()
                    // FIRST MATCH WINS, and the root refuses a repeated
                    // platform so there is never a second.
                    if tag == mine, picked == nil { picked = family }
                }
                // The font slot is always written; the mask says
                // whether it means anything.
                let (fontType, fontAt, _) = nextTypefaceValue()
                var registered: String?
                if mask & 1 != 0, fontType == valueBlob {
                    let handle = raw.loadUnaligned(fromByteOffset: fontAt, as: UInt64.self)
                    if let data = blobs[handle] {
                        // REGISTER, THEN RESOLVE: the bytes join this
                        // process's font list and hand back a family name, and
                        // the named-request machinery takes it from there.
                        registered = kayaRegisterFont(data)
                    }
                }
                let wanted = registered ?? picked ?? defaultFamily
                kayaScene.typefaceRequested = wanted
                // THE PRESENCE GATE: without it a family this device lacks
                // still renders — CoreText hands back Helvetica and
                // Font.custom goes through it — so a typo would look exactly
                // like a brand. Refusing leaves the platform's ramp standing.
                kayaScene.typefaceFamily = kayaFamilyPresent(wanted) ? wanted : nil
                if kayaScene.typefaceFamily == nil {
                    kayaDiag(
                        "typeface \(wanted) is not installed — the platform ramp stands")
                }
            case applySetAppIdentity:
                // ONE DECLARATION, TWO PLATFORMS THAT REACH IT DIFFERENTLY
                // (docs/app-identity-plan.md I1, I8): macOS hands the picture
                // to the Dock at runtime; iOS has no runtime route and its
                // identity is the bundle's.
                var iat = body + 8
                func nextIdentityValue() -> (UInt32, Int, Int) {
                    let type = raw.loadUnaligned(fromByteOffset: iat, as: UInt32.self)
                    let len = Int(raw.loadUnaligned(fromByteOffset: iat + 4, as: UInt32.self))
                    let at = iat + 8
                    iat += 8 + len
                    if iat % 8 != 0 { iat += 8 - iat % 8 }
                    return (type, at, len)
                }
                let identityMask = raw.loadUnaligned(fromByteOffset: body, as: UInt32.self)
                let (_, nameAt, nameLen) = nextIdentityValue()
                let identityName = String(
                    decoding: raw[nameAt..<(nameAt + nameLen)], as: UTF8.self)
                // The icon slot is always written; the mask says whether
                // it means anything (the typeface's convention, copied).
                let (iconType, iconAt, _) = nextIdentityValue()
                var identityIcon: Data?
                if identityMask & 1 != 0, iconType == valueBlob {
                    let handle = raw.loadUnaligned(fromByteOffset: iconAt, as: UInt64.self)
                    identityIcon = blobs[handle]
                }
                kayaScene.appIdentityName = identityName
                kayaScene.appIdentityIcon = identityIcon
                #if os(macOS)
                    kayaApplyMacIdentity(identityName, identityIcon)
                #else
                    // NO RUNTIME ROUTE, MEASURED: the whole iOS app-icon
                    // surface is typed BOOL and NSString and takes no bytes.
                    // The bytes are kept for the OBSERVATION, which reads the
                    // running bundle's icon and holds it equal to this.
                    kayaDiag(
                        "app identity \(identityName): iOS has no runtime route to the "
                            + "Home Screen icon, so this declaration reaches the platform "
                            + "through tools/ios/run-sim.py's make_bundle; "
                            + "\(identityIcon?.count ?? 0) icon bytes kept for the "
                            + "bundle read")
                #endif
            case applySetColumnHeaders:
                // The header bar: { u64 id; u32 sorted; u32 direction;
                // u32 count; u32 tag_len; Values titles; tag bytes }.
                let cid = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let csorted = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt32.self)
                let cdirection = raw.loadUnaligned(fromByteOffset: body + 12, as: UInt32.self)
                let ccount = Int(raw.loadUnaligned(fromByteOffset: body + 16, as: UInt32.self))
                let ctagLen = Int(raw.loadUnaligned(fromByteOffset: body + 20, as: UInt32.self))
                var cat = body + 32
                var ctitles: [String] = []
                for _ in 0..<ccount {
                    let len = Int(raw.loadUnaligned(fromByteOffset: cat + 4, as: UInt32.self))
                    ctitles.append(
                        String(decoding: raw[(cat + 8)..<(cat + 8 + len)], as: UTF8.self))
                    cat += 8 + len
                    if cat % 8 != 0 { cat += 8 - cat % 8 }
                }
                let cnode = kayaScene.nodes[cid]!
                cnode.tableColumns = ctitles
                cnode.tableSorted = csorted
                cnode.tableDirection = cdirection
                cnode.sortTag = Array(raw[cat..<(cat + ctagLen)])
            case applySetDrawing:
                // THE RASTER, not the ops: { u64 id; u32 width; u32
                // height; Value scale; Value pixels } — premultiplied
                // RGBA8 the core produced (docs/canvas-plan.md §1.1).
                let did = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let dw = Int(raw.loadUnaligned(fromByteOffset: body + 8, as: UInt32.self))
                let dh = Int(raw.loadUnaligned(fromByteOffset: body + 12, as: UInt32.self))
                // Each Value is { u32 type; u32 len; payload } padded to
                // 8, so the f64 scale's payload is at +24 and the blob
                // handle's at +40.
                let dscale = raw.loadUnaligned(fromByteOffset: body + 24, as: Double.self)
                let dhandle = raw.loadUnaligned(fromByteOffset: body + 40, as: UInt64.self)
                if let dnode = kayaScene.nodes[did] {
                    dnode.drawingScale = CGFloat(dscale)
                    dnode.drawing = kayaDrawingImage(blobs[dhandle], dw, dh)
                }
            case applyPresentSaveDialog:
                // The platform's REAL save dialog, answered exactly once —
                // one locator, or a null one for cancel. A STR THEN A LIST, a
                // body shape no other apply record has: the name is read FIRST
                // and the list's count taken from wherever it ended.
                let saveWindow = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let saveDialog = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt64.self)
                var sat = body + 16
                func nextSaveStr() -> String {
                    let len = Int(raw.loadUnaligned(fromByteOffset: sat + 4, as: UInt32.self))
                    let bytes = raw[(sat + 8)..<(sat + 8 + len)]
                    sat += 8 + len
                    if sat % 8 != 0 { sat += 8 - sat % 8 }
                    return String(decoding: bytes, as: UTF8.self)
                }
                let suggestedName = nextSaveStr()
                let saveFilterCount = Int(
                    raw.loadUnaligned(fromByteOffset: sat, as: UInt32.self))
                sat += 8
                var saveExtensions: [String] = []
                for _ in 0..<(saveFilterCount / 2) {
                    _ = nextSaveStr()  // the label, shown by the panel itself
                    saveExtensions.append(contentsOf:
                        nextSaveStr().split(separator: " ").map {
                            String($0).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                        })
                }
                kayaPresentSaveDialog(
                    window: saveWindow,
                    dialog: saveDialog,
                    suggestedName: suggestedName,
                    extensions: saveExtensions)
            case applyPresentAlert:
                // The platform's REAL modal dialog (NSAlert sheet /
                // UIAlertController), answered exactly once through
                // kaya_emit_alert_result — an action index or the cancel
                // sentinel.
                let wid = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let aid = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt64.self)
                let actions = Int(raw.loadUnaligned(fromByteOffset: body + 16, as: UInt32.self))
                var at = body + 24
                func nextStr() -> String {
                    let len = Int(raw.loadUnaligned(fromByteOffset: at + 4, as: UInt32.self))
                    let bytes = raw[(at + 8)..<(at + 8 + len)]
                    at += 8 + len
                    if at % 8 != 0 { at += 8 - at % 8 }
                    return String(decoding: bytes, as: UTF8.self)
                }
                let title = nextStr()
                let message = nextStr()
                let action0 = nextStr()
                let action1 = nextStr()
                let cancel = nextStr()
                kayaLiveAlert = KayaLiveAlert(id: aid, window: wid, actions: actions)
                #if os(macOS)
                    let alert = NSAlert()
                    alert.messageText = title
                    alert.informativeText = message
                    if actions >= 1 { alert.addButton(withTitle: action0) }
                    if actions == 2 { alert.addButton(withTitle: action1) }
                    // The cancel slot is always last and owns Esc —
                    // NSAlert keys Esc off the TITLE "Cancel" only,
                    // and the label is the guest's to choose.
                    let cancelButton = alert.addButton(withTitle: cancel)
                    cancelButton.keyEquivalent = "\u{1b}"
                    kayaLiveNSAlert = alert
                    guard let host = kayaNSWindows[wid] else {
                        fatalError(
                            "kaya: present_alert over window \(wid) before its NSWindow materialized")
                    }
                    alert.beginSheetModal(for: host) { response in
                        let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                        let index = response.rawValue - first
                        let choice =
                            index >= 0 && index < actions
                            ? UInt32(index) : kayaAlertChoiceCancel
                        kayaLiveAlert = nil
                        kayaLiveNSAlert = nil
                        KayaHost.emitAlertResult(aid, choice)
                    }
                #else
                    let alert = UIAlertController(
                        title: title, message: message, preferredStyle: .alert)
                    func answer(_ choice: UInt32) {
                        kayaLiveAlert = nil
                        kayaLiveAlertController = nil
                        kayaAlertAnswers = [:]
                        KayaHost.emitAlertResult(aid, choice)
                    }
                    kayaAlertAnswers = [:]
                    if actions >= 1 {
                        alert.addAction(
                            UIAlertAction(title: action0, style: .default) { _ in answer(0) })
                        kayaAlertAnswers["0"] = { answer(0) }
                    }
                    if actions == 2 {
                        alert.addAction(
                            UIAlertAction(title: action1, style: .default) { _ in answer(1) })
                        kayaAlertAnswers["1"] = { answer(1) }
                    }
                    alert.addAction(
                        UIAlertAction(title: cancel, style: .cancel) { _ in
                            answer(kayaAlertChoiceCancel)
                        })
                    kayaAlertAnswers["cancel"] = { answer(kayaAlertChoiceCancel) }
                    kayaLiveAlertController = alert
                    let scenes = UIApplication.shared.connectedScenes
                    let ws = scenes.compactMap { $0 as? UIWindowScene }.first
                    ws?.windows.first?.rootViewController?
                        .present(alert, animated: false)
                #endif
            case applySetProp:
                let id = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                // prop (u32), u32 pad, then the value (type, len, bytes).
                let prop = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt32.self)
                let valueType = raw.loadUnaligned(fromByteOffset: body + 16, as: UInt32.self)
                let len = Int(raw.loadUnaligned(fromByteOffset: body + 20, as: UInt32.self))
                switch (prop, valueType) {
                case (propText, valueStr):
                    let bytes = raw[(body + 24)..<(body + 24 + len)]
                    let node = kayaScene.nodes[id]!
                    // D7 + A3: a programmatic write resets the widget's
                    // native undo history, and only when it CHANGED the text.
                    // The before-image is read here because this is the last
                    // moment it exists.
                    let previous = node.text
                    node.text = kayaLF(String(decoding: bytes, as: UTF8.self))
                    kayaNoteQuietTextWrite(id, from: previous, to: node.text)
                case (propChecked, valueBool):
                    kayaScene.nodes[id]!.checked = raw[body + 24] != 0
                case (propValue, valueF64):
                    kayaScene.nodes[id]!.value =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Double.self)
                    kayaScene.nodes[id]!.committed = kayaScene.nodes[id]!.value
                case (propStep, valueF64):
                    kayaScene.nodes[id]!.step =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Double.self)
                case (propTickSpacing, valueF64):
                    kayaScene.nodes[id]!.tickSpacing =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Double.self)
                case (propMin, valueF64):
                    kayaScene.nodes[id]!.minValue =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Double.self)
                case (propMax, valueF64):
                    kayaScene.nodes[id]!.maxValue =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Double.self)
                case (propDate, valueI64):
                    kayaScene.nodes[id]!.date =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Int64.self)
                case (propMinDate, valueI64):
                    kayaScene.nodes[id]!.minDate =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Int64.self)
                case (propMaxDate, valueI64):
                    kayaScene.nodes[id]!.maxDate =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Int64.self)
                case (propTime, valueI64):
                    kayaScene.nodes[id]!.time =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Int64.self)
                case (propMinuteStep, valueF64):
                    kayaScene.nodes[id]!.minuteStep =
                        Int(raw.loadUnaligned(fromByteOffset: body + 24, as: Double.self))
                case (propGrow, valueF64):
                    kayaScene.nodes[id]!.grow =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Double.self)
                case (propSpacing, valueF64):
                    kayaScene.nodes[id]!.spacing =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Double.self)
                case (propAlign, valueI64):
                    kayaScene.nodes[id]!.align =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Int64.self)
                case (propAxis, valueI64):
                    kayaScene.nodes[id]!.axis =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Int64.self)
                case (propIndeterminate, valueBool):
                    kayaScene.nodes[id]!.indeterminate = raw[body + 24] != 0
                case (propFill, valueBool):
                    kayaScene.nodes[id]!.fill = raw[body + 24] != 0
                case (propMinColumnWidth, valueF64):
                    kayaScene.nodes[id]!.minColumnWidth =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Double.self)
                case (propWrap, valueBool):
                    kayaScene.nodes[id]!.wrap = raw[body + 24] != 0
                case (propColumns, valueF64):
                    kayaScene.nodes[id]!.columns =
                        Int(raw.loadUnaligned(fromByteOffset: body + 24, as: Double.self))
                case (propA11yId, valueStr):
                    let bytes = raw[(body + 24)..<(body + 24 + len)]
                    kayaScene.nodes[id]!.a11yId = String(decoding: bytes, as: UTF8.self)
                case (propA11yLabel, valueStr):
                    let bytes = raw[(body + 24)..<(body + 24 + len)]
                    kayaScene.nodes[id]!.a11yLabel = String(decoding: bytes, as: UTF8.self)
                case (propA11yHint, valueStr):
                    let bytes = raw[(body + 24)..<(body + 24 + len)]
                    kayaScene.nodes[id]!.a11yHint = String(decoding: bytes, as: UTF8.self)
                case (propHelp, valueStr):
                    let bytes = raw[(body + 24)..<(body + 24 + len)]
                    kayaScene.nodes[id]!.help = String(decoding: bytes, as: UTF8.self)
                case (propAccepts, valueStr):
                    let bytes = raw[(body + 24)..<(body + 24 + len)]
                    kayaScene.nodes[id]!.accepts = String(decoding: bytes, as: UTF8.self)
                case (propRole, valueI64):
                    kayaScene.nodes[id]!.role =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Int64.self)
                case (propInset, valueF64):
                    kayaScene.nodes[id]!.inset =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Double.self)
                case (propSource, valueBlob):
                    // The value's payload is a u64 batch-local handle;
                    // the pump prefetched the bytes into `blobs`.
                    let handle = raw.loadUnaligned(fromByteOffset: body + 24, as: UInt64.self)
                    kayaDecodeImage(blobs[handle], into: kayaScene.nodes[id]!)
                default:
                    fatalError("kaya: cannot apply prop \(prop) with value type \(valueType)")
                }
            case applyAddChild:
                let parent = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let child = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt64.self)
                kayaScene.nodes[parent]!.children.append(kayaScene.nodes[child]!)
                kayaScene.parents[child] = parent
                // A choice widget's label children are its OPTIONS, so they
                // leave the harness's label#N registry (their create arm ran
                // before this parent was known); otherwise every later label
                // shifts index.
                let parentKind = kayaScene.nodes[parent]!.kind
                if parentKind == kindSelect || parentKind == kindRadio {
                    kayaScene.labels.removeAll { $0.id == child }
                }
            case applySetDragSource:
                // { u64 id; u32 present; u32 file_count; u32 custom_count;
                // u32 operations; u32 tag_len; u32 reserved; Values reps; tag }
                // — the copy record's values in the canonical order.
                let sid = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let spresent = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt32.self)
                let sfileCount = Int(raw.loadUnaligned(fromByteOffset: body + 12, as: UInt32.self))
                let scustomCount = Int(raw.loadUnaligned(fromByteOffset: body + 16, as: UInt32.self))
                let sops = raw.loadUnaligned(fromByteOffset: body + 20, as: UInt32.self)
                var sat = body + 40
                func nextDragValue() -> (UInt32, Range<Int>) {
                    let type = raw.loadUnaligned(fromByteOffset: sat, as: UInt32.self)
                    let len = Int(raw.loadUnaligned(fromByteOffset: sat + 4, as: UInt32.self))
                    let payload = (sat + 8)..<(sat + 8 + len)
                    sat += 8 + len
                    if sat % 8 != 0 { sat += 8 - sat % 8 }
                    return (type, payload)
                }
                func nextDragString() -> String {
                    String(decoding: raw[nextDragValue().1], as: UTF8.self)
                }
                func nextDragBytes() -> Data {
                    let handle = raw.loadUnaligned(
                        fromByteOffset: nextDragValue().1.lowerBound, as: UInt64.self)
                    return blobs[handle] ?? Data()
                }
                var payload = KayaDragPayload()
                for _ in 0..<scustomCount { payload.custom.append((nextDragString(), nextDragBytes())) }
                for _ in 0..<sfileCount { payload.files.append(nextDragString()) }
                if spresent & kayaClipImage != 0 { payload.image = nextDragBytes() }
                if spresent & kayaClipHtml != 0 { payload.html = nextDragString() }
                if spresent & kayaClipText != 0 { payload.text = nextDragString() }
                let stagLen = Int(raw.loadUnaligned(fromByteOffset: body + 24, as: UInt32.self))
                if let snode = kayaScene.nodes[sid] {
                    let empty = spresent == 0 && payload.files.isEmpty && payload.custom.isEmpty
                    snode.dragPayload = empty ? nil : payload
                    snode.dragOps = empty ? 0 : sops
                    snode.dndTag = Array(raw[sat..<(sat + stagLen)])
                }
            case applySetDropTarget:
                // { u64 id; u32 operations; u32 tag_len; tag }
                let tid = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let tops = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt32.self)
                let ttagLen = Int(raw.loadUnaligned(fromByteOffset: body + 12, as: UInt32.self))
                if let tnode = kayaScene.nodes[tid] {
                    tnode.dropOps = tops
                    tnode.dndTag = Array(raw[(body + 16)..<(body + 16 + ttagLen)])
                }
            case applySetReorderable:
                // { u64 id; u32 enabled; u32 tag_len; tag }
                let rid = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let renabled = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt32.self)
                let rtagLen = Int(raw.loadUnaligned(fromByteOffset: body + 12, as: UInt32.self))
                if let rnode = kayaScene.nodes[rid] {
                    rnode.reorderable = renabled != 0
                    rnode.dndTag = Array(raw[(body + 16)..<(body + 16 + rtagLen)])
                }
            case applyFold:
                // The stacked fold (D7). Order is the core's emission
                // order — the row's declaration order — so append holds
                // sibling order.
                let child = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let table = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt64.self)
                if let node = kayaScene.nodes[child] {
                    if node.foldedInto != 0, let prev = kayaScene.nodes[node.foldedInto] {
                        prev.foldedChildren.removeAll { $0.id == child }
                    }
                    node.foldedInto = table
                    if table != 0, let dest = kayaScene.nodes[table] {
                        dest.foldedChildren.append(node)
                    }
                }
            case applyMount:
                // The target is a SURFACE: the primary, an auxiliary
                // window, or a pushed navigation entry.
                let wid = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let root = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt64.self)
                if let entry = kayaScene.navEntries[wid] {
                    // An entry presents in-window: the push already put it on
                    // the stack; the mount fills it. Nothing new materializes.
                    entry.root = kayaScene.nodes[root]
                    break
                }
                if let section = kayaScene.sectionsById[wid] {
                    // A section presents in-window: the mount fills its pane.
                    // BUT THE WINDOW IT LIVES IN may be an auxiliary nothing
                    // presented — it mounts into SECTIONS and never a root, so
                    // this mount is its "mounting presents" moment.
                    section.root = kayaScene.nodes[root]
                    if let owner = kayaScene.sectionWindow[wid], owner != 0 {
                        if let open = kayaOpenWindow {
                            kayaEnsureOpen(owner, open)
                        } else {
                            kayaDiag("mount parked wid=\(owner) (no openWindow yet)")
                            kayaPendingOpens.append(owner)
                        }
                    }
                    break
                }
                kayaScene.windows[wid]?.root = kayaScene.nodes[root]
                // Mounting presents: auxiliaries open here (the primary's
                // window is the WindowGroup's own). A mount can precede the
                // first view's appearance — park it for the stash drain.
                if wid != 0 {
                    if let open = kayaOpenWindow {
                        kayaEnsureOpen(wid, open)
                    } else {
                        kayaDiag("mount parked wid=\(wid) (no openWindow yet)")
                        kayaPendingOpens.append(wid)
                    }
                }
            case applyMoveChild:
                let parent = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let child = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt64.self)
                let before = raw.loadUnaligned(fromByteOffset: body + 16, as: UInt64.self)
                let parentNode = kayaScene.nodes[parent]!
                let childNode = kayaScene.nodes[child]!
                parentNode.children.removeAll { $0.id == child }
                // before == 0: the end sentinel (widget ids start at 1).
                if before != 0, let at = parentNode.children.firstIndex(where: { $0.id == before }) {
                    parentNode.children.insert(childNode, at: at)
                } else {
                    parentNode.children.append(childNode)
                }
            case applyDestroy:
                let id = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                if let parent = kayaScene.parents.removeValue(forKey: id),
                    let parentNode = kayaScene.nodes[parent]
                {
                    parentNode.children.removeAll { $0.id == id }
                }
                kayaScene.nodes.removeValue(forKey: id)
                // A destroyed anchor takes its context attachment with it
                // (menu ITEMS are never destroyed; the anchor map entry is): a
                // For-row removal must not leave the harness's open-menu
                // pointer dangling.
                if kayaScene.contextRoots.removeValue(forKey: id) != nil {
                    kayaScene.contextNouns.removeValue(forKey: id)
                    if kayaOpenContextWidget == id {
                        kayaOpenContextWidget = nil
                    }
                }
            case applyCommand:
                let id = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let command = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt32.self)
                switch command {
                case commandClear:
                    // Model-driven, like set_text: the node's text is the
                    // field's text, and the app hears the empty edit through
                    // the same emission the binding's set would make.
                    let node = kayaScene.nodes[id]!
                    let previous = node.text
                    node.text = ""
                    KayaHost.emitText(node, "")
                    // D7's other quiet-write site: Clear is a programmatic
                    // write like any other, and the core refuses it inside an
                    // undo group precisely because it destroys widget-owned
                    // text.
                    kayaNoteQuietTextWrite(id, from: previous, to: "")
                case commandFocus:
                    kayaScene.focusedId = id
                default:
                    fatalError("kaya: unknown command \(command)")
                }
            case applyPushEntry:
                // Materializes covered/incoming: on the stack now, the
                // mount fills it. The path binding derives from the
                // stack, so NavigationStack animates the push.
                let wid = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let eid = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt64.self)
                let entry = KayaEntryModel(id: eid)
                kayaScene.navEntries[eid] = entry
                kayaScene.entryWindow[eid] = wid
                // The host surface may be a window OR a section —
                // stacks are per-surface (DESIGN.md, Sections).
                if let section = kayaScene.sectionsById[wid] {
                    section.entries.append(entry)
                } else {
                    kayaScene.windows[wid]!.entries.append(entry)
                }
                let pushedAt = Date().timeIntervalSince1970
                if kayaLastPopAt > 0, pushedAt - kayaLastPopAt < 1.0 {
                    kayaDiag("push_entry \(eid) on \(wid) \(Int((pushedAt - kayaLastPopAt) * 1000))ms after the last pop; entries=\(kayaStackEntries(wid).count)")
                }
            case applyPopEntry:
                // Programmatic pop: the core already reconciled its stack;
                // drop the top model and let the derived path animate the NET
                // change of the batch as one transition.
                let wid = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let entry =
                    kayaScene.sectionsById[wid]?.entries.removeLast()
                    ?? kayaScene.windows[wid]!.entries.removeLast()
                kayaScene.navEntries.removeValue(forKey: entry.id)
                kayaScene.entryWindow.removeValue(forKey: entry.id)
                kayaLastPopAt = Date().timeIntervalSince1970
            case applySetEntryProp:
                let eid = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let prop = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt32.self)
                let evType = raw.loadUnaligned(fromByteOffset: body + 16, as: UInt32.self)
                let entry = kayaScene.navEntries[eid]!
                switch (prop, evType) {
                case (epropTitle, valueStr):
                    let len = Int(raw.loadUnaligned(fromByteOffset: body + 20, as: UInt32.self))
                    let bytes = raw[(body + 24)..<(body + 24 + len)]
                    entry.title = String(decoding: bytes, as: UTF8.self)
                case (epropInterceptBack, valueBool):
                    entry.interceptBack = raw[body + 24] != 0
                default:
                    fatalError("kaya: bad entry prop \(prop) value type \(evType)")
                }
            case applyAddSection:
                // Append-only; the first added is already selected on
                // the core side — mirror that here so the switcher
                // shows a selection from the first frame.
                let wid = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let sid = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt64.self)
                let section = KayaSectionModel(id: sid)
                kayaScene.sectionsById[sid] = section
                kayaScene.sectionWindow[sid] = wid
                let window = kayaScene.windows[wid]!
                window.sections.append(section)
                if window.selectedSection == nil {
                    window.selectedSection = sid
                }
            case applySelectSection:
                // Programmatic and QUIET: the model moves, no emit
                // (the echo doctrine — only the user's switch emits).
                let wid = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let sid = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt64.self)
                kayaScene.windows[wid]!.selectedSection = sid
            case applySetSectionProp:
                let sid = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let prop = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt32.self)
                let svType = raw.loadUnaligned(fromByteOffset: body + 16, as: UInt32.self)
                let section = kayaScene.sectionsById[sid]!
                switch (prop, svType) {
                case (spropTitle, valueStr):
                    let len = Int(raw.loadUnaligned(fromByteOffset: body + 20, as: UInt32.self))
                    let bytes = raw[(body + 24)..<(body + 24 + len)]
                    section.title = String(decoding: bytes, as: UTF8.self)
                case (spropIcon, valueBlob):
                    // Day-one slot: decoded and rendered where the platform
                    // switcher shows icons; the tab TITLE is the harness
                    // observable.
                    break
                case (spropSymbol, valueI64):
                    // The tab item and sidebar row draw the platform's own
                    // glyph (docs/styling-plan.md D6). VALUE AT +24, NOT +20:
                    // the I64 payload is 8-aligned past the type word, and +20
                    // is padding that decodes as garbage rendering NO icon.
                    section.symbol =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Int64.self)
                default:
                    fatalError("kaya: bad section prop \(prop) value type \(svType)")
                }
            case applyMenuItemCreate:
                // u64 item, u32 kind, u32 pad — the menu-item id
                // space is its own (never widget/node/surface ids).
                let mid = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let mkind = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt32.self)
                kayaScene.menuItems[mid] = KayaMenuItemModel(id: mid, kind: mkind)
                menusTouched = true
            case applyMenuItemAppend:
                // u64 parent, u64 child — append-only, single-parent
                // (the root validates the closed grammar and depth).
                let parent = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let child = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt64.self)
                kayaScene.menuItems[parent]!.children.append(kayaScene.menuItems[child]!)
                kayaScene.menuParents[child] = parent
                menusTouched = true
            case applyMenubarAppend:
                // u64 window, u64 item — a top-level grouping node
                // joins the window's catalog in append order.
                let wid = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let mid = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt64.self)
                kayaScene.windows[wid]!.menubar.append(kayaScene.menuItems[mid]!)
                menusTouched = true
            case applyContextAttach:
                // u64 widget, u64 item — a live-widget anchor: the
                // same command vocabulary scoped to a noun, empty
                // noun (the direct route).
                let widget = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let mid = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt64.self)
                kayaScene.contextRoots[widget, default: []].append(kayaScene.menuItems[mid]!)
                menusTouched = true
            case applyContextAttachNode:
                // u64 widget (the STAMPED copy), u64 item, then the copy's key
                // path { u32 count; u32 reserved; count values } — kept as raw
                // wire bytes, handed back verbatim as an activation's noun
                // (values self-pad to 8, so the path runs to the record end).
                let widget = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let mid = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt64.self)
                kayaScene.contextRoots[widget, default: []].append(kayaScene.menuItems[mid]!)
                kayaScene.contextNouns[widget] = [UInt8](raw[(body + 16)..<(at + size)])
                menusTouched = true
            case applySetMenuProp:
                // u64 item, u32 mprop, u32 pad, value. Programmatic
                // checked/value writes are configuration and stay
                // QUIET (the echo doctrine); nothing here emits.
                let mid = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let prop = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt32.self)
                let mvType = raw.loadUnaligned(fromByteOffset: body + 16, as: UInt32.self)
                let mvLen = Int(raw.loadUnaligned(fromByteOffset: body + 20, as: UInt32.self))
                let item = kayaScene.menuItems[mid]!
                switch (prop, mvType) {
                case (mpropLabel, valueStr):
                    let bytes = raw[(body + 24)..<(body + 24 + mvLen)]
                    item.label = String(decoding: bytes, as: UTF8.self)
                case (mpropEnabled, valueBool):
                    item.enabled = raw[body + 24] != 0
                case (mpropChecked, valueBool):
                    item.checked = raw[body + 24] != 0
                case (mpropValue, valueF64):
                    item.value =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Double.self)
                case (mpropPrimary, valueBool):
                    // The phone-promotion hint: the promoted set recomputes
                    // from the observable catalog, so this write re-renders
                    // the iOS toolbar; inert on desktop.
                    item.primary = raw[body + 24] != 0
                case (mpropShortcut, valueStr):
                    let bytes = raw[(body + 24)..<(body + 24 + mvLen)]
                    item.shortcut = String(decoding: bytes, as: UTF8.self)
                case (mpropRole, valueStr):
                    // A standard-command role: macOS relocates the item into
                    // the application menu (the one place a role may enter
                    // dress-owned chrome); every other host leaves it where
                    // the app put it.
                    let bytes = raw[(body + 24)..<(body + 24 + mvLen)]
                    item.role = String(decoding: bytes, as: UTF8.self)
                case (mpropIcon, valueBlob):
                    // Used by phone promotion; ignored where native menu dress
                    // has no icon. Failed decode is the placeholder class.
                    let handle = raw.loadUnaligned(fromByteOffset: body + 24, as: UInt64.self)
                    item.icon = blobs[handle].flatMap { KayaPlatformImage(data: $0) }
                case (mpropSymbol, valueI64):
                    // The SEMANTIC ICON (docs/styling-plan.md D6): a concept,
                    // resolved to this platform's glyph when the item is
                    // materialized.
                    item.symbol =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Int64.self)
                default:
                    fatalError("kaya: bad menu prop \(prop) value type \(mvType)")
                }
                menusTouched = true
            default:
                fatalError("kaya: unknown apply record kind \(kind)")
            }
            at += size
        }
    }
    #if !os(macOS)
        // Any batch can move the widget that decides a screen's grouped
        // verdict, so the registry is recomputed at every batch tail, over
        // REALIZED nodes only. BEFORE the admission drive, whose pinned tail is
        // the batch boundary (tools/check-steps.py).
        kayaRecomputeGroupedSurfaces()
    #endif
    if menusTouched {
        kayaMenuChanged()
    }
    kayaDriveSelftestAdmission()
}

private func kayaWindowHasMountedContent(_ window: KayaWindowModel) -> Bool {
    if window.root != nil || window.entries.contains(where: { $0.root != nil }) {
        return true
    }
    return window.sections.contains { section in
        section.root != nil || section.entries.contains(where: { $0.root != nil })
    }
}

private func kayaDriveSelftestAdmission(graceExpired: Bool = false, startupExpired: Bool = false) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard ProcessInfo.processInfo.environment["KAYA_SELFTEST"] != nil else { return }
    if startupExpired, kayaSelftestAdmissionState != .started {
        kayaDiag("selftest startup deadline fired with admission still waiting")
    }
    let mounted = kayaScene.windows.values.contains(where: kayaWindowHasMountedContent)
    let (next, effect) = kayaSelftestAdmissionTransition(
        kayaSelftestAdmissionState,
        mounted: mounted,
        hasNodes: !kayaScene.nodes.isEmpty,
        graceExpired: graceExpired,
        startupExpired: startupExpired)
    kayaSelftestAdmissionState = next
    switch effect {
    case .none:
        break
    case .armGrace:
        DispatchQueue.main.asyncAfter(deadline: .now() + kayaSelftestUnmountedGrace) {
            kayaDriveSelftestAdmission(graceExpired: true)
        }
    case .start:
        kayaStartSelftest()
    }
}

/// The interaction harness's Swift interpreter: the same line-oriented grammar
/// the Rust backends embed from tools/scenes (targets as kind#index, `;`
/// accepted as a newline stand-in). The suites hand the script in through
/// KAYA_SELFTEST_SCRIPT; steps drive the node tree exactly as a gesture would.
func kayaStartSelftest() {
    guard ProcessInfo.processInfo.environment["KAYA_SELFTEST"] != nil else { return }
    guard let script = ProcessInfo.processInfo.environment["KAYA_SELFTEST_SCRIPT"] else {
        FileHandle.standardError.write(
            "KAYA_SELFTEST: FAILED (no KAYA_SELFTEST_SCRIPT in the environment)\n"
                .data(using: .utf8)!)
        exit(1)
    }
    Thread {
        kayaRunScript(script)
    }.start()
}

/// Apply the two universal accessibility props to a widget's own view — the
/// CONTROL, never a wrapping Group, where an identifier never appears in the
/// tree. Empty means unset and stays untouched: an empty label SILENCES.
@ViewBuilder
func kayaA11y(_ view: some View, _ node: KayaNode) -> some View {
    // Containers need `.contain` first or these props do the wrong thing on
    // them (docs/traps.md, "SwiftUI containers do not take accessibility props
    // the way leaves do").
    let isContainer =
        node.kind == kindColumn || node.kind == kindRow || node.kind == kindGrid
        || node.kind == kindScroll
    let addressed =
        (isContainer && !(node.a11yId.isEmpty && node.a11yLabel.isEmpty))
        ? AnyView(view.accessibilityElement(children: .contain)) : AnyView(view)
    let identified =
        node.a11yId.isEmpty
        ? addressed : AnyView(addressed.accessibilityIdentifier(node.a11yId))
    let labelled =
        node.a11yLabel.isEmpty
        ? identified : AnyView(identified.accessibilityLabel(node.a11yLabel))
    // HELP TEXT (docs/tooltip-plan.md): `.help` is the Mac's tooltip (and
    // an iPad app's when it runs on a Mac; iPadOS itself draws none), and
    // Apple's own mapping makes it the accessibility hint too. It goes on
    // BEFORE the hint so an authored hint wins the hint slot (T3).
    let helped =
        node.help.isEmpty ? labelled : AnyView(labelled.help(node.help))
    // The HINT: what activating this control does. Apple speaks it after the
    // label and forbids naming the gesture, which is why the authored text is
    // a verb phrase.
    if node.a11yHint.isEmpty {
        helped
    } else {
        helped.accessibilityHint(node.a11yHint)
    }
}

/// Normalize one platform role name into the harness's closed set. The point
/// of the verb is that the PLATFORM classified the control, so anything kaya
/// has no name for reports `unknown` rather than being guessed at.
#if os(macOS)
    private func kayaAxRole(_ role: String?) -> String {
        switch role {
        case kAXButtonRole: return "button"
        case kAXStaticTextRole: return "label"
        // A label with the heading role (docs/styling-plan.md D4): SwiftUI's
        // .isHeader surfaces as the AXHeading ROLE on macOS — measured on the
        // styling scene's first run, not assumed.
        case "AXHeading": return "heading"
        case kAXTextFieldRole, kAXTextAreaRole: return "field"
        case kAXCheckBoxRole: return "checkbox"
        case kAXSliderRole: return "slider"
        // NSDatePicker publishes ONE role for a date and a time picker alike
        // (measured 2026-09-04 on the pickers scene): the closed set's
        // `datetime` (docs/datetime-plan.md P4).
        case "AXDateTimeArea": return "datetime"
        case kAXImageRole: return "image"
        case kAXProgressIndicatorRole: return "progress"
        // A chooser is a chooser everywhere and spelled differently
        // everywhere: AXPopUpButton here, a dropdown role on Compose, ComboBox
        // on AT-SPI and UIA. `combobox` is the closed set's one name for it
        // (harness.rs check_ax).
        case kAXPopUpButtonRole: return "combobox"
        // NORMALIZED DOWN to the coarsest role every platform agrees on.
        // macOS publishes finer container roles than the others do, and the
        // closed set exists to make a scene read the same everywhere.
        case kAXRadioGroupRole, kAXScrollAreaRole: return "group"
        case kAXGroupRole: return "group"
        default: return "unknown"
        }
    }

    /// Read the tree the way an assistive client does: the AXUIElement CLIENT
    /// API against our own pid, never the server-side NSAccessibility protocol
    /// (docs/traps.md, "macOS builds the accessibility tree lazily").
    private func kayaAxCopy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        kayaAxCopyCount += 1
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return err == .success ? value : nil
    }

    private func kayaAxFind(
        _ element: AXUIElement, _ identifier: String, _ depth: Int = 0
    ) -> AXUIElement? {
        if depth > 64 { return nil }
        if let ident = kayaAxCopy(element, kAXIdentifierAttribute) as? String,
            ident == identifier
        {
            return element
        }
        // An AXApplication publishes its WINDOWS under kAXWindows, not
        // kAXChildren — children there is the menu bar alone. Measured:
        // walking children only ever reached the menu tree.
        for child in kayaAxKids(element) {
            if let hit = kayaAxFind(child, identifier, depth + 1) { return hit }
        }
        return nil
    }

    /// Every element carrying the identifier, not just the first: the count is
    /// what lets an ambiguous id be REFUSED rather than guessed at. Taking the
    /// first was measured lying (2026-08-11), two stamped copies sharing an id.
    private func kayaAxFindAll(
        _ element: AXUIElement, _ identifier: String, _ depth: Int = 0,
        _ out: inout [AXUIElement]
    ) {
        if depth > 64 || out.count > 8 { return }
        if let ident = kayaAxCopy(element, kAXIdentifierAttribute) as? String,
            ident == identifier,
            // DEDUPLICATED BY ELEMENT IDENTITY: the tree reaches one element
            // down more than one path (kAXWindows and kAXChildren overlap two
            // levels apart, past kayaAxKids' per-parent dedup), so without this
            // 19 of 19 unique ids read as "shared by 2 elements".
            !out.contains(where: { CFEqual($0, element) })
        {
            out.append(element)
        }
        for child in kayaAxKids(element) {
            kayaAxFindAll(child, identifier, depth + 1, &out)
        }
    }

    private func kayaAxKids(_ element: AXUIElement) -> [AXUIElement] {
        let children = kayaAxCopy(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        let windows = kayaAxCopy(element, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let nav =
            kayaAxCopy(element, "AXChildrenInNavigationOrder" as String) as? [AXUIElement]
            ?? []
        // Deduplicate by element identity across ALL THREE attributes: an
        // AXApplication publishes one window under kAXWindows and kAXChildren
        // both, and a walk that dedups only `nav` descends each subtree twice —
        // 1008 attribute reads per walk (docs/deferred.md's AX dedup entry).
        var out = windows
        for c in children where !out.contains(where: { CFEqual($0, c) }) { out.append(c) }
        for n in nav where !out.contains(where: { CFEqual($0, n) }) { out.append(n) }
        return out
    }

    /// KAYA_AX_TRACE=1 dumps the real tree — the fastest way to see what
    /// the platform actually publishes rather than guess at it.
    private func kayaAxDump(_ element: AXUIElement, _ depth: Int = 0) {
        if depth > 12 { return }
        let pad = String(repeating: "  ", count: depth)
        let role = kayaAxCopy(element, kAXRoleAttribute) as? String ?? "nil"
        let ident = kayaAxCopy(element, kAXIdentifierAttribute) as? String ?? "nil"
        let label = kayaAxCopy(element, kAXDescriptionAttribute) as? String ?? "nil"
        let title = kayaAxCopy(element, kAXTitleAttribute) as? String ?? "nil"
        var namesRef: CFArray?
        AXUIElementCopyAttributeNames(element, &namesRef)
        let names = (namesRef as? [String] ?? []).joined(separator: ",")
        FileHandle.standardError.write(
            Data(
                "KAYA_AX_TRACE: \(pad)role=\(role) id=\(ident) desc=\(label) title=\(title) attrs=[\(names)]\n"
                    .utf8))
        for child in kayaAxKids(element) { kayaAxDump(child, depth + 1) }
    }

    private var kayaAxAnnounced = false
    /// Every attribute read the walks make goes through kayaAxCopy; this
    /// is the count KAYA_AX_COUNT reports per identifier walk.
    private var kayaAxCopyCount = 0

    private func kayaAxRead(_ identifier: String) -> String? {
        guard !identifier.isEmpty else { return nil }
        // WAIT FOR THE WINDOW, ON THE EVENT — never on a clock: kayaAwaitWindow
        // parks on the registration signal, because an AX call landing during
        // the appear/layout pass DEADLOCKS rather than failing.
        _ = kayaAwaitWindow(0)
        // …then read ON THE MAIN THREAD (docs/traps.md, "Reading your OWN
        // process's accessibility tree runs INLINE, on your thread"): no
        // messaging timeout can bound a call that never sends a message.
        return DispatchQueue.main.sync { kayaAxReadOnMain(identifier) }
    }

    private func kayaAxReadOnMain(_ identifier: String) -> String? {
        let app = AXUIElementCreateApplication(getpid())
        // The harness IS an assistive client here (docs/traps.md, "macOS
        // builds the accessibility tree lazily"). EVERY AX CALL IS BOUNDED,
        // AND THE BOUND COMES FIRST: the read is serviced by the MAIN RUNLOOP,
        // so a busy main thread blocks it and the default timeout eats a leg.
        AXUIElementSetMessagingTimeout(app, 2.0)
        // ANNOUNCED ONCE PER PROCESS, not once per read: AppKit rebuilds its
        // whole accessibility hierarchy in response and drives a full layout
        // pass, which was measured hanging legs past their 120s timeout.
        if !kayaAxAnnounced {
            kayaAxAnnounced = true
            AXUIElementSetAttributeValue(
                app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(
                app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        if ProcessInfo.processInfo.environment["KAYA_AX_TRACE"] != nil {
            FileHandle.standardError.write(
                Data("KAYA_AX_TRACE: trusted=\(AXIsProcessTrusted())\n".utf8))
            kayaAxDump(app)
        }
        var matches: [AXUIElement] = []
        let readsBefore = kayaAxCopyCount
        kayaAxFindAll(app, identifier, 0, &matches)
        // KAYA_AX_COUNT=1 prints what one identifier walk cost in attribute
        // reads — the number the walk's dedup was measured by.
        if ProcessInfo.processInfo.environment["KAYA_AX_COUNT"] != nil {
            FileHandle.standardError.write(
                Data("KAYA_AX_COUNT: '\(identifier)' reads=\(kayaAxCopyCount - readsBefore)\n".utf8))
        }
        guard let hit = matches.first else { return nil }
        // AN AMBIGUOUS IDENTIFIER IS REFUSED, NOT RESOLVED: this read
        // addresses the tree BY IDENTIFIER, so two elements sharing one id
        // leave it guessing. The refusal names only what it measured.
        if matches.count > 1 {
            return "<ambiguous: \(matches.count) elements share id '\(identifier)' — "
                + "expect_ax addresses the tree by identifier and cannot tell "
                + "them apart; give each element its own id>"
        }
        let role = kayaAxRole(kayaAxCopy(hit, kAXRoleAttribute) as? String)
        // A control's spoken name is its DESCRIPTION when authored and its
        // TITLE when derived, so the authored one comes first. STATIC TEXT
        // publishes nil for both and carries its string in AXValue (measured
        // 2026-07-25), which is a String only where it is text.
        let label =
            [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute]
            .lazy
            .compactMap { kayaAxCopy(hit, $0 as String) as? String }
            .first { !$0.isEmpty } ?? ""
        return role + "/" + label
    }

    /// What one textarea's text layer, selection and viewport say, in ONE
    /// main-thread hop. WHY THE HIGHLIGHT READ FORCES THE LOWERING'S HAND: of
    /// three macOS background mechanisms only `NSTextStorage`'s is published to
    /// accessibility (docs/probes/range-probe-mac.md §1).
    private struct KayaAxRanges {
        var text: String
        var highlights: [NSRange]
        var selection: NSRange?
        var visible: NSRange?
    }

    private func kayaAxRangesRead(_ identifier: String) -> KayaAxRanges? {
        guard !identifier.isEmpty else { return nil }
        _ = kayaAwaitWindow(0)
        return DispatchQueue.main.sync { () -> KayaAxRanges? in
            let app = AXUIElementCreateApplication(getpid())
            AXUIElementSetMessagingTimeout(app, 2.0)
            if !kayaAxAnnounced {
                kayaAxAnnounced = true
                AXUIElementSetAttributeValue(
                    app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(
                    app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            }
            guard let hit = kayaAxFind(app, identifier) else { return nil }
            let text = kayaAxCopy(hit, kAXValueAttribute) as? String ?? ""

            func cfRange(_ attribute: String) -> NSRange? {
                guard let raw = kayaAxCopy(hit, attribute) else { return nil }
                var out = CFRange(location: 0, length: 0)
                guard AXValueGetValue(raw as! AXValue, .cfRange, &out) else { return nil }
                return NSRange(location: out.location, length: out.length)
            }

            var runs: [NSRange] = []
            var whole = CFRange(location: 0, length: (text as NSString).length)
            if let param = AXValueCreate(.cfRange, &whole) {
                var out: CFTypeRef?
                let err = AXUIElementCopyParameterizedAttributeValue(
                    hit,
                    kAXAttributedStringForRangeParameterizedAttribute as CFString,
                    param, &out)
                if err == .success, let attributed = out as? NSAttributedString {
                    attributed.enumerateAttribute(
                        NSAttributedString.Key(rawValue: "AXBackgroundColor"),
                        in: NSRange(location: 0, length: attributed.length)
                    ) { value, range, _ in
                        if value != nil { runs.append(range) }
                    }
                }
            }
            return KayaAxRanges(
                text: text,
                highlights: runs,
                selection: cfRange(kAXSelectedTextRangeAttribute),
                visible: cfRange(kAXVisibleCharacterRangeAttribute))
        }
    }

    /// The HINT as the platform publishes it: AXHelp is where
    /// `.accessibilityHint()` lands on macOS.
    private func kayaAxHintRead(_ identifier: String) -> String? {
        guard !identifier.isEmpty else { return nil }
        _ = kayaAwaitWindow(0)
        return DispatchQueue.main.sync { () -> String? in
            let app = AXUIElementCreateApplication(getpid())
            AXUIElementSetMessagingTimeout(app, 2.0)
            if !kayaAxAnnounced {
                kayaAxAnnounced = true
                AXUIElementSetAttributeValue(
                    app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(
                    app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            }
            guard let hit = kayaAxFind(app, identifier) else { return nil }
            return kayaAxCopy(hit, kAXHelpAttribute as String) as? String ?? ""
        }
    }

    /// Whether the window's CHROME really shows the unsaved-work mark: `AXEdited`
    /// on the CLOSE BUTTON, measured (the AXWindow carries no edited state). nil
    /// = unreadable, never `false`; the thread rule is docs/traps.md's.
    private func kayaWindowEdited(_ windowId: UInt64) -> Bool? {
        guard kayaAwaitWindow(windowId) != nil else { return nil }
        return DispatchQueue.main.sync { () -> Bool? in
            guard let window = kayaTitleWindow(windowId) else { return nil }
            let app = AXUIElementCreateApplication(getpid())
            // Bounded like every AX call here: reading your own process
            // is still serviced by the main runloop.
            AXUIElementSetMessagingTimeout(app, 2.0)
            let windows = kayaAxCopy(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
            // AX publishes no window id, and SwiftUI's AXIdentifier is
            // derived from the root view TYPE (every aux surface shares one),
            // so the title is the key. A lone window needs no matching.
            let element =
                windows.first {
                    (kayaAxCopy($0, kAXTitleAttribute) as? String) == window.title
                } ?? (windows.count == 1 ? windows[0] : nil)
            guard let element else { return nil }
            guard let close = kayaAxCopy(element, kAXCloseButtonAttribute),
                CFGetTypeID(close) == AXUIElementGetTypeID()
            else { return nil }
            // swiftlint:disable:next force_cast
            let button = close as! AXUIElement
            guard let edited = kayaAxCopy(button, "AXEdited" as String) as? NSNumber
            else { return nil }
            return edited.boolValue
        }
    }

    /// What [kayaAxRole] weighed, for a MISMATCH: `unknown/…` means the
    /// platform published a role the closed set has no name for, and the next
    /// question is always which one.
    private func kayaAxWhy(_ identifier: String) -> String {
        let app = AXUIElementCreateApplication(getpid())
        guard let hit = kayaAxFind(app, identifier) else { return "" }
        let role = kayaAxCopy(hit, kAXRoleAttribute as String) as? String ?? "nil"
        let subrole = kayaAxCopy(hit, kAXSubroleAttribute as String) as? String ?? "nil"
        return " (role=\(role) subrole=\(subrole))"
    }

#else
    /// UIKit has NO role vocabulary — a TRAIT BITMASK plus the class, one trait
    /// riding several kinds (docs/traps.md, "iOS materializes no accessibility
    /// tree until automation is enabled"). The order below is not stylistic:
    /// SPECIFIC signals are weighed before `.button`.
    private func kayaAxRole(_ element: NSObject) -> String {
        let traits = element.accessibilityTraits
        // A Toggle publishes button|toggleButton (traits
        // 9007199254740993 = 1 | 1<<53, measured 2026-07-25). The trait
        // is iOS 17; below that the switch is only its class.
        if #available(iOS 17.0, *), traits.contains(.toggleButton) { return "checkbox" }
        if element is UISwitch { return "checkbox" }
        // A compact UIDatePicker is the accessibility element itself and
        // publishes NO traits at all (traits 0, elements 0, measured
        // 2026-09-04), so the CLASS is the only signal there is; it is
        // weighed here because the wheel style publishes `.adjustable`
        // (docs/datetime-plan.md P4).
        if element is UIDatePicker { return "datetime" }
        if traits.contains(.adjustable) { return "slider" }
        if traits.contains(.image) { return "image" }
        // A ProgressView publishes `updatesFrequently` and nothing else
        // (traits 512, measured): the element is not a UIProgressView at all
        // under SwiftUI.
        if traits.contains(.updatesFrequently) { return "progress" }
        // THE CHOOSER. iOS has no combo box: a menu-style picker is a UIButton
        // that OWNS A MENU (traits 1 — a plain button — on class
        // UIKitIconPreferringButton, measured), and the menu is the platform's
        // own evidence.
        if let button = element as? UIButton, button.menu != nil { return "combobox" }
        if traits.contains(.button) { return "button" }
        if element is UITextView || element is UITextField { return "field" }
        // A HEADING LABEL publishes header|staticText (traits 65600 = 0x40 |
        // 1<<16, measured 2026-08-12): `.header` rides ON TOP of staticText, so
        // it is weighed first or every heading reads as a plain label.
        if traits.contains(.header) { return "heading" }
        if traits.contains(.staticText) { return "label" }
        // CONTAINERS. A scroll view is a container of content by class;
        // anything else that publishes accessibility ELEMENTS rather than
        // being one is a group.
        if element is UIScrollView { return "group" }
        let count = element.accessibilityElementCount()
        if count != NSNotFound && count > 0 { return "group" }
        return "unknown"
    }

    /// UIKit publishes accessibility IN-PROCESS, so this arm is not a copy of the
    /// macOS one. SwiftUI's elements are not UIViews and do not conform to
    /// UIAccessibilityIdentification, so the ObjC selector is the way in
    /// (docs/traps.md, "iOS materializes no accessibility tree…").
    private func kayaAxIdentifier(_ node: NSObject) -> String? {
        if let ident = (node as? UIAccessibilityIdentification)?.accessibilityIdentifier,
            !ident.isEmpty
        {
            return ident
        }
        let selector = NSSelectorFromString("accessibilityIdentifier")
        if node.responds(to: selector),
            let ident = node.perform(selector)?.takeUnretainedValue() as? String,
            !ident.isEmpty
        {
            return ident
        }
        return nil
    }

    private func kayaAxFind(_ node: NSObject, _ identifier: String, _ depth: Int = 0)
        -> NSObject?
    {
        if depth > 64 { return nil }
        if kayaAxIdentifier(node) == identifier {
            return node
        }
        let count = node.accessibilityElementCount()
        if count != NSNotFound && count > 0 {
            for i in 0..<count {
                if let child = node.accessibilityElement(at: i) as? NSObject,
                    let hit = kayaAxFind(child, identifier, depth + 1)
                {
                    return hit
                }
            }
        }
        if let view = node as? UIView {
            for sub in view.subviews {
                if let hit = kayaAxFind(sub, identifier, depth + 1) { return hit }
            }
        }
        return nil
    }

    /// What the walk actually saw, printed ONCE on the first miss. A silent
    /// "not in the accessibility tree" costs a whole simulator round-trip per
    /// question, and the tree's shape cannot be guessed from the source.
    private func kayaAxDump(_ node: NSObject, _ depth: Int = 0) {
        if depth > 12 { return }
        let pad = String(repeating: "  ", count: depth)
        let count = node.accessibilityElementCount()
        let elements = count == NSNotFound ? 0 : count
        FileHandle.standardError.write(
            Data(
                """
                KAYA_AX_TRACE: \(pad)\(type(of: node)) \
                id=\(kayaAxIdentifier(node) ?? "nil") \
                label=\(node.accessibilityLabel ?? "nil") \
                traits=\(node.accessibilityTraits.rawValue) \
                isElement=\(node.isAccessibilityElement) elements=\(elements) \
                subviews=\((node as? UIView)?.subviews.count ?? 0)

                """.utf8))
        for i in 0..<elements {
            if let child = node.accessibilityElement(at: i) as? NSObject {
                kayaAxDump(child, depth + 1)
            }
        }
        if let view = node as? UIView {
            for sub in view.subviews { kayaAxDump(sub, depth + 1) }
        }
    }

    private var kayaAxDumped = false
    private var kayaAxAutomationOn = false

    /// Flip the AX runtime's AUTOMATION switch, which is what materializes the
    /// tree at all here (docs/traps.md, "iOS materializes no accessibility tree
    /// until automation is enabled"). dlsym, so no shipped binary references a
    /// private symbol.
    private func kayaAxEnableAutomation() {
        if kayaAxAutomationOn { return }
        kayaAxAutomationOn = true
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
            let symbol = dlsym(handle, "_AXSSetAutomationEnabled")
        else {
            FileHandle.standardError.write(
                Data("KAYA_AX_TRACE: no _AXSSetAutomationEnabled; the tree stays empty\n".utf8))
            return
        }
        typealias KayaSetAutomation = @convention(c) (Bool) -> Void
        unsafeBitCast(symbol, to: KayaSetAutomation.self)(true)
    }

    private func kayaAxRead(_ identifier: String) -> String? {
        guard !identifier.isEmpty else { return nil }
        // The tree materializes asynchronously after the switch flips;
        // the step's bounded retry is what waits for it (no sleep here —
        // a fixed wait would be a guess, and the retry already exists).
        kayaAxEnableAutomation()
        for scene in UIApplication.shared.connectedScenes.compactMap({
            $0 as? UIWindowScene
        }) {
            for window in scene.windows {
                if let hit = kayaAxFind(window, identifier) {
                    // A control's spoken name is its LABEL when authored and
                    // its VALUE when derived from its own content: an unnamed
                    // text field publishes no label at all. NO SCENE CAN CATCH
                    // IT — both of the a11y scene's field reads are authored.
                    let spoken =
                        [hit.accessibilityLabel, hit.accessibilityValue]
                        .lazy
                        .compactMap { $0 }
                        .first { !$0.isEmpty } ?? ""
                    return kayaAxRole(hit) + "/" + spoken
                }
            }
        }
        if !kayaAxDumped {
            kayaAxDumped = true
            for scene in UIApplication.shared.connectedScenes.compactMap({
                $0 as? UIWindowScene
            }) {
                for window in scene.windows { kayaAxDump(window) }
            }
        }
        return nil
    }

    /// The HINT as UIKit publishes it — `.accessibilityHint()` lands
    /// straight on the element.
    private func kayaAxHintRead(_ identifier: String) -> String? {
        guard !identifier.isEmpty else { return nil }
        kayaAxEnableAutomation()
        // ON THE MAIN THREAD, like the Mac's reader: walking the window tree
        // from the harness thread laid a UITextField out off-main and UIKit
        // logged its assertion on every tooltips leg (device log, 2026-09-05);
        // a main-thread checker traps where the log only complains.
        return DispatchQueue.main.sync { () -> String? in
            for scene in UIApplication.shared.connectedScenes.compactMap({
                $0 as? UIWindowScene
            }) {
                for window in scene.windows {
                    if let hit = kayaAxFind(window, identifier) {
                        return hit.accessibilityHint ?? ""
                    }
                }
            }
            return nil
        }
    }

    /// What [kayaAxRole] weighed, for a MISMATCH. UIKit has no role vocabulary
    /// — a trait bitmask plus the element's class — so `unknown/…` is never
    /// self-explaining, and it is one simulator round-trip per answer without
    /// this.
    private func kayaAxWhy(_ identifier: String) -> String {
        for scene in UIApplication.shared.connectedScenes.compactMap({
            $0 as? UIWindowScene
        }) {
            for window in scene.windows {
                guard let hit = kayaAxFind(window, identifier) else { continue }
                let count = hit.accessibilityElementCount()
                return " (class=\(type(of: hit)) traits=\(hit.accessibilityTraits.rawValue)"
                    + " elements=\(count == NSNotFound ? 0 : count))"
            }
        }
        return ""
    }

    /// The unsaved-work mark as THIS platform can honestly report it: the APPLIED
    /// PROP, since iOS lowers `dirty` to nothing (docs/dirty-plan.md D4/D5). NOT
    /// THE SCRIPT AGREEING WITH ITSELF — one line writes it, WATCHED red. nil
    /// means UNREADABLE, never `false`.
    private func kayaWindowDirtyState(_ windowId: UInt64) -> Bool? {
        DispatchQueue.main.sync { () -> Bool? in
            kayaScene.windows[windowId]?.dirty
        }
    }

    /// The UITextView a range verb is addressed to, by the accessibility walk.
    /// ASKED FOR A UITextView SPECIFICALLY: on iOS the accessibility element for
    /// a text control IS the view (the range probe measured `sameObject=true`).
    private func kayaUITextTarget(_ identifier: String) -> UITextView? {
        guard !identifier.isEmpty else { return nil }
        kayaAxEnableAutomation()
        func walk(_ node: NSObject, _ depth: Int) -> UITextView? {
            if depth > 64 { return nil }
            if let view = node as? UITextView, kayaAxIdentifier(node) == identifier {
                return view
            }
            let count = node.accessibilityElementCount()
            if count != NSNotFound && count > 0 {
                for i in 0..<count {
                    if let child = node.accessibilityElement(at: i) as? NSObject,
                        let hit = walk(child, depth + 1)
                    {
                        return hit
                    }
                }
            }
            if let view = node as? UIView {
                for sub in view.subviews {
                    if let hit = walk(sub, depth + 1) { return hit }
                }
            }
            return nil
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                if let hit = walk(window, 0) { return hit }
            }
        }
        return nil
    }

    /// EVERY RANGE READ CROSSES THIS FIRST: `DispatchQueue.main.sync` jumps the
    /// queue SwiftUI scheduled `updateUIView` on, so a read lands before the
    /// lowering and no retry saves it. Measured 2026-08-06 with D4's IME refusal
    /// deleted: no barrier passed 5 runs of 7, the barrier failed 3 of 3.
    private func kayaSettleRender() {
        CATransaction.flush()
    }

    /// What one textarea's text layer and selection say, off the live control.
    /// `painted` IS A PIXEL FACT: a TextKit 2 rendering attribute reads back
    /// exactly while drawing NOTHING (docs/probes/range-probe-ios.md M2/N1).
    private struct KayaUIRanges {
        var text: String
        var highlights: [NSRange]
        var selection: NSRange
        var painted: Bool
    }

    /// Chromatic pixels in what the view REALLY DRAWS; a FOCUSED view's selection
    /// tint can only make it MISS a failure. `drawHierarchy(afterScreenUpdates:)`
    /// AND NOT `layer.render(in:)` — measured 2026-08-06, 0 coloured pixels
    /// against 5906, because `render(in:)` ignores a scroll view's origin.
    private func kayaPaintedPixels(_ view: UIView) -> Int {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return 0 }
        let format = UIGraphicsImageRendererFormat.default()
        // Scale 1: this is a yes/no about colour, not a rendering test, and a
        // 3x bitmap is nine times the pixels to walk for the same answer.
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            _ = view.drawHierarchy(
                in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        guard let cg = image.cgImage else { return 0 }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard
                let ctx = CGContext(
                    data: raw.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        var coloured = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            if max(r, max(g, b)) - min(r, min(g, b)) > 40 { coloured += 1 }
        }
        return coloured
    }

    /// `wantsPaint` is the highlight verb asking for the pixel fact.
    /// `expect_selection` shares this read and must NOT ask: iOS paints no
    /// selection in an unfocused view, and a read may not force a screen update.
    private func kayaUIRangesRead(_ identifier: String, wantsPaint: Bool) -> KayaUIRanges? {
        DispatchQueue.main.sync { () -> KayaUIRanges? in
            kayaSettleRender()
            guard let view = kayaUITextTarget(identifier) else { return nil }
            let storage = view.textStorage
            var runs: [NSRange] = []
            storage.enumerateAttribute(
                .backgroundColor, in: NSRange(location: 0, length: storage.length)
            ) { value, range, _ in
                if value != nil { runs.append(range) }
            }
            return KayaUIRanges(
                text: view.text ?? "",
                highlights: runs,
                selection: view.selectedRange,
                painted: !wantsPaint || runs.isEmpty || kayaPaintedPixels(view) > 0)
        }
    }

    /// Is this range on screen? CONTAINMENT, never the viewport itself, whose
    /// context differs per lane. TWO PREDICATES, BOTH REQUIRED: `viewportRange`
    /// is GENEROUS and the segment rectangles close that latitude. NOT FULL RECT
    /// CONTAINMENT, watched failing (a reveal left the frame at 814..836).
    private func kayaUIRevealed(_ identifier: String, _ range: NSRange) -> Bool? {
        DispatchQueue.main.sync { () -> Bool? in
            kayaSettleRender()
            guard let view = kayaUITextTarget(identifier),
                let layout = view.textLayoutManager,
                let content = layout.textContentManager
            else { return nil }
            let document = content.documentRange
            guard let start = content.location(document.location, offsetBy: range.location),
                let end = content.location(
                    document.location, offsetBy: range.location + range.length),
                let textRange = NSTextRange(location: start, end: end)
            else { return nil }
            var segments: [CGRect] = []
            layout.enumerateTextSegments(in: textRange, type: .standard, options: []) {
                _, segment, _, _ in
                segments.append(segment)
                return true
            }
            guard !segments.isEmpty else { return nil }
            guard let viewport = layout.textViewportLayoutController.viewportRange else {
                return nil
            }
            let low = content.offset(from: document.location, to: viewport.location)
            let high = content.offset(from: document.location, to: viewport.endLocation)
            let laidOut = range.location >= low && NSMaxRange(range) <= high
            // THE TWO RECTANGLES ARE IN DIFFERENT SPACES by
            // `textContainerInset`, 8pt at the top here (docs/traps.md), so
            // compared directly a range 8pt BELOW the fold reads as visible.
            // The viewport moves into the segments' space, not the reverse.
            let visible = view.bounds.offsetBy(
                dx: -view.textContainerInset.left, dy: -view.textContainerInset.top)
            return laidOut && segments.allSatisfy { visible.intersects($0) }
        }
    }

    /// `compose`: leave MARKED, UNCOMMITTED text in the control, so select_range
    /// must refuse to run over it. A MEASURED DIVERGENCE FROM macOS — UITextView
    /// DOES notify its delegate for marked text (2026-08-06) — but the guard on
    /// the push stays: a write mid-composition drops `markedTextRange` silently.
    private func kayaCompose(_ view: UITextView, _ marked: String) -> String? {
        guard view.becomeFirstResponder() else {
            return "could not take first responder"
        }
        let end = ((view.text ?? "") as NSString).length
        view.selectedRange = NSRange(location: end, length: 0)
        // The caret parks at the END of the marked text, which is every
        // platform's convention and what the scene's frozen offset counts.
        view.setMarkedText(marked, selectedRange: NSRange(location: marked.utf16.count, length: 0))
        return view.markedTextRange != nil ? nil : "the view did not take marked text"
    }
#endif

private struct KayaTableStamp {
    let node: UInt64
    let keys: [String]
}

private func kayaTableStamp(_ tag: [UInt8]) -> KayaTableStamp? {
    func u32(_ at: Int) -> UInt32? {
        guard at >= 0, at <= tag.count - 4 else { return nil }
        return (0..<4).reduce(UInt32(0)) { $0 | (UInt32(tag[at + $1]) << UInt32(8 * $1)) }
    }
    func u64(_ at: Int) -> UInt64? {
        guard at >= 0, at <= tag.count - 8 else { return nil }
        return (0..<8).reduce(UInt64(0)) { $0 | (UInt64(tag[at + $1]) << UInt64(8 * $1)) }
    }

    guard tag.count >= 16, let node = u64(0), let rawCount = u32(8) else { return nil }
    let count = Int(rawCount)
    guard count > 0, count <= (tag.count - 16) / 8 else { return nil }
    var at = 16
    var keys: [String] = []
    for _ in 0..<count {
        guard let type = u32(at), let rawLength = u32(at + 4), type == valueStr else {
            return nil
        }
        let length = Int(rawLength)
        guard length <= Int.max - 7 else { return nil }
        let payload = at + 8
        guard payload <= tag.count, length <= tag.count - payload,
            let key = String(bytes: tag[payload..<(payload + length)], encoding: .utf8)
        else { return nil }
        keys.append(key)
        let padded = (length + 7) & ~7
        guard padded <= tag.count - payload else { return nil }
        at = payload + padded
    }
    guard at == tag.count else { return nil }
    return KayaTableStamp(node: node, keys: keys)
}

/// Resolves the target grammar against the verb's creation-order registry.
private func kayaTarget(_ spec: Substring, _ kind: String, _ registry: [KayaNode]) -> KayaNode? {
    let text = String(spec)
    if let at = text.firstIndex(of: "@") {
        guard text[..<at] == kind else { return nil }
        let authored = String(text[text.index(after: at)...])
        let id: String
        let keys: [String]?
        if let open = authored.firstIndex(of: "[") {
            guard authored.last == "]" else { return nil }
            id = String(authored[..<open])
            guard !id.contains(where: { $0 == "[" || $0 == "]" || $0 == "@" }) else {
                return nil
            }
            let start = authored.index(after: open)
            let end = authored.index(before: authored.endIndex)
            let keyText = String(authored[start..<end])
            guard !keyText.isEmpty,
                !keyText.contains(where: { $0 == "[" || $0 == "]" })
            else { return nil }
            let path = keyText.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !path.contains(where: { $0.isEmpty }) else { return nil }
            keys = path
        } else {
            guard !authored.contains(where: { $0 == "]" || $0 == "@" }) else { return nil }
            id = authored
            keys = nil
        }
        guard !id.isEmpty else { return nil }
        // A DESTROYED NODE MAY NOT ANSWER A TARGET: the registries are
        // append-only and `kayaScene.nodes` is the liveness record, so a
        // stamped copy that left the band would answer with the empty children
        // its teardown left behind (docs/virtualization-plan.md §1).
        guard let keys else {
            if let hit = registry.first(where: { kayaScene.nodes[$0.id] === $0 && $0.a11yId == id }) {
                return hit
            }
            let liveIds = registry.filter { kayaScene.nodes[$0.id] === $0 }.map { $0.a11yId }
            kayaDiag(
                "target \(text) unresolved: \(liveIds.count) live \(kind)s; ids "
                    + Set(liveIds).sorted().joined(separator: ","))
            return nil
        }
        // A stamped copy of ANY tagged kind resolves by key: the table's
        // sort tag and a widget's occurrence tag carry the same node-and-
        // keys encoding (the keyed-target entry, 2026-09-01).
        let stampOf: (KayaNode) -> KayaTableStamp? = { kayaTableStamp(kind == "column" ? $0.sortTag : $0.tag) }
        let live = registry.filter { kayaScene.nodes[$0.id] === $0 }
        // EVERY copy carrying the id is a candidate, whichever template
        // stamped it: the key path names the copy, so five lists' templates
        // may share one id (tools/scenes/tasks.steps). Two answering is a
        // refusal, said as such.
        let hits = live.filter { $0.a11yId == id && stampOf($0)?.keys == keys }
        guard hits.count == 1 else {
            // The miss says what the registry held: a keyed target that
            // resolves nothing is otherwise one sentence for every cause.
            let withId = live.filter { $0.a11yId == id }
            kayaDiag(
                "keyed target \(text) \(hits.isEmpty ? "unresolved" : "ambiguous (\(hits.count) copies)"): \(live.count) live \(kind)s, \(withId.count) carrying id \(id), tags "
                    + withId.map { "\($0.tag.count)b" }.joined(separator: ",") + "; ids "
                    + Set(live.map { $0.a11yId }).sorted().joined(separator: ","))
            return nil
        }
        return hits[0]
    }
    guard text.filter({ $0 == "#" }).count == 1 else { return nil }
    let bits = text.split(separator: "#", omittingEmptySubsequences: false)
    guard bits.count == 2, bits[0] == kind else { return nil }
    if bits[1] == "last" { return registry.last }
    guard let i = Int(bits[1]), registry.indices.contains(i) else { return nil }
    return registry[i]
}

/// Retry a main-thread read until it answers or the wait runs out: the AppKit
/// and UIKit surfaces behind a pushed screen materialize a frame after the
/// model does, and a drive verb that read them once lost that race
/// (tools/scenes/tasks.steps, 2026-09-05).
func kayaAwaitOnMain<T>(timeoutMs: Int = 5000, _ read: () -> T?) -> T? {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while true {
        if let hit = DispatchQueue.main.sync(execute: read) { return hit }
        if Date() >= deadline { return nil }
        Thread.sleep(forTimeInterval: 0.02)
    }
}

/// An optional leading `window#N` token for the window verbs; the remainder is
/// the verb's own arguments. Implicit = the primary.
func kayaWindowTarget(_ parts: [Substring]) -> (UInt64, Bool, [Substring]) {
    if let first = parts.first, first.hasPrefix("window#"),
        let id = UInt64(first.dropFirst("window#".count))
    {
        return (id, true, Array(parts.dropFirst()))
    }
    return (0, false, parts)
}

#if os(macOS)
    /// Await a surface's REAL NSWindow. Materialization is async and the wait
    /// is EVENT-DRIVEN, never a poll: the runner parks on a semaphore window
    /// registration signals, and the deadline is only the failure bound (a
    /// window that never materializes must fail the leg, not hang it).
    func kayaAwaitWindow(_ id: UInt64, timeoutMs: Int = 5000) -> NSWindow? {
        let waiter = DispatchSemaphore(value: 0)
        let immediate = DispatchQueue.main.sync { () -> NSWindow? in
            if let window = kayaNSWindows[id] { return window }
            kayaWindowWaiters[id, default: []].append(waiter)
            return nil
        }
        if let immediate { return immediate }
        _ = waiter.wait(timeout: .now() + .milliseconds(timeoutMs))
        return DispatchQueue.main.sync { kayaNSWindows[id] }
    }

    func kayaTitleWindow(_ id: UInt64) -> NSWindow? {
        kayaNSWindows[id] ?? (id == 0 ? NSApp.windows.first : nil)
    }
#endif

/// The observation contract compares Unicode SCALAR SEQUENCES — byte-for-byte,
/// the predicate every other interpreter computes. Swift's `==` alone adds
/// canonical equivalence, so an expect could pass here and fail on every other
/// platform for byte-identical inputs.
private func kayaBytesEqual(_ a: String, _ b: String) -> Bool {
    a.utf8.elementsEqual(b.utf8)
}

/// Guest-visible text uses LF everywhere, normalized at every WRITE. The
/// cheap-out guard checks UNICODE SCALARS: Swift's grapheme-based
/// `String.contains("\r")` sees CRLF as one cluster that does not "contain" CR.
private func kayaLF(_ s: String) -> String {
    s.unicodeScalars.contains("\r")
        ? s.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        : s
}

private func kayaQuoted(_ rest: [Substring]) -> String {
    let joined = rest.joined(separator: " ")
    let inner = String(joined.dropFirst().dropLast())
    // The grammar's escapes (harness.rs is the norm): \\n -> newline,
    // \\r -> carriage return (the paste stand-in for the LF-contract
    // proof), \\\\ -> backslash — a textarea's newline must ride a
    // line-oriented script.
    var out = ""
    var chars = inner.makeIterator()
    while let c = chars.next() {
        if c == "\\" {
            switch chars.next() {
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "\\": out.append("\\")
            case let other?:
                out.append("\\")
                out.append(other)
            case nil: out.append("\\")
            }
        } else {
            out.append(c)
        }
    }
    return out
}

/// A LEADING quoted string plus the remainder after its closing quote
/// (harness.rs's parse_quoted_prefix, mirrored): expect_menu's path precedes
/// its state token and a menu label may contain spaces, so whitespace-splitting
/// before the quote would shear it. Honors kayaQuoted's escapes.
private func kayaQuotedPrefix(_ rest: String) -> (String, String)? {
    var s = Substring(rest)
    while s.first == " " { s = s.dropFirst() }
    guard s.first == "\"" else { return nil }
    s = s.dropFirst()
    var out = ""
    var escaped = false
    var index = s.startIndex
    while index < s.endIndex {
        let c = s[index]
        if escaped {
            switch c {
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "\\": out.append("\\")
            default:
                out.append("\\")
                out.append(c)
            }
            escaped = false
        } else if c == "\\" {
            escaped = true
        } else if c == "\"" {
            let tail = String(s[s.index(after: index)...])
                .trimmingCharacters(in: .whitespaces)
            return (out, tail)
        } else {
            out.append(c)
        }
        index = s.index(after: index)
    }
    return nil
}

/// The expect_menu state token(s) onto (aspect, normalized spelling) —
/// the grammar's own words, byte-compared like every observation.
private func kayaParseMenuState(_ spec: String) -> (KayaMenuAspect, String)? {
    let s = spec.trimmingCharacters(in: .whitespaces)
    switch s {
    case "enabled", "disabled": return (.enablement, s)
    case "checked", "unchecked": return (.checkedness, s)
    default:
        let bits = s.split(separator: " ", omittingEmptySubsequences: true)
        // value takes a 0-BASED index (harness.rs parses usize; a
        // negative index is line noise, rejected, not resolved).
        if bits.count == 2, bits[0] == "value", let index = Int(bits[1]), index >= 0 {
            return (.value, "value \(index)")
        }
        return nil
    }
}

/// A menu path is labels joined with `>`: at least one label, every segment
/// non-empty and byte-exact — harness.rs's check_menu_path, mirrored. No
/// trimming: labels compare byte-for-byte, so a padded segment is a typo that
/// would only surface as a bewildering "no such item" at runtime.
private func kayaCheckMenuPath(_ path: String) -> String? {
    if path.isEmpty { return "menu path is empty" }
    for seg in path.split(separator: ">", omittingEmptySubsequences: false) {
        if seg.isEmpty {
            return "menu path \"\(path)\" has an empty label segment"
        }
        if seg != seg.trimmingCharacters(in: .whitespaces) {
            return "menu path \"\(path)\" pads a label with whitespace"
        }
    }
    return nil
}

/// context_open's target may be any non-editable widget kind — the
/// kind picks the registry, exactly as parse_target routes.
private func kayaAnyTarget(_ spec: Substring) -> KayaNode? {
    switch String(spec.prefix { $0 != "#" && $0 != "@" }) {
    case "button": return kayaTarget(spec, "button", kayaScene.buttons)
    case "checkbox": return kayaTarget(spec, "checkbox", kayaScene.checkboxes)
    case "label": return kayaTarget(spec, "label", kayaScene.labels)
    case "slider": return kayaTarget(spec, "slider", kayaScene.sliders)
    case "date_picker": return kayaTarget(spec, "date_picker", kayaScene.datePickers)
    case "time_picker": return kayaTarget(spec, "time_picker", kayaScene.timePickers)
    case "image": return kayaTarget(spec, "image", kayaScene.images)
    case "canvas": return kayaTarget(spec, "canvas", kayaScene.canvases)
    case "column": return kayaTarget(spec, "column", kayaScene.columns)
    case "row": return kayaTarget(spec, "row", kayaScene.rows)
    case "scroll": return kayaTarget(spec, "scroll", kayaScene.scrolls)
    case "progress": return kayaTarget(spec, "progress", kayaScene.progresses)
    case "select": return kayaTarget(spec, "select", kayaScene.selects)
    case "radio": return kayaTarget(spec, "radio", kayaScene.radios)
    case "grid": return kayaTarget(spec, "grid", kayaScene.grids)
    // The editable kinds: not reachable from context_open (the root rejects
    // that attach — their native edit menu is dress), but every kind is
    // addressable for accessibility, which is the point of a universal prop.
    case "entry": return kayaTarget(spec, "entry", kayaScene.entryWidgets)
    case "textarea": return kayaTarget(spec, "textarea", kayaScene.textareas)
    case "labeled": return kayaTarget(spec, "labeled", kayaScene.labeleds)
    default: return nil
    }
}

/// Cut one script LINE into statements at `;` — the newline stand-in for
/// transports that cannot carry one. QUOTE-AWARE: kaya's own asset miss sentence
/// carries a semicolon. harness.rs's `split_statements` and KayaCompose.kt's
/// twin are held equal by tools/scenes/assets.steps and tools/check-steps.py.
private func kayaSplitStatements(_ line: String) -> [String] {
    var out: [String] = []
    var current = ""
    var quoted = false
    for c in line {
        if c == "\"" {
            quoted.toggle()
            current.append(c)
        } else if c == ";" && !quoted {
            out.append(current)
            current = ""
        } else {
            current.append(c)
        }
    }
    out.append(current)
    return out.filter { !$0.isEmpty }
}

/// THE CEILING ON ONE STEP, HOP INCLUDED — harness.rs's STEP_CEILING, the same
/// number in all three harnesses (tools/check-harness-ceiling.py). Without it a
/// saturated main thread makes the leg print NOTHING until `timeout 120` kills
/// it, log and all (docs/measurements/choke-macos-2026-08-24.txt's ASIDE).
let kayaStepCeiling: TimeInterval = 60.0
/// Once a verdict is published the process leaves within this whether
/// or not `exit()` itself can finish (harness.rs's EXIT_GRACE).
let kayaExitGrace: TimeInterval = 3.0

func kayaStepCeilingSetting() -> TimeInterval {
    if let ms = ProcessInfo.processInfo.environment["KAYA_STEP_CEILING_MS"],
        let n = Double(ms), n > 0
    {
        return n / 1000
    }
    return kayaStepCeiling
}

/// The sentence a wedged step ends its run with — harness.rs's `wedge_verdict`
/// and KayaCompose.kt's `kayaWedgeVerdict` are the same text. It prints only
/// what it measured and says out loud what it cannot tell apart.
func kayaWedgeVerdict(_ step: String, _ waited: TimeInterval) -> String {
    "KAYA_SELFTEST: FAILED (no verdict — the harness entered step \(step) "
        + String(format: "%.1f", waited)
        + "s ago and has not come back from it. A step blocks in its hop to the "
        + "platform's UI thread, so nothing answered from there; a wedged UI thread "
        + "and a merely slow one look the same from here and this does not claim to "
        + "tell them apart. Ended by the harness step ceiling, which is the cover a "
        + "step's own retry deadline cannot give: that one is read only after a step "
        + "returns.)"
}

/// The thread that makes those two ceilings real. NOT the harness thread: the
/// failure class IS that thread stuck in a call that never returns. `_exit`,
/// never `exit`: atexit handlers and stdio teardown run in a state where the
/// main thread answers nothing, and stdout is already line-buffered.
final class KayaStepWatchdog {
    private let lock = NSLock()
    private let ceiling: TimeInterval
    private var step: String?
    private var leaving: Int32?
    private var since = Date()

    init(ceiling: TimeInterval) {
        self.ceiling = ceiling
    }

    func start() {
        let thread = Thread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 0.02)
                lock.lock()
                let step = self.step
                let leaving = self.leaving
                let waited = Date().timeIntervalSince(since)
                lock.unlock()
                if let leaving, waited >= kayaExitGrace {
                    // NOT a second verdict: the leg's own is already
                    // out, and replacing it would lose the answer the
                    // run reached.
                    FileHandle.standardError.write(
                        Data(
                            ("KAYA_HARNESS: the verdict is published and the platform's exit "
                                + "path has not run \(Int(kayaExitGrace))s later — leaving "
                                + "under the verdict's own code (the harness exit grace)\n")
                                .utf8))
                    _exit(leaving)
                }
                if let step, waited >= ceiling {
                    // THE WEDGE IS WHAT THE TRACE IS FOR (crates/kaya/src/
                    // vtrace.rs); the failed-verdict path dumps its own.
                    KayaVTrace.dump("the step ceiling fired: no verdict")
                    FileHandle.standardError.write(
                        Data((kayaWedgeVerdict(step, waited) + "\n").utf8))
                    _exit(1)
                }
            }
        }
        thread.name = "kaya-step-ceiling"
        thread.start()
    }

    func enter(_ step: String) {
        lock.lock()
        self.step = step
        leaving = nil
        since = Date()
        lock.unlock()
    }

    func published(_ code: Int32) {
        lock.lock()
        step = nil
        leaving = code
        since = Date()
        lock.unlock()
    }
}

private func kayaRunScript(_ script: String) {
    // Watched, before any step: a fault now reddens this leg instead of
    // ending the process (crates/kaya/src/fault.rs; the fault census
    // holds all three runners to this call).
    KayaHost.api.fault_watch()
    var observed: [String] = []
    var failures: [String] = []
    // Recording handshake: when the runner exports KAYA_HARNESS_GATE it is
    // recording this window and holds the gate until its recorder delivers a
    // first frame. Bounded; a no-op without the variable.
    if let gate = ProcessInfo.processInfo.environment["KAYA_HARNESS_GATE"] {
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: gate), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
    // THE TRACE MUST SURVIVE A KILL: stdout to a file is block-buffered, so a
    // leg killed at its timeout takes every logged step with it and the hang
    // looks like "never started" (measured twice, 2026-07-25).
    setvbuf(stdout, nil, _IOLBF, 0)
    // THE CEILING THAT COVERS THE HOP: armed at every step below and
    // again over the exit, so this run cannot end in silence.
    let watchdog = KayaStepWatchdog(ceiling: kayaStepCeilingSetting())
    watchdog.start()
    let start = Date()
    print("KAYA_HARNESS: epoch \(Int(start.timeIntervalSince1970 * 1000))")
    // The verb trace counts from the same zero (crates/kaya/src/vtrace.rs).
    KayaVTrace.begin(start)
    // AN UNCAUGHT NSException IS THE THIRD WAY A RUN ENDS, and the one that
    // left nothing: the failed verdict and the watchdog dump the ring, a crash
    // did not (docs/traps.md, "An NSTableView `frame` read off the main thread
    // can re-tile").
    NSSetUncaughtExceptionHandler { exception in
        KayaVTrace.dump(
            "an uncaught NSException: \(exception.name.rawValue): \(exception.reason ?? "")")
    }
    // THE SCENE-READY WAIT (harness.rs is the norm; docs/deferred.md, the
    // android `varied-python` WATCH): the first step's clock starts once a
    // root is mounted. Armed like a step, bounded short of the ceiling.
    watchdog.enter("<scene-ready wait>")
    let readyDeadline = Date().addingTimeInterval(max(1, kayaStepCeilingSetting() - 5))
    while !(DispatchQueue.main.sync {
        kayaScene.windows.values.contains(where: kayaWindowHasMountedContent)
    }) {
        if Date() > readyDeadline {
            print(
                "KAYA_SELFTEST: FAILED (the scene mounted no root inside the scene-ready wait — the first step's clock never started)")
            watchdog.published(1)
            exit(1)
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    print("KAYA_HARNESS: scene ready after \(Int(Date().timeIntervalSince(start) * 1000))ms")
    var stepOrdinal = 0
    // Whether the run already carried the core's fault into `failures`,
    // so the sweep after the loop cannot report the same one twice.
    var reportedFault = false
    // Labelled for the two things that end a script early: the pasteboard
    // witness (kayaClipWitness) finding that this leg no longer owns the
    // board it staged, and the core latching a fault (kayaCoreFaultNote).
    scriptLines: for rawLine in script.split(separator: "\n", omittingEmptySubsequences: true) {
        let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)
        if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") { continue }
        for raw in kayaSplitStatements(trimmedLine) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            let offset = Int(Date().timeIntervalSince(start) * 1000)
            print("KAYA_HARNESS: +\(offset)ms \(line)")
            watchdog.enter(line)
            KayaVTrace.step(stepOrdinal, line)
            stepOrdinal += 1
            // The observation contract (harness.rs is the norm): every expect
            // is a BOUNDED RETRY appending one failure on a miss, actions never
            // re-run, and the FIRST expect is the scene-ready wait. THE DEADLINE
            // IS THE LANE'S (docs/clipboard-plan.md §8).
            #if os(macOS)
                let stepDeadline = Date().addingTimeInterval(5.0)
            #else
                let stepDeadline = Date().addingTimeInterval(15.0)
            #endif
            var retryStep = true
            var attempt = 0
            while retryStep {
                retryStep = false
                let failuresBefore = failures.count
                switch parts[0] {
            case "settle":
                Thread.sleep(forTimeInterval: Double(parts[1])! / 1000)
            case "click":
                let ok = DispatchQueue.main.sync { () -> Bool in
                    // A click on a TEXT KIND focuses it — the only way a scene
                    // can focus a STAMPED copy, which has no live handle.
                    // Routed through the model's focusedId like the wire's
                    // focus command; a makeFirstResponder would fight it.
                    if let node = kayaTarget(parts[1], "entry", kayaScene.entryWidgets)
                        ?? kayaTarget(parts[1], "textarea", kayaScene.textareas)
                    {
                        kayaScene.focusedId = node.id
                        return true
                    }
                    guard let node = kayaTarget(parts[1], "button", kayaScene.buttons) else {
                        return false
                    }
                    let now = Date().timeIntervalSince1970
                    let entries = kayaStackEntries(0).count
                    kayaLastClick = (String(parts[1]), now, entries)
                    if kayaLastPopAt > 0, now - kayaLastPopAt < 1.0 {
                        kayaDiag("click \(parts[1]) \(Int((now - kayaLastPopAt) * 1000))ms after the last pop; entries=\(entries)")
                    }
                    KayaHost.emit(node.tag)
                    return true
                }
                if !ok { failures.append("no such target \(parts[1])") }
            case "toggle":
                let ok = DispatchQueue.main.sync { () -> Bool in
                    guard let node = kayaTarget(parts[1], "checkbox", kayaScene.checkboxes) else {
                        return false
                    }
                    kayaUserWrite { node.checked = parts[2] == "on" }
                    KayaHost.emitToggled(node.tag, node.checked)
                    return true
                }
                if !ok { failures.append("no such target \(parts[1])") }
            case "set_value":
                // THROUGH the control (docs/slider-plan.md S8): its value moves
                // and the arm's own commit path runs — the step's snap, the
                // range's clamp, the live emit and the committed one — the
                // path a user's gesture takes.
                let ok = DispatchQueue.main.sync { () -> Bool in
                    guard let node = kayaTarget(parts[1], "slider", kayaScene.sliders),
                        let control = kayaSliderControls[node.id]
                    else { return false }
                    kayaDriveSlider(control, node: node, to: Double(parts[2])!)
                    return true
                }
                if !ok { failures.append("no such target \(parts[1])") }
            case "expect_slider":
                // The CONTROL's value in the fixed spelling, never the node's
                // (docs/slider-plan.md S8).
                let want = kayaQuoted(Array(parts[2...]))
                let got = DispatchQueue.main.sync { () -> String? in
                    guard let node = kayaTarget(parts[1], "slider", kayaScene.sliders),
                        let control = kayaSliderControls[node.id]
                    else { return nil }
                    return kayaSpelledSlider(kayaControlSliderValue(control))
                }
                if let got, got == want {
                    observed.append(got)
                } else if let got {
                    failures.append("\(parts[1]) holds \"\(got)\", wanted \"\(want)\"")
                } else {
                    failures.append("no such target \(parts[1])")
                }
            case "set_date", "set_time":
                // THROUGH the control (docs/datetime-plan.md D8): its value
                // moves and its own action fires, the path a user's pick
                // takes, so the range police and the minute snap run too.
                let isTime = parts[0] == "set_time"
                let spelled = String(parts[2])
                guard let packed = isTime ? kayaParseTime(spelled) : kayaParseDate(spelled) else {
                    failures.append(
                        "\(parts[0]) wants \(isTime ? "HH:MM" : "YYYY-MM-DD"), got \(spelled)")
                    break
                }
                let pickerNode = DispatchQueue.main.sync {
                    isTime
                        ? kayaTarget(parts[1], "time_picker", kayaScene.timePickers)
                        : kayaTarget(parts[1], "date_picker", kayaScene.datePickers)
                }
                guard let pickerNode else {
                    failures.append("no such target \(parts[1])")
                    break
                }
                // The control materializes after the node (kayaAwaitOnMain),
                // and the two misses are two sentences.
                guard let control = kayaAwaitOnMain({ kayaPickerControls[pickerNode.id] }) else {
                    failures.append("\(parts[1]) has no picker control after 5000ms")
                    break
                }
                DispatchQueue.main.sync {
                    kayaDrivePicker(
                        control, to: isTime ? kayaDateFromPackedTime(packed) : kayaDateFromPackedDate(packed))
                }
            case "expect_picker":
                // The CONTROL's value, never the node's: the one observation
                // for the silent cases (docs/datetime-plan.md D8).
                let want = kayaQuoted(Array(parts[2...]))
                let isTimePicker = parts[1].hasPrefix("time_picker")
                let pickerNode = DispatchQueue.main.sync {
                    isTimePicker
                        ? kayaTarget(parts[1], "time_picker", kayaScene.timePickers)
                        : kayaTarget(parts[1], "date_picker", kayaScene.datePickers)
                }
                let got: String? = pickerNode.flatMap { node in
                    guard let control = kayaAwaitOnMain({ kayaPickerControls[node.id] }) else { return nil }
                    return DispatchQueue.main.sync {
                        isTimePicker
                            ? kayaSpelledTime(kayaPackedTime(kayaControlDate(control)))
                            : kayaSpelledDate(kayaPackedDate(kayaControlDate(control)))
                    }
                }
                if let got, got == want {
                    observed.append(got)
                } else if let got {
                    failures.append("\(parts[1]) holds \"\(got)\", wanted \"\(want)\"")
                } else {
                    failures.append("no such target \(parts[1])")
                }
            case "choose":
                // The select's real change route in this interpreter is the
                // Picker's binding set — mirrored here exactly as set_value
                // mirrors the slider's: write the model the binding reads,
                // emit with the identity tag.
                let ok = DispatchQueue.main.sync { () -> Bool in
                    let node =
                        parts[1].hasPrefix("radio")
                        ? kayaTarget(parts[1], "radio", kayaScene.radios)
                        : kayaTarget(parts[1], "select", kayaScene.selects)
                    guard let node else {
                        return false
                    }
                    kayaUserWrite { node.value = Double(parts[2])! }
                    KayaHost.emitValue(node.tag, node.value)
                    return true
                }
                if !ok { failures.append("no such target \(parts[1])") }
            case "set_text":
                let ok = DispatchQueue.main.sync { () -> Bool in
                    let node =
                        parts[1].hasPrefix("textarea")
                        ? kayaTarget(parts[1], "textarea", kayaScene.textareas)
                        : kayaTarget(parts[1], "entry", kayaScene.entryWidgets)
                    guard let node else {
                        return false
                    }
                    kayaUserWrite { node.text = kayaLF(kayaQuoted(Array(parts[2...]))) }
                    KayaHost.emitText(node, node.text)
                    return true
                }
                if !ok { failures.append("no such target \(parts[1])") }
            case "type":
                // A8's verb: REAL KEYSTROKES at whatever holds focus, with no
                // target because that is the platform's answer. set_text cannot
                // stand in — by D7 a programmatic write CLEARS the native
                // history the scene exists to observe.
                let typed = kayaQuoted(Array(parts[1...]))
                #if os(macOS)
                    if !kayaTypeAtFocus(typed) {
                        failures.append(
                            "type \"\(typed)\" reached no window — nothing was typed")
                    }
                #else
                    // REAL KEY EVENTS HERE TOO: the resident XCUITest driver
                    // types through the simulator's keyboard
                    // (tools/ios/xcuidrive, `type_b64`). This side still owns
                    // contract point 3 (caret to the end) and point 4.
                    if let why = kayaTypeThroughHost(typed) {
                        failures.append("type \"\(typed)\": \(why)")
                    }
                #endif
            case "expect":
                let want = kayaQuoted(Array(parts[2...]))
                // The target kind picks the observation: an entry reads the
                // field's own displayed text, an image its decoded size
                // ("WxH"/"0x0"), everything else label text — harness.rs's
                // routing.
                let got = DispatchQueue.main.sync { () -> String? in
                    parts[1].hasPrefix("textarea")
                        ? kayaTarget(parts[1], "textarea", kayaScene.textareas)?.text
                        : parts[1].hasPrefix("entry")
                        ? kayaTarget(parts[1], "entry", kayaScene.entryWidgets)?.text
                        : parts[1].hasPrefix("image")
                            ? kayaTarget(parts[1], "image", kayaScene.images)?.imageSize
                            : parts[1].hasPrefix("progress")
                                ? kayaTarget(parts[1], "progress", kayaScene.progresses).map {
                                    $0.indeterminate
                                        ? "indeterminate"
                                        : "\(Int(($0.value * 100).rounded()))%"
                                }
                                : parts[1].hasPrefix("select") || parts[1].hasPrefix("radio")
                                    ? (parts[1].hasPrefix("radio")
                                        ? kayaTarget(parts[1], "radio", kayaScene.radios)
                                        : kayaTarget(parts[1], "select", kayaScene.selects))
                                        .map {
                                            // The selected option's LABEL —
                                            // child order is option order.
                                            let index = Int($0.value)
                                            return $0.children.indices.contains(index)
                                                ? $0.children[index].text : ""
                                        }
                                    : kayaTarget(parts[1], "label", kayaScene.labels)?.text
                }
                if let got, kayaBytesEqual(got, want) {
                    observed.append(got)
                } else if let got {
                    failures.append("\(parts[1]) reads \"\(got)\", wanted \"\(want)\"")
                } else {
                    failures.append("no such target \(parts[1])")
                }
            case "expect_stall":
                // The core's watchdog reading (kaya_stalled_ms), polled like
                // every expectation since the threshold must elapse first.
                // Reported in the verdict, so a green leg still shows how long
                // the app was gone.
                let stalledMs = KayaHost.api.stalled_ms()
                if stalledMs > 0 {
                    observed.append("stalled \(stalledMs)ms")
                } else {
                    failures.append(
                        "the app thread is keeping up — no pending occurrences have gone "
                            + "unclaimed, so the stall watchdog has nothing to report")
                }
            case "expect_no_stall":
                // THE OTHER HALF OF THE SAME CLAIM: a watchdog reporting a
                // stall about a HEALTHY app is worse than none, because the
                // line is read as evidence.
                let idleMs = KayaHost.api.stalled_ms()
                if idleMs == 0 {
                    observed.append("the app thread is keeping up")
                } else {
                    failures.append(
                        "the stall watchdog reports \(idleMs)ms of unclaimed occurrences "
                            + "about an app that is answering this scene — either the app "
                            + "thread really is gone, or the watchdog cannot see this "
                            + "guest's transport (crates/kaya/src/stall.rs)")
                }
            case "expect_focused":
                // The model's focusedId is the observation the focus command
                // lands as (the entry view's FocusState mirrors it into
                // SwiftUI). Counts as an expect for the zero-expect rule.
                let focused = DispatchQueue.main.sync { () -> Bool? in
                    let node =
                        parts[1].hasPrefix("textarea")
                        ? kayaTarget(parts[1], "textarea", kayaScene.textareas)
                        : kayaTarget(parts[1], "entry", kayaScene.entryWidgets)
                    guard let node else {
                        return nil
                    }
                    return kayaScene.focusedId == node.id
                }
                switch focused {
                case true?:
                    observed.append("\(parts[1]) focused")
                case false?:
                    failures.append("\(parts[1]) does not hold focus")
                case nil:
                    failures.append("no such target \(parts[1])")
                }
            case "expect_order":
                // The container's label children in child order, joined with
                // `|` — reads the tree the moves actually edited, which the
                // creation-ordered registries cannot see.
                let want = kayaQuoted(Array(parts[2...]))
                let got = DispatchQueue.main.sync { () -> String? in
                    // Kind picks the registry, exactly as in the Rust
                    // harness: a row target must never read a column.
                    let isRow = parts[1].hasPrefix("row")
                    return kayaTarget(
                        parts[1], isRow ? "row" : "column",
                        isRow ? kayaScene.rows : kayaScene.columns
                    )?.children
                        .filter { $0.kind == kindLabel }
                        .map { $0.text }
                        .joined(separator: "|")
                }
                if let got, kayaBytesEqual(got, want) {
                    observed.append(got)
                } else if let got {
                    failures.append("\(parts[1]) ordered \"\(got)\", wanted \"\(want)\"")
                } else {
                    failures.append("no such target \(parts[1])")
                }
            case "expect_columns":
                // The header bar as the TABLE PATH presented it — the render's
                // own record, never the model echo, so a table that never
                // rendered reads as "". Spelling: "<titles|joined> [^N|vN]",
                // no size-class prefix (docs/tables-plan.md).
                let want = kayaQuoted(Array(parts[2...]))
                let got = DispatchQueue.main.sync { () -> String? in
                    kayaTarget(parts[1], "column", kayaScene.columns)?.tablePresented
                }
                if let got, kayaBytesEqual(got, want) {
                    observed.append(got)
                } else if let got {
                    failures.append("\(parts[1]) presents \"\(got)\", wanted \"\(want)\"")
                } else {
                    failures.append("no such target \(parts[1])")
                }
            case "expect_rows":
                // Per-row cell label texts: rows in child order joined with
                // `|`, each row's label cells with `,` — expect_order's read one
                // level deeper, for the shape a creation-order registry misses.
                let want = kayaQuoted(Array(parts[2...]))
                let got = DispatchQueue.main.sync { () -> String? in
                    kayaTarget(parts[1], "column", kayaScene.columns)?.children
                        .map { row in
                            row.children
                                .filter { $0.kind == kindLabel }
                                .map { $0.text }
                                .joined(separator: ",")
                        }
                        .joined(separator: "|")
                }
                if let got, kayaBytesEqual(got, want) {
                    observed.append(got)
                } else if let got {
                    failures.append("\(parts[1]) rows \"\(got)\", wanted \"\(want)\"")
                } else {
                    failures.append("no such target \(parts[1])")
                }
            case "expect_column_edges":
                // docs/tables-plan.md decision 6; docs/traps.md,
                // "A table viewport contains rows".
                let want = Int(parts[2]) ?? -1
                let got = DispatchQueue.main.sync {
                    () -> (KayaCurrentTableGeometry, Double?, Bool)? in
                    guard let node = kayaTarget(parts[1], "column", kayaScene.columns) else {
                        return nil
                    }
                    let trackWidth = kayaCurrentTableTrackWidth(node)
                    return (
                        kayaCurrentTableGeometry(node), trackWidth,
                        kayaCurrentTableSynthesized(node)
                    )
                }
                guard let got else {
                    failures.append("no such target \(parts[1])")
                    break
                }
                switch got.0 {
                case .missingViewport:
                    failures.append("\(parts[1]) has no current table viewport geometry")
                case let .partialRow(seen, expected):
                    failures.append(
                        "\(parts[1]) has a partially recorded row: \(seen) of \(expected) "
                            + "cells current — a row renders whole or not at all")
                case let .unrealized(realized, declared):
                    failures.append(
                        "\(parts[1]) realizes \(realized) of \(declared) declared rows "
                            + "on a tier that owes them")
                case let .current(viewport, rows, columns):
                    guard !rows.isEmpty else {
                        failures.append("\(parts[1]) has no current row-cell geometry")
                        break
                    }
                    switch kayaTableColumnAlignment(columns) {
                    case let .missing(column):
                        failures.append(
                            "\(parts[1]) column \(column) has no current cell geometry")
                    case let .split(column, clusters):
                        let seen = clusters.map { String(Int($0.rounded())) }
                            .joined(separator: ",")
                        failures.append(
                            "\(parts[1]) column \(column) cell edges split at [\(seen)]")
                    case let .aligned(representatives):
                        let seen = representatives.map { String(Int($0.rounded())) }
                            .joined(separator: ",")
                        guard representatives.count == want,
                            kayaTableColumnRepresentativesIncrease(representatives)
                        else {
                            failures.append(
                                "\(parts[1]) cell edges represent [\(seen)], wanted "
                                    + "\(parts[2]) distinct increasing columns")
                            break
                        }
                        guard let assigned = got.1, assigned > 0 else {
                            failures.append(
                                "\(parts[1]) has no current assigned table track")
                            break
                        }
                        // The card's own span comes off the track first, or
                        // every carded table convicts itself.
                        let track = kayaTableContentTrack(
                            assigned, pad: kayaTableCardPad, synthesized: got.2)
                        let frames = columns.flatMap { $0 }
                        // TRACK, THEN THE LEADING EDGE, THEN THE TRAILING ONE —
                        // one precedence in all four backends (gtk.rs's
                        // `TableHorizontalIssue`): a table displaced at its
                        // start also ends wrong, so the end is the symptom.
                        if !kayaTableViewportMatchesTrack(viewport, track: track) {
                            failures.append(
                                "\(parts[1]) draws a \(Int(viewport.width.rounded()))pt viewport "
                                    + "for a \(Int(track.rounded()))pt track")
                        } else if let leading = representatives.first,
                            let inside = kayaTableLeadingUnderfill(
                                leading, viewport: viewport, synthesized: got.2)
                        {
                            failures.append(
                                "\(parts[1]) cells start at \(Int(inside.rounded()))pt inside a "
                                    + "\(Int(viewport.width.rounded()))pt viewport")
                        } else if !kayaTableFramesFitHorizontally(
                            frames, inside: viewport,
                            reach: kayaTableColumnsReach(parts[1])),
                            let bounds = kayaTableBounds(frames)
                        {
                            failures.append(
                                "\(parts[1]) cells occupy "
                                    + "\(Int(bounds.minX.rounded()))...\(Int(bounds.maxX.rounded()))pt "
                                    + "outside viewport "
                                    + "\(Int(viewport.minX.rounded()))...\(Int(viewport.maxX.rounded()))pt "
                                    + "that scrolls \(Int(kayaTableColumnsReach(parts[1]).rounded()))pt")
                        } else {
                            observed.append("\(parts[1]) column edges \(want)")
                        }
                    }
                }
            case "header_click":
                // The user's route: what the sortOrder binding's setter does
                // for a real header click — the sort tag verbatim plus the
                // column index, and NO model change, since the indicator moves
                // when the guest re-declares.
                let index = Int(parts[2]) ?? -1
                let off = DispatchQueue.main.sync { () -> String? in
                    guard let node = kayaTarget(parts[1], "column", kayaScene.columns) else {
                        return "no such target \(parts[1])"
                    }
                    guard !node.tableColumns.isEmpty else {
                        return "\(parts[1]) declares no columns"
                    }
                    guard index >= 0, index < node.tableColumns.count else {
                        return "column \(parts[2]) of \(node.tableColumns.count)"
                    }
                    KayaHost.emitSortRequested(node.sortTag, UInt32(index))
                    return nil
                }
                if let off { failures.append("header_click: \(off)") }
            case "expect_window":
                // THE REALIZED BAND AND THE DECLARED TOTAL
                // (docs/virtualization-plan.md §5), read from the tier that
                // drew: a band the core believes in but nobody stamped reads
                // as the disagreement it is.
                let want = parts[2...].joined(separator: " ")
                let got = DispatchQueue.main.sync { () -> String? in
                    guard let node = kayaTarget(parts[1], "column", kayaScene.columns) else {
                        return nil
                    }
                    #if os(macOS)
                        if let driver = kayaOnMain({ kayaTableDrivers[node.id] }) {
                            let v = driver.firstVisible()
                            return "\(v.first) \(v.total)"
                        }
                    #endif
                    // The synthesized tier's own reading (§4's spacer +
                    // band): the row its viewport shows first, MEASURED
                    // against the placement, never the band's first.
                    if let window = kayaOnMain({ kayaTableWindows[node.id] }) {
                        return "\(window.visible?.first ?? 0) \(window.total)"
                    }
                    // A For no tier of this backend windows: the whole
                    // collection is realized and its first row is
                    // visible at rest, which is what an unreported
                    // window answers too.
                    guard let geometry = KayaHost.windowGeometry(node.id),
                        geometry.total > 0
                    else {
                        return "0 \(node.children.count)"
                    }
                    return "\(geometry.first) \(geometry.total)"
                }
                if let got, got == want {
                    observed.append("\(parts[1]) window \(want)")
                } else if let got {
                    failures.append("\(parts[1]) windows \"\(got)\", wanted \"\(want)\"")
                } else {
                    failures.append("no such target \(parts[1])")
                }
            case "drag":
                // drag <source> to <destination> [before|onto] — the platform's
                // own arms driven in-process (docs/dnd-plan.md D10). A refused
                // drop is not this verb's failure: the source reads `none`.
                var words = Array(parts[1...])
                var reorder: Bool? = nil
                if words.last == "before" {
                    reorder = true
                    words.removeLast()
                } else if words.last == "onto" {
                    reorder = false
                    words.removeLast()
                }
                if words.count != 3 || words[1] != "to" {
                    failures.append("drag wants `<source> to <destination> [before|onto]`")
                    break
                }
                let ends: (KayaNode, KayaNode)? = DispatchQueue.main.sync {
                    guard let src = kayaAnyTarget(words[0]), let dst = kayaAnyTarget(words[2]) else { return nil }
                    return (src, dst)
                }
                guard let ends else {
                    let which = DispatchQueue.main.sync {
                        kayaAnyTarget(words[0]) == nil ? "source \(words[0])" : "destination \(words[2])"
                    }
                    failures.append("drag: no such \(which)")
                    break
                }
                let (src, dst) = ends
                // The destination's surface materializes a frame after its node
                // (kayaAwaitOnMain); the drive itself stays one shot.
                _ = kayaAwaitOnMain { kayaDragSurfaces[dst.id] != nil ? true : nil }
                if let off = DispatchQueue.main.sync(execute: { kayaDriveDrag(source: src, destination: dst, reorder: reorder) }) {
                    failures.append("drag: \(off)")
                }
            case "drag_file":
                // drag_file "<path>" to <destination> — a foreign file drop
                // (docs/dnd-plan.md D6); the path is quoted and $TMP/$PID
                // expanded like clipboard_seed's.
                let spec = parts.dropFirst().joined(separator: " ")
                guard spec.hasPrefix("\""),
                    let close = spec.dropFirst().firstIndex(of: "\"")
                else {
                    failures.append("drag_file wants a quoted path first")
                    break
                }
                let rawPath = String(spec[spec.index(after: spec.startIndex)..<close])
                let tail = spec[spec.index(after: close)...].split(separator: " ").map(String.init)
                guard tail.count == 2, tail[0] == "to" else {
                    failures.append("drag_file wants `\"<path>\" to <destination>`")
                    break
                }
                let path = kayaExpandPath(rawPath)
                let off = DispatchQueue.main.sync { () -> String? in
                    guard let dst = kayaAnyTarget(Substring(tail[1])) else {
                        return "no such destination \(tail[1])"
                    }
                    return kayaDriveFileDrop(path: path, destination: dst)
                }
                if let off { failures.append("drag_file: \(off)") }
            case "scroll_to_row":
                // The core maps the KEY to an index in the collection's current
                // order and the tier scrolls that row to the viewport's TOP. An
                // action, silent like click; the key is a string quoted only
                // when it needs to be (harness.rs's parse is the norm).
                let rawKey = parts[2...].joined(separator: " ")
                let key = rawKey.hasPrefix("\"") ? kayaQuoted(Array(parts[2...])) : rawKey
                // THE TIER'S WINDOW REGISTERS AT ITS FIRST PLACEMENT: a scroll
                // before that read "not a windowed tier" on a table that was one
                // 800ms later (2026-09-01, docs/traps.md), so an action on a
                // viewport that has not laid out waits, bounded.
                var registered = false
                for _ in 0..<250 {
                    registered = DispatchQueue.main.sync { () -> Bool in
                        guard let node = kayaTarget(parts[1], "column", kayaScene.columns) else {
                            return true
                        }
                        #if os(macOS)
                            if kayaOnMain({ kayaTableDrivers[node.id] }) != nil { return true }
                        #endif
                        return kayaOnMain({ kayaTableWindows[node.id] }) != nil
                    }
                    if registered { break }
                    usleep(20_000)
                }
                let off = DispatchQueue.main.sync { () -> String? in
                    guard let node = kayaTarget(parts[1], "column", kayaScene.columns) else {
                        return "no such target \(parts[1])"
                    }
                    guard let index = KayaHost.scrollToRow(node.id, key) else {
                        return "no row of \(parts[1]) carries the key \"\(key)\""
                    }
                    #if os(macOS)
                        if let driver = kayaOnMain({ kayaTableDrivers[node.id] }) {
                            driver.scroll(toRow: index)
                            return nil
                        }
                    #endif
                    if let window = kayaOnMain({ kayaTableWindows[node.id] }) {
                        window.scroll(node, toRow: index)
                        return nil
                    }
                    // Neither tier of this backend has a window here: the
                    // mac native driver and the synthesized one are the
                    // two that do, and iOS's REGULAR-width native tier is
                    // still SwiftUI's own Table (§4 names macOS's).
                    return "\(parts[1]) is not a windowed tier on this backend "
                        + "(no synthesized window registered for it within 5s)"
                }
                if let off { failures.append("scroll_to_row: \(off)") }
            case "expect_shares":
                // The container's children as whole-percentage shares of THEIR
                // SUM, not of the container, so spacing and padding stay out;
                // the rounding matches harness::shares exactly, since the verb
                // compares byte-for-byte across all backends.
                let want = kayaQuoted(Array(parts[2...]))
                let got = DispatchQueue.main.sync { () -> String? in
                    let isRow = parts[1].hasPrefix("row")
                    guard
                        let container = kayaTarget(
                            parts[1], isRow ? "row" : "column",
                            isRow ? kayaScene.rows : kayaScene.columns)
                    else { return nil }
                    let extents = container.children.map { kayaMainExtents[$0.id] ?? 0 }
                    let total = extents.reduce(0, +)
                    guard total > 0 else { return "" }
                    return extents
                        .map { String(Int((($0 / total) * 100).rounded())) }
                        .joined(separator: ",")
                }
                if let got, kayaBytesEqual(got, want) {
                    observed.append(got)
                } else if let got {
                    failures.append("\(parts[1]) splits \"\(got)\", wanted \"\(want)\"")
                } else {
                    failures.append("no such target \(parts[1])")
                }
            case "expect_sections":
                // The primary window's section count from the switcher's item
                // source — SwiftUI's tab bar has no separate item registry.
                let want = Int(parts[1]) ?? -1
                let got = DispatchQueue.main.sync {
                    kayaScene.windows[0]?.sections.count ?? 0
                }
                if got == want {
                    observed.append("\(want) sections")
                } else {
                    failures.append("\(got) sections, wanted \(want)")
                }
            case "expect_section":
                // The ACTIVE section's title from the platform's own
                // selection state.
                let want = kayaQuoted(Array(parts[1...]))
                let got = DispatchQueue.main.sync { () -> String in
                    guard let window = kayaScene.windows[0],
                        let sid = window.selectedSection
                    else { return "" }
                    return kayaScene.sectionsById[sid]?.title ?? ""
                }
                if kayaBytesEqual(got, want) {
                    observed.append("section \"\(want)\"")
                } else {
                    failures.append("section \"\(got)\", wanted \"\(want)\"")
                }
            case "expect_section_symbol":
                // THE SEMANTIC ICON on the REAL switcher row. Its own arm
                // rather than a second label on expect_section: check-verbs
                // reads each `case "expect_*"` head, and a verb sharing
                // another's head is one the sweep never looks at.
                let sectionRest = String(line.dropFirst(parts[0].count))
                guard let (sectionTitle, symbolSpec) = kayaQuotedPrefix(sectionRest),
                    let (wantSectionSymbol, sectionTail) = kayaQuotedPrefix(symbolSpec),
                    sectionTail.isEmpty
                else {
                    failures.append(
                        "expect_section_symbol wants a quoted section title and a quoted "
                            + "symbol name: \(line)")
                    break
                }
                let gotSectionSymbol = DispatchQueue.main.sync { () -> String in
                    #if os(macOS)
                        return kayaSectionSymbolReadMac(sectionTitle)
                    #else
                        return kayaSectionSymbolReadIOS(sectionTitle)
                    #endif
                }
                if kayaBytesEqual(gotSectionSymbol, wantSectionSymbol) {
                    observed.append("section \"\(sectionTitle)\" symbol \"\(wantSectionSymbol)\"")
                } else {
                    // The MEASURED answer rides the failure: it is what
                    // tells a wrong glyph from a row that drew none from
                    // a switcher that is not built yet.
                    failures.append(
                        "section \"\(sectionTitle)\" symbol \"\(gotSectionSymbol)\", "
                            + "wanted \"\(wantSectionSymbol)\"")
                }
            case "select_section":
                // The user's route: move the switcher's selection and
                // emit — exactly what the TabView selection binding's
                // setter does for a real tap (choose/toggle precedent).
                let index = Int(parts[1]) ?? -1
                let ok = DispatchQueue.main.sync { () -> Bool in
                    guard let window = kayaScene.windows[0],
                        index >= 0, index < window.sections.count
                    else { return false }
                    let sid = window.sections[index].id
                    if window.selectedSection != sid {
                        window.selectedSection = sid
                        KayaHost.emitSectionSelected(0, sid)
                    }
                    return true
                }
                if !ok { failures.append("no such section \(parts[1])") }
            case "expect_title":
                // The REAL materialized title, never the model's copy on
                // macOS — a backend that ignored the write must fail. An
                // explicit window#N target prefixes the observation.
                let (wid, explicit, rest) = kayaWindowTarget(Array(parts[1...]))
                let want = kayaQuoted(rest)
                let prefix = explicit ? "window#\(wid) " : ""
                #if os(macOS)
                    // Await the REAL window first (materialization is async;
                    // see kayaAwaitWindow) — then read its title bar only; the
                    // model fallback is for pre-registration reads.
                    if explicit { _ = kayaAwaitWindow(wid) }
                #endif
                let got = DispatchQueue.main.sync { () -> String in
                    #if os(macOS)
                        if let window = kayaTitleWindow(wid) {
                            return window.title
                        }
                        return wid == 0 ? kayaWindowCaption(0) : ""
                    #else
                        // iOS has no title bar; the surface-title read is the
                        // model that feeds UIScene.title — and while a
                        // navigation entry covers the window, the entry's
                        // title is the visible one.
                        if let top = kayaScene.windows[wid]?.entries.last {
                            return top.title
                        }
                        return kayaWindowCaption(wid)
                    #endif
                }
                if kayaBytesEqual(got, want) {
                    observed.append("\(prefix)title \"\(want)\"")
                } else {
                    // The model's own view rides the refusal (the title WATCH's
                    // instrument): stack depth, top title, and the last click's
                    // age and depth — which tells a push that never reached the
                    // model from a surface that has not caught up.
                    let model = DispatchQueue.main.sync { () -> String in
                        let entries = kayaStackEntries(wid)
                        return "entries=\(entries.count) top=\"\(entries.last?.title ?? "")\""
                    }
                    let click = kayaLastClick.map { c in
                        "last click \(c.target) \(Int((Date().timeIntervalSince1970 - c.at) * 1000))ms ago at entries=\(c.entries)"
                    } ?? "no click yet"
                    failures.append("\(prefix)title \"\(got)\", wanted \"\(want)\" (\(model); \(click))")
                }
            case "expect_window_size":
                // The surface's REAL content extent against the advisory
                // request, within 2pt. Reads the window, not the offer reader
                // (the offer sits inside the root inset).
                let (wid, explicit, rest) = kayaWindowTarget(Array(parts[1...]))
                let prefix = explicit ? "window#\(wid) " : ""
                let dims = rest[0].split(separator: "x")
                let wantW = Double(dims[0]) ?? -1
                let wantH = Double(dims[1]) ?? -1
                #if os(macOS)
                    if explicit { _ = kayaAwaitWindow(wid) }
                #endif
                let got = DispatchQueue.main.sync { () -> CGSize in
                    #if os(macOS)
                        guard let window = kayaTitleWindow(wid) else { return .zero }
                        return window.contentRect(forFrameRect: window.frame).size
                    #else
                        let scenes = UIApplication.shared.connectedScenes
                        let ws = scenes.compactMap { $0 as? UIWindowScene }.first
                        return ws?.windows.first?.bounds.size ?? .zero
                    #endif
                }
                if abs(got.width - wantW) <= 2, abs(got.height - wantH) <= 2 {
                    observed.append("\(prefix)window \(Int(wantW))x\(Int(wantH))")
                } else {
                    failures.append(
                        "\(prefix)window \(Int(got.width))x\(Int(got.height)), wanted "
                            + "\(Int(wantW))x\(Int(wantH))")
                }
            case "expect_dirty":
                // The platform's REAL unsaved-work affordance
                // (docs/dirty-plan.md D5): the dot in the close button,
                // published as AXEdited there. The model is NOT the source, or
                // the verb agrees with itself. iOS reads the applied prop (D4).
                #if os(macOS)
                    let (wid, explicit, rest) = kayaWindowTarget(Array(parts[1...]))
                    let prefix = explicit ? "window#\(wid) " : ""
                    let want = rest[0] == "true"
                    let got = kayaWindowEdited(wid)
                    if got == want {
                        observed.append("\(prefix)dirty \(want)")
                    } else if let got {
                        failures.append("\(prefix)dirty \(got), wanted \(want)")
                    } else {
                        // UNREADABLE is not FALSE. Saying so keeps the
                        // clean-window assertion from passing because
                        // the read broke.
                        failures.append("\(prefix)dirty unreadable, wanted \(want)")
                    }
                #else
                    // The same three-way answer as the macOS arm, off this
                    // platform's observable. Spelled out rather than sharing a
                    // preamble: a `let` bound in one arm and read below the
                    // `#endif` compiles on one platform only.
                    let (wid, explicit, rest) = kayaWindowTarget(Array(parts[1...]))
                    let prefix = explicit ? "window#\(wid) " : ""
                    let want = rest[0] == "true"
                    let got = kayaWindowDirtyState(wid)
                    if got == want {
                        observed.append("\(prefix)dirty \(want)")
                    } else if let got {
                        failures.append("\(prefix)dirty \(got), wanted \(want)")
                    } else {
                        failures.append("\(prefix)dirty unreadable, wanted \(want)")
                    }
                #endif
            case "close_window":
                // The REAL chrome path: performClose runs the delegate
                // (windowShouldClose), so the veto grammar fires
                // exactly as a user click would. Silent, like click.
                let (wid, explicit, _) = kayaWindowTarget(Array(parts[1...]))
                guard explicit else {
                    failures.append("close_window wants an explicit window#N")
                    break
                }
                #if os(macOS)
                    let target = kayaAwaitWindow(wid)
                    DispatchQueue.main.sync {
                        target?.performClose(nil)
                    }
                #endif
            case "expect_windows":
                let want = Int(parts[1]) ?? -1
                let got = DispatchQueue.main.sync { kayaScene.windows.count }
                if got == want {
                    observed.append("windows \(want)")
                } else {
                    failures.append("windows \(got), wanted \(want)")
                }
            case "expect_entries":
                // The window's navigation-stack depth (implicit
                // primary; window#N targets a stack elsewhere).
                let (wid, explicit, rest) = kayaWindowTarget(Array(parts[1...]))
                let prefix = explicit ? "window#\(wid) " : ""
                let want = Int(rest[0]) ?? -1
                let got = DispatchQueue.main.sync {
                    kayaStackDepth(explicit ? wid : kayaActiveSurface(wid))
                }
                if got == want {
                    observed.append("\(prefix)entries \(want)")
                } else {
                    failures.append("\(prefix)entries \(got), wanted \(want)")
                }
            case "back":
                // The user's back affordance: drive the SAME path-shortening
                // write the toolbar back button and swipe-back make, so
                // interception and the post-fact reconcile run as a user pop.
                let (wid, _, _) = kayaWindowTarget(Array(parts[1...]))
                DispatchQueue.main.sync {
                    // NO back affordance while both panes are on screen:
                    // NavigationSplitView draws no back button in a detail
                    // column beside its sidebar, so driving the pop would let
                    // the harness do what the screen does not offer.
                    guard !kayaSplitArm(wid) else { return }
                    let surface = kayaActiveSurface(wid)
                    let depth = max(0, kayaStackDepth(surface))
                    kayaUserPops(surface, to: max(0, depth - 1))
                }
            case "expect_grid_columns":
                let want = Int(parts[2])!
                let off = DispatchQueue.main.sync { () -> String? in
                    guard let grid = kayaTarget(parts[1], "grid", kayaScene.grids) else {
                        return nil
                    }
                    // Geometry, never the model's columns copy: the distinct
                    // leading-edge clusters of the cells ARE the columns, and
                    // clustering within 2pt asserts per-column alignment too.
                    var edges: [Double] = []
                    for cell in grid.children {
                        guard let x = kayaCellMinX[cell.id] else {
                            return "cell geometry not recorded"
                        }
                        edges.append(x)
                    }
                    if edges.isEmpty { return "no cells" }
                    var clusters: [Double] = []
                    for x in edges.sorted() {
                        if clusters.last.map({ x - $0 > 2 }) ?? true {
                            clusters.append(x)
                        }
                    }
                    return clusters.count == want
                        ? "" : "\(clusters.count) column edges, wanted \(want)"
                }
                switch off {
                case ""?:
                    observed.append("\(parts[1]) columns \(want)")
                case let s?:
                    failures.append("\(parts[1]) misaligned (\(s))")
                case nil:
                    failures.append("no such target \(parts[1])")
                }
            case "expect_overflow":
                // Content exceeds the viewport — both readings are
                // geometry recorded by the render's readers.
                let got = DispatchQueue.main.sync { () -> (Double, Double)? in
                    kayaDiag(
                        "scroll geom viewport=\(kayaTarget(parts[1], "scroll", kayaScene.scrolls)?.scrollViewportH ?? -1) "
                        + "content=\(kayaTarget(parts[1], "scroll", kayaScene.scrolls)?.scrollContentH ?? -1) "
                        + "available=\(kayaAvailableSize) root=\(kayaRootSize)")
                    return kayaTarget(parts[1], "scroll", kayaScene.scrolls)
                        .map { ($0.scrollContentH, $0.scrollViewportH) }
                }
                // A TABLE TARGET READS ITS COLUMNS' AXIS (docs/tables-plan.md,
                // ruled 2026-08-29): a table's rows already answer to
                // expect_window and scroll_to_row, so the target's kind
                // decides the axis and no verb needs an axis word.
                let wide = got ?? DispatchQueue.main.sync { () -> (Double, Double)? in
                    guard kayaTarget(parts[1], "column", kayaScene.columns) != nil else { return nil }
                    return kayaTableHorizontal(parts[1]).map { ($0.content, $0.viewport) }
                }
                if let (content, viewport) = wide {
                    if content > viewport + 2 {
                        observed.append("\(parts[1]) overflows")
                    } else {
                        failures.append(
                            "\(parts[1]) fits (content \(Int(content)) in viewport \(Int(viewport)))")
                    }
                } else {
                    let isTable = DispatchQueue.main.sync {
                        kayaTarget(parts[1], "column", kayaScene.columns) != nil
                    }
                    failures.append(
                        isTable
                            ? "\(parts[1]) records no columns' axis on this tier"
                            : "no such target \(parts[1])")
                }
            case "scroll_end":
                // The REAL scrolling API: the reader proxy animates to
                // the content's bottom anchor. Silent, like click.
                DispatchQueue.main.sync {
                    if let node = kayaTarget(parts[1], "scroll", kayaScene.scrolls),
                        let proxy = kayaScrollProxies[node.id]
                    {
                        proxy.scrollTo("kaya-scroll-content-\(node.id)", anchor: .bottom)
                        return
                    }
                    // The table arm, expect_overflow's rule: the columns.
                    guard let table = kayaTarget(parts[1], "column", kayaScene.columns)
                    else { return }
                    #if os(macOS)
                        if let driver = kayaOnMain({ kayaTableDrivers[table.id] }) {
                            driver.scrollToTrailingEdge()
                            return
                        }
                    #endif
                    if let window = kayaOnMain({ kayaTableColumnAxes[table.id] }) {
                        window.columnsOffset = max(
                            0,
                            window.placement.columnsContent
                                - window.placement.columnsViewport)
                    }
                }
            case "expect_at_end":
                // The content's bottom edge coincides with the
                // viewport's (within two units) — read back from the
                // viewport-space frame, never a model copy.
                let got = DispatchQueue.main.sync { () -> (Double, Double)? in
                    kayaTarget(parts[1], "scroll", kayaScene.scrolls)
                        .map { ($0.scrollContentMaxY, $0.scrollViewportH) }
                }
                let wideEnd = got ?? DispatchQueue.main.sync { () -> (Double, Double)? in
                    guard kayaTarget(parts[1], "column", kayaScene.columns) != nil else { return nil }
                    return kayaTableTrailing(parts[1])
                }
                if let (reached, edge) = wideEnd {
                    if abs(reached - edge) <= 2 {
                        observed.append("\(parts[1]) at end")
                    } else {
                        failures.append(
                            "\(parts[1]) short of end (content bottom \(Int(reached)) vs viewport \(Int(edge)))")
                    }
                } else {
                    let isTable = DispatchQueue.main.sync {
                        kayaTarget(parts[1], "column", kayaScene.columns) != nil
                    }
                    failures.append(
                        isTable
                            ? "\(parts[1]) records no columns' axis on this tier"
                            : "no such target \(parts[1])")
                }
            case "expect_file_dialog":
                // The REAL panel, read over accessibility: the directory it is
                // showing and the names its list contains. Both matter — a
                // panel aimed wrong, or filtered to nothing, presents perfectly
                // and is useless. Identifiers: tools/mac/paneldrive.swift.
                let wantDir = parts.count > 1 ? kayaExpandPath(String(parts[1])) : ""
                let wantNames = parts.count > 2 ? parts[2...].map(String.init) : []
                // A LEFTOVER $ means the expansion did not happen — the WORST
                // shape of this bug, since the picker is aimed correctly and
                // the comparison fails against a literal "$PID", which reads as
                // a broken picker.
                if wantDir.contains("$") {
                    failures.append(
                        "expect_file_dialog \(wantDir): unexpanded substitution — "
                            + "only $TMP and $PID exist")
                }
                #if os(macOS)
                    // THE WAIT FOR CONTENT IS THIS CALL'S, NOT THE STEP RETRY'S,
                    // whose budget is spent inside the blocked hop
                    // (kayaAwaitOpenPanelState carries the measurement). Only
                    // the forms that NAME FILES wait.
                    let state = kayaAwaitOpenPanelState(requireRows: !wantNames.isEmpty)
                #else
                    // OFF the main thread, deliberately: the read goes out to the
                    // host and back, and the picker is a remote view controller
                    // whose UI a blocked main thread would stall.
                    let state = kayaSimdriveState()
                #endif
                if let (where_, rows) = state {
                    if wantDir.isEmpty {
                        // Bare: the wait a scene needs before it can
                        // navigate. An action fired before the panel
                        // exists silently does nothing.
                        observed.append("file dialog live")
                    } else if !where_.hasSuffix(wantDir) {
                        failures.append(
                            "file dialog showing \"\(where_)\", wanted \"\(wantDir)\"")
                    } else if let missing = wantNames.first(where: { wanted in
                        #if os(macOS)
                            return !rows.contains(wanted)
                        #else
                            // THE PICKER PUBLISHES DISPLAY NAMES, and iOS's omit
                            // the extension, so the comparison is on the stem.
                            // The scene still proves the RIGHT file was chosen:
                            // it reads the bytes, and the decoy's differ.
                            let stems = Set(rows.map { ($0 as NSString).deletingPathExtension })
                            return !stems.contains((wanted as NSString).deletingPathExtension)
                        #endif
                    }) {
                        failures.append(
                            "file dialog list has \(rows), missing \"\(missing)\"")
                    } else {
                        observed.append("file dialog \"\(wantDir)\" \(wantNames)")
                    }
                } else {
                    #if os(macOS)
                        failures.append(
                            "no file dialog live, wanted \"\(wantDir)\" — \(kayaOpenPanelWhyNot())")
                    #else
                        failures.append("no file dialog live, wanted \"\(wantDir)\"")
                    #endif
                }
            case "clipboard_seed":
                // Silent like click: expect_clipboard, or the guest's
                // own read, is what says whether it landed.
                if parts.count > 2 {
                    kayaClipboardSeed(
                        kind: String(parts[1]),
                        argument: kayaQuoted(Array(parts[2...])))
                } else {
                    failures.append("clipboard_seed wants a kind and its content")
                }
            case "expect_clipboard":
                if parts.count > 2 {
                    let kind = String(parts[1])
                    let want = kayaQuoted(Array(parts[2...]))
                    // POLLED: the copy went out on the apply pump, so
                    // the clipboard changes a moment after the click.
                    var got = ""
                    let deadline = Date().addingTimeInterval(5)
                    repeat {
                        // The harness's own consumption, witnessed inside the
                        // poll rather than before it: five seconds of retry is
                        // the widest window in the scene for somebody else's
                        // clip to arrive.
                        kayaClipWitness("the foreign read of \(kind)")
                        if kayaClipBreachNote() != nil { break }
                        got = kayaClipboardRead(kind)
                        if got == want { break }
                        usleep(20_000)
                    } while Date() < deadline
                    if got == want {
                        observed.append("clipboard \(kind) \"\(got)\"")
                    } else {
                        failures.append(
                            "the clipboard's \(kind) reads \"\(got)\", wanted \"\(want)\"")
                    }
                } else {
                    failures.append("expect_clipboard wants a kind and the expected content")
                }
            case "file_dialog_goto":
                // Silent like click; the expect that follows is what says
                // whether the panel actually moved — EXCEPT for the two scene
                // bugs below, which are silent everywhere else and cost a
                // debugging session each.
                let dir = parts.count > 1 ? String(parts[1]) : ""
                #if os(macOS)
                    let resolved = kayaExpandPath(dir)
                    // A LEFTOVER $ means a substitution that does not exist —
                    // `$TMPDIR` instead of `$TMP`, say. Without this the
                    // literal is used as a path and the panel falls back
                    // silently.
                    if resolved.contains("$") {
                        failures.append(
                            "file_dialog_goto \(dir): unexpanded substitution in "
                                + "\(resolved) — only $TMP and $PID exist")
                    } else if !FileManager.default.fileExists(atPath: resolved) {
                        // THE ONE THAT MATTERS: NSOpenPanel silently RESTORES ITS
                        // LAST-USED LOCATION when pointed at a directory that
                        // does not exist, so the scene then asserts against
                        // someone else's.
                        failures.append(
                            "file_dialog_goto \(dir): \(resolved) does not exist — "
                                + "the picker would silently fall back to its "
                                + "last-used location and the scene would compare "
                                + "against that")
                    } else {
                        DispatchQueue.main.sync { kayaOpenPanelGoto(dir) }
                    }
                #else
                    // The SAME two guards, because the failure they catch is
                    // the platform's, not AppKit's: a picker aimed at a
                    // directory that does not exist opens somewhere else
                    // without saying so on iOS too.
                    let resolved = kayaExpandPath(dir)
                    if resolved.contains("$") {
                        failures.append(
                            "file_dialog_goto \(dir): unexpanded substitution in "
                                + "\(resolved) — only $TMP and $PID exist")
                    } else if !FileManager.default.fileExists(atPath: resolved) {
                        failures.append(
                            "file_dialog_goto \(dir): \(resolved) does not exist — "
                                + "the picker would silently open somewhere else and "
                                + "the scene would compare against that")
                    } else {
                        kayaPendingPanelDirectory = resolved
                    }
                #endif
            case "file_choose":
                // Drive the REAL controls: the panel's own handler runs because
                // its own button was pressed. EXCEPT that the row must be THERE
                // (harness.rs's rule): a name matching nothing presses Open
                // anyway and completes with a silent wrong file.
                let arg = parts.count > 1 ? String(parts[1]) : ""
                if arg != "cancel", !arg.isEmpty {
                    #if os(macOS)
                        // THE SAME WAIT, and here the only one there is:
                        // file_choose is an ACTION the step wrapper never
                        // re-runs, so a read that beat the browser refuses the
                        // row for good.
                        let rows = kayaAwaitOpenPanelState(requireRows: true)?.1
                        guard let rows else {
                            failures.append("file_choose \(arg): no file dialog is live")
                            break
                        }
                        if !rows.contains(arg) {
                            failures.append(
                                "file_choose \(arg): the dialog lists \(rows) — selecting "
                                    + "nothing and pressing Open anyway returns a file, so "
                                    + "this would pick the wrong one silently")
                            // Dismiss it anyway: refusing alone leaves the
                            // panel up, the next show trips the
                            // one-per-process guard, and the abort takes this
                            // failure list with it.
                            _ = DispatchQueue.main.sync { kayaOpenPanelDrive("cancel") }
                            break
                        }
                    #endif
                }
                #if !os(macOS)
                    // simdrive does the same refusal on the host and names
                    // what the picker DID list, so the check is not repeated
                    // here — the failure text arrives with the answer.
                    if let why = kayaSimdriveDrive(arg) {
                        failures.append("file_choose \(arg): \(why)")
                    }
                #endif
                #if os(macOS)
                    // AND THE PANEL MUST BE GONE (harness.rs's postcondition): a
                    // press before the panel is interactive is swallowed and the
                    // leg fails later on the GUEST. RE-PRESSED, bounded, which a
                    // landed press's dismissal makes safe.
                    var pressWhys: [String] = []
                    var attempts = 0
                    var panelGone = false
                    let overall = Date().addingTimeInterval(12)
                    repeat {
                        attempts += 1
                        if let why = DispatchQueue.main.sync(execute: { kayaOpenPanelDrive(arg) }) {
                            pressWhys.append(why)
                        }
                        let settle = Date().addingTimeInterval(4)
                        while Date() < settle {
                            if DispatchQueue.main.sync(execute: { kayaOpenPanelState() }) == nil {
                                panelGone = true
                                break
                            }
                            Thread.sleep(forTimeInterval: 0.05)
                        }
                    } while !panelGone && Date() < overall
                    if !panelGone,
                        let still = DispatchQueue.main.sync(execute: { kayaOpenPanelState() })
                    {
                        let delivery =
                            pressWhys.isEmpty
                            ? "AX reported success for every press"
                            : "press reports: \(pressWhys.joined(separator: "; "))"
                        failures.append(
                            "file_choose \(arg): the panel is still up after \(attempts) "
                                + "presses (listing \(still.1)) — every press was swallowed, "
                                + "which the panel cannot tell you; \(delivery)")
                    }
                #endif
            case "expect_save_dialog":
                // The REAL save panel, read over accessibility: its directory
                // AND its name field. The name half catches a backend that
                // saved under the SUGGESTED name, where every byte assertion
                // downstream passes and points at the wrong file.
                let wantSaveDir = parts.count > 1 ? kayaExpandPath(String(parts[1])) : ""
                let wantSaveName = parts.count > 2 ? String(parts[2]) : ""
                if wantSaveDir.contains("$") {
                    // The picker's guard, verbatim: an unexpanded
                    // expectation reads as a broken dialog.
                    failures.append(
                        "expect_save_dialog \(wantSaveDir): unexpanded substitution — "
                            + "only $TMP and $PID exist")
                } else if wantSaveDir.isEmpty || wantSaveName.isEmpty {
                    failures.append("expect_save_dialog wants a directory and a name")
                } else {
                    #if os(macOS)
                        let saveState = kayaAwaitSavePanelState()
                        let saveWhy = "save dialog state unavailable"
                    #else
                        // Read on the HOST, for the reason the open picker's
                        // read is: the sheet belongs to another process and
                        // publishes nothing here. Its refusal travels with it.
                        let (saveState, saveWhy) = kayaSimdriveSaveState()
                    #endif
                    if let (where_, name) = saveState {
                        if !where_.hasSuffix(wantSaveDir) {
                            failures.append(
                                "save dialog showing \"\(where_)\", wanted \"\(wantSaveDir)\"")
                        } else if name != wantSaveName {
                            failures.append(
                                "save dialog names \"\(name)\", wanted \"\(wantSaveName)\"")
                        } else {
                            observed.append("save dialog \"\(wantSaveDir)\" \"\(wantSaveName)\"")
                        }
                    } else {
                        failures.append(saveWhy)
                    }
                }
            case "file_dialog_name":
                // Silent like click — expect_save_dialog reads it back. EXCEPT
                // that the dialog must BE there: typing into a panel that has
                // not presented does nothing, and the leg then saves under the
                // suggested name with every downstream assertion green.
                let saveName = parts.count > 1 ? String(parts[1]) : ""
                if saveName.isEmpty {
                    failures.append("file_dialog_name wants a file name")
                } else {
                    #if os(macOS)
                        if kayaAwaitSavePanelState() == nil {
                            failures.append(
                                "file_dialog_name \(saveName): save dialog state unavailable")
                        } else {
                            DispatchQueue.main.sync { kayaSavePanelName(saveName) }
                        }
                    #else
                        // simdrive does the same refusal on the host — no
                        // sheet, or a field that does not read the name back —
                        // and names what it saw, so the failure text arrives
                        // with the answer.
                        if let why = kayaSimdriveSaveName(saveName) {
                            failures.append("file_dialog_name \(saveName): \(why)")
                        }
                    #endif
                }
            case "file_save":
                // Press the panel's own Save or Cancel, for real: its
                // completion runs because its own button was pressed.
                let saveArg = parts.count > 1 ? String(parts[1]) : ""
                if saveArg != "" && saveArg != "cancel" {
                    failures.append("file_save takes nothing or `cancel`, got \(saveArg)")
                } else {
                    #if os(macOS)
                        if kayaAwaitSavePanelState() == nil {
                            failures.append("file_save: save dialog state unavailable")
                        } else {
                            DispatchQueue.main.sync { kayaSavePanelDrive(save: saveArg != "cancel") }
                            // AND THE PANEL MUST BE GONE — the picker's
                            // postcondition, for its reason: a press before the
                            // panel is interactive is swallowed with no error
                            // and the leg fails later on the GUEST.
                            let savedBy = Date().addingTimeInterval(5)
                            while Date() < savedBy {
                                if DispatchQueue.main.sync(execute: { kayaSavePanelState() }) == nil {
                                    break
                                }
                                Thread.sleep(forTimeInterval: 0.05)
                            }
                            if let still = DispatchQueue.main.sync(execute: { kayaSavePanelState() })
                            {
                                failures.append(
                                    "file_save: the panel is still up (naming \"\(still.1)\") "
                                        + "— the press was swallowed, which the panel cannot "
                                        + "tell you")
                            }
                        }
                    #else
                        // The sheet's OWN Save/Cancel, pressed on the host,
                        // with "the sheet is gone" asserted there too — the
                        // same postcondition as file_choose's.
                        if let why = kayaSimdriveSaveDrive(cancel: saveArg == "cancel") {
                            failures.append("file_save \(saveArg): \(why)")
                        }
                    #endif
                }
            case "expect_alert":
                // The REAL presented dialog's title (NSAlert's messageText /
                // the UIAlertController's title), never the request's copy — a
                // backend that materialized nothing must fail here.
                let (wid, explicit, rest) = kayaWindowTarget(Array(parts[1...]))
                let want = kayaQuoted(rest)
                let prefix = explicit ? "window#\(wid) " : ""
                let got = DispatchQueue.main.sync { () -> String? in
                    guard let live = kayaLiveAlert, live.window == wid else { return nil }
                    #if os(macOS)
                        return kayaLiveNSAlert?.messageText
                    #else
                        return kayaLiveAlertController?.title ?? ""
                    #endif
                }
                if let got, kayaBytesEqual(got, want) {
                    observed.append("\(prefix)alert \"\(want)\"")
                } else if let got {
                    failures.append("\(prefix)alert \"\(got)\", wanted \"\(want)\"")
                } else {
                    failures.append("\(prefix)no alert live, wanted \"\(want)\"")
                }
            case "alert_choose":
                // Drive the REAL answer path: on macOS press the native
                // button (performClick — Esc and click share it); on iOS the
                // real dismissal plus the SAME closure the pressed action runs
                // (UIKit exposes no public press).
                let arg = parts.count > 1 ? String(parts[1]) : ""
                DispatchQueue.main.sync {
                    guard let live = kayaLiveAlert else { return }
                    #if os(macOS)
                        guard let alert = kayaLiveNSAlert else { return }
                        let buttons = alert.buttons
                        var index = -1
                        if arg == "0", live.actions >= 1 { index = 0 }
                        if arg == "1", live.actions >= 2 { index = 1 }
                        if arg == "cancel" { index = buttons.count - 1 }
                        if index >= 0, index < buttons.count {
                            buttons[index].performClick(nil)
                        }
                    #else
                        if let alert = kayaLiveAlertController,
                            let answer = kayaAlertAnswers[arg]
                        {
                            alert.dismiss(animated: false, completion: answer)
                        }
                    #endif
                }
            case "expect_alerts":
                // The REAL screen truth on macOS: an attached sheet
                // counts even if bookkeeping already cleared.
                let want = Int(parts[1]) ?? -1
                let got = DispatchQueue.main.sync { () -> Int in
                    #if os(macOS)
                        let sheets = kayaNSWindows.values.filter { $0.attachedSheet != nil }
                        return max(kayaLiveAlert == nil ? 0 : 1, sheets.count)
                    #else
                        return kayaLiveAlert == nil ? 0 : 1
                    #endif
                }
                if got == want {
                    observed.append("alerts \(want)")
                } else {
                    failures.append("alerts \(got), wanted \(want)")
                }
            case "expect_typeface":
                // THE RESOLVED FAMILY, off the real views, never the request:
                // every font API here renders SOMETHING for a family it does
                // not have (docs/styling-plan.md Slice 2b).
                #if os(macOS)
                    // The family is a QUOTED string in the grammar, and the
                    // observation is byte-compared against harness.rs, so the
                    // quotes come off here and stay off below.
                    let wantFamily = kayaQuoted(Array(parts[1...]))
                    let gotFamily = DispatchQueue.main.sync { kayaResolvedTypeface() }
                    if gotFamily == wantFamily {
                        observed.append("typeface \(wantFamily)")
                    } else {
                        failures.append("typeface \(gotFamily), wanted \(wantFamily)")
                    }
                #else
                    // THE APPLY SIDE IS LIVE ON iOS, through UIFontMetrics, but
                    // the OBSERVATION has not been proven on a device, so the
                    // iOS runner wires no typeface legs.
                    kayaDepthStub("typeface", on: "ios")
                #endif
            case "expect_app_icon":
                // TWO PLATFORMS, TWO ARTIFACTS, ONE STRING: macOS reads AppKit's
                // copy of the Dock picture, iOS the icon in the bundle it runs
                // from, both through the same quadrant sampler
                // (docs/app-identity-plan.md I8).
                let wantIcon = kayaQuoted(Array(parts[1...]))
                let gotIcon = DispatchQueue.main.sync { () -> String in
                    #if os(macOS)
                        return kayaMacAppIcon()
                    #else
                        return kayaIOSAppIcon()
                    #endif
                }
                if gotIcon == wantIcon {
                    observed.append("app icon \(wantIcon)")
                } else {
                    failures.append("app icon \(gotIcon), wanted \(wantIcon)")
                }
            case "expect_drawing_hash", "expect_drawing":
                // THE CANONICAL RASTER, asked of the CORE (docs/canvas-plan.md
                // §7.1), so every backend answers the same way. The probe
                // carries the hash AND two legible facts; the hash verb prints
                // the rest, since a hash alone tells the next reader nothing.
                let drawSpec = Substring(parts[1])
                let wantDraw = kayaQuoted(Array(parts[2...]))
                let probe = DispatchQueue.main.sync { () -> String in
                    guard let node = kayaTarget(drawSpec, "canvas", kayaScene.canvases) else {
                        return ""
                    }
                    return KayaHost.canvasProbe(node.id)
                }
                let drawParts = probe.split(separator: " ", maxSplits: 1)
                let drawHash = drawParts.count == 2 ? String(drawParts[0]) : "<no canvas \(drawSpec)>"
                let drawMeasured =
                    drawParts.count == 2 ? String(drawParts[1]) : "<no canvas \(drawSpec)>"
                if parts[0] == "expect_drawing_hash" {
                    if drawHash == wantDraw {
                        observed.append("drawing hash \(wantDraw)")
                    } else {
                        failures.append(
                            "drawing hash \(drawHash) (\(drawMeasured)), wanted \(wantDraw)")
                    }
                } else if drawMeasured == wantDraw {
                    observed.append("drawing \(wantDraw)")
                } else {
                    failures.append("drawing \(drawMeasured), wanted \(wantDraw)")
                }
            case "expect_raster":
                // WHICH SIZE THE RASTER IS (docs/canvas-plan.md §3.2.1): the
                // TRACK is what this backend measured, the VIEWBOX what the
                // guest declared. The only canvas read a size policy moves, the
                // others coming from the CANONICAL raster.
                let rasterSpec = Substring(parts[1])
                let wantRaster = kayaQuoted(Array(parts[2...]))
                let gotRaster = DispatchQueue.main.sync { () -> String in
                    guard let node = kayaTarget(rasterSpec, "canvas", kayaScene.canvases) else {
                        return "<no canvas \(rasterSpec)>"
                    }
                    #if os(macOS)
                        // A stale track and the raster made for it agree by
                        // construction, so the track is corrected from the
                        // live AX read before the core answers
                        // (kayaCanvasLiveResolve, docs/traps.md).
                        kayaCanvasLiveResolve(node)
                    #endif
                    return KayaHost.canvasRasterShape(node.id)
                }
                if gotRaster == wantRaster {
                    observed.append("raster \(wantRaster)")
                } else {
                    failures.append("raster \(gotRaster), wanted \(wantRaster)")
                }
            case "frame":
                // ADVANCE THE FRAME CLOCK (§15.4). A VERB, never wall
                // clock: the core owns the step, so a leg's frame count
                // is part of the scene and not a fact about the load on
                // the machine that ran it.
                let frames = parts.count > 1 ? (Int(parts[1]) ?? 1) : 1
                DispatchQueue.main.sync {
                    for _ in 0..<max(frames, 1) { KayaHost.harnessFrame() }
                }
                observed.append("frame \(frames)")
            case "expect_ink":
                // THE BLIT, sampled off the window's own pixels (§7.2): the one
                // canvas read that fails when the buffer never reached the
                // platform's image object. Both modes are named in the
                // expectation, so the host's appearance cannot decide it.
                let inkSpec = Substring(parts[1])
                let inkArg = kayaQuoted(Array(parts[2...]))
                let inkHalves = inkArg.components(separatedBy: " = ")
                let inkPoints = inkHalves.first ?? ""
                let wantInk = inkHalves.count == 2 ? inkHalves[1] : ""
                let gotInk = DispatchQueue.main.sync { () -> String in
                    guard let node = kayaTarget(inkSpec, "canvas", kayaScene.canvases) else {
                        return "<no canvas \(inkSpec)>"
                    }
                    return kayaCanvasInk(node, inkPoints)
                }
                // THE OBSERVATION IS THE WANTED TEXT, not what was read:
                // inside the tolerance the platforms legitimately answer
                // different bytes, and the verdict is byte-compared
                // across all of them.
                if kayaInkMatches(gotInk, wantInk) {
                    observed.append("ink \(wantInk)")
                } else {
                    failures.append("ink \(gotInk) at \(inkPoints), wanted \(wantInk)")
                }
            case "expect_inset":
                // The content inset, MEASURED as the halved gap between the
                // padding container's outer extent and the offer inside it —
                // RELATIVE, since absolute offers cannot be byte-frozen across
                // platforms (docs/styling-plan.md D3).
                if parts.count >= 3 {
                    let wantInset = String(parts[2])
                    let spec = parts[1]
                    let gotInset = DispatchQueue.main.sync { () -> String in
                        guard let node = kayaAnyTarget(spec) else {
                            return "no such target \(spec)"
                        }
                        guard let outer = kayaInsetOuter[node.id],
                            let inner = kayaInsetInner[node.id],
                            outer.width > 0, inner.width > 0
                        else {
                            return "no layout recorded for \(spec)"
                        }
                        let x = ((outer.width - inner.width) / 2).rounded()
                        let y = ((outer.height - inner.height) / 2).rounded()
                        return x == y ? "\(Int(x))" : "\(Int(x))x\(Int(y)) (axes disagree)"
                    }
                    if gotInset == wantInset {
                        observed.append("inset \(spec) \(wantInset)")
                    } else {
                        failures.append(
                            "inset \(spec) \(gotInset), wanted \(wantInset)")
                    }
                } else {
                    let wantInset = String(parts[1])
                    let gotInset = DispatchQueue.main.sync { () -> String in
                        let outer = kayaOuterSize
                        let inner = kayaAvailableSize
                        guard outer.width > 0, inner.width > 0 else {
                            return "no layout recorded"
                        }
                        let x = ((outer.width - inner.width) / 2).rounded()
                        let y = ((outer.height - inner.height) / 2).rounded()
                        return x == y ? "\(Int(x))" : "\(Int(x))x\(Int(y)) (axes disagree)"
                    }
                    if gotInset == wantInset {
                        observed.append("inset \(wantInset)")
                    } else {
                        failures.append("inset \(gotInset), wanted \(wantInset)")
                    }
                }
            case "expect_root_fills":
                // The mounted root fills the area the window offered it — the
                // observation shares can never make: a share is a percentage
                // of the children's sum, total-invariant by construction, so a
                // hugging root still splits 25/75.
                let hug = DispatchQueue.main.sync { () -> String in
                    let root = kayaRootSize
                    let area = kayaAvailableSize
                    guard area.width > 0, area.height > 0 else {
                        return "no root layout recorded"
                    }
                    // Within one point: rounding is not a hug.
                    if abs(root.width - area.width) <= 1, abs(root.height - area.height) <= 1 {
                        return ""
                    }
                    return "\(Int(root.width))x\(Int(root.height))pt "
                        + "inside \(Int(area.width))x\(Int(area.height))pt"
                }
                if hug.isEmpty {
                    observed.append("root fills")
                } else {
                    failures.append("root hugs (\(hug))")
                }
            case "expect_axis":
                // The axis the render actually used, recorded by
                // KayaBoxReader at layout time — never the model's field
                // (the expect_aligned rule, one prop over; harness.rs
                // Step::ExpectAxis is the sentence's source of truth).
                let want = kayaQuoted(Array(parts[2...]))
                let got = DispatchQueue.main.sync { () -> String? in
                    let isRow = parts[1].hasPrefix("row")
                    guard
                        let container = kayaTarget(
                            parts[1], isRow ? "row" : "column",
                            isRow ? kayaScene.rows : kayaScene.columns)
                    else { return nil }
                    guard let vertical = kayaContainerAxis[container.id] else {
                        return "no container layout recorded"
                    }
                    return vertical ? "vertical" : "horizontal"
                }
                switch got {
                case nil:
                    failures.append("no such target \(parts[1])")
                case want?:
                    observed.append("\(parts[1]) axis \(want)")
                case let other?:
                    failures.append("\(parts[1]) axis \"\(other)\", wanted \"\(want)\"")
                }
            case "expect_folded":
                // The stacked fold (D7), read off the state the render consumes:
                // laidOut and foldedChildren ARE the ViewBuilder's inputs, so
                // this is the render's own record, checked on BOTH ends.
                let tableSpec = String(parts[2])
                let got = DispatchQueue.main.sync { () -> String? in
                    guard let child = kayaTarget(parts[1], "column", kayaScene.columns)
                    else { return nil }
                    if tableSpec == "none" {
                        return child.foldedInto == 0 ? "not folded" : "folded"
                    }
                    guard
                        let table = kayaTarget(parts[2], "column", kayaScene.columns)
                    else { return "<no such table target>" }
                    let held = table.foldedChildren.contains { $0.id == child.id }
                    if child.foldedInto == table.id && held { return "folded" }
                    if child.foldedInto == 0 { return "not folded" }
                    return "stamped folded, but rendered outside that table's viewport"
                }
                switch got {
                case nil:
                    failures.append("no such target \(parts[1])")
                case "folded" where tableSpec != "none":
                    observed.append("\(parts[1]) folded into \(tableSpec)")
                case "not folded" where tableSpec == "none":
                    observed.append("\(parts[1]) not folded")
                case let other?:
                    if tableSpec == "none" {
                        failures.append(
                            "\(parts[1]) fold reads \"\(other)\", wanted it not folded")
                    } else {
                        failures.append(
                            "\(parts[1]) fold reads \"\(other)\", "
                                + "wanted it folded into \(tableSpec)")
                    }
                }
            case "expect_aligned":
                // Classified from recorded geometry (cross rects in the
                // container's named space; baseline = child top + its
                // font-metric offset), never from the model's align field — a
                // backend that ignored the write must fail.
                let want = kayaQuoted(Array(parts[2...]))
                let got = DispatchQueue.main.sync { () -> String? in
                    let isRow = parts[1].hasPrefix("row")
                    guard
                        let container = kayaTarget(
                            parts[1], isRow ? "row" : "column",
                            isRow ? kayaScene.rows : kayaScene.columns)
                    else { return nil }
                    guard let inner = kayaContainerCross[container.id], inner > 0 else {
                        return "no container layout recorded"
                    }
                    var rects: [(Double, Double)] = []
                    var baselines: [Double] = []
                    for child in container.children {
                        guard let r = kayaCrossRects[child.id] else { continue }
                        rects.append(r)
                        if isRow, let b = kayaBaselineOffsets[child.id] {
                            baselines.append(r.0 + b)
                        }
                    }
                    if rects.isEmpty { return "no children" }
                    // STRETCH FIRST, and alone: spanning geometry is DEGENERATE,
                    // since a child at (0, inner) satisfies start/center/end
                    // too and the multi-match rule answered "ambiguous(4)" for
                    // every true stretch.
                    if rects.allSatisfy({ abs($0.0) <= 2 && abs($0.1 - inner) <= 2 }) {
                        return "stretch"
                    }
                    // Multi-match is ambiguity, and ambiguity fails
                    // loudly — a first-match answer lets an
                    // unseparated scene pass while proving nothing.
                    var matches: [String] = []
                    if rects.allSatisfy({ abs($0.0) <= 2 }) { matches.append("start") }
                    if rects.allSatisfy({ abs((2 * $0.0 + $0.1) - inner) <= 4 }) {
                        matches.append("center")
                    }
                    if rects.allSatisfy({ abs(($0.0 + $0.1) - inner) <= 2 }) { matches.append("end") }
                    if isRow, baselines.count >= 2,
                        baselines.allSatisfy({ abs($0 - baselines[0]) <= 2 })
                    {
                        matches.append("baseline")
                    }
                    if matches.count == 1 { return matches[0] }
                    if matches.isEmpty {
                        // A row that LOOKS baseline-aligned but reads mixed is
                        // usually the recording, not the geometry: the
                        // alignmentGuide hooks only run when a guide is
                        // queried (docs/traps.md), so name the recorded count.
                        let recorded = isRow ? "; \(baselines.count) baselines recorded" : ""
                        return "mixed (cross rects \(rects) in \(inner)pt\(recorded))"
                    }
                    return "ambiguous (\(matches.joined(separator: "|")))"
                }
                switch got {
                case nil:
                    failures.append("no such target \(parts[1])")
                case want?:
                    observed.append("\(parts[1]) aligns \(want)")
                case let other?:
                    failures.append("\(parts[1]) aligns \"\(other)\", wanted \"\(want)\"")
                }
            case "expect_breadth":
                // The cross-axis twin of expect_fills' widget half (harness.rs
                // Step::ExpectBreadth): the target's cross rect against its
                // container's breadth, both from expect_aligned's readers; a
                // nested container is a target too.
                let short = DispatchQueue.main.sync { kayaBreadthShortfall(parts[1]) }
                guard let short else {
                    failures.append("no such target: \(parts[1])")
                    break
                }
                if short.isEmpty {
                    observed.append("\(parts[1]) spans its breadth")
                } else {
                    failures.append("\(parts[1]) is short of its breadth (\(short))")
                }
            case "expect_lines":
                // The wrap observation (harness.rs Step::ExpectLines): a run
                // of the row's children whose cross boxes overlap is one line.
                let want = Int(parts[2]) ?? -1
                let off = DispatchQueue.main.sync { () -> String? in
                    guard let row = kayaTarget(parts[1], "row", kayaScene.rows) else { return nil }
                    let boxes = row.laidOut.compactMap { kayaCrossRects[$0.id] }
                        .map { ($0.0, $0.0 + $0.1) }
                        .sorted { $0.0 < $1.0 }
                    if boxes.isEmpty { return "no cells" }
                    var clusters = 0
                    var reach = -Double.infinity
                    for (start, end) in boxes {
                        if clusters == 0 || start >= reach - 0.5 { clusters += 1 }
                        reach = max(reach, end)
                    }
                    return clusters == want ? "" : "\(clusters) line edges, wanted \(want)"
                }
                guard let off else {
                    failures.append("no such target: \(parts[1])")
                    break
                }
                if off.isEmpty {
                    observed.append("\(parts[1]) lines \(want)")
                } else {
                    failures.append("\(parts[1]) lines off (\(off))")
                }
            case "expect_hugs":
                // The same read, wanted SHORT (harness.rs Step::ExpectHugs,
                // the `fill = false` opt-out): a reader that could not read is
                // a failure on this side too.
                let short = DispatchQueue.main.sync { kayaBreadthShortfall(parts[1]) }
                guard let short else {
                    failures.append("no such target: \(parts[1])")
                    break
                }
                if short.isEmpty {
                    failures.append("\(parts[1]) spans its breadth, wanted it to hug")
                } else if short.hasPrefix("no ") {
                    failures.append("\(parts[1]) cannot be read (\(short))")
                } else {
                    observed.append("\(parts[1]) hugs")
                }
            case "expect_fills":
                // ONE VERB, TWO SUBJECTS (harness.rs Step::ExpectFills): a
                // CONTAINER's children span its content box, a WIDGET its
                // assigned track. One-sided: an OVERFLOW is not a leftover.
                let isContainer = parts[1].hasPrefix("row") || parts[1].hasPrefix("column")
                let slack = DispatchQueue.main.sync { () -> String? in
                    guard isContainer else {
                        guard let widget = kayaAnyTarget(parts[1]) else { return nil }
                        guard let track = kayaMainExtents[widget.id], track > 0 else {
                            return "no track recorded — not a flex child"
                        }
                        let drawn = kayaDrawnExtents[widget.id] ?? 0
                        if drawn >= track - 2 { return "" }
                        return "draws \(Int(drawn.rounded()))pt of a \(Int(track.rounded()))pt track"
                    }
                    let isRow = parts[1].hasPrefix("row")
                    guard
                        let container = kayaTarget(
                            parts[1], isRow ? "row" : "column",
                            isRow ? kayaScene.rows : kayaScene.columns)
                    else { return nil }
                    // A grown container is a flex CHILD too: its box must span
                    // the track its weight earned — measured drawing 148pt of a
                    // 346pt track with every model observable green. Skipped
                    // when no track was recorded.
                    if let track = kayaMainExtents[container.id], track > 0 {
                        let drawn = kayaDrawnExtents[container.id] ?? 0
                        if drawn < track - 2 {
                            return
                                "draws \(Int(drawn.rounded()))pt of its own \(Int(track.rounded()))pt track"
                        }
                    }
                    // THE BREADTH CLAUSE (2026-08-22): a CROSSING container spans
                    // its parent's inner breadth under every align mode, off the
                    // cross-rect the classifier already records. Skipped when
                    // the parent is not a recorded container.
                    if let parent = (isRow ? kayaScene.columns : kayaScene.rows)
                        .first(where: { p in p.children.contains(where: { $0.id == container.id }) }),
                        let parentInner = kayaContainerCross[parent.id], parentInner > 0,
                        let r = kayaCrossRects[container.id],
                        r.1 < parentInner - 2
                    {
                        return
                            "spans \(Int(r.1.rounded()))pt of its parent's \(Int(parentInner.rounded()))pt breadth"
                    }
                    // A table viewport permits slack, not row overflow.
                    if !container.tableColumns.isEmpty {
                        switch kayaCurrentTableGeometry(container) {
                        case .missingViewport:
                            return "no current table viewport geometry"
                        case let .partialRow(got, want):
                            return
                                "has a partially recorded row: \(got) of \(want) cells "
                                + "current — a row renders whole or not at all"
                        case let .unrealized(realized, declared):
                            return
                                "realizes \(realized) of \(declared) declared rows on a "
                                + "tier that owes them"
                        case let .current(viewport, rows, _):
                            guard !rows.isEmpty else { return "" }
                            // THE GROW SPLIT (the empty-row ruling,
                            // docs/tables-plan.md): a GROWN table is the scroll
                            // viewport, whose rows legitimately extend past the
                            // clip; an UNGROWN one hugs its content.
                            if container.grow > 0 { return "" }
                            guard kayaTableFramesFitVertically(rows, inside: viewport) else {
                                guard let bounds = kayaTableBounds(rows) else {
                                    return "has no current row-cell geometry"
                                }
                                return
                                    "rows occupy \(Int(bounds.minY.rounded()))...\(Int(bounds.maxY.rounded()))pt "
                                    + "outside viewport \(Int(viewport.minY.rounded()))..."
                                    + "\(Int(viewport.maxY.rounded()))pt"
                            }
                            if let bounds = kayaTableBounds(rows) {
                                let slack = viewport.maxY - bounds.maxY
                                if slack > 30 {
                                    return
                                        "an ungrown table leaves \(Int(slack.rounded()))pt "
                                        + "below its last row — the hug rule is not holding"
                                }
                            }
                            return ""
                        }
                    }
                    guard let extent = kayaContainerExtents[container.id], extent > 0 else {
                        return "no container layout recorded"
                    }
                    let tracks = container.children.map { kayaMainExtents[$0.id] }
                    // Summing unrecorded tracks as zeros reported "children
                    // span 8pt of 56pt" about a VStack that recorded nothing
                    // (watched 2026-08-22) — a sentence may only claim what
                    // was measured.
                    if tracks.contains(where: { $0 == nil }), !container.children.isEmpty {
                        return "no child tracks recorded — not a flex container"
                    }
                    let span =
                        tracks.compactMap { $0 }.reduce(0, +)
                        + container.spacing * Double(max(0, tracks.count - 1))
                    if abs(span - extent) <= 2 { return "" }
                    return "children span \(Int(span.rounded()))pt of \(Int(extent.rounded()))pt"
                }
                switch slack {
                case ""?:
                    observed.append("\(parts[1]) fills")
                case let s?:
                    failures.append(
                        isContainer
                            ? "\(parts[1]) leaves leftover (\(s))"
                            : "\(parts[1]) is short of its track (\(s))")
                case nil:
                    failures.append("no such target \(parts[1])")
                }
            case "expect_menus":
                // The top-level catalog count from the REAL materialized bar
                // on macOS (the owned NSMenu segment actually sitting in
                // NSApp.mainMenu), the overflow's group list on iOS.
                let want = Int(parts[1]) ?? -1
                let got = DispatchQueue.main.sync { () -> Int in
                    #if os(macOS)
                        kayaEnsureMenuSegment()
                        guard let mainMenu = NSApp.mainMenu else { return 0 }
                        return kayaOwnedMenuItems.filter { $0.menu === mainMenu }.count
                    #else
                        return kayaScene.windows[0]?.menubar.count ?? 0
                    #endif
                }
                if got == want {
                    observed.append("\(want) menus")
                } else {
                    failures.append("\(got) menus, wanted \(want)")
                }
            case "expect_highlights", "expect_selection":
                // THE PLATFORM'S TEXT LAYER, through the accessibility tree —
                // the same data an assistive client receives. Reading the
                // interpreter's own declared-range map would make the verb
                // agree with itself and would pass with the lowering deleted.
                let wantRanges = kayaQuoted(Array(parts[2...]))
                let rangeIdentifier = DispatchQueue.main.sync { () -> String? in
                    guard let node = kayaAnyTarget(parts[1]) else { return nil }
                    return node.a11yId
                }
                var gotRanges: String
                switch rangeIdentifier {
                case .none: gotRanges = "<no such target>"
                case .some(let ident) where ident.isEmpty:
                    gotRanges = "<no a11y_id authored on this widget>"
                case .some(let ident):
                    #if os(macOS)
                        if let read = kayaAxRangesRead(ident) {
                            gotRanges =
                                parts[0] == "expect_highlights"
                                ? kayaRangeSpelling(read.text, read.highlights)
                                : kayaRangeSpelling(
                                    read.text, read.selection.map { [$0] } ?? [])
                        } else {
                            gotRanges = "<not in the accessibility tree>"
                        }
                    #else
                        if let read = kayaUIRangesRead(
                            ident, wantsPaint: parts[0] == "expect_highlights")
                        {
                            if parts[0] == "expect_highlights" {
                                // A DECLARED SET THAT REACHES NO PIXEL IS NOT
                                // A HIGHLIGHT, and this is the one failure the
                                // offsets cannot report: they come out of the
                                // same text layer the lowering wrote to.
                                gotRanges =
                                    read.painted
                                    ? kayaRangeSpelling(read.text, read.highlights)
                                    : "<declared but nothing painted>"
                            } else {
                                gotRanges = kayaRangeSpelling(read.text, [read.selection])
                            }
                        } else {
                            gotRanges = "<not in the accessibility tree>"
                        }
                    #endif
                }
                if gotRanges == wantRanges {
                    observed.append("\(parts[0]) \(wantRanges)")
                } else {
                    failures.append("\(parts[0]) \(gotRanges), wanted \(wantRanges)")
                }
            case "expect_revealed":
                // CONTAINMENT, never the viewport itself, whose context differs
                // per lane. The `offscreen` spelling keeps this from being
                // vacuous: a scene asserts it BEFORE the reveal, so a document
                // short enough to be entirely visible fails.
                let wantState = parts[3]
                let bounds = parts[2].split(separator: ":")
                let wantStart = Int(bounds.first ?? "") ?? -1
                let wantEnd = Int(bounds.count > 1 ? bounds[1] : "") ?? -1
                let revealIdentifier = DispatchQueue.main.sync { () -> String? in
                    guard let node = kayaAnyTarget(parts[1]) else { return nil }
                    return node.a11yId
                }
                var gotState: String
                switch revealIdentifier {
                case .none: gotState = "<no such target>"
                case .some(let ident) where ident.isEmpty:
                    gotState = "<no a11y_id authored on this widget>"
                case .some(let ident):
                    #if os(macOS)
                        if let read = kayaAxRangesRead(ident), let visible = read.visible {
                            let start = kayaUtf16Offset(read.text, wantStart)
                            let end = kayaUtf16Offset(read.text, wantEnd)
                            gotState =
                                (start >= 0 && end >= 0 && start >= visible.location
                                    && end <= NSMaxRange(visible))
                                ? "visible" : "offscreen"
                        } else {
                            gotState = "<no visible character range>"
                        }
                    #else
                        // The verb's offsets are the PROTOCOL's unit, UTF-8 bytes,
                        // converted here against the text the control holds. The
                        // lowering path does no such arithmetic: it receives
                        // UTF-16 from the core.
                        if let read = kayaUIRangesRead(ident, wantsPaint: false) {
                            let start = kayaUtf16Offset(read.text, wantStart)
                            let end = kayaUtf16Offset(read.text, wantEnd)
                            if start < 0 || end < 0 {
                                gotState = "<offset off a character boundary>"
                            } else {
                                switch kayaUIRevealed(
                                    ident, NSRange(location: start, length: end - start))
                                {
                                case true?: gotState = "visible"
                                case false?: gotState = "offscreen"
                                case nil: gotState = "<no laid-out geometry for that range>"
                                }
                            }
                        } else {
                            gotState = "<not in the accessibility tree>"
                        }
                    #endif
                }
                if gotState == wantState {
                    observed.append("\(parts[2]) \(wantState)")
                } else {
                    failures.append("\(parts[2]) is \(gotState), wanted \(wantState)")
                }
            case "compose":
                // The state a user is in mid-word with an IME, which no other
                // verb reaches (`type` is printable ASCII by contract). Through
                // the view's own `setMarkedText`, so the text is DISPLAYED,
                // UNCOMMITTED and invisible to the app.
                let marked = kayaQuoted(Array(parts[2...]))
                #if os(macOS)
                    let composed = DispatchQueue.main.sync { () -> String? in
                        guard let node = kayaAnyTarget(parts[1]) else {
                            return "no such target \(parts[1])"
                        }
                        guard let view = kayaMacTextViews[node.id]?.view else {
                            return "no text view for \(parts[1])"
                        }
                        guard view.window?.makeFirstResponder(view) == true else {
                            return "\(parts[1]) could not take first responder"
                        }
                        let end = (view.string as NSString).length
                        view.setSelectedRange(NSRange(location: end, length: 0))
                        view.setMarkedText(
                            marked,
                            selectedRange: NSRange(location: marked.utf16.count, length: 0),
                            replacementRange: NSRange(location: end, length: 0))
                        return view.hasMarkedText()
                            ? nil : "the view did not take marked text"
                    }
                    if let trouble = composed {
                        failures.append("compose: \(trouble)")
                    }
                #else
                    let composedOnPhone = DispatchQueue.main.sync { () -> String? in
                        guard let node = kayaAnyTarget(parts[1]) else {
                            return "no such target \(parts[1])"
                        }
                        guard !node.a11yId.isEmpty else {
                            return "\(parts[1]) has no a11y_id, which is how the verbs "
                                + "on this platform find a control"
                        }
                        guard let view = kayaUITextTarget(node.a11yId) else {
                            return "no text view for \(parts[1])"
                        }
                        return kayaCompose(view, marked).map { "\(parts[1]) \($0)" }
                    }
                    if let trouble = composedOnPhone {
                        failures.append("compose: \(trouble)")
                    }
                #endif
            case "expect_help":
                // Help as the platform offers it to its assistive reader —
                // AXHelp on the Mac, the accessibility hint on iOS, both where
                // `.help` lands (docs/tooltip-plan.md T5) — never the model.
                let wantHelp = kayaQuoted(Array(parts[2...]))
                let helpIdentifier = DispatchQueue.main.sync { () -> String? in
                    guard let node = kayaAnyTarget(parts[1]) else { return nil }
                    return node.a11yId
                }
                let gotHelp: String
                switch helpIdentifier {
                case .none: gotHelp = "<no such target>"
                case .some(let ident) where ident.isEmpty:
                    gotHelp = "<no a11y_id authored on this widget>"
                case .some(let ident):
                    gotHelp = kayaAxHintRead(ident) ?? "<not in the accessibility tree>"
                }
                if gotHelp == wantHelp {
                    observed.append("help \"\(wantHelp)\"")
                } else {
                    failures.append("help \"\(gotHelp)\", wanted \"\(wantHelp)\"")
                }
            case "expect_ax_hint":
                // The hint's own verb (harness.rs is the norm): what
                // activating this control does, read from the platform,
                // never from the model.
                let wantHint = kayaQuoted(Array(parts[2...]))
                let hintIdentifier = DispatchQueue.main.sync { () -> String? in
                    guard let node = kayaAnyTarget(parts[1]) else { return nil }
                    return node.a11yId
                }
                let gotHint: String
                switch hintIdentifier {
                case .none: gotHint = "<no such target>"
                case .some(let ident) where ident.isEmpty:
                    gotHint = "<no a11y_id authored on this widget>"
                case .some(let ident):
                    gotHint = kayaAxHintRead(ident) ?? "<not in the accessibility tree>"
                }
                if gotHint == wantHint {
                    observed.append("ax hint \"\(wantHint)\"")
                } else {
                    failures.append("ax hint \"\(gotHint)\", wanted \"\(wantHint)\"")
                }
            case "expect_ax":
                // target -> node -> its authored identifier -> the REAL
                // accessibility tree. Routed through the identifier, so an
                // element the platform never published is simply not found —
                // which is the point of the verb.
                let wantAx = kayaQuoted(Array(parts[2...]))
                // The identifier resolves on the main thread, but the AX READ
                // ITSELF runs on the harness thread ON PURPOSE: requests are
                // serviced BY the main runloop, so querying from inside
                // main.sync leaves SwiftUI's elements coming back empty.
                let identifier = DispatchQueue.main.sync { () -> String? in
                    guard let node = kayaAnyTarget(parts[1]) else { return nil }
                    return node.a11yId
                }
                let gotAx: String
                switch identifier {
                case .none: gotAx = "<no such target>"
                case .some(let ident) where ident.isEmpty:
                    gotAx = "<no a11y_id authored on this widget>"
                case .some(let ident):
                    gotAx = kayaAxRead(ident) ?? "<not in the accessibility tree>"
                }
                if gotAx == wantAx {
                    observed.append("ax \"\(wantAx)\"")
                } else {
                    // The platform's own classification rides the failure:
                    // `unknown/…` is never self-explaining, and the answer is
                    // one platform round-trip away otherwise.
                    let why = identifier.flatMap { $0.isEmpty ? nil : kayaAxWhy($0) } ?? ""
                    failures.append("ax \"\(gotAx)\", wanted \"\(wantAx)\"\(why)")
                }
            case "resize_window":
                // The REAL resize, so the size class actually moves and the
                // adaptive arms re-run. A model write would prove nothing: the
                // whole point of the verb is to make the platform re-decide.
                let spec = parts.count > 1 ? String(parts[1]) : ""
                let dims = spec.split(separator: "x", maxSplits: 1)
                guard dims.count == 2, let rw = Double(dims[0]), let rh = Double(dims[1]) else {
                    failures.append("resize_window wants WxH: \(line)")
                    break
                }
                #if os(macOS)
                    DispatchQueue.main.sync {
                        if let window = kayaNSWindows[0] {
                            kayaSetWindowContentSize(
                                window, NSSize(width: rw, height: rh))
                        }
                    }
                #else
                    // Phone and tablet hosts do not command window size — the
                    // system owns it (DESIGN.md, Windows). Loud, not a silent
                    // no-op.
                    failures.append(
                        "resize_window: this host does not command window size")
                #endif
            case "expect_sections_presentation":
                // THE ARM THE SECTIONS RENDER TOOK — "bar" or "sidebar", read
                // off the stamp the render body wrote (never derived from the
                // declared prop, which would agree with the lowering by
                // construction). window#N addresses an aux window.
                let (spWid, spExplicit, spRest) = kayaWindowTarget(Array(parts[1...]))
                let wantArm = kayaQuoted(spRest)
                let armPrefix = spExplicit ? "window#\(spWid) " : ""
                let gotArm = DispatchQueue.main.sync { () -> String in
                    guard let window = kayaScene.windows[spWid] else {
                        return "no such window"
                    }
                    guard !window.sectionsRendered.isEmpty else {
                        return "nothing stamped — no sections body rendered"
                    }
                    return window.sectionsRendered
                }
                if gotArm == wantArm {
                    observed.append("sections \(armPrefix)\(wantArm)")
                } else {
                    failures.append(
                        "sections \(armPrefix)presentation \(gotArm), wanted \(wantArm)")
                }
            case "expect_split":
                // `<size class>/<presentation>`. BOTH halves off the window
                // model, where the view layer stamped the platform's
                // size-class reading and THE ARM THAT RENDERED — never derived
                // from the prop or from each other.
                let wantSplit = parts.count > 1 ? kayaQuoted(Array(parts[1...])) : ""
                let gotSplit = DispatchQueue.main.sync { () -> String in
                    guard let window = kayaScene.windows[0] else { return "unknown/stacked" }
                    return window.formFactor.rawValue + "/" + window.splitPresentation
                }
                if wantSplit.isEmpty {
                    // The BARE form: the asymmetric invariant, reported
                    // lane-INDEPENDENTLY so a shared scene can compare
                    // it byte-for-byte everywhere.
                    let halves = gotSplit.split(separator: "/", maxSplits: 1)
                    let stack = kayaScene.windows[0]?.entries.count ?? 0
                    if halves.count == 2, halves[0] == "regular", halves[1] == "stacked",
                        stack >= 1
                    {
                        failures.append(
                            "presentation \(gotSplit): a regular window must not show "
                                + "one pane while its stack holds two")
                    } else {
                        observed.append("split fits")
                    }
                } else if gotSplit == wantSplit {
                    observed.append("split \(wantSplit)")
                } else {
                    failures.append("split \(gotSplit), wanted \(wantSplit)")
                }
            case "expect_panes":
                // `<size class>/<positions>` — the real NSSplitView's
                // columns mapped to the stack slots they hold (the
                // width-and-hiddenness rule, docs/multicolumn-plan.md
                // MECHANICS AMENDMENTS 3); the stack arm reads its top.
                let wantPanes = parts.count > 1 ? kayaQuoted(Array(parts[1...])) : ""
                if wantPanes.isEmpty {
                    // The bare form: expect_split's asymmetric invariant on
                    // the ARM stamp — an occupied pane beside an EMPTY slot
                    // is one visible position and still correct (D1), so
                    // the position list carries no invariant of its own.
                    let stamped = DispatchQueue.main.sync { () -> String in
                        guard let window = kayaScene.windows[0] else {
                            return "unknown/stacked"
                        }
                        return window.formFactor.rawValue + "/" + window.splitPresentation
                    }
                    let halves = stamped.split(separator: "/", maxSplits: 1)
                    let stack = kayaScene.windows[0]?.entries.count ?? 0
                    if halves.count == 2, halves[0] == "regular", halves[1] == "stacked",
                        stack >= 1
                    {
                        failures.append(
                            "presentation \(stamped): a regular window must not show "
                                + "one pane while its stack holds two")
                    } else {
                        observed.append("panes fit")
                    }
                } else {
                    let gotPanes = DispatchQueue.main.sync { kayaPanesReading(0) }
                    if gotPanes == wantPanes {
                        observed.append("panes \(wantPanes)")
                    } else {
                        failures.append("panes \(gotPanes), wanted \(wantPanes)")
                    }
                }
            case "expect_menu_presentation":
                // `<size class>/<presentation>`. macOS reads the REAL bar and is
                // always regular; elsewhere both halves come off the window
                // model's stamps, never a derivation from the other half.
                let wantPresentation =
                    parts.count > 1 ? kayaQuoted(Array(parts[1...])) : ""
                let gotPresentation = DispatchQueue.main.sync { () -> String in
                    #if os(macOS)
                        kayaEnsureMenuSegment()
                        let owned =
                            NSApp.mainMenu.map { mainMenu in
                                kayaOwnedMenuItems.filter { $0.menu === mainMenu }.count
                            } ?? 0
                        return "regular/" + (owned > 0 ? "bar" : "none")
                    #else
                        guard let window = kayaScene.windows[0] else {
                            return "unknown/none"
                        }
                        // HONEST LIMITATION: the iPadOS menu bar is built LAZILY
                        // (buildMenu runs once at launch, with an empty catalog)
                        // and UIKit presents no menu programmatically, so this
                        // half is ARM-DERIVED here (docs/deferred.md).
                        let presentation: String
                        if window.menubar.isEmpty {
                            presentation = "none"
                        } else if window.formFactor == .regular {
                            presentation = "bar"
                        } else {
                            presentation = "overflow"
                        }
                        return window.formFactor.rawValue + "/" + presentation
                    #endif
                }
                if wantPresentation.isEmpty {
                    // The BARE form: assert only the invariant, and report a
                    // LANE-INDEPENDENT string — a shared scene compares
                    // observations byte-for-byte, so it cannot echo a value
                    // that legitimately differs. Asymmetric on purpose.
                    let halves = gotPresentation.split(separator: "/", maxSplits: 1)
                    if halves.count == 2, halves[0] == "regular", halves[1] == "overflow" {
                        failures.append(
                            "presentation \(gotPresentation): a regular window must not "
                                + "hide its catalog behind the compact overflow")
                    } else {
                        observed.append("presentation fits")
                    }
                } else if gotPresentation == wantPresentation {
                    observed.append("presentation \(wantPresentation)")
                } else {
                    failures.append("presentation \(gotPresentation), wanted \(wantPresentation)")
                }
            case "expect_toolbar":
                // THE BARE INVARIANT (docs/chrome-plan.md C2): the promoted set
                // is really in this window's chrome and the remainder is
                // reachable. Never a count — capacity k is the platform's — so
                // the pass is one word and the numbers ride the failure.
                #if os(macOS)
                    let gotChrome = DispatchQueue.main.sync { kayaToolbarChromeRead(0) }
                #else
                    // The same invariant off the REAL UINavigationBar: the
                    // promoted set among the bar buttons UIKit built, in
                    // catalog preorder, with the remainder's More menu beside
                    // them.
                    let gotChrome = DispatchQueue.main.sync { kayaToolbarIOSChromeRead(0) }
                #endif
                // ONE VERDICT SPELLING FOR BOTH HOSTS. The platforms differ in
                // which object graph answers — NSToolbar there, UINavigationBar
                // here — never in what the scene reads back. Two copies of this
                // tail is how that stops being true.
                if let why = kayaToolbarChromeFits(gotChrome) {
                    failures.append(why)
                } else {
                    observed.append("toolbar")
                }
            case "expect_toolbar_item":
                // One promoted button's aspect, off the REAL chrome: a quoted
                // label, then a quoted aspect (a symbol name, or
                // enabled/disabled).
                let toolbarRest = String(line.dropFirst(parts[0].count))
                guard let (toolbarLabel, aspectSpec) = kayaQuotedPrefix(toolbarRest),
                    let (toolbarAspect, toolbarTail) = kayaQuotedPrefix(aspectSpec),
                    toolbarTail.isEmpty
                else {
                    failures.append(
                        "expect_toolbar_item wants a quoted label and a quoted aspect: \(line)")
                    break
                }
                #if os(macOS)
                    let gotItem = DispatchQueue.main.sync {
                        kayaToolbarItemRead(0, toolbarLabel, toolbarAspect)
                    }
                #else
                    let gotItem = DispatchQueue.main.sync {
                        kayaToolbarIOSItemRead(0, toolbarLabel, toolbarAspect)
                    }
                #endif
                if gotItem == toolbarAspect {
                    observed.append("toolbar item \(toolbarLabel) \(toolbarAspect)")
                } else {
                    // The measured answer rides the failure: it tells a wrong
                    // glyph from a button the chrome never got.
                    failures.append(
                        "toolbar item \(toolbarLabel) reads \"\(gotItem)\", "
                            + "wanted \"\(toolbarAspect)\"")
                }
            case "expect_menu":
                // Real item state wherever the item surfaced (bar, More, open
                // context menu); the bounded retry doubles as the wait for a
                // catalog rebuild to land.
                let restLine = String(line.dropFirst(parts[0].count))
                guard let (path, stateSpec) = kayaQuotedPrefix(restLine),
                    let (aspect, wantS) = kayaParseMenuState(stateSpec)
                else {
                    failures.append("expect_menu wants a quoted path and a state: \(line)")
                    break
                }
                if let bad = kayaCheckMenuPath(path) {
                    failures.append("\(bad): \(line)")
                    break
                }
                let got = DispatchQueue.main.sync { kayaMenuStateRead(path, aspect) }
                if got == wantS {
                    observed.append("menu \"\(path)\" \(wantS)")
                } else {
                    failures.append("menu \"\(path)\" reads \"\(got)\", wanted \"\(wantS)\"")
                }
            case "expect_menu_symbol":
                // THE SEMANTIC ICON, read from the REAL item
                // (docs/styling-plan.md D6). Same shape as expect_menu above.
                let restLine = String(line.dropFirst(parts[0].count))
                guard let (path, wantSpec) = kayaQuotedPrefix(restLine),
                    let (wantSymbol, tail) = kayaQuotedPrefix(wantSpec), tail.isEmpty
                else {
                    failures.append(
                        "expect_menu_symbol wants a quoted path and a quoted symbol name: \(line)")
                    break
                }
                if let bad = kayaCheckMenuPath(path) {
                    failures.append("\(bad): \(line)")
                    break
                }
                let gotSymbol = DispatchQueue.main.sync { kayaMenuSymbolRead(path) }
                if gotSymbol == wantSymbol {
                    observed.append("menu \"\(path)\" symbol \"\(wantSymbol)\"")
                } else {
                    // The MEASURED answer rides the failure: it tells a wrong
                    // concept from an item with no image from an item that is
                    // not there yet.
                    failures.append(
                        "menu \"\(path)\" symbol \"\(gotSymbol)\", wanted \"\(wantSymbol)\"")
                }
            case "menu_activate":
                // An action, silent like click. The OPEN context menu owns
                // resolution while presented; otherwise macOS performs the REAL
                // NSMenuItem's target/action with no model fallback, and iOS
                // resolves through the toolbar's own catalog helper.
                let restLine = String(line.dropFirst(parts[0].count))
                // Trailing junk after the quoted path is line-noise, not a
                // no-op (harness.rs's parse_string floor).
                guard let (path, tail) = kayaQuotedPrefix(restLine), tail.isEmpty else {
                    failures.append("menu_activate wants a quoted path: \(line)")
                    break
                }
                if let bad = kayaCheckMenuPath(path) {
                    failures.append("\(bad): \(line)")
                    break
                }
                let failure = DispatchQueue.main.sync { () -> String? in
                    if let wid = kayaOpenContextWidget {
                        guard let roots = kayaScene.contextRoots[wid],
                            let item = kayaResolveMenuPath(path, roots: roots)
                        else {
                            return "no such context item \(path)"
                        }
                        let noun = kayaScene.contextNouns[wid] ?? []
                        kayaOpenContextWidget = nil
                        kayaRoleInertNote(item, verb: "menu_activate \"\(path)\"")
                        kayaMenuUserActivate(item, noun: noun)
                        return nil
                    }
                    // BEFORE THE DISPATCH, AND ON BOTH PLATFORMS, because an
                    // inert standard command is the one activation that succeeds
                    // and does nothing (kayaRoleInertNote).
                    if let item = kayaResolveMenuPath(path, roots: kayaPresentedCatalog()) {
                        kayaRoleInertNote(item, verb: "menu_activate \"\(path)\"")
                    }
                    #if os(macOS)
                        return kayaMacMenuActivate(path)
                    #else
                        guard
                            let item = kayaResolveMenuPath(
                                path, roots: kayaPresentedCatalog())
                        else {
                            return "no such menu item \(path)"
                        }
                        kayaMenuUserActivate(item)
                        return nil
                    #endif
                }
                if let failure { failures.append(failure) }
            case "context_open":
                // An action, silent like click: opens the anchor's context
                // catalog for the following menu_activate. Editable text is
                // rejected up front — its native menu is dress.
                let failure = DispatchQueue.main.sync { () -> String? in
                    if parts[1].hasPrefix("entry") || parts[1].hasPrefix("textarea") {
                        return
                            "\(parts[1]) is editable text — its context menu is dress, not a context_open target"
                    }
                    guard let node = kayaAnyTarget(parts[1]) else {
                        return "no such target \(parts[1])"
                    }
                    guard kayaScene.contextRoots[node.id]?.isEmpty == false else {
                        return "no context menu attached to \(parts[1])"
                    }
                    kayaOpenContextWidget = node.id
                    return nil
                }
                if let failure { failures.append(failure) }
            case "shortcut":
                // An action, silent like click: macOS synthesizes the key event
                // through NSMenu.performKeyEquivalent (the real key-equivalent
                // walk); iOS traverses the interpreter's one dispatch table.
                // Both land in the SAME menu_activated.
                let restLine = String(line.dropFirst(parts[0].count))
                // The grammar floor, mirrored from harness.rs: an empty
                // spelling, whitespace inside the spelling, and trailing junk
                // after the quote are line-noise, not no-ops.
                guard let (spelling, tail) = kayaQuotedPrefix(restLine), tail.isEmpty,
                    !spelling.isEmpty, !spelling.contains(where: { $0.isWhitespace })
                else {
                    failures.append("shortcut wants a quoted spelling: \(line)")
                    break
                }
                let unowned: Bool = DispatchQueue.main.sync {
                    // A CHORD REACHES THE SAME COMMANDS, so it reaches the
                    // same silence: no scene pastes by chord today, and the
                    // session that first writes one must not have to find this
                    // out again.
                    if let id = kayaShortcutItems[spelling], let item = kayaScene.menuItems[id] {
                        kayaRoleInertNote(item, verb: "shortcut \"\(spelling)\"")
                    }
                    #if os(macOS)
                        return kayaMacShortcut(spelling)
                    #else
                        guard let id = kayaShortcutItems[spelling],
                            let item = kayaScene.menuItems[id]
                        else { return true }
                        kayaMenuUserActivate(item)
                        return false
                    #endif
                }
                if unowned {
                    // A chord no catalog item owns is a SCRIPT error,
                    // not a silent pass (docs/traps.md).
                    failures.append(
                        "shortcut \(spelling): no catalog item owns this chord")
                }
            default:
                failures.append("unknown step \(line)")
            }
                attempt += 1
                KayaVTrace.attempt(
                    String(parts[0]), attempt,
                    failures.count > failuresBefore
                        ? "<- not yet: " + failures[failuresBefore...].joined(separator: "; ")
                        : "<- ok")
                if let fault = kayaCoreFaultNote() {
                    // THE CORE FAULTED: nothing after this is applied, so the
                    // owed retry is dead time and every later step fails for a
                    // reason three removes from this one. The in-flight attempt
                    // is RETRACTED: it never reached its deadline.
                    failures.removeLast(failures.count - failuresBefore)
                    failures.append(fault)
                    print("KAYA_HARNESS: step-failed \(fault)")
                    reportedFault = true
                    break scriptLines
                }
                if let breach = kayaClipBreachNote() {
                    // THE WITNESS FIRED: somebody else's clip is on the board, so
                    // nothing asserted from here is about the clip this leg
                    // staged. The attempt is RETRACTED — reporting it beside the
                    // breach sent 2026-08-18 after kaya's paste.
                    failures.removeLast(failures.count - failuresBefore)
                    failures.append(breach)
                    print("KAYA_HARNESS: step-failed \(breach)")
                    break scriptLines
                }
                if failures.count > failuresBefore, parts[0].hasPrefix("expect"),
                    Date() < stepDeadline
                {
                    failures.removeLast(failures.count - failuresBefore)
                    Thread.sleep(forTimeInterval: 0.02)
                    retryStep = true
                } else if failures.count > failuresBefore {
                    // THE EVIDENCE MUST OUTLIVE THE PROCESS: the verdict prints
                    // LAST, and an unresolved dialog walks into the
                    // one-per-process guard three steps later, which ABORTS with
                    // the failure list. So a failure prints when it becomes FINAL.
                    for text in failures[failuresBefore...] {
                        print("KAYA_HARNESS: step-failed \(text)")
                    }
                }
            }
        }
    }
    // THE PINS ARE PART OF THE SCENE'S VERDICT: a pin not in force fails the leg
    // that rendered the widget rather than waiting for a gate. ONE CLAUSE FOR
    // BOTH APPLE ARMS, whose vocabularies differ and whose rule does not. THE
    // VERDICT'S OWN READS HOP TOO, so they stay under the ceiling.
    watchdog.enter("<the verdict's plain-text pin read>")
    let pinBreaches = DispatchQueue.main.sync { kayaPlainTextPinBreaches.sorted() }
    if !pinBreaches.isEmpty {
        failures.append(
            "the textarea's plain-text pins are not in force on the live text view: "
                + pinBreaches.joined(separator: ", ")
                + " — restore them in swift/KayaSwiftUI.swift, kayaPinPlainText")
    }
    // THE LAST STEP CAN FAULT TOO, and a fault must never leave a green
    // verdict behind it.
    if !reportedFault, let fault = kayaCoreFaultNote() {
        failures.append(fault)
        print("KAYA_HARNESS: step-failed \(fault)")
    }
    if failures.isEmpty && observed.isEmpty {
        failures.append("script has no expects")
    }
    // A recorded leg must outlive its last sample time — see
    // harness.rs's record_linger; same contract, same constant.
    if ProcessInfo.processInfo.environment["KAYA_RECORD"] != nil
        || ProcessInfo.processInfo.environment["KAYA_HARNESS_GATE"] != nil
    {
        Thread.sleep(forTimeInterval: 0.75)
    }
    if failures.isEmpty {
        print("KAYA_SELFTEST: OK (\(observed.joined(separator: ", ")))")
        // `exit` runs atexit handlers and stdio teardown, which a
        // wedged main thread can hold; the grace leaves anyway.
        watchdog.published(0)
        exit(0)
    }
    // docs/traps.md, "A scene that never mounts measures an invisible app".
    var reported = failures
    watchdog.enter("<the verdict's unmounted-scene read>")
    let unmountedNodeCount = DispatchQueue.main.sync { () -> Int? in
        guard !kayaScene.nodes.isEmpty,
            kayaScene.windows.values.allSatisfy({ !kayaWindowHasMountedContent($0) })
        else { return nil }
        return kayaScene.nodes.count
    }
    if let unmountedNodeCount {
        reported.insert(
            "\(unmountedNodeCount) widgets exist but NO ROOT IS MOUNTED on any surface "
                + "— the scene never called mount(root), so every assertion above measured "
                + "an empty window",
            at: 0)
    }
    // FAILURE ONLY, and BEFORE the publish: after it the watchdog may
    // end the process at any moment (crates/kaya/src/vtrace.rs).
    KayaVTrace.dump("the verdict failed: KAYA_SELFTEST: FAILED (\(reported.joined(separator: "; ")))")
    FileHandle.standardError.write(
        "KAYA_SELFTEST: FAILED (\(reported.joined(separator: "; ")))\n".data(using: .utf8)!)
    watchdog.published(1)
    exit(1)
}

/// The main-axis extent each node's TRACK was allocated — what `expect_shares`
/// reads back. Written by KayaTrackReader, NEVER inside a layout pass: SwiftUI's
/// speculative passes arrive in no useful order and clobbered a correct 25/75
/// into 26/74, and 96/286 into 0/0. Main-actor only.
var kayaMainExtents: [UInt64: Double] = [:]
var kayaTrackSizes: [UInt64: CGSize] = [:]
struct KayaTableTrackObservation {
    let generation: Int
    let size: CGSize
}
var kayaTableTrackSizes: [UInt64: KayaTableTrackObservation] = [:]

/// The invisible frame each flex child rides in IS the track KayaFlex assigned.
/// The reader records the frame's geometry — the layout rect, never the child's
/// drawn size, which several controls inflate or hug.
private struct KayaTrackReader: View {
    let id: UInt64
    let vertical: Bool
    let tableGeneration: Int?

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { record(geo.size) }
                .onChange(of: geo.size) { _, size in record(size) }
                .task(id: tableGeneration) { record(geo.size) }
        }
    }

    private func record(_ size: CGSize) {
        kayaTrackSizes[id] = size
        kayaMainExtents[id] = Double(vertical ? size.height : size.width)
        if let tableGeneration {
            kayaTableTrackSizes[id] = KayaTableTrackObservation(
                generation: tableGeneration, size: size)
        }
    }
}

/// The main-axis extent each CONTAINER rendered at, by node id — what
/// `expect_fills` compares its children's tracks against. Same geometry-only
/// discipline as the track extents: never written from a layout pass.
var kayaContainerExtents: [UInt64: Double] = [:]

/// Each container's CROSS-axis extent, and each child's cross-axis (start,
/// extent) in its container's space — what `expect_aligned` classifies from.
/// Baseline offsets ride an identity alignmentGuide hook: a font metric for
/// single-line text, invariant across speculative passes.
var kayaContainerCross: [UInt64: Double] = [:]
/// The axis each container RENDERED with (true = vertical), recorded by
/// KayaBoxReader — expect_axis's observation.
var kayaContainerAxis: [UInt64: Bool] = [:]
var kayaCrossRects: [UInt64: (Double, Double)] = [:]
var kayaBaselineOffsets: [UInt64: Double] = [:]

/// The main-axis extent each flex child DREW at — what `expect_fills` compares
/// against that child's track. THE TRACK'S SIBLING, DELIBERATELY NOT THE SAME
/// NUMBER: the gap between the assigned rect and the drawn box is where a widget
/// with a hard-coded size hides (96pt in a 126pt slot).
var kayaDrawnExtents: [UInt64: Double] = [:]

/// Records one child's cross rect in the enclosing container's named space, and
/// the main-axis extent it drew at (the reader rides the CHILD, inside the
/// track frame, so it sees the aligned box, not the track).
private struct KayaCellReader: View {
    let id: UInt64
    let parent: UInt64
    let vertical: Bool

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .named("kaya-box-\(parent)"))
            Color.clear
                .onAppear { record(frame) }
                .onChange(of: frame) { _, f in record(f) }
        }
    }

    private func record(_ frame: CGRect) {
        kayaCrossRects[id] =
            vertical
            ? (Double(frame.minX), Double(frame.width))
            : (Double(frame.minY), Double(frame.height))
        kayaDrawnExtents[id] = Double(vertical ? frame.height : frame.width)
    }
}

/// The container-inset measurement pair (docs/styling-plan.md D3): the INNER
/// reader rides the container's content, the OUTER one the same view after
/// `.padding(node.inset)`, and `expect_inset <target>` reads the halved gap.
/// Both record unconditionally, so a step can assert a container is FLUSH (0).
@MainActor var kayaInsetInner: [UInt64: CGSize] = [:]
@MainActor var kayaInsetOuter: [UInt64: CGSize] = [:]

private struct KayaInsetReader: View {
    let id: UInt64
    let outer: Bool

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { record(geo.size) }
                .onChange(of: geo.size) { _, size in record(size) }
        }
    }

    private func record(_ size: CGSize) {
        if outer {
            kayaInsetOuter[id] = size
        } else {
            kayaInsetInner[id] = size
        }
    }
}

private struct KayaBoxReader: View {
    let id: UInt64
    let vertical: Bool
    /// A GROUPED FLOW'S CONTENT BOX IS ITS CARDS' INTERIOR (the grouped-screen
    /// rule): the section stream pads every run and form by the card inset,
    /// so a child spanning the interior spans the flow's content.
    var crossInset: Double = 0

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { record(geo.size) }
                .onChange(of: geo.size) { _, size in record(size) }
                // An axis FLIP with a coincidentally equal box would
                // otherwise leave the previous axis on record.
                .onChange(of: vertical) { _, _ in record(geo.size) }
        }
    }

    private func record(_ size: CGSize) {
        kayaContainerExtents[id] = Double(vertical ? size.height : size.width)
        kayaContainerCross[id] = Double(vertical ? size.width : size.height) - crossInset
        // The axis the RENDER used, recorded only when the container
        // laid out — expect_axis's observation (never the model's
        // field: a backend that ignored the write must fail, the
        // expect_aligned rule).
        kayaContainerAxis[id] = vertical
    }
}

/// expect_breadth's read, shared with expect_hugs: nil for no such target,
/// "" when the target spans its container's breadth, otherwise the shortfall
/// (a "no ..." sentence when a reader has nothing recorded). Main thread.
func kayaBreadthShortfall(_ spec: Substring) -> String? {
    guard let widget = kayaAnyTarget(spec) else { return nil }
    guard
        let parent = (kayaScene.columns + kayaScene.rows).first(where: { c in
            c.children.contains(where: { $0.id == widget.id })
        })
    else { return "no parent — not a flex child" }
    guard let inner = kayaContainerCross[parent.id], inner > 0 else {
        return "no container layout recorded"
    }
    // A SCROLL'S BREADTH IS ITS SCROLL VIEW'S, never its cell's: the cell
    // wrapper spanned while the ScrollView inside it hugged, and only the
    // driver's real pan saw the difference.
    let breadth: Double
    if widget.kind == kindScroll {
        guard widget.scrollViewportW > 0 else {
            return "no scroll viewport recorded"
        }
        breadth = widget.scrollViewportW
    } else {
        guard let rect = kayaCrossRects[widget.id] else {
            return "no cross box recorded — not a flex child"
        }
        breadth = rect.1
    }
    if breadth >= inner - 2 { return "" }
    return "spans \(Int(breadth.rounded()))pt of its parent's \(Int(inner.rounded()))pt breadth"
}

/// The mounted root's rendered size and the area the window offered it — what
/// `expect_root_fills` compares. Both come from GeometryReaders, so neither can
/// be clobbered by a speculative layout pass. Main-actor only.
var kayaRootSize = CGSize.zero
var kayaAvailableSize = CGSize.zero

/// SwiftUI's half of the `grow` contract ([`Prop::Grow`]), which VStack/HStack
/// cannot express: `layoutPriority` is ORDINAL. The cell proposes the FULL cell,
/// never the child's fitted size, which the alignment-frame idiom re-proposes
/// (docs/deferred.md's KayaCell entry).
struct KayaCell: Layout {
    /// Trace only (KAYA_LAYOUT_TRACE): which node this cell wraps, so one
    /// run's lines can be read as a chain rather than a pile.
    var traceId: UInt64 = 0
    /// The CONTAINER's axis: true for a column's cells.
    let vertical: Bool
    /// The container's cross-axis align mode.
    let align: Int64

    /// A CELL WHOSE CHILD RENDERED NOTHING IS A ZERO-SIZE CELL, NEVER A TRAP:
    /// "produces a view" is a convention no type enforces, and `subviews[0]` on
    /// a COUNT ZERO collection traps before any expectation can be read
    /// (tools/check-empty-child.py).
    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        // MEASURED AT THE WIDTH WE WERE GIVEN (ruled 2026-08-29, KayaFlex's
        // rule): text is as tall as the width lets it be, so `.unspecified`
        // here reported ONE LINE and a long label truncated where it should
        // have wrapped.
        let probe = ProposedViewSize(width: proposal.width, height: nil)
        let natural = subviews.first?.sizeThatFits(probe) ?? .zero
        let out = CGSize(
            width: proposal.width ?? natural.width,
            height: proposal.height ?? natural.height)
        kayaTrace("cell#\(traceId) size in=\(proposal.width.map { Int($0) } ?? -1)x"
            + "\(proposal.height.map { Int($0) } ?? -1) natural=\(Int(natural.width))x"
            + "\(Int(natural.height)) out=\(Int(out.width))x\(Int(out.height))")
        return out
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        guard let child = subviews.first else { return }
        let full = ProposedViewSize(width: bounds.width, height: bounds.height)
        let size = child.sizeThatFits(full)
        kayaTrace("cell#\(traceId) place bounds=\(Int(bounds.width))x\(Int(bounds.height)) "
            + "childAsked=\(Int(size.width))x\(Int(size.height))")
        // The baseline-recording hooks are alignmentGuide closures, and guide
        // closures only run when somebody QUERIES a guide. Query .top
        // explicitly: a stack derives its guide from its children, so the
        // query cascades into a row's text children.
        _ = child.dimensions(in: full)[VerticalAlignment.top]
        var x: CGFloat = 0
        var y: CGFloat = 0
        if vertical {
            switch align {
            case alignCenter: x = (bounds.width - size.width) / 2
            case alignEnd: x = bounds.width - size.width
            default: x = 0
            }
        } else {
            switch align {
            case alignCenter: y = (bounds.height - size.height) / 2
            case alignEnd: y = bounds.height - size.height
            default: y = 0
            }
        }
        child.place(
            at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
            anchor: .topLeading, proposal: full)
    }
}

/// The declared table's surface (docs/tables-plan.md), kayaTableTier below being
/// the rule between the two tiers. The sortOrder binding is the click path and
/// nothing else: its getter presents the GUEST's declared indicator and its
/// setter emits sort_requested, since the platform never sorts the model.
private struct KayaColumnSpec: Identifiable {
    let id: Int
    let title: String
}

// docs/traps.md, "A table viewport contains rows".
func kayaInvalidateTableGeometry() {
    for table in kayaScene.columns where !table.tableColumns.isEmpty {
        table.tableGeometryEpoch &+= 1
    }
}

// ---- the slider (docs/slider-plan.md) ---------------------------------------
// The hosted platform slider with ONE commit path (S1, S2, S8): snap the value
// to the declared step, clamp it to the range, mirror the node, emit the live
// move, and — when the gesture is over — the committed value, once, only when
// it differs from the last committed one.

/// THE ONE SPELLING every harness reads back (harness.rs spelled_slider):
/// six decimals, trailing zeros and point dropped.
func kayaSpelledSlider(_ value: Double) -> String {
    let rounded = (value * 1_000_000).rounded() / 1_000_000
    var s = String(format: "%.6f", rounded)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return (s.isEmpty || s == "-" || s == "-0") ? "0" : s
}

/// Where the thumb may rest: on the step's lattice from the minimum, inside
/// the range.
func kayaSnappedSlider(_ node: KayaNode, _ raw: Double) -> Double {
    var v = raw
    if node.step > 0 {
        v = node.minValue + ((raw - node.minValue) / node.step).rounded() * node.step
    }
    return min(max(v, node.minValue), node.maxValue)
}

func kayaSliderCommitted(_ node: KayaNode, _ raw: Double, final: Bool, restore: (Double) -> Void) {
    let v = kayaSnappedSlider(node, raw)
    if v != raw { restore(v) }
    if v != node.value {
        kayaUserWrite { node.value = v }
        KayaHost.emitValue(node.tag, v)
    }
    if final && v != node.committed {
        kayaUserWrite { node.committed = v }
        KayaHost.emitValueCommitted(node.tag, v)
    }
}

/// The keyboard's nudge (S7): one step, or a hundredth of the range when the
/// slider is continuous.
func kayaSliderNudge(_ node: KayaNode) -> Double {
    node.step > 0 ? node.step : (node.maxValue - node.minValue) / 100
}

#if os(macOS)
    /// The hosted controls by node id: what `set_value` drives and
    /// `expect_slider` reads.
    nonisolated(unsafe) var kayaSliderControls: [UInt64: KayaNSSlider] = [:]

    func kayaControlSliderValue(_ control: KayaNSSlider) -> Double { control.doubleValue }

    /// Drive the control the way a user's gesture reaches it: the value moves
    /// and the commit path runs as one finished gesture.
    func kayaDriveSlider(_ control: KayaNSSlider, node: KayaNode, to value: Double) {
        control.doubleValue = value
        kayaSliderCommitted(node, control.doubleValue, final: true) { control.doubleValue = $0 }
    }

    /// NSSlider whose arrow keys move by kaya's nudge and commit at once, and
    /// whose action tells a drag's movement from its release by the event that
    /// carried it.
    final class KayaNSSlider: NSSlider {
        var node: KayaNode?

        private func nudge(by direction: Double) {
            guard let node else { return }
            let target = doubleValue + direction * kayaSliderNudge(node)
            doubleValue = target
            kayaSliderCommitted(node, doubleValue, final: true) { self.doubleValue = $0 }
        }
        override func moveLeft(_ sender: Any?) { nudge(by: -1) }
        override func moveDown(_ sender: Any?) { nudge(by: -1) }
        override func moveRight(_ sender: Any?) { nudge(by: 1) }
        override func moveUp(_ sender: Any?) { nudge(by: 1) }
    }

    final class KayaSliderCoordinator: NSObject {
        var node: KayaNode
        init(node: KayaNode) { self.node = node }
        @objc func changed(_ sender: KayaNSSlider) {
            // A continuous NSSlider sends its action for every drag movement
            // and once more on the release; the event type tells them apart.
            let type = NSApp.currentEvent?.type
            let final = type != .leftMouseDown && type != .leftMouseDragged
            kayaSliderCommitted(node, sender.doubleValue, final: final) { sender.doubleValue = $0 }
        }
    }

    struct KayaSliderSurface: NSViewRepresentable {
        let node: KayaNode

        func makeCoordinator() -> KayaSliderCoordinator { KayaSliderCoordinator(node: node) }

        func makeNSView(context: Context) -> KayaNSSlider {
            let slider = KayaNSSlider()
            slider.isContinuous = true
            slider.target = context.coordinator
            slider.action = #selector(KayaSliderCoordinator.changed(_:))
            kayaSliderControls[node.id] = slider
            apply(slider)
            return slider
        }

        func updateNSView(_ slider: KayaNSSlider, context: Context) {
            context.coordinator.node = node
            kayaSliderControls[node.id] = slider
            apply(slider)
        }

        static func dismantleNSView(_ slider: KayaNSSlider, coordinator: KayaSliderCoordinator) {
            if kayaSliderControls[coordinator.node.id] === slider {
                kayaSliderControls.removeValue(forKey: coordinator.node.id)
            }
        }

        private func apply(_ slider: KayaNSSlider) {
            slider.node = node
            slider.minValue = node.minValue
            slider.maxValue = node.maxValue
            // Ticks at the declared spacing (S5); the control snaps to them
            // itself only when every tick is a stop and every stop a tick,
            // otherwise the commit path snaps.
            let span = node.maxValue - node.minValue
            slider.numberOfTickMarks =
                node.tickSpacing > 0 && span > 0 ? Int((span / node.tickSpacing).rounded()) + 1 : 0
            slider.tickMarkPosition = .below
            slider.allowsTickMarkValuesOnly = node.step > 0 && node.tickSpacing == node.step
            slider.doubleValue = node.value
        }
    }
#else
    nonisolated(unsafe) var kayaSliderControls: [UInt64: KayaTickedSlider] = [:]

    func kayaControlSliderValue(_ control: KayaTickedSlider) -> Double { Double(control.slider.value) }

    /// THE DRIVEN VALUE AND NOT THE READ-BACK: UISlider's store is a Float,
    /// so a driven 0.37 reads back as 0.3700000047683716 and the app would
    /// hear that where the mac's Double-backed NSSlider hands it 0.37
    /// (docs/traps.md). The control has not moved off what it was just
    /// given, so the Double the verb named is the same position said
    /// exactly; a real gesture still reports the thumb's own Float.
    func kayaDriveSlider(_ control: KayaTickedSlider, node: KayaNode, to value: Double) {
        control.slider.setValue(Float(value), animated: false)
        kayaSliderCommitted(node, value, final: true) {
            control.slider.setValue(Float($0), animated: false)
        }
    }

    /// UISlider over a tick strip of kaya's own, since UIKit draws none: the
    /// shape of Settings' Larger Text slider (docs/slider-plan.md S5). The
    /// ticks sit under the track, one per spacing, each centred where the
    /// thumb rests on that value.
    final class KayaTickedSlider: UIView {
        let slider = UISlider()
        var node: KayaNode?
        var tickValues: [Double] = [] {
            didSet { setNeedsDisplay(); invalidateIntrinsicContentSize() }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            backgroundColor = .clear
            slider.isContinuous = true
            // ONE CONTROL, NOT TWO: the strip is this view's own drawing, so
            // the composition publishes ITSELF and the hosted UISlider is not
            // a second element. A bare UIView publishes no traits, and the
            // reader finds this wrapper — the role read `unknown/Level` until
            // the trait was declared here (docs/traps.md).
            slider.isAccessibilityElement = false
            isAccessibilityElement = true
            accessibilityTraits = .adjustable
            addSubview(slider)
        }
        required init?(coder: NSCoder) { fatalError("kaya: not from a storyboard") }

        override var accessibilityValue: String? {
            get { slider.accessibilityValue }
            set { super.accessibilityValue = newValue }
        }

        // An element that claims `.adjustable` has to adjust: VoiceOver's
        // swipes move by kaya's own nudge (S7) through the one commit path.
        override func accessibilityIncrement() { nudge(by: 1) }
        override func accessibilityDecrement() { nudge(by: -1) }

        private func nudge(by direction: Double) {
            guard let node else { return }
            let want = Double(slider.value) + direction * kayaSliderNudge(node)
            kayaSliderCommitted(node, want, final: true) {
                slider.setValue(Float($0), animated: false)
            }
        }

        override var intrinsicContentSize: CGSize {
            let base = slider.intrinsicContentSize
            return CGSize(width: base.width, height: base.height + (tickValues.isEmpty ? 0 : 8))
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let height = slider.intrinsicContentSize.height
            slider.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
            setNeedsDisplay()
        }

        override func draw(_ rect: CGRect) {
            guard !tickValues.isEmpty, let ctx = UIGraphicsGetCurrentContext() else { return }
            let track = slider.trackRect(forBounds: slider.bounds)
            ctx.setStrokeColor(UIColor.tertiaryLabel.cgColor)
            ctx.setLineWidth(1)
            let top = slider.frame.minY + track.maxY + 2
            for value in tickValues {
                let thumb = slider.thumbRect(forBounds: slider.bounds, trackRect: track, value: Float(value))
                let x = (slider.frame.minX + thumb.midX).rounded() + 0.5
                ctx.move(to: CGPoint(x: x, y: top))
                ctx.addLine(to: CGPoint(x: x, y: top + 6))
            }
            ctx.strokePath()
        }
    }

    final class KayaSliderCoordinator: NSObject {
        var node: KayaNode
        init(node: KayaNode) { self.node = node }
        @objc func moved(_ sender: UISlider) {
            kayaSliderCommitted(node, Double(sender.value), final: false) {
                sender.setValue(Float($0), animated: false)
            }
        }
        @objc func released(_ sender: UISlider) {
            kayaSliderCommitted(node, Double(sender.value), final: true) {
                sender.setValue(Float($0), animated: false)
            }
        }
    }

    struct KayaSliderSurface: UIViewRepresentable {
        let node: KayaNode

        func makeCoordinator() -> KayaSliderCoordinator { KayaSliderCoordinator(node: node) }

        func makeUIView(context: Context) -> KayaTickedSlider {
            let view = KayaTickedSlider()
            view.slider.addTarget(
                context.coordinator, action: #selector(KayaSliderCoordinator.moved(_:)),
                for: .valueChanged)
            view.slider.addTarget(
                context.coordinator, action: #selector(KayaSliderCoordinator.released(_:)),
                for: [.touchUpInside, .touchUpOutside, .touchCancel])
            kayaSliderControls[node.id] = view
            apply(view)
            return view
        }

        func updateUIView(_ view: KayaTickedSlider, context: Context) {
            context.coordinator.node = node
            kayaSliderControls[node.id] = view
            apply(view)
        }

        func sizeThatFits(_ proposal: ProposedViewSize, uiView: KayaTickedSlider, context: Context)
            -> CGSize?
        {
            let fit = uiView.intrinsicContentSize
            return CGSize(width: proposal.width ?? fit.width, height: fit.height)
        }

        static func dismantleUIView(_ view: KayaTickedSlider, coordinator: KayaSliderCoordinator) {
            if kayaSliderControls[coordinator.node.id] === view {
                kayaSliderControls.removeValue(forKey: coordinator.node.id)
            }
        }

        private func apply(_ view: KayaTickedSlider) {
            view.node = node
            view.slider.minimumValue = Float(node.minValue)
            view.slider.maximumValue = Float(node.maxValue)
            view.slider.setValue(Float(node.value), animated: false)
            let span = node.maxValue - node.minValue
            if node.tickSpacing > 0 && span > 0 {
                let count = Int((span / node.tickSpacing).rounded())
                view.tickValues = (0...count).map { node.minValue + Double($0) * node.tickSpacing }
            } else {
                view.tickValues = []
            }
        }
    }
#endif

// ---- the pickers (docs/datetime-plan.md) ------------------------------------
// The wire packs a date as YYYYMMDD and a time as HHMM (D2); the CONTROL holds
// an instant, read in the Gregorian calendar of the current zone whatever
// calendar the user displays, so the round trip is stable and the wire stays
// Gregorian (D9). Dates are placed at noon so no zone's midnight can move them.

private let kayaCivil: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone.current
    return c
}()

func kayaDateFromPackedDate(_ packed: Int64) -> Date {
    let parts = DateComponents(
        year: Int(packed / 10_000), month: Int((packed / 100) % 100), day: Int(packed % 100),
        hour: 12)
    return kayaCivil.date(from: parts) ?? Date()
}

func kayaPackedDate(_ date: Date) -> Int64 {
    let c = kayaCivil.dateComponents([.year, .month, .day], from: date)
    return Int64(c.year! * 10_000 + c.month! * 100 + c.day!)
}

func kayaDateFromPackedTime(_ packed: Int64) -> Date {
    kayaCivil.date(bySettingHour: Int(packed / 100), minute: Int(packed % 100), second: 0, of: Date())
        ?? Date()
}

func kayaPackedTime(_ date: Date) -> Int64 {
    let c = kayaCivil.dateComponents([.hour, .minute], from: date)
    return Int64(c.hour! * 100 + c.minute!)
}

/// The fixed-digit spellings every scene reads (harness.rs Date/Time Display).
func kayaSpelledDate(_ packed: Int64) -> String {
    String(format: "%04lld-%02lld-%02lld", packed / 10_000, (packed / 100) % 100, packed % 100)
}

func kayaSpelledTime(_ packed: Int64) -> String {
    String(format: "%02lld:%02lld", packed / 100, packed % 100)
}

/// `YYYY-MM-DD` to packed, refusing what is not a date (a leap rule the
/// calendar knows; a shape the digits do not fit).
func kayaParseDate(_ s: String) -> Int64? {
    let parts = s.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
        let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
    else { return nil }
    let c = DateComponents(calendar: kayaCivil, year: y, month: m, day: d)
    guard c.isValidDate else { return nil }
    return Int64(y * 10_000 + m * 100 + d)
}

func kayaParseTime(_ s: String) -> Int64? {
    let parts = s.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
        let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m)
    else { return nil }
    return Int64(h * 100 + m)
}

/// THE ONE COMMIT PATH, user or driven (D7, D8): read the control's instant
/// back as civil parts, CLAMP the date to its range and snap the minute
/// step, mirror the node, emit. Clamping is AppKit's own answer to a date
/// past a bound (NSDatePicker moves a programmatic or stepped value onto
/// the bound before its action fires, measured 2026-09-04) and the rule
/// every backend follows (D4). A pick that lands on the value already held
/// emits nothing.
func kayaPickerCommitted(_ node: KayaNode, isTime: Bool, _ picked: Date, restore: (Date) -> Void) {
    if isTime {
        let raw = kayaPackedTime(picked)
        var packed = raw
        let step = max(1, node.minuteStep)
        if step > 1 {
            var hour = Int(raw / 100)
            var minute = (Int(raw % 100) + step / 2) / step * step
            if minute >= 60 {
                minute = 0
                hour = (hour + 1) % 24
            }
            packed = Int64(hour * 100 + minute)
            if packed != raw { restore(kayaDateFromPackedTime(packed)) }
        }
        if packed == node.time { return }
        kayaUserWrite { node.time = packed }
        KayaHost.emitTimeChanged(node.tag, packed)
    } else {
        var packed = kayaPackedDate(picked)
        if node.minDate != 0 && packed < node.minDate { packed = node.minDate }
        if node.maxDate != 0 && packed > node.maxDate { packed = node.maxDate }
        if packed != kayaPackedDate(picked) { restore(kayaDateFromPackedDate(packed)) }
        if packed == node.date { return }
        kayaUserWrite { node.date = packed }
        KayaHost.emitDateChanged(node.tag, packed)
    }
}

#if os(macOS)
    typealias KayaPickerControl = NSDatePicker
    /// The hosted controls by node id, the drag surfaces' registry shape: what
    /// `set_date`/`set_time` drive and `expect_picker` reads.
    nonisolated(unsafe) var kayaPickerControls: [UInt64: NSDatePicker] = [:]

    func kayaControlDate(_ control: NSDatePicker) -> Date { control.dateValue }

    /// Drive the control the way a user's pick reaches it: the value moves
    /// and the control's own action fires.
    func kayaDrivePicker(_ control: NSDatePicker, to date: Date) {
        control.dateValue = date
        control.sendAction(control.action, to: control.target)
    }

    final class KayaPickerCoordinator: NSObject {
        var node: KayaNode
        let isTime: Bool
        init(node: KayaNode, isTime: Bool) {
            self.node = node
            self.isTime = isTime
        }
        @objc func changed(_ sender: NSDatePicker) {
            kayaPickerCommitted(node, isTime: isTime, sender.dateValue) { sender.dateValue = $0 }
        }
    }

    /// NSDatePicker in its text-field-and-stepper style with the calendar
    /// overlay: the mac's compact field (D6). AppKit has no minute interval,
    /// so the step is snapped in the commit path (D3).
    struct KayaPickerSurface: NSViewRepresentable {
        let node: KayaNode
        let isTime: Bool

        func makeCoordinator() -> KayaPickerCoordinator {
            KayaPickerCoordinator(node: node, isTime: isTime)
        }

        func makeNSView(context: Context) -> NSDatePicker {
            let picker = NSDatePicker()
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = isTime ? .hourMinute : .yearMonthDay
            picker.presentsCalendarOverlay = !isTime
            picker.isBezeled = true
            picker.target = context.coordinator
            picker.action = #selector(KayaPickerCoordinator.changed(_:))
            kayaPickerControls[node.id] = picker
            apply(picker)
            return picker
        }

        func updateNSView(_ picker: NSDatePicker, context: Context) {
            context.coordinator.node = node
            kayaPickerControls[node.id] = picker
            apply(picker)
        }

        static func dismantleNSView(_ picker: NSDatePicker, coordinator: KayaPickerCoordinator) {
            if kayaPickerControls[coordinator.node.id] === picker {
                kayaPickerControls.removeValue(forKey: coordinator.node.id)
            }
        }

        private func apply(_ picker: NSDatePicker) {
            if isTime {
                picker.dateValue = kayaDateFromPackedTime(node.time)
            } else {
                picker.minDate = node.minDate == 0
                    ? nil : kayaCivil.startOfDay(for: kayaDateFromPackedDate(node.minDate))
                picker.maxDate = node.maxDate == 0
                    ? nil
                    : kayaCivil.date(
                        byAdding: DateComponents(day: 1, second: -1),
                        to: kayaCivil.startOfDay(for: kayaDateFromPackedDate(node.maxDate)))
                picker.dateValue = kayaDateFromPackedDate(node.date)
            }
        }
    }
#else
    typealias KayaPickerControl = UIDatePicker
    nonisolated(unsafe) var kayaPickerControls: [UInt64: UIDatePicker] = [:]

    func kayaControlDate(_ control: UIDatePicker) -> Date { control.date }

    func kayaDrivePicker(_ control: UIDatePicker, to date: Date) {
        control.date = date
        control.sendActions(for: .valueChanged)
    }

    final class KayaPickerCoordinator: NSObject {
        var node: KayaNode
        let isTime: Bool
        init(node: KayaNode, isTime: Bool) {
            self.node = node
            self.isTime = isTime
        }
        @objc func changed(_ sender: UIDatePicker) {
            kayaPickerCommitted(node, isTime: isTime, sender.date) { sender.date = $0 }
        }
    }

    /// UIDatePicker in its compact style (D6): a pill that opens the calendar
    /// or the wheel. UIKit has a minute interval of its own.
    struct KayaPickerSurface: UIViewRepresentable {
        let node: KayaNode
        let isTime: Bool

        func makeCoordinator() -> KayaPickerCoordinator {
            KayaPickerCoordinator(node: node, isTime: isTime)
        }

        func makeUIView(context: Context) -> UIDatePicker {
            let picker = UIDatePicker()
            picker.datePickerMode = isTime ? .time : .date
            picker.preferredDatePickerStyle = .compact
            picker.setContentHuggingPriority(.required, for: .horizontal)
            picker.setContentHuggingPriority(.required, for: .vertical)
            picker.addTarget(
                context.coordinator, action: #selector(KayaPickerCoordinator.changed(_:)),
                for: .valueChanged)
            kayaPickerControls[node.id] = picker
            apply(picker)
            return picker
        }

        func updateUIView(_ picker: UIDatePicker, context: Context) {
            context.coordinator.node = node
            kayaPickerControls[node.id] = picker
            apply(picker)
        }

        /// THE HOST MUST ANSWER THE SIZE. A compact UIDatePicker asked for
        /// nothing by SwiftUI's `fixedSize` drew a 60x30 pill with NO value
        /// text — every read-back green, since the control HELD the date
        /// (captured 2026-09-04 for the pickers page; docs/traps.md). Its
        /// fitting size is the pill with its text.
        func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIDatePicker, context: Context)
            -> CGSize?
        {
            uiView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        }

        static func dismantleUIView(_ picker: UIDatePicker, coordinator: KayaPickerCoordinator) {
            if kayaPickerControls[coordinator.node.id] === picker {
                kayaPickerControls.removeValue(forKey: coordinator.node.id)
            }
        }

        private func apply(_ picker: UIDatePicker) {
            if isTime {
                picker.minuteInterval = max(1, node.minuteStep)
                picker.date = kayaDateFromPackedTime(node.time)
            } else {
                picker.minimumDate = node.minDate == 0
                    ? nil : kayaCivil.startOfDay(for: kayaDateFromPackedDate(node.minDate))
                picker.maximumDate = node.maxDate == 0
                    ? nil
                    : kayaCivil.date(
                        byAdding: DateComponents(day: 1, second: -1),
                        to: kayaCivil.startOfDay(for: kayaDateFromPackedDate(node.maxDate)))
                picker.date = kayaDateFromPackedDate(node.date)
            }
        }
    }
#endif

/// The USER ROUTE's model mirror — the checkbox flip, the drag, the keystroke,
/// the platform undo. A write nobody batched stales the table observations the
/// way a batch does, scene-wide because a sibling can move a table it is not
/// inside of. tools/check-table-tier.py holds every model write here.
func kayaUserWrite(_ write: () -> Void) {
    kayaInvalidateTableGeometry()
    write()
}

/// The staleness token every table observation carries: a STORED epoch, advanced
/// by kayaApply, kayaSetWindowContentSize and kayaUserWrite. NEVER derived from
/// the model — that cost 41% of the mac main thread at 100k rows
/// (docs/traps.md); tools/check-table-tier.py refuses a walk here.
func kayaTableGeometryGeneration(_ table: KayaNode) -> Int {
    table.tableGeometryEpoch
}

func kayaCurrentTableTrackWidth(_ table: KayaNode) -> Double? {
    let generation = kayaTableGeometryGeneration(table)
    guard let observation = kayaTableTrackSizes[table.id],
        observation.generation == generation,
        observation.size.width > 0
    else { return nil }
    return Double(observation.size.width)
}

/// The table registries are main-thread state, written by the representables
/// as tables appear and leave; a bare subscript from the harness thread races
/// the write and dies as a tagged-pointer objectForKey (docs/traps.md: A
/// registry subscript on the harness thread races the main thread's write).
/// Every harness-side read goes through this; tools/check-table-tier.py holds it.
func kayaOnMain<T>(_ body: () -> T) -> T {
    Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
}

/// A TABLE'S COLUMNS' AXIS, off the real scroll view (docs/tables-plan.md,
/// ruled 2026-08-29). macOS only for now: the SYNTHESIZED tier's reading is
/// the fan-out, and until it lands the verbs say that rather than claiming
/// the target does not exist.
func kayaTableHorizontal(_ spec: Substring) -> (content: Double, viewport: Double)? {
    guard let node = kayaTarget(spec, "column", kayaScene.columns) else { return nil }
    #if os(macOS)
        // ON THE MAIN THREAD: `NSTableView.frame` re-tiles a dirty table
        // inside the read, and a tile from the harness thread is an
        // NSException (measured 2026-09-02, the portfolio leg after a
        // header_click; docs/traps.md).
        if let driver = kayaOnMain({ kayaTableDrivers[node.id] }) {
            return Thread.isMainThread
                ? driver.horizontalExtents()
                : DispatchQueue.main.sync { driver.horizontalExtents() }
        }
    #endif
    // The SYNTHESIZED tier's own pair, measured by its layout into the
    // placement box (docs/tables-plan.md, ruled 2026-08-29).
    guard let window = kayaOnMain({ kayaTableColumnAxes[node.id] }), window.placement.columnsViewport > 0
    else { return nil }
    return (Double(window.placement.columnsContent),
            Double(window.placement.columnsViewport))
}

/// The columns' granted scroll for a table target: what `expect_column_edges`
/// must forgive before it convicts cells of standing outside the viewport.
func kayaTableColumnsReach(_ spec: Substring) -> CGFloat {
    guard let pair = kayaTableHorizontal(spec) else { return 0 }
    return CGFloat(max(0, pair.content - pair.viewport))
}

func kayaTableTrailing(_ spec: Substring) -> (Double, Double)? {
    guard let node = kayaTarget(spec, "column", kayaScene.columns) else { return nil }
    #if os(macOS)
        if let driver = kayaOnMain({ kayaTableDrivers[node.id] }) {
            // The same main-thread rule as kayaTableHorizontal's read.
            let edges = Thread.isMainThread
                ? driver.trailingEdges()
                : DispatchQueue.main.sync { driver.trailingEdges() }
            return (edges.visible, edges.content)
        }
    #endif
    guard let window = kayaOnMain({ kayaTableColumnAxes[node.id] }), window.placement.columnsViewport > 0
    else { return nil }
    // Where the visible trailing edge sits against the content's.
    return (Double(window.columnsOffset + window.placement.columnsViewport),
            Double(window.placement.columnsContent))
}

/// The track the CELLS were given: the assigned track less what the card spends
/// on both sides. KayaTrackReader records the flex cell's OUTER box while the
/// reporters read the card's CONTENT box, so a padded card underfills its own
/// track unless it comes off first. `pad` is a parameter for the mac probe.
func kayaTableContentTrack(_ track: Double, pad: CGFloat, synthesized: Bool) -> Double {
    synthesized ? track - 2 * Double(pad) : track
}


/// THE CELLS' OWN BOX inside a carded SCROLL CLIP: the card's interior lives
/// INSIDE the scrolling content (KayaTableCardFace), so the clip is wider by
/// that interior on each side and both writers of a grown table's viewport
/// report the cells' box. Vertical is untouched — the interior scrolls.
func kayaTableCellsBox(inScrollClip clip: CGRect, interior: CGFloat) -> CGRect {
    clip.insetBy(dx: interior, dy: 0)
}

private func kayaTableCellKey(_ row: KayaNode, _ column: Int, _ cell: KayaNode) -> String {
    "\(row.id)/\(column)/\(cell.id)"
}

func kayaTableEdgeClusters(_ edges: [Double], tolerance: Double = 2) -> [Double] {
    var clusters: [Double] = []
    for edge in edges.sorted() {
        if let representative = clusters.last, edge - representative <= tolerance { continue }
        clusters.append(edge)
    }
    return clusters
}

enum KayaTableColumnAlignment {
    case missing(column: Int)
    case split(column: Int, clusters: [Double])
    case aligned(representatives: [Double])
}

func kayaTableColumnAlignment(
    _ columns: [[CGRect]], tolerance: Double = 2
) -> KayaTableColumnAlignment {
    var representatives: [Double] = []
    for (column, frames) in columns.enumerated() {
        let clusters = kayaTableEdgeClusters(
            frames.map { Double($0.minX) }, tolerance: tolerance)
        guard !clusters.isEmpty else { return .missing(column: column) }
        guard clusters.count == 1 else {
            return .split(column: column, clusters: clusters)
        }
        representatives.append(clusters[0])
    }
    return .aligned(representatives: representatives)
}

func kayaTableColumnRepresentativesIncrease(
    _ representatives: [Double], tolerance: Double = 2
) -> Bool {
    for (previous, next) in zip(representatives, representatives.dropFirst()) {
        if next - previous <= tolerance { return false }
    }
    return true
}

func kayaTableBounds(_ frames: [CGRect]) -> CGRect? {
    guard let first = frames.first else { return nil }
    return frames.dropFirst().reduce(first) { $0.union($1) }
}

/// CELLS PAST THE VIEWPORT ARE A DEFECT ONLY IF THEY CANNOT BE REACHED
/// (docs/tables-plan.md, ruled 2026-08-29). `reach` is the surface's own granted
/// scroll, MEASURED rather than derived from content minus viewport, which would
/// make the clause agree with itself.
func kayaTableFramesFitHorizontally(
    _ frames: [CGRect], inside viewport: CGRect, reach: CGFloat = 0,
    tolerance: CGFloat = 2
) -> Bool {
    guard let bounds = kayaTableBounds(frames) else { return false }
    return bounds.minX >= viewport.minX - reach - tolerance
        && bounds.maxX <= viewport.maxX + reach + tolerance
}

func kayaTableViewportMatchesTrack(
    _ viewport: CGRect, track: Double, tolerance: Double = 2
) -> Bool {
    track > 0 && abs(Double(viewport.width) - track) <= tolerance
}

/// gtk.rs's `ContentLeftUnderfill` here: how far inside its own viewport a
/// table's cells start, nil when flush — the number, not a Bool, so the sentence
/// names what convicted it. SYNTHESIZED ONLY, and MEASURED: the mac native
/// tier's cells sit 16pt in with no accessor for that amount (docs/deferred.md).
func kayaTableLeadingUnderfill(
    _ leading: Double, viewport: CGRect, synthesized: Bool, tolerance: Double = 2
) -> Double? {
    guard synthesized else { return nil }
    let inside = leading - Double(viewport.minX)
    return inside > tolerance ? inside : nil
}

/// Whether the tier that recorded this table's CURRENT viewport
/// synthesized it — `kayaCurrentTableTrackWidth`'s staleness rule, one
/// field over.
func kayaCurrentTableSynthesized(_ table: KayaNode) -> Bool {
    guard let observation = table.tableViewport,
        observation.generation == kayaTableGeometryGeneration(table)
    else { return false }
    return observation.synthesized
}

func kayaTableFramesFitVertically(
    _ frames: [CGRect], inside viewport: CGRect, tolerance: CGFloat = 2
) -> Bool {
    guard let bounds = kayaTableBounds(frames) else { return false }
    return bounds.minY >= viewport.minY - tolerance
        && bounds.maxY <= viewport.maxY + tolerance
}

enum KayaCurrentTableGeometry {
    case missingViewport
    /// A row with SOME current cells but not all: incoherence on any
    /// tier — a row is rendered whole or not at all.
    case partialRow(got: Int, want: Int)
    /// Rows short of the declaration where the tier owes them all: the
    /// synthesized tier lays out every row, the native tier at least one
    /// (NSTableView realizes only visible rows — measured 2026-08-24, 20
    /// declared rows recording 10 of 40 cells on a CORRECT table).
    case unrealized(realized: Int, declared: Int)
    case current(viewport: CGRect, rows: [CGRect], columns: [[CGRect]])
}

func kayaCurrentTableGeometry(_ table: KayaNode) -> KayaCurrentTableGeometry {
    let generation = kayaTableGeometryGeneration(table)
    guard let viewport = table.tableViewport,
        viewport.generation == generation,
        viewport.frame.width > 0,
        viewport.frame.height > 0
    else { return .missingViewport }

    // PER-ROW realization: the native NSTableView materializes only visible
    // rows, so a declared row is observed WHOLE or legitimately absent — a
    // partial row is incoherence on any tier.
    let columnCount = table.tableColumns.count
    var realized: [[CGRect]] = []
    for row in table.children {
        var cells: [CGRect] = []
        for column in table.tableColumns.indices where row.children.indices.contains(column) {
            let key = kayaTableCellKey(row, column, row.children[column])
            if let observation = table.tableCellFrames[key],
                observation.generation == generation
            {
                cells.append(observation.frame)
            }
        }
        if cells.count == columnCount {
            realized.append(cells)
        } else if !cells.isEmpty {
            return .partialRow(got: cells.count, want: columnCount)
        }
    }
    if viewport.synthesized, realized.count != table.children.count {
        return .unrealized(realized: realized.count, declared: table.children.count)
    }
    if realized.isEmpty, !table.children.isEmpty {
        return .unrealized(realized: 0, declared: table.children.count)
    }
    var columnFrames: [[CGRect]] = (0..<columnCount).map { column in
        realized.map { $0[column] }
    }
    if viewport.synthesized {
        for column in table.tableColumns.indices {
            let key = "h/\(column)"
            guard let observation = table.tableCellFrames[key],
                observation.generation == generation
            else { return .partialRow(got: 0, want: columnCount) }
            columnFrames[column].insert(observation.frame, at: 0)
        }
    }
    return .current(
        viewport: viewport.frame, rows: realized.flatMap { $0 }, columns: columnFrames)
}

@available(macOS 14.4, iOS 17.4, *)
struct KayaColumnComparator: SortComparator {
    var column: Int
    var order: SortOrder
    /// Never consulted for ordering — Table sorts nothing here; this
    /// type is only the sortOrder binding's currency.
    func compare(_ a: KayaNode, _ b: KayaNode) -> ComparisonResult { .orderedSame }
}

enum KayaTableTier {
    case native
    case synthesized
}

/// The tier rule's width input. `.noSizeClass` is the mac, which reads
/// none; `.unknown` is an iOS host that reported none.
enum KayaTableWidth {
    case noSizeClass
    case regular
    case compact
    case unknown
}

/// Which tier a host takes, from its inputs alone — PURE, because no scene can
/// name the tier that drew (docs/traps.md, "An observable with no
/// discriminator"); tools/check-table-tier.py drives this truth table.
func kayaTableTier(width: KayaTableWidth, dynamicColumns: Bool, folded: Bool) -> KayaTableTier {
    guard dynamicColumns else { return .synthesized }
    // A FOLDED table hosts scroll-away header content inside its own viewport
    // (docs/adaptive-layout-plan.md D7), which only the synthesized tier's
    // scroll can hold: the native NSTableView owns its scroll and takes no
    // arbitrary content above row 0. Any platform, any width.
    if folded { return .synthesized }
    switch width {
    case .noSizeClass, .regular: return .native
    case .compact, .unknown: return .synthesized
    }
}

/// The environment's size class in the rule's vocabulary. Cross-platform
/// on purpose — the type compiles at kaya's macOS floor, so the gate's
/// probe reads the same mapping the phone runs.
func kayaTableWidth(sizeClass: UserInterfaceSizeClass?) -> KayaTableWidth {
    switch sizeClass {
    case .regular: return .regular
    case .compact: return .compact
    default: return .unknown
    }
}

struct KayaTableSurface: View {
    let node: KayaNode
    #if !os(macOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// Nothing on macOS SETS a horizontal size class (both the key and the type
    /// compile there, measured at -target macos13.0) and the mac Table does not
    /// collapse, so the mac reports the absence. Internal, not private: the
    /// gate's probe reads it to check this host's own branch.
    var widthClass: KayaTableWidth {
        #if os(macOS)
            return .noSizeClass
        #else
            return kayaTableWidth(sizeClass: horizontalSizeClass)
        #endif
    }

    var body: some View {
        if #available(macOS 14.4, iOS 17.4, *) {
            switch kayaTableTier(
                width: widthClass, dynamicColumns: true,
                folded: !node.foldedChildren.isEmpty)
            {
            case .native: KayaNativeTable(node: node)
            case .synthesized: KayaSynthesizedTable(node: node)
            }
        } else {
            // dynamicColumns: false, the rule's forced half — and the one
            // branch where KayaNativeTable does not compile.
            KayaSynthesizedTable(node: node)
        }
    }
}

/// The mac native tier's fixed metrics, MEASURED 2026-08-24 on the inset-style
/// NSTableView: rowHeight 24, intercell 0, header 28, 5pt above the first row
/// and below the last (docs/virtualization-plan.md §4). The leading 5 is THE
/// STYLE'S OWN, so a content inset double-counts it.
#if os(macOS)
    /// The measured numbers above, named. The row height is a FLOOR: a row
    /// measures TALLER when its content is, which moves a For onto the
    /// corrected path.
    let kayaNativeRowHeight: CGFloat = 24
    let kayaNativeHeaderHeight: CGFloat = 28
    let kayaNativeTopInset: CGFloat = 5
    let kayaNativeApronHeight: CGFloat = 5

    /// The WHOLE collection's height, realized or not: the core's arithmetic
    /// when it has any, and the tier's floor before the first measurement —
    /// which is what the gate probes get, hosting this path with no core.
    private func kayaNativeTableExtent(_ node: KayaNode) -> CGFloat {
        if let geometry = KayaHost.windowGeometry(node.id), geometry.total > 0,
            geometry.extent > 0
        {
            return CGFloat(geometry.extent)
        }
        return CGFloat(node.children.count) * kayaNativeRowHeight
    }

    private func kayaNativeTableContentHeight(_ node: KayaNode) -> CGFloat {
        kayaNativeHeaderHeight + kayaNativeTopInset + kayaNativeTableExtent(node)
            + kayaNativeApronHeight
    }

    /// An AppKit rect in the SPACE THE HARNESS COMPARES IN: the window's content
    /// view, y DOWN from its top-left, which is what SwiftUI's `.global` means.
    /// AppKit's y runs the other way, and expect_fills' hug read an unflipped
    /// rect as 33pt of chrome ABOVE the last row (measured).
    func kayaHarnessRect(_ rect: CGRect, in view: NSView) -> CGRect {
        guard let content = view.window?.contentView else { return rect }
        let inContent = view.convert(rect, to: content)
        if content.isFlipped { return inContent }
        return CGRect(
            x: inContent.minX, y: content.bounds.height - inContent.maxY,
            width: inContent.width, height: inContent.height)
    }
#else
    private func kayaNativeTableContentHeight(_ node: KayaNode) -> CGFloat {
        28 + 5 + CGFloat(node.children.count) * 44 + 5
    }
#endif

/// The apron's ground, on macOS a SHAPESTYLE rather than a Color:
/// `Color(nsColor:)` snapshots the NSColor OUTSIDE the window while the table
/// resolves it inside, which in dark aqua left a 5pt #1E1E1E bar under a
/// #24292C interior (measured 2026-08-26; tools/check-table-card.py).
private var kayaNativeTableApron: some View {
    #if os(macOS)
        return Rectangle().fill(.background)
    #else
        return Color(uiColor: .systemBackground)
    #endif
}

/// The header record BOTH native paths publish — "<titles|joined>
/// [^N|vN]" — written by the path that DREW, never a model echo, so
/// expect_columns proves a table rendered. No size-class prefix: headers
/// render at every width (ratified 2026-08-21, docs/tables-plan.md).
private func kayaTablePresented(_ node: KayaNode) -> String {
    var presented = node.tableColumns.joined(separator: "|")
    if node.tableSorted != kayaSortNone {
        presented += node.tableDirection == 0 ? " ^" : " v"
        presented += String(node.tableSorted)
    }
    return presented
}

@available(macOS 14.4, iOS 17.4, *)
private struct KayaNativeTable: View {
    let node: KayaNode

    var body: some View {
        // READ IN THE BODY, all of it: these are what make SwiftUI
        // re-evaluate — and on macOS re-enter updateNSView — when the
        // model or the geometry generation moves.
        let generation = kayaTableGeometryGeneration(node)
        #if os(macOS)
            // CONTENT IS THE FLOOR IN BOTH AXES (ruled 2026-08-26): the height
            // is declared here from the core's arithmetic, the WIDTH by
            // sizeThatFits below, the only place that sees the parent's
            // PROPOSAL and can answer hug and squeeze differently.
            KayaMacNativeTable(
                node: node, generation: generation, columns: node.tableColumns,
                sorted: node.tableSorted, direction: node.tableDirection,
                contentWidth: node.tableContentWidth
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if node.grow <= 0 {
                    kayaNativeTableApron.frame(height: kayaNativeApronHeight)
                }
            }
            .frame(
                height: node.grow > 0 ? nil : kayaNativeTableContentHeight(node),
                alignment: .top)
            // THE FLOOR STAYS A FLOOR (ruling A, 2026-08-26): a hugging
            // container widens to the table's content (check-table-tier.py). A
            // WRAPPER making this scrollable needs the viewport observation to
            // move with it (docs/deferred.md's mac-table-reachability entry).
            .frame(alignment: .leading)
        #else
            KayaTableColumns(node: node, generation: generation)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if node.grow <= 0 {
                        kayaNativeTableApron.frame(height: 5)
                    }
                }
                .frame(
                    height: node.grow > 0 ? nil : kayaNativeTableContentHeight(node),
                    alignment: .top)
                .background(
                    KayaTableViewportReporter(
                        node: node, generation: generation, synthesized: false))
                .onAppear { node.tablePresented = kayaTablePresented(node) }
                .onChange(of: node.tableColumns) {
                    node.tablePresented = kayaTablePresented(node)
                }
                .onChange(of: node.tableSorted) {
                    node.tablePresented = kayaTablePresented(node)
                }
                .onChange(of: node.tableDirection) {
                    node.tablePresented = kayaTablePresented(node)
                }
        #endif
    }
}

#if !os(macOS)
    /// The iOS native tier: SwiftUI's own Table, which is what a regular
    /// iPad width takes at or above TableColumnForEach's floor. The mac's
    /// per-row attribute-graph cost is not iOS's residue to pay yet —
    /// docs/virtualization-plan.md §6.3 carries the phones' tiers.
    @available(macOS 14.4, iOS 17.4, *)
    private struct KayaTableColumns: View {
        let node: KayaNode
        let generation: Int

        private var specs: [KayaColumnSpec] {
            node.tableColumns.enumerated().map { KayaColumnSpec(id: $0.offset, title: $0.element) }
        }

        private var sortOrder: Binding<[KayaColumnComparator]> {
            Binding(
                get: {
                    node.tableSorted == kayaSortNone
                        ? []
                        : [
                            KayaColumnComparator(
                                column: Int(node.tableSorted),
                                order: node.tableDirection == 0 ? .forward : .reverse)
                        ]
                },
                set: { requested in
                    // The user clicked a header: SwiftUI proposes a new
                    // order, and the proposal's COLUMN is the whole
                    // message — direction cycling is the guest's policy.
                    if let first = requested.first {
                        KayaHost.emitSortRequested(node.sortTag, UInt32(first.column))
                    }
                }
            )
        }

        var body: some View {
            Table(node.children, sortOrder: sortOrder) {
                TableColumnForEach(specs) { spec in
                    TableColumn(
                        Text(spec.title),
                        sortUsing: KayaColumnComparator(column: spec.id, order: .forward)
                    ) { (row: KayaNode) in
                        // The core held every row template to the declared
                        // arity; the guard is positional safety, never a
                        // reachable state (check-empty-child's rule: one
                        // node stays one widget even when it cannot show).
                        if spec.id < row.children.count {
                            KayaRender(
                                node: row.children[spec.id], flexVertical: false,
                                flexStretch: false
                            )
                            .background(
                                KayaEdgeReporter(
                                    node: node,
                                    key: kayaTableCellKey(row, spec.id, row.children[spec.id]),
                                    generation: generation))
                        }
                    }
                }
            }
            // A TIER REPORTS WHAT IT REALIZES, and this one realizes the WHOLE
            // collection. This backend DECLARES that it windows rows, so a band
            // starts at a screenful and a tier that never reported would show
            // that screenful forever (docs/deferred.md, declares-windowing).
            .onAppear { reportWholeCollection() }
            .onChange(of: node.children.count) { reportWholeCollection() }
        }

        private func reportWholeCollection() {
            let total = KayaHost.windowGeometry(node.id).map { Int($0.total) } ?? 0
            KayaHost.windowMoved(node.id, 0, max(total, node.children.count))
        }
    }
#endif

#if os(macOS)
    /// Every live mac table's driver, by container widget id — how the
    /// harness verbs reach the tier that drew (scroll_to_row's scroll,
    /// expect_window's realized count). Main thread only, like every
    /// other registry here.
    nonisolated(unsafe) var kayaTableDrivers: [UInt64: KayaTableDriver] = [:]

    /// THE MAC NATIVE TIER (docs/virtualization-plan.md §4): NSTableView through
    /// NSViewRepresentable with a REAL DATA SOURCE, cells recycled by AppKit.
    /// SwiftUI's Table is one attribute-graph node per row, 39% of the mac frame
    /// at scale (docs/measurements/choke-macos-2026-08-24.txt).
    private struct KayaMacNativeTable: NSViewRepresentable {
        let node: KayaNode
        /// Everything below is read in the BODY that builds this, so a
        /// model change or a geometry invalidation re-enters
        /// updateNSView — which is what republishes the observations at
        /// the current generation even when no frame moved.
        let generation: Int
        let columns: [String]
        let sorted: UInt32
        let direction: UInt32
        /// READ IN THE BODY that builds this, so a re-floor re-evaluates the view
        /// and SwiftUI asks sizeThatFits again: a read off the node inside that
        /// method is no observation, and the hug kept the first unmeasured pass
        /// (measured — the ideal stuck at 10pt while the tier published 367).
        let contentWidth: Double

        func makeCoordinator() -> KayaTableDriver {
            KayaTableDriver(node: node)
        }

        func makeNSView(context: Context) -> NSScrollView {
            context.coordinator.build()
        }

        func updateNSView(_ view: NSScrollView, context: Context) {
            context.coordinator.update(node: node, generation: generation)
        }

        static func dismantleNSView(_ view: NSScrollView, coordinator: KayaTableDriver) {
            coordinator.dismantle()
        }

        /// CONTENT IS THE FLOOR, AND THE OFFER IS THE ANSWER (ruling A
        /// 2026-08-26): as `minWidth` a 430pt table arrived as a 430pt PROPOSAL
        /// inside a 320pt window with nothing left to scroll
        /// (docs/probes/swiftui-sizing-2026.md).
        func sizeThatFits(
            _ proposal: ProposedViewSize, nsView: NSScrollView, context: Context
        ) -> CGSize? {
            let floor = CGFloat(contentWidth)
            guard let offered = proposal.width, offered.isFinite, offered > 0 else {
                // THE HUG. Before the driver has measured its columns,
                // answering the fitting size PINS the table at ~10pt and leaves
                // its columns no room to be measured in, so the hug stays 10
                // forever (measured 2026-08-29). nil until there is one.
                guard floor > 0 else { return nil }
                // Capped by the window: a hug wider than the window puts
                // columns where no scroll view can reach them.
                let room = nsView.window?.contentLayoutRect.width ?? floor
                return CGSize(
                    width: room > 0 ? min(floor, room) : floor,
                    height: proposal.height ?? nsView.fittingSize.height)
            }
            return CGSize(
                width: offered, height: proposal.height ?? nsView.fittingSize.height)
        }

    }

    /// The scroll view that says when it laid out. NSViewRepresentable
    /// has no layout callback, and the report has to run after the rows
    /// have their frames rather than before.
    final class KayaTableScrollView: NSScrollView {
        var onLayout: () -> Void = {}
        override func layout() {
            super.layout()
            onLayout()
        }
    }

    /// One recycled cell: an NSHostingView over the stamped cell's own
    /// KayaRender. A row outside the band keeps its cell and shows
    /// nothing rather than dropping out of the table's geometry — one
    /// node is one widget (tools/check-empty-child.py), one tier over.
    final class KayaTableCellView: NSTableCellView {
        private let host = NSHostingView(rootView: AnyView(Color.clear))

        override init(frame: NSRect) {
            super.init(frame: frame)
            host.translatesAutoresizingMaskIntoConstraints = false
            addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: leadingAnchor),
                host.trailingAnchor.constraint(equalTo: trailingAnchor),
                host.topAnchor.constraint(equalTo: topAnchor),
                host.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        required init?(coder: NSCoder) { nil }

        func present(_ cell: KayaNode?) {
            guard let cell else {
                host.rootView = AnyView(Color.clear)
                return
            }
            // LEADING, and vertically centred in the row: the cell fills its
            // column and the content sits under its own header, which is what
            // the SwiftUI Table drew and what the synthesized tier places (an
            // unaligned host centres every cell instead).
            host.rootView = AnyView(
                KayaRender(node: cell, flexVertical: false, flexStretch: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading))
        }

        /// What this cell's content ASKS for, which the row's measured extent
        /// is made of. The IDEAL size, not the fitting one: the host is pinned
        /// to the cell's edges, so a fitting size answers the cell's box back.
        var contentHeight: CGFloat { host.intrinsicContentSize.height }
        var contentWidth: CGFloat { host.intrinsicContentSize.width }
    }

    /// The mac table's data source, delegate, window reporter and geometry
    /// reporter — ONE object, because they are one loop: AppKit asks the CORE
    /// for row heights, the core's band decides which rows carry widgets, and
    /// this hands back the visible range and the extents laid out.
    final class KayaTableDriver: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private(set) var node: KayaNode
        private var generation = 0
        private let scrollView = KayaTableScrollView()
        private let tableView = NSTableView()
        /// The core's band and the collection's declared total, read
        /// TOGETHER and held for the length of a layout pass: AppKit's
        /// row count may not change under it.
        private var first = 0
        private var realized = 0
        private var total = 0
        /// The last range handed to the core. A layout that moved
        /// nothing reports nothing, so the report -> stamp -> layout
        /// loop cannot run away.
        private var reported: NSRange?
        /// True while this object is writing the sort indicator, so
        /// restoring the model's own indicator is not read back as
        /// another header click.
        private var applyingIndicator = false
        /// One report per main-queue turn, however many layout and
        /// scroll callbacks asked for it.
        private var reportScheduled = false

        init(node: KayaNode) {
            self.node = node
            super.init()
        }

        func build() -> NSScrollView {
            tableView.dataSource = self
            tableView.delegate = self
            tableView.style = .inset
            tableView.usesAlternatingRowBackgroundColors = true
            tableView.gridStyleMask = []
            tableView.intercellSpacing = NSSize(width: 0, height: 0)
            tableView.rowHeight = kayaNativeRowHeight
            tableView.allowsColumnReordering = false
            tableView.allowsMultipleSelection = false
            tableView.columnAutoresizingStyle = .noColumnAutoresizing
            let header = NSTableHeaderView(
                frame: NSRect(x: 0, y: 0, width: 0, height: kayaNativeHeaderHeight))
            tableView.headerView = header
            scrollView.documentView = tableView
            scrollView.hasVerticalScroller = true
            // A TABLE WIDER THAN ITS TRACK SCROLLS (docs/tables-plan.md, ruled
            // 2026-08-29): with the scroller off those columns were unreachable
            // rather than absent. OVERLAY, since a scroller that takes space
            // takes it from the body and the edge reader calls that underfill.
            scrollView.hasHorizontalScroller = true
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = true
            scrollView.automaticallyAdjustsContentInsets = false
            // ZERO, deliberately: the 5pt above the first row is the
            // INSET STYLE'S OWN padding (measured 2026-08-25 —
            // rect(ofRow: 0).minY is 5), so a content inset on top of it
            // double-counts and pushes the last row out of the hug.
            scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(boundsMoved),
                name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
            scrollView.onLayout = { [weak self] in
                self?.resetHorizontalOriginIfGeometryMoved()
                self?.scheduleReport()
            }
            kayaTableDrivers[node.id] = self
            syncColumns()
            return scrollView
        }

        /// A TABLE THAT WAS JUST LAID OUT SHOWS ITS FIRST COLUMN: AppKit keeps
        /// the visible area across a geometry change, so a table whose width
        /// moved arrived parked at its TRAILING edge (2026-08-29). Reset on a
        /// changed extent only, so a batch keeps the reader's scroll.
        private var lastHorizontalExtents: (CGFloat, CGFloat)?
        /// The extents a DELIBERATE scroll was made at; a relayout that moved
        /// neither must leave that scroll alone (gtk.rs states the same rule).
        /// Without it the reset and `scroll_end` fought and the run produced no
        /// verdict at all (measured 2026-08-29).
        private var readerScrolledAt: (CGFloat, CGFloat)?

        private var horizontalExtentPair: (CGFloat, CGFloat) {
            (scrollView.documentView?.frame.width ?? 0,
             scrollView.contentView.bounds.width)
        }

        private func extentsMoved(_ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat)) -> Bool {
            abs(a.0 - b.0) > 0.5 || abs(a.1 - b.1) > 0.5
        }

        func resetHorizontalOriginIfGeometryMoved() {
            let now = horizontalExtentPair
            defer { lastHorizontalExtents = now }
            if let parked = readerScrolledAt, !extentsMoved(parked, now) { return }
            readerScrolledAt = nil
            // THE CLIP IS THE TRIGGER: a resize moves the viewport, and
            // AppKit keeps the visible RIGHT edge across it, which parked a
            // freshly resized table at its trailing edge and made
            // `expect_at_end` true before anything had scrolled.
            guard let last = lastHorizontalExtents, abs(last.1 - now.1) > 0.5 else { return }
            let origin = scrollView.contentView.bounds.origin
            guard origin.x != 0 else { return }
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: origin.y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        /// THE COLUMNS' AXIS, read off the REAL scroll view (docs/tables-plan.md,
        /// ruled 2026-08-29). NO FORCED LAYOUT IN A HARNESS READ — gtk.rs's 1630
        /// rule one platform over: the layout re-enters this driver and the
        /// apply path, and the run produced no verdict at all.
        func horizontalExtents() -> (content: Double, viewport: Double) {
            (Double(scrollView.documentView?.frame.width ?? 0),
             Double(scrollView.contentView.bounds.width))
        }

        /// The toolkit's own scrolling, like scroll_end's reader proxy one
        /// tier over — never a frame written by hand.
        func scrollToTrailingEdge() {
            // NO settled() HERE: this runs on the main thread and the
            // layout hook it would trigger re-enters this driver's own
            // reset — the whole run then produced no verdict at all
            // (measured 2026-08-29). The READS settle; the write does not.
            guard let document = scrollView.documentView else { return }
            let x = max(0, document.frame.width - scrollView.contentView.bounds.width)
            scrollView.contentView.scroll(to: NSPoint(x: x, y: scrollView.contentView.bounds.origin.y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            readerScrolledAt = horizontalExtentPair
        }

        /// Where the visible rect's trailing edge sits against the
        /// document's — the reading `expect_at_end` convicts on.
        func trailingEdges() -> (visible: Double, content: Double) {
            (Double(scrollView.documentVisibleRect.maxX),
             Double(scrollView.documentView?.frame.maxX ?? 0))
        }

        func dismantle() {
            NotificationCenter.default.removeObserver(self)
            if kayaTableDrivers[node.id] === self {
                kayaTableDrivers.removeValue(forKey: node.id)
            }
        }

        func update(node: KayaNode, generation: Int) {
            self.node = node
            self.generation = generation
            kayaTableDrivers[node.id] = self
            syncColumns()
            applyIndicator()
            refresh()
            tableView.reloadData()
            let presented = kayaTablePresented(node)
            let target = node
            DispatchQueue.main.async { target.tablePresented = presented }
            // A same-size invalidation moves no frame, so the layout
            // callback may never come: the report rides the next
            // main-queue turn as well.
            scheduleReport()
        }

        // --- The data source: the COLLECTION's rows, not the band's. --

        func numberOfRows(in tableView: NSTableView) -> Int {
            total > 0 ? total : node.children.count
        }

        /// The stamped row at a POSITION in the collection's order, or
        /// nil where the band has not realized it.
        private func row(at index: Int) -> KayaNode? {
            guard index >= 0 else { return nil }
            if total > 0 {
                let offset = index - first
                guard offset >= 0, offset < node.children.count else { return nil }
                return node.children[offset]
            }
            return index < node.children.count ? node.children[index] : nil
        }

        /// THE CORE IS THE ONLY ESTIMATOR (§2): measured where this row
        /// has been measured, the pitch where it has not, and the tier's
        /// own floor before anything has been measured at all.
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            let extent = KayaHost.rowExtent(node.id, row)
            return extent > 0 ? CGFloat(extent) : kayaNativeRowHeight
        }

        func tableView(
            _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
        ) -> NSView? {
            guard let tableColumn,
                let column = tableView.tableColumns.firstIndex(of: tableColumn)
            else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("kaya-cell")
            let cell =
                (tableView.makeView(withIdentifier: identifier, owner: self)
                as? KayaTableCellView) ?? KayaTableCellView(frame: .zero)
            cell.identifier = identifier
            let stamped = self.row(at: row)
            cell.present(
                (stamped?.children.count ?? 0) > column ? stamped?.children[column] : nil)
            return cell
        }

        func tableView(
            _ tableView: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]
        ) {
            guard !applyingIndicator else { return }
            // A header click is a REQUEST: nothing sorts here. The guest
            // reorders by key and re-declares, so the indicator goes
            // straight back to what the model says until it does.
            if let key = tableView.sortDescriptors.first?.key,
                let column = Int(key.dropFirst(kayaSortKeyPrefix.count))
            {
                KayaHost.emitSortRequested(node.sortTag, UInt32(column))
            }
            applyIndicator()
        }

        // --- The report loop. ------------------------------------------

        @objc private func boundsMoved() {
            // A scroll the harness did not issue is the user's: the
            // anchor yields to free scrolling.
            if !inProgrammaticScroll { anchorRow = nil }
            scheduleReport()
        }

        /// THE REPORT NEVER RUNS INSIDE A LAYOUT PASS: it writes an @Observable
        /// node, and a SwiftUI invalidation raised from inside -[NSView layout]
        /// makes AppKit throw (an EXC_BREAKPOINT with no output, 2026-08-25).
        /// One coalesced hop per turn instead.
        private func scheduleReport() {
            guard !reportScheduled else { return }
            reportScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reportScheduled = false
                self.report()
            }
        }

        /// Once per layout and once per scroll: refresh the band, hand back the
        /// visible range and extents, record the geometry. THE RANGE LEADS AND
        /// THE HEIGHTS FOLLOW (§3.4); §2.4's anchor is re-parked every cycle,
        /// since AppKit's position keeping lost the race under load.
        private var anchorRow: Int?
        private var inProgrammaticScroll = false

        func report() {
            guard scrollView.window != nil else { return }
            refresh()
            layoutColumns()
            reparkAnchor()
            let visible = visibleRows()
            if reported.map({ !NSEqualRanges($0, visible) }) ?? true {
                reported = visible
                KayaHost.windowMoved(node.id, visible.location, visible.length)
            }
            measureRows(visible)
            recordGeometry(visible)
        }

        private func reparkAnchor() {
            guard let anchor = anchorRow, anchor < numberOfRows(in: tableView) else { return }
            let want = tableView.rect(ofRow: anchor).minY
            let clip = scrollView.contentView
            if abs(clip.bounds.origin.y - want) > 0.5 {
                inProgrammaticScroll = true
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: want))
                scrollView.reflectScrolledClipView(clip)
                inProgrammaticScroll = false
            }
        }

        private func refresh() {
            guard let geometry = KayaHost.windowGeometry(node.id), geometry.total > 0 else {
                first = 0
                realized = node.children.count
                total = 0
                return
            }
            first = Int(geometry.first)
            realized = Int(geometry.count)
            total = Int(geometry.total)
        }

        /// What the reader can actually SEE: the clip view keeps its full height
        /// and reserves the header by shifting its bounds origin (measured,
        /// origin.y -28 for a 28pt header), so documentVisibleRect covers a band
        /// the header is drawn over and rows behind it would report visible.
        private func visibleRect() -> CGRect {
            var rect = scrollView.contentView.documentVisibleRect
            let header = tableView.headerView?.frame.height ?? 0
            rect.origin.y += header
            rect.size.height = max(0, rect.size.height - header)
            return rect
        }

        private func visibleRows() -> NSRange {
            let range = tableView.rows(in: visibleRect())
            guard range.location != NSNotFound, range.length > 0 else {
                return NSRange(location: 0, length: 0)
            }
            return range
        }

        /// The extents this tier laid the realized rows out at, reported
        /// only when they DISAGREE with what the core already holds —
        /// exactly, no tolerance (§2.3), which is also what stops the
        /// note-heights round trip below from repeating forever.
        private func measureRows(_ visible: NSRange) {
            guard visible.length > 0 else { return }
            var heights: [Double] = []
            var moved = false
            for offset in 0..<visible.length {
                let row = visible.location + offset
                let height = Double(measuredHeight(row))
                heights.append(height)
                if KayaHost.rowExtent(node.id, row) != height { moved = true }
            }
            guard moved else { return }
            KayaHost.rowsMeasured(node.id, visible.location, heights)
            tableView.noteHeightOfRows(
                withIndexesChanged: IndexSet(
                    integersIn: visible.location..<(visible.location + visible.length)))
        }

        /// A row's extent along the scroll axis: what its cells ask for,
        /// floored by the tier's own row height. The FLOOR is why uniform
        /// single-line rows never leave the exact path, and the max is why
        /// a structurally taller row moves its For onto the corrected one.
        private func measuredHeight(_ row: Int) -> CGFloat {
            var height = kayaNativeRowHeight
            for column in tableView.tableColumns.indices {
                guard
                    let cell = tableView.view(atColumn: column, row: row, makeIfNecessary: false)
                        as? KayaTableCellView
                else { continue }
                height = max(height, cell.contentHeight)
            }
            return height.rounded(.up)
        }

        /// docs/tables-plan.md decision 6, the mac tier's spelling: a column's
        /// content is its width FLOOR, leftover distributes, and the table spans
        /// its viewport. Only the realized rows can be measured.
        private func layoutColumns() {
            let columns = tableView.tableColumns
            guard !columns.isEmpty else { return }
            var widths = columns.map { max(24, $0.headerCell.cellSize.width + 16) }
            let visible = visibleRows()
            for offset in 0..<visible.length {
                let row = visible.location + offset
                for column in columns.indices {
                    guard
                        let cell = tableView.view(
                            atColumn: column, row: row, makeIfNecessary: false)
                            as? KayaTableCellView
                    else { continue }
                    widths[column] = max(widths[column], cell.contentWidth + 16)
                }
            }
            // THE STYLE'S OWN ROW INSET COMES OUT OF THE TRACK FIRST: an
            // inset-style NSTableView indents every cell, so columns summing to
            // the clip width overflow by twice that inset. A system metric with
            // no accessor, READ from the first cell's leading edge.
            let inset =
                tableView.numberOfRows > 0
                ? max(0, min(tableView.frameOfCell(atColumn: 0, row: 0).minX, 32)) : 0
            let track = scrollView.contentView.bounds.width - 2 * inset
            let floors = widths
            var widened = false
            let total = widths.reduce(0, +)
            if track > total {
                let share = (track - total) / CGFloat(columns.count)
                for column in widths.indices { widths[column] += share }
            }
            for (index, column) in columns.enumerated() {
                // THE MEASURED FLOOR IS THE MINIMUM, not 24: an assignment is
                // only a request, and with a 24pt minimum AppKit compresses the
                // columns to the track it was given, ellipsizing every cell
                // while layoutColumns had the right widths (track 178 of 267.33).
                if abs(column.minWidth - floors[index]) > 0.5 {
                    column.minWidth = floors[index]
                }
                column.maxWidth = .greatestFiniteMagnitude
                if abs(column.width - widths[index]) > 0.5 {
                    column.width = widths[index]
                    widened = true
                }
            }
            publishContentWidth(floors.reduce(0, +) + 2 * inset)
            if widened { represent(visible) }
        }

        /// A WIDENED COLUMN MUST RE-PRESENT ITS CELLS: AppKit resizes the cell
        /// VIEW when a column moves, but the hosted SwiftUI content keeps the
        /// truncation it chose at the old width (2026-08-26). Setting the root
        /// view again is what makes SwiftUI decide over.
        private func represent(_ visible: NSRange) {
            guard visible.length > 0 else { return }
            for offset in 0..<visible.length {
                let index = visible.location + offset
                guard let stamped = row(at: index) else { continue }
                for column in tableView.tableColumns.indices
                where column < stamped.children.count {
                    guard
                        let cell = tableView.view(
                            atColumn: column, row: index, makeIfNecessary: false)
                            as? KayaTableCellView
                    else { continue }
                    cell.present(stamped.children[column])
                }
            }
        }

        /// The native tier's half of content-is-the-floor (ruled 2026-08-26): the
        /// measured content total handed UP so a hugging container widens to it.
        /// ASYNC, since this runs inside a layout pass, and the `!=` guard stops
        /// publish -> re-layout -> publish.
        private func publishContentWidth(_ content: CGFloat) {
            let chrome = max(0, scrollView.bounds.width - scrollView.contentView.bounds.width)
            let want = Double((content + chrome).rounded(.up))
            guard node.tableContentWidth != want else { return }
            let target = node
            DispatchQueue.main.async { target.tableContentWidth = want }
        }

        /// The geometry the harness reads, from the TIER'S OWN frames, both in
        /// window coordinates so they are comparable. SwiftUI's `.global` could
        /// not serve: inside a per-cell hosting view it is that cell's own
        /// space, so every column would report the same edge.
        private func recordGeometry(_ visible: NSRange) {
            let generation = kayaTableGeometryGeneration(node)
            kayaRecordTableViewport(
                node, generation, kayaHarnessRect(scrollView.bounds, in: scrollView), false)
            guard visible.length > 0 else { return }
            for offset in 0..<visible.length {
                let index = visible.location + offset
                guard let stamped = row(at: index) else { continue }
                for column in tableView.tableColumns.indices
                where column < stamped.children.count {
                    let cell = stamped.children[column]
                    let frame = kayaHarnessRect(
                        tableView.frameOfCell(atColumn: column, row: index), in: tableView)
                    kayaRecordTableCell(
                        node, kayaTableCellKey(stamped, column, cell), generation, frame)
                }
            }
        }

        // --- What the harness verbs drive. -----------------------------

        /// The realized band and the declared total as THIS TIER has them: the
        /// core's arithmetic, checked against the rows the table holds. The
        /// compiled table-tier gate reads this; the harness verb does not.
        func band() -> (first: Int, count: Int, total: Int) {
            refresh()
            if total > 0 { return (first, min(realized, node.children.count), total) }
            return (0, node.children.count, node.children.count)
        }

        /// What expect_window compares: the first VISIBLE row and the
        /// declared total — the pair a byte-shared scene can freeze.
        /// The overscan above the viewport is the band's business, not
        /// the verb's.
        func firstVisible() -> (first: Int, total: Int) {
            refresh()
            let visible = tableView.rows(in: tableView.visibleRect)
            let declared = total > 0 ? total : node.children.count
            return (visible.length > 0 ? visible.location : 0, declared)
        }

        /// Scroll so the row at `index` is the viewport's FIRST VISIBLE
        /// row — the top, which is what makes the first-visible row
        /// deterministic even where pixel positions are not.
        func scroll(toRow index: Int) {
            guard index >= 0, index < numberOfRows(in: tableView) else { return }
            anchorRow = index
            let rect = tableView.rect(ofRow: index)
            let clip = scrollView.contentView
            // The header FLOATS above the clip; subtracting its height
            // here over-scrolled by two rows (measured: expect_window
            // read 7498 for a scroll to 7500) — the row's own minY IS
            // the top.
            inProgrammaticScroll = true
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: rect.minY))
            scrollView.reflectScrolledClipView(clip)
            inProgrammaticScroll = false
            report()
        }

        // --- Columns and the sort indicator. ---------------------------

        private func syncColumns() {
            let titles = node.tableColumns
            if tableView.tableColumns.count != titles.count {
                for column in tableView.tableColumns { tableView.removeTableColumn(column) }
                for (index, title) in titles.enumerated() {
                    let column = NSTableColumn(
                        identifier: NSUserInterfaceItemIdentifier("kaya-column-\(index)"))
                    column.title = title
                    // A BARE COLUMN, nothing measured yet: layoutColumns
                    // re-floors it to its content on the first report.
                    column.minWidth = 24
                    column.sortDescriptorPrototype = NSSortDescriptor(
                        key: "\(kayaSortKeyPrefix)\(index)", ascending: true)
                    tableView.addTableColumn(column)
                }
            } else {
                for (index, title) in titles.enumerated()
                where tableView.tableColumns[index].title != title {
                    tableView.tableColumns[index].title = title
                }
            }
        }

        private func applyIndicator() {
            applyingIndicator = true
            defer { applyingIndicator = false }
            let column = Int(node.tableSorted)
            guard node.tableSorted != kayaSortNone, column < tableView.tableColumns.count else {
                tableView.sortDescriptors = []
                return
            }
            tableView.sortDescriptors = [
                NSSortDescriptor(
                    key: "\(kayaSortKeyPrefix)\(column)", ascending: node.tableDirection == 0)
            ]
        }
    }

    /// The sort descriptor key's prefix — the column index rides behind
    /// it, and the header-click handler reads it back.
    let kayaSortKeyPrefix = "kaya-sort-"
#endif

/// The reporters' task id — a struct, not an interpolated string: this is
/// one format per cell per layout pass, for a comparison CGRect answers.
private struct KayaGeometryStamp: Equatable {
    let generation: Int
    let frame: CGRect
}

/// THE ONE WRITER of a table's cell geometry, for BOTH tiers: SwiftUI's
/// reporter below on the synthesized one, NSTableView's own frames on the
/// mac native one. One writer because one displacement has to move both —
/// tools/check-table-tier.py's displaced-cells negative perturbs here.
func kayaRecordTableCell(
    _ node: KayaNode, _ key: String, _ generation: Int, _ frame: CGRect
) {
    node.tableCellFrames[key] = KayaTableCellObservation(
        generation: generation, frame: frame)
}

/// Its viewport twin — `synthesized` is what tells the realization census
/// which tier owes how many rows.
func kayaRecordTableViewport(
    _ node: KayaNode, _ generation: Int, _ frame: CGRect, _ synthesized: Bool
) {
    node.tableViewport = KayaTableViewportObservation(
        generation: generation, frame: frame, synthesized: synthesized)
}

/// docs/traps.md, "A table viewport contains rows".
private struct KayaEdgeReporter: View {
    let node: KayaNode
    let key: String
    let generation: Int
    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            Color.clear.task(id: KayaGeometryStamp(generation: generation, frame: frame)) {
                kayaRecordTableCell(node, key, generation, frame)
            }
        }
    }
}

private struct KayaTableViewportReporter: View {
    let node: KayaNode
    let generation: Int
    let synthesized: Bool
    /// True where this watches a SCROLL CLIP rather than the cells' own box:
    /// the card's interior scrolls inside that clip (kayaTableCellsBox).
    var scrollClip = false

    var body: some View {
        GeometryReader { geo in
            let box = geo.frame(in: .global)
            let frame =
                scrollClip
                ? kayaTableCellsBox(inScrollClip: box, interior: kayaTableCardInsetX) : box
            Color.clear.task(id: KayaGeometryStamp(generation: generation, frame: frame)) {
                kayaRecordTableViewport(node, generation, frame, synthesized)
            }
        }
    }
}

/// The synthesized tiers' shared geometry rule (docs/tables-plan.md decision 6):
/// a column's content width is its FLOOR, leftover distributes, and the table
/// spans its viewport. Subviews arrive in content order — headers, the divider,
/// then the stamped cells row-major.
private struct KayaTableLayout: Layout {
    let cols: Int
    let colGap: CGFloat
    let rowGap: CGFloat
    /// THE WINDOW'S TWO SPACERS (docs/virtualization-plan.md §4), in the CORE's
    /// arithmetic and never this file's. `windowed` makes a row's slot its PITCH
    /// (§2.1), so the core's `index x pitch` and this placement are one number.
    /// All three are 0/false for the §1 bridge, where the band is every row.
    var windowed = false
    var top: CGFloat = 0
    var bottom: CGFloat = 0
    /// The band index `top` belongs to. It rides the placement so the report
    /// reads the band THIS PASS DREW: mixing a fresh band index with a stale
    /// placement was measured answering row 197 for a viewport parked on 200.
    var first = 0
    /// What this layout PLACED, for the report that follows it, and the
    /// ask for that report.
    var placement: KayaTablePlacement?
    var placed: KayaTablePlaced?

    private func columnWidths(
        _ subviews: Subviews, _ proposal: ProposedViewSize
    ) -> ([CGFloat], CGFloat) {
        var widths = [CGFloat](repeating: 0, count: cols)
        for (i, v) in subviews.prefix(cols).enumerated() {
            widths[i] = max(widths[i], v.sizeThatFits(.unspecified).width)
        }
        for (i, v) in subviews.dropFirst(cols + 1).enumerated() {
            widths[i % cols] = max(widths[i % cols], v.sizeThatFits(.unspecified).width)
        }
        var total = widths.reduce(0, +) + colGap * CGFloat(cols - 1)
        if let bound = proposal.width, bound > total {
            let per = (bound - total) / CGFloat(cols)
            for c in 0..<cols { widths[c] += per }
            total = bound
        }
        return (widths, total)
    }

    private func rowHeights(_ subviews: Subviews) -> (CGFloat, CGFloat, [CGFloat]) {
        let headerH = subviews.prefix(cols)
            .map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        let dividerH = subviews[cols].sizeThatFits(.unspecified).height
        var rows: [CGFloat] = []
        let cells = Array(subviews.dropFirst(cols + 1))
        for start in stride(from: 0, to: cells.count, by: cols) {
            rows.append(
                cells[start..<min(start + cols, cells.count)]
                    .map { $0.sizeThatFits(.unspecified).height }.max() ?? 0)
        }
        return (headerH, dividerH, rows)
    }

    /// The rows' own region. WINDOWED: every row's slot is its pitch, so the
    /// band's height shares the core's unit and the two spacers add up to the
    /// whole collection. UNWINDOWED: the gaps sit BETWEEN the rows.
    private func rowsExtent(_ rows: [CGFloat]) -> CGFloat {
        rows.reduce(0, +) + rowGap * CGFloat(windowed ? rows.count : max(0, rows.count - 1))
    }

    /// The columns' scroll offset, passed in as a VALUE: a Layout is a pure
    /// function, so the view owns the number. Clamped here rather than reset
    /// from here — a write during layout invalidates the pass that made it, and
    /// cost the varied scene two rows of its band (measured 2026-08-29).
    var offsetX: CGFloat = 0

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let (_, total) = columnWidths(subviews, proposal)
        let (headerH, dividerH, rows) = rowHeights(subviews)
        let height =
            headerH + rowGap + dividerH + rowGap + top + rowsExtent(rows) + bottom
        // ACCEPT THE OFFER (docs/tables-plan.md, ruled 2026-08-29): answering
        // `total` past a narrower proposal put a too-wide table outside its
        // parent's box with the columns unreachable. An unspecified width still
        // answers the content, which is the hug.
        return CGSize(width: min(total, proposal.width ?? total), height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let (widths, _) = columnWidths(subviews, proposal)
        let (headerH, dividerH, rows) = rowHeights(subviews)
        var colX = [CGFloat](repeating: 0, count: cols)
        let content = widths.reduce(0, +) + colGap * CGFloat(max(0, cols - 1))
        let reach = max(0, content - bounds.width)
        var acc = bounds.minX - min(offsetX, reach)
        for c in 0..<cols {
            colX[c] = acc
            acc += widths[c] + colGap
        }
        for (i, v) in subviews.prefix(cols).enumerated() {
            v.place(
                at: CGPoint(x: colX[i], y: bounds.minY), anchor: .topLeading,
                proposal: .unspecified)
        }
        let dividerY = bounds.minY + headerH + rowGap
        subviews[cols].place(
            at: CGPoint(x: bounds.minX, y: dividerY), anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: dividerH))
        var y = dividerY + dividerH + rowGap + top
        // What the report reads back: where the band starts inside this
        // content, and the pitch this pass gave each realized row.
        if let placement {
            placement.bandFirst = first
            placement.bandOffset = top
            placement.bandTop = y - bounds.minY
            placement.rowPitches = rows.map { $0 + rowGap }
            // THE COLUMNS' PAIR: what they needed and what the track gave. THE
            // TRACK IS THE CARD'S INTERIOR, not this layout's box — the edge
            // instrument measures against the cells' box, so the outer width
            // said "content 290 in viewport 290" for cells 11pt outside it.
            placement.columnsContent = content
            placement.columnsViewport = max(0, bounds.width - 2 * kayaTableCardInsetX)
            placed?()
        }
        let cells = Array(subviews.dropFirst(cols + 1))
        for (r, rowH) in rows.enumerated() {
            for c in 0..<cols where r * cols + c < cells.count {
                cells[r * cols + c].place(
                    at: CGPoint(x: colX[c], y: y), anchor: .topLeading,
                    proposal: .unspecified)
            }
            y += rowH + rowGap
        }
    }
}

/// THE FINGER IS THIS TIER'S COLUMN SCROLL (docs/tables-plan.md, ruled
/// 2026-08-29). A drag rather than a ScrollView, which proposes an unbounded
/// width and would lose the track leftover distributes across. IT WRITES ONLY
/// FROM THE GESTURE — nothing here runs during layout.
private struct KayaColumnsDrag: ViewModifier {
    @Binding var offset: CGFloat
    let placement: KayaTablePlacement
    @State private var start: CGFloat = 0

    private var reach: CGFloat {
        max(0, placement.columnsContent - placement.columnsViewport)
    }

    func body(content: Content) -> some View {
        content
            .clipped()
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        let limit = reach
                        guard limit > 0 else { return }
                        if value.translation.width == 0 { start = offset }
                        offset = Swift.min(
                            Swift.max(start - value.translation.width, 0), limit)
                    }
                    .onEnded { _ in start = offset })
    }
}

/// Every live SYNTHESIZED table's window, by container widget id — the mac
/// driver's twin (kayaTableDrivers), and how the harness verbs reach the tier
/// that drew. Main thread only, like every other registry here.
nonisolated(unsafe) var kayaTableColumnAxes: [UInt64: KayaSynthesizedWindow] = [:]

nonisolated(unsafe) var kayaTableWindows: [UInt64: KayaSynthesizedWindow] = [:]

/// The scroll container's coordinate space: the content's frame in it IS
/// the scroll offset.
private func kayaTableScrollSpace(_ node: KayaNode) -> String { "kaya-table-\(node.id)" }

/// A row's scroll anchor. Its own type, so an id here cannot collide
/// with the ForEach's own element ids (KayaNode.ID is a UInt64 too).
private struct KayaRowAnchor: Hashable {
    let row: UInt64
    let col: Int
}

/// What KayaTableLayout PLACED, for the report that follows: where the band
/// starts inside the content, and each realized row's pitch. NOT @Observable —
/// written from inside placeSubviews, where a SwiftUI invalidation is fatal.
final class KayaTablePlacement {
    /// The columns' axis (docs/tables-plan.md, ruled 2026-08-29): what they
    /// needed and what the track gave. A PLAIN box, deliberately not
    /// observable — the layout writes it, and observable state written
    /// during layout invalidates the pass that wrote it.
    var columnsContent: CGFloat = 0
    var columnsViewport: CGFloat = 0
    var bandFirst = 0
    var bandOffset: CGFloat = 0
    var bandTop: CGFloat = 0
    var rowPitches: [CGFloat] = []
}

/// What KayaTableLayout tells the window when it has placed a band: ITS OWN
/// TRIGGER, since a scroll never re-runs this layout and a band change need not
/// move the content's box (the spacers keep it as tall as the collection).
typealias KayaTablePlaced = () -> Void

/// THE SYNTHESIZED TIER'S WINDOW (docs/virtualization-plan.md §4): top spacer,
/// the realized band's widgets, bottom spacer, inside the tier's own scroll.
/// THE CORE OWNS THE ARITHMETIC; this object owns the loop that feeds it — the
/// range the viewport shows and the extents the layout gave the band.
@Observable final class KayaSynthesizedWindow {
    /// The two spacers, and whether the core answers for this For at all.
    /// False is §1's bridge: nothing narrowed, every row realized, and
    /// this tier draws exactly what it drew before there was a window.
    var top = 0.0
    var bottom = 0.0
    var windowed = false
    /// The band index `top` is the offset of — it goes to the layout, so
    /// what the layout places and what the report reads back are one
    /// band even while the core's has moved on.
    var first = 0
    /// The collection's declared total — expect_window's second number.
    var total = 0

    @ObservationIgnored let placement = KayaTablePlacement()
    /// THE COLUMNS' SCROLL OFFSET (docs/tables-plan.md, ruled 2026-08-29). On the
    /// window rather than the view's @State because `scroll_end` has to drive it
    /// through kayaTableWindows. Written by the DRAG and that verb, never
    /// during layout.
    var columnsOffset: CGFloat = 0
    @ObservationIgnored private var proxy: ScrollViewProxy?
    /// The scroll container's own box, in the space the harness compares in,
    /// recorded through the ONE writer: a viewport riding only a `task(id:)` is
    /// dropped when the generation churns, which this tier's band does several
    /// times a second while it settles.
    @ObservationIgnored private var viewportRect = CGRect.zero
    @ObservationIgnored private var viewportHeight = 0.0
    @ObservationIgnored private var scrollTop = 0.0
    /// The last range handed to the core. A pass that moved nothing
    /// reports nothing, so the report -> stamp -> layout loop cannot run
    /// away (the mac driver's rule).
    @ObservationIgnored private var reported: (first: Int, count: Int)?
    /// What the last pass MEASURED — the viewport's own first row and how
    /// many rows it shows. expect_window reads the first of these: never
    /// the band's first, and never the park's claim below.
    @ObservationIgnored private(set) var visible: (first: Int, count: Int)?
    /// §2.4's anchor: scroll_to_row parks a ROW and every pass re-parks it
    /// until the viewport's first visible row IS that row. `landedAt` is
    /// the offset the park arrived at, nil while it is still in flight.
    @ObservationIgnored private var anchorRow: Int?
    @ObservationIgnored private var landedAt: Double?
    /// The previous pass's offset and the placement it was read against.
    /// A READER'S SCROLL MOVES THE OFFSET INSIDE A PLACEMENT THAT DID
    /// NOT MOVE; a correction above the viewport moves both, which is
    /// why the offset alone cannot tell them apart (`repark`).
    @ObservationIgnored private var lastScrollTop: Double?
    @ObservationIgnored private var lastPlacement: (top: Double, first: Int)?
    @ObservationIgnored private var scheduled = false
    /// Consecutive passes that found an input missing. BOUNDED because
    /// the re-arm below hops the main queue: a table that never gets
    /// geometry would otherwise spin it forever.
    @ObservationIgnored private var misses = 0

    /// THE COLUMNS' AXIS HAS ITS OWN REGISTRY, and must: an UNGROWN table never
    /// reaches `attach`, and putting it in kayaTableWindows made `expect_window`
    /// read a ROW window it has none of — "0 0" where the core's unwindowed
    /// answer is "0 12" (measured 2026-08-29).
    func registerColumns(_ node: KayaNode) {
        kayaTableColumnAxes[node.id] = self
    }

    /// The scroll container appeared or resized: the viewport this window
    /// is a window ON.
    func attach(_ node: KayaNode, proxy: ScrollViewProxy, viewport: CGRect) {
        kayaTableWindows[node.id] = self
        kayaTableColumnAxes[node.id] = self
        self.proxy = proxy
        viewportRect = viewport
        viewportHeight = Double(viewport.height)
        arrived(node)
    }

    func detach(_ node: KayaNode) {
        if kayaTableWindows[node.id] === self { kayaTableWindows.removeValue(forKey: node.id) }
        if kayaTableColumnAxes[node.id] === self {
            kayaTableColumnAxes.removeValue(forKey: node.id)
        }
    }

    /// The content moved inside the container: a scroll, or a resize.
    func note(_ node: KayaNode, scrollTop: Double) {
        self.scrollTop = scrollTop
        arrived(node)
    }

    /// The layout placed a band. THE THIRD TRIGGER: a scroll does not re-run the
    /// layout, and a band change does not move the content's box. AND THE
    /// REGISTRATION HEALS HERE — a transient duplicate view can attach and die,
    /// taking the registry entry with it (measured 2026-08-30).
    func placed(_ node: KayaNode) {
        if proxy != nil, kayaTableWindows[node.id] == nil {
            kayaTableWindows[node.id] = self
            kayaTableColumnAxes[node.id] = self
        }
        arrived(node)
    }

    /// A real input landed, so the re-arm budget below starts over: it
    /// exists to stop a table with no geometry spinning the main queue,
    /// not to stop a table that keeps being told things.
    private func arrived(_ node: KayaNode) {
        misses = 0
        schedule(node)
    }

    /// One report per main-queue turn, however many readers asked for it.
    /// NEVER INSIDE A LAYOUT PASS, for the reason KayaTablePlacement is
    /// not @Observable.
    private func schedule(_ node: KayaNode) {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.report(node)
        }
    }

    /// THE RANGE LEADS AND THE HEIGHTS FOLLOW (§3.4): the band moves on
    /// what the viewport shows, and the rows it stamped are measured on
    /// the pass after they laid out.
    private func report(_ node: KayaNode) {
        // THE VIEWPORT FIRST, past every early return below: a geometric fact
        // about the container, not the band, which expect_column_edges reads
        // whatever the window is doing. THE CELLS' BOX, not the raw clip —
        // this tier's second viewport writer must report the same box.
        let cells = kayaTableCellsBox(
            inScrollClip: viewportRect, interior: kayaTableCardInsetX)
        kayaTrace("vp#\(node.id) clip=\(Int(viewportRect.width))x\(Int(viewportRect.height)) "
            + "cells=\(Int(cells.width))x\(Int(cells.height))")
        if cells.width > 0, cells.height > 0 {
            kayaRecordTableViewport(
                node, kayaTableGeometryGeneration(node), cells, true)
        }
        guard let geometry = KayaHost.windowGeometry(node.id), geometry.total > 0 else {
            // No core (the gate's probes host this render path with none)
            // or a For it does not know: the bridge.
            publish(windowed: false, top: 0, bottom: 0, first: 0, total: node.children.count)
            visible = nil
            return
        }
        let pitches = placement.rowPitches
        guard viewportHeight > 0, pitches.count == node.children.count else {
            // The other reader has not landed yet, or the layout has not
            // placed this band. Both resolve on the next turn; the budget
            // is what keeps a table that never gets geometry from spinning
            // the main queue, and every real input resets it.
            misses += 1
            if misses < 8 { schedule(node) }
            return
        }
        misses = 0
        let band = Int(geometry.first)..<Int(geometry.first) + Int(geometry.count)
        var spanned = 0.0
        for index in band { spanned += KayaHost.rowExtent(node.id, index) }
        publish(
            windowed: true, top: geometry.offset,
            bottom: max(0, geometry.extent - geometry.offset - spanned),
            first: Int(geometry.first), total: Int(geometry.total))

        // WHERE THE VIEWPORT SITS IN THE BAND THAT WAS DRAWN, all from the SAME
        // layout pass: reading a fresh band index against the drawn placement
        // was measured answering 197 for a viewport parked on 200. The header
        // block is inside `bandTop`.
        let drawnFirst = placement.bandFirst
        let into = scrollTop - Double(placement.bandTop)
        let below = into + viewportHeight
        let span = pitches.reduce(0, +)
        var measured: (first: Int, count: Int)
        if pitches.isEmpty || below <= 0.5 || into >= Double(span) - 0.5 {
            // THE VIEWPORT IS OUTSIDE THE BAND — the reader jumped to rows
            // nothing has stamped, so nothing is measured and nothing claimed:
            // the seek asks the CORE where that offset lands, and the next pass
            // reports what it measures.
            let pitch = geometry.extent / Double(geometry.total)
            let at = Double(placement.bandOffset) + into
            let index = pitch > 0 ? Int((at / pitch).rounded(.down)) : 0
            measured = (min(Int(geometry.total) - 1, max(0, index)), visible?.count ?? 1)
        } else {
            var y = 0.0
            var k = 0
            while k < pitches.count, y + Double(pitches[k]) <= max(0, into) + 0.5 {
                y += Double(pitches[k])
                k += 1
            }
            var count = 0
            while k + count < pitches.count, y < below - 0.5 {
                y += Double(pitches[k + count])
                count += 1
            }
            // THE BAND CAN BE SHORTER THAN THE VIEWPORT: at the first report it
            // is ONE row, so the walk's count is a FLOOR and reporting it alone
            // climbs one doubling at a time — EIGHT generation bumps in 80ms,
            // cancelling every reporter's `task(id:)` (2026-08-25, 2 runs in 11).
            if k + count >= pitches.count, y < below {
                let pitch = Double(geometry.total) > 0 && geometry.extent > 0
                    ? geometry.extent / Double(geometry.total)
                    : Double(pitches.last ?? 0)
                if pitch > 0 { count += Int(((below - y) / pitch).rounded(.up)) }
            }
            measured = (drawnFirst + k, max(1, count))
        }
        visible = measured
        // WHILE A PARK IS IN FLIGHT THE BAND IS HELD WHERE IT IS AIMED, not
        // where the viewport still is: reporting the old place tears down the
        // row the scroll is travelling to, and the park has nothing to land on
        // (measured — the band snapped back to 0 and the scroll stuck).
        var claim = measured
        if let anchor = anchorRow, landedAt == nil { claim = (anchor, measured.count) }
        if reported.map({ $0 != claim }) ?? true {
            reported = claim
            KayaHost.windowMoved(node.id, claim.first, claim.count)
        }
        let placementMoved = lastPlacement.map {
            $0.top != Double(placement.bandTop) || $0.first != drawnFirst
        } ?? true
        let offsetMoved = lastScrollTop.map { abs(scrollTop - $0) > 0.5 } ?? false
        lastPlacement = (Double(placement.bandTop), drawnFirst)
        lastScrollTop = scrollTop
        measure(node, first: drawnFirst, pitches: pitches)
        repark(
            node, drawnFirst: drawnFirst, measured: measured,
            readerScrolled: offsetMoved && !placementMoved)
    }

    /// The verify half (§2.2): the extents this tier laid the band's rows
    /// out at, reported only when they DISAGREE with what the core
    /// already holds — exactly, no tolerance (§2.3), which is also what
    /// stops this round trip repeating.
    private func measure(_ node: KayaNode, first: Int, pitches: [CGFloat]) {
        var heights: [Double] = []
        var moved = false
        for (k, pitch) in pitches.enumerated() {
            let height = Double(pitch)
            heights.append(height)
            if KayaHost.rowExtent(node.id, first + k) != height { moved = true }
        }
        guard moved else { return }
        KayaHost.rowsMeasured(node.id, first, heights)
    }

    /// §2.4, this tier's spelling: a park is re-issued until the row it names IS
    /// the viewport's first visible row, and again whenever that row stops being
    /// first while the reader has not scrolled — which is what a correction
    /// above it looks like. An offset the reader moved cancels the park.
    private func repark(
        _ node: KayaNode, drawnFirst: Int, measured: (first: Int, count: Int),
        readerScrolled: Bool
    ) {
        guard let anchor = anchorRow, let proxy else { return }
        if measured.first == anchor {
            if landedAt == nil { landedAt = scrollTop }
            return
        }
        // ONLY THE READER'S OWN SCROLL CANCELS A PARK: a correction above the
        // viewport moves the offset TOO, and an offset-only test called that a
        // scroll and let the window free-run at 145..147 (measured 2026-08-29,
        // docs/traps.md).
        if landedAt != nil, readerScrolled {
            anchorRow = nil
            landedAt = nil
            return
        }
        landedAt = nil
        guard anchor >= drawnFirst, anchor < drawnFirst + node.children.count else { return }
        proxy.scrollTo(
            KayaRowAnchor(row: node.children[anchor - drawnFirst].id, col: 0), anchor: .top)
    }

    /// scroll_to_row's tier half: park the row and move the band to it.
    /// The row is addressed as DATA — the core already turned the key into
    /// this index — so a row nothing has stamped scrolls exactly like a
    /// realized one.
    func scroll(_ node: KayaNode, toRow index: Int) {
        anchorRow = index
        landedAt = nil
        let count = visible?.count ?? 1
        reported = (index, count)
        KayaHost.windowMoved(node.id, index, count)
        schedule(node)
    }

    /// Observation writes only when a number MOVED: @Observable notifies
    /// on assignment, not on change, and this is read from the body that
    /// draws the spacers.
    private func publish(
        windowed: Bool, top: Double, bottom: Double, first: Int, total: Int
    ) {
        if self.windowed != windowed { self.windowed = windowed }
        if self.top != top { self.top = top }
        if self.bottom != bottom { self.bottom = bottom }
        if self.first != first { self.first = first }
        if self.total != total { self.total = total }
    }
}

/// The grown table's viewport box (§4): it takes the extent it is offered along
/// the scroll axis and claims NONE of its own. A ScrollView answers an
/// UNSPECIFIED height proposal with its CONTENT's (11,362pt for the 400-row
/// scene), which travels up and makes the ROOT as tall as the collection.
private struct KayaScrollBox: Layout {
    var traceId: UInt64 = 0
    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let natural = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        let out = CGSize(width: proposal.width ?? natural.width, height: proposal.height ?? 0)
        kayaTrace("box#\(traceId) size in=\(proposal.width.map { Int($0) } ?? -1)x"
            + "\(proposal.height.map { Int($0) } ?? -1) out=\(Int(out.width))x\(Int(out.height))")
        return out
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        subviews.first?.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// The content's own box inside the scroll container — how far it is
/// scrolled and how tall it is. INSIDE the content on purpose: a reader
/// on the container itself does not move when the reader scrolls.
private struct KayaTableContentReporter: View {
    let node: KayaNode
    let window: KayaSynthesizedWindow
    let generation: Int
    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .named(kayaTableScrollSpace(node)))
            Color.clear.task(id: KayaGeometryStamp(generation: generation, frame: frame)) {
                window.note(node, scrollTop: -Double(frame.minY))
            }
        }
    }
}

/// THE INSET-GROUPED CARD'S NUMBERS, iOS only (ruled 2026-08-25;
/// docs/deferred.md's table-card entry). ZERO ON macOS: the edge instrument
/// subtracts what these say the card spends, so a mac that declared them would
/// convict every mac table.
#if os(macOS)
    let kayaTableCardInsetX: CGFloat = 0
    let kayaTableCardInsetY: CGFloat = 0
#else
    /// UIKit's cell layout margin — and the 16 the mac native tier's inset
    /// NSTableView measured at (kayaTableLeadingUnderfill's note).
    let kayaTableCardInsetX: CGFloat = 16
    /// kaya's 8, as GTK's and Compose's cards: ROW DENSITY MAY NOT MOVE, so
    /// the vertical interior is the container's, never the row's.
    let kayaTableCardInsetY: CGFloat = 8
#endif
/// iOS's inset-grouped section radius.
let kayaTableCardRadius: CGFloat = 10
/// What the card spends per side, and therefore the number the edge instrument
/// takes off the assigned track (kayaTableContentTrack and kayaTableCellsBox
/// read the same interior).
let kayaTableCardPad: CGFloat = kayaTableCardInsetX

/// THE FOLD SEAM (docs/adaptive-layout-plan.md D7): the gap between the last
/// folded child and the table's own grammar. A SECTION gap, not the table's
/// internal spacing — at `node.spacing` the two surfaces read as one card.
let kayaFoldSeamGap: CGFloat = 16

#if !os(macOS)
    /// THE PHONE'S FOLD OF A LABELLED ROW (docs/forms-plan.md §3): label
    /// leading and value trailing when the three fit the width, the value
    /// under the label when they do not. ONE Layout over ONE control: a
    /// ViewThatFits measures a second copy of a bridged control, and that
    /// copy's dismantle empties the harness registry (docs/traps.md).
    struct KayaLabeledFold: Layout {
        let spacing: CGFloat

        struct Plan {
            var stacked: Bool
            var label: CGSize
            var control: CGSize
            var button: CGSize?
            var lineHeight: CGFloat
            var size: CGSize
        }

        func plan(_ proposal: ProposedViewSize, _ subviews: Subviews) -> Plan {
            let label = subviews[0].sizeThatFits(.unspecified)
            let control = subviews[1].sizeThatFits(.unspecified)
            let button = subviews.count > 2 ? subviews[2].sizeThatFits(.unspecified) : nil
            let trailing = button.map { $0.width + spacing } ?? 0
            let rowWidth = label.width + spacing + control.width + trailing
            let rowHeight = max(label.height, control.height, button?.height ?? 0)
            guard let width = proposal.width, width.isFinite, rowWidth > width else {
                let ideal = rowWidth.isFinite ? rowWidth : label.width
                let w = proposal.width.map { $0.isFinite ? $0 : ideal } ?? ideal
                return Plan(
                    stacked: false, label: label, control: control, button: button,
                    lineHeight: rowHeight, size: CGSize(width: w, height: rowHeight))
            }
            let stackedLabel = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let controlWidth = max(0, width - trailing)
            let stackedControl = subviews[1].sizeThatFits(
                ProposedViewSize(width: controlWidth, height: nil))
            let line = max(stackedControl.height, button?.height ?? 0)
            return Plan(
                stacked: true, label: stackedLabel,
                control: CGSize(
                    width: min(stackedControl.width, controlWidth), height: stackedControl.height),
                button: button, lineHeight: line,
                size: CGSize(width: width, height: stackedLabel.height + spacing + line))
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard subviews.count >= 2 else { return .zero }
            return plan(proposal, subviews).size
        }

        func placeSubviews(
            in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
        ) {
            guard subviews.count >= 2 else { return }
            let p = plan(proposal, subviews)
            if p.stacked {
                subviews[0].place(
                    at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
                    proposal: ProposedViewSize(p.label))
                let lineMid = bounds.minY + p.label.height + spacing + p.lineHeight / 2
                subviews[1].place(
                    at: CGPoint(x: bounds.minX, y: lineMid), anchor: .leading,
                    proposal: ProposedViewSize(p.control))
                if let button = p.button {
                    subviews[2].place(
                        at: CGPoint(x: bounds.maxX, y: lineMid), anchor: .trailing,
                        proposal: ProposedViewSize(button))
                }
            } else {
                subviews[0].place(
                    at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                    proposal: ProposedViewSize(p.label))
                var x = bounds.maxX
                if let button = p.button {
                    subviews[2].place(
                        at: CGPoint(x: x, y: bounds.midY), anchor: .trailing,
                        proposal: ProposedViewSize(button))
                    x -= button.width + spacing
                }
                subviews[1].place(
                    at: CGPoint(x: x, y: bounds.midY), anchor: .trailing,
                    proposal: ProposedViewSize(p.control))
            }
        }
    }
#endif

/// THE GRID THAT FITS (docs/layout-knobs-plan.md §3): the column count is
/// a pure function of the proposed width and the floor, every column an
/// equal share of the width, cells centred in their row (R5). It takes the
/// width it is offered, which is what makes it span its parent.
struct KayaAutoGrid: Layout {
    let minWidth: CGFloat
    let spacing: CGFloat

    func columns(for width: CGFloat) -> Int {
        guard width.isFinite, minWidth > 0 else { return 1 }
        return max(1, Int(((width + spacing) / (minWidth + spacing)).rounded(.down)))
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> (cols: Int, share: CGFloat, heights: [CGFloat]) {
        let cols = columns(for: width)
        let share = max(0, (width - spacing * CGFloat(cols - 1)) / CGFloat(cols))
        var heights: [CGFloat] = []
        var i = 0
        while i < subviews.count {
            var rowH: CGFloat = 0
            for c in 0..<cols where i + c < subviews.count {
                rowH = max(
                    rowH,
                    subviews[i + c].sizeThatFits(ProposedViewSize(width: share, height: nil)).height)
            }
            heights.append(rowH)
            i += cols
        }
        return (cols, share, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? (minWidth * CGFloat(subviews.count) + spacing * CGFloat(max(0, subviews.count - 1)))
        let plan = rows(subviews, width: width)
        let height = plan.heights.reduce(0, +) + spacing * CGFloat(max(0, plan.heights.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let plan = rows(subviews, width: bounds.width)
        var y = bounds.minY
        for (r, rowH) in plan.heights.enumerated() {
            for c in 0..<plan.cols {
                let i = r * plan.cols + c
                if i >= subviews.count { break }
                let size = subviews[i].sizeThatFits(ProposedViewSize(width: plan.share, height: nil))
                let x = bounds.minX + CGFloat(c) * (plan.share + spacing)
                subviews[i].place(
                    at: CGPoint(x: x, y: y + (rowH - size.height) / 2), anchor: .topLeading,
                    proposal: ProposedViewSize(width: plan.share, height: size.height))
            }
            y += rowH + spacing
        }
    }
}

/// A ROW THAT FLOWS (docs/layout-knobs-plan.md §2): children at their
/// natural size, leading-aligned, onto a new line when the proposed width
/// runs out, the row's spacing on both axes.
struct KayaFlow: Layout {
    let spacing: CGFloat

    private func lines(_ subviews: Subviews, width: CGFloat) -> [[(Int, CGSize)]] {
        var out: [[(Int, CGSize)]] = []
        var line: [(Int, CGSize)] = []
        var x: CGFloat = 0
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let next = x + (line.isEmpty ? 0 : spacing) + size.width
            if !line.isEmpty, width.isFinite, next > width {
                out.append(line)
                line = []
                x = 0
            }
            x += (line.isEmpty ? 0 : spacing) + size.width
            line.append((i, size))
        }
        if !line.isEmpty { out.append(line) }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        var width: CGFloat = .infinity
        if let offered = proposal.width, offered.isFinite {
            width = offered
        }
        let plan = lines(subviews, width: width)
        var height: CGFloat = 0
        var widest: CGFloat = 0
        for line in plan {
            var lineH: CGFloat = 0
            var lineW: CGFloat = 0
            for (_, size) in line {
                lineH = max(lineH, size.height)
                lineW += size.width
            }
            lineW += spacing * CGFloat(max(0, line.count - 1))
            height += lineH
            widest = max(widest, lineW)
        }
        height += spacing * CGFloat(max(0, plan.count - 1))
        return CGSize(width: width.isFinite ? width : widest, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for line in lines(subviews, width: bounds.width) {
            let lineH = line.map { $0.1.height }.max() ?? 0
            var x = bounds.minX
            for (i, size) in line {
                subviews[i].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += lineH + spacing
        }
    }
}

/// A column of nothing but labelled rows, two or more, is a form
/// (docs/forms-plan.md §2).
func kayaIsForm(_ node: KayaNode) -> Bool {
    let laid = node.laidOut
    return laid.count >= 2 && laid.allSatisfy { $0.kind == kindLabeled }
}

/// Whether this container is a grouped screen's registered primary flow —
/// false on macOS by construction, which keeps the mac lane byte-stable.
func kayaIsGroupedFlow(_ node: KayaNode) -> Bool {
    #if os(macOS)
        return false
    #else
        return kayaScene.groupedFlows.contains(node.id)
    #endif
}

/// THE GROUPED-SCREEN RULE (docs/adaptive-layout-plan.md D7.5): a screen
/// containing a CARRIER — a table, or a form (docs/forms-plan.md §2) — is a
/// grouped screen, whose primary flow is the highest vertical container
/// whose subtree holds one, reached along a SINGLE carrier-bearing child.
/// Two carriers side by side ground but do not section.
func kayaRecomputeGroupedSurfaces() {
    var entries = Set<UInt64>()
    var windows = Set<UInt64>()
    var flows = Set<UInt64>()
    func containsCarrier(_ node: KayaNode) -> Bool {
        if !node.tableColumns.isEmpty || kayaIsForm(node) { return true }
        return node.laidOut.contains(where: containsCarrier)
            || node.foldedChildren.contains(where: containsCarrier)
    }
    func primaryFlow(_ node: KayaNode) -> KayaNode? {
        let vertical = (node.axis ?? (node.kind == kindColumn ? 1 : 0)) == 1
        if vertical, node.kind == kindColumn || node.kind == kindRow,
            node.tableColumns.isEmpty, !kayaIsForm(node)
        {
            return node
        }
        let carriers = node.laidOut.filter(containsCarrier)
        if carriers.count == 1 { return primaryFlow(carriers[0]) }
        return nil
    }
    func register(_ root: KayaNode?, entry: UInt64?, window: UInt64?) {
        guard let root, containsCarrier(root) else { return }
        if let entry { entries.insert(entry) }
        if let window { windows.insert(window) }
        if let flow = primaryFlow(root) { flows.insert(flow.id) }
    }
    for (eid, model) in kayaScene.navEntries {
        register(model.root, entry: eid, window: nil)
    }
    for (wid, model) in kayaScene.windows {
        register(model.root, entry: nil, window: wid)
    }
    register(kayaScene.root, entry: nil, window: 0)
    kayaScene.groupedEntries = entries
    kayaScene.groupedWindows = windows
    kayaScene.groupedFlows = flows
}

/// A section card's interior (the grouped section lowering): the standard
/// grouped-row rhythm, 16 leading like a Settings row and a hair tighter
/// vertically. The header gap is Settings' tight attach.
let kayaFoldSectionPadX: CGFloat = 16
let kayaFoldSectionPadY: CGFloat = 12
let kayaGroupedHeaderGap: CGFloat = 6

/// THE GROUPED SECTION GRAMMAR (docs/adaptive-layout-plan.md D7.5): a heading
/// label opens a section as its header, a caption label closes one as its
/// footer, a table or a form is a body of its own, and every other run of
/// consecutive children is one card. Headers and footers sit bare on the
/// ground.
private struct KayaGroupedSection: Identifiable {
    enum Content {
        case run([KayaNode])
        case table(KayaNode)
        case form(KayaNode)
        case none
    }
    var header: KayaNode?
    var content: Content = .none
    var footer: KayaNode?
    var id: UInt64 {
        if let header { return header.id }
        switch content {
        case .run(let nodes): return nodes[0].id
        case .table(let node), .form(let node): return node.id
        case .none: return footer?.id ?? 0
        }
    }
}

/// Flatten a flow: vertical non-carrier containers dissolve into their
/// children (a For's stamped instance most of all — that is where a
/// row's heading/table/caption triple lives); tables, forms, leaves and
/// horizontal containers are stream members that lay themselves out.
private func kayaGroupedFlatten(_ node: KayaNode, into out: inout [KayaNode]) {
    for child in node.laidOut {
        let vertical = (child.axis ?? (child.kind == kindColumn ? 1 : 0)) == 1
        if vertical, child.kind == kindColumn || child.kind == kindRow,
            child.tableColumns.isEmpty, !kayaIsForm(child), !child.laidOut.isEmpty
        {
            kayaGroupedFlatten(child, into: &out)
        } else {
            out.append(child)
        }
    }
}

private func kayaGroupedSections(_ flow: KayaNode) -> [KayaGroupedSection] {
    var flat: [KayaNode] = []
    kayaGroupedFlatten(flow, into: &flat)
    // A folded LEAF (or an empty container) is its own one-member stream.
    if flat.isEmpty { flat = [flow] }
    var out: [KayaGroupedSection] = []
    var run: [KayaNode] = []
    var header: KayaNode?
    func flush() {
        if header != nil || !run.isEmpty {
            out.append(
                KayaGroupedSection(
                    header: header, content: run.isEmpty ? .none : .run(run)))
            run = []
            header = nil
        }
    }
    for node in flat {
        if !node.tableColumns.isEmpty || kayaIsForm(node) {
            let body: KayaGroupedSection.Content =
                node.tableColumns.isEmpty ? .form(node) : .table(node)
            if run.isEmpty, header != nil {
                out.append(KayaGroupedSection(header: header, content: body))
                header = nil
            } else {
                flush()
                out.append(KayaGroupedSection(content: body))
            }
        } else if node.role == roleHeading {
            flush()
            header = node
        } else if node.role == roleCaption {
            flush()
            if !out.isEmpty, out[out.count - 1].footer == nil {
                out[out.count - 1].footer = node
            } else {
                out.append(KayaGroupedSection(content: .run([node])))
            }
        } else {
            run.append(node)
        }
    }
    flush()
    return out
}

private struct KayaGroupedSections: View {
    let flow: KayaNode

    var body: some View {
        let sections = kayaGroupedSections(flow)
        VStack(alignment: .leading, spacing: kayaFoldSeamGap) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: kayaGroupedHeaderGap) {
                    if let header = section.header {
                        kayaBare(header)
                    }
                    switch section.content {
                    case .table(let table):
                        KayaRender(node: table, flexVertical: true, flexStretch: true)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .background(
                                KayaTrackReader(
                                    id: table.id, vertical: true,
                                    tableGeneration: kayaTableGeometryGeneration(table)))
                    case .form(let form):
                        // The form arm draws its own card (docs/forms-plan.md
                        // §5.1), the same face kayaCarded gives a run.
                        KayaRender(node: form, flexVertical: true, flexStretch: true)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    case .run(let nodes):
                        kayaCarded(nodes)
                    case .none:
                        EmptyView()
                    }
                    if let footer = section.footer {
                        kayaBare(footer)
                    }
                }
            }
        }
    }

    /// A header or footer, bare on the ground in the grouped text style,
    /// aligned with the cards' interior text.
    @ViewBuilder private func kayaBare(_ node: KayaNode) -> some View {
        KayaRender(node: node, flexVertical: true)
            .environment(\.kayaGroupedSectionText, true)
            .padding(.horizontal, kayaFoldSectionPadX)
    }

    /// The card, the FACE's colours and radius on a run of ordinary
    /// content — macOS keeps its flat look exactly as the face does.
    @ViewBuilder private func kayaCarded(_ nodes: [KayaNode]) -> some View {
        let body = VStack(alignment: .leading, spacing: flow.spacing) {
            ForEach(nodes) { child in
                KayaRender(node: child, flexVertical: true, flexStretch: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    // The cross box, so expect_breadth and expect_aligned read
                    // a carded child as they read a flex one.
                    .background(KayaCellReader(id: child.id, parent: flow.id, vertical: true))
            }
        }
        .environment(\.kayaInGroupedCard, true)
        #if os(macOS)
            body
        #else
            body
                .padding(.horizontal, kayaFoldSectionPadX)
                .padding(.vertical, kayaFoldSectionPadY)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(kayaCardShape())
        #endif
    }
}

/// The grouped SCREEN ground (D7's presentation half): the ground is the
/// SCREEN's, edge to edge and behind the title, never a sharp-edged band around
/// the table's region.
private struct KayaGroupedScreenGround: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        #if os(macOS)
            content
        #else
            if on {
                content.background(
                    Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            } else {
                content
            }
        #endif
    }
}

/// Set for a section HEADER or FOOTER render (the grouped section
/// grammar): the label arm answers with the grouped text style —
/// footnote scale, secondary, headers uppercased — which is Settings'
/// own dress for bare text on the ground.
private struct KayaGroupedSectionTextKey: EnvironmentKey {
    static let defaultValue = false
}

/// Set for a carded run's children: the card is the boundary, so a text
/// area inside one draws no border of its own (Reminders' notes field).
private struct KayaInGroupedCardKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var kayaInGroupedCard: Bool {
        get { self[KayaInGroupedCardKey.self] }
        set { self[KayaInGroupedCardKey.self] = newValue }
    }
}

extension EnvironmentValues {
    var kayaGroupedSectionText: Bool {
        get { self[KayaGroupedSectionTextKey.self] }
        set { self[KayaGroupedSectionTextKey.self] = newValue }
    }
}

#if !os(macOS)
    /// THE CARD, one spelling: the face and the fold's section cards
    /// (D7) draw the same rounded surface, and check-table-card holds
    /// the look to exactly one occurrence — a second copy is where a
    /// radius or a colour drifts.
    func kayaCardShape() -> some View {
        RoundedRectangle(cornerRadius: kayaTableCardRadius, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground))
    }
#endif

/// THE CARD ITSELF, and it belongs to the CONTENT (ruled 2026-08-25): as the
/// scroll VIEWPORT's background it ran white to the bottom under a three-row
/// table. The GROUPED CELL background and NO STROKE.
/// tools/check-table-card.py holds the layer as well as the look.
private struct KayaTableCardFace: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
            content
        #else
            content
                .padding(.horizontal, kayaTableCardInsetX)
                .padding(.vertical, kayaTableCardInsetY)
                .background(kayaCardShape())
        #endif
    }
}

/// The synthesized tier (docs/tables-plan.md): kaya's own header over
/// KayaTableLayout's floored-and-distributed columns, for hosts below the native
/// Table's dynamic-column floor and every COMPACT iOS width. Headers render at
/// EVERY width; sorting stays a request the guest answers by re-declaring.
private struct KayaSynthesizedTable: View {
    let node: KayaNode
    @State private var window = KayaSynthesizedWindow()

    private var presented: String {
        var p = node.tableColumns.joined(separator: "|")
        if node.tableSorted != kayaSortNone {
            p += node.tableDirection == 0 ? " ^" : " v"
            p += String(node.tableSorted)
        }
        return p
    }

    private func headerText(_ col: Int, _ title: String) -> String {
        guard node.tableSorted != kayaSortNone, Int(node.tableSorted) == col else { return title }
        return title + (node.tableDirection == 0 ? " ▲" : " ▼")
    }

    private func rows(_ generation: Int) -> some View {
        KayaTableLayout(
            cols: node.tableColumns.count, colGap: 24, rowGap: node.spacing,
            windowed: window.windowed, top: window.top, bottom: window.bottom,
            first: window.first, placement: window.placement,
            placed: { window.placed(node) },
            offsetX: window.columnsOffset
        ) {
            ForEach(Array(node.tableColumns.enumerated()), id: \.offset) { col, title in
                Text(headerText(col, title))
                    .fontWeight(.semibold)
                    .background(
                        KayaEdgeReporter(
                            node: node, key: "h/\(col)", generation: generation))
                    .onTapGesture {
                        KayaHost.emitSortRequested(node.sortTag, UInt32(col))
                    }
            }
            Divider()
            ForEach(node.children) { row in
                ForEach(Array(row.children.enumerated()), id: \.offset) { col, cell in
                    KayaRender(node: cell, flexVertical: false, flexStretch: false)
                        .background(
                            KayaEdgeReporter(
                                node: node, key: kayaTableCellKey(row, col, cell),
                                generation: generation))
                        // The park's target (§2.4): the anchor is column
                        // 0's cell, whose top IS the row's top. Every
                        // cell carries its own so no two share an id.
                        .id(KayaRowAnchor(row: row.id, col: col))
                }
            }
        }
        .modifier(
            KayaColumnsDrag(
                offset: Binding(
                    get: { window.columnsOffset },
                    set: { window.columnsOffset = $0 }),
                placement: window.placement))
    }

    var body: some View {
        let generation = kayaTableGeometryGeneration(node)
        Group {
            if node.grow > 0 {
                // THE SCROLL CONTAINER THIS TIER OWNS (§4): a GROWN table IS
                // the viewport and a window is a window on one, while an UNGROWN
                // one hugs its rows and stays on §1's bridge with every row
                // realized (docs/tables-plan.md, the empty-row ruling).
                KayaScrollBox(traceId: node.id) {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            // THE FOLD (D7): a stacked row's hugging children
                            // render above row 0 and scroll away with the rows,
                            // while the card and reporters stay on the rows —
                            // folded content just shares the scroll.
                            VStack(alignment: .leading, spacing: 0) {
                                if !node.foldedChildren.isEmpty {
                                    // The seam is the folded side's: a section
                                    // gap under the last folded child, so the
                                    // two read as separate surfaces. One
                                    // renderer for both streams.
                                    VStack(alignment: .leading, spacing: kayaFoldSeamGap) {
                                        ForEach(node.foldedChildren) { folded in
                                            KayaGroupedSections(flow: folded)
                                        }
                                    }
                                    .padding(.bottom, kayaFoldSeamGap)
                                }
                                rows(generation)
                                    .background(
                                        KayaTableContentReporter(
                                            node: node, window: window, generation: generation))
                                    // THE CARD IS CONTENT, inside the clip: it
                                    // ends with the last row and scrolls with
                                    // them. Under the content reporter, whose
                                    // box must stay the LAYOUT's own.
                                    .modifier(KayaTableCardFace())
                            }
                        }
                        .coordinateSpace(name: kayaTableScrollSpace(node))
                        .background(
                            KayaTableViewportReporter(
                                node: node, generation: generation, synthesized: true,
                                scrollClip: true))
                        .background(
                            GeometryReader { geo in
                                let box = geo.frame(in: .global)
                                Color.clear.task(id: box) {
                                    window.attach(node, proxy: proxy, viewport: box)
                                }
                            })
                    }
                }
                // EVERY BATCH ASKS FOR A REPORT — and onChange, not a
                // task: a task is cancelled and restarted by the next
                // generation, and the band settling moves the generation
                // several times inside one frame.
                .onChange(of: generation) { window.placed(node) }
            } else {
                // No clip here: the rows ARE the content, so the face hugs
                // them exactly as it hugs a short scrolled table's.
                rows(generation)
                    .background(
                        KayaTableViewportReporter(
                            node: node, generation: generation, synthesized: true))
                    .modifier(KayaTableCardFace())
                    .onAppear { window.registerColumns(node) }
            }
        }
        // task(id:), not onChange: this tier compiles at the macOS 13 /
        // iOS 16 floor, below the zero-parameter onChange.
        .task(id: presented) { node.tablePresented = presented }
        .onDisappear { window.detach(node) }
    }
}

struct KayaFlex: Layout {
    let vertical: Bool
    let spacing: CGFloat
    /// Parallel to `subviews`, in the same order — the weights live on
    /// the model, not on the views.
    let nodes: [KayaNode]
    /// Whether to fill the cross axis as well as the main one. True only for
    /// the mounted root, which fills its window the way AppKit's contentView
    /// and UIKit's root view do. Nested containers hug their cross axis: a row
    /// is as tall as its tallest child, not as tall as its column.
    var fillCross = false

    private func main(_ size: CGSize) -> CGFloat { vertical ? size.height : size.width }
    private func cross(_ size: CGSize) -> CGFloat { vertical ? size.width : size.height }

    /// The cross extent this container was actually offered, or nil when
    /// the proposal leaves it open (SwiftUI's natural-size passes do).
    static func offeredCross(_ proposal: ProposedViewSize, vertical: Bool) -> CGFloat? {
        guard let v = vertical ? proposal.width : proposal.height,
            v.isFinite, v > 0
        else { return nil }
        return v
    }

    /// What to ask a child: the cross we were offered, main left open so
    /// the child still reports what it wants along the stack's axis.
    static func bounded(_ proposal: ProposedViewSize, vertical: Bool) -> ProposedViewSize {
        guard let offered = offeredCross(proposal, vertical: vertical) else {
            return .unspecified
        }
        return vertical
            ? ProposedViewSize(width: offered, height: nil)
            : ProposedViewSize(width: nil, height: offered)
    }

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        // THE OFFERED CROSS BOUNDS THE MEASUREMENT (ruled 2026-08-29): a child
        // asked with `.unspecified` answers its whole text on one line, so a
        // container hung off the screen and left a grown sibling a negative
        // track. It is also what makes wrapping possible (docs/traps.md).
        let childProposal = Self.bounded(proposal, vertical: vertical)
        let natural = subviews.map { $0.sizeThatFits(childProposal) }
        let gaps = spacing * CGFloat(max(0, subviews.count - 1))
        let naturalMain = natural.map { main($0) }.reduce(0, +) + gaps
        let naturalCross = natural.map { cross($0) }.max() ?? 0
        // Fill the MAIN axis from the proposal — what creates the free space the
        // growers divide — and hug the cross axis unless [fillCross]: filling it
        // unconditionally made a row claim its column's whole height. THE
        // FALLBACK IS PER-AXIS, or a natural-size pass is poisoned.
        let fallback = vertical
            ? CGSize(width: naturalCross, height: naturalMain)
            : CGSize(width: naturalMain, height: naturalCross)
        let extent = proposal.replacingUnspecifiedDimensions(by: fallback)
        let filledMain = vertical ? extent.height : extent.width
        let filledCross = vertical ? extent.width : extent.height
        // NEVER WIDER THAN WE WERE OFFERED. A hugging container still hugs
        // — it just cannot answer with more than it was given.
        let crossExtent: CGFloat
        if let offered = Self.offeredCross(proposal, vertical: vertical) {
            crossExtent = fillCross ? offered : min(naturalCross, offered)
        } else {
            crossExtent = fillCross ? max(naturalCross, filledCross) : naturalCross
        }
        return vertical
            ? CGSize(width: crossExtent, height: filledMain)
            : CGSize(width: filledMain, height: crossExtent)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        guard !subviews.isEmpty else { return }
        let gaps = spacing * CGFloat(subviews.count - 1)
        // A grower's natural size is deliberately not consulted: the contract is
        // flex-basis 0. MEASURED AGAINST THE BOX WE ARE PLACING INTO — a wrapped
        // label's height depends on the width it gets, so `.unspecified` here
        // lays every line after the first outside the container.
        let childProposal = Self.bounded(
            ProposedViewSize(bounds.size), vertical: vertical)
        var extents = subviews.indices.map { i -> CGFloat in
            weight(i) > 0 ? 0 : main(subviews[i].sizeThatFits(childProposal))
        }
        let fixed = extents.reduce(0, +)
        let leftover = max(0, main(bounds.size) - fixed - gaps)
        let pool = subviews.indices.map { weight($0) }.reduce(0, +)
        if pool > 0 {
            let growers = subviews.indices.filter { weight($0) > 0 }
            var spent: CGFloat = 0
            for (n, i) in growers.enumerated() {
                if n == growers.count - 1 {
                    // The last grower absorbs the rounding dust so the
                    // children fill the container exactly.
                    extents[i] = leftover - spent
                } else {
                    let share = (leftover * CGFloat(weight(i) / pool)).rounded()
                    extents[i] = share
                    spent += share
                }
            }
        }

        kayaTrace("flex v=\(vertical) bounds=\(Int(bounds.width))x\(Int(bounds.height)) "
            + "ids=\(nodes.map { $0.id }) grow=\(nodes.map { $0.grow }) "
            + "extents=\(extents.map { Int($0) })")
        var offset: CGFloat = 0
        for i in subviews.indices {
            let extent = extents[i]
            let origin =
                vertical
                ? CGPoint(x: bounds.minX, y: bounds.minY + offset)
                : CGPoint(x: bounds.minX + offset, y: bounds.minY)
            // The cross axis is offered the container's full extent and the
            // child decides: a nested container fills it, a label keeps its
            // intrinsic width. That reproduces the stack behaviour the other
            // backends have natively.
            let sized =
                vertical
                ? ProposedViewSize(width: bounds.width, height: extent)
                : ProposedViewSize(width: extent, height: bounds.height)
            subviews[i].place(at: origin, anchor: .topLeading, proposal: sized)
            offset += extent + spacing
        }
    }

    private func weight(_ i: Int) -> Double {
        i < nodes.count ? nodes[i].grow : 0
    }
}

/// The align enum onto SwiftUI's stack alignments. Baseline maps only on rows
/// (the scene core rejects it on columns); a flex row renders baseline as
/// firstTextBaseline placement inside each track frame.
func kayaColumnAlignment(_ mode: Int64) -> HorizontalAlignment {
    switch mode {
    case alignCenter: return .center
    case alignEnd: return .trailing
    default: return .leading
    }
}

func kayaRowAlignment(_ mode: Int64) -> VerticalAlignment {
    switch mode {
    case alignCenter: return .center
    case alignEnd: return .bottom
    case alignBaseline: return .firstTextBaseline
    default: return .top
    }
}

/// The padding container's OUTER size (before the window inset is taken), the
/// other half of the measured-inset observation.
@MainActor var kayaOuterSize: CGSize = .zero

/// The brand tint for the CURRENT appearance, or nil for "no request". A
/// DECLARED BRAND WINS ON EVERY PLATFORM (docs/styling-plan.md D2): `.tint()` is
/// an explicit environment value the system does not arbitrate. A BRANDLESS app
/// still gets the user's accent, since nil is the environment default.
private func kayaBrandTint() -> Color? {
    guard let brand = kayaScene.brand else { return nil }
    #if os(macOS)
        let dark =
            NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    #else
        let dark = UITraitCollection.current.userInterfaceStyle == .dark
    #endif
    // Wire order: seed, light[fill,on,standalone,hover,pressed], dark[...].
    let fill = dark ? brand[6] : brand[1]
    return Color(
        red: Double((fill >> 16) & 0xFF) / 255.0,
        green: Double((fill >> 8) & 0xFF) / 255.0,
        blue: Double(fill & 0xFF) / 255.0)
}

// --- THE BRAND TYPEFACE (docs/styling-plan.md Slice 2b) --------------
// `preferredFont(forTextStyle:)`'s descriptor plus `withFamily` IS A SILENT
// NO-OP on both Apple platforms (measured, 0.0000 differing pixels): what works
// is a FRESH descriptor with the family plus the ramp's own weight.

#if os(macOS)
    typealias KayaPlatformFont = NSFont
    typealias KayaPlatformTextStyle = NSFont.TextStyle
    typealias KayaPlatformFontDescriptor = NSFontDescriptor
#else
    typealias KayaPlatformFont = UIFont
    typealias KayaPlatformTextStyle = UIFont.TextStyle
    typealias KayaPlatformFontDescriptor = UIFontDescriptor
#endif

/// Is this family installed on THIS device? ONE GATE FOR BOTH APPLE PLATFORMS:
/// `NSFont(descriptor:size:)` returns nil where `UIFont(descriptor:size:)` is
/// NON-OPTIONAL and hands back Helvetica (measured), so
/// CTFontDescriptorCreateMatchingFontDescriptor goes in FRONT of the swap.
func kayaFamilyPresent(_ family: String) -> Bool {
    let wanted = CTFontDescriptorCreateWithAttributes(
        [kCTFontFamilyNameAttribute: family as CFString] as CFDictionary)
    let mandatory = NSSet(array: [kCTFontFamilyNameAttribute]) as CFSet
    return CTFontDescriptorCreateMatchingFontDescriptor(wanted, mandatory) != nil
}

/// The platform's ramp for `style`, with the family swapped and nothing
/// else touched. nil when no typeface is in force.
@MainActor func kayaPlatformFont(_ style: KayaPlatformTextStyle) -> KayaPlatformFont? {
    guard let family = kayaScene.typefaceFamily else { return nil }
    // The ramp: this platform's own pointSize and weight for the style.
    // macOS's .headline is 13pt/0.40, iOS's is 17pt/0.30 — the two ramps
    // differ in every row, which is why the design substitutes the family and
    // leaves the scale alone.
    #if os(macOS)
        let base = NSFont.preferredFont(forTextStyle: style)
    #else
        // The UNSCALED base — the size at content-size category .large —
        // because UIFontMetrics scales from there. Feeding it an
        // already-scaled size would apply Dynamic Type twice.
        let base = UIFont.preferredFont(
            forTextStyle: style,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
    #endif
    let traits =
        base.fontDescriptor.object(forKey: .traits)
        as? [KayaPlatformFontDescriptor.TraitKey: Any]
    var weight = (traits?[.weight] as? NSNumber)?.doubleValue ?? 0
    #if !os(macOS)
        // BOLD TEXT, CORRECTED — the one accessibility affordance a family swap
        // silently drops: the system font moves Regular -> Semibold and a
        // substituted family does not move at all (measured). macOS has no Bold
        // Text switch, hence the platform conditional.
        if UITraitCollection.current.legibilityWeight == .bold {
            weight += 0.30
        }
    #endif
    let descriptor = KayaPlatformFontDescriptor(fontAttributes: [
        .family: family,
        .traits: [KayaPlatformFontDescriptor.TraitKey.weight: weight],
    ])
    #if os(macOS)
        return NSFont(descriptor: descriptor, size: base.pointSize)
    #else
        let substituted = UIFont(descriptor: descriptor, size: base.pointSize)
        // Dynamic Type: macOS has none (per Apple DTS), and on iOS the raw
        // substituted font does NOT scale without UIFontMetrics. The swapped
        // ramp tracks the system's without matching it (53pt vs 48pt at
        // accessibilityXXXL), inherent to substituting a family.
        return UIFontMetrics(forTextStyle: style).scaledFont(for: substituted)
    #endif
}

/// The same font as SwiftUI's own type, or nil to leave the platform's in
/// place. `nil` is what a brandless app gets everywhere.
@MainActor func kayaBrandFont(_ style: KayaPlatformTextStyle = .body) -> Font? {
    guard let font = kayaPlatformFont(style) else { return nil }
    return Font(font as CTFont)
}

/// Register a font file's bytes with this process's font manager and return the
/// FAMILY NAME the registration produced. IN-PROCESS SCOPE: kaya never installs
/// anything on a user's machine, and afterwards the family is present exactly as
/// a system-supplied one is (Slice 2b's register-then-resolve).
func kayaRegisterFont(_ bytes: Data) -> String? {
    guard
        let descriptors = CTFontManagerCreateFontDescriptorsFromData(bytes as CFData)
            as? [CTFontDescriptor],
        let first = descriptors.first
    else {
        return nil
    }
    // Enabled at register, since the typeface applies before the first mount;
    // the call's own verdict is not consulted, the presence gate asking CoreText
    // instead. FILE-BACKED ON PURPOSE, measured 2026-08-16: descriptors from
    // DATA carry no URL and registered none of a variable font's instances.
    let dir = FileManager.default.temporaryDirectory
    let url = dir.appendingPathComponent("kaya-brand-font-\(ProcessInfo.processInfo.processIdentifier).ttf")
    do {
        try bytes.write(to: url)
    } catch {
        kayaDiag("typeface blob could not be staged for registration: \(error)")
        return nil
    }
    var cfError: Unmanaged<CFError>?
    if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &cfError) {
        kayaDiag(
            "typeface blob registration failed: "
                + String(describing: cfError?.takeRetainedValue()))
        return nil
    }
    return CTFontDescriptorCopyAttribute(first, kCTFontFamilyNameAttribute) as? String
}

/// THE HONEST READ, for `expect_typeface`: the family the TEXT SYSTEM ended up
/// with, off the real views, NEVER THE MODEL OR THE REQUEST. THE VIEWS MUST
/// AGREE. A BUTTON IS READ AT THE BUTTON, NOT AT ITS TITLE VIEW (measured),
/// except NSPopUpButton, whose swap rides the option `Text`.
@MainActor func kayaResolvedTypeface() -> String {
    var families: Set<String> = []
    // The same reads keyed by the VIEW CLASS, for the disagreement sentence
    // alone. A bare list of families says two things resolved differently; this
    // says WHICH view kept the system font, which is the difference between
    // "the lowering is missing" and "one route into it is".
    var byClass: Set<String> = []
    #if os(macOS)
        func walk(_ view: NSView) {
            var seen: String?
            if view is NSPopUpButton {
                // Read nothing here and nothing under it — see the note.
                return
            } else if let button = view as? NSButton {
                seen = button.font?.familyName ?? "<no family>"
                if let family = seen {
                    families.insert(family)
                    byClass.insert("\(type(of: view))=\(family)")
                }
                // NOT into its subviews: the title view's font is AppKit's own
                // bookkeeping, measured to disagree with what the title renders.
                return
            } else if let text = view as? NSTextView, let font = text.font {
                seen = font.familyName ?? "<no family>"
            } else if let field = view as? NSTextField, let font = field.font {
                seen = font.familyName ?? "<no family>"
            }
            if let family = seen {
                families.insert(family)
                byClass.insert("\(type(of: view))=\(family)")
            }
            for sub in view.subviews { walk(sub) }
        }
        // The CONTENT view, not the window: the titlebar's own controls are
        // not the scene's.
        for window in kayaNSWindows.values {
            if let content = window.contentView { walk(content) }
        }
    #else
        func walk(_ view: UIView) {
            var seen: String?
            if let text = view as? UITextView, let font = text.font {
                seen = font.familyName
            } else if let field = view as? UITextField, let font = field.font {
                seen = font.familyName
            }
            if let family = seen {
                families.insert(family)
                byClass.insert("\(type(of: view))=\(family)")
            }
            for sub in view.subviews { walk(sub) }
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows { walk(window) }
        }
    #endif
    if families.isEmpty {
        // A REAL ANSWER, not an empty string: no text view is on screen to
        // read, which is a different thing from a font that failed to apply.
        return "no text view on screen"
    }
    if families.count > 1 {
        return "views disagree: " + byClass.sorted().joined(separator: ", ")
    }
    return families.first!
}

// ---- The app identity ---------------------------------------------
//
// ONE DECLARATION, TWO ROUTES (docs/app-identity-plan.md), measured: macOS hands
// the picture to the Dock at runtime, iOS's identity is the BUNDLE's.

/// A window's EFFECTIVE caption: its own title, or the declared app identity's
/// NAME when it declared none — FILLING THE BLANK, NEVER OVERRIDING
/// (tools/scenes/identity.steps). A WINDOW THAT DOES NOT EXIST HAS NO CAPTION:
/// without that guard `expect_title window#1` PASSED on iOS.
func kayaWindowCaption(_ windowId: UInt64) -> String {
    guard let own = kayaScene.windows[windowId]?.title else { return "" }
    guard own.isEmpty, let name = kayaScene.appIdentityName, !name.isEmpty else {
        return own
    }
    return name
}

/// Where each canvas landed, in SwiftUI's global (window) space, and on macOS
/// corrected at read time from the AX client's independent answer: a recorded
/// frame can outlive the layout that produced it (kayaCanvasLiveResolve).
@MainActor var kayaCanvasFrames: [UInt64: CGRect] = [:]

/// THE PLATFORM'S FRAME DRIVE, outside the harness (docs/canvas-plan.md §15.4).
/// The tick carries the frame's date, since a clock read inside the callback
/// re-imports the jitter `targetTimestamp` removes. NOT UNDER THE HARNESS, and
/// ONE PER CANVAS — `kaya_frame` is monotone, so later canvases cost a compare.
private struct KayaCanvasTicker: View {
    var body: some View {
        TimelineView(.animation) { context in
            Color.clear.onChange(of: context.date) { _, date in
                KayaHost.frame(date.timeIntervalSinceReferenceDate)
            }
        }
    }
}

private let kayaHarnessDrivesFrames =
    ProcessInfo.processInfo.environment["KAYA_SELFTEST"] != nil

/// The canvas arm's geometry reader, so `expect_ink` finds the canvas ON THE
/// REAL SURFACE; it ALSO reports the track to the core (docs/canvas-plan.md
/// §3.2.1). ONE READER, BOTH JOBS: the ink sample and the raster size come from
/// one frame, and kayaCanvasLiveResolve corrects BOTH when it goes stale.
private struct KayaCanvasReader: View {
    let id: UInt64

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            Color.clear
                .onAppear {
                    kayaCanvasFrames[id] = frame
                    KayaHost.canvasTrack(id, frame.size)
                }
                .onChange(of: frame) { _, f in
                    kayaCanvasFrames[id] = f
                    KayaHost.canvasTrack(id, f.size)
                }
        }
    }
}

#if os(macOS)
    /// The recorded frame can outlive the layout that produced it (measured
    /// 2026-08-28, docs/traps.md), so the check is a SECOND, INDEPENDENT
    /// measurement: the AX client's answer for the canvas's identifier, which
    /// rides OUTSIDE the grow frame and is therefore the TRACK.
    @MainActor func kayaCanvasLiveResolve(_ node: KayaNode) {
        guard !node.a11yId.isEmpty,
            let window = NSApp.windows.first(where: { $0.isVisible }),
            let content = window.contentView,
            let live = kayaAxCanvasFrame(node.a11yId, window, content)
        else { return }
        if ProcessInfo.processInfo.environment["KAYA_AX_TRACE"] != nil {
            FileHandle.standardError.write(
                Data(
                    "KAYA_AX_TRACE: canvas \(node.a11yId) stored=\(String(describing: kayaCanvasFrames[node.id])) live=\(live)\n"
                        .utf8))
        }
        if let stored = kayaCanvasFrames[node.id],
            abs(stored.minX - live.minX) <= 1, abs(stored.minY - live.minY) <= 1,
            abs(stored.width - live.width) <= 1, abs(stored.height - live.height) <= 1
        {
            return
        }
        kayaCanvasFrames[node.id] = live
        KayaHost.canvasTrack(node.id, live.size)
    }

    /// The canvas's live frame in SwiftUI's global (window content, y-down)
    /// space, or nil when the AX tree cannot answer UNAMBIGUOUSLY — refused for
    /// kayaAxReadOnMain's reason, and a nil leaves the stored frame in charge.
    @MainActor private func kayaAxCanvasFrame(
        _ identifier: String, _ window: NSWindow, _ content: NSView
    ) -> CGRect? {
        // Create + bound + announce: kayaAxReadOnMain's discipline (the
        // measured reasons live on its comments; kayaPanelAxApp is the
        // other copy).
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 2.0)
        if !kayaAxAnnounced {
            kayaAxAnnounced = true
            AXUIElementSetAttributeValue(
                app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(
                app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        var matches: [AXUIElement] = []
        kayaAxFindAll(app, identifier, 0, &matches)
        guard matches.count == 1, let hit = matches.first,
            let posRef = kayaAxCopy(hit, kAXPositionAttribute),
            let sizeRef = kayaAxCopy(hit, kAXSizeAttribute),
            CFGetTypeID(posRef) == AXValueGetTypeID(),
            CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &p),
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &s),
            s.width > 1, s.height > 1
        else { return nil }
        // AX speaks the primary screen's top-left-origin y-down space;
        // Cocoa's screen space is bottom-left y-up on the same screen.
        guard let primary = NSScreen.screens.first else { return nil }
        let cocoa = NSRect(
            x: p.x, y: primary.frame.maxY - p.y - s.height, width: s.width, height: s.height)
        let inContent = content.convert(window.convertFromScreen(cocoa), from: nil)
        let y = content.isFlipped ? inContent.minY : content.bounds.height - inContent.maxY
        return CGRect(x: inContent.minX, y: y, width: inContent.width, height: inContent.height)
    }
#endif

/// `expect_ink` compares WITHIN ±1 PER CHANNEL (ruled 2026-08-26,
/// docs/canvas-plan.md §7.2): a macOS window's backing store carries the
/// DISPLAY's profile, so the core's D2E3F7 samples back as D2E2F7 while Android
/// reports the core's own bytes. tools/check-verbs.py pins all three copies.
let kayaInkTolerance = 1

/// The half of a PER-MODE expectation that names `mode`, out of
/// `"light FFFFFF/D2E3F7 dark 16181C/2B3B4F"` (docs/canvas-plan.md §7.2). ONE
/// SPELLING CARRYING BOTH MODES keeps a frozen ink expectation from depending on
/// the host's appearance; harness.rs and KayaCompose.kt carry the other copies.
func kayaInkForMode(_ want: String, _ mode: Substring) -> Substring? {
    let words = want.split(separator: " ")
    var i = 0
    while i + 1 < words.count {
        if words[i] == mode { return words[i + 1] }
        i += 2
    }
    return nil
}

/// The reported mode's colours, every channel within `kayaInkTolerance`.
/// An answer that does not parse — every `<...>` diagnostic below — never
/// matches, so it reaches the failure text whole.
func kayaInkMatches(_ got: String, _ want: String) -> Bool {
    func channels(_ hex: Substring) -> [Int]? {
        guard hex.count == 6 else { return nil }
        var out: [Int] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let v = Int(hex[i ..< j], radix: 16) else { return nil }
            out.append(v)
            i = j
        }
        return out
    }
    let gotParts = got.split(separator: " ", maxSplits: 1)
    guard gotParts.count == 2, let wanted = kayaInkForMode(want, gotParts[0]) else {
        return false
    }
    let gotInk = gotParts[1].split(separator: "/")
    let wantInk = wanted.split(separator: "/")
    guard gotInk.count == wantInk.count else { return false }
    for (g, w) in zip(gotInk, wantInk) {
        guard let g = channels(g), let w = channels(w) else { return false }
        for (a, b) in zip(g, w) where abs(a - b) > kayaInkTolerance { return false }
    }
    return true
}

/// Sample `points` — `x,y` pairs in hundredths of the canvas's own box — off THE
/// WINDOW'S OWN RENDERED PIXELS: the only canvas read that fails when the blit
/// dropped (docs/canvas-plan.md §7.2). Every angle-bracketed answer below says
/// what it MEASURED, never which layer lost the picture.
@MainActor func kayaCanvasInk(_ node: KayaNode, _ points: String) -> String {
    // THE APPEARANCE RIDES THE ANSWER, because the raster uses the platform's
    // mode and kaya's palette has two (§6): a bare colour string would be a
    // frozen expectation depending on the machine's appearance, failing on a
    // dark host with a mismatch that names no cause.
    let mode = kayaCanvasAppearance()
    let wanted = points.split(separator: " ").compactMap { pair -> (Double, Double)? in
        let xy = pair.split(separator: ",")
        guard xy.count == 2, let x = Double(xy[0]), let y = Double(xy[1]) else { return nil }
        return (x, y)
    }
    guard !wanted.isEmpty else { return "<no probe points in \(points)>" }
    #if os(macOS)
        // The stored frame is corrected from the live AX read first —
        // kayaCanvasLiveResolve's comment carries why a stored rectangle
        // cannot be trusted at read time (docs/traps.md).
        kayaCanvasLiveResolve(node)
    #endif
    guard let frame = kayaCanvasFrames[node.id], frame.width > 1, frame.height > 1 else {
        return "<the canvas laid out at \(kayaCanvasFrames[node.id].map(String.init(describing:)) ?? "no recorded frame")>"
    }
    #if os(macOS)
        guard let window = NSApp.windows.first(where: { $0.isVisible }),
            let content = window.contentView
        else { return "<no visible window: \(NSApp.windows.count) windows exist>" }
        // SwiftUI's global space is the window's content with y DOWN, while an
        // AppKit view's own is y-down only when flipped. Both are asked rather
        // than assumed: a wrong answer reads a different part of the window and
        // looks exactly like a lowering bug.
        let y = content.isFlipped ? frame.minY : content.bounds.height - frame.maxY
        let rect = CGRect(x: frame.minX, y: y, width: frame.width, height: frame.height)
        guard let rep = content.bitmapImageRepForCachingDisplay(in: rect) else {
            return "<AppKit made no bitmap for \(rect) of a \(content.bounds.size) view>"
        }
        content.cacheDisplay(in: rect, to: rep)
        guard let cg = rep.cgImage else {
            return "<the cached bitmap carried no image for \(rect)>"
        }
    #else
        let renderer = ImageRenderer(content: KayaRender(node: node))
        renderer.scale = node.drawingScale
        guard let cg = renderer.cgImage else {
            return "<the renderer produced no image for a \(frame.size) canvas>"
        }
    #endif
    return "\(mode) " + kayaSampleRGB(cg, wanted)
}

/// Which palette the core last rastered with. A SECOND READING, and it has to
/// be: `KayaPresentationReporter` reports SwiftUI's `\.colorScheme`, which only
/// a view can read, while this runs off the harness thread. MEASURED AGREEING
/// 2026-08-27; the raster's own mode is the one in `kaya_presentation`.
@MainActor func kayaCanvasAppearance() -> String {
    #if os(macOS)
        // APP SCOPE ON BOTH SIDES, which is why this one cannot drift: the
        // override sets `NSApp.appearance` and this reads
        // `NSApp.effectiveAppearance`, which returns it.
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    #else
        // NOT `UITraitCollection.current`: THE READ'S SCOPE MUST MATCH THE
        // OVERRIDE'S, per-WINDOW here, while `.current` on the harness thread
        // reported the SYSTEM's light against the raster's dark (ios lane
        // 2026-08-27; tools/check-appearance.py).
        guard let window = kayaHarnessWindow() else {
            return "<no window to read an appearance from>"
        }
        let dark = window.traitCollection.userInterfaceStyle == .dark
    #endif
    return dark ? "dark" : "light"
}

#if !os(macOS)
    /// The window the ink verb's pixels belong to: the key window, or the first
    /// window of the first scene when nothing is key. Returning nil rather than
    /// guessing is deliberate — the caller turns it into a bracketed answer that
    /// fails loudly, where a silent "light" would be the defect this replaced.
    @MainActor func kayaHarnessWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let key = scene.windows.first(where: { $0.isKeyWindow }) { return key }
        }
        return scenes.first?.windows.first
    }
#endif

/// `KAYA_APPEARANCE=light|dark`, the harness's per-process appearance. UNSET
/// RETURNS nil AND NOTHING IS INSTALLED (tools/check-appearance.py's inert
/// clause). A value that is neither word dies here naming both spellings: a
/// silently ignored typo would run the whole leg under the wrong palette.
func kayaAppearanceOverride() -> String? {
    guard let want = ProcessInfo.processInfo.environment["KAYA_APPEARANCE"] else { return nil }
    guard want == "light" || want == "dark" else {
        fatalError("kaya: KAYA_APPEARANCE=\(want) is not a mode; use light or dark")
    }
    return want
}

/// Installs that override on the PLATFORM's own appearance. NOT
/// `.preferredColorScheme`, which moves one of kaya's two readings while
/// `NSApp.effectiveAppearance` answers the host's. `-AppleInterfaceStyle Dark`
/// does NOT reach this stack (docs/measurements/canvas-palette-look-2026-08-27.txt).
@MainActor func kayaApplyAppearanceOverride() {
    guard let mode = kayaAppearanceOverride() else { return }
    #if os(macOS)
        NSApp.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
    #else
        let style: UIUserInterfaceStyle = mode == "dark" ? .dark : .light
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { window.overrideUserInterfaceStyle = style }
        }
    #endif
}

/// kayaIconQuadrants' sampler with the probe points named rather than fixed at
/// the quadrant centres. THE 16-BIT CONTEXT AND THE SINGLE ROUND ARE THE
/// MEASURED PART: an 8-bit context quantizes twice (2026-08-18).
func kayaSampleRGB(_ image: CGImage, _ points: [(Double, Double)]) -> String {
    let width = image.width, height = image.height
    guard width > 1, height > 1 else { return "<a \(width)x\(height) surface>" }
    var pixels = [UInt16](repeating: 0, count: width * height * 4)
    let drawn: Bool = pixels.withUnsafeMutableBufferPointer { buf -> Bool in
        guard
            let ctx = CGContext(
                data: buf.baseAddress, width: width, height: height,
                bitsPerComponent: 16, bytesPerRow: width * 8,
                space: CGColorSpace(name: CGColorSpace.sRGB)
                    ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                    | CGBitmapInfo.byteOrder16Little.rawValue)
        else { return false }
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { return "<no bitmap context for a \(width)x\(height) surface>" }
    return points.map { (px, py) -> String in
        let x = min(max(Int(Double(width) * px / 100.0), 0), width - 1)
        let y = min(max(Int(Double(height) * py / 100.0), 0), height - 1)
        let at = (y * width + x) * 4
        func byte(_ v: UInt16) -> Int { Int((Double(v) / 65535.0 * 255.0).rounded()) }
        return String(
            format: "%02X%02X%02X",
            byte(pixels[at]), byte(pixels[at + 1]), byte(pixels[at + 2]))
    }
    .joined(separator: "/")
}

/// The four quadrant CENTRES of a decoded picture. THE CONTRACT IS THE WINUI
/// ARM'S, VERBATIM (crates/kaya/src/winui/mod.rs's `icon_quadrants`) — centres,
/// not corners. SIXTEEN BITS PER COMPONENT, MEASURED 2026-08-18: an 8-bit
/// context quantizes the DISPLAY-profile read-back twice.
func kayaIconQuadrants(_ image: CGImage) -> String? {
    let width = image.width, height = image.height
    guard width > 1, height > 1 else { return nil }
    var pixels = [UInt16](repeating: 0, count: width * height * 4)
    let drawn: Bool = pixels.withUnsafeMutableBufferPointer { buf -> Bool in
        guard
            let ctx = CGContext(
                data: buf.baseAddress, width: width, height: height,
                bitsPerComponent: 16, bytesPerRow: width * 8,
                space: CGColorSpace(name: CGColorSpace.sRGB)
                    ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                    | CGBitmapInfo.byteOrder16Little.rawValue)
        else { return false }
        // OPAQUE BLACK FIRST. A source carrying alpha composites over whatever
        // is already in this buffer, and uninitialized memory would make a
        // translucent pixel report a different colour every run.
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { return nil }
    // A bitmap context's memory is TOP-DOWN — row 0 is the picture's top edge
    // — while its user space has a bottom-left origin, so drawing the image
    // upright lands its top row first. Same order the Windows arm asks
    // GetDIBits for with a negative height.
    func sample(_ qx: Int, _ qy: Int) -> String {
        let x = min(width * (1 + 2 * qx) / 4, width - 1)
        let y = min(height * (1 + 2 * qy) / 4, height - 1)
        let at = (y * width + x) * 4
        func byte(_ v: UInt16) -> Int { Int((Double(v) / 65535.0 * 255.0).rounded()) }
        return String(
            format: "%02X%02X%02X",
            byte(pixels[at]), byte(pixels[at + 1]), byte(pixels[at + 2]))
    }
    return [sample(0, 0), sample(1, 0), sample(0, 1), sample(1, 1)]
        .joined(separator: "/")
}

#if os(macOS)
    /// This process's activation policy, spelled rather than numbered: every
    /// sentence below turns on it, and `policy=1` is a number the reader has to
    /// go and look up.
    func kayaMacPolicySpelling() -> String {
        switch NSApp.activationPolicy() {
        case .regular: return "regular"
        case .accessory: return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "policy \(NSApp.activationPolicy().rawValue)"
        }
    }

    /// THE DECLARED IDENTITY, LOWERED (docs/app-identity-plan.md ruling 2 and
    /// I9), each part measured: `.accessory` has NO DOCK TILE, so a declaring
    /// app becomes `.regular`; the icon goes through `applicationIconImage`; and
    /// THE NAME IS PARTIAL, `NSApp.mainMenu`'s first item being the only route.
    func kayaApplyMacIdentity(_ name: String, _ icon: Data?) {
        let before = kayaMacPolicySpelling()
        var raised = true
        if NSApp.activationPolicy() != .regular {
            raised = NSApp.setActivationPolicy(.regular)
        }
        var installed = "none declared"
        if let bytes = icon {
            if let image = NSImage(data: bytes) {
                NSApp.applicationIconImage = image
                installed = "\(bytes.count) bytes -> \(Int(image.size.width))x"
                    + "\(Int(image.size.height))"
            } else {
                // MEASURED, AND THE PLATFORM'S OWN ICON IS LEFT STANDING: only
                // this platform's decoder can say whether a blob is a picture,
                // and it answered no. Nothing is substituted.
                installed = "\(bytes.count) bytes REFUSED by NSImage(data:)"
                kayaDiag(
                    "the app identity's icon bytes: NSImage(data:) refused "
                        + "\(bytes.count) bytes — the blob is not a picture this "
                        + "platform can decode, so the icon macOS already had "
                        + "stands and nothing was substituted")
            }
        }
        // The menu bar's first item is the app menu, and its title is the one
        // runtime name route this platform has. `kayaSyncMacMenuBar` never
        // touches item 0's title, so there is one author here.
        if let first = NSApp.mainMenu?.items.first, !name.isEmpty {
            first.title = name
        }
        kayaDiag(
            "app identity \(name): policy \(before) -> \(kayaMacPolicySpelling()) "
                + "(setActivationPolicy returned \(raised)), icon \(installed), "
                + "menu-bar title \(NSApp.mainMenu?.items.first?.title ?? "<no main menu>")")
    }

    /// WHY THIS READ CANNOT REPORT QUADRANT SAMPLES, or nil when it can. EVERY
    /// ANSWER IS A SENTENCE THIS PROCESS MEASURED (tools/check-diagnostics.py):
    /// `NSApp.applicationIconImage` CANNOT TELL "stored" FROM "SHOWN", reporting
    /// a 512x512 image installed while the Dock had no tile (I8).
    func kayaMacAppIconWhyNot(_ held: NSImage?, _ bitmap: CGImage?) -> String? {
        guard let held else {
            return "<AppKit holds no picture at all: NSApp.applicationIconImage is "
                + "nil, this app declared \(kayaScene.appIdentityIcon?.count ?? 0) "
                + "icon bytes, and this process is \(kayaMacPolicySpelling())>"
        }
        guard NSApp.activationPolicy() == .regular else {
            return "<a \(Int(held.size.width))x\(Int(held.size.height)) picture is "
                + "installed but this process is \(kayaMacPolicySpelling()): an app "
                + "that is not regular has no Dock tile to put one in, so this read "
                + "cannot say anything is showing it>"
        }
        guard let bitmap else {
            return "<AppKit holds a \(Int(held.size.width))x\(Int(held.size.height)) "
                + "NSImage with no bitmap representation this read can sample; "
                + "the app declared \(kayaScene.appIdentityIcon?.count ?? 0) icon bytes>"
        }
        guard bitmap.width > 1, bitmap.height > 1 else {
            return "<AppKit's picture rasterizes to \(bitmap.width)x\(bitmap.height), "
                + "too small to sample by quadrant>"
        }
        return nil
    }

    /// THE PICTURE THE SHELL WILL DRAW, in pixels, off AppKit's own copy —
    /// never off `kayaScene.appIdentityIcon`, which is the declaration echoed
    /// back and would pass with no lowering at all.
    @MainActor func kayaMacAppIcon() -> String {
        let held = NSApp.applicationIconImage
        var rect = CGRect(origin: .zero, size: held?.size ?? .zero)
        let bitmap = held?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        if let why = kayaMacAppIconWhyNot(held, bitmap) { return why }
        guard let bitmap, let samples = kayaIconQuadrants(bitmap) else {
            return "<AppKit's picture could not be drawn into a sampling bitmap: "
                + "\(bitmap?.width ?? 0)x\(bitmap?.height ?? 0)>"
        }
        return samples
    }
#else
    /// THE BUNDLE'S ICON FILE, resolved the way iOS itself resolves it:
    /// `CFBundleIcons` > `CFBundlePrimaryIcon` > `CFBundleIconFiles`, the first
    /// name, as a `.png` in the bundle. Returns the URL and the name it looked
    /// for, so a failure can say WHICH name it wanted.
    func kayaIOSBundleIconEntry() -> (name: String, url: URL?) {
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let files = primary?["CFBundleIconFiles"] as? [String]
        guard let first = files?.first else { return ("", nil) }
        if first.hasSuffix(".png") {
            return (first, Bundle.main.url(
                forResource: String(first.dropLast(4)), withExtension: "png"))
        }
        return (first + ".png",
                Bundle.main.url(forResource: first, withExtension: "png"))
    }

    /// WHY THIS READ CANNOT REPORT QUADRANT SAMPLES, or nil when it can. THE
    /// READ IS OF THE BUILT BUNDLE and CANNOT PASS VACUOUSLY: three states go
    /// RED and each names itself — no declared identity, a bundle with no icon,
    /// and a bundle whose icon is not the picture the wire declared.
    func kayaIOSAppIconWhyNot(_ entry: (name: String, url: URL?), _ bundled: Data?)
        -> String?
    {
        guard let declared = kayaScene.appIdentityIcon else {
            return "<this app declared no identity: no set_app_identity record "
                + "carrying icon bytes reached this backend, so there is nothing "
                + "the bundle at \(Bundle.main.bundleURL.lastPathComponent) can be "
                + "held equal to>"
        }
        guard !entry.name.isEmpty else {
            return "<the bundle \(Bundle.main.bundleURL.lastPathComponent) declares "
                + "no icon: its Info.plist has no CFBundleIcons > "
                + "CFBundlePrimaryIcon > CFBundleIconFiles, while the app declared "
                + "\(declared.count) icon bytes over the wire>"
        }
        guard let bundled else {
            return "<the bundle names \(entry.name) in CFBundleIconFiles but holds "
                + "no such file: \(Bundle.main.bundleURL.lastPathComponent) carries "
                + "\((try? FileManager.default.contentsOfDirectory(atPath: Bundle.main.bundlePath).count) ?? -1) "
                + "entries, and the app declared \(declared.count) icon bytes>"
        }
        guard bundled == declared else {
            return "<the bundle's icon and the declared icon are different pictures: "
                + "\(entry.name) is \(bundled.count) bytes, the wire declared "
                + "\(declared.count) bytes, and the first byte they differ at is "
                + "\(zip(bundled, declared).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(bundled.count, declared.count))>"
        }
        guard UIImage(data: bundled)?.cgImage != nil else {
            return "<the bundle's \(entry.name) is \(bundled.count) bytes that UIKit "
                + "will not decode: UIImage(data:) produced no bitmap, so the Home "
                + "Screen has nothing to draw either>"
        }
        return nil
    }

    /// The bundle's icon in PIXELS, decoded by UIKit's own decoder — the
    /// same conversion the Home Screen would do — so the samples prove
    /// the conversion and not merely that a file was copied.
    @MainActor func kayaIOSAppIcon() -> String {
        let entry = kayaIOSBundleIconEntry()
        let bundled = entry.url.flatMap { try? Data(contentsOf: $0) }
        if let why = kayaIOSAppIconWhyNot(entry, bundled) { return why }
        guard let bundled, let bitmap = UIImage(data: bundled)?.cgImage,
            let samples = kayaIconQuadrants(bitmap)
        else {
            return "<the bundle's \(entry.name) could not be drawn into a sampling "
                + "bitmap: \(bundled?.count ?? 0) bytes>"
        }
        return samples
    }
#endif

/// One style switch, because `.buttonStyle` takes a concrete type: bordered is
/// the dressed floor, borderedProminent the `prominent` role's chrome. Top
/// level, since a platform-conditional TYPE would put the compile error on the
/// other platform's lane.
private struct KayaButtonStyle: PrimitiveButtonStyle {
    let prominent: Bool
    var plain = false
    func makeBody(configuration: Configuration) -> some View {
        if prominent {
            BorderedProminentButtonStyle().makeBody(configuration: configuration)
        } else if plain {
            BorderlessButtonStyle().makeBody(configuration: configuration)
        } else {
            BorderedButtonStyle().makeBody(configuration: configuration)
        }
    }
}

/// THE IMAGE DECODE, in one function so the layout negative
/// (tools/check-empty-child.py) drives the real decoder. A failed decode is the
/// placeholder class, never a crash; ImageIO is LENIENT where gdk-pixbuf
/// refuses, so no scene can freeze a HALF-valid image (docs/deferred.md).
func kayaDecodeImage(_ data: Data?, into node: KayaNode) {
    if let data, let image = KayaPlatformImage(data: data) {
        node.image = image
        node.imageSize = "\(Int(image.size.width))x\(Int(image.size.height))"
    } else {
        node.image = nil
        node.imageSize = "0x0"
    }
}

/// The core's raster as a CGImage: premultiplied RGBA8, no decode and no colour
/// conversion — the bytes ARE the picture (docs/canvas-plan.md §1.1, §8). nil
/// for a zero-sized or short buffer, the declared-and-empty case, where the
/// render keeps the node present (tools/check-empty-child.py).
func kayaDrawingImage(_ data: Data?, _ width: Int, _ height: Int) -> CGImage? {
    guard let data, width > 0, height > 0, data.count >= width * height * 4 else { return nil }
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    // PREMULTIPLIED FIRST + byteOrder32Big is RGBA in memory order on a
    // little-endian host: R at byte 0, A at byte 3, which is tiny-skia's
    // Pixmap layout. The swizzle a wrong pair here would produce is what
    // expect_ink exists to catch.
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        .union(.byteOrder32Big)
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: info,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent)
}

struct KayaRender: View {
    let node: KayaNode
    /// The mounted root fills its window; nested containers do not.
    var isRoot = false
    /// The MAIN AXIS of the flex container this node is a child of, nil wherever
    /// grow has no meaning. A widget whose natural size is a FIXED FRAME needs
    /// it to honour grow: releasing both dimensions would fill the CROSS axis,
    /// which is align's business.
    var flexVertical: Bool? = nil
    /// That container's align MODE — the CROSS axis's half of the question
    /// `flexVertical` answers for the main one, and the one kind whose
    /// cross-axis default is not the container's: a scroll spans under start
    /// and stretch (ruled 2026-09-02), and center and end position it.
    var flexAlign: Int64 = alignStart
    var flexStretch = false
    /// The reorderable For this node is a stamped row of, if any
    /// (docs/dnd-plan.md D8): its surface then drags and takes rows.
    var reorderIn: KayaNode? = nil
    /// Grouped section header/footer dress (KayaGroupedSections.kayaBare).
    @Environment(\.kayaGroupedSectionText) private var kayaGroupedSectionText

    var body: some View {
        // The widget/node anchor: a context catalog rides .contextMenu on the
        // node's view, and editable text never reaches here (the root rejects
        // the attach). The accessibility props ride EVERY kind, applied where
        // every node's view passes through (tools/check-universal-props.py).
        if kayaScene.contextRoots[node.id]?.isEmpty == false {
            kayaA11y(kayaDragDrop(widget.contextMenu { KayaContextMenuItems(widgetId: node.id) }), node)
        } else {
            kayaA11y(kayaDragDrop(widget), node)
        }
    }

    /// The drag-and-drop surface behind a node that declares a payload, an
    /// operation mask, or is a row of a reorderable For (docs/dnd-plan.md D7,
    /// D8): an AppKit view on macOS, a UIKit one on iOS.
    @ViewBuilder private func kayaDragDrop(_ view: some View) -> some View {
        if node.dragPayload != nil || node.dropOps != 0 || reorderIn != nil {
            #if os(macOS)
                view.background(KayaMacDragDropSurface(node: node, reorderIn: reorderIn))
            #else
                view.background(KayaPhoneDragDropSurface(node: node, reorderIn: reorderIn))
            #endif
        } else {
            view
        }
    }

    /// The stock-stack path's children, both axes: frame BEFORE the
    /// reader, content top-leading (the stretch-classified-center fix,
    /// 2026-08-22, now one body for both spellings).
    @ViewBuilder private func kayaStackChildren(vertical: Bool) -> some View {
        ForEach(node.laidOut) { child in
            KayaRender(
                node: child, flexVertical: vertical,
                flexStretch: node.align == alignStretch,
                reorderIn: node.reorderable ? node : nil
            )
            .frame(
                maxWidth: vertical && (child.fill ?? (node.align == alignStretch)) ? .infinity : nil,
                maxHeight: !vertical && (child.fill ?? (node.align == alignStretch)) ? .infinity : nil,
                alignment: .topLeading)
            .background(
                KayaCellReader(id: child.id, parent: node.id, vertical: vertical)
            )
        }
    }

    @ViewBuilder private var widget: some View {
        switch node.kind {
        case kindColumn, kindRow:
            // ONE NODE, TWO CONSTRUCTOR SPELLINGS (docs/adaptive-layout-plan.md
            // D1): the kind names the INITIAL axis and the harness's address;
            // the axis prop, when set, is the arrangement truth. Normalized:
            // 8-unit spacing, cross-axis start.
            let vertical = (node.axis ?? (node.kind == kindColumn ? 1 : 0)) == 1
            // Stack unless a child carries a weight OR this container must FILL
            // the box its parent handed it (the 2026-08-22 ruling): a stack
            // returns its natural size however large a frame it is offered, so
            // nothing below it would have leftover space to divide.
            let boxFills =
                isRoot || (flexStretch && node.fill != false) || node.fill == true
                || (node.grow > 0 && flexVertical == !vertical)
            // A CROSSING container maximizes its main axis (the 2026-08-22
            // breadth ruling). It rides a frame around the chosen body, not the
            // flex path: forcing the flex path was watched breaking baseline
            // mode, since a common baseline is the stack's native gift.
            let boxCrosses = flexVertical == !vertical && node.fill != false
            Group {
                if vertical && !node.tableColumns.isEmpty {
                    // The declared table (docs/tables-plan.md);
                    // KayaTableSurface picks the tier. Tables declare on
                    // columns; the core holds the templates to the arity.
                    KayaTableSurface(node: node)
                } else if kayaIsGroupedFlow(node) {
                    // A grouped screen's PRIMARY FLOW (the grouped-screen
                    // rule): the flow's subtree renders as the section
                    // stream instead of its own flex layout.
                    KayaGroupedSections(flow: node)
                } else if !vertical && node.wrap {
                    // A ROW THAT FLOWS (docs/layout-knobs-plan.md §2): natural
                    // sizes, new lines when the width runs out, the cross
                    // reader on every child so expect_lines reads the tops.
                    KayaFlow(spacing: node.spacing) {
                        ForEach(node.laidOut) { child in
                            KayaRender(node: child, flexVertical: false)
                                .background(
                                    KayaCellReader(id: child.id, parent: node.id, vertical: false)
                                )
                        }
                    }
                } else if vertical && kayaIsForm(node) {
                    // A COLUMN OF LABELLED ROWS IS A FORM (docs/forms-plan.md
                    // §2), AHEAD of the flex branch: a section stream renders
                    // the form stretched, and the flex branch took it first
                    // (the card and its dividers gone, captured 2026-09-06).
                    // The platform's own form surface, its label column
                    // shared and its side-by-side against stacked decision the
                    // control's, never kaya's arithmetic. macOS gets the
                    // grouped Form; iOS draws the inset-grouped card the table
                    // and the fold already draw, because a List-backed Form
                    // inside a scroll collapses to nothing (measured
                    // 2026-09-06, the whole form gone from the phone).
                    #if os(macOS)
                        Form {
                            kayaStackChildren(vertical: true)
                        }
                        .formStyle(.grouped)
                    #else
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(node.laidOut.enumerated()), id: \.element.id) { i, child in
                                KayaRender(node: child, flexVertical: true)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                    .padding(.vertical, kayaFoldSectionPadY)
                                    .background(
                                        KayaCellReader(id: child.id, parent: node.id, vertical: true)
                                    )
                                if i < node.laidOut.count - 1 {
                                    Divider()
                                }
                            }
                        }
                        .padding(.horizontal, kayaFoldSectionPadX)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .background(kayaCardShape())
                    #endif
                } else if boxFills || node.laidOut.contains(where: { $0.grow > 0 }) {
                    KayaFlex(
                        vertical: vertical, spacing: node.spacing, nodes: node.laidOut,
                        fillCross: boxFills
                    ) {
                        ForEach(node.laidOut) { child in
                            // The cell fills the track KayaFlex proposes; the
                            // reader records the STRETCH FRAME's box in stretch
                            // mode (content top-leading, like GTK's Fill) and
                            // the content's box otherwise.
                            KayaCell(
                                traceId: child.id, vertical: vertical, align: node.align
                            ) {
                                KayaRender(
                                    node: child, flexVertical: vertical,
                                    flexAlign: node.align,
                                    flexStretch: node.align == alignStretch,
                                    reorderIn: node.reorderable ? node : nil)
                                    // The grower renders AT its track, leaf or
                                    // container, and stretch spans the cross
                                    // (the 2026-08-22 breadth ruling; grow.steps
                                    // was watched failing before it).
                                    .frame(
                                        maxWidth: (vertical
                                            ? (child.fill ?? (node.align == alignStretch))
                                            : child.grow > 0) ? .infinity : nil,
                                        maxHeight: (vertical
                                            ? child.grow > 0
                                            : (child.fill ?? (node.align == alignStretch)))
                                            ? .infinity : nil,
                                        alignment: .topLeading)
                                    .background(
                                        KayaCellReader(id: child.id, parent: node.id, vertical: vertical)
                                    )
                            }
                            .background(
                                KayaTrackReader(
                                    id: child.id, vertical: vertical,
                                    tableGeneration: child.tableColumns.isEmpty
                                        ? nil : kayaTableGeometryGeneration(child)))
                        }
                    }
                } else if vertical {
                    VStack(alignment: kayaColumnAlignment(node.align), spacing: node.spacing) {
                        kayaStackChildren(vertical: true)
                    }
                } else {
                    HStack(alignment: kayaRowAlignment(node.align), spacing: node.spacing) {
                        kayaStackChildren(vertical: false)
                    }
                }
            }
            .frame(
                maxWidth: !vertical && boxCrosses ? .infinity : nil,
                maxHeight: vertical && boxCrosses ? .infinity : nil,
                alignment: .topLeading)
            .coordinateSpace(name: "kaya-box-\(node.id)")
            .background(
                KayaBoxReader(
                    id: node.id, vertical: vertical,
                    crossInset: kayaIsGroupedFlow(node) ? Double(2 * kayaFoldSectionPadX) : 0))
            .background(KayaInsetReader(id: node.id, outer: false))
            .padding(node.inset)
            .background(KayaInsetReader(id: node.id, outer: true))
        case kindLabeled:
            // THE LABELLED ROW (docs/forms-plan.md §3): the label names the
            // control — LabeledContent is the platform's own pair, and it
            // carries the accessibility relation — with the optional trailing
            // button beside the control.
            let parts = node.laidOut
            if let label = parts.first, parts.count >= 2 {
                // THE RELATION, stated on the control: its accessibility name
                // is the label's text unless the app named it itself
                // (docs/forms-plan.md §4).
                let named = parts[1].a11yLabel.isEmpty ? label.text : parts[1].a11yLabel
                #if os(macOS)
                    LabeledContent {
                        HStack(spacing: node.spacing) {
                            KayaRender(node: parts[1])
                                .accessibilityLabel(named)
                            if parts.count > 2 {
                                KayaRender(node: parts[2]).fixedSize()
                            }
                        }
                    } label: {
                        KayaRender(node: label)
                    }
                #else
                    // THE PHONE'S FOLD: side by side when the row fits its
                    // width, the value under the label when it does not, so a
                    // Clear beside a date never crushes to one letter per line
                    // (measured 2026-09-06). ONE Layout over ONE control, never
                    // ViewThatFits: docs/traps.md, the measured copy's dismantle.
                    KayaLabeledFold(spacing: node.spacing) {
                        KayaRender(node: label)
                        KayaRender(node: parts[1]).accessibilityLabel(named)
                        if parts.count > 2 {
                            KayaRender(node: parts[2]).fixedSize()
                        }
                    }
                #endif
            } else {
                EmptyView()
            }
        case kindButton:
            // The dressed floor. macOS bridges to NSButton: under a pre-26 SDK
            // stamp SwiftUI's Button lays out at borderless metrics while
            // drawing the bezel, under EVERY style (38x20 against 52x32). iOS
            // keeps SwiftUI's Button: it measures what it draws.
            #if os(macOS)
                KayaMacButton(
                    title: node.text, tag: node.tag, role: node.role,
                    fillsWidth: node.grow > 0 && flexVertical == false
                )
                    .alignmentGuide(.top) { d in
                        kayaBaselineOffsets[node.id] = d[.firstTextBaseline] - d[.top]
                        return d[.top]
                    }
            #else
                // SwiftUI's own role vocabulary (docs/styling-plan.md D4):
                // destructive rides Button(role:), prominence is the
                // borderedProminent style — both platform affordances, never
                // raw color.
                Button(
                    node.text,
                    role: node.role == roleDestructive ? .destructive : nil
                ) {
                    KayaHost.emit(node.tag)
                }
                .buttonStyle(KayaButtonStyle(
                    prominent: node.role == roleProminent, plain: node.role == rolePlain))
                .alignmentGuide(.top) { d in
                    kayaBaselineOffsets[node.id] = d[.firstTextBaseline] - d[.top]
                    return d[.top]
                }
            #endif
        case kindLabel:
            // The heading role (docs/styling-plan.md D4) is BOTH facts at once:
            // the heading TEXT STYLE (.headline, never a raw size) and the AX
            // heading trait, caption being the tier under it. A role with no arm
            // here is REFUSED, never quietly worn as a plain label.
            let _ = precondition(
                node.role == 0 || node.role == roleHeading
                    || node.role == roleCaption,
                "kaya: label role \(node.role) has no swiftui arm")
            let sectionText = kayaGroupedSectionText
            // THE SWAPPED style, not the platform's: a text style set here
            // OVERRIDES the root font, so a heading in a branded app would
            // be the one label still in the system face (measured). Unroled
            // labels pass nil and inherit the root's.
            let font: Font? =
                node.role == roleHeading
                    ? (sectionText
                        ? (kayaBrandFont(.footnote) ?? .footnote)
                        : (kayaBrandFont(.headline) ?? .headline))
                    : node.role == roleCaption
                        ? (kayaBrandFont(.footnote) ?? .footnote) : nil
            let base = Text(node.text)
                .font(font)
                .textCase(
                    node.role == roleHeading && sectionText ? .uppercase : nil)
            Group {
                if node.role == roleCaption || (node.role == roleHeading && sectionText) {
                    base.foregroundStyle(.secondary)
                } else {
                    base
                }
            }
            .accessibilityAddTraits(
                node.role == roleHeading ? .isHeader : [])
            .alignmentGuide(.top) { d in
                kayaBaselineOffsets[node.id] = d[.firstTextBaseline] - d[.top]
                return d[.top]
            }
        case kindCheckbox:
            // Uncontrolled toward the app, the entry's shape: the node
            // mirrors the box's state (SwiftUI needs the binding), and
            // every flip is emitted with the box's identity tag.
            Toggle(
                node.text,
                isOn: Binding(
                    get: { node.checked },
                    set: { newValue in
                        kayaUserWrite { node.checked = newValue }
                        KayaHost.emitToggled(node.tag, newValue)
                    })
            )
            // The checkbox style is AppKit-only; iOS keeps the switch,
            // its native presentation of an on/off bit.
            #if os(macOS)
                .toggleStyle(.checkbox)
            #else
                // A UIKit switch is greedy on width: unfixed, it took a task
                // row's whole free width and pushed its neighbours to the
                // right (tools/scenes/tasks.steps, 2026-09-05). A grower
                // keeps its track.
                .fixedSize(horizontal: node.grow == 0, vertical: false)
            #endif
            .alignmentGuide(.top) { d in
                kayaBaselineOffsets[node.id] = d[.firstTextBaseline] - d[.top]
                return d[.top]
            }
        case kindSlider:
            // The platform's own control, hosted (docs/slider-plan.md §5):
            // NSSlider on the mac, UISlider on iOS, one commit path for a
            // user's move and a driven one. Hosted rather than SwiftUI's
            // Slider because a stepped SwiftUI slider on macOS draws a tick
            // per stop with no switch, and iOS draws none at all.
            KayaSliderSurface(node: node)
            // A slider has no natural width, so 200 stands in as the
            // intrinsic size every other toolkit's slider has. A grower must NOT
            // keep that cap: capping the drawn control below its track rendered
            // a 1:3 row as 38/62 while expect_shares kept passing.
            .frame(maxWidth: node.grow > 0 ? .infinity : 200)
        case kindDatePicker:
            // The platform's own control, hosted (docs/datetime-plan.md D6):
            // the compact field that opens the calendar. Its action is the
            // commit; the node mirrors it and the emit rides the identity tag.
            KayaPickerSurface(node: node, isTime: false)
                .fixedSize()
        case kindTimePicker:
            KayaPickerSurface(node: node, isTime: true)
                .fixedSize()
        case kindEntry:
            KayaEntry(node: node, flexVertical: flexVertical)
        case kindTextarea:
            KayaTextarea(node: node, flexVertical: flexVertical, flexStretch: flexStretch)
        case kindSelect:
            // The dressed floor: SwiftUI's own Picker in its menu presentation.
            // The node's label children are its options (their text, in child
            // order); the node mirrors the selected index, and every pick is
            // emitted with the select's identity tag — the uncontrolled contract.
            Picker(
                "",
                selection: Binding(
                    get: { Int(node.value) },
                    set: { newIndex in
                        kayaUserWrite { node.value = Double(newIndex) }
                        KayaHost.emitValue(node.tag, Double(newIndex))
                    })
            ) {
                ForEach(Array(node.children.enumerated()), id: \.element.id) { index, option in
                    // ON THE OPTION TEXT, NOT ON THE PICKER. Measured both ways:
                    // the option's font changes the rendering (0.0540 differing
                    // pixels), the Picker's changes nothing (0.0000) — it is an
                    // NSPopUpButton, which the root font does not reach.
                    Text(option.text).font(kayaBrandFont()).tag(index)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        case kindGrid where node.columns == 0:
            // THE GRID THAT FITS (docs/layout-knobs-plan.md §3): as many
            // columns as fit the proposed width at the floor, equal shares;
            // the cells record their leading edge exactly as the fixed
            // grid's do, so expect_grid_columns reads both the same way.
            KayaAutoGrid(minWidth: node.minColumnWidth, spacing: node.spacing) {
                ForEach(node.children, id: \.id) { cell in
                    KayaRender(node: cell)
                        .background(
                            GeometryReader { g in
                                Color.clear
                                    .onAppear {
                                        kayaCellMinX[cell.id] =
                                            g.frame(in: .named("kaya-grid-\(node.id)")).minX
                                    }
                                    .onChange(of: g.frame(in: .named("kaya-grid-\(node.id)")).minX) { _, x in
                                        kayaCellMinX[cell.id] = x
                                    }
                            }
                        )
                }
            }
            .coordinateSpace(name: "kaya-grid-\(node.id)")
            .background(KayaInsetReader(id: node.id, outer: false))
            .padding(node.inset)
            .background(KayaInsetReader(id: node.id, outer: true))
        case kindGrid:
            // The 2D layout contract: SwiftUI's own Grid — columns take their
            // natural width, aligned across rows. The node's children chunk
            // row-major by its columns count; each cell records its leading
            // edge for the geometry observation.
            Grid(
                alignment: .leading,
                horizontalSpacing: node.spacing, verticalSpacing: node.spacing
            ) {
                let cols = max(1, node.columns)
                let rows = stride(from: 0, to: node.children.count, by: cols).map {
                    Array(node.children[$0..<min($0 + cols, node.children.count)])
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                    GridRow {
                        ForEach(cells, id: \.id) { cell in
                            KayaRender(node: cell)
                                .background(
                                    GeometryReader { g in
                                        Color.clear
                                            .onAppear {
                                                kayaCellMinX[cell.id] =
                                                    g.frame(in: .named("kaya-grid-\(node.id)")).minX
                                            }
                                            .onChange(of: g.frame(in: .named("kaya-grid-\(node.id)")).minX) { _, x in
                                                kayaCellMinX[cell.id] = x
                                            }
                                    }
                                )
                        }
                    }
                }
            }
            .coordinateSpace(name: "kaya-grid-\(node.id)")
            .background(KayaInsetReader(id: node.id, outer: false))
            .padding(node.inset)
            .background(KayaInsetReader(id: node.id, outer: true))
        case kindRadio:
            // The choice contract in its inline presentation. The dressed floor
            // per platform: macOS renders the REAL radio group (Picker's
            // radioGroup style); iOS has no radio idiom, and its native
            // spelling of one-of-N inline is the segmented control.
            Picker(
                "",
                selection: Binding(
                    get: { Int(node.value) },
                    set: { newIndex in
                        kayaUserWrite { node.value = Double(newIndex) }
                        KayaHost.emitValue(node.tag, Double(newIndex))
                    })
            ) {
                ForEach(Array(node.children.enumerated()), id: \.element.id) { index, option in
                    // ON THE OPTION TEXT, NOT ON THE PICKER, for the select
                    // arm's measured reason: the font on the option changes the
                    // rendering (0.0540 differing pixels), the font on the
                    // Picker changes nothing at all (0.0000).
                    Text(option.text).font(kayaBrandFont()).tag(index)
                }
            }
            #if os(macOS)
                .pickerStyle(.radioGroup)
            #else
                .pickerStyle(.segmented)
            #endif
            .labelsHidden()
            .fixedSize()
        case kindProgress:
            // The dressed floor: SwiftUI's own ProgressView — linear
            // determinate over the 0..=1 fraction, or the activity
            // flavor while indeterminate is on.
            Group {
                if node.indeterminate {
                    ProgressView()
                } else {
                    ProgressView(value: node.value)
                }
            }
            .frame(maxWidth: node.grow > 0 ? .infinity : 200)
        case kindScroll:
            // The vertical scroll viewport over its ONE child. AND IT SPANS ITS
            // PARENT'S CROSS AXIS (ruled 2026-09-02): a vertical ScrollView is
            // as wide as its content, which left a 79pt pannable strip in a
            // 375pt window (docs/traps.md).
            let scrollSpans = flexVertical != nil && node.fill != false
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    if let content = node.children.first {
                        KayaRender(node: content)
                            // ON THE CONTENT, not around the ScrollView: a frame
                            // outside it widens only a wrapper, which reads as
                            // spanning while a pan moves nothing (2026-09-02).
                            // Height stays the content's: it is what scrolls.
                            .frame(
                                maxWidth: (flexVertical == true && scrollSpans) ? .infinity : nil,
                                alignment: .topLeading)
                            .background(
                                GeometryReader { g in
                                    Color.clear
                                        .onAppear {
                                            node.scrollContentH = g.size.height
                                            node.scrollContentMaxY =
                                                g.frame(in: .named("kaya-scroll-\(node.id)")).maxY
                                        }
                                        .onChange(of: g.frame(in: .named("kaya-scroll-\(node.id)"))) { _, f in
                                            node.scrollContentH = f.height
                                            node.scrollContentMaxY = f.maxY
                                        }
                                }
                            )
                            .id("kaya-scroll-content-\(node.id)")
                    }
                }
                .coordinateSpace(name: "kaya-scroll-\(node.id)")
                .background(
                    GeometryReader { g in
                        Color.clear
                            .onAppear {
                                node.scrollViewportH = g.size.height
                                node.scrollViewportW = g.size.width
                                kayaScrollProxies[node.id] = proxy
                            }
                            .onChange(of: g.size) { _, size in
                                node.scrollViewportH = size.height
                                node.scrollViewportW = size.width
                            }
                    }
                )
            }
        case kindImage:
            // Fixed to the decoded image's intrinsic size (no .resizable()),
            // matching the harness's size observation. A FAILED DECODE IS
            // PRESENT AND EMPTY, NOT ABSENT (tools/check-empty-child.py).
            if let image = node.image {
                #if os(macOS)
                    Image(nsImage: image)
                #else
                    Image(uiImage: image)
                #endif
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        case kindCanvas:
            // THE BLIT (docs/canvas-plan.md §8): the bytes go on screen at the
            // density they were drawn at, interpreting no draw op. STRICTLY 1:1,
            // NEVER STRETCHED (§3.2.1, tools/check-canvas-blit.py), and PRESENT
            // AND EMPTY when undeclared (tools/check-empty-child.py).
            Group {
                if let buffer = node.drawing {
                    #if os(macOS)
                        Image(
                            nsImage: NSImage(
                                cgImage: buffer,
                                size: NSSize(
                                    width: CGFloat(buffer.width) / node.drawingScale,
                                    height: CGFloat(buffer.height) / node.drawingScale)))
                    #else
                        Image(
                            uiImage: UIImage(
                                cgImage: buffer, scale: node.drawingScale, orientation: .up))
                    #endif
                } else {
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            // THE TRACK IS WHAT A GROWER IS OFFERED, and the reader sits
            // OUTSIDE the box that claims it: `.background` measures the view it
            // decorates, so on the bare image it would report the BUFFER's size
            // and the size policy could never do anything.
            .frame(
                maxWidth: node.grow > 0 ? .infinity : nil,
                maxHeight: node.grow > 0 ? .infinity : nil)
            .background(KayaCanvasReader(id: node.id))
            .background(kayaHarnessDrivesFrames ? nil : KayaCanvasTicker())
        default:
            EmptyView()
        }
    }
}

#if os(macOS)
    /// The macOS button, bridged to AppKit rather than SwiftUI's Button: under a
    /// pre-26 SDK stamp SwiftUI 26 measures Button at borderless metrics (38x20)
    /// while drawing the bezel (52x32). An AppKit control cannot disagree with
    /// itself (tools/check-design-generation.py).
    private struct KayaMacButton: NSViewRepresentable {
        let title: String
        let tag: [UInt8]
        var role: Int64 = 0
        /// A grower's bezel spans its track (the 2026-08-22 breadth
        /// ruling's leaf half): true fills the width proposal, an
        /// NSButton draws its bezel across whatever frame it is given,
        /// and GTK/WinUI/Compose already render exactly that.
        var fillsWidth = false

        final class Coordinator: NSObject {
            var tag: [UInt8] = []
            @objc func fire() { KayaHost.emit(tag) }
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> NSButton {
            let button = NSButton(
                title: title, target: context.coordinator,
                action: #selector(Coordinator.fire))
            button.bezelStyle = .rounded
            return button
        }

        func updateNSView(_ button: NSButton, context: Context) {
            button.title = title
            context.coordinator.tag = tag
            // SEMANTIC EMPHASIS, in AppKit's own words (docs/styling-plan.md
            // D4): destructive is NSButton's hasDestructiveAction (macOS 11+ —
            // the system decides what that looks like), prominent is the
            // default-button key equivalent.
            button.hasDestructiveAction = role == roleDestructive
            button.keyEquivalent = role == roleProminent ? "\r" : ""
            button.isBordered = role != rolePlain
            button.contentTintColor = role == rolePlain ? .controlAccentColor : nil
            // THE TYPEFACE'S PIPE INTO APPKIT, the tint finding's twin: an
            // NSButton never reads SwiftUI's `.font` (measured). `button.font`,
            // never `attributedTitle`: both change the pixels, but after the
            // attributedTitle route `button.font` still reads the system font.
            if let font = kayaPlatformFont(.body) { button.font = font }
            // THE BRAND'S ONE PIPE INTO APPKIT: an NSButton never reads
            // SwiftUI's `.tint` (2026-08-12). The default-button bezel is the
            // one accent surface AppKit gives a button, so the PROMINENT role
            // carries the fill, re-resolved on appearance change.
            if role == roleProminent, let brand = kayaScene.brand {
                button.bezelColor = NSColor(
                    name: nil,
                    dynamicProvider: { appearance in
                        let dark =
                            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        let fill = dark ? brand[6] : brand[1]
                        return NSColor(
                            srgbRed: Double((fill >> 16) & 0xFF) / 255.0,
                            green: Double((fill >> 8) & 0xFF) / 255.0,
                            blue: Double(fill & 0xFF) / 255.0,
                            alpha: 1.0)
                    })
            } else {
                button.bezelColor = nil
            }
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize, nsView: NSButton, context: Context
        ) -> CGSize? {
            let fit = nsView.fittingSize
            if fillsWidth, let width = proposal.width, width > fit.width {
                return CGSize(width: width, height: fit.height)
            }
            return fit
        }
    }
#endif

/// The window's navigation path, DERIVED from the core-owned stack: the getter
/// maps the model, and the setter is the user-pop interception point — SwiftUI
/// writes a shorter path when the back affordance fires, and the model decides
/// what actually pops.
func kayaNavPath(_ sid: UInt64) -> Binding<[UInt64]> {
    // The surface may be a window or a section — stacks are
    // per-surface (DESIGN.md, Sections).
    Binding(
        get: {
            (kayaScene.sectionsById[sid]?.entries
                ?? kayaScene.windows[sid]?.entries ?? []).map(\.id)
        },
        set: { newPath in kayaUserPops(sid, to: newPath.count) })
}

/// The surface's stack accessor: window or section, one shape.
private func kayaStackEntries(_ sid: UInt64) -> [KayaEntryModel] {
    kayaScene.sectionsById[sid]?.entries ?? kayaScene.windows[sid]?.entries ?? []
}

/// A user-driven pop down to `depth` entries: pop unarmed tops one at a time —
/// each reconciling the core-owned stack post-fact through emitEntryPopped —
/// and STOP at an intercept_back-armed entry: nothing pops there,
/// back_requested fires instead, and the derived path snaps the view back.
/// The surface whose stack the implicit stack verbs read and drive: the
/// window's selected section when it has sections, else the window —
/// stacks are per surface and the platform's back routes to the active
/// section's (scene.rs, PushEntry).
func kayaActiveSurface(_ wid: UInt64) -> UInt64 {
    guard let window = kayaScene.windows[wid], !window.sections.isEmpty,
        let sid = window.selectedSection
    else { return wid }
    return sid
}

/// A surface's stack depth, window or section; -1 for no such surface.
func kayaStackDepth(_ surface: UInt64) -> Int {
    (kayaScene.sectionsById[surface]?.entries ?? kayaScene.windows[surface]?.entries)?.count ?? -1
}

func kayaUserPops(_ sid: UInt64, to depth: Int) {
    while kayaStackEntries(sid).count > depth, let top = kayaStackEntries(sid).last {
        if top.interceptBack {
            KayaHost.emitBackRequested(top.id)
            return
        }
        if let section = kayaScene.sectionsById[sid] {
            section.entries.removeLast()
        } else {
            kayaScene.windows[sid]?.entries.removeLast()
        }
        kayaScene.navEntries.removeValue(forKey: top.id)
        kayaScene.entryWindow.removeValue(forKey: top.id)
        kayaLastPopAt = Date().timeIntervalSince1970
        KayaHost.emitEntryPopped(top.id)
    }
}

// --- Menus: the command vocabulary (DESIGN.md, Menus) ---------------
// macOS materializes the key window's catalog as a Kaya-owned native NSMenu
// segment (SwiftUI's CommandsBuilder has no buildArray); iOS folds it into a
// trailing More menu. ONE dispatch path, through kayaMenuUserActivate.

/// The harness's OPEN context menu: context_open records the anchor here and
/// the following menu_activate resolves against it (main actor).
var kayaOpenContextWidget: UInt64?

/// The interpreter's shortcut dispatch table: canonical spelling -> action item
/// id, rebuilt from the presented catalog on every menu change. On iOS the
/// `shortcut` verb traverses THIS table; on macOS dispatch is the real NSMenu
/// key-equivalent walk and the NSMenuItems carry the chords.
var kayaShortcutItems: [String: UInt64] = [:]

/// The phone bar's promotion capacity: k is the PLATFORM's idiom, never
/// computed by kaya. Inert on macOS.
let kayaPromotionCapacity = 2

/// Enablement is the AND of the item's own flag and every grouping
/// ancestor's — the inherited rule every read, render, shortcut, and
/// activation route shares (docs/traps.md).
func kayaMenuEffectiveEnabled(_ item: KayaMenuItemModel) -> Bool {
    var enabled = item.enabled
    var current = item.id
    while let parentId = kayaScene.menuParents[current],
        let parent = kayaScene.menuItems[parentId]
    {
        enabled = enabled && parent.enabled
        current = parentId
    }
    // A STANDARD COMMAND CONFIGURES ITS OWN ENABLEMENT, and kaya computes it
    // rather than handing the app a signal to compute it with: kaya knows what
    // is focused, kaya knows what the clipboard offers, and the widget already
    // declared what it accepts.
    return enabled && kayaRoleEnabled(item.role)
}

/// Whether a clipboard role's command can act right now; a non-role item answers
/// true. Paste is the INTERSECTION — something focused that takes content, and
/// something on the clipboard it takes — where cut and copy need only a focused
/// widget with a selection to give.
func kayaRoleEnabled(_ role: String) -> Bool {
    #if os(macOS)
        switch role {
        case "undo":
            // A4: ONE named query, and enablement is the routing answer —
            // `nothing` is what a disabled Edit>Undo means. This case is the
            // fifth silent-failure site D6 named: a role the filter does not
            // know falls to `default` and reports ENABLED forever.
            return kayaUndoRoute() != .nothing
        case "redo":
            return kayaRedoRoute() != .nothing
        case "cut", "copy":
            guard let id = kayaScene.focusedId else { return false }
            return kayaScene.entryWidgets.contains(where: { $0.id == id })
                || kayaScene.textareas.contains(where: { $0.id == id })
        case "paste":
            guard let id = kayaScene.focusedId,
                let node = kayaScene.nodes[id]
            else { return false }
            // A widget that declared NOTHING still pastes — the
            // platform inserts and the change handler reports it — so
            // an undeclared editable target enables on the offer alone.
            let (kinds, custom) = kayaParseAcceptList(node.accepts)
            if node.accepts.isEmpty {
                return NSPasteboard.general.canReadObject(forClasses: [NSString.self])
            }
            let offered = NSPasteboard.general.types?.map(\.rawValue) ?? []
            if custom.contains(where: { offered.contains($0) }) { return true }
            for (name, bit) in [
                ("text", kayaClipText), ("html", kayaClipHtml),
                ("image", kayaClipImage), ("files", kayaClipFiles),
            ] where kinds & bit != 0 {
                if offered.contains(kayaClipUTI(name)) { return true }
            }
            return false
        default:
            return true
        }
    #else
        // THE SAME INTERSECTION, in this platform's vocabulary. Every question
        // here is prompt-free (§8 finding 2), which is what lets enablement be
        // computed LIVE inside a body evaluation: a version that could raise the
        // paste alert would raise it while the user looked at a menu.
        switch role {
        case "undo":
            // A4 again: enablement IS the routing answer, asked live. The
            // phone's read path calls straight through to here, so it never had
            // the mac's stale-enablement problem — no NSMenuItem holds a state
            // it was born with.
            return kayaUndoRoute() != .nothing
        case "redo":
            return kayaRedoRoute() != .nothing
        case "cut", "copy":
            guard let id = kayaScene.focusedId else { return false }
            return kayaScene.entryWidgets.contains(where: { $0.id == id })
                || kayaScene.textareas.contains(where: { $0.id == id })
        case "paste":
            guard let id = kayaScene.focusedId,
                let node = kayaScene.nodes[id]
            else { return false }
            // A widget that declared NOTHING still pastes — the platform
            // inserts and the change handler reports it — so an
            // undeclared editable target enables on the offer alone.
            let (kinds, custom) = kayaParseAcceptList(node.accepts)
            if node.accepts.isEmpty {
                return UIPasteboard.general.hasStrings
            }
            let offered = Set(UIPasteboard.general.types)
            if custom.contains(where: { offered.contains($0) }) { return true }
            for (name, bit) in [
                ("text", kayaClipText), ("html", kayaClipHtml),
                ("image", kayaClipImage), ("files", kayaClipFiles),
            ] where kinds & bit != 0 {
                if offered.contains(kayaClipUTI(name)) { return true }
            }
            return false
        default:
            return true
        }
    #endif
}

/// ONE LINE WHEN A STANDARD COMMAND DOES NOTHING, naming the intersection that
/// came up empty — AND the door where a paste's board is witnessed. A disabled
/// role item is INERT, and for a scene SILENT: the activation reports success,
/// emits nothing, and fails seconds later (docs/traps.md, 2026-08-04).
func kayaRoleInertNote(_ item: KayaMenuItemModel, verb: String) {
    // AND THE WITNESS FIRST, before the enablement question: a paste whose
    // staged content was replaced is usually DISABLED, and every route past this
    // point turns a disabled item away without touching the clipboard. On macOS
    // kaya gets no say once AppKit has greyed the real item.
    if item.role == "paste" { kayaClipWitness("the paste command (\(verb))") }
    guard !item.role.isEmpty, !kayaMenuEffectiveEnabled(item) else { return }
    if item.role == "undo" || item.role == "redo" {
        kayaUndoInertNote(item, verb: verb)
        return
    }
    let board = kayaClipBoardNow()
    let target: String
    if let id = kayaScene.focusedId, let node = kayaScene.nodes[id] {
        target =
            node.accepts.isEmpty
            ? "the focused widget (node \(id)) declares no accept list, so it takes the "
                + "platform's own insertion"
            : "the focused widget (node \(id)) accepts [\(node.accepts)]"
    } else {
        target = "nothing is focused"
    }
    let note =
        "KAYA_CLIP_TRACE: \(verb) did nothing — the \(item.role) command "
        + "is disabled and a disabled item is inert. \(target); the clipboard offers "
        + "\(board.types) at cc \(board.change)\(kayaClipOwnerClause())\n"
    FileHandle.standardError.write(Data(note.utf8))
}


/// ONE LINE WHEN AN UNDO ACTIVATION WAS INERT, naming WHICH of the three ways it
/// can be: the app disabled the item, an ancestor disabled it, or both tiers
/// came up empty. It matters more here because of A6's protocol gap — a
/// native-tier undo is byte-identical to typing on the wire.
func kayaUndoInertNote(_ item: KayaMenuItemModel, verb: String) {
    let redo = item.role == "redo"
    let route = redo ? kayaRedoRoute() : kayaUndoRoute()
    let native = redo ? kayaFocusedCanRedo() : kayaFocusedCanUndo()
    let focus: String
    if let id = kayaScene.focusedId {
        focus =
            "node \(id) is focused and its native stack answers "
            + "can\(redo ? "Redo" : "Undo")=\(native)"
    } else {
        focus = "nothing is focused, so there is no native stack to ask"
    }
    let why: String
    if route == .nothing {
        why = "both tiers are empty — no step in the field and none in the core ledger"
    } else if !item.enabled {
        why = "the app disabled the item itself"
    } else {
        why = "a grouping ancestor is disabled, so the inherited AND is false"
    }
    let note =
        "KAYA_UNDO_TRACE: \(verb) did nothing — the \(item.role) command is "
        + "disabled and a disabled item is inert. \(why); \(focus)\n"
    FileHandle.standardError.write(Data(note.utf8))
}

// ---- The native text-undo tier ------------------------------------
// TWO TIERS, ONE SURFACE (docs/undo-plan.md D1). THE TWO MANAGERS, measured
// (§1.2): an ENTRY's is the field editor's private NSCellUndoManager, a
// TEXTAREA's the WINDOW's, and a programmatic write joins the "Typing" group.

#if os(macOS)
    /// How long the clear waits for SwiftUI to push a written value into the
    /// AppKit control before giving up on proving it: main-queue turns, 1ms
    /// apart, so a wedged sync reports rather than hangs.
    private let kayaUndoSyncTurns = 240

    /// The AppKit text object serving what is focused — the entry's field editor
    /// or the textarea's NSTextView — or nil when nothing editable is. Scoped to
    /// one window when the caller knows which, since neither this layer nor the
    /// core keeps a widget-to-window map.
    func kayaFocusedTextResponder(in window: UInt64? = nil) -> NSText? {
        if let window {
            return kayaNSWindows[window]?.firstResponder as? NSText
        }
        for host in kayaNSWindows.values {
            if let text = host.firstResponder as? NSText { return text }
        }
        return nil
    }

    // The `type` verb's macOS half lives here too: A8's verb exists so a scene
    // can fill the native stack this tier delegates to.

    /// The kaya window whose first responder is editing text — where a
    /// synthesized key event has to be addressed for AppKit to route it
    /// the way a real one is routed.
    func kayaFocusedTextWindow() -> NSWindow? {
        for host in kayaNSWindows.values where host.firstResponder is NSText {
            return host
        }
        return nil
    }

    /// The same window, WAITED FOR: kaya's focus is a model fact at once, but
    /// AppKit installs the field editor a render later, so the step before a
    /// `type` can pass while the platform has nowhere to send a key (measured).
    /// NOT by activating the process, which would steal a sibling leg's focus.
    func kayaAwaitTextWindow() -> NSWindow? {
        for _ in 0..<kayaUndoSyncTurns {
            if let window = DispatchQueue.main.sync(execute: { kayaFocusedTextWindow() }) {
                return window
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        // The last resort the first cut had as its only resort: the key
        // window is where a real keystroke would land if this process
        // were frontmost.
        return DispatchQueue.main.sync { NSApp.keyWindow }
    }

    /// The `type` verb's macOS half: real NSEvent key downs through
    /// NSApp.sendEvent. IN-PROCESS ON PURPOSE — CGEvent posting into the HID
    /// stream would type at whatever is frontmost. ONE EVENT PER CHARACTER, with
    /// a turn for the toolkit between them.
    func kayaTypeAtFocus(_ text: String) -> Bool {
        guard let window = kayaAwaitTextWindow() else { return false }
        let before = DispatchQueue.main.sync { () -> String? in
            // CONTRACT POINT 3: TYPING APPENDS. macOS SELECTS a field's whole
            // contents at first responder, so keys REPLACE what is there and the
            // script diverges from every other lane's. The caret goes to the end
            // first, and not between keys: that breaks the editor's coalescing.
            if let responder = kayaFocusedTextResponder() {
                let end = (responder.string as NSString).length
                responder.selectedRange = NSRange(location: end, length: 0)
            }
            return kayaScene.focusedId.flatMap { kayaScene.nodes[$0]?.text }
        }
        for ch in text {
            let sent = DispatchQueue.main.sync { () -> Bool in
                let key = String(ch)
                for kind in [NSEvent.EventType.keyDown, .keyUp] {
                    guard
                        let event = NSEvent.keyEvent(
                            with: kind, location: .zero, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil,
                            characters: key, charactersIgnoringModifiers: key,
                            isARepeat: false, keyCode: 0)
                    else { return false }
                    NSApp.sendEvent(event)
                }
                return true
            }
            if !sent { return false }
            Thread.sleep(forTimeInterval: 0.001)
        }
        kayaSettleTypedText(from: before)
        return true
    }

    /// Contract point 4: block until the typed text has LANDED, since an action
    /// is never retried and a keystroke still in flight reads as a broken undo
    /// rather than a missed key. A timeout is not a verdict — nothing focused is
    /// legitimate here, so it reports and returns.
    func kayaSettleTypedText(from before: String?) {
        var last: String?
        var stable = 0
        var moved = false
        for _ in 0..<250 {
            let now = DispatchQueue.main.sync { () -> String? in
                kayaScene.focusedId.flatMap { kayaScene.nodes[$0]?.text }
            }
            moved = moved || now != before
            if moved {
                stable = now == last ? stable + 1 : 0
                if stable >= 2 { return }
            }
            last = now
            Thread.sleep(forTimeInterval: 0.001)
        }
        if !moved {
            let note =
                "KAYA_UNDO_TRACE: type delivered its keys but the focused widget's text "
                + "never moved — kaya's focus is node "
                + "\(kayaScene.focusedId.map(String.init) ?? "nowhere") and the platform's "
                + "first responder is "
                + "\(kayaFocusedTextWindow()?.firstResponder.map { String(describing: type(of: $0)) } ?? "not editing text")\n"
            FileHandle.standardError.write(Data(note.utf8))
        }
    }
#endif

#if os(iOS)
    // ---- The same tier, in the phones' vocabulary ---------------------
    // EVERY CELL OF §1.3 DIVERGES FROM THE MAC, re-measured here: a PRIVATE
    // `_UITextUndoManager` per text kind; `undo:` NEVER FALLS THROUGH;
    // `canPerformAction(undo:)` answers FALSE while undo works; D7 IS FREE.

    /// The turn budget this half spends waiting for UIKit to catch up with a
    /// model write: main-queue turns a millisecond apart, so a wedged sync
    /// reports rather than hangs. Same number and reasoning as the macOS
    /// constant of this name; they are in mutually exclusive branches.
    private let kayaUndoSyncTurns = 240

    /// Q2's ledger-quiet bracket, IN THIS PLATFORM'S TIMING: a native undo
    /// reaches kaya's model SYNCHRONOUSLY INSIDE `sendAction`, where the mac
    /// arm's emission arrives a runloop turn later. AND THE TEXT BRACKET MUST
    /// NOT BE USED HERE — a record written after its edit silences the next one.
    var kayaRoutedNativeUndoDepth = 0

    /// Perform the platform's own undo (or redo) with the bracket held open
    /// across it, so the edit it provokes is banked ONCE — by
    /// `kayaNoteNativeUndo`'s sample, with this interpreter's emission quiet.
    func kayaSendBracketedNativeUndo(_ selector: Selector) {
        kayaRoutedNativeUndoDepth += 1
        kayaSendToFocusedResponder(selector)
        kayaRoutedNativeUndoDepth -= 1
    }

    /// The view holding keyboard focus. A WALK RATHER THAN AN API, because there
    /// is no API: UIKit names no first responder, and the `sendAction`-capture
    /// trick answers with a responder that may not be a view. The walk is public
    /// and cheap — it runs on activation, not per frame.
    func kayaFirstResponderView() -> UIView? {
        func walk(_ view: UIView) -> UIView? {
            if view.isFirstResponder { return view }
            for sub in view.subviews {
                if let hit = walk(sub) { return hit }
            }
            return nil
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                if let hit = walk(window) { return hit }
            }
        }
        return nil
    }

    /// The focused EDITABLE, or nil when nothing editable is focused — the iOS
    /// half of the mac arm's `kayaFocusedTextResponder`. Both kaya text kinds
    /// land on a UIKit control conforming to `UITextInput`, so the caret move,
    /// the text sample and the undo query are each written ONCE for both kinds.
    func kayaFocusedTextInput() -> (UIView & UITextInput)? {
        kayaFirstResponderView() as? (UIView & UITextInput)
    }

    /// The same, WAITED FOR — `kayaAwaitTextWindow`'s phone half, guarding the
    /// identical trap: kaya's focus is a model fact at once while UIKit makes
    /// the control first responder a render later, so a `type` step in between
    /// reports "nothing focused" for a scene that did everything right.
    func kayaAwaitFocusedTextInput() -> (UIView & UITextInput)? {
        for _ in 0..<kayaUndoSyncTurns {
            if let input = DispatchQueue.main.sync(execute: { kayaFocusedTextInput() }) {
                return input
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return nil
    }

    /// What the control SHOWS, read from the toolkit rather than from
    /// kaya's model — the reconciliation sample is made of this, and the
    /// model is a turn stale exactly where it is taken.
    func kayaTextInputString(_ input: UITextInput) -> String {
        guard
            let whole = input.textRange(
                from: input.beginningOfDocument, to: input.endOfDocument)
        else { return "" }
        return input.text(in: whole) ?? ""
    }

    /// The `type` verb's iOS half (harness.rs `Stage::type_text`, A8): the caret
    /// to the end in process (point 3), the KEYS from the host's resident
    /// XCUITest driver through the simulator's keyboard, which the field must
    /// hold, and the settle (point 4). Nil on success, the sentence otherwise.
    func kayaTypeThroughHost(_ text: String) -> String? {
        guard let input = kayaAwaitFocusedTextInput() else {
            return "reached no editable first responder — nothing was typed"
        }
        let before = DispatchQueue.main.sync { () -> String? in
            if let end = input.textRange(from: input.endOfDocument, to: input.endOfDocument) {
                input.selectedTextRange = end
            }
            return kayaScene.focusedId.flatMap { kayaScene.nodes[$0]?.text }
        }
        let payload = Data(text.utf8).base64EncodedString()
        let (ok, lines) = KayaSimdrive.ask("type_b64 \(payload)", timeout: 60)
        if !ok {
            return lines.first ?? "the host refused to type without saying why"
        }
        kayaSettleTypedText(from: before)
        return nil
    }

    /// Contract point 4: block until the typed text has LANDED, the mac arm's
    /// reasoning unchanged. A timeout is not a verdict: nothing focused is
    /// legitimate here, so this reports and returns.
    func kayaSettleTypedText(from before: String?) {
        var last: String?
        var stable = 0
        var moved = false
        for _ in 0..<250 {
            let now = DispatchQueue.main.sync { () -> String? in
                kayaScene.focusedId.flatMap { kayaScene.nodes[$0]?.text }
            }
            moved = moved || now != before
            if moved {
                stable = now == last ? stable + 1 : 0
                if stable >= 2 { return }
            }
            last = now
            Thread.sleep(forTimeInterval: 0.001)
        }
        if !moved {
            let responder = DispatchQueue.main.sync {
                kayaFirstResponderView().map { String(describing: type(of: $0)) }
            }
            let note =
                "KAYA_UNDO_TRACE: type delivered its keys but the focused widget's text "
                + "never moved — kaya's focus is node "
                + "\(kayaScene.focusedId.map(String.init) ?? "nowhere") and the platform's "
                + "first responder is \(responder ?? "nothing")\n"
            FileHandle.standardError.write(Data(note.utf8))
        }
    }

    /// D7's ASSERTION, which on this platform replaces D7's mechanism: a
    /// programmatic write was measured to clear the field's native history
    /// itself, and a `removeAllActions()` anyway would hide a UIKit regression.
    /// ON THE FAR SIDE OF THE RENDER, for the mac arm's reason.
    func kayaAssertNativeUndoCleared(expecting text: String, tries: Int = 0) {
        guard let input = kayaFocusedTextInput() else { return }
        if kayaTextInputString(input) != text {
            // SUPERSEDED (the mac arm's case, same shape): the model has moved
            // past the write this assertion belongs to, so the control will
            // never show `text` and the later write's own assertion covers it.
            if kayaScene.focusedId.flatMap({ kayaScene.nodes[$0]?.text }) != text { return }
            if tries < kayaUndoSyncTurns {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) {
                    kayaAssertNativeUndoCleared(expecting: text, tries: tries + 1)
                }
                return
            }
            let note =
                "KAYA_UNDO_TRACE: the UIKit control never caught up with the written text "
                + "after \(tries) turns (it holds \(kayaTextInputString(input).count) chars, "
                + "the write was \(text.count)); D7's assertion could not be taken\n"
            FileHandle.standardError.write(Data(note.utf8))
            return
        }
        guard input.undoManager?.canUndo == true else { return }
        let note =
            "KAYA_UNDO_TRACE: a programmatic write left the field's native undo history "
            + "STANDING (canUndo is still true) — this platform was measured to discard it "
            + "itself (docs/undo-plan.md §1.3), so UIKit's behavior has changed and D7 is "
            + "no longer free here; clearing explicitly to keep the rule, and this line is "
            + "the regression report\n"
        FileHandle.standardError.write(Data(note.utf8))
        input.undoManager?.removeAllActions()
    }

    /// A1's clear, which on this platform is NOT free: an iOS field keeps its
    /// history across focus changes (measured), so "ask the focused text first"
    /// would take back typing from BEFORE the group. MEASURED EFFECTIVE —
    /// canUndo true going in, false coming out.
    func kayaClearFocusedNativeUndo() {
        kayaFocusedTextInput()?.undoManager?.removeAllActions()
    }
#endif

/// Which surface's ledger a widget's typing belongs to (§3: one ledger per
/// window). THE CORE CANNOT ANSWER THIS and this layer can, which is why the
/// window rides the edit emission. The primary answers for a widget with no
/// mounted root above it, where an episode banked is at worst coarse.
func kayaWindowOf(_ id: UInt64) -> UInt64 {
    var top = id
    while let parent = kayaScene.parents[top] { top = parent }
    for (window, model) in kayaScene.windows where model.root?.id == top {
        return window
    }
    for (entry, model) in kayaScene.navEntries where model.root?.id == top {
        return kayaScene.entryWindow[entry] ?? 0
    }
    for (section, model) in kayaScene.sectionsById where model.root?.id == top {
        return kayaScene.sectionWindow[section] ?? 0
    }
    return 0
}

/// The ledger-quiet bracket around a native undo this backend ROUTED (§3): field
/// id -> the text the walk left. A BRACKET AND NOT A FLAG-WITH-A-TIMER, since
/// the sample is taken as `undo:` returns and SwiftUI pushes the same text
/// through the binding a runloop turn LATER.
var kayaNativeUndoEcho: [UInt64: String] = [:]

/// Record the text a routed native undo left in a field, so the ordinary
/// edit that follows it is banked once rather than twice.
func kayaNoteNativeUndoEcho(_ id: UInt64, _ text: String) {
    kayaNativeUndoEcho[id] = text
}

/// Is this edit the echo of a routed native undo? Consumes the record if
/// so — one bracket, one edit.
func kayaTakeNativeUndoEcho(_ id: UInt64, _ text: String) -> Bool {
    #if os(iOS)
        // THE PHONE'S BRACKET IS A SCOPE, not a text match, because its
        // emission arrives INSIDE the routed undo rather than a turn after it
        // (kayaRoutedNativeUndoDepth carries the measurement).
        if kayaRoutedNativeUndoDepth > 0 { return true }
    #endif
    guard kayaNativeUndoEcho[id] == text else { return false }
    kayaNativeUndoEcho.removeValue(forKey: id)
    return true
}

/// A4's ONE named query — "can the focused widget undo?" — answered in this
/// platform's vocabulary and asked nowhere else in this file. D6 already named
/// four hard-coded role filters as silent-failure sites; a fifth expression of
/// this question is the shape A4 exists to refuse.
func kayaFocusedCanUndo() -> Bool {
    #if os(macOS)
        return kayaFocusedTextResponder()?.undoManager?.canUndo == true
    #else
        // THE SAME QUESTION, and NOT the one the platform offers:
        // `canPerformAction(undo:)` was measured FALSE while undo demonstrably
        // worked (§1.3), so UIKit's own oracle would ship a permanently greyed
        // Edit>Undo. The manager is asked directly.
        return kayaFocusedTextInput()?.undoManager?.canUndo == true
    #endif
}

/// Redo's twin, same contract.
func kayaFocusedCanRedo() -> Bool {
    #if os(macOS)
        return kayaFocusedTextResponder()?.undoManager?.canRedo == true
    #else
        return kayaFocusedTextInput()?.undoManager?.canRedo == true
    #endif
}

/// D7/A1's clear, ON THE FAR SIDE OF THE RENDER (§1.2, measured): the LATER
/// runloop turn's push is what registers the undo action, so a clear timed to
/// the MODEL write clears an empty stack. It waits until the control PROVABLY
/// shows the written text.
func kayaClearNativeUndo(in window: UInt64? = nil, expecting text: String, tries: Int = 0) {
    #if os(macOS)
        // Nothing editable focused: an unfocused write registers
        // nothing (measured), so there is no history and no retry.
        guard let responder = kayaFocusedTextResponder(in: window) else { return }
        if responder.string != text {
            // SUPERSEDED: the model has moved past the write this clear belongs
            // to, so the control will never show `text` and the later write's
            // own clear covers the field.
            if kayaScene.focusedId.flatMap({ kayaScene.nodes[$0]?.text }) != text { return }
            if tries < kayaUndoSyncTurns {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) {
                    kayaClearNativeUndo(in: window, expecting: text, tries: tries + 1)
                }
                return
            }
            // NEVER PROVED. Clear anyway — the ratified rule is that an app
            // overwrite invalidates the field's edit history — but say so,
            // because a sync that never lands means this arm's central
            // assumption about the render moved.
            let note =
                "KAYA_UNDO_TRACE: the AppKit control never caught up with the written "
                + "text after \(tries) turns (it holds \(responder.string.count) chars, "
                + "the write was \(text.count)); clearing the field's undo history "
                + "anyway — D7 is the rule, and a missed clear is the corrupting case\n"
            FileHandle.standardError.write(Data(note.utf8))
        }
        responder.undoManager?.removeAllActions()
    #endif
}

/// D7 + A3 at the quiet-write sites: a programmatic write resets THAT widget's
/// native undo history, but only when it CHANGED the text (A3) and only when the
/// widget is focused. Called from the apply arms, so a core-written inverse
/// travels a forward write's path. THE PHONES DO NOT NEED IT (§1.3).
func kayaNoteQuietTextWrite(_ id: UInt64, from previous: String, to next: String) {
    guard previous != next else { return }
    guard kayaScene.focusedId == id else { return }
    #if os(macOS)
        kayaClearNativeUndo(expecting: next)
    #else
        kayaAssertNativeUndoCleared(expecting: next)
    #endif
}

/// A1: a core undo group committed, so the focused editable's native history goes
/// with it (the episode was banked first, so only granularity is lost). The
/// keystone (§3): every episode begins with an EMPTY native stack, so the native
/// stack can never reach past the episode's start.
func kayaClearUndoForGroup(_ window: UInt64) {
    #if os(macOS)
        // The expectation is the focused node's model text: once the control
        // shows it, the render that would have re-registered has happened.
        let expected = kayaScene.focusedId.flatMap { kayaScene.nodes[$0]?.text } ?? ""
        kayaClearNativeUndo(in: window, expecting: expected)
    #else
        // NO RENDER TO WAIT FOR HERE: a group commit does not write this field,
        // so no value is in flight for a later push to re-register behind the
        // clear. What there IS on this platform is a history that would SURVIVE
        // (measured), which is why the phone cannot take A1 for free.
        kayaClearFocusedNativeUndo()
    #endif
}

/// Where an undo can go: the focused text's own stack, the core's ledger, or
/// nowhere — `Scene::route_undo`'s three answers, mirrored.
enum KayaUndoRoute {
    case nothing
    case native
    case core
}

/// Where an undo would go RIGHT NOW. ASKED ONCE AND USED TWICE — enablement and
/// activation are the same question (D6, A4). AND THE ANSWER IS THE CORE'S: the
/// backend contributes only what it can see, the focus and that field's stack.
func kayaUndoRoute() -> KayaUndoRoute {
    #if os(macOS)
        return kayaRouteCode(
            KayaHost.api.undo_route(
                kayaPresentedMenuWindow, kayaScene.focusedId ?? 0,
                kayaFocusedCanUndo() ? 1 : 0))
    #else
        return kayaRouteCode(
            KayaHost.api.undo_route(
                kayaUndoWindow(), kayaScene.focusedId ?? 0,
                kayaFocusedCanUndo() ? 1 : 0))
    #endif
}

#if os(iOS)
    /// Which window's ledger an undo activation belongs to. macOS asks the key
    /// window, which is what its global menu bar shows; this platform has no
    /// such variable, so the activation asks the EMISSION's question — the
    /// window whose ledger this field's typing was banked into.
    func kayaUndoWindow() -> UInt64 {
        guard let id = kayaScene.focusedId else { return 0 }
        return kayaWindowOf(id)
    }
#endif

/// Redo's twin. On the frontier episode redo stays NATIVE while the episode is
/// partly undone — the platform still holds those steps, and taking them back
/// coarsely would throw away granularity the user sees. That judgement is the
/// ledger's too; this asks with `canRedo`.
func kayaRedoRoute() -> KayaUndoRoute {
    #if os(macOS)
        return kayaRouteCode(
            KayaHost.api.redo_route(
                kayaPresentedMenuWindow, kayaScene.focusedId ?? 0,
                kayaFocusedCanRedo() ? 1 : 0))
    #else
        return kayaRouteCode(
            KayaHost.api.redo_route(
                kayaUndoWindow(), kayaScene.focusedId ?? 0,
                kayaFocusedCanRedo() ? 1 : 0))
    #endif
}

/// The vtable's three-way answer, in this file's vocabulary. An unknown code is
/// a protocol drift, not a "nothing to do": the host and this interpreter would
/// disagree about routing, silently, on every activation.
func kayaRouteCode(_ code: UInt32) -> KayaUndoRoute {
    switch code {
    case 0: return .nothing
    case 1: return .native
    case 2: return .core
    default:
        fatalError("kaya: unknown undo route \(code) from the host — the vtable and this interpreter disagree")
    }
}

/// Perform an undo/redo role on the focused surface; answers whether it WAS one.
/// ROUTING (D6/§3): the focused text answers first when its own stack has
/// something, and `undo:` at the first responder implements that INCLUDING the
/// fall-through. windowWillReturnUndoManager is DELIBERATELY not implemented.
func kayaPerformUndoRole(_ role: String) -> Bool {
    #if os(macOS)
        switch role {
        case "undo":
            switch kayaUndoRoute() {
            case .native:
                kayaSendToFocusedResponder(Selector(("undo:")))
                kayaNoteNativeUndo(kayaPresentedMenuWindow)
            case .core: kayaCoreUndo(kayaPresentedMenuWindow)
            case .nothing: break
            }
            return true
        case "redo":
            switch kayaRedoRoute() {
            case .native:
                kayaSendToFocusedResponder(Selector(("redo:")))
                kayaNoteNativeUndo(kayaPresentedMenuWindow)
            case .core: kayaCoreRedo(kayaPresentedMenuWindow)
            case .nothing: break
            }
            return true
        default:
            return false
        }
    #else
        // THE TWO-STEP, HAND-WRITTEN: §1.3 measured that `undo:` reaches the
        // focused field's private manager and STOPS, so with that stack empty
        // the send is refused and nothing else is reached. The ROUTE decides
        // first and the send happens only on `.native`.
        switch role {
        case "undo":
            let window = kayaUndoWindow()
            switch kayaUndoRoute() {
            case .native:
                kayaSendBracketedNativeUndo(Selector(("undo:")))
                kayaNoteNativeUndo(window)
            case .core: kayaCoreUndo(window)
            case .nothing: break
            }
            return true
        case "redo":
            let window = kayaUndoWindow()
            switch kayaRedoRoute() {
            case .native:
                kayaSendBracketedNativeUndo(Selector(("redo:")))
                kayaNoteNativeUndo(window)
            case .core: kayaCoreRedo(window)
            case .nothing: break
            }
            return true
        default:
            return false
        }
    #endif
}

/// THE RECONCILIATION SAMPLE (§3): the field, the text the walk landed on, and
/// `canUndo` IN BOTH DIRECTIONS, from the AppKit control rather than the model.
/// THE SAMPLE IS ALSO HOW ANYONE ELSE FINDS OUT, overturning §0's premise: a
/// TextField's undo bypasses the binding's setter (measured, stale +50ms).
func kayaNoteNativeUndo(_ window: UInt64) {
    #if os(macOS)
        // NO RESPONDER, NO SAMPLE. Routing only sends the platform's undo where
        // a text responder answered CanUndo, so this cannot fire on the
        // ratified path — and if focus moved underneath it, an absent responder
        // reads as the empty string, which would wipe the field.
        guard let field = kayaScene.focusedId, let node = kayaScene.nodes[field],
            let responder = kayaFocusedTextResponder()
        else { return }
        let text = responder.string
        let canUndo = responder.undoManager?.canUndo ?? false
        kayaUserWrite { node.text = text }
        kayaNoteNativeUndoEcho(field, text)
        let utf8 = Array(text.utf8)
        utf8.withUnsafeBufferPointer { s in
            KayaHost.api.note_native_undo(
                window, field, s.baseAddress, UInt(s.count), canUndo ? 1 : 0)
        }
        KayaHost.emitText(node, text)
    #else
        // ONE CHANNEL LEFT, NOT THREE (§3a, measured): UIKit's undo is an
        // ordinary text replacement, so `text_changed` was emitted before this
        // line where the mac's model was still stale. NOT WRITING THE NODE IS
        // DELIBERATE — a second write would race the binding.
        guard let field = kayaScene.focusedId, let input = kayaFocusedTextInput()
        else { return }
        let text = kayaTextInputString(input)
        let canUndo = input.undoManager?.canUndo ?? false
        let utf8 = Array(text.utf8)
        utf8.withUnsafeBufferPointer { s in
            KayaHost.api.note_native_undo(
                window, field, s.baseAddress, UInt(s.count), canUndo ? 1 : 0)
        }
    #endif
}

/// The CORE tier: routing cases 2 and 3 (§3), where the core applies the inverse
/// itself. NOTHING COMES BACK, and that is the shape: the inverse produces
/// ordinary apply records that reach this interpreter through the pump.
func kayaCoreUndo(_ window: UInt64) {
    KayaHost.api.undo(window)
}

/// Redo's twin, symmetric in every respect (the forward delta was
/// computed at apply beside the inverse, so nothing is re-run).
func kayaCoreRedo(_ window: UInt64) {
    KayaHost.api.redo(window)
}

/// Send a standard editing command down the responder chain, starting at the
/// FOCUSED window's first responder. NOT `NSApp.sendAction(to: nil)`, which
/// starts at the KEY window: a leg running eight wide is rarely frontmost, and
/// the paste vanished with no error.
@discardableResult
func kayaSendToFocusedResponder(_ selector: Selector) -> Bool {
    #if os(macOS)
        for window in kayaNSWindows.values {
            if window.firstResponder?.tryToPerform(selector, with: nil) == true {
                return true
            }
        }
        if NSApp.sendAction(selector, to: nil, from: nil) { return true }
        let offered = kayaNSWindows.values.map { window in
            "win=\(window.windowNumber) "
                + (window.firstResponder.map { String(describing: type(of: $0)) } ?? "no responder")
        }
    #else
        // UIKit's dispatch starts at the FIRST RESPONDER and walks up, which is
        // the shape the macOS arm had to build by hand. Main thread, because it
        // moves the responder chain.
        if UIApplication.shared.sendAction(selector, to: nil, from: nil, for: nil) { return true }
        // No public API names this platform's first responder, so the sentence
        // below says what it can. The TRIGGER and the meaning are the same on
        // both platforms, which is the part that has to be uniform.
        let offered = ["the app's responder chain"]
    #endif
    // NOBODY TOOK IT: a command that reached no responder looks exactly like a
    // widget that ignored the content, and the scene reports a field that
    // simply stayed empty. A paste sent while the platform's focus is still
    // catching up with kaya's is precisely this, and it is intermittent.
    let note =
        "KAYA_CLIP_TRACE: \(selector) reached no responder that would take it — kaya's "
        + "focus is node \(kayaScene.focusedId.map(String.init) ?? "nowhere"), and the "
        + "platform offers [\(offered.joined(separator: ", "))]\n"
    FileHandle.standardError.write(Data(note.utf8))
    return false
}

/// Perform a clipboard role on the focused widget. Answers whether it WAS one,
/// so a plain action falls through. THE PASTE SPLIT: a widget that DECLARED what
/// it accepts takes the content through its paste hook, while one that declared
/// nothing gets the platform's own insertion.
func kayaPerformClipboardRole(_ role: String) -> Bool {
    #if os(macOS)
        switch role {
        case "cut", "copy":
            // A NATIVE CUT OR COPY IS A WRITE THIS LEG ASKED FOR, so it stages
            // like any other, or the guard reports a foreign writer for an
            // editor's own Cmd-X. The send is synchronous, so the board is
            // already written when it returns.
            kayaClipStaging()
            kayaSendToFocusedResponder(
                role == "cut" ? #selector(NSText.cut(_:)) : #selector(NSText.copy(_:)))
            kayaClipOwned(kayaClipBoardNow(), composed: false)
            return true
        case "paste":
            guard let id = kayaScene.focusedId, let node = kayaScene.nodes[id] else {
                return true
            }
            if node.accepts.isEmpty {
                // THE PLATFORM'S OWN INSERTION, down the responder chain. A
                // refusal is reported rather than swallowed: a paste that
                // reached no responder looks exactly like a widget that ignored
                // the content.
                kayaSendToFocusedResponder(#selector(NSText.paste(_:)))
                return true
            }
            // The same walk the privileged read makes, and deliberately
            // the same code: a paste and a read differ in their trigger,
            // never in what they can materialize.
            kayaReadClipboardValue(accepting: node.accepts).map { value in
                KayaHost.emitPasted(node.tag, value)
            }
            return true
        default:
            return false
        }
    #else
        switch role {
        case "cut", "copy":
            // The same stage the macOS arm opens. NOT COMPOSED BY KAYA, a real
            // limit: this clip carries no marker, the platform's only evidence,
            // so the witness stands down until kaya composes the next one. KAYA
            // WILL NOT STAMP A BOARD IT DID NOT COMPOSE.
            kayaClipStaging()
            kayaSendToFocusedResponder(
                role == "cut"
                    ? #selector(UIResponderStandardEditActions.cut(_:))
                    : #selector(UIResponderStandardEditActions.copy(_:)))
            kayaClipOwned(kayaClipBoardNow(), composed: false)
            return true
        case "paste":
            guard let id = kayaScene.focusedId, let node = kayaScene.nodes[id] else {
                return true
            }
            if node.accepts.isEmpty {
                // THE PLATFORM'S OWN INSERTION, ONE MAIN-QUEUE TURN OUT: a
                // kaya-dispatched paste is not the system's exempt affordance,
                // so the per-clip prompt can land mid-send and a synchronous
                // send would park the main AND harness threads.
                let finished = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    kayaSendToFocusedResponder(
                        #selector(UIResponderStandardEditActions.paste(_:)))
                    finished.signal()
                }
                kayaPressPasteWhileBusy(finished)
                return true
            }
            // The same walk the privileged read makes, and deliberately the
            // same code — off-thread for the same reason, since a paste of
            // foreign content is charged the same prompt.
            let tag = node.tag
            kayaReadOffThread(accepting: node.accepts) { value in
                value.map { KayaHost.emitPasted(tag, $0) }
            }
            return true
        default:
            return false
        }
    #endif
}

/// Catalog preorder: top-level grouping nodes in menubar-append order, then
/// each node's children in append order, depth-first. Creation time is
/// irrelevant — this order alone decides phone promotion.
func kayaCatalogPreorder(_ items: [KayaMenuItemModel]) -> [KayaMenuItemModel] {
    var out: [KayaMenuItemModel] = []
    func walk(_ item: KayaMenuItemModel) {
        out.append(item)
        for child in item.children { walk(child) }
    }
    for top in items { walk(top) }
    return out
}

/// The promoted primaries: the first k primary actions in catalog preorder.
/// Recomputed from the observable catalog on every mutation, so a later append
/// under an earlier node displaces deterministically.
func kayaPromotedActions(_ window: KayaWindowModel) -> [KayaMenuItemModel] {
    Array(
        kayaCatalogPreorder(window.menubar)
            .filter { $0.kind == menuKindAction && $0.primary }
            .prefix(kayaPromotionCapacity))
}

/// The catalog the chrome presents: the key kaya window's on macOS
/// (key-window changes swap it), the primary's on iOS.
func kayaPresentedCatalog() -> [KayaMenuItemModel] {
    #if os(macOS)
        return kayaScene.windows[kayaPresentedMenuWindow]?.menubar ?? []
    #else
        return kayaScene.windows[0]?.menubar ?? []
    #endif
}

/// Resolve a `>`-joined label path against root items, labels compared
/// byte-for-byte (the shared-scene contract). `"Sort>Date"` lands on
/// option Date inside group Sort; `"Sort"` lands on the group itself.
func kayaResolveMenuPath(_ path: String, roots: [KayaMenuItemModel]) -> KayaMenuItemModel? {
    var current = roots
    var found: KayaMenuItemModel?
    for seg in path.split(separator: ">", omittingEmptySubsequences: false).map(String.init) {
        guard let item = current.first(where: { kayaBytesEqual($0.label, seg) }) else {
            return nil
        }
        found = item
        current = item.children
    }
    return found
}

/// THE user dispatch path: chrome clicks, shortcuts, and harness verbs all land
/// here. Mirrors FIRST (the post-user-mirror rule), then emits with the item's
/// identity and the anchor's noun. Disabled items — the inherited AND — are
/// inert, exactly as native chrome leaves them.
func kayaMenuUserActivate(_ item: KayaMenuItemModel, noun: [UInt8] = []) {
    guard kayaMenuEffectiveEnabled(item) else { return }
    switch item.kind {
    case menuKindAction:
        // A ROLE ITEM IS THE PLATFORM'S COMMAND, not the app's action: it acts
        // on the focused widget and emits nothing of its own. kaya has no
        // selection API, which is exactly why these had to be commands.
        if kayaPerformUndoRole(item.role) { return }
        if kayaPerformClipboardRole(item.role) { return }
        KayaHost.emitMenuActivated(item.id, noun)
    case menuKindToggle:
        item.checked.toggle()  // the retained mirror, BEFORE the emit
        KayaHost.emitMenuToggled(item.id, noun, item.checked)
        kayaMenuChanged()
    case menuKindRadioOption:
        guard let groupId = kayaScene.menuParents[item.id],
            let group = kayaScene.menuItems[groupId],
            let index = group.children.firstIndex(where: { $0.id == item.id })
        else { return }
        kayaMenuUserSelectRadio(group, index, noun: noun)
    default:
        // Grouping nodes and separators have no activation; native
        // chrome opens or ignores them.
        break
    }
}

/// The radio group's user route (choice contract): selecting the
/// already-selected option is not a change and emits nothing, exactly
/// as the platform's own change route behaves.
func kayaMenuUserSelectRadio(_ group: KayaMenuItemModel, _ index: Int, noun: [UInt8] = []) {
    guard kayaMenuEffectiveEnabled(group),
        group.children.indices.contains(index),
        Int(group.value) != index
    else { return }
    group.value = Double(index)  // the retained mirror, BEFORE the emit
    KayaHost.emitMenuValueChanged(group.id, noun, Double(index))
    kayaMenuChanged()
}

/// The coalesced menu re-assert: rebuild the shortcut table and, on macOS,
/// re-synchronize the owned NSMenu segment. The macOS rebuild hops ONE
/// main-queue turn: a toggle fire runs inside AppKit's performActionForItem on
/// the very menu the rebuild would mutate.
func kayaMenuChanged() {
    var table: [String: UInt64] = [:]
    // Every LEAF command may carry a chord — a toggle and one option of a group
    // as readily as a plain action — so the table indexes all three kinds.
    for item in kayaCatalogPreorder(kayaPresentedCatalog())
    where !item.shortcut.isEmpty
        && (item.kind == menuKindAction || item.kind == menuKindToggle
            || item.kind == menuKindRadioOption)
    {
        table[item.shortcut] = item.id
    }
    kayaShortcutItems = table
    #if os(macOS)
        kayaScheduleMenuRebuild()
    #else
        // The menu bar is built from this same post-user mirror, so every prop
        // write has to invalidate it or the bar shows stale state. Coalesced by
        // UIKit, not by us.
        kayaRebuildCatalogMenus()
    #endif
}

/// One aspect of a menu item's state, spelled in the steps grammar's own words
/// — what expect_menu byte-compares. TOTAL: a missing item reads as a short
/// description, a retryable mismatch.
enum KayaMenuAspect { case enablement, checkedness, value }

func kayaModelMenuState(_ item: KayaMenuItemModel, _ aspect: KayaMenuAspect) -> String {
    switch aspect {
    case .enablement:
        return kayaMenuEffectiveEnabled(item) ? "enabled" : "disabled"
    case .checkedness:
        return item.checked ? "checked" : "unchecked"
    case .value:
        return "value \(Int(item.value))"
    }
}

/// THE expect_menu_symbol READ (docs/styling-plan.md D6): the semantic name the
/// item's REAL icon carries. macOS reads the materialized NSMenuItem's image;
/// iOS answers in TWO HALVES by what RENDERED, the unrendered one claiming no
/// menu was built. TOTAL: every failure is a retryable non-match.
func kayaMenuSymbolRead(_ path: String) -> String {
    let item: KayaMenuItemModel?
    if let wid = kayaOpenContextWidget {
        // Open-context EXCLUSIVITY, the state read's rule verbatim.
        item = kayaScene.contextRoots[wid].flatMap { kayaResolveMenuPath(path, roots: $0) }
    } else {
        item = kayaResolveMenuPath(path, roots: kayaPresentedCatalog())
    }
    guard let item else { return "no such item" }
    #if os(macOS)
        kayaEnsureMenuSegment()
        guard let nsItem = kayaOwnedNSMenuItem(item.id) else { return "no such item" }
        guard let image = nsItem.image else {
            // WHAT THIS MEASURED: the item exists in the real menu and carries
            // no image. It deliberately does NOT say whether the app asked for
            // one — this reader cannot see the difference between "no symbol
            // declared" and "declared and never lowered" (CLAUDE.md invariant 3).
            return "no image on the menu item"
        }
        guard let described = image.accessibilityDescription else {
            // An image with no description is a REAL defect this read can see:
            // kaya's own lowering always sets one.
            return "menu item image carries no accessibility description"
        }
        return described
    #else
        // THE RENDERED HALF. Both gate conditions are observations, not
        // derivations: `.overflow` is stamped by the chrome body that took the
        // compact arm, and promotion is recomputed from the same helper the bar
        // itself consumes. What answers is neither of them — it is the real bar.
        if let window = kayaScene.windows[0], window.menuPresentation == .overflow,
            kayaPromotedActions(window).contains(where: { $0.id == item.id })
        {
            // THE TOOLBAR VERB'S READ, CALLED — not copied, so a promoted item
            // cannot read one way through expect_toolbar_item and another
            // through here.
            return kayaToolbarIOSItemRead(0, item.label, "symbol")
        }
        // THE UNRENDERED HALF.
        guard item.symbol != 0 else { return "no symbol on the item" }
        guard let sf = kayaSFSymbol(item.symbol), let name = kayaSymbolName(item.symbol) else {
            return "symbol \(item.symbol) is not in this interpreter's table"
        }
        guard UIImage(systemName: sf) != nil else {
            // The rename trap, caught where it actually bites: the name is
            // reported so the reader knows which spelling this OS refused
            // rather than hunting a blank icon.
            return "SF symbol \(sf) does not resolve on this OS"
        }
        return name
    #endif
}

/// The invariant the BARE expect_toolbar step asserts: the promoted set really
/// reached the chrome, and the remainder has somewhere to live. Mirrored from
/// harness.rs's `toolbar_chrome_fits` sentence for sentence. nil means it fits;
/// the failure NAMES THE MEASURED NUMBERS, because the pass cannot.
func kayaToolbarChromeFits(_ spelling: String) -> String? {
    let homes = ["menubar", "more", "overflow", "none"]
    let parts = spelling.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 4, let found = Int(parts[0]), let promoted = Int(parts[1]),
        let items = Int(parts[2]), homes.contains(parts[3])
    else {
        return "chrome reads \"\(spelling)\", which is not "
            + "<promoted found>/<promoted>/<items>/<remainder's home>"
    }
    if found != promoted {
        return "the window's chrome holds \(items) items, and \(found) of the "
            + "\(promoted) promoted actions are among them in catalog preorder"
    }
    if parts[3] == "none" {
        return "the chrome holds the \(found) promoted actions and the remainder "
            + "of the catalog has no home in this window"
    }
    return nil
}

#if os(macOS)
    /// The window's REAL toolbar items, in the order AppKit holds them. Empty
    /// when the window has no toolbar at all, which is exactly what a promotion
    /// list that reached no chrome looks like.
    func kayaToolbarItems(_ windowId: UInt64) -> [NSToolbarItem] {
        let window = kayaNSWindows[windowId] ?? (windowId == 0 ? NSApp.windows.first : nil)
        return window?.toolbar?.items ?? []
    }

    /// THE expect_toolbar READ on macOS: `<promoted found>/<promoted in the
    /// catalog>/<items on the bar>/<remainder's home>`. The first two come from
    /// different sides, so the answer cannot agree with itself; the THIRD
    /// discriminates a bar that never materialized from a mis-filled one.
    func kayaToolbarChromeRead(_ windowId: UInt64) -> String {
        kayaToolbarTrace(windowId)
        let promoted = kayaScene.windows[windowId].map(kayaPromotedActions) ?? []
        var matched = 0
        for item in kayaToolbarItems(windowId)
        where matched < promoted.count && kayaBytesEqual(item.label, promoted[matched].label) {
            matched += 1
        }
        kayaEnsureMenuSegment()
        let owned =
            NSApp.mainMenu.map { mainMenu in
                kayaOwnedMenuItems.filter { $0.menu === mainMenu }.count
            } ?? 0
        return "\(matched)/\(promoted.count)/\(kayaToolbarItems(windowId).count)/"
            + (owned > 0 ? "menubar" : "none")
    }

    /// THE expect_toolbar_item READ on macOS: one aspect of the real toolbar
    /// button, addressed by the label AppKit lifted onto it. ENABLEMENT IS NOT
    /// `NSToolbarItem.isEnabled` (measured 2026-08-16, `true` for a visibly
    /// disabled button), so the read consults the accessibility tree.
    func kayaToolbarItemRead(_ windowId: UInt64, _ label: String, _ aspect: String) -> String {
        kayaToolbarTrace(windowId)
        let items = kayaToolbarItems(windowId)
        guard items.contains(where: { kayaBytesEqual($0.label, label) }) else {
            guard !items.isEmpty else { return "the window has no toolbar" }
            let shown = items.map(\.label).joined(separator: ", ")
            return "no toolbar item labelled \(label) (the toolbar carries: \(shown))"
        }
        return kayaToolbarAxRead(label, aspect)
    }

    /// KAYA_TOOLBAR_TRACE=1 dumps every property of the real toolbar this slice
    /// could have read, plus the accessibility tree under it. It is how the
    /// enablement question was ANSWERED rather than guessed: run the scene,
    /// disable the item halfway through, and read which property moved.
    func kayaToolbarTrace(_ windowId: UInt64) {
        guard ProcessInfo.processInfo.environment["KAYA_TOOLBAR_TRACE"] != nil else { return }
        let window = kayaNSWindows[windowId] ?? (windowId == 0 ? NSApp.windows.first : nil)
        var out = "KAYA_TOOLBAR_TRACE: window \(windowId) toolbar=\(window?.toolbar != nil)\n"
        for (i, item) in kayaToolbarItems(windowId).enumerated() {
            let image = item.image.map {
                "name=\($0.name() ?? "<unnamed>") desc=\($0.accessibilityDescription ?? "<nil>")"
            }
            out += "  [\(i)] id=\(item.itemIdentifier.rawValue) label=\"\(item.label)\" "
            out += "isEnabled=\(item.isEnabled) autovalidates=\(item.autovalidates) "
            out += "image=\(image ?? "nil") "
            out += "view=\(item.view.map { String(describing: type(of: $0)) } ?? "nil")\n"
            if let view = item.view { out += kayaToolbarViewTrace(view, 2) }
        }
        out += kayaToolbarAxTrace()
        FileHandle.standardError.write(Data(out.utf8))
    }

    private func kayaToolbarViewTrace(_ view: NSView, _ depth: Int) -> String {
        if depth > 8 { return "" }
        let pad = String(repeating: "  ", count: depth)
        var out = "\(pad)\(type(of: view)) alpha=\(view.alphaValue) hidden=\(view.isHidden)"
        out += " axRole=\(view.accessibilityRole()?.rawValue ?? "nil")"
        out += " axLabel=\(view.accessibilityLabel() ?? "nil")"
        out += " axTitle=\(view.accessibilityTitle() ?? "nil")"
        if let control = view as? NSControl { out += " controlEnabled=\(control.isEnabled)" }
        out += "\n"
        for sub in view.subviews { out += kayaToolbarViewTrace(sub, depth + 1) }
        return out
    }

    /// The accessibility tree under every AXToolbar, as an assistive
    /// client receives it — role, name and AXEnabled per element.
    private func kayaToolbarAxTrace() -> String {
        let app = kayaToolbarAxApp()
        var out = ""
        func walk(_ element: AXUIElement, _ depth: Int, _ inToolbar: Bool) {
            if depth > 24 { return }
            let role = kayaAxCopy(element, kAXRoleAttribute) as? String ?? "nil"
            let here = inToolbar || role == kAXToolbarRole
            if here {
                let pad = String(repeating: "  ", count: depth)
                let title = kayaAxCopy(element, kAXTitleAttribute) as? String ?? "nil"
                let desc = kayaAxCopy(element, kAXDescriptionAttribute) as? String ?? "nil"
                let enabled = kayaAxCopy(element, kAXEnabledAttribute) as? Bool
                let value = kayaAxCopy(element, kAXValueAttribute) as? String ?? "nil"
                out += "  AX \(pad)role=\(role) title=\(title) desc=\(desc) "
                out += "enabled=\(enabled.map(String.init) ?? "nil") value=\(value)"
                out += " subrole=\(kayaAxCopy(element, kAXSubroleAttribute) as? String ?? "nil")"
                out += " help=\(kayaAxCopy(element, kAXHelpAttribute) as? String ?? "nil")"
                out += " ident=\(kayaAxCopy(element, kAXIdentifierAttribute) as? String ?? "nil")"
                out +=
                    " roledesc=\(kayaAxCopy(element, kAXRoleDescriptionAttribute) as? String ?? "nil")"
                var namesRef: CFArray?
                AXUIElementCopyAttributeNames(element, &namesRef)
                out += " attrs=[\((namesRef as? [String] ?? []).joined(separator: ","))]\n"
            }
            for child in kayaAxKids(element) { walk(child, depth + 1, here) }
        }
        walk(app, 0, false)
        return out.isEmpty ? "  AX (no AXToolbar in the tree)\n" : out
    }

    /// This process's accessibility tree, announced as a client the way
    /// kayaAxReadOnMain announces it — macOS publishes a skeleton with no names
    /// until an assistive client attaches, so an unannounced read would report
    /// "no button here" for a button that is there.
    private func kayaToolbarAxApp() -> AXUIElement {
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 2.0)
        if !kayaAxAnnounced {
            kayaAxAnnounced = true
            AXUIElementSetAttributeValue(
                app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(
                app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        return app
    }

    /// One toolbar button's aspect, out of the accessibility tree: the
    /// element whose spoken name is the item's label, under an AXToolbar.
    private func kayaToolbarAxRead(_ label: String, _ aspect: String) -> String {
        let app = kayaToolbarAxApp()
        var hit: AXUIElement?
        func walk(_ element: AXUIElement, _ depth: Int, _ inToolbar: Bool) {
            if depth > 24 || hit != nil { return }
            let role = kayaAxCopy(element, kAXRoleAttribute) as? String ?? ""
            let here = inToolbar || role == kAXToolbarRole
            if here, role == kAXButtonRole {
                let name =
                    [kAXDescriptionAttribute, kAXTitleAttribute]
                    .lazy
                    .compactMap { kayaAxCopy(element, $0 as String) as? String }
                    .first { !$0.isEmpty } ?? ""
                if kayaBytesEqual(name, label) {
                    hit = element
                    return
                }
            }
            for child in kayaAxKids(element) { walk(child, depth + 1, here) }
        }
        walk(app, 0, false)
        guard let hit else {
            // WHAT THIS MEASURED: the item is on the real toolbar (the caller
            // checked) and the accessibility tree publishes no button by that
            // name under a toolbar. It deliberately does not guess which of the
            // two is wrong.
            return "the toolbar carries \(label), and no accessibility button under it is named that"
        }
        if aspect == "enabled" || aspect == "disabled" {
            // THE MEASURED PROPERTY. `NSToolbarItem.isEnabled` is NOT it: in one
            // trace block this attribute read false for the disabled button
            // while AppKit's flag read true for it and its neighbour
            // (KAYA_TOOLBAR_TRACE, 2026-08-17).
            guard let enabled = kayaAxCopy(hit, kAXEnabledAttribute) as? Bool else {
                return "the toolbar button \(label) publishes no AXEnabled"
            }
            return enabled ? "enabled" : "disabled"
        }
        // THE SEMANTIC ICON, from the identifier the rendering arm published
        // and AppKit carried into the real element — see KayaPromotedLabelMac
        // for why there is no glyph object to read on this lowering.
        guard let ident = kayaAxCopy(hit, kAXIdentifierAttribute) as? String,
            ident.hasPrefix(kayaToolbarSymbolIdent)
        else {
            // WHAT THIS MEASURED: the button is on the real toolbar and no arm
            // of its label published what it drew. Deliberately NOT a fall-back
            // to the item's props — the model is what agreed with itself on iOS
            // for four milestones.
            return "the toolbar button \(label) published no rendered-symbol identifier"
        }
        return String(ident.dropFirst(kayaToolbarSymbolIdent.count))
    }
#endif

#if !os(macOS)
    /// THE REAL BARS UIKit is showing, in the order a walk of the window
    /// hierarchy meets them. SwiftUI's `.toolbar` content on iOS is hosted by
    /// the enclosing NavigationStack's UINavigationBar, so a promoted action
    /// ends up there as a real UIBarButtonItem.
    func kayaToolbarIOSBars() -> [UIView] {
        var bars: [UIView] = []
        func walk(_ view: UIView, _ depth: Int) {
            if depth > 64 { return }
            if view is UINavigationBar || view is UIToolbar { bars.append(view) }
            for sub in view.subviews { walk(sub, depth + 1) }
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { walk(window, 0) }
        }
        return bars
    }

    /// One real bar button, reduced to what the harness asks about — every
    /// field taken off the object UIKit built, none off kaya's model.
    struct KayaToolbarIOSButton {
        /// The spoken name, i.e. what an assistive client is given.
        let name: String
        /// THE GLYPH THIS BUTTON IS REALLY DRAWING, as UIKit names it: the SF
        /// spelling it publishes on the rendered UIImageView's accessibility
        /// identifier. nil is a REAL answer — this button renders no symbol.
        let sfDrawn: String?
        /// The `kaya-toolbar-symbol:` / `kaya-toolbar-more` identifier the
        /// rendering arm published. NOT the symbol answer (that is `sfDrawn`);
        /// it names WHICH ARM drew, which is what a failure sentence needs to
        /// tell "no symbol declared" from "declared and undrawable".
        let ident: String?
        /// Enablement from the `notEnabled` trait on the BUTTON element, measured
        /// to move (1 before the scene's disable, 257 after) while the nested
        /// `_UIModernBarButton` reads 257 throughout — which is why this is
        /// taken off the outermost button.
        let enabled: Bool
    }

    /// EVERY BAR BUTTON THE REAL CHROME IS SHOWING, left to right — promotion is
    /// catalog PREORDER. THE ROUTE IS MEASURED (2026-08-17): `UIKitNavigationBar`
    /// publishes NO bar button items, so the walk is the accessibility tree.
    /// OUTERMOST BUTTONS ONLY, the inner one reporting `notEnabled` when live.
    func kayaToolbarIOSButtons() -> [KayaToolbarIOSButton] {
        var out: [KayaToolbarIOSButton] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ node: NSObject, _ depth: Int) {
            if depth > 32 { return }
            guard seen.insert(ObjectIdentifier(node)).inserted else { return }
            if node.isAccessibilityElement, node.accessibilityTraits.contains(.button) {
                out.append(kayaToolbarIOSReduce(node))
                return
            }
            let count = node.accessibilityElementCount()
            if count != NSNotFound && count > 0 {
                for i in 0..<count {
                    if let child = node.accessibilityElement(at: i) as? NSObject {
                        walk(child, depth + 1)
                    }
                }
            }
            if let view = node as? UIView {
                for sub in view.subviews { walk(sub, depth + 1) }
            }
        }
        for bar in kayaToolbarIOSBars() { walk(bar, 0) }
        return out
    }

    private func kayaToolbarIOSReduce(_ button: NSObject) -> KayaToolbarIOSButton {
        let name =
            [button.accessibilityLabel, button.accessibilityValue]
            .lazy
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? ""
        // THE RENDERED GLYPH: UIKit publishes the SF symbol name on the image
        // view it built (measured), so this is the platform's own record of what
        // is on screen. A button that fell to its text arm has no image view.
        var sfDrawn: String?
        func findGlyph(_ node: NSObject, _ depth: Int) {
            if depth > 16 || sfDrawn != nil { return }
            if node is UIImageView, let ident = kayaAxIdentifier(node) {
                sfDrawn = ident
                return
            }
            if let view = node as? UIView {
                for sub in view.subviews { findGlyph(sub, depth + 1) }
            }
        }
        findGlyph(button, 0)
        return KayaToolbarIOSButton(
            name: name, sfDrawn: sfDrawn, ident: kayaAxIdentifier(button),
            enabled: !button.accessibilityTraits.contains(.notEnabled))
    }

    /// The SEMANTIC name for a glyph the chrome is really drawing, by inverting
    /// the table the lowering drew through. TWO SPELLINGS PER ROW, since SwiftUI
    /// resolves an aliased SF name before UIKit builds the image (all 20 rows
    /// measured, iOS 26.5). DELIBERATELY NO FALL-BACK to kaya's own identifier.
    func kayaToolbarIOSSemantic(_ rendered: String) -> String? {
        kayaSymbolTable.first { $0.sf == rendered || $0.rendered == rendered }?.name
    }

    /// The symbol aspect of one real bar button, or a sentence saying what was
    /// measured instead. Shared by expect_toolbar_item and by
    /// expect_menu_symbol's promoted half — one read, so the two verbs cannot
    /// disagree about the same button.
    func kayaToolbarIOSSymbolOf(_ button: KayaToolbarIOSButton) -> String {
        guard let sf = button.sfDrawn else {
            // WHAT THIS MEASURED: the button is on the real bar and UIKit built
            // no glyph image under it. The arm's identifier rides along to tell
            // "declared no symbol" from "declared one this OS would not draw" —
            // a second measurement, never the answer.
            let arm = button.ident.map { $0.hasPrefix(kayaToolbarSymbolIdent)
                ? " (\(String($0.dropFirst(kayaToolbarSymbolIdent.count))))" : "" } ?? ""
            return "the toolbar button \(button.name) renders no symbol image\(arm)"
        }
        guard let semantic = kayaToolbarIOSSemantic(sf) else {
            // WHAT THIS MEASURED: a real glyph, in a spelling no row carries in
            // EITHER column. Two causes it cannot tell apart — an arm outside
            // this vocabulary, or a rename the rendered column has not measured
            // — so both are named and the glyph is printed either way.
            return "the toolbar button \(button.name) renders the glyph \(sf), which no row "
                + "of this interpreter's table spells (a glyph outside the vocabulary, or a "
                + "row this OS renames to a spelling the table has not measured)"
        }
        return semantic
    }

    /// The identifier the More menu's trigger publishes, so the chrome read can
    /// find the remainder's home on the REAL bar without matching an English
    /// word — the label "More" is dress and a localized build would move it.
    let kayaToolbarMoreIdent = "kaya-toolbar-more"

    /// THE expect_toolbar READ on iOS, the macOS arm's spelling exactly. The
    /// first two numbers come from different sides ON PURPOSE, so an answer
    /// computed once cannot agree with itself. The remainder's home is the MORE
    /// menu, and this LOOKS FOR IT rather than assuming the arm ran.
    func kayaToolbarIOSChromeRead(_ windowId: UInt64) -> String {
        kayaAxEnableAutomation()
        kayaToolbarIOSTrace(windowId)
        let promoted = kayaScene.windows[windowId].map(kayaPromotedActions) ?? []
        let buttons = kayaToolbarIOSButtons()
        var matched = 0
        for button in buttons
        where matched < promoted.count && kayaBytesEqual(button.name, promoted[matched].label) {
            matched += 1
        }
        let more = buttons.contains { $0.ident == kayaToolbarMoreIdent }
        return "\(matched)/\(promoted.count)/\(buttons.count)/" + (more ? "more" : "none")
    }

    /// THE expect_toolbar_item READ on iOS: one aspect of the real bar button,
    /// addressed by the name UIKit publishes for it. TOTAL, like
    /// kayaMenuStateRead: every failure is a short description and a retryable
    /// non-match, never a panic.
    func kayaToolbarIOSItemRead(_ windowId: UInt64, _ label: String, _ aspect: String) -> String {
        kayaAxEnableAutomation()
        kayaToolbarIOSTrace(windowId)
        let buttons = kayaToolbarIOSButtons()
        guard let hit = buttons.first(where: { kayaBytesEqual($0.name, label) }) else {
            guard !buttons.isEmpty else { return "the window has no toolbar" }
            let shown = buttons.map(\.name).joined(separator: ", ")
            return "no toolbar item labelled \(label) (the toolbar carries: \(shown))"
        }
        if aspect == "enabled" || aspect == "disabled" {
            // THE MEASURED PROPERTY: the `notEnabled` trait on the real button
            // element, where SwiftUI's `.disabled` lands. UIKit offers no second
            // flag to prefer it over — this bar has no UIBarButtonItem at all —
            // so unlike the macOS sibling there is no disagreement to report.
            return hit.enabled ? "enabled" : "disabled"
        }
        return kayaToolbarIOSSymbolOf(hit)
    }

    /// KAYA_TOOLBAR_TRACE=1 dumps every property of the real bar this read could
    /// have consulted, plus each button's accessibility subtree: how the
    /// enablement and symbol questions were ANSWERED rather than guessed.
    func kayaToolbarIOSTrace(_ windowId: UInt64) {
        guard ProcessInfo.processInfo.environment["KAYA_TOOLBAR_TRACE"] != nil else { return }
        var out = "KAYA_TOOLBAR_TRACE: window \(windowId) bars=\(kayaToolbarIOSBars().count)\n"
        for bar in kayaToolbarIOSBars() {
            out += "  bar \(type(of: bar)) frame=\(bar.frame)"
            if let nav = bar as? UINavigationBar {
                out += " topTitle=\(nav.topItem?.title ?? "nil")"
                out += " left=\(nav.topItem?.leftBarButtonItems?.count ?? -1)"
                out += " right=\(nav.topItem?.rightBarButtonItems?.count ?? -1)"
            }
            out += "\n"
        }
        for (i, button) in kayaToolbarIOSButtons().enumerated() {
            out += "  [\(i)] name=\"\(button.name)\" sfDrawn=\(button.sfDrawn ?? "nil") "
            out += "ident=\(button.ident ?? "nil") enabled=\(button.enabled) "
            out += "semantic=\(button.sfDrawn.flatMap(kayaToolbarIOSSemantic) ?? "nil")\n"
        }
        // EVERY RENDERED GLYPH, as an object AND as UIKit names it. The
        // identifier is what the read inverts; the image's description is what
        // says whether a name that failed to invert was renamed under the table
        // or drawn off it.
        for bar in kayaToolbarIOSBars() {
            func dumpImages(_ view: UIView, _ depth: Int) {
                if depth > 24 { return }
                if let imageView = view as? UIImageView {
                    out += "  glyph ident=\(kayaAxIdentifier(imageView) ?? "nil") "
                    out += "image=\(imageView.image.map { String(describing: $0) } ?? "nil")\n"
                }
                for sub in view.subviews { dumpImages(sub, depth + 1) }
            }
            dumpImages(bar, 0)
        }
        // THE WHOLE SUBTREE, which is how the route above was CHOSEN: the
        // UIBarButtonItem route this trace was first written for dumped nothing
        // at all (topItem nil), and these lines are where the buttons, their
        // traits and the glyph identifiers were found instead.
        for bar in kayaToolbarIOSBars() {
            var seen = Set<ObjectIdentifier>()
            func dump(_ node: NSObject, _ depth: Int) {
                if depth > 32 { return }
                guard seen.insert(ObjectIdentifier(node)).inserted else { return }
                out += "    \(String(repeating: " ", count: depth))el \(type(of: node)) "
                out += "label=\(node.accessibilityLabel ?? "nil") "
                out += "ident=\(kayaAxIdentifier(node) ?? "nil") "
                out += "isElement=\(node.isAccessibilityElement) "
                out += "traits=\(node.accessibilityTraits.rawValue) "
                out += "frame=\((node as? UIView).map { String(describing: $0.frame) } ?? "-")\n"
                let count = node.accessibilityElementCount()
                if count != NSNotFound && count > 0 {
                    for i in 0..<count {
                        if let child = node.accessibilityElement(at: i) as? NSObject {
                            dump(child, depth + 1)
                        }
                    }
                }
                if let view = node as? UIView {
                    for sub in view.subviews { dump(sub, depth + 1) }
                }
            }
            dump(bar, 0)
        }
        FileHandle.standardError.write(Data(out.utf8))
    }
#endif

#if os(macOS)
    /// One real section switcher row, reduced to the two things the verb asks
    /// about, each taken off the element AppKit built.
    struct KayaSectionRowMac {
        /// What the row is SPOKEN as — its title.
        let name: String
        /// The identifier the rendering arm published, still prefixed.
        let ident: String?
        /// The AX role it was found under, for the miss sentence.
        let role: String
    }

    /// EVERY SECTION SWITCHER ROW this process is showing, in accessibility-tree
    /// order, from every window. A ROW IS AN ELEMENT THE RENDER STAMPED, not a
    /// role: the two macOS switchers publish different roles, and a role list is
    /// a claim a release can falsify. The spoken name comes from AppKit.
    func kayaSectionRowsMac() -> [KayaSectionRowMac] {
        let app = kayaToolbarAxApp()
        var rows: [KayaSectionRowMac] = []
        func nameOf(_ element: AXUIElement, _ depth: Int) -> String {
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                if let text = kayaAxCopy(element, attribute as String) as? String, !text.isEmpty {
                    return text
                }
            }
            // A List row publishes its text on a static-text descendant rather
            // than on itself; the tab items name themselves.
            if depth < 4 {
                for child in kayaAxKids(element) {
                    let text = nameOf(child, depth + 1)
                    if !text.isEmpty { return text }
                }
            }
            return ""
        }
        func walk(_ element: AXUIElement, _ depth: Int) {
            if depth > 24 { return }
            if let ident = kayaAxCopy(element, kAXIdentifierAttribute) as? String,
                ident.hasPrefix(kayaSectionSymbolIdent)
            {
                rows.append(
                    KayaSectionRowMac(
                        name: nameOf(element, 0),
                        ident: ident,
                        role: kayaAxCopy(element, kAXRoleAttribute) as? String ?? "nil"))
                return
            }
            for child in kayaAxKids(element) { walk(child, depth + 1) }
        }
        walk(app, 0)
        return rows
    }

    /// THE expect_section_symbol READ on macOS. TOTAL, like
    /// kayaToolbarItemRead: every failure is a short description and a retryable
    /// non-match, which is also the wait for the switcher to finish building.
    func kayaSectionSymbolReadMac(_ title: String) -> String {
        kayaSectionTrace()
        let rows = kayaSectionRowsMac()
        guard let hit = rows.first(where: { kayaBytesEqual($0.name, title) }) else {
            guard !rows.isEmpty else {
                // WHAT THIS MEASURED: no element in the whole accessibility
                // tree carries a section row's stamp. It says nothing about
                // which window is showing — the reader cannot tell "the switcher
                // is not built yet" from "the render arm stopped stamping".
                return "no section rows are in the accessibility tree"
            }
            let shown = rows.map(\.name).joined(separator: ", ")
            return "no section row titled \(title) (the switchers carry: \(shown))"
        }
        guard let ident = hit.ident else {
            return "the section row \(title) published no rendered-symbol identifier"
        }
        // THE ANSWER IS THE STAMP, and its limit is stated: what the arm SAID it
        // drew, not the glyph. macOS publishes no image object for either
        // switcher (measured), and deliberately NO fall-back to section.symbol,
        // the copy that was garbage while every lane stayed green.
        return String(ident.dropFirst(kayaSectionSymbolIdent.count))
    }
#endif

#if !os(macOS)
    /// EVERY SECTION SWITCHER ROW UIKit is showing: the tab bar's button
    /// elements, each reduced to (spoken name, rendered glyph name, kaya stamp).
    /// THE OUTERMOST ELEMENT ONLY, kayaToolbarIOSButtons' rule: a walk that
    /// descended into a tab button would meet the same row twice.
    func kayaSectionRowsIOS() -> [(name: String, sfDrawn: String?, ident: String?)] {
        var bars: [UIView] = []
        func findBars(_ view: UIView, _ depth: Int) {
            if depth > 64 { return }
            if view is UITabBar { bars.append(view) }
            for sub in view.subviews { findBars(sub, depth + 1) }
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { findBars(window, 0) }
        }
        var out: [(name: String, sfDrawn: String?, ident: String?)] = []
        var seen = Set<ObjectIdentifier>()
        func glyphUnder(_ node: NSObject, _ depth: Int) -> String? {
            if depth > 16 { return nil }
            if node is UIImageView, let ident = kayaAxIdentifier(node) { return ident }
            if let view = node as? UIView {
                for sub in view.subviews {
                    if let found = glyphUnder(sub, depth + 1) { return found }
                }
            }
            return nil
        }
        func walk(_ node: NSObject, _ depth: Int) {
            if depth > 32 { return }
            guard seen.insert(ObjectIdentifier(node)).inserted else { return }
            if node.isAccessibilityElement,
                node.accessibilityTraits.contains(.button)
                    || node.accessibilityTraits.rawValue & UIAccessibilityTraits.selected.rawValue
                        != 0
            {
                out.append(
                    (
                        name: node.accessibilityLabel ?? "",
                        sfDrawn: glyphUnder(node, 0),
                        ident: kayaAxIdentifier(node)
                    ))
                return
            }
            let count = node.accessibilityElementCount()
            if count != NSNotFound && count > 0 {
                for i in 0..<count {
                    if let child = node.accessibilityElement(at: i) as? NSObject {
                        walk(child, depth + 1)
                    }
                }
            }
            if let view = node as? UIView {
                for sub in view.subviews { walk(sub, depth + 1) }
            }
        }
        for bar in bars { walk(bar, 0) }
        return out
    }

    /// A RENDERED TAB GLYPH, back to kaya's vocabulary. THE FILLED-VARIANT
    /// FINDING (iOS 26.5), and why this is not `kayaToolbarIOSSemantic`: a
    /// UITabBar draws the FILLED variant of whatever it is given, a THIRD naming
    /// relationship beside `rendered`. STILL NO FALL-BACK to kaya's stamp.
    func kayaSectionIOSSemantic(_ rendered: String) -> String? {
        if let name = kayaToolbarIOSSemantic(rendered) { return name }
        if rendered.hasSuffix(".fill") {
            return kayaToolbarIOSSemantic(String(rendered.dropLast(".fill".count)))
        }
        return nil
    }

    /// THE expect_section_symbol READ on iOS: the GLYPH the row really draws,
    /// inverted through EITHER column of kayaSymbolTable, since SwiftUI resolves
    /// an SF alias before UIKit builds the image. AND NO FALL-BACK TO THE STAMP.
    func kayaSectionSymbolReadIOS(_ title: String) -> String {
        kayaAxEnableAutomation()
        kayaSectionTrace()
        let rows = kayaSectionRowsIOS()
        guard let hit = rows.first(where: { kayaBytesEqual($0.name, title) }) else {
            guard !rows.isEmpty else { return "the window has no section switcher" }
            let shown = rows.map(\.name).joined(separator: ", ")
            return "no section row titled \(title) (the switchers carry: \(shown))"
        }
        guard let drawn = hit.sfDrawn else {
            // MEASURED: the row is in the real bar and no image view under it
            // publishes a glyph name. The stamp rides the sentence as a
            // DIAGNOSTIC — it says which arm drew — and is never the answer.
            return "the section row \(title) draws no glyph (it stamped \(hit.ident ?? "nothing"))"
        }
        guard let semantic = kayaSectionIOSSemantic(drawn) else {
            return
                "the section row \(title) renders the glyph \(drawn), which is not in this "
                + "interpreter's table — a glyph outside the vocabulary, or a row this OS "
                + "renames to a spelling the table has not measured"
        }
        return semantic
    }
#endif

/// KAYA_SECTION_TRACE=1 dumps every surface a section-symbol read could have
/// consulted: how the channel on each host was ANSWERED rather than guessed.
/// Run the sections scene and read which property carries the glyph.
func kayaSectionTrace() {
    guard ProcessInfo.processInfo.environment["KAYA_SECTION_TRACE"] != nil else { return }
    var out = "KAYA_SECTION_TRACE:\n"
    #if os(macOS)
        let app = kayaToolbarAxApp()
        func walk(_ element: AXUIElement, _ depth: Int) {
            if depth > 24 { return }
            let role = kayaAxCopy(element, kAXRoleAttribute) as? String ?? "nil"
            let pad = String(repeating: " ", count: depth)
            out += "  \(pad)role=\(role)"
            out += " sub=\(kayaAxCopy(element, kAXSubroleAttribute) as? String ?? "nil")"
            out += " title=\(kayaAxCopy(element, kAXTitleAttribute) as? String ?? "nil")"
            out += " desc=\(kayaAxCopy(element, kAXDescriptionAttribute) as? String ?? "nil")"
            out += " value=\(kayaAxCopy(element, kAXValueAttribute) as? String ?? "nil")"
            out += " ident=\(kayaAxCopy(element, kAXIdentifierAttribute) as? String ?? "nil")\n"
            for child in kayaAxKids(element) { walk(child, depth + 1) }
        }
        walk(app, 0)
        for row in kayaSectionRowsMac() {
            out += "  row name=\"\(row.name)\" role=\(row.role) ident=\(row.ident ?? "nil")\n"
        }
    #else
        kayaAxEnableAutomation()
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                func dump(_ node: NSObject, _ depth: Int) {
                    if depth > 24 { return }
                    let pad = String(repeating: " ", count: depth)
                    out += "  \(pad)el \(type(of: node)) label=\(node.accessibilityLabel ?? "nil")"
                    out += " ident=\(kayaAxIdentifier(node) ?? "nil")"
                    out += " isElement=\(node.isAccessibilityElement)"
                    out += " traits=\(node.accessibilityTraits.rawValue)\n"
                    let count = node.accessibilityElementCount()
                    if count != NSNotFound && count > 0 {
                        for i in 0..<count {
                            if let child = node.accessibilityElement(at: i) as? NSObject {
                                dump(child, depth + 1)
                            }
                        }
                    }
                    if let view = node as? UIView {
                        for sub in view.subviews { dump(sub, depth + 1) }
                    }
                }
                dump(window, 0)
            }
        }
        for row in kayaSectionRowsIOS() {
            out += "  row name=\"\(row.name)\" glyph=\(row.sfDrawn ?? "nil") "
            out += "ident=\(row.ident ?? "nil") "
            out += "toolbarSemantic=\(row.sfDrawn.flatMap(kayaToolbarIOSSemantic) ?? "nil") "
            out += "semantic=\(row.sfDrawn.flatMap(kayaSectionIOSSemantic) ?? "nil")\n"
        }
    #endif
    FileHandle.standardError.write(Data(out.utf8))
}

/// The expect_menu read: wherever the item surfaced — the OPEN context menu
/// first, then the bar. macOS reads the REAL NSMenuItem state; iOS reads the
/// model, since SwiftUI exposes no item registry and every aspect here rides a
/// modifier the row applies (which stopped being true for the icon).
func kayaMenuStateRead(_ path: String, _ aspect: KayaMenuAspect) -> String {
    if let wid = kayaOpenContextWidget {
        // Open-context EXCLUSIVITY: while presented, the context menu owns
        // resolution — a miss reads as the retryable "no such item", never a
        // bar fallback.
        guard let roots = kayaScene.contextRoots[wid],
            let item = kayaResolveMenuPath(path, roots: roots)
        else { return "no such item" }
        return kayaModelMenuState(item, aspect)
    }
    guard let item = kayaResolveMenuPath(path, roots: kayaPresentedCatalog()) else {
        return "no such item"
    }
    #if os(macOS)
        kayaEnsureMenuSegment()
        switch aspect {
        case .enablement:
            guard let nsItem = kayaOwnedNSMenuItem(item.id) else { return "no such item" }
            // A STANDARD COMMAND'S ENABLEMENT IS NOT A BUILD-TIME FACT:
            // `update()` on a menu with autoenablesItems=false validates nothing
            // and never reaches the delegate — measured, this read answering
            // with the state the item was BORN with.
            kayaRefreshRoleEnablement()
            // VALIDATED state, not merely the state we set: AppKit settles an
            // item's enablement as its menu is about to display, so this reads
            // what the user's next click gets (docs/traps.md). A grouping node
            // sits in the DRESS-owned main menu and keeps its declared state.
            if let owner = nsItem.menu, owner !== NSApp.mainMenu {
                owner.update()
            }
            return nsItem.isEnabled ? "enabled" : "disabled"
        case .checkedness:
            guard let nsItem = kayaOwnedNSMenuItem(item.id) else { return "no such item" }
            return nsItem.state == .on ? "checked" : "unchecked"
        case .value:
            // The group's value IS its checked option, read from the real items
            // (the checkmark idiom).
            for (index, option) in item.children.enumerated() {
                if let nsItem = kayaOwnedNSMenuItem(option.id), nsItem.state == .on {
                    return "value \(index)"
                }
            }
            return "no checked option"
        }
    #else
        return kayaModelMenuState(item, aspect)
    #endif
}

#if os(macOS)
    /// The kaya window whose catalog the global bar presents: the key kaya
    /// window, swapped by the key-window observer; the primary until any other
    /// kaya window takes key (accessory-policy suite runs never grant key
    /// status, which correctly leaves the primary's catalog presented).
    var kayaPresentedMenuWindow: UInt64 = 0
    /// The Kaya-owned SEGMENT of NSApp.mainMenu, in catalog order. Everything
    /// outside it — application menu, Edit, Window, Help — is dress and never
    /// touched.
    var kayaOwnedMenuItems: [NSMenuItem] = []
    var kayaMenuObserversInstalled = false
    /// Re-entrancy guard: our own inserts/removals fire the same NSMenu
    /// notifications we observe.
    var kayaMenuSyncing = false
    var kayaMenuResyncPending = false
    var kayaMainMenuKVO: NSKeyValueObservation?

    /// The one target of every owned NSMenuItem: routes the REAL AppKit action
    /// back into the shared dispatch path.
    final class KayaMenuDispatcher: NSObject {
        @objc func fire(_ sender: NSMenuItem) {
            guard let number = sender.representedObject as? NSNumber,
                let item = kayaScene.menuItems[number.uint64Value]
            else { return }
            kayaMenuUserActivate(item)
        }

        /// Kaya-owned menus set `autoenablesItems = false`, so this is dead
        /// weight for the segment — but the role item lands in the DRESS-owned
        /// application menu, which validates. Answering with the inherited AND
        /// keeps that item's enablement ours instead of AppKit's (docs/traps.md).
        @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
            guard let number = item.representedObject as? NSNumber,
                let model = kayaScene.menuItems[number.uint64Value]
            else { return true }
            return kayaMenuEffectiveEnabled(model)
        }
    }
    let kayaMenuDispatch = KayaMenuDispatcher()

    /// The canonical shortcut spelling (root-validated) onto AppKit's key
    /// equivalent. `primary` = Command on Apple hosts. The same mapping builds
    /// NSMenuItem chords and the verb's synthetic key event, so matching is by
    /// construction.
    func kayaKeyEquivalent(_ spelling: String) -> (String, NSEvent.ModifierFlags)? {
        var mask: NSEvent.ModifierFlags = []
        var key: String?
        for part in spelling.split(separator: "+").map(String.init) {
            switch part {
            case "primary": mask.insert(.command)
            case "shift": mask.insert(.shift)
            case "alt": mask.insert(.option)
            default: key = kayaKeyChar(part)
            }
        }
        guard let key else { return nil }
        return (key, mask)
    }

    private func kayaKeyChar(_ name: String) -> String? {
        switch name {
        case "enter": return "\r"
        case "delete": return "\u{08}"
        case "left": return String(UnicodeScalar(0xF702 as UInt32)!)
        case "right": return String(UnicodeScalar(0xF703 as UInt32)!)
        case "up": return String(UnicodeScalar(0xF700 as UInt32)!)
        case "down": return String(UnicodeScalar(0xF701 as UInt32)!)
        // The punctuation set names UNSHIFTED US positions; AppKit takes the
        // character itself and draws the chord its own way.
        case "comma": return ","
        case "period": return "."
        case "slash": return "/"
        case "backslash": return "\\"
        case "minus": return "-"
        case "equal": return "="
        case "leftbracket": return "["
        case "rightbracket": return "]"
        default:
            // escape never arrives (the root rejects every spelling);
            // fN maps into the function-key private-use plane.
            if name.hasPrefix("f"), let n = Int(name.dropFirst()), (1...12).contains(n) {
                return String(UnicodeScalar(0xF704 as UInt32 + UInt32(n) - 1)!)
            }
            return name.count == 1 ? name : nil
        }
    }

    /// Builds one grouping node's submenu content. A nested menu cascades; a
    /// radio_group materializes INLINE with the checkmark idiom.
    private func kayaBuildNSMenuItems(into menu: NSMenu, children: [KayaMenuItemModel]) {
        for child in children {
            switch child.kind {
            case menuKindSeparator:
                menu.addItem(NSMenuItem.separator())
            case menuKindMenu:
                let holder = NSMenuItem(title: child.label, action: nil, keyEquivalent: "")
                holder.representedObject = NSNumber(value: child.id)
                holder.isEnabled = kayaMenuEffectiveEnabled(child)
                let submenu = NSMenu(title: child.label)
                submenu.autoenablesItems = false  // docs/traps.md
            submenu.delegate = kayaMenuRefresher
                kayaApplySymbol(holder, child.symbol)
                kayaBuildNSMenuItems(into: submenu, children: child.children)
                holder.submenu = submenu
                menu.addItem(holder)
            case menuKindRadioGroup:
                for (index, option) in child.children.enumerated() {
                    let nsItem = NSMenuItem(
                        title: option.label,
                        action: #selector(KayaMenuDispatcher.fire(_:)), keyEquivalent: "")
                    nsItem.target = kayaMenuDispatch
                    nsItem.representedObject = NSNumber(value: option.id)
                    nsItem.isEnabled = kayaMenuEffectiveEnabled(option)
                    nsItem.state = Int(child.value) == index ? .on : .off
                    kayaApplySymbol(nsItem, option.symbol)
                    kayaApplyKeyEquivalent(nsItem, option.shortcut)
                    menu.addItem(nsItem)
                }
            case menuKindAction, menuKindToggle:
                // A role relocates its item: `settings` is rendered in the
                // application menu instead of here, so it must not also appear
                // in the menu that declared it.
                if child.role == "settings" { continue }
                let nsItem = NSMenuItem(
                    title: child.label,
                    action: #selector(KayaMenuDispatcher.fire(_:)), keyEquivalent: "")
                nsItem.target = kayaMenuDispatch
                nsItem.representedObject = NSNumber(value: child.id)
                nsItem.isEnabled = kayaMenuEffectiveEnabled(child)
                if child.kind == menuKindToggle {
                    nsItem.state = child.checked ? .on : .off
                }
                kayaApplySymbol(nsItem, child.symbol)
                // A chord rides any leaf command: "Show Sidebar" wants its
                // checkmark AND its key, and AppKit has never cared which kind
                // of item carries a key equivalent.
                kayaApplyKeyEquivalent(nsItem, child.shortcut)
                menu.addItem(nsItem)
            default:
                break  // radio_option outside its group: the closed grammar forbids it
            }
        }
    }

    /// One place applies a SEMANTIC ICON to a native item, so every leaf and
    /// grouping kind gets identical treatment and an unset symbol is simply no
    /// image. The image carries the semantic name as its accessibility
    /// description — see kayaSymbolImage.
    private func kayaApplySymbol(_ nsItem: NSMenuItem, _ symbol: Int64) {
        guard symbol != 0 else { return }
        nsItem.image = kayaSymbolImage(symbol)
    }

    /// One place applies a chord to a native item, so every leaf kind
    /// gets identical treatment and an empty spelling is simply no key.
    private func kayaApplyKeyEquivalent(_ nsItem: NSMenuItem, _ spelling: String) {
        guard !spelling.isEmpty, let (key, mask) = kayaKeyEquivalent(spelling) else { return }
        nsItem.keyEquivalent = key
        nsItem.keyEquivalentModifierMask = mask
    }

    /// The segment's insertion point among DRESS items: after the Edit dress,
    /// before Window/Help. Anchors are locale-independent — Edit by its native
    /// actions (copy:/paste: survive localization), Window/Help by NSApp's own
    /// menu handles.
    private func kayaMenuInsertionIndex(_ items: [NSMenuItem]) -> Int {
        let editActions = [#selector(NSText.copy(_:)), #selector(NSText.paste(_:))]
        let editByAction = items.firstIndex(where: { item in
            guard let submenu = item.submenu else { return false }
            return submenu.items.contains { child in
                guard let action = child.action else { return false }
                return editActions.contains(action)
            }
        })
        if let edit = editByAction ?? items.firstIndex(where: { $0.title == "Edit" }) {
            return edit + 1
        }
        if let windowsMenu = NSApp.windowsMenu,
            let window = items.firstIndex(where: { $0.submenu === windowsMenu })
        {
            return window
        }
        if let helpMenu = NSApp.helpMenu,
            let help = items.firstIndex(where: { $0.submenu === helpMenu })
        {
            return help
        }
        return items.count
    }

    /// Rebuild and re-insert the owned segment from the presented window's
    /// catalog — always from the model (docs/traps.md, "A native menu rebuild
    /// must start from the post-user mirror").
    func kayaSyncMacMenuBar() {
        kayaMenuSyncing = true
        defer { kayaMenuSyncing = false }
        for old in kayaOwnedMenuItems { old.menu?.removeItem(old) }
        kayaOwnedMenuItems.removeAll()
        let catalog = kayaPresentedCatalog()
        guard !catalog.isEmpty else { return }
        // Accessory-policy processes still carry a SwiftUI-built main menu; if
        // none exists yet there is no dress to preserve and the segment IS the
        // bar.
        let mainMenu = NSApp.mainMenu ?? {
            let menu = NSMenu()
            menu.autoenablesItems = false  // docs/traps.md
            menu.delegate = kayaMenuRefresher
            NSApp.mainMenu = menu
            return menu
        }()
        // Owned items are already removed above, so this list is the dress alone
        // — the insertion index's required view.
        var index = kayaMenuInsertionIndex(mainMenu.items)
        for top in catalog {
            let holder = NSMenuItem(title: top.label, action: nil, keyEquivalent: "")
            holder.representedObject = NSNumber(value: top.id)
            holder.isEnabled = kayaMenuEffectiveEnabled(top)
            kayaApplySymbol(holder, top.symbol)
            let submenu = NSMenu(title: top.label)
            submenu.autoenablesItems = false  // docs/traps.md
            submenu.delegate = kayaMenuRefresher
            // A bar-level radio_group is a top-level menu whose options use the
            // checkmark idiom — the same inline materialization, one level up.
            kayaBuildNSMenuItems(
                into: submenu,
                children: top.kind == menuKindRadioGroup ? [top] : top.children)
            holder.submenu = submenu
            mainMenu.insertItem(holder, at: min(index, mainMenu.items.count))
            kayaOwnedMenuItems.append(holder)
            index += 1
        }
        // The one place a role may enter dress-owned chrome. macOS expects
        // Settings in the application menu, so the item MOVES there; the model
        // keeps it where the app declared it, so paths, reads and activation are
        // unaffected. The role never invents a chord.
        if let settings = kayaCatalogRoleItem("settings", kayaPresentedCatalog()),
            let appMenu = mainMenu.items.first?.submenu
        {
            let nsItem = NSMenuItem(
                title: settings.label,
                action: #selector(KayaMenuDispatcher.fire(_:)), keyEquivalent: "")
            nsItem.target = kayaMenuDispatch
            nsItem.representedObject = NSNumber(value: settings.id)
            nsItem.isEnabled = kayaMenuEffectiveEnabled(settings)
            // The relocated item keeps its icon: the move is placement
            // only, and every other prop follows it.
            kayaApplySymbol(nsItem, settings.symbol)
            kayaApplyKeyEquivalent(nsItem, settings.shortcut)
            appMenu.insertItem(nsItem, at: kayaSettingsInsertionIndex(appMenu.items))
            kayaOwnedMenuItems.append(nsItem)
        }
    }

    /// The catalog item claiming a role, if any (the root allows one).
    private func kayaCatalogRoleItem(
        _ role: String, _ roots: [KayaMenuItemModel]
    ) -> KayaMenuItemModel? {
        for item in roots {
            if item.role == role { return item }
            if let found = kayaCatalogRoleItem(role, item.children) { return found }
        }
        return nil
    }

    /// Where Settings sits in an application menu: after the separator that
    /// follows About. Falling back to the end keeps a stripped app menu from
    /// losing the item.
    private func kayaSettingsInsertionIndex(_ items: [NSMenuItem]) -> Int {
        if let separator = items.firstIndex(where: { $0.isSeparatorItem }) {
            return separator + 1
        }
        return items.count
    }

    /// Idempotent segment assert — the kayaEnsureOpen shape: belt, not the fix
    /// (the observers below are the event-driven re-assert docs/traps.md
    /// requires); free when the segment already sits in the current main menu.
    func kayaEnsureMenuSegment() {
        if let mainMenu = NSApp.mainMenu, !kayaOwnedMenuItems.isEmpty {
            // Membership alone is not placement: a dress mutation can displace
            // or split the owned run. The segment must sit CONTIGUOUSLY, in
            // catalog order, at the insertion index the remaining dress
            // computes — anything else re-syncs.
            let items = mainMenu.items
            let dress = items.filter { item in
                !kayaOwnedMenuItems.contains(where: { $0 === item })
            }
            let start = kayaMenuInsertionIndex(dress)
            if items.count == dress.count + kayaOwnedMenuItems.count,
                start + kayaOwnedMenuItems.count <= items.count,
                kayaOwnedMenuItems.enumerated().allSatisfy({ offset, owned in
                    items[start + offset] === owned
                })
            {
                return
            }
            kayaSyncMacMenuBar()
            return
        }
        if kayaPresentedCatalog().isEmpty && kayaOwnedMenuItems.isEmpty { return }
        kayaSyncMacMenuBar()
    }

    /// Coalesce re-asserts: reacting inside a menu's own change notification
    /// mutates the menu being changed, so the sync hops one main-queue turn.
    func kayaScheduleMenuResync() {
        guard !kayaMenuResyncPending else { return }
        kayaMenuResyncPending = true
        DispatchQueue.main.async {
            kayaMenuResyncPending = false
            kayaEnsureMenuSegment()
        }
    }

    /// The model-changed rebuild, likewise one turn out (and coalesced):
    /// kayaMenuChanged can fire from a dispatcher action running inside
    /// performActionForItem on the owned menu itself.
    var kayaMenuRebuildPending = false
    func kayaScheduleMenuRebuild() {
        guard !kayaMenuRebuildPending else { return }
        kayaMenuRebuildPending = true
        DispatchQueue.main.async {
            kayaMenuRebuildPending = false
            kayaSyncMacMenuBar()
        }
    }

    /// The EVENT-DRIVEN re-assert (docs/traps.md, "AppKit menus auto-enable
    /// through the responder chain by default"): SwiftUI rebuilding the bar
    /// fires the NSMenu item notifications or replaces NSApp.mainMenu (KVO);
    /// key-window changes swap the catalog.
    func kayaInstallMenuObservers() {
        guard !kayaMenuObserversInstalled else { return }
        kayaMenuObserversInstalled = true
        let center = NotificationCenter.default
        center.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            guard let window = note.object as? NSWindow,
                let wid = kayaNSWindows.first(where: { $0.value === window })?.key
            else { return }
            if kayaPresentedMenuWindow != wid {
                kayaPresentedMenuWindow = wid
                kayaMenuChanged()
            } else {
                kayaScheduleMenuResync()
            }
        }
        for name in [NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard !kayaMenuSyncing, let menu = note.object as? NSMenu,
                    menu === NSApp.mainMenu
                else { return }
                kayaScheduleMenuResync()
            }
        }
        kayaMainMenuKVO = NSApp.observe(\.mainMenu) { _, _ in
            if !kayaMenuSyncing { kayaScheduleMenuResync() }
        }
    }

    /// The owned segment's NSMenuItem for a menu item id (depth-first
    /// over the segment only — dress is never read).
    func kayaOwnedNSMenuItem(_ id: UInt64) -> NSMenuItem? {
        func search(_ items: [NSMenuItem]) -> NSMenuItem? {
            for item in items {
                if (item.representedObject as? NSNumber)?.uint64Value == id { return item }
                if let submenu = item.submenu, let found = search(submenu.items) {
                    return found
                }
            }
            return nil
        }
        return search(kayaOwnedMenuItems)
    }

    /// menu_activate's macOS bar route, resolved SEMANTICALLY: the materialized
    /// NSMenuItem is found by IDENTITY, never by title-walking the chrome. A
    /// STANDARD COMMAND'S ENABLEMENT IS NOT A BUILD-TIME FACT, and AppKit never
    /// recomputes one under `autoenablesItems = false` (docs/traps.md).
    func kayaRefreshRoleEnablement() {
        for (_, item) in kayaScene.menuItems where !item.role.isEmpty {
            guard let nsItem = kayaOwnedNSMenuItem(item.id) else { continue }
            nsItem.isEnabled = kayaMenuEffectiveEnabled(item)
        }
    }

    /// The delegate that gives a REAL user the same freshness: AppKit asks
    /// before it displays.
    final class KayaMenuRefresher: NSObject, NSMenuDelegate {
        func menuNeedsUpdate(_ menu: NSMenu) {
            kayaRefreshRoleEnablement()
        }
    }

    let kayaMenuRefresher = KayaMenuRefresher()

    func kayaMacMenuActivate(_ path: String) -> String? {
        kayaEnsureMenuSegment()
        kayaRefreshRoleEnablement()
        guard let target = kayaResolveMenuPath(path, roots: kayaPresentedCatalog()) else {
            return "no such menu item \(path)"
        }
        var found = kayaOwnedNSMenuItem(target.id)
        if found == nil {
            // A coalesced rebuild may still be one queue turn out; re-sync from
            // the model (the post-user mirror) and look again before failing.
            kayaSyncMacMenuBar()
            found = kayaOwnedNSMenuItem(target.id)
        }
        guard let item = found, let menu = item.menu else {
            return "no such menu item \(path)"
        }
        // The REAL action route: highlight + target/action, exactly what menu
        // tracking sends. Disabled items stay inert in the dispatcher (the
        // inherited AND), as native tracking leaves them.
        menu.performActionForItem(at: menu.index(of: item))
        return nil
    }

    /// shortcut's macOS route: a synthetic key event through
    /// NSMenu.performKeyEquivalent, the table a real key press walks. The catalog
    /// table gates it, or the dress bar swallows an unowned chord — a stray
    /// primary+w would close the window under the leg.
    func kayaMacShortcut(_ spelling: String) -> Bool {
        kayaEnsureMenuSegment()
        kayaRefreshRoleEnablement()
        guard kayaShortcutItems[spelling] != nil else { return true }
        guard let (key, mask) = kayaKeyEquivalent(spelling),
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: mask,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: 0)
        else { return true }
        _ = NSApp.mainMenu?.performKeyEquivalent(with: event)
        return false
    }
#endif

/// One menu row's text, WITH its semantic icon where the item declared one — the
/// SwiftUI-menu spelling of kayaApplySymbol. Label, not Text: the row keeps its
/// title as the spoken text and gains the platform's glyph. Shared by the More
/// menu and every context menu, so it resolves nothing beyond the table.
struct KayaMenuRowLabel: View {
    let item: KayaMenuItemModel

    var body: some View {
        if let sf = kayaSFSymbol(item.symbol) {
            Label(item.label, systemImage: sf)
        } else {
            Text(item.label)
        }
    }
}

/// One menu item rendered in SwiftUI menu content — the More menu's children and
/// every context menu share this vocabulary. A nested menu survives as a real
/// cascade/drill-in; a radio_group renders inline with the platform's checkmark
/// idiom; all leaves fire the shared dispatch path with the anchor's noun.
struct KayaMenuNodeView: View {
    let item: KayaMenuItemModel
    let noun: [UInt8]
    /// Promoted primaries render in the bar, not in overflow.
    var promoted: Set<UInt64> = []

    var body: some View {
        switch item.kind {
        case menuKindSeparator:
            Divider()
        case menuKindMenu:
            // The drill-in row itself disables (Compose disables the drill row,
            // mac disables the holder — one semantics).
            Menu {
                ForEach(item.children) { child in
                    KayaMenuNodeView(item: child, noun: noun, promoted: promoted)
                }
            } label: {
                KayaMenuRowLabel(item: item)
            }
            .disabled(!kayaMenuEffectiveEnabled(item))
        case menuKindRadioGroup:
            KayaMenuRadioInline(group: item, noun: noun)
        case menuKindToggle:
            Toggle(
                isOn: Binding(
                    get: { item.checked },
                    set: { _ in kayaMenuUserActivate(item, noun: noun) })
            ) {
                KayaMenuRowLabel(item: item)
            }
            .disabled(!kayaMenuEffectiveEnabled(item))
        case menuKindAction:
            if !promoted.contains(item.id) {
                Button {
                    kayaMenuUserActivate(item, noun: noun)
                } label: {
                    KayaMenuRowLabel(item: item)
                }
                .disabled(!kayaMenuEffectiveEnabled(item))
            }
        default:
            EmptyView()
        }
    }
}

/// A radio group inline in menu content: the checkmark idiom via an inline
/// Picker; the selection binding's setter IS the user route (programmatic value
/// writes land in the apply arm and stay quiet).
struct KayaMenuRadioInline: View {
    let group: KayaMenuItemModel
    let noun: [UInt8]

    var body: some View {
        Picker(
            group.label,
            selection: Binding(
                get: { Int(group.value) },
                set: { index in kayaMenuUserSelectRadio(group, index, noun: noun) })
        ) {
            ForEach(Array(group.children.enumerated()), id: \.element.id) { index, option in
                // An option carries a symbol like any other leaf, and the mac
                // arm applies one to every radio option it builds.
                KayaMenuRowLabel(item: option).tag(index)
            }
        }
        .pickerStyle(.inline)
        .disabled(!kayaMenuEffectiveEnabled(group))
    }
}

/// A context anchor's menu content: the attached roots in append order, every
/// activation stamping the anchor's noun (empty for a live widget; the stamped
/// copy's key path for a template node).
struct KayaContextMenuItems: View {
    let widgetId: UInt64

    var body: some View {
        let noun = kayaScene.contextNouns[widgetId] ?? []
        ForEach(kayaScene.contextRoots[widgetId] ?? []) { root in
            KayaMenuNodeView(item: root, noun: noun)
        }
    }
}

/// The window's content size AND the platform's own size class, reported to the
/// CORE whenever either changes (docs/adaptive-layout-plan.md D3; iOS reports
/// the platform's class, macOS NONE, ruled 2026-08-31). Whole-window, outside
/// the arm chain, so the reading does not depend on which arm rendered.
struct KayaWindowMetricsReporter: ViewModifier {
    let windowId: UInt64
    #if !os(macOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var sizeClass: Int64 {
        #if os(macOS)
            return Int64(KAYA_SIZE_CLASS_NONE)
        #else
            switch horizontalSizeClass {
            case .compact: return Int64(KAYA_SIZE_CLASS_COMPACT)
            case .regular: return Int64(KAYA_SIZE_CLASS_REGULAR)
            default: return Int64(KAYA_SIZE_CLASS_NONE)
            }
        #endif
    }

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    #if os(macOS)
                        Color.clear
                            .onAppear {
                                KayaHost.windowMetrics(windowId, geo.size, sizeClass)
                            }
                            .onChange(of: geo.size) { _, size in
                                KayaHost.windowMetrics(windowId, size, sizeClass)
                            }
                    #else
                        Color.clear
                            .onAppear {
                                KayaHost.windowMetrics(windowId, geo.size, sizeClass)
                            }
                            .onChange(of: geo.size) { _, size in
                                KayaHost.windowMetrics(windowId, size, sizeClass)
                            }
                            .onChange(of: horizontalSizeClass) {
                                KayaHost.windowMetrics(windowId, geo.size, sizeClass)
                            }
                    #endif
                }
            )
    }
}

struct KayaFormFactorRecorder: ViewModifier {
    let windowId: UInt64
    #if !os(macOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var width: Double = 0

    private var factor: KayaFormFactor {
        #if os(macOS)
            return width >= 600 ? .regular : .compact
        #else
            return horizontalSizeClass == .regular ? .regular : .compact
        #endif
    }

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { width = geo.size.width }
                        .onChange(of: geo.size.width) { _, w in width = w }
                }
            )
            // Recorded in onAppear/onChange, never in body: a write during body
            // evaluation is a mutation inside the render pass.
            .onAppear { record() }
            .onChange(of: width) { record() }
        #if !os(macOS)
            .onChange(of: horizontalSizeClass) { record() }
        #endif
    }

    private func record() {
        kayaScene.windows[windowId]?.formFactor = factor
    }
}

/// The window catalog's chrome, attached to every surface root: a no-op on
/// macOS (the global-bar synchronizer owns the lowering there), and elsewhere
/// the FORM-FACTOR-keyed choice of lowering. The axis is the window's size
/// class, never the operating system (DESIGN.md, "Form factor and adaptivity").
struct KayaMenuChrome: ViewModifier {
    let windowId: UInt64

    func body(content: Content) -> some View {
        #if os(macOS)
            // No stamping here: macOS answers the chrome verbs off the REAL tree
            // — the kaya-owned segment in NSApp.mainMenu for the catalog, the
            // window's own NSToolbar for the promoted set — which is a stronger
            // read than anything this view could record.
            content.modifier(KayaMenuToolbarMac(windowId: windowId))
        #else
            content.modifier(KayaMenuFormFactorChrome(windowId: windowId))
        #endif
    }
}

/// The prefix a promoted toolbar button's rendering arm publishes on the
/// accessibility identifier; BOTH LOWERINGS PUBLISH IT, hence its place outside
/// either platform's block. WHAT IT IS WORTH DIFFERS BY HOST: the symbol ANSWER
/// on macOS, a DIAGNOSTIC on iOS, where UIKit names the glyph itself.
let kayaToolbarSymbolIdent = "kaya-toolbar-symbol:"

#if os(macOS)
    /// The macOS window-anchor lowering: the promoted primaries as REAL NSToolbar
    /// items (docs/chrome-plan.md C2), off the phones' own promoted list; the
    /// remainder needs no More menu here. NO TOOLBAR STYLE IS SET, MEASURED:
    /// `.automatic` resolves to `.unified` for this window shape.
    struct KayaMenuToolbarMac: ViewModifier {
        let windowId: UInt64
        @State private var scene = kayaScene

        func body(content: Content) -> some View {
            // The promoted set is read INSIDE the body so the toolbar recomputes
            // on every catalog mutation — a late `primary` write or a new append
            // moves the bar. A window with nothing promoted grows no toolbar at
            // all, which keeps every other scene's 28pt chrome where it was.
            let promoted = scene.windows[windowId].map(kayaPromotedActions) ?? []
            if promoted.isEmpty {
                content
            } else {
                content.toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        ForEach(promoted) { item in
                            Button {
                                kayaMenuUserActivate(item)
                            } label: {
                                KayaPromotedLabelMac(item: item)
                            }
                            // THE ONE ENABLEMENT, off the same inherited AND
                            // every other arm calls: disabling the menu item
                            // disables this button because it IS that item, not
                            // because anything copied the flag across.
                            .disabled(!kayaMenuEffectiveEnabled(item))
                        }
                    }
                }
            }
        }
    }

    /// One promoted primary's label on macOS, and the identifier saying which arm
    /// drew. PRECEDENCE: symbol, then icon bytes, then a bare label. THE
    /// IDENTIFIER IS THE STRONGEST OBSERVATION — a SwiftUI TOOLBAR item has no
    /// glyph object to read — and it cannot see the pixels.
    struct KayaPromotedLabelMac: View {
        let item: KayaMenuItemModel

        var body: some View {
            if item.symbol != 0 {
                if let sf = kayaSFSymbol(item.symbol), let name = kayaSymbolName(item.symbol),
                    kayaSymbolImage(item.symbol) != nil
                {
                    Label(item.label, systemImage: sf)
                        .accessibilityIdentifier(kayaToolbarSymbolIdent + name)
                } else {
                    // A declared symbol this host cannot draw. The button stays
                    // usable as text, and the identifier says which of the two
                    // causes was measured.
                    Text(item.label)
                        .accessibilityIdentifier(
                            kayaToolbarSymbolIdent + kayaPromotedSymbolWhyNot(item.symbol))
                }
            } else if let icon = item.icon {
                Image(nsImage: icon)
                    .accessibilityIdentifier(
                        kayaToolbarSymbolIdent
                            + "the promoted button drew the app's icon bytes, no symbol")
            } else {
                Text(item.label)
                    .accessibilityIdentifier(
                        kayaToolbarSymbolIdent
                            + "the promoted button drew its label as text, no icon")
            }
        }
    }
#endif

#if !os(macOS)
    /// Reads the live horizontal size class, records it on the window model so
    /// the harness can observe the transition, and picks the lowering. Recording
    /// happens in `onAppear`/`onChange` rather than in `body`, because a write
    /// during body evaluation is a mutation inside the render pass.
    struct KayaMenuFormFactorChrome: ViewModifier {
        let windowId: UInt64
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass

        private var factor: KayaFormFactor {
            horizontalSizeClass == .regular ? .regular : .compact
        }

        func body(content: Content) -> some View {
            Group {
                if factor == .regular {
                    // The system menu bar carries the whole catalog; a More
                    // toolbar beside it would be a second, redundant route.
                    content
                } else {
                    content.modifier(KayaMenuToolbar(windowId: windowId))
                }
            }
            .onAppear { record() }
            .onChange(of: horizontalSizeClass) { record() }
            .onChange(of: kayaScene.windows[windowId]?.menubar.count ?? 0) {
                record()
            }
        }

        /// Stamp both halves the harness reads. The presentation half names THE
        /// ARM THIS BODY TOOK: the toolbar on compact, and on regular the system
        /// menu bar that `kayaBuildCatalogMenus` installs.
        private func record() {
            guard let window = kayaScene.windows[windowId] else { return }
            window.formFactor = factor
            if window.menubar.isEmpty {
                window.menuPresentation = .none
            } else if factor != .regular {
                // The compact arm stamps itself; the regular arm's stamp belongs
                // to kayaBuildCatalogMenus, which writes `.bar` only after really
                // inserting menus. Deriving it here from `factor` would make the
                // harness verb agree with the lowering by construction.
                window.menuPresentation = .overflow
            }
            kayaRebuildCatalogMenus()
        }
    }
#endif

#if !os(macOS)
    /// The regular-width catalog lowering: the platform's own menu bar, driven
    /// through UIMenuBuilder because CommandsBuilder has no `buildArray`.
    /// buildMenu also runs on iPhone, feeding the hardware-keyboard HUD, so
    /// building is unconditional; only the VISIBLE arm keys on size class.
    func kayaBuildCatalogMenus(_ builder: UIMenuBuilder) {
        if ProcessInfo.processInfo.environment["KAYA_MENU_TRACE"] != nil {
            FileHandle.standardError.write(
                Data("KAYA_MENU_TRACE: buildMenu roots=\(kayaScene.windows[0]?.menubar.count ?? -1)\n".utf8))
        }
        guard let window = kayaScene.windows[0], !window.menubar.isEmpty else {
            return
        }
        // Reversed: each insert lands immediately after .view, so going back to
        // front leaves catalog order reading left to right.
        var inserted = 0
        for root in window.menubar.reversed() {
            guard let menu = kayaCatalogTopLevel(root) else { continue }
            builder.insertSibling(menu, afterMenu: .view)
            inserted += 1
        }
        // Stamped where the bar is REALLY built, never from the size class: a
        // build that silently produced nothing must not be able to report `bar`
        // to expect_menu_presentation. KAYA_MENU_TRACE=1 prints the build trace
        // to stderr; kept deliberately, it is what proved the bar is built lazily.
        if ProcessInfo.processInfo.environment["KAYA_MENU_TRACE"] != nil {
            FileHandle.standardError.write(
                Data("KAYA_MENU_TRACE: inserted=\(inserted) factor=\(window.formFactor.rawValue)\n".utf8))
        }
    }

    /// A top-level catalog node. Grouping nodes become real menus; a top-level
    /// radio group becomes a menu holding its inline options.
    private func kayaCatalogTopLevel(_ item: KayaMenuItemModel) -> UIMenu? {
        switch item.kind {
        case menuKindMenu:
            return UIMenu(
                title: item.label, children: kayaCatalogChildren(item.children))
        case menuKindRadioGroup:
            return UIMenu(title: item.label, children: [kayaCatalogRadio(item)])
        default:
            return nil
        }
    }

    /// One grouping node's children, with kaya's SEPARATOR items lowered the way
    /// UIKit spells separation: it has no separator element, a divider being the
    /// boundary between `.displayInline` groups. A placeholder would render as a
    /// real selectable row, so empty partitions are dropped instead.
    private func kayaCatalogChildren(_ children: [KayaMenuItemModel])
        -> [UIMenuElement]
    {
        var groups: [[UIMenuElement]] = [[]]
        for child in children {
            if child.kind == menuKindSeparator {
                if !(groups.last?.isEmpty ?? true) { groups.append([]) }
                continue
            }
            guard let element = kayaCatalogElement(child) else { continue }
            groups[groups.count - 1].append(element)
        }
        let filled = groups.filter { !$0.isEmpty }
        // A single group needs no wrapper: with no sibling group there is no
        // divider to draw.
        if filled.count <= 1 { return filled.first ?? [] }
        return filled.map {
            UIMenu(title: "", options: .displayInline, children: $0)
        }
    }

    private func kayaCatalogElement(_ item: KayaMenuItemModel) -> UIMenuElement? {
        switch item.kind {
        case menuKindMenu:
            return UIMenu(
                title: item.label, children: kayaCatalogChildren(item.children))
        case menuKindRadioGroup:
            return kayaCatalogRadio(item)
        case menuKindAction, menuKindToggle:
            let action = UIAction(title: item.label) { _ in
                // The one dispatch path, shared with every other arm.
                kayaMenuUserActivate(item)
            }
            if !kayaMenuEffectiveEnabled(item) { action.attributes = .disabled }
            if item.kind == menuKindToggle {
                action.state = item.checked ? .on : .off
            }
            return action
        default:
            return nil
        }
    }

    /// A radio group: options inline, exactly one `.on` — the choice contract's
    /// selected index, the same state the inline Picker shows in the compact arm.
    private func kayaCatalogRadio(_ group: KayaMenuItemModel) -> UIMenuElement {
        let enabled = kayaMenuEffectiveEnabled(group)
        let options = group.children.enumerated().map {
            (index, option) -> UIMenuElement in
            let action = UIAction(title: option.label) { _ in
                kayaMenuUserSelectRadio(group, index)
            }
            action.state = Int(group.value) == index ? .on : .off
            if !enabled { action.attributes = .disabled }
            return action
        }
        return UIMenu(title: group.label, options: .displayInline, children: options)
    }

    /// The catalog is live, so every structural append and every prop write must
    /// reach the bar or it shows stale state. UIKit's invalidation is a rebuild
    /// request — the same "recompute on every catalog mutation" rule the promoted
    /// set already follows.
    func kayaRebuildCatalogMenus() {
        // Hop to main, exactly like the macOS segment rebuild: this is reached
        // from the transaction apply, which is not guaranteed to be the main
        // thread, and a UIKit invalidation off-main is silently dropped.
        if ProcessInfo.processInfo.environment["KAYA_MENU_TRACE"] != nil {
            FileHandle.standardError.write(Data("KAYA_MENU_TRACE: rebuild requested\n".utf8))
        }
        DispatchQueue.main.async { UIMenuSystem.main.setNeedsRebuild() }
    }

    var kayaClipboardObserverInstalled = false

    /// A STANDARD COMMAND'S ENABLEMENT IS NOT A BUILD-TIME FACT, and a UIAction
    /// bakes `.disabled` in at build, so the VISIBLE Paste item would keep what
    /// it was born with. The iOS half of the macOS refresh, since UIKit asks
    /// nobody before display.
    func kayaInstallClipboardObserver() {
        guard !kayaClipboardObserverInstalled else { return }
        kayaClipboardObserverInstalled = true
        NotificationCenter.default.addObserver(
            forName: UIPasteboard.changedNotification, object: nil, queue: .main
        ) { _ in
            kayaRebuildCatalogMenus()
        }
    }

    /// One promoted primary's label, and the arm's own account of what it drew.
    /// PRECEDENCE, MIRRORED FROM macOS: symbol, icon bytes, bare label. THE
    /// IDENTIFIER IS A DIAGNOSTIC, not the answer — both iOS verbs ask the GLYPH
    /// first, since a `Label` swapped for a `Text` keeps the identifier.
    struct KayaPromotedLabel: View {
        let item: KayaMenuItemModel

        var body: some View {
            if item.symbol != 0 {
                if let sf = kayaSFSymbol(item.symbol), let name = kayaSymbolName(item.symbol),
                    UIImage(systemName: sf) != nil
                {
                    Label(item.label, systemImage: sf)
                        .accessibilityIdentifier(kayaToolbarSymbolIdent + name)
                } else {
                    // A declared symbol this host cannot draw. The button stays
                    // usable as text, and the identifier says which of the two
                    // causes was measured.
                    Text(item.label)
                        .accessibilityIdentifier(
                            kayaToolbarSymbolIdent + kayaPromotedSymbolWhyNot(item.symbol))
                }
            } else if let icon = item.icon {
                Image(uiImage: icon)
                    .accessibilityIdentifier(
                        kayaToolbarSymbolIdent
                            + "the promoted button drew the app's icon bytes, no symbol")
            } else {
                Text(item.label)
                    .accessibilityIdentifier(
                        kayaToolbarSymbolIdent
                            + "the promoted button drew its label as text, no icon")
            }
        }
    }

    /// The iOS window-anchor lowering: promoted primaries as real trailing bar
    /// actions, the rest of the catalog behind a trailing More menu — top-level
    /// grouping nodes as labeled groups, one nested menu level as a drill-in,
    /// radio groups inline. All recomputed from the observable catalog.
    struct KayaMenuToolbar: ViewModifier {
        let windowId: UInt64
        @State private var scene = kayaScene

        func body(content: Content) -> some View {
            if let window = scene.windows[windowId], !window.menubar.isEmpty {
                content.toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        let promoted = kayaPromotedActions(window)
                        ForEach(promoted) { item in
                            Button {
                                kayaMenuUserActivate(item)
                            } label: {
                                KayaPromotedLabel(item: item)
                            }
                            .disabled(!kayaMenuEffectiveEnabled(item))
                        }
                        Menu {
                            let promotedIds = Set(promoted.map(\.id))
                            ForEach(window.menubar) { top in
                                if top.kind == menuKindRadioGroup {
                                    KayaMenuRadioInline(group: top, noun: [])
                                } else {
                                    Section(top.label) {
                                        ForEach(top.children) { child in
                                            KayaMenuNodeView(
                                                item: child, noun: [],
                                                promoted: promotedIds)
                                        }
                                    }
                                }
                            }
                        } label: {
                            // The trigger glyph is dress; the IDENTIFIER is not.
                            // It is how the chrome read finds the remainder's
                            // home on the real bar without matching an English
                            // word.
                            Label("More", systemImage: "ellipsis.circle")
                                .accessibilityIdentifier(kayaToolbarMoreIdent)
                        }
                    }
                }
            } else {
                content
            }
        }
    }
#endif

/// A navigation entry's content: the mounted root in the normalized frame,
/// titled from its model — navigationTitle inside a NavigationStack destination
/// titles the bar (and the window, on macOS): the real title path the harness
/// reads back.
struct KayaEntryRoot: View {
    let entryId: UInt64
    @State private var scene = kayaScene

    var body: some View {
        Group {
            if let entry = scene.navEntries[entryId], let root = entry.root {
                KayaRender(node: root, isRoot: true)
            }
        }
        // The OWNING WINDOW's inset (D3: the knob is per-window; an entry is a
        // surface WITHIN one). Entries present on the primary in every scene
        // today; an aux-window stack would want the entry model to carry its
        // window.
        .padding(scene.windows[0]?.inset ?? 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(KayaGroupedScreenGround(on: scene.groupedEntries.contains(entryId)))
        .navigationTitle(scene.navEntries[entryId]?.title ?? "")
    }
}

/// An auxiliary surface's content: the mounted root in the same normalized frame
/// the primary uses, titled from its model. Presented via openWindow(value:)
/// when a mount targets it.
struct KayaAuxRoot: View {
    let windowId: UInt64
    @State private var scene = kayaScene

    var body: some View {
        // The stack hosts the window's serial entries; the window's own root is
        // the stack's base. The accessor rides OUTSIDE the stack so its view
        // never detaches under a push.
        Group {
        if scene.windows[windowId]?.sections.isEmpty == false {
            KayaSectionsView(windowId: windowId)
                .navigationTitle(kayaWindowCaption(windowId))
        } else {
        NavigationStack(path: kayaNavPath(windowId)) {
            Group {
                if let model = scene.windows[windowId], let root = model.root {
                    KayaRender(node: root, isRoot: true)
                }
            }
            .padding(scene.windows[windowId]?.inset ?? 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(kayaWindowCaption(windowId))
            .navigationDestination(for: UInt64.self) { eid in
                KayaEntryRoot(entryId: eid)
            }
        }
        }
        }
        .onAppear { kayaDiag("auxRoot appear wid=\(windowId)") }
        // The brand rides every scene root, not window 0's alone (the
        // Phase A finding — see KayaRoot's tint note).
        .tint(kayaBrandTint())
        .font(kayaBrandFont())
        #if os(macOS)
            .background(KayaWindowAccessor(windowId: windowId))
        #endif
    }
}

/// Does `windowId` take a split arm right now? Both halves must hold: the app
/// ASKED (wprop 6) and the window IS regular, the size class being the
/// platform's answer. WHICH split root renders is the ceiling's call; a compact
/// window takes the stack arm at any ceiling (docs/multicolumn-plan.md Q3).
func kayaSplitArm(_ windowId: UInt64) -> Bool {
    guard let w = kayaScene.windows[windowId] else { return false }
    return w.panes >= 2 && w.formFactor == .regular
}

// --- The pane surfaces on screen, and the mac ladder ------------------
// docs/multicolumn-plan.md: D1 (positions), D4 (the reader),
// MECHANICS AMENDMENTS (what may be declared to SwiftUI and what must
// not be).

// KAYA'S OWN PANE MINIMUMS — the model's alone, DECLARED TO NOBODY: a minimum
// handed to navigationSplitViewColumnWidth becomes the WINDOW's floor, so the
// collapse rule never fires and resize_window is a silent no-op (MECHANICS
// AMENDMENTS 1). tools/check-pane-ladder.py pins the arithmetic.
let kayaPaneMinSidebar: Double = 200
let kayaPaneMinContent: Double = 270
let kayaPaneMinDetail: Double = 320

/// Which rung fits `width`: 3 when the window can hold all three of
/// kaya's minimums, else 2. There is no 1 rung — one pane is the
/// compact stack arm's territory (see the constants above).
func kayaPaneRung(_ width: Double) -> Int {
    width >= kayaPaneMinSidebar + kayaPaneMinContent + kayaPaneMinDetail ? 3 : 2
}

/// EDGE-TRIGGERED: a command only when a width CROSSING changes the rung, nil on
/// the level — the sidebar toggle writes the same visibility binding, and a
/// level-triggered rule would undo the user's choice on the next layout pass
/// (MECHANICS AMENDMENTS 3). `from == nil` is an edge from nothing.
func kayaPaneLadderCommand(
    from: Double?, to: Double
) -> NavigationSplitViewVisibility? {
    if let from, kayaPaneRung(from) == kayaPaneRung(to) { return nil }
    return kayaPaneRung(to) == 3 ? .all : .doubleColumn
}

/// The expect_panes reading for `windowId`: `<size class>/<positions>`, ascending
/// stack indices. On a macOS split arm they come from the REAL NSSplitView, each
/// column counted visible by width AND hiddenness. View lifecycle is deliberately
/// NOT the source: NavigationStack retains covered views without onDisappear.
@MainActor
func kayaPanesReading(_ windowId: UInt64) -> String {
    guard let w = kayaScene.windows[windowId] else { return "unknown/-" }
    let entries = w.entries.count
    var positions: [Int] = []
    var splitUp = false
    #if os(macOS)
        if let host = kayaNSWindows[windowId] ?? NSApp.keyWindow,
            let content = host.contentView,
            let split = kayaFindSplitView(content)
        {
            splitUp = true
            let cols = split.arrangedSubviews.map {
                $0.frame.width > 1 && !$0.isHidden
            }
            if cols.count >= 3 {
                if cols[0] { positions.append(0) }
                if cols[1], entries >= 1 { positions.append(1) }
                if cols[2], entries >= 2 { positions.append(entries) }
            } else {
                if !cols.isEmpty, cols[0] { positions.append(0) }
                if cols.count >= 2, cols[1], entries >= 1 { positions.append(entries) }
            }
        }
    #endif
    if !splitUp {
        // No split view on screen: the stack arm's one pane is the TOP. On a
        // non-macOS split arm the positions derive from the arm stamp and the
        // stack (harness.rs's two-pane rule); the iOS real-arrangement read is
        // its own slice's work.
        switch w.splitPresentation {
        case "split":
            positions = entries == 0 ? [0] : [0, entries]
        case "split3":
            positions = [0]
            if entries >= 1 { positions.append(1) }
            if entries >= 2 { positions.append(entries) }
        default:
            positions = [entries]
        }
    }
    let spelled =
        positions.isEmpty ? "-" : positions.map(String.init).joined(separator: ",")
    return w.formFactor.rawValue + "/" + spelled
}

#if os(macOS)
    /// The first NSSplitView under `view` — NavigationSplitView's own,
    /// when a split arm is up; nil on the stack arm.
    func kayaFindSplitView(_ view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for sub in view.subviews {
            if let found = kayaFindSplitView(sub) { return found }
        }
        return nil
    }
#endif

/// The two-column presentation of a window's entry stack: pane 0 the base root,
/// the trailing pane the stack's TOP, the middles retained and covered
/// (docs/multicolumn-plan.md D1). The ceiling-3 form is KayaSplitRoot3, a
/// separate struct because the initializers are different generic types.
struct KayaSplitRoot: View {
    let windowId: UInt64
    @State private var scene = kayaScene

    var body: some View {
        NavigationSplitView {
            Group {
                if let root = scene.windows[windowId]?.root {
                    KayaRender(node: root, isRoot: true)
                }
            }
            .padding(scene.windows[windowId]?.inset ?? 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(kayaWindowCaption(windowId))
        } detail: {
            // The TOP of the stack is the detail. An empty stack gets the
            // platform's own empty state.
            if let top = scene.windows[windowId]?.entries.last {
                KayaEntryRoot(entryId: top.id)
            } else {
                // THE WINDOW'S TITLE HANGS OFF THE DETAIL COLUMN: on macOS a
                // NavigationSplitView titles its window from the DETAIL side, so
                // with an empty stack AppKit substituted the PROCESS NAME, which
                // read as correct only for a guest binary named `split`.
                Color.clear
                    .navigationTitle(kayaWindowCaption(windowId))
            }
        }
        .onAppear { record() }
        .onChange(of: scene.windows[windowId]?.entries.count ?? 0) { record() }
        // The brand rides every scene root (see KayaRoot's tint note).
        .tint(kayaBrandTint())
        .font(kayaBrandFont())
    }

    /// Stamp the arm THIS BODY TOOK. Never derived from panes or
    /// formFactor: a derived answer agrees with the lowering by construction and
    /// could never catch the defect.
    private func record() {
        kayaScene.windows[windowId]?.splitPresentation = "split"
    }
}

/// The THREE-column presentation (docs/multicolumn-plan.md D1/D3): pane 0 the
/// base root, pane 1 the first entry, the detail column the REST of the stack in
/// its own NavigationStack, so a deep stack keeps a real back item. An empty
/// pane slot still exists (D1): pushes deepen a column, never swap containers.
struct KayaSplitRoot3: View {
    let windowId: UInt64
    @State private var scene = kayaScene
    /// SHARED with the platform's own sidebar toggle; kaya writes it
    /// only on rung crossings (edge-triggered — see
    /// kayaPaneLadderCommand).
    @State private var visibility: NavigationSplitViewVisibility = .all
    @State private var width: Double = 0
    @State private var measured: Double? = nil

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            Group {
                if let root = scene.windows[windowId]?.root {
                    KayaRender(node: root, isRoot: true)
                }
            }
            .padding(scene.windows[windowId]?.inset ?? 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(kayaWindowCaption(windowId))
            // Ideal ONLY, never a minimum (MECHANICS AMENDMENTS 1).
            .navigationSplitViewColumnWidth(ideal: 220)
        } content: {
            Group {
                if let first = scene.windows[windowId]?.entries.first {
                    KayaEntryRoot(entryId: first.id)
                } else {
                    Color.clear
                        .navigationTitle(kayaWindowCaption(windowId))
                }
            }
            .navigationSplitViewColumnWidth(ideal: 300)
        } detail: {
            NavigationStack(path: kayaDetailPath()) {
                Group {
                    if let base = scene.windows[windowId]?.entries.dropFirst().first {
                        KayaEntryRoot(entryId: base.id)
                    } else {
                        // The empty trailing slot carries the window title —
                        // the KayaSplitRoot lesson, one column over.
                        Color.clear
                            .navigationTitle(kayaWindowCaption(windowId))
                    }
                }
                .navigationDestination(for: UInt64.self) { eid in
                    KayaEntryRoot(entryId: eid)
                }
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { width = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in width = w }
            }
        )
        #if os(macOS)
            // THE MAC LADDER: macOS has no compact mode to defer to, so
            // kaya's own arithmetic decides how many columns fit
            // (docs/multicolumn-plan.md Q3). Everywhere else the
            // container's native judgment drives visibility itself.
            .onChange(of: width) { _, w in
                if let command = kayaPaneLadderCommand(from: measured, to: w) {
                    visibility = command
                }
                measured = w
            }
        #endif
        .onAppear { record() }
        .onChange(of: scene.windows[windowId]?.entries.count ?? 0) { record() }
        // The brand rides every scene root (see KayaRoot's tint note).
        .tint(kayaBrandTint())
        .font(kayaBrandFont())
    }

    /// The detail column's slice of the stack: entries 2+, popped
    /// through the same user-pop path the two-column arms use.
    private func kayaDetailPath() -> Binding<[UInt64]> {
        Binding(
            get: {
                (kayaScene.windows[windowId]?.entries.dropFirst(2) ?? []).map(\.id)
            },
            set: { newPath in kayaUserPops(windowId, to: newPath.count + 2) })
    }

    /// Stamp the arm THIS BODY TOOK (the stamped-observation rule).
    private func record() {
        kayaScene.windows[windowId]?.splitPresentation = "split3"
    }
}

/// The entry's own view: it needs a @FocusState, which the recursive
/// KayaRender switch cannot carry per-node.
struct KayaEntry: View {
    let node: KayaNode
    var flexVertical: Bool? = nil
    @FocusState private var focused: Bool

    var body: some View {
        // Uncontrolled toward the app: the node mirrors what the user types and
        // every edit is emitted with the entry's identity tag, nothing read
        // back. Focus is model-driven the same way, with a user-driven change
        // flowing back so the model stays truthful.
        TextField(
            "",
            text: Binding(
                get: { node.text },
                set: { newValue in
                    let value = kayaLF(newValue)
                    kayaUserWrite { node.text = value }
                    KayaHost.emitText(node, value)
                })
        )
        .textFieldStyle(.roundedBorder)
        // 200 stands in for the intrinsic width every other toolkit's entry
        // has in a ROW; a grower keeps its track, and IN A COLUMN a text
        // field fills the width — an input region, not content (DESIGN.md
        // Layout, docs/tasks-plan.md R10).
        .frame(
            maxWidth: (node.grow > 0 || (flexVertical == true && node.fill != false))
                ? .infinity : 200)
        .focused($focused)
        .onAppear { focused = kayaScene.focusedId == node.id }
        .onChange(of: kayaScene.focusedId) { _, newValue in
            focused = newValue == node.id
        }
        .onChange(of: focused) { _, newValue in
            if newValue {
                kayaScene.focusedId = node.id
            } else if kayaScene.focusedId == node.id {
                kayaScene.focusedId = nil
            }
        }
    }
}

/// THE TEXTAREA'S LAYOUT FLOOR, AND THE ONE PLACE `grow` REACHES IT. A FLOOR,
/// NOT A FIXED FRAME, as GTK's `set_size_request` and WinUI's MinWidth are: a
/// fixed frame refuses the assigned track, so a full-window buffer with grow(1)
/// got a small box while every share assertion passed.
extension View {
    func kayaTextareaFrame(grow: Double, flexVertical: Bool?, stretch: Bool, fill: Bool?)
        -> some View
    {
        let grows = grow > 0
        // In a column a text area fills the width (docs/tasks-plan.md R10)
        // unless its own `fill` says otherwise (docs/layout-knobs-plan.md §1).
        let fillsWidth =
            (grows && flexVertical == false) || (flexVertical == true && fill != false)
        let fillsHeight =
            (grows && flexVertical == true) || (flexVertical == false && (fill ?? stretch))
        return frame(
            minWidth: 240, maxWidth: fillsWidth ? .infinity : 240,
            minHeight: 96, maxHeight: fillsHeight ? .infinity : 96)
    }
}

#if os(macOS)
/// The multi-line editor on macOS: KayaEntry's exact contract over an NSTextView
/// this file holds directly. RICH-CAPABLE CONTROL, PLAIN-TEXT CONTRACT
/// (docs/textarea-foundation-plan.md): every opinion the rich control carries is
/// pinned off in `kayaPinPlainText`, and a breach fails the leg.
struct KayaTextarea: View {
    let node: KayaNode
    /// The main axis of the flex container this textarea sits in, if it
    /// sits in one — see kayaTextareaFrame.
    var flexVertical: Bool? = nil
    /// Whether that container aligns `stretch` — the cross axis's half.
    var flexStretch = false

    var body: some View {
        // EVERY MODEL FACT THE VIEW NEEDS IS READ HERE, in a SwiftUI body:
        // @Observable tracks the reads a BODY makes, so reading `node.text` here
        // is what makes a model write re-run the body and bring `updateNSView`
        // around. A read inside `updateNSView` registers no dependency.
        KayaMacTextarea(
            node: node,
            text: node.text,
            focused: kayaScene.focusedId == node.id,
            a11yId: node.a11yId,
            a11yLabel: node.a11yLabel,
            a11yHint: node.a11yHint,
            // READ HERE, in the body, for the same reason the text is:
            // @Observable tracks a body's reads, so a declaration that arrived
            // while nothing else changed still brings updateNSView around.
            highlights: node.highlights,
            highlightsFor: node.highlightsFor,
            selectRequest: node.selectRequest,
            selectSeq: node.selectSeq,
            revealRequest: node.revealRequest,
            revealSeq: node.revealSeq
        )
        .kayaTextareaFrame(
            grow: node.grow, flexVertical: flexVertical, stretch: flexStretch, fill: node.fill)
        .border(Color.gray.opacity(0.4))
    }
}

/// The owned text view. THE SUBCLASS EXISTS FOR ONE REASON: focus must stay
/// truthful in BOTH directions, and the user-driven one has no delegate hook —
/// `textDidBeginEditing` fires on the first EDIT, not when the caret arrives, so
/// a click into an empty editor would leave `focusedId` on the old widget.
private final class KayaTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?
    /// Whose widget this is, so the view can ask the model whether it should be
    /// focused at a moment only the view knows about.
    var nodeId: UInt64 = 0

    /// FOCUS IS APPLIED WHEN THE VIEW HAS SOMEWHERE TO BE FOCUSED — the case
    /// `updateNSView`'s hook CANNOT cover. MEASURED, two runs in three: SwiftUI
    /// updates the NSView BEFORE putting it in a window, so the focus is lost
    /// with no error and the NEXT `type` reports "reached no window".
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, kayaScene.focusedId == nodeId else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window, kayaScene.focusedId == self.nodeId else { return }
            window.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { onFocusChange?(true) }
        return took
    }

    override func resignFirstResponder() -> Bool {
        let gave = super.resignFirstResponder()
        if gave { onFocusChange?(false) }
        return gave
    }
}

/// PIN OFF EVERY OPINION THE RICH CONTROL CARRIES: shipping one by accident
/// moves kaya's plain-text contract silently. EACH LINE IS LOAD-BEARING ON ITS
/// OWN, since the `enabledTextCheckingTypes` umbrella makes every individual pin
/// unfalsifiable; the defaults are read from the user's own settings.
func kayaPinPlainText(_ view: NSTextView) {
    // THE VALUE IS A STRING. Plain text refuses rich paste at the control (RTF
    // arrives as its characters and nothing else), refuses dropped/pasted
    // graphics — which would otherwise insert U+FFFC attachment characters INTO
    // the string the app reads — and keeps the format panels away.
    view.isRichText = false
    view.importsGraphics = false
    view.allowsImageEditing = false
    view.usesFontPanel = false
    view.usesRuler = false
    view.isRulerVisible = false
    view.allowsDocumentBackgroundColorChange = false
    // NOTHING REWRITES WHAT THE USER TYPED. Each of these edits the string the
    // app is told about, which is the observable kaya compares byte-for-byte
    // across eight languages and five lanes (invariant 6).
    view.isAutomaticQuoteSubstitutionEnabled = false
    view.isAutomaticDashSubstitutionEnabled = false
    view.isAutomaticTextReplacementEnabled = false
    view.isAutomaticSpellingCorrectionEnabled = false
    view.isAutomaticTextCompletionEnabled = false
    view.smartInsertDeleteEnabled = false
    // AND NOTHING ANNOTATES IT EITHER. These do not change the characters, they
    // attach attributes and draw over them — state the ranges milestone declares
    // on the same runs.
    view.isContinuousSpellCheckingEnabled = false
    view.isGrammarCheckingEnabled = false
    view.isAutomaticLinkDetectionEnabled = false
    view.isAutomaticDataDetectionEnabled = false
    // WRITING TOOLS REWRITE WHOLE SENTENCES (macOS 15+), in place, on the user's
    // command. `.none` is the API's own way to say the control is not a document.
    view.writingToolsBehavior = .none
    // THE FIND BAR STAYS OUT. kaya owns Cmd+F: it is a menu the app authors and
    // a role kaya routes, and a text view that installs its own find bar takes
    // the key first AND grows a bar inside the widget's 240x96 frame. The system
    // bar is not a fallback, it is a competitor.
    view.usesFindBar = false
    view.usesFindPanel = false
    view.isIncrementalSearchingEnabled = false
}

/// Is the scene interpreter running? The pin audit is a harness instrument and
/// costs a shipped app nothing.
let kayaHarnessActive = ProcessInfo.processInfo.environment["KAYA_SELFTEST"] != nil

/// Pins found NOT in force on a live control, by name. Written on the main
/// thread by the audit, folded into the scene's failures by kayaRunScript.
var kayaPlainTextPinBreaches: Set<String> = []

/// The pins, read back off the LIVE control: delete one, flip one, or apply them
/// to the wrong view and every textarea-bearing leg fails naming the trait. It
/// cannot prove AppKit HONOURS a trait, and no leg could — with the
/// substitutions ON, real NSEvents still produced straight quotes (2026-08-06).
func kayaAuditPlainTextPins(_ view: NSTextView) {
    guard kayaHarnessActive else { return }
    var breaches: [String] = []
    func want(_ ok: Bool, _ name: String) {
        if !ok { breaches.append(name) }
    }
    want(!view.isRichText, "isRichText")
    want(!view.importsGraphics, "importsGraphics")
    want(!view.allowsImageEditing, "allowsImageEditing")
    want(!view.usesFontPanel, "usesFontPanel")
    want(!view.usesRuler, "usesRuler")
    want(!view.isRulerVisible, "isRulerVisible")
    want(!view.allowsDocumentBackgroundColorChange, "allowsDocumentBackgroundColorChange")
    want(!view.isAutomaticQuoteSubstitutionEnabled, "isAutomaticQuoteSubstitutionEnabled")
    want(!view.isAutomaticDashSubstitutionEnabled, "isAutomaticDashSubstitutionEnabled")
    want(!view.isAutomaticTextReplacementEnabled, "isAutomaticTextReplacementEnabled")
    want(!view.isAutomaticSpellingCorrectionEnabled, "isAutomaticSpellingCorrectionEnabled")
    want(!view.isAutomaticTextCompletionEnabled, "isAutomaticTextCompletionEnabled")
    want(!view.smartInsertDeleteEnabled, "smartInsertDeleteEnabled")
    want(!view.isContinuousSpellCheckingEnabled, "isContinuousSpellCheckingEnabled")
    want(!view.isGrammarCheckingEnabled, "isGrammarCheckingEnabled")
    want(!view.isAutomaticLinkDetectionEnabled, "isAutomaticLinkDetectionEnabled")
    want(!view.isAutomaticDataDetectionEnabled, "isAutomaticDataDetectionEnabled")
    want(view.writingToolsBehavior == .none, "writingToolsBehavior")
    want(!view.usesFindBar, "usesFindBar")
    want(!view.usesFindPanel, "usesFindPanel")
    want(!view.isIncrementalSearchingEnabled, "isIncrementalSearchingEnabled")
    // The enabled checking types are the umbrella the pins do not use — asserted
    // rather than set, so a checker switched on through the mask is a breach
    // here instead of a silent substitution. ORTHOGRAPHY is the one bit AppKit
    // keeps and rewrites nothing; measured at exactly 1 on macOS 26.5.
    want(
        view.enabledTextCheckingTypes
            & ~NSTextCheckingResult.CheckingType.orthography.rawValue == 0,
        "enabledTextCheckingTypes")
    want(view.textLayoutManager != nil, "textLayoutManager")
    if !breaches.isEmpty { kayaPlainTextPinBreaches.formUnion(breaches) }
}

/// The macOS textarea: an NSTextView kaya owns rather than SwiftUI, since the
/// stock TextEditor's late push resets the caret and destroys every declared
/// attribute (docs/probes/range-probe-mac.md H2/G6). NEVER READ `.layoutManager`
/// ON THIS VIEW: that converts a TextKit 2 view to TextKit 1, permanently.
private struct KayaMacTextarea: NSViewRepresentable {
    let node: KayaNode
    let text: String
    let focused: Bool
    let a11yId: String
    let a11yLabel: String
    let a11yHint: String
    /// The declared set and THE TEXT IT WAS DECLARED AGAINST. Both, or the set
    /// is unpaintable: see `applyRanges`.
    let highlights: [NSRange]
    let highlightsFor: String?
    let selectRequest: NSRange?
    let selectSeq: Int
    let revealRequest: NSRange?
    let revealSeq: Int

    /// The uncontrolled fold, in AppKit's vocabulary: the view tells kaya what it
    /// holds, kaya normalizes it, writes the node and emits with the widget's
    /// identity tag. Nothing is read back.
    final class Coordinator: NSObject, NSTextViewDelegate {
        var node: KayaNode?
        /// The last one-shot sequence this view performed. A SEQUENCE AND NOT A
        /// CONSUMED OPTIONAL: `updateNSView` runs many times for one model
        /// change, and clearing the request there would be a model write during
        /// a view update. Remembering the number instead makes a re-run a no-op.
        var selectDone = 0
        var revealDone = 0
        /// THE TEXT STACK'S OWNER: the text view is initialized with the
        /// CONTAINER, so nothing it holds is documented to keep the content
        /// manager alive, and a widget whose content manager is collected has no
        /// text at all. The coordinator outlives every update.
        var content: NSTextContentStorage?

        func textDidChange(_ notification: Notification) {
            guard let node, let view = notification.object as? NSTextView else { return }
            let value = kayaLF(view.string)
            // THE ECHO DOCTRINE, held where an echo could enter: a programmatic
            // write emits nothing. "AppKit does not notify about a `string`
            // write" is a premise whose cost, if wrong, is a text_changed the
            // app never caused, so this compares against the model instead.
            guard value != node.text else { return }
            kayaUserWrite { node.text = value }
            KayaHost.emitText(node, value)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 2, assembled by name rather than inherited from a convenience
        // initializer, so what this widget sits on is stated in the source.
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        content.addTextLayoutManager(layout)
        let container = NSTextContainer(
            size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.textContainer = container

        context.coordinator.content = content

        let view = KayaTextView(frame: .zero, textContainer: container)
        view.isEditable = true
        view.isSelectable = true
        // The delegated undo tier lives on this manager: a kaya textarea's
        // undoManager resolves to the WINDOW's, and `kayaFocusedTextResponder`
        // reaches it as an NSText. Without this the native tier has nothing to
        // delegate to.
        view.allowsUndo = true
        // The textarea names its own ramp rung, so the swap is spelled here. This
        // view is also the best read-back site on the platform, and
        // expect_typeface reads it.
        view.font = kayaPlatformFont(.body) ?? .preferredFont(forTextStyle: .body)
        view.textContainerInset = CGSize(width: 2, height: 2)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = .zero
        view.maxSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        view.nodeId = node.id
        kayaPinPlainText(view)
        view.delegate = context.coordinator

        let coordinator = context.coordinator
        view.onFocusChange = { [weak view] took in
            // ONE TURN OUT, and the model re-read INSIDE the turn: this fires
            // from AppKit's first-responder change, which can be inside a
            // SwiftUI update pass, and by the time the turn arrives the answer
            // may have moved — so the closure asks who holds focus NOW.
            DispatchQueue.main.async {
                guard let node = coordinator.node, view != nil else { return }
                if took {
                    if kayaScene.focusedId != node.id { kayaScene.focusedId = node.id }
                } else if kayaScene.focusedId == node.id {
                    kayaScene.focusedId = nil
                }
            }
        }

        // THE VIEWPORT. A text view that is not a document view grows with its
        // content and clips against the widget's 240x96 frame, with no way to
        // reach what fell off the bottom.
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        // AND THE ONE LANDMINE OF THIS SWAP (docs/probes/range-probe-mac.md J1):
        // SwiftUI lands `.accessibilityIdentifier` on the representable's ROOT
        // view, this scroll view, so a published scroll area wins `kayaAxFind`.
        // Not publishing the viewport puts the text area first.
        scroll.setAccessibilityElement(false)
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? KayaTextView else { return }
        context.coordinator.node = node
        view.nodeId = node.id

        // APPLIED ON EVERY UPDATE, not once at construction: a pin that only ran
        // in makeNSView is lost the day SwiftUI hands back a recycled view or
        // AppKit re-derives a trait. The audit beside it reads the live control
        // back, so a breach fails the leg that rendered the widget.
        kayaPinPlainText(view)
        kayaAuditPlainTextPins(view)

        // THE PUSH KAYA OWNS, guarded by a comparison: an identical write still
        // rebuilds the storage and throws away the declared runs (measured, G2).
        // AND NOT WHILE THE USER IS COMPOSING (D4): `setMarkedText` notifies no
        // delegate, so the next pass would DESTROY the half-typed word.
        if view.string != text, !view.hasMarkedText() {
            let selection = view.selectedRange
            view.string = text
            let end = (text as NSString).length
            let location = min(selection.location, end)
            view.setSelectedRange(
                NSRange(location: location, length: min(selection.length, end - location)))
        }

        // THE UNIVERSAL PROPS, ON THE ELEMENT THAT PUBLISHES AS THE TEXT AREA:
        // KayaRender's modifiers land on the representable's root view, the
        // viewport (J1), so they are set again here and kaya's own set WINS
        // (measured by reading `AXTextArea id=notes-own` back). Empty stays unset.
        view.setAccessibilityIdentifier(a11yId)
        view.setAccessibilityLabel(a11yLabel.isEmpty ? nil : a11yLabel)
        view.setAccessibilityHelp(a11yHint.isEmpty ? nil : a11yHint)

        // THE RANGES, IN THE SAME PASS AS THE TEXT PUSH ABOVE — the ordering
        // this widget stopped being a stock TextEditor for: SwiftUI's own push
        // landed a turn later and destroyed everything declared before it.
        applyRanges(view, context.coordinator)

        // FOCUS, both directions, one turn out for the reason the responder
        // callback is: a first-responder change inside a SwiftUI update pass
        // reenters this view's own body. Each closure re-reads the model, so
        // whichever order the turns arrive in, the resting state is the model's.
        if focused, view.window?.firstResponder !== view {
            DispatchQueue.main.async { [weak view] in
                guard let view, kayaScene.focusedId == node.id else { return }
                view.window?.makeFirstResponder(view)
            }
        } else if !focused, view.window?.firstResponder === view {
            DispatchQueue.main.async { [weak view] in
                guard let view, kayaScene.focusedId != node.id,
                    view.window?.firstResponder === view
                else { return }
                view.window?.makeFirstResponder(nil)
            }
        }
    }

    /// The three primitives, lowered onto the owned view. HIGHLIGHT WRITES
    /// DOCUMENT ATTRIBUTES, the only one of macOS's three highlight mechanisms
    /// accessibility publishes (docs/probes/range-probe-mac.md §1/§4). D2'S
    /// CLEAR-ON-EDIT IS THE `highlightsFor` COMPARE, at paint time.
    private func applyRanges(_ view: KayaTextView, _ coordinator: Coordinator) {
        guard let storage = view.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.backgroundColor, range: full)
        if highlightsFor == text {
            // BOUNDS ARE RE-CHECKED AGAINST THE LIVE STORAGE: an out-of-range
            // `addAttribute` raises NSRangeException and the app exits 134
            // (measured), and the storage's length is a fact only this side
            // holds at this instant.
            for range in highlights where NSMaxRange(range) <= storage.length {
                storage.addAttribute(
                    .backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.55),
                    range: range)
            }
        }

        // THE TWO ONE-SHOTS, each performed once per request and clamped to the
        // live text: AppKit tolerates an out-of-range selection and scroll, but
        // tolerating is not a contract, and a range whose text has moved on is
        // not the range the app asked for.
        let length = (view.string as NSString).length
        if let range = selectRequest, selectSeq != coordinator.selectDone,
            NSMaxRange(range) <= length
        {
            coordinator.selectDone = selectSeq
            // D4, AND THE ONLY PARTY THAT CAN ENFORCE IT: an input-method
            // composition is live in the view and on no kaya channel, and
            // honouring a selection COMMITS the marked text mid-word
            // (docs/probes/range-probe-mac.md E7). Refused, never a panic.
            if view.hasMarkedText() {
                kayaDiag("select_range refused: ime_composition (widget \(node.id))")
            } else {
                view.setSelectedRange(range)
            }
        }
        if let range = revealRequest, revealSeq != coordinator.revealDone,
            NSMaxRange(range) <= length
        {
            coordinator.revealDone = revealSeq
            // A scroll disturbs neither the selection nor a composition
            // (measured, F6), so reveal has no refusal arm and needs none.
            view.scrollRangeToVisible(range)
        }
        kayaMacTextViews[node.id] = KayaWeakTextView(view)
    }
}

/// The widget-id -> text-view map, for the ONE harness verb that cannot go
/// through accessibility: `compose` reaches `setMarkedText`, which no AX
/// attribute exposes. The three READS deliberately do not use it, so a leg
/// cannot pass because kaya remembered its own intent.
final class KayaWeakTextView {
    weak var view: NSTextView?
    init(_ view: NSTextView) { self.view = view }
}
var kayaMacTextViews: [UInt64: KayaWeakTextView] = [:]

#else
    /// The multi-line editor on iOS: KayaEntry's exact contract over a UITextView
    /// this file holds directly. RICH-CAPABLE CONTROL, PLAIN-TEXT CONTRACT —
    /// `TextEditor` was already a UITextView, but SwiftUI owned that object, so
    /// nothing kaya could reach named its layout manager or selection.
    struct KayaTextarea: View {
        let node: KayaNode
        /// The main axis of the flex container this textarea sits in, if it sits
        /// in one — see kayaTextareaFrame.
        var flexVertical: Bool? = nil
        /// Whether that container aligns `stretch` — the cross axis's half.
        var flexStretch = false
        @Environment(\.kayaInGroupedCard) private var inGroupedCard

        var body: some View {
            // EVERY OBSERVATION IS READ HERE, in a SwiftUI body, and handed down
            // as values: `updateUIView` is no observation scope of its own, so a
            // representable reaching for `node.text` inside it would render once
            // and never hear about a model write again.
            KayaUITextView(
                node: node, text: node.text, focusedId: kayaScene.focusedId,
                highlights: node.highlights,
                highlightsFor: node.highlightsFor,
                selectRequest: node.selectRequest,
                selectSeq: node.selectSeq,
                revealRequest: node.revealRequest,
                revealSeq: node.revealSeq
            )
            .kayaTextareaFrame(
                grow: node.grow, flexVertical: flexVertical, stretch: flexStretch, fill: node.fill)
            .border(Color.gray.opacity(inGroupedCard ? 0 : 0.4))
        }
    }

    /// kaya's textarea control: a UITextView, pinned to plain text.
    struct KayaUITextView: UIViewRepresentable {
        let node: KayaNode
        let text: String
        let focusedId: UInt64?
        /// The declared set and THE TEXT IT WAS DECLARED AGAINST. Both, or the
        /// set is unpaintable: see `applyRanges`.
        let highlights: [NSRange]
        let highlightsFor: String?
        let selectRequest: NSRange?
        let selectSeq: Int
        let revealRequest: NSRange?
        let revealSeq: Int

        final class Coordinator: NSObject, UITextViewDelegate {
            var node: KayaNode?
            /// The last one-shot sequence this view performed. A SEQUENCE AND
            /// NOT A CONSUMED OPTIONAL: `updateUIView` runs many times for one
            /// model change, and clearing the request there would be a model
            /// write during a view update.
            var selectDone = 0
            var revealDone = 0

            /// The uncontrolled fold, spelled in UIKit: normalize line endings,
            /// mirror the value into the node, emit with the widget's identity
            /// tag. THE EQUALITY GUARD IS WHAT KEEPS THE ECHO OUT, making "no
            /// change, no emission" true by construction.
            func textViewDidChange(_ textView: UITextView) {
                guard let node else { return }
                let value = kayaLF(textView.text ?? "")
                guard value != node.text else { return }
                kayaUserWrite { node.text = value }
                KayaHost.emitText(node, value)
            }

            /// A user-driven focus change flows back so the model stays
            /// truthful, exactly as the `@FocusState` mirror did.
            func textViewDidBeginEditing(_ textView: UITextView) {
                guard let node, kayaScene.focusedId != node.id else { return }
                kayaScene.focusedId = node.id
            }

            func textViewDidEndEditing(_ textView: UITextView) {
                guard let node, kayaScene.focusedId == node.id else { return }
                kayaScene.focusedId = nil
            }
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeUIView(context: Context) -> UITextView {
            // THE BARE INITIALIZER IS THE TEXTKIT 2 ONE: `UITextView()` gets an
            // NSTextLayoutManager from iOS 16 on, while the container-taking
            // initializer and any read of `.layoutManager` silently downgrade
            // the view to TextKit 1. The audit below asserts it is still there.
            let view = UITextView()
            view.delegate = context.coordinator
            view.font = kayaPlatformFont(.body) ?? UIFont.preferredFont(forTextStyle: .body)
            view.adjustsFontForContentSizeCategory = true
            view.backgroundColor = .clear
            view.contentInsetAdjustmentBehavior = .never
            kayaPinPlainText(view)
            return view
        }

        func updateUIView(_ view: UITextView, context: Context) {
            context.coordinator.node = node
            // THE PUSH KAYA OWNS — AND NOT WHILE THE USER IS COMPOSING (D4).
            // Measured 2026-08-06: a programmatic `view.text =` mid-composition
            // DROPS `markedTextRange` and fires no callback. Unlike macOS,
            // UITextView DOES notify for marked text, so this covers the app.
            if view.text != text, view.markedTextRange == nil { view.text = text }
            // APPLIED ON EVERY UPDATE, not once at construction: a pin that only
            // ran in makeUIView would be quietly lost the day SwiftUI hands back
            // a recycled view or UIKit re-derives a trait.
            kayaPinPlainText(view)
            kayaAuditPlainTextPins(view)
            // THE RANGES, IN THE SAME PASS AS THE TEXT PUSH ABOVE, and in that
            // order: what is declared over a document has to land with the
            // document, not a main-queue turn after it.
            applyRanges(view, context.coordinator)
            // FOCUS ON THE FAR SIDE OF THE RENDER: becoming first responder
            // re-enters this view's delegate, which writes the very model this
            // update is reading. The next main-queue turn re-reads the model
            // first, so a focus that moved in between wins.
            let wants = focusedId == node.id
            if wants != view.isFirstResponder {
                let id = node.id
                DispatchQueue.main.async { [weak view] in
                    guard let view, (kayaScene.focusedId == id) == wants else { return }
                    if wants {
                        view.becomeFirstResponder()
                    } else {
                        view.resignFirstResponder()
                    }
                }
            }
        }

        /// The three primitives, lowered onto the owned view. HIGHLIGHT WRITES
        /// DOCUMENT ATTRIBUTES, the mac arm's mechanism and here a measured
        /// choice: TextKit 2 RENDERING attributes paint only once something calls
        /// `setNeedsDisplay()` (docs/probes/range-probe-ios.md N1/S1).
        private func applyRanges(_ view: UITextView, _ coordinator: Coordinator) {
            let storage = view.textStorage
            let full = NSRange(location: 0, length: storage.length)
            // UNCONDITIONALLY, on every update pass, and that is measured: 200
            // clear passes over a 200 KB document cost 2.47ms. CLEARED BEFORE
            // ANYTHING IS APPLIED: a re-declare that does not clear first UNIONS
            // with the stale shifted run, leaving {51,6} for a declared {51,5}.
            storage.beginEditing()
            storage.removeAttribute(.backgroundColor, range: full)
            if highlightsFor == text {
                // Bounds re-checked against the LIVE storage: its length is a
                // fact only this side holds at this instant.
                for range in highlights where NSMaxRange(range) <= storage.length {
                    storage.addAttribute(
                        .backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.55),
                        range: range)
                }
            }
            storage.endEditing()

            // THE TWO ONE-SHOTS, each performed once per request, both clamped to
            // the live text: an out-of-range selection is CLAMPED TO A CARET AT
            // THE END (measured, `set{20,3}` on a 6-unit document reading back
            // `{6,0}`), moving the caret where the app never asked.
            let length = ((view.text ?? "") as NSString).length
            if let range = selectRequest, selectSeq != coordinator.selectDone,
                NSMaxRange(range) <= length
            {
                coordinator.selectDone = selectSeq
                // D4, AND THE ONLY PARTY THAT CAN ENFORCE IT: an input-method
                // composition is live in the view and on no kaya channel, so
                // this refuses as a no-op under a named reason — UNIFORM
                // SEMANTICS, even though iOS would not commit the marked text.
                if view.markedTextRange != nil {
                    kayaDiag("select_range refused: ime_composition (widget \(node.id))")
                } else {
                    view.selectedRange = range
                }
            }
            if let range = revealRequest, revealSeq != coordinator.revealDone,
                NSMaxRange(range) <= length
            {
                coordinator.revealDone = revealSeq
                // THE LAYOUT BELOW THE VIEWPORT IS AN ESTIMATE, AND A SCROLL
                // COMPUTED AGAINST IT LANDS SHORT: `scrollRangeToVisible` uses
                // TextKit 2's guess without saying so, measured landing the last
                // line 10pt below the fold with nothing re-scrolling after.
                if let layout = view.textLayoutManager,
                    let content = layout.textContentManager,
                    let end = content.location(
                        content.documentRange.location, offsetBy: NSMaxRange(range)),
                    let laid = NSTextRange(location: content.documentRange.location, end: end)
                {
                    layout.ensureLayout(for: laid)
                }
                // WITHOUT ANIMATION, the difference between a deterministic verb
                // and a sleep: `scrollRangeToVisible` is ANIMATED on iOS (~300ms,
                // a no-op at the call site), so a leg asserting immediately
                // fails. Wrapped, it lands synchronously (3.95ms).
                UIView.performWithoutAnimation { view.scrollRangeToVisible(range) }
            }
        }
    }

    /// EVERY OPINION THE RICH CONTROL CARRIES, PINNED OFF: a UITextView arrives
    /// with the keyboard's whole editorial voice switched on — capitalization,
    /// autocorrect, typographic quotes, predictions, Writing Tools, attributed
    /// pasteboard runs, a find interaction. kaya's textarea contract is BYTES.
    func kayaPinPlainText(_ view: UITextView) {
        // The substitutions the keyboard performs on typed text. The first is
        // the one with teeth on a phone: `.sentences` is the SDK default, so an
        // unpinned textarea capitalizes the first letter the user types and
        // `text_changed` carries a byte nobody entered.
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        // Smart insert/delete rewrites the SPACES around a paste or a deletion,
        // which is the same class of unasked-for edit.
        view.smartInsertDeleteType = .no
        // The QuickType bar's inline prediction (iOS 17) inserts a run the app
        // never saw typed.
        view.inlinePredictionType = .no
        // Rich editing and rich paste. `NO` is already the SDK default for
        // allowsEditingTextAttributes, which is why it is written down rather
        // than assumed: it decides whether Bold/Italic/Underline appear in the
        // edit menu and whether an RTF paste keeps its attributes.
        view.allowsEditingTextAttributes = false
        // The item-provider side of the same claim: this control takes what reads
        // as a plain String and nothing else, so the type set is Foundation's
        // rather than one written here — measured as five identifiers, against
        // the eight an NSAttributedString configuration brings.
        view.pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)
        // Data detectors run only on a non-editable view, so this is a
        // declaration rather than a fix, kept for the same reason.
        view.dataDetectorTypes = []
        // THE FIND INTERACTION IS THE CANARY (iOS 16), the one pin UIKit answers
        // for itself: `findInteraction` is non-nil iff this flag is set, so the
        // audit reads UIKit rather than the line above. Off for the mac arm's
        // reason too — a find bar moves the selection and the scroll offset.
        view.isFindInteractionEnabled = false
        if #available(iOS 18.0, *) {
            // Writing Tools rewrites the whole document, in place, through a
            // path that is not this view's delegate.
            view.writingToolsBehavior = .none
            // Math completion turns a typed `2+2=` into `2+2=4`.
            view.mathExpressionCompletionType = .no
        }
    }

    /// Is the scene interpreter running? The pin audit is a harness instrument
    /// and costs a shipped app nothing.
    let kayaHarnessActive = ProcessInfo.processInfo.environment["KAYA_SELFTEST"] != nil

    /// Pins found NOT in force on a live control, by name. Written on the main
    /// thread by the audit, folded into the scene's failures by kayaRunScript.
    var kayaPlainTextPinBreaches: Set<String> = []

    /// The pins, read back off the LIVE control: each is in force on the object
    /// the user types into, though not that UIKit honours it, since iOS has no
    /// in-process way to press a key. TWO CLAUSES ARE UIKIT'S OWN ANSWER — the
    /// find interaction, and a TextKit 2 layout manager's survival.
    func kayaAuditPlainTextPins(_ view: UITextView) {
        guard kayaHarnessActive else { return }
        var breaches: [String] = []
        func want(_ ok: Bool, _ name: String) {
            if !ok { breaches.append(name) }
        }
        want(view.autocapitalizationType == .none, "autocapitalizationType")
        want(view.autocorrectionType == .no, "autocorrectionType")
        want(view.spellCheckingType == .no, "spellCheckingType")
        want(view.smartQuotesType == .no, "smartQuotesType")
        want(view.smartDashesType == .no, "smartDashesType")
        want(view.smartInsertDeleteType == .no, "smartInsertDeleteType")
        want(view.inlinePredictionType == .no, "inlinePredictionType")
        want(!view.allowsEditingTextAttributes, "allowsEditingTextAttributes")
        want(view.dataDetectorTypes.isEmpty, "dataDetectorTypes")
        // The pasteboard side, against FOUNDATION'S OWN ANSWER to "what reads as
        // a plain String" rather than a list maintained here (measured: five
        // identifiers against an attributed configuration's eight). A cleared
        // configuration reads empty, UITextView's default, so it is a breach too.
        let accepts = Set(view.pasteConfiguration?.acceptableTypeIdentifiers ?? [])
        want(
            !accepts.isEmpty && accepts == Set(NSString.readableTypeIdentifiersForItemProvider),
            "pasteConfiguration")
        want(view.findInteraction == nil, "findInteraction")
        want(view.textLayoutManager != nil, "textLayoutManager")
        if #available(iOS 18.0, *) {
            want(view.writingToolsBehavior == .none, "writingToolsBehavior")
            want(view.mathExpressionCompletionType == .no, "mathExpressionCompletionType")
        }
        if !breaches.isEmpty { kayaPlainTextPinBreaches.formUnion(breaches) }
    }
#endif

/// The prefix a SECTION SWITCHER ROW's rendering arm publishes on its
/// accessibility identifier; BOTH ARMS AND BOTH HOSTS publish it from the ONE
/// body below. WHAT IT IS WORTH DIFFERS BY HOST: the symbol ANSWER on macOS,
/// where SwiftUI exposes no image object (measured), a DIAGNOSTIC on iOS.
let kayaSectionSymbolIdent = "kaya-section-symbol:"

/// ONE ROW BODY FOR EVERY SECTION SWITCHER, so that "what a section row draws" is
/// a single arm. The identifier is published on EVERY arm, symbol or not: "the
/// row is there and drew no glyph" and "there is no row" are different
/// measurements that stamping only glyph-bearing rows would collapse.
struct KayaSectionLabel: View {
    let title: String
    let symbol: Int64

    /// Does this OS actually draw the glyph kaya asked for? The rename trap
    /// fails as a SILENT BLANK, so the resolution is checked in the render path
    /// and not only in the read (kayaPromotedSymbolWhyNot's rule).
    private func drawable(_ sf: String) -> Bool {
        #if os(macOS)
            return NSImage(systemSymbolName: sf, accessibilityDescription: nil) != nil
        #else
            return UIImage(systemName: sf) != nil
        #endif
    }

    var body: some View {
        if symbol != 0, let sf = kayaSFSymbol(symbol), let name = kayaSymbolName(symbol),
            drawable(sf)
        {
            Label(title, systemImage: sf)
                .accessibilityIdentifier(kayaSectionSymbolIdent + name)
        } else if symbol != 0 {
            // A declared symbol this host cannot draw. The row stays usable as
            // text and the identifier says which of the two causes was measured.
            Text(title)
                .accessibilityIdentifier(
                    kayaSectionSymbolIdent + kayaPromotedSymbolWhyNot(symbol))
        } else {
            Text(title)
                .accessibilityIdentifier(
                    kayaSectionSymbolIdent + "the section row drew its title as text, no icon")
        }
    }
}

/// A window's sections materialized: TabView carries the platform's dominant
/// idiom under the `auto` hint, `sidebar` resolves to NavigationSplitView on
/// macOS, and the phones ignore hints by physics. Each pane hosts ITS OWN
/// NavigationStack, and the selection setter fires only for USER switches.
struct KayaSectionsView: View {
    let windowId: UInt64
    @State private var scene = kayaScene

    private var selection: Binding<UInt64> {
        Binding(
            get: {
                scene.windows[windowId]?.selectedSection
                    ?? scene.windows[windowId]?.sections.first?.id ?? 0
            },
            set: { sid in
                guard let window = scene.windows[windowId],
                    window.selectedSection != sid
                else { return }
                window.selectedSection = sid
                KayaHost.emitSectionSelected(windowId, sid)
            })
    }

    var body: some View {
        if let window = scene.windows[windowId] {
            #if os(macOS)
                if window.sectionsPresentation == sectionsPresentationSidebar {
                    // The leading-edge list spelling, honored where the
                    // platform has it.
                    NavigationSplitView {
                        List(
                            window.sections,
                            selection: Binding<UInt64?>(
                                get: { selection.wrappedValue },
                                set: { if let sid = $0 { selection.wrappedValue = sid } })
                        ) { section in
                            // Label, not Text, so a section that named a SEMANTIC
                            // ICON gets the platform's own glyph beside its title
                            // (docs/styling-plan.md D6). ONE body with the tab
                            // arm below, so a perturbation moves both.
                            KayaSectionLabel(title: section.title, symbol: section.symbol)
                                .tag(section.id)
                        }
                        // EXPLICIT, not inherited: this is what
                        // NavigationSplitView's sidebar column defaults to today,
                        // and a default that changed under an SDK bump would
                        // silently de-modernize every sectioned window.
                        .listStyle(.sidebar)
                    } detail: {
                        KayaSectionPane(sectionId: selection.wrappedValue)
                    }
                    .onAppear { kayaScene.windows[windowId]?.sectionsRendered = "sidebar" }
                    .tint(kayaBrandTint())
                    .font(kayaBrandFont())
                } else {
                    tabBody(window)
                        .onAppear { kayaScene.windows[windowId]?.sectionsRendered = "bar" }
                        .tint(kayaBrandTint())
                        .font(kayaBrandFont())
                }
            #else
                tabBody(window)
                    .onAppear { kayaScene.windows[windowId]?.sectionsRendered = "bar" }
                    .tint(kayaBrandTint())
                    .font(kayaBrandFont())
            #endif
        }
    }

    private func tabBody(_ window: KayaWindowModel) -> some View {
        TabView(selection: selection) {
            ForEach(window.sections) { section in
                KayaSectionPane(sectionId: section.id)
                    .tabItem {
                        // The tab bar is the switcher that most wants an icon — a
                        // bare-text bottom bar is not the platform's real thing
                        // (DESIGN.md, Sections).
                        KayaSectionLabel(title: section.title, symbol: section.symbol)
                    }
                    .tag(section.id)
            }
        }
    }
}

/// One section's pane: the mounted root in the normalized frame over the
/// section's own stack — the KayaAuxRoot shape on a section surface.
struct KayaSectionPane: View {
    let sectionId: UInt64
    @State private var scene = kayaScene

    var body: some View {
        NavigationStack(path: kayaNavPath(sectionId)) {
            Group {
                if let section = scene.sectionsById[sectionId], let root = section.root {
                    KayaRender(node: root, isRoot: true)
                }
            }
            // The owning window's inset — same reasoning as the
            // entry site above.
            .padding(scene.windows[0]?.inset ?? 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The hosting window's catalog rides each pane's top bar on iOS
            // (sections share the window's command catalog).
            .modifier(KayaMenuChrome(windowId: scene.sectionWindow[sectionId] ?? 0))
            .navigationDestination(for: UInt64.self) { eid in
                KayaEntryRoot(entryId: eid)
            }
        }
    }
}

/// THE SCALE AND APPEARANCE REPORT (docs/canvas-plan.md §5, §6): the backend
/// reports, the core re-rasters every canvas. MEASURE-AT-IMPLEMENTATION #3 (§11)
/// IS STILL OPEN — that `\.displayScale` updates across differently-scaled
/// displays is inferred, not measured, on a one-display machine.
private struct KayaPresentationReporter: ViewModifier {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .onAppear {
                // iOS's windows exist only now (macOS installed it before its
                // first window, in KayaAppDelegate). Installing it here flips
                // the trait, which fires the colorScheme onChange below, so the
                // report corrects itself whatever order these run in.
                kayaApplyAppearanceOverride()
                report()
            }
            .onChange(of: displayScale) { _, _ in report() }
            .onChange(of: colorScheme) { _, _ in report() }
    }

    private func report() {
        KayaHost.presentation(displayScale, colorScheme == .dark)
    }
}

struct KayaRoot: View {
    @State private var scene = kayaScene
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
        if scene.windows[0]?.sections.isEmpty == false {
            // Sections present: the switcher IS the window content
            // (each pane carries its own stack).
            KayaSectionsView(windowId: 0)
        } else if kayaSplitArm(0) {
            // ADAPTIVE PANES (DESIGN.md; docs/multicolumn-plan.md): the base
            // root takes the leading pane, the stack's TOP the trailing one, and
            // a ceiling of three gives the first entry a middle column. The
            // entries between stay retained and covered.
            if (scene.windows[0]?.panes ?? 1) >= 3 {
                KayaSplitRoot3(windowId: 0)
            } else {
                KayaSplitRoot(windowId: 0)
            }
        } else {
        // The primary surface's stack: pushed entries cover this root serially;
        // the root is the stack's base and stays alive underneath. This arm
        // stamps "stacked" for the same reason the split arm stamps "split": an
        // observation only WRITTEN by one arm is derived by default in the other.
        NavigationStack(path: kayaNavPath(0)) {
        // The outer GeometryReader IS the offer: it fills whatever the window
        // proposes inside the padding, and expect_root_fills compares the root's
        // rendered size against it. Both readings are geometry, so no
        // speculative layout pass can clobber them.
        GeometryReader { available in
            Group {
                if let root = scene.root {
                    KayaRender(node: root, isRoot: true)
                        .background(
                            GeometryReader { geo in
                                Color.clear
                                    .onAppear { kayaRootSize = geo.size }
                                    .onChange(of: geo.size) { _, size in
                                        kayaRootSize = size
                                    }
                            }
                        )
                }
            }
            .onAppear { kayaAvailableSize = available.size }
            .onChange(of: available.size) { _, size in
                kayaAvailableSize = size
            }
        }
        // The normalized root inset, now the window's OWN (wprop 8,
        // docs/styling-plan.md D3): 16 unless the app says otherwise, 0 for full
        // bleed. This is the primary surface, window 0.
        .padding(kayaScene.windows[0]?.inset ?? 16)
        // The OUTER half of the measured-inset observation: this reader sits
        // just outside the padding, its inner twin just inside;
        // (outer - inner)/2 is the inset the harness asserts.
        .background(
            GeometryReader { outer in
                Color.clear
                    .onAppear { kayaOuterSize = outer.size }
                    .onChange(of: outer.size) { _, size in
                        kayaOuterSize = size
                    }
            }
        )
        // Normalized: pack content to the top-leading corner of the
        // surface rather than letting the window center it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // OUTSIDE the window inset, like KayaEntryRoot's: a background cannot
        // escape explicit padding, only safe-area insets, so worn any lower the
        // grouped ground stops at the content box and the title area keeps the
        // window's own colour (measured 2026-08-30).
        .modifier(
            KayaGroupedScreenGround(
                on: scene.groupedWindows.contains(0)))
        // The primary surface's title (initially the process name, so an unset
        // prop changes nothing): SwiftUI's blessed window titling path on macOS;
        // harmless on iOS, where the switcher label is stamped in the apply arm.
        .navigationTitle(kayaWindowCaption(0))
        // THE BRAND ACCENT, applied as .tint of the current appearance's derived
        // FILL — a value the core computed, never re-derived here
        // (docs/styling-plan.md D1, D2). The same tint rides the aux, sections
        // and split roots below: they are SIBLING scene roots, not descendants.
        .tint(kayaBrandTint())
        .font(kayaBrandFont())
        // The window's command catalog rides the window construct: on iOS this is
        // the trailing More menu + promoted bar actions; on macOS the NSMenu
        // segment owns the catalog and this attaches the promoted primaries as
        // the window's NSToolbar.
        .modifier(KayaMenuChrome(windowId: 0))
        .onAppear { kayaScene.windows[0]?.splitPresentation = "stacked" }
        .onChange(of: kayaSplitArm(0)) {
            if !kayaSplitArm(0) { kayaScene.windows[0]?.splitPresentation = "stacked" }
        }
        .navigationDestination(for: UInt64.self) { eid in
            KayaEntryRoot(entryId: eid)
        }
        }
        }
        }
        // The form factor is measured on the WHOLE window, outside the arm chain,
        // so the reading does not depend on which arm rendered — the arm depends
        // on the reading, never the reverse.
        .modifier(KayaFormFactorRecorder(windowId: 0))
        // The breakpoint channel (docs/adaptive-layout-plan.md D3), the
        // form factor's sibling for the same whole-window reason.
        .modifier(KayaWindowMetricsReporter(windowId: 0))
        // The canvas's scale and appearance channel, outside the arm
        // chain for the form factor's reason.
        .modifier(KayaPresentationReporter())
        // The accessor rides OUTSIDE the stack so its view never
        // detaches under a push.
        #if os(macOS)
            .background(KayaWindowAccessor(windowId: 0))
        #endif
        .onAppear {
            // The presentation actions, stashed for the apply arms
            // (mount presents an auxiliary; destroy dismisses it).
            #if os(macOS)
                kayaDiag("primaryRoot appear pending=\(kayaPendingOpens) \(kayaDiagAppState())")
            #endif
            // Batch-independent: the one start path a guest that never
            // sends a node-bearing batch still reaches (measured — this
            // appear fires for an empty window; the content branch's
            // does not).
            kayaArmSelftestStartupDeadline()
            kayaOpenWindow = { openWindow(value: $0) }
            kayaDismissWindow = { dismissWindow(value: $0) }
            for id in kayaPendingOpens {
                kayaEnsureOpen(id) { openWindow(value: $0) }
            }
            kayaPendingOpens.removeAll()
            #if os(macOS)
                // The menu segment's event-driven re-assert hooks — installed
                // before the pump so the first catalog batch cannot race them.
                kayaInstallMenuObservers()
            #else
                // The same idea, one signal: a clipboard change moves
                // what the Paste item is allowed to do.
                kayaInstallClipboardObserver()
            #endif
            kayaPlaceWindow()
            kayaStartCommandPump()
        }
    }
}

// Recording mode tiles parallel legs so one display-scoped capture sees every
// window unoccluded: the runner assigns a slot, the window places (and bounds)
// itself — its own window, no permissions.
private func kayaPlaceWindow() {
    #if os(macOS)
    guard let raw = ProcessInfo.processInfo.environment["KAYA_WIN_SLOT"],
        let slot = Int(raw),
        let window = NSApplication.shared.windows.first
    else { return }
    // A screen-derived grid, cells sized for this backend's 540x330 windows,
    // partial last cell counting when the window still fits.
    let vis = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let cols = max(1, Int((vis.width - 20 - 540) / 570) + 1)
    let rows = max(1, Int((vis.height - 40 - 330) / 345) + 1)
    let bounded = slot % (cols * rows)
    let x = 20.0 + Double(bounded % cols) * 570.0
    let y = 40.0 + Double(bounded / cols) * 345.0
    window.setFrame(NSRect(x: x, y: y, width: 540, height: 330), display: true)
    #endif
}
