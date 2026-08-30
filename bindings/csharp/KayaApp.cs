// kaya's idiomatic surface for C#: id allocation, template scoping and
// occurrence dispatch, layered over the runtime (Kaya.cs) and the
// generated wire vocabulary (KayaWire.cs). See DESIGN.md's binding
// conventions.
//
// Dispatch runs on the app thread after it pulls from the ring; the core
// never calls into the guest.

using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;

readonly struct Signal
{
    /// Mint a derived signal: recomputed when the source is written,
    /// the write batched into the same transaction. Reaches the open
    /// transaction ambiently, because the operators below are static.
    public Signal Derive(Func<object, object> compute)
    {
        var app = KayaApp.Ambient;
        var tx = app?.CurrentTx ?? throw new InvalidOperationException(
            "kaya: a derived signal is minted inside a transaction (build or handler)");
        var source = this;
        var d = tx.Signal(compute(app.SignalMirrors[source.Id]));
        tx.RegisterSignalDep(source.Id, t =>
        {
            object v = compute(app.SignalMirrors[source.Id]);
            if (!Equals(v, app.SignalMirrors[d.Id]))
                t.Write(d, v);
        });
        return d;
    }

    /// The derive vocabulary (the cross-language canon: eq, ne, lt,
    /// fmt, …); the operators below are these methods in operator
    /// clothes.
    public Signal Eq(object other) => Derive(v => ValuesEqual(v, other));

    public Signal Ne(object other) => Derive(v => !ValuesEqual(v, other));

    public Signal Lt(object other) => Derive(v => CompareValues(v, other) < 0);

    public Signal Gt(object other) => Derive(v => CompareValues(v, other) > 0);

    public Signal Le(object other) => Derive(v => CompareValues(v, other) <= 0);

    public Signal Ge(object other) => Derive(v => CompareValues(v, other) >= 0);

    public Signal Fmt(string template) => Derive(v => string.Format(template, v));

    // Wire scalars compare across numeric representations: a guest
    // that wrote an int and compares to a long must not get a silent
    // false.
    static bool IsNumber(object v) =>
        v is sbyte or byte or short or ushort or int or uint or long or ulong
            or float or double or decimal;

    static bool ValuesEqual(object a, object b) =>
        IsNumber(a) && IsNumber(b)
            ? Convert.ToDouble(a) == Convert.ToDouble(b)
            : Equals(a, b);

    static int CompareValues(object a, object b) =>
        IsNumber(a) && IsNumber(b)
            ? Convert.ToDouble(a).CompareTo(Convert.ToDouble(b))
            : Comparer<object>.Default.Compare(a, b);

    // The documented sharp edge (the SQLAlchemy/pandas trade-off):
    // == no longer answers identity, so `signal == null` mints a
    // derived — reference checks use `is null`, which bypasses user
    // operators.
    public static Signal operator ==(Signal s, object v) => s.Eq(v);

    public static Signal operator !=(Signal s, object v) => s.Ne(v);

    public static Signal operator <(Signal s, object v) => s.Lt(v);

    public static Signal operator >(Signal s, object v) => s.Gt(v);

    public static Signal operator <=(Signal s, object v) => s.Le(v);

    public static Signal operator >=(Signal s, object v) => s.Ge(v);

    public override bool Equals(object obj) => obj is Signal other && Id == other.Id;

    public override int GetHashCode() => Id.GetHashCode();

    internal readonly ulong Id;

    internal Signal(ulong id) => Id = id;
}

/// A live widget: exactly one thing on screen.
readonly struct Widget
{
    internal readonly ulong Id;

    internal Widget(ulong id) => Id = id;

    /// <summary>THIS CANVAS REFUSES COERCION: it draws at its viewbox and
    /// is placed in whatever track layout gives it, never adapting to it
    /// (docs/canvas-plan.md §3.2.1, ruling 2). A canvas that declares
    /// nothing is `scale`, which has no spelling on purpose.</summary>
    public Widget Fixed()
    {
        KayaApp.AmbientTx("Fixed()").SizePolicy(this, KayaWire.SizePolicyFixed);
        return this;
    }

    /// <summary>THIS CANVAS'S DRAWING IS A FUNCTION OF ITS SIZE: `f` is
    /// handed the size layout assigned, which becomes the viewbox it draws
    /// in, and the core takes back what it drew for that size.
    ///
    /// PROVIDING THE HANDLER IS THE DECLARATION, so this registers `f` AND
    /// puts the policy on the wire in one act — a registered handler
    /// nothing ever calls is unspellable (docs/canvas-plan.md §3.2.1).
    ///
    /// The binding answers the ask inside a transaction IT opens
    /// (tools/check-ambient-tx.sh); it never reaches the guest as an
    /// occurrence.</summary>
    public Widget OnDraw(Action<Draw, Viewbox> f)
    {
        var tx = KayaApp.AmbientTx("OnDraw()");
        tx.App.RegisterDraw(this, (d, size, _) => f(d, size));
        tx.SizePolicy(this, KayaWire.SizePolicyRedraw);
        return this;
    }

    /// <summary>The same, on the platform's FRAME CLOCK: `f` is handed the
    /// assigned size and the frame's time in seconds. A tick canvas is a
    /// redraw canvas too — the core asks it once before its first frame.
    ///
    /// THE TIME IS THE PLATFORM'S; a guest that reads its own clock
    /// re-imports the jitter the frame time exists to remove. Under the
    /// harness it is the core's deterministic step, advanced by a
    /// verb.</summary>
    public Widget OnTick(Action<Draw, Viewbox, double> f)
    {
        var tx = KayaApp.AmbientTx("OnTick()");
        tx.App.RegisterDraw(this, f);
        tx.SizePolicy(this, KayaWire.SizePolicyTick);
        return this;
    }
}

/// A half-open span of a text widget's content — Start up to but not
/// including Stop — in UTF-8 BYTE offsets into the widget's current
/// guest-visible text, which is kaya's unit on the wire and in every
/// binding.
///
/// A TYPE RATHER THAN TWO INTS BECAUSE C# COUNTS SOMETHING ELSE: a .NET
/// string index counts UTF-16 code units, and the disagreement is
/// silent (docs/traps.md, "A range offset is a UTF-8 BYTE offset").
/// `In` does the conversion once, here.
///
/// WHAT THE CORE REFUSES, wherever a range reaches it: endpoints out of
/// order, an endpoint past the end of the text, or an endpoint inside a
/// character. A range that splits a GRAPHEME CLUSTER is accepted and
/// covers exactly the code points it names — the platforms disagree
/// about what a grapheme is (.NET's StringInfo counts the ZWJ family as
/// one cluster where java.text.BreakIterator counts eleven), so a
/// platform may widen what it PAINTS to the whole cluster.
readonly struct TextRange
{
    internal readonly ulong Start;
    internal readonly ulong Stop;

    TextRange(ulong start, ulong stop)
    {
        Start = start;
        Stop = stop;
    }

    /// The range covering `length` .NET chars from `index` — the
    /// conversion from C#'s unit into kaya's:
    ///
    ///     hits.Add(TextRange.In(doc, at, needle.Length));
    ///
    /// The text is an argument rather than remembered state: a byte
    /// offset means nothing without the string it indexes.
    public static TextRange In(string text, int index, int length)
    {
        if (text == null)
            throw new ArgumentNullException(
                nameof(text), "kaya: a range is measured against the text it indexes");
        if (index < 0 || length < 0 || index > text.Length - length)
            throw new ArgumentOutOfRangeException(
                nameof(index),
                $"kaya: range {index}..{index + (long)length} is outside a text of "
                    + $"{text.Length} chars");
        ulong start = ByteOffset(text, index);
        return new TextRange(start, start + Utf8Length(text, index, length));
    }

    /// Offsets that are ALREADY UTF-8 byte offsets — for an app whose
    /// positions came out of something byte-oriented rather than out of
    /// a .NET string.
    public static TextRange Bytes(long start, long stop)
    {
        if (start < 0 || stop < 0)
            throw new ArgumentOutOfRangeException(
                nameof(start), $"kaya: a text range offset is negative ({start}..{stop})");
        return new TextRange((ulong)start, (ulong)stop);
    }

    static ulong ByteOffset(string text, int at) =>
        Utf8Length(text, 0, at);

    static ulong Utf8Length(string text, int at, int length)
    {
        // A .NET INDEX INSIDE A SURROGATE PAIR is the one error the core
        // cannot name for the app, because by the time it arrives the
        // evidence is gone: System.Text.Encoding.UTF8 encodes the
        // orphaned half as U+FFFD, three bytes where the whole character
        // is four, so the offset that comes back points into the middle
        // of a character the app never meant to split. The core does
        // refuse it — its boundary clause cannot do otherwise — but it
        // refuses a number this method invented. Refuse the index
        // instead, in the unit the app was thinking in.
        Boundary(text, at);
        Boundary(text, at + length);
        return (ulong)System.Text.Encoding.UTF8.GetByteCount(text.AsSpan(at, length));
    }

    static void Boundary(string text, int at)
    {
        // BOTH HALVES, not just the low one: a lone low surrogate is
        // ill-formed text, which the FFI boundary already owns
        // (DESIGN.md, string observations), and testing only the low
        // half would make this very message throw — ConvertToUtf32
        // refuses the pair it was handed.
        if (at > 0 && at < text.Length
            && char.IsHighSurrogate(text[at - 1]) && char.IsLowSurrogate(text[at]))
            throw new ArgumentException(
                $"kaya: char index {at} is inside the surrogate pair at {at - 1}..{at + 1} "
                    + $"('{char.ConvertFromUtf32(char.ConvertToUtf32(text[at - 1], text[at]))}'), "
                    + "which is half a character");
    }
}

/// A template node: a blueprint entry, stamped per collection entry.
/// Never on screen by itself; clicks on its copies arrive with the
/// copy's key path.
readonly struct Node
{
    internal readonly ulong Id;

    internal Node(ulong id) => Id = id;
}

/// A collection instance handle: the collection plus the key path
/// selecting one stamped copy's table. Tx.Collection() returns the
/// root (empty-path, live-zone) handle; At steps into a copy, one key
/// per enclosing For.
readonly struct Collection
{
    internal readonly ulong Id;
    internal readonly object[] Path;

    internal Collection(ulong id, object[] path)
    {
        Id = id;
        Path = path;
    }

    /// The instance of this collection inside the copy keyed by
    /// `key` of the next enclosing For; chain for deeper nesting.
    public Collection At(object key)
    {
        var path = new object[Path.Length + 1];
        Path.CopyTo(path, 0);
        path[Path.Length] = key;
        return new Collection(Id, path);
    }

    /// A For binds the collection itself — its template stamps per
    /// entry of every instance — so handing it an At(...) handle is a
    /// bug. (A default-constructed handle has a null Path; both are
    /// rejected here.)
    internal void AssertRoot()
    {
        if (Path == null || Path.Length > 0)
            throw new InvalidOperationException(
                "kaya: ForEach binds the collection itself, not an instance — drop the At(...)");
    }
}

/// A live menu item. One command identity: exactly one parent or
/// anchor, forever (append-only; nothing is removed in v1). Reopen a
/// retained item with tx.Menu(item, ...).
readonly struct MenuItem
{
    internal readonly ulong Id;

    internal MenuItem(ulong id) => Id = id;
}

/// A context catalog built UNANCHORED (tx.ContextCatalog) for a
/// template node: the catalog is built in the live zone and
/// Tpl.ContextMenu attaches it inside the template. An item takes
/// exactly one anchor — a second attach throws.
sealed class ContextCatalog
{
    internal readonly MenuItem[] Roots;
    internal bool Attached;

    internal ContextCatalog(MenuItem[] roots) => Roots = roots;
}

/// One of the TWO addressable sources a menu text property binds to —
/// a constant or a signal (menu items are not collection elements, so
/// there is no element arm).
readonly struct TextSource
{
    internal readonly string Text;
    internal readonly Signal? Bind;

    TextSource(string text, Signal? bind)
    {
        Text = text;
        Bind = bind;
    }

    public static implicit operator TextSource(string text) => new(text, null);

    public static implicit operator TextSource(Signal s) => new(null, s);
}

/// The Bool twin of TextSource, for enabled/isChecked.
readonly struct BoolSource
{
    internal readonly bool Value;
    internal readonly Signal? Bind;

    BoolSource(bool value, Signal? bind)
    {
        Value = value;
        Bind = bind;
    }

    public static implicit operator BoolSource(bool value) => new(value, null);

    public static implicit operator BoolSource(Signal s) => new(false, s);
}

/// The index twin, for a radio group's value (a 0-based option
/// index under the Choice contract).
readonly struct IndexSource
{
    internal readonly double Value;
    internal readonly Signal? Bind;

    IndexSource(double value, Signal? bind)
    {
        Value = value;
        Bind = bind;
    }

    public static implicit operator IndexSource(int index) => new(index, null);

    public static implicit operator IndexSource(double index) => new(index, null);

    public static implicit operator IndexSource(Signal s) => new(0, s);
}

/// A container's cross-axis child placement. Baseline is rows-only —
/// the root rejects it on columns.
enum Align : long
{
    Start = 0,
    Center = 1,
    End = 2,
    Stretch = 3,
    Baseline = 4,
}

/// A container's arrangement axis (docs/adaptive-layout-plan.md D1/D2):
/// row and column are ONE node this parameterizes, and the prop is
/// mutable, so a breakpoint diff or a handler toggle is an ordinary
/// property write. A widget stays addressable by its CREATION kind
/// whatever the axis says today.
enum Axis : long
{
    Horizontal = KayaWire.AxisHorizontal,
    Vertical = KayaWire.AxisVertical,
}

/// SEMANTIC EMPHASIS (docs/styling-plan.md D4): what a widget MEANS,
/// never how it looks. Each variant belongs to one kind, and the root
/// refuses the misfits at declare time — which is why `role:` appears
/// on Button and Label alone and SetRole leans on that wall.
enum Role : long
{
    /// An action whose press destroys something.
    Destructive = KayaWire.RoleDestructive,
    /// THE primary action — the default-button treatment.
    Prominent = KayaWire.RoleProminent,
    /// A text hierarchy heading: the platform's heading text style AND
    /// the accessibility heading trait.
    Heading = KayaWire.RoleHeading,
    /// A heading's counterpart under the content it explains: the
    /// platform's caption/footnote text tier.
    Caption = KayaWire.RoleCaption,
}

/// THE SEMANTIC ICON VOCABULARY (docs/styling-plan.md D6, DESIGN.md
/// "Icons want names, not bytes"). An app names a CONCEPT and each
/// backend draws its own platform's glyph. The `icon:` byte[] argument
/// stays for app-specific art.
///
/// Growing the set is a spec change (D5), never a per-app escape hatch,
/// and the values are APPEND-ONLY: a new concept takes the next number,
/// because renumbering silently redraws every shipped app's menus.
enum Symbol : long
{
    Add = KayaWire.SymbolAdd,
    Remove = KayaWire.SymbolRemove,
    /// Destroying something, the wastebasket idiom — distinct from
    /// Remove, which takes an item out of a list.
    Delete = KayaWire.SymbolDelete,
    Edit = KayaWire.SymbolEdit,
    /// Confirmation, the checkmark idiom.
    Done = KayaWire.SymbolDone,
    /// Dismissal, the ✕ idiom — not Delete.
    Close = KayaWire.SymbolClose,
    Search = KayaWire.SymbolSearch,
    Settings = KayaWire.SymbolSettings,
    Refresh = KayaWire.SymbolRefresh,
    Info = KayaWire.SymbolInfo,
    Warning = KayaWire.SymbolWarning,
    /// The direction-relative pair: every platform mirrors these under
    /// a right-to-left layout, so they mean BACKWARD and FORWARD in
    /// reading order, never "left" and "right".
    Back = KayaWire.SymbolBack,
    Forward = KayaWire.SymbolForward,
    /// The overflow affordance (the ellipsis idiom).
    More = KayaWire.SymbolMore,
    Copy = KayaWire.SymbolCopy,
    Paste = KayaWire.SymbolPaste,
    /// Favourite.
    Star = KayaWire.SymbolStar,
    Lock = KayaWire.SymbolLock,
    /// A person or account.
    Person = KayaWire.SymbolPerson,
    Home = KayaWire.SymbolHome,
}

/// WHICH PLATFORM A PER-PLATFORM BRAND VALUE IS FOR (the spec's
/// `platform` enum; docs/styling-plan.md Slice 2b).
///
/// AN APP NAMES THESE, IT NEVER ASKS WHICH ONE IT IS. There is no
/// Platform.Current() and there will not be: every row travels to every
/// backend and each lowering picks its own.
enum Platform : long
{
    Mac = KayaWire.PlatformMac,
    Ios = KayaWire.PlatformIos,
    Linux = KayaWire.PlatformLinux,
    Windows = KayaWire.PlatformWindows,
    Android = KayaWire.PlatformAndroid,
}

sealed class KayaInstance
{
    internal readonly List<object> Path;
    internal List<KeyValuePair<object, object>> Entries = new();

    internal KayaInstance(IEnumerable<object> path) => Path = new List<object>(path);

    internal KayaInstance Clone() =>
        new(Path) { Entries = new List<KeyValuePair<object, object>>(Entries) };
}

/// WHAT THIS HOST CAN DO — crates/kaya/src/app.rs carries the canonical
/// note. Named booleans, never the bits.
///
/// CAPABILITIES INFORM; WALLS REFUSE: a false here is not what makes a
/// call illegal, it lets a guest ask before it walks into the wall.
///
/// AuxWindows: the host can materialize a surface beside the primary
/// one (Tx.CreateWindow, Tx.MountIn). False on iOS and Android, whose
/// systems own surface geometry; there CreateWindow aborts at the root.
readonly record struct Caps(bool AuxWindows);

/// <summary>The header bar's sort indicator (docs/tables-plan.md):
/// which column shows it, in which direction — the GUEST's
/// declaration, re-sent with the new state after it handles a sort
/// request. The platform never sorts; a header click only asks.</summary>
readonly struct Sort
{
    internal readonly uint Sorted;
    internal readonly uint Direction;

    Sort(uint sorted, uint direction) { Sorted = sorted; Direction = direction; }

    /// <summary>The no-indicator bar.</summary>
    public static Sort None => new(0xFFFF_FFFF, 0);

    /// <summary>Ascending on <paramref name="column"/> (0-based).</summary>
    public static Sort Asc(uint column) => new(column, 0);

    /// <summary>Descending on <paramref name="column"/>.</summary>
    public static Sort Desc(uint column) => new(column, 1);
}

/// <summary>A canvas's coordinate system AND its natural size in
/// device-independent points (docs/canvas-plan.md §3.2). The op stream is
/// written in these units on every platform and in every language, so a
/// scene can freeze it.</summary>
readonly struct Viewbox
{
    internal readonly double W;
    internal readonly double H;

    public Viewbox(double w, double h) { W = w; H = h; }
}

/// <summary>The paint ROLE an op names. Never RGB: the roles resolve in
/// the core per appearance (docs/canvas-plan.md §3.4).</summary>
enum Paint : long
{
    /// The line.
    Series = KayaWire.PaintSeries,
    /// The area under it.
    SeriesFill = KayaWire.PaintSeriesFill,
    /// Gridlines.
    Grid = KayaWire.PaintGrid,
    /// Axis lines and tick labels.
    Axis = KayaWire.PaintAxis,
    /// The plot background.
    Ground = KayaWire.PaintGround,
}

/// <summary>Which way a fill resolves its own crossings.</summary>
enum FillRule : long
{
    Nonzero = KayaWire.FillRuleNonzero,
    EvenOdd = KayaWire.FillRuleEvenOdd,
}

/// <summary>SVG's text-anchor: which end of the run sits at the anchor
/// point.</summary>
enum TextAlign : long
{
    Start = KayaWire.TextAlignStart,
    Middle = KayaWire.TextAlignMiddle,
    End = KayaWire.TextAlignEnd,
}

/// <summary>SVG's dominant-baseline: which horizontal line of the run
/// sits at the anchor point.</summary>
enum TextBaseline : long
{
    Alphabetic = KayaWire.TextBaselineAlphabetic,
    Middle = KayaWire.TextBaselineMiddle,
    Top = KayaWire.TextBaselineTop,
    Bottom = KayaWire.TextBaselineBottom,
}

/// <summary>The drawing scope's recorder. The calls read as
/// immediate-mode drawing; they are recorded, and ONE record is submitted
/// when the scope closes — the For template trace's fiction with a
/// drawing scope instead of a loop (docs/canvas-plan.md §2.1).</summary>
sealed class Draw
{
    internal readonly List<object> Ops = new();

    internal Draw(Viewbox viewbox) => Viewbox = viewbox;

    /// <summary>The box this drawing is written in, so a chart can
    /// compute its own extents without the app carrying the numbers
    /// twice.</summary>
    public Viewbox Viewbox { get; }

    Draw Op(long code, params object[] operands)
    {
        Ops.Add(code);
        Ops.AddRange(operands);
        return this;
    }

    /// <summary>Start a subpath at (x, y).</summary>
    public Draw MoveTo(double x, double y) => Op(KayaWire.DrawOpMoveTo, x, y);

    /// <summary>Extend the current subpath to (x, y).</summary>
    public Draw LineTo(double x, double y) => Op(KayaWire.DrawOpLineTo, x, y);

    /// <summary>Close the current subpath.</summary>
    public Draw Close() => Op(KayaWire.DrawOpClose);

    /// <summary>MoveTo the first point and LineTo the rest — the chart's
    /// own shape, spelled once.</summary>
    public Draw Polyline(IReadOnlyList<(double X, double Y)> points)
    {
        for (int i = 0; i < points.Count; i++)
        {
            if (i == 0) MoveTo(points[i].X, points[i].Y);
            else LineTo(points[i].X, points[i].Y);
        }
        return this;
    }

    /// <summary>Stroke the built path and clear it. `width` is in
    /// device-independent points and does NOT carry the viewbox stretch,
    /// so a 1pt gridline is 1pt at every canvas size (§3.2).</summary>
    public Draw Stroke(Paint paint, double width) =>
        Op(KayaWire.DrawOpStroke, (long)paint, width);

    /// <summary>Fill the built path and clear it.</summary>
    public Draw Fill(Paint paint, FillRule rule = FillRule.Nonzero) =>
        Op(KayaWire.DrawOpFill, (long)paint, (long)rule);

    /// <summary>Select the face for subsequent text ops. `asset` is an
    /// ordinary asset name; "" is kaya's own embedded default face, which
    /// is why a canvas can always draw text (§4.2). `size` is in
    /// device-independent points.</summary>
    public Draw Font(double size, string asset = "", long weight = 400) =>
        Op(KayaWire.DrawOpFont, asset, size, weight);

    /// <summary>Draw ONE LINE with its anchor at (x, y). A line break in
    /// `s` is refused by the core (§3.3).</summary>
    public Draw Text(double x, double y, string s, Paint paint,
        TextAlign align = TextAlign.Start,
        TextBaseline baseline = TextBaseline.Alphabetic) =>
        Op(KayaWire.DrawOpText, x, y, (long)paint, (long)align, (long)baseline, s);
}

sealed class KayaApp
{
    /// This host's capabilities. Constant for the life of the process,
    /// so asking once and remembering is fine.
    public static Caps Capabilities() =>
        new Caps((Kaya.CapabilityBits() & Kaya.CAP_AUX_WINDOWS) != 0);

    // Work handed over by other threads, waiting to run as transactions
    // on the app thread. THE ONLY STATE HERE TOUCHED FROM ANOTHER
    // THREAD, and the only reason this class carries a lock at all —
    // everything else is app-thread-only by construction.
    readonly object postLock = new object();
    List<Action<Tx>> posted = new List<Action<Tx>>();

    // Signals recomputed from a collection after each of its
    // mutations, written into the same transaction.
    internal readonly Dictionary<ulong, List<Action<Tx>>> Derived = new();

    // Each canvas's declared viewbox, so a redraw in a LATER transaction
    // does not have to repeat it (docs/canvas-plan.md §2.2).
    internal readonly Dictionary<ulong, Viewbox> CanvasViewboxes = new();

    // THE CANVAS'S DRAWING-AS-A-FUNCTION-OF-SIZE (docs/canvas-plan.md
    // §3.2.1), keyed by canvas widget id. Not a handler table like the
    // others: these produce a DRAWING rather than a model edit, so
    // DispatchLoop answers the ask itself and the guest never sees it.
    // ONE ARITY FOR BOTH POLICIES — the third argument is the frame's
    // time in seconds, 0 for a plain redraw — because a TICK canvas is
    // asked as a `draw_requested` once before its first frame, and the
    // handler that answers that ask is the tick one.
    readonly Dictionary<ulong, Action<Draw, Viewbox, double>> draws = new();

    // No `nodes`: template nodes draw from `widgets`, one sequence per
    // app (DESIGN.md, Binding conventions).
    ulong signals, widgets, collections, menuItems;
    readonly Dictionary<ulong, Action<Tx>> widgetHandlers = new();
    // Table sort requests, keyed by the For container's widget id
    // (docs/tables-plan.md): the handler receives the 0-based column.
    readonly Dictionary<ulong, Action<Tx, uint>> sortHandlers = new();
    // The same, keyed by a NESTED For's template node: one bar per
    // stamped copy, so the handler also receives that copy's key path.
    readonly Dictionary<ulong, Action<Tx, List<object>, uint>> nodeSorts = new();
    // Menu dispatch tables, keyed by MENU ITEM id — their own id space,
    // separate from every widget/node table. The node flavors receive
    // the stamped copy's key path.
    internal readonly Dictionary<ulong, Action<Tx>> menuActivated = new();
    internal readonly Dictionary<ulong, Action<Tx, List<object>>> menuActivatedNode = new();
    internal readonly Dictionary<ulong, Action<Tx, bool>> menuToggled = new();
    internal readonly Dictionary<ulong, Action<Tx, List<object>, bool>> menuToggledNode = new();
    internal readonly Dictionary<ulong, Action<Tx, int>> menuSelected = new();
    internal readonly Dictionary<ulong, Action<Tx, List<object>, int>> menuSelectedNode = new();
    readonly Dictionary<ulong, Action<Tx, List<object>>> nodeHandlers = new();
    readonly Dictionary<ulong, Action<Tx, string>> widgetChanges = new();
    readonly Dictionary<ulong, Action<Tx, List<object>, string>> nodeChanges = new();
    readonly Dictionary<ulong, Action<Tx, bool>> widgetToggles = new();
    readonly Dictionary<ulong, Action<Tx, double>> widgetValues = new();
    readonly Dictionary<ulong, Action<Tx, List<object>, bool>> nodeToggles = new();
    readonly Dictionary<ulong, Action<Tx, List<object>, double>> nodeValues = new();
    // Window lifecycle: one handler each, receiving the window id.
    internal readonly Dictionary<ulong, Action<Tx>> closeRequested = new();
    internal readonly Dictionary<ulong, Action<Tx>> entryPopped = new();
    internal readonly Dictionary<ulong, Action<Tx>> backRequested = new();
    internal readonly Dictionary<ulong, Action<Tx>> sectionSelected = new();
    internal readonly Dictionary<ulong, Action<Tx>> windowClosed = new();
    // The ledger's two reports, keyed by WINDOW because the ledger is
    // (docs/undo-plan.md §3). NOT one-shot, unlike the alert's table: a
    // history is walked as often as the user likes.
    internal readonly Dictionary<ulong, Action<Tx, string, UndoDelta>> undone = new();
    internal readonly Dictionary<ulong, Action<Tx, string, UndoDelta>> redone = new();
    internal readonly Dictionary<ulong, Action<Tx, uint>> alerts = new();
    // BOTH DIALOG KINDS LIVE HERE: a save request answers on the
    // picker's grammar out of the picker's id space (docs/save-plan.md
    // D2), narrowed to "one or none" at Tx.SaveFile.
    internal readonly Dictionary<ulong, Action<Tx, List<PickedFile>>> fileDialogs = new();
    // Clipboard reads share the alert's request/result grammar: one-shot,
    // keyed by request id.
    internal readonly Dictionary<ulong, Action<Tx, Representation?>> clipboardReads = new();
    internal readonly Dictionary<ulong, Action<Tx, Representation>> widgetPastes = new();
    internal readonly Dictionary<ulong, Action<Tx, List<object>, Representation>> nodePastes = new();
    internal ulong nextAlert;
    internal ulong nextFileDialog;
    internal ulong nextClipboardRead;

    // The collection is the model — the only copy: every mutation op
    // edits it and queues the wire delta in the same call. Children
    // records the declared-inside-a-For edges the model purges along
    // when a parent entry's copy is torn down.
    internal readonly Dictionary<ulong, List<KayaInstance>> Model = new();
    // The fresh-key minter's counters, one per collection INSTANCE —
    // keyed by (collection, PATH), because an instance is a table and
    // keys are unique within one. OUTSIDE the rollback journal on
    // purpose: a minted key is spent, so an abandoned transaction leaves
    // the counter where it is and no key is handed out twice
    // (docs/fresh-key-plan.md).
    readonly Dictionary<ulong, List<(List<object> Path, long Counter)>> fresh = new();
    // How to turn one collection's WIRE fields back into the object the
    // model keeps, per collection id. Registered where the type is known
    // (KayaRecords.CollectionOf, KayaSums.SumOf, the scalar
    // Tx.Collection), because only an undo travels this direction.
    internal readonly Dictionary<ulong, Func<uint, List<object>, object, object>> Rehydrate = new();
    // The ambient app/tx pair exists because the comparison operators
    // are static and a Signal is only an id (one app per guest process).
    internal static KayaApp Ambient;
    internal Tx CurrentTx;
    internal readonly Dictionary<ulong, object> SignalMirrors = new();
    internal readonly Dictionary<ulong, List<Action<Tx>>> SignalDeps = new();
    // The ambient parent stack: containers push their id around their
    // body, constructors parent to the top, and 0 is the template-root
    // sentinel.
    internal readonly List<ulong> Parents = new();
    internal readonly Dictionary<ulong, List<ulong>> Children = new();
    internal readonly List<ulong> OpenFors = new();
    // >0 while a template body is being declared (a For body, a When
    // body, or an open row trace); OpenFors tracks Fors only. The
    // template records once and replays, so a model read inside its body
    // would bake one snapshot into every stamp — mirror reads throw
    // while this is armed; live-zone, handler and build reads stay legal.
    internal int TplDepth;

    public KayaApp()
    {
        Ambient = this;
        Kaya.Init();
    }

    internal Signal NextSignal() => new(++signals);

    internal Widget NextWidget() => new(++widgets);

    internal MenuItem NextMenuItem() => new(++menuItems);

    internal Node NextNode() => new(++widgets);

    internal Collection NextCollection() => new(++collections, Array.Empty<object>());

    /// A collection declared inside a For's template is torn down with
    /// its copies: record the edge so the model purges along it.
    internal void RegisterCollection(ulong id)
    {
        if (OpenFors.Count == 0)
            return;
        ulong parent = OpenFors[^1];
        if (!Children.TryGetValue(parent, out var kids))
            Children[parent] = kids = new List<ulong>();
        kids.Add(id);
    }

    internal static bool PathEq(IReadOnlyList<object> a, IReadOnlyList<object> b, int len)
    {
        if (a.Count < len || b.Count < len)
            return false;
        for (int i = 0; i < len; i++)
            if (!Equals(a[i], b[i]))
                return false;
        return true;
    }

    internal KayaInstance InstanceOf(ulong coll, IReadOnlyList<object> path)
    {
        if (!Model.TryGetValue(coll, out var instances))
            return null;
        foreach (var instance in instances)
            if (instance.Path.Count == path.Count && PathEq(instance.Path, path, path.Count))
                return instance;
        return null;
    }

    /// One instance's fresh-key counter, made if this is the first
    /// anyone has asked. A List entry is a value tuple, so the new count
    /// is written back rather than mutated through the indexer.
    long WithCounter(ulong coll, IReadOnlyList<object> path, Func<long, long> body)
    {
        if (!fresh.TryGetValue(coll, out var instances))
            fresh[coll] = instances = new List<(List<object>, long)>();
        int at = instances.FindIndex(i =>
            i.Path.Count == path.Count && PathEq(i.Path, path, path.Count));
        if (at < 0)
        {
            instances.Add((new List<object>(path), 0));
            at = instances.Count - 1;
        }
        long next = body(instances[at].Counter);
        instances[at] = (instances[at].Path, next);
        return next;
    }

    /// The next fresh key for one instance: counter+1, and the counter
    /// keeps it. Monotonic by construction — nothing else writes it
    /// downwards (see Tx.InsertFresh).
    internal long MintKey(ulong coll, IReadOnlyList<object> path) =>
        WithCounter(coll, path, counter => counter + 1);

    /// An explicit key, shown to the minter on its way into the table.
    /// A numeric key at or above the counter carries it up so the next
    /// mint clears it; anything else moves nothing, having no way to
    /// collide with an I64.
    ///
    /// BOTH C# INTEGER SPELLINGS COUNT. KayaWire.Encode widens an int
    /// to the wire's I64, so `Insert(c, 5, ...)` and `Insert(c, 5L, ...)`
    /// name the same entry to the core — while the mirror compares keys
    /// with Equals, where 5 and 5L differ. So the int is absorbed too.
    internal void AbsorbKey(ulong coll, IReadOnlyList<object> path, object key)
    {
        long n;
        if (key is long l)
            n = l;
        else if (key is int i)
            n = i;
        else
            return;
        WithCounter(coll, path, counter => counter > n ? counter : n);
    }

    /// Fold an undo's payload into the mirrors.
    ///
    /// The payload is core-authoritative, so nothing here re-derives
    /// anything.
    ///
    /// NO DERIVED RECOMPUTE, deliberately. A derived signal's write rode
    /// the same transaction as the mutation that caused it, so the core
    /// restored it too — recomputing here would write a value the ledger
    /// never banked, outside any transaction.
    internal void AbsorbUndo(UndoDelta delta)
    {
        foreach (var signal in delta.Signals)
            SignalMirrors[signal.Signal] = signal.Value;
        foreach (var entry in delta.Entries)
        {
            if (!Model.TryGetValue(entry.Collection, out var instances))
                Model[entry.Collection] = instances = new List<KayaInstance>();
            var instance = InstanceOf(entry.Collection, entry.Path);
            if (instance == null)
                instances.Add(instance = new KayaInstance(entry.Path));
            int at = instance.Entries.FindIndex(e => Equals(e.Key, entry.Key));
            if (entry.State is { } state)
            {
                object current = at >= 0 ? instance.Entries[at].Value : null;
                object value =
                    Rehydrate.TryGetValue(entry.Collection, out var rehydrate)
                        ? rehydrate(state.Variant, state.Fields, current)
                        : (state.Fields.Count > 0 ? state.Fields[0] : null);
                var pair = new KeyValuePair<object, object>(entry.Key, value);
                if (at >= 0)
                    instance.Entries[at] = pair;
                else
                    instance.Entries.Add(pair);
            }
            else if (at >= 0)
            {
                instance.Entries.RemoveAt(at);
            }
        }
        foreach (var order in delta.Orders)
        {
            var instance = InstanceOf(order.Collection, order.Path);
            if (instance == null)
                continue;
            // Position by the payload's list, keeping anything it does
            // not name at the end.
            var sorted = new List<KeyValuePair<object, object>>(instance.Entries.Count);
            foreach (var key in order.Keys)
            {
                int at = instance.Entries.FindIndex(e => Equals(e.Key, key));
                if (at < 0)
                    continue;
                sorted.Add(instance.Entries[at]);
                instance.Entries.RemoveAt(at);
            }
            sorted.AddRange(instance.Entries);
            instance.Entries = sorted;
        }
    }

    /// Run `build` with a fresh transaction and submit it atomically. A
    /// handler that throws abandons its records, and the model abandons
    /// the same writes before the exception continues.
    public void Build(Action<Tx> build)
    {
        RequireAppThread();
        var tx = new Tx(this);
        CurrentTx = tx;
        try
        {
            build(tx);
        }
        catch
        {
            tx.Rollback();
            tx.Close();
            throw;
        }
        finally
        {
            CurrentTx = null;
        }
        tx.SubmitIfAny();
        tx.Close();
    }

    public void OnClick(Widget w, Action<Tx> handler) => widgetHandlers[w.Id] = handler;

    /// <summary>Register the table's header-click handler at its For —
    /// the handler receives the 0-based column of a sort REQUEST:
    /// nothing has changed on screen; reorder the collection by key and
    /// re-declare the header with Columns (docs/tables-plan.md).</summary>
    public void OnSort(Widget w, Action<Tx, uint> handler) => sortHandlers[w.Id] = handler;

    /// <summary>The nested table's header-click handler, registered at
    /// the For's template node: every stamped copy has its own bar, so
    /// the handler receives that copy's keys, outermost first, and then
    /// the 0-based column. Re-declare THAT copy's indicator with
    /// tx.Columns(node, keys, ...) (docs/tables-plan.md).</summary>
    public void OnSort(Node n, Action<Tx, List<object>, uint> handler) =>
        nodeSorts[n.Id] = handler;

    /// Register a click handler for a template node; it also receives
    /// the stamped copy's keys, outermost first.
    public void OnClick(Node n, Action<Tx, List<object>> handler) => nodeHandlers[n.Id] = handler;

    /// Register a change handler for a live entry: the widget owns its
    /// text and reports each edit here. There is no read-back.
    public void OnChange(Widget w, Action<Tx, string> handler) => widgetChanges[w.Id] = handler;

    /// Register a change handler for a template entry; it also receives
    /// the stamped copy's keys, outermost first.
    public void OnChange(Node n, Action<Tx, List<object>, string> handler) =>
        nodeChanges[n.Id] = handler;

    /// Register a toggle handler for a live checkbox: the box owns its
    /// checked bit and reports each flip here.
    public void OnToggle(Widget w, Action<Tx, bool> handler) => widgetToggles[w.Id] = handler;

    /// A live slider's change handler: the bar owns its position and
    /// reports each move with the new value.
    public void OnValueChanged(Widget w, Action<Tx, double> handler) =>
        widgetValues[w.Id] = handler;

    /// Register a toggle handler for a template checkbox; it also
    /// receives the stamped copy's keys, outermost first.
    public void OnToggle(Node n, Action<Tx, List<object>, bool> handler) =>
        nodeToggles[n.Id] = handler;

    /// A template slider's or choice widget's change handler; it also
    /// receives the stamped copy's keys, outermost first.
    public void OnValueChanged(Node n, Action<Tx, List<object>, double> handler) =>
        nodeValues[n.Id] = handler;

    /// The open transaction, reached ambiently by the chained canvas
    /// declarations (Widget.Fixed, OnDraw, OnTick) — Signal.Derive's route
    /// and for the same reason: the handle is an id alone.
    internal static Tx AmbientTx(string what) =>
        Ambient?.CurrentTx ?? throw new InvalidOperationException(
            $"kaya: {what} is a declaration and belongs inside a transaction "
            + "(a build or a handler)");

    /// The registration half of Widget.OnDraw and Widget.OnTick. NOT
    /// PUBLIC on purpose: registering the handler and declaring the policy
    /// are ONE act, and a guest that could do the first without the second
    /// would hold a handler nothing ever calls (docs/canvas-plan.md
    /// §3.2.1).
    internal void RegisterDraw(Widget canvas, Action<Draw, Viewbox, double> f) =>
        draws[canvas.Id] = f;

    /// One handler dispatch: an exception crosses the Build boundary
    /// (which rolled the mirrors back and dropped the records), is
    /// logged, and the loop moves to the next occurrence. Fatal runtime
    /// errors (stack overflow, access violation) still die.
    void Dispatch(Action<Tx> fn)
    {
        try
        {
            Build(fn);
        }
        catch (Exception e)
        {
            Console.Error.WriteLine(
                $"kaya: handler threw (transaction rolled back): {e}");
        }
    }

    /// Run body as a transaction on the app thread, soon. THE ONE method
    /// safe to call from another thread:
    ///
    ///     _ = Task.Run(() => {
    ///         var data = File.ReadAllText(path);   // blocks this thread
    ///         app.Post(tx => tx.Write(content, data));
    ///     });
    ///
    /// The Tx is made where it is used and never crosses a thread; ids
    /// are values and are meant to be captured. A posted body runs in
    /// its OWN transaction, after whatever is running now, so posting
    /// from inside a handler queues for after, never nests.
    public void Post(Action<Tx> body)
    {
        lock (postLock) posted.Add(body);
        // The app thread may be parked in C waiting on the ring. Posted
        // work never enters that ring, so this is the only way it hears
        // about it.
        Kaya.Wake();
    }

    /// Run everything posted, each as its own transaction, in order. The
    /// batch is taken and the lock released BEFORE any of it runs, so a
    /// body that posts again lands in the NEXT batch — holding the lock
    /// across the calls would let a self-posting body starve the
    /// occurrence loop.
    internal void DrainPosted()
    {
        List<Action<Tx>> batch;
        lock (postLock)
        {
            batch = posted;
            posted = new List<Action<Tx>>();
        }
        foreach (var body in batch)
            Dispatch(tx => body(tx));
    }

    // The app thread, claimed by the dispatch loop and read at every
    // transaction gate (RequireAppThread). 0 until then, which is what
    // lets the guest's opening Build run on the main thread before Run —
    // Python's `_app_thread = None` arm, same rule.
    static int appThread;

    /// Called by the dispatch loop on the way in: from here on that
    /// thread IS the app thread.
    internal static void ClaimAppThread() => appThread = Thread.CurrentThread.ManagedThreadId;

    /// The other half of the rule Tx.Alive states: OPEN is not enough, a
    /// transaction also belongs to the app thread. `closed` cannot see a
    /// Task continuation writing through a transaction that is still
    /// open, nor a background Build opening one of its own — both race
    /// the app thread's model. tools/check-tx-liveness.sh holds it.
    internal static void RequireAppThread()
    {
        int owner = appThread;
        if (owner == 0)
            return;
        int here = Thread.CurrentThread.ManagedThreadId;
        if (here != owner)
            throw new InvalidOperationException(
                $"kaya: a transaction belongs to the app thread — this is thread {here}, "
                    + $"the app thread is {owner}. To mutate from a background thread use "
                    + "App.Post, which runs your function as a transaction over there.");
    }

    /// Answer one canvas ask inside the binding's own transaction: the
    /// ASSIGNED SIZE becomes this canvas's viewbox — so a later plain
    /// Tx.Draw uses it too — and exactly one drawing goes back for it.
    void AnswerCanvasAsk(
        Tx tx, ulong canvas, Action<Draw, Viewbox, double> f, List<object> ask)
    {
        var size = new Viewbox(AskNumber(ask, 0), AskNumber(ask, 1));
        // A `draw_requested` carries no time, and a TICK canvas is handed
        // one of those before its first frame: that frame is time 0.
        double time = ask.Count > 2 ? AskNumber(ask, 2) : 0.0;
        CanvasViewboxes[canvas] = size;
        tx.Draw(new Widget(canvas), d => f(d, size, time));
    }

    /// One value out of the ask's bare tail. A refusal rather than a
    /// silent zero: the tail is f64 by construction
    /// (crates/kaya/src/protocol.rs), so any other shape means the wire
    /// moved under this arm — Dispatch logs the throw and rolls back.
    static double AskNumber(List<object> ask, int at)
    {
        if (at < ask.Count && ask[at] is double d)
            return d;
        string got = at < ask.Count ? ask[at]?.GetType().Name ?? "null" : "absent";
        throw new InvalidOperationException(
            "kaya: a canvas ask carries width, height (and a tick's time) as f64 — "
                + $"value {at} of {ask.Count} is {got}");
    }

    void DispatchLoop()
    {
        ClaimAppThread();
        while (true)
        {
            // Posted work first, then the ring, then park. Draining at
            // the TOP is what makes a wake sufficient: whatever brought
            // this thread back, it looks here before anywhere else.
            DrainPosted();
            if (!Kaya.PollOccurrence(
                out ushort kind, out ulong id, out List<object> keys, out object payload))
            {
                if (!Kaya.WaitOccurrences()) return; // shutdown
                continue;
            }
            string text = payload as string;
            bool isChecked = payload is bool b && b;
            // THE CANVAS'S TWO ASKS ARE ANSWERED HERE AND NEVER HANDED
            // OVER (docs/canvas-plan.md §3.2.1): the guest registered a
            // drawing-as-a-function-of-size, so this draws it, submits the
            // one record and keeps looping. No registration means DROP,
            // like any unclaimed occurrence.
            //
            // AN EMPTY KEY PATH IS THE WHOLE RULE HERE: the size policy is
            // a live-zone declaration in this slice and the core refuses
            // one against a template node by name, so no stamped copy is
            // ever asked (docs/deferred.md, THE TEMPLATE ZONE IS REFUSED).
            if ((kind == KayaWire.OccKindDrawRequested || kind == KayaWire.OccKindTick)
                && keys.Count == 0)
            {
                if (draws.TryGetValue(id, out var draw))
                {
                    var ask = payload as List<object> ?? new List<object>();
                    Dispatch(tx => AnswerCanvasAsk(tx, id, draw, ask));
                }
            }
            else if (kind == KayaWire.OccKindSortRequested && keys.Count == 0)
            {
                uint column = payload is uint u ? u : 0;
                if (sortHandlers.TryGetValue(id, out var fn))
                    Dispatch(tx => fn(tx, column));
            }
            else if (kind == KayaWire.OccKindSortRequested)
            {
                uint column = payload is uint u ? u : 0;
                if (nodeSorts.TryGetValue(id, out var fn))
                    Dispatch(tx => fn(tx, keys, column));
            }
            else if (kind == KayaWire.OccKindButtonClicked && keys.Count == 0)
            {
                if (widgetHandlers.TryGetValue(id, out var fn))
                    Dispatch(fn);
            }
            else if (kind == KayaWire.OccKindButtonClicked)
            {
                if (nodeHandlers.TryGetValue(id, out var fn))
                    Dispatch(tx => fn(tx, keys));
            }
            else if (kind == KayaWire.OccKindTextChanged && keys.Count == 0)
            {
                if (widgetChanges.TryGetValue(id, out var fn))
                    Dispatch(tx => fn(tx, text));
            }
            else if (kind == KayaWire.OccKindTextChanged)
            {
                if (nodeChanges.TryGetValue(id, out var fn))
                    Dispatch(tx => fn(tx, keys, text));
            }
            else if (kind == KayaWire.OccKindToggled && keys.Count == 0)
            {
                if (widgetToggles.TryGetValue(id, out var fn))
                    Dispatch(tx => fn(tx, isChecked));
            }
            else if (kind == KayaWire.OccKindToggled)
            {
                if (nodeToggles.TryGetValue(id, out var fn))
                    Dispatch(tx => fn(tx, keys, isChecked));
            }
            else if (kind == KayaWire.OccKindValueChanged && keys.Count == 0)
            {
                if (widgetValues.TryGetValue(id, out var fn))
                    Dispatch(tx => fn(tx, payload is double d ? d : 0.0));
            }
            else if (kind == KayaWire.OccKindValueChanged)
            {
                if (nodeValues.TryGetValue(id, out var fn))
                    Dispatch(tx => fn(tx, keys, payload is double d ? d : 0.0));
            }
            else if (kind == KayaWire.OccKindCloseRequested)
            {
                if (closeRequested.TryGetValue(id, out var fn))
                    Dispatch(tx => fn(tx));
            }
            else if (kind == KayaWire.OccKindWindowClosed)
            {
                // One-shot: the window is gone; both registrations
                // retire with it.
                closeRequested.Remove(id);
                if (windowClosed.Remove(id, out var fn))
                    Dispatch(tx => fn(tx));
            }
            else if (kind == KayaWire.OccKindSectionSelected)
            {
                // NOT one-shot: sections never die, and the user can
                // return any number of times (id is the section; the
                // window rides as the payload). A programmatic
                // SelectSection never lands here (the echo doctrine).
                if (sectionSelected.TryGetValue(id, out var fn))
                    Dispatch(fn);
            }
            else if (kind == KayaWire.OccKindEntryPopped)
            {
                // One-shot: the entry is gone; both registrations
                // retire with it.
                backRequested.Remove(id);
                if (entryPopped.Remove(id, out var fn))
                    Dispatch(tx => fn(tx));
            }
            else if (kind == KayaWire.OccKindBackRequested)
            {
                if (backRequested.TryGetValue(id, out var fn))
                    Dispatch(tx => fn(tx));
            }
            else if (kind == KayaWire.OccKindAlertResult)
            {
                // One-shot: the registration retires with the result;
                // payload is the parsed u32 choice.
                if (alerts.Remove(id, out var fn))
                    Dispatch(tx => fn(tx, payload is uint c ? c : 0));
            }
            else if (kind == KayaWire.OccKindFileDialogResult)
            {
                // One-shot like the alert, and the id retires with it.
                // EMPTY IS CANCEL, for a save dialog too (it reaches the
                // guest as null, narrowed at SaveFile).
                if (fileDialogs.Remove(id, out var fn))
                {
                    var files = payload as List<PickedFile> ?? new List<PickedFile>();
                    Dispatch(tx => fn(tx, files));
                }
            }
            else if (kind == KayaWire.OccKindClipboardResult)
            {
                // One-shot like the alert, and the request retires with
                // it. EMPTY IS THE UNIVERSAL NO and arrives as null —
                // denied, unfocused, absent and nothing-we-accept alike,
                // because no platform says which.
                if (clipboardReads.Remove(id, out var fn))
                {
                    var clip = Representation.From(payload as KayaWire.ClipValues);
                    Dispatch(tx => fn(tx, clip));
                }
            }
            // An undo (or redo), as the CORE put it back. The id is the
            // WINDOW: one ledger per window.
            //
            // THE MIRROR FOLLOWS FIRST, and unconditionally — before the
            // handler lookup, so a window that registered no handler
            // still keeps its mirror in step.
            else if (kind == KayaWire.OccKindUndone || kind == KayaWire.OccKindRedone)
            {
                var step = (UndoStep)payload;
                AbsorbUndo(step.Delta);
                var table = kind == KayaWire.OccKindUndone ? undone : redone;
                // NOT one-shot: a history is walked as often as the user
                // likes, so the registration outlives every step.
                if (table.TryGetValue(id, out var fn))
                    Dispatch(tx => fn(tx, step.Label, step.Delta));
            }
            // A paste rides a click tag verbatim, so it arrives on the
            // ordinary widget/node split. Never empty: a paste that
            // delivered nothing is not an occurrence.
            else if (kind == KayaWire.OccKindPasted && keys.Count == 0)
            {
                if (widgetPastes.TryGetValue(id, out var fn)
                    && Representation.From(payload as KayaWire.ClipValues) is { } clip)
                    Dispatch(tx => fn(tx, clip));
            }
            else if (kind == KayaWire.OccKindPasted)
            {
                if (nodePastes.TryGetValue(id, out var fn)
                    && Representation.From(payload as KayaWire.ClipValues) is { } clip)
                    Dispatch(tx => fn(tx, keys, clip));
            }
            // Menu occurrences key the menu-item tables — their own id
            // space. Node-anchored context items carry the stamped
            // copy's keys; toggles carry the new state, radio groups the
            // new 0-based index.
            else if (kind == KayaWire.OccKindMenuActivated && keys.Count == 0)
            {
                if (menuActivated.TryGetValue(id, out var fn))
                    Dispatch(fn);
            }
            else if (kind == KayaWire.OccKindMenuActivated)
            {
                if (menuActivatedNode.TryGetValue(id, out var fn))
                    Dispatch(tx => fn(tx, keys));
            }
            else if (kind == KayaWire.OccKindMenuToggled && keys.Count == 0)
            {
                if (menuToggled.TryGetValue(id, out var fn))
                    Dispatch(tx => fn(tx, isChecked));
            }
            else if (kind == KayaWire.OccKindMenuToggled)
            {
                if (menuToggledNode.TryGetValue(id, out var fn))
                    Dispatch(tx => fn(tx, keys, isChecked));
            }
            else if (kind == KayaWire.OccKindMenuValueChanged && keys.Count == 0)
            {
                if (menuSelected.TryGetValue(id, out var fn))
                    Dispatch(tx => fn(tx, payload is double d ? (int)d : 0));
            }
            else if (kind == KayaWire.OccKindMenuValueChanged)
            {
                if (menuSelectedNode.TryGetValue(id, out var fn))
                    Dispatch(tx => fn(tx, keys, payload is double d ? (int)d : 0));
            }
        }
    }



    /// Enter the core on the calling thread (must be the process main
    /// thread), dispatching occurrences on the app thread; returns the
    /// exit code.
    public int Run()
    {
        var appThread = new Thread(DispatchLoop);
        appThread.Start();
        int code = Kaya.Run();
        appThread.Join();
        return code;
    }
}

/// One transaction: everything queued inside Build (or a handler)
/// applies atomically when it returns.
sealed class Tx
{
    internal readonly KayaApp App;

    // THE ONE CHOKEPOINT. Every write in this file is `Records.Add(...)`,
    // so the property checks liveness first and guards the next callsite
    // too. A write through a Tx that outlived its Build vanishes with no
    // error, which is why a check spread over callsites will not do
    // (tools/check-tx-liveness.sh).
    readonly List<byte[]> records = new();
    internal List<byte[]> Records
    {
        get
        {
            Alive();
            return records;
        }
    }

    // Set when Build finishes with this transaction, committed or not.
    bool closed;

    /// A Tx is valid ONLY inside the Build or handler that made it, on
    /// the app thread. To mutate from anywhere else, post.
    internal void Alive()
    {
        if (closed)
            throw new InvalidOperationException(
                "kaya: transaction is over — a Tx is only usable inside the Build or "
                    + "handler that created it; to mutate from a background thread use App.Post");
        KayaApp.RequireAppThread();
    }

    /// Called by Build on the way out, on every path.
    internal void Close() => closed = true;

    // How to undo this transaction's model edits: a snapshot per
    // touched collection, taken on first touch.
    readonly Dictionary<ulong, List<KayaInstance>> journal = new();

    // Deriveds registered in this transaction: promoted to the app
    // registry on submit, abandoned with a rolled-back Tx (their
    // signals were never created).
    readonly List<(ulong Coll, Action<Tx> Recompute)> pendingDerived = new();

    // Signal-derived twins of the above, keyed by the source signal,
    // plus the mirror journal (what to restore on rollback; absent =
    // the mirror was created this transaction).
    readonly List<(ulong Source, Action<Tx> Recompute)> pendingSignalDeps = new();
    readonly Dictionary<ulong, (bool Existed, object Old)> signalJournal = new();

    internal Tx(KayaApp app) => App = app;

    internal void SubmitIfAny()
    {
        foreach (var (coll, recompute) in pendingDerived)
        {
            if (!App.Derived.TryGetValue(coll, out var list))
                App.Derived[coll] = list = new List<Action<Tx>>();
            list.Add(recompute);
        }
        pendingDerived.Clear();
        foreach (var (source, recompute) in pendingSignalDeps)
        {
            if (!App.SignalDeps.TryGetValue(source, out var list))
                App.SignalDeps[source] = list = new List<Action<Tx>>();
            list.Add(recompute);
        }
        pendingSignalDeps.Clear();
        // `records` and not `Records`: the submit is the transaction's
        // own last act, and routing it through the liveness property
        // would make the guard trip on the very call that closes it.
        if (records.Count > 0)
            Kaya.Submit(records.ToArray());
    }

    internal void Rollback()
    {
        // The template-scope counter is app state, not tx state: an
        // aborted build is abandoned but the app continues, and a
        // stuck counter would poison every later mirror read.
        App.TplDepth = 0;
        foreach (var (id, snapshot) in journal)
            App.Model[id] = snapshot;
        foreach (var (id, (existed, old)) in signalJournal)
        {
            if (existed)
                App.SignalMirrors[id] = old;
            else
                App.SignalMirrors.Remove(id);
        }
    }

    internal void RegisterSignalDep(ulong source, Action<Tx> recompute) =>
        pendingSignalDeps.Add((source, recompute));

    void TouchSignal(ulong id)
    {
        if (!signalJournal.ContainsKey(id))
            signalJournal[id] = App.SignalMirrors.TryGetValue(id, out var old)
                ? (true, old)
                : (false, null);
    }

    void Touch(ulong coll)
    {
        if (journal.ContainsKey(coll))
            return;
        var snapshot = new List<KayaInstance>();
        if (App.Model.TryGetValue(coll, out var instances))
            foreach (var instance in instances)
                snapshot.Add(instance.Clone());
        journal[coll] = snapshot;
    }

    void ModelSet(ulong coll, IReadOnlyList<object> path, object key, object value)
    {
        Touch(coll);
        var instance = App.InstanceOf(coll, path);
        if (instance == null)
        {
            instance = new KayaInstance(path);
            if (!App.Model.TryGetValue(coll, out var instances))
                App.Model[coll] = instances = new List<KayaInstance>();
            instances.Add(instance);
        }
        for (int i = 0; i < instance.Entries.Count; i++)
        {
            if (Equals(instance.Entries[i].Key, key))
            {
                instance.Entries[i] = new KeyValuePair<object, object>(key, value);
                return;
            }
        }
        instance.Entries.Add(new KeyValuePair<object, object>(key, value));
    }

    void ModelRemove(ulong coll, IReadOnlyList<object> path, object key)
    {
        Touch(coll);
        var instance = App.InstanceOf(coll, path);
        instance?.Entries.RemoveAll(e => Equals(e.Key, key));
        // The core tears down the copy, taking descendant collection
        // instances with it; the model follows.
        var prefix = new List<object>(path) { key };
        PurgeChildren(coll, prefix);
    }

    void ModelMove(ulong coll, IReadOnlyList<object> path, object key, object[] before)
    {
        Touch(coll);
        var instance = App.InstanceOf(coll, path);
        // Both validated before anything mutates.
        int pos = instance == null ? -1 : instance.Entries.FindIndex(e => Equals(e.Key, key));
        if (pos < 0)
            throw new InvalidOperationException($"kaya: move of missing key {key}");
        if (before.Length > 0 && !instance.Entries.Exists(e => Equals(e.Key, before[0])))
            throw new InvalidOperationException($"kaya: move before missing key {before[0]}");
        var entry = instance.Entries[pos];
        instance.Entries.RemoveAt(pos);
        int at = before.Length > 0
            ? instance.Entries.FindIndex(e => Equals(e.Key, before[0]))
            : instance.Entries.Count;
        instance.Entries.Insert(at, entry);
    }

    List<object> KeysOf(Collection c)
    {
        var keys = new List<object>();
        var instance = App.InstanceOf(c.Id, c.Path);
        if (instance != null)
            foreach (var entry in instance.Entries)
                keys.Add(entry.Key);
        return keys;
    }

    void PurgeChildren(ulong coll, IReadOnlyList<object> prefix)
    {
        if (!App.Children.TryGetValue(coll, out var kids))
            return;
        foreach (ulong kid in kids)
        {
            Touch(kid);
            if (App.Model.TryGetValue(kid, out var instances))
                instances.RemoveAll(i => KayaApp.PathEq(i.Path, prefix, prefix.Count));
            PurgeChildren(kid, prefix);
        }
    }

    // Set by Undoable: one name per step. A flag because the marker is
    // opaque bytes by then.
    bool undoGroup;

    /// Make this transaction ONE undoable step, under `label`. Opt-in
    /// per transaction (docs/undo-plan.md D2, D8).
    ///
    /// CALLABLE ANYWHERE IN THE CHAIN, and the marker still rides at the
    /// head of the batch.
    ///
    /// WHAT A GROUP MAY HOLD is the reactive half — signal writes and
    /// collection deltas. Focus is permitted and not restored. Anything
    /// else (a const property write, creating a widget, Clear, showing a
    /// dialog) fails at apply, naming the op.
    public void Undoable(string label) => UndoableIn(0, label);

    /// Undoable against an auxiliary window's ledger: each window has
    /// its own history.
    public void UndoableIn(ulong window, string label)
    {
        if (undoGroup)
            throw new InvalidOperationException(
                "kaya: this transaction is already an undo group — one name per step");
        undoGroup = true;
        Records.Insert(0, KayaWire.TxUndoGroup(window, label));
    }

    public Signal Signal(object initial)
    {
        var s = App.NextSignal();
        Records.Add(KayaWire.TxCreateSignal(s.Id, initial));
        TouchSignal(s.Id);
        App.SignalMirrors[s.Id] = initial;
        return s;
    }

    public void Write(Signal s, object value)
    {
        TouchSignal(s.Id);
        Records.Add(KayaWire.TxWriteSignal(s.Id, value));
        App.SignalMirrors[s.Id] = value;
        // The dependents recompute now, batched into this transaction.
        if (App.SignalDeps.TryGetValue(s.Id, out var deps))
            foreach (var recompute in deps)
                recompute(this);
        foreach (var (source, recompute) in pendingSignalDeps)
            if (source == s.Id)
                recompute(this);
    }

    public Widget Widget(uint kind)
    {
        var w = App.NextWidget();
        Records.Add(KayaWire.TxCreateWidget(w.Id, kind));
        AutoParent(w.Id);
        return w;
    }

    // The current ambient parent (0 when the scope roots itself:
    // template bodies, or no open container).
    internal ulong CurrentParent() =>
        App.Parents.Count > 0 ? App.Parents[App.Parents.Count - 1] : 0;

    internal void AutoParent(ulong id)
    {
        ulong p = CurrentParent();
        if (p != 0)
            Records.Add(KayaWire.TxAddChild(p, id));
    }

    public void SetText(Widget w, string text) => Records.Add(KayaWire.TxSetText(w.Id, text));

    public void BindText(Widget w, Signal s) => Records.Add(KayaWire.TxBindText(w.Id, s.Id));

    public void SetChecked(Widget w, bool isChecked) =>
        Records.Add(KayaWire.TxSetChecked(w.Id, isChecked));

    /// Set a widget's flex weight within its row/column: 0 is natural
    /// size, positive weights divide the container's leftover main-axis
    /// space in proportion.
    public void SetGrow(Widget w, double weight) =>
        Records.Add(KayaWire.TxSetGrow(w.Id, weight));

    /// A container's inter-child gap (main axis, DIP; the normalized
    /// default is 8). Containers only — the root rejects it elsewhere.
    public void SetSpacing(Widget w, double gap) =>
        Records.Add(KayaWire.TxSetSpacing(w.Id, gap));

    /// A container's own padding: DIP between its bounds and its
    /// children, uniform on all four sides. Containers only, spacing's
    /// kinds exactly.
    public void SetInset(Widget w, double pad) =>
        Records.Add(KayaWire.TxSetInset(w.Id, pad));

    /// A container's cross-axis child placement (the normalized default
    /// is Align.Start). Containers only; baseline is rows-only.
    public void SetAlign(Widget w, Align align) =>
        Records.Add(KayaWire.TxSetAlign(w.Id, (long)align));

    /// A container's arrangement axis (the creation kind's own is the
    /// default — row horizontal, column vertical). Containers only; the
    /// widget stays addressable by its creation kind whatever this says
    /// (docs/adaptive-layout-plan.md D2).
    public void SetAxis(Widget w, Axis axis) =>
        Records.Add(KayaWire.TxSetAxis(w.Id, (long)axis));

    /// A widget's accessibility IDENTIFIER: a stable authored key that
    /// assistive tooling and UI automation address it by, and which is
    /// NEVER spoken. Universal — every kind carries one.
    public void SetA11yId(Widget w, string id) =>
        Records.Add(KayaWire.TxSetA11yId(w.Id, id));

    /// What an assistive client SPEAKS for a widget. Universal. Leave it
    /// unset to keep whatever the platform derives from the control's
    /// own content; setting it OVERRIDES that.
    public void SetA11yLabel(Widget w, string label) =>
        Records.Add(KayaWire.TxSetA11yLabel(w.Id, label));

    /// What ACTIVATING this widget does — the platforms' hint (Apple
    /// defines it as the result of performing an action; Android
    /// carries it as the click action's label). Write a VERB PHRASE.
    /// Activation kinds only; the root rejects it elsewhere.
    public void SetA11yHint(Widget w, string hint) =>
        Records.Add(KayaWire.TxSetA11yHint(w.Id, hint));

    /// A widget's SEMANTIC EMPHASIS (Role): what it means, never how it
    /// looks. Destructive and Prominent are button emphasis, Heading and
    /// Caption are label hierarchy, and the root refuses a role on a kind
    /// it does not fit.
    public void SetRole(Widget w, Role role) =>
        Records.Add(KayaWire.TxSetRole(w.Id, (long)role));

    public void BindChecked(Widget w, Signal s) =>
        Records.Add(KayaWire.TxBindChecked(w.Id, s.Id));

    /// Point the widget at encoded image bytes: one registration copy
    /// into core-owned memory, so the caller's array is free to drop the
    /// moment this returns.
    public void SetSource(Widget w, byte[] source) =>
        Records.Add(KayaWire.TxSetSource(w.Id, Kaya.RegisterBlob(source)));

    public void BindSource(Widget w, Signal s) =>
        Records.Add(KayaWire.TxBindSource(w.Id, s.Id));

    public void AddChild(Widget parent, Widget child) =>
        Records.Add(KayaWire.TxAddChild(parent.Id, child.Id));

    /// Drop the widget's owned content — a one-shot command riding this
    /// transaction, so the insert and the clear beside it commit
    /// together or not at all. The widget answers through its normal
    /// occurrence path: a clear arrives back as a text change with empty
    /// text.
    public void Clear(Widget w) =>
        Records.Add(KayaWire.TxWidgetCommand(w.Id, KayaWire.CommandClear));

    /// Give the widget keyboard focus — a one-shot command riding the
    /// transaction like Clear.
    public void Focus(Widget w) =>
        Records.Add(KayaWire.TxWidgetCommand(w.Id, KayaWire.CommandFocus));

    /// DECLARE the decorated ranges of a textarea, replacing whatever
    /// was declared before; an empty set is the clear. kaya ships no
    /// search — finding the hits is the app's (docs/ranges-plan.md §3).
    ///
    /// APP-OWNED AND NEVER TRACKED. The first edit of any kind — a
    /// keystroke, a SetText, a native undo — drops the set with nothing
    /// said, and the app re-declares from the fold its change handler
    /// already drives. Nothing in kaya adjusts a range across an edit.
    public void HighlightRanges(Widget w, IEnumerable<TextRange> ranges)
    {
        if (ranges == null)
            throw new ArgumentNullException(
                nameof(ranges),
                "kaya: HighlightRanges takes the set to declare — an empty one is the clear");
        // The offsets ride as one flat Values list read in pairs, start
        // then end, with the count beside it (wire.rs,
        // TX_HIGHLIGHT_RANGES).
        var flat = new List<object>();
        foreach (TextRange r in ranges)
        {
            flat.Add((long)r.Start);
            flat.Add((long)r.Stop);
        }
        Records.Add(KayaWire.TxHighlightRanges(w.Id, (uint)(flat.Count / 2), flat.ToArray()));
    }

    /// Put the textarea's selection at one range (an empty range is a
    /// caret). Same offsets and same validation as HighlightRanges.
    ///
    /// REFUSED WHILE THE USER IS COMPOSING through an input method, in
    /// every backend, because honouring it commits the composition
    /// mid-word — measured on macOS, where the half-typed kana land in
    /// the document and in the app's own model (docs/ranges-plan.md D4).
    /// The refusal is a no-op and not an exception: composition state is
    /// on no kaya channel. Ask again after the next change
    /// notification, which is what ends a composition.
    public void SelectRange(Widget w, TextRange range) =>
        Records.Add(KayaWire.TxSelectRange(w.Id, range.Start, range.Stop));

    /// Scroll the textarea so a range is inside the viewport. A pure
    /// effect: it moves no state, leaves the selection alone, and undo
    /// does not put the scroll position back. How much context lands
    /// around the range is the platform's own behaviour; kaya fixes
    /// containment.
    public void RevealRange(Widget w, TextRange range) =>
        Records.Add(KayaWire.TxRevealRange(w.Id, range.Start, range.Stop));

    // --- Construction sugar ------------------------------------------
    //
    // Everything lowers eagerly to the same records — children first,
    // then the container, then the AddChilds; never a scene value
    // interpreted later.

    /// `role:` is this button's semantic emphasis (Role.Destructive,
    /// Role.Prominent). It changes nothing about what pressing the
    /// button does.
    public Widget Button(string text = null, Action<Tx> onClick = null, double? grow = null,
        Role? role = null)
    {
        var w = Widget(KayaWire.KindButton);
        if (text != null) SetText(w, text);
        if (onClick != null) App.OnClick(w, onClick);
        if (grow is double g) SetGrow(w, g);
        if (role is Role r) SetRole(w, r);
        return w;
    }

    public Widget Entry(Action<Tx, string> onChange = null, double? grow = null)
    {
        var w = Widget(KayaWire.KindEntry);
        if (onChange != null) App.OnChange(w, onChange);
        if (grow is double g) SetGrow(w, g);
        return w;
    }

    /// A multi-line text editor: the entry's uncontrolled contract
    /// over the platform's real multi-line editor.
    public Widget Textarea(Action<Tx, string> onChange = null, double? grow = null)
    {
        var w = Widget(KayaWire.KindTextarea);
        if (onChange != null) App.OnChange(w, onChange);
        if (grow is double g) SetGrow(w, g);
        return w;
    }

    /// `role:` is this label's place in the text hierarchy
    /// (Role.Heading) — the platform's heading text style AND the
    /// accessibility heading trait, which is why it is a role and not a
    /// font size.
    public Widget Label(string text = null, Signal? bind = null, double? grow = null,
        Role? role = null)
    {
        var w = Widget(KayaWire.KindLabel);
        if (text != null) SetText(w, text);
        if (bind is Signal s) BindText(w, s);
        if (grow is double g) SetGrow(w, g);
        if (role is Role r) SetRole(w, r);
        return w;
    }

    /// A label wearing the heading role, in one word (the h1 tradition):
    /// the platform's heading text style AND the accessibility heading
    /// trait, and on a grouped screen the section-header seat.
    public Widget Heading(string text = null, Signal? bind = null, double? grow = null) =>
        Label(text, bind, grow, Role.Heading);

    /// A label wearing the caption role: the platform's footnote tier
    /// under the content it explains, and on a grouped screen the
    /// section-footer seat. The heading's counterpart.
    public Widget Caption(string text = null, Signal? bind = null, double? grow = null) =>
        Label(text, bind, grow, Role.Caption);

    /// A progress bar: display-only, like Label and Image. value is
    /// the determinate fraction (0..=1); indeterminate: true switches
    /// to the platform's activity mode.
    public Widget Progress(double value = 0.0, bool? indeterminate = null, double? grow = null)
    {
        var w = Widget(KayaWire.KindProgress);
        Records.Add(KayaWire.TxSetValue(w.Id, value));
        if (indeterminate is { } i) Records.Add(KayaWire.TxSetIndeterminate(w.Id, i));
        if (grow is double g) SetGrow(w, g);
        return w;
    }

    /// A drawing surface. `viewbox` is the coordinate system the ops are
    /// written in AND the canvas's natural size in points, which is what
    /// keeps one op stream identical on five platforms
    /// (docs/canvas-plan.md §3.2). Declare what it draws with Draw;
    /// until then it is present and empty.
    public Widget Canvas(Viewbox viewbox, double? grow = null)
    {
        var w = Widget(KayaWire.KindCanvas);
        // The viewbox rides the DRAWING on the wire, not a prop, so a
        // canvas with no declaration yet has nothing to be inconsistent
        // about; the guest side remembers it so a redraw in a later
        // handler does not repeat it.
        App.CanvasViewboxes[w.Id] = viewbox;
        if (grow is double g) SetGrow(w, g);
        return w;
    }

    /// WHAT THIS CANVAS DOES WITH A TRACK THAT IS NOT ITS VIEWBOX
    /// (docs/canvas-plan.md §3.2.1) — behind Widget.Fixed, Widget.OnDraw
    /// and Widget.OnTick, which is where a guest declares it.
    internal void SizePolicy(Widget w, uint policy) =>
        Records.Add(KayaWire.TxSetSizePolicy(w.Id, policy));

    /// DECLARE the whole drawing on a canvas, replacing whatever was
    /// declared before. The lambda reads as immediate-mode drawing and
    /// records: one atomic record is submitted when it returns.
    public void Draw(Widget w, Action<Draw> body)
    {
        if (!App.CanvasViewboxes.TryGetValue(w.Id, out var viewbox))
        {
            throw new InvalidOperationException(
                "kaya: Draw on a widget that is not a canvas this app declared — a "
                + "drawing is a declaration against the canvas it draws on "
                + "(docs/canvas-plan.md §2.1)");
        }
        var d = new Draw(viewbox);
        body(d);
        Records.Add(KayaWire.TxSetDrawing(w.Id, viewbox.W, viewbox.H,
            (uint)d.Ops.Count, 0, d.Ops.ToArray()));
    }

    /// Re-declare ONE stamped copy's drawing: `n` is the canvas template
    /// node and `keys` that copy's key path, outermost first. An empty
    /// path re-declares the drawing every copy is born with, which is
    /// what Tpl.Canvas spells at declaration time
    /// (docs/canvas-plan.md §3.1).
    public void Draw(Node n, IReadOnlyList<object> keys, Viewbox viewbox,
        Action<Draw> body)
    {
        var d = new Draw(viewbox);
        body(d);
        var values = new object[keys.Count + d.Ops.Count];
        for (int i = 0; i < keys.Count; i++) values[i] = keys[i];
        for (int i = 0; i < d.Ops.Count; i++) values[keys.Count + i] = d.Ops[i];
        Records.Add(KayaWire.TxSetDrawing(n.Id, viewbox.W, viewbox.H,
            (uint)d.Ops.Count, (uint)keys.Count, values));
    }

    /// A slider over min..max at value, with its change handler
    /// co-located. `bind` takes a float Signal for the position instead
    /// of a constant; property writes never echo an occurrence, so a
    /// handler's own writes cannot loop back at it.
    public Widget Slider(double min = 0.0, double max = 1.0, double value = 0.0,
        Action<Tx, double> onChange = null, double? grow = null, Signal? bind = null)
    {
        var w = Widget(KayaWire.KindSlider);
        Records.Add(KayaWire.TxSetMin(w.Id, min));
        Records.Add(KayaWire.TxSetMax(w.Id, max));
        if (bind is Signal s) Records.Add(KayaWire.TxBindValue(w.Id, s.Id));
        else Records.Add(KayaWire.TxSetValue(w.Id, value));
        if (onChange != null) App.OnValueChanged(w, onChange);
        if (grow is double g) SetGrow(w, g);
        return w;
    }

    /// A dropdown select over fixed options — each becomes a label child
    /// — at `selected`, the initial 0-based index (checked at the root
    /// against the option count). onSelect receives each USER pick's new
    /// index; programmatic writes never echo.
    public Widget Select(string[] options, int selected = 0,
        Action<Tx, int> onSelect = null, double? grow = null)
    {
        var w = Widget(KayaWire.KindSelect);
        App.Parents.Add(w.Id);
        foreach (var option in options)
        {
            var o = Widget(KayaWire.KindLabel);
            SetText(o, option);
        }
        App.Parents.RemoveAt(App.Parents.Count - 1);
        Records.Add(KayaWire.TxSetValue(w.Id, selected));
        if (onSelect != null)
            App.OnValueChanged(w, (tx, v) => onSelect(tx, (int)v));
        if (grow is double g) SetGrow(w, g);
        return w;
    }

    public Widget Radio(string[] options, int selected = 0,
        Action<Tx, int> onSelect = null, double? grow = null)
    {
        var w = Widget(KayaWire.KindRadio);
        App.Parents.Add(w.Id);
        foreach (var option in options)
        {
            var o = Widget(KayaWire.KindLabel);
            SetText(o, option);
        }
        App.Parents.RemoveAt(App.Parents.Count - 1);
        Records.Add(KayaWire.TxSetValue(w.Id, selected));
        if (onSelect != null)
            App.OnValueChanged(w, (tx, v) => onSelect(tx, (int)v));
        if (grow is double g) SetGrow(w, g);
        return w;
    }

    public Widget Checkbox(string text = null, bool? isChecked = null,
        Action<Tx, bool> onToggle = null, double? grow = null)
    {
        var w = Widget(KayaWire.KindCheckbox);
        if (text != null) SetText(w, text);
        if (isChecked is bool c) SetChecked(w, c);
        if (onToggle != null) App.OnToggle(w, onToggle);
        if (grow is double g) SetGrow(w, g);
        return w;
    }

    /// An image displaying encoded bytes (PNG, JPEG, ...): the toolkit
    /// decodes natively, and decode failure renders the placeholder,
    /// never a crash. The caller's array is free to drop the moment this
    /// returns.
    public Widget Image(byte[] source = null, Signal? bind = null, double? grow = null)
    {
        var w = Widget(KayaWire.KindImage);
        if (source != null) SetSource(w, source);
        if (bind is Signal s) BindSource(w, s);
        if (grow is double g) SetGrow(w, g);
        return w;
    }

    /// The PICTURE-FILE overload: the same image, showing what THE APP'S
    /// OWN BUILD PUT BESIDE IT.
    ///
    ///     using var mark = tx.Asset("icons/kaya-mark.png");
    ///     tx.Image(mark);
    ///
    /// The picture never enters .NET — the redemption clones one refcount
    /// into the blob table, AppIdentity(string, Asset)'s route exactly.
    /// The asset is REQUIRED, so this is not ambiguous with the
    /// bytes/signal call above.
    public Widget Image(Asset source, double? grow = null)
    {
        if (source is null)
            throw new ArgumentNullException(nameof(source),
                "kaya: Image got no asset — open one with " +
                "tx.Asset(\"icons/...\"), or pass encoded bytes");
        var w = Widget(KayaWire.KindImage);
        Records.Add(KayaWire.TxSetSource(w.Id, source.Blob()));
        if (grow is double g) SetGrow(w, g);
        return w;
    }

    /// A container parents everything declared inside its body (the
    /// ambient stack). `inset:` is this container's own padding.
    public Widget Column(
        Action body, double? grow = null, double? spacing = null, Align? align = null,
        double? inset = null) =>
        ContainerOf(KayaWire.KindColumn, body, grow, spacing, align, inset);

    /// `stackBelow:` stacks this row's children vertically while the
    /// window is narrower than that many logical points — a
    /// core-evaluated width breakpoint, reverting on the way back up
    /// (docs/adaptive-layout-plan.md D3).
    public Widget Row(
        Action body, double? grow = null, double? spacing = null, Align? align = null,
        double? inset = null, double? stackBelow = null) =>
        ContainerOf(KayaWire.KindRow, body, grow, spacing, align, inset, stackBelow);

    /// A vertical scroll viewport over EXACTLY ONE child. Pass grow: so
    /// the enclosing track CONSTRAINS it — an unconstrained viewport
    /// hugs its content and nothing overflows.
    public Widget Scroll(Action body, double? grow = null) =>
        ContainerOf(KayaWire.KindScroll, body, grow, null, null, null);

    /// A grid laying its children out row-major into `columns` columns —
    /// each column takes its NATURAL width, aligned across rows;
    /// `spacing` is the inter-cell gap on both axes.
    public Widget Grid(int columns, Action body, double? spacing = null, double? grow = null,
        double? inset = null)
    {
        var parent = Widget(KayaWire.KindGrid);
        Records.Add(KayaWire.TxSetColumns(parent.Id, columns));
        if (spacing is double gap) SetSpacing(parent, gap);
        if (grow is double g) SetGrow(parent, g);
        if (inset is double pad) SetInset(parent, pad);
        App.Parents.Add(parent.Id);
        body?.Invoke();
        App.Parents.RemoveAt(App.Parents.Count - 1);
        return parent;
    }

    /// A spacer: PURE SUGAR for an empty grown column — it consumes
    /// the leftover main-axis space between its siblings.
    public Widget Spacer()
    {
        var w = Widget(KayaWire.KindColumn);
        SetGrow(w, 1.0);
        return w;
    }

    Widget ContainerOf(
        uint kind, Action body, double? grow = null, double? spacing = null, Align? align = null,
        double? inset = null, double? stackBelow = null)
    {
        var parent = Widget(kind);
        if (grow is double g) SetGrow(parent, g);
        if (spacing is double gap) SetSpacing(parent, gap);
        if (align is Align a) SetAlign(parent, a);
        if (inset is double pad) SetInset(parent, pad);
        if (stackBelow is double below) StackBelow(parent, below);
        App.Parents.Add(parent.Id);
        body?.Invoke();
        App.Parents.RemoveAt(App.Parents.Count - 1);
        return parent;
    }

    // One breakpoint on the primary window carrying one setter: the
    // setter list is count triples flat, widgets then props then values
    // (KayaWire.TxCreateBreakpoint). LIVE ZONE ONLY — a breakpoint's
    // setters name live widgets, and Tpl's Row hands back a Node, so the
    // template zone is refused by type.
    void StackBelow(Widget w, double width) =>
        Records.Add(KayaWire.TxCreateBreakpoint(0, width, 1, new object[]
        {
            (long)w.Id, (long)KayaWire.PropAxis, (long)KayaWire.AxisVertical,
        }));

    /// A For as a child: ForEach whose body keeps no handles.
    public Widget Each(Collection c, Action<Tpl> body) => ForEach(c, body);

    public Collection Collection()
    {
        var c = App.NextCollection();
        App.RegisterCollection(c.Id);
        Records.Add(KayaWire.TxCreateCollection(c.Id, new[] { new uint[] { KayaWire.ValueStr } }));
        // A scalar collection IS its one field, so an undo puts the
        // value back as it stands.
        App.Rehydrate[c.Id] = (_, fields, _) => fields.Count > 0 ? fields[0] : null;
        return c;
    }

    /// A For over `c`: the body declares the template; the For itself
    /// (a live container) is returned.
    /// <summary>Declare the column header bar on a For's container —
    /// the Widget ForEach returns. One title per column; the row
    /// template's root must be a Row of exactly one cell per column,
    /// refused loudly otherwise. Re-call after sorting to move the
    /// indicator (docs/tables-plan.md).</summary>
    public void Columns(Widget w, string[] titles, Sort sort)
    {
        // pathLen 0: no key path, so the values are titles alone
        // (docs/tables-plan.md, dynamic tables).
        Records.Add(KayaWire.TxSetColumnHeaders(
            w.Id, sort.Sorted, sort.Direction, (uint)titles.Length, 0,
            HeaderValues(Array.Empty<object>(), titles)));
    }

    /// <summary>Re-declare ONE stamped copy's header bar — the per-copy
    /// sort arrows: `n` is the nested For's template node and `keys` is
    /// that copy's key path, outermost first, exactly the list
    /// OnSort(Node) handed over. An empty path re-declares the bar for
    /// every copy. The core refuses a keyed re-declaration before the
    /// template bar exists (docs/tables-plan.md).</summary>
    public void Columns(Node n, IReadOnlyList<object> keys, string[] titles, Sort sort)
    {
        Records.Add(KayaWire.TxSetColumnHeaders(
            n.Id, sort.Sorted, sort.Direction, (uint)titles.Length, (uint)keys.Count,
            HeaderValues(keys, titles)));
    }

    /// The record's Values: the copy's KEYS first, then the titles
    /// (docs/tables-plan.md, dynamic tables).
    internal static object[] HeaderValues(IReadOnlyList<object> keys, string[] titles)
    {
        var values = new object[keys.Count + titles.Length];
        for (int i = 0; i < keys.Count; i++) values[i] = keys[i];
        for (int i = 0; i < titles.Length; i++) values[keys.Count + i] = titles[i];
        return values;
    }

    public Widget ForEach(Collection c, Action<Tpl> body)
    {
        c.AssertRoot();
        var w = App.NextWidget();
        // The For parents into the enclosing scope, but the record
        // must land after template_end — an AddChild inside the
        // blueprint would cross zones.
        ulong parent = CurrentParent();
        Records.Add(KayaWire.TxCreateFor(w.Id, c.Id));
        App.OpenFors.Add(c.Id);
        App.Parents.Add(0);
        // try/finally: a throwing body abandons the tx but the app
        // survives, and a stuck counter would poison later reads.
        App.TplDepth++;
        try
        {
            body(new Tpl(this));
        }
        finally
        {
            App.TplDepth--;
        }
        App.Parents.RemoveAt(App.Parents.Count - 1);
        App.OpenFors.RemoveAt(App.OpenFors.Count - 1);
        Records.Add(KayaWire.TxTemplateEnd());
        if (parent != 0)
            Records.Add(KayaWire.TxAddChild(parent, w.Id));
        return w;
    }

    /// Open a For template for a generated row trace (`foreach (var row
    /// in todos.Rows())`). The enumerator's Dispose calls the close
    /// action, so foreach makes the close structural — even on break.
    public (Tpl, Action) BeginRowTrace(Collection c)
    {
        c.AssertRoot();
        var w = App.NextWidget();
        ulong parent = CurrentParent();
        Records.Add(KayaWire.TxCreateFor(w.Id, c.Id));
        App.OpenFors.Add(c.Id);
        App.Parents.Add(0);
        // The counter drops in the close action: foreach's Dispose
        // calls it structurally, even on break or a throwing body.
        App.TplDepth++;
        return (new Tpl(this), () =>
        {
            App.TplDepth--;
            App.Parents.RemoveAt(App.Parents.Count - 1);
            App.OpenFors.RemoveAt(App.OpenFors.Count - 1);
            Records.Add(KayaWire.TxTemplateEnd());
            if (parent != 0)
                Records.Add(KayaWire.TxAddChild(parent, w.Id));
        });
    }

    /// A When over a Bool signal: stamps on true, unstamps on false.
    public Widget When(Signal s, Action<Tpl> body)
    {
        var w = App.NextWidget();
        ulong parent = CurrentParent();
        Records.Add(KayaWire.TxCreateWhen(w.Id, s.Id));
        App.Parents.Add(0);
        App.TplDepth++;
        try
        {
            body(new Tpl(this));
        }
        finally
        {
            App.TplDepth--;
        }
        App.Parents.RemoveAt(App.Parents.Count - 1);
        Records.Add(KayaWire.TxTemplateEnd());
        if (parent != 0)
            Records.Add(KayaWire.TxAddChild(parent, w.Id));
        return w;
    }

    /// Insert under a key the app already has: a scalar collection's
    /// entry is one value, which is the single-field record.
    ///
    /// ROUTED THROUGH InsertRecordRaw so this binding has ONE insert
    /// path: the minter's absorption sits on it, and an explicit key
    /// that reached the core without passing the counter would let a
    /// later mint collide with it (docs/fresh-key-plan.md).
    public void Insert(Collection c, object key, object value) =>
        InsertRecordRaw(c, key, value, 0, new[] { value });

    /// Insert under a key the BINDING authors, and hand the key back —
    /// for data with no identity of its own (docs/fresh-key-plan.md).
    ///
    /// ONE COUNTER PER COLLECTION INSTANCE, starting at 0; the minted
    /// key is I64 (a C# long) and is counter+1. An instance is a table —
    /// the live-zone collection, or one stamped copy selected by At(...).
    ///
    /// MIXING IS SAFE BY ABSORPTION: an explicit Insert whose key is an
    /// integer at or above the counter carries it up. A non-numeric key
    /// cannot collide with an I64 and moves nothing.
    ///
    /// NO DECREMENT IS EXPRESSIBLE: undo and redo replay captured keys
    /// inside the core and never re-enter this path, and Rollback
    /// restores the model but not the counter. A fresh key is fresh
    /// forever.
    public long InsertFresh(Collection c, object value)
    {
        long key = MintKey(c);
        Insert(c, key, value);
        return key;
    }

    /// The mint behind the three InsertFresh spellings — this one, and
    /// the typed collections' in KayaRecords/KayaSums, which insert
    /// through their own raw paths.
    internal long MintKey(Collection c) => App.MintKey(c.Id, c.Path);

    public void Update(Collection c, object key, object value)
    {
        ModelSet(c.Id, c.Path, key, value);
        Records.Add(KayaWire.TxCollectionUpdate(c.Id, c.Path, key, 0, new[] { value }));
        RecomputeDerived(c);
    }

    public void Remove(Collection c, object key)
    {
        ModelRemove(c.Id, c.Path, key);
        Records.Add(KayaWire.TxCollectionRemove(c.Id, c.Path, key));
        RecomputeDerived(c);
    }

    /// MoveBefore repositions an entry before another's. Keys, never
    /// indices. A missing key or anchor throws here, at the call site;
    /// moving an entry before itself is a no-op and nothing travels.
    public void MoveBefore(Collection c, object key, object anchor) =>
        MoveEntry(c, key, new[] { anchor });

    public void MoveToEnd(Collection c, object key) =>
        MoveEntry(c, key, System.Array.Empty<object>());

    public void MoveToFront(Collection c, object key)
    {
        var keys = KeysOf(c);
        if (keys.Count == 0)
            throw new InvalidOperationException($"kaya: move of missing key {key}");
        MoveEntry(c, key, new[] { keys[0] });
    }

    public void MoveAfter(Collection c, object key, object anchor)
    {
        var keys = KeysOf(c);
        if (!keys.Exists(k => Equals(k, key)))
            throw new InvalidOperationException($"kaya: move of missing key {key}");
        int at = keys.FindIndex(k => Equals(k, anchor));
        if (at < 0)
            throw new InvalidOperationException($"kaya: move after missing key {anchor}");
        if (Equals(key, anchor))
            return;
        if (at + 1 == keys.Count)
        {
            MoveEntry(c, key, System.Array.Empty<object>());
            return;
        }
        if (Equals(keys[at + 1], key))
            return; // already directly after the anchor
        MoveEntry(c, key, new[] { keys[at + 1] });
    }

    void MoveEntry(Collection c, object key, object[] before)
    {
        if (before.Length > 0 && Equals(before[0], key))
        {
            // Order unchanged and nothing travels — but the key must
            // exist.
            if (!KeysOf(c).Exists(k => Equals(k, key)))
                throw new InvalidOperationException($"kaya: move of missing key {key}");
            return;
        }
        ModelMove(c.Id, c.Path, key, before);
        Records.Add(KayaWire.TxCollectionMove(c.Id, c.Path, key, before));
        RecomputeDerived(c);
    }

    internal void RegisterDerived(ulong coll, Action<Tx> recompute) =>
        pendingDerived.Add((coll, recompute));

    // Every derived signal rooted at this collection, recomputed and
    // written into this transaction. Deriveds hang off root handles,
    // so nested-instance mutations cannot change their input.
    void RecomputeDerived(Collection c)
    {
        if (c.Path.Length != 0)
            return;
        if (App.Derived.TryGetValue(c.Id, out var list))
            foreach (var recompute in list)
                recompute(this);
        foreach (var (coll, recompute) in pendingDerived)
            if (coll == c.Id)
                recompute(this);
    }

    // The raw record paths KayaRecords builds on: the model keeps the
    // record object itself; only the wire fields travel.
    internal Collection CollectionWithSchema(uint[] schema)
    {
        return CollectionWithVariants(new[] { schema });
    }

    internal Collection CollectionWithVariants(uint[][] variants)
    {
        var c = App.NextCollection();
        App.RegisterCollection(c.Id);
        Records.Add(KayaWire.TxCreateCollection(c.Id, variants));
        return c;
    }

    internal void EmitVariantCase(uint variant) =>
        Records.Add(KayaWire.TxVariantCase(variant));

    internal void InsertRecordRaw(Collection c, object key, object model, uint variant, object[] fields)
    {
        // ABSORPTION, on the one path every explicit key travels: a
        // numeric key at or above the minter's counter carries it up
        // (InsertFresh's contract).
        App.AbsorbKey(c.Id, c.Path, key);
        ModelSet(c.Id, c.Path, key, model);
        Records.Add(KayaWire.TxCollectionInsert(c.Id, c.Path, key, variant, fields));
        RecomputeDerived(c);
    }

    internal void UpdateRecordRaw(Collection c, object key, object model, uint variant, object[] fields)
    {
        ModelSet(c.Id, c.Path, key, model);
        Records.Add(KayaWire.TxCollectionUpdate(c.Id, c.Path, key, variant, fields));
        RecomputeDerived(c);
    }

    internal void UpdateFieldRaw(Collection c, object key, object model, uint variant, uint field, object value)
    {
        ModelSet(c.Id, c.Path, key, model);
        Records.Add(KayaWire.TxCollectionUpdateField(c.Id, c.Path, key, field, variant, value));
        RecomputeDerived(c);
    }

    // The record-time mirror-read guard: a read inside a template body
    // is one snapshot baked into every stamp. The typed surfaces route
    // through Items, so this is the single choke point.
    void GuardMirrorRead()
    {
        if (App.TplDepth > 0)
            throw new InvalidOperationException(
                "kaya: model read inside a template body — the template records once and "
                + "replays; bind a signal, use the element's field, or Derive() for "
                + "computed values");
    }

    /// The model: what this guest wrote, exactly — the fold of every
    /// patch so far (this transaction's included), in insertion order.
    public List<KeyValuePair<object, object>> Items(Collection c)
    {
        GuardMirrorRead();
        var instance = App.InstanceOf(c.Id, c.Path);
        return instance == null
            ? new List<KeyValuePair<object, object>>()
            : new List<KeyValuePair<object, object>>(instance.Entries);
    }

    public int Count(Collection c)
    {
        GuardMirrorRead();
        return App.InstanceOf(c.Id, c.Path)?.Entries.Count ?? 0;
    }

    /// REQUEST the app's brand accent (docs/styling-plan.md D1/D2).
    /// `seed` is one packed sRGB hex (0xRRGGBB); `light:`/`dark:` are
    /// per-appearance overrides, and the seed fills whichever is left
    /// unstated:
    /// tx.BrandAccent(0x3584E4) — tx.BrandAccent(0x3584E4, dark: 0x62A0EA).
    ///
    /// A REQUEST, uniformly: a platform may let its user override the
    /// app's accent (macOS does today).
    ///
    /// SET ONCE, BEFORE THE FIRST MOUNT: the root refuses a second write
    /// and a late one.
    ///
    /// The app NEVER writes a foreground and NEVER writes contrast
    /// variants — the core derives fill, on-fill, standalone and a
    /// hover/pressed ramp per appearance.
    public void BrandAccent(uint seed, uint? light = null, uint? dark = null)
    {
        // The mask says which overrides are PRESENT, so a legitimate
        // 0x000000 override is not read as absence.
        uint mask = (light is null ? 0u : 1u) | (dark is null ? 0u : 2u);
        Records.Add(KayaWire.TxSetBrandAccent(seed, mask, light ?? 0, dark ?? 0));
    }

    /// Open an asset — a file the app's own BUILD shipped beside it,
    /// named by a relative path under the asset root:
    ///
    ///     using var font = tx.Asset("fonts/sora-wght.ttf");
    ///
    /// Queues no record: opening one is a read.
    ///
    /// A MISS THROWS, WITH THE CORE'S SENTENCE AND NOTHING ADDED. This
    /// binding writes no prose of its own for that failure, so every
    /// language raises the same bytes and one scene can freeze them.
    ///
    /// EACH CALL READS. No cache, no watch, no reload.
    public Asset Asset(string name)
    {
        // The transaction's liveness, asked through the same chokepoint
        // every write uses.
        _ = Records;
        ulong handle = Kaya.AssetOpen(name);
        if (handle != 0) return new Asset(handle, name);
        string sentence = Kaya.AssetMissSentence(name);
        if (sentence.Length == 0)
            // Reachable only when the two calls disagree: the open
            // answered a miss and the why-not answers that it resolves.
            // Both were measured; this binding invents no third cause.
            sentence = $"kaya: asset(\"{name}\") did not open, and the core's own " +
                "why-not answers that it resolves — those two facts were measured " +
                "a moment apart, and this binding has nothing further to report";
        throw new InvalidOperationException(sentence);
    }

    /// Why Asset(name) would throw — the sentence it would carry, handed
    /// over without throwing. "" means the name resolves.
    ///
    /// Line 1 (name, rule, census) is the same on every platform and is
    /// the line a scene freezes; line 2 names the resolved place, which
    /// three platforms spell three ways.
    ///
    /// Why a query and not just the throw: docs/deferred.md, the assets
    /// entry.
    public string AssetMissSentence(string name)
    {
        // The transaction's liveness, for the same reason Asset asks it.
        _ = Records;
        return Kaya.AssetMissSentence(name);
    }

    /// REQUEST the app's brand typeface (docs/styling-plan.md Slice 2b).
    /// One family name is the whole call — tx.BrandTypeface("Georgia") —
    /// and every platform that HAS that family installed uses it.
    ///
    /// THE FAMILY, NEVER THE SCALE: sizes, weights, metrics and the
    /// whole type ramp stay the platform's.
    ///
    /// SET ONCE, BEFORE THE FIRST MOUNT: the accent's wall verbatim. The
    /// root refuses a second write and a late one.
    ///
    /// A family a platform does not have leaves that platform's own
    /// typeface in place, deliberately and silently: each lowering gates
    /// on the family being INSTALLED, because every font API renders
    /// SOMETHING for a name it cannot match.
    ///
    /// platforms: the per-platform overrides, as pairs —
    /// new[] { (Platform.Linux, "DejaVu Serif") } — with `family` the
    /// default. THE PAIRS TRAVEL UNRESOLVED, because this binding cannot
    /// know which platform it is running on while every LOWERING is its
    /// platform.
    ///
    /// font: a font FILE, as bytes, on the same blob channel an image
    /// rides. The backend registers them, reads back the family that
    /// produced, and the NAME machinery above takes over; a registered
    /// blob's own family wins over `family` on that backend.
    public void BrandTypeface(
        string family,
        (Platform Platform, string Family)[]? platforms = null,
        byte[]? font = null)
    {
        // The mask says whether the font slot means anything; the slot
        // is written EITHER WAY (an empty Str when it does not), so the
        // record's field count never varies with the payload.
        uint mask = font is null ? 0u : 1u;
        var pairs = new List<object>();
        foreach (var (platform, perPlatform) in
                 platforms ?? Array.Empty<(Platform, string)>())
        {
            // An I64 platform tag then that platform's family, read in
            // twos by the core, with the same odd-count refusal the file
            // dialog's filters get.
            pairs.Add((long)platform);
            pairs.Add(perPlatform);
        }
        Records.Add(KayaWire.TxSetBrandTypeface(
            mask, family, pairs.ToArray(),
            // The record carries the handle, never the font itself.
            font is null ? (object)"" : new KayaWire.BlobHandle(Kaya.RegisterBlob(font))));
    }

    /// The FONT-FILE overload: the same request, with the font THE APP'S
    /// OWN BUILD PUT BESIDE IT.
    ///
    ///     using var font = tx.Asset("fonts/sora-wght.ttf");
    ///     tx.BrandTypeface("Sora", font);
    ///
    /// The bytes never enter .NET: the core read them and the
    /// redemption clones one refcount into the blob table.
    ///
    /// THE ASSET IS SECOND AND REQUIRED, rather than a third optional
    /// parameter beside `font`. Two overloads whose tails were both
    /// optional would make tx.BrandTypeface("Georgia") ambiguous, so the
    /// parameter that selects this overload cannot be left out.
    public void BrandTypeface(
        string family,
        Asset font,
        (Platform Platform, string Family)[]? platforms = null)
    {
        if (font is null)
            throw new ArgumentNullException(nameof(font),
                "kaya: BrandTypeface got no asset — open one with " +
                "tx.Asset(\"fonts/...\"), or pass a family name alone");
        var pairs = new List<object>();
        foreach (var (platform, perPlatform) in
                 platforms ?? Array.Empty<(Platform, string)>())
        {
            pairs.Add((long)platform);
            pairs.Add(perPlatform);
        }
        Records.Add(KayaWire.TxSetBrandTypeface(
            1u, family, pairs.ToArray(),
            new KayaWire.BlobHandle(font.Blob())));
    }

    /// DECLARE the app's identity (docs/app-identity-plan.md): the name
    /// it goes by and the picture that stands for it, as the bytes of
    /// one image file — tx.AppIdentity("Aurora Notes", markPng).
    ///
    /// ONE PICTURE, FIVE PLATFORMS. The same bytes become the macOS Dock
    /// tile, the Windows taskbar/alt-tab icon and the caption's mark,
    /// and an X11 window's icon; the same FILE, read at build time,
    /// becomes the Android launcher icon and the iOS Home Screen icon.
    /// Send a PNG: each lowering converts, and no platform-specific
    /// artwork rides the wire.
    ///
    /// SET ONCE, BEFORE THE FIRST MOUNT: the brand's wall verbatim. The
    /// root refuses a second write, a late one, and an empty name — an
    /// app that wants the platform's own identity declares none at all.
    ///
    /// THE BYTES ARE NEVER INSPECTED between here and the platform's own
    /// decoder, so bytes that are not an image leave every platform's
    /// default in place.
    ///
    /// icon: the picture's bytes, on the same blob channel an image
    /// rides. Leave it out for the NAME-ONLY form, which still reaches
    /// every name surface and keeps each platform's default mark.
    public void AppIdentity(string name, byte[]? icon = null)
    {
        // The mask says whether the icon slot means anything; the slot
        // is written EITHER WAY (an empty Str when it does not), so the
        // record's field count never varies with the payload.
        Records.Add(KayaWire.TxSetAppIdentity(
            icon is null ? 0u : 1u, name,
            // The record carries the handle, never the picture itself.
            icon is null ? (object)"" : new KayaWire.BlobHandle(Kaya.RegisterBlob(icon))));
    }

    /// The MARK-FILE overload: the same declaration, with the picture
    /// THE APP'S OWN BUILD PUT BESIDE IT.
    ///
    ///     using var mark = tx.Asset("icons/kaya-mark.png");
    ///     tx.AppIdentity("Aurora Notes", mark);
    ///
    /// The picture never enters .NET. This overload REQUIRES the asset,
    /// so it is not ambiguous with the name-only call above.
    public void AppIdentity(string name, Asset icon)
    {
        if (icon is null)
            throw new ArgumentNullException(nameof(icon),
                "kaya: AppIdentity got no asset — open one with " +
                "tx.Asset(\"icons/...\"), or declare the name alone");
        Records.Add(KayaWire.TxSetAppIdentity(
            1u, name, new KayaWire.BlobHandle(icon.Blob())));
    }

    /// Set the window's attributes in one construct — the attribute set
    /// is EXACTLY CreateWindow's. tx.Window(title: "sections",
    /// sectionsPresentation: KayaWire.SectionsPresentationBar).
    ///
    /// dirty: says this surface holds UNSAVED WORK, and the backend
    /// shows its platform's own affordance (docs/dirty-plan.md D2/D4).
    /// STATE, NOT CHROME: the declared title is left alone. It ARMS
    /// NOTHING either — "unsaved changes, close anyway?" is vetoClose
    /// plus a dialog, yours to compose.
    ///
    /// inset: the window CONTENT INSET, in layout units — LAYOUT, not
    /// appearance (docs/styling-plan.md D3). 16 unless you say
    /// otherwise; 0 is full bleed. A platform's safe area is a separate
    /// fact and is not removed by it. Negative is refused at the root.
    ///
    /// panes: the CEILING on how many of this window's stack entries
    /// present side by side — 1 is the serial stack, 2 and 3 are columns
    /// on a window wide enough, the shallowest shed first as it narrows
    /// (docs/multicolumn-plan.md carries the ruling and the measured
    /// mechanics). There is deliberately no argument for WHICH entries
    /// show — the stack's order is the priority order — and the live
    /// count is the platform's own judgment where it has one. The root
    /// refuses 0 and anything above 3.
    public void Window(
        string? title = null, double? width = null, double? height = null,
        bool? vetoClose = null, uint? panes = null, bool? dirty = null,
        double? inset = null, long? sectionsPresentation = null,
        Action<Tx>? onCloseRequested = null, Action<Tx>? onClosed = null,
        Action<Tx, string, UndoDelta>? onUndone = null,
        Action<Tx, string, UndoDelta>? onRedone = null,
        MenuItem[]? menus = null, ulong id = 0)
    {
        if (title is { } t) Records.Add(KayaWire.TxSetWindowTitle(id, t));
        if (width is { } w) Records.Add(KayaWire.TxSetWindowWidth(id, w));
        if (height is { } h) Records.Add(KayaWire.TxSetWindowHeight(id, h));
        if (vetoClose is { } v) Records.Add(KayaWire.TxSetWindowVetoClose(id, v));
        if (panes is { } pn) Records.Add(KayaWire.TxSetWindowPanes(id, pn));
        if (dirty is { } d) Records.Add(KayaWire.TxSetWindowDirty(id, d));
        if (inset is { } ins) Records.Add(KayaWire.TxSetWindowInset(id, ins));
        if (sectionsPresentation is { } sp)
            Records.Add(KayaWire.TxSetWindowSectionsPresentation(id, sp));
        if (onCloseRequested is { } r) App.closeRequested[id] = r;
        if (onClosed is { } c) App.windowClosed[id] = c;
        // Each fires every time kaya routes an undo (or a redo) there,
        // with the group's label — EMPTY for a typing episode — and what
        // the core put back. THE DELTA IS THE ONLY NOTIFICATION:
        // applying an inverse is a programmatic write, so the echo
        // doctrine silences every occurrence it would cause. The mirrors
        // are already folded when the handler runs; this is where an app
        // folds it into ITS model.
        if (onUndone is { } u) App.undone[id] = u;
        if (onRedone is { } re) App.redone[id] = re;
        // menus: appends top-level grouping nodes (Menu or RadioGroup)
        // to this window's command catalog, in order — append-only, at
        // any time.
        if (menus != null)
            foreach (var m in menus)
                Records.Add(KayaWire.TxMenubarAppend(id, m.Id));
    }

    /// Create an auxiliary window (capability-gated: phone hosts reject
    /// at the root). Materializes hidden; MountIn presents it.
    ///
    /// onCloseRequested fires per chrome close while vetoClose is armed
    /// — nothing has closed; answer with tx.DestroyWindow to agree.
    /// onClosed fires when the non-veto auxiliary is chrome-closed
    /// (informational; DestroyWindow reconciles) and retires with it.
    public void CreateWindow(
        ulong id, string? title = null, double? width = null, double? height = null,
        bool? vetoClose = null, uint? panes = null, bool? dirty = null,
        double? inset = null, long? sectionsPresentation = null,
        Action<Tx>? onCloseRequested = null, Action<Tx>? onClosed = null,
        Action<Tx, string, UndoDelta>? onUndone = null,
        Action<Tx, string, UndoDelta>? onRedone = null,
        MenuItem[]? menus = null)
    {
        Records.Add(KayaWire.TxCreateWindow(id));
        Window(title, width, height, vetoClose, panes, dirty, inset, sectionsPresentation,
            onCloseRequested, onClosed, onUndone, onRedone, menus, id);
    }

    /// Request a modal alert (the request/result grammar):
    /// tx.ShowAlert(title: "delete item?", message: "…",
    ///     action0: "Delete", action1: "Archive", cancel: "Keep",
    ///     onResult: (tx, choice) => { … }).
    /// The result handler rides the REQUEST and retires with its one
    /// answer — choice is an action index (0 or 1) or
    /// KayaWire.AlertChoiceCancel, every platform-native dismissal. Up
    /// to two actions (the platform floor); the cancel label is
    /// required. One alert may be live per process; show the next from
    /// the handler.
    public ulong ShowAlert(
        string title = "", string message = "",
        string? action0 = null, string? action1 = null,
        string? cancel = null, Action<Tx, uint>? onResult = null,
        ulong window = 0)
    {
        if (action1 != null && action0 == null)
            throw new ArgumentException(
                "kaya: action1 without action0 — actions fill in order");
        if (string.IsNullOrEmpty(cancel))
            throw new ArgumentException(
                "kaya: the cancel slot always exists and needs a name — pass cancel:");
        uint actions = action0 == null ? 0u : (action1 == null ? 1u : 2u);
        ulong id = ++App.nextAlert;
        if (onResult != null)
            App.alerts[id] = onResult;
        Records.Add(KayaWire.TxShowAlert(
            window, id, actions, title, message,
            action0 ?? "", action1 ?? "", cancel));
        return id;
    }

    /// Ask the platform for files. THE PICK, NOT THE OPEN — the result
    /// carries handles you redeem later (DESIGN.md, File dialogs).
    ///
    /// `filters` is advisory on every platform, so the guest still
    /// validates what it got. Each entry is (label, space-separated
    /// extensions).
    ///
    /// onResult fires exactly once and the registration retires with it.
    /// CANCEL IS THE EMPTY LIST. One dialog may be live per process;
    /// show the next from the handler.
    public ulong PickFiles(
        (string Label, string Extensions)[]? filters = null,
        Action<Tx, List<PickedFile>>? onResult = null,
        ulong window = 0)
        => Pick(true, filters, onResult, window);

    /// The single-file spelling. The floor always returns a LIST; this
    /// only asks the platform for one, so the handler receives zero or
    /// one file.
    public ulong PickFile(
        (string Label, string Extensions)[]? filters = null,
        Action<Tx, List<PickedFile>>? onResult = null,
        ulong window = 0)
        => Pick(false, filters, onResult, window);

    ulong Pick(
        bool multiple,
        (string Label, string Extensions)[]? filters,
        Action<Tx, List<PickedFile>>? onResult,
        ulong window)
    {
        ulong id = ++App.nextFileDialog;
        if (onResult != null)
            App.fileDialogs[id] = onResult;
        Records.Add(KayaWire.TxShowFileDialog(
            window, id, multiple ? 1u : 0u, FilterValues(filters)));
        return id;
    }

    /// Ask the platform WHERE TO SAVE. The picker's twin: a request that
    /// answers once with a capability, on the same grammar, out of the
    /// same one-live-dialog slot (docs/save-plan.md D2).
    ///
    /// `suggestedName` is the name the dialog OPENS with, and every
    /// platform treats it the way it treats a filter: it takes it, and
    /// guarantees nothing. The user renames it; Android may append an
    /// extension matching the mime type. Read the name you GOT.
    ///
    /// CANCEL IS null AND A DESTINATION IS A VALUE — the list the picker
    /// returns is narrowed HERE rather than in every guest.
    ///
    /// onResult fires exactly once and the registration retires with it.
    /// One dialog may be live per process WHICHEVER KIND IT IS, so a save
    /// and a pick cannot overlap; show the next from the handler.
    ///
    /// WHAT YOU GET BACK OPENS EMPTY. A save destination may not exist
    /// yet (macOS, GTK and Windows answer with a name for a file nobody
    /// has made — measured), so the handle's Open CREATES
    /// (docs/save-plan.md D1).
    public ulong SaveFile(
        string suggestedName,
        (string Label, string Extensions)[]? filters = null,
        Action<Tx, PickedFile?>? onResult = null,
        ulong window = 0)
    {
        // ONE ID SPACE AND ONE TABLE, shared with the picker: the core
        // keeps ONE live-dialog slot whichever kind is up, and the answer
        // arrives as the same file_dialog_result. A second counter would
        // mint an id the picker had already used.
        ulong id = ++App.nextFileDialog;
        if (onResult != null)
            // The narrowing lives at the REGISTRATION, so the dispatch
            // loop's one-shot removal serves both kinds unchanged.
            App.fileDialogs[id] = (tx, files) =>
                onResult(tx, files.Count == 0 ? (PickedFile?)null : files[0]);
        Records.Add(KayaWire.TxShowSaveDialog(
            window, id, suggestedName, FilterValues(filters)));
        return id;
    }

    /// The advisory filters' wire shape, shared by both dialog kinds:
    /// alternating Str values, a label then its space-separated
    /// extensions. One encoder because the core validates one encoding.
    static object[] FilterValues((string Label, string Extensions)[]? filters)
    {
        var values = new List<object>();
        foreach (var f in filters ?? Array.Empty<(string, string)>())
        {
            values.Add(f.Label);
            values.Add(f.Extensions);
        }
        return values.ToArray();
    }

    // --- The clipboard (DESIGN.md, Clipboard) ----------------------
    //
    // A clip is ONE item available in several types, so Copy takes a
    // record (a chain here, where a second Text() replaces the field)
    // and the two answers are a sum. kaya DERIVES NOTHING between
    // representations.

    /// Begin a clip: fill in as many representations as the app wants
    /// to offer, and Send puts it on the system clipboard.
    public CopyRef Copy() => new CopyRef(this);

    /// Begin the privileged read. Asking without a gesture is expensive
    /// on every platform: iOS 16 PROMPTS when the content came from
    /// another app and blocks until the user answers, Android returns
    /// nothing unless the app has focus, and Wayland delivers no offer
    /// to an unfocused client. Never implement Paste with this — that is
    /// the Paste command, and it is free.
    public ClipReadRef ReadClipboard() => new ClipReadRef(this, ++App.nextClipboardRead);

    /// Declare what a widget takes from a paste — the closed kinds by
    /// name ("text", "html", "image", "files") plus any custom format
    /// ids.
    ///
    /// ONE DECLARATION, THREE JOBS: it drives whether the Paste command
    /// is live while this widget is focused, it filters what can reach
    /// the paste hook, and on Android it IS the native registration
    /// (setOnReceiveContentListener takes the mime types on the view).
    ///
    /// DECLARING IS HOW AN APP OVERRIDES THE DEFAULT. A widget that
    /// declares nothing gets the platform's own insertion and reports it
    /// through the ordinary change path.
    public void SetAccepts(Widget w, params string[] kinds) =>
        Records.Add(KayaWire.TxSetAccepts(w.Id, AcceptList(kinds)));

    /// Take pasted content at a live widget.
    ///
    /// COSTS NOTHING ON ANY PLATFORM, unlike ReadClipboard: a paste is a
    /// user gesture, so it is its own authorisation — iOS raises no
    /// prompt and the focus rules are satisfied by construction. Only
    /// fires for a widget that declared what it accepts.
    public void OnPaste(Widget w, Action<Tx, Representation> handler) =>
        App.widgetPastes[w.Id] = handler;

    /// A paste onto a stamped copy: the handler also receives the copy's
    /// key path, outermost first.
    public void OnPaste(Node n, Action<Tx, List<object>, Representation> handler) =>
        App.nodePastes[n.Id] = handler;

    /// Join an accept list: the closed kinds by name plus any custom
    /// ids, space separated.
    ///
    /// A LIST AND NOT A MASK, because half the set is open-ended. Ids
    /// reach every platform's registry verbatim, so they carry no spaces
    /// — which is what makes the join unambiguous.
    internal static string AcceptList(IEnumerable<string> kinds)
    {
        foreach (var kind in kinds)
            if (string.IsNullOrEmpty(kind) || kind.Contains(' '))
                throw new ArgumentException(
                    $"kaya: \"{kind}\" is not an accept-list entry — the closed "
                    + "kinds are \"text\", \"html\", \"image\" and \"files\", and a "
                    + "custom format id reaches the platform's own registry "
                    + "verbatim, so it carries no spaces");
        return string.Join(" ", kinds);
    }

    /// Close and forget an auxiliary window — also the veto grammar's
    /// confirmation and the reconciliation after a chrome close.
    public void DestroyWindow(ulong id) => Records.Add(KayaWire.TxDestroyWindow(id));

    /// Push a navigation entry onto the primary surface's stack (entry
    /// ids are guest-allocated in the shared surface namespace).
    /// Materializes covered; MountIn presents it.
    ///
    /// onPopped fires when the user's back affordance pops THIS entry
    /// natively (post-fact; a programmatic PopEntry does not fire it)
    /// and retires with the one pop. onBackRequested fires per back
    /// request while interceptBack is armed — nothing has popped; answer
    /// with tx.PopEntry to agree.
    public void PushEntry(
        ulong id, string? title = null, bool? interceptBack = null,
        Action<Tx>? onPopped = null, Action<Tx>? onBackRequested = null,
        ulong window = 0)
    {
        Records.Add(KayaWire.TxPushEntry(window, id));
        if (title is { } t) Records.Add(KayaWire.TxSetEntryTitle(id, t));
        if (interceptBack is { } i) Records.Add(KayaWire.TxSetEntryInterceptBack(id, i));
        if (onPopped is { } p) App.entryPopped[id] = p;
        if (onBackRequested is { } b) App.backRequested[id] = b;
    }

    /// Pop the window's top navigation entry and forget its tree —
    /// also the back-veto grammar's confirmation after
    /// OnBackRequested. Popping an empty stack is a scene error.
    public void PopEntry(ulong window = 0) => Records.Add(KayaWire.TxPopEntry(window));

    /// Append a section to the window's section set (section ids are
    /// guest-allocated in the shared surface namespace); the set is
    /// append-only, and every section's root is retained while covered —
    /// switching is SELECTION, not lifecycle. MountIn fills its pane.
    ///
    /// onSelected fires each time the USER switches to it — post-fact
    /// and NOT one-shot; a programmatic SelectSection does not fire it.
    /// `symbol:` is the switcher item's SEMANTIC ICON (Symbol).
    public void AddSection(
        ulong id, string? title = null, Symbol? symbol = null,
        Action<Tx>? onSelected = null, ulong window = 0)
    {
        Records.Add(KayaWire.TxAddSection(window, id));
        if (title is { } t) Records.Add(KayaWire.TxSetSectionTitle(id, t));
        if (symbol is Symbol s)
            Records.Add(KayaWire.TxSetSectionSymbol(id, (long)s));
        if (onSelected is { } fn) App.sectionSelected[id] = fn;
    }

    /// Select a section programmatically: configuration, never echoes
    /// onSelected (the echo doctrine).
    public void SelectSection(ulong id, ulong window = 0) =>
        Records.Add(KayaWire.TxSelectSection(window, id));

    // --- Menus: the command vocabulary (DESIGN.md, Menus) ------------
    //
    // Children are arguments (evaluated first, unanchored), the grouping
    // construct appends them, and the window construct's menus:
    // parameter is the bar anchor. Items are live-zone only; a retained
    // item reopens through tx.Menu(item, ...).

    MenuItem NewMenuItem(uint kind, TextSource? label)
    {
        if (App.TplDepth > 0)
            throw new InvalidOperationException(
                "kaya: menu items are live — build the context catalog in the "
                + "live zone (tx.ContextCatalog) and attach it inside the "
                + "template with Tpl.ContextMenu");
        var m = App.NextMenuItem();
        Records.Add(KayaWire.TxMenuItemCreate(m.Id, kind));
        if (label is { } l)
            MenuLabel(m, l);
        return m;
    }

    void MenuLabel(MenuItem m, TextSource label)
    {
        if (label.Bind is Signal s)
            Records.Add(KayaWire.TxBindMenuLabel(m.Id, s.Id));
        else
            Records.Add(KayaWire.TxSetMenuLabel(m.Id, label.Text));
    }

    void MenuEnabled(MenuItem m, BoolSource enabled)
    {
        if (enabled.Bind is Signal s)
            Records.Add(KayaWire.TxBindMenuEnabled(m.Id, s.Id));
        else
            Records.Add(KayaWire.TxSetMenuEnabled(m.Id, enabled.Value));
    }

    void MenuChecked(MenuItem m, BoolSource isChecked)
    {
        if (isChecked.Bind is Signal s)
            Records.Add(KayaWire.TxBindMenuChecked(m.Id, s.Id));
        else
            Records.Add(KayaWire.TxSetMenuChecked(m.Id, isChecked.Value));
    }

    void MenuValue(MenuItem m, IndexSource value)
    {
        if (value.Bind is Signal s)
            Records.Add(KayaWire.TxBindMenuValue(m.Id, s.Id));
        else
            Records.Add(KayaWire.TxSetMenuValue(m.Id, value.Value));
    }

    // The tail every item kind shares. `symbol` rides here beside
    // `icon`: they are the two answers to the same question, and one
    // place to spell them is one place for a kind to forget them.
    void MenuTail(MenuItem m, BoolSource? enabled, byte[] icon, Symbol? symbol = null)
    {
        if (enabled is { } e) MenuEnabled(m, e);
        if (icon != null) Records.Add(KayaWire.TxSetMenuIcon(m.Id, Kaya.RegisterBlob(icon)));
        if (symbol is Symbol s) MenuSymbol(m, s);
    }

    void MenuSymbol(MenuItem m, Symbol symbol) =>
        Records.Add(KayaWire.TxSetMenuSymbol(m.Id, (long)symbol));

    void MenuAppendAll(MenuItem parent, MenuItem[] children)
    {
        if (children == null)
            return;
        foreach (var child in children)
            Records.Add(KayaWire.TxMenuItemAppend(parent.Id, child.Id));
    }

    /// The closed standard-command vocabulary (DESIGN.md, Menus):
    /// macOS places this one in the application menu, and every other
    /// host leaves the item where the app declared it.
    // A NAMED VOCABULARY FOR THE CLOSED HALF of the accept list, because
    // A MISTYPED BARE STRING IS SILENT: it becomes a custom format id no
    // clipboard will ever offer, so Paste stays dead and the paste hook
    // never fires, with nothing to see anywhere.
    public const string AcceptText = "text";
    public const string AcceptHtml = "html";
    public const string AcceptImage = "image";
    public const string AcceptFiles = "files";

    public const string RoleSettings = "settings";

    /// The three clipboard commands. They lower to the platform's own,
    /// act on the FOCUSED widget, and work out their own enablement
    /// from what the clipboard offers and what that widget accepts.
    ///
    /// GESTURES ARE COMMANDS BECAUSE KAYA HAS NO SELECTION API: only the
    /// widget knows what is selected. Copy() and ReadClipboard() are for
    /// overriding that default and for targets with no native behaviour.
    public const string RoleCut = "cut";
    public const string RoleCopy = "copy";
    public const string RolePaste = "paste";

    /// Undo and Redo act on the FOCUSED widget first — a text field
    /// whose own stack has something to give answers before the core's
    /// ledger does — and configure their own enablement
    /// (docs/undo-plan.md D6). An app declares the two items and writes
    /// nothing else.
    public const string RoleUndo = "undo";
    public const string RoleRedo = "redo";

    /// An action — a leaf command firing exactly one menu_activated
    /// occurrence for a menu click OR its shortcut. The shortcut is
    /// canonicalized by the binding's one parser; the root judges its
    /// anchor (window catalogs only).
    public MenuItem Item(TextSource label, string shortcut = null,
        BoolSource? enabled = null, byte[] icon = null, Symbol? symbol = null,
        bool primary = false, string role = null, Action<Tx> onActivate = null)
    {
        var m = NewMenuItem(KayaWire.MenuKindAction, label);
        if (shortcut != null) Records.Add(KayaWire.TxSetMenuShortcut(m.Id, shortcut));
        if (role != null) Records.Add(KayaWire.TxSetMenuRole(m.Id, role));
        MenuTail(m, enabled, icon, symbol);
        if (primary) Records.Add(KayaWire.TxSetMenuPrimary(m.Id, true));
        if (onActivate != null) App.menuActivated[m.Id] = onActivate;
        return m;
    }

    /// The template-node flavor: an item attached to a stamped copy
    /// (tx.ContextCatalog + Tpl.ContextMenu) reports the copy's key
    /// path, outermost first. Context items take no shortcuts
    /// (root-checked).
    public MenuItem Item(TextSource label, Action<Tx, List<object>> onActivate,
        BoolSource? enabled = null, byte[] icon = null, Symbol? symbol = null)
    {
        var m = NewMenuItem(KayaWire.MenuKindAction, label);
        MenuTail(m, enabled, icon, symbol);
        App.menuActivatedNode[m.Id] = onActivate;
        return m;
    }

    /// A toggle — a stateful leaf reusing the Checkbox contract: user
    /// flips emit menu_toggled (the handler receives the new state);
    /// programmatic isChecked writes are QUIET (the echo doctrine).
    public MenuItem Toggle(TextSource label, BoolSource? isChecked = null,
        BoolSource? enabled = null, byte[] icon = null, Symbol? symbol = null,
        string shortcut = null, Action<Tx, bool> onToggle = null)
    {
        var m = NewMenuItem(KayaWire.MenuKindToggle, label);
        if (isChecked is { } c) MenuChecked(m, c);
        if (shortcut != null) Records.Add(KayaWire.TxSetMenuShortcut(m.Id, shortcut));
        MenuTail(m, enabled, icon, symbol);
        if (onToggle != null) App.menuToggled[m.Id] = onToggle;
        return m;
    }

    /// The template-node flavor of Toggle: the copy's keys, then the
    /// new state.
    public MenuItem Toggle(TextSource label, Action<Tx, List<object>, bool> onToggle,
        BoolSource? isChecked = null, BoolSource? enabled = null, byte[] icon = null,
        Symbol? symbol = null)
    {
        var m = NewMenuItem(KayaWire.MenuKindToggle, label);
        if (isChecked is { } c) MenuChecked(m, c);
        MenuTail(m, enabled, icon, symbol);
        App.menuToggledNode[m.Id] = onToggle;
        return m;
    }

    /// One labeled radio option, appended in declaration order — the
    /// order IS the index vocabulary the group's value selects over.
    public MenuItem Option(TextSource label, BoolSource? enabled = null,
        byte[] icon = null, Symbol? symbol = null, string shortcut = null)
    {
        var m = NewMenuItem(KayaWire.MenuKindRadioOption, label);
        if (shortcut != null) Records.Add(KayaWire.TxSetMenuShortcut(m.Id, shortcut));
        MenuTail(m, enabled, icon, symbol);
        return m;
    }

    /// Native grouping chrome: no label, no props, no handler.
    public MenuItem Separator() => NewMenuItem(KayaWire.MenuKindSeparator, null);

    /// A menu grouping node — at bar level (seat it through the window
    /// construct's menus: parameter) or nested (pass it in a parent's
    /// items:). Children arrive as arguments, already created; the
    /// menu appends them in order. Disabling a menu disables its
    /// subtree (the inherited-disabled contract).
    public MenuItem Menu(TextSource label, BoolSource? enabled = null,
        byte[] icon = null, Symbol? symbol = null, MenuItem[] items = null)
    {
        var m = NewMenuItem(KayaWire.MenuKindMenu, label);
        MenuAppendAll(m, items);
        MenuTail(m, enabled, icon, symbol);
        return m;
    }

    /// Reopen a RETAINED menu item — the append-at-any-time
    /// discipline: tx.Menu(file, label: "Document", items: new[] {
    /// publish }). Props mutate freely on every kind the prop applies
    /// to (the root judges kind and anchor rules); programmatic
    /// isChecked/value writes are configuration and stay QUIET.
    public void Menu(MenuItem item, TextSource? label = null,
        BoolSource? enabled = null, BoolSource? isChecked = null,
        IndexSource? value = null, byte[] icon = null, Symbol? symbol = null,
        bool? primary = null, string shortcut = null, string role = null,
        MenuItem[] items = null)
    {
        MenuAppendAll(item, items);
        if (label is { } l) MenuLabel(item, l);
        if (enabled is { } e) MenuEnabled(item, e);
        if (isChecked is { } c) MenuChecked(item, c);
        if (value is { } v) MenuValue(item, v);
        if (icon != null) Records.Add(KayaWire.TxSetMenuIcon(item.Id, Kaya.RegisterBlob(icon)));
        if (symbol is Symbol sym) MenuSymbol(item, sym);
        if (primary is { } p) Records.Add(KayaWire.TxSetMenuPrimary(item.Id, p));
        if (shortcut != null) Records.Add(KayaWire.TxSetMenuShortcut(item.Id, shortcut));
        if (role != null) Records.Add(KayaWire.TxSetMenuRole(item.Id, role));
    }

    /// A radio group — the Choice contract with the platform's
    /// checkmark idiom, admissible wherever a menu grouping node is
    /// (bar level via the window construct, nested via a parent's
    /// items:). options: only Option children (the closed grammar,
    /// root-checked); value is the selected 0-based index
    /// (programmatic writes are quiet); onSelect receives each USER
    /// pick's new index.
    public MenuItem RadioGroup(TextSource label, MenuItem[] options,
        IndexSource? value = null, BoolSource? enabled = null, byte[] icon = null,
        Symbol? symbol = null, Action<Tx, int> onSelect = null)
    {
        var m = NewMenuItem(KayaWire.MenuKindRadioGroup, label);
        MenuAppendAll(m, options);
        if (value is { } v) MenuValue(m, v);
        MenuTail(m, enabled, icon, symbol);
        if (onSelect != null) App.menuSelected[m.Id] = onSelect;
        return m;
    }

    /// The template-node flavor of RadioGroup: the copy's keys, then
    /// the new index.
    public MenuItem RadioGroup(TextSource label, MenuItem[] options,
        Action<Tx, List<object>, int> onSelect, IndexSource? value = null,
        BoolSource? enabled = null, byte[] icon = null, Symbol? symbol = null)
    {
        var m = NewMenuItem(KayaWire.MenuKindRadioGroup, label);
        MenuAppendAll(m, options);
        if (value is { } v) MenuValue(m, v);
        MenuTail(m, enabled, icon, symbol);
        App.menuSelectedNode[m.Id] = onSelect;
        return m;
    }

    /// A context menu on a LIVE widget: the same item vocabulary
    /// scoped to a NOUN, with the platform's own gesture (right-click,
    /// long-press). Calling it again appends more roots. The editable
    /// text controls (entry, textarea) reject attachment at the root;
    /// context items take no shortcuts.
    public void ContextMenu(Widget target, params MenuItem[] items)
    {
        foreach (var item in items)
            Records.Add(KayaWire.TxContextAttach(target.Id, item.Id));
    }

    /// Build a context catalog UNANCHORED — free root items for a
    /// template-node anchor (menu items are live and shared across
    /// stamped copies): Tpl.ContextMenu attaches it inside the
    /// template, and each activation carries the copy's key path.
    public ContextCatalog ContextCatalog(params MenuItem[] items) => new(items);

    /// Mount a root into a specific window; mounting presents an
    /// auxiliary.
    public void MountIn(ulong window, Widget root) =>
        Records.Add(KayaWire.TxMount(window, root.Id));

    public void Mount(Widget root) => Records.Add(KayaWire.TxMount(0, root.Id));
}

/// A template body: the same declaration vocabulary with template-node
/// ids, plus element bindings.
sealed class Tpl
{
    readonly Tx tx;

    internal Tpl(Tx enclosing) => tx = enclosing;

    // INTERNAL, for KayaRecords.CollectionOf(this Tpl): a type parameter
    // cannot ride on a method of this class the way Rust's
    // Tpl::collection does, so the record constructor is an extension
    // and needs the enclosing transaction. Not public — a guest that
    // reached the live zone from inside a template would cross zones.
    internal Tx Tx => tx;

    public Node Widget(uint kind)
    {
        var n = tx.App.NextNode();
        tx.Records.Add(KayaWire.TxCreateWidget(n.Id, kind));
        tx.AutoParent(n.Id);
        return n;
    }

    /// PRIVATE, and the visibility is the point: both zones' spellings
    /// read `.SetText(` and only the receiver's TYPE tells them apart,
    /// which no sweep over a guest can see — so the template one is not
    /// spellable and the compiler holds the line a regex could not (F3,
    /// docs/tpl-props-plan.md). KEEP IT PRIVATE.
    void SetText(Node n, string text) => tx.Records.Add(KayaWire.TxSetText(n.Id, text));

    /// Bind text to the element of the enclosing For, `level` Fors up
    /// (0 = nearest).
    public void BindTextElement(Node n, uint level = 0) =>
        tx.Records.Add(KayaWire.TxBindTextElement(n.Id, level));

    /// Bind a label's text to one field of the element; Field<string>
    /// only — the token pins the type at compile time.
    public void BindTextField(Node n, uint level, Field<string> f) =>
        tx.Records.Add(KayaWire.TxBindTextElement(n.Id, level, f.Index));

    public void BindCheckedField(Node n, uint level, Field<bool> f) =>
        tx.Records.Add(KayaWire.TxBindCheckedElement(n.Id, level, f.Index));

    /// Bind an image's source to one field of the element;
    /// Field<byte[]> only — the token pins the type at compile time.
    public void BindSourceField(Node n, uint level, Field<byte[]> f) =>
        tx.Records.Add(KayaWire.TxBindSourceElement(n.Id, level, f.Index));

    /// Bind a slider's, progress bar's or choice widget's value to one
    /// field of the element; Field&lt;double&gt; only. A choice's 0-based
    /// index rides a `double` record field too: `value` is an F64 prop
    /// and the root compares a bound field's declared type against the
    /// prop's exactly, so a Field&lt;long&gt; is rejected at declaration
    /// however integral the index is.
    public void BindValueField(Node n, uint level, Field<double> f) =>
        tx.Records.Add(KayaWire.TxBindValueElement(n.Id, level, f.Index));

    /// A template node's flex weight within its enclosing row or column
    /// — kind-agnostic, as the live Tx.SetGrow is.
    ///
    /// A floor setter and not a `grow:` argument, because a TEMPLATE
    /// constructor's arguments are its per-copy SOURCES and grow is one
    /// value for every copy.
    public void SetGrow(Node n, double weight) =>
        tx.Records.Add(KayaWire.TxSetGrow(n.Id, weight));

    /// A stamped copy's accessibility IDENTIFIER: the stable authored
    /// key assistive tooling and UI automation address it by, and which
    /// is NEVER spoken. Universal, in both zones.
    ///
    /// A CONST OR SIGNAL GIVES EVERY COPY THE SAME KEY, and nothing
    /// catches the collision. Source it from a field the row carries
    /// when automation must tell the copies apart.
    public void SetA11yId(Node n, string id) =>
        tx.Records.Add(KayaWire.TxSetA11yId(n.Id, id));

    public void SetA11yId(Node n, Signal s) =>
        tx.Records.Add(KayaWire.TxBindA11yId(n.Id, s.Id));

    public void SetA11yId(Node n, Field<string> f, uint level = 0) =>
        tx.Records.Add(KayaWire.TxBindA11yIdElement(n.Id, level, f.Index));

    /// What an assistive client SPEAKS for a stamped copy. Universal.
    /// Leave it unset to keep whatever the platform derives from the
    /// control's own content.
    ///
    /// THE FIELD ARM IS THE CASE THIS ZONE EXISTS FOR: one label per
    /// copy, so a list of images does not speak as N unlabelled images.
    public void SetA11yLabel(Node n, string label) =>
        tx.Records.Add(KayaWire.TxSetA11yLabel(n.Id, label));

    public void SetA11yLabel(Node n, Signal s) =>
        tx.Records.Add(KayaWire.TxBindA11yLabel(n.Id, s.Id));

    public void SetA11yLabel(Node n, Field<string> f, uint level = 0) =>
        tx.Records.Add(KayaWire.TxBindA11yLabelElement(n.Id, level, f.Index));

    /// What ACTIVATING a stamped copy does — write a verb phrase. The
    /// field arm is a row of Delete buttons each naming what it deletes.
    ///
    /// ACTIVATION KINDS ONLY (button, checkbox, select, radio), and the
    /// wall is the root's, not a type here: a hint on a template label
    /// dies at SUBMIT of the transaction that wrote it, naming the kind
    /// and the prop, before a single row stamps.
    public void SetA11yHint(Node n, string hint) =>
        tx.Records.Add(KayaWire.TxSetA11yHint(n.Id, hint));

    public void SetA11yHint(Node n, Signal s) =>
        tx.Records.Add(KayaWire.TxBindA11yHint(n.Id, s.Id));

    public void SetA11yHint(Node n, Field<string> f, uint level = 0) =>
        tx.Records.Add(KayaWire.TxBindA11yHintElement(n.Id, level, f.Index));

    /// Declare what every stamped copy takes from a paste — the closed
    /// kinds by name ("text", "html", "image", "files") plus any custom
    /// format ids. Entry and textarea only; the root rejects it
    /// elsewhere, at submit, like the hint above.
    ///
    /// WITHOUT THIS THE NODE PASTE HOOK NEVER FIRES: every backend falls
    /// back to the platform's own insertion when the focused control's
    /// accept list is empty, and emits no occurrence at all.
    ///
    /// CONSTANT ONLY, unlike the three props above: an accept list
    /// describes the PROTOTYPE'S ROLE, which is one fact for every copy.
    public void SetAccepts(Node n, params string[] kinds) =>
        tx.Records.Add(KayaWire.TxSetAccepts(n.Id, Tx.AcceptList(kinds)));

    /// What a stamped copy MEANS — semantic emphasis, never appearance.
    ///
    /// CONST, like SetAccepts above and for its reason. The root refuses
    /// a role on a kind it does not fit at DECLARE time, naming both,
    /// before a single row stamps — which is why there is no type-level
    /// wall here.
    public void SetRole(Node n, Role role) =>
        tx.Records.Add(KayaWire.TxSetRole(n.Id, (long)role));

    /// A stamped CONTAINER's own padding: DIP between its bounds and its
    /// children, uniform on all four sides — the same number the live
    /// Tx.SetInset spells. Const for SetRole's reason. Containers only,
    /// and the root says so at declare time.
    public void SetInset(Node n, double pad) =>
        tx.Records.Add(KayaWire.TxSetInset(n.Id, pad));

    // Construction sugar, template flavor: one name per widget, the
    // argument's type picks the addressable source (constant, signal,
    // or element field); handlers receive the stamped copy's keys
    // first.
    public Node Label(string text)
    {
        var n = Widget(KayaWire.KindLabel);
        tx.Records.Add(KayaWire.TxSetText(n.Id, text));
        return n;
    }

    public Node Label(Signal s)
    {
        var n = Widget(KayaWire.KindLabel);
        tx.Records.Add(KayaWire.TxBindText(n.Id, s.Id));
        return n;
    }

    public Node Label(Field<string> f)
    {
        var n = Widget(KayaWire.KindLabel);
        BindTextField(n, 0, f);
        return n;
    }

    /// A stamped label wearing the heading role — the h1 tradition, in
    /// one word. Caption below is its counterpart.
    public Node Heading(string text) => WithRole(Label(text), Role.Heading);

    public Node Heading(Signal s) => WithRole(Label(s), Role.Heading);

    public Node Heading(Field<string> f) => WithRole(Label(f), Role.Heading);

    /// A stamped label wearing the caption role: the footnote tier under
    /// the content it explains.
    public Node Caption(string text) => WithRole(Label(text), Role.Caption);

    public Node Caption(Signal s) => WithRole(Label(s), Role.Caption);

    public Node Caption(Field<string> f) => WithRole(Label(f), Role.Caption);

    Node WithRole(Node n, Role role)
    {
        SetRole(n, role);
        return n;
    }

    /// A button with its caption, in the blueprint: the template twin of
    /// Tx.Button. The argument's type picks the caption's source.
    ///
    /// IT TAKES NO HANDLER, and the omission is the design: a stamped
    /// copy's click names the copy, so the handler goes on the TEMPLATE
    /// NODE — app.OnClick(node, (tx, keys) => …).
    public Node Button(string text)
    {
        var n = Widget(KayaWire.KindButton);
        SetText(n, text);
        return n;
    }

    public Node Button(Signal s)
    {
        var n = Widget(KayaWire.KindButton);
        tx.Records.Add(KayaWire.TxBindText(n.Id, s.Id));
        return n;
    }

    /// A button captioned from the row's OWN field — the "Delete
    /// &lt;that row's title&gt;" shape, which only this zone can spell.
    /// The live zone has no twin: a live button has no row to read.
    public Node Button(Field<string> f)
    {
        var n = Widget(KayaWire.KindButton);
        BindTextField(n, 0, f);
        return n;
    }

    /// An image over constant encoded bytes: every stamped copy shows
    /// the same asset.
    public Node Image(byte[] source)
    {
        var n = Widget(KayaWire.KindImage);
        tx.Records.Add(KayaWire.TxSetSource(n.Id, Kaya.RegisterBlob(source)));
        return n;
    }

    public Node Image(Signal s)
    {
        var n = Widget(KayaWire.KindImage);
        tx.Records.Add(KayaWire.TxBindSource(n.Id, s.Id));
        return n;
    }

    public Node Image(Field<byte[]> f)
    {
        var n = Widget(KayaWire.KindImage);
        BindSourceField(n, 0, f);
        return n;
    }

    /// A canvas per stamped copy — a sparkline in a table cell, which is
    /// the case set_drawing grew its keys-first addressing for
    /// (docs/canvas-plan.md §3.1). The drawing is declared with the node,
    /// so every copy is born with it; Tx.Draw(Node, keys, …) re-declares
    /// one copy's afterwards.
    ///
    /// NO SIZE POLICY HERE, AND THE COMPILER IS THE REFUSAL: Fixed,
    /// OnDraw and OnTick are Widget's and Node does not carry them, so a
    /// canvas in a row template is `scale` — the default, and correct
    /// (docs/deferred.md, THE TEMPLATE ZONE IS REFUSED, LOUDLY, under the
    /// size-policy entry; the core panics naming it too).
    public Node Canvas(Viewbox viewbox, Action<Draw> body)
    {
        var n = Widget(KayaWire.KindCanvas);
        var d = new Draw(viewbox);
        body(d);
        tx.Records.Add(KayaWire.TxSetDrawing(n.Id, viewbox.W, viewbox.H,
            (uint)d.Ops.Count, 0, d.Ops.ToArray()));
        return n;
    }

    public Node Checkbox(Field<bool> f, Action<Tx, List<object>, bool> onToggle = null)
    {
        var n = Widget(KayaWire.KindCheckbox);
        BindCheckedField(n, 0, f);
        if (onToggle != null) tx.App.OnToggle(n, onToggle);
        return n;
    }

    /// A single-line text field in the blueprint, one copy per stamped
    /// row. UNCONTROLLED, which is why the default overload takes no
    /// source: the copy owns its text and each edit arrives at onChange
    /// with that copy's keys, outermost first.
    ///
    /// The three below SEED the copy instead. Seeding does not make the
    /// entry controlled — a later write to the source pushes into every
    /// copy quietly, replacing what the user typed, so seed from a field
    /// the app writes on commit and not on keystroke.
    public Node Entry(Action<Tx, List<object>, string> onChange = null)
    {
        var n = Widget(KayaWire.KindEntry);
        if (onChange != null) tx.App.OnChange(n, onChange);
        return n;
    }

    public Node Entry(string text, Action<Tx, List<object>, string> onChange = null)
    {
        var n = Entry(onChange);
        SetText(n, text);
        return n;
    }

    public Node Entry(Signal text, Action<Tx, List<object>, string> onChange = null)
    {
        var n = Entry(onChange);
        tx.Records.Add(KayaWire.TxBindText(n.Id, text.Id));
        return n;
    }

    public Node Entry(Field<string> text, Action<Tx, List<object>, string> onChange = null)
    {
        var n = Entry(onChange);
        BindTextField(n, 0, text);
        return n;
    }

    /// A multi-line editor in the blueprint: Entry's contract over the
    /// platform's real multi-line control, with the same four arms for
    /// the same reason.
    public Node Textarea(Action<Tx, List<object>, string> onChange = null)
    {
        var n = Widget(KayaWire.KindTextarea);
        if (onChange != null) tx.App.OnChange(n, onChange);
        return n;
    }

    public Node Textarea(string text, Action<Tx, List<object>, string> onChange = null)
    {
        var n = Textarea(onChange);
        SetText(n, text);
        return n;
    }

    public Node Textarea(Signal text, Action<Tx, List<object>, string> onChange = null)
    {
        var n = Textarea(onChange);
        tx.Records.Add(KayaWire.TxBindText(n.Id, text.Id));
        return n;
    }

    public Node Textarea(Field<string> text, Action<Tx, List<object>, string> onChange = null)
    {
        var n = Textarea(onChange);
        BindTextField(n, 0, text);
        return n;
    }

    /// A progress bar in the blueprint: display-only. The fraction
    /// (0..=1, domain-checked at the root) comes from any addressable
    /// source.
    public Node Progress(double value)
    {
        var n = Widget(KayaWire.KindProgress);
        tx.Records.Add(KayaWire.TxSetValue(n.Id, value));
        return n;
    }

    public Node Progress(Signal value)
    {
        var n = Widget(KayaWire.KindProgress);
        tx.Records.Add(KayaWire.TxBindValue(n.Id, value.Id));
        return n;
    }

    public Node Progress(Field<double> value)
    {
        var n = Widget(KayaWire.KindProgress);
        BindValueField(n, 0, value);
        return n;
    }

    /// A progress bar in the platform's activity mode: no fraction, so
    /// nothing to source, which is why it is its own constructor rather
    /// than a flag on the three above.
    public Node ProgressIndeterminate()
    {
        var n = Widget(KayaWire.KindProgress);
        tx.Records.Add(KayaWire.TxSetIndeterminate(n.Id, true));
        return n;
    }

    /// A slider over min..max in the blueprint, its POSITION from any
    /// addressable source and its change handler co-located.
    ///
    /// THE RANGE IS CONSTANT AND THE POSITION IS THE SOURCE: min and max
    /// describe the prototype, so every copy shares them.
    public Node Slider(double min, double max, double value,
        Action<Tx, List<object>, double> onChange = null)
    {
        var n = SliderOf(min, max, onChange);
        tx.Records.Add(KayaWire.TxSetValue(n.Id, value));
        return n;
    }

    public Node Slider(double min, double max, Signal value,
        Action<Tx, List<object>, double> onChange = null)
    {
        var n = SliderOf(min, max, onChange);
        tx.Records.Add(KayaWire.TxBindValue(n.Id, value.Id));
        return n;
    }

    public Node Slider(double min, double max, Field<double> value,
        Action<Tx, List<object>, double> onChange = null)
    {
        var n = SliderOf(min, max, onChange);
        BindValueField(n, 0, value);
        return n;
    }

    Node SliderOf(double min, double max, Action<Tx, List<object>, double> onChange)
    {
        var n = Widget(KayaWire.KindSlider);
        tx.Records.Add(KayaWire.TxSetMin(n.Id, min));
        tx.Records.Add(KayaWire.TxSetMax(n.Id, max));
        if (onChange != null) tx.App.OnValueChanged(n, onChange);
        return n;
    }

    /// A dropdown select in the blueprint, with the SELECTED INDEX from
    /// any addressable source: onSelect receives the stamped copy's
    /// keys, outermost first, and each USER pick's new 0-based index.
    ///
    /// THE OPTIONS ARE PER-TEMPLATE, NOT PER-ROW: the prototype is
    /// stamped verbatim, so a per-copy option LIST would be a per-copy
    /// blueprint (docs/sugar-pass-plan.md §2).
    public Node Select(string[] options, int selected,
        Action<Tx, List<object>, int> onSelect = null) =>
        Choice(KayaWire.KindSelect, options, selected, onSelect);

    public Node Select(string[] options, Signal selected,
        Action<Tx, List<object>, int> onSelect = null) =>
        Choice(KayaWire.KindSelect, options, selected, onSelect);

    public Node Select(string[] options, Field<double> selected,
        Action<Tx, List<object>, int> onSelect = null) =>
        Choice(KayaWire.KindSelect, options, selected, onSelect);

    public Node Radio(string[] options, int selected,
        Action<Tx, List<object>, int> onSelect = null) =>
        Choice(KayaWire.KindRadio, options, selected, onSelect);

    public Node Radio(string[] options, Signal selected,
        Action<Tx, List<object>, int> onSelect = null) =>
        Choice(KayaWire.KindRadio, options, selected, onSelect);

    public Node Radio(string[] options, Field<double> selected,
        Action<Tx, List<object>, int> onSelect = null) =>
        Choice(KayaWire.KindRadio, options, selected, onSelect);

    Node Choice(uint kind, string[] options, int selected,
        Action<Tx, List<object>, int> onSelect)
    {
        var n = ChoiceOf(kind, options, onSelect);
        tx.Records.Add(KayaWire.TxSetValue(n.Id, selected));
        return n;
    }

    Node Choice(uint kind, string[] options, Signal selected,
        Action<Tx, List<object>, int> onSelect)
    {
        var n = ChoiceOf(kind, options, onSelect);
        tx.Records.Add(KayaWire.TxBindValue(n.Id, selected.Id));
        return n;
    }

    Node Choice(uint kind, string[] options, Field<double> selected,
        Action<Tx, List<object>, int> onSelect)
    {
        var n = ChoiceOf(kind, options, onSelect);
        BindValueField(n, 0, selected);
        return n;
    }

    /// The option children and the handler — everything a choice widget
    /// has before its selected index.
    Node ChoiceOf(uint kind, string[] options, Action<Tx, List<object>, int> onSelect)
    {
        var n = Widget(kind);
        tx.App.Parents.Add(n.Id);
        foreach (var option in options)
        {
            var o = Widget(KayaWire.KindLabel);
            SetText(o, option);
        }
        tx.App.Parents.RemoveAt(tx.App.Parents.Count - 1);
        if (onSelect != null)
            tx.App.OnValueChanged(n, (t2, keys, v) => onSelect(t2, keys, (int)v));
        return n;
    }

    public Node Column(Action body) => ContainerOf(KayaWire.KindColumn, body);

    public Node Row(Action body) => ContainerOf(KayaWire.KindRow, body);

    /// A vertical scroll viewport over EXACTLY ONE child, per stamped
    /// copy. SetGrow it so the enclosing track CONSTRAINS it — an
    /// unconstrained viewport hugs its content and nothing overflows.
    public Node Scroll(Action body) => ContainerOf(KayaWire.KindScroll, body);

    /// A grid laying each stamped copy's children out row-major into
    /// `columns` columns — each column takes its NATURAL width, aligned
    /// across rows. The column count describes the PROTOTYPE, so it is a
    /// constant and not a source.
    public Node Grid(int columns, Action body)
    {
        var n = ContainerOf(KayaWire.KindGrid, body);
        tx.Records.Add(KayaWire.TxSetColumns(n.Id, columns));
        return n;
    }

    /// A spacer: PURE SUGAR for an empty grown column, in every stamped
    /// copy.
    public Node Spacer()
    {
        var n = Widget(KayaWire.KindColumn);
        SetGrow(n, 1.0);
        return n;
    }

    Node ContainerOf(uint kind, Action body)
    {
        var parent = Widget(kind);
        tx.App.Parents.Add(parent.Id);
        body?.Invoke();
        tx.App.Parents.RemoveAt(tx.App.Parents.Count - 1);
        return parent;
    }

    public void AddChild(Node parent, Node child) =>
        tx.Records.Add(KayaWire.TxAddChild(parent.Id, child.Id));

    /// Attach a live-built context catalog (tx.ContextCatalog) to a
    /// template node: every stamped copy shows the same catalog, and
    /// each activation carries that copy's key path. An item takes
    /// exactly one anchor, so a second attach throws here.
    public void ContextMenu(Node n, ContextCatalog catalog)
    {
        if (catalog.Attached)
            throw new InvalidOperationException(
                "kaya: a context catalog takes exactly one anchor");
        catalog.Attached = true;
        foreach (var root in catalog.Roots)
            tx.Records.Add(KayaWire.TxContextAttachNode(n.Id, root.Id));
    }

    public Collection Collection() => tx.Collection();

    /// A nested For as a child: ForEach whose body keeps no handles.
    ///
    /// A C# lambda captures its enclosing locals BY REFERENCE, so a
    /// handle the body owes the outside is assigned to the scene's own
    /// local rather than threaded back through a result — which is why
    /// this returns the For alone.
    public Node Each(Collection c, Action<Tpl> body) => ForEach(c, body);

    /// <summary>Declare the header bar of a NESTED For — the Node Each
    /// hands back — for every copy stamped from this template. One
    /// title per column; the nested row template's root must be a Row
    /// of exactly one cell per column, refused loudly otherwise. A
    /// copy's own indicator comes later, from tx.Columns(node, keys, …).
    ///
    /// CALL IT AFTER THE FOR CLOSES, in the enclosing template body: the
    /// nested For folds into the open parent scope at its TemplateEnd,
    /// and that is where this record looks for it (docs/tables-plan.md,
    /// measured in slice 1).</summary>
    public void Columns(Node n, string[] titles, Sort sort)
    {
        // pathLen 0 with a TEMPLATE NODE: the bar every stamp emits
        // (docs/tables-plan.md, dynamic tables).
        tx.Records.Add(KayaWire.TxSetColumnHeaders(
            n.Id, sort.Sorted, sort.Direction, (uint)titles.Length, 0,
            Tx.HeaderValues(Array.Empty<object>(), titles)));
    }

    public Node ForEach(Collection c, Action<Tpl> body)
    {
        c.AssertRoot();
        var n = tx.App.NextNode();
        ulong parent = tx.CurrentParent();
        tx.Records.Add(KayaWire.TxCreateFor(n.Id, c.Id));
        tx.App.OpenFors.Add(c.Id);
        tx.App.Parents.Add(0);
        tx.App.TplDepth++;
        try
        {
            body(new Tpl(tx));
        }
        finally
        {
            tx.App.TplDepth--;
        }
        tx.App.Parents.RemoveAt(tx.App.Parents.Count - 1);
        tx.App.OpenFors.RemoveAt(tx.App.OpenFors.Count - 1);
        tx.Records.Add(KayaWire.TxTemplateEnd());
        if (parent != 0)
            tx.Records.Add(KayaWire.TxAddChild(parent, n.Id));
        return n;
    }

    public Node When(Signal s, Action<Tpl> body)
    {
        var n = tx.App.NextNode();
        ulong parent = tx.CurrentParent();
        tx.Records.Add(KayaWire.TxCreateWhen(n.Id, s.Id));
        tx.App.Parents.Add(0);
        tx.App.TplDepth++;
        try
        {
            body(new Tpl(tx));
        }
        finally
        {
            tx.App.TplDepth--;
        }
        tx.App.Parents.RemoveAt(tx.App.Parents.Count - 1);
        tx.Records.Add(KayaWire.TxTemplateEnd());
        if (parent != 0)
            tx.Records.Add(KayaWire.TxAddChild(parent, n.Id));
        return n;
    }
}


/// The copy chain: a clip record under construction. Each method fills
/// one representation, and Send puts it on the clipboard.
///
/// A RECORD AND NOT A LIST: at most one per kind is structural, since a
/// second Text() replaces the field.
sealed class CopyRef
{
    readonly Tx tx;
    string? text;
    string? html;
    byte[]? image;
    readonly List<ulong> files = new();
    readonly List<(string Id, byte[] Bytes)> custom = new();

    internal CopyRef(Tx tx) => this.tx = tx;

    public CopyRef Text(string value) { text = value; return this; }

    public CopyRef Html(string value) { html = value; return this; }

    public CopyRef Image(byte[] bytes) { image = bytes; return this; }

    /// Offer a picked file, the picker's own capability put straight on
    /// the clipboard. The bytes never move through kaya.
    public CopyRef File(PickedFile f) { files.Add(f.Handle); return this; }

    /// An app-defined format, round-tripped verbatim. The id reaches
    /// every platform's own registry unchanged — a UTI on Apple,
    /// RegisterClipboardFormat on Windows, a target atom on X11 and
    /// Wayland, a MIME type on Android — so it carries no spaces.
    public CopyRef Custom(string id, byte[] bytes)
    {
        Tx.AcceptList(new[] { id });
        custom.Add((id, bytes));
        return this;
    }

    /// Put the clip on the system clipboard. The wire order is kaya's,
    /// not this chain's — descending richness, which is preference
    /// order on every host that has one.
    public void Send()
    {
        uint present = 0;
        var values = new List<object>();
        foreach (var (id, bytes) in custom)
        {
            values.Add(id);
            values.Add(new KayaWire.BlobHandle(Kaya.RegisterBlob(bytes)));
        }
        foreach (var handle in files)
            values.Add((long)handle);
        if (image != null)
        {
            present |= KayaWire.ClipImage;
            values.Add(new KayaWire.BlobHandle(Kaya.RegisterBlob(image)));
        }
        if (html != null)
        {
            present |= KayaWire.ClipHtml;
            values.Add(html);
        }
        if (text != null)
        {
            present |= KayaWire.ClipText;
            values.Add(text);
        }
        tx.Records.Add(KayaWire.TxCopy(
            present, (uint)files.Count, (uint)custom.Count, values.ToArray()));
    }
}

/// The read chain: which representations this read can use, and the
/// request id its one answer arrives under.
sealed class ClipReadRef
{
    readonly Tx tx;
    readonly ulong id;
    readonly List<string> accepting = new();
    Action<Tx, Representation?>? onResult;

    internal ClipReadRef(Tx tx, ulong id)
    {
        this.tx = tx;
        this.id = id;
    }

    public ClipReadRef Text() => Accept("text");
    public ClipReadRef Html() => Accept("html");
    public ClipReadRef Image() => Accept("image");
    public ClipReadRef Files() => Accept("files");

    /// Accept an app-defined format by id. Custom formats are tried
    /// FIRST, in the order named.
    public ClipReadRef Custom(string formatId) => Accept(formatId);

    ClipReadRef Accept(string kind)
    {
        accepting.Add(kind);
        return this;
    }

    /// Bind the one-shot handler to THIS request. The answer is null
    /// when the clipboard had nothing this read accepted — and null
    /// equally when the read was denied or the app was unfocused,
    /// because no platform says which.
    public ClipReadRef OnResult(Action<Tx, Representation?> handler)
    {
        onResult = handler;
        return this;
    }

    public ulong Send()
    {
        if (onResult != null)
            tx.App.clipboardReads[id] = onResult;
        tx.Records.Add(KayaWire.TxReadClipboard(id, Tx.AcceptList(accepting)));
        return id;
    }
}
