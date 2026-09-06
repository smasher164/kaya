//! Traffic types between the core (main thread) and app logic (its own
//! thread). In-process transactions ride mpsc as parsed values;
//! serialization is for the C boundary (wire.rs). Occurrences travel
//! the byte-record ring (ring.rs) or mpsc, per consumer.

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

/// An opened picked file: the descriptor as the language's own file
/// type, plus whether it seeks. `seekable` rides the OPEN because only
/// opening reveals it (an Android provider may hand back a pipe);
/// FALSE means a stream — no mmap, no random access.
pub struct PickedOpen {
    pub file: std::fs::File,
    pub seekable: bool,
}

impl PickedFile {
    /// Redeem the handle for a real descriptor. BLOCKS, possibly for a
    /// long time — a cloud provider may download first — so call it from
    /// a thread you chose (DESIGN.md, File dialogs). Safe from any
    /// thread. Fallible where the pick is not: no picker on any platform
    /// lets you REQUEST write.
    pub fn open(&self, mode: FileMode) -> std::io::Result<PickedOpen> {
        let raw = match mode {
            FileMode::Read => crate::wire::FILE_MODE_READ,
            FileMode::Write => crate::wire::FILE_MODE_WRITE,
            FileMode::ReadWrite => crate::wire::FILE_MODE_READ_WRITE,
        };
        let mut handle = -1i64;
        let mut seekable = 0u32;
        let rc = crate::capi::kaya_open_picked(self.handle.0, raw, &mut handle, &mut seekable);
        if rc != 0 {
            return Err(std::io::Error::from_raw_os_error(rc as i32));
        }
        Ok(PickedOpen {
            // The handle is the guest's from here: File closes it on drop.
            file: unsafe { file_from_raw(handle) },
            seekable: seekable != 0,
        })
    }
}

/// What the backend registers for each picked file; the core stores
/// these behind integer handles and never interprets them.
///
/// `open` runs ON THE CALLING THREAD by design — dispatching to a
/// shared worker would SERIALIZE opens the guest made concurrent.
pub trait PickedSource: Send + Sync {
    /// Open in `mode`, returning the OS's own integer — a DESCRIPTOR on
    /// POSIX, a HANDLE on Windows — and whether it seeks. Seekability is
    /// only knowable by opening (Android may hand back a pipe).
    ///
    /// NOT a CRT file descriptor on Windows: `_open_osfhandle` mints one
    /// valid only inside the CRT that minted it, and Python, Go and the
    /// JVM each bring their own (docs/traps.md).
    fn open(&self, mode: FileMode) -> std::io::Result<(i64, bool)>;
    fn name(&self) -> &str;
    /// Empty unless re-opening this name actually works.
    fn local_path(&self) -> &str;
    /// WHAT THE PLATFORM CALLS THIS FILE — a path on the desktops, a
    /// `content://` URI on Android, a security-scoped URL string on iOS.
    /// Never empty, unlike `local_path`. The core resolves handle to
    /// locator once, at lowering, so no backend needs its own table.
    fn locator(&self) -> &str;
}

/// Build a File back from the OS integer the C ABI carried. Unsafe: it
/// takes ownership of a handle it did not open, and closing it twice is
/// on the caller.
#[cfg(unix)]
pub(crate) unsafe fn file_from_raw(handle: i64) -> std::fs::File {
    use std::os::fd::FromRawFd;
    unsafe { std::fs::File::from_raw_fd(handle as i32) }
}

#[cfg(windows)]
pub(crate) unsafe fn file_from_raw(handle: i64) -> std::fs::File {
    use std::os::windows::io::FromRawHandle;
    unsafe { std::fs::File::from_raw_handle(handle as *mut std::ffi::c_void) }
}

/// The open file as the OS's own integer, and the ONE place the
/// platforms differ. Both arms give up ownership: the caller owns it.
#[cfg(unix)]
pub(crate) fn raw_handle(file: std::fs::File) -> i64 {
    use std::os::fd::IntoRawFd;
    i64::from(file.into_raw_fd())
}

#[cfg(windows)]
pub(crate) fn raw_handle(file: std::fs::File) -> i64 {
    use std::os::windows::io::IntoRawHandle;
    file.into_raw_handle() as i64
}

/// `FileMode` as the number that crosses the C ABI to a backend that
/// redeems a picked file (iOS's `kaya_swiftui_open_picked`). Spelled out
/// rather than cast from the discriminant, so the two sides of the ABI
/// agree by a written rule; the Swift side names the same three values.
#[cfg_attr(not(target_os = "ios"), allow(dead_code))]
pub(crate) fn picked_mode_code(mode: FileMode) -> u32 {
    match mode {
        FileMode::Read => 0,
        FileMode::Write => 1,
        FileMode::ReadWrite => 2,
    }
}

/// `FileMode` as ContentResolver.openFileDescriptor spells it.
///
/// `wt` AND NOT `w` FOR WRITE: the provider maps a bare `w` to O_WRONLY
/// WITHOUT O_TRUNC while `PathSource` opens Write with `.truncate(true)`
/// — one `FileMode`, two meanings (docs/file-dialogs-plan.md §6d,
/// measurement 11). Not cfg'd to Android so the test runs everywhere;
/// narrowed to not-android so Android still fails if its caller goes.
#[cfg_attr(not(target_os = "android"), allow(dead_code))]
pub(crate) fn android_open_mode(mode: FileMode) -> &'static str {
    match mode {
        FileMode::Read => "r",
        FileMode::Write => "wt",
        FileMode::ReadWrite => "rw",
    }
}

/// The three desktops' source: a path is the capability, so the open is
/// ordinary `std::fs` and `into_raw_fd` transfers ownership to the
/// guest. The phones do NOT use this — Android has no path at all, and
/// iOS's EPERMs once the security scope drops
/// (docs/file-dialogs-plan.md).
pub struct PathSource {
    pub name: String,
    pub path: String,
}

impl PickedSource for PathSource {
    fn open(&self, mode: FileMode) -> std::io::Result<(i64, bool)> {
        let mut opts = std::fs::OpenOptions::new();
        match mode {
            FileMode::Read => opts.read(true),
            FileMode::Write => opts.write(true).truncate(true),
            FileMode::ReadWrite => opts.read(true).write(true),
        };
        let file = opts.open(&self.path)?;
        // A regular file seeks; a fifo or a device does not. The phones
        // answer this from the descriptor, which is why it rides the OPEN.
        let seekable = file.metadata().map(|m| m.is_file()).unwrap_or(false);
        Ok((raw_handle(file), seekable))
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn local_path(&self) -> &str {
        &self.path
    }

    /// A path IS the capability on the desktops, so the locator and
    /// the re-openable name are the same string.
    fn locator(&self) -> &str {
        &self.path
    }
}

/// WHERE A SAVE DIALOG SAID TO WRITE — the same path, opened by a different
/// rule, and the rule IS docs/save-plan.md D1: three platforms answer with a
/// name for a file NOBODY HAS MADE and two with a document that exists, so
/// the destination's open CREATES and the guest sees one behaviour.
/// CREATE ON EVERY MODE, TRUNCATE ONLY ON `Write` — `Read` and `ReadWrite`
/// coincide, since creating a file costs write access on every OS.
pub struct SaveDestination {
    pub name: String,
    pub path: String,
}

impl PickedSource for SaveDestination {
    fn open(&self, mode: FileMode) -> std::io::Result<(i64, bool)> {
        let mut opts = std::fs::OpenOptions::new();
        match mode {
            FileMode::Read => opts.read(true).write(true).create(true),
            FileMode::Write => opts.write(true).create(true).truncate(true),
            FileMode::ReadWrite => opts.read(true).write(true).create(true),
        };
        let file = opts.open(&self.path)?;
        let seekable = file.metadata().map(|m| m.is_file()).unwrap_or(false);
        Ok((raw_handle(file), seekable))
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn local_path(&self) -> &str {
        &self.path
    }

    fn locator(&self) -> &str {
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
/// PRESENT_ALERT carry the same shape). `actions` holds 0..=2 labels —
/// the platform floor; `cancel` is the always-present dismissal slot.
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

/// A save-dialog request. The picker's twin with two differences: there
/// is no `multiple`, and `suggested_name` is the name the dialog opens
/// with — ADVISORY like the filters. A guest reads the name it GOT.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SaveDialogSpec {
    pub window: WindowId,
    pub dialog: FileDialogId,
    pub suggested_name: String,
    pub filters: Vec<(String, String)>,
}

/// A brand-typeface request, carried UNRESOLVED from the guest to every
/// backend (docs/styling-plan.md Slice 2b). `family` is the default,
/// `platforms` the per-platform overrides over the spec's `platform`
/// enum, `font` an optional font file's bytes. The core resolves
/// nothing: a family NAME is a lookup only the platform can do, and a
/// binding cannot even name its own platform (the JVM says "Linux" on
/// Android).
#[derive(Debug, Clone, PartialEq)]
pub struct TypefaceRequest {
    pub family: String,
    pub platforms: Vec<(u32, String)>,
    pub font: Option<Blob>,
}

impl TypefaceRequest {
    /// The family THIS platform asked for: its own row if it has one, the
    /// default otherwise. Paired with `wire::this_platform()`.
    /// `allow(dead_code)` because a host build compiling neither Rust
    /// native backend still compiles this file.
    #[allow(dead_code)]
    pub fn family_for(&self, platform: u32) -> &str {
        self.platforms
            .iter()
            .find(|(tag, _)| *tag == platform)
            .map_or(self.family.as_str(), |(_, f)| f.as_str())
    }
}

/// The app's declared identity, carried UNINSPECTED from the guest to every
/// backend (docs/app-identity-plan.md). The core validates only the root's
/// four walls — set once, before the first mount, non-empty, not undoable —
/// because whether a blob is an image is the platform decoder's question.
/// ONE PICTURE, NOT FIVE: per-platform artwork is refused.
#[derive(Debug, Clone, PartialEq)]
pub struct AppIdentity {
    pub name: String,
    pub icon: Option<Blob>,
}

/// One clip, offered in several representations at once.
///
/// A RECORD AND NOT A LIST: every platform models the clipboard as one item
/// available in several types, so at-most-one-per-kind is structural rather
/// than a duplicate check; `custom` is the one plural field with names.
/// kaya DERIVES NOTHING — the one exception is `files`, which also gets a
/// text rendition of the paths.
/// One clip slot bound to a row field rather than a constant: `slot`
/// indexes the record's value block in its canonical order (custom id,
/// custom bytes per pair, then files, image, html, text), `level` counts
/// enclosing Fors outward as set_property's element source does.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BoundRep {
    pub slot: u32,
    pub level: u32,
    pub field: u32,
}

/// The canonical slot index of each single-valued representation, given
/// the counts ahead of it; the two plural kinds take their slots first.
impl Clip {
    pub fn slot_of_text(&self) -> u32 {
        self.slot_of_html() + u32::from(self.html.is_some())
    }
    pub fn slot_of_html(&self) -> u32 {
        self.slot_of_image() + u32::from(self.image.is_some())
    }
    pub fn slot_of_image(&self) -> u32 {
        (self.custom.len() * 2 + self.files.len()) as u32
    }
    pub fn slot_of_custom_bytes(&self, index: usize) -> u32 {
        (index * 2 + 1) as u32
    }
    /// Put a resolved value into the slot a BoundRep names.
    pub fn set_slot(&mut self, slot: u32, value: Value) {
        let pairs = self.custom.len() as u32 * 2;
        let files = self.files.len() as u32;
        if slot < pairs {
            let (i, half) = ((slot / 2) as usize, slot % 2);
            match (half, value) {
                (0, Value::Str(s)) => self.custom[i].0 = s,
                (1, Value::Blob(b)) => self.custom[i].1 = b,
                (_, other) => panic!("kaya: a bound custom slot resolved to {other:?}"),
            }
        } else if slot < pairs + files {
            panic!("kaya: a file slot cannot bind a row field (a picked handle is not a field)");
        } else {
            let mut at = pairs + files;
            if self.image.is_some() {
                if slot == at {
                    match value {
                        Value::Blob(b) => self.image = Some(b),
                        other => panic!("kaya: a bound image slot resolved to {other:?}"),
                    }
                    return;
                }
                at += 1;
            }
            if self.html.is_some() {
                if slot == at {
                    match value {
                        Value::Str(s) => self.html = Some(s),
                        other => panic!("kaya: a bound html slot resolved to {other:?}"),
                    }
                    return;
                }
                at += 1;
            }
            if self.text.is_some() && slot == at {
                match value {
                    Value::Str(s) => self.text = Some(s),
                    other => panic!("kaya: a bound text slot resolved to {other:?}"),
                }
                return;
            }
            panic!("kaya: bound slot {slot} names no representation of this clip");
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Clip {
    pub text: Option<String>,
    pub html: Option<String>,
    pub image: Option<Blob>,
    /// The SAME capability the picker returns, so a picked file goes
    /// straight on and a pasted one opens with the call that exists.
    pub files: Vec<PickedId>,
    pub custom: Vec<(String, Blob)>,
}

/// The same clip, one step later: what a BACKEND receives. Identical to
/// [`Clip`] except in `files`, and that is why it exists — a guest names
/// a file by CAPABILITY, a backend needs the platform's own reference.
/// The core resolves handle to locator ONCE, at lowering, where the
/// picked table lives.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ClipOut {
    pub text: Option<String>,
    pub html: Option<String>,
    pub image: Option<Blob>,
    /// What the platform calls each file (PickedSource::locator).
    pub files: Vec<String>,
    pub custom: Vec<(String, Blob)>,
}

/// One representation, arriving — the sum [`Clip`] is the record of.
///
/// YOU OFFER MANY AND YOU RECEIVE ONE: a clipboard read and a paste both
/// materialise exactly one of the kinds the reader accepted, because
/// that is what every host does. `files` is plural INSIDE one
/// representation, the nesting `text/uri-list` already has.
#[derive(Debug, Clone, PartialEq)]
pub enum Representation {
    Text(String),
    Html(String),
    Image(Blob),
    Files(Vec<PickedFile>),
    Custom { id: String, bytes: Blob },
}

/// A collection: a core-side ordered key→value table, the sibling of a
/// signal, changed with delta records and rendered by a For.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct CollectionId(pub u64);

/// A template node: a blueprint entry, declared inside a For/When
/// template scope. Never on screen and never addressable alone — an
/// instance is named (template node, key path). Shares the WidgetId
/// counter (DESIGN.md, Binding conventions), so a number names exactly
/// one of the two; the wire tells them apart by path_len, never by
/// number.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct TemplateNodeId(pub u64);

/// A menu item's id: its OWN guest-allocated id space, distinct from
/// widget, node and surface ids so cross-use is a compile error where
/// the language can express it (DESIGN.md, Menus). Dispatch tables key
/// by item id. Never carries the internal bit; 0 is not an item.
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
/// out of `recv()` for work that is NOT an event. Keeping it out of
/// `Occurrence` matters: guests match that enum exhaustively.
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
    /// owns its text; there is no read-back, by doctrine.
    TextChanged { id: WidgetId, text: String },
    /// The user edited a stamped copy of a template entry.
    InstanceTextChanged { node: TemplateNodeId, path: Path, text: String },
    /// The user toggled a checkbox the guest created directly; carries
    /// the new state. Same ownership stance as TextChanged.
    Toggled { id: WidgetId, checked: bool },
    /// The user asked a veto_close window to close. Nothing has closed;
    /// the app answers with destroy_window if it agrees.
    CloseRequested { window: WindowId },
    /// A non-veto auxiliary window was closed by its chrome —
    /// informational and post-fact; destroy_window reconciles the scene
    /// (idempotent: the native window may already be gone).
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
    /// informational and post-fact. A programmatic pop_entry does not
    /// echo here: its caller already knows.
    EntryPopped { entry: WindowId },
    /// The user drove the back affordance on an entry whose
    /// intercept_back is armed. Nothing has popped; the app answers
    /// with pop_entry if it agrees — the CloseRequested veto class.
    BackRequested { entry: WindowId },
    /// The user switched sections through the platform's own switcher —
    /// informational and post-fact. A programmatic SelectSection is
    /// configuration and stays silent (the echo doctrine).
    SectionSelected { window: WindowId, section: WindowId },
    /// The user clicked a column header on a live For's table. A
    /// REQUEST: nothing has changed on screen; the guest reorders its
    /// collection by key and re-declares set_columns with the new
    /// indicator (docs/tables-plan.md). Direction cycling is guest
    /// policy, which is why none rides here.
    SortRequested { id: WidgetId, column: u32 },
    /// The header click on a stamped copy's nested table.
    InstanceSortRequested { node: TemplateNodeId, path: Path, column: u32 },
    /// A REDRAW CANVAS IS ASKED FOR ITS DRAWING AT THE SIZE IT WAS
    /// ASSIGNED (docs/canvas-plan.md §3.2.1). `size` is in
    /// device-independent points, and it is the guest's next viewbox.
    /// LATEST-WINS: a newer size REPLACES a request the guest has not
    /// answered yet, so a drag-resize storm collapses to the newest size
    /// and a slow guest cannot stuff a queue.
    DrawRequested { id: WidgetId, size: (f64, f64) },
    InstanceDrawRequested { node: TemplateNodeId, path: Path, size: (f64, f64) },
    /// A FRAME, for a canvas with an on_tick handler. `time` is in
    /// seconds and is the PLATFORM'S, never the guest's own clock —
    /// Choreographer's frame time and CADisplayLink's targetTimestamp
    /// are both fixed at schedule time, and a guest that read its own
    /// clock would re-import the jitter both removed (§15.4). Under the
    /// harness it is the core's own deterministic step, so a leg's frame
    /// count is part of the scene rather than a fact about the machine.
    Tick { id: WidgetId, size: (f64, f64), time: f64 },
    InstanceTick { node: TemplateNodeId, path: Path, size: (f64, f64), time: f64 },
    /// The user toggled a stamped copy of a template checkbox.
    InstanceToggled { node: TemplateNodeId, path: Path, checked: bool },
    /// The user moved a slider the guest created directly; one
    /// occurrence per change.
    ValueChanged { id: WidgetId, value: f64 },
    /// The user moved a stamped copy of a template slider.
    InstanceValueChanged { node: TemplateNodeId, path: Path, value: f64 },
    /// The user FINISHED a slider gesture — released the thumb, or moved it
    /// by a key — and this is the value it settled on (docs/slider-plan.md
    /// S2). One per gesture, after that gesture's ValueChanged moves.
    ValueCommitted { id: WidgetId, value: f64 },
    InstanceValueCommitted { node: TemplateNodeId, path: Path, value: f64 },
    /// The user COMMITTED a new date in a date picker the guest created
    /// directly (docs/datetime-plan.md D7): the value the control holds
    /// once the user is done, never an intermediate movement.
    DateChanged { id: WidgetId, date: Date },
    InstanceDateChanged { node: TemplateNodeId, path: Path, date: Date },
    /// The user committed a new time in a time picker.
    TimeChanged { id: WidgetId, time: Time },
    InstanceTimeChanged { node: TemplateNodeId, path: Path, time: Time },
    /// A menu action fired — clicked OR invoked through its shortcut:
    /// ONE occurrence, one dispatch path (DESIGN.md, Menus).
    MenuActivated { item: MenuItemId },
    /// A menu action fired on a node-anchored context menu: the item id
    /// plus the anchor copy's key path (the on_click_node encoding — the
    /// keys ARE the noun).
    InstanceMenuActivated { item: MenuItemId, path: Path },
    /// The user flipped a toggle item; carries the new state. A
    /// programmatic `checked` write is configuration and stays quiet.
    MenuToggled { item: MenuItemId, checked: bool },
    /// A toggle flipped on a node-anchored context menu.
    InstanceMenuToggled { item: MenuItemId, path: Path, checked: bool },
    /// The user picked a radio option; carries the group's new selected
    /// option index (the Choice contract, 0-based, integral). A
    /// programmatic `value` write is quiet.
    MenuValueChanged { group: MenuItemId, index: f64 },
    /// A radio option picked on a node-anchored context menu.
    InstanceMenuValueChanged { group: MenuItemId, path: Path, index: f64 },
    /// The privileged read's one answer, or `None` for the universal no
    /// — a denied prompt, an unfocused reader, an empty clipboard, or no
    /// accepted representation; the platforms decline to say which, so
    /// kaya does not invent a distinction. The request id retires here.
    ClipboardResult {
        request: u64,
        clip: Option<Representation>,
    },
    /// Content arriving at a widget because the USER pasted. Same
    /// payload as the read, different trigger — and free of the read's
    /// permission cost, since a gesture is its own authorisation.
    Pasted { id: WidgetId, clip: Representation },
    /// A paste onto a stamped copy of a template widget.
    InstancePasted {
        node: TemplateNodeId,
        path: Path,
        clip: Representation,
    },
    /// Content dropped on a widget (docs/dnd-plan.md D1): the paste's
    /// payload with a point in the destination's own coordinates, the
    /// operation the core settled on, and — for a reorder — the anchor
    /// row's key path and whether the drop landed before it.
    Dropped {
        id: WidgetId,
        point: (f64, f64),
        operation: u32,
        anchor: Path,
        before: bool,
        clip: Representation,
    },
    /// A drop onto a stamped copy of a template widget.
    InstanceDropped {
        node: TemplateNodeId,
        path: Path,
        point: (f64, f64),
        operation: u32,
        anchor: Path,
        before: bool,
        clip: Representation,
    },
    /// A drag that began on this widget ended, with what the destination
    /// did: a drag_op, `none` for cancelled or refused.
    DragEnded { id: WidgetId, operation: u32 },
    /// The same for a stamped copy.
    InstanceDragEnded { node: TemplateNodeId, path: Path, operation: u32 },
    /// kaya routed an undo, and this is what the CORE put back
    /// (docs/undo-plan.md D5). `label` is the group's authored name, or
    /// EMPTY for a typing episode. Applying an inverse emits nothing
    /// else, which is why this payload has to be complete.
    Undone {
        window: WindowId,
        label: String,
        delta: UndoDelta,
    },
    /// The Undone twin, same payload, opposite direction. A FRONTIER
    /// typing episode redoes natively and arrives as TextChanged.
    Redone {
        window: WindowId,
        label: String,
        delta: UndoDelta,
    },
    /// The core is gone and no further occurrences will arrive; the app
    /// loop should end. First member of the lifecycle vocabulary.
    Shutdown,
}

/// Bulk payload bytes behind a cheap handle. The bytes live once, in
/// core-owned memory; every clone is an Arc clone, so a blob bound to N
/// widgets or stamped into M rows never re-copies. The last drop frees.
/// On the wire a blob travels as its u64 registration handle; the bytes
/// never enter a record stream.
#[derive(Clone)]
pub struct Blob(pub Arc<[u8]>);

impl std::fmt::Debug for Blob {
    /// Length plus a short FNV prefix, never the bytes: round-trip tests
    /// compare Debug strings, and a bare length would false-match.
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

/// A signal, property, element-field, or key value. The scalar set plus
/// the blob handle; there is deliberately no record *value* — a
/// collection entry is a Record (one Value per schema field).
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Bool(bool),
    I64(i64),
    F64(f64),
    Str(String),
    /// Bulk payload bytes, Arc'd core memory referenced by handle on the
    /// wire. Not a key type — a blob names content, never identity.
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

/// What an undo or a redo PUT BACK: the core-authoritative statement of
/// the restored state (docs/undo-plan.md D5).
///
/// A STATEMENT, NOT A REPLAY. Every member says what a thing now IS, so
/// a mirror that applies one twice is still correct and a binding needs
/// no diffing of its own.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct UndoDelta {
    /// Signal id -> its restored value.
    pub signals: Vec<(SignalId, Value)>,
    /// Each text field this step put back. A coarse episode restore is a
    /// programmatic write, so nothing else would tell an app.
    pub texts: Vec<UndoText>,
    /// Collection entries, present or gone.
    pub entries: Vec<UndoEntry>,
    /// Instance orders, for the instances whose order the step changed
    /// — position is the one thing per-entry statements cannot carry.
    pub orders: Vec<UndoOrder>,
}

/// One text field's restored text, named the way the edit that filled it was
/// named. THE IDENTITY IS THE OCCURRENCE'S, not the core's bookkeeping: an
/// empty `path` means `id` is a live [`WidgetId`], a non-empty one that `id`
/// is the [`TemplateNodeId`] of a stamped copy. The core's internal widget id
/// for a copy never leaves the core — it changes on every restamp.
#[derive(Debug, Clone, PartialEq)]
pub struct UndoText {
    /// A widget id when `path` is empty, a template node id otherwise.
    pub id: u64,
    /// The stamped copy's key path, outermost first; empty for a live
    /// widget.
    pub path: Path,
    pub text: String,
}

/// One collection entry's restored state.
#[derive(Debug, Clone, PartialEq)]
pub struct UndoEntry {
    pub collection: CollectionId,
    /// The instance path: one key per enclosing For, empty at top level.
    pub path: Path,
    pub key: Value,
    /// The variant and record it holds, or None when the restored state
    /// does not have this entry at all.
    pub state: Option<(u32, Record)>,
}

/// One collection instance's restored key order.
#[derive(Debug, Clone, PartialEq)]
pub struct UndoOrder {
    pub collection: CollectionId,
    pub path: Path,
    pub keys: Vec<Value>,
}

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

/// The widget vocabulary (the spec's `kind` enum).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WidgetKind {
    Column,
    Button,
    Label,
    /// A single-line text field. Uncontrolled: the widget owns its text
    /// and reports edits as TextChanged; Prop::Text sets the content.
    Entry,
    /// A horizontal container: Column turned sideways.
    Row,
    /// A labeled on/off box. Prop::Text is the caption, Prop::Checked
    /// the state; user toggles report as Toggled occurrences.
    Checkbox,
    /// A continuous control over a numeric range. Prop::Value is the
    /// position, Prop::Min/Prop::Max the range (0..1 unless set); drags
    /// report as ValueChanged. Uncontrolled, like the entry.
    Slider,
    /// A displayed picture. Prop::Source carries the encoded bytes
    /// (PNG/JPEG/...) as a blob; the toolkit decodes natively.
    /// Display-only, like Label: no occurrence, no tag.
    Image,
    /// A horizontal progress bar. Display-only. Prop::Value carries the
    /// determinate fraction (0..=1, domain-checked at the root);
    /// Prop::Indeterminate switches the bar to the platform's activity
    /// mode and Value is ignored while it is on.
    Progress,
    Select,
    Radio,
    Grid,
    /// The multi-line entry: the platform's real multi-line editor, on
    /// the Entry's uncontrolled text contract.
    Textarea,
    /// A vertical scroll viewport over EXACTLY ONE child; the scene
    /// rejects a second. Vertical-only in v1. No occurrence — the
    /// position is widget-owned — and no props of its own, since
    /// Spacing/Align are container-of-many concerns. Virtualization is
    /// out (docs/deferred.md).
    Scroll,
    /// A drawing surface whose content is a PIXEL BUFFER THE CORE PRODUCED
    /// (docs/canvas-plan.md): the guest declares an op list through
    /// `set_drawing` and every backend's arm is a raw-pixel blit.
    /// Display-only, like Image. Its VIEWBOX is its natural size — the one
    /// widget whose content size is app-decided, hence no width/height prop.
    Canvas,
    /// A compact field holding a civil DATE that opens the platform's own
    /// calendar (docs/datetime-plan.md): Prop::Date the value, Prop::MinDate
    /// and Prop::MaxDate its inclusive range; a committed pick reports as
    /// DateChanged. Uncontrolled, like the slider. GTK composes it.
    DatePicker,
    /// A compact field holding a civil TIME of day (hour and minute):
    /// Prop::Time the value, Prop::MinuteStep the minute granularity; a
    /// committed pick reports as TimeChanged. No range (D4).
    TimePicker,
    /// A LABELLED ROW (docs/forms-plan.md): a label, the one control it
    /// names and, optionally, one trailing button. The pairing is a
    /// semantic fact — assistive technology gets the label-for relation,
    /// and a backend lowers the pair to its native labelled control; a
    /// column of nothing but these is a FORM, derived. The root holds the
    /// shape at the end of the transaction. No occurrence, no tag.
    Labeled,
}

/// A civil calendar date, the value a date picker holds
/// (docs/datetime-plan.md D2): proleptic Gregorian, no zone, no instant.
/// On the wire it is ONE I64, `year * 10000 + month * 100 + day`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Date {
    pub year: i32,
    pub month: u8,
    pub day: u8,
}

impl Date {
    pub fn new(year: i32, month: u8, day: u8) -> Result<Date, String> {
        let d = Date { year, month, day };
        d.check()?;
        Ok(d)
    }

    fn check(self) -> Result<(), String> {
        if !(1..=12).contains(&self.month) {
            return Err(format!("month {} is not in 1..=12", self.month));
        }
        let days = Self::days_in_month(self.year, self.month);
        if self.day == 0 || self.day > days {
            return Err(format!(
                "{}-{:02} has {} days, not {}",
                self.year, self.month, days, self.day
            ));
        }
        if !(1..=9999).contains(&self.year) {
            return Err(format!("year {} is not in 1..=9999", self.year));
        }
        Ok(())
    }

    pub fn days_in_month(year: i32, month: u8) -> u8 {
        match month {
            1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
            4 | 6 | 9 | 11 => 30,
            2 => {
                if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 {
                    29
                } else {
                    28
                }
            }
            _ => 0,
        }
    }

    /// The wire form: packed decimal.
    pub fn packed(self) -> i64 {
        self.year as i64 * 10_000 + self.month as i64 * 100 + self.day as i64
    }

    /// The wire form read back, refusing anything that is not a date.
    pub fn from_packed(packed: i64) -> Result<Date, String> {
        if !(1_0101..=9999_1231).contains(&packed) {
            return Err(format!("{packed} is not a packed date (YYYYMMDD)"));
        }
        let year = (packed / 10_000) as i32;
        let month = ((packed / 100) % 100) as u8;
        let day = (packed % 100) as u8;
        Date::new(year, month, day).map_err(|why| format!("{packed}: {why}"))
    }
}

impl std::fmt::Display for Date {
    /// The fixed-digit spelling every scene reads: `2026-09-04`.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:04}-{:02}-{:02}", self.year, self.month, self.day)
    }
}

impl std::str::FromStr for Date {
    type Err = String;
    fn from_str(s: &str) -> Result<Date, String> {
        let parts: Vec<&str> = s.split('-').collect();
        if parts.len() != 3 || parts[0].len() != 4 || parts[1].len() != 2 || parts[2].len() != 2 {
            return Err(format!("{s:?} is not a date (YYYY-MM-DD)"));
        }
        let n = |p: &str| p.parse::<u32>().map_err(|_| format!("{s:?} is not a date (YYYY-MM-DD)"));
        Date::new(n(parts[0])? as i32, n(parts[1])? as u8, n(parts[2])? as u8)
    }
}

/// A civil time of day, the value a time picker holds: hour and minute,
/// no seconds (docs/datetime-plan.md D3). On the wire ONE I64,
/// `hour * 100 + minute`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Time {
    pub hour: u8,
    pub minute: u8,
}

impl Time {
    pub fn new(hour: u8, minute: u8) -> Result<Time, String> {
        if hour > 23 {
            return Err(format!("hour {hour} is not in 0..=23"));
        }
        if minute > 59 {
            return Err(format!("minute {minute} is not in 0..=59"));
        }
        Ok(Time { hour, minute })
    }

    pub fn packed(self) -> i64 {
        self.hour as i64 * 100 + self.minute as i64
    }

    pub fn from_packed(packed: i64) -> Result<Time, String> {
        if !(0..=2359).contains(&packed) {
            return Err(format!("{packed} is not a packed time (HHMM)"));
        }
        Time::new((packed / 100) as u8, (packed % 100) as u8).map_err(|why| format!("{packed}: {why}"))
    }
}

impl std::fmt::Display for Time {
    /// The fixed-digit spelling every scene reads: `14:30`.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:02}:{:02}", self.hour, self.minute)
    }
}

impl std::str::FromStr for Time {
    type Err = String;
    fn from_str(s: &str) -> Result<Time, String> {
        let (h, m) = s.split_once(':').ok_or_else(|| format!("{s:?} is not a time (HH:MM)"))?;
        if h.len() != 2 || m.len() != 2 {
            return Err(format!("{s:?} is not a time (HH:MM)"));
        }
        let n = |p: &str| p.parse::<u8>().map_err(|_| format!("{s:?} is not a time (HH:MM)"));
        Time::new(n(h)?, n(m)?)
    }
}

impl From<Date> for Value {
    fn from(d: Date) -> Value {
        Value::I64(d.packed())
    }
}

impl From<Time> for Value {
    fn from(t: Time) -> Value {
        Value::I64(t.packed())
    }
}

impl WidgetKind {
    /// Every kind, for the sweeps that must not miss one. Pinned to the
    /// spec's own `kind` enum by
    /// `spec::tests::all_widget_kinds_are_the_spec_s_kinds` (invariant 7).
    /// `pub(crate)`, not `pub`: a `pub` associated const makes cbindgen
    /// export `WidgetKind` into the public header as an opaque handle no C
    /// caller can use. `cfg(test)` because the sweeps that walk it are tests.
    #[cfg(test)]
    pub(crate) const ALL: [WidgetKind; 18] = [
        WidgetKind::Column,
        WidgetKind::Button,
        WidgetKind::Label,
        WidgetKind::Entry,
        WidgetKind::Row,
        WidgetKind::Checkbox,
        WidgetKind::Slider,
        WidgetKind::Image,
        WidgetKind::Scroll,
        WidgetKind::Progress,
        WidgetKind::Select,
        WidgetKind::Radio,
        WidgetKind::Grid,
        WidgetKind::Textarea,
        WidgetKind::Canvas,
        WidgetKind::DatePicker,
        WidgetKind::TimePicker,
        WidgetKind::Labeled,
    ];

    /// Whether a widget of this kind carries an identity tag — the
    /// pre-encoded occurrence body a backend emits verbatim when the
    /// control reports. THE INTERACTIVE KINDS DO; the display and
    /// container kinds have nothing to report.
    ///
    /// ONE predicate, read by both the live and the stamped callsite —
    /// as two matches they drifted (docs/sugar-pass-plan.md D1).
    pub(crate) fn carries_tag(self) -> bool {
        match self {
            WidgetKind::Button
            | WidgetKind::Entry
            | WidgetKind::Textarea
            | WidgetKind::Checkbox
            | WidgetKind::Slider
            | WidgetKind::Select
            | WidgetKind::Radio
            | WidgetKind::DatePicker
            | WidgetKind::TimePicker => true,
            // Exhaustive on purpose — no wildcard. A kind added to the
            // spec lands here as a compile error, which is the moment to
            // decide whether it reports.
            WidgetKind::Column
            | WidgetKind::Row
            | WidgetKind::Label
            | WidgetKind::Image
            | WidgetKind::Scroll
            | WidgetKind::Progress
            | WidgetKind::Canvas
            | WidgetKind::Grid
            | WidgetKind::Labeled => false,
        }
    }
}

/// The menu item vocabulary (spec enum "menu_kind"; DESIGN.md, Menus).
/// `menu` and `radio_group` are the grouping nodes, the rest are leaves.
/// One vocabulary, two anchors — the anchor decides the spelling.
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
    /// backend cannot quietly disagree about which chords exist
    /// (docs/traps.md).
    pub fn takes_shortcut(self) -> bool {
        matches!(
            self,
            MenuItemKind::Action | MenuItemKind::Toggle | MenuItemKind::RadioOption
        )
    }
}

/// Value accessors for a prop apply. The ROOT validated every (prop,
/// value) pairing, so a backend matches EXHAUSTIVELY over the prop enum
/// and reads the value through these: a new prop then fails to COMPILE
/// in every backend instead of reaching a catch-all and panicking at
/// runtime (docs/traps.md).
// Their callers are the cfg'd NATIVE backends, so a mac-native build
// sees no use at all.
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

/// Menu property keys (spec::MENU_PROPS; DESIGN.md, Menus). `label` and
/// `enabled` apply to every kind but `separator`; `checked` is
/// toggle-only, `value` radio-group-only; `primary` and `role` are
/// action-only, `shortcut` rides any leaf command. `label`, `enabled`,
/// `checked` and `value` are signal-bindable; the rest are const-only.
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
    /// The item's SEMANTIC ICON NAME (I64-valued, the spec's "symbol"
    /// enum; docs/styling-plan.md D6). A concept, never bytes: each
    /// backend maps it to its own platform's symbol set. Const-only, and
    /// it sits BESIDE `Icon` rather than replacing it — a blob is still
    /// the right primitive for app-specific art.
    Symbol,
}

/// Which materialized attachment a backend's menu native belongs to:
/// one window's bar, or one context anchor's flyout. A template context
/// catalog attaches the SAME item ids to every stamped copy, so an item
/// id alone never identifies a native. A backend with a flat native map
/// keys it by `(MenuAttachment, item id)` (WinUI); GTK reaches the same
/// invariant with per-attachment action instances.
#[cfg(any(target_os = "windows", test))]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MenuAttachment {
    /// The window catalog attachment (the bar), by window id.
    Window(u64),
    /// A context catalog attachment, by anchor widget id.
    Context(u64),
}

/// Destroying a context anchor takes its materialized natives with it
/// (menu ITEMS are never destroyed; the attachment's instances are): a
/// detached native still raises Click through its automation peer
/// (docs/traps.md), so a surviving entry would stay invoke-capable with
/// the dead copy's noun. Every other attachment's natives survive.
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
    /// A date picker's value (I64-valued on the wire: a packed civil date,
    /// PropKind::Date — docs/datetime-plan.md D2).
    Date,
    /// A time picker's value (I64-valued: a packed hour and minute).
    Time,
    /// A date picker's inclusive range (packed dates).
    MinDate,
    MaxDate,
    /// A time picker's minute granularity (F64-valued count: 1, 5, 10,
    /// 15 or 30; docs/datetime-plan.md D3).
    MinuteStep,
    Step,
    TickSpacing,
    Help,
    /// A child's cross-axis stretch (Bool-valued): spans its container's
    /// cross axis, or hugs; unset leaves the kind's default
    /// (docs/layout-knobs-plan.md §1).
    Fill,
    /// A grid's minimum column width when its `columns` is 0, auto
    /// (F64-valued, DIP; docs/layout-knobs-plan.md §3).
    MinColumnWidth,
    /// An image's encoded source bytes (Blob-valued).
    Source,
    /// A container's inter-child gap on its main axis (F64-valued, DIP;
    /// finite, non-negative; the normalized default is 8). A property OF
    /// the container, unlike grow, which rides the child.
    Spacing,
    /// A container's cross-axis child placement (I64-valued on the
    /// wire: one of the `align` spec enum's values — start 0, center
    /// 1, end 2, stretch 3, baseline 4). Baseline is rows-only; the
    /// scene rejects it on columns.
    Align,
    /// A child's flex-grow weight within its row/column (F64-valued; 0 =
    /// natural size, the default). Kind-agnostic.
    ///
    /// Weight-0 children take their natural main-axis size and the growers
    /// divide the LEFTOVER in proportion to their weights, a grower's own
    /// natural size not entering it — CSS `flex-basis: 0`, uniform on every
    /// backend, constructed explicitly where there is no native weight.
    Grow,
    /// Progress-only (Bool): the bar shows activity without a
    /// fraction — the platform's pulse/animation mode; Value is
    /// ignored while it is on.
    Indeterminate,
    /// Grid-only (F64, integral >= 1): how many columns children
    /// fill row-major. Columns take their NATURAL width, aligned
    /// across rows — the thing nested rows cannot express.
    Columns,
    /// The accessibility IDENTIFIER (Str): a stable authored key, NEVER
    /// spoken — accessibilityIdentifier, testTag, AutomationId are the
    /// same idea. A product surface rather than test plumbing; kaya's
    /// harness is only its first consumer.
    A11yId,
    /// The accessibility LABEL (Str): what an assistive client SPEAKS.
    /// Separate from [`Prop::A11yId`] on purpose — conflating them would
    /// read every automation key aloud to screen-reader users.
    A11yLabel,
    /// What activating this control does — the platforms' hint, which
    /// every one of them defines as the result of an ACTION.
    A11yHint,
    /// Which clip representations this widget accepts (Str carrying a
    /// space-separated ACCEPT LIST — the closed kinds by name plus any
    /// custom ids; a mask could name nothing open). PER-WIDGET, because
    /// whether Paste should be live is the intersection of what the
    /// clipboard offers and what the focused target takes, which is
    /// exactly what every platform asks of the focused target.
    Accepts,
    /// SEMANTIC EMPHASIS (docs/styling-plan.md D4): what this widget
    /// MEANS — destructive, prominent, heading — never how it looks.
    /// U32-valued from the closed role enum; which variant fits which
    /// KIND is the root's value-dependent check.
    Role,
    /// A CONTAINER'S OWN PADDING (docs/styling-plan.md D3, one level
    /// down from the window inset): DIP between the container's bounds
    /// and its children, uniform on all four sides. LAYOUT beside
    /// grow/spacing/align, carried by the spacing kinds — a leaf has no
    /// children to hold away from its edge. Spelled in BOTH construction
    /// zones: a stamped row needs it as much as a live one.
    Inset,
    /// The container's arrangement axis (docs/adaptive-layout-plan.md
    /// D1/D2): row and column are one node this parameterizes, and the
    /// prop is mutable so a breakpoint diff or a handler toggle is an
    /// ordinary property write.
    Axis,
}

/// The leading pane's width for a list-detail split: a FRACTION of the
/// window, clamped. Not half, and the numbers are adopted rather than
/// invented — libadwaita states the rule for AdwNavigationSplitView (25% of
/// the total, min 180, max 280), Apple's NavigationSplitView behaves the same
/// way, and Material gives the list a preferred width.
#[cfg_attr(
    // WinUI only: libadwaita sizes its own sidebar from the rule this
    // function encodes, while TwoPaneView's default is two EQUAL panes.
    // The tests exercise it everywhere.
    not(any(target_os = "windows", test)),
    allow(dead_code)
)]
pub(crate) fn leading_pane_width(total: f64) -> f64 {
    (total * 0.25).clamp(180.0, 280.0).min(total)
}

/// Window property keys — the presentation-context twin of [`Prop`],
/// separate because windows are not widgets (DESIGN.md, Presentation
/// contexts). Window 0 is the primary surface and always exists.
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
    /// [`SectionsPresentation`]; default Auto). ADVISORY: honored where
    /// the platform has the idiom, resolved to the nearest thing
    /// otherwise. Window-scoped because the GROUP is the unit
    /// (DESIGN.md, Sections).
    SectionsPresentation,
    /// The CEILING of side-by-side stack surfaces this window asks for
    /// (I64-valued, 1-3; DESIGN.md, Adaptive panes). 1 is the serial
    /// stack navigation has always had; 2 list-detail; 3
    /// sidebar/content/detail. How many of them FIT is the platform's
    /// re-decision at every width — there is deliberately no prop for a
    /// threshold or for WHICH panes survive: the stack order is the
    /// priority.
    Panes,
    /// Whether this surface holds UNSAVED WORK (Bool-valued; default false;
    /// docs/dirty-plan.md D1). State, never chrome: each backend spells its
    /// platform's own affordance (D2) and the title string is untouched.
    /// It arms nothing (D3), and macOS attaches no behavior to the flag
    /// either (docs/probes/dirty-probe-mac.md).
    Dirty,
    /// The window CONTENT INSET in layout units (F64-valued) — LAYOUT,
    /// not appearance (docs/styling-plan.md D3): the space kaya's own
    /// interpreters put around the mounted root. Defaults to 16; 0 is
    /// full bleed, honored unconditionally. Platform safe areas are
    /// separate facts and are not removed by it.
    Inset,
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
    /// The switcher item's SEMANTIC ICON NAME (I64-valued, the spec's
    /// "symbol" enum; docs/styling-plan.md D6) — the names-not-bytes half
    /// of the same slot.
    Symbol,
}

/// Navigation-entry property keys (spec::ENTRY_PROPS; DESIGN.md,
/// Navigation): a wrong-surface prop dies at compile time in every
/// binding rather than at the scene. Entries share the surface-id
/// namespace with windows, so [`WindowId`] carries entry ids too.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EntryProp {
    /// The entry's title (Str-valued): the back affordance's label
    /// source — the iOS back button, the desktop headers.
    Title,
    /// The close-veto class transplanted to POP (Bool-valued; default
    /// false). False: the platform pops natively with its predictive
    /// animation. True: the back affordance emits back_requested and
    /// nothing pops until the app answers with pop_entry — Android's own
    /// declared-ahead model, not veto-at-gesture-time.
    InterceptBack,
}

/// The one-shot command vocabulary: momentary verbs aimed at
/// widget-owned state, the third arm of the ownership rule.
/// Fire-and-forget — no state at rest, nothing replays on instance
/// rebuild, and the widget reports the result through its normal
/// occurrence path. A closed set.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CommandKind {
    /// Drop an entry's content now (the widget stays authoritative and
    /// answers with a TextChanged carrying the empty text).
    Clear,
    /// Give the widget the keyboard focus.
    Focus,
}

/// A span of a text widget's content, in UTF-8 BYTE offsets into the widget's
/// current guest-visible text — the unit the guest speaks. `start <= end`;
/// `start == end` is a caret. THE SIBLING TYPE [`NativeRange`] IS THE POINT
/// OF BOTH: every backend counts something else (UTF-16 code units, code
/// points on GTK) and the core converts before it lowers, so two types make
/// that conversion impossible to skip.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TextRange {
    pub start: u64,
    pub stop: u64,
}

impl TextRange {
    pub fn new(start: u64, stop: u64) -> Self {
        Self { start, stop }
    }
}

/// A span already converted into the unit THIS BUILD'S backend counts
/// (see [`TextRange`]). Never constructed by a guest, never decoded from
/// the tx wire: the only way to make one is the core's conversion
/// against the text it validated the byte offsets against.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NativeRange {
    pub start: u64,
    pub stop: u64,
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
/// template-node space. Outside a scope they create live things.
#[derive(Debug)]
pub enum TxOp {
    /// Mark this transaction as ONE undoable step in `window`'s ledger.
    /// MUST BE THE FIRST OP OF THE BATCH and may appear once
    /// (docs/undo-plan.md D2). A marked batch holds signal writes and
    /// collection deltas; focus is permitted and not restored; anything
    /// else is refused at apply, naming the op.
    UndoGroup { window: WindowId, label: String },
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
    /// Request the platform's save dialog: the picker's grammar, one
    /// id space, one live slot, and the same FileDialogResult back
    /// carrying one file or none (docs/save-plan.md D2).
    ShowSaveDialog(SaveDialogSpec),
    /// REQUEST the app's brand accent (docs/styling-plan.md D1/D2):
    /// `seed` packed sRGB, plus the optional per-appearance author
    /// overrides. Set once, before the first mount — the root refuses a
    /// second or late write. The core derives; backends receive values.
    SetBrandAccent {
        seed: u32,
        light: Option<u32>,
        dark: Option<u32>,
    },
    /// REQUEST the app's brand typeface (docs/styling-plan.md Slice 2b):
    /// a default family, the per-platform overrides, optionally a font
    /// file's bytes. Set once, before the first mount — the accent's wall
    /// verbatim. The core resolves NOTHING.
    SetBrandTypeface(TypefaceRequest),
    /// DECLARE the app's identity (docs/app-identity-plan.md). Set once,
    /// before the first mount — the brand's walls verbatim. The core
    /// inspects the bytes no more than it inspects a font's.
    SetAppIdentity(AppIdentity),
    /// Put one clip on the system clipboard.
    Copy(Clip),
    /// Read the clipboard outside any paste gesture — the privileged
    /// one; see the spec record for what the platforms charge.
    ReadClipboard { request: u64, accepting: String },
    /// Push a navigation entry onto `window`'s stack (no capability
    /// gate). Materializes covered/incoming; mounting a root into it
    /// presents it. The covered root below stays alive until popped.
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
    /// Declare a collection with its schema: one ordered field-type list
    /// per variant of the element sum. Mandatory — a record collection is
    /// the one-variant case, not a separate mode. Variants are indices;
    /// variant names never travel, like field names.
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
    /// the discriminant the guest WITNESSED in the match that produced
    /// this write — never a way to change it — and the scene asserts it
    /// against the entry's stored variant, so a drifted binding fails
    /// loudly instead of writing the wrong constructor's field.
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
    /// A one-shot command aimed at a live widget. Live-zone targets only
    /// for now: a live id can only vanish by the guest's own hand, so a
    /// missing target is misuse and fails loudly, like SetProperty.
    WidgetCommand { widget: WidgetId, command: CommandKind },
    /// DECLARE this textarea's decorated ranges, replacing the previous
    /// set; an empty list is the clear. Byte offsets, validated at
    /// apply against the widget's current text and never tracked
    /// afterwards (docs/ranges-plan.md D1/D2).
    HighlightRanges { widget: WidgetId, ranges: Vec<TextRange> },
    /// Put the textarea's selection at one range (a caret when empty).
    /// Refused by the backend during an input-method composition (D4).
    SelectRange { widget: WidgetId, range: TextRange },
    /// Scroll a range into the textarea's viewport. A pure effect:
    /// undo does not restore it (docs/undo-plan.md A2).
    RevealRange { widget: WidgetId, range: TextRange },
    /// A DECLARED BREAKPOINT (docs/adaptive-layout-plan.md D3; size classes
    /// ruled 2026-08-31): while the window's SIZE CLASS equals `when`
    /// (wire::SIZE_CLASS_COMPACT alone today) the setters apply, and leaving
    /// the class they auto-revert to the guest-authored value or the kind's
    /// default. THE CORE EVALUATES, never a platform's breakpoint machinery;
    /// setters are limited to the ruled list (axis alone today).
    CreateBreakpoint {
        window: WindowId,
        when: i64,
        setters: Vec<(WidgetId, Prop, Value)>,
    },
    /// DECLARE the column header bar on a For's container, replacing the
    /// previous declaration; `sorted` is a 0-based index or SORT_NONE,
    /// `direction` 0 asc / 1 desc (docs/tables-plan.md). `widget` is a live
    /// For's container (path empty) or a nested For's TEMPLATE NODE — path
    /// empty declares every copy's bar, keys outermost-first re-declare ONE
    /// stamped copy's.
    SetColumnHeaders {
        widget: WidgetId,
        sorted: u32,
        direction: u32,
        path: Vec<Value>,
        titles: Vec<String>,
    },
    /// DECLARE that a widget can be dragged and what it hands over
    /// (docs/dnd-plan.md D1): a clip plus a mask over the drag_op enum. An
    /// empty clip withdraws it. `path` keys address a stamped copy; inside
    /// a For's body `bound` names the clip slots that are the row's own
    /// fields (docs/dnd-plan.md §4), each resolved per stamped copy.
    SetDragSource {
        widget: WidgetId,
        clip: Clip,
        bound: Vec<BoundRep>,
        operations: u32,
        path: Vec<Value>,
    },
    /// DECLARE that a widget receives drops with the given operation mask
    /// (what it accepts is its `accepts` prop). Zero withdraws it.
    SetDropTarget { widget: WidgetId, operations: u32, path: Vec<Value> },
    /// Make a live For's rows draggable within their own collection
    /// (docs/dnd-plan.md D8); the drop reports an anchor and the app
    /// confirms with collection_move.
    SetReorderable { container: WidgetId, enabled: u32 },
    /// DECLARE the whole drawing on a canvas, replacing the previous
    /// declaration (docs/canvas-plan.md §3.1). `viewbox` is the coordinate
    /// system the ops are written in AND the canvas's natural size in points;
    /// `ops` is the flat opcode-then-operands run. `widget` is a live canvas
    /// (path empty) or a canvas TEMPLATE NODE, addressed exactly as
    /// set_column_headers is.
    SetDrawing {
        widget: WidgetId,
        viewbox: (f64, f64),
        path: Vec<Value>,
        ops: Vec<Value>,
    },
    /// WHAT THIS CANVAS DOES WITH A TRACK THAT IS NOT ITS VIEWBOX
    /// (docs/canvas-plan.md §3.2.1). `scale` is the default and needs no
    /// record; the other three are what a guest's declaration lowers to
    /// — `fixed` from the property, `redraw` from an on_draw handler,
    /// `tick` from an on_tick one.
    SetSizePolicy { widget: WidgetId, policy: u32 },
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
    /// Present the platform's real save dialog (already validated).
    PresentSaveDialog(SaveDialogSpec),
    /// Put this clip on the system clipboard. The backend owns the
    /// lowering per representation — CF_HTML's offset header, a
    /// content:// URI, CF_HDROP's struct — which is the whole reason the
    /// representation set is closed.
    Copy(ClipOut),
    /// Answer a privileged read with the first accepted representation.
    ReadClipboard { request: u64, accepting: String },
    /// Reset the NATIVE undo history of whatever editable holds the
    /// keyboard focus in this window; do nothing if that is nothing.
    /// Targetless because the core does not know what is focused and by
    /// doctrine never will (docs/undo-plan.md A1).
    ClearUndo { window: WindowId },
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
    /// The stacked fold (docs/adaptive-layout-plan.md D7): render `child`
    /// inside grown table `table`'s viewport as scroll-away content above
    /// row 0, in sibling order; `table` 0 restores it. Derived by the
    /// core from a `stack_when` row's own shape — no guest spells it —
    /// and identity does not move: the child keeps its parent and its
    /// addressing, only where it renders changes.
    Fold { child: WidgetId, table: WidgetId },
    Mount { window: WindowId, root: WidgetId },
    /// Reposition `child` among `parent`'s children: before the
    /// sibling `before`, or to the end when None.
    MoveChild { parent: WidgetId, child: WidgetId, before: Option<WidgetId> },
    /// Remove the widget from its parent and forget it. The core emits
    /// one Destroy per widget of a torn-down instance, children before
    /// parents, so backends never walk anything.
    Destroy { id: WidgetId },
    /// Execute a one-shot command on the widget, then let it report the
    /// result through its normal occurrence path — a clear arrives back
    /// as TextChanged with empty text, through the same delegate a
    /// keystroke uses.
    Command { id: WidgetId, command: CommandKind },
    /// REPLACE the widget's decorated set with these ranges — already in
    /// this build's native unit — and record the widget's text as it is
    /// at this moment, painting the set only while the widget still
    /// holds that text (the spec's lowering contract; docs/ranges-plan.md
    /// D2). An empty list clears.
    HighlightRanges { id: WidgetId, ranges: Vec<NativeRange> },
    /// Move the selection, in native units. REFUSED while an
    /// input-method composition is active on the widget, under the
    /// reason `ime_composition` — a silent no-op, never a panic, because
    /// the app cannot see composition state and so cannot avoid it (D4).
    SelectRange { id: WidgetId, range: NativeRange },
    /// Scroll the range into the widget's viewport, in native units.
    RevealRange { id: WidgetId, range: NativeRange },
    /// The column header bar on the For's live container — titles in visual
    /// order, the indicator on `sorted` (SORT_NONE for none), `direction` 0
    /// asc / 1 desc. Table presentation where the size class and platform
    /// have the idiom; a synthesized header or, on compact, none, where they
    /// do not. Header clicks hand `tag` to kaya_emit_sort_requested verbatim
    /// with the column index. Nothing here reorders (docs/tables-plan.md).
    SetColumnHeaders { id: WidgetId, sorted: u32, direction: u32, titles: Vec<String>, tag: Vec<u8> },
    /// Install the platform's drag source over this payload on a live
    /// widget; `tag` goes back verbatim through kaya_emit_drag_ended.
    SetDragSource { id: WidgetId, clip: ClipOut, operations: u32, tag: Vec<u8> },
    /// Register a live widget as a platform drop destination; the backend
    /// asks kaya_drag_verdict at every hover and drop, and hands `tag` to
    /// kaya_emit_dropped verbatim.
    SetDropTarget { id: WidgetId, operations: u32, tag: Vec<u8> },
    /// Rows of this live For reorder within their collection in the
    /// platform's own idiom; a landing reports through kaya_emit_dropped
    /// with the row's tag and the anchor row's tag.
    SetReorderable { id: WidgetId, enabled: u32, tag: Vec<u8> },
    /// THE RASTER a canvas's declaration produced (docs/canvas-plan.md
    /// §1.1): `width` x `height` PREMULTIPLIED RGBA8 device pixels at
    /// `scale`, so the logical size is width/scale by height/scale. The
    /// backend blits; it interprets no op and owns no drawing API.
    /// Re-emitted on a new declaration, a scale report or an appearance
    /// flip. A zero-sized buffer means declared-and-empty: the node
    /// stays present with no picture (tools/check-empty-child.py).
    SetDrawing { id: WidgetId, width: u32, height: u32, scale: f64, pixels: Blob },
    /// The brand accent, DERIVED (docs/styling-plan.md D1): the seed —
    /// for Material, the one platform whose own derivation kaya defers
    /// to — plus per-appearance values no backend re-computes. Emitted
    /// once, before the first mount's ops.
    SetBrand {
        accent: crate::brand::BrandAccent,
    },
    /// The brand typeface, as requested and unresolved (Slice 2b): the
    /// backend picks its platform's row, registers the blob with its
    /// platform's app-font API when one rode along, gates on the family
    /// being installed, and substitutes it into its own type ramp.
    /// Emitted once, before the first mount's ops.
    SetTypeface(TypefaceRequest),
    /// The app's identity, as declared (docs/app-identity-plan.md): the
    /// backend hands the icon's bytes to its own platform's decoder and
    /// routes the result to that platform's identity sinks. Emitted
    /// once, before the first mount's ops.
    SetAppIdentity(AppIdentity),
}

/// Where occurrences go: the Rust API consumes over mpsc, the C ABI over
/// the byte-record ring. One consumer either way.
#[derive(Clone)]
pub(crate) enum OccSink {
    Mpsc(std::sync::mpsc::Sender<Inbox>),
    Ring(std::sync::Arc<crate::ring::OccRing>),
}

impl OccSink {
    // Dead on the interpreter platforms, where occurrences enter through
    // the C API's typed emit entries instead.
    #[cfg_attr(
        any(target_os = "macos", target_os = "ios", target_os = "android"),
        allow(dead_code)
    )]
    pub(crate) fn send(&self, occurrence: Occurrence) {
        match self {
            OccSink::Mpsc(tx) => {
                crate::stall::enqueued();
                let _ = tx.send(Inbox::Occ(occurrence));
            }
            OccSink::Ring(ring) => match occurrence {
                Occurrence::FileDialogResult { dialog, files } => {
                    let body = crate::wire::file_dialog_result_body(dialog, &files);
                    ring.push_record(crate::ring::REC_FILE_DIALOG_RESULT, &body);
                }
                Occurrence::ClipboardResult { request, clip } => {
                    let body = crate::wire::clipboard_result_body(request, clip.as_ref());
                    ring.push_record(crate::ring::REC_CLIPBOARD_RESULT, &body);
                }
                Occurrence::Pasted { id, clip } => {
                    let tag = crate::wire::click_tag(id.0, &[]);
                    ring.push_record(crate::ring::REC_PASTED, &crate::wire::pasted_body(&tag, &clip));
                }
                Occurrence::InstancePasted { node, path, clip } => {
                    let tag = crate::wire::click_tag(node.0, &path);
                    ring.push_record(crate::ring::REC_PASTED, &crate::wire::pasted_body(&tag, &clip));
                }
                Occurrence::Dropped { id, point, operation, anchor, before, clip } => {
                    let tag = crate::wire::click_tag(id.0, &[]);
                    let body = crate::wire::dropped_body(&tag, point, operation, &anchor, before, &clip);
                    ring.push_record(crate::ring::REC_DROPPED, &body);
                }
                Occurrence::InstanceDropped { node, path, point, operation, anchor, before, clip } => {
                    let tag = crate::wire::click_tag(node.0, &path);
                    let body = crate::wire::dropped_body(&tag, point, operation, &anchor, before, &clip);
                    ring.push_record(crate::ring::REC_DROPPED, &body);
                }
                Occurrence::DragEnded { id, operation } => {
                    let tag = crate::wire::click_tag(id.0, &[]);
                    ring.push_record(crate::ring::REC_DRAG_ENDED, &crate::wire::drag_ended_body(&tag, operation));
                }
                Occurrence::InstanceDragEnded { node, path, operation } => {
                    let tag = crate::wire::click_tag(node.0, &path);
                    ring.push_record(crate::ring::REC_DRAG_ENDED, &crate::wire::drag_ended_body(&tag, operation));
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
                Occurrence::DateChanged { id, date } => {
                    let tag = crate::wire::click_tag(id.0, &[]);
                    let body = crate::wire::date_changed_body(&tag, date.packed());
                    ring.push_record(crate::ring::REC_DATE_CHANGED, &body);
                }
                Occurrence::InstanceDateChanged { node, path, date } => {
                    let tag = crate::wire::click_tag(node.0, &path);
                    let body = crate::wire::date_changed_body(&tag, date.packed());
                    ring.push_record(crate::ring::REC_DATE_CHANGED, &body);
                }
                Occurrence::TimeChanged { id, time } => {
                    let tag = crate::wire::click_tag(id.0, &[]);
                    let body = crate::wire::time_changed_body(&tag, time.packed());
                    ring.push_record(crate::ring::REC_TIME_CHANGED, &body);
                }
                Occurrence::InstanceTimeChanged { node, path, time } => {
                    let tag = crate::wire::click_tag(node.0, &path);
                    let body = crate::wire::time_changed_body(&tag, time.packed());
                    ring.push_record(crate::ring::REC_TIME_CHANGED, &body);
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
                Occurrence::ValueCommitted { id, value } => {
                    let tag = crate::wire::click_tag(id.0, &[]);
                    let body = crate::wire::value_committed_body(&tag, value);
                    ring.push_record(crate::ring::REC_VALUE_COMMITTED, &body);
                }
                Occurrence::InstanceValueCommitted { node, path, value } => {
                    let tag = crate::wire::click_tag(node.0, &path);
                    let body = crate::wire::value_committed_body(&tag, value);
                    ring.push_record(crate::ring::REC_VALUE_COMMITTED, &body);
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
                Occurrence::SortRequested { id, column } => {
                    let tag = crate::wire::click_tag(id.0, &[]);
                    ring.push_record(
                        crate::ring::REC_SORT_REQUESTED,
                        &crate::wire::sort_body(&tag, column),
                    );
                }
                Occurrence::InstanceSortRequested { node, path, column } => {
                    let tag = crate::wire::click_tag(node.0, &path);
                    ring.push_record(
                        crate::ring::REC_SORT_REQUESTED,
                        &crate::wire::sort_body(&tag, column),
                    );
                }
                Occurrence::DrawRequested { id, size } => {
                    let body = crate::wire::draw_body(id.0, &[], size, None);
                    ring.push_record(crate::ring::REC_DRAW_REQUESTED, &body);
                }
                Occurrence::InstanceDrawRequested { node, path, size } => {
                    let body = crate::wire::draw_body(node.0, &path, size, None);
                    ring.push_record(crate::ring::REC_DRAW_REQUESTED, &body);
                }
                Occurrence::Tick { id, size, time } => {
                    let body = crate::wire::draw_body(id.0, &[], size, Some(time));
                    ring.push_record(crate::ring::REC_TICK, &body);
                }
                Occurrence::InstanceTick { node, path, size, time } => {
                    let body = crate::wire::draw_body(node.0, &path, size, Some(time));
                    ring.push_record(crate::ring::REC_TICK, &body);
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
                Occurrence::Undone { window, label, delta } => {
                    let body = crate::wire::undo_body(window, &label, &delta);
                    ring.push_record(crate::ring::REC_UNDONE, &body);
                }
                Occurrence::Redone { window, label, delta } => {
                    let body = crate::wire::undo_body(window, &label, &delta);
                    ring.push_record(crate::ring::REC_REDONE, &body);
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
                crate::stall::enqueued();
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
                crate::stall::enqueued();
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

    /// The same fast path for a column-header click: the stored sort
    /// tag plus the column index, patched into the tag's reserved slot
    /// (the sort_requested record IS a click tag with `column` where
    /// `reserved` sits).
    pub(crate) fn send_sort_tag(&self, tag: &[u8], column: u32) {
        match self {
            OccSink::Mpsc(tx) => {
                crate::stall::enqueued();
                let _ = tx.send(Inbox::Occ(crate::wire::decode_sort_tag(tag, column)));
            }
            OccSink::Ring(ring) => {
                ring.push_record(
                    crate::ring::REC_SORT_REQUESTED,
                    &crate::wire::sort_body(tag, column),
                );
            }
        }
    }

    /// The same fast path for a picker's committed date / time: the
    /// stored tag plus the packed value (docs/datetime-plan.md D2).
    pub(crate) fn send_date_tag(&self, tag: &[u8], packed: i64) {
        match self {
            OccSink::Mpsc(tx) => {
                crate::stall::enqueued();
                let _ = tx.send(Inbox::Occ(crate::wire::decode_date_changed_tag(tag, packed)));
            }
            OccSink::Ring(ring) => {
                ring.push_record(
                    crate::ring::REC_DATE_CHANGED,
                    &crate::wire::date_changed_body(tag, packed),
                );
            }
        }
    }

    pub(crate) fn send_time_tag(&self, tag: &[u8], packed: i64) {
        match self {
            OccSink::Mpsc(tx) => {
                crate::stall::enqueued();
                let _ = tx.send(Inbox::Occ(crate::wire::decode_time_changed_tag(tag, packed)));
            }
            OccSink::Ring(ring) => {
                ring.push_record(
                    crate::ring::REC_TIME_CHANGED,
                    &crate::wire::time_changed_body(tag, packed),
                );
            }
        }
    }

    /// The same fast path for a slider move: the stored tag plus the
    /// new value.
    pub(crate) fn send_value_tag(&self, tag: &[u8], value: f64) {
        match self {
            OccSink::Mpsc(tx) => {
                crate::stall::enqueued();
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

    /// The committed twin (docs/slider-plan.md S2).
    pub(crate) fn send_value_committed_tag(&self, tag: &[u8], value: f64) {
        match self {
            OccSink::Mpsc(tx) => {
                crate::stall::enqueued();
                let _ = tx.send(Inbox::Occ(crate::wire::decode_value_committed_tag(tag, value)));
            }
            OccSink::Ring(ring) => {
                ring.push_record(
                    crate::ring::REC_VALUE_COMMITTED,
                    &crate::wire::value_committed_body(tag, value),
                );
            }
        }
    }

    /// The same fast path for an entry edit: the stored tag plus the
    /// field's current text.
    pub(crate) fn send_text_tag(&self, tag: &[u8], text: &str) {
        match self {
            OccSink::Mpsc(tx) => {
                crate::stall::enqueued();
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
    /// (mpsc). One route for the bar action and the node-anchored context
    /// item; the noun path in the tag tells them apart.
    #[cfg_attr(
        any(target_os = "macos", target_os = "ios", target_os = "android"),
        allow(dead_code)
    )]
    pub(crate) fn send_menu_activated_tag(&self, tag: &[u8]) {
        match self {
            OccSink::Mpsc(tx) => {
                crate::stall::enqueued();
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
                crate::stall::enqueued();
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
                crate::stall::enqueued();
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

    /// The negative for the mode divergence: Android's Write must ask for
    /// TRUNCATION EXPLICITLY, because the provider's bare `w` is
    /// O_WRONLY without O_TRUNC while `PathSource` truncates
    /// (docs/file-dialogs-plan.md §6d, measurement 11).
    #[test]
    fn android_write_truncates_like_every_other_platform() {
        assert_eq!(android_open_mode(FileMode::Read), "r");
        assert_eq!(android_open_mode(FileMode::ReadWrite), "rw");
        assert_eq!(
            android_open_mode(FileMode::Write),
            "wt",
            "a bare `w` does not truncate through a ContentResolver, and \
             PathSource's Write does"
        );
    }

    /// The mode numbers that cross to a backend redeeming a picked file
    /// are a WRITTEN rule, not the enum's layout, and nothing but this
    /// test holds the two spellings together. Reordering `FileMode`
    /// would otherwise turn every guest's Read into the backend's Write.
    #[test]
    fn picked_mode_codes_are_pinned() {
        assert_eq!(picked_mode_code(FileMode::Read), 0);
        assert_eq!(picked_mode_code(FileMode::Write), 1);
        assert_eq!(picked_mode_code(FileMode::ReadWrite), 2);
    }

    /// Content is not identity: the blob arm of the key gate has its
    /// own sentence, because "must be I64 or Str" would leave an
    /// avatar-keyed collection author guessing at the doctrine.
    #[test]
    #[should_panic(expected = "a blob names content, never identity")]
    fn a_blob_cannot_be_a_key() {
        Key::from_value(&Value::Blob(Blob::from(&b"\x89PNG"[..])));
    }

    /// The multi-copy negative: a template context catalog attaches the
    /// SAME item ids to every stamped row, so a native map must hold one
    /// entry per (attachment, item). A flat per-item map keeps only the
    /// last-built copy, with THAT row's noun baked into its activation
    /// route (docs/traps.md).
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

    /// The destroy negative: removing one stamped row purges exactly that
    /// attachment's instances — the other rows' copies and the bar's stay
    /// — so a later context_open + menu_activate on another row can never
    /// invoke the dead copy.
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
