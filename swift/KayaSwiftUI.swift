// KayaSwiftUI: the Swift half of the SwiftUI backend — an interpreter of
// resolved apply-op records over the presentation-side C ABI:
//
//   create/add_child/mount -> an @Observable node tree (invalidation renders)
//   set_prop               -> observable writes on the nodes
//   occurrence             <- SwiftUI action closure -> emit_button_clicked
//
// The pump blocks in next_commands on its own thread and hops to the
// main actor to apply — the doorbell equivalent, no polling, no
// callbacks across the ABI. Signals never reach this layer; the core
// resolves them before the records leave kaya_next_commands.

import SwiftUI

// Pinned to the KAYA_APPLY_* / KAYA_KIND_* / KAYA_VALUE_* constants in
// kaya.h (imported via the bridging header, but spelled here for use in
// switch patterns).
private let applyCreate: UInt16 = 1
private let applySetProp: UInt16 = 2
private let applyAddChild: UInt16 = 3
private let applyMount: UInt16 = 4
private let kindColumn: UInt32 = 1
private let kindButton: UInt32 = 2
private let kindLabel: UInt32 = 3
private let valueStr: UInt32 = 4

@Observable
final class KayaNode: Identifiable {
    let id: UInt64
    let kind: UInt32
    var text = ""
    var children: [KayaNode] = []

    init(id: UInt64, kind: UInt32) {
        self.id = id
        self.kind = kind
    }
}

@Observable
final class KayaSceneModel {
    var root: KayaNode?
    var nodes: [UInt64: KayaNode] = [:]  // main actor only
    var firstButton: KayaNode?
    var firstLabel: KayaNode?
}

let kayaScene = KayaSceneModel()

/// The presentation-side functions, handed over by the host kaya rather
/// than resolved through the dynamic linker: hosts may carry kaya
/// statically or load it RTLD_LOCAL, so the vtable pins the one live
/// instance. Populated by kaya_swiftui_run.
enum KayaHost {
    nonisolated(unsafe) static var api: KayaHostApi!

    static func emit(_ widgetId: UInt64) {
        api.emit_button_clicked(widgetId)
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
                let node = KayaNode(id: id, kind: widgetKind)
                kayaScene.nodes[id] = node
                if widgetKind == kindButton && kayaScene.firstButton == nil {
                    kayaScene.firstButton = node
                }
                if widgetKind == kindLabel && kayaScene.firstLabel == nil {
                    kayaScene.firstLabel = node
                }
            case applySetProp:
                let id = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                // prop (u32) is text — the only property at milestone 1 —
                // then u32 pad, then the value.
                let valueType = raw.loadUnaligned(fromByteOffset: body + 16, as: UInt32.self)
                let len = Int(raw.loadUnaligned(fromByteOffset: body + 20, as: UInt32.self))
                precondition(valueType == valueStr, "kaya: expected a string value")
                let bytes = raw[(body + 24)..<(body + 24 + len)]
                kayaScene.nodes[id]!.text = String(decoding: bytes, as: UTF8.self)
            case applyAddChild:
                let parent = raw.loadUnaligned(fromByteOffset: body, as: UInt64.self)
                let child = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt64.self)
                kayaScene.nodes[parent]!.children.append(kayaScene.nodes[child]!)
            case applyMount:
                // window (u64) is the default until the window vocabulary.
                let root = raw.loadUnaligned(fromByteOffset: body + 8, as: UInt64.self)
                kayaScene.root = kayaScene.nodes[root]
            default:
                fatalError("kaya: unknown apply record kind \(kind)")
            }
            at += size
        }
    }
}

/// Drives the round trip without a human, matching the Rust backends'
/// spawn_selftest: emits the occurrence the Button action emits and
/// verifies the rendered model state.
func kayaStartSelftest() {
    guard ProcessInfo.processInfo.environment["KAYA_SELFTEST"] != nil else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        if let button = kayaScene.firstButton { KayaHost.emit(button.id) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
        if let button = kayaScene.firstButton { KayaHost.emit(button.id) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
        let text = kayaScene.firstLabel?.text ?? "(no label)"
        if text == "Clicked 2 times" {
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
                KayaHost.emit(node.id)
            }
        case kindLabel:
            Text(node.text)
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
