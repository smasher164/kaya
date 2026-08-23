// KayaSwiftUI: the Swift half of the SwiftUI backend — an interpreter of
// resolved apply-op records over the presentation-side C ABI.
//
// The pump blocks in next_commands on its own thread and hops to the main
// actor to apply. Signals, collections and templates never reach this
// layer; the core resolves them before the records leave kaya_next_commands.

import SwiftUI
import UniformTypeIdentifiers

// Pinned to the KAYA_APPLY_* / KAYA_KIND_* / KAYA_VALUE_* constants in
// kaya.h; spelled here for use in switch patterns.
/// KAYA_SPEC_HASH, asserted against the host's kaya_spec_hash at entry —
/// the runtime half of the stale-artifact guard, presentation side.
let kayaSpecHash: UInt64 = 0x1c6b68dc2656ea21

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
private let propText: UInt32 = 1
private let propChecked: UInt32 = 2
private let propColumns: UInt32 = 11
/// The accessibility identifier (never spoken) and label (spoken).
private let propA11yId: UInt32 = 12
private let propA11yLabel: UInt32 = 13
private let propA11yHint: UInt32 = 14
/// Which clip representations this widget accepts: a space-separated string
/// of closed kind names and custom format ids. Not a mask.
private let propAccepts: UInt32 = 15
/// Semantic emphasis (docs/styling-plan.md D4); the variant values follow.
private let propRole: UInt32 = 16
private let propInset: UInt32 = 17
private let roleDestructive: Int64 = 1
private let roleProminent: Int64 = 2
private let roleHeading: Int64 = 3
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
private let propIndeterminate: UInt32 = 10
// The align enum's wire values (spec enum "align").
private let alignStart: Int64 = 0
private let alignCenter: Int64 = 1
private let alignEnd: Int64 = 2
private let alignStretch: Int64 = 3
private let alignBaseline: Int64 = 4
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

/// THE SEMANTIC ICON TABLE (docs/styling-plan.md D6): one row per
/// vocabulary entry — the wire value, the name kaya's apps write, and
/// the SF Symbols spelling Apple ships.
///
/// THE SF COLUMN IS NOT RECALLED, and must never be edited from the SF
/// Symbols app. It was generated against
/// `/System/Library/CoreServices/CoreGlyphs.bundle/.../name_availability.plist`
/// and every string resolved live through
/// `NSImage(systemSymbolName:)` with failing canaries beside it
/// (docs/styling/symbols-sf-symbols.md). Two traps live in this column:
///
///  - `copy`/`paste` are `doc.on.doc`/`doc.on.clipboard`, NOT
///    `document.on.document`/`document.on.clipboard`. Apple renamed
///    that family in SF Symbols 6; the NEW names need macOS 15 / iOS 18
///    and fail as a BLANK IMAGE below that, with no compile error and
///    no runtime complaint. Worse, Apple's own search index has already
///    moved: searching the catalog for "copy" returns only the macOS-15
///    name. kaya's floor is macOS 13 / iOS 16, so the old spellings are
///    the correct ones and they still resolve on the newest OS.
///  - `home` is `house`. There is no symbol called `home`.
///
/// The highest requirement in this column is macOS 11 / iOS 14
/// (`gearshape`, `chevron.backward`, `chevron.forward`), comfortably
/// under the floor.
///
/// AND NO SCENE CAN GUARD THIS COLUMN — measured 2026-08-16, not
/// assumed. Shipping `document.on.document` here and running the menus
/// scene on this machine PASSED: the macOS-15 name resolves perfectly
/// on a current OS, and every machine the project runs on is a current
/// OS. A resolution check only fails on a machine old enough to BE the
/// floor, so the assertion that looks like the guard is vacuous
/// everywhere it is run. The only thing that can answer is Apple's own
/// `name_availability.plist` — every name's introduction year against
/// the declared floor — which is tools/check-symbols.sh: it reads the
/// `sf` column out of this table and self-tests by perturbing
/// doc.on.doc to the macOS-15 rename on every run.
///
/// THE `rendered` COLUMN IS THE OTHER HALF OF THAT SAME TRAP, and it is
/// what a READ meets rather than a lowering. `sf` is what kaya ASKS FOR;
/// SwiftUI resolves the alias before UIKit sees the image, so the glyph
/// on screen publishes the CANONICAL name on its UIImageView's
/// accessibility identifier — kaya asks `doc.on.doc` and the bar renders
/// `document.on.document`. Any read that inverts a rendered glyph back
/// to this vocabulary therefore matches THE REQUEST OR THE RENDERED
/// NAME (kayaToolbarIOSSemantic), and this column is nil wherever the
/// two agree.
///
/// MEASURED, ALL 20, NOT RECALLED: a probe rendered every row the way
/// the promoted bar does — `Label(name, systemImage: sf)` in a
/// `ToolbarItemGroup(.primaryAction)` inside a NavigationStack, one row
/// per pass in a fresh hosting controller — and read the identifier back
/// through kayaToolbarIOSButtons' own walk (iOS 26.5, 2026-08-17;
/// docs/chrome/sf-rendered-names.md holds the 20-row table, the
/// probe and its canaries). EXACTLY TWO ROWS DIFFER, and they are the
/// `doc.*` -> `document.*` family SF Symbols 6 renamed. The rename is
/// not a relabeling: the rendered image is a DIFFERENT UIImage object
/// from the one `UIImage(systemName: sf)` returns, which is why the two
/// are not `isEqual` and why no runtime route reconciles them.
///
/// A row here is this OS's answer. An older OS renders the asked
/// spelling and inverts through `sf`; a newer one that renames another
/// family adds a row — and the read that meets it says which glyph it
/// measured, so the next reader is told rather than left hunting.
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

/// Why a declared symbol could not be drawn as a glyph. TWO causes this
/// reader can tell apart: a value this interpreter's table does not carry,
/// or a row whose SF spelling this OS refuses — the rename trap, which
/// fails as a silent blank image, so resolution is checked in the RENDER
/// path and not only in the read. One sentence for both platforms.
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
    /// Semantic emphasis (docs/styling-plan.md D4), 0 = none — never a raw
    /// color.
    var role: Int64 = 0
    /// A container's own padding (docs/styling-plan.md D3): DIP between its
    /// bounds and its children, uniform. 0 = flush, every container's default.
    var inset: Double = 0
    /// The widget's accept list, verbatim; empty means it takes nothing.
    var accepts = ""
    var checked = false
    var value = 0.0
    var minValue = 0.0
    var maxValue = 1.0
    // The decoded native image (nil is the placeholder class) and its size
    // as the harness's "WxH" observation ("0x0" before a source lands or
    // after a failed decode).
    var image: KayaPlatformImage?
    var imageSize = "0x0"
    // The scroll observations (scroll viewports only), recorded by the
    // render's readers, never a model copy.
    var scrollViewportH = 0.0
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
    /// TEXT RANGES (textarea only), in UTF-16 code units — the unit the core
    /// converted to and the unit NSRange speaks. `highlights` is the DECLARED
    /// SET and `highlightsFor` the text it was declared against: the lowering
    /// paints only while the widget still holds that exact text, so any edit
    /// drops it. That comparison is made at PAINT time and so cannot arrive
    /// late; see spec.rs's Prop::Highlights and docs/ranges-plan.md.
    var highlights: [NSRange] = []
    var highlightsFor: String?
    /// The two one-shot effects carry a SEQUENCE NUMBER rather than a
    /// consumed optional: `updateNSView` runs many times for one model change
    /// and must not write the model back. The view remembers the last
    /// sequence it performed.
    var selectRequest: NSRange?
    var selectSeq = 0
    var revealRequest: NSRange?
    var revealSeq = 0
    var children: [KayaNode] = []
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
    /// Cell leading edges in window space, keyed "<rowId>/<col>" (and
    /// "h/<col>" where kaya composes the header) — written by the
    /// render's edge reporters, clustered by expect_column_edges. The
    /// native macOS header is NSTableView's own and aligns with its
    /// cells by construction, so that path records cells alone.
    var cellEdgeX: [String: Double] = [:]

    init(id: UInt64, kind: UInt32, tag: [UInt8]) {
        self.id = id
        self.kind = kind
        self.tag = tag
    }
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
    /// The window's live FORM FACTOR, written by the view layer from the
    /// platform's own size-class reading. The adaptivity axis is THIS, never
    /// the operating system (DESIGN.md, "Form factor and adaptivity"); macOS
    /// has no size classes and reports `regular`. `unknown` is the
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
    var images: [KayaNode] = []
    var columns: [KayaNode] = []
    var rows: [KayaNode] = []
    var scrolls: [KayaNode] = []
    var progresses: [KayaNode] = []
    var selects: [KayaNode] = []
    var radios: [KayaNode] = []
    var grids: [KayaNode] = []
    var textareas: [KayaNode] = []
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

/// Absolute timestamps on stderr so a leg log correlates with `log show`.
func kayaDiag(_ msg: String) {
    let line = String(format: "KAYA_DIAG %.3f %@\n", Date().timeIntervalSince1970, msg)
    FileHandle.standardError.write(line.data(using: .utf8)!)
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
        // NOT the temp directory on iOS: the app's `TMPDIR` is inside its
        // container and the document picker browses PROVIDERS, so a picker
        // aimed there opens somewhere else with no error. Documents is
        // browsable only because the bundle declares UIFileSharingEnabled and
        // LSSupportsOpeningDocumentsInPlace (tools/ios/Info.plist.in;
        // docs/file-dialogs-plan.md). The guest computes the same place from
        // `HOME`.
        return (NSHomeDirectory() as NSString).appendingPathComponent("Documents")
    #else
        return ProcessInfo.processInfo.environment["TMPDIR"].map {
            ($0 as NSString).standardizingPath
        } ?? "/tmp"
    #endif
}

// ---- Text ranges: the ONE place this file converts an offset -------
//
// The lowering path does no arithmetic and must not: offsets arrive from the
// core already in UTF-16 code units, converted against the same text the core
// validated them against (docs/ranges-units.md §7).
// THE READING DIRECTION IS DIFFERENT AND IS DELIBERATE. A harness verb
// compares one frozen string on five lanes (invariant 6), so a read
// must answer in the PROTOCOL's unit — UTF-8 byte offsets — and the
// only party holding the widget's real text is this side. The
// conversion is exact, not approximate: `String.Index(utf16Offset:in:)`
// silently ROUNDS an offset that lands inside a character, and
// `samePosition(in: unicodeScalars)` is nil on precisely the offsets
// Rust's `is_char_boundary` rejects — measured identical on both hazard
// strings by the units arm — so an offset that cannot be converted is
// reported as such rather than quietly moved.

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
/// `<start>:<end>=<covered text>` per range, `|`-joined, ascending.
///
/// THE COVERED TEXT IS NOT DECORATION. Offsets alone would make this read the
/// exact inverse of the lowering's own conversion, so two symmetric mistakes
/// would cancel; the covered text has no arithmetic in it.
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

// A depth stub is a CALL, never a sentence — tools/check-stubs.sh reads
// it; the platform argument exists because this one file serves mac AND iOS.
func kayaDepthStub(_ scene: String, on platform: String) -> Never {
    fatalError(
        "kaya: the \(scene) scene is not yet materialized on \(platform) — "
            + "it is a depth slice; see CLAUDE.md's sequencing")
}

// ---- The clipboard ------------------------------------------------
//
// One clip, offered in several representations at once; the consumer takes
// the richest it understands. The values arrive in kaya's canonical order —
// descending clip value, which IS descending richness — and that is already
// the preference order a pasteboard consumer walks, so this writes them in
// the order it reads them. The measurements behind the representation
// choices are in docs/clipboard-plan.md.

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

/// Put one clip on the system clipboard.
///
/// SEVERAL FILES MEANS SEVERAL ITEMS on this platform, so item 0 carries every
/// single-valued representation plus the first file and each later item one
/// more file. The text rendition of a file list is DERIVED HERE, and only when
/// the clip offers no text of its own.
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
        // ITEM 0 GOES THROUGH THE PASTEBOARD-LEVEL PATH, NEVER
        // NSPasteboardItem: the item path VALIDATES its type strings as UTIs
        // and DROPS a mime-shaped custom id with only a console log to say so
        // (docs/clipboard-plan.md §5b finding 4). Declared in descending
        // richness, the canonical order.
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
        // ONE WRITE PATH here, and that is the difference from the arm above:
        // `items` takes an arbitrary type string VERBATIM, the slashed custom
        // id included (docs/clipboard-plan.md §8 finding 1), so there is no
        // item-vs-board dance to pick between. A dictionary keeps no order and
        // nothing here needs it to: every consumer asks for a type by name.
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
        // AND KAYA'S OWN MARKER, on item 0 beside the payload: the whole of
        // the witness's evidence on this platform (kayaClipMarkerType). It can
        // answer no read — every arm of the walk gates on the ACCEPT LIST
        // first, and no accept list names kaya's namespace. A clip with no
        // representations at all still leaves this item.
        item[kayaClipMarkerType] = kayaClipMarkerBytes
        // SEVERAL FILES MEANS SEVERAL ITEMS here too, and here EVERY file is
        // its own item rather than the first riding along: this write owns the
        // items directly, where declareTypes owns the BOARD.
        var items: [[String: Any]] = [item]
        for url in urls { items.append([kayaClipUTI("files"): url]) }
        // The assignment IS the clear — `items` replaces the board.
        UIPasteboard.general.items = items
    #endif
    // THE BOARD KAYA NOW OWNS. Anything that moves it after this line was
    // somebody else, and the diagnostics say so by name (kayaClipOwnerClause).
    // Composed by this very function, so on iOS the marker above must be on
    // the board it reads back — and if it is not, the stage says so.
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
    /// Materialize a clip OFF THE CALLING THREAD and hand the answer back on
    /// the main queue: the one route both the privileged read and the paste
    /// split take on this platform.
    ///
    /// A DATA READ OF FOREIGN CONTENT BLOCKS ON A PROMPT and does not return
    /// until someone answers it (docs/clipboard-plan.md §0e finding 2), so it
    /// can never run on the main queue — a parked main thread stops drawing
    /// the very screen the alert is on and takes the harness thread down with
    /// it. The read parks ONLY its own thread.
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

    /// Answer the paste prompt from the host while a read is in flight.
    ///
    /// THE PROMPT IS PER-CLIP, not per-pair (§8 finding 2), and the alert is
    /// an out-of-process overlay, which is why the host can reach it and this
    /// app cannot. TOLERANT BY CONSTRUCTION: an own-content read never
    /// prompts, so "nothing to press" is the ordinary case. The press runs
    /// BESIDE the read — the alert only exists once the read has blocked — and
    /// stops the moment the read returns, because the bridge is a single
    /// request file.
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

/// ONE LINE WHEN A READ ANSWERS NOTHING, naming what was asked for and what
/// the clipboard was actually holding. Empty is a legitimate answer with four
/// indistinguishable causes (denied, unfocused, absent, or nothing this read
/// accepted), so the GUEST cannot report which and the backend can
/// (docs/clipboard-plan.md §8 finding 7).
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
/// the witness's evidence there: UIPasteboard hands out no counter a reader
/// may believe (docs/traps.md, "UIPasteboard's changeCount is a PER-PROCESS
/// number"). AN ARBITRARY STRING, NOT A UTI — UIPasteboard takes a type string
/// verbatim, slash and all — in kaya's own namespace. macOS DOES NOT CARRY IT:
/// NSPasteboard's count moves on writes and only on writes. THE BYTES ARE
/// NEVER READ; presence is the whole signal.
let kayaClipMarkerType = "dev.kaya/staged"
let kayaClipMarkerBytes = Data("staged".utf8)

/// What the board this leg staged has been replaced by, in the terms the
/// PLATFORM ACTUALLY MEASURED. The two platforms measure different facts and a
/// step's failure sentence may only claim the one that was measured
/// (invariant 3), so the evidence travels as a value and each case renders
/// itself — no shared sentence with a platform-shaped hole in it.
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

/// Remember the board kaya just produced, and close the stage that produced
/// it. Every clipboard write kaya asks for ends here.
///
/// `composed` is whether the ITEMS were built by a writer kaya controls — this
/// file's own `items =`, or tools/ios/clipctl for a seed — as against a clip
/// UIKit or AppKit composed down the responder chain. Only a composed clip can
/// be expected to carry kaya's marker, and only iOS reads it.
///
/// IT RECORDS WHAT IT SEES, NOT WHAT THE WRITE MEANT, and a composed stage
/// that lost its marker FAILS THE LEG — which also pins the marker's spelling
/// across the two binaries that write it, this file and
/// tools/ios/clipctl/main.swift (docs/traps.md).
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

/// The board this leg staged against the board that is there now, or nil when
/// they are the same one — the single comparison the trace clause and the
/// witness below both read.
///
/// THE TWO PLATFORMS MEASURE DIFFERENT FACTS, and this is the one place that
/// knows it: macOS compares the change count, iOS the presence of kaya's
/// marker, and neither borrows the other's evidence. The count cannot serve on
/// iOS and neither can the notification (docs/traps.md, "UIPasteboard's
/// changeCount is a PER-PROCESS number").
///
/// WHAT THE MARKER CANNOT SEE, said here because a guard nobody has bounded
/// gets believed past its evidence. It sees the staged clip REPLACED. It does
/// not see a stranger who writes a clip CARRYING kaya's marker, nor a writer
/// who APPENDS an item and leaves kaya's in place — which the macOS count does
/// catch. That is the right trade for the threat model: a machine-wide
/// resource shared by ACCIDENT, not a boundary against anyone who is trying.
///
/// Silent before this leg has staged anything, silent inside a stage
/// (kayaClipStages), and on iOS silent after a stage that left no marker.
/// ONE OBSERVATION OF THE BOARD backs both halves of what this returns.
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

/// A clause naming a board that has changed since kaya last wrote it, or ""
/// when the board is still the one kaya left.
///
/// A pasteboard has no "who wrote it", so every failure whose real cause is a
/// second principal — a VM's clipboard relay, a clipboard manager, a sibling
/// lane — arrives as kaya's own step reading the wrong thing, and the session
/// that gets it starts by suspecting kaya (docs/traps.md). On iOS the marker
/// answers both ways; the middle case — nothing staged yet, or a stage that
/// left no marker — stays quiet, because nothing was measured.
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
/// staged. Nothing happens on the matching path.
///
/// A machine has ONE pasteboard and every process on it is a writer, so a
/// leg's staged clip can be replaced under it by anybody, and the step's
/// sentence for that is the same sentence a broken paste prints
/// (docs/traps.md). Whatever a platform can measure about the board's identity
/// is the evidence that separates them, and this is where it gets read.
///
/// IT SAYS WHAT IT MEASURED AND STOPS THERE. WHO replaced the content is not
/// on the pasteboard at all — no API answers it — so this names nobody; the
/// type list is the board as it is now, for the reader who has to guess.
/// kayaClipDrifted answers in whichever terms its platform can measure and
/// this renders what it was handed, so there is no `#if` here.
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

/// The core's latched fault, for the harness to end a run with. A guard that
/// caught an app misuse, or a transaction that died inside Scene::apply, used
/// to ABORT this process — taking the failure list with it — and now reports
/// through here instead (crates/kaya/src/fault.rs).
///
/// SIZED, THEN READ, exactly as Asset.missSentence does it: the host returns
/// the sentence's TRUE length, and a guessed buffer would cut the half that
/// names the cause. A PEEK, never a take: the run asks again after its last
/// step, and a consuming read would let that look report a green leg.
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
        let (kinds, custom) = kayaParseAcceptList(accepting)
        let board = NSPasteboard.general
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
    #else
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
    #endif
}

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

/// Run one of the platform's own clipboard tools as a CHILD PROCESS and hand
/// back what it did. The tools are Apple's — `pbcopy`, `pbpaste`, `osascript`,
/// `sips` — never anything kaya wrote, because the whole value of the foreign
/// side is that it does not share our assumptions about the lowering.
///
/// NOT `@discardableResult`, and that one missing attribute is the guard: the
/// COMPILER refuses a dropped answer at the callsite. A caller that genuinely
/// has nothing to do with it says so by name — `kayaToolNote(kayaRunTool(…))`.
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
/// ONE PLACE THE TWO BOARDS DIFFER, so everything built on it is written once
/// and cannot drift between the platforms this file serves.
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
        // THE SEED IS A SPAWNED WRITER ON THIS DEVICE, asked for over the
        // host bridge, because this process has no way to be another app and
        // no stock tool to run. The host spawns tools/ios/clipctl, whose write
        // is visible to other processes before the spawn exits (§8 finding 6).
        // The payload rides base64 because the watcher word-splits the request
        // line.
        let payload = Data(arg.utf8).base64EncodedString()
        let (ok, lines) = KayaSimdrive.ask("clip_seed \(kind) \(payload)")
        return ok ? nil : (lines.first ?? "the host refused without saying why")
    #endif
}

/// Put content on the clipboard FROM OUTSIDE this app, so a read leg is
/// answering something this process did not write.
///
/// CUSTOM FORMATS ARE NOT SEEDABLE and deliberately so: no Apple tool can
/// write an app-defined type, and a helper kaya wrote would be foreign in name
/// only. The scene copies and reads one back instead, with `pbpaste`
/// confirming from outside.
///
/// ONE BODY FOR BOTH PLATFORMS: the seed's settle is the rule that "the verb
/// returns only when the content is really there", and the two arms drifted
/// apart once already (docs/clipboard-plan.md §8 finding 6). What differs
/// between the platforms is the WRITE and the board object; the rule does not.
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

    // AND WAIT UNTIL IT IS REALLY *NEW*, not merely until the kind is offered:
    // the scene's own copy leaves a union clip carrying nearly every kind's
    // type, so a poll for the type alone is satisfied by the STALE board. Both
    // polls are prompt-free, so waiting here cannot raise the very alert the
    // read after it is meant to raise. THAT FIRST CLAUSE IS A macOS CLAIM — on
    // iOS the count also moves when a text field takes focus, so there the
    // TYPE is what says the seed landed (docs/traps.md).
    //
    // AND RE-ISSUE A WRITE THAT DID NOT LAND: `set the clipboard to` reports
    // success and writes nothing when another process touches the board inside
    // its clear-then-put window (docs/traps.md), and the seed is idempotent by
    // construction — same file, same content, same command.
    //
    // A SEED IS THIS LEG'S OWN STAGE, however foreign the process that
    // performs the write, and it takes several tries by construction — so the
    // witness stays quiet from here until the settle records the board.
    kayaClipStaging()
    let want = kayaClipUTI(kind)
    let before = kayaClipBoardNow().change
    let started = Date()
    // EVERY BOARD THIS WAIT SEES, one entry per distinct clip. A settle that
    // runs out has two very different stories and the bare timeout tells
    // neither: nothing was ever written, or something else is writing this
    // board too. This list is that evidence.
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
                // The seed is kaya's write too, however foreign the
                // process that made it. COMPOSED, because the writer on the
                // other side of both platforms' seeds is one kaya controls —
                // so on iOS clipctl's marker has to be on this board, and a
                // settle that closed without it fails the leg.
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
            // observation is WxH because the hosts re-encode freely and a byte
            // count would read differently on every platform.
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
        // ONE MECHANISM FOR EVERY KIND, and it is the host's: a CLI spawned
        // on the device reads the pasteboard as a genuinely different
        // principal, and is the only reader that sees the custom id at all —
        // device->host sync drops app-defined types and file-urls, and
        // simctl's own pbpaste reads a union clip as empty (§8 findings 3
        // and 4). The answer comes back base64'd because the response is
        // line-oriented.
        let (ok, lines) = KayaSimdrive.ask(
            "clip_read \(Data(kind.utf8).base64EncodedString())")
        guard ok, let encoded = lines.first,
            let bytes = Data(base64Encoded: encoded)
        else {
            // A HOST THAT COULD NOT ANSWER IS NOT AN EMPTY CLIPBOARD, and
            // the step's own text cannot tell them apart. The sentence the
            // host wrote goes out where the leg's log will carry it.
            let why = lines.first ?? "no answer from the simdrive watcher"
            FileHandle.standardError.write(
                Data("KAYA_CLIP_TRACE: clip_read \(kind) — \(why)\n".utf8))
            return ""
        }
        return String(decoding: bytes, as: UTF8.self)
    #endif
}

func kayaExpandPath(_ path: String) -> String {
    // WHOLE NAMES, not prefixes. A plain replace of "$TMP" also eats the
    // first four characters of "$TMPDIR" and leaves "<tmp>DIR" — a path that
    // does not exist, spelled plausibly enough to look like the caller's typo.
    // So take the whole identifier after the $ and look THAT up; an unknown
    // name survives intact and trips the leftover-$ check.
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

    /// THE FILE BROWSER HAS THREE SPELLINGS, ONE PER VIEW MODE, and which one
    /// you get is not the app's choice: it is the MACHINE-WIDE `NSGlobalDomain
    /// NSNavPanelFileListModeForOpenMode2`, which any application's open panel
    /// writes for every application on the box (docs/traps.md carries the
    /// three-row table and the 2026-08-06 failure).
    ///
    /// AN ENUM RATHER THAN THREE STRINGS, so that the identifiers the reader
    /// HUNTS FOR and the shapes it can actually READ are one list. Both
    /// switches below are exhaustive and carry no `default`: a fourth mode is
    /// added by adding a case, and the build then refuses until someone has
    /// written how to read it AND how to select in it.
    private enum KayaPanelShape: String, CaseIterable {
        case list = "ListView"
        case icons = "IconView"
        case columns = "ColumnView"
    }
    private let kayaPanelBrowserIds = KayaPanelShape.allCases.map { $0.rawValue }

    /// Roles that carry CONTENT rather than structure. No panel lookup ever
    /// descends into one, and that is a correctness rule, not a tidiness one:
    /// every attribute read is a mach round trip and an ancestor column here
    /// held 8362 items (docs/traps.md). A whole-tree `kayaAxFind` for the OK
    /// button was the same trap with a different name.
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
            // THE COLUMN HEADER IS A ROW TOO, and an identical one: role
            // AXRow and subrole AXOutlineRow, exactly like a file, so the list
            // came back as ["Name", "decoy.txt", "picked.txt", "Name"].
            // AXDisclosureLevel is what separates them — 0 on the header, 1 on
            // the files — measured, because kAXHeader is present but points at
            // the header VIEW and equals no row, and kAXRows returns the
            // header along with the rest. A row that publishes no level at all
            // is kept.
            //
            // Icons and columns have no header row, so this filter is this
            // arm's alone — applied to an icon item it would discard the files.
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
            // DIRECTORY. Never walk the others: an ancestor column here held
            // 8362 items, and each is a round trip.
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

    /// Why the panel could not be read, IN MEASUREMENTS. Every clause below
    /// prints something this process just observed; none of them names a cause
    /// it cannot see. The sentence that used to live here broke that rule and
    /// misdirected two investigations — CLAUDE.md invariant 3, docs/traps.md.
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
            return
                "the panel's sheet is up but its file browser is none of "
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

    /// The panel's state, WAITED FOR — because the browser exists before its
    /// contents do.
    ///
    /// THE STEP'S OWN RETRY CANNOT COVER THIS ONE: the retry's budget is spent
    /// inside a `DispatchQueue.main.sync`, and the main thread is the very
    /// thread busy presenting, so the whole 5s goes by inside ONE blocked call
    /// (docs/traps.md, "A RETRY BUDGET SPENT WAITING ON THE MAIN QUEUE IS NOT
    /// A RETRY BUDGET"). So the wait for CONTENT lives below the deadline,
    /// here, in the same bounded-poll shape as `kayaAwaitTextWindow`; the
    /// poll's SECOND read is the first one the main thread is free to serve.
    ///
    /// `requireRows` IS NOT ALWAYS TRUE, and that is the point: an empty list
    /// is a legitimate answer to the bare `expect_file_dialog` and to a form
    /// naming an empty directory, so waiting for rows nobody asked for is a
    /// stall on every use. A nil state — no panel yet — is returned at once in
    /// BOTH forms; that wait is the step retry's, and the retry can serve it.
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

    /// Select the named row and press Open, or press Cancel.
    ///
    /// PRESSING OPEN RETURNS kAXErrorCannotComplete (-25204) AND THAT IS NOT A
    /// FAILURE — the press dismisses the panel, which tears the element down
    /// mid-round-trip — and the selection set in columns mode lies the same
    /// way with kAXErrorAttributeUnsupported (-25205). Do not "fix" either by
    /// checking the return code; the completion is the proof (docs/traps.md).
    ///
    /// Returns nil when the press was DELIVERED (AX reported success);
    /// otherwise the reason, naming the stage that refused. Delivered is not
    /// landed: only the panel's DISMISSAL proves that, and the caller's
    /// postcondition owns it and re-presses on it (see file_choose). Never a
    /// silent guard-return — a re-press that could not find the row would
    /// no-op forever with nothing printed anywhere.
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
        // A ROW IS SELECTED WHERE ITS CONTAINER SAYS, and the attribute is
        // not the same one twice: an AXOutline takes AXSelectedRows and
        // refuses AXSelectedChildren, while a collection view and an NSBrowser
        // column take AXSelectedChildren and IGNORE AXSelectedRows — silently,
        // returning success.
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

    /// What the live SAVE panel is really showing: its directory, and the name
    /// in its name field. nil when no save panel is live.
    ///
    /// NO BROWSER IS REQUIRED, AND THAT IS THE MEASUREMENT. NSSavePanel's
    /// COLLAPSED form is the default and publishes no ListView/IconView/
    /// ColumnView at all, and whether a box is collapsed is the machine-wide
    /// `NSNavPanelExpandedStateForSaveMode`, which no gate reads
    /// (tools/validate-mac.sh). So the rows are never read here, either state.
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

    /// The save panel's state, waited for — and the wait is NOT
    /// decoration, it is the difference between a green leg and a red
    /// one. MEASURED 2026-08-09, twice in one run and again with this
    /// function's two extra property sets removed: the first
    /// `DispatchQueue.main.sync` after the presentation is asked for
    /// returns **8.7 SECONDS** later and still finds no sheet, and the
    /// state settles one 20ms turn after that. `NSSavePanel` blocks the
    /// main thread for that whole time, every time — it does not warm up
    /// (both panels in the same process cost 8688ms and 8671ms), and the
    /// cost is invariant to what this function configures, so it is the
    /// panel service's and not kaya's. The same box presented an
    /// `NSOpenPanel` in 6.5s cold and 0.93s warm, with WindowServer at
    /// ~49% serving two VMs.
    ///
    /// So the loop below cannot be dropped in favour of the step's own retry,
    /// which is the shape the open panel's reader uses: that budget is SPENT
    /// INSIDE THE BLOCKED HOP (docs/traps.md, the same 2026-08-07 measurement
    /// that put the content wait inside `kayaAwaitOpenPanelState`), here for
    /// the PRESENCE of the sheet rather than the fill of a browser.
    ///
    /// It waits for the SHEET, never for rows — see kayaSavePanelState.
    func kayaAwaitSavePanelState() -> (String, String)? {
        var state = DispatchQueue.main.sync { kayaSavePanelState() }
        for _ in 0..<kayaPanelFillTurns {
            if state != nil { return state }
            Thread.sleep(forTimeInterval: 0.02)
            state = DispatchQueue.main.sync { kayaSavePanelState() }
        }
        return state
    }

    /// Type a name into the live save panel's name field.
    ///
    /// THROUGH THE ACCESSIBILITY VALUE, which is what a user's keyboard
    /// reaches: the probe set it, read it back off the ELEMENT, saw
    /// `nameFieldStringValue` agree, and then watched the completion deliver a
    /// URL ending in that name. Setting the panel's property directly would
    /// have proved only that Swift can assign a string.
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

/// Present the platform's real file picker and answer exactly once. macOS is
/// NSOpenPanel; `allowsMultiple` rides the request as a FLAG here where GTK and
/// WinUI spell it as a METHOD and Android as a CONTRACT. THE ANSWER IS PATHS: a
/// path IS the capability on this platform, where iOS hands over the
/// security-scoped URL instead (DESIGN.md, File dialogs). Cancel is an EMPTY
/// list — no platform can confirm an empty selection.
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

/// Present the platform's real SAVE dialog and answer exactly once. macOS is
/// `NSSavePanel`, the class `NSOpenPanel` already inherits from. IT ANSWERS WITH
/// ONE URL AND CREATES NOTHING (measured: `exists=false` after a clean Save, and
/// pressing Replace leaves the old bytes intact), which is why the core
/// registers the destination through `emit_save_dialog_result`.
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
        // THE EXTENSION STAYS VISIBLE, and the harness reads that field back
        // byte for byte. Hiding it is the USER'S Finder preference, so the
        // name the panel publishes would otherwise be the stem on one machine
        // and the whole name on another — a machine-wide setting deciding a
        // lane's colour.
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
        // iOS HAS NO "CREATE A FILE WITH THIS NAME" PICKER. Every export
        // initializer in the SDK takes URLs THAT ALREADY EXIST locally
        // (`initForExportingURLs:asCopy:`, measured against the header), so a
        // destination is made by EXPORTING something rather than by naming
        // nothing. The core absorbs that by giving iOS the ordinary
        // picked-file source rather than the create-and-truncate one
        // (capi.rs `register_saved`, docs/save-plan.md D1).
        //
        // SO THE STAGED FILE IS ZERO BYTES, and that is D1 itself: the export
        // copies what it is given, so anything staged here is what an
        // UNTOUCHED destination reads back as — and a desktop destination
        // reads empty because nothing made it yet.
        //
        // IT IS STAGED IN THE APP'S PRIVATE TMPDIR, not kayaTempDir(): that is
        // `Documents` here, which is the directory the picker BROWSES, and a
        // staged file there would show up as a row in the very dialog that is
        // about to name its copy.
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
        // the harness reads this field back byte for byte. The scene's names
        // carry no extension, so this can only ever agree — which is the point
        // of setting it rather than inheriting it.
        panel.shouldShowFileExtensions = true
        // ARMED BY file_dialog_goto AND MEASURED NOT TO TAKE. The OPEN picker
        // honours `directoryURL` here; the EXPORT sheet does not — it resumes
        // wherever the Files browser last was, and that memory outlives the
        // process (docs/traps.md; tools/ios/run-sim.sh). So what
        // `expect_save_dialog`'s directory half reads on this platform is the
        // BROWSER's location, not this line, and the scene's own `file_choose`
        // is what puts the browser there. The line stays because it is the
        // documented initial location and costs nothing.
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
    /// THE HARNESS'S REACH OUT TO THE HOST. Every other backend reads and drives
    /// its picker in-process; iOS cannot — `UIDocumentPickerViewController` is a
    /// remote view controller that publishes zero accessibility elements here,
    /// and iOS has no accessibility service an app may install (docs/traps.md).
    /// The eyes live on the host, in tools/ios/simdrive, and the two sides meet
    /// through the app's own container: a file each way, `request` and
    /// `response`, first line `ok` or `err`, each removed by whoever consumed it.
    enum KayaSimdrive {
        static var directory: String { kayaTempDir() }
        static var requestPath: String {
            (directory as NSString).appendingPathComponent("kaya-simdrive-request")
        }
        static var responsePath: String {
            (directory as NSString).appendingPathComponent("kaya-simdrive-response")
        }

        /// ONE REQUEST FILE AND ONE RESPONSE FILE means the exchange is a
        /// critical section. The clipboard's asks are not single-threaded — a
        /// read's prompt-press runs on a background queue while the harness
        /// thread may be asking the host for a foreign read — and two asks
        /// interleaved on the same two paths would hand each the other's
        /// answer.
        private static let turn = NSLock()

        /// Ask the host for something and wait for its answer. Returns
        /// (ok, lines). A timeout is a FAILURE with a sentence, never a silent
        /// empty read: the class of bug that would otherwise be a harness
        /// reporting the guest's state when the harness itself is what broke.
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
    /// directory and the name in its "Save as" field. Nil when no save sheet is
    /// up, which FAILS expect_save_dialog rather than passing quietly. Nil state
    /// PLUS the sentence to report, because a refusal from the host would
    /// otherwise read as "no save dialog live" and send the next reader looking
    /// at the guest.
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
    /// the one piece of UI in this backend that NOBODY IN THIS PROCESS CAN
    /// SEE. So the four moments that exist here are said out loud — presented,
    /// picked, cancelled, emitted — and the difference between "the tap never
    /// landed" and "the tap landed and the delegate never fired" stops being a
    /// guess.
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

    /// The picked URLs, by the locator handed to the core.
    ///
    /// THE OBJECT IS THE CAPABILITY on this platform: the picked file's path
    /// EPERMs the moment its security scope drops and only the URL can
    /// re-acquire that scope (DESIGN.md, measurements 4 and 5). So the backend
    /// keeps them and the core redeems them by name.
    var kayaPickedURLs: [String: URL] = [:]

    /// The last open's failure, kept alive for the length of the call
    /// that reports it — the core copies the string inside that call.
    var kayaPickedOpenError: [CChar] = []

    final class KayaPickerDelegate: NSObject, UIDocumentPickerDelegate {
        let dialog: UInt64
        /// WHICH DIALOG THIS IS, and it has to be carried rather than asked:
        /// macOS has two panel CLASSES to interrogate, and iOS presents both
        /// from the one `UIDocumentPickerViewController`. It sits on the
        /// delegate — made at the single moment a picker is presented, with no
        /// default.
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

    /// Redeem a picked file. The core calls this — the one entry that runs
    /// that way — from whatever thread the guest opened on.
    ///
    /// START, OPEN, STOP, all inside this call. The scope is a kernel-tracked
    /// capability with a concurrency limit that leaks if held, and the
    /// descriptor OUTLIVES it (DESIGN.md, measurements 2 and 3), which is why
    /// the handle can be redeemed lazily and more than once.
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


/// Present an auxiliary surface AT-LEAST-ONCE. Belt, not the fix: the
/// panels-java flake this was built for turned out to be the accessor's
/// registration racing window attachment (see KayaWindowAccessor). It stays
/// because it is free and idempotent — a value-identified WindowGroup is
/// unique per value, so a duplicate request focuses the one window. Bounded
/// backoff; registration (kayaNSWindows) is the delivered signal.
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

/// Where the NEXT picker opens. Armed by file_dialog_goto and applied AT
/// PRESENTATION on both Apple platforms, because that is the only moment
/// either picker honors its initial location — set on a panel already up it is
/// ignored, and NSOpenPanel then restores whatever location it used last
/// (measured: a run inherited a directory left by an unrelated probe binary).
/// `UIDocumentPickerViewController` takes the same `directoryURL` and honours
/// it, so both arms read this one variable.
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
    /// AS THE SUPERCLASS, because `NSOpenPanel` IS an `NSSavePanel`: the
    /// presentation call, the sheet plumbing and the directory arming are
    /// already shared, and one slot mirrors the core's
    /// one-live-dialog-per-process rule instead of inventing a second one.
    var kayaLivePanel: NSSavePanel?

    /// The two readers each see ONLY their own kind, and they ask the TYPE
    /// rather than a flag someone has to remember to set. A save panel
    /// publishes no `open-panel` sheet and no file browser, so an open-panel
    /// read that could see it would poll forever — and `file_choose`'s
    /// postcondition reads a nil state as "the press landed".
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
    /// close-veto delegate proxy (SwiftUI owns the window's real delegate; the
    /// proxy answers windowShouldClose and forwards everything else).
    ///
    /// Registration is EVENT-DRIVEN on window attachment: the view subclass
    /// overrides viewDidMoveToWindow — AppKit's attachment signal — so
    /// registration cannot race the window's creation.
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

    /// An entry edit, with the three facts the core's undo ledger cannot
    /// derive (docs/undo-plan.md §3).
    ///
    /// TAKES THE NODE, NOT THE TAG, so those facts are read in ONE place: the
    /// window whose ledger this run of typing belongs to, whether the field
    /// holds focus, and whether the edit is LEDGER-QUIET. Quiet means this
    /// backend ROUTED a native undo and reported it with its own sample
    /// (kayaNoteNativeUndo), so the ordinary edit the same undo provokes must
    /// not be banked a second time; the app still hears it, and only the
    /// banking is suppressed.
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

    static func nextCommands(_ buffer: UnsafeMutablePointer<UInt8>, _ cap: Int) -> Int {
        Int(api.next_commands(buffer, UInt(cap)))
    }

    /// Fetch a blob's bytes by the handle an apply record carried, copied out
    /// of core memory. Handles are batch-local, so callers fetch on the pump
    /// thread, within the batch. Nil for a dead handle.
    static func blobData(_ handle: UInt64) -> Data? {
        var length: UInt = 0
        guard let bytes = api.blob_data(handle, &length) else { return nil }
        return Data(bytes: bytes, count: Int(length))
    }
}

func kayaStartCommandPump() {
    let thread = Thread {
        let cap = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        defer { buffer.deallocate() }
        while true {
            let length = KayaHost.nextCommands(buffer, cap)
            if length == 0 { break }
            let batch = Data(bytes: buffer, count: length)
            // Blob handles are batch-local: the next nextCommands call
            // replaces the core's table, and the main-queue apply may run
            // after that. Fetch every referenced blob here, on the pump
            // thread, within the batch.
            let blobs = kayaCollectBlobs(batch)
            DispatchQueue.main.async {
                kayaApply(batch, blobs)
            }
        }
    }
    thread.start()
}

/// Pre-fetch the batch's blob payloads (SET_PROP values of type blob)
/// through the host's blob_data, keyed by wire handle. Runs on the pump
/// thread, before the next nextCommands call invalidates the handles.
private func kayaCollectBlobs(_ batch: Data) -> [UInt64: Data] {
    var blobs: [UInt64: Data] = [:]
    batch.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        var at = 0
        while at + 8 <= raw.count {
            let size = Int(raw.loadUnaligned(fromByteOffset: at, as: UInt32.self))
            let kind = raw.loadUnaligned(fromByteOffset: at + 4, as: UInt16.self)
            // SET_PROP and SET_MENU_PROP share the { u64 id; u32 prop;
            // u32 pad; value } layout, so one scan serves both blob
            // carriers (widget source, menu icon).
            if kind == applySetProp || kind == applySetMenuProp {
                let valueType = raw.loadUnaligned(fromByteOffset: at + 24, as: UInt32.self)
                if valueType == valueBlob {
                    let handle = raw.loadUnaligned(fromByteOffset: at + 32, as: UInt64.self)
                    blobs[handle] = KayaHost.blobData(handle)
                }
            }
            // COPY carries blobs too — an image, and every custom format's
            // bytes — and they die with the batch exactly as a prop's do.
            // Walking its Values block generically: the header says how many,
            // and a value that is not a blob is skipped by the same
            // arithmetic.
            if kind == applyCopy {
                let slots = Int(raw.loadUnaligned(fromByteOffset: at + 8 + 16, as: UInt32.self))
                var vat = at + 8 + 24
                for _ in 0..<slots {
                    let valueType = raw.loadUnaligned(fromByteOffset: vat, as: UInt32.self)
                    let len = Int(raw.loadUnaligned(fromByteOffset: vat + 4, as: UInt32.self))
                    if valueType == valueBlob {
                        let handle = raw.loadUnaligned(fromByteOffset: vat + 8, as: UInt64.self)
                        blobs[handle] = KayaHost.blobData(handle)
                    }
                    vat += 8 + len
                    if vat % 8 != 0 { vat += 8 - vat % 8 }
                }
            }
            // SET_TYPEFACE's font blob (apply 33). Its slot sits after two
            // variable-length fields: skip mask+reserved, skip the family
            // value, skip the pair list, and the font is what is left.
            if kind == applySetTypeface {
                var vat = at + 8 + 8
                func skip() {
                    let len = Int(raw.loadUnaligned(fromByteOffset: vat + 4, as: UInt32.self))
                    vat += 8 + len
                    if vat % 8 != 0 { vat += 8 - vat % 8 }
                }
                skip()  // family
                let pairCount = Int(raw.loadUnaligned(fromByteOffset: vat, as: UInt32.self))
                vat += 8
                for _ in 0..<pairCount { skip() }
                if raw.loadUnaligned(fromByteOffset: vat, as: UInt32.self) == valueBlob {
                    let handle = raw.loadUnaligned(fromByteOffset: vat + 8, as: UInt64.self)
                    blobs[handle] = KayaHost.blobData(handle)
                }
            }
            // SET_APP_IDENTITY's icon blob (apply 34). Its slot sits after
            // mask+reserved and the name. It has to be HERE rather than in the
            // apply arm, for the reason at the top of this function: the
            // handle dies with the batch, and without this the icon arrives as
            // no bytes at all, with no error on any side.
            if kind == applySetAppIdentity {
                var vat = at + 8 + 8
                let nameLen = Int(raw.loadUnaligned(fromByteOffset: vat + 4, as: UInt32.self))
                vat += 8 + nameLen
                if vat % 8 != 0 { vat += 8 - vat % 8 }
                if raw.loadUnaligned(fromByteOffset: vat, as: UInt32.self) == valueBlob {
                    let handle = raw.loadUnaligned(fromByteOffset: vat + 8, as: UInt64.self)
                    blobs[handle] = KayaHost.blobData(handle)
                }
            }
            at += size
        }
    }
    return blobs
}

/// The size request's macOS materialization: resize the primary window's
/// CONTENT to the requested DIP, keeping the current extent on any axis the
/// scene has not requested. iOS applies nothing — the system owns geometry.
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
        window.setContentSize(size)
    #endif
}

/// The dirty flag's macOS materialization: NSWindow.isDocumentEdited, which
/// draws the dot inside the close button — measured as the WHOLE of the chrome
/// change (88 backing pixels; the title string, the toolbar, the proxy icon
/// and the Dock tile are all untouched). It goes through the NSWindow bridge
/// because SwiftUI publishes nothing for it. The system attaches NO behavior
/// to the flag — a real Cmd+W on an edited window calls windowShouldClose once
/// and closes, with no save sheet — so the confirm flow stays the app's,
/// spelled with veto_close and a dialog (docs/dirty-plan.md D3).
///
/// iOS applies NOTHING, and that is the stated carve-out (D4): the platform
/// has no window chrome to carry the mark.
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
                case kindEntry: kayaScene.entryWidgets.append(node)
                case kindCheckbox: kayaScene.checkboxes.append(node)
                case kindImage: kayaScene.images.append(node)
                case kindColumn: kayaScene.columns.append(node)
                case kindRow: kayaScene.rows.append(node)
                case kindScroll: kayaScene.scrolls.append(node)
                case kindProgress: kayaScene.progresses.append(node)
                case kindSelect: kayaScene.selects.append(node)
                case kindRadio: kayaScene.radios.append(node)
                case kindGrid: kayaScene.grids.append(node)
                case kindTextarea: kayaScene.textareas.append(node)
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
                // THE DECLARED SET, replacing whatever was declared before.
                // Offsets ride as a flat Values list of I64s read IN PAIRS —
                // start then end — and they are already UTF-16 code units.
                //
                // RECORDED WITH THE TEXT IT WAS DECLARED AGAINST, which is the
                // whole of D2's clear-on-edit: the model's text at THIS moment
                // is the text the core validated these offsets against,
                // because a text write earlier in this same batch has already
                // landed on the node.
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
                // platform it was compiled for. This file serves macOS AND
                // iOS, and it carries NO copy of the platform vocabulary — a
                // private copy here and another in Kotlin is the CLIP_* mirror
                // trap.
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
                        // from there the name machinery is the same one a
                        // named request uses.
                        registered = kayaRegisterFont(data)
                    }
                }
                let wanted = registered ?? picked ?? defaultFamily
                kayaScene.typefaceRequested = wanted
                // THE PRESENCE GATE. Without it a family this device does not
                // have would still render — CoreText's forgiving door hands
                // back Helvetica and SwiftUI's Font.custom goes through it —
                // and a typo would look exactly like a brand. Refusing here
                // leaves the platform's own ramp standing.
                kayaScene.typefaceFamily = kayaFamilyPresent(wanted) ? wanted : nil
                if kayaScene.typefaceFamily == nil {
                    kayaDiag(
                        "typeface \(wanted) is not installed — the platform ramp stands")
                }
            case applySetAppIdentity:
                // ONE DECLARATION, TWO PLATFORMS THAT REACH IT DIFFERENTLY,
                // and the difference is measured rather than scheduled
                // (docs/app-identity-plan.md I1, I8): macOS hands the picture
                // to the Dock at runtime, iOS has no runtime route at all and
                // its identity is the bundle's.
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
                    // NO RUNTIME ROUTE, AND THAT IS A MEASURED FACT RATHER
                    // THAN A SCHEDULE: the whole iOS app-icon surface is
                    // `supportsAlternateIcons`, `setAlternateIconName` and
                    // `alternateIconName`, typed BOOL and NSString, none of
                    // which takes bytes. The bytes are kept because the
                    // OBSERVATION needs them: `expect_app_icon` reads the icon
                    // out of the bundle this app is running from and holds it
                    // equal to this declaration.
                    kayaDiag(
                        "app identity \(identityName): iOS has no runtime route to the "
                            + "Home Screen icon, so this declaration reaches the platform "
                            + "through tools/ios/run-sim.sh's make_bundle; "
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
            case applyPresentSaveDialog:
                // The platform's REAL save dialog (NSSavePanel), answered
                // exactly once through kaya_emit_save_dialog_result — one
                // locator, or a null one for cancel.
                //
                // A STR THEN A LIST, a body shape no other apply record has:
                // the name is a Value and the filters follow as the picker's
                // own pairs, so the walk below reads the name FIRST and takes
                // the list's count from wherever the name ended.
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
                case (propMin, valueF64):
                    kayaScene.nodes[id]!.minValue =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Double.self)
                case (propMax, valueF64):
                    kayaScene.nodes[id]!.maxValue =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Double.self)
                case (propGrow, valueF64):
                    kayaScene.nodes[id]!.grow =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Double.self)
                case (propSpacing, valueF64):
                    kayaScene.nodes[id]!.spacing =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Double.self)
                case (propAlign, valueI64):
                    kayaScene.nodes[id]!.align =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Int64.self)
                case (propIndeterminate, valueBool):
                    kayaScene.nodes[id]!.indeterminate = raw[body + 24] != 0
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
                // A choice widget's label children are its OPTIONS — rows of
                // the dropdown, entries of the radio group — so they leave the
                // harness's label#N registry (their create arm appended before
                // this parent was known). Without this, every label after one
                // would shift index.
                let parentKind = kayaScene.nodes[parent]!.kind
                if parentKind == kindSelect || parentKind == kindRadio {
                    kayaScene.labels.removeAll { $0.id == child }
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
                    // A section presents in-window too: added to the set
                    // already; the mount fills its pane. BUT THE WINDOW IT
                    // LIVES IN may itself be an auxiliary that nothing has
                    // presented: a sections window mounts into its SECTIONS
                    // and never into a root, so the root-mount trigger below
                    // can never fire for it. The section's mount is that
                    // window's "mounting presents" moment.
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
                    // The names-not-bytes half: the tab item and the sidebar
                    // row draw the platform's own glyph for the concept
                    // (docs/styling-plan.md D6). VALUE AT +24, NOT +20: the
                    // I64 payload is 8-aligned past the type word, exactly
                    // like the widget arms, and +20 is padding that decodes as
                    // garbage rendering NO icon. Break this line and the
                    // sections leg fails on all five lanes — that exact
                    // perturbation is the watched red `expect_section_symbol`
                    // was built against (docs/deferred.md).
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
                // u64 widget (the STAMPED copy), u64 item, then the
                // copy's key path { u32 count; u32 reserved; count
                // values } — kept as raw wire bytes: activations hand
                // them back verbatim as the emit's noun (values
                // self-pad to 8, so the path runs to the record end).
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
    if menusTouched {
        kayaMenuChanged()
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

/// Apply the two universal accessibility props to a widget's own view. Applied
/// to the CONTROL, never to a wrapping Group: a label set on a Group did reach
/// the element while an identifier set the same way did not appear in the tree
/// at all. Empty means unset and unset stays untouched — SwiftUI derives a
/// control's name from its own content, and an empty string would silence it.
@ViewBuilder
func kayaA11y(_ view: some View, _ node: KayaNode) -> some View {
    // Containers need an explicit accessibility element first, or these props
    // do the wrong thing on them — both measured 2026-07-25: an IDENTIFIER set
    // on a container propagates DOWN and lands on its first child, and a LABEL
    // collapses the container into one element and hides everything inside.
    // `.contain` is the API for exactly this: the container becomes its own
    // element while its children stay individually reachable.
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
    // The HINT: what activating this control does. Apple speaks it after the
    // label and forbids naming the gesture, which is why the authored text is
    // a verb phrase.
    if node.a11yHint.isEmpty {
        labelled
    } else {
        labelled.accessibilityHint(node.a11yHint)
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
    /// API against our own pid. The server-side NSAccessibility protocol is
    /// for SETTING accessibility, not reading it back — measured: a
    /// server-side walk found the tree with correct roles but nil for every
    /// identifier and label, and it is not what VoiceOver sees either.
    private func kayaAxCopy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
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

    /// Every element carrying the identifier, not just the first — the count
    /// is what lets an ambiguous id be REFUSED rather than guessed at.
    /// `kayaAxFind` returning the first match was measured lying (2026-08-11):
    /// two stamped copies shared a const template a11y id, `expect_ax entry#2`
    /// resolved through the id, and the verb reported the FIRST copy's label
    /// as the second's (tools/check-diagnostics.sh's rule, one verb over).
    private func kayaAxFindAll(
        _ element: AXUIElement, _ identifier: String, _ depth: Int = 0,
        _ out: inout [AXUIElement]
    ) {
        if depth > 64 || out.count > 8 { return }
        if let ident = kayaAxCopy(element, kAXIdentifierAttribute) as? String,
            ident == identifier,
            // DEDUPLICATED BY ELEMENT IDENTITY, and the walk itself is why:
            // the tree reaches one element down more than one path (kAXWindows
            // and kAXChildren overlap two levels apart, where kayaAxKids'
            // per-parent dedup cannot see it), so an undeduplicated count
            // reported EVERY identifier in the scene as ambiguous — measured,
            // 19 of 19 unique ids "shared by 2 elements".
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
        // Deduplicate by element identity: the three attributes overlap.
        var out = windows + children
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

    private func kayaAxRead(_ identifier: String) -> String? {
        guard !identifier.isEmpty else { return nil }
        // WAIT FOR THE WINDOW, ON THE EVENT — never on a clock. The scene's
        // first step is an expect (check-steps enforces that, and its bounded
        // retry is the readiness wait), so the first AX call can land while
        // AppKit is still inside the appear/layout pass that materializes the
        // window. Reading your own process then DEADLOCKS rather than failing,
        // and the messaging timeout does not save it — measured 2026-07-25,
        // legs hung at 120s with the trace showing `+0ms expect_ax`.
        // kayaAwaitWindow parks on the registration signal itself.
        _ = kayaAwaitWindow(0)
        // …then read ON THE MAIN THREAD. Reading your OWN process does not go
        // out through the messaging layer at all: measured 2026-07-25 from a
        // sampled deadlock, AXUIElementCopyAttributeValue short-circuits into
        // AppKit and runs `-[NSObject _accessibilityValueForAttribute:]`
        // INLINE on the calling thread. That is main-thread-only API, and no
        // messaging timeout can bound a call that never sends a message.
        return DispatchQueue.main.sync { kayaAxReadOnMain(identifier) }
    }

    private func kayaAxReadOnMain(_ identifier: String) -> String? {
        let app = AXUIElementCreateApplication(getpid())
        // macOS builds the accessibility tree LAZILY: until an assistive
        // client attaches, an app publishes a skeleton — correct top-level
        // roles, but no content and no names. VoiceOver announces itself with
        // AXEnhancedUserInterface; third-party assistive technology uses
        // AXManualAccessibility, and the harness IS an assistive client here.
        // EVERY AX CALL HERE IS BOUNDED, AND THE BOUND COMES FIRST: the read
        // is serviced by the MAIN RUNLOOP, so a busy main thread blocks it and
        // the default messaging timeout is long enough to eat a whole leg.
        AXUIElementSetMessagingTimeout(app, 2.0)
        // ANNOUNCED ONCE PER PROCESS, not once per read. Setting these is not
        // a flag flip: AppKit rebuilds its whole accessibility hierarchy in
        // response, and that rebuild drives a full layout pass.
        //
        // Measured 2026-07-25 under the mac lane's 8-wide pool: legs hung past
        // their 120s timeout with their windows registered, while the same
        // binary passed standalone. A sample of a stuck process put 100% of
        // the main thread in CA::Transaction::commit -> NSDisplayCycleFlush ->
        // -[NSView _layoutSubtreeWithOldSize:] — layout, not the AX transport,
        // which is why bounding the messaging timeout alone did not fix it.
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
        kayaAxFindAll(app, identifier, 0, &matches)
        guard let hit = matches.first else { return nil }
        // AN AMBIGUOUS IDENTIFIER IS REFUSED, NOT RESOLVED. This read
        // addresses the tree BY IDENTIFIER, so with two elements carrying the
        // same id it can only guess — and it used to guess the first. The
        // refusal names what was measured: the count and the id, nothing more.
        if matches.count > 1 {
            return "<ambiguous: \(matches.count) elements share id '\(identifier)' — "
                + "expect_ax addresses the tree by identifier and cannot tell "
                + "them apart; give each element its own id>"
        }
        let role = kayaAxRole(kayaAxCopy(hit, kAXRoleAttribute) as? String)
        // A control's spoken name is its DESCRIPTION when one was authored and
        // its TITLE when the control derived it from its own content — take
        // the authored one first. STATIC TEXT derives from neither: a label
        // publishes nil for both and carries its string in AXValue (measured
        // 2026-07-25), and VoiceOver speaks that value. AXValue is a String
        // only where it is text — a slider's is a number, and the cast misses.
        let label =
            [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute]
            .lazy
            .compactMap { kayaAxCopy(hit, $0 as String) as? String }
            .first { !$0.isEmpty } ?? ""
        return role + "/" + label
    }

    /// What one textarea's text layer, selection and viewport say, read in ONE
    /// main-thread hop out of the accessibility tree — the same data an
    /// assistive client receives.
    ///
    /// WHY THE HIGHLIGHT READ FORCES THE LOWERING'S HAND. Three macOS
    /// mechanisms paint a background on a run and only one of them is
    /// published to accessibility (measured, range-probe-mac.md §1): TextKit 2
    /// rendering attributes and `NSTextHighlightStyle` both report `bg=false`
    /// through `AXAttributedStringForRange`, and TextKit 1 temporary
    /// attributes are not reachable without touching `.layoutManager`, which
    /// silently and permanently downgrades the view. `NSTextStorage`'s
    /// `.backgroundColor` is the one that surfaces, so it is the one the
    /// lowering writes.
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

    /// Whether the window's CHROME is really showing the unsaved-work mark:
    /// `AXEdited` on the window's CLOSE BUTTON, which is a measured fact — the
    /// AXWindow's own 29 attributes contain no edited state at all (`AXEdited`
    /// there is kAXErrorAttributeUnsupported), while the button element's 14
    /// include it and it tracks NSWindow.isDocumentEdited exactly.
    ///
    /// nil = unreadable, and it must NOT collapse to `false`: a scene's first
    /// assertion is that the window is CLEAN, and a broken read answering false
    /// would pass it.
    ///
    /// FOUR MEASURED PROPERTIES make it usable in the lane: no assistive-client
    /// announcement is needed (AppKit chrome, so no accessibility rebuild and no
    /// layout pass); it works under `.accessory` on a window that is neither key
    /// nor active; it is synchronous; and it is READ-ONLY from the client side.
    /// THE THREAD DISCIPLINE IS NOT OPTIONAL: a same-process AX read runs
    /// main-thread-only code INLINE on the calling thread (docs/traps.md), so
    /// park on the window's materialization first, then read inside main.sync.
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
    /// UIKit has NO role vocabulary — that is the platform difference this arm
    /// exists for. macOS publishes AXRole, a first-class name per control; iOS
    /// publishes a TRAIT BITMASK plus the element's class, and the same trait
    /// rides several kinds. So the order below is not stylistic: the SPECIFIC
    /// signals must be weighed before `.button`, or every one of them reads as
    /// a plain button. All of it is measured — see the traits in each case.
    private func kayaAxRole(_ element: NSObject) -> String {
        let traits = element.accessibilityTraits
        // A Toggle publishes button|toggleButton (traits
        // 9007199254740993 = 1 | 1<<53, measured 2026-07-25). The trait
        // is iOS 17; below that the switch is only its class.
        if #available(iOS 17.0, *), traits.contains(.toggleButton) { return "checkbox" }
        if element is UISwitch { return "checkbox" }
        if traits.contains(.adjustable) { return "slider" }
        if traits.contains(.image) { return "image" }
        // A ProgressView publishes `updatesFrequently` and nothing else
        // (traits 512, measured): the element is not a UIProgressView at all
        // under SwiftUI.
        if traits.contains(.updatesFrequently) { return "progress" }
        // THE CHOOSER. iOS has no combo box: a menu-style picker is a UIButton
        // that OWNS A MENU (traits 1 — a plain button — on class
        // UIKitIconPreferringButton, measured). The menu is the platform's own
        // evidence, so the question is asked of the control and not of kaya's
        // model.
        if let button = element as? UIButton, button.menu != nil { return "combobox" }
        if traits.contains(.button) { return "button" }
        if element is UITextView || element is UITextField { return "field" }
        // A HEADING LABEL publishes header|staticText (traits 65600 = 0x40 |
        // 1<<16, measured 2026-08-12 by the styling legs failing exactly
        // here): `.header` is what `.accessibilityAddTraits(.isHeader)`
        // becomes on this platform, and it rides ON TOP of staticText — so the
        // specific signal is weighed first, or every heading reads as a plain
        // label. The macOS half learned the same role from AXHeading.
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

    /// UIKit publishes accessibility IN-PROCESS: the identifier lives on
    /// `UIAccessibilityIdentification`, and containers expose their elements
    /// through `UIAccessibilityContainer`. macOS's server side returns nil for
    /// everything and the read has to go through the AXUIElement CLIENT API,
    /// so this arm is not a copy of that one.
    ///
    /// SwiftUI's own accessibility elements are not UIViews and do not
    /// formally conform to UIAccessibilityIdentification, so the typed cast
    /// misses them and the ObjC selector is the way in — measured 2026-07-25,
    /// when every node in a materialized tree reported a nil identifier
    /// through the cast alone.
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

    /// iOS builds its accessibility tree LAZILY, exactly as macOS does: until
    /// an assistive technology is running, SwiftUI's accessibility elements do
    /// not exist. Measured 2026-07-25 — every view in the hierarchy reported
    /// `isAccessibilityElement=false`, zero accessibility elements and a nil
    /// identifier, so the walk below found nothing at all.
    ///
    /// VoiceOver cannot be started from inside the app, but the AX runtime's
    /// AUTOMATION switch can be, and flipping it is what materializes the
    /// tree — the iOS spelling of the AXEnhancedUserInterface /
    /// AXManualAccessibility handshake the macOS arm performs, and the same
    /// switch XCUITest, KIF and EarlGrey flip.
    ///
    /// Resolved with dlsym rather than linked, so no shipped binary carries a
    /// reference to a private symbol.
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
                    // A control's spoken name is its LABEL when one was
                    // authored, and its VALUE when it derived one from its own
                    // content: an unnamed text field publishes no label at all
                    // and carries what it holds in accessibilityValue. Same
                    // gap, same fix, as every other backend — and the a11y
                    // scene cannot catch it, because both of its field reads
                    // are authored labels.
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

    /// The unsaved-work mark as THIS platform can honestly report it: the
    /// APPLIED PROP, read back off the model the apply arm wrote
    /// (docs/dirty-plan.md D5's iOS row). iOS lowers `dirty` to nothing (D4),
    /// so there is no surface to interrogate and a read that invented one
    /// would assert what no native app on this platform shows.
    ///
    /// IT IS NOT THE SCRIPT AGREEING WITH ITSELF, which is the thing to be
    /// careful about when a read drops to state. Exactly one line writes this
    /// field — the apply arm's `case (wpropDirty, valueBool)` — and that line
    /// is the far end of the whole chain this milestone added. WATCHED: delete
    /// it and the leg reports `dirty false, wanted true` while every label
    /// assertion still passes.
    ///
    /// nil means UNREADABLE, never `false`: a surface id this scene does not
    /// have is not a clean window (the macOS arm's rule, for its reason).
    private func kayaWindowDirtyState(_ windowId: UInt64) -> Bool? {
        DispatchQueue.main.sync { () -> Bool? in
            kayaScene.windows[windowId]?.dirty
        }
    }

    /// The UITextView a range verb is addressed to, found the way every other
    /// read on this platform finds its target: the accessibility walk, by the
    /// authored identifier.
    ///
    /// ASKED FOR A UITextView SPECIFICALLY, and that is not a downcast of
    /// convenience. On iOS the accessibility element for a text control IS the
    /// view — the range probe measured `sameObject=true` against a plain
    /// subview walk — so an element that carries the identifier without being
    /// the control is not the thing a range was declared on. UIKit publishes
    /// accessibility in-process and hands back the live object, where macOS
    /// has to ask the accessibility SERVER for an opaque element.
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

    /// EVERY RANGE READ CROSSES THIS FIRST, and it is the difference between an
    /// assertion and a coin toss. The lowering runs in `updateUIView`, which
    /// SwiftUI schedules; the harness reads through `DispatchQueue.main.sync`,
    /// which jumps the queue. So a read can land BEFORE the pass that lowers the
    /// thing it is asking about — and a retry does not save it, because a step
    /// whose "before" already equals its "after" passes on the first look.
    ///
    /// FOUND BY WATCHING THE NEGATIVE TEST, 2026-08-06: with D4's IME refusal
    /// DELETED the ranges leg still passed, the only read of `expect_selection`
    /// seeing `{814,0}` 12ms after the click and before `updateUIView` had run.
    /// Counted: with the refusal deleted and no barrier the leg passed 5 runs
    /// out of 7, four of those five first; with the barrier and the same
    /// deletion it failed 3 out of 3. `CATransaction.flush()` commits the
    /// implicit transaction, driving the pending update pass to completion.
    private func kayaSettleRender() {
        CATransaction.flush()
    }

    /// What one textarea's text layer and selection say, read off the live
    /// control on the main thread.
    ///
    /// `painted` IS A PIXEL FACT, and it is here because the read-back oracle
    /// structurally cannot see the failure the iOS probe named: a highlight
    /// that is real to every query and invisible on screen. Measured on this
    /// platform (range-probe-ios.md M2/N1): a TextKit 2 rendering attribute
    /// reads back exactly while drawing NOTHING until something unrelated
    /// happens to repaint the view.
    private struct KayaUIRanges {
        var text: String
        var highlights: [NSRange]
        var selection: NSRange
        var painted: Bool
    }

    /// Chromatic pixels in what the view REALLY DRAWS. Text is grayscale and so
    /// is the border, so kaya's highlight is the only coloured thing a
    /// plain-text control can show — colour-agnostic in light mode, dark mode
    /// and any tint.
    ///
    /// WHAT IT CANNOT SEE: a FOCUSED text view paints its selection in the
    /// system tint, so a scene asserting a non-empty highlight on a focused
    /// control could be answered by the selection's pixels. That can only make
    /// this clause MISS a failure, never invent one.
    ///
    /// `drawHierarchy(afterScreenUpdates:)` AND NOT `layer.render(in:)`,
    /// measured 2026-08-06: with the view scrolled to the last match,
    /// `layer.render` reported ZERO coloured pixels while `drawHierarchy`
    /// reported 5906 — `CALayer.render(in:)` does not apply a scroll view's own
    /// `bounds.origin`.
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
    /// selection in an unfocused text view at all, and forcing a screen update
    /// to answer a question nobody posed is a side effect a read has no
    /// business having.
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

    /// Is this range on screen? CONTAINMENT, never the viewport itself — how
    /// much context a scroll leaves around a range is native behaviour and
    /// differs per lane.
    ///
    /// TWO PREDICATES, BOTH REQUIRED. `viewportRange` is the exact iOS sibling
    /// of the mac arm's `AXVisibleCharacterRange`: a CHARACTER range naming what
    /// the view laid out (measured on the frozen document: `0:91` before the
    /// reveal and `644:764` after, against a wanted `747:752`). It is a little
    /// GENEROUS on both platforms, so the segment rectangles close that latitude.
    /// The two are ANDed in one direction on purpose, so a disagreement can only
    /// fail a `visible` assertion.
    ///
    /// NOT FULL RECT CONTAINMENT, which this arm tried and watched fail: UIKit's
    /// own `scrollRangeToVisible` does not promise it — revealing `747:752`
    /// moved the viewport to 729..825 with the line's typographic frame at
    /// 814..836. AND NOT `firstRect(for:)`, measured at the same instant putting
    /// the range at 821..844.7 where the segment said 814..836.
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
            // THE TWO RECTANGLES ARE IN DIFFERENT SPACES, and the difference
            // is `textContainerInset`. A segment frame is the TEXT CONTAINER's
            // coordinate; `bounds` is the VIEW's, and on this control they
            // differ by 8pt at the top (docs/traps.md). Compared directly, a
            // range sitting up to 8pt BELOW the fold reads as visible. The
            // viewport moves into the segments' space rather than the other
            // way round.
            let visible = view.bounds.offsetBy(
                dx: -view.textContainerInset.left, dy: -view.textContainerInset.top)
            return laidOut && segments.allSatisfy { visible.intersects($0) }
        }
    }

    /// `compose`: leave MARKED, UNCOMMITTED text in the control — the state a
    /// person is in mid-word with an input method, which no other verb can
    /// reach (`type` is printable ASCII by contract). This goes in through the
    /// view's own `setMarkedText`, so the text is displayed, uncommitted, and
    /// select_range must refuse to run over it.
    ///
    /// A MEASURED DIVERGENCE FROM macOS, recorded because a breadth arm after
    /// this one will need it: UITextView DOES notify its delegate for marked
    /// text (`textViewDidChange` fired, measured 2026-08-06) where AppKit's
    /// `setMarkedText` notifies nobody. The guard on the push is still here
    /// because the destruction it prevents was measured on this platform too:
    /// a programmatic `view.text =` during a composition drops
    /// `markedTextRange` and fires NO delegate callback at all.
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

/// Resolves `kind#index` against the registry the verb reads, mirroring
/// harness.rs's parse_target: a kind that names a different registry, a
/// malformed index, or one out of range is a loud step failure — never a
/// silently misresolved read (`row#0` once indexed the COLUMNS registry).
private func kayaTarget(_ spec: Substring, _ kind: String, _ registry: [KayaNode]) -> KayaNode? {
    // kind@id — the authored a11y_id, creation order never entering
    // (harness.rs's Target doc; the check-steps container lint's
    // sanctioned alternative). First match in creation order.
    if spec.contains("@") {
        let bits = spec.split(separator: "@", maxSplits: 1)
        guard bits.count == 2, bits[0] == kind, !bits[1].isEmpty else { return nil }
        let id = String(bits[1])
        return registry.first { $0.a11yId == id }
    }
    let bits = spec.split(separator: "#")
    guard bits.count == 2, bits[0] == kind else { return nil }
    if bits[1] == "last" { return registry.last }
    guard let i = Int(bits[1]), registry.indices.contains(i) else { return nil }
    return registry[i]
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
    /// The registered NSWindow for a surface id (the accessor fills the
    /// table); the primary falls back to the first app window for
    /// pre-registration reads. Await a surface's REAL NSWindow: materialization
    /// is async, and the wait is EVENT-DRIVEN, never a poll — the runner parks
    /// on a semaphore that window registration signals, so the wake is
    /// guaranteed the moment the window exists; the deadline is only the
    /// failure bound (a window that never materializes must fail the leg, not
    /// hang it).
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

/// Guest-visible text uses LF as its line separator on every platform, so
/// normalization happens at every WRITE into the model — user edits and pastes
/// through the bindings, the wire's property write, the harness's set_text —
/// and reads need none. The cheap-out guard checks UNICODE SCALARS, not
/// characters: Swift's grapheme-based `String.contains("\r")` sees CRLF as one
/// cluster that does not "contain" CR, and would skip exactly the input this
/// function exists for.
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
    switch spec.split(separator: "#").first.map(String.init) ?? "" {
    case "button": return kayaTarget(spec, "button", kayaScene.buttons)
    case "checkbox": return kayaTarget(spec, "checkbox", kayaScene.checkboxes)
    case "label": return kayaTarget(spec, "label", kayaScene.labels)
    case "slider": return kayaTarget(spec, "slider", kayaScene.sliders)
    case "image": return kayaTarget(spec, "image", kayaScene.images)
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
    default: return nil
    }
}

/// Cut one script LINE into statements at `;` — the newline stand-in for
/// transports that cannot carry a newline. QUOTE-AWARE, AND THAT IS NOT A
/// NICETY: an expected string is whatever the app puts on screen, and kaya's own
/// asset miss sentence carries a semicolon. Same rule as `split_statements` in
/// crates/kaya/src/harness.rs and `kayaSplitStatements` in KayaCompose.kt, held
/// equal by tools/scenes/assets.steps; tools/check-steps.sh refuses a statement
/// with unbalanced quotes.
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
    // THE TRACE MUST SURVIVE A KILL. stdout to a file is block-buffered, so a
    // leg killed at its timeout takes every step it had logged down with it,
    // and the hang looks like "never started". Measured twice on 2026-07-25
    // before this line existed: two accessibility legs died at 120s with no
    // trace at all. Line buffering makes a killed leg say where it stopped.
    setvbuf(stdout, nil, _IOLBF, 0)
    let start = Date()
    print("KAYA_HARNESS: epoch \(Int(start.timeIntervalSince1970 * 1000))")
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
            // The observation contract (harness.rs is the norm): every expect is
            // a BOUNDED RETRY — each verb case appends exactly one failure on a
            // miss, so the wrapper retracts it and re-runs until it passes or
            // the deadline lands the last failure text. Actions never re-run;
            // the FIRST expect doubles as the scene-ready wait. THE DEADLINE IS
            // THE LANE'S: iOS waits longer because its clipboard steps contain a
            // HUMAN-APPROVAL ROUND TRIP, measured at 2-3s solo and 6-10s under
            // the five-lane matrix (docs/clipboard-plan.md §8 finding 2).
            #if os(macOS)
                let stepDeadline = Date().addingTimeInterval(5.0)
            #else
                let stepDeadline = Date().addingTimeInterval(15.0)
            #endif
            var retryStep = true
            while retryStep {
                retryStep = false
                let failuresBefore = failures.count
                switch parts[0] {
            case "settle":
                Thread.sleep(forTimeInterval: Double(parts[1])! / 1000)
            case "click":
                let ok = DispatchQueue.main.sync { () -> Bool in
                    // A click on a TEXT KIND focuses it — what a native click
                    // does to a field, and the only way a scene can put focus
                    // on a STAMPED copy: a stamped entry has no live handle a
                    // guest could focus programmatically. Routed through the
                    // model's focusedId exactly as the wire's focus command is
                    // (the commandFocus arm): the model drives the first
                    // responder here, and a direct makeFirstResponder would
                    // fight it.
                    if let node = kayaTarget(parts[1], "entry", kayaScene.entryWidgets)
                        ?? kayaTarget(parts[1], "textarea", kayaScene.textareas)
                    {
                        kayaScene.focusedId = node.id
                        return true
                    }
                    guard let node = kayaTarget(parts[1], "button", kayaScene.buttons) else {
                        return false
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
                    node.checked = parts[2] == "on"
                    KayaHost.emitToggled(node.tag, node.checked)
                    return true
                }
                if !ok { failures.append("no such target \(parts[1])") }
            case "set_value":
                let ok = DispatchQueue.main.sync { () -> Bool in
                    guard let node = kayaTarget(parts[1], "slider", kayaScene.sliders) else {
                        return false
                    }
                    node.value = Double(parts[2])!
                    KayaHost.emitValue(node.tag, node.value)
                    return true
                }
                if !ok { failures.append("no such target \(parts[1])") }
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
                    node.value = Double(parts[2])!
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
                    node.text = kayaLF(kayaQuoted(Array(parts[2...])))
                    KayaHost.emitText(node, node.text)
                    return true
                }
                if !ok { failures.append("no such target \(parts[1])") }
            case "type":
                // A8's verb: REAL KEYSTROKES at whatever holds focus.
                // set_text cannot stand in for it — by D7 a programmatic write
                // CLEARS the native history a delegated-tier scene exists to
                // observe. It takes no target because "who receives this key"
                // is the platform's answer.
                let typed = kayaQuoted(Array(parts[1...]))
                #if os(macOS)
                    if !kayaTypeAtFocus(typed) {
                        failures.append(
                            "type \"\(typed)\" reached no window — nothing was typed")
                    }
                #else
                    // The same verb, through the only input path this
                    // platform has in process (kayaTypeAtFocus carries the
                    // deviation and what was measured in its place).
                    if !kayaTypeAtFocus(typed) {
                        failures.append(
                            "type \"\(typed)\" reached no editable first responder "
                                + "— nothing was typed")
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
                // The core's watchdog reading, over the C floor
                // (kaya_stalled_ms). Polled like every other expectation — the
                // watchdog needs its threshold to elapse before it will say
                // anything. Reported in the verdict rather than just passed,
                // so a green leg still shows how long the app was gone.
                let stalledMs = KayaHost.api.stalled_ms()
                if stalledMs > 0 {
                    observed.append("stalled \(stalledMs)ms")
                } else {
                    failures.append(
                        "the app thread is keeping up — no pending occurrences have gone "
                            + "unclaimed, so the stall watchdog has nothing to report")
                }
            case "expect_no_stall":
                // THE OTHER HALF OF THE SAME CLAIM, and the half nothing
                // asserted for four milestones: a watchdog that reports a
                // stall about a HEALTHY app is worse than none, because the
                // line is read as evidence. It shipped that way — the five
                // languages that read the occurrence ring directly reported a
                // stall on every green leg — and this arm refuses it.
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
                // The header bar as the TABLE PATH presented it — the
                // render's own record (the scroll-geometry precedent),
                // never the model echo: a wire that arrived but a table
                // that never rendered reads as "", loudly. Spelling:
                // "<titles|joined> [^N|vN]" — no size-class prefix,
                // headers render at every width (docs/tables-plan.md).
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
                // Per-row cell label texts: rows in the toolkit's child
                // order joined with `|`, each row's label cells joined
                // with `,` — expect_order's read one level deeper, for
                // the celled (table) shape whose moves a creation-order
                // registry cannot see.
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
                // The uniform GEOMETRY claim, both halves: the cells'
                // leading edges (recorded in window space by the
                // render's reporters) form exactly N clusters within
                // two units, AND the table spans the flex track it was
                // assigned — the regression a content-hugging layout
                // slips past every model-side observable. On the
                // NATIVE path both header and cell BOXES are
                // Table-placed, so intra-box content offsets are
                // invisible here (measured 2026-08-21: a padding
                // perturbation correctly did not fire) and the cluster
                // half's live protection is the COUNT — a column that
                // never renders reads 1 of 2. The synthesized tiers
                // place cells themselves, and their negatives moved
                // real placement.
                let want = Int(parts[2]) ?? -1
                let got = DispatchQueue.main.sync {
                    () -> (clusters: [Double], track: Double, drawn: Double)? in
                    guard let node = kayaTarget(parts[1], "column", kayaScene.columns) else {
                        return nil
                    }
                    var clusters: [Double] = []
                    var prev: Double?
                    for x in node.cellEdgeX.values.sorted() {
                        if let p = prev, x - p <= 2 {
                            prev = x
                            continue
                        }
                        clusters.append(x)
                        prev = x
                    }
                    return (
                        clusters, kayaMainExtents[node.id] ?? -1,
                        kayaDrawnExtents[node.id] ?? -1
                    )
                }
                if let got, got.clusters.count == want, got.track <= 0 || got.drawn >= got.track - 2 {
                    observed.append("\(parts[1]) column edges \(want)")
                } else if let got, got.clusters.count != want {
                    let seen = got.clusters.map { String(Int($0.rounded())) }
                        .joined(separator: ",")
                    failures.append(
                        "\(parts[1]) cell edges cluster at [\(seen)], wanted \(parts[2]) columns")
                } else if let got {
                    failures.append(
                        "\(parts[1]) draws \(Int(got.drawn.rounded()))pt of a "
                            + "\(Int(got.track.rounded()))pt track")
                } else {
                    failures.append("no such target \(parts[1])")
                }
            case "header_click":
                // The user's route: what the Table's sortOrder binding
                // setter does for a real header click — the sort tag
                // verbatim plus the column index, and NO model change:
                // the indicator moves when the guest re-declares
                // (select_section's drive-and-emit precedent).
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
            case "expect_shares":
                // The container's children as whole-percentage shares of
                // their sum. Percent of the children's sum and not of the
                // container, so spacing and padding stay out of the number;
                // the rounding matches harness::shares exactly, because
                // expect_shares compares byte-for-byte across all backends.
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
                // reads each `case "expect_*"` head and demands that arm
                // record or refuse, and a verb sharing another's head is a
                // verb the sweep never looks at.
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
                    failures.append("\(prefix)title \"\(got)\", wanted \"\(want)\"")
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
                // (docs/dirty-plan.md D5). On macOS that is the dot in the
                // close button and NOTHING ELSE — the title string does not
                // change — and the accessibility tree publishes it as AXEdited
                // ON THE CLOSE BUTTON. The model is NOT the source: reading it
                // would make the verb agree with itself, and the failure under
                // test is a lowering that never reached the NSWindow.
                //
                // iOS's read is the applied prop instead, a stated carve-out
                // rather than a shortcut (D4) — see kayaWindowDirtyState for
                // why that is still an observation. The phone lane runs this
                // scene's PHONE-EXPRESSIBLE PREFIX (tools/ios/run-sim.sh's
                // `cut` argument states that with its reasons).
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
                    // platform's own observable. Spelled out rather than
                    // sharing a preamble with it: a `let` bound in one arm and
                    // read below the `#endif` compiles on one platform and not
                    // the other, and this file's iOS half has broken exactly
                    // that way before.
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
                    kayaScene.windows[wid]?.entries.count ?? -1
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
                    // NO back affordance while both panes are on screen.
                    // NavigationSplitView draws no back button in a detail
                    // column sitting beside its sidebar, so driving the pop
                    // anyway would let the harness do what the screen does not
                    // offer.
                    guard !kayaSplitArm(wid) else { return }
                    let depth = kayaScene.windows[wid]?.entries.count ?? 0
                    kayaUserPops(wid, to: max(0, depth - 1))
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
                if let (content, viewport) = got {
                    if content > viewport + 2 {
                        observed.append("\(parts[1]) overflows")
                    } else {
                        failures.append(
                            "\(parts[1]) fits (content \(Int(content)) in viewport \(Int(viewport)))")
                    }
                } else {
                    failures.append("no such target \(parts[1])")
                }
            case "scroll_end":
                // The REAL scrolling API: the reader proxy animates to
                // the content's bottom anchor. Silent, like click.
                DispatchQueue.main.sync {
                    guard let node = kayaTarget(parts[1], "scroll", kayaScene.scrolls),
                        let proxy = kayaScrollProxies[node.id]
                    else { return }
                    proxy.scrollTo("kaya-scroll-content-\(node.id)", anchor: .bottom)
                }
            case "expect_at_end":
                // The content's bottom edge coincides with the
                // viewport's (within two units) — read back from the
                // viewport-space frame, never a model copy.
                let got = DispatchQueue.main.sync { () -> (Double, Double)? in
                    kayaTarget(parts[1], "scroll", kayaScene.scrolls)
                        .map { ($0.scrollContentMaxY, $0.scrollViewportH) }
                }
                if let (maxY, viewport) = got {
                    if abs(maxY - viewport) <= 2 {
                        observed.append("\(parts[1]) at end")
                    } else {
                        failures.append(
                            "\(parts[1]) short of end (content bottom \(Int(maxY)) vs viewport \(Int(viewport)))")
                    }
                } else {
                    failures.append("no such target \(parts[1])")
                }
            case "expect_file_dialog":
                // The REAL panel, read over accessibility: the directory it is
                // actually showing and the names its list actually contains.
                // Both matter — a panel aimed at the wrong place, or filtered
                // down to nothing, presents perfectly and is useless.
                // Identifiers measured with tools/mac/paneldrive.swift.
                // Expanded like the goto's argument.
                let wantDir = parts.count > 1 ? kayaExpandPath(String(parts[1])) : ""
                let wantNames = parts.count > 2 ? parts[2...].map(String.init) : []
                // A LEFTOVER $ means the expansion did not happen, and an
                // unexpanded expectation is the WORST shape of this bug: the
                // picker is aimed correctly, shows the right directory, and
                // the comparison fails against a literal "$PID" — which reads
                // as a broken picker.
                if wantDir.contains("$") {
                    failures.append(
                        "expect_file_dialog \(wantDir): unexpanded substitution — "
                            + "only $TMP and $PID exist")
                }
                #if os(macOS)
                    // THE WAIT FOR CONTENT IS THIS CALL'S, NOT THE STEP
                    // RETRY'S: a live panel whose browser lists nothing is a
                    // read that beat the browser, and by the time it lands the
                    // retry budget is spent inside the blocked hop that made
                    // it (kayaAwaitOpenPanelState carries the measurement).
                    // Only the forms that NAME FILES wait.
                    let state = kayaAwaitOpenPanelState(requireRows: !wantNames.isEmpty)
                #else
                    // OFF the main thread, deliberately: the read goes out to
                    // the host and back, and the app must keep servicing its
                    // run loop while it does — the picker is a remote view
                    // controller and a blocked main thread stalls the very UI
                    // being read.
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
                            // THE PICKER PUBLISHES DISPLAY NAMES, and iOS's
                            // omit the extension: the row for picked.txt reads
                            // "picked". That is a property of the
                            // accessibility label and not of the file, so the
                            // comparison is on the stem — and the scene still
                            // proves the RIGHT file was chosen, because it
                            // reads the bytes and the decoy's differ.
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
                        // THE ONE THAT MATTERS. NSOpenPanel silently RESTORES
                        // ITS LAST-USED LOCATION when pointed at a directory
                        // that does not exist — including one left behind by
                        // an unrelated process — so the scene then asserts
                        // against someone else's directory. Two separate bugs
                        // landed here: setting directoryURL after presentation
                        // (it is honored only AT presentation), and $TMP
                        // resolving differently on the two sides.
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
                // Drive the REAL controls: select the row and press Open, or
                // press Cancel. Not a synthesized completion — the panel's own
                // handler runs because its own button was pressed.
                //
                // EXCEPT that the row must be THERE, the same rule harness.rs
                // applies: a name that matches nothing skips the selection and
                // presses Open anyway, and the panel then completes with
                // whatever was already selected — a silent wrong file
                // (measured on GTK).
                let arg = parts.count > 1 ? String(parts[1]) : ""
                if arg != "cancel", !arg.isEmpty {
                    #if os(macOS)
                        // THE SAME WAIT, and here it is the only one there is:
                        // file_choose is an ACTION, so the step wrapper never
                        // re-runs it, and a read that beat the browser refuses
                        // the row for good. Measured in the same run as the
                        // expect above.
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
                    // AND THE PANEL MUST BE GONE, the same postcondition
                    // harness.rs applies. A press that lands before the panel
                    // is interactive is swallowed with no error anywhere, so
                    // the leg fails three steps later on an assertion about
                    // the GUEST — where nobody looks for a harness problem.
                    //
                    // AND THE PRESS IS RE-PRESSED, bounded, on the
                    // postcondition's own evidence (2026-08-17: the five-lane
                    // matrix swallowed a single press on the
                    // modern-generation panel while the same leg ran green
                    // twice standalone — contention stretches the
                    // not-yet-interactive window). The re-press is safe
                    // BECAUSE of the postcondition: a press that landed
                    // dismisses the panel, so pressing again only ever happens
                    // where the previous press provably did nothing.
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
                // The REAL save panel, read over accessibility: the directory
                // it is showing AND the name in its name field. The name half
                // catches a backend that ignored the name it was told and
                // saved under the SUGGESTED name, where every byte assertion
                // downstream still passes and points at the wrong file.
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
                        let saveWhy = "no save dialog live"
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
                // not presented yet does nothing at all, and the leg then
                // saves under the suggested name with every downstream
                // assertion still green.
                let saveName = parts.count > 1 ? String(parts[1]) : ""
                if saveName.isEmpty {
                    failures.append("file_dialog_name wants a file name")
                } else {
                    #if os(macOS)
                        if kayaAwaitSavePanelState() == nil {
                            failures.append(
                                "file_dialog_name \(saveName): no save dialog is live")
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
                            failures.append("file_save: no save dialog is live")
                        } else {
                            DispatchQueue.main.sync { kayaSavePanelDrive(save: saveArg != "cancel") }
                            // AND THE PANEL MUST BE GONE — the picker's
                            // postcondition and the same reason: a press that
                            // lands before the panel is interactive is
                            // swallowed with no error anywhere, and the leg
                            // fails three steps later on the GUEST.
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
                // THE RESOLVED FAMILY, off the real views. Never the request:
                // every font API on this platform renders SOMETHING for a
                // family it does not have, so an echo would report a perfect
                // swap for a font that was never installed
                // (docs/styling-plan.md Slice 2b).
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
                    // THE APPLY SIDE IS LIVE ON iOS — the same
                    // substitution, through UIFontMetrics — but the
                    // OBSERVATION has not been proven on a device, so
                    // the iOS runner wires no typeface legs and this
                    // says so where a reader will meet it.
                    kayaDepthStub("typeface", on: "ios")
                #endif
            case "expect_app_icon":
                // TWO PLATFORMS, TWO ARTIFACTS, ONE STRING. macOS reads
                // AppKit's own copy of the Dock picture; iOS reads the icon
                // file inside the bundle it is running out of, having no
                // runtime route to the Home Screen at all. Both go through the
                // same quadrant sampler (docs/app-identity-plan.md I8).
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
            case "expect_inset":
                // The content inset, MEASURED as the halved gap between the
                // padding container's outer extent and the offer inside it —
                // RELATIVE deliberately: absolute offers cannot be byte-frozen
                // across platforms (GTK's CSD headerbar sits inside the
                // window's height where macOS's titlebar sits outside), while
                // the inset is the same number everywhere
                // (docs/styling-plan.md D3).
                //
                // TWO FORMS, one measurement: `expect_inset N` reads the
                // WINDOW's pair, `expect_inset <target> N` a CONTAINER's own.
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
                    // STRETCH FIRST, and alone: spanning geometry is
                    // DEGENERATE — a child at (0, inner) satisfies the
                    // start/center/end predicates too, so a stretched
                    // container could never classify by elimination
                    // (measured: the multi-match rule answered
                    // "ambiguous(4)" for every true stretch). All children
                    // spanning IS stretch; the positional modes classify
                    // only a container with a non-spanning child, and the
                    // scene's separability burden (differing naturals)
                    // keeps luck out, exactly as with center.
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
            case "expect_fills":
                // ONE VERB, TWO SUBJECTS (harness.rs Step::ExpectFills). A
                // CONTAINER's children span its content box — the
                // leftover-consumption half of the grow contract, which shares
                // (total-invariant) and root_fills (root-level only) can never
                // see. A WIDGET spans the track KayaFlex assigned IT:
                // kayaMainExtents is the TRACK, so a control drawing at a hard
                // 240x96 inside a correct 126pt slot splits the column exactly
                // right. An OVERFLOW is not a leftover, so the test is
                // one-sided.
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
                    // the track its weight earned before its children can span
                    // anything — the dashboard's first photograph caught it
                    // drawing 148pt of a 346pt track with every model
                    // observable green (the GAP entry beside dynamic-tables).
                    // One-sided like the rest, and skipped when no track was
                    // recorded (the root, or a non-flex parent).
                    if let track = kayaMainExtents[container.id], track > 0 {
                        let drawn = kayaDrawnExtents[container.id] ?? 0
                        if drawn < track - 2 {
                            return
                                "draws \(Int(drawn.rounded()))pt of its own \(Int(track.rounded()))pt track"
                        }
                    }
                    // THE BREADTH CLAUSE (2026-08-22): a CROSSING container —
                    // a row in a column, a column in a row — spans its
                    // parent's inner breadth, under every align mode. Its
                    // cross-rect in the parent's space is already recorded
                    // for the classifier; skipped honestly when the parent
                    // is not a recorded container (the root).
                    if let parent = (isRow ? kayaScene.columns : kayaScene.rows)
                        .first(where: { p in p.children.contains(where: { $0.id == container.id }) }),
                        let parentInner = kayaContainerCross[parent.id], parentInner > 0,
                        let r = kayaCrossRects[container.id],
                        r.1 < parentInner - 2
                    {
                        return
                            "spans \(Int(r.1.rounded()))pt of its parent's \(Int(parentInner.rounded()))pt breadth"
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
                // CONTAINMENT, never the viewport itself: how much context a
                // scroll leaves around a range is native behaviour and differs
                // per lane, while "is my range on screen" is the same question
                // everywhere. The `offscreen` spelling is what keeps this from
                // being vacuous — a scene asserts it BEFORE the reveal, so a
                // document short enough to be entirely visible fails.
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
                        // The verb's offsets are the PROTOCOL's unit — UTF-8
                        // bytes — so they are converted here, in the reading
                        // direction, against the text the control is holding.
                        // The lowering path below does no such arithmetic and
                        // must not: it receives UTF-16 from the core.
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
                // verb can reach: `type` is printable ASCII by contract,
                // because a composed character is an input-method question and
                // not a verb argument. Through the view's own `setMarkedText`,
                // so the text is DISPLAYED, UNCOMMITTED and invisible to the
                // app — exactly the state select_range must refuse to run over.
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
                    observed.append("ax hint \(wantHint)")
                } else {
                    failures.append("ax hint \(gotHint), wanted \(wantHint)")
                }
            case "expect_ax":
                // target -> node -> its authored identifier -> the REAL
                // accessibility tree. Routed through the identifier rather
                // than reading the node: an element the platform never
                // published simply is not found, and that failure is the point
                // of the verb.
                let wantAx = kayaQuoted(Array(parts[2...]))
                // The identifier is resolved on the main thread (scene state
                // lives there), but the AX READ ITSELF runs on the harness
                // thread ON PURPOSE. Accessibility requests are serviced BY
                // the app's main runloop, so querying yourself from inside
                // main.sync leaves nothing able to answer: AppKit chrome still
                // replies from cache, while SwiftUI's lazily-materialized
                // elements come back empty.
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
                    observed.append("ax \(wantAx)")
                } else {
                    // The platform's own classification rides the failure:
                    // `unknown/…` is never self-explaining, and the answer is
                    // one platform round-trip away otherwise.
                    let why = identifier.flatMap { $0.isEmpty ? nil : kayaAxWhy($0) } ?? ""
                    failures.append("ax \(gotAx), wanted \(wantAx)\(why)")
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
                        kayaNSWindows[0]?.setContentSize(NSSize(width: rw, height: rh))
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
                // `<size class>/<presentation>`. macOS reads the REAL bar
                // (there are no size classes there, and a desktop window
                // carries the global bar unconditionally, so the class is
                // always regular). Elsewhere both halves come off the window
                // model's stamps — never a derivation from the other half.
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
                        // HONEST LIMITATION, recorded rather than hidden. Every
                        // other backend reads its real chrome; iOS cannot — the
                        // iPadOS menu bar is built LAZILY (measured: buildMenu
                        // runs once at launch with an empty catalog and never
                        // again, however many times setNeedsRebuild is called),
                        // and UIKit exposes no way to present a menu
                        // programmatically. So this one half is ARM-DERIVED on
                        // iOS-regular: it reports the lowering this window
                        // selected. The bar itself was confirmed by eye on an
                        // iPad Pro (2026-07-25); the iPad's own tree carries no
                        // menu-bar element and iOS 26's UIMainMenuSystem build
                        // handler never fires (docs/deferred.md).
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
                // THE BARE INVARIANT (docs/chrome-plan.md C2): the promoted
                // set is really in this window's chrome and the remainder is
                // reachable. Never a count — capacity k is the platform's own
                // number and this scene is compared byte-for-byte on five
                // lanes — so the pass observation is one lane-independent word
                // and the MEASURED numbers ride the failure.
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
                // resolution while presented; otherwise macOS walks the owned
                // NSApp.mainMenu segment by title and performs the item's REAL
                // target/action (no model-route fallback), and iOS resolves
                // through the same catalog helper the toolbar consumes, so a
                // promoted primary resolves WITHOUT opening More.
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
                    // inert standard command is the one activation that
                    // succeeds and does nothing (kayaRoleInertNote). Resolved
                    // against the model, as the mac route does before it walks
                    // to the real NSMenuItem.
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
                if let fault = kayaCoreFaultNote() {
                    // THE CORE FAULTED: a guard caught an app misuse, or a
                    // transaction died inside Scene::apply. Nothing after this
                    // is applied, so the retry the expect was owed is dead
                    // time and every following step would fail at its own
                    // deadline for a reason three removes from this one.
                    //
                    // The in-flight attempt is RETRACTED for the reason the
                    // breach's is: it had not reached its deadline, so it was
                    // never final, and "reads """ printed next to the cause is
                    // what sends the next reader after the wrong thing.
                    failures.removeLast(failures.count - failuresBefore)
                    failures.append(fault)
                    print("KAYA_HARNESS: step-failed \(fault)")
                    reportedFault = true
                    break scriptLines
                }
                if let breach = kayaClipBreachNote() {
                    // THE WITNESS FIRED: somebody else's clip is on the board,
                    // so nothing this leg asserts from here is about the clip
                    // it staged.
                    //
                    // What this attempt observed is RETRACTED rather than
                    // reported beside the breach — an expect had not reached
                    // its deadline, so it was never final, and "reads """
                    // printed next to the cause is the sentence that sent
                    // 2026-08-18 after kaya's paste. The read's own account
                    // stays in the stderr trace. Then the script stops.
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
                    // THE EVIDENCE MUST OUTLIVE THE PROCESS. The verdict line
                    // at the bottom is authoritative but is printed LAST — and
                    // a scene whose failure is "the dialog did not resolve"
                    // walks into the one-per-process dialog guard three steps
                    // later, which ABORTS. The failure list then dies with the
                    // process and the log shows a panic with no reason, which
                    // is exactly the round this cost on iOS.
                    //
                    // So a failure is printed the moment it becomes FINAL — an
                    // expect whose deadline has run out, or any action, which
                    // never retries. One line each, on the same line-buffered
                    // stdout as the step trace.
                    for text in failures[failuresBefore...] {
                        print("KAYA_HARNESS: step-failed \(text)")
                    }
                }
            }
        }
    }
    // THE PINS ARE PART OF THE SCENE'S VERDICT. A rich control's opinion
    // shipping by accident is this milestone's named failure mode, so a pin
    // that is not in force fails the leg that rendered the widget rather than
    // waiting for a gate somebody has to remember to run.
    //
    // ONE CLAUSE FOR BOTH APPLE ARMS, on purpose: the two platforms pin a
    // different vocabulary (a UITextView's keyboard traits, an NSTextView's
    // checking and find flags) but hold the SAME rule, so they fill the same
    // set and answer through the same sentence.
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
        exit(0)
    }
    // THE UNMOUNTED-SCENE DIAGNOSIS. A scene that creates widgets and never
    // calls mount(root) renders an EMPTY window, and every assertion then
    // measures an invisible app. Target resolution cannot catch it — the
    // widgets exist in the model, so `kind#index` resolves happily.
    //
    // Checked HERE rather than before the run, for two reasons: at script
    // start the guest's transactions have not arrived yet, so the scene
    // legitimately looks empty (the first attempt at this guard fired never);
    // and on the failure path it cannot false-positive on a scene that mounts
    // late. This cost most of an afternoon on 2026-07-25, and was misdiagnosed
    // in turn as an SDK-generation, a language and a missing-API problem.
    var reported = failures
    if !kayaScene.nodes.isEmpty,
        kayaScene.windows.values.allSatisfy({ $0.root == nil && $0.sections.isEmpty })
    {
        reported.insert(
            "\(kayaScene.nodes.count) widgets exist but NO ROOT IS MOUNTED on any surface "
                + "— the scene never called mount(root), so every assertion above measured "
                + "an empty window",
            at: 0)
    }
    FileHandle.standardError.write(
        "KAYA_SELFTEST: FAILED (\(reported.joined(separator: "; ")))\n".data(using: .utf8)!)
    exit(1)
}

/// The main-axis extent each node's TRACK was allocated, by node id — what
/// `expect_shares` reads back.
///
/// Written by KayaTrackReader, NEVER from inside a layout pass: SwiftUI runs
/// speculative passes at arbitrary sizes and delivers them in no useful order
/// — a natural-width pass arriving after the real one once clobbered a correct
/// 25/75 into 26/74, and zero-size passes clobbered 96/286 into 0/0. Geometry
/// only ever describes the rendered result. Main-actor only.
var kayaMainExtents: [UInt64: Double] = [:]

/// The invisible frame each flex child rides in IS the track KayaFlex assigned.
/// The reader records the frame's geometry — the layout rect, never the child's
/// drawn size, which several controls inflate or hug.
private struct KayaTrackReader: View {
    let id: UInt64
    let vertical: Bool

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { record(geo.size) }
                .onChange(of: geo.size) { _, size in record(size) }
        }
    }

    private func record(_ size: CGSize) {
        kayaMainExtents[id] = Double(vertical ? size.height : size.width)
    }
}

/// The main-axis extent each CONTAINER rendered at, by node id — what
/// `expect_fills` compares its children's tracks against. Same geometry-only
/// discipline as the track extents: never written from a layout pass.
var kayaContainerExtents: [UInt64: Double] = [:]

/// Each container's CROSS-axis extent, and each child's cross-axis (start,
/// extent) in its container's named coordinate space — what `expect_aligned`
/// classifies from. Baseline offsets are the distance from a text child's top
/// to its first baseline, recorded through an identity alignmentGuide hook:
/// that value is a font metric for single-line text, invariant across
/// speculative passes, so the recording trap does not apply.
var kayaContainerCross: [UInt64: Double] = [:]
var kayaCrossRects: [UInt64: (Double, Double)] = [:]
var kayaBaselineOffsets: [UInt64: Double] = [:]

/// The main-axis extent each flex child DREW at, by node id — what
/// `expect_fills` compares against that child's track on a widget target.
///
/// THE TRACK'S SIBLING, AND DELIBERATELY NOT THE SAME NUMBER.
/// `kayaMainExtents` is the layout rect the grow arithmetic decided; this is
/// the box the control actually took inside it, and the gap between them is
/// where a widget with a hard-coded size hides: it splits its container
/// exactly right and renders at 96pt in a 126pt slot. It rides the CHILD
/// inside the cell, so a speculative layout pass cannot write it.
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

/// The container-extent sibling of KayaTrackReader: a background reader on the
/// container view itself, recording its rendered main-axis extent.
///
/// The container-inset measurement pair (docs/styling-plan.md D3): the INNER
/// reader rides the container's content, the OUTER one rides the same view
/// after `.padding(node.inset)`, and `expect_inset <target>` reads the halved
/// gap between them — RELATIVE for the window measurement's exact reason. Both
/// record unconditionally, so a step can also assert a container is FLUSH (0).
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

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { record(geo.size) }
                .onChange(of: geo.size) { _, size in record(size) }
        }
    }

    private func record(_ size: CGSize) {
        kayaContainerExtents[id] = Double(vertical ? size.height : size.width)
        kayaContainerCross[id] = Double(vertical ? size.width : size.height)
    }
}

/// The mounted root's rendered size and the area the window offered it — what
/// `expect_root_fills` compares. Both come from GeometryReaders, so neither can
/// be clobbered by a speculative layout pass. Main-actor only.
var kayaRootSize = CGSize.zero
var kayaAvailableSize = CGSize.zero

/// SwiftUI's half of the `grow` contract.
///
/// VStack/HStack cannot express it: SwiftUI's only per-child knob is
/// `layoutPriority`, which is *ordinal*, so a 1:3 request is unrepresentable
/// with the built-in stacks. The policy is [`Prop::Grow`]: weight-0 children
/// take their natural main-axis size and the growers divide what is left in
/// proportion to their weights.
///
/// The flex track's cell places its child by proposing the FULL cell, never the
/// child's own fitted size. It replaces the alignment-frame idiom, whose
/// placement re-proposes the child its fitted ideal — a hugging stack proposed
/// exactly its ideal runs the platform stack's fair-share division with zero
/// slack and a conforming control absorbs the shortfall (docs/deferred.md's
/// KayaCell entry). Cross-axis: start/stretch/baseline lead, center centers,
/// end trails; the main axis always starts.
struct KayaCell: Layout {
    /// The CONTAINER's axis: true for a column's cells.
    let vertical: Bool
    /// The container's cross-axis align mode.
    let align: Int64

    /// A CELL WHOSE CHILD RENDERED NOTHING IS A ZERO-SIZE CELL, NEVER A TRAP.
    /// The cell wraps exactly one KayaRender, so `subviews` holds one element
    /// for every kind that produces a view — but "produces a view" is a
    /// convention no type enforces, and a SwiftUI `if let` with no `else`, or
    /// this file's `default:` arm for an unknown kind, yields a Subviews
    /// collection of COUNT ZERO. `subviews[0]` then traps on the subscript
    /// (EXC_BREAKPOINT inside LayoutSubviews.subscript.getter), killing the
    /// process before any expectation could be read. The image kind is now
    /// present-and-empty on a failed decode; the fallback stays because the
    /// next kind to render conditionally would find the same trap.
    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let natural = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(
            width: proposal.width ?? natural.width,
            height: proposal.height ?? natural.height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        guard let child = subviews.first else { return }
        let full = ProposedViewSize(width: bounds.width, height: bounds.height)
        let size = child.sizeThatFits(full)
        // The baseline-recording hooks are alignmentGuide closures, and guide
        // closures only run when somebody QUERIES a guide — the alignment
        // frames this layout replaced used to be that somebody. Query .top
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

/// The declared table's surface (docs/tables-plan.md): SwiftUI Table on
/// the native tier — NSTableView's wrapper on macOS, the native headers,
/// resize and indicator — and kaya's own header on the other;
/// kayaTableTier below is the rule between them. The sortOrder binding
/// is the click path and nothing else: its getter presents the GUEST's
/// declared indicator, its setter emits sort_requested and changes
/// nothing — the platform never sorts the model (one-way flow, the echo
/// doctrine's shape).
private struct KayaColumnSpec: Identifiable {
    let id: Int
    let title: String
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

/// Which tier a host takes, from its inputs alone — PURE, because the
/// two tiers present identical bytes and no scene can name the one that
/// drew it (docs/traps.md, "An observable with no discriminator").
/// tools/check-table-tier.sh drives this truth table and holds
/// KayaTableSurface as its only caller.
///
/// `dynamicColumns` is TableColumnForEach's floor (macOS 14.4 / iOS
/// 17.4), below kaya's own. A COMPACT iOS width takes kaya's header at
/// any availability: SwiftUI's Table collapses to a first-column list
/// there and throws the declared columns away (docs/tables-plan.md
/// decision 5, revised 2026-08-21).
func kayaTableTier(width: KayaTableWidth, dynamicColumns: Bool) -> KayaTableTier {
    guard dynamicColumns else { return .synthesized }
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

    /// Nothing on macOS SETS a horizontal size class (the key and the
    /// type both compile there — measured at -target macos13.0), and the
    /// mac Table does not collapse, so the mac reports the absence and
    /// the rule answers native. Internal, not private: the gate's probe
    /// reads it to check this host's own branch.
    var widthClass: KayaTableWidth {
        #if os(macOS)
            return .noSizeClass
        #else
            return kayaTableWidth(sizeClass: horizontalSizeClass)
        #endif
    }

    var body: some View {
        if #available(macOS 14.4, iOS 17.4, *) {
            switch kayaTableTier(width: widthClass, dynamicColumns: true) {
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

@available(macOS 14.4, iOS 17.4, *)
private struct KayaNativeTable: View {
    let node: KayaNode

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
                            KayaEdgeReporter(node: node, key: "\(row.id)/\(spec.id)"))
                    }
                }
            }
        }
        .onAppear { record() }
        .onChange(of: node.tableColumns) { record() }
        .onChange(of: node.tableSorted) { record() }
        .onChange(of: node.tableDirection) { record() }
    }

    /// The presented record expect_columns reads — written by THIS
    /// path only, so the observation proves the table rendered: the
    /// titles in visual order and the indicator (^N asc / vN desc)
    /// when shown. No size-class prefix — headers render at every
    /// width (ratified 2026-08-21, docs/tables-plan.md).
    private func record() {
        var presented = node.tableColumns.joined(separator: "|")
        if node.tableSorted != kayaSortNone {
            presented += node.tableDirection == 0 ? " ^" : " v"
            presented += String(node.tableSorted)
        }
        let target = node
        DispatchQueue.main.async { target.tablePresented = presented }
    }
}

/// Records one cell's leading edge into the table node's cluster
/// store, in window space — expect_column_edges' raw material.
private struct KayaEdgeReporter: View {
    let node: KayaNode
    let key: String
    var body: some View {
        GeometryReader { geo in
            let x = Double(geo.frame(in: .global).minX)
            Color.clear.task(id: x) { node.cellEdgeX[key] = x }
        }
    }
}

/// The synthesized tiers' shared geometry rule (docs/tables-plan.md
/// decision 6): a column's content width is its FLOOR, never its
/// size — leftover track width distributes across the columns, so
/// the table spans its viewport (the native Table's resting look,
/// stated as a rule; the span half of expect_column_edges holds it).
/// Subviews arrive in content order: cols headers, the divider, then
/// the stamped cells row-major.
private struct KayaTableLayout: Layout {
    let cols: Int
    let colGap: CGFloat
    let rowGap: CGFloat

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

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let (_, total) = columnWidths(subviews, proposal)
        let (headerH, dividerH, rows) = rowHeights(subviews)
        let height =
            headerH + rowGap + dividerH + rowGap + rows.reduce(0, +)
            + rowGap * CGFloat(max(0, rows.count - 1))
        return CGSize(width: total, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let (widths, _) = columnWidths(subviews, proposal)
        let (headerH, dividerH, rows) = rowHeights(subviews)
        var colX = [CGFloat](repeating: 0, count: cols)
        var acc = bounds.minX
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
        var y = dividerY + dividerH + rowGap
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

/// The synthesized tier (docs/tables-plan.md): kaya's own header over
/// KayaTableLayout's floored-and-distributed columns, for hosts below
/// the native Table's dynamic-column floor AND for every COMPACT iOS
/// width, where the native Table would collapse to a first-column list
/// and hide the declared columns. Headers render at EVERY width
/// (ratified 2026-08-21). Sorting stays a request: a header tap emits
/// and the indicator moves only when the guest re-declares.
private struct KayaSynthesizedTable: View {
    let node: KayaNode

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

    var body: some View {
        KayaTableLayout(cols: node.tableColumns.count, colGap: 24, rowGap: node.spacing) {
            ForEach(Array(node.tableColumns.enumerated()), id: \.offset) { col, title in
                Text(headerText(col, title))
                    .fontWeight(.semibold)
                    .background(KayaEdgeReporter(node: node, key: "h/\(col)"))
                    .onTapGesture {
                        KayaHost.emitSortRequested(node.sortTag, UInt32(col))
                    }
            }
            Divider()
            ForEach(node.children) { row in
                ForEach(Array(row.children.enumerated()), id: \.offset) { col, cell in
                    KayaRender(node: cell, flexVertical: false, flexStretch: false)
                        .background(KayaEdgeReporter(node: node, key: "\(row.id)/\(col)"))
                }
            }
        }
        // task(id:), not onChange: this tier compiles at the macOS 13 /
        // iOS 16 floor, below the zero-parameter onChange.
        .task(id: presented) { node.tablePresented = presented }
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

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let natural = subviews.map { $0.sizeThatFits(.unspecified) }
        let gaps = spacing * CGFloat(max(0, subviews.count - 1))
        let naturalMain = natural.map { main($0) }.reduce(0, +) + gaps
        let naturalCross = natural.map { cross($0) }.max() ?? 0
        // Fill the MAIN axis from the proposal — that is what creates the free
        // space the growers divide, and what the other backends do — and hug
        // the cross axis unless [fillCross]: filling it UNCONDITIONALLY made a
        // row claim its column's whole height (a band of empty space in the
        // recording), because SwiftUI probes with concrete proposals too.
        // fillCross is set only where a parent deliberately handed this
        // container a box — the root, a stretch cell, a cross-oriented grow
        // track (the 2026-08-22 ruling; the GAP entry beside dynamic-tables).
        //
        // THE FALLBACK IS PER-AXIS: an unspecified cross dimension must fall
        // back to naturalCross, or a fillCross container measured with an
        // unspecified proposal answers max(naturalCross, naturalMain) and
        // poisons its parent's natural-size pass.
        let fallback = vertical
            ? CGSize(width: naturalCross, height: naturalMain)
            : CGSize(width: naturalMain, height: naturalCross)
        let extent = proposal.replacingUnspecifiedDimensions(by: fallback)
        let filledMain = vertical ? extent.height : extent.width
        let filledCross = vertical ? extent.width : extent.height
        let crossExtent = fillCross ? max(naturalCross, filledCross) : naturalCross
        return vertical
            ? CGSize(width: crossExtent, height: filledMain)
            : CGSize(width: filledMain, height: crossExtent)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        guard !subviews.isEmpty else { return }
        let gaps = spacing * CGFloat(subviews.count - 1)
        // A grower's own natural size is deliberately not consulted: the
        // contract is flex-basis 0, so it starts from nothing.
        var extents = subviews.indices.map { i -> CGFloat in
            weight(i) > 0 ? 0 : main(subviews[i].sizeThatFits(.unspecified))
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

/// One style switch, because `.buttonStyle` takes a concrete type: bordered is
/// the dressed floor, borderedProminent the `prominent` role's chrome — the
/// platform's own emphasis, not a color kaya invented. Top level, because a
/// platform-conditional TYPE would put the compile error on the other
/// platform's lane.
///
/// kayaOuterSize is the padding container's OUTER size (before the window inset
/// is taken), the other half of the measured-inset observation.
@MainActor var kayaOuterSize: CGSize = .zero

/// The brand tint for the CURRENT appearance, or nil for "no request". A
/// DECLARED BRAND WINS ON EVERY PLATFORM — the macOS user-accent yield was
/// dropped 2026-08-12, because `.tint()` is an explicit environment value the
/// system does not arbitrate (docs/styling-plan.md D2), and the other three
/// backends already branded unconditionally. A BRANDLESS app still gets the
/// user's accent everywhere: nil here means the environment default, which on
/// macOS IS that preference.
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
//
// Built from a measured probe, not from the documentation: the route every blog
// post and half of Apple's own docs suggest — take
// `preferredFont(forTextStyle:)`'s descriptor and `withFamily` it — IS A SILENT
// NO-OP on both Apple platforms, because the system font's descriptor carries
// NSCTFontUIUsageAttribute and that outranks the family. Measured: the first
// render through that route reported 0.0000 differing pixels on all twelve
// widget rows for Georgia, Menlo, Helvetica and a nonsense family alike.
//
// What works is a FRESH descriptor carrying the family plus the ramp's own
// weight, resolved at the ramp's own pointSize.

#if os(macOS)
    typealias KayaPlatformFont = NSFont
    typealias KayaPlatformTextStyle = NSFont.TextStyle
    typealias KayaPlatformFontDescriptor = NSFontDescriptor
#else
    typealias KayaPlatformFont = UIFont
    typealias KayaPlatformTextStyle = UIFont.TextStyle
    typealias KayaPlatformFontDescriptor = UIFontDescriptor
#endif

/// Is this family installed on THIS device?
///
/// ONE GATE FOR BOTH APPLE PLATFORMS, and it is not the obvious one.
/// `NSFont(descriptor:size:)` returns nil for a family macOS does not have, so
/// there the construction itself is a refusal — but `UIFont(descriptor:size:)`
/// is NON-OPTIONAL and silently hands back Helvetica, so the identical route
/// has different failure semantics on the two platforms (measured). Left alone
/// that is an invariant-1 divergence inside one file.
/// CTFontDescriptorCreateMatchingFontDescriptor answers the same way on both,
/// so the gate goes in FRONT of the substitution.
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
        // BOLD TEXT, CORRECTED — the one accessibility affordance a family
        // swap silently drops. The system font moves Regular -> Semibold when
        // the user turns Bold Text on; a substituted family does not move at
        // all (measured), so a branded app would quietly stop answering the
        // setting. Lowering-internal and invisible to apps — DESIGN.md's
        // tier-2 escape. macOS has no Bold Text switch at all, which is why
        // this is inside the platform conditional.
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
        // Dynamic Type. macOS has none (per Apple DTS); iOS does, and the raw
        // substituted font does NOT scale — it must run through UIFontMetrics.
        // The swapped ramp tracks the system's without matching it (53pt vs
        // 48pt at accessibilityXXXL), which is inherent to substituting a
        // family.
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
/// FAMILY NAME the registration produced.
///
/// IN-PROCESS SCOPE: the font joins this process's font list and nothing
/// else's — kaya never installs anything on a user's machine. After this the
/// family is present exactly as a system-supplied one is, so the name machinery
/// below takes over unchanged (Slice 2b's register-then-resolve).
func kayaRegisterFont(_ bytes: Data) -> String? {
    guard
        let descriptors = CTFontManagerCreateFontDescriptorsFromData(bytes as CFData)
            as? [CTFontDescriptor],
        let first = descriptors.first
    else {
        return nil
    }
    // Enabled at register, because the descriptors must be usable in this same
    // launch — the typeface applies before the first mount.
    //
    // THE CALL'S OWN VERDICT IS NOT CONSULTED, deliberately: it reports through
    // a registration handler, while the family name comes back here and the
    // presence gate then asks CoreText whether that family can be matched. One
    // gate for "not a font", "would not register" and "not installed".
    //
    // FILE-BACKED ON PURPOSE, measured 2026-08-16: descriptors created FROM
    // DATA carry no URL attribute, and RegisterFontDescriptors wants
    // file-backed descriptors — it handed back all seven of the variable font's
    // named instances and registered none of them (CTFontManagerError 303).
    // Writing the bytes to a temp file and registering the URL holds for static
    // AND variable fonts on both Apple platforms; the file must outlive the
    // registration, so it stays for the process's lifetime.
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
/// with, off the AppKit/UIKit text views in the on-screen hierarchy. NEVER THE
/// MODEL AND NEVER THE REQUEST — every font API on both Apple platforms renders
/// SOMETHING for a family it cannot match. These are the four reads the probe
/// measured on a real window (NSTextView.font, its typingAttributes, its
/// textStorage attributes, NSTextField.font).
///
/// THE VIEWS MUST AGREE: reporting the first one found would hide a lowering
/// that reached the textarea and not the field, so a disagreement is reported AS
/// a disagreement.
///
/// A BUTTON IS READ AT THE BUTTON, NOT AT ITS TITLE VIEW: measured, with the mac
/// button's font set to Georgia, the button reported `Georgia` and its inner
/// private NSButtonTextField reported `.AppleSystemUIFont` in the same walk.
/// EXCEPT NSPopUpButton, which `Picker(.menu)` is: the design leaves the popup's
/// own font alone and carries the swap on the option `Text` (measured, 0.0540
/// differing pixels against 0.0000 for the font on the Picker itself).
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
// ONE DECLARATION, TWO ROUTES (docs/app-identity-plan.md), and the difference
// is a MEASUREMENT rather than a schedule. macOS hands the picture to the Dock
// while the app runs. iOS has no runtime call that takes picture bytes at all —
// the whole SDK surface is supportsAlternateIcons/setAlternateIconName/
// alternateIconName, typed BOOL and NSString — so its identity is the BUNDLE's,
// written by tools/ios/run-sim.sh's make_bundle.

/// The four quadrant CENTRES of a decoded picture, as
/// `RRGGBB/RRGGBB/RRGGBB/RRGGBB` in reading order: top-left, top-right,
/// bottom-left, bottom-right.
///
/// THE CONTRACT IS THE WINUI ARM'S, VERBATIM (crates/kaya/src/winui/mod.rs's
/// `icon_quadrants`): the scene's expectation is ONE frozen string on every
/// lane. Centres and not corners, because whatever rescale a platform applies
/// blurs a quadrant BOUNDARY.
///
/// SIXTEEN BITS PER COMPONENT, AND THAT IS NOT BELT AND BRACES. MEASURED
/// 2026-08-18: `applicationIconImage` reads back as a 128x128, SIXTEEN-BIT
/// snapshot in the DISPLAY's ICC profile, so sampling means a colour conversion
/// back to sRGB — done into an EIGHT-bit context it quantizes twice and
/// reported `1D71D8` for a declared `1C71D8`. A 16-bit context and one rounding
/// at the end recovers all four exactly; truncating the high byte does NOT
/// (`F7D32C` for `F6D32D`). A display profile SMALLER than sRGB would clip
/// rather than round-trip; every display this has run against contains sRGB.
///
/// kayaWindowCaption is a window's EFFECTIVE caption: the title that window
/// declared, or the declared app identity's NAME when it declared none —
/// FILLING THE BLANK, NEVER OVERRIDING (tools/scenes/identity.steps), the same
/// rule the Windows backend spells. A WINDOW THAT DOES NOT EXIST HAS NO
/// CAPTION: without that guard `expect_title window#1` PASSED on iOS, where the
/// guest builds no auxiliary window at all.
func kayaWindowCaption(_ windowId: UInt64) -> String {
    guard let own = kayaScene.windows[windowId]?.title else { return "" }
    guard own.isEmpty, let name = kayaScene.appIdentityName, !name.isEmpty else {
        return own
    }
    return name
}

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
    /// I9). Three things happen here and each is measured:
    ///
    /// THE POLICY, a ratified behaviour change: `.accessory` — every lane leg's
    /// default — has NO DOCK TILE to put a picture in (measured: the setter
    /// succeeded, the read back showed a 512x512 image installed, and the Dock
    /// did not move one pixel), so an app that DECLARES an identity becomes
    /// `.regular`.
    ///
    /// THE ICON, from plain PNG bytes: `NSImage(data:)` then
    /// `applicationIconImage` replaces the Dock tile AND the Cmd-Tab tile, with
    /// no `.icns`. The tile is UNMASKED. Undecodable bytes leave the platform's
    /// own icon standing.
    ///
    /// THE NAME IS PARTIAL AND MUST NOT PRETEND OTHERWISE (I9).
    /// `NSApp.mainMenu`'s first item's title is the only runtime route; nothing
    /// moves the Cmd-Tab label or the Dock tile's AX title. `CFBundleName` must
    /// be injected before the first touch of `NSApplication.shared`, which is
    /// before the wire is open, so it is refused; `ProcessInfo.processName` is
    /// refused too, having moved the in-process API while the RENDERED menu bar
    /// kept the old name.
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
                // MEASURED, AND THE PLATFORM'S OWN ICON IS LEFT STANDING:
                // whether a blob is a picture is a question only this
                // platform's decoder can answer, and it just answered no.
                // Nothing is substituted — the read then reports whatever
                // AppKit is really holding.
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

    /// WHY THIS READ CANNOT REPORT QUADRANT SAMPLES, or nil when it can.
    ///
    /// EVERY ANSWER IS A SENTENCE THIS PROCESS WENT AND MEASURED (CLAUDE.md
    /// invariant 3, tools/check-diagnostics.sh), and the second one is the
    /// whole reason this function exists: reading `NSApp.applicationIconImage`
    /// back is NOT an echo — AppKit stores a re-rendered snapshot — but it
    /// STILL CANNOT TELL "stored" FROM "SHOWN". In the accessory arm this exact
    /// read reported a 512x512 image installed while the Dock had no tile at
    /// all (docs/app-identity-plan.md I8). The activation policy is the part of
    /// "shown" that IS measurable from in here, so it is measured and named;
    /// what is left unmeasurable is what the capture is for.
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

    /// WHY THIS READ CANNOT REPORT QUADRANT SAMPLES, or nil when it can.
    ///
    /// THE READ IS OF THE BUILT BUNDLE, and it is designed so that it CANNOT
    /// PASS VACUOUSLY. iOS has no runtime route to the Home Screen icon, so the
    /// artifact this platform's identity lives in is the bundle the app is
    /// running out of. Three separate states go RED and each names itself: an
    /// app that declared NO identity, a bundle that carries no icon, and a
    /// bundle whose icon is a different picture from the one the wire declared
    /// (ruling 4's byte-equality check).
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

private struct KayaButtonStyle: PrimitiveButtonStyle {
    let prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        if prominent {
            BorderedProminentButtonStyle().makeBody(configuration: configuration)
        } else {
            BorderedButtonStyle().makeBody(configuration: configuration)
        }
    }
}

/// THE IMAGE DECODE, in one function so the layout negative
/// (tools/check-empty-child.sh) drives the platform's real decoder and not a
/// copy of this arm. A failed decode — or a handle the pump never prefetched —
/// is the placeholder class, never a crash: the image slot goes nil and
/// `imageSize` reads "0x0", which is what the byte-frozen gallery scene asserts
/// on every platform.
///
/// MEASURED, because "undecodable" is not one thing. ImageIO is LENIENT: a PNG
/// truncated mid-IDAT and a PNG whose IDAT payload is clobbered both answer a
/// live 2x2 image here, while gdk-pixbuf refuses both and reads 0x0. Only bytes
/// with no recognisable container at all reach the nil arm on this platform,
/// which is why no scene can freeze an expectation on a HALF-valid image (see
/// docs/deferred.md).
func kayaDecodeImage(_ data: Data?, into node: KayaNode) {
    if let data, let image = KayaPlatformImage(data: data) {
        node.image = image
        node.imageSize = "\(Int(image.size.width))x\(Int(image.size.height))"
    } else {
        node.image = nil
        node.imageSize = "0x0"
    }
}

struct KayaRender: View {
    let node: KayaNode
    /// The mounted root fills its window; nested containers do not.
    var isRoot = false
    /// The MAIN AXIS of the flex container this node is a child of — true
    /// inside a column, false inside a row — and nil wherever grow has no
    /// meaning: a grid cell, a scroll's content, the mounted root, and the
    /// stock VStack/HStack path.
    ///
    /// A widget whose natural size is a FIXED FRAME needs this to honour grow:
    /// a grower's extent is the track KayaFlex assigned on this axis, and the
    /// widget can only release the right dimension if it knows which one that
    /// is. Releasing both would fill the CROSS axis too, which is align's
    /// business and not grow's.
    var flexVertical: Bool? = nil
    /// Whether that container aligns its children `stretch` — the CROSS axis's
    /// half of the question `flexVertical` answers for the main one. Only the
    /// widgets whose natural size is a fixed frame need it.
    var flexStretch = false

    var body: some View {
        // The widget/node anchor: a context catalog attached to this node rides
        // .contextMenu on its view — the platform's own gesture. Editable text
        // never reaches here (the root rejects the attach).
        //
        // The accessibility props ride EVERY kind, applied at the one place
        // every node's view passes through — containers included, so an
        // assistive client sees a labelled group and the harness can address
        // one. Empty means unset, and unset must stay untouched rather than
        // written as "": SwiftUI derives a control's label from its own content,
        // and stamping an empty label would SILENCE it.
        if kayaScene.contextRoots[node.id]?.isEmpty == false {
            kayaA11y(widget.contextMenu { KayaContextMenuItems(widgetId: node.id) }, node)
        } else {
            kayaA11y(widget, node)
        }
    }

    @ViewBuilder private var widget: some View {
        switch node.kind {
        case kindColumn:
            // Normalized: 8-unit spacing, leading (cross-axis start).
            //
            // VStack unless a child carries a weight OR this column must FILL
            // the box its parent handed it — the root's window, a stretch
            // cell, or a cross-oriented grow track (the 2026-08-22 ruling:
            // three backends impose the box natively and this one must be
            // told; the GAP entry beside dynamic-tables). A VStack returns
            // its natural size however large a frame it is offered, so
            // nothing below it would ever have leftover space to divide.
            let columnFills =
                isRoot || flexStretch || (node.grow > 0 && flexVertical == false)
            // A CROSSING container maximizes its main axis (height, in a
            // row parent) — the 2026-08-22 breadth ruling, the rule
            // WinUI's Stretch default carried alone until it was ratified
            // for all four. It rides a frame around the chosen body, not
            // the flex path: forcing the flex path was watched breaking
            // baseline mode (KayaCell places one child; a common baseline
            // is the stack's native gift).
            let columnCrosses = flexVertical == false
            Group {
                if !node.tableColumns.isEmpty {
                    // The declared table (docs/tables-plan.md);
                    // KayaTableSurface picks the tier. The row templates
                    // were held to the declared arity by the core.
                    KayaTableSurface(node: node)
                } else if columnFills || node.children.contains(where: { $0.grow > 0 }) {
                    KayaFlex(
                        vertical: true, spacing: node.spacing, nodes: node.children,
                        fillCross: columnFills
                    ) {
                        ForEach(node.children) { child in
                            // The cell fills the track KayaFlex proposes; the
                            // reader records the STRETCH FRAME's box when the
                            // mode is stretch (child breadth = content
                            // breadth, content top-leading like GTK's Fill)
                            // and the content's box otherwise; every other
                            // mode places in KayaCell.
                            KayaCell(vertical: true, align: node.align) {
                                KayaRender(
                                    node: child, flexVertical: true,
                                    flexStretch: node.align == alignStretch)
                                    // maxHeight: a grower renders AT its track,
                                    // leaf or container (the 2026-08-22 breadth
                                    // ruling's leaf half; grow.steps' label#1 and
                                    // button#0 were watched failing 23/109 and
                                    // 66/327 before this line).
                                    .frame(
                                        maxWidth: node.align == alignStretch ? .infinity : nil,
                                        maxHeight: child.grow > 0 ? .infinity : nil,
                                        alignment: .topLeading)
                                    .background(
                                        KayaCellReader(id: child.id, parent: node.id, vertical: true)
                                    )
                            }
                            .background(KayaTrackReader(id: child.id, vertical: true))
                        }
                    }
                } else {
                    VStack(alignment: kayaColumnAlignment(node.align), spacing: node.spacing) {
                        ForEach(node.children) { child in
                            KayaRender(
                                node: child, flexVertical: true,
                                flexStretch: node.align == alignStretch
                            )
                            // Frame BEFORE the reader, content top-leading:
                            // the old order recorded the hugged content
                            // centered inside the frame, and stretch
                            // classified center (watched failing 2026-08-22).
                            .frame(
                                maxWidth: node.align == alignStretch ? .infinity : nil,
                                alignment: .topLeading)
                            .background(
                                KayaCellReader(id: child.id, parent: node.id, vertical: true)
                            )
                        }
                    }
                }
            }
            .frame(maxHeight: columnCrosses ? .infinity : nil, alignment: .topLeading)
            .coordinateSpace(name: "kaya-box-\(node.id)")
            .background(KayaBoxReader(id: node.id, vertical: true))
            .background(KayaInsetReader(id: node.id, outer: false))
            .padding(node.inset)
            .background(KayaInsetReader(id: node.id, outer: true))
        case kindButton:
            // The dressed floor. macOS bridges to NSButton: in a process whose
            // main executable is stamped with a pre-26 SDK, SwiftUI's Button
            // lays out at borderless metrics while the AppKit bridge paints the
            // bezel over them — under EVERY style (automatic, bordered,
            // prominent all probed 38x20-vs-52x32, kaya-free) — and
            // vendor-hosted runtimes sit on such stamps permanently. iOS keeps
            // SwiftUI's Button: it measures what it draws.
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
                .buttonStyle(KayaButtonStyle(prominent: node.role == roleProminent))
                .alignmentGuide(.top) { d in
                    kayaBaselineOffsets[node.id] = d[.firstTextBaseline] - d[.top]
                    return d[.top]
                }
            #endif
        case kindRow:
            // Normalized: 8-unit spacing, top (cross-axis start).
            // HStack until a weight appears or this row must fill its box —
            // see the column arm.
            let rowFills =
                isRoot || flexStretch || (node.grow > 0 && flexVertical == true)
            // Crossing rows maximize their width — see the column arm.
            let rowCrosses = flexVertical == true
            Group {
                if rowFills || node.children.contains(where: { $0.grow > 0 }) {
                    KayaFlex(
                        vertical: false, spacing: node.spacing, nodes: node.children,
                        fillCross: rowFills
                    ) {
                        ForEach(node.children) { child in
                            KayaCell(vertical: false, align: node.align) {
                                KayaRender(
                                    node: child, flexVertical: false,
                                    flexStretch: node.align == alignStretch)
                                    // maxWidth: the leaf half of the breadth
                                    // ruling — see the column arm.
                                    .frame(
                                        maxWidth: child.grow > 0 ? .infinity : nil,
                                        maxHeight: node.align == alignStretch ? .infinity : nil,
                                        alignment: .topLeading)
                                    .background(
                                        KayaCellReader(id: child.id, parent: node.id, vertical: false)
                                    )
                            }
                            .background(KayaTrackReader(id: child.id, vertical: false))
                        }
                    }
                } else {
                    HStack(alignment: kayaRowAlignment(node.align), spacing: node.spacing) {
                        ForEach(node.children) { child in
                            KayaRender(
                                node: child, flexVertical: false,
                                flexStretch: node.align == alignStretch
                            )
                            // Frame before the reader — the column arm's
                            // stretch-classified-center fix, one axis over.
                            .frame(
                                maxHeight: node.align == alignStretch ? .infinity : nil,
                                alignment: .topLeading)
                            .background(
                                KayaCellReader(id: child.id, parent: node.id, vertical: false)
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: rowCrosses ? .infinity : nil, alignment: .topLeading)
            .coordinateSpace(name: "kaya-box-\(node.id)")
            .background(KayaBoxReader(id: node.id, vertical: false))
            .background(KayaInsetReader(id: node.id, outer: false))
            .padding(node.inset)
            .background(KayaInsetReader(id: node.id, outer: true))
        case kindLabel:
            // The heading role (docs/styling-plan.md D4) is BOTH facts at once:
            // the platform's heading TEXT STYLE (.headline — the scale's own
            // tier, never a raw size) and the AX heading trait, which is what
            // assistive users skim by.
            Text(node.text)
                // THE SWAPPED .headline, not the platform's: a text style set
                // here OVERRIDES the root font, so a heading in a branded app
                // would be the one label still in the system face (measured).
                // Non-headings pass nil and inherit the root's.
                .font(
                    node.role == roleHeading
                        ? (kayaBrandFont(.headline) ?? .headline) : nil)
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
                        node.checked = newValue
                        KayaHost.emitToggled(node.tag, newValue)
                    })
            )
            // The checkbox style is AppKit-only; iOS keeps the switch,
            // its native presentation of an on/off bit.
            #if os(macOS)
                .toggleStyle(.checkbox)
            #endif
            .alignmentGuide(.top) { d in
                kayaBaselineOffsets[node.id] = d[.firstTextBaseline] - d[.top]
                return d[.top]
            }
        case kindSlider:
            // Uncontrolled toward the app, the entry's shape: the node
            // mirrors the slider's position (SwiftUI needs the
            // binding), and every move is emitted with the slider's
            // identity tag.
            Slider(
                value: Binding(
                    get: { node.value },
                    set: { newValue in
                        node.value = newValue
                        KayaHost.emitValue(node.tag, newValue)
                    }),
                in: node.minValue...node.maxValue
            )
            // SwiftUI's Slider has no natural width — unconstrained it swallows
            // whatever a stack offers — so 200 stands in as the intrinsic size
            // every other toolkit's slider has. A grower must NOT keep that
            // cap: capping the drawn control below its track rendered a 1:3 row
            // as 38/62 while expect_shares (which reads the track) kept passing.
            .frame(maxWidth: node.grow > 0 ? .infinity : 200)
        case kindEntry:
            KayaEntry(node: node)
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
                        node.value = Double(newIndex)
                        KayaHost.emitValue(node.tag, Double(newIndex))
                    })
            ) {
                ForEach(Array(node.children.enumerated()), id: \.element.id) { index, option in
                    // ON THE OPTION TEXT, NOT ON THE PICKER. Measured both
                    // ways: the font on the option changes the rendering
                    // (0.0540 differing pixels), the font on the Picker changes
                    // nothing at all (0.0000) — it is an NSPopUpButton, and the
                    // AppKit-backed widgets are exactly the ones the root font
                    // does not reach.
                    Text(option.text).font(kayaBrandFont()).tag(index)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
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
                        node.value = Double(newIndex)
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
            // The vertical scroll viewport over its ONE child (the scene
            // enforces the count). ScrollViewReader's proxy is the REAL
            // scrolling API scroll_end drives; the geometry readers record
            // viewport, content, and the content's bottom edge in the
            // viewport's space.
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    if let content = node.children.first {
                        KayaRender(node: content)
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
                                kayaScrollProxies[node.id] = proxy
                            }
                            .onChange(of: g.size) { _, size in
                                node.scrollViewportH = size.height
                            }
                    }
                )
            }
        case kindImage:
            // Fixed to the decoded image's intrinsic size (no .resizable()),
            // matching the harness's size observation.
            //
            // A FAILED DECODE IS PRESENT AND EMPTY, NOT ABSENT. The placeholder
            // is a 0x0 view that still occupies the node's slot, which is what
            // the two widget backends have by construction. An `EmptyView` here
            // removed the node from the view tree entirely, and everything
            // above that counts children positionally then read the wrong
            // child: KayaCell trapped on `subviews[0]` (docs/deferred.md), and
            // the Compose grid's twin of this line shifted every later cell up.
            if let image = node.image {
                #if os(macOS)
                    Image(nsImage: image)
                #else
                    Image(uiImage: image)
                #endif
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        default:
            EmptyView()
        }
    }
}

// The entry's own view: it needs a @FocusState, which the recursive
// KayaRender switch cannot carry per-node.
#if os(macOS)
    /// The macOS button, bridged to AppKit directly instead of through
    /// SwiftUI's Button. In a process whose main executable is stamped with a
    /// pre-26 SDK — every non-Apple guest runtime — SwiftUI 26's compatibility
    /// path measures Button at its borderless metrics (38x20 for a 13pt
    /// caption) while drawing the bezeled control (52x32), and every container
    /// that consults sizeThatFits inherits the lie: the bezel overflows its
    /// slot and the caption truncates. An AppKit control cannot disagree with
    /// itself — fittingSize IS the drawn size. No style escapes the compat lie:
    /// automatic, bordered and borderedProminent all measure 38x20 there.
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
            // THE TYPEFACE'S PIPE INTO APPKIT, and it is the tint finding's
            // exact twin: an NSButton never reads SwiftUI's `.font` any more
            // than it reads `.tint`, so the root apply reached every SwiftUI
            // control and no mac button — measured, with "Save" and "Cancel"
            // left in SF in a window where everything else had swapped.
            // `button.font`, never `attributedTitle`: both change the pixels
            // identically, but after the attributedTitle route `button.font`
            // still reads the system font, so the honest read would lie.
            if let font = kayaPlatformFont(.body) { button.font = font }
            // THE BRAND'S ONE PIPE INTO APPKIT. This bridge exists for the
            // SDK-stamp bezel bug, and it took the brand out with it: an
            // NSButton never reads SwiftUI's `.tint` environment, so the root
            // tint reached every SwiftUI control and no mac button
            // (2026-08-12). The default-button bezel is the one accent surface
            // AppKit gives a button, so the PROMINENT role carries the brand
            // fill here, per appearance and re-resolved on appearance change (a
            // color computed once at update would go stale on a dark flip).
            // Brandless stays nil: the system paints its own accent.
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
        KayaHost.emitEntryPopped(top.id)
    }
}

// --- Menus: the command vocabulary (DESIGN.md, Menus) ---------------
//
// One item vocabulary, two anchors. The WINDOW anchor rides the window model
// (menubar); macOS materializes the key kaya window's catalog as a Kaya-owned
// native NSMenu segment (SwiftUI's pinned CommandsBuilder has no buildArray, so
// it cannot express append-at-any-time top-level catalogs), while iOS folds the
// catalog into a trailing More menu with promoted primaries as real bar
// actions. The WIDGET/NODE anchor is .contextMenu on the anchored node's view.
// Echo doctrine: ONE dispatch path — user chrome, shortcuts and harness verbs
// land in kayaMenuUserActivate and emit; programmatic set_menu_prop writes
// mutate the model silently in the apply arm.

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

/// Whether a clipboard role's command can act right now. A non-role item
/// answers true and pays nothing.
///
/// Paste is the INTERSECTION: something focused that takes content, and
/// something on the clipboard it takes. Cut and copy need only a focused widget
/// that HAS a selection to give.
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
        // THE SAME INTERSECTION, asked in this platform's vocabulary. Every
        // question here is prompt-free (types, hasStrings — §8 finding 2),
        // which is what lets enablement be computed LIVE: this runs inside a
        // SwiftUI body evaluation and inside every harness activation, and a
        // version that could raise the paste alert would raise it while the
        // user was merely looking at a menu.
        switch role {
        case "undo":
            // A4 again, and the same rule: enablement IS the routing answer,
            // asked live. The phone's read path answers from the model, which
            // calls straight through to here, so this platform never had the
            // mac's stale-enablement problem — there is no NSMenuItem holding a
            // state it was born with.
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
/// came up empty — AND the door where a paste's board is witnessed
/// (kayaClipWitness, first line of the body).
///
/// A disabled role item is INERT, exactly as native chrome leaves a greyed one.
/// For a person that needs no words. For a scene it is SILENT: `menu_activate
/// "Edit>Paste"` reports success, nothing is emitted, and the failure surfaces
/// seconds later as a label that still reads what it read before. That is the
/// 2026-08-04 matrix failure — a foreign image clip replaced the seeded text
/// 25ms after the seed settled (docs/traps.md).
func kayaRoleInertNote(_ item: KayaMenuItemModel, verb: String) {
    // AND THE WITNESS FIRST, before the enablement question, because a paste
    // whose staged content was replaced is usually DISABLED — nothing the
    // focused widget accepts is on the board any more — and every route past
    // this point turns a disabled item away without touching the clipboard. On
    // macOS the harness's dispatch is the REAL NSMenuItem's action, so kaya
    // gets no say once AppKit has greyed it.
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


/// ONE LINE WHEN AN UNDO ACTIVATION WAS INERT, naming WHICH of the three ways
/// it can be.
///
/// The inert-paste precedent, in A6's spirit. An undo has one more way to do
/// nothing than a paste does, and they are indistinguishable from outside: the
/// app disabled the item, a grouping ancestor disabled it, or both tiers came
/// up empty. It matters more here than for the clipboard because of A6's
/// protocol gap: a native-tier undo is byte-identical to typing on the wire, so
/// "the undo did nothing" and "the undo happened" already look alike to an app.
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
//
// TWO TIERS, ONE SURFACE (docs/undo-plan.md D1): text-local undo DELEGATES to
// the platform's own stacks the way cut/copy/paste do; app-state undo is the
// core's ledger.
//
// THE TWO MANAGERS, measured (§1.2) and invisible from the SwiftUI source: a
// kaya ENTRY is an NSTextField edited through the window's FIELD EDITOR, whose
// undoManager is a private NSCellUndoManager; a kaya TEXTAREA is an NSTextView
// whose undoManager resolves to the WINDOW's. `firstResponder.undoManager`
// picks the right one without this layer knowing which kind is focused.
//
// AND THE DEFECT THIS FIXES IS LIVE TODAY: a programmatic write into a FOCUSED
// entry REGISTERS an undo action and JOINS the open "Typing" group, so one
// Cmd+Z throws away the user's typing AND the app's write together.

#if os(macOS)
    /// How long the clear waits for SwiftUI to push a written value into the
    /// AppKit control before giving up on proving it: main-queue turns, 1ms
    /// apart, so a wedged sync reports rather than hangs.
    private let kayaUndoSyncTurns = 240

    /// The AppKit text object serving what is focused — the entry's field editor
    /// or the textarea's NSTextView — or nil when nothing editable is focused.
    /// Scoped to one window when the caller knows which; across kaya's windows
    /// otherwise, since a widget-to-window map exists in neither this layer nor
    /// the core.
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

    /// The same window, WAITED FOR.
    ///
    /// kaya's focus is a model fact the instant the focus command applies, and
    /// `expect_focused` reads that model — but AppKit installs the window's
    /// field editor a render later, and a leg runs in a process that is not the
    /// active application. So the step before a `type` can pass while the
    /// platform still has nowhere to send a key. Measured: the same leg typed
    /// fine on one run and found no window on the next, 14ms after the window
    /// registered.
    ///
    /// Bounded by the same budget as the undo clear, and NOT by activating the
    /// process: `NSApp.activate` would take the user's focus and, under a
    /// five-lane matrix, whichever leg happened to be typing.
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
    /// NSApp.sendEvent — the same path a hardware key takes into the app, and
    /// the one already measured filling the native undo stack.
    ///
    /// IN-PROCESS ON PURPOSE. CGEvent posting into the HID stream would type at
    /// whatever is frontmost, which under a five-lane matrix is rarely this
    /// process, and it charges the accessibility permission besides.
    ///
    /// ONE EVENT PER CHARACTER, with the toolkit given a turn between them: the
    /// contract says the characters arrive as separate key events in order and
    /// each one emits the ordinary text_changed the core banks from.
    func kayaTypeAtFocus(_ text: String) -> Bool {
        guard let window = kayaAwaitTextWindow() else { return false }
        let before = DispatchQueue.main.sync { () -> String? in
            // CONTRACT POINT 3: TYPING APPENDS. macOS SELECTS a field's whole
            // contents when it becomes first responder, so keys arriving at the
            // selection REPLACE what is there — the same script would append on
            // a lane whose platform leaves the caret at the end and replace on
            // this one, and one script is compared byte-for-byte across all
            // five (invariant 6). So the caret goes to the end first.
            //
            // Before the keys and not between them: a selection change mid-run
            // would break the field editor's own coalescing.
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

    /// Contract point 4: block until the typed text has LANDED.
    ///
    /// An action is never retried, and the step after a `type` is usually
    /// `menu_activate "Edit>Undo"` — an action too, with no retry cover — so a
    /// keystroke still in flight would read as a broken undo rather than as a
    /// missed key. Waits for the model the app sees to MOVE and then hold still.
    ///
    /// A timeout is not a verdict: nothing focused is a legitimate state under
    /// this verb's contract, so this reports and returns rather than failing.
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
    //
    // EVERY CELL OF §1.3 DIVERGES FROM THE MAC, mechanically, and this arm
    // re-measured every load-bearing cell against THIS interpreter:
    //
    // - BOTH text kinds carry a PRIVATE `_UITextUndoManager` and the window's
    //   manager is never in play, so the focused text's own stack is the only
    //   one any affordance here can reach — shake-to-undo included, which is ON
    //   by default. A6's consequence: the core tier is invisible to shake.
    // - `undo:` down the responder chain performs the focused field's undo and
    //   NEVER FALLS THROUGH, so D6's routing is HAND-WRITTEN here and the route
    //   is asked BEFORE the send.
    // - `canPerformAction(undo:)` answers FALSE while undo works, so A4's query
    //   reads `undoManager?.canUndo` instead.
    // - D7 IS FREE: a programmatic write registers nothing and clears the
    //   field's stack by itself, both kinds. An explicit `removeAllActions()` is
    //   a MEASURED NO-OP, so this arm ASSERTS the rule rather than performing it.
    // - A1's clear is NOT free: an iOS field's history SURVIVES a focus round
    //   trip (measured; on macOS the field editor takes it with it), so a core
    //   group committing while a field is focused has to clear that field's
    //   stack EXPLICITLY.

    /// The turn budget this half spends waiting for UIKit to catch up with a
    /// model write: main-queue turns a millisecond apart, so a wedged sync
    /// reports rather than hangs. Same number and reasoning as the macOS
    /// constant of this name; they are in mutually exclusive branches.
    private let kayaUndoSyncTurns = 240

    /// Q2's ledger-quiet bracket, IN THIS PLATFORM'S TIMING — and the timing is
    /// the whole reason it is a scope here and a text match there.
    ///
    /// A native undo DOES reach kaya's model on this platform — UIKit's undo is
    /// an ordinary text replacement, so SwiftUI's binding setter runs, the node
    /// is written and the ordinary `text_changed` is emitted — and it does so
    /// SYNCHRONOUSLY INSIDE `sendAction`, before this backend can take its
    /// sample. The mac arm's bracket records the sampled TEXT and lets the
    /// emission a runloop turn later consume it; here that emission has gone.
    ///
    /// AND THE TEXT BRACKET MUST NOT BE USED HERE AS WELL. A record written
    /// after the edit it was meant to silence is never consumed, and it would
    /// sit in the table silencing the NEXT edit that happened to reach the same
    /// string — a corruption, not a miss.
    var kayaRoutedNativeUndoDepth = 0

    /// Perform the platform's own undo (or redo) with the bracket held open
    /// across it, so the edit it provokes is banked ONCE — by
    /// `kayaNoteNativeUndo`'s sample, with this interpreter's emission quiet.
    func kayaSendBracketedNativeUndo(_ selector: Selector) {
        kayaRoutedNativeUndoDepth += 1
        kayaSendToFocusedResponder(selector)
        kayaRoutedNativeUndoDepth -= 1
    }

    /// The view holding keyboard focus.
    ///
    /// A WALK RATHER THAN AN API, because there is no API: UIKit names no first
    /// responder, and the `sendAction`-capture trick answers with a responder
    /// that may not be a view. The walk is public API and cheap — a kaya scene's
    /// view tree is small and this runs on activation, not per frame.
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

    /// The same, WAITED FOR — the phone's version of `kayaAwaitTextWindow`,
    /// guarding the identical trap: kaya's focus is a model fact the instant
    /// the focus command applies, while UIKit makes the control first responder
    /// a render later, so a `type` step in between would report "nothing
    /// focused" for a scene that did everything right.
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

    /// The `type` verb's iOS half (harness.rs `Stage::type_text`, A8).
    ///
    /// POINT 1 IS SPELLED `insertText`, AND THAT IS THE ONE DEVIATION IN THIS
    /// ARM. The contract names a real key event per platform, and iOS is not in
    /// that list because it has none: UIKit exposes no way to construct or post
    /// a `UIPressesEvent`, `simctl` has no typing verb, and driving
    /// Simulator.app through System Events would type at whatever is frontmost.
    ///
    /// `insertText(_:)` is `UIKeyInput`'s method — the one UIKit's OWN keyboard
    /// calls for a pressed key — so it is the platform's text input path and
    /// not a text write. What the contract BUYS with point 1 was measured here
    /// rather than assumed: each character fills the field's native undo stack
    /// exactly as a user's typing fills it, and each emits the ordinary
    /// `text_changed`. Only the COALESCING differs, and point 5 hands
    /// granularity to the platform explicitly.
    func kayaTypeAtFocus(_ text: String) -> Bool {
        guard let input = kayaAwaitFocusedTextInput() else { return false }
        let before = DispatchQueue.main.sync { () -> String? in
            // CONTRACT POINT 3: TYPING APPENDS. iOS is gentler than macOS here
            // — becoming first responder does not select the whole contents —
            // but one script is compared byte-for-byte on all five lanes, so
            // the caret goes to the end with nothing selected, explicitly.
            // Before the keys and not between them: a selection change mid-run
            // breaks the field's own coalescing.
            if let end = input.textRange(from: input.endOfDocument, to: input.endOfDocument) {
                input.selectedTextRange = end
            }
            return kayaScene.focusedId.flatMap { kayaScene.nodes[$0]?.text }
        }
        for ch in text {
            let sent = DispatchQueue.main.sync { () -> Bool in
                // UITextInput REFINES UIKeyInput, so the control that
                // holds the caret is by construction the one that takes
                // a keystroke — no cast, no optional path to get wrong.
                input.insertText(String(ch))
                return true
            }
            if !sent { return false }
            Thread.sleep(forTimeInterval: 0.001)
        }
        kayaSettleTypedText(from: before)
        return true
    }

    /// Contract point 4: block until the typed text has LANDED.
    ///
    /// The mac arm's reasoning, unchanged, because the hazard is not
    /// platform-specific: an action is never retried, and the step after a
    /// `type` is usually another action with no retry cover, so a keystroke
    /// still in flight reads as a broken undo rather than a missed key.
    ///
    /// A timeout is not a verdict: nothing focused is a legitimate state under
    /// this verb's contract, so this reports and returns.
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

    /// D7's ASSERTION, which on this platform replaces D7's mechanism.
    ///
    /// A programmatic write was measured to clear the field's native history by
    /// itself, so there is nothing here to perform — and a `removeAllActions()`
    /// written anyway would be indistinguishable from the platform doing it,
    /// which means a UIKit regression would pass silently and the corrupting
    /// case (a Cmd+Z that reverts the APP's write) would ship green.
    ///
    /// ON THE FAR SIDE OF THE RENDER, for the mac arm's reason: a kaya write is
    /// `node.text = …` on an @Observable class, and SwiftUI pushes it into
    /// UIKit a later runloop turn. Asked at the model write, this would read the
    /// stack as it was BEFORE the write.
    ///
    /// And if the assertion ever fails, the rule still wins: it clears
    /// explicitly and says so.
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

    /// A1's clear, which on this platform is NOT free.
    ///
    /// D7's freebie covers a programmatic WRITE; A1 fires when a core group
    /// commits with a field focused and nothing wrote that field at all. On
    /// macOS the field editor loses its history anyway; here the field keeps it
    /// across focus changes (measured), so without this call the field's stack
    /// would still hold typing from BEFORE the group — and "ask the focused text
    /// first" would take back that older typing ahead of the group, which is
    /// precisely the interleave §3 exists to make unconstructible.
    ///
    /// MEASURED EFFECTIVE, which the probe could not establish: its only clear
    /// followed a write that had already emptied the stack. Live, on the
    /// private manager, the star group's commit read canUndo true going in and
    /// false coming out.
    func kayaClearFocusedNativeUndo() {
        kayaFocusedTextInput()?.undoManager?.removeAllActions()
    }
#endif

/// Which surface's ledger a widget's typing belongs to (§3: one ledger per
/// window).
///
/// THE CORE CANNOT ANSWER THIS and this layer can, which is why the window
/// rides the edit emission: a scene keeps no widget-to-window map, while the
/// interpreter is literally rendering the widget inside a surface. The walk is
/// the parent chain to a mounted root and then the surface holding it.
///
/// The primary is the answer for a widget with no mounted root above it:
/// window 0 always exists, and an episode banked there is at worst coarse.
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

/// The ledger-quiet bracket around a native undo this backend ROUTED (§3):
/// field id -> the text the walk left in the widget, recorded when the sample
/// was taken.
///
/// A BRACKET AND NOT A FLAG-WITH-A-TIMER, because the two reports of one native
/// undo are not adjacent in time: kayaNoteNativeUndo samples the AppKit control
/// the instant `undo:` returns, and SwiftUI pushes the same text through the
/// binding a runloop turn LATER. Matching on the text the sample saw is exact,
/// needs no clock, and self-clears.
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
        // (kayaRoutedNativeUndoDepth carries the measurement). Same rule in
        // both places; the two spellings are the two platforms' delivery
        // orders, not two policies.
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
        // THE SAME QUESTION, and NOT the one the platform offers to answer:
        // `canPerformAction(undo:)` on the focused responder was measured FALSE
        // while undo demonstrably worked (§1.3), so asking UIKit's own
        // enablement oracle here would ship a permanently greyed Edit>Undo. The
        // manager is asked directly instead.
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

/// D7/A1's clear, ON THE FAR SIDE OF THE RENDER.
///
/// THE TRAP THIS FUNCTION IS SHAPED AROUND (§1.2, measured): a clear timed to
/// the MODEL write is undone by the render that follows it. A kaya programmatic
/// write is `node.text = …` on an @Observable class — no AppKit call at all —
/// and SwiftUI pushes the value into the AppKit control on a LATER runloop
/// turn. That push is what registers the undo action, so a clear that runs
/// first clears an empty stack.
///
/// So the clear waits until the control PROVABLY shows the text that was
/// written, and only then removes the actions. A clear on the wrong side of the
/// render passes any test that only checks the TEXT, which is why the negative
/// test types, KEEPS focus, writes, and asserts canUndo == false.
func kayaClearNativeUndo(in window: UInt64? = nil, expecting text: String, tries: Int = 0) {
    #if os(macOS)
        // Nothing editable focused: an unfocused write registers
        // nothing (measured), so there is no history and no retry.
        guard let responder = kayaFocusedTextResponder(in: window) else { return }
        if responder.string != text {
            // SUPERSEDED: the model has moved past the write this clear
            // belongs to — a second write in the same batch, say — so the
            // control will never show `text` and the later write's own clear
            // covers the field. Both callers' expectation IS the focused node's
            // model text.
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

/// D7 + A3 at the quiet-write sites: a programmatic write to a text widget
/// resets THAT widget's native undo history — but only when the write CHANGED
/// the text (A3), and only when the widget is the focused one.
///
/// A3 is not tidiness: an app that mirrors a field's text into a signal and
/// writes it back would otherwise lose native undo on every keystroke.
///
/// THE FOCUS GUARD IS CORRECTNESS, twice over. An unfocused write registers
/// nothing (measured), and the clear resolves the FOCUSED responder, so a clear
/// fired for a background field would destroy the history of the field the user
/// is typing in.
///
/// Called from the apply arms rather than the two writing sites, so an inverse
/// the CORE writes travels the same path a forward write does.
///
/// THE PHONES ARE MEASURED NOT TO NEED IT (§1.3): UIKit discards the field's
/// undo history itself when text is set programmatically. The guard for that is
/// an assertion that `canUndo == false` after a write, never a silent
/// `removeAllActions()` — which would make a UIKit regression unobservable.
func kayaNoteQuietTextWrite(_ id: UInt64, from previous: String, to next: String) {
    guard previous != next else { return }
    guard kayaScene.focusedId == id else { return }
    #if os(macOS)
        kayaClearNativeUndo(expecting: next)
    #else
        kayaAssertNativeUndoCleared(expecting: next)
    #endif
}

/// A1: a core undo group committed, so the focused editable's native history
/// goes with it (the episode was banked before the clear, so nothing is lost
/// but granularity).
///
/// This is the keystone (§3): every episode begins with an EMPTY native stack,
/// so the native stack can never reach past the current episode's start, and
/// the interleave the literature calls selective undo becomes unconstructible.
func kayaClearUndoForGroup(_ window: UInt64) {
    #if os(macOS)
        // The expectation is the focused node's model text: once the control
        // shows it, the render that would have re-registered has happened.
        let expected = kayaScene.focusedId.flatMap { kayaScene.nodes[$0]?.text } ?? ""
        kayaClearNativeUndo(in: window, expecting: expected)
    #else
        // NO RENDER TO WAIT FOR HERE, and that is the difference from the write
        // path rather than an omission: a group commit does not write this
        // field, so there is no value in flight a later push could re-register
        // behind the clear. What there IS on this platform is a history that
        // would otherwise SURVIVE (measured — an iOS field keeps its stack
        // across a focus round trip), which is why the phone cannot take A1 for
        // free the way it takes D7.
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

/// Where an undo would go RIGHT NOW.
///
/// ASKED ONCE AND USED TWICE — enablement and activation are the same question
/// (D6), and `nothing` IS what a disabled Edit>Undo means. Two expressions of
/// it would drift, which is A4's whole point.
///
/// AND THE ANSWER IS THE CORE'S, not this layer's. What the backend contributes
/// is the pair only it can see — what is focused, and whether that field's own
/// stack has anything — and the ledger decides against them.
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
    /// Which window's ledger an undo activation belongs to.
    ///
    /// macOS asks `kayaPresentedMenuWindow` — the key window, which is what its
    /// global menu bar is showing. This platform has no such variable, so the
    /// activation asks the same question the EMISSION asks: the window whose
    /// ledger this field's typing was banked into. Falling back to the primary
    /// is the same answer `kayaWindowOf` gives for an unmounted widget.
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

/// Perform an undo/redo role on the focused surface. Answers whether it WAS
/// one, so a plain action falls through to its own dispatch — a role item is the
/// PLATFORM's command, not the app's action.
///
/// ROUTING (D6/§3): the focused text answers first when its own stack has
/// something, and the core's ledger answers otherwise. On this platform the
/// first half is free — `undo:` sent at the first responder travels AppKit's own
/// resolution, measured to implement the ratified routing INCLUDING the
/// fall-through. The focused-CanUndo test in front of it is A4's query, and
/// under A1's clear it agrees with the core's `route_undo` by construction.
///
/// windowWillReturnUndoManager is DELIBERATELY not implemented: it was measured
/// to capture none of the entry's typing while merging a textarea's typing with
/// anything kaya registered into ONE undo step.
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
        // THE TWO-STEP, HAND-WRITTEN. §1.3 measured that `undo:` reaches the
        // focused field's private manager and STOPS: with the field's own stack
        // empty the send is simply refused, and nothing else is ever reached.
        // So the ROUTE decides first and the send happens only on `.native` —
        // here it is also the only thing standing between a core-tier step and
        // silence.
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

/// THE RECONCILIATION SAMPLE (§3): what a NATIVE undo left behind.
///
/// The core walks its frontier episode backwards from three facts — the field,
/// the text the walk landed on, and whether the field can still undo. The
/// backend's job is to take the sample at the one moment it is true, immediately
/// after the responder performed the undo, from the AppKit control rather than
/// from the model (SwiftUI syncs the model a turn later).
///
/// AND ON THIS PLATFORM THE SAMPLE IS ALSO HOW ANYONE ELSE FINDS OUT. MEASURED,
/// and it overturns a premise §0 states for every backend: "a native undo emits
/// the ordinary text_changed". Through a SwiftUI TextField it does not — the
/// undo runs on the field editor's own NSCellUndoManager and rewrites the
/// editor's storage directly, bypassing the binding's setter:
///
///     undo took=true resp=_SystemTextFieldFieldEditor mgr=NSCellUndoManager
///     text teas->tea canUndo true->false model teas->teas
///     +50ms text=tea model=teas
///
/// So this backend reports the change itself: the node's text, the app (through
/// the ordinary text_changed emission), and the ledger through
/// `note_native_undo` — ONCE, the emission being bracketed LEDGER-QUIET with the
/// sampled text.
///
/// THE THIRD FACT IS `canUndo` IN BOTH DIRECTIONS: it is the core's test for the
/// case A1's clear is meant to make unreachable, a platform that coalesced
/// ACROSS the episode's start. A redo reporting `canRedo` there would answer
/// false at the end of a forward walk and send the core backwards.
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
        node.text = text
        kayaNoteNativeUndoEcho(field, text)
        let utf8 = Array(text.utf8)
        utf8.withUnsafeBufferPointer { s in
            KayaHost.api.note_native_undo(
                window, field, s.baseAddress, UInt(s.count), canUndo ? 1 : 0)
        }
        KayaHost.emitText(node, text)
    #else
        // ONE CHANNEL LEFT, NOT THREE — and §3a is why that is a measurement
        // rather than a shortcut. Asked here the way the amendment demands,
        // this platform answered YES: UIKit's undo is an ordinary text
        // replacement on the UITextField, so SwiftUI's binding setter ran, the
        // node was written and the ordinary `text_changed` was emitted before
        // this line was reached (`text="tea" model="tea"` at the instant `undo:`
        // returned, where the mac's model was still "teas" fifty milliseconds
        // later).
        //
        // NOT WRITING THE NODE IS DELIBERATE: the mac arm must write it or the
        // next render pushes the stale model back into the control; here the
        // model already holds the undone text, and a second write would at best
        // be a no-op and at worst race the binding.
        //
        // What remains is the LEDGER, once — Q2's one-reporter rule, with the
        // two platforms differing only in which report they suppress.
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

/// The CORE tier: routing cases 2 and 3 (§3) — the ledger's newest entry is a
/// group, or an episode that is no longer frontier-live, and the core applies
/// the inverse itself.
///
/// NOTHING COMES BACK, and that is the shape rather than an omission. Applying
/// the inverse produces ordinary apply records, which reach this interpreter
/// through the pump; the app hears one `undone` carrying the whole restored
/// state. This layer keeps no copy of the ledger to disagree with.
func kayaCoreUndo(_ window: UInt64) {
    KayaHost.api.undo(window)
}

/// Redo's twin, symmetric in every respect (the forward delta was
/// computed at apply beside the inverse, so nothing is re-run).
func kayaCoreRedo(_ window: UInt64) {
    KayaHost.api.redo(window)
}

/// Send a standard editing command down the responder chain, starting at the
/// FOCUSED window's first responder rather than at the application.
///
/// NOT `NSApp.sendAction(to: nil)`, which was the first cut and never once
/// worked: that route starts at the KEY window, and a leg running eight wide
/// beside seven others is rarely the frontmost app — so it found no responder,
/// returned false, and the paste vanished with no error. Making the app key
/// instead would have fixed it by stealing focus from every sibling leg. A
/// window's first responder exists whether or not the window is key.
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
    // NOBODY TOOK IT, and this was swallowed even though the callsite's own
    // comment claimed otherwise: a command that reached no responder looks
    // exactly like a widget that ignored the content, and the scene reports a
    // field that simply stayed empty. A paste sent while the platform's focus is
    // still catching up with kaya's is precisely this, and it is intermittent.
    let note =
        "KAYA_CLIP_TRACE: \(selector) reached no responder that would take it — kaya's "
        + "focus is node \(kayaScene.focusedId.map(String.init) ?? "nowhere"), and the "
        + "platform offers [\(offered.joined(separator: ", "))]\n"
    FileHandle.standardError.write(Data(note.utf8))
    return false
}

/// Perform a clipboard role on the focused widget. Answers whether it WAS one,
/// so a plain action falls through to its own dispatch.
///
/// THE PASTE SPLIT, and it is the rule the whole gesture layer turns on: a
/// widget that DECLARED what it accepts takes the content itself — kaya reads
/// the clipboard and delivers it to the paste hook — while one that declared
/// nothing gets the platform's own insertion, and its change handler reports the
/// result. A plain text editor writes none of this and works.
func kayaPerformClipboardRole(_ role: String) -> Bool {
    #if os(macOS)
        switch role {
        case "cut", "copy":
            // A NATIVE CUT OR COPY IS A WRITE THIS LEG ASKED FOR, so it stages
            // like any other: the responder puts the selection on the board and
            // the count it leaves is the one the witness measures against.
            // Missing this is how the guard would report a foreign writer for an
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
                // THE PLATFORM'S OWN INSERTION, down the responder chain from
                // whatever is focused. It answers whether anything took it, and
                // a refusal is reported rather than swallowed: a paste that
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
            // The same stage the macOS arm opens, for the same reason.
            //
            // NOT COMPOSED BY KAYA, and that is a real limit rather than a
            // formality: UIKit builds this clip down the responder chain, so it
            // carries no marker, and on this platform the marker is the only
            // evidence there is — the witness stands down until kaya composes
            // the next clip. KAYA WILL NOT STAMP A BOARD IT DID NOT COMPOSE to
            // close that hole: a responder that refused leaves the PREVIOUS clip
            // in place, which may be a stranger's, and stamping it would be a
            // false OK. No scene reaches this arm today, so the alternative
            // would also be an unwatched branch.
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
                // THE PLATFORM'S OWN INSERTION, down the responder chain.
                //
                // ONE MAIN-QUEUE TURN OUT, and pressed for: UIKit's paste
                // implementation reads the pasteboard itself, and a command kaya
                // dispatched is not the system's exempt paste affordance, so the
                // per-clip prompt can land in the middle of the send. Sent
                // synchronously it would park the main thread AND the harness
                // thread waiting on it, with nobody left to answer the alert.
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
/// re-synchronize the owned NSMenu segment (a rebuild always starts from the
/// post-user mirror). The macOS rebuild hops ONE main-queue turn: a toggle/radio
/// fire runs inside AppKit's performActionForItem on the very menu the rebuild
/// would mutate.
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
/// item's REAL icon carries.
///
/// macOS reads it off the materialized NSMenuItem's image
/// accessibilityDescription — the item AppKit will actually draw, not kaya's
/// model — so an arm that decoded the prop and never built an image must fail.
///
/// iOS answers in TWO HALVES, decided by what RENDERED and never by the props.
/// THE RENDERED HALF: an item the promoted bar is carrying is a REAL BAR BUTTON,
/// and this asks UIKit's own objects what it is drawing, through the shared
/// kayaToolbarIOSSymbolOf, so expect_toolbar_item and this verb cannot disagree.
/// THE UNRENDERED HALF: an unpromoted item, and every item on a regular-width
/// window, where UIMenu elements are rebuilt on demand and kaya keeps no handle.
/// That half answers with what it CAN measure — the SF name the lowering would
/// use, and the semantic name only if UIImage(systemName:) really produces an
/// image on this OS — and does NOT claim any menu was built.
///
/// TOTAL, like kayaMenuStateRead: every failure is a short description and a
/// retryable non-match, never a panic.
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
            // THE TOOLBAR VERB'S READ, CALLED — not copied. The address, the
            // automation switch, the trace, the outermost-button walk, the glyph
            // and the sentences for a missing bar are all one implementation, so
            // a promoted item cannot read one way through expect_toolbar_item
            // and another through here.
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

/// The invariant the BARE expect_toolbar step asserts, over a backend's
/// `<in the real chrome>/<promoted in the catalog>/<remainder's home>` reading:
/// the promoted set really reached the chrome, and the remainder has somewhere
/// to live. Mirrored from harness.rs's `toolbar_chrome_fits` sentence for
/// sentence — this interpreter is string-matched rather than compile-checked.
/// nil means it fits; the failure NAMES THE MEASURED NUMBERS, because the pass
/// observation cannot.
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
    /// catalog>/<items on the bar>/<remainder's home>`.
    ///
    /// The first number walks the REAL NSToolbar's items IN ORDER against the
    /// promoted list's labels — promotion is catalog preorder, and a bar holding
    /// the right set in the wrong sequence is not the same lowering. The second
    /// is the promoted list itself; they come from two different sides so the
    /// answer cannot agree with itself.
    ///
    /// The THIRD number is what lets the failure discriminate, and a watched
    /// negative is why: with the symbol arm perturbed off, the promoted buttons
    /// drew bare `Text`, AppKit lifted NO label onto either NSToolbarItem
    /// (measured — a title reaches `NSToolbarItem.label` from
    /// `Label(_:systemImage:)` and not from a bare `Text`), and "reached no
    /// toolbar" was printed for a window with a two-item toolbar.
    ///
    /// The remainder's home on macOS is the MENU BAR, and this checks the
    /// kaya-owned segment is really there rather than asserting it.
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
    /// button, addressed by the label AppKit lifted onto it.
    ///
    /// ENABLEMENT IS NOT `NSToolbarItem.isEnabled`, and that is measured rather
    /// than assumed: SwiftUI hosts the button inside a `ToolbarItemHostingView`
    /// and never writes AppKit's flag, so it reads `true` for a visibly disabled
    /// button (measured 2026-08-16, and again by this slice's own probe). The
    /// read consults the accessibility tree — the same AXUIElement client route
    /// `expect_ax` uses — where the disable really lands.
    ///
    /// TOTAL, like kayaMenuStateRead: every failure is a short description and a
    /// retryable non-match, never a panic.
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
            // THE MEASURED PROPERTY. `NSToolbarItem.isEnabled` is NOT it: in
            // the same trace block where this attribute reads false for the
            // disabled button, AppKit's own flag reads true for it AND for the
            // untouched control item beside it (KAYA_TOOLBAR_TRACE, 2026-08-17).
            // The accessibility tree is where SwiftUI's `.disabled` lands.
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
        /// Enablement from the `notEnabled` trait on the BUTTON element.
        /// Measured to move — 1 (button) before the scene's disable and 257
        /// (button|notEnabled) after it — while the nested `_UIModernBarButton`
        /// reads 257 throughout, which is why this is taken off the outermost
        /// button and the walk does not descend into one.
        let enabled: Bool
    }

    /// EVERY BAR BUTTON THE REAL CHROME IS SHOWING, in the order an assistive
    /// client meets them (measured left to right). Order matters — promotion is
    /// catalog PREORDER and a bar holding the right set in the wrong sequence is
    /// not the same lowering.
    ///
    /// THE ROUTE IS MEASURED, NOT ASSUMED, and it is not the macOS one.
    /// SwiftUI's `UIKitNavigationBar` on this OS publishes NO bar button items
    /// whatsoever — `topItem` is nil and `rightBarButtonItems` with it (measured
    /// 2026-08-17) — because `.toolbar` content is hosted as views inside the
    /// bar rather than bridged through `UINavigationItem`. So the walk is the
    /// accessibility tree under the bar.
    ///
    /// OUTERMOST BUTTONS ONLY: `_UIButtonBarButton` wraps a
    /// `_UIModernBarButton` that also carries the button trait, and the inner
    /// one reports `notEnabled` even while the button is live.
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
        // THE RENDERED GLYPH. UIKit publishes the SF symbol name on the image
        // view it built for the glyph (`ident=checkmark` under the Save button,
        // `ident=magnifyingglass` under Find — measured), so this is the
        // platform's own record of what is on screen. A button that fell to its
        // text arm has no image view here at all.
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
    /// the one table the lowering drew through. nil when no row of this
    /// interpreter's table resolves to that glyph.
    ///
    /// TWO SPELLINGS PER ROW, because the name kaya asks for is not always the
    /// name that renders: SwiftUI resolves an aliased SF name to its canonical
    /// one before UIKit builds the image, so the bar publishes
    /// `document.on.document` for the `doc.on.doc` this table ships (measured on
    /// all 20 rows, iOS 26.5 — exactly two differ). A row therefore matches on
    /// its REQUEST or on its RENDERED name.
    ///
    /// STILL nil FOR A GLYPH NO ROW SPELLS, and that is the point: a name that
    /// is neither a request nor a measured rendering is a picture this
    /// vocabulary does not describe.
    ///
    /// THERE IS DELIBERATELY NO FALL-BACK to the identifier kaya's own arm
    /// published. It would close this gap and open a worse one: an arm perturbed
    /// to draw an off-table glyph would also fail to invert, and would then be
    /// answered from kaya's claim — the read passing while the wrong picture is
    /// on screen.
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
            // no glyph image under it. The arm's own identifier rides along when
            // there is one, because it tells "the app declared no symbol" from
            // "declared one this OS would not draw" — a REPORT of a second
            // measurement, never the answer.
            let arm = button.ident.map { $0.hasPrefix(kayaToolbarSymbolIdent)
                ? " (\(String($0.dropFirst(kayaToolbarSymbolIdent.count))))" : "" } ?? ""
            return "the toolbar button \(button.name) renders no symbol image\(arm)"
        }
        guard let semantic = kayaToolbarIOSSemantic(sf) else {
            // WHAT THIS MEASURED: a real glyph, and a spelling no row of the
            // table carries in EITHER column. Two causes it CANNOT tell apart
            // and so does not try to: an arm drawing something outside this
            // vocabulary, and a row this OS renames to a spelling the rendered
            // column has not measured yet. Both are named, and the glyph is
            // printed either way.
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

    /// THE expect_toolbar READ on iOS: `<promoted found>/<promoted in the
    /// catalog>/<items on the bar>/<remainder's home>`, the macOS arm's spelling
    /// exactly, off this platform's own object graph. The first two numbers come
    /// from two different sides ON PURPOSE, so an answer computed once and
    /// reported twice cannot agree with itself; the third is what the bar really
    /// holds, so a bar that never materialized reads differently from one
    /// holding the wrong buttons. The remainder's home is the MORE menu, and
    /// this LOOKS FOR IT on the bar rather than assuming the arm ran.
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
    /// have consulted, plus the accessibility subtree under each button. It is
    /// how the enablement and symbol questions were ANSWERED rather than
    /// guessed. The macOS sibling of this function is what found that
    /// NSToolbarItem.isEnabled does not move at all.
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

    /// EVERY SECTION SWITCHER ROW this process is showing, in the order a walk
    /// of the accessibility tree meets them — the macOS tab bar's items AND the
    /// source list's rows, from every window, because the sections scene puts
    /// its sidebar in an aux window.
    ///
    /// A ROW IS AN ELEMENT THE RENDER STAMPED. Scoping by role instead was tried
    /// and rejected: SwiftUI's macOS TabView publishes its items as AXRadioButton
    /// under an AXTabGroup while the sidebar publishes AXRow > AXCell, and a role
    /// list is a claim about SwiftUI's internals that a release can quietly
    /// falsify. The spoken name comes from AppKit's own title/description/value,
    /// never from the stamp, so the two halves of the match come from two places.
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
        // THE ANSWER IS THE STAMP, and its limit is stated: it is what the arm
        // SAID it drew, not the glyph itself. macOS publishes no image object
        // for either switcher (measured, see kayaSectionTrace), so unlike the
        // iOS half there is nothing stronger to read — and deliberately NO
        // fall-back to section.symbol, which is the copy that was garbage while
        // every lane stayed green.
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

    /// A RENDERED TAB GLYPH, back to kaya's vocabulary.
    ///
    /// THE FILLED-VARIANT FINDING, measured on the simulator (iOS 26.5) and the
    /// reason this is not just `kayaToolbarIOSSemantic`: a UITabBar draws the
    /// FILLED variant of whatever symbol it is given. kaya asks for `house` and
    /// `star`; the bar's image views publish `house.fill` and `star.fill`, for
    /// the selected tab and the unselected one alike. That is a THIRD naming
    /// relationship — kayaSymbolTable's `rendered` column records an alias
    /// SwiftUI resolves before the image exists, this a variant UIKit picks when
    /// it draws. STILL NO FALL-BACK to kaya's own stamp.
    func kayaSectionIOSSemantic(_ rendered: String) -> String? {
        if let name = kayaToolbarIOSSemantic(rendered) { return name }
        if rendered.hasSuffix(".fill") {
            return kayaToolbarIOSSemantic(String(rendered.dropLast(".fill".count)))
        }
        return nil
    }

    /// THE expect_section_symbol READ on iOS: the GLYPH the row really draws,
    /// inverted back to kaya's vocabulary.
    ///
    /// THE INVERSION MATCHES EITHER COLUMN of kayaSymbolTable: SwiftUI resolves
    /// an SF alias to its canonical spelling before UIKit ever builds the image.
    /// AND NO FALL-BACK TO THE STAMP when the inversion fails, for
    /// kayaToolbarIOSSemantic's measured reason: a fall-back would let an arm
    /// perturbed to draw an OFF-TABLE glyph pass while the wrong picture was on
    /// screen.
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
/// consulted. It is how the channel on each host was ANSWERED rather than
/// guessed — run the sections scene, which renders the bar arm in the primary
/// window and the sidebar arm in an aux one, and read which property carries the
/// glyph.
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
/// first (context items shadow the bar while presented), then the bar. macOS
/// reads the REAL NSMenuItem state from the owned segment (a backend that
/// ignored the write must fail); iOS reads the model, because SwiftUI exposes no
/// item registry to read instead.
///
/// STATE IS NOT THE SYMBOL, and the two reads part company here. Every aspect
/// this function answers — enablement, checkedness, value — is carried into the
/// chrome by a modifier the row itself applies, so the model IS what the More
/// menu and the promoted bar enumerate for these three. The semantic icon was
/// the aspect where that stopped being true, so kayaMenuSymbolRead reads a
/// RENDER STAMP for items the bar is carrying.
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
            // A STANDARD COMMAND'S ENABLEMENT IS NOT A BUILD-TIME FACT, and
            // this reader had no way to say so. The activation route refreshes
            // and a real user's menu opening refreshes (the delegate), but
            // `update()` on a menu with autoenablesItems=false validates nothing
            // and never reaches the delegate — measured: the undo scene typed
            // into a field and this read still answered with the state the item
            // was BORN with.
            kayaRefreshRoleEnablement()
            // VALIDATED state, not merely the state we set: AppKit settles an
            // item's enablement when its menu is about to display, so this reads
            // what the user's next click will get — and it fails loudly if a
            // Kaya menu ever loses `autoenablesItems = false` (docs/traps.md).
            // The top-level holders sit in the DRESS-owned main menu, whose
            // automatic enabling is not ours to interpret, so a grouping node
            // keeps answering with the declared state.
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
    /// before Window/Help. Anchors are locale-independent: the Edit dress is
    /// detected by its native edit actions (copy:/paste: survive every
    /// localization; the English title probe is only the fallback), Window/Help
    /// by NSApp's own menu handles.
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
    /// catalog — always from the model, which is the post-user mirror
    /// (docs/traps.md: rebuilding from a pre-click copy silently reverts the
    /// user's toggle/radio state).
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

    /// The EVENT-DRIVEN re-assert (docs/traps.md: a one-shot insertion races the
    /// same asynchronous scene machinery as a one-shot window registration):
    /// SwiftUI rebuilding the bar fires the NSMenu item notifications or
    /// replaces NSApp.mainMenu (KVO); key-window changes swap the catalog.
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

    /// menu_activate's macOS bar route — the ruled REAL-chrome verdict, resolved
    /// SEMANTICALLY: the path walks the model tree, then the materialized
    /// NSMenuItem is found by IDENTITY, never by title-walking the chrome.
    ///
    /// A STANDARD COMMAND'S ENABLEMENT IS NOT A BUILD-TIME FACT: it is the
    /// intersection of what the clipboard offers and what the FOCUSED widget
    /// accepts, and both move long after the bar was built. Kaya-owned menus set
    /// `autoenablesItems = false` (docs/traps.md), so AppKit will not recompute
    /// one — this does. Found the hard way: the first cut computed it once, at
    /// sync, and every paste leg failed SILENTLY.
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
    /// NSMenu.performKeyEquivalent — the same key-equivalent table the real key
    /// press walks. The verb is a SILENT action and a chord no catalog action
    /// owns is a no-op on every platform, so the catalog table gates the walk —
    /// the dress bar must never swallow an unowned chord (a stray primary+w
    /// would close the window under the leg). Returns true when NO catalog item
    /// owns the chord.
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
/// SwiftUI-menu spelling of what kayaApplySymbol does to every NSMenuItem the
/// mac arm builds. Label, not Text: the row keeps its title as the spoken text
/// and gains the platform's own glyph.
///
/// Shared by the More menu's rows and by every context menu, on both platforms,
/// which is why it resolves nothing beyond the table: a name this OS lacks draws
/// as no glyph here, and the two READS that matter each check resolution where
/// they can actually observe it.
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

/// The window catalog's chrome, attached to every surface root: a no-op on macOS
/// (the global-bar synchronizer owns the lowering there), and elsewhere the
/// FORM-FACTOR-keyed choice of lowering. The axis is the window's size class,
/// never the operating system (DESIGN.md, "Form factor and adaptivity") — the
/// `#if os(iOS)` this replaced was wrong as of iPadOS 26.
///
/// It also stamps the window's live FORM FACTOR, once, for everyone: the
/// platform's own size class where there is one, and the window's OWN WIDTH
/// against the same 600 boundary GTK, WinUI and Compose draw where there is not.
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
/// accessibility identifier, so the read can tell a kaya-drawn answer from an
/// element that simply has no identifier.
///
/// BOTH LOWERINGS PUBLISH IT, which is why it is not inside either platform's
/// block: the mac arm hands it to AppKit, which carries it onto the real
/// AXButton, and the iOS arm hands it to SwiftUI, which carries it onto the
/// hosted `_UIButtonBarButton` element.
///
/// WHAT IT IS WORTH DIFFERS BY HOST. On macOS it is the symbol ANSWER, because
/// nothing on that lowering names the glyph. On iOS it is only a DIAGNOSTIC:
/// UIKit publishes the SF name on the rendered image view itself.
let kayaToolbarSymbolIdent = "kaya-toolbar-symbol:"

#if os(macOS)
    /// The macOS window-anchor lowering: the promoted primaries as REAL NSToolbar
    /// items (docs/chrome-plan.md C2), off the SAME promoted list the phones use.
    /// The remainder needs no More menu here — the kaya-owned NSApp.mainMenu
    /// segment already carries the entire catalog.
    ///
    /// NO TOOLBAR STYLE IS SET, and that is MEASURED rather than an omission:
    /// `.automatic` resolves to `.unified` for this window shape, and setting
    /// `.unified` explicitly measured identical at 52pt while `.expanded` moved
    /// to 56pt — which is what proves the modifier reaches the window at all.
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

    /// One promoted primary's label on macOS — and the identifier that says which
    /// arm of it drew. PRECEDENCE, the rule the mac menu arm and the iOS bar
    /// already spell: the semantic symbol wins, the app's icon bytes are the
    /// fallback, a bare label the last resort. `Label(_:systemImage:)` rather
    /// than a bare `Image`, because the title is what AppKit lifts onto
    /// `NSToolbarItem.label` (measured) and what an assistive client speaks.
    ///
    /// WHY THE ARM PUBLISHES AN IDENTIFIER: a SwiftUI TOOLBAR item has no glyph
    /// object to read — measured, `NSToolbarItem.image` is nil for every item,
    /// the hosting view's subtree is three AXUnknown shims, and the real
    /// AXButton publishes no attribute naming a glyph. So the strongest
    /// available observation is the accessibility identifier each arm writes,
    /// which AppKit carries onto the real element; perturb which arm draws and
    /// the identifier moves with it.
    ///
    /// WHAT IT CANNOT SEE: the pixels. An edit that keeps this arm and swaps the
    /// view inside it would still publish "done".
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
    /// The regular-width catalog lowering: the platform's own menu bar (iPadOS
    /// 26+). Driven through UIMenuBuilder rather than SwiftUI's `.commands` for
    /// the same reason macOS drives NSMenu directly — CommandsBuilder has no
    /// `buildArray`, so it cannot express an append-at-any-time number of
    /// top-level menus. buildMenu also runs on iPhone, where it feeds the
    /// hardware-keyboard HUD, so building is unconditional; only the VISIBLE arm
    /// keys on size class.
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
    /// UIKit spells separation.
    ///
    /// UIKit has no separator element: a divider is the boundary between
    /// `.displayInline` groups. So partition the run at each separator and wrap
    /// each partition inline. A placeholder element would be wrong (it renders as
    /// a real, selectable row), and an EMPTY inline menu draws nothing at all,
    /// which is why empty partitions are dropped rather than emitted.
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

    /// A STANDARD COMMAND'S ENABLEMENT IS NOT A BUILD-TIME FACT, and the
    /// clipboard is the half that moves without the app touching anything. The
    /// harness route already sees it fresh, but a UIAction bakes `.disabled` in
    /// when the menu was built, so the VISIBLE Paste item would keep whatever it
    /// was born with. This is the iOS half of the macOS refresh (its menu
    /// delegate is asked before display; UIKit asks nobody).
    func kayaInstallClipboardObserver() {
        guard !kayaClipboardObserverInstalled else { return }
        kayaClipboardObserverInstalled = true
        NotificationCenter.default.addObserver(
            forName: UIPasteboard.changedNotification, object: nil, queue: .main
        ) { _ in
            kayaRebuildCatalogMenus()
        }
    }

    /// One promoted primary's label — and the arm's own account of what it drew.
    ///
    /// PRECEDENCE, MIRRORED FROM macOS: the semantic symbol wins, the icon bytes
    /// are the fallback, a bare label the last resort. Label rather than Image:
    /// the glyph is what the user sees and the item's LABEL is what an assistive
    /// client reads.
    ///
    /// THE IDENTIFIER IS A DIAGNOSTIC, not the symbol answer. UIKit publishes the
    /// SF name on the image view this arm's `Label` produces, so both iOS symbol
    /// verbs ask the GLYPH what it is and turn to this string only when there is
    /// no glyph. That ordering closes the gap the first fix left open: a `Label`
    /// swapped for a `Text` inside this same arm keeps the identifier and loses
    /// the image, and the read follows the image.
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

/// Does `windowId` take a split arm right now? Both halves must hold:
/// the app ASKED (wprop 6) and the window IS regular. The size class is the
/// platform's answer, never the app's — that is what makes this adaptive.
/// WHICH split root renders is the ceiling's call (2 or 3); a compact
/// window takes the stack arm at any ceiling, kaya's uniform collapse
/// (docs/multicolumn-plan.md Q3).
func kayaSplitArm(_ windowId: UInt64) -> Bool {
    guard let w = kayaScene.windows[windowId] else { return false }
    return w.panes >= 2 && w.formFactor == .regular
}

// --- The pane surfaces on screen, and the mac ladder ------------------
// docs/multicolumn-plan.md: D1 (positions), D4 (the reader),
// MECHANICS AMENDMENTS (what may be declared to SwiftUI and what must
// not be).

// KAYA'S OWN PANE MINIMUMS — the model's alone, DECLARED TO NOBODY.
// A minimum handed to navigationSplitViewColumnWidth becomes the
// WINDOW's floor: the collapse rule can then never fire and
// resize_window turns into a silent no-op (MECHANICS AMENDMENTS 1).
// content+detail stays UNDER 600, the compact threshold: below 600 the
// window leaves the split arm entirely, so the two-pane rung is this
// ladder's floor and the bare expect_panes invariant — a regular window
// never stacks — holds at every regular width. tools/check-pane-ladder.sh
// pins the arithmetic and that ordering.
let kayaPaneMinSidebar: Double = 200
let kayaPaneMinContent: Double = 270
let kayaPaneMinDetail: Double = 320

/// Which rung fits `width`: 3 when the window can hold all three of
/// kaya's minimums, else 2. There is no 1 rung — one pane is the
/// compact stack arm's territory (see the constants above).
func kayaPaneRung(_ width: Double) -> Int {
    width >= kayaPaneMinSidebar + kayaPaneMinContent + kayaPaneMinDetail ? 3 : 2
}

/// EDGE-TRIGGERED: a command only when a width CROSSING changes the
/// rung, nil on the level — the sidebar toggle writes the same
/// visibility binding, and a level-triggered rule would undo the
/// user's choice on the next layout pass (MECHANICS AMENDMENTS 3).
/// `from == nil` is the first real measurement: an edge from nothing.
func kayaPaneLadderCommand(
    from: Double?, to: Double
) -> NavigationSplitViewVisibility? {
    if let from, kayaPaneRung(from) == kayaPaneRung(to) { return nil }
    return kayaPaneRung(to) == 3 ? .all : .doubleColumn
}

/// The expect_panes reading for `windowId`: `<size class>/<positions>`,
/// positions ascending stack indices (0 the base root, j entry j-1).
///
/// On a macOS split arm the positions come from the REAL NSSplitView —
/// each column counted visible by width AND hiddenness (a zero-width
/// column keeps isHidden == false, so either signal alone over-reads) —
/// mapped to the stack slot it holds, with an EMPTY slot contributing
/// no position (D1: a pane is a surface from the stack). On the stack
/// arm the one pane on screen is the TOP of the stack, the same
/// stack-depth reading D4 prescribes for a collapsed column. View
/// lifecycle is deliberately NOT the source: NavigationStack retains
/// covered views without firing onDisappear, and an arm swap fires the
/// outgoing arm's onDisappear after the incoming arm's onAppear.
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
        // No split view on screen: the stack arm's one pane is the TOP.
        // On a non-macOS split arm (no NSSplitView exists there) the
        // positions derive from the arm stamp and the stack — the
        // harness.rs two-pane rule; the iOS real-arrangement read
        // (UISplitViewController's columns) is its own slice's work.
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

/// The two-column presentation of a window's entry stack: pane 0 the
/// base root, the trailing pane the TOP of the stack, the middles
/// retained and covered exactly as navigation already does
/// (docs/multicolumn-plan.md D1; the ceiling-3 form is KayaSplitRoot3,
/// a separate struct because the two- and three-column
/// NavigationSplitView initializers are different generic types).
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
                // THE WINDOW'S TITLE HANGS OFF THE DETAIL COLUMN. On macOS a
                // NavigationSplitView titles its window from the DETAIL side;
                // the sidebar's navigationTitle names the sidebar column and
                // nothing else. So with an empty stack there was no title at
                // all, and AppKit substitutes the PROCESS NAME. That read as
                // correct for one reason: the only guest running this scene was
                // an example binary named `split`, and the scene asserts the
                // title "split" — the Python port reported "python3.14".
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

/// The THREE-column presentation (docs/multicolumn-plan.md D1/D3):
/// pane 0 the base root, pane 1 the first entry, and the detail column
/// the REST of the stack — its own NavigationStack, so a deep stack
/// keeps a real back item that appears exactly when this column COVERS
/// something and survives every rung of the ladder. An empty pane slot
/// still exists (D1): pushes deepen a column, never swap containers.
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

struct KayaEntry: View {
    let node: KayaNode
    @FocusState private var focused: Bool

    var body: some View {
        // Uncontrolled toward the app: the node mirrors what the user types
        // (SwiftUI needs the binding), and every edit is emitted with the
        // entry's identity tag — nothing here is read back. Focus is
        // model-driven the same way: the focus command lands as the scene's
        // focusedId, mirrored into SwiftUI here, and a user-driven change flows
        // back so the model stays truthful.
        TextField(
            "",
            text: Binding(
                get: { node.text },
                set: { newValue in
                    let value = kayaLF(newValue)
                    node.text = value
                    KayaHost.emitText(node, value)
                })
        )
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 200)
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

/// THE TEXTAREA'S LAYOUT FLOOR, AND THE ONE PLACE `grow` REACHES IT — stated
/// once for both platform halves, because 240x96 is one size with two spellings.
///
/// A FLOOR, NOT A FIXED FRAME, as GTK's `set_size_request(240, 96)` and WinUI's
/// MinWidth already are. `.frame(width: 240, height: 96)` was not — it refused
/// the track KayaFlex assigned, so an editor asking for a full-window buffer
/// with grow(1) got a small box on macOS AND iOS while every share assertion
/// passed (expect_shares reads the TRACK).
///
/// TWO AXES, TWO OWNERS: `grow` divides the container's MAIN axis and `align`
/// places on the CROSS axis, so each releases its own dimension, following
/// `flexVertical`. A textarea outside a flex container keeps the floor.
///
/// THE CROSS HALF WAS THE SECOND HALF OF THE SAME DEFECT (2026-08-10): with the
/// main axis released, a full-window buffer got a full-HEIGHT column 240pt wide,
/// because `maxWidth: 240` refused the cell a stretch-aligned column proposed.
extension View {
    func kayaTextareaFrame(grow: Double, flexVertical: Bool?, stretch: Bool) -> some View {
        let grows = grow > 0
        let fillsWidth = (grows && flexVertical == false) || (stretch && flexVertical == true)
        let fillsHeight = (grows && flexVertical == true) || (stretch && flexVertical == false)
        return frame(
            minWidth: 240, maxWidth: fillsWidth ? .infinity : 240,
            minHeight: 96, maxHeight: fillsHeight ? .infinity : 96)
    }
}

#if os(macOS)
/// The multi-line editor on macOS: KayaEntry's exact contract (uncontrolled
/// fold, identity-tag emits, model-driven focus) over an NSTextView this file
/// holds directly.
///
/// RICH-CAPABLE CONTROL, PLAIN-TEXT CONTRACT (docs/textarea-foundation-plan.md).
/// The control underneath is the one that can express attributed runs, and
/// kaya's textarea contract does not move by one byte. Every opinion the rich
/// control carries is pinned off in `kayaPinPlainText`, audited on the live
/// control, and a breach fails the leg that rendered it.
struct KayaTextarea: View {
    let node: KayaNode
    /// The main axis of the flex container this textarea sits in, if it
    /// sits in one — see kayaTextareaFrame.
    var flexVertical: Bool? = nil
    /// Whether that container aligns `stretch` — the cross axis's half.
    var flexStretch = false

    var body: some View {
        // EVERY MODEL FACT THE VIEW NEEDS IS READ HERE, in a SwiftUI body, and
        // handed down as a value. That is not style: @Observable tracks the
        // reads a BODY makes, so reading `node.text` here is what makes a model
        // write re-run this body — and the re-run is what brings `updateNSView`
        // around to push the text into AppKit. A representable that reached for
        // the node inside `updateNSView` would register no dependency.
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
        .kayaTextareaFrame(grow: node.grow, flexVertical: flexVertical, stretch: flexStretch)
        .border(Color.gray.opacity(0.4))
    }
}

/// The owned text view.
///
/// THE SUBCLASS EXISTS FOR ONE REASON: focus is a kaya model fact, and it has to
/// stay truthful in BOTH directions. The model-driven direction is a
/// `makeFirstResponder` from `updateNSView`; the user-driven one has no delegate
/// hook — `textDidBeginEditing` fires on the first EDIT, not when the caret
/// arrives — so a click into an empty editor would leave `kayaScene.focusedId`
/// naming whatever was focused before.
private final class KayaTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?
    /// Whose widget this is, so the view can ask the model whether it should be
    /// focused at a moment only the view knows about.
    var nodeId: UInt64 = 0

    /// FOCUS IS APPLIED WHEN THE VIEW HAS SOMEWHERE TO BE FOCUSED, and this hook
    /// is not belt-and-braces for the one in `updateNSView` — it is the case
    /// that hook CANNOT cover.
    ///
    /// MEASURED, and it cost two runs in three: SwiftUI creates and updates a
    /// representable's NSView BEFORE putting it in a window, so the update
    /// carrying "this widget is focused" runs with `window == nil`,
    /// `makeFirstResponder` has nobody to send to, and the focus is lost with no
    /// error and no second chance. The symptom is remote from the cause:
    /// `expect_focused` passes (it reads the model), and the NEXT `type` reports
    /// "reached no window".
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

/// PIN OFF EVERY OPINION THE RICH CONTROL CARRIES.
///
/// NSTextView is a rich text editor with a decade of opinions about what the
/// user "meant", and shipping one by accident would move kaya's plain-text
/// contract without anything saying so: a person typing `"` into an unpinned
/// control gets `"`, and the app is told a character it never entered.
///
/// EACH LINE IS LOAD-BEARING ON ITS OWN. NSTextView also has
/// `enabledTextCheckingTypes`, one bitmask that would zero the checking group in
/// a statement — and that is why it is not used: an umbrella makes every
/// individual pin unfalsifiable.
///
/// THE DEFAULTS ARE NOT KAYA'S TO CHOOSE: most of these read their initial value
/// from the user's own system settings.
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

/// The pins, read back off the LIVE control, plus the one fact AppKit derives
/// for itself.
///
/// WHAT THIS PROVES AND WHAT IT CANNOT. It proves each pin is in force on the
/// object the user types into: delete one, flip one, apply them to the wrong
/// view, or let SwiftUI hand back a view that never saw them, and every
/// textarea-bearing leg fails naming the trait. It cannot prove AppKit HONOURS a
/// trait, and that half could not be measured from inside a leg either: with the
/// quote and dash substitutions flipped ON, the harness's own `type` verb — real
/// NSEvents through `NSApp.sendEvent` — still produced straight quotes and two
/// hyphens (measured 2026-08-06), because the substitution machinery does not
/// act on a process that never becomes active.
///
/// ONE CLAUSE IS APPKIT'S OWN ANSWER: a TextKit 2 layout manager exists only
/// while nothing has touched `.layoutManager`.
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
    // The enabled checking types are the umbrella the pins deliberately do not
    // use — asserted rather than set, so a checker switched on through the mask
    // is a breach here instead of a silent substitution. ORTHOGRAPHY is the one
    // bit AppKit keeps whatever the individual properties say: it is the language
    // identification the checkers are built on and rewrites nothing. Measured at
    // exactly 1 (orthography alone) on macOS 26.5 with every pin above in force.
    want(
        view.enabledTextCheckingTypes
            & ~NSTextCheckingResult.CheckingType.orthography.rawValue == 0,
        "enabledTextCheckingTypes")
    want(view.textLayoutManager != nil, "textLayoutManager")
    if !breaches.isEmpty { kayaPlainTextPinBreaches.formUnion(breaches) }
}

/// The macOS textarea: an NSTextView kaya owns, wrapped by kaya rather than by
/// SwiftUI.
///
/// WHY THE STOCK TextEditor HAD TO GO (range-probe-mac.md H2/G6): it pushes an
/// app-driven text change into its private AppKit view ONE MAIN-QUEUE TURN LATER
/// — 11ms after kaya's write — and that late push resets the caret to the end of
/// the document and destroys every attribute declared on the text. Owning the
/// view moves the push into `updateNSView`, so the text and everything declared
/// over it land in ONE pass.
///
/// NEVER READ `.layoutManager` ON THIS VIEW, not even in a diagnostic: reading
/// it silently and permanently converts a TextKit 2 view to TextKit 1.
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
        /// THE TEXT STACK'S OWNER. TextKit 2's graph runs content manager ->
        /// layout manager -> container, and the text view is initialized with the
        /// CONTAINER — so nothing the view holds is documented to keep the
        /// content manager alive, and a widget whose content manager is collected
        /// has no text at all. The coordinator outlives every update.
        var content: NSTextContentStorage?

        func textDidChange(_ notification: Notification) {
            guard let node, let view = notification.object as? NSTextView else { return }
            let value = kayaLF(view.string)
            // THE ECHO DOCTRINE, held at the one place an echo could enter: a
            // programmatic write emits nothing. AppKit does not notify a
            // delegate about a change kaya made through `string` — but "AppKit
            // does not" is a premise, and the cost of it being wrong is a
            // text_changed the app never caused. Comparing against the model
            // refuses that whatever AppKit decides to notify about.
            guard value != node.text else { return }
            node.text = value
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
            // ONE TURN OUT, and the model re-read INSIDE the turn. This fires
            // from inside AppKit's first-responder change, which can be inside a
            // SwiftUI update pass — writing the model there is the "modifying
            // state during view update" hazard. And by the time the turn arrives
            // the answer may have moved, so the closure asks who holds focus NOW.
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
        // AND THE ONE LANDMINE OF THIS SWAP (range-probe-mac.md J1).
        //
        // `kayaA11y` applies `.accessibilityIdentifier` to the widget from
        // KayaRender; on a representable SwiftUI lands it on the ROOT AppKit view
        // — this scroll view — and PROPAGATES it down to the first child besides.
        // `kayaAxFind` takes the FIRST element whose identifier matches, so a
        // published scroll area wins the search and `expect_ax textarea#0` reads
        // `group/Notes` where the a11y milestone pinned `field/Notes`.
        //
        // Not publishing the viewport is what puts the text area first. It is
        // also the honest tree: this scroll view is a viewport with no name, no
        // value and nothing to activate, and iOS publishes no such element at
        // all. Overriding `accessibilityIdentifier()` on a subclass does NOT work
        // and was tried first: the identifier is served by the accessibility
        // element SwiftUI installs, not by the view's own method.
        scroll.setAccessibilityElement(false)
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? KayaTextView else { return }
        context.coordinator.node = node
        view.nodeId = node.id

        // APPLIED ON EVERY UPDATE, not once at construction: a pin that only ran
        // in makeNSView would be quietly lost the day SwiftUI hands back a
        // recycled view or AppKit re-derives a trait from the user's settings.
        // The audit beside it reads the live control back — a breach fails the
        // leg that rendered the widget, which is a wall on the path every
        // textarea-bearing scene already walks.
        kayaPinPlainText(view)
        kayaAuditPlainTextPins(view)

        // THE PUSH KAYA OWNS. Guarded by a comparison rather than written
        // unconditionally: an identical write would still rebuild the text
        // storage, and a rebuild throws away everything declared on the runs
        // (measured, G2). The selection is carried across, clamped.
        //
        // AND NOT WHILE THE USER IS COMPOSING, measured 2026-08-06 with the
        // whole loop instrumented:
        //
        //     PROBE update marked=true push=true viewLen=814 modelLen=809
        //     PROBE textDidChange marked=false len=809
        //
        // `setMarkedText` does NOT notify the delegate, so kaya's model never
        // hears about a composition and the next update pass sees the view five
        // characters longer, pushes, and DESTROYS the user's half-typed word —
        // then reports the text without the composition, so the app is told the
        // user typed nothing at all. KAYA DOES NOT TOUCH A CONTROL WHILE THE
        // USER IS COMPOSING IN IT (D4).
        if view.string != text, !view.hasMarkedText() {
            let selection = view.selectedRange
            view.string = text
            let end = (text as NSString).length
            let location = min(selection.location, end)
            view.setSelectedRange(
                NSRange(location: location, length: min(selection.length, end - location)))
        }

        // THE UNIVERSAL PROPS, ON THE ELEMENT THAT PUBLISHES AS THE TEXT AREA.
        // They ride SwiftUI modifiers from KayaRender for every other kind and
        // land on the representable's root view, which is the viewport (J1) — so
        // they are set again here, on the text view itself, and kaya's own set
        // WINS: measured by setting `a11yId + "-own"` and reading
        // `AXTextArea id=notes-own` back out of the tree. Empty stays unset.
        view.setAccessibilityIdentifier(a11yId)
        view.setAccessibilityLabel(a11yLabel.isEmpty ? nil : a11yLabel)
        view.setAccessibilityHelp(a11yHint.isEmpty ? nil : a11yHint)

        // THE RANGES, IN THE SAME PASS AS THE TEXT PUSH ABOVE. That ordering is
        // the whole reason this widget stopped being a stock TextEditor:
        // SwiftUI's own push landed a main-queue turn later and destroyed
        // everything declared before it, and a re-declare issued in the same
        // batch was applied to the OLD document and then wiped.
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

    /// The three primitives, lowered onto the owned view.
    ///
    /// HIGHLIGHT WRITES DOCUMENT ATTRIBUTES (`NSTextStorage`'s
    /// `.backgroundColor`): it is the only one of macOS's three highlight
    /// mechanisms accessibility publishes, and accessibility is where the
    /// harness reads. TextKit 2 rendering attributes and `NSTextHighlightStyle`
    /// report `bg=false` through `AXAttributedStringForRange`; TextKit 1
    /// temporary attributes need `.layoutManager`, one read of which converts
    /// this view to TextKit 1. All three measured, range-probe-mac.md §1/§4.
    ///
    /// D2'S CLEAR-ON-EDIT IS THE `highlightsFor` COMPARE, made at paint time so
    /// it cannot arrive late. It is not belt-and-braces for the platform's own
    /// behaviour: measured, an app-driven write wipes every attribute layer by
    /// itself, but a USER edit does not — typing three characters at offset 0
    /// MOVED a highlight at {20,5} to {23,5} (F1), and tracking is exactly what
    /// D2 refuses to ship.
    private func applyRanges(_ view: KayaTextView, _ coordinator: Coordinator) {
        guard let storage = view.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.backgroundColor, range: full)
        if highlightsFor == text {
            // BOUNDS ARE RE-CHECKED AGAINST THE LIVE STORAGE, and this is not
            // distrust of the core — it is the one call on this path that kills
            // the process rather than complaining. An out-of-range `addAttribute`
            // raises NSRangeException and the app exits 134 (measured), and the
            // storage's length is a fact only this side holds at this instant.
            for range in highlights where NSMaxRange(range) <= storage.length {
                storage.addAttribute(
                    .backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.55),
                    range: range)
            }
        }

        // THE TWO ONE-SHOTS, each performed once per request. Both are clamped to
        // the live text for the same reason as above: AppKit tolerates an
        // out-of-range selection and an out-of-range scroll, but tolerating is
        // not a contract, and a range whose text has already moved on is not the
        // range the app asked for.
        let length = (view.string as NSString).length
        if let range = selectRequest, selectSeq != coordinator.selectDone,
            NSMaxRange(range) <= length
        {
            coordinator.selectDone = selectSeq
            // D4, AND THE ONLY PARTY THAT CAN ENFORCE IT. An input-method
            // composition is live in the view and on no kaya channel, so the core
            // cannot know and the app cannot avoid the race. Honouring a
            // selection here COMMITS the marked text into the document AND into
            // the app's model mid-word — measured, range-probe-mac.md E7 — which
            // is data loss shaped like a feature. Refused as a no-op under a
            // named reason, never a panic.
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
/// through accessibility: `compose` has to reach the view's own input-method
/// entry point (`setMarkedText`), which no AX attribute exposes. The three READS
/// deliberately do not use this map — they go through the accessibility tree, so
/// a leg cannot pass because kaya remembered its own intent.
final class KayaWeakTextView {
    weak var view: NSTextView?
    init(_ view: NSTextView) { self.view = view }
}
var kayaMacTextViews: [UInt64: KayaWeakTextView] = [:]

#else
    /// The multi-line editor on iOS: KayaEntry's exact contract (uncontrolled
    /// fold, identity-tag emits, model-driven focus) over a UITextView this file
    /// holds directly.
    ///
    /// RICH-CAPABLE CONTROL, PLAIN-TEXT CONTRACT, and the control is the only
    /// half that moved. `TextEditor` was already a UITextView underneath, but
    /// SwiftUI owned that object: nothing kaya could reach named its layout
    /// manager, its selection or its scroll offset. Holding the view changes
    /// NOTHING an app or a scene can observe, and it buys the handle the ranges
    /// milestone needs — all public API at kaya's iOS 16 floor.
    struct KayaTextarea: View {
        let node: KayaNode
        /// The main axis of the flex container this textarea sits in, if it sits
        /// in one — see kayaTextareaFrame.
        var flexVertical: Bool? = nil
        /// Whether that container aligns `stretch` — the cross axis's half.
        var flexStretch = false

        var body: some View {
            // EVERY OBSERVATION IS READ HERE, in a SwiftUI body, and handed
            // down as values. `updateUIView` is not an observation scope of its
            // own, so a representable that reached for `node.text` inside it
            // would render once and never hear about a model write again — and
            // the ranges are read here for the same reason.
            KayaUITextView(
                node: node, text: node.text, focusedId: kayaScene.focusedId,
                highlights: node.highlights,
                highlightsFor: node.highlightsFor,
                selectRequest: node.selectRequest,
                selectSeq: node.selectSeq,
                revealRequest: node.revealRequest,
                revealSeq: node.revealSeq
            )
            .kayaTextareaFrame(grow: node.grow, flexVertical: flexVertical, stretch: flexStretch)
            .border(Color.gray.opacity(0.4))
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
            /// mirror the value into the node, and emit with the widget's
            /// identity tag. Nothing is read back from the app.
            ///
            /// THE EQUALITY GUARD IS WHAT KEEPS THE ECHO OUT. Setting
            /// `UITextView.text` programmatically does not call this delegate
            /// method, so a model write cannot reach here on its own; the guard
            /// covers the paths that could and makes "no change, no emission"
            /// true by construction rather than by trust.
            func textViewDidChange(_ textView: UITextView) {
                guard let node else { return }
                let value = kayaLF(textView.text ?? "")
                guard value != node.text else { return }
                node.text = value
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
            // THE BARE INITIALIZER IS THE TEXTKIT 2 ONE. `UITextView()` gets an
            // NSTextLayoutManager from iOS 16 on; the container-taking
            // initializer and any read of `.layoutManager` silently downgrade
            // the view to TextKit 1, which has no non-destructive styling on
            // this platform at all. The audit below asserts the layout manager
            // is still there for exactly that reason.
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
            // THE PUSH KAYA OWNS — AND NOT WHILE THE USER IS COMPOSING.
            // Measured on this platform 2026-08-06, with marked text in the
            // control:
            //
            //     afterProgWrite marked=false text=abc# changes=0
            //
            // A programmatic `view.text =` during a composition DROPS
            // `markedTextRange`, commits nothing, and fires no delegate callback
            // at all — the user's half-typed word is gone and nobody is told.
            // The answer is D4's sentence: KAYA DOES NOT TOUCH A CONTROL WHILE
            // THE USER IS COMPOSING IN IT.
            //
            // The precondition differs from macOS: UITextView DOES notify its
            // delegate for marked text (measured), where AppKit's
            // `setMarkedText` notifies nobody — so on iOS kaya's model is never
            // silently behind the view, and this guard covers an app that writes
            // its own text during a composition rather than kaya's own echo.
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
            // FOCUS ON THE FAR SIDE OF THE RENDER. Becoming first responder
            // re-enters this view's delegate, which writes the very model this
            // update is reading; done inline that is a write during a SwiftUI
            // update. The next main-queue turn re-reads the model before acting,
            // so a focus that moved in between wins.
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

        /// The three primitives, lowered onto the owned view.
        ///
        /// HIGHLIGHT WRITES DOCUMENT ATTRIBUTES, the same mechanism the mac arm
        /// writes, and here that is a measured choice between two working
        /// options. TextKit 2 RENDERING attributes are the iOS-native
        /// non-destructive path and they do paint — but they are invisible until
        /// something calls `setNeedsDisplay()`, which nothing on the SwiftUI
        /// update path does, so a lowering that forgets it reads back perfectly
        /// and draws nothing (measured, range-probe-ios.md N1/S1: six settle
        /// rounds at `drawn=0` with the attribute present in every read).
        ///
        /// AND THE PLAIN-TEXT CONTRACT SURVIVES IT: copying a selection out of a
        /// storage-attributed UITextView puts `["public.utf8-plain-text"]` on
        /// the pasteboard and nothing else.
        ///
        /// D2'S CLEAR-ON-EDIT IS THE `highlightsFor` COMPARE: measured here, a
        /// USER keystroke SHIFTS these attributes rather than dropping them
        /// (`["51,56",…]` became `["52,57",…]` after one insert at 0).
        private func applyRanges(_ view: UITextView, _ coordinator: Coordinator) {
            let storage = view.textStorage
            let full = NSRange(location: 0, length: storage.length)
            // UNCONDITIONALLY, on every update pass, and that is measured: 200
            // clear passes over a 200 KB document cost 2.47ms — 12µs each —
            // because an attribute removal that removes nothing invalidates
            // nothing.
            //
            // CLEARED BEFORE ANYTHING IS APPLIED, and that is not housekeeping.
            // Measured: a re-declare that does not clear first UNIONS with the
            // stale shifted run — declaring {51,5} over a document the user has
            // typed one character into leaves {51,6}, wrong at both ends.
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

            // THE TWO ONE-SHOTS, each performed once per request, both clamped
            // to the live text. UIKit tolerates neither out of charity: an
            // out-of-range selection is CLAMPED TO A CARET AT THE END (measured:
            // `set{20,3}` on a 6-unit document reads back `{6,0}`), which would
            // silently move the caret somewhere the app never asked for.
            let length = ((view.text ?? "") as NSString).length
            if let range = selectRequest, selectSeq != coordinator.selectDone,
                NSMaxRange(range) <= length
            {
                coordinator.selectDone = selectSeq
                // D4, AND THE ONLY PARTY THAT CAN ENFORCE IT. An input-method
                // composition is live in the view and on no kaya channel, so the
                // core cannot know and the app cannot avoid the race. Refused as
                // a no-op under a named reason, never a panic.
                //
                // UNIFORM SEMANTICS, NOT INHERITED REASONING. On macOS honouring
                // the selection COMMITS the marked text into the document;
                // measured here, it does NOT — iOS leaves the composition alone
                // and moves the caret anyway. So this refusal is iOS spelling
                // the SAME contract, not protecting itself from a platform
                // behaviour.
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
                // COMPUTED AGAINST IT LANDS SHORT. TextKit 2 lays out what the
                // viewport shows and guesses the rest, and
                // `scrollRangeToVisible` scrolls to the guess without saying so.
                // Measured on the editor's 59-line document, revealing its LAST
                // two bytes from the top:
                //
                //     scroll   off 8 -> 1178, contentSize 1369 (estimated)
                //     settled  contentSize 1314, the line at 1276..1298
                //     visible  1178..1274 — the line 10pt below the fold
                //
                // Nothing re-scrolls afterwards: the one-shot is spent, so the
                // miss is PERMANENT and silent. So the layout up to the TARGET
                // is forced first — no further, since nothing below it can move
                // it — and the scroll then runs against real geometry.
                // `ranges.steps` never caught this: its reveal target sits
                // mid-document where the guess lands inside a 22pt line.
                if let layout = view.textLayoutManager,
                    let content = layout.textContentManager,
                    let end = content.location(
                        content.documentRange.location, offsetBy: NSMaxRange(range)),
                    let laid = NSTextRange(location: content.documentRange.location, end: end)
                {
                    layout.ensureLayout(for: laid)
                }
                // WITHOUT ANIMATION, and this is the difference between a
                // deterministic verb and a sleep. `scrollRangeToVisible` is
                // ANIMATED on iOS — measured at ~300ms over a standard UIKit
                // curve, reading as a complete no-op at the call site — so a leg
                // that asserts immediately fails and a leg that sleeps long
                // enough passes for the wrong reason. Wrapped, it lands
                // synchronously (3.95ms measured).
                UIView.performWithoutAnimation { view.scrollRangeToVisible(range) }
            }
        }
    }

    /// EVERY OPINION THE RICH CONTROL CARRIES, PINNED OFF.
    ///
    /// A UITextView arrives with the keyboard's whole editorial voice switched
    /// on: it capitalizes sentences, autocorrects, turns "quotes" typographic
    /// and `--` into an em dash, adds and removes spaces around a paste, offers
    /// inline predictions, completes arithmetic, hands the document to Writing
    /// Tools, takes attributed runs off the pasteboard, and owns a find
    /// interaction. kaya's textarea contract is BYTES.
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
        // allowsEditingTextAttributes, which is exactly why it is written down
        // rather than assumed: a default is a decision somebody else can
        // revisit, and this one decides whether Bold/Italic/Underline appear in
        // the edit menu and whether an RTF paste keeps its attributes.
        view.allowsEditingTextAttributes = false
        // The item-provider side of the same claim: this control takes what
        // reads as a plain String and nothing else. NSString's own readable list
        // is what that means, so the type set is Foundation's rather than one
        // written here — measured on the simulator as three plain-text
        // encodings, public.plain-text and public.url, where the
        // NSAttributedString configuration a rich editor would use brings RTF,
        // RTFD, flat RTFD, HTML, a webarchive and UIKit's attributed-string type.
        view.pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)
        // Data detectors run only on a non-editable view, so this is a
        // declaration rather than a fix, kept for the same reason.
        view.dataDetectorTypes = []
        // THE FIND INTERACTION IS THE CANARY (iOS 16), and the one pin UIKit
        // will answer for itself: `findInteraction` is non-nil if and only if
        // this flag is set, so the audit reads UIKit rather than the line above.
        // Off for the mac arm's reason as well: the ranges milestone owns this
        // control's selection and scroll offset, and a find bar moves both.
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

    /// The pins, read back off the LIVE control, plus the two facts UIKit derives
    /// for itself.
    ///
    /// It proves each pin is in force on the object the user types into: delete
    /// one, flip one, apply them to the wrong view, or let SwiftUI hand back a
    /// view that never saw them, and every textarea-bearing leg fails naming the
    /// trait. It does NOT prove UIKit honours the trait, because iOS has no
    /// in-process way to press a key — there is no API to post a UIPressesEvent,
    /// and `insertText` goes in below the keyboard.
    ///
    /// TWO CLAUSES ARE UIKIT'S OWN ANSWER: the find interaction exists iff the
    /// flag is set, and a TextKit 2 layout manager exists only while nothing has
    /// touched `.layoutManager`.
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
        // a plain String" rather than a list maintained here. Measured on the
        // simulator: the five identifiers NSString declares, against the eight an
        // NSAttributedString configuration would bring. A cleared configuration
        // reads as the empty set, which is UITextView's own default back again,
        // so it is a breach too.
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
/// accessibility identifier, the `kayaToolbarSymbolIdent` shape one construct
/// over. BOTH ARMS AND BOTH HOSTS publish it from the ONE body below, so a read
/// need not know whether it is looking at a sidebar row or a tab item.
///
/// WHAT IT IS WORTH DIFFERS BY HOST. On macOS it is the symbol ANSWER: SwiftUI
/// hands the tab bar and the source list an SF name and keeps no image object
/// anywhere the accessibility tree exposes (measured, KAYA_SECTION_TRACE). On
/// iOS it is a DIAGNOSTIC only.
let kayaSectionSymbolIdent = "kaya-section-symbol:"

/// ONE ROW BODY FOR EVERY SECTION SWITCHER — the macOS sidebar list, the macOS
/// tab bar and the phones' bottom bar.
///
/// It exists so that "what a section row draws" is a single arm. Before this the
/// two macOS arms each spelled the Label/Text choice for themselves, and a
/// perturbation of one would have left the other answering correctly.
///
/// The identifier is published on EVERY arm, symbol or not: "the row is there
/// and drew no glyph" and "there is no row" are different measurements, and
/// stamping only the glyph-bearing rows would collapse them into one.
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

/// A window's sections materialized: SwiftUI's TabView carries the platform's
/// dominant idiom under the `auto` hint — toolbar tabs on macOS, the bottom bar
/// on iOS. `sidebar` resolves to NavigationSplitView on macOS; the phones ignore
/// hints by physics. Each pane hosts ITS OWN NavigationStack. The selection
/// binding's setter fires only for USER switches, which emit section_selected —
/// a programmatic select_section writes the model directly and stays quiet.
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
                            // Label, not Text, so a section that named a
                            // SEMANTIC ICON gets the platform's own glyph beside
                            // its title (docs/styling-plan.md D6). ONE body with
                            // the tab arm below, so a perturbation of what a row
                            // draws moves both.
                            KayaSectionLabel(title: section.title, symbol: section.symbol)
                                .tag(section.id)
                        }
                        // EXPLICIT, not inherited: the sidebar style is what
                        // NavigationSplitView's sidebar column defaults to on
                        // macOS today, and the modern-mac pass depends on it — a
                        // default that changed under an SDK bump would silently
                        // de-modernize every sectioned window.
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
            // root takes the leading pane, the TOP of the stack the trailing
            // one, and a ceiling of three gives the first entry a middle
            // column. The entries between stay retained and covered — the
            // same rule navigation already has.
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
        // The primary surface's title (initially the process name, so an unset
        // prop changes nothing): SwiftUI's blessed window titling path on macOS;
        // harmless on iOS, where the switcher label is stamped in the apply arm.
        .navigationTitle(kayaWindowCaption(0))
        // THE BRAND ACCENT, applied as .tint of the current appearance's derived
        // FILL — a value the core computed, never re-derived here
        // (docs/styling-plan.md D1). A DECLARED BRAND WINS on every platform
        // (D2); a brandless app gets the environment default, which on macOS is
        // the user's own accent. The same tint rides the aux, the sections and
        // the split roots below — they are SIBLING scene roots, not descendants
        // of this one, and the brand reaching window 0 alone was Phase A's first
        // finding (2026-08-16).
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
            kayaStartSelftest()
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
