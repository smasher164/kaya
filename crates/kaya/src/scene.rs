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
    ApplyOp, CollectionId, CommandKind, Key, Prop, PropValue, Record, SignalId, Transaction, TxOp,
    Value, ValueType, WidgetId, WidgetKind,
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

#[derive(Default)]
pub(crate) struct Scene {
    signals: HashMap<SignalId, Value>,
    /// signal -> the (widget, property) pairs it feeds (live and stamped).
    bindings: HashMap<SignalId, Vec<(WidgetId, Prop)>>,
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
    mounted: bool,
    next_internal: u64,
    next_when_site: u64,
    next_scope: u64,
}

fn check_prop(kind: WidgetKind, prop: Prop) {
    let ok = match prop {
        Prop::Text => matches!(
            kind,
            WidgetKind::Button | WidgetKind::Label | WidgetKind::Entry | WidgetKind::Checkbox
        ),
        Prop::Checked => matches!(kind, WidgetKind::Checkbox),
        Prop::Value | Prop::Min | Prop::Max => matches!(kind, WidgetKind::Slider),
        Prop::Source => matches!(kind, WidgetKind::Image),
        // Layout weight is kind-agnostic: any child of a row/column may
        // grow, so it applies to every widget kind.
        Prop::Grow => true,
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
        CommandKind::Clear => matches!(kind, WidgetKind::Entry),
        CommandKind::Focus => matches!(
            kind,
            WidgetKind::Entry | WidgetKind::Button | WidgetKind::Checkbox | WidgetKind::Slider
        ),
    };
    assert!(ok, "kaya: command {command:?} does not apply to {kind:?}");
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
    }
}

/// The typed setters the bindings generate enforce prop types at
/// compile time — but the wire itself is untyped, so an ill-typed
/// record from a raw guest must die here, not in whichever backend
/// applies it.
fn check_prop_value(prop: Prop, value: &Value) {
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
        // Template scopes currently open; while non-empty, creation
        // records describe a blueprint instead of executing.
        let mut scopes: Vec<TplScope> = Vec::new();

        for op in tx {
            if !scopes.is_empty() {
                self.declare(op, &mut scopes, &mut out);
                continue;
            }
            match op {
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
                    *current = value;
                    if !dirty.contains(&id) {
                        dirty.push(id);
                    }
                }
                TxOp::CreateWidget { id, kind } => {
                    assert!(
                        id.0 & INTERNAL_BIT == 0,
                        "kaya: widget id {id:?} uses the reserved internal bit"
                    );
                    let clash = self.widgets.insert(id, kind).is_some();
                    assert!(!clash, "kaya: widget id {id:?} already exists");
                    // Interactive widgets carry their identity tag:
                    // buttons emit it on click, entries on edit.
                    let tag = match kind {
                        WidgetKind::Button
                        | WidgetKind::Entry
                        | WidgetKind::Checkbox
                        | WidgetKind::Slider => Self::button_tag(id.0, &vec![]),
                        _ => None,
                    };
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
                            check_prop_value(prop, &v);
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
                            check_prop_value(prop, &current);
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
                TxOp::AddChild { parent, child } => {
                    assert!(
                        self.widgets.contains_key(&parent),
                        "kaya: add_child to unknown parent {parent:?}"
                    );
                    assert!(
                        self.widgets.contains_key(&child),
                        "kaya: add_child of unknown child {child:?}"
                    );
                    out.push(ApplyOp::AddChild { parent, child });
                }
                TxOp::Mount { window, root } => {
                    assert!(
                        self.widgets.contains_key(&root),
                        "kaya: mount of unknown root {root:?}"
                    );
                    assert!(
                        !self.mounted,
                        "kaya: one scene per window until the window vocabulary lands"
                    );
                    self.mounted = true;
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

        for id in dirty {
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
            if let Value::Bool(on) = value {
                self.toggle_whens(id, on, &mut out);
            }
        }
        out
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
                check_prop(self.template_nodes[&widget.0], prop);
                match &value {
                    PropValue::Const(v) => check_prop_value(prop, v),
                    PropValue::Signal(id) => {
                        let current = self.signals.get(id).unwrap_or_else(|| {
                            panic!("kaya: binding to unknown signal {id:?}")
                        });
                        check_prop_value(prop, current);
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
                top.current.childed.push(child.0);
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
                    let tag = match kind {
                        WidgetKind::Button
                        | WidgetKind::Entry
                        | WidgetKind::Checkbox
                        | WidgetKind::Slider => Self::button_tag(*node, copy_path),
                        _ => None,
                    };
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
        ]);
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
}
