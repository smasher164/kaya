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

print("swift abort check: OK")
