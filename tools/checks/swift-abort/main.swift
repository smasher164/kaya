// The uniform-abort guard, Swift arm; tools/check-abort.py builds and
// runs it. HEADLESS: the library links and records submit, but the core
// loop is never entered. Compiled as ONE MODULE with bindings/swift/*.swift,
// so the internal mirrors (signalMirrors, signalDeps) are in reach.

import Foundation

// The record-time mirror-read guard, trap side: a preconditionFailure
// is uncatchable in Swift, so each trapping arm runs in a re-exec of
// this binary (KAYA_GUARD_TRAP=for|when) that must die before reaching
// its exit(0). Exit 0 here means the guard did NOT fire.
if let trap = ProcessInfo.processInfo.environment["KAYA_GUARD_TRAP"] {
    let app = KayaApp()
    app.build { tx in
        let c = tx.collection()
        tx.insert(c, .str("a"), .str("one"))
        switch trap {
        case "for":
            _ = tx.forEach(c) { _ in tx.items(c) }
        case "when":
            let s = tx.signal(.bool(false))
            _ = tx.when(s) { _ in tx.count(c) }
        case "shortcut":
            // The binding's one shortcut parser rejects aliases with a
            // preconditionFailure — uncatchable, so it is pinned the
            // same way as the mirror-read guard: the child must die.
            _ = tx.item("Bad", shortcut: "ctrl+s")
        default:
            FileHandle.standardError.write(Data("unknown KAYA_GUARD_TRAP: \(trap)\n".utf8))
        }
    }
    print("swift guard trap \(trap): guard did not fire")
    exit(0)
}

struct CheckError: Error {}

func entryKeys(_ tx: KayaAppTx, _ c: KayaCollection) -> [KayaValue] {
    tx.items(c).map { $0.key }
}

let app = KayaApp()

// ONE ID SPACE: a template node draws from the WIDGET counter (DESIGN.md,
// Binding conventions). FIRST, so the run starts at 1. THE CONTIGUOUS RUN
// IS THE ASSERTION, not inequality — a private node counter restarted at 1
// sits under the live ids an app has spent and passes a `!=`.
var idRun: [UInt64] = []
app.build { tx in
    idRun.append(tx.label("live").id)
    let rows = tx.collection()
    // The For's own container is a live widget; the node is inside it.
    let (site, node) = tx.forEach(rows) { t in t.label("row").id }
    idRun.append(site.id)
    idRun.append(node)
    idRun.append(tx.label("live").id)
}
precondition(idRun == [1, 2, 3, 4], "widget/node ids \(idRun) — want [1, 2, 3, 4] from one counter")

var todos: KayaCollection!
var counter: KayaSignal!
app.build { tx in
    todos = tx.collection()
    tx.insert(todos, .str("a"), .str("one"))
    tx.insert(todos, .str("b"), .str("two"))
    counter = tx.signal(.str("x"))
}
app.build { tx in
    precondition(
        entryKeys(tx, todos) == [.str("a"), .str("b")],
        "commit did not reach the mirror: \(entryKeys(tx, todos))")
}

// Abort mid-transaction after mutating: the boundary must restore the
// mirrors and rethrow (rollback + propagate is the tx boundary's
// contract; surviving is the dispatch loop's).
var propagated = false
do {
    try app.build { tx in
        tx.insert(todos, .str("c"), .str("three"))
        tx.remove(todos, .str("a"))
        tx.write(counter, .str("y"))
        _ = counter.derive { $0 }
        throw CheckError()
    }
} catch {
    propagated = error is CheckError
}
precondition(propagated, "build swallowed the throw — the tx boundary must propagate")
app.build { tx in
    precondition(
        entryKeys(tx, todos) == [.str("a"), .str("b")],
        "abort did not restore the mirror: \(entryKeys(tx, todos))")
}
precondition(
    app.signalMirrors[counter.id] == .str("x"),
    "abort did not restore the signal mirror: \(String(describing: app.signalMirrors[counter.id]))")

// An aborted transaction abandons its derived-signal registrations
// with its records: the pending list promotes only on commit.
precondition(
    (app.signalDeps[counter.id] ?? []).isEmpty,
    "aborted tx leaked \(app.signalDeps[counter.id]!.count) derived-signal registrations")

// A post-abort commit works and sees the restored model.
app.build { tx in
    tx.insert(todos, .str("c"), .str("three"))
}
app.build { tx in
    precondition(
        entryKeys(tx, todos) == [.str("a"), .str("b"), .str("c")],
        "post-abort commit broken: \(entryKeys(tx, todos))")
}

// The record-time mirror-read guard, legal side: a read after the
// template scope closes — in the very transaction that declared it —
// and the build-tx reads pinned above all stay legal.
app.build { tx in
    _ = tx.forEach(todos) { t in t.label("x") }
    precondition(
        tx.count(todos) == 3,
        "post-scope read broken: \(tx.count(todos))")
}

// The menu construction surface must REACH the record stream: a
// constructor that emits nothing passes every surface gate until a scene
// fails live. Each frame is u32 length then u16 kind at offset 4, LE.
func recordKinds(_ data: Data, from start: Int) -> [UInt16] {
    var kinds: [UInt16] = []
    var at = start
    while at + 8 <= data.count {
        let len = UInt32(data[at]) | UInt32(data[at + 1]) << 8
            | UInt32(data[at + 2]) << 16 | UInt32(data[at + 3]) << 24
        kinds.append(UInt16(data[at + 4]) | UInt16(data[at + 5]) << 8)
        at += Int(len)
    }
    return kinds
}

func menuAppendParent(_ data: Data, from start: Int) -> UInt64? {
    var at = start
    while at + 8 <= data.count {
        let len = UInt32(data[at]) | UInt32(data[at + 1]) << 8
            | UInt32(data[at + 2]) << 16 | UInt32(data[at + 3]) << 24
        let kind = UInt16(data[at + 4]) | UInt16(data[at + 5]) << 8
        if kind == UInt16(KAYA_TX_MENU_ITEM_APPEND) {
            var parent: UInt64 = 0
            for i in 0..<8 { parent |= UInt64(data[at + 8 + i]) << (8 * UInt64(i)) }
            return parent
        }
        at += Int(len)
    }
    return nil
}

var fileItem: KayaMenuItem!
app.build { tx in
    let start = tx.tx.bytes.count
    let save = tx.item("Save", shortcut: "PRIMARY+S")
    fileItem = tx.menu("File", items: [save])
    let sort = tx.radioGroup(
        "Sort", options: [tx.option("Name"), tx.option("Date")], value: 1)
    tx.window(menus: [fileItem, sort])
    let noun = tx.label("noun")
    tx.contextMenu(noun, items: [tx.item("Rename")])
    let kinds = recordKinds(tx.tx.bytes, from: start)
    // Save, File, Name, Date, Sort, Rename.
    precondition(
        kinds.filter { $0 == UInt16(KAYA_TX_MENU_ITEM_CREATE) }.count == 6,
        "menu constructors queued the wrong create count")
    precondition(
        kinds.filter { $0 == UInt16(KAYA_TX_MENUBAR_APPEND) }.count == 2,
        "bar anchors queued the wrong menubar-append count")
    precondition(
        kinds.filter { $0 == UInt16(KAYA_TX_MENU_ITEM_APPEND) }.count == 3,
        "children queued the wrong item-append count")
    precondition(
        kinds.filter { $0 == UInt16(KAYA_TX_CONTEXT_ATTACH) }.count == 1,
        "context anchor queued the wrong attach count")
    precondition(
        String(decoding: tx.tx.bytes[start...], as: UTF8.self).contains("primary+s"),
        "shortcut did not reach the records canonicalized")
}

// Append-at-any-time: the retained handle reopens in a later
// transaction — one create plus one append under the RETAINED parent,
// and never a new bar anchor.
app.build { tx in
    let start = tx.tx.bytes.count
    tx.menu(fileItem, items: [tx.item("Publish")])
    let kinds = recordKinds(tx.tx.bytes, from: start)
    precondition(
        kinds.filter { $0 == UInt16(KAYA_TX_MENU_ITEM_CREATE) }.count == 1,
        "reopen queued the wrong create count")
    precondition(
        menuAppendParent(tx.tx.bytes, from: start) == fileItem.id,
        "reopen did not seat under the retained parent")
    precondition(
        !kinds.contains(UInt16(KAYA_TX_MENUBAR_APPEND)),
        "reopen re-anchored the bar")
}

// An aborted append drops its menu records with everything else
// (records die with the tx; nothing ships) and the app continues.
propagated = false
do {
    try app.build { tx in
        tx.menu(fileItem, items: [tx.item("Doomed")])
        throw CheckError()
    }
} catch {
    propagated = error is CheckError
}
precondition(propagated, "menu abort: build must propagate")
app.build { tx in
    tx.menu(fileItem, items: [tx.item("Recovered")])
}

// The trap side, via re-exec (see the KAYA_GUARD_TRAP branch at the
// top): a mirror read inside a For or When body being declared must
// kill the process — and so must an alias shortcut hitting the
// binding's one parser (its rejection is a preconditionFailure).
for mode in ["for", "when", "shortcut"] {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    var env = ProcessInfo.processInfo.environment
    env["KAYA_GUARD_TRAP"] = mode
    child.environment = env
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    do {
        try child.run()
    } catch {
        preconditionFailure("could not re-exec for the \(mode) trap: \(error)")
    }
    child.waitUntilExit()
    let died = child.terminationReason == .uncaughtSignal || child.terminationStatus != 0
    precondition(died, "mirror read inside a \(mode) body did not trap")
}

print("swift abort check: OK")
