// kaya's idiomatic surface for Swift, over the generated wire vocabulary
// (KayaWire.swift) and kaya.h via the bridging header.

internal import CKaya
import Foundation

/// The header bar's sort indicator (docs/tables-plan.md): which column
/// shows it, in which direction. The platform never sorts; a header
/// click only asks.
public struct KayaSort: Sendable {
    let sorted: UInt32
    let direction: UInt32

    /// The no-indicator bar.
    public static let none = KayaSort(sorted: 0xFFFF_FFFF, direction: 0)

    /// Ascending on `column` (0-based, in the declared order).
    public static func asc(_ column: UInt32) -> KayaSort {
        KayaSort(sorted: column, direction: 0)
    }

    /// Descending on `column`.
    public static func desc(_ column: UInt32) -> KayaSort {
        KayaSort(sorted: column, direction: 1)
    }
}

public struct KayaSignal {
    let id: UInt64

    /// Mint a derived signal: recomputed when the source is written, the
    /// write batched into the same transaction.
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

    /// The derive vocabulary (the cross-language canon: eq, ne, lt, …).
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

    public static func == <V: KayaValueConvertible>(s: KayaSignal, v: V) -> KayaSignal {
        s.eq(v.kayaValue)
    }

    public static func != <V: KayaValueConvertible>(s: KayaSignal, v: V) -> KayaSignal {
        s.ne(v.kayaValue)
    }

    public static func < <V: KayaValueConvertible>(s: KayaSignal, v: V) -> KayaSignal {
        s.lt(v.kayaValue)
    }

    public static func > <V: KayaValueConvertible>(s: KayaSignal, v: V) -> KayaSignal {
        s.gt(v.kayaValue)
    }

    public static func <= <V: KayaValueConvertible>(s: KayaSignal, v: V) -> KayaSignal {
        s.le(v.kayaValue)
    }

    public static func >= <V: KayaValueConvertible>(s: KayaSignal, v: V) -> KayaSignal {
        s.ge(v.kayaValue)
    }
}

/// The plain values the comparison operators accept on their right:
/// `stepCount == 1` wraps into the wire scalar itself.
public protocol KayaValueConvertible {
    var kayaValue: KayaValue { get }
}

extension Int: KayaValueConvertible {
    public var kayaValue: KayaValue { .i64(Int64(self)) }
}

extension Int64: KayaValueConvertible {
    public var kayaValue: KayaValue { .i64(self) }
}

extension String: KayaValueConvertible {
    public var kayaValue: KayaValue { .str(self) }
}

extension Bool: KayaValueConvertible {
    public var kayaValue: KayaValue { .bool(self) }
}

extension Double: KayaValueConvertible {
    public var kayaValue: KayaValue { .f64(self) }
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

/// Register bulk payload bytes with the core: one copy into core-owned
/// memory, returning the u64 handle the next submit consumes.
func kayaRegisterBlob(_ data: Data) -> UInt64 {
    data.withUnsafeBytes { raw in
        kaya_blob_register(raw.bindMemory(to: UInt8.self).baseAddress, UInt(raw.count))
    }
}

/// A container's cross-axis child placement (the align spec enum; wire
/// values pinned by the generated constants).
public enum KayaAlign: Int64 {
    case start = 0
    case center = 1
    case end = 2
    case stretch = 3
    case baseline = 4
}

/// What a filled container's surface means (docs/tints-plan.md T1): each
/// backend draws it in the platform's own fill and foreground pair.
public enum KayaTint: Int64 {
    case accent = 1
    case success = 2
    case warning = 3
    case critical = 4
    case neutral = 5
}

/// A container's ARRANGEMENT AXIS: identity is the creation kind
/// (`row#N` stays `row#N` whatever this says), presentation is the prop
/// (docs/adaptive-layout-plan.md D1/D2).
public enum KayaAxis: Int64 {
    case horizontal = 0
    case vertical = 1
}

/// A canvas's coordinate system AND its natural size in
/// device-independent points (docs/canvas-plan.md §3.2).
public struct KayaViewbox {
    public let w: Double
    public let h: Double

    public init(_ w: Double, _ h: Double) {
        self.w = w
        self.h = h
    }
}

/// The paint ROLE an op names. Never RGB: the roles resolve in the core
/// per appearance (docs/canvas-plan.md §3.4). The numbers come from the
/// core's own header, never a hand-written copy
/// (tools/check-symbol-parity.py).
public enum KayaPaint {
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
public enum KayaFillRule {
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
public enum KayaTextAlign {
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
public enum KayaTextBaseline {
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
/// closes (docs/canvas-plan.md §2.1).
public final class KayaDraw {
    /// The box this drawing is written in.
    let viewbox: KayaViewbox
    fileprivate var ops: [KayaValue] = []

    fileprivate init(viewbox: KayaViewbox) {
        self.viewbox = viewbox
    }

    private func op(_ code: Int32, _ operands: KayaValue...) -> KayaDraw {
        ops.append(.i64(Int64(code)))
        ops.append(contentsOf: operands)
        return self
    }

    /// Start a subpath at (x, y).
    @discardableResult
    public func moveTo(_ x: Double, _ y: Double) -> KayaDraw {
        op(KAYA_DRAW_MOVE_TO, .f64(x), .f64(y))
    }

    /// Extend the current subpath to (x, y).
    @discardableResult
    public func lineTo(_ x: Double, _ y: Double) -> KayaDraw {
        op(KAYA_DRAW_LINE_TO, .f64(x), .f64(y))
    }

    /// Close the current subpath.
    @discardableResult
    public func close() -> KayaDraw {
        op(KAYA_DRAW_CLOSE)
    }

    /// `moveTo` the first point and `lineTo` the rest.
    @discardableResult
    public func polyline(_ points: [(Double, Double)]) -> KayaDraw {
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
    /// device-independent points and does NOT carry the viewbox stretch
    /// (§3.2).
    @discardableResult
    public func stroke(_ paint: KayaPaint, width: Double) -> KayaDraw {
        op(KAYA_DRAW_STROKE, .i64(paint.wire), .f64(width))
    }

    /// Fill the built path and clear it.
    @discardableResult
    public func fill(_ paint: KayaPaint, rule: KayaFillRule = .nonzero) -> KayaDraw {
        op(KAYA_DRAW_FILL, .i64(paint.wire), .i64(rule.wire))
    }

    /// Select the face for subsequent text ops. `asset` is an ordinary
    /// asset name; `""` is kaya's own embedded default face (§4.2).
    /// `size` is in device-independent points.
    @discardableResult
    public func font(size: Double, asset: String = "", weight: Int64 = 400) -> KayaDraw {
        op(KAYA_DRAW_FONT, .str(asset), .f64(size), .i64(weight))
    }

    /// Draw ONE LINE with its anchor at (x, y). A line break in `s` is
    /// refused by the core (§3.3).
    @discardableResult
    public func text(
        _ x: Double, _ y: Double, _ s: String, _ paint: KayaPaint,
        align: KayaTextAlign = .start, baseline: KayaTextBaseline = .alphabetic
    ) -> KayaDraw {
        op(
            KAYA_DRAW_TEXT, .f64(x), .f64(y), .i64(paint.wire), .i64(align.wire),
            .i64(baseline.wire), .str(s))
    }
}

/// SEMANTIC EMPHASIS (docs/styling-plan.md D4): what a widget MEANS,
/// never how it looks. Destructive and prominent are BUTTON emphasis,
/// heading and caption are LABEL hierarchy; the root refuses the other
/// combinations at declare time.
/// An alert's three outcomes: the action the user pressed, by its slot,
/// or the cancel every platform-native dismissal answers
/// (DESIGN.md, Binding conventions — a closed vocabulary is a type).
public enum KayaAlertChoice: UInt32, Sendable {
    case action0 = 0
    case action1 = 1
    case cancel = 0xFFFF_FFFF

    /// The wire's number, refused naming one this build does not know.
    static func fromWire(_ code: UInt32) -> KayaAlertChoice {
        guard let known = KayaAlertChoice(rawValue: code) else {
            fatalError(
                "kaya: an alert result carries choice \(code), which this build does not know")
        }
        return known
    }
}

/// A notification's two outcomes (docs/tasks-s3-plan.md N1). Dismissal
/// is not one of them: two platforms never report it.
enum KayaNotificationOutcome: UInt32 {
    case activated = 0
    case refused = 1

    static func fromWire(_ code: UInt32) -> KayaNotificationOutcome {
        guard let known = KayaNotificationOutcome(rawValue: code) else {
            fatalError(
                "kaya: a notification result carries outcome \(code), which this build does not know")
        }
        return known
    }

    /// The wire's own word for it, which the drop announcement names.
    var name: String { self == .activated ? "activated" : "refused" }
}

/// How a picked file is re-opened (crates/kaya/src/spec.rs decides the
/// numbers; tools/check-file-modes.py holds them together).
public enum KayaFileMode: UInt32 {
    case read = 0
    case write = 1
    case readWrite = 2
}

/// How a window presents its sections.
public enum KayaSectionsPresentation: Int64 {
    case auto = 0
    case bar = 1
    case sidebar = 2
}

/// The app's OWN light/dark choice, applied process-wide from the
/// default window (docs/tasks-s2b-plan.md R1-R3).
public enum KayaAppearance: Int64 {
    case system = 0
    case light = 1
    case dark = 2
}

/// The height the phones open a sheet at (docs/sheet-plan.md §1.4); the
/// desktops have nothing to say and ignore it.
public enum KayaDetent: Int64 {
    case medium = 1
    case large = 2
}

/// THE CLOSED MENU-ROLE VOCABULARY (DESIGN.md, Menus;
/// crates/kaya/src/scene.rs MENU_ROLES). `settings` is placed in the
/// application menu on macOS and left where the app declared it
/// everywhere else. Cut/copy/paste are THE GESTURE LAYER: they lower to
/// the platform's own, act on the FOCUSED widget, and work out their own
/// enablement. Undo/redo ask the focused widget's own history before the
/// app's ledger (docs/undo-plan.md D6).
public enum KayaMenuRole: String {
    case settings
    case cut
    case copy
    case paste
    case undo
    case redo
}

public enum KayaRole: Int64 {
    /// An action whose press destroys something.
    case destructive = 1
    /// THE primary action — one per dialog's worth of emphasis.
    case prominent = 2
    /// A text hierarchy heading — the platform's heading text style AND
    /// the accessibility heading trait.
    case heading = 3
    /// A heading's counterpart under the content it explains: the
    /// platform's caption/footnote tier.
    case caption = 4
    /// An action at low emphasis: a row's accessory (Details, Open).
    /// Buttons only.
    case plain = 5
    /// A checkbox drawn as the platform's SWITCH and reporting its trait
    /// (docs/tasks-s2-plan.md T1): a setting that takes effect at once.
    /// Backticked because `switch` is a Swift keyword — the NAME is the
    /// role's, the backticks are the language's.
    case `switch` = 6
    /// A label drawn as the platform's LINK, opening its `href` through
    /// the platform's own opener (docs/tasks-s2-plan.md T3).
    case link = 7
    /// A row drawn as ONE text field in the platform's own style around its
    /// field and buttons (docs/composer-plan.md §4).
    case composer = 8
}

/// WHICH PLATFORM A PER-PLATFORM BRAND VALUE IS FOR (the `platform` spec
/// enum; docs/styling-plan.md Slice 2b). AN APP NAMES THESE, IT NEVER
/// ASKS WHICH ONE IT IS: there is no `KayaPlatform.current`, and ONE
/// guest source compiles for macOS and for iOS, so a `#if os(macOS)` in
/// a guest is the thing kaya exists to not do.
public enum KayaPlatform: Int64 {
    case mac = 1
    case ios = 2
    case linux = 3
    case windows = 4
    case android = 5
}

/// THE SEMANTIC ICON VOCABULARY (the `symbol` spec enum;
/// docs/styling-plan.md D6, DESIGN.md "Icons want names, not bytes").
/// THE RAW VALUES ARE WIRE VALUES AND ARE APPEND-ONLY — renumbering
/// silently redraws every shipped app's menus.
public enum KayaSymbol: Int64 {
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
    case emoji = 21
    case send = 22
    case attach = 23
    case mic = 24
}

public struct KayaWidget {
    let id: UInt64

    /// Stack this row's children vertically while the window's SIZE
    /// CLASS is `when`, reverting on leaving the class
    /// (docs/adaptive-layout-plan.md D3). The root refuses a
    /// non-container target at batch.
    @discardableResult
    public func stackWhen(_ when: KayaSizeClass) -> KayaWidget {
        let (_, tx) = kayaDeclaring()
        // Widgets, then props, then values — thirds by position.
        tx.tx.createBreakpoint(
            0, .i64(when.wire), 1,
            [.i64(Int64(id)), .i64(Int64(KAYA_PROP_AXIS)), .i64(Int64(KAYA_AXIS_VERTICAL))])
        return self
    }

    /// Lay this grid out in `columns` columns while the window's SIZE
    /// CLASS is `when`; the authored count returns when the class does
    /// (docs/adaptive-layout-plan.md D6.2). The root refuses a non-grid
    /// target at batch.
    @discardableResult
    public func columnsWhen(_ when: KayaSizeClass, _ columns: Int) -> KayaWidget {
        let (_, tx) = kayaDeclaring()
        tx.tx.createBreakpoint(
            0, .i64(when.wire), 1,
            [.i64(Int64(id)), .i64(Int64(KAYA_PROP_COLUMNS)), .f64(Double(columns))])
        return self
    }

    /// THIS CANVAS REFUSES COERCION: it draws at its viewbox and is placed
    /// in whatever track layout gives it, never adapting to it
    /// (docs/canvas-plan.md §3.2.1, ruling 2). A canvas that declares
    /// nothing is `scale`.
    @discardableResult
    public func fixed() -> KayaWidget {
        let (_, tx) = kayaDeclaring()
        tx.tx.setSizePolicy(id, UInt32(KAYA_SIZE_POLICY_FIXED))
        return self
    }

    /// THIS CANVAS'S DRAWING IS A FUNCTION OF ITS SIZE: the core hands it
    /// the size layout assigned and takes back what this draws for that
    /// size, which becomes its viewbox. PROVIDING THE HANDLER IS THE
    /// DECLARATION — registering and putting the policy on the wire are
    /// ONE act. The binding answers the ask inside a transaction of its
    /// own (tools/check-ambient-tx.py); it never reaches the guest.
    @discardableResult
    public func onDraw(_ handler: @escaping (KayaDraw, KayaViewbox) -> Void) -> KayaWidget {
        // WIDENED HERE, not at dispatch: a tick canvas is also asked
        // once as a draw_requested, so one stored shape cannot be called
        // with the wrong arity.
        declareDrawing(UInt32(KAYA_SIZE_POLICY_REDRAW)) { d, size, _ in handler(d, size) }
    }

    /// The same on the platform's FRAME CLOCK, the handler also receiving
    /// the frame's time in seconds.
    @discardableResult
    public func onTick(_ handler: @escaping (KayaDraw, KayaViewbox, Double) -> Void) -> KayaWidget {
        declareDrawing(UInt32(KAYA_SIZE_POLICY_TICK), handler)
    }

    private func declareDrawing(
        _ policy: UInt32, _ f: @escaping (KayaDraw, KayaViewbox, Double) -> Void
    ) -> KayaWidget {
        let (app, tx) = kayaDeclaring()
        app.registerDraw(id, f)
        tx.tx.setSizePolicy(id, policy)
        return self
    }
}

/// A window's named size class (spec enum "size_class"): what
/// `stackWhen` speaks in place of an author-invented width. `.compact`
/// is the whole surface today.
public enum KayaSizeClass {
    case compact

    var wire: Int64 {
        switch self {
        case .compact: return Int64(KAYA_SIZE_CLASS_COMPACT)
        }
    }
}

/// A template node: a blueprint entry, stamped per collection entry.
///
/// NO `stackWhen`/`fixed`/`onDraw`/`onTick` HERE, and the compiler is the
/// refusal — a canvas inside a row template keeps `scale`
/// (docs/adaptive-layout-plan.md D3; docs/deferred.md, the template-zone
/// size policy entry).
public struct KayaNodeHandle {
    let id: UInt64
}

/// The app and the open transaction a chained live-zone declaration
/// needs.
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
/// carries none and answers 0.
private func kayaFrameTime(_ tail: [KayaValue]) -> Double {
    guard tail.count >= 3, case .f64(let t) = tail[2] else { return 0.0 }
    return t
}

/// A collection instance handle: the collection plus the key path selecting
/// one stamped copy's table.
public struct KayaCollection {
    let id: UInt64
    let path: [KayaValue]

    /// The instance of this collection inside the copy keyed by `key`
    /// of the next enclosing For; chain for deeper nesting.
    public func at(_ key: KayaValue) -> KayaCollection {
        KayaCollection(id: id, path: path + [key])
    }

    /// A For binds the collection itself, so handing it an at(...)
    /// handle is a bug.
    fileprivate func assertRoot() {
        precondition(
            path.isEmpty,
            "kaya: forEach binds the collection itself, not an instance — drop the at(...)")
    }
}

/// One instance of a collection: the table inside the stamped copy selected
/// by `path` (the empty path for a live-zone collection). ORDERED AND KEYED
/// AT ONCE — `entries` is the order the guest reads back, `slots` is each
/// key's index in it, and the scan they replace cost 58s of guest time at
/// 40,000 rows (docs/deferred.md, the Swift binding's quadratic insert).
private struct KayaInstance {
    let path: [KayaValue]
    // Any: a KayaValue for scalar collections, the record struct itself
    // for record collections — the model keeps native values, and only
    // wire fields ever encode.
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
public struct KayaMenuItem {
    let id: UInt64
}

/// A context catalog built UNANCHORED (tx.contextCatalog) for a template
/// node: menu items are live and shared across stamped copies, so the
/// catalog is built in the live zone and KayaTpl.contextMenu attaches it
/// inside the template.
public final class KayaContextCatalog {
    let roots: [KayaMenuItem]
    var attached = false

    init(_ roots: [KayaMenuItem]) {
        self.roots = roots
    }
}

/// One of the TWO addressable sources a menu text property binds to:
/// constant text or a Str signal. Menu items are not collection
/// elements, so there is no element arm.
public protocol KayaMenuText {}

extension String: KayaMenuText {}

extension KayaSignal: KayaMenuText {}

/// The Bool twin, for enabled/checked.
public protocol KayaMenuBool {}

extension Bool: KayaMenuBool {}

extension KayaSignal: KayaMenuBool {}

/// The index twin, for a radio group's value (a 0-based option index
/// under the Choice contract).
public protocol KayaMenuIndex {}

extension Int: KayaMenuIndex {}

extension Double: KayaMenuIndex {}

extension KayaSignal: KayaMenuIndex {}

/// One representation of a clip (DESIGN.md, Clipboard).
public enum KayaRepresentation: Sendable {
    case text(String)
    case html(String)
    /// Encoded image bytes. WHAT COMES BACK MAY BE A RE-ENCODE — the
    /// hosts convert freely between image types — so compare what the
    /// image IS, never the bytes it arrived in.
    case image([UInt8])
    /// Files, plural INSIDE one representation.
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
    case UInt32(KAYA_CLIP_TEXT): return .text(str(0))
    case UInt32(KAYA_CLIP_HTML): return .html(str(0))
    case UInt32(KAYA_CLIP_IMAGE): return .image(bytes(0))
    case UInt32(KAYA_CLIP_CUSTOM): return .custom(id: str(0), bytes: bytes(1))
    case UInt32(KAYA_CLIP_FILES):
        // The picker's own three-per-file grouping.
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

/// A drag operation (docs/dnd-plan.md D3): copy and move, nothing else.
public enum KayaOp: UInt32 {
    case copy = 1
    case move = 2
}

/// What a drop delivered (docs/dnd-plan.md D1): the representation a
/// paste already delivers, the point in the destination's own
/// coordinates, the operation the core settled on (nil for a refused
/// drag), and — for a reorder — the anchor row and the side it landed on.
public struct KayaDropped {
    let point: (x: Double, y: Double)
    public let operation: KayaOp?
    public let anchor: [KayaValue]
    public let before: Bool
    public let clip: KayaRepresentation?
}

/// A link_opened occurrence's tail is ONE FLAT RUN of Str values: the
/// url, then the captured pairs (KayaWire's arm). The handler receives
/// the captures alone — kaya matches once, in the core
/// (docs/app-links-plan.md §4) — and the url is for the drop sentence.
func kayaLinkUrl(_ tail: [KayaValue]) -> String {
    if let first = tail.first, case .str(let url) = first { return url }
    return ""
}

func kayaLinkParams(_ tail: [KayaValue]) -> [String: String] {
    var captured: [String: String] = [:]
    var i = 1
    while i + 1 < tail.count {
        if case .str(let name) = tail[i], case .str(let value) = tail[i + 1] {
            captured[name] = value
        }
        i += 2
    }
    return captured
}

/// A span the CORE sent, refused BY NAME if its ends are out of order:
/// `Range`'s own init would otherwise trap the process with Swift's
/// sentence and no kaya one. No scene reaches it — the core always sends
/// ordered spans (the idiom review's S3).
func kayaDecodedSpan(_ what: String, _ start: Int, _ stop: Int) -> Range<Int> {
    guard start <= stop else {
        fatalError("kaya: a \(what) carries \(start)..\(stop), a reversed span")
    }
    return start..<stop
}

/// A text_edited tail (KayaWire's arm): source, start, stop, the inserted
/// text, then four values per run.
func kayaEditFromTail(_ tail: [KayaValue]) -> KayaEdit {
    var edit = KayaEdit()
    guard tail.count >= 4 else { return edit }
    if case .i64(let source) = tail[0] {
        guard let known = KayaEditSource(rawValue: Int(source)) else {
            fatalError(
                "kaya: text_edited carries edit source \(source), which this "
                    + "build does not know")
        }
        edit.source = known
    }
    var start = edit.range.lowerBound, stop = edit.range.upperBound
    if case .i64(let s) = tail[1] { start = Int(s) }
    if case .i64(let e) = tail[2] { stop = Int(e) }
    edit.range = kayaDecodedSpan("text_edited", start, stop)
    if case .str(let inserted) = tail[3] { edit.inserted = inserted }
    edit.runs = kayaRunsFromValues(Array(tail[4...]))
    return edit
}

/// A text_formatted tail: removed, start, stop, name, value.
func kayaFormatFromTail(_ tail: [KayaValue]) -> KayaFormat {
    var act = KayaFormat(range: 0..<0, name: "", value: nil)
    guard tail.count >= 5 else { return act }
    var removed = false
    if case .i64(let flag) = tail[0] { removed = flag != 0 }
    var start = act.range.lowerBound, stop = act.range.upperBound
    if case .i64(let s) = tail[1] { start = Int(s) }
    if case .i64(let e) = tail[2] { stop = Int(e) }
    act.range = kayaDecodedSpan("text_formatted", start, stop)
    if case .str(let name) = tail[3] { act.name = name }
    if case .str(let value) = tail[4], !removed { act.value = value }
    return act
}

/// The same four, on the way down.
func kayaRunValues(_ runs: [KayaRun]) -> [KayaValue] {
    runs.flatMap { run -> [KayaValue] in
        [.i64(Int64(run.range.lowerBound)), .i64(Int64(run.range.upperBound)),
         .str(run.name), .str(run.value)]
    }
}

/// Four values per run — start, end, name, value — as the wire carries
/// them in both occurrences and both writes.
func kayaRunsFromValues(_ flat: [KayaValue]) -> [KayaRun] {
    var runs: [KayaRun] = []
    var i = 0
    while i + 3 < flat.count {
        guard case .i64(let start) = flat[i], case .i64(let end) = flat[i + 1],
            case .str(let name) = flat[i + 2], case .str(let value) = flat[i + 3]
        else {
            i += 4
            continue
        }
        runs.append(
            KayaRun(range: kayaDecodedSpan("run", Int(start), Int(end)), name: name, value: value))
        i += 4
    }
    return runs
}

/// The drag_op word, or nil for a cancelled or refused drag.
func kayaOperation(_ mask: UInt32) -> KayaOp? {
    KayaOp(rawValue: mask)
}

/// Turn the decoder's drop values into the app-facing struct.
func kayaDropped(_ drop: KayaDropValues) -> KayaDropped {
    KayaDropped(
        point: (drop.x, drop.y), operation: kayaOperation(drop.operation),
        anchor: drop.anchor, before: drop.before,
        clip: kayaRepresentation(drop.clip))
}

/// What an undo (or a redo) PUT BACK — the core-authoritative statement
/// of the restored state, never a replay of ops (docs/undo-plan.md D5).
public struct KayaUndoDelta {
    /// Signal id -> its restored value.
    let signals: [(signal: UInt64, value: KayaValue)]
    /// One restored field's text, per field the step disturbed — nothing
    /// else tells an app that folds text_changed into its own model.
    public let texts: [KayaUndoText]
    /// Collection entries, present or gone.
    let entries: [KayaUndoEntry]
    /// Instance orders, for the instances whose order the step changed.
    let orders: [KayaUndoOrder]
}

/// One text field's restored text, and the identity that says WHICH
/// field.
public struct KayaUndoText {
    let id: UInt64
    /// The instance path: one key per enclosing For, EMPTY for a live
    /// widget.
    public let path: [KayaValue]
    public let text: String
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

/// Decode an undone/redone record body (kind 17/18, one layout for both).
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
        // Values self-pad to 8 and concatenate.
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
                // A restored record's blob field rides the OCCURRENCE table
                // like a paste's bytes (crates/kaya/src/wire.rs, undo_body).
                out = .bytes(kayaOccurrenceBlobBytes(
                    raw.loadUnaligned(fromByteOffset: at + 8, as: UInt64.self)))
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
/// label/extensions run.
func kayaFilterValues(_ filters: [(String, String)]) -> [KayaValue] {
    var values: [KayaValue] = []
    for (label, extensions) in filters {
        values.append(.str(label))
        values.append(.str(extensions))
    }
    return values
}

/// The UTF-8 BYTE OFFSET of a position in `text` — kaya's unit for every
/// text range. NEVER CONVERT BY HAND: both spellings a Swift author
/// reaches for first (`distance(from:to:)`, `utf16Offset(in:)`) are
/// silently short on non-ASCII text (docs/traps.md: A range offset is a
/// UTF-8 BYTE offset, and almost no language's own search agrees).
func kayaByteOffset(_ i: String.Index, in text: String) -> Int {
    text.utf8.distance(from: text.startIndex, to: i)
}

/// A Swift string range as kaya's pair of UTF-8 byte offsets.
func kayaByteRange(_ r: Range<String.Index>, in text: String) -> Range<Int> {
    kayaByteOffset(r.lowerBound, in: text)..<kayaByteOffset(r.upperBound, in: text)
}

/// The copy chain: a clip record under construction; send() puts it on
/// the clipboard.
public struct KayaCopyRef {
    let tx: KayaAppTx
    private var text: String?
    private var html: String?
    private var image: [UInt8]?
    private var files: [UInt64] = []
    private var custom: [(String, [UInt8])] = []

    init(tx: KayaAppTx) { self.tx = tx }

    public func text(_ text: String) -> KayaCopyRef {
        var next = self
        next.text = text
        return next
    }

    public func html(_ html: String) -> KayaCopyRef {
        var next = self
        next.html = html
        return next
    }

    /// Encoded image bytes — the same currency the image property takes.
    public func image(_ bytes: [UInt8]) -> KayaCopyRef {
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
    /// every platform's own registry unchanged, so it carries no spaces.
    public func custom(_ id: String, _ bytes: [UInt8]) -> KayaCopyRef {
        _ = kayaAcceptList([id])
        var next = self
        next.custom.append((id, bytes))
        return next
    }

    /// Put the clip on the system clipboard. The wire order is kaya's,
    /// not this chain's: descending richness.
    public func send() {
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
            present |= UInt32(KAYA_CLIP_IMAGE)
            values.append(.blob(kayaRegisterBlob(Data(image))))
        }
        if let html {
            present |= UInt32(KAYA_CLIP_HTML)
            values.append(.str(html))
        }
        if let text {
            present |= UInt32(KAYA_CLIP_TEXT)
            values.append(.str(text))
        }
        tx.tx.copy(present, UInt32(files.count), UInt32(custom.count), values)
    }
}

/// A TEMPLATE node's drag chain (docs/dnd-plan.md §4): each representation
/// is a CONSTANT or the ROW'S OWN FIELD — text(row.title) binds the way
/// label(row.title) does — resolved per stamped copy and re-declared when
/// that field changes. A file stays constant.
public struct KayaTplDragRef {
    let tx: KayaAppTx
    let node: UInt64
    private var text: String?
    private var textField: UInt32?
    private var html: String?
    private var htmlField: UInt32?
    private var image: [UInt8]?
    private var imageField: UInt32?
    private var files: [UInt64] = []
    private var custom: [(String, [UInt8]?, UInt32?)] = []
    private var ops: UInt32 = 0

    init(tx: KayaAppTx, node: UInt64) {
        self.tx = tx
        self.node = node
    }

    func text(_ text: String) -> KayaTplDragRef {
        var next = self
        next.text = text
        return next
    }

    public func text(_ f: KayaField<String>) -> KayaTplDragRef {
        var next = self
        next.textField = f.index
        return next
    }

    func html(_ html: String) -> KayaTplDragRef {
        var next = self
        next.html = html
        return next
    }

    func html(_ f: KayaField<String>) -> KayaTplDragRef {
        var next = self
        next.htmlField = f.index
        return next
    }

    func image(_ bytes: [UInt8]) -> KayaTplDragRef {
        var next = self
        next.image = bytes
        return next
    }

    func image(_ f: KayaField<Data>) -> KayaTplDragRef {
        var next = self
        next.imageField = f.index
        return next
    }

    func file(_ f: KayaPickedFile) -> KayaTplDragRef {
        var next = self
        next.files.append(f.handle)
        return next
    }

    func custom(_ id: String, _ bytes: [UInt8]) -> KayaTplDragRef {
        _ = kayaAcceptList([id])
        var next = self
        next.custom.append((id, bytes, nil))
        return next
    }

    func custom(_ id: String, _ f: KayaField<Data>) -> KayaTplDragRef {
        _ = kayaAcceptList([id])
        var next = self
        next.custom.append((id, nil, f.index))
        return next
    }

    /// Allow this operation (copy, move, or both across two calls).
    public func allow(_ op: KayaOp) -> KayaTplDragRef {
        var next = self
        next.ops |= op.rawValue
        return next
    }

    public func declare() {
        var present: UInt32 = 0
        var bound: UInt32 = 0
        var values: [KayaValue] = []
        // A bound slot rides as the i64 `level << 32 | field`; the slot
        // IS its index in the reps.
        func slot(_ field: UInt32?) -> Bool {
            guard let field else { return false }
            bound |= 1 << UInt32(values.count)
            values.append(.i64(Int64(field)))
            return true
        }
        for (id, bytes, field) in custom {
            values.append(.str(id))
            if !slot(field) {
                values.append(.blob(kayaRegisterBlob(Data(bytes!))))
            }
        }
        for handle in files {
            values.append(.i64(Int64(bitPattern: handle)))
        }
        if image != nil || imageField != nil {
            present |= UInt32(KAYA_CLIP_IMAGE)
            if !slot(imageField) {
                values.append(.blob(kayaRegisterBlob(Data(image!))))
            }
        }
        if html != nil || htmlField != nil {
            present |= UInt32(KAYA_CLIP_HTML)
            if !slot(htmlField) {
                values.append(.str(html!))
            }
        }
        if text != nil || textField != nil {
            present |= UInt32(KAYA_CLIP_TEXT)
            if !slot(textField) {
                values.append(.str(text!))
            }
        }
        let empty = present == 0 && files.isEmpty && custom.isEmpty
        tx.tx.setDragSource(
            node, present, UInt32(files.count), UInt32(custom.count),
            empty ? 0 : ops, 0, bound, values)
    }
}

/// The drag chain: the copy chain's representations plus the operations
/// the source allows; declare() sends it. An EMPTY chain withdraws, which
/// is how a same-app move removes its source (docs/dnd-plan.md D1, D2).
public struct KayaDragRef {
    let tx: KayaAppTx
    let widget: UInt64
    let keys: [KayaValue]
    private var text: String?
    private var html: String?
    private var image: [UInt8]?
    private var files: [UInt64] = []
    private var custom: [(String, [UInt8])] = []
    private var ops: UInt32 = 0

    init(tx: KayaAppTx, widget: UInt64, keys: [KayaValue] = []) {
        self.tx = tx
        self.widget = widget
        self.keys = keys
    }

    public func text(_ text: String) -> KayaDragRef {
        var next = self
        next.text = text
        return next
    }

    func html(_ html: String) -> KayaDragRef {
        var next = self
        next.html = html
        return next
    }

    func image(_ bytes: [UInt8]) -> KayaDragRef {
        var next = self
        next.image = bytes
        return next
    }

    func file(_ f: KayaPickedFile) -> KayaDragRef {
        var next = self
        next.files.append(f.handle)
        return next
    }

    public func custom(_ id: String, _ bytes: [UInt8]) -> KayaDragRef {
        _ = kayaAcceptList([id])
        var next = self
        next.custom.append((id, bytes))
        return next
    }

    /// Allow this operation (copy, move, or both across two calls).
    public func allow(_ op: KayaOp) -> KayaDragRef {
        var next = self
        next.ops |= op.rawValue
        return next
    }

    public func declare() {
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
            present |= UInt32(KAYA_CLIP_IMAGE)
            values.append(.blob(kayaRegisterBlob(Data(image))))
        }
        if let html {
            present |= UInt32(KAYA_CLIP_HTML)
            values.append(.str(html))
        }
        if let text {
            present |= UInt32(KAYA_CLIP_TEXT)
            values.append(.str(text))
        }
        let empty = present == 0 && files.isEmpty && custom.isEmpty
        // KEYS FIRST, then the reps (set_column_headers' convention).
        tx.tx.setDragSource(
            widget, present, UInt32(files.count), UInt32(custom.count),
            empty ? 0 : ops, UInt32(keys.count), 0, keys + values)
    }
}

/// The read chain: which representations this read can use, and the
/// request id its one answer arrives under.
public struct KayaClipReadRef {
    let tx: KayaAppTx
    let id: UInt64
    private var accepting: [String] = []
    private var onResult: ((KayaAppTx, KayaRepresentation?) throws -> Void)?

    init(tx: KayaAppTx, id: UInt64) {
        self.tx = tx
        self.id = id
    }

    public func text() -> KayaClipReadRef { accept("text") }
    func html() -> KayaClipReadRef { accept("html") }
    public func image() -> KayaClipReadRef { accept("image") }
    public func files() -> KayaClipReadRef { accept("files") }

    /// Accept an app-defined format by id. Custom formats are tried
    /// FIRST, in the order named.
    public func custom(_ id: String) -> KayaClipReadRef { accept(id) }

    private func accept(_ kind: String) -> KayaClipReadRef {
        var next = self
        next.accepting.append(kind)
        return next
    }

    /// Bind the one-shot handler to THIS request. The answer is nil
    /// when the clipboard had nothing this read accepted — and nil
    /// equally when the read was denied or the app was unfocused,
    /// because no platform says which.
    public func onResult(
        _ handler: @escaping (KayaAppTx, KayaRepresentation?) throws -> Void
    ) -> KayaClipReadRef {
        var next = self
        next.onResult = handler
        return next
    }

    /// Send the request, returning its id.
    @discardableResult
    public func send() -> UInt64 {
        tx.tx.readClipboard(id, .str(kayaAcceptList(accepting)))
        tx.app.onClipboard(id, onResult)
        return id
    }
}

/// WHAT `KayaAsset(_:)` THROWS: a name the package does not carry, or
/// carries unreadably (docs/assets-plan.md). `LocalizedError` MUST STAY —
/// without it `localizedDescription` answers Foundation's boilerplate
/// instead of the core's sentence, which is `asset_why_not`'s verbatim
/// (crates/kaya/src/assets.rs).
public struct KayaAssetMiss: Error, CustomStringConvertible, LocalizedError {
    /// The name that was asked for.
    let name: String
    /// The core's sentence, verbatim: line 1 names the name, the rule it
    /// broke and the census; line 2 names the resolved place.
    public let sentence: String

    public var description: String { sentence }
    public var errorDescription: String? { sentence }
}

/// AN ASSET — a file this app's own BUILD put where the running program
/// can find it (docs/assets-plan.md, tools/check-assets.py). EACH CALL
/// READS: no cache, no watch, no reload. A miss throws `KayaAssetMiss`
/// carrying the core's sentence and nothing added —
/// `tools/scenes/assets.steps` freezes it THROUGH THE CAUGHT ERROR.
public final class KayaAsset {
    private var handle: UInt64

    public init(_ name: String) throws {
        // Set before anything can throw: a class must be whole before a
        // designated initializer leaves, and `deinit` runs on the way out.
        handle = 0
        let utf8 = Array(name.utf8)
        let opened = utf8.withUnsafeBufferPointer { raw in
            kaya_asset_open(raw.baseAddress, UInt(raw.count))
        }
        guard opened != 0 else {
            throw KayaAssetMiss(name: name, sentence: KayaAsset.missSentence(name))
        }
        handle = opened
    }

    /// Why `KayaAsset(name)` would throw — the sentence it would carry,
    /// handed over without throwing. `""` means the name resolves
    /// (docs/deferred.md, the assets entry).
    ///
    /// SIZED, THEN READ: the C entry returns the sentence's TRUE length
    /// and fills the caller's buffer, so it takes two calls. A guessed
    /// buffer cuts the half that names the root and the route.
    public static func missSentence(_ name: String) -> String {
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

    /// This asset's bytes, copied out of core memory.
    public var bytes: Data {
        alive()
        var len = UInt(0)
        guard let p = kaya_asset_bytes(handle, &len), len > 0 else { return Data() }
        return Data(bytes: p, count: Int(len))
    }

    /// The same bytes as a stream. IN-MEMORY AND NOT A FILE: no core
    /// surface behind it and no descriptor anywhere.
    func stream() -> InputStream {
        InputStream(data: bytes)
    }

    /// Register these bytes into the pending table and answer with the
    /// handle the record carries.
    fileprivate func blob() -> UInt64 {
        alive()
        return kaya_asset_blob(handle)
    }

    /// Let the core drop these bytes. Idempotent, and `deinit` calls the
    /// same release.
    public func close() {
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

public struct KayaPickedFile: Sendable {
    let handle: UInt64
    public let name: String
    /// A RE-OPENABLE NAME, nil unless re-opening it actually works —
    /// measurement puts that at the three desktops and neither phone
    /// (DESIGN.md, File dialogs).
    let localPath: String?

    init(handle: UInt64, name: String, localPath: String) {
        self.handle = handle
        self.name = name
        self.localPath = localPath.isEmpty ? nil : localPath
    }

    /// Redeem the handle for a real FileHandle, plus whether it seeks.
    /// BLOCKS, possibly for a long time, so call it from a thread you
    /// chose and post the result back. THE DESCRIPTOR BECOMES SWIFT'S:
    /// `closeOnDealloc` is true, so the core keeps no claim.
    public func open(_ mode: KayaFileMode = .read)
        throws -> (file: FileHandle, seekable: Bool)
    {
        var raw: Int64 = 0
        var seekable: UInt32 = 0
        let rc = kaya_open_picked(handle, mode.rawValue, &raw, &seekable)
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
public struct KayaCapabilities {
    /// The host can materialize a surface beside the primary one
    /// (`tx.createWindow`, `tx.mountIn`). False on iOS, where
    /// `createWindow` aborts at the root. ONE SOURCE SERVES MAC AND iOS,
    /// so a `#if !os(iOS)` around the CALL is a second copy of the core's
    /// rule, keyed on the platform rather than on the capability. (A `#if`
    /// around an IMPORT or an unavailable API is a different thing.)
    public let auxWindows: Bool

    /// This process can post a local notification the desktop will show
    /// (docs/tasks-s3-plan.md N3). A RUNTIME bit: the host measures it at
    /// startup, so it is false where no notification service answers.
    let notifications: Bool

    /// `setBadge` will show a number on the app's icon
    /// (docs/app-badge-plan.md). A RUNTIME bit, like `notifications`.
    let badge: Bool

    /// `showEmojiPicker` opens a picker (docs/emoji-picker-plan.md); on iOS
    /// it only focuses the field.
    let emojiPicker: Bool
}

// --- The formatter door and the catalog (docs/compliance-plan.md §1.4) ------

/// How much of a date or time to write: the numeric form, the abbreviated
/// words, the full words.
public enum KayaLength: Int64, Sendable {
    case short = 0
    case medium = 1
    case long = 2
}

/// What a number formatter may be told; a nil digit count leaves the
/// platform's default.
public struct KayaNumberSpec: Sendable {
    public var minFractionDigits: Int?
    public var maxFractionDigits: Int?
    public var grouping: Bool

    public init(minFractionDigits: Int? = nil, maxFractionDigits: Int? = nil, grouping: Bool = true) {
        self.minFractionDigits = minFractionDigits
        self.maxFractionDigits = maxFractionDigits
        self.grouping = grouping
    }
}

/// Who the user is, as the platform reports it: the BCP-47 tag, the hour
/// cycle (12 or 24), the first weekday (1 Monday … 7 Sunday), the calendar
/// and the numbering system.
public struct KayaLocaleInfo: Sendable {
    public let tag: String
    public let hourCycle: Int
    public let firstWeekday: Int
    public let calendar: String
    public let numbering: String
}

/// Which way the layout runs, decided by the locale's script.
public enum KayaDirection: Sendable {
    case ltr
    case rtl
}

/// One argument to `KayaApp.tr`; integer, float and string literals
/// convert, a date or time is spelled `.date(d)` / `.time(t)`.
public enum KayaArg: Sendable, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByStringLiteral
{
    case int(Int64)
    case float(Double)
    case str(String)
    case date(KayaDate)
    case time(KayaTime)

    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .float(value) }
    public init(stringLiteral value: String) { self = .str(value) }
}

/// The C API's fill shape read twice; a 0 length is the core's fault for
/// the input (the sentence is already reported), and a formatter never
/// legitimately writes nothing.
func kayaFilled(_ what: String, _ ask: (UnsafeMutablePointer<UInt8>?, UInt) -> UInt) -> String {
    let len = ask(nil, 0)
    precondition(len > 0, "kaya: \(what) refused its input (the fault names it)")
    var out = [UInt8](repeating: 0, count: Int(len))
    let written = out.withUnsafeMutableBufferPointer { buf in ask(buf.baseAddress, len) }
    return String(decoding: out[0..<Int(min(written, len))], as: UTF8.self)
}

/// The formatter door: dates, times, numbers, percentages and money
/// written the way the user's platform writes them, by the platform's own
/// formatter. Pure functions, any thread, no transaction.
public enum KayaFmt {
    public static func date(_ d: KayaDate, _ length: KayaLength = .medium) -> String {
        let packed = kayaPackedDate("fmt.date", d)
        return kayaFilled("fmt.date") { kaya_fmt_date(packed, length.rawValue, $0, $1) }
    }

    /// The date with its weekday and no year (`Mon, Sep 7` in en-US).
    public static func dateWeekday(_ d: KayaDate) -> String {
        let packed = kayaPackedDate("fmt.dateWeekday", d)
        return kayaFilled("fmt.dateWeekday") { kaya_fmt_date_weekday(packed, $0, $1) }
    }

    public static func time(_ t: KayaTime, _ length: KayaLength = .short) -> String {
        let packed = kayaPackedTime("fmt.time", t)
        return kayaFilled("fmt.time") { kaya_fmt_time(packed, length.rawValue, $0, $1) }
    }

    public static func dateTime(_ d: KayaDate, _ t: KayaTime, _ length: KayaLength = .medium) -> String {
        let date = kayaPackedDate("fmt.dateTime", d)
        let time = kayaPackedTime("fmt.dateTime", t)
        return kayaFilled("fmt.dateTime") { kaya_fmt_date_time(date, time, length.rawValue, $0, $1) }
    }

    private static func options(_ o: KayaNumberSpec) -> KayaNumberOptions {
        KayaNumberOptions(
            min_fraction_digits: Int32(o.minFractionDigits ?? -1),
            max_fraction_digits: Int32(o.maxFractionDigits ?? -1),
            grouping: o.grouping)
    }

    public static func number(_ value: Double, _ o: KayaNumberSpec = KayaNumberSpec()) -> String {
        var opts = options(o)
        return kayaFilled("fmt.number") { kaya_fmt_number(value, &opts, $0, $1) }
    }

    public static func percent(_ value: Double, _ o: KayaNumberSpec = KayaNumberSpec()) -> String {
        var opts = options(o)
        return kayaFilled("fmt.percent") { kaya_fmt_percent(value, &opts, $0, $1) }
    }

    /// An amount in the ISO 4217 currency `code`.
    public static func currency(_ value: Double, _ code: String) -> String {
        code.withCString { c in kayaFilled("fmt.currency") { kaya_fmt_currency(value, c, $0, $1) } }
    }

    /// The process locale and its settings, asked of the platform each time.
    public static func locale() -> KayaLocaleInfo {
        let parts = kayaFilled("fmt.locale") { kaya_locale($0, $1) }.split(separator: " ").map(String.init)
        precondition(parts.count == 5, "kaya: kaya_locale answered \(parts)")
        return KayaLocaleInfo(
            tag: parts[0], hourCycle: Int(parts[1]) ?? 12, firstWeekday: Int(parts[2]) ?? 1,
            calendar: parts[3], numbering: parts[4])
    }

    public static func direction() -> KayaDirection {
        kaya_direction() == 1 ? .rtl : .ltr
    }

    /// The text scale the platform reported, 1.0 until one does.
    public static func textScale() -> Double {
        kaya_text_scale()
    }
}

/// The app's preferences store (docs/tasks-s4-plan.md P2/P3): a small
/// typed key-value record under the app's id, the platform's own where
/// the platform has one — UserDefaults on Apple, SharedPreferences on
/// Android, a key file on Linux and Windows.
///
/// A PULL, NOT A SIGNAL: a setting is read when the app builds and
/// written when the user changes it. Every get takes the default it
/// answers when the key is absent OR holds another type. Writes are
/// durable when they return, and the store may be used from any thread.
struct KayaPrefs {
    /// A guest may READ any key and WRITE any key kaya has not reserved
    /// (docs/tasks-s4-plan.md P4: window memory lives under `kaya.`).
    private static func key(_ name: String) -> [UInt8] {
        precondition(!name.isEmpty, "kaya: a preference key must not be empty")
        return Array(name.utf8)
    }

    private static func writeKey(_ name: String) -> [UInt8] {
        let raw = key(name)
        precondition(
            !name.hasPrefix("kaya."),
            "kaya: preference key \"\(name)\" is reserved "
                + "(the kaya. prefix is kaya's own)")
        return raw
    }

    /// One typed get, resolved by the call site's inferred type — the
    /// generic entry point `UserDefaults` itself grew (return-type
    /// inference) in place of a get<Type> family, and the shape
    /// `@AppStorage` wraps.
    func get<V: KayaPrefValue>(_ name: String, default def: V) -> V {
        V.kayaPrefGet(KayaPrefs.key(name), default: def)
    }

    func set<V: KayaPrefValue>(_ name: String, _ value: V) {
        V.kayaPrefSet(KayaPrefs.writeKey(name), value)
    }

    subscript<V: KayaPrefValue>(name: String, default def: V) -> V {
        get { get(name, default: def) }
        nonmutating set { set(name, newValue) }
    }

    func remove(_ name: String) {
        let raw = KayaPrefs.writeKey(name)
        raw.withUnsafeBufferPointer { k in
            kaya_pref_remove(k.baseAddress, UInt(k.count))
        }
    }
}

/// The four wire-storable primitive types a preference may hold
/// (docs/tasks-s4-plan.md P2/P3); `KayaPrefs.get`/`set` resolve to one
/// of these four by the call site's inferred type.
protocol KayaPrefValue {
    static func kayaPrefGet(_ raw: [UInt8], default def: Self) -> Self
    static func kayaPrefSet(_ raw: [UInt8], _ value: Self)
}

extension String: KayaPrefValue {
    static func kayaPrefGet(_ raw: [UInt8], default def: String) -> String {
        var len = UInt(0)
        let present = raw.withUnsafeBufferPointer { k in
            kaya_pref_get_string(k.baseAddress, UInt(k.count), nil, 0, &len)
        }
        if present == 0 { return def }
        if len == 0 { return "" }
        var out = [UInt8](repeating: 0, count: Int(len))
        let ok = out.withUnsafeMutableBufferPointer { buf -> Int32 in
            raw.withUnsafeBufferPointer { k in
                kaya_pref_get_string(
                    k.baseAddress, UInt(k.count), buf.baseAddress, len, &len)
            }
        }
        if ok == 0 { return def }
        return String(decoding: out[0..<Int(len)], as: UTF8.self)
    }

    static func kayaPrefSet(_ raw: [UInt8], _ value: String) {
        let packed = Array(value.utf8)
        raw.withUnsafeBufferPointer { k in
            packed.withUnsafeBufferPointer { v in
                kaya_pref_set_string(
                    k.baseAddress, UInt(k.count), v.baseAddress, UInt(v.count))
            }
        }
    }
}

extension Int64: KayaPrefValue {
    static func kayaPrefGet(_ raw: [UInt8], default def: Int64) -> Int64 {
        var out: Int64 = 0
        let present = raw.withUnsafeBufferPointer { k in
            kaya_pref_get_i64(k.baseAddress, UInt(k.count), &out)
        }
        return present == 0 ? def : out
    }

    static func kayaPrefSet(_ raw: [UInt8], _ value: Int64) {
        raw.withUnsafeBufferPointer { k in
            kaya_pref_set_i64(k.baseAddress, UInt(k.count), value)
        }
    }
}

/// `Int` IS THE TYPE OF AN INTEGER LITERAL in Swift, so without this
/// `prefs.get("count", default: 0)` — the most obvious call there is —
/// does not compile (`@AppStorage`, the model the doc comment above
/// cites, conforms Int first). It forwards to the Int64 arm; the store
/// has one integer channel.
extension Int: KayaPrefValue {
    static func kayaPrefGet(_ raw: [UInt8], default def: Int) -> Int {
        Int(Int64.kayaPrefGet(raw, default: Int64(def)))
    }

    static func kayaPrefSet(_ raw: [UInt8], _ value: Int) {
        Int64.kayaPrefSet(raw, Int64(value))
    }
}

extension Double: KayaPrefValue {
    static func kayaPrefGet(_ raw: [UInt8], default def: Double) -> Double {
        var out: Double = 0
        let present = raw.withUnsafeBufferPointer { k in
            kaya_pref_get_f64(k.baseAddress, UInt(k.count), &out)
        }
        return present == 0 ? def : out
    }

    static func kayaPrefSet(_ raw: [UInt8], _ value: Double) {
        raw.withUnsafeBufferPointer { k in
            kaya_pref_set_f64(k.baseAddress, UInt(k.count), value)
        }
    }
}

extension Bool: KayaPrefValue {
    static func kayaPrefGet(_ raw: [UInt8], default def: Bool) -> Bool {
        var out: UInt8 = 0
        let present = raw.withUnsafeBufferPointer { k in
            kaya_pref_get_bool(k.baseAddress, UInt(k.count), &out)
        }
        return present == 0 ? def : out != 0
    }

    static func kayaPrefSet(_ raw: [UInt8], _ value: Bool) {
        raw.withUnsafeBufferPointer { k in
            kaya_pref_set_bool(k.baseAddress, UInt(k.count), value ? 1 : 0)
        }
    }
}

// --- Rich text (docs/rich-text-plan.md R1) ---------------------------
// EVERY OFFSET IS A UTF-8 BYTE OFFSET into the widget's text
// (docs/ranges-units.md §7), so these take `Range<Int>` and never a
// `String.Index`: a run's ends are the core's, not Foundation's.

extension Range where Bound == Int {
    /// The same span `d` bytes along — the splice's own arithmetic. A
    /// Range's bounds are `let`, so without these every partial edit is a
    /// full reconstruction and the range is a worse pair than two Ints.
    func shifted(by d: Int) -> Range<Int> { (lowerBound + d)..<(upperBound + d) }

    /// The same span with its upper bound brought down to `n`.
    func raised(to n: Int) -> Range<Int> { lowerBound..<n }

    /// The same span with its lower bound taken up to `n`.
    func lowered(to n: Int) -> Range<Int> { n..<upperBound }
}

/// The wire's own spelling of a flag attribute; the bool overloads
/// coerce to it and `isFlag` reads it back.
let kayaFlagValue = "true"

/// One attribute over one span; `value` is a URL for `link`, a kind for
/// `block`, and the wire's flag string for the rest — which `isFlag`
/// reads back as a Bool.
public struct KayaRun: Equatable, Sendable {
    public var range: Range<Int>
    public var name: String
    public var value: String

    /// A flag attribute, on: bold, italic, underline, strike, code.
    public var isFlag: Bool { value == kayaFlagValue }
}

/// One paragraph kind; drawn, never stored (docs/rich-text-plan.md R3).
public enum KayaBlock: String {
    case body
    case heading1
    case heading2
    case heading3
    case quote
    case codeBlock = "code_block"

    var name: String { rawValue }
}

/// What provoked an edit the widget reports (docs/rich-text-plan.md §2;
/// the review page's ruling 3). THE RAW VALUES ARE WIRE VALUES
/// (crates/kaya/src/wire.rs `EDIT_SOURCES`): KayaWire.swift carries no
/// constant for this vocabulary, so they are pinned here as KayaRole's are.
public enum KayaEditSource: Int {
    case user = 0
    case imeCommit = 1
    case paste = 2
    case nativeUndo = 3
    case drop = 4

    public var name: String {
        switch self {
        case .user: return "user"
        case .imeCommit: return "ime_commit"
        case .paste: return "paste"
        case .nativeUndo: return "native_undo"
        case .drop: return "drop"
        }
    }
}

/// A `rich` textarea's text and runs, kept current by the binding from
/// the edits it delivers.
public struct KayaDocument: Equatable, Sendable {
    public var text: String = ""
    public var runs: [KayaRun] = []

    public init(_ text: String = "") {
        self.text = text
    }

    /// A FLAG attribute, on or off — the boolean spelling, coerced to
    /// the wire's own string here at the boundary.
    public func mark(_ range: Range<Int>, _ name: String, _ on: Bool) -> KayaDocument {
        mark(range, name, on ? kayaFlagValue : "false")
    }

    func mark(_ range: Range<Int>, _ name: String, _ value: String) -> KayaDocument {
        var next = self
        next.runs.append(KayaRun(range: range, name: name, value: value))
        return next
    }

    public func bold(_ range: Range<Int>) -> KayaDocument { mark(range, "bold", "true") }
    public func italic(_ range: Range<Int>) -> KayaDocument { mark(range, "italic", "true") }
    func underline(_ range: Range<Int>) -> KayaDocument { mark(range, "underline", "true") }
    func strike(_ range: Range<Int>) -> KayaDocument { mark(range, "strike", "true") }
    func code(_ range: Range<Int>) -> KayaDocument { mark(range, "code", "true") }
    public func link(_ range: Range<Int>, _ url: String) -> KayaDocument { mark(range, "link", url) }

    /// A paragraph's kind; the range covers whole paragraphs or is refused.
    public func block(_ range: Range<Int>, _ kind: KayaBlock) -> KayaDocument {
        mark(range, "block", kind.name)
    }

    func attr(at byte: Int, _ name: String) -> String? {
        runs.first { $0.name == name && $0.range.contains(byte) }?.value
    }
}

/// Replace `range` with `inserted`, whose `runs` carry offsets RELATIVE to
/// the inserted text.
public struct KayaEdit: Equatable {
    public var range: Range<Int> = 0..<0
    public var inserted: String = ""
    public var runs: [KayaRun] = []
    /// What provoked it; nil on an edit the app builds, and ignored by
    /// `applyEdit` — nothing on the wire carries it downward.
    public var source: KayaEditSource? = nil

    public static func insert(at: Int, _ text: String) -> KayaEdit {
        KayaEdit(range: at..<at, inserted: text, runs: [])
    }

    static func delete(_ range: Range<Int>) -> KayaEdit {
        KayaEdit(range: range, inserted: "", runs: [])
    }

    static func replace(_ range: Range<Int>, _ text: String) -> KayaEdit {
        KayaEdit(range: range, inserted: text, runs: [])
    }

    /// One attribute over the INSERTED text's own offsets.
    /// A flag attribute over the inserted text, on or off.
    public func mark(_ range: Range<Int>, _ name: String, _ on: Bool) -> KayaEdit {
        mark(range, name, on ? kayaFlagValue : "false")
    }

    func mark(_ range: Range<Int>, _ name: String, _ value: String) -> KayaEdit {
        var next = self
        next.runs.append(KayaRun(range: range, name: name, value: value))
        return next
    }
}

/// A toolbar act over a range; `value` nil is the attribute taken off.
public struct KayaFormat: Equatable {
    public var range: Range<Int>
    public var name: String
    public var value: String?

    /// A flag attribute, on.
    var isFlag: Bool { value == kayaFlagValue }
}

/// The core's own fold rule over ANY document — a live widget's mirror or
/// a stamped copy's ROW FIELD (crates/kaya/src/app.rs, `fold_edit`;
/// docs/rich-text-plan.md §19). EVERY OFFSET IS A UTF-8 BYTE OFFSET, so
/// the text is cut as bytes and decoded back.
func kayaFoldEdit(
    _ doc: inout KayaDocument, _ start: Int, _ end: Int, _ inserted: String, _ runs: [KayaRun]
) {
    var bytes = Array(doc.text.utf8)
    let boundary = { (at: Int) in at == bytes.count || bytes[at] & 0xC0 != 0x80 }
    if start < 0 || start > end || end > bytes.count || !boundary(start) || !boundary(end) {
        // A mirror out of step with the core would splice garbage.
        doc.text = inserted
        doc.runs = runs
        return
    }
    let insertedBytes = Array(inserted.utf8)
    let shift = insertedBytes.count - (end - start)
    var next: [KayaRun] = []
    for run in doc.runs {
        if run.range.lowerBound < start {
            var head = run
            head.range = run.range.raised(to: min(run.range.upperBound, start))
            next.append(head)
        }
        if run.range.upperBound > end {
            var tail = run
            tail.range = run.range.lowered(to: max(run.range.lowerBound, end)).shifted(by: shift)
            next.append(tail)
        }
    }
    for run in runs {
        var moved = run
        moved.range = run.range.shifted(by: start)
        next.append(moved)
    }
    bytes.replaceSubrange(start..<end, with: insertedBytes)
    doc.text = String(decoding: bytes, as: UTF8.self)
    doc.runs = kayaNormalizeRuns(next)
}

/// kayaFoldEdit's twin one act over (`fold_format`): put the attribute
/// over the range or take it off, clipping THIS attribute's runs.
func kayaFoldFormat(
    _ doc: inout KayaDocument, _ start: Int, _ end: Int, _ name: String, _ value: String?
) {
    if start >= end { return }
    var next: [KayaRun] = []
    for run in doc.runs {
        if run.name != name || run.range.upperBound <= start || run.range.lowerBound >= end {
            next.append(run)
            continue
        }
        if run.range.lowerBound < start {
            var head = run
            head.range = run.range.raised(to: start)
            next.append(head)
        }
        if run.range.upperBound > end {
            var tail = run
            tail.range = run.range.lowered(to: end)
            next.append(tail)
        }
    }
    if let value {
        next.append(KayaRun(range: start..<end, name: name, value: value))
    }
    doc.runs = kayaNormalizeRuns(next)
}

/// A Document's BYTES as a record field holds them
/// (docs/rich-text-plan.md §19, crates/kaya/src/wire.rs `document_blob`):
/// one counted value list — the text, then four values per run.
/// Hand-packed because KayaWire's value encoder is the generated file's
/// own; the bytes are pinned against the wire rules in
/// tools/checks/swift-abort/main.swift.
func kayaDocumentBlob(_ doc: KayaDocument) -> Data {
    var out = Data()
    func put32(_ v: UInt32) {
        withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) }
    }
    func put64(_ v: Int64) {
        withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) }
    }
    func str(_ s: String) {
        let utf8 = Array(s.utf8)
        put32(UInt32(KAYA_VALUE_STR))
        put32(UInt32(utf8.count))
        out.append(contentsOf: utf8)
    }
    func i64(_ v: Int) {
        put32(UInt32(KAYA_VALUE_I64))
        put32(8)
        put64(Int64(v))
    }
    func pad() {
        while out.count % 8 != 0 { out.append(0) }
    }
    put32(UInt32(1 + doc.runs.count * 4))
    put32(0)
    str(doc.text)
    pad()
    for run in doc.runs {
        i64(run.range.lowerBound)
        pad()
        i64(run.range.upperBound)
        pad()
        str(run.name)
        pad()
        str(run.value)
        pad()
    }
    return out
}

/// `kayaDocumentBlob`'s inverse, for a row an undo restored: the delta
/// carries a Document field as a blob and the decoder redeems it to these
/// bytes (crates/kaya/src/wire.rs, `read_document_blob`).
public func kayaDocumentOfBlob(_ bytes: Data) -> KayaDocument {
    let raw = [UInt8](bytes)
    var values: [KayaValue] = []
    raw.withUnsafeBytes { buf in
        guard buf.count >= 8 else { return }
        let count = Int(buf.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        var at = 8
        for _ in 0..<count {
            guard at + 8 <= buf.count else { return }
            let vtype = buf.loadUnaligned(fromByteOffset: at, as: UInt32.self)
            let vlen = Int(buf.loadUnaligned(fromByteOffset: at + 4, as: UInt32.self))
            guard at + 8 + vlen <= buf.count else { return }
            if vtype == UInt32(KAYA_VALUE_I64) {
                values.append(.i64(buf.loadUnaligned(fromByteOffset: at + 8, as: Int64.self)))
            } else {
                values.append(.str(String(
                    decoding: raw[(at + 8)..<(at + 8 + vlen)], as: UTF8.self)))
            }
            at += 8 + ((vlen + 7) & ~7)
        }
    }
    guard case .str(let text)? = values.first else {
        preconditionFailure(
            "kaya: a document blob starts with its text; this one holds \(values.count) value(s)")
    }
    var doc = KayaDocument(text)
    var i = 1
    while i + 3 < values.count {
        guard case .i64(let start) = values[i], case .i64(let end) = values[i + 1],
              case .str(let name) = values[i + 2], case .str(let value) = values[i + 3]
        else { break }
        doc.runs.append(
            KayaRun(range: kayaDecodedSpan("document blob run", Int(start), Int(end)),
                    name: name, value: value))
        i += 4
    }
    return doc
}

/// The core's normal form (crates/kaya/src/scene.rs, `RichDoc::normalize`),
/// so the mirror and the core's document spell one string.
func kayaNormalizeRuns(_ runs: [KayaRun]) -> [KayaRun] {
    var out: [KayaRun] = []
    for name in Set(runs.map(\.name)).sorted() {
        var painted: [KayaRun] = []
        for run in runs where run.name == name {
            if run.range.lowerBound >= run.range.upperBound { continue }
            var kept: [KayaRun] = []
            for old in painted {
                if old.range.upperBound <= run.range.lowerBound
                    || old.range.lowerBound >= run.range.upperBound {
                    kept.append(old)
                    continue
                }
                if old.range.lowerBound < run.range.lowerBound {
                    var head = old
                    head.range = old.range.raised(to: run.range.lowerBound)
                    kept.append(head)
                }
                if old.range.upperBound > run.range.upperBound {
                    var tail = old
                    tail.range = old.range.lowered(to: run.range.upperBound)
                    kept.append(tail)
                }
            }
            kept.append(run)
            painted = kept
        }
        painted.sort { $0.range.lowerBound < $1.range.lowerBound }
        var merged: [KayaRun] = []
        for run in painted {
            if let last = merged.last, last.range.upperBound == run.range.lowerBound,
                last.value == run.value {
                merged[merged.count - 1].range = last.range.raised(to: run.range.upperBound)
            } else {
                merged.append(run)
            }
        }
        out.append(contentsOf: merged)
    }
    out.sort { ($0.range.lowerBound, $0.name) < ($1.range.lowerBound, $1.name) }
    return out
}

public final class KayaApp {
    /// The notification_result decision, in a method of its own because
    /// the ring loop's switch has no seam a test can reach (the ring is
    /// C memory) — Go's `notificationResult` for the same reason, and
    /// tools/checks/swift-notify drives the three cases through here.
    /// THE ORDER IS THE SEMANTICS (docs/tasks-s9-plan.md R1) and
    /// tools/check-sugar-surface.py reads it out of this body: the
    /// one-shot handler bound at the show first, retiring with the
    /// result; else the process-level one, which does not; else the drop
    /// is announced.
    func notificationResult(_ id: UInt64, _ choice: UInt32) {
        let answer = KayaNotificationOutcome.fromWire(choice)
        if let handler = notifications.removeValue(forKey: id) {
            dispatch { try build { tx in try handler(tx, answer) } }
        } else if let act = notificationActivation {
            dispatch { try build { tx in try act(tx, id, answer) } }
        } else {
            let outcome = answer.name
            FileHandle.standardError.write(Data((
                "kaya: notification \(id) outcome \(outcome) reached no "
                + "handler — none was bound at the show and no "
                + "process-level handler is registered "
                + "(KayaApp.onNotificationActivation)\n").utf8))
        }
    }

    /// The app's OWN writable directory (docs/tasks-s4-plan.md P1):
    /// Application Support/<id> on macOS, Documents on iOS, the files
    /// directory on Android, $XDG_DATA_HOME/<id> on Linux,
    /// %LOCALAPPDATA%\<id> on Windows. Created on first ask.
    ///
    /// KAYA OWNS THE PLACE AND NOTHING ELSE: the app's document is the
    /// app's, written the standard way (GRDB is the recommendation).
    /// Settings are small and typed and belong in `prefs()`.
    ///
    /// SIZED, THEN READ, `KayaAsset.missSentence`'s two-call shape.
    /// REFUSES where the platform has handed no directory over — an
    /// error state a guest cannot plan around, so all nine bindings
    /// refuse rather than answering an absent value (ruled 2026-09-09).
    static func appDataDir() -> String {
        let len = kaya_app_data_dir(nil, 0)
        if len == 0 {
            preconditionFailure(
                "kaya: app_data_dir asked before the platform handed one "
                    + "over (Android before attach)")
        }
        var out = [UInt8](repeating: 0, count: Int(len))
        let written = out.withUnsafeMutableBufferPointer { buf in
            kaya_app_data_dir(buf.baseAddress, len)
        }
        return String(decoding: out[0..<Int(min(written, len))], as: UTF8.self)
    }

    /// The app's preferences store — one per process.
    static func prefs() -> KayaPrefs { KayaPrefs() }

    /// The formatter door (docs/compliance-plan.md §1.4): `KayaApp.fmt.date(d, .medium)`.
    public static var fmt: KayaFmt.Type { KayaFmt.self }

    /// Load the app's catalog, `l10n/<app>.<locale>.ftl` under the asset root
    /// with the fallback chain (docs/compliance-plan.md §2.4). Once, at
    /// startup, before the first `tr`.
    public static func catalog(_ app: String) {
        app.withCString { kaya_catalog($0) }
    }

    /// The message `key` with `args` filled from the loaded catalog; dates
    /// and times are formatted through the door. A missing message or
    /// argument is the core's panic naming the key and the locale.
    public static func tr(_ key: String, _ args: [String: KayaArg] = [:]) -> String {
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        func keep(_ s: String) -> UnsafePointer<CChar>? {
            guard let p = strdup(s) else { return nil }
            owned.append(p)
            return UnsafePointer(p)
        }
        var records: [KayaTrArg] = []
        for (name, arg) in args {
            var record = KayaTrArg(name: keep(name), tag: 0, i: 0, f: 0, s: nil)
            switch arg {
            case .int(let v): record.tag = UInt32(KAYA_TR_INT); record.i = v
            case .float(let v): record.tag = UInt32(KAYA_TR_FLOAT); record.f = v
            case .str(let v): record.tag = UInt32(KAYA_TR_STR); record.s = keep(v)
            case .date(let v): record.tag = UInt32(KAYA_TR_DATE); record.i = kayaPackedDate("tr(\(key))", v)
            case .time(let v): record.tag = UInt32(KAYA_TR_TIME); record.i = kayaPackedTime("tr(\(key))", v)
            }
            records.append(record)
        }
        return key.withCString { k in
            records.withUnsafeBufferPointer { buf in
                kayaFilled("tr(\"\(key)\")") { out, cap in
                    kaya_tr(k, buf.baseAddress, UInt(buf.count), out, cap)
                }
            }
        }
    }

    /// This host's capabilities, constant for the life of the process.
    /// `KAYA_CAP_AUX_WINDOWS` is the CORE'S OWN `#define`, imported
    /// through the bridging header, never a copied number.
    public static func capabilities() -> KayaCapabilities {
        let bits = kaya_capabilities()
        return KayaCapabilities(
            auxWindows: bits & UInt64(KAYA_CAP_AUX_WINDOWS) != 0,
            notifications: bits & UInt64(KAYA_CAP_NOTIFICATIONS) != 0,
            badge: bits & UInt64(KAYA_CAP_BADGE) != 0,
            emojiPicker: bits & UInt64(KAYA_CAP_EMOJI_PICKER) != 0)
    }

    private let posted = KayaAppQueue<@KayaAppActor @Sendable (KayaAppTx) throws -> Void>()
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
    /// dispatchLoop answers the ask itself. ONE SHAPE, widened at
    /// registration; the Double is the frame's time in seconds, 0 for a
    /// plain redraw.
    private var draws: [UInt64: (KayaDraw, KayaViewbox, Double) -> Void] = [:]
    private var nodeHandlers: [UInt64: (KayaAppTx, [KayaValue]) throws -> Void] = [:]
    private var widgetChanges: [UInt64: (KayaAppTx, String) throws -> Void] = [:]
    private var nodeChanges: [UInt64: (KayaAppTx, [KayaValue], String) throws -> Void] = [:]
    private var widgetSubmits: [UInt64: (KayaAppTx, String) throws -> Void] = [:]
    private var nodeSubmits: [UInt64: (KayaAppTx, [KayaValue], String) throws -> Void] = [:]
    private var widgetToggles: [UInt64: (KayaAppTx, Bool) throws -> Void] = [:]
    private var widgetValues: [UInt64: (KayaAppTx, Double) throws -> Void] = [:]
    private var nodeValues: [UInt64: (KayaAppTx, [KayaValue], Double) throws -> Void] = [:]
    private var widgetCommits: [UInt64: (KayaAppTx, Double) throws -> Void] = [:]
    private var nodeCommits: [UInt64: (KayaAppTx, [KayaValue], Double) throws -> Void] = [:]
    private var widgetDates: [UInt64: (KayaAppTx, KayaDate) throws -> Void] = [:]
    private var nodeDates: [UInt64: (KayaAppTx, [KayaValue], KayaDate) throws -> Void] = [:]
    private var widgetTimes: [UInt64: (KayaAppTx, KayaTime) throws -> Void] = [:]
    private var nodeTimes: [UInt64: (KayaAppTx, [KayaValue], KayaTime) throws -> Void] = [:]
    // Window lifecycle: one handler each, receiving the window id.
    private var closeRequested: [UInt64: (KayaAppTx) throws -> Void] = [:]
    private var entryPopped: [UInt64: (KayaAppTx) throws -> Void] = [:]
    private var backRequested: [UInt64: (KayaAppTx) throws -> Void] = [:]
    // Per-sheet, keyed by sheet surface id (docs/sheet-plan.md).
    private var sheetDismissed: [UInt64: (KayaAppTx) throws -> Void] = [:]
    private var dismissRequested: [UInt64: (KayaAppTx) throws -> Void] = [:]
    private var sectionSelected: [UInt64: (KayaAppTx) throws -> Void] = [:]
    var alerts: [UInt64: (KayaAppTx, KayaAlertChoice) throws -> Void] = [:]
    var liveAlert: UInt64 = 0
    var liveFileDialog: UInt64 = 0
    // One-shot, keyed by the GUEST's notification id (the alert's
    // request/result grammar; many may be live at once).
    private var notifications: [UInt64: (KayaAppTx, KayaNotificationOutcome) throws -> Void] = [:]
    // NOT one-shot, and not keyed at all: the process-level handler for
    // a result whose id has none above (docs/tasks-s9-plan.md R1). A
    // relaunched process never called showNotification.
    private var notificationActivation: ((KayaAppTx, UInt64, KayaNotificationOutcome) throws -> Void)?
    // NOT one-shot either: a route declared by link answers every URL
    // that matches it, for the life of the process
    // (docs/app-links-plan.md §4), and the core owns the pattern table —
    // nothing is kept here but the handler.
    private var links: [UInt64: (KayaAppTx, [String: String]) throws -> Void] = [:]
    private var nextLinkRoute: UInt64 = 0
    // link may be called before the first transaction, so its record
    // waits here for one (submitIfAny drains it head-first). Module
    // scope, not private: tools/checks/swift-notify reads the bytes back.
    var pendingRoutes = KayaTx()
    var fileDialogs: [UInt64: (KayaAppTx, [KayaPickedFile]) throws -> Void] = [:]
    // Clipboard reads: one-shot, keyed by request id, on the alert's
    // request/result grammar.
    var clipboardReads: [UInt64: (KayaAppTx, KayaRepresentation?) throws -> Void] = [:]
    // The rich mirror, one Document per `rich` textarea
    // (docs/rich-text-plan.md R1): folded from the two occurrences here
    // and from the app's own set_document/apply_edit as they are SENT.
    private var documents: [UInt64: KayaDocument] = [:]
    private var widgetEdits: [UInt64: (KayaAppTx, KayaEdit) throws -> Void] = [:]
    private var widgetFormats: [UInt64: (KayaAppTx, KayaFormat) throws -> Void] = [:]
    // A stamped copy's own acts (docs/rich-text-plan.md §19): the
    // handlers, the template node -> (collection, field) every
    // document-bound textarea registers, and the per-collection pair
    // that reads and rewrites T's Document field by wire index.
    private var nodeEdits: [UInt64: (KayaAppTx, [KayaValue], KayaEdit) throws -> Void] = [:]
    private var nodeFormats: [UInt64: (KayaAppTx, [KayaValue], KayaFormat) throws -> Void] = [:]
    private var documentBinds: [UInt64: (collection: UInt64, field: UInt32)] = [:]
    private var documentFields: [UInt64: (
        read: (Any, UInt32) -> KayaDocument?,
        write: (Any, UInt32, KayaDocument) -> Any
    )] = [:]
    private var widgetPastes: [UInt64: (KayaAppTx, KayaRepresentation) throws -> Void] = [:]
    private var nodePastes: [UInt64: (KayaAppTx, [KayaValue], KayaRepresentation) throws -> Void] = [:]
    private var widgetDrops: [UInt64: (KayaAppTx, KayaDropped) throws -> Void] = [:]
    private var nodeDrops: [UInt64: (KayaAppTx, [KayaValue], KayaDropped) throws -> Void] = [:]
    private var dragEnded: [UInt64: (KayaAppTx, KayaOp?) throws -> Void] = [:]
    private var nodeDragEnded: [UInt64: (KayaAppTx, [KayaValue], KayaOp?) throws -> Void] = [:]
    private var nextClipboardRead: UInt64 = 0
    private var nextAlert: UInt64 = 0
    private var nextFileDialog: UInt64 = 0
    private var windowClosed: [UInt64: (KayaAppTx) throws -> Void] = [:]
    private var nodeToggles: [UInt64: (KayaAppTx, [KayaValue], Bool) throws -> Void] = [:]
    // The two history occurrences, keyed by WINDOW — one ledger per
    // window (docs/undo-plan.md §3) — and PERSISTENT rather than
    // one-shot: a history is walked as often as the user likes.
    private var undone: [UInt64: (KayaAppTx, String, KayaUndoDelta) throws -> Void] = [:]
    private var redone: [UInt64: (KayaAppTx, String, KayaUndoDelta) throws -> Void] = [:]
    // How to rebuild a model entry from the wire fields an undo hands
    // back, per collection. Only the type that declared the collection
    // can make a native value, so each factory leaves its constructor
    // here at declaration — the only moment the type is known.
    private var elementDecoders: [UInt64: (UInt32, [KayaValue]) -> Any] = [:]
    // Menu dispatch tables, keyed by MENU ITEM id — their own id space,
    // separate from every widget/node table. The node flavors receive the
    // stamped copy's key path.
    var menuActivated: [UInt64: (KayaAppTx) throws -> Void] = [:]
    var menuActivatedNode: [UInt64: (KayaAppTx, [KayaValue]) throws -> Void] = [:]
    var menuToggled: [UInt64: (KayaAppTx, Bool) throws -> Void] = [:]
    var menuToggledNode: [UInt64: (KayaAppTx, [KayaValue], Bool) throws -> Void] = [:]
    var menuSelected: [UInt64: (KayaAppTx, Int) throws -> Void] = [:]
    var menuSelectedNode: [UInt64: (KayaAppTx, [KayaValue], Int) throws -> Void] = [:]

    nonisolated(unsafe) static var ambient: KayaApp?
    // The app thread, claimed by dispatchLoop and read at every
    // transaction gate (requireAppThread). Nil until then, which is what
    // lets the guest's opening build run on the main thread before run().
    nonisolated(unsafe) static var appThread: Thread?

    /// Called by dispatchLoop on the way in: from here on that thread IS
    /// the app thread.
    static func claimAppThread() { appThread = Thread.current }

    /// The other half of the rule KayaAppTx.alive states: OPEN is not
    /// enough, a transaction also belongs to the app thread. `closed`
    /// cannot see a Task continuation writing through a still-open
    /// transaction, nor a background build opening one of its own
    /// (tools/check-tx-liveness.py).
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
    // (a frame per open container). Constructors parent AT CREATION,
    // never at expression position — that silently drops any let-bound
    // child — and the zone tag makes a cross-zone child loud.
    struct KayaFrame {
        let template: Bool
        var ids: [UInt64] = []
    }

    var childFrames: [KayaFrame] = []

    /// A live widget parents into the open live frame at creation.
    fileprivate func parentAtCreation(live id: UInt64) {
        guard let top = childFrames.indices.last else { return }
        precondition(
            !childFrames[top].template,
            "kaya: a live widget cannot be created inside a template body")
        childFrames[top].ids.append(id)
    }

    /// A template node parents into the open template frame at creation;
    /// with no template frame open it is template-rooted and the scope
    /// itself carries it.
    fileprivate func parentAtCreation(node id: UInt64) {
        if let top = childFrames.indices.last, childFrames[top].template {
            childFrames[top].ids.append(id)
        }
    }

    /// Run a For's or a When's body behind a PARENT BARRIER: a node created
    /// directly in that body is a ROOT of the template it declares, never a
    /// child of whatever container encloses the combinator.
    fileprivate func inTemplateBody<R>(_ body: () -> R) -> R {
        childFrames.append(KayaFrame(template: true))
        defer { childFrames.removeLast() }
        return body()
    }
    var openTraces = 0
    // The record-time mirror-read guard's arming counter: >0 while any
    // template body is being DECLARED.
    var tplDepth = 0

    public init() {
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

    /// Journal one collection's instances into the open transaction the
    /// first time it mutates them.
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
    /// anyone asked. One instance per stamped copy, not one per entry, so
    /// this list stays short.
    private func instanceSlot(_ coll: UInt64, _ path: [KayaValue]) -> Int {
        if let at = model[coll]?.firstIndex(where: { $0.path == path }) { return at }
        model[coll, default: []].append(KayaInstance(path: path))
        return model[coll]!.count - 1
    }

    fileprivate func modelSet(_ coll: UInt64, _ path: [KayaValue], _ key: KayaValue, _ value: Any) {
        touchModel(coll)
        let at = instanceSlot(coll, path)
        // IN PLACE, through the default subscript: a `var copy = ...` /
        // `model[coll] = copy` round trip copies every entry on every
        // insert (docs/deferred.md, the Swift binding's quadratic insert).
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
        // A missing key or anchor is a guest bug, never a fallback.
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

    /// Fold an undo's payload into the mirrors this binding keeps.
    ///
    /// NOT INSIDE A TRANSACTION, and it must not be: the core moved
    /// without one, so sending records would apply the undo a second
    /// time. The derived recompute does NOT re-run — whatever the group
    /// wrote to a derived signal is in this same payload.
    fileprivate func absorbUndo(_ delta: KayaUndoDelta) {
        for (signal, value) in delta.signals {
            signalMirrors[signal] = value
        }
        for entry in delta.entries {
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
            // not name at the end.
            model[order.collection, default: []][at].reorder(order.keys)
        }
    }

    func nextSignal() -> KayaSignal {
        signals += 1
        return KayaSignal(id: signals)
    }

    @discardableResult
    func nextWidget() -> KayaWidget {
        widgets += 1
        return KayaWidget(id: widgets)
    }

    @discardableResult
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
    public func build<R>(_ build: (KayaAppTx) throws -> R) rethrows -> R {
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

    /// Register the table's header-click handler at its For — the handler
    /// receives the 0-based column of a sort REQUEST: nothing has changed
    /// on screen; reorder the collection by key and re-declare the header
    /// with columns (docs/tables-plan.md).
    public func onSort(_ w: KayaWidget, _ handler: @escaping (KayaAppTx, UInt32) throws -> Void) {
        sortHandlers[w.id] = handler
    }

    /// The same registration for a NESTED For. The handler receives the
    /// clicked copy's keys, outermost first, before the column; hand them
    /// back to `KayaAppTx.columns(_:at:_:_:)` to move that copy's
    /// indicator (docs/tables-plan.md, dynamic tables).
    public func onSort(
        _ n: KayaNodeHandle, _ handler: @escaping (KayaAppTx, [KayaValue], UInt32) throws -> Void
    ) {
        nodeSorts[n.id] = handler
    }

    public func onClick(_ w: KayaWidget, _ handler: @escaping (KayaAppTx) throws -> Void) {
        widgetHandlers[w.id] = handler
    }

    /// The registration half of `KayaWidget.onDraw` / `KayaWidget.onTick`.
    /// NOT PUBLIC on purpose: registering the closure and declaring the
    /// policy on the wire are ONE act (docs/canvas-plan.md §3.2.1).
    fileprivate func registerDraw(
        _ canvas: UInt64, _ f: @escaping (KayaDraw, KayaViewbox, Double) -> Void
    ) {
        draws[canvas] = f
    }

    /// Register a click handler for a template node; it also receives
    /// the stamped copy's keys, outermost first.
    public func onClick(_ n: KayaNodeHandle, _ handler: @escaping (KayaAppTx, [KayaValue]) throws -> Void) {
        nodeHandlers[n.id] = handler
    }

    /// Register a change handler for a live entry: the widget owns its
    /// text and reports each edit here. There is no read-back.
    public func onChange(_ w: KayaWidget, _ handler: @escaping (KayaAppTx, String) throws -> Void) {
        widgetChanges[w.id] = handler
    }

    /// Register a change handler for a template entry; it also receives
    /// the stamped copy's keys, outermost first.
    func onChange(
        _ n: KayaNodeHandle, _ handler: @escaping (KayaAppTx, [KayaValue], String) throws -> Void
    ) {
        nodeChanges[n.id] = handler
    }

    /// The field's text when the user SUBMITTED it (docs/submit-plan.md S7):
    /// Return in an entry or a search field, the send gesture on a `submits`
    /// textarea. `onChange` has already carried every edit.
    public func onSubmitted(_ w: KayaWidget, _ handler: @escaping (KayaAppTx, String) throws -> Void) {
        widgetSubmits[w.id] = handler
    }

    /// Register a submit handler for a template field; it also receives
    /// the stamped copy's keys, outermost first.
    func onSubmitted(
        _ n: KayaNodeHandle, _ handler: @escaping (KayaAppTx, [KayaValue], String) throws -> Void
    ) {
        nodeSubmits[n.id] = handler
    }

    /// One addressed user edit of a `rich` textarea; `onChange` still
    /// fires beside it (docs/rich-text-plan.md R1).
    func onEdit(_ w: KayaWidget, _ handler: @escaping (KayaAppTx, KayaEdit) throws -> Void) {
        widgetEdits[w.id] = handler
    }

    /// The user formatted a range; a format over a collapsed caret is
    /// pending state and arrives as the next edit's runs, never here.
    func onFormat(_ w: KayaWidget, _ handler: @escaping (KayaAppTx, KayaFormat) throws -> Void) {
        widgetFormats[w.id] = handler
    }

    /// One addressed user edit of a STAMPED copy's rich textarea: the
    /// handler receives that copy's keys, outermost first. The row's
    /// Document field already carries the edit when it fires, so the app
    /// reads the row and never the widget (docs/rich-text-plan.md §19).
    public func onEdit(
        _ n: KayaNodeHandle,
        _ handler: @escaping (KayaAppTx, [KayaValue], KayaEdit) throws -> Void
    ) {
        nodeEdits[n.id] = handler
    }

    /// The same for a stamped copy's toolbar act.
    public func onFormat(
        _ n: KayaNodeHandle,
        _ handler: @escaping (KayaAppTx, [KayaValue], KayaFormat) throws -> Void
    ) {
        nodeFormats[n.id] = handler
    }

    /// A document-bound template textarea's node, against the For it was
    /// declared in and the row field it reads.
    fileprivate func bindDocument(node: UInt64, field: UInt32) {
        guard let collection = openFors.last else { return }
        documentBinds[node] = (collection: collection, field: field)
    }

    /// How THIS collection's element type reads and rewrites a Document
    /// field by wire index; registered by the collection factory, the one
    /// place T is known (KayaRecords.swift).
    func registerDocumentField(
        _ coll: UInt64,
        read: @escaping (Any, UInt32) -> KayaDocument?,
        write: @escaping (Any, UInt32, KayaDocument) -> Any
    ) {
        documentFields[coll] = (read: read, write: write)
    }

    /// A stamped copy's edit or format act reaches its ROW's Document
    /// field (docs/rich-text-plan.md §19, crates/kaya/src/app.rs
    /// `fold_row_document`): the node is bound to (collection, field) by
    /// the document-bound template textarea, and the occurrence's keys
    /// name the row. A row that is gone has no field to fold into, and
    /// that is not a fault.
    func foldRowDocument(
        _ node: UInt64, _ keys: [KayaValue], _ fold: (inout KayaDocument) -> Void
    ) {
        guard let bind = documentBinds[node], let key = keys.last,
            let field = documentFields[bind.collection]
        else { return }
        let path = Array(keys.dropLast())
        guard let entry = instanceEntries(bind.collection, path).first(where: { $0.key == key }),
            var doc = field.read(entry.value, bind.field)
        else { return }
        fold(&doc)
        modelSet(bind.collection, path, key, field.write(entry.value, bind.field, doc))
    }

    /// The folded document of a `rich` textarea; empty until the first
    /// edit or write.
    public func document(_ w: KayaWidget) -> KayaDocument {
        documents[w.id] ?? KayaDocument()
    }

    /// Seed from a write, so a read after `setDocument` answers it.
    fileprivate func seedDocument(_ widget: UInt64, _ document: KayaDocument) {
        documents[widget] = document
    }

    /// One delivered edit, folded into the live widget's mirror.
    fileprivate func absorbEdit(
        _ widget: UInt64, _ start: Int, _ end: Int, _ inserted: String, _ runs: [KayaRun]
    ) {
        var doc = documents[widget] ?? KayaDocument()
        kayaFoldEdit(&doc, start, end, inserted, runs)
        documents[widget] = doc
    }
    /// A ranged act's range in the fold's text: a `block` covers the whole
    /// paragraphs it touches, as the core snaps it
    /// (docs/rich-text-plan.md §17).
    fileprivate func rangedActBounds(
        _ widget: UInt64, _ range: Range<Int>, _ name: String
    ) -> Range<Int> {
        guard name == "block" else { return range }
        let bytes = Array((documents[widget]?.text ?? "").utf8)
        let start = min(range.lowerBound, bytes.count)
        let stop = min(range.upperBound, bytes.count)
        var paraStart = 0
        var back = start - 1
        while back >= 0 {
            if bytes[back] == 0x0A {
                paraStart = back + 1
                break
            }
            back -= 1
        }
        var paraEnd = bytes.count
        var ahead = stop
        while ahead < bytes.count {
            if bytes[ahead] == 0x0A {
                paraEnd = ahead
                break
            }
            ahead += 1
        }
        return paraStart..<paraEnd
    }

    /// One delivered format act, folded into the live widget's mirror.
    fileprivate func absorbFormat(
        _ widget: UInt64, _ start: Int, _ end: Int, _ name: String, _ value: String?
    ) {
        var doc = documents[widget] ?? KayaDocument()
        kayaFoldFormat(&doc, start, end, name, value)
        documents[widget] = doc
    }
    /// Register a toggle handler for a live checkbox: the box owns its
    /// checked bit and reports each flip here.
    func onToggle(_ w: KayaWidget, _ handler: @escaping (KayaAppTx, Bool) throws -> Void) {
        widgetToggles[w.id] = handler
    }

    /// A live slider's change handler: the bar owns its position and
    /// reports each move with the new value.
    func onValueChanged(_ w: KayaWidget, _ handler: @escaping (KayaAppTx, Double) throws -> Void) {
        widgetValues[w.id] = handler
    }

    /// A template slider's or choice widget's change handler; it also
    /// receives the stamped copy's keys, outermost first.
    func onValueChanged(
        _ n: KayaNodeHandle, _ handler: @escaping (KayaAppTx, [KayaValue], Double) throws -> Void
    ) {
        nodeValues[n.id] = handler
    }

    /// The value a live slider's gesture SETTLED ON — once per release or
    /// key move, after that gesture's moves (docs/slider-plan.md S2).
    func onValueCommitted(_ w: KayaWidget, _ handler: @escaping (KayaAppTx, Double) throws -> Void) {
        widgetCommits[w.id] = handler
    }

    /// A template slider's settled value, the stamped copy's keys first.
    func onValueCommitted(
        _ n: KayaNodeHandle, _ handler: @escaping (KayaAppTx, [KayaValue], Double) throws -> Void
    ) {
        nodeCommits[n.id] = handler
    }

    /// Register a toggle handler for a template checkbox; it also
    /// receives the stamped copy's keys, outermost first.
    func onToggle(
        _ n: KayaNodeHandle, _ handler: @escaping (KayaAppTx, [KayaValue], Bool) throws -> Void
    ) {
        nodeToggles[n.id] = handler
    }

    /// Register a pick handler for a live date picker: the control owns
    /// its value and reports each COMMITTED pick here; a programmatic
    /// write never echoes (docs/datetime-plan.md D7).
    func onDate(_ w: KayaWidget, _ handler: @escaping (KayaAppTx, KayaDate) throws -> Void) {
        widgetDates[w.id] = handler
    }

    /// Register a pick handler for a template date picker; it also
    /// receives the stamped copy's keys, outermost first.
    func onDate(
        _ n: KayaNodeHandle, _ handler: @escaping (KayaAppTx, [KayaValue], KayaDate) throws -> Void
    ) {
        nodeDates[n.id] = handler
    }

    /// Register a pick handler for a live time picker.
    func onTime(_ w: KayaWidget, _ handler: @escaping (KayaAppTx, KayaTime) throws -> Void) {
        widgetTimes[w.id] = handler
    }

    /// Register a pick handler for a template time picker, keys first.
    func onTime(
        _ n: KayaNodeHandle, _ handler: @escaping (KayaAppTx, [KayaValue], KayaTime) throws -> Void
    ) {
        nodeTimes[n.id] = handler
    }

    public var post: @Sendable (@escaping @KayaAppActor @Sendable (KayaAppTx) throws -> Void) -> Void {
        posted.append
    }

    // docs/async-dialogs-plan.md section 2.1; tools/check-abort.py
    @KayaAppActor public func task(
        _ body: @escaping @KayaAppActor @Sendable () async throws -> Void
    ) {
        KayaApp.requireAppThread()
        precondition(tplDepth == 0, "kaya: async work cannot be started inside a template body")
        Task { @KayaAppActor in
            requireAsyncBoundary()
            do {
                try await body()
            } catch {
                requireAsyncBoundary()
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                FileHandle.standardError.write(Data((
                    "kaya: async handler failed; no transaction was rolled back by this reporter; "
                        + "completed transactions remain committed\n").utf8))
            }
        }
    }

    @KayaAppActor func requireAsyncBoundary() {
        KayaApp.requireAppThread()
        precondition(currentTx == nil, "kaya: async work cannot run inside a transaction")
        precondition(tplDepth == 0, "kaya: async dialogs cannot be requested inside a template body")
    }

    @KayaAppActor private func requestAsync<T: Sendable>(
        _ send: (KayaAppTx, @escaping (T) -> Void) -> Void
    ) async -> T {
        requireAsyncBoundary()
        let answer: T = await withCheckedContinuation { continuation in
            build { tx in send(tx, { continuation.resume(returning: $0) }) }
        }
        requireAsyncBoundary()
        return answer
    }

    @KayaAppActor public func showAlert(
        title: String = "", message: String = "",
        actions: [String] = [], cancel: String, window: UInt64 = 0
    ) async -> KayaAlertChoice {
        await requestAsync { tx, resolve in
            tx.showAlert(title: title, message: message, actions: actions,
                         cancel: cancel, window: window) { _, choice in resolve(choice) }
        }
    }

    @KayaAppActor public func pickFile(
        filters: [(String, String)] = [], window: UInt64 = 0
    ) async -> [KayaPickedFile] {
        await requestAsync { tx, resolve in
            tx.pickFile(filters: filters, window: window) { _, files in resolve(files) }
        }
    }

    @KayaAppActor public func pickFiles(
        filters: [(String, String)] = [], window: UInt64 = 0
    ) async -> [KayaPickedFile] {
        await requestAsync { tx, resolve in
            tx.pickFiles(filters: filters, window: window) { _, files in resolve(files) }
        }
    }

    @KayaAppActor public func saveFile(
        suggestedName: String, filters: [(String, String)] = [], window: UInt64 = 0
    ) async -> KayaPickedFile? {
        await requestAsync { tx, resolve in
            tx.saveFile(suggestedName: suggestedName, filters: filters, window: window) {
                _, file in resolve(file)
            }
        }
    }

    @KayaAppActor public func readClipboard(accepting: [String] = []) async -> KayaRepresentation? {
        await requestAsync { tx, resolve in
            var request = tx.readClipboard()
            for kind in accepting { request = request.custom(kind) }
            request.onResult { _, clip in resolve(clip) }.send()
        }
    }

    /// Run everything posted, each as its own transaction, in order.
    @KayaAppActor private func drainPosted() {
        for body in posted.takeAll() {
            dispatch { try build { tx in try body(tx) } }
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
    /// sugar registers at declaration; the closed one retires with its
    /// window).
    func onCloseRequested(_ window: UInt64, _ handler: @escaping (KayaAppTx) throws -> Void) {
        closeRequested[window] = handler
    }

    /// Bind the one-shot result handler to a request; the registration
    /// retires with the result.
    func onAlert(_ alert: UInt64, _ handler: ((KayaAppTx, KayaAlertChoice) throws -> Void)?) {
        liveAlert = alert
        if let handler { alerts[alert] = handler }
        currentTx!.rollbackActions.append { [self] in
            alerts.removeValue(forKey: alert)
            if liveAlert == alert { liveAlert = 0 }
        }
    }

    func alertResult(_ id: UInt64, _ choice: KayaAlertChoice) {
        if liveAlert == id { liveAlert = 0 }
        if let handler = alerts.removeValue(forKey: id) {
            dispatch { try build { tx in try handler(tx, choice) } }
        }
    }

    /// Bind a notification's one-shot result handler; the registration
    /// retires with the result.
    func onNotification(
        _ notification: UInt64,
        _ handler: @escaping (KayaAppTx, KayaNotificationOutcome) throws -> Void
    ) {
        notifications[notification] = handler
    }

    /// Register the PROCESS-LEVEL notification handler
    /// (docs/tasks-s9-plan.md R1): it receives every result whose id has
    /// no one-shot handler bound at showNotification — which is the
    /// whole of a process the platform RELAUNCHED for a tap, since it
    /// never called showNotification. It does not retire, and a one-shot
    /// handler for the same id still wins.
    func onNotificationActivation(
        _ handler: @escaping (KayaAppTx, UInt64, KayaNotificationOutcome) throws -> Void
    ) {
        notificationActivation = handler
    }

    /// Declare a link ROUTE and the handler that answers it
    /// (docs/app-links-plan.md §4): `link("task/{key}", f)` matches
    /// `<scheme>://task/t1` and calls f with `["key": "t1"]`. Segments
    /// split on `/`, `{name}` captures one segment, a literal segment
    /// matches itself; the query's pairs join the params and a capture
    /// wins a name clash.
    ///
    /// PROCESS-LEVEL, `onNotificationActivation`'s shape: it does not
    /// retire and it needs no transaction — declared before the first
    /// one the record waits and rides the head of it, declared inside a
    /// handler it rides that handler's. A URL that arrives before the
    /// app thread exists is delivered first, and one no route matched is
    /// announced by the core and reaches nothing here.
    ///
    /// NOTHING HERE READS THE PATTERN. The core is the one parser and
    /// the one author of every refusal — an empty pattern, an empty
    /// segment, a malformed one, a duplicate — and it faults at apply
    /// with the whole sentence, where every other declaration refusal in
    /// kaya lands (tools/check-sugar-surface.py refuses a reason spelled
    /// here).
    func link(
        _ pattern: String,
        _ handler: @escaping (KayaAppTx, [String: String]) throws -> Void
    ) {
        nextLinkRoute += 1
        links[nextLinkRoute] = handler
        pendingRoutes.declareLinkRoute(nextLinkRoute, .str(pattern))
    }

    /// The pending route declarations, taken and cleared: they lead the
    /// next transaction's bytes.
    func takePendingRoutes() -> Data {
        let bytes = pendingRoutes.bytes
        pendingRoutes = KayaTx()
        return bytes
    }

    /// The link_opened decision, in a method of its own because the ring
    /// loop's switch has no seam a test can reach (the ring is C memory)
    /// — `notificationResult` for the same reason, and
    /// tools/checks/swift-notify drives the cases through here. TWO DROPS
    /// WITH DISJOINT CAUSES (docs/app-links-plan.md §4): route 0 is a URL
    /// NO ROUTE TOOK, which the core announced naming every declared
    /// pattern, so it is silent here; a route that matched and reached no
    /// handler is this binding's to announce, naming its own registrar.
    func linkOpened(_ route: UInt64, _ url: String, _ params: [String: String]) {
        if let handler = links[route] {
            dispatch { try build { tx in try handler(tx, params) } }
        } else if route != 0 {
            FileHandle.standardError.write(Data((
                "kaya: link \(url) matched route \(route) and reached no "
                + "handler — none is registered for it "
                + "(KayaApp.link)\n").utf8))
        }
    }

    func allocAlert() -> UInt64 {
        precondition(liveAlert == 0, "kaya: another alert is already live; wait for its result before showing the next")
        nextAlert += 1
        return nextAlert
    }

    /// Bind a clipboard read's one-shot result handler.
    func onClipboard(
        _ request: UInt64, _ handler: ((KayaAppTx, KayaRepresentation?) throws -> Void)?
    ) {
        if let handler { clipboardReads[request] = handler }
        currentTx!.rollbackActions.append { [self] in clipboardReads.removeValue(forKey: request) }
    }

    func clipboardResult(_ id: UInt64, _ answer: KayaRepresentation?) {
        if let handler = clipboardReads.removeValue(forKey: id) {
            dispatch { try build { tx in try handler(tx, answer) } }
        }
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

    func onDrop(
        _ w: KayaWidget,
        _ handler: @escaping (KayaAppTx, KayaDropped) throws -> Void
    ) {
        widgetDrops[w.id] = handler
    }

    func onDragEnded(
        _ w: KayaWidget,
        _ handler: @escaping (KayaAppTx, KayaOp?) throws -> Void
    ) {
        dragEnded[w.id] = handler
    }

    func onDrop(
        _ n: KayaNodeHandle,
        _ handler: @escaping (KayaAppTx, [KayaValue], KayaDropped) throws -> Void
    ) {
        nodeDrops[n.id] = handler
    }

    func onDragEnded(
        _ n: KayaNodeHandle,
        _ handler: @escaping (KayaAppTx, [KayaValue], KayaOp?) throws -> Void
    ) {
        nodeDragEnded[n.id] = handler
    }

    /// Bind the picker's one-shot result handler; it retires with the
    /// result.
    func onFileDialog(
        _ dialog: UInt64, _ handler: ((KayaAppTx, [KayaPickedFile]) throws -> Void)?
    ) {
        liveFileDialog = dialog
        if let handler { fileDialogs[dialog] = handler }
        currentTx!.rollbackActions.append { [self] in
            fileDialogs.removeValue(forKey: dialog)
            if liveFileDialog == dialog { liveFileDialog = 0 }
        }
    }

    func fileDialogResult(_ id: UInt64, _ files: [KayaPickedFile]) {
        if liveFileDialog == id { liveFileDialog = 0 }
        if let handler = fileDialogs.removeValue(forKey: id) {
            dispatch { try build { tx in try handler(tx, files) } }
        }
    }

    func allocFileDialog() -> UInt64 {
        precondition(liveFileDialog == 0, "kaya: another file dialog is already live; wait for its result before showing the next")
        nextFileDialog += 1
        return nextFileDialog
    }

    func onWindowClosed(_ window: UInt64, _ handler: @escaping (KayaAppTx) throws -> Void) {
        windowClosed[window] = handler
    }

    /// Per-entry navigation registrations; the popped one retires with
    /// its one pop.
    func onEntryPopped(_ entry: UInt64, _ handler: @escaping (KayaAppTx) throws -> Void) {
        entryPopped[entry] = handler
    }

    func onBackRequested(_ entry: UInt64, _ handler: @escaping (KayaAppTx) throws -> Void) {
        backRequested[entry] = handler
    }

    /// Per-sheet registrations; the dismissed one retires with its one
    /// dismissal.
    func onSheetDismissed(_ sheet: UInt64, _ handler: @escaping (KayaAppTx) throws -> Void) {
        sheetDismissed[sheet] = handler
    }

    func onDismissRequested(_ sheet: UInt64, _ handler: @escaping (KayaAppTx) throws -> Void) {
        dismissRequested[sheet] = handler
    }

    /// Per-section, NOT one-shot: the user can return any number of
    /// times; a programmatic selectSection never fires it (the echo
    /// doctrine).
    func onSectionSelected(_ section: UInt64, _ handler: @escaping (KayaAppTx) throws -> Void) {
        sectionSelected[section] = handler
    }

    /// kaya routed an undo in this window, and this is what the CORE put
    /// back. The ledger is per window.
    func onUndone(
        _ window: UInt64, _ handler: @escaping (KayaAppTx, String, KayaUndoDelta) throws -> Void
    ) {
        undone[window] = handler
    }

    /// The onUndone twin, same payload, opposite direction. A frontier
    /// typing episode redoes natively and never arrives here — it is the
    /// platform's own stack moving, reported by its text_changed.
    func onRedone(
        _ window: UInt64, _ handler: @escaping (KayaAppTx, String, KayaUndoDelta) throws -> Void
    ) {
        redone[window] = handler
    }

    @KayaAppActor private func dispatchLoop() {
        KayaApp.claimAppThread()
        var record: UnsafePointer<UInt8>?
        while true {
            KayaAppExecutor.shared.drain()
            // Posted work first, then the ring: draining at the TOP is
            // what makes a wake sufficient.
            drainPosted()
            let size = kaya_next_occurrence(&record)
            if size == KAYA_OCCURRENCE_SHUTDOWN { return }
            if size == KAYA_OCCURRENCE_WOKEN {
                // NO RECORD WAS HANDED OUT: decoding here would re-parse
                // the PREVIOUS one.
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
            guard let (kind, id, keys, payload, files, clip, drop, tail) = kayaParseOccurrence(buf)
            else { continue }
            var text: String?
            var checked = false
            var value = 0.0
            var choice: UInt32 = 0
            var packed: Int64 = 0
            switch payload {
            case .str(let s): text = s
            case .bool(let b): checked = b
            case .f64(let x): value = x
            // The alert parser boxes the u32 choice as .i64; a picker's
            // committed value rides the same tag, unnarrowed.
            case .i64(let n):
                choice = UInt32(truncatingIfNeeded: n)
                packed = n
            default: break
            }
            switch (kind, keys.isEmpty) {
            // THE CANVAS'S TWO ASKS ARE ANSWERED HERE AND NEVER MAPPED
            // (docs/canvas-plan.md §3.2.1): this draws, submits the one
            // record and keeps looping, in the binding's own transaction
            // (tools/check-ambient-tx.py). The keys are not consulted —
            // only a KayaWidget can carry a policy.
            case (UInt16(KAYA_OCCURRENCE_DRAW_REQUESTED), _),
                (UInt16(KAYA_OCCURRENCE_TICK), _):
                if let drawing = draws[id], let size = kayaAssignedSize(tail) {
                    let time = kayaFrameTime(tail)
                    // The size that arrived IS this canvas's viewbox from
                    // here on, so a later plain `draw` uses it too.
                    canvasViewboxes[id] = size
                    let canvas = KayaWidget(id: id)
                    // No `dispatch` wrapper: a drawing handler cannot
                    // throw, so there is no error for it to log.
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
            case (UInt16(KAYA_OCCURRENCE_SUBMITTED), true):
                if let handler = widgetSubmits[id] {
                    dispatch { try build { tx in try handler(tx, text ?? "") } }
                }
            case (UInt16(KAYA_OCCURRENCE_SUBMITTED), false):
                if let handler = nodeSubmits[id] {
                    dispatch { try build { tx in try handler(tx, keys, text ?? "") } }
                }
            // THE MIRROR IS FOLDED BEFORE THE HANDLER RUNS, so a handler
            // reading `document` sees the edit it was told about
            // (docs/rich-text-plan.md R1).
            case (UInt16(KAYA_OCCURRENCE_TEXT_EDITED), true):
                let edit = kayaEditFromTail(tail)
                absorbEdit(id, edit.range.lowerBound, edit.range.upperBound, edit.inserted, edit.runs)
                if let handler = widgetEdits[id] {
                    dispatch { try build { tx in try handler(tx, edit) } }
                }
            // A STAMPED COPY FOLDS INTO ITS ROW, never into a mirror the
            // app cannot address (docs/rich-text-plan.md §19).
            case (UInt16(KAYA_OCCURRENCE_TEXT_EDITED), false):
                let edit = kayaEditFromTail(tail)
                foldRowDocument(id, keys) { doc in
                    kayaFoldEdit(&doc, edit.range.lowerBound, edit.range.upperBound, edit.inserted, edit.runs)
                }
                if let handler = nodeEdits[id] {
                    dispatch { try build { tx in try handler(tx, keys, edit) } }
                }
            case (UInt16(KAYA_OCCURRENCE_TEXT_FORMATTED), true):
                let act = kayaFormatFromTail(tail)
                absorbFormat(id, act.range.lowerBound, act.range.upperBound, act.name, act.value)
                if let handler = widgetFormats[id] {
                    dispatch { try build { tx in try handler(tx, act) } }
                }
            case (UInt16(KAYA_OCCURRENCE_TEXT_FORMATTED), false):
                let act = kayaFormatFromTail(tail)
                foldRowDocument(id, keys) { doc in
                    kayaFoldFormat(&doc, act.range.lowerBound, act.range.upperBound, act.name, act.value)
                }
                if let handler = nodeFormats[id] {
                    dispatch { try build { tx in try handler(tx, keys, act) } }
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
            case (UInt16(KAYA_OCCURRENCE_VALUE_COMMITTED), true):
                if let handler = widgetCommits[id] {
                    dispatch { try build { tx in try handler(tx, value) } }
                }
            case (UInt16(KAYA_OCCURRENCE_VALUE_COMMITTED), false):
                if let handler = nodeCommits[id] {
                    dispatch { try build { tx in try handler(tx, keys, value) } }
                }
            case (UInt16(KAYA_OCCURRENCE_DATE_CHANGED), true):
                if let handler = widgetDates[id] {
                    dispatch { try build { tx in try handler(tx, kayaDate(packed: packed)) } }
                }
            case (UInt16(KAYA_OCCURRENCE_DATE_CHANGED), false):
                if let handler = nodeDates[id] {
                    dispatch {
                        try build { tx in try handler(tx, keys, kayaDate(packed: packed)) }
                    }
                }
            case (UInt16(KAYA_OCCURRENCE_TIME_CHANGED), true):
                if let handler = widgetTimes[id] {
                    dispatch { try build { tx in try handler(tx, kayaTime(packed: packed)) } }
                }
            case (UInt16(KAYA_OCCURRENCE_TIME_CHANGED), false):
                if let handler = nodeTimes[id] {
                    dispatch {
                        try build { tx in try handler(tx, keys, kayaTime(packed: packed)) }
                    }
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
            case (UInt16(KAYA_OCCURRENCE_SHEET_DISMISSED), _):
                // One-shot: the sheet is gone; both registrations
                // retire with it.
                dismissRequested.removeValue(forKey: id)
                if let handler = sheetDismissed.removeValue(forKey: id) {
                    dispatch { try build(handler) }
                }
            case (UInt16(KAYA_OCCURRENCE_DISMISS_REQUESTED), _):
                if let handler = dismissRequested[id] {
                    dispatch { try build(handler) }
                }
            case (UInt16(KAYA_OCCURRENCE_SECTION_SELECTED), _):
                // NOT one-shot: sections never die (id is the section;
                // the window rides as the payload).
                if let handler = sectionSelected[id] {
                    dispatch { try build(handler) }
                }
            case (UInt16(KAYA_OCCURRENCE_ALERT_RESULT), _):
                alertResult(id, KayaAlertChoice.fromWire(choice))
            case (UInt16(KAYA_OCCURRENCE_LINK_OPENED), _):
                // id is the ROUTE the core matched
                // (docs/app-links-plan.md §4), and NOT one-shot.
                linkOpened(id, kayaLinkUrl(tail), kayaLinkParams(tail))
            case (UInt16(KAYA_OCCURRENCE_NOTIFICATION_RESULT), _):
                notificationResult(id, choice)
            case (UInt16(KAYA_OCCURRENCE_CLIPBOARD_RESULT), _):
                clipboardResult(id, kayaRepresentation(clip))
            // A paste rides a click tag verbatim: one record kind, the
            // key path deciding.
            case (UInt16(KAYA_OCCURRENCE_PASTED), true):
                if let handler = widgetPastes[id], let answer = kayaRepresentation(clip) {
                    dispatch { try build { tx in try handler(tx, answer) } }
                }
            case (UInt16(KAYA_OCCURRENCE_PASTED), false):
                if let handler = nodePastes[id], let answer = kayaRepresentation(clip) {
                    dispatch { try build { tx in try handler(tx, keys, answer) } }
                }
            // A drop rides the same tag with four more words
            // (docs/dnd-plan.md D1), so it arrives on the ordinary
            // widget/node split — a stamped copy's landing and a
            // reorderable row's own drag_ended carry the copy's keys (§4).
            case (UInt16(KAYA_OCCURRENCE_DROPPED), true):
                if let handler = widgetDrops[id], let drop {
                    let answer = kayaDropped(drop)
                    dispatch { try build { tx in try handler(tx, answer) } }
                }
            case (UInt16(KAYA_OCCURRENCE_DROPPED), false):
                if let handler = nodeDrops[id], let drop {
                    let answer = kayaDropped(drop)
                    dispatch { try build { tx in try handler(tx, keys, answer) } }
                }
            case (UInt16(KAYA_OCCURRENCE_DRAG_ENDED), true):
                if let handler = dragEnded[id] {
                    let answer = kayaOperation(choice)
                    dispatch { try build { tx in try handler(tx, answer) } }
                }
            case (UInt16(KAYA_OCCURRENCE_DRAG_ENDED), false):
                if let handler = nodeDragEnded[id] {
                    let answer = kayaOperation(choice)
                    dispatch { try build { tx in try handler(tx, keys, answer) } }
                }
            case (UInt16(KAYA_OCCURRENCE_FILE_DIALOG_RESULT), _):
                fileDialogResult(id, files)
            // Menu occurrences key the menu-item tables — their own id
            // space, so neither widget nor node ids can collide with
            // them.
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

    public static func run(
        _ setup: @escaping @KayaAppActor @Sendable (KayaApp) throws -> Void
    ) -> Never {
        verifySpec()
        start(setup)
        exit(kaya_run())
    }

    static func start(_ setup: @escaping @KayaAppActor @Sendable (KayaApp) throws -> Void) {
        Task { @KayaAppActor in
            let app = KayaApp()
            KayaApp.claimAppThread()
            do {
                try setup(app)
            } catch {
                FileHandle.standardError.write(Data("kaya: app setup threw: \(error)\n".utf8))
                exit(1)
            }
            app.dispatchLoop()
        }
        Thread { KayaAppExecutor.shared.serve() }.start()
    }

    private static func verifySpec() {
        // The stale-artifact guard: the loaded library must speak the
        // spec revision this binding was generated from.
        precondition(
            kaya_spec_hash() == kayaSpecHash,
            "kaya: library speaks spec \(String(kaya_spec_hash(), radix: 16)), this binding "
                + "was generated from \(String(kayaSpecHash, radix: 16)) — rebuild the "
                + "library or regenerate bindings")
    }

    @available(swift, obsoleted: 6, message: "Use KayaApp.run { app in ... } so construction and handlers belong to KayaAppActor.")
    public func run() -> Never {
        Self.verifySpec()
        // The app object crosses to the app thread here and the
        // calling thread never touches it again; tools/check-pins.py
        // names every nonisolated(unsafe) site.
        nonisolated(unsafe) let app = self
        Task { @KayaAppActor in app.dispatchLoop() }
        let thread = Thread { KayaAppExecutor.shared.serve() }
        thread.start()
        exit(kaya_run())
    }
}

@resultBuilder
public enum KayaNodeChildren {
    // Parenting happens at creation; see KayaChildren.
    public static func buildExpression(_ n: KayaNodeHandle) {
        _ = n
    }

    public static func buildExpression(_: Void) {}

    public static func buildBlock(_: Void...) {}

    public static func buildArray(_: [Void]) {}
}

/// The for-statement tracer over a record collection's rows: the loop body
/// runs ONCE, authoring the For's template. The tracer opens the template on
/// the first element and closes it when the loop asks for a second.
public struct KayaRowTrace<Row>: Sequence, IteratorProtocol {
    let collection: KayaCollection
    let makeRow: (KayaTpl) -> Row
    private var state = 0
    private var forId: UInt64 = 0

    public init(collection: KayaCollection, makeRow: @escaping (KayaTpl) -> Row) {
        self.collection = collection
        self.makeRow = makeRow
    }

    public mutating func next() -> Row? {
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
            // here, and submitIfAny's precondition kills the transaction
            // before a stuck depth could misfire.
            app.tplDepth -= 1
            precondition(
                !app.childFrames.isEmpty,
                "kaya: a for-in over rows needs an enclosing container builder")
            app.childFrames[app.childFrames.count - 1].ids.append(forId)
        }
        return nil
    }
}

public final class KayaAppTx {
    let app: KayaApp

    // THE ONE CHOKEPOINT: every write in this file is `tx.<verb>(...)`,
    // so the liveness check on the way in guards all of them. The failure
    // it guards is SILENT — a write through a Tx that outlived its build
    // vanishes with no error (tools/check-tx-liveness.py).
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
        // `_modify` AND NOT get/set, which copies the whole batch out
        // and back per mutating call: 32,000 inserts, 3070ms against 16ms
        // (docs/deferred.md, the Swift binding's quadratic insert). It
        // keeps the ONE chokepoint above intact — do not answer this by
        // checking liveness at the callsites.
        _modify {
            alive()
            yield &storage
        }
    }

    /// A KayaAppTx is valid ONLY inside the build or handler that made it,
    /// on the app thread.
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
    var rollbackActions: [() -> Void] = []

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
        // The pending link-route declarations go FIRST, in declaration
        // order (docs/app-links-plan.md §4; Rust's PENDING_ROUTES
        // drained head-first by Tx::commit is the shape).
        // `storage` and not `tx`: the submit is the transaction's own
        // last act, and routing it through the liveness property would
        // make the guard trip on the very call that closes it.
        let routes = app.takePendingRoutes()
        if !routes.isEmpty || !storage.bytes.isEmpty {
            var whole = KayaTx()
            whole.bytes = routes + storage.bytes
            whole.submit()
        }
    }

    /// The commit's mirror image: restore every touched mirror entry and
    /// drop the records with the pending registrations.
    func rollback() {
        app.currentTx = nil
        for action in rollbackActions.reversed() { action() }
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
    /// CHAIN and the marker still rides at the HEAD of the batch. WHAT A
    /// GROUP MAY HOLD is the reactive half — signal writes and collection
    /// deltas; anything else fails at apply, naming the op.
    public func undoable(_ label: String, window: UInt64 = 0) {
        precondition(
            !named,
            "kaya: this transaction is already an undo group — one name per step")
        named = true
        // THE HEAD OF THE BATCH, wherever the call sits: a transaction is
        // a bare list of records with no header, so the marker's position
        // IS its association with the batch.
        var head = KayaTx()
        head.undoGroup(window, .str(label))
        head.bytes.append(tx.bytes)
        tx = head
    }

    public func signal(_ initial: KayaValue) -> KayaSignal {
        let s = app.nextSignal()
        tx.createSignal(s.id, initial)
        touchSignal(s.id)
        app.signalMirrors[s.id] = initial
        return s
    }

    public func write(_ s: KayaSignal, _ value: KayaValue) {
        tx.writeSignal(s.id, value)
        touchSignal(s.id)
        app.signalMirrors[s.id] = value
        // The dependents recompute now, batched into this transaction.
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

    public func setText(_ w: KayaWidget, _ text: String) {
        tx.setText(w.id, text)
    }

    /// Declare the column header bar on a For's container. One title per
    /// column; the row template's root must be a row of exactly one cell
    /// per column, refused loudly otherwise. Re-call after sorting to move
    /// the indicator (docs/tables-plan.md).
    public func columns(_ w: KayaWidget, _ titles: [String], _ sort: KayaSort) {
        // pathLen 0: no key path, so the values are titles alone
        // (docs/tables-plan.md, dynamic tables).
        tx.setColumnHeaders(
            w.id, sort.sorted, sort.direction, UInt32(titles.count), 0,
            titles.map { .str($0) })
    }

    /// Re-declare ONE stamped copy's header bar, addressed by the nested
    /// For's template node plus that copy's keys — exactly what its
    /// `onSort` handler was handed. `at: []` re-declares the
    /// template-wide bar instead. The core refuses a keyed re-declaration
    /// with no template bar declared first, and a key path naming no
    /// stamped copy.
    public func columns(
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

    /// A container's inter-child gap (main axis, DIP; the normalized
    /// default is 8).
    func setSpacing(_ w: KayaWidget, _ gap: Double) {
        tx.setSpacing(w.id, gap)
    }

    /// A container's OWN padding: DIP between its bounds and its children,
    /// uniform on all four sides — the window inset one level down
    /// (docs/styling-plan.md D3).
    func setInset(_ w: KayaWidget, _ pad: Double) {
        tx.setInset(w.id, pad)
    }

    /// A container's cross-axis child placement. Containers only; baseline
    /// is rows-only.
    func setAlign(_ w: KayaWidget, _ align: KayaAlign) {
        tx.setAlign(w.id, align.rawValue)
    }

    /// A textarea one line tall at rest that grows with its text to `lines`
    /// lines, then scrolls (docs/grow-lines-plan.md).
    public func setMaxLines(_ w: KayaWidget, _ lines: Int) {
        tx.setMaxLines(w.id, Double(lines))
    }

    /// A row or column filled with a platform tint: kaya chooses the fill,
    /// the corner radius, the inset (unless one was set) and the foreground
    /// of what sits inside (docs/tints-plan.md T2).
    func setFilled(_ w: KayaWidget, _ tint: KayaTint) {
        tx.setFilled(w.id, tint.rawValue)
    }

    /// A container's arrangement axis, the dynamic path beside the
    /// creation kind (docs/adaptive-layout-plan.md D2). Containers only.
    public func setAxis(_ w: KayaWidget, _ axis: KayaAxis) {
        tx.setAxis(w.id, axis.rawValue)
    }

    /// A widget's SEMANTIC EMPHASIS: destructive/prominent on buttons,
    /// heading/caption on labels — what it means, never how it looks.
    func setRole(_ w: KayaWidget, _ role: KayaRole) {
        tx.setRole(w.id, role.rawValue)
    }

    /// An icon-only button: the platform's glyph in place of the title, which
    /// stays its accessible name (docs/composer-plan.md §2).
    public func setSymbol(_ w: KayaWidget, _ symbol: KayaSymbol) {
        tx.setSymbol(w.id, symbol.rawValue)
    }

    public func setGrow(_ w: KayaWidget, _ weight: Double) {
        tx.setGrow(w.id, weight)
    }

    /// Whether a widget spans its container's cross axis — a column's
    /// width, a row's height — whatever the container's align
    /// (docs/layout-knobs-plan.md §1). Unset, the kind's own default
    /// holds.
    public func setFill(_ w: KayaWidget, _ on: Bool) {
        tx.setFill(w.id, on)
    }

    /// THE GRID THAT FITS (docs/layout-knobs-plan.md §3): as many columns
    /// as fit this grid's width at `minWidth` DIP each, sharing the
    /// extra. An explicit `columnsWhen` still wins while its class holds.
    public func setColumnsAuto(_ w: KayaWidget, _ minWidth: Double) {
        tx.setColumns(w.id, 0)
        tx.setMinColumnWidth(w.id, minWidth)
    }

    /// A ROW THAT FLOWS (docs/layout-knobs-plan.md §2): children keep
    /// their natural size and move onto the next line when the row runs
    /// out of width, leading-aligned, the row's `spacing` on both axes.
    /// Rows only, and no child of a wrapping row may grow.
    public func setWrap(_ w: KayaWidget, _ on: Bool) {
        tx.setWrap(w.id, on)
    }

    /// A widget's accessibility IDENTIFIER: a stable authored key that
    /// automation addresses it by, and which is NEVER spoken.
    public func setA11yId(_ w: KayaWidget, _ id: String) {
        tx.setA11yId(w.id, id)
    }

    /// What an assistive client SPEAKS for a widget. Leave it unset to
    /// keep whatever the platform derives from the control's own content;
    /// setting it OVERRIDES that.
    public func setA11yLabel(_ w: KayaWidget, _ label: String) {
        tx.setA11yLabel(w.id, label)
    }

    /// What ACTIVATING this widget does. Write a VERB PHRASE.
    public func setA11yHint(_ w: KayaWidget, _ hint: String) {
        tx.setA11yHint(w.id, hint)
    }

    /// The SIGNAL-SOURCED forms of the trio, spelled as bindText is
    /// (docs/deferred.md, the live-zone a11y entry).
    func setA11yId(_ w: KayaWidget, _ s: KayaSignal) {
        tx.bindA11yId(w.id, s.id)
    }

    public func setA11yLabel(_ w: KayaWidget, _ s: KayaSignal) {
        tx.bindA11yLabel(w.id, s.id)
    }

    func setA11yHint(_ w: KayaWidget, _ s: KayaSignal) {
        tx.bindA11yHint(w.id, s.id)
    }

    /// A widget's HELP TEXT: one short sentence saying what the control
    /// is or does (docs/tooltip-plan.md T1). The platform picks the
    /// surface — a tooltip on the desktops, nothing visible on the
    /// iPhone — and hands the text to its assistive reader; an authored
    /// hint wins the hint slot (T3).
    public func setHelp(_ w: KayaWidget, _ text: String) {
        tx.setHelp(w.id, text)
    }

    public func setHelp(_ w: KayaWidget, _ s: KayaSignal) {
        tx.bindHelp(w.id, s.id)
    }

    /// The PROMPT a text field shows while it is empty
    /// (docs/search-plan.md S3): the platform's own placeholder, never
    /// part of the text and never emitted. Entry, textarea and search
    /// only, checked at the root.
    public func setPlaceholder(_ w: KayaWidget, _ text: String) {
        tx.setPlaceholder(w.id, text)
    }

    func setPlaceholder(_ w: KayaWidget, _ s: KayaSignal) {
        tx.bindPlaceholder(w.id, s.id)
    }

    /// The DESTINATION a `.link` label opens (docs/tasks-s2-plan.md T3):
    /// the platform's own opener takes it and nothing is emitted.
    func setHref(_ w: KayaWidget, _ url: String) {
        tx.setHref(w.id, url)
    }

    func setHref(_ w: KayaWidget, _ s: KayaSignal) {
        tx.bindHref(w.id, s.id)
    }

    func bindChecked(_ w: KayaWidget, _ s: KayaSignal) {
        tx.bindChecked(w.id, s.id)
    }

    /// Aim an image's source at encoded bytes: one registration copy into
    /// core memory, and the guest's bytes are free to drop on return.
    func setSource(_ w: KayaWidget, _ data: Data) {
        tx.setSource(w.id, kayaRegisterBlob(data))
    }

    /// Aim an image's source at a signal carrying a blob handle.
    func bindSource(_ w: KayaWidget, _ s: KayaSignal) {
        tx.bindSource(w.id, s.id)
    }

    // One-shot commands: momentary verbs into widget-owned state, riding
    // the open transaction like any record.

    /// Drop an entry's content now (the field stays authoritative).
    public func clear(_ w: KayaWidget) {
        tx.widgetCommand(w.id, UInt32(KAYA_COMMAND_CLEAR))
    }

    /// Give this widget the keyboard focus.
    public func focus(_ w: KayaWidget) {
        tx.widgetCommand(w.id, UInt32(KAYA_COMMAND_FOCUS))
    }

    /// Focus a text field and open the platform's emoji picker on it
    /// (docs/emoji-picker-plan.md); a chosen emoji arrives as its text change.
    public func showEmojiPicker(_ w: KayaWidget) {
        tx.widgetCommand(w.id, UInt32(KAYA_COMMAND_EMOJI_PICKER))
    }

    /// Scroll the For mounted in `w` so the row keyed `key` tops the
    /// viewport, clamped at the end (docs/scroll-to-plan.md). A pure
    /// effect; a key the collection does not hold scrolls nothing.
    public func scrollToRow(_ w: KayaWidget, _ key: KayaValue) {
        tx.scrollToRow(w.id, key)
    }

    // --- Text ranges: decorate a set, select one, reveal one ----------
    // EVERY OFFSET HERE IS A UTF-8 BYTE OFFSET into the widget's current
    // text (docs/ranges-plan.md D1). Swift's strings are indexed by
    // neither bytes nor integers, so reach for the `Range<String.Index>`
    // spelling and let the binding convert (docs/traps.md: A range offset
    // is a UTF-8 BYTE offset, and almost no language's own search agrees).

    /// DECLARE the decorated ranges of a textarea, replacing whatever was
    /// declared before; an empty set is the clear.
    ///
    /// APP-OWNED AND NEVER TRACKED: the first edit of any kind drops the
    /// set, and nothing in kaya adjusts a range across an edit.
    public func highlightRanges(
        _ w: KayaWidget, _ ranges: [Range<String.Index>], in text: String
    ) {
        highlightRanges(w, ranges.map { kayaByteRange($0, in: text) })
    }

    /// The byte-offset floor of `highlightRanges(_:_:in:)`. An offset past
    /// the end, or one that splits a character, fails loudly in the CORE.
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
    /// caret). REFUSED WHILE THE USER IS COMPOSING through an input
    /// method, in every backend, and the refusal is a silent no-op
    /// (docs/deferred.md).
    public func selectRange(_ w: KayaWidget, _ range: Range<String.Index>, in text: String) {
        selectRange(w, kayaByteRange(range, in: text))
    }

    /// The byte-offset floor of `selectRange(_:_:in:)`.
    public func selectRange(_ w: KayaWidget, _ range: Range<Int>) {
        let (start, stop) = kayaRangeOffsets(range)
        tx.selectRange(w.id, start, stop)
    }

    /// Scroll the textarea so a range is inside the viewport. A pure
    /// effect: it moves no state, leaves the selection alone, and undo
    /// does not put the scroll position back.
    public func revealRange(_ w: KayaWidget, _ range: Range<String.Index>, in text: String) {
        revealRange(w, kayaByteRange(range, in: text))
    }

    /// The byte-offset floor of `revealRange(_:_:in:)`.
    func revealRange(_ w: KayaWidget, _ range: Range<Int>) {
        let (start, stop) = kayaRangeOffsets(range)
        tx.revealRange(w.id, start, stop)
    }

    // --- Rich text (docs/rich-text-plan.md R1) ----------------------

    /// This textarea carries attribute runs: `setDocument`, `applyEdit`,
    /// `KayaApp.onEdit`.
    func setRich(_ w: KayaWidget, _ on: Bool = true) {
        tx.setRich(w.id, on)
    }

    /// Replace a `rich` textarea's whole document: echoes nothing and,
    /// like `setText`, spends the native undo history
    /// (docs/undo-plan.md D7).
    public func setDocument(_ w: KayaWidget, _ document: KayaDocument) {
        app.seedDocument(w.id, document)
        tx.setRichText(w.id, UInt32(document.runs.count),
                       kayaRunValues(document.runs), .str(document.text))
    }

    /// One edit into a `rich` textarea: echoes nothing, never resets
    /// undo, and is held rather than refused mid-composition
    /// (docs/rich-text-plan.md R5). THE MIRROR TAKES IT AS IT IS SENT,
    /// so the app's document is ahead of the widget's until a live
    /// composition ends (§7).
    public func applyEdit(_ w: KayaWidget, _ edit: KayaEdit) {
        app.absorbEdit(w.id, edit.range.lowerBound, edit.range.upperBound, edit.inserted, edit.runs)
        tx.applyEdit(
            w.id, UInt64(edit.range.lowerBound), UInt64(edit.range.upperBound),
            UInt32(edit.runs.count), kayaRunValues(edit.runs), .str(edit.inserted))
    }

    /// Format the widget's CURRENT SELECTION through its own act — what
    /// a toolbar button sends; the widget answers through
    /// `KayaApp.onFormat`. Over a collapsed selection the attribute is
    /// armed for the next keystroke instead. `value` is "true" for a
    /// flag, the URL for `link`.
    /// A flag attribute over the selection, on or off.
    func format(_ w: KayaWidget, _ name: String, _ on: Bool) {
        format(w, name, on ? kayaFlagValue : "false")
    }

    func format(_ w: KayaWidget, _ name: String, _ value: String) {
        tx.formatText(w.id, 0, 0, 0, 0, [.str(name), .str(value)])
    }

    /// The named acts (the review page's ruling 1 — docs/rich-text-plan.md
    /// §18): each is `format` with its name, over the widget's own
    /// selection; removal stays `unformat`, the block kinds stay `setBlock`.
    func bold(_ w: KayaWidget) { format(w, "bold", "true") }

    func italic(_ w: KayaWidget) { format(w, "italic", "true") }

    func underline(_ w: KayaWidget) { format(w, "underline", "true") }

    func strike(_ w: KayaWidget) { format(w, "strike", "true") }

    func code(_ w: KayaWidget) { format(w, "code", "true") }

    func link(_ w: KayaWidget, _ url: String) { format(w, "link", url) }

    /// Take an attribute off the widget's current selection.
    public func unformat(_ w: KayaWidget, _ name: String) {
        tx.formatText(w.id, 1, 0, 0, 0, [.str(name), .str("")])
    }

    /// One attribute over a BYTE RANGE of the document, the selection left
    /// where it is: a document write, echoed by nothing, legal on a rich
    /// label (docs/rich-text-plan.md §17). A `block` name covers the
    /// range's whole paragraphs.
    /// A flag attribute over a byte range, on or off.
    public func formatRange(_ w: KayaWidget, _ range: Range<Int>, _ name: String, _ on: Bool) {
        formatRange(w, range, name, on ? kayaFlagValue : "false")
    }

    func formatRange(_ w: KayaWidget, _ range: Range<Int>, _ name: String, _ value: String) {
        // A silent document write moves the fold, as applyEdit does
        // (docs/rich-text-plan.md §17).
        let at = app.rangedActBounds(w.id, range, name)
        let mark: String? = name == "block" && value == "body" ? nil : value
        app.absorbFormat(w.id, at.lowerBound, at.upperBound, name, mark)
        let (start, stop) = kayaRangeOffsets(at)
        tx.formatText(w.id, mark == nil ? 1 : 0, 1, start, stop,
                      [.str(name), .str(mark ?? "")])
    }

    /// `formatRange`'s removal.
    public func unformatRange(_ w: KayaWidget, _ range: Range<Int>, _ name: String) {
        let at = app.rangedActBounds(w.id, range, name)
        app.absorbFormat(w.id, at.lowerBound, at.upperBound, name, nil)
        let (start, stop) = kayaRangeOffsets(at)
        tx.formatText(w.id, 1, 1, start, stop, [.str(name), .str("")])
    }

    /// Make the selection's paragraphs `kind`; `.body` clears.
    public func setBlock(_ w: KayaWidget, _ kind: KayaBlock) {
        format(w, "block", kind.name)
    }

    /// What an `ownUndo` textarea's app answers for Edit>Undo: true
    /// enables the item and routes its activation to the app
    /// (docs/rich-text-plan.md R6, §14).
    public func canUndo(_ w: KayaWidget, _ can: Bool) {
        tx.setCanUndo(w.id, can)
    }

    /// The same for Edit>Redo.
    public func canRedo(_ w: KayaWidget, _ can: Bool) {
        tx.setCanRedo(w.id, can)
    }

    /// A `Range<Int>` as the wire's two unsigned offsets. `Range` already
    /// guarantees lower <= upper; checking the lower bound HERE names kaya
    /// instead of letting `UInt64.init` trap with "Negative value is not
    /// representable".
    private func kayaRangeOffsets(_ r: Range<Int>) -> (UInt64, UInt64) {
        precondition(
            r.lowerBound >= 0,
            "kaya: a text range starts at \(r.lowerBound) — offsets are UTF-8 byte "
                + "offsets into the widget's text and cannot be negative")
        return (UInt64(r.lowerBound), UInt64(r.upperBound))
    }

    // --- Construction sugar: the tree reads as a tree ----------------

    /// `role:` is this button's semantic emphasis — `.destructive` or
    /// `.prominent`. It changes what the press MEANS, never what
    /// `onClick:` does.
    @discardableResult
    public func button(
        _ text: String? = nil, role: KayaRole? = nil, symbol: KayaSymbol? = nil,
        onClick: ((KayaAppTx) throws -> Void)? = nil,
        grow: Double? = nil
    ) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_BUTTON))
        if let text { setText(w, text) }
        if let role { setRole(w, role) }
        if let symbol { setSymbol(w, symbol) }
        if let onClick { app.onClick(w, onClick) }
        if let grow { setGrow(w, grow) }
        return w
    }

    /// `onSubmit:` answers the Return gesture with the field's text
    /// (docs/submit-plan.md S7); the field keeps its text and its focus.
    @discardableResult
    public func entry(
        onChange: ((KayaAppTx, String) throws -> Void)? = nil,
        onSubmit: ((KayaAppTx, String) throws -> Void)? = nil,
        grow: Double? = nil
    ) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_ENTRY))
        if let onChange { app.onChange(w, onChange) }
        if let onSubmit { app.onSubmitted(w, onSubmit) }
        if let grow { setGrow(w, grow) }
        return w
    }

    /// A multi-line text editor, on the entry's uncontrolled contract.
    /// `rich:` adds the attribute-run channel (docs/rich-text-plan.md R1):
    /// `onEdit:` and `onFormat:` answer only on one. `ownUndo:` turns the
    /// platform's own undo stack off on this widget and routes Edit>Undo
    /// to the app's Undo item (docs/rich-text-plan.md R6, §14). `submits:`
    /// makes Return the send gesture and Shift+Return the newline
    /// (docs/submit-plan.md S2); off, Return is the newline.
    @discardableResult
    public func textarea(
        onChange: ((KayaAppTx, String) throws -> Void)? = nil,
        onSubmit: ((KayaAppTx, String) throws -> Void)? = nil,
        submits: Bool = false,
        rich: Bool = false,
        ownUndo: Bool = false,
        onEdit: ((KayaAppTx, KayaEdit) throws -> Void)? = nil,
        onFormat: ((KayaAppTx, KayaFormat) throws -> Void)? = nil,
        grow: Double? = nil
    ) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_TEXTAREA))
        if let onChange { app.onChange(w, onChange) }
        if let onSubmit { app.onSubmitted(w, onSubmit) }
        if submits { tx.setSubmits(w.id, true) }
        if rich { setRich(w, true) }
        if ownUndo { tx.setOwnUndo(w.id, true) }
        if let onEdit { app.onEdit(w, onEdit) }
        if let onFormat { app.onFormat(w, onFormat) }
        if let grow { setGrow(w, grow) }
        return w
    }

    /// A search field, on the entry's uncontrolled contract under the
    /// platform's search chrome (docs/search-plan.md): it filters on
    /// every keystroke and the clear affordance arrives as a change
    /// with "".
    @discardableResult
    public func search(
        onChange: ((KayaAppTx, String) throws -> Void)? = nil,
        onSubmit: ((KayaAppTx, String) throws -> Void)? = nil,
        grow: Double? = nil
    ) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_SEARCH))
        if let onChange { app.onChange(w, onChange) }
        if let onSubmit { app.onSubmitted(w, onSubmit) }
        if let grow { setGrow(w, grow) }
        return w
    }

    /// `role:` is this label's place in the text hierarchy — `.heading`
    /// or `.caption`, a semantic fact and not a font size. `rich: true`
    /// draws the label's attribute runs over the role's own font,
    /// read-only (docs/rich-text-plan.md R8, §15).
    @discardableResult
    public func label(
        _ text: String? = nil, bind: KayaSignal? = nil, role: KayaRole? = nil,
        rich: Bool = false, grow: Double? = nil
    ) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_LABEL))
        if let text { setText(w, text) }
        if let bind { bindText(w, bind) }
        if let role { setRole(w, role) }
        if rich { setRich(w, true) }
        if let grow { setGrow(w, grow) }
        return w
    }

    /// A label wearing the heading role: the platform's heading text
    /// style AND the accessibility heading trait, and on a grouped screen
    /// the section-header seat.
    @discardableResult
    public func heading(
        _ text: String? = nil, bind: KayaSignal? = nil, grow: Double? = nil
    ) -> KayaWidget {
        label(text, bind: bind, role: .heading, grow: grow)
    }

    /// A label wearing the caption role: the platform's footnote tier,
    /// and on a grouped screen the section-footer seat.
    @discardableResult
    public func caption(
        _ text: String? = nil, bind: KayaSignal? = nil, grow: Double? = nil
    ) -> KayaWidget {
        label(text, bind: bind, role: .caption, grow: grow)
    }

    /// A progress bar. `value` is the determinate fraction (0..=1);
    /// `indeterminate: true` switches to the platform's activity mode.
    @discardableResult
    public func progress(
        value: Double = 0.0, indeterminate: Bool? = nil, grow: Double? = nil
    ) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_PROGRESS))
        tx.setValue(w.id, value)
        if let indeterminate { tx.setIndeterminate(w.id, indeterminate) }
        if let grow { setGrow(w, grow) }
        return w
    }

    /// A drawing surface. `viewbox` is the coordinate system the ops are
    /// written in AND the canvas's natural size in points
    /// (docs/canvas-plan.md §3.2). Declare what it draws with `draw`;
    /// until then it is present and empty.
    @discardableResult
    public func canvas(_ viewbox: KayaViewbox, grow: Double? = nil) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_CANVAS))
        // The viewbox rides the DRAWING on the wire, not a prop; the
        // guest side remembers it so a redraw in a later handler does not
        // repeat it.
        app.canvasViewboxes[w.id] = viewbox
        if let grow { setGrow(w, grow) }
        return w
    }

    /// DECLARE the whole drawing on a canvas, replacing whatever was
    /// declared before: one atomic record when the closure returns.
    public func draw(_ w: KayaWidget, _ body: (KayaDraw) -> Void) {
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
    /// template node plus that copy's keys. `at: []` re-declares the
    /// drawing every copy is born with (docs/canvas-plan.md §3.1).
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

    /// A slider over min...max at value, with its change and commit
    /// handlers co-located. `step` is the granularity the thumb rests on
    /// and `tickSpacing` the distance between drawn ticks, in value units
    /// (docs/slider-plan.md S1, S5).
    @discardableResult
    public func slider(
        min: Double = 0.0, max: Double = 1.0, value: Double = 0.0,
        step: Double? = nil, tickSpacing: Double? = nil,
        bind: KayaSignal? = nil,
        onChange: ((KayaAppTx, Double) throws -> Void)? = nil,
        onCommit: ((KayaAppTx, Double) throws -> Void)? = nil,
        grow: Double? = nil
    ) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_SLIDER))
        tx.setMin(w.id, min)
        tx.setMax(w.id, max)
        if let step { tx.setStep(w.id, step) }
        if let tickSpacing { tx.setTickSpacing(w.id, tickSpacing) }
        if let bind {
            tx.bindValue(w.id, bind.id)
        } else {
            tx.setValue(w.id, value)
        }
        if let onChange { app.onValueChanged(w, onChange) }
        if let onCommit { app.onValueCommitted(w, onCommit) }
        if let grow { setGrow(w, grow) }
        return w
    }

    /// A dropdown select over fixed options — each option becomes a label
    /// child — at `selected`, the initial 0-based index. `onSelect`
    /// receives each USER pick's new index; programmatic writes never
    /// echo.
    @discardableResult
    public func select(
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

    /// A radio group over fixed options: `select`'s contract in its
    /// inline presentation.
    @discardableResult
    public func radio(
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

    @discardableResult
    public func checkbox(
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

    /// A date picker over civil dates — the compact field that opens the
    /// platform's calendar (docs/datetime-plan.md). UNCONTROLLED: the
    /// control owns its value and reports each COMMITTED pick to onDate.
    /// `min`/`max` are the inclusive range and a pick past a bound lands
    /// on the bound.
    @discardableResult
    public func datePicker(
        _ value: KayaDate? = nil, min: KayaDate? = nil, max: KayaDate? = nil,
        bind: KayaSignal? = nil,
        onDate: ((KayaAppTx, KayaDate) throws -> Void)? = nil,
        grow: Double? = nil
    ) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_DATE_PICKER))
        if let min {
            _ = kayaPackedDate("min_date", min)
            tx.setMinDate(w.id, min.year, min.month, min.day)
        }
        if let max {
            _ = kayaPackedDate("max_date", max)
            tx.setMaxDate(w.id, max.year, max.month, max.day)
        }
        if let bind { tx.bindDate(w.id, bind.id) }
        if let value {
            _ = kayaPackedDate("a date picker's value", value)
            tx.setDate(w.id, value.year, value.month, value.day)
        }
        if let onDate { app.onDate(w, onDate) }
        if let grow { setGrow(w, grow) }
        return w
    }

    /// A time picker over civil times: hours and minutes, no seconds.
    /// `step` is the minute granularity (1, 5, 10, 15 or 30) and a pick
    /// snaps to it.
    @discardableResult
    public func timePicker(
        _ value: KayaTime? = nil, step: Int? = nil, bind: KayaSignal? = nil,
        onTime: ((KayaAppTx, KayaTime) throws -> Void)? = nil,
        grow: Double? = nil
    ) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_TIME_PICKER))
        if let step { tx.setMinuteStep(w.id, Double(step)) }
        if let bind { tx.bindTime(w.id, bind.id) }
        if let value {
            _ = kayaPackedTime("a time picker's value", value)
            tx.setTime(w.id, value.hour, value.minute)
        }
        if let onTime { app.onTime(w, onTime) }
        if let grow { setGrow(w, grow) }
        return w
    }

    /// An image displaying encoded bytes (PNG, JPEG, ...). Decode failure
    /// renders the placeholder, never a crash.
    @discardableResult
    public func image(
        _ source: Data? = nil, bind: KayaSignal? = nil, grow: Double? = nil
    ) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_IMAGE))
        if let source { setSource(w, source) }
        if let bind { bindSource(w, bind) }
        if let grow { setGrow(w, grow) }
        return w
    }

    /// The ASSET form of the source slot: the same image, with the picture
    /// NAMED rather than read. THE BYTES NEVER ENTER THE GUEST'S HEAP.
    @discardableResult
    public func image(_ source: KayaAsset, grow: Double? = nil) -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_IMAGE))
        tx.setSource(w.id, source.blob())
        if let grow { setGrow(w, grow) }
        return w
    }

    @discardableResult
    public func column<R>(
        grow: Double? = nil, spacing: Double? = nil, inset: Double? = nil,
        align: KayaAlign? = nil, filled: KayaTint? = nil,
        _ children: (KayaWidget) throws -> R
    ) rethrows -> R {
        try containerOf(
            UInt32(KAYA_KIND_COLUMN), children, grow: grow, spacing: spacing,
            inset: inset, align: align, filled: filled)
    }

    /// A vertical scroll viewport over EXACTLY ONE child. Pass grow: so
    /// the enclosing track CONSTRAINS it — an unconstrained viewport hugs
    /// its content and nothing overflows.
    @discardableResult
    /// `followsEnd:` keeps the end in view while the content grows, until the
    /// user scrolls away from it (docs/follow-end-plan.md).
    public func scroll<R>(
        grow: Double? = nil, followsEnd: Bool = false, _ children: (KayaWidget) throws -> R
    ) rethrows -> R {
        try containerOf(
            UInt32(KAYA_KIND_SCROLL), { w in
                if followsEnd { tx.setFollowsEnd(w.id, true) }
                return try children(w)
            }, grow: grow, spacing: nil,
            inset: nil, align: nil)
    }

    @discardableResult
    /// `role: .composer` draws the row as one text field around its field
    /// and buttons (docs/composer-plan.md §4).
    public func row<R>(
        grow: Double? = nil, spacing: Double? = nil, inset: Double? = nil,
        align: KayaAlign? = nil, filled: KayaTint? = nil, role: KayaRole? = nil,
        _ children: (KayaWidget) throws -> R
    ) rethrows -> R {
        try containerOf(
            UInt32(KAYA_KIND_ROW), { w in
                if let role { setRole(w, role) }
                return try children(w)
            }, grow: grow, spacing: spacing,
            inset: inset, align: align, filled: filled)
    }

    /// A grid laying its children out row-major into `columns` columns —
    /// each column takes its NATURAL width, aligned across rows.
    /// `spacing` is the inter-cell gap on both axes.
    @discardableResult
    public func grid<R>(
        columns: Int, spacing: Double? = nil, inset: Double? = nil,
        grow: Double? = nil,
        _ children: (KayaWidget) throws -> R
    ) rethrows -> R {
        let parent = widget(UInt32(KAYA_KIND_GRID))
        tx.setColumns(parent.id, Double(columns))
        if let spacing { setSpacing(parent, spacing) }
        if let inset { setInset(parent, inset) }
        if let grow { setGrow(parent, grow) }
        app.childFrames.append(KayaApp.KayaFrame(template: false))
        defer {
            let ids = app.childFrames.removeLast().ids
            for id in ids { tx.addChild(parent.id, id) }
        }
        return try children(parent)
    }

    /// A LABELLED ROW (docs/forms-plan.md): the label names the one
    /// control the children declare, with an optional trailing button
    /// after it. A column of nothing but these renders as the platform's
    /// form.
    @discardableResult
    public func labeled<R>(
        _ label: String, spacing: Double? = nil, inset: Double? = nil,
        grow: Double? = nil,
        _ children: (KayaWidget) throws -> R
    ) rethrows -> R {
        try labeledOf(children, spacing: spacing, inset: inset, grow: grow) {
            _ = self.label(label)
        }
    }

    @discardableResult
    func labeled<R>(
        _ label: KayaSignal, spacing: Double? = nil, inset: Double? = nil,
        grow: Double? = nil,
        _ children: (KayaWidget) throws -> R
    ) rethrows -> R {
        try labeledOf(children, spacing: spacing, inset: inset, grow: grow) {
            _ = self.label(bind: label)
        }
    }

    private func labeledOf<R>(
        _ children: (KayaWidget) throws -> R, spacing: Double?, inset: Double?, grow: Double?,
        _ name: () -> Void
    ) rethrows -> R {
        let parent = widget(UInt32(KAYA_KIND_LABELED))
        if let spacing { setSpacing(parent, spacing) }
        if let inset { setInset(parent, inset) }
        if let grow { setGrow(parent, grow) }
        app.childFrames.append(KayaApp.KayaFrame(template: false))
        name()
        defer {
            let ids = app.childFrames.removeLast().ids
            for id in ids { tx.addChild(parent.id, id) }
        }
        return try children(parent)
    }

    /// A spacer: PURE SUGAR for an empty grown column — it consumes
    /// the leftover main-axis space between its siblings.
    @discardableResult
    public func spacer() -> KayaWidget {
        let w = widget(UInt32(KAYA_KIND_COLUMN))
        setGrow(w, 1.0)
        return w
    }

    private func containerOf<R>(
        _ kind: UInt32, _ children: (KayaWidget) throws -> R, grow: Double? = nil, spacing: Double? = nil,
        inset: Double? = nil, align: KayaAlign? = nil, filled: KayaTint? = nil
    ) rethrows -> R {
        // Parent before children: creation order is observable (column#N)
        // and statement-shaped construction is parent-first in every
        // language.
        let parent = widget(kind)
        if let grow { setGrow(parent, grow) }
        if let spacing { setSpacing(parent, spacing) }
        if let inset { setInset(parent, inset) }
        if let align { setAlign(parent, align) }
        if let filled { setFilled(parent, filled) }
        app.childFrames.append(KayaApp.KayaFrame(template: false))
        defer {
            let ids = app.childFrames.removeLast().ids
            for id in ids { tx.addChild(parent.id, id) }
        }
        return try children(parent)
    }

    /// A For as a child: forEach whose body keeps no handles.
    @discardableResult
    public func each(_ c: KayaCollection, _ body: (KayaTpl) -> Void) -> KayaWidget {
        forEach(c) { body($0) }.0
    }

    func addChild(_ parent: KayaWidget, _ child: KayaWidget) {
        tx.addChild(parent.id, child.id)
    }

    public func collection() -> KayaCollection {
        let c = app.nextCollection()
        app.registerCollection(c.id)
        // A scalar collection's element IS its one wire value, so the
        // undo decoder is the identity (see registerDecoder).
        app.registerDecoder(c.id) { _, values in values[0] }
        tx.createCollection(c.id, [[UInt32(KAYA_VALUE_STR)]])
        return c
    }

    /// A For over `c`: the closure declares the template, and the For
    /// itself comes back alongside the body's result — the way handles
    /// declared inside the template reach the handlers.
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
    public func when<R>(_ s: KayaSignal, _ body: (KayaTpl) -> R) -> (KayaWidget, R) {
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

    /// A scalar collection's element IS its one wire value, so this is the
    /// record path with a one-field record — a delegation, so EVERY insert
    /// passes the one chokepoint the minter absorbs at.
    public func insert(_ c: KayaCollection, _ key: KayaValue, _ value: KayaValue) {
        insertRecordRaw(c, key, value, 0, [value])
    }

    /// Insert a scalar under a key the binding authors, and hand the key
    /// back. ONE COUNTER PER COLLECTION INSTANCE; the minted key is
    /// counter+1. MIXING IS SAFE BY ABSORPTION — an explicit `insert`
    /// whose key is an I64 at or above the counter carries it up — and NO
    /// DECREMENT IS EXPRESSIBLE.
    @discardableResult
    public func insertFresh(_ c: KayaCollection, _ value: KayaValue) -> Int64 {
        insertRecordFresh(c, value, 0, [value])
    }

    public func update(_ c: KayaCollection, _ key: KayaValue, _ value: KayaValue) {
        app.modelSet(c.id, c.path, key, value)
        tx.collectionUpdate(c.id, c.path, key, 0, [value])
        recomputeDerived(c)
    }

    public func remove(_ c: KayaCollection, _ key: KayaValue) {
        app.modelRemove(c.id, c.path, key)
        tx.collectionRemove(c.id, c.path, key)
        recomputeDerived(c)
    }

    /// Repositions an entry before another's.
    func moveBefore(_ c: KayaCollection, _ key: KayaValue, _ anchor: KayaValue) {
        moveEntry(c, key, [anchor])
    }

    /// Repositions an entry at the end of its collection.
    func moveToEnd(_ c: KayaCollection, _ key: KayaValue) {
        moveEntry(c, key, [])
    }

    /// Repositions an entry at the front.
    func moveToFront(_ c: KayaCollection, _ key: KayaValue) {
        guard let first = app.keysOf(c.id, c.path).first else {
            preconditionFailure("kaya: move of missing key \(key)")
        }
        moveEntry(c, key, [first])
    }

    /// Repositions an entry directly after another's.
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
            // Moving before itself: order unchanged and nothing travels —
            // but the key must still exist.
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

    /// The model: what this guest wrote, exactly — the fold of every patch
    /// so far (this transaction's included), in insertion order.
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
        // ABSORPTION, on the one path every explicit key travels: a
        // numeric key at or above the minter's counter carries it up
        // (insertFresh's contract).
        app.absorbKey(c.id, c.path, key)
        app.modelSet(c.id, c.path, key, model)
        tx.collectionInsert(c.id, c.path, key, variant, fields)
        recomputeDerived(c)
    }

    /// The minting insert every typed surface's `insertFresh` lowers to.
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

    // The raw read every typed surface funnels through — guarded once.
    func recordEntries(_ c: KayaCollection) -> [(key: KayaValue, value: Any)] {
        guardMirrorRead()
        return app.instanceEntries(c.id, c.path)
    }

    public func count(_ c: KayaCollection) -> Int {
        guardMirrorRead()
        return app.instanceEntries(c.id, c.path).count
    }

    /// Request a modal alert. The result handler rides the REQUEST and
    /// retires with its one answer — `choice` is an action index (0 or 1)
    /// or KAYA_ALERT_CHOICE_CANCEL, which is every platform-native
    /// dismissal.
    @discardableResult
    public func showAlert(
        title: String = "", message: String = "",
        actions: [String] = [], cancel: String, window: UInt64 = 0,
        onResult: ((KayaAppTx, KayaAlertChoice) throws -> Void)? = nil
    ) -> UInt64 {
        alive()
        precondition(
            actions.count <= 2,
            "kaya: an alert carries at most 2 actions (the platform floor)")
        precondition(
            !cancel.isEmpty,
            "kaya: the cancel slot always exists and needs a name")
        let id = app.allocAlert()
        tx.showAlert(
            window, id, UInt32(actions.count), .str(title), .str(message),
            .str(actions.count >= 1 ? actions[0] : ""),
            .str(actions.count == 2 ? actions[1] : ""), .str(cancel))
        app.onAlert(id, onResult)
        return id
    }

    /// Post a local notification with a GUEST-CHOSEN id
    /// (docs/tasks-s3-plan.md N1, N2): the alert's grammar without a
    /// window — the platform shows it outside the app. `onResult` fires
    /// exactly once and retires, with KAYA_NOTIFICATION_OUTCOME_ACTIVATED
    /// when the user opened it and KAYA_NOTIFICATION_OUTCOME_REFUSED when
    /// the platform would not post it. `at` is a UNIX time in seconds
    /// handed to the OS scheduler where one exists; 0 posts now. Many may
    /// be live at once.
    @discardableResult
    func showNotification(
        _ notification: UInt64, title: String = "", body: String = "",
        at: UInt64 = 0,
        onResult: ((KayaAppTx, KayaNotificationOutcome) throws -> Void)? = nil
    ) -> UInt64 {
        precondition(
            !title.isEmpty,
            "kaya: a notification needs a title — pass title:")
        if let onResult { app.onNotification(notification, onResult) }
        tx.showNotification(notification, at, .str(title), .str(body))
        return notification
    }

    /// Withdraw a pending or delivered notification (a reminder that was
    /// cleared). No answer follows; an unknown id is ignored.
    func cancelNotification(_ notification: UInt64) {
        tx.cancelNotification(notification)
    }

    /// Ask the platform to show `count` on the app's icon, 0 clearing it
    /// (docs/app-badge-plan.md). Never refused: `capabilities().badge` says
    /// whether a number will appear.
    func setBadge(_ count: UInt32) {
        tx.setBadge(count)
    }

    /// Ask the platform for files. THE PICK, NOT THE OPEN — the result
    /// carries handles you redeem later (DESIGN.md, File dialogs).
    /// `filters` is advisory on every platform, `onResult` fires exactly
    /// once, and CANCEL IS THE EMPTY LIST.
    @discardableResult
    public func pickFiles(
        filters: [(String, String)] = [], window: UInt64 = 0,
        onResult: ((KayaAppTx, [KayaPickedFile]) throws -> Void)? = nil
    ) -> UInt64 {
        pick(multiple: true, filters: filters, window: window, onResult: onResult)
    }

    /// The single-file spelling. The floor always returns a LIST, so the
    /// handler receives zero or one file.
    @discardableResult
    public func pickFile(
        filters: [(String, String)] = [], window: UInt64 = 0,
        onResult: ((KayaAppTx, [KayaPickedFile]) throws -> Void)? = nil
    ) -> UInt64 {
        pick(multiple: false, filters: filters, window: window, onResult: onResult)
    }

    private func pick(
        multiple: Bool, filters: [(String, String)], window: UInt64,
        onResult: ((KayaAppTx, [KayaPickedFile]) throws -> Void)?
    ) -> UInt64 {
        alive()
        let id = app.allocFileDialog()
        tx.showFileDialog(window, id, multiple ? 1 : 0, kayaFilterValues(filters))
        app.onFileDialog(id, onResult)
        return id
    }

    /// Ask the platform WHERE TO SAVE — the picker's twin, out of the same
    /// one-live-dialog slot. CANCEL IS `nil`. `suggestedName` is the name
    /// the dialog OPENS with and no platform guarantees anything about it:
    /// READ THE NAME YOU GOT. WHAT YOU GET BACK OPENS EMPTY —
    /// `FILE_MODE_WRITE` CREATES on every platform (docs/save-plan.md D1).
    @discardableResult
    public func saveFile(
        suggestedName: String, filters: [(String, String)] = [], window: UInt64 = 0,
        onResult: ((KayaAppTx, KayaPickedFile?) throws -> Void)? = nil
    ) -> UInt64 {
        alive()
        let id = app.allocFileDialog()
        tx.showSaveDialog(window, id, .str(suggestedName), kayaFilterValues(filters))
        if let onResult {
            // The save answer rides the picker's own result occurrence:
            // one id space, one live slot, one retire gate.
            app.onFileDialog(id) { tx, files in try onResult(tx, files.first) }
        } else {
            app.onFileDialog(id, nil)
        }
        return id
    }

    // --- The clipboard (DESIGN.md, Clipboard) ----------------------

    /// Begin a clip: fill in as many representations as the app wants to
    /// offer, and send() puts it on the system clipboard.
    public func copy() -> KayaCopyRef {
        KayaCopyRef(tx: self)
    }

    /// Begin the privileged read. The platforms have deliberately made it
    /// expensive (DESIGN.md, docs/clipboard-plan.md): reach for it to
    /// detect a URL or import, never to implement Paste — that is the
    /// Paste command, and it is free.
    public func readClipboard() -> KayaClipReadRef {
        KayaClipReadRef(tx: self, id: app.allocClipboardRead())
    }

    /// Declare what a widget takes from a paste — the closed kinds by name
    /// ("text", "html", "image", "files") plus any custom format ids. It
    /// drives whether Paste is live while this widget is focused, and on
    /// Android IS the native registration. A widget that declares NOTHING
    /// gets the platform's own insertion.
    public func setAccepts(_ w: KayaWidget, _ kinds: [String]) {
        tx.setAccepts(w.id, kayaAcceptList(kinds))
    }

    /// Take pasted content at a live widget. COSTS NOTHING ON ANY
    /// PLATFORM, unlike readClipboard: a paste is its own authorisation.
    public func onPaste(
        _ w: KayaWidget,
        _ handler: @escaping (KayaAppTx, KayaRepresentation) throws -> Void
    ) {
        app.onPaste(w, handler)
    }

    /// A paste onto a stamped copy: the handler also receives the copy's
    /// key path, outermost first. IT ONLY FIRES FOR A COPY WHOSE TEMPLATE
    /// DECLARED WHAT IT TAKES (`KayaTpl.setAccepts`).
    public func onPaste(
        _ n: KayaNodeHandle,
        _ handler: @escaping (KayaAppTx, [KayaValue], KayaRepresentation) throws -> Void
    ) {
        app.onPaste(n, handler)
    }

    /// DECLARE what a widget hands over when dragged: a clip in the copy
    /// chain's own shapes plus the operations it allows (docs/dnd-plan.md
    /// D1). `declare()` sends it; an empty chain withdraws.
    public func draggable(_ w: KayaWidget) -> KayaDragRef {
        KayaDragRef(tx: self, widget: w.id)
    }

    /// DECLARE that a widget receives drops, performing these operations;
    /// naming NONE withdraws it. WHAT it takes is its `setAccepts` list,
    /// which must be declared first — a destination has one vocabulary,
    /// not two.
    public func setDropTarget(_ w: KayaWidget, _ ops: [KayaOp]) {
        tx.setDropTarget(w.id, ops.reduce(0) { $0 | $1.rawValue }, 0, [])
    }

    /// Rows of this live For drag within their own collection
    /// (docs/dnd-plan.md D8): the landing arrives at `onDrop` on the For's
    /// own container and the app confirms with a move.
    public func setReorderable(_ container: KayaWidget, _ enabled: Bool) {
        tx.setReorderable(container.id, enabled ? 1 : 0)
    }

    /// Take dropped content at a live widget, or a reorderable For's
    /// landings (docs/dnd-plan.md D8). Only fires for a widget that
    /// declared `setDropTarget` over an accept list.
    public func onDrop(
        _ w: KayaWidget,
        _ handler: @escaping (KayaAppTx, KayaDropped) throws -> Void
    ) {
        app.onDrop(w, handler)
    }

    /// A drag that began at this widget has ended: nil is a cancelled or
    /// refused drag, not an error.
    public func onDragEnded(
        _ w: KayaWidget,
        _ handler: @escaping (KayaAppTx, KayaOp?) throws -> Void
    ) {
        app.onDragEnded(w, handler)
    }

    /// ONE STAMPED COPY's drag declaration (docs/dnd-plan.md §4): the
    /// template node and the copy's keys, outermost first. The per-row
    /// payload an app declares after the row's insert; it overrides the
    /// template's own for that copy and follows it through a re-stamp.
    func draggableAt(_ n: KayaNodeHandle, at keys: [KayaValue]) -> KayaDragRef {
        KayaDragRef(tx: self, widget: n.id, keys: keys)
    }

    /// `draggableAt`'s twin: ONE stamped copy receives drops with these
    /// operations, taking what the template's `setAccepts` names.
    func setDropTargetAt(_ n: KayaNodeHandle, at keys: [KayaValue], _ ops: [KayaOp]) {
        tx.setDropTarget(
            n.id, ops.reduce(0) { $0 | $1.rawValue }, UInt32(keys.count), keys)
    }

    /// A drop on a stamped copy: the handler also receives the copy's key
    /// path, outermost first.
    public func onDrop(
        _ n: KayaNodeHandle,
        _ handler: @escaping (KayaAppTx, [KayaValue], KayaDropped) throws -> Void
    ) {
        app.onDrop(n, handler)
    }

    /// A stamped copy of this node — a reorderable row is one — finished
    /// its drag; the copy's keys first.
    public func onDragEnded(
        _ n: KayaNodeHandle,
        _ handler: @escaping (KayaAppTx, [KayaValue], KayaOp?) throws -> Void
    ) {
        app.onDragEnded(n, handler)
    }

    /// REQUEST the app's brand accent (docs/styling-plan.md D1/D2): one
    /// packed sRGB hex (0xRRGGBB). `light:`/`dark:` are the per-appearance
    /// overrides, whichever you leave out filled from `seed`, and the core
    /// derives every foreground and contrast variant. SET ONCE, BEFORE THE
    /// FIRST MOUNT: the root refuses a second write and a late one.
    public func brandAccent(_ seed: UInt32, light: UInt32? = nil, dark: UInt32? = nil) {
        // The mask is what tells the core "unstated" from "0x000000":
        // black is a legal accent.
        var mask: UInt32 = 0
        if light != nil { mask |= 1 }
        if dark != nil { mask |= 2 }
        tx.setBrandAccent(seed, mask, light ?? 0, dark ?? 0)
    }

    /// REQUEST the app's brand typeface (docs/styling-plan.md Slice 2b).
    /// THE FAMILY, NEVER THE SCALE. SET ONCE, BEFORE THE FIRST MOUNT.
    /// `KeyValuePairs` AND NOT A `Dictionary`, which is unordered and
    /// would write different bytes on different runs. A FAMILY A PLATFORM
    /// DOES NOT HAVE leaves that platform's own typeface in place
    /// silently, so each lowering gates on the family being installed.
    func brandTypeface(
        _ family: String,
        platforms: KeyValuePairs<KayaPlatform, String> = [:],
        font: Data? = nil
    ) {
        // Flat pairs: the platform tag, then that platform's family, read
        // in twos by the root.
        var pairs: [KayaValue] = []
        for (platform, name) in platforms {
            pairs.append(.i64(platform.rawValue))
            pairs.append(.str(name))
        }
        // The font SLOT rides either way and the mask says whether it
        // means anything, so the field count never varies.
        tx.setBrandTypeface(
            font == nil ? 0 : 1, .str(family), pairs,
            font.map { .blob(kayaRegisterBlob($0)) } ?? .str(""))
    }

    /// The ASSET form of the font slot: the same call, with the font NAMED
    /// rather than read. THE BYTES NEVER ENTER THE GUEST'S HEAP.
    public func brandTypeface(
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

    /// DECLARE the app's identity (docs/app-identity-plan.md,
    /// docs/tasks-s3-plan.md N4). NO ARGUMENTS: the name it goes by, the
    /// picture that stands for it and the reverse-DNS id it registers under
    /// are the asset root's own identity.toml, which the BUILD already
    /// reads, and the core reads the same file. SET ONCE, BEFORE THE FIRST
    /// MOUNT.
    ///
    /// STILL AN EXPLICIT CALL, because declaring an identity is a POLICY: a
    /// declared app is a Dock app on macOS (ruling 1), so an app that wants
    /// the platform's own identity declares none at all.
    public func appIdentity() {
        // THE SLOTS RIDE EMPTY and the root fills them from the asset root's own
        // identity.toml: mask 0, no name, no blob. The record's shape is fixed, so
        // the icon slot is written either way, as an empty Str.
        tx.setAppIdentity(0, .str(""), .str(""))
    }

    /// Create an auxiliary window (capability-gated: phone hosts reject at
    /// the root); materializes hidden, mountIn presents.
    public func createWindow(
        _ id: UInt64, title: String? = nil, width: Double? = nil,
        height: Double? = nil, vetoClose: Bool? = nil, dirty: Bool? = nil,
        rememberFrame: Bool? = nil,
        panes: UInt32? = nil, sectionsPresentation: KayaSectionsPresentation? = nil,
        appearance: KayaAppearance? = nil,
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
            vetoClose: vetoClose, dirty: dirty, rememberFrame: rememberFrame,
            panes: panes,
            sectionsPresentation: sectionsPresentation,
            appearance: appearance, inset: inset,
            onCloseRequested: onCloseRequested, onClosed: onClosed,
            onUndone: onUndone, onRedone: onRedone,
            menus: menus)
    }

    /// Set a window's attributes in one construct — EXACTLY createWindow's
    /// set (docs/dirty-plan.md D2/D4, docs/styling-plan.md D3,
    /// docs/multicolumn-plan.md). `dirty:` is STATE, NOT CHROME: it leaves
    /// `title:` alone and ARMS NOTHING. `inset:` is the CONTENT INSET, 16
    /// by default and 0 for full bleed, and keeps the platform's SAFE
    /// AREA. `panes:` is the CEILING on how many stack entries present
    /// side by side; the root refuses 0 and anything above 3.
    public func window(
        _ id: UInt64 = 0, title: String? = nil, width: Double? = nil,
        height: Double? = nil, vetoClose: Bool? = nil, dirty: Bool? = nil,
        rememberFrame: Bool? = nil,
        panes: UInt32? = nil, sectionsPresentation: KayaSectionsPresentation? = nil,
        appearance: KayaAppearance? = nil,
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
        // The OPT-OUT from window memory (docs/tasks-s4-plan.md P4);
        // inert on the phones.
        if let rememberFrame { tx.setWindowRememberFrame(id, rememberFrame) }
        if let panes { tx.setWindowPanes(id, Int64(panes)) }
        if let sectionsPresentation {
            tx.setWindowSectionsPresentation(id, sectionsPresentation.rawValue)
        }
        // The app's OWN light/dark choice, applied process-wide from the
        // default window (docs/tasks-s2b-plan.md R1-R3).
        if let appearance { tx.setWindowAppearance(id, appearance.rawValue) }
        if let inset { tx.setWindowInset(id, inset) }
        if let onCloseRequested { app.onCloseRequested(id, onCloseRequested) }
        if let onClosed { app.onWindowClosed(id, onClosed) }
        // The history handlers ride the window construct because the
        // LEDGER is per window.
        if let onUndone { app.onUndone(id, onUndone) }
        if let onRedone { app.onRedone(id, onRedone) }
        // menus: appends top-level grouping nodes to this window's
        // command catalog, in order — append-only, at any time.
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
    /// tail without deciding about the slot.
    private func menuTail(
        _ m: KayaMenuItem, _ enabled: KayaMenuBool?, _ icon: Data?, _ symbol: KayaSymbol?
    ) {
        if let enabled { menuEnabled(m, enabled) }
        if let icon { tx.setMenuIcon(m.id, kayaRegisterBlob(icon)) }
        if let symbol { tx.setMenuSymbol(m.id, symbol.rawValue) }
    }

    // A MISTYPED BARE STRING IS SILENT: it becomes a custom format id no
    // clipboard will ever offer, so Paste stays dead and the paste hook
    // never fires, with nothing to see anywhere.
    public static let acceptText = "text"
    static let acceptHtml = "html"
    static let acceptImage = "image"
    public static let acceptFiles = "files"

    /// An action — a leaf command firing exactly one menu_activated
    /// occurrence, for a menu click and for its shortcut alike.
    public func item(
        _ label: KayaMenuText, shortcut: String? = nil,
        enabled: KayaMenuBool? = nil, icon: Data? = nil,
        symbol: KayaSymbol? = nil, primary: Bool = false,
        role: KayaMenuRole? = nil,
        onActivate: ((KayaAppTx) throws -> Void)? = nil
    ) -> KayaMenuItem {
        let m = newMenuItem(KAYA_MENU_KIND_ACTION, label)
        if let shortcut { tx.setMenuShortcut(m.id, shortcut) }
        if let role { tx.setMenuRole(m.id, role.rawValue) }
        menuTail(m, enabled, icon, symbol)
        if primary { tx.setMenuPrimary(m.id, true) }
        if let onActivate { app.menuActivated[m.id] = onActivate }
        return m
    }

    /// The template-node flavor: an item attached to a stamped copy
    /// reports the copy's key path, outermost first.
    public func item(
        _ label: KayaMenuText, enabled: KayaMenuBool? = nil, icon: Data? = nil,
        symbol: KayaSymbol? = nil,
        onActivate: @escaping (KayaAppTx, [KayaValue]) throws -> Void
    ) -> KayaMenuItem {
        let m = newMenuItem(KAYA_MENU_KIND_ACTION, label)
        menuTail(m, enabled, icon, symbol)
        app.menuActivatedNode[m.id] = onActivate
        return m
    }

    /// A toggle, on the Checkbox contract: user flips emit menu_toggled;
    /// programmatic checked writes are QUIET.
    public func toggle(
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

    /// One labeled radio option, appended in declaration order — the order
    /// IS the index vocabulary the group's value selects over.
    public func option(
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

    /// A menu grouping node — at bar level (through the window construct's
    /// menus:) or nested (in a parent's items:).
    public func menu(
        _ label: KayaMenuText, enabled: KayaMenuBool? = nil, icon: Data? = nil,
        symbol: KayaSymbol? = nil, items: [KayaMenuItem] = []
    ) -> KayaMenuItem {
        let m = newMenuItem(KAYA_MENU_KIND_MENU, label)
        for child in items { tx.menuItemAppend(m.id, child.id) }
        menuTail(m, enabled, icon, symbol)
        return m
    }

    /// Reopen a RETAINED menu item — the append-at-any-time discipline.
    /// Props mutate freely on every kind the prop applies to;
    /// programmatic checked/value writes stay QUIET.
    public func menu(
        _ item: KayaMenuItem, label: KayaMenuText? = nil,
        enabled: KayaMenuBool? = nil, checked: KayaMenuBool? = nil,
        value: KayaMenuIndex? = nil, icon: Data? = nil,
        symbol: KayaSymbol? = nil, primary: Bool? = nil,
        shortcut: String? = nil, role: KayaMenuRole? = nil, items: [KayaMenuItem] = []
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
        if let role { tx.setMenuRole(item.id, role.rawValue) }
    }

    /// A radio group — the Choice contract with the platform's checkmark
    /// idiom, admissible wherever a menu grouping node is. `options:`
    /// takes only option children; `value` is the selected 0-based index
    /// and programmatic writes are quiet.
    public func radioGroup(
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

    /// A context menu on a LIVE widget, with the platform's own gesture.
    public func contextMenu(_ target: KayaWidget, items: [KayaMenuItem]) {
        for item in items { tx.contextAttach(target.id, item.id) }
    }

    /// Build a context catalog UNANCHORED — free root items for a
    /// template-node anchor; KayaTpl.contextMenu attaches it inside the
    /// template.
    public func contextCatalog(items: [KayaMenuItem]) -> KayaContextCatalog {
        KayaContextCatalog(items)
    }

    /// Close and forget an auxiliary window — also the veto grammar's
    /// confirmation and the reconciliation after a chrome close.
    public func destroyWindow(_ id: UInt64) {
        tx.destroyWindow(id)
    }

    /// Push a navigation entry onto the primary surface's stack (entry ids
    /// are guest-allocated in the shared surface namespace); materializes
    /// covered, mountIn presents it. `onPopped` fires when the user's back
    /// affordance pops THIS entry natively — never for a programmatic
    /// popEntry — and retires with the one pop; `onBackRequested` fires
    /// per back request while interceptBack is armed, with nothing yet
    /// popped, and tx.popEntry is how you agree.
    public func pushEntry(
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
    public func popEntry(window: UInt64 = 0) {
        tx.popEntry(window)
    }

    /// Request a sheet over `parent` — a window (0, the primary) or a LIVE
    /// SHEET, the chain (docs/sheet-plan.md): a modal hosting a root,
    /// presented by mountIn. Sheet ids are guest-allocated in the shared
    /// surface namespace. `onDismissed` fires when the user's cancel path
    /// closes THIS sheet natively — never for a programmatic dismissSheet —
    /// and retires with the one dismissal; `onDismissRequested` fires per
    /// cancel while interceptDismiss is armed, with nothing yet gone, and
    /// tx.dismissSheet is how you agree. `detent:` is the height the phones
    /// open it at; the desktops ignore it.
    public func presentSheet(
        _ id: UInt64, title: String? = nil, interceptDismiss: Bool? = nil,
        detent: KayaDetent? = nil,
        onDismissed: ((KayaAppTx) throws -> Void)? = nil,
        onDismissRequested: ((KayaAppTx) throws -> Void)? = nil,
        parent: UInt64 = 0
    ) {
        tx.presentSheet(parent, id)
        if let title { tx.setSheetTitle(id, title) }
        if let interceptDismiss { tx.setSheetInterceptDismiss(id, interceptDismiss) }
        if let detent { tx.setSheetDetent(id, detent.rawValue) }
        if let onDismissed { app.onSheetDismissed(id, onDismissed) }
        if let onDismissRequested { app.onDismissRequested(id, onDismissRequested) }
    }

    /// Dismiss a live sheet and forget its tree, child sheets with it — also
    /// the dismiss-veto grammar's confirmation after onDismissRequested.
    public func dismissSheet(_ id: UInt64) {
        tx.dismissSheet(id)
    }

    /// Append a section to the window's section set (section ids are
    /// guest-allocated in the shared surface namespace). The set is
    /// APPEND-ONLY and every section's root is retained while covered:
    /// switching is SELECTION, not lifecycle. `onSelected` fires each time
    /// the USER switches to it — post-fact and NOT one-shot; a
    /// programmatic selectSection does not fire it.
    /// `badge:` is the COUNT on the switcher item
    /// (docs/tasks-s2-plan.md T2) — a number or, through
    /// `badgeSignal:`, a signal holding one; zero clears.
    public func addSection(
        _ id: UInt64, title: String? = nil, symbol: KayaSymbol? = nil,
        badge: Double? = nil, badgeSignal: KayaSignal? = nil,
        onSelected: ((KayaAppTx) throws -> Void)? = nil,
        window: UInt64 = 0
    ) {
        tx.addSection(window, id)
        if let title { tx.setSectionTitle(id, title) }
        if let symbol { tx.setSectionSymbol(id, symbol.rawValue) }
        if let badge { tx.setSectionBadge(id, badge) }
        if let badgeSignal { tx.bindSectionBadge(id, badgeSignal.id) }
        if let onSelected { app.onSectionSelected(id, onSelected) }
    }

    /// Select a section programmatically: never echoes onSelected.
    public func selectSection(_ id: UInt64, window: UInt64 = 0) {
        tx.selectSection(window, id)
    }

    /// Mount a root into a specific window; mounting presents an
    /// auxiliary.
    public func mountIn(_ window: UInt64, _ root: KayaWidget) {
        tx.mount(window, root.id)
    }

    public func mount(_ root: KayaWidget) {
        tx.mount(0, root.id)
    }
}

/// A template body: the same declaration vocabulary with template-node ids,
/// plus element bindings.
public final class KayaTpl {
    private let tx: KayaAppTx

    init(tx: KayaAppTx) {
        self.tx = tx
    }

    @discardableResult
    func widget(_ kind: UInt32) -> KayaNodeHandle {
        let n = tx.app.nextNode()
        defer { tx.app.parentAtCreation(node: n.id) }
        tx.tx.createWidget(n.id, kind)
        return n
    }

    /// The raw Text write on a node — PRIVATE, and that is the point: only
    /// the receiver's type tells it from the live zone's `setText`, which
    /// no sweep can see, so hiding it is what keeps the floor spelling
    /// from existing (docs/tpl-props-plan.md F3,
    /// tools/check-sugar-surface.py).
    private func setText(_ n: KayaNodeHandle, _ text: String) {
        tx.tx.setText(n.id, text)
    }

    /// Bind text to the element of the enclosing For, `level` Fors up
    /// (0 = nearest).
    func bindTextElement(_ n: KayaNodeHandle, level: UInt32 = 0) {
        tx.tx.bindTextElement(n.id, level: level)
    }

    /// Weight a template node within its stamped row or column. A template
    /// `scroll` needs it: an unconstrained viewport hugs its content.
    /// Spacing and align have no spelling in this zone (docs/deferred.md).
    public func setGrow(_ n: KayaNodeHandle, _ weight: Double) {
        tx.tx.setGrow(n.id, weight)
    }

    /// A stamped copy's accessibility IDENTIFIER. The argument's type
    /// picks the source: a String gives EVERY copy the same key, which is
    /// legal; the row's own field is the spelling when automation must
    /// tell two copies apart.
    public func setA11yId(_ n: KayaNodeHandle, _ id: String) {
        tx.tx.setA11yId(n.id, id)
    }

    func setA11yId(_ n: KayaNodeHandle, _ s: KayaSignal) {
        tx.tx.bindA11yId(n.id, s.id)
    }

    public func setA11yId(_ n: KayaNodeHandle, level: UInt32 = 0, _ f: KayaField<String>) {
        tx.tx.bindA11yIdElement(n.id, level: level, field: f.index)
    }

    /// What an assistive client SPEAKS for a stamped copy. Leave it unset
    /// to keep whatever the platform derives from the copy's own content;
    /// THE ROW'S OWN FIELD is the only source that makes two copies say
    /// different things.
    func setA11yLabel(_ n: KayaNodeHandle, _ label: String) {
        tx.tx.setA11yLabel(n.id, label)
    }

    func setA11yLabel(_ n: KayaNodeHandle, _ s: KayaSignal) {
        tx.tx.bindA11yLabel(n.id, s.id)
    }

    public func setA11yLabel(_ n: KayaNodeHandle, level: UInt32 = 0, _ f: KayaField<String>) {
        tx.tx.bindA11yLabelElement(n.id, level: level, field: f.index)
    }

    /// A stamped copy's HELP TEXT (KayaTx.setHelp). THE ROW'S OWN
    /// FIELD is the source that makes two copies explain themselves
    /// differently.
    func setHelp(_ n: KayaNodeHandle, _ text: String) {
        tx.tx.setHelp(n.id, text)
    }

    func setHelp(_ n: KayaNodeHandle, _ s: KayaSignal) {
        tx.tx.bindHelp(n.id, s.id)
    }

    public func setHelp(_ n: KayaNodeHandle, level: UInt32 = 0, _ f: KayaField<String>) {
        tx.tx.bindHelpElement(n.id, level: level, field: f.index)
    }

    /// A stamped field's PROMPT while it is empty (KayaTx.setPlaceholder).
    public func setPlaceholder(_ n: KayaNodeHandle, _ text: String) {
        tx.tx.setPlaceholder(n.id, text)
    }

    public func setPlaceholder(_ n: KayaNodeHandle, _ s: KayaSignal) {
        tx.tx.bindPlaceholder(n.id, s.id)
    }

    public func setPlaceholder(_ n: KayaNodeHandle, level: UInt32 = 0, _ f: KayaField<String>) {
        tx.tx.bindPlaceholderElement(n.id, level: level, field: f.index)
    }

    /// A stamped link's DESTINATION (KayaTx.setHref).
    public func setHref(_ n: KayaNodeHandle, _ url: String) {
        tx.tx.setHref(n.id, url)
    }

    public func setHref(_ n: KayaNodeHandle, _ s: KayaSignal) {
        tx.tx.bindHref(n.id, s.id)
    }

    public func setHref(_ n: KayaNodeHandle, level: UInt32 = 0, _ f: KayaField<String>) {
        tx.tx.bindHrefElement(n.id, level: level, field: f.index)
    }

    /// A stamped copy's cross-axis stretch (KayaTx.setFill).
    public func setFill(_ n: KayaNodeHandle, _ on: Bool) {
        tx.tx.setFill(n.id, on)
    }

    /// A stamped container's cross-axis child placement (KayaTx.setAlign).
    public func setAlign(_ n: KayaNodeHandle, _ align: KayaAlign) {
        tx.tx.setAlign(n.id, align.rawValue)
    }

    /// A stamped container filled with a platform tint (KayaTx.setFilled) —
    /// a chat thread's bubbles are stamped rows.
    public func setFilled(_ n: KayaNodeHandle, _ tint: KayaTint) {
        tx.tx.setFilled(n.id, tint.rawValue)
    }

    /// A stamped grid's auto columns at a floor (KayaTx.setColumnsAuto).
    public func setColumnsAuto(_ n: KayaNodeHandle, _ minWidth: Double) {
        tx.tx.setColumns(n.id, 0)
        tx.tx.setMinColumnWidth(n.id, minWidth)
    }

    /// A stamped row that flows onto new lines (KayaTx.setWrap).
    public func setWrap(_ n: KayaNodeHandle, _ on: Bool) {
        tx.tx.setWrap(n.id, on)
    }

    /// A stamped textarea that SUBMITS on Return (docs/submit-plan.md S2).
    public func setSubmits(_ n: KayaNodeHandle, _ on: Bool) {
        tx.tx.setSubmits(n.id, on)
    }

    /// What ACTIVATING a stamped copy does. Write a VERB PHRASE.
    /// Activation kinds only, refused by the ROOT at DECLARE time.
    public func setA11yHint(_ n: KayaNodeHandle, _ hint: String) {
        tx.tx.setA11yHint(n.id, hint)
    }

    public func setA11yHint(_ n: KayaNodeHandle, _ s: KayaSignal) {
        tx.tx.bindA11yHint(n.id, s.id)
    }

    public func setA11yHint(_ n: KayaNodeHandle, level: UInt32 = 0, _ f: KayaField<String>) {
        tx.tx.bindA11yHintElement(n.id, level: level, field: f.index)
    }

    /// Declare what a stamped copy takes from a paste. Entry and textarea
    /// only. THIS IS WHAT MAKES A STAMPED PASTE HAPPEN AT ALL: every
    /// backend gates the paste occurrence on the focused widget's accept
    /// list and falls back to the platform's own insertion when it is
    /// empty. CONST ONLY — on Android the list IS the native registration.
    public func setAccepts(_ n: KayaNodeHandle, _ kinds: [String]) {
        tx.tx.setAccepts(n.id, kayaAcceptList(kinds))
    }

    /// Every stamped copy of `n` hands over this payload with its own
    /// identity, each representation a constant or the row's own field
    /// (docs/dnd-plan.md §4); a copy's OWN payload is
    /// `KayaAppTx.draggableAt` after its insert, constants only, and the
    /// copy's keys reach the app through the node flavour of `onDragEnded`.
    public func draggable(_ n: KayaNodeHandle) -> KayaTplDragRef {
        KayaTplDragRef(tx: tx, node: n.id)
    }

    /// Every stamped copy of `n` receives drops with these operations,
    /// taking what `setAccepts` names; the landing arrives at the node
    /// flavour of `onDrop` with the copy's keys.
    public func setDropTarget(_ n: KayaNodeHandle, _ ops: [KayaOp]) {
        tx.tx.setDropTarget(n.id, ops.reduce(0) { $0 | $1.rawValue }, 0, [])
    }

    /// What a stamped copy MEANS: semantic emphasis, never appearance.
    /// CONST ONLY, `setAccepts`'s rule — what a copy means is a fact about
    /// the PROTOTYPE. The kind restriction is the ROOT'S.
    public func setRole(_ n: KayaNodeHandle, _ role: KayaRole) {
        tx.tx.setRole(n.id, role.rawValue)
    }

    /// A stamped CONTAINER's own padding, in DIP between its bounds and
    /// its children.
    public func setInset(_ n: KayaNodeHandle, _ pad: Double) {
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

    /// Bind a date picker's value to one field of the element;
    /// KayaField<KayaDate> only (docs/datetime-plan.md D10).
    func bindDateField(_ n: KayaNodeHandle, level: UInt32 = 0, _ f: KayaField<KayaDate>) {
        tx.tx.bindDateElement(n.id, level: level, field: f.index)
    }

    /// Bind a time picker's value to one field of the element.
    func bindTimeField(_ n: KayaNodeHandle, level: UInt32 = 0, _ f: KayaField<KayaTime>) {
        tx.tx.bindTimeElement(n.id, level: level, field: f.index)
    }

    /// Bind an image's source to one field of the element;
    /// KayaField<Data> only — the token pins the type at compile time.
    func bindSourceField(_ n: KayaNodeHandle, level: UInt32 = 0, _ f: KayaField<Data>) {
        tx.tx.bindSourceElement(n.id, level: level, field: f.index)
    }

    /// Bind a numeric value to one field of the element;
    /// KayaField<Double> only. ONE binder serves three kinds because a
    /// progress fraction, a slider position and a choice index are all
    /// Prop::Value on the wire.
    func bindValueField(_ n: KayaNodeHandle, level: UInt32 = 0, _ f: KayaField<Double>) {
        tx.tx.bindValueElement(n.id, level: level, field: f.index)
    }

    // Construction sugar, template flavor: one name per widget, the
    // argument's type picks the addressable source (constant, signal, or
    // element field); handlers receive the stamped copy's keys first.
    @discardableResult
    public func label(_ text: String) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_LABEL))
        setText(n, text)
        return n
    }

    @discardableResult
    func label(_ s: KayaSignal) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_LABEL))
        tx.tx.bindText(n.id, s.id)
        return n
    }

    @discardableResult
    public func label(_ f: KayaField<String>) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_LABEL))
        bindTextField(n, f)
        return n
    }

    /// A label wearing the heading role, stamped.
    @discardableResult
    func heading(_ text: String) -> KayaNodeHandle {
        let n = label(text)
        setRole(n, .heading)
        return n
    }

    @discardableResult
    func heading(_ s: KayaSignal) -> KayaNodeHandle {
        let n = label(s)
        setRole(n, .heading)
        return n
    }

    @discardableResult
    func heading(_ f: KayaField<String>) -> KayaNodeHandle {
        let n = label(f)
        setRole(n, .heading)
        return n
    }

    /// A label wearing the caption role, stamped.
    @discardableResult
    func caption(_ text: String) -> KayaNodeHandle {
        let n = label(text)
        setRole(n, .caption)
        return n
    }

    @discardableResult
    func caption(_ s: KayaSignal) -> KayaNodeHandle {
        let n = label(s)
        setRole(n, .caption)
        return n
    }

    @discardableResult
    func caption(_ f: KayaField<String>) -> KayaNodeHandle {
        let n = label(f)
        setRole(n, .caption)
        return n
    }

    /// A button with its caption, in the blueprint.
    @discardableResult
    public func button(_ text: String) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_BUTTON))
        setText(n, text)
        return n
    }

    @discardableResult
    public func button(_ s: KayaSignal) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_BUTTON))
        tx.tx.bindText(n.id, s.id)
        return n
    }

    /// A button captioned from the row's OWN field — the "Delete <that
    /// row's title>" shape, which only this zone can spell.
    @discardableResult
    public func button(_ f: KayaField<String>) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_BUTTON))
        bindTextField(n, f)
        return n
    }

    @discardableResult
    public func checkbox(
        _ f: KayaField<Bool>,
        onToggle: ((KayaAppTx, [KayaValue], Bool) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_CHECKBOX))
        bindCheckedField(n, f)
        if let onToggle { tx.app.onToggle(n, onToggle) }
        return n
    }

    /// A date picker in the blueprint bound to the row's own Date field
    /// (docs/datetime-plan.md D10); picks carry the copy's keys first.
    @discardableResult
    public func datePicker(
        _ f: KayaField<KayaDate>,
        onDate: ((KayaAppTx, [KayaValue], KayaDate) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_DATE_PICKER))
        bindDateField(n, f)
        if let onDate { tx.app.onDate(n, onDate) }
        return n
    }

    /// A date picker at a constant date, the same in every stamped copy.
    @discardableResult
    func datePicker(
        _ value: KayaDate,
        onDate: ((KayaAppTx, [KayaValue], KayaDate) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_DATE_PICKER))
        _ = kayaPackedDate("a date picker's value", value)
        tx.tx.setDate(n.id, value.year, value.month, value.day)
        if let onDate { tx.app.onDate(n, onDate) }
        return n
    }

    /// A date picker whose value binds a signal.
    @discardableResult
    func datePicker(
        _ s: KayaSignal,
        onDate: ((KayaAppTx, [KayaValue], KayaDate) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_DATE_PICKER))
        tx.tx.bindDate(n.id, s.id)
        if let onDate { tx.app.onDate(n, onDate) }
        return n
    }

    /// A time picker bound to the row's own Time field.
    @discardableResult
    public func timePicker(
        _ f: KayaField<KayaTime>,
        onTime: ((KayaAppTx, [KayaValue], KayaTime) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_TIME_PICKER))
        bindTimeField(n, f)
        if let onTime { tx.app.onTime(n, onTime) }
        return n
    }

    /// A time picker at a constant time.
    @discardableResult
    func timePicker(
        _ value: KayaTime,
        onTime: ((KayaAppTx, [KayaValue], KayaTime) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_TIME_PICKER))
        _ = kayaPackedTime("a time picker's value", value)
        tx.tx.setTime(n.id, value.hour, value.minute)
        if let onTime { tx.app.onTime(n, onTime) }
        return n
    }

    /// A time picker whose value binds a signal.
    @discardableResult
    func timePicker(
        _ s: KayaSignal,
        onTime: ((KayaAppTx, [KayaValue], KayaTime) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_TIME_PICKER))
        tx.tx.bindTime(n.id, s.id)
        if let onTime { tx.app.onTime(n, onTime) }
        return n
    }

    /// A single-line text field per stamped copy. UNCONTROLLED, which is
    /// why the primary form takes no source at all: each edit arrives
    /// naming this node AND the copy's key path.
    @discardableResult
    public func entry(
        onChange: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil,
        onSubmit: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        textFieldOf(UInt32(KAYA_KIND_ENTRY), onChange, onSubmit)
    }

    /// An entry seeded from an addressable source. HOW LONG THE SOURCE
    /// LASTS DIFFERS BY SOURCE: a String is ONE write at declaration, so
    /// the user owns the field from the first keystroke, while a signal or
    /// a field stays LIVE and a later write REPLACES whatever the user has
    /// typed. There is no "seed once and let go" arm on the wire.
    @discardableResult
    func entry(
        _ text: String,
        onChange: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil,
        onSubmit: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = textFieldOf(UInt32(KAYA_KIND_ENTRY), onChange, onSubmit)
        setText(n, text)
        return n
    }

    @discardableResult
    func entry(
        _ s: KayaSignal,
        onChange: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil,
        onSubmit: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = textFieldOf(UInt32(KAYA_KIND_ENTRY), onChange, onSubmit)
        tx.tx.bindText(n.id, s.id)
        return n
    }

    @discardableResult
    func entry(
        _ f: KayaField<String>,
        onChange: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil,
        onSubmit: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = textFieldOf(UInt32(KAYA_KIND_ENTRY), onChange, onSubmit)
        bindTextField(n, f)
        return n
    }

    /// A multi-line editor per stamped copy, on the entry's uncontrolled
    /// contract and with the same four spellings.
    @discardableResult
    func textarea(
        onChange: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil,
        onSubmit: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        textFieldOf(UInt32(KAYA_KIND_TEXTAREA), onChange, onSubmit)
    }

    @discardableResult
    func textarea(
        _ text: String,
        onChange: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil,
        onSubmit: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = textFieldOf(UInt32(KAYA_KIND_TEXTAREA), onChange, onSubmit)
        setText(n, text)
        return n
    }

    @discardableResult
    func textarea(
        _ s: KayaSignal,
        onChange: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil,
        onSubmit: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = textFieldOf(UInt32(KAYA_KIND_TEXTAREA), onChange, onSubmit)
        tx.tx.bindText(n.id, s.id)
        return n
    }

    @discardableResult
    func textarea(
        _ f: KayaField<String>,
        onChange: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil,
        onSubmit: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = textFieldOf(UInt32(KAYA_KIND_TEXTAREA), onChange, onSubmit)
        bindTextField(n, f)
        return n
    }

    /// A RICH textarea per stamped copy whose document is a
    /// `KayaDocument` FIELD of the row (docs/rich-text-plan.md §19):
    /// `rich` first, then the bound document, which the core turns into
    /// that copy's own set_rich_text. The user's acts fold into the row's
    /// field as a live widget's fold into its mirror, so the app writes a
    /// copy's document by patching the row and reads it back off the row.
    @discardableResult
    public func textarea(
        document f: KayaField<KayaDocument>,
        onChange: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil,
        onSubmit: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = textFieldOf(UInt32(KAYA_KIND_TEXTAREA), onChange, onSubmit)
        tx.tx.setRich(n.id, true)
        // LEVEL 0 ONLY: the fold names the row by the occurrence's own
        // last key.
        tx.app.bindDocument(node: n.id, field: f.index)
        tx.tx.bindDocumentElement(n.id, level: 0, field: f.index)
        return n
    }

    /// A search field per stamped copy, on the entry's uncontrolled
    /// contract under the platform's search chrome, with the same four
    /// spellings (docs/search-plan.md).
    @discardableResult
    public func search(
        onChange: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil,
        onSubmit: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        textFieldOf(UInt32(KAYA_KIND_SEARCH), onChange, onSubmit)
    }

    @discardableResult
    public func search(
        _ text: String,
        onChange: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil,
        onSubmit: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = textFieldOf(UInt32(KAYA_KIND_SEARCH), onChange, onSubmit)
        setText(n, text)
        return n
    }

    @discardableResult
    public func search(
        _ s: KayaSignal,
        onChange: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil,
        onSubmit: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = textFieldOf(UInt32(KAYA_KIND_SEARCH), onChange, onSubmit)
        tx.tx.bindText(n.id, s.id)
        return n
    }

    @discardableResult
    public func search(
        _ f: KayaField<String>,
        onChange: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil,
        onSubmit: ((KayaAppTx, [KayaValue], String) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = textFieldOf(UInt32(KAYA_KIND_SEARCH), onChange, onSubmit)
        bindTextField(n, f)
        return n
    }

    /// The unsourced half of the text kinds: the widget and its handlers.
    /// `onSubmit:` is the stamped copy's Return gesture, keys first
    /// (docs/submit-plan.md S7).
    private func textFieldOf(
        _ kind: UInt32, _ onChange: ((KayaAppTx, [KayaValue], String) throws -> Void)?,
        _ onSubmit: ((KayaAppTx, [KayaValue], String) throws -> Void)?
    ) -> KayaNodeHandle {
        let n = widget(kind)
        if let onChange { tx.app.onChange(n, onChange) }
        if let onSubmit { tx.app.onSubmitted(n, onSubmit) }
        return n
    }

    /// A progress bar whose fraction comes from an addressable source.
    @discardableResult
    public func progress(_ value: Double) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_PROGRESS))
        tx.tx.setValue(n.id, value)
        return n
    }

    @discardableResult
    public func progress(_ s: KayaSignal) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_PROGRESS))
        tx.tx.bindValue(n.id, s.id)
        return n
    }

    @discardableResult
    public func progress(_ f: KayaField<Double>) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_PROGRESS))
        bindValueField(n, f)
        return n
    }

    /// A progress bar in the platform's activity mode. Its own constructor
    /// rather than the live zone's `indeterminate:` flag, because here the
    /// fraction argument is what picks the source overload.
    @discardableResult
    func progressIndeterminate() -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_PROGRESS))
        tx.tx.setIndeterminate(n.id, true)
        return n
    }

    /// A slider over min...max in the blueprint. THE RANGE DESCRIBES THE
    /// PROTOTYPE and stays a pair of constants; the POSITION takes a
    /// source. A move does NOT write the row's field back — the handler
    /// decides whether the model follows.
    @discardableResult
    func slider(
        min: Double = 0.0, max: Double = 1.0, value: Double,
        step: Double? = nil, tickSpacing: Double? = nil,
        onChange: ((KayaAppTx, [KayaValue], Double) throws -> Void)? = nil,
        onCommit: ((KayaAppTx, [KayaValue], Double) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = sliderOf(min, max, step, tickSpacing, onChange, onCommit)
        tx.tx.setValue(n.id, value)
        return n
    }

    @discardableResult
    func slider(
        min: Double = 0.0, max: Double = 1.0, value s: KayaSignal,
        step: Double? = nil, tickSpacing: Double? = nil,
        onChange: ((KayaAppTx, [KayaValue], Double) throws -> Void)? = nil,
        onCommit: ((KayaAppTx, [KayaValue], Double) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = sliderOf(min, max, step, tickSpacing, onChange, onCommit)
        tx.tx.bindValue(n.id, s.id)
        return n
    }

    @discardableResult
    public func slider(
        min: Double = 0.0, max: Double = 1.0, value f: KayaField<Double>,
        step: Double? = nil, tickSpacing: Double? = nil,
        onChange: ((KayaAppTx, [KayaValue], Double) throws -> Void)? = nil,
        onCommit: ((KayaAppTx, [KayaValue], Double) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = sliderOf(min, max, step, tickSpacing, onChange, onCommit)
        bindValueField(n, f)
        return n
    }

    private func sliderOf(
        _ min: Double, _ max: Double, _ step: Double?, _ tickSpacing: Double?,
        _ onChange: ((KayaAppTx, [KayaValue], Double) throws -> Void)?,
        _ onCommit: ((KayaAppTx, [KayaValue], Double) throws -> Void)?
    ) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_SLIDER))
        tx.tx.setMin(n.id, min)
        tx.tx.setMax(n.id, max)
        if let step { tx.tx.setStep(n.id, step) }
        if let tickSpacing { tx.tx.setTickSpacing(n.id, tickSpacing) }
        if let onChange { tx.app.onValueChanged(n, onChange) }
        if let onCommit { tx.app.onValueCommitted(n, onCommit) }
        return n
    }

    /// A dropdown in the blueprint: the option list is the BLUEPRINT'S,
    /// the choice is the row's. `onSelect` receives the copy's key path
    /// and each USER pick's new 0-based index.
    @discardableResult
    public func select(
        _ options: [String], selected: Int = 0,
        onSelect: ((KayaAppTx, [KayaValue], Int) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = choiceOf(UInt32(KAYA_KIND_SELECT), options, onSelect)
        tx.tx.setValue(n.id, Double(selected))
        return n
    }

    @discardableResult
    public func select(
        _ options: [String], selected s: KayaSignal,
        onSelect: ((KayaAppTx, [KayaValue], Int) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = choiceOf(UInt32(KAYA_KIND_SELECT), options, onSelect)
        tx.tx.bindValue(n.id, s.id)
        return n
    }

    @discardableResult
    public func select(
        _ options: [String], selected f: KayaField<Double>,
        onSelect: ((KayaAppTx, [KayaValue], Int) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = choiceOf(UInt32(KAYA_KIND_SELECT), options, onSelect)
        bindValueField(n, f)
        return n
    }

    /// A radio group in the blueprint: `select`'s contract in its inline
    /// presentation.
    @discardableResult
    public func radio(
        _ options: [String], selected: Int = 0,
        onSelect: ((KayaAppTx, [KayaValue], Int) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = choiceOf(UInt32(KAYA_KIND_RADIO), options, onSelect)
        tx.tx.setValue(n.id, Double(selected))
        return n
    }

    @discardableResult
    public func radio(
        _ options: [String], selected s: KayaSignal,
        onSelect: ((KayaAppTx, [KayaValue], Int) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = choiceOf(UInt32(KAYA_KIND_RADIO), options, onSelect)
        tx.tx.bindValue(n.id, s.id)
        return n
    }

    @discardableResult
    public func radio(
        _ options: [String], selected f: KayaField<Double>,
        onSelect: ((KayaAppTx, [KayaValue], Int) throws -> Void)? = nil
    ) -> KayaNodeHandle {
        let n = choiceOf(UInt32(KAYA_KIND_RADIO), options, onSelect)
        bindValueField(n, f)
        return n
    }

    /// Both choice kinds, minus the index. The options are LABEL CHILDREN
    /// of the prototype, so every stamped copy offers the same list and
    /// only the selected index can be the row's
    /// (docs/sugar-pass-plan.md §2).
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

    /// An image with constant encoded bytes: every stamped copy shows the
    /// same picture.
    @discardableResult
    func image(_ source: Data) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_IMAGE))
        tx.tx.setSource(n.id, kayaRegisterBlob(source))
        return n
    }

    @discardableResult
    func image(_ s: KayaSignal) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_IMAGE))
        tx.tx.bindSource(n.id, s.id)
        return n
    }

    @discardableResult
    public func image(_ f: KayaField<Data>) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_IMAGE))
        bindSourceField(n, f)
        return n
    }

    /// A canvas per stamped copy — a sparkline in a table cell
    /// (docs/canvas-plan.md §3.1). The drawing is declared with the node,
    /// so every copy is born with it; `KayaAppTx.draw(_:at:_:_:)`
    /// re-declares one copy's afterwards.
    @discardableResult
    public func canvas(_ viewbox: KayaViewbox, _ body: (KayaDraw) -> Void) -> KayaNodeHandle {
        let n = widget(UInt32(KAYA_KIND_CANVAS))
        let d = KayaDraw(viewbox: viewbox)
        body(d)
        tx.tx.setDrawing(
            n.id, .f64(viewbox.w), .f64(viewbox.h), UInt32(d.ops.count), 0, d.ops)
        return n
    }

    @discardableResult
    public func row(@KayaNodeChildren _ children: () -> Void) -> KayaNodeHandle {
        nodeContainerOf(UInt32(KAYA_KIND_ROW), children)
    }

    @discardableResult
    public func column(@KayaNodeChildren _ children: () -> Void) -> KayaNodeHandle {
        nodeContainerOf(UInt32(KAYA_KIND_COLUMN), children)
    }

    /// A vertical scroll viewport over EXACTLY ONE child, per stamped
    /// copy.
    @discardableResult
    public func scroll(@KayaNodeChildren _ children: () -> Void) -> KayaNodeHandle {
        nodeContainerOf(UInt32(KAYA_KIND_SCROLL), children)
    }

    /// A grid laying each copy's children out row-major into `columns`
    /// columns. The column count describes the PROTOTYPE, so it is a plain
    /// constant rather than a source.
    @discardableResult
    public func grid(columns: Int, @KayaNodeChildren _ children: () -> Void) -> KayaNodeHandle {
        let n = nodeContainerOf(UInt32(KAYA_KIND_GRID), children)
        tx.tx.setColumns(n.id, Double(columns))
        return n
    }

    /// A LABELLED ROW per stamped copy (docs/forms-plan.md): the label
    /// names the one control the children declare, with an optional
    /// trailing button after it.
    public func labeled(_ label: String, @KayaNodeChildren _ children: () -> Void)
        -> KayaNodeHandle
    {
        labeledOf(children) { _ = self.label(label) }
    }

    public func labeled(_ label: KayaSignal, @KayaNodeChildren _ children: () -> Void)
        -> KayaNodeHandle
    {
        labeledOf(children) { _ = self.label(label) }
    }

    @discardableResult
    public func labeled(
        _ label: KayaField<String>, @KayaNodeChildren _ children: () -> Void
    ) -> KayaNodeHandle {
        labeledOf(children) { _ = self.label(label) }
    }

    private func labeledOf(
        _ children: () -> Void, _ name: () -> Void
    ) -> KayaNodeHandle {
        let parent = widget(UInt32(KAYA_KIND_LABELED))
        tx.app.childFrames.append(KayaApp.KayaFrame(template: true))
        name()
        children()
        let ids = tx.app.childFrames.removeLast().ids
        for id in ids { tx.tx.addChild(parent.id, id) }
        return parent
    }

    /// A spacer: PURE SUGAR for an empty grown column, in every stamped
    /// copy.
    @discardableResult
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
    /// template node: every stamped copy shows the same catalog, and each
    /// activation carries that copy's key path.
    public func contextMenu(_ node: KayaNodeHandle, _ catalog: KayaContextCatalog) {
        precondition(
            !catalog.attached, "kaya: a context catalog takes exactly one anchor")
        catalog.attached = true
        for root in catalog.roots {
            tx.tx.contextAttachNode(node.id, root.id)
        }
    }

    public func collection() -> KayaCollection {
        tx.collection()
    }

    /// Declare a collection of T records inside this template; the struct
    /// is the schema. A nested collection may only be declared in the
    /// template scope. IN THIS FILE because `tx` is fileprivate storage —
    /// the body is KayaRecords' extension.
    public func collection<T: KayaRecord>(of type: T.Type) -> KayaRecordCollection<T> {
        tx.collection(of: type)
    }

    /// A nested For as a child: forEach whose body keeps no handles.
    @discardableResult
    public func each(_ c: KayaCollection, _ body: (KayaTpl) -> Void) -> KayaNodeHandle {
        forEach(c) { body($0) }.0
    }

    /// Declare the header bar of a NESTED For: one declaration, every
    /// stamped copy, each copy sorting without disturbing its siblings.
    /// CALL IT RIGHT AFTER `forEach`/`each` RETURNS, in the same template
    /// body: this op resolves against the OPEN parent scope, and a
    /// grandparent's is not expressible (docs/tables-plan.md, MEASURED IN
    /// SLICE 1).
    public func columns(_ n: KayaNodeHandle, _ titles: [String], _ sort: KayaSort) {
        // pathLen 0 against a TEMPLATE NODE: the bar for every copy — the
        // id's zone is what tells this from the live case.
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
