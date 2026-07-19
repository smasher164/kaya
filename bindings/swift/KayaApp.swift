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

    /// Mint a derived signal: recomputed when the source is written,
    /// the write batched into the same transaction; the core sees an
    /// ordinary signal. Reaches the open transaction ambiently — the
    /// comparison operators are static, and a signal is only an id.
    func derive(_ compute: @escaping (KayaValue) -> KayaValue) -> KayaSignal {
        guard let app = KayaApp.ambient, let tx = app.currentTx else {
            preconditionFailure(
                "kaya: a derived signal is minted inside a transaction (build or handler)")
        }
        let source = self
        let d = tx.signal(compute(app.signalMirrors[source.id]!))
        tx.pendingSignalDeps.append((source.id, { t in
            let v = compute(t.app.signalMirrors[source.id]!)
            if v != t.app.signalMirrors[d.id]! {
                t.write(d, v)
            }
        }))
        return d
    }

    /// The derive vocabulary (the cross-language canon: eq, ne, lt,
    /// …); the comparison operators below are these methods in
    /// operator clothes.
    func eq(_ other: KayaValue) -> KayaSignal { derive { .bool($0 == other) } }

    func ne(_ other: KayaValue) -> KayaSignal { derive { .bool($0 != other) } }

    func lt(_ other: KayaValue) -> KayaSignal {
        derive { .bool(kayaOrder($0, other) < 0) }
    }

    func gt(_ other: KayaValue) -> KayaSignal {
        derive { .bool(kayaOrder($0, other) > 0) }
    }

    func le(_ other: KayaValue) -> KayaSignal {
        derive { .bool(kayaOrder($0, other) <= 0) }
    }

    func ge(_ other: KayaValue) -> KayaSignal {
        derive { .bool(kayaOrder($0, other) >= 0) }
    }

    static func == <V: KayaValueConvertible>(s: KayaSignal, v: V) -> KayaSignal {
        s.eq(v.kayaValue)
    }

    static func != <V: KayaValueConvertible>(s: KayaSignal, v: V) -> KayaSignal {
        s.ne(v.kayaValue)
    }

    static func < <V: KayaValueConvertible>(s: KayaSignal, v: V) -> KayaSignal {
        s.lt(v.kayaValue)
    }

    static func > <V: KayaValueConvertible>(s: KayaSignal, v: V) -> KayaSignal {
        s.gt(v.kayaValue)
    }

    static func <= <V: KayaValueConvertible>(s: KayaSignal, v: V) -> KayaSignal {
        s.le(v.kayaValue)
    }

    static func >= <V: KayaValueConvertible>(s: KayaSignal, v: V) -> KayaSignal {
        s.ge(v.kayaValue)
    }
}

/// The plain values the comparison operators accept on their right:
/// `stepCount == 1` wraps into the wire scalar itself.
protocol KayaValueConvertible {
    var kayaValue: KayaValue { get }
}

extension Int: KayaValueConvertible {
    var kayaValue: KayaValue { .i64(Int64(self)) }
}

extension Int64: KayaValueConvertible {
    var kayaValue: KayaValue { .i64(self) }
}

extension String: KayaValueConvertible {
    var kayaValue: KayaValue { .str(self) }
}

extension Bool: KayaValueConvertible {
    var kayaValue: KayaValue { .bool(self) }
}

extension Double: KayaValueConvertible {
    var kayaValue: KayaValue { .f64(self) }
}

/// Wire scalars order within their own kind (i64/f64 also across the
/// two numeric kinds); anything else is a declaration bug, loudly.
func kayaOrder(_ a: KayaValue, _ b: KayaValue) -> Int {
    func cmp<T: Comparable>(_ x: T, _ y: T) -> Int { x == y ? 0 : (x < y ? -1 : 1) }
    switch (a, b) {
    case (.i64(let x), .i64(let y)): return cmp(x, y)
    case (.f64(let x), .f64(let y)): return cmp(x, y)
    case (.i64(let x), .f64(let y)): return cmp(Double(x), y)
    case (.f64(let x), .i64(let y)): return cmp(x, Double(y))
    case (.str(let x), .str(let y)): return cmp(x, y)
    default:
        preconditionFailure("kaya: \(a) and \(b) have no order")
    }
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

/// A collection instance handle: the collection plus the key path
/// selecting one stamped copy's table. tx.collection() returns the
/// root (empty-path, live-zone) handle; at(_:) steps into a copy, one
/// key per enclosing For. Mutations and reads take the handle, so the
/// target is spelled once.
struct KayaCollection {
    let id: UInt64
    let path: [KayaValue]

    /// The instance of this collection inside the copy keyed by `key`
    /// of the next enclosing For; chain for deeper nesting.
    func at(_ key: KayaValue) -> KayaCollection {
        KayaCollection(id: id, path: path + [key])
    }

    /// A For binds the collection itself — its template stamps per
    /// entry of every instance — so handing it an at(...) handle is a
    /// bug.
    fileprivate func assertRoot() {
        precondition(
            path.isEmpty,
            "kaya: forEach binds the collection itself, not an instance — drop the at(...)")
    }
}

/// One instance of a collection: the table inside the stamped copy
/// selected by `path` (the empty path for a live-zone collection).
/// Entries keep insertion order, matching the core's rendering.
private struct KayaInstance {
    let path: [KayaValue]
    // Any: a KayaValue for scalar collections, the record struct itself
    // for record collections — the model is guest-owned, so it keeps
    // native values and only wire fields ever encode.
    var entries: [(key: KayaValue, value: Any)]
}

final class KayaApp {
    private var signals: UInt64 = 0
    private var widgets: UInt64 = 0
    private var collections: UInt64 = 0
    private var nodes: UInt64 = 0
    private var widgetHandlers: [UInt64: (KayaAppTx) throws -> Void] = [:]
    private var nodeHandlers: [UInt64: (KayaAppTx, [KayaValue]) throws -> Void] = [:]
    private var widgetChanges: [UInt64: (KayaAppTx, String) throws -> Void] = [:]
    private var nodeChanges: [UInt64: (KayaAppTx, [KayaValue], String) throws -> Void] = [:]
    private var widgetToggles: [UInt64: (KayaAppTx, Bool) throws -> Void] = [:]
    private var widgetValues: [UInt64: (KayaAppTx, Double) throws -> Void] = [:]
    private var nodeToggles: [UInt64: (KayaAppTx, [KayaValue], Bool) throws -> Void] = [:]

    // The collection is the model — the only copy: every mutation op
    // edits it and queues the wire delta in the same call, so reads
    // (items, count) are exactly the writes. childCollections records
    // the declared-inside-a-For edges the model purges along when a
    // parent entry's copy is torn down.
    // Ambient state for the operator/derive and for-in sugar: one app
    // per guest process (the Python binding's own assumption), and the
    // operators/tracers are static code — a signal or collection is
    // only an id, so the sugar reaches the open transaction here.
    static var ambient: KayaApp?
    var currentTx: KayaAppTx?
    var signalMirrors: [UInt64: KayaValue] = [:]
    var signalDeps: [UInt64: [(KayaAppTx) -> Void]] = [:]
    // Container builders collect children ambiently, in evaluation
    // order (a frame per open container); a for-in row trace appends
    // its For widget to the top frame at close.
    var childFrames: [[UInt64]] = []
    var openTraces = 0

    init() {
        KayaApp.ambient = self
    }

    private var model: [UInt64: [KayaInstance]] = [:]
    private var childCollections: [UInt64: [UInt64]] = [:]
    fileprivate var openFors: [UInt64] = []
    // Signals recomputed from a collection after each of its
    // mutations, written into the same transaction.
    var derived: [UInt64: [(KayaAppTx) -> Void]] = [:]

    /// A collection declared inside a For's template is torn down with
    /// its copies: record the edge so the model purges along it.
    fileprivate func registerCollection(_ id: UInt64) {
        if let parent = openFors.last {
            childCollections[parent, default: []].append(id)
        }
    }

    /// Journal one collection's instances into the open transaction the
    /// first time it mutates them (value semantics make the snapshot a
    /// cheap copy-on-write). nil records that the collection had no
    /// model entry before this transaction.
    fileprivate func touchModel(_ coll: UInt64) {
        guard let tx = currentTx else { return }
        if tx.journal.index(forKey: coll) == nil {
            tx.journal[coll] = model[coll]
        }
    }

    fileprivate func restoreModel(_ journal: [UInt64: [KayaInstance]?]) {
        for (id, saved) in journal {
            if let saved {
                model[id] = saved
            } else {
                model.removeValue(forKey: id)
            }
        }
    }

    fileprivate func modelSet(_ coll: UInt64, _ path: [KayaValue], _ key: KayaValue, _ value: Any) {
        touchModel(coll)
        var instances = model[coll, default: []]
        let at = instances.firstIndex { $0.path == path } ?? {
            instances.append(KayaInstance(path: path, entries: []))
            return instances.count - 1
        }()
        if let slot = instances[at].entries.firstIndex(where: { $0.key == key }) {
            instances[at].entries[slot].value = value
        } else {
            instances[at].entries.append((key: key, value: value))
        }
        model[coll] = instances
    }

    fileprivate func modelRemove(_ coll: UInt64, _ path: [KayaValue], _ key: KayaValue) {
        touchModel(coll)
        if var instances = model[coll], let at = instances.firstIndex(where: { $0.path == path }) {
            instances[at].entries.removeAll { $0.key == key }
            model[coll] = instances
        }
        // The core tears down the copy, taking descendant collection
        // instances with it; the model follows.
        purgeChildren(coll, prefix: path + [key])
    }

    fileprivate func keysOf(_ coll: UInt64, _ path: [KayaValue]) -> [KayaValue] {
        model[coll]?.first { $0.path == path }?.entries.map { $0.key } ?? []
    }

    fileprivate func modelMove(
        _ coll: UInt64, _ path: [KayaValue], _ key: KayaValue, _ before: [KayaValue]
    ) {
        touchModel(coll)
        // The same checks the scene makes, made where the guest can
        // see the stack: a missing key or anchor is a guest bug, never
        // a fallback. Both validated before anything mutates.
        guard var instances = model[coll], let at = instances.firstIndex(where: { $0.path == path }),
            let pos = instances[at].entries.firstIndex(where: { $0.key == key })
        else { preconditionFailure("kaya: move of missing key \(key)") }
        if let anchor = before.first {
            precondition(
                instances[at].entries.contains { $0.key == anchor },
                "kaya: move before missing key \(anchor)")
        }
        let entry = instances[at].entries.remove(at: pos)
        let slot = before.first.flatMap { anchor in
            instances[at].entries.firstIndex { $0.key == anchor }
        } ?? instances[at].entries.count
        instances[at].entries.insert(entry, at: slot)
        model[coll] = instances
    }

    private func purgeChildren(_ coll: UInt64, prefix: [KayaValue]) {
        for kid in childCollections[coll, default: []] {
            touchModel(kid)
            model[kid]?.removeAll { instance in
                instance.path.count >= prefix.count
                    && Array(instance.path[0..<prefix.count]) == prefix
            }
            purgeChildren(kid, prefix: prefix)
        }
    }

    fileprivate func instanceEntries(_ coll: UInt64, _ path: [KayaValue])
        -> [(key: KayaValue, value: Any)]
    {
        model[coll]?.first { $0.path == path }?.entries ?? []
    }

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
        return KayaCollection(id: collections, path: [])
    }

    /// Run `build` with a fresh transaction and submit it atomically.
    /// The body's result comes back out — the way a scene's handles
    /// reach the handlers. A throw out of the body abandons the
    /// transaction: the records never ship and the journal restores
    /// the model and signal mirrors to exactly what was shipped — then
    /// the error continues to the caller. The tx boundary rolls back
    /// and propagates; whether the app survives is the caller's
    /// decision (the dispatch loop survives).
    func build<R>(_ build: (KayaAppTx) throws -> R) rethrows -> R {
        let tx = KayaAppTx(app: self)
        do {
            let out = try build(tx)
            tx.submitIfAny()
            return out
        } catch {
            tx.rollback()
            throw error
        }
    }

    /// Register a click handler for a live widget.
    func onClick(_ w: KayaWidget, _ handler: @escaping (KayaAppTx) throws -> Void) {
        widgetHandlers[w.id] = handler
    }

    /// Register a click handler for a template node; it also receives
    /// the stamped copy's keys, outermost first.
    func onClick(_ n: KayaNodeHandle, _ handler: @escaping (KayaAppTx, [KayaValue]) throws -> Void) {
        nodeHandlers[n.id] = handler
    }

    /// Register a change handler for a live entry: the widget owns its
    /// text and reports each edit here; the app folds the text into its
    /// own state — there is no read-back, by doctrine.
    func onChange(_ w: KayaWidget, _ handler: @escaping (KayaAppTx, String) throws -> Void) {
        widgetChanges[w.id] = handler
    }

    /// Register a change handler for a template entry; it also receives
    /// the stamped copy's keys, outermost first.
    func onChange(
        _ n: KayaNodeHandle, _ handler: @escaping (KayaAppTx, [KayaValue], String) throws -> Void
    ) {
        nodeChanges[n.id] = handler
    }

    /// Register a toggle handler for a live checkbox: the box owns its
    /// checked bit and reports each flip here; the app folds it into
    /// its own state.
    func onToggle(_ w: KayaWidget, _ handler: @escaping (KayaAppTx, Bool) throws -> Void) {
        widgetToggles[w.id] = handler
    }

    /// A live slider's change handler: the bar owns its position and
    /// reports each move with the new value — the entry's uncontrolled
    /// contract, with a Double.
    func onValueChanged(_ w: KayaWidget, _ handler: @escaping (KayaAppTx, Double) throws -> Void) {
        widgetValues[w.id] = handler
    }

    /// Register a toggle handler for a template checkbox; it also
    /// receives the stamped copy's keys, outermost first.
    func onToggle(
        _ n: KayaNodeHandle, _ handler: @escaping (KayaAppTx, [KayaValue], Bool) throws -> Void
    ) {
        nodeToggles[n.id] = handler
    }

    /// One handler dispatch: a throw crosses the build boundary (which
    /// has already rolled the mirrors back and dropped the records), is
    /// logged, and the loop moves to the next occurrence — the uniform
    /// dispatch discipline across every binding. Traps still die.
    private func dispatch(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            FileHandle.standardError.write(
                Data("kaya: handler threw (transaction rolled back): \(error)\n".utf8))
        }
    }

    private func dispatchLoop() {
        var buf = [UInt8](repeating: 0, count: 256)
        while true {
            let size = buf.withUnsafeMutableBufferPointer { p in
                kaya_next_occurrence(p.baseAddress, 256)
            }
            if size == 0 { return } // shutdown
            guard let (kind, id, keys, payload) = kayaParseOccurrence(buf) else { continue }
            var text: String?
            var checked = false
            var value = 0.0
            switch payload {
            case .str(let s): text = s
            case .bool(let b): checked = b
            case .f64(let x): value = x
            default: break
            }
            switch (kind, keys.isEmpty) {
            case (UInt16(KAYA_OCCURRENCE_BUTTON_CLICKED), true):
                if let handler = widgetHandlers[id] {
                    dispatch { try build(handler) }
                }
            case (UInt16(KAYA_OCCURRENCE_BUTTON_CLICKED), false):
                if let handler = nodeHandlers[id] {
                    dispatch { try build { tx in try handler(tx, keys) } }
                }
            case (UInt16(KAYA_OCCURRENCE_TEXT_CHANGED), true):
                if let handler = widgetChanges[id] {
                    dispatch { try build { tx in try handler(tx, text ?? "") } }
                }
            case (UInt16(KAYA_OCCURRENCE_TEXT_CHANGED), false):
                if let handler = nodeChanges[id] {
                    dispatch { try build { tx in try handler(tx, keys, text ?? "") } }
                }
            case (UInt16(KAYA_OCCURRENCE_TOGGLED), true):
                if let handler = widgetToggles[id] {
                    dispatch { try build { tx in try handler(tx, checked) } }
                }
            case (UInt16(KAYA_OCCURRENCE_TOGGLED), false):
                if let handler = nodeToggles[id] {
                    dispatch { try build { tx in try handler(tx, keys, checked) } }
                }
            case (UInt16(KAYA_OCCURRENCE_VALUE_CHANGED), true):
                if let handler = widgetValues[id] {
                    dispatch { try build { tx in try handler(tx, value) } }
                }
            default:
                break
            }
        }
    }

    /// Enter the core on the calling thread (must be the process main
    /// thread), dispatching occurrences on the app thread. Never
    /// returns on iOS; the exit code path is the self-test's.
    func run() -> Never {
        // The stale-artifact guard: this binding was generated from one
        // spec revision; the loaded library must speak the same one.
        precondition(
            kaya_spec_hash() == kayaSpecHash,
            "kaya: library speaks spec \(String(kaya_spec_hash(), radix: 16)), this binding "
                + "was generated from \(String(kayaSpecHash, radix: 16)) — rebuild the "
                + "library or regenerate bindings")
        let thread = Thread { self.dispatchLoop() }
        thread.start()
        exit(kaya_run())
    }
}

/// One transaction: everything queued inside build (or a handler)
/// applies atomically when it returns.
/// The container builder: each expression appends its handle to the
/// enclosing container's ambient frame, in evaluation order — which
/// lets a `for row in todos.rows { … }` statement stand between
/// siblings (the tracer appends the For widget itself at close; the
/// loop contributes nothing through the builder).
@resultBuilder
enum KayaChildren {
    static func buildExpression(_ w: KayaWidget) {
        guard let app = KayaApp.ambient, !app.childFrames.isEmpty else {
            preconditionFailure("kaya: a container builder has no open frame")
        }
        app.childFrames[app.childFrames.count - 1].append(w.id)
    }

    // A template node at statement position inside a live container:
    // legal only as a for-in row trace's body (the node is already
    // template-rooted; the builder discards the handle).
    static func buildExpression(_ n: KayaNodeHandle) {
        guard let app = KayaApp.ambient, app.openTraces > 0 else {
            preconditionFailure(
                "kaya: a template node cannot parent into a live container "
                    + "— it belongs to a for-in row trace's body")
        }
        _ = n
    }

    static func buildBlock(_: Void...) {}

    static func buildArray(_: [Void]) {}
}

@resultBuilder
enum KayaNodeChildren {
    static func buildExpression(_ n: KayaNodeHandle) {
        guard let app = KayaApp.ambient, !app.childFrames.isEmpty else {
            preconditionFailure("kaya: a container builder has no open frame")
        }
        app.childFrames[app.childFrames.count - 1].append(n.id)
    }

    static func buildBlock(_: Void...) {}

    static func buildArray(_: [Void]) {}
}

/// The for-statement tracer over a record collection's rows (the
/// generated `todos.rows` returns one): the loop body runs once,
/// authoring the For's template; the tracer opens the template on the
/// first element and closes it — appending the For widget to the
/// enclosing container's ambient frame — when the loop asks for a
/// second. Statement-position iteration needs a container builder
/// around it; stamping is the core's replay, never Swift iteration.
struct KayaRowTrace<Row>: Sequence, IteratorProtocol {
    let collection: KayaCollection
    let makeRow: (KayaTpl) -> Row
    private var state = 0
    private var forId: UInt64 = 0

    init(collection: KayaCollection, makeRow: @escaping (KayaTpl) -> Row) {
        self.collection = collection
        self.makeRow = makeRow
    }

    mutating func next() -> Row? {
        guard let app = KayaApp.ambient, let tx = app.currentTx else {
            preconditionFailure(
                "kaya: rows iterates at record time, inside a transaction")
        }
        if state == 0 {
            state = 1
            collection.assertRoot()
            let w = app.nextWidget()
            forId = w.id
            tx.tx.createFor(w.id, collection.id)
            app.openFors.append(collection.id)
            app.openTraces += 1
            return makeRow(KayaTpl(tx: tx))
        }
        if state == 1 {
            state = 2
            app.openFors.removeLast()
            tx.tx.templateEnd()
            app.openTraces -= 1
            precondition(
                !app.childFrames.isEmpty,
                "kaya: a for-in over rows needs an enclosing container builder")
            app.childFrames[app.childFrames.count - 1].append(forId)
        }
        return nil
    }
}

final class KayaAppTx {
    let app: KayaApp
    var tx = KayaTx()
    // How to undo this transaction's mirror edits: a snapshot per
    // touched collection / signal, taken on first touch (nil = it did
    // not exist before this transaction). Derived registrations are
    // pure data until the commit promotes them — an abandoned
    // transaction abandons its registrations with its records.
    fileprivate var journal: [UInt64: [KayaInstance]?] = [:]
    var signalJournal: [UInt64: KayaValue?] = [:]
    var pendingSignalDeps: [(UInt64, (KayaAppTx) -> Void)] = []
    var pendingDerived: [(UInt64, (KayaAppTx) -> Void)] = []

    init(app: KayaApp) {
        self.app = app
        app.currentTx = self
    }

    func submitIfAny() {
        precondition(
            app.openTraces == 0,
            "kaya: a for-in over rows was exited early (break?) — the template never closed")
        app.currentTx = nil
        for (id, recompute) in pendingSignalDeps {
            app.signalDeps[id, default: []].append(recompute)
        }
        for (id, recompute) in pendingDerived {
            app.derived[id, default: []].append(recompute)
        }
        if !tx.bytes.isEmpty {
            tx.submit()
        }
    }

    /// The commit's mirror image: restore every touched mirror entry
    /// and drop the records with the pending registrations. Reads
    /// after an abandoned transaction show exactly what was shipped.
    func rollback() {
        app.currentTx = nil
        app.restoreModel(journal)
        for (id, old) in signalJournal {
            if let old {
                app.signalMirrors[id] = old
            } else {
                app.signalMirrors.removeValue(forKey: id)
            }
        }
    }

    func touchSignal(_ id: UInt64) {
        if signalJournal.index(forKey: id) == nil {
            signalJournal[id] = app.signalMirrors[id]
        }
    }

    func signal(_ initial: KayaValue) -> KayaSignal {
        let s = app.nextSignal()
        tx.createSignal(s.id, initial)
        touchSignal(s.id)
        app.signalMirrors[s.id] = initial
        return s
    }

    func write(_ s: KayaSignal, _ value: KayaValue) {
        tx.writeSignal(s.id, value)
        touchSignal(s.id)
        app.signalMirrors[s.id] = value
        // The dependents recompute now, batched into this transaction
        // (a derived write chains through here again for its own
        // dependents).
        for recompute in app.signalDeps[s.id, default: []] {
            recompute(self)
        }
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

    func setChecked(_ w: KayaWidget, _ checked: Bool) {
        tx.setChecked(w.id, checked)
    }

    func bindChecked(_ w: KayaWidget, _ s: KayaSignal) {
        tx.bindChecked(w.id, s.id)
    }

    // One-shot commands: momentary verbs into widget-owned state,
    // riding the open transaction like any record — the insert and the
    // clear beside it commit together or not at all. Fire-and-forget:
    // no mirror state, nothing to journal; the widget answers through
    // its normal occurrence path (a clear arrives back as
    // text_changed("") and the app's draft fold empties itself).
    // Commands take a KayaWidget only — a KayaNodeHandle is a
    // blueprint, and a blueprint has nothing to clear (the type-level
    // arm of the scene's own template rejection).

    /// Drop an entry's content now (the field stays authoritative).
    func clear(_ w: KayaWidget) {
        tx.widgetCommand(w.id, UInt32(KAYA_COMMAND_CLEAR))
    }

    /// Give this widget the keyboard focus.
    func focus(_ w: KayaWidget) {
        tx.widgetCommand(w.id, UInt32(KAYA_COMMAND_FOCUS))
    }

    // --- Construction sugar: the tree reads as a tree ----------------
    //
    // Co-located constructors (props and handlers at the declaration
    // site) and result-builder containers, so the build closure is the
    // scene's shape. Everything lowers eagerly to the same records —
    // the builder block runs like any closure, children first, then
    // the container and its addChilds. Sugar over the record calls,
    // never a scene value interpreted later.

    func button(_ text: String? = nil, onClick: ((KayaAppTx) throws -> Void)? = nil) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_BUTTON))
        if let text { setText(w, text) }
        if let onClick { app.onClick(w, onClick) }
        return w
    }

    func entry(onChange: ((KayaAppTx, String) throws -> Void)? = nil) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_ENTRY))
        if let onChange { app.onChange(w, onChange) }
        return w
    }

    func label(_ text: String? = nil, bind: KayaSignal? = nil) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_LABEL))
        if let text { setText(w, text) }
        if let bind { bindText(w, bind) }
        return w
    }

    /// A slider over min...max at value, with its change handler
    /// co-located.
    func slider(
        min: Double = 0.0, max: Double = 1.0, value: Double = 0.0,
        onChange: ((KayaAppTx, Double) throws -> Void)? = nil
    ) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_SLIDER))
        tx.setMin(w.id, min)
        tx.setMax(w.id, max)
        tx.setValue(w.id, value)
        if let onChange { app.onValueChanged(w, onChange) }
        return w
    }

    func checkbox(
        _ text: String? = nil, checked: Bool? = nil,
        onToggle: ((KayaAppTx, Bool) throws -> Void)? = nil
    ) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_CHECKBOX))
        if let text { setText(w, text) }
        if let checked { setChecked(w, checked) }
        if let onToggle { app.onToggle(w, onToggle) }
        return w
    }

    func column(@KayaChildren _ children: () -> Void) -> KayaWidget {
        containerOf(UInt32(KAYA_KIND_COLUMN), children)
    }

    func row(@KayaChildren _ children: () -> Void) -> KayaWidget {
        containerOf(UInt32(KAYA_KIND_ROW), children)
    }

    private func containerOf(_ kind: UInt32, _ children: () -> Void) -> KayaWidget {
        // Parent before children: statement-shaped construction is
        // parent-first in every language (expression trees are
        // children-first because arguments evaluate before the call) —
        // creation order is observable (column#N) and derivable from
        // the construction style, never per-language trivia.
        let parent = widget(kind)
        app.childFrames.append([])
        children()
        let ids = app.childFrames.removeLast()
        for id in ids { tx.addChild(parent.id, id) }
        return parent
    }

    /// A For as a child: forEach whose body keeps no handles — the
    /// common case once handlers co-locate at their constructors.
    func each(_ c: KayaCollection, _ body: (KayaTpl) -> Void) -> KayaWidget {
        forEach(c) { body($0) }.0
    }

    func addChild(_ parent: KayaWidget, _ child: KayaWidget) {
        tx.addChild(parent.id, child.id)
    }

    func collection() -> KayaCollection {
        let c = app.nextCollection()
        app.registerCollection(c.id)
        tx.createCollection(c.id, [[UInt32(KAYA_VALUE_STR)]])
        return c
    }

    /// A For over `c`: the closure declares the template; the For
    /// itself (a live container) comes back alongside the body's
    /// result — the way handles declared inside the template (nested
    /// collections, buttons) reach the handlers.
    func forEach<R>(_ c: KayaCollection, _ body: (KayaTpl) -> R) -> (KayaWidget, R) {
        c.assertRoot()
        let w = app.nextWidget()
        tx.createFor(w.id, c.id)
        app.openFors.append(c.id)
        let out = body(KayaTpl(tx: self))
        app.openFors.removeLast()
        tx.templateEnd()
        return (w, out)
    }

    /// A When over a Bool signal: stamps on true, unstamps on false.
    func when<R>(_ s: KayaSignal, _ body: (KayaTpl) -> R) -> (KayaWidget, R) {
        let w = app.nextWidget()
        tx.createWhen(w.id, s.id)
        let out = body(KayaTpl(tx: self))
        tx.templateEnd()
        return (w, out)
    }

    // Every derived signal rooted at this collection, recomputed and
    // written into this transaction. Deriveds hang off root handles,
    // so nested-instance mutations cannot change their input.
    func recomputeDerived(_ c: KayaCollection) {
        guard c.path.isEmpty else { return }
        for recompute in app.derived[c.id, default: []] {
            recompute(self)
        }
    }

    func insert(_ c: KayaCollection, _ key: KayaValue, _ value: KayaValue) {
        app.modelSet(c.id, c.path, key, value)
        tx.collectionInsert(c.id, c.path, key, 0, [value])
        recomputeDerived(c)
    }

    func update(_ c: KayaCollection, _ key: KayaValue, _ value: KayaValue) {
        app.modelSet(c.id, c.path, key, value)
        tx.collectionUpdate(c.id, c.path, key, 0, [value])
        recomputeDerived(c)
    }

    func remove(_ c: KayaCollection, _ key: KayaValue) {
        app.modelRemove(c.id, c.path, key)
        tx.collectionRemove(c.id, c.path, key)
        recomputeDerived(c)
    }

    /// Repositions an entry before another's: order is collection
    /// data, so the model reorders and the wire carries the same
    /// keys-only delta. Keys, never indices. A missing key or anchor
    /// traps here, at the call site — the same check the scene makes;
    /// moving an entry before itself is a no-op, and nothing travels.
    func moveBefore(_ c: KayaCollection, _ key: KayaValue, _ anchor: KayaValue) {
        moveEntry(c, key, [anchor])
    }

    /// Repositions an entry at the end of its collection.
    func moveToEnd(_ c: KayaCollection, _ key: KayaValue) {
        moveEntry(c, key, [])
    }

    /// Repositions an entry at the front: sugar for moveBefore the
    /// current first key, lowering to the same wire op.
    func moveToFront(_ c: KayaCollection, _ key: KayaValue) {
        guard let first = app.keysOf(c.id, c.path).first else {
            preconditionFailure("kaya: move of missing key \(key)")
        }
        moveEntry(c, key, [first])
    }

    /// Repositions an entry directly after another's: sugar for
    /// moveBefore the anchor's successor (moveToEnd when the anchor is
    /// last), lowering to the same wire op.
    func moveAfter(_ c: KayaCollection, _ key: KayaValue, _ anchor: KayaValue) {
        let keys = app.keysOf(c.id, c.path)
        precondition(keys.contains(key), "kaya: move of missing key \(key)")
        guard let at = keys.firstIndex(of: anchor) else {
            preconditionFailure("kaya: move after missing key \(anchor)")
        }
        if key == anchor { return }
        if at + 1 == keys.count {
            moveEntry(c, key, [])
            return
        }
        if keys[at + 1] == key { return }  // already directly after the anchor
        moveEntry(c, key, [keys[at + 1]])
    }

    private func moveEntry(_ c: KayaCollection, _ key: KayaValue, _ before: [KayaValue]) {
        if before.first == key {
            // Moving before itself: order unchanged and nothing
            // travels — but the key must exist, the check the scene
            // would make.
            precondition(
                app.keysOf(c.id, c.path).contains(key),
                "kaya: move of missing key \(key)")
            return
        }
        app.modelMove(c.id, c.path, key, before)
        tx.collectionMove(c.id, c.path, key, before)
        recomputeDerived(c)
    }

    /// The model: what this guest wrote, exactly — the fold of every
    /// patch so far (this transaction's included), in insertion order.
    func items(_ c: KayaCollection) -> [(key: KayaValue, value: KayaValue)] {
        app.instanceEntries(c.id, c.path).map { (key: $0.key, value: $0.value as! KayaValue) }
    }

    // The raw record paths KayaRecords builds on: the model keeps the
    // record struct itself; only the wire fields travel.
    func collectionWithSchema(_ schema: [UInt32]) -> KayaCollection {
        collectionWithVariants([schema])
    }

    func collectionWithVariants(_ variants: [[UInt32]]) -> KayaCollection {
        let c = app.nextCollection()
        app.registerCollection(c.id)
        tx.createCollection(c.id, variants)
        return c
    }

    func emitVariantCase(_ variant: UInt32) {
        tx.variantCase(variant)
    }

    func insertRecordRaw(
        _ c: KayaCollection, _ key: KayaValue, _ model: Any, _ variant: UInt32,
        _ fields: [KayaValue]
    ) {
        app.modelSet(c.id, c.path, key, model)
        tx.collectionInsert(c.id, c.path, key, variant, fields)
        recomputeDerived(c)
    }

    func updateRecordRaw(
        _ c: KayaCollection, _ key: KayaValue, _ model: Any, _ variant: UInt32,
        _ fields: [KayaValue]
    ) {
        app.modelSet(c.id, c.path, key, model)
        tx.collectionUpdate(c.id, c.path, key, variant, fields)
        recomputeDerived(c)
    }

    func updateFieldRaw(
        _ c: KayaCollection, _ key: KayaValue, _ model: Any, _ variant: UInt32,
        _ field: UInt32, _ value: KayaValue
    ) {
        app.modelSet(c.id, c.path, key, model)
        tx.collectionUpdateField(c.id, c.path, key, field, variant, value)
        recomputeDerived(c)
    }

    func recordEntries(_ c: KayaCollection) -> [(key: KayaValue, value: Any)] {
        app.instanceEntries(c.id, c.path)
    }

    func count(_ c: KayaCollection) -> Int {
        app.instanceEntries(c.id, c.path).count
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

    /// Bind a label's text to one field of the element; KayaField<String>
    /// only — the token pins the type at compile time.
    func bindTextField(_ n: KayaNodeHandle, level: UInt32 = 0, _ f: KayaField<String>) {
        tx.tx.bindTextElement(n.id, level: level, field: f.index)
    }

    /// Bind a checkbox's state to one field of the element;
    /// KayaField<Bool> only.
    func bindCheckedField(_ n: KayaNodeHandle, level: UInt32 = 0, _ f: KayaField<Bool>) {
        tx.tx.bindCheckedElement(n.id, level: level, field: f.index)
    }

    // Construction sugar, template flavor: one name per widget, the
    // argument's type picks the addressable source (constant, signal,
    // or element field); handlers receive the stamped copy's keys
    // first.
    func label(_ text: String) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_LABEL))
        setText(n, text)
        return n
    }

    func label(_ s: KayaSignal) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_LABEL))
        tx.tx.bindText(n.id, s.id)
        return n
    }

    func label(_ f: KayaField<String>) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_LABEL))
        bindTextField(n, f)
        return n
    }

    func checkbox(
        _ f: KayaField<Bool>,
        onToggle: ((KayaAppTx, [KayaValue], Bool) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_CHECKBOX))
        bindCheckedField(n, f)
        if let onToggle { tx.app.onToggle(n, onToggle) }
        return n
    }

    func row(@KayaNodeChildren _ children: () -> Void) -> KayaNodeHandle {
        nodeContainerOf(UInt32(KAYA_KIND_ROW), children)
    }

    func column(@KayaNodeChildren _ children: () -> Void) -> KayaNodeHandle {
        nodeContainerOf(UInt32(KAYA_KIND_COLUMN), children)
    }

    private func nodeContainerOf(_ kind: UInt32, _ children: () -> Void) -> KayaNodeHandle {
        let parent = widget(kind)
        tx.app.childFrames.append([])
        children()
        let ids = tx.app.childFrames.removeLast()
        for id in ids { tx.tx.addChild(parent.id, id) }
        return parent
    }

    func addChild(_ parent: KayaNodeHandle, _ child: KayaNodeHandle) {
        tx.tx.addChild(parent.id, child.id)
    }

    func collection() -> KayaCollection {
        tx.collection()
    }

    func forEach<R>(_ c: KayaCollection, _ body: (KayaTpl) -> R) -> (KayaNodeHandle, R) {
        c.assertRoot()
        let n = tx.app.nextNode()
        tx.tx.createFor(n.id, c.id)
        tx.app.openFors.append(c.id)
        let out = body(KayaTpl(tx: tx))
        tx.app.openFors.removeLast()
        tx.tx.templateEnd()
        return (n, out)
    }

    func when<R>(_ s: KayaSignal, _ body: (KayaTpl) -> R) -> (KayaNodeHandle, R) {
        let n = tx.app.nextNode()
        tx.tx.createWhen(n.id, s.id)
        let out = body(KayaTpl(tx: tx))
        tx.tx.templateEnd()
        return (n, out)
    }
}
