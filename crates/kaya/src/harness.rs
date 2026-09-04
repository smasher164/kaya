//! The interaction test harness: scene scripts as data, one interpreter
//! for every Rust backend. The choreography lives once, in
//! tools/scenes/<scene>.steps, and the SwiftUI and Compose halves
//! interpret the same grammar. `;` is a line separator for transports
//! that cannot carry a newline (an Android intent extra); every step
//! logs its offset from the run's start, relative only, because that
//! transcript is a recording mode's timeline. `kind#index` is HARNESS
//! grammar alone — container creation order is per-language, so
//! tools/check-steps.py rejects every container target except
//! `column#0`/`row#0`.

use crate::vtrace;
use std::time::{Duration, Instant};

/// The scene scripts, embedded from tools/scenes at build time.
pub fn script(scene: &str) -> Option<&'static str> {
    // TWO transports and NO registry — an unknown scene returns None and
    // fails spawn loudly, never falling back to another scene's script.
    // KAYA_SELFTEST_SCRIPT carries the script's TEXT for the interpreters
    // (an iOS bundle or an Android intent has no shared filesystem, and
    // intent extras cannot carry newlines); KAYA_SCENES_DIR/<scene>.steps
    // is the FILE the Rust backends read.
    let scene = if scene == "1" { "milestone2" } else { scene };
    if let Ok(text) = std::env::var("KAYA_SELFTEST_SCRIPT") {
        if !text.trim().is_empty() {
            return Some(Box::leak(text.into_boxed_str()));
        }
    }
    // The repo's own tools/scenes, resolved at COMPILE time so local
    // runs and `cargo test` need no environment.
    let dir = std::env::var("KAYA_SCENES_DIR").unwrap_or_else(|_| {
        concat!(env!("CARGO_MANIFEST_DIR"), "/../../tools/scenes").to_owned()
    });
    let path = std::path::Path::new(&dir).join(format!("{scene}.steps"));
    std::fs::read_to_string(path)
        .ok()
        .map(|t| &*Box::leak(t.into_boxed_str()))
}

/// One widget, named by kind and creation order (`index`; -1 is
/// `#last`) — or by AUTHORED KEY (`kind@id`, the a11y_id the guest
/// declared), which dissolves the creation-order instability that makes
/// container indices per-language (tools/check-steps.py). `kind@id[key]`
/// adds the stamped copy's outermost-first string keys, and `index` is
/// meaningless until the runner normalizes through `Stage::resolve_id`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Target {
    pub kind: TargetKind,
    pub index: isize,
    pub id: Option<&'static str>,
    pub keys: Option<&'static str>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TargetKind {
    Button,
    Checkbox,
    Slider,
    Entry,
    Label,
    Column,
    /// Rows are targetable under the container convention: only index
    /// 0, only in a scene that keeps exactly one row
    /// (tools/check-steps.py).
    Row,
    Image,
    Progress,
    /// Scroll viewports are targetable under the container convention:
    /// only index 0, only in a scene that keeps exactly one scroll
    /// (tools/check-steps.py).
    Scroll,
    Select,
    /// The radio group: the choice contract in its inline
    /// presentation — same choose/expect verbs as select.
    Radio,
    /// Grids are targetable under the container convention: only index
    /// 0, only in a scene that keeps exactly one grid
    /// (tools/check-steps.py).
    Grid,
    /// The multi-line entry: same set_text/read_text/focus verbs as
    /// the entry, its own registry.
    Textarea,
    /// The drawing surface: the canvas verbs' target, and nothing
    /// else's — a canvas has no text, no value and no activation.
    Canvas,
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
/// `menu_state` is asked for.
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
    /// byte-compared against and what the pass observation echoes.
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
    /// The app thread is ignoring pending occurrences — the stall the
    /// watchdog reports (crate::stall), asserted rather than merely
    /// survived.
    ExpectStall,
    /// The watchdog has NOTHING to report about a healthy app — the
    /// other half of ExpectStall's claim (docs/traps.md, "A watchdog
    /// that reports a stall on a HEALTHY app").
    ExpectNoStall,
    Click(Target),
    Toggle(Target, bool),
    SetValue(Target, f64),
    SetText(Target, String),
    /// Type the text at the FOCUSED widget as REAL PLATFORM KEYSTROKES. A
    /// programmatic write CLEARS the field's native undo history on every
    /// platform (docs/undo-plan.md D7), so a scene built out of set_text
    /// destroys the very history it wants to assert. It takes no target: a
    /// scene puts focus somewhere first and says so with `expect_focused`.
    /// An action, silent like click: it APPENDS and clears nothing.
    Type(String),
    Expect(Target, String),
    /// Expect the container's label children to read, in child order,
    /// the given `|`-joined texts — the observation reorder ops are
    /// verified by (creation-order registries cannot see a move).
    ExpectOrder(Target, String),
    /// Expect a table container's header bar as the TABLE PATH presented
    /// it — "<titles|joined> [^N|vN]" — read from the render's own
    /// record, never the model echo. Headers render at EVERY width
    /// (docs/tables-plan.md), which is what keeps this byte-comparable.
    ExpectColumns(Target, String),
    /// Expect a table's rows as per-row cell label texts: rows
    /// pipe-joined in the toolkit's child order, each row's cells
    /// comma-joined — expect_order one level deeper, for the celled
    /// shape whose moves creation-order registries cannot see.
    ExpectRows(Target, String),
    /// Expect the table's cells to form exactly N leading-edge clusters
    /// AND the table to span its assigned track — the GEOMETRY claim
    /// every backend makes uniformly (docs/tables-plan.md decision 6). A
    /// misaligned column splits its cluster and the count moves; a
    /// content-hugging layout comes up short of its track.
    ExpectColumnEdges(Target, usize),
    /// Expect the For's REALIZED BAND and its collection's declared
    /// total — `<first> <count> <total>` — read from the tier's own
    /// geometry (docs/virtualization-plan.md §5).
    ExpectWindow(Target, usize, usize),
    /// Scroll the For so the keyed row lands at the viewport's TOP. It
    /// addresses the ROW as data, so an unrealized row scrolls exactly
    /// like a realized one, and the top placement is what makes the first
    /// visible row deterministic on the corrected path.
    ScrollToRow(Target, String),
    /// Drag the source onto the destination through the platform's own
    /// drag arms, in-process where real input is refused (docs/dnd-plan.md
    /// D10). `Some(before)` marks a REORDER: the destination is a row of
    /// the source's own For and the bit says before or onto it.
    Drag(Target, Target, Option<bool>),
    /// `drag_file "<path>" to <destination>`: a FOREIGN file drop (D6) —
    /// the path, $TMP/$PID expanded, dropped on the destination as a
    /// source outside this app would drop it, so the picked-table
    /// redemption is what the scene reads. No source in the app, so no
    /// drag_ended.
    DragFile(String, Target),
    /// Click the table's column header at the 0-based index through
    /// the platform's real header path, so it emits sort_requested
    /// (select_section's drive-and-emit precedent).
    HeaderClick(Target, u32),
    /// Expect the widget to hold keyboard focus — the observation the
    /// focus command is verified by.
    ExpectFocused(Target),
    /// Expect the container's children to occupy the given `,`-joined
    /// percentages of the main axis.
    ///
    /// SHARES, NEVER SIZES: absolute geometry is a metric, which DESIGN
    /// leaves platform-flavored, so a size assertion could not be
    /// compared byte-for-byte.
    ExpectShares(Target, String),
    /// Expect the mounted root to fill the window's content area — the
    /// one thing shares can NEVER see, since a share is a percentage of
    /// the children's sum and therefore total-invariant.
    ExpectRootFills,
    /// The window content inset, MEASURED: the gap between the padding
    /// container's outer extent and its children's offer, halved, in whole
    /// layout units. Deliberately RELATIVE — GTK's CSD headerbar sits
    /// inside the window's height where macOS's titlebar sits outside it
    /// (docs/styling-plan.md D3). `expect_inset N` reads the WINDOW's pair;
    /// `expect_inset <target> N` reads a CONTAINER's own.
    ExpectInset { target: Option<Target>, units: u32 },
    /// The RESOLVED typeface family, read off the real views rather than
    /// echoed back from the request (docs/styling-plan.md Slice 2b). Every
    /// platform's font API renders SOMETHING for a family it does not have,
    /// so only the TEXT SYSTEM's answer tells a typo, a stale lowering and
    /// a working swap apart. Compared byte-for-byte.
    ExpectTypeface(String),
    /// The app icon's SAMPLED PIXELS, read off the artifact the shell will
    /// draw (docs/app-identity-plan.md I8). FOUR SAMPLES, NOT A HASH: each
    /// platform converts the one PNG its own way, so a hash cannot be one
    /// frozen string across platforms while four unmistakable colours can.
    /// The spelling is the four quadrant centres as uppercase `RRGGBB`,
    /// `/`-joined.
    ExpectAppIcon(String),
    /// THE PRIMARY CANVAS OBSERVABLE: the byte-hash of the canonical
    /// raster (docs/canvas-plan.md §7.1), one frozen string on five
    /// platforms. A HASH IS A TERRIBLE DIAGNOSTIC, so the failure text
    /// prints what was MEASURED beside it — the op count and the ink
    /// bounds — and never a guess about which op moved.
    ExpectDrawingHash(Target, String),
    /// The legible half: how many ops the core replayed and where the ink
    /// landed, as `<ops>/<l>,<t>,<r>,<b>` in hundredths of the canvas's
    /// own box (§7.2).
    ExpectDrawing(Target, String),
    /// The colour at declared probe points on THE BACKEND'S OWN RENDERED
    /// SURFACE (§7.2) — the one check that fails when the blit dropped.
    /// Spelled `"<x,y> <x,y> ... = <RRGGBB>/<RRGGBB>/..."`: the points in
    /// hundredths of the box, then the colours they must sample.
    ExpectInk(Target, String, String),
    /// WHICH SIZE this canvas's raster actually is — `"track"` or
    /// `"viewbox"` (docs/canvas-plan.md §3.2.1). The only canvas observable
    /// a size policy can move: the hash and the ink bounds both come from
    /// the CANONICAL raster, taken at the viewbox by definition. The two
    /// candidates come from opposite sides of the boundary — the backend
    /// measured the track, the guest declared the viewbox.
    ExpectRaster(Target, String),
    /// ADVANCE THE FRAME CLOCK by `n` frames, and let every `tick` canvas
    /// draw for each (docs/canvas-plan.md §15.4). A VERB, NEVER WALL CLOCK:
    /// the core's deterministic step is the only thing that moves a frame,
    /// so a leg's frame count is as reproducible on a loaded machine as on
    /// an idle one. The rate is the core's `KAYA_HARNESS_FRAME_HZ`, so
    /// three harnesses share one clock.
    Frame(u32),
    /// Expect the container's children to span its content box along the
    /// main axis — the leftover-consumption half of the grow contract,
    /// and the blind spot shares cannot see: growers that hold their
    /// weight RATIO at natural size pass every share assertion while
    /// consuming none of the leftover. root_fills cannot see it either.
    ExpectFills(Target),
    ExpectBreadth(Target),
    /// Expect the container's children to sit at the given cross-axis
    /// placement — the observation the `align` prop is verified by. The
    /// stage CLASSIFIES from geometry rather than reading the prop back:
    /// a backend that ignored the write while the model still carried it
    /// must fail here.
    ExpectAligned(Target, String),
    /// The container's ARRANGEMENT AXIS as rendered — "horizontal" or
    /// "vertical" (docs/adaptive-layout-plan.md §2). Observed from the
    /// backend's own layout state, never the model: a backend that
    /// ignored the write must fail, the expect_aligned rule.
    ExpectAxis(Target, String),
    /// The stacked fold (docs/adaptive-layout-plan.md D7): the child
    /// renders inside the table's viewport (Some) or in its structural
    /// parent (None, spelled `none`). Observed from the backend's own
    /// tree, never the core's model — a backend that ignored the Fold op
    /// must fail, the expect_axis rule.
    ExpectFolded(Target, Option<Target>),
    /// None = the implicit primary (window 0), keeping the
    /// single-window spelling; Some(n) prefixes the observation with
    /// `window#n `.
    ExpectTitle(Option<u64>, String),
    /// The ARM the sections render took ("bar"/"sidebar"), read off the
    /// backend's own stamp — never derived from the declared prop, which
    /// would agree with the lowering by construction. None = the primary;
    /// Some(n) prefixes the observation with `window#n `.
    ExpectSectionsPresentation(Option<u64>, String),
    /// The primary window's section count, from the REAL switcher.
    ExpectSections(usize),
    /// The ACTIVE section's title, from the platform's own selection
    /// state — never the scene model's copy.
    ExpectSection(String),
    /// Expect the section row titled `.0` to draw the SEMANTIC ICON named
    /// `.1`, read from the REAL rendered switcher row. The observation is
    /// the SEMANTIC NAME (`"home"`): a scene shared by five lanes cannot
    /// compare `house` against `go-home-symbolic` against `Home`.
    /// Addressed by title across every window, in window order. TOTAL, like
    /// `menu_symbol`: a miss is a retryable non-match, not a panic.
    ExpectSectionSymbol(String, String),
    /// Drive the switcher to the section at `index` (add order),
    /// through the platform's real switching path — emits
    /// section_selected like a user's switch.
    SelectSection(usize),
    ExpectWindowSize(Option<u64>, f64, f64),
    /// Expect the surface to be showing the platform's UNSAVED-WORK
    /// affordance, or not (None = the implicit primary). The READ is
    /// per-backend — see [`Stage::window_dirty`], which is where the
    /// per-platform table lives; the SCRIPT is identical everywhere,
    /// which is why this is a verb rather than five platform-flavored
    /// expect_title lines.
    ExpectDirty(Option<u64>, bool),
    /// Drive the window's REAL chrome close (performClose, WM_CLOSE,
    /// gtk close) — the veto grammar's trigger.
    CloseWindow(u64),
    /// The number of live surfaces (primary included).
    ExpectWindows(usize),
    /// Expect a live modal alert (over the target window; None = the
    /// primary) whose REAL presented title matches — read from the
    /// platform dialog, never the request's copy.
    ExpectAlert(Option<u64>, String),
    /// Drive the live alert's REAL answer path: press the action button
    /// (0 or 1) or fire the platform's dismissal (the cancel slot). An
    /// action, silent like click.
    AlertChoose(u32),
    ExpectFileDialog(Option<String>, Vec<String>),
    FileChoose(Option<String>),
    FileDialogGoto(String),
    /// The save dialog's observation: the directory it is REALLY showing
    /// and the name REALLY in its name field, both read from the platform
    /// panel. The name half catches a backend that ignored the name it
    /// was told — a wrong destination whose bytes are all correct, so
    /// every downstream assertion passes.
    ExpectSaveDialog(String, String),
    /// Type a name into the live save dialog's name field — set_text's
    /// tier. Silent, like every action: `expect_save_dialog` reads it
    /// back.
    FileDialogName(String),
    /// Press the live save dialog's own Save (true) or Cancel (false).
    /// The panel's completion runs; nothing is synthesized.
    FileSave(bool),
    /// A FOREIGN process puts something on the system clipboard, so a
    /// read leg is answering content this app did not write — the one
    /// thing a kaya-reads-what-kaya-wrote check cannot be.
    ClipboardSeed(String, String),
    /// A FOREIGN process reads the clipboard back, in one named
    /// representation, and the observation is compared byte for byte.
    ExpectClipboard(String, String),
    /// The number of live alerts (0 or 1 — one per process).
    ExpectAlerts(usize),
    /// The window's navigation-stack depth (None = the implicit
    /// primary; Some(n) prefixes the observation with `window#n `).
    ExpectEntries(Option<u64>, usize),
    /// Drive the window's REAL back affordance (the toolbar back button's
    /// path, the predictive gesture's path): an armed intercept_back entry
    /// emits back_requested and nothing pops; an unarmed top pops and
    /// reports entry_popped. An action, silent like click.
    Back(Option<u64>),
    /// Expect the scroll viewport's content to exceed its visible
    /// extent — the observation that pins "there is something to
    /// scroll" (both readings are geometry from the toolkit).
    ExpectOverflow(Target),
    /// Drive the viewport to its end through the toolkit's REAL
    /// scrolling API. An action, silent like click.
    ScrollEnd(Target),
    /// Expect the content's end edge to coincide with the viewport's
    /// (within two device units) — read back from the toolkit, never a
    /// model copy.
    ExpectAtEnd(Target),
    /// Drive the select's REAL selection path to the given option index —
    /// through the toolkit's own change route, so the native handler
    /// emits value_changed. An action, silent like click; `expect
    /// select#N "label"` is the observable.
    Choose(Target, usize),
    /// Expect the grid to lay its children out in exactly N columns with
    /// each column's cells sharing their leading edge — geometry from the
    /// toolkit, never a model copy.
    ExpectGridColumns(Target, usize),
    /// Drive the REAL activation path of the menu item at the `>`-joined
    /// label path — resolved wherever the item surfaced: the bar (or its
    /// phone overflow), or the OPEN context menu after a context_open. The
    /// platform's own action route fires, so the native handler emits
    /// menu_activated / menu_toggled / menu_value_changed. An action,
    /// silent like click.
    MenuActivate(String),
    /// Open the context menu attached to the live widget through the
    /// platform's own gesture route (right-click, long-press) — the
    /// following menu_activate resolves against the OPEN menu. An action,
    /// silent like click.
    ContextOpen(Target),
    /// The menu item's state along one axis (enablement, checkedness,
    /// or the radio group's value), from the platform's REAL menu
    /// chrome — never the scene model's copy.
    ExpectMenu(String, MenuState),
    /// Expect the menu item at the path to carry the SEMANTIC ICON of that
    /// name, read from the platform's REAL menu chrome (docs/styling-plan.md
    /// D6). THE OBSERVATION IS THE ACCESSIBILITY DESCRIPTION, not the
    /// platform's glyph string: a scene shared by five lanes cannot compare
    /// `doc.on.doc` against `content_copy`. TOTAL, like menu_state: a
    /// missing item or image reads as a short description, not a panic.
    ExpectMenuSymbol(String, String),
    /// The target's accessibility ROLE and spoken LABEL, read from the
    /// platform's OWN accessibility peer — NSAccessibility /
    /// UIAccessibility, AccessibilityNodeInfo, FrameworkElementAutomationPeer,
    /// GtkAccessible — never the scene model. Spelled `<role>/<label>`;
    /// role is each platform's vocabulary normalized to a closed set.
    ExpectAx(Target, String),
    /// The control's HINT — what activating it does. Its own verb
    /// because expect_ax's `<role>/<label>` spelling is byte-frozen in
    /// every scene; see the parse arm.
    ExpectAxHint(Target, String),
    ExpectMenus(usize),
    /// How the window catalog is CURRENTLY presented, spelled
    /// `<size class>/<presentation>`. THE PAIR is the assertion on purpose:
    /// neither half alone catches a regular-width window wearing the
    /// compact lowering (DESIGN.md, "Form factor and adaptivity"). `None` —
    /// the BARE form a SHARED scene can carry — asserts only the invariant,
    /// asymmetrically: a compact window showing a bar is legitimate.
    ExpectMenuPresentation(Option<String>),
    /// The window's toolbar, BARE INVARIANT form: the promoted set is
    /// really in this window's chrome and the remainder is reachable. A
    /// COUNT CANNOT RIDE A SHARED SCENE — k is the platform's own number.
    /// The backend answers `<promoted found>/<promoted>/<items>/<home>`,
    /// and the third number is what makes "no chrome at all" and "a chrome
    /// whose items are not these" different sentences (docs/traps.md: "the
    /// promotion list reached no toolbar").
    ExpectToolbar,
    /// One toolbar item's ASPECT, read off the REAL chrome and never off
    /// the promotion list. ENABLEMENT IS PER-PLATFORM MEASURED:
    /// `NSToolbarItem.isEnabled` stays `true` for a visibly disabled
    /// SwiftUI toolbar button (measured 2026-08-16,
    /// docs/chrome/toolbar-mac.md §2.3), so each backend reads the property
    /// its own disable moves and names it at the arm.
    ExpectToolbarItem(String, String),
    /// Drive the platform's key-equivalent dispatch for a canonical
    /// shortcut spelling — at minimum the same table the platform's own
    /// key event traverses, emitting the SAME menu_activated the item's
    /// direct activation would. An action, silent like click.
    Shortcut(String),
    /// Drive the window's REAL resize — the path a user's drag takes, not
    /// a model write — so the SIZE CLASS changes and the adaptive arms
    /// re-run. `None` targets the implicit primary. Capability-rejected on
    /// the phone hosts: a phone window has no size to command.
    ResizeWindow(Option<u64>, f64, f64),
    /// The window's live list-detail presentation,
    /// `<size class>/<presentation>` with presentations `split` and
    /// `stacked`. `None` — the BARE form a SHARED scene can carry — asserts
    /// only the invariant, ASYMMETRIC like expect_menu_presentation: a
    /// regular window must not show one pane while its stack holds two.
    ExpectSplit(Option<String>),
    /// The window's visible PANES, `<size class>/<positions>` with
    /// positions the ascending stack indices on screen (0 = the base root,
    /// j = entry j-1; docs/multicolumn-plan.md D4). Positions, not a
    /// count: the defect this gates is a lowering showing the WRONG panes.
    /// `None` — the BARE form a SHARED scene can carry — asserts
    /// expect_split's own asymmetric invariant.
    ExpectPanes(Option<String>),
    /// The textarea's DECORATED RANGES, read from the platform's own text
    /// layer, `<start>:<end>=<covered text>` per range, `|`-joined
    /// ascending. BOTH HALVES, and the second is the guard: offsets alone
    /// agree with themselves, since two symmetric conversion mistakes cancel
    /// while the highlight visibly covers the wrong characters. The COVERED
    /// TEXT has no arithmetic in it.
    ExpectHighlights(Target, String),
    /// The textarea's SELECTION, in the same `<start>:<end>=<text>`
    /// spelling as ExpectHighlights and for the same reason. A caret
    /// reads as `12:12=`.
    ExpectSelection(Target, String),
    /// Whether a range is inside the textarea's VIEWPORT: `visible` or
    /// `offscreen`. CONTAINMENT AND NOT THE VIEWPORT ITSELF, which
    /// differs per lane. The `offscreen` spelling keeps the assertion
    /// from being vacuous — a scene asserts it BEFORE the reveal, so a
    /// document short enough to be entirely visible fails the leg.
    ExpectRevealed(Target, TextRange, String),
    /// Start an input-method COMPOSITION in the target with this marked
    /// text — the mid-word IME state no other verb can reach (`type` is
    /// printable ASCII by contract). The text is MARKED, not committed:
    /// displayed, not in the widget's value, and the app has been told
    /// nothing. It exists so a scene can prove that select_range refuses
    /// to run over it (docs/ranges-plan.md D4).
    Compose(Target, String),
}

/// A range in a harness assertion, in the same UTF-8 byte offsets the
/// protocol carries. Its own type so a verb cannot take two loose
/// integers in the wrong order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TextRange {
    pub start: u64,
    pub stop: u64,
}

impl Step {
    /// Every Target this step carries, for the runner's kind@id
    /// normalization.
    fn targets_mut(&mut self) -> Vec<&mut Target> {
        match self {
            Step::Click(t)
            | Step::ExpectFocused(t)
            | Step::ExpectFills(t)
            | Step::ExpectBreadth(t)
            | Step::ExpectOverflow(t)
            | Step::ScrollEnd(t)
            | Step::ExpectAtEnd(t)
            | Step::ContextOpen(t) => vec![t],
            Step::Toggle(t, _)
            | Step::SetValue(t, _)
            | Step::SetText(t, _)
            | Step::Expect(t, _)
            | Step::ExpectOrder(t, _)
            | Step::ExpectColumns(t, _)
            | Step::ExpectRows(t, _)
            | Step::ExpectColumnEdges(t, _)
            | Step::ScrollToRow(t, _)
            | Step::HeaderClick(t, _)
            | Step::ExpectShares(t, _)
            | Step::ExpectAligned(t, _)
            | Step::ExpectAxis(t, _)
            | Step::Choose(t, _)
            | Step::ExpectGridColumns(t, _)
            | Step::ExpectAx(t, _)
            | Step::ExpectAxHint(t, _)
            | Step::ExpectHighlights(t, _)
            | Step::ExpectSelection(t, _)
            | Step::ExpectDrawingHash(t, _)
            | Step::ExpectDrawing(t, _)
            | Step::ExpectRaster(t, _)
            | Step::Compose(t, _) => vec![t],
            // BOTH ENDS OF A DRAG NORMALIZE. Handing the loop above the
            // source alone left `drag label#0 to label@row[a]` reaching every
            // rust-native backend as index 0 with the id still on it —
            // label#0 — and no lane could see it, because the mac
            // interpreter parses the script itself (tools/check-verbs.py
            // holds every variant's Target fields against these arms).
            // docs/traps.md: A Step's SECOND Target was never normalized
            Step::Drag(source, destination, _) => vec![source, destination],
            Step::DragFile(_, destination) => vec![destination],
            Step::ExpectFolded(child, table) => {
                let mut out = vec![child];
                if let Some(table) = table {
                    out.push(table);
                }
                out
            }
            Step::ExpectInk(t, _, _) => vec![t],
            Step::ExpectRevealed(t, _, _) => vec![t],
            Step::ExpectWindow(t, _, _) => vec![t],
            Step::ExpectInset { target, .. } => target.iter_mut().collect(),
            Step::Settle(..)
            | Step::ExpectStall
            | Step::ExpectNoStall
            | Step::Type(..)
            | Step::ExpectRootFills
            | Step::ExpectTypeface(..)
            | Step::ExpectAppIcon(..)
            | Step::ExpectTitle(..)
            | Step::ExpectSections(..)
            | Step::ExpectSection(..)
            | Step::ExpectSectionSymbol(..)
            | Step::ExpectSectionsPresentation(..)
            | Step::SelectSection(..)
            | Step::ExpectWindowSize(..)
            | Step::ExpectDirty(..)
            | Step::CloseWindow(..)
            | Step::ExpectWindows(..)
            | Step::ExpectAlert(..)
            | Step::FileChoose(..)
            | Step::FileDialogGoto(..)
            | Step::ExpectSaveDialog(..)
            | Step::FileDialogName(..)
            | Step::FileSave(..)
            | Step::ClipboardSeed(..)
            | Step::ExpectClipboard(..)
            | Step::ExpectFileDialog(..)
            | Step::AlertChoose(..)
            | Step::ExpectAlerts(..)
            | Step::ExpectEntries(..)
            | Step::Back(..)
            | Step::MenuActivate(..)
            | Step::ExpectMenu(..)
            | Step::ExpectMenuSymbol(..)
            | Step::ExpectMenus(..)
            | Step::ExpectMenuPresentation(..)
            | Step::ExpectToolbar
            | Step::ExpectToolbarItem(..)
            | Step::Shortcut(..)
            | Step::ResizeWindow(..)
            | Step::ExpectSplit(..)
            | Step::ExpectPanes(..)
            | Step::Frame(..) => Vec::new(),
        }
    }

    /// Does this step ASSERT something, as opposed to driving the UI?
    /// Exhaustive on purpose: a hand-written list here fell eight
    /// variants behind and reported a menu-only scene as having no
    /// expects at all, so a new Step must not compile until someone
    /// decides which side of this line it is on.
    fn is_assertion(&self) -> bool {
        match self {
            Step::Settle { .. } => false,
            Step::Click { .. } => false,
            Step::Toggle { .. } => false,
            Step::SetValue { .. } => false,
            Step::SetText { .. } => false,
            Step::Type { .. } => false,
            Step::Expect { .. } => true,
            Step::ExpectStall => true,
            Step::ExpectNoStall => true,
            Step::ExpectOrder { .. } => true,
            Step::ExpectColumns { .. } => true,
            Step::ExpectRows { .. } => true,
            Step::ExpectColumnEdges { .. } => true,
            Step::ExpectWindow { .. } => true,
            Step::ScrollToRow { .. } => false,
            Step::Drag { .. } => false,
            Step::DragFile { .. } => false,
            Step::HeaderClick { .. } => false,
            Step::ExpectFocused { .. } => true,
            Step::ExpectShares { .. } => true,
            Step::ExpectRootFills { .. } => true,
            Step::ExpectInset { .. } => true,
            Step::ExpectTypeface(_) => true,
            Step::ExpectAppIcon(_) => true,
            Step::ExpectDrawingHash { .. } => true,
            Step::ExpectDrawing { .. } => true,
            Step::ExpectInk { .. } => true,
            Step::ExpectRaster { .. } => true,
            // A frame is a DRIVE, not a read: it changes the scene and
            // is not retried.
            Step::Frame(_) => false,
            Step::ExpectFills { .. } => true,
            Step::ExpectBreadth { .. } => true,
            Step::ExpectAligned { .. } => true,
            Step::ExpectAxis { .. } => true,
            Step::ExpectFolded { .. } => true,
            Step::ExpectTitle { .. } => true,
            Step::ExpectSections { .. } => true,
            Step::ExpectSection { .. } => true,
            Step::ExpectSectionSymbol { .. } => true,
            Step::ExpectSectionsPresentation { .. } => true,
            Step::SelectSection { .. } => false,
            Step::ExpectWindowSize { .. } => true,
            Step::ExpectDirty { .. } => true,
            Step::CloseWindow { .. } => false,
            Step::ExpectWindows { .. } => true,
            Step::ExpectAlert { .. } => true,
            Step::FileChoose(..) => false,
            Step::FileDialogGoto(..) => false,
            Step::ExpectSaveDialog(..) => true,
            Step::FileDialogName(..) => false,
            Step::FileSave(..) => false,
            Step::ClipboardSeed(..) => false,
            Step::ExpectClipboard(..) => true,
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
            Step::ExpectMenuSymbol { .. } => true,
            Step::ExpectAx { .. } => true,
            Step::ExpectAxHint { .. } => true,
            Step::ExpectMenus { .. } => true,
            Step::ExpectMenuPresentation { .. } => true,
            Step::ExpectToolbar => true,
            Step::ExpectToolbarItem { .. } => true,
            Step::Shortcut { .. } => false,
            Step::ResizeWindow { .. } => false,
            Step::ExpectSplit { .. } => true,
            Step::ExpectPanes { .. } => true,
            Step::ExpectHighlights { .. } => true,
            Step::ExpectSelection { .. } => true,
            Step::ExpectRevealed { .. } => true,
            Step::Compose { .. } => false,
        }
    }
}


/// What a backend supplies: its native calls, each hopping to its UI
/// thread internally and blocking until applied.
///
/// NO METHOD HERE GETS A DEFAULT BODY. A backend that forgets one must
/// fail to COMPILE; a default would let it pass that scene's legs
/// vacuously, which is how the GTK reorder gap reached the Linux suite.
pub trait Stage: Send + 'static {
    fn click(&self, target: Target);
    fn toggle(&self, target: Target, on: bool);
    fn set_value(&self, target: Target, value: f64);
    fn set_text(&self, target: Target, text: &str);
    /// Deliver `text` to the FOCUSED widget as real platform keystrokes.
    /// THE CONTRACT, since every backend implements it separately:
    ///
    /// 1. THE PLATFORM'S OWN INPUT PATH, never a text write, so the NATIVE
    ///    undo stack fills as a user's typing fills it (docs/undo-plan.md D7).
    /// 2. WHATEVER HOLDS FOCUS RECEIVES IT, resolved by the platform.
    /// 3. IT APPENDS: the insertion point goes to the END with nothing
    ///    selected first — macOS forces this, since making a text field
    ///    first responder SELECTS ITS WHOLE CONTENTS.
    /// 4. IT BLOCKS UNTIL THE TEXT HAS LANDED. Actions are not retried and
    ///    a following ACTION has no POLL_DEADLINE cover, so a race there
    ///    reads as a broken undo rather than a missed keystroke.
    /// 5. NO SYNTHETIC COALESCING: separate key events, in order.
    /// 6. PRINTABLE ASCII ONLY — `parse` refuses anything else.
    fn type_text(&self, text: &str);
    fn read_label(&self, target: Target) -> String;
    /// The displayed text of an entry, read from the toolkit — the
    /// observation the clear command is pinned by.
    fn read_text(&self, target: Target) -> String;
    /// Whether the widget holds keyboard focus, read from the toolkit
    /// (per-window focus, never global key status — parallel tiled legs
    /// must not steal each other's assertion).
    fn is_focused(&self, target: Target) -> bool;
    /// The decoded size of an image, as "WxH" — a failed decode reads
    /// "0x0", the placeholder class.
    fn image_size(&self, target: Target) -> String;
    /// The texts of the container's label children, in child order, joined
    /// with `|` — the observation expect_order verifies.
    fn child_texts(&self, target: Target) -> String;
    /// The table's header bar as the TABLE PATH presented it —
    /// "<titles|joined> [^N|vN]", empty when no table rendered — read
    /// from the toolkit's own presentation, never the model
    /// (docs/tables-plan.md).
    fn columns_presented(&self, target: Target) -> String;
    /// The table's rows as per-row cell label texts: rows `|`-joined in
    /// the toolkit's child order, cells `,`-joined within a row.
    fn row_cells(&self, target: Target) -> String;
    /// The table observation expect_column_edges verifies: empty when the
    /// cells form exactly `want` leading-edge clusters within two device
    /// units AND the table spans its assigned flex track; otherwise the
    /// toolkit's own description, for the failure text. Geometry, never a
    /// model copy — a content-hugging table keeps every cluster right while
    /// drawing in a corner of its viewport.
    fn column_edges(&self, target: Target, want: usize) -> String;
    /// The For's FIRST VISIBLE row and its collection's declared total, as
    /// this tier lays them out: `"<first> <total>"` (ruled 2026-08-25;
    /// docs/virtualization-plan.md §5). The band's WIDTH is a viewport
    /// metric and deliberately not here, so THIS PAIR CANNOT SEE WHETHER THE
    /// BAND EVER NARROWED (measured 2026-08-25 on the GTK lane —
    /// windowed.steps passed with the range report removed); the report
    /// loop's links are held statically by tools/check-table-tier.py and
    /// tools/check-gtk.py's census. A backend that does not window yet
    /// answers a SENTENCE, so the leg reddens carrying it.
    fn window_band(&self, target: Target) -> String;
    /// Scroll the For so the keyed row is the viewport's FIRST VISIBLE
    /// row. The empty string when it happened; otherwise a sentence
    /// naming what stopped it, which the step turns into its failure.
    fn scroll_to_row(&self, target: Target, key: &str) -> String;
    /// Drag `source` onto `destination` through this backend's own drag
    /// arms (docs/dnd-plan.md D10); `reorder` is Some(before) for a row
    /// landing on a row of its own For. The empty string when it ran,
    /// otherwise the sentence naming what stopped it. Defaulted, so a
    /// backend that has not grown its arms says so by name.
    fn drag(&self, source: Target, destination: Target, reorder: Option<bool>) -> String {
        let _ = (source, destination, reorder);
        "drag is a depth slice on this backend (docs/dnd-plan.md §5)".to_owned()
    }

    /// Drop `path` on `destination` as a source OUTSIDE this app would
    /// (docs/dnd-plan.md D6): the file lands as a picked file. The empty
    /// string when it ran, else the sentence naming what stopped it.
    fn drag_file(&self, path: &str, destination: Target) -> String {
        let _ = (path, destination);
        "drag_file is a depth slice on this backend (docs/dnd-plan.md §5)".to_owned()
    }
    /// The creation index of the FIRST widget of `kind` carrying the
    /// authored a11y_id `id`, and (when present) whose table sort tag
    /// carries `keys`, or None while no such widget exists — how a
    /// `kind@id[key.path]` target becomes the index every other read
    /// uses. Read from the BACKEND'S OWN records of the applied prop,
    /// never the script's hopes.
    fn resolve_id(&self, kind: TargetKind, id: &str, keys: Option<&str>) -> Option<isize>;
    /// Click the column header at `column` through the platform's real
    /// header path, so it emits sort_requested.
    fn header_click(&self, target: Target, column: u32);
    /// Whether the mounted root fills the window's content area, read from
    /// the toolkit after forcing pending layout: the empty string when it
    /// does (within one device unit), otherwise a short platform-flavored
    /// description for the failure text alone. "Content area" is the
    /// platform's own notion — the safe area on iOS, the contentView on
    /// macOS, the window's child area on GTK and WinUI.
    fn root_fills(&self) -> String;
    /// The window content inset, MEASURED from real layout — the gap
    /// between the padding container's outer extent and its children's
    /// offer, halved — as whole layout units ("16"), or the backend's own
    /// words when the two axes disagree.
    fn inset(&self) -> String;
    /// A CONTAINER's own content inset, the same halved-gap measurement one
    /// level down (its outer extent against its children's offer).
    fn container_inset(&self, target: Target) -> String;

    /// The RESOLVED typeface family, read off the real text views — what
    /// the toolkit ENDED UP WITH, never the family the app asked for
    /// (docs/styling-plan.md Slice 2b). On a brandless app that is the
    /// platform's own default, and saying so is the honest answer: every
    /// font API renders SOMETHING, so a Stage that answered "" or echoed
    /// the request would pass while the swap never happened.
    fn typeface(&self) -> String;
    /// The app icon's four quadrant samples, read off the picture the
    /// PLATFORM is holding — uppercase `RRGGBB`, clockwise from the top
    /// left (docs/app-identity-plan.md I8). WHEN THERE IS NO ICON the
    /// answer says what it MEASURED and what it could not tell apart, never
    /// a bare "none": the platforms document a fallback chain.
    fn app_icon(&self) -> String;
    /// One canvas's CANONICAL raster read back out of the core:
    /// `"<16 hex> <ops>/<l>,<t>,<r>,<b>"` (docs/canvas-plan.md §7.1). Every
    /// backend answers by asking kaya, so one frozen string says five
    /// platforms produced the same drawing. This proves NOTHING about what
    /// reached the screen; [`Stage::canvas_ink`] is what fails then.
    fn canvas_probe(&self, target: Target) -> String;
    /// The colour at declared normalized probe points, sampled from THE
    /// BACKEND'S OWN RENDERED SURFACE. Sample CENTRES of flat regions,
    /// never boundaries, through a 16-bit context with interpolation off.
    /// Its job is to prove the BLIT; the appearance rides the answer
    /// (`"<mode> RRGGBB/..."`) and the compare is tolerant by exactly ±1
    /// per channel — see [`INK_TOLERANCE`].
    fn canvas_ink(&self, target: Target, points: &str) -> String;
    /// WHICH SIZE the raster this canvas last produced is: `"track"` when
    /// it is the size the BACKEND reported, `"viewbox"` when it is the one
    /// the GUEST declared, and on disagreement all three numbers rather
    /// than a guess. Asked of the core, like [`Stage::canvas_probe`].
    fn canvas_raster_shape(&self, target: Target) -> String;
    /// ADVANCE THE FRAME CLOCK by one frame and drive every `tick` canvas
    /// at the core's own deterministic step (§15.4). The step is the
    /// core's, not the stage's, so a leg's frame count is one number in
    /// all three harnesses.
    fn frame(&self);
    /// The main-axis extents of the container's children, in child order,
    /// each as a whole percentage of their SUM — the only way a layout
    /// weight is observable at all, and their sum rather than the
    /// container's extent because spacing and padding are platform metrics.
    /// Read the alignment rect where the toolkit distinguishes it from the
    /// drawing frame (docs/traps.md — AppKit reads 1:3 as 2.90:1).
    fn child_shares(&self, target: Target) -> String;
    /// Whether the container's children (plumbing like leftover fillers
    /// excluded) span its content box along the main axis, read from the
    /// toolkit after forcing pending layout: the empty string when they
    /// do (within two device units), otherwise a short platform-flavored
    /// description for the failure text alone.
    fn container_fills(&self, target: Target) -> String;
    /// Whether a WIDGET spans the track its flex container assigned it, along
    /// that container's main axis. THE HALF OF THE GROW CONTRACT SHARES CANNOT
    /// SEE: three of the four backends read the TRACK in `child_shares`, so a
    /// widget drawn at a HARD SIZE inside a correct track splits its container
    /// exactly right and renders wrong, silently.
    fn widget_fills(&self, target: Target) -> String;
    /// Whether a WIDGET spans its flex container's content box along that
    /// container's CROSS axis — the breadth `widget_fills` cannot see. It
    /// exists for the scroll ruling of 2026-09-02: a scroll spans its
    /// parent's cross axis by default, and every backend hugged its content
    /// until the iOS driver's real pans found a 79pt viewport in a 375pt
    /// window.
    fn widget_spans_breadth(&self, target: Target) -> String;
    /// The container's cross-axis placement, CLASSIFIED from geometry after
    /// forcing pending layout: "start", "center", "end", "stretch", or
    /// "baseline" when the coincidence holds for every child (within two
    /// device units), otherwise a short description (failure text only).
    /// Baseline is rows-only and classifies via each toolkit's own query.
    fn cross_mode(&self, target: Target) -> String;
    /// The container's rendered arrangement axis: "horizontal" or
    /// "vertical", read from the backend's own layout state.
    fn container_axis(&self, target: Target) -> String;
    /// The stacked fold, measured off this backend's own tree (D7):
    /// "folded" when the child renders inside the table's viewport, "not
    /// folded" when it renders in its structural parent, and any other
    /// sentence is what the backend could actually see.
    fn fold_state(&self, child: Target, table: Option<Target>) -> String;
    /// A surface's REAL materialized title (the title bar on the
    /// desktops, the task label on Android) — never the scene model's
    /// copy, so a backend that ignored the write fails.
    fn window_title(&self, window: u64) -> String;
    /// A surface's REAL content extent in device-independent units — what
    /// expect_window_size compares against the advisory request.
    fn window_content_size(&self, window: u64) -> (f64, f64);
    /// Whether the surface is REALLY showing the platform's unsaved-work
    /// affordance — the observation `expect_dirty` verifies
    /// (docs/dirty-plan.md D5).
    ///
    /// THE READ IS PER-BACKEND AND THE SCRIPT IS NOT: `dirty` is one
    /// declaration with five different chromes (D2), and this verb is
    /// where that divergence is absorbed. From the platform wherever the
    /// platform has one — a model read would agree with itself.
    ///
    /// | backend | what to read |
    /// |---|---|
    /// | SwiftUI (macOS) | the window's CLOSE BUTTON element, attribute `AXEdited` (measured: it is not on the window element — the window's 29 attributes have no edited state) |
    /// | WinUI | the REAL OS caption through the existing title read: leading `*` present or absent |
    /// | GTK | the header-bar marker through the existing AT-SPI read |
    /// | SwiftUI (iOS), Compose | the applied window prop, read back through the interpreter — state, not chrome, because these platforms have none (D4). NOT vacuous: it fails if the prop never applied |
    fn window_dirty(&self, window: u64) -> bool;
    /// Drive the surface's REAL chrome close (performClose, WM_CLOSE,
    /// gtk close) — a veto_close window emits close_requested and
    /// stays; a non-veto auxiliary closes and reports window_closed.
    fn close_window(&self, window: u64);
    /// The number of live surfaces, primary included.
    fn window_count(&self) -> usize;
    /// The REAL presented title of the live alert over the window, or None
    /// when no alert is live there — read from the platform dialog
    /// (NSAlert's messageText, ContentDialog's Title, ...), never the
    /// request's copy.
    fn alert_title(&self, window: u64) -> Option<String>;
    /// Drive the live alert's REAL answer path: activate the action button
    /// (choice 0 or 1) or the cancel slot (the sentinel) the way the
    /// platform's own dismissal would.
    fn choose_alert(&self, choice: u32);
    /// The number of live alerts (0 or 1).
    fn alert_count(&self) -> usize;
    /// What the live file picker is REALLY showing: the directory it is
    /// pointed at, and the file names its list actually contains — read
    /// from the platform panel, never from the request. None when no
    /// picker is live. Both halves matter: a panel aimed at the wrong
    /// place, or with a filter that excludes everything, presents
    /// perfectly and is useless.
    fn file_dialog_state(&self) -> Option<(String, Vec<String>)>;
    /// Drive the live picker's REAL answer path: select the named row and
    /// press Open, or press Cancel when `name` is None — the same controls
    /// a user works, not a synthesized completion.
    fn choose_file(&self, name: Option<&str>);
    /// Point the live picker at a directory, the way a user navigating
    /// there would leave it. HARNESS MACHINERY, NOT VOCABULARY — NOT a
    /// request field: WinUI's start location is a PickerLocationId ENUM of
    /// well-known folders, so a `directory` on the wire would be honorable
    /// on four platforms and not the fifth.
    fn goto_directory(&self, path: &str);
    /// What the live SAVE dialog is really showing: the directory, and the
    /// name in its name field. THE NAME HALF IS THE WHOLE POINT: a backend
    /// that ignored the name saves under the SUGGESTED one and every
    /// downstream assertion passes on the wrong file. NEVER REQUIRE ROWS
    /// HERE — NSSavePanel's collapsed form publishes none, and whether it is
    /// collapsed is a MACHINE-WIDE preference no gate reads
    /// (docs/probes/save-probe-mac.md). tools/lib/stage-coverage.py holds
    /// these three for GTK.
    fn save_dialog_state(&self) -> Option<(String, String)>;
    /// Type a name into the live save dialog's name field, the way a user
    /// would leave it. set_text's tier; whether it took is not assumed —
    /// expect_save_dialog reads it back.
    fn set_save_name(&self, name: &str);
    /// Press the live save dialog's REAL Save (`save`) or Cancel — the same
    /// controls a user works, so the dialog's own completion runs.
    fn confirm_save(&self, save: bool);
    /// Put content on the system clipboard FROM OUTSIDE THIS APP, and read
    /// it back the same way, through the platform's own clipboard tool.
    /// FOREIGN ON PURPOSE: a check where kaya reads what kaya wrote parses
    /// its own bad header happily. `kind` is a closed name (text, html,
    /// image, files) or a custom format id; the read answers the content,
    /// the basenames for files, the decoded size for an image, or "".
    fn clipboard_seed(&self, kind: &str, argument: &str);
    fn clipboard_read(&self, kind: &str) -> String;
    /// The window's navigation-stack depth — the observation expect_entries
    /// verifies.
    fn entry_count(&self, window: u64) -> usize;
    /// Drive the window's REAL back affordance.
    fn back(&self, window: u64);
    /// The progress bar's state, read from the toolkit: the determinate
    /// fraction as an integer percent ("42%" — the slider verdict's
    /// spelling) or "indeterminate" while activity mode is on.
    fn progress_state(&self, target: Target) -> String;
    /// Drive the select's REAL selection path to the given option index —
    /// the toolkit's own change route, so the native handler emits
    /// value_changed (never a synthetic occurrence).
    fn choose(&self, target: Target, index: usize);
    /// The selected option's LABEL, read from the toolkit's own selection
    /// state — never a model copy. Labels, not indices: byte-compared
    /// across every language like all expects.
    fn selected_label(&self, target: Target) -> String;
    /// The grid observation: empty when the grid lays out in exactly `want`
    /// columns whose cells share their leading edges (within two device
    /// units); otherwise the toolkit's own description of the mismatch, for
    /// the failure text. Geometry, never a model copy.
    fn grid_columns(&self, target: Target, want: usize) -> String;
    /// The scroll viewport's overflow, read from the toolkit after forcing
    /// pending layout: the empty string when the content exceeds the
    /// viewport, otherwise a short platform-flavored description of the two
    /// extents (failure text only).
    fn scroll_overflow(&self, target: Target) -> String;
    /// Drive the viewport to its end through the toolkit's REAL scrolling
    /// API.
    fn scroll_end(&self, target: Target);
    /// Whether the content's end edge coincides with the viewport's (within
    /// two device units): the empty string when it does, otherwise a
    /// description (failure text only).
    fn scroll_at_end(&self, target: Target) -> String;
    /// The primary window's section count, read from the REAL switcher
    /// control (tab bar items, stack pages), never the scene model.
    fn section_count(&self) -> usize;
    /// The ACTIVE section's title, from the platform's own selection state.
    fn active_section_title(&self) -> String;
    /// The SEMANTIC ICON NAME the REAL switcher row titled `title` draws,
    /// searched across every window — never the section record's `symbol`
    /// field, which is a decoded copy. On failure it says WHAT IT MEASURED
    /// and no more, because "wrong concept", "nothing drawn" and "not built
    /// yet" are three different bugs (invariant 3). TOTAL: a miss is a
    /// retryable non-match.
    fn section_symbol(&self, title: &str) -> String;
    /// The ARM the sections render actually took, "bar" or "sidebar", for
    /// the given window — stamped by the render body, never derived from
    /// the declared prop (the expect_split rule).
    fn sections_presentation(&self, window: u64) -> String;
    /// Drive the switcher to the section at `index` (add order) through the
    /// platform's real switching path — the user's route, so it emits
    /// section_selected (choose/toggle precedent).
    fn select_section(&self, index: usize);
    /// Drive the REAL activation path of the menu item at the `>`-joined
    /// label path — through the bar (or its phone overflow), or the OPEN
    /// context menu when a context_open preceded — so the platform's own
    /// action route emits menu_activated / menu_toggled /
    /// menu_value_changed, never a synthetic occurrence.
    fn menu_activate(&self, path: &str);
    /// Open the context menu attached to the live widget through the
    /// platform's own gesture route (right-click, long-press), so a
    /// following menu_activate resolves against the OPEN menu.
    fn context_open(&self, target: Target);
    /// The top-level catalog count, read from the REAL materialized bar (or
    /// the phone overflow's group list) — never the scene model's copy.
    fn menu_count(&self) -> usize;
    /// The target's accessibility ROLE and spoken LABEL as `<role>/<label>`,
    /// read from the PLATFORM'S OWN accessibility peer — never the scene
    /// model and never kaya's memory of what it set, which would make this
    /// verb agree with itself. Role is normalized to the closed set in
    /// `check_ax`; `unknown` is legal and honest.
    fn ax(&self, target: Target) -> String;

    /// The control's HINT as the platform publishes it — what activating
    /// it does. Read from the same tree as `ax`, never from kaya's model.
    fn ax_hint(&self, target: Target) -> String;
    /// The window catalog's live presentation,
    /// `<size class>/<presentation>` — see Step::ExpectMenuPresentation.
    /// Both halves must come FROM THE PLATFORM: the failure being gated is
    /// a lowering that disagrees with the window it is in, and a
    /// model-sourced answer cannot see that.
    fn menu_presentation(&self) -> String;
    /// Resize `window` to WxH in DIP through the platform's real window-
    /// resize path, blocking until the new size is applied so the size-
    /// class-driven arms have re-run by the time this returns. Hosts
    /// without commandable window size reject the scene loudly rather than
    /// silently no-op.
    fn resize_window(&self, window: u64, width: f64, height: f64);
    /// The window's live list-detail presentation — see Step::ExpectSplit.
    /// The presentation half must name THE ARM THAT RENDERED, read from
    /// the view layer's own stamp, never derived from the prop or the size
    /// class: a derived answer agrees with the lowering by construction.
    fn split_presentation(&self) -> String;
    /// The window's visible panes, `<size class>/<positions>` — see
    /// Step::ExpectPanes. Positions must come from the backend's REAL
    /// arrangement wherever more than two panes can stand; a two-pane
    /// world may compose `panes_positions` over its split stamp, which
    /// is exact there (root + top, or the top alone).
    fn panes_reading(&self) -> String;
    /// The menu item's state along one axis, read from the platform's real
    /// menu chrome and spelled in the steps grammar's own words
    /// ("enabled"/"disabled", "checked"/"unchecked", "value N") — never a
    /// model copy. TOTAL: a missing item reads as a short description ("no
    /// such item"), so expect_menu doubles as the wait for a catalog
    /// rebuild to land.
    fn menu_state(&self, path: &str, aspect: MenuAspect) -> String;
    /// The SEMANTIC ICON NAME the platform's real menu item carries — read
    /// from the materialized item's image accessibility description, never
    /// from the model. On failure it says WHAT IT MEASURED: `"no such
    /// item"`, `"no symbol"`, or the platform glyph string that failed to
    /// resolve; a backend that cannot tell "never lowered" from "lowered
    /// and rejected" says the one thing it knows (invariant 3).
    fn menu_symbol(&self, path: &str) -> String;
    /// What this window's chrome DID with the promotion list, spelled
    /// `<promoted found>/<promoted>/<items>/<remainder's home>` — see
    /// Step::ExpectToolbar. The chrome numbers come FROM THE PLATFORM'S OWN
    /// BAR and the catalog number from the model, from two different sides:
    /// an answer computed once and reported twice would agree with itself.
    fn toolbar_chrome(&self) -> String;
    /// One toolbar item's aspect, read off the REAL chrome: the semantic
    /// symbol name it draws, or `"enabled"`/`"disabled"`. TOTAL, like
    /// `menu_state`. The enablement half is where "print only what you
    /// measured" bites — on macOS `NSToolbarItem.isEnabled` stays `true` for
    /// a visibly disabled button, so each backend reads the property its own
    /// disable moves and names it at the arm.
    fn toolbar_item(&self, label: &str, aspect: &str) -> String;
    /// Drive the platform's key-equivalent dispatch for a canonical
    /// shortcut spelling — at minimum the same table the platform's own key
    /// event would traverse, emitting the SAME menu_activated the item's
    /// direct activation would (one dispatch path).
    fn shortcut(&self, spelling: &str);
    /// THE TEXT-RANGE READS, one per primitive. Read the table before
    /// writing an arm: the wrong SOURCE passes with the lowering
    /// deleted.
    ///
    /// | | source it MUST come from | mac (built) | windows | linux | ios/android |
    /// |---|---|---|---|---|---|
    /// | `highlights` | the platform's text attribute layer | `AXAttributedStringForRange` -> `AXBackgroundColor` runs (0.58ms for 60 runs over 1.9k chars, measured) | provider-side in-process `GetAttributeValue(BackgroundColor)` — never a UIA client attach, which is the file-dialog era's crash class | AT-SPI text attributes over the GtkTextTag | the interpreter's own view state |
    /// | `selection` | the platform's selection | `AXSelectedTextRange` | `GetSelection` | AT-SPI `GetSelection` | `selectedRange` / the field's selection |
    /// | `revealed` | the platform's VIEWPORT, never a model | `AXVisibleCharacterRange`, containment | `GetVisibleRanges` | the GtkScrolledWindow viewport geometry the foundation added | the scroll view's visible rect |
    ///
    /// SPELLING, both range verbs: `<start>:<end>=<covered text>` per
    /// range, `|`-joined, ascending; `""` when there is nothing. The
    /// offsets are UTF-8 BYTE offsets — the protocol's unit, not the
    /// backend's. This is the one place a backend converts an offset in the
    /// READING direction; the covered text beside it is what stops the read
    /// from being the lowering's own inverse (see Step::ExpectHighlights).
    ///
    /// TOTAL, like `menu_state`: a target that is not a textarea, or a
    /// widget that has vanished, answers with a short description rather
    /// than panicking, so these double as the wait for a render.
    fn highlights(&self, target: Target) -> String;
    fn selection(&self, target: Target) -> String;
    /// `visible` when the byte range is inside the widget's viewport,
    /// `offscreen` when it is not.
    fn revealed(&self, target: Target, range: TextRange) -> String;
    /// Start an input-method composition in the target, leaving `text`
    /// MARKED — displayed, uncommitted, invisible to the app. The platform's
    /// own composition entry point (`setMarkedText:`, `IMM`/`TSF`,
    /// `gtk_im_context`, `InputConnection.setComposingText`), never a text
    /// write: a plain insertion proves nothing about D4. Blocks until the
    /// composition is live.
    fn compose(&self, target: Target, text: &str);
    /// Report the verdict and end the process (backends own their exit
    /// discipline: process::exit, request_exit, _exit after finishing
    /// the Activity, ...).
    fn finish(&self, code: i32, verdict: &str);
}

/// Cut one script LINE into statements at `;` — the newline stand-in for
/// transports that cannot carry a newline. QUOTE-AWARE: kaya's own asset
/// miss sentence contains a semicolon, a `"` TOGGLES, and
/// tools/check-steps.py refuses an unbalanced statement. ALL THREE
/// INTERPRETERS SPLIT IDENTICALLY, and tools/scenes/assets.steps freezes a
/// quoted `;` on every lane through all three.
fn split_statements(line: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0usize;
    let mut quoted = false;
    for (i, c) in line.char_indices() {
        match c {
            '"' => quoted = !quoted,
            ';' if !quoted => {
                out.push(&line[start..i]);
                start = i + 1;
            }
            _ => {}
        }
    }
    out.push(&line[start..]);
    out
}

pub fn parse(script: &str) -> Result<Vec<Step>, String> {
    let mut steps = Vec::new();
    // Comments are whole newline-delimited lines; only the statements
    // that remain also split on `;`.
    for raw_line in script.split('\n') {
        let raw_line = raw_line.trim();
        if raw_line.is_empty() || raw_line.starts_with('#') {
            continue;
        }
        for raw in split_statements(raw_line) {
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
            "expect_stall" => Step::ExpectStall,
            "expect_no_stall" => Step::ExpectNoStall,
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
            "type" => {
                let text = parse_string(rest)?;
                check_typing(&text).map_err(|e| format!("{e}: {line:?}"))?;
                Step::Type(text)
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
            "expect_columns" => {
                let (target, text) = rest.split_once(char::is_whitespace).ok_or_else(|| {
                    format!("expect_columns wants a target and a string: {line:?}")
                })?;
                Step::ExpectColumns(parse_target(target)?, parse_string(text)?)
            }
            "expect_rows" => {
                let (target, text) = rest.split_once(char::is_whitespace).ok_or_else(|| {
                    format!("expect_rows wants a target and a string: {line:?}")
                })?;
                Step::ExpectRows(parse_target(target)?, parse_string(text)?)
            }
            "expect_column_edges" => {
                let (target, count) = rest.split_once(char::is_whitespace).ok_or_else(|| {
                    format!("expect_column_edges wants a target and a count: {line:?}")
                })?;
                Step::ExpectColumnEdges(
                    parse_target(target)?,
                    count.trim().parse().map_err(|_| {
                        format!("expect_column_edges wants a cluster count: {line:?}")
                    })?,
                )
            }
            "header_click" => {
                let (target, index) = rest.split_once(char::is_whitespace).ok_or_else(|| {
                    format!("header_click wants a target and a column index: {line:?}")
                })?;
                Step::HeaderClick(
                    parse_target(target)?,
                    index.trim().parse().map_err(|_| {
                        format!("header_click wants a 0-based column index: {line:?}")
                    })?,
                )
            }
            "expect_shares" => {
                let (target, text) = rest.split_once(char::is_whitespace).ok_or_else(|| {
                    format!("expect_shares wants a target and a string: {line:?}")
                })?;
                Step::ExpectShares(parse_target(target)?, parse_string(text)?)
            }
            "expect_fills" => Step::ExpectFills(parse_target(rest)?),
            "expect_breadth" => Step::ExpectBreadth(parse_target(rest)?),
            "expect_axis" => {
                let (target, text) = rest.split_once(char::is_whitespace).ok_or_else(|| {
                    format!("expect_axis wants a target and an axis string: {line:?}")
                })?;
                Step::ExpectAxis(parse_target(target)?, parse_string(text)?)
            }
            "expect_folded" => {
                let (child, table) = rest.split_once(char::is_whitespace).ok_or_else(|| {
                    format!("expect_folded wants a child target and a table target (or `none`): {line:?}")
                })?;
                let table = table.trim();
                let table = if table == "none" { None } else { Some(parse_target(table)?) };
                Step::ExpectFolded(parse_target(child)?, table)
            }
            "expect_aligned" => {
                let (target, text) = rest.split_once(char::is_whitespace).ok_or_else(|| {
                    format!("expect_aligned wants a target and a mode string: {line:?}")
                })?;
                Step::ExpectAligned(parse_target(target)?, parse_string(text)?)
            }
            "expect_inset" => {
                let rest = rest.trim();
                if let Ok(units) = rest.parse() {
                    Step::ExpectInset { target: None, units }
                } else {
                    let (target, units) =
                        rest.split_once(char::is_whitespace).ok_or_else(|| {
                            format!(
                                "expect_inset wants whole layout units, optionally \
                                 after a container target: {line:?}"
                            )
                        })?;
                    Step::ExpectInset {
                        target: Some(parse_target(target)?),
                        units: units.trim().parse().map_err(|_| {
                            format!("expect_inset wants whole layout units: {line:?}")
                        })?,
                    }
                }
            }
            "expect_typeface" => Step::ExpectTypeface(parse_string(rest)?),
            "expect_app_icon" => Step::ExpectAppIcon(parse_string(rest)?),
            // THE THREE CANVAS VERBS (docs/canvas-plan.md §7): the hash
            // is the primary observable, and expect_ink is the only one
            // that fails when the blit dropped.
            "expect_drawing_hash" => {
                let (target, text) = rest.split_once(char::is_whitespace).ok_or_else(|| {
                    format!("expect_drawing_hash wants a target and a string: {line:?}")
                })?;
                Step::ExpectDrawingHash(parse_target(target)?, parse_string(text)?)
            }
            "expect_drawing" => {
                let (target, text) = rest.split_once(char::is_whitespace).ok_or_else(|| {
                    format!("expect_drawing wants a target and a string: {line:?}")
                })?;
                Step::ExpectDrawing(parse_target(target)?, parse_string(text)?)
            }
            "expect_ink" => {
                let (target, text) = rest.split_once(char::is_whitespace).ok_or_else(|| {
                    format!("expect_ink wants a target and a string: {line:?}")
                })?;
                let target = parse_target(target)?;
                let spec = parse_string(text)?;
                // `"<x,y> ... = light <RRGGBB>/... dark <RRGGBB>/..."` —
                // the points and BOTH MODES' colours in ONE argument, so
                // no frozen ink expectation depends on the host's
                // appearance setting (`ink_for_mode`).
                let (points, want) = spec.split_once(" = ").ok_or_else(|| {
                    format!(
                        "expect_ink wants \"<x,y> ... = light <RRGGBB>/... dark <RRGGBB>/...\", \
                         got {spec:?}"
                    )
                })?;
                Step::ExpectInk(target, points.trim().to_owned(), want.trim().to_owned())
            }
            "expect_raster" => {
                let (target, text) = rest.split_once(char::is_whitespace).ok_or_else(|| {
                    format!("expect_raster wants a target and a string: {line:?}")
                })?;
                let want = parse_string(text)?;
                // A CLOSED SET, refused at parse: a typo would otherwise
                // be a string the stage can never answer, and the leg
                // would read as a real disagreement about the raster.
                if want != "track" && want != "viewbox" {
                    return Err(format!(
                        "expect_raster wants \"track\" or \"viewbox\" — which size the \
                         canvas's raster is (docs/canvas-plan.md §3.2.1) — got {want:?}"
                    ));
                }
                Step::ExpectRaster(parse_target(target)?, want)
            }
            "frame" => {
                // Bare `frame` is one frame; `frame <n>` is n. Zero is
                // refused: a step that drives nothing is a scene saying
                // something it does not mean.
                let n: u32 = if rest.is_empty() {
                    1
                } else {
                    rest.trim()
                        .parse()
                        .map_err(|_| format!("frame wants a whole number of frames: {line:?}"))?
                };
                if n == 0 {
                    return Err(format!("frame 0 advances nothing: {line:?}"));
                }
                Step::Frame(n)
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
            "expect_section_symbol" => {
                let (title, want) = parse_quoted_prefix(rest).map_err(|e| {
                    format!("expect_section_symbol wants a quoted section title and a quoted symbol name: {e}")
                })?;
                Step::ExpectSectionSymbol(title, parse_string(want)?)
            }
            "expect_sections_presentation" => {
                let (window, rest) = parse_window_target(rest);
                Step::ExpectSectionsPresentation(window, parse_string(rest)?)
            }
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
            "expect_dirty" => {
                let (window, rest) = parse_window_target(rest);
                // `parse::<bool>` rather than a match on the two
                // spellings: check-verbs reads THIS function's `"…" =>`
                // arms as the verb grammar, so a literal argument here
                // would enter the vocabulary and be demanded of both
                // interpreters as if it were a verb.
                let on = rest.trim().parse::<bool>().map_err(|_| {
                    format!("expect_dirty wants true or false: {line:?}")
                })?;
                Step::ExpectDirty(window, on)
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
                // `expect_file_dialog <dir> <name>...`: bare names, so
                // the script stays identical on lanes whose temp dirs
                // differ. BARE means "a picker is live" — the wait a
                // scene needs before it can navigate, since an action
                // fired before the panel exists silently does nothing.
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
            "expect_save_dialog" => {
                // `expect_save_dialog <dir> <name>`. BOTH REQUIRED,
                // unlike the picker's bare form — a save dialog with no
                // browser publishes nothing else worth asserting.
                let mut words = rest.split_whitespace().map(str::to_owned);
                let (Some(dir), Some(name)) = (words.next(), words.next()) else {
                    return Err(format!(
                        "expect_save_dialog wants a directory and a name: {line:?}"
                    ));
                };
                if words.next().is_some() {
                    // A name with a space in it would silently assert
                    // against its first word.
                    return Err(format!(
                        "expect_save_dialog takes exactly a directory and a name: {line:?}"
                    ));
                }
                Step::ExpectSaveDialog(dir, name)
            }
            "file_dialog_name" => {
                let name = rest.trim();
                if name.is_empty() {
                    return Err(format!("file_dialog_name wants a file name: {line:?}"));
                }
                if name.split_whitespace().count() != 1 {
                    return Err(format!(
                        "file_dialog_name takes one name and no spaces: {line:?}"
                    ));
                }
                Step::FileDialogName(name.to_owned())
            }
            "file_save" => {
                // `file_save` presses Save; `file_save cancel` presses
                // Cancel — the picker's shape minus the row.
                match rest.trim() {
                    "" => Step::FileSave(true),
                    "cancel" => Step::FileSave(false),
                    other => {
                        return Err(format!(
                            "file_save takes nothing or `cancel`, got {other:?}: {line:?}"
                        ))
                    }
                }
            }
            "clipboard_seed" => {
                // `clipboard_seed <kind> <argument>`: a closed kind name
                // or a custom format id, then the content — a literal for
                // text, html and custom, a path for image and files (with
                // $TMP/$PID expanded, the file_dialog_goto rule).
                let (kind, arg) = rest.trim().split_once(char::is_whitespace).ok_or_else(|| {
                    format!("clipboard_seed wants a kind and its content: {line:?}")
                })?;
                // QUOTED like an expect's string, because seeded content
                // is content: it may hold spaces, and a path may not.
                Step::ClipboardSeed(kind.to_owned(), parse_string(arg)?)
            }
            "expect_clipboard" => {
                // `expect_clipboard <kind> <expected>`: the content for
                // text, html and custom; the basenames for files; and the
                // DECODED SIZE ("4x4") for an image, because the hosts
                // re-encode freely and a byte count would differ per
                // platform for the same picture.
                let (kind, want) = rest.trim().split_once(char::is_whitespace).ok_or_else(|| {
                    format!("expect_clipboard wants a kind and the expected content: {line:?}")
                })?;
                Step::ExpectClipboard(kind.to_owned(), parse_string(want)?)
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
            "expect_window" => {
                let mut words = rest.split_whitespace();
                let target = words
                    .next()
                    .ok_or_else(|| format!("expect_window wants a target: {line:?}"))?;
                let mut number = |what: &str| -> Result<usize, String> {
                    words
                        .next()
                        .and_then(|w| w.parse().ok())
                        .ok_or_else(|| format!("expect_window wants a {what}: {line:?}"))
                };
                let first = number("first visible index")?;
                let total = number("declared total")?;
                if words.next().is_some() {
                    return Err(format!(
                        "expect_window takes a target and exactly two numbers \
                         (first visible index, declared total): {line:?}"
                    ));
                }
                Step::ExpectWindow(parse_target(target)?, first, total)
            }
            "scroll_to_row" => {
                let (target, key) = rest.split_once(char::is_whitespace).ok_or_else(|| {
                    format!("scroll_to_row wants a target and a row key: {line:?}")
                })?;
                let key = key.trim();
                // The key is a STRING, quoted only when it needs to be:
                // the keyed-target grammar this shares its addressing
                // with is string-key-only (table_tag_identity).
                let key = if key.starts_with('"') {
                    parse_string(key)?
                } else if key.is_empty() || key.split_whitespace().count() != 1 {
                    return Err(format!(
                        "scroll_to_row wants ONE row key, quoted if it has spaces: {line:?}"
                    ));
                } else {
                    key.to_owned()
                };
                Step::ScrollToRow(parse_target(target)?, key)
            }
            "drag" => {
                // drag <source> to <destination> [before|onto]
                let mut words: Vec<&str> = rest.split_whitespace().collect();
                let reorder = match words.last().copied() {
                    Some("before") => {
                        words.pop();
                        Some(true)
                    }
                    Some("onto") => {
                        words.pop();
                        Some(false)
                    }
                    _ => None,
                };
                if words.len() != 3 || words[1] != "to" {
                    return Err(format!(
                        "drag wants `<source> to <destination> [before|onto]`: {line:?}"
                    ));
                }
                Step::Drag(parse_target(words[0])?, parse_target(words[2])?, reorder)
            }
            "drag_file" => {
                // drag_file "<path>" to <destination> — the path quoted like
                // clipboard_seed's content, since a path may hold spaces.
                let spec = rest.trim();
                let close = spec
                    .strip_prefix('"')
                    .and_then(|s| s.find('"'))
                    .ok_or_else(|| format!("drag_file wants a quoted path first: {line:?}"))?;
                let path = unescape(&spec[1..close + 1]);
                let words: Vec<&str> = spec[close + 2..].split_whitespace().collect();
                if words.len() != 2 || words[0] != "to" {
                    return Err(format!("drag_file wants `\"<path>\" to <destination>`: {line:?}"));
                }
                Step::DragFile(path, parse_target(words[1])?)
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
            "expect_menu_symbol" => {
                let (path, want) = parse_quoted_prefix(rest).map_err(|e| {
                    format!("expect_menu_symbol wants a quoted path and a quoted symbol name: {e}")
                })?;
                Step::ExpectMenuSymbol(path, parse_string(want)?)
            }
            "expect_menus" => Step::ExpectMenus(
                rest.trim()
                    .parse::<usize>()
                    .map_err(|_| format!("expect_menus wants a count: {line:?}"))?,
            ),
            // The hint is its own verb rather than a third field on
            // expect_ax: the `<role>/<label>` spelling is byte-frozen in
            // every scene.
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
            "expect_panes" => {
                if rest.trim().is_empty() {
                    Step::ExpectPanes(None)
                } else {
                    let want = parse_string(rest)?;
                    check_panes_reading(&want).map_err(|e| format!("{e}: {line:?}"))?;
                    Step::ExpectPanes(Some(want))
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
            // BARE ONLY: a count here would be a per-lane literal in a
            // scene compared byte-for-byte on five of them.
            "expect_toolbar" => {
                if !rest.trim().is_empty() {
                    return Err(format!(
                        "expect_toolbar takes no argument — capacity k is the \
                         platform's number, so the step asserts the invariant \
                         (the promoted set is in the chrome, the remainder is \
                         reachable): {line:?}"
                    ));
                }
                Step::ExpectToolbar
            }
            "expect_toolbar_item" => {
                let (label, tail) = parse_quoted_prefix(rest).map_err(|e| {
                    format!("expect_toolbar_item wants a quoted label and a quoted aspect: {e}")
                })?;
                let aspect = parse_string(tail)?;
                check_toolbar_aspect(&aspect).map_err(|e| format!("{e}: {line:?}"))?;
                Step::ExpectToolbarItem(label, aspect)
            }
            "shortcut" => {
                let spelling = parse_string(rest)?;
                // Grammar-level sanity only. The POLICY floor (the
                // modifier rules, the named-key set, the reserved union)
                // is the root's one checker (scene.rs), and a spelling it
                // rejects can never reach a dispatch table.
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
            "expect_highlights" => {
                let (target, text) = rest.split_once(char::is_whitespace).ok_or_else(|| {
                    format!(
                        "expect_highlights wants a target and a \"s:e=text|...\" string \
                         (the empty string asserts nothing is decorated): {line:?}"
                    )
                })?;
                let want = parse_string(text)?;
                check_range_list(&want).map_err(|e| format!("{e}: {line:?}"))?;
                Step::ExpectHighlights(parse_target(target)?, want)
            }
            "expect_selection" => {
                let (target, text) = rest.split_once(char::is_whitespace).ok_or_else(|| {
                    format!("expect_selection wants a target and a \"s:e=text\" string: {line:?}")
                })?;
                let want = parse_string(text)?;
                check_range_list(&want).map_err(|e| format!("{e}: {line:?}"))?;
                if want.contains('|') {
                    return Err(format!(
                        "expect_selection takes ONE range; a set is expect_highlights: {line:?}"
                    ));
                }
                Step::ExpectSelection(parse_target(target)?, want)
            }
            "expect_revealed" => {
                let mut parts = rest.split_whitespace();
                let (Some(target), Some(range), Some(state), None) =
                    (parts.next(), parts.next(), parts.next(), parts.next())
                else {
                    return Err(format!(
                        "expect_revealed wants a target, a start:end range and \
                         visible|offscreen: {line:?}"
                    ));
                };
                if state != "visible" && state != "offscreen" {
                    return Err(format!(
                        "expect_revealed state is {state:?}, wanted visible or offscreen: {line:?}"
                    ));
                }
                Step::ExpectRevealed(
                    parse_target(target)?,
                    parse_range(range).map_err(|e| format!("{e}: {line:?}"))?,
                    state.to_owned(),
                )
            }
            "compose" => {
                let (target, text) = rest.split_once(char::is_whitespace).ok_or_else(|| {
                    format!("compose wants a target and a quoted marked text: {line:?}")
                })?;
                let marked = parse_string(text)?;
                if marked.is_empty() {
                    return Err(format!("compose wants a non-empty marked text: {line:?}"));
                }
                Step::Compose(parse_target(target)?, marked)
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
    // The authored-key spelling: kind@id, optionally narrowed to one
    // stamped copy by its outermost-first string keys.
    if let Some((kind, authored)) = spec.split_once('@') {
        let kind = parse_target_kind(kind, spec)?;
        let (id, keys) = if let Some(open) = authored.find('[') {
            if !authored.ends_with(']')
                || authored[open + 1..authored.len() - 1].contains('[')
                || authored[open + 1..authored.len() - 1].contains(']')
            {
                return Err(format!("target copy keys are malformed: {spec:?}"));
            }
            let keys = &authored[open + 1..authored.len() - 1];
            if keys.is_empty() || keys.split('.').any(str::is_empty) {
                return Err(format!("target copy keys want dot-joined non-empty segments: {spec:?}"));
            }
            let id = &authored[..open];
            if id.contains(['[', ']', '@']) {
                return Err(format!("target copy keys are malformed: {spec:?}"));
            }
            (id, Some(keys))
        } else {
            if authored.contains([']', '@']) {
                return Err(format!("target copy keys are malformed: {spec:?}"));
            }
            (authored, None)
        };
        if id.is_empty() {
            return Err(format!("target id is empty: {spec:?}"));
        }
        return Ok(Target {
            kind,
            index: 0,
            id: Some(&*Box::leak(id.to_owned().into_boxed_str())),
            keys: keys.map(|keys| &*Box::leak(keys.to_owned().into_boxed_str())),
        });
    }
    let (kind, index) = spec
        .split_once('#')
        .ok_or_else(|| format!("target wants kind#index or kind@id[key.path]: {spec:?}"))?;
    let kind = parse_target_kind(kind, spec)?;
    let index = if index == "last" {
        -1
    } else {
        index
            .parse()
            .map_err(|_| format!("target index wants a number or `last`: {spec:?}"))?
    };
    Ok(Target { kind, index, id: None, keys: None })
}

fn parse_target_kind(kind: &str, spec: &str) -> Result<TargetKind, String> {
    Ok(match kind {
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
        "canvas" => TargetKind::Canvas,
        other => return Err(format!("unknown target kind {other:?} in {spec:?}")),
    })
}

fn parse_string(spec: &str) -> Result<String, String> {
    let spec = spec.trim();
    let inner = spec
        .strip_prefix('"')
        .and_then(|s| s.strip_suffix('"'))
        .ok_or_else(|| format!("wanted a quoted string, got {spec:?}"))?;
    Ok(unescape(inner))
}

/// The escapes the line-oriented grammar needs: `\n` -> newline (a
/// textarea's distinguishing observable is accepting one, and it cannot
/// ride a script line), `\r` -> carriage return (the paste stand-in that
/// proves the backends' LF normalization), `\\` -> backslash. All three
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

/// A LEADING quoted string plus the remainder after its closing quote —
/// for the verbs whose quoted argument comes first (a menu path may
/// contain spaces, so whitespace-splitting before the quote would shear
/// a label). Honors the same escapes as [`parse_string`].
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

/// What `type` may carry: a non-empty run of PRINTABLE ASCII, the one range
/// where all five platforms agree on the character-to-keycode mapping with
/// no keyboard-layout or input-method machinery (docs/undo-plan.md A5). A
/// LINE BREAK IS REFUSED FOR A SECOND REASON: Return is a command, not a
/// character, and what it does depends on the widget it lands in — while the
/// target here is whatever holds focus.
fn check_typing(text: &str) -> Result<(), String> {
    if text.is_empty() {
        return Err("type wants some text to type".to_owned());
    }
    for c in text.chars() {
        if !matches!(c, ' '..='~') {
            return Err(format!(
                "type {text:?} carries {c:?}, which is not printable ASCII — a \
                 keystroke needs one keycode per character, and that mapping is \
                 only platform-independent inside 0x20..0x7e"
            ));
        }
    }
    Ok(())
}

/// A menu path is labels joined with `>`: at least one label, every
/// segment non-empty and byte-exact. No trimming — labels compare
/// byte-for-byte across every language, so a padded segment is a typo
/// that would surface as a bewildering "no such item" at runtime.
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

/// One `start:end` range in a harness assertion — UTF-8 byte offsets,
/// the protocol's own unit, so a scene and a guest spell the same
/// numbers.
fn parse_range(spec: &str) -> Result<TextRange, String> {
    let Some((start, end)) = spec.split_once(':') else {
        return Err(format!("range {spec:?} wants start:end"));
    };
    let start: u64 = start
        .parse()
        .map_err(|_| format!("range {spec:?} has a non-numeric start"))?;
    let end: u64 = end
        .parse()
        .map_err(|_| format!("range {spec:?} has a non-numeric end"))?;
    if start > end {
        return Err(format!("range {spec:?} starts after it ends"));
    }
    Ok(TextRange { start, stop: end })
}

/// The spelling of a range assertion: `<start>:<end>=<covered text>` per
/// range, joined with `|`, ascending. The empty string is the empty set
/// and is meaningful — it is what a scene asserts after an edit drops a
/// declared set (docs/ranges-plan.md D2). A `|` inside the covered text
/// would read back as two ranges and name the wrong offsets.
fn check_range_list(spec: &str) -> Result<(), String> {
    if spec.is_empty() {
        return Ok(());
    }
    for item in spec.split('|') {
        let Some((range, _covered)) = item.split_once('=') else {
            return Err(format!(
                "range assertion {item:?} wants <start>:<end>=<covered text>"
            ));
        };
        parse_range(range)?;
    }
    Ok(())
}

/// The spelling of an expect_ax step: `<role>/<label>`. The role half is
/// a closed set — the platforms' own vocabularies normalized — while the
/// label half is free text. An empty label is legal and meaningful: it
/// asserts the platform speaks nothing for this element.
fn check_ax(spec: &str) -> Result<(), String> {
    // NORMALIZED, not exhaustive: a platform role no other platform can
    // match is normalized DOWN to the coarsest one they all publish
    // (macOS's AXRadioGroup and AXScrollArea are both `group`), because a
    // name only one backend can produce is a name no shared scene can
    // assert.
    const ROLES: [&str; 11] = [
        "button", "label", "field", "checkbox", "slider", "image", "progress",
        "combobox", "group", "heading", "unknown",
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
/// overflow. Deliberately ASYMMETRIC — a compact window showing a bar is
/// legitimate (a narrow GTK or WinUI window keeps its menu bar). The two
/// interpreters mirror it.
fn menu_presentation_fits(spelling: &str) -> bool {
    let (class, presentation) = spelling.split_once('/').unwrap_or(("unknown", "none"));
    !(class == "regular" && presentation == "overflow")
}

/// The invariant the BARE expect_split step asserts: a regular window
/// must not be showing ONE pane while its stack holds two. Asymmetric
/// for the menu rule's reason — what counts as wide enough is the
/// platform's call, and a compact window is never asked to show two.
fn split_presentation_fits(spelling: &str, entries: usize) -> bool {
    let (class, presentation) = spelling.split_once('/').unwrap_or(("unknown", "stacked"));
    !(class == "regular" && presentation == "stacked" && entries >= 1)
}

/// The presentation spelling of an expect_split step:
/// `<size class>/<presentation>`, both halves from closed sets — a typo
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

/// The reading of an expect_panes step: `<size class>/<positions>`,
/// positions a comma-joined STRICTLY ASCENDING list of stack indices
/// (docs/multicolumn-plan.md D4). Ascending because the panes ARE the
/// stack's order — "2,1" asserts an arrangement no lowering can
/// produce.
fn check_panes_reading(spec: &str) -> Result<(), String> {
    const CLASSES: [&str; 3] = ["unknown", "compact", "regular"];
    let Some((class, positions)) = spec.split_once('/') else {
        return Err(format!("panes reading {spec:?} wants <size class>/<positions>"));
    };
    if !CLASSES.contains(&class) {
        return Err(format!(
            "panes reading {spec:?} has an unknown size class {class:?}; \
             wanted one of {CLASSES:?}"
        ));
    }
    let mut last: Option<u64> = None;
    for part in positions.split(',') {
        let Ok(n) = part.parse::<u64>() else {
            return Err(format!(
                "panes reading {spec:?} has a non-numeric position {part:?}"
            ));
        };
        if last.is_some_and(|l| l >= n) {
            return Err(format!(
                "panes reading {spec:?} lists positions out of ascending order"
            ));
        }
        last = Some(n);
    }
    Ok(())
}

/// The visible-position half of a TWO-pane world's panes reading,
/// derived from the split stamp and the stack, which is exact there. A
/// backend with a third pane must answer Stage::panes_reading from its
/// real arrangement instead — the wide leg of panes.steps fails loudly
/// against this derivation.
pub(crate) fn panes_positions(presentation: &str, entries: usize) -> String {
    match (presentation, entries) {
        ("split", 0) => "0".to_owned(),
        ("split", n) => format!("0,{n}"),
        (_, n) => format!("{n}"),
    }
}

/// The presentation spelling of an expect_menu_presentation step:
/// `<size class>/<presentation>`, both halves from closed sets, so a
/// typo dies at parse rather than reading as a backend disagreeing with
/// the scene. `unknown` IS a legal size class to write: a backend that
/// has not observed its window yet must be able to say so.
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

/// The invariant the BARE expect_toolbar step asserts, off the backend's
/// chrome reading: the promoted set really reached the chrome, and the
/// remainder has somewhere to live. `Err` carries the sentence the step
/// fails with, which names the MEASURED numbers and nothing else. The
/// two interpreters mirror it.
fn toolbar_chrome_fits(spelling: &str) -> Result<(), String> {
    const HOMES: [&str; 4] = ["menubar", "more", "overflow", "none"];
    let parts: Vec<&str> = spelling.split('/').collect();
    let [found, promoted, items, home] = parts[..] else {
        return Err(format!(
            "chrome reads {spelling:?}, which is not \
             <promoted found>/<promoted>/<items>/<remainder's home>"
        ));
    };
    let (Ok(found), Ok(promoted), Ok(items)) = (
        found.parse::<usize>(),
        promoted.parse::<usize>(),
        items.parse::<usize>(),
    ) else {
        return Err(format!(
            "chrome reads {spelling:?}, whose first three fields are not counts"
        ));
    };
    if !HOMES.contains(&home) {
        return Err(format!(
            "chrome reads {spelling:?}, whose remainder home {home:?} is not one of {HOMES:?}"
        ));
    }
    if found != promoted {
        return Err(format!(
            "the window's chrome holds {items} items, and {found} of the \
             {promoted} promoted actions are among them in catalog preorder"
        ));
    }
    if home == "none" {
        return Err(format!(
            "the chrome holds the {found} promoted actions and the remainder \
             of the catalog has no home in this window"
        ));
    }
    Ok(())
}

/// The aspect of an expect_toolbar_item step: `enabled`, `disabled`, or
/// a name from the symbol vocabulary. Checked at PARSE against
/// `wire::SYMBOLS` — the same closed set the prop's value wall reads —
/// so a typo does not read as a backend drawing the wrong glyph.
fn check_toolbar_aspect(aspect: &str) -> Result<(), String> {
    if aspect == "enabled" || aspect == "disabled" {
        return Ok(());
    }
    if crate::wire::SYMBOLS.iter().any(|(_, name)| *name == aspect) {
        return Ok(());
    }
    let names: Vec<&str> = crate::wire::SYMBOLS.iter().map(|(_, name)| *name).collect();
    Err(format!(
        "toolbar aspect {aspect:?} is neither enabled/disabled nor a symbol \
         name; wanted one of {names:?}"
    ))
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
/// and the verdict joins their observed values.
pub fn spawn(scene: &str, stage: impl Stage, log: fn(&str)) {
    // A scene with no script must NOT return silently: the app would
    // run, no steps would execute, no verdict would print, and the runner
    // would wait out its whole timeout with nothing to show.
    let Some(text) = script(scene) else {
        preflight_fail(
            stage,
            format!(
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
            preflight_fail(stage, format!("KAYA_SELFTEST: FAILED (bad script: {e})"));
            return;
        }
    };
    std::thread::spawn(move || {
        // A HARNESS PANIC TERMINATES THE PROCESS: a panic here unwinds only
        // THIS thread, the UI thread keeps the process alive, and the runner
        // — which waits for process EXIT — burns its whole timeout. Measured
        // 2026-07-25 on Windows: a shortcut verb panicked at +714ms and the
        // leg was reported as a 328-SECOND HANG, with the real diagnosis
        // unread in the output file the entire time.
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
            harness_exit(1);
        }
        // AND THE VERDICT IS FINAL EVEN IF NOTHING CAN SHUT DOWN. An app
        // thread that never returns cannot participate in shutdown, and
        // five of the eight bindings then hang at exit waiting for it
        // (docs/deferred.md). The grace lets the orderly path win where it
        // works and the process leave under its own verdict where it does
        // not.
        let code = outcome.unwrap_or(1);
        std::thread::sleep(EXIT_GRACE);
        harness_exit(code);
    });
}

/// The synchronous run loop, factored out of spawn so tests can drive
/// it with a mock stage.
pub fn run(steps: Vec<Step>, stage: impl Stage) {
    let _ = run_with_log(steps, stage, None);
}

/// A verdict published before any step, from whatever thread called
/// `spawn` — the app's own thread on both Rust backends, where
/// `finish`'s exit hop cannot be answered at all. EXIT_GRACE is then
/// the only thing that ends the process.
fn preflight_fail(stage: impl Stage, verdict: String) {
    let watch = StepWatchdog::start(step_ceiling());
    watch.published(1);
    stage.finish(1, &verdict);
    watch.clear();
    std::thread::sleep(EXIT_GRACE);
    harness_exit(1);
}

/// Recording handshake: KAYA_HARNESS_GATE means the runner is recording
/// this window, and the recorder needs time to deliver its first frame
/// (seconds, when several streams start under load). Waiting for the
/// runner's go-file means a leg cannot outrun its recorder. Bounded, and
/// a no-op without the variable.
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

/// A recorded leg must outlive its last sample time: the verdict and
/// exit follow the last step by milliseconds, so any anchor drift hands
/// the covering-frame rule a teardown frame (docs/traps.md). A no-op
/// without a recorder, and the pre-flight failures skip it.
fn record_linger() {
    if std::env::var_os("KAYA_RECORD").is_some()
        || std::env::var_os("KAYA_HARNESS_GATE").is_some()
    {
        std::thread::sleep(Duration::from_millis(750));
    }
}

/// `expect_ink` compares WITHIN ±1 PER CHANNEL (ruled 2026-08-26,
/// docs/canvas-plan.md §7.2): a macOS window's backing store carries the
/// DISPLAY's profile, so the core's D2E3F7 reads back as D2E2F7 there while
/// Android reports the core's own bytes (docs/traps.md). The byte-exact
/// assertion is `expect_drawing_hash`. Both interpreters carry their own
/// copy, and tools/check-verbs.py holds the three equal and pinned at 1.
const INK_TOLERANCE: i32 = 1;

/// The half of a PER-MODE expectation that names `mode`, out of
/// `"light FFFFFF/D2E3F7 dark 16181C/2B3B4F"` (docs/canvas-plan.md §7.2).
/// ONE SPELLING CARRYING BOTH MODES keeps a frozen ink expectation from
/// depending on the host's appearance; a mode the string does not name is
/// `None`, which never matches. KayaSwiftUI.swift and KayaCompose.kt carry
/// their own copies.
fn ink_for_mode<'a>(want: &'a str, mode: &str) -> Option<&'a str> {
    let mut it = want.split_whitespace();
    while let (Some(named), Some(colours)) = (it.next(), it.next()) {
        if named == mode {
            return Some(colours);
        }
    }
    None
}

/// The reported mode's colours, every channel within [`INK_TOLERANCE`].
/// An answer that does not parse never matches, so every `<...>`
/// diagnostic the backends return reaches the failure text whole.
fn ink_matches(got: &str, want: &str) -> bool {
    fn channels(hex: &str) -> Option<[i32; 3]> {
        if hex.len() != 6 || !hex.is_ascii() {
            return None;
        }
        let mut out = [0i32; 3];
        for (i, c) in out.iter_mut().enumerate() {
            *c = i32::from_str_radix(&hex[i * 2..i * 2 + 2], 16).ok()?;
        }
        Some(out)
    }
    let Some((got_mode, got_ink)) = got.split_once(' ') else {
        return false;
    };
    let Some(want_ink) = ink_for_mode(want, got_mode) else {
        return false;
    };
    let got_ink: Vec<&str> = got_ink.split('/').collect();
    let want_ink: Vec<&str> = want_ink.split('/').collect();
    got_ink.len() == want_ink.len()
        && got_ink.iter().zip(&want_ink).all(|(g, w)| match (channels(g), channels(w)) {
            (Some(g), Some(w)) => {
                g.iter().zip(&w).all(|(a, b)| (a - b).abs() <= INK_TOLERANCE)
            }
            _ => false,
        })
}

/// Returns the verdict's exit code, which the harness thread needs after
/// `finish` in order to leave under its own verdict when nothing else can
/// end the process (see spawn).
fn run_with_log(steps: Vec<Step>, stage: impl Stage, log: Option<fn(&str)>) -> i32 {
    // Watched, before any step: a fault reddens this leg instead of
    // ending the process (crates/kaya/src/fault.rs).
    crate::fault::watch();
    if log.is_some() {
        gate_wait();
    }
    // Offsets are relative to here — after the gate, so the recording
    // contains every step from its own t=0 onward.
    let start = Instant::now();
    // The verb trace counts from the same zero, and the ring is this
    // run's alone (crates/kaya/src/vtrace.rs).
    vtrace::begin(start);
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
    // THE CEILING THAT COVERS THE HOP (STEP_CEILING), and the grace that
    // covers every `finish` below it. Dropped with this frame, so nothing
    // it can report outlives the run.
    let watch = StepWatchdog::start(step_ceiling());
    // A script with no expects proves nothing; a transport that
    // mangled the text into a comment must fail, not pass.
    if !steps.iter().any(Step::is_assertion)
    {
        watch.published(1);
        stage.finish(1, "KAYA_SELFTEST: FAILED (script has no expects)");
        watch.clear();
        return 1;
    }
    let mut observed = Vec::new();
    let mut failures = Vec::new();
    // A FAULT ENDS THE RUN, carrying its sentence into the verdict list
    // rather than aborting with the failures already collected
    // (docs/deferred.md, "A GUARD THAT ABORTS THE PROCESS IS THE WRONG
    // SHAPE").
    let mut faulted = false;
    for (ordinal, step) in steps.iter().enumerate() {
        if let Some(sentence) = crate::fault::latched() {
            if let Some((log, _)) = log {
                log(&format!("KAYA_HARNESS: step-failed {sentence}"));
            }
            failures.push(sentence);
            faulted = true;
            break;
        }
        // Where this step's failures start, for the retraction below.
        let failures_before = failures.len();
        // Armed BEFORE the id normalization below, which hops as well
        // (Stage::resolve_id), and with the step as the script wrote it.
        watch.enter(format!("{step:?}"));
        vtrace::step(ordinal, format_args!("{step:?}"));
        // kind@id targets normalize HERE, once per step, through the
        // backend's own records — so the index-shaped Stage reads below
        // never learn about ids. An OBSERVATION retries the resolution on
        // the poll clock (an id applies with the scene, so absence is a
        // non-match); an ACTION's target must have been proven by a
        // preceding expect, so a miss there fails the step at once.
        let mut step_norm = step.clone();
        let mut unresolved = None;
        {
            let retry = step_norm.is_assertion();
            for t in step_norm.targets_mut() {
                let Some(id) = t.id else { continue };
                let deadline = Instant::now() + POLL_DEADLINE;
                let mut tries = 0u32;
                vtrace::note(
                    "resolve_id",
                    format_args!(
                        "-> searching for a {:?} carrying a11y_id {id:?}{}",
                        t.kind,
                        t.keys.map_or(String::new(), |keys| format!(" at copy [{keys}]"))
                    ),
                );
                loop {
                    tries += 1;
                    if let Some(index) = stage.resolve_id(t.kind, id, t.keys) {
                        vtrace::attempt(
                            "resolve_id",
                            tries,
                            format_args!("<- {id:?} resolved to index {index}"),
                        );
                        *t = Target { kind: t.kind, index, id: None, keys: None };
                        break;
                    }
                    vtrace::attempt(
                        "resolve_id",
                        tries,
                        format_args!("<- no {:?} carries {id:?} yet", t.kind),
                    );
                    if !retry || Instant::now() >= deadline {
                        unresolved = Some(format!(
                            "{} names no widget: no {:?} carries a11y_id \"{id}\"{}",
                            target_spec(t), t.kind,
                            t.keys.map_or(String::new(), |keys| format!(" at copy [{keys}]"))
                        ));
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(50));
                }
                if unresolved.is_some() {
                    break;
                }
            }
        }
        if let Some(text) = unresolved {
            if let Some((log, _)) = log {
                log(&format!("KAYA_HARNESS: step-failed {text}"));
            }
            failures.push(text);
            continue;
        }
        let step = &step_norm;
        if let Some((log, start)) = log {
            log(&format!(
                "KAYA_HARNESS: +{}ms {:?}",
                start.elapsed().as_millis(),
                step
            ));
        }
        // Actions run once, immediately; observations are bounded
        // retries (see POLL_DEADLINE): each arm builds a pass/fail
        // outcome, and `poll` re-evaluates a failing one until it passes
        // or the deadline lands the last failure text.
        let outcome: Option<Result<String, String>> = match step {
            Step::Settle(ms) => {
                std::thread::sleep(Duration::from_millis(*ms));
                None
            }
            Step::Click(t) => {
                vtrace::note("click", format_args!("-> stage.click {}", target_spec(t)));
                stage.click(*t);
                vtrace::note("click", format_args!("<- stage.click {}", target_spec(t)));
                None
            }
            // WRAPPED IN `poll` because the watchdog needs its threshold
            // to elapse before it will say anything: a single evaluation
            // reads "keeping up" every time.
            Step::ExpectStall => Some(poll(|| match crate::stall::stalled_for() {
                Some(waited) => Ok(format!("stalled {}ms", waited.as_millis())),
                None => Err(
                    "the app thread is keeping up — no pending occurrences have gone \
                     unclaimed, so the stall watchdog has nothing to report"
                        .to_string(),
                ),
            })),
            // POLLED TOO, for the mirror-image reason: the watchdog
            // clears its reading on its own 100ms poll. What it must NOT
            // tolerate is a reading that never clears, which is what a
            // watchdog blind to a transport produces.
            Step::ExpectNoStall => Some(poll(|| match crate::stall::stalled_for() {
                None => Ok("the app thread is keeping up".to_string()),
                Some(waited) => Err(format!(
                    "the stall watchdog reports {}ms of unclaimed occurrences about an app \
                     that is answering this scene — either the app thread really is gone, \
                     or the watchdog cannot see this guest's transport (crate::stall)",
                    waited.as_millis()
                )),
            })),
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
            Step::Type(s) => {
                vtrace::note("type", format_args!("-> stage.type_text {s:?}"));
                stage.type_text(s);
                vtrace::note("type", format_args!("<- stage.type_text {s:?}"));
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
            Step::ExpectSectionSymbol(title, want) => Some(poll(|| {
                let got = stage.section_symbol(title);
                if got == *want {
                    // Byte-identical on every backend: the title in its
                    // quoted spelling, then the semantic name.
                    Ok(format!("section {title:?} symbol {want:?}"))
                } else {
                    // The MEASURED answer rides the failure — the only
                    // thing that tells "wrong glyph" from "no glyph at
                    // all" from "no such row yet".
                    Err(format!("section {title:?} symbol {got:?}, wanted {want:?}"))
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
                // what says whether it landed — EXCEPT for the two scene
                // bugs below, silent everywhere else, each of which cost a
                // debugging session (docs/traps.md).
                let resolved = expand_path(path);
                if resolved.contains('$') {
                    Some(Err(format!(
                        "file_dialog_goto {path}: unexpanded substitution in \
                         {resolved} — only $TMP and $PID exist"
                    )))
                } else if !std::path::Path::new(&resolved).is_dir() {
                    // A picker aimed at a directory that does not exist
                    // does not fail — it silently shows somewhere else,
                    // and the scene then asserts against a directory
                    // nobody chose.
                    Some(Err(format!(
                        "file_dialog_goto {path}: {resolved} does not exist — the \
                         picker would silently fall back to its last-used \
                         location and the scene would compare against that"
                    )))
                } else {
                    vtrace::note(
                        "file_dialog_goto",
                        format_args!("-> stage.goto_directory {resolved} (scene wrote {path})"),
                    );
                    stage.goto_directory(&resolved);
                    // THE AIM BESIDE THE ANSWER, the record
                    // docs/deferred.md's iOS-sheets WATCH entry asked for:
                    // the fifth face of that family was a picker sitting
                    // in the PARENT directory and nothing paired the goto
                    // with the breadcrumb. Read only when recording — it
                    // is one more hop to the UI thread.
                    if vtrace::on() {
                        let breadcrumb = stage.file_dialog_state().map(|(where_, _)| where_);
                        vtrace::note(
                            "file_dialog_goto",
                            format_args!(
                                "<- asked for {resolved}; the picker's breadcrumb right \
                                 after the call reads {breadcrumb:?}"
                            ),
                        );
                    }
                    None
                }
            }
            Step::ClipboardSeed(kind, arg) => {
                // An action, silent like click. Expanded HERE for the
                // Rust backends, exactly as each interpreter expands in
                // its own seed (KayaSwiftUI's kayaClipboardSeed): image
                // and files seeds name the guest's scene files by
                // $TMP/$PID token, and an unexpanded token is a literal
                // path that exists nowhere.
                let resolved = expand_path(arg);
                if matches!(kind.as_str(), "image" | "files")
                    && !std::path::Path::new(&resolved).exists()
                {
                    // A FILE THAT IS NOT THERE IS NOT A CLIPBOARD
                    // PROBLEM, and the tools do not say so
                    // (docs/traps.md, "`set the clipboard to` reports
                    // success and writes NOTHING"). Said here, at the one
                    // place every backend passes through.
                    Some(Err(format!(
                        "clipboard_seed {kind} {arg}: there is no file at {resolved}"
                    )))
                } else {
                    stage.clipboard_seed(kind, &resolved);
                    None
                }
            }
            Step::ExpectClipboard(kind, want) => Some(poll(|| {
                // POLLED like every other observation: the copy went out
                // on the apply pump, so the clipboard changes a moment
                // after the click that asked for it.
                let got = stage.clipboard_read(kind);
                if got == *want {
                    Ok(got)
                } else {
                    Err(format!(
                        "the clipboard's {kind} reads {got:?}, wanted {want:?}"
                    ))
                }
            })),
            Step::FileChoose(name) => {
                // An action, silent like click — EXCEPT that the row must be
                // THERE: a name that matched nothing skips the selection while
                // the press goes ahead, and the chooser completes with
                // whatever was already selected (docs/traps.md, "Pressing Open
                // with nothing selected still returns a file"). Checked here,
                // so no backend checks its own work.
                match name {
                    Some(want) => match traced_file_dialog_state("file_choose", &stage) {
                        Some((_, rows)) if rows.iter().any(|r| r == want) => {
                            vtrace::note(
                                "file_choose",
                                format_args!("-> stage.choose_file(Some({want:?}))"),
                            );
                            stage.choose_file(Some(want));
                            vtrace::note("file_choose", format_args!("<- stage.choose_file"));
                            // AND THE DIALOG MUST BE GONE. A press that
                            // lands before the dialog is interactive is
                            // swallowed with no error anywhere, so the leg
                            // fails three steps later on an assertion
                            // about the GUEST. Measured on Windows, where
                            // it passed once and flaked on the next run.
                            match poll_named("file_choose", || match stage.file_dialog_state() {
                                None => Ok(String::new()),
                                Some((_, rows)) => Err(format!(
                                    "file_choose {want:?}: the dialog is still up \
                                     (listing {rows:?}) — the press was swallowed, \
                                     which a backend cannot tell you because \
                                     nothing returns an error for it"
                                )),
                            }) {
                                Ok(_) => None,
                                Err(why) => Some(Err(why)),
                            }
                        }
                        Some((_, rows)) => {
                            // DISMISS IT ANYWAY: refusing alone leaves
                            // the picker up, the next show trips the
                            // one-per-process guard, and the abort takes
                            // the failure list with it, so the run dies
                            // naming the wrong cause.
                            vtrace::note(
                                "file_choose",
                                format_args!(
                                    "-> stage.choose_file(None) (cancelling: {want:?} is \
                                     not among {rows:?})"
                                ),
                            );
                            stage.choose_file(None);
                            Some(Err(format!(
                                "file_choose {want:?}: the dialog lists {rows:?} — \
                                 selecting nothing and pressing Open anyway returns \
                                 a file, so this would pick the wrong one silently"
                            )))
                        }
                        None => Some(Err(format!(
                            "file_choose {want:?}: no file dialog is live"
                        ))),
                    },
                    None => {
                        vtrace::note("file_choose", format_args!("-> stage.choose_file(None)"));
                        stage.choose_file(None);
                        vtrace::note("file_choose", format_args!("<- stage.choose_file"));
                        // Cancel has the same postcondition: the dialog
                        // is gone, or the press did not take.
                        match poll_named("file_choose", || match stage.file_dialog_state() {
                            None => Ok(String::new()),
                            Some((_, rows)) => Err(format!(
                                "file_choose cancel: the dialog is still up \
                                 (listing {rows:?}) — the press was swallowed"
                            )),
                        }) {
                            Ok(_) => None,
                            Err(why) => Some(Err(why)),
                        }
                    }
                }
            }
            Step::FileDialogName(name) => {
                // An action, silent like click — EXCEPT that the dialog
                // must BE there: typing into a panel that has not
                // presented yet does nothing at all, and the leg would
                // then save under the SUGGESTED name with every byte
                // assertion still passing. The file_choose rule, one
                // dialog over.
                match traced_save_dialog_state("file_dialog_name", &stage) {
                    // THE NAME THE PANEL ALREADY CARRIED is what tells
                    // "we set it and it took" from "we set it and the
                    // panel saved under its suggestion".
                    Some((dir, was)) => {
                        vtrace::note(
                            "file_dialog_name",
                            format_args!(
                                "-> stage.set_save_name {name:?} (the panel at {dir:?} \
                                 already names {was:?})"
                            ),
                        );
                        stage.set_save_name(name);
                        vtrace::note("file_dialog_name", format_args!("<- stage.set_save_name"));
                        None
                    }
                    None => Some(Err(format!(
                        "file_dialog_name {name:?}: no save dialog is live"
                    ))),
                }
            }
            Step::FileSave(save) => {
                // The picker's postcondition, verbatim: a press that
                // lands before the dialog is interactive is swallowed with
                // no error anywhere, and the leg then fails three steps
                // later on an assertion about the GUEST.
                if traced_save_dialog_state("file_save", &stage).is_none() {
                    Some(Err("file_save: no save dialog is live".to_string()))
                } else {
                    vtrace::note("file_save", format_args!("-> stage.confirm_save({save})"));
                    stage.confirm_save(*save);
                    vtrace::note("file_save", format_args!("<- stage.confirm_save"));
                    match poll_named("file_save", || match stage.save_dialog_state() {
                        None => Ok(String::new()),
                        Some((_, name)) => Err(format!(
                            "file_save: the dialog is still up (naming {name:?}) — the \
                             press was swallowed, which a backend cannot tell you \
                             because nothing returns an error for it"
                        )),
                    }) {
                        Ok(_) => None,
                        Err(why) => Some(Err(why)),
                    }
                }
            }
            Step::ExpectSaveDialog(dir, name) => {
                Some(poll(|| match stage.save_dialog_state() {
                    Some((where_, got)) => {
                        // Expanded like the picker's: an unexpanded
                        // expectation reads as a broken dialog rather than
                        // a broken script.
                        let dir = expand_path(dir);
                        if dir.contains('$') {
                            return Err(format!(
                                "expect_save_dialog {dir}: unexpanded substitution — \
                                 only $TMP and $PID exist"
                            ));
                        }
                        if !where_.ends_with(dir.as_str()) {
                            return Err(format!("save dialog showing {where_:?}, wanted {dir:?}"));
                        }
                        if &got != name {
                            return Err(format!(
                                "save dialog names {got:?}, wanted {name:?}"
                            ));
                        }
                        Ok(format!("save dialog {dir:?} {name:?}"))
                    }
                    None => Err("no save dialog live".to_string()),
                }))
            }
            Step::ExpectFileDialog(dir, names) => Some(poll(|| match stage.file_dialog_state() {
                Some((where_, rows)) => {
                    let Some(dir) = dir else {
                        return Ok("file dialog live".to_string());
                    };
                    // Expanded like the goto's argument, so a scene names
                    // the same directory both places and the pid stays out
                    // of the script.
                    let dir = expand_path(dir);
                    // A LEFTOVER $ means the expansion did not happen,
                    // which is the WORST shape of this bug: the picker is
                    // aimed correctly, shows the right directory, and the
                    // comparison fails against a literal "$PID" — which
                    // reads as a broken picker.
                    if dir.contains('$') {
                        return Err(format!(
                            "expect_file_dialog {dir}: unexpanded substitution — \
                             only $TMP and $PID exist"
                        ));
                    }
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
                // A SCROLL CONTAINER OR A TABLE (docs/tables-plan.md,
                // ruled 2026-08-29): on a table these three read the
                // COLUMNS' axis, so the target's kind decides the axis and
                // no verb needs an axis word.
                if !matches!(t.kind, TargetKind::Scroll | TargetKind::Column) {
                    Some(Err(format!("{t:?} is neither a scroll target nor a table")))
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
                // The target kind picks the observation, and nothing else
                // reads at all: routing another kind to read_label would
                // index the LABELS registry with a foreign target and
                // silently read a different widget.
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
                // registry (or vice versa) would silently read a DIFFERENT
                // widget, the false-verdict class.
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
            Step::ExpectColumns(t, want) => {
                if !matches!(t.kind, TargetKind::Column) {
                    Some(Err(format!("{t:?} is not a table container target")))
                } else {
                    Some(poll(|| {
                        let got = stage.columns_presented(*t);
                        if got == *want {
                            Ok(got)
                        } else {
                            Err(format!("{t:?} presents {got:?}, wanted {want:?}"))
                        }
                    }))
                }
            }
            Step::ExpectRows(t, want) => {
                if !matches!(t.kind, TargetKind::Column) {
                    Some(Err(format!("{t:?} is not a table container target")))
                } else {
                    Some(poll(|| {
                        let got = stage.row_cells(*t);
                        if got == *want {
                            Ok(got)
                        } else {
                            Err(format!("{t:?} rows {got:?}, wanted {want:?}"))
                        }
                    }))
                }
            }
            Step::ExpectColumnEdges(t, want) => {
                if !matches!(t.kind, TargetKind::Column) {
                    Some(Err(format!("{t:?} is not a table container target")))
                } else {
                    Some(poll(|| {
                        let off = stage.column_edges(*t, *want);
                        if off.is_empty() {
                            Ok(format!("{} column edges {want}", target_spec(t)))
                        } else {
                            Err(format!("{} misaligned ({off})", target_spec(t)))
                        }
                    }))
                }
            }
            Step::ExpectWindow(t, first, total) => {
                if !matches!(t.kind, TargetKind::Column | TargetKind::Row) {
                    Some(Err(format!("{t:?} is not a collection container target")))
                } else {
                    let want = format!("{first} {total}");
                    Some(poll(|| {
                        let got = stage.window_band(*t);
                        if got == want {
                            Ok(format!("{} window {want}", target_spec(t)))
                        } else {
                            Err(format!("{} windows {got:?}, wanted {want:?}", target_spec(t)))
                        }
                    }))
                }
            }
            Step::ScrollToRow(t, key) => {
                // An action, silent like click — the expect_window after
                // it is the observable — but a backend that cannot do it
                // says so HERE, where the sentence still names the verb.
                let off = stage.scroll_to_row(*t, key);
                if off.is_empty() {
                    None
                } else {
                    Some(Err(format!("scroll_to_row {key:?}: {off}")))
                }
            }
            Step::Drag(source, destination, reorder) => {
                // An action; the guest's own writes after `dropped` and
                // `drag_ended` are the observables. A refused drop is not
                // a failure here: the source learns `none` through
                // drag_ended and the scene reads that.
                let off = stage.drag(*source, *destination, *reorder);
                if off.is_empty() {
                    None
                } else {
                    Some(Err(format!("drag: {off}")))
                }
            }
            Step::DragFile(path, destination) => {
                let off = stage.drag_file(&expand_path(path), *destination);
                if off.is_empty() {
                    None
                } else {
                    Some(Err(format!("drag_file: {off}")))
                }
            }
            Step::HeaderClick(t, column) => {
                stage.header_click(*t, *column);
                None
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
            Step::ExpectInset { target, units } => Some(poll(|| {
                let (got, subject) = match target {
                    Some(t) => (stage.container_inset(*t), target_spec(t)),
                    None => (stage.inset(), String::new()),
                };
                let want = format!("{units}");
                let label = if subject.is_empty() {
                    "inset".to_string()
                } else {
                    format!("inset {subject}")
                };
                if got == want {
                    Ok(format!("{label} {want}"))
                } else {
                    Err(format!("{label} {got}, wanted {want}"))
                }
            })),
            Step::ExpectTypeface(want) => Some(poll(|| {
                let got = stage.typeface();
                if got == *want {
                    Ok(format!("typeface {want}"))
                } else {
                    // THE RESOLVED FAMILY IS THE FAILURE TEXT: it is the
                    // whole diagnosis — "Helvetica" says a CoreText
                    // fallback swallowed the request, the platform's own
                    // default says the presence gate refused it, and the
                    // request echoed back says the read is wired to the
                    // model instead of the views.
                    Err(format!("typeface {got}, wanted {want}"))
                }
            })),
            Step::ExpectAppIcon(want) => Some(poll(|| {
                let got = stage.app_icon();
                if got == *want {
                    Ok(format!("app icon {want}"))
                } else {
                    // WHAT THE PLATFORM IS HOLDING IS THE DIAGNOSIS: four
                    // greys say a monochrome default is being drawn, a
                    // sentence about a class icon says the window never
                    // got one of its own, and the declared colours in a
                    // different order say a lowering flipped an axis.
                    Err(format!("app icon {got}, wanted {want}"))
                }
            })),
            Step::ExpectDrawingHash(target, want) => Some(poll(|| {
                let got = stage.canvas_probe(*target);
                // The probe carries the hash AND the two legible facts;
                // this verb compares the hash and PRINTS THE REST on
                // failure, because a hash alone tells the next reader
                // nothing (invariant 3, §7.1).
                let (hash, measured) = got.split_once(' ').unwrap_or((got.as_str(), ""));
                if hash == want {
                    Ok(format!("drawing hash {want}"))
                } else {
                    Err(format!("drawing hash {hash} ({measured}), wanted {want}"))
                }
            })),
            Step::ExpectDrawing(target, want) => Some(poll(|| {
                let got = stage.canvas_probe(*target);
                let measured = got.split_once(' ').map(|(_, m)| m).unwrap_or("").to_owned();
                if measured == *want {
                    Ok(format!("drawing {want}"))
                } else {
                    Err(format!("drawing {measured}, wanted {want}"))
                }
            })),
            Step::ExpectInk(target, points, want) => Some(poll(|| {
                let got = stage.canvas_ink(*target, points);
                // THE OBSERVATION IS THE WANTED TEXT, not what was read:
                // inside the tolerance the platforms legitimately answer
                // different bytes, and the verdict is byte-compared across
                // all of them (invariant 6).
                if ink_matches(&got, want) {
                    Ok(format!("ink {want}"))
                } else {
                    // WHAT THE SURFACE IS HOLDING IS THE DIAGNOSIS: the
                    // declared colours with two channels swapped say the
                    // blit reached a BGRA object, all-transparent says
                    // nothing arrived, and the colours in the wrong order
                    // say it landed flipped.
                    Err(format!("ink {got} at {points}, wanted {want}"))
                }
            })),
            Step::ExpectRaster(target, want) => Some(poll(|| {
                let got = stage.canvas_raster_shape(*target);
                if got == *want {
                    Ok(format!("raster {want}"))
                } else {
                    // THE THREE NUMBERS ARE THE DIAGNOSIS: "viewbox"
                    // where "track" was wanted is the stretch defect
                    // itself, "no track reported" is a backend that never
                    // sent the geometry, and the `neither` form names all
                    // three sizes.
                    Err(format!("raster {got}, wanted {want}"))
                }
            })),
            Step::Frame(n) => {
                for _ in 0..*n {
                    stage.frame();
                }
                Some(Ok(format!("frame {n}")))
            }
            Step::ExpectRootFills => Some(poll(|| {
                // Empty means fills; anything else is the platform's own
                // description of the hug, for the failure text alone — the
                // pass observation is the byte-identical "root fills".
                let hug = stage.root_fills();
                if hug.is_empty() {
                    Ok("root fills".to_owned())
                } else {
                    Err(format!("root hugs ({hug})"))
                }
            })),
            Step::ExpectTitle(window, want) => {
                // The REAL materialized title (the title bar / task
                // label), never the scene model's copy. The pass
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
            Step::ExpectSectionsPresentation(window, want) => {
                let id = window.unwrap_or(0);
                let prefix = match window {
                    Some(n) => format!("window#{n} "),
                    None => String::new(),
                };
                Some(poll(|| {
                    let got = stage.sections_presentation(id);
                    if got == *want {
                        Ok(format!("{prefix}sections {want}"))
                    } else {
                        Err(format!("{prefix}sections presentation {got}, wanted {want}"))
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
                    } else if !gw.is_finite() || !gh.is_finite() {
                        // NOT A SIZE, AND IT MUST NOT PRINT AS ONE: a backend
                        // that could not read the window answers NaN (GTK and
                        // WinUI both), and `NaN as i64` is 0, so the sentence
                        // would read "window 0x0" and send the reader after a
                        // zero-sized window that does not exist.
                        Err(format!(
                            "{prefix}window size unreadable, wanted {}x{}",
                            *w as i64, *h as i64
                        ))
                    } else {
                        Err(format!(
                            "{prefix}window {}x{}, wanted {}x{}",
                            gw as i64, gh as i64, *w as i64, *h as i64
                        ))
                    }
                }))
            }
            Step::ExpectDirty(window, want) => {
                // The platform's REAL unsaved-work affordance, read where
                // that platform publishes it (Stage::window_dirty carries
                // the table) — never the scene model's copy where chrome
                // exists. The pass observation is byte-identical on every
                // backend; an explicit window target prefixes it.
                let id = window.unwrap_or(0);
                let prefix = match window {
                    Some(n) => format!("window#{n} "),
                    None => String::new(),
                };
                Some(poll(|| {
                    let got = stage.window_dirty(id);
                    if got == *want {
                        Ok(format!("{prefix}dirty {want}"))
                    } else {
                        Err(format!("{prefix}dirty {got}, wanted {want}"))
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
                // A SCROLL CONTAINER OR A TABLE (docs/tables-plan.md,
                // ruled 2026-08-29): on a table these three read the
                // COLUMNS' axis, so the target's kind decides the axis and
                // no verb needs an axis word.
                if !matches!(t.kind, TargetKind::Scroll | TargetKind::Column) {
                    Some(Err(format!("{t:?} is neither a scroll target nor a table")))
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
                // A SCROLL CONTAINER OR A TABLE (docs/tables-plan.md,
                // ruled 2026-08-29): on a table these three read the
                // COLUMNS' axis, so the target's kind decides the axis and
                // no verb needs an axis word.
                if !matches!(t.kind, TargetKind::Scroll | TargetKind::Column) {
                    Some(Err(format!("{t:?} is neither a scroll target nor a table")))
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
                // ONE VERB, TWO SUBJECTS: a CONTAINER's children must
                // span its content box, a WIDGET must span the track its
                // container gave it. Separate blind spots — both keep
                // every share exactly right while leaving leftover
                // unconsumed.
                let container = matches!(t.kind, TargetKind::Column | TargetKind::Row);
                Some(poll(|| {
                    let slack = if container {
                        stage.container_fills(*t)
                    } else {
                        stage.widget_fills(*t)
                    };
                    if slack.is_empty() {
                        Ok(format!("{} fills", target_spec(t)))
                    } else if container {
                        Err(format!("{} leaves leftover ({slack})", target_spec(t)))
                    } else {
                        Err(format!("{} is short of its track ({slack})", target_spec(t)))
                    }
                }))
            }
            Step::ExpectBreadth(t) => {
                // The cross-axis twin of expect_fills' widget half: the
                // widget's breadth against its container's content box.
                // A container target is refused — its children's breadth
                // is expect_aligned's question.
                if matches!(t.kind, TargetKind::Column | TargetKind::Row) {
                    Some(Err(format!("{t:?} is a container; expect_breadth reads a widget")))
                } else {
                    Some(poll(|| {
                        let short = stage.widget_spans_breadth(*t);
                        if short.is_empty() {
                            Ok(format!("{} spans its breadth", target_spec(t)))
                        } else {
                            Err(format!("{} is short of its breadth ({short})", target_spec(t)))
                        }
                    }))
                }
            }
            Step::ExpectAxis(t, want) => {
                if !matches!(t.kind, TargetKind::Column | TargetKind::Row) {
                    Some(Err(format!("{t:?} is not a container target")))
                } else {
                    Some(poll(|| {
                        let got = stage.container_axis(*t);
                        if got == *want {
                            Ok(format!("{} axis {got}", target_spec(t)))
                        } else {
                            Err(format!(
                                "{} axis {got:?}, wanted {want:?}",
                                target_spec(t)
                            ))
                        }
                    }))
                }
            }
            Step::ExpectFolded(child, table) => {
                Some(poll(|| {
                    let got = stage.fold_state(*child, *table);
                    match table {
                        Some(table) => {
                            if got == "folded" {
                                Ok(format!(
                                    "{} folded into {}",
                                    target_spec(child),
                                    target_spec(table)
                                ))
                            } else {
                                Err(format!(
                                    "{} fold reads {got:?}, wanted it folded into {}",
                                    target_spec(child),
                                    target_spec(table)
                                ))
                            }
                        }
                        None => {
                            if got == "not folded" {
                                Ok(format!("{} not folded", target_spec(child)))
                            } else {
                                Err(format!(
                                    "{} fold reads {got:?}, wanted it not folded",
                                    target_spec(child)
                                ))
                            }
                        }
                    }
                }))
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
            Step::ExpectFocused(t) => Some(poll_named("expect_focused", || {
                if stage.is_focused(*t) {
                    Ok(format!("{t:?} focused"))
                } else {
                    Err(format!("{t:?} does not hold focus"))
                }
            })),
            Step::MenuActivate(path) => {
                // An action, silent like click: the fold's reaction (or
                // the next expect_menu) is the observable. Where the path
                // resolves is the stage's own presentation state.
                stage.menu_activate(path);
                None
            }
            Step::ContextOpen(t) => {
                // v1 rejects context menus on editable text (their native
                // menus are dress — scene.rs refuses the attach), so
                // driving the gesture there would probe a menu that cannot
                // exist.
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
            Step::ExpectHighlights(target, want) => Some(poll(|| {
                let got = stage.highlights(*target);
                if got == *want {
                    Ok(format!("highlights {want:?}"))
                } else {
                    Err(format!("highlights {got:?}, wanted {want:?}"))
                }
            })),
            Step::ExpectSelection(target, want) => Some(poll(|| {
                let got = stage.selection(*target);
                if got == *want {
                    Ok(format!("selection {want:?}"))
                } else {
                    Err(format!("selection {got:?}, wanted {want:?}"))
                }
            })),
            Step::ExpectRevealed(target, range, want) => Some(poll(|| {
                let got = stage.revealed(*target, *range);
                if got == *want {
                    Ok(format!("{}:{} {want}", range.start, range.stop))
                } else {
                    Err(format!(
                        "{}:{} is {got}, wanted {want}",
                        range.start, range.stop
                    ))
                }
            })),
            Step::Compose(target, text) => {
                // An action, silent like type: what the composition does
                // to the next step is the observable.
                stage.compose(*target, text);
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
                    // The bare form, lane-INDEPENDENT by construction: a
                    // shared scene compares this byte-for-byte on every
                    // platform, so it cannot echo a reading that
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
            Step::ExpectPanes(want) => Some(poll(|| {
                let Some(want) = want else {
                    // The bare form: expect_split's own asymmetric
                    // invariant, on the ARM stamp rather than the position
                    // list — an occupied pane beside an EMPTY slot is one
                    // visible position and still correct
                    // (docs/multicolumn-plan.md D1/D4).
                    let stamped = stage.split_presentation();
                    let entries = stage.entry_count(0);
                    return if split_presentation_fits(&stamped, entries) {
                        Ok("panes fit".to_owned())
                    } else {
                        Err(format!(
                            "presentation {stamped}: a regular window must not show \
                             one pane while its stack holds two"
                        ))
                    };
                };
                let got = stage.panes_reading();
                if got == *want {
                    Ok(format!("panes {got}"))
                } else {
                    Err(format!("panes {got}, wanted {want}"))
                }
            })),
            Step::ExpectMenuPresentation(want) => Some(poll(|| {
                let got = stage.menu_presentation();
                let Some(want) = want else {
                    // The bare form: the observation string must be
                    // lane-INDEPENDENT, since a shared scene compares it
                    // byte-for-byte across every platform.
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
            Step::ExpectToolbar => Some(poll(|| {
                let got = stage.toolbar_chrome();
                // LANE-INDEPENDENT VERDICT, the bare expect_split rule: a
                // shared scene compares observations byte-for-byte across
                // every platform, so the pass cannot echo a reading (k
                // differs per lane). The MEASURED numbers ride the
                // failure.
                match toolbar_chrome_fits(&got) {
                    Ok(()) => Ok("toolbar".to_owned()),
                    Err(why) => Err(why),
                }
            })),
            Step::ExpectToolbarItem(label, want) => Some(poll(|| {
                let got = stage.toolbar_item(label, want);
                if got == *want {
                    Ok(format!("toolbar item {label} {want}"))
                } else {
                    // The measured answer rides the failure: it is what
                    // tells a wrong glyph from a button that is not in
                    // the chrome at all.
                    Err(format!("toolbar item {label} reads {got:?}, wanted {want:?}"))
                }
            })),
            Step::ExpectMenuSymbol(path, want) => Some(poll(|| {
                let got = stage.menu_symbol(path);
                if got == *want {
                    // Byte-identical on every backend: the path in its
                    // quoted spelling, then the semantic name.
                    Ok(format!("menu {path:?} symbol {want:?}"))
                } else {
                    // The MEASURED answer rides the failure, the only
                    // thing that tells "wrong concept" from "no icon at
                    // all" from "item not there yet".
                    Err(format!("menu {path:?} symbol {got:?}, wanted {want:?}"))
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
            Some(Err(e)) => {
                // PRINTED THE MOMENT IT IS FINAL: the verdict below is the
                // ONLY place `failures` is named and it needs the run to
                // reach the end, so a scene that fails and then ABORTS takes
                // the whole list with it. Measured 2026-08-10: the editor
                // scene's first linux run failed six assertions and aborted
                // on the alert guard, and diagnosing it meant noticing that
                // six steps took EXACTLY 15.0s (POLL_DEADLINE).
                if let Some((log, _)) = log {
                    log(&format!("KAYA_HARNESS: step-failed {e}"));
                }
                failures.push(e);
            }
            None => {}
        }
        // AND CHECKED AGAIN HERE, because the check at the top of the loop
        // races the backend. THE IN-FLIGHT ATTEMPT IS RETRACTED: `poll` ends
        // the moment a fault latches, so the failure just recorded is a read
        // taken BEFORE its deadline. Measured 2026-08-21 on the windows
        // lane, where the verdict led with `label#0 reads "0 matches"` and
        // named the real cause second (docs/deferred.md).
        if let Some(sentence) = crate::fault::latched() {
            failures.truncate(failures_before);
            if let Some((log, _)) = log {
                log(&format!("KAYA_HARNESS: step-failed {sentence}"));
            }
            failures.push(sentence);
            faulted = true;
            break;
        }
    }
    // The LAST step can fault too, and a fault must never leave a green
    // verdict behind it.
    if !faulted {
        if let Some(sentence) = crate::fault::latched() {
            if let Some((log, _)) = log {
                log(&format!("KAYA_HARNESS: step-failed {sentence}"));
            }
            failures.push(sentence);
        }
    }
    record_linger();
    let (code, verdict) = if failures.is_empty() {
        (0, format!("KAYA_SELFTEST: OK ({})", observed.join(", ")))
    } else {
        (1, format!("KAYA_SELFTEST: FAILED ({})", failures.join("; ")))
    };
    // FAILURE ONLY, and BEFORE the publish: after it the watchdog may
    // end the process at any moment (crates/kaya/src/vtrace.rs).
    if code != 0 {
        vtrace::dump(&format!("the verdict failed: {verdict}"));
    }
    // EXIT_GRACE covers `finish` itself: it prints the verdict and then
    // hops to the UI thread for the exit, and that hop wedges with the
    // rest (the linux lane's N=6000, verdict at 103.63s and no exit).
    watch.published(code);
    stage.finish(code, &verdict);
    watch.clear();
    code
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
        TargetKind::Canvas => "canvas",
    };
    if let Some(id) = t.id {
        t.keys.map_or_else(
            || format!("{kind}@{id}"),
            |keys| format!("{kind}@{id}[{keys}]"),
        )
    } else if t.index < 0 {
        format!("{kind}#last")
    } else {
        format!("{kind}#{}", t.index)
    }
}

fn table_tag_identity(tag: &[u8]) -> Option<(u64, Vec<Option<&str>>)> {
    if tag.len() < 16 {
        return None;
    }
    let node = u64::from_le_bytes(tag[0..8].try_into().ok()?);
    let count = u32::from_le_bytes(tag[8..12].try_into().ok()?) as usize;
    if count == 0 || count > (tag.len() - 16) / 8 {
        return None;
    }
    let mut at = 16usize;
    let mut path = Vec::new();
    for _ in 0..count {
        let ty = u32::from_le_bytes(tag.get(at..at + 4)?.try_into().ok()?);
        let len = u32::from_le_bytes(tag.get(at + 4..at + 8)?.try_into().ok()?) as usize;
        let payload_at = at.checked_add(8)?;
        let payload = tag.get(payload_at..payload_at.checked_add(len)?)?;
        path.push(match ty {
            crate::wire::VALUE_STR => Some(std::str::from_utf8(payload).ok()?),
            crate::wire::VALUE_I64 if len == 8 => None,
            _ => return None,
        });
        let padded = len.checked_add(7)? & !7;
        at = payload_at.checked_add(padded)?;
    }
    (at == tag.len()).then_some((node, path))
}

pub(crate) fn table_tag_node(tag: &[u8]) -> Option<u64> {
    table_tag_identity(tag).map(|(node, _)| node)
}

/// `kind@id[key.path]` is string-key-only (docs/tables-plan.md).
pub(crate) fn table_tag_matches_keys(tag: &[u8], node: u64, keys: &str) -> bool {
    let Some((got_node, path)) = table_tag_identity(tag) else {
        return false;
    };
    let wanted: Vec<_> = keys.split('.').collect();
    got_node == node
        && path.len() == wanted.len()
        && path.iter().zip(wanted).all(|(got, want)| *got == Some(want))
}

/// Format child main-axis extents as whole-percentage shares of their
/// sum, joined with `,` — the one implementation every backend's
/// `child_shares` formats through, because the ROUNDING has to be
/// identical everywhere and expect_shares compares byte-for-byte. An
/// empty container, or one whose children are all zero-extent, reports
/// the empty string rather than dividing by zero.
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

/// The observation contract: every expect is a BOUNDED RETRY, polled
/// until it holds or the deadline passes. The FIRST expect of a script
/// doubles as the scene-ready wait — scripts open with an expect of
/// initial state (check-steps holds the line) — so reads must be TOTAL:
/// a missing target is a retryable non-match, never a panic.
pub const POLL_INTERVAL: Duration = Duration::from_millis(20);
// 15, NOT 5, and the number is measured: under the five-lane matrix a
// loaded VM answered a first click in more than five seconds and a leg
// that was 145/145 solo went red (entry_go, 2026-08-03). A pass returns
// the moment it matches, so the width costs a green run nothing.
pub const POLL_DEADLINE: Duration = Duration::from_secs(15);

/// THE CEILING ON ONE STEP, HOP INCLUDED — the cover the deadline above
/// cannot give, because it is read only after a step RETURNS and every step
/// blocks in a hop to the platform's UI thread. A saturated app answers no
/// step, so the run prints NOTHING until something outside kills it
/// (measured on four platforms 2026-08-24,
/// docs/measurements/choke-*-2026-08-24.txt). 60s, both bounds measured:
/// an attempt entered inside the retry deadline may finish well past it
/// (choke-macos note 3 — entered at 4.9s, passing at 9.6s), and validate-mac
/// kills a leg at `timeout 120`. tools/check-harness-ceiling.py censuses the
/// default in all three harnesses.
pub const STEP_CEILING: Duration = Duration::from_secs(60);

/// The other half: once a verdict is published the process leaves within
/// this whether or not the platform's exit path runs. `finish` prints the
/// verdict and then hops to the same UI thread to ask for the exit —
/// measured on the linux lane 2026-08-24, N=6000: "KAYA_SELFTEST: OK
/// (77987.99)" at 103.63s and no exit ever, killed from outside at the
/// bench's 120s cap.
pub const EXIT_GRACE: Duration = Duration::from_secs(3);

/// The exit every fire path leaves by. On Windows `std::process::exit` is
/// `ExitProcess`, which runs LOADER SHUTDOWN, and a wedged dialog/COM thread
/// holds EXIT ITSELF hostage past the grace (measured 2026-08-27: verdict at
/// +24s, grace at +27s, process gone at +64s — docs/traps.md). UNIX IS
/// `_exit` TOO (2026-09-01): a Node host's atexit handlers are V8's teardown
/// while the worker is still executing the app, and two x11 legs printed a
/// verdict then died of SIGSEGV (docs/traps.md, the Node exit entry).
pub(crate) fn harness_exit(code: i32) -> ! {
    crate::exit_hard(code)
}


fn step_ceiling() -> Duration {
    match std::env::var("KAYA_STEP_CEILING_MS").ok().and_then(|v| v.parse::<u64>().ok()) {
        Some(ms) if ms > 0 => Duration::from_millis(ms),
        _ => STEP_CEILING,
    }
}

/// What the watchdog below is waiting on, and since when.
enum Watched {
    /// A step the harness thread entered and has not come back from.
    Step { text: String, entered: Instant },
    /// A verdict already published, waiting on the platform's exit.
    Exit { code: i32, published: Instant },
}

/// The thread that makes those two ceilings real. NOT the harness
/// thread: the whole failure class is the harness thread stuck inside a
/// call that never returns, so the only thread that can report it is one
/// that never enters a step. (crate::stall is the other watchdog and
/// watches the APP thread's unclaimed occurrences.)
struct StepWatchdog {
    watched: std::sync::Arc<std::sync::Mutex<Option<Watched>>>,
}

impl StepWatchdog {
    fn start(ceiling: Duration) -> Self {
        let watched = std::sync::Arc::new(std::sync::Mutex::new(None));
        let weak = std::sync::Arc::downgrade(&watched);
        std::thread::spawn(move || {
            // The run's own end drops the last strong reference, so the
            // watchdog cannot outlive the run it watches.
            while let Some(watched) = weak.upgrade() {
                let now = Instant::now();
                let fire = match &*watched.lock().unwrap() {
                    Some(Watched::Step { text, entered }) if now >= *entered + ceiling => {
                        Some((1, Some(wedge_verdict(text, now - *entered))))
                    }
                    Some(Watched::Exit { code, published }) if now >= *published + EXIT_GRACE => {
                        Some((*code, None))
                    }
                    _ => None,
                };
                drop(watched);
                if let Some((code, verdict)) = fire {
                    match verdict {
                        Some(text) => {
                            // THE WEDGE IS WHAT THE TRACE IS FOR: nobody
                            // else knows what the verb was doing, and the
                            // harness thread is still inside it
                            // (crates/kaya/src/vtrace.rs).
                            crate::vtrace::dump("the step ceiling fired: no verdict");
                            eprintln!("{text}")
                        }
                        // NOT a second verdict: the leg's own is
                        // already out, and overwriting it would lose
                        // the answer the run reached.
                        None => eprintln!(
                            "KAYA_HARNESS: the verdict is published and the platform's exit \
                             path has not run {}s later — leaving under the verdict's own \
                             code (the harness exit grace)",
                            EXIT_GRACE.as_secs()
                        ),
                    }
                    harness_exit(code);
                }
                std::thread::sleep(POLL_INTERVAL);
            }
        });
        StepWatchdog { watched }
    }

    fn enter(&self, text: String) {
        *self.watched.lock().unwrap() = Some(Watched::Step { text, entered: Instant::now() });
    }

    fn published(&self, code: i32) {
        *self.watched.lock().unwrap() = Some(Watched::Exit { code, published: Instant::now() });
    }

    fn clear(&self) {
        *self.watched.lock().unwrap() = None;
    }
}

/// The sentence a wedged step ends its run with. It prints only what it
/// measured — which step was entered, how long ago, and that nothing has come
/// back — and says out loud that it cannot tell a wedged UI thread from a slow
/// one. ONE SENTENCE, THREE HARNESSES: KayaSwiftUI.swift's `kayaWedgeVerdict`
/// and KayaCompose.kt's `wedgeVerdict` are the same text.
fn wedge_verdict(step: &str, waited: Duration) -> String {
    format!(
        "KAYA_SELFTEST: FAILED (no verdict — the harness entered step {step} {:.1}s ago \
         and has not come back from it. A step blocks in its hop to the platform's UI \
         thread, so nothing answered from there; a wedged UI thread and a merely slow \
         one look the same from here and this does not claim to tell them apart. Ended \
         by the harness step ceiling, which is the cover a step's own retry deadline \
         cannot give: that one is read only after a step returns.)",
        waited.as_secs_f64()
    )
}

/// `$TMP` and `$PID` in a scene path. THE THIRD SITE, with
/// KayaSwiftUI.swift's and KayaCompose.kt's copies — check-verbs polices all
/// three, and an interpreter that leaves a token alone uses it as a LITERAL
/// path segment. `$TMP` is `std::env::temp_dir`, which is what a Rust guest's
/// own file API returns. WHOLE NAMES, not prefixes, or `$TMP` eats the front
/// of `$TMPDIR` (docs/traps.md).
fn expand_path(path: &str) -> String {
    let tmp = std::env::temp_dir();
    let tmp = tmp.to_string_lossy();
    let pid = std::process::id().to_string();
    let mut out = String::with_capacity(path.len());
    let mut rest = path;
    while let Some(at) = rest.find('$') {
        out.push_str(&rest[..at]);
        let after = &rest[at + 1..];
        let end = after
            .find(|c: char| !c.is_ascii_uppercase() && c != '_')
            .unwrap_or(after.len());
        match &after[..end] {
            // BOTH separators: Windows' temp_dir ends in a BACKSLASH, so
            // trimming only '/' left "…\\Temp\\" and the scene's own '/'
            // made "…\\Temp\\/kaya-picked-N", which
            // SHCreateItemFromParsingName rejects outright while POSIX
            // shrugs at "//" (docs/traps.md).
            "TMP" => out.push_str(tmp.trim_end_matches(['/', '\\'])),
            "PID" => out.push_str(&pid),
            other => {
                out.push('$');
                out.push_str(other);
            }
        }
        rest = &after[end..];
    }
    out.push_str(rest);
    // The SCENE writes POSIX separators, because tools/scenes/*.steps is
    // one file serving five platforms (CLAUDE.md, invariant 6); the
    // shell's parsing-name wants backslashes.
    #[cfg(windows)]
    let out = out.replace('/', "\\");
    out
}

#[cfg(test)]
mod expand_tests {
    use super::expand_path;

    #[test]
    fn whole_names_only() {
        // The prefix trap: $TMPDIR is not $TMP followed by DIR. An
        // unknown name survives INTACT so the caller's check can name
        // the token that is actually wrong.
        assert_eq!(expand_path("$TMPDIR/x"), "$TMPDIR/x");
        assert_eq!(expand_path("$NOPE"), "$NOPE");
        assert!(!expand_path("$TMP/a").contains('$'));
    }

    #[test]
    fn expands_mid_segment() {
        // $PID is not its own path segment — it is a suffix on one, which
        // a split-on-slash expander gets wrong.
        let got = expand_path("$TMP/kaya-picked-$PID");
        assert!(got.contains(&format!("kaya-picked-{}", std::process::id())));
        assert!(!got.contains('$'));
    }

    #[test]
    fn no_doubled_separator_after_tmp() {
        // The one that broke Windows: temp_dir ends in a separator
        // there, so a naive join produces "…\\Temp\\/name".
        let got = expand_path("$TMP/kaya-picked-1");
        assert!(!got.contains("//"), "{got}");
        assert!(!got.contains("\\/"), "{got}");
        assert!(got.ends_with("kaya-picked-1"), "{got}");
    }

    #[test]
    fn agrees_with_the_guest() {
        // The scene's premise: guest and harness are one process and
        // compute the same path with no runner involvement.
        assert!(expand_path("$TMP").starts_with(
            std::env::temp_dir().to_string_lossy().trim_end_matches('/')
        ));
    }
}

fn poll(eval: impl FnMut() -> Result<String, String>) -> Result<String, String> {
    poll_inner(None, eval)
}

/// `poll` with every ATTEMPT on the verb trace — only the last of them
/// survives anywhere else, in the failure sentence
/// (crates/kaya/src/vtrace.rs). ONE BODY with `poll`, so the retry
/// semantics cannot differ between a traced verb and an untraced one.
fn poll_named(
    verb: &'static str,
    eval: impl FnMut() -> Result<String, String>,
) -> Result<String, String> {
    poll_inner(Some(verb), eval)
}

fn poll_inner(
    verb: Option<&'static str>,
    mut eval: impl FnMut() -> Result<String, String>,
) -> Result<String, String> {
    let deadline = Instant::now() + POLL_DEADLINE;
    let mut tries = 0u32;
    loop {
        let outcome = eval();
        if let Some(verb) = verb {
            tries += 1;
            match &outcome {
                Ok(o) if o.is_empty() => vtrace::attempt(verb, tries, format_args!("<- ok")),
                Ok(o) => vtrace::attempt(verb, tries, format_args!("<- ok: {o}")),
                Err(e) => vtrace::attempt(verb, tries, format_args!("<- not yet: {e}")),
            }
        }
        // A LATCHED FAULT ENDS THE WAIT: nothing more will be applied,
        // so the rest of POLL_DEADLINE is dead time — the "six steps took
        // EXACTLY 15.0s" shape one layer down.
        if outcome.is_ok() || Instant::now() >= deadline || crate::fault::latched().is_some() {
            return outcome;
        }
        std::thread::sleep(POLL_INTERVAL);
    }
}

/// The picker's state, ON THE RECORD. "the picker listed six stale
/// siblings" is this family's exact failure face (docs/deferred.md's
/// iOS-sheets WATCH entry) and the read that saw it is discarded
/// everywhere else.
fn traced_file_dialog_state(
    verb: &'static str,
    stage: &impl Stage,
) -> Option<(String, Vec<String>)> {
    let state = stage.file_dialog_state();
    match &state {
        Some((where_, rows)) => vtrace::note(
            verb,
            format_args!("<- stage.file_dialog_state at {where_:?} listing {rows:?}"),
        ),
        None => vtrace::note(verb, format_args!("<- stage.file_dialog_state: none is live")),
    }
    state
}

/// Its save-panel half.
fn traced_save_dialog_state(verb: &'static str, stage: &impl Stage) -> Option<(String, String)> {
    let state = stage.save_dialog_state();
    match &state {
        Some((where_, name)) => vtrace::note(
            verb,
            format_args!("<- stage.save_dialog_state at {where_:?} naming {name:?}"),
        ),
        None => vtrace::note(verb, format_args!("<- stage.save_dialog_state: none is live")),
    }
    state
}

/// `expect_ink`'s probe points: `x,y` pairs in hundredths of the canvas's
/// own box (docs/canvas-plan.md §7.2). The BACKENDS parse this rather
/// than the runner, because each one samples in its own surface's
/// coordinates. An unparseable pair is dropped, and an empty answer is
/// what the backend reports as "no probe points".
pub fn probe_points(spec: &str) -> Vec<(f64, f64)> {
    spec.split_whitespace()
        .filter_map(|pair| {
            let (x, y) = pair.split_once(',')?;
            Some((x.trim().parse().ok()?, y.trim().parse().ok()?))
        })
        .collect()
}

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
        assert_eq!(steps[1], Step::Click(Target { kind: TargetKind::Button, index: -1, id: None, keys: None }));
        assert_eq!(
            steps[4],
            Step::SetText(Target { kind: TargetKind::Entry, index: 0, id: None, keys: None }, "a b".into())
        );
        assert!(parse("warp reality#0").is_err());
        assert_eq!(resolve(-1, 3), 2);
        assert_eq!(resolve(1, 3), 1);
        // The quoted-string escapes, byte-exact, including unknown ones
        // passing through verbatim. All three interpreters must match.
        assert_eq!(
            parse(r#"set_text textarea#0 "a\r\nb\nc\\d\qe""#).unwrap()[0],
            Step::SetText(
                Target { kind: TargetKind::Textarea, index: 0, id: None, keys: None },
                "a\r\nb\nc\\d\\qe".into()
            )
        );
        assert_eq!(
            parse("expect_shares column#1 \"25,75\"").unwrap()[0],
            Step::ExpectShares(
                Target { kind: TargetKind::Column, index: 1, id: None, keys: None },
                "25,75".into()
            )
        );
    }

    /// The runtime half of `targets_mut`'s drag arm (docs/traps.md: A
    /// Step's SECOND Target was never normalized).
    #[test]
    fn a_drag_normalizes_both_ends() {
        let mut step = parse("drag label@row[c] to label@row[a] before").unwrap()
            .pop()
            .unwrap();
        let named: Vec<(Option<&str>, Option<&str>)> =
            step.targets_mut().iter().map(|t| (t.id, t.keys)).collect();
        assert_eq!(
            named,
            vec![(Some("row"), Some("c")), (Some("row"), Some("a"))],
            "a drag's source AND destination must both be normalizable"
        );
    }

    /// The panes grammar and the two-pane derivation
    /// (docs/multicolumn-plan.md D4).
    #[test]
    fn panes_grammar_and_derivation() {
        for good in ["regular/0", "regular/0,1,2", "compact/2", "unknown/0"] {
            check_panes_reading(good).unwrap();
        }
        for bad in ["regular", "wide/0", "regular/a", "regular/2,1", "regular/1,1"] {
            check_panes_reading(bad).unwrap_err();
        }
        assert_eq!(parse("expect_panes").unwrap()[0], Step::ExpectPanes(None));
        assert_eq!(
            parse("expect_panes \"regular/0,1\"").unwrap()[0],
            Step::ExpectPanes(Some("regular/0,1".into()))
        );
        parse("expect_panes \"regular/1,0\"").unwrap_err();
        assert_eq!(panes_positions("split", 0), "0");
        assert_eq!(panes_positions("split", 2), "0,2");
        assert_eq!(panes_positions("stacked", 0), "0");
        assert_eq!(panes_positions("stacked", 2), "2");
    }

    /// THE SAVE VERBS' GRAMMAR, and the refusals that matter — each a
    /// mistake that would otherwise be SILENT: a name with a space
    /// asserts against its first word, and `file_save save` would parse
    /// as something and press nothing.
    #[test]
    fn save_verbs_parse() {
        assert_eq!(
            parse("expect_save_dialog $TMP/kaya-save-$PID copy").unwrap()[0],
            Step::ExpectSaveDialog("$TMP/kaya-save-$PID".into(), "copy".into())
        );
        assert_eq!(
            parse("file_dialog_name final").unwrap()[0],
            Step::FileDialogName("final".into())
        );
        assert_eq!(parse("file_save").unwrap()[0], Step::FileSave(true));
        assert_eq!(parse("file_save cancel").unwrap()[0], Step::FileSave(false));
        assert!(parse("expect_save_dialog somewhere").is_err());
        assert!(parse("expect_save_dialog a b c").is_err());
        assert!(parse("file_dialog_name a b").is_err());
        assert!(parse("file_dialog_name").is_err());
        assert!(parse("file_save save").is_err());
        // Actions are silent, observations are not — the same split the
        // rest of the grammar keeps.
        assert!(!Step::FileSave(true).is_assertion());
        assert!(!Step::FileDialogName("x".into()).is_assertion());
        assert!(Step::ExpectSaveDialog("d".into(), "n".into()).is_assertion());
    }

    /// Shares are percentages of the children's *sum*, so container
    /// spacing and padding stay out of the number.
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

    /// A `;` INSIDE A QUOTED STRING IS PROSE TOO — kaya's own asset
    /// miss sentence carries one. tools/scenes/assets.steps is the
    /// cross-platform half, through the Swift and Kotlin interpreters.
    #[test]
    fn a_quoted_semicolon_is_not_a_statement_break() {
        let sentence = "kaya: no asset named \"icons/nope.png\"; the package carries a, b";
        let script = format!("expect label#0 \"{sentence}\"");
        let steps = parse(&script).unwrap();
        assert_eq!(steps.len(), 1, "{steps:?}");
        assert_eq!(
            steps[0],
            Step::Expect(Target { kind: TargetKind::Label, index: 0, id: None, keys: None }, sentence.to_owned())
        );
        // And the separator still separates when it is not inside a
        // string, which is the property the transports depend on.
        let joined = parse("click button#0; expect label#0 \"a; b\"; click button#1").unwrap();
        assert_eq!(joined.len(), 3, "{joined:?}");
        assert_eq!(
            joined[1],
            Step::Expect(Target { kind: TargetKind::Label, index: 0, id: None, keys: None }, "a; b".to_owned())
        );
    }

    /// expect routes by target kind, and expect_focused both parses and
    /// counts as an expect for the zero-expect guard.
    #[test]
    fn entry_expect_and_focus_route_and_count() {
        let steps =
            parse("expect entry#0 \"entry-text\"\nexpect_focused entry#0").unwrap();
        assert_eq!(steps[1], Step::ExpectFocused(Target { kind: TargetKind::Entry, index: 0, id: None, keys: None }));
        let (tx, rx) = std::sync::mpsc::channel();
        run(steps, MockStage { seen: &SEEN, verdict: tx });
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 0, "{verdict}");
        assert!(verdict.contains("entry-text"), "{verdict}");
        assert!(verdict.contains("focused"), "{verdict}");
    }

    /// `type` takes no target and reaches the stage as the text the
    /// script wrote, verbatim, escapes and all.
    #[test]
    fn type_drives_the_stage_with_the_text_it_was_given() {
        let steps = parse("expect entry#0 \"entry-text\"\ntype \"a b\"").unwrap();
        assert_eq!(steps[1], Step::Type("a b".to_owned()));
        SEEN.lock().unwrap().clear();
        let (tx, rx) = std::sync::mpsc::channel();
        run(steps, MockStage { seen: &SEEN, verdict: tx });
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 0, "{verdict}");
        assert!(
            SEEN.lock().unwrap().iter().any(|s| s == "type a b"),
            "{:?}",
            SEEN.lock().unwrap()
        );
    }

    /// The payload floor, refused at PARSE so no backend has to invent
    /// a keycode the five platforms do not agree on.
    #[test]
    fn type_refuses_what_a_keystroke_cannot_carry() {
        assert!(parse("type \"a\\nb\"").is_err());
        assert!(parse("type \"a\\rb\"").is_err());
        assert!(parse("type \"héllo\"").is_err());
        assert!(parse("type \"\"").is_err());
        assert!(parse("type").is_err());
        // ...and the whole printable range goes through, spaces
        // included: a scene types words.
        assert!(parse("type \"kaya 1.0 (x)\"").is_ok());
    }

    /// TYPING IS AN ACTION: a script that only types proves nothing,
    /// and the exhaustive is_assertion match is what keeps a new verb
    /// from shipping without landing on one side of that line.
    #[test]
    fn a_script_that_only_types_has_no_expects() {
        let (tx, rx) = std::sync::mpsc::channel();
        run(parse("type \"milk\"").unwrap(), MockStage { seen: &SEEN, verdict: tx });
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 1, "{verdict}");
        assert!(verdict.contains("no expects"), "{verdict}");
    }

    /// `expect_dirty` takes a BOOLEAN, never a marker string: the
    /// marker is the backend's business and differs on every platform
    /// (docs/dirty-plan.md D1/D2).
    #[test]
    fn expect_dirty_parses_a_bool_and_an_optional_window() {
        assert_eq!(parse("expect_dirty true").unwrap()[0], Step::ExpectDirty(None, true));
        assert_eq!(parse("expect_dirty false").unwrap()[0], Step::ExpectDirty(None, false));
        assert_eq!(
            parse("expect_dirty window#1 true").unwrap()[0],
            Step::ExpectDirty(Some(1), true)
        );
        // Not a marker, not a title, not a maybe.
        assert!(parse("expect_dirty").is_err());
        assert!(parse("expect_dirty yes").is_err());
        assert!(parse("expect_dirty \"*notes\"").is_err());
    }

    /// The verb reads THE STAGE, and both answers are reachable (the
    /// mock's surface 0 is clean, surface 1 edited); the mismatch text
    /// carries the observation.
    #[test]
    fn expect_dirty_reads_the_stage_and_reports_what_it_saw() {
        let (tx, rx) = std::sync::mpsc::channel();
        run(
            parse("expect_dirty false\nexpect_dirty window#1 true").unwrap(),
            MockStage { seen: &SEEN, verdict: tx },
        );
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 0, "{verdict}");
        assert!(verdict.contains("dirty false"), "{verdict}");
        assert!(verdict.contains("window#1 dirty true"), "{verdict}");

        let (tx, rx) = std::sync::mpsc::channel();
        run(parse("expect_dirty true").unwrap(), MockStage { seen: &SEEN, verdict: tx });
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 1, "{verdict}");
        assert!(verdict.contains("dirty false, wanted true"), "{verdict}");
    }

    /// A seed whose file is NOT THERE fails by name. macOS's own tool
    /// is why this cannot be left to the backend: `set the clipboard to
    /// POSIX file "<missing>"` exits 0, prints nothing and leaves the
    /// board untouched (docs/traps.md), so every symptom downstream
    /// describes the clipboard and none of them the path.
    #[test]
    fn clipboard_seed_names_a_file_that_is_not_there() {
        let (tx, rx) = std::sync::mpsc::channel();
        run(
            parse("clipboard_seed files \"/nope/kaya-missing.txt\"\nexpect label#0 \"ok-text\"")
                .unwrap(),
            MockStage { seen: &SEEN, verdict: tx },
        );
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 1, "{verdict}");
        assert!(verdict.contains("there is no file at /nope/kaya-missing.txt"), "{verdict}");
        // And the kinds that carry CONTENT rather than a path are
        // untouched by the check — a text seed of that same string is
        // a perfectly good seed.
        let (tx, rx) = std::sync::mpsc::channel();
        run(
            parse("clipboard_seed text \"/nope/kaya-missing.txt\"\nexpect label#0 \"ok-text\"")
                .unwrap(),
            MockStage { seen: &SEEN, verdict: tx },
        );
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 0, "{verdict}");
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
        fn type_text(&self, text: &str) {
            self.seen.lock().unwrap().push(format!("type {text}"));
        }
        fn read_label(&self, _: Target) -> String {
            // THE WEDGE, for the step-ceiling test below: a Stage call
            // that never comes back, which is what every backend's hop is
            // when the UI thread is saturated.
            while WEDGE.load(std::sync::atomic::Ordering::Relaxed) {
                std::thread::sleep(Duration::from_millis(25));
            }
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
        fn columns_presented(&self, target: Target) -> String {
            if target.index == 7 {
                NORMALIZED_SEEN.lock().unwrap().push(format!("{target:?}"));
            }
            String::new()
        }
        fn row_cells(&self, _: Target) -> String {
            String::new()
        }
        fn column_edges(&self, _: Target, _: usize) -> String {
            String::new()
        }
        /// A windowed tier: three of twelve rows realized from index 4.
        fn window_band(&self, _: Target) -> String {
            "4 12".into()
        }
        /// "" is done; the one key this stage cannot find answers the
        /// sentence a backend would, so the refusal path is a test too.
        fn scroll_to_row(&self, _: Target, key: &str) -> String {
            self.seen.lock().unwrap().push(format!("scroll_to_row {key}"));
            if key == "missing" {
                return "no row carries that key".into();
            }
            String::new()
        }
        fn resolve_id(&self, kind: TargetKind, id: &str, keys: Option<&str>) -> Option<isize> {
            if id == "missing" {
                return None;
            }
            if let Some(keys) = keys {
                RESOLVE_SEEN
                    .lock()
                    .unwrap()
                    .push(format!("{kind:?} {id} {keys}"));
                return Some(7);
            }
            Some(0)
        }
        fn header_click(&self, _: Target, _: u32) {}
        fn child_shares(&self, _: Target) -> String {
            "25,75".into()
        }
        fn window_title(&self, _: u64) -> String {
            "mock".to_owned()
        }
        fn window_content_size(&self, _: u64) -> (f64, f64) {
            (540.0, 330.0)
        }
        /// Surface 1 is EDITED and 0 is clean, so one stage walks both
        /// answers; a fixed `true` would pass every test for the same
        /// reason.
        fn window_dirty(&self, window: u64) -> bool {
            window == 1
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
        /// A picker that ANSWERS A FIXED NUMBER OF READS and is then
        /// gone: every dialog verb's postcondition is that the panel
        /// leaves, so a mock that answers forever could only walk the
        /// swallowed-press path.
        fn file_dialog_state(&self) -> Option<(String, Vec<String>)> {
            countdown(&DIALOG_READS).then(|| DIALOG.lock().unwrap().clone())?
        }
        fn choose_file(&self, _: Option<&str>) {}
        fn goto_directory(&self, _: &str) {}
        fn save_dialog_state(&self) -> Option<(String, String)> {
            countdown(&SAVE_READS).then(|| SAVE.lock().unwrap().clone())?
        }
        fn set_save_name(&self, _: &str) {}
        fn confirm_save(&self, _: bool) {}
        fn clipboard_seed(&self, _: &str, _: &str) {}
        fn clipboard_read(&self, _: &str) -> String {
            String::new()
        }
        fn alert_count(&self) -> usize {
            0
        }
        fn root_fills(&self) -> String {
            String::new()
        }
        fn inset(&self) -> String {
            "16".into()
        }
        /// A family NAME rather than an empty string, which would pass
        /// an `expect_typeface ""` nobody would write.
        fn typeface(&self) -> String {
            "MockSystemFont".into()
        }
        /// A sentence rather than four colours: a colour string could
        /// accidentally equal a scene's expectation.
        fn app_icon(&self) -> String {
            "<mock stage draws no app icon>".into()
        }
        /// Same rule as the icon: a sentence, never a shape that could
        /// accidentally equal a scene's expectation.
        fn canvas_probe(&self, _target: Target) -> String {
            "<mock stage rasterizes nothing>".into()
        }
        /// The mock blits nothing and says so in a sentence, UNLESS a
        /// test staged an answer — the ±1 compare's negatives need this
        /// stage to hand the verb bytes it chose.
        fn canvas_ink(&self, _target: Target, _points: &str) -> String {
            INK_ANSWER
                .lock()
                .unwrap()
                .clone()
                .unwrap_or_else(|| "<mock stage blits nothing>".to_owned())
        }
        /// A SENTENCE, never "track" or "viewbox": either word would let
        /// a scene pass here with nothing rastered at all.
        fn canvas_raster_shape(&self, _target: Target) -> String {
            "<mock stage rasterizes nothing>".into()
        }
        /// The mock has no core to drive, and COUNTS instead — the frame
        /// verb's only observable in this suite.
        fn frame(&self) {
            FRAMES.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        }
        fn container_inset(&self, _target: Target) -> String {
            "0".into()
        }
        fn container_fills(&self, _: Target) -> String {
            String::new()
        }
        /// Index 0 FILLS and every other index is short, so one stage
        /// walks both answers; a fixed empty string would pass the
        /// negative half for the positive half's reason.
        fn widget_fills(&self, t: Target) -> String {
            if t.index == 0 {
                String::new()
            } else {
                "draws 96pt of a 126pt track".into()
            }
        }
        /// The same shape: index 0 spans, every other index is short.
        fn widget_spans_breadth(&self, t: Target) -> String {
            if t.index == 0 {
                String::new()
            } else {
                "spans 79pt of its parent's 375pt breadth".into()
            }
        }
        fn cross_mode(&self, _: Target) -> String {
            "center".into()
        }
        fn container_axis(&self, _: Target) -> String {
            "center".into()
        }
        fn fold_state(&self, _: Target, _: Option<Target>) -> String {
            "<mock stage folds nothing>".into()
        }
        fn section_count(&self) -> usize {
            0
        }
        fn sections_presentation(&self, _window: u64) -> String {
            "bar".into()
        }
        fn active_section_title(&self) -> String {
            String::new()
        }
        // The switcher row's glyph, the way menu_symbol's mock answers:
        // one row this stage claims to draw, everything else absent, so
        // the hit and the miss are both exercisable.
        fn section_symbol(&self, title: &str) -> String {
            if title == "Feed" { "home".to_owned() } else { "no such section row".to_owned() }
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
        fn panes_reading(&self) -> String {
            "unknown/0".to_owned()
        }
        fn ax(&self, _: Target) -> String {
            "button/Save".to_owned()
        }
        fn ax_hint(&self, _: Target) -> String {
            "save the draft".to_owned()
        }
        // The range reads answer NOTHING here on purpose: these mocks
        // exist for the parse/flow tests, and a mock that invented a
        // highlight would be a fixture pretending to be a platform.
        fn highlights(&self, _: Target) -> String {
            String::new()
        }
        fn selection(&self, _: Target) -> String {
            String::new()
        }
        fn revealed(&self, _: Target, _: TextRange) -> String {
            "offscreen".to_owned()
        }
        fn compose(&self, _: Target, _: &str) {}
        fn menu_state(&self, _: &str, aspect: MenuAspect) -> String {
            match aspect {
                MenuAspect::Enablement => "disabled".to_owned(),
                MenuAspect::Checkedness => "checked".to_owned(),
                MenuAspect::Value => "value 1".to_owned(),
            }
        }
        fn menu_symbol(&self, _: &str) -> String {
            "copy".to_owned()
        }
        // A chrome that took the promotion list, and the remainder in the
        // menu bar — the macOS shape.
        fn toolbar_chrome(&self) -> String {
            "2/2/2/menubar".to_owned()
        }
        fn toolbar_item(&self, _: &str, aspect: &str) -> String {
            // Answers the two axes the way menu_state's mock does: the
            // glyph it drew, and a button the catalog disabled.
            match aspect {
                "enabled" | "disabled" => "disabled".to_owned(),
                _ => "done".to_owned(),
            }
        }
        fn shortcut(&self, spelling: &str) {
            self.seen.lock().unwrap().push(format!("shortcut {spelling}"));
        }
        fn finish(&self, code: i32, verdict: &str) {
            let _ = self.verdict.send((code, verdict.to_owned()));
            // The exit hop's wedge: `finish` prints the verdict and then
            // asks the UI thread to end the process, and THAT hop wedges
            // too (the linux lane's N=6000 — verdict at 103.63s, no exit
            // ever, killed from outside).
            while WEDGE_EXIT.load(std::sync::atomic::Ordering::Relaxed) {
                std::thread::sleep(Duration::from_millis(25));
            }
        }
    }

    static SEEN: Mutex<Vec<String>> = Mutex::new(Vec::new());
    static RESOLVE_SEEN: Mutex<Vec<String>> = Mutex::new(Vec::new());
    static NORMALIZED_SEEN: Mutex<Vec<String>> = Mutex::new(Vec::new());
    static WEDGE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    static WEDGE_EXIT: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    /// What MockStage::canvas_ink answers. Held for the whole of the
    /// one test that writes it, so two tests in the same binary cannot
    /// read each other's answer.
    static INK_ANSWER: Mutex<Option<String>> = Mutex::new(None);
    /// How many frames MockStage was driven. The `frame` verb's only
    /// observable in this suite — the mock has no core to tick.
    static FRAMES: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    static INK_SERIAL: Mutex<()> = Mutex::new(());
    /// The picker and the save panel MockStage answers with, and how
    /// many reads each has left. Written only by the verb trace's child
    /// processes, where nothing else runs.
    static DIALOG: Mutex<Option<(String, Vec<String>)>> = Mutex::new(None);
    static SAVE: Mutex<Option<(String, String)>> = Mutex::new(None);
    static DIALOG_READS: std::sync::atomic::AtomicUsize =
        std::sync::atomic::AtomicUsize::new(0);
    static SAVE_READS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

    /// One read off a dialog's remaining budget; false once it is spent.
    fn countdown(left: &std::sync::atomic::AtomicUsize) -> bool {
        use std::sync::atomic::Ordering::Relaxed;
        left.fetch_update(Relaxed, Relaxed, |n| n.checked_sub(1)).is_ok()
    }

    /// A WEDGED STEP ENDS THE RUN LEGIBLY. Before the step ceiling a
    /// step that never returned printed NOTHING, because the retry
    /// deadline is read only after a step returns (measured on all four
    /// platforms 2026-08-24, docs/measurements/choke-*-2026-08-24.txt).
    /// IN A CHILD PROCESS, because what the guard promises is that the
    /// harness LEAVES — which the process it ends cannot report.
    #[test]
    fn a_wedged_step_publishes_a_verdict_and_leaves() {
        use std::sync::atomic::Ordering::Relaxed;
        const CHILD: &str = "KAYA_HARNESS_WEDGE_CHILD";
        const CEILING: Duration = Duration::from_millis(1500);
        let me = format!(
            "{}::a_wedged_step_publishes_a_verdict_and_leaves",
            module_path!().splitn(2, "::").nth(1).unwrap()
        );
        // BOTH HOPS, because the measurement found both: a step that
        // never answers (no verdict at all) and, once a verdict IS out,
        // an exit that never runs (linux N=6000, verdict at 103.63s).
        match std::env::var(CHILD).as_deref() {
            Ok("step") => {
                WEDGE.store(true, Relaxed);
                let (tx, _rx) = std::sync::mpsc::channel();
                run(
                    parse("expect label#0 \"ok-text\"").unwrap(),
                    MockStage { seen: &SEEN, verdict: tx },
                );
                // Only reachable if the ceiling did NOT fire — the
                // parent reads this line as the failure it is.
                println!("KAYA_TEST: the wedged run returned on its own");
                return;
            }
            Ok("exit") => {
                WEDGE_EXIT.store(true, Relaxed);
                let (tx, _rx) = std::sync::mpsc::channel();
                run(
                    parse("expect label#0 \"ok-text\"").unwrap(),
                    MockStage { seen: &SEEN, verdict: tx },
                );
                println!("KAYA_TEST: the wedged finish returned on its own");
                return;
            }
            _ => {}
        }
        // The cap is the OLD behavior's stand-in for "something outside
        // kills it"; reaching it is the pre-fix red.
        let cap = Duration::from_secs(30);
        let drive = |mode: &str| -> (Option<std::process::ExitStatus>, String, Duration) {
            let log_path = std::env::temp_dir()
                .join(format!("kaya-wedge-{}-{mode}.log", std::process::id()));
            let log_file = std::fs::File::create(&log_path).unwrap();
            let mut child = std::process::Command::new(std::env::current_exe().unwrap())
                .args(["--exact", "--nocapture", "--test-threads=1", &me])
                .env(CHILD, mode)
                .env("KAYA_STEP_CEILING_MS", CEILING.as_millis().to_string())
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::from(log_file.try_clone().unwrap()))
                .stderr(std::process::Stdio::from(log_file))
                .spawn()
                .unwrap();
            let started = Instant::now();
            let status = loop {
                match child.try_wait().unwrap() {
                    Some(status) => break Some(status),
                    None if started.elapsed() > cap => {
                        let _ = child.kill();
                        let _ = child.wait();
                        break None;
                    }
                    None => std::thread::sleep(Duration::from_millis(25)),
                }
            };
            let waited = started.elapsed();
            let log = std::fs::read_to_string(&log_path).unwrap_or_default();
            let _ = std::fs::remove_file(&log_path);
            (status, log, waited)
        };

        let (status, log, waited) = drive("step");
        let status = status.unwrap_or_else(|| {
            panic!("the wedged child never left in {cap:?} — the step ceiling did not fire, \
                    which is the silence this test exists for. Its log:\n{log}")
        });
        assert_eq!(status.code(), Some(1), "the wedged child left with the wrong code:\n{log}");
        assert!(
            log.contains("KAYA_SELFTEST: FAILED (no verdict"),
            "the wedged child left without publishing a verdict:\n{log}"
        );
        // The sentence NAMES THE STEP: a fixed sentence would be printed
        // for every wedge and name none of them.
        assert!(
            log.contains(r#"Expect(Target { kind: Label, index: 0"#),
            "the verdict does not name the step:\n{log}"
        );
        assert!(waited >= CEILING, "the ceiling fired before its own deadline ({waited:?})");
        assert!(waited < cap, "{waited:?}");

        let (status, log, waited) = drive("exit");
        let status = status.unwrap_or_else(|| {
            panic!("the child never left in {cap:?} though its verdict was published — \
                    the exit grace did not fire. Its log:\n{log}")
        });
        // UNDER THE VERDICT'S OWN CODE: this run PASSED, and a wedged
        // exit must not turn a pass into a failure.
        assert_eq!(status.code(), Some(0), "the wedged exit left with the wrong code:\n{log}");
        assert!(
            log.contains("the verdict is published and the platform's exit path has not run"),
            "the exit grace left without saying why:\n{log}"
        );
        assert!(waited >= EXIT_GRACE, "the exit grace fired early ({waited:?})");
        assert!(waited < cap, "{waited:?}");
    }

    /// THE VERB TRACE's four promises: a failing run writes the
    /// attempts, a passing one writes nothing, the ring says how much it
    /// dropped, and a WEDGED step dumps from the watchdog
    /// (crates/kaya/src/vtrace.rs). IN CHILD PROCESSES for the
    /// parallelism: the ring and the env var that arms it are
    /// process-global, and every other test that calls `run` resets it.
    #[test]
    fn the_verb_trace_is_written_on_failure_only() {
        use std::sync::atomic::Ordering::Relaxed;
        const CHILD: &str = "KAYA_VERB_TRACE_CHILD";
        let me = format!(
            "{}::the_verb_trace_is_written_on_failure_only",
            module_path!().splitn(2, "::").nth(1).unwrap()
        );
        // Every ghost-family verb in one run, then an ACTION whose id
        // resolves to nothing — the one failure that lands at once
        // instead of after the 15s poll deadline.
        let dialog_stage = || {
            *DIALOG.lock().unwrap() = Some((
                "/nowhere".to_owned(),
                vec!["wanted.txt".to_owned(), "stale-sibling.txt".to_owned()],
            ));
            *SAVE.lock().unwrap() = Some(("/nowhere".to_owned(), "suggested.txt".to_owned()));
            // The picker answers the goto's breadcrumb read, the
            // file_choose row check and two dismissal attempts, then it
            // is gone — so the third attempt is the one that passes.
            DIALOG_READS.store(4, Relaxed);
            // The name read, file_save's check, and one dismissal
            // attempt.
            SAVE_READS.store(3, Relaxed);
            let (tx, _rx) = std::sync::mpsc::channel();
            run(
                parse(&format!(
                    "expect label#0 \"ok-text\"\nfile_dialog_goto {}\nfile_choose wanted.txt\n\
                     file_dialog_name final\nfile_save\nclick button@missing",
                    std::env::temp_dir().to_string_lossy()
                ))
                .unwrap(),
                MockStage { seen: &SEEN, verdict: tx },
            );
        };
        match std::env::var(CHILD).as_deref() {
            Ok("fail") => {
                dialog_stage();
                return;
            }
            Ok("pass") => {
                let (tx, _rx) = std::sync::mpsc::channel();
                run(
                    parse("expect label#0 \"ok-text\"").unwrap(),
                    MockStage { seen: &SEEN, verdict: tx },
                );
                return;
            }
            Ok("cap") => {
                crate::vtrace::begin(Instant::now());
                crate::vtrace::step(0, format_args!("Overflow"));
                for i in 0..crate::vtrace::CAP + 50 {
                    crate::vtrace::note("cap", format_args!("record {i}"));
                }
                crate::vtrace::dump("the ring test");
                return;
            }
            Ok("wedge") => {
                // The highest-value dump: the harness thread is still
                // inside the verb, so nothing else knows what it was
                // doing.
                WEDGE.store(true, Relaxed);
                let (tx, _rx) = std::sync::mpsc::channel();
                run(
                    parse("expect label#0 \"ok-text\"").unwrap(),
                    MockStage { seen: &SEEN, verdict: tx },
                );
                println!("KAYA_TEST: the wedged run returned on its own");
                return;
            }
            _ => {}
        }
        let drive = |mode: &str| -> (std::process::Output, std::path::PathBuf, String) {
            let trace = std::env::temp_dir()
                .join(format!("kaya-vtrace-{}-{mode}.log", std::process::id()));
            let _ = std::fs::remove_file(&trace);
            let out = std::process::Command::new(std::env::current_exe().unwrap())
                .args(["--exact", "--nocapture", "--test-threads=1", &me])
                .env(CHILD, mode)
                .env("KAYA_VERB_TRACE", &trace)
                .env("KAYA_STEP_CEILING_MS", "800")
                .output()
                .unwrap();
            let text = std::fs::read_to_string(&trace).unwrap_or_default();
            (out, trace, text)
        };

        let (out, trace, text) = drive("fail");
        let _ = std::fs::remove_file(&trace);
        assert!(
            out.status.success(),
            "the failing-run child did not finish: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        for want in [
            // The dump says why it was written and what it lost.
            "dump reason=\"the verdict failed",
            "dropped=0",
            // The step boundary, so a record knows what it was inside.
            "step=5 text=\"Click(",
            // The picker's own listing: "six stale siblings" is this
            // family's failure face and nothing else keeps it.
            "stale-sibling.txt",
            // EVERY attempt of the dismissal poll — the FAILING ones by
            // name, since asserting on the last attempt alone passes with
            // the per-attempt records deleted (watched 2026-08-27).
            "verb=file_choose try=2 what=\"<- not yet: file_choose 'wanted.txt': the dialog \
             is still up",
            "verb=file_choose try=3",
            // The press, paired with the read that preceded it.
            // A `what` is one key=value field, so its own quotes are
            // flattened to `'` (vtrace's `quoted`, simdrive's rule).
            "-> stage.choose_file(Some('wanted.txt'))",
            // The aim beside the answer (docs/deferred.md's iOS-sheets
            // WATCH entry asked for exactly this).
            "the picker's breadcrumb right after the call reads",
            // The name the panel already carried, which the verb used
            // to throw away as `Some(_)`.
            "already names 'suggested.txt'",
            "verb=file_save try=1 what=\"<- not yet: file_save: the dialog is still up",
            "verb=file_save try=2",
            // The id search, and each attempt that resolved nothing.
            "-> searching for a Button carrying a11y_id 'missing'",
            "<- no Button carries 'missing' yet",
            "verb=resolve_id try=1",
        ] {
            assert!(text.contains(want), "the trace has no {want:?}:\n{text}");
        }

        let (out, trace, text) = drive("pass");
        let existed = trace.exists();
        let _ = std::fs::remove_file(&trace);
        assert!(out.status.success(), "the passing-run child did not finish");
        assert!(
            !existed && text.is_empty(),
            "a PASSING run wrote a trace — retention is failure-only:\n{text}"
        );

        let (out, trace, text) = drive("cap");
        let _ = std::fs::remove_file(&trace);
        assert!(out.status.success(), "the ring child did not finish");
        assert!(
            text.contains(&format!("records={} dropped=50", crate::vtrace::CAP)),
            "the ring does not report what it dropped:\n{}",
            text.lines().next().unwrap_or_default()
        );
        assert!(!text.contains("what=\"record 0\""), "the oldest record was not dropped");
        assert!(text.contains("what=\"record 50\""), "the ring dropped more than it said");
        assert!(
            text.contains(&format!("what=\"record {}\"", crate::vtrace::CAP + 49)),
            "the newest record is missing"
        );

        let (out, trace, text) = drive("wedge");
        let _ = std::fs::remove_file(&trace);
        assert_eq!(
            out.status.code(),
            Some(1),
            "the wedged child left with the wrong code: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        assert!(
            text.contains("dump reason=\"the step ceiling fired"),
            "the step ceiling ended the run and wrote no trace — that is the case the \
             trace exists for:\n{text}"
        );
        assert!(
            text.contains("step=0 text=\"Expect(Target { kind: Label"),
            "the wedge dump does not name the step it was inside:\n{text}"
        );
    }

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

    /// THE INK COMPARE IS ±1 PER CHANNEL AND NOT ±2 (ruled 2026-08-26,
    /// docs/canvas-plan.md §7.2): one unit is the macOS display-profile
    /// round trip, two is a different colour, and every failure the verb
    /// was built for moves a channel by far more than either.
    #[test]
    fn ink_tolerates_one_channel_unit_and_no_more() {
        // ONE STRING, BOTH MODES — the scene's own frozen spelling.
        let want = "light FFFFFF/D2E3F7 dark 16181C/2B3B4F";
        // THE TWO MEASURED CASES FIRST: what the mac actually reads back
        // off its own window for the bytes the core wrote, in each
        // appearance (2026-08-26 light, 2026-08-27 dark).
        assert!(ink_matches("light FFFFFF/D2E2F7", want));
        assert!(ink_matches("dark 17181D/2B3A4F", want));
        // Every channel of every colour, both directions, at the edge —
        // in BOTH modes, since the tolerance is per mode.
        for got in [
            "light FEFFFF/D2E3F7", "light FFFEFF/D2E3F7", "light FFFFFE/D2E3F7",
            "light FFFFFF/D1E3F7", "light FFFFFF/D2E2F7", "light FFFFFF/D2E3F6",
            "light FFFFFF/D3E4F8",
            "dark 15181C/2B3B4F", "dark 16171C/2B3B4F", "dark 16181B/2B3B4F",
            "dark 16181C/2A3B4F", "dark 16181C/2B3A4F", "dark 16181C/2B3B4E",
            "dark 17191D/2C3C50",
        ] {
            assert!(ink_matches(got, want), "{got} is one unit away and must pass");
        }
        // And one past it, on each side of each mode's pair.
        for got in [
            "light FDFFFF/D2E3F7", "light FFFFFF/D0E3F7", "light FFFFFF/D2E5F7",
            "light FFFFFF/D2E3F9",
            "dark 14181C/2B3B4F", "dark 16181C/293B4F", "dark 16181C/2B3D4F",
            "dark 18181C/2B3B4F",
        ] {
            assert!(!ink_matches(got, want), "{got} is two units away and must fail");
        }
        // THE MODES DO NOT BORROW EACH OTHER'S VALUES, which is the whole
        // point of naming both: the light palette's bytes measured under a
        // dark appearance is the defect that shipped, and it must fail even
        // though every one of those bytes appears in this string.
        assert!(!ink_matches("dark FFFFFF/D2E3F7", want));
        assert!(!ink_matches("light 16181C/2B3B4F", want));
        // A mode the expectation does not name never matches — it is not
        // silently treated as either half.
        assert!(!ink_matches("sepia FFFFFF/D2E3F7", want));
        // Neither is the SHAPE: a diagnostic answer, a missing colour,
        // an extra one and a value that is not six hex digits are all
        // non-matches, so they reach the failure text whole.
        for got in [
            "<mock stage blits nothing>",
            "light FFFFFF",
            "light FFFFFF/D2E3F7/D2E3F7",
            "light FFFFFF/D2E3F",
            "light FFFFFF/D2E3FZ",
            "",
        ] {
            assert!(!ink_matches(got, want), "{got:?} must not match {want:?}");
        }
    }

    /// AND THE REAL VERB SAYS BOTH VALUES when it refuses: the
    /// tolerance's whole risk is a scene going quietly green against a
    /// colour nobody meant.
    #[test]
    fn the_ink_verb_passes_at_one_unit_and_names_both_colours_at_two() {
        let _serial = INK_SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let script =
            "expect_ink canvas@chart \"15,20 70,63 = light FFFFFF/D2E3F7 dark 16181C/2B3B4F\"";
        let drive = |answer: &str| -> (i32, String) {
            *INK_ANSWER.lock().unwrap() = Some(answer.to_owned());
            let (tx, rx) = std::sync::mpsc::channel();
            run(parse(script).unwrap(), MockStage { seen: &SEEN, verdict: tx });
            *INK_ANSWER.lock().unwrap() = None;
            rx.recv().unwrap()
        };
        // The mac's own reading, which is the case the ruling is for.
        let (code, verdict) = drive("light FFFFFF/D2E2F7");
        assert_eq!(code, 0, "{verdict}");
        // THE OBSERVATION IS THE WHOLE FROZEN TEXT, never the sampled
        // bytes and never just the mode that ran: the platforms
        // legitimately sample different values AND run in different
        // appearances, and the verdict is byte-compared across all of
        // them (invariant 6).
        assert!(
            verdict.contains("ink light FFFFFF/D2E3F7 dark 16181C/2B3B4F"),
            "{verdict}"
        );
        assert!(!verdict.contains("D2E2F7"), "the verdict leaked the sampled bytes: {verdict}");

        // THE SAME SCENE ON A DARK HOST publishes that same line — the
        // failure this per-mode form closes.
        let (code, dark_verdict) = drive("dark 17181D/2B3A4F");
        assert_eq!(code, 0, "{dark_verdict}");
        assert_eq!(
            verdict, dark_verdict,
            "the two appearances must publish a byte-identical verdict (invariant 6)"
        );

        let (code, verdict) = drive("light FFFFFF/D2E5F7");
        assert_eq!(code, 1, "two units must not pass: {verdict}");
        assert!(
            verdict.contains("ink light FFFFFF/D2E5F7 at 15,20 70,63, \
                              wanted light FFFFFF/D2E3F7 dark 16181C/2B3B4F"),
            "the refusal must name what was read AND what was wanted: {verdict}"
        );

        // AND THE WRONG MODE'S VALUES FAIL, which is the defect that
        // shipped: the light palette's bytes measured under a dark
        // appearance.
        let (code, verdict) = drive("dark FFFFFF/D2E3F7");
        assert_eq!(code, 1, "the light palette under a dark appearance must fail: {verdict}");
        assert!(verdict.contains("ink dark FFFFFF/D2E3F7 at 15,20 70,63"), "{verdict}");
    }

    /// expect_order parses like expect, counts as an expect for the
    /// zero-expect guard, and compares against the stage's child_texts.
    #[test]
    fn expect_order_is_an_expect() {
        let steps = parse("expect_order column#0 \"a|b\"").unwrap();
        assert_eq!(
            steps[0],
            Step::ExpectOrder(Target { kind: TargetKind::Column, index: 0, id: None, keys: None }, "a|b".into())
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

    /// expect_shares counts as an expect for the zero-expect guard.
    /// That half is load-bearing: a scene whose only assertion is a
    /// layout one — a conformance scene — would otherwise be rejected as
    /// asserting nothing.
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

    /// expect_typeface puts the RESOLVED family in its failure text
    /// rather than the requested one, because that name IS the
    /// diagnosis: the platform's default means the presence gate refused
    /// the request, `Helvetica` on Apple means a CoreText fallback
    /// swallowed it, and the request echoed back means the read is wired
    /// to the model.
    #[test]
    fn expect_typeface_reports_the_resolved_family() {
        let steps = parse(r#"expect_typeface "Georgia""#).unwrap();
        assert_eq!(steps[0], Step::ExpectTypeface("Georgia".into()));
        assert!(parse("expect_typeface Georgia").is_err(), "the family is quoted");
        let (tx, rx) = std::sync::mpsc::channel();
        run(steps, MockStage { seen: &SEEN, verdict: tx });
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 1, "the mock resolved nothing, so this must fail");
        assert!(
            verdict.contains("typeface MockSystemFont, wanted Georgia"),
            "the failure names what the stage RESOLVED: {verdict}"
        );
        // And the passing spelling is the byte-compared observation
        // every backend has to reproduce.
        let (tx, rx) = std::sync::mpsc::channel();
        run(
            parse(r#"expect_typeface "MockSystemFont""#).unwrap(),
            MockStage { seen: &SEEN, verdict: tx },
        );
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 0, "{verdict}");
        assert_eq!(verdict, "KAYA_SELFTEST: OK (typeface MockSystemFont)");
    }

    /// expect_root_fills parses bare (the mounted root is the only
    /// thing it can mean) and reads the stage's root_fills: empty is the
    /// fill, anything else is the hug's description.
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
            fn clipboard_seed(&self, _: &str, _: &str) {}
            fn clipboard_read(&self, _: &str) -> String {
                String::new()
            }
            fn click(&self, _: Target) {}
            fn toggle(&self, _: Target, _: bool) {}
            fn set_value(&self, _: Target, _: f64) {}
            fn set_text(&self, _: Target, _: &str) {}
            fn type_text(&self, _: &str) {}
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
            fn columns_presented(&self, _: Target) -> String {
                String::new()
            }
            fn row_cells(&self, _: Target) -> String {
                String::new()
            }
            fn column_edges(&self, _: Target, _: usize) -> String {
                String::new()
            }
            fn window_band(&self, _: Target) -> String {
                String::new()
            }
            fn scroll_to_row(&self, _: Target, _: &str) -> String {
                String::new()
            }
            fn resolve_id(&self, _: TargetKind, _: &str, _: Option<&str>) -> Option<isize> {
                Some(0)
            }
            fn header_click(&self, _: Target, _: u32) {}
            fn child_shares(&self, _: Target) -> String {
                String::new()
            }
            fn window_title(&self, _: u64) -> String {
            "mock".to_owned()
        }
        fn window_content_size(&self, _: u64) -> (f64, f64) {
            (540.0, 330.0)
        }
        fn window_dirty(&self, _: u64) -> bool {
            false
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
            fn widget_fills(&self, _: Target) -> String {
                "draws 96pt of a 126pt track".into()
            }
            fn widget_spans_breadth(&self, _: Target) -> String {
                String::new()
            }
            fn cross_mode(&self, _: Target) -> String {
                "start".into()
            }
            fn container_axis(&self, _: Target) -> String {
                "start".into()
            }
            fn alert_title(&self, _window: u64) -> Option<String> {
            None
        }
        fn fold_state(&self, _: Target, _: Option<Target>) -> String {
            "<mock stage folds nothing>".into()
        }
        fn inset(&self) -> String {
            "16".into()
        }
        /// A family NAME rather than an empty string, which would pass
        /// an `expect_typeface ""` nobody would write.
        fn typeface(&self) -> String {
            "MockSystemFont".into()
        }
        /// A sentence rather than four colours: a colour string could
        /// accidentally equal a scene's expectation.
        fn app_icon(&self) -> String {
            "<mock stage draws no app icon>".into()
        }
        /// Same rule as the icon: a sentence, never a shape that could
        /// accidentally equal a scene's expectation.
        fn canvas_probe(&self, _target: Target) -> String {
            "<mock stage rasterizes nothing>".into()
        }
        fn canvas_ink(&self, _target: Target, _points: &str) -> String {
            "<mock stage blits nothing>".into()
        }
        fn canvas_raster_shape(&self, _target: Target) -> String {
            "<mock stage rasterizes nothing>".into()
        }
        fn frame(&self) {}
        fn container_inset(&self, _target: Target) -> String {
            "0".into()
        }
        fn choose_alert(&self, _choice: u32) {}
        fn file_dialog_state(&self) -> Option<(String, Vec<String>)> {
            None
        }
        fn choose_file(&self, _: Option<&str>) {}
        fn goto_directory(&self, _: &str) {}
        fn save_dialog_state(&self) -> Option<(String, String)> {
            None
        }
        fn set_save_name(&self, _: &str) {}
        fn confirm_save(&self, _: bool) {}
        fn alert_count(&self) -> usize {
            0
        }
        fn section_count(&self) -> usize {
            0
        }
        fn sections_presentation(&self, _window: u64) -> String {
            "bar".into()
        }
        fn active_section_title(&self) -> String {
            String::new()
        }
        fn section_symbol(&self, _: &str) -> String {
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
        fn panes_reading(&self) -> String {
            "unknown/0".to_owned()
        }
        fn ax(&self, _: Target) -> String {
            "unknown/".to_owned()
        }
        fn ax_hint(&self, _: Target) -> String {
            String::new()
        }
        // The range reads answer NOTHING here on purpose: these mocks
        // exist for the parse/flow tests, and a mock that invented a
        // highlight would be a fixture pretending to be a platform.
        fn highlights(&self, _: Target) -> String {
            String::new()
        }
        fn selection(&self, _: Target) -> String {
            String::new()
        }
        fn revealed(&self, _: Target, _: TextRange) -> String {
            "offscreen".to_owned()
        }
        fn compose(&self, _: Target, _: &str) {}
        fn menu_state(&self, _: &str, _: MenuAspect) -> String {
            String::new()
        }
        fn menu_symbol(&self, _: &str) -> String {
            String::new()
        }
        fn toolbar_chrome(&self) -> String {
            String::new()
        }
        fn toolbar_item(&self, _: &str, _: &str) -> String {
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

    /// expect_fills takes a container target and fails with the
    /// platform's slack description. The pass half is load-bearing:
    /// growers that hold their ratio at natural size pass every share
    /// assertion while consuming nothing — this is the verb that sees
    /// the leftover (the AppKit gravity-areas miss, found only because a
    /// 540x330 window made 200pt of slack impossible to overlook).
    #[test]
    fn expect_fills_is_an_expect() {
        let steps = parse("expect_fills column#0").unwrap();
        assert_eq!(
            steps[0],
            Step::ExpectFills(Target { kind: TargetKind::Column, index: 0, id: None, keys: None })
        );
        let (tx, rx) = std::sync::mpsc::channel();
        run(steps, MockStage { seen: &SEEN, verdict: tx });
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 0, "{verdict}");
        assert_eq!(verdict, "KAYA_SELFTEST: OK (column#0 fills)");
        // Slack fails loudly: the whole point of the verb is that
        // ratio-at-minimum cannot pass it.
        struct Pooler(Sender<(i32, String)>);
        impl Stage for Pooler {
            fn clipboard_seed(&self, _: &str, _: &str) {}
            fn clipboard_read(&self, _: &str) -> String {
                String::new()
            }
            fn click(&self, _: Target) {}
            fn toggle(&self, _: Target, _: bool) {}
            fn set_value(&self, _: Target, _: f64) {}
            fn set_text(&self, _: Target, _: &str) {}
            fn type_text(&self, _: &str) {}
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
            fn columns_presented(&self, _: Target) -> String {
                String::new()
            }
            fn row_cells(&self, _: Target) -> String {
                String::new()
            }
            fn column_edges(&self, _: Target, _: usize) -> String {
                String::new()
            }
            fn window_band(&self, _: Target) -> String {
                String::new()
            }
            fn scroll_to_row(&self, _: Target, _: &str) -> String {
                String::new()
            }
            fn resolve_id(&self, _: TargetKind, _: &str, _: Option<&str>) -> Option<isize> {
                Some(0)
            }
            fn header_click(&self, _: Target, _: u32) {}
            fn child_shares(&self, _: Target) -> String {
                String::new()
            }
            fn window_title(&self, _: u64) -> String {
            "mock".to_owned()
        }
        fn window_content_size(&self, _: u64) -> (f64, f64) {
            (540.0, 330.0)
        }
        fn window_dirty(&self, _: u64) -> bool {
            false
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
            fn widget_fills(&self, _: Target) -> String {
                "draws 96pt of a 126pt track".into()
            }
            fn widget_spans_breadth(&self, _: Target) -> String {
                String::new()
            }
            fn cross_mode(&self, _: Target) -> String {
                "start".into()
            }
            fn container_axis(&self, _: Target) -> String {
                "start".into()
            }
            fn alert_title(&self, _window: u64) -> Option<String> {
            None
        }
        fn fold_state(&self, _: Target, _: Option<Target>) -> String {
            "<mock stage folds nothing>".into()
        }
        fn inset(&self) -> String {
            "16".into()
        }
        /// A family NAME rather than an empty string, which would pass
        /// an `expect_typeface ""` nobody would write.
        fn typeface(&self) -> String {
            "MockSystemFont".into()
        }
        /// A sentence rather than four colours: a colour string could
        /// accidentally equal a scene's expectation.
        fn app_icon(&self) -> String {
            "<mock stage draws no app icon>".into()
        }
        /// Same rule as the icon: a sentence, never a shape that could
        /// accidentally equal a scene's expectation.
        fn canvas_probe(&self, _target: Target) -> String {
            "<mock stage rasterizes nothing>".into()
        }
        fn canvas_ink(&self, _target: Target, _points: &str) -> String {
            "<mock stage blits nothing>".into()
        }
        fn canvas_raster_shape(&self, _target: Target) -> String {
            "<mock stage rasterizes nothing>".into()
        }
        fn frame(&self) {}
        fn container_inset(&self, _target: Target) -> String {
            "0".into()
        }
        fn choose_alert(&self, _choice: u32) {}
        fn file_dialog_state(&self) -> Option<(String, Vec<String>)> {
            None
        }
        fn choose_file(&self, _: Option<&str>) {}
        fn goto_directory(&self, _: &str) {}
        fn save_dialog_state(&self) -> Option<(String, String)> {
            None
        }
        fn set_save_name(&self, _: &str) {}
        fn confirm_save(&self, _: bool) {}
        fn alert_count(&self) -> usize {
            0
        }
        fn section_count(&self) -> usize {
            0
        }
        fn sections_presentation(&self, _window: u64) -> String {
            "bar".into()
        }
        fn active_section_title(&self) -> String {
            String::new()
        }
        fn section_symbol(&self, _: &str) -> String {
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
        fn panes_reading(&self) -> String {
            "unknown/0".to_owned()
        }
        fn ax(&self, _: Target) -> String {
            "unknown/".to_owned()
        }
        fn ax_hint(&self, _: Target) -> String {
            String::new()
        }
        // The range reads answer NOTHING here on purpose: these mocks
        // exist for the parse/flow tests, and a mock that invented a
        // highlight would be a fixture pretending to be a platform.
        fn highlights(&self, _: Target) -> String {
            String::new()
        }
        fn selection(&self, _: Target) -> String {
            String::new()
        }
        fn revealed(&self, _: Target, _: TextRange) -> String {
            "offscreen".to_owned()
        }
        fn compose(&self, _: Target, _: &str) {}
        fn menu_state(&self, _: &str, _: MenuAspect) -> String {
            String::new()
        }
        fn menu_symbol(&self, _: &str) -> String {
            String::new()
        }
        fn toolbar_chrome(&self) -> String {
            String::new()
        }
        fn toolbar_item(&self, _: &str, _: &str) -> String {
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

    /// expect_breadth reads widget_spans_breadth and refuses a
    /// container; index 0 spans, index 1 is short, so all three answers
    /// are walked on one mock.
    #[test]
    fn expect_breadth_reads_a_widget_against_its_container_breadth() {
        let steps = parse("expect_breadth scroll#0").unwrap();
        assert_eq!(
            steps[0],
            Step::ExpectBreadth(Target { kind: TargetKind::Scroll, index: 0, id: None, keys: None })
        );
        let (tx, rx) = std::sync::mpsc::channel();
        run(steps, MockStage { seen: &SEEN, verdict: tx });
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 0, "{verdict}");
        assert_eq!(verdict, "KAYA_SELFTEST: OK (scroll#0 spans its breadth)");
        let steps = parse("expect_breadth scroll#1").unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        run(steps, MockStage { seen: &SEEN, verdict: tx });
        let (code, verdict) = rx.recv().unwrap();
        assert_ne!(code, 0);
        assert!(verdict.contains("short of its breadth (spans 79pt of its parent's 375pt breadth)"), "{verdict}");
        let steps = parse("expect_breadth column#0").unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        run(steps, MockStage { seen: &SEEN, verdict: tx });
        let (code, verdict) = rx.recv().unwrap();
        assert_ne!(code, 0);
        assert!(verdict.contains("expect_breadth reads a widget"), "{verdict}");
    }

    #[test]
    fn expect_fills_reads_a_widget_against_its_track() {
        let steps = parse("expect_fills textarea#0").unwrap();
        assert_eq!(
            steps[0],
            Step::ExpectFills(Target { kind: TargetKind::Textarea, index: 0, id: None, keys: None })
        );
        let (tx, rx) = std::sync::mpsc::channel();
        run(steps, MockStage { seen: &SEEN, verdict: tx });
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 0, "{verdict}");
        assert_eq!(verdict, "KAYA_SELFTEST: OK (textarea#0 fills)");
        // A widget short of its track fails loudly, and says so in the
        // widget's own words rather than the container's ("leaves
        // leftover" would name the wrong subject).
        let (tx, rx) = std::sync::mpsc::channel();
        run(
            parse("expect_fills textarea#1").unwrap(),
            MockStage { seen: &SEEN, verdict: tx },
        );
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 1);
        assert!(verdict.contains("textarea#1 is short of its track"), "{verdict}");
        assert!(verdict.contains("96pt of a 126pt track"), "{verdict}");
    }

    /// expect_window compares the first VISIBLE row and the declared
    /// total — the pair a byte-shared scene can freeze (ruled
    /// 2026-08-25; the realized count is a viewport metric).
    #[test]
    fn expect_window_compares_first_visible_and_total() {
        let steps = parse("expect_window column#0 4 12").unwrap();
        assert_eq!(
            steps[0],
            Step::ExpectWindow(
                Target { kind: TargetKind::Column, index: 0, id: None, keys: None },
                4,
                12
            )
        );
        let (tx, rx) = std::sync::mpsc::channel();
        run(steps, MockStage { seen: &SEEN, verdict: tx });
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 0, "{verdict}");
        assert!(verdict.contains("column#0 window 4 12"), "{verdict}");

        let (tx, rx) = std::sync::mpsc::channel();
        run(
            parse("expect_window column#0 0 12").unwrap(),
            MockStage { seen: &SEEN, verdict: tx },
        );
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 1, "{verdict}");
        assert!(verdict.contains("\"4 12\""), "{verdict}");
        assert!(verdict.contains("wanted \"0 12\""), "{verdict}");
    }

    /// Both numbers are required, and nothing else is — a third number
    /// is the realized count this verb deliberately cannot say.
    #[test]
    fn expect_window_wants_exactly_two_numbers() {
        for line in [
            "expect_window column#0",
            "expect_window column#0 4",
            "expect_window column#0 4 3 12",
            "expect_window column#0 4 many",
            "expect_window column#0 -1 12",
        ] {
            assert!(parse(line).is_err(), "accepted {line:?}");
        }
        assert!(parse("expect_window column@ledger[august] 0 15000").is_ok());
    }

    /// scroll_to_row is an ACTION, but a backend that cannot do it
    /// reddens the step with its own sentence rather than passing.
    #[test]
    fn scroll_to_row_drives_the_stage_and_reports_a_refusal() {
        let steps = parse("scroll_to_row column#0 tx-4200").unwrap();
        assert_eq!(
            steps[0],
            Step::ScrollToRow(
                Target { kind: TargetKind::Column, index: 0, id: None, keys: None },
                "tx-4200".to_owned()
            )
        );
        SEEN.lock().unwrap().clear();
        let (tx, rx) = std::sync::mpsc::channel();
        run(
            parse("expect_window column#0 4 12\nscroll_to_row column#0 tx-4200").unwrap(),
            MockStage { seen: &SEEN, verdict: tx },
        );
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 0, "{verdict}");
        assert!(
            SEEN.lock().unwrap().iter().any(|s| s == "scroll_to_row tx-4200"),
            "{:?}",
            SEEN.lock().unwrap()
        );

        let (tx, rx) = std::sync::mpsc::channel();
        run(
            parse("expect_window column#0 4 12\nscroll_to_row column#0 missing").unwrap(),
            MockStage { seen: &SEEN, verdict: tx },
        );
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 1, "{verdict}");
        assert!(verdict.contains("no row carries that key"), "{verdict}");
        assert!(verdict.contains("\"missing\""), "{verdict}");
    }

    /// A key with spaces has to be quoted, and a bare one may not be
    /// two words — refused at parse rather than scrolling nowhere.
    #[test]
    fn scroll_to_row_takes_one_key() {
        assert!(parse("scroll_to_row column#0").is_err());
        assert!(parse("scroll_to_row column#0 a b").is_err());
        assert_eq!(
            parse("scroll_to_row column#0 \"a b\"").unwrap()[0],
            Step::ScrollToRow(
                Target { kind: TargetKind::Column, index: 0, id: None, keys: None },
                "a b".to_owned()
            )
        );
    }

    /// Authored targets preserve their script spelling, and malformed
    /// copy suffixes never degrade into a bare authored id.
    #[test]
    fn authored_key_targets_parse() {
        let bare = parse("expect_columns column@positions \"A|B\"").unwrap();
        let Step::ExpectColumns(bare, _) = &bare[0] else {
            panic!("parsed {:?}", bare[0]);
        };
        assert_eq!(bare.id, Some("positions"));
        assert_eq!(bare.keys, None);
        assert_eq!(target_spec(bare), "column@positions");

        let steps = parse(
            "expect_columns column@positions[brokerage.taxable] \"A|B\"",
        )
        .unwrap();
        match &steps[0] {
            Step::ExpectColumns(t, _) => {
                assert_eq!(t.kind, TargetKind::Column);
                assert_eq!(t.id, Some("positions"));
                assert_eq!(t.keys, Some("brokerage.taxable"));
                assert_eq!(target_spec(t), "column@positions[brokerage.taxable]");
            }
            other => panic!("parsed {other:?}"),
        }
        for target in [
            "column@",
            "column@positions[]",
            "column@positions[.a]",
            "column@positions[a.]",
            "column@positions[a..b]",
            "column@positions[a",
            "column@positions[a]]",
            "column@positions[[a]",
            "column@positions][a]",
            "column@positions[a][b]",
        ] {
            assert!(
                parse(&format!("expect_columns {target} \"A|B\"")).is_err(),
                "accepted {target}"
            );
        }
    }

    /// The core-minted sort tag is decoded without trusting its length;
    /// numeric keys never collide with numeric-looking string keys.
    #[test]
    fn table_tags_match_string_copy_paths() {
        use crate::protocol::Value;

        let exact = crate::wire::click_tag(
            41,
            &[Value::Str("brokerage".into()), Value::Str("taxable".into())],
        );
        assert_eq!(table_tag_node(&exact), Some(41));
        assert!(table_tag_matches_keys(&exact, 41, "brokerage.taxable"));
        assert!(!table_tag_matches_keys(&exact, 42, "brokerage.taxable"));
        assert!(!table_tag_matches_keys(&exact, 41, "brokerage.retirement"));
        assert!(!table_tag_matches_keys(&exact, 41, "brokerage"));

        let numeric = crate::wire::click_tag(41, &[Value::I64(3)]);
        assert_eq!(table_tag_node(&numeric), Some(41));
        assert!(!table_tag_matches_keys(&numeric, 41, "3"));

        let pathless = crate::wire::click_tag(41, &[]);
        assert_eq!(table_tag_node(&pathless), None);
        assert!(!table_tag_matches_keys(&pathless, 41, "brokerage"));

        assert_eq!(table_tag_node(&exact[..exact.len() - 1]), None);
        assert!(!table_tag_matches_keys(&exact[..16], 41, "brokerage.taxable"));
    }

    /// Resolution sees the full keyed target; every downstream Stage
    /// method sees only the normalized creation index.
    #[test]
    fn authored_copy_target_resolves_then_normalizes() {
        RESOLVE_SEEN.lock().unwrap().clear();
        NORMALIZED_SEEN.lock().unwrap().clear();
        let (tx, rx) = std::sync::mpsc::channel();
        run(
            parse("expect_columns column@positions[brokerage.taxable] \"\"").unwrap(),
            MockStage { seen: &SEEN, verdict: tx },
        );
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 0, "{verdict}");
        assert_eq!(
            *RESOLVE_SEEN.lock().unwrap(),
            vec!["Column positions brokerage.taxable".to_owned()]
        );
        assert_eq!(
            *NORMALIZED_SEEN.lock().unwrap(),
            vec!["Target { kind: Column, index: 7, id: None, keys: None }".to_owned()]
        );
        assert_eq!(verdict, "KAYA_SELFTEST: OK ()");
    }

    /// A missing keyed copy reports the complete script target instead
    /// of blaming the authored id alone.
    #[test]
    fn authored_copy_target_failure_keeps_copy_path() {
        let (tx, rx) = std::sync::mpsc::channel();
        run(
            parse(
                "expect_columns column#0 \"\"\n\
                 click column@missing[brokerage.taxable]",
            )
            .unwrap(),
            MockStage { seen: &SEEN, verdict: tx },
        );
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 1, "{verdict}");
        assert!(
            verdict.contains(
                "column@missing[brokerage.taxable] names no widget: no Column carries a11y_id \
                 \"missing\" at copy [brokerage.taxable]"
            ),
            "{verdict}"
        );
    }

    /// expect_aligned emits the byte-identical "column#0 aligns center"
    /// observation on match and fails with the stage's classification,
    /// which comes from geometry — so a backend that ignores the prop
    /// cannot pass by echoing the model.
    #[test]
    fn expect_aligned_is_an_expect() {
        let steps = parse("expect_aligned column#0 \"center\"").unwrap();
        assert_eq!(
            steps[0],
            Step::ExpectAligned(
                Target { kind: TargetKind::Column, index: 0, id: None, keys: None },
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
    /// label with an internal space and each state spelling.
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
            Step::ContextOpen(Target { kind: TargetKind::Label, index: 1, id: None, keys: None })
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
    /// item" at runtime.
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

    /// Menu-chrome spellings are a closed set on BOTH halves, checked
    /// at parse.
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
    /// the iPadOS 26 defect exactly: a regular window whose catalog sits
    /// behind the compact overflow.
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

    /// The toolbar verbs' grammar. `expect_toolbar` is BARE — a count
    /// there would be a per-lane literal in a byte-frozen scene.
    #[test]
    fn toolbar_spellings() {
        for good in [
            "expect_toolbar",
            "expect_toolbar_item \"Save\" \"done\"",
            "expect_toolbar_item \"Find\" \"search\"",
            "expect_toolbar_item \"Save\" \"enabled\"",
            "expect_toolbar_item \"Save\" \"disabled\"",
        ] {
            assert!(parse(good).is_ok(), "{good} should parse");
        }
        for bad in [
            // A count (the whole reason the verb is bare), an aspect
            // outside the vocabulary, a misspelled symbol, the two
            // arguments unquoted, and each half missing.
            "expect_toolbar 2",
            "expect_toolbar_item \"Save\" \"checked\"",
            "expect_toolbar_item \"Save\" \"serach\"",
            "expect_toolbar_item Save done",
            "expect_toolbar_item \"Save\"",
            "expect_toolbar_item",
        ] {
            assert!(parse(bad).is_err(), "{bad} should not parse");
        }
    }

    /// The bare form's invariant, both directions: a promotion list
    /// that reached no chrome, and a remainder with nowhere to be.
    #[test]
    fn toolbar_chrome_invariant() {
        for good in ["2/2/2/menubar", "2/2/3/more", "3/3/9/overflow", "0/0/0/menubar"] {
            assert!(toolbar_chrome_fits(good).is_ok(), "{good} should fit");
        }
        // THE TWO SENTENCES THE ITEM COUNT BUYS: "no chrome at all" and
        // "a chrome whose items are not these" are different measurements
        // and must read differently. The second was printed as the first
        // by the first cut of this rule, on a real perturbed run.
        let nothing = toolbar_chrome_fits("0/2/0/menubar").unwrap_err();
        assert!(nothing.contains("holds 0 items, and 0 of the 2"), "{nothing}");
        let unlabelled = toolbar_chrome_fits("0/2/2/menubar").unwrap_err();
        assert!(unlabelled.contains("holds 2 items, and 0 of the 2"), "{unlabelled}");
        let homeless = toolbar_chrome_fits("2/2/2/none").unwrap_err();
        assert!(homeless.contains("no home in this window"), "{homeless}");
        // A reading that is not the spelling at all fails NAMING what
        // was read, rather than being coerced into a verdict.
        for bad in ["2/2/menubar", "2/2/2/menubar/extra", "two/2/2/menubar", "2/2/2/sidebar"] {
            let why = toolbar_chrome_fits(bad).unwrap_err();
            assert!(why.contains(bad), "{why} should quote the reading");
        }
    }

    /// The toolbar verbs poll the stage's real-chrome reads and report
    /// a LANE-INDEPENDENT verdict for the bare form.
    #[test]
    fn toolbar_expects_poll_the_real_chrome() {
        static TOOLBAR_SEEN: Mutex<Vec<String>> = Mutex::new(Vec::new());
        let steps = parse(
            "expect label#0 \"ok-text\"\n\
             expect_toolbar\n\
             expect_toolbar_item \"Save\" \"done\"\n\
             expect_toolbar_item \"Save\" \"disabled\"",
        )
        .unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        run(steps, MockStage { seen: &TOOLBAR_SEEN, verdict: tx });
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 0, "{verdict}");
        assert_eq!(
            verdict,
            "KAYA_SELFTEST: OK (ok-text, toolbar, toolbar item Save done, \
             toolbar item Save disabled)"
        );
        // The mismatch half: the mock's enablement reads "disabled", so
        // asserting enabled fails with the read.
        let (tx, rx) = std::sync::mpsc::channel();
        run(
            parse("expect label#0 \"ok-text\"\nexpect_toolbar_item \"Save\" \"enabled\"")
                .unwrap(),
            MockStage { seen: &TOOLBAR_SEEN, verdict: tx },
        );
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 1);
        assert!(
            verdict.contains("toolbar item Save reads \"disabled\", wanted \"enabled\""),
            "{verdict}"
        );
    }

    /// The section-symbol verb takes two QUOTED arguments: a title may
    /// carry spaces, and an unquoted tail would silently assert only its
    /// first word.
    #[test]
    fn section_symbol_spellings() {
        for good in [
            "expect_section_symbol \"Feed\" \"home\"",
            "expect_section_symbol \"Archive\" \"star\"",
            // A title with a space, which is the case the quoting is for.
            "expect_section_symbol \"Recently Played\" \"star\"",
        ] {
            assert!(parse(good).is_ok(), "{good} should parse");
        }
        for bad in [
            // Both unquoted, each half missing, and neither present.
            "expect_section_symbol Feed home",
            "expect_section_symbol \"Feed\" home",
            "expect_section_symbol \"Feed\"",
            "expect_section_symbol",
        ] {
            assert!(parse(bad).is_err(), "{bad} should not parse");
        }
    }

    /// The verb polls the stage's REAL-switcher read and fails with the
    /// measured answer — the property the +20/+24 decode needed and
    /// nobody had (see Step::ExpectSectionSymbol).
    #[test]
    fn section_symbol_expects_poll_the_real_switcher() {
        static SECTION_SEEN: Mutex<Vec<String>> = Mutex::new(Vec::new());
        let (tx, rx) = std::sync::mpsc::channel();
        run(
            parse("expect_section_symbol \"Feed\" \"home\"").unwrap(),
            MockStage { seen: &SECTION_SEEN, verdict: tx },
        );
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 0, "{verdict}");
        assert_eq!(verdict, "KAYA_SELFTEST: OK (section \"Feed\" symbol \"home\")");
        // The miss carries WHAT WAS MEASURED, which is the whole point:
        // "wrong glyph", "no glyph" and "no such row" have to read
        // differently or the reader chases the wrong thing.
        let (tx, rx) = std::sync::mpsc::channel();
        run(
            parse("expect_section_symbol \"Archive\" \"star\"").unwrap(),
            MockStage { seen: &SECTION_SEEN, verdict: tx },
        );
        let (code, verdict) = rx.recv().unwrap();
        assert_eq!(code, 1);
        assert!(
            verdict
                .contains("section \"Archive\" symbol \"no such section row\", wanted \"star\""),
            "{verdict}"
        );
    }

    /// The hint verb is deliberately NOT the `<role>/<label>` shape — a
    /// hint is one free-text phrase.
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

    /// The ax spelling's closed role set, both directions. An EMPTY
    /// label is a real assertion: the platform speaks nothing here.
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

    /// Malformed states die at parse too.
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

    /// The shortcut verb's GRAMMAR floor only. The policy floor is the
    /// root's one checker in scene.rs, and a spelling it rejects never
    /// reaches a dispatch table.
    #[test]
    fn shortcut_grammar_rejects_line_noise() {
        assert!(parse("shortcut \"\"").is_err());
        assert!(parse("shortcut \"primary +s\"").is_err());
        assert!(parse("shortcut primary+s").is_err());
        assert!(parse("shortcut").is_err());
    }

    /// expect_menus and expect_menu poll the stage's real-chrome reads
    /// and join the byte-identical pass observations into the verdict.
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
    /// the parsed path/target/spelling. A dedicated registry: SEEN is
    /// shared across parallel tests.
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
                "context_open Target { kind: Label, index: 1, id: None, keys: None }".to_owned(),
                "menu_activate Rename".to_owned(),
                "shortcut primary+s".to_owned(),
            ]
        );
    }

    /// context_open on editable text fails loudly: v1's context menus
    /// there are dress (scene.rs refuses the attach). Parse accepts the
    /// target — the grammar is kind-agnostic — and the run arm holds the
    /// line.
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

/// Runs ONLY on the windows guest (tools/deploy-win.py's unit phase); no
/// unix build compiles it. The wedge is teardown that never returns, armed
/// on a hook `ExitProcess` RUNS and `TerminateProcess` skips. NOT atexit:
/// `std::process::exit` on this OS never runs CRT atexit handlers — the
/// first draft wedged atexit and the guest FALSIFIED it (the hostage child
/// exited clean in 4s), which would have made the escapes test vacuous.
#[cfg(all(test, windows))]
mod win_exit_tests {
    use std::time::{Duration, Instant};

    unsafe extern "system" fn wedge(_: *mut core::ffi::c_void) {
        loop {
            std::thread::sleep(Duration::from_secs(3600));
        }
    }

    fn arm_wedge() {
        // Function scope: a module-level extern ships into kaya.h
        // (gates.py's stale-header refusal caught exactly that).
        unsafe extern "system" {
            fn FlsAlloc(
                cb: Option<unsafe extern "system" fn(*mut core::ffi::c_void)>,
            ) -> u32;
            fn FlsSetValue(index: u32, value: *mut core::ffi::c_void) -> i32;
        }
        unsafe {
            let idx = FlsAlloc(Some(wedge));
            assert_ne!(idx, u32::MAX, "FlsAlloc failed");
            // The callback fires at loader shutdown only for a
            // non-null slot value.
            assert_ne!(FlsSetValue(idx, 1 as *mut core::ffi::c_void), 0);
        }
    }

    fn child(mode: &str) -> std::process::Child {
        std::process::Command::new(std::env::current_exe().unwrap())
            .args(["harness::win_exit_tests::child_body", "--exact", "--test-threads=1", "--nocapture"])
            .env("KAYA_TEST_WEDGE", mode)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .unwrap()
    }

    #[test]
    fn child_body() {
        let Ok(mode) = std::env::var("KAYA_TEST_WEDGE") else {
            return;
        };
        arm_wedge();
        match mode.as_str() {
            "harness" => super::harness_exit(7),
            "std" => std::process::exit(7),
            other => panic!("unknown wedge mode {other}"),
        }
    }

    #[test]
    fn harness_exit_escapes_wedged_teardown() {
        let t0 = Instant::now();
        let mut c = child("harness");
        let deadline = t0 + Duration::from_secs(10);
        loop {
            if let Some(status) = c.try_wait().unwrap() {
                assert_eq!(status.code(), Some(7), "wrong exit code");
                assert!(t0.elapsed() < Duration::from_secs(5), "took {:?}", t0.elapsed());
                return;
            }
            if Instant::now() > deadline {
                let _ = c.kill();
                panic!("harness_exit did not end the wedged child within 10s");
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    #[test]
    fn std_exit_is_the_hostage() {
        // The negative that keeps harness_exit honest: the primitive it
        // replaced really is held by the same wedge.
        let mut c = child("std");
        std::thread::sleep(Duration::from_secs(4));
        let held = c.try_wait().unwrap().is_none();
        let _ = c.kill();
        let _ = c.wait();
        assert!(held, "std::process::exit escaped the atexit wedge — the platform changed; re-derive harness_exit");
    }
}
