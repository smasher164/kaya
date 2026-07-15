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
private let kindColumn: UInt32 = 1
private let kindButton: UInt32 = 2
private let kindLabel: UInt32 = 3
private let kindEntry: UInt32 = 4
private let kindRow: UInt32 = 5
private let kindCheckbox: UInt32 = 6
private let propText: UInt32 = 1
private let propChecked: UInt32 = 2
private let valueBool: UInt32 = 1
private let valueStr: UInt32 = 4

@Observable
final class KayaNode: Identifiable {
    let id: UInt64
    let kind: UInt32
    let tag: [UInt8]
    var text = ""
    var checked = false
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
    var firstButton: KayaNode?
    var lastButton: KayaNode?
    var firstLabel: KayaNode?
    var firstEntry: KayaNode?
    var firstCheckbox: KayaNode?
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
            DispatchQueue.main.async {
                kayaApply(batch)
            }
        }
    }
    thread.start()
}

private func kayaApply(_ batch: Data) {
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
                if widgetKind == kindButton {
                    if kayaScene.firstButton == nil { kayaScene.firstButton = node }
                    kayaScene.lastButton = node
                }
                if widgetKind == kindLabel && kayaScene.firstLabel == nil {
                    kayaScene.firstLabel = node
                }
                if widgetKind == kindEntry && kayaScene.firstEntry == nil {
                    kayaScene.firstEntry = node
                }
                if widgetKind == kindCheckbox && kayaScene.firstCheckbox == nil {
                    kayaScene.firstCheckbox = node
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
            case applyDestroy:
                let id = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                if let parent = kayaScene.parents.removeValue(forKey: id),
                    let parentNode = kayaScene.nodes[parent]
                {
                    parentNode.children.removeAll { $0.id == id }
                }
                kayaScene.nodes.removeValue(forKey: id)
            default:
                fatalError("kaya: unknown apply record kind \(kind)")
            }
            at += size
        }
    }
}

/// Drives the round trip without a human, matching the Rust backends'
/// spawn_selftest: two clicks on the scene's driver button (stamping
/// groups, items, and the When), one on the most recently stamped
/// button, and the status label proves the whole loop.
func kayaStartSelftest() {
    guard let script = ProcessInfo.processInfo.environment["KAYA_SELFTEST"] else { return }
    if script == "entry" {
        kayaStartEntrySelftest()
        return
    }
    if script == "gallery" {
        kayaStartGallerySelftest()
        return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        if let button = kayaScene.firstButton { KayaHost.emit(button.tag) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
        if let button = kayaScene.firstButton { KayaHost.emit(button.tag) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) {
        if let button = kayaScene.lastButton { KayaHost.emit(button.tag) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
        let text = kayaScene.firstLabel?.text ?? "(no label)"
        if text == "removed g2/a, 0 left" {
            print("KAYA_SELFTEST: OK (\(text))")
            exit(0)
        } else {
            FileHandle.standardError.write(
                "KAYA_SELFTEST: FAILED (label reads \(text))\n".data(using: .utf8)!)
            exit(1)
        }
    }
}

/// The interpreter's render: the node tree as SwiftUI declarations.
/// The entry scene's round trip (KAYA_SELFTEST=entry): drive the same
/// binding path a keystroke takes, click add, read the status label.
func kayaStartEntrySelftest() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        if let entry = kayaScene.firstEntry {
            entry.text = "milk"
            KayaHost.emitText(entry.tag, "milk")
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
        if let button = kayaScene.firstButton { KayaHost.emit(button.tag) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) {
        let text = kayaScene.firstLabel?.text ?? "(no label)"
        if text == "added milk, 1 total" {
            print("KAYA_SELFTEST: OK (\(text))")
            exit(0)
        } else {
            FileHandle.standardError.write(
                "KAYA_SELFTEST: FAILED (label reads \(text))\n".data(using: .utf8)!)
            exit(1)
        }
    }
}

/// The gallery scene's round trip (KAYA_SELFTEST=gallery): drive the
/// same binding path a click takes — flip the node, emit toggled — then
/// read the status label.
func kayaStartGallerySelftest() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        if let box = kayaScene.firstCheckbox {
            box.checked = true
            KayaHost.emitToggled(box.tag, true)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) {
        let text = kayaScene.firstLabel?.text ?? "(no label)"
        if text == "urgent: true" {
            print("KAYA_SELFTEST: OK (\(text))")
            exit(0)
        } else {
            FileHandle.standardError.write(
                "KAYA_SELFTEST: FAILED (label reads \(text))\n".data(using: .utf8)!)
            exit(1)
        }
    }
}

struct KayaRender: View {
    let node: KayaNode

    var body: some View {
        switch node.kind {
        case kindColumn:
            VStack(spacing: 8) {
                ForEach(node.children) { child in
                    KayaRender(node: child)
                }
            }
        case kindButton:
            Button(node.text) {
                KayaHost.emit(node.tag)
            }
        case kindRow:
            HStack(spacing: 8) {
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
        case kindEntry:
            // Uncontrolled toward the app: the node mirrors what the
            // user types (SwiftUI needs the binding), and every edit is
            // emitted with the entry's identity tag for the app to fold
            // into its own model — nothing here is read back.
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
        default:
            EmptyView()
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
        .onAppear {
            kayaStartCommandPump()
            kayaStartSelftest()
        }
    }
}
