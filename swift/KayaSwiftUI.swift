// KayaSwiftUI: the Swift half of the SwiftUI backend — an interpreter of
// resolved apply-op records over the presentation-side C ABI:
//
//   create/add_child/mount/destroy -> an @Observable node tree
//   set_prop                       -> observable writes on the nodes
//   occurrence                     <- Button action -> emit_clicked(tag)
//
// The pump blocks in next_commands on its own thread and hops to the
// main actor to apply — the doorbell equivalent, no polling, no
// callbacks across the ABI. Signals, collections, and templates never
// reach this layer; the core resolves them before the records leave
// kaya_next_commands. A button's create record carries a click tag —
// opaque bytes this layer stores and emits verbatim; identity stays a
// core concern.

import SwiftUI

// Pinned to the KAYA_APPLY_* / KAYA_KIND_* / KAYA_VALUE_* constants in
// kaya.h (imported via the bridging header, but spelled here for use in
// switch patterns).
/// The protocol fingerprint this interpreter was written against
/// (KAYA_SPEC_HASH). Asserted against the host's kaya_spec_hash at
/// entry: check-verbs holds the SOURCE current, but only a runtime
/// assert catches a stale COMPILED dylib decoding new wire records
/// with old constants — the stale-artifact class, presentation side.
let kayaSpecHash: UInt64 = 0xc1ceb0f03be1e512

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

/// Window properties (their own namespace — windows are not widgets;
/// window 0 is the primary surface).
private let wpropTitle: UInt32 = 1
private let wpropWidth: UInt32 = 2
private let wpropHeight: UInt32 = 3
private let wpropVetoClose: UInt32 = 4
private let wpropSectionsPresentation: UInt32 = 5
private let wpropListDetail: UInt32 = 6
private let spropTitle: UInt32 = 1
private let spropIcon: UInt32 = 2
private let sectionsPresentationAuto: Int64 = 0
private let sectionsPresentationBar: Int64 = 1
private let sectionsPresentationSidebar: Int64 = 2
/// Navigation-entry properties (their own typed table; intercept_back
/// is the close-veto class transplanted to POP).
private let epropTitle: UInt32 = 1
private let epropInterceptBack: UInt32 = 2
/// The menu item vocabulary (spec enum "menu_kind"; DESIGN.md, Menus):
/// menu and radio_group are the grouping nodes, the rest are leaves.
private let menuKindMenu: UInt32 = 1
private let menuKindAction: UInt32 = 2
private let menuKindToggle: UInt32 = 3
private let menuKindRadioGroup: UInt32 = 4
private let menuKindRadioOption: UInt32 = 5
private let menuKindSeparator: UInt32 = 6
/// Menu properties (spec::MENU_PROPS) — their own typed table,
/// separate from widget, window, entry, and section props.
private let mpropLabel: UInt32 = 1
private let mpropEnabled: UInt32 = 2
private let mpropChecked: UInt32 = 3
private let mpropValue: UInt32 = 4
private let mpropIcon: UInt32 = 5
private let mpropPrimary: UInt32 = 6
private let mpropShortcut: UInt32 = 7
private let mpropRole: UInt32 = 8
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
/// Universal: every widget kind carries both.
private let propA11yId: UInt32 = 12
private let propA11yLabel: UInt32 = 13
private let propA11yHint: UInt32 = 14
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

@Observable
final class KayaNode: Identifiable {
    let id: UInt64
    let kind: UInt32
    let tag: [UInt8]
    var text = ""
    /// The accessibility identifier and label (universal props). The
    /// identifier is never spoken — it lowers to
    /// accessibilityIdentifier, the automation key — while the label
    /// IS what VoiceOver reads. Empty means unset: the platform keeps
    /// whatever it derives from the control's own content.
    var a11yId = ""
    var a11yLabel = ""
    var a11yHint = ""
    var checked = false
    var value = 0.0
    var minValue = 0.0
    var maxValue = 1.0
    // The image slot: the decoded native image (nil is the placeholder
    // class) and its size as the harness's "WxH" observation string
    // ("0x0" before a source lands or after a failed decode).
    var image: KayaPlatformImage?
    var imageSize = "0x0"
    // The scroll observations (scroll viewports only): the visible
    // extent, the content's extent, and the content's bottom edge in
    // the viewport's space — all geometry, recorded by the render's
    // readers, never a model copy.
    var scrollViewportH = 0.0
    var scrollContentH = 0.0
    var scrollContentMaxY = 0.0
    /// Progress-only: the platform's activity mode (Value carries
    /// the determinate fraction, reused from the slider).
    var indeterminate = false
    /// Grid-only: how many columns children fill row-major.
    var columns = 1
    /// This child's flex weight within its enclosing row/column. 0 is
    /// natural size; positive weights divide the leftover main-axis
    /// space in proportion. See Prop::Grow in protocol.rs.
    var grow = 0.0
    /// This container's inter-child gap on its main axis (containers
    /// only; the normalized default is 8). See Prop::Spacing.
    var spacing = 8.0
    /// This container's cross-axis child placement (containers only;
    /// wire values of the align spec enum; 0 = start, the normalized
    /// default). See Prop::Align.
    var align: Int64 = 0
    var children: [KayaNode] = []

    init(id: UInt64, kind: UInt32, tag: [UInt8]) {
        self.id = id
        self.kind = kind
        self.tag = tag
    }
}

/// One presentation surface: the primary (id 0, always present) or a
/// created auxiliary. Materializes hidden; mounting a root presents
/// it (aux ids reach openWindow(value:) at mount).
@Observable
final class KayaWindowModel: Identifiable {
    let id: UInt64
    var root: KayaNode?
    var title: String
    var width: Double?
    var height: Double?
    /// Who owns the chrome close — see WindowProp::VetoClose.
    var vetoClose = false
    /// The window's navigation stack, bottom to top (DESIGN.md,
    /// Navigation): pushed entries, exactly one visible (the top; the
    /// window's own root when empty). NavigationStack's path derives
    /// from this — the core-owned stack is the source of truth.
    var entries: [KayaEntryModel] = []
    /// The window's section set (add order) and selection: presentation
    /// context, not lifecycle — every section's root stays alive while
    /// covered. Non-empty sections render as the platform's switcher
    /// (TabView here) instead of the bare root.
    var sections: [KayaSectionModel] = []
    var selectedSection: UInt64?
    /// Whether this window presents its entry stack as list-detail
    /// (wprop 6; DESIGN.md, Adaptive list-detail). Adaptive by
    /// construction: this asks for the presentation, the SIZE CLASS
    /// decides which one materializes.
    var listDetail = false
    /// The presentation the view layer ACTUALLY rendered — "split" or
    /// "stacked" — stamped by the arm that ran, never derived from
    /// `listDetail` or `formFactor`. Deriving it would make the
    /// assertion agree with the lowering by construction and it could
    /// never catch the defect; that is the lesson menuPresentation
    /// already paid for.
    var splitPresentation = "stacked"
    /// The ADVISORY presentation hint (wprop 5): auto | bar | sidebar.
    var sectionsPresentation: Int64 = 0
    /// The window's command catalog (DESIGN.md, Menus): top-level
    /// grouping nodes in menubar-append order. macOS materializes the
    /// key kaya window's catalog as a native NSMenu segment; iOS folds
    /// it into the top bar's trailing More menu with promoted
    /// primaries as real bar actions.
    var menubar: [KayaMenuItemModel] = []
    /// The window's live FORM FACTOR, written by the view layer from
    /// the platform's own size-class reading and read by the harness.
    /// The adaptivity axis is THIS, never the operating system
    /// (DESIGN.md, "Form factor and adaptivity"): a phone is a compact
    /// window, an iPad is usually a regular one, and a narrow window on
    /// a desktop is compact. macOS has no size classes and its windows
    /// carry the menu bar unconditionally, so it reports `regular`.
    /// `unknown` is the pre-appearance value and no lowering may branch
    /// on it — it exists so the harness can tell "not yet observed"
    /// from "observed compact".
    var formFactor: KayaFormFactor = .unknown
    /// Which catalog lowering ACTUALLY rendered for this window. Each
    /// arm stamps its own value as it renders; nothing derives this
    /// from `formFactor`. That is the whole point — deriving it would
    /// make the harness verb agree with the lowering by construction,
    /// and the defect being gated is precisely the two disagreeing.
    var menuPresentation: KayaMenuPresentation = .none

    init(id: UInt64, title: String = "") {
        self.id = id
        self.title = title
    }
}

/// The window size classes kaya lowers against. Deliberately the
/// two-valued intersection of what every backend already exposes
/// (SwiftUI's horizontal size class, Compose's WindowSizeClass,
/// AdwBreakpoint, WinUI's adaptive triggers) rather than a new scale:
/// adopting the platforms' notion is the point.
enum KayaFormFactor: String {
    case unknown
    case compact
    case regular
}

/// How a window's command catalog is currently materialized. `bar` is a
/// real menu bar (the macOS NSMenu segment; the iPadOS 26 system menu
/// bar); `overflow` is the compact top-bar treatment; `none` is an
/// empty catalog.
enum KayaMenuPresentation: String {
    case none
    case bar
    case overflow
}

/// One menu item: kind fixed at create, every applicable prop live.
/// This model is the backend's retained MIRROR: user chrome writes
/// checked/value here BEFORE emitting (a native rebuild must start
/// from the post-user mirror — docs/traps.md), and programmatic
/// set_menu_prop writes land here QUIETLY (the echo doctrine).
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
    /// A standard-command role from the closed vocabulary, "" = none.
    /// macOS relocates `settings` into the application menu; the item
    /// keeps its authored place in the model, so paths and reads are
    /// unaffected by where the chrome ends up showing it.
    var role = ""
    /// Optional icon, used by phone promotion; ignored where native
    /// menu dress has no icon.
    var icon: KayaPlatformImage?
    var children: [KayaMenuItemModel] = []

    init(id: UInt64, kind: UInt32) {
        self.id = id
        self.kind = kind
    }
}

/// One section: a peer root inside a window's section set, user-
/// switched, ALL retained — switching is selection, not lifecycle,
/// and the grammar has no destruction verbs (a section dies only
/// with its window). Carries its own navigation stack: stacks are
/// per-surface (DESIGN.md, Sections).
@Observable
final class KayaSectionModel: Identifiable {
    let id: UInt64
    var root: KayaNode?
    var title = ""
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
    /// The close-veto class transplanted to POP: armed, the back
    /// affordance emits back_requested and nothing pops until the
    /// app answers with pop_entry.
    var interceptBack = false

    init(id: UInt64) {
        self.id = id
    }
}

@Observable
final class KayaSceneModel {
    /// Live surfaces by id. The primary starts with the process name
    /// as its title — exactly what an untitled WindowGroup shows.
    var windows: [UInt64: KayaWindowModel] = [
        0: KayaWindowModel(id: 0, title: ProcessInfo.processInfo.processName)
    ]

    var nodes: [UInt64: KayaNode] = [:]  // main actor only
    var parents: [UInt64: UInt64] = [:]
    /// Live navigation entries by surface id (they share the
    /// surface namespace with windows; mount targets either).
    /// `navEntries`, not `entries` — that name is the ENTRY-widget
    /// registry below.
    var navEntries: [UInt64: KayaEntryModel] = [:]
    /// entry id -> the window whose stack holds it.
    var entryWindow: [UInt64: UInt64] = [:]
    /// Live sections by surface id (the one namespace: windows,
    /// entries, sections), and section id -> hosting window.
    var sectionsById: [UInt64: KayaSectionModel] = [:]
    var sectionWindow: [UInt64: UInt64] = [:]
    /// Menu items by id — their OWN id space (never widget, node, or
    /// surface ids), the dispatch table keyed by item id.
    var menuItems: [UInt64: KayaMenuItemModel] = [:]
    /// child item id -> parent item id (grouping nodes only): the
    /// enablement AND-chain walks this.
    var menuParents: [UInt64: UInt64] = [:]
    /// Context catalogs by ANCHOR widget id: the root items attached
    /// through context_attach / context_attach_node (append order).
    var contextRoots: [UInt64: [KayaMenuItemModel]] = [:]
    /// The anchor copy's key-path bytes (the wire path encoding
    /// CONTEXT_ATTACH_NODE delivered) by widget id — the NOUN every
    /// activation from that anchor stamps; absent for live-widget
    /// anchors (the empty noun).
    var contextNouns: [UInt64: [UInt8]] = [:]
    // The focus command's landing spot: the entry view's FocusState
    // mirrors it into SwiftUI, and expect_focused reads it back.
    var focusedId: UInt64?
    // Per-kind registries in creation order (stamped copies included):
    // the harness names targets as kind#index.
    var buttons: [KayaNode] = []
    var checkboxes: [KayaNode] = []
    var labels: [KayaNode] = []
    var entries: [KayaNode] = []
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

// The single-window spellings, forwarding to the primary surface.
// An extension keeps them out of @Observable's macro expansion —
// observation still tracks through the stored `windows` dictionary.
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

/// Presentation actions and native handles, stashed from the view
/// side (main actor only). The apply arms drive them imperatively.
var kayaOpenWindow: ((UInt64) -> Void)?
var kayaDismissWindow: ((UInt64) -> Void)?
/// The live ScrollViewReader proxies by scroll node id (main actor):
/// how scroll_end drives the REAL scrolling API.
var kayaScrollProxies: [UInt64: ScrollViewProxy] = [:]
/// Grid cell leading edges by child node id, in the grid's own
/// coordinate space (main actor): the expect_grid_columns
/// observation clusters these — geometry, never the model's columns
/// copy.
var kayaCellMinX: [UInt64: Double] = [:]
/// Mounts that arrived before the environment actions were stashed
/// (a batch can apply before the first view appears): drained by
/// KayaRoot's onAppear.
var kayaPendingOpens: [UInt64] = []

/// Flake diagnostics (the panels-java aux-open ledger entry): absolute
/// timestamps on stderr so a leg log correlates with `log show`.
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

/// Present an auxiliary surface AT-LEAST-ONCE. Belt, not the fix:
/// the panels-java flake this was built for turned out to be the
/// accessor's registration racing window attachment (see
/// KayaWindowAccessor — the request itself was never observed
/// dropped). The belt stays because it is free and idempotent: a
/// value-identified WindowGroup is unique per value, so a duplicate
/// request focuses the one window. Bounded backoff; registration
/// (kayaNSWindows) is the delivered signal, and the exhausted case
/// logs a self-diagnosing state dump instead of going quiet.
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
                // Terminal, and self-diagnosing: if a matching window
                // shows in appWindows below, the scene request landed
                // and the REGISTRATION path failed (the flake class
                // viewDidMoveToWindow now closes); if it is absent,
                // the request itself was dropped — a class never yet
                // observed.
                kayaDiag("ensureOpen EXHAUSTED wid=\(wid) \(kayaDiagAppState())")
            }
        }
    #endif
}

/// The live modal alert (one per process): the request's identity for
/// the runner's reads and the emit; the platform dialog rides beside
/// it per-OS. Cleared when the one result fires.
struct KayaLiveAlert {
    let id: UInt64
    let window: UInt64
    let actions: Int
}
var kayaLiveAlert: KayaLiveAlert?
#if !os(macOS)
    var kayaLiveAlertController: UIAlertController?
    /// UIKit exposes no public button-press for UIAlertController, so
    /// alert_choose drives the REAL dismissal and then the SAME
    /// closure the pressed action would run (stored here at build).
    var kayaAlertAnswers: [String: () -> Void] = [:]
#endif
/// App-initiated teardown (destroy_window) bypasses the chrome-close
/// grammar: dismissWindow re-enters windowShouldClose, and without
/// this a veto window would emit a second close_requested for its
/// own confirmed destruction.
var kayaTearingDown: Set<UInt64> = []
#if os(macOS)
    var kayaLiveNSAlert: NSAlert?
    var kayaNSWindows: [UInt64: NSWindow] = [:]
    /// Parked waiters for window materialization, keyed by surface id
    /// (main-thread state like the registry): registration signals
    /// them, so an awaiting runner wakes ON the event rather than
    /// polling — the deadline below is only the failure bound.
    var kayaWindowWaiters: [UInt64: [DispatchSemaphore]] = [:]
    var kayaWindowDelegates: [UInt64: KayaWindowDelegate] = [:]

    /// Registers the hosting NSWindow for a surface id and installs
    /// the close-veto delegate proxy (SwiftUI owns the window's real
    /// delegate; the proxy answers windowShouldClose and forwards
    /// everything else).
    ///
    /// Registration is EVENT-DRIVEN on window attachment: the view
    /// subclass overrides viewDidMoveToWindow — AppKit's attachment
    /// signal — so registration cannot race the window's creation.
    /// (The one-shot `DispatchQueue.main.async { register }` this
    /// replaces was exactly such a race: under suite load the aux
    /// window attached AFTER the async drain, register's window guard
    /// returned silently, and nothing ever re-fired — the panels-java
    /// flake. The window existed, visible and titled, the whole time;
    /// only this registry was empty.)
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
                // (kayaAwaitWindow): the wait is event-driven — this
                // signal IS the event.
                for waiter in kayaWindowWaiters.removeValue(forKey: windowId) ?? [] {
                    waiter.signal()
                }
                let proxy = KayaWindowDelegate(
                    windowId: windowId, original: window.delegate)
                kayaWindowDelegates[windowId] = proxy
                window.delegate = proxy
                // The advisory size may predate the native window
                // (props apply while a surface is still hidden);
                // honor the pending request now that it exists.
                kayaApplyWindowSize(windowId)
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

/// The presentation-side functions, handed over by the host kaya rather
/// than resolved through the dynamic linker: hosts may carry kaya
/// statically or load it RTLD_LOCAL, so the vtable pins the one live
/// instance. Populated by kaya_swiftui_run.
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

    /// The user switched sections through the platform switcher —
    /// post-fact; the core's selection mirror reconciles inside this
    /// call. Programmatic selection never comes here (echo doctrine).
    static func emitSectionSelected(_ window: UInt64, _ section: UInt64) {
        api.emit_section_selected(window, section)
    }

    static func emitToggled(_ tag: [UInt8], _ checked: Bool) {
        tag.withUnsafeBufferPointer { buffer in
            api.emit_toggled(buffer.baseAddress, UInt(buffer.count), checked ? 1 : 0)
        }
    }

    /// A menu action fired — chrome click, shortcut, or harness verb:
    /// ONE occurrence, one dispatch path. `noun` is the wire path
    /// bytes CONTEXT_ATTACH_NODE delivered for a node-anchored context
    /// item (empty for bar and live-widget items) — the keys ARE the
    /// noun.
    static func emitMenuActivated(_ item: UInt64, _ noun: [UInt8]) {
        noun.withUnsafeBufferPointer { buffer in
            api.emit_menu_activated(item, buffer.baseAddress, UInt(buffer.count))
        }
    }

    /// A toggle item flipped by the user; `checked` is the NEW state
    /// (the model mirror was updated before this call — the post-user
    /// mirror rule). Programmatic checked writes never come here.
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

    static func emitText(_ tag: [UInt8], _ text: String) {
        let utf8 = Array(text.utf8)
        tag.withUnsafeBufferPointer { t in
            utf8.withUnsafeBufferPointer { s in
                api.emit_text_changed(t.baseAddress, UInt(t.count), s.baseAddress, UInt(s.count))
            }
        }
    }

    static func nextCommands(_ buffer: UnsafeMutablePointer<UInt8>, _ cap: Int) -> Int {
        Int(api.next_commands(buffer, UInt(cap)))
    }

    /// Fetch a blob's bytes by the handle an apply record carried,
    /// copied out of core memory. Handles are batch-local (the next
    /// next_commands call replaces the table), so callers fetch on the
    /// pump thread, within the batch. Nil for a dead handle.
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
            // replaces the core's table, and the main-queue apply may
            // run after that. Fetch every referenced blob here, on the
            // pump thread, within the batch; the bytes travel with it.
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
            at += size
        }
    }
    return blobs
}

/// The size request's macOS materialization: resize the primary
/// window's CONTENT to the requested DIP, keeping the current extent
/// on any axis the scene has not requested. iOS applies nothing —
/// the request is recorded and the system owns geometry.
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
                case kindEntry: kayaScene.entries.append(node)
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
                // window (u64; 0 = the primary surface), prop (u32),
                // pad, value. Size is an advisory request: macOS
                // resizes, iOS records (see DESIGN.md, Presentation
                // contexts).
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
                case (wpropListDetail, valueBool):
                    model?.listDetail = raw[body + 24] != 0
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
            case applyPresentAlert:
                // The platform's REAL modal dialog (NSAlert sheet /
                // UIAlertController), answered exactly once through
                // kaya_emit_alert_result — an action index or the
                // cancel sentinel (every native dismissal path).
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
                    kayaScene.nodes[id]!.text = kayaLF(String(decoding: bytes, as: UTF8.self))
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
                case (propSource, valueBlob):
                    // The value's payload is a u64 batch-local handle;
                    // the pump prefetched the bytes into `blobs`.
                    // Native decode: NSImage(data:)/UIImage(data:); a
                    // failed decode is nil — the placeholder class,
                    // never a crash — and imageSize stays "0x0".
                    let handle = raw.loadUnaligned(fromByteOffset: body + 24, as: UInt64.self)
                    let node = kayaScene.nodes[id]!
                    if let data = blobs[handle], let image = KayaPlatformImage(data: data) {
                        node.image = image
                        node.imageSize =
                            "\(Int(image.size.width))x\(Int(image.size.height))"
                    } else {
                        node.image = nil
                        node.imageSize = "0x0"
                    }
                default:
                    fatalError("kaya: cannot apply prop \(prop) with value type \(valueType)")
                }
            case applyAddChild:
                let parent = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let child = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt64.self)
                kayaScene.nodes[parent]!.children.append(kayaScene.nodes[child]!)
                kayaScene.parents[child] = parent
                // A choice widget's label children are its OPTIONS —
                // rows of the dropdown / entries of the radio group,
                // not standalone widgets — so they leave the
                // harness's label#N registry (their create arm
                // appended before this parent was known). Without
                // this, every label after one would shift index.
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
                    // An entry presents in-window: the push already put
                    // it on the stack; the mount fills it. No
                    // openWindow — nothing new materializes.
                    entry.root = kayaScene.nodes[root]
                    break
                }
                if let section = kayaScene.sectionsById[wid] {
                    // A section presents in-window too: added to the
                    // set already; the mount fills its pane.
                    section.root = kayaScene.nodes[root]
                    break
                }
                kayaScene.windows[wid]?.root = kayaScene.nodes[root]
                // Mounting presents: auxiliaries open here (the
                // primary's window is the WindowGroup's own). A mount
                // can precede the first view's appearance — park it
                // for the stash drain.
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
                // A destroyed anchor takes its context attachment with
                // it (menu ITEMS are never destroyed; the anchor map
                // entry is): a For-row removal must not leave the
                // harness's open-menu pointer dangling.
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
                    // Model-driven, like set_text: the node's text is
                    // the field's text, and the app hears the empty
                    // edit through the same emission the binding's set
                    // would make.
                    let node = kayaScene.nodes[id]!
                    node.text = ""
                    KayaHost.emitText(node.tag, "")
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
                // Programmatic pop: the core already reconciled its
                // stack; drop the top model and let the derived path
                // animate the NET change of the batch as one
                // transition (the multi-pop obligation).
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
                    // Day-one slot: decoded and rendered where the
                    // platform switcher shows icons; the tab TITLE is
                    // the harness observable, so the blob is accepted
                    // and title rendering stays authoritative.
                    break
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
                    // The phone-promotion hint: the promoted set
                    // recomputes from the observable catalog, so this
                    // write re-renders the iOS toolbar; inert on
                    // desktop.
                    item.primary = raw[body + 24] != 0
                case (mpropShortcut, valueStr):
                    let bytes = raw[(body + 24)..<(body + 24 + mvLen)]
                    item.shortcut = String(decoding: bytes, as: UTF8.self)
                case (mpropRole, valueStr):
                    // A standard-command role: macOS relocates the item
                    // into the application menu (the one place a role
                    // may enter dress-owned chrome); every other host
                    // leaves it where the app put it.
                    let bytes = raw[(body + 24)..<(body + 24 + mvLen)]
                    item.role = String(decoding: bytes, as: UTF8.self)
                case (mpropIcon, valueBlob):
                    // Used by phone promotion; ignored where native
                    // menu dress has no icon. Failed decode is the
                    // placeholder class, never a crash.
                    let handle = raw.loadUnaligned(fromByteOffset: body + 24, as: UInt64.self)
                    item.icon = blobs[handle].flatMap { KayaPlatformImage(data: $0) }
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

/// The interaction harness's Swift interpreter: the same line-oriented
/// grammar the Rust backends embed from tools/scenes (settle / click /
/// toggle / set_value / set_text / expect / expect_order /
/// expect_focused, targets as kind#index,
/// `;` accepted as a newline stand-in). The suites hand the script in
/// through KAYA_SELFTEST_SCRIPT; steps drive the node tree exactly as
/// a gesture would — flip the observable, emit through the host API.
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

/// Apply the two universal accessibility props to a widget's own view.
///
/// Applied to the CONTROL, never to a wrapping Group: SwiftUI treats a
/// transparent container's accessibility modifiers differently — a
/// label set on a Group did reach the element while an identifier set
/// the same way did not appear in the tree at all.
///
/// Empty means unset, and unset stays untouched: SwiftUI derives a
/// control's name from its own content, and stamping an empty string
/// would silence it. That derived name is exactly what this milestone
/// exists to prove kaya gets for free.
@ViewBuilder
func kayaA11y(_ view: some View, _ node: KayaNode) -> some View {
    // Containers need an explicit accessibility element first, or these
    // props do the wrong thing on them — both measured 2026-07-25:
    // an IDENTIFIER set on a container propagates DOWN and lands on its
    // first child, and a LABEL collapses the container into one element
    // and hides everything inside. `.contain` is the API for exactly
    // this: the container becomes its own element while its children
    // stay individually reachable, which is what a group means to an
    // assistive client.
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
    // The HINT: what activating this control does. Apple speaks it
    // after the label and forbids naming the gesture, which is why the
    // authored text is a verb phrase — the same string TalkBack reads
    // after its own "double tap to".
    if node.a11yHint.isEmpty {
        labelled
    } else {
        labelled.accessibilityHint(node.a11yHint)
    }
}

/// Normalize one platform role name into the harness's closed set. The
/// point of the verb is that the PLATFORM classified the control, so
/// anything kaya has no name for reports `unknown` rather than being
/// guessed at — an honest "the platform said something else" is a
/// finding, and a guess would hide one.
#if os(macOS)
    private func kayaAxRole(_ role: String?) -> String {
        switch role {
        case kAXButtonRole: return "button"
        case kAXStaticTextRole: return "label"
        case kAXTextFieldRole, kAXTextAreaRole: return "field"
        case kAXCheckBoxRole: return "checkbox"
        case kAXSliderRole: return "slider"
        case kAXImageRole: return "image"
        case kAXProgressIndicatorRole: return "progress"
        // A chooser is a chooser everywhere and spelled differently
        // everywhere: AXPopUpButton here, a dropdown role on Compose,
        // ComboBox on AT-SPI and UIA. `combobox` is the closed set's
        // one name for it (harness.rs check_ax).
        case kAXPopUpButtonRole: return "combobox"
        // NORMALIZED DOWN to the coarsest role every platform agrees
        // on. macOS publishes finer container roles than the others do
        // — a radio group is its own role here and a plain container of
        // choices elsewhere, a scroll area is a container of content —
        // and the closed set exists to make a scene read the same
        // everywhere, so the finer name is not information a scene can
        // use.
        case kAXRadioGroupRole, kAXScrollAreaRole: return "group"
        case kAXGroupRole: return "group"
        default: return "unknown"
        }
    }

    /// Read the tree the way an assistive client does: the AXUIElement
    /// CLIENT API against our own pid.
    ///
    /// The server-side NSAccessibility protocol is for SETTING
    /// accessibility, not reading it back — measured, not assumed: a
    /// server-side walk found the tree with correct roles but nil for
    /// every identifier and label, because those are materialized for
    /// the client API. Reading the server side would also have been the
    /// wrong test even if it worked, since it is not what VoiceOver
    /// sees.
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
        // walking children only ever reached the menu tree, never a
        // single widget.
        for child in kayaAxKids(element) {
            if let hit = kayaAxFind(child, identifier, depth + 1) { return hit }
        }
        return nil
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
        // WAIT FOR THE WINDOW, ON THE EVENT — never on a clock. The
        // scene's first step is an expect (check-steps enforces that,
        // and its bounded retry is the readiness wait), so the first AX
        // call can land while AppKit is still inside the appear/layout
        // pass that materializes the window. Reading your own process
        // then deadlocks rather than failing: the messaging timeout
        // does not save it, because a same-process read never reaches
        // the messaging layer. Measured 2026-07-25 — legs hung at 120s
        // with the trace showing `+0ms expect_ax` and the window
        // registering microseconds later.
        //
        // kayaAwaitWindow parks on the registration signal itself, so
        // this is the same event-driven wait the harness uses
        // everywhere else, not the `settle 300` that used to hide the
        // race at the top of the scene.
        _ = kayaAwaitWindow(0)
        // …then read ON THE MAIN THREAD. Reading your OWN process does
        // not go out through the messaging layer at all: measured
        // 2026-07-25 from a sampled deadlock, AXUIElementCopyAttributeValue
        // short-circuits into AppKit and runs
        // `-[NSObject _accessibilityValueForAttribute:]` INLINE on the
        // calling thread. That is main-thread-only API, so servicing it
        // on the harness thread while the main thread was in layout
        // inverted AppKit's own locks and hung the leg forever — and no
        // messaging timeout can bound a call that never sends a message.
        return DispatchQueue.main.sync { kayaAxReadOnMain(identifier) }
    }

    private func kayaAxReadOnMain(_ identifier: String) -> String? {
        let app = AXUIElementCreateApplication(getpid())
        // macOS builds the accessibility tree LAZILY: until an
        // assistive client attaches, an app publishes a skeleton —
        // correct top-level roles, but no content and no names. VoiceOver
        // announces itself with AXEnhancedUserInterface; third-party
        // assistive technology uses AXManualAccessibility. The harness
        // IS an assistive client here, so saying so is honest, and it is
        // the only way to read the tree a real client would receive.
        // EVERY AX CALL HERE IS BOUNDED, AND THE BOUND COMES FIRST.
        // Reading your own process is still a client/server round trip
        // serviced by the MAIN RUNLOOP, so a busy main thread blocks
        // the reader, and the default messaging timeout is long enough
        // to eat a whole leg.
        AXUIElementSetMessagingTimeout(app, 2.0)
        // ANNOUNCED ONCE PER PROCESS, not once per read. Setting these
        // is not a flag flip: AppKit rebuilds its whole accessibility
        // hierarchy in response, and that rebuild drives a full layout
        // pass. Re-announcing on every assertion therefore paid for
        // seventeen rebuilds in a seventeen-step scene.
        //
        // Measured 2026-07-25 under the mac lane's 8-wide pool: legs
        // hung past their 120s timeout with their windows registered,
        // while the same binary passed in a second standalone. A sample
        // of a stuck process put 100% of the main thread in
        // CA::Transaction::commit -> NSDisplayCycleFlush ->
        // -[NSView _layoutSubtreeWithOldSize:] — layout, not the AX
        // transport, which is why bounding the messaging timeout alone
        // did not fix it.
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
        guard let hit = kayaAxFind(app, identifier) else { return nil }
        let role = kayaAxRole(kayaAxCopy(hit, kAXRoleAttribute) as? String)
        // A control's spoken name is its DESCRIPTION when one was
        // authored and its TITLE when the control derived it from its
        // own content — both are what the client reads, so take the
        // authored one first and fall back to the derived one. STATIC
        // TEXT derives from neither: a label publishes nil for both and
        // carries its string in AXValue (measured 2026-07-25, which is
        // why `label#0` read `label/` before this), and VoiceOver
        // speaks that value. AXValue is a String only where it is text
        // — a slider's is a number, and the cast simply misses.
        let label =
            [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute]
            .lazy
            .compactMap { kayaAxCopy(hit, $0 as String) as? String }
            .first { !$0.isEmpty } ?? ""
        return role + "/" + label
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

    /// What [kayaAxRole] weighed, for a MISMATCH: `unknown/…` means the
    /// platform published a role the closed set has no name for, and
    /// the next question is always which one.
    private func kayaAxWhy(_ identifier: String) -> String {
        let app = AXUIElementCreateApplication(getpid())
        guard let hit = kayaAxFind(app, identifier) else { return "" }
        let role = kayaAxCopy(hit, kAXRoleAttribute as String) as? String ?? "nil"
        let subrole = kayaAxCopy(hit, kAXSubroleAttribute as String) as? String ?? "nil"
        return " (role=\(role) subrole=\(subrole))"
    }

#else
    /// UIKit has NO role vocabulary — that is the platform difference
    /// this arm exists for. macOS publishes AXRole, a first-class name
    /// per control; iOS publishes a TRAIT BITMASK plus the element's
    /// class, and the same trait rides several kinds (a toggle is a
    /// button that toggles, a chooser is a button that owns a menu).
    /// So the order below is not stylistic: the SPECIFIC signals must
    /// be weighed before `.button`, or every one of them reads as a
    /// plain button. All of it is measured — see the traits in each
    /// case.
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
        // (traits 512, measured): it is the only classification iOS
        // gives a progress indicator, since the element is not a
        // UIProgressView at all under SwiftUI.
        if traits.contains(.updatesFrequently) { return "progress" }
        // THE CHOOSER. iOS has no combo box: a menu-style picker is a
        // UIButton that OWNS A MENU (traits 1 — a plain button — on
        // class UIKitIconPreferringButton, measured). The menu is the
        // platform's own evidence that this is a chooser rather than a
        // button, so the question is asked of the control, not of
        // kaya's model.
        if let button = element as? UIButton, button.menu != nil { return "combobox" }
        if traits.contains(.button) { return "button" }
        if element is UITextView || element is UITextField { return "field" }
        if traits.contains(.staticText) { return "label" }
        // CONTAINERS. A scroll view is a container of content by class;
        // anything else that publishes accessibility ELEMENTS rather
        // than being one is a group — the same rule the Compose reader
        // applies to a node with children and no role of its own.
        if element is UIScrollView { return "group" }
        let count = element.accessibilityElementCount()
        if count != NSNotFound && count > 0 { return "group" }
        return "unknown"
    }

    /// UIKit publishes accessibility IN-PROCESS: the identifier lives on
    /// `UIAccessibilityIdentification`, and containers expose their
    /// elements through `UIAccessibilityContainer`. That is unlike
    /// macOS, where the server side returns nil for everything and the
    /// read has to go through the AXUIElement CLIENT API — the two
    /// Apple platforms genuinely differ here, which is why this arm is
    /// not a copy of the macOS one.
    /// The identifier as the ELEMENT publishes it. SwiftUI's own
    /// accessibility elements are not UIViews and do not formally
    /// conform to UIAccessibilityIdentification, so the typed cast
    /// misses them and the ObjC selector is the way in — measured
    /// 2026-07-25, when every node in a materialized tree reported a
    /// nil identifier through the cast alone.
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

    /// What the walk actually saw, printed ONCE on the first miss. A
    /// silent "not in the accessibility tree" costs a whole simulator
    /// round-trip per question, and every question here is about a tree
    /// whose shape cannot be guessed from the source.
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

    /// iOS builds its accessibility tree LAZILY, exactly as macOS does:
    /// until an assistive technology is running, SwiftUI's accessibility
    /// elements do not exist. Measured 2026-07-25 — every view in the
    /// hierarchy (UISwitch, UITextField, UISlider, the lot) reported
    /// `isAccessibilityElement=false`, zero accessibility elements and a
    /// nil identifier, so the walk below found nothing at all and every
    /// assertion read `<not in the accessibility tree>`.
    ///
    /// VoiceOver cannot be started from inside the app, but the AX
    /// runtime's AUTOMATION switch can be, and flipping it is what
    /// materializes the tree. This is the iOS spelling of the
    /// AXEnhancedUserInterface / AXManualAccessibility handshake the
    /// macOS arm performs a few lines up — the harness IS an assistive
    /// client, and saying so is what makes the read honest — and it is
    /// the same switch XCUITest, KIF and EarlGrey flip for the same
    /// reason.
    ///
    /// Resolved with dlsym rather than linked: nothing outside this
    /// harness path can reach it, and no shipped binary carries a
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
                    return kayaAxRole(hit) + "/" + (hit.accessibilityLabel ?? "")
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

    /// What [kayaAxRole] weighed, for a MISMATCH. UIKit has no role
    /// vocabulary — the classification is a trait bitmask plus the
    /// element's class — so `unknown/…` is never self-explaining, and
    /// the next question is always which traits and which class. One
    /// simulator round-trip per answer without this.
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
#endif

/// Resolves `kind#index` against the registry the verb reads, mirroring
/// harness.rs's parse_target: a kind that names a different registry, a
/// malformed index, or one out of range is a loud step failure — never
/// a trap, and never a silently misresolved read (`row#0` once indexed
/// the COLUMNS registry, which is the false-verdict class).
private func kayaTarget(_ spec: Substring, _ kind: String, _ registry: [KayaNode]) -> KayaNode? {
    let bits = spec.split(separator: "#")
    guard bits.count == 2, bits[0] == kind else { return nil }
    if bits[1] == "last" { return registry.last }
    guard let i = Int(bits[1]), registry.indices.contains(i) else { return nil }
    return registry[i]
}

/// An optional leading `window#N` token for the window verbs; the
/// remainder is the verb's own arguments. Implicit = the primary,
/// keeping the single-window observation spellings.
func kayaWindowTarget(_ parts: [Substring]) -> (UInt64, Bool, [Substring]) {
    if let first = parts.first, first.hasPrefix("window#"),
        let id = UInt64(first.dropFirst("window#".count))
    {
        return (id, true, Array(parts.dropFirst()))
    }
    return (0, false, parts)
}

#if os(macOS)
    /// The registered NSWindow for a surface id (the accessor fills
    /// the table); the primary falls back to the first app window
    /// for pre-registration reads.
    /// Await a surface's REAL NSWindow: materialization is async (the
    /// aux WindowGroup presents on SwiftUI's schedule, and under
    /// 8-wide suite load a slow-booting guest's aux window can lag
    /// the script by seconds — panels-java flaked exactly here). The
    /// wait is EVENT-DRIVEN, never a poll: the runner parks on a
    /// semaphore that window registration signals, so the wake is
    /// guaranteed to occur the moment the window exists; the deadline
    /// is only the failure bound (a window that never materializes
    /// must fail the leg, not hang it).
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

/// The observation contract compares Unicode SCALAR SEQUENCES —
/// byte-for-byte, the predicate every other interpreter computes.
/// Swift's `==` alone adds canonical equivalence (a precomposed é
/// equals its decomposed spelling), so an expect could pass here and
/// fail on every other platform for byte-identical inputs. The utf8
/// views compare code units, restoring the shared predicate.
private func kayaBytesEqual(_ a: String, _ b: String) -> Bool {
    a.utf8.elementsEqual(b.utf8)
}

/// Guest-visible text uses LF as its line separator on every platform
/// (strings are compared byte-for-byte across languages). The model
/// owns this backend's text, so normalization happens at every WRITE
/// into it — user edits and pastes through the bindings, the wire's
/// property write, the harness's set_text — and reads need none.
/// The cheap-out guard checks UNICODE SCALARS, not characters: Swift's
/// grapheme-based `String.contains("\r")` sees CRLF as one cluster
/// that does not "contain" CR, and would skip exactly the input this
/// function exists for. (The replacements below are UTF-16 literal
/// matches and are not affected.)
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
/// (harness.rs's parse_quoted_prefix, mirrored): expect_menu's path
/// precedes its state token and a menu label may contain spaces, so
/// whitespace-splitting before the quote would shear it. Honors the
/// same escapes as kayaQuoted; the remainder comes back with leading
/// whitespace stripped.
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

/// A menu path is labels joined with `>`: at least one label, every
/// segment non-empty and byte-exact — harness.rs's check_menu_path,
/// mirrored. No trimming: labels compare byte-for-byte, so a padded
/// segment is a typo that would only surface as a bewildering "no
/// such item" at runtime; reject it at parse instead. Returns the
/// failure text, nil when the path is well-formed.
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
    // The editable kinds: not reachable from context_open (the root
    // rejects that attach — their native edit menu is dress), but every
    // kind is addressable for accessibility, which is the point of a
    // universal prop.
    case "entry": return kayaTarget(spec, "entry", kayaScene.entries)
    case "textarea": return kayaTarget(spec, "textarea", kayaScene.textareas)
    default: return nil
    }
}

private func kayaRunScript(_ script: String) {
    var observed: [String] = []
    var failures: [String] = []
    // Recording handshake: when the runner exports KAYA_HARNESS_GATE
    // it is recording this window and holds the gate until its
    // recorder delivers a first frame — a leg must not outrun its
    // recording. Bounded; a no-op without the variable.
    if let gate = ProcessInfo.processInfo.environment["KAYA_HARNESS_GATE"] {
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: gate), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
    // THE TRACE MUST SURVIVE A KILL. stdout to a file is
    // block-buffered, so a leg killed at its timeout takes every step
    // it had logged down with it — the log then shows only the
    // backend's stderr and the hang looks like "never started".
    // Measured twice on 2026-07-25 before this line existed: two
    // accessibility legs died at 120s with no trace at all, and the
    // step they hung on was unknowable from the log. Line buffering
    // costs nothing here and makes a killed leg say where it stopped.
    setvbuf(stdout, nil, _IOLBF, 0)
    let start = Date()
    print("KAYA_HARNESS: epoch \(Int(start.timeIntervalSince1970 * 1000))")
    for rawLine in script.split(separator: "\n", omittingEmptySubsequences: true) {
        let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)
        if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") { continue }
        for raw in trimmedLine.split(separator: ";", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            let offset = Int(Date().timeIntervalSince(start) * 1000)
            print("KAYA_HARNESS: +\(offset)ms \(line)")
            // The observation contract (harness.rs is the norm):
            // every expect is a BOUNDED RETRY — each verb case
            // appends exactly one failure on a miss, so the wrapper
            // retracts it and re-runs the case until it passes or
            // the deadline lands the last failure text. Actions
            // never re-run; the FIRST expect doubles as the
            // scene-ready wait (scripts open with one).
            let stepDeadline = Date().addingTimeInterval(5.0)
            var retryStep = true
            while retryStep {
                retryStep = false
                let failuresBefore = failures.count
                switch parts[0] {
            case "settle":
                Thread.sleep(forTimeInterval: Double(parts[1])! / 1000)
            case "click":
                let ok = DispatchQueue.main.sync { () -> Bool in
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
                // The select's real change route in this interpreter
                // is the Picker's binding set — mirrored here exactly
                // as set_value mirrors the slider's: write the model
                // the binding reads, emit with the identity tag.
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
                        : kayaTarget(parts[1], "entry", kayaScene.entries)
                    guard let node else {
                        return false
                    }
                    node.text = kayaLF(kayaQuoted(Array(parts[2...])))
                    KayaHost.emitText(node.tag, node.text)
                    return true
                }
                if !ok { failures.append("no such target \(parts[1])") }
            case "expect":
                let want = kayaQuoted(Array(parts[2...]))
                // The target kind picks the observation: an entry reads
                // the field's own displayed text, an image its decoded
                // size ("WxH"/"0x0"), everything else reads label text
                // — harness.rs's routing.
                let got = DispatchQueue.main.sync { () -> String? in
                    parts[1].hasPrefix("textarea")
                        ? kayaTarget(parts[1], "textarea", kayaScene.textareas)?.text
                        : parts[1].hasPrefix("entry")
                        ? kayaTarget(parts[1], "entry", kayaScene.entries)?.text
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
                                            // The selected option's LABEL
                                            // — what the control shows
                                            // (child order is option
                                            // order).
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
            case "expect_focused":
                // The model's focusedId is the observation the focus
                // command lands as (the entry view's FocusState mirrors
                // it into SwiftUI). Counts as an expect for the
                // zero-expect rule, exactly as in harness.rs.
                let focused = DispatchQueue.main.sync { () -> Bool? in
                    let node =
                        parts[1].hasPrefix("textarea")
                        ? kayaTarget(parts[1], "textarea", kayaScene.textareas)
                        : kayaTarget(parts[1], "entry", kayaScene.entries)
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
                // The container's label children in child order, joined
                // with `|` — reads the tree the moves actually edited,
                // which the creation-ordered registries cannot see.
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
            case "expect_shares":
                // The container's children as whole-percentage shares of
                // their sum — the observation grow weights are verified
                // by. Percent of the children's sum and not of the
                // container, so spacing and padding (platform metrics
                // both) stay out of the number; the rounding matches
                // harness::shares exactly, because expect_shares
                // compares byte-for-byte across all seven backends.
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
                // The primary window's section count from the
                // switcher's item source (the model the TabView
                // enumerates — SwiftUI's tab bar has no separate
                // item registry to read).
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
                // The REAL materialized title, never the model's copy
                // on macOS — a backend that ignored the write must
                // fail. An explicit window#N target prefixes the
                // observation; the implicit form keeps the primary's
                // single-window spelling.
                let (wid, explicit, rest) = kayaWindowTarget(Array(parts[1...]))
                let want = kayaQuoted(rest)
                let prefix = explicit ? "window#\(wid) " : ""
                #if os(macOS)
                    // Await the REAL window first (materialization is
                    // async; see kayaAwaitWindow) — then read its
                    // title bar only; the model fallback is for the
                    // primary's pre-registration reads.
                    if explicit { _ = kayaAwaitWindow(wid) }
                #endif
                let got = DispatchQueue.main.sync { () -> String in
                    #if os(macOS)
                        if let window = kayaTitleWindow(wid) {
                            return window.title
                        }
                        return wid == 0 ? kayaScene.windows[0]?.title ?? "" : ""
                    #else
                        // iOS has no title bar; the surface-title read
                        // is the model that feeds UIScene.title — and
                        // while a navigation entry covers the window,
                        // the entry's title is the visible one (the
                        // nav bar's), exactly as the macOS window
                        // title reads.
                        if let top = kayaScene.windows[wid]?.entries.last {
                            return top.title
                        }
                        return kayaScene.windows[wid]?.title ?? ""
                    #endif
                }
                if kayaBytesEqual(got, want) {
                    observed.append("\(prefix)title \"\(want)\"")
                } else {
                    failures.append("\(prefix)title \"\(got)\", wanted \"\(want)\"")
                }
            case "expect_window_size":
                // The surface's REAL content extent against the
                // advisory request, within 2pt. Reads the window, not
                // the offer reader (the offer sits inside the root
                // inset).
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
                // The user's back affordance: drive the SAME
                // path-shortening write the toolbar back button and
                // swipe-back make, so interception and the post-fact
                // reconcile run exactly as a user pop. Silent, like
                // click.
                let (wid, _, _) = kayaWindowTarget(Array(parts[1...]))
                DispatchQueue.main.sync {
                    let depth = kayaScene.windows[wid]?.entries.count ?? 0
                    kayaUserPops(wid, to: max(0, depth - 1))
                }
            case "expect_grid_columns":
                let want = Int(parts[2])!
                let off = DispatchQueue.main.sync { () -> String? in
                    guard let grid = kayaTarget(parts[1], "grid", kayaScene.grids) else {
                        return nil
                    }
                    // Geometry, never the model's columns copy: the
                    // distinct leading-edge clusters of the cells ARE
                    // the columns, and clustering within 2pt asserts
                    // per-column alignment in the same breath.
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
            case "expect_alert":
                // The REAL presented dialog's title (NSAlert's
                // messageText / the UIAlertController's title), never
                // the request's copy — a backend that materialized
                // nothing must fail here.
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
                // Drive the REAL answer path: on macOS press the
                // native button (performClick — Esc and click share
                // it); on iOS the real dismissal plus the SAME
                // closure the pressed action runs (UIKit exposes no
                // public press). Silent, like click.
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
            case "expect_root_fills":
                // The mounted root fills the area the window offered it
                // — the observation shares can never make: a share is a
                // percentage of the children's sum, total-invariant by
                // construction, so a hugging root still splits 25/75.
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
                // font-metric offset), never from the model's align
                // field — a backend that ignored the write must fail.
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
                    // Multi-match is ambiguity, and ambiguity fails
                    // loudly — a first-match answer lets an
                    // unseparated scene pass while proving nothing.
                    var matches: [String] = []
                    if rects.allSatisfy({ abs($0.1 - inner) <= 2 }) { matches.append("stretch") }
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
                        // A row that LOOKS baseline-aligned but reads
                        // mixed is usually the recording, not the
                        // geometry: the alignmentGuide hooks only run
                        // when a guide is queried (docs/traps.md), so
                        // name the recorded count in the verdict.
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
                // The container's children span its content box — the
                // leftover-consumption half of the grow contract, which
                // shares (total-invariant) and root_fills (root-level
                // only) can never see. Span = the tracks KayaFlex
                // actually assigned plus the 8-unit gaps, against the
                // container's own rendered extent; the pass observation
                // matches harness.rs byte-for-byte.
                let slack = DispatchQueue.main.sync { () -> String? in
                    let isRow = parts[1].hasPrefix("row")
                    guard
                        let container = kayaTarget(
                            parts[1], isRow ? "row" : "column",
                            isRow ? kayaScene.rows : kayaScene.columns)
                    else { return nil }
                    guard let extent = kayaContainerExtents[container.id], extent > 0 else {
                        return "no container layout recorded"
                    }
                    let tracks = container.children.map { kayaMainExtents[$0.id] ?? 0 }
                    let span =
                        tracks.reduce(0, +) + container.spacing * Double(max(0, tracks.count - 1))
                    if abs(span - extent) <= 2 { return "" }
                    return "children span \(Int(span.rounded()))pt of \(Int(extent.rounded()))pt"
                }
                switch slack {
                case ""?:
                    observed.append("\(parts[1]) fills")
                case let s?:
                    failures.append("\(parts[1]) leaves leftover (\(s))")
                case nil:
                    failures.append("no such target \(parts[1])")
                }
            case "expect_menus":
                // The top-level catalog count from the REAL
                // materialized bar on macOS (the owned NSMenu segment
                // actually sitting in NSApp.mainMenu), the overflow's
                // group list on iOS (the model the More menu
                // enumerates — the expect_sections precedent).
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
                // accessibility tree. Deliberately routed through the
                // identifier rather than reading the node: an element
                // the platform never published simply is not found, and
                // that failure is the point of the verb.
                let wantAx = kayaQuoted(Array(parts[2...]))
                // The identifier is resolved on the main thread (scene
                // state lives there), but the AX READ ITSELF runs on the
                // harness thread ON PURPOSE. Accessibility requests are
                // serviced BY the app's main runloop, so querying
                // yourself from inside main.sync leaves nothing able to
                // answer: AppKit chrome still replies from cache, while
                // SwiftUI's lazily-materialized elements come back empty
                // — which is exactly the empty AXHostingView subtree
                // this cost an afternoon to explain.
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
                    // The platform's own classification rides the
                    // failure: `unknown/…` is never self-explaining, and
                    // the answer is one platform round-trip away
                    // otherwise.
                    let why = identifier.flatMap { $0.isEmpty ? nil : kayaAxWhy($0) } ?? ""
                    failures.append("ax \(gotAx), wanted \(wantAx)\(why)")
                }
            case "expect_menu_presentation":
                // `<size class>/<presentation>`. macOS reads the REAL
                // bar (there are no size classes there, and a desktop
                // window carries the global bar unconditionally, so the
                // class is always regular). Elsewhere both halves come
                // off the window model, where the view layer stamped
                // the platform's size-class reading and the arm that
                // actually rendered — never a derivation from the
                // other half, which would make this verb agree with
                // the lowering by construction.
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
                        // HONEST LIMITATION, recorded rather than
                        // hidden. Every other backend reads its real
                        // chrome. iOS cannot: the iPadOS menu bar is
                        // built LAZILY — measured, buildMenu runs once
                        // at launch with an empty catalog and never
                        // again, however many times setNeedsRebuild is
                        // called — because UIKit defers it until the
                        // bar is about to be PRESENTED, and the bar
                        // stays hidden until a swipe or hover. UIKit
                        // exposes no way to present a menu
                        // programmatically, so a headless scene can
                        // never witness the build.
                        //
                        // So this one half is ARM-DERIVED on
                        // iOS-regular: it reports the lowering this
                        // window selected, not a reading of the
                        // rendered bar. The bar itself was confirmed
                        // by eye on an iPad Pro (2026-07-25). The real
                        // observation arrives with the accessibility
                        // verb — a menu bar is an AX element, so
                        // reading the platform tree restores an
                        // independent check. Until then this cannot
                        // catch a regression in the BUILD; it can
                        // still catch one in the ARM CHOICE, which is
                        // what the original defect was.
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
                    // The BARE form: assert only the invariant, and
                    // report a LANE-INDEPENDENT string — a shared scene
                    // compares observations byte-for-byte across every
                    // platform, so it cannot echo a value that
                    // legitimately differs. Asymmetric on purpose: a
                    // compact window showing a bar is fine.
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
            case "expect_menu":
                // Real item state wherever the item surfaced (bar,
                // More, open context menu); the bounded retry doubles
                // as the wait for a catalog rebuild to land.
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
            case "menu_activate":
                // An action, silent like click. The OPEN context menu
                // owns resolution while presented (a leaf fires once
                // and the menu closes); otherwise macOS walks the
                // owned NSApp.mainMenu segment by title and performs
                // the item's REAL target/action (the ruled verdict —
                // no model-route fallback), and iOS resolves through
                // the same catalog helper the toolbar consumes, so a
                // promoted primary resolves WITHOUT opening More.
                let restLine = String(line.dropFirst(parts[0].count))
                // Trailing junk after the quoted path is line-noise,
                // not a no-op (harness.rs's parse_string floor; the
                // Compose sibling's rejection).
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
                        kayaMenuUserActivate(item, noun: noun)
                        return nil
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
                // An action, silent like click: opens the anchor's
                // context catalog for the following menu_activate.
                // Editable text is rejected up front — its native
                // menu is dress (harness.rs's guard, mirrored).
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
                // An action, silent like click: macOS synthesizes the
                // key event through NSMenu.performKeyEquivalent (the
                // real key-equivalent walk); iOS traverses the
                // interpreter's one dispatch table. Both land in the
                // SAME menu_activated the item's direct activation
                // emits.
                let restLine = String(line.dropFirst(parts[0].count))
                // The grammar floor, mirrored from harness.rs: an
                // empty spelling, whitespace inside the spelling, and
                // trailing junk after the quote are line-noise, not
                // no-ops (the Compose sibling's one rejection).
                guard let (spelling, tail) = kayaQuotedPrefix(restLine), tail.isEmpty,
                    !spelling.isEmpty, !spelling.contains(where: { $0.isWhitespace })
                else {
                    failures.append("shortcut wants a quoted spelling: \(line)")
                    break
                }
                let unowned: Bool = DispatchQueue.main.sync {
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
                if failures.count > failuresBefore, parts[0].hasPrefix("expect"),
                    Date() < stepDeadline
                {
                    failures.removeLast(failures.count - failuresBefore)
                    Thread.sleep(forTimeInterval: 0.02)
                    retryStep = true
                }
            }
        }
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
    // THE UNMOUNTED-SCENE DIAGNOSIS. A scene that creates widgets and
    // never calls mount(root) renders an EMPTY window, and every
    // assertion then measures an invisible app. Target resolution
    // cannot catch it — the widgets exist in the model, so `kind#index`
    // resolves happily and the reads simply describe nothing.
    //
    // Checked HERE rather than before the run, for two reasons: at
    // script start the guest's transactions have not arrived yet, so
    // the scene legitimately looks empty (the first attempt at this
    // guard fired never); and on the failure path it cannot
    // false-positive on a scene that mounts late.
    //
    // This cost most of an afternoon on 2026-07-25: a missing mount
    // produced an empty accessibility tree, which was then misdiagnosed
    // in turn as an SDK-generation problem, a language problem, and a
    // missing macOS API — three wrong conclusions, all downstream of
    // one silent omission that no gate mentioned.
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

/// The main-axis extent each node's TRACK was allocated, by node id —
/// what `expect_shares` reads back.
///
/// Written by KayaTrackReader, never from inside a layout pass: SwiftUI
/// runs speculative passes at arbitrary sizes and delivers them in no
/// useful order — a natural-width pass arriving after the real one once
/// clobbered a correct 25/75 into 26/74 (and before that, zero-size
/// passes clobbered 96/286 into 0/0). Geometry only ever describes the
/// rendered result, so the readers cannot lie that way. Main-actor
/// only, like the rest of the scene model.
var kayaMainExtents: [UInt64: Double] = [:]

/// The invisible frame each flex child rides in IS the track KayaFlex
/// assigned (the frame accepts the track proposal; the child aligns
/// top-leading inside it, the normalized cross-axis default). The
/// reader records the frame's geometry — the layout rect, never the
/// child's drawn size, which several controls inflate or hug.
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
/// `expect_fills` compares its children's tracks against. Same
/// geometry-only discipline as the track extents: never written from a
/// layout pass. Main-actor only.
var kayaContainerExtents: [UInt64: Double] = [:]

/// Each container's CROSS-axis extent, and each child's cross-axis
/// (start, extent) in its container's named coordinate space — what
/// `expect_aligned` classifies from. Baseline offsets are the
/// distance from a text child's top to its first baseline, recorded
/// through an identity alignmentGuide hook: that value is a font
/// metric for single-line text, invariant across speculative layout
/// passes, so the recording trap does not apply.
var kayaContainerCross: [UInt64: Double] = [:]
var kayaCrossRects: [UInt64: (Double, Double)] = [:]
var kayaBaselineOffsets: [UInt64: Double] = [:]

/// Records one child's cross rect in the enclosing container's named
/// space (the reader rides the CHILD, inside the track frame, so it
/// sees the aligned box, not the track).
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
    }
}

/// The container-extent sibling of KayaTrackReader: a background
/// reader on the container view itself (either branch — flex or
/// stock stack), recording its rendered main-axis extent.
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

/// The mounted root's rendered size and the area the window offered it
/// — what `expect_root_fills` compares. Both come from GeometryReaders
/// (the offer from the reader wrapping KayaRoot's content, which fills
/// what it is proposed; the root from a background reader on the
/// mounted container), so neither can be clobbered by a speculative
/// layout pass — geometry only ever describes the rendered result.
/// Main-actor only, like the rest of the scene model.
var kayaRootSize = CGSize.zero
var kayaAvailableSize = CGSize.zero

/// SwiftUI's half of the `grow` contract.
///
/// VStack/HStack cannot express it: SwiftUI's only per-child knob is
/// `layoutPriority`, which is *ordinal* — it decides who gets scarce
/// space first, not in what proportion — so a 1:3 request is
/// unrepresentable with the built-in stacks. The Layout protocol is the
/// blessed way to add a layout policy, and it lets the same arithmetic
/// every other backend performs be written once here.
///
/// The policy is [`Prop::Grow`]: weight-0 children take their natural
/// main-axis size, and the growers divide what is left in proportion to
/// their weights, their own natural sizes not entering the division.
/// The flex track's cell. It accepts the rect KayaFlex assigns —
/// fills what it is offered, hugs when measured — and places its
/// child by proposing the FULL cell, never the child's own fitted
/// size. It replaces the alignment-frame idiom
/// (`.frame(maxWidth: .infinity, alignment:)`), whose placement
/// re-proposes the child its fitted ideal: a hugging stack proposed
/// exactly its ideal runs the platform stack's fair-share division
/// with zero slack — the division asks the button before the label
/// releases its surplus — and a conforming control absorbs the
/// shortfall (a bordered button wraps mid-word; a rigid bridge
/// overflows its slot). The in-vivo probe that pinned this is quoted
/// in docs/deferred.md's KayaCell entry. Cross-axis placement:
/// start/stretch/baseline lead, center centers, end trails — the
/// mapping the old frame-alignment tables encoded; the main axis
/// always starts.
struct KayaCell: Layout {
    /// The CONTAINER's axis: true for a column's cells.
    let vertical: Bool
    /// The container's cross-axis align mode.
    let align: Int64

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let natural = subviews[0].sizeThatFits(.unspecified)
        return CGSize(
            width: proposal.width ?? natural.width,
            height: proposal.height ?? natural.height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let full = ProposedViewSize(width: bounds.width, height: bounds.height)
        let size = subviews[0].sizeThatFits(full)
        // The baseline-recording hooks are alignmentGuide closures,
        // and guide closures only run when somebody QUERIES a guide —
        // the alignment frames this layout replaced used to be that
        // somebody. Query .top explicitly: a stack derives its guide
        // from its children, so the query cascades into a row's text
        // children and their recording closures.
        _ = subviews[0].dimensions(in: full)[VerticalAlignment.top]
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
        subviews[0].place(
            at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
            anchor: .topLeading, proposal: full)
    }
}

struct KayaFlex: Layout {
    let vertical: Bool
    let spacing: CGFloat
    /// Parallel to `subviews`, in the same order — the weights live on
    /// the model, not on the views.
    let nodes: [KayaNode]
    /// Whether to fill the cross axis as well as the main one. True only
    /// for the mounted root, which fills its window the way AppKit's
    /// contentView and UIKit's root view do by construction. Nested
    /// containers hug their cross axis: a row is as tall as its tallest
    /// child, not as tall as the column it sits in.
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
        // Fill what we are offered when a size is proposed, and hug when
        // it is not. Filling is what creates the free space the growers
        // divide — and it is what the other backends do, where a stack
        // has no intrinsic size and stretches to its parent while its
        // children keep their own.
        // Fill the MAIN axis from the proposal — that is what creates
        // the free space the growers divide — and hug the cross axis.
        // Filling both made a row claim its column's whole height, which
        // showed up in the recording as a band of empty space around the
        // slider row.
        let mainExtent = proposal.replacingUnspecifiedDimensions(
            by: CGSize(width: naturalMain, height: naturalMain))
        let filledMain = vertical ? mainExtent.height : mainExtent.width
        let filledCross = vertical ? mainExtent.width : mainExtent.height
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
            // The cross axis is offered the container's full extent and
            // the child decides: a nested container fills it, a label
            // keeps its intrinsic width. That reproduces the stack
            // behaviour the other backends have natively.
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

/// The align enum onto SwiftUI's stack alignments. Baseline maps only
/// on rows (the scene core rejects it on columns); a flex row renders
/// baseline as firstTextBaseline placement inside each track frame.
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

struct KayaRender: View {
    let node: KayaNode
    /// The mounted root fills its window; nested containers do not.
    var isRoot = false

    var body: some View {
        // The widget/node anchor: a context catalog attached to this
        // node rides .contextMenu on its view — the platform's own
        // gesture (right-click on macOS, long-press on iOS). Editable
        // text never reaches here (the root rejects the attach; its
        // native edit menu is dress).
        // The accessibility props ride EVERY kind, applied at the one
        // place every node's view passes through — containers included,
        // which is the point: an assistive client sees a labelled group,
        // and the harness can address one.
        //
        // Empty means unset, and unset must stay untouched rather than
        // written as "": SwiftUI derives a control's label from its own
        // content (a Button's title), and stamping an empty label would
        // SILENCE it. The whole milestone exists to prove the free
        // accessibility the wrap-native bet gives us; clobbering it here
        // would be the exact opposite.
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
            // VStack unless a child actually carries a weight. The
            // custom Layout can express grow and VStack cannot, but it
            // also replaces SwiftUI's own stack behaviour wholesale —
            // and the point is that each platform flows like itself, not
            // that all seven produce the same pixels. So the toolkit
            // keeps the layout until a scene asks for something the
            // toolkit has no way to say.
            // The root always takes the flex path: it has to FILL its
            // window — the same normalization GTK needed — and a VStack
            // returns its natural size however large a frame it is
            // offered, so nothing below it would ever have leftover
            // space to divide. Nested containers keep VStack until one
            // of their own children actually grows.
            Group {
                if isRoot || node.children.contains(where: { $0.grow > 0 }) {
                    KayaFlex(vertical: true, spacing: node.spacing, nodes: node.children, fillCross: isRoot) {
                        ForEach(node.children) { child in
                            // The cell fills the track KayaFlex proposes; the
                            // reader on it records the track's geometry (see
                            // KayaTrackReader). The inner frame is the stretch
                            // box; every other mode places in KayaCell.
                            KayaCell(vertical: true, align: node.align) {
                                KayaRender(node: child)
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
                            KayaRender(node: child)
                                .background(
                                    KayaCellReader(id: child.id, parent: node.id, vertical: true)
                                )
                                .frame(maxWidth: node.align == alignStretch ? .infinity : nil)
                        }
                    }
                }
            }
            .coordinateSpace(name: "kaya-box-\(node.id)")
            .background(KayaBoxReader(id: node.id, vertical: true))
        case kindButton:
            // The dressed floor. macOS bridges to NSButton: in a
            // process whose main executable is stamped with a pre-26
            // SDK, SwiftUI's Button lays out at borderless metrics
            // while the AppKit bridge paints the bezel over them —
            // under EVERY style (automatic, bordered, prominent all
            // probed 38x20-vs-52x32, kaya-free) — and vendor-hosted
            // runtimes sit on such stamps permanently. iOS keeps
            // SwiftUI's Button: it measures what it draws (probed at
            // every proposal, .unspecified included); the bordered
            // style is the chrome, and KayaCell keeps the proposals
            // around it honest.
            #if os(macOS)
                KayaMacButton(title: node.text, tag: node.tag)
                    .alignmentGuide(.top) { d in
                        kayaBaselineOffsets[node.id] = d[.firstTextBaseline] - d[.top]
                        return d[.top]
                    }
            #else
                Button(node.text) {
                    KayaHost.emit(node.tag)
                }
                .buttonStyle(.bordered)
                .alignmentGuide(.top) { d in
                    kayaBaselineOffsets[node.id] = d[.firstTextBaseline] - d[.top]
                    return d[.top]
                }
            #endif
        case kindRow:
            // Normalized: 8-unit spacing, top (cross-axis start).
            // HStack until a weight appears — see the column arm.
            Group {
                if isRoot || node.children.contains(where: { $0.grow > 0 }) {
                    KayaFlex(vertical: false, spacing: node.spacing, nodes: node.children, fillCross: isRoot) {
                        ForEach(node.children) { child in
                            KayaCell(vertical: false, align: node.align) {
                                KayaRender(node: child)
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
                            KayaRender(node: child)
                                .background(
                                    KayaCellReader(id: child.id, parent: node.id, vertical: false)
                                )
                                .frame(maxHeight: node.align == alignStretch ? .infinity : nil)
                        }
                    }
                }
            }
            .coordinateSpace(name: "kaya-box-\(node.id)")
            .background(KayaBoxReader(id: node.id, vertical: false))
        case kindLabel:
            Text(node.text)
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
            // SwiftUI's Slider has no natural width — unconstrained it
            // swallows whatever a stack offers — so 200 stands in as the
            // intrinsic size every other toolkit's slider has. A grower
            // must NOT keep that cap: its extent is the track KayaFlex
            // assigned, and capping the drawn control below its track
            // rendered a 1:3 row as 38/62 while expect_shares (which
            // reads the track, correctly) kept passing.
            .frame(maxWidth: node.grow > 0 ? .infinity : 200)
        case kindEntry:
            KayaEntry(node: node)
        case kindTextarea:
            KayaTextarea(node: node)
        case kindSelect:
            // The dressed floor: SwiftUI's own Picker in its menu
            // presentation — the platform dropdown. The node's label
            // children are its options (their text, in child order);
            // the node mirrors the selected index (SwiftUI needs the
            // binding), and every pick is emitted with the select's
            // identity tag — the slider's uncontrolled contract.
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
                    Text(option.text).tag(index)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        case kindGrid:
            // The 2D layout contract: SwiftUI's own Grid — columns
            // take their natural width, aligned across rows. The
            // node's children chunk row-major by its columns count;
            // each cell records its leading edge for the geometry
            // observation.
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
        case kindRadio:
            // The choice contract in its inline presentation. The
            // dressed floor per platform: macOS renders the REAL
            // radio group (Picker's radioGroup style); iOS has no
            // radio idiom — its native spelling of one-of-N inline
            // is the segmented control.
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
                    Text(option.text).tag(index)
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
            // The vertical scroll viewport over its ONE child (the
            // scene enforces the count). ScrollViewReader's proxy is
            // the REAL scrolling API scroll_end drives; the geometry
            // readers record viewport, content, and the content's
            // bottom edge in the viewport's space — the overflow and
            // at-end observations.
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
            // Fixed to the decoded image's intrinsic size (no
            // .resizable()), matching the harness's size observation;
            // nil is the placeholder class — nothing renders.
            if let image = node.image {
                #if os(macOS)
                    Image(nsImage: image)
                #else
                    Image(uiImage: image)
                #endif
            } else {
                EmptyView()
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
    /// SwiftUI's Button. In a process whose main executable is stamped
    /// with a pre-26 SDK — every non-Apple guest runtime: rust, go,
    /// JVM, .NET hosts — SwiftUI 26's compatibility path measures
    /// Button at its borderless metrics (38x20 for a 13pt caption)
    /// while drawing the bezeled control (52x32), and every container
    /// that consults sizeThatFits inherits the lie: the bezel
    /// overflows its layout slot and the caption truncates to an
    /// ellipsis. An AppKit control cannot disagree with itself —
    /// fittingSize IS the drawn size, in both design generations,
    /// under every host stamp — so the floor stays uniform across all
    /// guest languages. No style escapes the compat lie: automatic,
    /// bordered, and borderedProminent all measure 38x20 there.
    private struct KayaMacButton: NSViewRepresentable {
        let title: String
        let tag: [UInt8]

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
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize, nsView: NSButton, context: Context
        ) -> CGSize? {
            nsView.fittingSize
        }
    }
#endif

/// The window's navigation path, DERIVED from the core-owned stack:
/// the getter maps the model, and the setter is the user-pop
/// interception point — SwiftUI writes a shorter path when the back
/// affordance fires (the toolbar back button, swipe-back), and the
/// model decides what actually pops.
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

/// A user-driven pop down to `depth` entries: pop unarmed tops one at
/// a time — each reconciling the core-owned stack post-fact through
/// emitEntryPopped — and STOP at an intercept_back-armed entry:
/// nothing pops there, back_requested fires instead, and the derived
/// path snaps the view back to the retained stack (the veto class,
/// materialized; the app answers with pop_entry if it agrees).
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
// One item vocabulary, two anchors. The WINDOW anchor rides the window
// model (menubar); macOS materializes the key kaya window's catalog as
// a Kaya-owned native NSMenu segment (SwiftUI's pinned CommandsBuilder
// has no buildArray, so it cannot express append-at-any-time top-level
// catalogs — the ruled lowering), while iOS folds the catalog into a
// trailing More menu with promoted primaries as real bar actions. The
// WIDGET/NODE anchor is .contextMenu on the anchored node's view.
// Echo doctrine: ONE dispatch path — user chrome, shortcuts, and
// harness verbs land in kayaMenuUserActivate and emit; programmatic
// set_menu_prop writes mutate the model silently in the apply arm.

/// The harness's OPEN context menu: context_open records the anchor
/// here and the following menu_activate resolves against it (main
/// actor, like the rest of the presentation state).
var kayaOpenContextWidget: UInt64?

/// The interpreter's shortcut dispatch table: canonical spelling ->
/// action item id, rebuilt from the presented catalog on every menu
/// change. On iOS the `shortcut` verb traverses THIS table (the one a
/// hardware key event would feed); on macOS dispatch is the real
/// NSMenu key-equivalent walk and the NSMenuItems carry the chords.
var kayaShortcutItems: [String: UInt64] = [:]

/// The phone bar's promotion capacity: k is the PLATFORM's idiom
/// (never computed by kaya) — two trailing actions beside More is the
/// iOS top-bar shape. Inert on macOS.
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
    return enabled
}

/// Catalog preorder: top-level grouping nodes in menubar-append order,
/// then each node's children in append order, depth-first. Creation
/// time is irrelevant — this order alone decides phone promotion.
func kayaCatalogPreorder(_ items: [KayaMenuItemModel]) -> [KayaMenuItemModel] {
    var out: [KayaMenuItemModel] = []
    func walk(_ item: KayaMenuItemModel) {
        out.append(item)
        for child in item.children { walk(child) }
    }
    for top in items { walk(top) }
    return out
}

/// The promoted primaries: the first k primary actions in catalog
/// preorder. Recomputed from the observable catalog on every mutation
/// (a structural append or `primary` prop write re-renders the bar),
/// so a later append under an earlier node displaces deterministically.
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

/// THE user dispatch path: chrome clicks (NSMenu action, More-menu
/// button, context-menu button), shortcuts, and harness verbs all land
/// here. Mirrors FIRST (the post-user-mirror rule), then emits with
/// the item's identity and the anchor's noun. Disabled items — the
/// inherited AND — are inert, exactly as native chrome leaves them.
func kayaMenuUserActivate(_ item: KayaMenuItemModel, noun: [UInt8] = []) {
    guard kayaMenuEffectiveEnabled(item) else { return }
    switch item.kind {
    case menuKindAction:
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

/// The coalesced menu re-assert: rebuild the shortcut table and, on
/// macOS, re-synchronize the owned NSMenu segment (a rebuild always
/// starts from the post-user mirror — the model IS that mirror). The
/// macOS rebuild hops ONE main-queue turn: a toggle/radio fire runs
/// inside AppKit's performActionForItem on the very menu the rebuild
/// would mutate, and the expect retry contract absorbs the hop.
func kayaMenuChanged() {
    var table: [String: UInt64] = [:]
    // Every LEAF command may carry a chord — a toggle and one option of
    // a group as readily as a plain action — so the table indexes all
    // three kinds (the root's own rule).
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
        // The menu bar is built from this same post-user mirror, so
        // every prop write (enabled/checked/value) has to invalidate it
        // or the bar shows stale state — the sibling of the macOS
        // segment rebuild above. Coalesced by UIKit, not by us.
        kayaRebuildCatalogMenus()
    #endif
}

/// One aspect of a menu item's state, spelled in the steps grammar's
/// own words — what expect_menu byte-compares. TOTAL: a missing item
/// reads as a short description, a retryable mismatch (expect_menu
/// doubles as the wait for a catalog rebuild to land).
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

/// The expect_menu read: wherever the item surfaced — the OPEN context
/// menu first (context items shadow the bar while presented), then the
/// bar. macOS reads the REAL NSMenuItem state from the owned segment
/// (a backend that ignored the write must fail); iOS reads the model
/// the More menu and toolbar enumerate (the expect_sections precedent —
/// SwiftUI exposes no separate item registry).
func kayaMenuStateRead(_ path: String, _ aspect: KayaMenuAspect) -> String {
    if let wid = kayaOpenContextWidget {
        // Open-context EXCLUSIVITY: while presented, the context menu
        // owns resolution — a miss reads as the retryable "no such
        // item", never a bar fallback.
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
            // VALIDATED state, not merely the state we set: AppKit
            // settles an item's enablement when its menu is about to
            // display, so this reads what the user's next click will
            // get — and it fails loudly if a Kaya menu ever loses
            // `autoenablesItems = false` (docs/traps.md), which an
            // unvalidated read cannot see. The top-level holders sit in
            // the DRESS-owned main menu, whose automatic enabling is
            // not ours to interpret, so a grouping node keeps answering
            // with the declared state (DESIGN.md, "Where a platform
            // cannot say it").
            if let owner = nsItem.menu, owner !== NSApp.mainMenu {
                owner.update()
            }
            return nsItem.isEnabled ? "enabled" : "disabled"
        case .checkedness:
            guard let nsItem = kayaOwnedNSMenuItem(item.id) else { return "no such item" }
            return nsItem.state == .on ? "checked" : "unchecked"
        case .value:
            // The group's value IS its checked option, read from the
            // real items (the checkmark idiom).
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
    /// The kaya window whose catalog the global bar presents: the key
    /// kaya window, swapped by the key-window observer; the primary
    /// until any other kaya window takes key (accessory-policy suite
    /// runs never grant key status, which correctly leaves the
    /// primary's catalog presented).
    var kayaPresentedMenuWindow: UInt64 = 0
    /// The Kaya-owned SEGMENT of NSApp.mainMenu, in catalog order.
    /// Everything outside it — application menu, Edit, Window, Help —
    /// is dress and never touched.
    var kayaOwnedMenuItems: [NSMenuItem] = []
    var kayaMenuObserversInstalled = false
    /// Re-entrancy guard: our own inserts/removals fire the same NSMenu
    /// notifications we observe.
    var kayaMenuSyncing = false
    var kayaMenuResyncPending = false
    var kayaMainMenuKVO: NSKeyValueObservation?

    /// The one target of every owned NSMenuItem: routes the REAL
    /// AppKit action back into the shared dispatch path.
    final class KayaMenuDispatcher: NSObject {
        @objc func fire(_ sender: NSMenuItem) {
            guard let number = sender.representedObject as? NSNumber,
                let item = kayaScene.menuItems[number.uint64Value]
            else { return }
            kayaMenuUserActivate(item)
        }

        /// Kaya-owned menus set `autoenablesItems = false`, so this is
        /// dead weight for the segment — but the role item lands in the
        /// DRESS-owned application menu, which validates. Answering
        /// with the inherited AND keeps that one item's enablement ours
        /// instead of AppKit's (docs/traps.md, the auto-enable trap).
        @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
            guard let number = item.representedObject as? NSNumber,
                let model = kayaScene.menuItems[number.uint64Value]
            else { return true }
            return kayaMenuEffectiveEnabled(model)
        }
    }
    let kayaMenuDispatch = KayaMenuDispatcher()

    /// The canonical shortcut spelling (root-validated: lowercase,
    /// `primary`/`shift`/`alt` order, one key) onto AppKit's key
    /// equivalent. `primary` = Command on Apple hosts. The same
    /// mapping builds NSMenuItem chords and the verb's synthetic key
    /// event, so matching is by construction.
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
        // The punctuation set names UNSHIFTED US positions; AppKit
        // takes the character itself and draws the chord its own way
        // (primary+shift+equal shows as Command-plus).
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

    /// Builds one grouping node's submenu content. A nested menu
    /// cascades; a radio_group materializes INLINE with the checkmark
    /// idiom (its options join the enclosing menu directly).
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
                    kayaApplyKeyEquivalent(nsItem, option.shortcut)
                    menu.addItem(nsItem)
                }
            case menuKindAction, menuKindToggle:
                // A role relocates its item: `settings` is rendered in
                // the application menu instead of here (macOS's own
                // placement), so it must not also appear in the menu
                // that declared it.
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
                // A chord rides any leaf command: "Show Sidebar" wants
                // its checkmark AND its key, and AppKit has never cared
                // which kind of item carries a key equivalent.
                kayaApplyKeyEquivalent(nsItem, child.shortcut)
                menu.addItem(nsItem)
            default:
                break  // radio_option outside its group: the closed grammar forbids it
            }
        }
    }

    /// One place applies a chord to a native item, so every leaf kind
    /// gets identical treatment and an empty spelling is simply no key.
    private func kayaApplyKeyEquivalent(_ nsItem: NSMenuItem, _ spelling: String) {
        guard !spelling.isEmpty, let (key, mask) = kayaKeyEquivalent(spelling) else { return }
        nsItem.keyEquivalent = key
        nsItem.keyEquivalentModifierMask = mask
    }

    /// The segment's insertion point among DRESS items: after the
    /// Edit dress, before Window/Help — never touching the rest of
    /// the bar. Anchors are locale-independent: the Edit dress is
    /// detected by its native edit actions (copy:/paste: survive
    /// every localization; the English title probe is only the
    /// fallback), Window/Help by NSApp's own menu handles.
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

    /// Rebuild and re-insert the owned segment from the presented
    /// window's catalog — always from the model, which is the
    /// post-user mirror (docs/traps.md: rebuilding from a pre-click
    /// copy silently reverts the user's toggle/radio state).
    func kayaSyncMacMenuBar() {
        kayaMenuSyncing = true
        defer { kayaMenuSyncing = false }
        for old in kayaOwnedMenuItems { old.menu?.removeItem(old) }
        kayaOwnedMenuItems.removeAll()
        let catalog = kayaPresentedCatalog()
        guard !catalog.isEmpty else { return }
        // Accessory-policy processes still carry a SwiftUI-built main
        // menu; if none exists yet there is no dress to preserve and
        // the segment IS the bar.
        let mainMenu = NSApp.mainMenu ?? {
            let menu = NSMenu()
            menu.autoenablesItems = false  // docs/traps.md
            NSApp.mainMenu = menu
            return menu
        }()
        // Owned items are already removed above, so this list is the
        // dress alone — the insertion index's required view.
        var index = kayaMenuInsertionIndex(mainMenu.items)
        for top in catalog {
            let holder = NSMenuItem(title: top.label, action: nil, keyEquivalent: "")
            holder.representedObject = NSNumber(value: top.id)
            holder.isEnabled = kayaMenuEffectiveEnabled(top)
            let submenu = NSMenu(title: top.label)
            submenu.autoenablesItems = false  // docs/traps.md
            // A bar-level radio_group is a top-level menu whose
            // options use the checkmark idiom — the same inline
            // materialization, one level up.
            kayaBuildNSMenuItems(
                into: submenu,
                children: top.kind == menuKindRadioGroup ? [top] : top.children)
            holder.submenu = submenu
            mainMenu.insertItem(holder, at: min(index, mainMenu.items.count))
            kayaOwnedMenuItems.append(holder)
            index += 1
        }
        // The one place a role may enter dress-owned chrome. macOS
        // expects Settings in the application menu, so the item MOVES
        // there; the model keeps it where the app declared it, so
        // paths, reads, and activation are unaffected by the move. The
        // role never invents a chord — an app that wants Command-comma
        // declares it and every host then agrees.
        if let settings = kayaCatalogRoleItem("settings", kayaPresentedCatalog()),
            let appMenu = mainMenu.items.first?.submenu
        {
            let nsItem = NSMenuItem(
                title: settings.label,
                action: #selector(KayaMenuDispatcher.fire(_:)), keyEquivalent: "")
            nsItem.target = kayaMenuDispatch
            nsItem.representedObject = NSNumber(value: settings.id)
            nsItem.isEnabled = kayaMenuEffectiveEnabled(settings)
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

    /// Where Settings sits in an application menu: after the separator
    /// that follows About. Falling back to the end keeps a stripped
    /// app menu (no About, no separators) from losing the item.
    private func kayaSettingsInsertionIndex(_ items: [NSMenuItem]) -> Int {
        if let separator = items.firstIndex(where: { $0.isSeparatorItem }) {
            return separator + 1
        }
        return items.count
    }

    /// Idempotent segment assert — the kayaEnsureOpen shape: belt, not
    /// the fix (the observers below are the event-driven re-assert the
    /// traps entry requires); free when the segment already sits in
    /// the current main menu.
    func kayaEnsureMenuSegment() {
        if let mainMenu = NSApp.mainMenu, !kayaOwnedMenuItems.isEmpty {
            // Membership alone is not placement: a dress mutation can
            // displace or split the owned run. The segment must sit
            // CONTIGUOUSLY, in catalog order, at the insertion index
            // the remaining dress computes — anything else re-syncs.
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

    /// Coalesce re-asserts: reacting inside a menu's own change
    /// notification mutates the menu being changed, so the sync hops
    /// one main-queue turn.
    func kayaScheduleMenuResync() {
        guard !kayaMenuResyncPending else { return }
        kayaMenuResyncPending = true
        DispatchQueue.main.async {
            kayaMenuResyncPending = false
            kayaEnsureMenuSegment()
        }
    }

    /// The model-changed rebuild, likewise one turn out (and
    /// coalesced): kayaMenuChanged can fire from a dispatcher action
    /// running inside performActionForItem on the owned menu itself.
    var kayaMenuRebuildPending = false
    func kayaScheduleMenuRebuild() {
        guard !kayaMenuRebuildPending else { return }
        kayaMenuRebuildPending = true
        DispatchQueue.main.async {
            kayaMenuRebuildPending = false
            kayaSyncMacMenuBar()
        }
    }

    /// The EVENT-DRIVEN re-assert (docs/traps.md: a one-shot insertion
    /// races the same asynchronous scene machinery as a one-shot
    /// window registration): SwiftUI rebuilding the bar fires the
    /// NSMenu item notifications or replaces NSApp.mainMenu (KVO);
    /// key-window changes swap the presented catalog.
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

    /// menu_activate's macOS bar route — the ruled REAL-chrome verdict,
    /// resolved SEMANTICALLY: the path walks the model tree (a grouping
    /// root's label is a path segment whether or not materialization
    /// mints a titled item — an inline nested radio_group has none, so
    /// "View>Sort>Date" must still land on Date), then the materialized
    /// NSMenuItem is found by IDENTITY (the representedObject id every
    /// owned item carries), never by title-walking the chrome. The
    /// activation itself stays real chrome (no model-route fallback).
    /// Returns a failure description, nil on success.
    func kayaMacMenuActivate(_ path: String) -> String? {
        kayaEnsureMenuSegment()
        guard let target = kayaResolveMenuPath(path, roots: kayaPresentedCatalog()) else {
            return "no such menu item \(path)"
        }
        var found = kayaOwnedNSMenuItem(target.id)
        if found == nil {
            // A coalesced rebuild may still be one queue turn out;
            // re-sync from the model (the post-user mirror — always
            // safe) and look again before failing.
            kayaSyncMacMenuBar()
            found = kayaOwnedNSMenuItem(target.id)
        }
        guard let item = found, let menu = item.menu else {
            return "no such menu item \(path)"
        }
        // The REAL action route: highlight + target/action, exactly
        // what menu tracking sends. Disabled items stay inert in the
        // dispatcher (the inherited AND), as native tracking leaves
        // them.
        menu.performActionForItem(at: menu.index(of: item))
        return nil
    }

    /// shortcut's macOS route: a synthetic key event through
    /// NSMenu.performKeyEquivalent — the same key-equivalent table the
    /// real key press walks, landing on the same NSMenuItem action.
    /// The verb is a SILENT action and a chord no catalog action owns
    /// is a no-op on every platform, so the catalog table gates the
    /// walk — the dress bar must never swallow an unowned chord (a
    /// stray primary+w would close the window under the leg).
    /// Returns true when NO catalog item owns the chord — the caller
    /// turns that into a script failure rather than a silent pass.
    func kayaMacShortcut(_ spelling: String) -> Bool {
        kayaEnsureMenuSegment()
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

/// One menu item rendered in SwiftUI menu content — the More menu's
/// children and every context menu share this vocabulary. A nested
/// menu survives as a real cascade/drill-in; a radio_group renders
/// inline with the platform's checkmark idiom (an inline Picker); all
/// leaves fire the shared dispatch path with the anchor's noun.
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
            // The drill-in row itself disables (Compose disables the
            // drill row, mac disables the holder — one semantics).
            Menu(item.label) {
                ForEach(item.children) { child in
                    KayaMenuNodeView(item: child, noun: noun, promoted: promoted)
                }
            }
            .disabled(!kayaMenuEffectiveEnabled(item))
        case menuKindRadioGroup:
            KayaMenuRadioInline(group: item, noun: noun)
        case menuKindToggle:
            Toggle(
                item.label,
                isOn: Binding(
                    get: { item.checked },
                    set: { _ in kayaMenuUserActivate(item, noun: noun) })
            )
            .disabled(!kayaMenuEffectiveEnabled(item))
        case menuKindAction:
            if !promoted.contains(item.id) {
                Button(item.label) {
                    kayaMenuUserActivate(item, noun: noun)
                }
                .disabled(!kayaMenuEffectiveEnabled(item))
            }
        default:
            EmptyView()
        }
    }
}

/// A radio group inline in menu content: the checkmark idiom via an
/// inline Picker; the selection binding's setter IS the user route
/// (programmatic value writes land in the apply arm and stay quiet).
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
                Text(option.label).tag(index)
            }
        }
        .pickerStyle(.inline)
        .disabled(!kayaMenuEffectiveEnabled(group))
    }
}

/// A context anchor's menu content: the attached roots in append
/// order, every activation stamping the anchor's noun (empty for a
/// live widget; the stamped copy's key path for a template node).
struct KayaContextMenuItems: View {
    let widgetId: UInt64

    var body: some View {
        let noun = kayaScene.contextNouns[widgetId] ?? []
        ForEach(kayaScene.contextRoots[widgetId] ?? []) { root in
            KayaMenuNodeView(item: root, noun: noun)
        }
    }
}

/// The window catalog's chrome, attached to every surface root: a
/// no-op on macOS (the global-bar synchronizer owns the lowering
/// there), and elsewhere the FORM-FACTOR-keyed choice of lowering.
///
/// The axis is the window's size class, never the operating system
/// (DESIGN.md, "Form factor and adaptivity"). The `#if os(iOS)` this
/// replaced was wrong as of iPadOS 26, which gives every iPad app a
/// real system menu bar reachable without a keyboard — so a full
/// command catalog sat behind a phone affordance on a device that had
/// the desktop one.
struct KayaMenuChrome: ViewModifier {
    let windowId: UInt64

    func body(content: Content) -> some View {
        #if os(macOS)
            // No stamping here: macOS answers the chrome verb by
            // counting the kaya-owned segment in the REAL NSApp.mainMenu,
            // which is a stronger read than anything this view could
            // record.
            content
        #else
            content.modifier(KayaMenuFormFactorChrome(windowId: windowId))
        #endif
    }
}

#if !os(macOS)
    /// Reads the live horizontal size class, records it on the window
    /// model so the harness can observe the transition, and picks the
    /// lowering. Recording happens in `onAppear`/`onChange` rather than
    /// in `body`, because a write during body evaluation is a mutation
    /// inside the render pass.
    struct KayaMenuFormFactorChrome: ViewModifier {
        let windowId: UInt64
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass

        private var factor: KayaFormFactor {
            horizontalSizeClass == .regular ? .regular : .compact
        }

        func body(content: Content) -> some View {
            Group {
                if factor == .regular {
                    // The system menu bar carries the whole catalog; a
                    // More toolbar beside it would be a second,
                    // redundant route to the same commands.
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

        /// Stamp both halves the harness reads. The presentation half
        /// names THE ARM THIS BODY TOOK — today the toolbar in both
        /// size classes, which is exactly the state the iPad defect
        /// leaves behind and exactly what `expect_menu_presentation
        /// "regular/bar"` is meant to fail on until the menu-bar arm
        /// lands.
        private func record() {
            guard let window = kayaScene.windows[windowId] else { return }
            window.formFactor = factor
            if window.menubar.isEmpty {
                window.menuPresentation = .none
            } else if factor != .regular {
                // The compact arm stamps itself; the regular arm's
                // stamp belongs to kayaBuildCatalogMenus, which writes
                // `.bar` only after really inserting menus. Deriving it
                // here from `factor` would make the harness verb agree
                // with the lowering by construction.
                window.menuPresentation = .overflow
            }
            kayaRebuildCatalogMenus()
        }
    }
#endif

#if !os(macOS)
    /// The regular-width catalog lowering: the platform's own menu bar
    /// (iPadOS 26+). Driven through UIMenuBuilder rather than SwiftUI's
    /// `.commands` for the same reason macOS drives NSMenu directly —
    /// CommandsBuilder has no `buildArray`, so it cannot express an
    /// append-at-any-time number of top-level menus.
    ///
    /// buildMenu also runs on iPhone, where it feeds the
    /// hardware-keyboard HUD rather than a visible bar. Building is
    /// therefore unconditional; only the VISIBLE arm keys on size class.
    func kayaBuildCatalogMenus(_ builder: UIMenuBuilder) {
        if ProcessInfo.processInfo.environment["KAYA_MENU_TRACE"] != nil {
            FileHandle.standardError.write(
                Data("KAYA_MENU_TRACE: buildMenu roots=\(kayaScene.windows[0]?.menubar.count ?? -1)\n".utf8))
        }
        guard let window = kayaScene.windows[0], !window.menubar.isEmpty else {
            return
        }
        // Reversed: each insert lands immediately after .view, so
        // going back to front leaves catalog order reading left to
        // right — the same preorder every other arm materializes.
        var inserted = 0
        for root in window.menubar.reversed() {
            guard let menu = kayaCatalogTopLevel(root) else { continue }
            builder.insertSibling(menu, afterMenu: .view)
            inserted += 1
        }
        // Stamped where the bar is REALLY built, never from the size
        // class: a build that silently produced nothing must not be
        // able to report `bar` to expect_menu_presentation.
        // KAYA_MENU_TRACE=1 prints the build/rebuild trace to stderr.
        // Kept deliberately: it is what proved the bar is built lazily,
        // and whoever wires the accessibility gate will want it again.
        if ProcessInfo.processInfo.environment["KAYA_MENU_TRACE"] != nil {
            FileHandle.standardError.write(
                Data("KAYA_MENU_TRACE: inserted=\(inserted) factor=\(window.formFactor.rawValue)\n".utf8))
        }
    }

    /// A top-level catalog node. Grouping nodes become real menus; a
    /// top-level radio group becomes a menu holding its inline options.
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

    /// One grouping node's children, with kaya's SEPARATOR items
    /// lowered the way UIKit spells separation.
    ///
    /// UIKit has no separator element: a divider is the boundary
    /// between `.displayInline` groups. So partition the run at each
    /// separator and wrap each partition inline — the system draws the
    /// dividers between them. A placeholder element would be wrong (it
    /// renders as a real, selectable row), and an EMPTY inline menu
    /// draws nothing at all, which is why empty partitions are dropped
    /// rather than emitted: a leading or doubled separator must not
    /// silently swallow a divider.
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
        // A single group needs no wrapper: with no sibling group there
        // is no divider to draw, and the extra menu is pure noise.
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

    /// A radio group: options inline, exactly one `.on` — the choice
    /// contract's selected index, the same state the inline Picker
    /// shows in the compact arm.
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

    /// The catalog is live, so every structural append and every prop
    /// write must reach the bar or it shows stale state. UIKit's
    /// invalidation is a rebuild request — the same "recompute on every
    /// catalog mutation" rule the promoted set already follows.
    func kayaRebuildCatalogMenus() {
        // Hop to main, exactly like the macOS segment rebuild: this is
        // reached from the transaction apply, which is not guaranteed
        // to be the main thread, and a UIKit invalidation off-main is
        // silently dropped rather than diagnosed.
        if ProcessInfo.processInfo.environment["KAYA_MENU_TRACE"] != nil {
            FileHandle.standardError.write(Data("KAYA_MENU_TRACE: rebuild requested\n".utf8))
        }
        DispatchQueue.main.async { UIMenuSystem.main.setNeedsRebuild() }
    }

    /// The iOS window-anchor lowering: promoted primaries as real
    /// trailing bar actions, the rest of the catalog behind a trailing
    /// More menu — top-level grouping nodes as labeled groups, one
    /// nested menu level as a drill-in, radio groups inline. All
    /// recomputed from the observable catalog, so promotion follows
    /// every mutation.
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
                                if let icon = item.icon {
                                    Image(uiImage: icon)
                                } else {
                                    Text(item.label)
                                }
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
                            // The trigger glyph is dress.
                            Label("More", systemImage: "ellipsis.circle")
                        }
                    }
                }
            } else {
                content
            }
        }
    }
#endif

/// A navigation entry's content: the mounted root in the normalized
/// frame (16-unit inset, top-leading, fill), titled from its model —
/// navigationTitle inside a NavigationStack destination titles the
/// bar (and the window, on macOS): the real title path the harness
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
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(scene.navEntries[entryId]?.title ?? "")
    }
}

/// An auxiliary surface's content: the mounted root in the same
/// normalized frame the primary uses (16-unit inset, top-leading,
/// fill), titled from its model. Presented via openWindow(value:)
/// when a mount targets it.
struct KayaAuxRoot: View {
    let windowId: UInt64
    @State private var scene = kayaScene

    var body: some View {
        // The stack hosts the window's serial entries; the window's
        // own root is the stack's base. The accessor rides OUTSIDE
        // the stack so its view never detaches under a push.
        Group {
        if scene.windows[windowId]?.sections.isEmpty == false {
            KayaSectionsView(windowId: windowId)
                .navigationTitle(scene.windows[windowId]?.title ?? "")
        } else {
        NavigationStack(path: kayaNavPath(windowId)) {
            Group {
                if let model = scene.windows[windowId], let root = model.root {
                    KayaRender(node: root, isRoot: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(scene.windows[windowId]?.title ?? "")
            .navigationDestination(for: UInt64.self) { eid in
                KayaEntryRoot(entryId: eid)
            }
        }
        }
        }
        .onAppear { kayaDiag("auxRoot appear wid=\(windowId)") }
        #if os(macOS)
            .background(KayaWindowAccessor(windowId: windowId))
        #endif
    }
}

/// Does `windowId` take the list-detail arm right now? Both halves
/// must hold: the app ASKED (wprop 6) and the window IS regular. The
/// size class is the platform's answer, never the app's — that is what
/// makes this adaptive rather than a manual switch.
func kayaSplitArm(_ windowId: UInt64) -> Bool {
    guard let w = kayaScene.windows[windowId] else { return false }
    return w.listDetail && w.formFactor == .regular
}

/// The list-detail presentation of a window's entry stack. Two panes,
/// never three: Apple has a three-column form and nobody else does, so
/// it is not the intersection.
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
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(scene.windows[windowId]?.title ?? "")
        } detail: {
            // The TOP of the stack is the detail. An empty stack gets
            // the platform's own empty state — every one of the four
            // has one, so there is nothing to invent.
            if let top = scene.windows[windowId]?.entries.last {
                KayaEntryRoot(entryId: top.id)
            }
        }
        .onAppear { record() }
        .onChange(of: scene.windows[windowId]?.entries.count ?? 0) { record() }
    }

    /// Stamp the arm THIS BODY TOOK. Never derived from listDetail or
    /// formFactor: a derived answer agrees with the lowering by
    /// construction and could never catch the defect.
    private func record() {
        kayaScene.windows[windowId]?.splitPresentation = "split"
    }
}

struct KayaEntry: View {
    let node: KayaNode
    @FocusState private var focused: Bool

    var body: some View {
        // Uncontrolled toward the app: the node mirrors what the
        // user types (SwiftUI needs the binding), and every edit is
        // emitted with the entry's identity tag for the app to fold
        // into its own model — nothing here is read back. Focus is
        // model-driven the same way: the focus command lands as the
        // scene's focusedId, mirrored into SwiftUI here, and a
        // user-driven change flows back so the model stays truthful.
        TextField(
            "",
            text: Binding(
                get: { node.text },
                set: { newValue in
                    let value = kayaLF(newValue)
                    node.text = value
                    KayaHost.emitText(node.tag, value)
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

/// The multi-line editor: KayaEntry's exact contract (uncontrolled
/// binding, identity-tag emits, model-driven focus) over TextEditor.
struct KayaTextarea: View {
    let node: KayaNode
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(
            text: Binding(
                get: { node.text },
                set: { newValue in
                    let value = kayaLF(newValue)
                    node.text = value
                    KayaHost.emitText(node.tag, value)
                })
        )
        .frame(width: 240, height: 96)
        .border(Color.gray.opacity(0.4))
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

/// A window's sections materialized: SwiftUI's TabView carries the
/// platform's dominant idiom under the `auto` hint — toolbar tabs on
/// macOS, the bottom bar on iOS. `sidebar` resolves to
/// NavigationSplitView on macOS; the phones ignore hints by physics.
/// Each pane hosts ITS OWN NavigationStack (stacks are per-surface).
/// The selection binding's setter fires only for USER switches, which
/// emit section_selected — a programmatic select_section writes the
/// model directly and stays quiet (the echo doctrine).
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
                            Text(section.title).tag(section.id)
                        }
                    } detail: {
                        KayaSectionPane(sectionId: selection.wrappedValue)
                    }
                } else {
                    tabBody(window)
                }
            #else
                tabBody(window)
            #endif
        }
    }

    private func tabBody(_ window: KayaWindowModel) -> some View {
        TabView(selection: selection) {
            ForEach(window.sections) { section in
                KayaSectionPane(sectionId: section.id)
                    .tabItem { Text(section.title) }
                    .tag(section.id)
            }
        }
    }
}

/// One section's pane: the mounted root in the normalized frame over
/// the section's own stack — the KayaAuxRoot shape on a section
/// surface.
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
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The hosting window's catalog rides each pane's top bar
            // on iOS (sections share the window's command catalog).
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
            // ADAPTIVE LIST-DETAIL (DESIGN.md): the base root takes the
            // leading pane and the TOP of the stack the trailing one.
            // The entries between stay retained and covered — the same
            // rule navigation already has, which is why this needed no
            // new lifecycle vocabulary.
            KayaSplitRoot(windowId: 0)
        } else {
        // The primary surface's stack: pushed entries cover this root
        // serially; the root is the stack's base and stays alive
        // (retained-until-popped) underneath. This arm stamps
        // "stacked" for the same reason the split arm stamps "split":
        // an observation that is only WRITTEN by one arm is derived by
        // default in the other, which is the shape that cannot catch a
        // defect.
        NavigationStack(path: kayaNavPath(0)) {
        // The outer GeometryReader IS the offer: it fills whatever the
        // window proposes inside the padding, and expect_root_fills
        // compares the root's rendered size against it. Both readings
        // are geometry, so no speculative layout pass can clobber them.
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
        // The normalized root inset: 16 units, the same default the
        // other six backends now apply inside their roots.
        .padding(16)
        // Normalized: pack content to the top-leading corner of the
        // surface rather than letting the window center it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The primary surface's title (initially the process name, so
        // an unset prop changes nothing): SwiftUI's blessed window
        // titling path on macOS; harmless on iOS, where the switcher
        // label is stamped in the apply arm instead.
        .navigationTitle(scene.windowTitle)
        // The window's command catalog rides the window construct: on
        // iOS this is the trailing More menu + promoted bar actions
        // (a no-op on macOS, where the NSMenu segment owns the bar).
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
                // The menu segment's event-driven re-assert hooks
                // (SwiftUI rebuilds, key-window changes) — installed
                // before the pump so the first catalog batch cannot
                // race them.
                kayaInstallMenuObservers()
            #endif
            kayaPlaceWindow()
            kayaStartCommandPump()
            kayaStartSelftest()
        }
    }
}

// Recording mode tiles parallel legs so one display-scoped capture
// sees every window unoccluded: the runner assigns a slot, the window
// places (and bounds) itself — its own window, no permissions. The
// geometry mirrors the AppKit backend's.
private func kayaPlaceWindow() {
    #if os(macOS)
    guard let raw = ProcessInfo.processInfo.environment["KAYA_WIN_SLOT"],
        let slot = Int(raw),
        let window = NSApplication.shared.windows.first
    else { return }
    // Same screen-derived grid as the AppKit backend: shared cells
    // sized for this backend's 540x330 windows, partial last cell
    // counting when the window still fits.
    let vis = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let cols = max(1, Int((vis.width - 20 - 540) / 570) + 1)
    let rows = max(1, Int((vis.height - 40 - 330) / 345) + 1)
    let bounded = slot % (cols * rows)
    let x = 20.0 + Double(bounded % cols) * 570.0
    let y = 40.0 + Double(bounded / cols) * 345.0
    window.setFrame(NSRect(x: x, y: y, width: 540, height: 330), display: true)
    #endif
}
