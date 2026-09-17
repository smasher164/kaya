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
        case "span":
            // A span the CORE sent with its ends out of order is refused
            // NAMING THE RECORD (the idiom review's S3) rather than
            // trapping inside Range's own init with no kaya sentence.
            _ = kayaDecodedSpan("text_edited", 5, 3)
        case "choice":
            // A closed vocabulary refuses a wire number this build does
            // not know, naming it (X1).
            _ = KayaAlertChoice.fromWire(7)
        case "outcome":
            _ = KayaNotificationOutcome.fromWire(9)
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

// A STAMPED COPY'S DOCUMENT IS A ROW FIELD (docs/rich-text-plan.md §19),
// and NO SCENE CAN SEE EITHER HALF: a copy renders the same picture
// whatever bytes the field holds, and the fold is the app's own mirror of
// an act the core already applied. So the BYTES are pinned against the
// wire's rules read off crates/kaya/src/wire.rs (write_values is
// {u32 count, u32 0}; write_value is {u32 tag, u32 len, payload}
// zero-padded to 8; VALUE_I64 is 2, VALUE_STR is 4) rather than against
// this binding's own encoder, and the fold is required to answer what the
// LIVE fold answers. THE CONFORMANCE IS HAND-WRITTEN here, in the shape
// kaya-swift-gen emits: this fixture compiles the bindings alone.
struct RowNote: KayaRecord {
    var title: String
    var body: KayaDocument

    static let prototype = RowNote(title: "", body: KayaDocument())

    init(title: String, body: KayaDocument) {
        self.title = title
        self.body = body
    }

    init(values: [KayaValue]) {
        guard case .str(let title) = values[0], case .bytes(let body) = values[1] else {
            preconditionFailure("kaya: RowNote fields out of order")
        }
        self.init(title: title, body: kayaDocumentOfBlob(Data(body)))
    }

    static func kayaDocument(_ record: RowNote, _ index: UInt32) -> KayaDocument? {
        index == 1 ? record.body : nil
    }

    static func kayaWithDocument(
        _ record: RowNote, _ index: UInt32, _ document: KayaDocument
    ) -> RowNote {
        var next = record
        if index == 1 { next.body = document }
        return next
    }
}

func spellRuns(_ runs: [KayaRun]) -> String {
    runs.map { "\($0.range.lowerBound):\($0.range.upperBound) \($0.name)=\($0.value)" }
        .joined(separator: "|")
}

let documentBlobHex =
    "09000000000000000400000003000000"
    + "48C3A900000000000200000008000000"
    + "00000000000000000200000008000000"
    + "02000000000000000400000004000000"
    + "626F6C64000000000400000004000000"
    + "74727565000000000200000008000000"
    + "02000000000000000200000008000000"
    + "03000000000000000400000004000000"
    + "6C696E6B000000000400000001000000"
    + "7500000000000000"

let rowDoc = KayaDocument("H\u{e9}")
    .mark(0..<2, "bold", "true")
    .mark(2..<3, "link", "u")
let rowBlob = kayaDocumentBlob(rowDoc).map { String(format: "%02X", $0) }.joined()
precondition(
    rowBlob == documentBlobHex,
    "a Document field's blob is\n  \(rowBlob)\nand the wire's rules say\n  "
        + documentBlobHex)

// ONE EDIT, through the ONE fold: the live mirror's answer is the row
// field's answer.
let rowMarks = [KayaRun(range: 0..<1, name: "code", value: "true")]
var rowLive = rowDoc
kayaFoldEdit(&rowLive, 3, 3, "!", rowMarks)

var rowNotes: KayaRecordCollection<RowNote>! = nil
var rowBody: KayaNodeHandle! = nil
app.build { tx in
    rowNotes = tx.collection(of: RowNote.self)
    _ = tx.forEach(rowNotes.collection) { t in
        rowBody = t.textarea(document: KayaField<KayaDocument>(index: 1))
    }
    rowNotes.insert(tx, .str("a"), RowNote(title: "a", body: rowDoc))
}
app.foldRowDocument(rowBody.id, [.str("a")]) { doc in
    kayaFoldEdit(&doc, 3, 3, "!", rowMarks)
}
app.build { tx in
    let items = rowNotes.items(tx)
    precondition(items.count == 1, "the row-document probe lost its row")
    let folded = items[0].value.body
    precondition(
        folded.text == rowLive.text,
        "the row field folded to \"\(folded.text)\", the live mirror to \"\(rowLive.text)\"")
    precondition(
        spellRuns(folded.runs) == spellRuns(rowLive.runs),
        "the row field's runs are \(spellRuns(folded.runs)), the live mirror's "
            + spellRuns(rowLive.runs))
    precondition(
        items[0].value.title == "a", "the fold rewrote a field the act never named")
}
// A ROW THAT IS GONE HAS NO FIELD TO FOLD INTO, and that is not a fault.
app.foldRowDocument(rowBody.id, [.str("gone")]) { doc in
    kayaFoldEdit(&doc, 0, 0, "x", [])
}
app.build { tx in
    precondition(
        rowNotes.items(tx).count == 1, "folding into a row that is gone invented one")
}

// AN UNDO RESTORES THE FIELD FROM ITS BYTES, never from the handle that
// carried them (docs/deferred.md, the restored-row blob entry): the core
// registers the bytes in the occurrence table, kayaParseUndo redeems them,
// and the generated init(values:) reads a Document out of them.
let restoredNote = RowNote(values: [
    .str("a"), .bytes([UInt8](kayaDocumentBlob(rowDoc))),
])
precondition(
    restoredNote.body.text == rowDoc.text
        && spellRuns(restoredNote.body.runs) == spellRuns(rowDoc.runs),
    "a restored row's Document field read \"\(restoredNote.body.text)\" / "
        + spellRuns(restoredNote.body.runs) + ", the bytes say \"\(rowDoc.text)\" / "
        + spellRuns(rowDoc.runs))

// The trap side, via re-exec (see the KAYA_GUARD_TRAP branch at the
// top): a mirror read inside a For or When body being declared must
// kill the process, an alias shortcut hitting the binding's one parser
// must too (its rejection is a preconditionFailure), and so must
// a reversed span the core sent and a wire number outside a closed
// vocabulary must too.
// EACH TRAP IS READ BY ITS SENTENCE, not merely by the death: the
// reversed span would kill the process either way — Range's own init has
// a precondition — and the whole point of the guard is that the reader is
// told which RECORD carried it, in kaya's words (invariant 3's
// diagnostics half).
for (mode, sentence) in [
    ("for", "model read inside a template body"),
    ("when", "model read inside a template body"),
    ("shortcut", "shortcut"),
    ("span", "a text_edited carries 5..3, a reversed span"),
    ("choice", "an alert result carries choice 7"),
    ("outcome", "a notification result carries outcome 9"),
] {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    var env = ProcessInfo.processInfo.environment
    env["KAYA_GUARD_TRAP"] = mode
    child.environment = env
    child.standardOutput = FileHandle.nullDevice
    let pipe = Pipe()
    child.standardError = pipe
    do {
        try child.run()
    } catch {
        preconditionFailure("could not re-exec for the \(mode) trap: \(error)")
    }
    let said = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    child.waitUntilExit()
    let died = child.terminationReason == .uncaughtSignal || child.terminationStatus != 0
    precondition(died, "guard trap \(mode) did not fire")
    precondition(
        said.contains(sentence),
        "guard trap \(mode) fired on someone else's sentence, not \"\(sentence)\": \(said)")
}

// THE CORRECTION SLICE (the idiom review, 2026-09-17), the halves that
// answer rather than trap.
//
// S1: a civil date is a TYPE, not a DateComponents alias — every
// component non-optional, so a time cannot stand where a date is wanted,
// and the display spelling is the type's own.
precondition(
    "\(KayaDate(year: 2026, month: 9, day: 4))" == "2026-09-04",
    "a KayaDate does not spell itself: \(KayaDate(year: 2026, month: 9, day: 4))")
precondition(
    "\(KayaTime(hour: 14, minute: 30))" == "14:30",
    "a KayaTime does not spell itself: \(KayaTime(hour: 14, minute: 30))")

// S2: the Range carries the arithmetic the splices need, so a partial
// edit is a call rather than a full reconstruction.
precondition((2..<5).shifted(by: 3) == 5..<8, "Range.shifted moved the wrong bounds")
precondition((2..<5).raised(to: 4) == 2..<4, "Range.raised moved the wrong bound")
precondition((2..<5).lowered(to: 3) == 3..<5, "Range.lowered moved the wrong bound")

// X2: a flag attribute is a BOOL on both sides, the wire's own string
// only at the boundary.
let marked = KayaDocument("abcd").mark(0..<2, "italic", true).link(2..<4, "https://kaya.dev")
precondition(
    marked.runs[0].isFlag && marked.runs[0].value == "true",
    "a bool mark did not reach the wire as its flag string")
precondition(!marked.runs[1].isFlag, "a valued attribute read back as a flag")
precondition(
    KayaEdit.insert(at: 3, "x").mark(0..<1, "code", true).runs[0].isFlag,
    "an edit's bool mark did not read back as a flag")

// C3: a picked file with no re-openable name answers nil, not an empty
// one — the absence the type now checks.
precondition(
    KayaPickedFile(handle: 1, name: "n", localPath: "").localPath == nil,
    "an absent local path is not nil")
precondition(
    KayaPickedFile(handle: 1, name: "n", localPath: "/tmp/n").localPath == "/tmp/n",
    "a present local path did not survive")

// S4: `Int` is the type of an integer literal, so the most obvious prefs
// call must compile — this line IS the check.
precondition(KayaApp.prefs().get("kaya-correction-absent", default: 7) == 7,
    "prefs.get with an Int default did not answer the default")

print("swift abort check: OK")
