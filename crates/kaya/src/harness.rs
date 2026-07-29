//! The interaction test harness: scene scripts as data, one
//! interpreter for every Rust backend.
//!
//! A scene's selftest used to be a hand-written driver per backend per
//! scene — sleep, poke a control through its own event path, sleep,
//! read a label, compare. That knowledge now lives once, in
//! tools/scenes/<scene>.steps (embedded here at build time, so a Rust
//! backend can never run a stale script), and each backend supplies
//! only its native calls through [`Stage`]: how to click its button,
//! flip its checkbox, read its label — code it already had, minus the
//! choreography. The SwiftUI and Compose halves interpret the same
//! grammar in Swift and Kotlin (they own their node trees on the far
//! side of the C ABI); the suites hand them the script text through
//! the environment.
//!
//! The grammar is line-oriented; `;` is accepted as a line separator
//! for transports that cannot carry newlines:
//!
//!   settle <ms>
//!   click <kind>#<index|last>
//!   toggle <kind>#<index> on|off
//!   set_value <kind>#<index> <f64>
//!   set_text <kind>#<index> "<text>"
//!   expect label#<index> "<text>"
//!   expect entry#<index> "<text>"     (reads the field's displayed text)
//!   expect image#<index> "<WxH>"      (reads the decoded image's size)
//!   expect_focused <kind>#<index>
//!   menu_activate "<path>"            (labels joined with `>`)
//!   context_open <kind>#<index>
//!   expect_menu "<path>" enabled|disabled|checked|unchecked|value <N>
//!   expect_menus <count>
//!   shortcut "<spelling>"
//!
//! Targets are (kind, creation index) — stamped copies enter the count
//! in creation order, so `button#last` is "the most recently stamped
//! button", today's milestone-2 idiom. Every step is logged with its
//! offset from the run's start (`KAYA_HARNESS: +<ms> <step>`): the
//! transcript is the timeline a recording mode will extract frames by,
//! relative offsets only, no wall clock.
//!
//! `kind#index` is HARNESS grammar and nothing else. App code never
//! addresses positionally — an app holds the WidgetId its constructor
//! returned, or names collection rows by their domain keys — and no
//! binding exposes an index lookup. The harness gets indices because
//! it drives scenes from OUTSIDE the process, across eight language
//! guests sharing one byte-identical script, where a handle cannot
//! exist; even here the indexability policy bites — leaf kinds index
//! stably because body order is screen order in every language, while
//! container creation order is not, so tools/check-steps.sh rejects
//! every container target except the unique-by-convention
//! `column#0`/`row#0`.

use std::time::{Duration, Instant};

/// The scene scripts, embedded from tools/scenes at build time.
pub fn script(scene: &str) -> Option<&'static str> {
    // TWO transports, one per platform shape, and NO registry.
    //
    // 1. KAYA_SELFTEST_SCRIPT — the script's TEXT. The interpreters
    //    need this: an iOS bundle or an Android intent has no shared
    //    filesystem with the runner. (Android's intent extras cannot
    //    carry newlines, hence the `;` stand-in in the grammar.)
    // 2. KAYA_SCENES_DIR/<scene>.steps — the FILE. The Rust backends
    //    run where a filesystem exists, so they read the live .steps
    //    rather than a copy. On Windows the runner ships tools/scenes
    //    to the VM and points this at it; on Linux the repo is already
    //    mounted.
    //
    // This replaced a hand-written `match scene` of include_str! arms
    // that ended in `_ => milestone2.steps` — a CATCH-ALL. An unknown
    // scene therefore ran the WRONG SCENE's script rather than failing:
    // a GTK run of the a11y scene silently executed milestone2's steps
    // and reported assertion failures about labels the scene never had
    // (2026-07-25). A missing scene now returns None and spawn fails
    // loudly, and a scene is just a file rather than a registry entry —
    // the same forgotten-list class check-steps already polices.
    // `KAYA_SELFTEST=1` is the original plain selftest flag and still
    // names the milestone-2 scene; the runners use it for those legs.
    let scene = if scene == "1" { "milestone2" } else { scene };
    if let Ok(text) = std::env::var("KAYA_SELFTEST_SCRIPT") {
        if !text.trim().is_empty() {
            return Some(Box::leak(text.into_boxed_str()));
        }
    }
    // Default: the repo's own tools/scenes, resolved at COMPILE time so
    // local runs and `cargo test` work with no environment at all.
    // KAYA_SCENES_DIR overrides it wherever the binary is deployed away
    // from the source tree.
    let dir = std::env::var("KAYA_SCENES_DIR").unwrap_or_else(|_| {
        concat!(env!("CARGO_MANIFEST_DIR"), "/../../tools/scenes").to_owned()
    });
    let path = std::path::Path::new(&dir).join(format!("{scene}.steps"));
    std::fs::read_to_string(path)
        .ok()
        .map(|t| &*Box::leak(t.into_boxed_str()))
}

/// One widget, named by kind and creation order. `index` of -1 is
/// `#last`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Target {
    pub kind: TargetKind,
    pub index: isize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TargetKind {
    Button,
    Checkbox,
    Slider,
    Entry,
    Label,
    Column,
    /// Rows are targetable under the same convention as columns: only
    /// index 0, only in a scene that keeps exactly one row, because
    /// container creation order legitimately differs per language
    /// (tools/check-steps.sh holds the line). Landed for the
    /// horizontal grow assertion — before this, a backend that grew
    /// only columns would have passed the whole matrix.
    Row,
    Image,
    Progress,
    /// Scroll viewports are targetable under the same convention as
    /// columns: only index 0, only in a scene that keeps exactly one
    /// scroll (tools/check-steps.sh holds the line).
    Scroll,
    Select,
    /// The radio group: the choice contract in its inline
    /// presentation — same choose/expect verbs as select.
    Radio,
    /// Grids are targetable under the container convention: only
    /// index 0, only in a scene that keeps exactly one grid
    /// (tools/check-steps.sh holds the line).
    Grid,
    /// The multi-line entry: same set_text/read_text/focus verbs as
    /// the entry, its own registry.
    Textarea,
}

/// The state an `expect_menu` step asserts, exactly as the steps
/// grammar spells it. One token per axis — an item has several axes at
/// once (a toggle is enabled AND checked), so the step names which one
/// it reads via [`MenuState::aspect`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MenuState {
    Enabled,
    Disabled,
    Checked,
    Unchecked,
    /// The radio group's selected option index (the choice contract's
    /// 0-based add order), asserted on the GROUP's path.
    Value(usize),
}

/// Which axis of a menu item's state a step reads — what the stage's
/// `menu_state` is asked for, so a backend never has to guess whether
/// "the state" means enablement or checkedness.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MenuAspect {
    Enablement,
    Checkedness,
    Value,
}

impl MenuState {
    /// The axis this assertion reads.
    pub fn aspect(self) -> MenuAspect {
        match self {
            MenuState::Enabled | MenuState::Disabled => MenuAspect::Enablement,
            MenuState::Checked | MenuState::Unchecked => MenuAspect::Checkedness,
            MenuState::Value(_) => MenuAspect::Value,
        }
    }

    /// The steps grammar's own spelling — what the stage's read is
    /// byte-compared against and what the pass observation echoes, so
    /// every backend and interpreter reports identically.
    pub fn spelling(self) -> String {
        match self {
            MenuState::Enabled => "enabled".to_owned(),
            MenuState::Disabled => "disabled".to_owned(),
            MenuState::Checked => "checked".to_owned(),
            MenuState::Unchecked => "unchecked".to_owned(),
            MenuState::Value(n) => format!("value {n}"),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Step {
    Settle(u64),
    Click(Target),
    Toggle(Target, bool),
    SetValue(Target, f64),
    SetText(Target, String),
    Expect(Target, String),
    /// Expect the container's label children to read, in child order,
    /// the given `|`-joined texts — the observation reorder ops are
    /// verified by (creation-order registries cannot see a move).
    ExpectOrder(Target, String),
    /// Expect the widget to hold keyboard focus — the observation the
    /// focus command is verified by (there is no other way to see
    /// focus land).
    ExpectFocused(Target),
    /// Expect the container's children to occupy the given `,`-joined
    /// percentages of the main axis — the observation layout weights
    /// are verified by.
    ///
    /// Shares, never sizes: absolute geometry is a *metric*, which
    /// DESIGN leaves platform-flavored, so a size assertion could not
    /// be shared byte-for-byte the way every other expect is. A share
    /// is *semantics*, and identical everywhere by construction — give
    /// a container none but growing children and the split is exactly
    /// weight/Σweight whatever the platform's control metrics are.
    ExpectShares(Target, String),
    /// Expect the mounted root to fill the window's content area — the
    /// observation "the root fills its window" (a DESIGN normalization)
    /// is verified by, and the one thing shares can NEVER see: a share
    /// is a percentage of the children's sum, which is total-invariant,
    /// so a root that hugs its content at a fraction of the window
    /// still splits 25/75 and passes every share assertion. That blind
    /// spot shipped twice (GTK's root hugged top-left; UIKit's root was
    /// pinned top+leading only) and both times only a recording caught
    /// it — this step is the gate that does instead.
    ExpectRootFills,
    /// Expect the container's children to span its content box along
    /// the main axis — the leftover-consumption half of the grow
    /// contract, and the second blind spot shares can never see:
    /// growers that hold their weight RATIO at natural size pass every
    /// share assertion (shares are percentages of the children's sum,
    /// which is total-invariant) while consuming none of the leftover.
    /// root_fills cannot see it either — it stops at the root, and the
    /// root can be forced full-size by its window while its children
    /// pool the leftover in container slack. That exact combination
    /// shipped: AppKit's gravity-areas distribution left the bottom
    /// pull unenforced, growers sat at ratio'd minimums, every gate
    /// stayed green, and only a 540x330 window made it visible where
    /// 320x160 had hidden it. This step is the gate that sees it.
    ExpectFills(Target),
    /// Expect the container's children to sit at the given cross-axis
    /// placement — the observation the `align` prop is verified by.
    /// The stage CLASSIFIES from geometry (which edges or centers
    /// coincide, whether breadths fill, whether text baselines agree)
    /// rather than reading the prop back: a backend that ignored the
    /// write while the model still carried it must fail here.
    ExpectAligned(Target, String),
    /// None = the implicit primary (window 0), keeping the
    /// single-window spelling; Some(n) prefixes the observation with
    /// `window#n `.
    ExpectTitle(Option<u64>, String),
    /// The primary window's section count, from the REAL switcher.
    ExpectSections(usize),
    /// The ACTIVE section's title, from the platform's own selection
    /// state — never the scene model's copy.
    ExpectSection(String),
    /// Drive the switcher to the section at `index` (add order),
    /// through the platform's real switching path — emits
    /// section_selected like a user's switch.
    SelectSection(usize),
    ExpectWindowSize(Option<u64>, f64, f64),
    /// Drive the window's REAL chrome close (performClose, WM_CLOSE,
    /// gtk close) — the veto grammar's trigger.
    CloseWindow(u64),
    /// The number of live surfaces (primary included).
    ExpectWindows(usize),
    /// Expect a live modal alert (over the target window; None = the
    /// primary) whose REAL presented title matches — read from the
    /// platform dialog, never the request's copy.
    ExpectAlert(Option<u64>, String),
    /// Drive the live alert's REAL answer path: press the action
    /// button (0 or 1) or fire the platform's dismissal (the cancel
    /// slot). An action, silent like click and close_window.
    AlertChoose(u32),
    ExpectFileDialog(Option<String>, Vec<String>),
    FileChoose(Option<String>),
    FileDialogGoto(String),
    /// The number of live alerts (0 or 1 — one per process).
    ExpectAlerts(usize),
    /// The window's navigation-stack depth (None = the implicit
    /// primary; Some(n) prefixes the observation with `window#n `).
    ExpectEntries(Option<u64>, usize),
    /// Drive the window's REAL back affordance (the toolbar back
    /// button's path, the predictive gesture's path): an armed
    /// intercept_back entry emits back_requested and nothing pops; an
    /// unarmed top pops and reports entry_popped. An action, silent
    /// like click and close_window. None = the implicit primary.
    Back(Option<u64>),
    /// Expect the scroll viewport's content to exceed its visible
    /// extent — the observation that pins "there is something to
    /// scroll" (both readings are geometry from the toolkit).
    ExpectOverflow(Target),
    /// Drive the viewport to its end through the toolkit's REAL
    /// scrolling API. An action, silent like click.
    ScrollEnd(Target),
    /// Expect the content's end edge to coincide with the viewport's
    /// (within two device units) — the observation scroll_end is
    /// verified by: position actually moved, read back from the
    /// toolkit, never a model copy.
    ExpectAtEnd(Target),
    /// Drive the select's REAL selection path to the given option
    /// index — through the toolkit's own change route, so the native
    /// handler (never a synthetic occurrence) emits value_changed. An
    /// action, silent like click; `expect select#N "label"` is the
    /// observable.
    Choose(Target, usize),
    /// Expect the grid to lay its children out in exactly N columns
    /// with each column's cells sharing their leading edge — the
    /// observation the columns prop is verified by, and the one
    /// nested rows can never fake: geometry from the toolkit, never
    /// a model copy.
    ExpectGridColumns(Target, usize),
    /// Drive the REAL activation path of the menu item at the
    /// `>`-joined label path — resolved wherever the item surfaced:
    /// the bar (or its phone overflow), or the OPEN context menu
    /// after a context_open. The platform's own action route fires,
    /// so the native handler emits menu_activated / menu_toggled /
    /// menu_value_changed (never a synthetic occurrence). An action,
    /// silent like click; the guest's fold reaction and the menu
    /// expects are the observables.
    MenuActivate(String),
    /// Open the context menu attached to the live widget through the
    /// platform's own gesture route (right-click, long-press) — the
    /// following menu_activate resolves against the OPEN menu. An
    /// action, silent like click.
    ContextOpen(Target),
    /// Expect the menu item at the path to read the given state along
    /// that state's axis (enablement, checkedness, or the radio
    /// group's value), from the platform's REAL menu chrome — never
    /// the scene model's copy, so a backend that ignored the write
    /// must fail.
    ExpectMenu(String, MenuState),
    /// The window's top-level catalog count, from the REAL
    /// materialized bar (or the phone overflow's group list) — the
    /// observation menubar_append's topology is verified by.
    /// The target's accessibility ROLE and spoken LABEL, read from the
    /// platform's OWN accessibility peer — NSAccessibility /
    /// UIAccessibility protocol methods, AccessibilityNodeInfo,
    /// FrameworkElementAutomationPeer, GtkAccessible. Not the scene
    /// model, and not kaya's copy of what it set: the data an assistive
    /// client actually receives.
    ///
    /// This is the gate DESIGN's accessibility claim never had. kaya
    /// asserts that native widgets ARE the accessibility tree, which is
    /// the load-bearing consequence of the wrap-native bet, and until
    /// now nothing anywhere proved it on any platform.
    ///
    /// Spelled `<role>/<label>`. Role comes from each platform's own
    /// vocabulary normalized to a small closed set, because the point is
    /// that the PLATFORM classified the control, not that kaya
    /// remembered what it built.
    ExpectAx(Target, String),
    /// The control's HINT — what activating it does. Its own verb
    /// because expect_ax's `<role>/<label>` spelling is byte-frozen in
    /// every scene; see the parse arm.
    ExpectAxHint(Target, String),
    ExpectMenus(usize),
    /// How the window catalog is CURRENTLY presented, spelled
    /// `<size class>/<presentation>`: `regular/bar`,
    /// `compact/overflow`, or `<class>/none` when the catalog is empty.
    ///
    /// The PAIR is the assertion on purpose. The iPadOS 26 defect was a
    /// regular-width window wearing the compact lowering, and neither
    /// half alone catches that — the size class was right and the
    /// presentation was right, only for different windows (DESIGN.md,
    /// "Form factor and adaptivity"). Size class comes from the
    /// platform's own reading where it has one (SwiftUI's horizontal
    /// size class, Compose's WindowSizeClass) and from the 600dp width
    /// boundary those APIs themselves use where it does not (GTK4,
    /// WinUI — whose adaptive triggers are width thresholds anyway).
    /// `Some(spelling)` asserts an exact `<class>/<presentation>`.
    /// `None` — the BARE form — asserts only the invariant: a regular
    /// window must not hide its catalog behind the compact overflow.
    /// The bare form is what a SHARED scene can carry, because the
    /// exact literal differs per lane (`regular/bar` on desktops,
    /// `compact/overflow` on phones) while the invariant holds
    /// everywhere. Deliberately ASYMMETRIC: a compact window showing a
    /// bar is legitimate — a narrow GTK or WinUI window keeps its menu
    /// bar — so only the one direction is a defect.
    ExpectMenuPresentation(Option<String>),
    /// Drive the platform's key-equivalent dispatch for a canonical
    /// shortcut spelling — at minimum the same table the platform's
    /// own key event traverses, emitting the SAME menu_activated the
    /// item's direct activation would (one dispatch path). An action,
    /// silent like click.
    Shortcut(String),
    /// Drive the window's REAL resize — the path a user's drag takes,
    /// not a model write — so the SIZE CLASS actually changes and the
    /// adaptive arms re-run. `None` targets the implicit primary.
    /// Capability-rejected on the phone hosts, the create_window
    /// precedent: a phone window has no size to command. An action,
    /// silent like click and close_window.
    ResizeWindow(Option<u64>, f64, f64),
    /// The window's live list-detail presentation,
    /// `<size class>/<presentation>` with presentations `split` and
    /// `stacked`. `Some(spelling)` asserts an exact reading; `None` —
    /// the BARE form — asserts only the invariant a SHARED scene can
    /// carry, because the exact literal differs per lane while the
    /// invariant holds everywhere. Deliberately ASYMMETRIC, the
    /// expect_menu_presentation precedent: a regular window must not be
    /// showing one pane while its stack holds two, but what counts as
    /// wide enough is the platform's call and a compact window is never
    /// asked to show two.
    ExpectSplit(Option<String>),
}

impl Step {
    /// Does this step ASSERT something, as opposed to driving the UI?
    ///
    /// Exhaustive on purpose. This began as a hand-written list of
    /// seven variants inside the "script has no expects" guard, and by
    /// 2026-07-25 it had silently fallen eight behind — a scene built
    /// only from menu or accessibility assertions was reported as
    /// having no expects at all. An exhaustive match turns that
    /// forgotten-list class into a COMPILE ERROR: a new Step cannot
    /// ship without someone deciding which side of this line it is on.
    fn is_assertion(&self) -> bool {
        match self {
            Step::Settle { .. } => false,
            Step::Click { .. } => false,
            Step::Toggle { .. } => false,
            Step::SetValue { .. } => false,
            Step::SetText { .. } => false,
            Step::Expect { .. } => true,
            Step::ExpectOrder { .. } => true,
            Step::ExpectFocused { .. } => true,
            Step::ExpectShares { .. } => true,
            Step::ExpectRootFills { .. } => true,
            Step::ExpectFills { .. } => true,
            Step::ExpectAligned { .. } => true,
            Step::ExpectTitle { .. } => true,
            Step::ExpectSections { .. } => true,
            Step::ExpectSection { .. } => true,
            Step::SelectSection { .. } => false,
            Step::ExpectWindowSize { .. } => true,
            Step::CloseWindow { .. } => false,
            Step::ExpectWindows { .. } => true,
            Step::ExpectAlert { .. } => true,
            Step::FileChoose(..) => false,
            Step::FileDialogGoto(..) => false,
            Step::ExpectFileDialog(..) => true,
            Step::AlertChoose { .. } => false,
            Step::ExpectAlerts { .. } => true,
            Step::ExpectEntries { .. } => true,
            Step::Back { .. } => false,
            Step::ExpectOverflow { .. } => true,
            Step::ScrollEnd { .. } => false,
            Step::ExpectAtEnd { .. } => true,
            Step::Choose { .. } => false,
            Step::ExpectGridColumns { .. } => true,
            Step::MenuActivate { .. } => false,
            Step::ContextOpen { .. } => false,
            Step::ExpectMenu { .. } => true,
            Step::ExpectAx { .. } => true,
            Step::ExpectAxHint { .. } => true,
            Step::ExpectMenus { .. } => true,
            Step::ExpectMenuPresentation { .. } => true,
            Step::Shortcut { .. } => false,
            Step::ResizeWindow { .. } => false,
            Step::ExpectSplit { .. } => true,
        }
    }
}


/// What a backend supplies: its native calls, each hopping to its UI
/// thread internally and blocking until applied (reads return the
/// value). The harness thread stays dumb.
pub trait Stage: Send + 'static {
    fn click(&self, target: Target);
    fn toggle(&self, target: Target, on: bool);
    fn set_value(&self, target: Target, value: f64);
    fn set_text(&self, target: Target, text: &str);
    fn read_label(&self, target: Target) -> String;
    /// The displayed text of an entry — what the user sees in the
    /// field, read from the toolkit (the observation the clear command
    /// is pinned by: the occurrence fold alone cannot prove the screen
    /// emptied). No default, like child_texts: a backend that forgets
    /// it fails to compile.
    fn read_text(&self, target: Target) -> String;
    /// Whether the widget holds keyboard focus, read from the toolkit
    /// (per-window focus, never global key status — parallel tiled
    /// legs must not steal each other's assertion). No default.
    fn is_focused(&self, target: Target) -> bool;
    /// The decoded size of an image, as "WxH" — the observation that
    /// pins "the bytes actually decoded and display" (a failed decode
    /// reads "0x0", the placeholder class). No default, like
    /// child_texts: a backend that forgets it fails to compile.
    fn image_size(&self, target: Target) -> String;
    /// The texts of the container's label children, in child order,
    /// joined with `|` — the observation expect_order verifies. No
    /// default: a backend that forgets it must fail to compile, not
    /// panic on the first reorder leg (which is how the GTK gap
    /// reached the Linux suite).
    fn child_texts(&self, target: Target) -> String;
    /// Whether the mounted root fills the window's content area, read
    /// from the toolkit after forcing pending layout: the empty string
    /// when it does (within one device unit — rounding is not a hug),
    /// otherwise a short platform-flavored description of the two
    /// rects, which only ever appears in failure text and is never
    /// compared across platforms. "Content area" is the platform's own
    /// notion — the safe area on iOS, the contentView on macOS, the
    /// window's child area on GTK and WinUI, the content parent on
    /// Android. No default, like child_shares: a backend that forgets
    /// it must fail to compile rather than pass the fill leg vacuously.
    fn root_fills(&self) -> String;
    /// The main-axis extents of the container's children, in child
    /// order, each as a whole percentage of their sum, joined with `,`
    /// — the observation expect_shares verifies, and the only way a
    /// layout weight is observable at all.
    ///
    /// Their sum, not the container's extent: spacing and padding are
    /// platform metrics, so dividing by the container would leak them
    /// into the number and break the byte-for-byte comparison. Read the
    /// alignment/layout rect where the toolkit distinguishes it from
    /// the drawing frame (AppKit inflates a slider's frame past its
    /// alignment rect, which would read 1:3 as 2.90:1).
    ///
    /// No default, like child_texts: a backend that forgets it must
    /// fail to compile rather than pass a layout leg vacuously.
    fn child_shares(&self, target: Target) -> String;
    /// Whether the container's children (plumbing like leftover
    /// fillers excluded) span its content box along the main axis,
    /// read from the toolkit after forcing pending layout: the empty
    /// string when they do (within two device units), otherwise a
    /// short platform-flavored description of the span and the box,
    /// which only ever appears in failure text and is never compared
    /// across platforms. The observation expect_fills verifies. No
    /// default, like child_shares: a backend that forgets it must
    /// fail to compile rather than pass the consumption leg vacuously.
    fn container_fills(&self, target: Target) -> String;
    /// The container's cross-axis placement, CLASSIFIED from geometry
    /// after forcing pending layout: one of "start", "center", "end",
    /// "stretch", or "baseline" when the corresponding coincidence
    /// holds for every child (within two device units), otherwise a
    /// short platform-flavored description of what was seen (failure
    /// text only, never compared across platforms). Baseline is
    /// meaningful on rows alone and classifies via each toolkit's own
    /// baseline query. The observation expect_aligned verifies. No
    /// default: a backend that forgets it must fail to compile.
    fn cross_mode(&self, target: Target) -> String;
    /// A surface's REAL materialized title (the title bar on the
    /// desktops, the task label on Android) — never the scene
    /// model's copy, so a backend that ignored the write fails. No
    /// default: a backend that forgets it must fail to compile.
    fn window_title(&self, window: u64) -> String;
    /// A surface's REAL content extent in device-independent units —
    /// what expect_window_size compares against the advisory
    /// request. No default, like window_title.
    fn window_content_size(&self, window: u64) -> (f64, f64);
    /// Drive the surface's REAL chrome close (performClose, WM_CLOSE,
    /// gtk close) — a veto_close window emits close_requested and
    /// stays; a non-veto auxiliary closes and reports window_closed.
    fn close_window(&self, window: u64);
    /// The number of live surfaces, primary included.
    fn window_count(&self) -> usize;
    /// The REAL presented title of the live alert over the window, or
    /// None when no alert is live there — read from the platform
    /// dialog (NSAlert's messageText, ContentDialog's Title, ...),
    /// never the request's copy. No default: a backend that forgets
    /// it must fail to compile.
    fn alert_title(&self, window: u64) -> Option<String>;
    /// Drive the live alert's REAL answer path: activate the action
    /// button (choice 0 or 1) or the cancel slot (the sentinel) the
    /// way the platform's own dismissal would. No default.
    fn choose_alert(&self, choice: u32);
    /// The number of live alerts (0 or 1). No default.
    fn alert_count(&self) -> usize;
    /// What the live file picker is REALLY showing: the directory it is
    /// pointed at, and the file names its list actually contains — read
    /// from the platform panel, never from the request. None when no
    /// picker is live.
    ///
    /// Both halves matter and neither is stamped. A panel aimed at the
    /// wrong place, or with a filter that excludes everything, presents
    /// perfectly and is useless; only reading the real "where" and the
    /// real rows catches that. No default: a backend that forgets it
    /// must fail to compile.
    fn file_dialog_state(&self) -> Option<(String, Vec<String>)>;
    /// Drive the live picker's REAL answer path: select the named row
    /// and press Open, or press Cancel when `name` is None — the same
    /// controls a user works, not a synthesized completion. No default.
    fn choose_file(&self, name: Option<&str>);
    /// Point the live picker at a directory, the way a user navigating
    /// there would leave it.
    ///
    /// HARNESS MACHINERY, NOT VOCABULARY — the same tier as set_text,
    /// which sets a field's text rather than simulating keystrokes. It
    /// deliberately is NOT a request field: every platform has a start
    /// location, but WinUI's is a PickerLocationId ENUM of well-known
    /// folders, so a `directory` on the wire would be honorable on four
    /// platforms and not the fifth — the "looks usable and isn't" shape
    /// `local_path` already exists to avoid. Whether it took effect is
    /// not assumed either: expect_file_dialog reads the panel back.
    /// No default.
    fn goto_directory(&self, path: &str);
    /// The window's navigation-stack depth — the observation
    /// expect_entries verifies. No default: a backend that forgets it
    /// must fail to compile rather than pass a navigation leg
    /// vacuously.
    fn entry_count(&self, window: u64) -> usize;
    /// Drive the window's REAL back affordance. No default.
    fn back(&self, window: u64);
    /// The progress bar's state, read from the toolkit: the
    /// determinate fraction as an integer percent ("42%" — the slider
    /// verdict's spelling, identical in every language by
    /// construction) or "indeterminate" while activity mode is on.
    /// No default: a backend that forgets it must fail to compile.
    fn progress_state(&self, target: Target) -> String;
    /// Drive the select's REAL selection path to the given option
    /// index — the toolkit's own change route, so the native handler
    /// emits value_changed (never a synthetic occurrence). No
    /// default: a backend that forgets it must fail to compile.
    fn choose(&self, target: Target, index: usize);
    /// The selected option's LABEL, read from the toolkit's own
    /// selection state — what the collapsed control shows, never a
    /// model copy. Labels, not indices: byte-compared across every
    /// language like all expects. No default.
    fn selected_label(&self, target: Target) -> String;
    /// The grid observation: empty when the grid lays out in exactly
    /// `want` columns whose cells share their leading edges (within
    /// two device units); otherwise the toolkit's own description of
    /// the mismatch, for the failure text. Geometry, never a model
    /// copy. No default.
    fn grid_columns(&self, target: Target, want: usize) -> String;
    /// The scroll viewport's overflow, read from the toolkit after
    /// forcing pending layout: the empty string when the content
    /// exceeds the viewport, otherwise a short platform-flavored
    /// description of the two extents (failure text only). No
    /// default: a backend that forgets it must fail to compile.
    fn scroll_overflow(&self, target: Target) -> String;
    /// Drive the viewport to its end through the toolkit's REAL
    /// scrolling API. No default.
    fn scroll_end(&self, target: Target);
    /// Whether the content's end edge coincides with the viewport's
    /// (within two device units): the empty string when it does,
    /// otherwise a description (failure text only). No default.
    fn scroll_at_end(&self, target: Target) -> String;
    /// The primary window's section count, read from the REAL
    /// switcher control (tab bar items, stack pages), never the scene
    /// model. No default: a backend that forgets it must fail to
    /// compile.
    fn section_count(&self) -> usize;
    /// The ACTIVE section's title, from the platform's own selection
    /// state. No default.
    fn active_section_title(&self) -> String;
    /// Drive the switcher to the section at `index` (add order)
    /// through the platform's real switching path — the user's route,
    /// so it emits section_selected (choose/toggle precedent). No
    /// default.
    fn select_section(&self, index: usize);
    /// Drive the REAL activation path of the menu item at the
    /// `>`-joined label path — through the bar (or its phone
    /// overflow), or the OPEN context menu when a context_open
    /// preceded — so the platform's own action route emits
    /// menu_activated / menu_toggled / menu_value_changed, never a
    /// synthetic occurrence. No default: a backend that forgets it
    /// must fail to compile rather than pass a menu leg vacuously.
    fn menu_activate(&self, path: &str);
    /// Open the context menu attached to the live widget through the
    /// platform's own gesture route (right-click, long-press), so a
    /// following menu_activate resolves against the OPEN menu. No
    /// default.
    fn context_open(&self, target: Target);
    /// The top-level catalog count, read from the REAL materialized
    /// bar (or the phone overflow's group list) — never the scene
    /// model's copy. No default.
    fn menu_count(&self) -> usize;
    /// The target's accessibility ROLE and spoken LABEL as
    /// `<role>/<label>`, read from the PLATFORM'S OWN accessibility
    /// peer — never from the scene model and never from kaya's memory
    /// of what it set. Reading the model would make this verb agree
    /// with itself and prove nothing; the whole claim under test is
    /// that the native control publishes a correct accessibility
    /// surface without kaya doing anything.
    ///
    /// Role is each platform's classification normalized to the closed
    /// set in `check_ax`. `unknown` is legal and honest — a platform
    /// that classifies something kaya has no name for must say so
    /// rather than guess. No default.
    fn ax(&self, target: Target) -> String;

    /// The control's HINT as the platform publishes it — what
    /// activating it does. Read from the same tree as `ax`, never from
    /// kaya's model, for the same reason.
    fn ax_hint(&self, target: Target) -> String;
    /// The window catalog's live presentation, `<size class>/<presentation>`
    /// — see Step::ExpectMenuPresentation for the vocabulary.
    ///
    /// Both halves must come FROM THE PLATFORM, not from the scene
    /// model. Reading the model would make this verb agree with itself:
    /// the whole failure being gated is a lowering that disagrees with
    /// the window it is in, and a model-sourced answer cannot see that.
    /// No default.
    fn menu_presentation(&self) -> String;
    /// Resize `window` to WxH in DIP through the platform's real
    /// window-resize path, blocking until the new size is applied so
    /// the size-class-driven arms have re-run by the time this
    /// returns. Hosts without commandable window size reject the
    /// scene loudly rather than silently no-op.
    /// No default.
    fn resize_window(&self, window: u64, width: f64, height: f64);
    /// The window's live list-detail presentation,
    /// `<size class>/<presentation>` — see Step::ExpectSplit.
    ///
    /// The presentation half must name THE ARM THAT RENDERED, read
    /// from the view layer's own stamp, never derived from the prop or
    /// the size class. A derived answer agrees with the lowering by
    /// construction and cannot see the defect being gated.
    /// No default.
    fn split_presentation(&self) -> String;
    /// The menu item's state along one axis, read from the platform's
    /// real menu chrome and spelled in the steps grammar's own words
    /// ("enabled"/"disabled", "checked"/"unchecked", "value N") —
    /// never a model copy, so a backend that ignored the write must
    /// fail. TOTAL: a missing item reads as a short description ("no
    /// such item"), a retryable non-match rather than a panic —
    /// expect_menu doubles as the wait for a catalog rebuild to land.
    /// No default.
    fn menu_state(&self, path: &str, aspect: MenuAspect) -> String;
    /// Drive the platform's key-equivalent dispatch for a canonical
    /// shortcut spelling — at minimum the same table the platform's
    /// own key event would traverse, emitting the SAME menu_activated
    /// the item's direct activation would (one dispatch path). No
    /// default.
    fn shortcut(&self, spelling: &str);
    /// Report the verdict and end the process (backends own their exit
    /// discipline: process::exit, request_exit, _exit after finishing
    /// the Activity, ...).
    fn finish(&self, code: i32, verdict: &str);
}

pub fn parse(script: &str) -> Result<Vec<Step>, String> {
    let mut steps = Vec::new();
    // Comments are whole newline-delimited lines; only the statements
    // that remain also split on `;` (the newline stand-in for
    // transports that cannot carry one).
    for raw_line in script.split('\n') {
        let raw_line = raw_line.trim();
        if raw_line.is_empty() || raw_line.starts_with('#') {
            continue;
        }
        for raw in raw_line.split(';') {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (op, rest) = line.split_once(char::is_whitespace).unwrap_or((line, ""));
        let rest = rest.trim();
        let step = match op {
            "settle" => Step::Settle(
                rest.parse()
                    .map_err(|_| format!("settle wants milliseconds: {line:?}"))?,
            ),
            "click" => Step::Click(parse_target(rest)?),
            "toggle" => {
                let (target, state) = rest
                    .split_once(char::is_whitespace)
                    .ok_or_else(|| format!("toggle wants a target and on|off: {line:?}"))?;
                Step::Toggle(
                    parse_target(target)?,
                    match state.trim() {
                        "on" => true,
                        "off" => false,
                        other => return Err(format!("toggle wants on|off, got {other:?}")),
                    },
                )
            }
            "set_value" => {
                let (target, value) = rest
                    .split_once(char::is_whitespace)
                    .ok_or_else(|| format!("set_value wants a target and a number: {line:?}"))?;
                Step::SetValue(
                    parse_target(target)?,
                    value
                        .trim()
                        .parse()
                        .map_err(|_| format!("set_value wants a number: {line:?}"))?,
                )
            }
            "set_text" => {
                let (target, text) = rest
                    .split_once(char::is_whitespace)
                    .ok_or_else(|| format!("set_text wants a target and a string: {line:?}"))?;
                Step::SetText(parse_target(target)?, parse_string(text)?)
            }
            "expect" => {
                let (target, text) = rest
                    .split_once(char::is_whitespace)
                    .ok_or_else(|| format!("expect wants a target and a string: {line:?}"))?;
                Step::Expect(parse_target(target)?, parse_string(text)?)
            }
            "expect_focused" => Step::ExpectFocused(parse_target(rest)?),
            "expect_order" => {
                let (target, text) = rest.split_once(char::is_whitespace).ok_or_else(|| {
                    format!("expect_order wants a target and a string: {line:?}")
                })?;
                Step::ExpectOrder(parse_target(target)?, parse_string(text)?)
            }
            "expect_shares" => {
                let (target, text) = rest.split_once(char::is_whitespace).ok_or_else(|| {
                    format!("expect_shares wants a target and a string: {line:?}")
                })?;
                Step::ExpectShares(parse_target(target)?, parse_string(text)?)
            }
            "expect_fills" => Step::ExpectFills(parse_target(rest)?),
            "expect_aligned" => {
                let (target, text) = rest.split_once(char::is_whitespace).ok_or_else(|| {
                    format!("expect_aligned wants a target and a mode string: {line:?}")
                })?;
                Step::ExpectAligned(parse_target(target)?, parse_string(text)?)
            }
            "expect_root_fills" => {
                if !rest.is_empty() {
                    return Err(format!(
                        "expect_root_fills takes no arguments — the mounted root is the target: {line:?}"
                    ));
                }
                Step::ExpectRootFills
            }
            "expect_title" => {
                let (window, rest) = parse_window_target(rest);
                Step::ExpectTitle(window, parse_string(rest)?)
            }
            "expect_sections" => Step::ExpectSections(
                rest.trim()
                    .parse::<usize>()
                    .map_err(|_| format!("expect_sections wants a count: {line:?}"))?,
            ),
            "expect_section" => Step::ExpectSection(parse_string(rest)?),
            "select_section" => Step::SelectSection(
                rest.trim()
                    .parse::<usize>()
                    .map_err(|_| format!("select_section wants an index: {line:?}"))?,
            ),
            "expect_window_size" => {
                let (window, rest) = parse_window_target(rest);
                let (w, h) = rest.split_once('x').ok_or_else(|| {
                    format!("expect_window_size wants WxH: {line:?}")
                })?;
                let w = w.trim().parse::<f64>().map_err(|_| {
                    format!("expect_window_size wants numeric WxH: {line:?}")
                })?;
                let h = h.trim().parse::<f64>().map_err(|_| {
                    format!("expect_window_size wants numeric WxH: {line:?}")
                })?;
                Step::ExpectWindowSize(window, w, h)
            }
            "close_window" => {
                let (window, rest) = parse_window_target(rest);
                if !rest.is_empty() {
                    return Err(format!(
                        "close_window takes one window#N target: {line:?}"
                    ));
                }
                let window = window.ok_or_else(|| {
                    format!("close_window wants an explicit window#N: {line:?}")
                })?;
                Step::CloseWindow(window)
            }
            "expect_windows" => {
                let n = rest.trim().parse::<usize>().map_err(|_| {
                    format!("expect_windows wants a count: {line:?}")
                })?;
                Step::ExpectWindows(n)
            }
            "expect_alert" => {
                let (window, rest) = parse_window_target(rest);
                Step::ExpectAlert(window, parse_string(rest)?)
            }
            "alert_choose" => {
                let choice = match rest.trim() {
                    "0" => 0,
                    "1" => 1,
                    "cancel" => u32::MAX,
                    other => {
                        return Err(format!(
                            "alert_choose wants 0, 1, or cancel, got {other:?}: {line:?}"
                        ))
                    }
                };
                Step::AlertChoose(choice)
            }
            "expect_file_dialog" => {
                // `expect_file_dialog <dir> <name>...`: the directory the
                // panel is showing, then every file its list must
                // contain. Bare names, so the script stays identical on
                // lanes whose temp dirs differ.
                // BARE means "a picker is live" — the wait a scene needs
                // before it can navigate, since an action fired before
                // the panel exists silently does nothing. With arguments
                // it also asserts the directory being shown and the
                // names the list holds.
                let mut words = rest.split_whitespace().map(str::to_owned);
                Step::ExpectFileDialog(words.next(), words.collect())
            }
            "file_dialog_goto" => {
                let path = rest.trim();
                if path.is_empty() {
                    return Err(format!("file_dialog_goto wants a directory: {line:?}"));
                }
                Step::FileDialogGoto(path.to_owned())
            }
            "file_choose" => {
                let arg = rest.trim();
                if arg.is_empty() {
                    return Err(format!("file_choose wants a name or cancel: {line:?}"));
                }
                Step::FileChoose(if arg == "cancel" {
                    None
                } else {
                    Some(arg.to_owned())
                })
            }
            "expect_alerts" => {
                let n = rest.trim().parse::<usize>().map_err(|_| {
                    format!("expect_alerts wants a count: {line:?}")
                })?;
                Step::ExpectAlerts(n)
            }
            "expect_entries" => {
                let (window, rest) = parse_window_target(rest);
                let n = rest.trim().parse::<usize>().map_err(|_| {
                    format!("expect_entries wants a count: {line:?}")
                })?;
                Step::ExpectEntries(window, n)
            }
            "back" => {
                let (window, rest) = parse_window_target(rest);
                if !rest.trim().is_empty() {
                    return Err(format!(
                        "back takes at most one window#N target: {line:?}"
                    ));
                }
                Step::Back(window)
            }
            "choose" => {
                let (target, index) = rest
                    .split_once(char::is_whitespace)
                    .ok_or_else(|| format!("choose wants a target and an index: {line:?}"))?;
                Step::Choose(
                    parse_target(target)?,
                    index
                        .trim()
                        .parse()
                        .map_err(|_| format!("choose wants a 0-based index: {line:?}"))?,
                )
            }
            "expect_grid_columns" => {
                let (target, n) = rest
                    .split_once(char::is_whitespace)
                    .ok_or_else(|| format!("expect_grid_columns wants a target and a count: {line:?}"))?;
                Step::ExpectGridColumns(
                    parse_target(target)?,
                    n.trim()
                        .parse()
                        .map_err(|_| format!("expect_grid_columns wants a count: {line:?}"))?,
                )
            }
            "expect_overflow" => Step::ExpectOverflow(parse_target(rest.trim())?),
            "scroll_end" => Step::ScrollEnd(parse_target(rest.trim())?),
            "expect_at_end" => Step::ExpectAtEnd(parse_target(rest.trim())?),
            "menu_activate" => {
                let path = parse_string(rest)?;
                check_menu_path(&path).map_err(|e| format!("{e}: {line:?}"))?;
                Step::MenuActivate(path)
            }
            "context_open" => Step::ContextOpen(parse_target(rest.trim())?),
            "expect_menu" => {
                let (path, tail) = parse_quoted_prefix(rest)
                    .map_err(|e| format!("expect_menu wants a quoted path and a state: {e}"))?;
                check_menu_path(&path).map_err(|e| format!("{e}: {line:?}"))?;
                let state = parse_menu_state(tail).map_err(|e| format!("{e}: {line:?}"))?;
                Step::ExpectMenu(path, state)
            }
            "expect_menus" => Step::ExpectMenus(
                rest.trim()
                    .parse::<usize>()
                    .map_err(|_| format!("expect_menus wants a count: {line:?}"))?,
            ),
            // The hint is its own verb rather than a third field on
            // expect_ax: the `<role>/<label>` spelling is byte-frozen
            // in every scene, and widening it would rewrite assertions
            // that have nothing to do with hints.
            "expect_ax_hint" => {
                let (target, text) = rest.split_once(char::is_whitespace).ok_or_else(|| {
                    format!("expect_ax_hint wants a target and a hint string: {line:?}")
                })?;
                Step::ExpectAxHint(parse_target(target)?, parse_string(text)?)
            }
            "expect_ax" => {
                let (target, text) = rest.split_once(char::is_whitespace).ok_or_else(|| {
                    format!("expect_ax wants a target and a \"role/label\" string: {line:?}")
                })?;
                let want = parse_string(text)?;
                check_ax(&want).map_err(|e| format!("{e}: {line:?}"))?;
                Step::ExpectAx(parse_target(target)?, want)
            }
            "resize_window" => {
                let (window, rest) = parse_window_target(rest);
                let (w, h) = rest
                    .trim()
                    .split_once('x')
                    .ok_or_else(|| format!("resize_window wants WxH: {line:?}"))?;
                let w: f64 = w
                    .trim()
                    .parse()
                    .map_err(|_| format!("resize_window wants numeric WxH: {line:?}"))?;
                let h: f64 = h
                    .trim()
                    .parse()
                    .map_err(|_| format!("resize_window wants numeric WxH: {line:?}"))?;
                Step::ResizeWindow(window, w, h)
            }
            "expect_split" => {
                if rest.trim().is_empty() {
                    Step::ExpectSplit(None)
                } else {
                    let want = parse_string(rest)?;
                    check_split_presentation(&want).map_err(|e| format!("{e}: {line:?}"))?;
                    Step::ExpectSplit(Some(want))
                }
            }
            "expect_menu_presentation" => {
                if rest.trim().is_empty() {
                    Step::ExpectMenuPresentation(None)
                } else {
                    let want = parse_string(rest)?;
                    check_menu_presentation(&want)
                        .map_err(|e| format!("{e}: {line:?}"))?;
                    Step::ExpectMenuPresentation(Some(want))
                }
            }
            "shortcut" => {
                let spelling = parse_string(rest)?;
                // Grammar-level sanity only: emptiness and whitespace
                // are line-noise, caught here; the POLICY floor (the
                // modifier rules, the named-key set, the reserved
                // union) is the root's one checker (scene.rs), and a
                // spelling it rejects can never reach a dispatch
                // table for this verb to hit.
                if spelling.is_empty() {
                    return Err(format!("shortcut wants a spelling: {line:?}"));
                }
                if spelling.chars().any(char::is_whitespace) {
                    return Err(format!(
                        "shortcut spelling {spelling:?} contains whitespace: {line:?}"
                    ));
                }
                Step::Shortcut(spelling)
            }
            other => return Err(format!("unknown step {other:?}")),
        };
        steps.push(step);
        }
    }
    Ok(steps)
}

/// An optional leading `window#N` token; the remainder is returned
/// for the verb's own parsing. None keeps the implicit primary.
fn parse_window_target(rest: &str) -> (Option<u64>, &str) {
    let trimmed = rest.trim_start();
    if let Some(tail) = trimmed.strip_prefix("window#") {
        let digits: &str = tail.split_whitespace().next().unwrap_or("");
        if let Ok(n) = digits.parse::<u64>() {
            let after = &tail[digits.len()..];
            return (Some(n), after.trim_start());
        }
    }
    (None, rest)
}

fn parse_target(spec: &str) -> Result<Target, String> {
    let (kind, index) = spec
        .split_once('#')
        .ok_or_else(|| format!("target wants kind#index: {spec:?}"))?;
    let kind = match kind {
        "button" => TargetKind::Button,
        "checkbox" => TargetKind::Checkbox,
        "slider" => TargetKind::Slider,
        "entry" => TargetKind::Entry,
        "label" => TargetKind::Label,
        "column" => TargetKind::Column,
        "row" => TargetKind::Row,
        "image" => TargetKind::Image,
        "scroll" => TargetKind::Scroll,
        "progress" => TargetKind::Progress,
        "select" => TargetKind::Select,
        "radio" => TargetKind::Radio,
        "grid" => TargetKind::Grid,
        "textarea" => TargetKind::Textarea,
        other => return Err(format!("unknown target kind {other:?}")),
    };
    let index = if index == "last" {
        -1
    } else {
        index
            .parse()
            .map_err(|_| format!("target index wants a number or `last`: {spec:?}"))?
    };
    Ok(Target { kind, index })
}

fn parse_string(spec: &str) -> Result<String, String> {
    let spec = spec.trim();
    let inner = spec
        .strip_prefix('"')
        .and_then(|s| s.strip_suffix('"'))
        .ok_or_else(|| format!("wanted a quoted string, got {spec:?}"))?;
    Ok(unescape(inner))
}

/// The escapes the line-oriented grammar needs: a literal newline
/// cannot ride a script line, and a textarea's whole distinguishing
/// observable is accepting one. `\n` -> newline, `\r` -> carriage
/// return (the paste stand-in: set_text with CR-bearing text proves
/// the backends' LF normalization), `\\` -> backslash; all three
/// interpreters unescape identically.
fn unescape(inner: &str) -> String {
    let mut out = String::with_capacity(inner.len());
    let mut chars = inner.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('n') => out.push('\n'),
                Some('r') => out.push('\r'),
                Some('\\') => out.push('\\'),
                Some(other) => {
                    out.push('\\');
                    out.push(other);
                }
                None => out.push('\\'),
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// A LEADING quoted string plus the remainder after its closing quote
/// — for the verbs whose quoted argument comes first (expect_menu's
/// path precedes its state token, and a path may contain spaces, so
/// whitespace-splitting before the quote would shear a label). Honors
/// the same escapes as [`parse_string`]; the remainder comes back with
/// its leading whitespace stripped.
fn parse_quoted_prefix(spec: &str) -> Result<(String, &str), String> {
    let spec = spec.trim_start();
    let Some(body) = spec.strip_prefix('"') else {
        return Err(format!("wanted a quoted string, got {spec:?}"));
    };
    let mut escaped = false;
    for (i, c) in body.char_indices() {
        if escaped {
            escaped = false;
        } else if c == '\\' {
            escaped = true;
        } else if c == '"' {
            return Ok((unescape(&body[..i]), body[i + 1..].trim_start()));
        }
    }
    Err(format!("unterminated quoted string: {spec:?}"))
}

/// A menu path is labels joined with `>`: at least one label, every
/// segment non-empty and byte-exact. No trimming — labels compare
/// byte-for-byte across every language, so a segment padded with
/// whitespace is a typo that would only surface as a bewildering
/// "no such item" at runtime; reject it at parse instead.
fn check_menu_path(path: &str) -> Result<(), String> {
    if path.is_empty() {
        return Err("menu path is empty".to_owned());
    }
    for seg in path.split('>') {
        if seg.is_empty() {
            return Err(format!("menu path {path:?} has an empty label segment"));
        }
        if seg != seg.trim() {
            return Err(format!(
                "menu path {path:?} pads a label with whitespace"
            ));
        }
    }
    Ok(())
}

/// The spelling of an expect_ax step: `<role>/<label>`. The role half
/// is a closed set — the platforms' own vocabularies normalized, so a
/// scene reads the same everywhere — while the label half is free text
/// (it is whatever the app authored, or whatever the control derived
/// from its own content). An empty label is legal and meaningful: it
/// asserts the platform speaks nothing for this element.
fn check_ax(spec: &str) -> Result<(), String> {
    // NORMALIZED, not exhaustive: a platform role that no other
    // platform can match is normalized DOWN to the coarsest one they
    // all publish (macOS's AXRadioGroup and AXScrollArea are both
    // `group`), because a name only one backend can produce is a name
    // no shared scene can assert. `combobox` earns its place the other
    // way: every platform has a chooser role, and only the spelling
    // differs (AXPopUpButton, Compose's dropdown, AT-SPI/UIA ComboBox).
    const ROLES: [&str; 10] = [
        "button", "label", "field", "checkbox", "slider", "image", "progress",
        "combobox", "group", "unknown",
    ];
    let Some((role, _label)) = spec.split_once('/') else {
        return Err(format!("ax {spec:?} wants <role>/<label>"));
    };
    if !ROLES.contains(&role) {
        return Err(format!(
            "ax {spec:?} has an unknown role {role:?}; wanted one of {ROLES:?}"
        ));
    }
    Ok(())
}

/// The invariant the BARE expect_menu_presentation step asserts: a
/// regular-width window must not hide its catalog behind the compact
/// overflow. Deliberately ASYMMETRIC — a compact window showing a bar
/// is legitimate (a narrow GTK or WinUI window keeps its menu bar), so
/// the reverse is not a defect. Extracted from the step so it is
/// directly testable; the two interpreters mirror it.
fn menu_presentation_fits(spelling: &str) -> bool {
    let (class, presentation) = spelling.split_once('/').unwrap_or(("unknown", "none"));
    !(class == "regular" && presentation == "overflow")
}

/// The invariant the BARE expect_split step asserts: a regular window
/// must not be showing ONE pane while its stack holds two. Asymmetric
/// for the same reason menus is — what counts as wide enough is the
/// platform's call, and a compact window is never asked to show two.
/// Extracted from the step so it is directly testable.
fn split_presentation_fits(spelling: &str, entries: usize) -> bool {
    let (class, presentation) = spelling.split_once('/').unwrap_or(("unknown", "stacked"));
    !(class == "regular" && presentation == "stacked" && entries >= 1)
}

/// The presentation spelling of an expect_split step:
/// `<size class>/<presentation>`, both halves from closed sets — the
/// expect_menu_presentation precedent, and for the same reason: a typo
/// would otherwise read as a backend disagreeing with the scene.
fn check_split_presentation(spec: &str) -> Result<(), String> {
    const CLASSES: [&str; 3] = ["unknown", "compact", "regular"];
    const PRESENTATIONS: [&str; 2] = ["split", "stacked"];
    let Some((class, presentation)) = spec.split_once('/') else {
        return Err(format!(
            "split presentation {spec:?} wants <size class>/<presentation>"
        ));
    };
    if !CLASSES.contains(&class) {
        return Err(format!(
            "split presentation {spec:?} has an unknown size class {class:?}; \
             wanted one of {CLASSES:?}"
        ));
    }
    if !PRESENTATIONS.contains(&presentation) {
        return Err(format!(
            "split presentation {spec:?} has an unknown presentation \
             {presentation:?}; wanted one of {PRESENTATIONS:?}"
        ));
    }
    Ok(())
}

/// The presentation spelling of an expect_menu_presentation step:
/// `<size class>/<presentation>`, both halves from closed sets. A
/// typo here would otherwise read as a backend disagreeing with the
/// scene, which is the most expensive way to learn you misspelled
/// "overflow" — so the grammar rejects it at parse. `unknown` IS a
/// legal size class to write: a backend that has not observed its
/// window yet must be able to say so, and a scene that asserts it is
/// making a real (if unusual) claim.
fn check_menu_presentation(spec: &str) -> Result<(), String> {
    const CLASSES: [&str; 3] = ["unknown", "compact", "regular"];
    const PRESENTATIONS: [&str; 3] = ["bar", "overflow", "none"];
    let Some((class, presentation)) = spec.split_once('/') else {
        return Err(format!(
            "menu presentation {spec:?} wants <size class>/<presentation>"
        ));
    };
    if !CLASSES.contains(&class) {
        return Err(format!(
            "menu presentation {spec:?} has an unknown size class {class:?}; \
             wanted one of {CLASSES:?}"
        ));
    }
    if !PRESENTATIONS.contains(&presentation) {
        return Err(format!(
            "menu presentation {spec:?} has an unknown presentation \
             {presentation:?}; wanted one of {PRESENTATIONS:?}"
        ));
    }
    Ok(())
}

/// The state token(s) of an expect_menu step. `value` takes a 0-based
/// option index (the choice contract's add order); the four bare
/// states take nothing — trailing junk is rejected, not ignored.
fn parse_menu_state(spec: &str) -> Result<MenuState, String> {
    let spec = spec.trim();
    match spec {
        "enabled" => return Ok(MenuState::Enabled),
        "disabled" => return Ok(MenuState::Disabled),
        "checked" => return Ok(MenuState::Checked),
        "unchecked" => return Ok(MenuState::Unchecked),
        _ => {}
    }
    if let Some((word, index)) = spec.split_once(char::is_whitespace) {
        if word == "value" {
            return index
                .trim()
                .parse::<usize>()
                .map(MenuState::Value)
                .map_err(|_| {
                    format!("expect_menu value wants a 0-based index, got {index:?}")
                });
        }
    }
    Err(format!(
        "expect_menu wants enabled|disabled|checked|unchecked|value N, got {spec:?}"
    ))
}

/// Run the scene's script on its own thread against a backend's stage.
/// Every step logs its offset from the run's start; expects accumulate,
/// and the verdict joins their observed values — "urgent: true,
/// volume: 75%" — exactly the strings the suites have always printed.
pub fn spawn(scene: &str, stage: impl Stage, log: fn(&str)) {
    // A scene with no script used to return SILENTLY: the app ran, no
    // steps executed, no verdict printed, and the runner waited out its
    // whole timeout with nothing to show. That is the silent-no-op shape
    // this repo keeps paying for, and it is worse on the Rust backends
    // because they carry 434 of the matrix's 686 legs.
    let Some(text) = script(scene) else {
        stage.finish(
            1,
            &format!(
                "KAYA_SELFTEST: FAILED (no script for scene {scene:?} — export \
                 KAYA_SELFTEST_SCRIPT with the scene's steps, or add an arm to \
                 harness::script for a standalone run)"
            ),
        );
        return;
    };
    let steps = match parse(text) {
        Ok(steps) => steps,
        Err(e) => {
            stage.finish(1, &format!("KAYA_SELFTEST: FAILED (bad script: {e})"));
            return;
        }
    };
    std::thread::spawn(move || {
        // A panic here unwinds only THIS thread; the UI thread keeps the
        // process alive, so the runner — which waits for process EXIT —
        // sees nothing and burns its whole timeout. Measured 2026-07-25
        // on Windows: a shortcut verb panicked at +714ms and the leg was
        // reported as a 328-SECOND HANG, with the real diagnosis sitting
        // unread in the output file the entire time.
        //
        // So a harness panic terminates the process. The message has
        // already been printed by the default hook; the exit code is
        // what lets the runner's `EXIT=` appear at once, turning a
        // multi-minute silent stall into a one-second labelled failure.
        // This is the harness thread, and its panic IS the verdict —
        // there is nothing left for the process to do.
        let outcome =
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                run_with_log(steps, stage, Some(log))
            }));
        if outcome.is_err() {
            // Flush what the default hook wrote before leaving; an
            // orderly exit is not available from a foreign thread on
            // every backend (WinUI's XAML apartment in particular).
            use std::io::Write;
            let _ = std::io::stderr().flush();
            let _ = std::io::stdout().flush();
            std::process::exit(1);
        }
    });
}

/// The synchronous run loop, factored out of spawn so tests can drive
/// it with a mock stage.
pub fn run(steps: Vec<Step>, stage: impl Stage) {
    run_with_log(steps, stage, None);
}

/// Recording handshake: when the runner exports KAYA_HARNESS_GATE, it
/// is recording this window, and the recorder needs time to deliver
/// its first frame (seconds, when several streams start under load).
/// Waiting for the runner's go-file means a leg cannot outrun its
/// recorder; without the variable this is a no-op. Bounded — a
/// recorder that never starts must not hang the scene.
fn gate_wait() {
    let Ok(gate) = std::env::var("KAYA_HARNESS_GATE") else {
        return;
    };
    let deadline = Instant::now() + Duration::from_secs(20);
    while !std::path::Path::new(&gate).exists() {
        if Instant::now() > deadline {
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// A recorded leg must outlive its last sample time. The extractor
/// takes the final expect's still at that step's own transcript moment,
/// and the window closes within ONE capture-frame period of that moment
/// — the verdict and exit follow the last step by milliseconds. Any
/// anchor drift then hands the covering-frame rule a teardown frame:
/// the GTK stills were the bare Xvfb root, because the arithmetic
/// anchor (kill-time minus duration) drifts ~150ms and at 15fps that is
/// two black frames. Holding the window briefly after the steps makes
/// every sampled moment a live one whatever the anchor error, on every
/// backend alike. Without a recorder this is a no-op; the pre-flight
/// failures (bad script, no expects) skip it — they ran no steps worth
/// sampling.
fn record_linger() {
    if std::env::var_os("KAYA_RECORD").is_some()
        || std::env::var_os("KAYA_HARNESS_GATE").is_some()
    {
        std::thread::sleep(Duration::from_millis(750));
    }
}

fn run_with_log(steps: Vec<Step>, stage: impl Stage, log: Option<fn(&str)>) {
    if log.is_some() {
        gate_wait();
    }
    // Offsets are relative to here — after the gate, so the recording
    // contains every step from its own t=0 onward.
    let start = Instant::now();
    let log = log.map(|log| (log, start));
    if let Some((log, _)) = log {
        // The wall-clock anchor recording mode pairs with the
        // recorder's own start stamp; step offsets stay relative.
        let epoch = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        log(&format!("KAYA_HARNESS: epoch {epoch}"));
    }
    // A script with no expects proves nothing; a transport that
    // mangled the text into a comment must fail, not pass.
    if !steps.iter().any(Step::is_assertion)
    {
        stage.finish(1, "KAYA_SELFTEST: FAILED (script has no expects)");
        return;
    }
    let mut observed = Vec::new();
    let mut failures = Vec::new();
    for step in &steps {
        if let Some((log, start)) = log {
            log(&format!(
                "KAYA_HARNESS: +{}ms {:?}",
                start.elapsed().as_millis(),
                step
            ));
        }
        // Actions run once, immediately; observations are bounded
        // retries (see POLL_DEADLINE): each arm builds a pass/fail
        // outcome, and `poll` re-evaluates a failing one until it
        // passes or the deadline lands the last failure text.
        let outcome: Option<Result<String, String>> = match step {
            Step::Settle(ms) => {
                std::thread::sleep(Duration::from_millis(*ms));
                None
            }
            Step::Click(t) => {
                stage.click(*t);
                None
            }
            Step::Toggle(t, on) => {
                stage.toggle(*t, *on);
                None
            }
            Step::SetValue(t, v) => {
                stage.set_value(*t, *v);
                None
            }
            Step::SetText(t, s) => {
                stage.set_text(*t, s);
                None
            }
            Step::SelectSection(i) => {
                stage.select_section(*i);
                None
            }
            Step::ExpectSections(n) => Some(poll(|| {
                let got = stage.section_count();
                if got == *n {
                    Ok(format!("{n} sections"))
                } else {
                    Err(format!("{got} sections, wanted {n}"))
                }
            })),
            Step::ExpectSection(want) => Some(poll(|| {
                let got = stage.active_section_title();
                if got == *want {
                    Ok(format!("section {want:?}"))
                } else {
                    Err(format!("section {got:?}, wanted {want:?}"))
                }
            })),
            Step::CloseWindow(window) => {
                // An action, silent like click: the veto grammar's
                // observable is what the scene does next.
                stage.close_window(*window);
                None
            }
            Step::FileDialogGoto(path) => {
                // An action, silent like click: expect_file_dialog is
                // what says whether it landed.
                stage.goto_directory(path);
                None
            }
            Step::FileChoose(name) => {
                // An action, silent like click: the observable is the
                // guest's reaction to the result.
                stage.choose_file(name.as_deref());
                None
            }
            Step::ExpectFileDialog(dir, names) => Some(poll(|| match stage.file_dialog_state() {
                Some((where_, rows)) => {
                    let Some(dir) = dir else {
                        return Ok("file dialog live".to_string());
                    };
                    if !where_.ends_with(dir.as_str()) {
                        return Err(format!("file dialog showing {where_:?}, wanted {dir:?}"));
                    }
                    if let Some(missing) = names.iter().find(|n| !rows.contains(n)) {
                        return Err(format!(
                            "file dialog list has {rows:?}, missing {missing:?}"
                        ));
                    }
                    Ok(format!("file dialog {dir:?} {names:?}"))
                }
                None => Err("no file dialog live".to_string()),
            })),
            Step::AlertChoose(choice) => {
                // An action, silent like click: the observable is the
                // guest's reaction to the result.
                stage.choose_alert(*choice);
                None
            }
            Step::Back(window) => {
                // An action, silent like click: the observable is
                // whether the stack popped (expect_entries) or the
                // guest's back_requested reaction.
                stage.back(window.unwrap_or(0));
                None
            }
            Step::ScrollEnd(t) => {
                if t.kind != TargetKind::Scroll {
                    Some(Err(format!("{t:?} is not a scroll target")))
                } else {
                    // An action, silent like click: expect_at_end is
                    // the observable.
                    stage.scroll_end(*t);
                    None
                }
            }
            Step::Choose(t, index) => {
                if !matches!(t.kind, TargetKind::Select | TargetKind::Radio) {
                    Some(Err(format!("{t:?} is not a choice (select/radio) target")))
                } else {
                    // An action, silent like click: `expect select#N`
                    // and the guest's value_changed reaction are the
                    // observables.
                    stage.choose(*t, *index);
                    None
                }
            }
            Step::Expect(t, want) => Some(match t.kind {
                // The target kind picks the observation: an entry
                // reads its own displayed text, an image its decoded
                // size, a label its text — and nothing else reads at
                // all: routing any other kind to read_label would
                // index the LABELS registry with a foreign target and
                // silently read a different widget (the interpreters
                // already reject these loudly).
                TargetKind::Entry
                | TargetKind::Textarea
                | TargetKind::Image
                | TargetKind::Label
                | TargetKind::Progress
                | TargetKind::Select
                | TargetKind::Radio => poll(|| {
                    let got = match t.kind {
                        TargetKind::Entry | TargetKind::Textarea => stage.read_text(*t),
                        TargetKind::Image => stage.image_size(*t),
                        TargetKind::Label => stage.read_label(*t),
                        TargetKind::Progress => stage.progress_state(*t),
                        TargetKind::Select | TargetKind::Radio => stage.selected_label(*t),
                        _ => unreachable!(),
                    };
                    if got == *want {
                        Ok(got)
                    } else {
                        Err(format!("{t:?} reads {got:?}, wanted {want:?}"))
                    }
                }),
                other => Err(format!(
                    "expect reads labels, entries, images, progress and selects — not {other:?}"
                )),
            }),
            Step::ExpectOrder(t, want) => {
                // Container verbs take container targets and nothing
                // else — resolving a label target against a container
                // registry (or vice versa) would silently read a
                // DIFFERENT widget, the false-verdict class the
                // interpreters already reject loudly.
                if !matches!(t.kind, TargetKind::Column | TargetKind::Row) {
                    Some(Err(format!("{t:?} is not a container target")))
                } else {
                    Some(poll(|| {
                        let got = stage.child_texts(*t);
                        if got == *want {
                            Ok(got)
                        } else {
                            Err(format!("{t:?} ordered {got:?}, wanted {want:?}"))
                        }
                    }))
                }
            }
            Step::ExpectShares(t, want) => {
                if !matches!(t.kind, TargetKind::Column | TargetKind::Row) {
                    Some(Err(format!("{t:?} is not a container target")))
                } else {
                    Some(poll(|| {
                        let got = stage.child_shares(*t);
                        if got == *want {
                            Ok(got)
                        } else {
                            Err(format!("{t:?} splits {got:?}, wanted {want:?}"))
                        }
                    }))
                }
            }
            Step::ExpectRootFills => Some(poll(|| {
                // Empty means fills; anything else is the platform's
                // own description of the hug, for the failure text
                // alone — the pass observation is the byte-identical
                // "root fills" on every backend.
                let hug = stage.root_fills();
                if hug.is_empty() {
                    Ok("root fills".to_owned())
                } else {
                    Err(format!("root hugs ({hug})"))
                }
            })),
            Step::ExpectTitle(window, want) => {
                // The REAL materialized title (the title bar / task
                // label), never the scene model's copy — a backend
                // that ignored the write must fail. The pass
                // observation is byte-identical on every backend; an
                // explicit window target prefixes it.
                let id = window.unwrap_or(0);
                let prefix = match window {
                    Some(n) => format!("window#{n} "),
                    None => String::new(),
                };
                Some(poll(|| {
                    let got = stage.window_title(id);
                    if got == *want {
                        Ok(format!("{prefix}title {want:?}"))
                    } else {
                        Err(format!("{prefix}title {got:?}, wanted {want:?}"))
                    }
                }))
            }
            Step::ExpectWindowSize(window, w, h) => {
                // The surface's REAL content extent against the
                // advisory request, within 2 device units.
                let id = window.unwrap_or(0);
                let prefix = match window {
                    Some(n) => format!("window#{n} "),
                    None => String::new(),
                };
                Some(poll(|| {
                    let (gw, gh) = stage.window_content_size(id);
                    if (gw - w).abs() <= 2.0 && (gh - h).abs() <= 2.0 {
                        Ok(format!("{prefix}window {}x{}", *w as i64, *h as i64))
                    } else {
                        Err(format!(
                            "{prefix}window {}x{}, wanted {}x{}",
                            gw as i64, gh as i64, *w as i64, *h as i64
                        ))
                    }
                }))
            }
            Step::ExpectWindows(n) => Some(poll(|| {
                let got = stage.window_count();
                if got == *n {
                    Ok(format!("windows {n}"))
                } else {
                    Err(format!("windows {got}, wanted {n}"))
                }
            })),
            Step::ExpectAlert(window, want) => {
                // The REAL presented title, never the request's copy —
                // a backend that materialized nothing must fail here.
                let id = window.unwrap_or(0);
                let prefix = match window {
                    Some(n) => format!("window#{n} "),
                    None => String::new(),
                };
                Some(poll(|| match stage.alert_title(id) {
                    Some(got) if got == *want => Ok(format!("{prefix}alert {want:?}")),
                    Some(got) => Err(format!("{prefix}alert {got:?}, wanted {want:?}")),
                    None => Err(format!("{prefix}no alert live, wanted {want:?}")),
                }))
            }
            Step::ExpectAlerts(n) => Some(poll(|| {
                let got = stage.alert_count();
                if got == *n {
                    Ok(format!("alerts {n}"))
                } else {
                    Err(format!("alerts {got}, wanted {n}"))
                }
            })),
            Step::ExpectEntries(window, n) => {
                let id = window.unwrap_or(0);
                let prefix = match window {
                    Some(w) => format!("window#{w} "),
                    None => String::new(),
                };
                Some(poll(|| {
                    let got = stage.entry_count(id);
                    if got == *n {
                        Ok(format!("{prefix}entries {n}"))
                    } else {
                        Err(format!("{prefix}entries {got}, wanted {n}"))
                    }
                }))
            }
            Step::ExpectOverflow(t) => {
                if t.kind != TargetKind::Scroll {
                    Some(Err(format!("{t:?} is not a scroll target")))
                } else {
                    Some(poll(|| {
                        let slack = stage.scroll_overflow(*t);
                        if slack.is_empty() {
                            Ok(format!("{} overflows", target_spec(t)))
                        } else {
                            Err(format!("{} fits ({slack})", target_spec(t)))
                        }
                    }))
                }
            }
            Step::ExpectAtEnd(t) => {
                if t.kind != TargetKind::Scroll {
                    Some(Err(format!("{t:?} is not a scroll target")))
                } else {
                    Some(poll(|| {
                        let off = stage.scroll_at_end(*t);
                        if off.is_empty() {
                            Ok(format!("{} at end", target_spec(t)))
                        } else {
                            Err(format!("{} short of end ({off})", target_spec(t)))
                        }
                    }))
                }
            }
            Step::ExpectFills(t) => {
                if !matches!(t.kind, TargetKind::Column | TargetKind::Row) {
                    Some(Err(format!("{t:?} is not a container target")))
                } else {
                    // Empty means the children span the content box;
                    // the pass observation is the byte-identical
                    // "column#0 fills" every backend and interpreter
                    // emits.
                    Some(poll(|| {
                        let slack = stage.container_fills(*t);
                        if slack.is_empty() {
                            Ok(format!("{} fills", target_spec(t)))
                        } else {
                            Err(format!("{} leaves leftover ({slack})", target_spec(t)))
                        }
                    }))
                }
            }
            Step::ExpectAligned(t, want) => {
                if !matches!(t.kind, TargetKind::Column | TargetKind::Row) {
                    Some(Err(format!("{t:?} is not a container target")))
                } else {
                    Some(poll(|| {
                        let got = stage.cross_mode(*t);
                        if got == *want {
                            Ok(format!("{} aligns {got}", target_spec(t)))
                        } else {
                            Err(format!(
                                "{} aligns {got:?}, wanted {want:?}",
                                target_spec(t)
                            ))
                        }
                    }))
                }
            }
            Step::ExpectGridColumns(t, want) => {
                if t.kind != TargetKind::Grid {
                    Some(Err(format!("{t:?} is not a grid target")))
                } else {
                    Some(poll(|| {
                        let off = stage.grid_columns(*t, *want);
                        if off.is_empty() {
                            Ok(format!("{} columns {want}", target_spec(t)))
                        } else {
                            Err(format!("{} misaligned ({off})", target_spec(t)))
                        }
                    }))
                }
            }
            Step::ExpectFocused(t) => Some(poll(|| {
                if stage.is_focused(*t) {
                    Ok(format!("{t:?} focused"))
                } else {
                    Err(format!("{t:?} does not hold focus"))
                }
            })),
            Step::MenuActivate(path) => {
                // An action, silent like click: the fold's reaction
                // (or the next expect_menu) is the observable. Where
                // the path resolves — the bar or the OPEN context
                // menu — is the stage's own presentation state.
                stage.menu_activate(path);
                None
            }
            Step::ContextOpen(t) => {
                // v1 rejects context menus on editable text (their
                // native menus are dress — scene.rs refuses the
                // attach), so driving the gesture there would probe a
                // menu that cannot exist: the false-verdict class the
                // container verbs reject loudly.
                if matches!(t.kind, TargetKind::Entry | TargetKind::Textarea) {
                    Some(Err(format!(
                        "{t:?} is editable text — its context menu is dress, not a context_open target"
                    )))
                } else {
                    // An action, silent like click: the following
                    // menu_activate's effect is the observable.
                    stage.context_open(*t);
                    None
                }
            }
            Step::Shortcut(spelling) => {
                // An action, silent like click: the SAME
                // menu_activated the item's direct activation emits
                // is the observable, read back through the fold.
                stage.shortcut(spelling);
                None
            }
            Step::ExpectAx(target, want) => Some(poll(|| {
                let got = stage.ax(*target);
                if got == *want {
                    Ok(format!("ax {want:?}"))
                } else {
                    Err(format!("ax {got:?}, wanted {want:?}"))
                }
            })),
            Step::ExpectAxHint(target, want) => Some(poll(|| {
                let got = stage.ax_hint(*target);
                if got == *want {
                    Ok(format!("ax hint {want:?}"))
                } else {
                    Err(format!("ax hint {got:?}, wanted {want:?}"))
                }
            })),
            Step::ExpectMenus(n) => Some(poll(|| {
                let got = stage.menu_count();
                if got == *n {
                    Ok(format!("{n} menus"))
                } else {
                    Err(format!("{got} menus, wanted {n}"))
                }
            })),
            Step::ResizeWindow(window, w, h) => {
                stage.resize_window(window.unwrap_or(0), *w, *h);
                None
            }
            Step::ExpectSplit(want) => Some(poll(|| {
                let got = stage.split_presentation();
                let Some(want) = want else {
                    // The bare form. Lane-INDEPENDENT by construction:
                    // a shared scene compares this byte-for-byte on
                    // every platform, so it cannot echo a reading that
                    // legitimately differs.
                    return if split_presentation_fits(&got, stage.entry_count(0)) {
                        Ok("split fits".to_owned())
                    } else {
                        Err(format!(
                            "presentation {got}: a regular window must not show \
                             one pane while its stack holds two"
                        ))
                    };
                };
                if got == *want {
                    Ok(format!("split {got}"))
                } else {
                    Err(format!("split {got}, wanted {want}"))
                }
            })),
            Step::ExpectMenuPresentation(want) => Some(poll(|| {
                let got = stage.menu_presentation();
                let Some(want) = want else {
                    // The bare form. The observation string must be
                    // lane-INDEPENDENT: a shared scene compares it
                    // byte-for-byte across every platform, so it cannot
                    // echo a value that legitimately differs.
                    return if menu_presentation_fits(&got) {
                        Ok("presentation fits".to_owned())
                    } else {
                        Err(format!(
                            "presentation {got}: a regular window must not \
                             hide its catalog behind the compact overflow"
                        ))
                    };
                };
                if got == *want {
                    Ok(format!("presentation {want}"))
                } else {
                    Err(format!("presentation {got}, wanted {want}"))
                }
            })),
            Step::ExpectMenu(path, want) => {
                let want_s = want.spelling();
                Some(poll(|| {
                    let got = stage.menu_state(path, want.aspect());
                    if got == want_s {
                        // Byte-identical on every backend: the path in
                        // its quoted spelling, then the state token(s).
                        Ok(format!("menu {path:?} {want_s}"))
                    } else {
                        Err(format!("menu {path:?} reads {got:?}, wanted {want_s:?}"))
                    }
                }))
            }
        };
        match outcome {
            Some(Ok(o)) => observed.push(o),
            Some(Err(e)) => failures.push(e),
            None => {}
        }
    }
    record_linger();
    if failures.is_empty() {
        stage.finish(0, &format!("KAYA_SELFTEST: OK ({})", observed.join(", ")));
    } else {
        stage.finish(1, &format!("KAYA_SELFTEST: FAILED ({})", failures.join("; ")));
    }
}

/// The steps-file spelling of a target — "column#0" — for observation
/// strings that echo their target. One implementation so the pass
/// observations stay byte-identical; the interpreters emit the same
/// spelling from their own runners.
fn target_spec(t: &Target) -> String {
    let kind = match t.kind {
        TargetKind::Button => "button",
        TargetKind::Checkbox => "checkbox",
        TargetKind::Slider => "slider",
        TargetKind::Entry => "entry",
        TargetKind::Label => "label",
        TargetKind::Column => "column",
        TargetKind::Row => "row",
        TargetKind::Image => "image",
        TargetKind::Scroll => "scroll",
        TargetKind::Progress => "progress",
        TargetKind::Select => "select",
        TargetKind::Radio => "radio",
        TargetKind::Grid => "grid",
        TargetKind::Textarea => "textarea",
    };
    if t.index < 0 {
        format!("{kind}#last")
    } else {
        format!("{kind}#{}", t.index)
    }
}

/// Format child main-axis extents as whole-percentage shares of their
/// sum, joined with `,` — the one implementation every backend's
/// `child_shares` formats through.
///
/// Shared because the *rounding* has to be identical everywhere, not
/// just the arithmetic: expect_shares compares byte-for-byte, so a
/// backend that rounded 24.6 to 24 while another rounded to 25 would
/// fail a leg over a formatting difference and read as a layout bug.
/// An empty container, or one whose children are all zero-extent,
/// reports the empty string rather than dividing by zero.
pub fn shares(extents: &[f64]) -> String {
    let total: f64 = extents.iter().sum();
    if total <= 0.0 {
        return String::new();
    }
    extents
        .iter()
        .map(|e| format!("{}", (e / total * 100.0).round() as i64))
        .collect::<Vec<_>>()
        .join(",")
}

/// Resolve `#last` against a registry length; panics on out-of-range,
/// which is a script bug worth dying loudly for.
/// The observation contract: every expect is a BOUNDED RETRY — the
/// predicate is polled until it holds or the deadline passes
/// (ratified 2026-07-22, replacing scripted settles: fixed sleeps
/// became actual latency, and the pacing race class died at the
/// root). One uniform mechanism, no per-platform event plumbing: the
/// poll interval is noise next to the settles it replaced, and the
/// deadline keeps a wrong scene loudly failing with its last read.
/// The FIRST expect of a script doubles as the scene-ready wait —
/// scripts open with an expect of initial state (check-steps holds
/// the line) — so reads must be TOTAL: a missing target is a
/// retryable non-match ("no such target"), never a panic
/// (try_resolve; the interpreters were already total).
pub const POLL_INTERVAL: Duration = Duration::from_millis(20);
pub const POLL_DEADLINE: Duration = Duration::from_secs(5);

fn poll(mut eval: impl FnMut() -> Result<String, String>) -> Result<String, String> {
    let deadline = Instant::now() + POLL_DEADLINE;
    loop {
        let outcome = eval();
        if outcome.is_ok() || Instant::now() >= deadline {
            return outcome;
        }
        std::thread::sleep(POLL_INTERVAL);
    }
}

/// The total flavor for OBSERVATION reads (retried, so absence is a
/// non-match, not a bug — the scene may simply not have applied
/// yet). Actions keep the panicking `resolve`: they run only after
/// an expect proved their target's scene state, so a miss there IS a
/// bug.
pub fn try_resolve(index: isize, len: usize) -> Option<usize> {
    if index < 0 {
        len.checked_sub(index.unsigned_abs())
    } else {
        let i = index as usize;
        (i < len).then_some(i)
    }
}

pub fn resolve(index: isize, len: usize) -> usize {
    if index < 0 {
        len.checked_sub(index.unsigned_abs())
            .unwrap_or_else(|| panic!("kaya: harness target #last of an empty registry"))
    } else {
        let i = index as usize;
        assert!(i < len, "kaya: harness target #{index} of {len}");
        i
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use std::sync::mpsc::Sender;

    #[test]
    fn scripts_parse_and_grammar_round_trips() {
        for scene in ["entry", "gallery", "todos", "reorder", "feed", "align", "menus", "1"] {
            parse(script(scene).unwrap()).unwrap();
        }
        let steps = parse(
            "# c\nsettle 5; click button#last\ntoggle checkbox#0 on\n\
             set_value slider#0 0.75;set_text entry#0 \"a b\"\nexpect label#1 \"x\"",
        )
        .unwrap();
        assert_eq!(steps.len(), 6);
        assert_eq!(steps[1], Step::Click(Target { kind: TargetKind::Button, index: -1 }));
        assert_eq!(
            steps[4],
            Step::SetText(Target { kind: TargetKind::Entry, index: 0 }, "a b".into())
        );
        assert!(parse("warp reality#0").is_err());
        assert_eq!(resolve(-1, 3), 2);
        assert_eq!(resolve(1, 3), 1);
        // The quoted-string escapes, byte-exact: `\n` (a textarea's
        // newline must ride a line-oriented script), `\r` (the paste
        // stand-in that proves the backends' LF normalization), `\\`
        // (the escape's own spelling), and unknown escapes pass
        // through verbatim. All three interpreters must match this.
        assert_eq!(
            parse(r#"set_text textarea#0 "a\r\nb\nc\\d\qe""#).unwrap()[0],
            Step::SetText(
                Target { kind: TargetKind::Textarea, index: 0 },
                "a\r\nb\nc\\d\\qe".into()
            )
        );
        assert_eq!(
            parse("expect_shares column#1 \"25,75\"").unwrap()[0],
            Step::ExpectShares(
                Target { kind: TargetKind::Column, index: 1 },
                "25,75".into()
            )
        );
    }

    /// Shares are percentages of the children's *sum*, so container
    /// spacing and padding — platform metrics both — stay out of the
    /// number, and every backend rounds identically.
    #[test]
    fn shares_are_percentages_of_the_child_sum() {
        assert_eq!(shares(&[78.0, 234.0]), "25,75");
        // Same split, different absolute metrics: the whole point.
        assert_eq!(shares(&[7.8, 23.4]), "25,75");
        // Spacing is not subtracted here because it was never added:
        // a container 8pt wider does not move the shares.
        assert_eq!(shares(&[1.0, 1.0, 2.0]), "25,25,50");
        // Degenerate containers report nothing rather than dividing by
        // zero, so a backend cannot pass a leg with a collapsed tree.
        assert_eq!(shares(&[]), "");
        assert_eq!(shares(&[0.0, 0.0]), "");
    }

    /// A `;` inside a comment is prose, not a statement separator —
    /// the regression that once turned "…; both labels…" into steps.
    #[test]
    fn comments_swallow_their_semicolons() {
        let steps = parse("# wait; settle 999; chaos\nexpect label#0 \"x\"").unwrap();
        assert_eq!(steps.len(), 1);
    }

    /// expect routes by target kind (entry reads the field, labels
    /// read label text) and expect_focused both parses and counts as
    /// an expect for the zero-expect guard.
    #[test]
    fn entry_expect_and_focus_route_and_count() {
        let steps =
            parse("expect entry#0 \"entry-text\"\nexpect_focused entry#0").unwrap();
        assert_eq!(steps[1], Step::ExpectFocused(Target { kind: TargetKind::Entry, index: 0 }));
        let (tx, rx) = std::sync::mpsc::channel();
        run(steps, MockStage { seen: &SEEN, verdict: tx });
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 0, "{verdict}");
        assert!(verdict.contains("entry-text"), "{verdict}");
        assert!(verdict.contains("focused"), "{verdict}");
    }

    /// A stage that records interactions and reports the verdict back
    /// through a channel, so tests can watch a whole run.
    struct MockStage {
        seen: &'static Mutex<Vec<String>>,
        verdict: Sender<(i32, String)>,
    }

    impl Stage for MockStage {
        fn click(&self, t: Target) {
            self.seen.lock().unwrap().push(format!("click {t:?}"));
        }
        fn toggle(&self, _: Target, _: bool) {}
        fn set_value(&self, _: Target, _: f64) {}
        fn set_text(&self, _: Target, _: &str) {}
        fn read_label(&self, _: Target) -> String {
            "ok-text".into()
        }
        fn read_text(&self, _: Target) -> String {
            "entry-text".into()
        }
        fn is_focused(&self, _: Target) -> bool {
            true
        }
        fn image_size(&self, _: Target) -> String {
            "2x2".into()
        }
        fn child_texts(&self, _: Target) -> String {
            "a|b".into()
        }
        fn child_shares(&self, _: Target) -> String {
            "25,75".into()
        }
        fn window_title(&self, _: u64) -> String {
            "mock".to_owned()
        }
        fn window_content_size(&self, _: u64) -> (f64, f64) {
            (540.0, 330.0)
        }
        fn close_window(&self, _: u64) {}
        fn entry_count(&self, _: u64) -> usize {
            0
        }
        fn back(&self, _: u64) {}
        fn scroll_overflow(&self, _: Target) -> String {
            String::new()
        }
        fn scroll_end(&self, _: Target) {}
        fn scroll_at_end(&self, _: Target) -> String {
            String::new()
        }
        fn choose(&self, _: Target, _: usize) {}
        fn selected_label(&self, _: Target) -> String {
            String::new()
        }
        fn grid_columns(&self, _: Target, _: usize) -> String {
            String::new()
        }
        fn progress_state(&self, _: Target) -> String {
            String::new()
        }
        fn window_count(&self) -> usize {
            1
        }
        fn alert_title(&self, _window: u64) -> Option<String> {
            None
        }
        fn choose_alert(&self, _choice: u32) {}
        fn file_dialog_state(&self) -> Option<(String, Vec<String>)> {
            None
        }
        fn choose_file(&self, _: Option<&str>) {}
        fn goto_directory(&self, _: &str) {}
        fn alert_count(&self) -> usize {
            0
        }
        fn root_fills(&self) -> String {
            String::new()
        }
        fn container_fills(&self, _: Target) -> String {
            String::new()
        }
        fn cross_mode(&self, _: Target) -> String {
            "center".into()
        }
        fn section_count(&self) -> usize {
            0
        }
        fn active_section_title(&self) -> String {
            String::new()
        }
        fn select_section(&self, _: usize) {}
        fn menu_activate(&self, path: &str) {
            self.seen.lock().unwrap().push(format!("menu_activate {path}"));
        }
        fn context_open(&self, t: Target) {
            self.seen.lock().unwrap().push(format!("context_open {t:?}"));
        }
        fn menu_count(&self) -> usize {
            3
        }
        fn menu_presentation(&self) -> String {
            "regular/bar".to_owned()
        }
        fn resize_window(&self, _: u64, _: f64, _: f64) {}
        fn split_presentation(&self) -> String {
            "unknown/stacked".to_owned()
        }
        fn ax(&self, _: Target) -> String {
            "button/Save".to_owned()
        }
        fn ax_hint(&self, _: Target) -> String {
            "save the draft".to_owned()
        }
        fn menu_state(&self, _: &str, aspect: MenuAspect) -> String {
            match aspect {
                MenuAspect::Enablement => "disabled".to_owned(),
                MenuAspect::Checkedness => "checked".to_owned(),
                MenuAspect::Value => "value 1".to_owned(),
            }
        }
        fn shortcut(&self, spelling: &str) {
            self.seen.lock().unwrap().push(format!("shortcut {spelling}"));
        }
        fn finish(&self, code: i32, verdict: &str) {
            let _ = self.verdict.send((code, verdict.to_owned()));
        }
    }

    static SEEN: Mutex<Vec<String>> = Mutex::new(Vec::new());

    /// The zero-expect guard fires: a script a transport mangled into
    /// nothing (or someone forgot to assert in) must fail, not pass.
    #[test]
    fn a_script_with_no_expects_fails() {
        let (tx, rx) = std::sync::mpsc::channel();
        run(
            parse("click button#0").unwrap(),
            MockStage { seen: &SEEN, verdict: tx },
        );
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 1);
        assert!(verdict.contains("no expects"), "{verdict}");
    }

    /// expect_order parses like expect, counts as an expect for the
    /// zero-expect guard, and compares against the stage's child_texts.
    #[test]
    fn expect_order_is_an_expect() {
        let steps = parse("expect_order column#0 \"a|b\"").unwrap();
        assert_eq!(
            steps[0],
            Step::ExpectOrder(Target { kind: TargetKind::Column, index: 0 }, "a|b".into())
        );
        let (tx, rx) = std::sync::mpsc::channel();
        run(steps, MockStage { seen: &SEEN, verdict: tx });
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 0, "{verdict}");
        assert_eq!(verdict, "KAYA_SELFTEST: OK (a|b)");
        let (tx, rx) = std::sync::mpsc::channel();
        run(
            parse("expect_order column#0 \"b|a\"").unwrap(),
            MockStage { seen: &SEEN, verdict: tx },
        );
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 1);
        assert!(verdict.contains("ordered"), "{verdict}");
    }

    /// expect_shares counts as an expect for the zero-expect guard, and
    /// compares against the stage's child_shares.
    ///
    /// The zero-expect half is the load-bearing half: a scene whose only
    /// assertion is a layout one — which is exactly what a conformance
    /// scene is — would otherwise be rejected as asserting nothing, and
    /// the natural "fix" is to weaken the scene rather than the guard.
    #[test]
    fn expect_shares_is_an_expect() {
        let steps = parse("expect_shares column#0 \"25,75\"").unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        run(steps, MockStage { seen: &SEEN, verdict: tx });
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 0, "{verdict}");
        assert_eq!(verdict, "KAYA_SELFTEST: OK (25,75)");
        // A wrong split fails loudly rather than being tolerated: the
        // whole point of the verb is that an ordinal or equal-split
        // implementation cannot pass.
        let (tx, rx) = std::sync::mpsc::channel();
        run(
            parse("expect_shares column#0 \"50,50\"").unwrap(),
            MockStage { seen: &SEEN, verdict: tx },
        );
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 1);
        assert!(verdict.contains("splits"), "{verdict}");
    }

    /// expect_root_fills parses bare (a target would be a lie — the
    /// mounted root is the only thing it can mean), counts as an expect
    /// for the zero-expect guard, and reads the stage's root_fills:
    /// empty is the fill, anything else is the hug's description.
    #[test]
    fn expect_root_fills_is_an_expect() {
        let steps = parse("expect_root_fills").unwrap();
        assert_eq!(steps[0], Step::ExpectRootFills);
        assert!(parse("expect_root_fills column#0").is_err());
        let (tx, rx) = std::sync::mpsc::channel();
        run(steps, MockStage { seen: &SEEN, verdict: tx });
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 0, "{verdict}");
        assert_eq!(verdict, "KAYA_SELFTEST: OK (root fills)");
        struct Hugger(Sender<(i32, String)>);
        impl Stage for Hugger {
            fn click(&self, _: Target) {}
            fn toggle(&self, _: Target, _: bool) {}
            fn set_value(&self, _: Target, _: f64) {}
            fn set_text(&self, _: Target, _: &str) {}
            fn read_label(&self, _: Target) -> String {
                String::new()
            }
            fn read_text(&self, _: Target) -> String {
                String::new()
            }
            fn is_focused(&self, _: Target) -> bool {
                false
            }
            fn image_size(&self, _: Target) -> String {
                String::new()
            }
            fn child_texts(&self, _: Target) -> String {
                String::new()
            }
            fn child_shares(&self, _: Target) -> String {
                String::new()
            }
            fn window_title(&self, _: u64) -> String {
            "mock".to_owned()
        }
        fn window_content_size(&self, _: u64) -> (f64, f64) {
            (540.0, 330.0)
        }
        fn close_window(&self, _: u64) {}
        fn entry_count(&self, _: u64) -> usize {
            0
        }
        fn back(&self, _: u64) {}
        fn scroll_overflow(&self, _: Target) -> String {
            String::new()
        }
        fn scroll_end(&self, _: Target) {}
        fn scroll_at_end(&self, _: Target) -> String {
            String::new()
        }
        fn choose(&self, _: Target, _: usize) {}
        fn selected_label(&self, _: Target) -> String {
            String::new()
        }
        fn grid_columns(&self, _: Target, _: usize) -> String {
            String::new()
        }
        fn progress_state(&self, _: Target) -> String {
            String::new()
        }
        fn window_count(&self) -> usize {
            1
        }
        fn root_fills(&self) -> String {
                "34x27pt inside 390x844pt".into()
            }
            fn container_fills(&self, _: Target) -> String {
                "children span 92pt of 298pt".into()
            }
            fn cross_mode(&self, _: Target) -> String {
                "start".into()
            }
            fn alert_title(&self, _window: u64) -> Option<String> {
            None
        }
        fn choose_alert(&self, _choice: u32) {}
        fn file_dialog_state(&self) -> Option<(String, Vec<String>)> {
            None
        }
        fn choose_file(&self, _: Option<&str>) {}
        fn goto_directory(&self, _: &str) {}
        fn alert_count(&self) -> usize {
            0
        }
        fn section_count(&self) -> usize {
            0
        }
        fn active_section_title(&self) -> String {
            String::new()
        }
        fn select_section(&self, _: usize) {}
        fn menu_activate(&self, _: &str) {}
        fn context_open(&self, _: Target) {}
        fn menu_count(&self) -> usize {
            0
        }
        fn menu_presentation(&self) -> String {
            "regular/none".to_owned()
        }
        fn resize_window(&self, _: u64, _: f64, _: f64) {}
        fn split_presentation(&self) -> String {
            "unknown/stacked".to_owned()
        }
        fn ax(&self, _: Target) -> String {
            "unknown/".to_owned()
        }
        fn ax_hint(&self, _: Target) -> String {
            String::new()
        }
        fn menu_state(&self, _: &str, _: MenuAspect) -> String {
            String::new()
        }
        fn shortcut(&self, _: &str) {}
        fn finish(&self, code: i32, verdict: &str) {
                let _ = self.0.send((code, verdict.to_owned()));
            }
        }
        let (tx, rx) = std::sync::mpsc::channel();
        run(parse("expect_root_fills").unwrap(), Hugger(tx));
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 1);
        assert!(verdict.contains("root hugs"), "{verdict}");
    }

    /// expect_fills takes a container target, counts as an expect for
    /// the zero-expect guard, emits the byte-identical "column#0
    /// fills" observation on pass, and fails with the platform's slack
    /// description otherwise. The pass half is the load-bearing half:
    /// growers that hold their ratio at natural size pass every share
    /// assertion while consuming nothing — this is the verb that sees
    /// the leftover (the AppKit gravity-areas miss, found only because
    /// a 540x330 window made 200pt of slack impossible to overlook).
    #[test]
    fn expect_fills_is_an_expect() {
        let steps = parse("expect_fills column#0").unwrap();
        assert_eq!(
            steps[0],
            Step::ExpectFills(Target { kind: TargetKind::Column, index: 0 })
        );
        let (tx, rx) = std::sync::mpsc::channel();
        run(steps, MockStage { seen: &SEEN, verdict: tx });
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 0, "{verdict}");
        assert_eq!(verdict, "KAYA_SELFTEST: OK (column#0 fills)");
        // A non-container target is the false-verdict class: resolving
        // label#0 against a container registry would read a different
        // widget. Rejected loudly, exactly like the other container
        // verbs.
        let (tx, rx) = std::sync::mpsc::channel();
        run(
            parse("expect_fills label#0").unwrap(),
            MockStage { seen: &SEEN, verdict: tx },
        );
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 1);
        assert!(verdict.contains("not a container target"), "{verdict}");
        // Slack fails loudly: the whole point of the verb is that
        // ratio-at-minimum cannot pass it.
        struct Pooler(Sender<(i32, String)>);
        impl Stage for Pooler {
            fn click(&self, _: Target) {}
            fn toggle(&self, _: Target, _: bool) {}
            fn set_value(&self, _: Target, _: f64) {}
            fn set_text(&self, _: Target, _: &str) {}
            fn read_label(&self, _: Target) -> String {
                String::new()
            }
            fn read_text(&self, _: Target) -> String {
                String::new()
            }
            fn is_focused(&self, _: Target) -> bool {
                false
            }
            fn image_size(&self, _: Target) -> String {
                String::new()
            }
            fn child_texts(&self, _: Target) -> String {
                String::new()
            }
            fn child_shares(&self, _: Target) -> String {
                String::new()
            }
            fn window_title(&self, _: u64) -> String {
            "mock".to_owned()
        }
        fn window_content_size(&self, _: u64) -> (f64, f64) {
            (540.0, 330.0)
        }
        fn close_window(&self, _: u64) {}
        fn entry_count(&self, _: u64) -> usize {
            0
        }
        fn back(&self, _: u64) {}
        fn scroll_overflow(&self, _: Target) -> String {
            String::new()
        }
        fn scroll_end(&self, _: Target) {}
        fn scroll_at_end(&self, _: Target) -> String {
            String::new()
        }
        fn choose(&self, _: Target, _: usize) {}
        fn selected_label(&self, _: Target) -> String {
            String::new()
        }
        fn grid_columns(&self, _: Target, _: usize) -> String {
            String::new()
        }
        fn progress_state(&self, _: Target) -> String {
            String::new()
        }
        fn window_count(&self) -> usize {
            1
        }
        fn root_fills(&self) -> String {
                String::new()
            }
            fn container_fills(&self, _: Target) -> String {
                "children span 92pt of 298pt".into()
            }
            fn cross_mode(&self, _: Target) -> String {
                "start".into()
            }
            fn alert_title(&self, _window: u64) -> Option<String> {
            None
        }
        fn choose_alert(&self, _choice: u32) {}
        fn file_dialog_state(&self) -> Option<(String, Vec<String>)> {
            None
        }
        fn choose_file(&self, _: Option<&str>) {}
        fn goto_directory(&self, _: &str) {}
        fn alert_count(&self) -> usize {
            0
        }
        fn section_count(&self) -> usize {
            0
        }
        fn active_section_title(&self) -> String {
            String::new()
        }
        fn select_section(&self, _: usize) {}
        fn menu_activate(&self, _: &str) {}
        fn context_open(&self, _: Target) {}
        fn menu_count(&self) -> usize {
            0
        }
        fn menu_presentation(&self) -> String {
            "regular/none".to_owned()
        }
        fn resize_window(&self, _: u64, _: f64, _: f64) {}
        fn split_presentation(&self) -> String {
            "unknown/stacked".to_owned()
        }
        fn ax(&self, _: Target) -> String {
            "unknown/".to_owned()
        }
        fn ax_hint(&self, _: Target) -> String {
            String::new()
        }
        fn menu_state(&self, _: &str, _: MenuAspect) -> String {
            String::new()
        }
        fn shortcut(&self, _: &str) {}
        fn finish(&self, code: i32, verdict: &str) {
                let _ = self.0.send((code, verdict.to_owned()));
            }
        }
        let (tx, rx) = std::sync::mpsc::channel();
        run(parse("expect_fills row#0").unwrap(), Pooler(tx));
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 1);
        assert!(verdict.contains("row#0 leaves leftover"), "{verdict}");
        assert!(verdict.contains("92pt of 298pt"), "{verdict}");
    }

    /// expect_aligned takes a container target and a mode, counts as
    /// an expect, emits the byte-identical "column#0 aligns center"
    /// observation on match, and fails with the stage's classification
    /// otherwise — the classification coming from geometry, so a
    /// backend that ignores the prop cannot pass by echoing the model.
    #[test]
    fn expect_aligned_is_an_expect() {
        let steps = parse("expect_aligned column#0 \"center\"").unwrap();
        assert_eq!(
            steps[0],
            Step::ExpectAligned(
                Target { kind: TargetKind::Column, index: 0 },
                "center".into()
            )
        );
        let (tx, rx) = std::sync::mpsc::channel();
        run(steps, MockStage { seen: &SEEN, verdict: tx });
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 0, "{verdict}");
        assert_eq!(verdict, "KAYA_SELFTEST: OK (column#0 aligns center)");
        let (tx, rx) = std::sync::mpsc::channel();
        run(
            parse("expect_aligned label#0 \"center\"").unwrap(),
            MockStage { seen: &SEEN, verdict: tx },
        );
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 1);
        assert!(verdict.contains("not a container target"), "{verdict}");
        let (tx, rx) = std::sync::mpsc::channel();
        run(
            parse("expect_aligned column#0 \"end\"").unwrap(),
            MockStage { seen: &SEEN, verdict: tx },
        );
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 1);
        assert!(verdict.contains("aligns \"center\", wanted \"end\""), "{verdict}");
    }

    /// The verdict format is load-bearing: the suites grep
    /// "KAYA_SELFTEST: OK" and the parenthesized text is the observed
    /// expects joined with ", ".
    #[test]
    fn verdict_joins_observed_expects() {
        let (tx, rx) = std::sync::mpsc::channel();
        run(
            parse("expect label#0 \"ok-text\";expect label#1 \"ok-text\"").unwrap(),
            MockStage { seen: &SEEN, verdict: tx },
        );
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 0);
        assert_eq!(verdict, "KAYA_SELFTEST: OK (ok-text, ok-text)");
    }

    /// The five menu verbs parse into their Step arms, including a
    /// label with an internal space (the quoted-prefix helper must not
    /// shear on whitespace) and each of the five state spellings.
    #[test]
    fn menu_grammar_parses() {
        let steps = parse(
            "menu_activate \"File>Save\"\n\
             context_open label#1\n\
             expect_menu \"File>Save As\" enabled\n\
             expect_menu \"File>Export\" disabled\n\
             expect_menu \"View>Details\" checked\n\
             expect_menu \"View>Details\" unchecked\n\
             expect_menu \"Sort\" value 1\n\
             expect_menus 3\n\
             shortcut \"primary+s\"",
        )
        .unwrap();
        assert_eq!(steps[0], Step::MenuActivate("File>Save".into()));
        assert_eq!(
            steps[1],
            Step::ContextOpen(Target { kind: TargetKind::Label, index: 1 })
        );
        assert_eq!(
            steps[2],
            Step::ExpectMenu("File>Save As".into(), MenuState::Enabled)
        );
        assert_eq!(
            steps[3],
            Step::ExpectMenu("File>Export".into(), MenuState::Disabled)
        );
        assert_eq!(
            steps[4],
            Step::ExpectMenu("View>Details".into(), MenuState::Checked)
        );
        assert_eq!(
            steps[5],
            Step::ExpectMenu("View>Details".into(), MenuState::Unchecked)
        );
        assert_eq!(steps[6], Step::ExpectMenu("Sort".into(), MenuState::Value(1)));
        assert_eq!(steps[7], Step::ExpectMenus(3));
        assert_eq!(steps[8], Step::Shortcut("primary+s".into()));
        // The state's axis is derivable from its spelling — what
        // menu_state is asked for — and the spelling round-trips.
        assert_eq!(MenuState::Disabled.aspect(), MenuAspect::Enablement);
        assert_eq!(MenuState::Unchecked.aspect(), MenuAspect::Checkedness);
        assert_eq!(MenuState::Value(0).aspect(), MenuAspect::Value);
        assert_eq!(MenuState::Value(2).spelling(), "value 2");
    }

    /// Malformed paths die at parse, not as a bewildering "no such
    /// item" at runtime: empty, empty segments (leading/trailing/`>>`),
    /// whitespace-padded segments (labels compare byte-for-byte), an
    /// unquoted path, and an unterminated quote.
    #[test]
    fn malformed_menu_paths_rejected() {
        for bad in [
            "menu_activate \"\"",
            "menu_activate \"File>\"",
            "menu_activate \">File\"",
            "menu_activate \"File>>Save\"",
            "menu_activate \"File> Save\"",
            "menu_activate \"File >Save\"",
            "menu_activate File>Save",
            "menu_activate",
            "expect_menu \"\" enabled",
            "expect_menu \"File>\" enabled",
            "expect_menu \"File>Save disabled",
        ] {
            assert!(parse(bad).is_err(), "{bad} should not parse");
        }
    }

    /// Menu-chrome spellings are a closed set on BOTH halves. A typo
    /// here would otherwise surface as a backend apparently disagreeing
    /// with the scene, which is the most expensive way to discover you
    /// wrote "overflowed" — so both halves are checked at parse.
    #[test]
    fn menu_presentation_spellings() {
        for good in [
            "expect_menu_presentation \"regular/bar\"",
            "expect_menu_presentation \"compact/overflow\"",
            "expect_menu_presentation \"regular/none\"",
            // Legal on purpose: a backend that has not observed its
            // window yet must be able to say so rather than guess.
            "expect_menu_presentation \"unknown/none\"",
            // The BARE form: the invariant a shared scene can carry,
            // since the exact literal differs per lane.
            "expect_menu_presentation",
        ] {
            assert!(parse(good).is_ok(), "{good} should parse");
        }
        for bad in [
            // No separator, either half unknown, empty halves, the
            // halves swapped, a third component, and an unquoted arg.
            "expect_menu_presentation \"regular\"",
            "expect_menu_presentation \"regular/overflowed\"",
            "expect_menu_presentation \"wide/bar\"",
            "expect_menu_presentation \"/bar\"",
            "expect_menu_presentation \"regular/\"",
            "expect_menu_presentation \"bar/regular\"",
            "expect_menu_presentation \"regular/bar/extra\"",
            "expect_menu_presentation regular/bar",
        ] {
            assert!(parse(bad).is_err(), "{bad} should not parse");
        }
    }

    /// The bare form's invariant, both directions. The failing case is
    /// the iPadOS 26 defect exactly: a regular window whose catalog
    /// sits behind the compact overflow.
    #[test]
    fn menu_presentation_invariant() {
        assert!(!menu_presentation_fits("regular/overflow"));
        // Every legitimate combination, including the asymmetry: a
        // compact window MAY show a bar (a narrow desktop window does).
        for good in [
            "regular/bar",
            "regular/none",
            "compact/overflow",
            "compact/bar",
            "compact/none",
            "unknown/none",
        ] {
            assert!(menu_presentation_fits(good), "{good} should fit");
        }
    }

    /// The hint verb's own spelling. It is deliberately NOT the
    /// `<role>/<label>` shape — a hint is one free-text phrase — so the
    /// only grammar to hold is target-then-quoted-string.
    #[test]
    fn ax_hint_spellings() {
        for good in [
            "expect_ax_hint button#0 \"save the draft\"",
            "expect_ax_hint checkbox#0 \"show more detail\"",
            // Empty is a real assertion: the platform speaks no hint.
            "expect_ax_hint button#last \"\"",
        ] {
            assert!(parse(good).is_ok(), "{good} should parse");
        }
        for bad in [
            // No hint, no target, and an unquoted phrase (which would
            // otherwise silently assert only its first word).
            "expect_ax_hint button#0",
            "expect_ax_hint \"save the draft\"",
            "expect_ax_hint button#0 save the draft",
            "expect_ax_hint",
        ] {
            assert!(parse(bad).is_err(), "{bad} should not parse");
        }
    }

    /// The ax spelling's closed role set, both directions. The label
    /// half is free text — including EMPTY, which is a real assertion
    /// (the platform speaks nothing for this element).
    #[test]
    fn ax_spellings() {
        for good in [
            "expect_ax button#0 \"button/Save\"",
            "expect_ax label#0 \"label/Ready\"",
            "expect_ax entry#0 \"field/\"",
            "expect_ax column#0 \"group/Controls\"",
            "expect_ax image#0 \"unknown/\"",
            // A label may itself contain a slash — only the FIRST
            // separator splits, or any spoken name with punctuation
            // would be unassertable.
            "expect_ax label#0 \"label/on/off\"",
        ] {
            assert!(parse(good).is_ok(), "{good} should parse");
        }
        for bad in [
            "expect_ax button#0 \"widget/Save\"",
            "expect_ax button#0 \"Save\"",
            "expect_ax button#0 \"/Save\"",
            "expect_ax button#0 button/Save",
            "expect_ax button#0",
            "expect_ax",
        ] {
            assert!(parse(bad).is_err(), "{bad} should not parse");
        }
    }

    /// Malformed states die at parse too: unknown tokens, a bare
    /// `value`, a non-numeric or negative index, trailing junk after a
    /// bare state, and a missing state altogether.
    #[test]
    fn malformed_menu_states_rejected() {
        for bad in [
            "expect_menu \"File>Save\" toggled",
            "expect_menu \"File>Save\" value",
            "expect_menu \"File>Save\" value x",
            "expect_menu \"File>Save\" value -1",
            "expect_menu \"File>Save\" value 1 junk",
            "expect_menu \"File>Save\" enabled junk",
            "expect_menu \"File>Save\"",
            "expect_menus",
            "expect_menus x",
        ] {
            assert!(parse(bad).is_err(), "{bad} should not parse");
        }
    }

    /// The shortcut verb's GRAMMAR floor: emptiness and whitespace are
    /// line noise, rejected here. The policy floor (modifier rules,
    /// the named-key set, the reserved union) is the root's one
    /// checker in scene.rs — a spelling it rejects never reaches a
    /// dispatch table, so the harness does not re-implement it.
    #[test]
    fn shortcut_grammar_rejects_line_noise() {
        assert!(parse("shortcut \"\"").is_err());
        assert!(parse("shortcut \"primary +s\"").is_err());
        assert!(parse("shortcut primary+s").is_err());
        assert!(parse("shortcut").is_err());
    }

    /// expect_menus and expect_menu poll the stage's real-chrome
    /// reads and join the byte-identical pass observations into the
    /// verdict; a state mismatch fails with the read-vs-want text.
    #[test]
    fn menu_expects_poll_the_real_chrome() {
        let steps = parse(
            "expect label#0 \"ok-text\"\n\
             expect_menus 3\n\
             expect_menu \"File>Save\" disabled\n\
             expect_menu \"View>Details\" checked\n\
             expect_menu \"Sort\" value 1",
        )
        .unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        run(steps, MockStage { seen: &SEEN, verdict: tx });
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 0, "{verdict}");
        assert_eq!(
            verdict,
            "KAYA_SELFTEST: OK (ok-text, 3 menus, menu \"File>Save\" disabled, \
             menu \"View>Details\" checked, menu \"Sort\" value 1)"
        );
        // The mismatch half: the mock's enablement reads "disabled",
        // so asserting enabled fails with the last read's text.
        let (tx, rx) = std::sync::mpsc::channel();
        run(
            parse("expect label#0 \"ok-text\"\nexpect_menu \"File>Save\" enabled").unwrap(),
            MockStage { seen: &SEEN, verdict: tx },
        );
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 1);
        assert!(
            verdict.contains("menu \"File>Save\" reads \"disabled\", wanted \"enabled\""),
            "{verdict}"
        );
    }

    /// The action verbs drive their Stage methods, in step order, with
    /// the parsed path/target/spelling — what the backends build
    /// against. A dedicated registry: SEEN is shared across parallel
    /// tests.
    #[test]
    fn menu_actions_drive_the_stage() {
        static MENU_SEEN: Mutex<Vec<String>> = Mutex::new(Vec::new());
        let steps = parse(
            "context_open label#1\n\
             menu_activate \"Rename\"\n\
             shortcut \"primary+s\"\n\
             expect label#0 \"ok-text\"",
        )
        .unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        run(steps, MockStage { seen: &MENU_SEEN, verdict: tx });
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 0, "{verdict}");
        assert_eq!(
            *MENU_SEEN.lock().unwrap(),
            vec![
                "context_open Target { kind: Label, index: 1 }".to_owned(),
                "menu_activate Rename".to_owned(),
                "shortcut primary+s".to_owned(),
            ]
        );
    }

    /// context_open on editable text fails loudly: v1's context menus
    /// on entry/textarea are dress (scene.rs refuses the attach), so
    /// the gesture would probe a menu that cannot exist — the
    /// false-verdict class. Parse accepts the target (the grammar is
    /// kind-agnostic, like choose and scroll_end); the run arm holds
    /// the line.
    #[test]
    fn context_open_rejects_editable_text() {
        for bad in ["context_open entry#0", "context_open textarea#0"] {
            let script = format!("{bad}\nexpect label#0 \"ok-text\"");
            let (tx, rx) = std::sync::mpsc::channel();
            run(parse(&script).unwrap(), MockStage { seen: &SEEN, verdict: tx });
            let (code, verdict) = rx.recv().unwrap();
            assert_eq!(code, 1, "{verdict}");
            assert!(verdict.contains("not a context_open target"), "{verdict}");
        }
    }
}
