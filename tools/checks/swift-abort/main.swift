// The uniform-abort guard: a handler abort rolls the model mirror
// back, ships nothing, and the app continues — the same observable
// semantics as every other binding (the negative test each language
// carries). Runs headless: the library links and records submit, but
// the core loop is never entered — the Python checks' arrangement.
// Compiled as one module with bindings/swift/*.swift, so the internal
// mirrors (signalMirrors, signalDeps) are in reach; the dispatch
// wrapper is private, so the boundary test covers the rollback and
// the dispatch wrapper stays compile-visible only.
//
// Build and run (from the repo root, inside `nix develop`):
//   swiftc -o /tmp/swift-abort-check bindings/swift/*.swift \
//     tools/checks/swift-abort/main.swift \
//     -import-objc-header crates/kaya/include/kaya.h \
//     -I crates/kaya/include -L target/debug -lkaya \
//     -Xlinker -rpath -Xlinker "$PWD/target/debug"
//   /tmp/swift-abort-check

import Foundation

// The record-time mirror-read guard, trap side: the guard is a
// preconditionFailure — uncatchable in Swift — so each trapping arm
// runs in a re-exec of this binary (KAYA_GUARD_TRAP=for|when) that
// must die before reaching its exit(0). The parent asserts on the
// child's death below; exit 0 here means the guard did NOT fire.
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

// The trap side, via re-exec (see the KAYA_GUARD_TRAP branch at the
// top): a mirror read inside a For or When body being declared must
// kill the process.
for mode in ["for", "when"] {
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
