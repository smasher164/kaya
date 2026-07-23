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
let kayaSpecHash: UInt64 = 0x4605672632603270

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
/// The alert_choice cancel sentinel (deliberately not an index).
private let kayaAlertChoiceCancel: UInt32 = 0xFFFF_FFFF

/// Window properties (their own namespace — windows are not widgets;
/// window 0 is the primary surface).
private let wpropTitle: UInt32 = 1
private let wpropWidth: UInt32 = 2
private let wpropHeight: UInt32 = 3
private let wpropVetoClose: UInt32 = 4
/// Navigation-entry properties (their own typed table; intercept_back
/// is the close-veto class transplanted to POP).
private let epropTitle: UInt32 = 1
private let epropInterceptBack: UInt32 = 2
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

    init(id: UInt64, title: String = "") {
        self.id = id
        self.title = title
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

    static func emitToggled(_ tag: [UInt8], _ checked: Bool) {
        tag.withUnsafeBufferPointer { buffer in
            api.emit_toggled(buffer.baseAddress, UInt(buffer.count), checked ? 1 : 0)
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
            if kind == applySetProp {
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
                kayaScene.windows[wid]!.entries.append(entry)
            case applyPopEntry:
                // Programmatic pop: the core already reconciled its
                // stack; drop the top model and let the derived path
                // animate the NET change of the batch as one
                // transition (the multi-pop obligation).
                let wid = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let entry = kayaScene.windows[wid]!.entries.removeLast()
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
            default:
                fatalError("kaya: unknown apply record kind \(kind)")
            }
            at += size
        }
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
    FileHandle.standardError.write(
        "KAYA_SELFTEST: FAILED (\(failures.joined(separator: "; ")))\n".data(using: .utf8)!)
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
func kayaNavPath(_ wid: UInt64) -> Binding<[UInt64]> {
    Binding(
        get: { kayaScene.windows[wid]?.entries.map(\.id) ?? [] },
        set: { newPath in kayaUserPops(wid, to: newPath.count) })
}

/// A user-driven pop down to `depth` entries: pop unarmed tops one at
/// a time — each reconciling the core-owned stack post-fact through
/// emitEntryPopped — and STOP at an intercept_back-armed entry:
/// nothing pops there, back_requested fires instead, and the derived
/// path snaps the view back to the retained stack (the veto class,
/// materialized; the app answers with pop_entry if it agrees).
func kayaUserPops(_ wid: UInt64, to depth: Int) {
    guard let window = kayaScene.windows[wid] else { return }
    while window.entries.count > depth, let top = window.entries.last {
        if top.interceptBack {
            KayaHost.emitBackRequested(top.id)
            return
        }
        window.entries.removeLast()
        kayaScene.navEntries.removeValue(forKey: top.id)
        kayaScene.entryWindow.removeValue(forKey: top.id)
        KayaHost.emitEntryPopped(top.id)
    }
}

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
        .onAppear { kayaDiag("auxRoot appear wid=\(windowId)") }
        #if os(macOS)
            .background(KayaWindowAccessor(windowId: windowId))
        #endif
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

struct KayaRoot: View {
    @State private var scene = kayaScene
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        // The primary surface's stack: pushed entries cover this root
        // serially; the root is the stack's base and stays alive
        // (retained-until-popped) underneath.
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
        .navigationDestination(for: UInt64.self) { eid in
            KayaEntryRoot(entryId: eid)
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
