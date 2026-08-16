//! The scene core: signal and collection storage, the binding indexes,
//! the template registry, and the stamping machinery. Transactions come
//! in; resolved apply-ops come out. This is the whole of kaya's
//! reactivity — backends apply what this module emits and never see a
//! signal, a collection, or a template.
//!
//! Structure follows the milestone-2 design: a For binds a collection
//! and stamps one copy of its template per entry; a When is For over a
//! zero-or-one collection wired to a Bool signal. Stamped widgets get
//! core-allocated internal ids (top bit set — opaque to backends, never
//! guest-visible); the guest-visible name of a copy is (template node,
//! key path), which interactive widgets carry pre-encoded as a click
//! tag. Everything inside a For is reproducible from template plus
//! collection data, so teardown is always safe.
//!
//! Lives on the UI thread, one instance per core. Validation fails
//! loudly: every panic here is a broken guest or binding, not a runtime
//! condition (the same policy as the full ring).

use std::collections::HashMap;
use std::sync::Arc;

use crate::protocol::{
    ApplyOp, CollectionId, CommandKind, EntryProp, Key, MenuItemId, MenuItemKind, MenuProp,
    NativeRange, Occurrence, Prop, PropValue, Record, SectionProp, SignalId, TextRange,
    Transaction, TxOp, UndoDelta, UndoEntry, UndoOrder, Value, ValueType, WidgetId, WidgetKind,
    WindowId, WindowProp,
};

/// Internal instance ids live above this bit; guest widget ids below it.
const INTERNAL_BIT: u64 = 1 << 63;

/// A copy's key path, in hashable form (wire paths are Vec<Value>).
type PathKey = Vec<Key>;

/// One collection entry, fully named: (collection, instance path, key).
type EntryRef = (CollectionId, PathKey, Key);

fn path_values(path: &PathKey) -> Vec<Value> {
    path.iter().map(Key::to_value).collect()
}

/// A template body op, the blueprint form of the creation vocabulary.
#[derive(Debug)]
enum TplOp {
    Widget { node: u64, kind: WidgetKind },
    SetProp { node: u64, prop: Prop, value: PropValue },
    AddChild { parent: u64, child: u64 },
    Collection { id: CollectionId },
    /// One body per variant of the collection's element sum, indexed by
    /// discriminant; a For over a record collection has exactly one.
    For { node: u64, collection: CollectionId, bodies: Vec<Arc<TplBody>> },
    When { node: u64, signal: SignalId, body: Arc<TplBody> },
    /// A context catalog attached to a template node: every stamped
    /// copy shows the shared `item` tree, and each stamp emits a
    /// CONTEXT_ATTACH_NODE apply carrying that copy's key path (the
    /// noun). Menu items are not stamped in v1 — the tree is shared, the
    /// path is what differs per copy.
    ContextAttachNode { node: u64, item: MenuItemId },
}

#[derive(Debug)]
struct TplBody {
    ops: Vec<TplOp>,
    /// Nodes with no parent inside the body, in declaration order; each
    /// stamp appends these to the structure's container.
    roots: Vec<u64>,
}

/// One variant case being parsed: the section of a For scope between
/// VariantCase records (or the whole scope when no case is declared —
/// the one-variant For).
struct TplSection {
    variant: u32,
    ops: Vec<TplOp>,
    /// Node ids declared in this section; AddChild/SetProp may only
    /// reference these — a case is a complete blueprint, so nodes never
    /// cross case boundaries.
    declared: Vec<u64>,
    /// Of `declared`, the ones already claimed as someone's child.
    childed: Vec<u64>,
}

impl TplSection {
    fn new(variant: u32) -> Self {
        TplSection {
            variant,
            ops: Vec::new(),
            declared: Vec::new(),
            childed: Vec::new(),
        }
    }

    fn into_body(self) -> (u32, Arc<TplBody>) {
        let roots = self
            .declared
            .iter()
            .filter(|n| !self.childed.contains(n))
            .copied()
            .collect();
        (self.variant, Arc::new(TplBody { ops: self.ops, roots }))
    }
}

/// A declaration scope being parsed (between CreateFor/CreateWhen and
/// its TemplateEnd).
struct TplScope {
    header: ScopeHeader,
    /// Cases already closed by a VariantCase record that followed them.
    closed: Vec<(u32, Arc<TplBody>)>,
    /// The section currently accepting records.
    current: TplSection,
    /// Whether any VariantCase record was seen: distinguishes the
    /// implicit one-variant scope from explicit case declarations.
    explicit_cases: bool,
    /// Unique id of this scope, for same-scope collection validation.
    scope: u64,
}

enum ScopeHeader {
    For { id: u64, collection: CollectionId },
    When { id: u64, signal: SignalId },
}

/// A closed scope's assembled blueprint(s), ready to fold into the
/// parent template or start rendering live.
enum ClosedScope {
    For { id: u64, collection: CollectionId, bodies: Vec<Arc<TplBody>> },
    When { id: u64, signal: SignalId, body: Arc<TplBody> },
}

struct CollDecl {
    /// The declaration scope (0 = live zone); a For may only bind a
    /// collection declared in its own scope.
    scope: u64,
    bound: bool,
    /// One ordered field-type list per variant of the element sum; a
    /// record collection is the one-variant case and a scalar
    /// collection the one-variant one-field case.
    variants: Vec<Vec<ValueType>>,
}

#[derive(Default)]
struct CollInstance {
    order: Vec<Key>,
    /// Each entry: the variant it currently holds, and that variant's
    /// fields. The variant is the eliminator's discriminant — stamping
    /// picks the case blueprint by it, and update_field's witnessed
    /// variant is asserted against it.
    entries: HashMap<Key, (u32, Record)>,
}

/// A live rendering site of a For: the (collection, instance path) it
/// renders, its container widget, and the element chain it was stamped
/// under. One body per variant; stamping picks by the entry's
/// discriminant.
struct ForSite {
    container: WidgetId,
    bodies: Vec<Arc<TplBody>>,
    chain: Vec<EntryRef>,
}

struct WhenSite {
    signal: SignalId,
    container: WidgetId,
    body: Arc<TplBody>,
    path: PathKey,
    chain: Vec<EntryRef>,
    stamp: Option<Stamp>,
}

/// Everything one stamped copy put into the world, for exact teardown.
#[derive(Default)]
struct Stamp {
    /// Internal widget ids in creation order; destroyed in reverse.
    widgets: Vec<WidgetId>,
    /// Which TEMPLATE NODE each of this copy's widgets came from — the
    /// map `run_body` builds while stamping, kept instead of thrown
    /// away.
    ///
    /// It is the translation between the copy's two names. A stamped
    /// widget has an internal id, which is what a programmatic write
    /// names and what the ledger keys on; the app knows the same widget
    /// as (template node, key path), which is what its occurrences
    /// carry and the only name it could resolve. Everything that has to
    /// cross between those two — banking a row's typing, and naming the
    /// restored text in an `undone` payload — reads this map.
    nodes: HashMap<u64, WidgetId>,
    /// The copy's root widgets (children of the For's container), in
    /// body order — what a move repositions.
    roots: Vec<WidgetId>,
    signal_binds: Vec<(SignalId, WidgetId)>,
    element_binds: Vec<(EntryRef, WidgetId)>,
    /// Collection instances born with this copy.
    colls: Vec<(CollectionId, PathKey)>,
    for_sites: Vec<(CollectionId, PathKey)>,
    when_sites: Vec<u64>,
}

/// Where a menu item's subtree root is anchored. Set once — an item
/// acquires exactly one parent OR one anchor (single-parent; DESIGN.md,
/// Menus).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum MenuAnchor {
    /// The window's command catalog (the bar). Carries the window so a
    /// later append into the subtree can dup-check against its catalog.
    Window(WindowId),
    /// A widget or template-node context menu.
    Context,
}

/// One menu item's core state: its kind, its single parent (or None for
/// a root), its anchor (or None until anchored), its children in append
/// order, and its own canonical shortcut spelling (action-only).
struct MenuItem {
    kind: MenuItemKind,
    parent: Option<MenuItemId>,
    anchor: Option<MenuAnchor>,
    children: Vec<MenuItemId>,
    shortcut: Option<String>,
    /// The standard-command role this item claims, if any. Kept per
    /// item (not only in the app-wide table) so a subtree walk can
    /// reject a role that would land under a context anchor.
    role: Option<String>,
}

// --- The undo ledger (docs/undo-plan.md D2, D3, §3) ---------------------

/// One window's history, newest LAST. `done` is what an undo walks;
/// `redo` is what a redo walks, and any new step clears it.
///
/// ONE ORDERED LIST, NOT TWO STACKS. The whole point of banking typing
/// episodes beside groups is that the user's history has no holes and no
/// interleave: "ask the focused text first" and "ask the most recent
/// first" are the same question, because a group commit clears the
/// focused field's native stack (A1) and every episode therefore begins
/// with an empty one. Nothing in a native stack can reach past the
/// frontier episode's start.
#[derive(Default)]
struct Ledger {
    done: Vec<LedgerEntry>,
    redo: Vec<LedgerEntry>,
}

enum LedgerEntry {
    /// A transaction the app named, with BOTH directions of its delta.
    /// Both are computed once, at apply, from state the core already
    /// holds — the forward one is not a re-run of anything.
    Group {
        label: String,
        inverse: UndoDelta,
        forward: UndoDelta,
    },
    /// The run of text_changed occurrences on one field between clears.
    Episode(Episode),
}

/// A banked run of edits on one field.
///
/// The core tracks this PURELY from the occurrence stream it already
/// receives — never by reading the widget, which the no-mirror-reads
/// doctrine forbids and which nothing here needs.
struct Episode {
    field: WidgetId,
    /// The field's text when the run started.
    before: String,
    /// The high-water text: where ordinary typing has taken the field.
    /// A native undo walking backwards does NOT move this, so a redo of
    /// a banked episode still knows where to go.
    after: String,
    /// Where the field is NOW. Equal to `after` except mid-walk.
    current: String,
    /// Still the frontier: further edits extend it rather than opening a
    /// new one. Closed by a group commit, by a programmatic write that
    /// changes the text, or by an event naming another field.
    open: bool,
}

/// Where an undo request should go (D6, widened to §3's three-way).
///
/// A4: the "can the focused widget undo?" question is asked ONCE, by
/// name, and answered per backend — never re-expressed as a fifth
/// hard-coded predicate the way the role filters were.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum UndoRoute {
    /// The focused text widget's own stack answers: call its native
    /// Undo, then report the result back through `note_native_undo`.
    Native,
    /// The core answers: call `undo`/`redo`.
    Core,
    /// Nothing to undo; the command is inert and should read disabled.
    Nothing,
}

/// A group under construction: the pre-state of everything the batch has
/// touched so far.
///
/// Kept for two jobs at once — computing the inverse at the end, and
/// PUTTING THE SCENE BACK if a later op turns out to be one the core
/// cannot invert. A refused group therefore leaves the scene exactly as
/// it was, which the menu barrier already promises for signals and this
/// extends to collections.
struct GroupCapture {
    window: WindowId,
    label: String,
    /// First touch wins, the rollback map's rule. None = the entry did
    /// not exist before the batch.
    entries: Vec<(EntryRef, Option<(u32, Record)>)>,
    /// Instance key orders, captured only when an op can move something
    /// — position is the one thing per-entry statements cannot carry.
    orders: Vec<((CollectionId, PathKey), Vec<Key>)>,
}

/// What an op costs an undoable group (D4, narrowed by A2).
enum UndoVerdict {
    /// The core can derive its inverse from state it keeps.
    Invertible,
    /// A pure effect: permitted, and simply not restored. Undo restores
    /// state; it does not restore where you were looking.
    PureEffect,
    /// Refused, under this wire name.
    Refused(&'static str),
}

fn undo_verdict(op: &TxOp) -> UndoVerdict {
    match op {
        TxOp::WriteSignal { .. }
        | TxOp::CollectionInsert { .. }
        | TxOp::CollectionUpdate { .. }
        | TxOp::CollectionUpdateField { .. }
        | TxOp::CollectionRemove { .. }
        | TxOp::CollectionMove { .. } => UndoVerdict::Invertible,
        // Focus was the first pure effect; the three text-range ops are
        // the rest of the set A2 anticipated ("scroll when it lands").
        // Clear is NOT one — it destroys widget-owned text the core
        // never held, so it cannot be put back.
        TxOp::WidgetCommand {
            command: CommandKind::Focus,
            ..
        } => UndoVerdict::PureEffect,
        // ALL THREE, together, so no app author has to remember which of
        // them a group admits. reveal is A2's own example. select moves
        // the caret, which is where you were looking. And HIGHLIGHT,
        // which looks like state and is not: the core keeps no declared
        // set to invert (docs/ranges-plan.md D2 rejects tracking
        // outright), and a set is bound to the text it was declared
        // against — an undo that restores the text therefore drops it
        // anyway, and the app re-declares from the `undone` occurrence
        // exactly as it re-declares from `text_changed`.
        TxOp::HighlightRanges { .. } | TxOp::SelectRange { .. } | TxOp::RevealRange { .. } => {
            UndoVerdict::PureEffect
        }
        TxOp::WidgetCommand {
            command: CommandKind::Clear,
            ..
        } => UndoVerdict::Refused("clear"),
        TxOp::UndoGroup { .. } => UndoVerdict::Refused("a second undo_group"),
        TxOp::CreateSignal { .. } => UndoVerdict::Refused("create_signal"),
        TxOp::CreateWidget { .. } => UndoVerdict::Refused("create_widget"),
        TxOp::SetProperty { .. } => UndoVerdict::Refused("set_property"),
        TxOp::AddChild { .. } => UndoVerdict::Refused("add_child"),
        TxOp::Mount { .. } => UndoVerdict::Refused("mount"),
        TxOp::SetWindowProp { .. } => UndoVerdict::Refused("set_window_prop"),
        TxOp::CreateWindow { .. } => UndoVerdict::Refused("create_window"),
        TxOp::DestroyWindow { .. } => UndoVerdict::Refused("destroy_window"),
        TxOp::ShowAlert(_) => UndoVerdict::Refused("show_alert"),
        TxOp::ShowFileDialog(_) => UndoVerdict::Refused("show_file_dialog"),
        TxOp::ShowSaveDialog(_) => UndoVerdict::Refused("show_save_dialog"),
        TxOp::SetBrandAccent { .. } => UndoVerdict::Refused("set_brand_accent"),
        TxOp::Copy(_) => UndoVerdict::Refused("copy"),
        TxOp::ReadClipboard { .. } => UndoVerdict::Refused("read_clipboard"),
        TxOp::PushEntry { .. } => UndoVerdict::Refused("push_entry"),
        TxOp::PopEntry { .. } => UndoVerdict::Refused("pop_entry"),
        TxOp::SetEntryProp { .. } => UndoVerdict::Refused("set_entry_prop"),
        TxOp::AddSection { .. } => UndoVerdict::Refused("add_section"),
        TxOp::SelectSection { .. } => UndoVerdict::Refused("select_section"),
        TxOp::SetSectionProp { .. } => UndoVerdict::Refused("set_section_prop"),
        TxOp::MenuItemCreate { .. } => UndoVerdict::Refused("menu_item_create"),
        TxOp::MenuItemAppend { .. } => UndoVerdict::Refused("menu_item_append"),
        TxOp::MenubarAppend { .. } => UndoVerdict::Refused("menubar_append"),
        TxOp::ContextAttach { .. } => UndoVerdict::Refused("context_attach"),
        TxOp::ContextAttachNode { .. } => UndoVerdict::Refused("context_attach_node"),
        TxOp::SetMenuProp { .. } => UndoVerdict::Refused("set_menu_prop"),
        TxOp::CreateCollection { .. } => UndoVerdict::Refused("create_collection"),
        TxOp::CreateFor { .. } => UndoVerdict::Refused("create_for"),
        TxOp::CreateWhen { .. } => UndoVerdict::Refused("create_when"),
        TxOp::VariantCase { .. } => UndoVerdict::Refused("variant_case"),
        TxOp::TemplateEnd => UndoVerdict::Refused("template_end"),
    }
}

#[derive(Default)]
pub(crate) struct Scene {
    /// The brand accent, once set — brand is identity, not state, so
    /// the arm below refuses a second write and a post-mount one, and
    /// this Option is the whole record of it.
    brand_accent: Option<crate::brand::BrandAccent>,
    signals: HashMap<SignalId, Value>,
    /// signal -> the (widget, property) pairs it feeds (live and stamped).
    bindings: HashMap<SignalId, Vec<(WidgetId, Prop)>>,
    window_bindings: HashMap<SignalId, Vec<(WindowId, WindowProp)>>,
    /// Live AUXILIARY windows (the primary, window 0, always exists
    /// and is never in this set). Auxiliaries join at create_window
    /// and leave at destroy_window; chrome-closed non-veto windows
    /// stay until the guest's destroy_window reconciles
    /// (window_closed is informational).
    windows: std::collections::HashSet<WindowId>,
    /// Live navigation entries: entry surface id -> the window whose
    /// stack holds it. Entries share the surface namespace with
    /// windows (one guest allocator; mount targets either).
    nav_entries: HashMap<WindowId, WindowId>,
    /// Per-window navigation stacks, bottom to top. The core owns the
    /// stack (DESIGN.md, Navigation): guest pops arrive as pop_entry,
    /// user pops reconcile through `user_popped`.
    nav_stacks: HashMap<WindowId, Vec<WindowId>>,
    entry_bindings: HashMap<SignalId, Vec<(WindowId, EntryProp)>>,
    /// Live sections: section surface id -> the window whose section
    /// set holds it. Sections share the surface namespace with
    /// windows and entries (one guest allocator; mount and push_entry
    /// target any of them). APPEND-ONLY by design: this grammar has
    /// no destruction verbs, and a section only dies with its window.
    section_of: HashMap<WindowId, WindowId>,
    /// Per-window section sets, in add order.
    sections: HashMap<WindowId, Vec<WindowId>>,
    /// Per-window selected section — the core's mirror of the
    /// switcher state, kept for select_section validation and
    /// user-switch reconciliation (the nav_stacks stance).
    selected_section: HashMap<WindowId, WindowId>,
    section_bindings: HashMap<SignalId, Vec<(WindowId, SectionProp)>>,
    /// Menu items by id — their OWN id space (DESIGN.md, Menus).
    /// Append-only, never removed in v1.
    menu_items: HashMap<MenuItemId, MenuItem>,
    /// Per-window top-level catalog (bar) items, in menubar_append
    /// order.
    window_menus: HashMap<WindowId, Vec<MenuItemId>>,
    /// Per-window catalog shortcuts, for the duplicate-within-a-window
    /// check (the same chord in separate windows is fine).
    window_shortcuts: HashMap<WindowId, std::collections::HashSet<String>>,
    /// role -> the item that claimed it. App-wide, unlike shortcuts: a
    /// role names ONE standard command for the whole program, and the
    /// host that relocates it (macOS's application menu) has exactly
    /// one slot to put it in.
    menu_roles: HashMap<String, MenuItemId>,
    /// signal -> the (item, property) pairs it feeds. Only the
    /// signal-bindable menu props (label, enabled, checked, value) land
    /// here; the coalesced value is domain-validated at the barrier.
    menu_bindings: HashMap<SignalId, Vec<(MenuItemId, MenuProp)>>,
    /// entry -> the (widget, property, field) triples its record feeds.
    element_bindings: HashMap<EntryRef, Vec<(WidgetId, Prop, u32)>>,
    widgets: HashMap<WidgetId, WidgetKind>,
    template_nodes: HashMap<u64, WidgetKind>,
    collections: HashMap<CollectionId, CollDecl>,
    coll_instances: HashMap<(CollectionId, PathKey), CollInstance>,
    for_sites: HashMap<(CollectionId, PathKey), ForSite>,
    stamps: HashMap<EntryRef, Stamp>,
    when_sites: HashMap<u64, WhenSite>,
    when_by_signal: HashMap<SignalId, Vec<u64>>,
    /// Every live surface that has a mounted root, and WHICH widget that
    /// root is. `Mount` is the only site that inserts; six sites remove
    /// (DestroyWindow's window, its entries and its sections' entries,
    /// PopEntry, user_popped). Held as one map rather than a set plus a
    /// side table because the two facts have one lifetime: a seventh
    /// removal site that updated only one of them would make an
    /// unreachable widget look reachable, which is the exact defect the
    /// barrier below exists to catch.
    mounted_windows: HashMap<WindowId, WidgetId>,
    /// child -> parent, LIVE ZONE ONLY. The template zone keeps its own
    /// (`TplSection::childed`) and promotes an unparented node to a root
    /// of the stamped copy; the live zone has nowhere to promote to, so
    /// an unclaimed widget renders nowhere while still answering every
    /// read. This map plus `mounted_windows` is what proves it does not
    /// happen (`check_reachable_from_mounted_root`).
    parent_of: HashMap<WidgetId, WidgetId>,
    /// Scroll viewports that already hold their one child: a scroll
    /// takes EXACTLY ONE (the ScrolledWindow shape) and a second
    /// add_child fails loudly here, at the root.
    filled_scrolls: std::collections::HashSet<WidgetId>,
    /// Per-select option count (options are its label children;
    /// append-only — the protocol has no remove_child). Feeds the
    /// selected-index upper-bound check at the live SetProp site.
    select_options: HashMap<WidgetId, u32>,
    next_internal: u64,
    next_when_site: u64,
    next_scope: u64,
    /// One undo ledger per window (docs/undo-plan.md §3). Keyed by the
    /// window a group NAMES: the core cannot derive it — a signal write
    /// addresses no surface, and the scene keeps no widget-to-window map
    /// — so `undo_group` carries it and every episode entry point takes
    /// it from the backend, which knows.
    ledgers: HashMap<WindowId, Ledger>,
    /// The text the core has SEEN each field hold: seeded by every
    /// programmatic write it resolves, advanced by every text_changed it
    /// is told about. NOT A MIRROR READ — nothing here ever asks a
    /// widget anything; this is the core's record of what it watched go
    /// past, and it exists because an episode's before-image is the text
    /// as of the event BEFORE the first one in the run.
    field_text: HashMap<WidgetId, String>,
}

/// The choice kinds: one selection among label-children options.
/// Select is the dropdown presentation, Radio the inline group —
/// SAME semantics (options as label children, Value as the 0-based
/// index, value_changed on user picks only), different chrome.
fn is_choice(kind: WidgetKind) -> bool {
    matches!(kind, WidgetKind::Select | WidgetKind::Radio)
}

fn check_prop(kind: WidgetKind, prop: Prop) {
    let ok = match prop {
        Prop::Text => matches!(
            kind,
            WidgetKind::Button
                | WidgetKind::Label
                | WidgetKind::Entry
                | WidgetKind::Checkbox
                | WidgetKind::Textarea
        ),
        Prop::Checked => matches!(kind, WidgetKind::Checkbox),
        // Value is the slider's position AND the progress bar's
        // determinate fraction AND the select's 0-based selected index
        // (per-kind domains, checked below); min/max stay slider-only
        // (progress is fixed 0..=1, the select's range is its option
        // count).
        Prop::Value => {
            matches!(kind, WidgetKind::Slider | WidgetKind::Progress) || is_choice(kind)
        }
        Prop::Min | Prop::Max => matches!(kind, WidgetKind::Slider),
        Prop::Indeterminate => matches!(kind, WidgetKind::Progress),
        Prop::Source => matches!(kind, WidgetKind::Image),
        // Layout weight is kind-agnostic: any child of a row/column may
        // grow, so it applies to every widget kind.
        Prop::Grow => true,
        // Spacing is the container's own property — the gap between
        // ITS children — so only the container kinds carry it (a
        // grid's spacing is its inter-cell gap, both axes).
        Prop::Spacing => {
            matches!(kind, WidgetKind::Column | WidgetKind::Row | WidgetKind::Grid)
        }
        // Alignment likewise: where the container places ITS children
        // on the cross axis.
        Prop::Align => matches!(kind, WidgetKind::Column | WidgetKind::Row),
        // A container's own padding (docs/styling-plan.md D3, one level
        // down from the window inset): spacing's kinds exactly, and for
        // spacing's reason — the prop is about a container's relation
        // to ITS children, and a leaf has none to hold off its edge.
        Prop::Inset => {
            matches!(kind, WidgetKind::Column | WidgetKind::Row | WidgetKind::Grid)
        }
        // The grid's own shape: how many columns children fill
        // row-major.
        Prop::Columns => matches!(kind, WidgetKind::Grid),
        // The first UNIVERSAL props. Every other prop is kind-scoped
        // because it names something only some controls have; these
        // name something every element in the tree has — an identity
        // and a spoken name. Containers included, deliberately: a
        // column is a labelled group to an assistive client, and a
        // harness must be able to address one.
        Prop::A11yId | Prop::A11yLabel => true,
        // Acceptance is scoped to what can RECEIVE a paste. A column
        // cannot take content; an entry and a textarea can, and so can
        // any widget an app makes its own paste target. Kept to the
        // text kinds for now because those are the ones with native
        // paste behaviour to override — widening it is a decision about
        // which kinds get a paste hook, not about this prop.
        Prop::Accepts => matches!(kind, WidgetKind::Entry | WidgetKind::Textarea),
        // The hint is the ONE accessibility prop that is not universal,
        // and the reason is the platforms' own definition rather than a
        // lowering gap: a hint says what ACTIVATING the control does,
        // so it needs an activation to describe. Android carries it as
        // the click ACTION's label and has nowhere to put one without
        // an action; Apple's guidance scopes hints to actions too. So
        // the root admits it exactly where "activate" means something,
        // and a hint on a label, an image or a container dies here
        // rather than silently reaching four backends and not the
        // fifth. Adjustable and editable kinds (slider, entry,
        // textarea) are a deliberate cut: their Android route is a
        // different action's label, and they wait for an artifact.
        Prop::A11yHint => matches!(
            kind,
            WidgetKind::Button
                | WidgetKind::Checkbox
                | WidgetKind::Select
                | WidgetKind::Radio
        ),
        // Semantic emphasis (docs/styling-plan.md D4). KIND legality
        // here is the union of the variants' homes — buttons and
        // labels; WHICH variant fits which kind is value-dependent and
        // lives in check_prop_value, where a destructive label dies at
        // declare time naming both the role and the kind.
        Prop::Role => matches!(kind, WidgetKind::Button | WidgetKind::Label),
    };
    assert!(ok, "kaya: {kind:?} has no property {prop:?}");
}

/// A command is momentary and kind-scoped: clear drops an entry's
/// content, focus lands on anything interactive. The same check class
/// as check_prop — misuse fails loudly at the call site, never on a
/// backend. (The silent no-op is reserved for instance-addressed
/// commands, where a stamped target can legitimately vanish under
/// rebuild; a live id only vanishes by the guest's own hand.)
fn check_command(kind: WidgetKind, command: CommandKind) {
    let ok = match command {
        CommandKind::Clear => matches!(kind, WidgetKind::Entry | WidgetKind::Textarea),
        CommandKind::Focus => matches!(
            kind,
            WidgetKind::Entry
                | WidgetKind::Button
                | WidgetKind::Checkbox
                | WidgetKind::Slider
                | WidgetKind::Textarea
        ),
    };
    assert!(ok, "kaya: command {command:?} does not apply to {kind:?}");
}

/// A UTF-8 byte offset into `text`, converted into the unit THIS BUILD'S
/// backend counts. `cfg!` and not `#[cfg]` on purpose: both arms compile
/// on every target, so the linux conversion is type-checked and
/// unit-tested on the machine writing it rather than discovered by the
/// linux lane.
pub(crate) fn native_offset(text: &str, byte: u64) -> u64 {
    if cfg!(target_os = "linux") {
        native_offset_chars(text, byte)
    } else {
        native_offset_utf16(text, byte)
    }
}

/// Foundation's `NSRange`, TOM's character positions and Compose's
/// `TextRange` all index UTF-16 code units — four of the five backends.
fn native_offset_utf16(text: &str, byte: u64) -> u64 {
    text[..byte as usize].encode_utf16().count() as u64
}

/// GTK's `GtkTextBuffer` counts CODE POINTS: `gtk_text_buffer_get_char_count`
/// is 5 for `ab😀cd`, whose UTF-8 length is 8 (measured live on GTK
/// 4.18.6, scratchpad/ranges-units.md §3).
fn native_offset_chars(text: &str, byte: u64) -> u64 {
    text[..byte as usize].chars().count() as u64
}

/// THE ONE CHOKEPOINT every declared range crosses (docs/ranges-plan.md
/// D2, scratchpad/ranges-units.md §7): validate against the text, then
/// convert to the backend's unit. Both halves here, in this order,
/// because the conversion is only meaningful on an offset that is
/// already known to be a code-point boundary inside the text —
/// `&text[..byte]` panics with Rust's own message otherwise, which is a
/// worse version of the same complaint.
///
/// WHY IT PANICS rather than dropping the op: it is the same class as
/// `wire.rs`'s `expect("kaya: string value is not UTF-8")` — an
/// app-programming error, deterministic, and fixable by the app. A
/// dropped op is the failure that SHIPS, because the app sees a
/// highlight that did not appear and blames the backend. Snapping is
/// what the platforms do and the measurements show snapping is not one
/// behaviour: AppKit snaps a bad start and keeps a bad end (whose copy
/// then yields U+FFFD), GTK accepts a split verbatim, Compose snaps
/// outward and throws out of bounds, Windows clamps silently. Adopting
/// any of them would mean adopting whichever platform ran first.
///
/// WHAT IT DOES NOT REFUSE, deliberately: a GRAPHEME split. The
/// platforms disagree about what a grapheme is — java.text.BreakIterator
/// counts the ZWJ family as 11 clusters where .NET StringInfo and Swift
/// count 5, same string, measured — so a core refusing by its own table
/// would refuse ranges three platforms honour. It also does not refuse
/// an empty range (that is a caret, and select_range needs it) or an
/// empty set.
fn check_range(text: &str, widget: WidgetId, op: &str, range: TextRange) -> NativeRange {
    let where_ = format!("kaya: {op} on {widget:?}");
    assert!(
        range.start <= range.stop,
        "{where_}: start {} is after end {}",
        range.start,
        range.stop
    );
    assert!(
        range.stop <= text.len() as u64,
        "{where_}: end {} is past the end of the text ({} bytes)",
        range.stop,
        text.len()
    );
    for offset in [range.start, range.stop] {
        assert!(
            text.is_char_boundary(offset as usize),
            "{where_}: byte offset {offset} is not a character boundary; \
             it is inside {}",
            split_char(text, offset as usize)
        );
    }
    NativeRange {
        start: native_offset(text, range.start),
        stop: native_offset(text, range.stop),
    }
}

/// Which character a mid-sequence offset splits, spelled the way Rust's
/// own slice panic spells it — the core can say this because it holds
/// the text, and it is the difference between a message that names the
/// bug and one that names a number.
fn split_char(text: &str, offset: usize) -> String {
    let start = (0..=offset).rev().find(|i| text.is_char_boundary(*i)).unwrap_or(0);
    let ch = text[start..].chars().next().unwrap_or('\u{fffd}');
    format!("{ch:?} (bytes {start}..{})", start + ch.len_utf8())
}

/// Every property has one value type (spec::PROPS). The match is
/// exhaustive: a new prop cannot ship without declaring its type.
fn prop_value_type(prop: Prop) -> ValueType {
    match prop {
        Prop::Text => ValueType::Str,
        Prop::Checked => ValueType::Bool,
        Prop::Value | Prop::Min | Prop::Max => ValueType::F64,
        Prop::Source => ValueType::Blob,
        Prop::Grow => ValueType::F64,
        Prop::Spacing => ValueType::F64,
        Prop::Inset => ValueType::F64,
        Prop::Align => ValueType::I64,
        Prop::Role => ValueType::I64,
        Prop::Indeterminate => ValueType::Bool,
        Prop::Columns => ValueType::F64,
        Prop::A11yId | Prop::A11yLabel | Prop::A11yHint => ValueType::Str,
        // An ACCEPT LIST: the closed kinds by name plus any custom
        // format ids, space separated. Not a mask and not an enum slot
        // — a widget accepts a SET, and half that set is open-ended.
        Prop::Accepts => ValueType::Str,
    }
}

/// The typed setters the bindings generate enforce prop types at
/// compile time — but the wire itself is untyped, so an ill-typed
/// record from a raw guest must die here, not in whichever backend
/// Window property values: the title takes any string; the size
/// request takes finite positive DIP. Nonsense dies at the root, the
/// grow/spacing precedent.
fn check_window_prop_value(prop: WindowProp, value: &Value) {
    match (prop, value) {
        (WindowProp::Title, Value::Str(_)) => {}
        (WindowProp::VetoClose, Value::Bool(_)) => {}
        (WindowProp::ListDetail, Value::Bool(_)) => {}
        (WindowProp::Dirty, Value::Bool(_)) => {}
        (WindowProp::Width | WindowProp::Height, Value::F64(v)) => {
            assert!(
                v.is_finite() && *v > 0.0,
                "kaya: window size request must be finite and positive, got {v}"
            );
        }
        // ZERO IS THE POINT (docs/styling-plan.md D3): a full-bleed
        // window is the inset's reason to exist; negative has no
        // reading — an inset is space, not an offset.
        (WindowProp::Inset, Value::F64(v)) => {
            assert!(
                v.is_finite() && *v >= 0.0,
                "kaya: window inset must be finite and non-negative, got {v}"
            );
        }
        // The enum's closed set (the align precedent): the wire
        // carries I64, the domain is the spec enum's values.
        (WindowProp::SectionsPresentation, Value::I64(v)) => {
            assert!(
                (0..=2).contains(v),
                "kaya: sections_presentation must be auto (0), bar (1), or \
                 sidebar (2), got {v}"
            );
        }
        (p, v) => panic!("kaya: window property {p:?} rejects value {v:?}"),
    }
}

fn check_entry_prop_value(prop: EntryProp, value: &Value) {
    match (prop, value) {
        (EntryProp::Title, Value::Str(_)) => {}
        (EntryProp::InterceptBack, Value::Bool(_)) => {}
        (p, v) => panic!("kaya: entry property {p:?} rejects value {v:?}"),
    }
}

fn check_section_prop_value(prop: SectionProp, value: &Value) {
    match (prop, value) {
        (SectionProp::Title, Value::Str(_)) => {}
        (SectionProp::Icon, Value::Blob(_)) => {}
        // The enum's closed set (the sections_presentation precedent,
        // one table over): the wire carries I64 and the domain is the
        // spec enum's values.
        (SectionProp::Symbol, Value::I64(v)) => check_symbol(*v),
        (p, v) => panic!("kaya: section property {p:?} rejects value {v:?}"),
    }
}

/// THE VALUE WALL for the semantic icon vocabulary (docs/styling-plan.md
/// D6), the `role` precedent: an out-of-enum number dies AT THE ROOT,
/// naming the vocabulary, before any backend improvises on it. Without
/// it the wire slot is a bare integer, and the failure is silent in the
/// worst direction — a backend's glyph table simply misses, the item
/// draws with no icon, and nothing anywhere says why.
///
/// The sentence lists the whole vocabulary rather than the count,
/// because the reader's next question is always "then what may I say?".
fn check_symbol(value: i64) {
    assert!(
        crate::wire::symbol_name(value).is_some(),
        "kaya: {value} is not a symbol — the vocabulary is {}",
        crate::wire::SYMBOLS
            .iter()
            .map(|(id, name)| format!("{name}={id}"))
            .collect::<Vec<_>>()
            .join(", ")
    );
}

/// The closed parent/child grammar (DESIGN.md, Menus): a `menu`
/// contains the five non-option kinds; a `radio_group` contains only
/// `radio_option`; leaves contain nothing. The depth cap is separate
/// (validated at the anchor); this is the per-edge grammar.
fn menu_accepts(parent: MenuItemKind, child: MenuItemKind) -> bool {
    match parent {
        MenuItemKind::Menu => matches!(
            child,
            MenuItemKind::Menu
                | MenuItemKind::RadioGroup
                | MenuItemKind::Action
                | MenuItemKind::Toggle
                | MenuItemKind::Separator
        ),
        MenuItemKind::RadioGroup => matches!(child, MenuItemKind::RadioOption),
        MenuItemKind::Action
        | MenuItemKind::Toggle
        | MenuItemKind::RadioOption
        | MenuItemKind::Separator => false,
    }
}

fn is_menu_group(kind: MenuItemKind) -> bool {
    matches!(kind, MenuItemKind::Menu | MenuItemKind::RadioGroup)
}

/// Which kinds carry which property (DESIGN.md, Menus): label/enabled
/// on everything but a separator; checked toggle-only; value
/// radio-group-only; primary and role action-only; shortcut on any LEAF
/// command — a checkable item takes a chord as readily as a plain one
/// on every host, and "Show Sidebar" wants both its checkmark and its
/// key; icon on everything but a separator. Misuse dies at the root,
/// the check_prop precedent.
fn check_menu_prop(kind: MenuItemKind, prop: MenuProp) {
    let ok = match prop {
        MenuProp::Label | MenuProp::Enabled | MenuProp::Icon | MenuProp::Symbol => {
            !matches!(kind, MenuItemKind::Separator)
        }
        MenuProp::Checked => matches!(kind, MenuItemKind::Toggle),
        MenuProp::Value => matches!(kind, MenuItemKind::RadioGroup),
        MenuProp::Primary | MenuProp::Role => matches!(kind, MenuItemKind::Action),
        MenuProp::Shortcut => kind.takes_shortcut(),
    };
    assert!(ok, "kaya: a {kind:?} menu item has no property {prop:?}");
}

/// The closed role vocabulary (DESIGN.md, Menus). Closed on purpose — a
/// role is the only thing that can move an authored item into
/// dress-owned chrome, or hand its behaviour to the platform.
///
/// `settings` names the app's settings command, which macOS places in
/// the application menu and every other host leaves where the app put
/// it.
///
/// `cut`, `copy` and `paste` are THE GESTURE LAYER, and they exist
/// because kaya has no selection API: only the widget knows what is
/// selected, so "copy the selection" cannot be assembled by an app out
/// of the data layer. A role item lowers to the platform's own command,
/// acts on the FOCUSED widget, and configures its own enablement —
/// which kaya computes rather than handing the app a signal to compute
/// it with, since kaya already knows what is focused, what the
/// clipboard offers, and what the widget declared it accepts.
/// `undo` and `redo` are the same gesture layer one tier deeper. They
/// act on the FOCUSED widget first — a text widget whose native stack
/// has something to give answers before the core's ledger does — and
/// configure their own enablement from that same question, which is
/// why they are roles and not app-authored actions (docs/undo-plan.md
/// D6). tools/check-roles.sh holds every backend to this line.
pub(crate) const MENU_ROLES: &[&str] =
    &["settings", "cut", "copy", "paste", "undo", "redo"];

fn check_menu_role(value: &Value) {
    let Value::Str(role) = value else {
        return;
    };
    assert!(
        MENU_ROLES.contains(&role.as_str()),
        "kaya: menu role {role:?} is not in the closed role vocabulary ({})",
        MENU_ROLES.join(", ")
    );
}

/// Every menu property has one value type (spec::MENU_PROPS). The match
/// is exhaustive: a new prop cannot ship without declaring its type.
fn menu_prop_value_type(prop: MenuProp) -> ValueType {
    match prop {
        MenuProp::Label | MenuProp::Shortcut | MenuProp::Role => ValueType::Str,
        MenuProp::Enabled | MenuProp::Checked | MenuProp::Primary => ValueType::Bool,
        MenuProp::Value => ValueType::F64,
        MenuProp::Icon => ValueType::Blob,
        // The semantic icon vocabulary rides I64 like every other
        // spec enum; check_menu_prop_value walls the domain.
        MenuProp::Symbol => ValueType::I64,
    }
}

/// The signal-bindable menu props: label, enabled, checked, value. icon,
/// symbol, primary, shortcut and role are const-only (DESIGN.md, Menus;
/// docs/styling-plan.md D6 for the symbol). Kept in lockstep with
/// kaya-bindgen's menu_prop_bindable, which panics on an undeclared
/// prop rather than guessing.
fn is_bindable_menu_prop(prop: MenuProp) -> bool {
    matches!(
        prop,
        MenuProp::Label | MenuProp::Enabled | MenuProp::Checked | MenuProp::Value
    )
}

/// A menu property value against its type, plus the value domain: a
/// radio group's `value` is a 0-based option index (integral,
/// non-negative). The upper bound (index < option count) needs scene
/// state, so it lives at the call site (the select-index precedent).
fn check_menu_prop_value(prop: MenuProp, value: &Value) {
    assert!(
        value.type_of() == menu_prop_value_type(prop),
        "kaya: menu property {prop:?} cannot hold {value:?}"
    );
    if let (MenuProp::Value, Value::F64(idx)) = (prop, value) {
        assert!(
            idx.is_finite() && *idx >= 0.0 && idx.fract() == 0.0,
            "kaya: a radio group's value is a 0-based option index \
             (integral, non-negative), got {idx}"
        );
    }
    // The same wall the section slot gets, on the same vocabulary: one
    // function, so the two surfaces cannot drift into two answers.
    if let (MenuProp::Symbol, Value::I64(symbol)) = (prop, value) {
        check_symbol(*symbol);
    }
}

/// The closed named-key set of the shortcut floor (DESIGN.md, Menus),
/// beyond the ASCII alphanumerics. `escape` is recognized here so it
/// can be rejected with its own reason.
fn is_named_key(key: &str) -> bool {
    matches!(key, "enter" | "escape" | "delete" | "left" | "right" | "up" | "down")
        || is_function_key(key)
        || is_punctuation_key(key)
}

/// The closed punctuation set, named rather than spelled with the
/// character itself — `enter`/`delete` are the precedent, and a name
/// keeps the wire spelling free of characters the step grammar and the
/// path syntax already use. Each names the UNSHIFTED US position; the
/// host binds its own key code and displays the chord its own way, so
/// `primary+shift+equal` is how an app asks for what macOS draws as
/// Command-plus. Typing protection is the alphanumeric rule: these
/// keys need primary or alt too.
fn is_punctuation_key(key: &str) -> bool {
    matches!(
        key,
        "comma"
            | "period"
            | "slash"
            | "backslash"
            | "minus"
            | "equal"
            | "leftbracket"
            | "rightbracket"
    )
}

/// `f1`..`f12`, exactly — no leading zeros, no `f0`, no `f13`.
fn is_function_key(key: &str) -> bool {
    match key.strip_prefix('f') {
        Some(n) => n
            .parse::<u8>()
            .ok()
            .filter(|d| (1..=12).contains(d))
            .is_some_and(|d| n == d.to_string()),
        None => false,
    }
}

fn is_ascii_alnum_key(key: &str) -> bool {
    let mut chars = key.chars();
    match (chars.next(), chars.next()) {
        (Some(c), None) => c.is_ascii_lowercase() || c.is_ascii_digit(),
        _ => false,
    }
}

/// Validate a CANONICAL shortcut wire spelling and the reserved-floor
/// policy — the one shortcut checker, validating and never rewriting
/// (DESIGN.md, Menus). Canonical form: `+`-joined lowercase tokens,
/// optional `primary`, `shift`, `alt` in that order, then exactly one
/// key. The strict key floor is one ASCII alphanumeric or one closed
/// named key; `escape` is recognized but always rejected; `shift` and
/// an alphanumeric key both require `primary` or `alt`; `primary+q` and
/// `alt+f4` are the reserved cross-platform union. Returns the exact
/// error a raw non-canonical or inapplicable spelling must die with.
fn validate_shortcut(spelling: &str) -> Result<(), String> {
    if spelling.is_empty() {
        return Err("kaya: shortcut is empty".to_string());
    }
    if spelling.chars().any(|c| c.is_whitespace()) {
        return Err(format!("kaya: shortcut {spelling:?} contains whitespace"));
    }
    let parts: Vec<&str> = spelling.split('+').collect();
    if parts.iter().any(|p| p.is_empty()) {
        return Err(format!("kaya: shortcut {spelling:?} has an empty token"));
    }
    let (mods, key) = parts.split_at(parts.len() - 1);
    let key = key[0];
    let (mut has_primary, mut has_shift, mut has_alt) = (false, false, false);
    let mut last_rank = 0u8;
    for m in mods {
        let (rank, slot): (u8, &mut bool) = match *m {
            "primary" => (1, &mut has_primary),
            "shift" => (2, &mut has_shift),
            "alt" => (3, &mut has_alt),
            other => {
                return Err(format!(
                    "kaya: shortcut {spelling:?} has an unknown or non-canonical \
                     modifier {other:?} (the portable modifiers are primary, \
                     shift, alt)"
                ));
            }
        };
        if *slot {
            return Err(format!("kaya: shortcut {spelling:?} repeats modifier {m:?}"));
        }
        if rank <= last_rank {
            return Err(format!(
                "kaya: shortcut {spelling:?} modifiers are not in canonical order \
                 (primary, shift, alt)"
            ));
        }
        last_rank = rank;
        *slot = true;
    }
    if key == "escape" {
        return Err(format!(
            "kaya: shortcut {spelling:?} uses escape — the platforms' universal \
             dismiss key is never a shortcut"
        ));
    }
    let alnum = is_ascii_alnum_key(key);
    if !alnum && !is_named_key(key) {
        return Err(format!(
            "kaya: shortcut {spelling:?} key {key:?} is outside the floor \
             (one of a-z, 0-9, or the closed named set)"
        ));
    }
    if (alnum || is_punctuation_key(key)) && !(has_primary || has_alt) {
        return Err(format!(
            "kaya: shortcut {spelling:?}: an alphanumeric or punctuation key needs primary or alt \
             (bare and shift-only spellings are ordinary typing)"
        ));
    }
    if has_shift && !(has_primary || has_alt) {
        return Err(format!(
            "kaya: shortcut {spelling:?}: shift is valid only with primary or alt"
        ));
    }
    if spelling == "primary+q" || spelling == "alt+f4" {
        return Err(format!(
            "kaya: shortcut {spelling:?} is reserved (the strict cross-platform \
             floor: primary+q and alt+f4)"
        ));
    }
    Ok(())
}

/// applies it.
fn check_prop_value(kind: WidgetKind, prop: Prop, value: &Value) {
    assert!(
        value.type_of() == prop_value_type(prop),
        "kaya: {prop:?} cannot hold {value:?}"
    );
    // Grow's domain is narrower than its type. A negative weight has no
    // reading under "divide the leftover in proportion to the weights" —
    // it is not a small share, it is not a contract at all — and every
    // backend would have to invent its own answer: the AppKit path would
    // build a constraint with a negative multiplier, the GTK one would
    // hand out a negative allocation, and neither would look like the
    // other. Nonsense dies at the root, where the answer is the same in
    // all eight languages, rather than turning into seven silent
    // behaviours.
    if let (Prop::Grow, Value::F64(weight)) = (prop, value) {
        assert!(
            *weight >= 0.0 && weight.is_finite(),
            "kaya: grow weight must be finite and non-negative, got {weight}"
        );
    }
    // A grid's column count has no reading below one, and a
    // fractional count has none at all — nonsense dies at the root.
    if let (Prop::Columns, Value::F64(cols)) = (prop, value) {
        assert!(
            cols.is_finite() && *cols >= 1.0 && cols.fract() == 0.0,
            "kaya: a grid's columns is an integral count >= 1, got {cols}"
        );
    }
    // The ROLE'S VARIANT is what decides the kind, not the prop
    // (docs/styling-plan.md D4): check_prop admits Role on the union of
    // the variants' homes, and this is where a destructive LABEL dies —
    // at declare time, in one sentence naming both sides, rather than
    // as four backends' improvisations on a meaningless combination.
    if let (Prop::Role, Value::I64(role)) = (prop, value) {
        let ok = match *role {
            // destructive, prominent: an ACTION's emphasis — what
            // pressing it means. Only a button presses.
            1 | 2 => kind == WidgetKind::Button,
            // heading: a text hierarchy fact — what assistive users
            // skim by. Only a label heads a section.
            3 => kind == WidgetKind::Label,
            other => panic!(
                "kaya: {other} is not a role (destructive=1, prominent=2, heading=3)"
            ),
        };
        let name = match *role {
            1 => "destructive",
            2 => "prominent",
            _ => "heading",
        };
        assert!(
            ok,
            "kaya: role {name} does not fit {kind:?} — destructive and \
             prominent are button emphasis, heading is label hierarchy"
        );
    }
    // The accept list's own domain: at least one token, no token twice.
    // "You structurally cannot declare text twice" was the promise the
    // set shape made, and a string carrier keeps it only if the root
    // checks — so it checks, once, where the answer is the same in all
    // eight languages.
    if let (Prop::Accepts, Value::Str(list)) = (prop, value) {
        crate::wire::check_accept_list(list, "accepts");
    }
    // Same argument as grow's domain: a negative gap has no reading
    // under "8 units between adjacent children", and every backend
    // would invent its own overlap. Nonsense dies at the root.
    // Same domain as the window inset's, for the same reason: negative
    // padding has no reading, and every backend would invent one.
    if let (Prop::Inset, Value::F64(pad)) = (prop, value) {
        assert!(
            *pad >= 0.0 && pad.is_finite(),
            "kaya: a container's inset must be finite and non-negative, got {pad}"
        );
    }
    if let (Prop::Spacing, Value::F64(gap)) = (prop, value) {
        assert!(
            *gap >= 0.0 && gap.is_finite(),
            "kaya: spacing must be finite and non-negative, got {gap}"
        );
    }
    // Align's domain is the spec enum, and baseline is rows-only: a
    // column has no text baseline to agree on, so the write dies here
    // with one message rather than as four backend improvisations.
    if let (Prop::Align, Value::I64(mode)) = (prop, value) {
        assert!(
            (0..=4).contains(mode),
            "kaya: align must be one of the align enum's values (0..=4), got {mode}"
        );
        assert!(
            !(*mode == 4 && kind == WidgetKind::Column),
            "kaya: baseline alignment applies to rows only"
        );
    }
    // A progress fraction outside 0..=1 has no reading — nonsense
    // dies at the root, the grow discipline (the slider keeps its own
    // min/max range; this arm is progress-only).
    if let (Prop::Value, Value::F64(fraction)) = (prop, value) {
        if kind == WidgetKind::Progress {
            assert!(
                (0.0..=1.0).contains(fraction),
                "kaya: a progress fraction lives in 0..=1, got {fraction}"
            );
        }
        // A choice widget's value is a 0-based option index:
        // integral and non-negative, or it has no reading. The upper
        // bound (index < option count) needs scene state, so it
        // lives at the live SetProp site, not here.
        if is_choice(kind) {
            assert!(
                fraction.is_finite() && *fraction >= 0.0 && fraction.fract() == 0.0,
                "kaya: a {kind:?}'s value is a 0-based option index \
                 (integral, non-negative), got {fraction}"
            );
        }
    }
}

/// An entry's record against its collection's schema: arity, then each
/// field's type. Positional and typed is the whole contract; names
/// never travel.
fn check_record(schema: &[ValueType], record: &[Value], what: &str) {
    assert!(
        record.len() == schema.len(),
        "kaya: {what} has {} fields, schema declares {}",
        record.len(),
        schema.len()
    );
    for (i, (value, ty)) in record.iter().zip(schema).enumerate() {
        assert!(
            value.type_of() == *ty,
            "kaya: {what} field {i} is {value:?}, schema declares {ty:?}"
        );
    }
}

fn check_type(current: &Value, incoming: &Value, what: &str) {
    let same = matches!(
        (current, incoming),
        (Value::Bool(_), Value::Bool(_))
            | (Value::I64(_), Value::I64(_))
            | (Value::F64(_), Value::F64(_))
            | (Value::Str(_), Value::Str(_))
    );
    assert!(same, "kaya: write changes the type of {what}");
}

impl Scene {
    pub(crate) fn new() -> Self {
        Self::default()
    }

    fn alloc_internal(&mut self) -> WidgetId {
        self.next_internal += 1;
        WidgetId(INTERNAL_BIT | self.next_internal)
    }

    fn button_tag(id: u64, path: &PathKey) -> Option<Vec<u8>> {
        Some(crate::wire::click_tag(id, &path_values(path)))
    }

    /// Apply one transaction atomically, returning the ops a backend
    /// must perform. Construction ops come out in submission order;
    /// signal writes coalesce (last write wins per signal within the
    /// batch) and flush — as targeted property sets and When toggles —
    /// at the end. A property bound mid-transaction is also set
    /// immediately at bind time, so a scene arrives fully valued; the
    /// end-of-batch flush may repeat such a set with the same value,
    /// which is harmless. Collection delta ops are edits, not writes:
    /// they apply in place, in order, never coalesced.
    pub(crate) fn apply(&mut self, tx: Transaction) -> Vec<ApplyOp> {
        let mut out = Vec::new();
        // First-dirtied order, deduped.
        let mut dirty: Vec<SignalId> = Vec::new();
        // Pre-transaction values of the signals this batch writes,
        // captured on first write. If a menu binding's COALESCED value
        // fails its domain check at the barrier, these restore every
        // signal this batch touched before the panic propagates — so a
        // caught panic never leaves partially-applied signal state
        // (DESIGN.md, Menus: barrier validation with rollback).
        let mut rollback: HashMap<SignalId, Value> = HashMap::new();
        // Template scopes currently open; while non-empty, creation
        // records describe a blueprint instead of executing.
        let mut scopes: Vec<TplScope> = Vec::new();
        // The undo group this batch declared at its head, if any, with
        // the pre-state of everything it has touched so far (D2/D3).
        let mut group: Option<GroupCapture> = None;
        // Every LIVE widget this batch minted, in creation order — the
        // domain of the reachability barrier below. Batch-scoped, not a
        // global sweep over `self.widgets`, because the core never
        // prunes that map: DestroyWindow (:1401) and PopEntry (:1584)
        // drop the surfaces and leave their widget ids behind forever,
        // so a global sweep would re-accuse widgets that were checked
        // when they were alive and parented.
        let mut created: Vec<WidgetId> = Vec::new();

        for (at, op) in tx.into_iter().enumerate() {
            if !scopes.is_empty() {
                self.declare(op, &mut scopes, &mut out);
                continue;
            }
            // A marked batch is checked op by op BEFORE anything runs:
            // the refusal has to happen while the scene can still be put
            // back (D4/A2).
            if let Some(cap) = &mut group {
                match undo_verdict(&op) {
                    UndoVerdict::Invertible => Self::capture_for_undo(
                        &self.collections,
                        &self.coll_instances,
                        &op,
                        cap,
                    ),
                    UndoVerdict::PureEffect => {}
                    UndoVerdict::Refused(name) => {
                        let cap = group.take().expect("just matched");
                        self.rollback_group(&cap, &rollback);
                        panic!(
                            "kaya: the undo group {:?} contains {name}, which the core \
                             cannot invert — an undoable group holds signal writes and \
                             collection deltas, because undo restores STATE and state is \
                             signals plus collections (focus is permitted and simply not \
                             restored). Bind the property to a signal, or drop \
                             undoable() from this transaction. Nothing was applied.",
                            cap.label
                        );
                    }
                }
            }
            match op {
                TxOp::UndoGroup { window, label } => {
                    // HEAD OF BATCH, ONCE. A transaction is a bare list
                    // with no header, so this position is the whole
                    // grammar: anywhere else and "which ops does it
                    // cover" would have two answers.
                    assert!(
                        at == 0,
                        "kaya: undo_group is record {} of this transaction — it must be \
                         the FIRST, because a transaction has no header and the marker's \
                         position is what says which ops the group covers",
                        at + 1
                    );
                    crate::wire::check_undo_label(&label, "undo_group");
                    assert!(
                        window == crate::protocol::DEFAULT_WINDOW
                            || self.windows.contains(&window),
                        "kaya: undo group {label:?} names unknown window {window:?} — \
                         create_window first (0 is the primary)"
                    );
                    group = Some(GroupCapture {
                        window,
                        label,
                        entries: Vec::new(),
                        orders: Vec::new(),
                    });
                }
                TxOp::CreateSignal { id, initial } => {
                    let clash = self.signals.insert(id, initial).is_some();
                    assert!(!clash, "kaya: signal id {id:?} already exists");
                }
                TxOp::WriteSignal { id, value } => {
                    let current = self
                        .signals
                        .get_mut(&id)
                        .unwrap_or_else(|| panic!("kaya: write to unknown signal {id:?}"));
                    check_type(current, &value, &format!("signal {id:?}"));
                    let old = std::mem::replace(current, value);
                    if !dirty.contains(&id) {
                        dirty.push(id);
                        // First write of this signal in the batch: its
                        // pre-transaction value, for barrier rollback.
                        rollback.insert(id, old);
                    }
                }
                TxOp::CreateWidget { id, kind } => {
                    assert!(
                        id.0 & INTERNAL_BIT == 0,
                        "kaya: widget id {id:?} uses the reserved internal bit"
                    );
                    let clash = self.widgets.insert(id, kind).is_some();
                    assert!(!clash, "kaya: widget id {id:?} already exists");
                    created.push(id);
                    // Interactive widgets carry their identity tag:
                    // buttons emit it on click, entries on edit. The
                    // predicate is shared with the STAMPING site below,
                    // which is the whole point — see
                    // WidgetKind::carries_tag.
                    let tag = kind
                        .carries_tag()
                        .then(|| Self::button_tag(id.0, &vec![]))
                        .flatten();
                    out.push(ApplyOp::Create { id, kind, tag });
                }
                TxOp::SetProperty {
                    widget,
                    prop,
                    value,
                } => {
                    let kind = *self
                        .widgets
                        .get(&widget)
                        .unwrap_or_else(|| panic!("kaya: property on unknown widget {widget:?}"));
                    check_prop(kind, prop);
                    match value {
                        PropValue::Const(v) => {
                            check_prop_value(kind, prop, &v);
                            // The select index's upper bound is scene
                            // state: options added SO FAR in op order
                            // (append-only), so "add options, then
                            // select" is the required tx shape and an
                            // out-of-range index dies at the root.
                            if is_choice(kind) && prop == Prop::Value {
                                if let Value::F64(idx) = &v {
                                    let count =
                                        self.select_options.get(&widget).copied().unwrap_or(0);
                                    assert!(
                                        (*idx as u32) < count,
                                        "kaya: select {widget:?} has {count} options; \
                                         index {idx} is out of range (add options \
                                         before selecting)"
                                    );
                                }
                            }
                            out.push(ApplyOp::SetProp {
                                id: widget,
                                prop,
                                value: v,
                            })
                        }
                        PropValue::Signal(id) => {
                            let current = self
                                .signals
                                .get(&id)
                                .unwrap_or_else(|| {
                                    panic!("kaya: binding to unknown signal {id:?}")
                                })
                                .clone();
                            // A signal's type is fixed at creation
                            // (check_type guards every write), so the
                            // current value speaks for the binding.
                            check_prop_value(kind, prop, &current);
                            // Same stance for the select index's upper
                            // bound: checked here against the current
                            // value; later writes only type-check
                            // (the progress-fraction policy).
                            if is_choice(kind) && prop == Prop::Value {
                                if let Value::F64(idx) = &current {
                                    let count =
                                        self.select_options.get(&widget).copied().unwrap_or(0);
                                    assert!(
                                        (*idx as u32) < count,
                                        "kaya: select {widget:?} has {count} options; \
                                         index {idx} is out of range (add options \
                                         before selecting)"
                                    );
                                }
                            }
                            self.bindings.entry(id).or_default().push((widget, prop));
                            out.push(ApplyOp::SetProp {
                                id: widget,
                                prop,
                                value: current,
                            });
                        }
                        PropValue::Element { .. } => {
                            panic!("kaya: element binding outside a template")
                        }
                    }
                }
                TxOp::SetWindowProp {
                    window,
                    prop,
                    value,
                } => {
                    assert!(
                        window == crate::protocol::DEFAULT_WINDOW
                            || self.windows.contains(&window),
                        "kaya: window prop on unknown window {window:?} — \
                         create_window first (0 is the primary)"
                    );
                    match value {
                        PropValue::Const(v) => {
                            check_window_prop_value(prop, &v);
                            out.push(ApplyOp::SetWindowProp {
                                window,
                                prop,
                                value: v,
                            })
                        }
                        PropValue::Signal(id) => {
                            let current = self
                                .signals
                                .get(&id)
                                .unwrap_or_else(|| {
                                    panic!("kaya: binding to unknown signal {id:?}")
                                })
                                .clone();
                            check_window_prop_value(prop, &current);
                            self.window_bindings
                                .entry(id)
                                .or_default()
                                .push((window, prop));
                            out.push(ApplyOp::SetWindowProp {
                                window,
                                prop,
                                value: current,
                            });
                        }
                        PropValue::Element { .. } => {
                            panic!("kaya: window properties cannot bind element sources")
                        }
                    }
                }
                TxOp::CreateWindow { window } => {
                    // Capability gate: the phones' systems own surface
                    // geometry — a host without aux windows rejects at
                    // the root, the column-baseline precedent
                    // (DESIGN.md, Presentation contexts).
                    #[cfg(any(target_os = "ios", target_os = "android"))]
                    {
                        let _ = window;
                        panic!(
                            "kaya: this host has no auxiliary windows \
                             (KAYA_CAP_AUX_WINDOWS is unset); the primary \
                             surface is the one window"
                        );
                    }
                    #[cfg(not(any(target_os = "ios", target_os = "android")))]
                    {
                        assert!(
                            window.0 != 0,
                            "kaya: window 0 is the primary and always exists"
                        );
                        assert!(
                            window.0 & INTERNAL_BIT == 0,
                            "kaya: window id {window:?} uses the reserved internal bit"
                        );
                        let fresh = self.windows.insert(window);
                        assert!(fresh, "kaya: window id {window:?} already exists");
                        out.push(ApplyOp::CreateWindow { window });
                    }
                }
                TxOp::DestroyWindow { window } => {
                    assert!(
                        window.0 != 0,
                        "kaya: the primary window is not destroyable — the \
                         process owns it"
                    );
                    let existed = self.windows.remove(&window);
                    assert!(existed, "kaya: destroy of unknown window {window:?}");
                    self.mounted_windows.remove(&window);
                    // A destroyed window takes its navigation stack
                    // with it — the entries' views go wholesale with
                    // the native window, no per-entry pops.
                    for entry in self.nav_stacks.remove(&window).unwrap_or_default() {
                        self.nav_entries.remove(&entry);
                        self.mounted_windows.remove(&entry);
                    }
                    // ... and its sections, each with ITS stack — the
                    // one way a section dies (the grammar itself has
                    // no destruction verbs).
                    for section in self.sections.remove(&window).unwrap_or_default() {
                        self.section_of.remove(&section);
                        self.mounted_windows.remove(&section);
                        for entry in self.nav_stacks.remove(&section).unwrap_or_default() {
                            self.nav_entries.remove(&entry);
                            self.mounted_windows.remove(&entry);
                        }
                    }
                    self.selected_section.remove(&window);
                    // ... and its command catalog: the chords free with
                    // the window (window ids are recreatable — a fresh
                    // window must not inherit a dead catalog's
                    // shortcuts), and the anchored trees revert to free
                    // roots. Items are append-only and outlive the
                    // window; their anchor does not.
                    self.window_shortcuts.remove(&window);
                    for root in self.window_menus.remove(&window).unwrap_or_default() {
                        self.menu_items.get_mut(&root).unwrap().anchor = None;
                    }
                    out.push(ApplyOp::DestroyWindow { window });
                }
                TxOp::ShowAlert(spec) => {
                    assert!(
                        spec.window == crate::protocol::DEFAULT_WINDOW
                            || self.windows.contains(&spec.window),
                        "kaya: show_alert over unknown window {:?} — \
                         create_window first (0 is the primary)",
                        spec.window
                    );
                    assert!(
                        spec.actions.len() <= 2,
                        "kaya: show_alert carries {} actions (the cap is 2 — \
                         the platform floor)",
                        spec.actions.len()
                    );
                    for (i, label) in spec.actions.iter().enumerate() {
                        assert!(
                            !label.is_empty(),
                            "kaya: show_alert action{i} has an empty label"
                        );
                    }
                    assert!(
                        !spec.cancel.is_empty(),
                        "kaya: show_alert cancel label is empty — the cancel \
                         slot always exists and needs a name"
                    );
                    // Liveness is process-global (the platform floor:
                    // ContentDialog throws on a second per root), and
                    // the result that frees the slot arrives on the
                    // presentation side — so the slot lives in capi's
                    // singleton, the one state both ends share.
                    crate::capi::alert_shown(spec.alert);
                    out.push(ApplyOp::PresentAlert(spec));
                }
                TxOp::ShowFileDialog(spec) => {
                    assert!(
                        spec.window == crate::protocol::DEFAULT_WINDOW
                            || self.windows.contains(&spec.window),
                        "kaya: show_file_dialog over unknown window {:?} — \
                         create_window first (0 is the primary)",
                        spec.window
                    );
                    for (label, _) in &spec.filters {
                        assert!(
                            !label.is_empty(),
                            "kaya: show_file_dialog carries a filter with an \
                             empty label — the label is what the picker shows"
                        );
                    }
                    // Same liveness rule and the same reason as alerts:
                    // process-global, freed by a result that arrives on
                    // the presentation side, so the slot lives in capi's
                    // singleton.
                    crate::capi::file_dialog_shown(spec.dialog);
                    out.push(ApplyOp::PresentFileDialog(spec));
                }
                TxOp::SetBrandAccent { seed, light, dark } => {
                    // SET ONCE, BEFORE THE FIRST MOUNT. Brand is
                    // identity, not state: a second write is a program
                    // error, and a post-mount write would promise the
                    // runtime theme-switching surface the vocabulary
                    // deliberately does not have (docs/styling-plan.md
                    // §2). Both die here, in the root's words, before
                    // any backend sees an accent it would have to
                    // un-apply.
                    assert!(
                        self.brand_accent.is_none(),
                        "kaya: set_brand_accent called twice — brand is set once, \
                         at startup; a slot that could flip at runtime would be a \
                         theme-switching surface, which the vocabulary does not \
                         promise (docs/styling-plan.md)"
                    );
                    assert!(
                        self.mounted_windows.is_empty(),
                        "kaya: set_brand_accent after a mount — brand is set once, \
                         BEFORE the first mount, so no backend ever shows an \
                         unbranded frame it must repaint"
                    );
                    // THE SEED IS A PACKED sRGB HEX AND NOTHING ELSE.
                    // Without this wall the binding-side spelling decides
                    // what a stray high byte means: an ARGB constant
                    // pasted where 0xRRGGBB belongs applied cleanly and
                    // reached every backend as seed AND fill (measured by
                    // the fan-out through Swift and Java — Java can even
                    // spell it as a negative int), while Compose feeds
                    // the raw word to Material's own derivation. One
                    // refusal here is the same answer in all eight
                    // languages; a per-binding precondition is eight.
                    for (word, which) in [(Some(seed), "seed"), (light, "light"), (dark, "dark")] {
                        if let Some(w) = word {
                            assert!(
                                w <= 0xFF_FFFF,
                                "kaya: brand {which} {w:#08x} is not a packed \
                                 sRGB hex — the accent is 0xRRGGBB, no alpha, \
                                 no extra bytes (docs/styling-plan.md D1)"
                            );
                        }
                    }
                    let accent = crate::brand::derive(seed, light, dark);
                    self.brand_accent = Some(accent);
                    out.push(ApplyOp::SetBrand { accent });
                }
                TxOp::ShowSaveDialog(spec) => {
                    assert!(
                        spec.window == crate::protocol::DEFAULT_WINDOW
                            || self.windows.contains(&spec.window),
                        "kaya: show_save_dialog over unknown window {:?} — \
                         create_window first (0 is the primary)",
                        spec.window
                    );
                    for (label, _) in &spec.filters {
                        assert!(
                            !label.is_empty(),
                            "kaya: show_save_dialog carries a filter with an \
                             empty label — the label is what the dialog shows"
                        );
                    }
                    // A SAVE DIALOG IS FOR NAMING A FILE, so an empty
                    // suggested name is an author who filled no field
                    // rather than a request for no name: every platform
                    // opens with SOMETHING in that box, and the one that
                    // does not (an empty NSSavePanel name field) disables
                    // its own Save button — a dialog nobody can complete.
                    assert!(
                        !spec.suggested_name.is_empty(),
                        "kaya: show_save_dialog has an empty suggested_name — \
                         name the file the dialog opens with (tx.save_file(\"notes.txt\"))"
                    );
                    // THE PICKER'S LIVE SLOT, not a second one: one dialog
                    // of either kind per process, so a guest that shows a
                    // save panel over a live picker is refused here rather
                    // than presenting two modals a platform cannot stack.
                    crate::capi::file_dialog_shown(spec.dialog);
                    out.push(ApplyOp::PresentSaveDialog(spec));
                }
                TxOp::Copy(clip) => {
                    // AN EMPTY CLIP IS A MISTAKE, not a way to clear:
                    // every platform distinguishes putting nothing on
                    // the clipboard from putting an empty string, and a
                    // copy that offers no representation at all can
                    // only be an author who filled none of the record.
                    assert!(
                        clip.text.is_some()
                            || clip.html.is_some()
                            || clip.image.is_some()
                            || !clip.files.is_empty()
                            || !clip.custom.is_empty(),
                        "kaya: copy offers no representation — fill at least one \
                         field of the clip record"
                    );
                    for (id, _) in &clip.custom {
                        assert!(
                            !id.is_empty(),
                            "kaya: a custom clip representation needs an id — it is \
                             the name the format round-trips under"
                        );
                        // The mime-shaped grammar, at the gate every
                        // binding passes; the reasons live on the
                        // check itself.
                        crate::wire::check_custom_id(id, "copy");
                    }
                    // Resolve every file handle to what the PLATFORM
                    // calls that file, here and not in four backends:
                    // this is where the picked table lives, and the
                    // two Rust-native backends would otherwise need a
                    // C entry to ask.
                    out.push(ApplyOp::Copy(crate::protocol::ClipOut {
                        text: clip.text,
                        html: clip.html,
                        image: clip.image,
                        files: clip
                            .files
                            .iter()
                            .map(|handle| crate::capi::picked_locator(*handle))
                            .collect(),
                        custom: clip.custom,
                    }));
                }
                TxOp::ReadClipboard { request, accepting } => {
                    // ACCEPTING NOTHING CANNOT SUCCEED, so it is an
                    // author error rather than a read that always
                    // answers empty — the empty answer means denied or
                    // absent, and conflating the two would hide a typo
                    // behind a legitimate outcome.
                    crate::wire::check_accept_list(&accepting, "read_clipboard");
                    out.push(ApplyOp::ReadClipboard { request, accepting });
                }
                TxOp::PushEntry { window, entry } => {
                    // No capability gate — every host materializes a
                    // serial stack natively (the deliberate contrast
                    // with create_window; DESIGN.md, Navigation).
                    // Stacks are PER-SURFACE: a section hosts its own
                    // stack (pushing into a section fell out of the
                    // same generalization mount made; DESIGN.md,
                    // Sections), and back routes to the ACTIVE
                    // section's stack on the backends.
                    assert!(
                        window == crate::protocol::DEFAULT_WINDOW
                            || self.windows.contains(&window)
                            || self.section_of.contains_key(&window),
                        "kaya: push_entry onto unknown surface {window:?} — \
                         create_window or add_section first (0 is the primary)"
                    );
                    assert!(
                        entry.0 != 0,
                        "kaya: surface id 0 is the primary window, not an entry"
                    );
                    assert!(
                        entry.0 & INTERNAL_BIT == 0,
                        "kaya: entry id {entry:?} uses the reserved internal bit"
                    );
                    // One surface namespace: an entry id must be fresh
                    // among windows AND entries.
                    assert!(
                        !self.windows.contains(&entry) && !self.nav_entries.contains_key(&entry),
                        "kaya: surface id {entry:?} already exists"
                    );
                    self.nav_entries.insert(entry, window);
                    self.nav_stacks.entry(window).or_default().push(entry);
                    out.push(ApplyOp::PushEntry { window, entry });
                }
                TxOp::PopEntry { window } => {
                    let stack = self.nav_stacks.get_mut(&window);
                    let entry = stack
                        .and_then(|s| s.pop())
                        .unwrap_or_else(|| {
                            panic!(
                                "kaya: pop_entry on window {window:?} with an \
                                 empty navigation stack"
                            )
                        });
                    self.nav_entries.remove(&entry);
                    self.mounted_windows.remove(&entry);
                    out.push(ApplyOp::PopEntry { window });
                }
                TxOp::AddSection { window, section } => {
                    // No capability gate — every platform has a
                    // sections idiom (the push_entry stance).
                    assert!(
                        window == crate::protocol::DEFAULT_WINDOW
                            || self.windows.contains(&window),
                        "kaya: add_section onto unknown window {window:?} — \
                         create_window first (0 is the primary)"
                    );
                    assert!(
                        section.0 != 0,
                        "kaya: surface id 0 is the primary window, not a section"
                    );
                    assert!(
                        section.0 & INTERNAL_BIT == 0,
                        "kaya: section id {section:?} uses the reserved internal bit"
                    );
                    // One surface namespace: fresh among windows,
                    // entries, AND sections.
                    assert!(
                        !self.windows.contains(&section)
                            && !self.nav_entries.contains_key(&section)
                            && !self.section_of.contains_key(&section),
                        "kaya: surface id {section:?} already exists"
                    );
                    self.section_of.insert(section, window);
                    let set = self.sections.entry(window).or_default();
                    set.push(section);
                    // The first added becomes selected — a window with
                    // sections always shows one.
                    self.selected_section.entry(window).or_insert(section);
                    out.push(ApplyOp::AddSection { window, section });
                }
                TxOp::SelectSection { window, section } => {
                    assert!(
                        self.section_of.get(&section) == Some(&window),
                        "kaya: select_section of {section:?} which is not a \
                         section of window {window:?} — add_section first"
                    );
                    self.selected_section.insert(window, section);
                    // Quiet by doctrine: configuration, no echo.
                    out.push(ApplyOp::SelectSection { window, section });
                }
                TxOp::SetSectionProp { section, prop, value } => {
                    assert!(
                        self.section_of.contains_key(&section),
                        "kaya: section prop on unknown section {section:?} — \
                         add_section first"
                    );
                    match value {
                        PropValue::Const(v) => {
                            check_section_prop_value(prop, &v);
                            out.push(ApplyOp::SetSectionProp { section, prop, value: v })
                        }
                        PropValue::Signal(id) => {
                            let current = self
                                .signals
                                .get(&id)
                                .unwrap_or_else(|| {
                                    panic!("kaya: binding to unknown signal {id:?}")
                                })
                                .clone();
                            check_section_prop_value(prop, &current);
                            self.section_bindings
                                .entry(id)
                                .or_default()
                                .push((section, prop));
                            out.push(ApplyOp::SetSectionProp {
                                section,
                                prop,
                                value: current,
                            });
                        }
                        PropValue::Element { .. } => {
                            panic!("kaya: section properties cannot bind element sources")
                        }
                    }
                }
                TxOp::SetEntryProp { entry, prop, value } => {
                    assert!(
                        self.nav_entries.contains_key(&entry),
                        "kaya: entry prop on unknown entry {entry:?} — \
                         push_entry first"
                    );
                    match value {
                        PropValue::Const(v) => {
                            check_entry_prop_value(prop, &v);
                            out.push(ApplyOp::SetEntryProp { entry, prop, value: v })
                        }
                        PropValue::Signal(id) => {
                            let current = self
                                .signals
                                .get(&id)
                                .unwrap_or_else(|| {
                                    panic!("kaya: binding to unknown signal {id:?}")
                                })
                                .clone();
                            check_entry_prop_value(prop, &current);
                            self.entry_bindings
                                .entry(id)
                                .or_default()
                                .push((entry, prop));
                            out.push(ApplyOp::SetEntryProp {
                                entry,
                                prop,
                                value: current,
                            });
                        }
                        PropValue::Element { .. } => {
                            panic!("kaya: entry properties cannot bind element sources")
                        }
                    }
                }
                TxOp::MenuItemCreate { item, kind } => {
                    assert!(item.0 != 0, "kaya: menu item id 0 is not a valid item");
                    assert!(
                        item.0 & INTERNAL_BIT == 0,
                        "kaya: menu item id {item:?} uses the reserved internal bit"
                    );
                    let clash = self
                        .menu_items
                        .insert(
                            item,
                            MenuItem {
                                kind,
                                parent: None,
                                anchor: None,
                                children: Vec::new(),
                                shortcut: None,
                                role: None,
                            },
                        )
                        .is_some();
                    assert!(!clash, "kaya: menu item id {item:?} already exists");
                    out.push(ApplyOp::MenuItemCreate { item, kind });
                }
                TxOp::MenuItemAppend { parent, child } => {
                    self.menu_item_append(parent, child, &mut out)
                }
                TxOp::MenubarAppend { window, item } => {
                    assert!(
                        window == crate::protocol::DEFAULT_WINDOW
                            || self.windows.contains(&window),
                        "kaya: menubar_append onto unknown window {window:?} — \
                         create_window first (0 is the primary)"
                    );
                    let kind = self
                        .menu_items
                        .get(&item)
                        .unwrap_or_else(|| {
                            panic!("kaya: menubar_append of unknown menu item {item:?}")
                        })
                        .kind;
                    self.assert_menu_root_free(item);
                    assert!(
                        is_menu_group(kind),
                        "kaya: the menu bar accepts only grouping nodes \
                         (menu or radio_group), got {kind:?}"
                    );
                    // Walk the subtree: depth cap + collect shortcuts (the
                    // bar is a shortcut home). A group root sits at depth 1.
                    let mut shortcuts = Vec::new();
                    self.validate_menu_subtree(item, 1, true, &mut shortcuts);
                    // Duplicate detection within THIS window's catalog and
                    // within the appended subtree — checked before any
                    // mutation so a reject leaves the catalog untouched.
                    let mut seen = std::collections::HashSet::new();
                    for sc in &shortcuts {
                        assert!(
                            seen.insert(sc.clone()),
                            "kaya: duplicate shortcut {sc:?} within window {window:?}'s catalog"
                        );
                        assert!(
                            !self
                                .window_shortcuts
                                .get(&window)
                                .is_some_and(|c| c.contains(sc)),
                            "kaya: duplicate shortcut {sc:?} within window {window:?}'s catalog"
                        );
                    }
                    self.window_shortcuts.entry(window).or_default().extend(shortcuts);
                    self.menu_items.get_mut(&item).unwrap().anchor =
                        Some(MenuAnchor::Window(window));
                    self.window_menus.entry(window).or_default().push(item);
                    out.push(ApplyOp::MenubarAppend { window, item });
                }
                TxOp::ContextAttach { widget, item } => {
                    let wkind = *self.widgets.get(&widget).unwrap_or_else(|| {
                        panic!("kaya: context_attach to unknown widget {widget:?}")
                    });
                    assert!(
                        !matches!(wkind, WidgetKind::Entry | WidgetKind::Textarea),
                        "kaya: context_attach rejected on {wkind:?} — the editable text \
                         controls keep their native edit menus (dress)"
                    );
                    self.validate_context_root(item);
                    self.menu_items.get_mut(&item).unwrap().anchor = Some(MenuAnchor::Context);
                    out.push(ApplyOp::ContextAttach { widget, item });
                }
                TxOp::ContextAttachNode { .. } => {
                    panic!(
                        "kaya: context_attach_node names a template node — it is valid only \
                         inside a For/When template scope (use context_attach for a live widget)"
                    )
                }
                TxOp::SetMenuProp { item, prop, value } => {
                    self.set_menu_prop(item, prop, value, &mut out)
                }
                TxOp::AddChild { parent, child } => {
                    assert!(
                        self.widgets.contains_key(&parent),
                        "kaya: add_child to unknown parent {parent:?}"
                    );
                    assert!(
                        self.widgets.contains_key(&child),
                        "kaya: add_child of unknown child {child:?}"
                    );
                    if self.widgets[&parent] == WidgetKind::Scroll {
                        let fresh = self.filled_scrolls.insert(parent);
                        assert!(
                            fresh,
                            "kaya: scroll {parent:?} already holds its one                              child — a scroll viewport takes exactly one                              (wrap the content in a column)"
                        );
                    }
                    // A choice widget's children ARE its options:
                    // label widgets, one per row/entry. Anything else
                    // has no options reading, so it dies here with
                    // one message rather than as four backend
                    // improvisations.
                    if is_choice(self.widgets[&parent]) {
                        assert!(
                            self.widgets[&child] == WidgetKind::Label,
                            "kaya: a {:?}'s children are its options — \
                             labels only, got {:?}",
                            self.widgets[&parent],
                            self.widgets[&child]
                        );
                        *self.select_options.entry(parent).or_insert(0) += 1;
                    }
                    // The edge, kept. Everything above validates it and
                    // forgets it; the reachability barrier needs it to
                    // survive the op. Last write wins, matching the
                    // backends: a second add_child of the same child
                    // reparents it.
                    assert!(
                        parent != child,
                        "kaya: add_child of {child:?} to itself"
                    );
                    assert!(
                        !self.widget_subtree_contains(child, parent),
                        "kaya: add_child of {child:?} under {parent:?} would create a \
                         cycle — {parent:?} is already inside {child:?}"
                    );
                    self.parent_of.insert(child, parent);
                    out.push(ApplyOp::AddChild { parent, child });
                }
                TxOp::Mount { window, root } => {
                    // The target's domain is SURFACES: the primary, a
                    // created window, a pushed navigation entry, or an
                    // added section (generalize the TARGET of mount,
                    // not the tree).
                    assert!(
                        window == crate::protocol::DEFAULT_WINDOW
                            || self.windows.contains(&window)
                            || self.nav_entries.contains_key(&window)
                            || self.section_of.contains_key(&window),
                        "kaya: mount into unknown surface {window:?} — \
                         create_window, push_entry, or add_section first \
                         (0 is the primary)"
                    );
                    assert!(
                        self.widgets.contains_key(&root),
                        "kaya: mount of unknown root {root:?}"
                    );
                    // The vocabulary landed: one mounted root PER
                    // WINDOW (a remount into the same window replaces
                    // its root wholesale on the backends).
                    let fresh = self.mounted_windows.insert(window, root).is_none();
                    assert!(
                        fresh,
                        "kaya: window {window:?} already has a mounted root"
                    );
                    out.push(ApplyOp::Mount { window, root });
                }
                TxOp::CreateCollection { id, variants } => {
                    Self::check_variants(id, &variants);
                    let clash = self
                        .collections
                        .insert(
                            id,
                            CollDecl {
                                scope: 0,
                                bound: false,
                                variants,
                            },
                        )
                        .is_some();
                    assert!(!clash, "kaya: collection id {id:?} already exists");
                    // A live-zone collection has exactly one instance,
                    // at the empty path, existing from declaration.
                    self.coll_instances
                        .insert((id, vec![]), CollInstance::default());
                }
                TxOp::CollectionInsert {
                    id,
                    path,
                    key,
                    variant,
                    record,
                } => self.insert_entry(id, path, key, variant, record, &mut out),
                TxOp::CollectionUpdate {
                    id,
                    path,
                    key,
                    variant,
                    record,
                } => self.update_entry(id, path, key, variant, record, &mut out),
                TxOp::CollectionUpdateField {
                    id,
                    path,
                    key,
                    variant,
                    field,
                    value,
                } => self.update_field_entry(id, path, key, variant, field, value, &mut out),
                TxOp::CollectionRemove { id, path, key } => {
                    self.remove_entry(id, path, key, &mut out)
                }
                TxOp::CollectionMove {
                    id,
                    path,
                    key,
                    before,
                } => self.move_entry(id, path, key, before, &mut out),
                TxOp::CreateFor { id, collection } => {
                    // Live For: a real container widget; its template
                    // scope opens here.
                    let wid = WidgetId(id);
                    assert!(
                        id & INTERNAL_BIT == 0,
                        "kaya: widget id {wid:?} uses the reserved internal bit"
                    );
                    let clash = self.widgets.insert(wid, WidgetKind::Column).is_some();
                    assert!(!clash, "kaya: widget id {wid:?} already exists");
                    created.push(wid);
                    out.push(ApplyOp::Create {
                        id: wid,
                        kind: WidgetKind::Column,
                        tag: None,
                    });
                    self.bind_collection(collection, 0);
                    self.next_scope += 1;
                    scopes.push(TplScope {
                        header: ScopeHeader::For { id, collection },
                        closed: Vec::new(),
                        current: TplSection::new(0),
                        explicit_cases: false,
                        scope: self.next_scope,
                    });
                }
                TxOp::CreateWhen { id, signal } => {
                    let wid = WidgetId(id);
                    assert!(
                        id & INTERNAL_BIT == 0,
                        "kaya: widget id {wid:?} uses the reserved internal bit"
                    );
                    let clash = self.widgets.insert(wid, WidgetKind::Column).is_some();
                    assert!(!clash, "kaya: widget id {wid:?} already exists");
                    created.push(wid);
                    out.push(ApplyOp::Create {
                        id: wid,
                        kind: WidgetKind::Column,
                        tag: None,
                    });
                    let current = self
                        .signals
                        .get(&signal)
                        .unwrap_or_else(|| panic!("kaya: When on unknown signal {signal:?}"));
                    assert!(
                        matches!(current, Value::Bool(_)),
                        "kaya: When must bind a Bool signal, {signal:?} is not"
                    );
                    self.next_scope += 1;
                    scopes.push(TplScope {
                        header: ScopeHeader::When { id, signal },
                        closed: Vec::new(),
                        current: TplSection::new(0),
                        explicit_cases: false,
                        scope: self.next_scope,
                    });
                }
                TxOp::WidgetCommand { widget, command } => {
                    let kind = *self
                        .widgets
                        .get(&widget)
                        .unwrap_or_else(|| panic!("kaya: command on unknown widget {widget:?}"));
                    check_command(kind, command);
                    // Momentary by construction: nothing is recorded, so
                    // nothing replays on rebuild — the op forwards and is
                    // forgotten.
                    out.push(ApplyOp::Command { id: widget, command });
                }
                TxOp::HighlightRanges { widget, ranges } => {
                    let text = self.range_text(widget, "highlight_ranges", &out);
                    let native = ranges
                        .iter()
                        .map(|r| check_range(&text, widget, "highlight_ranges", *r))
                        .collect();
                    out.push(ApplyOp::HighlightRanges { id: widget, ranges: native });
                }
                TxOp::SelectRange { widget, range } => {
                    let text = self.range_text(widget, "select_range", &out);
                    let native = check_range(&text, widget, "select_range", range);
                    out.push(ApplyOp::SelectRange { id: widget, range: native });
                }
                TxOp::RevealRange { widget, range } => {
                    let text = self.range_text(widget, "reveal_range", &out);
                    let native = check_range(&text, widget, "reveal_range", range);
                    out.push(ApplyOp::RevealRange { id: widget, range: native });
                }
                TxOp::VariantCase { .. } => {
                    panic!("kaya: variant_case outside a template scope")
                }
                TxOp::TemplateEnd => panic!("kaya: TemplateEnd outside a template scope"),
            }
        }
        assert!(
            scopes.is_empty(),
            "kaya: template scope left open at end of transaction"
        );

        // Barrier: validate every signal-bound menu prop on its COMPLETE
        // coalesced value BEFORE any fan-out mutates derived state
        // (SetProp emissions, When stamps). label/enabled/checked are
        // type-fixed by their signal; a radio group's `value` has a live
        // domain a late write can break. A rejection must not leave
        // partially-applied signal state — so restore every signal this
        // batch wrote, then propagate the panic (DESIGN.md, Menus).
        for id in &dirty {
            if let Some(bound) = self.menu_bindings.get(id).cloned() {
                let value = self.signals[id].clone();
                for (item, prop) in bound {
                    if let Err(msg) = self.check_menu_binding_domain(item, prop, &value) {
                        // A marked batch can put its COLLECTION edits
                        // back too, not just its signals: the group
                        // captured their pre-state on first touch. Same
                        // promise either way — a rejected batch leaves
                        // the scene as it was.
                        match group.take() {
                            Some(cap) => self.rollback_group(&cap, &rollback),
                            None => {
                                for (sid, old) in &rollback {
                                    self.signals.insert(*sid, old.clone());
                                }
                            }
                        }
                        panic!("{msg}");
                    }
                }
            }
        }

        // Barrier: every widget this batch created must be reachable
        // from a mounted root. Here — beside the menu domain check and
        // before the fan-out — for the same two reasons that one is
        // here. It must be a BARRIER and not a per-op check, because
        // ordering inside a transaction is free and a widget is an
        // orphan for most of the batch's length by design (guests/c/
        // a11y.c mints every widget, then makes 24 add_child calls, then
        // mounts, in one transaction). And it must run BEFORE the
        // fan-out, so a refusal has nothing derived to unwind.
        if let Some(orphan) = self.first_unreachable(&created) {
            // Signals only, and that is not an omission: a MARKED batch
            // cannot get here with anything to check, because
            // `undo_verdict` refuses create_widget/create_for/create_when
            // outright (:359, :383-384), so `created` is empty whenever
            // `group` is live and `first_unreachable` has already
            // returned None. The menu barrier above needs both arms; this
            // one has only the reachable arm, so it does not carry a
            // second that no input can take.
            debug_assert!(group.is_none(), "a marked batch cannot create widgets");
            for (sid, old) in &rollback {
                self.signals.insert(*sid, old.clone());
            }
            panic!("{}", self.orphan_message(orphan));
        }

        self.fan_out_signals(&dirty, &mut out);

        // EVERY programmatic text write this batch produced, read off
        // the ops themselves rather than from the four sites that emit
        // them. One place, and it cannot be bypassed by a fifth site:
        // this is what advances the core's record of each field's text
        // and what closes an episode when an app write changes it
        // (D7, narrowed by A3 to writes that actually differ).
        self.absorb_text_writes(&out);

        if let Some(cap) = group {
            self.bank_group(cap, &dirty, &rollback, &mut out);
        }
        out
    }

    /// The end-of-batch fan-out: every dirtied signal reaches everything
    /// bound to it. Its own method because an INVERSE takes the same
    /// path — a restored signal has to reach its widgets exactly as the
    /// write that is being undone did, and two copies of this walk would
    /// agree right up until they didn't.
    fn fan_out_signals(&mut self, dirty: &[SignalId], out: &mut Vec<ApplyOp>) {
        for id in dirty.iter().copied() {
            let value = self.signals[&id].clone();
            if let Some(bound) = self.bindings.get(&id) {
                for (widget, prop) in bound {
                    out.push(ApplyOp::SetProp {
                        id: *widget,
                        prop: *prop,
                        value: value.clone(),
                    });
                }
            }
            if let Some(bound) = self.window_bindings.get(&id) {
                for (window, prop) in bound {
                    out.push(ApplyOp::SetWindowProp {
                        window: *window,
                        prop: *prop,
                        value: value.clone(),
                    });
                }
            }
            if let Some(bound) = self.section_bindings.get(&id) {
                for (section, prop) in bound {
                    out.push(ApplyOp::SetSectionProp {
                        section: *section,
                        prop: *prop,
                        value: value.clone(),
                    });
                }
            }
            if let Some(bound) = self.entry_bindings.get(&id) {
                for (entry, prop) in bound {
                    out.push(ApplyOp::SetEntryProp {
                        entry: *entry,
                        prop: *prop,
                        value: value.clone(),
                    });
                }
            }
            if let Some(bound) = self.menu_bindings.get(&id) {
                for (item, prop) in bound {
                    out.push(ApplyOp::SetMenuProp {
                        item: *item,
                        prop: *prop,
                        value: value.clone(),
                    });
                }
            }
            if let Value::Bool(on) = value {
                self.toggle_whens(id, on, out);
            }
        }
    }

    // --- Undo: capture, bank, refuse (docs/undo-plan.md D3/D4) ----------

    /// One collection entry, as it stands now. `None` = no such entry.
    fn entry_state(
        instances: &HashMap<(CollectionId, PathKey), CollInstance>,
        id: CollectionId,
        path: &PathKey,
        key: &Key,
    ) -> Option<(u32, Record)> {
        instances
            .get(&(id, path.clone()))
            .and_then(|inst| inst.entries.get(key))
            .cloned()
    }

    /// Snapshot what an about-to-run delta op is going to disturb.
    ///
    /// FIRST TOUCH WINS, the rollback map's rule: the pre-state of the
    /// whole batch is what an inverse needs, not the state between two
    /// of its own ops. Takes the tables rather than `&self` so it can be
    /// called while the capture is borrowed out of the loop.
    fn capture_for_undo(
        collections: &HashMap<CollectionId, CollDecl>,
        instances: &HashMap<(CollectionId, PathKey), CollInstance>,
        op: &TxOp,
        cap: &mut GroupCapture,
    ) {
        // A delta naming a collection or instance that does not exist is
        // about to panic on its own terms; capturing nothing is right.
        let mut entry = |id: CollectionId, path: &[Value], key: &Value| {
            if !collections.contains_key(&id) {
                return;
            }
            let path: PathKey = path.iter().map(Key::from_value).collect();
            let key = Key::from_value(key);
            let at: EntryRef = (id, path.clone(), key.clone());
            if cap.entries.iter().any(|(had, _)| *had == at) {
                return;
            }
            let state = Self::entry_state(instances, id, &path, &key);
            cap.entries.push((at, state));
        };
        let mut order = |id: CollectionId, path: &[Value]| {
            let path: PathKey = path.iter().map(Key::from_value).collect();
            if cap.orders.iter().any(|((c, p), _)| *c == id && *p == path) {
                return;
            }
            if let Some(inst) = instances.get(&(id, path.clone())) {
                cap.orders.push(((id, path), inst.order.clone()));
            }
        };
        match op {
            TxOp::CollectionInsert { id, path, key, .. }
            | TxOp::CollectionRemove { id, path, key } => {
                entry(*id, path, key);
                // These change WHICH keys are in the order, so the
                // instance's order is part of the pre-state.
                order(*id, path);
            }
            TxOp::CollectionMove { id, path, key, .. } => {
                entry(*id, path, key);
                order(*id, path);
            }
            TxOp::CollectionUpdate { id, path, key, .. }
            | TxOp::CollectionUpdateField { id, path, key, .. } => entry(*id, path, key),
            // Signals need no capture here: `apply`'s rollback map
            // already holds every pre-transaction value, on first write.
            _ => {}
        }
    }

    /// Put the scene back to where a group found it, emitting nothing.
    ///
    /// The silence is the point: this runs on the refusal path, where
    /// the batch's ApplyOps die with the panic and no backend ever saw
    /// them. Signals first (the menu barrier's own restore), then
    /// entries, then orders — the same sequence an inverse uses, for the
    /// same reason: an entry cannot be positioned before it exists.
    fn rollback_group(&mut self, cap: &GroupCapture, rollback: &HashMap<SignalId, Value>) {
        for (id, old) in rollback {
            self.signals.insert(*id, old.clone());
        }
        for ((id, path, key), state) in &cap.entries {
            let inst = match self.coll_instances.get_mut(&(*id, path.clone())) {
                Some(inst) => inst,
                None => continue,
            };
            match state {
                Some(entry) => {
                    if inst.entries.insert(key.clone(), entry.clone()).is_none() {
                        inst.order.push(key.clone());
                    }
                }
                None => {
                    inst.entries.remove(key);
                    inst.order.retain(|k| k != key);
                }
            }
        }
        for ((id, path), order) in &cap.orders {
            if let Some(inst) = self.coll_instances.get_mut(&(*id, path.clone())) {
                inst.order = order.clone();
            }
        }
    }

    /// Close the group: compute both directions, push it onto the
    /// window's ledger, and tell the backend to clear the focused
    /// field's native history.
    ///
    /// THE CLEAR IS THE KEYSTONE (A1, §3). It runs on every group
    /// commit, unconditionally, because the core does not know what is
    /// focused and the backend that does can no-op in a nanosecond. What
    /// it buys: every episode begins with an empty native stack, so the
    /// native stack can never reach past the frontier episode's start,
    /// so one ledger read newest-first IS the user's history. The
    /// episode was banked before the clear, so no history is lost — only
    /// granularity.
    fn bank_group(
        &mut self,
        cap: GroupCapture,
        dirty: &[SignalId],
        rollback: &HashMap<SignalId, Value>,
        out: &mut Vec<ApplyOp>,
    ) {
        let mut inverse = UndoDelta::default();
        let mut forward = UndoDelta::default();
        for id in dirty {
            inverse.signals.push((*id, rollback[id].clone()));
            forward.signals.push((*id, self.signals[id].clone()));
        }
        for ((id, path, key), was) in &cap.entries {
            let now = Self::entry_state(&self.coll_instances, *id, path, key);
            if &now == was {
                continue; // the batch wrote it back to where it was
            }
            inverse.entries.push(UndoEntry {
                collection: *id,
                path: path_values(path),
                key: key.to_value(),
                state: was.clone(),
            });
            forward.entries.push(UndoEntry {
                collection: *id,
                path: path_values(path),
                key: key.to_value(),
                state: now,
            });
        }
        for ((id, path), was) in &cap.orders {
            let now = match self.coll_instances.get(&(*id, path.clone())) {
                Some(inst) => inst.order.clone(),
                None => continue,
            };
            if &now == was {
                continue;
            }
            inverse.orders.push(UndoOrder {
                collection: *id,
                path: path_values(path),
                keys: was.iter().map(Key::to_value).collect(),
            });
            forward.orders.push(UndoOrder {
                collection: *id,
                path: path_values(path),
                keys: now.iter().map(Key::to_value).collect(),
            });
        }
        let ledger = self.ledgers.entry(cap.window).or_default();
        // The frontier episode is banked as it stands; whatever the user
        // typed keeps its place in the order, and only its granularity
        // is spent by the clear below.
        if let Some(LedgerEntry::Episode(ep)) = ledger.done.last_mut() {
            ep.open = false;
        }
        ledger.done.push(LedgerEntry::Group {
            label: cap.label,
            inverse,
            forward,
        });
        // A new step invalidates the forward history — the rule every
        // undo system has, and the one the platforms apply to their own
        // text stacks on the next keystroke.
        ledger.redo.clear();
        out.push(ApplyOp::ClearUndo { window: cap.window });
    }

    /// Read every programmatic text write out of a finished batch's ops.
    ///
    /// ON THE OPS, NOT AT THE FOUR EMISSION SITES. A const set, a
    /// bind-time set, the end-of-batch signal flush, an element binding
    /// re-resolving, and `clear` all reach a field the same way — as one
    /// of these two ops — so reading them here is the only place that
    /// cannot be bypassed by a sixth site nobody remembers to visit.
    ///
    /// A3: only a write that CHANGES the text closes an episode. An app
    /// that mirrors a field into a signal and writes it back would
    /// otherwise lose its typing history on every keystroke.
    /// The text a range op is addressed against: the widget's content AS
    /// IT WILL BE when this batch lands.
    ///
    /// NOT SIMPLY `field_text`, and that is the whole method.
    /// `absorb_text_writes` runs at the END of a batch (one place, so a
    /// fifth emit site cannot bypass it), so while the batch is being
    /// applied `field_text` still holds the PREVIOUS text. The obvious
    /// app spelling —
    ///
    /// ```text
    /// tx.set_text(editor, new_document);
    /// tx.highlight(editor, matches_in(new_document));
    /// ```
    ///
    /// — would then be validated and converted against the old document.
    /// That is not a wrong colour: on macOS an out-of-range attribute is
    /// an NSRangeException and the process dies with exit 134
    /// (scratchpad/ranges-units.md §3, measured). So the ops this batch
    /// has already produced are consulted first, newest write wins.
    ///
    /// TEXTAREA ONLY (docs/ranges-plan.md D1): the entry's deferral is
    /// enforced here rather than described in a document, because the
    /// three platforms that cannot honour it honestly would each fail in
    /// their own way and one of them silently (GTK's entry highlight
    /// rides byte offsets that do not follow edits and is unreadable
    /// over AT-SPI).
    fn range_text(&self, widget: WidgetId, op: &str, out: &[ApplyOp]) -> String {
        let kind = self
            .widgets
            .get(&widget)
            .unwrap_or_else(|| panic!("kaya: {op} on unknown widget {widget:?}"));
        assert!(
            matches!(kind, WidgetKind::Textarea),
            "kaya: {op} on {widget:?}, which is a {kind:?} — text ranges are a \
             TEXTAREA surface this milestone. The entry is deferred with measured \
             reasons per platform (docs/deferred.md); an editor decorates a document"
        );
        for op in out.iter().rev() {
            match op {
                ApplyOp::SetProp { id, prop: Prop::Text, value: Value::Str(text) }
                    if *id == widget =>
                {
                    return text.clone()
                }
                ApplyOp::Command { id, command: CommandKind::Clear } if *id == widget => {
                    return String::new()
                }
                _ => {}
            }
        }
        self.field_text.get(&widget).cloned().unwrap_or_default()
    }

    fn absorb_text_writes(&mut self, out: &[ApplyOp]) {
        let mut writes: Vec<(WidgetId, String)> = Vec::new();
        for op in out {
            match op {
                ApplyOp::SetProp {
                    id,
                    prop: Prop::Text,
                    value: Value::Str(text),
                } => writes.push((*id, text.clone())),
                ApplyOp::Command {
                    id,
                    command: CommandKind::Clear,
                } => writes.push((*id, String::new())),
                _ => {}
            }
        }
        for (id, text) in writes {
            // Only the text-bearing INTERACTIVE kinds carry a native
            // undo stack; a label's text is not an edit history. A
            // stamped copy's kind is not in the widget table (its
            // blueprint holds it), so an internal id is admitted.
            let editable = match self.widgets.get(&id) {
                Some(kind) => matches!(kind, WidgetKind::Entry | WidgetKind::Textarea),
                None => id.0 & INTERNAL_BIT != 0,
            };
            if !editable {
                continue;
            }
            let changed = self.field_text.get(&id).map(String::as_str) != Some(text.as_str());
            self.field_text.insert(id, text);
            if changed {
                self.close_episodes_on(id);
            }
        }
    }

    /// A programmatic write landed on this field: any open episode on it
    /// is over. Across every ledger, because the core knows the widget
    /// and not its window — the scene keeps no widget-to-window map, and
    /// a field lives in exactly one window anyway.
    fn close_episodes_on(&mut self, field: WidgetId) {
        for ledger in self.ledgers.values_mut() {
            if let Some(LedgerEntry::Episode(ep)) = ledger.done.last_mut() {
                if ep.field == field {
                    ep.open = false;
                }
            }
        }
    }

    // --- Undo: episode banking (docs/undo-plan.md §3) -------------------

    /// A text_changed the backend is about to deliver to the guest,
    /// shown to the ledger on the way past.
    ///
    /// This is banking: the run of edits on one field between clears is
    /// ONE ledger entry, opened by the first event and extended by each
    /// one after. Nothing is copied — the two images plus the current
    /// position are all a coarse restore needs, and they are what a
    /// textarea-scale payload can afford.
    ///
    /// `focused` is the backend's answer for the field this event names.
    /// An event on an UNFOCUSED field closes the episode as it stands:
    /// the user is no longer there, so nothing further belongs to it.
    ///
    /// NOT for a text_changed the core itself provoked by routing a
    /// native undo — that one goes to `note_native_undo`, which walks
    /// the episode backwards instead of extending it forwards.
    pub(crate) fn note_text_changed(
        &mut self,
        window: WindowId,
        field: WidgetId,
        text: &str,
        focused: bool,
    ) {
        let before = self
            .field_text
            .get(&field)
            .cloned()
            .unwrap_or_default();
        // AN EVENT THAT TELLS THE LEDGER NOTHING IT ALREADY KNOWS IS NOT
        // A STEP. A COMMAND ACTS LIKE THE USER — `clear` deliberately
        // echoes, so the field emits its own text_changed("") and the
        // entry scene's second-add round depends on that (gtk.rs's Clear
        // arm) — but `absorb_text_writes` already recorded the field as
        // empty when the write went out. The echo therefore describes a
        // run from "" to "", and pushing it would put a step that does
        // nothing on top of the ledger: the user clicks add and the
        // first Cmd+Z spends itself on the clear's shadow instead of
        // taking back the add. That is the exact bug this milestone
        // exists to fix, one move over.
        //
        // The extend arm below already drops an episode that has typed
        // its way back to its own before-image, for the same reason
        // stated once. This is that rule where the run has not started
        // yet — and it is also why the redo stack survives: a report of
        // no change is not new typing, so the forward history has no
        // business dying on it.
        if before == text {
            return;
        }
        self.field_text.insert(field, text.to_owned());
        let ledger = self.ledgers.entry(window).or_default();
        // Typing is a new step: the forward history dies here, which is
        // the same rule the platforms apply to their own text stacks.
        ledger.redo.clear();
        match ledger.done.last_mut() {
            Some(LedgerEntry::Episode(ep)) if ep.open && ep.field == field => {
                // A REPORT OF WHERE THE RUN ALREADY IS CANNOT BECOME THE
                // NEW HIGH-WATER. `after` is where a redo goes; `current`
                // is where the field is now, and they differ only while a
                // native undo has walked the run backwards.
                //
                // A routed native undo is reported ONCE, by
                // `note_native_undo`: the backend marks the ordinary
                // text_changed its own undo provokes ledger-quiet, so that
                // one never arrives here. This is the second line — a
                // backend that forgets the mark delivers a text_changed
                // restating the walk's position, and lowering `after` to
                // it would erase the walk the redo side needs. The
                // no-change return above catches that too, whenever the
                // core's record of the field is current; this holds when
                // it is not, and its test drives exactly that state
                // because nothing else reaches this line.
                //
                // Ordinary typing is unaffected, mid-walk included: a new
                // position is a new high-water, and the platform's own
                // rule that a keystroke kills the native redo history is
                // inherited rather than fought (§3).
                if text != ep.current {
                    ep.after = text.to_owned();
                }
                ep.current = text.to_owned();
                if ep.current == ep.before {
                    // Typed all the way back to where the run started:
                    // the entry describes nothing and would be a step
                    // that does nothing.
                    ledger.done.pop();
                } else if !focused {
                    ep.open = false;
                }
            }
            _ => {
                if let Some(LedgerEntry::Episode(ep)) = ledger.done.last_mut() {
                    ep.open = false;
                }
                ledger.done.push(LedgerEntry::Episode(Episode {
                    field,
                    before,
                    after: text.to_owned(),
                    current: text.to_owned(),
                    open: focused,
                }));
            }
        }
    }

    /// The field a text_changed's identity tag names — the ledger's half
    /// of the emit, which carries the widget's stored tag rather than an
    /// id (the backend never learns what the tag means; it hands back
    /// what it was given).
    ///
    /// A STAMPED COPY ANSWERS WITH ITS OWN INTERNAL ID, which is the
    /// identity that CARRIES the text: it is what a programmatic write
    /// to the same field names (so `absorb_text_writes` and this agree),
    /// and what the backend reports as focused. The copy's app-facing
    /// name — (template node, key path) — is restored on the way out,
    /// where the payload is built.
    pub(crate) fn text_field_of_tag(&self, tag: &[u8]) -> Option<WidgetId> {
        match crate::wire::decode_text_changed_tag(tag, "") {
            Occurrence::TextChanged { id, .. } => Some(id),
            Occurrence::InstanceTextChanged { node, path, .. } => {
                self.instance_widget(node.0, &path)
            }
            _ => None,
        }
    }

    /// The internal widget a stamped copy's template node became, for
    /// the copy addressed by `path`.
    ///
    /// The stamps table is keyed by (collection, site path, key) and the
    /// copy's own path is the site path plus the key — the same
    /// `copy_path` the tag was built from (`button_tag`) — so the
    /// candidates are the stamps at that path, and the node map picks
    /// the widget among them. The collection is not in the tag and does
    /// not need to be: a template node belongs to exactly one blueprint.
    ///
    /// Linear in live copies, and deliberately so: the map that makes it
    /// O(1) would be a second index over the same facts, and a second
    /// index is a thing that drifts. If a scene ever makes this hot, the
    /// answer is a node-to-collection table built at declaration, not a
    /// copy of this one.
    fn instance_widget(&self, node: u64, path: &[Value]) -> Option<WidgetId> {
        let (key, site) = path.split_last()?;
        let key = Key::from_value(key);
        let site: PathKey = site.iter().map(Key::from_value).collect();
        self.stamps.iter().find_map(|((_, p, k), stamp)| {
            (*p == site && *k == key)
                .then(|| stamp.nodes.get(&node).copied())
                .flatten()
        })
    }

    /// What an `undone`/`redone` payload calls this field.
    ///
    /// A live widget is its own name. A stamped copy's internal id is
    /// NOT a name — no app has ever seen it, it cannot be resolved
    /// through any binding, and it changes when the row is stamped again
    /// — so the copy is named the way its own occurrences name it:
    /// template node plus key path (D5, and the option-A ruling of
    /// 2026-08-06). None means the field cannot be named at all, which
    /// after `teardown`'s drop is a field no ledger holds.
    fn field_identity(&self, field: WidgetId) -> Option<(u64, crate::protocol::Path)> {
        if field.0 & INTERNAL_BIT == 0 {
            return Some((field.0, Vec::new()));
        }
        self.stamps.iter().find_map(|((_, path, key), stamp)| {
            let node = *stamp.nodes.iter().find(|(_, w)| **w == field)?.0;
            let mut values = path_values(path);
            values.push(key.to_value());
            Some((node, values))
        })
    }

    /// An episode's restored text as the payload's one-entry texts run,
    /// or an EMPTY run for a field that can no longer be named — which
    /// is not a state a ledger reaches (`teardown` drops the episodes of
    /// a copy it destroys), and is an empty statement rather than a
    /// wrong one if it ever is.
    fn text_delta(&self, field: WidgetId, text: &str) -> Vec<crate::protocol::UndoText> {
        self.field_identity(field)
            .map(|(id, path)| crate::protocol::UndoText {
                id,
                path,
                text: text.to_owned(),
            })
            .into_iter()
            .collect()
    }

    /// The live widget an `undone` text entry describes: itself when it
    /// names one, or the copy that carries that template node now.
    ///
    /// RESOLVED AT APPLY, not stored: between banking and restoring, a
    /// row can be stamped again (an undone removal re-inserts it) and
    /// the copy's internal ids are new. The path names the row, so the
    /// write follows it.
    fn text_target(&self, text: &crate::protocol::UndoText) -> Option<WidgetId> {
        if text.path.is_empty() {
            Some(WidgetId(text.id))
        } else {
            self.instance_widget(text.id, &text.path)
        }
    }

    /// The text_changed a NATIVE undo produced, plus the field's own
    /// answer to "can you still undo?".
    ///
    /// Walks the frontier episode backwards rather than extending it. It
    /// ends three ways, and the third is the interesting one:
    ///
    /// - the text reached the before-image: the episode is spent as a
    ///   step back and is BANKED FORWARD, so the next undo takes whatever
    ///   is under it and a redo brings the typing back (below);
    /// - the field can still undo: the episode stays OPEN at its current
    ///   position, and further typing extends it (the platform's own
    ///   rule that a keystroke kills the redo history is inherited, not
    ///   fought);
    /// - the field is EXHAUSTED without having reached the before-image,
    ///   which means the platform coalesced across the episode's start.
    ///   A1's clear is supposed to make that unreachable — so this arm
    ///   falls back to the coarse restore and its test's job is to prove
    ///   the arm cannot be entered.
    ///
    /// THE FORWARD BANK IS WHAT KEEPS THE LEDGER SYMMETRIC. A walk that
    /// reaches the run's start has spent the platform's stack, so the
    /// episode leaves the done side — and the frontier moves to the entry
    /// underneath, which is a GROUP whenever A1's clear did its job. So
    /// `route_redo` can no longer offer the native tier, and if the
    /// episode were merely dropped the typing would be unreachable in
    /// both directions: the one hole D5's "walk back as often as you
    /// like" promise cannot have. Banked, it redoes through exactly the
    /// machinery a coarsely-undone episode already uses — its after-image
    /// written by the core, named by the same `redone` occurrence — and
    /// the only thing the user loses is the platform's finer granularity,
    /// which is the granularity degradation §3 already charges for.
    pub(crate) fn note_native_undo(
        &mut self,
        window: WindowId,
        field: WidgetId,
        text: &str,
        can_undo: bool,
    ) -> Option<(Vec<ApplyOp>, Occurrence)> {
        self.field_text.insert(field, text.to_owned());
        let ledger = self.ledgers.entry(window).or_default();
        let ep = match ledger.done.last_mut() {
            Some(LedgerEntry::Episode(ep)) if ep.field == field => ep,
            _ => return None,
        };
        ep.current = text.to_owned();
        if ep.current == ep.before {
            // Spent as a step back, and closed on the way over: the
            // native stack that was carrying it is empty now, so nothing
            // further belongs to this run — the same state the coarse
            // restore leaves an episode in, reached by the other tier.
            ep.open = false;
            let spent = ledger.done.pop().expect("just matched the frontier");
            ledger.redo.push(spent);
            return None;
        }
        if can_undo {
            return None;
        }
        // Exhausted mid-episode: finish the job the coarse way.
        let mut out = Vec::new();
        let occurrence = self.restore_episode_backwards(window, &mut out);
        occurrence.map(|occ| (out, occ))
    }

    // --- Undo: routing and the two entry points (D6, §3) ----------------

    /// Where an undo should go: the focused field's own stack, the
    /// core's ledger, or nowhere.
    ///
    /// `focused_can_undo` is A4's named query, answered by the backend
    /// (CanUndo, canUndo, undoManager.canUndo) and consumed here — ONE
    /// expression of the question, not a fifth hard-coded predicate.
    /// Enablement is this same call: `Nothing` is what a disabled
    /// Edit>Undo means, computed live at activation the way paste's
    /// offer-meets-accepts already is.
    pub(crate) fn route_undo(
        &self,
        window: WindowId,
        focused: Option<WidgetId>,
        focused_can_undo: bool,
    ) -> UndoRoute {
        match self.ledgers.get(&window).and_then(|l| l.done.last()) {
            None => UndoRoute::Nothing,
            Some(LedgerEntry::Episode(ep))
                if ep.open && Some(ep.field) == focused && focused_can_undo =>
            {
                UndoRoute::Native
            }
            Some(_) => UndoRoute::Core,
        }
    }

    /// Redo's twin. The frontier episode redoes NATIVELY while it is
    /// partly undone — the platform still holds those steps, and taking
    /// them back coarsely would throw away granularity the user can see.
    pub(crate) fn route_redo(
        &self,
        window: WindowId,
        focused: Option<WidgetId>,
        focused_can_redo: bool,
    ) -> UndoRoute {
        let ledger = match self.ledgers.get(&window) {
            Some(ledger) => ledger,
            None => return UndoRoute::Nothing,
        };
        if let Some(LedgerEntry::Episode(ep)) = ledger.done.last() {
            if ep.open
                && Some(ep.field) == focused
                && focused_can_redo
                && ep.current != ep.after
            {
                return UndoRoute::Native;
            }
        }
        if ledger.redo.is_empty() {
            UndoRoute::Nothing
        } else {
            UndoRoute::Core
        }
    }

    /// Undo the newest ledger entry: apply its inverse, move it to the
    /// redo side, and say what was put back.
    ///
    /// ONE OCCURRENCE AND NOTHING ELSE (D5). The inverse is a
    /// programmatic write, so the echo doctrine silences everything it
    /// touches — which is why the occurrence carries the whole restored
    /// state rather than a notification.
    pub(crate) fn undo(&mut self, window: WindowId) -> Option<(Vec<ApplyOp>, Occurrence)> {
        let mut out = Vec::new();
        let occurrence = self.restore_episode_backwards(window, &mut out)?;
        Some((out, occurrence))
    }

    /// The undo body, shared with the exhausted-episode fallback.
    fn restore_episode_backwards(
        &mut self,
        window: WindowId,
        out: &mut Vec<ApplyOp>,
    ) -> Option<Occurrence> {
        let entry = self.ledgers.get_mut(&window)?.done.pop()?;
        let (label, delta, back) = match entry {
            LedgerEntry::Group {
                label,
                inverse,
                forward,
            } => {
                let delta = inverse.clone();
                (
                    label.clone(),
                    delta,
                    LedgerEntry::Group {
                        label,
                        inverse,
                        forward,
                    },
                )
            }
            LedgerEntry::Episode(mut ep) => {
                // The coarse restore: the core writes the before-image
                // itself, which by D7 clears that field's native stack
                // — one correctly-ordered step, at the granularity a
                // banked episode has left.
                let delta = UndoDelta {
                    texts: self.text_delta(ep.field, &ep.before),
                    ..UndoDelta::default()
                };
                ep.current = ep.before.clone();
                ep.open = false;
                // EMPTY LABEL: a typing episode has no authored name and
                // kaya invents none ("Undo Typing" is an Apple
                // convention, not a scene string).
                (String::new(), delta, LedgerEntry::Episode(ep))
            }
        };
        self.apply_delta(&delta, out);
        self.ledgers.entry(window).or_default().redo.push(back);
        Some(Occurrence::Undone {
            window,
            label,
            delta,
        })
    }

    /// Redo the newest undone entry. Symmetric in every respect: the
    /// forward delta was computed at apply, beside the inverse, so a
    /// redo re-runs no handler and re-derives nothing.
    pub(crate) fn redo(&mut self, window: WindowId) -> Option<(Vec<ApplyOp>, Occurrence)> {
        let entry = self.ledgers.get_mut(&window)?.redo.pop()?;
        let (label, delta, back) = match entry {
            LedgerEntry::Group {
                label,
                inverse,
                forward,
            } => {
                let delta = forward.clone();
                (
                    label.clone(),
                    delta,
                    LedgerEntry::Group {
                        label,
                        inverse,
                        forward,
                    },
                )
            }
            LedgerEntry::Episode(mut ep) => {
                let delta = UndoDelta {
                    texts: self.text_delta(ep.field, &ep.after),
                    ..UndoDelta::default()
                };
                ep.current = ep.after.clone();
                (String::new(), delta, LedgerEntry::Episode(ep))
            }
        };
        let mut out = Vec::new();
        self.apply_delta(&delta, &mut out);
        self.ledgers.entry(window).or_default().done.push(back);
        Some((
            out,
            Occurrence::Redone {
                window,
                label,
                delta,
            },
        ))
    }

    /// Put a delta's state back into the scene and emit what the backend
    /// must do about it.
    ///
    /// THE ORDER IS THE CORRECTNESS. Signals first, so bound widgets
    /// follow their props. Then entries, so everything the order names
    /// exists. Then orders, so position is decided once and by the run
    /// that owns it. Then texts, which are the only part that touches
    /// widget-owned state and does so as an ordinary programmatic write.
    fn apply_delta(&mut self, delta: &UndoDelta, out: &mut Vec<ApplyOp>) {
        let from = out.len();
        let mut dirty: Vec<SignalId> = Vec::new();
        for (id, value) in &delta.signals {
            let current = self
                .signals
                .get_mut(id)
                .unwrap_or_else(|| panic!("kaya: undo writes unknown signal {id:?}"));
            check_type(current, value, &format!("signal {id:?}"));
            *current = value.clone();
            if !dirty.contains(id) {
                dirty.push(*id);
            }
        }
        self.fan_out_signals(&dirty, out);
        for entry in &delta.entries {
            let path: PathKey = entry.path.iter().map(Key::from_value).collect();
            let key = Key::from_value(&entry.key);
            let now = Self::entry_state(&self.coll_instances, entry.collection, &path, &key);
            match (&entry.state, now.is_some()) {
                (Some((variant, record)), true) => self.update_entry(
                    entry.collection,
                    entry.path.clone(),
                    entry.key.clone(),
                    *variant,
                    record.clone(),
                    out,
                ),
                (Some((variant, record)), false) => self.insert_entry(
                    entry.collection,
                    entry.path.clone(),
                    entry.key.clone(),
                    *variant,
                    record.clone(),
                    out,
                ),
                (None, true) => self.remove_entry(
                    entry.collection,
                    entry.path.clone(),
                    entry.key.clone(),
                    out,
                ),
                (None, false) => {}
            }
        }
        for order in &delta.orders {
            let path: PathKey = order.path.iter().map(Key::from_value).collect();
            let keys: Vec<Key> = order.keys.iter().map(Key::from_value).collect();
            self.restore_order(order.collection, &path, &keys, out);
        }
        for text in &delta.texts {
            // THE PAYLOAD NAMES THE FIELD THE APP'S WAY, so the write
            // has to translate back: a live widget is its own id, and a
            // stamped copy's field is whichever widget carries that
            // template node at that key path RIGHT NOW. A copy whose row
            // is gone resolves to nothing and writes nothing — the same
            // statement, applied to a world that no longer has the
            // widget, rather than a write into a destroyed id.
            let Some(field) = self.text_target(text) else {
                continue;
            };
            self.field_text.insert(field, text.text.clone());
            out.push(ApplyOp::SetProp {
                id: field,
                prop: Prop::Text,
                value: Value::Str(text.text.clone()),
            });
        }
        // An inverse is a programmatic write like any other, so D7 holds
        // for it too: restoring a signal bound to a field's text ends
        // that field's run and resets its native history. Read off the
        // ops this call added, the same one place a forward batch reads
        // its own from — the texts run above is already reconciled, so
        // it passes through as a no-change.
        let added = out.split_off(from);
        self.absorb_text_writes(&added);
        out.extend(added);
    }

    /// Restore an instance's key order, and its stamped copies with it.
    ///
    /// RIGHT TO LEFT, each copy moved before the one already placed
    /// after it: the last entry appends, and every earlier one anchors
    /// on its successor, so the container ends in exactly this order
    /// whatever it held before. O(entries) rather than O(change),
    /// deliberately — an order is not a set of independent facts, and a
    /// minimal move sequence would be a second reconciler.
    fn restore_order(
        &mut self,
        id: CollectionId,
        path: &PathKey,
        keys: &[Key],
        out: &mut Vec<ApplyOp>,
    ) {
        match self.coll_instances.get_mut(&(id, path.clone())) {
            Some(inst) => inst.order = keys.to_vec(),
            None => return,
        }
        let container = match self.for_sites.get(&(id, path.clone())) {
            Some(site) => site.container,
            None => return, // not rendered: the table alone is the state
        };
        let mut anchor: Option<WidgetId> = None;
        for key in keys.iter().rev() {
            let roots = match self.stamps.get(&(id, path.clone(), key.clone())) {
                Some(stamp) => stamp.roots.clone(),
                None => continue,
            };
            for child in &roots {
                out.push(ApplyOp::MoveChild {
                    parent: container,
                    child: *child,
                    before: anchor,
                });
            }
            if let Some(first) = roots.first() {
                anchor = Some(*first);
            }
        }
    }

    /// The user's back affordance popped an entry natively (predictive
    /// back, swipe-back, the desktop back button) — the backend informs
    /// the core POST-FACT, and the core-owned stack reconciles here.
    /// The counterpart of pop_entry with no ApplyOp: the platform
    /// already animated the pop. A user pop always takes the visible
    /// top; anything else is a backend bug and fails loudly.
    #[cfg_attr(
        not(any(target_os = "macos", target_os = "ios", target_os = "android")),
        allow(dead_code)
    )]
    // --- Mounted-root reachability ---------------------------------------
    //
    // A widget with no parent is not an error the way a bad id is: it is
    // WELL-FORMED and INVISIBLE. It enters the backends' per-kind
    // registries at create time, so `kind#index` resolves to it and every
    // harness read answers about it — while the screen shows nothing.
    // Swift's milestone2 window displayed two widgets for over two weeks
    // with every leg green (docs/deferred.md, the orphan entry), and its
    // menus.swift sibling shipped the same shape in the same commit.
    //
    // The core is the one layer that can refuse it once for everybody:
    // `Scene::apply` is the funnel for all five backends (gtk.rs:1079 and
    // :6412, winui/mod.rs:829, capi.rs:2335 for the two interpreters), so
    // this walk is one implementation covering nine guest languages, and
    // it fires in a real app that never runs the harness.
    //
    // WHAT IT DOES NOT COVER, stated so nobody reads it as total: an
    // orphan made by a BACKEND — one that receives ApplyOp::AddChild and
    // fails to reparent — is invisible here, because the core sees the op
    // and not the toolkit's tree. Only GTK's `WidgetExt::root()`, WinUI's
    // `XamlRoot` and the interpreters' `parents` maps can see that one.
    // No such defect is on record; all three recorded instances were made
    // above the core, in a binding.

    /// Is `target` inside `root`'s subtree (or `root` itself)? Walks
    /// UP from `target`, which is the direction the map runs. Bounded by
    /// the map's size so a pre-existing cycle cannot hang the caller
    /// that is checking for cycles.
    fn widget_subtree_contains(&self, root: WidgetId, target: WidgetId) -> bool {
        let mut at = target;
        for _ in 0..=self.parent_of.len() {
            if at == root {
                return true;
            }
            match self.parent_of.get(&at) {
                Some(parent) => at = *parent,
                None => return false,
            }
        }
        false
    }

    /// The first widget in `created` that no mounted root reaches, or
    /// None. Order is creation order, so the message names the widget an
    /// author wrote first rather than whichever one a hash map yielded.
    fn first_unreachable(&self, created: &[WidgetId]) -> Option<WidgetId> {
        if created.is_empty() {
            return None;
        }
        let roots: std::collections::HashSet<WidgetId> =
            self.mounted_windows.values().copied().collect();
        created
            .iter()
            .copied()
            .find(|id| !roots.contains(&self.top_ancestor(*id)))
    }

    /// The topmost widget above `id` (itself when it has no parent).
    /// Bounded by the map's size: `add_child` refuses to make a cycle, so
    /// this cannot spin — and if that refusal is ever removed, this
    /// returns a wrong answer instead of hanging the app thread.
    fn top_ancestor(&self, id: WidgetId) -> WidgetId {
        let mut at = id;
        for _ in 0..=self.parent_of.len() {
            match self.parent_of.get(&at) {
                Some(parent) => at = *parent,
                None => return at,
            }
        }
        at
    }

    /// The refusal text. It carries the diagnosis because the whole
    /// failure class is "it looked fine": the reader's screen is missing
    /// a widget and every assertion passed, so a bare "invalid tree"
    /// would send them to the backend. Every clause here is READ OFF THE
    /// SCENE, not guessed (docs/traps.md, "a diagnostic may only print
    /// what it measured"): the kind, the chain that was actually walked,
    /// and how many surfaces have a root at all.
    fn orphan_message(&self, orphan: WidgetId) -> String {
        let kind = self.widgets.get(&orphan);
        let top = self.top_ancestor(orphan);
        let mut chain = String::new();
        if top != orphan {
            // Strictly what was walked. NOT "its window was destroyed" —
            // the core cannot tell a root whose surface died from one
            // that was never mounted, and a diagnostic may only print
            // what it measured (docs/traps.md).
            chain = format!(
                " Walking up, its topmost ancestor is {top:?} ({:?}), and no live \
                 surface has that widget as its root.",
                self.widgets.get(&top)
            );
        }
        let surfaces = if self.mounted_windows.is_empty() {
            " NO surface in this app has a mounted root yet — if this \
             transaction builds the scene, it is missing its mount(root)."
                .to_string()
        } else {
            let mut mounted: Vec<String> = self
                .mounted_windows
                .iter()
                .map(|(w, r)| format!("{w:?}->{r:?}"))
                .collect();
            mounted.sort();
            format!(" Mounted roots right now: {}.", mounted.join(", "))
        };
        format!(
            "kaya: widget {orphan:?} ({kind:?}) was created by this transaction and is \
             not reachable from any mounted root — it will render NOWHERE while still \
             answering every harness read, so a scene asserting on it passes against an \
             invisible widget.{chain}{surfaces} Add it to a container (add_child), or \
             mount it as a surface's root. If you built it with a container's builder, \
             check that the body USES the handle rather than MENTIONING it: a bare \
             expression is discarded by Swift result builders and Kotlin lambdas, which \
             is how guests/swift/milestone2.swift and guests/swift/menus.swift both \
             shipped invisible widgets. Nothing was applied."
        )
    }

    /// The user switched sections through the platform's switcher —
    /// post-fact reconciliation of the core's selected-section mirror
    /// (the user_popped stance). Selecting a section that was never
    /// added is a backend bug and fails loudly.
    pub(crate) fn user_selected_section(&mut self, window: WindowId, section: WindowId) {
        assert!(
            self.section_of.get(&section) == Some(&window),
            "kaya: user selected {section:?} which is not a section of {window:?}"
        );
        self.selected_section.insert(window, section);
    }

    pub(crate) fn user_popped(&mut self, entry: WindowId) {
        let window = self
            .nav_entries
            .remove(&entry)
            .unwrap_or_else(|| panic!("kaya: user pop of unknown entry {entry:?}"));
        let stack = self
            .nav_stacks
            .get_mut(&window)
            .unwrap_or_else(|| panic!("kaya: user pop on window {window:?} with no stack"));
        let top = stack.pop();
        assert!(
            top == Some(entry),
            "kaya: user pop of {entry:?} but the top of {window:?}'s stack is {top:?}"
        );
        self.mounted_windows.remove(&entry);
    }

    // --- Menus -----------------------------------------------------------

    /// The topmost ancestor of a menu item (itself when it is a root).
    fn menu_root(&self, item: MenuItemId) -> MenuItemId {
        let mut cur = item;
        while let Some(parent) = self.menu_items[&cur].parent {
            cur = parent;
        }
        cur
    }

    /// The anchor of an item's whole tree (its root's anchor), or None if
    /// the tree is not anchored yet.
    fn anchored_root(&self, item: MenuItemId) -> Option<MenuAnchor> {
        self.menu_items[&self.menu_root(item)].anchor
    }

    /// The grouping-node depth of an item: grouping nodes on the path
    /// from its root down to and including it. A leaf does not deepen the
    /// chain; the cap (DESIGN.md, Menus) is a chain of at most two
    /// grouping nodes.
    fn menu_group_depth(&self, item: MenuItemId) -> u32 {
        let mut depth = 0;
        let mut cur = Some(item);
        while let Some(id) = cur {
            let it = &self.menu_items[&id];
            if is_menu_group(it.kind) {
                depth += 1;
            }
            cur = it.parent;
        }
        depth
    }

    /// Whether `target` sits anywhere in `root`'s subtree (root
    /// included) — the cycle guard for append.
    fn menu_subtree_contains(&self, root: MenuItemId, target: MenuItemId) -> bool {
        root == target
            || self.menu_items[&root]
                .children
                .iter()
                .any(|&c| self.menu_subtree_contains(c, target))
    }

    /// An item destined for an anchor or a new parent must be a free
    /// root — no parent, no anchor. Single-parent, no shared nodes.
    fn assert_menu_root_free(&self, item: MenuItemId) {
        let it = &self.menu_items[&item];
        assert!(
            it.parent.is_none() && it.anchor.is_none(),
            "kaya: menu item {item:?} already has a parent or anchor \
             (an item takes exactly one parent or anchor)"
        );
    }

    /// Walk a subtree from `item` (at grouping depth `depth`): enforce
    /// the depth cap on every grouping node, and either collect its
    /// shortcuts (a window catalog is a shortcut home) or reject any
    /// shortcut (a context anchor is not).
    fn validate_menu_subtree(
        &self,
        item: MenuItemId,
        depth: u32,
        is_bar: bool,
        shortcuts: &mut Vec<String>,
    ) {
        let it = &self.menu_items[&item];
        if is_menu_group(it.kind) {
            assert!(
                depth <= 2,
                "kaya: menu item {item:?} exceeds the depth cap \
                 (bar > grouping node > one nested grouping node > leaf)"
            );
        }
        if let Some(sc) = &it.shortcut {
            if is_bar {
                shortcuts.push(sc.clone());
            } else {
                panic!(
                    "kaya: shortcut {sc:?} on a context menu item {item:?} — \
                     a shortcut needs a window catalog home"
                );
            }
        }
        if let Some(role) = &it.role {
            assert!(
                is_bar,
                "kaya: role {role:?} on a context menu item {item:?} — a role \
                 names a standard command in the window catalog"
            );
        }
        for &child in &it.children {
            let child_depth = depth
                + u32::from(is_menu_group(self.menu_items[&child].kind));
            self.validate_menu_subtree(child, child_depth, is_bar, shortcuts);
        }
    }

    /// The shared front of context_attach and context_attach_node: the
    /// root must be a free root, must not be a radio_option, and its
    /// subtree must hold no shortcut (validated from the group-or-leaf
    /// starting depth).
    fn validate_context_root(&self, item: MenuItemId) {
        let kind = self
            .menu_items
            .get(&item)
            .unwrap_or_else(|| panic!("kaya: context attach of unknown menu item {item:?}"))
            .kind;
        self.assert_menu_root_free(item);
        assert!(
            !matches!(kind, MenuItemKind::RadioOption),
            "kaya: a context menu root cannot be a radio_option"
        );
        let mut shortcuts = Vec::new();
        self.validate_menu_subtree(item, u32::from(is_menu_group(kind)), false, &mut shortcuts);
    }

    /// Link `child` under grouping node `parent`, then — if the parent's
    /// tree is already anchored — re-validate the appended subtree in
    /// that anchor's context (depth, and shortcut collection/rejection).
    fn menu_item_append(&mut self, parent: MenuItemId, child: MenuItemId, out: &mut Vec<ApplyOp>) {
        let parent_kind = self
            .menu_items
            .get(&parent)
            .unwrap_or_else(|| panic!("kaya: menu_item_append to unknown parent {parent:?}"))
            .kind;
        let child_kind = self
            .menu_items
            .get(&child)
            .unwrap_or_else(|| panic!("kaya: menu_item_append of unknown child {child:?}"))
            .kind;
        assert!(parent != child, "kaya: a menu item cannot be its own parent");
        self.assert_menu_root_free(child);
        assert!(
            menu_accepts(parent_kind, child_kind),
            "kaya: a {parent_kind:?} menu item cannot contain a {child_kind:?}"
        );
        assert!(
            !self.menu_subtree_contains(child, parent),
            "kaya: menu_item_append of {child:?} under {parent:?} would create a cycle"
        );
        // If the parent's tree is anchored, the child joins that catalog
        // now — re-validate at the child's would-be absolute grouping
        // depth BEFORE linking, so a reject leaves the tree and the
        // catalog untouched (the MenubarAppend standard). The depth is
        // computed from the parent pre-link: the child is a free root,
        // so its post-link depth is the parent's plus its own grouping
        // contribution.
        if let Some(anchor) = self.anchored_root(parent) {
            let is_bar = matches!(anchor, MenuAnchor::Window(_));
            let start = self.menu_group_depth(parent) + u32::from(is_menu_group(child_kind));
            let mut shortcuts = Vec::new();
            self.validate_menu_subtree(child, start, is_bar, &mut shortcuts);
            if let MenuAnchor::Window(window) = anchor {
                let mut seen = std::collections::HashSet::new();
                for sc in &shortcuts {
                    assert!(
                        seen.insert(sc.clone()),
                        "kaya: duplicate shortcut {sc:?} within window {window:?}'s catalog"
                    );
                    assert!(
                        !self
                            .window_shortcuts
                            .get(&window)
                            .is_some_and(|c| c.contains(sc)),
                        "kaya: duplicate shortcut {sc:?} within window {window:?}'s catalog"
                    );
                }
                self.window_shortcuts.entry(window).or_default().extend(shortcuts);
            }
        }
        self.menu_items.get_mut(&child).unwrap().parent = Some(parent);
        self.menu_items.get_mut(&parent).unwrap().children.push(child);
        out.push(ApplyOp::MenuItemAppend { parent, child });
    }

    /// A radio group's `value` upper bound: the index must address an
    /// existing option (the select-index precedent — append the
    /// radio_option children first).
    fn check_radio_value_range(&self, item: MenuItemId, value: &Value) {
        if let Value::F64(idx) = value {
            let count = self.menu_items[&item].children.len() as u32;
            assert!(
                (*idx as u32) < count,
                "kaya: radio group {item:?} has {count} options; index {idx} is \
                 out of range (append radio_option children before selecting)"
            );
        }
    }

    /// Store a validated canonical shortcut on an action, and — for an
    /// action already in a window catalog — dup-check and register it.
    /// A shortcut on a context-anchored item is a root error.
    ///
    /// Props mutate freely (DESIGN.md, Menus), so a re-set REPLACES the
    /// item's own registration: the item's previous spelling leaves the
    /// window set before the new one is dup-checked in. The dup-check
    /// runs before any mutation, so a reject leaves both the registry
    /// and the item untouched.
    fn set_item_shortcut(&mut self, item: MenuItemId, spelling: String) {
        match self.anchored_root(item) {
            Some(MenuAnchor::Context) => panic!(
                "kaya: shortcut {spelling:?} on a context menu item {item:?} — \
                 a shortcut needs a window catalog home"
            ),
            Some(MenuAnchor::Window(window)) => {
                let old = self.menu_items[&item].shortcut.clone();
                let set = self.window_shortcuts.entry(window).or_default();
                assert!(
                    old.as_deref() == Some(spelling.as_str()) || !set.contains(&spelling),
                    "kaya: duplicate shortcut {spelling:?} within window {window:?}'s catalog"
                );
                if let Some(old) = old {
                    set.remove(&old);
                }
                set.insert(spelling.clone());
            }
            None => {}
        }
        self.menu_items.get_mut(&item).unwrap().shortcut = Some(spelling);
    }

    /// One standard command per role, window-anchored: a role can move
    /// an authored item into dress-owned chrome (macOS puts `settings`
    /// in the application menu), so two claimants would be two items
    /// racing for one native slot, and a context anchor has no such
    /// slot at all. Re-setting the same role on the same item is idle,
    /// the shortcut precedent.
    fn claim_menu_role(&mut self, item: MenuItemId, value: &Value) {
        let Value::Str(role) = value else { return };
        if let Some(MenuAnchor::Context) = self.anchored_root(item) {
            panic!(
                "kaya: role {role:?} on a context menu item {item:?} — a role \
                 names a standard command in the window catalog"
            );
        }
        if let Some(held) = self.menu_roles.get(role) {
            assert!(
                *held == item,
                "kaya: role {role:?} is already claimed by menu item {held:?} \
                 (one standard command per role)"
            );
        }
        self.menu_roles.insert(role.clone(), item);
        self.menu_items.get_mut(&item).unwrap().role = Some(role.clone());
    }

    fn set_menu_prop(
        &mut self,
        item: MenuItemId,
        prop: MenuProp,
        value: PropValue,
        out: &mut Vec<ApplyOp>,
    ) {
        let kind = self
            .menu_items
            .get(&item)
            .unwrap_or_else(|| panic!("kaya: set_menu_prop on unknown menu item {item:?}"))
            .kind;
        check_menu_prop(kind, prop);
        match value {
            PropValue::Const(v) => {
                check_menu_prop_value(prop, &v);
                if prop == MenuProp::Shortcut {
                    let Value::Str(spelling) = &v else { unreachable!() };
                    if let Err(msg) = validate_shortcut(spelling) {
                        panic!("{msg}");
                    }
                    self.set_item_shortcut(item, spelling.clone());
                }
                if prop == MenuProp::Value {
                    self.check_radio_value_range(item, &v);
                }
                if prop == MenuProp::Role {
                    check_menu_role(&v);
                    self.claim_menu_role(item, &v);
                }
                out.push(ApplyOp::SetMenuProp { item, prop, value: v });
            }
            PropValue::Signal(id) => {
                assert!(
                    is_bindable_menu_prop(prop),
                    "kaya: menu property {prop:?} is not signal-bindable \
                     (icon, symbol, primary, shortcut, and role are const-only)"
                );
                let current = self
                    .signals
                    .get(&id)
                    .unwrap_or_else(|| panic!("kaya: binding to unknown signal {id:?}"))
                    .clone();
                check_menu_prop_value(prop, &current);
                if prop == MenuProp::Value {
                    self.check_radio_value_range(item, &current);
                }
                self.menu_bindings.entry(id).or_default().push((item, prop));
                out.push(ApplyOp::SetMenuProp { item, prop, value: current });
            }
            PropValue::Element { .. } => {
                panic!("kaya: menu properties cannot bind element sources")
            }
        }
    }

    /// A menu binding's COALESCED value against its live domain, at the
    /// barrier. Only a radio group's `value` has a domain that a later
    /// coalesced write can break (label/enabled/checked are type-fixed
    /// by their signal). Returns the exact message the barrier must
    /// panic with (after restoring signal state).
    fn check_menu_binding_domain(
        &self,
        item: MenuItemId,
        prop: MenuProp,
        value: &Value,
    ) -> Result<(), String> {
        if prop == MenuProp::Value {
            if let Value::F64(idx) = value {
                if !(idx.is_finite() && *idx >= 0.0 && idx.fract() == 0.0) {
                    return Err(format!(
                        "kaya: a radio group's value is a 0-based option index \
                         (integral, non-negative), got {idx}"
                    ));
                }
                let count = self
                    .menu_items
                    .get(&item)
                    .map_or(0, |it| it.children.len() as u32);
                if (*idx as u32) >= count {
                    return Err(format!(
                        "kaya: radio group {item:?} has {count} options; index {idx} \
                         is out of range"
                    ));
                }
            }
        }
        Ok(())
    }

    /// One record of a template declaration. Creation records describe;
    /// nothing executes until data stamps the template.
    fn declare(&mut self, op: TxOp, scopes: &mut Vec<TplScope>, out: &mut Vec<ApplyOp>) {
        let top = scopes.last_mut().unwrap();
        match op {
            TxOp::CreateWidget { id, kind } => {
                let clash = self.template_nodes.insert(id.0, kind).is_some();
                assert!(!clash, "kaya: template node id {} already exists", id.0);
                top.current.declared.push(id.0);
                top.current.ops.push(TplOp::Widget { node: id.0, kind });
            }
            TxOp::SetProperty {
                widget,
                prop,
                value,
            } => {
                assert!(
                    top.current.declared.contains(&widget.0),
                    "kaya: property on node {} not declared in this template case",
                    widget.0
                );
                let node_kind = self.template_nodes[&widget.0];
                check_prop(node_kind, prop);
                match &value {
                    PropValue::Const(v) => check_prop_value(node_kind, prop, v),
                    PropValue::Signal(id) => {
                        let current = self.signals.get(id).unwrap_or_else(|| {
                            panic!("kaya: binding to unknown signal {id:?}")
                        });
                        check_prop_value(node_kind, prop, current);
                    }
                    PropValue::Element { level, field } => {
                        let depth = scopes
                            .iter()
                            .filter(|s| matches!(s.header, ScopeHeader::For { .. }))
                            .count() as u32;
                        assert!(
                            *level < depth,
                            "kaya: element level {level} exceeds For nesting depth {depth}"
                        );
                        // The For `level` Fors up names a collection whose
                        // schema is already declared — and the case being
                        // parsed there names which variant's schema this
                        // binding sees. Validated here, before anything
                        // ever stamps: index in bounds, field type
                        // against prop type, within that variant.
                        let (collection, variant) = scopes
                            .iter()
                            .rev()
                            .filter_map(|s| match s.header {
                                ScopeHeader::For { collection, .. } => {
                                    Some((collection, s.current.variant))
                                }
                                ScopeHeader::When { .. } => None,
                            })
                            .nth(*level as usize)
                            .expect("level checked against For depth above");
                        let schema = &self.collections[&collection].variants[variant as usize];
                        assert!(
                            (*field as usize) < schema.len(),
                            "kaya: field {field} out of bounds for variant {variant} of \
                             {collection:?} ({} fields)",
                            schema.len()
                        );
                        assert!(
                            schema[*field as usize] == prop_value_type(prop),
                            "kaya: {prop:?} cannot bind field {field} of variant {variant} \
                             of {collection:?} (a {:?} field)",
                            schema[*field as usize]
                        );
                        // Re-borrow after the immutable walk above.
                        let top = scopes.last_mut().unwrap();
                        top.current.ops.push(TplOp::SetProp {
                            node: widget.0,
                            prop,
                            value,
                        });
                        return;
                    }
                }
                let top = scopes.last_mut().unwrap();
                top.current.ops.push(TplOp::SetProp {
                    node: widget.0,
                    prop,
                    value,
                });
            }
            TxOp::AddChild { parent, child } => {
                assert!(
                    top.current.declared.contains(&parent.0)
                        && top.current.declared.contains(&child.0),
                    "kaya: add_child across template cases ({} <- {})",
                    parent.0,
                    child.0
                );
                assert!(
                    !top.current.childed.contains(&child.0),
                    "kaya: template node {} already has a parent",
                    child.0
                );
                // THE STRUCTURAL RULES THE LIVE PATH ENFORCES, ENFORCED
                // HERE TOO. A scroll takes exactly one child and a
                // choice's children are its options, and both were
                // checked only on the live `AddChild`
                // (crates/kaya/src/scene.rs, the `TxOp::AddChild` arm
                // outside a template). Recording a template ran none of
                // them, so a malformed prototype recorded clean,
                // declared clean, and reached four backends as a shape
                // none of them has a reading for.
                //
                // It was unreachable through sugar until 2026-08-10 for
                // the same reason D1 was: no binding had a template
                // constructor for scroll, select or radio, so only the
                // widget-kind floor could build one. The sugar pass
                // shipped those constructors, which is exactly when a
                // rule enforced on one path and not the other stops
                // being theoretical (docs/sugar-pass-plan.md).
                //
                // Checked at RECORD time, not at stamp: the prototype is
                // wrong once, and a message about the guest's own
                // declaration beats the same message repeated per row.
                let parent_kind = self.template_nodes[&parent.0];
                let child_kind = self.template_nodes[&child.0];
                if parent_kind == WidgetKind::Scroll {
                    let already = top.current.ops.iter().any(|op| {
                        matches!(op, TplOp::AddChild { parent: p, .. } if *p == parent.0)
                    });
                    assert!(
                        !already,
                        "kaya: template scroll {} already holds its one child — a \
                         scroll viewport takes exactly one (wrap the content in a \
                         column)",
                        parent.0
                    );
                }
                if is_choice(parent_kind) {
                    assert!(
                        child_kind == WidgetKind::Label,
                        "kaya: a template {parent_kind:?}'s children are its options \
                         — labels only, got {child_kind:?}"
                    );
                }
                top.current.childed.push(child.0);
                let top = scopes.last_mut().unwrap();
                top.current.ops.push(TplOp::AddChild {
                    parent: parent.0,
                    child: child.0,
                });
            }
            TxOp::CreateCollection { id, variants } => {
                Self::check_variants(id, &variants);
                let scope = top.scope;
                let clash = self
                    .collections
                    .insert(
                        id,
                        CollDecl {
                            scope,
                            bound: false,
                            variants,
                        },
                    )
                    .is_some();
                assert!(!clash, "kaya: collection id {id:?} already exists");
                top.current.ops.push(TplOp::Collection { id });
            }
            TxOp::CreateFor { id, collection } => {
                let clash = self
                    .template_nodes
                    .insert(id, WidgetKind::Column)
                    .is_some();
                assert!(!clash, "kaya: template node id {id} already exists");
                let scope = top.scope;
                top.current.declared.push(id);
                self.bind_collection(collection, scope);
                self.next_scope += 1;
                scopes.push(TplScope {
                    header: ScopeHeader::For { id, collection },
                    closed: Vec::new(),
                    current: TplSection::new(0),
                    explicit_cases: false,
                    scope: self.next_scope,
                });
            }
            TxOp::CreateWhen { id, signal } => {
                let clash = self
                    .template_nodes
                    .insert(id, WidgetKind::Column)
                    .is_some();
                assert!(!clash, "kaya: template node id {id} already exists");
                let current = self
                    .signals
                    .get(&signal)
                    .unwrap_or_else(|| panic!("kaya: When on unknown signal {signal:?}"));
                assert!(
                    matches!(current, Value::Bool(_)),
                    "kaya: When must bind a Bool signal, {signal:?} is not"
                );
                top.current.declared.push(id);
                self.next_scope += 1;
                scopes.push(TplScope {
                    header: ScopeHeader::When { id, signal },
                    closed: Vec::new(),
                    current: TplSection::new(0),
                    explicit_cases: false,
                    scope: self.next_scope,
                });
            }
            TxOp::VariantCase { variant } => {
                let ScopeHeader::For { collection, .. } = top.header else {
                    panic!("kaya: variant_case inside a When (only For eliminates a sum)");
                };
                let count = self.collections[&collection].variants.len() as u32;
                assert!(
                    variant < count,
                    "kaya: variant_case {variant} out of bounds for {collection:?} \
                     ({count} variants)"
                );
                if top.explicit_cases {
                    // Close the previous case; its blueprint is done.
                    let section = std::mem::replace(&mut top.current, TplSection::new(variant));
                    top.closed.push(section.into_body());
                } else {
                    // First case of the scope: nothing may precede it —
                    // records before the first variant_case would belong
                    // to no constructor.
                    assert!(
                        top.current.ops.is_empty() && top.current.declared.is_empty(),
                        "kaya: template records before the first variant_case of \
                         {collection:?}"
                    );
                    top.explicit_cases = true;
                    top.current = TplSection::new(variant);
                }
                assert!(
                    !top.closed.iter().any(|(v, _)| *v == variant),
                    "kaya: variant_case {variant} declared twice for {collection:?}"
                );
            }
            TxOp::TemplateEnd => {
                let closed = scopes.pop().unwrap();
                let bodies = self.close_scope_bodies(closed);
                match (scopes.last_mut(), bodies) {
                    // Nested: fold into the parent template.
                    (Some(parent), ClosedScope::For { id, collection, bodies }) => {
                        parent.current.ops.push(TplOp::For {
                            node: id,
                            collection,
                            bodies,
                        });
                    }
                    (Some(parent), ClosedScope::When { id, signal, body }) => {
                        parent.current.ops.push(TplOp::When {
                            node: id,
                            signal,
                            body,
                        });
                    }
                    // Top level: the live site starts rendering now.
                    (None, ClosedScope::For { id, collection, bodies }) => {
                        self.register_for_site(
                            collection,
                            vec![],
                            WidgetId(id),
                            bodies,
                            vec![],
                            out,
                        );
                    }
                    (None, ClosedScope::When { id, signal, body }) => {
                        self.register_when_site(
                            signal,
                            WidgetId(id),
                            body,
                            vec![],
                            vec![],
                            out,
                        );
                    }
                }
            }
            TxOp::ContextAttachNode { node, item } => {
                assert!(
                    top.current.declared.contains(&node.0),
                    "kaya: context_attach_node on node {} not declared in this template case",
                    node.0
                );
                let node_kind = self.template_nodes[&node.0];
                assert!(
                    !matches!(node_kind, WidgetKind::Entry | WidgetKind::Textarea),
                    "kaya: context_attach_node rejected on {node_kind:?} — the editable \
                     text controls keep their native edit menus (dress)"
                );
                // The menu item tree is live (items are not stamped in
                // v1) — validate it as a context root and anchor it once.
                // Every stamped copy shares this tree; only the noun key
                // path differs per copy.
                self.validate_context_root(item);
                self.menu_items.get_mut(&item).unwrap().anchor = Some(MenuAnchor::Context);
                top.current.ops.push(TplOp::ContextAttachNode { node: node.0, item });
            }
            other => panic!("kaya: {other:?} is not valid inside a template"),
        }
    }

    /// Assemble a closed scope's blueprint(s). A For's cases must be
    /// total — one body per variant of its collection's sum, in
    /// discriminant order — with the caseless scope standing for the
    /// one-variant For. An empty case is the explicit way to render a
    /// constructor as nothing; a missing one dies here, at declaration,
    /// not on the first insert of the unlucky variant.
    fn close_scope_bodies(&self, scope: TplScope) -> ClosedScope {
        let TplScope { header, closed, current, explicit_cases, .. } = scope;
        match header {
            ScopeHeader::For { id, collection } => {
                let count = self.collections[&collection].variants.len();
                let mut cases = closed;
                let explicit = explicit_cases;
                cases.push(current.into_body());
                let bodies = if explicit {
                    let mut bodies: Vec<Option<Arc<TplBody>>> = vec![None; count];
                    for (variant, body) in cases {
                        bodies[variant as usize] = Some(body);
                    }
                    bodies
                        .into_iter()
                        .enumerate()
                        .map(|(variant, body)| {
                            body.unwrap_or_else(|| {
                                panic!(
                                    "kaya: For over {collection:?} declares no case for \
                                     variant {variant} (an empty case renders nothing; \
                                     a missing one is a hole in the eliminator)"
                                )
                            })
                        })
                        .collect()
                } else {
                    assert!(
                        count == 1,
                        "kaya: For over {collection:?} needs a variant_case per variant \
                         ({count} variants, none declared)"
                    );
                    cases.into_iter().map(|(_, body)| body).collect()
                };
                ClosedScope::For { id, collection, bodies }
            }
            ScopeHeader::When { id, signal } => {
                assert!(
                    !explicit_cases,
                    "kaya: variant_case inside a When (only For eliminates a sum)"
                );
                let (_, body) = current.into_body();
                ClosedScope::When { id, signal, body }
            }
        }
    }

    /// The schema-shape checks shared by live and template collection
    /// declarations. A unit variant (no fields) is legal inside a real
    /// sum — a `Divider` constructor carries no data — but the
    /// one-variant zero-field collection stays an error, as it always
    /// was: a record with no fields holds nothing.
    fn check_variants(id: CollectionId, variants: &[Vec<ValueType>]) {
        assert!(
            !variants.is_empty(),
            "kaya: collection {id:?} declares no variants"
        );
        assert!(
            !(variants.len() == 1 && variants[0].is_empty()),
            "kaya: collection {id:?} declares an empty schema"
        );
    }

    fn bind_collection(&mut self, collection: CollectionId, scope: u64) {
        let decl = self
            .collections
            .get_mut(&collection)
            .unwrap_or_else(|| panic!("kaya: For over unknown collection {collection:?}"));
        assert!(
            decl.scope == scope,
            "kaya: For must bind a collection declared in its own scope"
        );
        assert!(
            !decl.bound,
            "kaya: collection {collection:?} is already bound to a For"
        );
        decl.bound = true;
    }

    /// A For starts rendering a collection instance: register the site
    /// and stamp any entries already in the table.
    fn register_for_site(
        &mut self,
        collection: CollectionId,
        path: PathKey,
        container: WidgetId,
        bodies: Vec<Arc<TplBody>>,
        chain: Vec<EntryRef>,
        out: &mut Vec<ApplyOp>,
    ) {
        let existing: Vec<Key> = self
            .coll_instances
            .get(&(collection, path.clone()))
            .unwrap_or_else(|| {
                panic!("kaya: For site over missing instance of {collection:?}")
            })
            .order
            .clone();
        self.for_sites.insert(
            (collection, path.clone()),
            ForSite {
                container,
                bodies,
                chain: chain.clone(),
            },
        );
        for key in existing {
            self.stamp_entry(collection, &path, &key, out);
        }
    }

    fn register_when_site(
        &mut self,
        signal: SignalId,
        container: WidgetId,
        body: Arc<TplBody>,
        path: PathKey,
        chain: Vec<EntryRef>,
        out: &mut Vec<ApplyOp>,
    ) -> u64 {
        self.next_when_site += 1;
        let site = self.next_when_site;
        self.when_sites.insert(
            site,
            WhenSite {
                signal,
                container,
                body,
                path,
                chain,
                stamp: None,
            },
        );
        self.when_by_signal.entry(signal).or_default().push(site);
        if matches!(self.signals[&signal], Value::Bool(true)) {
            self.toggle_when_site(site, true, out);
        }
        site
    }

    // --- Collection deltas ------------------------------------------------

    fn instance_mut(&mut self, id: CollectionId, path: &PathKey) -> &mut CollInstance {
        assert!(
            self.collections.contains_key(&id),
            "kaya: delta on unknown collection {id:?}"
        );
        self.coll_instances
            .get_mut(&(id, path.clone()))
            .unwrap_or_else(|| {
                panic!("kaya: no instance of {id:?} at path {path:?} (wrong path, or not stamped)")
            })
    }

    fn variants_of(&self, id: CollectionId) -> Vec<Vec<ValueType>> {
        self.collections
            .get(&id)
            .unwrap_or_else(|| panic!("kaya: delta on unknown collection {id:?}"))
            .variants
            .clone()
    }

    fn variant_schema(&self, id: CollectionId, variant: u32, what: &str) -> Vec<ValueType> {
        let variants = self.variants_of(id);
        assert!(
            (variant as usize) < variants.len(),
            "kaya: {what} names variant {variant} of {id:?} ({} variants)",
            variants.len()
        );
        variants[variant as usize].clone()
    }

    fn insert_entry(
        &mut self,
        id: CollectionId,
        path: Vec<Value>,
        key: Value,
        variant: u32,
        record: Record,
        out: &mut Vec<ApplyOp>,
    ) {
        let schema = self.variant_schema(id, variant, "insert");
        check_record(&schema, &record, &format!("insert into {id:?}"));
        let path: PathKey = path.iter().map(Key::from_value).collect();
        let key = Key::from_value(&key);
        let inst = self.instance_mut(id, &path);
        assert!(
            !inst.entries.contains_key(&key),
            "kaya: key {key:?} already present in {id:?} at {path:?} (update is explicit)"
        );
        inst.order.push(key.clone());
        inst.entries.insert(key.clone(), (variant, record));
        self.stamp_entry(id, &path, &key, out);
    }

    fn update_entry(
        &mut self,
        id: CollectionId,
        path: Vec<Value>,
        key: Value,
        variant: u32,
        record: Record,
        out: &mut Vec<ApplyOp>,
    ) {
        let schema = self.variant_schema(id, variant, "update");
        check_record(&schema, &record, &format!("update of {id:?}"));
        let path: PathKey = path.iter().map(Key::from_value).collect();
        let key = Key::from_value(&key);
        let inst = self.instance_mut(id, &path);
        let current = inst
            .entries
            .get_mut(&key)
            .unwrap_or_else(|| panic!("kaya: update of missing key {key:?} in {id:?}"));
        let was = current.0;
        *current = (variant, record.clone());
        if was != variant {
            // The entry changed constructor: its copy is a different
            // blueprint now. Tear down, restamp from the new case, and
            // put the fresh copy back in the entry's slot — the key
            // kept its position in the order; only the shape changed.
            if let Some(stamp) = self.stamps.remove(&(id, path.clone(), key.clone())) {
                self.teardown(stamp, out);
            }
            self.stamp_entry(id, &path, &key, out);
            self.reposition_restamp(id, &path, &key, out);
            return;
        }
        // Same constructor: the data changed; every property fed by
        // this entry follows, each from its own field.
        if let Some(bound) = self.element_bindings.get(&(id, path, key)) {
            for (widget, prop, field) in bound {
                out.push(ApplyOp::SetProp {
                    id: *widget,
                    prop: *prop,
                    value: record[*field as usize].clone(),
                });
            }
        }
    }

    /// A restamped copy was appended to its container; move it back to
    /// the entry's position by anchoring before the next stamped
    /// neighbor in the order (None when the entry is last).
    fn reposition_restamp(
        &mut self,
        id: CollectionId,
        path: &PathKey,
        key: &Key,
        out: &mut Vec<ApplyOp>,
    ) {
        let Some(site) = self.for_sites.get(&(id, path.clone())) else {
            return;
        };
        let container = site.container;
        let inst = &self.coll_instances[&(id, path.clone())];
        let at = inst
            .order
            .iter()
            .position(|k| k == key)
            .expect("restamped entry is in the order");
        let anchor_widget = inst.order[at + 1..].iter().find_map(|next| {
            self.stamps
                .get(&(id, path.clone(), next.clone()))
                .and_then(|s| s.roots.first().copied())
        });
        let Some(anchor_widget) = anchor_widget else {
            return; // last stamped entry: the append already placed it
        };
        let Some(stamp) = self.stamps.get(&(id, path.clone(), key.clone())) else {
            return;
        };
        for child in stamp.roots.clone() {
            out.push(ApplyOp::MoveChild {
                parent: container,
                child,
                before: Some(anchor_widget),
            });
        }
    }

    /// One field's delta: only bindings on that field re-resolve — the
    /// O(change) doctrine applied within an entry. `variant` is the
    /// discriminant the guest witnessed in the match that produced this
    /// write; a mismatch with the stored one means the binding's model
    /// has drifted from the core, and dies here rather than writing a
    /// type-correct field of the wrong constructor.
    fn update_field_entry(
        &mut self,
        id: CollectionId,
        path: Vec<Value>,
        key: Value,
        variant: u32,
        field: u32,
        value: Value,
        out: &mut Vec<ApplyOp>,
    ) {
        let schema = self.variant_schema(id, variant, "update_field");
        assert!(
            (field as usize) < schema.len(),
            "kaya: field {field} out of bounds for variant {variant} of {id:?} ({} fields)",
            schema.len()
        );
        assert!(
            value.type_of() == schema[field as usize],
            "kaya: field {field} of variant {variant} of {id:?} is {:?}, cannot hold {value:?}",
            schema[field as usize]
        );
        let path: PathKey = path.iter().map(Key::from_value).collect();
        let key = Key::from_value(&key);
        let inst = self.instance_mut(id, &path);
        let (stored, current) = inst
            .entries
            .get_mut(&key)
            .unwrap_or_else(|| panic!("kaya: update of missing key {key:?} in {id:?}"));
        assert!(
            *stored == variant,
            "kaya: update_field witnessed variant {variant} but {key:?} in {id:?} holds \
             variant {stored} (update, not update_field, changes a constructor)"
        );
        current[field as usize] = value.clone();
        if let Some(bound) = self.element_bindings.get(&(id, path, key)) {
            for (widget, prop, bound_field) in bound {
                if *bound_field == field {
                    out.push(ApplyOp::SetProp {
                        id: *widget,
                        prop: *prop,
                        value: value.clone(),
                    });
                }
            }
        }
    }

    fn remove_entry(
        &mut self,
        id: CollectionId,
        path: Vec<Value>,
        key: Value,
        out: &mut Vec<ApplyOp>,
    ) {
        let path: PathKey = path.iter().map(Key::from_value).collect();
        let key = Key::from_value(&key);
        let inst = self.instance_mut(id, &path);
        assert!(
            inst.entries.remove(&key).is_some(),
            "kaya: remove of missing key {key:?} in {id:?}"
        );
        inst.order.retain(|k| k != &key);
        if let Some(stamp) = self.stamps.remove(&(id, path, key)) {
            self.teardown(stamp, out);
        }
    }

    /// Reposition an entry in the ordered table, and its stamped copy
    /// among the For container's children. Order is collection data:
    /// the instance stays fully reproducible from template + table.
    fn move_entry(
        &mut self,
        id: CollectionId,
        path: Vec<Value>,
        key: Value,
        before: Option<Value>,
        out: &mut Vec<ApplyOp>,
    ) {
        let path: PathKey = path.iter().map(Key::from_value).collect();
        let key = Key::from_value(&key);
        let before = before.as_ref().map(Key::from_value);
        let inst = self.instance_mut(id, &path);
        assert!(
            inst.entries.contains_key(&key),
            "kaya: move of missing key {key:?} in {id:?}"
        );
        if let Some(anchor) = &before {
            assert!(
                inst.entries.contains_key(anchor),
                "kaya: move before missing key {anchor:?} in {id:?}"
            );
            if anchor == &key {
                return; // moving before itself: order unchanged
            }
        }
        inst.order.retain(|k| k != &key);
        match &before {
            Some(anchor) => {
                let at = inst
                    .order
                    .iter()
                    .position(|k| k == anchor)
                    .expect("anchor presence asserted above");
                inst.order.insert(at, key.clone());
            }
            None => inst.order.push(key.clone()),
        }
        // Reposition the stamped copy, if this instance is rendered.
        let Some(site) = self.for_sites.get(&(id, path.clone())) else {
            return;
        };
        let container = site.container;
        let Some(stamp) = self.stamps.get(&(id, path.clone(), key.clone())) else {
            return;
        };
        let roots = stamp.roots.clone();
        // The visual anchor is the first root of the anchor entry's
        // copy; None appends. Multi-root bodies keep their internal
        // order because each root lands before the same anchor.
        let anchor_widget = before.as_ref().and_then(|anchor| {
            self.stamps
                .get(&(id, path.clone(), anchor.clone()))
                .and_then(|s| s.roots.first().copied())
        });
        for child in roots {
            out.push(ApplyOp::MoveChild {
                parent: container,
                child,
                before: anchor_widget,
            });
        }
    }

    // --- Stamping -----------------------------------------------------------

    /// Stamp one copy for an entry, if its collection is being rendered.
    fn stamp_entry(
        &mut self,
        id: CollectionId,
        path: &PathKey,
        key: &Key,
        out: &mut Vec<ApplyOp>,
    ) {
        let Some(site) = self.for_sites.get(&(id, path.clone())) else {
            return; // data without a For yet; stamped when one binds
        };
        let container = site.container;
        // The eliminator applied: the entry's discriminant picks its
        // case blueprint. Totality was checked at declaration, so the
        // index is always in bounds.
        let variant = self.coll_instances[&(id, path.clone())].entries[key].0;
        let site = &self.for_sites[&(id, path.clone())];
        let body = site.bodies[variant as usize].clone();
        let mut chain = site.chain.clone();
        chain.push((id, path.clone(), key.clone()));
        let mut copy_path = path.clone();
        copy_path.push(key.clone());

        let mut stamp = Stamp::default();
        let mut node_map: HashMap<u64, WidgetId> = HashMap::new();
        self.run_body(&body, &copy_path, &chain, &mut node_map, &mut stamp, out);
        for root in &body.roots {
            out.push(ApplyOp::AddChild {
                parent: container,
                child: node_map[root],
            });
            stamp.roots.push(node_map[root]);
        }
        stamp.nodes = node_map;
        self.stamps.insert((id, path.clone(), key.clone()), stamp);
    }

    /// Execute a template body: create internal widgets, resolve and
    /// register bindings, birth nested collection instances and sites.
    fn run_body(
        &mut self,
        body: &TplBody,
        copy_path: &PathKey,
        chain: &[EntryRef],
        node_map: &mut HashMap<u64, WidgetId>,
        stamp: &mut Stamp,
        out: &mut Vec<ApplyOp>,
    ) {
        for op in &body.ops {
            match op {
                TplOp::Widget { node, kind } => {
                    let id = self.alloc_internal();
                    node_map.insert(*node, id);
                    stamp.widgets.push(id);
                    // The same predicate the live create reads. These two
                    // sites are the pair that had drifted.
                    let tag = kind
                        .carries_tag()
                        .then(|| Self::button_tag(*node, copy_path))
                        .flatten();
                    out.push(ApplyOp::Create {
                        id,
                        kind: *kind,
                        tag,
                    });
                }
                TplOp::SetProp { node, prop, value } => {
                    let id = node_map[node];
                    match value {
                        PropValue::Const(v) => out.push(ApplyOp::SetProp {
                            id,
                            prop: *prop,
                            value: v.clone(),
                        }),
                        PropValue::Signal(sig) => {
                            let current = self.signals[sig].clone();
                            self.bindings.entry(*sig).or_default().push((id, *prop));
                            stamp.signal_binds.push((*sig, id));
                            out.push(ApplyOp::SetProp {
                                id,
                                prop: *prop,
                                value: current,
                            });
                        }
                        PropValue::Element { level, field } => {
                            let entry = chain[chain.len() - 1 - *level as usize].clone();
                            let current = self.coll_instances[&(entry.0, entry.1.clone())]
                                .entries[&entry.2]
                                .1[*field as usize]
                                .clone();
                            self.element_bindings
                                .entry(entry.clone())
                                .or_default()
                                .push((id, *prop, *field));
                            stamp.element_binds.push((entry, id));
                            out.push(ApplyOp::SetProp {
                                id,
                                prop: *prop,
                                value: current,
                            });
                        }
                    }
                }
                TplOp::AddChild { parent, child } => out.push(ApplyOp::AddChild {
                    parent: node_map[parent],
                    child: node_map[child],
                }),
                TplOp::Collection { id } => {
                    self.coll_instances
                        .insert((*id, copy_path.clone()), CollInstance::default());
                    stamp.colls.push((*id, copy_path.clone()));
                }
                TplOp::For {
                    node,
                    collection,
                    bodies,
                } => {
                    let container = self.alloc_internal();
                    node_map.insert(*node, container);
                    stamp.widgets.push(container);
                    out.push(ApplyOp::Create {
                        id: container,
                        kind: WidgetKind::Column,
                        tag: None,
                    });
                    stamp.for_sites.push((*collection, copy_path.clone()));
                    self.register_for_site(
                        *collection,
                        copy_path.clone(),
                        container,
                        bodies.clone(),
                        chain.to_vec(),
                        out,
                    );
                }
                TplOp::When { node, signal, body } => {
                    let container = self.alloc_internal();
                    node_map.insert(*node, container);
                    stamp.widgets.push(container);
                    out.push(ApplyOp::Create {
                        id: container,
                        kind: WidgetKind::Column,
                        tag: None,
                    });
                    let site = self.register_when_site(
                        *signal,
                        container,
                        body.clone(),
                        copy_path.clone(),
                        chain.to_vec(),
                        out,
                    );
                    stamp.when_sites.push(site);
                }
                TplOp::ContextAttachNode { node, item } => {
                    // The menu tree is shared (live); each stamp attaches
                    // it to this copy's widget carrying the copy's key
                    // path — the noun every activation stamps into its
                    // occurrence (the on_click_node encoding).
                    let widget = node_map[node];
                    out.push(ApplyOp::ContextAttachNode {
                        widget,
                        item: *item,
                        path: path_values(copy_path),
                    });
                }
            }
        }
    }

    fn toggle_whens(&mut self, signal: SignalId, on: bool, out: &mut Vec<ApplyOp>) {
        // Toggling one site can tear down nested sites of the same
        // signal; snapshot the list and skip the already-gone.
        let sites = self.when_by_signal.get(&signal).cloned().unwrap_or_default();
        for site in sites {
            if self.when_sites.contains_key(&site) {
                self.toggle_when_site(site, on, out);
            }
        }
    }

    fn toggle_when_site(&mut self, site: u64, on: bool, out: &mut Vec<ApplyOp>) {
        let s = self.when_sites.get_mut(&site).unwrap();
        if on && s.stamp.is_none() {
            let container = s.container;
            let body = s.body.clone();
            let path = s.path.clone();
            let chain = s.chain.clone();
            let mut stamp = Stamp::default();
            let mut node_map = HashMap::new();
            self.run_body(&body, &path, &chain, &mut node_map, &mut stamp, out);
            for root in &body.roots {
                out.push(ApplyOp::AddChild {
                    parent: container,
                    child: node_map[root],
                });
            }
            stamp.nodes = node_map;
            self.when_sites.get_mut(&site).unwrap().stamp = Some(stamp);
        } else if !on {
            if let Some(stamp) = s.stamp.take() {
                self.teardown(stamp, out);
            }
        }
    }

    /// Undo one stamp exactly: nested sites and instances first (their
    /// bookkeeping and their own stamps), then this copy's bindings,
    /// then Destroys in reverse creation order — children before
    /// parents, so backends never walk anything.
    fn teardown(&mut self, stamp: Stamp, out: &mut Vec<ApplyOp>) {
        for site_id in &stamp.when_sites {
            if let Some(mut site) = self.when_sites.remove(site_id) {
                if let Some(bysig) = self.when_by_signal.get_mut(&site.signal) {
                    bysig.retain(|s| s != site_id);
                }
                if let Some(inner) = site.stamp.take() {
                    self.teardown(inner, out);
                }
            }
        }
        for (cid, path) in &stamp.colls {
            self.for_sites.remove(&(*cid, path.clone()));
            if let Some(inst) = self.coll_instances.remove(&(*cid, path.clone())) {
                for key in inst.order {
                    if let Some(inner) = self.stamps.remove(&(*cid, path.clone(), key)) {
                        self.teardown(inner, out);
                    }
                }
            }
        }
        for (sig, widget) in &stamp.signal_binds {
            if let Some(bound) = self.bindings.get_mut(sig) {
                bound.retain(|(w, _)| w != widget);
            }
        }
        for (entry, widget) in &stamp.element_binds {
            if let Some(bound) = self.element_bindings.get_mut(entry) {
                bound.retain(|(w, _, _)| w != widget);
            }
        }
        // THE COPY TAKES ITS TYPING HISTORY WITH IT. An episode on a
        // field that no longer exists is a step that would visibly do
        // nothing — the user presses Cmd+Z and the screen does not move
        // — which is the exact shape this milestone exists to remove
        // (`note_text_changed`'s no-change rule, one level up). The row's
        // own removal is a step in its own right and still walks back;
        // what it brings back is a fresh copy, because an uncontrolled
        // field's text is widget-owned state and undo restores app state
        // (D4). An app that wants a row's text to survive its removal
        // binds it to a record field, and the entries run carries it.
        for ledger in self.ledgers.values_mut() {
            let spent = |entry: &LedgerEntry| match entry {
                LedgerEntry::Episode(ep) => stamp.widgets.contains(&ep.field),
                LedgerEntry::Group { .. } => false,
            };
            ledger.done.retain(|entry| !spent(entry));
            ledger.redo.retain(|entry| !spent(entry));
        }
        for id in stamp.widgets.iter().rev() {
            out.push(ApplyOp::Destroy { id: *id });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::DEFAULT_WINDOW;

    fn v(s: &str) -> Value {
        Value::from(s)
    }

    /// The milestone-2 scene: a column holding a When (extras banner)
    /// and a For over groups, each group holding a label bound to its
    /// element and a nested For over items, each item a label and a
    /// remove button.
    ///
    /// ids: signals 1; widgets 1 column, 2 when, 3 for-groups;
    /// collections 1 groups, 2 items (in group template); template
    /// nodes 10 banner label, 20 group column, 21 group label,
    /// 22 items-for, 30 item label, 31 item button.
    fn milestone2_scene() -> Transaction {
        vec![
            TxOp::CreateSignal {
                id: SignalId(1),
                initial: Value::Bool(false),
            },
            TxOp::CreateWidget {
                id: WidgetId(1),
                kind: WidgetKind::Column,
            },
            TxOp::CreateWhen { id: 2, signal: SignalId(1) },
            TxOp::CreateWidget {
                id: WidgetId(10),
                kind: WidgetKind::Label,
            },
            TxOp::SetProperty {
                widget: WidgetId(10),
                prop: Prop::Text,
                value: PropValue::Const(v("extras")),
            },
            TxOp::TemplateEnd,
            TxOp::CreateCollection { id: CollectionId(1), variants: vec![vec![ValueType::Str]] },
            TxOp::CreateFor {
                id: 3,
                collection: CollectionId(1),
            },
            TxOp::CreateWidget {
                id: WidgetId(20),
                kind: WidgetKind::Column,
            },
            TxOp::CreateWidget {
                id: WidgetId(21),
                kind: WidgetKind::Label,
            },
            TxOp::SetProperty {
                widget: WidgetId(21),
                prop: Prop::Text,
                value: PropValue::Element { level: 0, field: 0 },
            },
            TxOp::AddChild {
                parent: WidgetId(20),
                child: WidgetId(21),
            },
            TxOp::CreateCollection { id: CollectionId(2), variants: vec![vec![ValueType::Str]] },
            TxOp::CreateFor {
                id: 22,
                collection: CollectionId(2),
            },
            TxOp::CreateWidget {
                id: WidgetId(30),
                kind: WidgetKind::Label,
            },
            TxOp::SetProperty {
                widget: WidgetId(30),
                prop: Prop::Text,
                value: PropValue::Element { level: 0, field: 0 },
            },
            TxOp::CreateWidget {
                id: WidgetId(31),
                kind: WidgetKind::Button,
            },
            TxOp::SetProperty {
                widget: WidgetId(31),
                prop: Prop::Text,
                value: PropValue::Const(v("remove")),
            },
            TxOp::TemplateEnd,
            TxOp::AddChild {
                parent: WidgetId(20),
                child: WidgetId(22),
            },
            TxOp::TemplateEnd,
            TxOp::AddChild {
                parent: WidgetId(1),
                child: WidgetId(2),
            },
            TxOp::AddChild {
                parent: WidgetId(1),
                child: WidgetId(3),
            },
            TxOp::Mount {
                window: DEFAULT_WINDOW,
                root: WidgetId(1),
            },
        ]
    }

    // --- The mounted-root reachability wall ------------------------------
    //
    // The two negatives below RE-CREATE THE SHIPPED DEFECT rather than a
    // synthetic one. `milestone2_scene()` above is byte-for-byte the shape
    // guests/swift/milestone2.swift had before aadbe9e: a column, a When
    // container and a For container, with the two AddChild ops that claim
    // them. Delete the first and you have the Swift result builder
    // discarding `banner`; delete the second and you have menus.swift's
    // `itemList`, built outside its column and only mentioned inside it.
    // Both shipped in the same commit and both rendered nothing while
    // every leg stayed green.
    //
    // Each negative asserts the PERTURBATION COUNT. A `should_panic` test
    // whose edit silently matched nothing passes for the wrong reason, and
    // this repo has been bitten by exactly that twice (check-tx-liveness's
    // three vacuous clauses, the wayland seat guard's two vacuous runs).
    // An unchanged fixture fails here as loudly as a missing wall.

    /// Remove every `AddChild` that claims `child`, returning how many
    /// went. Printed, and every caller asserts on it.
    fn strip_add_child(tx: &mut Transaction, child: WidgetId) -> usize {
        let before = tx.len();
        tx.retain(|op| !matches!(op, TxOp::AddChild { child: c, .. } if *c == child));
        let n = before - tx.len();
        println!("strip_add_child({child:?}): {n} op(s) removed");
        n
    }

    /// E2, the one that shipped: the `When` container is created at
    /// ambient parent 0 (app.rs:1239 emits no AddChild there), the column
    /// never claims it, and it renders nowhere while answering every read.
    #[test]
    #[should_panic(expected = "not reachable from any mounted root")]
    fn a_when_container_never_parented_fails_the_batch() {
        let mut tx = milestone2_scene();
        let n = strip_add_child(&mut tx, WidgetId(2));
        assert_eq!(n, 1, "the perturbation did not apply — the fixture moved");
        Scene::new().apply(tx);
    }

    /// E3, its sibling in the same commit: a `For` container built outside
    /// the column that was supposed to hold it.
    #[test]
    #[should_panic(expected = "not reachable from any mounted root")]
    fn a_for_container_built_outside_its_column_fails_the_batch() {
        let mut tx = milestone2_scene();
        let n = strip_add_child(&mut tx, WidgetId(3));
        assert_eq!(n, 1, "the perturbation did not apply — the fixture moved");
        Scene::new().apply(tx);
    }

    /// The unperturbed fixture passes. Without this, the two negatives
    /// above would also be satisfied by a wall that refused everything.
    #[test]
    fn the_unperturbed_milestone2_scene_is_reachable() {
        Scene::new().apply(milestone2_scene());
    }

    /// A whole detached subtree is caught, and it is named at the widget
    /// the author wrote FIRST — the container — rather than at whichever
    /// leaf a hash map happened to yield. `created` is in creation order
    /// for exactly this reason.
    #[test]
    #[should_panic(expected = "widget WidgetId(2)")]
    fn a_detached_subtree_is_named_at_its_container() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Column },
            TxOp::Mount { window: DEFAULT_WINDOW, root: WidgetId(1) },
            TxOp::CreateWidget { id: WidgetId(2), kind: WidgetKind::Column },
            TxOp::CreateWidget { id: WidgetId(3), kind: WidgetKind::Label },
            // 3 has a parent; 2 does not. Neither is on screen.
            TxOp::AddChild { parent: WidgetId(2), child: WidgetId(3) },
        ]);
    }

    /// The scene that creates widgets and never mounts at all. The
    /// SwiftUI interpreter carries a diagnosis for exactly this
    /// (KayaSwiftUI.swift's UNMOUNTED-SCENE DIAGNOSIS, and the comment
    /// there records the afternoon it cost) — but that one runs only on
    /// the failure path, so a scene whose legs all pass never reaches it.
    /// This fires first, in the core, for every backend.
    #[test]
    #[should_panic(expected = "missing its mount(root)")]
    fn a_scene_that_never_mounts_is_refused() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Column },
            TxOp::CreateWidget { id: WidgetId(2), kind: WidgetKind::Button },
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(2) },
        ]);
    }

    // --- The positives: the wall must not fire on legitimate code --------

    /// guests/c/a11y.c's shape, which is the decisive one: ONE
    /// transaction, every widget created first, then the add_child calls
    /// in a block, then the mount. Every widget in that file is an orphan
    /// for most of the transaction's length, so a per-op check would fail
    /// the whole C floor. This is why the wall is a BARRIER.
    #[test]
    fn create_then_parent_later_in_the_same_batch_is_fine() {
        let mut scene = Scene::new();
        let mut tx = vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Column },
            TxOp::CreateWidget { id: WidgetId(2), kind: WidgetKind::Row },
            TxOp::CreateWidget { id: WidgetId(3), kind: WidgetKind::Label },
            TxOp::CreateWidget { id: WidgetId(4), kind: WidgetKind::Button },
        ];
        tx.extend([
            TxOp::AddChild { parent: WidgetId(2), child: WidgetId(3) },
            TxOp::AddChild { parent: WidgetId(2), child: WidgetId(4) },
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(2) },
        ]);
        tx.push(TxOp::Mount { window: DEFAULT_WINDOW, root: WidgetId(1) });
        scene.apply(tx);
    }

    /// guests/rust/nav.rs:51-58's shape: a pane built INSIDE A CLICK
    /// HANDLER — push the entry, create the widgets, parent them, mount
    /// into the entry — all in one handler transaction, long after the
    /// app's first batch.
    #[test]
    fn a_pane_built_and_mounted_in_a_handler_is_fine() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Column },
            TxOp::Mount { window: DEFAULT_WINDOW, root: WidgetId(1) },
        ]);
        // The handler's own transaction.
        scene.apply(vec![
            TxOp::PushEntry { window: DEFAULT_WINDOW, entry: WindowId(7) },
            TxOp::CreateWidget { id: WidgetId(2), kind: WidgetKind::Column },
            TxOp::CreateWidget { id: WidgetId(3), kind: WidgetKind::Label },
            TxOp::AddChild { parent: WidgetId(2), child: WidgetId(3) },
            TxOp::Mount { window: WindowId(7), root: WidgetId(2) },
        ]);
    }

    /// A widget parented into a tree that is mounted in a LATER op of the
    /// same batch. Ordering inside a transaction is free; only the
    /// finished state is judged.
    #[test]
    fn parenting_before_the_mount_op_is_fine() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Column },
            TxOp::CreateWidget { id: WidgetId(2), kind: WidgetKind::Label },
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(2) },
            TxOp::Mount { window: DEFAULT_WINDOW, root: WidgetId(1) },
        ]);
    }

    /// The batch scope, and why it is not a nicety: the core NEVER prunes
    /// `self.widgets` (DestroyWindow at :1401 and PopEntry at :1584 drop
    /// the surface and leave the widget ids behind forever), so a global
    /// sweep would re-accuse a destroyed window's widgets on every later
    /// transaction and redden three scenes in the matrix today —
    /// guests/rust/dirty.rs, guests/rust/panels.rs, guests/rust/nav.rs.
    #[test]
    fn a_destroyed_windows_widgets_are_not_re_accused() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Column },
            TxOp::Mount { window: DEFAULT_WINDOW, root: WidgetId(1) },
            TxOp::CreateWindow { window: WindowId(2) },
            TxOp::CreateWidget { id: WidgetId(5), kind: WidgetKind::Column },
            TxOp::Mount { window: WindowId(2), root: WidgetId(5) },
        ]);
        scene.apply(vec![TxOp::DestroyWindow { window: WindowId(2) }]);
        // Widget 5 is still in `self.widgets` and is now unreachable —
        // and this batch is judged on ITS creations, not on the leak.
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(6), kind: WidgetKind::Label },
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(6) },
        ]);
    }

    /// The other half of that, and the one that makes the six
    /// `mounted_windows.remove` sites load-bearing: parenting a NEW widget
    /// into a destroyed window's tree is refused. Without the removal the
    /// dead root would still count as mounted and this would pass.
    ///
    /// It is also the case that exercises the WALK: widget 6's immediate
    /// parent exists and is perfectly real, so only following the chain to
    /// its top finds the problem — which is what the expected substring
    /// pins.
    #[test]
    #[should_panic(expected = "no live surface has that widget as its root")]
    fn a_widget_added_to_a_destroyed_windows_tree_is_refused() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWindow { window: WindowId(2) },
            TxOp::CreateWidget { id: WidgetId(5), kind: WidgetKind::Column },
            TxOp::Mount { window: WindowId(2), root: WidgetId(5) },
        ]);
        scene.apply(vec![TxOp::DestroyWindow { window: WindowId(2) }]);
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(6), kind: WidgetKind::Label },
            TxOp::AddChild { parent: WidgetId(5), child: WidgetId(6) },
        ]);
    }

    /// Same, for a popped navigation entry.
    #[test]
    #[should_panic(expected = "not reachable from any mounted root")]
    fn a_widget_added_to_a_popped_entrys_tree_is_refused() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::PushEntry { window: DEFAULT_WINDOW, entry: WindowId(7) },
            TxOp::CreateWidget { id: WidgetId(2), kind: WidgetKind::Column },
            TxOp::Mount { window: WindowId(7), root: WidgetId(2) },
        ]);
        scene.apply(vec![TxOp::PopEntry { window: DEFAULT_WINDOW }]);
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(3), kind: WidgetKind::Label },
            TxOp::AddChild { parent: WidgetId(2), child: WidgetId(3) },
        ]);
    }

    /// Stamped copies are out of scope BY CONSTRUCTION, not by an
    /// exemption: `run_body` mints them with `alloc_internal()` and never
    /// puts them in `self.widgets`, so they are never in `created`. The
    /// inserts here stamp three group copies with nested item copies; a
    /// wall that swept the whole widget map would drown in them.
    #[test]
    fn stamped_copies_are_not_live_widgets() {
        let mut scene = Scene::new();
        scene.apply(milestone2_scene());
        scene.apply(vec![
            insert(1, vec![], "g1", "Groceries"),
            insert(1, vec![], "g2", "Chores"),
        ]);
        scene.apply(vec![insert(2, vec![v("g1")], "i1", "milk")]);
    }

    // --- Termination: the walk cannot be made to spin ---------------------

    #[test]
    #[should_panic(expected = "to itself")]
    fn add_child_refuses_a_self_parent() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Column },
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(1) },
        ]);
    }

    #[test]
    #[should_panic(expected = "would create a cycle")]
    fn add_child_refuses_a_cycle() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Column },
            TxOp::CreateWidget { id: WidgetId(2), kind: WidgetKind::Column },
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(2) },
            TxOp::AddChild { parent: WidgetId(2), child: WidgetId(1) },
        ]);
    }

    fn insert(id: u64, path: Vec<Value>, key: &str, value: &str) -> TxOp {
        TxOp::CollectionInsert {
            id: CollectionId(id),
            path,
            key: v(key),
            variant: 0,
            record: vec![v(value)],
        }
    }

    fn creates(ops: &[ApplyOp]) -> Vec<(WidgetKind, bool)> {
        ops.iter()
            .filter_map(|op| match op {
                ApplyOp::Create { kind, tag, .. } => Some((*kind, tag.is_some())),
                _ => None,
            })
            .collect()
    }

    fn destroys(ops: &[ApplyOp]) -> usize {
        ops.iter()
            .filter(|op| matches!(op, ApplyOp::Destroy { .. }))
            .count()
    }

    #[test]
    fn declaration_renders_nothing() {
        let mut scene = Scene::new();
        let ops = scene.apply(milestone2_scene());
        // Only the live zone appears: the column, the When container,
        // the For container. No template node hits the backend.
        assert_eq!(
            creates(&ops),
            vec![
                (WidgetKind::Column, false),
                (WidgetKind::Column, false),
                (WidgetKind::Column, false),
            ]
        );
    }

    #[test]
    fn insert_stamps_a_copy() {
        let mut scene = Scene::new();
        scene.apply(milestone2_scene());
        let ops = scene.apply(vec![insert(1, vec![], "g1", "Work")]);
        // One group copy: its column, its element-bound label (valued at
        // stamp time), and the inner For's container.
        assert_eq!(
            creates(&ops),
            vec![
                (WidgetKind::Column, false),
                (WidgetKind::Label, false),
                (WidgetKind::Column, false),
            ]
        );
        assert!(ops.iter().any(|op| matches!(
            op,
            ApplyOp::SetProp { value, .. } if *value == v("Work")
        )));
    }

    /// A STAMPED COPY IS TAGGED EXACTLY WHERE A LIVE WIDGET IS, and the
    /// two `button_tag` callsites are twelve hundred lines apart. They
    /// were the same fact written twice and had already drifted:
    /// Textarea, Select and Radio were tagged live and untagged when
    /// stamped, which is the one shape that reaches a backend as a
    /// choice between a panic and a silence. GTK and WinUI unwrap the
    /// tag for exactly those three (`tag.expect("selects carry a tag")`,
    /// gtk.rs:3897 and winui/mod.rs:6008), so a stamped select aborted
    /// the process there; the SwiftUI interpreter reads a zero-length
    /// tag without complaint, so on mac and iOS the control appeared and
    /// never reported. Nothing could see it, because no BINDING had a
    /// template constructor for those kinds — only the raw floor did
    /// (docs/sugar-pass-plan.md D1).
    ///
    /// EXHAUSTIVE OVER THE KIND ENUM, deliberately: it compares the two
    /// paths for every variant rather than checking a list, so a kind
    /// added later cannot diverge without this failing. `carries_tag` is
    /// what makes them one fact; this is what proves it stayed one.
    #[test]
    fn a_stamped_copy_is_tagged_exactly_where_a_live_one_is() {
        for kind in WidgetKind::ALL {
            // The live half: create one, read its Create op's tag.
            let mut scene = Scene::new();
            let live = scene.apply(vec![
                TxOp::CreateWidget { id: WidgetId(1), kind },
                TxOp::Mount { window: DEFAULT_WINDOW, root: WidgetId(1) },
            ]);
            let live_tagged = creates(&live)
                .into_iter()
                .find(|(k, _)| *k == kind)
                .map(|(_, tagged)| tagged)
                .unwrap_or_else(|| panic!("kaya: no live Create for {kind:?}"));

            // The stamped half: the same kind as a template node, one
            // row inserted, read the stamped copy's Create op.
            let mut scene = Scene::new();
            scene.apply(vec![
                TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Column },
                TxOp::CreateCollection {
                    id: CollectionId(1),
                    variants: vec![vec![ValueType::Str]],
                },
                TxOp::CreateFor { id: 2, collection: CollectionId(1) },
                TxOp::CreateWidget { id: WidgetId(10), kind },
                TxOp::TemplateEnd,
                TxOp::AddChild { parent: WidgetId(1), child: WidgetId(2) },
                TxOp::Mount { window: DEFAULT_WINDOW, root: WidgetId(1) },
            ]);
            let stamped = scene.apply(vec![insert(1, vec![], "k", "row")]);
            let stamped_tagged = creates(&stamped)
                .into_iter()
                .find(|(k, _)| *k == kind)
                .map(|(_, tagged)| tagged)
                .unwrap_or_else(|| panic!("kaya: no stamped Create for {kind:?}"));

            assert_eq!(
                live_tagged, stamped_tagged,
                "kaya: {kind:?} is tagged {live_tagged} live and {stamped_tagged} \
                 when stamped — the two button_tag callsites disagree, so a \
                 stamped {kind:?} either aborts a backend that unwraps the tag \
                 or reports to nobody. Both sites read carries_tag()."
            );
        }
    }

    /// A template scroll takes exactly one child, like a live one.
    ///
    /// This rule and the choice rule below lived on the live `AddChild`
    /// arm only. Recording a template ran neither, so a two-child
    /// scroll prototype recorded clean and reached the backends as a
    /// shape none of them reads. Unreachable through sugar until the
    /// template zone gained a `scroll` constructor, which is precisely
    /// when a rule enforced on one path and not the other stops being
    /// theoretical (docs/sugar-pass-plan.md).
    #[test]
    #[should_panic(expected = "already holds its one child")]
    fn a_template_scroll_refuses_a_second_child() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateCollection {
                id: CollectionId(1),
                variants: vec![vec![ValueType::Str]],
            },
            TxOp::CreateFor { id: 1, collection: CollectionId(1) },
            TxOp::CreateWidget { id: WidgetId(10), kind: WidgetKind::Scroll },
            TxOp::CreateWidget { id: WidgetId(11), kind: WidgetKind::Label },
            TxOp::CreateWidget { id: WidgetId(12), kind: WidgetKind::Label },
            TxOp::AddChild { parent: WidgetId(10), child: WidgetId(11) },
            TxOp::AddChild { parent: WidgetId(10), child: WidgetId(12) },
        ]);
    }

    /// A template choice's children are its options: labels only.
    #[test]
    #[should_panic(expected = "children are its options")]
    fn a_template_select_refuses_a_non_label_option() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateCollection {
                id: CollectionId(1),
                variants: vec![vec![ValueType::Str]],
            },
            TxOp::CreateFor { id: 1, collection: CollectionId(1) },
            TxOp::CreateWidget { id: WidgetId(10), kind: WidgetKind::Select },
            TxOp::CreateWidget { id: WidgetId(11), kind: WidgetKind::Button },
            TxOp::AddChild { parent: WidgetId(10), child: WidgetId(11) },
        ]);
    }

    /// AND THE POSITIVE HALF, so the two above are not passing because
    /// the arm refuses everything: the shapes the constructors actually
    /// emit must record without complaint.


    #[test]
    fn a_well_formed_template_scroll_and_choice_record() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Column },
            TxOp::CreateCollection {
                id: CollectionId(1),
                variants: vec![vec![ValueType::Str]],
            },
            TxOp::CreateFor { id: 2, collection: CollectionId(1) },
            TxOp::CreateWidget { id: WidgetId(10), kind: WidgetKind::Scroll },
            TxOp::CreateWidget { id: WidgetId(11), kind: WidgetKind::Column },
            TxOp::AddChild { parent: WidgetId(10), child: WidgetId(11) },
            TxOp::CreateWidget { id: WidgetId(12), kind: WidgetKind::Select },
            TxOp::CreateWidget { id: WidgetId(13), kind: WidgetKind::Label },
            TxOp::CreateWidget { id: WidgetId(14), kind: WidgetKind::Label },
            TxOp::AddChild { parent: WidgetId(12), child: WidgetId(13) },
            TxOp::AddChild { parent: WidgetId(12), child: WidgetId(14) },
            TxOp::TemplateEnd,
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(2) },
            TxOp::Mount { window: DEFAULT_WINDOW, root: WidgetId(1) },
        ]);
    }

    /// THE ROLE WALLS, both directions. The variant decides the kind:
    /// a destructive label and a heading button both die at declare
    /// time in the root's words, and the legal pairings record clean.
    #[test]
    #[should_panic(expected = "role destructive does not fit Label")]
    fn a_destructive_label_dies_at_declare() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Label },
            TxOp::SetProperty {
                widget: WidgetId(1),
                prop: Prop::Role,
                value: PropValue::Const(Value::I64(1)),
            },
        ]);
    }

    /// THE CONTAINER INSET'S TWO WALLS, spacing's exactly: a leaf has
    /// no children to hold off its edge, and negative padding has no
    /// reading for any backend to invent.
    #[test]
    #[should_panic(expected = "Label has no property Inset")]
    fn an_inset_label_dies_at_declare() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Label },
            TxOp::SetProperty {
                widget: WidgetId(1),
                prop: Prop::Inset,
                value: PropValue::Const(Value::F64(8.0)),
            },
        ]);
    }

    #[test]
    #[should_panic(expected = "container's inset must be finite and non-negative")]
    fn a_negative_container_inset_dies() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Row },
            TxOp::SetProperty {
                widget: WidgetId(1),
                prop: Prop::Inset,
                value: PropValue::Const(Value::F64(-1.0)),
            },
        ]);
    }

    #[test]
    #[should_panic(expected = "role heading does not fit Button")]
    fn a_heading_button_dies_at_declare() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Button },
            TxOp::SetProperty {
                widget: WidgetId(1),
                prop: Prop::Role,
                value: PropValue::Const(Value::I64(3)),
            },
        ]);
    }

    #[test]
    fn the_legal_role_pairings_record() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Column },
            TxOp::CreateWidget { id: WidgetId(2), kind: WidgetKind::Button },
            TxOp::SetProperty {
                widget: WidgetId(2),
                prop: Prop::Role,
                value: PropValue::Const(Value::I64(1)),
            },
            TxOp::CreateWidget { id: WidgetId(3), kind: WidgetKind::Button },
            TxOp::SetProperty {
                widget: WidgetId(3),
                prop: Prop::Role,
                value: PropValue::Const(Value::I64(2)),
            },
            TxOp::CreateWidget { id: WidgetId(4), kind: WidgetKind::Label },
            TxOp::SetProperty {
                widget: WidgetId(4),
                prop: Prop::Role,
                value: PropValue::Const(Value::I64(3)),
            },
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(2) },
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(3) },
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(4) },
            TxOp::Mount { window: DEFAULT_WINDOW, root: WidgetId(1) },
        ]);
    }

    /// THE BRAND'S SET-ONCE WALLS. A second write and a post-mount
    /// write both die in the root's words; the clean path emits ONE
    /// derived SetBrand carrying the seed.
    #[test]
    #[should_panic(expected = "set_brand_accent called twice")]
    fn a_second_brand_write_dies() {
        let mut scene = Scene::new();
        scene.apply(vec![TxOp::SetBrandAccent { seed: 0x3584E4, light: None, dark: None }]);
        scene.apply(vec![TxOp::SetBrandAccent { seed: 0xE62D42, light: None, dark: None }]);
    }

    #[test]
    #[should_panic(expected = "after a mount")]
    fn a_post_mount_brand_write_dies() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Column },
            TxOp::Mount { window: DEFAULT_WINDOW, root: WidgetId(1) },
        ]);
        scene.apply(vec![TxOp::SetBrandAccent { seed: 0x3584E4, light: None, dark: None }]);
    }

    /// AND THE DOMAIN WALL: the seed is 0xRRGGBB and nothing else. The
    /// fan-out measured an ARGB constant sailing through seven bindings
    /// and reaching every backend as seed AND fill (only Python's local
    /// precondition caught it); the refusal belongs here, where the
    /// answer is the same in all eight languages. All three words are
    /// walled — the overrides take the same grammar as the seed.
    #[test]
    #[should_panic(expected = "brand seed 0xff3584e4 is not a packed")]
    fn an_alpha_carrying_seed_dies() {
        let mut scene = Scene::new();
        scene.apply(vec![TxOp::SetBrandAccent { seed: 0xFF3584E4, light: None, dark: None }]);
    }

    #[test]
    #[should_panic(expected = "brand dark 0x1000000 is not a packed")]
    fn an_out_of_range_override_dies() {
        let mut scene = Scene::new();
        scene.apply(vec![TxOp::SetBrandAccent {
            seed: 0x3584E4,
            light: None,
            dark: Some(0x0100_0000),
        }]);
    }

    #[test]
    fn the_brand_derives_once_and_carries_the_seed() {
        let mut scene = Scene::new();
        let ops = scene.apply(vec![TxOp::SetBrandAccent {
            seed: 0x3584E4,
            light: None,
            dark: None,
        }]);
        let brands: Vec<_> = ops
            .iter()
            .filter_map(|op| match op {
                ApplyOp::SetBrand { accent } => Some(accent),
                _ => None,
            })
            .collect();
        assert_eq!(brands.len(), 1, "one derived SetBrand out");
        assert_eq!(brands[0].seed, 0x3584E4, "the seed rides along for Material");
        // Adwaita blue takes white — the derivation's empirical anchor.
        assert_eq!(brands[0].light.on_fill, 0xFFFFFF);
    }

    #[test]
    fn nested_insert_stamps_with_tagged_button() {
        let mut scene = Scene::new();
        scene.apply(milestone2_scene());
        scene.apply(vec![insert(1, vec![], "g1", "Work")]);
        let ops = scene.apply(vec![insert(2, vec![v("g1")], "a", "send report")]);
        assert_eq!(
            creates(&ops),
            vec![(WidgetKind::Label, false), (WidgetKind::Button, true)]
        );
        // The button's tag names (node 31, [g1, a]).
        let tag = ops
            .iter()
            .find_map(|op| match op {
                ApplyOp::Create { tag: Some(t), .. } => Some(t.clone()),
                _ => None,
            })
            .unwrap();
        assert_eq!(
            crate::wire::decode_click_tag(&tag),
            crate::protocol::Occurrence::InstanceButtonClicked {
                node: crate::protocol::TemplateNodeId(31),
                path: vec![v("g1"), v("a")],
            }
        );
    }

    #[test]
    fn update_feeds_element_bindings() {
        let mut scene = Scene::new();
        scene.apply(milestone2_scene());
        scene.apply(vec![insert(1, vec![], "g1", "Work")]);
        let ops = scene.apply(vec![TxOp::CollectionUpdate {
            id: CollectionId(1),
            path: vec![],
            key: v("g1"),
            variant: 0,
            record: vec![v("Home")],
        }]);
        assert_eq!(ops.len(), 1);
        assert!(
            matches!(&ops[0], ApplyOp::SetProp { value, .. } if *value == v("Home"))
        );
    }

    #[test]
    fn remove_tears_down_recursively() {
        let mut scene = Scene::new();
        scene.apply(milestone2_scene());
        scene.apply(vec![insert(1, vec![], "g1", "Work")]);
        scene.apply(vec![
            insert(2, vec![v("g1")], "a", "one"),
            insert(2, vec![v("g1")], "b", "two"),
        ]);
        let ops = scene.apply(vec![TxOp::CollectionRemove {
            id: CollectionId(1),
            path: vec![],
            key: v("g1"),
        }]);
        // Group copy: 3 widgets. Two items: 2 widgets each. All go.
        assert_eq!(destroys(&ops), 7);
        // And the nested instance is gone: reinserting g1 starts empty.
        let ops = scene.apply(vec![insert(1, vec![], "g1", "Work")]);
        assert_eq!(destroys(&ops), 0);
        assert_eq!(creates(&ops).len(), 3);
    }

    #[test]
    fn when_stamps_and_unstamps_on_signal() {
        let mut scene = Scene::new();
        scene.apply(milestone2_scene());
        let ops = scene.apply(vec![TxOp::WriteSignal {
            id: SignalId(1),
            value: Value::Bool(true),
        }]);
        assert_eq!(creates(&ops), vec![(WidgetKind::Label, false)]);
        let ops = scene.apply(vec![TxOp::WriteSignal {
            id: SignalId(1),
            value: Value::Bool(false),
        }]);
        assert_eq!(destroys(&ops), 1);
        // Toggling within one batch coalesces: net false, nothing out.
        let ops = scene.apply(vec![
            TxOp::WriteSignal {
                id: SignalId(1),
                value: Value::Bool(true),
            },
            TxOp::WriteSignal {
                id: SignalId(1),
                value: Value::Bool(false),
            },
        ]);
        assert_eq!(creates(&ops).len(), 0);
        assert_eq!(destroys(&ops), 0);
    }

    #[test]
    fn signal_bindings_inside_stamps_unregister_on_teardown() {
        let mut scene = Scene::new();
        // A For whose template binds a signal; removal must sever it.
        scene.apply(vec![
            TxOp::CreateSignal {
                id: SignalId(1),
                initial: v("tick"),
            },
            TxOp::CreateCollection { id: CollectionId(1), variants: vec![vec![ValueType::Str]] },
            TxOp::CreateFor {
                id: 1,
                collection: CollectionId(1),
            },
            TxOp::CreateWidget {
                id: WidgetId(10),
                kind: WidgetKind::Label,
            },
            TxOp::SetProperty {
                widget: WidgetId(10),
                prop: Prop::Text,
                value: PropValue::Signal(SignalId(1)),
            },
            TxOp::TemplateEnd,
            TxOp::Mount {
                window: DEFAULT_WINDOW,
                root: WidgetId(1),
            },
        ]);
        scene.apply(vec![insert(1, vec![], "a", "x")]);
        let ops = scene.apply(vec![TxOp::WriteSignal {
            id: SignalId(1),
            value: v("tock"),
        }]);
        assert_eq!(ops.len(), 1); // the stamped label follows the signal
        scene.apply(vec![TxOp::CollectionRemove {
            id: CollectionId(1),
            path: vec![],
            key: v("a"),
        }]);
        let ops = scene.apply(vec![TxOp::WriteSignal {
            id: SignalId(1),
            value: v("tick"),
        }]);
        assert_eq!(ops.len(), 0); // no dangling binding
    }

    /// The sections grammar end to end at the core: add (first added
    /// becomes selected), select validates membership, mount and
    /// push_entry both accept a section as their surface, and the
    /// selection mirror reconciles user switches.
    #[test]
    fn sections_are_surfaces() {
        let mut scene = Scene::new();
        let ops = scene.apply(vec![
            TxOp::AddSection { window: DEFAULT_WINDOW, section: WindowId(7) },
            TxOp::AddSection { window: DEFAULT_WINDOW, section: WindowId(8) },
            TxOp::SetSectionProp {
                section: WindowId(7),
                prop: SectionProp::Title,
                value: PropValue::Const(Value::from("Feed")),
            },
            TxOp::SelectSection { window: DEFAULT_WINDOW, section: WindowId(8) },
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Column },
            // Sections are mount targets...
            TxOp::Mount { window: WindowId(7), root: WidgetId(1) },
            // ...and stack hosts (per-surface stacks): push INTO one.
            TxOp::PushEntry { window: WindowId(7), entry: WindowId(9) },
        ]);
        assert!(ops.iter().any(|op| matches!(
            op,
            ApplyOp::AddSection { window, section }
                if *window == DEFAULT_WINDOW && section.0 == 7
        )));
        assert!(ops.iter().any(|op| matches!(
            op,
            ApplyOp::SelectSection { section, .. } if section.0 == 8
        )));
        assert_eq!(scene.selected_section[&DEFAULT_WINDOW].0, 8);
        // The user switches back: the mirror reconciles.
        scene.user_selected_section(DEFAULT_WINDOW, WindowId(7));
        assert_eq!(scene.selected_section[&DEFAULT_WINDOW].0, 7);
    }

    #[test]
    #[should_panic(expected = "not a section of")]
    fn selecting_an_unadded_section_fails_loudly() {
        let mut scene = Scene::new();
        scene.apply(vec![TxOp::SelectSection {
            window: DEFAULT_WINDOW,
            section: WindowId(7),
        }]);
    }

    #[test]
    #[should_panic(expected = "already exists")]
    fn section_ids_share_the_surface_namespace() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::PushEntry { window: DEFAULT_WINDOW, entry: WindowId(7) },
            TxOp::AddSection { window: DEFAULT_WINDOW, section: WindowId(7) },
        ]);
    }

    /// The custom-id grammar (DESIGN.md, Clipboard): mime-shaped — a
    /// slash, lowercase, no whitespace. The slash is GDK's measured
    /// charge: its serving path interns the requested type as a mime
    /// type, so a slashless id is ADVERTISED AND NEVER SERVED on GTK,
    /// with no error anywhere; the same path lowercases, so a
    /// mixed-case id would surface differently there than everywhere
    /// else (docs/clipboard-plan.md §5b finding 4). Checked at apply —
    /// the one gate every binding passes — so a bad id fails HERE,
    /// naming the rule, on every platform alike.
    fn copy_of_custom(id: &str) -> TxOp {
        TxOp::Copy(crate::protocol::Clip {
            custom: vec![(
                id.to_owned(),
                crate::protocol::Blob(std::sync::Arc::from(&b"note=1"[..])),
            )],
            ..Default::default()
        })
    }

    #[test]
    fn a_mime_shaped_custom_id_is_accepted() {
        let mut scene = Scene::new();
        scene.apply(vec![copy_of_custom("dev.kaya/note")]);
    }

    #[test]
    #[should_panic(expected = "has no slash")]
    fn a_slashless_custom_id_fails_at_apply() {
        let mut scene = Scene::new();
        scene.apply(vec![copy_of_custom("dev.kaya.note")]);
    }

    #[test]
    #[should_panic(expected = "not lowercase")]
    fn an_uppercase_custom_id_fails_at_apply() {
        let mut scene = Scene::new();
        scene.apply(vec![copy_of_custom("Dev.Kaya/Note")]);
    }

    #[test]
    #[should_panic(expected = "carries whitespace")]
    fn a_custom_id_with_a_space_fails_at_apply() {
        // Accept lists are space-separated, so an id with a space
        // could never be accepted by name — it would split in two.
        let mut scene = Scene::new();
        scene.apply(vec![copy_of_custom("dev.kaya/no te")]);
    }

    #[test]
    #[should_panic(expected = "has no slash")]
    fn an_accept_list_holds_custom_ids_to_the_same_grammar() {
        let mut scene = Scene::new();
        scene.apply(vec![TxOp::ReadClipboard {
            request: 1,
            accepting: "text dev.kaya.note".into(),
        }]);
    }

    #[test]
    #[should_panic(expected = "offers no representation")]
    fn an_empty_clip_fails_at_apply() {
        let mut scene = Scene::new();
        scene.apply(vec![TxOp::Copy(crate::protocol::Clip::default())]);
    }

    #[test]
    fn the_leading_pane_is_a_quarter_not_a_half() {
        use crate::protocol::leading_pane_width;
        // The whole point: never half. A 1000-wide window gives the
        // list 250 and the detail 750.
        assert_eq!(leading_pane_width(1000.0), 250.0);
        // Clamped at both ends, libadwaita's stated 180..280.
        assert_eq!(leading_pane_width(600.0), 180.0);
        assert_eq!(leading_pane_width(4000.0), 280.0);
        // And never wider than the window it sits in, however narrow —
        // a compact window never takes this arm, but the arithmetic
        // must not produce a pane wider than its parent regardless.
        assert_eq!(leading_pane_width(100.0), 100.0);
    }

    #[test]
    fn list_detail_takes_a_bool() {
        let mut scene = Scene::new();
        scene.apply(vec![TxOp::SetWindowProp {
            window: DEFAULT_WINDOW,
            prop: WindowProp::ListDetail,
            value: PropValue::Const(Value::Bool(true)),
        }]);
    }

    #[test]
    #[should_panic(expected = "rejects value")]
    fn list_detail_rejects_a_non_bool() {
        // The prop asks a yes/no question — "present this stack as
        // list-detail" — and WHICH way it presents is the size class's
        // answer, never a value the app supplies. An enum here would be
        // an app overriding the platform's own breakpoint.
        let mut scene = Scene::new();
        scene.apply(vec![TxOp::SetWindowProp {
            window: DEFAULT_WINDOW,
            prop: WindowProp::ListDetail,
            value: PropValue::Const(Value::from("regular")),
        }]);
    }

    #[test]
    fn dirty_takes_a_bool() {
        let mut scene = Scene::new();
        scene.apply(vec![TxOp::SetWindowProp {
            window: DEFAULT_WINDOW,
            prop: WindowProp::Dirty,
            value: PropValue::Const(Value::Bool(true)),
        }]);
    }

    #[test]
    #[should_panic(expected = "rejects value")]
    fn dirty_rejects_a_non_bool() {
        // The prop is a BOOLEAN, and a string here is exactly the
        // design it replaces: Qt spells unsaved work as a `[*]`
        // placeholder inside the app's own title, which puts the
        // mechanism in app-facing text and the constraint on a string
        // no type system sees (docs/dirty-plan.md D1). kaya's window
        // titles are compared byte-for-byte across platforms, so the
        // declared string stays identical everywhere and only the
        // chrome diverges.
        let mut scene = Scene::new();
        scene.apply(vec![TxOp::SetWindowProp {
            window: DEFAULT_WINDOW,
            prop: WindowProp::Dirty,
            value: PropValue::Const(Value::from("notes[*]")),
        }]);
    }

    #[test]
    #[should_panic(expected = "rejects value")]
    fn section_icon_rejects_non_blob() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::AddSection { window: DEFAULT_WINDOW, section: WindowId(7) },
            TxOp::SetSectionProp {
                section: WindowId(7),
                prop: SectionProp::Icon,
                value: PropValue::Const(Value::from("not bytes")),
            },
        ]);
    }

    /// THE SYMBOL VALUE WALL, section side (docs/styling-plan.md D6).
    /// The slot is a bare integer on the wire, so without this an
    /// out-of-vocabulary number reaches four backends' glyph tables,
    /// misses in each, and the tab simply draws with no icon — silent
    /// everywhere. 21 is the first free id, i.e. exactly what a guest
    /// generated against a NEWER spec would send.
    #[test]
    #[should_panic(expected = "21 is not a symbol")]
    fn section_symbol_rejects_a_value_outside_the_vocabulary() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::AddSection { window: DEFAULT_WINDOW, section: WindowId(7) },
            TxOp::SetSectionProp {
                section: WindowId(7),
                prop: SectionProp::Symbol,
                value: PropValue::Const(Value::I64(21)),
            },
        ]);
    }

    /// The sentence NAMES THE VOCABULARY, not just the count — the
    /// reader's next question is always "then what may I say?". Pinned
    /// because a message that merely said "bad symbol" would satisfy
    /// the test above and help nobody.
    #[test]
    #[should_panic(expected = "the vocabulary is add=1, remove=2")]
    fn the_symbol_refusal_names_the_vocabulary() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::AddSection { window: DEFAULT_WINDOW, section: WindowId(7) },
            TxOp::SetSectionProp {
                section: WindowId(7),
                prop: SectionProp::Symbol,
                value: PropValue::Const(Value::I64(0)),
            },
        ]);
    }

    /// Every legal value passes on the section slot — the accept
    /// direction, without which a wall that refused EVERYTHING would
    /// pass both tests above.
    #[test]
    fn every_symbol_in_the_vocabulary_is_accepted_on_a_section() {
        for (id, _name) in crate::wire::SYMBOLS {
            let mut scene = Scene::new();
            scene.apply(vec![
                TxOp::AddSection { window: DEFAULT_WINDOW, section: WindowId(7) },
                TxOp::SetSectionProp {
                    section: WindowId(7),
                    prop: SectionProp::Symbol,
                    value: PropValue::Const(Value::I64(i64::from(*id))),
                },
            ]);
        }
    }

    #[test]
    fn data_before_for_stamps_at_bind_time() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateCollection { id: CollectionId(1), variants: vec![vec![ValueType::Str]] },
            insert(1, vec![], "a", "early"),
        ]);
        let ops = scene.apply(vec![
            TxOp::CreateFor {
                id: 1,
                collection: CollectionId(1),
            },
            TxOp::CreateWidget {
                id: WidgetId(10),
                kind: WidgetKind::Label,
            },
            TxOp::SetProperty {
                widget: WidgetId(10),
                prop: Prop::Text,
                value: PropValue::Element { level: 0, field: 0 },
            },
            TxOp::TemplateEnd,
            TxOp::Mount {
                window: DEFAULT_WINDOW,
                root: WidgetId(1),
            },
        ]);
        assert_eq!(
            creates(&ops),
            vec![(WidgetKind::Column, false), (WidgetKind::Label, false)]
        );
    }

    #[test]
    fn outer_element_reaches_inner_rows() {
        // An item row shows its group's name: element level 1.
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateCollection { id: CollectionId(1), variants: vec![vec![ValueType::Str]] },
            TxOp::CreateFor {
                id: 1,
                collection: CollectionId(1),
            },
            TxOp::CreateCollection { id: CollectionId(2), variants: vec![vec![ValueType::Str]] },
            TxOp::CreateFor {
                id: 10,
                collection: CollectionId(2),
            },
            TxOp::CreateWidget {
                id: WidgetId(20),
                kind: WidgetKind::Label,
            },
            TxOp::SetProperty {
                widget: WidgetId(20),
                prop: Prop::Text,
                value: PropValue::Element { level: 1, field: 0 },
            },
            TxOp::TemplateEnd,
            TxOp::TemplateEnd,
            TxOp::Mount {
                window: DEFAULT_WINDOW,
                root: WidgetId(1),
            },
        ]);
        scene.apply(vec![insert(1, vec![], "g1", "Work")]);
        let ops = scene.apply(vec![insert(2, vec![v("g1")], "a", "ignored")]);
        assert!(ops.iter().any(|op| matches!(
            op,
            ApplyOp::SetProp { value, .. } if *value == v("Work")
        )));
        // Updating the group re-feeds the inner row's label.
        let ops = scene.apply(vec![TxOp::CollectionUpdate {
            id: CollectionId(1),
            path: vec![],
            key: v("g1"),
            variant: 0,
            record: vec![v("Home")],
        }]);
        assert!(ops.iter().any(|op| matches!(
            op,
            ApplyOp::SetProp { value, .. } if *value == v("Home")
        )));
    }

    /// A record collection end to end: a {title: Str, done: Bool}
    /// schema, a template binding each field to its own prop, and a
    /// field update that re-resolves only the bindings on that field.
    #[test]
    fn record_fields_bind_and_update_independently() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateCollection {
                id: CollectionId(1),
                variants: vec![vec![ValueType::Str, ValueType::Bool]],
            },
            TxOp::CreateFor { id: 1, collection: CollectionId(1) },
            TxOp::CreateWidget { id: WidgetId(10), kind: WidgetKind::Label },
            TxOp::SetProperty {
                widget: WidgetId(10),
                prop: Prop::Text,
                value: PropValue::Element { level: 0, field: 0 },
            },
            TxOp::CreateWidget { id: WidgetId(11), kind: WidgetKind::Checkbox },
            TxOp::SetProperty {
                widget: WidgetId(11),
                prop: Prop::Checked,
                value: PropValue::Element { level: 0, field: 1 },
            },
            TxOp::TemplateEnd,
            TxOp::Mount { window: DEFAULT_WINDOW, root: WidgetId(1) },
        ]);
        let ops = scene.apply(vec![TxOp::CollectionInsert {
            id: CollectionId(1),
            path: vec![],
            key: v("a"),
            variant: 0,
            record: vec![v("buy milk"), Value::Bool(false)],
        }]);
        // Stamping resolved each field to its own binding.
        assert!(ops.iter().any(|op| matches!(
            op,
            ApplyOp::SetProp { prop: Prop::Text, value, .. } if *value == v("buy milk")
        )));
        assert!(ops.iter().any(|op| matches!(
            op,
            ApplyOp::SetProp { prop: Prop::Checked, value, .. }
                if *value == Value::Bool(false)
        )));

        // One field's delta: exactly one SetProp, on the Checked binding.
        let ops = scene.apply(vec![TxOp::CollectionUpdateField {
            id: CollectionId(1),
            path: vec![],
            key: v("a"),
            variant: 0,
            field: 1,
            value: Value::Bool(true),
        }]);
        assert_eq!(ops.len(), 1);
        assert!(matches!(
            &ops[0],
            ApplyOp::SetProp { prop: Prop::Checked, value, .. }
                if *value == Value::Bool(true)
        ));
    }

    /// An insert whose record disagrees with the schema — wrong arity
    /// or wrong field type — dies at validation.
    #[test]
    #[should_panic(expected = "field 1 is")]
    fn ill_typed_record_fails_loudly() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateCollection {
                id: CollectionId(1),
                variants: vec![vec![ValueType::Str, ValueType::Bool]],
            },
            TxOp::CollectionInsert {
                id: CollectionId(1),
                path: vec![],
                key: v("a"),
                variant: 0,
                record: vec![v("buy milk"), v("not a bool")],
            },
        ]);
    }

    /// A field binding is validated at template declaration — before
    /// anything stamps: a Checked prop cannot bind a Str field.
    #[test]
    #[should_panic(expected = "cannot bind field 0")]
    fn ill_typed_field_binding_fails_at_declaration() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateCollection {
                id: CollectionId(1),
                variants: vec![vec![ValueType::Str, ValueType::Bool]],
            },
            TxOp::CreateFor { id: 1, collection: CollectionId(1) },
            TxOp::CreateWidget { id: WidgetId(10), kind: WidgetKind::Checkbox },
            TxOp::SetProperty {
                widget: WidgetId(10),
                prop: Prop::Checked,
                value: PropValue::Element { level: 0, field: 0 },
            },
            TxOp::TemplateEnd,
        ]);
    }

    /// A field index past the schema is caught at declaration too.
    #[test]
    #[should_panic(expected = "out of bounds")]
    fn field_binding_out_of_bounds_fails_at_declaration() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateCollection {
                id: CollectionId(1),
                variants: vec![vec![ValueType::Str]],
            },
            TxOp::CreateFor { id: 1, collection: CollectionId(1) },
            TxOp::CreateWidget { id: WidgetId(10), kind: WidgetKind::Label },
            TxOp::SetProperty {
                widget: WidgetId(10),
                prop: Prop::Text,
                value: PropValue::Element { level: 0, field: 3 },
            },
            TxOp::TemplateEnd,
        ]);
    }

    /// The wire is untyped; the scene is not. A raw guest sending a
    /// string where the prop's type says bool must fail at validation,
    /// not in a backend's SetProp match.
    #[test]
    #[should_panic(expected = "cannot hold")]
    fn ill_typed_prop_value_fails_loudly() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget {
                id: WidgetId(1),
                kind: WidgetKind::Checkbox,
            },
            TxOp::SetProperty {
                widget: WidgetId(1),
                prop: Prop::Checked,
                value: PropValue::Const(v("not a bool")),
            },
        ]);
    }

    /// The same guard covers bindings: a signal's type is fixed at
    /// creation, so binding a string signal to a bool prop is caught
    /// when the binding is declared.
    #[test]
    #[should_panic(expected = "cannot hold")]
    fn ill_typed_prop_binding_fails_loudly() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateSignal {
                id: SignalId(1),
                initial: v("a string"),
            },
            TxOp::CreateWidget {
                id: WidgetId(1),
                kind: WidgetKind::Checkbox,
            },
            TxOp::SetProperty {
                widget: WidgetId(1),
                prop: Prop::Checked,
                value: PropValue::Signal(SignalId(1)),
            },
        ]);
    }

    #[test]
    #[should_panic(expected = "already present")]
    fn duplicate_insert_fails_loudly() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateCollection { id: CollectionId(1), variants: vec![vec![ValueType::Str]] },
            insert(1, vec![], "a", "x"),
            insert(1, vec![], "a", "y"),
        ]);
    }

    #[test]
    #[should_panic(expected = "must bind a collection declared in its own scope")]
    fn cross_scope_for_fails_loudly() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateCollection { id: CollectionId(1), variants: vec![vec![ValueType::Str]] },
            TxOp::CreateFor {
                id: 1,
                collection: CollectionId(1),
            },
            // Nested For binding the top-level collection: forbidden.
            TxOp::CreateFor {
                id: 10,
                collection: CollectionId(1),
            },
            TxOp::TemplateEnd,
            TxOp::TemplateEnd,
        ]);
    }

    #[test]
    #[should_panic(expected = "exceeds For nesting depth")]
    fn element_level_out_of_range_fails_loudly() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateCollection { id: CollectionId(1), variants: vec![vec![ValueType::Str]] },
            TxOp::CreateFor {
                id: 1,
                collection: CollectionId(1),
            },
            TxOp::CreateWidget {
                id: WidgetId(10),
                kind: WidgetKind::Label,
            },
            TxOp::SetProperty {
                widget: WidgetId(10),
                prop: Prop::Text,
                value: PropValue::Element { level: 1, field: 0 },
            },
            TxOp::TemplateEnd,
        ]);
    }

    #[test]
    #[should_panic(expected = "left open")]
    fn unterminated_template_fails_loudly() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateCollection { id: CollectionId(1), variants: vec![vec![ValueType::Str]] },
            TxOp::CreateFor {
                id: 1,
                collection: CollectionId(1),
            },
        ]);
    }

    // --- Milestone-1 behavior, unchanged ---------------------------------

    fn milestone1_scene() -> Transaction {
        vec![
            TxOp::CreateSignal {
                id: SignalId(1),
                initial: v("Clicked 0 times"),
            },
            TxOp::CreateWidget {
                id: WidgetId(1),
                kind: WidgetKind::Column,
            },
            TxOp::CreateWidget {
                id: WidgetId(2),
                kind: WidgetKind::Button,
            },
            TxOp::SetProperty {
                widget: WidgetId(2),
                prop: Prop::Text,
                value: PropValue::Const(v("Click me")),
            },
            TxOp::CreateWidget {
                id: WidgetId(3),
                kind: WidgetKind::Label,
            },
            TxOp::SetProperty {
                widget: WidgetId(3),
                prop: Prop::Text,
                value: PropValue::Signal(SignalId(1)),
            },
            TxOp::AddChild {
                parent: WidgetId(1),
                child: WidgetId(2),
            },
            TxOp::AddChild {
                parent: WidgetId(1),
                child: WidgetId(3),
            },
            TxOp::Mount {
                window: DEFAULT_WINDOW,
                root: WidgetId(1),
            },
        ]
    }

    #[test]
    fn milestone1_scene_still_applies() {
        let mut scene = Scene::new();
        let ops = scene.apply(milestone1_scene());
        // Live buttons carry a plain tag (widget id, empty path).
        let tag = ops
            .iter()
            .find_map(|op| match op {
                ApplyOp::Create { tag: Some(t), .. } => Some(t.clone()),
                _ => None,
            })
            .unwrap();
        assert_eq!(
            crate::wire::decode_click_tag(&tag),
            crate::protocol::Occurrence::ButtonClicked { id: WidgetId(2) }
        );
        let ops = scene.apply(vec![TxOp::WriteSignal {
            id: SignalId(1),
            value: v("Clicked 1 time"),
        }]);
        assert_eq!(
            ops,
            vec![ApplyOp::SetProp {
                id: WidgetId(3),
                prop: Prop::Text,
                value: v("Clicked 1 time")
            }]
        );
    }

    #[test]
    fn writes_coalesce_within_a_transaction() {
        let mut scene = Scene::new();
        scene.apply(milestone1_scene());
        let ops = scene.apply(vec![
            TxOp::WriteSignal {
                id: SignalId(1),
                value: v("Clicked 1 time"),
            },
            TxOp::WriteSignal {
                id: SignalId(1),
                value: v("Clicked 2 times"),
            },
        ]);
        assert_eq!(
            ops,
            vec![ApplyOp::SetProp {
                id: WidgetId(3),
                prop: Prop::Text,
                value: v("Clicked 2 times")
            }]
        );
    }

    #[test]
    #[should_panic(expected = "already exists")]
    fn id_collisions_fail_loudly() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateSignal {
                id: SignalId(1),
                initial: Value::Bool(false),
            },
            TxOp::CreateSignal {
                id: SignalId(1),
                initial: Value::Bool(true),
            },
        ]);
    }

    #[test]
    #[should_panic(expected = "changes the type")]
    fn type_changes_fail_loudly() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateSignal {
                id: SignalId(1),
                initial: Value::I64(0),
            },
            TxOp::WriteSignal {
                id: SignalId(1),
                value: v("nope"),
            },
        ]);
    }

    /// A negative weight has no reading under the grow contract, so it
    /// dies at the root rather than becoming a different improvisation
    /// in each of seven backends.
    #[test]
    #[should_panic(expected = "grow weight must be finite and non-negative")]
    fn negative_grow_weight_fails_loudly() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget {
                id: WidgetId(1),
                kind: WidgetKind::Column,
            },
            TxOp::SetProperty {
                widget: WidgetId(1),
                prop: Prop::Grow,
                value: PropValue::Const(Value::F64(-1.0)),
            },
        ]);
    }

    /// Zero is the default and must stay legal — the guard rejects
    /// negatives, not the "no weight" case that every non-grower has.
    #[test]
    fn zero_grow_weight_is_legal() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget {
                id: WidgetId(1),
                kind: WidgetKind::Column,
            },
            TxOp::SetProperty {
                widget: WidgetId(1),
                prop: Prop::Grow,
                value: PropValue::Const(Value::F64(0.0)),
            },
            TxOp::Mount { window: DEFAULT_WINDOW, root: WidgetId(1) },
        ]);
    }

    /// The hint is the one accessibility prop with a domain, and the
    /// domain is the platforms' own: a hint describes what ACTIVATING
    /// the control does, and Android has nowhere to put one without an
    /// action to hang it on. So a hint on a label dies here rather than
    /// reaching four backends and silently missing the fifth.
    #[test]
    #[should_panic(expected = "has no property")]
    fn hint_on_a_non_activation_kind_fails_loudly() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget {
                id: WidgetId(1),
                kind: WidgetKind::Label,
            },
            TxOp::SetProperty {
                widget: WidgetId(1),
                prop: Prop::A11yHint,
                value: PropValue::Const(v("does something")),
            },
        ]);
    }

    /// ...and the activation kinds take it, so the check is a domain
    /// and not a blanket refusal.
    #[test]
    fn hint_on_the_activation_kinds() {
        for kind in [
            WidgetKind::Button,
            WidgetKind::Checkbox,
            WidgetKind::Select,
            WidgetKind::Radio,
        ] {
            let mut scene = Scene::new();
            scene.apply(vec![
                TxOp::CreateWidget { id: WidgetId(1), kind },
                TxOp::SetProperty {
                    widget: WidgetId(1),
                    prop: Prop::A11yHint,
                    value: PropValue::Const(v("do the thing")),
                },
                TxOp::Mount { window: DEFAULT_WINDOW, root: WidgetId(1) },
            ]);
        }
    }

    #[test]
    #[should_panic(expected = "has no property")]
    fn wrong_property_fails_loudly() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget {
                id: WidgetId(1),
                kind: WidgetKind::Column,
            },
            TxOp::SetProperty {
                widget: WidgetId(1),
                prop: Prop::Text,
                value: PropValue::Const(v("x")),
            },
        ]);
    }

    /// The sum happy path: a Note{Str} | Todo{Str,Bool} feed, one case
    /// per constructor. Stamping picks the case by the entry's
    /// discriminant, and an update with a different tag restamps the
    /// entry in place — same key, same slot, new shape.
    #[test]
    fn sum_stamps_per_variant_and_restamps_on_change() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateCollection {
                id: CollectionId(1),
                variants: vec![
                    vec![ValueType::Str],
                    vec![ValueType::Str, ValueType::Bool],
                ],
            },
            TxOp::CreateFor { id: 1, collection: CollectionId(1) },
            TxOp::VariantCase { variant: 0 },
            TxOp::CreateWidget { id: WidgetId(10), kind: WidgetKind::Label },
            TxOp::SetProperty {
                widget: WidgetId(10),
                prop: Prop::Text,
                value: PropValue::Element { level: 0, field: 0 },
            },
            TxOp::VariantCase { variant: 1 },
            TxOp::CreateWidget { id: WidgetId(20), kind: WidgetKind::Checkbox },
            TxOp::SetProperty {
                widget: WidgetId(20),
                prop: Prop::Checked,
                value: PropValue::Element { level: 0, field: 1 },
            },
            TxOp::TemplateEnd,
            TxOp::Mount { window: DEFAULT_WINDOW, root: WidgetId(1) },
        ]);

        // A note stamps the label case; a todo stamps the checkbox case.
        let ops = scene.apply(vec![
            TxOp::CollectionInsert {
                id: CollectionId(1),
                path: vec![],
                key: v("a"),
                variant: 0,
                record: vec![v("jot")],
            },
            TxOp::CollectionInsert {
                id: CollectionId(1),
                path: vec![],
                key: v("b"),
                variant: 1,
                record: vec![v("buy milk"), Value::Bool(false)],
            },
        ]);
        let creates = |ops: &[ApplyOp], kind: WidgetKind| {
            ops.iter()
                .filter(|op| matches!(op, ApplyOp::Create { kind: k, .. } if *k == kind))
                .count()
        };
        assert_eq!(creates(&ops, WidgetKind::Label), 1);
        assert_eq!(creates(&ops, WidgetKind::Checkbox), 1);

        // Promoting the note re-eliminates: old copy destroyed, the
        // todo case stamped, and the fresh copy moved back before b's.
        let ops = scene.apply(vec![TxOp::CollectionUpdate {
            id: CollectionId(1),
            path: vec![],
            key: v("a"),
            variant: 1,
            record: vec![v("jot"), Value::Bool(true)],
        }]);
        assert!(ops.iter().any(|op| matches!(op, ApplyOp::Destroy { .. })));
        assert_eq!(creates(&ops, WidgetKind::Checkbox), 1);
        assert!(
            ops.iter().any(|op| matches!(
                op,
                ApplyOp::MoveChild { before: Some(_), .. }
            )),
            "restamp must reposition into the entry's slot, not append"
        );

        // The witnessed field write reaches the new constructor.
        let ops = scene.apply(vec![TxOp::CollectionUpdateField {
            id: CollectionId(1),
            path: vec![],
            key: v("a"),
            variant: 1,
            field: 1,
            value: Value::Bool(false),
        }]);
        assert_eq!(ops.len(), 1);
    }

    /// Totality is checked where the eliminator is declared: a For
    /// over a sum with a missing case dies at template_end, naming the
    /// hole — not on the first insert of the unlucky constructor.
    #[test]
    #[should_panic(expected = "declares no case for variant 1")]
    fn missing_case_dies_at_declaration() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateCollection {
                id: CollectionId(1),
                variants: vec![vec![ValueType::Str], vec![ValueType::Str]],
            },
            TxOp::CreateFor { id: 1, collection: CollectionId(1) },
            TxOp::VariantCase { variant: 0 },
            TxOp::CreateWidget { id: WidgetId(10), kind: WidgetKind::Label },
            TxOp::TemplateEnd,
        ]);
    }

    /// A caseless For over a sum is the same hole.
    #[test]
    #[should_panic(expected = "needs a variant_case per variant")]
    fn caseless_for_over_sum_dies() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateCollection {
                id: CollectionId(1),
                variants: vec![vec![ValueType::Str], vec![ValueType::Str]],
            },
            TxOp::CreateFor { id: 1, collection: CollectionId(1) },
            TxOp::CreateWidget { id: WidgetId(10), kind: WidgetKind::Label },
            TxOp::TemplateEnd,
        ]);
    }

    /// Records before the first variant_case belong to no constructor.
    #[test]
    #[should_panic(expected = "before the first variant_case")]
    fn records_before_first_case_die() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateCollection {
                id: CollectionId(1),
                variants: vec![vec![ValueType::Str], vec![ValueType::Str]],
            },
            TxOp::CreateFor { id: 1, collection: CollectionId(1) },
            TxOp::CreateWidget { id: WidgetId(10), kind: WidgetKind::Label },
            TxOp::VariantCase { variant: 0 },
            TxOp::TemplateEnd,
        ]);
    }

    /// Declaring the same case twice is a contradiction, not a merge.
    #[test]
    #[should_panic(expected = "declared twice")]
    fn duplicate_case_dies() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateCollection {
                id: CollectionId(1),
                variants: vec![vec![ValueType::Str], vec![ValueType::Str]],
            },
            TxOp::CreateFor { id: 1, collection: CollectionId(1) },
            TxOp::VariantCase { variant: 0 },
            TxOp::VariantCase { variant: 1 },
            TxOp::VariantCase { variant: 0 },
            TxOp::TemplateEnd,
        ]);
    }

    /// The witnessed discriminant must match the entry's stored one: a
    /// binding whose model drifted from the core dies here instead of
    /// writing a type-correct field of the wrong constructor.
    #[test]
    #[should_panic(expected = "holds variant 0")]
    fn witnessed_variant_mismatch_dies() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateCollection {
                id: CollectionId(1),
                variants: vec![
                    vec![ValueType::Str],
                    vec![ValueType::Str, ValueType::Bool],
                ],
            },
            TxOp::CollectionInsert {
                id: CollectionId(1),
                path: vec![],
                key: v("a"),
                variant: 0,
                record: vec![v("jot")],
            },
            TxOp::CollectionUpdateField {
                id: CollectionId(1),
                path: vec![],
                key: v("a"),
                variant: 1,
                field: 1,
                value: Value::Bool(true),
            },
        ]);
    }

    /// An element binding inside a case sees that variant's schema:
    /// field 1 of a one-field constructor dies at declaration.
    #[test]
    #[should_panic(expected = "out of bounds for variant 0")]
    fn case_binding_validates_against_its_variant() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateCollection {
                id: CollectionId(1),
                variants: vec![
                    vec![ValueType::Str],
                    vec![ValueType::Str, ValueType::Bool],
                ],
            },
            TxOp::CreateFor { id: 1, collection: CollectionId(1) },
            TxOp::VariantCase { variant: 0 },
            TxOp::CreateWidget { id: WidgetId(10), kind: WidgetKind::Label },
            TxOp::SetProperty {
                widget: WidgetId(10),
                prop: Prop::Text,
                value: PropValue::Element { level: 0, field: 1 },
            },
            TxOp::VariantCase { variant: 1 },
            TxOp::TemplateEnd,
        ]);
    }

    /// An empty case is the explicit "render nothing" for a
    /// constructor: the entry stamps no widgets and tears down clean.
    #[test]
    fn empty_case_renders_nothing() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateCollection {
                id: CollectionId(1),
                variants: vec![vec![ValueType::Str], vec![ValueType::Str]],
            },
            TxOp::CreateFor { id: 1, collection: CollectionId(1) },
            TxOp::VariantCase { variant: 0 },
            TxOp::CreateWidget { id: WidgetId(10), kind: WidgetKind::Label },
            TxOp::SetProperty {
                widget: WidgetId(10),
                prop: Prop::Text,
                value: PropValue::Element { level: 0, field: 0 },
            },
            TxOp::VariantCase { variant: 1 },
            TxOp::TemplateEnd,
            TxOp::Mount { window: DEFAULT_WINDOW, root: WidgetId(1) },
        ]);
        let ops = scene.apply(vec![TxOp::CollectionInsert {
            id: CollectionId(1),
            path: vec![],
            key: v("quiet"),
            variant: 1,
            record: vec![v("hidden")],
        }]);
        assert!(
            ops.is_empty(),
            "an empty case stamps nothing, explicitly: {ops:?}"
        );
        let ops = scene.apply(vec![TxOp::CollectionRemove {
            id: CollectionId(1),
            path: vec![],
            key: v("quiet"),
        }]);
        assert!(ops.is_empty());
    }

    // --- Navigation: the serial stack (DESIGN.md, Navigation) ---

    #[test]
    fn push_mount_pop_lifecycle() {
        use crate::protocol::EntryProp;
        let mut scene = Scene::new();
        let ops = scene.apply(vec![
            TxOp::PushEntry { window: DEFAULT_WINDOW, entry: WindowId(5) },
            TxOp::SetEntryProp {
                entry: WindowId(5),
                prop: EntryProp::Title,
                value: PropValue::Const(v("detail")),
            },
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Label },
            TxOp::Mount { window: WindowId(5), root: WidgetId(1) },
        ]);
        assert_eq!(
            format!("{ops:?}"),
            format!(
                "{:?}",
                vec![
                    ApplyOp::PushEntry { window: DEFAULT_WINDOW, entry: WindowId(5) },
                    ApplyOp::SetEntryProp {
                        entry: WindowId(5),
                        prop: EntryProp::Title,
                        value: v("detail"),
                    },
                    ApplyOp::Create { id: WidgetId(1), kind: WidgetKind::Label, tag: None },
                    ApplyOp::Mount { window: WindowId(5), root: WidgetId(1) },
                ]
            )
        );
        let ops = scene.apply(vec![TxOp::PopEntry { window: DEFAULT_WINDOW }]);
        assert_eq!(
            format!("{ops:?}"),
            format!("{:?}", vec![ApplyOp::PopEntry { window: DEFAULT_WINDOW }])
        );
        // The popped surface is gone: a re-mount targets nothing.
        let err = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            scene.apply(vec![TxOp::Mount { window: WindowId(5), root: WidgetId(1) }]);
        }));
        assert!(err.is_err(), "mount into a popped entry must fail loudly");
    }

    #[test]
    #[should_panic(expected = "empty navigation stack")]
    fn pop_of_empty_stack_fails_loudly() {
        let mut scene = Scene::new();
        scene.apply(vec![TxOp::PopEntry { window: DEFAULT_WINDOW }]);
    }

    #[test]
    #[should_panic(expected = "already exists")]
    fn entry_id_collision_fails_loudly() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::PushEntry { window: DEFAULT_WINDOW, entry: WindowId(5) },
            TxOp::PushEntry { window: DEFAULT_WINDOW, entry: WindowId(5) },
        ]);
    }

    #[test]
    #[should_panic(expected = "entry prop on unknown entry")]
    fn entry_prop_on_unknown_entry_fails_loudly() {
        use crate::protocol::EntryProp;
        let mut scene = Scene::new();
        scene.apply(vec![TxOp::SetEntryProp {
            entry: WindowId(5),
            prop: EntryProp::Title,
            value: PropValue::Const(v("ghost")),
        }]);
    }

    #[test]
    #[should_panic(expected = "rejects value")]
    fn intercept_back_rejects_non_bool() {
        use crate::protocol::EntryProp;
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::PushEntry { window: DEFAULT_WINDOW, entry: WindowId(5) },
            TxOp::SetEntryProp {
                entry: WindowId(5),
                prop: EntryProp::InterceptBack,
                value: PropValue::Const(v("yes")),
            },
        ]);
    }

    #[test]
    fn user_pop_reconciles_the_stack() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::PushEntry { window: DEFAULT_WINDOW, entry: WindowId(5) },
            TxOp::PushEntry { window: DEFAULT_WINDOW, entry: WindowId(6) },
        ]);
        // The user's back affordance popped the top natively; the
        // core reconciles post-fact with no ApplyOp.
        scene.user_popped(WindowId(6));
        // The remaining entry is now the top and pops normally.
        let ops = scene.apply(vec![TxOp::PopEntry { window: DEFAULT_WINDOW }]);
        assert_eq!(
            format!("{ops:?}"),
            format!("{:?}", vec![ApplyOp::PopEntry { window: DEFAULT_WINDOW }])
        );
    }

    #[test]
    #[should_panic(expected = "but the top of")]
    fn user_pop_of_covered_entry_fails_loudly() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::PushEntry { window: DEFAULT_WINDOW, entry: WindowId(5) },
            TxOp::PushEntry { window: DEFAULT_WINDOW, entry: WindowId(6) },
        ]);
        scene.user_popped(WindowId(5));
    }

    #[test]
    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    fn destroyed_window_sweeps_its_stack() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWindow { window: WindowId(2) },
            TxOp::PushEntry { window: WindowId(2), entry: WindowId(3) },
            TxOp::DestroyWindow { window: WindowId(2) },
        ]);
        // The entry went with its window: its id no longer names a
        // surface.
        let err = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            scene.apply(vec![TxOp::PopEntry { window: WindowId(2) }]);
        }));
        assert!(err.is_err(), "the destroyed window's stack must be gone");
    }

    #[test]
    fn signal_bound_entry_title_fans_out() {
        use crate::protocol::EntryProp;
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateSignal { id: SignalId(1), initial: v("first") },
            TxOp::PushEntry { window: DEFAULT_WINDOW, entry: WindowId(5) },
            TxOp::SetEntryProp {
                entry: WindowId(5),
                prop: EntryProp::Title,
                value: PropValue::Signal(SignalId(1)),
            },
        ]);
        let ops = scene.apply(vec![TxOp::WriteSignal { id: SignalId(1), value: v("second") }]);
        assert_eq!(
            format!("{ops:?}"),
            format!(
                "{:?}",
                vec![ApplyOp::SetEntryProp {
                    entry: WindowId(5),
                    prop: EntryProp::Title,
                    value: v("second"),
                }]
            )
        );
    }

    /// The happy path of the select grammar: options (label children)
    /// first, then an in-range selection — and the select carries an
    /// identity tag like every interactive kind (it emits
    /// value_changed).
    #[test]
    fn select_options_then_selection() {
        let mut scene = Scene::new();
        let ops = scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Select },
            TxOp::CreateWidget { id: WidgetId(2), kind: WidgetKind::Label },
            TxOp::CreateWidget { id: WidgetId(3), kind: WidgetKind::Label },
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(2) },
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(3) },
            TxOp::SetProperty {
                widget: WidgetId(1),
                prop: Prop::Value,
                value: PropValue::Const(Value::F64(1.0)),
            },
            TxOp::Mount { window: DEFAULT_WINDOW, root: WidgetId(1) },
        ]);
        let tagged = ops.iter().any(|op| {
            matches!(op, ApplyOp::Create { id, kind: WidgetKind::Select, tag: Some(_) }
                     if *id == WidgetId(1))
        });
        assert!(tagged, "a select carries its identity tag");
    }

    /// A select's children are its options: labels only. Anything else
    /// has no dropdown reading and dies at the root.
    #[test]
    #[should_panic(expected = "labels only")]
    fn select_rejects_non_label_children() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Select },
            TxOp::CreateWidget { id: WidgetId(2), kind: WidgetKind::Button },
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(2) },
        ]);
    }

    /// The index's upper bound is the option count at that point in op
    /// order: selecting past the end dies at the root.
    #[test]
    #[should_panic(expected = "out of range")]
    fn select_index_out_of_range_fails_loudly() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Select },
            TxOp::CreateWidget { id: WidgetId(2), kind: WidgetKind::Label },
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(2) },
            TxOp::SetProperty {
                widget: WidgetId(1),
                prop: Prop::Value,
                value: PropValue::Const(Value::F64(1.0)),
            },
        ]);
    }

    /// A fractional index has no reading — the select's value is a
    /// 0-based option index.
    #[test]
    #[should_panic(expected = "0-based option index")]
    fn select_fractional_index_fails_loudly() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Select },
            TxOp::CreateWidget { id: WidgetId(2), kind: WidgetKind::Label },
            TxOp::CreateWidget { id: WidgetId(3), kind: WidgetKind::Label },
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(2) },
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(3) },
            TxOp::SetProperty {
                widget: WidgetId(1),
                prop: Prop::Value,
                value: PropValue::Const(Value::F64(0.5)),
            },
        ]);
    }

    /// A signal-bound selection is checked against the signal's
    /// current value at bind time (the progress-fraction policy).
    #[test]
    #[should_panic(expected = "out of range")]
    fn select_signal_bound_index_checked_at_bind() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateSignal { id: SignalId(1), initial: Value::F64(2.0) },
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Select },
            TxOp::CreateWidget { id: WidgetId(2), kind: WidgetKind::Label },
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(2) },
            TxOp::SetProperty {
                widget: WidgetId(1),
                prop: Prop::Value,
                value: PropValue::Signal(SignalId(1)),
            },
        ]);
    }

    /// The radio group shares the choice contract wholesale: same
    /// arms, so one happy path and one negative pin the sharing.
    #[test]
    fn radio_shares_the_choice_contract() {
        let mut scene = Scene::new();
        let ops = scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Radio },
            TxOp::CreateWidget { id: WidgetId(2), kind: WidgetKind::Label },
            TxOp::CreateWidget { id: WidgetId(3), kind: WidgetKind::Label },
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(2) },
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(3) },
            TxOp::SetProperty {
                widget: WidgetId(1),
                prop: Prop::Value,
                value: PropValue::Const(Value::F64(1.0)),
            },
            TxOp::Mount { window: DEFAULT_WINDOW, root: WidgetId(1) },
        ]);
        let tagged = ops.iter().any(|op| {
            matches!(op, ApplyOp::Create { id, kind: WidgetKind::Radio, tag: Some(_) }
                     if *id == WidgetId(1))
        });
        assert!(tagged, "a radio group carries its identity tag");
    }

    #[test]
    #[should_panic(expected = "out of range")]
    fn radio_index_out_of_range_fails_loudly() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Radio },
            TxOp::CreateWidget { id: WidgetId(2), kind: WidgetKind::Label },
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(2) },
            TxOp::SetProperty {
                widget: WidgetId(1),
                prop: Prop::Value,
                value: PropValue::Const(Value::F64(1.0)),
            },
        ]);
    }

    /// The grid's column count: integral and >= 1, or it has no
    /// reading.
    #[test]
    #[should_panic(expected = "integral count >= 1")]
    fn grid_zero_columns_fails_loudly() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Grid },
            TxOp::SetProperty {
                widget: WidgetId(1),
                prop: Prop::Columns,
                value: PropValue::Const(Value::F64(0.0)),
            },
        ]);
    }

    #[test]
    #[should_panic(expected = "has no property")]
    fn columns_on_a_column_fails_loudly() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Column },
            TxOp::SetProperty {
                widget: WidgetId(1),
                prop: Prop::Columns,
                value: PropValue::Const(Value::F64(2.0)),
            },
        ]);
    }

    /// The scroll viewport's one-child contract, as a test (the guard
    /// predates this negative test — closing the gap).
    #[test]
    #[should_panic(expected = "takes exactly one")]
    fn scroll_rejects_second_child() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Scroll },
            TxOp::CreateWidget { id: WidgetId(2), kind: WidgetKind::Column },
            TxOp::CreateWidget { id: WidgetId(3), kind: WidgetKind::Column },
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(2) },
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(3) },
        ]);
    }

    /// The progress fraction's 0..=1 domain, as a test (same
    /// gap-closing as scroll_rejects_second_child).
    #[test]
    #[should_panic(expected = "lives in 0..=1")]
    fn progress_fraction_out_of_range_fails_loudly() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Progress },
            TxOp::SetProperty {
                widget: WidgetId(1),
                prop: Prop::Value,
                value: PropValue::Const(Value::F64(1.5)),
            },
        ]);
    }

    // --- Menus -----------------------------------------------------------

    use crate::protocol::{MenuItemId, MenuItemKind, MenuProp, TemplateNodeId};

    fn item(id: u64, kind: MenuItemKind) -> TxOp {
        TxOp::MenuItemCreate { item: MenuItemId(id), kind }
    }
    fn label(id: u64, text: &str) -> TxOp {
        TxOp::SetMenuProp {
            item: MenuItemId(id),
            prop: MenuProp::Label,
            value: PropValue::Const(v(text)),
        }
    }
    fn append(parent: u64, child: u64) -> TxOp {
        TxOp::MenuItemAppend { parent: MenuItemId(parent), child: MenuItemId(child) }
    }
    fn sc(id: u64, spelling: &str) -> TxOp {
        TxOp::SetMenuProp {
            item: MenuItemId(id),
            prop: MenuProp::Shortcut,
            value: PropValue::Const(v(spelling)),
        }
    }
    fn role(id: u64, name: &str) -> TxOp {
        TxOp::SetMenuProp {
            item: MenuItemId(id),
            prop: MenuProp::Role,
            value: PropValue::Const(v(name)),
        }
    }

    /// A bar catalog builds, a signal-bound `enabled` fans out on write,
    /// and a bar-anchored action's shortcut joins the window catalog.
    #[test]
    fn menu_bar_builds_and_enabled_fans_out() {
        let mut scene = Scene::new();
        let ops = scene.apply(vec![
            TxOp::CreateSignal { id: SignalId(1), initial: Value::Bool(false) },
            item(1, MenuItemKind::Menu),
            label(1, "File"),
            item(2, MenuItemKind::Action),
            label(2, "Save"),
            TxOp::SetMenuProp {
                item: MenuItemId(2),
                prop: MenuProp::Shortcut,
                value: PropValue::Const(v("primary+s")),
            },
            item(3, MenuItemKind::Action),
            label(3, "Export"),
            TxOp::SetMenuProp {
                item: MenuItemId(3),
                prop: MenuProp::Enabled,
                value: PropValue::Signal(SignalId(1)),
            },
            append(1, 2),
            append(1, 3),
            TxOp::MenubarAppend { window: DEFAULT_WINDOW, item: MenuItemId(1) },
        ]);
        assert!(ops.iter().any(|op| matches!(
            op,
            ApplyOp::MenuItemCreate { item: MenuItemId(1), kind: MenuItemKind::Menu }
        )));
        assert!(ops
            .iter()
            .any(|op| matches!(op, ApplyOp::MenubarAppend { item: MenuItemId(1), .. })));
        // Export's enabled binding emitted the signal's current (false).
        assert!(ops.iter().any(|op| matches!(
            op,
            ApplyOp::SetMenuProp { item: MenuItemId(3), prop: MenuProp::Enabled, value: Value::Bool(false) }
        )));
        // Flipping the shared signal fans the new value out.
        let ops = scene.apply(vec![TxOp::WriteSignal {
            id: SignalId(1),
            value: Value::Bool(true),
        }]);
        assert!(ops.iter().any(|op| matches!(
            op,
            ApplyOp::SetMenuProp { item: MenuItemId(3), prop: MenuProp::Enabled, value: Value::Bool(true) }
        )));
    }

    /// A radio group takes radio_option children and a selected index in
    /// range; a bar radio_group is a legal top-level entry.
    #[test]
    fn radio_group_options_and_value() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::RadioGroup),
            label(1, "Sort"),
            item(2, MenuItemKind::RadioOption),
            label(2, "Name"),
            item(3, MenuItemKind::RadioOption),
            label(3, "Date"),
            append(1, 2),
            append(1, 3),
            TxOp::SetMenuProp {
                item: MenuItemId(1),
                prop: MenuProp::Value,
                value: PropValue::Const(Value::F64(1.0)),
            },
            TxOp::MenubarAppend { window: DEFAULT_WINDOW, item: MenuItemId(1) },
        ]);
    }

    /// The node-anchored context attach: the shared item tree stamps a
    /// CONTEXT_ATTACH_NODE per copy carrying that copy's key as the noun
    /// (the on_click_node encoding).
    #[test]
    fn context_attach_node_stamps_with_noun_path() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Action),
            label(1, "Remove"),
            TxOp::CreateCollection { id: CollectionId(1), variants: vec![vec![ValueType::Str]] },
            TxOp::CreateFor { id: 3, collection: CollectionId(1) },
            TxOp::CreateWidget { id: WidgetId(30), kind: WidgetKind::Label },
            TxOp::SetProperty {
                widget: WidgetId(30),
                prop: Prop::Text,
                value: PropValue::Element { level: 0, field: 0 },
            },
            TxOp::ContextAttachNode { node: TemplateNodeId(30), item: MenuItemId(1) },
            TxOp::TemplateEnd,
            TxOp::Mount { window: DEFAULT_WINDOW, root: WidgetId(3) },
        ]);
        let ops = scene.apply(vec![insert(1, vec![], "a", "Alice")]);
        assert!(
            ops.iter().any(|op| matches!(
                op,
                ApplyOp::ContextAttachNode { item: MenuItemId(1), path, .. } if path == &vec![v("a")]
            )),
            "the stamped context attach must carry the row's key as the noun"
        );
    }

    /// The full canonical-shortcut grammar and the reserved floor, as an
    /// accept/reject table (the core validates, never rewrites).
    #[test]
    fn shortcut_grammar_table() {
        for ok in [
            "primary+s",
            "primary+shift+s",
            "primary+a",
            "alt+a",
            "shift+alt+a",
            "primary+shift+alt+s",
            "primary+0",
            "alt+9",
            "primary+f", // 'f' is an alphanumeric key, not a modifier
            "enter",
            "primary+enter",
            "delete",
            "primary+delete",
            "left",
            "right",
            "up",
            "down",
            "primary+left",
            "f1",
            "f12",
            "primary+f5",
            "alt+f7",
            // The punctuation set, named rather than spelled with the
            // character (DESIGN.md, Menus). Command-plus is
            // primary+shift+equal — no separate `plus` key exists.
            "primary+comma",
            "primary+period",
            "primary+slash",
            "primary+backslash",
            "primary+minus",
            "primary+equal",
            "primary+shift+equal",
            "primary+leftbracket",
            "primary+rightbracket",
            "alt+comma",
            "primary+shift+slash",
        ] {
            assert!(validate_shortcut(ok).is_ok(), "expected accept: {ok:?}");
        }
        for bad in [
            "",                       // empty
            " ",                      // whitespace
            "primary + s",            // whitespace
            "s",                      // bare alphanumeric
            "0",                      // bare alphanumeric
            "shift+s",                // shift-only alphanumeric
            "shift+enter",            // shift-only named
            "shift+f1",               // shift-only named
            "escape",                 // escape unmodified
            "primary+escape",         // escape modified
            "shift+alt+escape",       // escape modified
            "alt+escape",             // escape modified
            "primary+q",              // reserved floor
            "alt+f4",                 // reserved floor
            "ctrl+s",                 // modifier alias
            "cmd+s",                  // modifier alias
            "option+a",               // modifier alias
            "meta+s",                 // modifier alias
            "primary+shift",          // no key ('shift' is not a key)
            "primary+",               // empty token
            "+s",                     // empty token
            "primary++s",             // empty token
            "shift+primary+s",        // non-canonical order
            "alt+shift+primary+s",    // non-canonical order
            "primary+primary+s",      // duplicate modifier
            "shift+shift+enter",      // duplicate modifier
            "primary+S",              // uppercase key
            "primary+.",              // the character, not the name
            "primary+,",              // the character, not the name
            "comma",                  // bare punctuation
            "shift+comma",            // shift-only punctuation
            "period",                 // bare punctuation
            "primary+plus",           // not in the closed set (shift+equal)
            "primary+semicolon",      // not in the closed set
            "primary+quote",          // not in the closed set
            "primary+grave",          // not in the closed set
            "primary+Comma",          // uppercase
            "primary+f0",             // f0 is not a function key
            "primary+f13",            // f13 is out of range
            "primary+tab",            // unknown named key
            "primary+space",          // unknown named key
            "primary+esc",            // not the canonical 'escape'
            "primary+ab",             // two-character key
        ] {
            assert!(validate_shortcut(bad).is_err(), "expected reject: {bad:?}");
        }
    }

    /// A menu binding's domain is validated on the COMPLETE coalesced
    /// value at the barrier; a rejection restores EVERY signal the batch
    /// wrote, so a caught panic leaves no partial signal state.
    #[test]
    fn barrier_rollback_restores_signals_on_menu_reject() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateSignal { id: SignalId(1), initial: Value::F64(0.0) },
            TxOp::CreateSignal { id: SignalId(2), initial: v("keep") },
            item(1, MenuItemKind::RadioGroup),
            label(1, "Sort"),
            item(2, MenuItemKind::RadioOption),
            label(2, "A"),
            item(3, MenuItemKind::RadioOption),
            label(3, "B"),
            append(1, 2),
            append(1, 3),
            TxOp::SetMenuProp {
                item: MenuItemId(1),
                prop: MenuProp::Value,
                value: PropValue::Signal(SignalId(1)),
            },
            TxOp::MenubarAppend { window: DEFAULT_WINDOW, item: MenuItemId(1) },
        ]);
        let caught = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            // The unrelated write lands first; the coalesced radio value
            // is out of range (2 options, index 5) and the barrier
            // rejects.
            scene.apply(vec![
                TxOp::WriteSignal { id: SignalId(2), value: v("changed") },
                TxOp::WriteSignal { id: SignalId(1), value: Value::F64(5.0) },
            ]);
        }));
        assert!(caught.is_err(), "an out-of-range coalesced radio value must reject");
        assert_eq!(scene.signals[&SignalId(1)], Value::F64(0.0));
        assert_eq!(scene.signals[&SignalId(2)], v("keep"));
    }

    #[test]
    #[should_panic(expected = "cannot contain")]
    fn menu_grammar_rejects_bad_edge() {
        // A radio_group accepts only radio_option children.
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::RadioGroup),
            item(2, MenuItemKind::Action),
            append(1, 2),
        ]);
    }

    #[test]
    #[should_panic(expected = "accepts only grouping nodes")]
    fn menubar_rejects_non_group_root() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Action),
            label(1, "Save"),
            TxOp::MenubarAppend { window: DEFAULT_WINDOW, item: MenuItemId(1) },
        ]);
    }

    #[test]
    #[should_panic(expected = "editable text controls keep their native")]
    fn context_attach_rejects_entry() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Entry },
            item(1, MenuItemKind::Action),
            label(1, "Rename"),
            TxOp::ContextAttach { widget: WidgetId(1), item: MenuItemId(1) },
        ]);
    }

    #[test]
    #[should_panic(expected = "context menu root cannot be a radio_option")]
    fn context_root_rejects_radio_option() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Label },
            item(1, MenuItemKind::RadioOption),
            TxOp::ContextAttach { widget: WidgetId(1), item: MenuItemId(1) },
        ]);
    }

    #[test]
    #[should_panic(expected = "exceeds the depth cap")]
    fn depth_cap_rejects_third_grouping_level() {
        // bar > menu > menu > menu — three grouping nodes.
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Menu),
            item(2, MenuItemKind::Menu),
            item(3, MenuItemKind::Menu),
            append(2, 3),
            append(1, 2),
            TxOp::MenubarAppend { window: DEFAULT_WINDOW, item: MenuItemId(1) },
        ]);
    }

    #[test]
    #[should_panic(expected = "already has a parent or anchor")]
    fn item_rejects_second_parent() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Menu),
            item(2, MenuItemKind::Menu),
            item(3, MenuItemKind::Action),
            append(1, 3),
            append(2, 3),
        ]);
    }

    #[test]
    #[should_panic(expected = "duplicate shortcut")]
    fn duplicate_shortcut_in_window_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Menu),
            item(2, MenuItemKind::Action),
            label(2, "Save"),
            TxOp::SetMenuProp {
                item: MenuItemId(2),
                prop: MenuProp::Shortcut,
                value: PropValue::Const(v("primary+s")),
            },
            item(3, MenuItemKind::Action),
            label(3, "Send"),
            TxOp::SetMenuProp {
                item: MenuItemId(3),
                prop: MenuProp::Shortcut,
                value: PropValue::Const(v("primary+s")),
            },
            append(1, 2),
            append(1, 3),
            TxOp::MenubarAppend { window: DEFAULT_WINDOW, item: MenuItemId(1) },
        ]);
    }

    #[test]
    #[should_panic(expected = "is reserved")]
    fn reserved_shortcut_primary_q_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Action),
            TxOp::SetMenuProp {
                item: MenuItemId(1),
                prop: MenuProp::Shortcut,
                value: PropValue::Const(v("primary+q")),
            },
        ]);
    }

    #[test]
    #[should_panic(expected = "is reserved")]
    fn reserved_shortcut_alt_f4_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Action),
            TxOp::SetMenuProp {
                item: MenuItemId(1),
                prop: MenuProp::Shortcut,
                value: PropValue::Const(v("alt+f4")),
            },
        ]);
    }

    #[test]
    #[should_panic(expected = "not in canonical order")]
    fn non_canonical_shortcut_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Action),
            TxOp::SetMenuProp {
                item: MenuItemId(1),
                prop: MenuProp::Shortcut,
                value: PropValue::Const(v("shift+primary+s")),
            },
        ]);
    }

    #[test]
    #[should_panic(expected = "universal dismiss key")]
    fn escape_shortcut_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Action),
            TxOp::SetMenuProp {
                item: MenuItemId(1),
                prop: MenuProp::Shortcut,
                value: PropValue::Const(v("primary+escape")),
            },
        ]);
    }

    #[test]
    #[should_panic(expected = "punctuation key needs primary or alt")]
    fn bare_alnum_shortcut_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Action),
            TxOp::SetMenuProp {
                item: MenuItemId(1),
                prop: MenuProp::Shortcut,
                value: PropValue::Const(v("s")),
            },
        ]);
    }

    #[test]
    #[should_panic(expected = "shift is valid only with primary or alt")]
    fn shift_only_named_shortcut_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Action),
            TxOp::SetMenuProp {
                item: MenuItemId(1),
                prop: MenuProp::Shortcut,
                value: PropValue::Const(v("shift+enter")),
            },
        ]);
    }

    #[test]
    #[should_panic(expected = "has no property")]
    fn shortcut_on_grouping_node_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Menu),
            TxOp::SetMenuProp {
                item: MenuItemId(1),
                prop: MenuProp::Shortcut,
                value: PropValue::Const(v("primary+s")),
            },
        ]);
    }

    /// A shortcut rides any LEAF command: a checkable item takes a
    /// chord as readily as a plain one ("Show Sidebar" wants both its
    /// checkmark and its key), and so does one option of a group
    /// (the view-mode 1/2/3 pattern).
    #[test]
    fn shortcut_rides_toggle_and_radio_option() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Menu),
            label(1, "View"),
            item(2, MenuItemKind::Toggle),
            label(2, "Details"),
            sc(2, "primary+backslash"),
            append(1, 2),
            item(3, MenuItemKind::RadioGroup),
            label(3, "Sort"),
            item(4, MenuItemKind::RadioOption),
            label(4, "Name"),
            sc(4, "primary+1"),
            item(5, MenuItemKind::RadioOption),
            label(5, "Date"),
            sc(5, "primary+2"),
            append(3, 4),
            append(3, 5),
            append(1, 3),
            TxOp::MenubarAppend { window: DEFAULT_WINDOW, item: MenuItemId(1) },
        ]);
    }

    /// The duplicate-within-a-window rule spans every leaf kind, not
    /// just plain commands.
    #[test]
    #[should_panic(expected = "duplicate shortcut")]
    fn duplicate_shortcut_across_leaf_kinds_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Menu),
            label(1, "View"),
            item(2, MenuItemKind::Action),
            label(2, "Save"),
            sc(2, "primary+comma"),
            item(3, MenuItemKind::Toggle),
            label(3, "Details"),
            sc(3, "primary+comma"),
            append(1, 2),
            append(1, 3),
            TxOp::MenubarAppend { window: DEFAULT_WINDOW, item: MenuItemId(1) },
        ]);
    }

    /// The settings role: accepted on a window-anchored action, and it
    /// is the one value the closed vocabulary holds.
    #[test]
    fn settings_role_accepted() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Menu),
            label(1, "App"),
            item(2, MenuItemKind::Action),
            label(2, "Settings…"),
            role(2, "settings"),
            sc(2, "primary+comma"),
            append(1, 2),
            TxOp::MenubarAppend { window: DEFAULT_WINDOW, item: MenuItemId(1) },
        ]);
    }

    #[test]
    #[should_panic(expected = "closed role vocabulary")]
    fn unknown_role_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![item(1, MenuItemKind::Action), role(1, "about")]);
    }

    /// The menu side of the symbol wall — the SAME function as the
    /// section side, which is the point: one vocabulary, one sentence,
    /// two surfaces that cannot answer differently.
    #[test]
    #[should_panic(expected = "21 is not a symbol")]
    fn menu_symbol_rejects_a_value_outside_the_vocabulary() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Action),
            TxOp::SetMenuProp {
                item: MenuItemId(1),
                prop: MenuProp::Symbol,
                value: PropValue::Const(Value::I64(21)),
            },
        ]);
    }

    /// A separator has no label and no icon, and it has no symbol
    /// either — the `icon` scoping, restated by the same clause.
    #[test]
    #[should_panic(expected = "has no property")]
    fn symbol_on_a_separator_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Separator),
            TxOp::SetMenuProp {
                item: MenuItemId(1),
                prop: MenuProp::Symbol,
                value: PropValue::Const(Value::I64(crate::wire::SYMBOL_COPY.into())),
            },
        ]);
    }

    /// Const-only, like `icon` beside it: a symbol names a fixed
    /// concept, so a per-frame signal binding has no reading.
    #[test]
    #[should_panic(expected = "is not signal-bindable")]
    fn symbol_signal_bind_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateSignal { id: SignalId(1), initial: Value::I64(1) },
            item(1, MenuItemKind::Action),
            TxOp::SetMenuProp {
                item: MenuItemId(1),
                prop: MenuProp::Symbol,
                value: PropValue::Signal(SignalId(1)),
            },
        ]);
    }

    /// The accept direction on the menu slot, on every kind that takes
    /// one: a wall that refused everything would pass all three
    /// refusals above.
    #[test]
    fn every_symbol_is_accepted_on_every_menu_kind_that_takes_one() {
        for kind in [
            MenuItemKind::Menu,
            MenuItemKind::Action,
            MenuItemKind::Toggle,
            MenuItemKind::RadioGroup,
            MenuItemKind::RadioOption,
        ] {
            for (id, _name) in crate::wire::SYMBOLS {
                let mut scene = Scene::new();
                scene.apply(vec![
                    item(1, kind),
                    TxOp::SetMenuProp {
                        item: MenuItemId(1),
                        prop: MenuProp::Symbol,
                        value: PropValue::Const(Value::I64(i64::from(*id))),
                    },
                ]);
            }
        }
    }

    #[test]
    #[should_panic(expected = "has no property")]
    fn role_on_non_action_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![item(1, MenuItemKind::Toggle), role(1, "settings")]);
    }

    /// One standard command per role: the host that relocates it has
    /// exactly one slot to put it in.
    #[test]
    #[should_panic(expected = "already claimed")]
    fn duplicate_settings_role_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Action),
            role(1, "settings"),
            item(2, MenuItemKind::Action),
            role(2, "settings"),
        ]);
    }

    /// Re-setting the same role on the same item is idle, not a clash
    /// (the shortcut precedent).
    #[test]
    fn resetting_same_role_on_same_item_is_idle() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Action),
            role(1, "settings"),
            role(1, "settings"),
        ]);
    }

    #[test]
    #[should_panic(expected = "names a standard command")]
    fn role_on_context_item_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Label },
            item(1, MenuItemKind::Action),
            label(1, "Settings…"),
            TxOp::ContextAttach { widget: WidgetId(1), item: MenuItemId(1) },
            role(1, "settings"),
        ]);
    }

    /// Direction two, the context-attach scan: a role-carrying subtree
    /// cannot be attached to a context anchor either.
    #[test]
    #[should_panic(expected = "names a standard command")]
    fn context_attach_of_subtree_with_role_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Label },
            item(1, MenuItemKind::Menu),
            label(1, "Stuff"),
            item(2, MenuItemKind::Action),
            label(2, "Settings…"),
            role(2, "settings"),
            append(1, 2),
            TxOp::ContextAttach { widget: WidgetId(1), item: MenuItemId(1) },
        ]);
    }

    #[test]
    #[should_panic(expected = "has no property")]
    fn primary_on_non_action_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Menu),
            TxOp::SetMenuProp {
                item: MenuItemId(1),
                prop: MenuProp::Primary,
                value: PropValue::Const(Value::Bool(true)),
            },
        ]);
    }

    #[test]
    #[should_panic(expected = "has no property")]
    fn checked_on_non_toggle_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Action),
            TxOp::SetMenuProp {
                item: MenuItemId(1),
                prop: MenuProp::Checked,
                value: PropValue::Const(Value::Bool(true)),
            },
        ]);
    }

    #[test]
    #[should_panic(expected = "0-based option index")]
    fn radio_value_non_integral_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::RadioGroup),
            item(2, MenuItemKind::RadioOption),
            item(3, MenuItemKind::RadioOption),
            append(1, 2),
            append(1, 3),
            TxOp::SetMenuProp {
                item: MenuItemId(1),
                prop: MenuProp::Value,
                value: PropValue::Const(Value::F64(0.5)),
            },
        ]);
    }

    #[test]
    #[should_panic(expected = "out of range")]
    fn radio_value_out_of_range_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::RadioGroup),
            item(2, MenuItemKind::RadioOption),
            append(1, 2),
            TxOp::SetMenuProp {
                item: MenuItemId(1),
                prop: MenuProp::Value,
                value: PropValue::Const(Value::F64(3.0)),
            },
        ]);
    }

    #[test]
    #[should_panic(expected = "is not signal-bindable")]
    fn primary_signal_bind_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateSignal { id: SignalId(1), initial: Value::Bool(true) },
            item(1, MenuItemKind::Action),
            TxOp::SetMenuProp {
                item: MenuItemId(1),
                prop: MenuProp::Primary,
                value: PropValue::Signal(SignalId(1)),
            },
        ]);
    }

    #[test]
    #[should_panic(expected = "context_attach_node names a template node")]
    fn context_attach_node_outside_scope_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Action),
            label(1, "Remove"),
            TxOp::ContextAttachNode { node: TemplateNodeId(5), item: MenuItemId(1) },
        ]);
    }

    #[test]
    #[should_panic(expected = "menu item id 0")]
    fn menu_item_id_zero_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![item(0, MenuItemKind::Menu)]);
    }

    /// Props mutate freely (DESIGN.md, Menus): re-setting a bar-anchored
    /// action's shortcut to its OWN spelling replaces it — never a
    /// duplicate against itself.
    #[test]
    fn shortcut_reset_same_spelling_on_bar_action_ok() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Menu),
            item(2, MenuItemKind::Action),
            sc(2, "primary+s"),
            append(1, 2),
            TxOp::MenubarAppend { window: DEFAULT_WINDOW, item: MenuItemId(1) },
            sc(2, "primary+s"),
        ]);
        assert!(scene.window_shortcuts[&DEFAULT_WINDOW].contains("primary+s"));
    }

    /// Re-setting to a NEW spelling deregisters the old chord from the
    /// window's registry, so a later item may legitimately claim it.
    #[test]
    fn shortcut_reset_frees_old_chord_for_reuse() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Menu),
            item(2, MenuItemKind::Action),
            sc(2, "primary+s"),
            append(1, 2),
            TxOp::MenubarAppend { window: DEFAULT_WINDOW, item: MenuItemId(1) },
            sc(2, "primary+e"),
            item(3, MenuItemKind::Action),
            sc(3, "primary+s"),
            append(1, 3),
        ]);
        let set = &scene.window_shortcuts[&DEFAULT_WINDOW];
        assert!(set.contains("primary+e"), "the new spelling registers");
        assert!(set.contains("primary+s"), "the freed chord is claimable");
    }

    /// A re-set onto a chord ANOTHER item holds rejects via the
    /// window_shortcuts lookup — the set-after-anchor dup path.
    #[test]
    #[should_panic(expected = "duplicate shortcut")]
    fn shortcut_set_after_anchor_duplicate_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Menu),
            item(2, MenuItemKind::Action),
            sc(2, "primary+s"),
            item(3, MenuItemKind::Action),
            append(1, 2),
            append(1, 3),
            TxOp::MenubarAppend { window: DEFAULT_WINDOW, item: MenuItemId(1) },
            sc(3, "primary+s"),
        ]);
    }

    /// The rejected re-set mutates NOTHING: both prior registrations
    /// survive and the item keeps its old spelling.
    #[test]
    fn shortcut_reset_reject_leaves_registry_intact() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Menu),
            item(2, MenuItemKind::Action),
            sc(2, "primary+s"),
            item(3, MenuItemKind::Action),
            sc(3, "primary+e"),
            append(1, 2),
            append(1, 3),
            TxOp::MenubarAppend { window: DEFAULT_WINDOW, item: MenuItemId(1) },
        ]);
        let caught = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            scene.apply(vec![sc(3, "primary+s")]);
        }));
        assert!(caught.is_err(), "a re-set onto another item's chord must reject");
        let set = &scene.window_shortcuts[&DEFAULT_WINDOW];
        assert!(set.contains("primary+s") && set.contains("primary+e"));
        assert_eq!(
            scene.menu_items[&MenuItemId(3)].shortcut.as_deref(),
            Some("primary+e")
        );
    }

    /// The cross-tree half of the window dup-check: a second top-level
    /// tree must dup-check against the window's REGISTRY, not just
    /// within its own subtree's `seen` set.
    #[test]
    #[should_panic(expected = "duplicate shortcut")]
    fn duplicate_shortcut_across_bar_trees_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Menu),
            item(2, MenuItemKind::Action),
            sc(2, "primary+s"),
            append(1, 2),
            TxOp::MenubarAppend { window: DEFAULT_WINDOW, item: MenuItemId(1) },
            item(3, MenuItemKind::Menu),
            item(4, MenuItemKind::Action),
            sc(4, "primary+s"),
            append(3, 4),
            TxOp::MenubarAppend { window: DEFAULT_WINDOW, item: MenuItemId(3) },
        ]);
    }

    /// The post-anchor append lookup: a free subtree carrying a chord
    /// the window already registered cannot join the catalog.
    #[test]
    #[should_panic(expected = "duplicate shortcut")]
    fn duplicate_shortcut_on_append_into_anchored_catalog_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Menu),
            item(2, MenuItemKind::Action),
            sc(2, "primary+s"),
            append(1, 2),
            TxOp::MenubarAppend { window: DEFAULT_WINDOW, item: MenuItemId(1) },
            item(3, MenuItemKind::Action),
            sc(3, "primary+s"),
            append(1, 3),
        ]);
    }

    /// `shortcut` on anything but a menubar-anchored action, direction
    /// one: a set on an already context-anchored action.
    #[test]
    #[should_panic(expected = "needs a window catalog home")]
    fn shortcut_on_context_anchored_action_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Label },
            item(1, MenuItemKind::Action),
            label(1, "Rename"),
            TxOp::ContextAttach { widget: WidgetId(1), item: MenuItemId(1) },
            sc(1, "primary+r"),
        ]);
    }

    /// Direction two: attaching a subtree that already carries a
    /// shortcut to a context anchor.
    #[test]
    #[should_panic(expected = "needs a window catalog home")]
    fn context_attach_of_subtree_with_shortcut_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Label },
            item(1, MenuItemKind::Menu),
            label(1, "Stuff"),
            item(2, MenuItemKind::Action),
            sc(2, "primary+r"),
            append(1, 2),
            TxOp::ContextAttach { widget: WidgetId(1), item: MenuItemId(1) },
        ]);
    }

    /// Direction two, append flavor: a shortcut-carrying free item
    /// appended INTO an already context-anchored tree.
    #[test]
    #[should_panic(expected = "needs a window catalog home")]
    fn append_shortcut_into_context_anchor_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Label },
            item(1, MenuItemKind::Menu),
            label(1, "Stuff"),
            TxOp::ContextAttach { widget: WidgetId(1), item: MenuItemId(1) },
            item(2, MenuItemKind::Action),
            sc(2, "primary+r"),
            append(1, 2),
        ]);
    }

    /// The live-widget editable-text rejection covers BOTH kinds.
    #[test]
    #[should_panic(expected = "editable text controls keep their native")]
    fn context_attach_rejects_textarea() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Textarea },
            item(1, MenuItemKind::Action),
            label(1, "Rename"),
            TxOp::ContextAttach { widget: WidgetId(1), item: MenuItemId(1) },
        ]);
    }

    /// The template-declare arm is its own code path and message; it
    /// rejects entry ...
    #[test]
    #[should_panic(expected = "context_attach_node rejected on")]
    fn context_attach_node_rejects_entry() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Action),
            label(1, "Clear"),
            TxOp::CreateCollection { id: CollectionId(1), variants: vec![vec![ValueType::Str]] },
            TxOp::CreateFor { id: 3, collection: CollectionId(1) },
            TxOp::CreateWidget { id: WidgetId(30), kind: WidgetKind::Entry },
            TxOp::ContextAttachNode { node: TemplateNodeId(30), item: MenuItemId(1) },
        ]);
    }

    /// ... and textarea alike.
    #[test]
    #[should_panic(expected = "context_attach_node rejected on")]
    fn context_attach_node_rejects_textarea() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Action),
            label(1, "Clear"),
            TxOp::CreateCollection { id: CollectionId(1), variants: vec![vec![ValueType::Str]] },
            TxOp::CreateFor { id: 3, collection: CollectionId(1) },
            TxOp::CreateWidget { id: WidgetId(30), kind: WidgetKind::Textarea },
            TxOp::ContextAttachNode { node: TemplateNodeId(30), item: MenuItemId(1) },
        ]);
    }

    // --- Text ranges (docs/ranges-plan.md, scratchpad/ranges-units.md) ---

    /// The five hazard strings the units arm measured, so every test
    /// below argues over the same material.
    const EMOJI: &str = "ab\u{1f600}cd"; // 8 bytes, 6 UTF-16, 5 scalars
    const COMBINING: &str = "ae\u{301}b"; // e + COMBINING ACUTE
    const FAMILY: &str = "ab\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}\u{200d}\u{1f466}cd";

    /// A live textarea holding `text`.
    fn editor(text: &str) -> Transaction {
        vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Textarea },
            TxOp::SetProperty {
                widget: WidgetId(1),
                prop: Prop::Text,
                value: PropValue::Const(Value::Str(text.to_owned())),
            },
            TxOp::Mount { window: DEFAULT_WINDOW, root: WidgetId(1) },
        ]
    }

    fn highlight(ranges: &[(u64, u64)]) -> TxOp {
        TxOp::HighlightRanges {
            widget: WidgetId(1),
            ranges: ranges.iter().map(|(a, b)| TextRange::new(*a, *b)).collect(),
        }
    }

    fn lowered(ops: &[ApplyOp]) -> Vec<(u64, u64)> {
        ops.iter()
            .find_map(|op| match op {
                ApplyOp::HighlightRanges { ranges, .. } => {
                    Some(ranges.iter().map(|r| (r.start, r.stop)).collect())
                }
                _ => None,
            })
            .expect("a highlight was lowered")
    }

    /// THE CONVERSION TABLE ITSELF, pinned against the units arm's
    /// measurements — both units, on every hazard string, on every
    /// platform. `native_offset` picks one of these at build time and a
    /// test of the picked one alone would say nothing about the arm the
    /// linux lane runs.
    #[test]
    fn the_two_offset_conversions_match_the_measured_table() {
        // ab😀cd: the emoji is bytes 2..6, UTF-16 units 2..4, scalars 2..3.
        assert_eq!(super::native_offset_utf16(EMOJI, 2), 2);
        assert_eq!(super::native_offset_utf16(EMOJI, 6), 4);
        assert_eq!(super::native_offset_utf16(EMOJI, 8), 6);
        assert_eq!(super::native_offset_chars(EMOJI, 2), 2);
        assert_eq!(super::native_offset_chars(EMOJI, 6), 3);
        assert_eq!(super::native_offset_chars(EMOJI, 8), 5);
        // The ZWJ family is the discriminator: 25 bytes, 11 UTF-16 units,
        // 7 scalars for ONE visible glyph. An off-by-one CJK would hide.
        // 29 bytes end to end: `ab` + the 25-byte family + `cd`, so
        // `cd` starts at byte 27 and at UTF-16 unit 13.
        assert_eq!(FAMILY.len(), 29);
        assert_eq!(super::native_offset_utf16(FAMILY, 2), 2);
        assert_eq!(super::native_offset_utf16(FAMILY, 27), 13);
        assert_eq!(super::native_offset_chars(FAMILY, 27), 9);
        // The combining sequence: every unit but graphemes keeps them
        // apart, which is why an offset between them is ACCEPTED.
        assert_eq!(super::native_offset_utf16(COMBINING, 2), 2);
        assert_eq!(super::native_offset_utf16(COMBINING, 4), 3);
        assert_eq!(super::native_offset_chars(COMBINING, 4), 3);
        // And the benign case, stated so the safe intuition is on record.
        assert_eq!(super::native_offset_utf16("a\u{65e5}\u{672c}\u{8a9e}b", 7), 3);
        assert_eq!(super::native_offset_chars("a\u{65e5}\u{672c}\u{8a9e}b", 7), 3);
    }

    /// The one this build actually lowers with, so a wrong `cfg!` arm
    /// fails here rather than on a lane.
    #[test]
    fn the_build_lowers_in_its_own_backends_unit() {
        let want = if cfg!(target_os = "linux") { 3 } else { 4 };
        assert_eq!(super::native_offset(EMOJI, 6), want);
    }

    #[test]
    fn a_declared_set_lowers_converted() {
        let mut scene = Scene::new();
        scene.apply(editor(EMOJI));
        // The emoji alone, in bytes.
        let ops = scene.apply(vec![highlight(&[(2, 6)])]);
        let want = if cfg!(target_os = "linux") { (2, 3) } else { (2, 4) };
        assert_eq!(lowered(&ops), vec![want]);
    }

    #[test]
    fn an_empty_set_is_the_clear_and_still_lowers() {
        let mut scene = Scene::new();
        scene.apply(editor("hello"));
        let ops = scene.apply(vec![highlight(&[])]);
        assert_eq!(lowered(&ops), Vec::<(u64, u64)>::new());
    }

    /// ACCEPTANCE, and it matters as much as the refusals: a guard that
    /// refused these would make the framework unable to express a
    /// correct range (scratchpad/ranges-units.md §8.2).
    #[test]
    fn a_grapheme_split_is_accepted_because_the_platforms_disagree() {
        let mut scene = Scene::new();
        scene.apply(editor(COMBINING));
        // Between `e` and its combining acute — one grapheme, two code
        // points. java.text.BreakIterator, .NET StringInfo and Swift
        // give three different answers about this cluster; the core
        // gives none, on purpose.
        let ops = scene.apply(vec![highlight(&[(1, 2)])]);
        assert_eq!(lowered(&ops).len(), 1);
        // And the whole ZWJ family, which is the same carve-out at size.
        let mut scene = Scene::new();
        scene.apply(editor(FAMILY));
        let ops = scene.apply(vec![highlight(&[(2, 27)])]);
        assert_eq!(lowered(&ops).len(), 1);
    }

    #[test]
    fn a_caret_is_a_legal_selection() {
        let mut scene = Scene::new();
        scene.apply(editor("hello"));
        let ops = scene.apply(vec![TxOp::SelectRange {
            widget: WidgetId(1),
            range: TextRange::new(3, 3),
        }]);
        assert!(ops.iter().any(|op| matches!(
            op,
            ApplyOp::SelectRange { range: NativeRange { start: 3, stop: 3 }, .. }
        )));
    }

    #[test]
    #[should_panic(expected = "start 12 is after end 4")]
    fn a_backwards_range_is_refused() {
        let mut scene = Scene::new();
        scene.apply(editor("hello world, and so on"));
        scene.apply(vec![highlight(&[(12, 4)])]);
    }

    /// THE CLAUSE THAT IS NOT POLITENESS: an out-of-range attribute on
    /// macOS is an NSRangeException and the process dies with exit 134
    /// (scratchpad/ranges-units.md §3, measured).
    #[test]
    #[should_panic(expected = "end 40 is past the end of the text (5 bytes)")]
    fn an_offset_past_the_end_is_refused() {
        let mut scene = Scene::new();
        scene.apply(editor("hello"));
        scene.apply(vec![highlight(&[(0, 40)])]);
    }

    #[test]
    #[should_panic(expected = "byte offset 3 is not a character boundary; it is inside")]
    fn a_start_inside_a_character_is_refused() {
        let mut scene = Scene::new();
        scene.apply(editor(EMOJI));
        scene.apply(vec![highlight(&[(3, 6)])]);
    }

    /// The END clause has its own test because AppKit treats the two
    /// endpoints DIFFERENTLY — it snaps a bad start and keeps a bad end,
    /// whose selected text then copies as U+FFFD (measured). One test
    /// over both endpoints would pass with the end clause deleted.
    #[test]
    #[should_panic(expected = "byte offset 5 is not a character boundary; it is inside")]
    fn an_end_inside_a_character_is_refused() {
        let mut scene = Scene::new();
        scene.apply(editor(EMOJI));
        scene.apply(vec![highlight(&[(2, 5)])]);
    }

    /// Every op of the family crosses the same chokepoint — a rule that
    /// held for one of three would be a rule nobody could rely on.
    #[test]
    #[should_panic(expected = "select_range on WidgetId(1): end 99 is past the end")]
    fn select_range_is_validated_too() {
        let mut scene = Scene::new();
        scene.apply(editor("hello"));
        scene.apply(vec![TxOp::SelectRange {
            widget: WidgetId(1),
            range: TextRange::new(0, 99),
        }]);
    }

    #[test]
    #[should_panic(expected = "reveal_range on WidgetId(1): end 99 is past the end")]
    fn reveal_range_is_validated_too() {
        let mut scene = Scene::new();
        scene.apply(editor("hello"));
        scene.apply(vec![TxOp::RevealRange {
            widget: WidgetId(1),
            range: TextRange::new(0, 99),
        }]);
    }

    /// D1's deferral, structural. The entry's per-platform reasons are
    /// recorded in docs/deferred.md; this is what makes them true of the
    /// running code rather than of a document.
    #[test]
    #[should_panic(expected = "text ranges are a TEXTAREA surface")]
    fn ranges_refuse_an_entry() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Entry },
            TxOp::Mount { window: DEFAULT_WINDOW, root: WidgetId(1) },
        ]);
        scene.apply(vec![highlight(&[(0, 0)])]);
    }

    /// THE SAME-BATCH ORDERING HAZARD. `absorb_text_writes` runs at the
    /// END of a batch, so `field_text` still holds the old text while
    /// the batch is applying. A range declared over text this same
    /// transaction wrote must be read against the NEW text — otherwise
    /// the obvious app spelling validates against the wrong document,
    /// and on macOS that is not a wrong colour, it is exit 134.
    #[test]
    fn a_range_reads_the_text_this_batch_wrote() {
        let mut scene = Scene::new();
        scene.apply(editor("short"));
        let ops = scene.apply(vec![
            TxOp::SetProperty {
                widget: WidgetId(1),
                prop: Prop::Text,
                value: PropValue::Const(Value::Str("a much longer document".to_owned())),
            },
            highlight(&[(7, 13)]),
        ]);
        assert_eq!(lowered(&ops), vec![(7, 13)]);
    }

    /// The same rule the other way: without the batch-local read this
    /// would be accepted against the LONG text that is no longer there.
    #[test]
    #[should_panic(expected = "past the end of the text (5 bytes)")]
    fn a_range_over_text_this_batch_shortened_is_refused() {
        let mut scene = Scene::new();
        scene.apply(editor("a much longer document"));
        scene.apply(vec![
            TxOp::SetProperty {
                widget: WidgetId(1),
                prop: Prop::Text,
                value: PropValue::Const(Value::Str("short".to_owned())),
            },
            highlight(&[(7, 13)]),
        ]);
    }

    /// A `clear` in the same batch empties the text for the same reason.
    #[test]
    #[should_panic(expected = "past the end of the text (0 bytes)")]
    fn a_range_after_a_clear_in_the_same_batch_is_refused() {
        let mut scene = Scene::new();
        scene.apply(editor("hello"));
        scene.apply(vec![
            TxOp::WidgetCommand { widget: WidgetId(1), command: CommandKind::Clear },
            highlight(&[(0, 5)]),
        ]);
    }

    /// D2's other half, in the core: what the user typed is what the
    /// next declaration is measured against. The paint-time half — a
    /// declared set is dropped the moment the widget's text moves — is
    /// the backend's, and the ranges scene watches it there.
    #[test]
    fn a_user_edit_moves_the_text_a_range_is_measured_against() {
        let mut scene = Scene::new();
        scene.apply(editor("hello"));
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(1), "hello world", true);
        let ops = scene.apply(vec![highlight(&[(6, 11)])]);
        assert_eq!(lowered(&ops), vec![(6, 11)]);
    }

    /// All three ride in an undo group and none of them comes back —
    /// A2's rule, stated once for the whole family so no app author has
    /// to remember which of the three a group admits.
    #[test]
    fn the_three_range_ops_are_pure_effects_in_a_group() {
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(9), kind: WidgetKind::Textarea },
            TxOp::SetProperty {
                widget: WidgetId(9),
                prop: Prop::Text,
                value: PropValue::Const(Value::Str("hello".to_owned())),
            },
            // Into undo_scene's mounted column. A later transaction may
            // add to a tree the app already mounted; what it may not do
            // is leave the widget hanging, which is what this fixture
            // used to do because nothing was looking.
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(9) },
        ]);
        let ops = scene.apply(vec![
            group("find"),
            insert(1, vec![], "a", "Alpha"),
            TxOp::HighlightRanges {
                widget: WidgetId(9),
                ranges: vec![TextRange::new(0, 5)],
            },
            TxOp::SelectRange { widget: WidgetId(9), range: TextRange::new(0, 5) },
            TxOp::RevealRange { widget: WidgetId(9), range: TextRange::new(0, 5) },
        ]);
        assert_eq!(lowered(&ops), vec![(0, 5)]);
        let (ops, _) = scene.undo(DEFAULT_WINDOW).expect("one group to undo");
        assert!(
            !ops.iter().any(|op| matches!(
                op,
                ApplyOp::HighlightRanges { .. }
                    | ApplyOp::SelectRange { .. }
                    | ApplyOp::RevealRange { .. }
            )),
            "a pure effect is permitted, never replayed backwards"
        );
    }

    /// Shift-only alphanumeric through the scene root (the grammar
    /// table's direct assert is not the root path).
    #[test]
    #[should_panic(expected = "punctuation key needs primary or alt")]
    fn shift_only_alnum_shortcut_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![item(1, MenuItemKind::Action), sc(1, "shift+s")]);
    }

    /// Unmodified escape through the scene root.
    #[test]
    #[should_panic(expected = "universal dismiss key")]
    fn unmodified_escape_shortcut_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![item(1, MenuItemKind::Action), sc(1, "escape")]);
    }

    #[test]
    #[should_panic(expected = "cannot be its own parent")]
    fn menu_self_append_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![item(1, MenuItemKind::Menu), append(1, 1)]);
    }

    #[test]
    #[should_panic(expected = "would create a cycle")]
    fn menu_append_cycle_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Menu),
            item(2, MenuItemKind::Menu),
            append(1, 2),
            append(2, 1),
        ]);
    }

    /// Double anchoring, bar+bar: one item cannot be the root of two
    /// windows' catalogs (the anchor half of assert_menu_root_free).
    #[test]
    #[should_panic(expected = "already has a parent or anchor")]
    fn menubar_append_to_two_windows_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWindow { window: WindowId(2) },
            item(1, MenuItemKind::Menu),
            label(1, "File"),
            TxOp::MenubarAppend { window: DEFAULT_WINDOW, item: MenuItemId(1) },
            TxOp::MenubarAppend { window: WindowId(2), item: MenuItemId(1) },
        ]);
    }

    /// Double anchoring, bar-then-context.
    #[test]
    #[should_panic(expected = "already has a parent or anchor")]
    fn menubar_then_context_anchor_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Label },
            item(1, MenuItemKind::Menu),
            label(1, "File"),
            TxOp::MenubarAppend { window: DEFAULT_WINDOW, item: MenuItemId(1) },
            TxOp::ContextAttach { widget: WidgetId(1), item: MenuItemId(1) },
        ]);
    }

    /// Double anchoring, context-then-context: no shared nodes.
    #[test]
    #[should_panic(expected = "already has a parent or anchor")]
    fn context_then_context_anchor_rejected() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Label },
            TxOp::CreateWidget { id: WidgetId(2), kind: WidgetKind::Label },
            item(1, MenuItemKind::Action),
            label(1, "Rename"),
            TxOp::ContextAttach { widget: WidgetId(1), item: MenuItemId(1) },
            TxOp::ContextAttach { widget: WidgetId(2), item: MenuItemId(1) },
        ]);
    }

    /// The depth cap holds on the append-into-anchored path, not just
    /// at anchor time.
    #[test]
    #[should_panic(expected = "exceeds the depth cap")]
    fn depth_cap_rejected_on_append_into_anchored_bar() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Menu),
            item(2, MenuItemKind::Menu),
            item(3, MenuItemKind::Menu),
            append(2, 3),
            TxOp::MenubarAppend { window: DEFAULT_WINDOW, item: MenuItemId(1) },
            append(1, 2),
        ]);
    }

    /// A rejected append into an anchored catalog leaves NO trace: the
    /// edge is not linked, the registry is untouched, and the subtree
    /// stays a free root a legal append may still take (the probe that
    /// exposed the pre-fix mutate-before-validate divergence).
    #[test]
    fn rejected_append_leaves_tree_and_registry_untouched() {
        let mut scene = Scene::new();
        scene.apply(vec![
            item(1, MenuItemKind::Menu),
            item(2, MenuItemKind::Menu),
            item(3, MenuItemKind::Menu),
            append(2, 3),
            TxOp::MenubarAppend { window: DEFAULT_WINDOW, item: MenuItemId(1) },
        ]);
        let caught = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            scene.apply(vec![append(1, 2)]);
        }));
        assert!(caught.is_err(), "the over-deep append must reject");
        assert!(scene.menu_items[&MenuItemId(2)].parent.is_none());
        assert!(!scene.menu_items[&MenuItemId(1)]
            .children
            .contains(&MenuItemId(2)));
        // Still a free root: an unanchored parent takes the subtree.
        scene.apply(vec![item(4, MenuItemKind::Menu), append(4, 2)]);
    }

    /// A destroyed window takes its command catalog with it: the same
    /// (recreatable) window id starts with a free chord registry, and
    /// the old trees revert to free roots.
    #[test]
    fn destroyed_window_frees_its_catalog() {
        let mut scene = Scene::new();
        scene.apply(vec![
            TxOp::CreateWindow { window: WindowId(2) },
            item(1, MenuItemKind::Menu),
            label(1, "File"),
            item(2, MenuItemKind::Action),
            sc(2, "primary+s"),
            append(1, 2),
            TxOp::MenubarAppend { window: WindowId(2), item: MenuItemId(1) },
            TxOp::DestroyWindow { window: WindowId(2) },
            TxOp::CreateWindow { window: WindowId(2) },
            item(3, MenuItemKind::Menu),
            label(3, "Edit"),
            item(4, MenuItemKind::Action),
            sc(4, "primary+s"),
            append(3, 4),
            TxOp::MenubarAppend { window: WindowId(2), item: MenuItemId(3) },
        ]);
        assert!(
            scene.menu_items[&MenuItemId(1)].anchor.is_none(),
            "the dead window's root reverts to a free root"
        );
        assert_eq!(scene.window_menus[&WindowId(2)], vec![MenuItemId(3)]);
        assert!(scene.window_shortcuts[&WindowId(2)].contains("primary+s"));
    }

    // --- Undo (docs/undo-plan.md D2-D5, A1-A3, §3) ----------------------

    /// signal 1 (Str), widget 1 column, widget 2 ENTRY, widget 3 label
    /// bound to signal 1, collection 1 rendered by For id 4 with template
    /// node 10 bound to the element's one field.
    fn undo_scene() -> Transaction {
        vec![
            TxOp::CreateSignal { id: SignalId(1), initial: v("one") },
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Column },
            TxOp::CreateWidget { id: WidgetId(2), kind: WidgetKind::Entry },
            TxOp::CreateWidget { id: WidgetId(3), kind: WidgetKind::Label },
            TxOp::SetProperty {
                widget: WidgetId(3),
                prop: Prop::Text,
                value: PropValue::Signal(SignalId(1)),
            },
            TxOp::CreateCollection { id: CollectionId(1), variants: vec![vec![ValueType::Str]] },
            TxOp::CreateFor { id: 4, collection: CollectionId(1) },
            TxOp::CreateWidget { id: WidgetId(10), kind: WidgetKind::Label },
            TxOp::SetProperty {
                widget: WidgetId(10),
                prop: Prop::Text,
                value: PropValue::Element { level: 0, field: 0 },
            },
            TxOp::TemplateEnd,
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(2) },
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(3) },
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(4) },
            TxOp::Mount { window: DEFAULT_WINDOW, root: WidgetId(1) },
        ]
    }

    fn group(label: &str) -> TxOp {
        TxOp::UndoGroup {
            window: DEFAULT_WINDOW,
            label: label.to_string(),
        }
    }

    fn keys(scene: &Scene) -> Vec<Key> {
        scene.coll_instances[&(CollectionId(1), vec![])].order.clone()
    }

    fn cleared(ops: &[ApplyOp]) -> usize {
        ops.iter()
            .filter(|op| matches!(op, ApplyOp::ClearUndo { .. }))
            .count()
    }

    /// The texts run a LIVE field's restore carries: its own id and the
    /// empty path, which is how the payload spells "a widget id" (the
    /// identity-tag vocabulary, spec.rs).
    fn live_text(id: u64, text: &str) -> crate::protocol::UndoText {
        crate::protocol::UndoText {
            id,
            path: Vec::new(),
            text: text.to_owned(),
        }
    }

    fn set_texts(ops: &[ApplyOp]) -> Vec<(u64, String)> {
        ops.iter()
            .filter_map(|op| match op {
                ApplyOp::SetProp {
                    id,
                    prop: Prop::Text,
                    value: Value::Str(text),
                } => Some((id.0, text.clone())),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn a_group_undoes_and_redoes_a_signal() {
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        let ops = scene.apply(vec![
            group("rename"),
            TxOp::WriteSignal { id: SignalId(1), value: v("two") },
        ]);
        assert_eq!(scene.signals[&SignalId(1)], v("two"));
        // A1: the group's commit tells the backend to reset the focused
        // field's native history, exactly once.
        assert_eq!(cleared(&ops), 1);

        let (ops, occ) = scene.undo(DEFAULT_WINDOW).expect("one group to undo");
        assert_eq!(scene.signals[&SignalId(1)], v("one"));
        // The label bound to the signal follows, the way it followed the
        // forward write: an inverse takes the ordinary fan-out.
        assert_eq!(set_texts(&ops), vec![(3, "one".to_string())]);
        match occ {
            Occurrence::Undone { window, label, delta } => {
                assert_eq!(window, DEFAULT_WINDOW);
                assert_eq!(label, "rename");
                assert_eq!(delta.signals, vec![(SignalId(1), v("one"))]);
                assert!(delta.entries.is_empty() && delta.texts.is_empty());
            }
            other => panic!("wanted Undone, got {other:?}"),
        }

        let (ops, occ) = scene.redo(DEFAULT_WINDOW).expect("one group to redo");
        assert_eq!(scene.signals[&SignalId(1)], v("two"));
        assert_eq!(set_texts(&ops), vec![(3, "two".to_string())]);
        match occ {
            Occurrence::Redone { label, delta, .. } => {
                assert_eq!(label, "rename");
                assert_eq!(delta.signals, vec![(SignalId(1), v("two"))]);
            }
            other => panic!("wanted Redone, got {other:?}"),
        }
        // And back to empty at both ends.
        assert!(scene.redo(DEFAULT_WINDOW).is_none());
        scene.undo(DEFAULT_WINDOW).expect("still undoable");
        assert!(scene.undo(DEFAULT_WINDOW).is_none());
    }

    #[test]
    fn a_group_undoes_and_redoes_collection_deltas() {
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        scene.apply(vec![
            insert(1, vec![], "a", "Alpha"),
            insert(1, vec![], "b", "Beta"),
        ]);
        // One group: insert a third, retitle the first, drop the second,
        // and reorder — every delta shape at once.
        scene.apply(vec![
            group("shuffle"),
            insert(1, vec![], "c", "Gamma"),
            TxOp::CollectionUpdate {
                id: CollectionId(1),
                path: vec![],
                key: v("a"),
                variant: 0,
                record: vec![v("Alpha!")],
            },
            TxOp::CollectionRemove { id: CollectionId(1), path: vec![], key: v("b") },
            TxOp::CollectionMove {
                id: CollectionId(1),
                path: vec![],
                key: v("c"),
                before: Some(v("a")),
            },
        ]);
        assert_eq!(keys(&scene), vec![Key::Str("c".into()), Key::Str("a".into())]);

        let (_, occ) = scene.undo(DEFAULT_WINDOW).expect("one group to undo");
        assert_eq!(keys(&scene), vec![Key::Str("a".into()), Key::Str("b".into())]);
        let entries = &scene.coll_instances[&(CollectionId(1), vec![])].entries;
        assert_eq!(entries[&Key::Str("a".into())], (0, vec![v("Alpha")]));
        assert_eq!(entries[&Key::Str("b".into())], (0, vec![v("Beta")]));
        assert!(!entries.contains_key(&Key::Str("c".into())));
        let Occurrence::Undone { delta, .. } = &occ else {
            panic!("wanted Undone, got {occ:?}");
        };
        // A STATEMENT OF THE RESTORED STATE: c is gone, a and b are what
        // they were, and the order names the whole instance.
        let gone: Vec<&Value> = delta
            .entries
            .iter()
            .filter(|e| e.state.is_none())
            .map(|e| &e.key)
            .collect();
        assert_eq!(gone, vec![&v("c")]);
        assert_eq!(delta.orders.len(), 1);
        assert_eq!(delta.orders[0].keys, vec![v("a"), v("b")]);

        scene.redo(DEFAULT_WINDOW).expect("one group to redo");
        assert_eq!(keys(&scene), vec![Key::Str("c".into()), Key::Str("a".into())]);
        let entries = &scene.coll_instances[&(CollectionId(1), vec![])].entries;
        assert_eq!(entries[&Key::Str("a".into())], (0, vec![v("Alpha!")]));
        assert!(!entries.contains_key(&Key::Str("b".into())));
    }

    #[test]
    fn an_update_field_undoes_to_the_field_it_replaced() {
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        scene.apply(vec![insert(1, vec![], "a", "Alpha")]);
        scene.apply(vec![
            group("retitle"),
            TxOp::CollectionUpdateField {
                id: CollectionId(1),
                path: vec![],
                key: v("a"),
                variant: 0,
                field: 0,
                value: v("Omega"),
            },
        ]);
        let (ops, _) = scene.undo(DEFAULT_WINDOW).expect("one group to undo");
        assert_eq!(
            scene.coll_instances[&(CollectionId(1), vec![])].entries[&Key::Str("a".into())],
            (0, vec![v("Alpha")])
        );
        // The stamped label follows: the element binding re-resolves the
        // way a forward write makes it.
        assert!(set_texts(&ops).iter().any(|(_, t)| t == "Alpha"));
        // No order group: nothing moved, so nothing says it did.
        let (_, occ) = (0, scene.undo(DEFAULT_WINDOW));
        assert!(occ.is_none(), "one step, one entry");
    }

    #[test]
    fn a_batch_that_writes_a_value_back_banks_nothing_about_it() {
        // The inverse is computed against the PRE-BATCH state, so an op
        // that returns a thing to where it started leaves the delta
        // silent about it rather than carrying a no-op statement.
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        scene.apply(vec![insert(1, vec![], "a", "Alpha")]);
        scene.apply(vec![
            group("churn"),
            TxOp::CollectionUpdateField {
                id: CollectionId(1),
                path: vec![],
                key: v("a"),
                variant: 0,
                field: 0,
                value: v("Beta"),
            },
            TxOp::CollectionUpdateField {
                id: CollectionId(1),
                path: vec![],
                key: v("a"),
                variant: 0,
                field: 0,
                value: v("Alpha"),
            },
        ]);
        let (_, occ) = scene.undo(DEFAULT_WINDOW).expect("the group is still a step");
        let Occurrence::Undone { delta, .. } = &occ else {
            panic!("wanted Undone");
        };
        assert!(delta.entries.is_empty(), "nothing actually changed");
    }

    #[test]
    fn focus_rides_in_a_group_and_is_not_restored() {
        // A2: a handler that appends a row and focuses it is the
        // ordinary shape, and refusing it would refuse ordinary code.
        // Undo restores state; it does not restore where you were
        // looking, so nothing about the focus comes back.
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        let ops = scene.apply(vec![
            group("add"),
            insert(1, vec![], "a", "Alpha"),
            TxOp::WidgetCommand { widget: WidgetId(2), command: CommandKind::Focus },
        ]);
        assert!(ops
            .iter()
            .any(|op| matches!(op, ApplyOp::Command { command: CommandKind::Focus, .. })));
        let (ops, _) = scene.undo(DEFAULT_WINDOW).expect("one group to undo");
        assert!(keys(&scene).is_empty());
        assert!(
            !ops.iter().any(|op| matches!(op, ApplyOp::Command { .. })),
            "a pure effect is permitted, never replayed backwards"
        );
    }

    #[test]
    #[should_panic(expected = "contains create_widget, which the core cannot invert")]
    fn a_group_refuses_an_op_it_cannot_invert() {
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        scene.apply(vec![
            group("build"),
            TxOp::CreateWidget { id: WidgetId(99), kind: WidgetKind::Label },
        ]);
    }

    #[test]
    #[should_panic(expected = "contains clear, which the core cannot invert")]
    fn a_group_refuses_clear() {
        // Clear destroys widget-owned text the core never held. It is
        // the op that looks like a pure effect and is not.
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        scene.apply(vec![
            group("wipe"),
            TxOp::WidgetCommand { widget: WidgetId(2), command: CommandKind::Clear },
        ]);
    }

    #[test]
    fn a_refused_group_leaves_the_scene_exactly_as_it_was() {
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        scene.apply(vec![insert(1, vec![], "a", "Alpha")]);
        let refused = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            scene.apply(vec![
                group("half"),
                TxOp::WriteSignal { id: SignalId(1), value: v("two") },
                insert(1, vec![], "b", "Beta"),
                TxOp::CollectionRemove { id: CollectionId(1), path: vec![], key: v("a") },
                // The op that cannot be inverted arrives LAST, after
                // three that already landed.
                TxOp::SetWindowProp {
                    window: DEFAULT_WINDOW,
                    prop: WindowProp::Title,
                    value: PropValue::Const(v("nope")),
                },
            ]);
        }));
        assert!(refused.is_err(), "the group must be refused");
        assert_eq!(scene.signals[&SignalId(1)], v("one"), "the signal is back");
        assert_eq!(keys(&scene), vec![Key::Str("a".into())], "the table is back");
        assert!(
            scene.ledgers.get(&DEFAULT_WINDOW).is_none_or(|l| l.done.is_empty()),
            "a refused group is not a step"
        );
    }

    #[test]
    #[should_panic(expected = "it must be the FIRST")]
    fn the_group_marker_must_lead_the_batch() {
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        scene.apply(vec![
            TxOp::WriteSignal { id: SignalId(1), value: v("two") },
            group("late"),
        ]);
    }

    #[test]
    #[should_panic(expected = "contains a second undo_group")]
    fn one_name_per_step() {
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        scene.apply(vec![group("first"), group("second")]);
    }

    #[test]
    #[should_panic(expected = "has an empty label")]
    fn a_group_must_be_named() {
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        scene.apply(vec![TxOp::UndoGroup {
            window: DEFAULT_WINDOW,
            label: String::new(),
        }]);
    }

    #[test]
    #[should_panic(expected = "names unknown window")]
    fn a_group_names_a_live_window() {
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        scene.apply(vec![TxOp::UndoGroup {
            window: WindowId(7),
            label: "stray".into(),
        }]);
    }

    #[test]
    fn ledgers_are_per_window() {
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        scene.apply(vec![TxOp::CreateWindow { window: WindowId(2) }]);
        scene.apply(vec![
            TxOp::UndoGroup { window: WindowId(2), label: "aux".into() },
            TxOp::WriteSignal { id: SignalId(1), value: v("two") },
        ]);
        assert!(
            scene.undo(DEFAULT_WINDOW).is_none(),
            "the primary's history is not the auxiliary's"
        );
        assert!(scene.undo(WindowId(2)).is_some());
        assert_eq!(scene.signals[&SignalId(1)], v("one"));
    }

    // --- Episode banking ------------------------------------------------

    fn episode(scene: &Scene, window: WindowId) -> Option<(&str, &str, &str, bool)> {
        match scene.ledgers.get(&window)?.done.last()? {
            LedgerEntry::Episode(ep) => {
                Some((&ep.before, &ep.after, &ep.current, ep.open))
            }
            _ => None,
        }
    }

    fn depth(scene: &Scene, window: WindowId) -> usize {
        scene.ledgers.get(&window).map(|l| l.done.len()).unwrap_or(0)
    }

    #[test]
    fn typing_banks_one_episode_however_many_keystrokes() {
        // DELTAS, NOT COPIES: the run of edits is two images and a
        // cursor, so a textarea does not double its own memory in the
        // log for every character.
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        for text in ["m", "mi", "mil", "milk"] {
            scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), text, true);
        }
        assert_eq!(depth(&scene, DEFAULT_WINDOW), 1);
        assert_eq!(episode(&scene, DEFAULT_WINDOW), Some(("", "milk", "milk", true)));
    }

    #[test]
    fn typing_back_to_the_start_of_a_run_removes_it() {
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), "m", true);
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), "", true);
        assert_eq!(depth(&scene, DEFAULT_WINDOW), 0, "a step that does nothing is not a step");
    }

    #[test]
    fn an_event_on_an_unfocused_field_closes_the_episode() {
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), "milk", true);
        assert_eq!(episode(&scene, DEFAULT_WINDOW).map(|e| e.3), Some(true));
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), "milky", false);
        assert_eq!(
            episode(&scene, DEFAULT_WINDOW),
            Some(("", "milky", "milky", false)),
            "the user is no longer there, so nothing further belongs to this run"
        );
    }

    #[test]
    fn a_programmatic_write_that_changes_the_text_closes_the_episode() {
        // D7, and A3's narrowing right beside it: an app that mirrors a
        // field into a signal and writes the SAME text back must not
        // lose the run it is mirroring.
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        scene.apply(vec![TxOp::CreateSignal { id: SignalId(2), initial: v("") }]);
        scene.apply(vec![TxOp::SetProperty {
            widget: WidgetId(2),
            prop: Prop::Text,
            value: PropValue::Signal(SignalId(2)),
        }]);
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), "milk", true);
        // The echo an app makes: same text back through the signal.
        scene.apply(vec![TxOp::WriteSignal { id: SignalId(2), value: v("milk") }]);
        assert_eq!(
            episode(&scene, DEFAULT_WINDOW).map(|e| e.3),
            Some(true),
            "A3: a write that changes nothing takes nothing away"
        );
        // A write that really changes it ends the run.
        scene.apply(vec![TxOp::WriteSignal { id: SignalId(2), value: v("bread") }]);
        assert_eq!(episode(&scene, DEFAULT_WINDOW).map(|e| e.3), Some(false));
    }

    #[test]
    fn a_group_commit_banks_the_frontier_episode_and_clears_the_native_stack() {
        // The keystone: after this, everything in the field's native
        // stack is strictly newer than everything in the ledger.
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), "milk", true);
        let ops = scene.apply(vec![
            group("add todo"),
            TxOp::WriteSignal { id: SignalId(1), value: v("two") },
        ]);
        assert_eq!(cleared(&ops), 1);
        assert_eq!(depth(&scene, DEFAULT_WINDOW), 2);
        match &scene.ledgers[&DEFAULT_WINDOW].done[0] {
            LedgerEntry::Episode(ep) => assert!(!ep.open, "banked, and closed by the clear"),
            other => panic!("wanted the episode under the group, got a {}", match other {
                LedgerEntry::Group { label, .. } => label.as_str(),
                LedgerEntry::Episode(_) => unreachable!(),
            }),
        }
    }

    /// THE SCENARIO THAT MOTIVATED THE MILESTONE (docs/undo-plan.md §2),
    /// in the shape guests/rust/undo.rs and tools/scenes/undo.steps
    /// drive it: the user types "milk", clicks add, and the handler
    /// appends a todo AND clears the field. One Cmd+Z must take back the
    /// ADD. Under two bare stacks it takes back the CLEAR — "milk"
    /// returns, the todo stays, and the user is looking at a state that
    /// never existed.
    ///
    /// THE CLEAR ACTS LIKE THE USER, which is what makes this delicate:
    /// unlike a property write it echoes, so the field really does emit
    /// its own `text_changed("")` (gtk.rs's Clear arm says so, and the
    /// entry scene's second-add round depends on it). That echo arrives
    /// at the ledger AFTER `absorb_text_writes` has already recorded the
    /// field as empty — so it describes a run from "" to "", and an
    /// entry that describes nothing must not become a step that does
    /// nothing.
    #[test]
    fn the_add_scenario_undoes_the_add_and_not_the_clear() {
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        for text in ["m", "mi", "mil", "milk"] {
            scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), text, true);
        }
        // The add handler's undoable half: what the step MEANS is the
        // insert and the status it wrote. Focus rides along as a pure
        // effect (A2) and is not restored.
        scene.apply(vec![
            group("add milk"),
            insert(1, vec![], "t1", "milk"),
            TxOp::WriteSignal { id: SignalId(1), value: v("added milk, 1 total") },
            TxOp::WidgetCommand { widget: WidgetId(2), command: CommandKind::Focus },
        ]);
        // ...and the clear in its own transaction, because Clear is
        // refused inside a group (D4) — which is the design saying the
        // same thing the fix says: emptying the field is not part of
        // the step, it is what the form does afterwards.
        scene.apply(vec![TxOp::WidgetCommand {
            widget: WidgetId(2),
            command: CommandKind::Clear,
        }]);
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), "", true);
        assert_eq!(
            depth(&scene, DEFAULT_WINDOW),
            2,
            "the ledger is the typing and the group — the clear's echo \
             describes a run from \"\" to \"\" and is not a step"
        );

        let (ops, occ) = scene.undo(DEFAULT_WINDOW).expect("one Cmd+Z, one step");
        let Occurrence::Undone { label, .. } = &occ else {
            panic!("wanted Undone");
        };
        assert_eq!(label, "add milk", "the FIRST undo is the add");
        assert!(keys(&scene).is_empty(), "the todo went back");
        assert_eq!(scene.signals[&SignalId(1)], v("one"));
        assert!(
            !set_texts(&ops).iter().any(|(id, _)| *id == 2),
            "the field is not touched: the clear was never a step, so undoing \
             the add cannot put \"milk\" back beside a todo that is gone — {:?}",
            set_texts(&ops)
        );

        // And the typing is still under it, at the granularity banking
        // left: one more undo empties the field's history the coarse way.
        let (ops, occ) = scene.undo(DEFAULT_WINDOW).expect("the typing under it");
        let Occurrence::Undone { label, .. } = &occ else {
            panic!("wanted Undone");
        };
        assert_eq!(label, "", "a typing episode carries no authored name");
        assert_eq!(set_texts(&ops), vec![(2, String::new())]);
    }

    #[test]
    fn the_interleave_walks_back_b_then_x_then_a() {
        // §2's hole, closed. Under two bare stacks this undoes as b, a,
        // X — both text edits first, because they live on the other
        // stack — and the user passes through a state that never
        // existed. One ledger gives the order things happened in.
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), "a", true);
        scene.apply(vec![
            group("X"),
            TxOp::WriteSignal { id: SignalId(1), value: v("two") },
        ]);
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), "ab", true);
        assert_eq!(depth(&scene, DEFAULT_WINDOW), 3);

        let (ops, occ) = scene.undo(DEFAULT_WINDOW).expect("b");
        assert_eq!(set_texts(&ops), vec![(2, "a".to_string())]);
        let Occurrence::Undone { label, delta, .. } = &occ else {
            panic!("wanted Undone");
        };
        assert_eq!(label, "", "a typing episode carries no authored name");
        assert_eq!(delta.texts, vec![live_text(2, "a")]);

        let (_, occ) = scene.undo(DEFAULT_WINDOW).expect("X");
        let Occurrence::Undone { label, .. } = &occ else {
            panic!("wanted Undone");
        };
        assert_eq!(label, "X");
        assert_eq!(scene.signals[&SignalId(1)], v("one"));

        let (ops, _) = scene.undo(DEFAULT_WINDOW).expect("a");
        assert_eq!(set_texts(&ops), vec![(2, String::new())]);
        assert!(scene.undo(DEFAULT_WINDOW).is_none(), "no holes, and no more");

        // And forward again, in the order they happened.
        let (ops, _) = scene.redo(DEFAULT_WINDOW).expect("a");
        assert_eq!(set_texts(&ops), vec![(2, "a".to_string())]);
        let (_, occ) = scene.redo(DEFAULT_WINDOW).expect("X");
        let Occurrence::Redone { label, .. } = &occ else {
            panic!("wanted Redone");
        };
        assert_eq!(label, "X");
        assert_eq!(scene.signals[&SignalId(1)], v("two"));
        let (ops, _) = scene.redo(DEFAULT_WINDOW).expect("b");
        assert_eq!(set_texts(&ops), vec![(2, "ab".to_string())]);
    }

    #[test]
    fn routing_asks_the_focused_field_first_and_the_ledger_otherwise() {
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        assert_eq!(
            scene.route_undo(DEFAULT_WINDOW, Some(WidgetId(2)), true),
            UndoRoute::Nothing,
            "an empty ledger is a disabled Edit>Undo"
        );
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), "milk", true);
        assert_eq!(
            scene.route_undo(DEFAULT_WINDOW, Some(WidgetId(2)), true),
            UndoRoute::Native,
            "the frontier episode on the focused field is the platform's"
        );
        assert_eq!(
            scene.route_undo(DEFAULT_WINDOW, Some(WidgetId(2)), false),
            UndoRoute::Core,
            "A4's query said no: the coarse restore answers"
        );
        assert_eq!(
            scene.route_undo(DEFAULT_WINDOW, Some(WidgetId(3)), true),
            UndoRoute::Core,
            "another widget has focus, so the episode is not frontier-live"
        );
        scene.apply(vec![
            group("X"),
            TxOp::WriteSignal { id: SignalId(1), value: v("two") },
        ]);
        assert_eq!(
            scene.route_undo(DEFAULT_WINDOW, Some(WidgetId(2)), true),
            UndoRoute::Core,
            "a group is the newest entry, so the core answers whatever has focus"
        );
    }

    #[test]
    fn a_native_undo_that_reaches_the_before_image_consumes_the_episode() {
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), "mi", true);
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), "milk", true);
        // The platform coalesced the run into one step of its own.
        let fallback = scene.note_native_undo(DEFAULT_WINDOW, WidgetId(2), "", false);
        assert!(fallback.is_none(), "the before-image was reached; no coarse restore");
        // Consumed AS A STEP BACK — gone from the done side, and the
        // test below is the other half: it is on the redo side, not
        // thrown away.
        assert_eq!(depth(&scene, DEFAULT_WINDOW), 0);
    }

    #[test]
    fn a_native_walk_to_the_start_banks_the_episode_forward() {
        // THE OTHER HALF OF CONSUMING AN EPISODE: it is spent as a step
        // BACK, not thrown away. The walk emptied the platform's stack
        // and the frontier moved to the group underneath, so the native
        // tier can offer this typing in NEITHER direction any more —
        // and a redo that found nothing here would be the one hole the
        // ledger promises not to have.
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), "tea", true);
        scene.apply(vec![
            group("star"),
            TxOp::WriteSignal { id: SignalId(1), value: v("starred") },
        ]);
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), "teas", true);
        assert!(
            scene
                .note_native_undo(DEFAULT_WINDOW, WidgetId(2), "tea", false)
                .is_none(),
            "the walk reached the run's start, so no coarse restore"
        );
        assert_eq!(depth(&scene, DEFAULT_WINDOW), 2, "the group and the typing under it");
        for still_holds_forward_steps in [false, true] {
            assert_eq!(
                scene.route_redo(DEFAULT_WINDOW, Some(WidgetId(2)), still_holds_forward_steps),
                UndoRoute::Core,
                "the frontier is the group again, so the ledger answers whatever \
                 the field's own stack has left — and this call IS the live \
                 enablement of Edit>Redo"
            );
        }

        let (ops, occ) = scene.redo(DEFAULT_WINDOW).expect("the typing comes back");
        assert_eq!(set_texts(&ops), vec![(2, "teas".to_string())]);
        let Occurrence::Redone { label, delta, .. } = &occ else {
            panic!("wanted Redone");
        };
        assert_eq!(label, "", "a typing episode carries no authored name");
        assert_eq!(
            delta.texts,
            vec![live_text(2, "teas")],
            "the after-image, restored by the core: the redo is the coarse one, \
             which is the granularity the walk already spent"
        );

        // And it is a step back again, as often as the user likes.
        let (ops, _) = scene.undo(DEFAULT_WINDOW).expect("and back");
        assert_eq!(set_texts(&ops), vec![(2, "tea".to_string())]);
    }

    #[test]
    fn a_new_step_after_a_banked_walk_spends_the_forward_history() {
        // A banked episode is forward history like any other, so the
        // rule every undo system has applies to it unchanged: a new step
        // invalidates it. THIS IS ALSO WHY tools/scenes/undo.steps asks
        // for the redo before the next app action — a click that commits
        // a group would take the banked typing with it, whatever it did
        // to focus.
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), "milk", true);
        assert!(
            scene
                .note_native_undo(DEFAULT_WINDOW, WidgetId(2), "", false)
                .is_none()
        );
        assert_eq!(scene.route_redo(DEFAULT_WINDOW, Some(WidgetId(2)), false), UndoRoute::Core);
        scene.apply(vec![
            group("X"),
            TxOp::WriteSignal { id: SignalId(1), value: v("two") },
        ]);
        assert_eq!(
            scene.route_redo(DEFAULT_WINDOW, Some(WidgetId(2)), false),
            UndoRoute::Nothing,
            "the group is the newest step, so nothing is forward of it"
        );
        assert!(scene.redo(DEFAULT_WINDOW).is_none());

        // And typing is a step by the same rule.
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), "milk", true);
        assert!(
            scene
                .note_native_undo(DEFAULT_WINDOW, WidgetId(2), "", false)
                .is_none()
        );
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), "b", true);
        assert_eq!(
            scene.route_redo(DEFAULT_WINDOW, Some(WidgetId(2)), false),
            UndoRoute::Nothing,
            "the new run is the newest step"
        );
    }

    #[test]
    fn a_partial_native_undo_leaves_the_episode_open_and_typing_extends_it() {
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), "milk", true);
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), "milk bread", true);
        let fallback = scene.note_native_undo(DEFAULT_WINDOW, WidgetId(2), "milk ", true);
        assert!(fallback.is_none());
        assert_eq!(
            episode(&scene, DEFAULT_WINDOW),
            Some(("", "milk bread", "milk ", true)),
            "current sits between the images; the high-water is untouched"
        );
        assert_eq!(
            scene.route_redo(DEFAULT_WINDOW, Some(WidgetId(2)), true),
            UndoRoute::Native,
            "the platform still holds the forward steps"
        );
        // Further typing extends the SAME run, and the platform's own
        // rule that a keystroke kills the redo history is inherited.
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), "milk eggs", true);
        assert_eq!(depth(&scene, DEFAULT_WINDOW), 1);
        assert_eq!(
            episode(&scene, DEFAULT_WINDOW),
            Some(("", "milk eggs", "milk eggs", true))
        );
    }

    #[test]
    fn a_restated_walk_position_is_not_a_new_high_water() {
        // EXACTLY ONE FUNCTION REPORTS A ROUTED NATIVE UNDO. The backend
        // marks the ordinary text_changed its own undo provokes
        // ledger-quiet, so the walk is told to the core once, by
        // note_native_undo. This is what happens when a backend forgets
        // the mark and the same undo is reported twice.
        //
        // The no-change return at the top of note_text_changed catches it
        // whenever the core's record of the field is current — which it
        // is, right after a walk — so the record is made STALE here by
        // hand. That is the only way to reach the high-water rule at all,
        // and a guard nobody can reach is a guard nobody can watch fail.
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), "milk bread", true);
        assert!(
            scene
                .note_native_undo(DEFAULT_WINDOW, WidgetId(2), "milk ", true)
                .is_none()
        );
        scene.field_text.insert(WidgetId(2), "milk bread".to_owned());
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), "milk ", true);
        assert_eq!(
            episode(&scene, DEFAULT_WINDOW),
            Some(("", "milk bread", "milk ", true)),
            "the walk's own position must not become the high-water — a redo \
             would have nowhere to go"
        );
        assert_eq!(
            scene.route_redo(DEFAULT_WINDOW, Some(WidgetId(2)), true),
            UndoRoute::Native,
            "and the forward steps the platform still holds stay reachable"
        );
    }

    #[test]
    fn an_exhausted_native_stack_short_of_the_before_image_falls_back_to_the_coarse_restore() {
        // The arm A1's clear is supposed to make unreachable — see the
        // test below, which is the one that proves it cannot be entered
        // through the ordinary lifecycle. Reached here only by lying to
        // the core about CanUndo, which is what a platform that
        // coalesced across the episode start would look like.
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), "milk bread", true);
        let (ops, occ) = scene
            .note_native_undo(DEFAULT_WINDOW, WidgetId(2), "milk ", false)
            .expect("exhausted short of the before-image");
        assert_eq!(set_texts(&ops), vec![(2, String::new())]);
        let Occurrence::Undone { delta, .. } = &occ else {
            panic!("wanted Undone");
        };
        assert_eq!(delta.texts, vec![live_text(2, "")]);
        assert_eq!(depth(&scene, DEFAULT_WINDOW), 0);
    }

    #[test]
    fn the_clear_puts_the_exhausted_case_out_of_reach() {
        // THE KEYSTONE, asserted rather than assumed: every episode
        // begins with an empty native stack, so a native undo can walk
        // the frontier episode and physically nothing else. Provoke the
        // shape that would break it — a group commits mid-run, then the
        // user types again — and the new run's before-image is where the
        // clear left the field, so walking it back cannot pass the
        // group.
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), "milk", true);
        let ops = scene.apply(vec![
            group("add todo"),
            TxOp::WriteSignal { id: SignalId(1), value: v("two") },
        ]);
        assert_eq!(cleared(&ops), 1, "the native stack is empty from here");
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), "milk ", true);
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), "milk bread", true);
        // The furthest the platform can walk is this run's start.
        let fallback = scene.note_native_undo(DEFAULT_WINDOW, WidgetId(2), "milk", false);
        assert!(
            fallback.is_none(),
            "the walk reached the before-image, which is where the clear put it"
        );
        // What is left under it is the group, in order — not the older
        // typing, which the platform can no longer see.
        match scene.ledgers[&DEFAULT_WINDOW].done.last() {
            Some(LedgerEntry::Group { label, .. }) => assert_eq!(label, "add todo"),
            _ => panic!("the group must be the next step back"),
        }
    }

    /// The undo scene one level down: the For's template holds the
    /// element-bound label AND AN ENTRY OF ITS OWN — a collection row's
    /// text field, which is the case the fixed-arity texts run could not
    /// name and therefore did not bank (RULED 2026-08-06, option A).
    ///
    /// ids: signal 1; widgets 1 column, 2 the live entry, 3 label,
    /// 4 the For; collection 1; template nodes 10 label, 11 row entry.
    fn stamped_field_scene() -> Transaction {
        vec![
            TxOp::CreateSignal { id: SignalId(1), initial: v("one") },
            TxOp::CreateWidget { id: WidgetId(1), kind: WidgetKind::Column },
            TxOp::CreateWidget { id: WidgetId(2), kind: WidgetKind::Entry },
            TxOp::CreateWidget { id: WidgetId(3), kind: WidgetKind::Label },
            TxOp::SetProperty {
                widget: WidgetId(3),
                prop: Prop::Text,
                value: PropValue::Signal(SignalId(1)),
            },
            TxOp::CreateCollection { id: CollectionId(1), variants: vec![vec![ValueType::Str]] },
            TxOp::CreateFor { id: 4, collection: CollectionId(1) },
            TxOp::CreateWidget { id: WidgetId(10), kind: WidgetKind::Label },
            TxOp::SetProperty {
                widget: WidgetId(10),
                prop: Prop::Text,
                value: PropValue::Element { level: 0, field: 0 },
            },
            TxOp::CreateWidget { id: WidgetId(11), kind: WidgetKind::Entry },
            TxOp::TemplateEnd,
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(2) },
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(3) },
            TxOp::AddChild { parent: WidgetId(1), child: WidgetId(4) },
            TxOp::Mount { window: DEFAULT_WINDOW, root: WidgetId(1) },
        ]
    }

    fn insert_row(key: &str) -> TxOp {
        TxOp::CollectionInsert {
            id: CollectionId(1),
            path: vec![],
            key: v(key),
            variant: 0,
            record: vec![v(key)],
        }
    }

    /// The map the stamping pass used to throw away is kept, and it is
    /// kept per copy: every template node the body created answers with
    /// the widget THIS copy got, and two copies of one template answer
    /// differently. Without it the two names for a row's field — the
    /// internal id the text arrives under and the (node, key path) the
    /// app knows it by — cannot be translated in either direction.
    #[test]
    fn a_stamp_remembers_which_node_each_widget_came_from() {
        let mut scene = Scene::new();
        scene.apply(stamped_field_scene());
        scene.apply(vec![insert_row("r1"), insert_row("r2")]);
        let one = &scene.stamps[&(CollectionId(1), vec![], Key::Str("r1".into()))];
        let two = &scene.stamps[&(CollectionId(1), vec![], Key::Str("r2".into()))];
        for stamp in [one, two] {
            let mut nodes: Vec<u64> = stamp.nodes.keys().copied().collect();
            nodes.sort_unstable();
            assert_eq!(nodes, vec![10, 11], "both template nodes, and only those");
            for widget in stamp.nodes.values() {
                assert!(stamp.widgets.contains(widget), "a widget this copy created");
            }
        }
        assert_ne!(
            one.nodes[&11], two.nodes[&11],
            "one template node, two copies, two widgets — which is the whole \
             reason the app cannot be handed the internal id"
        );
    }

    /// THE ITEM THIS SLICE EXISTS FOR. A row's field banks a typing
    /// episode like any other field, walks back through the ledger, and
    /// is named in the payload the way the app knows it: template node
    /// plus key path, never the copy's internal id (D5 — this record is
    /// the only thing the app hears, so every name in it must be one the
    /// app can resolve).
    #[test]
    fn a_stamped_rows_field_banks_an_episode_and_names_itself_to_the_app() {
        let mut scene = Scene::new();
        scene.apply(stamped_field_scene());
        scene.apply(vec![insert_row("r1")]);

        // The identity a backend reports the edit under: the tag it was
        // handed at Create, which for a copy is (node, key path).
        let tag = crate::wire::click_tag(11, &[v("r1")]);
        let field = scene
            .text_field_of_tag(&tag)
            .expect("a stamped copy's field resolves to the widget carrying the text");
        assert!(
            field.0 & INTERNAL_BIT != 0,
            "the ledger keys on the copy's own internal id — the one a \
             programmatic write to the same field names"
        );

        scene.note_text_changed(DEFAULT_WINDOW, field, "ha", false);
        assert_eq!(depth(&scene, DEFAULT_WINDOW), 1, "the row's run is banked");
        assert_eq!(
            scene.route_undo(DEFAULT_WINDOW, Some(WidgetId(2)), false),
            UndoRoute::Core,
            "the frontier is the row's episode and the focus is elsewhere"
        );

        let (ops, occ) = scene.undo(DEFAULT_WINDOW).expect("the row's typing walks back");
        assert_eq!(
            set_texts(&ops),
            vec![(field.0, String::new())],
            "the widget write still goes to the copy that carries the text"
        );
        let Occurrence::Undone { label, delta, .. } = &occ else {
            panic!("wanted Undone");
        };
        assert_eq!(label, "", "a typing episode carries no authored name");
        assert_eq!(
            delta.texts,
            vec![crate::protocol::UndoText {
                id: 11,
                path: vec![v("r1")],
                text: String::new(),
            }],
            "named the app's way: the template node and the row's key"
        );

        let (ops, occ) = scene.redo(DEFAULT_WINDOW).expect("and forward again");
        assert_eq!(set_texts(&ops), vec![(field.0, "ha".to_string())]);
        let Occurrence::Redone { delta, .. } = &occ else {
            panic!("wanted Redone");
        };
        assert_eq!(
            delta.texts,
            vec![crate::protocol::UndoText {
                id: 11,
                path: vec![v("r1")],
                text: "ha".to_string(),
            }]
        );
    }

    /// Two copies of one template are two fields, and the payload says
    /// which. A reader that took the template node alone would fold the
    /// wrong row's text into its model and never know.
    #[test]
    fn two_rows_of_one_template_bank_separately() {
        let mut scene = Scene::new();
        scene.apply(stamped_field_scene());
        scene.apply(vec![insert_row("r1"), insert_row("r2")]);
        let first = scene
            .text_field_of_tag(&crate::wire::click_tag(11, &[v("r1")]))
            .expect("row one");
        let second = scene
            .text_field_of_tag(&crate::wire::click_tag(11, &[v("r2")]))
            .expect("row two");
        assert_ne!(first, second);
        scene.note_text_changed(DEFAULT_WINDOW, first, "one", false);
        scene.note_text_changed(DEFAULT_WINDOW, second, "two", false);
        assert_eq!(depth(&scene, DEFAULT_WINDOW), 2, "two runs, two entries");

        let (_, occ) = scene.undo(DEFAULT_WINDOW).expect("newest first");
        let Occurrence::Undone { delta, .. } = &occ else {
            panic!("wanted Undone");
        };
        assert_eq!(delta.texts[0].path, vec![v("r2")]);
        let (_, occ) = scene.undo(DEFAULT_WINDOW).expect("then the older one");
        let Occurrence::Undone { delta, .. } = &occ else {
            panic!("wanted Undone");
        };
        assert_eq!(delta.texts[0].path, vec![v("r1")]);
    }

    /// A removed row takes its typing history with it. The alternative
    /// is a step that visibly does nothing — the user presses Cmd+Z, the
    /// core writes text into a widget that no longer exists, and the
    /// screen does not move — which is the shape this milestone exists
    /// to remove, one level down.
    #[test]
    fn a_removed_row_takes_its_episode_with_it() {
        let mut scene = Scene::new();
        scene.apply(stamped_field_scene());
        scene.apply(vec![insert_row("r1")]);
        let field = scene
            .text_field_of_tag(&crate::wire::click_tag(11, &[v("r1")]))
            .expect("the row's field");
        scene.note_text_changed(DEFAULT_WINDOW, field, "ha", false);
        assert_eq!(depth(&scene, DEFAULT_WINDOW), 1);

        scene.apply(vec![
            group("remove r1"),
            TxOp::CollectionRemove {
                id: CollectionId(1),
                path: vec![],
                key: v("r1"),
            },
        ]);
        assert_eq!(
            depth(&scene, DEFAULT_WINDOW),
            1,
            "the removal is the only step left: the row's run went with the row"
        );
        let (_, occ) = scene.undo(DEFAULT_WINDOW).expect("the removal walks back");
        let Occurrence::Undone { label, delta, .. } = &occ else {
            panic!("wanted Undone");
        };
        assert_eq!(label, "remove r1");
        assert!(
            delta.texts.is_empty(),
            "undo restores app state; an uncontrolled field's text is the \
             widget's, and the row comes back the way a fresh copy is stamped"
        );
    }

    #[test]
    fn an_inverse_that_rewrites_a_field_ends_that_field_s_run() {
        // An inverse is a programmatic write like any other, so D7 does
        // not stop applying just because the core is the one writing:
        // restoring a signal bound to a field's text ends the run the
        // user was in, and the next keystroke starts a new one from
        // where the inverse left the field.
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        scene.apply(vec![TxOp::CreateSignal { id: SignalId(2), initial: v("") }]);
        scene.apply(vec![TxOp::SetProperty {
            widget: WidgetId(2),
            prop: Prop::Text,
            value: PropValue::Signal(SignalId(2)),
        }]);
        scene.apply(vec![
            group("draft"),
            TxOp::WriteSignal { id: SignalId(2), value: v("hello") },
        ]);
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), "hello!", true);
        assert_eq!(episode(&scene, DEFAULT_WINDOW).map(|e| e.3), Some(true));

        // Undoing the group rewrites the field back to "": the run the
        // user was in cannot survive that.
        let (ops, _) = scene.undo(DEFAULT_WINDOW).expect("the episode is the newest step");
        assert_eq!(
            set_texts(&ops),
            vec![(2, "hello".to_string())],
            "the episode walks back to where the group's write left the field"
        );
        let (ops, _) = scene.undo(DEFAULT_WINDOW).expect("then the group");
        assert!(set_texts(&ops).iter().any(|(id, t)| *id == 2 && t.is_empty()));
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), "x", true);
        assert_eq!(
            episode(&scene, DEFAULT_WINDOW),
            Some(("", "x", "x", true)),
            "the new run starts where the inverse left the field"
        );
    }

    #[test]
    fn the_core_never_reads_a_widget_for_an_episode() {
        // The before-image comes from the occurrence stream and the
        // programmatic writes the core resolved — nothing else. A field
        // the core has never heard of starts empty, and one it has
        // written starts from what it wrote.
        let mut scene = Scene::new();
        scene.apply(undo_scene());
        scene.apply(vec![TxOp::SetProperty {
            widget: WidgetId(2),
            prop: Prop::Text,
            value: PropValue::Const(v("draft")),
        }]);
        scene.note_text_changed(DEFAULT_WINDOW, WidgetId(2), "drafts", true);
        assert_eq!(
            episode(&scene, DEFAULT_WINDOW),
            Some(("draft", "drafts", "drafts", true)),
            "the run starts where the core last saw the field, not at empty"
        );
    }
}
