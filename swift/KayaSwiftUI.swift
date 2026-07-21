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
let kayaSpecHash: UInt64 = 0xcce97c88cc7210aa

private let applyCreate: UInt16 = 1
private let applySetProp: UInt16 = 2
private let applyAddChild: UInt16 = 3
private let applyMount: UInt16 = 4
private let applyDestroy: UInt16 = 5
private let applyMoveChild: UInt16 = 6
private let applyCommand: UInt16 = 7
private let applySetWindowProp: UInt16 = 8

/// Window properties (their own namespace — windows are not widgets;
/// window 0 is the primary surface).
private let wpropTitle: UInt32 = 1
private let wpropWidth: UInt32 = 2
private let wpropHeight: UInt32 = 3
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
private let propText: UInt32 = 1
private let propChecked: UInt32 = 2
private let propValue: UInt32 = 3
private let propMin: UInt32 = 4
private let propMax: UInt32 = 5
private let propSource: UInt32 = 6
private let propGrow: UInt32 = 7
private let propSpacing: UInt32 = 8
private let propAlign: UInt32 = 9
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

@Observable
final class KayaSceneModel {
    var root: KayaNode?
    var nodes: [UInt64: KayaNode] = [:]  // main actor only
    var parents: [UInt64: UInt64] = [:]
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
    // The primary surface's properties. The title starts as the
    // process name — exactly what an untitled WindowGroup shows — so
    // an unset prop changes nothing. Width/height record the advisory
    // size request; macOS materializes it, iOS records it only (the
    // system owns surface geometry).
    var windowTitle: String = ProcessInfo.processInfo.processName
    var windowWidth: Double?
    var windowHeight: Double?
}

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
private func kayaApplyWindowSize() {
    #if os(macOS)
        guard let window = NSApp.windows.first else { return }
        let current = window.contentRect(forFrameRect: window.frame).size
        let size = NSSize(
            width: kayaScene.windowWidth ?? current.width,
            height: kayaScene.windowHeight ?? current.height)
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
                default: break
                }
            case applySetWindowProp:
                // window (u64; 0 = the primary surface), prop (u32),
                // pad, value. Size is an advisory request: macOS
                // resizes, iOS records (see DESIGN.md, Presentation
                // contexts).
                let prop = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt32.self)
                let wvType = raw.loadUnaligned(fromByteOffset: body + 16, as: UInt32.self)
                let wvLen = Int(raw.loadUnaligned(fromByteOffset: body + 20, as: UInt32.self))
                switch (prop, wvType) {
                case (wpropTitle, valueStr):
                    let bytes = raw[(body + 24)..<(body + 24 + wvLen)]
                    let title = String(decoding: bytes, as: UTF8.self)
                    kayaScene.windowTitle = title
                    #if os(iOS)
                        // The switcher/Stage Manager label — iOS's
                        // materialization of a surface title.
                        for uiScene in UIApplication.shared.connectedScenes {
                            (uiScene as? UIWindowScene)?.title = title
                        }
                    #endif
                case (wpropWidth, valueF64):
                    kayaScene.windowWidth =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Double.self)
                    kayaApplyWindowSize()
                case (wpropHeight, valueF64):
                    kayaScene.windowHeight =
                        raw.loadUnaligned(fromByteOffset: body + 24, as: Double.self)
                    kayaApplyWindowSize()
                default:
                    fatalError("kaya: bad window prop \(prop) value type \(wvType)")
                }
            case applySetProp:
                let id = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                // prop (u32), u32 pad, then the value (type, len, bytes).
                let prop = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt32.self)
                let valueType = raw.loadUnaligned(fromByteOffset: body + 16, as: UInt32.self)
                let len = Int(raw.loadUnaligned(fromByteOffset: body + 20, as: UInt32.self))
                switch (prop, valueType) {
                case (propText, valueStr):
                    let bytes = raw[(body + 24)..<(body + 24 + len)]
                    kayaScene.nodes[id]!.text = String(decoding: bytes, as: UTF8.self)
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
            case applyMount:
                // window (u64) is the default until the window vocabulary.
                let root = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt64.self)
                kayaScene.root = kayaScene.nodes[root]
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

private func kayaQuoted(_ rest: [Substring]) -> String {
    let joined = rest.joined(separator: " ")
    return String(joined.dropFirst().dropLast())
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
            case "set_text":
                let ok = DispatchQueue.main.sync { () -> Bool in
                    guard let node = kayaTarget(parts[1], "entry", kayaScene.entries) else {
                        return false
                    }
                    node.text = kayaQuoted(Array(parts[2...]))
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
                    parts[1].hasPrefix("entry")
                        ? kayaTarget(parts[1], "entry", kayaScene.entries)?.text
                        : parts[1].hasPrefix("image")
                            ? kayaTarget(parts[1], "image", kayaScene.images)?.imageSize
                            : kayaTarget(parts[1], "label", kayaScene.labels)?.text
                }
                if let got, got == want {
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
                    guard let node = kayaTarget(parts[1], "entry", kayaScene.entries) else {
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
                if let got, got == want {
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
                if let got, got == want {
                    observed.append(got)
                } else if let got {
                    failures.append("\(parts[1]) splits \"\(got)\", wanted \"\(want)\"")
                } else {
                    failures.append("no such target \(parts[1])")
                }
            case "expect_title":
                // The REAL materialized title, never the model's copy
                // on macOS — a backend that ignored the write must
                // fail.
                let want = kayaQuoted(Array(parts[1...]))
                let got = DispatchQueue.main.sync { () -> String in
                    #if os(macOS)
                        return NSApp.windows.first?.title ?? ""
                    #else
                        return kayaScene.windowTitle
                    #endif
                }
                if got == want {
                    observed.append("title \"\(want)\"")
                } else {
                    failures.append("title \"\(got)\", wanted \"\(want)\"")
                }
            case "expect_window_size":
                // The surface's REAL content extent against the
                // advisory request, within 2pt. Reads the window, not
                // the offer reader (the offer sits inside the root
                // inset).
                let dims = parts[1].split(separator: "x")
                let wantW = Double(dims[0]) ?? -1
                let wantH = Double(dims[1]) ?? -1
                let got = DispatchQueue.main.sync { () -> CGSize in
                    #if os(macOS)
                        guard let window = NSApp.windows.first else { return .zero }
                        return window.contentRect(forFrameRect: window.frame).size
                    #else
                        let scenes = UIApplication.shared.connectedScenes
                        let ws = scenes.compactMap { $0 as? UIWindowScene }.first
                        return ws?.windows.first?.bounds.size ?? .zero
                    #endif
                }
                if abs(got.width - wantW) <= 2, abs(got.height - wantH) <= 2 {
                    observed.append("window \(Int(wantW))x\(Int(wantH))")
                } else {
                    failures.append(
                        "window \(Int(got.width))x\(Int(got.height)), wanted "
                            + "\(Int(wantW))x\(Int(wantH))")
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
                    node.text = newValue
                    KayaHost.emitText(node.tag, newValue)
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

struct KayaRoot: View {
    @State private var scene = kayaScene

    var body: some View {
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
        .onAppear {
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
