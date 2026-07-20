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
private let applyCreate: UInt16 = 1
private let applySetProp: UInt16 = 2
private let applyAddChild: UInt16 = 3
private let applyMount: UInt16 = 4
private let applyDestroy: UInt16 = 5
private let applyMoveChild: UInt16 = 6
private let applyCommand: UInt16 = 7
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
private let valueBool: UInt32 = 1
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
                default: break
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

private func kayaTarget(_ spec: Substring, _ registry: [KayaNode]) -> KayaNode {
    let index = spec.split(separator: "#")[1]
    let i = index == "last" ? registry.count - 1 : Int(index)!
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
                DispatchQueue.main.sync {
                    KayaHost.emit(kayaTarget(parts[1], kayaScene.buttons).tag)
                }
            case "toggle":
                DispatchQueue.main.sync {
                    let node = kayaTarget(parts[1], kayaScene.checkboxes)
                    node.checked = parts[2] == "on"
                    KayaHost.emitToggled(node.tag, node.checked)
                }
            case "set_value":
                DispatchQueue.main.sync {
                    let node = kayaTarget(parts[1], kayaScene.sliders)
                    node.value = Double(parts[2])!
                    KayaHost.emitValue(node.tag, node.value)
                }
            case "set_text":
                DispatchQueue.main.sync {
                    let node = kayaTarget(parts[1], kayaScene.entries)
                    node.text = kayaQuoted(Array(parts[2...]))
                    KayaHost.emitText(node.tag, node.text)
                }
            case "expect":
                let want = kayaQuoted(Array(parts[2...]))
                // The target kind picks the observation: an entry reads
                // the field's own displayed text, an image its decoded
                // size ("WxH"/"0x0"), everything else reads label text
                // — harness.rs's routing.
                let got = DispatchQueue.main.sync {
                    parts[1].hasPrefix("entry")
                        ? kayaTarget(parts[1], kayaScene.entries).text
                        : parts[1].hasPrefix("image")
                            ? kayaTarget(parts[1], kayaScene.images).imageSize
                            : kayaTarget(parts[1], kayaScene.labels).text
                }
                if got == want {
                    observed.append(got)
                } else {
                    failures.append("\(parts[1]) reads \"\(got)\", wanted \"\(want)\"")
                }
            case "expect_focused":
                // The model's focusedId is the observation the focus
                // command lands as (the entry view's FocusState mirrors
                // it into SwiftUI). Counts as an expect for the
                // zero-expect rule, exactly as in harness.rs.
                let focused = DispatchQueue.main.sync {
                    kayaScene.focusedId == kayaTarget(parts[1], kayaScene.entries).id
                }
                if focused {
                    observed.append("\(parts[1]) focused")
                } else {
                    failures.append("\(parts[1]) does not hold focus")
                }
            case "expect_order":
                // The container's label children in child order, joined
                // with `|` — reads the tree the moves actually edited,
                // which the creation-ordered registries cannot see.
                let want = kayaQuoted(Array(parts[2...]))
                let got = DispatchQueue.main.sync {
                    kayaTarget(parts[1], kayaScene.columns).children
                        .filter { $0.kind == kindLabel }
                        .map { $0.text }
                        .joined(separator: "|")
                }
                if got == want {
                    observed.append(got)
                } else {
                    failures.append("\(parts[1]) ordered \"\(got)\", wanted \"\(want)\"")
                }
            default:
                failures.append("unknown step \(line)")
            }
        }
    }
    if failures.isEmpty && observed.isEmpty {
        failures.append("script has no expects")
    }
    if failures.isEmpty {
        print("KAYA_SELFTEST: OK (\(observed.joined(separator: ", ")))")
        exit(0)
    }
    FileHandle.standardError.write(
        "KAYA_SELFTEST: FAILED (\(failures.joined(separator: "; ")))\n".data(using: .utf8)!)
    exit(1)
}

struct KayaRender: View {
    let node: KayaNode

    var body: some View {
        switch node.kind {
        case kindColumn:
            // Normalized: 8-pt spacing, leading (cross-axis start).
            VStack(alignment: .leading, spacing: 8) {
                ForEach(node.children) { child in
                    KayaRender(node: child)
                }
            }
        case kindButton:
            Button(node.text) {
                KayaHost.emit(node.tag)
            }
        case kindRow:
            // Normalized: 8-pt spacing, top (cross-axis start).
            HStack(alignment: .top, spacing: 8) {
                ForEach(node.children) { child in
                    KayaRender(node: child)
                }
            }
        case kindLabel:
            Text(node.text)
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
            .frame(maxWidth: 200)
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
        Group {
            if let root = scene.root {
                KayaRender(node: root)
            }
        }
        .padding()
        // Normalized: pack content to the top-leading corner of the
        // surface rather than letting the window center it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
