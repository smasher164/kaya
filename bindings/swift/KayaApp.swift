// kaya's idiomatic surface for Swift: the structural core.
//
// Three jobs, layered over the generated wire vocabulary
// (KayaWire.swift) and the kaya C declarations (kaya.h via the bridging
// header):
//
//   - id allocation: signals, widgets, collections, and template nodes
//     come from per-space counters behind distinct types, so no app
//     hand-numbers the id spaces — and the compiler keeps blueprint
//     nodes (KayaNodeHandle) from being used where live widgets
//     (KayaWidget) belong;
//   - template scoping: forEach and when take trailing closures whose
//     bodies declare the blueprint, bracketing the records;
//   - occurrence dispatch: handlers register per button; the app loop
//     routes each click, handing template-node handlers the stamped
//     copy's key path. Handlers receive their transaction explicitly;
//     it submits when the handler returns.
//
// (KayaWidget/KayaNodeHandle rather than Widget/Node: the function-
// floor guests share a namespace with whatever UI framework the host
// links, where bare Widget/Node invite collisions.)

import Foundation

struct KayaSignal {
    let id: UInt64
}

/// A live widget: exactly one thing on screen.
struct KayaWidget {
    let id: UInt64
}

/// A template node: a blueprint entry, stamped per collection entry.
/// Never on screen by itself; clicks on its copies arrive with the
/// copy's key path.
struct KayaNodeHandle {
    let id: UInt64
}

struct KayaCollection {
    let id: UInt64
}

final class KayaApp {
    private var signals: UInt64 = 0
    private var widgets: UInt64 = 0
    private var collections: UInt64 = 0
    private var nodes: UInt64 = 0
    private var widgetHandlers: [UInt64: (KayaAppTx) -> Void] = [:]
    private var nodeHandlers: [UInt64: (KayaAppTx, [KayaValue]) -> Void] = [:]

    func nextSignal() -> KayaSignal {
        signals += 1
        return KayaSignal(id: signals)
    }

    func nextWidget() -> KayaWidget {
        widgets += 1
        return KayaWidget(id: widgets)
    }

    func nextNode() -> KayaNodeHandle {
        nodes += 1
        return KayaNodeHandle(id: nodes)
    }

    func nextCollection() -> KayaCollection {
        collections += 1
        return KayaCollection(id: collections)
    }

    /// Run `build` with a fresh transaction and submit it atomically.
    func build(_ build: (KayaAppTx) -> Void) {
        let tx = KayaAppTx(app: self)
        build(tx)
        tx.submitIfAny()
    }

    /// Register a click handler for a live widget.
    func onClick(_ w: KayaWidget, _ handler: @escaping (KayaAppTx) -> Void) {
        widgetHandlers[w.id] = handler
    }

    /// Register a click handler for a template node; it also receives
    /// the stamped copy's keys, outermost first.
    func onClick(_ n: KayaNodeHandle, _ handler: @escaping (KayaAppTx, [KayaValue]) -> Void) {
        nodeHandlers[n.id] = handler
    }

    private func dispatchLoop() {
        var buf = [UInt8](repeating: 0, count: 256)
        while true {
            let size = buf.withUnsafeMutableBufferPointer { p in
                kaya_next_occurrence(p.baseAddress, 256)
            }
            if size == 0 { return } // shutdown
            guard let (id, keys) = kayaParseClick(buf) else { continue }
            if keys.isEmpty {
                if let handler = widgetHandlers[id] {
                    build(handler)
                }
            } else if let handler = nodeHandlers[id] {
                build { tx in handler(tx, keys) }
            }
        }
    }

    /// Enter the core on the calling thread (must be the process main
    /// thread), dispatching occurrences on the app thread. Never
    /// returns on iOS; the exit code path is the self-test's.
    func run() -> Never {
        let thread = Thread { self.dispatchLoop() }
        thread.start()
        exit(kaya_run())
    }
}

/// One transaction: everything queued inside build (or a handler)
/// applies atomically when it returns.
final class KayaAppTx {
    let app: KayaApp
    var tx = KayaTx()

    init(app: KayaApp) {
        self.app = app
    }

    func submitIfAny() {
        if !tx.bytes.isEmpty {
            tx.submit()
        }
    }

    func signal(_ initial: KayaValue) -> KayaSignal {
        let s = app.nextSignal()
        tx.createSignal(s.id, initial)
        return s
    }

    func write(_ s: KayaSignal, _ value: KayaValue) {
        tx.writeSignal(s.id, value)
    }

    func widget(_ kind: UInt32) -> KayaWidget {
        let w = app.nextWidget()
        tx.createWidget(w.id, kind)
        return w
    }

    func setText(_ w: KayaWidget, _ text: String) {
        tx.setText(w.id, text)
    }

    func bindText(_ w: KayaWidget, _ s: KayaSignal) {
        tx.bindText(w.id, s.id)
    }

    func addChild(_ parent: KayaWidget, _ child: KayaWidget) {
        tx.addChild(parent.id, child.id)
    }

    func collection() -> KayaCollection {
        let c = app.nextCollection()
        tx.createCollection(c.id)
        return c
    }

    /// A For over `c`: the closure declares the template; the For
    /// itself (a live container) is returned.
    func forEach(_ c: KayaCollection, _ body: (KayaTpl) -> Void) -> KayaWidget {
        let w = app.nextWidget()
        tx.createFor(w.id, c.id)
        body(KayaTpl(tx: self))
        tx.templateEnd()
        return w
    }

    /// A When over a Bool signal: stamps on true, unstamps on false.
    func when(_ s: KayaSignal, _ body: (KayaTpl) -> Void) -> KayaWidget {
        let w = app.nextWidget()
        tx.createWhen(w.id, s.id)
        body(KayaTpl(tx: self))
        tx.templateEnd()
        return w
    }

    func insert(_ c: KayaCollection, _ path: [KayaValue], _ key: KayaValue, _ value: KayaValue) {
        tx.collectionInsert(c.id, path, key, value)
    }

    func update(_ c: KayaCollection, _ path: [KayaValue], _ key: KayaValue, _ value: KayaValue) {
        tx.collectionUpdate(c.id, path, key, value)
    }

    func remove(_ c: KayaCollection, _ path: [KayaValue], _ key: KayaValue) {
        tx.collectionRemove(c.id, path, key)
    }

    /// Mount into the default window; per-window targets arrive with
    /// the window vocabulary.
    func mount(_ root: KayaWidget) {
        tx.mount(0, root.id)
    }
}

/// A template body: the same declaration vocabulary with template-node
/// ids, plus element bindings.
final class KayaTpl {
    private let tx: KayaAppTx

    init(tx: KayaAppTx) {
        self.tx = tx
    }

    func widget(_ kind: UInt32) -> KayaNodeHandle {
        let n = tx.app.nextNode()
        tx.tx.createWidget(n.id, kind)
        return n
    }

    func setText(_ n: KayaNodeHandle, _ text: String) {
        tx.tx.setText(n.id, text)
    }

    /// Bind text to the element of the enclosing For, `level` Fors up
    /// (0 = nearest).
    func bindTextElement(_ n: KayaNodeHandle, level: UInt32 = 0) {
        tx.tx.bindTextElement(n.id, level: level)
    }

    func addChild(_ parent: KayaNodeHandle, _ child: KayaNodeHandle) {
        tx.tx.addChild(parent.id, child.id)
    }

    func collection() -> KayaCollection {
        tx.collection()
    }

    func forEach(_ c: KayaCollection, _ body: (KayaTpl) -> Void) -> KayaNodeHandle {
        let n = tx.app.nextNode()
        tx.tx.createFor(n.id, c.id)
        body(KayaTpl(tx: tx))
        tx.tx.templateEnd()
        return n
    }

    func when(_ s: KayaSignal, _ body: (KayaTpl) -> Void) -> KayaNodeHandle {
        let n = tx.app.nextNode()
        tx.tx.createWhen(n.id, s.id)
        body(KayaTpl(tx: tx))
        tx.tx.templateEnd()
        return n
    }
}
