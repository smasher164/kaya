//! Traffic types between the core (main thread) and app logic (its own
//! thread).
//!
//! Transport policy: while the crate is in-process-only, transactions ride
//! `std::sync::mpsc` as parsed values, and the Rust API constructs them
//! directly — serialization is for the C boundary (wire.rs), where foreign
//! guests submit the same records as bytes. Occurrences travel the
//! byte-record ring (ring.rs) or mpsc, per consumer.

use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct WidgetId(pub u64);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct SignalId(pub u64);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct WindowId(pub u64);

/// A live alert request's id: guest-chosen, single-use — it retires
/// when its one AlertResult fires (reuse after retirement is legal;
/// reuse while live is a guest error).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct AlertId(pub u64);

/// A live file dialog, guest-chosen like an alert id, retiring when its
/// result fires. One may be live per process.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct FileDialogId(pub u64);

/// A handle on one picked file — core-minted, redeemed with
/// `kaya_open_picked`. An INTEGER because the thing it names is a
/// platform object the guest can never hold: an `NSURL` whose authority
/// dies if you stringify it (measured), a Java `Uri`, a WinRT
/// `StorageFile`, or a path. See DESIGN.md, File dialogs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct PickedId(pub u64);

/// What a handle is opened for. Writability is DISCOVERABLE on every
/// platform and REQUESTABLE on none, so the open is fallible in ways
/// the pick is not.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileMode {
    Read,
    Write,
    ReadWrite,
}

/// One picked file as it reaches the guest: the handle to redeem, a
/// display name, and `local_path` — a RE-OPENABLE NAME, empty unless
/// re-opening it actually works, which measurement put at the three
/// desktops and neither phone.
#[derive(Debug, Clone, PartialEq)]
pub struct PickedFile {
    pub handle: PickedId,
    pub name: String,
    pub local_path: String,
}

/// What the backend registers for each picked file. The core stores
/// these behind integer handles and never interprets them; only the
/// backend that made one knows what it is.
///
/// `open` runs ON THE CALLING THREAD by design — the guest called it
/// from a thread it spawned, and dispatching to a shared worker would
/// SERIALIZE opens, losing exactly the concurrency the guest created.
pub trait PickedSource: Send + Sync {
    /// Open in `mode`, returning the descriptor and whether it seeks.
    /// Seekability is only knowable by opening (Android may hand back a
    /// pipe), which is why it rides the open and not the pick.
    fn open(&self, mode: FileMode) -> std::io::Result<(i32, bool)>;
    fn name(&self) -> &str;
    /// Empty unless re-opening this name actually works.
    fn local_path(&self) -> &str;
}

/// The three desktops' source: a path is the capability, so the open is
/// ordinary `std::fs`. `into_raw_fd` transfers ownership — the guest
/// owns the descriptor from here and closes it with its own file API,
/// which is the whole point of handing over a capability rather than
/// bytes.
///
/// The phones do NOT use this: Android has no path at all, and iOS has
/// one that EPERMs once the security scope drops (measured). Their
/// sources hold the platform object instead.
#[cfg(unix)]
pub struct PathSource {
    pub name: String,
    pub path: String,
}

#[cfg(unix)]
impl PickedSource for PathSource {
    fn open(&self, mode: FileMode) -> std::io::Result<(i32, bool)> {
        use std::os::fd::IntoRawFd;
        let mut opts = std::fs::OpenOptions::new();
        match mode {
            FileMode::Read => opts.read(true),
            FileMode::Write => opts.write(true).truncate(true),
            FileMode::ReadWrite => opts.read(true).write(true),
        };
        let file = opts.open(&self.path)?;
        // A regular file seeks; anything else here (a fifo the user
        // picked, a device) does not. The phones answer this from the
        // descriptor they were handed, which is why it rides the OPEN.
        let seekable = file.metadata().map(|m| m.is_file()).unwrap_or(false);
        Ok((file.into_raw_fd(), seekable))
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn local_path(&self) -> &str {
        &self.path
    }
}

/// An alert's one answer. The wire carries a u32: action indices, or
/// the deliberately-not-an-index cancel sentinel (ALERT_CHOICE_CANCEL)
/// that every platform-native dismissal — Esc, back, outside tap, the
/// cancel button itself — resolves to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AlertChoice {
    /// The action at this index (0 or 1) was chosen.
    Action(u32),
    /// The uniform dismissal slot fired.
    Cancel,
}

/// One modal alert request, atomic on the wire (SHOW_ALERT /
/// PRESENT_ALERT carry the same shape): the request/result grammar's
/// first client. `actions` holds 0..=2 labels — the platform floor
/// (ContentDialog's three slots are two actions plus close); `cancel`
/// is the always-present dismissal slot's label.
#[derive(Debug, Clone, PartialEq)]
pub struct AlertSpec {
    pub window: WindowId,
    pub alert: AlertId,
    pub title: String,
    pub message: String,
    pub actions: Vec<String>,
    pub cancel: String,
}

/// A file-picker request. `filters` are ADVISORY `(label, extensions)`
/// pairs — every platform treats them as a default view rather than a
/// guarantee, so the guest still validates what it got.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileDialogSpec {
    pub window: WindowId,
    pub dialog: FileDialogId,
    pub multiple: bool,
    pub filters: Vec<(String, String)>,
}

/// A collection: a core-side ordered key→value table, the sibling of a
/// signal, changed with delta records and rendered by a For.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct CollectionId(pub u64);

/// A template node: a blueprint entry, declared inside a For/When
/// template scope. Never on screen and never addressable alone — an
/// instance is named (template node, key path). Its own id space, so a
/// WidgetId always names exactly one live widget.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TemplateNodeId(pub u64);

/// A menu item's id: its OWN guest-allocated id space (one `c_menu_item`
/// counter per app), distinct from widget, node, surface, and every
/// other space so cross-use with a widget or a window is a compile
/// error where the language can express it (DESIGN.md, Menus). Dispatch
/// tables key by item id — "N tables, always". Never carries the
/// internal bit; 0 is not an item.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct MenuItemId(pub u64);

/// The implicit window every scene can mount into until the window
/// vocabulary arrives (see DESIGN.md: windows are a scene layer).
pub const DEFAULT_WINDOW: WindowId = WindowId(0);

/// A key path: one key per enclosing For, outermost first. Selects one
/// stamped copy at each nesting level. Empty for the live (untemplated)
/// zone.
pub type Path = Vec<Value>;

/// What the app thread's inbox carries. A guest only ever sees
/// `Occurrence`; `Woken` is how a [`crate::Poster`] gets the app thread
/// out of `recv()` for work that is NOT an event and never belongs in
/// the public vocabulary. Keeping it out of `Occurrence` matters: guests
/// match that enum exhaustively (guests/rust/milestone2.rs does), and a
/// variant they can never receive would be a case they must write anyway.
pub(crate) enum Inbox {
    Occ(Occurrence),
    Woken,
}

/// Core -> app. Ordered, lossless, consumed exactly once.
#[derive(Debug, PartialEq)]
pub enum Occurrence {
    /// A click on a widget the guest created directly.
    ButtonClicked { id: WidgetId },
    /// A click on a stamped copy of a template button: which blueprint
    /// node, and the key path naming the copy.
    InstanceButtonClicked { node: TemplateNodeId, path: Path },
    /// The user edited an entry the guest created directly. The widget
    /// owns its text; the app folds these into its own model — there is
    /// no read-back, by doctrine.
    TextChanged { id: WidgetId, text: String },
    /// The user edited a stamped copy of a template entry.
    InstanceTextChanged { node: TemplateNodeId, path: Path, text: String },
    /// The user toggled a checkbox the guest created directly; carries
    /// the new state. Same ownership stance as TextChanged.
    Toggled { id: WidgetId, checked: bool },
    /// The user asked a veto_close window to close. Nothing has
    /// closed; the app answers with destroy_window if it agrees (the
    /// request/confirm veto class — no response required, no
    /// correlation ids).
    CloseRequested { window: WindowId },
    /// A non-veto auxiliary window was closed by its chrome —
    /// informational and post-fact; destroy_window reconciles the
    /// scene (idempotent: the backend tolerates the native window
    /// already being gone).
    WindowClosed { window: WindowId },
    /// The picker's one answer: the chosen files, or an EMPTY list for
    /// cancel — no platform can confirm an empty selection, so the
    /// empty list needs no sentinel. The dialog id retires here.
    FileDialogResult {
        dialog: FileDialogId,
        files: Vec<PickedFile>,
    },
    /// The alert's one answer; the dialog is already gone when this
    /// fires, and the alert id retired with it.
    AlertResult { alert: AlertId, choice: AlertChoice },
    /// The user's back affordance popped an entry natively —
    /// informational and post-fact (the WindowClosed precedent); the
    /// core's stack has already reconciled. A programmatic pop_entry
    /// does not echo here: its caller already knows.
    EntryPopped { entry: WindowId },
    /// The user drove the back affordance on an entry whose
    /// intercept_back is armed. Nothing has popped; the app answers
    /// with pop_entry if it agrees — the CloseRequested veto class.
    BackRequested { entry: WindowId },
    /// The user switched sections through the platform's own switcher
    /// — informational and post-fact: the selection has already
    /// changed on screen. Only the user's act emits; a programmatic
    /// SelectSection is configuration and stays silent (the echo
    /// doctrine).
    SectionSelected { window: WindowId, section: WindowId },
    /// The user toggled a stamped copy of a template checkbox.
    InstanceToggled { node: TemplateNodeId, path: Path, checked: bool },
    /// The user moved a slider the guest created directly; carries the
    /// new value, one occurrence per change (the entry's per-edit
    /// granularity). Same ownership stance as TextChanged.
    ValueChanged { id: WidgetId, value: f64 },
    /// The user moved a stamped copy of a template slider.
    InstanceValueChanged { node: TemplateNodeId, path: Path, value: f64 },
    /// A menu action fired — clicked in the bar/overflow/context menu OR
    /// invoked through its shortcut: ONE occurrence, one dispatch path
    /// (the shortcut is another affordance of the same item; DESIGN.md,
    /// Menus). The action the guest created directly.
    MenuActivated { item: MenuItemId },
    /// A menu action fired on a node-anchored context menu: the item id
    /// plus the anchor copy's key path (the on_click_node encoding — the
    /// keys ARE the noun).
    InstanceMenuActivated { item: MenuItemId, path: Path },
    /// The user flipped a toggle item; carries the new state. Reuses the
    /// checkbox contract — user activation emits, a programmatic
    /// `checked` write is configuration and stays quiet.
    MenuToggled { item: MenuItemId, checked: bool },
    /// A toggle flipped on a node-anchored context menu.
    InstanceMenuToggled { item: MenuItemId, path: Path, checked: bool },
    /// The user picked a radio option; carries the group's new selected
    /// option index (the Choice contract, 0-based, integral). A
    /// programmatic `value` write is quiet.
    MenuValueChanged { group: MenuItemId, index: f64 },
    /// A radio option picked on a node-anchored context menu.
    InstanceMenuValueChanged { group: MenuItemId, path: Path, index: f64 },
    /// The core is gone and no further occurrences will arrive; the app
    /// loop should end. First member of the lifecycle vocabulary.
    Shutdown,
}

/// Bulk payload bytes behind a cheap handle: the content-buffer arm of
/// the value set. The bytes live once, in core-owned memory; every
/// clone is an Arc clone (8 bytes of pointer, one refcount bump), so a
/// blob bound to N widgets or stamped into M rows never re-copies —
/// the scene's fan-out clones stay O(1) per reference. The last drop
/// frees: reclamation is refcount, resolving DESIGN's open question #2.
/// On the wire a blob travels as its u64 registration handle; the
/// bytes never enter a record stream.
#[derive(Clone)]
pub struct Blob(pub Arc<[u8]>);

impl std::fmt::Debug for Blob {
    /// Length plus a short FNV prefix, never the bytes: round-trip
    /// tests compare Debug strings, and a payload dump would make a
    /// megabyte diff out of a one-line mismatch (while a bare length
    /// would false-match different bytes of equal size).
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let mut h: u64 = 0xcbf2_9ce4_8422_2325;
        for b in self.0.iter() {
            h ^= u64::from(*b);
            h = h.wrapping_mul(0x0000_0100_0000_01b3);
        }
        write!(f, "Blob({} bytes, fnv={:08x})", self.0.len(), h as u32)
    }
}

impl PartialEq for Blob {
    /// Content equality: a decoded blob is a different allocation with
    /// the same bytes, and tests compare across that boundary.
    fn eq(&self, other: &Self) -> bool {
        self.0 == other.0
    }
}

impl From<Vec<u8>> for Blob {
    fn from(bytes: Vec<u8>) -> Self {
        Blob(bytes.into())
    }
}
impl From<&[u8]> for Blob {
    fn from(bytes: &[u8]) -> Self {
        Blob(bytes.into())
    }
}
impl From<Arc<[u8]>> for Blob {
    fn from(bytes: Arc<[u8]>) -> Self {
        Blob(bytes)
    }
}

/// A signal, property, element-field, or key value. The scalar set
/// plus the blob handle; there is deliberately no record *value* — a
/// collection entry is a Record (one Value per schema field), and
/// Value::Record waits for the feature that needs a record as a value
/// (nested fields, sum-typed payloads).
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Bool(bool),
    I64(i64),
    F64(f64),
    Str(String),
    /// Bulk payload bytes (an encoded image, a row batch): Arc'd core
    /// memory referenced by handle on the wire. Not a key type — a
    /// blob names content, never identity.
    Blob(Blob),
}

/// A value's type: the schema element. Every collection declares an
/// ordered list of these at creation, and every field access — inserts,
/// field updates, element bindings — is validated against it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ValueType {
    Bool,
    I64,
    F64,
    Str,
    Blob,
}

impl Value {
    pub fn type_of(&self) -> ValueType {
        match self {
            Value::Bool(_) => ValueType::Bool,
            Value::I64(_) => ValueType::I64,
            Value::F64(_) => ValueType::F64,
            Value::Str(_) => ValueType::Str,
            Value::Blob(_) => ValueType::Blob,
        }
    }
}

/// One collection entry's value: one Value per schema field, positional.
/// A scalar collection is the one-field case.
pub type Record = Vec<Value>;

impl From<&str> for Value {
    fn from(s: &str) -> Self {
        Value::Str(s.to_owned())
    }
}
impl From<String> for Value {
    fn from(s: String) -> Self {
        Value::Str(s)
    }
}
impl From<i64> for Value {
    fn from(v: i64) -> Self {
        Value::I64(v)
    }
}
impl From<bool> for Value {
    fn from(v: bool) -> Self {
        Value::Bool(v)
    }
}
impl From<f64> for Value {
    fn from(v: f64) -> Self {
        Value::F64(v)
    }
}
impl From<Blob> for Value {
    fn from(b: Blob) -> Self {
        Value::Blob(b)
    }
}

/// A collection key, core-side: domain identity, unique per collection
/// instance. I64 and Str only — a float is not an identity, and a bool
/// key is a When in disguise. Hashable where Value cannot be.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Key {
    I64(i64),
    Str(String),
}

impl Key {
    /// Keys arrive on the wire as values; anything but I64/Str is a
    /// broken binding.
    pub fn from_value(v: &Value) -> Key {
        match v {
            Value::I64(n) => Key::I64(*n),
            Value::Str(s) => Key::Str(s.clone()),
            Value::Blob(_) => panic!(
                "kaya: a blob names content, never identity — blobs cannot be \
                 collection keys (key by an id and keep the bytes as a field)"
            ),
            other => panic!("kaya: collection keys must be I64 or Str, got {other:?}"),
        }
    }

    pub fn to_value(&self) -> Value {
        match self {
            Key::I64(n) => Value::I64(*n),
            Key::Str(s) => Value::Str(s.clone()),
        }
    }
}

/// The widget vocabulary, growing one conformance-gallery widget at a
/// time.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WidgetKind {
    Column,
    Button,
    Label,
    /// A single-line text field. Uncontrolled: the widget owns its
    /// text and reports edits as TextChanged occurrences; Prop::Text
    /// sets the initial (or programmatic) content.
    Entry,
    /// A horizontal container: Column turned sideways.
    Row,
    /// A labeled on/off box. Prop::Text is the caption, Prop::Checked
    /// the state; user toggles report as Toggled occurrences.
    Checkbox,
    /// A continuous control over a numeric range. Prop::Value is the
    /// position, Prop::Min/Prop::Max the range (0..1 unless set); user
    /// drags report as ValueChanged occurrences, one per change.
    /// Uncontrolled, like the entry: the widget owns its position.
    Slider,
    /// A displayed picture. Prop::Source carries the encoded bytes
    /// (PNG/JPEG/...) as a blob; the toolkit decodes natively.
    /// Display-only, like Label: no occurrence, no tag. The v1 vehicle
    /// for the content-buffer path (DESIGN: "Image covers content
    /// buffers").
    Image,
    /// A horizontal progress bar. Display-only, like Label and
    /// Image: no occurrence, no tag. Prop::Value carries the
    /// determinate fraction (0..=1, domain-checked at the root, the
    /// grow discipline); Prop::Indeterminate switches the bar to the
    /// platform's activity mode (pulse/animation) and Value is
    /// ignored while it is on.
    Progress,
    Select,
    Radio,
    Grid,
    /// The multi-line entry: same uncontrolled text contract, same
    /// text_changed occurrence, same clear/focus commands — the
    /// platform's real multi-line editor.
    Textarea,
    /// A vertical scroll viewport over EXACTLY ONE child (usually a
    /// column) — the ScrolledWindow/SingleChildScrollView shape; the
    /// scene rejects a second child. Vertical-only in v1 (an axis
    /// enum is a later relaxation, the slider-step precedent). No
    /// occurrence: the position is widget-owned state, and no props
    /// of its own — Spacing/Align are container-of-many concerns and
    /// do not apply. Virtualization is explicitly out (ledgered; a
    /// For inside a scroll renders unvirtualized).
    Scroll,
}

/// The menu item vocabulary (spec enum "menu_kind"; DESIGN.md, Menus).
/// `menu` and `radio_group` are the grouping nodes; the rest are
/// leaves. One vocabulary, two anchors (the window bar and a
/// widget/node context) — the anchor decides the spelling, never the
/// item kinds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MenuItemKind {
    /// A neutral grouping node, at bar level or nested as a submenu.
    Menu,
    /// A leaf command emitting `menu_activated`.
    Action,
    /// A stateful leaf reusing the Checkbox contract; emits
    /// `menu_toggled`.
    Toggle,
    /// A grouping node and Choice-contract state owner; its selected
    /// option is an integral index (`value`), and a user pick emits
    /// `menu_value_changed`. Accepts only `radio_option` children.
    RadioGroup,
    /// A labeled option belonging to a radio group.
    RadioOption,
    /// Native grouping chrome with no label or handler.
    Separator,
}

impl MenuItemKind {
    /// Whether this kind may carry a `shortcut` — every LEAF command
    /// (DESIGN.md, Menus). ONE statement of the rule: the root's
    /// validation and every backend's dispatch table read it here, so a
    /// backend cannot quietly disagree with the root about which chords
    /// exist. It did once: a table built from actions alone gated the
    /// harness verb, so a checkable command's chord was never pressed
    /// and the silence read as a platform limitation (docs/traps.md).
    pub fn takes_shortcut(self) -> bool {
        matches!(
            self,
            MenuItemKind::Action | MenuItemKind::Toggle | MenuItemKind::RadioOption
        )
    }
}

/// Value accessors for a prop apply. The ROOT validated every (prop,
/// value) pairing, so a mismatch here is a core bug rather than a guest
/// one — which is exactly why a backend should match EXHAUSTIVELY over
/// the prop enum and read the value through these, instead of matching
/// the pair and catching the rest. A new prop then fails to COMPILE in
/// every backend; the previous shape let `role` reach a catch-all and
/// panic on Windows at runtime (docs/traps.md).
// (Their callers are the cfg'd NATIVE backends — gtk and winui — so a
// mac-native build sees no use at all.)
#[allow(dead_code)]
pub fn prop_str(value: &Value) -> &str {
    match value {
        Value::Str(s) => s,
        other => unreachable!("kaya: prop wants Str, the root passed {other:?}"),
    }
}

#[allow(dead_code)]
pub fn prop_bool(value: &Value) -> bool {
    match value {
        Value::Bool(b) => *b,
        other => unreachable!("kaya: prop wants Bool, the root passed {other:?}"),
    }
}

#[allow(dead_code)]
pub fn prop_f64(value: &Value) -> f64 {
    match value {
        Value::F64(f) => *f,
        other => unreachable!("kaya: prop wants F64, the root passed {other:?}"),
    }
}

/// Menu property keys — separate from widget, window, entry, and
/// section props (spec::MENU_PROPS; DESIGN.md, Menus). `label` and
/// `enabled` apply to every kind but `separator`; `checked` is
/// toggle-only, `value` radio-group-only; `primary` and `role` are
/// action-only, `shortcut` rides any leaf command. `label`, `enabled`,
/// `checked`, and `value` are signal-bindable; `icon`, `primary`,
/// `shortcut`, and `role` are const-only.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MenuProp {
    /// The item's label (Str). Required except on separators;
    /// signal-bindable.
    Label,
    /// Whether the item is enabled (Bool, default true);
    /// signal-bindable.
    Enabled,
    /// A toggle's state (Bool); signal-bound in both directions under
    /// the Checkbox contract.
    Checked,
    /// A radio group's selected option index (F64, integral, 0-based)
    /// under the Choice contract.
    Value,
    /// An optional icon (Blob) used by phone promotion; ignored where
    /// native menu dress has no icon.
    Icon,
    /// The phone-bar promotion hint (Bool, default false); action-only,
    /// inert on desktops.
    Primary,
    /// A normalized shortcut spelling (Str); any window-anchored LEAF
    /// command — action, toggle, or radio option. The core validates
    /// the canonical wire form and rejects non-canonical spellings — it
    /// never rewrites guest data.
    Shortcut,
    /// A standard-command role (Str) from the closed vocabulary;
    /// action-only. `settings` is the one v1 value: macOS places that
    /// item in the application menu, every other host leaves it where
    /// the app put it.
    Role,
}

/// Which materialized attachment a backend's menu native belongs to:
/// one window's bar, or one context anchor's flyout. A template
/// context catalog attaches the SAME item ids to every stamped copy,
/// so an item id alone never identifies a native — stamped node
/// activations carry the copy's key path because those keys identify
/// the noun (DESIGN.md, Menus), and only the attachment says whose
/// copy (and therefore whose noun) an activation route fires for.
/// A backend that keeps a flat native map keys it by
/// `(MenuAttachment, item id)` (WinUI); GTK reaches the same
/// invariant with per-attachment action instances. Compiled with the
/// Rust-native backends and the unit tests (the harness cfg
/// precedent).
#[cfg(any(target_os = "windows", test))]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MenuAttachment {
    /// The window catalog attachment (the bar), by window id.
    Window(u64),
    /// A context catalog attachment, by anchor widget id.
    Context(u64),
}

/// Destroying a context anchor takes its materialized natives with it
/// (menu ITEMS are never destroyed; the attachment's instances are):
/// a detached native still raises Click through its automation peer —
/// the WinUI menu probe proves it — so a surviving entry would stay
/// invoke-capable with the dead copy's noun. Every other attachment's
/// natives — the shared item ids under OTHER anchors, and the window
/// bars — survive untouched (GTK's Destroy arm is the precedent: it
/// retains item actions against the removed attachment's instances).
#[cfg(any(target_os = "windows", test))]
pub fn purge_context_natives<V>(
    natives: &mut std::collections::HashMap<(MenuAttachment, u64), V>,
    anchor: u64,
) {
    natives.retain(|&(a, _), _| a != MenuAttachment::Context(anchor));
}

/// Property keys; grows with widgets.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Prop {
    Text,
    /// A checkbox's state (Bool-valued).
    Checked,
    /// A slider's position (F64-valued).
    Value,
    /// A slider's range, lower bound (F64-valued).
    Min,
    /// A slider's range, upper bound (F64-valued).
    Max,
    /// An image's encoded source bytes (Blob-valued).
    Source,
    /// A container's inter-child gap on its main axis (F64-valued,
    /// device-independent units; finite, non-negative). The normalized
    /// default is 8 — the prop overrides it per container. Spacing is
    /// a property OF the container, unlike grow, which rides the child.
    Spacing,
    /// A container's cross-axis child placement (I64-valued on the
    /// wire: one of the `align` spec enum's values — start 0, center
    /// 1, end 2, stretch 3, baseline 4). Baseline is rows-only; the
    /// scene rejects it on columns.
    Align,
    /// A child's flex-grow weight within its row/column (F64-valued;
    /// 0 = natural size, the default). Kind-agnostic — any child may
    /// grow.
    ///
    /// The normalized semantics, uniform on every backend: children
    /// with weight 0 are laid out at their natural main-axis size, and
    /// the children with weight > 0 divide the space left over in
    /// proportion to their weights. A grower's own natural size does
    /// not enter the division — weights 1 and 3 split the leftover
    /// 1:3 whatever the two children would have measured. This is the
    /// contract shared by CSS `flex-basis: 0`, Compose's
    /// `Modifier.weight`, XAML star sizing, and Android's
    /// `layout_weight` at a 0 main-axis size; the backends that have no
    /// native weight (AppKit, GTK) construct it explicitly rather than
    /// approximating it with a priority, which would be merely ordinal
    /// and would render differently per platform.
    Grow,
    /// Progress-only (Bool): the bar shows activity without a
    /// fraction — the platform's pulse/animation mode; Value is
    /// ignored while it is on.
    Indeterminate,
    /// Grid-only (F64, integral >= 1): how many columns children
    /// fill row-major. Columns take their NATURAL width, aligned
    /// across rows — the thing nested rows cannot express.
    Columns,
    /// The accessibility IDENTIFIER (Str): a stable authored key,
    /// NEVER spoken. Every platform's automation identifier is the
    /// same idea — accessibilityIdentifier, testTag,
    /// AutomationProperties.AutomationId — which is why this is a
    /// product surface rather than test plumbing: assistive tooling
    /// and UI automation both key on it, and kaya's harness is simply
    /// its first consumer.
    A11yId,
    /// The accessibility LABEL (Str): what an assistive client SPEAKS
    /// for this widget. Separate from [`Prop::A11yId`] on purpose —
    /// conflating them would read every automation key aloud to
    /// screen-reader users. Maps to accessibilityLabel,
    /// contentDescription, AutomationProperties.Name, and GTK's LABEL
    /// accessible property.
    A11yLabel,
    /// What activating this control does — the platforms' hint, which
    /// every one of them defines as the result of an ACTION.
    A11yHint,
}

/// Window property keys — the presentation-context twin of [`Prop`],
/// separate because windows are not widgets (the widget domain checks
/// The leading pane's width for a list-detail split: a FRACTION of the
/// window, clamped.
///
/// Not half. No platform splits a list-detail in half — the list is a
/// navigation affordance and the detail is the content, so the detail
/// takes the remainder. libadwaita states the rule outright for
/// AdwNavigationSplitView (25% of the total, min 180, max 280), Apple's
/// NavigationSplitView behaves the same way, and Material gives the
/// list a preferred width with the detail taking the rest. Those
/// numbers are adopted here rather than invented so that swapping in
/// each platform's own wrapper later is a change of DRESSING, not of
/// behaviour.
///
/// This lives in one place because three backends have to pick, and
/// three independent guesses is how a lowering starts disagreeing with
/// itself across platforms.
// Used by the GTK and WinUI backends, which are cfg'd per platform, so
// a host that compiles neither sees it as dead. The tests exercise it
// everywhere.
#[cfg_attr(
    // GTK dropped off this list when the backend adopted
    // AdwNavigationSplitView: libadwaita sizes its own sidebar from the
    // rule this function encodes, so asking it to is better than
    // computing a copy. WinUI still needs the number, because
    // TwoPaneView's own default is two EQUAL panes.
    not(any(target_os = "windows", test)),
    allow(dead_code)
)]
pub(crate) fn leading_pane_width(total: f64) -> f64 {
    (total * 0.25).clamp(180.0, 280.0).min(total)
}

/// stay widget-pure; see DESIGN.md's Presentation contexts). Window 0
/// is the primary surface and always exists.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum WindowProp {
    /// The surface's title (Str-valued). Uniform semantics with
    /// per-platform materialization: the title bar on the desktops,
    /// UIScene.title on iOS, the Activity task label on Android.
    Title,
    /// Requested content width in DIP (F64-valued; finite, positive).
    /// ADVISORY on every platform: a request the window manager may
    /// decline — tiling WMs on the desktops, the system on mobile —
    /// never a guarantee.
    Width,
    /// Requested content height in DIP; see `Width`.
    Height,
    /// Who owns the chrome close (Bool-valued; default false). False:
    /// native — an aux window just closes (window_closed reports it)
    /// and closing the primary exits the app. True: the close button
    /// emits close_requested and nothing closes until the app answers
    /// with destroy_window — the veto class, armed by opt-in. Inert
    /// on mobile: no chrome close, and back is not close.
    VetoClose,
    /// How this window presents its sections (Enum-valued:
    /// [`SectionsPresentation`]; default Auto). ADVISORY, the
    /// width/height precedent: honored where the platform has the
    /// idiom, resolved to the nearest thing otherwise, ignored on the
    /// phones where physics decides. Window-scoped because the GROUP
    /// is the unit — no platform mixes per-section presentations
    /// (DESIGN.md, Sections).
    SectionsPresentation,
    /// Whether this window presents its ENTRY STACK as list-detail
    /// (Bool-valued; DESIGN.md, Adaptive list-detail). False (the
    /// default) is the serial stack navigation has always had. True
    /// asks for the adaptive presentation: on a REGULAR window the
    /// base root takes the leading pane and the top of the stack the
    /// trailing one; on a COMPACT window nothing changes, because the
    /// compact case IS the default. There is deliberately no prop for
    /// WHICH way it presents — that is the size class's answer.
    ListDetail,
}

/// The presentation hint's closed set (spec enum
/// "sections_presentation"). `Auto` resolves to each platform's
/// dominant sections idiom: the bottom tab bar on the phones, toolbar
/// tabs on macOS, NavigationView's left pane on Windows, the header
/// switcher on GTK. `Bar` asks for the horizontal spelling, `Sidebar`
/// for the leading-edge list; both are advisory.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum SectionsPresentation {
    #[default]
    Auto,
    Bar,
    Sidebar,
}

/// Section property keys — the third typed surface table (see
/// spec::SECTION_PROPS and DESIGN.md's Sections). Sections share the
/// surface-id namespace with windows and entries, so [`WindowId`]
/// carries section ids too.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SectionProp {
    /// The switcher item's label (Str-valued): the tab title on every
    /// platform.
    Title,
    /// The switcher item's icon (Blob-valued, the image-source
    /// channel). Materialized where the platform's switcher shows
    /// icons (the phones' tab bars, NavigationView); a desktop
    /// switcher without icon slots ignores it.
    Icon,
}

/// Navigation-entry property keys — their own typed table (see
/// spec::ENTRY_PROPS and DESIGN.md's Navigation): a wrong-surface
/// prop dies at compile time in every binding rather than at the
/// scene. Entries share the surface-id namespace with windows (one
/// guest-side allocator; mount's target addresses either), so
/// [`WindowId`] carries entry ids too.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EntryProp {
    /// The entry's title (Str-valued): the back affordance's label
    /// source — the iOS back button, the desktop headers.
    Title,
    /// The close-veto class transplanted to POP (Bool-valued; default
    /// false). False: the platform pops natively with its full
    /// predictive animation. True: the back affordance emits
    /// back_requested and nothing pops until the app answers with
    /// pop_entry — Android's own declared-ahead OnBackPressedCallback
    /// model, not veto-at-gesture-time.
    InterceptBack,
}

/// The one-shot command vocabulary: momentary verbs aimed at
/// widget-owned state, the third arm of the ownership rule (app-owned
/// state travels as props and deltas, widget-owned state comes back as
/// occurrences, and the app's momentary crossings into state it does
/// not own are commands). Fire-and-forget: no state at rest, nothing
/// replays on instance rebuild, and the widget reports the result
/// through its normal occurrence path. A closed set; each verb is
/// admitted by a real artifact, per the escalation policy.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CommandKind {
    /// Drop an entry's content now (the widget stays authoritative and
    /// answers with a TextChanged carrying the empty text).
    Clear,
    /// Give the widget the keyboard focus.
    Focus,
}

/// A bound property's source: a constant, a signal reference, or —
/// inside a template — one field of the element (the entry's record)
/// of an enclosing For, `level` Fors up (0 = nearest). Nothing else;
/// the binding rule, wire-concrete.
#[derive(Debug, Clone)]
pub enum PropValue {
    Const(Value),
    Signal(SignalId),
    Element { level: u32, field: u32 },
}

/// One record of a transaction, app -> core.
///
/// Zone rule: between CreateFor/CreateWhen and its matching TemplateEnd,
/// creation records describe a blueprint — their ids are read in the
/// template-node space (the WidgetId newtype in these ops carries a
/// template node id there; one wire vocabulary, two zones). Outside a
/// scope they create live things, as in milestone 1.
#[derive(Debug)]
pub enum TxOp {
    CreateSignal { id: SignalId, initial: Value },
    WriteSignal { id: SignalId, value: Value },
    CreateWidget { id: WidgetId, kind: WidgetKind },
    SetProperty { widget: WidgetId, prop: Prop, value: PropValue },
    AddChild { parent: WidgetId, child: WidgetId },
    Mount { window: WindowId, root: WidgetId },
    /// Bind a window property. Element sources are rejected at decode
    /// — windows are not collection elements; constants and signals
    /// both bind (a signal-bound title is the reactive title).
    SetWindowProp { window: WindowId, prop: WindowProp, value: PropValue },
    /// Create an auxiliary window (capability-gated; materializes
    /// hidden — mounting a root presents it).
    CreateWindow { window: WindowId },
    /// Close and forget an auxiliary window; its mounted tree is
    /// destroyed children-first. The primary is not destroyable.
    DestroyWindow { window: WindowId },
    /// Request a modal alert over a live window: one atomic record,
    /// answered by exactly one AlertResult (the request/result
    /// grammar). One alert may be live per process.
    ShowAlert(AlertSpec),
    /// Request the platform's file picker over a live window: the
    /// alert's grammar exactly, answered by one FileDialogResult. One
    /// dialog may be live per process.
    ShowFileDialog(FileDialogSpec),
    /// Push a navigation entry onto `window`'s stack (no capability
    /// gate — every host materializes a serial stack natively).
    /// Materializes covered/incoming; mounting a root into it
    /// presents it. The covered root below stays alive: retained
    /// until popped.
    PushEntry { window: WindowId, entry: WindowId },
    /// Pop the window's top entry and forget its mounted tree, the
    /// destroy_window teardown discipline (ids never reused). Popping
    /// an empty stack is a scene error. Multi-pop is binding sugar —
    /// N of these in one transaction, one animated transition.
    PopEntry { window: WindowId },
    /// Bind a navigation-entry property. Element sources are rejected
    /// at decode — entries are not collection elements.
    SetEntryProp { entry: WindowId, prop: EntryProp, value: PropValue },
    /// Append a section to `window`'s section set (no capability gate
    /// — every platform has a sections idiom). The first added
    /// becomes selected; the set is append-only, and every section's
    /// root is retained while covered (DESIGN.md, Sections).
    AddSection { window: WindowId, section: WindowId },
    /// Select a section programmatically: configuration, never echoes
    /// section_selected (the echo doctrine). The section must already
    /// be added to `window`.
    SelectSection { window: WindowId, section: WindowId },
    /// Bind a section property. Element sources are rejected at
    /// decode — sections are not collection elements.
    SetSectionProp { section: WindowId, prop: SectionProp, value: PropValue },
    /// Create a menu item of `kind` in the menu-item id space. Items
    /// are live, append-only, and never removed in v1 (DESIGN.md,
    /// Menus).
    MenuItemCreate { item: MenuItemId, kind: MenuItemKind },
    /// Append `child` under grouping node `parent` (single-parent: an
    /// item acquires exactly one parent or anchor). The closed
    /// parent/child grammar is validated at the root.
    MenuItemAppend { parent: MenuItemId, child: MenuItemId },
    /// Append a top-level grouping node (`menu` or `radio_group`) to
    /// `window`'s command catalog — the window anchor, riding the
    /// window construct under the window-attribute unification rule.
    MenubarAppend { window: WindowId, item: MenuItemId },
    /// Attach a context catalog rooted at `item` to a live widget. The
    /// editable text controls (Entry, TextArea) reject attachment — their
    /// native edit menus are dress.
    ContextAttach { widget: WidgetId, item: MenuItemId },
    /// Attach a context catalog to a template node (the Tpl zone): every
    /// stamped copy shows the same catalog, and an activation carries the
    /// copy's key path (the on_click_node encoding).
    ContextAttachNode { node: TemplateNodeId, item: MenuItemId },
    /// Bind a menu property (MENU_PROPS). Element sources are rejected at
    /// decode — menu items are not collection elements; `icon`,
    /// `primary`, and `shortcut` reject signal sources at the root.
    SetMenuProp { item: MenuItemId, prop: MenuProp, value: PropValue },
    /// Declare a collection with its schema: one ordered field-type
    /// list per variant of the element sum. Mandatory — a record
    /// collection is the one-variant case and a scalar collection the
    /// one-variant one-field case, not separate modes. Variants are
    /// indices; variant names never travel, like field names.
    CreateCollection { id: CollectionId, variants: Vec<Vec<ValueType>> },
    /// Delta ops. `path` addresses the collection instance (one key per
    /// enclosing For of the collection's declaration site; empty for a
    /// top-level collection). `variant` selects which of the sum's
    /// schemas the record matches; an update whose variant differs from
    /// the entry's current one tears down its stamped copy and restamps
    /// from the new variant's case.
    CollectionInsert { id: CollectionId, path: Path, key: Value, variant: u32, record: Record },
    CollectionUpdate { id: CollectionId, path: Path, key: Value, variant: u32, record: Record },
    /// One field's delta: toggling a todo's `done` never resends its
    /// title, and only bindings on that field re-resolve. `variant` is
    /// the discriminant the guest witnessed in the match that produced
    /// this write — never a way to change it — and the scene asserts it
    /// against the entry's stored variant, so a binding whose model
    /// drifted from the core fails loudly instead of writing a
    /// type-correct field of the wrong constructor.
    CollectionUpdateField {
        id: CollectionId,
        path: Path,
        key: Value,
        variant: u32,
        field: u32,
        value: Value,
    },
    CollectionRemove { id: CollectionId, path: Path, key: Value },
    /// Reposition an entry in the ordered table: before the entry at
    /// `before`, or to the end when None. Keys, never indices.
    CollectionMove { id: CollectionId, path: Path, key: Value, before: Option<Value> },
    /// Opens a template scope; records until TemplateEnd are the
    /// blueprint. The For itself lives where it was declared (live
    /// widget at top level, template node inside another template).
    /// Over a multi-variant collection the scope is split by
    /// VariantCase records — one blueprint per constructor, checked
    /// total at TemplateEnd.
    CreateFor { id: u64, collection: CollectionId },
    /// When is For over a zero-or-one collection wired to a Bool signal:
    /// false→true stamps the template, true→false unstamps.
    CreateWhen { id: u64, signal: SignalId },
    /// Inside a For over a sum: the records that follow (until the next
    /// VariantCase or TemplateEnd) are the blueprint for this variant.
    /// Declaring a case with no records is the explicit way to render
    /// a constructor as nothing; omitting a case is a scene error.
    VariantCase { variant: u32 },
    TemplateEnd,
    /// A one-shot command aimed at a live widget. Live-zone targets
    /// only for now: a live id can only vanish by the guest's own hand,
    /// so a missing target is misuse and fails loudly, like
    /// SetProperty. Instance-addressed commands (a scrollTo naming a
    /// stamped row) arrive with their artifact and bring the silent
    /// vanished-target no-op with them — stamped copies legitimately
    /// disappear under rebuild.
    WidgetCommand { widget: WidgetId, command: CommandKind },
}

/// A transaction: applied atomically, in submission order, last write
/// wins per signal within the batch.
pub type Transaction = Vec<TxOp>;

/// What a backend applies, produced by the scene core from a transaction
/// with every signal and element reference already resolved. Backends
/// stay appliers: no diffing, no reconciliation, no subscriptions.
///
/// Ids here are opaque u64 keys into the backend's widget map: guest
/// widget ids for the live zone, core-allocated instance ids (top bit
/// set) for stamped copies. Backends never tell them apart.
#[derive(Debug, PartialEq)]
pub enum ApplyOp {
    /// `tag`: for interactive widgets, the pre-encoded occurrence body
    /// the backend emits verbatim on activation (see wire::click_tag).
    /// The backend stores bytes and hands them back; identity stays a
    /// core concern.
    Create { id: WidgetId, kind: WidgetKind, tag: Option<Vec<u8>> },
    SetProp { id: WidgetId, prop: Prop, value: Value },
    SetWindowProp { window: WindowId, prop: WindowProp, value: Value },
    CreateWindow { window: WindowId },
    DestroyWindow { window: WindowId },
    /// Present the platform's real modal dialog (the core already
    /// validated the spec); answer exactly once with an AlertResult
    /// emission — an action index or the cancel sentinel.
    PresentAlert(AlertSpec),
    /// Present the platform's real file picker (already validated).
    PresentFileDialog(FileDialogSpec),
    /// Push a navigation entry onto the window's stack, hidden until
    /// a mount presents it. The covered root stays alive.
    PushEntry { window: WindowId, entry: WindowId },
    /// Pop the window's top entry and release its views. The NET
    /// stack change of the whole batch animates as one transition
    /// (the multi-pop obligation; see DESIGN.md, Navigation).
    PopEntry { window: WindowId },
    SetEntryProp { entry: WindowId, prop: EntryProp, value: Value },
    /// Append a section to the window's section set, its root hidden
    /// until a mount fills it; the first added becomes selected.
    AddSection { window: WindowId, section: WindowId },
    /// Select a section, quietly: programmatic selection never echoes
    /// section_selected.
    SelectSection { window: WindowId, section: WindowId },
    SetSectionProp { section: WindowId, prop: SectionProp, value: Value },
    /// Create a presentation-side menu item; the backend keys its
    /// dispatch by item id and emits menu occurrences carrying that id.
    MenuItemCreate { item: MenuItemId, kind: MenuItemKind },
    /// Append `child` under grouping node `parent`.
    MenuItemAppend { parent: MenuItemId, child: MenuItemId },
    /// Append a top-level grouping node to the window's catalog. The bar
    /// materializes per platform (native menu chrome on desktop, top-bar
    /// overflow on the phones).
    MenubarAppend { window: WindowId, item: MenuItemId },
    /// Attach a context catalog to a live widget.
    ContextAttach { widget: WidgetId, item: MenuItemId },
    /// Attach a context catalog to a stamped widget, carrying the anchor
    /// copy's key path — the noun every activation from this attachment
    /// stamps into its occurrence (the on_click_node encoding).
    ContextAttachNode { widget: WidgetId, item: MenuItemId, path: Path },
    /// Set a menu property to an already-resolved value.
    SetMenuProp { item: MenuItemId, prop: MenuProp, value: Value },
    AddChild { parent: WidgetId, child: WidgetId },
    Mount { window: WindowId, root: WidgetId },
    /// Reposition `child` among `parent`'s children: before the
    /// sibling `before`, or to the end when None.
    MoveChild { parent: WidgetId, child: WidgetId, before: Option<WidgetId> },
    /// Remove the widget from its parent and forget it. The core emits
    /// one Destroy per widget of a torn-down instance, children before
    /// parents, so backends never walk anything.
    Destroy { id: WidgetId },
    /// Execute a one-shot command on the widget, then let it report
    /// the result through its normal occurrence path — a clear arrives
    /// back as TextChanged with empty text, through the same delegate
    /// a keystroke uses (programmatic mutations fire the change path
    /// explicitly on toolkits that don't, the Stage set_text
    /// precedent).
    Command { id: WidgetId, command: CommandKind },
}

/// Where occurrences go: the Rust API consumes over mpsc, the C ABI over
/// the byte-record ring. One consumer either way.
#[derive(Clone)]
pub(crate) enum OccSink {
    Mpsc(std::sync::mpsc::Sender<Inbox>),
    Ring(std::sync::Arc<crate::ring::OccRing>),
}

impl OccSink {
    // The Rust-native backends (GTK, WinUI) push through this; on the
    // interpreter platforms occurrences enter through the C API's
    // typed emit entries instead, so the method is dead there.
    #[cfg_attr(
        any(target_os = "macos", target_os = "ios", target_os = "android"),
        allow(dead_code)
    )]
    pub(crate) fn send(&self, occurrence: Occurrence) {
        match self {
            OccSink::Mpsc(tx) => {
                let _ = tx.send(Inbox::Occ(occurrence));
            }
            OccSink::Ring(ring) => match occurrence {
                Occurrence::FileDialogResult { dialog, files } => {
                    let body = crate::wire::file_dialog_result_body(dialog, &files);
                    ring.push_record(crate::ring::REC_FILE_DIALOG_RESULT, &body);
                }
                Occurrence::ButtonClicked { id } => {
                    let tag = crate::wire::click_tag(id.0, &[]);
                    ring.push_record(crate::ring::REC_BUTTON_CLICKED, &tag);
                }
                Occurrence::InstanceButtonClicked { node, path } => {
                    let tag = crate::wire::click_tag(node.0, &path);
                    ring.push_record(crate::ring::REC_BUTTON_CLICKED, &tag);
                }
                Occurrence::TextChanged { id, text } => {
                    let tag = crate::wire::click_tag(id.0, &[]);
                    let body = crate::wire::text_changed_body(&tag, &text);
                    ring.push_record(crate::ring::REC_TEXT_CHANGED, &body);
                }
                Occurrence::InstanceTextChanged { node, path, text } => {
                    let tag = crate::wire::click_tag(node.0, &path);
                    let body = crate::wire::text_changed_body(&tag, &text);
                    ring.push_record(crate::ring::REC_TEXT_CHANGED, &body);
                }
                Occurrence::Toggled { id, checked } => {
                    let tag = crate::wire::click_tag(id.0, &[]);
                    let body = crate::wire::toggled_body(&tag, checked);
                    ring.push_record(crate::ring::REC_TOGGLED, &body);
                }
                Occurrence::InstanceToggled { node, path, checked } => {
                    let tag = crate::wire::click_tag(node.0, &path);
                    let body = crate::wire::toggled_body(&tag, checked);
                    ring.push_record(crate::ring::REC_TOGGLED, &body);
                }
                Occurrence::ValueChanged { id, value } => {
                    let tag = crate::wire::click_tag(id.0, &[]);
                    let body = crate::wire::value_changed_body(&tag, value);
                    ring.push_record(crate::ring::REC_VALUE_CHANGED, &body);
                }
                Occurrence::InstanceValueChanged { node, path, value } => {
                    let tag = crate::wire::click_tag(node.0, &path);
                    let body = crate::wire::value_changed_body(&tag, value);
                    ring.push_record(crate::ring::REC_VALUE_CHANGED, &body);
                }
                Occurrence::CloseRequested { window } => {
                    ring.push_record(
                        crate::ring::REC_CLOSE_REQUESTED,
                        &window.0.to_le_bytes(),
                    );
                }
                Occurrence::WindowClosed { window } => {
                    ring.push_record(
                        crate::ring::REC_WINDOW_CLOSED,
                        &window.0.to_le_bytes(),
                    );
                }
                Occurrence::AlertResult { alert, choice } => {
                    ring.push_record(
                        crate::ring::REC_ALERT_RESULT,
                        &crate::wire::alert_result_body(alert, choice),
                    );
                }
                Occurrence::EntryPopped { entry } => {
                    ring.push_record(crate::ring::REC_ENTRY_POPPED, &entry.0.to_le_bytes());
                }
                Occurrence::BackRequested { entry } => {
                    ring.push_record(crate::ring::REC_BACK_REQUESTED, &entry.0.to_le_bytes());
                }
                Occurrence::SectionSelected { window, section } => {
                    let mut body = [0u8; 16];
                    body[..8].copy_from_slice(&window.0.to_le_bytes());
                    body[8..].copy_from_slice(&section.0.to_le_bytes());
                    ring.push_record(crate::ring::REC_SECTION_SELECTED, &body);
                }
                Occurrence::MenuActivated { item } => {
                    let tag = crate::wire::click_tag(item.0, &[]);
                    ring.push_record(crate::ring::REC_MENU_ACTIVATED, &tag);
                }
                Occurrence::InstanceMenuActivated { item, path } => {
                    let tag = crate::wire::click_tag(item.0, &path);
                    ring.push_record(crate::ring::REC_MENU_ACTIVATED, &tag);
                }
                Occurrence::MenuToggled { item, checked } => {
                    let tag = crate::wire::click_tag(item.0, &[]);
                    let body = crate::wire::toggled_body(&tag, checked);
                    ring.push_record(crate::ring::REC_MENU_TOGGLED, &body);
                }
                Occurrence::InstanceMenuToggled { item, path, checked } => {
                    let tag = crate::wire::click_tag(item.0, &path);
                    let body = crate::wire::toggled_body(&tag, checked);
                    ring.push_record(crate::ring::REC_MENU_TOGGLED, &body);
                }
                Occurrence::MenuValueChanged { group, index } => {
                    let tag = crate::wire::click_tag(group.0, &[]);
                    let body = crate::wire::value_changed_body(&tag, index);
                    ring.push_record(crate::ring::REC_MENU_VALUE_CHANGED, &body);
                }
                Occurrence::InstanceMenuValueChanged { group, path, index } => {
                    let tag = crate::wire::click_tag(group.0, &path);
                    let body = crate::wire::value_changed_body(&tag, index);
                    ring.push_record(crate::ring::REC_MENU_VALUE_CHANGED, &body);
                }
                Occurrence::Shutdown => ring.set_shutdown(),
            },
        }
    }

    /// The backend fast path: a stored click tag goes out verbatim (ring)
    /// or is parsed back into an Occurrence (mpsc).
    pub(crate) fn send_click_tag(&self, tag: &[u8]) {
        match self {
            OccSink::Mpsc(tx) => {
                let _ = tx.send(Inbox::Occ(crate::wire::decode_click_tag(tag)));
            }
            OccSink::Ring(ring) => {
                ring.push_record(crate::ring::REC_BUTTON_CLICKED, tag);
            }
        }
    }

    /// The same fast path for a checkbox toggle: the stored tag plus
    /// the new state.
    pub(crate) fn send_toggle_tag(&self, tag: &[u8], checked: bool) {
        match self {
            OccSink::Mpsc(tx) => {
                let _ = tx.send(Inbox::Occ(crate::wire::decode_toggled_tag(tag, checked)));
            }
            OccSink::Ring(ring) => {
                ring.push_record(
                    crate::ring::REC_TOGGLED,
                    &crate::wire::toggled_body(tag, checked),
                );
            }
        }
    }

    /// The same fast path for a slider move: the stored tag plus the
    /// new value.
    pub(crate) fn send_value_tag(&self, tag: &[u8], value: f64) {
        match self {
            OccSink::Mpsc(tx) => {
                let _ = tx.send(Inbox::Occ(crate::wire::decode_value_changed_tag(tag, value)));
            }
            OccSink::Ring(ring) => {
                ring.push_record(
                    crate::ring::REC_VALUE_CHANGED,
                    &crate::wire::value_changed_body(tag, value),
                );
            }
        }
    }

    /// The same fast path for an entry edit: the stored tag plus the
    /// field's current text.
    pub(crate) fn send_text_tag(&self, tag: &[u8], text: &str) {
        match self {
            OccSink::Mpsc(tx) => {
                let _ = tx.send(Inbox::Occ(crate::wire::decode_text_changed_tag(tag, text)));
            }
            OccSink::Ring(ring) => {
                ring.push_record(
                    crate::ring::REC_TEXT_CHANGED,
                    &crate::wire::text_changed_body(tag, text),
                );
            }
        }
    }

    /// A menu action fired: the item's menu tag (item id + noun path)
    /// goes out verbatim (ring) or is parsed back into an Occurrence
    /// (mpsc). One route for the bar action and the node-anchored
    /// context item; the noun path in the tag tells them apart.
    #[cfg_attr(
        any(target_os = "macos", target_os = "ios", target_os = "android"),
        allow(dead_code)
    )]
    pub(crate) fn send_menu_activated_tag(&self, tag: &[u8]) {
        match self {
            OccSink::Mpsc(tx) => {
                let _ = tx.send(Inbox::Occ(crate::wire::decode_menu_activated_tag(tag)));
            }
            OccSink::Ring(ring) => {
                ring.push_record(crate::ring::REC_MENU_ACTIVATED, tag);
            }
        }
    }

    /// The same fast path for a toggle item: the menu tag plus the new
    /// state.
    #[cfg_attr(
        any(target_os = "macos", target_os = "ios", target_os = "android"),
        allow(dead_code)
    )]
    pub(crate) fn send_menu_toggled_tag(&self, tag: &[u8], checked: bool) {
        match self {
            OccSink::Mpsc(tx) => {
                let _ = tx.send(Inbox::Occ(crate::wire::decode_menu_toggled_tag(tag, checked)));
            }
            OccSink::Ring(ring) => {
                ring.push_record(
                    crate::ring::REC_MENU_TOGGLED,
                    &crate::wire::toggled_body(tag, checked),
                );
            }
        }
    }

    /// The same fast path for a radio group: the menu tag plus the new
    /// selected option index.
    #[cfg_attr(
        any(target_os = "macos", target_os = "ios", target_os = "android"),
        allow(dead_code)
    )]
    pub(crate) fn send_menu_value_tag(&self, tag: &[u8], index: f64) {
        match self {
            OccSink::Mpsc(tx) => {
                let _ = tx.send(Inbox::Occ(crate::wire::decode_menu_value_tag(tag, index)));
            }
            OccSink::Ring(ring) => {
                ring.push_record(
                    crate::ring::REC_MENU_VALUE_CHANGED,
                    &crate::wire::value_changed_body(tag, index),
                );
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Content is not identity: the blob arm of the key gate has its
    /// own sentence, because "must be I64 or Str" would leave an
    /// avatar-keyed collection author guessing at the doctrine.
    #[test]
    #[should_panic(expected = "a blob names content, never identity")]
    fn a_blob_cannot_be_a_key() {
        Key::from_value(&Value::Blob(Blob::from(&b"\x89PNG"[..])));
    }

    /// The multi-copy negative: a template context catalog attaches
    /// the SAME item ids to every stamped row, so a native map must
    /// hold one entry per (attachment, item). A flat per-item map
    /// keeps only the last-built copy — whichever attachment an
    /// arbitrary rebuild order visits last — with THAT row's noun
    /// baked into its activation route (the WinUI wrong-noun bug,
    /// docs/traps.md).
    #[test]
    fn stamped_copies_keep_one_native_per_attachment() {
        let mut natives = std::collections::HashMap::new();
        // Item 7 materializes under the bar and under two stamped rows.
        natives.insert((MenuAttachment::Window(0), 7u64), "bar copy");
        natives.insert((MenuAttachment::Context(31), 7u64), "row 1 copy");
        natives.insert((MenuAttachment::Context(32), 7u64), "row 2 copy");
        assert_eq!(natives.len(), 3, "every stamped copy keeps its own native");
        assert_eq!(natives[&(MenuAttachment::Context(31), 7)], "row 1 copy");
        assert_eq!(natives[&(MenuAttachment::Context(32), 7)], "row 2 copy");
        assert_eq!(natives[&(MenuAttachment::Window(0), 7)], "bar copy");
    }

    /// The destroy negative: removing one stamped row purges exactly
    /// that attachment's instances — the other rows' copies and the
    /// bar's stay — so Remove on row 1 followed by context_open +
    /// menu_activate on row 2 can never invoke (and re-emit the keys
    /// of) the dead copy.
    #[test]
    fn destroying_an_anchor_purges_only_its_natives() {
        let mut natives = std::collections::HashMap::new();
        natives.insert((MenuAttachment::Window(0), 7u64), "bar copy");
        natives.insert((MenuAttachment::Context(31), 7u64), "row 1 copy");
        natives.insert((MenuAttachment::Context(31), 8u64), "row 1 rename");
        natives.insert((MenuAttachment::Context(32), 7u64), "row 2 copy");
        purge_context_natives(&mut natives, 31);
        assert!(!natives.contains_key(&(MenuAttachment::Context(31), 7)));
        assert!(!natives.contains_key(&(MenuAttachment::Context(31), 8)));
        assert_eq!(natives[&(MenuAttachment::Context(32), 7)], "row 2 copy");
        assert_eq!(natives[&(MenuAttachment::Window(0), 7)], "bar copy");
    }
}
