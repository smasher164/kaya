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

/// Register bulk payload bytes (an encoded image) with the core: one
/// copy into core-owned memory, returning the u64 handle the next
/// submit from this guest consumes, referenced or not. The caller's
/// bytes are free to drop the moment this returns.
func kayaRegisterBlob(_ data: Data) -> UInt64 {
    data.withUnsafeBytes { raw in
        kaya_blob_register(raw.bindMemory(to: UInt8.self).baseAddress, UInt(raw.count))
    }
}

/// A live widget: exactly one thing on screen.
/// A container's cross-axis child placement (the align spec enum;
/// wire values pinned by the generated constants). Baseline is
/// rows-only — the scene rejects it on columns at the root.
enum KayaAlign: Int64 {
    case start = 0
    case center = 1
    case end = 2
    case stretch = 3
    case baseline = 4
}

/// SEMANTIC EMPHASIS (docs/styling-plan.md D4): what a widget MEANS,
/// never how it looks — a closed vocabulary, so there is no raw value to
/// reach for. Destructive and prominent are BUTTON emphasis, heading is
/// LABEL hierarchy, and the root refuses the other combinations at
/// declare time, in one sentence naming both the role and the kind.
enum KayaRole: Int64 {
    /// An action whose press destroys something: the platform's own
    /// destructive affordance (red title on Apple, the error-role
    /// container on Material, `.destructive-action` on GTK).
    case destructive = 1
    /// THE primary action — one per dialog's worth of emphasis: the
    /// default-button treatment on every platform.
    case prominent = 2
    /// A text hierarchy heading — the platform's heading text style AND
    /// the accessibility heading trait assistive users skim by.
    case heading = 3
}

/// WHICH PLATFORM A PER-PLATFORM BRAND VALUE IS FOR (the `platform` spec
/// enum; docs/styling-plan.md Slice 2b): one entry per backend roster
/// row, closed.
///
/// AN APP NAMES THESE, IT NEVER ASKS WHICH ONE IT IS. There is no
/// `KayaPlatform.current` and there will not be: a binding cannot answer
/// that question, and it does not have to — every row travels to every
/// backend on the wire, and each backend picks its own. Swift is where
/// the temptation is sharpest, because ONE guest source compiles for
/// macOS and for iOS: `#if os(macOS)` in a guest would ship different
/// code per platform, which is the thing kaya exists to not do. Name the
/// rows instead and let both lowerings read the same transaction.
///
/// THE RAW VALUES ARE WIRE VALUES (`PLATFORM_MAC` … `PLATFORM_ANDROID`
/// in crates/kaya/include/kaya.h) and are append-only.
enum KayaPlatform: Int64 {
    case mac = 1
    case ios = 2
    case linux = 3
    case windows = 4
    case android = 5
}

/// THE SEMANTIC ICON VOCABULARY (the `symbol` spec enum;
/// docs/styling-plan.md D6, DESIGN.md "Icons want names, not bytes").
///
/// An app names a CONCEPT and each backend draws its own platform's
/// glyph for it: `copy` is `doc.on.doc` on Apple, `content_copy` on
/// Material, `edit-copy-symbolic` on Adwaita, and no single asset is
/// right on all three — SF Symbols are license-locked to Apple
/// platforms, so a shared one is not even legal. The platform sets also
/// metric-match the text beside them (weight, baseline) while a blob
/// cannot. The `icon:` blob slot stays for genuinely app-specific art.
///
/// Closed, and small on purpose — the `KayaRole` trick one tier over.
/// Apple keeps its own semantic set to fifteen entries. Growing it is a
/// spec change with its gates, never a per-app escape hatch.
///
/// THE RAW VALUES ARE WIRE VALUES AND ARE APPEND-ONLY. A new concept
/// takes 21; renumbering silently redraws every shipped app's menus.
enum KayaSymbol: Int64 {
    case add = 1
    case remove = 2
    /// Destroying something, the wastebasket idiom — distinct from
    /// `remove`, which takes an item out of a list.
    case delete = 3
    case edit = 4
    /// Confirmation, the checkmark idiom.
    case done = 5
    /// Dismissal, the ✕ idiom — not `delete`.
    case close = 6
    case search = 7
    case settings = 8
    case refresh = 9
    case info = 10
    case warning = 11
    /// The direction-relative pair: every platform mirrors these under
    /// a right-to-left layout, so they mean BACKWARD and FORWARD in
    /// reading order, never "left" and "right".
    case back = 12
    case forward = 13
    /// The overflow affordance (the ellipsis idiom).
    case more = 14
    case copy = 15
    case paste = 16
    /// Favourite.
    case star = 17
    case lock = 18
    /// A person or account.
    case person = 19
    case home = 20
}

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

/// A live menu item: its OWN id space (the c_menu_item counter)
/// behind its own type, so cross-use with widget or node handles is a
/// compile error. One command identity: exactly one parent or anchor,
/// forever (append-only; nothing is removed in v1). The id alone is
/// the durable name — reopen a retained item with tx.menu(item, ...).
struct KayaMenuItem {
    let id: UInt64
}

/// A context catalog built UNANCHORED (tx.contextCatalog) for a
/// template node: menu items are live and shared across stamped
/// copies, so the catalog is built in the live zone and
/// KayaTpl.contextMenu attaches it inside the template, where each
/// activation carries the copy's key path. An item takes exactly one
/// anchor — a second attach traps.
final class KayaContextCatalog {
    let roots: [KayaMenuItem]
    var attached = false

    init(_ roots: [KayaMenuItem]) {
        self.roots = roots
    }
}

/// One of the TWO addressable sources a menu text property binds to —
/// constant text or a Str signal (menu items are not collection
/// elements, so there is no element arm). Conformance is the sealed
/// union: only String and KayaSignal conform, so a Bool label is a
/// compile error — one parameter name per property, compile-checked.
protocol KayaMenuText {}

extension String: KayaMenuText {}

extension KayaSignal: KayaMenuText {}

/// The Bool twin, for enabled/checked.
protocol KayaMenuBool {}

extension Bool: KayaMenuBool {}

extension KayaSignal: KayaMenuBool {}

/// The index twin, for a radio group's value (a 0-based option index
/// under the Choice contract).
protocol KayaMenuIndex {}

extension Int: KayaMenuIndex {}

extension Double: KayaMenuIndex {}

extension KayaSignal: KayaMenuIndex {}

/// One file the picker answered with: a handle to redeem, a display
/// name, and `localPath` — a RE-OPENABLE NAME, empty unless re-opening
/// it actually works, which measurement puts at the three desktops and
/// neither phone (DESIGN.md, File dialogs).
/// One representation, arriving — the sum a copy is the record of.
/// Swift has a real sum, so this is an enum with associated values and
/// a `switch` is the elimination.
///
/// YOU OFFER MANY AND YOU RECEIVE ONE, and the two shapes say so: a
/// record here would invite a guest to check five fields where four
/// are structurally always empty.
enum KayaRepresentation {
    case text(String)
    case html(String)
    /// Encoded image bytes. WHAT COMES BACK MAY BE A RE-ENCODE — the
    /// hosts convert freely between image types — so compare what the
    /// image IS, never the bytes it arrived in.
    case image([UInt8])
    /// Files, plural INSIDE one representation — the same nesting
    /// text/uri-list and CF_HDROP already have. A pasted file is the
    /// picker's own capability arriving through a second door, so it
    /// opens with the call that already exists.
    case files([KayaPickedFile])
    /// An app-defined format, round-tripped verbatim.
    case custom(id: String, bytes: [UInt8])
}

/// Turn the decoder's kind-and-parts into the sum, or nil.
///
/// EMPTY IS THE UNIVERSAL NO: nil covers a denied prompt on iOS, an
/// unfocused reader on Android or Wayland, an empty clipboard, and
/// content in no representation this read accepted. The guest is not
/// told which, because the platforms deliberately do not say.
func kayaRepresentation(_ clip: KayaClipValues?) -> KayaRepresentation? {
    guard let clip else { return nil }
    func str(_ i: Int) -> String {
        guard i < clip.parts.count, case .str(let s) = clip.parts[i] else { return "" }
        return s
    }
    func bytes(_ i: Int) -> [UInt8] {
        guard i < clip.parts.count, case .bytes(let b) = clip.parts[i] else { return [] }
        return b
    }
    switch clip.kind {
    case UInt32(CLIP_TEXT): return .text(str(0))
    case UInt32(CLIP_HTML): return .html(str(0))
    case UInt32(CLIP_IMAGE): return .image(bytes(0))
    case UInt32(CLIP_CUSTOM): return .custom(id: str(0), bytes: bytes(1))
    case UInt32(CLIP_FILES):
        // The picker's own three-per-file grouping, so a guest that
        // decodes a dialog result decodes this with the same loop.
        var out: [KayaPickedFile] = []
        var i = 0
        while i + 2 < clip.parts.count {
            guard case .i64(let handle) = clip.parts[i] else { break }
            out.append(KayaPickedFile(
                handle: UInt64(handle), name: str(i + 1), localPath: str(i + 2)))
            i += 3
        }
        return .files(out)
    default: return nil
    }
}

/// What an undo (or a redo) PUT BACK — the core-authoritative statement
/// of the restored state, never a replay of ops (docs/undo-plan.md D5).
///
/// APPLYING AN INVERSE EMITS NOTHING ELSE: it is programmatic by
/// construction, so the echo doctrine covers it — no text_changed for
/// the text this restored, no value_changed for the signals. That is
/// why the payload is fat. This binding folds the two runs it MIRRORS
/// (signals, collection entries and orders) before the handler runs, so
/// a read-back inside the handler answers about the restored state; the
/// runs it does not mirror pass through for the app to fold.
///
/// Every group says what a thing now IS, so applying this twice is the
/// same as applying it once.
struct KayaUndoDelta {
    /// Signal id -> its restored value.
    let signals: [(signal: UInt64, value: KayaValue)]
    /// One restored field's text, per field the step disturbed. A coarse
    /// episode restore is a programmatic write, so NOTHING ELSE would
    /// ever tell an app that folds text_changed into its own model
    /// (which is every app — the field is uncontrolled).
    let texts: [KayaUndoText]
    /// Collection entries, present or gone.
    let entries: [KayaUndoEntry]
    /// Instance orders, for the instances whose order the step changed
    /// — position is the one thing per-entry statements cannot carry.
    let orders: [KayaUndoOrder]
}

/// One text field's restored text, and the identity that says WHICH
/// field.
///
/// THE SAME TWO NAMES A CHANGE OCCURRENCE ALREADY ARRIVES UNDER, which
/// is the whole reason this run became an arity-first group like its
/// entries and orders siblings: an empty `path` means `id` is a live
/// widget's id, and a non-empty `path` means `id` is a TEMPLATE NODE and
/// the path is the stamped copy's key path, outermost first — the pair
/// `onChange(_ n: KayaNodeHandle, …)` hands a row's edit under. A fixed
/// (widget id, text) pair had nowhere to put the path, so a row's typing
/// could not be named to the app at all.
struct KayaUndoText {
    let id: UInt64
    /// The instance path: one key per enclosing For, EMPTY for a live
    /// widget.
    let path: [KayaValue]
    let text: String
}

/// One collection entry's restored state.
struct KayaUndoEntry {
    let collection: UInt64
    /// The instance path: one key per enclosing For, empty at top level.
    let path: [KayaValue]
    let key: KayaValue
    /// The variant and the record's wire fields, or nil when the
    /// restored state does not have this entry at all.
    let state: (variant: UInt32, fields: [KayaValue])?
}

/// One collection instance's restored key order.
struct KayaUndoOrder {
    let collection: UInt64
    let path: [KayaValue]
    let keys: [KayaValue]
}

/// Decode an undone/redone record body (kind 17/18, one layout for
/// both — one encoder writes them, so one reader reads them).
///
/// HAND-WRITTEN AND NOT GENERATED, deliberately: the generated
/// kayaParseOccurrence reads the widget/keys/payload shape every other
/// record has, and this record's head is four counts followed by one
/// flat Values block read as four RUNS. The dispatch loop branches on
/// the kind BEFORE that parser sees the bytes.
func kayaParseUndo(_ rec: [UInt8]) -> (window: UInt64, label: String, delta: KayaUndoDelta)? {
    rec.withUnsafeBytes { raw -> (UInt64, String, KayaUndoDelta)? in
        guard raw.count >= 32 else { return nil }
        var at = 8
        func u32() -> Int {
            let v = raw.loadUnaligned(fromByteOffset: at, as: UInt32.self)
            at += 4
            return Int(v)
        }
        let window = raw.loadUnaligned(fromByteOffset: at, as: UInt64.self)
        at += 8
        let nSignals = u32(), nTexts = u32(), nEntries = u32(), nOrders = u32()
        // Values self-pad to 8 and concatenate, so one reader walks the
        // label and the flat tail alike.
        func value() -> KayaValue? {
            guard at + 8 <= raw.count else { return nil }
            let vtype = raw.loadUnaligned(fromByteOffset: at, as: UInt32.self)
            let vlen = Int(raw.loadUnaligned(fromByteOffset: at + 4, as: UInt32.self))
            guard at + 8 + vlen <= raw.count else { return nil }
            var out: KayaValue
            switch vtype {
            case UInt32(KAYA_VALUE_BOOL):
                out = .bool(raw[at + 8] != 0)
            case UInt32(KAYA_VALUE_I64):
                out = .i64(Int64(bitPattern:
                    raw.loadUnaligned(fromByteOffset: at + 8, as: UInt64.self)))
            case UInt32(KAYA_VALUE_F64):
                out = .f64(Double(bitPattern:
                    raw.loadUnaligned(fromByteOffset: at + 8, as: UInt64.self)))
            case UInt32(KAYA_VALUE_BLOB):
                out = .blob(raw.loadUnaligned(fromByteOffset: at + 8, as: UInt64.self))
            default:
                out = .str(String(decoding: raw[(at + 8)..<(at + 8 + vlen)], as: UTF8.self))
            }
            at += 8 + ((vlen + 7) & ~7)
            return out
        }
        guard case .str(let label)? = value() else { return nil }
        // The flat tail's own count, then its reserved word.
        guard at + 8 <= raw.count else { return nil }
        let flatCount = u32()
        at += 4
        var flat: [KayaValue] = []
        for _ in 0..<flatCount {
            guard let v = value() else { return nil }
            flat.append(v)
        }
        var i = 0
        func take(_ n: Int) -> [KayaValue]? {
            guard i + n <= flat.count else { return nil }
            defer { i += n }
            return Array(flat[i..<(i + n)])
        }
        func int(_ v: KayaValue) -> Int? {
            guard case .i64(let n) = v else { return nil }
            return Int(n)
        }
        var signals: [(signal: UInt64, value: KayaValue)] = []
        for _ in 0..<nSignals {
            guard let pair = take(2), let id = int(pair[0]) else { return nil }
            signals.append((signal: UInt64(id), value: pair[1]))
        }
        // ARITY FIRST, so a reader needs no schema: size counts itself.
        // THREE RUNS SHARE THAT SHAPE, and this one joined the other two
        // when a row's field needed a path — the group is
        // `size, id, path_len, path values…, text`, pinned value by
        // value in crates/kaya/src/wire.rs `undo_bodies_round_trip`.
        // A reader that kept the old fixed pair takes the SIZE for the
        // id and the id for the text, which is why the pin table is
        // where this is agreed rather than in a round trip.
        var texts: [KayaUndoText] = []
        for _ in 0..<nTexts {
            guard let head = take(1), let size = int(head[0]), size >= 4,
                let rest = take(size - 1),
                let id = int(rest[0]), let pathLen = int(rest[1]),
                pathLen >= 0, pathLen + 2 < rest.count,
                case .str(let text) = rest[2 + pathLen]
            else { return nil }
            texts.append(
                KayaUndoText(
                    id: UInt64(id), path: Array(rest[2..<(2 + pathLen)]), text: text))
        }
        var entries: [KayaUndoEntry] = []
        for _ in 0..<nEntries {
            guard let head = take(1), let size = int(head[0]), size >= 6,
                let rest = take(size - 1),
                let collection = int(rest[0]), let present = int(rest[1]),
                let variant = int(rest[2]), let pathLen = int(rest[3]),
                pathLen + 4 < rest.count
            else { return nil }
            let path = Array(rest[4..<(4 + pathLen)])
            let key = rest[4 + pathLen]
            let fields = Array(rest[(5 + pathLen)...])
            entries.append(KayaUndoEntry(
                collection: UInt64(collection), path: path, key: key,
                state: present != 0 ? (variant: UInt32(variant), fields: fields) : nil))
        }
        var orders: [KayaUndoOrder] = []
        for _ in 0..<nOrders {
            guard let head = take(1), let size = int(head[0]), size >= 3,
                let rest = take(size - 1),
                let collection = int(rest[0]), let pathLen = int(rest[1]),
                pathLen + 2 <= rest.count
            else { return nil }
            orders.append(KayaUndoOrder(
                collection: UInt64(collection),
                path: Array(rest[2..<(2 + pathLen)]),
                keys: Array(rest[(2 + pathLen)...])))
        }
        return (
            window, label,
            KayaUndoDelta(signals: signals, texts: texts, entries: entries, orders: orders)
        )
    }
}

/// Join an accept list: the closed kinds by name plus any custom ids,
/// space separated.
///
/// A LIST AND NOT A MASK, because half the set is open-ended. A custom
/// format that could be written and never accepted would be an escape
/// hatch that only opens outward, and round-tripping an app's own data
/// is the whole reason to have one. Ids reach every platform's registry
/// verbatim, so they carry no spaces — which is what makes the join
/// unambiguous, and what this refuses to let you break.
func kayaAcceptList(_ kinds: [String]) -> String {
    for kind in kinds where kind.isEmpty || kind.contains(" ") {
        fatalError("""
            kaya: "\(kind)" is not an accept-list entry — the closed kinds \
            are "text", "html", "image" and "files", and a custom format id \
            reaches the platform's own registry verbatim, so it carries no spaces
            """)
    }
    return kinds.joined(separator: " ")
}

/// Flatten a dialog's ADVISORY filters into the wire's alternating
/// label/extensions run — a label, then its space-separated extensions,
/// per pair.
///
/// ONE ENCODER FOR BOTH DIALOGS, deliberately. The picker and the save
/// request carry the identical filter block, and the core validates it
/// through one shared helper for the same reason: two copies of an
/// alternating layout are two chances for one of them to write the pairs
/// in the other order, which no type here would catch.
func kayaFilterValues(_ filters: [(String, String)]) -> [KayaValue] {
    var values: [KayaValue] = []
    for (label, extensions) in filters {
        values.append(.str(label))
        values.append(.str(extensions))
    }
    return values
}

/// The UTF-8 BYTE OFFSET of a position in `text` — kaya's unit for
/// every text range, and the one number Swift's `String.Index` will not
/// hand you.
///
/// WHY THIS EXISTS RATHER THAN A LINE IN EACH APP. Swift is the only
/// guest language whose string is indexed by neither bytes nor an
/// integer, and its two reachable substitutes are both wrong and both
/// silent. Measured on a string whose first line is `日本語`:
///
///     text.utf8.distance(from: text.startIndex, to: i)  // 57  <- kaya's
///     text.distance(from: text.startIndex, to: i)       // 51  (Characters)
///     i.utf16Offset(in: text)                           // 51  (UTF-16)
///
/// The last two are what an author reaches for; each would decorate six
/// characters early on this milestone's own document, with nothing to
/// blame. `String.Index(utf16Offset:in:)` is worse still — it ROUNDS a
/// split offset and then reports the offset it was given
/// (scratchpad/ranges-units.md §5).
///
/// The result is a code-point boundary by construction: a `String.Index`
/// is one, so the core's boundary clause cannot fire on anything this
/// produced.
func kayaByteOffset(_ i: String.Index, in text: String) -> Int {
    text.utf8.distance(from: text.startIndex, to: i)
}

/// A Swift string range as kaya's pair of UTF-8 byte offsets — the
/// conversion `highlightRanges`, `selectRange` and `revealRange` apply
/// to the ranges Swift's own search returns.
func kayaByteRange(_ r: Range<String.Index>, in text: String) -> Range<Int> {
    kayaByteOffset(r.lowerBound, in: text)..<kayaByteOffset(r.upperBound, in: text)
}

/// The copy chain: a clip record under construction. Each method fills
/// one representation, and send() puts it on the clipboard.
///
/// A RECORD AND NOT A LIST is the whole shape — at most one per kind is
/// structural, since a second text() replaces the field rather than
/// needing a duplicate check the root has to run.
struct KayaCopyRef {
    let tx: KayaAppTx
    private var text: String?
    private var html: String?
    private var image: [UInt8]?
    private var files: [UInt64] = []
    private var custom: [(String, [UInt8])] = []

    init(tx: KayaAppTx) { self.tx = tx }

    func text(_ text: String) -> KayaCopyRef {
        var next = self
        next.text = text
        return next
    }

    func html(_ html: String) -> KayaCopyRef {
        var next = self
        next.html = html
        return next
    }

    /// Encoded image bytes — the same currency the image property takes.
    func image(_ bytes: [UInt8]) -> KayaCopyRef {
        var next = self
        next.image = bytes
        return next
    }

    /// Offer a picked file, the picker's own capability put straight on
    /// the clipboard. The bytes never move through kaya.
    func file(_ f: KayaPickedFile) -> KayaCopyRef {
        var next = self
        next.files.append(f.handle)
        return next
    }

    /// An app-defined format, round-tripped verbatim. The id reaches
    /// every platform's own registry unchanged — a UTI on Apple,
    /// RegisterClipboardFormat on Windows, a target atom on X11 and
    /// Wayland, a MIME type on Android — so it carries no spaces, and
    /// kaya does nothing clever with the bytes.
    func custom(_ id: String, _ bytes: [UInt8]) -> KayaCopyRef {
        _ = kayaAcceptList([id])
        var next = self
        next.custom.append((id, bytes))
        return next
    }

    /// Put the clip on the system clipboard. The wire order is kaya's,
    /// not this chain's — descending richness, which is preference
    /// order on every host that has one.
    func send() {
        var present: UInt32 = 0
        var values: [KayaValue] = []
        for (id, bytes) in custom {
            values.append(.str(id))
            values.append(.blob(kayaRegisterBlob(Data(bytes))))
        }
        for handle in files {
            values.append(.i64(Int64(bitPattern: handle)))
        }
        if let image {
            present |= UInt32(CLIP_IMAGE)
            values.append(.blob(kayaRegisterBlob(Data(image))))
        }
        if let html {
            present |= UInt32(CLIP_HTML)
            values.append(.str(html))
        }
        if let text {
            present |= UInt32(CLIP_TEXT)
            values.append(.str(text))
        }
        tx.tx.copy(present, UInt32(files.count), UInt32(custom.count), values)
    }
}

/// The read chain: which representations this read can use, and the
/// request id its one answer arrives under.
struct KayaClipReadRef {
    let tx: KayaAppTx
    let id: UInt64
    private var accepting: [String] = []
    private var onResult: ((KayaAppTx, KayaRepresentation?) throws -> Void)?

    init(tx: KayaAppTx, id: UInt64) {
        self.tx = tx
        self.id = id
    }

    func text() -> KayaClipReadRef { accept("text") }
    func html() -> KayaClipReadRef { accept("html") }
    func image() -> KayaClipReadRef { accept("image") }
    func files() -> KayaClipReadRef { accept("files") }

    /// Accept an app-defined format by id. Custom formats are tried
    /// FIRST, in the order named: an app's own format round-trips its
    /// data losslessly, which is the only reason to have one.
    func custom(_ id: String) -> KayaClipReadRef { accept(id) }

    private func accept(_ kind: String) -> KayaClipReadRef {
        var next = self
        next.accepting.append(kind)
        return next
    }

    /// Bind the one-shot handler to THIS request. The answer is nil
    /// when the clipboard had nothing this read accepted — and nil
    /// equally when the read was denied or the app was unfocused,
    /// because no platform says which.
    func onResult(
        _ handler: @escaping (KayaAppTx, KayaRepresentation?) throws -> Void
    ) -> KayaClipReadRef {
        var next = self
        next.onResult = handler
        return next
    }

    /// Send the request, returning its id.
    @discardableResult
    func send() -> UInt64 {
        if let onResult { tx.app.onClipboard(id, onResult) }
        tx.tx.readClipboard(id, .str(kayaAcceptList(accepting)))
        return id
    }
}

struct KayaPickedFile {
    let handle: UInt64
    let name: String
    let localPath: String

    /// Redeem the handle for a real FileHandle, plus whether it seeks.
    ///
    /// BLOCKS, and may block for a long time — a cloud provider can
    /// download the file before it answers — so call it from a thread
    /// you chose and post the result back. kaya is not in the data
    /// path: what comes back is an ordinary FileHandle.
    ///
    /// THE DESCRIPTOR BECOMES SWIFT'S: closeOnDealloc is true, so it
    /// closes exactly once and the core keeps no claim.
    ///
    /// `seekable` RIDES THE OPEN rather than the pick because that is
    /// the only place the answer exists — an Android provider may hand
    /// back a pipe, and nothing short of opening reveals it.
    func open(_ mode: UInt32 = UInt32(FILE_MODE_READ))
        throws -> (file: FileHandle, seekable: Bool)
    {
        var raw: Int64 = 0
        var seekable: UInt32 = 0
        let rc = kaya_open_picked(handle, mode, &raw, &seekable)
        guard rc == 0 else {
            throw NSError(
                domain: "kaya", code: Int(rc),
                userInfo: [NSLocalizedDescriptionKey:
                    "kaya: opening the picked file failed (code \(rc))"])
        }
        return (FileHandle(fileDescriptor: Int32(raw), closeOnDealloc: true), seekable != 0)
    }
}

final class KayaApp {
    // Work handed over by other threads, waiting to run as transactions
    // on the app thread. THE ONLY STATE HERE TOUCHED FROM ANOTHER
    // THREAD, and the only reason this class carries a lock at all —
    // everything below is app-thread-only by construction.
    private let postLock = NSLock()
    private var posted: [(KayaAppTx) throws -> Void] = []
    private var signals: UInt64 = 0
    private var widgets: UInt64 = 0
    private var collections: UInt64 = 0
    private var nodes: UInt64 = 0
    private var menuItems: UInt64 = 0
    private var widgetHandlers: [UInt64: (KayaAppTx) throws -> Void] = [:]
    private var nodeHandlers: [UInt64: (KayaAppTx, [KayaValue]) throws -> Void] = [:]
    private var widgetChanges: [UInt64: (KayaAppTx, String) throws -> Void] = [:]
    private var nodeChanges: [UInt64: (KayaAppTx, [KayaValue], String) throws -> Void] = [:]
    private var widgetToggles: [UInt64: (KayaAppTx, Bool) throws -> Void] = [:]
    private var widgetValues: [UInt64: (KayaAppTx, Double) throws -> Void] = [:]
    private var nodeValues: [UInt64: (KayaAppTx, [KayaValue], Double) throws -> Void] = [:]
    // Window lifecycle: one handler each, receiving the window id.
    private var closeRequested: [UInt64: (KayaAppTx) throws -> Void] = [:]
    private var entryPopped: [UInt64: (KayaAppTx) throws -> Void] = [:]
    private var backRequested: [UInt64: (KayaAppTx) throws -> Void] = [:]
    private var sectionSelected: [UInt64: (KayaAppTx) throws -> Void] = [:]
    private var alerts: [UInt64: (KayaAppTx, UInt32) throws -> Void] = [:]
    private var fileDialogs: [UInt64: (KayaAppTx, [KayaPickedFile]) throws -> Void] = [:]
    // Clipboard reads share the alert's request/result grammar and so
    // its table shape: one-shot, keyed by request id.
    private var clipboardReads: [UInt64: (KayaAppTx, KayaRepresentation?) throws -> Void] = [:]
    private var widgetPastes: [UInt64: (KayaAppTx, KayaRepresentation) throws -> Void] = [:]
    private var nodePastes: [UInt64: (KayaAppTx, [KayaValue], KayaRepresentation) throws -> Void] = [:]
    private var nextClipboardRead: UInt64 = 0
    private var nextAlert: UInt64 = 0
    private var nextFileDialog: UInt64 = 0
    private var windowClosed: [UInt64: (KayaAppTx) throws -> Void] = [:]
    private var nodeToggles: [UInt64: (KayaAppTx, [KayaValue], Bool) throws -> Void] = [:]
    // The two history occurrences, keyed by WINDOW — one ledger per
    // window (docs/undo-plan.md §3) — and PERSISTENT, the
    // section-selected stance rather than the alert's one-shot: a
    // history is walked as often as the user likes.
    private var undone: [UInt64: (KayaAppTx, String, KayaUndoDelta) throws -> Void] = [:]
    private var redone: [UInt64: (KayaAppTx, String, KayaUndoDelta) throws -> Void] = [:]
    // How to rebuild a model entry from the wire fields an undo hands
    // back, per collection. The model keeps NATIVE values (a KayaValue
    // for a scalar collection, the guest's own struct or enum for a
    // record or sum one), and only the type that declared the
    // collection can make one — so each factory leaves its constructor
    // here at declaration, which is the only moment the type is known.
    private var elementDecoders: [UInt64: (UInt32, [KayaValue]) -> Any] = [:]
    // Menu dispatch tables, keyed by MENU ITEM id — their own id
    // space, separate from every widget/node table ("two tables,
    // always" — now N tables, still always). The node flavors receive
    // the stamped copy's key path (the keys ARE the noun).
    var menuActivated: [UInt64: (KayaAppTx) throws -> Void] = [:]
    var menuActivatedNode: [UInt64: (KayaAppTx, [KayaValue]) throws -> Void] = [:]
    var menuToggled: [UInt64: (KayaAppTx, Bool) throws -> Void] = [:]
    var menuToggledNode: [UInt64: (KayaAppTx, [KayaValue], Bool) throws -> Void] = [:]
    var menuSelected: [UInt64: (KayaAppTx, Int) throws -> Void] = [:]
    var menuSelectedNode: [UInt64: (KayaAppTx, [KayaValue], Int) throws -> Void] = [:]

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
    // its For widget to the top frame at close. Frames are
    // zone-tagged: constructors parent AT CREATION (the ambient-stack
    // semantics every other binding has — parenting at expression
    // position silently dropped any let-bound child, the unparented-
    // entry focus bug), and the tag makes a cross-zone child loud
    // instead of silently absent.
    struct KayaFrame {
        let template: Bool
        var ids: [UInt64] = []
    }

    var childFrames: [KayaFrame] = []

    /// A live widget parents into the open live frame at creation;
    /// creating one inside a template body is misuse, caught here.
    fileprivate func parentAtCreation(live id: UInt64) {
        guard let top = childFrames.indices.last else { return }
        precondition(
            !childFrames[top].template,
            "kaya: a live widget cannot be created inside a template body")
        childFrames[top].ids.append(id)
    }

    /// A template node parents into the open template frame at
    /// creation; with no template frame open it is template-rooted
    /// (a blueprint root, or a trace body's row) and the scope itself
    /// carries it.
    fileprivate func parentAtCreation(node id: UInt64) {
        if let top = childFrames.indices.last, childFrames[top].template {
            childFrames[top].ids.append(id)
        }
    }

    /// Run a For's or a When's body behind a PARENT BARRIER: a node
    /// created directly in that body is a ROOT of the template it
    /// declares — the core derives the roots itself — and never a child
    /// of whatever container encloses the combinator. The frame is
    /// pushed only to be dropped; its ids are the roots, and roots take
    /// no add_child.
    ///
    /// Java's binding has always spelled this (`parents.add(0L)` around
    /// the body); Swift's omission survived because no Swift guest had
    /// ever declared a For inside a TEMPLATE container. milestone2's
    /// graduation is the first, and without the barrier its item column
    /// parented into the enclosing group column across the inner For's
    /// scope — which the core refuses outright ("add_child across
    /// template cases"). That refusal is the wall; this is the fix it
    /// named.
    fileprivate func inTemplateBody<R>(_ body: () -> R) -> R {
        childFrames.append(KayaFrame(template: true))
        defer { childFrames.removeLast() }
        return body()
    }
    var openTraces = 0
    // The record-time mirror-read guard's arming counter: >0 while any
    // template body (a For body, a When body, or a row-trace body) is
    // being DECLARED. Distinct from openFors (For-only, and keyed by
    // collection): every template scope bumps this, When included.
    var tplDepth = 0

    init() {
        KayaApp.ambient = self
    }

    private var model: [UInt64: [KayaInstance]] = [:]
    // The minter's counters: the highest I64 key each collection
    // INSTANCE has minted or absorbed. Keyed by path the way the model
    // is (a [KayaValue] is not Hashable — KayaValue carries an f64), and
    // NOT part of the transaction journal: a minted key is spent even if
    // the transaction that spent it is abandoned, so an id can never be
    // handed out twice.
    private var fresh: [UInt64: [(path: [KayaValue], counter: Int64)]] = [:]
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

    /// One instance's counter, made if this is the first anyone has
    /// asked. Split out because both the mint and the absorb want the
    /// same lookup.
    private func withCounter<R>(
        _ coll: UInt64, _ path: [KayaValue], _ body: (inout Int64) -> R
    ) -> R {
        var instances = fresh[coll, default: []]
        let at = instances.firstIndex { $0.path == path } ?? {
            instances.append((path: path, counter: 0))
            return instances.count - 1
        }()
        let out = body(&instances[at].counter)
        fresh[coll] = instances
        return out
    }

    /// The next fresh key for one instance: counter+1, and the counter
    /// keeps it. Monotonic by construction — nothing else writes it
    /// downwards (see `KayaAppTx.insertFresh`).
    fileprivate func mintKey(_ coll: UInt64, _ path: [KayaValue]) -> Int64 {
        withCounter(coll, path) { counter in
            counter += 1
            return counter
        }
    }

    /// An explicit key, shown to the minter on its way into the table.
    /// A numeric key at or above the counter carries it up so the next
    /// mint clears it; anything else moves nothing, having no way to
    /// collide with an I64.
    fileprivate func absorbKey(_ coll: UInt64, _ path: [KayaValue], _ key: KayaValue) {
        guard case .i64(let n) = key else { return }
        withCounter(coll, path) { counter in counter = max(counter, n) }
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

    /// Record how this collection's elements are built from wire
    /// fields; called by every collection factory at declaration.
    func registerDecoder(_ coll: UInt64, _ decode: @escaping (UInt32, [KayaValue]) -> Any) {
        elementDecoders[coll] = decode
    }

    /// Fold an undo's payload into the mirrors this binding keeps.
    ///
    /// THE ROLLBACK JOURNAL IN REVERSE: a rolled-back transaction
    /// restores a snapshot because nothing was shipped; an undo
    /// restores a delta because everything WAS — the core has already
    /// moved, and the mirror is what would otherwise be left behind.
    /// Same machinery, opposite case, and the payload is
    /// core-authoritative so nothing here re-derives anything.
    ///
    /// NOT INSIDE A TRANSACTION, and it must not be: the core moved
    /// without one, so these writes describe state that is already
    /// true. Sending records would apply the undo a second time.
    /// Signals are mirrored here for the same reason (a derived signal
    /// reads its source's mirror), and the derived recompute does NOT
    /// re-run: whatever the group wrote to a derived signal is in this
    /// same payload, restored by the core that owns it.
    fileprivate func absorbUndo(_ delta: KayaUndoDelta) {
        for (signal, value) in delta.signals {
            signalMirrors[signal] = value
        }
        for entry in delta.entries {
            // The same two calls an ordinary mutation makes, so an
            // undone entry and a removed one leave the model in the
            // same shape (descendant instances purged included) — one
            // implementation of each rule, not a second copy here.
            guard let state = entry.state else {
                modelRemove(entry.collection, entry.path, entry.key)
                continue
            }
            guard let decode = elementDecoders[entry.collection] else {
                preconditionFailure(
                    "kaya: collection \(entry.collection) came back from an undo with no "
                        + "element decoder — every collection registers one at declaration")
            }
            modelSet(
                entry.collection, entry.path, entry.key,
                decode(state.variant, state.fields))
        }
        for order in delta.orders {
            guard var instances = model[order.collection],
                let at = instances.firstIndex(where: { $0.path == order.path })
            else { continue }
            // Position by the payload's list, keeping anything it does
            // not name at the end: the delta describes one instance's
            // whole order, and an entry it never mentions is one this
            // undo did not touch.
            var sorted: [(key: KayaValue, value: Any)] = []
            for key in order.keys {
                if let slot = instances[at].entries.firstIndex(where: { $0.key == key }) {
                    sorted.append(instances[at].entries.remove(at: slot))
                }
            }
            instances[at].entries = sorted + instances[at].entries
            model[order.collection] = instances
        }
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

    func nextMenuItem() -> KayaMenuItem {
        menuItems += 1
        return KayaMenuItem(id: menuItems)
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
            tx.close()
            return out
        } catch {
            tx.rollback()
            tx.close()
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

    /// A template slider's or choice widget's change handler; it also
    /// receives the stamped copy's keys, outermost first — the
    /// `onToggle(_ n:_:)` shape, one payload over.
    ///
    /// This registrar and its dispatch arm arrived together with the
    /// template `slider`/`select`/`radio` constructors, and the reason
    /// is worth keeping: the core has ALWAYS emitted
    /// `Occurrence::InstanceValueChanged` for a stamped copy, and until
    /// now nothing here read it. The dispatch switch had a keyed arm for
    /// clicks, for text edits, for toggles and for pastes, and only the
    /// keyless one for value changes, so a stamped slider's move matched
    /// no case and fell out of `default: break` — dropped in silence,
    /// which is the failure class no scene can see. Nothing had reached
    /// it only because there was no constructor to build such a slider.
    func onValueChanged(
        _ n: KayaNodeHandle, _ handler: @escaping (KayaAppTx, [KayaValue], Double) throws -> Void
    ) {
        nodeValues[n.id] = handler
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
    /// Run `body` as a transaction on the app thread, soon. THE ONE
    /// method safe to call from another thread, and the answer to "how
    /// does background work reach the UI".
    ///
    /// `build` is a transaction NOW on the calling thread; `post` is the
    /// same transaction SOON on the app thread — so a background thread
    /// writes ordinary blocking Swift and hands back only the result:
    ///
    ///     Thread.detachNewThread {
    ///         let data = try! Data(contentsOf: url)   // blocks this thread
    ///         app.post { tx in try tx.write(content, String(decoding: data, as: UTF8.self)) }
    ///     }
    ///
    /// The `KayaAppTx` is made where it is used and never crosses a
    /// thread; ids are values and are meant to be captured. A posted
    /// body runs in its OWN transaction, after whatever is running now,
    /// so posting from inside a handler queues for after and never
    /// nests.
    func post(_ body: @escaping (KayaAppTx) throws -> Void) {
        postLock.lock()
        posted.append(body)
        postLock.unlock()
        // The app thread may be parked in C waiting on the ring. Posted
        // work is not an occurrence and never enters that ring, so this
        // is the only way it hears about it.
        kaya_wake()
    }

    /// Run everything posted, each as its own transaction, in order.
    ///
    /// The batch is taken and the lock released BEFORE any of it runs,
    /// so a body that posts again lands in the NEXT batch. Holding the
    /// lock across the calls would let a self-posting body drain forever
    /// and starve the occurrence loop.
    private func drainPosted() {
        postLock.lock()
        let batch = posted
        posted = []
        postLock.unlock()
        for body in batch {
            dispatch { try build(body) }
        }
    }

    private func dispatch(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            FileHandle.standardError.write(
                Data("kaya: handler threw (transaction rolled back): \(error)\n".utf8))
        }
    }

    /// Per-window lifecycle registrations (internal: the createWindow
    /// sugar registers at declaration — handlers scope to the thing
    /// that creates them; the closed one retires with its window).
    func onCloseRequested(_ window: UInt64, _ handler: @escaping (KayaAppTx) throws -> Void) {
        closeRequested[window] = handler
    }

    /// Bind the one-shot result handler to a request (internal: the
    /// Tx sugar registers at show time; the registration retires
    /// with the result).
    func onAlert(_ alert: UInt64, _ handler: @escaping (KayaAppTx, UInt32) throws -> Void) {
        alerts[alert] = handler
    }

    func allocAlert() -> UInt64 {
        nextAlert += 1
        return nextAlert
    }

    /// Bind a clipboard read's one-shot result handler (internal: the
    /// Tx sugar registers at send time, on the alert's grammar).
    func onClipboard(
        _ request: UInt64, _ handler: @escaping (KayaAppTx, KayaRepresentation?) throws -> Void
    ) {
        clipboardReads[request] = handler
    }

    func allocClipboardRead() -> UInt64 {
        nextClipboardRead += 1
        return nextClipboardRead
    }

    func onPaste(
        _ w: KayaWidget,
        _ handler: @escaping (KayaAppTx, KayaRepresentation) throws -> Void
    ) {
        widgetPastes[w.id] = handler
    }

    func onPaste(
        _ n: KayaNodeHandle,
        _ handler: @escaping (KayaAppTx, [KayaValue], KayaRepresentation) throws -> Void
    ) {
        nodePastes[n.id] = handler
    }

    /// Bind the picker's one-shot result handler (internal: the Tx
    /// sugar registers at show time and the registration retires with
    /// the result).
    func onFileDialog(
        _ dialog: UInt64, _ handler: @escaping (KayaAppTx, [KayaPickedFile]) throws -> Void
    ) {
        fileDialogs[dialog] = handler
    }

    func allocFileDialog() -> UInt64 {
        nextFileDialog += 1
        return nextFileDialog
    }

    func onWindowClosed(_ window: UInt64, _ handler: @escaping (KayaAppTx) throws -> Void) {
        windowClosed[window] = handler
    }

    /// Per-entry navigation registrations (internal: the pushEntry
    /// sugar registers at push time — the request-bound alert
    /// precedent; the popped one retires with its one pop).
    func onEntryPopped(_ entry: UInt64, _ handler: @escaping (KayaAppTx) throws -> Void) {
        entryPopped[entry] = handler
    }

    func onBackRequested(_ entry: UInt64, _ handler: @escaping (KayaAppTx) throws -> Void) {
        backRequested[entry] = handler
    }

    /// Per-section, NOT one-shot: the user can return any number of
    /// times; a programmatic selectSection never fires it (the echo
    /// doctrine).
    func onSectionSelected(_ section: UInt64, _ handler: @escaping (KayaAppTx) throws -> Void) {
        sectionSelected[section] = handler
    }

    /// kaya routed an undo in this window, and this is what the CORE
    /// put back (internal: the window construct registers at
    /// declaration — handlers scope to the thing that creates them, and
    /// the ledger is per window).
    ///
    /// PER WINDOW AND PERSISTENT, never one-shot: a history is walked
    /// as often as the user likes. The label is the group's authored
    /// name, or EMPTY for a typing episode — kaya invents no
    /// user-facing strings, so the word for that is the app's to spell.
    func onUndone(
        _ window: UInt64, _ handler: @escaping (KayaAppTx, String, KayaUndoDelta) throws -> Void
    ) {
        undone[window] = handler
    }

    /// The onUndone twin, same payload, opposite direction. Only a
    /// FRONTIER typing episode redoes natively, and that one never
    /// arrives here: it is the platform's own stack moving, reported by
    /// its ordinary text_changed.
    func onRedone(
        _ window: UInt64, _ handler: @escaping (KayaAppTx, String, KayaUndoDelta) throws -> Void
    ) {
        redone[window] = handler
    }

    private func dispatchLoop() {
        var record: UnsafePointer<UInt8>?
        while true {
            // Posted work first, then the ring. Draining at the TOP is
            // what makes a wake sufficient: whatever brought this thread
            // back, it looks here before anywhere else.
            drainPosted()
            let size = kaya_next_occurrence(&record)
            if size == KAYA_OCCURRENCE_SHUTDOWN { return }
            if size == KAYA_OCCURRENCE_WOKEN {
                // NO RECORD WAS HANDED OUT. Decoding here would re-parse
                // the PREVIOUS one — a stale re-dispatch, and the bug
                // this branch prevents.
                continue
            }
            // The core owns the bytes until the next call, so they are
            // copied out here. There is no cap: an html clip is
            // routinely kilobytes.
            guard let start = record else { continue }
            let buf = [UInt8](UnsafeBufferPointer(start: start, count: Int(size)))
            // THE TWO HISTORY RECORDS ARE READ FIRST, and by their own
            // parser: their head is four counts and one flat Values
            // block, not the widget/keys/payload shape every other
            // record has, so the general parser must never see these
            // bytes. An undo moved core state without a transaction, so
            // the mirrors are folded HERE, before the handler — a
            // read-back inside it answers about the restored state.
            let recKind = buf.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 4, as: UInt16.self)
            }
            if recKind == UInt16(KAYA_OCCURRENCE_UNDONE)
                || recKind == UInt16(KAYA_OCCURRENCE_REDONE)
            {
                guard let (window, label, delta) = kayaParseUndo(buf) else { continue }
                absorbUndo(delta)
                let table = recKind == UInt16(KAYA_OCCURRENCE_UNDONE) ? undone : redone
                if let handler = table[window] {
                    dispatch { try build { tx in try handler(tx, label, delta) } }
                }
                continue
            }
            guard let (kind, id, keys, payload, files, clip) = kayaParseOccurrence(buf)
            else { continue }
            var text: String?
            var checked = false
            var value = 0.0
            var choice: UInt32 = 0
            switch payload {
            case .str(let s): text = s
            case .bool(let b): checked = b
            case .f64(let x): value = x
            // The alert parser boxes the u32 choice as .i64.
            case .i64(let n): choice = UInt32(truncatingIfNeeded: n)
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
            case (UInt16(KAYA_OCCURRENCE_VALUE_CHANGED), false):
                if let handler = nodeValues[id] {
                    dispatch { try build { tx in try handler(tx, keys, value) } }
                }
            case (UInt16(KAYA_OCCURRENCE_CLOSE_REQUESTED), _):
                if let handler = closeRequested[id] {
                    dispatch { try build(handler) }
                }
            case (UInt16(KAYA_OCCURRENCE_WINDOW_CLOSED), _):
                // One-shot: the window is gone; both registrations
                // retire with it.
                closeRequested.removeValue(forKey: id)
                if let handler = windowClosed.removeValue(forKey: id) {
                    dispatch { try build(handler) }
                }
            case (UInt16(KAYA_OCCURRENCE_ENTRY_POPPED), _):
                // One-shot: the entry is gone; both registrations
                // retire with it.
                backRequested.removeValue(forKey: id)
                if let handler = entryPopped.removeValue(forKey: id) {
                    dispatch { try build(handler) }
                }
            case (UInt16(KAYA_OCCURRENCE_BACK_REQUESTED), _):
                if let handler = backRequested[id] {
                    dispatch { try build(handler) }
                }
            case (UInt16(KAYA_OCCURRENCE_SECTION_SELECTED), _):
                // NOT one-shot: sections never die, and the user can
                // return any number of times (id is the section; the
                // window rides as the payload).
                if let handler = sectionSelected[id] {
                    dispatch { try build(handler) }
                }
            case (UInt16(KAYA_OCCURRENCE_ALERT_RESULT), _):
                // One-shot: the registration retires with the result.
                if let handler = alerts.removeValue(forKey: id) {
                    dispatch { try build { tx in try handler(tx, choice) } }
                }
            case (UInt16(KAYA_OCCURRENCE_CLIPBOARD_RESULT), _):
                // One-shot like the alert, and the request retires with
                // it. EMPTY IS THE UNIVERSAL NO and arrives as nil —
                // denied, unfocused, absent and nothing-we-accept
                // alike, because no platform says which.
                if let handler = clipboardReads.removeValue(forKey: id) {
                    let answer = kayaRepresentation(clip)
                    dispatch { try build { tx in try handler(tx, answer) } }
                }
            // A paste rides a click tag verbatim, so it arrives on the
            // ordinary widget/node split — one record kind, the key
            // path deciding. Never empty: a paste that delivered
            // nothing is not an occurrence.
            case (UInt16(KAYA_OCCURRENCE_PASTED), true):
                if let handler = widgetPastes[id], let answer = kayaRepresentation(clip) {
                    dispatch { try build { tx in try handler(tx, answer) } }
                }
            case (UInt16(KAYA_OCCURRENCE_PASTED), false):
                if let handler = nodePastes[id], let answer = kayaRepresentation(clip) {
                    dispatch { try build { tx in try handler(tx, keys, answer) } }
                }
            case (UInt16(KAYA_OCCURRENCE_FILE_DIALOG_RESULT), _):
                // One-shot like the alert, and the id retires with it.
                // EMPTY IS CANCEL — no platform can confirm an empty
                // selection, so there is no sentinel to invent.
                if let handler = fileDialogs.removeValue(forKey: id) {
                    dispatch { try build { tx in try handler(tx, files) } }
                }
            // Menu occurrences key the menu-item tables — their own id
            // space, so neither widget nor node ids can collide with
            // them. Node-anchored context items carry the stamped
            // copy's keys (the keys ARE the noun); toggles carry the
            // new state, radio groups the new 0-based index.
            case (UInt16(KAYA_OCCURRENCE_MENU_ACTIVATED), true):
                if let handler = menuActivated[id] {
                    dispatch { try build(handler) }
                }
            case (UInt16(KAYA_OCCURRENCE_MENU_ACTIVATED), false):
                if let handler = menuActivatedNode[id] {
                    dispatch { try build { tx in try handler(tx, keys) } }
                }
            case (UInt16(KAYA_OCCURRENCE_MENU_TOGGLED), true):
                if let handler = menuToggled[id] {
                    dispatch { try build { tx in try handler(tx, checked) } }
                }
            case (UInt16(KAYA_OCCURRENCE_MENU_TOGGLED), false):
                if let handler = menuToggledNode[id] {
                    dispatch { try build { tx in try handler(tx, keys, checked) } }
                }
            case (UInt16(KAYA_OCCURRENCE_MENU_VALUE_CHANGED), true):
                if let handler = menuSelected[id] {
                    dispatch { try build { tx in try handler(tx, Int(value)) } }
                }
            case (UInt16(KAYA_OCCURRENCE_MENU_VALUE_CHANGED), false):
                if let handler = menuSelectedNode[id] {
                    dispatch { try build { tx in try handler(tx, keys, Int(value)) } }
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
    // Parenting happens at creation (the constructors append to the
    // open frame); expression position only carries the value away.
    static func buildExpression(_ w: KayaWidget) {
        _ = w
    }

    static func buildExpression(_ n: KayaNodeHandle) {
        _ = n
    }

    // Void statements are legal in a body: an inline attachment
    // (tx.contextMenu(target, items:)) or a command declares beside
    // the widgets it concerns — nothing rides on expression position.
    static func buildExpression(_: Void) {}

    static func buildBlock(_: Void...) {}

    static func buildArray(_: [Void]) {}
}

@resultBuilder
enum KayaNodeChildren {
    // Parenting happens at creation; see KayaChildren.
    static func buildExpression(_ n: KayaNodeHandle) {
        _ = n
    }

    static func buildExpression(_: Void) {}

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
            app.tplDepth += 1
            return makeRow(KayaTpl(tx: tx))
        }
        if state == 1 {
            state = 2
            app.openFors.removeLast()
            tx.tx.templateEnd()
            app.openTraces -= 1
            // Paired with openTraces: a break-ed trace never reaches
            // here, and submitIfAny's openTraces precondition kills the
            // transaction before a stuck depth could misfire.
            app.tplDepth -= 1
            precondition(
                !app.childFrames.isEmpty,
                "kaya: a for-in over rows needs an enclosing container builder")
            app.childFrames[app.childFrames.count - 1].ids.append(forId)
        }
        return nil
    }
}

final class KayaAppTx {
    let app: KayaApp

    // THE ONE CHOKEPOINT. Every write in this file is `tx.<verb>(...)`
    // — a mutating method on the struct — so a computed property that
    // checks liveness on the way in guards all ninety of them without
    // touching a callsite, and guards the next one too. That is the
    // part that matters: a check spread over callsites is a check that
    // gets forgotten. Go's lived on two chains only, and a write
    // through a Tx that had outlived its build appended into a buffer
    // already submitted and never submitted again — no error, the
    // write simply vanished.
    //
    // Nothing invited that mistake until post arrived. Posting is
    // exactly the reason a guest now holds a tx near a background
    // thread, so the guard has to be total.
    private var storage = KayaTx()
    private var closed = false
    /// Whether undoable() has already named this batch — one name per
    /// step, and the marker is a head-of-batch singleton on the wire.
    private var named = false
    var tx: KayaTx {
        get {
            alive()
            return storage
        }
        set {
            alive()
            storage = newValue
        }
    }

    /// A KayaAppTx is valid ONLY inside the build or handler that made
    /// it, on the app thread. To mutate from anywhere else, post.
    func alive() {
        precondition(
            !closed,
            "kaya: transaction is over — a tx is only usable inside the build or handler "
                + "that created it; to mutate from a background thread use app.post")
    }

    /// Called by build on the way out, on every path.
    func close() {
        closed = true
    }
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
        // `storage` and not `tx`: the submit is the transaction's own
        // last act, and routing it through the liveness property would
        // make the guard trip on the very call that closes it.
        if !storage.bytes.isEmpty {
            storage.submit()
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

    /// Make this transaction ONE undoable step, under `label`, in
    /// `window`'s ledger (docs/undo-plan.md D2).
    ///
    /// The unit of undo is a NAMED GROUP declared at the opener, not
    /// every transaction: handlers fire per-gesture transactions
    /// constantly and most of them are consequences rather than
    /// intents, and a per-keystroke editor would earn one step per
    /// character — the exact problem grouping exists to solve. So a
    /// group is opt-in, which is also what keeps a collaborative app
    /// free to own its own history.
    ///
    /// CALLABLE ANYWHERE IN THE CHAIN, and the marker still rides at
    /// the head: a handler naturally builds first and names the step
    /// when it knows what the step was, and the wire's head-of-batch
    /// rule should not turn that into a footgun.
    ///
    /// WHAT A GROUP MAY HOLD is the reactive half — signal writes and
    /// collection deltas, whose inverse the core derives from state it
    /// already keeps. Focus is permitted and not restored. Anything
    /// else (a const property write, creating a widget, clear, showing
    /// a dialog) fails at apply, naming the op: undo restores state,
    /// and state is signals plus collections. The app hears the result
    /// through the window construct's onUndone.
    ///
    /// Each window has its own history, because Undo in one window has
    /// never meant "revert what happened in another"; 0 is the primary.
    func undoable(_ label: String, window: UInt64 = 0) {
        precondition(
            !named,
            "kaya: this transaction is already an undo group — one name per step")
        named = true
        // THE HEAD OF THE BATCH, wherever the call sits: a transaction
        // is a bare list of records with no header, so the marker's
        // position IS its association with the batch.
        var head = KayaTx()
        head.undoGroup(window, .str(label))
        head.bytes.append(tx.bytes)
        tx = head
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
        app.parentAtCreation(live: w.id)
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

    /// Set a widget's flex weight within its row/column: 0 is natural
    /// size, positive weights divide the container's leftover
    /// main-axis space in proportion (see Prop::Grow in the core). The
    /// declarative spelling is the `grow:` argument at construction;
    /// this is the dynamic path.
    /// A container's inter-child gap (main axis, DIP; the normalized
    /// default is 8). Containers only — the scene rejects it anywhere
    /// else. The declarative spelling is the `spacing:` argument at
    /// construction; this is the dynamic path.
    func setSpacing(_ w: KayaWidget, _ gap: Double) {
        tx.setSpacing(w.id, gap)
    }

    /// A container's OWN padding: DIP between its bounds and its
    /// children, uniform on all four sides — the window inset one level
    /// down (docs/styling-plan.md D3). Containers only — the scene
    /// rejects it anywhere else. The declarative spelling is the
    /// `inset:` argument at construction; this is the dynamic path.
    ///
    /// The window's own inset is the `inset:` argument on `window(...)`;
    /// this is the same number one level down, so a full-bleed window
    /// can still hold an inset status row — the app that forced the
    /// prop into existence (the editor).
    func setInset(_ w: KayaWidget, _ pad: Double) {
        tx.setInset(w.id, pad)
    }

    /// A container's cross-axis child placement. Containers only;
    /// baseline is rows-only — the scene rejects misuse at the root.
    /// The declarative spelling is the `align:` argument at
    /// construction; this is the dynamic path.
    func setAlign(_ w: KayaWidget, _ align: KayaAlign) {
        tx.setAlign(w.id, align.rawValue)
    }

    /// A widget's SEMANTIC EMPHASIS: destructive/prominent on buttons,
    /// heading on labels — what it means, never how it looks. The
    /// declarative spelling is the `role:` argument at construction;
    /// this is the dynamic path. A role on a kind it does not fit dies
    /// at the root, at declare time.
    func setRole(_ w: KayaWidget, _ role: KayaRole) {
        tx.setRole(w.id, role.rawValue)
    }

    func setGrow(_ w: KayaWidget, _ weight: Double) {
        tx.setGrow(w.id, weight)
    }

    /// A widget's accessibility IDENTIFIER: a stable authored key that
    /// assistive tooling and UI automation address it by, and which is
    /// NEVER spoken. Universal — every kind carries one.
    func setA11yId(_ w: KayaWidget, _ id: String) {
        tx.setA11yId(w.id, id)
    }

    /// What an assistive client SPEAKS for a widget. Universal, and
    /// deliberately separate from the identifier — an automation key is
    /// not a spoken name. Leave it unset to keep whatever the platform
    /// derives from the control's own content; setting it OVERRIDES
    /// that, so a button whose caption already reads well needs nothing
    /// here.
    func setA11yLabel(_ w: KayaWidget, _ label: String) {
        tx.setA11yLabel(w.id, label)
    }

    /// What ACTIVATING this widget does — the platforms' hint (Apple
    /// defines it as the result of performing an action; Android
    /// carries it as the click action's label). Write a VERB PHRASE.
    /// Activation kinds only; the root rejects it elsewhere.
    func setA11yHint(_ w: KayaWidget, _ hint: String) {
        tx.setA11yHint(w.id, hint)
    }

    func bindChecked(_ w: KayaWidget, _ s: KayaSignal) {
        tx.bindChecked(w.id, s.id)
    }

    /// Aim an image's source at encoded bytes: one registration copy
    /// into core memory — the handle is consumed by the next submit,
    /// and the guest's bytes are free to drop the moment this returns.
    func setSource(_ w: KayaWidget, _ data: Data) {
        tx.setSource(w.id, kayaRegisterBlob(data))
    }

    /// Aim an image's source at a signal carrying a blob handle.
    func bindSource(_ w: KayaWidget, _ s: KayaSignal) {
        tx.bindSource(w.id, s.id)
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

    // --- Text ranges: decorate a set, select one, reveal one ----------
    //
    // The three primitives an editor cannot write for itself
    // (docs/ranges-plan.md D1). kaya ships no search: WHAT to decorate
    // is the app's question and every editor answers it differently.
    //
    // EVERY OFFSET HERE IS A UTF-8 BYTE OFFSET into the widget's current
    // text — kaya's unit on the wire, in all nine languages. Swift is
    // the one guest language whose strings are indexed by NEITHER bytes
    // nor an integer, so it is the one where "hand kaya the ranges you
    // already have" needs the binding to mean it. Hence two spellings
    // per verb:
    //
    //   * `Range<String.Index>` + the string they index — what Swift's
    //     own search returns, converted here. REACH FOR THIS ONE.
    //   * `Range<Int>` — the byte-offset floor, for an app that already
    //     holds offsets in kaya's unit.
    //
    // The conversion is not a formality, it is the trap. Measured on
    // this milestone's own document (a CJK word on line 0, ASCII after):
    // for the first match of "alpha" the byte offset is 57, while
    // `doc.distance(from:to:)` (Characters) says 51 and
    // `String.Index.utf16Offset(in:)` says 51 — the two spellings a
    // Swift author reaches for first, both six early, both silent. An
    // app that hand-rolled either would decorate six characters off and
    // find nothing in kaya to blame.

    /// DECLARE the decorated ranges of a textarea, replacing whatever
    /// was declared before; an empty set is the clear.
    ///
    /// The ranges are Swift's own — `String.range(of:)` and friends
    /// return exactly this — and `text` is the string they index, which
    /// is what makes a `String.Index` mean anything at all.
    ///
    /// APP-OWNED AND NEVER TRACKED. A declared set is bound to the text
    /// it was declared against: the first edit of any kind drops it, and
    /// the app re-declares from the fold `onChange` already drives — the
    /// same uncontrolled contract the text itself has. Nothing in kaya
    /// adjusts a range across an edit.
    func highlightRanges(
        _ w: KayaWidget, _ ranges: [Range<String.Index>], in text: String
    ) {
        highlightRanges(w, ranges.map { kayaByteRange($0, in: text) })
    }

    /// The byte-offset floor of `highlightRanges(_:_:in:)`: offsets are
    /// UTF-8 byte offsets into the widget's current text.
    ///
    /// An offset past the end of the text, or one that splits a
    /// character, fails loudly in the core rather than in a backend: the
    /// five platforms answer a malformed offset five different ways and
    /// one of them aborts the process.
    func highlightRanges(_ w: KayaWidget, _ ranges: [Range<Int>]) {
        var flat: [KayaValue] = []
        flat.reserveCapacity(ranges.count * 2)
        for r in ranges {
            let (start, stop) = kayaRangeOffsets(r)
            flat.append(.i64(Int64(start)))
            flat.append(.i64(Int64(stop)))
        }
        tx.highlightRanges(w.id, UInt32(ranges.count), flat)
    }

    /// Put the textarea's selection at one range (an empty range is a
    /// caret). Same offsets, same validation as `highlightRanges`.
    ///
    /// REFUSED WHILE THE USER IS COMPOSING through an input method, in
    /// every backend, because honouring it commits the composition
    /// mid-word — measured on macOS, where the half-typed kana land in
    /// the document and in the app's own model. The refusal is a no-op,
    /// not an error: composition state is on no kaya channel, so an app
    /// cannot avoid the race and is not blamed for it. The selection the
    /// app wanted is still worth asking for after the next `onChange`,
    /// which is what ends a composition.
    func selectRange(_ w: KayaWidget, _ range: Range<String.Index>, in text: String) {
        selectRange(w, kayaByteRange(range, in: text))
    }

    /// The byte-offset floor of `selectRange(_:_:in:)`.
    func selectRange(_ w: KayaWidget, _ range: Range<Int>) {
        let (start, stop) = kayaRangeOffsets(range)
        tx.selectRange(w.id, start, stop)
    }

    /// Scroll the textarea so a range is inside the viewport. A pure
    /// effect: it moves no state, leaves the selection alone, and undo
    /// does not put the scroll position back (undo restores state, not
    /// where you were looking).
    func revealRange(_ w: KayaWidget, _ range: Range<String.Index>, in text: String) {
        revealRange(w, kayaByteRange(range, in: text))
    }

    /// The byte-offset floor of `revealRange(_:_:in:)`.
    func revealRange(_ w: KayaWidget, _ range: Range<Int>) {
        let (start, stop) = kayaRangeOffsets(range)
        tx.revealRange(w.id, start, stop)
    }

    /// A `Range<Int>` as the wire's two unsigned offsets. `Range`
    /// already guarantees lower <= upper, so one bound is the only
    /// thing left to check — and checking it here names kaya instead of
    /// letting `UInt64.init` trap with "Negative value is not
    /// representable", or letting a select_range wrap a negative into a
    /// nonsense offset the core then reports as past the end.
    private func kayaRangeOffsets(_ r: Range<Int>) -> (UInt64, UInt64) {
        precondition(
            r.lowerBound >= 0,
            "kaya: a text range starts at \(r.lowerBound) — offsets are UTF-8 byte "
                + "offsets into the widget's text and cannot be negative")
        return (UInt64(r.lowerBound), UInt64(r.upperBound))
    }

    // --- Construction sugar: the tree reads as a tree ----------------
    //
    // Co-located constructors (props and handlers at the declaration
    // site) and result-builder containers, so the build closure is the
    // scene's shape. Everything lowers eagerly to the same records —
    // the builder block runs like any closure, children first, then
    // the container and its addChilds. Sugar over the record calls,
    // never a scene value interpreted later.

    /// `role:` is this button's semantic emphasis — `.destructive` or
    /// `.prominent`, the two that fit an action. It changes what the
    /// press MEANS to the platform and to assistive tech, never what
    /// `onClick:` does.
    func button(
        _ text: String? = nil, role: KayaRole? = nil,
        onClick: ((KayaAppTx) throws -> Void)? = nil,
        grow: Double? = nil
    ) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_BUTTON))
        if let text { setText(w, text) }
        if let role { setRole(w, role) }
        if let onClick { app.onClick(w, onClick) }
        if let grow { setGrow(w, grow) }
        return w
    }

    func entry(
        onChange: ((KayaAppTx, String) throws -> Void)? = nil, grow: Double? = nil
    ) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_ENTRY))
        if let onChange { app.onChange(w, onChange) }
        if let grow { setGrow(w, grow) }
        return w
    }

    /// A multi-line text editor: the entry's uncontrolled contract
    /// over the platform's real multi-line editor.
    func textarea(
        onChange: ((KayaAppTx, String) throws -> Void)? = nil,
        grow: Double? = nil
    ) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_TEXTAREA))
        if let onChange { app.onChange(w, onChange) }
        if let grow { setGrow(w, grow) }
        return w
    }

    /// `role:` is this label's place in the text hierarchy — `.heading`
    /// is the one that fits a label, and it is a semantic fact (the
    /// platform's heading style AND the trait assistive users skim by),
    /// not a font size.
    func label(
        _ text: String? = nil, bind: KayaSignal? = nil, role: KayaRole? = nil,
        grow: Double? = nil
    ) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_LABEL))
        if let text { setText(w, text) }
        if let bind { bindText(w, bind) }
        if let role { setRole(w, role) }
        if let grow { setGrow(w, grow) }
        return w
    }

    /// A progress bar: display-only, like label and image. value is
    /// the determinate fraction (0..=1); indeterminate: true switches
    /// to the platform's activity mode.
    func progress(
        value: Double = 0.0, indeterminate: Bool? = nil, grow: Double? = nil
    ) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_PROGRESS))
        tx.setValue(w.id, value)
        if let indeterminate { tx.setIndeterminate(w.id, indeterminate) }
        if let grow { setGrow(w, grow) }
        return w
    }

    /// A slider over min...max at value, with its change handler
    /// co-located. `bind` takes a float signal for the position
    /// instead of a constant — the programmatic write path (write
    /// fans out to the control; property writes never echo an
    /// occurrence, so a handler's own writes cannot loop back at
    /// it).
    func slider(
        min: Double = 0.0, max: Double = 1.0, value: Double = 0.0,
        bind: KayaSignal? = nil,
        onChange: ((KayaAppTx, Double) throws -> Void)? = nil,
        grow: Double? = nil
    ) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_SLIDER))
        tx.setMin(w.id, min)
        tx.setMax(w.id, max)
        if let bind {
            tx.bindValue(w.id, bind.id)
        } else {
            tx.setValue(w.id, value)
        }
        if let onChange { app.onValueChanged(w, onChange) }
        if let grow { setGrow(w, grow) }
        return w
    }

    /// A dropdown select over fixed options — each option becomes a
    /// label child (labels only, scene-checked) — at `selected`, the
    /// initial 0-based index (domain-checked at the root against the
    /// option count), with its pick handler co-located: `onSelect`
    /// receives each USER pick's new 0-based index (programmatic
    /// writes never echo) — the slider's uncontrolled contract.
    func select(
        _ options: [String], selected: Int = 0,
        onSelect: ((KayaAppTx, Int) throws -> Void)? = nil,
        grow: Double? = nil
    ) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_SELECT))
        app.childFrames.append(KayaApp.KayaFrame(template: false))
        for option in options {
            let o = widget(UInt32(KAYA_KIND_LABEL))
            setText(o, option)
        }
        let ids = app.childFrames.removeLast().ids
        for id in ids { tx.addChild(w.id, id) }
        tx.setValue(w.id, Double(selected))
        if let onSelect {
            app.onValueChanged(w) { tx, v in try onSelect(tx, Int(v)) }
        }
        if let grow { setGrow(w, grow) }
        return w
    }

    /// A radio group over fixed options — the choice contract
    /// (`select`) in its inline presentation: same option children,
    /// same 0-based `selected` index, same pick handler.
    func radio(
        _ options: [String], selected: Int = 0,
        onSelect: ((KayaAppTx, Int) throws -> Void)? = nil,
        grow: Double? = nil
    ) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_RADIO))
        app.childFrames.append(KayaApp.KayaFrame(template: false))
        for option in options {
            let o = widget(UInt32(KAYA_KIND_LABEL))
            setText(o, option)
        }
        let ids = app.childFrames.removeLast().ids
        for id in ids { tx.addChild(w.id, id) }
        tx.setValue(w.id, Double(selected))
        if let onSelect {
            app.onValueChanged(w) { tx, v in try onSelect(tx, Int(v)) }
        }
        if let grow { setGrow(w, grow) }
        return w
    }

    func checkbox(
        _ text: String? = nil, checked: Bool? = nil,
        onToggle: ((KayaAppTx, Bool) throws -> Void)? = nil,
        grow: Double? = nil
    ) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_CHECKBOX))
        if let text { setText(w, text) }
        if let checked { setChecked(w, checked) }
        if let onToggle { app.onToggle(w, onToggle) }
        if let grow { setGrow(w, grow) }
        return w
    }

    /// An image displaying encoded bytes (PNG, JPEG, ...): the toolkit
    /// decodes natively, and decode failure renders the placeholder,
    /// never a crash. `source` is the encoded bytes — one registration
    /// copy into core memory; the handle is consumed by the next
    /// submit, and the guest's bytes are free to drop the moment the
    /// call returns. `bind` is a Signal carrying a blob handle.
    func image(
        _ source: Data? = nil, bind: KayaSignal? = nil, grow: Double? = nil
    ) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_IMAGE))
        if let source { setSource(w, source) }
        if let bind { bindSource(w, bind) }
        if let grow { setGrow(w, grow) }
        return w
    }

    func column(
        grow: Double? = nil, spacing: Double? = nil, inset: Double? = nil,
        align: KayaAlign? = nil,
        @KayaChildren _ children: () -> Void
    ) -> KayaWidget {
        containerOf(
            UInt32(KAYA_KIND_COLUMN), children, grow: grow, spacing: spacing,
            inset: inset, align: align)
    }

    /// A vertical scroll viewport over EXACTLY ONE child (declare it
    /// in the builder; the scene rejects a second). Pass grow: so the
    /// enclosing track CONSTRAINS it — an unconstrained viewport hugs
    /// its content and nothing overflows.
    func scroll(
        grow: Double? = nil, @KayaChildren _ children: () -> Void
    ) -> KayaWidget {
        containerOf(
            UInt32(KAYA_KIND_SCROLL), children, grow: grow, spacing: nil,
            inset: nil, align: nil)
    }

    func row(
        grow: Double? = nil, spacing: Double? = nil, inset: Double? = nil,
        align: KayaAlign? = nil,
        @KayaChildren _ children: () -> Void
    ) -> KayaWidget {
        containerOf(
            UInt32(KAYA_KIND_ROW), children, grow: grow, spacing: spacing,
            inset: inset, align: align)
    }

    /// A grid laying its children out row-major into `columns`
    /// columns — each column takes its NATURAL width, aligned across
    /// rows (the thing nested rows cannot express); `spacing` is the
    /// inter-cell gap on both axes and `inset` the padding around the
    /// whole block.
    func grid(
        columns: Int, spacing: Double? = nil, inset: Double? = nil,
        grow: Double? = nil,
        @KayaChildren _ children: () -> Void
    ) -> KayaWidget {
        let parent = widget(UInt32(KAYA_KIND_GRID))
        tx.setColumns(parent.id, Double(columns))
        if let spacing { setSpacing(parent, spacing) }
        if let inset { setInset(parent, inset) }
        if let grow { setGrow(parent, grow) }
        app.childFrames.append(KayaApp.KayaFrame(template: false))
        children()
        let ids = app.childFrames.removeLast().ids
        for id in ids { tx.addChild(parent.id, id) }
        return parent
    }

    /// A spacer: PURE SUGAR for an empty grown column — it consumes
    /// the leftover main-axis space between its siblings.
    func spacer() -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_COLUMN))
        setGrow(w, 1.0)
        return w
    }

    private func containerOf(
        _ kind: UInt32, _ children: () -> Void, grow: Double? = nil, spacing: Double? = nil,
        inset: Double? = nil, align: KayaAlign? = nil
    ) -> KayaWidget {
        // Parent before children: statement-shaped construction is
        // parent-first in every language (expression trees are
        // children-first because arguments evaluate before the call) —
        // creation order is observable (column#N) and derivable from
        // the construction style, never per-language trivia.
        let parent = widget(kind)
        if let grow { setGrow(parent, grow) }
        // spacing was accepted-but-dropped here for one commit — the
        // fills observation could not see it (render and observation
        // share the node state, so a write the WIRE never carried
        // stays self-consistent); the recordings are the gate for
        // that class until per-binding emission checks exist.
        if let spacing { setSpacing(parent, spacing) }
        if let inset { setInset(parent, inset) }
        if let align { setAlign(parent, align) }
        app.childFrames.append(KayaApp.KayaFrame(template: false))
        children()
        let ids = app.childFrames.removeLast().ids
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
        // A scalar collection's element IS its one wire value, so the
        // undo decoder is the identity (see registerDecoder).
        app.registerDecoder(c.id) { _, values in values[0] }
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
        app.parentAtCreation(live: w.id)
        app.openFors.append(c.id)
        app.tplDepth += 1
        defer { app.tplDepth -= 1 }
        let out = app.inTemplateBody { body(KayaTpl(tx: self)) }
        app.openFors.removeLast()
        tx.templateEnd()
        return (w, out)
    }

    /// A When over a Bool signal: stamps on true, unstamps on false.
    func when<R>(_ s: KayaSignal, _ body: (KayaTpl) -> R) -> (KayaWidget, R) {
        let w = app.nextWidget()
        tx.createWhen(w.id, s.id)
        app.parentAtCreation(live: w.id)
        app.tplDepth += 1
        defer { app.tplDepth -= 1 }
        let out = app.inTemplateBody { body(KayaTpl(tx: self)) }
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

    /// A scalar collection's element IS its one wire value, so this is
    /// the record path with a one-field record — spelled as a delegation
    /// rather than a copy so that EVERY insert this binding can make,
    /// scalar or typed, passes the one chokepoint the minter absorbs at.
    func insert(_ c: KayaCollection, _ key: KayaValue, _ value: KayaValue) {
        insertRecordRaw(c, key, value, 0, [value])
    }

    /// Insert a scalar under a key the binding authors, and hand the key
    /// back.
    ///
    /// FOR DATA THAT HAS NO IDENTITY OF ITS OWN. Keys are domain
    /// identity and guest-chosen (DESIGN.md, the update algebra), so
    /// anything that already HAS a name passes it to `insert` — today
    /// and always. This is the other case, and it is the common one in a
    /// form: the app has a title and nothing else, and the alternative
    /// is a hand-spelled counter beside the collection, which is mutable
    /// global state in most languages and whose safety rests on a
    /// never-rewind rule nobody wrote down.
    ///
    /// ONE COUNTER PER COLLECTION INSTANCE, starting at 0; the minted
    /// key is `.i64` and is counter+1. An instance is a table — the
    /// live-zone collection, or one stamped copy selected by `at(...)`
    /// — and keys are unique within one, so that is what the counter is
    /// per.
    ///
    /// MIXING IS SAFE BY ABSORPTION: an explicit `insert` whose key is
    /// an I64 at or above the counter carries it up, so a later mint
    /// clears every hand-chosen numeric key already in the table. A
    /// non-numeric key cannot collide with an I64 at all and moves
    /// nothing.
    ///
    /// NO DECREMENT IS EXPRESSIBLE, and that is the whole safety
    /// argument. Undo and redo replay captured keys inside the core and
    /// never re-enter this path, so a history walk never moves the
    /// counter; an abandoned transaction does not move it back either
    /// (the rollback journal restores the model, not the counter, so a
    /// key can never be handed out twice). A fresh key is fresh forever.
    ///
    /// The key IS the return value — an app that selects the row it just
    /// made takes it from here rather than inventing a second name for
    /// the same datum — and `@discardableResult` is Swift's spelling of
    /// "and an app that has no use for it simply does not read it".
    @discardableResult
    func insertFresh(_ c: KayaCollection, _ value: KayaValue) -> Int64 {
        insertRecordFresh(c, value, 0, [value])
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

    /// The record-time mirror-read guard: a template body records once
    /// and the core replays it — a model read inside one bakes this
    /// moment's data into every future stamp, silently dead. Live-zone,
    /// handler-tx, and build-tx reads stay legal.
    private func guardMirrorRead() {
        precondition(
            app.tplDepth == 0,
            "kaya: model read inside a template body — the template records once and replays; "
                + "bind a signal, use the element's field, or derive() for computed values")
    }

    /// The model: what this guest wrote, exactly — the fold of every
    /// patch so far (this transaction's included), in insertion order.
    func items(_ c: KayaCollection) -> [(key: KayaValue, value: KayaValue)] {
        guardMirrorRead()
        return app.instanceEntries(c.id, c.path).map {
            (key: $0.key, value: $0.value as! KayaValue)
        }
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
        // ABSORPTION, on the one path every explicit key travels — the
        // scalar `insert` and both typed surfaces come through here: a
        // numeric key at or above the minter's counter carries it up, so
        // hand-chosen and minted keys share one space safely and in
        // either order (insertFresh's contract).
        app.absorbKey(c.id, c.path, key)
        app.modelSet(c.id, c.path, key, model)
        tx.collectionInsert(c.id, c.path, key, variant, fields)
        recomputeDerived(c)
    }

    /// The minting insert every typed surface's `insertFresh` lowers to:
    /// take the instance's next key, insert under it, hand it back. The
    /// contract lives on `insertFresh` above.
    @discardableResult
    func insertRecordFresh(
        _ c: KayaCollection, _ model: Any, _ variant: UInt32, _ fields: [KayaValue]
    ) -> Int64 {
        let key = app.mintKey(c.id, c.path)
        insertRecordRaw(c, .i64(key), model, variant, fields)
        return key
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

    // The raw read every typed surface (KayaRecords items/get,
    // KayaSums items/get) funnels through — guarded here once.
    func recordEntries(_ c: KayaCollection) -> [(key: KayaValue, value: Any)] {
        guardMirrorRead()
        return app.instanceEntries(c.id, c.path)
    }

    func count(_ c: KayaCollection) -> Int {
        guardMirrorRead()
        return app.instanceEntries(c.id, c.path).count
    }

    /// Request a modal alert (the request/result grammar), named
    /// arguments as the Swift spelling:
    /// `tx.showAlert(title: "delete item?", message: "…",
    ///     actions: ["Delete", "Archive"], cancel: "Keep") { tx, choice in … }`.
    /// The result handler rides the REQUEST (the widget-handler
    /// precedent) and retires with its one answer — choice is an
    /// action index (0 or 1) or KAYA_ALERT_CHOICE_CANCEL, every
    /// platform-native dismissal. Ids are binding-allocated; the
    /// call returns the id for the floor-minded. Up to two actions
    /// (the platform floor — a third traps at construction, matching
    /// the scene gate); `cancel` is required by the signature, and
    /// no binding invents a default label. One alert may be live per
    /// process; show the next from the handler.
    @discardableResult
    func showAlert(
        title: String = "", message: String = "",
        actions: [String] = [], cancel: String, window: UInt64 = 0,
        onResult: ((KayaAppTx, UInt32) throws -> Void)? = nil
    ) -> UInt64 {
        precondition(
            actions.count <= 2,
            "kaya: an alert carries at most 2 actions (the platform floor)")
        precondition(
            !cancel.isEmpty,
            "kaya: the cancel slot always exists and needs a name")
        let id = app.allocAlert()
        if let onResult { app.onAlert(id, onResult) }
        tx.showAlert(
            window, id, UInt32(actions.count), .str(title), .str(message),
            .str(actions.count >= 1 ? actions[0] : ""),
            .str(actions.count == 2 ? actions[1] : ""), .str(cancel))
        return id
    }

    /// Ask the platform for files. THE PICK, NOT THE OPEN — the result
    /// carries handles you redeem later, so the name says `pick`
    /// (DESIGN.md, File dialogs).
    ///
    /// `filters` is advisory on every platform: a default view rather
    /// than a guarantee, so the guest still validates what it got. Each
    /// pair is (label, space-separated extensions).
    ///
    /// `onResult` fires exactly once and retires with its answer.
    /// CANCEL IS THE EMPTY LIST, faithfully: no platform can confirm an
    /// empty selection. One dialog may be live per process; show the
    /// next from the handler.
    @discardableResult
    func pickFiles(
        filters: [(String, String)] = [], window: UInt64 = 0,
        onResult: ((KayaAppTx, [KayaPickedFile]) throws -> Void)? = nil
    ) -> UInt64 {
        pick(multiple: true, filters: filters, window: window, onResult: onResult)
    }

    /// The single-file spelling. The floor always returns a LIST; this
    /// only asks the platform for one, so the handler receives zero or
    /// one file.
    @discardableResult
    func pickFile(
        filters: [(String, String)] = [], window: UInt64 = 0,
        onResult: ((KayaAppTx, [KayaPickedFile]) throws -> Void)? = nil
    ) -> UInt64 {
        pick(multiple: false, filters: filters, window: window, onResult: onResult)
    }

    private func pick(
        multiple: Bool, filters: [(String, String)], window: UInt64,
        onResult: ((KayaAppTx, [KayaPickedFile]) throws -> Void)?
    ) -> UInt64 {
        let id = app.allocFileDialog()
        if let onResult { app.onFileDialog(id, onResult) }
        tx.showFileDialog(window, id, multiple ? 1 : 0, kayaFilterValues(filters))
        return id
    }

    /// Ask the platform WHERE TO SAVE. The picker's twin: a request that
    /// answers once with a capability, on the same grammar, out of the
    /// same one-live-dialog slot — one dialog of either kind may be live
    /// per process, and the next is shown from this one's handler.
    ///
    /// `suggestedName` is the name the dialog OPENS with, and every
    /// platform treats it the way it treats a filter: it takes it, and
    /// guarantees nothing. The user renames it; Android may append an
    /// extension matching the mime type. READ THE NAME YOU GOT.
    ///
    /// WHAT YOU GET BACK OPENS EMPTY. A save destination may not exist
    /// yet (macOS, GTK and Windows answer with a name for a file nobody
    /// has made — measured), so the handle's open CREATES: opening it
    /// for `FILE_MODE_WRITE` succeeds and yields an empty file on every
    /// platform, which is the one behaviour a guest writes against
    /// (docs/save-plan.md D1).
    ///
    /// CANCEL IS `nil`. The narrowing from the wire's list is the
    /// BINDING's, not the guest's: "one locator or none" is a fact of
    /// the request, and no app should re-derive it from a length.
    @discardableResult
    func saveFile(
        suggestedName: String, filters: [(String, String)] = [], window: UInt64 = 0,
        onResult: ((KayaAppTx, KayaPickedFile?) throws -> Void)? = nil
    ) -> UInt64 {
        let id = app.allocFileDialog()
        if let onResult {
            // The save answer rides the picker's own result occurrence,
            // so it lands in the picker's own one-shot table and retires
            // there — one id space, one live slot, one retire gate.
            app.onFileDialog(id) { tx, files in try onResult(tx, files.first) }
        }
        tx.showSaveDialog(window, id, .str(suggestedName), kayaFilterValues(filters))
        return id
    }

    // --- The clipboard (DESIGN.md, Clipboard) ----------------------
    //
    // A clip is not a string: every host models it as ONE item
    // available in several types, with the consumer taking the richest
    // it understands. So COPY TAKES A RECORD — spelled as a chain here,
    // where a second text() simply replaces the field rather than
    // needing a duplicate check — and the two answers are a SUM.
    //
    // kaya DERIVES NOTHING between representations. Whether list
    // bullets survive html-to-text is the app's decision.

    /// Begin a clip: fill in as many representations as the app wants
    /// to offer, and send() puts it on the system clipboard.
    func copy() -> KayaCopyRef {
        KayaCopyRef(tx: self)
    }

    /// Begin the privileged read — THE ONE NAMED FOR WHAT IT IS rather
    /// than for pasting.
    ///
    /// A user's paste arrives at the widget's hook and costs nothing;
    /// this asks without a gesture, which the platforms have
    /// deliberately made expensive: iOS 16 PROMPTS when the content
    /// came from another app and blocks until the user answers, Android
    /// returns nothing unless the app has focus, and Wayland delivers
    /// no offer to an unfocused client. Reach for this to detect a URL
    /// or import from the clipboard, never to implement Paste — that is
    /// the Paste command, and it is free.
    func readClipboard() -> KayaClipReadRef {
        KayaClipReadRef(tx: self, id: app.allocClipboardRead())
    }

    /// Declare what a widget takes from a paste — the closed kinds by
    /// name ("text", "html", "image", "files") plus any custom format
    /// ids.
    ///
    /// ONE DECLARATION, THREE JOBS: it drives whether the Paste command
    /// is live while this widget is focused, it filters what can reach
    /// the paste hook, and on Android it IS the native registration
    /// (setOnReceiveContentListener takes the mime types on the view).
    /// Per-widget because whether Paste should be enabled is the
    /// INTERSECTION of what the clipboard offers and what the FOCUSED
    /// target takes.
    ///
    /// DECLARING IS HOW AN APP OVERRIDES THE DEFAULT. A widget that
    /// declares nothing gets the platform's own insertion and reports
    /// it through the ordinary change path, which is why a plain text
    /// editor writes none of this and has working cut, copy and paste.
    func setAccepts(_ w: KayaWidget, _ kinds: [String]) {
        tx.setAccepts(w.id, kayaAcceptList(kinds))
    }

    /// Take pasted content at a live widget.
    ///
    /// COSTS NOTHING ON ANY PLATFORM, unlike readClipboard: a paste is
    /// a user gesture, so it is its own authorisation — iOS raises no
    /// prompt and the focus rules are satisfied by construction. Only
    /// fires for a widget that declared what it accepts.
    func onPaste(
        _ w: KayaWidget,
        _ handler: @escaping (KayaAppTx, KayaRepresentation) throws -> Void
    ) {
        app.onPaste(w, handler)
    }

    /// A paste onto a stamped copy: the handler also receives the
    /// copy's key path, outermost first. One record kind, the path
    /// deciding — exactly as a click on a stamped row is one record
    /// with a click on a live widget.
    ///
    /// AND ONLY FIRES FOR A COPY WHOSE TEMPLATE DECLARED WHAT IT TAKES
    /// (`KayaTpl.setAccepts`), which is the same rule the live overload
    /// above states and was the reason this one was dead: until that
    /// setter existed, registering here compiled and waited forever,
    /// because every backend hands a paste to the platform's own
    /// insertion when the target's accept list is empty.
    func onPaste(
        _ n: KayaNodeHandle,
        _ handler: @escaping (KayaAppTx, [KayaValue], KayaRepresentation) throws -> Void
    ) {
        app.onPaste(n, handler)
    }

    /// REQUEST the app's brand accent (docs/styling-plan.md D1/D2):
    /// one packed sRGB hex (0xRRGGBB) is the whole call for most apps.
    /// `light:`/`dark:` are the per-appearance overrides a brand book
    /// with a stated dark variant needs; whichever you leave out is
    /// filled from `seed`. One name for both forms is the Swift
    /// spelling — the same defaulted-argument shape the window
    /// construct uses.
    ///
    /// SET ONCE, BEFORE THE FIRST MOUNT: brand is identity, not state,
    /// and the root refuses a second write and a late one.
    ///
    /// You never write a foreground and never write contrast variants.
    /// The core derives fill, on-fill, standalone and the hover/pressed
    /// ramp per appearance and hands every backend values — a pair an
    /// app supplied could be illegible with nothing to catch it, and
    /// three of the four platforms hard-code or compute the foreground
    /// anyway.
    ///
    /// AND IT IS A REQUEST: a platform may let its user override the
    /// app's accent. macOS does today — an app accent applies only
    /// while the system accent is multicolor — and the semantics does
    /// not change if another platform grows the preference.
    ///
    /// NO PER-PLATFORM VALUE MAP HERE, and the same absence in every
    /// binding: D1's grammar allows one, the reference sugar does not
    /// spell it, and a surface one language has is the divergence
    /// invariant 1 refuses. Swift is the tempting place — one source
    /// serves macOS and iOS — which is exactly why the answer is a
    /// `perPlatform:` label resolved inside THIS function if it is ever
    /// admitted, never `#if os(...)` in a guest.
    func brandAccent(_ seed: UInt32, light: UInt32? = nil, dark: UInt32? = nil) {
        // The mask is what tells the core "unstated" from "0x000000":
        // black is a legal accent, so absence cannot be encoded as a
        // zero value.
        var mask: UInt32 = 0
        if light != nil { mask |= 1 }
        if dark != nil { mask |= 2 }
        tx.setBrandAccent(seed, mask, light ?? 0, dark ?? 0)
    }

    /// REQUEST the app's brand typeface (docs/styling-plan.md Slice 2b):
    /// one family name is the whole call, and every platform that has
    /// that family installed uses it. One name covers the plain and the
    /// per-platform forms, the defaulted-argument shape `brandAccent`
    /// and the window construct already use.
    ///
    /// THE FAMILY, NEVER THE SCALE (ratified DESIGN.md): sizes, weights,
    /// metrics and the whole type ramp stay the platform's. There is
    /// nowhere here to put a size, deliberately — emphasis is the role
    /// tier's job (`role: .heading`), and that is what makes a family
    /// swap safe.
    ///
    /// SET ONCE, BEFORE THE FIRST MOUNT: the accent's wall verbatim, and
    /// for its reason — a slot that could flip at runtime would promise
    /// the theme-switching surface the vocabulary deliberately lacks.
    ///
    /// `platforms:` overrides that default for the platforms that name
    /// themselves — `[.mac: "Georgia", .linux: "DejaVu Serif"]` — and
    /// THE PAIRS TRAVEL UNRESOLVED, unlike the accent's per-appearance
    /// values. That asymmetry is the design: this binding cannot know
    /// which platform it is running on, but every LOWERING is one, so
    /// each backend picks its own row out of the list. It is
    /// `KeyValuePairs` rather than a `Dictionary` for two measured
    /// reasons: a Dictionary is unordered, so the same guest would write
    /// different bytes on different runs, and it would swallow a
    /// repeated platform in Swift's own words, where the root refuses it
    /// in kaya's — the sentence the other seven bindings print.
    ///
    /// `font:` ships a FONT FILE's bytes on the blob channel,
    /// register-then-resolve: the backend hands them to its platform's
    /// app-font API, reads back the family that registration named, and
    /// prefers it to any name above. The bytes are copied out at the
    /// call, so the `Data` is yours again the moment this returns.
    ///
    /// A FAMILY A PLATFORM DOES NOT HAVE leaves that platform's own
    /// typeface in place, deliberately and silently: every font API
    /// renders SOMETHING for a name it cannot match (Apple's falls
    /// through to Helvetica — measured), so each lowering gates on the
    /// family being installed rather than letting the platform pick a
    /// stranger. An app that wants the system typeface declares none at
    /// all, which is also the only way to ask for it: `SF Pro` and `New
    /// York` are not reachable by family name.
    func brandTypeface(
        _ family: String,
        platforms: KeyValuePairs<KayaPlatform, String> = [:],
        font: Data? = nil
    ) {
        // Flat pairs — the file dialog's filter encoding one tier over:
        // the platform tag, then that platform's family, read in twos by
        // the root, which is also where an odd count or a tag outside
        // the vocabulary dies.
        var pairs: [KayaValue] = []
        for (platform, name) in platforms {
            pairs.append(.i64(platform.rawValue))
            pairs.append(.str(name))
        }
        // The font SLOT rides either way and the mask is what says
        // whether it means anything — the accent mask's discipline, and
        // the reason this record's field count never varies with the
        // payload.
        tx.setBrandTypeface(
            font == nil ? 0 : 1, .str(family), pairs,
            font.map { .blob(kayaRegisterBlob($0)) } ?? .str(""))
    }

    /// Create an auxiliary window (capability-gated: phone hosts
    /// reject at the root); materializes hidden, mountIn presents.
    /// Named arguments are the Swift spelling.
    /// The handlers ride the declaration (per-window — handlers
    /// scope to the thing that creates them): onCloseRequested fires
    /// per chrome close while vetoClose is armed — nothing has
    /// closed; answer with tx.destroyWindow to agree. onClosed fires
    /// when the non-veto auxiliary is chrome-closed (informational;
    /// destroyWindow reconciles) and retires with it.
    func createWindow(
        _ id: UInt64, title: String? = nil, width: Double? = nil,
        height: Double? = nil, vetoClose: Bool? = nil, dirty: Bool? = nil,
        listDetail: Bool? = nil, sectionsPresentation: Int64? = nil,
        inset: Double? = nil,
        onCloseRequested: ((KayaAppTx) throws -> Void)? = nil,
        onClosed: ((KayaAppTx) throws -> Void)? = nil,
        onUndone: ((KayaAppTx, String, KayaUndoDelta) throws -> Void)? = nil,
        onRedone: ((KayaAppTx, String, KayaUndoDelta) throws -> Void)? = nil,
        menus: [KayaMenuItem]? = nil
    ) {
        tx.createWindow(id)
        window(
            id, title: title, width: width, height: height,
            vetoClose: vetoClose, dirty: dirty, listDetail: listDetail,
            sectionsPresentation: sectionsPresentation, inset: inset,
            onCloseRequested: onCloseRequested, onClosed: onClosed,
            onUndone: onUndone, onRedone: onRedone,
            menus: menus)
    }

    /// Set a window's attributes in one construct — the attribute set
    /// is EXACTLY createWindow's (a window's attributes ride its
    /// window construct; the primary differs only in having no
    /// creation moment — the process owns it):
    /// tx.window(title: "sections", sectionsPresentation:
    /// Int64(KAYA_SECTIONS_PRESENTATION_BAR)).
    ///
    /// `dirty:` says this surface holds UNSAVED WORK, and the backend
    /// shows its platform's own affordance — the dot in the close
    /// button on macOS, a leading `*` in the rendered caption on
    /// Windows, a bullet beside the header-bar title on GTK, nothing on
    /// the phones, which have none (docs/dirty-plan.md D2/D4).
    ///
    /// STATE, NOT CHROME, and the `title:` you declared is left alone:
    /// there is no marker to compose into it and no placeholder to
    /// leave room for (the rejected Qt design). It ARMS NOTHING either
    /// — "unsaved changes, close anyway?" is `vetoClose:` plus a
    /// dialog, which is yours to compose, because apps legitimately
    /// differ on what it should do.
    ///
    /// `inset:` is this window's CONTENT INSET in layout units — LAYOUT,
    /// not appearance (docs/styling-plan.md D3): the space kaya's own
    /// interpreter puts around the mounted root. 16 unless you say
    /// otherwise; 0 is full bleed (an editor, a canvas), honored
    /// unconditionally because the inset is kaya's own padding and
    /// nothing platform-side defends it. A platform's SAFE AREA is a
    /// separate fact and is not removed by it: on iPhone the content
    /// reaches the safe-area edge, not past it.
    func window(
        _ id: UInt64 = 0, title: String? = nil, width: Double? = nil,
        height: Double? = nil, vetoClose: Bool? = nil, dirty: Bool? = nil,
        listDetail: Bool? = nil, sectionsPresentation: Int64? = nil,
        inset: Double? = nil,
        onCloseRequested: ((KayaAppTx) throws -> Void)? = nil,
        onClosed: ((KayaAppTx) throws -> Void)? = nil,
        onUndone: ((KayaAppTx, String, KayaUndoDelta) throws -> Void)? = nil,
        onRedone: ((KayaAppTx, String, KayaUndoDelta) throws -> Void)? = nil,
        menus: [KayaMenuItem]? = nil
    ) {
        if let title { tx.setWindowTitle(id, title) }
        if let width { tx.setWindowWidth(id, width) }
        if let height { tx.setWindowHeight(id, height) }
        if let vetoClose { tx.setWindowVetoClose(id, vetoClose) }
        if let dirty { tx.setWindowDirty(id, dirty) }
        if let listDetail { tx.setWindowListDetail(id, listDetail) }
        if let sectionsPresentation {
            tx.setWindowSectionsPresentation(id, sectionsPresentation)
        }
        if let inset { tx.setWindowInset(id, inset) }
        if let onCloseRequested { app.onCloseRequested(id, onCloseRequested) }
        if let onClosed { app.onWindowClosed(id, onClosed) }
        // The history handlers ride the window construct because the
        // LEDGER is per window: one ordered history per surface, so the
        // registration scopes to the thing that owns it. Persistent —
        // a history is walked as often as the user likes.
        if let onUndone { app.onUndone(id, onUndone) }
        if let onRedone { app.onRedone(id, onRedone) }
        // The menubar rides the window construct (the window-attribute
        // unification rule): menus: appends top-level grouping nodes
        // (menu or radioGroup) to this window's command catalog, in
        // order — append-only, at any time.
        if let menus {
            for m in menus { tx.menubarAppend(id, m.id) }
        }
    }

    // --- Menus: the command vocabulary (DESIGN.md, Menus) ------------
    //
    // Named-args constructors nested by argument lists: children are
    // arguments (evaluated first, unanchored), the grouping construct
    // appends them, and the window construct's menus: parameter is the
    // bar anchor. Items are live-zone only; a retained item reopens
    // through tx.menu(item, ...) — the append-at-any-time discipline.

    private func newMenuItem(_ kind: Int32, _ label: KayaMenuText?) -> KayaMenuItem {
        precondition(
            app.tplDepth == 0,
            "kaya: menu items are live — build the context catalog in the live "
                + "zone (tx.contextCatalog) and attach it inside the template "
                + "with KayaTpl.contextMenu")
        let m = app.nextMenuItem()
        tx.menuItemCreate(m.id, UInt32(kind))
        if let label { menuLabel(m, label) }
        return m
    }

    private func menuLabel(_ m: KayaMenuItem, _ src: KayaMenuText) {
        if let s = src as? KayaSignal {
            tx.bindMenuLabel(m.id, s.id)
        } else {
            tx.setMenuLabel(m.id, src as! String)
        }
    }

    private func menuEnabled(_ m: KayaMenuItem, _ src: KayaMenuBool) {
        if let s = src as? KayaSignal {
            tx.bindMenuEnabled(m.id, s.id)
        } else {
            tx.setMenuEnabled(m.id, src as! Bool)
        }
    }

    private func menuChecked(_ m: KayaMenuItem, _ src: KayaMenuBool) {
        if let s = src as? KayaSignal {
            tx.bindMenuChecked(m.id, s.id)
        } else {
            tx.setMenuChecked(m.id, src as! Bool)
        }
    }

    private func menuValue(_ m: KayaMenuItem, _ src: KayaMenuIndex) {
        if let s = src as? KayaSignal {
            tx.bindMenuValue(m.id, s.id)
        } else if let i = src as? Int {
            tx.setMenuValue(m.id, Double(i))
        } else {
            tx.setMenuValue(m.id, src as! Double)
        }
    }

    /// The tail every menu-item CONSTRUCTOR shares. The symbol arrives
    /// here rather than in each constructor's own body ON PURPOSE: it is
    /// a REQUIRED positional, so a constructor added later cannot reach
    /// the tail without deciding about the slot — the same reason
    /// `enabled` and `icon` already sit here.
    ///
    /// Two kinds are deliberately outside it, exactly as they are for
    /// `icon`: `separator()`, which takes no props at all (the root
    /// refuses a symbol on a separator), and the REOPENING
    /// `menu(_ item:…)`, which mutates each prop it was handed and has
    /// no create to share.
    private func menuTail(
        _ m: KayaMenuItem, _ enabled: KayaMenuBool?, _ icon: Data?, _ symbol: KayaSymbol?
    ) {
        if let enabled { menuEnabled(m, enabled) }
        if let icon { tx.setMenuIcon(m.id, kayaRegisterBlob(icon)) }
        if let symbol { tx.setMenuSymbol(m.id, symbol.rawValue) }
    }

    /// The closed standard-command vocabulary (DESIGN.md, Menus):
    /// macOS places this one in the application menu, and every other
    /// host leaves the item where the app declared it.
    // A NAMED VOCABULARY FOR THE CLOSED HALF, exactly as the menu roles
    // are. The accept list is open-ended — a custom format id is any
    // app-chosen string — so the four closed kinds cannot be a mask; but
    // they can be spelled once here instead of quoted at every call site.
    // A MISTYPED BARE STRING IS SILENT: it becomes a custom format id no
    // clipboard will ever offer, so Paste stays dead and the paste hook
    // never fires, with nothing to see anywhere. A custom id has no
    // constant by nature — the app that defines it names it.
    static let acceptText = "text"
    static let acceptHtml = "html"
    static let acceptImage = "image"
    static let acceptFiles = "files"

    static let roleSettings = "settings"

    /// The three clipboard commands. They lower to the platform's own,
    /// act on the FOCUSED widget, and work out their own enablement
    /// from what the clipboard offers and what that widget accepts.
    ///
    /// GESTURES ARE COMMANDS BECAUSE KAYA HAS NO SELECTION API: only
    /// the widget knows what is selected, so an app cannot assemble the
    /// payload for "copy the selected text" out of the data layer. Copy
    /// of a selection is therefore necessarily a command, and Paste is
    /// its mirror. copy() and readClipboard() are for overriding that
    /// default and for targets with no native behaviour.
    static let roleCut = "cut"
    static let roleCopy = "copy"
    static let rolePaste = "paste"

    /// The two history commands, and the same gesture layer one tier
    /// deeper (docs/undo-plan.md D6). They ask the FOCUSED widget
    /// first — a text field whose own edit history has something to
    /// give answers before the app's ledger does, which is what an
    /// editor user expects: mid-typing, Undo means the typing; after a
    /// structural action, Undo means the action. Enablement is that
    /// same question, computed live at activation.
    ///
    /// AN APP OPTS IN TO THE OTHER TIER BY NAMING ITS STEPS
    /// (tx.undoable) and hears the result as the window construct's
    /// onUndone. An app that names none still gets working text undo
    /// from these items, because the first tier is the platform's.
    static let roleUndo = "undo"
    static let roleRedo = "redo"

    /// An action — a leaf command firing exactly one menu_activated
    /// occurrence (menu click OR its shortcut: ONE occurrence, one
    /// dispatch path; the handler rides the declaration and covers
    /// both). The shortcut is canonicalized by the binding's one
    /// parser; the root judges its anchor (window catalogs only).
    ///
    /// `symbol:` is the item's SEMANTIC ICON — a concept from the closed
    /// [KayaSymbol] vocabulary that each backend draws in its own
    /// platform's symbol set. It sits BESIDE `icon:`, not instead of it:
    /// a name for the standard concepts, a blob for app-specific art.
    /// Both are const-only. Every item constructor below takes it on the
    /// same terms.
    func item(
        _ label: KayaMenuText, shortcut: String? = nil,
        enabled: KayaMenuBool? = nil, icon: Data? = nil,
        symbol: KayaSymbol? = nil, primary: Bool = false,
        role: String? = nil,
        onActivate: ((KayaAppTx) throws -> Void)? = nil
    ) -> KayaMenuItem {
        let m = newMenuItem(KAYA_MENU_KIND_ACTION, label)
        if let shortcut { tx.setMenuShortcut(m.id, shortcut) }
        if let role { tx.setMenuRole(m.id, role) }
        menuTail(m, enabled, icon, symbol)
        if primary { tx.setMenuPrimary(m.id, true) }
        if let onActivate { app.menuActivated[m.id] = onActivate }
        return m
    }

    /// The template-node flavor: an item attached to a stamped copy
    /// (tx.contextCatalog + KayaTpl.contextMenu) reports the copy's
    /// key path, outermost first — the keys ARE the noun the command
    /// acts on. Context items take no shortcuts (root-checked).
    func item(
        _ label: KayaMenuText, enabled: KayaMenuBool? = nil, icon: Data? = nil,
        symbol: KayaSymbol? = nil,
        onActivate: @escaping (KayaAppTx, [KayaValue]) throws -> Void
    ) -> KayaMenuItem {
        let m = newMenuItem(KAYA_MENU_KIND_ACTION, label)
        menuTail(m, enabled, icon, symbol)
        app.menuActivatedNode[m.id] = onActivate
        return m
    }

    /// A toggle — a stateful leaf reusing the Checkbox contract: user
    /// flips emit menu_toggled (the handler receives the new state);
    /// programmatic checked writes are QUIET (the echo doctrine).
    func toggle(
        _ label: KayaMenuText, checked: KayaMenuBool? = nil,
        enabled: KayaMenuBool? = nil, icon: Data? = nil,
        symbol: KayaSymbol? = nil, shortcut: String? = nil,
        onToggle: ((KayaAppTx, Bool) throws -> Void)? = nil
    ) -> KayaMenuItem {
        let m = newMenuItem(KAYA_MENU_KIND_TOGGLE, label)
        if let checked { menuChecked(m, checked) }
        if let shortcut { tx.setMenuShortcut(m.id, shortcut) }
        menuTail(m, enabled, icon, symbol)
        if let onToggle { app.menuToggled[m.id] = onToggle }
        return m
    }

    /// The template-node flavor of toggle: the copy's keys, then the
    /// new state.
    func toggle(
        _ label: KayaMenuText, checked: KayaMenuBool? = nil,
        enabled: KayaMenuBool? = nil, icon: Data? = nil,
        symbol: KayaSymbol? = nil,
        onToggle: @escaping (KayaAppTx, [KayaValue], Bool) throws -> Void
    ) -> KayaMenuItem {
        let m = newMenuItem(KAYA_MENU_KIND_TOGGLE, label)
        if let checked { menuChecked(m, checked) }
        menuTail(m, enabled, icon, symbol)
        app.menuToggledNode[m.id] = onToggle
        return m
    }

    /// One labeled radio option, appended in declaration order — the
    /// order IS the index vocabulary the group's value selects over.
    func option(
        _ label: KayaMenuText, enabled: KayaMenuBool? = nil, icon: Data? = nil,
        symbol: KayaSymbol? = nil, shortcut: String? = nil
    ) -> KayaMenuItem {
        let m = newMenuItem(KAYA_MENU_KIND_RADIO_OPTION, label)
        if let shortcut { tx.setMenuShortcut(m.id, shortcut) }
        menuTail(m, enabled, icon, symbol)
        return m
    }

    /// Native grouping chrome: no label, no props, no handler.
    func separator() -> KayaMenuItem {
        newMenuItem(KAYA_MENU_KIND_SEPARATOR, nil)
    }

    /// A menu grouping node — at bar level (seat it through the window
    /// construct's menus: parameter) or nested (pass it in a parent's
    /// items:). Children arrive as arguments, already created; the
    /// menu appends them in order. Disabling a menu disables its
    /// subtree (the inherited-disabled contract).
    func menu(
        _ label: KayaMenuText, enabled: KayaMenuBool? = nil, icon: Data? = nil,
        symbol: KayaSymbol? = nil, items: [KayaMenuItem] = []
    ) -> KayaMenuItem {
        let m = newMenuItem(KAYA_MENU_KIND_MENU, label)
        for child in items { tx.menuItemAppend(m.id, child.id) }
        menuTail(m, enabled, icon, symbol)
        return m
    }

    /// Reopen a RETAINED menu item — the append-at-any-time
    /// discipline: tx.menu(file, label: "Document", items: [publish]).
    /// Props mutate freely on every kind the prop applies to (the root
    /// judges kind and anchor rules); programmatic checked/value
    /// writes are configuration and stay QUIET.
    func menu(
        _ item: KayaMenuItem, label: KayaMenuText? = nil,
        enabled: KayaMenuBool? = nil, checked: KayaMenuBool? = nil,
        value: KayaMenuIndex? = nil, icon: Data? = nil,
        symbol: KayaSymbol? = nil, primary: Bool? = nil,
        shortcut: String? = nil, role: String? = nil, items: [KayaMenuItem] = []
    ) {
        for child in items { tx.menuItemAppend(item.id, child.id) }
        if let label { menuLabel(item, label) }
        if let enabled { menuEnabled(item, enabled) }
        if let checked { menuChecked(item, checked) }
        if let value { menuValue(item, value) }
        if let icon { tx.setMenuIcon(item.id, kayaRegisterBlob(icon)) }
        if let symbol { tx.setMenuSymbol(item.id, symbol.rawValue) }
        if let primary { tx.setMenuPrimary(item.id, primary) }
        if let shortcut { tx.setMenuShortcut(item.id, shortcut) }
        if let role { tx.setMenuRole(item.id, role) }
    }

    /// A radio group — the Choice contract with the platform's
    /// checkmark idiom, admissible wherever a menu grouping node is
    /// (bar level via the window construct, nested via a parent's
    /// items:). options: only option children (the closed grammar,
    /// root-checked); value is the selected 0-based index
    /// (programmatic writes are quiet); onSelect receives each USER
    /// pick's new index.
    func radioGroup(
        _ label: KayaMenuText, options: [KayaMenuItem],
        value: KayaMenuIndex? = nil, enabled: KayaMenuBool? = nil,
        icon: Data? = nil, symbol: KayaSymbol? = nil,
        onSelect: ((KayaAppTx, Int) throws -> Void)? = nil
    ) -> KayaMenuItem {
        let m = newMenuItem(KAYA_MENU_KIND_RADIO_GROUP, label)
        for child in options { tx.menuItemAppend(m.id, child.id) }
        if let value { menuValue(m, value) }
        menuTail(m, enabled, icon, symbol)
        if let onSelect { app.menuSelected[m.id] = onSelect }
        return m
    }

    /// The template-node flavor of radioGroup: the copy's keys, then
    /// the new index.
    func radioGroup(
        _ label: KayaMenuText, options: [KayaMenuItem],
        value: KayaMenuIndex? = nil, enabled: KayaMenuBool? = nil,
        icon: Data? = nil, symbol: KayaSymbol? = nil,
        onSelect: @escaping (KayaAppTx, [KayaValue], Int) throws -> Void
    ) -> KayaMenuItem {
        let m = newMenuItem(KAYA_MENU_KIND_RADIO_GROUP, label)
        for child in options { tx.menuItemAppend(m.id, child.id) }
        if let value { menuValue(m, value) }
        menuTail(m, enabled, icon, symbol)
        app.menuSelectedNode[m.id] = onSelect
        return m
    }

    /// A context menu on a LIVE widget: the same item vocabulary
    /// scoped to a NOUN, with the platform's own gesture (right-click,
    /// long-press). Calling it again appends more roots. The editable
    /// text controls (entry, textarea) reject attachment at the root;
    /// context items take no shortcuts.
    func contextMenu(_ target: KayaWidget, items: [KayaMenuItem]) {
        for item in items { tx.contextAttach(target.id, item.id) }
    }

    /// Build a context catalog UNANCHORED — free root items for a
    /// template-node anchor (menu items are live and shared across
    /// stamped copies): KayaTpl.contextMenu attaches it inside the
    /// template, and each activation carries the copy's key path.
    func contextCatalog(items: [KayaMenuItem]) -> KayaContextCatalog {
        KayaContextCatalog(items)
    }

    /// Close and forget an auxiliary window — also the veto grammar's
    /// confirmation and the reconciliation after a chrome close.
    func destroyWindow(_ id: UInt64) {
        tx.destroyWindow(id)
    }

    /// Push a navigation entry onto the primary surface's stack
    /// (entry ids are guest-allocated in the shared surface
    /// namespace, the createWindow discipline); materializes covered,
    /// mountIn presents it. Named arguments are the Swift spelling:
    /// tx.pushEntry(7, title: "detail", interceptBack: true).
    /// The handlers ride the push (per-entry, the showAlert onResult
    /// precedent — no id inspection anywhere): onPopped fires when
    /// the user's back affordance pops THIS entry natively
    /// (post-fact; a programmatic popEntry does not fire it — its
    /// caller already knows) and retires with the one pop;
    /// onBackRequested fires per back request while interceptBack is
    /// armed — nothing has popped; answer with tx.popEntry to agree.
    func pushEntry(
        _ id: UInt64, title: String? = nil, interceptBack: Bool? = nil,
        onPopped: ((KayaAppTx) throws -> Void)? = nil,
        onBackRequested: ((KayaAppTx) throws -> Void)? = nil,
        window: UInt64 = 0
    ) {
        tx.pushEntry(window, id)
        if let title { tx.setEntryTitle(id, title) }
        if let interceptBack { tx.setEntryInterceptBack(id, interceptBack) }
        if let onPopped { app.onEntryPopped(id, onPopped) }
        if let onBackRequested { app.onBackRequested(id, onBackRequested) }
    }

    /// Pop the window's top navigation entry and forget its tree —
    /// also the back-veto grammar's confirmation after
    /// onBackRequested. Popping an empty stack is a scene error.
    func popEntry(window: UInt64 = 0) {
        tx.popEntry(window)
    }

    /// Append a section to the window's section set (section ids are
    /// guest-allocated in the shared surface namespace); the set is
    /// append-only — sections have no destruction grammar, and every
    /// section's root is retained while covered (switching is
    /// SELECTION, not lifecycle). mountIn fills its pane. Named
    /// arguments are the Swift spelling:
    /// tx.addSection(7, title: "Feed", onSelected: { tx in … }).
    /// onSelected rides the add (per-section): fires each time the
    /// USER switches to it — post-fact and NOT one-shot; a
    /// programmatic selectSection does not fire it (the echo
    /// doctrine).
    ///
    /// `symbol:` is the switcher item's SEMANTIC ICON — a concept from
    /// the closed [KayaSymbol] vocabulary each backend draws in its own
    /// platform's symbol set. A tab bar without icons is not the
    /// platform's real thing, and a blob is the wrong primitive for a
    /// STANDARD one. It sits beside the section's blob `icon` slot, for
    /// app-specific art — which this construct has never spelled in any
    /// binding but Rust's; `KayaWire.setSectionIcon` is the floor until
    /// one of them grows the sugar.
    func addSection(
        _ id: UInt64, title: String? = nil, symbol: KayaSymbol? = nil,
        onSelected: ((KayaAppTx) throws -> Void)? = nil,
        window: UInt64 = 0
    ) {
        tx.addSection(window, id)
        if let title { tx.setSectionTitle(id, title) }
        if let symbol { tx.setSectionSymbol(id, symbol.rawValue) }
        if let onSelected { app.onSectionSelected(id, onSelected) }
    }

    /// Select a section programmatically: configuration, never echoes
    /// onSelected (the echo doctrine).
    func selectSection(_ id: UInt64, window: UInt64 = 0) {
        tx.selectSection(window, id)
    }

    /// Mount a root into a specific window; mounting presents an
    /// auxiliary.
    func mountIn(_ window: UInt64, _ root: KayaWidget) {
        tx.mount(window, root.id)
    }

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
        defer { tx.app.parentAtCreation(node: n.id) }
        tx.tx.createWidget(n.id, kind)
        return n
    }

    /// The raw Text write on a node — PRIVATE, and that is the point.
    ///
    /// The live zone's `setText` is a WIDGET VERB the sugar sweep
    /// requires of every binding (tools/check-sugar-surface.sh's
    /// check_range_verb); this one is the floor spelling of a prop, and
    /// the only thing telling the two apart is the receiver's type,
    /// which no floor sweep can see. Rust never had the problem — it
    /// spells the floor `Tpl::set` and the verb `set_text`. Hiding is
    /// the sharper half of that split here: every caller is a
    /// constructor in this same class, no guest and no generated file
    /// has ever named it, so the floor spelling simply stops existing
    /// rather than moving to a name someone could still reach for
    /// (docs/tpl-props-plan.md F3).
    private func setText(_ n: KayaNodeHandle, _ text: String) {
        tx.tx.setText(n.id, text)
    }

    /// Bind text to the element of the enclosing For, `level` Fors up
    /// (0 = nearest).
    func bindTextElement(_ n: KayaNodeHandle, level: UInt32 = 0) {
        tx.tx.bindTextElement(n.id, level: level)
    }

    /// Weight a template node within its stamped row or column — the
    /// template twin of `KayaAppTx.setGrow`.
    ///
    /// It arrived a pass ahead of the a11y props below because `scroll`
    /// needs it: an unconstrained viewport hugs its content and nothing
    /// overflows, so a template scroll without a grow weight is a scroll
    /// that cannot scroll. Rust's `Tpl` has always been able to spell
    /// this through its generic `set(node, prop, value)`, so shipping
    /// the scroll constructor without it would have opened a divergence
    /// in the same pass that closed one (invariant 1).
    ///
    /// Spacing and align are what a node still cannot carry here. They
    /// are the container props, they have no Swift spelling in this zone
    /// at all — not even on `row`/`column`/`grid` — and they stay
    /// ledgered (docs/deferred.md).
    func setGrow(_ n: KayaNodeHandle, _ weight: Double) {
        tx.tx.setGrow(n.id, weight)
    }

    /// A stamped copy's accessibility IDENTIFIER — the template twin of
    /// `KayaAppTx.setA11yId`, and universal in this zone exactly as it
    /// is in that one: the template declare arm runs the same
    /// `check_prop` the live path does, and A11yId is admitted on every
    /// kind (crates/kaya/src/scene.rs).
    ///
    /// The argument's type picks the source, as it does for `label`. A
    /// String gives EVERY copy the same key, which is legal and often
    /// right — nothing in the core deduplicates ids and the harness
    /// addresses by kind#index, never by id — while the row's own field
    /// is the spelling when automation has to tell two copies apart.
    func setA11yId(_ n: KayaNodeHandle, _ id: String) {
        tx.tx.setA11yId(n.id, id)
    }

    func setA11yId(_ n: KayaNodeHandle, _ s: KayaSignal) {
        tx.tx.bindA11yId(n.id, s.id)
    }

    func setA11yId(_ n: KayaNodeHandle, level: UInt32 = 0, _ f: KayaField<String>) {
        tx.tx.bindA11yIdElement(n.id, level: level, field: f.index)
    }

    /// What an assistive client SPEAKS for a stamped copy — the template
    /// twin of `KayaAppTx.setA11yLabel`. Leave it unset to keep whatever
    /// the platform derives from the copy's own content.
    ///
    /// THE ROW'S OWN FIELD IS THE CASE THIS EXISTS FOR: it is the only
    /// one of the three sources that makes two copies say different
    /// things, so a list whose rows each announce their own name is one
    /// line. A String is right for a per-cell role ("delete") and wrong
    /// for a per-row identity; a signal makes every copy say the same
    /// changing thing.
    func setA11yLabel(_ n: KayaNodeHandle, _ label: String) {
        tx.tx.setA11yLabel(n.id, label)
    }

    func setA11yLabel(_ n: KayaNodeHandle, _ s: KayaSignal) {
        tx.tx.bindA11yLabel(n.id, s.id)
    }

    func setA11yLabel(_ n: KayaNodeHandle, level: UInt32 = 0, _ f: KayaField<String>) {
        tx.tx.bindA11yLabelElement(n.id, level: level, field: f.index)
    }

    /// What ACTIVATING a stamped copy does — the template twin of
    /// `KayaAppTx.setA11yHint`. Write a VERB PHRASE.
    ///
    /// Activation kinds only (button, checkbox, select, radio), and the
    /// restriction is the ROOT'S rather than this type's: a hint on a
    /// template label dies in `check_prop` at DECLARE time, before a
    /// single row stamps, in the same sentence the live zone gets.
    /// Walling it off in the type here — a kind parameter on
    /// `KayaNodeHandle` — would be the two zones diverging on one prop,
    /// which is the thing invariant 1 forbids.
    func setA11yHint(_ n: KayaNodeHandle, _ hint: String) {
        tx.tx.setA11yHint(n.id, hint)
    }

    func setA11yHint(_ n: KayaNodeHandle, _ s: KayaSignal) {
        tx.tx.bindA11yHint(n.id, s.id)
    }

    func setA11yHint(_ n: KayaNodeHandle, level: UInt32 = 0, _ f: KayaField<String>) {
        tx.tx.bindA11yHintElement(n.id, level: level, field: f.index)
    }

    /// Declare what a stamped copy takes from a paste — the template
    /// twin of `KayaAppTx.setAccepts`. Entry and textarea only; the root
    /// rejects it elsewhere, at declaration rather than per stamp.
    ///
    /// THIS IS WHAT MAKES A STAMPED PASTE HAPPEN AT ALL. Every backend
    /// gates the paste occurrence on the focused widget's accept list
    /// and falls back to the platform's own insertion when it is empty
    /// (swift/KayaSwiftUI.swift, `node.accepts.isEmpty`), so until this
    /// existed `onPaste(_ n: KayaNodeHandle, …)` registered a handler
    /// that compiled, registered and could never fire — silently, and in
    /// seven of the eight bindings (docs/tpl-props-plan.md §1).
    ///
    /// CONST ONLY, and that is parity rather than a cut: an accept list
    /// says what the PROTOTYPE can take, which is structure, and
    /// structure belongs to the blueprint — the rule the slider's
    /// min/max and the select's options already follow. No zone in any
    /// binding offers a dynamic spelling; on Android the list IS the
    /// native registration, so a per-row one would be a per-copy native
    /// registration.
    func setAccepts(_ n: KayaNodeHandle, _ kinds: [String]) {
        tx.tx.setAccepts(n.id, kayaAcceptList(kinds))
    }

    /// What a stamped copy MEANS — the template twin of
    /// `KayaAppTx.setRole`. Semantic emphasis, never appearance, so a
    /// stamped "Delete" button inside a For can finally be declared
    /// destructive; until this existed it could be declared so in no
    /// language.
    ///
    /// CONST ONLY, `setAccepts`'s rule and its reason: what a copy means
    /// is a fact about the PROTOTYPE, not about the row's data. There is
    /// no signal overload and no `KayaField` one, and that is parity
    /// rather than a cut — no zone in any binding offers a dynamic
    /// spelling.
    ///
    /// The kind restriction is the ROOT'S, not this type's: a role on a
    /// kind it does not fit dies in `check_prop` at DECLARE time, before
    /// a single row stamps, in the same sentence naming both the role and
    /// the kind that the live zone gets (crates/kaya/src/scene.rs).
    func setRole(_ n: KayaNodeHandle, _ role: KayaRole) {
        tx.tx.setRole(n.id, role.rawValue)
    }

    /// A stamped CONTAINER's own padding, in DIP between its bounds and
    /// its children — the template twin of `KayaAppTx.setInset`, and the
    /// same number the window's `inset:` spells two levels up.
    ///
    /// THE FORCING CASE IS A STAMPED ROW. The editor's status row is live
    /// and insets; its find bar is a copy stamped from a template and sat
    /// flush against a full-bleed window's edge, because this zone
    /// carried exactly one layout prop (`setGrow`) and nothing could give
    /// a stamped row its margin back.
    ///
    /// Const for `setRole`'s reason: how far a prototype holds its
    /// children off its edge describes the prototype. Containers only,
    /// and the root says so at declare time.
    func setInset(_ n: KayaNodeHandle, _ pad: Double) {
        tx.tx.setInset(n.id, pad)
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

    /// Bind an image's source to one field of the element;
    /// KayaField<Data> only — the token pins the type at compile time.
    func bindSourceField(_ n: KayaNodeHandle, level: UInt32 = 0, _ f: KayaField<Data>) {
        tx.tx.bindSourceElement(n.id, level: level, field: f.index)
    }

    /// Bind a numeric value to one field of the element;
    /// KayaField<Double> only. ONE binder serves three kinds because
    /// they share one prop on the wire: a progress bar's fraction, a
    /// slider's position and a choice widget's selected index are all
    /// Prop::Value, and the index rides as an f64 like the rest.
    func bindValueField(_ n: KayaNodeHandle, level: UInt32 = 0, _ f: KayaField<Double>) {
        tx.tx.bindValueElement(n.id, level: level, field: f.index)
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

    /// A button with its caption, in the blueprint: the template twin
    /// of `KayaAppTx.button(_:onClick:grow:)`, and the same constructor
    /// Java's and OCaml's template zones already carry.
    ///
    /// It takes NO handler argument, and the omission is the design:
    /// a stamped copy's click names the copy, so the handler is
    /// registered against the template node
    /// (`app.onClick(node) { tx, keys in … }`) and receives that copy's
    /// keys. The live zone's `(KayaAppTx) -> Void` shape has nowhere to
    /// put them, so an `onClick:` overload here could only be the wrong
    /// one.
    func button(_ text: String) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_BUTTON))
        setText(n, text)
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

    /// A single-line text field per stamped copy. UNCONTROLLED, which
    /// is why the primary form takes no source at all: the copy owns
    /// its text, each edit arrives naming this node AND the copy's key
    /// path, and the app folds it into its own state. That is the live
    /// zone's `entry(onChange:)` with the keys threaded through, and it
    /// is what a per-row note field or a one-row find bar actually
    /// wants — the reason this constructor exists.
    func entry(
        onChange: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        textFieldOf(UInt32(KAYA_KIND_ENTRY), onChange)
    }

    /// An entry seeded from an addressable source: the argument's type
    /// picks it, as it does for `label`.
    ///
    /// HOW LONG THE SOURCE LASTS DIFFERS BY SOURCE, and the difference
    /// is the protocol's rather than this binding's. A String is one
    /// write at declaration, so every copy starts there and the user
    /// owns it from the first keystroke. A signal or a field stays
    /// LIVE: the stamper records the binding, so a later write to that
    /// signal — or to that field of that row — replaces whatever the
    /// user has typed into the copy. There is no "seed once from the
    /// row and then let go" arm on the wire (PropValue is Const,
    /// Signal or Element and nothing else), so binding a row's field
    /// here means the row keeps writing.
    func entry(
        _ text: String,
        onChange: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = textFieldOf(UInt32(KAYA_KIND_ENTRY), onChange)
        setText(n, text)
        return n
    }

    func entry(
        _ s: KayaSignal,
        onChange: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = textFieldOf(UInt32(KAYA_KIND_ENTRY), onChange)
        tx.tx.bindText(n.id, s.id)
        return n
    }

    func entry(
        _ f: KayaField<String>,
        onChange: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = textFieldOf(UInt32(KAYA_KIND_ENTRY), onChange)
        bindTextField(n, f)
        return n
    }

    /// A multi-line editor per stamped copy: the entry's uncontrolled
    /// contract over the platform's real multi-line control, and the
    /// same four spellings for the same reasons.
    func textarea(
        onChange: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        textFieldOf(UInt32(KAYA_KIND_TEXTAREA), onChange)
    }

    func textarea(
        _ text: String,
        onChange: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = textFieldOf(UInt32(KAYA_KIND_TEXTAREA), onChange)
        setText(n, text)
        return n
    }

    func textarea(
        _ s: KayaSignal,
        onChange: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = textFieldOf(UInt32(KAYA_KIND_TEXTAREA), onChange)
        tx.tx.bindText(n.id, s.id)
        return n
    }

    func textarea(
        _ f: KayaField<String>,
        onChange: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = textFieldOf(UInt32(KAYA_KIND_TEXTAREA), onChange)
        bindTextField(n, f)
        return n
    }

    /// The unsourced half of both text kinds: the widget and its
    /// handler. Registering the handler emits no wire op, so the source
    /// each caller applies afterwards still lands immediately after the
    /// create — the live zone's op order, unchanged.
    private func textFieldOf(
        _ kind: UInt32, _ onChange: ((KayaAppTx, [KayaValue], String) throws -> Void)?
    ) -> KayaNodeHandle {
        let n = widget(kind)
        if let onChange { tx.app.onChange(n, onChange) }
        return n
    }

    /// A progress bar whose fraction comes from an addressable source —
    /// `t.progress(row.done)` is the per-row case this zone exists for.
    /// Display-only, like label and image; the root re-checks the 0...1
    /// domain for every stamped copy.
    func progress(_ value: Double) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_PROGRESS))
        tx.tx.setValue(n.id, value)
        return n
    }

    func progress(_ s: KayaSignal) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_PROGRESS))
        tx.tx.bindValue(n.id, s.id)
        return n
    }

    func progress(_ f: KayaField<Double>) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_PROGRESS))
        bindValueField(n, f)
        return n
    }

    /// A progress bar in the platform's activity mode. Its own
    /// constructor rather than the live zone's `indeterminate:` flag:
    /// here the fraction argument is what picks the source overload,
    /// and an activity bar has no fraction to source.
    func progressIndeterminate() -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_PROGRESS))
        tx.tx.setIndeterminate(n.id, true)
        return n
    }

    /// A slider over min...max in the blueprint, its change handler
    /// co-located.
    ///
    /// THE RANGE DESCRIBES THE PROTOTYPE and so stays a pair of plain
    /// constants — every stamped copy runs between the same two ends.
    /// The POSITION is the part that varies per row, so it takes a
    /// source. The bar owns that position and reports each move with
    /// the copy's key path and the new value: the entry's uncontrolled
    /// contract, one identity deeper. A move where the position came
    /// from the row's own field does NOT write the field back — the
    /// handler decides whether the model follows.
    func slider(
        min: Double = 0.0, max: Double = 1.0, value: Double,
        onChange: ((KayaAppTx, [KayaValue], Double) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = sliderOf(min, max, onChange)
        tx.tx.setValue(n.id, value)
        return n
    }

    func slider(
        min: Double = 0.0, max: Double = 1.0, value s: KayaSignal,
        onChange: ((KayaAppTx, [KayaValue], Double) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = sliderOf(min, max, onChange)
        tx.tx.bindValue(n.id, s.id)
        return n
    }

    func slider(
        min: Double = 0.0, max: Double = 1.0, value f: KayaField<Double>,
        onChange: ((KayaAppTx, [KayaValue], Double) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = sliderOf(min, max, onChange)
        bindValueField(n, f)
        return n
    }

    private func sliderOf(
        _ min: Double, _ max: Double,
        _ onChange: ((KayaAppTx, [KayaValue], Double) throws -> Void)?
    ) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_SLIDER))
        tx.tx.setMin(n.id, min)
        tx.tx.setMax(n.id, max)
        if let onChange { tx.app.onValueChanged(n, onChange) }
        return n
    }

    /// A dropdown in the blueprint: the option list is the
    /// BLUEPRINT'S, the choice is the row's.
    ///
    /// `selected` is the 0-based index and takes a source, so each copy
    /// can open on its own row's choice; `onSelect` receives the copy's
    /// key path and each USER pick's new index (programmatic writes
    /// never echo). The options cannot vary per row and that is
    /// deliberate rather than missing — see `choiceOf` below.
    func select(
        _ options: [String], selected: Int = 0,
        onSelect: ((KayaAppTx, [KayaValue], Int) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = choiceOf(UInt32(KAYA_KIND_SELECT), options, onSelect)
        tx.tx.setValue(n.id, Double(selected))
        return n
    }

    func select(
        _ options: [String], selected s: KayaSignal,
        onSelect: ((KayaAppTx, [KayaValue], Int) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = choiceOf(UInt32(KAYA_KIND_SELECT), options, onSelect)
        tx.tx.bindValue(n.id, s.id)
        return n
    }

    func select(
        _ options: [String], selected f: KayaField<Double>,
        onSelect: ((KayaAppTx, [KayaValue], Int) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = choiceOf(UInt32(KAYA_KIND_SELECT), options, onSelect)
        bindValueField(n, f)
        return n
    }

    /// A radio group in the blueprint: `select`'s contract in its
    /// inline presentation — same option children, same 0-based index,
    /// same pick handler carrying the copy's keys.
    func radio(
        _ options: [String], selected: Int = 0,
        onSelect: ((KayaAppTx, [KayaValue], Int) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = choiceOf(UInt32(KAYA_KIND_RADIO), options, onSelect)
        tx.tx.setValue(n.id, Double(selected))
        return n
    }

    func radio(
        _ options: [String], selected s: KayaSignal,
        onSelect: ((KayaAppTx, [KayaValue], Int) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = choiceOf(UInt32(KAYA_KIND_RADIO), options, onSelect)
        tx.tx.bindValue(n.id, s.id)
        return n
    }

    func radio(
        _ options: [String], selected f: KayaField<Double>,
        onSelect: ((KayaAppTx, [KayaValue], Int) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = choiceOf(UInt32(KAYA_KIND_RADIO), options, onSelect)
        bindValueField(n, f)
        return n
    }

    /// Both choice kinds, minus the index: the widget, its options and
    /// its handler.
    ///
    /// The options are LABEL CHILDREN of the prototype, exactly as in
    /// the live zone, so they are declared into their own template
    /// frame and parented here. That is also why every stamped copy
    /// offers the same list: children are structure, and structure
    /// belongs to the blueprint. A per-row option list would need a
    /// collection inside the choice widget, and the scene rejects that
    /// (labels only, deliberately — docs/sugar-pass-plan.md §2). Only
    /// the selected index can be the row's.
    ///
    /// The pick arrives as a Double because the index rides Prop::Value
    /// like every other number; the wrapper narrows it once, here,
    /// rather than in three handlers.
    private func choiceOf(
        _ kind: UInt32, _ options: [String],
        _ onSelect: ((KayaAppTx, [KayaValue], Int) throws -> Void)?
    ) -> KayaNodeHandle {
        let n = widget(kind)
        tx.app.childFrames.append(KayaApp.KayaFrame(template: true))
        for option in options {
            let o = widget(UInt32(KAYA_KIND_LABEL))
            setText(o, option)
        }
        let ids = tx.app.childFrames.removeLast().ids
        for id in ids { tx.tx.addChild(n.id, id) }
        if let onSelect {
            tx.app.onValueChanged(n) { tx, keys, v in try onSelect(tx, keys, Int(v)) }
        }
        return n
    }

    /// An image with constant encoded bytes: every stamped copy shows
    /// the same picture — one registration copy into core memory, the
    /// handle consumed by the next submit.
    func image(_ source: Data) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_IMAGE))
        tx.tx.setSource(n.id, kayaRegisterBlob(source))
        return n
    }

    func image(_ s: KayaSignal) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_IMAGE))
        tx.tx.bindSource(n.id, s.id)
        return n
    }

    func image(_ f: KayaField<Data>) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_IMAGE))
        bindSourceField(n, f)
        return n
    }

    func row(@KayaNodeChildren _ children: () -> Void) -> KayaNodeHandle {
        nodeContainerOf(UInt32(KAYA_KIND_ROW), children)
    }

    func column(@KayaNodeChildren _ children: () -> Void) -> KayaNodeHandle {
        nodeContainerOf(UInt32(KAYA_KIND_COLUMN), children)
    }

    /// A vertical scroll viewport over EXACTLY ONE child, per stamped
    /// copy (declare it in the builder).
    func scroll(@KayaNodeChildren _ children: () -> Void) -> KayaNodeHandle {
        nodeContainerOf(UInt32(KAYA_KIND_SCROLL), children)
    }

    /// A grid laying each copy's children out row-major into `columns`
    /// columns — each column takes its NATURAL width, aligned across
    /// rows (the thing nested rows cannot express).
    ///
    /// The column count describes the PROTOTYPE, so it is a plain
    /// constant rather than a source: every stamped copy has the same
    /// shape and only the values inside it vary. The count is written
    /// after the children rather than before, which the tree cannot
    /// see — the parent is created first either way, and creation order
    /// is what the observation names.
    func grid(columns: Int, @KayaNodeChildren _ children: () -> Void) -> KayaNodeHandle {
        let n = nodeContainerOf(UInt32(KAYA_KIND_GRID), children)
        tx.tx.setColumns(n.id, Double(columns))
        return n
    }

    /// A spacer: PURE SUGAR for an empty grown column — it consumes the
    /// leftover main-axis space between its siblings in every stamped
    /// copy. No new vocabulary reaches a backend: it writes the Grow a
    /// caller could write itself with `setGrow`.
    func spacer() -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_COLUMN))
        tx.tx.setGrow(n.id, 1.0)
        return n
    }

    private func nodeContainerOf(_ kind: UInt32, _ children: () -> Void) -> KayaNodeHandle {
        let parent = widget(kind)
        tx.app.childFrames.append(KayaApp.KayaFrame(template: true))
        children()
        let ids = tx.app.childFrames.removeLast().ids
        for id in ids { tx.tx.addChild(parent.id, id) }
        return parent
    }

    func addChild(_ parent: KayaNodeHandle, _ child: KayaNodeHandle) {
        tx.tx.addChild(parent.id, child.id)
    }

    /// Attach a live-built context catalog (tx.contextCatalog) to a
    /// template node: every stamped copy shows the same catalog, and
    /// each activation carries that copy's key path — the keys ARE
    /// the noun (received by the node-flavor handlers). An item takes
    /// exactly one anchor, so a second attach of the same catalog
    /// traps here.
    func contextMenu(_ node: KayaNodeHandle, _ catalog: KayaContextCatalog) {
        precondition(
            !catalog.attached, "kaya: a context catalog takes exactly one anchor")
        catalog.attached = true
        for root in catalog.roots {
            tx.tx.contextAttachNode(node.id, root.id)
        }
    }

    func collection() -> KayaCollection {
        tx.collection()
    }

    /// A nested For as a child: forEach whose body keeps no handles —
    /// the template twin of `KayaAppTx.each(_:_:)`, and the common case
    /// once the handles a template owes the outside are assigned to the
    /// scene's own bindings rather than threaded back through R.
    func each(_ c: KayaCollection, _ body: (KayaTpl) -> Void) -> KayaNodeHandle {
        forEach(c) { body($0) }.0
    }

    func forEach<R>(_ c: KayaCollection, _ body: (KayaTpl) -> R) -> (KayaNodeHandle, R) {
        c.assertRoot()
        let n = tx.app.nextNode()
        tx.tx.createFor(n.id, c.id)
        tx.app.parentAtCreation(node: n.id)
        tx.app.openFors.append(c.id)
        tx.app.tplDepth += 1
        defer { tx.app.tplDepth -= 1 }
        let out = tx.app.inTemplateBody { body(KayaTpl(tx: tx)) }
        tx.app.openFors.removeLast()
        tx.tx.templateEnd()
        return (n, out)
    }

    func when<R>(_ s: KayaSignal, _ body: (KayaTpl) -> R) -> (KayaNodeHandle, R) {
        let n = tx.app.nextNode()
        tx.tx.createWhen(n.id, s.id)
        tx.app.parentAtCreation(node: n.id)
        tx.app.tplDepth += 1
        defer { tx.app.tplDepth -= 1 }
        let out = tx.app.inTemplateBody { body(KayaTpl(tx: tx)) }
        tx.tx.templateEnd()
        return (n, out)
    }
}
