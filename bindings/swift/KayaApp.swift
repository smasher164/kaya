// kaya's idiomatic surface for Swift: the structural core, over the generated
// wire vocabulary (KayaWire.swift) and the kaya C declarations (kaya.h via
// the bridging header).

import Foundation

/// The header bar's sort indicator (docs/tables-plan.md): which column
/// shows it, in which direction — the GUEST's declaration, re-sent
/// with the new state after it handles a sort request. The platform
/// never sorts; a header click only asks.
struct KayaSort {
    let sorted: UInt32
    let direction: UInt32

    /// The no-indicator bar.
    static let none = KayaSort(sorted: 0xFFFF_FFFF, direction: 0)

    /// Ascending on `column` (0-based, in the declared order).
    static func asc(_ column: UInt32) -> KayaSort {
        KayaSort(sorted: column, direction: 0)
    }

    /// Descending on `column`.
    static func desc(_ column: UInt32) -> KayaSort {
        KayaSort(sorted: column, direction: 1)
    }
}

struct KayaSignal {
    let id: UInt64

    /// Mint a derived signal: recomputed when the source is written, the
    /// write batched into the same transaction; the core sees an ordinary
    /// signal.
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

/// Register bulk payload bytes (an encoded image) with the core: one copy
/// into core-owned memory, returning the u64 handle the next submit from this
/// guest consumes, referenced or not.
func kayaRegisterBlob(_ data: Data) -> UInt64 {
    data.withUnsafeBytes { raw in
        kaya_blob_register(raw.bindMemory(to: UInt8.self).baseAddress, UInt(raw.count))
    }
}

/// A live widget: exactly one thing on screen. A container's cross-axis child
/// placement (the align spec enum; wire values pinned by the generated
/// constants).
enum KayaAlign: Int64 {
    case start = 0
    case center = 1
    case end = 2
    case stretch = 3
    case baseline = 4
}

/// A container's ARRANGEMENT AXIS: identity is the creation kind
/// (`row#N` stays `row#N` whatever this says), presentation is the prop
/// (docs/adaptive-layout-plan.md D1/D2).
enum KayaAxis: Int64 {
    case horizontal = 0
    case vertical = 1
}

/// A canvas's coordinate system AND its natural size in
/// device-independent points (docs/canvas-plan.md §3.2). The op stream is
/// written in these units on every platform and in every language, so a
/// scene can freeze it.
struct KayaViewbox {
    let w: Double
    let h: Double

    init(_ w: Double, _ h: Double) {
        self.w = w
        self.h = h
    }
}

/// The paint ROLE an op names. Never RGB: the roles resolve in the core
/// per appearance (docs/canvas-plan.md §3.4). The numbers come from the
/// core's own header rather than a fourth hand-written copy of them
/// (tools/check-symbol-parity.sh's trap, one surface over).
enum KayaPaint {
    /// The line.
    case series
    /// The area under it.
    case seriesFill
    /// Gridlines.
    case grid
    /// Axis lines and tick labels.
    case axis
    /// The plot background.
    case ground

    var wire: Int64 {
        switch self {
        case .series: return Int64(KAYA_PAINT_SERIES)
        case .seriesFill: return Int64(KAYA_PAINT_SERIES_FILL)
        case .grid: return Int64(KAYA_PAINT_GRID)
        case .axis: return Int64(KAYA_PAINT_AXIS)
        case .ground: return Int64(KAYA_PAINT_GROUND)
        }
    }
}

/// Which way a fill resolves its own crossings.
enum KayaFillRule {
    case nonzero
    case evenOdd

    var wire: Int64 {
        switch self {
        case .nonzero: return Int64(KAYA_FILL_NONZERO)
        case .evenOdd: return Int64(KAYA_FILL_EVEN_ODD)
        }
    }
}

/// SVG's `text-anchor`: which end of the run sits at the anchor point.
enum KayaTextAlign {
    case start
    case middle
    case end

    var wire: Int64 {
        switch self {
        case .start: return Int64(KAYA_TEXT_ALIGN_START)
        case .middle: return Int64(KAYA_TEXT_ALIGN_MIDDLE)
        case .end: return Int64(KAYA_TEXT_ALIGN_END)
        }
    }
}

/// SVG's `dominant-baseline`: which horizontal line of the run sits at
/// the anchor point.
enum KayaTextBaseline {
    case alphabetic
    case middle
    case top
    case bottom

    var wire: Int64 {
        switch self {
        case .alphabetic: return Int64(KAYA_TEXT_BASELINE_ALPHABETIC)
        case .middle: return Int64(KAYA_TEXT_BASELINE_MIDDLE)
        case .top: return Int64(KAYA_TEXT_BASELINE_TOP)
        case .bottom: return Int64(KAYA_TEXT_BASELINE_BOTTOM)
        }
    }
}

/// The drawing scope's recorder. The calls read as immediate-mode
/// drawing; they are recorded, and ONE record is submitted when the scope
/// closes — the For template trace's fiction with a drawing scope instead
/// of a loop (docs/canvas-plan.md §2.1).
final class KayaDraw {
    /// The box this drawing is written in, so a chart can compute its own
    /// extents without the app carrying the numbers twice.
    let viewbox: KayaViewbox
    fileprivate var ops: [KayaValue] = []

    fileprivate init(viewbox: KayaViewbox) {
        self.viewbox = viewbox
    }

    @discardableResult
    private func op(_ code: Int32, _ operands: KayaValue...) -> KayaDraw {
        ops.append(.i64(Int64(code)))
        ops.append(contentsOf: operands)
        return self
    }

    /// Start a subpath at (x, y).
    @discardableResult
    func moveTo(_ x: Double, _ y: Double) -> KayaDraw {
        op(KAYA_DRAW_MOVE_TO, .f64(x), .f64(y))
    }

    /// Extend the current subpath to (x, y).
    @discardableResult
    func lineTo(_ x: Double, _ y: Double) -> KayaDraw {
        op(KAYA_DRAW_LINE_TO, .f64(x), .f64(y))
    }

    /// Close the current subpath.
    @discardableResult
    func close() -> KayaDraw {
        op(KAYA_DRAW_CLOSE)
    }

    /// `moveTo` the first point and `lineTo` the rest — the chart's own
    /// shape, spelled once.
    @discardableResult
    func polyline(_ points: [(Double, Double)]) -> KayaDraw {
        for (i, p) in points.enumerated() {
            if i == 0 {
                moveTo(p.0, p.1)
            } else {
                lineTo(p.0, p.1)
            }
        }
        return self
    }

    /// Stroke the built path and clear it. `width` is in
    /// device-independent points and does NOT carry the viewbox stretch,
    /// so a 1pt gridline is 1pt at every canvas size (§3.2).
    @discardableResult
    func stroke(_ paint: KayaPaint, width: Double) -> KayaDraw {
        op(KAYA_DRAW_STROKE, .i64(paint.wire), .f64(width))
    }

    /// Fill the built path and clear it.
    @discardableResult
    func fill(_ paint: KayaPaint, rule: KayaFillRule = .nonzero) -> KayaDraw {
        op(KAYA_DRAW_FILL, .i64(paint.wire), .i64(rule.wire))
    }

    /// Select the face for subsequent text ops. `asset` is an ordinary
    /// asset name; `""` is kaya's own embedded default face, which is why
    /// a canvas can always draw text (§4.2). `size` is in
    /// device-independent points.
    @discardableResult
    func font(size: Double, asset: String = "", weight: Int64 = 400) -> KayaDraw {
        op(KAYA_DRAW_FONT, .str(asset), .f64(size), .i64(weight))
    }

    /// Draw ONE LINE with its anchor at (x, y). A line break in `s` is
    /// refused by the core (§3.3).
    @discardableResult
    func text(
        _ x: Double, _ y: Double, _ s: String, _ paint: KayaPaint,
        align: KayaTextAlign = .start, baseline: KayaTextBaseline = .alphabetic
    ) -> KayaDraw {
        op(
            KAYA_DRAW_TEXT, .f64(x), .f64(y), .i64(paint.wire), .i64(align.wire),
            .i64(baseline.wire), .str(s))
    }
}

/// SEMANTIC EMPHASIS (docs/styling-plan.md D4): what a widget MEANS,
/// never how it looks — a closed vocabulary, so there is no raw value to
/// reach for. Destructive and prominent are BUTTON emphasis, heading and
/// caption are LABEL hierarchy, and the root refuses the other
/// combinations at declare time, in one sentence naming both the role and
/// the kind.
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
    /// A heading's counterpart under the content it explains: the
    /// platform's caption/footnote text tier. The AX fact rides only
    /// where the platform has one (GTK's Caption role).
    case caption = 4
}

/// WHICH PLATFORM A PER-PLATFORM BRAND VALUE IS FOR (the `platform` spec
/// enum; docs/styling-plan.md Slice 2b): one entry per backend roster
/// row, closed.
///
/// AN APP NAMES THESE, IT NEVER ASKS WHICH ONE IT IS. There is no
/// `KayaPlatform.current`: every row travels to every backend and each
/// backend picks its own. Swift is where the temptation is sharpest,
/// because ONE guest source compiles for macOS and for iOS — a
/// `#if os(macOS)` in a guest ships different code per platform, which
/// is the thing kaya exists to not do.
enum KayaPlatform: Int64 {
    case mac = 1
    case ios = 2
    case linux = 3
    case windows = 4
    case android = 5
}

/// THE SEMANTIC ICON VOCABULARY (the `symbol` spec enum;
/// docs/styling-plan.md D6, DESIGN.md "Icons want names, not bytes").
/// An app names a CONCEPT and each backend draws its own platform's
/// glyph; the `icon:` blob slot stays for app-specific art. THE RAW
/// VALUES ARE WIRE VALUES AND ARE APPEND-ONLY — renumbering silently
/// redraws every shipped app's menus.
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

    /// Stack this row's children vertically while the window's SIZE
    /// CLASS is `when` (`.compact`, the only class today), reverting on
    /// leaving the class — ONE core-evaluated breakpoint record, the
    /// container-riding spelling (docs/adaptive-layout-plan.md D3;
    /// classes ruled 2026-08-31: iOS answers with the platform's own
    /// class, every other platform is compact below 600 points). The
    /// root refuses a non-container target at batch.
    @discardableResult
    func stackWhen(_ when: KayaSizeClass) -> KayaWidget {
        let (_, tx) = kayaDeclaring()
        // Widgets, then props, then values — thirds by position.
        tx.tx.createBreakpoint(
            0, .i64(when.wire), 1,
            [.i64(Int64(id)), .i64(Int64(KAYA_PROP_AXIS)), .i64(Int64(KAYA_AXIS_VERTICAL))])
        return self
    }

    /// THIS CANVAS REFUSES COERCION: it draws at its viewbox and is placed
    /// in whatever track layout gives it, never adapting to it
    /// (docs/canvas-plan.md §3.2.1, ruling 2). The one true PROPERTY of the
    /// size policy — it asserts that the content is not a function of the
    /// assigned track; the other two are handlers, and a canvas that
    /// declares nothing is `scale`.
    @discardableResult
    func fixed() -> KayaWidget {
        let (_, tx) = kayaDeclaring()
        tx.tx.setSizePolicy(id, UInt32(SIZE_POLICY_FIXED))
        return self
    }

    /// THIS CANVAS'S DRAWING IS A FUNCTION OF ITS SIZE: the core hands it
    /// the size layout assigned and takes back what this draws for that
    /// size, which becomes its viewbox. PROVIDING THE HANDLER IS THE
    /// DECLARATION, so this registers and puts the policy on the wire in
    /// ONE act — a registered handler nothing could reach is unspellable.
    ///
    /// The binding answers the ask inside a transaction of its own
    /// (tools/check-ambient-tx.sh); it never reaches the guest.
    @discardableResult
    func onDraw(_ handler: @escaping (KayaDraw, KayaViewbox) -> Void) -> KayaWidget {
        // WIDENED HERE, not at dispatch: one stored shape means the
        // answer path never asks which policy it holds, and a tick
        // canvas — which is asked once as a draw_requested before its
        // first frame — cannot be called with the wrong arity.
        declareDrawing(UInt32(SIZE_POLICY_REDRAW)) { d, size, _ in handler(d, size) }
    }

    /// The same on the platform's FRAME CLOCK, the handler also receiving
    /// the frame's time in seconds. Under the harness that clock is the
    /// core's deterministic step, advanced by a verb, so a leg's frame
    /// count is part of the scene and never a fact about the machine.
    @discardableResult
    func onTick(_ handler: @escaping (KayaDraw, KayaViewbox, Double) -> Void) -> KayaWidget {
        declareDrawing(UInt32(SIZE_POLICY_TICK), handler)
    }

    @discardableResult
    private func declareDrawing(
        _ policy: UInt32, _ f: @escaping (KayaDraw, KayaViewbox, Double) -> Void
    ) -> KayaWidget {
        let (app, tx) = kayaDeclaring()
        app.registerDraw(id, f)
        tx.tx.setSizePolicy(id, policy)
        return self
    }
}

/// A window's named size class (spec enum "size_class"; ruled
/// 2026-08-31): what `stackWhen` speaks in place of an author-invented
/// width. `.compact` is the whole surface today.
enum KayaSizeClass {
    case compact

    var wire: Int64 {
        switch self {
        case .compact: return Int64(KAYA_SIZE_CLASS_COMPACT)
        }
    }
}

/// A template node: a blueprint entry, stamped per collection entry.
///
/// NO `stackWhen`/`fixed`/`onDraw`/`onTick` HERE, and the compiler is
/// the refusal: a breakpoint's setters name LIVE widgets and a template
/// row is a blueprint stamped per entry
/// (docs/adaptive-layout-plan.md D3), and the size policy is a live-zone
/// declaration in this slice, so a canvas inside a row template keeps
/// `scale` (docs/deferred.md, the template-zone size policy entry, which
/// says what closing it costs).
struct KayaNodeHandle {
    let id: UInt64
}

/// The app and the open transaction a chained live-zone declaration
/// needs: the registry a handler joins, and the batch the record rides
/// (KayaSignal.derive's guard, one handle type over).
private func kayaDeclaring() -> (app: KayaApp, tx: KayaAppTx) {
    guard let app = KayaApp.ambient, let tx = app.currentTx else {
        preconditionFailure(
            "kaya: a canvas's size policy and stackWhen are declared inside a "
                + "transaction (build or handler)")
    }
    return (app, tx)
}

/// The size a canvas ask was made about: two bare f64 values after the
/// key path, in device-independent points (spec records 20 and 21).
private func kayaAssignedSize(_ tail: [KayaValue]) -> KayaViewbox? {
    guard tail.count >= 2, case .f64(let w) = tail[0], case .f64(let h) = tail[1] else {
        return nil
    }
    return KayaViewbox(w, h)
}

/// A tick's third value, the frame's time in seconds. A draw_requested
/// carries none and answers 0, which is what a tick canvas's first ask
/// is.
private func kayaFrameTime(_ tail: [KayaValue]) -> Double {
    guard tail.count >= 3, case .f64(let t) = tail[2] else { return 0.0 }
    return t
}

/// A collection instance handle: the collection plus the key path selecting
/// one stamped copy's table.
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

/// One instance of a collection: the table inside the stamped copy selected
/// by `path` (the empty path for a live-zone collection).
///
/// ORDERED AND KEYED AT ONCE: `entries` is the order the guest reads back,
/// `slots` is each key's index in it. `entries` is read-only from outside
/// and `slots` is unreachable, so a write that skipped the index cannot be
/// spelled — the scan it replaces cost 58s of guest time at 40,000 rows
/// (docs/deferred.md, the Swift binding's quadratic insert).
private struct KayaInstance {
    let path: [KayaValue]
    // Any: a KayaValue for scalar collections, the record struct itself
    // for record collections — the model is guest-owned, so it keeps
    // native values and only wire fields ever encode.
    private(set) var entries: [(key: KayaValue, value: Any)] = []
    private var slots: [KayaValue: Int] = [:]

    init(path: [KayaValue]) {
        self.path = path
    }

    func has(_ key: KayaValue) -> Bool {
        slots[key] != nil
    }

    mutating func set(_ key: KayaValue, _ value: Any) {
        if let at = slots[key] {
            entries[at].value = value
        } else {
            slots[key] = entries.count
            entries.append((key: key, value: value))
        }
    }

    mutating func remove(_ key: KayaValue) {
        guard let at = slots.removeValue(forKey: key) else { return }
        entries.remove(at: at)
        reindex(from: at)
    }

    /// Lift `key` out and put it back before `anchor`, or at the end when
    /// there is none. The anchor is resolved AFTER the lift, so moving an
    /// entry before itself lands it last.
    mutating func move(_ key: KayaValue, before anchor: KayaValue?) {
        guard let from = slots.removeValue(forKey: key) else { return }
        let entry = entries.remove(at: from)
        reindex(from: from)
        let to = anchor.flatMap { slots[$0] } ?? entries.count
        entries.insert(entry, at: to)
        reindex(from: to)
    }

    /// Put the named keys first, in this order; anything the list does not
    /// name keeps its place behind them. A key named twice is placed once.
    mutating func reorder(_ keys: [KayaValue]) {
        var lifted: Set<Int> = []
        var front: [(key: KayaValue, value: Any)] = []
        for key in keys {
            guard let at = slots[key], lifted.insert(at).inserted else { continue }
            front.append(entries[at])
        }
        if front.isEmpty { return }
        var back: [(key: KayaValue, value: Any)] = []
        back.reserveCapacity(entries.count - front.count)
        for (at, entry) in entries.enumerated() where !lifted.contains(at) {
            back.append(entry)
        }
        entries = front + back
        slots.removeAll(keepingCapacity: true)
        reindex(from: 0)
    }

    private mutating func reindex(from: Int) {
        for at in from..<entries.count {
            slots[entries[at].key] = at
        }
    }
}

/// A live menu item: its OWN id space (the c_menu_item counter) behind its
/// own type, so cross-use with widget or node handles is a compile error.
struct KayaMenuItem {
    let id: UInt64
}

/// A context catalog built UNANCHORED (tx.contextCatalog) for a template
/// node: menu items are live and shared across stamped copies, so the catalog
/// is built in the live zone and KayaTpl.contextMenu attaches it inside the
/// template, where each activation carries the copy's key path.
final class KayaContextCatalog {
    let roots: [KayaMenuItem]
    var attached = false

    init(_ roots: [KayaMenuItem]) {
        self.roots = roots
    }
}

/// One of the TWO addressable sources a menu text property binds to —
/// constant text or a Str signal (menu items are not collection elements, so
/// there is no element arm).
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

/// One file the picker answered with: a handle to redeem, a display name, and
/// `localPath` — a RE-OPENABLE NAME, empty unless re-opening it actually
/// works, which measurement puts at the three desktops and neither phone
/// (DESIGN.md, File dialogs).
enum KayaRepresentation {
    case text(String)
    case html(String)
    /// Encoded image bytes. WHAT COMES BACK MAY BE A RE-ENCODE — the
    /// hosts convert freely between image types — so compare what the
    /// image IS, never the bytes it arrived in.
    case image([UInt8])
    /// Files, plural INSIDE one representation — the same nesting
    /// text/uri-list and CF_HDROP already have.
    case files([KayaPickedFile])
    /// An app-defined format, round-tripped verbatim.
    case custom(id: String, bytes: [UInt8])
}

/// Turn the decoder's kind-and-parts into the sum, or nil.
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
        // ARITY FIRST, so a reader needs no schema: `size` counts
        // itself. The group is `size, id, path_len, path values…, text`,
        // pinned value by value in crates/kaya/src/wire.rs
        // `undo_bodies_round_trip`.
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
func kayaFilterValues(_ filters: [(String, String)]) -> [KayaValue] {
    var values: [KayaValue] = []
    for (label, extensions) in filters {
        values.append(.str(label))
        values.append(.str(extensions))
    }
    return values
}

/// The UTF-8 BYTE OFFSET of a position in `text` — kaya's unit for every text
/// range, and the one number Swift's `String.Index` will not hand you. NEVER
/// CONVERT BY HAND: both spellings a Swift author reaches for first
/// (`distance(from:to:)` counts Characters, `utf16Offset(in:)` counts UTF-16)
/// are silently short on non-ASCII text — docs/traps.md, "what each
/// language's own unit is".
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

    /// Offer a picked file, the picker's own capability put straight on the
    /// clipboard.
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

/// WHAT `KayaAsset(_:)` THROWS: a name the package does not carry, or
/// carries unreadably (docs/assets-plan.md).
///
/// THE SENTENCE IS THE ERROR: `description` and `errorDescription` are
/// both `sentence`, so every way Swift has of printing an error says the
/// bytes the core wrote. Without `LocalizedError`,
/// `localizedDescription` would answer Foundation's boilerplate instead.
/// This type writes NO prose — `sentence` is `asset_why_not`'s, verbatim
/// (crates/kaya/src/assets.rs) — and `name` is carried separately so a
/// guest can branch without reading the prose back out.
struct KayaAssetMiss: Error, CustomStringConvertible, LocalizedError {
    /// The name that was asked for.
    let name: String
    /// The core's sentence, verbatim. Two lines: the first names the
    /// name, the rule it broke and the census, and is the same on every
    /// platform; the second names the resolved place and the route that
    /// chose it.
    let sentence: String

    var description: String { sentence }
    var errorDescription: String? { sentence }
}

/// AN ASSET — a file this app's own BUILD put where the running program
/// can find it (docs/assets-plan.md). `try KayaAsset("fonts/x.ttf")`
/// opens one; the name is a relative path under a root the CORE
/// resolves, and no guest reads an asset environment variable or carries
/// a repo-relative default (tools/check-assets.sh).
///
/// A MISS THROWS `KayaAssetMiss` carrying the core's sentence and
/// nothing added — `tools/scenes/assets.steps` freezes it THROUGH THE
/// CAUGHT ERROR, so a byte this file prefixed would redden two lanes.
/// Unhandled it is still fatal.
///
/// EACH CALL READS: no cache, no watch, no reload. A CLASS RATHER THAN A
/// STRUCT for the one reason a class earns here — `deinit`, so release
/// is explicit (`close()`) AND automatic.
final class KayaAsset {
    private var handle: UInt64

    init(_ name: String) throws {
        // Set before anything can throw: a class must be whole before a
        // designated initializer leaves, and `deinit` runs on the way out.
        handle = 0
        let utf8 = Array(name.utf8)
        let opened = utf8.withUnsafeBufferPointer { raw in
            kaya_asset_open(raw.baseAddress, UInt(raw.count))
        }
        guard opened != 0 else {
            // ONE COPY OF THE FFI DANCE, and it is `missSentence` below:
            // the throw and the query hand back the same bytes because
            // they are the same call.
            throw KayaAssetMiss(name: name, sentence: KayaAsset.missSentence(name))
        }
        handle = opened
    }

    /// Why `KayaAsset(name)` would throw — the sentence it would carry,
    /// handed over without throwing. `""` means the name resolves.
    ///
    /// It answers what the throw cannot: for a name that RESOLVES it
    /// hands back `""`, having opened nothing. Line 1 (name, rule,
    /// census) is the same on every platform and is the line a scene
    /// freezes; line 2 names the resolved place, which three platforms
    /// spell three ways. It measures rather than predicts: each call
    /// reads, so `""` is a fact about the moment it was asked.
    ///
    /// Why a query when `init` throws: docs/deferred.md, the assets
    /// entry. The sentence has one author, `asset_why_not` in
    /// crates/kaya/src/assets.rs.
    ///
    /// SIZED, THEN READ: the C entry returns the sentence's TRUE length
    /// and fills the caller's buffer, so it takes two calls. A guessed
    /// buffer cuts the half that names the root and the route.
    static func missSentence(_ name: String) -> String {
        let utf8 = Array(name.utf8)
        let len = utf8.withUnsafeBufferPointer { raw in
            kaya_asset_why_not(raw.baseAddress, UInt(raw.count), nil, 0)
        }
        if len == 0 { return "" }
        var sentence = [UInt8](repeating: 0, count: Int(len))
        sentence.withUnsafeMutableBufferPointer { out in
            _ = utf8.withUnsafeBufferPointer { raw in
                kaya_asset_why_not(raw.baseAddress, UInt(raw.count), out.baseAddress, len)
            }
        }
        return String(decoding: sentence, as: UTF8.self)
    }

    /// THE BYTES REDEMPTION: this asset's bytes, copied out of core memory.
    var bytes: Data {
        alive()
        var len = UInt(0)
        guard let p = kaya_asset_bytes(handle, &len), len > 0 else { return Data() }
        return Data(bytes: p, count: Int(len))
    }

    /// The same bytes as a stream, for the Foundation consumers that want
    /// one. IN-MEMORY AND NOT A FILE: `InputStream(data:)` over `bytes`,
    /// with no core surface behind it and no descriptor anywhere.
    func stream() -> InputStream {
        InputStream(data: bytes)
    }

    /// THE BLOB REDEMPTION, for the consumers inside this binding: register
    /// these bytes into the pending table and answer with the handle the
    /// record carries.
    fileprivate func blob() -> UInt64 {
        alive()
        return kaya_asset_blob(handle)
    }

    /// Let the core drop these bytes. Idempotent, and `deinit` calls the
    /// same release, which the core also treats as a no-op.
    func close() {
        kaya_asset_release(handle)
        handle = 0
    }

    deinit {
        kaya_asset_release(handle)
    }

    private func alive() {
        precondition(
            handle != 0,
            "kaya: this asset is closed — an asset's bytes live in the core until "
                + "close(), and a use after that has nothing to read; open it again "
                + "with KayaAsset(_:)")
    }
}

struct KayaPickedFile {
    let handle: UInt64
    let name: String
    let localPath: String

    /// Redeem the handle for a real FileHandle, plus whether it seeks.
    /// BLOCKS, possibly for a long time, so call it from a thread you
    /// chose and post the result back. THE DESCRIPTOR BECOMES SWIFT'S:
    /// `closeOnDealloc` is true, so it closes exactly once and the core
    /// keeps no claim.
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

/// WHAT THIS HOST CAN DO — see crates/kaya/src/app.rs for the canonical
/// note, which every binding's copy of this surface shortens.
struct KayaCapabilities {
    /// The host can materialize a surface beside the primary one
    /// (`tx.createWindow`, `tx.mountIn`). False on iOS, whose system owns
    /// surface geometry; there `createWindow` aborts at the root.
    ///
    /// ONE SOURCE SERVES MAC AND iOS, so this is the only spelling that
    /// can answer for both: a `#if !os(iOS)` around the CALL is a second
    /// copy of the core's rule, keyed on the platform rather than on the
    /// capability. (A `#if` around an IMPORT or an unavailable API is a
    /// different thing and stays.)
    let auxWindows: Bool
}

final class KayaApp {
    /// This host's capabilities. Constant for the life of the process, so
    /// asking once and remembering is fine. `KAYA_CAP_AUX_WINDOWS` is the
    /// CORE'S OWN `#define`, imported through the bridging header, so a
    /// renumbering reaches Swift with no edit in this tree.
    static func capabilities() -> KayaCapabilities {
        let bits = kaya_capabilities()
        return KayaCapabilities(auxWindows: bits & UInt64(KAYA_CAP_AUX_WINDOWS) != 0)
    }

    // Work handed over by other threads, waiting to run as transactions
    // on the app thread. THE ONLY STATE HERE TOUCHED FROM ANOTHER
    // THREAD, and the only reason this class carries a lock at all —
    // everything below is app-thread-only by construction.
    private let postLock = NSLock()
    private var posted: [(KayaAppTx) throws -> Void] = []
    private var signals: UInt64 = 0
    private var widgets: UInt64 = 0
    private var collections: UInt64 = 0
    // No `nodes`: template nodes draw from `widgets`, one sequence per
    // app (DESIGN.md, Binding conventions).
    private var menuItems: UInt64 = 0
    private var widgetHandlers: [UInt64: (KayaAppTx) throws -> Void] = [:]
    /// Table sort requests, keyed by the For container's widget id
    /// (docs/tables-plan.md): the handler receives the 0-based column.
    private var sortHandlers: [UInt64: (KayaAppTx, UInt32) throws -> Void] = [:]
    /// A nested For's sort requests, keyed by its TEMPLATE NODE id —
    /// its own table because the two id spaces collide numerically, and
    /// the empty key path is what tells the two apart at dispatch.
    private var nodeSorts: [UInt64: (KayaAppTx, [KayaValue], UInt32) throws -> Void] = [:]
    /// Each canvas's declared viewbox, so a redraw in a LATER
    /// transaction does not have to repeat it (docs/canvas-plan.md §2.2).
    fileprivate var canvasViewboxes: [UInt64: KayaViewbox] = [:]
    /// THE CANVAS'S DRAWING-AS-A-FUNCTION-OF-SIZE (docs/canvas-plan.md
    /// §3.2.1), keyed by the canvas's widget id. Not a message handler:
    /// these produce a DRAWING, so dispatchLoop answers the ask itself and
    /// keeps looping rather than handing the guest an occurrence. ONE
    /// SHAPE, widened at registration, so the answer path never has to ask
    /// which policy declared it; the Double is the frame's time in
    /// seconds, 0 for a plain redraw.
    private var draws: [UInt64: (KayaDraw, KayaViewbox, Double) -> Void] = [:]
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

    // The collection is the model — the only copy: every mutation op edits it
    // and queues the wire delta in the same call, so reads (items, count) are
    // exactly the writes.
    static var ambient: KayaApp?
    // The app thread, claimed by dispatchLoop and read at every
    // transaction gate (requireAppThread). Nil until then, which is what
    // lets the guest's opening build run on the main thread before run().
    static var appThread: Thread?

    /// Called by dispatchLoop on the way in: from here on that thread IS
    /// the app thread.
    static func claimAppThread() { appThread = Thread.current }

    /// The other half of the rule KayaAppTx.alive states: OPEN is not
    /// enough, a transaction also belongs to the app thread. `closed`
    /// cannot see a Task continuation writing through a transaction that
    /// is still open, nor a background build opening one of its own —
    /// both race the app thread's mirror.
    /// tools/check-tx-liveness.sh holds it.
    static func requireAppThread() {
        guard let owner = appThread else { return }
        let here = Thread.current
        if here !== owner {
            preconditionFailure(
                "kaya: a transaction belongs to the app thread — this is thread \(here), "
                    + "the app thread is \(owner). To mutate from a background thread use "
                    + "app.post, which runs your function as a transaction over there.")
        }
    }

    var currentTx: KayaAppTx?
    var signalMirrors: [UInt64: KayaValue] = [:]
    var signalDeps: [UInt64: [(KayaAppTx) -> Void]] = [:]
    // Container builders collect children ambiently, in evaluation order
    // (a frame per open container). Frames are ZONE-TAGGED and
    // constructors parent AT CREATION, never at expression position —
    // that silently drops any let-bound child — and the tag makes a
    // cross-zone child loud instead of silently absent.
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

    /// Run a For's or a When's body behind a PARENT BARRIER: a node created
    /// directly in that body is a ROOT of the template it declares — the core
    /// derives the roots itself — and never a child of whatever container
    /// encloses the combinator.
    fileprivate func inTemplateBody<R>(_ body: () -> R) -> R {
        childFrames.append(KayaFrame(template: true))
        defer { childFrames.removeLast() }
        return body()
    }
    var openTraces = 0
    // The record-time mirror-read guard's arming counter: >0 while any
    // template body (a For body, a When body, or a row-trace body) is being
    // DECLARED.
    var tplDepth = 0

    init() {
        KayaApp.ambient = self
    }

    private var model: [UInt64: [KayaInstance]] = [:]
    // The minter's counters: the highest I64 key each collection
    // INSTANCE has minted or absorbed. NOT part of the transaction
    // journal: a minted key is spent even if the transaction that spent
    // it is abandoned, so an id can never be handed out twice.
    private var fresh: [UInt64: [[KayaValue]: Int64]] = [:]
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

    /// Journal one collection's instances into the open transaction the first
    /// time it mutates them (value semantics make the snapshot a cheap copy-
    /// on-write).
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

    /// `path`'s slot in `coll`'s instance list, made if this is the first
    /// anyone asked. There is one instance per stamped copy, not one per
    /// entry, so this list stays short.
    private func instanceSlot(_ coll: UInt64, _ path: [KayaValue]) -> Int {
        if let at = model[coll]?.firstIndex(where: { $0.path == path }) { return at }
        model[coll, default: []].append(KayaInstance(path: path))
        return model[coll]!.count - 1
    }

    fileprivate func modelSet(_ coll: UInt64, _ path: [KayaValue], _ key: KayaValue, _ value: Any) {
        touchModel(coll)
        let at = instanceSlot(coll, path)
        // IN PLACE, through the default subscript: `var copy = model[coll]`
        // … `model[coll] = copy` leaves the entry array shared and copies
        // every entry on every insert, which is the other half of the
        // quadratic (docs/deferred.md, the Swift binding's quadratic
        // insert).
        model[coll, default: []][at].set(key, value)
    }

    fileprivate func modelRemove(_ coll: UInt64, _ path: [KayaValue], _ key: KayaValue) {
        touchModel(coll)
        if let at = model[coll]?.firstIndex(where: { $0.path == path }) {
            model[coll, default: []][at].remove(key)
        }
        // The core tears down the copy, taking descendant collection
        // instances with it; the model follows.
        purgeChildren(coll, prefix: path + [key])
    }

    fileprivate func keysOf(_ coll: UInt64, _ path: [KayaValue]) -> [KayaValue] {
        model[coll]?.first { $0.path == path }?.entries.map { $0.key } ?? []
    }

    /// One instance's counter, made if this is the first anyone has asked.
    private func withCounter<R>(
        _ coll: UInt64, _ path: [KayaValue], _ body: (inout Int64) -> R
    ) -> R {
        body(&fresh[coll, default: [:]][path, default: 0])
    }

    /// The next fresh key for one instance: counter+1, and the counter keeps
    /// it.
    fileprivate func mintKey(_ coll: UInt64, _ path: [KayaValue]) -> Int64 {
        withCounter(coll, path) { counter in
            counter += 1
            return counter
        }
    }

    /// An explicit key, shown to the minter on its way into the table.
    fileprivate func absorbKey(_ coll: UInt64, _ path: [KayaValue], _ key: KayaValue) {
        guard case .i64(let n) = key else { return }
        withCounter(coll, path) { counter in counter = max(counter, n) }
    }

    fileprivate func modelMove(
        _ coll: UInt64, _ path: [KayaValue], _ key: KayaValue, _ before: [KayaValue]
    ) {
        touchModel(coll)
        // The same checks the scene makes, made where the guest can see the
        // stack: a missing key or anchor is a guest bug, never a fallback.
        guard let at = model[coll]?.firstIndex(where: { $0.path == path }),
            model[coll]![at].has(key)
        else { preconditionFailure("kaya: move of missing key \(key)") }
        if let anchor = before.first {
            precondition(
                model[coll]![at].has(anchor),
                "kaya: move before missing key \(anchor)")
        }
        model[coll, default: []][at].move(key, before: before.first)
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

    /// Fold an undo's payload into the mirrors this binding keeps. The
    /// payload is core-authoritative, so nothing here re-derives anything.
    ///
    /// NOT INSIDE A TRANSACTION, and it must not be: the core moved
    /// without one, so these writes describe state that is already true
    /// and sending records would apply the undo a second time. The
    /// derived recompute does NOT re-run — whatever the group wrote to a
    /// derived signal is in this same payload.
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
            guard let at = model[order.collection]?.firstIndex(where: { $0.path == order.path })
            else { continue }
            // Position by the payload's list, keeping anything it does
            // not name at the end: the delta describes one instance's
            // whole order, and an entry it never mentions is one this
            // undo did not touch.
            model[order.collection, default: []][at].reorder(order.keys)
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
        widgets += 1
        return KayaNodeHandle(id: widgets)
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
    func build<R>(_ build: (KayaAppTx) throws -> R) rethrows -> R {
        KayaApp.requireAppThread()
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
    /// Register the table's header-click handler at its For — the
    /// handler receives the 0-based column of a sort REQUEST: nothing
    /// has changed on screen; reorder the collection by key and
    /// re-declare the header with columns (docs/tables-plan.md).
    func onSort(_ w: KayaWidget, _ handler: @escaping (KayaAppTx, UInt32) throws -> Void) {
        sortHandlers[w.id] = handler
    }

    /// The same registration for a NESTED For — one table stamped per
    /// entry of the enclosing collection. The handler receives the
    /// clicked copy's keys, outermost first, before the column; hand
    /// them back to `KayaAppTx.columns(_:at:_:_:)` to move that one
    /// copy's indicator (docs/tables-plan.md, dynamic tables).
    func onSort(
        _ n: KayaNodeHandle, _ handler: @escaping (KayaAppTx, [KayaValue], UInt32) throws -> Void
    ) {
        nodeSorts[n.id] = handler
    }

    func onClick(_ w: KayaWidget, _ handler: @escaping (KayaAppTx) throws -> Void) {
        widgetHandlers[w.id] = handler
    }

    /// The registration half of `KayaWidget.onDraw` / `KayaWidget.onTick`.
    /// NOT PUBLIC on purpose: registering the closure and declaring the
    /// policy on the wire are ONE act, and a guest that could do the first
    /// without the second would hold a handler nothing ever calls
    /// (docs/canvas-plan.md §3.2.1).
    fileprivate func registerDraw(
        _ canvas: UInt64, _ f: @escaping (KayaDraw, KayaViewbox, Double) -> Void
    ) {
        draws[canvas] = f
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
        // From here on this thread IS the app thread, and every
        // transaction gate compares against it.
        KayaApp.claimAppThread()
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
            // The core owns the bytes until the next call, so they are copied
            // out here.
            guard let start = record else { continue }
            let buf = [UInt8](UnsafeBufferPointer(start: start, count: Int(size)))
            // THE TWO HISTORY RECORDS ARE READ FIRST, by their own
            // parser: their head is four counts and one flat Values
            // block, so the general parser must never see these bytes.
            // The mirrors are folded HERE, before the handler.
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
            guard let (kind, id, keys, payload, files, clip, tail) = kayaParseOccurrence(buf)
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
            // THE CANVAS'S TWO ASKS ARE ANSWERED HERE AND NEVER MAPPED
            // (docs/canvas-plan.md §3.2.1): the guest registered a
            // drawing-as-a-function-of-size, so this draws it, submits the
            // one record and keeps looping. The transaction is the
            // binding's — a guest opening its own inside a handler is the
            // camouflage tools/check-ambient-tx.sh refuses.
            //
            // ONE CALL SHAPE, decided at registration rather than here: a
            // tick canvas is a redraw canvas too and is asked once, as a
            // draw_requested, before its first frame, so its handler
            // answers that ask with time 0 instead of the canvas staying
            // empty until the clock moves.
            //
            // The keys are not consulted: only a KayaWidget can carry a
            // policy, so a template node's id is never in this table.
            case (UInt16(KAYA_OCCURRENCE_DRAW_REQUESTED), _),
                (UInt16(KAYA_OCCURRENCE_TICK), _):
                if let drawing = draws[id], let size = kayaAssignedSize(tail) {
                    let time = kayaFrameTime(tail)
                    // The size that arrived IS this canvas's viewbox from
                    // here on, so a later plain `draw` uses it too.
                    canvasViewboxes[id] = size
                    let canvas = KayaWidget(id: id)
                    // No `dispatch` wrapper: a drawing handler cannot
                    // throw (the recorder's ops do not), so there is no
                    // error for it to log — the rest of this switch wraps
                    // handlers the guest declared `throws`.
                    build { tx in
                        tx.draw(canvas) { d in drawing(d, size, time) }
                    }
                }
            case (UInt16(KAYA_OCCURRENCE_SORT_REQUESTED), true):
                if let handler = sortHandlers[id] {
                    // The generated parser boxes the column as .i64.
                    let column = UInt32(truncatingIfNeeded: choice)
                    dispatch { try build { tx in try handler(tx, column) } }
                }
            case (UInt16(KAYA_OCCURRENCE_SORT_REQUESTED), false):
                if let handler = nodeSorts[id] {
                    let column = UInt32(truncatingIfNeeded: choice)
                    dispatch { try build { tx in try handler(tx, keys, column) } }
                }
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
            // ordinary widget/node split — one record kind, the key path
            // deciding.
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
    /// thread), dispatching occurrences on the app thread.
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

/// One transaction: everything queued inside build (or a handler) applies
/// atomically when it returns.
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

/// The for-statement tracer over a record collection's rows (the generated
/// `todos.rows` returns one): the loop body runs once, authoring the For's
/// template; the tracer opens the template on the first element and closes it
/// — appending the For widget to the enclosing container's ambient frame —
/// when the loop asks for a second.
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

    // THE ONE CHOKEPOINT. Every write in this file is `tx.<verb>(...)`,
    // so a computed property that checks liveness on the way in guards
    // all of them without touching a callsite, and guards the next one
    // too. A check spread over callsites is a check that gets forgotten,
    // and the failure it guards is SILENT: a write through a Tx that
    // outlived its build vanishes with no error
    // (tools/check-tx-liveness.sh).
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
        // `tx.<verb>(...)` is a MUTATING call, and a get/set property
        // serves one by copying the value out, mutating the copy and
        // writing it back — so every record copied the whole batch built
        // so far, N records costing N²/2 bytes of memcpy. Measured
        // 2026-08-24 at 32,000 inserts: 3070ms with get/set, 16ms
        // yielding (docs/deferred.md, the Swift binding's quadratic
        // insert). `_modify` keeps the ONE chokepoint above intact — do
        // not answer this by checking liveness at the callsites.
        _modify {
            alive()
            yield &storage
        }
    }

    /// A KayaAppTx is valid ONLY inside the build or handler that made it, on
    /// the app thread.
    func alive() {
        precondition(
            !closed,
            "kaya: transaction is over — a tx is only usable inside the build or handler "
                + "that created it; to mutate from a background thread use app.post")
        KayaApp.requireAppThread()
    }

    /// Called by build on the way out, on every path.
    func close() {
        closed = true
    }
    // How to undo this transaction's mirror edits: a snapshot per touched
    // collection / signal, taken on first touch (nil = it did not exist
    // before this transaction).
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

    /// The commit's mirror image: restore every touched mirror entry and drop
    /// the records with the pending registrations.
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
    /// `window`'s ledger (docs/undo-plan.md D2). CALLABLE ANYWHERE IN THE
    /// CHAIN and the marker still rides at the HEAD of the batch.
    ///
    /// WHAT A GROUP MAY HOLD is the reactive half — signal writes and
    /// collection deltas. Anything else (a const property write, creating
    /// a widget, clear, showing a dialog) fails at apply, naming the op.
    /// Each window has its own history; 0 is the primary.
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

    /// Declare the column header bar on a For's container — the widget
    /// forEach returns. One title per column; the row template's root
    /// must be a row of exactly one cell per column, refused loudly
    /// otherwise. Re-call after sorting to move the indicator
    /// (docs/tables-plan.md).
    func columns(_ w: KayaWidget, _ titles: [String], _ sort: KayaSort) {
        // pathLen 0: no key path, so the values are titles alone
        // (docs/tables-plan.md, dynamic tables).
        tx.setColumnHeaders(
            w.id, sort.sorted, sort.direction, UInt32(titles.count), 0,
            titles.map { .str($0) })
    }

    /// Re-declare ONE stamped copy's header bar — the per-copy sort
    /// indicator, addressed by the nested For's template node plus that
    /// copy's keys, outermost first: exactly what its `onSort` handler
    /// was handed. `at: []` re-declares the template-wide bar instead,
    /// for every copy at once.
    ///
    /// The core refuses a keyed re-declaration with no template bar
    /// declared first, and a key path naming no stamped copy.
    func columns(
        _ n: KayaNodeHandle, at path: [KayaValue], _ titles: [String], _ sort: KayaSort
    ) {
        // Keys first, then the titles — TX 45's Values order
        // (docs/tables-plan.md, dynamic tables).
        tx.setColumnHeaders(
            n.id, sort.sorted, sort.direction, UInt32(titles.count), UInt32(path.count),
            path + titles.map { .str($0) })
    }

    func bindText(_ w: KayaWidget, _ s: KayaSignal) {
        tx.bindText(w.id, s.id)
    }

    func setChecked(_ w: KayaWidget, _ checked: Bool) {
        tx.setChecked(w.id, checked)
    }

    /// Set a widget's flex weight within its row/column: 0 is natural size,
    /// positive weights divide the container's leftover main-axis space in
    /// proportion (see Prop::Grow in the core). The declarative spelling is
    /// the `grow:` argument at construction; this is the dynamic path. A
    /// container's inter-child gap (main axis, DIP; the normalized default is
    /// 8).
    func setSpacing(_ w: KayaWidget, _ gap: Double) {
        tx.setSpacing(w.id, gap)
    }

    /// A container's OWN padding: DIP between its bounds and its children,
    /// uniform on all four sides — the window inset one level down
    /// (docs/styling-plan.md D3).
    func setInset(_ w: KayaWidget, _ pad: Double) {
        tx.setInset(w.id, pad)
    }

    /// A container's cross-axis child placement. Containers only; baseline is
    /// rows-only — the scene rejects misuse at the root.
    func setAlign(_ w: KayaWidget, _ align: KayaAlign) {
        tx.setAlign(w.id, align.rawValue)
    }

    /// A container's arrangement axis. The creation kind is its
    /// declarative spelling and this is the dynamic path — a handler's
    /// flip, keyed on nothing about the window
    /// (docs/adaptive-layout-plan.md D2). Containers only.
    func setAxis(_ w: KayaWidget, _ axis: KayaAxis) {
        tx.setAxis(w.id, axis.rawValue)
    }

    /// A widget's SEMANTIC EMPHASIS: destructive/prominent on buttons,
    /// heading/caption on labels — what it means, never how it looks.
    func setRole(_ w: KayaWidget, _ role: KayaRole) {
        tx.setRole(w.id, role.rawValue)
    }

    func setGrow(_ w: KayaWidget, _ weight: Double) {
        tx.setGrow(w.id, weight)
    }

    /// A widget's accessibility IDENTIFIER: a stable authored key that
    /// assistive tooling and UI automation address it by, and which is NEVER
    /// spoken.
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

    /// What ACTIVATING this widget does — the platforms' hint (Apple defines
    /// it as the result of performing an action; Android carries it as the
    /// click action's label). Write a VERB PHRASE.
    func setA11yHint(_ w: KayaWidget, _ hint: String) {
        tx.setA11yHint(w.id, hint)
    }

    /// The SIGNAL-SOURCED forms of the trio — the live zone's half of
    /// KayaTpl's KayaSignal overloads, spelled as bindText is: a spoken
    /// name that follows app state. Since 2026-09-02, uniform across the
    /// nine bindings (docs/deferred.md, the live-zone a11y entry).
    func setA11yId(_ w: KayaWidget, _ s: KayaSignal) {
        tx.bindA11yId(w.id, s.id)
    }

    func setA11yLabel(_ w: KayaWidget, _ s: KayaSignal) {
        tx.bindA11yLabel(w.id, s.id)
    }

    func setA11yHint(_ w: KayaWidget, _ s: KayaSignal) {
        tx.bindA11yHint(w.id, s.id)
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

    // One-shot commands: momentary verbs into widget-owned state, riding the
    // open transaction like any record — the insert and the clear beside it
    // commit together or not at all.

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
    // (docs/ranges-plan.md D1). kaya ships no search.
    //
    // EVERY OFFSET HERE IS A UTF-8 BYTE OFFSET into the widget's current
    // text. Swift is the one guest language whose strings are indexed by
    // NEITHER bytes nor an integer, hence two spellings per verb:
    //
    //   * `Range<String.Index>` + the string they index — what Swift's
    //     own search returns, converted here. REACH FOR THIS ONE.
    //   * `Range<Int>` — the byte-offset floor.
    //
    // The conversion is the trap, not a formality (docs/traps.md).

    /// DECLARE the decorated ranges of a textarea, replacing whatever was
    /// declared before; an empty set is the clear. The ranges are Swift's
    /// own and `text` is the string they index.
    ///
    /// APP-OWNED AND NEVER TRACKED: the first edit of any kind drops the
    /// set, and the app re-declares from the fold `onChange` already
    /// drives. Nothing in kaya adjusts a range across an edit.
    func highlightRanges(
        _ w: KayaWidget, _ ranges: [Range<String.Index>], in text: String
    ) {
        highlightRanges(w, ranges.map { kayaByteRange($0, in: text) })
    }

    /// The byte-offset floor of `highlightRanges(_:_:in:)`: offsets are
    /// UTF-8 byte offsets into the widget's current text. An offset past
    /// the end, or one that splits a character, fails loudly in the CORE
    /// rather than in a backend — one platform aborts the process.
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

    /// Put the textarea's selection at one range (an empty range is a caret).
    /// Same offsets, same validation as `highlightRanges`. REFUSED WHILE THE
    /// USER IS COMPOSING through an input method, in every backend, and the
    /// refusal is a no-op rather than an error: composition state is on no
    /// kaya channel, so an app cannot avoid the race (docs/deferred.md).
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
    /// and `.caption` are the two that fit a label, and each is a
    /// semantic fact (the platform's heading style AND the trait
    /// assistive users skim by), not a font size.
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

    /// A label wearing the heading role, in one word (the h1 tradition):
    /// the platform's heading text style AND the accessibility heading
    /// trait, and on a grouped screen the section-header seat.
    func heading(
        _ text: String? = nil, bind: KayaSignal? = nil, grow: Double? = nil
    ) -> KayaWidget {
        label(text, bind: bind, role: .heading, grow: grow)
    }

    /// A label wearing the caption role: the platform's footnote tier
    /// under the content it explains, and on a grouped screen the
    /// section-footer seat.
    func caption(
        _ text: String? = nil, bind: KayaSignal? = nil, grow: Double? = nil
    ) -> KayaWidget {
        label(text, bind: bind, role: .caption, grow: grow)
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

    /// A drawing surface. `viewbox` is the coordinate system the ops are
    /// written in AND the canvas's natural size in points, which is what
    /// keeps one op stream identical on five platforms
    /// (docs/canvas-plan.md §3.2). Declare what it draws with `draw`;
    /// until then it is present and empty.
    func canvas(_ viewbox: KayaViewbox, grow: Double? = nil) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_CANVAS))
        // The viewbox rides the DRAWING on the wire, not a prop, so a
        // canvas with no declaration yet has nothing to be inconsistent
        // about; the guest side remembers it so a redraw in a later
        // handler does not repeat it.
        app.canvasViewboxes[w.id] = viewbox
        if let grow { setGrow(w, grow) }
        return w
    }

    /// DECLARE the whole drawing on a canvas, replacing whatever was
    /// declared before. The closure reads as immediate-mode drawing and
    /// records: one atomic record is submitted when it returns.
    func draw(_ w: KayaWidget, _ body: (KayaDraw) -> Void) {
        guard let viewbox = app.canvasViewboxes[w.id] else {
            fatalError(
                "kaya: draw on a widget that is not a canvas this app declared — a "
                    + "drawing is a declaration against the canvas it draws on "
                    + "(docs/canvas-plan.md §2.1)")
        }
        let d = KayaDraw(viewbox: viewbox)
        body(d)
        tx.setDrawing(
            w.id, .f64(viewbox.w), .f64(viewbox.h), UInt32(d.ops.count), 0, d.ops)
    }

    /// Re-declare ONE stamped copy's drawing, addressed by the canvas
    /// template node plus that copy's keys, outermost first. `at: []`
    /// re-declares the drawing every copy is born with, which is what
    /// `KayaTpl.canvas` spells at declaration time
    /// (docs/canvas-plan.md §3.1).
    func draw(
        _ n: KayaNodeHandle, at path: [KayaValue], _ viewbox: KayaViewbox,
        _ body: (KayaDraw) -> Void
    ) {
        let d = KayaDraw(viewbox: viewbox)
        body(d)
        // Keys first, then the op stream — TX 46's Values order.
        tx.setDrawing(
            n.id, .f64(viewbox.w), .f64(viewbox.h), UInt32(d.ops.count),
            UInt32(path.count), path + d.ops)
    }

    /// A slider over min...max at value, with its change handler co-located.
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
    /// decodes natively, and decode failure renders the placeholder, never a
    /// crash.
    func image(
        _ source: Data? = nil, bind: KayaSignal? = nil, grow: Double? = nil
    ) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_IMAGE))
        if let source { setSource(w, source) }
        if let bind { bindSource(w, bind) }
        if let grow { setGrow(w, grow) }
        return w
    }

    /// The ASSET form of the source slot: the same image, with the picture
    /// NAMED rather than read — `tx.image(try KayaAsset("icons/kaya-mark.png"))`.
    /// THE BYTES NEVER ENTER THE GUEST'S HEAP; `appIdentity(_:icon:)`'s
    /// route, verbatim.
    func image(_ source: KayaAsset, grow: Double? = nil) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_IMAGE))
        tx.setSource(w.id, source.blob())
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

    // Every derived signal rooted at this collection, recomputed and written
    // into this transaction.
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
    /// back. ONE COUNTER PER COLLECTION INSTANCE, starting at 0; the
    /// minted key is `.i64` and is counter+1. MIXING IS SAFE BY
    /// ABSORPTION — an explicit `insert` whose key is an I64 at or above
    /// the counter carries it up — and NO DECREMENT IS EXPRESSIBLE, so a
    /// history walk never moves the counter and an abandoned transaction
    /// does not move it back.
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

    /// Repositions an entry before another's: order is collection data, so
    /// the model reorders and the wire carries the same keys-only delta.
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

    /// The record-time mirror-read guard: a template body records once and
    /// the core replays it — a model read inside one bakes this moment's data
    /// into every future stamp, silently dead.
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

    /// The minting insert every typed surface's `insertFresh` lowers to: take
    /// the instance's next key, insert under it, hand it back.
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

    /// Request a modal alert (the request/result grammar), named arguments as
    /// the Swift spelling: `tx.showAlert(title: "delete item?", message: "…",
    /// actions: ["Delete", "Archive"], cancel: "Keep") { tx, choice in … }`.
    /// The result handler rides the REQUEST (the widget-handler precedent)
    /// and retires with its one answer — choice is an action index (0 or 1)
    /// or KAYA_ALERT_CHOICE_CANCEL, every platform-native dismissal.
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
    /// carries handles you redeem later (DESIGN.md, File dialogs). `filters`
    /// is advisory on every platform. `onResult` fires exactly once and
    /// retires with its answer; CANCEL IS THE EMPTY LIST.
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

    /// Ask the platform WHERE TO SAVE. The picker's twin, on the same
    /// grammar and out of the same one-live-dialog slot. CANCEL IS `nil`.
    ///
    /// `suggestedName` is the name the dialog OPENS with and every
    /// platform guarantees nothing about it: READ THE NAME YOU GOT.
    ///
    /// WHAT YOU GET BACK OPENS EMPTY: a save destination may not exist
    /// yet, so the handle's open CREATES — `FILE_MODE_WRITE` succeeds and
    /// yields an empty file on every platform (docs/save-plan.md D1).
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

    /// Begin a clip: fill in as many representations as the app wants
    /// to offer, and send() puts it on the system clipboard.
    func copy() -> KayaCopyRef {
        KayaCopyRef(tx: self)
    }

    /// Begin the privileged read — THE ONE NAMED FOR WHAT IT IS rather
    /// than for pasting. The platforms have deliberately made it
    /// expensive (DESIGN.md, and docs/clipboard-plan.md): reach for it to
    /// detect a URL or import, never to implement Paste — that is the
    /// Paste command, and it is free.
    func readClipboard() -> KayaClipReadRef {
        KayaClipReadRef(tx: self, id: app.allocClipboardRead())
    }

    /// Declare what a widget takes from a paste — the closed kinds by
    /// name ("text", "html", "image", "files") plus any custom format
    /// ids. It drives whether Paste is live while this widget is focused,
    /// filters what reaches the paste hook, and on Android IS the native
    /// registration. A widget that declares NOTHING gets the platform's
    /// own insertion, which is why a plain text editor writes none of
    /// this and has working cut, copy and paste.
    func setAccepts(_ w: KayaWidget, _ kinds: [String]) {
        tx.setAccepts(w.id, kayaAcceptList(kinds))
    }

    /// Take pasted content at a live widget. COSTS NOTHING ON ANY PLATFORM,
    /// unlike readClipboard: a paste is a user gesture, so it is its own
    /// authorisation.
    func onPaste(
        _ w: KayaWidget,
        _ handler: @escaping (KayaAppTx, KayaRepresentation) throws -> Void
    ) {
        app.onPaste(w, handler)
    }

    /// A paste onto a stamped copy: the handler also receives the copy's
    /// key path, outermost first. AND ONLY FIRES FOR A COPY WHOSE
    /// TEMPLATE DECLARED WHAT IT TAKES (`KayaTpl.setAccepts`) — every
    /// backend hands a paste to the platform's own insertion when the
    /// target's accept list is empty.
    func onPaste(
        _ n: KayaNodeHandle,
        _ handler: @escaping (KayaAppTx, [KayaValue], KayaRepresentation) throws -> Void
    ) {
        app.onPaste(n, handler)
    }

    /// REQUEST the app's brand accent (docs/styling-plan.md D1/D2): one
    /// packed sRGB hex (0xRRGGBB) is the whole call for most apps.
    /// `light:`/`dark:` are the per-appearance overrides; whichever you
    /// leave out is filled from `seed`. You never write a foreground and
    /// never write contrast variants — the core derives them.
    ///
    /// SET ONCE, BEFORE THE FIRST MOUNT: the root refuses a second write
    /// and a late one.
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
    /// one family name is the whole call. THE FAMILY, NEVER THE SCALE.
    ///
    /// SET ONCE, BEFORE THE FIRST MOUNT, like `brandAccent`.
    ///
    /// `platforms:` rows TRAVEL UNRESOLVED, so each backend picks its
    /// own. It is `KeyValuePairs` and not a `Dictionary` for two measured
    /// reasons: a Dictionary is unordered, so the same guest would write
    /// different bytes on different runs, and it would swallow a repeated
    /// platform in Swift's own words where the root refuses it in kaya's.
    ///
    /// A FAMILY A PLATFORM DOES NOT HAVE leaves that platform's own
    /// typeface in place, deliberately and silently: every font API
    /// renders SOMETHING for a name it cannot match (Apple's falls
    /// through to Helvetica — measured), so each lowering gates on the
    /// family being installed. `SF Pro` and `New York` are not reachable
    /// by family name — declare none to get the system typeface.
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

    /// The ASSET form of the font slot: the same call, with the font NAMED
    /// rather than read — `tx.brandTypeface("Sora", font: try
    /// KayaAsset("fonts/sora-wght.ttf"))`. THE BYTES NEVER ENTER THE GUEST'S
    /// HEAP.
    func brandTypeface(
        _ family: String,
        platforms: KeyValuePairs<KayaPlatform, String> = [:],
        font: KayaAsset
    ) {
        var pairs: [KayaValue] = []
        for (platform, name) in platforms {
            pairs.append(.i64(platform.rawValue))
            pairs.append(.str(name))
        }
        tx.setBrandTypeface(1, .str(family), pairs, .blob(font.blob()))
    }

    /// DECLARE the app's identity (docs/app-identity-plan.md): the name
    /// it goes by and the picture that stands for it, as the bytes of one
    /// image file. `icon:` left out is the name-only declaration. Send a
    /// PNG; each lowering converts, and no platform-specific artwork
    /// rides the wire.
    ///
    /// SET ONCE, BEFORE THE FIRST MOUNT: the root refuses a second write,
    /// a late one and an empty name. THE BYTES ARE NEVER INSPECTED
    /// between here and the platform's own decoder.
    func appIdentity(_ name: String, icon: Data? = nil) {
        // The icon SLOT rides either way and the mask is what says
        // whether it means anything — the brand mask's discipline, and
        // the reason this record's field count never varies with the
        // payload.
        tx.setAppIdentity(
            icon == nil ? 0 : 1, .str(name),
            icon.map { .blob(kayaRegisterBlob($0)) } ?? .str(""))
    }

    /// The ASSET form of the icon slot: the same declaration, with the mark
    /// NAMED rather than read. THE BYTES NEVER ENTER THE GUEST'S HEAP.
    func appIdentity(_ name: String, icon: KayaAsset) {
        tx.setAppIdentity(1, .str(name), .blob(icon.blob()))
    }

    /// Create an auxiliary window (capability-gated: phone hosts reject at
    /// the root); materializes hidden, mountIn presents.
    func createWindow(
        _ id: UInt64, title: String? = nil, width: Double? = nil,
        height: Double? = nil, vetoClose: Bool? = nil, dirty: Bool? = nil,
        panes: UInt32? = nil, sectionsPresentation: Int64? = nil,
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
            vetoClose: vetoClose, dirty: dirty, panes: panes,
            sectionsPresentation: sectionsPresentation, inset: inset,
            onCloseRequested: onCloseRequested, onClosed: onClosed,
            onUndone: onUndone, onRedone: onRedone,
            menus: menus)
    }

    /// Set a window's attributes in one construct — the attribute set is
    /// EXACTLY createWindow's (a window's attributes ride its window
    /// construct; the primary differs only in having no creation moment).
    ///
    /// `dirty:` says this surface holds UNSAVED WORK and each backend
    /// shows its platform's own affordance (docs/dirty-plan.md D2/D4).
    /// STATE, NOT CHROME: the `title:` you declared is LEFT ALONE, and it
    /// ARMS NOTHING — the close confirmation is `vetoClose:` plus a
    /// dialog, yours to compose.
    ///
    /// `inset:` is this window's CONTENT INSET in layout units — LAYOUT,
    /// not appearance (docs/styling-plan.md D3). 16 unless you say
    /// otherwise; 0 is full bleed. A platform's SAFE AREA is a separate
    /// fact and is not removed by it.
    ///
    /// `panes:` is the CEILING on how many of this window's stack entries
    /// present side by side — 1 is the serial stack, 2 and 3 are columns on
    /// a window wide enough, the shallowest shed first as it narrows
    /// (docs/multicolumn-plan.md carries the ruling and the measured
    /// mechanics). There is deliberately no argument for WHICH entries show
    /// — the stack's order is the priority order — and the live count is
    /// the platform's own judgment where it has one. The root refuses 0 and
    /// anything above 3.
    func window(
        _ id: UInt64 = 0, title: String? = nil, width: Double? = nil,
        height: Double? = nil, vetoClose: Bool? = nil, dirty: Bool? = nil,
        panes: UInt32? = nil, sectionsPresentation: Int64? = nil,
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
        if let panes { tx.setWindowPanes(id, Int64(panes)) }
        if let sectionsPresentation {
            tx.setWindowSectionsPresentation(id, sectionsPresentation)
        }
        if let inset { tx.setWindowInset(id, inset) }
        if let onCloseRequested { app.onCloseRequested(id, onCloseRequested) }
        if let onClosed { app.onWindowClosed(id, onClosed) }
        // The history handlers ride the window construct because the LEDGER
        // is per window: one ordered history per surface, so the registration
        // scopes to the thing that owns it.
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

    /// The tail every menu-item CONSTRUCTOR shares. The symbol is a
    /// REQUIRED positional, so a constructor added later cannot reach the
    /// tail without deciding about the slot. Two kinds are deliberately
    /// outside it: `separator()`, which takes no props at all, and the
    /// REOPENING `menu(_ item:…)`, which has no create to share.
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
    static let roleUndo = "undo"
    static let roleRedo = "redo"

    /// An action — a leaf command firing exactly one menu_activated
    /// occurrence (menu click OR its shortcut: ONE occurrence, one dispatch
    /// path; the handler rides the declaration and covers both).
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
    /// (tx.contextCatalog + KayaTpl.contextMenu) reports the copy's key path,
    /// outermost first — the keys ARE the noun the command acts on.
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
    /// items:).
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

    /// A context menu on a LIVE widget: the same item vocabulary scoped to a
    /// NOUN, with the platform's own gesture (right-click, long-press).
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

    /// Pop the window's top navigation entry and forget its tree — also the
    /// back-veto grammar's confirmation after onBackRequested.
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

    /// The raw Text write on a node — PRIVATE, and that is the point. The
    /// live zone's `setText` is a WIDGET VERB the sugar sweep requires of
    /// every binding (tools/check-sugar-surface.sh's check_range_verb);
    /// this one is the floor spelling of a prop, and only the receiver's
    /// type tells them apart, which no sweep can see. Hiding it means the
    /// floor spelling stops existing (docs/tpl-props-plan.md F3).
    private func setText(_ n: KayaNodeHandle, _ text: String) {
        tx.tx.setText(n.id, text)
    }

    /// Bind text to the element of the enclosing For, `level` Fors up
    /// (0 = nearest).
    func bindTextElement(_ n: KayaNodeHandle, level: UInt32 = 0) {
        tx.tx.bindTextElement(n.id, level: level)
    }

    /// Weight a template node within its stamped row or column — the
    /// template twin of `KayaAppTx.setGrow`. A template `scroll` needs
    /// it: an unconstrained viewport hugs its content. Spacing and align
    /// have no Swift spelling in this zone at all and stay ledgered
    /// (docs/deferred.md).
    func setGrow(_ n: KayaNodeHandle, _ weight: Double) {
        tx.tx.setGrow(n.id, weight)
    }

    /// A stamped copy's accessibility IDENTIFIER — the template twin of
    /// `KayaAppTx.setA11yId`, universal in this zone as in that one. The
    /// argument's type picks the source: a String gives EVERY copy the
    /// same key, which is legal (nothing deduplicates ids and the harness
    /// addresses by kind#index), while the row's own field is the
    /// spelling when automation must tell two copies apart.
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
    /// the platform derives from the copy's own content. THE ROW'S OWN
    /// FIELD IS THE CASE THIS EXISTS FOR: it is the only source that
    /// makes two copies say different things.
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
    /// `KayaAppTx.setA11yHint`. Write a VERB PHRASE. Activation kinds
    /// only, and the restriction is the ROOT'S rather than this type's: a
    /// hint on a template label dies in `check_prop` at DECLARE time.
    func setA11yHint(_ n: KayaNodeHandle, _ hint: String) {
        tx.tx.setA11yHint(n.id, hint)
    }

    func setA11yHint(_ n: KayaNodeHandle, _ s: KayaSignal) {
        tx.tx.bindA11yHint(n.id, s.id)
    }

    func setA11yHint(_ n: KayaNodeHandle, level: UInt32 = 0, _ f: KayaField<String>) {
        tx.tx.bindA11yHintElement(n.id, level: level, field: f.index)
    }

    /// Declare what a stamped copy takes from a paste — the template twin
    /// of `KayaAppTx.setAccepts`. Entry and textarea only; the root
    /// rejects it elsewhere, at declaration rather than per stamp.
    ///
    /// THIS IS WHAT MAKES A STAMPED PASTE HAPPEN AT ALL: every backend
    /// gates the paste occurrence on the focused widget's accept list and
    /// falls back to the platform's own insertion when it is empty
    /// (swift/KayaSwiftUI.swift, `node.accepts.isEmpty`). CONST ONLY — on
    /// Android the list IS the native registration.
    func setAccepts(_ n: KayaNodeHandle, _ kinds: [String]) {
        tx.tx.setAccepts(n.id, kayaAcceptList(kinds))
    }

    /// What a stamped copy MEANS — the template twin of
    /// `KayaAppTx.setRole`. Semantic emphasis, never appearance. CONST
    /// ONLY, `setAccepts`'s rule: what a copy means is a fact about the
    /// PROTOTYPE. The kind restriction is the ROOT'S, refused in
    /// `check_prop` at DECLARE time.
    func setRole(_ n: KayaNodeHandle, _ role: KayaRole) {
        tx.tx.setRole(n.id, role.rawValue)
    }

    /// A stamped CONTAINER's own padding, in DIP between its bounds and its
    /// children — the template twin of `KayaAppTx.setInset`.
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

    /// A label wearing the heading role — the h1 tradition, stamped.
    func heading(_ text: String) -> KayaNodeHandle {
        let n = label(text)
        setRole(n, .heading)
        return n
    }

    func heading(_ s: KayaSignal) -> KayaNodeHandle {
        let n = label(s)
        setRole(n, .heading)
        return n
    }

    func heading(_ f: KayaField<String>) -> KayaNodeHandle {
        let n = label(f)
        setRole(n, .heading)
        return n
    }

    /// A label wearing the caption role — the footnote under the content
    /// it explains, stamped.
    func caption(_ text: String) -> KayaNodeHandle {
        let n = label(text)
        setRole(n, .caption)
        return n
    }

    func caption(_ s: KayaSignal) -> KayaNodeHandle {
        let n = label(s)
        setRole(n, .caption)
        return n
    }

    func caption(_ f: KayaField<String>) -> KayaNodeHandle {
        let n = label(f)
        setRole(n, .caption)
        return n
    }

    /// A button with its caption, in the blueprint: the template twin of
    /// `KayaAppTx.button(_:onClick:grow:)`.
    func button(_ text: String) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_BUTTON))
        setText(n, text)
        return n
    }

    func button(_ s: KayaSignal) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_BUTTON))
        tx.tx.bindText(n.id, s.id)
        return n
    }

    /// A button captioned from the row's OWN field — the "Delete <that row's
    /// title>" shape, which only this zone can spell.
    func button(_ f: KayaField<String>) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_BUTTON))
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

    /// A single-line text field per stamped copy. UNCONTROLLED, which is why
    /// the primary form takes no source at all: the copy owns its text, each
    /// edit arrives naming this node AND the copy's key path, and the app
    /// folds it into its own state.
    func entry(
        onChange: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        textFieldOf(UInt32(KAYA_KIND_ENTRY), onChange)
    }

    /// An entry seeded from an addressable source: the argument's type
    /// picks it, as it does for `label`.
    ///
    /// HOW LONG THE SOURCE LASTS DIFFERS BY SOURCE, and the difference is
    /// the protocol's. A String is ONE write at declaration, so the user
    /// owns the field from the first keystroke. A signal or a field stays
    /// LIVE: a later write to that signal — or to that field of that row
    /// — REPLACES whatever the user has typed. There is no "seed once and
    /// let go" arm on the wire.
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

    /// The unsourced half of both text kinds: the widget and its handler.
    private func textFieldOf(
        _ kind: UInt32, _ onChange: ((KayaAppTx, [KayaValue], String) throws -> Void)?
    ) -> KayaNodeHandle {
        let n = widget(kind)
        if let onChange { tx.app.onChange(n, onChange) }
        return n
    }

    /// A progress bar whose fraction comes from an addressable source —
    /// `t.progress(row.done)` is the per-row case this zone exists for.
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
    /// co-located. THE RANGE DESCRIBES THE PROTOTYPE and stays a pair of
    /// constants; the POSITION takes a source. A move where the position
    /// came from the row's own field does NOT write the field back — the
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

    /// A dropdown in the blueprint: the option list is the BLUEPRINT'S, the
    /// choice is the row's. `selected` is the 0-based index and takes a
    /// source; `onSelect` receives the copy's key path and each USER pick's
    /// new index.
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
    /// its handler. The options are LABEL CHILDREN of the prototype, so
    /// every stamped copy offers the same list: children are structure,
    /// and structure belongs to the blueprint. Only the selected index
    /// can be the row's (docs/sugar-pass-plan.md §2).
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

    /// A canvas per stamped copy — a sparkline in a table cell, which is
    /// the case set_drawing grew its keys-first addressing for
    /// (docs/canvas-plan.md §3.1). The drawing is declared with the node,
    /// so every copy is born with it; `KayaAppTx.draw(_:at:_:_:)`
    /// re-declares one copy's afterwards.
    func canvas(_ viewbox: KayaViewbox, _ body: (KayaDraw) -> Void) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_CANVAS))
        let d = KayaDraw(viewbox: viewbox)
        body(d)
        tx.tx.setDrawing(
            n.id, .f64(viewbox.w), .f64(viewbox.h), UInt32(d.ops.count), 0, d.ops)
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
    /// columns — each column takes its NATURAL width, aligned across rows.
    /// The column count describes the PROTOTYPE, so it is a plain
    /// constant rather than a source.
    func grid(columns: Int, @KayaNodeChildren _ children: () -> Void) -> KayaNodeHandle {
        let n = nodeContainerOf(UInt32(KAYA_KIND_GRID), children)
        tx.tx.setColumns(n.id, Double(columns))
        return n
    }

    /// A spacer: PURE SUGAR for an empty grown column — it consumes the
    /// leftover main-axis space between its siblings in every stamped copy.
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

    /// Attach a live-built context catalog (tx.contextCatalog) to a template
    /// node: every stamped copy shows the same catalog, and each activation
    /// carries that copy's key path — the keys ARE the noun (received by the
    /// node-flavor handlers).
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

    /// Declare a collection of T records inside this template; the
    /// struct is the schema. A nested collection may only be declared in
    /// the template scope, so a table whose rows carry named fields
    /// needs the constructor here too (docs/deferred.md, the
    /// nested-record-collection gap). IN THIS FILE because `tx` is
    /// fileprivate storage — the body is KayaRecords' extension.
    func collection<T: KayaRecord>(of type: T.Type) -> KayaRecordCollection<T> {
        tx.collection(of: type)
    }

    /// A nested For as a child: forEach whose body keeps no handles —
    /// the template twin of `KayaAppTx.each(_:_:)`, and the common case
    /// once the handles a template owes the outside are assigned to the
    /// scene's own bindings rather than threaded back through R.
    func each(_ c: KayaCollection, _ body: (KayaTpl) -> Void) -> KayaNodeHandle {
        forEach(c) { body($0) }.0
    }

    /// Declare the header bar of a NESTED For — the template twin of
    /// `KayaAppTx.columns(_:_:_:)`. One declaration, every stamped copy,
    /// each copy sorting without disturbing its siblings.
    ///
    /// CALL IT RIGHT AFTER `forEach`/`each` RETURNS, in the same
    /// template body: the nested For folds into the parent at its
    /// TemplateEnd, and this op is resolved against that OPEN parent
    /// scope — a grandparent's is not expressible (docs/tables-plan.md,
    /// MEASURED IN SLICE 1). Answer its clicks with
    /// `KayaApp.onSort(_ n:_:)`; move one copy's indicator with
    /// `KayaAppTx.columns(_:at:_:_:)`.
    func columns(_ n: KayaNodeHandle, _ titles: [String], _ sort: KayaSort) {
        // pathLen 0 against a TEMPLATE NODE: the bar for every copy —
        // the id's zone is what tells this from the live case
        // (docs/tables-plan.md, dynamic tables).
        tx.tx.setColumnHeaders(
            n.id, sort.sorted, sort.direction, UInt32(titles.count), 0,
            titles.map { .str($0) })
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
