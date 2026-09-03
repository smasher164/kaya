//! WinUI 3 backend: an interpreter of resolved apply-ops.

#[allow(
    non_snake_case,
    non_camel_case_types,
    non_upper_case_globals,
    dead_code,
    clippy::all
)]
mod bindings;
mod order;

use order::{track_of, ChildOrder};

use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::c_void;
use std::sync::mpsc::Receiver;
use std::sync::OnceLock;

use windows_core::{HSTRING, Interface as _};

use bindings::Microsoft::UI::Dispatching::{DispatcherQueue, DispatcherQueueHandler};
// The WINDOW's own caption height, a windowing fact and not a XAML one:
// the `TitleBar` control sizes its own band and leaves the system's
// caption buttons where they were (microsoft-ui-xaml#9863).
use bindings::Microsoft::UI::Windowing::TitleBarHeightOption;
use bindings::Microsoft::UI::Xaml::Controls::{
    AppBarButton, Button, CheckBox, ColumnDefinition, ColumnDefinitionCollection, ComboBox,
    ComboBoxItem, CommandBar,
    ContentDialog,
    ContentDialogButton, ContentDialogResult, DisabledFormattingAccelerators, FontIcon, Grid,
    ICommandBarElement, IconElement, Image, MenuBar,
    MenuBarItem, MenuFlyout,
    MenuFlyoutItem, MenuFlyoutItemBase, MenuFlyoutSeparator, MenuFlyoutSubItem, NavigationView,
    NavigationViewItem, NavigationViewPaneDisplayMode, ProgressBar, RadioMenuFlyoutItem,
    RichEditBox, RichEditClipboardFormat, RowDefinition,
    RadioButtons, ScrollBarVisibility, ScrollMode, ScrollViewer, SelectionChangedEventHandler,
    SymbolIcon,
    Slider, TextBlock, TextBox, TextChangedEventHandler, TextCompositionEndedEventArgs,
    TextCompositionStartedEventArgs, TextControlPasteEventHandler,
    TitleBar,
    ToggleMenuFlyoutItem, TwoPaneView,
    TwoPaneViewMode, TwoPaneViewPriority, TwoPaneViewWideModeConfiguration,
};
// The RichEdit text object model: the textarea's text, undo stack and
// clipboard verbs live on a document object, and the text ranges ride it
// (docs/textarea-foundation-plan.md, the windows arm; docs/ranges-plan.md D1).
use bindings::Microsoft::UI::Text::{PointOptions, TextConstants, TextGetOptions, TextSetOptions};
use bindings::Windows::Foundation::{Point, TypedEventHandler};
// The caption title's two text properties are vtable pads in this
// backend's bindings, so the one element that needs them is parsed from
// markup — see `caption_title_text`.
use bindings::Microsoft::UI::Xaml::Markup::XamlReader;
use bindings::Microsoft::UI::Xaml::Input::KeyboardAccelerator;
use bindings::Windows::System::{VirtualKey, VirtualKeyModifiers};
use bindings::Microsoft::UI::Xaml::{
    GridLength, GridUnitType, HorizontalAlignment, Style, Thickness, Visibility,
};
// The styling pass's two resource types (docs/styling-plan.md D4): a role
// lowers to a keyed Style or a keyed Brush, looked up out of the
// framework's own dictionary.
use bindings::Microsoft::UI::Xaml::Media::Brush;
// The brand typeface's one type (docs/styling-plan.md Slice 2b); its
// bindgen filter entry is in tools/winui-bindgen.
use bindings::Microsoft::UI::Xaml::Media::FontFamily;
#[cfg(feature = "harness")]
use bindings::Microsoft::UI::Xaml::Automation::Peers::AutomationControlType;
use bindings::Microsoft::UI::Xaml::Media::Imaging::{BitmapImage, WriteableBitmap};
use bindings::Microsoft::UI::Xaml::ElementTheme;
// The canvas's four (docs/canvas-plan.md §3.2.1, §15.4): the blit fills a
// box `set_drawing` sized from the BUFFER, so Fill is exact rather than a
// stretch.
use bindings::Microsoft::UI::Xaml::Media::{
    CompositionTarget, ImageSource, RenderingEventArgs, Stretch,
};
// THE TRACK LAYOUT ASSIGNED (§3.2.1): the area the parent gave a child,
// which is not the child's own arranged box once the child carries an
// explicit size. See `canvas_track_of`.
use bindings::Microsoft::UI::Xaml::Controls::Primitives::LayoutInformation;
use windows::Win32::System::WinRT::IBufferByteAccess;
use bindings::Windows::Foundation::{IReference, PropertyValue};
use bindings::Windows::Storage::Streams::{DataWriter, InMemoryRandomAccessStream};
use bindings::Microsoft::UI::Xaml::{
    Application, ApplicationInitializationCallback, FocusState, FrameworkElement,
    RoutedEventHandler, TextWrapping, UIElement, UnhandledExceptionEventHandler, Window,
};
use bindings::Windows::Foundation::EventHandler;

use crate::protocol::{
    ApplyOp, CommandKind, MenuAttachment, MenuItemId, MenuItemKind, MenuProp, OccSink, Occurrence,
    Path, Prop, Transaction, Value, WidgetId, WidgetKind, WindowId, WindowProp,
    purge_context_natives,
};
use crate::scene::Scene;

enum NativeWidget {
    Column(Grid),
    Row(Grid),
    Checkbox { check: CheckBox, caption: TextBlock },
    Slider(Slider),
    Button { button: Button, caption: TextBlock },
    Label(TextBlock),
    Entry(TextBox),
    Image(Image),
    Scroll(ScrollViewer),
    Progress(ProgressBar),
    Select(ComboBox),
    Radio(RadioButtons),
    /// The 2D grid widget (KIND_GRID) — a WinUI Grid with Auto
    /// tracks, distinct from Column/Row's star-sized Grids.
    Grid2D(Grid),
    /// THE RICH-CAPABLE CONTROL, PINNED TO PLAIN TEXT
    /// (docs/textarea-foundation-plan.md): TextBox has no document object and
    /// no per-range formatting, and every rich opinion the RichEdit engine
    /// carries is pinned off in `pin_plain_text`.
    Textarea(RichEditBox),
    /// The blit's widget: the same `Image` control, over a
    /// `WriteableBitmap` the core's pixels are written straight into
    /// (docs/canvas-plan.md §8).
    Canvas(Image),
}

impl NativeWidget {
    fn element(&self) -> windows_core::Result<UIElement> {
        use windows_core::Interface;
        match self {
            NativeWidget::Column(panel) => panel.cast(),
            NativeWidget::Row(panel) => panel.cast(),
            NativeWidget::Checkbox { check, .. } => check.cast(),
            NativeWidget::Slider(slider) => slider.cast(),
            NativeWidget::Button { button, .. } => button.cast(),
            NativeWidget::Label(label) => label.cast(),
            NativeWidget::Entry(field) => field.cast(),
            NativeWidget::Image(image) => image.cast(),
            NativeWidget::Scroll(viewer) => viewer.cast(),
            NativeWidget::Progress(bar) => bar.cast(),
            NativeWidget::Select(combo) => combo.cast(),
            NativeWidget::Radio(group) => group.cast(),
            NativeWidget::Grid2D(grid) => grid.cast(),
            NativeWidget::Textarea(field) => field.cast(),
            NativeWidget::Canvas(image) => image.cast(),
        }
    }

    /// The editable behind a text widget, if this is one — the ONE place
    /// that knows which kinds are editable.
    fn editable(&self) -> Option<Editable> {
        match self {
            NativeWidget::Entry(field) => Some(Editable::Entry(field.clone())),
            NativeWidget::Textarea(field) => Some(Editable::Textarea(field.clone())),
            _ => None,
        }
    }
}

/// AN ORDINARY RANGE OVER WHATEVER THE SELECTION COVERS: READ the
/// selection, MUTATE a range (docs/traps.md: Mutating a RichEdit document
/// through its ITextSelection kills the process at teardown).
fn selection_range(
    doc: &bindings::Microsoft::UI::Text::RichEditTextDocument,
) -> windows_core::Result<bindings::Microsoft::UI::Text::ITextRange> {
    let selection = doc.Selection()?;
    let (start, end) = (selection.StartPosition()?, selection.EndPosition()?);
    doc.GetRange(start, end)
}

/// THE TWO NATIVE EDITABLES, BEHIND ONE CONTRACT.
///
/// The textarea is a `RichEditBox`, whose editing commands all live on its
/// `TextDocument` (docs/textarea-foundation-plan.md, the windows arm). Adding
/// an operation means adding it here, for both, or it does not compile.
#[derive(Clone)]
enum Editable {
    Entry(TextBox),
    Textarea(RichEditBox),
}

impl Editable {
    /// The text AS THE CONTROL STORES IT — CR line breaks, no trailing
    /// paragraph mark; callers apply `lf` on the way to the guest.
    ///
    /// `AdjustCrlf` IS A PIN: without it the story's trailing paragraph mark
    /// reads back as a newline the guest never wrote, breaking invariant 6
    /// (docs/probes/range-probe-windows.md; docs/textarea-foundation-plan.md).
    fn text(&self) -> windows_core::Result<String> {
        match self {
            Editable::Entry(field) => Ok(field.Text()?.to_string()),
            Editable::Textarea(field) => {
                let mut out = HSTRING::new();
                field
                    .TextDocument()?
                    .GetText(TextGetOptions::AdjustCrlf, &mut out)?;
                Ok(out.to_string())
            }
        }
    }

    /// `TextSetOptions::None` IS A PIN: the same call with `FormatRtf` PARSES
    /// the string as a document, so a guest whose textarea text began
    /// `{\rtf1` would see it rendered on windows and stored literally on the
    /// other four platforms (docs/traps.md: A RichEdit `SetText` with
    /// `FormatRtf` parses the guest's string as a document).
    fn set_text(&self, text: &str) -> windows_core::Result<()> {
        match self {
            Editable::Entry(field) => field.SetText(&HSTRING::from(text)),
            Editable::Textarea(field) => field
                .TextDocument()?
                .SetText(TextSetOptions::None, &HSTRING::from(text)),
        }
    }

    fn focus_state(&self) -> windows_core::Result<FocusState> {
        match self {
            Editable::Entry(field) => field.FocusState(),
            Editable::Textarea(field) => field.FocusState(),
        }
    }

    fn can_undo(&self) -> windows_core::Result<bool> {
        match self {
            Editable::Entry(field) => field.CanUndo(),
            Editable::Textarea(field) => field.TextDocument()?.CanUndo(),
        }
    }

    fn can_redo(&self) -> windows_core::Result<bool> {
        match self {
            Editable::Entry(field) => field.CanRedo(),
            Editable::Textarea(field) => field.TextDocument()?.CanRedo(),
        }
    }

    fn undo(&self) -> windows_core::Result<()> {
        match self {
            Editable::Entry(field) => field.Undo(),
            Editable::Textarea(field) => field.TextDocument()?.Undo(),
        }
    }

    fn redo(&self) -> windows_core::Result<()> {
        match self {
            Editable::Entry(field) => field.Redo(),
            Editable::Textarea(field) => field.TextDocument()?.Redo(),
        }
    }

    fn clear_undo_redo_history(&self) -> windows_core::Result<()> {
        match self {
            Editable::Entry(field) => field.ClearUndoRedoHistory(),
            Editable::Textarea(field) => field.TextDocument()?.ClearUndoRedoHistory(),
        }
    }

    fn cut_selection_to_clipboard(&self) -> windows_core::Result<()> {
        match self {
            Editable::Entry(field) => field.CutSelectionToClipboard(),
            Editable::Textarea(field) => selection_range(&field.TextDocument()?)?.Cut(),
        }
    }

    fn copy_selection_to_clipboard(&self) -> windows_core::Result<()> {
        match self {
            Editable::Entry(field) => field.CopySelectionToClipboard(),
            Editable::Textarea(field) => selection_range(&field.TextDocument()?)?.Copy(),
        }
    }

    /// The platform's own insertion — for a widget that declared no accept
    /// list, this IS the paste (DESIGN.md's paste split).
    ///
    /// PLAIN TEXT ON BOTH ARMS: `ITextRange::Paste(0)` would take the RICHEST
    /// format the clipboard offers, so the textarea reads CF_UNICODETEXT
    /// itself; `pin_plain_text` routes the control's own pastes here too.
    fn paste_from_clipboard(&self) -> windows_core::Result<()> {
        match self {
            Editable::Entry(field) => field.PasteFromClipboard(),
            Editable::Textarea(field) => {
                let Some(text) = clipboard_plain_text() else {
                    return Ok(());
                };
                selection_range(&field.TextDocument()?)?.SetText(&HSTRING::from(text))
            }
        }
    }

    /// Put the caret at `at` (in UTF-16 units), collapsed.
    fn set_caret(&self, at: i32) -> windows_core::Result<()> {
        match self {
            Editable::Entry(field) => {
                field.SetSelectionStart(at)?;
                field.SetSelectionLength(0)
            }
            Editable::Textarea(field) => field.TextDocument()?.Selection()?.SetRange(at, at),
        }
    }
}

struct CoreState {
    /// The window content inset (wprop 8, docs/styling-plan.md D3): the Mount
    /// arm stamps it as Grid.Padding and the harness's `offer` observation
    /// subtracts it from the root's actual size.
    inset: f64,
    /// A CONTAINER's own inset (prop 17, one level down): a WinUI Grid has ONE
    /// Padding where SwiftUI and Compose nest two boxes — see
    /// `container_padding`, the only thing that writes it.
    container_insets: HashMap<WidgetId, f64>,
    /// The minted padding host around a SCROLL mounted as a window's root: a
    /// ScrollViewer's default template ignores Control.Padding (the
    /// retemplated entry ScrollViewer in this file exists for that reason), so
    /// the window inset lives on a Grid AROUND the viewer. Keyed by the
    /// scroll's widget id; written only by the Mount arm.
    scroll_root_hosts: HashMap<WidgetId, Grid>,
    transactions: Receiver<Transaction>,
    scene: Scene,
    occurrences: OccSink,
    /// The directory the next picker opens on. ARMED, NOT SET: a dialog reads
    /// its folder when it is shown, so the harness's file_dialog_goto stores
    /// it here and the apply arm applies it.
    pending_dialog_dir: RefCell<Option<String>>,
    widgets: HashMap<WidgetId, NativeWidget>,
    // Which grid each widget sits in, for Destroy's detach.
    parents: HashMap<WidgetId, Grid>,
    /// The stacked fold's memory (docs/adaptive-layout-plan.md D7): folded
    /// child -> its table's id. The unfold op carries table 0, so the map is
    /// what routes the element home.
    folded_into: HashMap<u64, u64>,
    // Grid places by attached Row/Column index, not by child order
    // (docs/traps.md), so the logical order is tracked here and stamped back
    // onto the children after every structural change — which only MARKS its
    // container; `flush_tracks` stamps, once per batch (winui/order.rs).
    child_order: ChildOrder,
    grow: HashMap<WidgetId, f64>,
    /// Container align modes (the align spec enum's wire values): reindex
    /// stamps the cross alignment onto every child after any structural
    /// change, so late arrivals take the same path.
    aligns: HashMap<WidgetId, i64>,
    /// Axis overrides (prop 18, docs/adaptive-layout-plan.md D2): the creation
    /// kind names the default and `effective_vertical` folds this over it —
    /// reindex, spacing and the harness read all key on the fold.
    axes: HashMap<WidgetId, i64>,
    /// Container spacing as KAYA declared it (default 8), deliberately NOT the
    /// Grid's own RowSpacing/ColumnSpacing: reading the toolkit back mirrors
    /// the lowering's write and can never catch it dropped.
    spacings: HashMap<WidgetId, f64>,
    // Per-kind registries in creation order (stamped copies included): the
    // harness names targets as kind#index. Clicks emit the stored tag
    // directly; the other controls fire their real events for the stage's
    // direct writes, and the APPLY path arms apply_quiet instead.
    buttons: Vec<Vec<u8>>,
    /// The controls beside those tags, creation order: what `button@id` reads
    /// its AutomationId off and what `button@id[key.path]` matches a tag
    /// against.
    button_controls: Vec<Button>,
    checkboxes: Vec<CheckBox>,
    labels: Vec<TextBlock>,
    entries: Vec<TextBox>,
    /// Aligned with `entries`: the widget id per registry slot (the
    /// stage indexes by creation order; the maps below key by id).
    entry_ids: Vec<u64>,
    /// Per-entry swallow counters (docs/traps.md: A windows `type` verb that
    /// settles on the CONTROL leaves the undo ledger one edit behind): SetProp,
    /// the clear command and the stage's set_text
    /// bump this, write the text, and emit the occurrence SYNCHRONOUSLY where
    /// they must — the late native raise is swallowed 1:1. User typing bumps
    /// nothing and emits through the real raise.
    entry_swallow: HashMap<u64, std::sync::Arc<std::sync::atomic::AtomicUsize>>,
    entry_tags: HashMap<u64, Vec<u8>>,
    sliders: Vec<Slider>,
    images: Vec<Image>,
    /// The canvases, and their CORE ids beside them: `canvas_probe` asks
    /// the core about a widget id and `kind#index` is the only address
    /// the harness has.
    canvases: Vec<Image>,
    canvas_ids: Vec<u64>,
    scrolls: Vec<ScrollViewer>,
    progresses: Vec<ProgressBar>,
    selects: Vec<ComboBox>,
    radios: Vec<RadioButtons>,
    grids: Vec<Grid>,
    textareas: Vec<RichEditBox>,
    textarea_ids: Vec<u64>,
    /// Grid layout state: ordered children + column count; both the adds and
    /// the columns prop re-flow the attach positions (docs/traps.md: Sugar
    /// construction order differs per language).
    grid_children: HashMap<u64, Vec<UIElement>>,
    grid_cols: HashMap<u64, i32>,
    /// Radio plumbing, the select_options shape: label id -> (its
    /// group, its row in the group's Items vector) — option text
    /// updates land with SetAt.
    radio_options: HashMap<u64, (RadioButtons, u32)>,
    /// Option-label plumbing: label widget id -> (its select's ComboBox, its
    /// option row's own TextBlock). A select's label children are its OPTIONS
    /// — ComboBoxItems in the popup, not standalone widgets — so their SetProp
    /// text lands on the row as STRING content, never a TextBlock
    /// (docs/traps.md: A WinUI ComboBoxItem with UIElement content gets STOLEN
    /// by the collapsed box).
    select_options: HashMap<u64, (ComboBox, ComboBoxItem)>,
    /// Echo guard for EVERY interactive kind: WinUI's change events cannot
    /// tell a user act from a programmatic write, and only the USER path may
    /// emit an occurrence. Armed around every SetProp write; commands (clear)
    /// and the harness stage's writes stay unguarded ON PURPOSE. Atomic
    /// because WinRT event handlers are Send-bound.
    apply_quiet: std::sync::Arc<std::sync::atomic::AtomicBool>,
    columns: Vec<Grid>,
    /// Aligned with `columns`, including retained dead slots, so a keyed
    /// harness lookup can reject a copy whose widget and table are gone.
    #[cfg(feature = "harness")]
    column_ids: Vec<WidgetId>,
    rows: Vec<Grid>,
    window: Window,
    /// Auxiliary surfaces by kaya window id (the primary is
    /// `window`); created hidden, presented (Activated) at mount.
    aux_windows: HashMap<u64, Window>,
    /// veto_close per window id (primary included; default false).
    window_veto: HashMap<u64, bool>,
    /// App-initiated teardown bypasses the chrome-close grammar:
    /// Window.Close() rides WM_CLOSE, and without this a veto window would
    /// swallow its own confirmed destruction.
    tearing_down: std::collections::HashSet<u64>,
    /// The live modal alert (one per process): the request's identity
    /// plus the REAL ContentDialog for the runner's reads and press.
    /// Cleared by the ShowAsync completion — the one emit site.
    live_alert: Option<WinLiveAlert>,
    /// Live navigation entries by surface id, and per-window stacks
    /// bottom to top (DESIGN.md, Navigation); the window's own root
    /// and title come back when its stack empties.
    nav_entries: HashMap<u64, WinNavEntry>,
    nav_stacks: HashMap<u64, Vec<u64>>,
    /// The declared pane CEILING per window (wprop 6;
    /// docs/multicolumn-plan.md D2), and the presentation refresh_nav ACTUALLY
    /// rendered — stamped by the arm that ran, never derived (docs/traps.md).
    panes: HashMap<u64, i64>,
    split_presentation: HashMap<u64, &'static str>,
    /// The live split view per window, kept so the next render can
    /// release the roots it holds (see release_split).
    split_views: HashMap<u64, TwoPaneView>,
    /// The INNER TwoPaneView at a ceiling of three — the nest IS the
    /// three-pane construct (the priority is a CHAIN of PanePriority
    /// bits), and the panes reading folds both views' Modes.
    inner_splits: HashMap<u64, TwoPaneView>,
    window_roots: HashMap<u64, UIElement>,
    /// The WIDGET ID of each mounted surface root, by surface (window, pushed
    /// navigation entry or section pane): it tells `container_padding` which
    /// containers carry the window inset in their own Padding.
    mounted_roots: HashMap<u64, WidgetId>,
    window_titles: HashMap<u64, String>,
    /// Unsaved work per window (wprop 7). Windows publishes no modified
    /// affordance at any layer (docs/dirty-plan.md, the windows arm), so the
    /// caption IS the chrome here. Kept as STATE rather than read back out of
    /// the caption string: the app's title is never touched (D1/D2).
    window_dirty: HashMap<u64, bool>,
    /// Sections (DESIGN.md, Sections): per-window ordered sets, pane
    /// containers by section id, the NavigationView that materializes the
    /// switcher, and the selection mirror. A section's pane swaps between its
    /// own root and its stack's top entry (stacks are per-surface; nav_stacks
    /// keys sections too).
    sections: HashMap<u64, Vec<u64>>,
    section_panes: HashMap<u64, WinSection>,
    section_navs: HashMap<u64, NavigationView>,
    section_items: HashMap<u64, NavigationViewItem>,
    /// The switcher's swallow counter: SelectionChanged is raised
    /// ASYNCHRONOUSLY, so programmatic moves swallow the late raise (a flag's
    /// guard window closes too early) and only real user switches reach the
    /// handler body.
    section_swallow: HashMap<u64, std::sync::Arc<std::sync::atomic::AtomicUsize>>,
    /// What the CONTROL last showed — a no-op SetSelectedItem raises
    /// nothing, so the swallow only increments on a real move.
    ui_selected_sections: HashMap<u64, u64>,
    selected_sections: HashMap<u64, u64>,
    sections_presentation: HashMap<u64, i64>,
    /// Menus (DESIGN.md, Menus): the retained item model — kind fixed at
    /// create, every applicable prop live. This map is the POST-USER MIRROR
    /// (docs/traps.md): a toggle's Click handler updates checked here BEFORE
    /// emitting, and every rebuild starts from it. Items are never destroyed.
    menu_models: HashMap<u64, MenuModel>,
    /// Per-window top-level catalog items, in menubar-append order.
    menu_windows: HashMap<u64, Vec<u64>>,
    /// Context catalogs: attached root items per anchor widget, the
    /// stamped copy's key path (empty for a live widget — the noun
    /// every activation from that anchor stamps), and the one real
    /// MenuFlyout set as the element's ContextFlyout.
    context_roots: HashMap<u64, Vec<u64>>,
    context_nouns: HashMap<u64, Path>,
    context_flyouts: HashMap<u64, MenuFlyout>,
    /// (attachment, item id) -> its materialized native chrome, rebuilt
    /// with the catalog. Keyed PER ATTACHMENT because a template context
    /// catalog attaches the SAME item ids to every stamped copy and the
    /// copy's keys ARE the noun — a flat per-item map is the wrong-noun
    /// bug (docs/traps.md). Separators and NESTED radio groups mint none.
    menu_natives: HashMap<(MenuAttachment, u64), MenuNative>,
    /// The window shell (the ratified lowering): the TITLEBAR's Auto row at
    /// the top of a shell Grid, the MenuBar in the Auto row under it, the
    /// window's real content in the Star-row slot beneath both. Built once per
    /// window at the first menubar_append; every content swap goes through the
    /// slot.
    menubars: HashMap<u64, MenuBar>,
    menu_slots: HashMap<u64, Grid>,
    /// The shell Grid itself, kept so the titlebar row can be filled LATER
    /// than the shell is built — a window earns its caption `TitleBar` and
    /// the `CommandBar` inside it only when its catalog promotes something
    /// (docs/chrome-plan.md C2).
    menu_shells: HashMap<u64, Grid>,
    /// The window's REAL toolbar, minted on the first promotion by
    /// `refresh_toolbar`. Absent = this window has no toolbar, which is
    /// a state the harness read reports rather than papers over.
    toolbars: HashMap<u64, CommandBar>,
    /// The window's custom `TitleBar` control — the caption row the toolbar
    /// MERGES INTO (docs/chrome-plan.md C2's WinUI row). Extended is DERIVED
    /// from toolbar presence: minted by the first promotion and by nothing
    /// else, so a window that promotes nothing keeps the system caption.
    /// `refresh_caption` reaches it as a SECOND SINK, never a second author.
    window_titlebars: HashMap<u64, TitleBar>,
    /// The caption's TITLE TEXT, in the control's CENTRE slot.
    ///
    /// NOT THE CONTROL'S `Title` PROPERTY: it lays that out right after
    /// `LeftHeader`, which is kaya's MENU, and `TitleBar` writes
    /// `appWindow.Title` from it (microsoft-ui-xaml 2.2.0,
    /// `TitleBar.cpp:483-516`), clobbering the dirty marker (chrome-plan C2).
    window_caption_texts: HashMap<u64, TextBlock>,
    /// (window, item id) -> the promoted action's `AppBarButton`.
    ///
    /// THE WRITE SIDE ONLY: enablement is stamped through this map, while
    /// every harness READ walks the bar's own
    /// `PrimaryCommands`/`SecondaryCommands` — a read through this map would
    /// agree with kaya's model no matter what the window holds.
    toolbar_buttons: HashMap<(u64, u64), AppBarButton>,
    /// Canonical shortcut spelling -> action item id for the PRIMARY window's
    /// catalog. Gates the shortcut verb: a chord no catalog action owns is a
    /// silent no-op, checked before any OS-global injection (docs/traps.md).
    /// It also DISPATCHES every chord, so what the verb gates on and what the
    /// app answers cannot disagree.
    menu_shortcuts: HashMap<String, u64>,
    /// The harness's OPEN context menu: anchor widget id plus the flyout
    /// handle, kept until Closed is awaited — the anchor row may be destroyed
    /// by the very occurrence the activation emits.
    open_context: Option<(u64, MenuFlyout)>,
    /// Coalesced per drain: any op touching the command surface sets
    /// it; one rebuild follows the batch.
    menus_touched: bool,
    /// Accept lists by widget id (the accepts prop; empty = unset = absent
    /// here). The paste split and Paste's enablement both read it.
    accepts: HashMap<u64, String>,
    /// A ROLE surface appeared — an authored role, or a clipboard surface
    /// (accepts / copy / read): the refresh sites consult it, so scenes that
    /// declare no role pay nothing for the recomputation. Not clipboard-only,
    /// because undo's enablement is live in a scene that never touches the
    /// clipboard (docs/undo-plan.md D6).
    roles_armed: bool,
    /// What the LEDGER has been shown for each field — the last text
    /// `bank_text_changed` handed the core.
    ///
    /// THE `type` VERB'S SETTLE READS IT: TextChanged is async here, so a
    /// settle on the control alone let `menu_activate "Edit>Undo"` undo the
    /// STAR GROUP instead of the typing (measured, the first windows leg).
    banked_text: HashMap<u64, String>,
    /// Q2's LEDGER-QUIET BRACKET (docs/undo-plan.md §3, "report it once"):
    /// field id -> the text a native undo THIS BACKEND ROUTED left in the
    /// widget, recorded when the sample was taken.
    ///
    /// A BRACKET AND NOT A FLAG-WITH-A-TIMER: a routed `TextBox.Undo()` raises
    /// TextChanged a runloop turn LATER (7ms, `inside_undo_call=false`).
    ledger_quiet: HashMap<u64, String>,
}

// ---- Text ranges: the two pieces of state that CANNOT live in
// ---- CoreState (docs/ranges-plan.md D2, D4)
//
// Both are written by CONTROL EVENT HANDLERS, and `CORE.with_borrow_mut`
// PANICS on a live borrow — `set_text` writes the control under that borrow,
// and a panic crossing a dispatcher callback aborts rather than unwinds.

thread_local! {
    /// D2'S CLEAR-ON-EDIT: the widget's text when a highlight set was declared
    /// over it; any edit makes it stale and `drop_stale_highlights` unpaints
    /// everything with nothing said. The compare is against the TEXT, never
    /// TextChanged — that event is async here, so an event-driven drop would
    /// destroy every set declared in the same batch as a write
    /// (range-probe-windows.md §5).
    static HIGHLIGHT_TEXT: RefCell<HashMap<u64, String>> = RefCell::new(HashMap::new());

    /// Widgets with a LIVE INPUT-METHOD COMPOSITION, from the control's
    /// own `TextCompositionStarted`/`TextCompositionEnded` (D4): a
    /// composition rides no kaya channel, so only the control knows, and
    /// a `select_range` arriving mid-word is a race the app cannot see.
    static COMPOSING: RefCell<std::collections::HashSet<u64>> =
        RefCell::new(std::collections::HashSet::new());
}

struct WinSection {
    window: u64,
    pane: Grid,
    title: String,
    /// The SEMANTIC ICON (0 = none). Retained because the switcher's item
    /// is minted lazily by `refresh_sections` and re-read there.
    symbol: i64,
    root: Option<UIElement>,
}

/// One navigation entry: a pushed scene root, retained while covered
/// (the wrapper Grid holds it), destroyed at pop. The wrapper's top
/// row is the backend-owned back bar.
struct WinNavEntry {
    window: u64,
    title: String,
    /// The close-veto class transplanted to POP.
    intercept_back: bool,
    wrapper: Option<Grid>,
    back_button: Option<Button>,
}

struct WinLiveAlert {
    window: u64,
    actions: usize,
    dialog: ContentDialog,
}

/// One menu item's retained state (the post-user mirror; see
/// CoreState::menu_models). `primary` is the CHROME-promotion hint
/// (DESIGN.md) that `promoted_items` filters this catalog by
/// (docs/chrome-plan.md C2).
struct MenuModel {
    kind: MenuItemKind,
    label: String,
    enabled: bool,
    checked: bool,
    value: f64,
    primary: bool,
    /// A standard-command role from the closed vocabulary ("" = none).
    /// PLACEMENT is inert here (no dress-owned application menu); the
    /// clipboard roles change BEHAVIOR — activation performs the command
    /// on the focused widget, and enablement folds in role_enabled
    /// (refresh_role_enablement).
    role: String,
    shortcut: String,
    /// The SEMANTIC ICON (spec enum "symbol"; 0 = none). Retained because
    /// `rebuild_menus` builds every native from this model; the harness
    /// reads the materialized item instead (`menu_symbol`).
    symbol: i64,
    children: Vec<u64>,
    parent: Option<u64>,
}

/// An item's materialized WinUI chrome, per the ratified 1:1 lowering.
#[derive(Clone)]
enum MenuNative {
    Bar(MenuBarItem),
    Sub(MenuFlyoutSubItem),
    Action(MenuFlyoutItem),
    Toggle(ToggleMenuFlyoutItem),
    Option(RadioMenuFlyoutItem),
}

impl MenuNative {
    /// The REAL chrome's enablement — what expect_menu reads. The
    /// rebuild stamps the inherited AND onto every native, so this is
    /// the effective value (docs/traps.md, inherited enablement).
    fn is_enabled(&self) -> windows_core::Result<bool> {
        match self {
            MenuNative::Bar(i) => i.IsEnabled(),
            MenuNative::Sub(i) => i.IsEnabled(),
            MenuNative::Action(i) => i.IsEnabled(),
            MenuNative::Toggle(i) => i.IsEnabled(),
            MenuNative::Option(i) => i.IsEnabled(),
        }
    }

    /// The write side of the same flag — what refresh_role_enablement
    /// stamps the intersection enablement through. The rebuild writes
    /// structural enablement alone, so every rebuild is followed by a
    /// role refresh.
    fn set_enabled(&self, on: bool) -> windows_core::Result<()> {
        match self {
            MenuNative::Bar(i) => i.SetIsEnabled(on),
            MenuNative::Sub(i) => i.SetIsEnabled(on),
            MenuNative::Action(i) => i.SetIsEnabled(on),
            MenuNative::Toggle(i) => i.SetIsEnabled(on),
            MenuNative::Option(i) => i.SetIsEnabled(on),
        }
    }

    /// The REAL chrome's icon — what expect_menu_symbol reads through
    /// [`icon_uia_name`]. Never the model: a lowering that decoded the
    /// symbol prop and drew nothing has to fail the assertion.
    fn icon(&self) -> MenuIcon {
        let slot: &dyn IconSlot = match self {
            // The top-level bar grouping has no icon slot at all in WinUI,
            // so its symbol is dropped rather than drawn (the mac arm does
            // put one on its bar holders).
            MenuNative::Bar(_) => return MenuIcon::NoSlot,
            MenuNative::Sub(i) => i,
            MenuNative::Action(i) => i,
            MenuNative::Toggle(i) => i,
            MenuNative::Option(i) => i,
        };
        match slot.icon_element() {
            Ok(icon) => MenuIcon::Present(icon),
            // AN UNSET Icon IS AN `Err` WHOSE HRESULT SAYS SUCCESS: the
            // property returns S_OK with a NULL pointer, which windows-core
            // turns into `Error::empty()`, whose `code()` is `HRESULT(0)` and
            // NOT `E_POINTER` (windows-core 0.62.2 type.rs; windows-result
            // 0.4.1 `S_EMPTY_ERROR`). Only a real failure HRESULT is one.
            Err(e) if e.code().is_ok() => MenuIcon::Empty,
            Err(e) => MenuIcon::Unreadable(e),
        }
    }
}

// --- The semantic icon vocabulary: the FLUENT column -------------------
//
// Every identifier below comes from docs/styling/symbols-fluent.md (the
// extraction, the rendered-shape checks and the member-name traps). Three of
// the twenty concepts have no `Symbol` member and are codepoints; neither
// route sets a FontFamily. UNMEASURED: RTL mirroring of back/forward.
enum FluentIcon {
    /// Route 1: a `Symbol` enum member — 17 of the 20 concepts.
    Member(bindings::Microsoft::UI::Xaml::Controls::Symbol),
    /// Route 2: a Segoe Fluent Icons codepoint, for the three concepts
    /// the enum never got.
    Glyph(&'static str),
}

/// The Fluent spelling of a concept. EXHAUSTIVE ON PURPOSE: a 21st
/// entry in the vocabulary fails the windows build right here rather
/// than compiling into an icon that silently never draws.
const fn fluent_icon(symbol: crate::app::Symbol) -> FluentIcon {
    use bindings::Microsoft::UI::Xaml::Controls::Symbol as Fluent;
    use crate::app::Symbol as S;
    match symbol {
        S::Add => FluentIcon::Member(Fluent::Add),
        S::Remove => FluentIcon::Member(Fluent::Remove),
        S::Delete => FluentIcon::Member(Fluent::Delete),
        S::Edit => FluentIcon::Member(Fluent::Edit),
        S::Done => FluentIcon::Member(Fluent::Accept),
        S::Close => FluentIcon::Member(Fluent::Cancel),
        S::Search => FluentIcon::Member(Fluent::Find),
        S::Settings => FluentIcon::Member(Fluent::Setting),
        S::Refresh => FluentIcon::Member(Fluent::Refresh),
        S::Info => FluentIcon::Glyph("\u{E946}"),
        S::Warning => FluentIcon::Glyph("\u{E7BA}"),
        S::Back => FluentIcon::Member(Fluent::Back),
        S::Forward => FluentIcon::Member(Fluent::Forward),
        S::More => FluentIcon::Member(Fluent::More),
        S::Copy => FluentIcon::Member(Fluent::Copy),
        S::Paste => FluentIcon::Member(Fluent::Paste),
        S::Star => FluentIcon::Member(Fluent::OutlineStar),
        S::Lock => FluentIcon::Glyph("\u{E72E}"),
        S::Person => FluentIcon::Member(Fluent::Contact),
        S::Home => FluentIcon::Member(Fluent::Home),
    }
}

/// A concept's WIRE id — the spec's number by way of `wire`, never a
/// literal. Exhaustive for the same reason as [`fluent_icon`].
const fn symbol_wire(symbol: crate::app::Symbol) -> u32 {
    use crate::app::Symbol as S;
    match symbol {
        S::Add => crate::wire::SYMBOL_ADD,
        S::Remove => crate::wire::SYMBOL_REMOVE,
        S::Delete => crate::wire::SYMBOL_DELETE,
        S::Edit => crate::wire::SYMBOL_EDIT,
        S::Done => crate::wire::SYMBOL_DONE,
        S::Close => crate::wire::SYMBOL_CLOSE,
        S::Search => crate::wire::SYMBOL_SEARCH,
        S::Settings => crate::wire::SYMBOL_SETTINGS,
        S::Refresh => crate::wire::SYMBOL_REFRESH,
        S::Info => crate::wire::SYMBOL_INFO,
        S::Warning => crate::wire::SYMBOL_WARNING,
        S::Back => crate::wire::SYMBOL_BACK,
        S::Forward => crate::wire::SYMBOL_FORWARD,
        S::More => crate::wire::SYMBOL_MORE,
        S::Copy => crate::wire::SYMBOL_COPY,
        S::Paste => crate::wire::SYMBOL_PASTE,
        S::Star => crate::wire::SYMBOL_STAR,
        S::Lock => crate::wire::SYMBOL_LOCK,
        S::Person => crate::wire::SYMBOL_PERSON,
        S::Home => crate::wire::SYMBOL_HOME,
    }
}

/// The vocabulary in wire order — the decode side's only list.
const SYMBOL_ORDER: [crate::app::Symbol; 20] = {
    use crate::app::Symbol as S;
    [
        S::Add, S::Remove, S::Delete, S::Edit, S::Done, S::Close, S::Search, S::Settings,
        S::Refresh, S::Info, S::Warning, S::Back, S::Forward, S::More, S::Copy, S::Paste, S::Star,
        S::Lock, S::Person, S::Home,
    ]
};

/// THE COMPILE-TIME PIN that makes the array above safe to hand-write:
/// position by position, `SYMBOL_ORDER[i]`'s wire id must equal
/// `wire::SYMBOLS[i]`'s. A 21st concept, a renumbered one, or a repeated
/// entry all fail to build here.
const _: () = {
    assert!(
        SYMBOL_ORDER.len() == crate::wire::SYMBOLS.len(),
        "the symbol vocabulary grew: add the new concept to SYMBOL_ORDER \
         and give it a Fluent spelling in fluent_icon (crates/kaya/src/winui/mod.rs)"
    );
    let mut i = 0;
    while i < SYMBOL_ORDER.len() {
        assert!(
            symbol_wire(SYMBOL_ORDER[i]) == crate::wire::SYMBOLS[i].0,
            "SYMBOL_ORDER disagrees with wire::SYMBOLS on a wire id \
             (crates/kaya/src/winui/mod.rs)"
        );
        i += 1;
    }
};

/// The concept a wire value names, or None for the unset slot (0).
fn symbol_from_wire(value: i64) -> Option<crate::app::Symbol> {
    SYMBOL_ORDER
        .into_iter()
        .find(|s| i64::from(symbol_wire(*s)) == value)
}

/// The platform icon for a wire symbol value, carrying THE SEMANTIC NAME as
/// its UIA name.
///
/// That name is the OBSERVATION CHANNEL: `menu_symbol` reads it back off the
/// live element's automation peer, so reading kaya's own model instead would
/// agree with itself no matter what was drawn.
fn symbol_icon(value: i64) -> windows_core::Result<Option<IconElement>> {
    let Some(symbol) = symbol_from_wire(value) else {
        return Ok(None);
    };
    let Some(name) = crate::wire::symbol_name(value) else {
        return Ok(None);
    };
    let element: IconElement = match fluent_icon(symbol) {
        FluentIcon::Member(member) => {
            let icon = SymbolIcon::new()?;
            icon.SetSymbol(member)?;
            icon.cast()?
        }
        FluentIcon::Glyph(glyph) => {
            // NO FontFamily on purpose: an unset one resolves through
            // SymbolThemeFontFamily, the theme resource that also carries
            // the Windows 10 fallback (docs/styling/typeface-winui.md).
            let icon = FontIcon::new()?;
            icon.SetGlyph(&HSTRING::from(glyph))?;
            icon.cast()?
        }
    };
    bindings::Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(
        &element,
        &HSTRING::from(name),
    )?;
    Ok(Some(element))
}

/// The controls with an `Icon` slot, as one surface — WinUI puts `Icon`
/// on each class separately with no common base. The impl list is the
/// honest statement of WHICH kinds have the slot: `MenuBarItem` is absent
/// because it has none in the pinned metadata.
trait IconSlot {
    fn set_icon_element(&self, icon: &IconElement) -> windows_core::Result<()>;
    /// `Err` for an EMPTY slot as much as for a failure. Callers that
    /// need to tell the two apart compare the code (see [`MenuIcon`]).
    fn icon_element(&self) -> windows_core::Result<IconElement>;
}

macro_rules! icon_slot {
    ($($ty:ty),+ $(,)?) => {$(
        impl IconSlot for $ty {
            fn set_icon_element(&self, icon: &IconElement) -> windows_core::Result<()> {
                self.SetIcon(icon)
            }
            fn icon_element(&self) -> windows_core::Result<IconElement> {
                self.Icon()
            }
        }
    )+};
}

// THE WINUI 3 HIERARCHY IS NOT THE UWP ONE: in the pinned WinUI 2.2.1
// metadata `ToggleMenuFlyoutItem` derives from `MenuFlyoutItem` (UWP's does
// not), so the checkable kind and the radio option inherit the icon slot.
// Read from the metadata, not the UWP documentation a search finds first.
icon_slot!(
    MenuFlyoutItem,
    ToggleMenuFlyoutItem,
    RadioMenuFlyoutItem,
    MenuFlyoutSubItem,
    NavigationViewItem,
    AppBarButton,
);

/// Stamp a concept onto a control's icon slot. One place, so an unset
/// symbol is simply no icon.
fn apply_symbol(target: &impl IconSlot, symbol: i64) -> windows_core::Result<()> {
    let Some(icon) = symbol_icon(symbol)? else {
        return Ok(());
    };
    target.set_icon_element(&icon)
}

/// What an item's icon slot holds — four outcomes, kept apart because
/// they fail for four different reasons and the harness prints the one
/// it measured.
enum MenuIcon {
    Present(IconElement),
    /// The slot exists and is empty.
    Empty,
    /// The item's KIND has no icon slot on this platform.
    NoSlot,
    /// Reading the slot failed for a reason that is not emptiness.
    Unreadable(windows_core::Error),
}

/// The semantic name an icon element publishes to UIA — the read half of
/// [`symbol_icon`]. TOTAL: every failure is a short description of WHAT
/// WAS MEASURED, and the three answers are kept distinguishable.
fn icon_uia_name(icon: &IconElement) -> String {
    let Ok(fe) = icon.cast::<bindings::Microsoft::UI::Xaml::FrameworkElement>() else {
        return "the icon element is not a FrameworkElement".to_owned();
    };
    uia_name(&fe, "the icon")
}

/// The name any live element publishes to UIA — what an assistive client
/// hears — or a short description of which of the three ways the read
/// failed. `what` names the thing being read so the sentence says what it
/// measured ("the icon", "the toolbar button Save"). TOTAL, and the three
/// answers are kept distinguishable because they fail differently.
fn uia_name(fe: &FrameworkElement, what: &str) -> String {
    use bindings::Microsoft::UI::Xaml::Automation::Peers::FrameworkElementAutomationPeer;
    // CreatePeerForElement first, FromElement second — the `ax` read's
    // ladder: an element with no peer class of its own (a Grid there, an
    // icon here) has no peer until one is made, and FromElement alone
    // reported such elements absent from a tree UIA will describe.
    let peer = match FrameworkElementAutomationPeer::CreatePeerForElement(fe) {
        Ok(p) => p,
        Err(_) => match FrameworkElementAutomationPeer::FromElement(fe) {
            Ok(p) => p,
            // Same success-coded-error rule as MenuIcon::Empty: a NULL
            // peer means the element genuinely has none, while a failure
            // HRESULT means the call itself broke.
            Err(e) if e.code().is_ok() => {
                return format!("{what} has no automation peer")
            }
            Err(e) => return format!("{what}'s automation peer could not be made: {e}"),
        },
    };
    // An element with no name publishes the EMPTY string, not an error:
    // HSTRING is a clone type, so a null handle arrives as `Ok("")`
    // (windows-core 0.62.2 src/type.rs, the CloneType `from_abi`).
    match peer.GetName() {
        Ok(name) if name.is_empty() => {
            format!("{what} publishes no accessibility name")
        }
        Ok(name) => name.to_string(),
        Err(e) => format!("{what}'s accessibility name could not be read: {e}"),
    }
}

impl Drop for CoreState {
    fn drop(&mut self) {
        self.occurrences.send(Occurrence::Shutdown);
    }
}

thread_local! {
    static CORE: RefCell<Option<CoreState>> = const { RefCell::new(None) };
    /// Whether the two presentation edges are wired yet
    /// (`presentation_report`). UI thread only, like CORE.
    static PRESENTATION_WATCHED: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    /// A canvas-track report is already queued for this turn, because
    /// LayoutUpdated fires per canvas per pass.
    static CANVAS_TRACKS_DUE: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    /// Whether the platform's frame drive is attached
    /// (`attach_frame_drive`). UI thread only, like CORE.
    static FRAME_DRIVE_ATTACHED: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    /// A window-metrics report is already queued for this turn, for the
    /// same per-pass LayoutUpdated fan.
    static WINDOW_METRICS_DUE: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// The UI thread's dispatcher, for waking it from other threads.
/// DispatcherQueue is agile (TryEnqueue is documented thread-safe); the
/// wrapper asserts that to the type system.
struct SharedDispatcher(DispatcherQueue);
unsafe impl Send for SharedDispatcher {}
unsafe impl Sync for SharedDispatcher {}

static DISPATCHER: OnceLock<SharedDispatcher> = OnceLock::new();

/// Exit code for when Application::Start returns. Clean shutdown goes
/// through Application::Exit on the UI thread; calling process::exit from
/// inside XAML dispatch tears down under the framework's feet (observed as
/// an access violation in XAML rundown).
static EXIT_CODE: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(0);
/// Whether EXIT_CODE has been claimed — see request_exit.
static EXIT_DECIDED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

// The composed Application, kept from CreateInstance: the composition
// outer (KayaOuter) answers its own interfaces and forwards the rest, so
// Application::Current() — whose identity is the outer — cannot be cast
// back to Application. UI thread only.
thread_local! {
    static APP: RefCell<Option<Application>> = const { RefCell::new(None) };
}

fn request_exit(code: i32) {
    // First writer wins: Application.Exit() closes the window, which
    // fires Closed, which calls back in here with 0, and a plain store
    // would overwrite a failing verdict's 1 — a FAILED scene then reports
    // PASS (docs/traps.md).
    if !EXIT_DECIDED.swap(true, std::sync::atomic::Ordering::Relaxed) {
        EXIT_CODE.store(code, std::sync::atomic::Ordering::Relaxed);
    }
    APP.with_borrow(|app| match app.as_ref() {
        Some(app) => {
            if let Err(e) = app.Exit() {
                eprintln!("kaya: winui Application.Exit failed: {}", e.message());
            }
        }
        None => eprintln!("kaya: winui request_exit before the app existed"),
    });
}

/// Wake the UI thread so it drains pending transactions. Safe to call
/// from any thread.
pub(crate) fn ring_doorbell() {
    if let Some(dispatcher) = DISPATCHER.get() {
        let handler = DispatcherQueueHandler::new(|| {
            drain_transactions();
            Ok(())
        });
        let _ = dispatcher.0.TryEnqueue(&handler);
    }
}

/// Recompute the clipboard roles' enablement ONE TICK LATER. The callers
/// are event handlers that can fire while CORE is borrowed — a Focus()
/// inside apply raises GotFocus, and the WNDPROC re-enters CORE by
/// construction — so neither may borrow here and now.
fn defer_role_refresh() {
    if let Some(dispatcher) = DISPATCHER.get() {
        let handler = DispatcherQueueHandler::new(|| {
            CORE.with_borrow(|core| {
                if let Some(core) = core.as_ref() {
                    if core.roles_armed {
                        refresh_role_enablement(core);
                    }
                }
            });
            Ok(())
        });
        let _ = dispatcher.0.TryEnqueue(&handler);
    }
}

/// THE WINDOW'S SCALE AND APPEARANCE, reported to the core, which
/// re-rasters every canvas at them (docs/canvas-plan.md §5, §6). Only
/// these two numbers cross: no platform colour reaches a drawing.
/// `XamlRoot.RasterizationScale` is this platform's density reading —
/// what `WM_DPICHANGED` moves — and `ActualTheme` the appearance, the
/// same reading `canvas_ink`'s answer names.
fn presentation_report(core: &mut CoreState) -> windows_core::Result<()> {
    let Ok(root) = core.window.Content() else { return Ok(()) };
    let element: FrameworkElement = windows_core::Interface::cast(&root)?;
    // The harness appearance, on the SAME element whose ActualTheme this
    // function reads. ELEMENT SCOPE, NOT APPLICATION SCOPE:
    // Application.RequestedTheme throws if set while the app runs, and kaya's
    // content root arrives with the app's FIRST MOUNT. Re-applied per report
    // and only when it differs, so it cannot loop through the
    // ActualThemeChanged edge below (tools/check-appearance.py).
    if let Some(mode) = crate::canvas::appearance_override() {
        let want = match mode {
            crate::canvas::Mode::Dark => ElementTheme::Dark,
            crate::canvas::Mode::Light => ElementTheme::Light,
        };
        if element.RequestedTheme()? != want {
            element.SetRequestedTheme(want)?;
        }
    }
    // THE TWO EDGES, wired the first time there is a XamlRoot to wire one of
    // them to: Windows delivers a DPI change per top-level window and a theme
    // change per element. THE FLAG FOLLOWS THE XamlRoot, not the content: an
    // element can be Content before it is in a live tree, and a run that took
    // the flag on that pass would never wire the DPI edge at all.
    if !PRESENTATION_WATCHED.get() {
        if let Ok(xaml_root) = root.XamlRoot() {
            PRESENTATION_WATCHED.set(true);
            let _ = xaml_root.Changed(&TypedEventHandler::new(|_, _| {
                report_presentation_now();
                Ok(())
            }));
            let _ = element.ActualThemeChanged(&TypedEventHandler::new(|_, _| {
                report_presentation_now();
                Ok(())
            }));
        }
    }
    let scale = root
        .XamlRoot()
        .and_then(|xaml_root| xaml_root.RasterizationScale())
        .unwrap_or(crate::canvas::CANONICAL_SCALE);
    let mode = if element.ActualTheme()? == ElementTheme::Dark {
        crate::canvas::Mode::Dark
    } else {
        crate::canvas::Mode::Light
    };
    let ops = crate::fault::guard("reporting the window's scale and appearance", || {
        core.scene.set_presentation(crate::canvas::Presentation { scale, mode })
    })
    .unwrap_or_default();
    for op in ops {
        let what = op_head(&op);
        if let Err(e) = apply(core, op) {
            crate::fault::report(format!("kaya: applying {what} failed: {e}"));
            return Ok(());
        }
    }
    Ok(())
}

/// The report, from a XAML event handler: those run on the UI thread but
/// can land in a turn that already holds the CORE borrow, so this takes
/// it only if it is free and lets the next event carry it otherwise.
fn report_presentation_now() {
    CORE.with(|slot| {
        let Ok(mut core) = slot.try_borrow_mut() else { return };
        let Some(core) = core.as_mut() else { return };
        if let Err(e) = presentation_report(core) {
            crate::fault::report(format!("kaya: reporting the presentation failed: {e}"));
        }
    });
}

/// WHAT LAYOUT ASSIGNED ONE CANVAS, in points (docs/canvas-plan.md §3.2.1).
/// A GROWN CANVAS'S TRACK IS ITS LAYOUT SLOT, never its arranged box:
/// `set_drawing` gives the Image an explicit size from the BUFFER, a HARD
/// constraint in XAML, so `ActualWidth` would answer the raster's own size.
/// AN UNGROWN CANVAS IS ITS OWN BOX — its track IS its viewbox, where the
/// slot would answer the whole COLUMN's width instead.
fn canvas_track_of(core: &CoreState, id: WidgetId, image: &Image) -> Option<(f64, f64)> {
    let element: FrameworkElement = windows_core::Interface::cast(image).ok()?;
    if core.grow.get(&id).copied().unwrap_or(0.0) > 0.0 {
        let slot = LayoutInformation::GetLayoutSlot(&element).ok()?;
        return Some((f64::from(slot.Width), f64::from(slot.Height)));
    }
    Some((element.ActualWidth().ok()?, element.ActualHeight().ok()?))
}

/// Every live canvas's track, reported to the core. A report that changes
/// nothing emits nothing, so a missed layout edge is harmless. The registries
/// are PUSH-ONLY, so a destroyed canvas is skipped by asking `widgets` rather
/// than by shrinking them.
fn report_canvas_tracks(core: &mut CoreState) {
    for i in 0..core.canvas_ids.len() {
        let id = WidgetId(core.canvas_ids[i]);
        if !core.widgets.contains_key(&id) {
            continue;
        }
        let image = core.canvases[i].clone();
        let Some(size) = canvas_track_of(core, id, &image) else {
            continue;
        };
        let reported = crate::fault::guard("reporting a canvas's assigned track", || {
            core.scene.set_canvas_track(id, size)
        });
        let Some((ops, asks)) = reported else { continue };
        for op in ops {
            let what = op_head(&op);
            if let Err(e) = apply(core, op) {
            crate::fault::report(format!("kaya: applying {what} failed: {e}"));
                return;
            }
        }
        for occ in asks {
            core.occurrences.send(occ);
        }
    }
}

/// Every window's content width, reported to the core for breakpoint
/// evaluation (docs/adaptive-layout-plan.md D3). A same-width report is
/// silent in the core, so re-asking on every layout pass is free.
fn report_window_metrics(core: &mut CoreState) {
    // A mounted root's key is a SURFACE — the primary or an aux window's
    // own id, a pushed entry's, a section's — and the width that governs
    // a breakpoint is the OWNING WINDOW's: an entry id handed to
    // window_client_width answers None (docs/traps.md, docs/
    // adaptive-layout-plan.md:217).
    let mut windows: Vec<u64> = core
        .mounted_roots
        .keys()
        .map(|&surface| {
            if let Some(entry) = core.nav_entries.get(&surface) {
                entry.window
            } else if let Some(section) = core.section_panes.get(&surface) {
                section.window
            } else {
                surface
            }
        })
        .collect();
    windows.sort_unstable();
    windows.dedup();
    for window in windows {
        let Some(width) = window_client_width(core, window) else {
            continue;
        };
        if width <= 0.0 {
            continue;
        }
        let reported = crate::fault::guard("reporting the window's content size", || {
            core.scene.set_window_metrics(
                crate::protocol::WindowId(window),
                width,
                i64::from(crate::wire::SIZE_CLASS_NONE),
            )
        });
        let Some(ops) = reported else { continue };
        for op in ops {
            let what = op_head(&op);
            if let Err(e) = apply(core, op) {
            crate::fault::report(format!("kaya: applying {what} failed: {e}"));
                return;
            }
        }
    }
}

/// The report applies ops, which must not run inside the layout pass
/// that provoked it.
fn schedule_window_metrics() {
    if WINDOW_METRICS_DUE.replace(true) {
        return;
    }
    let Some(dispatcher) = DISPATCHER.get() else {
        WINDOW_METRICS_DUE.set(false);
        return;
    };
    let handler = DispatcherQueueHandler::new(move || {
        WINDOW_METRICS_DUE.set(false);
        CORE.with_borrow_mut(|core| {
            if let Some(core) = core.as_mut() {
                report_window_metrics(core);
            }
        });
        Ok(())
    });
    let _ = dispatcher.0.TryEnqueue(&handler);
}

/// The report, coalesced onto the dispatcher: LayoutUpdated fires once
/// per canvas per layout PASS, and the report can apply a re-raster,
/// which must not run inside the pass that provoked it.
fn schedule_canvas_tracks() {
    if CANVAS_TRACKS_DUE.replace(true) {
        return;
    }
    let Some(dispatcher) = DISPATCHER.get() else {
        CANVAS_TRACKS_DUE.set(false);
        return;
    };
    let handler = DispatcherQueueHandler::new(move || {
        CANVAS_TRACKS_DUE.set(false);
        CORE.with_borrow_mut(|core| {
            if let Some(core) = core.as_mut() {
                report_canvas_tracks(core);
            }
        });
        Ok(())
    });
    let _ = dispatcher.0.TryEnqueue(&handler);
}

/// THE PLATFORM'S FRAME DRIVE, outside the harness (docs/canvas-plan.md
/// §15.4): `RenderingEventArgs.RenderingTime` is what the tick carries, since
/// a clock read inside the callback re-imports the jitter a frame time
/// removes. NOT UNDER THE HARNESS, where a scene's frame count is what the
/// `frame` verb advanced. ONCE PER PROCESS, attached at the first canvas,
/// because a subscription holds the compositor in a continuous render loop.
fn attach_frame_drive() {
    if std::env::var("KAYA_SELFTEST").is_ok() || FRAME_DRIVE_ATTACHED.replace(true) {
        return;
    }
    let rendering = EventHandler::<windows_core::IInspectable>::new(move |_, args| {
        let Some(args) = args.as_ref() else { return Ok(()) };
        let Ok(frame) = windows_core::Interface::cast::<RenderingEventArgs>(args) else {
            return Ok(());
        };
        let Ok(time) = frame.RenderingTime() else { return Ok(()) };
        // TimeSpan is in hundreds of nanoseconds; the core's clock is
        // seconds (§15.4).
        drive_frame(time.Duration as f64 / 1e7);
        Ok(())
    });
    if let Err(e) = CompositionTarget::Rendering(&rendering) {
        FRAME_DRIVE_ATTACHED.set(false);
        crate::fault::report(format!("kaya: attaching the frame drive failed: {e}"));
    }
}

fn drive_frame(time: f64) {
    if !time.is_finite() {
        return;
    }
    CORE.with(|slot| {
        let Ok(mut core) = slot.try_borrow_mut() else { return };
        let Some(core) = core.as_mut() else { return };
        let ticks = crate::fault::guard("driving a frame", || core.scene.frame(time))
            .unwrap_or_default();
        for occ in ticks {
            core.occurrences.send(occ);
        }
    });
}

fn drain_transactions() {
    CORE.with_borrow_mut(|core| {
        let Some(core) = core.as_mut() else { return };
        // THE UNWIND STOPS HERE: every route in is a XAML callback — the
        // DispatcherQueue handler above, the WNDPROC — and none of them
        // can unwind, so a panic aborts with exit 0xC0000409 and no
        // verdict list (crates/kaya/src/fault.rs; docs/deferred.md).
        crate::fault::guard("draining a transaction", || {
            let mut failed = false;
            'drain: while let Ok(tx) = core.transactions.try_recv() {
                for op in core.scene.apply(tx) {
                    let what = op_head(&op);
                    if let Err(e) = apply(core, op) {
                        crate::fault::report(format!(
                            "kaya: applying {what} failed: {e}"
                        ));
                        failed = true;
                        break 'drain;
                    }
                }
                // A canvas that became a redraw one with its track
                // already known (docs/canvas-plan.md §3.2.1).
                for occ in core.scene.take_asks() {
                    core.occurrences.send(occ);
                }
            }
            // ONE coalesced track re-stamp for the whole drain — the
            // batch boundary the deferred reindex is deferred TO
            // (winui/order.rs). It runs even after a failed op, because a
            // half-applied batch that skipped it would leave the window's
            // Grid tracks stale on top of incomplete.
            if let Err(e) = flush_tracks(core) {
                crate::fault::report(format!(
                    "kaya: restamping the container tracks failed: {e}"
                ));
                return;
            }
            if failed {
                return;
            }
            // ONE coalesced menu-chrome rebuild per drain, from the
            // post-user mirror. Quiet-armed: constructing and stamping
            // native items must never read as user activation.
            if core.menus_touched {
                core.menus_touched = false;
                core.apply_quiet
                    .store(true, std::sync::atomic::Ordering::Relaxed);
                let rebuilt = rebuild_menus(core);
                core.apply_quiet
                    .store(false, std::sync::atomic::Ordering::Relaxed);
                if let Err(e) = rebuilt {
                    crate::fault::report(format!(
                        "kaya: rebuilding the menu chrome failed: {e}"
                    ));
                    return;
                }
            }
            // ONE coalesced table pass per drain: rows, cell texts and
            // declared titles can all have moved, and the column tracks
            // are computed from all three.
            sync_tables(core);
            // AND THE PRESENTATION, last: a window has no XamlRoot until
            // something is mounted, so the first drain is where the scale
            // and the appearance become askable at all, and it is what
            // wires the two edges (docs/canvas-plan.md §5, §6).
            if let Err(e) = presentation_report(core) {
                crate::fault::report(format!("kaya: reporting the presentation failed: {e}"));
            }
            // AND EVERY CANVAS'S TRACK: a canvas created in this batch
            // has no layout yet, so the real report comes off
            // LayoutUpdated — but a layout edge that lands while the core
            // is borrowed is dropped, and re-asking makes that harmless
            // (§3.2.1).
            report_canvas_tracks(core);
        });
    });
}

/// The head of an op's `Debug`, for a fault sentence. TRUNCATED because
/// a whole one carries the document a `SetText` holds.
fn op_head(op: &ApplyOp) -> String {
    let text = format!("{op:?}");
    match text.char_indices().nth(120) {
        Some((i, _)) => format!("{}…", &text[..i]),
        None => text,
    }
}

/// The minimal TextBox template: text editing needs only the
/// ScrollViewer named ContentElement; everything else of the default
/// chrome is styling this unpackaged app cannot resource-resolve.
const ENTRY_STYLE_XAML: &str = r#"<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="TextBox">
  <Setter Property="MinWidth" Value="160"/>
  <Setter Property="Padding" Value="6,4,6,4"/>
  <Setter Property="Template">
    <Setter.Value>
      <ControlTemplate TargetType="TextBox">
        <Border Background="{TemplateBinding Background}" BorderBrush="Gray" BorderThickness="1" CornerRadius="4">
          <ScrollViewer x:Name="ContentElement" Padding="{TemplateBinding Padding}" VerticalAlignment="Center"/>
        </Border>
      </ControlTemplate>
    </Setter.Value>
  </Setter>
</Style>"#;

/// The load-bearing piece of code-only WinUI: the XAML parser resolves
/// non-core types through an IXamlMetadataProvider it QIs off the Application
/// object, and without one deferred theme XAML fail-fasts the process
/// (docs/traps.md; microsoft-ui-xaml #7357/#8151). HAND-ROLLED, not
/// #[implement], because the Application is composed via COM aggregation with
/// this object as the outer (docs/traps.md, the NavigationView saga).
#[repr(C)]
struct KayaOuter {
    identity: *const windows_core::IInspectable_Vtbl,
    overrides: *const bindings::Microsoft::UI::Xaml::IApplicationOverrides_Vtbl,
    metadata: *const bindings::Microsoft::UI::Xaml::Markup::IXamlMetadataProvider_Vtbl,
    /// The inner's non-delegating IUnknown/IInspectable, set once
    /// after CreateInstance; QIs the outer cannot answer forward
    /// here. Null only during CreateInstance itself.
    inner: std::cell::Cell<*mut core::ffi::c_void>,
    // Lazily created: the provider activates WinUI machinery that is
    // not ready until the application object exists.
    provider: RefCell<
        Option<bindings::Microsoft::UI::Xaml::XamlTypeInfo::XamlControlsXamlMetaDataProvider>,
    >,
}

static KAYA_OUTER_IDENTITY_VTBL: windows_core::IInspectable_Vtbl =
    windows_core::IInspectable_Vtbl {
        base: windows_core::IUnknown_Vtbl {
            QueryInterface: outer_qi::<0>,
            AddRef: outer_addref,
            Release: outer_release,
        },
        GetIids: outer_get_iids,
        GetRuntimeClassName: outer_get_class_name,
        GetTrustLevel: outer_get_trust_level,
    };

static KAYA_OUTER_OVERRIDES_VTBL: bindings::Microsoft::UI::Xaml::IApplicationOverrides_Vtbl =
    bindings::Microsoft::UI::Xaml::IApplicationOverrides_Vtbl {
        base__: windows_core::IInspectable_Vtbl {
            base: windows_core::IUnknown_Vtbl {
                QueryInterface: outer_qi::<1>,
                AddRef: outer_addref,
                Release: outer_release,
            },
            GetIids: outer_get_iids,
            GetRuntimeClassName: outer_get_class_name,
            GetTrustLevel: outer_get_trust_level,
        },
        OnLaunched: outer_on_launched,
    };

static KAYA_OUTER_METADATA_VTBL:
    bindings::Microsoft::UI::Xaml::Markup::IXamlMetadataProvider_Vtbl =
    bindings::Microsoft::UI::Xaml::Markup::IXamlMetadataProvider_Vtbl {
        base__: windows_core::IInspectable_Vtbl {
            base: windows_core::IUnknown_Vtbl {
                QueryInterface: outer_qi::<2>,
                AddRef: outer_addref,
                Release: outer_release,
            },
            GetIids: outer_get_iids,
            GetRuntimeClassName: outer_get_class_name,
            GetTrustLevel: outer_get_trust_level,
        },
        GetXamlType: outer_get_xaml_type,
        GetXamlTypeByFullName: outer_get_xaml_type_by_full_name,
        GetXmlnsDefinitions: outer_get_xmlns_definitions,
    };

unsafe fn outer_from_slot<const SLOT: isize>(this: *mut core::ffi::c_void) -> *const KayaOuter {
    unsafe { (this as *mut *const core::ffi::c_void).offset(-SLOT) as *const KayaOuter }
}

unsafe extern "system" fn outer_qi<const SLOT: isize>(
    this: *mut core::ffi::c_void,
    iid: *const windows_core::GUID,
    out: *mut *mut core::ffi::c_void,
) -> windows_core::HRESULT {
    use windows_core::Interface;
    unsafe {
        if out.is_null() {
            return windows_core::imp::E_POINTER;
        }
        let outer = outer_from_slot::<SLOT>(this);
        let iid = &*iid;
        let slot: isize = if *iid == windows_core::IUnknown::IID
            || *iid == windows_core::IInspectable::IID
        {
            0
        } else if *iid
            == <bindings::Microsoft::UI::Xaml::IApplicationOverrides as Interface>::IID
        {
            1
        } else if *iid
            == <bindings::Microsoft::UI::Xaml::Markup::IXamlMetadataProvider as Interface>::IID
        {
            2
        } else {
            -1
        };
        if slot >= 0 {
            *out = (outer as *mut *const core::ffi::c_void).offset(slot)
                as *mut core::ffi::c_void;
            return windows_core::HRESULT(0);
        }
        // The aggregation contract: everything else is the inner's
        // business, through its NON-delegating IUnknown.
        let inner = (*outer).inner.get();
        if !inner.is_null() {
            let vtbl = *(inner as *mut *const windows_core::IUnknown_Vtbl);
            return ((*vtbl).QueryInterface)(inner, iid, out);
        }
        *out = core::ptr::null_mut();
        windows_core::imp::E_NOINTERFACE
    }
}

unsafe extern "system" fn outer_addref(_this: *mut core::ffi::c_void) -> u32 {
    // Process-lifetime object; the count is nominal.
    2
}

unsafe extern "system" fn outer_release(_this: *mut core::ffi::c_void) -> u32 {
    1
}

unsafe extern "system" fn outer_get_iids(
    _this: *mut core::ffi::c_void,
    count: *mut u32,
    values: *mut *mut windows_core::GUID,
) -> windows_core::HRESULT {
    unsafe {
        *count = 0;
        *values = core::ptr::null_mut();
    }
    windows_core::HRESULT(0)
}

unsafe extern "system" fn outer_get_class_name(
    _this: *mut core::ffi::c_void,
    value: *mut *mut core::ffi::c_void,
) -> windows_core::HRESULT {
    let name = windows_core::HSTRING::from("Microsoft.UI.Xaml.Application");
    unsafe {
        *value = core::mem::transmute::<windows_core::HSTRING, *mut core::ffi::c_void>(name);
    }
    windows_core::HRESULT(0)
}

unsafe extern "system" fn outer_get_trust_level(
    _this: *mut core::ffi::c_void,
    value: *mut i32,
) -> windows_core::HRESULT {
    unsafe { *value = 0 };
    windows_core::HRESULT(0)
}

impl KayaOuter {
    fn provider(
        &self,
    ) -> windows_core::Result<
        bindings::Microsoft::UI::Xaml::XamlTypeInfo::XamlControlsXamlMetaDataProvider,
    > {
        let mut slot = self.provider.borrow_mut();
        if slot.is_none() {
            *slot = Some(
                bindings::Microsoft::UI::Xaml::XamlTypeInfo::XamlControlsXamlMetaDataProvider::new()?,
            );
        }
        Ok(slot.as_ref().expect("just filled").clone())
    }

    fn raw_provider(
        &self,
    ) -> windows_core::Result<bindings::Microsoft::UI::Xaml::Markup::IXamlMetadataProvider> {
        use windows_core::Interface;
        self.provider()?.cast()
    }
}

/// Whether the framework's control resources were merged at launch, and
/// if not, why. Recorded ONCE by outer_on_launched; read by
/// require_control_resources. A process-global rather than CoreState,
/// because the merge happens in OnLaunched — before CORE holds anything.
static CONTROL_RESOURCES: OnceLock<Result<(), String>> = OnceLock::new();

/// Refuse to build chrome whose default style lives in the resources this
/// process could not load, and SAY SO (docs/traps.md: WinUI resource
/// resolution is anchored to the PROCESS exe's directory). WHAT "log and
/// continue" COSTS: a bare `RaiseFailFastException` LATER, on a layout tick,
/// with no message and pointing at the wrong step (docs/traps.md: A
/// logged-and-continued control-resource merge fail-fasts LATER).
fn require_control_resources(surface: &str) {
    let Some(Err(why)) = CONTROL_RESOURCES.get() else {
        return;
    };
    panic!(
        "kaya: winui: {surface}, but the Windows App SDK control \
         resources are not loaded, so XAML has no default style for the \
         menu chrome. Realizing it fail-fasts the process with \
         0xc000027b on a later layout tick — after the window is on \
         screen, with no message — so kaya refuses here instead. \
         XamlControlsResources could not be merged at launch: {why}. It \
         loads through ms-appx, and ms-appx in an unpackaged process \
         resolves against the directory of the EXECUTABLE — not the \
         dll, not the working directory. Put kaya's resources.pri beside \
         the exe that runs this app; a host that launches from a \
         temporary or build-output directory (`go run`, a dotnet apphost \
         under bin/) must build or copy its exe next to the pri instead. \
         See docs/traps.md, \"WinUI resource resolution is anchored to \
         the PROCESS exe's directory\"."
    );
}

unsafe extern "system" fn outer_on_launched(
    this: *mut core::ffi::c_void,
    _args: *mut core::ffi::c_void,
) -> windows_core::HRESULT {
    let _ = unsafe { outer_from_slot::<1>(this) };
    // Merge the framework's control resources once, at launch: a code-only
    // app has no App.xaml to do it. TIERED because XamlControlsResources
    // resolves through ms-appx, which needs the exe-adjacent resources.pri
    // (docs/traps.md), so where it fails kaya RECORDS THE REASON and
    // continues — the reason turns the eventual death into a sentence.
    let launched: windows_core::Result<()> = APP.with_borrow(|app| {
        let Some(app) = app.as_ref() else {
            return Ok(());
        };
        let merged: windows_core::Result<()> = (|| {
            let resources =
                bindings::Microsoft::UI::Xaml::Controls::XamlControlsResources::new()?;
            app.Resources()?.MergedDictionaries()?.Append(&resources)?;
            Ok(())
        })();
        let outcome = match &merged {
            Ok(()) => Ok(()),
            Err(e) => {
                eprintln!(
                    "kaya: winui XamlControlsResources unavailable ({})",
                    e.message()
                );
                Err(e.message())
            }
        };
        let _ = CONTROL_RESOURCES.set(outcome);
        Ok(())
    });
    launched.into()
}

unsafe extern "system" fn outer_get_xaml_type(
    this: *mut core::ffi::c_void,
    type_name: core::mem::MaybeUninit<bindings::Windows::UI::Xaml::Interop::TypeName>,
    out: *mut *mut core::ffi::c_void,
) -> windows_core::HRESULT {
    use windows_core::Interface;
    unsafe {
        let outer = outer_from_slot::<2>(this);
        match (*outer).raw_provider() {
            Ok(provider) => {
                let vtbl = *(provider.as_raw()
                    as *mut *const bindings::Microsoft::UI::Xaml::Markup::IXamlMetadataProvider_Vtbl);
                ((*vtbl).GetXamlType)(provider.as_raw(), type_name, out)
            }
            Err(e) => e.into(),
        }
    }
}

unsafe extern "system" fn outer_get_xaml_type_by_full_name(
    this: *mut core::ffi::c_void,
    full_name: *mut core::ffi::c_void,
    out: *mut *mut core::ffi::c_void,
) -> windows_core::HRESULT {
    use windows_core::Interface;
    unsafe {
        let outer = outer_from_slot::<2>(this);
        match (*outer).raw_provider() {
            Ok(provider) => {
                let vtbl = *(provider.as_raw()
                    as *mut *const bindings::Microsoft::UI::Xaml::Markup::IXamlMetadataProvider_Vtbl);
                ((*vtbl).GetXamlTypeByFullName)(provider.as_raw(), full_name, out)
            }
            Err(e) => e.into(),
        }
    }
}

unsafe extern "system" fn outer_get_xmlns_definitions(
    this: *mut core::ffi::c_void,
    count: *mut u32,
    values: *mut *mut core::mem::MaybeUninit<
        bindings::Microsoft::UI::Xaml::Markup::XmlnsDefinition,
    >,
) -> windows_core::HRESULT {
    use windows_core::Interface;
    unsafe {
        let outer = outer_from_slot::<2>(this);
        match (*outer).raw_provider() {
            Ok(provider) => {
                let vtbl = *(provider.as_raw()
                    as *mut *const bindings::Microsoft::UI::Xaml::Markup::IXamlMetadataProvider_Vtbl);
                ((*vtbl).GetXmlnsDefinitions)(provider.as_raw(), count, values)
            }
            Err(e) => e.into(),
        }
    }
}

/// Construct the Application composed with KayaOuter as the COM
/// aggregation outer: identity QIs route to the outer.
fn compose_application() -> windows_core::Result<Application> {
    use windows_core::Interface;
    let outer: &'static KayaOuter = Box::leak(Box::new(KayaOuter {
        identity: &KAYA_OUTER_IDENTITY_VTBL,
        overrides: &KAYA_OUTER_OVERRIDES_VTBL,
        metadata: &KAYA_OUTER_METADATA_VTBL,
        inner: std::cell::Cell::new(core::ptr::null_mut()),
        provider: RefCell::new(None),
    }));
    let factory = windows_core::factory::<
        Application,
        bindings::Microsoft::UI::Xaml::IApplicationFactory,
    >()?;
    unsafe {
        let mut inner: *mut core::ffi::c_void = core::ptr::null_mut();
        let mut result: *mut core::ffi::c_void = core::ptr::null_mut();
        (Interface::vtable(&factory).CreateInstance)(
            Interface::as_raw(&factory),
            outer as *const KayaOuter as *mut core::ffi::c_void,
            &mut inner,
            &mut result,
        )
        .ok()?;
        // The non-delegating inner: the QI fallback target. Owned by
        // the composition for the process lifetime; never released.
        outer.inner.set(inner);
        windows_core::Type::from_abi(result)
    }
}

fn trace_enabled() -> bool {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("KAYA_WINUI_TRACE").is_some())
}

/// The Padding a container Grid must carry: the inset the container itself
/// declares (prop 17), plus the WINDOW inset when it is a mounted surface
/// root (wprop 8). WinUI folds two boxes into one — SwiftUI and Compose NEST
/// the window inset around the container's own padding — so a root's Padding
/// is the SUM, and every writer goes through here.
fn container_padding(core: &CoreState, id: WidgetId) -> f64 {
    let own = core.container_insets.get(&id).copied().unwrap_or(0.0);
    let root = core.mounted_roots.values().any(|&r| r == id);
    // A DECLARED TABLE'S CARD INTERIOR RIDES THIS NUMBER deliberately
    // (TABLE_CARD_XAML): it is the one every track arithmetic already
    // subtracts, so the card holds the content off its stroke without
    // moving a single cell edge.
    let card = if TABLES.with_borrow(|tables| tables.contains_key(&id.0)) {
        TABLE_CARD_PAD
    } else {
        0.0
    };
    own + card + if root { core.inset } else { 0.0 }
}

/// Write [`container_padding`] onto a container, or onto the minted HOST of a
/// scroll-rooted window. The scroll arm is load-bearing for one case: a
/// `kaya.scroll` mounted as a window's root, where the window inset has
/// nowhere else to land (docs/traps.md: A window inset stamped on containers
/// alone is dropped by a scroll-rooted window). Padding cannot go on the
/// viewer itself: ScrollViewer's default template does not bind it.
fn stamp_container_padding(core: &CoreState, id: WidgetId) -> windows_core::Result<()> {
    let pad = container_padding(core, id);
    let pad = Thickness {
        Left: pad,
        Top: pad,
        Right: pad,
        Bottom: pad,
    };
    match core.widgets.get(&id) {
        Some(
            NativeWidget::Column(grid) | NativeWidget::Row(grid) | NativeWidget::Grid2D(grid),
        ) => grid.SetPadding(pad),
        Some(NativeWidget::Scroll(_)) => match core.scroll_root_hosts.get(&id) {
            Some(host) => host.SetPadding(pad),
            None => Ok(()),
        },
        _ => Ok(()),
    }
}

/// Re-attach a 2D grid's children row-major per its current column count,
/// with one Auto track per row/column — reached from `flush_tracks` once per
/// batch. `reindex` below does the same for a Column/Row: a Grid lays out by
/// attached index rather than by child order (docs/traps.md), so the whole
/// set is rebuilt after every structural change.
fn reflow_grid(core: &CoreState, grid_id: u64) -> windows_core::Result<()> {
    let Some(NativeWidget::Grid2D(grid)) = core.widgets.get(&WidgetId(grid_id)) else {
        return Ok(());
    };
    let cols = core.grid_cols.get(&grid_id).copied().unwrap_or(1).max(1);
    let children = match core.grid_children.get(&grid_id) {
        Some(c) => c.clone(),
        None => return Ok(()),
    };
    let rows = (children.len() as i32 + cols - 1) / cols;
    let coldefs = grid.ColumnDefinitions()?;
    coldefs.Clear()?;
    for _ in 0..cols {
        let def = ColumnDefinition::new()?;
        def.SetWidth(GridLength { Value: 1.0, GridUnitType: GridUnitType::Auto })?;
        coldefs.Append(&def)?;
    }
    let rowdefs = grid.RowDefinitions()?;
    rowdefs.Clear()?;
    for _ in 0..rows {
        let def = RowDefinition::new()?;
        def.SetHeight(GridLength { Value: 1.0, GridUnitType: GridUnitType::Auto })?;
        rowdefs.Append(&def)?;
    }
    let slots = grid.Children()?;
    slots.Clear()?;
    for (i, child) in children.iter().enumerate() {
        let i = i as i32;
        Grid::SetColumn(&child.cast::<FrameworkElement>()?, i % cols)?;
        Grid::SetRow(&child.cast::<FrameworkElement>()?, i / cols)?;
        slots.Append(child)?;
    }
    Ok(())
}

/// WHICH PANEL A CONTAINER'S CHILDREN ACTUALLY LIVE IN: for a declared
/// table the band panel inside its scroll host, so the rows scroll and
/// the header does not; for everything else the container's own Grid.
fn container_panel(core: &CoreState, parent: WidgetId) -> Option<Grid> {
    let own = match core.widgets.get(&parent) {
        Some(NativeWidget::Column(g)) => g.clone(),
        Some(NativeWidget::Row(g)) => return Some(g.clone()),
        _ => return None,
    };
    Some(TABLES.with_borrow(|t| t.get(&parent.0).map(|w| w.band.clone())).unwrap_or(own))
}

/// A container's rendered direction: the creation kind's default under
/// any axis override (prop 18). Every direction decision below keys on
/// this fold — a variant-keyed read would call a flipped row a row.
fn effective_vertical(core: &CoreState, id: WidgetId) -> bool {
    core.axes.get(&id).map_or_else(
        || matches!(core.widgets.get(&id), Some(NativeWidget::Column(_))),
        |a| *a == 1,
    )
}

fn reindex(core: &CoreState, parent: WidgetId) -> windows_core::Result<()> {
    let grid = match core.widgets.get(&parent) {
        Some(NativeWidget::Column(g)) | Some(NativeWidget::Row(g)) => g.clone(),
        // Destroyed, or never a container: nothing to place.
        _ => return Ok(()),
    };
    let vertical = effective_vertical(core, parent);
    // The children this container LAYS OUT (D7): a folded child renders
    // inside its table's viewport instead; its order entry stays, so the
    // unfold re-stamps it exactly where it was declared.
    let order: Vec<WidgetId> = core
        .child_order
        .children(parent)
        .iter()
        .copied()
        .filter(|c| !core.folded_into.contains_key(&c.0))
        .collect();
    let order = &order[..];
    // A DECLARED TABLE OWNS THREE TRACKS OF ITS OWN — the header, the
    // rule and the scroll host — and its rows are placed inside the
    // host's band panel, one track down past the top spacer
    // (docs/virtualization-plan.md §4, docs/tables-plan.md). This is the
    // only place a Column's children are placed.
    let table = if vertical {
        TABLES.with_borrow(|t| {
            t.get(&parent.0)
                .map(|w| (w.band.clone(), w.spacer_top, w.spacer_bottom, w.gap))
        })
    } else {
        None
    };
    let head = if table.is_some() { 1 } else { 0 };

    if vertical {
        if let Some((band, top, bottom, _)) = &table {
            let defs = grid.RowDefinitions()?;
            defs.Clear()?;
            for length in [track(0.0), track(0.0), track(1.0)] {
                let def = RowDefinition::new()?;
                def.SetHeight(length)?;
                defs.Append(&def)?;
            }
            // THE SPACERS ARE TRACKS, NOT WIDGETS: an empty pixel track
            // reserves its height, and both numbers are the CORE's
            // arithmetic (`table_spacer_targets`). NO SCENE CAN SEE THEM,
            // so the pair is held statically, in
            // `every_link_of_the_report_loop_is_still_wired`.
            let defs = band.RowDefinitions()?;
            defs.Clear()?;
            let spacer = |h: f64| GridLength { Value: h.max(0.0), GridUnitType: GridUnitType::Pixel };
            let def = RowDefinition::new()?;
            def.SetHeight(spacer(*top))?;
            defs.Append(&def)?;
            for child in order {
                let def = RowDefinition::new()?;
                def.SetHeight(track(core.grow.get(child).copied().unwrap_or(0.0)))?;
                defs.Append(&def)?;
            }
            let def = RowDefinition::new()?;
            def.SetHeight(spacer(*bottom))?;
            defs.Append(&def)?;
        } else {
            // The OTHER side's tracks are cleared on every pass: after an
            // axis flip the old direction's definitions would otherwise
            // survive and place children on both grids at once.
            grid.ColumnDefinitions()?.Clear()?;
            let defs = grid.RowDefinitions()?;
            defs.Clear()?;
            for child in order {
                let def = RowDefinition::new()?;
                def.SetHeight(track(core.grow.get(child).copied().unwrap_or(0.0)))?;
                defs.Append(&def)?;
            }
        }
    } else {
        grid.RowDefinitions()?.Clear()?;
        let defs = grid.ColumnDefinitions()?;
        defs.Clear()?;
        for child in order {
            let def = ColumnDefinition::new()?;
            def.SetWidth(track(core.grow.get(child).copied().unwrap_or(0.0)))?;
            defs.Append(&def)?;
        }
    }

    let mode = core.aligns.get(&parent).copied().unwrap_or(0);
    for (index, child) in order.iter().enumerate() {
        let Some(widget) = core.widgets.get(child) else {
            continue;
        };
        let element: FrameworkElement = widget.element()?.cast()?;
        let track = track_of(index, head);
        // Both attached indices, so a flip leaves no stale placement on
        // the axis that no longer has tracks.
        if vertical {
            Grid::SetRow(&element, track)?;
            Grid::SetColumn(&element, 0)?;
        } else {
            Grid::SetColumn(&element, track)?;
            Grid::SetRow(&element, 0)?;
        }
        // A WINDOWED ROW'S TRACK IS ITS PITCH: the gap rides the row's
        // own bottom margin, uniformly (an odd last row would report a
        // different extent and correct a table whose data is uniform).
        if let Some((_, _, _, gap)) = &table {
            element.SetMargin(Thickness { Left: 0.0, Top: 0.0, Right: 0.0, Bottom: *gap })?;
        }
        // THE TEXTAREA'S LAYOUT FLOOR, AND THE ONE PLACE `grow` REACHES IT.
        // 240x96 is the size all four backends declare; on the other three it
        // is a MINIMUM. The HEIGHT cannot be one here — WinUI measures a
        // control in an Auto row against infinite height, so a 40-line
        // document asked for 758 pixels and got them — and an explicit Height
        // OUTRANKS the star row's Stretch (docs/traps.md).
        if let NativeWidget::Textarea(field) = widget {
            let grows = vertical && core.grow.get(child).copied().unwrap_or(0.0) > 0.0;
            field.SetMinHeight(if grows { 96.0 } else { 0.0 })?;
            field.SetHeight(if grows { f64::NAN } else { 96.0 })?;
        }
        // Cross placement from the container's align mode. WinUI's own
        // default is Stretch; kaya's normalized default is start, stamped
        // explicitly so the two never drift. Baseline (rows only) stamps Top
        // and gets its margin compensation below. THE BREADTH RULE outranks
        // the mode: a nested container whose main axis crosses its parent's
        // spans the parent's breadth (container_fills' breadth clause holds it).
        let crossing = matches!(widget, NativeWidget::Row(_) | NativeWidget::Column(_))
            && effective_vertical(core, *child) != vertical;
        // A SCROLL SPANS ITS PARENT'S CROSS AXIS under the default mode
        // and under stretch (ruled 2026-09-02; the scene's expect_breadth
        // holds it): a viewport is a region, not content. Center and end
        // still position a hugging one.
        let crossing = crossing
            || (matches!(widget, NativeWidget::Scroll(_)) && matches!(mode, 0 | 3));
        // THE MAIN AXIS IS STAMPED STRETCH ON EVERY FLEX CHILD: an Auto
        // track renders identically (track = desired), a star track is
        // the grower's box, and a declared Width/Height still outranks
        // Stretch by WinUI's own rules. Left unstamped, a Button in a
        // star track drew 57dip of a 372dip track (docs/traps.md: A
        // stretched WinUI TextBlock arranges text-sized).
        if vertical {
            element.SetVerticalAlignment(
                bindings::Microsoft::UI::Xaml::VerticalAlignment::Stretch)?;
        } else {
            element.SetHorizontalAlignment(
                bindings::Microsoft::UI::Xaml::HorizontalAlignment::Stretch)?;
        }
        if vertical {
            element.SetHorizontalAlignment(if crossing {
                bindings::Microsoft::UI::Xaml::HorizontalAlignment::Stretch
            } else {
                match mode {
                    1 => bindings::Microsoft::UI::Xaml::HorizontalAlignment::Center,
                    2 => bindings::Microsoft::UI::Xaml::HorizontalAlignment::Right,
                    3 => bindings::Microsoft::UI::Xaml::HorizontalAlignment::Stretch,
                    _ => bindings::Microsoft::UI::Xaml::HorizontalAlignment::Left,
                }
            })?;
        } else {
            element.SetVerticalAlignment(if crossing {
                bindings::Microsoft::UI::Xaml::VerticalAlignment::Stretch
            } else {
                match mode {
                    1 => bindings::Microsoft::UI::Xaml::VerticalAlignment::Center,
                    2 => bindings::Microsoft::UI::Xaml::VerticalAlignment::Bottom,
                    3 => bindings::Microsoft::UI::Xaml::VerticalAlignment::Stretch,
                    _ => bindings::Microsoft::UI::Xaml::VerticalAlignment::Top,
                }
            })?;
        }
    }
    if mode == 4 && !vertical {
        baseline_compensate(core, &grid, order)?;
    }
    Ok(())
}

/// THE BATCH'S ONE RE-STAMP: running `reindex` per child is N^2/2 WinRT round
/// trips (winui/order.rs), so a structural change marks its container and this
/// drains the marks — every container once, in first-marked order. It runs at
/// both op runners' ends AND at every harness hop, so nothing can be shown a
/// tree a batch behind; a failure leaves the rest marked for the next flush.
fn flush_tracks(core: &mut CoreState) -> windows_core::Result<()> {
    while let Some(container) = core.child_order.next_due() {
        // A 2D grid re-flows row-major instead: `reflow_grid` clears the
        // Children collection and re-appends every child.
        match core.widgets.get(&container) {
            Some(NativeWidget::Grid2D(_)) => reflow_grid(core, container.0)?,
            _ => reindex(core, container)?,
        }
    }
    Ok(())
}

/// WinUI's baseline row: no native primitive exists, so children with
/// a text baseline get a top margin lifting them to the deepest one.
/// BaselineOffset is only meaningful after a measure pass; UpdateLayout
/// forces it synchronously, the child_shares precedent.
fn baseline_compensate(
    core: &CoreState,
    grid: &Grid,
    order: &[WidgetId],
) -> windows_core::Result<()> {
    grid.UpdateLayout()?;
    let mut offsets: Vec<(FrameworkElement, f64)> = Vec::new();
    for child in order {
        let Some(widget) = core.widgets.get(child) else {
            continue;
        };
        let element: FrameworkElement = widget.element()?.cast()?;
        let baseline = match widget {
            NativeWidget::Label(text) => Some(text.BaselineOffset()?),
            NativeWidget::Button { caption, .. } | NativeWidget::Checkbox { caption, .. } => {
                // The caption sits inside the control: its baseline in
                // the CONTROL's space is its offset there plus its own
                // BaselineOffset.
                let at = caption
                    .TransformToVisual(&element)?
                    .TransformPoint(bindings::Windows::Foundation::Point { X: 0.0, Y: 0.0 })?;
                Some(f64::from(at.Y) + caption.BaselineOffset()?)
            }
            // No text baseline: the bottom-edge rule — the child's
            // baseline IS its bottom (the CSS replaced-element rule), so
            // a tall image drags the common baseline down and the text
            // children lift to meet it. Text-only compensation is
            // geometrically indistinguishable from start.
            _ => Some(element.ActualHeight()?),
        };
        if let Some(b) = baseline {
            offsets.push((element, b));
        }
    }
    let Some(deepest) = offsets
        .iter()
        .map(|(_, b)| *b)
        .max_by(|a, b| a.partial_cmp(b).unwrap())
    else {
        return Ok(());
    };
    for (element, baseline) in offsets {
        element.SetMargin(Thickness {
            Left: 0.0,
            Top: deepest - baseline,
            Right: 0.0,
            Bottom: 0.0,
        })?;
    }
    Ok(())
}

/// Re-stamp the wrap's rows after a fold change (D7): one Auto row per
/// folded element in sibling order, then the band. Its only callers are
/// the Fold arm's two directions.
fn fold_restack(table: &WinTable) -> windows_core::Result<()> {
    // THE FOLD SEAM (D7): a SECTION gap between the folded children and
    // the band, not the table's internal spacing — at nothing, the folded
    // summary and the rows read as one surface. RowSpacing, so it clears
    // itself when the last unfold empties the list.
    table
        .wrap
        .SetRowSpacing(if table.folded.is_empty() { 0.0 } else { 16.0 })?;
    let defs = table.wrap.RowDefinitions()?;
    defs.Clear()?;
    for _ in 0..=table.folded.len() {
        let def = RowDefinition::new()?;
        def.SetHeight(track(0.0))?;
        defs.Append(&def)?;
    }
    for (i, element) in table.folded.iter().enumerate() {
        Grid::SetRow(element, i as i32)?;
    }
    Grid::SetRow(&table.band.cast::<FrameworkElement>()?, table.folded.len() as i32)?;
    Ok(())
}

/// The folded block's extent above the band (D7): what every band-space
/// coordinate must add to reach host space, and 0.0 with nothing folded.
/// MEASURED as the band's own Y inside the wrap — everything the layout
/// actually spent — rather than a second sum that would drift from it.
fn fold_extent(id: u64) -> f64 {
    TABLES.with_borrow(|tables| {
        tables.get(&id).map_or(0.0, |t| {
            if t.folded.is_empty() {
                return 0.0;
            }
            t.band
                .TransformToVisual(&t.wrap)
                .and_then(|tr| {
                    tr.TransformPoint(bindings::Windows::Foundation::Point { X: 0.0, Y: 0.0 })
                })
                .map_or(0.0, |p| f64::from(p.Y))
        })
    })
}

fn track(weight: f64) -> GridLength {
    if weight > 0.0 {
        GridLength {
            Value: weight,
            GridUnitType: GridUnitType::Star,
        }
    } else {
        // Auto and not `*`: a weight-0 child takes no part in the
        // division, so the growers' shares come out of the leftover.
        GridLength {
            Value: 0.0,
            GridUnitType: GridUnitType::Auto,
        }
    }
}

// TABLES: the details-view lowering (docs/tables-plan.md decision 6).
//
// THE COLUMN WIDTHS ARE COMPUTED, NOT DECLARED, and that is forced: WinUI's
// Grid has no SharedSizeGroup, so the header and the row Grids cannot share
// tracks, and star sizing with per-column MinWidth resolves to EQUAL columns
// clamped up at content, not to content-floor-plus-equal-leftover.

/// The gap between adjacent columns.
const TABLE_COL_GAP: f64 = 24.0;

/// A header cell. PARSED RATHER THAN CONSTRUCTED because `FontWeight` and the
/// flat chrome are vtable pads in the generated bindings (the cleaner home is
/// three members in tools/winui-bindgen). A Button and not a TextBlock so the
/// header has a real activation path: its Click is what emits, and
/// `header_click` drives it through the button's own automation peer.
const TABLE_HEADER_CELL_XAML: &str = concat!(
    "<Button xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" ",
    "Background=\"Transparent\" BorderThickness=\"0\" Padding=\"0,2,0,2\" ",
    "FontWeight=\"SemiBold\" HorizontalAlignment=\"Stretch\" ",
    "HorizontalContentAlignment=\"Left\"/>"
);

/// The rule under the header row. A Grid with a Background rather than a
/// Border: `Border` is not in the bindgen filter, and the brush comes out
/// of the markup so no `SolidColorBrush` projection is needed either.
const TABLE_RULE_XAML: &str = concat!(
    "<Grid xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" ",
    "Height=\"1\" Background=\"#40808080\" HorizontalAlignment=\"Stretch\"/>"
);

/// A TABLE BOUNDS ITS OWN EXTENT (docs/deferred.md's table-card entry) —
/// Fluent's layer card, FLAT: fill, a 1 DIP stroke and the radius, no shadow.
/// IT SITS BEHIND THE THREE TRACKS, NOT AROUND THEM: a BorderThickness on the
/// container takes 2 DIP out of the box every track arithmetic divides. AND IT
/// CARRIES A NEGATIVE MARGIN of the card's interior padding, which rides the
/// CONTAINER's own Padding, so the card cannot move a cell edge.
const TABLE_CARD_XAML: &str = concat!(
    "<Grid xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" ",
    "Background=\"{ThemeResource CardBackgroundFillColorDefaultBrush}\" ",
    "BorderBrush=\"{ThemeResource CardStrokeColorDefaultBrush}\" ",
    "BorderThickness=\"1\" CornerRadius=\"{ThemeResource OverlayCornerRadius}\" ",
    "HorizontalAlignment=\"Stretch\" VerticalAlignment=\"Stretch\"/>"
);

/// The card's interior, per side. FLUENT'S CARD CONTENT INSET is 12epx
/// (the SettingsCard family's 12/16 pair, of which 12 is the tighter one
/// and the one a DENSE table wants). Symmetric, because `pad` is one
/// number for four sides here.
const TABLE_CARD_PAD: f64 = 12.0;

/// The ascending / descending indicator, appended to the sorted column's
/// title — the glyphs the other synthesized tiers use. `columns_presented`
/// reads them back off the control as the scene's `^N`/`vN`.
const TABLE_ASC: &str = " \u{25B2}";
const TABLE_DESC: &str = " \u{25BC}";

/// One declared table's native side.
///
/// OUTSIDE `CoreState` FOR THE REASON HIGHLIGHT_TEXT IS: the
/// redistribution pass runs from a LayoutUpdated handler, and a handler
/// that touched `CORE` would be one synchronous layout away from
/// aborting the process.
struct WinTable {
    titles: Vec<String>,
    sorted: u32,
    direction: u32,
    /// The click tag, handed back verbatim with the column index.
    tag: Vec<u8>,
    grid: Grid,
    /// The card behind the three tracks (TABLE_CARD_XAML).
    card: Grid,
    /// The header's own scroller, driven to `host`'s horizontal offset so
    /// the titles travel with the cells under them. It hangs on the
    /// container, and it is what CLIPS the titles, since a panel does not.
    head: ScrollViewer,
    header: Grid,
    rule: Grid,
    /// THE SCROLL CONTAINER THIS TIER OWNS (docs/virtualization-plan.md
    /// §4). The header and the rule stay pinned as the container's first
    /// two tracks; everything that scrolls is inside this.
    host: ScrollViewer,
    /// The band panel: the top spacer track, one track per REALIZED row,
    /// the bottom spacer track. `reindex` is its only structural writer.
    band: Grid,
    /// The host's real content since the fold (D7): Auto rows holding the
    /// folded children, then the band.
    wrap: Grid,
    /// The folded elements in sibling order — the extent the report adds
    /// back, since every band coordinate is band-space.
    folded: Vec<FrameworkElement>,
    cells: Vec<Button>,
    rows: Vec<Grid>,
    pad: f64,
    /// Each column's MEASURED content width — the floor.
    floors: Vec<f64>,
    /// The widths last written, so the layout pass can tell a real change
    /// from a no-op and stop invalidating layout.
    applied: Vec<f64>,
    /// WHICH ROWS THOSE WIDTHS WERE WRITTEN TO. Without it the no-op
    /// early-out above swallows a row ARRIVING at unchanged widths: the
    /// new row keeps its container default (8dip gaps, Auto tracks) while
    /// every older row carries the table's.
    stamped: Vec<Grid>,
    /// The floors need re-measuring: set by every drain that could have
    /// moved content, cleared by the first layout pass that gets a real
    /// answer.
    dirty: bool,
    /// Measures spent waiting for that real answer. A measure taken
    /// before the tree is live reads ZEROS, and zero floors leave the
    /// columns evenly split with no content floor at all, passing every
    /// observable. So a zero keeps the request open, and this bounds how
    /// many layout passes that may cost.
    probes: u32,

    // --- The row window (docs/virtualization-plan.md §3-§4). ----------
    /// The two spacer tracks, in the core's own arithmetic: the band's
    /// top offset and what the collection has left below it. NEVER
    /// computed here — the core owns presume/verify/correct, and a second
    /// estimator is what §2 exists to remove.
    spacer_top: f64,
    spacer_bottom: f64,
    /// The gap each row carries as its own bottom margin, so a row's
    /// TRACK is its pitch (top-to-top, spacing included) and the band
    /// panel needs no RowSpacing of its own.
    gap: f64,
    /// The last visible range handed to `kaya_window_moved`, so an
    /// unchanged range produces no applies, which is also what stops the
    /// report loop from repeating.
    reported: Option<(usize, usize)>,
    /// What `expect_window` compares: the first VISIBLE row and the
    /// collection's declared total, refreshed by every report.
    first_visible: usize,
    total: usize,
    /// The ROW the viewport is parked on (§2.4) and the offset this tier
    /// last commanded. An offset we did not command is the user's scroll,
    /// and the anchor yields to it.
    anchor: Option<usize>,
    at: f64,
    /// Cycles left for a commanded scroll to land. THIS BACKEND CANNOT
    /// SEE A SCROLL EVENT — its bindings project no `ViewChanged`
    /// (tools/winui-bindgen; the add is a vtable pad) — so a scroll is
    /// observed as an OFFSET that is neither where we put it nor where
    /// the anchor says it belongs. This bounds how long a command that
    /// never lands may suppress that reading.
    commanded: u8,
    scheduled: bool,

    // --- The columns' axis (the 2026-08-29 overflow ruling). ----------
    /// The columns' box as `host` last reported it: the resolved columns
    /// and the track they were laid out in. A table just laid out shows
    /// its FIRST column, so either half moving parks the offset back at
    /// the leading edge (`table_columns_track`).
    hcontent: f64,
    htrack: f64,
}

/// How many settle rounds one report drives. Each round acts on at most
/// one thing and stops when nothing moved, so this only bounds a tier
/// that never converges.
const TABLE_SETTLE_ROUNDS: usize = 6;

/// How many layout passes a table may spend trying to measure real
/// content before it settles for what it has.
const TABLE_PROBE_LIMIT: u32 = 8;

thread_local! {
    static TABLES: RefCell<HashMap<u64, WinTable>> = RefCell::new(HashMap::new());
}

fn table_cell_text(titles: &[String], sorted: u32, direction: u32, column: usize) -> String {
    let mut text = titles[column].clone();
    if sorted as usize == column && sorted != crate::wire::SORT_NONE {
        text.push_str(if direction == 0 { TABLE_ASC } else { TABLE_DESC });
    }
    text
}

/// Mint (or re-mint) a table's header chrome and record the declaration.
/// The rows and the tracks are not touched here — `reindex` places the
/// children and `table_pass` sizes the columns.
fn declare_table(
    core: &mut CoreState,
    id: WidgetId,
    sorted: u32,
    direction: u32,
    titles: Vec<String>,
    tag: Vec<u8>,
) -> windows_core::Result<()> {
    let Some(NativeWidget::Column(grid)) = core.widgets.get(&id) else {
        return Ok(());
    };
    let grid = grid.clone();
    let mut minted: Option<(Grid, ScrollViewer, Grid, Grid, ScrollViewer, Grid, Grid, Vec<Button>)> =
        None;
    let remint = TABLES.with_borrow(|tables| match tables.get(&id.0) {
        Some(live) => live.titles.len() != titles.len(),
        None => true,
    });
    if remint {
        let header = Grid::new()?;
        header.SetColumnSpacing(TABLE_COL_GAP)?;
        header.SetHorizontalAlignment(HorizontalAlignment::Stretch)?;
        let card: Grid = XamlReader::Load(&HSTRING::from(TABLE_CARD_XAML))?.cast()?;
        // ONE number, written here rather than spelled again in the
        // markup: the card sits back out at the container's own box while
        // the content stays inside the padding it shares with the track
        // arithmetic.
        card.SetMargin(Thickness {
            Left: -TABLE_CARD_PAD,
            Top: -TABLE_CARD_PAD,
            Right: -TABLE_CARD_PAD,
            Bottom: -TABLE_CARD_PAD,
        })?;
        let rule: Grid = XamlReader::Load(&HSTRING::from(TABLE_RULE_XAML))?.cast()?;
        // THE SCROLL CONTAINER (§4). BOTH AXES since the overflow ruling
        // (docs/tables-plan.md): Disabled here IS how "the last column is
        // clipped" shipped (docs/probes/table-overflow-2026.md §4.4).
        // BOTH BARS ARE OVERLAYS (Auto, never Visible): a reserved gutter
        // would take its width out of the rows and leave them narrower than
        // the pinned header, which `column_edges` convicts as ContentUnderfill.
        let host = ScrollViewer::new()?;
        host.SetHorizontalScrollMode(ScrollMode::Enabled)?;
        host.SetHorizontalScrollBarVisibility(ScrollBarVisibility::Auto)?;
        host.SetVerticalScrollMode(ScrollMode::Enabled)?;
        host.SetVerticalScrollBarVisibility(ScrollBarVisibility::Auto)?;
        host.SetHorizontalAlignment(HorizontalAlignment::Stretch)?;
        // THE HEADER RIDES A SCROLLER OF ITS OWN, driven to the body's offset
        // by `table_columns_track`: this backend's bindings project neither
        // RenderTransform nor Clip, and a bare header would not be clipped
        // either. NO BAR OF ITS OWN (Hidden, not Disabled): Disabled also
        // refuses ChangeView. The vertical half is Disabled precisely so this
        // scroller reports the header's HEIGHT to the Auto track it sits in.
        let head = ScrollViewer::new()?;
        head.SetHorizontalScrollMode(ScrollMode::Enabled)?;
        head.SetHorizontalScrollBarVisibility(ScrollBarVisibility::Hidden)?;
        head.SetVerticalScrollMode(ScrollMode::Disabled)?;
        head.SetVerticalScrollBarVisibility(ScrollBarVisibility::Disabled)?;
        head.SetHorizontalAlignment(HorizontalAlignment::Stretch)?;
        head.SetContent(&header)?;
        let band = Grid::new()?;
        // NO RowSpacing: a row's own bottom margin carries the gap, so
        // the TRACK is the pitch and the spacers are the core's numbers
        // with nothing added (`reindex`).
        band.SetRowSpacing(0.0)?;
        band.SetHorizontalAlignment(HorizontalAlignment::Stretch)?;
        // The wrap (D7): the scrolling side is [folded children..., band],
        // Auto rows; fold_restack keeps the definitions in step.
        let wrap = Grid::new()?;
        wrap.SetHorizontalAlignment(HorizontalAlignment::Stretch)?;
        {
            let def = RowDefinition::new()?;
            def.SetHeight(track(0.0))?;
            wrap.RowDefinitions()?.Append(&def)?;
        }
        Grid::SetRow(&band.cast::<FrameworkElement>()?, 0)?;
        wrap.Children()?.Append(&band)?;
        host.SetContent(&wrap)?;
        let mut cells = Vec::new();
        for (column, _) in titles.iter().enumerate() {
            let cell: Button = XamlReader::Load(&HSTRING::from(TABLE_HEADER_CELL_XAML))?.cast()?;
            let def = ColumnDefinition::new()?;
            def.SetWidth(GridLength { Value: 0.0, GridUnitType: GridUnitType::Auto })?;
            header.ColumnDefinitions()?.Append(&def)?;
            Grid::SetColumn(&cell.cast::<FrameworkElement>()?, column as i32)?;
            header.Children()?.Append(&cell)?;
            // THE HEADER'S OWN ACTIVATION PATH. A click is a REQUEST: the
            // tag goes back verbatim with the column index and nothing on
            // screen moves.
            let sink = core.occurrences.clone();
            let owner = id.0;
            let handler = RoutedEventHandler::new(move |_, _| {
                TABLES.with(|tables| {
                    if let Ok(tables) = tables.try_borrow() {
                        if let Some(table) = tables.get(&owner) {
                            sink.send_sort_tag(&table.tag, column as u32);
                        }
                    }
                });
                Ok(())
            });
            cell.Click(&handler)?;
            cells.push(cell);
        }
        minted = Some((card, head, header, rule, host, band, wrap, cells));
    }
    let fresh = minted.is_some();
    let gap = core.spacings.get(&id).copied().unwrap_or(8.0);
    TABLES.with_borrow_mut(|tables| -> windows_core::Result<()> {
        if let Some((card, head, header, rule, host, band, wrap, cells)) = minted {
            tables.insert(
                id.0,
                WinTable {
                    titles: titles.clone(),
                    sorted,
                    direction,
                    tag,
                    grid: grid.clone(),
                    card,
                    head,
                    header,
                    rule,
                    host,
                    band,
                    wrap,
                    folded: Vec::new(),
                    cells,
                    rows: Vec::new(),
                    pad: 0.0,
                    floors: Vec::new(),
                    applied: Vec::new(),
                    stamped: Vec::new(),
                    dirty: true,
                    probes: 0,
                    spacer_top: 0.0,
                    spacer_bottom: 0.0,
                    gap,
                    reported: None,
                    first_visible: 0,
                    total: 0,
                    anchor: None,
                    at: 0.0,
                    commanded: 0,
                    scheduled: false,
                    hcontent: 0.0,
                    htrack: 0.0,
                },
            );
        } else if let Some(table) = tables.get_mut(&id.0) {
            table.titles = titles.clone();
            table.sorted = sorted;
            table.direction = direction;
            table.tag = tag;
            table.dirty = true;
            table.probes = 0;
        }
        let table = tables.get_mut(&id.0).expect("just inserted or updated");
        for (column, cell) in table.cells.iter().enumerate() {
            let text = table_cell_text(&table.titles, table.sorted, table.direction, column);
            cell.SetContent(&PropertyValue::CreateString(&HSTRING::from(text))?)?;
        }
        Ok(())
    })?;
    if fresh {
        let children = grid.Children()?;
        let (card, head, rule, host) = TABLES.with_borrow(|tables| {
            let table = &tables[&id.0];
            (
                table.card.clone(),
                table.head.clone(),
                table.rule.clone(),
                table.host.clone(),
            )
        });
        // The card spans the three tracks and is inserted FIRST, which is
        // what puts it behind them (TABLE_CARD_XAML).
        let card_element = card.cast::<FrameworkElement>()?;
        Grid::SetRow(&card_element, 0)?;
        Grid::SetRowSpan(&card_element, 3)?;
        // The HEAD hangs on the container; the header itself is its child.
        Grid::SetRow(&head.cast::<FrameworkElement>()?, 0)?;
        Grid::SetRow(&rule.cast::<FrameworkElement>()?, 1)?;
        Grid::SetRow(&host.cast::<FrameworkElement>()?, 2)?;
        children.InsertAt(0, &card)?;
        children.Append(&head)?;
        children.Append(&rule)?;
        children.Append(&host)?;
        // A scroll moves no frame of the container, so its LayoutUpdated
        // cannot be the only report trigger: the host's own is where a
        // view change lands (this backend's bindings project no
        // ViewChanged), and it is the only signal the header travels on.
        let host_id = id.0;
        let scrolled = EventHandler::<windows_core::IInspectable>::new(move |_, _| {
            table_columns_track(host_id);
            schedule_report(host_id);
            Ok(())
        });
        host.LayoutUpdated(&scrolled)?;
        // The first real layout is where a measure stops reading zeros
        // (the baseline-compensation lesson), and LayoutUpdated is where
        // a later resize is seen — this backend projects no SizeChanged.
        let loaded_id = id.0;
        let loaded = RoutedEventHandler::new(move |_, _| {
            table_pass(loaded_id);
            Ok(())
        });
        grid.Loaded(&loaded)?;
        let laid_id = id.0;
        let laid = EventHandler::<windows_core::IInspectable>::new(move |_, _| {
            table_pass(laid_id);
            Ok(())
        });
        grid.LayoutUpdated(&laid)?;
    }
    // The card's interior joins the container's padding the moment the
    // table exists, and container_padding only answers for a table it can
    // already see in TABLES, so the stamp is re-run HERE.
    stamp_container_padding(core, id)?;
    // The two head tracks the rows now shift down past.
    core.child_order.mark(id);
    Ok(())
}

/// Refresh what the geometry pass needs from the core and mark the
/// floors stale. Called once per drain, the `menus_touched` shape.
fn sync_tables(core: &CoreState) {
    let ids: Vec<u64> = TABLES.with_borrow(|tables| tables.keys().copied().collect());
    for id in ids {
        let mut rows = Vec::new();
        for child in core.child_order.children(WidgetId(id)) {
            if let Some(NativeWidget::Row(grid)) = core.widgets.get(child) {
                rows.push(grid.clone());
            }
        }
        let pad = container_padding(core, WidgetId(id));
        TABLES.with_borrow_mut(|tables| {
            if let Some(table) = tables.get_mut(&id) {
                table.rows = rows;
                table.pad = pad;
                table.dirty = true;
                table.probes = 0;
            }
        });
        table_pass(id);
        schedule_report(id);
    }
}

// THE ROW WINDOW (docs/virtualization-plan.md §3-§4), this tier's spelling:
// top spacer, the realized band's real widgets, bottom spacer, inside the
// scroll container the table owns. THE REPORT LOOP reports the realized rows'
// measured extents EXACTLY, no tolerance, which is what stops it repeating.
// EVERY NUMBER LAID OUT HERE IS THE CORE'S: this file owns no height cache,
// no pitch and no prefix sum (§2's one estimator).

/// One coalesced report per main-loop turn.
///
/// IT MAY NOT RUN INSIDE A LAYOUT PASS: the report applies ops, which
/// re-enters the Grid whose layout callback called us, and the dispatcher
/// hop is what keeps them apart.
fn schedule_report(id: u64) {
    let due = TABLES.with(|tables| match tables.try_borrow_mut() {
        Ok(mut tables) => match tables.get_mut(&id) {
            Some(table) if !table.scheduled => {
                table.scheduled = true;
                true
            }
            _ => false,
        },
        // Borrowed by the pass that is about to schedule its own.
        Err(_) => false,
    });
    if !due {
        return;
    }
    if let Some(dispatcher) = DISPATCHER.get() {
        let handler = DispatcherQueueHandler::new(move || {
            TABLES.with(|tables| {
                if let Ok(mut tables) = tables.try_borrow_mut() {
                    if let Some(table) = tables.get_mut(&id) {
                        table.scheduled = false;
                    }
                }
            });
            CORE.with_borrow_mut(|core| {
                if let Some(core) = core.as_mut() {
                    table_settle(core, id);
                }
            });
            Ok(())
        });
        let _ = dispatcher.0.TryEnqueue(&handler);
    }
}

/// A scroll offset in the boxed form ScrollViewer's two view calls take.
fn offset_ref(value: f64) -> windows_core::Result<IReference<f64>> {
    PropertyValue::CreateDouble(value)?.cast()
}

/// THE HEADER TRAVELS WITH THE BODY, and a table just laid out shows its
/// FIRST column (docs/tables-plan.md, the overflow ruling). Reached from
/// `host`'s LayoutUpdated; every write here is gated on a number that MOVED,
/// or a pass would request a view on every layout. THE RESET'S TRIGGER IS THE
/// COLUMNS' BOX, never the offset: resetting on every view change would throw
/// away the scroll the reader made.
fn table_columns_track(id: u64) {
    let Some((head, host)) =
        TABLES.with(|tables| match tables.try_borrow() {
            Ok(tables) => tables.get(&id).map(|w| (w.head.clone(), w.host.clone())),
            // Borrowed by the pass we were called from.
            Err(_) => None,
        })
    else {
        return;
    };
    let _ = (|| -> windows_core::Result<()> {
        let (content, track) = (host.ExtentWidth()?, host.ViewportWidth()?);
        let relaid = TABLES.with(|tables| match tables.try_borrow_mut() {
            Ok(mut tables) => match tables.get_mut(&id) {
                Some(w) if (w.hcontent - content).abs() > 0.5 || (w.htrack - track).abs() > 0.5 => {
                    w.hcontent = content;
                    w.htrack = track;
                    true
                }
                _ => false,
            },
            Err(_) => false,
        });
        let mut at = host.HorizontalOffset()?;
        if relaid && at > 0.5 {
            host.ChangeViewWithOptionalAnimation(
                &offset_ref(0.0)?,
                None::<&IReference<f64>>,
                None::<&IReference<f32>>,
                true,
            )?;
            at = 0.0;
        }
        if (head.HorizontalOffset()? - at).abs() > 0.5 {
            head.ChangeViewWithOptionalAnimation(
                &offset_ref(at)?,
                None::<&IReference<f64>>,
                None::<&IReference<f32>>,
                true,
            )?;
        }
        Ok(())
    })();
}

/// The band panel's live track geometry: the top spacer's height and one
/// height per realized row, in track order.
fn band_tracks(band: &Grid) -> windows_core::Result<(f64, Vec<f64>)> {
    let defs = band.RowDefinitions()?;
    let n = defs.Size()?;
    if n < 2 {
        return Ok((0.0, Vec::new()));
    }
    let top = defs.GetAt(0)?.ActualHeight()?;
    let mut rows = Vec::with_capacity((n - 2) as usize);
    for at in 1..n - 1 {
        rows.push(defs.GetAt(at)?.ActualHeight()?);
    }
    Ok((top, rows))
}

/// The two spacer heights the core's arithmetic currently implies.
/// Reached from layout callbacks that cannot unwind, so the window reads
/// sit under the fault guard like every other report caller.
fn table_spacer_targets(core: &mut CoreState, id: u64) -> (f64, f64) {
    crate::fault::guard("reading window geometry for the spacer tracks", || {
        let geometry = core.scene.window_geometry(id);
        let mut banded = 0.0;
        for index in geometry.first..geometry.first + geometry.count {
            banded += core.scene.row_extent(id, index);
        }
        band_spacers(geometry.offset, geometry.extent, banded)
    })
    .unwrap_or_default()
}

fn table_write_spacers(
    core: &mut CoreState,
    id: u64,
    band: &Grid,
) -> windows_core::Result<bool> {
    let (top, bottom) = table_spacer_targets(core, id);
    let (was_top, was_bottom) = TABLES
        .with_borrow(|t| t.get(&id).map(|w| (w.spacer_top, w.spacer_bottom)))
        .unwrap_or((0.0, 0.0));
    if (was_top - top).abs() <= 0.5 && (was_bottom - bottom).abs() <= 0.5 {
        return Ok(false);
    }
    TABLES.with_borrow_mut(|t| {
        if let Some(w) = t.get_mut(&id) {
            w.spacer_top = top;
            w.spacer_bottom = bottom;
        }
    });
    let defs = band.RowDefinitions()?;
    let n = defs.Size()?;
    if n >= 2 {
        let pixel = |h: f64| GridLength { Value: h, GridUnitType: GridUnitType::Pixel };
        defs.GetAt(0)?.SetHeight(pixel(top))?;
        defs.GetAt(n - 1)?.SetHeight(pixel(bottom))?;
    }
    Ok(true)
}

/// THE VERIFY HALF (§2.2): the extents this tier laid the realized rows
/// out at, reported only when they DISAGREE with what the core already
/// holds — exactly, no tolerance (§2.3).
fn table_measure_rows(
    core: &mut CoreState,
    id: u64,
    band: &Grid,
) -> windows_core::Result<bool> {
    let (_, tracks) = band_tracks(band)?;
    if tracks.is_empty() || tracks.iter().any(|h| *h <= 0.0) {
        // A track measured before the tree is live reads ZERO (the
        // baseline-compensation lesson); a zero pitch would presume every
        // unrealized row at nothing.
        return Ok(false);
    }
    Ok(crate::fault::guard("reporting measured row tracks", || {
        let first = core.scene.window_geometry(id).first;
        if !tracks
            .iter()
            .enumerate()
            .any(|(i, h)| core.scene.row_extent(id, first + i) != *h)
        {
            return false;
        }
        core.scene.rows_measured(id, first, &tracks);
        true
    })
    .unwrap_or(false))
}

/// One report cycle. Answers whether anything moved, so the settle loop knows
/// to look again. THE LAYOUT FOLLOWS THE CORE, THEN THE RANGE FOLLOWS THE
/// LAYOUT: `y0` is measured in the BAND PANEL's own coordinates, so a range
/// read while that spacer still holds the PREVIOUS band's number is
/// arithmetic over two collections (docs/traps.md: A range read against the
/// PREVIOUS band's spacer alternates two bands forever).
fn table_report_once(core: &mut CoreState, id: u64) -> windows_core::Result<bool> {
    let Some((host, band)) =
        TABLES.with_borrow(|tables| tables.get(&id).map(|w| (w.host.clone(), w.band.clone())))
    else {
        return Ok(false);
    };
    // Measure/arrange are lazy; force them or this cycle reads the
    // previous layout's tracks (the child_shares precedent).
    band.UpdateLayout()?;
    if table_measure_rows(core, id, &band)? {
        return Ok(true);
    }
    if table_write_spacers(core, id, &band)? {
        band.UpdateLayout()?;
        return Ok(true);
    }
    let (spacer_top, tracks) = band_tracks(&band)?;
    let y0 = host.VerticalOffset()?;
    let viewport = host.ViewportHeight()?;
    let Some(geometry) =
        crate::fault::guard("reading window geometry in the report cycle", || {
            core.scene.window_geometry(id)
        })
    else {
        // The fault already reddened the leg; nothing may be read.
        return Ok(true);
    };
    if (spacer_top - geometry.offset).abs() > 0.5 {
        // The spacer this tier asked for is not the height the toolkit
        // gave it yet. Nothing may be read off that: come back when the
        // layout has caught up.
        return Ok(true);
    }

    // --- §2.4's anchor: the scroll follows a ROW. -------------------
    let (anchor, at, commanded) =
        TABLES.with_borrow(|t| t.get(&id).map(|w| (w.anchor, w.at, w.commanded)).unwrap_or((None, 0.0, 0)));
    let landed = (y0 - at).abs() <= 0.5;
    // Band space to host space (D7): the folded block above the band
    // shifts every host offset by its own extent.
    let folded_h = fold_extent(id);
    let want = anchor.and_then(|row| {
        let offset = row.checked_sub(geometry.first)?;
        (offset <= tracks.len())
            .then(|| folded_h + spacer_top + tracks[..offset].iter().sum::<f64>())
    });
    if commanded > 0 || landed {
        TABLES.with_borrow_mut(|t| {
            if let Some(w) = t.get_mut(&id) {
                w.commanded = if landed { 0 } else { commanded - 1 };
            }
        });
    } else if want.is_none_or(|w| (y0 - w).abs() > 0.5) {
        // Neither where this tier put it nor where the anchor says the
        // parked row now is: the reader scrolled, and the anchor yields
        // to free scrolling.
        TABLES.with_borrow_mut(|t| {
            if let Some(w) = t.get_mut(&id) {
                w.anchor = None;
                w.at = y0;
            }
        });
    }
    if let Some(want) = want {
        if (y0 - want).abs() > 0.5 {
            // The parked row moved under a correction, or the last
            // command has not landed: put the viewport back on the ROW and
            // read nothing off an offset on its way somewhere.
            table_scroll_to(&host, id, want)?;
            return Ok(true);
        }
    }

    // --- The report: the visible range (§3.2). ----------------------
    let visible =
        table_visible_rows(&geometry, spacer_top, &tracks, (y0 - folded_h).max(0.0), viewport);
    if trace_enabled() {
        eprintln!(
            "kaya: winui window {id} band {}+{} of {} offset {:.1} extent {:.1} corrected {} \
             | spacer {spacer_top:.1} tracks {} y0 {y0:.1} vh {viewport:.1} \
             | anchor {anchor:?} want {want:?} at {at:.1} cmd {commanded} -> visible {visible:?}",
            geometry.first,
            geometry.count,
            geometry.total,
            geometry.offset,
            geometry.extent,
            geometry.corrected as u8,
            tracks.len()
        );
    }
    // THE TOTAL IS THE CORE'S OWN NUMBER and survives an unmeasured
    // cycle; the first VISIBLE row does not, so nothing publishes one
    // this cycle did not read.
    TABLES.with_borrow_mut(|t| {
        if let Some(w) = t.get_mut(&id) {
            w.total = geometry.total;
        }
    });
    let Some(visible) = visible else {
        // No live viewport and no extent: nothing to report, and an
        // invented report comes back as a bigger band (see
        // `table_visible_rows`).
        return Ok(false);
    };
    TABLES.with_borrow_mut(|t| {
        if let Some(w) = t.get_mut(&id) {
            w.first_visible = visible.0;
        }
    });
    let last = TABLES.with_borrow(|t| t.get(&id).and_then(|w| w.reported));
    if last == Some(visible) {
        return Ok(false);
    }
    TABLES.with_borrow_mut(|t| {
        if let Some(w) = t.get_mut(&id) {
            w.reported = Some(visible);
        }
    });
    table_band_to(core, id, visible)?;
    Ok(true)
}

/// Move the band to a reported range and put the applies it produces on
/// screen. THE SECOND PRODUCER (§3.3), on this backend's own pump: the
/// ops go through the same `apply` the drain uses, with the same one
/// re-stamp at the end.
fn table_band_to(
    core: &mut CoreState,
    id: u64,
    visible: (usize, usize),
) -> windows_core::Result<()> {
    let ops = crate::fault::guard("reporting a window range", || {
        core.scene.window_moved(id, visible.0, visible.1)
    })
    .unwrap_or_default();
    for op in ops {
        let what = op_head(&op);
        if let Err(e) = apply(core, op) {
            crate::fault::report(format!("kaya: applying {what} failed: {e}"));
            return Ok(());
        }
    }
    // THE SPACERS MOVE BEFORE THE RE-STAMP: `reindex` rebuilds the band
    // panel's two spacer tracks from these stored numbers, and a re-stamp
    // carrying the PREVIOUS band's collapses the content for one layout
    // pass — long enough for the ScrollViewer to clamp the offset out
    // from under the reader (docs/traps.md: A one-pass collapsed band
    // lets the ScrollViewer clamp the reader's offset).
    let (top, bottom) = table_spacer_targets(core, id);
    TABLES.with_borrow_mut(|t| {
        if let Some(w) = t.get_mut(&id) {
            w.spacer_top = top;
            w.spacer_bottom = bottom;
        }
    });
    flush_tracks(core)?;
    sync_tables(core);
    Ok(())
}

/// THE TWO SPACER HEIGHTS, from the core's three numbers: where the band
/// starts, how far the collection reaches, and what the band's rows occupy.
/// The identity `top + banded + bottom` = the collection's extent is what
/// makes the scrollbar honest; a band whose rows measure MORE than the extent
/// below them clamps rather than reserving negative space.
fn band_spacers(offset: f64, extent: f64, banded: f64) -> (f64, f64) {
    (offset.max(0.0), (extent - offset - banded).max(0.0))
}

/// The rows the reader can actually SEE, as `(first, count)` over the
/// COLLECTION's order — or `None` when this cycle measured NOTHING. Read off
/// the realized band's own tracks; a viewport that has landed in a SPACER has
/// no row to read, so it answers with the collection's mean row. A REPORT IS
/// A MEASUREMENT: answering the REALIZED BAND's own count is a doubling
/// (docs/traps.md: The band that fed itself).
fn table_visible_rows(
    geometry: &crate::scene::WindowGeometry,
    spacer_top: f64,
    tracks: &[f64],
    y0: f64,
    viewport: f64,
) -> Option<(usize, usize)> {
    if geometry.total == 0 {
        return Some((0, 0));
    }
    if viewport > 0.0 {
        let mut top = spacer_top;
        let mut first = None;
        let mut count = 0usize;
        for (i, h) in tracks.iter().enumerate() {
            let bottom = top + h;
            if bottom > y0 + 0.5 && top < y0 + viewport - 0.5 {
                first.get_or_insert(geometry.first + i);
                count += 1;
            }
            top = bottom;
        }
        if let Some(first) = first {
            return Some((first, count));
        }
    }
    let mean = if geometry.extent > 0.0 {
        geometry.extent / geometry.total as f64
    } else {
        0.0
    };
    if viewport <= 0.0 || mean <= 0.0 {
        return None;
    }
    let first = ((y0 / mean) as usize).min(geometry.total - 1);
    Some((first, ((viewport / mean).ceil() as usize).max(1)))
}

/// Command the host to `offset`, with no animation: an animated scroll
/// would be a moving target for the very next report.
fn table_scroll_to(host: &ScrollViewer, id: u64, offset: f64) -> windows_core::Result<()> {
    let target: IReference<f64> = PropertyValue::CreateDouble(offset.max(0.0))?.cast()?;
    host.ChangeViewWithOptionalAnimation(
        None::<&IReference<f64>>,
        &target,
        None::<&IReference<f32>>,
        true,
    )?;
    TABLES.with_borrow_mut(|t| {
        if let Some(w) = t.get_mut(&id) {
            w.at = offset.max(0.0);
            w.commanded = 3;
        }
    });
    Ok(())
}

/// Drive one table's report to a fixpoint. Each round acts on at most one
/// thing and answers whether it moved, so a settled tier costs one round.
fn table_settle(core: &mut CoreState, id: u64) {
    for _ in 0..TABLE_SETTLE_ROUNDS {
        match table_report_once(core, id) {
            Ok(true) => continue,
            Ok(false) => return,
            Err(e) => {
                crate::fault::report(format!("kaya: reporting a row window failed: {e}"));
                return;
            }
        }
    }
}

/// Measure each column's content width — the widest of the header cell
/// and that column's body cells, at their natural size.
fn table_measure(table: &WinTable) -> windows_core::Result<Vec<f64>> {
    let unbounded = bindings::Windows::Foundation::Size {
        Width: f32::INFINITY,
        Height: f32::INFINITY,
    };
    let mut floors = vec![0.0f64; table.titles.len()];
    for (column, cell) in table.cells.iter().enumerate() {
        cell.Measure(unbounded)?;
        floors[column] = floors[column].max(f64::from(cell.DesiredSize()?.Width));
    }
    for row in &table.rows {
        let children = row.Children()?;
        for at in 0..children.Size()? {
            let cell = children.GetAt(at)?;
            let column = Grid::GetColumn(&cell.cast::<FrameworkElement>()?)? as usize;
            if column >= floors.len() {
                continue;
            }
            cell.Measure(unbounded)?;
            floors[column] = floors[column].max(f64::from(cell.DesiredSize()?.Width));
        }
    }
    Ok(floors)
}

/// THE GEOMETRY RULE, this backend's spelling: content is each column's
/// FLOOR, the leftover track width divides equally, and header and rows
/// take the same explicit tracks, so the cells share leading edges by
/// construction (docs/tables-plan.md decision 6).
fn table_widths(table: &WinTable, track: f64) -> Vec<f64> {
    let cols = table.floors.len();
    let mut widths = table.floors.clone();
    if cols == 0 {
        return widths;
    }
    let content: f64 = widths.iter().sum();
    let leftover = track - content - TABLE_COL_GAP * (cols as f64 - 1.0);
    if leftover > 0.0 {
        let per = leftover / cols as f64;
        for w in &mut widths {
            *w += per;
        }
    }
    widths
}

#[cfg(any(feature = "harness", test))]
fn table_content_fits(content: f64, viewport: f64) -> bool {
    content <= viewport + 2.0
}

/// ONE CAUSE PER SENTENCE for `column_edges`' horizontal half — gtk.rs's
/// variant set plus `ColumnsUnreachable`, since a disjunction would print one
/// sentence for six causes (invariant 3). EVERY NUMBER IS IN THE GRID'S
/// CONTENT BOX: XAML gives a UIElement's coordinate space its PADDING box
/// where GTK4 gives the content box. COLUMNS PAST THE VIEWPORT ARE NOT THE
/// DEFECT: what is left is columns the surface CANNOT REACH, hence `reach`.
#[cfg(any(feature = "harness", test))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TableHorizontalIssue {
    TrackUnderfill,
    ColumnsUnreachable,
    ContentLeftUnderfill,
    ContentLeftOverflow,
    ContentUnderfill,
    ContentUnreachable,
}

/// `drawn` is the resolved column tracks plus their spacing, `track` what the
/// parent gave the table, `viewport` the table surface's own width — all in
/// the grid's content box. THE THREE EDGE NUMBERS DO NOT SHARE A BASIS
/// (docs/deferred.md):
///   `min_start`  the leftmost cell's INK — cells sit at their tracks'
///                leading edges here, so it reads flush.
///   `min_end`    the SHORTEST of the lines' TRACK ends. Ink cannot serve: a
///                cell is not stretched to its track. This is the
///                header-versus-rows instrument.
///   `max_end`    the furthest cell's INK, the only basis that can see ink
///                spilling PAST its own track.
/// `reach` is the host's own ScrollableWidth, never an arithmetic over the
/// numbers beside it.
#[cfg(any(feature = "harness", test))]
fn table_horizontal_issue(
    drawn: f64,
    track: f64,
    viewport: f64,
    min_start: f64,
    min_end: f64,
    max_end: f64,
    reach: f64,
) -> Option<TableHorizontalIssue> {
    if drawn < track - 2.0 {
        Some(TableHorizontalIssue::TrackUnderfill)
    } else if drawn > viewport + reach + 2.0 {
        Some(TableHorizontalIssue::ColumnsUnreachable)
    } else if min_start > 2.0 {
        Some(TableHorizontalIssue::ContentLeftUnderfill)
    } else if min_start < -2.0 {
        Some(TableHorizontalIssue::ContentLeftOverflow)
    } else if min_end < viewport - 2.0 {
        Some(TableHorizontalIssue::ContentUnderfill)
    } else if max_end > viewport + reach + 2.0 {
        Some(TableHorizontalIssue::ContentUnreachable)
    } else {
        None
    }
}

/// ONE CELL'S TWO BASES, in the table surface's own space: where the cell
/// DRAWS, and where its Grid TRACK is. THEY ARE DIFFERENT ON THIS BACKEND,
/// and believing otherwise cost a windows lane (docs/deferred.md):
/// `flush_tracks` stamps Stretch on FLEX children and a table's cells are not
/// flex children, so a cell's ActualWidth is its own content.
#[cfg(any(feature = "harness", test))]
#[derive(Debug, Clone, Copy)]
struct TableCellBox {
    ink_start: f64,
    ink_end: f64,
    track_start: f64,
    track_end: f64,
}

/// One line's trailing edge: the far side of the furthest TRACK any of its
/// cells occupies, or None for a line with no placed cell.
///
/// THE TRACK, NEVER THE INK. gtk.rs's cells FILL their columns, so its
/// line end IS the track edge and one read answers both; reading ink here
/// would put a different question in the same sentence.
#[cfg(any(feature = "harness", test))]
fn table_line_end(cells: &[TableCellBox]) -> Option<f64> {
    cells.iter().fold(None, |far: Option<f64>, cell| {
        Some(far.map_or(cell.track_end, |edge| edge.max(cell.track_end)))
    })
}

/// `column_edges`' FIVE NUMBERS, moved into the grid's CONTENT box.
/// TransformToVisual's origin is the grid's PADDING box and
/// `assigned_track`/`ActualWidth` are its OUTER one, so `pad` comes off each —
/// and `pad` includes the table card's interior (`container_padding`), which
/// lets the card hold content off its stroke without moving a cell edge.
#[cfg(any(feature = "harness", test))]
fn table_content_frame(
    pad: f64,
    track: f64,
    viewport: f64,
    ink: (f64, f64, f64),
) -> (f64, f64, f64, f64, f64) {
    let (min_start, min_end, max_end) = ink;
    (
        track - 2.0 * pad,
        viewport - 2.0 * pad,
        min_start - pad,
        min_end - pad,
        max_end - pad,
    )
}

/// The convicting sentence for each cause, or empty when there is none.
/// PURE and separate from the read, so `mod tests` can pin it.
#[cfg(any(feature = "harness", test))]
fn table_horizontal_complaint(
    drawn: f64,
    track: f64,
    viewport: f64,
    min_start: f64,
    min_end: f64,
    max_end: f64,
    reach: f64,
) -> String {
    let dip = |x: f64| x.round() as i64;
    match table_horizontal_issue(drawn, track, viewport, min_start, min_end, max_end, reach) {
        Some(TableHorizontalIssue::TrackUnderfill) => {
            format!("draws {}dip of a {}dip track", dip(drawn), dip(track))
        }
        Some(TableHorizontalIssue::ColumnsUnreachable) => format!(
            "columns resolve to {}dip in a {}dip viewport that scrolls {}dip",
            dip(drawn),
            dip(viewport),
            dip(reach)
        ),
        Some(TableHorizontalIssue::ContentLeftUnderfill) => format!(
            "cells start at {}dip inside a {}dip viewport",
            dip(min_start),
            dip(viewport)
        ),
        Some(TableHorizontalIssue::ContentLeftOverflow) => format!(
            "cells start at {}dip outside a {}dip viewport",
            dip(min_start),
            dip(viewport)
        ),
        Some(TableHorizontalIssue::ContentUnderfill) => format!(
            "draws {}dip of a {}dip viewport",
            dip(min_end),
            dip(viewport)
        ),
        Some(TableHorizontalIssue::ContentUnreachable) => format!(
            "cells end at {}dip past a {}dip viewport that scrolls {}dip",
            dip(max_end),
            dip(viewport),
            dip(reach)
        ),
        None => String::new(),
    }
}

/// Write one table's tracks onto the header and every row, if they moved.
/// Idempotent BY DESIGN, because it runs from a layout callback: a write
/// invalidates layout, and a pass that wrote unconditionally would never
/// let the tree settle.
fn table_stamp(table: &mut WinTable) -> windows_core::Result<()> {
    let inner = table.grid.ActualWidth()? - 2.0 * table.pad;
    if inner <= 0.0 {
        // No track to divide — before the first layout, and again while
        // the window is closing. Neither is a table to size.
        return Ok(());
    }
    let widths = table_widths(table, inner);
    if table.stamped == table.rows
        && widths.len() == table.applied.len()
        && widths
            .iter()
            .zip(&table.applied)
            .all(|(a, b)| (a - b).abs() < 0.5)
    {
        return Ok(());
    }
    let stamp = |defs: &ColumnDefinitionCollection| -> windows_core::Result<()> {
        defs.Clear()?;
        for width in &widths {
            let def = ColumnDefinition::new()?;
            def.SetWidth(GridLength {
                Value: *width,
                GridUnitType: GridUnitType::Pixel,
            })?;
            defs.Append(&def)?;
        }
        Ok(())
    };
    stamp(&table.header.ColumnDefinitions()?)?;
    for row in &table.rows {
        row.SetColumnSpacing(TABLE_COL_GAP)?;
        stamp(&row.ColumnDefinitions()?)?;
    }
    if trace_enabled() {
        // FLOOR VERSUS SIZE, on the guest. `column_edges` proves the
        // clusters and the span; only this says whether the floors were
        // ever REAL — zero floors evenly split satisfy both halves while
        // clipping any content wider than its share.
        eprintln!(
            "kaya: winui table {:?} floors {:?} widths {:?} inner {inner:.1} rows {}",
            table.titles,
            table.floors.iter().map(|w| w.round() as i64).collect::<Vec<_>>(),
            widths.iter().map(|w| w.round() as i64).collect::<Vec<_>>(),
            table.rows.len()
        );
    }
    table.applied = widths;
    table.stamped = table.rows.clone();
    Ok(())
}

/// One table's measure-and-stamp. Reached from the drain and from every
/// layout, so it tolerates a borrow it cannot take (the pass it skipped
/// is the pass the next layout runs) and a control it cannot measure.
fn table_pass(id: u64) {
    TABLES.with(|tables| {
        let Ok(mut tables) = tables.try_borrow_mut() else {
            return;
        };
        let Some(table) = tables.get_mut(&id) else {
            return;
        };
        if table.dirty {
            match table_measure(table) {
                Ok(floors) => {
                    table.probes += 1;
                    // A zero is "not measurable yet", never a real width:
                    // the core refuses an empty title, so every column
                    // has a header cell with ink in it.
                    let real = floors.iter().all(|w| *w > 0.0);
                    if real || table.floors.is_empty() {
                        table.floors = floors;
                    }
                    table.dirty = !real && table.probes < TABLE_PROBE_LIMIT;
                }
                Err(_) => return,
            }
        }
        let _ = table_stamp(table);
    });
    schedule_report(id);
}

/// A user-driven back on the window's top entry: an intercept_back-armed
/// top emits back_requested and nothing pops (the veto class); an unarmed
/// top pops here, reconciles the core-owned stack post-fact, and reports
/// entry_popped.
fn user_back(core: &mut CoreState, window: u64) -> windows_core::Result<()> {
    // With sections present, back routes to the ACTIVE section's
    // stack — back never switches sections (DESIGN.md, Sections).
    let window = if core.sections.contains_key(&window) {
        core.selected_sections.get(&window).copied().unwrap_or(window)
    } else {
        window
    };
    let Some(&top) = core.nav_stacks.get(&window).and_then(|s| s.last()) else {
        return Ok(());
    };
    if core.nav_entries[&top].intercept_back {
        core.occurrences.send(Occurrence::BackRequested {
            entry: WindowId(top),
        });
        return Ok(());
    }
    core.nav_stacks.get_mut(&window).unwrap().pop();
    core.nav_entries.remove(&top);
    core.scene.user_popped(WindowId(top));
    refresh_nav(core, window)?;
    core.occurrences.send(Occurrence::EntryPopped {
        entry: WindowId(top),
    });
    Ok(())
}

/// The dirty marker: a LEADING ASTERISK, NO SPACE, prefixed to the
/// caption — the convention Windows apps use, measured on Notepad
/// 11.2606.15.0 (docs/dirty-plan.md, the windows arm).
const DIRTY_MARK: &str = "*";

/// The caption a window SHOULD be showing, composed: the covering nav
/// entry's title if the stack has one, else the window's own, with the
/// dirty marker in front when the app has declared unsaved work.
///
/// THE DECLARED TITLE IS NEVER TOUCHED (docs/dirty-plan.md D1): the
/// marker is composed here, on the way to the OS.
fn window_caption(core: &CoreState, window: u64) -> String {
    let title = core
        .nav_stacks
        .get(&window)
        .and_then(|s| s.last())
        .and_then(|id| core.nav_entries.get(id))
        .map(|e| e.title.clone())
        .unwrap_or_else(|| core.window_titles.get(&window).cloned().unwrap_or_default());
    // THE IDENTITY NAME IS THE WINDOW'S DEFAULT TITLE, never an override
    // of one (docs/app-identity-plan.md I9).
    let title = if title.is_empty() {
        APP_IDENTITY.with_borrow(|slot| {
            slot.as_ref().map_or_else(String::new, |identity| identity.name.clone())
        })
    } else {
        title
    };
    if core.window_dirty.get(&window).copied().unwrap_or(false) {
        format!("{DIRTY_MARK}{title}")
    } else {
        title
    }
}

/// THE ONE CAPTION WRITER: every `Window::SetTitle` past the pre-app
/// placeholder in `setup()` goes through here, and a promoted window's
/// caption TextBlock is the second sink. `TitleBar::UpdateTitle` writes
/// `appWindow.Title` from its own `Title` property (microsoft-ui-xaml @
/// winui3/release/2.2.0, `TitleBar.cpp:505-513`), and the first casualty of
/// two writers is the dirty marker — so that property is left empty.
fn refresh_caption(core: &CoreState, window: u64) -> windows_core::Result<()> {
    let caption = HSTRING::from(window_caption(core, window));
    let target = winui_window(core, window)?;
    target.SetTitle(&caption)?;
    if let Some(text) = core.window_caption_texts.get(&window) {
        text.SetText(&caption)?;
    }
    Ok(())
}

/// The visible stack positions at a ceiling of three, folded from BOTH
/// views' Modes — never a width kaya measured — plus slot occupancy: an
/// empty slot is a visible column but not a pane
/// (docs/multicolumn-plan.md D1/D4). None when no three-pane nest is up.
fn three_pane_positions(core: &CoreState, window: u64) -> Option<Vec<u64>> {
    let outer = core.split_views.get(&window)?;
    let inner = core.inner_splits.get(&window)?;
    let entries = core.nav_stacks.get(&window).map_or(0, |s| s.len()) as u64;
    let outer_wide = outer.Mode().ok()? != TwoPaneViewMode::SinglePane;
    let inner_wide = inner.Mode().ok()? != TwoPaneViewMode::SinglePane;
    let inner_positions = |v: &mut Vec<u64>| {
        if inner_wide {
            if entries >= 1 {
                v.push(1);
            }
            if entries >= 2 {
                v.push(entries);
            }
        } else if entries >= 2 {
            v.push(entries);
        } else if entries >= 1 {
            v.push(1);
        }
    };
    let mut positions = Vec::new();
    if outer_wide {
        positions.push(0);
        inner_positions(&mut positions);
    } else if entries >= 1 {
        inner_positions(&mut positions);
    } else {
        positions.push(0);
    }
    Some(positions)
}

/// The back affordance at a ceiling of three: the TOP entry's bar,
/// visible exactly when popping would REVEAL a covered surface into a
/// visible slot; every other entry's bar stays collapsed.
fn apply_three_pane_back_bar(core: &CoreState, window: u64) -> windows_core::Result<()> {
    let entries = core.nav_stacks.get(&window).cloned().unwrap_or_default();
    let count = entries.len() as u64;
    let reveal = count >= 1
        && three_pane_positions(core, window)
            .is_some_and(|positions| !positions.contains(&(count - 1)));
    for (i, id) in entries.iter().enumerate() {
        if let Some(back) = core.nav_entries.get(id).and_then(|e| e.back_button.clone()) {
            let back: UIElement = back.cast()?;
            let is_top = i + 1 == entries.len();
            back.SetVisibility(if is_top && reveal {
                Visibility::Visible
            } else {
                Visibility::Collapsed
            })?;
        }
    }
    Ok(())
}

/// The ceiling-3 arm: pane 0 the base root, pane 1 the first entry, the
/// trailing pane the REST of the stack's top — two nested TwoPaneViews,
/// the inner in the outer's STAR-SIZED Pane2 (an auto-sized parent gives
/// it no width to measure its own threshold against). Returns false when
/// the window has no root yet.
fn refresh_three_panes(core: &mut CoreState, window: u64) -> windows_core::Result<bool> {
    let Some(base) = core.window_roots.get(&window).cloned() else {
        return Ok(false);
    };
    let entries = core.nav_stacks.get(&window).cloned().unwrap_or_default();
    let first = entries.first().copied();
    let deep_top = if entries.len() >= 2 { entries.last().copied() } else { None };
    let content = first
        .and_then(|id| core.nav_entries.get(&id))
        .and_then(|e| e.wrapper.clone());
    let detail = deep_top
        .and_then(|id| core.nav_entries.get(&id))
        .and_then(|e| e.wrapper.clone());

    let width = window_client_width(core, window).unwrap_or(0.0);
    let outer_lead = crate::protocol::leading_pane_width(width);

    let inner = TwoPaneView::new()?;
    inner.SetMinTallModeHeight(f64::INFINITY)?;
    inner.SetWideModeConfiguration(TwoPaneViewWideModeConfiguration::LeftRight)?;
    inner.SetPane1Length(GridLength {
        Value: crate::protocol::leading_pane_width((width - outer_lead).max(0.0)),
        GridUnitType: GridUnitType::Pixel,
    })?;
    inner.SetPane2Length(GridLength {
        Value: 1.0,
        GridUnitType: GridUnitType::Star,
    })?;
    inner.SetPanePriority(if deep_top.is_some() {
        TwoPaneViewPriority::Pane2
    } else {
        TwoPaneViewPriority::Pane1
    })?;
    let content_el: UIElement = match &content {
        Some(c) => windows_core::Interface::cast(c)?,
        None => windows_core::Interface::cast(&Grid::new()?)?,
    };
    let detail_el: UIElement = match &detail {
        Some(d) => windows_core::Interface::cast(d)?,
        None => windows_core::Interface::cast(&Grid::new()?)?,
    };
    inner.SetPane1(&content_el)?;
    inner.SetPane2(&detail_el)?;

    let outer = TwoPaneView::new()?;
    outer.SetMinTallModeHeight(f64::INFINITY)?;
    outer.SetWideModeConfiguration(TwoPaneViewWideModeConfiguration::LeftRight)?;
    outer.SetPane1Length(GridLength {
        Value: outer_lead,
        GridUnitType: GridUnitType::Pixel,
    })?;
    outer.SetPane2Length(GridLength {
        Value: 1.0,
        GridUnitType: GridUnitType::Star,
    })?;
    outer.SetPanePriority(if entries.is_empty() {
        TwoPaneViewPriority::Pane1
    } else {
        TwoPaneViewPriority::Pane2
    })?;
    detach_window_content(core, window)?;
    outer.SetPane1(&base)?;
    let inner_el: UIElement = windows_core::Interface::cast(&inner)?;
    outer.SetPane2(&inner_el)?;
    core.split_views.insert(window, outer.clone());
    core.inner_splits.insert(window, inner.clone());
    let el: UIElement = windows_core::Interface::cast(&outer)?;
    set_window_content(core, window, &el)?;
    refresh_caption(core, window)?;
    // Mode is decided during layout, so a build-time read alone would
    // predate this arrangement (docs/traps.md).
    apply_three_pane_back_bar(core, window)?;
    let handler = TypedEventHandler::new(move |_, _| {
        CORE.with_borrow_mut(|core| {
            let Some(core) = core.as_mut() else { return Ok(()) };
            apply_three_pane_back_bar(core, window)
        })
    });
    outer.ModeChanged(&handler)?;
    let handler = TypedEventHandler::new(move |_, _| {
        CORE.with_borrow_mut(|core| {
            let Some(core) = core.as_mut() else { return Ok(()) };
            apply_three_pane_back_bar(core, window)
        })
    });
    inner.ModeChanged(&handler)?;
    Ok(true)
}

/// Reconcile the window's visible state with its stack: the top
/// entry's wrapper and title (the entry title IS the window title
/// while covered), or the window's own root and title when the stack
/// empties.
fn refresh_nav(core: &mut CoreState, window: u64) -> windows_core::Result<()> {
    // A section host reconciles its PANE, not a window (stacks are
    // per-surface; DESIGN.md, Sections).
    if core.section_panes.contains_key(&window) {
        return refresh_section_pane(core, window);
    }
    let top = core.nav_stacks.get(&window).and_then(|s| s.last()).copied();

    // Whichever arm is about to run, the previous split render must let
    // go of the roots first.
    release_split(core, window)?;
    // docs/multicolumn-plan.md: the ceiling is the app's one declaration;
    // how many panes fit is each TwoPaneView's own Mode.
    let ceiling = core.panes.get(&window).copied().unwrap_or(1);
    if ceiling >= 3 && refresh_three_panes(core, window)? {
        return Ok(());
    }
    let wants_split = ceiling == 2;
    // Short-circuited on wants_split: a window reconciling before its
    // first mount has no content to measure.
    let measured = window_client_width(core, window);
    if std::env::var("KAYA_SPLIT_TRACE").is_ok() {
        eprintln!(
            "KAYA_SPLIT_TRACE: window={window} wants_split={wants_split} \
             measured={measured:?} entries={}",
            core.nav_stacks.get(&window).map(|s| s.len()).unwrap_or(0)
        );
    }
    // No width test here (TwoPaneView decides off its own
    // MinWideModeWidth) and no `top.is_some()` either: an empty stack on
    // a wide window shows the leading pane and an EMPTY trailing one.
    if wants_split {
        let base = core.window_roots.get(&window).cloned();
        let detail = top
            .and_then(|id| core.nav_entries.get(&id))
            .and_then(|e| e.wrapper.clone());
        if let Some(base) = base {
            let view = TwoPaneView::new()?;
            // Tall mode is killed the platform's own way: a
            // compact-width window TALLER than 641 otherwise stacks both
            // panes top-over-bottom, and every scene height is 600
            // (docs/multicolumn-plan.md; check-steps holds this call
            // present on every TwoPaneView).
            view.SetMinTallModeHeight(f64::INFINITY)?;
            view.SetWideModeConfiguration(TwoPaneViewWideModeConfiguration::LeftRight)?;
            // TwoPaneView's own default is two equal panes (it was
            // built for dual-SCREEN devices); the proportion stays ours —
            // see protocol::leading_pane_width.
            let lead = crate::protocol::leading_pane_width(
                window_client_width(core, window).unwrap_or(0.0),
            );
            view.SetPane1Length(GridLength {
                Value: lead,
                GridUnitType: GridUnitType::Pixel,
            })?;
            view.SetPane2Length(GridLength {
                Value: 1.0,
                GridUnitType: GridUnitType::Star,
            })?;
            view.SetPanePriority(if top.is_some() {
                TwoPaneViewPriority::Pane2
            } else {
                TwoPaneViewPriority::Pane1
            })?;
            let detail: UIElement = match &detail {
                Some(d) => windows_core::Interface::cast(d)?,
                None => windows_core::Interface::cast(&Grid::new()?)?,
            };
            // The window is still holding the base root at this point.
            detach_window_content(core, window)?;
            view.SetPane1(&base)?;
            view.SetPane2(&detail)?;
            core.split_views.insert(window, view.clone());
            let el: UIElement = windows_core::Interface::cast(&view)?;
            set_window_content(core, window, &el)?;
            // With an empty stack the window keeps its OWN title: an
            // empty one degrades to the process name
            // (docs/multicolumn-plan.md).
            refresh_caption(core, window)?;
            // Mode is decided during layout, so reading it here alone
            // would predate this pane arrangement (docs/traps.md).
            apply_split_back_bar(core, window)?;
            let handler = TypedEventHandler::new(move |_, _| {
                CORE.with_borrow_mut(|core| {
                    let Some(core) = core.as_mut() else { return Ok(()) };
                    apply_split_back_bar(core, window)
                })
            });
            view.ModeChanged(&handler)?;
            return Ok(());
        }
    }
    core.split_presentation.insert(window, "stacked");

    match top.and_then(|id| core.nav_entries.get(&id)) {
        Some(entry) => {
            // Collapsed: the entry COVERS the leading pane, so back
            // means something again. Both arms must write it.
            if let Some(back) = &entry.back_button {
                let back: UIElement = back.cast()?;
                back.SetVisibility(Visibility::Visible)?;
            }
            if let Some(wrapper) = &entry.wrapper {
                let wrapper: UIElement = windows_core::Interface::cast(wrapper)?;
                set_window_content(core, window, &wrapper)?;
            }
        }
        None => {
            if let Some(root) = core.window_roots.get(&window) {
                let root = root.clone();
                set_window_content(core, window, &root)?;
            }
        }
    }
    refresh_caption(core, window)
}

/// Fill a navigation entry at mount: the wrapper Grid is the backend's
/// chrome — an auto-height back bar over a star-height row holding the
/// entry's root.
fn mount_entry(
    core: &mut CoreState,
    entry_id: u64,
    element: UIElement,
) -> windows_core::Result<()> {
    let wrapper = Grid::new()?;
    let defs = wrapper.RowDefinitions()?;
    let bar = RowDefinition::new()?;
    bar.SetHeight(GridLength {
        Value: 1.0,
        GridUnitType: GridUnitType::Auto,
    })?;
    defs.Append(&bar)?;
    let fill = RowDefinition::new()?;
    fill.SetHeight(GridLength {
        Value: 1.0,
        GridUnitType: GridUnitType::Star,
    })?;
    defs.Append(&fill)?;
    let back = Button::new()?;
    let caption = text_block()?;
    caption.SetText(&HSTRING::from("\u{2190}"))?;
    back.SetContent(&caption)?;
    let host = core.nav_entries[&entry_id].window;
    let handler = RoutedEventHandler::new(move |_, _| {
        // Fires from the message loop, never under an apply borrow.
        CORE.with_borrow_mut(|core| {
            let Some(core) = core.as_mut() else { return Ok(()) };
            user_back(core, host)
        })
    });
    back.Click(&handler)?;
    let back_el: FrameworkElement = back.cast()?;
    Grid::SetRow(&back_el, 0)?;
    wrapper.Children()?.Append(&back_el)?;
    let content_el: FrameworkElement = element.cast()?;
    Grid::SetRow(&content_el, 1)?;
    wrapper.Children()?.Append(&element)?;
    let entry = core.nav_entries.get_mut(&entry_id).unwrap();
    entry.wrapper = Some(wrapper);
    entry.back_button = Some(back);
    if core.nav_stacks.get(&host).and_then(|s| s.last()) == Some(&entry_id) {
        refresh_nav(core, host)?;
    }
    Ok(())
}

/// Assemble the window's sections chrome: a NavigationView whose items
/// are the sections (string content — docs/traps.md: a WinUI ComboBoxItem
/// with UIElement content gets STOLEN) and whose Content is the active
/// pane. Built ONCE and grown incrementally (XAML refuses re-parenting);
/// SelectionChanged is the USER route, raised async and guarded by the
/// swallow COUNTER.
fn refresh_sections(core: &mut CoreState, window: u64) -> windows_core::Result<()> {
    let ids = core.sections.get(&window).cloned().unwrap_or_default();
    if ids.is_empty() {
        return Ok(());
    }
    if !core.section_navs.contains_key(&window) {
        let nav = NavigationView::new()?;
        nav.SetIsSettingsVisible(false)?;
        nav.SetIsBackButtonVisible(
            bindings::Microsoft::UI::Xaml::Controls::NavigationViewBackButtonVisible::Collapsed,
        )?;
        let swallow =
            std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        core.section_swallow.insert(window, swallow.clone());
        let handler = bindings::Windows::Foundation::TypedEventHandler::new(
            move |nav: windows_core::Ref<NavigationView>, _| {
                use windows_core::Interface;
                // A programmatic move's late raise: the model and emit
                // were handled synchronously at the set.
                if swallow
                    .fetch_update(
                        std::sync::atomic::Ordering::Relaxed,
                        std::sync::atomic::Ordering::Relaxed,
                        |n| n.checked_sub(1),
                    )
                    .is_ok()
                {
                    return Ok(());
                }
                let Some(nav) = nav.as_ref() else { return Ok(()) };
                let Ok(selected) = nav.SelectedItem() else { return Ok(()) };
                let Ok(item) = selected.cast::<NavigationViewItem>() else {
                    return Ok(());
                };
                let Ok(tag) = item.Tag() else { return Ok(()) };
                let Ok(sid_ref) = tag.cast::<IReference<u64>>() else {
                    return Ok(());
                };
                let sid = sid_ref.Value()?;
                // Fires from the message loop, never under an apply
                // borrow.
                let mut emit = false;
                CORE.with_borrow_mut(|core| {
                    let Some(core) = core.as_mut() else { return };
                    if core.selected_sections.get(&window) == Some(&sid) {
                        return;
                    }
                    core.selected_sections.insert(window, sid);
                    core.ui_selected_sections.insert(window, sid);
                    core.scene
                        .user_selected_section(WindowId(window), WindowId(sid));
                    let _ = show_section_pane(core, window, sid);
                    emit = true;
                });
                if emit {
                    CORE.with_borrow(|core| {
                        if let Some(core) = core.as_ref() {
                            core.occurrences.send(Occurrence::SectionSelected {
                                window: WindowId(window),
                                section: WindowId(sid),
                            });
                        }
                    });
                }
                Ok(())
            },
        );
        nav.SelectionChanged(&handler)?;
        core.section_navs.insert(window, nav.clone());
        let nav_el: UIElement = windows_core::Interface::cast(&nav)?;
        set_window_content(core, window, &nav_el)?;
    }
    let nav = core.section_navs[&window].clone();
    for sid in &ids {
        if core.section_items.contains_key(sid) {
            continue;
        }
        let item = NavigationViewItem::new()?;
        let title = &core.section_panes[sid].title;
        // String content, never a UIElement child — the ComboBox
        // content-stealing trap (docs/traps.md).
        item.SetContent(&PropertyValue::CreateString(&HSTRING::from(&**title))?)?;
        item.SetTag(&PropertyValue::CreateUInt64(*sid)?)?;
        // The icon rides its OWN slot, not the content, so the title
        // stays a plain string and the trap above stays shut.
        apply_symbol(&item, core.section_panes[sid].symbol)?;
        nav.MenuItems()?.Append(&item)?;
        core.section_items.insert(*sid, item);
    }
    let hint = core
        .sections_presentation
        .get(&window)
        .copied()
        .unwrap_or(0);
    let bar_hint = i64::from(crate::wire::SECTIONS_PRESENTATION_BAR);
    nav.SetPaneDisplayMode(if hint == bar_hint {
        NavigationViewPaneDisplayMode::Top
    } else {
        NavigationViewPaneDisplayMode::Left
    })?;
    if let Some(sel) = core.selected_sections.get(&window).copied() {
        nav_set_selected(core, window, sel)?;
        show_section_pane(core, window, sel)?;
    }
    Ok(())
}

/// Move the switcher's selection programmatically: swallow the async
/// SelectionChanged raise (counter, not flag) and skip no-op moves, which
/// raise nothing and would leave the counter armed against a real switch.
fn nav_set_selected(
    core: &mut CoreState,
    window: u64,
    sid: u64,
) -> windows_core::Result<()> {
    if core.ui_selected_sections.get(&window) == Some(&sid) {
        return Ok(());
    }
    let (Some(nav), Some(item)) = (
        core.section_navs.get(&window).cloned(),
        core.section_items.get(&sid).cloned(),
    ) else {
        return Ok(());
    };
    if let Some(swallow) = core.section_swallow.get(&window) {
        swallow.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    }
    core.ui_selected_sections.insert(window, sid);
    nav.SetSelectedItem(&item)?;
    Ok(())
}

/// Put the section's pane into the NavigationView's content slot.
fn show_section_pane(
    core: &CoreState,
    window: u64,
    section: u64,
) -> windows_core::Result<()> {
    let (Some(nav), Some(record)) = (
        core.section_navs.get(&window),
        core.section_panes.get(&section),
    ) else {
        return Ok(());
    };
    nav.SetContent(&record.pane)?;
    Ok(())
}

/// Reconcile a section pane's visible child: its stack's top entry
/// wrapper while covered (stacks are per-surface), its own mounted
/// root otherwise.
fn refresh_section_pane(core: &mut CoreState, sid: u64) -> windows_core::Result<()> {
    let Some(record) = core.section_panes.get(&sid) else {
        return Ok(());
    };
    let top = core.nav_stacks.get(&sid).and_then(|s| s.last()).copied();
    let desired: Option<UIElement> = top
        .and_then(|id| core.nav_entries.get(&id))
        .and_then(|e| e.wrapper.clone())
        .map(|w| w.cast().expect("a Grid is a UIElement"))
        .or_else(|| record.root.clone());
    let children = record.pane.Children()?;
    children.Clear()?;
    if let Some(widget) = desired {
        children.Append(&widget)?;
    }
    Ok(())
}

/// WinUI's editable controls store every line break as a bare CR
/// (docs/traps.md: WinUI TextBox speaks CR, everything else speaks LF), so
/// CR is normalized to LF wherever that text escapes toward the guest or
/// is compared against guest text. The trailing paragraph mark is a
/// separate problem, dropped by `Editable::text`'s
/// `TextGetOptions::AdjustCrlf`.
fn lf(s: String) -> String {
    if s.contains('\r') {
        s.replace("\r\n", "\n").replace('\r', "\n")
    } else {
        s
    }
}

/// KAYA_WINUI_NAV_PROBE: wrap the primary mount in a NavigationView
/// ("bare" = no items; anything else adds two string items). The
/// stowed-E_NOINTERFACE bisection instrument (docs/traps.md).
fn nav_probe_wrap(element: &UIElement) -> windows_core::Result<UIElement> {
    use bindings::Microsoft::UI::Xaml::Controls::{NavigationView, NavigationViewItem};
    let level = std::env::var("KAYA_WINUI_NAV_PROBE").unwrap_or_default();
    if level.is_empty() {
        return Ok(element.clone());
    }
    eprintln!("kaya: NAV PROBE armed ({level})");
    // NavigationView's ResourceAccessor consults Application.Current at
    // runtime; with the outer discarding the inner, identity QIs for
    // IApplication die E_NOINTERFACE. Reproduce the exact lookup.
    match bindings::Microsoft::UI::Xaml::Application::Current() {
        Ok(app) => match app.Resources() {
            Ok(_) => eprintln!("kaya: PROBE Current().Resources() OK"),
            Err(e) => eprintln!(
                "kaya: PROBE Current().Resources() FAILED: {:?} {}",
                e.code(),
                e.message()
            ),
        },
        Err(e) => eprintln!(
            "kaya: PROBE Application::Current() FAILED: {:?} {}",
            e.code(),
            e.message()
        ),
    }
    let nav = NavigationView::new()?;
    nav.SetIsSettingsVisible(false)?;
    if level != "bare" {
        for title in ["Feed", "Archive"] {
            let item = NavigationViewItem::new()?;
            item.SetContent(&PropertyValue::CreateString(&HSTRING::from(title))?)?;
            nav.MenuItems()?.Append(&item)?;
        }
    }
    nav.SetContent(element)?;
    nav.cast()
}

// --- Menus: the command vocabulary (DESIGN.md, Menus) ---------------

/// Enablement is the AND of the item's own flag and every grouping
/// ancestor's — the inherited rule every read, render, shortcut, and
/// activation route shares (docs/traps.md).
fn menu_effective_enabled(core: &CoreState, item: u64) -> bool {
    let mut enabled = match core.menu_models.get(&item) {
        Some(m) => m.enabled,
        None => return false,
    };
    let mut current = item;
    while let Some(parent) = core.menu_models.get(&current).and_then(|m| m.parent) {
        enabled = enabled && core.menu_models.get(&parent).is_some_and(|m| m.enabled);
        current = parent;
    }
    enabled
}

/// Catalog preorder: top-level grouping nodes in menubar-append order,
/// then each node's children in append order, depth-first (the
/// promotion/shortcut-table order; creation time is irrelevant).
fn menu_preorder(core: &CoreState, roots: &[u64], out: &mut Vec<u64>) {
    for &id in roots {
        out.push(id);
        if let Some(children) = core.menu_models.get(&id).map(|m| m.children.clone()) {
            menu_preorder(core, &children, out);
        }
    }
}

/// Resolve a `>`-joined label path against root items, labels compared
/// byte-for-byte (the shared-scene contract). The path walks the SEMANTIC
/// tree: a grouping root's label is a path segment whether or not
/// materialization mints a titled row.
fn resolve_menu_path(core: &CoreState, path: &str, roots: &[u64]) -> Option<u64> {
    let mut current: Vec<u64> = roots.to_vec();
    let mut found = None;
    for seg in path.split('>') {
        let item = *current
            .iter()
            .find(|id| core.menu_models.get(id).is_some_and(|m| m.label == seg))?;
        found = Some(item);
        current = core.menu_models[&item].children.clone();
    }
    found
}

/// Build the window shell at the first menubar_append: an Auto row for the
/// TITLEBAR, an Auto row for the MenuBar, and a Star content slot every
/// later mount/nav/sections swap fills. Built ONCE; content the window
/// already presents is DETACHED first, since XAML refuses re-parenting
/// (docs/traps.md). The titlebar row is filled later by `refresh_toolbar`;
/// the MenuBar may leave row 1 for `TitleBar.LeftHeader` (chrome-plan C2).
fn ensure_menu_shell(core: &mut CoreState, window: u64) -> windows_core::Result<()> {
    use windows_core::Interface as _;
    if core.menubars.contains_key(&window) {
        return Ok(());
    }
    // The MenuBar's items are realized by a LAYOUT PASS, not by the
    // append below, so the failure this guards would otherwise land
    // milliseconds later on a dispatcher tick.
    require_control_resources("this window declares a menu");
    let target = winui_window(core, window)?;
    let shell = Grid::new()?;
    let defs = shell.RowDefinitions()?;
    let bar_row = RowDefinition::new()?;
    bar_row.SetHeight(GridLength {
        Value: 1.0,
        GridUnitType: GridUnitType::Auto,
    })?;
    defs.Append(&bar_row)?;
    let toolbar_row = RowDefinition::new()?;
    toolbar_row.SetHeight(GridLength {
        Value: 1.0,
        GridUnitType: GridUnitType::Auto,
    })?;
    defs.Append(&toolbar_row)?;
    let fill = RowDefinition::new()?;
    fill.SetHeight(GridLength {
        Value: 1.0,
        GridUnitType: GridUnitType::Star,
    })?;
    defs.Append(&fill)?;
    let bar = MenuBar::new()?;
    let bar_el: FrameworkElement = bar.cast()?;
    Grid::SetRow(&bar_el, MENUBAR_ROW)?;
    shell.Children()?.Append(&bar_el)?;
    let slot = Grid::new()?;
    let slot_el: FrameworkElement = slot.cast()?;
    Grid::SetRow(&slot_el, TOOLBAR_CONTENT_ROW)?;
    shell.Children()?.Append(&slot_el)?;
    let old = target.Content().ok();
    target.SetContent(&shell.cast::<UIElement>()?)?;
    if let Some(old) = old {
        slot.Children()?.Append(&old)?;
    }
    core.menubars.insert(window, bar);
    core.menu_slots.insert(window, slot);
    core.menu_shells.insert(window, shell);
    Ok(())
}

/// The width one promoted command occupies in the caption band: the cell
/// is square and its side is the band — `AppBarThemeCompactHeight` (48).
/// `AppBarButton`'s own default of 68 is a TOOLBAR metric, sized for a
/// strip where the label sits under the icon (docs/chrome-plan.md C2).
const CAPTION_COMMAND_CELL: f64 = 48.0;

/// The theme key holding the height an `AppBarButton`'s own template is
/// laid out for (64), which is NOT the height of the caption row it sits
/// in (48): laid out against 48 the hover border is 16 DIP too short and
/// cuts across the icon. The button is given its own template's height and
/// the CommandBar's `Grid.Clip` takes the empty label row back off, for
/// rendering and hit-testing both (docs/chrome/winui-clip.md §2).
const CAPTION_COMMAND_BUTTON_BOX_KEY: &str = "AppBarThemeMinHeight";

/// The width of the drag strip between the promoted commands and the
/// system's minimize/maximize/close, in DIP: the band's own
/// element-to-element gap, overriding `TitleBarMinDragRegionWidth`'s 48
/// (docs/chrome/winui-caption-gap.md). SEPARATION, not the drag affordance
/// — the star-sized Content column is the drag surface.
const CAPTION_DRAG_STRIP: f64 = 8.0;

/// Write `CAPTION_DRAG_STRIP` into the application's resource dictionary
/// under the `TitleBar` control's own key. A DIRECT entry rather than a
/// merged dictionary: a dictionary's own keys are searched first, so this
/// wins whatever is appended later. CALLED AT THE MINT, BEFORE THE FIRST
/// `TitleBar` EXISTS — a resource value changed after a tree is built does
/// not re-flow it (docs/chrome/winui-caption-gap.md).
fn apply_caption_drag_strip() -> windows_core::Result<()> {
    const KEY: &str = "TitleBarMinDragRegionWidth";
    APP.with_borrow(|app| {
        let app = app
            .as_ref()
            .expect("the toolbar lowering runs on the UI thread, where APP lives");
        let resources = app.Resources()?;
        resources.Insert(
            &PropertyValue::CreateString(&HSTRING::from(KEY))?,
            &PropertyValue::CreateDouble(CAPTION_DRAG_STRIP)?,
        )?;
        let readback: f64 = resources
            .Lookup(&PropertyValue::CreateString(&HSTRING::from(KEY))?)?
            .cast::<IReference<f64>>()?
            .Value()?;
        assert!(
            readback == CAPTION_DRAG_STRIP,
            "kaya: winui: the application resource dictionary was asked for \
             {KEY} = {CAPTION_DRAG_STRIP} and answers {readback}. That key is \
             the whole width of the TitleBar template's column 10 \
             (TitleBar-v220.xaml:190), which is the gap between this window's \
             promoted commands and the system's minimize/maximize/close, so a \
             dictionary that did not take the write would silently give the \
             band back its 48 DIP reserve. This says nothing about whether the \
             CONTROL consumed the value - that is a layout fact and is measured \
             on the lane - only that the dictionary this process hands to XAML \
             does not hold the number kaya wrote."
        );
        Ok(())
    })
}

thread_local! {
    /// Set by `refresh_toolbar`, cleared by the first caption layout pass
    /// that had something arranged to measure. UI-thread only, and it
    /// touches no core state: the layout callback that reads it runs
    /// inside `refresh_toolbar`'s own `RecomputeDragRegions`, which holds
    /// the `CORE` borrow.
    static CAPTION_GEOMETRY_ARMED: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// The height an `AppBarButton`'s own template is laid out for, read out
/// of the theme dictionary rather than written down here. A MISSING KEY IS
/// FATAL: a guess would put the hover visual back across the icon with
/// nothing to notice it.
fn caption_command_button_box() -> windows_core::Result<f64> {
    APP.with_borrow(|app| {
        let app = app
            .as_ref()
            .expect("the toolbar lowering runs on the UI thread, where APP lives");
        let key = CAPTION_COMMAND_BUTTON_BOX_KEY;
        let found = app
            .Resources()?
            .Lookup(&PropertyValue::CreateString(&HSTRING::from(key))?)
            .and_then(|v| v.cast::<IReference<f64>>())
            .and_then(|v| v.Value());
        match found {
            Ok(value) => Ok(value),
            Err(err) => panic!(
                "kaya: winui: the application resource dictionary publishes no \
                 {key} ({err:?}). That key is the height an AppBarButton's own \
                 template is laid out for, and the two margins that place a \
                 promoted command's hover visual — \
                 AppBarButtonInnerBorderCompactMargin's bottom 22 and \
                 AppBarButtonContentViewboxCollapsedMargin's top 16 — are only \
                 concentric at that height. Its absence means the pinned WinUI \
                 moved under this backend, and guessing the number would put \
                 the hover box back across the icon with nothing to see it."
            ),
        }
    })
}

/// The first descendant of `root` carrying `name` as its template name.
fn named_descendant(root: &UIElement, name: &str) -> windows_core::Result<Option<FrameworkElement>> {
    use bindings::Microsoft::UI::Xaml::Media::VisualTreeHelper;
    if let Ok(fe) = root.cast::<FrameworkElement>() {
        if fe.Name()? == name {
            return Ok(Some(fe));
        }
    }
    for i in 0..VisualTreeHelper::GetChildrenCount(root)? {
        let child = VisualTreeHelper::GetChild(root, i)?;
        if let Ok(child) = child.cast::<UIElement>() {
            if let Some(hit) = named_descendant(&child, name)? {
                return Ok(Some(hit));
            }
        }
    }
    Ok(None)
}

/// THE TWO CAPTION-COMMAND GEOMETRIES THIS BACKEND OWNS, asserted against
/// the arrangement XAML actually produced: no scene can see either, since
/// every harness read goes through the button OBJECTS, and both writes fail
/// QUIETLY (a `{ThemeResource}` written after the template is applied is
/// ignored, and a button given no height still measures 48x48 to UIA).
/// Deferred to the caption's `LayoutUpdated`; an unarranged pass stays ARMED.
fn assert_caption_command_geometry(titlebar: &TitleBar) -> windows_core::Result<bool> {
    use bindings::Microsoft::UI::Xaml::Media::VisualTreeHelper;
    let band = titlebar.ActualHeight()?;
    if band <= 0.0 {
        return Ok(false);
    }
    let Ok(header) = titlebar
        .RightHeader()
        .and_then(|header| header.cast::<UIElement>())
    else {
        return Ok(true);
    };

    // THE OVERFLOW GLYPH'S BOX consumed the value kaya wrote.
    let ellipsis = named_descendant(&header, "EllipsisIcon")?;
    let Some(ellipsis) = ellipsis else {
        return Ok(false);
    };
    let box_height = ellipsis.ActualHeight()?;
    if box_height <= 0.0 {
        return Ok(false);
    }
    assert!(
        (box_height - CAPTION_ELLIPSIS_ICON_BOX).abs() < 0.5,
        "kaya: winui: the caption CommandBar's overflow glyph is arranged in \
         a box {box_height} DIP tall; kaya wrote \
         {CAPTION_ELLIPSIS_ICON_BOX} into the application dictionary under \
         AppBarExpandButtonCircleDiameter, which is what the template binds \
         that FontIcon's Height to. The library's own value for that key is 3 \
         against a FontSize of 20, and at 3 the glyph loses an anti-aliased \
         row off the bottom of every dot (measured 1:1, \
         docs/chrome/winui-clip.md). A box of the library's size means \
         the write did not reach the control — the usual cause is ordering: a \
         {{ThemeResource}} is resolved when the template is applied, so \
         apply_caption_ellipsis_box has to run BEFORE the CommandBar exists, \
         which is why it is welded into mint_caption_titlebar."
    );

    // EVERY PROMOTED COMMAND'S HOVER VISUAL IS CONCENTRIC WITH ITS ICON,
    // found by the names the AppBarButton template gives them.
    fn walk(node: &UIElement, band: f64, checked: &mut usize) -> windows_core::Result<()> {
        use bindings::Microsoft::UI::Xaml::Media::VisualTreeHelper;
        let mut border = None;
        for i in 0..VisualTreeHelper::GetChildrenCount(node)? {
            let child = VisualTreeHelper::GetChild(node, i)?;
            let Ok(child) = child.cast::<FrameworkElement>() else {
                continue;
            };
            if child.Name()? == "AppBarButtonInnerBorder" {
                border = Some(child);
            }
        }
        if let Some(border) = border {
            let root: UIElement = node.cast()?;
            if let Some(icon) = named_descendant(&root, "ContentViewbox")? {
                let within: UIElement = root.clone();
                let btop = border
                    .TransformToVisual(&within)?
                    .TransformPoint(Point { X: 0.0, Y: 0.0 })?
                    .Y as f64;
                let bh = border.ActualHeight()?;
                let itop = icon
                    .TransformToVisual(&within)?
                    .TransformPoint(Point { X: 0.0, Y: 0.0 })?
                    .Y as f64;
                let ih = icon.ActualHeight()?;
                if bh > 0.0 && ih > 0.0 {
                    *checked += 1;
                    let bcentre = btop + bh / 2.0;
                    let icentre = itop + ih / 2.0;
                    assert!(
                        (bcentre - icentre).abs() <= 1.0 && btop + bh <= band + 0.5,
                        "kaya: winui: a promoted command's hover visual is not on \
                         its own icon. The AppBarButtonInnerBorder — the element \
                         the template paints the pointer-over background into — \
                         is arranged {bh} DIP tall from y {btop}, centre \
                         {bcentre}; the ContentViewbox holding the icon is {ih} \
                         DIP tall from y {itop}, centre {icentre}; the caption \
                         band is {band} DIP. Those two centres agree only when \
                         the button is as tall as its own template assumes \
                         (AppBarThemeMinHeight, written by refresh_toolbar via \
                         caption_command_button_box): the closed CommandBar puts \
                         the button in the Compact visual state, whose \
                         AppBarButtonInnerBorderCompactMargin reserves 22 DIP at \
                         the bottom for a collapsed label, and in a 48 DIP \
                         caption row that leaves a 20 DIP box top-aligned at 6 \
                         whose lower edge cuts across the icon."
                    );
                }
            }
        }
        for i in 0..VisualTreeHelper::GetChildrenCount(node)? {
            let child = VisualTreeHelper::GetChild(node, i)?;
            if let Ok(child) = child.cast::<UIElement>() {
                walk(&child, band, checked)?;
            }
        }
        Ok(())
    }
    let mut checked = 0usize;
    walk(&header, band, &mut checked)?;
    // A BAR WITH BUTTONS IN IT AND NOTHING MEASURED is the vacuous pass
    // this check exists to refuse.
    let buttons = VisualTreeHelper::GetChildrenCount(&header)?;
    if buttons > 0 && checked == 0 {
        return Ok(false);
    }
    Ok(true)
}

/// The one place a `TitleBar` is constructed, so the one ordering it depends
/// on cannot be got wrong: `apply_caption_drag_strip` and
/// `apply_caption_ellipsis_box` write `{ThemeResource}` values, which are
/// resolved when the template is applied — write them afterwards and the
/// control keeps the library's number while NOTHING FAILS
/// (docs/chrome/winui-caption-gap.md).
fn mint_caption_titlebar() -> windows_core::Result<TitleBar> {
    apply_caption_drag_strip()?;
    apply_caption_ellipsis_box()?;
    let titlebar = TitleBar::new()?;
    // THE FAR-LEFT SLOT IS MINTED WITH THE BAND, so that "what is in
    // LeftHeader" has exactly one answer — see `caption_left_header`.
    titlebar.SetLeftHeader(&mint_caption_left_header()?.cast::<UIElement>()?)?;
    Ok(titlebar)
}

/// The mark's box and the gap after it, both the `TitleBar` control's own
/// numbers for its own icon: `TitleBarIconMaxWidth`/`MaxHeight` are 16 and
/// `TitleBarIconMargin` is `0,0,16,0`
/// (`v220-TitleBar_themeresources.xaml:88-92`).
const CAPTION_MARK_BOX: f64 = 16.0;
const CAPTION_MARK_GAP: f64 = 16.0;

/// The band a promoted caption is arranged in: `TitleBarExpandedHeight`,
/// the control's own 48 (`v220-TitleBar_themeresources.xaml:78`), which is
/// also the height the window's own caption cluster is given in `Tall`
/// mode.
const CAPTION_BAND_HEIGHT: f64 = 48.0;

/// THE MARK'S LEADING GAP, DERIVED RATHER THAN CHOSEN: a `CAPTION_MARK_BOX`
/// box centred in a `CAPTION_BAND_HEIGHT` band sits exactly this far below
/// the band's top, so the same number to its left makes the top and left
/// insets equal. The mark's cell is then 16+16+16 = 48, one caption cell;
/// `assert_caption_mark_geometry` fails if the two insets part.
const CAPTION_MARK_LEAD: f64 = (CAPTION_BAND_HEIGHT - CAPTION_MARK_BOX) / 2.0;

/// The two things that live at the caption's far left, in the order the
/// ruling puts them: the app's mark, then the window's menu.
const CAPTION_MARK_COLUMN: i32 = 0;
const CAPTION_MENU_COLUMN: i32 = 1;

/// `LeftHeader` takes ONE element and this band has two things that belong
/// at its left edge, so kaya owns a container there. Two Auto columns, so
/// an empty one measures ZERO. THE MARK'S WIDTH DOES NOT MOVE THE TITLE'S
/// CLAMP: the control's icon column (5) and the left-header column (3) are
/// BOTH left of the content slot (8), so `center_caption_title`'s `span0`
/// is unchanged.
fn mint_caption_left_header() -> windows_core::Result<Grid> {
    let holder = Grid::new()?;
    let columns = holder.ColumnDefinitions()?;
    for _ in 0..2 {
        let def = ColumnDefinition::new()?;
        def.SetWidth(GridLength {
            Value: 1.0,
            GridUnitType: GridUnitType::Auto,
        })?;
        columns.Append(&def)?;
    }
    // The control centres `LeftHeader` in the band already
    // (`TitleBarLeftHeaderVerticalAlignment`); this says the same about the
    // container's own contents, so a 16 DIP mark and a 32 DIP menu share
    // the band's centre line rather than stretching to it.
    holder.SetVerticalAlignment(bindings::Microsoft::UI::Xaml::VerticalAlignment::Center)?;
    Ok(holder)
}

/// kaya's far-left container, read back off the band.
///
/// A READ AND NOT A MAP, for the reason `rehost_menubar` gives about the
/// menu's own parent: the tree is the state, and a second copy of it kept
/// beside the tree is a second answer that can disagree.
fn caption_left_header(window: u64, titlebar: &TitleBar) -> windows_core::Result<Grid> {
    match titlebar
        .LeftHeader()
        .ok()
        .and_then(|header| header.cast::<Grid>().ok())
    {
        Some(holder) => Ok(holder),
        None => panic!(
            "kaya: winui: window {window}'s TitleBar has no far-left container in its \
             LeftHeader. mint_caption_titlebar puts one there when the band is minted, \
             and it is the only thing this backend ever writes to that slot: the app's \
             mark rides in its first column and the window's MenuBar in its second (the \
             ruling of 2026-08-18 — the mark goes BEFORE the menu, which the control's \
             own IconSource cannot do because it lays that out in template column 5, \
             after LeftHeader's column 3). A LeftHeader holding something else means a \
             second writer appeared; a LeftHeader holding nothing means the mint was \
             bypassed."
        ),
    }
}

/// The height of the box the CommandBar's "…" glyph is drawn in, in DIP —
/// 20 is the glyph's own font size, the literal in the same element. The
/// template gives `EllipsisIcon` a `Height` of
/// `AppBarExpandButtonCircleDiameter`, which is **3** in the shipped
/// dictionary: a 20 DIP glyph arranged in a 3 DIP box, with one
/// anti-aliased row of every dot cut off (docs/chrome/winui-clip.md §1-2).
const CAPTION_ELLIPSIS_ICON_BOX: f64 = 20.0;

/// Give the CommandBar's "…" a box its own glyph fits in, written through
/// `Application.Resources` under the platform's own key. Same timing rule
/// as `apply_caption_drag_strip`: a `{ThemeResource}` is resolved when the
/// template is applied, so this must be in the dictionary BEFORE the
/// `CommandBar` exists — hence welded into `mint_caption_titlebar`.
fn apply_caption_ellipsis_box() -> windows_core::Result<()> {
    const KEY: &str = "AppBarExpandButtonCircleDiameter";
    APP.with_borrow(|app| {
        let app = app
            .as_ref()
            .expect("the toolbar lowering runs on the UI thread, where APP lives");
        let resources = app.Resources()?;
        resources.Insert(
            &PropertyValue::CreateString(&HSTRING::from(KEY))?,
            &PropertyValue::CreateDouble(CAPTION_ELLIPSIS_ICON_BOX)?,
        )?;
        let readback: f64 = resources
            .Lookup(&PropertyValue::CreateString(&HSTRING::from(KEY))?)?
            .cast::<IReference<f64>>()?
            .Value()?;
        assert!(
            readback == CAPTION_ELLIPSIS_ICON_BOX,
            "kaya: winui: the application resource dictionary was asked for \
             {KEY} = {CAPTION_ELLIPSIS_ICON_BOX} and answers {readback}. That \
             key is the CommandBar template's Height for the FontIcon carrying \
             the overflow \"…\" glyph, and the library's own value for it is 3 \
             against a FontSize of 20, which cuts a row off every dot. This \
             says nothing about whether the CONTROL consumed the value — that \
             is a layout fact and `assert_caption_command_geometry` measures \
             it on every rebuild — only that the dictionary this process hands \
             to XAML holds the number kaya wrote."
        );
        Ok(())
    })
}

/// The least room the caption's title may leave between itself and either
/// header, in DIP: the gap this band already draws between two of its own
/// elements (`MenuBarItemMargin` 4,4,4,4; `TitleBarTitleMargin` 0,0,8,0). A
/// floor is needed at all only because the title is centred on the WINDOW
/// rather than in the content slot, so on a narrow window it can cross a
/// header.
const CAPTION_TITLE_GAP: f64 = 8.0;

/// How far the arranged title may sit from the centre this backend asked
/// for before `center_caption_title`'s post-condition calls it a defect.
/// NOT THE ACCEPTANCE FIGURE: acceptance is 1 PHYSICAL PIXEL, read off UIA
/// by `title-centre-probe.sh` against a live guest on the VM. This is the
/// in-process wall against a MODEL that stopped being true (tens of pixels
/// wrong), where a tight number would abort an app over layout rounding.
const CAPTION_TITLE_TOLERANCE: f64 = 1.5;

/// The `TitleBar` template's name for the element that occupies column 8 —
/// the caption's content slot, and the one thing that says where the space
/// between the two headers begins and ends
/// (`docs/chrome/TitleBar-v220.xaml:262-266`).
const CAPTION_CONTENT_SLOT_PART: &str = "PART_ContentPresenterGrid";

/// What the last centring pass asked for, and the geometry it asked it
/// from. One entry per promoted window; dropped with the window. EVERY
/// FIELD BUT `centre` IS AN INPUT, which is what makes the post-condition
/// safe: if any input moved, the comparison is skipped.
#[derive(Clone, Copy, PartialEq)]
struct CaptionTitleAim {
    band: f64,
    slot0: f64,
    slot1: f64,
    left_edge: f64,
    right_edge: f64,
    width: f64,
    centre: f64,
}

thread_local! {
    /// The centring's post-condition state, keyed by window.
    ///
    /// A THREAD-LOCAL RATHER THAN `CoreState`: this map is written from a
    /// XAML LAYOUT CALLBACK, and `CORE.with_borrow_mut` panics on a live
    /// borrow — `refresh_toolbar` holds exactly that borrow while it calls
    /// `RecomputeDragRegions`, which forces a synchronous layout.
    static CAPTION_TITLE_AIM: RefCell<HashMap<u64, CaptionTitleAim>> =
        RefCell::new(HashMap::new());
}

/// The caption's title `TextBlock`, minted with the two text properties the
/// clamp depends on. MARKUP AND NOT `TextBlock::new()`: `TextTrimming` and
/// `TextWrapping` are vtable PADS in this backend's bindings, and markup's
/// LOCAL VALUES beat `BaseTextBlockStyle`'s Wrap/None. `Stretch` is written
/// because `center_caption_title` needs UIA's rect to be the ink.
/// TODO: name those two properties in tools/winui-bindgen's filter.
fn caption_title_text() -> windows_core::Result<TextBlock> {
    const MARKUP: &str = concat!(
        "<TextBlock xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" ",
        "TextWrapping=\"NoWrap\" TextTrimming=\"CharacterEllipsis\" />"
    );
    let title: TextBlock = XamlReader::Load(&HSTRING::from(MARKUP))?.cast()?;
    // `CaptionTextBlockStyle` is the key `PART_TitleText` itself uses
    // (`TitleBar-v220.xaml:238`), so the title is the platform's caption
    // type at the platform's caption size — no font, no size, no colour
    // chosen here. A style's setters lose to the two local values above.
    title.SetStyle(&theme_resource::<Style>("CaptionTextBlockStyle")?)?;
    title.SetHorizontalAlignment(HorizontalAlignment::Stretch)?;
    Ok(title)
}

/// The x of an element's own origin, in another element's coordinates.
fn element_origin_x(element: &FrameworkElement, within: &UIElement) -> windows_core::Result<f64> {
    let origin = element
        .TransformToVisual(within)?
        .TransformPoint(Point { X: 0.0, Y: 0.0 })?;
    Ok(f64::from(origin.X))
}

/// The y of an element's own origin, in another element's coordinates.
fn element_origin_y(element: &FrameworkElement, within: &UIElement) -> windows_core::Result<f64> {
    let origin = element
        .TransformToVisual(within)?
        .TransformPoint(Point { X: 0.0, Y: 0.0 })?;
    Ok(f64::from(origin.Y))
}

/// THE MARK IS AT THE CAPTION'S FAR LEFT, ARRANGED, AND BEFORE THE MENU,
/// asserted against the arrangement XAML produced. THE HARNESS READ CANNOT
/// SEE THIS: `expect_app_icon` reads `WM_GETICON` on the HWND, which answers
/// identically whether the mark was composed, composed in the wrong column,
/// or never composed — measured with the compose call deleted, the scene
/// still passes. Deferred: `false` leaves it ARMED rather than vacuous.
fn assert_caption_mark_geometry(window: u64, titlebar: &TitleBar) -> windows_core::Result<bool> {
    if APP_ICON_BITMAP.with_borrow(|slot| slot.is_none()) {
        return Ok(true);
    }
    let band_height = titlebar.ActualHeight()?;
    if band_height <= 0.0 {
        return Ok(false);
    }
    let holder = caption_left_header(window, titlebar)?;
    let children = holder.Children()?;
    let mut mark: Option<Image> = None;
    let mut menu: Option<MenuBar> = None;
    let count = children.Size()?;
    for i in 0..count {
        let child = children.GetAt(i)?;
        if let Ok(image) = child.cast::<Image>() {
            mark = Some(image);
        } else if let Ok(bar) = child.cast::<MenuBar>() {
            menu = Some(bar);
        }
    }
    let Some(mark) = mark else {
        panic!(
            "kaya: winui: window {window} declared an app identity with a picture, and \
             its promoted caption's far-left container holds {count} element(s), none of \
             which is the Image that carries the mark (a MenuBar was {} among them). The \
             mark belongs in that container's first column, BEFORE the menu — the ruling \
             of 2026-08-18 — and refresh_caption_mark is what puts it there, from the \
             declaration, from a window's creation and from the caption's mint. No scene \
             can see this: expect_app_icon reads WM_GETICON, which is the WINDOW's icon \
             and answers the same with no caption mark at all.",
            if menu.is_some() { "found" } else { "not found" }
        )
    };
    let mark_fe: FrameworkElement = mark.cast()?;
    let width = mark.ActualWidth()?;
    let height = mark.ActualHeight()?;
    if width <= 0.0 || height <= 0.0 {
        return Ok(false);
    }
    let within: UIElement = titlebar.cast()?;
    let x = element_origin_x(&mark_fe, &within)?;
    let y = element_origin_y(&mark_fe, &within)?;
    assert!(
        (width - CAPTION_MARK_BOX).abs() < 0.5 && (height - CAPTION_MARK_BOX).abs() < 0.5,
        "kaya: winui: window {window}'s caption mark is arranged {width}x{height} DIP \
         where the band's own icon box is {CAPTION_MARK_BOX} — TitleBarIconMaxWidth and \
         TitleBarIconMaxHeight, the numbers the control's own PART_Icon wears \
         (v220-TitleBar_themeresources.xaml:88-89). kaya writes that box in \
         refresh_caption_mark and picks no size of its own; a different arranged size \
         means something else is sizing it."
    );
    // THE TWO INSETS ARE EQUAL, the corner-mirror criterion of 2026-08-18
    // measured rather than trusted, and the wall that makes
    // `CAPTION_MARK_LEAD`'s derivation from the band height true rather
    // than merely intended: a band that stopped being CAPTION_BAND_HEIGHT
    // tall parts them.
    assert!(
        (x - y).abs() <= 0.5,
        "kaya: winui: window {window}'s caption mark is arranged {x} DIP from the band's \
         left edge and {y} DIP from its top, and those two have to be the same number: \
         the mark mirrors the system's Close cell in the opposite corner, which is what \
         VS Code's icon does and what the maintainer's criterion of 2026-08-18 asks for. \
         The top inset is not chosen — it is what centring a {CAPTION_MARK_BOX} DIP box \
         in a {band_height} DIP band produces — so the left one is written to match it \
         (CAPTION_MARK_LEAD, derived from CAPTION_BAND_HEIGHT). They part when the band \
         is not the height that constant assumes, or when something else has put a \
         margin on the mark."
    );
    let centre = y + height / 2.0;
    let band_centre = band_height / 2.0;
    assert!(
        (centre - band_centre).abs() <= 1.0,
        "kaya: winui: window {window}'s caption mark sits on centre line {centre} in a \
         band {band_height} DIP tall, whose centre is {band_centre}. The mark is \
         VerticalAlignment=Center inside a container that is itself centred by the \
         control's own TitleBarLeftHeaderVerticalAlignment, so those two agree unless \
         something stretched one of them. The complaint this band was rebuilt for was \
         furniture that did not share the system cluster's centre line."
    );
    if let Some(menu) = menu {
        let menu_fe: FrameworkElement = menu.cast()?;
        let menu_x = element_origin_x(&menu_fe, &within)?;
        let menu_width = menu.ActualWidth()?;
        if menu_width > 0.0 {
            assert!(
                x + width <= menu_x + 0.5,
                "kaya: winui: window {window}'s caption mark is arranged at x={x} and is \
                 {width} DIP wide, so it ends at {}, while the window's menu begins at \
                 x={menu_x}. The mark goes BEFORE the menu at the caption's far left — \
                 the ruling of 2026-08-18, and the convention the system caption draws \
                 unprompted on every window that has no custom one. This is the exact \
                 arrangement TitleBar.IconSource produces and cannot be talked out of \
                 (the control lays its own icon out in template column 5 and LeftHeader \
                 in column 3), which is why kaya composes the mark into the container \
                 instead.",
                x + width
            );
        }
    }
    Ok(true)
}

/// THE TITLE CENTRES ON THE WINDOW, not on the space left over between the
/// headers (docs/chrome-plan.md, the WinUI row, "the title centres on the
/// WINDOW"). THE MARGIN IS A BIAS, `(d, 0, -d, 0)`, whose halves cancel in
/// the desired size: margins that carve the wanted rect out of the slot
/// RATCHET THE WINDOW, measured as a band frozen at its widest. `d` is
/// CORRECTED, not predicted; the post-condition is the wall (`CaptionTitleAim`).
fn center_caption_title(window: u64, titlebar: &TitleBar) -> windows_core::Result<()> {
    let band = titlebar.ActualWidth()?;
    if band <= 0.0 {
        // Before the first arrange, and while the caption is collapsed,
        // there is no geometry to read.
        return Ok(());
    }
    let Ok(title) = titlebar.Content().and_then(|content| content.cast::<TextBlock>()) else {
        return Ok(());
    };
    let title_fe: FrameworkElement = title.cast()?;
    let within: UIElement = titlebar.cast()?;

    // THE SLOT, BY THE NAME THE TEMPLATE GIVES IT: `PART_ContentPresenter`
    // centres the title inside itself, so the slot is the element carrying
    // `Grid.Column="8"`, which the template calls `PART_ContentPresenterGrid`
    // (`TitleBar-v220.xaml:262-266`). NOT BY WALKING UP FROM THE TITLE
    // (docs/traps.md: a TemplateBinding gives the element no logical parent).
    let slot = titlebar
        .GetTemplateChild(&HSTRING::from(CAPTION_CONTENT_SLOT_PART))
        .ok()
        .and_then(|part| part.cast::<FrameworkElement>().ok());
    let Some(slot) = slot else {
        // A band that has been arranged has had its template applied, so
        // there is no benign reading of this.
        panic!(
            "kaya: winui: window {window}'s TitleBar is arranged {band} DIP wide, \
             so its template has been applied, and yet it publishes no part \
             named {CAPTION_CONTENT_SLOT_PART}. That part is the element \
             carrying Grid.Column=\"8\" in the control's template \
             (docs/chrome/TitleBar-v220.xaml:262-266) and it is the only \
             thing that says where the caption's content slot begins and ends; \
             without it the title cannot be kept inside that slot while it is \
             aimed at the window's centre. A renamed part means the pinned \
             WinUI moved under this backend."
        );
    };
    let slot0 = element_origin_x(&slot, &within)?;
    let slot_width = slot.ActualWidth()?;
    if slot_width <= 0.0 {
        return Ok(());
    }
    let slot1 = slot0 + slot_width;

    // THE HEADERS. Absent ones do not clamp: a caption with no menu has
    // nothing on the left to collide with.
    let left_edge = match titlebar
        .LeftHeader()
        .ok()
        .and_then(|header| header.cast::<FrameworkElement>().ok())
    {
        Some(header) => element_origin_x(&header, &within)? + header.ActualWidth()?,
        None => 0.0,
    };
    let right_edge = match titlebar
        .RightHeader()
        .ok()
        .and_then(|header| header.cast::<FrameworkElement>().ok())
    {
        Some(header) => element_origin_x(&header, &within)?,
        None => slot1,
    };

    // The bias is written as `(d, -d)`, so reading `Left` reads `d`.
    let bias = title.Margin()?.Left;
    let origin = element_origin_x(&title_fe, &within)?;
    let width = title.ActualWidth()?;

    // THE SPAN THE TITLE MAY OCCUPY. The slot's own edge is the stricter
    // bound on the left (the control's left-header padding column already
    // holds 14 DIP there), and an element biased out of its slot is at the
    // mercy of whatever the template clips.
    let span0 = slot0.max(left_edge + CAPTION_TITLE_GAP);
    let span1 = right_edge.min(slot1) - CAPTION_TITLE_GAP;
    let available = (span1 - span0).max(0.0);

    let scale = title.RasterizationScale()?.max(1.0);
    let ideal = band / 2.0 - width / 2.0;
    // DOES IT FIT AT ALL? A `TextBlock` ellipsizes down to one "…" and no
    // further, and `MaxWidth` cannot take it below that. Measured on the
    // menus scene at 540 DIP: a 9 DIP slot and a 19.5 DIP ellipsis.
    let fits = width < available;
    let x = if fits {
        ideal.max(span0).min(span1 - width)
    } else {
        // NOTHING TO CENTRE, SO CHOOSE WHICH SIDE OVERFLOWS. The right
        // edge is pinned its 8 DIP clear of the commands and the overflow
        // goes LEFT, into the control's own empty left-header padding
        // column, where overflowing right would put an ellipsis under a
        // button.
        span1 - width
    };
    // SNAPPED TO A WHOLE PHYSICAL PIXEL, which keeps the correction a
    // one-step move instead of a feedback loop (`UseLayoutRounding`).
    let x = (x * scale).round() / scale;
    let centre = x + width / 2.0;
    let delta = x - origin;

    let aim = CaptionTitleAim {
        band,
        slot0,
        slot1,
        left_edge,
        right_edge,
        width,
        centre,
    };
    let previous = CAPTION_TITLE_AIM.with_borrow(|aims| aims.get(&window).copied());
    // THE POST-CONDITION SAYS NOTHING ABOUT A TITLE THAT DOES NOT FIT:
    // below its own floor the title's arranged width is no longer the width
    // its box was given, so an assertion about it would be an assertion
    // about the font's ellipsis metrics. Measured before it was gated: the
    // menus scene, whose menu leaves a 9 DIP slot, aborted five legs on a
    // 4 DIP disagreement no aim could have removed.
    if fits && previous == Some(aim) {
        // Every input is what the previous pass measured, so the
        // arrangement in front of us is that pass's margin, arranged.
        let achieved = element_origin_x(&title_fe, &within)? + title.ActualWidth()? / 2.0;
        assert!(
            (achieved - centre).abs() <= CAPTION_TITLE_TOLERANCE,
            "kaya: winui: window {window}'s caption title was aimed at x={centre:.1} \
             and is arranged centred on x={achieved:.1}, off by {:.1} DIP, with \
             nothing this backend measures having moved since it was aimed. The \
             caption title centres on the WINDOW (maintainer's ruling 2026-08-17, \
             VS Code's rule), which no scene can check: no harness verb reads a \
             caption's geometry and the other four backends draw their own band, \
             so this is the only place a lost centring says anything at all. What \
             was measured, in TitleBar coordinates: band width {band:.1} (centre \
             {:.1}), content slot {slot0:.1}..{slot1:.1}, menu's right edge \
             {left_edge:.1}, commands' left edge {right_edge:.1}, the title's \
             arranged width {width:.1}, the bias written {:.1}. If the slot's \
             span and the commands' left \
             edge disagree, the element being measured as the slot is not the \
             template's column 8 and the whole aim is computed in the wrong \
             place; if they agree and the title still sits at \
             {:.1} - the slot's own centre - then nothing is biasing it.",
            achieved - centre,
            band / 2.0,
            bias + delta,
            (slot0 + slot1) / 2.0
        );
    } else {
        CAPTION_TITLE_AIM.with_borrow_mut(|aims| {
            aims.insert(window, aim);
        });
    }

    // THE WIDTH THE TITLE MAY USE, which is what ellipsizes it. `MaxWidth`
    // rather than a margin, because a margin is part of an element's
    // DESIRED size and this one must not be — see the doc comment's
    // ratchet paragraph.
    if (available - title.MaxWidth()?).abs() > 0.05 {
        title.SetMaxWidth(available)?;
    }
    // THE BIAS, written only when it moves by half a physical pixel or
    // more. A `Thickness` write invalidates measure, and a pass that
    // rewrote the same number would schedule a layout for nothing on every
    // layout in the app.
    if delta.abs() >= 0.5 / scale {
        title.SetMargin(Thickness {
            Left: bias + delta,
            Top: 0.0,
            Right: -(bias + delta),
            Bottom: 0.0,
        })?;
    }
    Ok(())
}

/// The shell Grid's rows, named because two functions have to agree about
/// them and a bare `1` in each is how they stop agreeing. The TITLEBAR is
/// the TOP row, not a strip under the caption: the promoted commands ride
/// IN the caption row (docs/chrome-plan.md C2).
const TITLEBAR_ROW: i32 = 0;
const MENUBAR_ROW: i32 = 1;
const TOOLBAR_CONTENT_ROW: i32 = 2;

/// The window's PROMOTED actions, in catalog preorder — `action` items with
/// `primary` set, the same filter every other backend's promotion applies.
/// NO CAPACITY *k* IS APPLIED HERE: a WinUI `CommandBar` has DYNAMIC
/// OVERFLOW ON BY DEFAULT (docs/chrome-plan.md C2's WinUI row), so how many
/// buttons show is the platform's answer per resize. The phones apply a k
/// because their bars have none.
fn promoted_items(core: &CoreState, window: u64) -> Vec<u64> {
    let roots = core.menu_windows.get(&window).cloned().unwrap_or_default();
    let mut order = Vec::new();
    menu_preorder(core, &roots, &mut order);
    order
        .into_iter()
        .filter(|id| {
            core.menu_models
                .get(id)
                .is_some_and(|m| m.kind == MenuItemKind::Action && m.primary)
        })
        .collect()
}

/// THE PROMOTION (docs/chrome-plan.md C2's WinUI row;
/// docs/chrome/toolbar-winui.md): the window's primary catalog actions as
/// `AppBarButton`s in its `CommandBar`, in catalog preorder, and the bar
/// rides IN THE CAPTION ROW — extended is DERIVED from toolbar presence, so
/// a window that promotes nothing keeps the system caption. Four facts:
///   * the control fills to 48px when a header slot fills
///     (`TitleBar.cpp:493`) and does NOT tell the WINDOW, so
///     `AppWindowTitleBar.PreferredHeightOption` is written in step, or the
///     two runs of buttons sit 9 DIP apart (microsoft-ui-xaml#9863);
///   * `AutoRefreshDragRegions` watches `Content()`'s `LayoutUpdated` ALONE
///     (`TitleBar.cpp:603-606`), so `RecomputeDragRegions()` is called by
///     hand at the end of every rebuild;
///   * SECONDARY COMMANDS STAY EMPTY — `rebuild_menus` renders the whole
///     catalog into a `MenuBar`, so the remainder's home is `menubar`;
///   * NO SECOND KEYBOARD ACCELERATOR: the chord is already on the item's
///     `MenuFlyoutItem`, and a second is a SECOND HANDLER for one key.
fn refresh_toolbar(core: &mut CoreState, window: u64) -> windows_core::Result<()> {
    let promoted = promoted_items(core, window);
    if promoted.is_empty() && !core.toolbars.contains_key(&window) {
        return Ok(());
    }
    let bar = match core.toolbars.get(&window) {
        Some(bar) => bar.clone(),
        None => {
            // AT MINT, NOT AT FIRST LAYOUT: a CommandBar whose template
            // cannot resolve its theme keys fail-fasts the process on a
            // dispatcher tick, milliseconds after the step that caused it
            // (docs/traps.md).
            require_control_resources("this window promotes an action into its toolbar");
            // EXTENDED IS DERIVED FROM TOOLBAR PRESENCE, and this is the
            // wall on the path nobody can avoid. MEASURED: with the early
            // return above deleted, every menu-bearing window took an
            // extended caption it never asked for and seven rust legs ALL
            // PASSED — no harness verb reads "is this caption extended".
            assert!(
                !promoted.is_empty(),
                "kaya: winui: window {window} reached the caption mint with \
                 an EMPTY promotion list. `extended` is derived from toolbar \
                 presence (docs/chrome-plan.md C2's WinUI row): a window that \
                 promotes nothing keeps the system caption, and minting a \
                 TitleBar here would give it chrome no app declared."
            );
            let Some(shell) = core.menu_shells.get(&window).cloned() else {
                return Ok(());
            };
            let target = winui_window(core, window)?;

            // THE TITLE IS NOT WRITTEN HERE, and the control's own
            // `Title` property is never written at all: a filled `Title`
            // makes the control a second caption writer
            // (docs/dirty-plan.md D2, and see `refresh_caption`). The mint
            // puts an EMPTY TextBlock in the centre slot.
            let titlebar = mint_caption_titlebar()?;
            let tb_el: FrameworkElement = titlebar.cast()?;
            Grid::SetRow(&tb_el, TITLEBAR_ROW)?;
            shell.Children()?.Append(&titlebar.cast::<UIElement>()?)?;

            let caption_text = caption_title_text()?;
            titlebar.SetContent(&caption_text.cast::<UIElement>()?)?;
            core.window_caption_texts.insert(window, caption_text);

            // The hook that keeps the title centred (`center_caption_title`).
            // A WEAK REFERENCE for two reasons that both bite: a strong one
            // is a cycle XAML's reference tracker cannot see, so every
            // closed window's caption would leak, and `EventHandler::new`
            // demands `Send`, which a projected XAML interface is not. IT
            // TOUCHES NO CORE STATE: `refresh_toolbar` holds that borrow.
            let weak_titlebar = titlebar.downgrade()?;
            let recentre = EventHandler::<windows_core::IInspectable>::new(move |_, _| {
                match weak_titlebar.upgrade() {
                    Some(titlebar) => {
                        center_caption_title(window, &titlebar)?;
                        if CAPTION_GEOMETRY_ARMED.get()
                            && assert_caption_command_geometry(&titlebar)?
                            && assert_caption_mark_geometry(window, &titlebar)?
                        {
                            CAPTION_GEOMETRY_ARMED.set(false);
                        }
                        Ok(())
                    }
                    None => Ok(()),
                }
            });
            titlebar.LayoutUpdated(&recentre)?;

            let bar = CommandBar::new()?;
            titlebar.SetRightHeader(&bar.cast::<UIElement>()?)?;
            titlebar.SetAutoRefreshDragRegions(true)?;

            // ORDER IS LOAD-BEARING AND DOCUMENTED: "To specify a custom
            // title bar, you must first set ExtendsContentIntoTitleBar to
            // true… If ExtendsContentIntoTitleBar is false, the call to
            // SetTitleBar does not have any effect." (Window.SetTitleBar
            // remarks, windows-app-sdk-2.0). Swapped, the window silently
            // keeps its system caption with a second one drawn under it.
            target.SetExtendsContentIntoTitleBar(true)?;
            target.SetTitleBar(&tb_el)?;

            core.window_titlebars.insert(window, titlebar);
            // THE CAPTION SINK OPENS HERE and nowhere else: the promotion
            // that replaces the system caption is also what takes the
            // system-drawn icon away (docs/app-identity-plan.md I3). A
            // window that promotes nothing never reaches this line.
            apply_identity_to_window(core, window)?;
            core.toolbars.insert(window, bar.clone());
            bar
        }
    };
    let primary = bar.PrimaryCommands()?;
    primary.Clear()?;
    core.toolbar_buttons.retain(|(w, _), _| *w != window);
    for id in promoted {
        let (label, symbol) = {
            let m = &core.menu_models[&id];
            (m.label.clone(), m.symbol)
        };
        let enabled = menu_effective_enabled(core, id);
        let button = AppBarButton::new()?;
        // THE CAPTION CELL, written because the button's own default is a
        // metric for a different place — see CAPTION_COMMAND_CELL.
        button.SetWidth(CAPTION_COMMAND_CELL)?;
        // The height the button's OWN template is laid out for, read out
        // of the theme dictionary — see CAPTION_COMMAND_BUTTON_BOX_KEY for
        // why a 48 DIP row makes a 64 DIP button draw its hover visual
        // across its own icon.
        button.SetHeight(caption_command_button_box()?)?;
        // THE LABEL IS THE BUTTON'S NAME, not decoration: a closed
        // CommandBar draws icons only, so `Label` is what the overflow row
        // shows, what the button publishes to UIA, and the address
        // `expect_toolbar_item "Save"` resolves through.
        button.SetLabel(&HSTRING::from(&*label))?;
        apply_symbol(&button, symbol)?;
        button.SetIsEnabled(enabled)?;
        let attachment = MenuAttachment::Window(window);
        let handler = RoutedEventHandler::new(move |_, _| {
            menu_user_activate(id, attachment);
            Ok(())
        });
        button.Click(&handler)?;
        primary.Append(&button.cast::<ICommandBarElement>()?)?;
        core.toolbar_buttons.insert((window, id), button);
    }
    // An emptied promotion list leaves the bar in the tree with nothing in
    // it, and a CommandBar with no commands still measures 48px — so it is
    // collapsed, and so is the caption row, and the window goes back to the
    // system caption. The extended state follows the one number in BOTH
    // directions.
    let holds = primary.Size()? + bar.SecondaryCommands()?.Size()?;
    let extended = holds > 0;
    let visibility = if extended {
        Visibility::Visible
    } else {
        Visibility::Collapsed
    };
    bar.SetVisibility(visibility)?;
    if let Some(titlebar) = core.window_titlebars.get(&window).cloned() {
        titlebar.SetVisibility(visibility)?;
        let target = winui_window(core, window)?;
        // READ BEFORE WRITE: this runs on every catalog rebuild, and
        // re-asserting the flag re-enters the window's frame/inset
        // recomputation for no reason.
        if target.ExtendsContentIntoTitleBar()? != extended {
            target.SetExtendsContentIntoTitleBar(extended)?;
        }
        // THE SYSTEM'S HALF OF THE BAND, derived from the same number: the
        // caption BUTTONS are the window's, and this is the only thing that
        // moves them. Read before write, as above.
        let caption = target.AppWindow()?.TitleBar()?;
        let wanted = if extended {
            TitleBarHeightOption::Tall
        } else {
            TitleBarHeightOption::Standard
        };
        if caption.PreferredHeightOption()? != wanted {
            caption.SetPreferredHeightOption(wanted)?;
        }
        // Before RecomputeDragRegions, deliberately: the move changes
        // LeftHeader's extent, and the rects published below have to be the
        // ones the bar ends up occupying.
        rehost_menubar(core, window, extended)?;
        // ARM THE GEOMETRY POST-CONDITION: this rebuild may be the one
        // that puts the bar in the tree, so there is nothing arranged yet
        // to measure.
        CAPTION_GEOMETRY_ARMED.set(true);
        // The bar's width just changed and it lives in RightHeader, which
        // the control's automatic refresh does not watch. Without this the
        // passthrough rects describe the PREVIOUS set of buttons. The menu
        // has the same problem for the same reason.
        titlebar.RecomputeDragRegions()?;
        refresh_caption(core, window)?;
    }
    Ok(())
}

/// THE MENU'S PARENT IS DERIVED, like the caption it moves into: the same
/// `MenuBar` object leaves its shell row for the caption's `LeftHeader` and
/// goes back when the promotion empties, so `core.menubars` still holds the
/// bar every harness read goes through. XAML REFUSES RE-PARENTING AND DOES
/// NOT WARN (an append with a parent still set ABORTS THE PROCESS), so each
/// direction detaches first, and the move precedes `RecomputeDragRegions`.
fn rehost_menubar(core: &CoreState, window: u64, in_caption: bool) -> windows_core::Result<()> {
    let Some(bar) = core.menubars.get(&window) else {
        return Ok(());
    };
    let Some(shell) = core.menu_shells.get(&window) else {
        return Ok(());
    };
    let bar_el: UIElement = bar.cast()?;
    let bar_fe: FrameworkElement = bar.cast()?;
    let children = shell.Children()?;
    let mut at = 0u32;
    let in_row = children.IndexOf(&bar_el, &mut at)?;
    let titlebar = core.window_titlebars.get(&window);
    // A window with no caption control has nowhere else to put it — the
    // shape EVERY non-promoting window has.
    let in_caption = in_caption && titlebar.is_some();
    match (in_caption, in_row, titlebar) {
        (true, true, Some(titlebar)) => {
            children.RemoveAt(at)?;
            // INTO THE CONTAINER'S SECOND COLUMN, not into `LeftHeader`
            // itself: the first column is the app's mark, which goes BEFORE
            // the menu (the ruling of 2026-08-18). `LeftHeader` is written
            // once, at the mint, and by nothing else.
            Grid::SetColumn(&bar_fe, CAPTION_MENU_COLUMN)?;
            caption_left_header(window, titlebar)?
                .Children()?
                .Append(&bar_el)?;
        }
        (false, false, titlebar) => {
            if let Some(titlebar) = titlebar {
                let kids = caption_left_header(window, titlebar)?.Children()?;
                let mut here = 0u32;
                if kids.IndexOf(&bar_el, &mut here)? {
                    kids.RemoveAt(here)?;
                }
            }
            Grid::SetRow(&bar_fe, MENUBAR_ROW)?;
            // The column it wore in the caption travels with the element,
            // and the shell's grid has only column 0.
            Grid::SetColumn(&bar_fe, 0)?;
            children.Append(&bar_el)?;
        }
        // Already where it belongs. Idempotent because this runs on EVERY
        // catalog rebuild.
        _ => {}
    }

    // THE POST-CONDITION, AND IT IS A WALL BECAUSE NOTHING ELSE IS ONE.
    // MEASURED: with `SetLeftHeader` deleted the bar is attached to nothing,
    // the window shows NO MENU AT ALL, and `menus_rust` PASSED — every menu
    // question this backend answers goes through the bar OBJECT or the item
    // objects, and none of them asks whether the bar is in a TREE.
    let in_caption_now = match titlebar {
        Some(titlebar) => {
            let kids = caption_left_header(window, titlebar)?.Children()?;
            let mut here = 0u32;
            kids.IndexOf(&bar_el, &mut here)?
        }
        None => false,
    };
    let in_row_now = children.IndexOf(&bar_el, &mut at)?;
    assert!(
        in_caption_now == in_caption && in_row_now == !in_caption,
        "kaya: winui: window {window}'s MenuBar ended a rebuild somewhere \
         other than where the one-band derivation puts it. Wanted {}; \
         found caption={in_caption_now} row={in_row_now}. A promoted \
         window's menu rides in the far-left container inside its \
         TitleBar's LeftHeader — beside the app's mark, which takes that \
         container's first column — and every other window's rides in the \
         shell's MENUBAR_ROW; a bar in NEITHER is invisible, and no scene \
         can say so — the menu reads walk core.menubars and \
         core.menu_natives, which answer the same whether or not the bar \
         is in a tree.",
        if in_caption {
            "the caption's far-left container"
        } else {
            "the shell's menu row"
        }
    );
    Ok(())
}

/// What the window's REAL toolbar holds: how many items are in it, and the
/// addressable buttons among them with the name each publishes to UIA.
/// WALKED FROM THE BAR'S OWN COLLECTIONS, never from `toolbar_buttons`,
/// which would answer "yes" whether or not the promotion reached the
/// chrome. WHAT IT CANNOT SEE: dynamic overflow flips `IsInOverflow`
/// without moving a command, so "in the chrome" is not "showing now".
#[cfg(feature = "harness")]
fn toolbar_read(
    core: &CoreState,
    window: u64,
) -> windows_core::Result<(usize, Vec<(String, AppBarButton)>)> {
    let Some(bar) = core.toolbars.get(&window) else {
        return Ok((0, Vec::new()));
    };
    let mut held = 0;
    let mut buttons = Vec::new();
    for commands in [bar.PrimaryCommands()?, bar.SecondaryCommands()?] {
        for index in 0..commands.Size()? {
            held += 1;
            let element = commands.GetAt(index)?;
            let Ok(button) = element.cast::<AppBarButton>() else {
                continue;
            };
            let Ok(fe) = button.cast::<FrameworkElement>() else {
                continue;
            };
            let name = uia_name(&fe, "the toolbar button");
            buttons.push((name, button));
        }
    }
    Ok((held, buttons))
}

/// Where this window's unpromoted catalog lives, from the closed set the
/// harness contract names — READ, not asserted: the window's real
/// `MenuBar` with real items in it, and `none` the moment that stops being
/// true rather than a home the window does not have.
#[cfg(feature = "harness")]
fn toolbar_remainder_home(core: &CoreState, window: u64) -> windows_core::Result<&'static str> {
    let Some(bar) = core.menubars.get(&window) else {
        return Ok("none");
    };
    Ok(if bar.Items()?.Size()? > 0 {
        "menubar"
    } else {
        "none"
    })
}

/// KAYA_WINUI_TOOLBAR_TRACE=1: dump every candidate surface of the real
/// bar at every toolbar step. It settled what an `AppBarButton` publishes
/// as its UIA name with `Label` set and `Content` null, and which
/// enablement surface a disable actually moves.
#[cfg(feature = "harness")]
fn toolbar_trace(core: &CoreState, window: u64) {
    if std::env::var_os("KAYA_WINUI_TOOLBAR_TRACE").is_none() {
        return;
    }
    let promoted: Vec<String> = promoted_items(core, window)
        .iter()
        .filter_map(|id| core.menu_models.get(id).map(|m| m.label.clone()))
        .collect();
    eprintln!("kaya-toolbar-trace: promoted={promoted:?} bar={}", core.toolbars.contains_key(&window));
    let Ok((held, buttons)) = toolbar_read(core, window) else {
        eprintln!("kaya-toolbar-trace: the bar could not be walked");
        return;
    };
    eprintln!("kaya-toolbar-trace: held={held}");
    for (name, button) in buttons {
        let label = button.Label().map(|l| l.to_string());
        let enabled = button.IsEnabled();
        let overflow = button.IsInOverflow();
        let icon = match button.Icon() {
            Ok(icon) => icon_uia_name(&icon),
            Err(e) if e.code().is_ok() => "<no icon>".to_owned(),
            Err(e) => format!("<unreadable: {e}>"),
        };
        eprintln!(
            "kaya-toolbar-trace:   uia={name:?} label={label:?} enabled={enabled:?} \
             overflow={overflow:?} icon={icon:?}"
        );
    }
}

/// Every content swap for a window goes through here: into the menu
/// shell's slot when the window carries a bar, straight onto the Window
/// otherwise. `window_client_width` reads the WINDOW and not whatever
/// element occupies it — a UIElement's XamlRoot is null until it is
/// parented, so `Content().XamlRoot().Size()` is circular for the
/// list-detail arm, whose trace alternated Some(900.0)/None mid-swap.
#[cfg(feature = "harness")]
/// Is the Shell's file dialog on screen? Plain Win32, no COM.
///
/// THE GONE-CHECK MUST NOT WALK THE DIALOG (docs/traps.md: UI Automation
/// cannot read the Shell's file dialog from a guest — the structured
/// exception it raises is fatal under a JVM). EnumWindows never speaks to
/// a provider.
#[cfg(feature = "harness")]
fn file_dialog_is_up() -> bool {
    unsafe extern "system" fn visit(hwnd: isize, found: isize) -> i32 {
        let mut class = [0u16; 64];
        let n = unsafe { GetClassNameW(hwnd, class.as_mut_ptr(), class.len() as i32) };
        if n > 0 && unsafe { IsWindowVisible(hwnd) } != 0 {
            let name = String::from_utf16_lossy(&class[..n as usize]);
            if name == "#32770" {
                unsafe { *(found as *mut bool) = true };
                return 0; // stop: one is enough
            }
        }
        1
    }

    let mut found = false;
    unsafe { EnumWindows(Some(visit), &mut found as *mut bool as isize) };
    found
}

/// The live dialog's window, or nothing. Plain Win32: no COM, no
/// automation, no messages sent.
#[cfg(feature = "harness")]
fn live_dialog() -> Option<isize> {
    unsafe extern "system" fn visit(hwnd: isize, found: isize) -> i32 {
        let mut class = [0u16; 64];
        let n = unsafe { GetClassNameW(hwnd, class.as_mut_ptr(), class.len() as i32) };
        if n > 0 && unsafe { IsWindowVisible(hwnd) } != 0 {
            let name = String::from_utf16_lossy(&class[..n as usize]);
            if name == "#32770" {
                unsafe { *(found as *mut isize) = hwnd };
                return 0;
            }
        }
        1
    }
    let mut found: isize = 0;
    unsafe { EnumWindows(Some(visit), &mut found as *mut isize as isize) };
    (found != 0).then_some(found)
}

/// A window's caption. Only ever read for the log line below.
#[cfg(feature = "harness")]
fn window_text(hwnd: isize) -> String {
    let mut buf = [0u16; 128];
    let n = unsafe { GetWindowTextW(hwnd, buf.as_mut_ptr(), buf.len() as i32) };
    String::from_utf16_lossy(&buf[..n.max(0) as usize])
}

/// Answer the save dialog's overwrite confirmation, if one is up.
/// `FOS_OVERWRITEPROMPT` is in the dialog's DEFAULT options (measured
/// `0x880a`) and unanswered `Show()` NEVER RETURNS. FOUND BY IDENTITY: the
/// prompt is a SECOND top-level `#32770` whose Buttons carry id 0
/// (docs/probes/save-probe-windows.md §B.3), so it is "the other window";
/// enumeration order is `"&Yes"` then `"&No"`, and pressing No fails safe.
#[cfg(feature = "harness")]
fn answer_overwrite_prompt(dialog: isize) {
    struct Hunt {
        dialog: isize,
        found: isize,
    }
    unsafe extern "system" fn visit_top(hwnd: isize, param: isize) -> i32 {
        let hunt = unsafe { &mut *(param as *mut Hunt) };
        let mut class = [0u16; 64];
        let n = unsafe { GetClassNameW(hwnd, class.as_mut_ptr(), class.len() as i32) };
        if hwnd != hunt.dialog
            && n > 0
            && unsafe { IsWindowVisible(hwnd) } != 0
            && String::from_utf16_lossy(&class[..n as usize]) == "#32770"
        {
            hunt.found = hwnd;
            return 0;
        }
        1
    }
    let mut hunt = Hunt { dialog, found: 0 };
    unsafe { EnumWindows(Some(visit_top), &mut hunt as *mut Hunt as isize) };
    if hunt.found == 0 {
        return;
    }
    // The first visible Button under it, by class alone.
    struct Press {
        found: isize,
    }
    unsafe extern "system" fn visit_button(hwnd: isize, param: isize) -> i32 {
        let press = unsafe { &mut *(param as *mut Press) };
        let mut class = [0u16; 64];
        let n = unsafe { GetClassNameW(hwnd, class.as_mut_ptr(), class.len() as i32) };
        if n > 0
            && unsafe { IsWindowVisible(hwnd) } != 0
            && String::from_utf16_lossy(&class[..n as usize]) == "Button"
        {
            press.found = hwnd;
            return 0;
        }
        unsafe { EnumChildWindows(hwnd, Some(visit_button), param) };
        1
    }
    let mut press = Press { found: 0 };
    unsafe { EnumChildWindows(hunt.found, Some(visit_button), &mut press as *mut Press as isize) };
    if press.found == 0 {
        return;
    }
    // ONCE, and it is the record that this arm ran at all: the shared
    // scene cannot reach here, so the log line is what distinguishes "the
    // prompt never came up" from "the answer did nothing".
    eprintln!(
        "kaya: answered the save dialog's overwrite prompt {:?} with {:?}",
        window_text(hunt.found),
        window_text(press.found)
    );
    unsafe { PostMessageW(press.found, BM_CLICK, 0, 0) };
}

/// ASK THE LIVE DIALOG WHAT IT IS SHOWING, then wait briefly for its own
/// thread to answer. The bounded wait is not the assertion's:
/// `expect_file_dialog` and `expect_save_dialog` are themselves retries.
#[cfg(feature = "harness")]
fn sample_dialog() -> Option<sampler::Sampled> {
    let window = sampler::WINDOW.load(std::sync::atomic::Ordering::SeqCst);
    if window == 0 {
        return None;
    }
    unsafe { PostMessageW(window, sampler::SAMPLE, 0, 0) };
    for _ in 0..20 {
        if let Ok(slot) = sampler::VIEW.lock() {
            if let Some(state) = slot.as_ref() {
                return Some(state.clone());
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(25));
    }
    None
}

/// What the live dialog is SHOWING, sampled through the shell's own
/// interfaces rather than through UI Automation: MERELY ATTACHING A UIA
/// CLIENT makes this dialog fatal to a JVM (docs/traps.md: UI Automation
/// cannot read the Shell's file dialog from a guest). The dialog is ours, so
/// IServiceProvider -> SID_STopLevelBrowser -> IShellBrowser -> IShellView
/// -> IFolderView answers, sampled ON THE DIALOG'S OWN STA THREAD.
#[cfg(feature = "harness")]
mod sampler {
    use std::sync::Mutex;

    /// The message-only window on the dialog's thread, 0 when no dialog
    /// is up.
    pub(crate) static WINDOW: std::sync::atomic::AtomicIsize =
        std::sync::atomic::AtomicIsize::new(0);

    /// WHICH DIALOG THIS SAMPLE CAME OFF, carried in the type: one process
    /// may have one live file dialog and this backend has one sampler
    /// window, so the variant makes each reader's `None` mean "no dialog OF
    /// MINE is live".
    #[derive(Clone)]
    pub(crate) enum Sampled {
        /// A picker: the directory it is browsing, and every row its view
        /// is displaying.
        Open(String, Vec<String>),
        /// A save dialog: the directory it is browsing, and the text
        /// currently in its file-name box. NEVER ROWS — the platform whose
        /// save panel publishes none at all is why the observation is shaped
        /// this way in every backend (harness.rs, Stage::save_dialog_state).
        Save(String, String),
    }

    /// The last sample. Cleared when a dialog opens, so a stale answer
    /// can never satisfy an assertion about a new one.
    pub(crate) static VIEW: Mutex<Option<Sampled>> = Mutex::new(None);
    /// WM_APP: "sample now". pub(crate) and not pub: cbindgen scrapes
    /// public constants into the C header regardless of the privacy of the
    /// module holding them (docs/traps.md).
    pub(crate) const SAMPLE: u32 = 0x8000;
}

/// A shell-allocated wide string, read and RELEASED: every `PWSTR` the
/// Shell answers with is CoTaskMemAlloc'd and belongs to the caller, and
/// these reads sit inside a poll that samples tens of times.
#[cfg(feature = "harness")]
fn take_pwstr(text: windows_core::PWSTR) -> windows_core::Result<String> {
    let owned = unsafe { text.to_string() };
    unsafe {
        windows::Win32::System::Com::CoTaskMemFree(Some(text.0 as *const core::ffi::c_void))
    };
    Ok(owned?)
}

/// The directory the live dialog is browsing — asked of `IFileDialog`,
/// which BOTH dialogs are, so the picker and the save dialog answer the
/// "where" half of their observation through one call.
#[cfg(feature = "harness")]
fn sample_folder(dialog: &windows::Win32::UI::Shell::IFileDialog) -> windows_core::Result<String> {
    use windows::Win32::UI::Shell::SIGDN_FILESYSPATH;
    take_pwstr(unsafe { dialog.GetFolder()?.GetDisplayName(SIGDN_FILESYSPATH)? })
}

#[cfg(feature = "harness")]
fn sample_folder_view(
    dialog: &windows::Win32::UI::Shell::IFileOpenDialog,
) -> windows_core::Result<sampler::Sampled> {
    use windows::Win32::System::Com::IServiceProvider;
    use windows::Win32::UI::Shell::{
        IFolderView, IShellBrowser, IShellItemArray, SVGIO_ALLVIEW, SIGDN_PARENTRELATIVEFORUI,
    };
    // {4C96BE40-915C-11CF-99D3-00AA004AE837}, the top-level browser the
    // dialog hosts its view in. Not exported by the metadata, so it is
    // spelled out.
    const SID_S_TOP_LEVEL_BROWSER: windows_core::GUID =
        windows_core::GUID::from_u128(0x4C96BE40_915C_11CF_99D3_00AA004AE837);
    // SVGIO_ALLVIEW is everything the view is displaying, which is the
    // question the scene asks — not the selection, not the background.

    let directory = sample_folder(dialog)?;

    let provider: IServiceProvider = dialog.cast()?;
    let browser: IShellBrowser = unsafe { provider.QueryService(&SID_S_TOP_LEVEL_BROWSER)? };
    let view = unsafe { browser.QueryActiveShellView()? };
    let folder: IFolderView = view.cast()?;
    let items: IShellItemArray = unsafe { folder.Items(SVGIO_ALLVIEW)? };

    let mut rows = Vec::new();
    for i in 0..unsafe { items.GetCount()? } {
        let item = unsafe { items.GetItemAt(i)? };
        // PARENTRELATIVEFORUI is WHAT THE USER SEES, which every other
        // backend reports and the shared scene compares byte for byte. It
        // honours Explorer's HideFileExt, so the deploy still has to set
        // that to 0.
        rows.push(take_pwstr(unsafe {
            item.GetDisplayName(SIGDN_PARENTRELATIVEFORUI)?
        })?);
    }
    Ok(sampler::Sampled::Open(directory, rows))
}

/// The save dialog's observation: where it is browsing, and THE NAME IT
/// WOULD SAVE UNDER. `IFileDialog::GetFileName` and not the file-name
/// Edit's text: reading the control means `WM_GETTEXT`, whose lParam is a
/// POINTER, so only `SendMessage` marshals it — and a send puts the
/// receiving thread into the input-synchronous call that makes this dialog
/// fatal to a JVM. A LIVE read, not the echo of `SetFileName`.
#[cfg(feature = "harness")]
fn sample_save_state(
    dialog: &windows::Win32::UI::Shell::IFileSaveDialog,
) -> windows_core::Result<sampler::Sampled> {
    let directory = sample_folder(dialog)?;
    let name = take_pwstr(unsafe { dialog.GetFileName()? })?;
    Ok(sampler::Sampled::Save(directory, name))
}

/// Sample whichever dialog is live, on ITS thread. A failed read leaves the
/// previous answer alone rather than publishing a half one; `open_sampler`
/// is what clears the slot.
#[cfg(feature = "harness")]
fn sample_live(live: &LiveDialog) {
    let sampled = match live {
        LiveDialog::Open(dialog) => sample_folder_view(dialog),
        LiveDialog::Save(dialog) => sample_save_state(dialog),
    };
    if let Ok(state) = sampled {
        if let Ok(mut slot) = sampler::VIEW.lock() {
            *slot = Some(state);
        }
    }
}

/// A control of the dialog by its classic id and class, confirmed against
/// the real dialog by tools/win/dialogprobe rather than taken from
/// documentation: 1 is Open, 2 is Cancel, and 1148 is the file-name box, an
/// Edit inside a ComboBoxEx32 that shares its id.
#[cfg(feature = "harness")]
fn dialog_control(dialog: isize, id: i32, class: &str) -> Option<isize> {
    struct Hunt<'a> {
        id: i32,
        class: &'a str,
        found: isize,
    }
    unsafe extern "system" fn visit(hwnd: isize, param: isize) -> i32 {
        let hunt = unsafe { &mut *(param as *mut Hunt) };
        let mut buf = [0u16; 64];
        let n = unsafe { GetClassNameW(hwnd, buf.as_mut_ptr(), buf.len() as i32) };
        let class = String::from_utf16_lossy(&buf[..n.max(0) as usize]);
        if unsafe { GetDlgCtrlID(hwnd) } == hunt.id && class == hunt.class {
            hunt.found = hwnd;
            return 0;
        }
        unsafe { EnumChildWindows(hwnd, Some(visit), param) };
        1
    }
    let mut hunt = Hunt { id, class, found: 0 };
    unsafe { EnumChildWindows(dialog, Some(visit), &mut hunt as *mut Hunt as isize) };
    (hunt.found != 0).then_some(hunt.found)
}

#[cfg(feature = "harness")]
const ID_OK: i32 = 1;
#[cfg(feature = "harness")]
const ID_CANCEL: i32 = 2;
#[cfg(feature = "harness")]
const ID_FILENAME: i32 = 1148;
/// The SAVE dialog's file-name box, a DIFFERENT CONTROL rather than the
/// same id in a different place (docs/probes/save-probe-windows.md §B.3):
/// the save dialog has no id 1148 at all and `dialog_control(dialog, 1148,
/// "Edit")` is a SILENT no-op. Its box is id 1001, class `Edit`, and the
/// class half is load-bearing — id 1001 is ALSO the address bar.
#[cfg(feature = "harness")]
const ID_SAVE_FILENAME: i32 = 1001;
#[cfg(feature = "harness")]
const WM_CHAR: u32 = 0x0102;
#[cfg(feature = "harness")]
const EM_SETSEL: u32 = 0x00B1;
#[cfg(feature = "harness")]
const BM_CLICK: u32 = 0x00F5;

/// The WNDCLASSW the sampler window registers, hand-declared rather than by
/// enabling Win32_UI_WindowsAndMessaging for one struct.
#[cfg(feature = "harness")]
#[repr(C)]
struct WndClassW {
    style: u32,
    proc_: Option<unsafe extern "system" fn(isize, u32, usize, isize) -> isize>,
    cls_extra: i32,
    wnd_extra: i32,
    instance: isize,
    icon: isize,
    cursor: isize,
    background: isize,
    menu_name: *const u16,
    class_name: *const u16,
}

/// The message-only window the harness posts its sample request to.
///
/// It lives on the DIALOG'S thread, the only thread allowed to touch an STA
/// object, and it is a window rather than a channel because that thread is
/// inside a modal Show() loop — which pumps the queue and so dispatches to
/// this window without knowing anything about it.
#[cfg(feature = "harness")]
unsafe extern "system" fn sampler_proc(
    hwnd: isize,
    msg: u32,
    wparam: usize,
    lparam: isize,
) -> isize {
    if msg == sampler::SAMPLE {
        SAMPLED_DIALOG.with(|held| {
            if let Some(live) = held.borrow().as_ref() {
                sample_live(live);
            }
        });
        return 0;
    }
    unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
}

/// The dialog the sampler is holding, and WHICH KIND IT IS.
/// `IFileOpenDialog` and `IFileSaveDialog` are siblings under `IFileDialog`
/// rather than one deriving from the other, so there is no single type to
/// hold and ask about later.
#[cfg(feature = "harness")]
#[derive(Clone)]
enum LiveDialog {
    Open(windows::Win32::UI::Shell::IFileOpenDialog),
    Save(windows::Win32::UI::Shell::IFileSaveDialog),
}

#[cfg(feature = "harness")]
thread_local! {
    /// The live dialog, reachable from the window proc above. A
    /// thread-local and not a global: an STA interface pointer is only
    /// valid on the thread that created it, and this is that thread.
    static SAMPLED_DIALOG: std::cell::RefCell<Option<LiveDialog>> =
        const { std::cell::RefCell::new(None) };
}

#[cfg(feature = "harness")]
fn utf16(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// Stand the sampler up for the life of one dialog.
#[cfg(feature = "harness")]
fn open_sampler(dialog: LiveDialog) {
    let class = utf16("KayaFileDialogSampler");
    let instance = unsafe { GetModuleHandleW(core::ptr::null()) };
    let mut wc: WndClassW = unsafe { core::mem::zeroed() };
    wc.proc_ = Some(sampler_proc);
    wc.instance = instance;
    wc.class_name = class.as_ptr();
    // Registering the same class twice simply fails; the class outlives
    // any one dialog.
    unsafe { RegisterClassW(&wc) };
    // HWND_MESSAGE is -3: a queue endpoint and nothing else.
    let hwnd = unsafe {
        CreateWindowExW(
            0,
            class.as_ptr(),
            core::ptr::null(),
            0,
            0,
            0,
            0,
            0,
            -3,
            0,
            instance,
            core::ptr::null_mut(),
        )
    };
    SAMPLED_DIALOG.with(|held| *held.borrow_mut() = Some(dialog));
    // A NEW DIALOG STARTS WITH NO ANSWER, so a sample of the previous
    // one can never satisfy an assertion about this one.
    if let Ok(mut slot) = sampler::VIEW.lock() {
        *slot = None;
    }
    sampler::WINDOW.store(hwnd, std::sync::atomic::Ordering::SeqCst);
}

/// Take it down when the dialog goes. A published handle to a window
/// nobody pumps would leave the harness posting into nothing.
#[cfg(feature = "harness")]
fn close_sampler() {
    let hwnd = sampler::WINDOW.swap(0, std::sync::atomic::Ordering::SeqCst);
    if hwnd != 0 {
        unsafe { DestroyWindow(hwnd) };
    }
    SAMPLED_DIALOG.with(|held| *held.borrow_mut() = None);
}

/// Show the Shell's common item dialog and return (name, path) per file.
/// Runs on the dialog apartment's thread; see `dialog_apartment`.
///
/// The empty vector IS cancel: Show() answers ERROR_CANCELLED, which is the
/// platform's way of saying the selection was empty.
fn file_dialog_show(
    hwnd: isize,
    multiple: bool,
    filters: &[(String, String)],
    folder: Option<&str>,
) -> Vec<(String, String)> {
    use windows::Win32::System::Com::{CoCreateInstance, CLSCTX_INPROC_SERVER};
    use windows::Win32::UI::Shell::Common::COMDLG_FILTERSPEC;
    use windows::Win32::UI::Shell::{
        FileOpenDialog, IFileOpenDialog, IShellItem, SHCreateItemFromParsingName,
        SIGDN_FILESYSPATH, FOS_ALLOWMULTISELECT, FOS_FORCEFILESYSTEM,
    };

    let mut out = Vec::new();
    unsafe {
        // THE APARTMENT IS THE THREAD'S, NOT THIS CALL'S — the caller
        // entered it and never leaves it. See `dialog_apartment`.
        //
        // WHICH CALL FAILED, not merely that one did: a bare "The parameter
        // is incorrect" from a chain of six COM calls names nothing.
        let mut stage = "CoCreateInstance";
        let result = (|| -> windows_core::Result<()> {
            let dialog: IFileOpenDialog =
                CoCreateInstance(&FileOpenDialog, None, CLSCTX_INPROC_SERVER)?;

            stage = "GetOptions";
            let mut options = dialog.GetOptions()?;
            // FORCEFILESYSTEM: the guest opens the path with its own file
            // API, and a virtual shell item has nothing to open.
            options |= FOS_FORCEFILESYSTEM;
            if multiple {
                options |= FOS_ALLOWMULTISELECT;
            }
            stage = "SetOptions";
            dialog.SetOptions(options)?;

            // Advisory, never a guarantee (DESIGN.md). The HSTRINGs must
            // outlive SetFileTypes, which borrows their pointers.
            let specs: Vec<(HSTRING, HSTRING)> = filters
                .iter()
                .map(|(label, suffix)| {
                    (HSTRING::from(label.as_str()), HSTRING::from(format!("*.{suffix}")))
                })
                .collect();
            if !specs.is_empty() {
                let raw: Vec<COMDLG_FILTERSPEC> = specs
                    .iter()
                    .map(|(label, pattern)| COMDLG_FILTERSPEC {
                        pszName: windows_core::PCWSTR(label.as_ptr()),
                        pszSpec: windows_core::PCWSTR(pattern.as_ptr()),
                    })
                    .collect();
                stage = "SetFileTypes";
            dialog.SetFileTypes(&raw)?;
            }

            if let Some(dir) = folder {
                let wide = HSTRING::from(dir);
                stage = "SHCreateItemFromParsingName";
                let item: IShellItem =
                    SHCreateItemFromParsingName(windows_core::PCWSTR(wide.as_ptr()), None)?;
                stage = "SetFolder";
            dialog.SetFolder(&item)?;
            }

            // The sampler lives exactly as long as the modal loop: stood
            // up immediately before Show, taken down the instant it returns
            // (below, outside this closure, because cancel leaves via `?`).
            #[cfg(feature = "harness")]
            open_sampler(LiveDialog::Open(dialog.clone()));

            stage = "Show";
            // NO OWNER: Show() disables its owner and waits on the owner's
            // input queue, and this runs off the UI thread, so passing the
            // app window blocks inside Show() before the dialog is ever
            // created (docs/traps.md: Show() with an owner on another
            // thread never comes back). Modality is kept by
            // capi::file_dialog_shown, which refuses a second.
            let _ = hwnd;
            dialog.Show(None)?;

            stage = "GetResults";
            let items = dialog.GetResults()?;
            for i in 0..items.GetCount()? {
                let item = items.GetItemAt(i)?;
                let path = item.GetDisplayName(SIGDN_FILESYSPATH)?;
                let path = path.to_string()?;
                let name = std::path::Path::new(&path)
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default();
                out.push((name, path));
            }
            Ok(())
        })();
        // OUTSIDE the closure: Show() answers cancel with an Err that leaves
        // it early, so a teardown inside would run on the happy path only.
        #[cfg(feature = "harness")]
        close_sampler();
        if let Err(err) = result {
            const CANCELLED: windows_core::HRESULT = windows_core::HRESULT(0x8007_04C7u32 as i32);
            if err.code() != CANCELLED {
                eprintln!(
                    "kaya: file dialog failed at {stage} (hwnd={hwnd:#x}, \
                     folder={folder:?}, filters={filters:?}): {err}"
                );
            }
        }
    }
    out
}

/// Show the Shell's SAVE dialog and return the one (name, path) it was
/// pointed at, or nothing for cancel; runs on the dialog apartment's thread.
/// `IFileSaveDialog` AND NOT `FileSavePicker`, measured
/// (docs/probes/save-probe-windows.md §B.1). IT CREATES NOTHING — the core's
/// `SaveDestination::open` does (docs/save-plan.md D1). The overwrite prompt
/// stays on, and unanswered it WEDGES, because `Show()` never returns.
fn file_save_show(
    hwnd: isize,
    suggested_name: &str,
    filters: &[(String, String)],
    folder: Option<&str>,
) -> Option<(String, String)> {
    use windows::Win32::System::Com::{CoCreateInstance, CLSCTX_INPROC_SERVER};
    use windows::Win32::UI::Shell::Common::COMDLG_FILTERSPEC;
    use windows::Win32::UI::Shell::{
        FileSaveDialog, IFileSaveDialog, IShellItem, SHCreateItemFromParsingName,
        SIGDN_FILESYSPATH, FOS_FORCEFILESYSTEM,
    };

    let mut out = None;
    unsafe {
        let mut stage = "CoCreateInstance";
        let result = (|| -> windows_core::Result<()> {
            let dialog: IFileSaveDialog =
                CoCreateInstance(&FileSaveDialog, None, CLSCTX_INPROC_SERVER)?;

            stage = "GetOptions";
            let mut options = dialog.GetOptions()?;
            // FORCEFILESYSTEM for the picker's reason. The defaults this ORs
            // into (OVERWRITEPROMPT, NOREADONLYRETURN, PATHMUSTEXIST,
            // NOCHANGEDIR) are the platform's own and are kept.
            options |= FOS_FORCEFILESYSTEM;
            stage = "SetOptions";
            dialog.SetOptions(options)?;

            let specs: Vec<(HSTRING, HSTRING)> = filters
                .iter()
                .map(|(label, suffix)| {
                    (HSTRING::from(label.as_str()), HSTRING::from(format!("*.{suffix}")))
                })
                .collect();
            if !specs.is_empty() {
                let raw: Vec<COMDLG_FILTERSPEC> = specs
                    .iter()
                    .map(|(label, pattern)| COMDLG_FILTERSPEC {
                        pszName: windows_core::PCWSTR(label.as_ptr()),
                        pszSpec: windows_core::PCWSTR(pattern.as_ptr()),
                    })
                    .collect();
                stage = "SetFileTypes";
                dialog.SetFileTypes(&raw)?;
                // SetDefaultExtension is this platform's spelling of the
                // extension completion NSSavePanel does, so a filtered save
                // answers the same shape of name on both (measured: `bare`
                // under a `txt` filter answers `bare.txt`). ONLY under a
                // filter, and the shared scene sends none for that reason
                // (docs/save-plan.md, docs/probes/save-depth.md §8).
                stage = "SetDefaultExtension";
                dialog.SetDefaultExtension(&HSTRING::from(filters[0].1.as_str()))?;
            }

            // Advisory, like the filters: the guest reads back the name it GOT.
            stage = "SetFileName";
            dialog.SetFileName(&HSTRING::from(suggested_name))?;

            if let Some(dir) = folder {
                let wide = HSTRING::from(dir);
                stage = "SHCreateItemFromParsingName";
                let item: IShellItem =
                    SHCreateItemFromParsingName(windows_core::PCWSTR(wide.as_ptr()), None)?;
                stage = "SetFolder";
                dialog.SetFolder(&item)?;
            }

            #[cfg(feature = "harness")]
            open_sampler(LiveDialog::Save(dialog.clone()));

            stage = "Show";
            // NO OWNER, for the measured reason at `file_dialog_show`.
            let _ = hwnd;
            dialog.Show(None)?;

            stage = "GetResult";
            let item = dialog.GetResult()?;
            let path = item.GetDisplayName(SIGDN_FILESYSPATH)?;
            let path = path.to_string()?;
            let name = std::path::Path::new(&path)
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default();
            out = Some((name, path));
            Ok(())
        })();
        #[cfg(feature = "harness")]
        close_sampler();
        if let Err(err) = result {
            const CANCELLED: windows_core::HRESULT = windows_core::HRESULT(0x8007_04C7u32 as i32);
            if err.code() != CANCELLED {
                eprintln!(
                    "kaya: save dialog failed at {stage} (hwnd={hwnd:#x}, \
                     name={suggested_name:?}, folder={folder:?}, filters={filters:?}): {err}"
                );
            }
        }
    }
    out
}

/// Win32's EXCEPTION_POINTERS/EXCEPTION_RECORD, truncated to the one
/// field the probe reads. The handler never touches the rest.
#[repr(C)]
struct ExceptionPointers {
    record: *mut ExceptionRecord,
    context: *mut c_void,
}
#[repr(C)]
struct ExceptionRecord {
    code: u32,
    flags: u32,
}

unsafe extern "system" {
    fn AddVectoredExceptionHandler(
        first: u32,
        handler: unsafe extern "system" fn(*mut ExceptionPointers) -> i32,
    ) -> *mut c_void;
}

/// How many times the Shell has been caught calling into an apartment this
/// process had already closed. THE HARNESS FAILS THE SCENE ON A NON-ZERO
/// COUNT (see `Stage::finish`). A count and not a print because the failure
/// is SILENT IN FOUR RUNTIMES OUT OF FIVE: measured 2026-08-03, rust raised
/// 0x80010108 on 2 of 5 runs and PASSED all five, while java raised it on 3
/// of 5 and died on those three (docs/deferred.md, the filedialog_java entry).
static COM_DISCONNECTS: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
/// KAYA_WINUI_SEH_PROBE: also name every COM/RPC first-chance code and
/// the thread it landed on, for the next investigation.
static PROBE_VERBOSE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// A VECTORED handler is the only place in this process that can see these:
/// they run ahead of every frame-based `__except`, and combase swallows the
/// one that matters. It decides nothing — always EXCEPTION_CONTINUE_SEARCH.
unsafe extern "system" fn seh_probe(info: *mut ExceptionPointers) -> i32 {
    use std::sync::atomic::Ordering::Relaxed;
    const CONTINUE_SEARCH: i32 = 0;
    const RPC_E_DISCONNECTED: u32 = 0x8001_0108;
    let code = unsafe { (*(*info).record).code };
    if code == RPC_E_DISCONNECTED {
        COM_DISCONNECTS.fetch_add(1, Relaxed);
    }
    // FACILITY_RPC's HRESULT range. Printing is opt-in: a handler that takes
    // stderr's lock runs on threads this process does not own.
    if PROBE_VERBOSE.load(Relaxed) && code & 0xFFFF_0000 == 0x8001_0000 {
        eprintln!(
            "kaya: first-chance COM exception {code:#010x} on thread {}",
            unsafe { GetCurrentThreadId() }
        );
    }
    CONTINUE_SEARCH
}

/// Armed for every harness build, because that is the build being TESTED. A
/// shipped app carries no handler unless it asks for the probe.
fn install_seh_probe() {
    let verbose = std::env::var_os("KAYA_WINUI_SEH_PROBE").is_some();
    if !verbose && !cfg!(feature = "harness") {
        return;
    }
    PROBE_VERBOSE.store(verbose, std::sync::atomic::Ordering::Relaxed);
    // 1 = ahead of any handler already registered.
    unsafe { AddVectoredExceptionHandler(1, seh_probe) };
}

/// WHICH DIALOG, and everything that differs between the two: the picker's
/// `multiple` and the save dialog's `suggested_name` are meaningless to the
/// other, so a save request PHYSICALLY CANNOT carry two destinations
/// (docs/save-plan.md D2).
enum DialogKind {
    Open { multiple: bool },
    Save { suggested_name: String },
}

/// One request to put a dialog up, handed to the apartment thread.
struct DialogRequest {
    hwnd: isize,
    kind: DialogKind,
    filters: Vec<(String, String)>,
    folder: Option<String>,
    dialog: u64,
    sink: OccSink,
}

/// Requests waiting for the apartment thread.
static DIALOG_QUEUE: std::sync::Mutex<Vec<DialogRequest>> = std::sync::Mutex::new(Vec::new());
/// The apartment thread, started at the first pick and never joined.
static DIALOG_APARTMENT: OnceLock<()> = OnceLock::new();
/// The doorbell the apply arm rings after queueing.
///
/// AN EVENT AND NOT A POSTED MESSAGE: posting needs the thread's id, so the
/// caller would have to WAIT for the thread on the UI thread inside apply,
/// and a thread message is discarded by any modal loop that dispatches it.
static DIALOG_DOORBELL: OnceLock<isize> = OnceLock::new();

fn dialog_doorbell() -> isize {
    *DIALOG_DOORBELL
        .get_or_init(|| unsafe { CreateEventW(std::ptr::null(), 0, 0, std::ptr::null()) })
}

/// The ONE STA the pickers live in, for the life of the process.
///
/// WHY IT IS SHARED AND NEVER TORN DOWN, measured 2026-08-03 (the numbers
/// docs/deferred.md's filedialog_java entry points at): a thread per dialog
/// called CoUninitialize the moment Show() returned, forcing every RPC
/// connection on the thread to close while the Shell's own workers were
/// still calling back, so RPCRT4 raised RPC_E_DISCONNECTED (0x80010108) —
/// absorbed by every runtime but the JVM, whose top-level filter reports ANY
/// exception code as fatal: filedialog_java passed 2 of 10 where
/// filedialog_rust passed 10 of 10 ON THE SAME BUILD. A grace period was
/// measured and rejected (5ms -> 13/15, 50ms and 250ms -> 15/15: a race won
/// by margin). It PUMPS while idle, because those workers post into it.
fn dialog_apartment() {
    DIALOG_APARTMENT.get_or_init(|| {
        let doorbell = dialog_doorbell();
        std::thread::Builder::new()
            .name("kaya-file-dialog".into())
            .spawn(move || {
                const COINIT_APARTMENTTHREADED: u32 = 0x2;
                const INFINITE: u32 = 0xFFFF_FFFF;
                const QS_ALLINPUT: u32 = 0x04FF;
                const MWMO_INPUTAVAILABLE: u32 = 0x0004;
                const PM_REMOVE: u32 = 0x0001;
                unsafe { CoInitializeEx(std::ptr::null(), COINIT_APARTMENTTHREADED) };
                // NO CoUninitialize ANYWHERE BELOW, deliberately, and no way
                // out of this loop: the apartment ends with the process.
                loop {
                    // One at a time, and never under the lock: a picker
                    // runs a nested modal loop for as long as the user
                    // stares at it.
                    while let Some(request) = DIALOG_QUEUE.lock().unwrap().pop() {
                        run_dialog_request(request);
                    }
                    let mut msg = Msg::default();
                    while unsafe { PeekMessageW(&mut msg, 0, 0, 0, PM_REMOVE) } != 0 {
                        unsafe { DispatchMessageW(&msg) };
                    }
                    unsafe {
                        MsgWaitForMultipleObjectsEx(
                            1,
                            &doorbell,
                            INFINITE,
                            QS_ALLINPUT,
                            MWMO_INPUTAVAILABLE,
                        )
                    };
                }
            })
            .expect("failed to spawn the file dialog thread");
    });
}

/// Put one dialog up and answer it. Runs ON the apartment thread.
///
/// ONE ANSWERING PATH FOR BOTH (docs/save-plan.md D2). What is NOT shared is
/// the source each registers: the picker a `PathSource`, the save dialog a
/// `SaveDestination` whose open creates. The backend hands over the locator
/// UNCHANGED and creates nothing itself.
fn run_dialog_request(request: DialogRequest) {
    let picked = match request.kind {
        DialogKind::Open { multiple } => file_dialog_show(
            request.hwnd,
            multiple,
            &request.filters,
            request.folder.as_deref(),
        )
        .into_iter()
        .map(|(name, path)| {
            let handle = crate::capi::picked_register(std::sync::Arc::new(
                crate::protocol::PathSource {
                    name: name.clone(),
                    path: path.clone(),
                },
            ));
            crate::protocol::PickedFile {
                handle,
                name,
                local_path: path,
            }
        })
        .collect::<Vec<_>>(),
        DialogKind::Save { suggested_name } => file_save_show(
            request.hwnd,
            &suggested_name,
            &request.filters,
            request.folder.as_deref(),
        )
        .into_iter()
        .map(|(name, path)| {
            let handle = crate::capi::picked_register(std::sync::Arc::new(
                crate::protocol::SaveDestination {
                    name: name.clone(),
                    path: path.clone(),
                },
            ));
            crate::protocol::PickedFile {
                handle,
                name,
                local_path: path,
            }
        })
        .collect::<Vec<_>>(),
    };
    // Cancel is the EMPTY LIST: no platform can confirm an empty selection, so
    // there is no sentinel to invent (DESIGN.md, File dialogs).
    crate::capi::file_dialog_retire(request.dialog);
    request.sink.send(Occurrence::FileDialogResult {
        dialog: crate::protocol::FileDialogId(request.dialog),
        files: picked,
    });
}

fn window_client_width(core: &CoreState, window: u64) -> Option<f64> {
    let target = winui_window(core, window).ok()?;
    let native: IWindowNative = windows_core::Interface::cast(&target).ok()?;
    let hwnd = native.window_handle().ok()?;
    let mut client = Rect::default();
    let scale;
    unsafe {
        if GetClientRect(hwnd, &mut client) == 0 {
            return None;
        }
        // DIP, not physical pixels — the same conversion resize_request
        // uses, so the 600 boundary means what it means elsewhere.
        scale = f64::from(GetDpiForWindow(hwnd)) / 96.0;
    }
    Some(f64::from(client.right - client.left) / scale)
}

/// Show or hide the covered entry's back bar according to the CONTROL's mode.
/// TwoPaneView decides whether the detail covers the list, so the affordance
/// follows its Mode rather than a width kaya measured. Called from
/// ModeChanged too, because Mode is settled during layout and not before.
fn apply_split_back_bar(core: &CoreState, window: u64) -> windows_core::Result<()> {
    let Some(view) = core.split_views.get(&window) else {
        return Ok(());
    };
    let covering = view.Mode()? == TwoPaneViewMode::SinglePane;
    let Some(top) = core.nav_stacks.get(&window).and_then(|s| s.last()).copied() else {
        return Ok(());
    };
    if let Some(back) = core.nav_entries.get(&top).and_then(|e| e.back_button.clone()) {
        let back: UIElement = back.cast()?;
        back.SetVisibility(if covering {
            Visibility::Visible
        } else {
            Visibility::Collapsed
        })?;
    }
    Ok(())
}

/// Release the roots a previous list-detail render is still holding.
/// A UIElement lives in exactly ONE Children collection, and appending a
/// parented one takes a non-unwinding panic through the XAML layer and ABORTS
/// the process.
fn release_split(core: &mut CoreState, window: u64) -> windows_core::Result<()> {
    // DEPTH-FIRST: the inner view's panes first, then the outer's. Nulling the
    // outer alone leaves the inner still holding two roots.
    if let Some(inner) = core.inner_splits.remove(&window) {
        inner.SetPane1(None::<&UIElement>)?;
        inner.SetPane2(None::<&UIElement>)?;
    }
    if let Some(view) = core.split_views.remove(&window) {
        // TwoPaneView holds its panes as PROPERTIES, not in a Children
        // collection, so emptying it means nulling both.
        view.SetPane1(None::<&UIElement>)?;
        view.SetPane2(None::<&UIElement>)?;
    }
    Ok(())
}

/// Let go of whatever the WINDOW itself is currently showing. On the FIRST
/// split render the base root is still the window's own content, and appending
/// it to the Grid then fails with "Element is already the child of another
/// element" — a non-unwinding panic that takes the process with it.
fn detach_window_content(core: &CoreState, window: u64) -> windows_core::Result<()> {
    if let Some(slot) = core.menu_slots.get(&window) {
        slot.Children()?.Clear()
    } else {
        winui_window(core, window)?.SetContent(None)
    }
}

fn set_window_content(
    core: &CoreState,
    window: u64,
    element: &UIElement,
) -> windows_core::Result<()> {
    if let Some(slot) = core.menu_slots.get(&window) {
        let children = slot.Children()?;
        children.Clear()?;
        children.Append(element)?;
        Ok(())
    } else {
        winui_window(core, window)?.SetContent(element)
    }
}

/// One real MenuFlyout per context anchor, set as the element's ContextFlyout.
fn ensure_context_flyout(core: &mut CoreState, widget: u64) -> windows_core::Result<()> {
    if core.context_flyouts.contains_key(&widget) {
        return Ok(());
    }
    // At ATTACH, not at first show: a flyout whose styles are missing dies
    // on the user's first right-click.
    require_control_resources("this widget declares a context menu");
    let flyout = MenuFlyout::new()?;
    let element = core
        .widgets
        .get(&WidgetId(widget))
        .expect("scene validated the context anchor")
        .element()?;
    element.SetContextFlyout(&flyout)?;
    core.context_flyouts.insert(widget, flyout);
    Ok(())
}

/// The canonical shortcut spelling (root-validated: lowercase,
/// `primary`/`shift`/`alt` order, one key) onto the accelerator enums.
/// `primary` = Control on Windows.
fn accelerator_chord(spelling: &str) -> Option<(VirtualKey, VirtualKeyModifiers)> {
    let mut mods = VirtualKeyModifiers::None;
    let mut key = None;
    for part in spelling.split('+') {
        match part {
            "primary" => mods = VirtualKeyModifiers(mods.0 | VirtualKeyModifiers::Control.0),
            "shift" => mods = VirtualKeyModifiers(mods.0 | VirtualKeyModifiers::Shift.0),
            "alt" => mods = VirtualKeyModifiers(mods.0 | VirtualKeyModifiers::Menu.0),
            k => key = virtual_key(k),
        }
    }
    Some((key?, mods))
}

/// One closed key floor (DESIGN.md, Menus) onto Windows.System VirtualKey
/// values. `escape` never arrives — the root rejects every spelling of it.
fn virtual_key(name: &str) -> Option<VirtualKey> {
    match name {
        "enter" => return Some(VirtualKey(0x0D)),
        "delete" => return Some(VirtualKey(0x2E)),
        "left" => return Some(VirtualKey(0x25)),
        "up" => return Some(VirtualKey(0x26)),
        "right" => return Some(VirtualKey(0x27)),
        "down" => return Some(VirtualKey(0x28)),
        // The punctuation set onto the OEM keys. VK_OEM_* are defined by
        // POSITION on the US layout, which is what the canonical names denote.
        "minus" => return Some(VirtualKey(0xBD)),        // VK_OEM_MINUS
        "equal" => return Some(VirtualKey(0xBB)),        // VK_OEM_PLUS (the = key)
        "comma" => return Some(VirtualKey(0xBC)),        // VK_OEM_COMMA
        "period" => return Some(VirtualKey(0xBE)),       // VK_OEM_PERIOD
        "slash" => return Some(VirtualKey(0xBF)),        // VK_OEM_2
        "backslash" => return Some(VirtualKey(0xDC)),    // VK_OEM_5
        "leftbracket" => return Some(VirtualKey(0xDB)),  // VK_OEM_4
        "rightbracket" => return Some(VirtualKey(0xDD)), // VK_OEM_6
        _ => {}
    }
    if let Some(n) = name.strip_prefix('f').and_then(|s| s.parse::<u32>().ok()) {
        if (1..=12).contains(&n) {
            return Some(VirtualKey(0x70 + n as i32 - 1));
        }
    }
    let bytes = name.as_bytes();
    if bytes.len() == 1 && bytes[0].is_ascii_lowercase() {
        return Some(VirtualKey(i32::from(bytes[0]) - 32)); // 'a'..'z' -> A..Z
    }
    if bytes.len() == 1 && bytes[0].is_ascii_digit() {
        return Some(VirtualKey(i32::from(bytes[0]))); // '0'..'9' -> Number0..9
    }
    None
}

/// Rebuild every window bar and context flyout from the model — which IS the
/// post-user mirror, so a rebuild forced by an unrelated prop write preserves
/// the user's toggle/radio state (docs/traps.md). Coalesced per drain.
fn rebuild_menus(core: &mut CoreState) -> windows_core::Result<()> {
    assert_chord_premise();
    if std::env::var_os("KAYA_WINUI_MENU_PROBE").is_some() {
        menu_probe();
    }
    core.menu_natives.clear();
    core.menu_shortcuts.clear();
    let windows: Vec<(u64, Vec<u64>)> = core
        .menu_windows
        .iter()
        .map(|(w, tops)| (*w, tops.clone()))
        .collect();
    for (window, tops) in windows {
        let Some(bar) = core.menubars.get(&window).cloned() else {
            continue;
        };
        let items = bar.Items()?;
        items.Clear()?;
        ensure_key_hook();
        for top in tops {
            let (label, kind) = {
                let m = &core.menu_models[&top];
                (m.label.clone(), m.kind)
            };
            let bar_item = MenuBarItem::new()?;
            bar_item.SetTitle(&HSTRING::from(&*label))?;
            bar_item.SetIsEnabled(menu_effective_enabled(core, top))?;
            // NO SYMBOL HERE, and it is the platform's gap: MenuBarItem has no
            // Icon slot in the pinned metadata (Title and Items, 243 members),
            // so a symbol declared on a top-level grouping is dropped rather
            // than approximated, and `menu_symbol` reports exactly that.
            let children: Vec<u64> = if kind == MenuItemKind::RadioGroup {
                vec![top]
            } else {
                core.menu_models[&top].children.clone()
            };
            build_menu_items(core, &bar_item.Items()?, &children, MenuAttachment::Window(window))?;
            items.Append(&bar_item)?;
            core.menu_natives
                .insert((MenuAttachment::Window(window), top), MenuNative::Bar(bar_item));
        }
    }
    let attaches: Vec<(u64, Vec<u64>)> = core
        .context_roots
        .iter()
        .map(|(w, roots)| (*w, roots.clone()))
        .collect();
    for (widget, roots) in attaches {
        let Some(flyout) = core.context_flyouts.get(&widget).cloned() else {
            continue;
        };
        let items = flyout.Items()?;
        items.Clear()?;
        build_menu_items(core, &items, &roots, MenuAttachment::Context(widget))?;
    }
    let roots = core.menu_windows.get(&0).cloned().unwrap_or_default();
    let mut order = Vec::new();
    menu_preorder(core, &roots, &mut order);
    for id in order {
        let m = &core.menu_models[&id];
        // This table also GATES the harness's shortcut verb, so a kind missing
        // here is a chord that is never pressed (docs/traps.md: A harness verb
        // gated on a table is a chord that never fires).
        if !m.shortcut.is_empty() && m.kind.takes_shortcut() {
            core.menu_shortcuts.insert(m.shortcut.clone(), id);
        }
    }
    // THE TOOLBAR REBUILDS WITH THE CATALOG, from the same mirror and in the
    // same pass: this is the one place that sees every catalog mutation
    // (docs/chrome-plan.md C2).
    let shells: Vec<u64> = core.menu_shells.keys().copied().collect();
    for window in shells {
        refresh_toolbar(core, window)?;
    }
    // The rebuild stamped STRUCTURAL enablement alone onto the fresh natives,
    // which would un-gray a role item whose clipboard half says no.
    if core.roles_armed {
        refresh_role_enablement(core);
    }
    Ok(())
}

/// Attach a chord to a native item — every LEAF command may carry one.
/// The accelerator is DRESS, not dispatch: WinUI draws the chord text beside
/// the item from it, and the key hook eats the keystroke before any default
/// action of it can run (see The chord route).
fn attach_accelerator(
    accels: &windows_collections::IVector<KeyboardAccelerator>,
    shortcut: &str,
) -> windows_core::Result<()> {
    if shortcut.is_empty() {
        return Ok(());
    }
    let Some((key, mods)) = accelerator_chord(shortcut) else {
        return Ok(());
    };
    let accel = KeyboardAccelerator::new()?;
    accel.SetKey(key)?;
    accel.SetModifiers(mods)?;
    // The default action is a UIA pattern lookup, and dead from this side: the
    // hook consumes the key first (docs/traps.md: A WinUI accelerator's default
    // action is a UI Automation PATTERN).
    accels.Append(&accel)?;
    Ok(())
}

fn build_menu_items(
    core: &mut CoreState,
    dest: &windows_collections::IVector<MenuFlyoutItemBase>,
    ids: &[u64],
    attachment: MenuAttachment,
) -> windows_core::Result<()> {
    use windows_core::Interface as _;
    for &id in ids {
        let (kind, label, checked, value, shortcut, symbol, children) = {
            let m = &core.menu_models[&id];
            (
                m.kind,
                m.label.clone(),
                m.checked,
                m.value,
                m.shortcut.clone(),
                m.symbol,
                m.children.clone(),
            )
        };
        let enabled = menu_effective_enabled(core, id);
        match kind {
            MenuItemKind::Separator => {
                dest.Append(&MenuFlyoutSeparator::new()?.cast::<MenuFlyoutItemBase>()?)?;
            }
            MenuItemKind::Action => {
                let item = MenuFlyoutItem::new()?;
                item.SetText(&HSTRING::from(&*label))?;
                item.SetIsEnabled(enabled)?;
                apply_symbol(&item, symbol)?;
                attach_accelerator(&item.KeyboardAccelerators()?, &shortcut)?;
                let handler = RoutedEventHandler::new(move |_, _| {
                    menu_user_activate(id, attachment);
                    Ok(())
                });
                item.Click(&handler)?;
                dest.Append(&item.cast::<MenuFlyoutItemBase>()?)?;
                core.menu_natives.insert((attachment, id), MenuNative::Action(item));
            }
            MenuItemKind::Toggle => {
                let item = ToggleMenuFlyoutItem::new()?;
                item.SetText(&HSTRING::from(&*label))?;
                item.SetIsChecked(checked)?;
                item.SetIsEnabled(enabled)?;
                // The checkable kind takes an icon like any other leaf: in
                // WinUI 3 it descends from MenuFlyoutItem.
                apply_symbol(&item, symbol)?;
                attach_accelerator(&item.KeyboardAccelerators()?, &shortcut)?;
                let handler = RoutedEventHandler::new(move |_, _| {
                    menu_user_activate(id, attachment);
                    Ok(())
                });
                item.Click(&handler)?;
                dest.Append(&item.cast::<MenuFlyoutItemBase>()?)?;
                core.menu_natives.insert((attachment, id), MenuNative::Toggle(item));
            }
            MenuItemKind::Menu => {
                let sub = MenuFlyoutSubItem::new()?;
                sub.SetText(&HSTRING::from(&*label))?;
                sub.SetIsEnabled(enabled)?;
                apply_symbol(&sub, symbol)?;
                build_menu_items(core, &sub.Items()?, &children, attachment)?;
                dest.Append(&sub.cast::<MenuFlyoutItemBase>()?)?;
                core.menu_natives.insert((attachment, id), MenuNative::Sub(sub));
            }
            MenuItemKind::RadioGroup => {
                // Inline with the platform's checkmark idiom: the options join
                // the enclosing vector directly (RadioMenuFlyoutItem.GroupName
                // per radio group); the GROUP mints no chrome of its own here.
                for (index, &option) in children.iter().enumerate() {
                    let (option_label, option_shortcut, option_symbol) = {
                        let m = &core.menu_models[&option];
                        (m.label.clone(), m.shortcut.clone(), m.symbol)
                    };
                    let option_enabled = menu_effective_enabled(core, option);
                    let radio = RadioMenuFlyoutItem::new()?;
                    radio.SetText(&HSTRING::from(&*option_label))?;
                    radio.SetGroupName(&HSTRING::from(format!("kmg{id}")))?;
                    radio.SetIsChecked(value == index as f64)?;
                    radio.SetIsEnabled(option_enabled)?;
                    apply_symbol(&radio, option_symbol)?;
                    attach_accelerator(&radio.KeyboardAccelerators()?, &option_shortcut)?;
                    let handler = RoutedEventHandler::new(move |_, _| {
                        menu_user_activate(option, attachment);
                        Ok(())
                    });
                    radio.Click(&handler)?;
                    dest.Append(&radio.cast::<MenuFlyoutItemBase>()?)?;
                    core.menu_natives
                        .insert((attachment, option), MenuNative::Option(radio));
                }
            }
            // The closed grammar: options build through their group.
            MenuItemKind::RadioOption => {}
        }
    }
    Ok(())
}




// --- The chord route (Win32) -------------------------------------------
//
// EVERY chord this catalog owns dispatches from here: a THREAD-scoped hook
// that matches the canonical spelling against the same catalog table the
// verb gates on and consumes only a chord this catalog owns. THE TWO-ROUTE
// SPLIT IT REPLACED WAS A RACE — the XAML accelerator route PERMANENTLY
// DROPS a chord arriving within ~45ms of the previous chord's activation
// (measured 2026-08-03: the two passing runs landed 67ms and 81ms after the
// preceding activation, the fourteen failures within 42ms, LOST not late;
// docs/deferred.md, "Follow-ups from the WinUI chord-drop fix"). The
// accelerators stay attached for the chord TEXT WinUI draws beside items.
unsafe extern "system" {
    fn SetWindowsHookExW(id: i32, proc_: HookProc, module: isize, thread: u32) -> isize;
    fn CallNextHookEx(hook: isize, code: i32, wparam: usize, lparam: isize) -> isize;
    fn GetCurrentThreadId() -> u32;
    fn GetKeyState(vkey: i32) -> i16;
}
type HookProc = unsafe extern "system" fn(i32, usize, isize) -> isize;

thread_local! {
    static KEY_HOOK: std::cell::Cell<isize> = const { std::cell::Cell::new(0) };
}

fn modifier_down(vkey: i32) -> bool {
    (unsafe { GetKeyState(vkey) }) < 0
}

/// The canonical key name for a virtual-key code — the reverse of
/// [`virtual_key`], over the same closed floor.
fn key_name(code: u32) -> Option<String> {
    Some(match code {
        0x0D => "enter".to_owned(),
        0x2E => "delete".to_owned(),
        0x25 => "left".to_owned(),
        0x26 => "up".to_owned(),
        0x27 => "right".to_owned(),
        0x28 => "down".to_owned(),
        0xBD => "minus".to_owned(),
        0xBB => "equal".to_owned(),
        0xBC => "comma".to_owned(),
        0xBE => "period".to_owned(),
        0xBF => "slash".to_owned(),
        0xDC => "backslash".to_owned(),
        0xDB => "leftbracket".to_owned(),
        0xDD => "rightbracket".to_owned(),
        0x30..=0x39 => char::from(b'0' + (code - 0x30) as u8).to_string(),
        0x41..=0x5A => char::from(b'a' + (code - 0x41) as u8).to_string(),
        0x70..=0x7B => format!("f{}", code - 0x70 + 1),
        _ => return None,
    })
}

unsafe extern "system" fn key_hook(code: i32, wparam: usize, lparam: isize) -> isize {
    const HC_ACTION: i32 = 0;
    // Bit 31 set = the key is coming up; bit 30 set = it was already
    // down (auto-repeat), which a menu chord ignores.
    if code == HC_ACTION && (lparam & (1 << 31)) == 0 && (lparam & (1 << 30)) == 0 {
        if let Some(key) = key_name(wparam as u32) {
            let mut spelling = String::new();
            if modifier_down(0x11) {
                spelling.push_str("primary+");
            }
            if modifier_down(0x10) {
                spelling.push_str("shift+");
            }
            if modifier_down(0x12) {
                spelling.push_str("alt+");
            }
            spelling.push_str(&key);
            let hit = CORE.with_borrow(|core| {
                let core = core.as_ref()?;
                let item = *core.menu_shortcuts.get(&spelling)?;
                let kind = core.menu_models.get(&item)?.kind;
                Some((item, kind, menu_effective_enabled(core, item)))
            });
            if let Some((item, kind, enabled)) = hit {
                // A disabled item is INERT, exactly as native chrome leaves
                // it — the chord is still this catalog's, so it is eaten
                // rather than sprayed at whatever is behind. WHICH IS WHY
                // THE UNDO ROUTING LIVES ON THIS PATH (docs/undo-plan.md
                // §1.1): a focused field never sees Ctrl+Z once this catalog
                // owns the chord.
                if enabled {
                    // The native owns the immediate user change, exactly as it
                    // does for a click. EXHAUSTIVE over the kind: a new leaf
                    // kind that may carry a chord fails to COMPILE here rather
                    // than reaching a catch-all that dispatches nothing.
                    let _ = CORE.with_borrow(|core| -> windows_core::Result<()> {
                        let Some(core) = core.as_ref() else { return Ok(()) };
                        let native = core.menu_natives.get(&(MenuAttachment::Window(0), item));
                        match kind {
                            MenuItemKind::Toggle => {
                                if let Some(MenuNative::Toggle(native)) = native {
                                    let now = native.IsChecked()?;
                                    native.SetIsChecked(!now)?;
                                }
                            }
                            // One option of a group: checking it is what the
                            // platform's own Select() does, and the shared
                            // GroupName clears the sibling.
                            MenuItemKind::RadioOption => {
                                if let Some(MenuNative::Option(native)) = native {
                                    native.SetIsChecked(true)?;
                                }
                            }
                            // A plain command owns no state of its own.
                            MenuItemKind::Action => {}
                            // Not leaf kinds: menu_shortcuts holds only what
                            // takes_shortcut admits.
                            MenuItemKind::Menu
                            | MenuItemKind::RadioGroup
                            | MenuItemKind::Separator => {}
                        }
                        Ok(())
                    });
                    menu_user_activate(item, MenuAttachment::Window(0));
                }
                return 1; // consumed: this catalog owns the chord
            }
        }
    }
    let hook = KEY_HOOK.with(|h| h.get());
    unsafe { CallNextHookEx(hook, code, wparam, lparam) }
}

/// Install the thread-scoped key hook once, on the UI thread.
fn ensure_key_hook() {
    const WH_KEYBOARD: i32 = 2;
    KEY_HOOK.with(|slot| {
        if slot.get() == 0 {
            slot.set(unsafe { SetWindowsHookExW(WH_KEYBOARD, key_hook, 0, GetCurrentThreadId()) });
        }
    });
}

/// THE user dispatch path: chrome clicks, the accelerator route and harness
/// verbs all land here. Fires from the message loop, never under an apply
/// borrow. Mirrors FIRST (the post-user-mirror rule), then emits with the
/// item's identity and the noun of the attachment whose copy fired. Disabled
/// items — the inherited AND — stay inert.
fn menu_user_activate(item: u64, attachment: MenuAttachment) {
    CORE.with_borrow_mut(|core| {
        let Some(core) = core.as_mut() else { return };
        // Echo doctrine belt: no programmatic write path raises Click on these
        // controls (the MENU PROBE verifies), but the apply guard keeps one
        // quiet if it ever did.
        if core.apply_quiet.load(std::sync::atomic::Ordering::Relaxed) {
            return;
        }
        let Some(model) = core.menu_models.get(&item) else {
            return;
        };
        let kind = model.kind;
        let was_checked = model.checked;
        let role = model.role.clone();
        if !menu_effective_enabled(core, item) {
            return;
        }
        // A DISABLED ROLE ITEM IS INERT beyond the structural AND: the
        // intersection half lives on the native's IsEnabled, which this route
        // does not consult, so it is recomputed here (docs/clipboard-plan.md
        // §3).
        if matches!(role.as_str(), "cut" | "copy" | "paste" | "undo" | "redo")
            && !role_enabled(core, &role)
        {
            return;
        }
        let noun = match attachment {
            MenuAttachment::Window(_) => Path::new(),
            MenuAttachment::Context(widget) => {
                core.context_nouns.get(&widget).cloned().unwrap_or_default()
            }
        };
        match kind {
            MenuItemKind::Action => {
                // A GESTURE ROLE PERFORMS RATHER THAN REPORTS: no menu
                // occurrence goes up (DESIGN.md — gestures are commands). UNDO
                // FIRST: an undo is not a clipboard command, and this is the ONE
                // dispatch both the chord hook and the harness activation reach.
                if perform_undo_role(core, &role) {
                    return;
                }
                if perform_clipboard_role(core, &role) {
                    return;
                }
                core.occurrences.send(if noun.is_empty() {
                    Occurrence::MenuActivated { item: MenuItemId(item) }
                } else {
                    Occurrence::InstanceMenuActivated {
                        item: MenuItemId(item),
                        path: noun.clone(),
                    }
                });
            }
            MenuItemKind::Toggle => {
                // The native control owns the immediate user change (it flipped
                // IsChecked before raising Click): mirror from the firing copy's
                // own native, by its attachment key, then emit (docs/traps.md).
                let checked = match core.menu_natives.get(&(attachment, item)) {
                    Some(MenuNative::Toggle(native)) => {
                        native.IsChecked().unwrap_or(!was_checked)
                    }
                    _ => !was_checked,
                };
                core.menu_models.get_mut(&item).expect("checked above").checked = checked;
                core.occurrences.send(if noun.is_empty() {
                    Occurrence::MenuToggled { item: MenuItemId(item), checked }
                } else {
                    Occurrence::InstanceMenuToggled {
                        item: MenuItemId(item),
                        path: noun.clone(),
                        checked,
                    }
                });
            }
            MenuItemKind::RadioOption => {
                let Some(group) = core.menu_models.get(&item).and_then(|m| m.parent) else {
                    return;
                };
                let Some(index) = core
                    .menu_models
                    .get(&group)
                    .and_then(|g| g.children.iter().position(|&c| c == item))
                else {
                    return;
                };
                // Re-selecting the selected option is not a change and emits
                // nothing (the choice contract).
                if core.menu_models[&group].value == index as f64 {
                    return;
                }
                core.menu_models.get_mut(&group).expect("resolved above").value =
                    index as f64; // the retained mirror, BEFORE the emit
                core.occurrences.send(if noun.is_empty() {
                    Occurrence::MenuValueChanged {
                        group: MenuItemId(group),
                        index: index as f64,
                    }
                } else {
                    Occurrence::InstanceMenuValueChanged {
                        group: MenuItemId(group),
                        path: noun.clone(),
                        index: index as f64,
                    }
                });
            }
            // Grouping nodes and separators have no activation.
            _ => {}
        }
    });
}

/// The harness's REAL invoke route (the ContentDialog precedent): the item's
/// automation peer, cast to the provider pattern it exposes — Invoke for
/// plain/radio items, Toggle for toggle items. The peer pipeline runs the
/// control's own OnInvoke, which raises the same Click a pointer press does.
fn invoke_menu_native(native: &MenuNative) -> windows_core::Result<()> {
    use bindings::Microsoft::UI::Xaml::Automation::Peers::FrameworkElementAutomationPeer;
    use bindings::Microsoft::UI::Xaml::Automation::Provider::{IInvokeProvider, IToggleProvider};
    use windows_core::Interface as _;
    let element: UIElement = match native {
        MenuNative::Action(i) => i.cast()?,
        MenuNative::Toggle(i) => i.cast()?,
        MenuNative::Option(i) => i.cast()?,
        MenuNative::Bar(_) | MenuNative::Sub(_) => return Ok(()),
    };
    let peer = FrameworkElementAutomationPeer::CreatePeerForElement(&element)?;
    if let Ok(invoke) = peer.cast::<IInvokeProvider>() {
        return invoke.Invoke();
    }
    peer.cast::<IToggleProvider>()?.Toggle()
}


/// The PREMISE the peer-invoke route rests on, checked once per process —
/// not flag-gated, because a silent change here is a dead harness
/// activation or a checkmark that never moves. [`invoke_menu_native`] asks
/// for Invoke FIRST and falls back to Toggle, the platform's own priority
/// (docs/traps.md: A WinUI accelerator's default action is a UI Automation
/// PATTERN). The CHORD route rests on none of it.
fn assert_chord_premise() {
    static CHECKED: OnceLock<()> = OnceLock::new();
    if CHECKED.set(()).is_err() {
        return;
    }
    let probe: windows_core::Result<()> = (|| {
        use bindings::Microsoft::UI::Xaml::Automation::Peers::FrameworkElementAutomationPeer;
        use bindings::Microsoft::UI::Xaml::Automation::Provider::IInvokeProvider;
        use windows_core::Interface as _;
        let action: UIElement = MenuFlyoutItem::new()?.cast()?;
        let action_invokes = FrameworkElementAutomationPeer::CreatePeerForElement(&action)?
            .cast::<IInvokeProvider>()
            .is_ok();
        let toggle: UIElement = ToggleMenuFlyoutItem::new()?.cast()?;
        let toggle_invokes = FrameworkElementAutomationPeer::CreatePeerForElement(&toggle)?
            .cast::<IInvokeProvider>()
            .is_ok();
        assert!(
            action_invokes,
            "kaya: MenuFlyoutItem lost its Invoke automation pattern — the \
             harness's menu_activate has no pattern left to drive, so a plain \
             command can no longer be activated at all (docs/traps.md)"
        );
        assert!(
            !toggle_invokes,
            "kaya: ToggleMenuFlyoutItem GAINED an Invoke automation pattern — \
             invoke_menu_native prefers Invoke, so a checkable command would be \
             INVOKED instead of toggled and its checkmark would never move \
             (docs/traps.md)"
        );
        Ok(())
    })();
    if let Err(e) = probe {
        eprintln!("kaya: chord-premise check failed: {:?} {}", e.code(), e.message());
    }
}

/// KAYA_WINUI_MENU_PROBE: the flag-gated instrument (the KAYA_WINUI_NAV_PROBE
/// pattern) answering this backend's two menu behaviour questions in-band, on
/// detached canary items — (1) echo doctrine: a programmatic IsChecked write
/// must not raise Click; (2) the peer-invoke route must raise Click on an item
/// whose flyout has never opened. Runs once, at the first rebuild.
fn menu_probe() {
    static RAN: OnceLock<()> = OnceLock::new();
    if RAN.set(()).is_err() {
        return;
    }
    let probe: windows_core::Result<()> = (|| {
        use std::sync::atomic::{AtomicBool, Ordering};
        use std::sync::Arc;
        // (1) Echo canary: programmatic set on toggle and radio items.
        let toggled = Arc::new(AtomicBool::new(false));
        let toggle = ToggleMenuFlyoutItem::new()?;
        let seen = toggled.clone();
        toggle.Click(&RoutedEventHandler::new(move |_, _| {
            seen.store(true, Ordering::Relaxed);
            Ok(())
        }))?;
        toggle.SetIsChecked(true)?;
        toggle.SetIsChecked(false)?;
        let radio_fired = Arc::new(AtomicBool::new(false));
        let radio = RadioMenuFlyoutItem::new()?;
        let seen = radio_fired.clone();
        radio.Click(&RoutedEventHandler::new(move |_, _| {
            seen.store(true, Ordering::Relaxed);
            Ok(())
        }))?;
        radio.SetGroupName(&HSTRING::from("kmg-probe"))?;
        radio.SetIsChecked(true)?;
        eprintln!(
            "kaya: MENU PROBE programmatic-set clicks: toggle={} radio={} (must both be false)",
            toggled.load(Ordering::Relaxed),
            radio_fired.load(Ordering::Relaxed),
        );
        // (2) Peer-invoke canary on a never-opened item.
        let clicked = Arc::new(AtomicBool::new(false));
        let item = MenuFlyoutItem::new()?;
        let seen = clicked.clone();
        item.Click(&RoutedEventHandler::new(move |_, _| {
            seen.store(true, Ordering::Relaxed);
            Ok(())
        }))?;
        invoke_menu_native(&MenuNative::Action(item))?;
        eprintln!(
            "kaya: MENU PROBE peer invoke on closed item: click fired={} (must be true)",
            clicked.load(Ordering::Relaxed),
        );
        Ok(())
    })();
    if let Err(e) = probe {
        eprintln!("kaya: MENU PROBE failed: {:?} {}", e.code(), e.message());
    }
}

// ---- Clipboard (DESIGN.md, Clipboard; docs/clipboard-plan.md §6, the
// windows section; tools/win/clipprobe) --------------------------------
// CLASSIC WIN32, DELIBERATELY: WinRT DataTransfer's SetContent is
// documented to work "only when the application is in the foreground", its
// custom-format bridge to Win32 atoms is documented only in the read
// direction, and its content dies with the process unless flushed.

const CF_UNICODETEXT: u32 = 13;
const CF_HDROP: u32 = 15;

fn clip_register(name: &str) -> u32 {
    let wide: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();
    unsafe {
        windows::Win32::System::DataExchange::RegisterClipboardFormatW(
            windows_core::PCWSTR(wide.as_ptr()),
        )
    }
}

/// Open with a bounded retry: the clipboard is a global lock, and
/// another process holding it answers with an error, not a wait.
fn clip_open_retry() -> windows_core::Result<()> {
    let mut last = Ok(());
    for attempt in 0..10 {
        last = unsafe { windows::Win32::System::DataExchange::OpenClipboard(None) };
        if last.is_ok() {
            return Ok(());
        }
        std::thread::sleep(std::time::Duration::from_millis(20 * (attempt + 1)));
    }
    last
}

fn clip_set_bytes(format: u32, bytes: &[u8]) -> windows_core::Result<()> {
    unsafe {
        let hglobal = windows::Win32::System::Memory::GlobalAlloc(
            windows::Win32::System::Memory::GMEM_MOVEABLE,
            bytes.len().max(1),
        )?;
        let p = windows::Win32::System::Memory::GlobalLock(hglobal);
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), p as *mut u8, bytes.len());
        let _ = windows::Win32::System::Memory::GlobalUnlock(hglobal);
        windows::Win32::System::DataExchange::SetClipboardData(
            format,
            Some(windows::Win32::Foundation::HANDLE(hglobal.0)),
        )?;
        Ok(())
    }
}

fn clip_available(format: u32) -> bool {
    unsafe { windows::Win32::System::DataExchange::IsClipboardFormatAvailable(format).is_ok() }
}

/// One format's bytes, inside an already-open clipboard. GlobalSize may exceed
/// the written length (the allocator rounds up), so self-delimiting formats
/// must trust their own delimiters.
fn clip_get_bytes(format: u32) -> Option<Vec<u8>> {
    unsafe {
        let handle = windows::Win32::System::DataExchange::GetClipboardData(format).ok()?;
        let hglobal = windows::Win32::Foundation::HGLOBAL(handle.0);
        let size = windows::Win32::System::Memory::GlobalSize(hglobal);
        let p = windows::Win32::System::Memory::GlobalLock(hglobal);
        if p.is_null() {
            return None;
        }
        let bytes = std::slice::from_raw_parts(p as *const u8, size).to_vec();
        let _ = windows::Win32::System::Memory::GlobalUnlock(hglobal);
        Some(bytes)
    }
}

/// CF_UNICODETEXT and nothing else — the read behind the textarea's plain-text
/// paste pin (`Editable::paste_from_clipboard`).
///
/// NOT `materialize_clipboard`: that one answers the RICHEST representation an
/// accept list takes, and this is the path for a widget that declared none.
fn clipboard_plain_text() -> Option<String> {
    if clip_open_retry().is_err() {
        return None;
    }
    let answer = clip_available(CF_UNICODETEXT)
        .then(|| clip_get_bytes(CF_UNICODETEXT))
        .flatten()
        .map(|bytes| {
            let units: Vec<u16> = bytes
                .chunks_exact(2)
                .map(|c| u16::from_le_bytes([c[0], c[1]]))
                .take_while(|&u| u != 0)
                .collect();
            // The lf boundary: clipboard text is CRLF by Windows convention
            // and the control re-normalizes on the way in.
            lf(String::from_utf16_lossy(&units))
        });
    unsafe {
        let _ = windows::Win32::System::DataExchange::CloseClipboard();
    }
    answer
}

fn clip_utf16z(s: &str) -> Vec<u8> {
    s.encode_utf16()
        .chain(std::iter::once(0))
        .flat_map(|u| u.to_le_bytes())
        .collect()
}

/// CF_HTML with 10-digit fixed-width offsets. Fixed width is what makes the
/// header length a CONSTANT rather than a fixpoint; pad while computing but
/// print unpadded and every offset is silently short. Microsoft's own doc
/// example is arithmetically wrong (docs/clipboard-plan.md §3); this
/// construction is verified byte-exact by tools/win/clipprobe.
fn build_cf_html(fragment: &str) -> Vec<u8> {
    const HEADER_LEN: usize = 105;
    const PREFIX: &str = "<html>\r\n<body>\r\n<!--StartFragment-->";
    const SUFFIX: &str = "<!--EndFragment-->\r\n</body>\r\n</html>";
    let start_fragment = HEADER_LEN + PREFIX.len();
    let end_fragment = start_fragment + fragment.len();
    let end_html = end_fragment + SUFFIX.len();
    let header = format!(
        "Version:0.9\r\nStartHTML:{HEADER_LEN:010}\r\nEndHTML:{end_html:010}\r\nStartFragment:{start_fragment:010}\r\nEndFragment:{end_fragment:010}\r\n"
    );
    debug_assert!(header.len() == HEADER_LEN, "the CF_HTML header stopped being a constant");
    let mut out = header.into_bytes();
    out.extend_from_slice(PREFIX.as_bytes());
    out.extend_from_slice(fragment.as_bytes());
    out.extend_from_slice(SUFFIX.as_bytes());
    out
}

/// The read side's equal and opposite parser: kaya's html representation is the
/// raw fragment, so a CF_HTML payload — whose header kaya may not have written
/// — is sliced by its own StartFragment/EndFragment BYTE offsets. Proven
/// against a foreign header with different padding than ours (PowerShell 5.1's
/// -AsHtml pads to 9 digits with trailing spaces; digits-then-stop parses both).
fn parse_cf_html(payload: &[u8]) -> Option<String> {
    let head = String::from_utf8_lossy(&payload[..payload.len().min(400)]).into_owned();
    let grab = |key: &str| -> Option<usize> {
        let at = head.find(key)? + key.len();
        head[at..]
            .chars()
            .take_while(|c| c.is_ascii_digit())
            .collect::<String>()
            .parse()
            .ok()
    };
    let start = grab("StartFragment:")?;
    let end = grab("EndFragment:")?;
    if start >= end || end > payload.len() {
        return None;
    }
    Some(String::from_utf8_lossy(&payload[start..end]).into_owned())
}

/// DROPFILES: the 20-byte struct (pFiles=20, pt={0,0}, fNC=0,
/// fWide=1), then UTF-16 paths each NUL-terminated, then one extra
/// NUL — measured round-tripping through Explorer's own
/// FileDropList reader.
fn build_dropfiles(paths: &[String]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&20u32.to_le_bytes());
    out.extend_from_slice(&0i32.to_le_bytes());
    out.extend_from_slice(&0i32.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());
    out.extend_from_slice(&1u32.to_le_bytes());
    for path in paths {
        out.extend_from_slice(&clip_utf16z(path));
    }
    out.extend_from_slice(&[0, 0]);
    out
}

fn parse_dropfiles(bytes: &[u8]) -> Vec<String> {
    if bytes.len() < 20 {
        return Vec::new();
    }
    let p_files = u32::from_le_bytes(bytes[0..4].try_into().unwrap()) as usize;
    let f_wide = u32::from_le_bytes(bytes[16..20].try_into().unwrap());
    if f_wide == 0 {
        // An ANSI list is legal but nothing modern writes one; a foreign ANSI
        // writer surfaces here as an empty answer rather than mojibake.
        return Vec::new();
    }
    let mut out = Vec::new();
    let mut at = p_files;
    loop {
        let mut units = Vec::new();
        while at + 1 < bytes.len() {
            let u = u16::from_le_bytes([bytes[at], bytes[at + 1]]);
            at += 2;
            if u == 0 {
                break;
            }
            units.push(u);
        }
        if units.is_empty() {
            break;
        }
        out.push(String::from_utf16_lossy(&units));
    }
    out
}

/// Choose the RICHEST representation the clipboard offers that the accept list
/// takes, read exactly that one, and answer — None for no intersection, the
/// universal no. Descending clip value — custom (accept-list order), files,
/// image, html, text — the canonical order (§1).
fn materialize_clipboard(accepting: &str) -> windows_core::Result<Option<crate::protocol::Representation>> {
    use crate::protocol::Representation as R;
    let (kinds, custom) = crate::wire::parse_accept_list(accepting);
    let chosen_custom = custom
        .iter()
        .map(|id| (id.to_string(), clip_register(id)))
        .find(|(_, format)| clip_available(*format));
    let png = clip_register("PNG");
    let html = clip_register("HTML Format");

    clip_open_retry()?;
    let answer = (|| {
        if let Some((id, format)) = chosen_custom {
            return clip_get_bytes(format).map(|bytes| R::Custom {
                id,
                bytes: crate::protocol::Blob(std::sync::Arc::from(&bytes[..])),
            });
        }
        if kinds & crate::wire::CLIP_FILES != 0 && clip_available(CF_HDROP) {
            let paths = clip_get_bytes(CF_HDROP).map(|b| parse_dropfiles(&b)).unwrap_or_default();
            let files: Vec<_> = paths
                .into_iter()
                .map(|path| {
                    let name = std::path::Path::new(&path)
                        .file_name()
                        .map(|n| n.to_string_lossy().into_owned())
                        .unwrap_or_default();
                    // The picker's capability arriving through the second door:
                    // the same registration the file dialog result makes, so
                    // kaya_open_picked redeems a pasted file identically.
                    let handle = crate::capi::picked_register(std::sync::Arc::new(
                        crate::protocol::PathSource { name: name.clone(), path: path.clone() },
                    ));
                    crate::protocol::PickedFile { handle, name, local_path: path }
                })
                .collect();
            return (!files.is_empty()).then_some(R::Files(files));
        }
        if kinds & crate::wire::CLIP_IMAGE != 0 && clip_available(png) {
            return clip_get_bytes(png)
                .map(|b| R::Image(crate::protocol::Blob(std::sync::Arc::from(&b[..]))));
        }
        if kinds & crate::wire::CLIP_HTML != 0 && clip_available(html) {
            return clip_get_bytes(html).and_then(|b| parse_cf_html(&b)).map(R::Html);
        }
        if kinds & crate::wire::CLIP_TEXT != 0 && clip_available(CF_UNICODETEXT) {
            return clip_get_bytes(CF_UNICODETEXT).map(|bytes| {
                let units: Vec<u16> = bytes
                    .chunks_exact(2)
                    .map(|c| u16::from_le_bytes([c[0], c[1]]))
                    .take_while(|&u| u != 0)
                    .collect();
                // The lf boundary: guest strings are LF everywhere.
                R::Text(lf(String::from_utf16_lossy(&units)))
            });
        }
        None
    })();
    unsafe { windows::Win32::System::DataExchange::CloseClipboard()? };
    Ok(answer)
}

/// The focused editable widget, if any: the root admits `accepts` on entries
/// and textareas alone (scene.rs), and each control IS its own focus target
/// here — no GtkText delegation to walk.
fn focused_editable_id(core: &CoreState) -> Option<u64> {
    let focused = |field: &Editable| {
        field
            .focus_state()
            .map(|s| s != FocusState::Unfocused)
            .unwrap_or(false)
    };
    for (i, field) in core.entries.iter().enumerate() {
        if focused(&Editable::Entry(field.clone())) {
            return Some(core.entry_ids[i]);
        }
    }
    for (i, field) in core.textareas.iter().enumerate() {
        if focused(&Editable::Textarea(field.clone())) {
            return Some(core.textarea_ids[i]);
        }
    }
    None
}

fn editable_by_id(core: &CoreState, id: u64) -> Option<Editable> {
    if let Some(i) = core.entry_ids.iter().position(|&e| e == id) {
        return Some(Editable::Entry(core.entries[i].clone()));
    }
    core.textarea_ids
        .iter()
        .position(|&t| t == id)
        .map(|i| Editable::Textarea(core.textareas[i].clone()))
}

/// RICH-CAPABLE CONTROL, PLAIN-TEXT CONTRACT — the pins, in one place, with
/// their read-back (docs/textarea-foundation-plan.md; the measured defaults
/// are in docs/probes/range-probe-windows.md):
/// - `ClipboardCopyFormat` defaults to `AllFormats`, so a copy out of a
///   kaya textarea would put RTF on the clipboard beside the text;
/// - `DisabledFormattingAccelerators` defaults to `None` — none are
///   DISABLED — so Ctrl+B/I/U actively format inside one; `All` is the pin;
/// - the control's OWN paste routes bypass every kaya path, so the `Paste`
///   event is cancelled and kaya inserts the clipboard's plain text itself.
/// THE READ-BACK IS THE GUARD, a panic on a path nobody can avoid. Two more
/// pins are not properties: `AdjustCrlf` (`Editable::text`) and
/// `TextSetOptions::None` (`Editable::set_text`). Spell-check and text
/// prediction are NOT pinned — the entry carries the same defaults.
fn pin_plain_text(field: &RichEditBox) -> windows_core::Result<()> {
    field.SetClipboardCopyFormat(RichEditClipboardFormat::PlainText)?;
    field.SetDisabledFormattingAccelerators(DisabledFormattingAccelerators::All)?;
    let pasting = Editable::Textarea(field.clone());
    let paste_handler = TextControlPasteEventHandler::new(move |_, args| {
        // Cancel the control's own insertion FIRST — an unhandled
        // paste here is the RichEdit engine's, which takes RTF.
        if let Some(args) = args.as_ref() {
            args.SetHandled(true)?;
        }
        // Then paste what the entry would have pasted. INLINE, and through a
        // range rather than through the live selection — see `selection_range`.
        // The swallow counter is deliberately not bumped: a paste acts like the
        // user, and the control's TextChanged is the report.
        pasting.paste_from_clipboard()
    });
    field.Paste(&paste_handler)?;

    let copy_format = field.ClipboardCopyFormat()?;
    let accelerators = field.DisabledFormattingAccelerators()?;
    assert!(
        copy_format == RichEditClipboardFormat::PlainText
            && accelerators == DisabledFormattingAccelerators::All,
        "kaya: winui: a textarea's plain-text pins did not take \
         (ClipboardCopyFormat={copy_format:?}, wanted PlainText; \
         DisabledFormattingAccelerators={accelerators:?}, wanted All). \
         kaya's textarea is a RichEditBox — a control that CAN carry \
         formatting — held to the plain-text contract every other \
         backend has by construction: string in, string out, nothing \
         rich on the clipboard, Ctrl+B/I/U never bold. Restore the \
         setters in pin_plain_text (crates/kaya/src/winui/mod.rs), or \
         if a Windows App SDK update refused them, work out what it \
         wants instead before shipping a textarea with opinions kaya \
         never agreed to. docs/textarea-foundation-plan.md."
    );
    Ok(())
}

/// D7/A1's clear, in this platform's one available spelling. MEASURED A
/// NO-OP ON THE ENTRY, AND CALLED ANYWAY (docs/undo-plan.md §1.1): setting
/// `TextBox.Text` resets the control's undo buffer by itself, but that is
/// NOT measured on the textarea's RichEditBox, whose stack is the RichEdit
/// engine's. A3 IS THE CALLER'S: every call site sits inside a text-DIFFERS
/// branch, or an app mirroring a field into a signal would lose the history.
fn clear_native_undo(field: &Editable) {
    if let Err(e) = field.clear_undo_redo_history() {
        eprintln!("kaya: winui ClearUndoRedoHistory failed: {}", e.message());
    }
}

// ---- Text ranges (docs/ranges-plan.md D1-D5) ------------------------
// OFFSETS ARRIVE NATIVE AND ARE NEVER CONVERTED HERE: Rich Edit's positions
// are UTF-16 code units, and the only offset arithmetic in this file is in
// the READING direction (`range_spelling`). THE LINE BREAK DOES NOT MOVE
// THEM either — a story stores every break as a single CR against kaya's
// single LF, so the counts agree 1:1 (GTK's buffer is the opposite).

/// The background a declared range wears. Rich Edit's background is opaque —
/// `ITextCharacterFormat` has no alpha channel of its own — so this is the
/// flattened equivalent of the mac arm's 55%-yellow over white.
const HIGHLIGHT_BACKGROUND: bindings::Windows::UI::Color = bindings::Windows::UI::Color {
    A: 255,
    R: 255,
    G: 241,
    B: 143,
};

/// The textarea behind a widget id, or None if this id is not one.
///
/// TEXTAREA ONLY, and the core already refused anything else at the one
/// chokepoint (scene.rs), so None here means the widget vanished between the
/// transaction and its apply.
fn textarea_by_id(core: &CoreState, id: u64) -> Option<RichEditBox> {
    core.textarea_ids
        .iter()
        .position(|&t| t == id)
        .map(|i| core.textareas[i].clone())
}

/// One background write: get the range, take its format COPY, set the colour,
/// assign the copy back. The round trip is not optional —
/// `ITextRange::CharacterFormat` hands out a snapshot, so a colour set on it
/// changes nothing until it is assigned.
fn set_background(
    range: &bindings::Microsoft::UI::Text::ITextRange,
    color: bindings::Windows::UI::Color,
) -> windows_core::Result<()> {
    let format = range.CharacterFormat()?;
    format.SetBackgroundColor(color)?;
    range.SetCharacterFormat(&format)
}

/// Unpaint the whole story.
///
/// EXPLICIT, AND ON EVERY DECLARATION, because `SetText` does NOT reset
/// character formatting on this control (measured,
/// docs/probes/range-probe-windows.md §5: a probe that painted eight
/// characters red ended up with an 80,513-pixel red document after a re-set).
fn clear_highlights(field: &RichEditBox) -> windows_core::Result<()> {
    let doc = field.TextDocument()?;
    let story = doc.GetRange(0, TextConstants::MaxUnitCount()?)?;
    set_background(&story, TextConstants::AutoColor()?)
}

/// THE DECLARED SET, painted (D1's first primitive).
fn paint_highlights(
    field: &RichEditBox,
    ranges: &[crate::protocol::NativeRange],
) -> windows_core::Result<()> {
    let doc = field.TextDocument()?;
    // Batched unconditionally: measured 2.2x faster per range
    // (docs/probes/range-probe-windows.md, 96µs -> 44µs) and it keeps the clear
    // below from being a visible flash of undecorated text.
    doc.BatchDisplayUpdates()?;
    let painted = (|| -> windows_core::Result<()> {
        clear_highlights(field)?;
        for range in ranges {
            set_background(
                &doc.GetRange(range.start as i32, range.stop as i32)?,
                HIGHLIGHT_BACKGROUND,
            )?;
        }
        Ok(())
    })();
    // ALWAYS, even on the failure above: an unmatched BatchDisplayUpdates leaves
    // the control's rendering suspended for the rest of the process.
    doc.ApplyDisplayUpdates()?;
    painted
}

/// D2, ENFORCED WHERE THE EDIT ARRIVES. Called from the textarea's TextChanged
/// BEFORE the swallow test, so it sees every edit whatever its origin — a
/// keystroke, a paste, kaya's own write, a native undo. The compare is against
/// the recorded text, never against the event (see HIGHLIGHT_TEXT).
fn drop_stale_highlights(id: u64, field: &RichEditBox) {
    let Some(declared) = HIGHLIGHT_TEXT.with_borrow(|map| map.get(&id).cloned()) else {
        return;
    };
    let now = match Editable::Textarea(field.clone()).text() {
        Ok(text) => text,
        Err(_) => return,
    };
    if now == declared {
        return;
    }
    HIGHLIGHT_TEXT.with_borrow_mut(|map| map.remove(&id));
    if let Err(e) = clear_highlights(field) {
        eprintln!("kaya: winui could not drop a stale highlight set: {}", e.message());
    }
}

/// The painted runs the control is actually holding, in its own units.
/// THE READ GOES TO THE DOCUMENT MODEL, not to kaya's bookkeeping: delete
/// the paint and this answers `""` while HIGHLIGHT_TEXT still remembers
/// everything (the in-process peer publishes no Text pattern to read it
/// from — docs/deferred.md). A run is "painted" when its background is not
/// `AutoColor`, so a clear that wrote the WRONG colour reads as painted.
#[cfg(feature = "harness")]
fn painted_runs(field: &RichEditBox, units: i32) -> windows_core::Result<Vec<(i32, i32)>> {
    let doc = field.TextDocument()?;
    let auto = TextConstants::AutoColor()?;
    let mut runs: Vec<(i32, i32)> = Vec::new();
    let mut open: Option<i32> = None;
    for at in 0..units {
        let painted = doc
            .GetRange(at, at + 1)?
            .CharacterFormat()?
            .BackgroundColor()?
            != auto;
        match (painted, open) {
            (true, None) => open = Some(at),
            (false, Some(from)) => {
                runs.push((from, at));
                open = None;
            }
            _ => {}
        }
    }
    if let Some(from) = open {
        runs.push((from, units));
    }
    Ok(runs)
}

/// A UTF-16 code-unit offset as a UTF-8 byte offset into the same text,
/// or None when it splits a character — which can only mean something
/// handed the platform an offset the core would have refused.
#[cfg(feature = "harness")]
fn byte_offset(text: &str, utf16: i32) -> Option<usize> {
    if utf16 < 0 {
        return None;
    }
    let mut units = 0usize;
    for (byte, ch) in text.char_indices() {
        if units == utf16 as usize {
            return Some(byte);
        }
        units += ch.len_utf16();
    }
    (units == utf16 as usize).then_some(text.len())
}

/// The inverse, for the one verb that arrives carrying byte offsets:
/// `expect_revealed` asks whether a range is on screen, so the range has
/// to be in the control's unit before the control can be asked.
#[cfg(feature = "harness")]
fn utf16_offset(text: &str, byte: usize) -> Option<i32> {
    if byte > text.len() || !text.is_char_boundary(byte) {
        return None;
    }
    Some(text[..byte].encode_utf16().count() as i32)
}

/// WHERE A RANGE SITS IN THE DOCUMENT: top and bottom edge, in the
/// ScrollViewer's own units. `ITextRange::GetRect` names its option
/// `ClientCoordinates` and means DOCUMENT coordinates (measured 2026-08-06:
/// the rectangle does not move when the viewport scrolls), so a viewport
/// question combines it with the ScrollViewer's offset, while
/// `ITextRange::ScrollIntoView` does move the viewport.
#[cfg(feature = "harness")]
fn range_extent(field: &RichEditBox, start: i32, stop: i32) -> windows_core::Result<(f64, f64)> {
    let mut rect = bindings::Windows::Foundation::Rect::default();
    let mut hit = 0i32;
    field.TextDocument()?.GetRange(start, stop)?.GetRect(
        // AllowOffClient is what makes an off-screen range answerable at
        // all: without it there is no rectangle to report for one, and a
        // containment test could only ever say "visible".
        PointOptions::ClientCoordinates | PointOptions::AllowOffClient,
        &mut rect,
        &mut hit,
    )?;
    Ok((rect.Y as f64, (rect.Y + rect.Height) as f64))
}

/// The ScrollViewer inside a text control's template — the part named
/// `ContentElement`, which is what actually moves when a WinUI text
/// control scrolls.
#[cfg(feature = "harness")]
fn template_scroll(field: &RichEditBox) -> windows_core::Result<ScrollViewer> {
    fn walk(element: &UIElement) -> windows_core::Result<Option<ScrollViewer>> {
        use bindings::Microsoft::UI::Xaml::Media::VisualTreeHelper;
        if let Ok(viewer) = element.cast::<ScrollViewer>() {
            return Ok(Some(viewer));
        }
        for at in 0..VisualTreeHelper::GetChildrenCount(element)? {
            let child = VisualTreeHelper::GetChild(element, at)?;
            if let Ok(child) = child.cast::<UIElement>() {
                if let Some(found) = walk(&child)? {
                    return Ok(Some(found));
                }
            }
        }
        Ok(None)
    }
    let element: UIElement = field.cast()?;
    walk(&element)?.ok_or_else(|| {
        windows_core::Error::new(
            windows_core::HRESULT(0x8000_4005u32 as i32),
            "kaya: the textarea's template has no ScrollViewer — a text control that \
             cannot scroll cannot reveal a range (docs/ranges-plan.md D1)",
        )
    })
}

/// THE HARNESS'S COMPOSITION, THROUGH THE TEXT SERVICES FRAMEWORK.
///
/// Windows has no "insert marked text" call, so this does what a text
/// service does: focused context, edit session, composition over the caret,
/// marked text written into it. Nothing is committed — the state D4's
/// refusal exists for — and `ITfComposition` is parked in a thread-local so
/// the marked text stays marked.
#[cfg(feature = "harness")]
fn tsf_compose(text: &str) -> Result<(), String> {
    use windows::Win32::System::Com::{CLSCTX_INPROC_SERVER, CoCreateInstance};
    use windows::Win32::UI::TextServices::{
        CLSID_TF_ThreadMgr, ITfContextComposition, ITfInsertAtSelection, ITfThreadMgr,
        TF_AE_END, TF_ANCHOR_END,
        TF_CONTEXT_EDIT_CONTEXT_FLAGS, TF_ES_READWRITE, TF_ES_SYNC, TF_IAS_QUERYONLY,
        TF_SELECTION, TF_SELECTIONSTYLE,
    };
    let named = |what: &str, e: windows_core::Error| format!("{what}: {}", e.message());
    unsafe {
        // The thread manager is a per-thread singleton, so this is a handle to
        // the one WinUI's input stack already activated.
        let manager: ITfThreadMgr = CoCreateInstance(&CLSID_TF_ThreadMgr, None, CLSCTX_INPROC_SERVER)
            .map_err(|e| named("no TSF thread manager on the UI thread", e))?;
        let client = manager
            .Activate()
            .map_err(|e| named("TSF refused a client id", e))?;
        let document = manager.GetFocus().map_err(|e| {
            named(
                "TSF has no focused document (the control must hold the keyboard focus)",
                e,
            )
        })?;
        let context = document
            .GetTop()
            .map_err(|e| named("the focused document has no context", e))?;
        let composer: ITfContextComposition = context
            .cast()
            .map_err(|e| named("the context owns no compositions", e))?;
        let marked: Vec<u16> = text.encode_utf16().collect();
        let inside = context.clone();
        let session = Box::leak(Box::new(KayaEditSession {
            vtable: &KAYA_EDIT_SESSION_VTBL,
            body: RefCell::new(Some(Box::new(move |ec: u32| {
                let sink = composition_sink();
                // THE COMPOSITION RANGE COMES FROM `ITfInsertAtSelection` rather
                // than from `GetSelection`, the pattern Microsoft's own TSF
                // sample uses (Win7Samples/winui/tsf/tsfmark): a query-only
                // insert asks the TEXT STORE where text would go, which is the
                // range a composition may cover, where the selection is only
                // where the caret is.
                let inserter: ITfInsertAtSelection = inside.cast()?;
                let at = inserter.InsertTextAtSelection(ec, TF_IAS_QUERYONLY, &[])?;
                let composition = composer.StartComposition(ec, &at, &sink)?;
                let range = composition.GetRange()?;
                range.SetText(ec, 0, &marked)?;
                // A COMPOSITION PARKS THE CARET AT THE END OF ITS MARKED TEXT —
                // every platform's convention, and the number the scene asserts.
                let end = range.Clone()?;
                end.Collapse(ec, TF_ANCHOR_END)?;
                let mut moved: [TF_SELECTION; 1] = [core::mem::zeroed()];
                moved[0].range = core::mem::ManuallyDrop::new(Some(end));
                moved[0].style = TF_SELECTIONSTYLE {
                    ase: TF_AE_END,
                    fInterimChar: false.into(),
                };
                inside.SetSelection(ec, &moved)?;
                LIVE_COMPOSITION.with_borrow_mut(|slot| *slot = Some(composition));
                Ok(())
            }))),
            outcome: RefCell::new(None),
        }));
        let raw = session as *const KayaEditSession as *mut core::ffi::c_void;
        let handle =
            <windows::Win32::UI::TextServices::ITfEditSession as windows_core::Interface>::from_raw_borrowed(&raw)
                .expect("the edit session object is not null");
        // SYNCHRONOUS FIRST so the composition is live before this returns,
        // ASYNC as the fallback, keyed on the GRANT and not on the call:
        // `RequestEditSession` answers twice, so a refused sync request comes
        // back as a SUCCESSFUL call carrying a failed grant. Measured on the VM
        // 2026-08-06: the sync request is answered E_INVALIDARG (a synchronous
        // lock is the document owner's privilege), the async one is granted.
        let sync = TF_CONTEXT_EDIT_CONTEXT_FLAGS(TF_ES_SYNC.0 | TF_ES_READWRITE.0);
        let mut granted = context
            .RequestEditSession(client, handle, sync)
            .map_err(|e| named("TSF refused an edit session", e))?;
        if granted.is_err() {
            granted = context
                .RequestEditSession(client, handle, TF_ES_READWRITE)
                .map_err(|e| named("TSF refused an asynchronous edit session", e))?;
        }
        if granted.is_err() {
            return Err(format!(
                "TSF granted no edit session (sync and async both refused, {granted:?})"
            ));
        }
        match session.outcome.borrow_mut().take() {
            Some(Err(e)) => Err(named("the composition was refused", e)),
            // None means the grant was asynchronous; the caller's poll on
            // TextCompositionStarted is the report either way.
            _ => Ok(()),
        }
    }
}

/// TSF's edit session, hand-rolled — one method over `IUnknown`, and the same
/// nominal-refcount shape as `KayaOuter` above. The alternative is the
/// `implement` macro, which would add a proc-macro dependency to every kaya
/// build for one harness verb.
#[cfg(feature = "harness")]
#[repr(C)]
struct KayaEditSession {
    vtable: *const windows::Win32::UI::TextServices::ITfEditSession_Vtbl,
    /// What to do inside the write lock. Taken on the first (and only)
    /// call, so a session cannot run twice.
    #[allow(clippy::type_complexity)]
    body: RefCell<Option<Box<dyn FnOnce(u32) -> windows_core::Result<()>>>>,
    outcome: RefCell<Option<windows_core::Result<()>>>,
}

#[cfg(feature = "harness")]
static KAYA_EDIT_SESSION_VTBL: windows::Win32::UI::TextServices::ITfEditSession_Vtbl =
    windows::Win32::UI::TextServices::ITfEditSession_Vtbl {
        base__: windows_core::IUnknown_Vtbl {
            QueryInterface: edit_session_qi,
            AddRef: edit_session_addref,
            Release: edit_session_release,
        },
        DoEditSession: edit_session_do,
    };

#[cfg(feature = "harness")]
unsafe extern "system" fn edit_session_qi(
    this: *mut core::ffi::c_void,
    iid: *const windows_core::GUID,
    out: *mut *mut core::ffi::c_void,
) -> windows_core::HRESULT {
    use windows_core::Interface;
    unsafe {
        if out.is_null() {
            return windows_core::imp::E_POINTER;
        }
        let iid = &*iid;
        if *iid == windows_core::IUnknown::IID
            || *iid == <windows::Win32::UI::TextServices::ITfEditSession as Interface>::IID
        {
            *out = this;
            return windows_core::HRESULT(0);
        }
        *out = core::ptr::null_mut();
        windows_core::imp::E_NOINTERFACE
    }
}

#[cfg(feature = "harness")]
unsafe extern "system" fn edit_session_addref(_this: *mut core::ffi::c_void) -> u32 {
    2
}

#[cfg(feature = "harness")]
unsafe extern "system" fn edit_session_release(_this: *mut core::ffi::c_void) -> u32 {
    1
}

#[cfg(feature = "harness")]
unsafe extern "system" fn edit_session_do(
    this: *mut core::ffi::c_void,
    cookie: u32,
) -> windows_core::HRESULT {
    let session = unsafe { &*(this as *const KayaEditSession) };
    let body = session.body.borrow_mut().take();
    let outcome = match body {
        Some(body) => body(cookie),
        None => Ok(()),
    };
    let code = match &outcome {
        Ok(()) => windows_core::HRESULT(0),
        Err(e) => {
            // SAID HERE AND NOT AT THE CALL SITE: an ASYNCHRONOUS grant runs
            // this body long after the caller returned, so a failure the caller
            // reported would be a failure nobody ever hears about.
            eprintln!("kaya: the composition edit session failed: {}", e.message());
            e.code()
        }
    };
    *session.outcome.borrow_mut() = Some(outcome);
    code
}

/// TSF'S COMPOSITION SINK — the object a composition reports its own
/// termination to. Documented as optional, and NOT optional in practice:
/// `StartComposition` with a NULL sink answers E_INVALIDARG on this Windows
/// build (measured on the VM 2026-08-06, twice). One method beyond IUnknown,
/// and nothing to do in it.
#[cfg(feature = "harness")]
#[repr(C)]
struct KayaCompositionSink {
    vtable: *const windows::Win32::UI::TextServices::ITfCompositionSink_Vtbl,
}

#[cfg(feature = "harness")]
static KAYA_COMPOSITION_SINK_VTBL: windows::Win32::UI::TextServices::ITfCompositionSink_Vtbl =
    windows::Win32::UI::TextServices::ITfCompositionSink_Vtbl {
        base__: windows_core::IUnknown_Vtbl {
            QueryInterface: composition_sink_qi,
            AddRef: edit_session_addref,
            Release: edit_session_release,
        },
        OnCompositionTerminated: composition_sink_terminated,
    };

/// One instance, leaked: the composition outlives the call that starts
/// it, so the sink must outlive both.
#[cfg(feature = "harness")]
fn composition_sink() -> windows::Win32::UI::TextServices::ITfCompositionSink {
    let object = Box::leak(Box::new(KayaCompositionSink {
        vtable: &KAYA_COMPOSITION_SINK_VTBL,
    }));
    let raw = object as *const KayaCompositionSink as *mut core::ffi::c_void;
    // Nominal refcounts (see the vtable): taking "ownership" of a
    // reference that is never released is what this object is for.
    unsafe { windows_core::Interface::from_raw(raw) }
}

#[cfg(feature = "harness")]
unsafe extern "system" fn composition_sink_qi(
    this: *mut core::ffi::c_void,
    iid: *const windows_core::GUID,
    out: *mut *mut core::ffi::c_void,
) -> windows_core::HRESULT {
    use windows_core::Interface;
    unsafe {
        if out.is_null() {
            return windows_core::imp::E_POINTER;
        }
        let iid = &*iid;
        if *iid == windows_core::IUnknown::IID
            || *iid == <windows::Win32::UI::TextServices::ITfCompositionSink as Interface>::IID
        {
            *out = this;
            return windows_core::HRESULT(0);
        }
        *out = core::ptr::null_mut();
        windows_core::imp::E_NOINTERFACE
    }
}

#[cfg(feature = "harness")]
unsafe extern "system" fn composition_sink_terminated(
    _this: *mut core::ffi::c_void,
    _cookie: u32,
    _composition: *mut core::ffi::c_void,
) -> windows_core::HRESULT {
    // Nothing to unwind: the harness's composition lives until the process does.
    windows_core::HRESULT(0)
}

#[cfg(feature = "harness")]
thread_local! {
    /// The open composition, parked so it outlives the edit session that started
    /// it: the marked text has to stay marked for the assertion that follows.
    static LIVE_COMPOSITION: RefCell<Option<windows::Win32::UI::TextServices::ITfComposition>> =
        const { RefCell::new(None) };
}

/// A set of platform ranges in the harness's spelling:
/// `<start>:<end>=<covered text>` per range, `|`-joined, ascending.
///
/// THE COVERED TEXT IS NOT DECORATION: offsets alone would read the exact
/// inverse of the lowering's own conversion, so two symmetric mistakes would
/// cancel and the leg would pass with the wrong characters highlighted.
#[cfg(feature = "harness")]
fn range_spelling(text: &str, ranges: &[(i32, i32)]) -> String {
    let mut ranges = ranges.to_vec();
    ranges.sort_by_key(|(start, _)| *start);
    ranges
        .iter()
        .map(|&(start, stop)| {
            match (byte_offset(text, start), byte_offset(text, stop)) {
                // Named, not silently coerced: no scene will ever expect
                // this, and it says which endpoint split a character.
                (Some(from), Some(to)) => format!("{from}:{to}={}", &text[from..to]),
                _ => format!("split@{start}:{stop}="),
            }
        })
        .collect::<Vec<_>>()
        .join("|")
}

/// EPISODE BANKING (docs/undo-plan.md §3), on the way past: every user edit of
/// a text field is shown to the ledger before the occurrence goes to the app,
/// whichever way it arrived (the control's TextChanged and the harness's
/// `set_text`; the APP's writes go through `Scene::absorb_text_writes`). The
/// backend contributes the two facts only it can see — WHICH FIELD, and
/// whether it is FOCUSED. `with_borrow_mut` and not a deferred hop: a bank a
/// tick later could arrive AFTER the routing question that depends on it.
fn bank_text_changed(id: u64, text: &str) -> bool {
    CORE.with_borrow_mut(|core| {
        let Some(core) = core.as_mut() else { return false };
        bank_text_changed_on(core, id, text)
    })
}

/// The same banking with the core ALREADY BORROWED — the harness's `set_text`
/// runs inside `on_ui_mut`, where taking `CORE` again would panic on the live
/// borrow rather than bank. ONE BODY, TWO DOORS: spelled twice, the two
/// spellings drift and only one is the one a scene exercises.
fn bank_text_changed_on(core: &mut CoreState, id: u64, text: &str) -> bool {
    // A RAISE THAT CARRIES NO TEXT CHANGE IS NOT A TEXT CHANGE: a RichEditBox
    // raises TextChanged for a CHARACTER FORMAT write as readily as for a
    // keystroke, and with the app re-declaring its find set from the fold
    // that is a feedback loop (docs/traps.md: A RichEditBox raises
    // TextChanged for kaya's own paint). The compare is against what THIS
    // HANDLER LAST SAW (`banked_text`), never the core's model (§3a).
    if core.banked_text.get(&id).map(String::as_str) == Some(text) {
        return false;
    }
    // THE LEDGER HAS BEEN SHOWN THIS TEXT, whichever way the next few lines go:
    // the `type` verb's settle asks "has kaya seen it", not "which path did it
    // take".
    core.banked_text.insert(id, text.to_owned());
    // Q2's ledger-quiet bracket: this edit is the echo of a native undo THIS
    // BACKEND ROUTED, already reported by `note_native_undo`. Banking it again
    // would restate the walk's position as a new high-water and erase the walk
    // the redo side needs.
    if core.ledger_quiet.get(&id).map(String::as_str) == Some(text) {
        core.ledger_quiet.remove(&id);
        // The APP still hears it: a routed native undo is an edit like any other
        // from the guest's side (§3a); only the ledger's second look is
        // suppressed.
        return true;
    }
    let focused = focused_editable_id(core) == Some(id);
    let window = ledger_window(core);
    core.scene
        .note_text_changed(window, WidgetId(id), text, focused);
    true
}

/// A4's ONE named query — "can the focused widget undo?" — answered in this
/// platform's vocabulary and asked nowhere else in this file. D6 named four
/// hard-coded role filters as silent-failure sites; a fifth expression of this
/// question is the shape A4 exists to refuse.
fn focused_can_undo(core: &CoreState) -> bool {
    focused_editable_id(core)
        .and_then(|id| editable_by_id(core, id))
        .and_then(|field| field.can_undo().ok())
        .unwrap_or(false)
}

/// Redo's twin, same contract.
fn focused_can_redo(core: &CoreState) -> bool {
    focused_editable_id(core)
        .and_then(|id| editable_by_id(core, id))
        .and_then(|field| field.can_redo().ok())
        .unwrap_or(false)
}

/// THE LEDGER'S WINDOW, in one named place: §3's ledger is per window and this
/// backend keeps no widget-to-window map, so the assumption is stated ONCE —
/// typing in an auxiliary window banks into the primary's ledger — and this
/// is the single site that changes when aux windows grow one.
fn ledger_window(_core: &CoreState) -> WindowId {
    WindowId(0)
}

/// Where an undo would go RIGHT NOW.
///
/// ASKED ONCE AND USED TWICE — enablement and activation are the same question
/// (docs/undo-plan.md D6), and `Nothing` IS what a disabled Edit>Undo means.
fn undo_route(core: &CoreState) -> crate::scene::UndoRoute {
    core.scene.route_undo(
        ledger_window(core),
        focused_editable_id(core).map(WidgetId),
        focused_can_undo(core),
    )
}

/// Redo's twin. On the frontier episode redo stays NATIVE while the episode is
/// partly undone — the platform still holds those steps, and taking them back
/// coarsely would throw away granularity the user can see.
fn redo_route(core: &CoreState) -> crate::scene::UndoRoute {
    core.scene.route_redo(
        ledger_window(core),
        focused_editable_id(core).map(WidgetId),
        focused_can_redo(core),
    )
}

/// Whether a role's command can act right now; a non-role item answers true and
/// pays nothing. Paste is the INTERSECTION of what the clipboard offers and what
/// the focused widget accepts — a widget that declared NOTHING still pastes.
/// Cut and copy need a focused editable. Undo and redo ask the ROUTE, which is
/// the same call their activation makes, so the two cannot drift (A4).
fn role_enabled(core: &CoreState, role: &str) -> bool {
    match role {
        "undo" => undo_route(core) != crate::scene::UndoRoute::Nothing,
        "redo" => redo_route(core) != crate::scene::UndoRoute::Nothing,
        "cut" | "copy" => focused_editable_id(core).is_some(),
        "paste" => {
            let Some(id) = focused_editable_id(core) else {
                return false;
            };
            let accepts = core.accepts.get(&id).cloned().unwrap_or_default();
            if accepts.is_empty() {
                return clip_available(CF_UNICODETEXT);
            }
            let (kinds, custom) = crate::wire::parse_accept_list(&accepts);
            custom.iter().any(|id| clip_available(clip_register(id)))
                || (kinds & crate::wire::CLIP_FILES != 0 && clip_available(CF_HDROP))
                || (kinds & crate::wire::CLIP_IMAGE != 0 && clip_available(clip_register("PNG")))
                || (kinds & crate::wire::CLIP_HTML != 0
                    && clip_available(clip_register("HTML Format")))
                || (kinds & crate::wire::CLIP_TEXT != 0 && clip_available(CF_UNICODETEXT))
        }
        _ => true,
    }
}

/// Recompute the role items' enablement onto the REAL chrome
/// (docs/clipboard-plan.md §3): enablement is the intersection of what the
/// clipboard offers and what the focused widget accepts, so this runs
/// wherever it can change hands, and before a harness activation OR READ.
/// The role set is one of D6's four recorded silent-failure sites
/// (tools/check-roles.py): it must name every gesture role in MENU_ROLES.
fn refresh_role_enablement(core: &CoreState) {
    for (&id, model) in &core.menu_models {
        if !matches!(model.role.as_str(), "cut" | "copy" | "paste" | "undo" | "redo") {
            continue;
        }
        let on = menu_effective_enabled(core, id) && role_enabled(core, model.role.as_str());
        for ((_, native_id), native) in &core.menu_natives {
            if *native_id == id {
                let _ = native.set_enabled(on);
            }
        }
        // ONE ITEM, TWO CHROME VIEWS: a promoted role item has a toolbar button
        // as well as a menu row, and the role factor moves with no catalog
        // traffic at all, so a button left out of this loop would keep the
        // enablement the last REBUILD stamped on it.
        for ((_, button_id), button) in &core.toolbar_buttons {
            if *button_id == id {
                let _ = button.SetIsEnabled(on);
            }
        }
    }
}

/// Perform an UNDO role. Answers whether it WAS one, so a clipboard role and
/// then a plain action fall through behind it. Split from the clipboard
/// perform on purpose, and tools/check-roles.py reads the UNION of this
/// file's `perform_*_role` functions. THIS IS ALSO WHERE THE CHORD LANDS:
/// kaya's thread-scoped keyboard hook STEALS Ctrl+Z from a focused TextBox
/// once `MenuRole::Undo` carries the chord (§1.1), so the routing cannot sit
/// beside the dispatch — it has to BE the dispatch.
fn perform_undo_role(core: &mut CoreState, role: &str) -> bool {
    match role {
        "undo" => {
            match undo_route(core) {
                crate::scene::UndoRoute::Native => native_walk(core, false),
                crate::scene::UndoRoute::Core => core_walk(core, false),
                // Inert: enablement IS this route (role_enabled), recomputed live.
                crate::scene::UndoRoute::Nothing => {}
            }
            true
        }
        "redo" => {
            match redo_route(core) {
                crate::scene::UndoRoute::Native => native_walk(core, true),
                crate::scene::UndoRoute::Core => core_walk(core, true),
                crate::scene::UndoRoute::Nothing => {}
            }
            true
        }
        _ => false,
    }
}

/// How many native records ONE Edit>Undo may spend looking for the text to move
/// (`native_walk`). A BOUND AND NOT A `while`: the walk runs on the UI thread,
/// so a stack that never satisfies the condition has to stop and SAY SO rather
/// than spin the window into a hang.
const NATIVE_WALK_LIMIT: usize = 64;

/// THE NATIVE TIER, and THE RECONCILIATION SAMPLE with it (docs/undo-plan.md
/// §3). MEASURED here: the text and `CanUndo` read the instant `Undo()`
/// returns are already final, so the sample is synchronous, unlike macOS.
/// §3a's question is answered "yes", so this does NOT report the text change
/// — `TextBox.Undo()` raises TextChanged 7ms later and `ledger_quiet` absorbs
/// it. `CanUndo` IN BOTH DIRECTIONS: the core's test for a coalesced episode.
fn native_walk(core: &mut CoreState, redo: bool) {
    // NO FOCUSED EDITABLE, NO WALK: a missing field must not read as the empty
    // string, which would wipe the episode through the sample.
    let Some(id) = focused_editable_id(core) else {
        return;
    };
    let Some(field) = editable_by_id(core, id) else {
        return;
    };
    // ONE Edit>Undo IS ONE TEXT STEP, and this control's stack holds records
    // that move no text at all: Rich Edit records a CharacterFormat write like
    // any other, so kaya's own paint sits on top of the user's typing —
    // measured 2026-08-10, `Undo()` returned with the text byte-identical and
    // `CanUndo` still true. So the walk spends records until the text moves.
    let start = lf(field.text().unwrap_or_default());
    let mut called: windows_core::Result<()>;
    let mut spent = 0usize;
    loop {
        called = if redo { field.redo() } else { field.undo() };
        spent += 1;
        if called.is_err() || lf(field.text().unwrap_or_default()) != start {
            break;
        }
        // The text has not moved and the stack has nothing left to spend: the
        // episode is exhausted, which `note_native_undo` finishes coarsely.
        let more = if redo { field.can_redo() } else { field.can_undo() };
        if !more.unwrap_or(false) {
            break;
        }
        if spent >= NATIVE_WALK_LIMIT {
            eprintln!(
                "kaya: winui native {} spent {NATIVE_WALK_LIMIT} records without \
                 the text moving — the control's stack is holding more \
                 non-text records than any paint this backend makes, so the \
                 walk stops here rather than spinning on the UI thread",
                if redo { "redo" } else { "undo" }
            );
            break;
        }
    }
    if let Err(e) = called {
        eprintln!("kaya: winui native {} failed: {}", if redo { "redo" } else { "undo" }, e.message());
        return;
    }
    let text = lf(field.text().unwrap_or_default());
    let can_undo = field.can_undo().unwrap_or(false);
    // The bracket goes in BEFORE anything can arrive (the raise is a
    // runloop turn away, but the order is not this code's to assume).
    core.ledger_quiet.insert(id, text.clone());
    let window = ledger_window(core);
    let fallback = core.scene.note_native_undo(window, WidgetId(id), &text, can_undo);
    // Usually nothing comes back — the walk already happened in the widget. The
    // exception is the exhausted-mid-episode case above.
    if let Some((ops, occurrence)) = fallback {
        deliver_undo(core, ops, occurrence);
    }
}

/// THE CORE TIER: routing cases 2 and 3 (§3) — the ledger's newest entry
/// is a group, or an episode that is no longer frontier-live, and the
/// core applies the inverse itself.
fn core_walk(core: &mut CoreState, redo: bool) {
    let window = ledger_window(core);
    let answer = if redo {
        core.scene.redo(window)
    } else {
        core.scene.undo(window)
    };
    if let Some((ops, occurrence)) = answer {
        deliver_undo(core, ops, occurrence);
    }
}

/// The restore, then the report — IN THAT ORDER, the same rule capi.rs's
/// `with_undo_scene` states: the app's reacting transaction must not overtake
/// the restore.
fn deliver_undo(core: &mut CoreState, ops: Vec<ApplyOp>, occurrence: Occurrence) {
    // THE TWIN of drain_transactions' guard, and it needs its own: this is
    // reached from a menu click and from an accelerator, both XAML callbacks that
    // cannot unwind (docs/deferred.md).
    let applied = crate::fault::guard("applying an undo op", || {
        for op in ops {
            let what = op_head(&op);
            if let Err(e) = apply(core, op) {
                crate::fault::report(format!("kaya: applying undo op {what} failed: {e}"));
                let _ = flush_tracks(core);
                return false;
            }
        }
        // THE UNDO'S OWN BATCH BOUNDARY: the restamp an undo marked
        // (winui/order.rs) has to land before the occurrence below tells the app
        // its model is back.
        if let Err(e) = flush_tracks(core) {
            crate::fault::report(format!("kaya: restamping an undo's container tracks failed: {e}"));
            return false;
        }
        true
    });
    if applied != Some(true) {
        // A HALF-RESTORED WINDOW REPORTS NOTHING: the occurrence would
        // tell the app its model was put back, which is now untrue.
        return;
    }
    // The chrome an undo restored may have changed what the roles can do, and the
    // item that fired is about to be asked again.
    if core.roles_armed {
        refresh_role_enablement(core);
    }
    core.occurrences.send(occurrence);
}

/// Perform a clipboard role on the focused widget. Answers whether it WAS one,
/// so a plain action falls through to its own dispatch. THE PASTE SPLIT
/// (DESIGN.md): a widget that DECLARED what it accepts takes the content
/// itself, while one that declared nothing gets the platform's insertion and
/// its ordinary change path reports it. The swallow counter is NOT bumped
/// for that insertion: a paste acts like the user.
fn perform_clipboard_role(core: &mut CoreState, role: &str) -> bool {
    match role {
        "cut" | "copy" => {
            if let Some(field) = focused_editable_id(core).and_then(|id| editable_by_id(core, id))
            {
                let _ = if role == "cut" {
                    field.cut_selection_to_clipboard()
                } else {
                    field.copy_selection_to_clipboard()
                };
            }
            true
        }
        "paste" => {
            let Some(id) = focused_editable_id(core) else {
                return true;
            };
            let accepts = core.accepts.get(&id).cloned().unwrap_or_default();
            if accepts.is_empty() {
                if let Some(field) = editable_by_id(core, id) {
                    let _ = field.paste_from_clipboard();
                }
                return true;
            }
            let clip = match materialize_clipboard(&accepts) {
                Ok(Some(clip)) => clip,
                // A paste that delivered nothing is not an occurrence.
                _ => return true,
            };
            let tag = core
                .entry_tags
                .get(&id)
                .cloned()
                .unwrap_or_else(|| crate::wire::click_tag(id, &[]));
            let occurrence = match crate::wire::decode_click_tag(&tag) {
                Occurrence::ButtonClicked { id } => Occurrence::Pasted { id, clip },
                Occurrence::InstanceButtonClicked { node, path } => {
                    Occurrence::InstancePasted { node, path, clip }
                }
                other => panic!(
                    "kaya: a paste tag decoded to {other:?}, which is not a widget identity"
                ),
            };
            core.occurrences.send(occurrence);
            true
        }
        _ => false,
    }
}

/// THE BRAND ACCENT, AS A THEME DICTIONARY OF STOPS (docs/styling-plan.md D1).
/// NOT `SystemAccentColor`, which no control fill reads
/// (microsoft-ui-xaml#6394): Fluent reads the DERIVED stops, CROSSED — the
/// LIGHT theme reads the DARK ones (tools/check-accent.py holds the six).
/// Never HighContrast, where the framework re-points every accent brush at
/// `SystemColor*`. Markup, because `windows-core` boxes no value types.
fn brand_dictionary(accent: &crate::brand::BrandAccent) -> String {
    // THE MAPPING, stop by stop, paired by CONSUMER and never by position in a
    // ramp:
    //
    //   Light dictionary (what the LIGHT theme reads — the Dark stops):
    //     Dark1 <- light.fill       AccentFillColorDefault/Secondary/Tertiary
    //                               plus AccentTextFillColorTertiary.
    //     Dark2 <- light.standalone AccentTextFillColorPrimary.
    //     Dark3 <- light.hover      AccentTextFillColorSecondary.
    //
    //   Dark dictionary (what the DARK theme reads — the Light stops):
    //     Light2 <- dark.fill       the same fill family, plus
    //                               SystemFillColorAttention.
    //     Light3 <- dark.standalone AccentTextFillColorPrimary AND Secondary.
    //     Light1 <- dark.hover      NOTHING in the framework's dictionary reads
    //                               Light1; it is written because a HALF-
    //                               overridden ramp paints the USER's accent
    //                               beside kaya's brand in any consumer this
    //                               table has not enumerated.
    //
    // `on_fill` reaches no stop: Fluent hard-codes the accent foreground
    // (#FFFFFF under Light, #000000 under Default). Nor does `pressed`: this
    // platform derives its pressed fill as the fill stop at 0.8.
    let hex = |rgb: u32| format!("#FF{rgb:06X}");
    format!(
        "<ResourceDictionary xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" \
           xmlns:x=\"http://schemas.microsoft.com/winfx/2006/xaml\">\
           <ResourceDictionary.ThemeDictionaries>\
             <ResourceDictionary x:Key=\"Light\">\
               <Color x:Key=\"SystemAccentColorDark1\">{}</Color>\
               <Color x:Key=\"SystemAccentColorDark2\">{}</Color>\
               <Color x:Key=\"SystemAccentColorDark3\">{}</Color>\
             </ResourceDictionary>\
             <ResourceDictionary x:Key=\"Dark\">\
               <Color x:Key=\"SystemAccentColorLight2\">{}</Color>\
               <Color x:Key=\"SystemAccentColorLight3\">{}</Color>\
               <Color x:Key=\"SystemAccentColorLight1\">{}</Color>\
             </ResourceDictionary>\
           </ResourceDictionary.ThemeDictionaries>\
         </ResourceDictionary>",
        hex(accent.light.fill),
        hex(accent.light.standalone),
        hex(accent.light.hover),
        hex(accent.dark.fill),
        hex(accent.dark.standalone),
        hex(accent.dark.hover),
    )
}

/// Merge the brand dictionary into the application's resources.
///
/// APPENDED LAST: merged dictionaries are searched in REVERSE order, so
/// kaya's entry must go in after `XamlControlsResources`. ONCE, BEFORE ANY
/// WIDGET EXISTS: changing a resource VALUE at runtime does NOT refresh a
/// WinUI tree, so a brand that arrived late would need a visible re-theme.
fn apply_brand(accent: &crate::brand::BrandAccent) -> windows_core::Result<()> {
    let markup = brand_dictionary(accent);
    let loaded = match bindings::Microsoft::UI::Xaml::Markup::XamlReader::Load(&HSTRING::from(
        markup.as_str(),
    )) {
        Ok(loaded) => loaded,
        Err(e) => panic!(
            "kaya: winui: the brand accent's resource dictionary did not parse: {}. \
             That markup is kaya's own fixed text with six colour literals in it, so \
             a parse failure is the XAML reader refusing to run in this process rather \
             than a malformed document — the same class as the ms-appx resolution that \
             already costs this backend XamlControlsResources in dll-hosted guests \
             (require_control_resources). kaya refuses here rather than shipping an \
             unbranded window, which is the silent no-op the whole stop route exists \
             to avoid.",
            e.message()
        ),
    };
    let dictionary: bindings::Microsoft::UI::Xaml::ResourceDictionary = loaded.cast()?;
    APP.with_borrow(|app| {
        // No `if let Some` fallback here, deliberately: an absent Application
        // would make this a silently unbranded app. Ops are applied on the UI
        // thread, which is the thread `setup` puts the Application in.
        let app = app
            .as_ref()
            .expect("apply runs on the UI thread, where the Application lives");
        app.Resources()?.MergedDictionaries()?.Append(&dictionary)
    })
}

/// One theme resource, by key. `Application.Current.Resources` is the lookup
/// ROOT: the application dictionary, then the merged ones in reverse order, then
/// their theme dictionaries.
fn theme_resource<T: windows_core::Interface>(key: &str) -> windows_core::Result<T> {
    APP.with_borrow(|app| {
        let app = app
            .as_ref()
            .expect("the role lowering runs on the UI thread, where APP lives");
        app.Resources()?
            .Lookup(&PropertyValue::CreateString(&HSTRING::from(key))?)?
            .cast()
    })
}

// ---------------------------------------------------------------------
// THE BRAND TYPEFACE (docs/styling-plan.md Slice 2b). Measured mechanics:
// docs/styling/typeface-winui.md and typeface-winui-arm.md.
// ---------------------------------------------------------------------

// The brand typeface's `FontFamily` SOURCE for this process, or `None` for a
// brandless app. A SOURCE STRING RATHER THAN A FAMILY NAME, because XAML's
// grammar here is wider than a name: a comma-separated FALLBACK LIST is one
// spelling and `<path>#<family>` names a face that is not installed at all
// (`register_font_blob`). Thread-local and not a `CoreState` field: widgets
// are built on the UI thread inside `apply`, where `CoreState` is borrowed.
thread_local! {
    static BRAND_TYPEFACE: RefCell<Option<String>> = const { RefCell::new(None) };
}

fn brand_typeface() -> Option<String> {
    BRAND_TYPEFACE.with_borrow(|source| source.clone())
}

/// Every `TextBlock` this backend makes — and the only place one is made.
/// THE PAIR THAT CANNOT SPLIT (docs/styling/typeface-winui.md): a plain kaya
/// label is a bare TextBlock with no implicit style at all (measured), and
/// every step of the Fluent type ramp is `BasedOn` `BaseTextBlockStyle`,
/// which hard-codes `XamlAutoFontFamily`. So the write sits in the
/// constructor, where a LOCAL value outranks a Style setter.
fn text_block() -> windows_core::Result<TextBlock> {
    let block = TextBlock::new()?;
    // TEXT WRAPS (the 2026-08-29 ruling), which on this platform means saying so:
    // a TextBlock's own default is `NoWrap`, where SwiftUI and Compose wrap by
    // construction, so a long label would force its container wider than the
    // window. The enum needed the bindgen filter to name it before there was a
    // setter to call at all (tools/winui-bindgen/src/main.rs).
    block.SetTextWrapping(TextWrapping::Wrap)?;
    if let Some(source) = brand_typeface() {
        block.SetFontFamily(&FontFamily::CreateInstanceWithName(&HSTRING::from(source))?)?;
    }
    Ok(block)
}

/// The app-level dictionary that re-points the CONTROL ramp: four keys, and a
/// fifth that must NEVER join them. `XamlAutoFontFamily` reaches Fluent's
/// controls through `ContentControlThemeFontFamily`, a `{ThemeResource}` and
/// so re-resolved against the lookup chain. **`SymbolThemeFontFamily` is NOT
/// here and may never be** — it is the icon glyph family, and sweeping "every
/// FontFamily resource" turns every icon in the app into a box
/// (docs/styling/typeface-winui-arm.md §6).
fn typeface_dictionary(source: &str) -> String {
    // XML-escaped: a family name is app data, and `&` or `<` in one would be a
    // parse failure in kaya's own markup rather than a bad request.
    let escaped = source
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;");
    format!(
        "<ResourceDictionary xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" \
           xmlns:x=\"http://schemas.microsoft.com/winfx/2006/xaml\">\
           <FontFamily x:Key=\"ContentControlThemeFontFamily\">{escaped}</FontFamily>\
           <FontFamily x:Key=\"KeyTipFontFamily\">{escaped}</FontFamily>\
           <FontFamily x:Key=\"PivotHeaderItemFontFamily\">{escaped}</FontFamily>\
           <FontFamily x:Key=\"PivotTitleFontFamily\">{escaped}</FontFamily>\
         </ResourceDictionary>"
    )
}

/// A font BLOB, made nameable to XAML, and every part of it measured: an
/// absolute path, a `file:///` URI and `AddFontResourceExW` all render the
/// fallback with no error anywhere. WHAT WORKS is a file under the APP ROOT
/// by an app-relative or `ms-appx:///` path, with the family name read OUT OF
/// THE BYTES by DirectWrite. Two limits in docs/deferred.md: a writable app
/// directory, and a DLL-hosted guest's `current_exe`
/// (docs/styling/typeface-winui-arm.md §3).
#[allow(dead_code)] // reachable only through a guest that ships font bytes
fn register_font_blob(bytes: &[u8]) -> Result<String, String> {
    // NAMED BY CONTENT, not by process: two guests running side by side on one
    // desktop (the lane runs four) that ship the same font write the same bytes
    // to the same path, and two that ship different fonts cannot collide.
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        hash ^= u64::from(*b);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    let root = app_root()?.join(FONT_DIR);
    std::fs::create_dir_all(&root)
        .map_err(|e| format!("{} could not be created: {e}", root.display()))?;
    let name = format!("brand-{hash:016x}.ttf");
    let path = root.join(&name);
    // Skipped when the bytes on disk are already the bytes asked for:
    // Windows refuses to overwrite a MAPPED font file, os error 1224
    // (docs/traps.md: A per-app font is never in the system font
    // collection — "The second half: Windows will not overwrite a
    // MAPPED file").
    if std::fs::read(&path).map(|there| there == bytes).unwrap_or(false) {
        // Nothing to do: the bytes on disk are the bytes asked for.
    } else {
        std::fs::write(&path, bytes)
            .map_err(|e| format!("{} could not be written: {e}", path.display()))?;
    }
    let family = font_file_family(&path).map_err(|why| {
        format!(
            "{}: {why} (from the {} bytes the guest shipped)",
            path.display(),
            bytes.len()
        )
    })?;
    // `ms-appx:///` is what XAML resolves; the absolute path this
    // function just wrote to is what it silently ignores.
    Ok(format!("ms-appx:///{FONT_DIR}/{name}#{family}"))
}

/// The one directory `register_font_blob` writes into, and therefore the
/// one segment the source it hands back names.
const FONT_DIR: &str = "kaya-fonts";

/// The directory an UNPACKAGED app's `ms-appx:///` namespace resolves
/// to: the one holding this process's executable — for the dll-hosted
/// guests (python, go, csharp, java) that is the HOST interpreter's
/// directory, which is where XAML looks for that process too.
fn app_root() -> Result<std::path::PathBuf, String> {
    let exe = std::env::current_exe()
        .map_err(|e| format!("this process cannot name its own executable: {e}"))?;
    Ok(exe
        .parent()
        .ok_or_else(|| format!("{} has no directory", exe.display()))?
        .to_path_buf())
}

/// The family a font FILE declares, read out of its own name table.
///
/// DirectWrite reports what the face says it is; the request never gets
/// a vote (docs/styling/typeface-winui-arm.md §1).
fn font_file_family(path: &std::path::Path) -> Result<String, String> {
    use windows::Win32::Graphics::DirectWrite::*;
    let wide: Vec<u16> = path
        .to_string_lossy()
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    unsafe {
        let factory: IDWriteFactory = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED)
            .map_err(|e| format!("DirectWrite did not start: {}", e.message()))?;
        let file = factory
            .CreateFontFileReference(windows_core::PCWSTR(wide.as_ptr()), None)
            .map_err(|e| format!("DirectWrite would not open it: {}", e.message()))?;
        let mut supported = windows_core::BOOL(0);
        let mut face_type = DWRITE_FONT_FACE_TYPE_UNKNOWN;
        let mut file_type = DWRITE_FONT_FILE_TYPE_UNKNOWN;
        let mut faces = 0u32;
        file.Analyze(&mut supported, &mut file_type, Some(&mut face_type), &mut faces)
            .map_err(|e| format!("DirectWrite could not analyze it: {}", e.message()))?;
        if !supported.as_bool() {
            return Err(format!(
                "it is not a font DirectWrite can read (file type {})",
                file_type.0
            ));
        }
        let face = factory
            .CreateFontFace(face_type, &[Some(file)], 0, DWRITE_FONT_SIMULATIONS_NONE)
            .map_err(|e| format!("the font face would not open: {}", e.message()))?;
        let face3: IDWriteFontFace3 = face
            .cast()
            .map_err(|e| format!("the face declares no family names: {}", e.message()))?;
        localized_string(
            &face3
                .GetFamilyNames()
                .map_err(|e| format!("the face's family names would not read: {}", e.message()))?,
        )
        .map_err(|e| format!("the face's family name would not decode: {}", e.message()))
    }
}

/// One `IDWriteLocalizedStrings`, in en-us where it has one.
#[allow(dead_code)] // with register_font_blob and the harness read
fn localized_string(
    names: &windows::Win32::Graphics::DirectWrite::IDWriteLocalizedStrings,
) -> windows_core::Result<String> {
    unsafe {
        let mut index = 0u32;
        let mut exists = windows_core::BOOL(0);
        let en: Vec<u16> = "en-us".encode_utf16().chain(std::iter::once(0)).collect();
        names.FindLocaleName(windows_core::PCWSTR(en.as_ptr()), &mut index, &mut exists)?;
        if !exists.as_bool() {
            index = 0;
        }
        let len = names.GetStringLength(index)? as usize;
        let mut buf = vec![0u16; len + 1];
        names.GetString(index, &mut buf)?;
        Ok(String::from_utf16_lossy(&buf[..len]))
    }
}

/// Apply the brand typeface: the control ramp by resource, every
/// TextBlock by construction.
///
/// ONCE, BEFORE ANY WIDGET EXISTS: changing a resource VALUE at runtime
/// does not re-theme a live WinUI tree (`apply_brand`).
fn apply_typeface(req: &crate::protocol::TypefaceRequest) -> windows_core::Result<()> {
    let family = req.family_for(crate::wire::this_platform());
    let source = match &req.font {
        Some(blob) => match register_font_blob(&blob.0) {
            Ok(source) => source,
            // Panics rather than falling through to the family NAME,
            // which would render as the platform default — silently.
            Err(why) => panic!(
                "kaya: winui: the brand typeface's font bytes could not be registered: {why}"
            ),
        },
        None => family.to_owned(),
    };
    BRAND_TYPEFACE.with_borrow_mut(|slot| *slot = Some(source.clone()));
    let markup = typeface_dictionary(&source);
    let loaded = match bindings::Microsoft::UI::Xaml::Markup::XamlReader::Load(&HSTRING::from(
        markup.as_str(),
    )) {
        Ok(loaded) => loaded,
        Err(e) => panic!(
            "kaya: winui: the brand typeface's resource dictionary did not parse: {}. \
             The family is XML-escaped before it goes in, so a parse failure is the \
             XAML reader refusing to run in this process rather than a malformed \
             document — the same class as the ms-appx resolution that already costs \
             this backend XamlControlsResources in dll-hosted guests \
             (require_control_resources).",
            e.message()
        ),
    };
    let dictionary: bindings::Microsoft::UI::Xaml::ResourceDictionary = loaded.cast()?;
    APP.with_borrow(|app| {
        let app = app
            .as_ref()
            .expect("apply runs on the UI thread, where the Application lives");
        app.Resources()?.MergedDictionaries()?.Append(&dictionary)
    })
}

/// A family name no machine can have: whatever XAML lays this out in IS
/// the fallback, measured rather than named.
#[cfg(feature = "harness")]
const TYPEFACE_ABSENT: &str = "KayaNoSuchFamily-9x";

/// The pinned string every fingerprint lays out — ascenders, descenders
/// and a wide/narrow pair, so a serif and a sans cannot collide by
/// accident, at 24pt because the discrimination scales with the size.
#[cfg(feature = "harness")]
const TYPEFACE_PROBE_TEXT: &str = "Hxg Wi1lIm";

/// A XAML `FontFamily` source, split into the FILE it points into, if it
/// points into one, and the family it names. The grammar has three forms
/// and only one is a bare name: `path#Family` points into a file (the
/// blob route), and a comma-separated list is a fallback chain whose
/// FIRST entry is the one a reader means.
#[cfg(feature = "harness")]
fn typeface_source_parts(source: &str) -> (Option<&str>, &str) {
    let first = source.split(',').next().unwrap_or(source);
    match first.rsplit_once('#') {
        Some((path, family)) => (Some(path), family),
        None => (None, first),
    }
}

/// The family part of a XAML `FontFamily` source.
#[cfg(feature = "harness")]
fn typeface_family_of(source: &str) -> &str {
    typeface_source_parts(source).1
}

/// What XAML's own text stack makes of one family source: the laid-out WIDTH
/// of a pinned string and the BASELINE it put under it, in 1/64ths so a float
/// never decides an equality. NOT WIDTH AND HEIGHT: `DesiredSize.Height` is
/// the LINE BOX, and a resolved family and a fallback lay the SAME glyphs out
/// in two different boxes, so a height-based fingerprint reports the fallback
/// as the face it is not (docs/styling/typeface-winui-arm.md §2).
#[cfg(feature = "harness")]
fn typeface_fingerprint(source: &str) -> windows_core::Result<(i64, i64)> {
    let block = text_block()?;
    block.SetText(&HSTRING::from(TYPEFACE_PROBE_TEXT))?;
    block.SetFontSize(24.0)?;
    let source = if source.is_empty() { TYPEFACE_ABSENT } else { source };
    block.SetFontFamily(&FontFamily::CreateInstanceWithName(&HSTRING::from(source))?)?;
    block.Measure(bindings::Windows::Foundation::Size {
        Width: f32::INFINITY,
        Height: f32::INFINITY,
    })?;
    let size = block.DesiredSize()?;
    let baseline = block.BaselineOffset()?;
    if trace_enabled() {
        eprintln!(
            "kaya: winui typeface: {source:?} w={} h={} baseline={baseline}",
            size.Width, size.Height
        );
    }
    Ok((
        (f64::from(size.Width) * 64.0).round() as i64,
        (baseline * 64.0).round() as i64,
    ))
}

/// The `FontFamily.Source` each TextBlock is ASKING FOR — the question
/// the fingerprint then settles, not the answer. For a Control it
/// reports what the implicit style resolved
/// `ContentControlThemeFontFamily` to.
#[cfg(feature = "harness")]
fn typeface_sources_of_blocks(blocks: &[TextBlock]) -> windows_core::Result<Vec<String>> {
    blocks
        .iter()
        .map(|b| Ok(b.FontFamily()?.Source()?.to_string()))
        .collect()
}

#[cfg(feature = "harness")]
fn typeface_sources_of_controls<T: windows_core::Interface>(
    controls: &[T],
) -> windows_core::Result<Vec<String>> {
    controls
        .iter()
        .map(|c| {
            let control: bindings::Microsoft::UI::Xaml::Controls::Control = c.cast()?;
            Ok(control.FontFamily()?.Source()?.to_string())
        })
        .collect()
}

/// What ONE view ended up with, said in the strongest terms its measurements
/// support and no stronger. XAML's family lookup and DirectWrite's disagree
/// (`Segoe UI Variable` is not in the system collection and XAML still lays
/// it out), so DirectWrite's presence answer is REPORTED and never the
/// verdict; the presence question follows the SOURCE (docs/traps.md: A
/// per-app font is never in the system font collection).
#[cfg(feature = "harness")]
fn typeface_resolved(
    claimed: &str,
    measured: (i64, i64),
    absent: (i64, i64),
) -> windows_core::Result<String> {
    if measured == absent {
        return typeface_fallback_family(absent);
    }
    let family = typeface_family_of(claimed);
    let availability = typeface_availability(claimed)?;
    Ok(if availability.available() {
        family.to_owned()
    } else {
        format!(
            "{family} (XAML lays it out, but it {})",
            availability.measured()
        )
    })
}

/// Whether the family a `FontFamily` source names is really available to
/// this process — measured by the route the SOURCE names, never by the
/// route that happens to have a one-call answer.
///
/// Each variant is a different thing this process went and looked at,
/// and `measured` says which one (CLAUDE.md invariant 3).
#[cfg(feature = "harness")]
enum TypefaceAvailability {
    /// A bare-name source, asked of the SYSTEM font collection, out of
    /// `families` families.
    System { installed: bool, families: u32 },
    /// A `path#family` source whose file is there and whose name table
    /// declares exactly that family.
    FileDeclares { file: String },
    /// A `path#family` source whose file this process could not read at
    /// all — gone, unreadable, or not a font.
    FileUnreadable { file: String, why: String },
    /// A `path#family` source whose file declares a DIFFERENT family:
    /// the bytes under the name are somebody else's font.
    FileDeclaresOther { file: String, declared: String },
}

#[cfg(feature = "harness")]
impl TypefaceAvailability {
    /// Is the family really available by the route its source names?
    fn available(&self) -> bool {
        match self {
            Self::System { installed, .. } => *installed,
            Self::FileDeclares { .. } => true,
            Self::FileUnreadable { .. } | Self::FileDeclaresOther { .. } => false,
        }
    }

    /// WHAT WAS MEASURED, as a clause whose subject is the family the
    /// caller has just named, so both sentence sites cannot drift apart.
    fn measured(&self) -> String {
        match self {
            Self::System { installed: true, families } => {
                format!("IS installed among this machine's {families} font families")
            }
            Self::System { installed: false, families } => {
                format!("is not one of this machine's {families} font families")
            }
            Self::FileDeclares { file } => {
                format!("is the family the per-app font file {file} declares in its own name table")
            }
            Self::FileUnreadable { file, why } => format!(
                "is asked for through a per-app font file, {file}, that could not be read: {why}"
            ),
            Self::FileDeclaresOther { file, declared } => format!(
                "is asked for through a per-app font file, {file}, that declares the family \
                 {declared} instead"
            ),
        }
    }
}

/// THE FALLEN-BACK NOTE: a brand was declared, the text system did not
/// use it, and this says which half broke. It takes the SAME
/// `TypefaceAvailability` the per-view answer takes and prints it with
/// the same vocabulary, so the two sentences cannot disagree
/// (`typeface_resolved`). `asks_for` is the family the first view is
/// really asking for.
#[cfg(feature = "harness")]
fn typeface_fallback_note(
    first: &str,
    source: &str,
    availability: &TypefaceAvailability,
    asks_for: &str,
) -> String {
    let wanted = typeface_family_of(source);
    if availability.available() {
        format!(
            "{first} ({wanted} {}, so the lowering did not reach the view — it asks for \
             {asks_for})",
            availability.measured()
        )
    } else {
        format!("{first} ({wanted} {})", availability.measured())
    }
}

/// The presence question, asked the way the source spells it. For a
/// `path#family` source this is the INVERSE of what `register_font_blob`
/// wrote, read back with the same reader that named it
/// (`font_file_family`); nothing here consults the system collection,
/// because a per-app file is definitionally not in it.
#[cfg(feature = "harness")]
fn typeface_availability(source: &str) -> windows_core::Result<TypefaceAvailability> {
    let (path, family) = typeface_source_parts(source);
    let Some(path) = path else {
        let (installed, families) = typeface_presence(family)?;
        return Ok(TypefaceAvailability::System { installed, families });
    };
    let file = match app_font_file(path) {
        Ok(file) => file,
        // An unnameable app root is a measurement too, and it is not
        // "the font is missing".
        Err(why) => {
            return Ok(TypefaceAvailability::FileUnreadable {
                file: path.to_owned(),
                why,
            })
        }
    };
    let shown = file.display().to_string();
    // Asked separately because DirectWrite cannot: its open failure says
    // the file "does not exist or is unavailable" — one sentence for two
    // states a reader would chase differently.
    if let Err(e) = std::fs::metadata(&file) {
        return Ok(TypefaceAvailability::FileUnreadable {
            file: shown,
            why: format!("it is not there: {e}"),
        });
    }
    Ok(match font_file_family(&file) {
        Err(why) => TypefaceAvailability::FileUnreadable { file: shown, why },
        Ok(declared) if declared == family => TypefaceAvailability::FileDeclares { file: shown },
        Ok(declared) => TypefaceAvailability::FileDeclaresOther {
            file: shown,
            declared,
        },
    })
}

/// The on-disk file an app-root path in a `FontFamily` source names —
/// `register_font_blob`'s write, run backwards: drop the `ms-appx://` scheme
/// and any leading separator, then join the app root, since all four
/// spellings XAML resolves are app-root-relative. An absolute path is left
/// alone (docs/styling/typeface-winui-arm.md §3).
#[cfg(feature = "harness")]
fn app_font_file(path: &str) -> Result<std::path::PathBuf, String> {
    let rest = match path.get(..10) {
        Some(scheme) if scheme.eq_ignore_ascii_case("ms-appx://") => &path[10..],
        _ => path,
    };
    let rest = rest.trim_start_matches(['/', '\\']);
    let as_given = std::path::Path::new(rest);
    if as_given.is_absolute() {
        return Ok(as_given.to_path_buf());
    }
    // Segment by segment, because the URI's separator is `/` and this
    // machine's is `\`: the reader of a failure sentence should see the
    // path they would type.
    let mut file = app_root()?;
    for segment in rest.split(['/', '\\']).filter(|s| !s.is_empty()) {
        file.push(segment);
    }
    Ok(file)
}

/// Is this family on this machine at all, and out of how many?
///
/// `IDWriteFontCollection::FindFamilyName` against the SYSTEM collection.
/// IT ANSWERS FOR BARE-NAME SOURCES ONLY (`typeface_availability`): a
/// font this process registered from bytes is not in that collection and
/// never will be.
#[cfg(feature = "harness")]
fn typeface_presence(family: &str) -> windows_core::Result<(bool, u32)> {
    use windows::Win32::Graphics::DirectWrite::*;
    unsafe {
        let factory: IDWriteFactory = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED)?;
        let mut collection: Option<IDWriteFontCollection> = None;
        factory.GetSystemFontCollection(&mut collection, true)?;
        let collection = collection.expect("S_OK carries a collection");
        let wide: Vec<u16> = family.encode_utf16().chain(std::iter::once(0)).collect();
        let mut index = 0u32;
        let mut exists = windows_core::BOOL(0);
        collection.FindFamilyName(windows_core::PCWSTR(wide.as_ptr()), &mut index, &mut exists)?;
        Ok((exists.as_bool(), collection.GetFontFamilyCount()))
    }
}

/// The name of the face an unresolvable family actually renders in — NAMED by
/// DirectWrite and CONFIRMED by XAML's own measurement. THIS NAME MAY NOT BE
/// A CONSTANT IN THIS TREE: WinUI 3's fallback family is undocumented and
/// image-dependent (microsoft-ui-xaml#10709, #9247, #8360). The confirmation
/// is the WIDTH alone: an unresolved family draws the fallback's glyphs but
/// gets a synthetic 0.9em baseline (docs/styling/typeface-winui-arm.md §2).
#[cfg(feature = "harness")]
fn typeface_fallback_family(absent: (i64, i64)) -> windows_core::Result<String> {
    let named = match typeface_directwrite_fallback() {
        Ok(name) => name,
        Err(e) => return Ok(format!("<the platform's own face; DirectWrite would not name it: {}>", e.message())),
    };
    let theirs = typeface_fingerprint(&named)?;
    if theirs.0 == absent.0 {
        Ok(named)
    } else {
        Ok(format!(
            "<the platform's own face, {} 64ths wide; DirectWrite names {named}, which XAML \
             lays out at {}>",
            absent.0, theirs.0
        ))
    }
}

/// DirectWrite's own answer: map plain Latin text with a base family
/// nothing can resolve, and ask the MAPPED FONT what family it belongs
/// to.
#[cfg(feature = "harness")]
fn typeface_directwrite_fallback() -> windows_core::Result<String> {
    use windows::Win32::Graphics::DirectWrite::*;
    unsafe {
        let factory: IDWriteFactory = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED)?;
        let mut collection: Option<IDWriteFontCollection> = None;
        factory.GetSystemFontCollection(&mut collection, true)?;
        let collection = collection.expect("S_OK carries a collection");
        let fallback = factory.cast::<IDWriteFactory2>()?.GetSystemFontFallback()?;
        let source: IDWriteTextAnalysisSource = TypefaceRun {
            text: TYPEFACE_PROBE_TEXT
                .encode_utf16()
                .chain(std::iter::once(0))
                .collect(),
            locale: "en-us".encode_utf16().chain(std::iter::once(0)).collect(),
        }
        .into();
        let base: Vec<u16> = TYPEFACE_ABSENT
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();
        let mut mapped_len = 0u32;
        let mut mapped: Option<IDWriteFont> = None;
        let mut scale = 0f32;
        fallback.MapCharacters(
            &source,
            0,
            TYPEFACE_PROBE_TEXT.encode_utf16().count() as u32,
            &collection,
            windows_core::PCWSTR(base.as_ptr()),
            DWRITE_FONT_WEIGHT_NORMAL,
            DWRITE_FONT_STYLE_NORMAL,
            DWRITE_FONT_STRETCH_NORMAL,
            &mut mapped_len,
            &mut mapped,
            &mut scale,
        )?;
        match mapped {
            Some(font) => localized_string(&font.GetFontFamily()?.GetFamilyNames()?),
            None => Err(windows_core::Error::new(
                windows_core::HRESULT(-1),
                "the system fallback mapped no font",
            )),
        }
    }
}

/// The smallest `IDWriteTextAnalysisSource` that can carry one run of
/// Latin text — what `MapCharacters` reads its input through.
#[cfg(feature = "harness")]
#[windows_core::implement(windows::Win32::Graphics::DirectWrite::IDWriteTextAnalysisSource)]
struct TypefaceRun {
    text: Vec<u16>,
    locale: Vec<u16>,
}

#[cfg(feature = "harness")]
impl windows::Win32::Graphics::DirectWrite::IDWriteTextAnalysisSource_Impl for TypefaceRun_Impl {
    fn GetTextAtPosition(
        &self,
        textposition: u32,
        textstring: *mut *mut u16,
        textlength: *mut u32,
    ) -> windows_core::Result<()> {
        // The vector carries a trailing NUL the run does not.
        let n = self.text.len() as u32 - 1;
        unsafe {
            if textposition >= n {
                *textstring = std::ptr::null_mut();
                *textlength = 0;
            } else {
                *textstring = self.text.as_ptr().add(textposition as usize) as *mut u16;
                *textlength = n - textposition;
            }
        }
        Ok(())
    }
    fn GetTextBeforePosition(
        &self,
        textposition: u32,
        textstring: *mut *mut u16,
        textlength: *mut u32,
    ) -> windows_core::Result<()> {
        unsafe {
            if textposition == 0 {
                *textstring = std::ptr::null_mut();
                *textlength = 0;
            } else {
                *textstring = self.text.as_ptr() as *mut u16;
                *textlength = textposition;
            }
        }
        Ok(())
    }
    fn GetParagraphReadingDirection(
        &self,
    ) -> windows::Win32::Graphics::DirectWrite::DWRITE_READING_DIRECTION {
        windows::Win32::Graphics::DirectWrite::DWRITE_READING_DIRECTION_LEFT_TO_RIGHT
    }
    fn GetLocaleName(
        &self,
        _textposition: u32,
        textlength: *mut u32,
        localename: *mut *mut u16,
    ) -> windows_core::Result<()> {
        unsafe {
            *textlength = self.text.len() as u32 - 1;
            *localename = self.locale.as_ptr() as *mut u16;
        }
        Ok(())
    }
    fn GetNumberSubstitution(
        &self,
        _textposition: u32,
        textlength: *mut u32,
        numbersubstitution: windows_core::OutRef<
            windows::Win32::Graphics::DirectWrite::IDWriteNumberSubstitution,
        >,
    ) -> windows_core::Result<()> {
        unsafe {
            *textlength = self.text.len() as u32 - 1;
        }
        numbersubstitution.write(None)
    }
}

/// THE BLIT (docs/canvas-plan.md §8): the core's premultiplied RGBA8 into a
/// `WriteableBitmap`'s own pixel buffer, shown at the LOGICAL size the
/// raster's scale names. THIS IS THE ONE ARM THAT SWIZZLES
/// (tools/check-canvas-blit.py): the buffer is premultiplied BGRA8 by
/// contract, which is why `expect_ink` photographs the element through XAML's
/// own renderer — a read-back here would agree with itself either way. A
/// drawing that will not decode is PRESENT AND EMPTY (tools/check-empty-child.py).
fn set_drawing(
    image: &Image,
    width: u32,
    height: u32,
    scale: f64,
    pixels: &[u8],
) -> windows_core::Result<()> {
    let count = width as usize * height as usize;
    if width == 0 || height == 0 || !scale.is_finite() || scale <= 0.0 || pixels.len() < count * 4 {
        image.SetSource(None::<&ImageSource>)?;
        return Ok(());
    }
    let bitmap = WriteableBitmap::CreateInstanceWithDimensions(width as i32, height as i32)?;
    let buffer = bitmap.PixelBuffer()?;
    if (buffer.Capacity()? as usize) < count * 4 {
        // The platform gave a smaller buffer than the dimensions it was
        // asked for: say what was measured rather than writing past it.
        eprintln!(
            "kaya: winui canvas: a {width}x{height} WriteableBitmap answered with a \
             {}-byte pixel buffer",
            buffer.Capacity()?
        );
        image.SetSource(None::<&ImageSource>)?;
        return Ok(());
    }
    let access: IBufferByteAccess = windows_core::Interface::cast(&buffer)?;
    // SAFETY: `Buffer` hands back the bitmap's own pixel store, and the
    // capacity was just checked against what is about to be written.
    unsafe {
        let dst = access.Buffer()?;
        for i in 0..count {
            let at = i * 4;
            *dst.add(at) = pixels[at + 2];
            *dst.add(at + 1) = pixels[at + 1];
            *dst.add(at + 2) = pixels[at];
            *dst.add(at + 3) = pixels[at + 3];
        }
    }
    bitmap.Invalidate()?;
    image.SetSource(&bitmap)?;
    // A WriteableBitmap's pixels are DEVICE pixels and an Image measures
    // in DIPs, so the logical size is stated here (§5 rule 2).
    let element: FrameworkElement = windows_core::Interface::cast(image)?;
    element.SetWidth(f64::from(width) / scale)?;
    element.SetHeight(f64::from(height) / scale)?;
    Ok(())
}

/// One grab of a canvas's own pixels, BGRA8 top-down.
///
/// NOT A XAML PHOTOGRAPH: `RenderTargetBitmap` renders and hands back a
/// NULL buffer under S_OK on the VM's display-only adapter
/// (docs/traps.md), so the ink read asks DWM to print the WINDOW instead.
#[cfg(feature = "harness")]
struct Grab {
    width: i32,
    height: i32,
    pixels: Vec<u8>,
}

/// A `w`x`h` 32-bit top-down DIB, whatever `draw` puts in it.
///
/// Every failure says which call failed and what it returned: a camera
/// that can fail silently is the defect docs/traps.md records.
#[cfg(feature = "harness")]
fn capture(
    w: i32,
    h: i32,
    draw: impl FnOnce(isize) -> Result<(), String>,
) -> Result<Grab, String> {
    if w < 1 || h < 1 {
        return Err(format!("a {w}x{h} grab was asked for"));
    }
    unsafe {
        let screen = GetDC(0);
        if screen == 0 {
            return Err("GetDC(NULL) answered 0, so there is no DC to build a bitmap on".to_owned());
        }
        let mem = CreateCompatibleDC(screen);
        if mem == 0 {
            ReleaseDC(0, screen);
            return Err("CreateCompatibleDC answered 0".to_owned());
        }
        let info = BitmapInfo {
            // The SIZE is the header's alone — the colour table is not
            // part of what BITMAPINFOHEADER.biSize declares.
            size: 40,
            width: w,
            // NEGATIVE, which is what makes the DIB top-down: row 0 is
            // the top one, so `sample_grab` indexes without flipping.
            height: -h,
            planes: 1,
            bit_count: 32,
            ..Default::default()
        };
        let mut bits: *mut c_void = std::ptr::null_mut();
        let dib = CreateDIBSection(mem, &info, 0, &mut bits, 0, 0);
        if dib == 0 || bits.is_null() {
            DeleteDC(mem);
            ReleaseDC(0, screen);
            return Err(format!("CreateDIBSection answered {dib} with a {bits:?} pixel pointer"));
        }
        let old = SelectObject(mem, dib);
        let drawn = draw(mem);
        // THE BITS ARE NOT THERE UNTIL THE BATCH IS: GDI queues drawing
        // into a DIB section, and reading `bits` without this returns
        // whatever the allocation happened to hold.
        GdiFlush();
        let out = drawn.map(|()| {
            let len = (w as usize) * (h as usize) * 4;
            // SAFETY: CreateDIBSection just answered with a w*h 32bpp
            // surface at `bits`, which is exactly `len` bytes.
            Grab { width: w, height: h, pixels: std::slice::from_raw_parts(bits as *const u8, len).to_vec() }
        });
        SelectObject(mem, old);
        DeleteObject(dib);
        DeleteDC(mem);
        ReleaseDC(0, screen);
        out
    }
}

/// The canvas's box, cut out of a print of the WHOLE WINDOW: `PrintWindow`
/// with `PW_RENDERFULLCONTENT` addresses the window by HWND rather than by
/// screen position, so an occluded or PARTLY OFF-SCREEN window still answers
/// — the lane tiles six legs and two slots sit below the bottom of the
/// desktop (measured 2026-08-26, docs/traps.md).
#[cfg(feature = "harness")]
fn grab_canvas(at: &Placement) -> Result<Grab, String> {
    const PW_RENDERFULLCONTENT: u32 = 2;
    let window = capture(at.win_w, at.win_h, |mem| {
        // SAFETY: a live HWND and the DIB's own DC.
        if unsafe { PrintWindow(at.hwnd, mem, PW_RENDERFULLCONTENT) } == 0 {
            return Err(format!(
                "PrintWindow(PW_RENDERFULLCONTENT) of the {}x{} window {:#x} answered 0",
                at.win_w, at.win_h, at.hwnd
            ));
        }
        Ok(())
    })?;
    crop(&window, at)
}

/// The canvas's own box out of the window's print.
#[cfg(feature = "harness")]
fn crop(window: &Grab, at: &Placement) -> Result<Grab, String> {
    if at.ox < 0 || at.oy < 0 || at.ox + at.w > window.width || at.oy + at.h > window.height {
        return Err(format!(
            "the canvas sits at {},{} {}x{} inside a {}x{} window, which does not contain it",
            at.ox, at.oy, at.w, at.h, window.width, window.height
        ));
    }
    let mut pixels = Vec::with_capacity((at.w as usize) * (at.h as usize) * 4);
    for row in 0..at.h {
        let start = ((at.oy + row) as usize * window.width as usize + at.ox as usize) * 4;
        pixels.extend_from_slice(&window.pixels[start..start + (at.w as usize) * 4]);
    }
    Ok(Grab { width: at.w, height: at.h, pixels })
}

/// The declared probe points off a grab, as `RRGGBB/RRGGBB/...`.
///
/// A GDI DIB is BGRA8 with an ignored alpha, and this platform hands
/// back the CORE'S OWN BYTES — no colour conversion anywhere on the
/// path, unlike the mac's display-profile round trip (docs/traps.md: The
/// windows ink read crosses no colour space).
#[cfg(feature = "harness")]
fn sample_grab(grab: &Grab, points: &[(f64, f64)]) -> String {
    let (w, h) = (grab.width, grab.height);
    if w < 1 || h < 1 || grab.pixels.len() < (w as usize) * (h as usize) * 4 {
        return format!("<a {w}x{h} grab carrying {} bytes>", grab.pixels.len());
    }
    points
        .iter()
        .map(|(px, py)| {
            let x = ((f64::from(w) * px / 100.0) as i32).clamp(0, w - 1) as usize;
            let y = ((f64::from(h) * py / 100.0) as i32).clamp(0, h - 1) as usize;
            let at = (y * w as usize + x) * 4;
            let p = &grab.pixels[at..at + 4];
            format!("{:02X}{:02X}{:02X}", p[2], p[1], p[0])
        })
        .collect::<Vec<_>>()
        .join("/")
}

/// Where a canvas's pixels are INSIDE THE WINDOW's outer rect, which is
/// the frame of reference `PrintWindow` answers in — and the numbers
/// that put them there, every one of which the ink read's refusals name,
/// because a wrong mapping and a dead camera answer with the same bytes.
#[cfg(feature = "harness")]
struct Placement {
    ox: i32,
    oy: i32,
    w: i32,
    h: i32,
    win_w: i32,
    win_h: i32,
    scale: f64,
    hwnd: isize,
}

/// The canvas element's box in the WINDOW's own pixels: XAML's own
/// transform to the window root, scaled by the island's density, moved
/// by where the client area sits inside the window's outer rect.
#[cfg(feature = "harness")]
fn placement(core: &CoreState, image: &Image) -> windows_core::Result<Placement> {
    let root = core.window.Content()?;
    let element: FrameworkElement = windows_core::Interface::cast(image)?;
    // THE SAME SCALE THE CORE RASTERED AT: `presentation_report` sends
    // `RasterizationScale`, so any other reading of the DPI would sample
    // the right picture at the wrong place.
    let scale = root.XamlRoot()?.RasterizationScale()?;
    let origin = windows_core::Interface::cast::<UIElement>(image)?
        .TransformToVisual(&root)?
        .TransformPoint(bindings::Windows::Foundation::Point { X: 0.0, Y: 0.0 })?;
    let native: IWindowNative = windows_core::Interface::cast(&core.window)?;
    let hwnd = native.window_handle()?;
    let mut client = Point32 { x: 0, y: 0 };
    let mut outer = Rect::default();
    // SAFETY: a live HWND with a stack POINT and a stack RECT.
    unsafe {
        ClientToScreen(hwnd, &mut client);
        GetWindowRect(hwnd, &mut outer);
    }
    Ok(Placement {
        ox: client.x - outer.left + (f64::from(origin.X) * scale).round() as i32,
        oy: client.y - outer.top + (f64::from(origin.Y) * scale).round() as i32,
        w: (element.ActualWidth()? * scale).round() as i32,
        h: (element.ActualHeight()? * scale).round() as i32,
        win_w: outer.right - outer.left,
        win_h: outer.bottom - outer.top,
        scale,
        hwnd,
    })
}

fn apply(core: &mut CoreState, op: ApplyOp) -> windows_core::Result<()> {
    // KAYA_WINUI_TRACE=1: print every op before applying it, so a
    // stowed-exception crash names its last op. The probe sets it.
    if trace_enabled() {
        eprintln!("kaya: winui apply {op:?}");
    }
    match op {
        ApplyOp::Create { id, kind, tag } => {
            let native = match kind {
                WidgetKind::Entry => {
                    // Two prerequisites, both VM-proven (2026-07-15):
                    // MRT init needs an exe-adjacent resources.pri and
                    // the built-in template's deferred theme XAML needs
                    // the composed Application's metadata provider
                    // (docs/traps.md). The minimal template keeps the
                    // widget free of chrome resources kaya doesn't ship.
                    let field = TextBox::new()?;
                    let sink = core.occurrences.clone();
                    let tag = tag.expect("entries carry a tag");
                    let handler_tag = tag.clone();
                    let bank_id = id.0;
                    let field_for_handler = field.clone();
                    let swallow =
                        std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
                    let handler_swallow = swallow.clone();
                    let handler = TextChangedEventHandler::new(move |_, _| {
                        // A programmatic write already emitted its
                        // occurrence synchronously; this late raise is
                        // its shadow. See entry_swallow.
                        if handler_swallow
                            .fetch_update(
                                std::sync::atomic::Ordering::Relaxed,
                                std::sync::atomic::Ordering::Relaxed,
                                |n| n.checked_sub(1),
                            )
                            .is_ok()
                        {
                            return Ok(());
                        }
                        let text = lf(field_for_handler.Text()?.to_string());
                        // The ledger sees it BEFORE the app does (§3),
                        // and it decides whether anything happened at
                        // all (the no-change guard there).
                        if bank_text_changed(bank_id, &text) {
                            sink.send_text_tag(&handler_tag, &text);
                        }
                        Ok(())
                    });
                    field.TextChanged(&handler)?;
                    // Paste's enablement is the offer/accepts
                    // intersection AT THE FOCUSED WIDGET; deferred a
                    // tick, because a programmatic Focus() inside apply
                    // raises this while CORE is borrowed.
                    let focus_handler = RoutedEventHandler::new(move |_, _| {
                        defer_role_refresh();
                        Ok(())
                    });
                    field.GotFocus(&focus_handler)?;
                    let blur_handler = RoutedEventHandler::new(move |_, _| {
                        defer_role_refresh();
                        Ok(())
                    });
                    field.LostFocus(&blur_handler)?;
                    core.entries.push(field.clone());
                    core.entry_ids.push(id.0);
                    core.entry_swallow.insert(id.0, swallow);
                    core.entry_tags.insert(id.0, tag);
                    NativeWidget::Entry(field)
                }
                WidgetKind::Column => {
                    // Grid and not StackPanel: a StackPanel has no
                    // per-child weight of any kind, so proportional grow
                    // is unrepresentable there. The cost is placing by
                    // attached index, which `reindex` restamps.
                    let grid = Grid::new()?;
                    // 8-unit gap between adjacent children, matching
                    // every other backend; only the stacking axis
                    // applies, since the cross axis is a single track.
                    grid.SetRowSpacing(8.0)?;
                    core.columns.push(grid.clone());
                    #[cfg(feature = "harness")]
                    core.column_ids.push(id);
                    NativeWidget::Column(grid)
                }
                WidgetKind::Row => {
                    let grid = Grid::new()?;
                    grid.SetColumnSpacing(8.0)?;
                    core.rows.push(grid.clone());
                    NativeWidget::Row(grid)
                }
                WidgetKind::Checkbox => {
                    // WinUI raises Checked/Unchecked for programmatic
                    // SetIsChecked too — the USER/programmatic split
                    // rides apply_quiet (see that field).
                    let check = CheckBox::new()?;
                    let caption = text_block()?;
                    check.SetContent(&caption)?;
                    let tag = tag.expect("checkboxes carry a tag");
                    let on_sink = core.occurrences.clone();
                    let on_tag = tag.clone();
                    let on_quiet = core.apply_quiet.clone();
                    let checked = RoutedEventHandler::new(move |_, _| {
                        if !on_quiet.load(std::sync::atomic::Ordering::Relaxed) {
                            on_sink.send_toggle_tag(&on_tag, true);
                        }
                        Ok(())
                    });
                    check.Checked(&checked)?;
                    let off_sink = core.occurrences.clone();
                    let off_tag = tag.clone();
                    let off_quiet = core.apply_quiet.clone();
                    let unchecked = RoutedEventHandler::new(move |_, _| {
                        if !off_quiet.load(std::sync::atomic::Ordering::Relaxed) {
                            off_sink.send_toggle_tag(&off_tag, false);
                        }
                        Ok(())
                    });
                    check.Unchecked(&unchecked)?;
                    core.checkboxes.push(check.clone());
                    NativeWidget::Checkbox { check, caption }
                }
                WidgetKind::Slider => {
                    // WinUI raises ValueChanged for programmatic
                    // SetValue too, which is what lets the selftest drag
                    // like a user.
                    let slider = Slider::new()?;
                    slider.SetMinimum(0.0)?;
                    slider.SetMaximum(1.0)?;
                    slider.SetStepFrequency(0.01)?;
                    slider.SetMinWidth(160.0)?;
                    let sink = core.occurrences.clone();
                    let tag = tag.expect("sliders carry a tag");
                    let quiet = core.apply_quiet.clone();
                    let handler = bindings::Microsoft::UI::Xaml::Controls::Primitives::RangeBaseValueChangedEventHandler::new(
                        move |_, args: windows_core::Ref<'_, bindings::Microsoft::UI::Xaml::Controls::Primitives::RangeBaseValueChangedEventArgs>| {
                            if quiet.load(std::sync::atomic::Ordering::Relaxed) {
                                return Ok(());
                            }
                            if let Some(args) = args.as_ref() {
                                sink.send_value_tag(&tag, args.NewValue()?);
                            }
                            Ok(())
                        },
                    );
                    slider.ValueChanged(&handler)?;
                    core.sliders.push(slider.clone());
                    NativeWidget::Slider(slider)
                }
                WidgetKind::Button => {
                    let button = Button::new()?;
                    let caption = text_block()?;
                    button.SetContent(&caption)?;
                    let click_sink = core.occurrences.clone();
                    let tag = tag.expect("buttons carry a click tag");
                    core.buttons.push(tag.clone());
                    core.button_controls.push(button.clone());
                    let handler = RoutedEventHandler::new(move |_, _| {
                        click_sink.send_click_tag(&tag);
                        Ok(())
                    });
                    button.Click(&handler)?;
                    NativeWidget::Button { button, caption }
                }
                WidgetKind::Label => {
                    let label = text_block()?;
                    core.labels.push(label.clone());
                    NativeWidget::Label(label)
                }
                WidgetKind::Scroll => {
                    let viewer = ScrollViewer::new()?;
                    viewer.SetHorizontalScrollMode(ScrollMode::Disabled)?;
                    viewer.SetHorizontalScrollBarVisibility(ScrollBarVisibility::Disabled)?;
                    viewer.SetVerticalScrollMode(ScrollMode::Enabled)?;
                    core.scrolls.push(viewer.clone());
                    NativeWidget::Scroll(viewer)
                }
                WidgetKind::Progress => {
                    // RangeBase's default span is 0..100; kaya's
                    // fraction contract is 0..=1, set explicitly.
                    let bar = ProgressBar::new()?;
                    bar.SetMinimum(0.0)?;
                    bar.SetMaximum(1.0)?;
                    core.progresses.push(bar.clone());
                    NativeWidget::Progress(bar)
                }
                WidgetKind::Textarea => {
                    // A RichEditBox with AcceptsReturn, PINNED TO PLAIN
                    // TEXT, on the entry's exact contract (the swallow
                    // counters are id-keyed and kind-agnostic).
                    // `pin_plain_text` READS ITS PINS BACK, so a deleted
                    // pin is a panic at the first textarea a scene builds.
                    let field = RichEditBox::new()?;
                    field.SetAcceptsReturn(true)?;
                    field.SetMinWidth(240.0)?;
                    // A TEXTAREA IS A VIEWPORT ONTO A DOCUMENT: an explicit
                    // height, never a MINIMUM (docs/traps.md: A WinUI
                    // textarea sized by a MINIMUM is as tall as its
                    // document). 240x96 is the third spelling of the
                    // SwiftUI and GTK arms' size.
                    field.SetHeight(96.0)?;
                    pin_plain_text(&field)?;
                    let sink = core.occurrences.clone();
                    let tag = tag.expect("textareas carry a tag");
                    let handler_tag = tag.clone();
                    let bank_id = id.0;
                    let field_for_handler = Editable::Textarea(field.clone());
                    let swallow =
                        std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
                    let handler_swallow = swallow.clone();
                    // A ROUTED HANDLER, not a TextChangedEventHandler:
                    // RichEditBox raises TextChanged as a plain routed
                    // event. Same event, same async raise, same swallow
                    // discipline.
                    let ranges_field = field.clone();
                    let handler = RoutedEventHandler::new(move |_, _| {
                        // D2 FIRST, AND ABOVE THE SWALLOW TEST
                        // (docs/ranges-plan.md D2): a clear-on-edit
                        // standing below it would leave a programmatic
                        // write painting a stale set, which on this
                        // control DRIFTS with the edit and GROWS when the
                        // user types at its edge.
                        drop_stale_highlights(bank_id, &ranges_field);
                        if handler_swallow
                            .fetch_update(
                                std::sync::atomic::Ordering::Relaxed,
                                std::sync::atomic::Ordering::Relaxed,
                                |n| n.checked_sub(1),
                            )
                            .is_ok()
                        {
                            return Ok(());
                        }
                        let text = lf(field_for_handler.text()?);
                        // The ledger sees it BEFORE the app does (§3),
                        // and THIS control is why its no-change guard
                        // exists: a CharacterFormat write raises
                        // TextChanged here, so `highlight_ranges` would
                        // otherwise report an edit the document never had.
                        if bank_text_changed(bank_id, &text) {
                            sink.send_text_tag(&handler_tag, &text);
                        }
                        Ok(())
                    });
                    field.TextChanged(&handler)?;
                    // D4'S PREMISE (docs/ranges-plan.md D4): an input
                    // method's composition is live in this control and on
                    // no kaya channel, these two events are how the
                    // control says so, and the select_range arm reads the
                    // answer. A real IME and the harness's `compose` both
                    // go through the same text store.
                    let composing_id = id.0;
                    field.TextCompositionStarted(&TypedEventHandler::<
                        RichEditBox,
                        TextCompositionStartedEventArgs,
                    >::new(move |_, _| {
                        COMPOSING.with_borrow_mut(|live| live.insert(composing_id));
                        Ok(())
                    }))?;
                    field.TextCompositionEnded(&TypedEventHandler::<
                        RichEditBox,
                        TextCompositionEndedEventArgs,
                    >::new(move |_, _| {
                        COMPOSING.with_borrow_mut(|live| live.remove(&composing_id));
                        Ok(())
                    }))?;
                    // Same focus-handoff refresh as the entry (paste
                    // enablement follows the focused editable).
                    let focus_handler = RoutedEventHandler::new(move |_, _| {
                        defer_role_refresh();
                        Ok(())
                    });
                    field.GotFocus(&focus_handler)?;
                    let blur_handler = RoutedEventHandler::new(move |_, _| {
                        defer_role_refresh();
                        Ok(())
                    });
                    field.LostFocus(&blur_handler)?;
                    core.textareas.push(field.clone());
                    core.textarea_ids.push(id.0);
                    core.entry_swallow.insert(id.0, swallow);
                    core.entry_tags.insert(id.0, tag);
                    NativeWidget::Textarea(field)
                }
                WidgetKind::Grid => {
                    let grid = Grid::new()?;
                    core.grid_children.insert(id.0, Vec::new());
                    core.grid_cols.insert(id.0, 1);
                    core.grids.push(grid.clone());
                    NativeWidget::Grid2D(grid)
                }
                WidgetKind::Radio => {
                    // RadioButtons, the platform's own group control
                    // (string items render as radio rows). Same
                    // quiet-guard stance as the ComboBox: SelectionChanged
                    // cannot tell a user pick from SetSelectedIndex.
                    let group = RadioButtons::new()?;
                    let sink = core.occurrences.clone();
                    let tag = tag.expect("radio groups carry a tag");
                    let quiet = core.apply_quiet.clone();
                    let handler = SelectionChangedEventHandler::new(
                        move |sender: windows_core::Ref<'_, windows_core::IInspectable>, _| {
                            if quiet.load(std::sync::atomic::Ordering::Relaxed) {
                                return Ok(());
                            }
                            if let Some(sender) = sender.as_ref() {
                                let group: RadioButtons =
                                    windows_core::Interface::cast(sender)?;
                                let index = group.SelectedIndex()?;
                                if index >= 0 {
                                    sink.send_value_tag(&tag, f64::from(index));
                                }
                            }
                            Ok(())
                        },
                    );
                    group.SelectionChanged(&handler)?;
                    core.radios.push(group.clone());
                    NativeWidget::Radio(group)
                }
                WidgetKind::Select => {
                    // ComboBox — the select's label children are its
                    // OPTIONS, ComboBoxItems in the popup (see AddChild).
                    // Programmatic writes ride the quiet guard because
                    // SelectionChanged cannot tell the two apart.
                    let combo = ComboBox::new()?;
                    let sink = core.occurrences.clone();
                    let tag = tag.expect("selects carry a tag");
                    let quiet = core.apply_quiet.clone();
                    let handler = SelectionChangedEventHandler::new(
                        move |sender: windows_core::Ref<'_, windows_core::IInspectable>, _| {
                            if quiet.load(std::sync::atomic::Ordering::Relaxed) {
                                return Ok(());
                            }
                            if let Some(sender) = sender.as_ref() {
                                let combo: ComboBox = windows_core::Interface::cast(sender)?;
                                let index = combo.SelectedIndex()?;
                                if index >= 0 {
                                    sink.send_value_tag(&tag, f64::from(index));
                                }
                            }
                            Ok(())
                        },
                    );
                    combo.SelectionChanged(&handler)?;
                    core.selects.push(combo.clone());
                    NativeWidget::Select(combo)
                }
                WidgetKind::Image => {
                    let image = Image::new()?;
                    core.images.push(image.clone());
                    NativeWidget::Image(image)
                }
                WidgetKind::Canvas => {
                    // The raw-pixel sibling of the arm above, filled by the
                    // SetDrawing arm from a WriteableBitmap
                    // (docs/canvas-plan.md §8). FILL, AND STRICTLY 1:1 FOR IT
                    // (§3.2.1, ruling 2): `set_drawing` gives the element an
                    // explicit Width/Height from the BUFFER's pixels, so a
                    // bigger track leaves MARGIN. Image's default Uniform
                    // would rescale a `fixed` canvas.
                    let image = Image::new()?;
                    image.SetStretch(Stretch::Fill)?;
                    // THE REPORT, on this backend's own layout edge —
                    // see `canvas_track_of` and `schedule_canvas_tracks`.
                    // LayoutUpdated rather than SizeChanged: this
                    // backend's bindings project no SizeChanged, and a
                    // grown canvas's own box does not move when the window
                    // resizes — only its slot does.
                    let laid = EventHandler::<windows_core::IInspectable>::new(move |_, _| {
                        schedule_canvas_tracks();
                        Ok(())
                    });
                    image.LayoutUpdated(&laid)?;
                    attach_frame_drive();
                    core.canvases.push(image.clone());
                    core.canvas_ids.push(id.0);
                    NativeWidget::Canvas(image)
                }
            };
            core.widgets.insert(id, native);
        }
        ApplyOp::MoveChild {
            parent,
            child,
            before,
        } => {
            use bindings::Microsoft::UI::Xaml::UIElement;
            let panel = match container_panel(core, parent) {
                Some(panel) => panel,
                None => panic!("kaya: move_child parent is not a container"),
            };
            let as_element = |core: &CoreState, id: WidgetId| -> UIElement {
                match core.widgets.get(&id).expect("scene validated the id") {
                    NativeWidget::Column(p) | NativeWidget::Row(p) => {
                        windows_core::Interface::cast(p).expect("panel is a UIElement")
                    }
                    NativeWidget::Button { button, .. } => {
                        windows_core::Interface::cast(button).expect("button is a UIElement")
                    }
                    NativeWidget::Label(label) => {
                        windows_core::Interface::cast(label).expect("label is a UIElement")
                    }
                    NativeWidget::Entry(field) => {
                        windows_core::Interface::cast(field).expect("entry is a UIElement")
                    }
                    NativeWidget::Checkbox { check, .. } => {
                        windows_core::Interface::cast(check).expect("checkbox is a UIElement")
                    }
                    NativeWidget::Slider(slider) => {
                        windows_core::Interface::cast(slider).expect("slider is a UIElement")
                    }
                    NativeWidget::Image(image) => {
                        windows_core::Interface::cast(image).expect("image is a UIElement")
                    }
                    NativeWidget::Scroll(viewer) => {
                        windows_core::Interface::cast(viewer).expect("scroll is a UIElement")
                    }
                    NativeWidget::Progress(bar) => {
                        windows_core::Interface::cast(bar).expect("progress is a UIElement")
                    }
                    NativeWidget::Select(combo) => {
                        windows_core::Interface::cast(combo).expect("select is a UIElement")
                    }
                    NativeWidget::Radio(group) => {
                        windows_core::Interface::cast(group).expect("radio is a UIElement")
                    }
                    NativeWidget::Grid2D(grid) => {
                        windows_core::Interface::cast(grid).expect("grid is a UIElement")
                    }
                    NativeWidget::Textarea(field) => {
                        windows_core::Interface::cast(field).expect("textarea is a UIElement")
                    }
                    NativeWidget::Canvas(image) => {
                        windows_core::Interface::cast(image).expect("canvas is a UIElement")
                    }
                }
            };
            let children = panel.Children()?;
            let child_elem = as_element(core, child);
            let mut at = 0u32;
            if children.IndexOf(&child_elem, &mut at)?.into() {
                children.RemoveAt(at)?;
            }
            match before {
                Some(anchor) => {
                    let anchor_elem = as_element(core, anchor);
                    let mut idx = 0u32;
                    let found: bool = children.IndexOf(&anchor_elem, &mut idx)?.into();
                    assert!(found, "kaya: move_child anchor not among siblings");
                    children.InsertAt(idx, &child_elem)?;
                }
                None => children.Append(&child_elem)?,
            }
            // On a Grid the Children collection places nothing, so
            // without the batch's restamp the move would be invisible.
            core.child_order.place(parent, child, before);
        }
        ApplyOp::Destroy { id } => {
            // A destroyed anchor takes its context attachment with it: a
            // For-row removal must not leave the harness's open-menu
            // pointer dangling. The Stage's activation keeps its own
            // flyout handle through Closed, so this is safe mid-activation.
            if core.context_roots.remove(&id.0).is_some() {
                core.context_nouns.remove(&id.0);
                core.context_flyouts.remove(&id.0);
                // The dead copy's native instances leave the map too: a
                // detached item still raises Click through its automation
                // peer, so a surviving entry would stay invoke-capable
                // with the dead row's noun.
                purge_context_natives(&mut core.menu_natives, id.0);
                if core.open_context.as_ref().is_some_and(|(w, _)| *w == id.0) {
                    core.open_context = None;
                }
            }
            let widget = core.widgets.remove(&id).expect("scene validated the id");
            core.grow.remove(&id);
            core.child_order.forget(id);
            // A destroyed table takes its header chrome with it: the
            // entry holds XAML handles and a layout callback keyed on
            // this id, and both outlive the container otherwise.
            TABLES.with_borrow_mut(|tables| tables.remove(&id.0));
            if let Some(panel) = core.parents.remove(&id) {
                let children = panel.Children()?;
                let mut index = 0u32;
                if children.IndexOf(&widget.element()?, &mut index)? {
                    children.RemoveAt(index)?;
                }
                core.child_order.detach(id);
            }
        }
        ApplyOp::SetWindowProp { window, prop, value } => {
            let target = winui_window(core, window.0)?;
            match (prop, &value) {
                (WindowProp::Title, Value::Str(title)) => {
                    // The window's OWN title, stored EXACTLY as the app
                    // wrote it: the dirty marker is composed on the way
                    // to the OS (window_caption), not stored with it
                    // (docs/dirty-plan.md D1).
                    core.window_titles.insert(window.0, title.clone());
                    refresh_caption(core, window.0)?;
                }
                (WindowProp::Inset, Value::F64(units)) => {
                    // LAYOUT, not appearance (docs/styling-plan.md D3).
                    // A pre-mount write is the normal case and the Mount
                    // arm reads the store.
                    core.inset = *units;
                    // Through container_padding and the roots the mount
                    // recorded, never straight onto the window's Content:
                    // that Padding also carries the root container's OWN
                    // inset (prop 17), and it reaches the roots Content is
                    // not — a pushed entry's and an auxiliary window's.
                    let roots: Vec<WidgetId> = core.mounted_roots.values().copied().collect();
                    for id in roots {
                        stamp_container_padding(core, id)?;
                    }
                }
                (WindowProp::Dirty, Value::Bool(on)) => {
                    // WINDOWS PUBLISHES NO MODIFIED AFFORDANCE — not in
                    // WinUI, not in the Windows App SDK metadata, not in
                    // UIA's WindowPattern (docs/dirty-plan.md), so the
                    // caption is the entire surface, composed rather than
                    // stored (D2).
                    core.window_dirty.insert(window.0, *on);
                    refresh_caption(core, window.0)?;
                }
                (WindowProp::Width, Value::F64(v)) => {
                    resize_request(&target, Some(*v), None)?
                }
                (WindowProp::Height, Value::F64(v)) => {
                    resize_request(&target, None, Some(*v))?
                }
                (WindowProp::VetoClose, Value::Bool(on)) => {
                    core.window_veto.insert(window.0, *on);
                }
                (WindowProp::Panes, Value::I64(n)) => {
                    core.panes.insert(window.0, *n);
                    refresh_nav(core, window.0)?;
                }
                (WindowProp::SectionsPresentation, Value::I64(hint)) => {
                    // ADVISORY: Left pane for auto/sidebar, Top for
                    // bar; rebuilt if the chrome already exists.
                    core.sections_presentation.insert(window.0, *hint);
                    if core.sections.contains_key(&window.0) {
                        refresh_sections(core, window.0)?;
                    }
                }
                (p, v) => unreachable!("scene validated window prop {p:?}/{v:?}"),
            }
        }
        ApplyOp::CreateWindow { window } => {
            // Materializes hidden (never Activated until a mount
            // presents it); the close grammar is installed at birth.
            let aux = Window::new()?;
            subclass(&aux, window.0)?;
            core.aux_windows.insert(window.0, aux);
            // A WINDOW BORN AFTER THE DECLARATION still belongs to the
            // same app (docs/app-identity-plan.md): identity is per-APP,
            // and this is one of the three orders these objects can
            // arrive in. A no-op when nothing was declared.
            apply_identity_to_window(core, window.0)?;
        }
        ApplyOp::DestroyWindow { window } => {
            core.window_veto.remove(&window.0);
            core.tearing_down.insert(window.0);
            if let Some(aux) = core.aux_windows.remove(&window.0) {
                // Close() on an already-chrome-closed window errors, and
                // the grammar makes destroy the reconciliation.
                let _ = aux.Close();
            }
            core.tearing_down.remove(&window.0);
            for entry in core.nav_stacks.remove(&window.0).unwrap_or_default() {
                core.nav_entries.remove(&entry);
            }
            // Its sections go too, each with ITS stack — the one way a
            // section dies.
            for sid in core.sections.remove(&window.0).unwrap_or_default() {
                core.section_panes.remove(&sid);
                core.section_items.remove(&sid);
                for entry in core.nav_stacks.remove(&sid).unwrap_or_default() {
                    core.nav_entries.remove(&entry);
                }
            }
            core.section_navs.remove(&window.0);
            core.section_swallow.remove(&window.0);
            core.ui_selected_sections.remove(&window.0);
            core.selected_sections.remove(&window.0);
            core.sections_presentation.remove(&window.0);
            core.window_roots.remove(&window.0);
            core.window_titles.remove(&window.0);
            core.window_dirty.remove(&window.0);
            // Its menu shell/catalog registration goes too; the item
            // MODELS stay, since items are never destroyed.
            core.menu_windows.remove(&window.0);
            core.menubars.remove(&window.0);
            core.menu_slots.remove(&window.0);
            core.menu_shells.remove(&window.0);
            core.toolbars.remove(&window.0);
            core.window_titlebars.remove(&window.0);
            core.window_caption_texts.remove(&window.0);
            // The centring's post-condition state (`CaptionTitleAim`)
            // lives outside CoreState because a layout callback writes
            // it, so it is dropped here by hand.
            CAPTION_TITLE_AIM.with_borrow_mut(|aims| {
                aims.remove(&window.0);
            });
            core.toolbar_buttons.retain(|(w, _), _| *w != window.0);
        }
        ApplyOp::PushEntry { window, entry } => {
            core.nav_entries.insert(
                entry.0,
                WinNavEntry {
                    window: window.0,
                    title: String::new(),
                    intercept_back: false,
                    wrapper: None,
                    back_button: None,
                },
            );
            core.nav_stacks.entry(window.0).or_default().push(entry.0);
        }
        ApplyOp::PopEntry { window } => {
            let top = core
                .nav_stacks
                .get_mut(&window.0)
                .and_then(|s| s.pop())
                .expect("scene validated the pop");
            core.nav_entries.remove(&top);
            refresh_nav(core, window.0)?;
        }
        ApplyOp::SetEntryProp { entry, prop, value } => {
            use crate::protocol::EntryProp;
            let record = core
                .nav_entries
                .get_mut(&entry.0)
                .expect("scene validated the entry id");
            match (prop, &value) {
                (EntryProp::Title, Value::Str(title)) => {
                    record.title = title.clone();
                }
                (EntryProp::InterceptBack, Value::Bool(on)) => {
                    record.intercept_back = *on;
                }
                (p, v) => unreachable!("scene validated entry prop {p:?}/{v:?}"),
            }
            let window = record.window;
            if core.nav_stacks.get(&window).and_then(|s| s.last()) == Some(&entry.0) {
                refresh_nav(core, window)?;
            }
        }
        ApplyOp::AddSection { window, section } => {
            // Append-only: a pane joins the window's NavigationView and
            // the mount fills it. First added is selected.
            let pane = Grid::new()?;
            core.section_panes.insert(
                section.0,
                WinSection {
                    window: window.0,
                    pane,
                    title: String::new(),
                    symbol: 0,
                    root: None,
                },
            );
            core.sections.entry(window.0).or_default().push(section.0);
            core.selected_sections.entry(window.0).or_insert(section.0);
            refresh_sections(core, window.0)?;
        }
        ApplyOp::SelectSection { window, section } => {
            // Programmatic and QUIET: SelectionChanged raises ASYNC, so
            // the switcher moves under the swallow counter.
            core.selected_sections.insert(window.0, section.0);
            nav_set_selected(core, window.0, section.0)?;
            show_section_pane(core, window.0, section.0)?;
        }
        ApplyOp::SetSectionProp { section, prop, value } => {
            use crate::protocol::SectionProp;
            let record = core
                .section_panes
                .get_mut(&section.0)
                .expect("scene validated the section id");
            match (prop, &value) {
                (SectionProp::Title, Value::Str(title)) => {
                    record.title = title.clone();
                    if let Some(item) = core.section_items.get(&section.0) {
                        // String content, never a UIElement child —
                        // the ComboBox content-stealing trap.
                        item.SetContent(&PropertyValue::CreateString(&HSTRING::from(
                            &*record.title,
                        ))?)?;
                    }
                }
                // Day-one slot: accepted; the switcher TITLE is the
                // harness observable.
                (SectionProp::Icon, Value::Blob(_)) => {}
                // THE SEMANTIC ICON (docs/styling-plan.md D6):
                // NavigationView's own Icon slot. Stamped onto the live
                // item when there is one; `refresh_sections` stamps the
                // ones it mints later.
                (SectionProp::Symbol, Value::I64(symbol)) => {
                    record.symbol = *symbol;
                    if let Some(item) = core.section_items.get(&section.0) {
                        apply_symbol(item, *symbol)?;
                    }
                }
                (p, v) => unreachable!("scene validated section prop {p:?}/{v:?}"),
            }
        }
        // Menus: every arm mutates the retained model and defers the
        // chrome to ONE coalesced rebuild per drain (menus_touched), which
        // starts from the post-user mirror by construction (docs/traps.md).
        ApplyOp::MenuItemCreate { item, kind } => {
            core.menu_models.insert(
                item.0,
                MenuModel {
                    kind,
                    label: String::new(),
                    enabled: true,
                    checked: false,
                    value: 0.0,
                    primary: false,
                    role: String::new(),
                    shortcut: String::new(),
                    symbol: 0,
                    children: Vec::new(),
                    parent: None,
                },
            );
            core.menus_touched = true;
        }
        ApplyOp::MenuItemAppend { parent, child } => {
            core.menu_models
                .get_mut(&child.0)
                .expect("scene validated the child item")
                .parent = Some(parent.0);
            core.menu_models
                .get_mut(&parent.0)
                .expect("scene validated the parent item")
                .children
                .push(child.0);
            core.menus_touched = true;
        }
        ApplyOp::MenubarAppend { window, item } => {
            core.menu_windows.entry(window.0).or_default().push(item.0);
            ensure_menu_shell(core, window.0)?;
            core.menus_touched = true;
        }
        ApplyOp::ContextAttach { widget, item } => {
            core.context_roots.entry(widget.0).or_default().push(item.0);
            ensure_context_flyout(core, widget.0)?;
            core.menus_touched = true;
        }
        ApplyOp::ContextAttachNode { widget, item, path } => {
            core.context_roots.entry(widget.0).or_default().push(item.0);
            // The stamped copy's key path — the noun every activation
            // from this anchor carries (the on_click_node encoding).
            core.context_nouns.insert(widget.0, path);
            ensure_context_flyout(core, widget.0)?;
            core.menus_touched = true;
        }
        ApplyOp::SetMenuProp { item, prop, value } => {
            let model = core
                .menu_models
                .get_mut(&item.0)
                .expect("scene validated the item id");
            // EXHAUSTIVE over the prop: a new MENU_PROPS row fails to
            // compile here rather than reaching a catch-all at runtime
            // — which `role` did, panicking this backend (docs/traps.md).
            match prop {
                MenuProp::Label => model.label = crate::protocol::prop_str(&value).to_owned(),
                MenuProp::Enabled => model.enabled = crate::protocol::prop_bool(&value),
                // Programmatic checked/value writes are configuration
                // and stay QUIET: the rebuild restamps the native state
                // and no Click fires on a programmatic set.
                MenuProp::Checked => model.checked = crate::protocol::prop_bool(&value),
                MenuProp::Value => model.value = crate::protocol::prop_f64(&value),
                // The phone-promotion hint, INERT on desktop by the
                // ratified design — stored, never materialized here.
                MenuProp::Primary => model.primary = crate::protocol::prop_bool(&value),
                MenuProp::Shortcut => {
                    model.shortcut = crate::protocol::prop_str(&value).to_owned();
                }
                // Native Windows menu rows carry no icon in this
                // lowering (the section Icon precedent: a day-one slot).
                MenuProp::Icon => {}
                // PLACEMENT is a request this host has nowhere to honor, so
                // the item stays where the app declared it (DESIGN.md, Menus).
                // BEHAVIOR is not: a clipboard role's activation performs the
                // standard command on the focused widget, so the role is
                // recorded and the role items resync now. The semantic icon
                // (docs/styling-plan.md D6) is drawn by the coalesced rebuild.
                MenuProp::Symbol => {
                    model.symbol = match &value {
                        Value::I64(v) => *v,
                        other => unreachable!("kaya: symbol wants I64, the root passed {other:?}"),
                    }
                }
                MenuProp::Role => {
                    model.role = crate::protocol::prop_str(&value).to_owned();
                    // AN AUTHORED ROLE IS ITSELF THE ARMING: undo's
                    // enablement moves in a scene that never touches the
                    // clipboard (see `roles_armed`).
                    core.roles_armed = true;
                    refresh_role_enablement(core);
                }
            }
            core.menus_touched = true;
        }

        ApplyOp::Copy(clip) => {
            core.roles_armed = true;
            // Five formats in ONE open, descending clip value — custom,
            // files, image, html, text — the canonical order (§1), which
            // is preference (first-set) order on this host. EmptyClipboard
            // makes this process the owner; classic SetClipboardData is
            // immediate rendering, so the content outlives the process
            // with no Flush of any kind (measured, tools/win/clipprobe).
            clip_open_retry()?;
            unsafe { windows::Win32::System::DataExchange::EmptyClipboard()? };
            let result: windows_core::Result<()> = (|| {
                for (id, bytes) in &clip.custom {
                    clip_set_bytes(clip_register(id), &bytes.0)?;
                }
                if !clip.files.is_empty() {
                    clip_set_bytes(CF_HDROP, &build_dropfiles(&clip.files))?;
                }
                if let Some(png) = &clip.image {
                    // Raw bytes under the "PNG" registered format — the
                    // Firefox/clip convention, byte-exact both ways
                    // (measured). CF_DIB is a deliberate cut: it would
                    // mean decoding the PNG here.
                    clip_set_bytes(clip_register("PNG"), &png.0)?;
                }
                if let Some(html) = &clip.html {
                    clip_set_bytes(clip_register("HTML Format"), &build_cf_html(html))?;
                }
                if let Some(text) = &clip.text {
                    clip_set_bytes(CF_UNICODETEXT, &clip_utf16z(text))?;
                }
                Ok(())
            })();
            unsafe { windows::Win32::System::DataExchange::CloseClipboard()? };
            result?;
            refresh_role_enablement(core);
        }
        ApplyOp::ReadClipboard { request, accepting } => {
            core.roles_armed = true;
            // Answered exactly once; None IS an answer — the universal
            // no (denied, absent, unfocused and nothing-accepted alike).
            let clip = materialize_clipboard(&accepting)?;
            core.occurrences.send(Occurrence::ClipboardResult { request, clip });
        }
        // A1: a core undo group committed, so the focused editable's native
        // history goes with it. THE KEYSTONE (docs/undo-plan.md §3): every
        // episode begins with an EMPTY native stack, and WinUI coalesces a
        // whole typing run into ONE native step (measured), so without the
        // clear a single Ctrl+Z would walk back past the group. Targetless
        // by design: the core does not know what is focused and this does.
        ApplyOp::ClearUndo { window } => {
            let _ = window;
            if let Some(field) = focused_editable_id(core).and_then(|id| editable_by_id(core, id)) {
                clear_native_undo(&field);
            }
        }
        // THE THREE TEXT-RANGE PRIMITIVES (docs/ranges-plan.md D1). The
        // offsets in these ops are already UTF-16 code units — the core
        // converted them against the text it validated them on — so
        // nothing below counts a character.
        ApplyOp::HighlightRanges { id, ranges } => {
            let Some(field) = textarea_by_id(core, id.0) else {
                return Ok(());
            };
            // A DECLARATION THAT CHANGES NOTHING WRITES NOTHING, and not as a
            // micro-optimization: every paint goes through `clear_highlights`,
            // a CharacterFormat write over the whole story, which RAISES
            // TextChanged and lands on the control's own undo stack — so an
            // app re-declaring from its text_changed fold paid a spurious
            // edit report and undo record per keystroke.
            let painted = HIGHLIGHT_TEXT.with_borrow(|map| map.contains_key(&id.0));
            if ranges.is_empty() && !painted {
                return Ok(());
            }
            paint_highlights(&field, &ranges)?;
            // D2's compare needs the text these offsets were validated against,
            // and the control is holding it RIGHT NOW. AN EMPTY DECLARATION
            // LEAVES NO ENTRY: one kept here would send
            // `drop_stale_highlights` into `clear_highlights` on the next
            // keystroke.
            HIGHLIGHT_TEXT.with_borrow_mut(|map| {
                if ranges.is_empty() {
                    map.remove(&id.0);
                } else {
                    map.insert(
                        id.0,
                        Editable::Textarea(field.clone()).text().unwrap_or_default(),
                    );
                }
            });
        }
        ApplyOp::SelectRange { id, range } => {
            let Some(field) = textarea_by_id(core, id.0) else {
                return Ok(());
            };
            // D4, AND THIS BACKEND IS THE ONLY PARTY THAT CAN ENFORCE IT
            // (docs/ranges-plan.md D4): moving the selection while a
            // composition is live would end it and commit the user's
            // half-typed word. Refused as a no-op under a named reason,
            // never a panic — the app wrote correct code and lost a race.
            if COMPOSING.with_borrow(|live| live.contains(&id.0)) {
                eprintln!("kaya: select_range refused: ime_composition (widget {})", id.0);
                return Ok(());
            }
            field
                .TextDocument()?
                .Selection()?
                .SetRange(range.start as i32, range.stop as i32)?;
        }
        ApplyOp::SetColumnHeaders {
            id,
            sorted,
            direction,
            titles,
            tag,
        } => {
            declare_table(core, id, sorted, direction, titles, tag)?;
        }
        ApplyOp::SetDrawing { id, width, height, scale, pixels } => {
            if let Some(NativeWidget::Canvas(image)) = core.widgets.get(&id) {
                set_drawing(&image.clone(), width, height, scale, &pixels.0)?;
            }
        }
        ApplyOp::SetAppIdentity(identity) => {
            // TWO SINKS FROM ONE DECLARATION (docs/app-identity-plan.md
            // I3): the WINDOW's icon, which the taskbar and alt-tab read,
            // and the XAML `TitleBar`'s `IconSource`, which repairs what a
            // custom caption takes away from the first.
            apply_app_identity(core, &identity)?;
        }
        ApplyOp::SetTypeface(req) => {
            // TWO ROUTES, BECAUSE THE PLATFORM HAS TWO KINDS OF TEXT and
            // no single write reaches both: the CONTROLS take the family
            // from `ContentControlThemeFontFamily`, which an app-level
            // dictionary can redefine, while a TextBlock takes it from a
            // local value only (`typeface_dictionary`, `text_block`).
            apply_typeface(&req)?;
        }
        ApplyOp::SetBrand { accent } => {
            // VALUES IN, VALUES OUT: the core derived the eleven words
            // (crates/kaya/src/brand.rs) and this arm re-derives none of
            // them — no opacity ladder, no foreground rule.
            apply_brand(&accent)?;
        }
        ApplyOp::RevealRange { id, range } => {
            let Some(field) = textarea_by_id(core, id.0) else {
                return Ok(());
            };
            // `PointOptions::None` is the MINIMUM scroll that brings the
            // range into view, which is every other backend's semantics.
            // A scroll disturbs neither the selection nor a composition,
            // so reveal has no refusal arm.
            field
                .TextDocument()?
                .GetRange(range.start as i32, range.stop as i32)?
                .ScrollIntoView(PointOptions::None)?;
        }
        ApplyOp::PresentSaveDialog(spec) => {
            // The Shell's SAVE dialog — the picker's presentation with
            // the multiplicity flag replaced by a name (`file_save_show`).
            // THE WINDOW IS AN APPLY-SIDE CERTAINTY: same-batch ordering
            // means the create reached this backend first, so a miss here
            // is a core bug and dies naming it (hwnd 0 = unowned dialog).
            let target = winui_window(core, spec.window.0)
                .expect("kaya: a save dialog was presented over a window this process does not hold");
            let hwnd = windows_core::Interface::cast::<IWindowNative>(&target)
                .ok()
                .and_then(|n: IWindowNative| n.window_handle().ok())
                .unwrap_or(0);
            let request = DialogRequest {
                hwnd,
                kind: DialogKind::Save {
                    suggested_name: spec.suggested_name.clone(),
                },
                filters: spec.filters.clone(),
                // The SAME armed directory the picker reads:
                // `file_dialog_goto` arms one slot and whichever dialog
                // presents next consumes it, because a dialog reads its
                // folder only at presentation.
                folder: core.pending_dialog_dir.borrow_mut().take(),
                dialog: spec.dialog.0,
                sink: core.occurrences.clone(),
            };
            // QUEUE, THEN RING: whichever order the apartment thread
            // starts in, the request is already there to be found.
            DIALOG_QUEUE.lock().unwrap().push(request);
            dialog_apartment();
            unsafe { SetEvent(dialog_doorbell()) };
        }
        ApplyOp::PresentFileDialog(spec) => {
            // The Shell's common item dialog, which is what Windows means by a
            // file picker. NOT FileOpenPicker: its SuggestedStartLocation is a
            // PickerLocationId ENUM of well-known folders, so it cannot be
            // pointed at <temp>/kaya-picked-<pid> at all. ON THE DIALOG
            // APARTMENT'S THREAD, because Show() is modal and runs a nested
            // message loop that would stall the dispatcher (`dialog_apartment`).
            let target = winui_window(core, spec.window.0)
                .expect("kaya: a file picker was presented over a window this process does not hold");
            let hwnd = windows_core::Interface::cast::<IWindowNative>(&target)
                .ok()
                .and_then(|n: IWindowNative| n.window_handle().ok())
                .unwrap_or(0);
            let request = DialogRequest {
                hwnd,
                kind: DialogKind::Open {
                    multiple: spec.multiple,
                },
                filters: spec.filters.clone(),
                folder: core.pending_dialog_dir.borrow_mut().take(),
                dialog: spec.dialog.0,
                sink: core.occurrences.clone(),
            };
            // QUEUE, THEN RING: whichever order the apartment thread
            // starts in, the request is already there to be found.
            DIALOG_QUEUE.lock().unwrap().push(request);
            dialog_apartment();
            unsafe { SetEvent(dialog_doorbell()) };
        }
        ApplyOp::PresentAlert(spec) => {
            // The platform's REAL modal dialog: ContentDialog's three
            // slots ARE the vocabulary (two actions + close). The
            // ShowAsync completion is the ONE emit site — anything that is
            // not Primary/Secondary completes as None, the cancel slot.
            let host = winui_window(core, spec.window.0)?;
            // A dialog needs the host's LIVE XamlRoot, and a guest can
            // request one within milliseconds of launch — before the
            // content island exists (caught live 2026-07-22: the expect
            // aborted the UI thread). Not ready yet: re-enqueue this whole
            // present on the dispatcher and let the queue load the content
            // first; expect_alert retries until the dialog is really up.
            let root_live = host
                .Content()
                .and_then(|c| {
                    let root: FrameworkElement = windows_core::Interface::cast(&c)?;
                    root.XamlRoot()
                })
                .is_ok();
            if !root_live {
                // Re-present when the root actually loads — its Loaded
                // event is the platform's own "the island is up" signal.
                // A dispatcher self-re-enqueue loop STARVES the queue that
                // would do the loading, and a timer is a guess.
                let root: FrameworkElement = windows_core::Interface::cast(&host.Content()?)?;
                let cell = std::sync::Mutex::new(Some(spec));
                let handler = RoutedEventHandler::new(move |_, _| {
                    if let Some(spec) = cell.lock().unwrap().take() {
                        CORE.with_borrow_mut(|core| {
                            let core = core.as_mut().expect("core state initialized");
                            let _ = apply(core, ApplyOp::PresentAlert(spec));
                        });
                    }
                    Ok(())
                });
                root.Loaded(&handler)?;
                return Ok(());
            }
            let dialog = ContentDialog::new().expect("ContentDialog::new");
            let title = PropertyValue::CreateString(&HSTRING::from(spec.title.as_str()))
                .expect("title box");
            dialog.SetTitle(&title).expect("SetTitle");
            let message = PropertyValue::CreateString(&HSTRING::from(spec.message.as_str()))
                .expect("message box");
            dialog.SetContent(&message).expect("SetContent");
            if let Some(a0) = spec.actions.first() {
                dialog
                    .SetPrimaryButtonText(&HSTRING::from(a0.as_str()))
                    .expect("SetPrimaryButtonText");
            }
            if let Some(a1) = spec.actions.get(1) {
                dialog
                    .SetSecondaryButtonText(&HSTRING::from(a1.as_str()))
                    .expect("SetSecondaryButtonText");
            }
            dialog
                .SetCloseButtonText(&HSTRING::from(spec.cancel.as_str()))
                .expect("SetCloseButtonText");
            dialog
                .SetDefaultButton(if spec.actions.is_empty() {
                    ContentDialogButton::Close
                } else {
                    ContentDialogButton::Primary
                })
                .expect("SetDefaultButton");
            let xaml_root = host
                .Content()
                .expect("host content")
                .XamlRoot()
                .expect("host XamlRoot");
            dialog.SetXamlRoot(&xaml_root).expect("SetXamlRoot");
            let alert_id = spec.alert.0;
            core.live_alert = Some(WinLiveAlert {
                window: spec.window.0,
                actions: spec.actions.len(),
                dialog: dialog.clone(),
            });
            let op = dialog.ShowAsync().expect("ShowAsync");
            op.SetCompleted(&windows_future::AsyncOperationCompletedHandler::new(
                move |op: windows_core::Ref<'_, windows_future::IAsyncOperation<ContentDialogResult>>,
                      _status| {
                    let result = op.ok()?.GetResults()?;
                    let choice = match result {
                        ContentDialogResult::Primary => crate::protocol::AlertChoice::Action(0),
                        ContentDialogResult::Secondary => crate::protocol::AlertChoice::Action(1),
                        _ => crate::protocol::AlertChoice::Cancel,
                    };
                    // The result must ride THIS backend's sink (the guest
                    // listens there); capi::alert_retire is only the
                    // liveness gate.
                    let sink = CORE.with(|core| {
                        let mut core = core.borrow_mut();
                        let core = core.as_mut().expect("core lives while a dialog shows");
                        core.live_alert = None;
                        core.occurrences.clone()
                    });
                    crate::capi::alert_retire(alert_id);
                    sink.send(Occurrence::AlertResult {
                        alert: crate::protocol::AlertId(alert_id),
                        choice,
                    });
                    Ok(())
                },
            ))
            .expect("SetCompleted");
        }
        ApplyOp::SetProp { id, prop, value } => {
            // Grow is handled ahead of the per-kind table: it is the one
            // kind-agnostic prop, and its effect lands on the parent's
            // track definitions rather than on the widget itself.
            if let (Prop::Grow, Value::F64(weight)) = (prop, &value) {
                debug_assert!(core.widgets.contains_key(&id), "scene validated the id");
                core.grow.insert(id, *weight);
                if let Some(parent) = core.child_order.parent_of(id) {
                    core.child_order.mark(parent);
                }
                return Ok(());
            }
            let widget = core.widgets.get(&id).expect("scene validated the id");
            match (widget, prop, value) {
                (NativeWidget::Button { caption, .. }, Prop::Text, Value::Str(s)) => {
                    caption.SetText(&HSTRING::from(&s))?;
                }
                (NativeWidget::Label(label), Prop::Text, Value::Str(s)) => {
                    label.SetText(&HSTRING::from(&s))?;
                    // An option label's text lands on its ComboBox row
                    // too, as string content (see select_options for why
                    // never a TextBlock) — or its radio row.
                    if let Some((_, item)) = core.select_options.get(&id.0) {
                        item.SetContent(&PropertyValue::CreateString(&HSTRING::from(&s))?)?;
                    }
                    if let Some((group, row)) = core.radio_options.get(&id.0) {
                        group
                            .Items()?
                            .SetAt(*row, &PropertyValue::CreateString(&HSTRING::from(&s))?)?;
                    }
                }
                (NativeWidget::Entry(_), Prop::Text, Value::Str(s))
                | (NativeWidget::Textarea(_), Prop::Text, Value::Str(s)) => {
                    let field = widget.editable().expect("the arm matched a text widget");
                    // Quiet: a property write is configuration, not a
                    // user edit — and TextChanged is raised async, so the
                    // flag is a counter (see entry_swallow).
                    if lf(field.text()?) != s {
                        if let Some(swallow) = core.entry_swallow.get(&id.0) {
                            swallow.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                        }
                        field.set_text(&s)?;
                        clear_native_undo(&field);
                    }
                }
                (NativeWidget::Checkbox { caption, .. }, Prop::Text, Value::Str(s)) => {
                    caption.SetText(&HSTRING::from(&s))?;
                }
                (NativeWidget::Checkbox { check, .. }, Prop::Checked, Value::Bool(b)) => {
                    let boxed: IReference<bool> = PropertyValue::CreateBoolean(b)?.cast()?;
                    core.apply_quiet
                        .store(true, std::sync::atomic::Ordering::Relaxed);
                    let write = check.SetIsChecked(&boxed);
                    core.apply_quiet
                        .store(false, std::sync::atomic::Ordering::Relaxed);
                    write?;
                }
                (NativeWidget::Slider(slider), Prop::Value, Value::F64(v)) => {
                    core.apply_quiet
                        .store(true, std::sync::atomic::Ordering::Relaxed);
                    let write = slider.SetValue(v);
                    core.apply_quiet
                        .store(false, std::sync::atomic::Ordering::Relaxed);
                    write?;
                }
                (NativeWidget::Select(combo), Prop::Value, Value::F64(v)) => {
                    // A programmatic write is quiet: only the user path
                    // emits.
                    core.apply_quiet
                        .store(true, std::sync::atomic::Ordering::Relaxed);
                    let write = combo.SetSelectedIndex(v as i32);
                    core.apply_quiet
                        .store(false, std::sync::atomic::Ordering::Relaxed);
                    write?;
                }
                // THE UNIVERSAL PROPS: every other arm keys on a (kind,
                // prop) pair; these name something every element has, so
                // they match the prop alone. WinUI publishes a settable
                // AutomationId, so the harness read matches by identity.
                (w, Prop::A11yId, Value::Str(id)) => {
                    let element = w.element()?;
                    bindings::Microsoft::UI::Xaml::Automation::AutomationProperties::SetAutomationId(
                        &element,
                        &windows_core::HSTRING::from(id.as_str()),
                    )?;
                }
                // Empty means unset, and unset stays untouched: UIA derives a
                // control's name from its content, and writing "" would
                // SILENCE it. THE EMPTINESS TEST IS INSIDE THE ARM, never a
                // pattern guard (gtk.rs:A11yLabel has the same shape): a
                // guard makes an empty label match NO arm and fall through
                // to the catch-all panic (docs/deferred.md a11y-empty-label).
                (w, Prop::A11yLabel, Value::Str(label)) => {
                    if !label.is_empty() {
                        let element = w.element()?;
                        bindings::Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(
                            &element,
                            &windows_core::HSTRING::from(label.as_str()),
                        )?;
                    }
                }
                // The HINT: UIA's HelpText. Empty means unset, like the
                // name, and inside the arm for the name's reason.
                (w, Prop::A11yHint, Value::Str(hint)) => {
                    if !hint.is_empty() {
                        let element = w.element()?;
                        bindings::Microsoft::UI::Xaml::Automation::AutomationProperties::SetHelpText(
                            &element,
                            &windows_core::HSTRING::from(hint.as_str()),
                        )?;
                    }
                }
                // ACCEPTANCE IS PER-WIDGET (DESIGN.md, Clipboard): the
                // list drives the paste split and Paste's enablement.
                // Kind-agnostic like the universal props; empty means
                // unset, the universal prop rule.
                (_, Prop::Accepts, Value::Str(list)) => {
                    if list.is_empty() {
                        core.accepts.remove(&id.0);
                    } else {
                        core.accepts.insert(id.0, list);
                    }
                    core.roles_armed = true;
                    refresh_role_enablement(core);
                }
                (NativeWidget::Grid2D(_), Prop::Columns, Value::F64(cols)) => {
                    core.grid_cols.insert(id.0, cols as i32);
                    core.child_order.mark(id);
                }
                (NativeWidget::Grid2D(grid), Prop::Spacing, Value::F64(gap)) => {
                    grid.SetRowSpacing(gap)?;
                    grid.SetColumnSpacing(gap)?;
                }
                (NativeWidget::Radio(group), Prop::Value, Value::F64(v)) => {
                    core.apply_quiet
                        .store(true, std::sync::atomic::Ordering::Relaxed);
                    let write = group.SetSelectedIndex(v as i32);
                    core.apply_quiet
                        .store(false, std::sync::atomic::Ordering::Relaxed);
                    write?;
                }
                (NativeWidget::Progress(bar), Prop::Value, Value::F64(v)) => {
                    bar.SetValue(v)?;
                }
                (NativeWidget::Progress(bar), Prop::Indeterminate, Value::Bool(on)) => {
                    bar.SetIsIndeterminate(on)?;
                }
                (NativeWidget::Column(grid) | NativeWidget::Row(grid), Prop::Spacing, Value::F64(gap)) => {
                    // The gap rides the STACKING axis, which the fold
                    // decides, not the variant. The DECLARED value is
                    // stored beside the write — expect_fills sums with the
                    // declaration, never the toolkit's read-back.
                    core.spacings.insert(id, gap);
                    if effective_vertical(core, id) {
                        grid.SetRowSpacing(gap)?;
                        grid.SetColumnSpacing(0.0)?;
                    } else {
                        grid.SetColumnSpacing(gap)?;
                        grid.SetRowSpacing(0.0)?;
                    }
                }
                (
                    NativeWidget::Column(_) | NativeWidget::Row(_) | NativeWidget::Grid2D(_),
                    Prop::Inset,
                    Value::F64(pad),
                ) => {
                    // A container's own padding, one level down from the
                    // window inset (docs/styling-plan.md D3). One arm for
                    // all three container kinds because all three ARE
                    // Grids here; on a mounted root this Padding carries
                    // the window inset too.
                    core.container_insets.insert(id, pad);
                    stamp_container_padding(core, id)?;
                }
                (NativeWidget::Column(grid) | NativeWidget::Row(grid), Prop::Axis, Value::I64(v)) => {
                    // The axis-state pass (docs/adaptive-layout-plan.md
                    // D2): store the override, move the gap onto the new
                    // stacking axis, and let reindex rebuild the tracks.
                    core.axes.insert(id, v);
                    let gap = core.spacings.get(&id).copied().unwrap_or(8.0);
                    if v == 1 {
                        grid.SetRowSpacing(gap)?;
                        grid.SetColumnSpacing(0.0)?;
                    } else {
                        grid.SetColumnSpacing(gap)?;
                        grid.SetRowSpacing(0.0)?;
                    }
                    core.child_order.mark(id);
                }
                (NativeWidget::Column(_), Prop::Align, Value::I64(mode))
                | (NativeWidget::Row(_), Prop::Align, Value::I64(mode)) => {
                    core.aligns.insert(id, mode);
                    core.child_order.mark(id);
                }
                (NativeWidget::Slider(slider), Prop::Min, Value::F64(v)) => {
                    slider.SetMinimum(v)?;
                }
                (NativeWidget::Slider(slider), Prop::Max, Value::F64(v)) => {
                    slider.SetMaximum(v)?;
                }
                (NativeWidget::Image(image), Prop::Source, Value::Blob(blob)) => {
                    // Encoded bytes in, native decode. SetSource is the
                    // synchronously-callable path on the UI thread; the
                    // one async hop is DataWriter.StoreAsync, blocked on
                    // .join(). Any failure (decode included) leaves the
                    // placeholder — never a panic.
                    let result: windows_core::Result<()> = (|| {
                        let stream = InMemoryRandomAccessStream::new()?;
                        let writer = DataWriter::CreateDataWriter(&stream)?;
                        writer.WriteBytes(&blob.0)?;
                        writer.StoreAsync()?.join()?;
                        writer.DetachStream()?;
                        stream.Seek(0)?;
                        let source = BitmapImage::new()?;
                        source.SetSource(&stream)?;
                        image.SetSource(&source)?;
                        Ok(())
                    })();
                    if let Err(e) = result {
                        eprintln!(
                            "kaya: winui image source rejected (placeholder): {}",
                            e.message()
                        );
                    }
                }
                // THE ROLE TIER (docs/styling-plan.md D4): three semantic
                // roles, each lowered to the platform's OWN emphasis. The
                // legal (kind, role) pairs sit in the PATTERNS, so a role
                // on a kind it does not fit falls to this match's
                // catch-all and dies naming the prop and the value.
                (NativeWidget::Button { button, .. }, Prop::Role, Value::I64(2)) => {
                    // PROMINENT: a single keyed Style whose background is
                    // `AccentFillColorDefaultBrush`, painted by the accent
                    // stops the brand lowering wrote. A brandless app gets
                    // the user's Windows accent.
                    button.SetStyle(&theme_resource::<Style>("AccentButtonStyle")?)?;
                }
                (NativeWidget::Button { caption, .. }, Prop::Role, Value::I64(1)) => {
                    // DESTRUCTIVE, AND FLUENT SHIPS NO DESTRUCTIVE BUTTON, so
                    // kaya lowers the platform's severity palette onto the
                    // TEXT and leaves the chrome standard
                    // (docs/styling-plan.md D4). ON THE CAPTION, NOT ON THE
                    // BUTTON: the Button template re-points the presenter's
                    // Foreground in PointerOver and Pressed.
                    caption.SetForeground(&theme_resource::<Brush>(
                        "SystemFillColorCriticalBrush",
                    )?)?;
                }
                (NativeWidget::Label(label), Prop::Role, Value::I64(3)) => {
                    // THE HEADING ROLE IS TWO FACTS AT ONCE: a style changes no
                    // UIA property, and HeadingLevel changes no pixel. The
                    // accessible fact is UIA's own HeadingLevel, which gives
                    // real heading NAVIGATION — `SetLevel` is depth in a
                    // hierarchy and `SetLocalizedControlType` would only make
                    // Narrator SAY "heading".
                    bindings::Microsoft::UI::Xaml::Automation::AutomationProperties::SetHeadingLevel(
                        label,
                        bindings::Microsoft::UI::Xaml::Automation::Peers::AutomationHeadingLevel::Level2,
                    )?;
                    // THE TEXT TIER IS A STYLE KEY, NEVER A FONT SIZE.
                    // `SubtitleTextBlockStyle` is Fluent's own
                    // section-heading step of the XAML type ramp, so the
                    // size, weight and line height are the platform's
                    // scale — picking numbers out of it is what D4 refuses.
                    label.SetStyle(&theme_resource::<Style>("SubtitleTextBlockStyle")?)?;
                }
                (NativeWidget::Label(label), Prop::Role, Value::I64(4)) => {
                    // The caption role: Fluent's own caption step of the
                    // type ramp, on the secondary text fill. STYLE ONLY —
                    // UIA has no caption fact to publish (SetHeadingLevel
                    // is headings alone), the same carve-out Apple's stack
                    // has and a11yrows.steps records.
                    label.SetStyle(&theme_resource::<Style>("CaptionTextBlockStyle")?)?;
                    label.SetForeground(&theme_resource::<Brush>(
                        "TextFillColorSecondaryBrush",
                    )?)?;
                }
                (_, prop, value) => {
                    panic!("kaya: winui cannot apply {prop:?} = {value:?} here")
                }
            }
        }
        ApplyOp::AddChild { parent, child } => {
            // The viewport's one child (the scene rejects a second):
            // ScrollViewer is a ContentControl, not a panel.
            if let NativeWidget::Scroll(viewer) =
                core.widgets.get(&parent).expect("scene validated the id")
            {
                let viewer = viewer.clone();
                let element = core
                    .widgets
                    .get(&child)
                    .expect("scene validated the id")
                    .element()?;
                viewer.SetContent(&element)?;
                return Ok(());
            }
            if let NativeWidget::Grid2D(_) =
                core.widgets.get(&parent).expect("scene validated the id")
            {
                let element = core
                    .widgets
                    .get(&child)
                    .expect("scene validated the id")
                    .element()?;
                core.grid_children
                    .get_mut(&parent.0)
                    .expect("grid created")
                    .push(element);
                core.child_order.mark(parent);
                return Ok(());
            }
            // A radio's label children are its OPTIONS: string rows of
            // the group's Items vector, and the label leaves the harness's
            // label registry.
            if let NativeWidget::Radio(group) =
                core.widgets.get(&parent).expect("scene validated the id")
            {
                let group = group.clone();
                let items = group.Items()?;
                let row = items.Size()?;
                if let NativeWidget::Label(label) =
                    core.widgets.get(&child).expect("scene validated the id")
                {
                    items.Append(&PropertyValue::CreateString(&label.Text()?)?)?;
                    let label = label.clone();
                    core.labels.retain(|x| x != &label);
                } else {
                    items.Append(&PropertyValue::CreateString(&HSTRING::new())?)?;
                }
                core.radio_options.insert(child.0, (group, row));
                return Ok(());
            }
            // A select's label children are its OPTIONS: ComboBoxItems in
            // the popup, never children of a panel. The label's native
            // TextBlock stays unparented and the label leaves the harness's
            // label registry — options are the select's data, so they must
            // not shift every later label's index.
            if let NativeWidget::Select(combo) =
                core.widgets.get(&parent).expect("scene validated the id")
            {
                let combo = combo.clone();
                let item = ComboBoxItem::new()?;
                if let NativeWidget::Label(label) =
                    core.widgets.get(&child).expect("scene validated the id")
                {
                    // The row initializes from the label's CURRENT text:
                    // children-first sugars (OCaml, Haskell) set the text
                    // BEFORE this AddChild (the GTK empty-row lesson).
                    item.SetContent(&PropertyValue::CreateString(&label.Text()?)?)?;
                    let label = label.clone();
                    core.labels.retain(|x| x != &label);
                }
                combo.Items()?.Append(&item)?;
                core.select_options.insert(child.0, (combo, item));
                return Ok(());
            }
            let panel = match container_panel(core, parent) {
                Some(panel) => panel,
                None => panic!("kaya: add_child parent is not a container"),
            };
            let children = panel.Children()?;
            match core.widgets.get(&child).expect("scene validated the id") {
                NativeWidget::Column(p) | NativeWidget::Row(p) => children.Append(p)?,
                NativeWidget::Button { button, .. } => children.Append(button)?,
                NativeWidget::Label(label) => children.Append(label)?,
                NativeWidget::Entry(field) => children.Append(field)?,
                NativeWidget::Checkbox { check, .. } => children.Append(check)?,
                NativeWidget::Slider(slider) => children.Append(slider)?,
                NativeWidget::Image(image) => children.Append(image)?,
                NativeWidget::Scroll(viewer) => children.Append(viewer)?,
                NativeWidget::Progress(bar) => children.Append(bar)?,
                NativeWidget::Select(combo) => children.Append(combo)?,
                NativeWidget::Radio(group) => children.Append(group)?,
                NativeWidget::Grid2D(grid) => children.Append(grid)?,
                NativeWidget::Textarea(field) => children.Append(field)?,
                NativeWidget::Canvas(image) => children.Append(image)?,
            }
            core.parents.insert(child, panel);
            // A new child means a new track and a shifted set of indices —
            // stamped once for the whole batch (winui/order.rs).
            core.child_order.append(parent, child);
        }
        ApplyOp::Fold { child, table } => {
            // The stacked fold (D7): the element moves into the table's
            // wrap and scrolls away with the rows under the pinned header.
            // Identity does not move — the child keeps its id, its order
            // entry and its registries — so the move is an Append each way
            // plus a re-stamp.
            let element = core
                .widgets
                .get(&child)
                .expect("scene validated the id")
                .element()?;
            if table.0 != 0 {
                core.folded_into.insert(child.0, table.0);
                if let Some(panel) = core.parents.get(&child) {
                    let children = panel.Children()?;
                    let mut at = 0u32;
                    if children.IndexOf(&element, &mut at)? {
                        children.RemoveAt(at)?;
                    }
                }
                TABLES.with_borrow_mut(|tables| -> windows_core::Result<()> {
                    if let Some(t) = tables.get_mut(&table.0) {
                        t.wrap.Children()?.Append(&element)?;
                        t.folded.push(element.cast()?);
                        fold_restack(t)?;
                    }
                    Ok(())
                })?;
            } else if let Some(tid) = core.folded_into.remove(&child.0) {
                TABLES.with_borrow_mut(|tables| -> windows_core::Result<()> {
                    if let Some(t) = tables.get_mut(&tid) {
                        let children = t.wrap.Children()?;
                        let mut at = 0u32;
                        if children.IndexOf(&element, &mut at)? {
                            children.RemoveAt(at)?;
                        }
                        let fe: FrameworkElement = element.cast()?;
                        t.folded.retain(|e| e != &fe);
                        fold_restack(t)?;
                    }
                    Ok(())
                })?;
                if let Some(panel) = core.parents.get(&child) {
                    panel.Children()?.Append(&element)?;
                }
            }
            if let Some(parent) = core.child_order.parent_of(child) {
                core.child_order.mark(parent);
            }
        }
        ApplyOp::Mount { window, root } => {
            let widget = core.widgets.get(&root).expect("scene validated the id");
            // Both handles are taken here, under the widget borrow: a
            // WinRT handle is refcounted and outlives the map it came
            // from, which is what lets the stamp below take the core state
            // mutably.
            let element = widget.element()?;
            let panel = match widget {
                NativeWidget::Column(panel) | NativeWidget::Row(panel) => Some(panel.clone()),
                _ => None,
            };
            let scroll_root = matches!(widget, NativeWidget::Scroll(_));
            if let Some(panel) = panel {
                // The normalized root inset — the window's OWN (wprop 8,
                // docs/styling-plan.md D3), INSIDE the root (Grid.Padding
                // is inside ActualSize, so expect_root_fills holds).
                // Recorded as a mounted root FIRST, because
                // container_padding adds this container's own inset to it.
                core.mounted_roots.insert(window.0, root);
                stamp_container_padding(core, root)?;
                // Baseline compensation needs REAL text metrics, and at
                // apply time the grid has never had a true layout pass: a
                // detached or just-attached measure reads zeros (margins
                // came out ~0 and the row classified start on the first two
                // Windows runs). Loaded fires after the first real layout.
                let loaded = RoutedEventHandler::new(move |_, _| {
                    CORE.with_borrow(|core| {
                        let Some(core) = core.as_ref() else {
                            return Ok(());
                        };
                        let ids: Vec<WidgetId> = core
                            .aligns
                            .iter()
                            .filter(|&(_, &m)| m == 4)
                            .map(|(&id, _)| id)
                            .collect();
                        for id in ids {
                            reindex(core, id)?;
                        }
                        Ok(())
                    })
                });
                panel.Loaded(&loaded)?;
                // The width report's trigger: this backend projects no
                // SizeChanged, so the mounted root's LayoutUpdated is where
                // a resize is seen — coalesced, same-width silent.
                let laid = EventHandler::<windows_core::IInspectable>::new(move |_, _| {
                    schedule_window_metrics();
                    Ok(())
                });
                panel.LayoutUpdated(&laid)?;
                schedule_window_metrics();
            }
            // A SCROLL-ROOTED WINDOW gets the panel path's three duties through
            // a minted HOST grid, because the viewer can carry none of them:
            // the window inset (its template ignores Padding —
            // scroll_root_hosts), the mounted-root record, and the
            // LayoutUpdated metrics trigger, without which every breakpoint on
            // the screen is dead (docs/adaptive-layout-plan.md).
            let element = if scroll_root {
                core.mounted_roots.insert(window.0, root);
                let host = Grid::new()?;
                host.Children()?.Append(&element)?;
                core.scroll_root_hosts.insert(root, host.clone());
                stamp_container_padding(core, root)?;
                let laid = EventHandler::<windows_core::IInspectable>::new(move |_, _| {
                    schedule_window_metrics();
                    Ok(())
                });
                host.LayoutUpdated(&laid)?;
                schedule_window_metrics();
                host.cast::<UIElement>()?
            } else {
                element
            };
            // The target is a SURFACE: a navigation entry presents
            // in-window, the primary is the window's own root, an auxiliary
            // presents its window.
            if core.section_panes.contains_key(&window.0) {
                // A section presents in-window, BUT THE WINDOW IT SITS IN MAY BE
                // AN AUXILIARY NOTHING HAS PRESENTED: a sections window mounts
                // into its SECTIONS and never into a root, so the "Mounting
                // presents" Activate below cannot fire for it and
                // CreateWindow's materializes-hidden would become permanent —
                // a window the user never saw, every observation still green.
                let owner = core.section_panes[&window.0].window;
                core.section_panes.get_mut(&window.0).unwrap().root =
                    Some(element);
                refresh_section_pane(core, window.0)?;
                if owner != 0 {
                    winui_window(core, owner)?.Activate()?;
                }
            } else if core.nav_entries.contains_key(&window.0) {
                mount_entry(core, window.0, element)?;
            } else if window.0 == 0 {
                let element = nav_probe_wrap(&element)?;
                set_window_content(core, 0, &element)?;
                core.window_roots.insert(0, element);
            } else {
                set_window_content(core, window.0, &element)?;
                // Mounting presents.
                winui_window(core, window.0)?.Activate()?;
                core.window_roots.insert(window.0, element);
            }
        }
        ApplyOp::Command { id, command } => {
            let widget = core.widgets.get(&id).expect("scene validated the id");
            match command {
                CommandKind::Clear => {
                    let field = widget
                        .editable()
                        .expect("kaya: clear on a non-text widget (scene validates kinds)");
                    // A command ACTS LIKE THE USER, and its echo must stay
                    // ORDERED with what follows — TextChanged is raised
                    // async, so the echo is emitted here synchronously and
                    // the late raise is swallowed (see entry_swallow).
                    if !field.text()?.is_empty() {
                        if let Some(swallow) = core.entry_swallow.get(&id.0) {
                            swallow.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                        }
                        field.set_text("")?;
                        clear_native_undo(&field);
                        if let Some(tag) = core.entry_tags.get(&id.0) {
                            core.occurrences.send_text_tag(tag, "");
                        }
                    }
                }
                CommandKind::Focus => {
                    // The materialization class (docs/traps.md): an
                    // element not yet in the live tree cannot take focus
                    // and the call's bool would be discarded, so a
                    // mount-tx focus would silently drop. Not loaded yet:
                    // one-shot re-run from the element's own Loaded.
                    let element = widget.element()?;
                    let fe: FrameworkElement = windows_core::Interface::cast(&element)?;
                    if fe.IsLoaded()? {
                        let _ = element.Focus(FocusState::Programmatic)?;
                    } else {
                        // One-shot: Loaded re-fires on every re-attach,
                        // and a stale handler must not steal focus later.
                        let armed = std::sync::Mutex::new(true);
                        let deferred = RoutedEventHandler::new(
                            move |sender: windows_core::Ref<'_, windows_core::IInspectable>, _| {
                                if !std::mem::take(&mut *armed.lock().unwrap()) {
                                    return Ok(());
                                }
                                if let Some(sender) = sender.as_ref() {
                                    let element: UIElement =
                                        windows_core::Interface::cast(sender)?;
                                    let _ = element.Focus(FocusState::Programmatic)?;
                                }
                                Ok(())
                            },
                        );
                        fe.Loaded(&deferred)?;
                    }
                }
            }
        }
    }
    Ok(())
}

// --- Windows App Runtime bootstrap (unpackaged apps) ---------------------
//
// Loaded dynamically so kaya needs no import lib from the NuGet package.

const WASDK_MAJOR_MINOR: u32 = 0x0002_0002; // 2.2
const MDD_ON_NO_MATCH_SHOW_UI: i32 = 0x8;

#[link(name = "kernel32")]
unsafe extern "system" {
    fn LoadLibraryW(name: *const u16) -> *mut c_void;
    fn GetProcAddress(module: *mut c_void, name: *const u8) -> *mut c_void;
    /// The dialog apartment's doorbell: auto-reset, unnamed.
    fn CreateEventW(
        attributes: *const c_void,
        manual_reset: i32,
        initial: i32,
        name: *const u16,
    ) -> isize;
    fn SetEvent(event: isize) -> i32;
    /// This module's own base, for the sampler window's class.
    #[cfg(feature = "harness")]
    fn GetModuleHandleW(name: *const u16) -> isize;
}

#[link(name = "ole32")]
unsafe extern "system" {
    fn CoInitializeEx(reserved: *const c_void, coinit: u32) -> i32;
    // NO CoUninitialize IS DECLARED HERE, deliberately: the one apartment
    // this process opens for pickers is meant to end with the process.
    // `dialog_apartment` carries the measurement.
}

type MddBootstrapInitialize2 =
    unsafe extern "system" fn(u32, *const u16, u64, i32) -> i32;
type MddBootstrapShutdown = unsafe extern "system" fn();

static BOOTSTRAP_SHUTDOWN: OnceLock<usize> = OnceLock::new();

fn bootstrap_shutdown() {
    if let Some(&addr) = BOOTSTRAP_SHUTDOWN.get() {
        let shutdown: MddBootstrapShutdown = unsafe { std::mem::transmute(addr) };
        unsafe { shutdown() };
    }
}

fn bootstrap_windows_app_runtime() {
    // TODO: resolve the bootstrap DLL relative to kaya's own module path
    // (GetModuleHandleExW with FROM_ADDRESS) instead of the default search
    // order, so foreign hosts (python.exe) need not have kaya's directory
    // on PATH.
    let dll: Vec<u16> = "Microsoft.WindowsAppRuntime.Bootstrap.dll\0"
        .encode_utf16()
        .collect();
    let module = unsafe { LoadLibraryW(dll.as_ptr()) };
    assert!(
        !module.is_null(),
        "Microsoft.WindowsAppRuntime.Bootstrap.dll not found next to the executable"
    );
    let proc = unsafe { GetProcAddress(module, c"MddBootstrapInitialize2".as_ptr().cast()) };
    assert!(!proc.is_null(), "MddBootstrapInitialize2 not exported");
    let init: MddBootstrapInitialize2 = unsafe { std::mem::transmute(proc) };
    let version_tag: Vec<u16> = "\0".encode_utf16().collect();
    let hr = unsafe { init(WASDK_MAJOR_MINOR, version_tag.as_ptr(), 0, MDD_ON_NO_MATCH_SHOW_UI) };
    assert!(
        hr >= 0,
        "MddBootstrapInitialize2 failed: 0x{hr:08x} (is the Windows App Runtime installed?)"
    );

    let shutdown = unsafe { GetProcAddress(module, c"MddBootstrapShutdown".as_ptr().cast()) };
    if !shutdown.is_null() {
        let _ = BOOTSTRAP_SHUTDOWN.set(shutdown as usize);
    }
}

// --- Core ----------------------------------------------------------------

/// The UI-thread half, independent of who owns the app thread. Returns
/// the exit code; the host process decides how to exit (a library must
/// not tear down someone else's process).
pub(crate) fn run_core(occ_tx: OccSink, tx_rx: Receiver<Transaction>) -> i32 {
    install_seh_probe();
    bootstrap_windows_app_runtime();

    const COINIT_APARTMENTTHREADED: u32 = 0x2;
    unsafe { CoInitializeEx(std::ptr::null(), COINIT_APARTMENTTHREADED) };

    // Application::Start creates the XAML UI thread machinery and calls
    // back once it is ready, on the UI thread. Building the core is
    // deferred through the dispatcher so it runs after the launch
    // sequence completes.
    let callback = ApplicationInitializationCallback::new(move |_params| {
        // XAML forwards render-loop errors to CoreApplication; with no
        // handler there, RoReportUnhandledError fail-fasts the process
        // (0xC000027B) — a channel Application.UnhandledException never
        // sees. Propagate() rethrows the stowed HRESULT here, marking it
        // observed; the one known survivable error is deferred theme XAML
        // that cannot instantiate without an IXamlMetadataProvider.
        let on_core_error = bindings::Windows::Foundation::EventHandler::new(
            |_,
             args: windows_core::Ref<
                '_,
                bindings::Windows::ApplicationModel::Core::UnhandledErrorDetectedEventArgs,
            >| {
                if let Some(args) = args.as_ref() {
                    if let Ok(error) = args.UnhandledError() {
                        match error.Propagate() {
                            Ok(()) => {}
                            Err(e) => eprintln!(
                                "kaya: winui unhandled core error (continuing): {}",
                                e.message()
                            ),
                        }
                    }
                }
                Ok(())
            },
        );
        // The statics interface is activated by hand: pulling in the
        // CoreApplication class itself drags members whose types the
        // standalone windows-* crates do not carry.
        struct CoreApplicationMarker;
        impl windows_core::RuntimeName for CoreApplicationMarker {
            const NAME: &'static str = "Windows.ApplicationModel.Core.CoreApplication";
        }
        let unhandled: bindings::Windows::ApplicationModel::Core::ICoreApplicationUnhandledError =
            windows_core::factory::<CoreApplicationMarker, _>()?;
        unhandled.UnhandledErrorDetected(&on_core_error)?;
        let app = compose_application()?;
        APP.with_borrow_mut(|slot| *slot = Some(app));
        // The aggregation contract, asserted where it can fail loudly: an
        // outer that stops delegating unknown IIDs stow-crashes every
        // control that consults Current at runtime, minutes later, with a
        // bare E_NOINTERFACE (docs/traps.md: The aggregation outer MUST delegate QI).
        bindings::Microsoft::UI::Xaml::Application::Current().expect(
            "kaya: Application.Current() failed — the aggregation outer \
             is not delegating QI to the inner (see KayaOuter)",
        );
        // Stowed exceptions (0xC000027B) die silently; print what XAML
        // actually complained about before the process goes down. A
        // permanent diagnostic, not scaffolding.
        let on_unhandled = UnhandledExceptionEventHandler::new(|_, args| {
            if let Some(args) = args.as_ref() {
                eprintln!(
                    "kaya: winui unhandled exception (continuing): {}",
                    args.Message().unwrap_or_default()
                );
                // Keep the process alive: backends are appliers, and the
                // exceptions seen here in practice are resource lookups
                // for control chrome that unpackaged apps resolve
                // imperfectly. Logged, never silent.
                args.SetHandled(true)?;
            }
            Ok(())
        });
        APP.with_borrow(|app| {
            app.as_ref()
                .expect("composed just above")
                .UnhandledException(&on_unhandled)
        })?;
        let dispatcher = DispatcherQueue::GetForCurrentThread()?;
        let occ_tx = occ_tx.clone();
        let tx_rx_cell = RefCell::new(Some(tx_rx_take()));
        let build = DispatcherQueueHandler::new(move || {
            let tx_rx = tx_rx_cell
                .borrow_mut()
                .take()
                .expect("core set up once");
            setup(occ_tx.clone(), tx_rx)
        });
        dispatcher.TryEnqueue(&build)?;
        DISPATCHER
            .set(SharedDispatcher(dispatcher))
            .map_err(|_| ())
            .expect("run_core called once");
        Ok(())
    });

    // Application::Start's callback cannot capture tx_rx directly because
    // the callback type requires Fn semantics; park it in a static slot.
    tx_rx_put(tx_rx);

    Application::Start(&callback).expect("Application::Start failed");

    // Start has returned; XAML has torn down its apartment. Rust TLS
    // destructors still run during process::exit on Windows, and releasing
    // XAML COM objects into the dead apartment is an access violation.
    // Announce shutdown, then leak the COM references.
    CORE.with_borrow_mut(|core| {
        if let Some(core) = core.take() {
            core.occurrences.send(Occurrence::Shutdown);
            std::mem::forget(core);
        }
    });
    // EVERY THREAD-LOCAL THAT CAN HOLD A XAML HANDLE IS DRAINED AND
    // FORGOTTEN HERE (docs/traps.md: A thread_local holding a XAML object
    // aborts the process at exit, AFTER the scene has passed).
    // `APP_ICON_BITMAP`'s TLS destructor runs after the line above has
    // declared the apartment dead, and the abort lands with the scene
    // already green and nothing printing a reason.
    APP_ICON_BITMAP.with_borrow_mut(|slot| {
        if let Some(bitmap) = slot.take() {
            std::mem::forget(bitmap);
        }
    });
    // The third thread-local under that rule, and the same traps entry's
    // second bite: a declared table's header Grid, rule and cell Buttons
    // live in `TABLES`.
    TABLES.with_borrow_mut(|tables| {
        for (_, table) in tables.drain() {
            std::mem::forget(table);
        }
    });
    // Unwind the App Runtime while the process is still healthy; leaving
    // it for DLL_PROCESS_DETACH crashes inside Microsoft.UI.Xaml.dll in
    // hosted processes (observed with python.exe).
    bootstrap_shutdown();
    EXIT_CODE.load(std::sync::atomic::Ordering::Relaxed)
}

// Receiver<Transaction> is !Sync and the WinRT callback signature forces
// the closure to be Fn + Send, so the receiver crosses into the UI thread
// through this slot instead of the closure environment.
static TX_RX_SLOT: std::sync::Mutex<Option<Receiver<Transaction>>> = std::sync::Mutex::new(None);

fn tx_rx_put(rx: Receiver<Transaction>) {
    *TX_RX_SLOT.lock().unwrap() = Some(rx);
}

fn tx_rx_take() -> Receiver<Transaction> {
    TX_RX_SLOT
        .lock()
        .unwrap()
        .take()
        .expect("transaction receiver already taken")
}

// WinUI 3's interop interface for reaching a Window's HWND
// (IWindowNative, one method past IUnknown): the generated bindings do
// not project AppWindow.
windows_core::imp::define_interface!(
    IWindowNative,
    IWindowNative_Vtbl,
    0xeecdbf0e_bae9_4cb6_a68e_9598e1cb57bb
);
windows_core::imp::interface_hierarchy!(IWindowNative, windows_core::IUnknown);
#[repr(C)]
#[doc(hidden)]
pub struct IWindowNative_Vtbl {
    pub base__: windows_core::IUnknown_Vtbl,
    pub WindowHandle:
        unsafe extern "system" fn(*mut core::ffi::c_void, *mut isize) -> windows_core::HRESULT,
}
impl IWindowNative {
    fn window_handle(&self) -> windows_core::Result<isize> {
        unsafe {
            let mut hwnd = 0isize;
            (windows_core::Interface::vtable(self).WindowHandle)(
                windows_core::Interface::as_raw(self),
                &mut hwnd,
            )
            .ok()?;
            Ok(hwnd)
        }
    }
}

// ---- The app's identity (docs/app-identity-plan.md I3) -------------
//
// TWO SINKS. The WINDOW's icon (`AppWindow.SetIcon`) serves every window,
// the taskbar and alt-tab, and matters most here because kaya is a LIBRARY
// inside python.exe, java.exe and dotnet.exe for six of its eight languages
// — Windows' fallback for a window with no icon ends at the HOST PROCESS's
// icon. `TitleBar.IconSource` is needed BECAUSE a custom caption takes the
// system-drawn icon with it.

thread_local! {
    /// The declared identity, kept because its sinks are not all available
    /// when it arrives: identity is declared BEFORE the first mount (the
    /// core's wall), while an auxiliary window is created later and a
    /// `TitleBar` later still. Every one of those sites reads this slot.
    static APP_IDENTITY: RefCell<Option<crate::protocol::AppIdentity>> =
        const { RefCell::new(None) };
    /// The caption sink's ready-made picture, built ONCE from the bytes; a XAML
    /// object in a thread-local, on the UI thread only, exactly like CORE. A
    /// `BitmapImage` RATHER THAN AN `ImageIconSource`: an `ImageSource` has no
    /// parent, so one can hang off every promoted window's mark at once — an
    /// element could not.
    static APP_ICON_BITMAP: RefCell<Option<BitmapImage>> = const { RefCell::new(None) };
    /// The window sink's `IconId`, as its raw handle value. 0 = none,
    /// which is also what `IconId::default()` carries, so the absence
    /// and the zero are the same fact rather than two.
    static APP_ICON_ID: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

/// `CreateIconFromResourceEx`'s version word: "generally set to 0x00030000"
/// (the Win32 documentation's own words) — the icon-resource format
/// version, not a Windows version.
const ICON_RESOURCE_VERSION: u32 = 0x0003_0000;

#[link(name = "user32")]
unsafe extern "system" {
    /// PNG bytes to an HICON with nothing on disk. `presbits` points at
    /// MEMORY holding one icon IMAGE (an RT_ICON entry, not a whole .ico
    /// file's directory), which since Vista may itself be a PNG.
    fn CreateIconFromResourceEx(
        presbits: *const u8,
        size: u32,
        is_icon: i32,
        version: u32,
        cx: i32,
        cy: i32,
        flags: u32,
    ) -> isize;
    /// The documented counterpart: "You should call DestroyIcon for
    /// icons created with CreateIconFromResourceEx."
    fn DestroyIcon(icon: isize) -> i32;
    /// The harness's read side: `WM_GETICON` is answered by USER32's own
    /// per-window state, not by any cache of kaya's.
    #[cfg(feature = "harness")]
    fn SendMessageW(hwnd: isize, msg: u32, wparam: usize, lparam: isize) -> isize;
    /// The fallback the documentation names when `WM_GETICON` answers 0:
    /// "If sending a WM_GETICON message to a window returns 0, next try
    /// calling the GetClassLongPtr function."
    #[cfg(feature = "harness")]
    fn GetClassLongPtrW(hwnd: isize, index: i32) -> usize;
    /// An HICON's two bitmaps, for the pixel read.
    #[cfg(feature = "harness")]
    fn GetIconInfo(icon: isize, info: *mut IconInfo) -> i32;
}

#[cfg(feature = "harness")]
#[link(name = "gdi32")]
unsafe extern "system" {
    fn GetObjectW(handle: isize, size: i32, out: *mut c_void) -> i32;
    fn GetDIBits(
        hdc: isize,
        bitmap: isize,
        start: u32,
        lines: u32,
        bits: *mut c_void,
        info: *mut BitmapInfo,
        usage: u32,
    ) -> i32;
    fn DeleteObject(handle: isize) -> i32;
    fn CreateCompatibleDC(hdc: isize) -> isize;
    fn DeleteDC(hdc: isize) -> i32;
    /// `canvas_ink`'s camera (see `capture`): a top-down 32-bit surface
    /// to copy the desktop into, and the copy itself.
    fn CreateDIBSection(
        hdc: isize,
        info: *const BitmapInfo,
        usage: u32,
        bits: *mut *mut c_void,
        section: isize,
        offset: u32,
    ) -> isize;
    fn SelectObject(hdc: isize, object: isize) -> isize;
    /// GDI batches drawing into a DIB section; without this the bytes
    /// read back are whatever the allocation held.
    fn GdiFlush() -> i32;
}

/// Win32's ICONINFO, laid out to match winuser.h.
#[cfg(feature = "harness")]
#[repr(C)]
#[derive(Default)]
struct IconInfo {
    is_icon: i32,
    hotspot_x: u32,
    hotspot_y: u32,
    mask: isize,
    color: isize,
}

/// Win32's BITMAP (wingdi.h), for the icon's colour bitmap extent.
#[cfg(feature = "harness")]
#[repr(C)]
#[derive(Default)]
struct BitmapHeader {
    kind: i32,
    width: i32,
    height: i32,
    width_bytes: i32,
    planes: u16,
    bits_pixel: u16,
    bits: *mut c_void,
}

/// Win32's BITMAPINFO: the header plus one colour-table entry, which is
/// what a 32-bit BI_RGB request needs (the table is unused, but the API
/// takes a BITMAPINFO and a bare header would be a short buffer).
#[cfg(feature = "harness")]
#[repr(C)]
#[derive(Default)]
struct BitmapInfo {
    size: u32,
    width: i32,
    height: i32,
    planes: u16,
    bit_count: u16,
    compression: u32,
    size_image: u32,
    x_pels_per_meter: i32,
    y_pels_per_meter: i32,
    clr_used: u32,
    clr_important: u32,
    colors: [u32; 1],
}

/// `Windowing_GetIconIdFromIcon`, the flat export that turns an HICON into the
/// `IconId` the windowing API takes. NOT WinRT, which is why it needs a shim:
/// a plain C function exported from `Microsoft.Internal.FrameworkUdk.dll`,
/// since "third-party apps cannot link to the FrameworkUdk directly". It
/// works in unpackaged apps only after `MddBootstrapInitialize`, which this
/// backend already calls.
type PfnGetIconIdFromIcon = unsafe extern "system" fn(
    isize,
    *mut bindings::Microsoft::UI::IconId,
) -> windows_core::HRESULT;

fn get_icon_id_from_icon(icon: isize) -> Result<bindings::Microsoft::UI::IconId, String> {
    static ENTRY: OnceLock<Option<usize>> = OnceLock::new();
    let entry = *ENTRY.get_or_init(|| {
        let name: Vec<u16> = "Microsoft.Internal.FrameworkUdk.dll"
            .encode_utf16()
            .chain(std::iter::once(0))
            .collect();
        let module = unsafe { LoadLibraryW(name.as_ptr()) };
        if module.is_null() {
            return None;
        }
        let proc = unsafe { GetProcAddress(module, c"Windowing_GetIconIdFromIcon".as_ptr().cast()) };
        (!proc.is_null()).then(|| proc as usize)
    });
    let Some(entry) = entry else {
        return Err(
            "Microsoft.Internal.FrameworkUdk.dll has no Windowing_GetIconIdFromIcon — the \
             Windows App Runtime bootstrapper has not run, or this is an older runtime"
                .to_owned(),
        );
    };
    let f: PfnGetIconIdFromIcon = unsafe { std::mem::transmute(entry) };
    let mut id = bindings::Microsoft::UI::IconId::default();
    let hr = unsafe { f(icon, &mut id) };
    if hr.is_err() {
        return Err(format!("Windowing_GetIconIdFromIcon failed: {hr:?}"));
    }
    Ok(id)
}

/// The wire's blob as an HICON, at the size the system draws a large window
/// icon.
///
/// THE BUFFER IS COPIED INTO AN ALIGNED ONE: the documentation calls
/// `presbits` "the DWORD-aligned buffer pointer containing the icon
/// resource bits", and a wire blob's bytes carry an alignment of one.
fn hicon_from_bytes(bytes: &[u8]) -> Result<isize, String> {
    if bytes.is_empty() {
        return Err("the icon blob is empty".to_owned());
    }
    let mut aligned: Vec<u32> = vec![0; bytes.len().div_ceil(4)];
    // SAFETY: the destination holds at least bytes.len() bytes and the
    // two regions are distinct allocations.
    unsafe {
        std::ptr::copy_nonoverlapping(
            bytes.as_ptr(),
            aligned.as_mut_ptr().cast::<u8>(),
            bytes.len(),
        );
    }
    // cx/cy 0 = the system's own large-icon metric, the size this platform
    // draws a window icon at.
    let icon = unsafe {
        CreateIconFromResourceEx(
            aligned.as_ptr().cast::<u8>(),
            bytes.len() as u32,
            1,
            ICON_RESOURCE_VERSION,
            0,
            0,
            0,
        )
    };
    if icon == 0 {
        return Err(format!(
            "CreateIconFromResourceEx refused {} bytes — the blob is not an icon image \
             this platform can decode (a PNG or an RT_ICON entry)",
            bytes.len()
        ));
    }
    Ok(icon)
}

/// The XAML caption sink's picture: the `Image` widget's blob arm,
/// unchanged. Nothing is decoded by kaya here either — the bytes go to
/// `BitmapImage.SetSource`, the platform's second decoder on the same blob.
fn caption_mark_bitmap(bytes: &[u8]) -> windows_core::Result<BitmapImage> {
    let stream = InMemoryRandomAccessStream::new()?;
    let writer = DataWriter::CreateDataWriter(&stream)?;
    writer.WriteBytes(bytes)?;
    writer.StoreAsync()?.join()?;
    writer.DetachStream()?;
    stream.Seek(0)?;
    let bitmap = BitmapImage::new()?;
    bitmap.SetSource(&stream)?;
    Ok(bitmap)
}

/// The identity's arrival: decode once, then reach every sink that already
/// exists. The sinks that do not exist yet read the slots this fills.
fn apply_app_identity(
    core: &mut CoreState,
    identity: &crate::protocol::AppIdentity,
) -> windows_core::Result<()> {
    APP_IDENTITY.with_borrow_mut(|slot| *slot = Some(identity.clone()));
    if let Some(blob) = &identity.icon {
        // THE WINDOW SINK. A failure here is LOUD: bytes that are not a
        // picture would otherwise leave the platform's own icon in place,
        // which every observation reports exactly as a working identity would.
        let icon = hicon_from_bytes(&blob.0)
            .unwrap_or_else(|why| panic!("kaya: winui: the app identity's icon bytes: {why}"));
        let id = get_icon_id_from_icon(icon).unwrap_or_else(|why| {
            // The one path that DOES destroy: a decode that produced an icon
            // the interop layer then refused.
            unsafe { DestroyIcon(icon) };
            panic!("kaya: winui: the app identity's icon bytes: {why}")
        });
        // THE HICON IS NOT DESTROYED ON THE SUCCESS PATH: the IconId is a
        // handle ONTO it, the windowing layer draws from it for the process's
        // whole life, and the identity is declared once (the core's set-once
        // wall), so there is exactly one of these per process.
        APP_ICON_ID.set(id.Value);

        // THE CAPTION SINK. A failure here is NOT loud: the bytes were already
        // proven decodable by the window sink above, so a failure here is a
        // XAML-side condition and not a bad declaration.
        match caption_mark_bitmap(&blob.0) {
            Ok(bitmap) => APP_ICON_BITMAP.with_borrow_mut(|slot| *slot = Some(bitmap)),
            Err(e) => eprintln!(
                "kaya: winui: the app identity's caption icon did not build: {}",
                e.message()
            ),
        }
    }
    let windows: Vec<u64> = std::iter::once(0).chain(core.aux_windows.keys().copied()).collect();
    for window in windows {
        apply_identity_to_window(core, window)?;
    }
    Ok(())
}

/// One window's share of the declared identity: the window icon, the caption
/// icon if that window has a custom caption, and the caption TEXT. Called
/// from the declaration, a window's creation and a caption's minting —
/// the three orders these objects can arrive in.
fn apply_identity_to_window(core: &CoreState, window: u64) -> windows_core::Result<()> {
    let has_identity = APP_IDENTITY.with_borrow(|slot| slot.is_some());
    if !has_identity {
        return Ok(());
    }
    let icon = APP_ICON_ID.get();
    if icon != 0
        && let Ok(target) = winui_window(core, window)
        && let Ok(app_window) = target.AppWindow()
    {
        // SetIcon, not SetTaskbarIcon: the 1.7 split lets an app give the
        // taskbar a different picture, and kaya has one mark by ruling.
        app_window.SetIconWithIconId(bindings::Microsoft::UI::IconId { Value: icon })?;
    }
    refresh_caption_mark(core, window)?;
    // THE NAME REACHES THE CAPTION THROUGH THE ONE CAPTION WRITER, never
    // through `TitleBar.Title`: that property makes the control a rival
    // author of the window's title and the first casualty is the dirty
    // marker (see `refresh_caption`'s doc comment).
    refresh_caption(core, window)
}

/// The app's mark at the FAR LEFT of a promoted caption, ahead of the menu.
/// NOT `TitleBar.IconSource`: the control lays its own icon out in column 5
/// and `LeftHeader` — kaya's MENU — in column 3, so the mark sat at x=97 in
/// a band whose menu ended at 83 (measured, docs/deferred.md). IDEMPOTENT,
/// AND IT HAS TO BE: XAML ABORTS THE PROCESS when a parented element is
/// appended elsewhere, so the question is asked of the TREE.
fn refresh_caption_mark(core: &CoreState, window: u64) -> windows_core::Result<()> {
    let Some(titlebar) = core.window_titlebars.get(&window) else {
        // No custom caption: the system draws this window's mark from the
        // window icon, which is the other sink's job.
        return Ok(());
    };
    let Some(bitmap) = APP_ICON_BITMAP.with_borrow(|slot| slot.clone()) else {
        // No identity, or an identity with a name and no picture.
        return Ok(());
    };
    let holder = caption_left_header(window, titlebar)?;
    let children = holder.Children()?;
    for i in 0..children.Size()? {
        if children.GetAt(i)?.cast::<Image>().is_ok() {
            return Ok(());
        }
    }
    let mark = Image::new()?;
    mark.SetSource(&bitmap)?;
    mark.SetWidth(CAPTION_MARK_BOX)?;
    mark.SetHeight(CAPTION_MARK_BOX)?;
    mark.SetVerticalAlignment(bindings::Microsoft::UI::Xaml::VerticalAlignment::Center)?;
    mark.SetMargin(Thickness {
        Left: CAPTION_MARK_LEAD,
        Top: 0.0,
        Right: CAPTION_MARK_GAP,
        Bottom: 0.0,
    })?;
    // THE MARK SAYS THE APP'S NAME TO AN ASSISTIVE CLIENT: the DECLARED
    // name, the same string the caption, the taskbar tooltip and alt-tab
    // read, so the mark is findable from outside the process.
    let name = APP_IDENTITY.with_borrow(|slot| slot.as_ref().map(|id| id.name.clone()));
    if let Some(name) = name {
        bindings::Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(
            &mark,
            &HSTRING::from(name),
        )?;
    }
    Grid::SetColumn(&mark.cast::<FrameworkElement>()?, CAPTION_MARK_COLUMN)?;
    children.Append(&mark.cast::<UIElement>()?)?;
    Ok(())
}

/// The window-icon read's constants, from the Win32 documentation:
/// `WM_GETICON`'s three types and the class-icon indices its own
/// fallback note names.
#[cfg(feature = "harness")]
const WM_GETICON: u32 = 0x007F;
#[cfg(feature = "harness")]
const ICON_SMALL: usize = 0;
#[cfg(feature = "harness")]
const ICON_BIG: usize = 1;
#[cfg(feature = "harness")]
const ICON_SMALL2: usize = 2;
#[cfg(feature = "harness")]
const GCLP_HICON: i32 = -14;

/// The four quadrant samples of the icon the window is HOLDING, or a sentence
/// saying what was measured instead. THE ABSENCE SENTENCE DISCRIMINATES
/// (CLAUDE.md invariant 3): a window with no icon of its own uses its
/// registered class's and DefWindowProc answers 0 to `WM_GETICON`, so both
/// steps are taken and both answers are printed.
#[cfg(feature = "harness")]
fn window_icon_samples(hwnd: isize) -> String {
    let big = unsafe { SendMessageW(hwnd, WM_GETICON, ICON_BIG, 0) };
    let small = unsafe { SendMessageW(hwnd, WM_GETICON, ICON_SMALL, 0) };
    let small2 = unsafe { SendMessageW(hwnd, WM_GETICON, ICON_SMALL2, 0) };
    if trace_enabled() {
        // WHICH SLOT ANSWERED: `AppWindow.SetIcon` routes through the
        // window's USER32 icon state, so all three types answer the same
        // non-zero handle and `WM_GETICON` is an honest read of what the
        // shell will draw (measured 2026-08-18 on the VM;
        // docs/app-identity-plan.md I8).
        eprintln!(
            "kaya: winui app icon: WM_GETICON big={big:#x} small={small:#x} small2={small2:#x}"
        );
    }
    let Some(icon) = [big, small, small2].into_iter().find(|h| *h != 0) else {
        let class_icon = unsafe { GetClassLongPtrW(hwnd, GCLP_HICON) };
        return format!(
            "<the window holds no icon of its own: WM_GETICON answered 0 for BIG, \
             SMALL and SMALL2; the window CLASS's icon is {}>",
            if class_icon == 0 { "absent too" } else { "what the shell draws" }
        );
    };
    match icon_quadrants(icon) {
        Ok(samples) => samples,
        Err(why) => format!("<the window's icon could not be sampled: {why}>"),
    }
}

/// An HICON's four quadrant centres as `RRGGBB/RRGGBB/RRGGBB/RRGGBB`, in
/// reading order: top-left, top-right, bottom-left, bottom-right.
///
/// CENTRES AND NOT CORNERS: any rescale between the declared PNG and the
/// size this platform rasterizes an icon at blurs a quadrant BOUNDARY, and
/// a corner sample sits on one.
#[cfg(feature = "harness")]
fn icon_quadrants(icon: isize) -> Result<String, String> {
    let mut info = IconInfo::default();
    if unsafe { GetIconInfo(icon, &mut info) } == 0 {
        return Err("GetIconInfo refused the handle".to_owned());
    }
    // Both bitmaps are OURS to free once GetIconInfo has handed them over,
    // and a leak here would run once per read on a polling verb.
    let colour = info.color;
    let mask = info.mask;
    let result = icon_quadrants_of_bitmap(colour);
    if mask != 0 {
        unsafe { DeleteObject(mask) };
    }
    if colour != 0 {
        unsafe { DeleteObject(colour) };
    }
    result
}

#[cfg(feature = "harness")]
fn icon_quadrants_of_bitmap(bitmap: isize) -> Result<String, String> {
    if bitmap == 0 {
        return Err(
            "the icon has no colour bitmap — it is a 1-bit mask icon, which this read \
             cannot sample and no kaya declaration produces"
                .to_owned(),
        );
    }
    let mut header = BitmapHeader::default();
    let size = std::mem::size_of::<BitmapHeader>() as i32;
    if unsafe { GetObjectW(bitmap, size, (&raw mut header).cast::<c_void>()) } == 0 {
        return Err("GetObjectW could not describe the icon's colour bitmap".to_owned());
    }
    let (w, h) = (header.width, header.height);
    if w <= 1 || h <= 1 {
        return Err(format!("the icon's colour bitmap is {w}x{h}, too small to sample"));
    }
    // A TOP-DOWN 32-BIT BI_RGB REQUEST, so the rows arrive in the order the
    // picture is drawn in and every pixel is one BGRA word: the negative
    // height is Win32's own spelling of top-down.
    let mut info = BitmapInfo {
        size: 40,
        width: w,
        height: -h,
        planes: 1,
        bit_count: 32,
        ..BitmapInfo::default()
    };
    let mut pixels: Vec<u32> = vec![0; (w as usize) * (h as usize)];
    let dc = unsafe { CreateCompatibleDC(0) };
    if dc == 0 {
        return Err("CreateCompatibleDC failed".to_owned());
    }
    let lines = unsafe {
        GetDIBits(
            dc,
            bitmap,
            0,
            h as u32,
            pixels.as_mut_ptr().cast::<c_void>(),
            &mut info,
            0,
        )
    };
    unsafe { DeleteDC(dc) };
    if lines == 0 {
        return Err("GetDIBits read no scanlines from the icon's colour bitmap".to_owned());
    }
    let sample = |qx: i32, qy: i32| -> String {
        let x = (w * (1 + 2 * qx) / 4).clamp(0, w - 1) as usize;
        let y = (h * (1 + 2 * qy) / 4).clamp(0, h - 1) as usize;
        let px = pixels[y * (w as usize) + x];
        // BGRA in memory, little-endian, so the word reads 0xAARRGGBB.
        format!("{:06X}", px & 0x00FF_FFFF)
    };
    Ok(format!(
        "{}/{}/{}/{}",
        sample(0, 0),
        sample(1, 0),
        sample(0, 1),
        sample(1, 1)
    ))
}

const WM_CLOSE: u32 = 0x0010;
const WM_CLIPBOARDUPDATE: u32 = 0x031D;
const GWLP_WNDPROC: i32 = -4;

thread_local! {
    /// hwnd -> (kaya window id, the original WNDPROC). UI thread only,
    /// like CORE.
    static KAYA_WNDPROCS: RefCell<HashMap<isize, (u64, isize)>> =
        RefCell::new(HashMap::new());
}

/// The chrome-close grammar, at the Win32 boundary: WM_CLOSE on a
/// veto_close window emits close_requested and is swallowed; on a
/// non-veto auxiliary it reports window_closed and proceeds; the
/// non-veto primary proceeds into the existing Closed handler (app
/// exit). Everything else forwards to the original WNDPROC.
unsafe extern "system" fn kaya_wndproc(
    hwnd: isize,
    msg: u32,
    wparam: usize,
    lparam: isize,
) -> isize {
    let entry = KAYA_WNDPROCS.with_borrow(|m| m.get(&hwnd).copied());
    let Some((id, original)) = entry else {
        return unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) };
    };
    if msg == WM_CLIPBOARDUPDATE {
        // Deferred, never a borrow here: the WNDPROC re-enters CORE
        // by construction (the close path's rule).
        defer_role_refresh();
        return unsafe { CallWindowProcW(original, hwnd, msg, wparam, lparam) };
    }
    if msg == WM_CLOSE {
        let tearing = CORE.with_borrow(|core| {
            core.as_ref()
                .map(|c| c.tearing_down.contains(&id))
                .unwrap_or(false)
        });
        if tearing {
            return unsafe { CallWindowProcW(original, hwnd, msg, wparam, lparam) };
        }
        let veto = CORE.with_borrow(|core| {
            core.as_ref()
                .map(|c| c.window_veto.get(&id).copied().unwrap_or(false))
                .unwrap_or(false)
        });
        if veto {
            CORE.with_borrow(|core| {
                if let Some(c) = core.as_ref() {
                    c.occurrences.send(crate::protocol::Occurrence::CloseRequested {
                        window: crate::protocol::WindowId(id),
                    });
                }
            });
            return 0;
        }
        if id != 0 {
            CORE.with_borrow(|core| {
                if let Some(c) = core.as_ref() {
                    c.occurrences.send(crate::protocol::Occurrence::WindowClosed {
                        window: crate::protocol::WindowId(id),
                    });
                }
            });
        }
    }
    unsafe { CallWindowProcW(original, hwnd, msg, wparam, lparam) }
}

/// Install the close grammar on a window's HWND.
fn subclass(window: &Window, id: u64) -> windows_core::Result<()> {
    let native: IWindowNative = windows_core::Interface::cast(window)?;
    let hwnd = native.window_handle()?;
    unsafe {
        let original = SetWindowLongPtrW(hwnd, GWLP_WNDPROC, kaya_wndproc as isize);
        KAYA_WNDPROCS.with_borrow_mut(|m| {
            m.insert(hwnd, (id, original));
        });
        // Paste's enablement moves when the clipboard does, and the system's
        // own change signal is WM_CLIPBOARDUPDATE — a format listener, not the
        // ancient viewer chain. Registered on every kaya window.
        AddClipboardFormatListener(hwnd);
    }
    Ok(())
}

#[link(name = "user32")]
unsafe extern "system" {
    fn SetWindowPos(
        hwnd: isize,
        insert_after: isize,
        x: i32,
        y: i32,
        cx: i32,
        cy: i32,
        flags: u32,
    ) -> i32;

    fn GetWindowRect(hwnd: isize, rect: *mut Rect) -> i32;
    fn GetClientRect(hwnd: isize, rect: *mut Rect) -> i32;

    /// `canvas_ink`'s camera and the numbers that aim it (see `capture`,
    /// `grab_canvas`, `placement`): a reference DC for the DIB, where this
    /// window's client area sits inside its frame, and DWM's print of the
    /// window's composited content.
    #[cfg(feature = "harness")]
    fn GetDC(hwnd: isize) -> isize;
    #[cfg(feature = "harness")]
    fn ReleaseDC(hwnd: isize, hdc: isize) -> i32;
    #[cfg(feature = "harness")]
    fn ClientToScreen(hwnd: isize, point: *mut Point32) -> i32;
    #[cfg(feature = "harness")]
    fn PrintWindow(hwnd: isize, hdc: isize, flags: u32) -> i32;

    /// The gone-check's three entries, declared here rather than by enabling
    /// Win32_UI_WindowsAndMessaging, which would pull a very large surface
    /// for three.
    fn EnumWindows(
        callback: Option<unsafe extern "system" fn(isize, isize) -> i32>,
        param: isize,
    ) -> i32;
    fn GetClassNameW(hwnd: isize, buf: *mut u16, len: i32) -> i32;
    fn IsWindowVisible(hwnd: isize) -> i32;
    /// The save dialog's overwrite prompt is answered by STRUCTURE, not
    /// by caption; this reads the caption only for the log line that
    /// records the answer happened (`answer_overwrite_prompt`).
    #[cfg(feature = "harness")]
    fn GetWindowTextW(hwnd: isize, buf: *mut u16, len: i32) -> i32;
    fn GetDpiForWindow(hwnd: isize) -> u32;
    fn SetWindowLongPtrW(hwnd: isize, index: i32, value: isize) -> isize;
    // The shortcut verb's REAL dispatch: foreground the guest and put the
    // chord on the system input queue, so XAML's own KeyboardAccelerator
    // machinery routes it (docs/traps.md: WinUI shortcut injection is OS-global,
    // so menu legs run serially).
    fn SetForegroundWindow(hwnd: isize) -> i32;
    fn GetForegroundWindow() -> isize;
    /// The clipboard-change signal Paste's enablement follows
    /// (WM_CLIPBOARDUPDATE to every registered listener).
    fn AddClipboardFormatListener(hwnd: isize) -> i32;
    fn keybd_event(vk: u8, scan: u8, flags: u32, extra: usize);
    /// The `type` verb's character-to-keystroke mapping, asked of the ACTIVE
    /// KEYBOARD LAYOUT rather than hard-coded: the low byte is the virtual
    /// key, the high byte the shift state (bit 0 shift, bit 1 control, bit 2
    /// alt). A table of our own would be a US layout wearing a platform's
    /// name — `!` and `"` do not live on the same keys everywhere.
    #[cfg(feature = "harness")]
    fn VkKeyScanW(ch: u16) -> i16;
    fn CallWindowProcW(
        prev: isize,
        hwnd: isize,
        msg: u32,
        wparam: usize,
        lparam: isize,
    ) -> isize;
    fn DefWindowProcW(hwnd: isize, msg: u32, wparam: usize, lparam: isize) -> isize;

    /// The dialog apartment's loop (`dialog_apartment`): a thread that
    /// owns an STA has to dispatch, and it sleeps on its doorbell and
    /// its message queue at the same time.
    fn PeekMessageW(msg: *mut Msg, hwnd: isize, min: u32, max: u32, remove: u32) -> i32;
    fn DispatchMessageW(msg: *const Msg) -> isize;
    fn MsgWaitForMultipleObjectsEx(
        count: u32,
        handles: *const isize,
        timeout: u32,
        wake_mask: u32,
        flags: u32,
    ) -> u32;

    /// The harness's own calls: the sampler window that lets it ask an STA
    /// object a question from another thread, and the posts that drive the
    /// dialog. EVERY ONE IS GATED, because WndClassW is, and a shipped app
    /// carries none of this (tools/check-targets.py builds both feature
    /// configurations).
    #[cfg(feature = "harness")]
    fn RegisterClassW(class: *const WndClassW) -> u16;
    #[cfg(feature = "harness")]
    fn EnumChildWindows(
        parent: isize,
        callback: Option<unsafe extern "system" fn(isize, isize) -> i32>,
        param: isize,
    ) -> i32;
    #[cfg(feature = "harness")]
    fn GetDlgCtrlID(hwnd: isize) -> i32;
    #[cfg(feature = "harness")]
    #[allow(clippy::too_many_arguments)]
    fn CreateWindowExW(
        ex_style: u32,
        class: *const u16,
        window: *const u16,
        style: u32,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
        parent: isize,
        menu: isize,
        instance: isize,
        param: *mut core::ffi::c_void,
    ) -> isize;
    #[cfg(feature = "harness")]
    fn DestroyWindow(hwnd: isize) -> i32;
    #[cfg(feature = "harness")]
    fn PostMessageW(hwnd: isize, msg: u32, wparam: usize, lparam: isize) -> i32;
}

/// Win32's MSG, for the dialog apartment's loop. Laid out to match
/// winuser.h exactly (POINT inline, no trailing member on Windows).
#[repr(C)]
#[derive(Default)]
struct Msg {
    hwnd: isize,
    message: u32,
    wparam: usize,
    lparam: isize,
    time: u32,
    pt_x: i32,
    pt_y: i32,
}

/// Win32's RECT, for the client/outer chrome math below.
#[repr(C)]
#[derive(Default)]
struct Rect {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
}

/// Win32's POINT, for `ClientToScreen` — named apart from WinRT's
/// `Point`, which this file already uses for XAML's float coordinates.
#[cfg(feature = "harness")]
#[repr(C)]
struct Point32 {
    x: i32,
    y: i32,
}

/// Every window this process is really holding, for the sentence below:
/// `#0, #1`. A resolver miss prints WHAT IT SAW, because the two causes it
/// cannot tell apart are "the id is wrong" and "the apply has not run yet"
/// — an id that never appears is a typo; one that appears a moment later
/// was a race.
fn live_windows(core: &CoreState) -> String {
    let mut ids: Vec<u64> = std::iter::once(0).chain(core.aux_windows.keys().copied()).collect();
    ids.sort_unstable();
    ids.iter()
        .map(|id| format!("#{id}"))
        .collect::<Vec<_>>()
        .join(", ")
}

/// A window by kaya id — TOTAL, because window materialization is
/// asynchronous and a harness read racing the apply is the normal state of
/// affairs (measured 2026-08-16: two windows legs died on an `expect` here,
/// five on linux, when a scene asserted on an aux window without a count
/// barrier). The error is what makes the read RETRYABLE: `on_ui_read` turns
/// it into a non-match and the harness polls again.
fn winui_window(core: &CoreState, id: u64) -> windows_core::Result<Window> {
    if id == 0 {
        return Ok(core.window.clone());
    }
    core.aux_windows.get(&id).cloned().ok_or_else(|| {
        windows_core::Error::new(
            windows_core::HRESULT(0x8000_4005u32 as i32),
            format!(
                "kaya: window#{id} is not materialized; live windows: {}",
                live_windows(core)
            ),
        )
    })
}

/// The advisory size request's Win32 materialization: DIP -> physical via
/// the window's DPI, applied to the CLIENT area (the request is a content
/// size) by carrying the current chrome delta onto the outer frame. A
/// request, never a guarantee (DESIGN.md, Presentation contexts).
fn resize_request(
    window: &Window,
    width: Option<f64>,
    height: Option<f64>,
) -> windows_core::Result<()> {
    let native: IWindowNative = windows_core::Interface::cast(window)?;
    let hwnd = native.window_handle()?;
    unsafe {
        let mut outer = Rect::default();
        let mut client = Rect::default();
        if GetWindowRect(hwnd, &mut outer) == 0 || GetClientRect(hwnd, &mut client) == 0 {
            return Ok(());
        }
        let scale = f64::from(GetDpiForWindow(hwnd)) / 96.0;
        let client_w = f64::from(client.right - client.left);
        let client_h = f64::from(client.bottom - client.top);
        let chrome_w = (outer.right - outer.left) - (client.right - client.left);
        let chrome_h = (outer.bottom - outer.top) - (client.bottom - client.top);
        let target_w = width.map_or(client_w, |w| w * scale).round() as i32 + chrome_w;
        let target_h = height.map_or(client_h, |h| h * scale).round() as i32 + chrome_h;
        const SWP_NOMOVE: u32 = 0x2;
        const SWP_NOZORDER: u32 = 0x4;
        const SWP_NOACTIVATE: u32 = 0x10;
        SetWindowPos(
            hwnd,
            0,
            0,
            0,
            target_w,
            target_h,
            SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE,
        );
    }
    Ok(())
}

fn setup(occ_tx: OccSink, tx_rx: Receiver<Transaction>) -> windows_core::Result<()> {
    let window = Window::new()?;
    // Recording mode tiles parallel legs so per-window captures never
    // overlap, and the slot rides the TITLE so the recorder can name
    // each window's frames unambiguously.
    let slot = std::env::var("KAYA_WIN_SLOT")
        .ok()
        .and_then(|s| s.parse::<i32>().ok());
    let title = match slot {
        Some(n) => format!("kaya milestone 2 [{n}]"),
        None => "kaya milestone 2".to_owned(),
    };
    // THE ONE CAPTION WRITE THAT DOES NOT GO THROUGH refresh_caption, and it
    // cannot: CORE does not exist yet — this is the placeholder the window
    // wears between materializing and the app's first transaction, replaced
    // through the writer a moment later.
    window.SetTitle(&HSTRING::from(&*title))?;
    if let Some(n) = slot {
        let native: IWindowNative = windows_core::Interface::cast(&window)?;
        let hwnd = native.window_handle()?;
        const SWP_NOZORDER: u32 = 0x4;
        const SWP_NOACTIVATE: u32 = 0x10;
        unsafe {
            SetWindowPos(
                hwnd,
                0,
                6 + (n % 2) * 568,
                6 + (n / 2) * 390,
                556,
                378,
                SWP_NOZORDER | SWP_NOACTIVATE,
            );
        }
    }

    // The close grammar (veto/report) rides a WNDPROC subclass; the
    // non-veto primary falls through into the Closed handler below.
    subclass(&window, 0)?;

    let closed = bindings::Windows::Foundation::TypedEventHandler::new(|_, _| {
        request_exit(0);
        Ok(())
    });
    window.Closed(&closed)?;
    window.Activate()?;

    #[cfg(feature = "harness")]
    if let Ok(scene) = std::env::var("KAYA_SELFTEST") {
        let scene = scene.trim().to_owned();
        eprintln!("kaya: winui selftest armed ({scene})");
        crate::harness::spawn(&scene, WinUiStage, |line| println!("{line}"));
    }
    // A build WITHOUT the harness feature must not silently ignore
    // KAYA_SELFTEST: a runner that forgets `--features harness` would
    // otherwise start the app, run no steps, print no verdict, and hang
    // until its timeout. Fail loudly instead, naming the fix.
    #[cfg(not(feature = "harness"))]
    if std::env::var("KAYA_SELFTEST").is_ok() {
        panic!(
            "kaya: KAYA_SELFTEST is set but this build has no harness \
             — rebuild with `--features harness` (it is off by default \
             so shipped apps do not carry the scene interpreter)"
        );
    }


    CORE.with_borrow_mut(|core| {
        *core = Some(CoreState {
            inset: 16.0,
            container_insets: HashMap::new(),
            scroll_root_hosts: HashMap::new(),
            transactions: tx_rx,
            // THIS BACKEND WINDOWS ROWS (docs/deferred.md, the
            // declares-windowing entry): every declared table gets the
            // spacer+band tier.
            scene: {
                let mut scene = Scene::new();
                scene.declare_windowing();
                scene
            },
            occurrences: occ_tx,
            pending_dialog_dir: RefCell::new(None),
            widgets: HashMap::new(),
            parents: HashMap::new(),
            folded_into: HashMap::new(),
            buttons: Vec::new(),
            button_controls: Vec::new(),
            checkboxes: Vec::new(),
            labels: Vec::new(),
            entries: Vec::new(),
            entry_ids: Vec::new(),
            entry_swallow: HashMap::new(),
            entry_tags: HashMap::new(),
            sliders: Vec::new(),
            images: Vec::new(),
            canvases: Vec::new(),
            canvas_ids: Vec::new(),
            scrolls: Vec::new(),
            progresses: Vec::new(),
            selects: Vec::new(),
            radios: Vec::new(),
            grids: Vec::new(),
            textareas: Vec::new(),
            textarea_ids: Vec::new(),
            grid_children: HashMap::new(),
            grid_cols: HashMap::new(),
            radio_options: HashMap::new(),
            select_options: HashMap::new(),
            apply_quiet: std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
            columns: Vec::new(),
            #[cfg(feature = "harness")]
            column_ids: Vec::new(),
            rows: Vec::new(),
            child_order: ChildOrder::default(),
            grow: HashMap::new(),
            aligns: HashMap::new(),
            axes: HashMap::new(),
            spacings: HashMap::new(),
            window,
            aux_windows: HashMap::new(),
            nav_entries: HashMap::new(),
            sections: HashMap::new(),
            section_panes: HashMap::new(),
            section_navs: HashMap::new(),
            section_items: HashMap::new(),
            section_swallow: HashMap::new(),
            ui_selected_sections: HashMap::new(),
            selected_sections: HashMap::new(),
            sections_presentation: HashMap::new(),
            nav_stacks: HashMap::new(),
            panes: HashMap::new(),
            inner_splits: HashMap::new(),
            split_presentation: HashMap::new(),
            split_views: HashMap::new(),
            window_roots: HashMap::new(),
            mounted_roots: HashMap::new(),
            window_titles: HashMap::new(),
            window_dirty: HashMap::new(),
            window_veto: HashMap::new(),
            tearing_down: std::collections::HashSet::new(),
            live_alert: None,
            menu_models: HashMap::new(),
            menu_windows: HashMap::new(),
            context_roots: HashMap::new(),
            context_nouns: HashMap::new(),
            context_flyouts: HashMap::new(),
            menu_natives: HashMap::new(),
            menubars: HashMap::new(),
            menu_slots: HashMap::new(),
            menu_shells: HashMap::new(),
            toolbars: HashMap::new(),
            window_titlebars: HashMap::new(),
            window_caption_texts: HashMap::new(),
            toolbar_buttons: HashMap::new(),
            menu_shortcuts: HashMap::new(),
            open_context: None,
            menus_touched: false,
            accepts: HashMap::new(),
            roles_armed: false,
            banked_text: HashMap::new(),
            ledger_quiet: HashMap::new(),
        });
    });

    // The first transaction may already be queued; drain now.
    drain_transactions();
    Ok(())
}

/// PowerShell single-quoted literal: the only escape is '' for '.
#[cfg(feature = "harness")]
fn ps_quote(s: &str) -> String {
    s.replace('\'', "''")
}

/// The foreign clipboard tool's one entry: powershell.exe, PINNED — pwsh
/// silently lacks the entire clipboard cmdlet surface this lane uses
/// (-AsHtml, -LiteralPath, -Format, -TextFormatType), so the edition is
/// asserted INSIDE the script and a shell swap fails loudly here instead
/// of reading empty. Runs on the harness thread — a child process on the
/// app thread would trip the stall watchdog.
#[cfg(feature = "harness")]
fn run_powershell(script: &str) -> String {
    let guarded = format!(
        "$ErrorActionPreference='Stop'; if ($PSVersionTable.PSEdition -ne 'Desktop') {{ Write-Output 'KAYA_WRONG_EDITION'; exit 1 }}; {script}"
    );
    let out = std::process::Command::new("powershell.exe")
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            &guarded,
        ])
        .output()
        .unwrap_or_else(|e| panic!("kaya: the foreign clipboard tool needs powershell.exe: {e}"));
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    assert!(
        !stdout.contains("KAYA_WRONG_EDITION"),
        "kaya: powershell resolved to a non-Desktop edition — the clipboard \
         cmdlet surface differs there (docs/clipboard-plan.md §6)"
    );
    stdout
}

#[cfg(feature = "harness")]
struct WinUiStage;

/// Take the batch's outstanding track re-stamp before this hop touches the
/// tree (winui/order.rs). Its own borrow, taken and dropped before the
/// caller's: the hops below hand their closure a borrow that lives for the
/// whole dispatched call, and a nested one aborts the process.
#[cfg(feature = "harness")]
fn flush_before_hop() {
    CORE.with_borrow_mut(|core| {
        if let Some(core) = core.as_mut() {
            let _ = flush_tracks(core);
        }
    });
}

#[cfg(feature = "harness")]
impl WinUiStage {
    /// The mutable twin of on_ui, for stage actions that reconcile
    /// core-owned state (select_section's user route).
    fn on_ui_mut<T: Send + 'static>(
        f: impl FnOnce(&mut CoreState) -> windows_core::Result<T> + Send + 'static,
    ) -> T {
        let (tx, rx) = std::sync::mpsc::channel();
        let dispatcher = DISPATCHER.get().expect("the dispatcher is up");
        let cell = std::sync::Mutex::new(Some((f, tx)));
        let handler = DispatcherQueueHandler::new(move || {
            if let Some((f, tx)) = cell.lock().unwrap().take() {
                flush_before_hop();
                CORE.with_borrow_mut(|core| {
                    let core = core.as_mut().expect("core state initialized");
                    let _ = tx.send(f(core));
                });
            }
            Ok(())
        });
        let _ = dispatcher.0.TryEnqueue(&handler);
        rx.recv()
            .expect("the dispatcher applied the step")
            .expect("the step's WinRT calls succeeded")
    }

    fn on_ui<T: Send + 'static>(
        f: impl FnOnce(&CoreState) -> windows_core::Result<T> + Send + 'static,
    ) -> T {
        let (tx, rx) = std::sync::mpsc::channel();
        let dispatcher = DISPATCHER.get().expect("the dispatcher is up");
        let cell = std::sync::Mutex::new(Some((f, tx)));
        let handler = DispatcherQueueHandler::new(move || {
            if let Some((f, tx)) = cell.lock().unwrap().take() {
                flush_before_hop();
                CORE.with_borrow(|core| {
                    let core = core.as_ref().expect("core state initialized");
                    let _ = tx.send(f(core));
                });
            }
            Ok(())
        });
        let _ = dispatcher.0.TryEnqueue(&handler);
        rx.recv()
            .expect("the dispatcher applied the step")
            .expect("the step's WinRT calls succeeded")
    }

    /// Foreground the guest and CONFIRM it before injecting anything, for the
    /// two verbs that put real keys on the SYSTEM INPUT QUEUE (`shortcut` and
    /// `type`): the queue is OS-GLOBAL, so keystrokes would otherwise land in
    /// whatever window is frontmost. A bounded confirmation poll, not a sleep.
    fn foreground_guest(what: &str) {
        let hwnd = Self::on_ui(|core| {
            let native: IWindowNative = windows_core::Interface::cast(&core.window)?;
            native.window_handle()
        });
        let mut confirmed = false;
        for attempt in 0..150 {
            if unsafe { GetForegroundWindow() } == hwnd {
                confirmed = true;
                break;
            }
            unsafe { SetForegroundWindow(hwnd) };
            if attempt == 10 {
                // An ACTIVE MENU categorically blocks SetForegroundWindow —
                // "no menus are active" is one of the documented
                // preconditions, so retrying and the ALT tap below can never
                // win against an open Start menu; ESC dismisses it
                // (docs/traps.md: Whether the desktop will hand over the
                // foreground is invisible from ssh).
                unsafe {
                    keybd_event(0x1B, 0, 0, 0);
                    keybd_event(0x1B, 0, 2, 0);
                }
            }
            if attempt == 50 {
                // The classic foreground-lock release: a bare ALT tap
                // grants the next SetForegroundWindow call.
                unsafe {
                    keybd_event(0x12, 0, 0, 0);
                    keybd_event(0x12, 0, 2, 0);
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        assert!(
            confirmed,
            "kaya: could not foreground the guest window for {what} \
             injection after 3s (an ACTIVE MENU blocks SetForegroundWindow \
             outright — a Start menu or popup left open on the VM is the \
             usual cause; ESC and the ALT foreground-lock release were \
             both tried)"
        );
    }

    /// THE UI THREAD WITHOUT THE CORE — for a call that must not be running
    /// inside a `CORE` borrow when it completes. The other three hops hold
    /// that borrow for the whole dispatched call, so a WinRT call completing
    /// SYNCHRONOUSLY inside one re-enters `CORE` from its completion handler
    /// and aborts (measured 2026-08-10: `ContentDialog::Hide()` on a dialog
    /// that never loaded completes `ShowAsync` right there).
    fn on_ui_bare<T: Send + 'static>(
        f: impl FnOnce() -> windows_core::Result<T> + Send + 'static,
    ) -> windows_core::Result<T> {
        let (tx, rx) = std::sync::mpsc::channel();
        let dispatcher = DISPATCHER.get().expect("the dispatcher is up");
        let cell = std::sync::Mutex::new(Some((f, tx)));
        let handler = DispatcherQueueHandler::new(move || {
            if let Some((f, tx)) = cell.lock().unwrap().take() {
                // Its own borrow, taken and DROPPED before `f` runs —
                // this hop exists precisely so `f` runs outside one.
                flush_before_hop();
                let _ = tx.send(f());
            }
            Ok(())
        });
        let _ = dispatcher.0.TryEnqueue(&handler);
        rx.recv().expect("the dispatcher applied the step")
    }

    /// on_ui_read's mutable twin, for the window verbs: they DRIVE the tier's
    /// report to a fixpoint before answering (`table_settle`), which applies
    /// core ops and therefore needs the core mutably.
    fn on_ui_settled<T: Send + 'static>(
        f: impl FnOnce(&mut CoreState) -> windows_core::Result<T> + Send + 'static,
    ) -> windows_core::Result<T> {
        let (tx, rx) = std::sync::mpsc::channel();
        let dispatcher = DISPATCHER.get().expect("the dispatcher is up");
        let cell = std::sync::Mutex::new(Some((f, tx)));
        let handler = DispatcherQueueHandler::new(move || {
            if let Some((f, tx)) = cell.lock().unwrap().take() {
                flush_before_hop();
                CORE.with_borrow_mut(|core| {
                    let core = core.as_mut().expect("core state initialized");
                    let _ = tx.send(f(core));
                });
            }
            Ok(())
        });
        let _ = dispatcher.0.TryEnqueue(&handler);
        rx.recv().expect("the dispatcher applied the step")
    }

    fn on_ui_read<T: Send + 'static>(
        f: impl FnOnce(&CoreState) -> windows_core::Result<T> + Send + 'static,
    ) -> windows_core::Result<T> {
        let (tx, rx) = std::sync::mpsc::channel();
        let dispatcher = DISPATCHER.get().expect("the dispatcher is up");
        let cell = std::sync::Mutex::new(Some((f, tx)));
        let handler = DispatcherQueueHandler::new(move || {
            if let Some((f, tx)) = cell.lock().unwrap().take() {
                flush_before_hop();
                CORE.with_borrow(|core| {
                    let core = core.as_ref().expect("core state initialized");
                    let _ = tx.send(f(core));
                });
            }
            Ok(())
        });
        let _ = dispatcher.0.TryEnqueue(&handler);
        rx.recv().expect("the dispatcher applied the step")
    }
}

/// The declared table a `column#N` target names, or `None` when that
/// container declared no columns — which is what the empty
/// `columns_presented` answer means.
#[cfg(feature = "harness")]
fn table_of<T>(
    core: &CoreState,
    t: crate::harness::Target,
    f: impl FnOnce(&WinTable) -> T,
) -> Option<T> {
    if !matches!(t.kind, crate::harness::TargetKind::Column) {
        return None;
    }
    let i = crate::harness::try_resolve(t.index, core.columns.len())?;
    let grid = core.columns[i].clone();
    TABLES.with_borrow(|tables| tables.values().find(|table| table.grid == grid).map(f))
}

/// The WIDGET ID a `column#N`/`row#N` target names — the id the window
/// verbs report on and the id TABLES is keyed by. Recovered by COM
/// identity from the creation-ordered registry, the `cross_mode` idiom.
#[cfg(feature = "harness")]
fn container_id(core: &CoreState, t: crate::harness::Target) -> Option<u64> {
    let vertical = matches!(t.kind, crate::harness::TargetKind::Column);
    if !vertical && !matches!(t.kind, crate::harness::TargetKind::Row) {
        return None;
    }
    let registry = if vertical { &core.columns } else { &core.rows };
    let grid = registry[crate::harness::try_resolve(t.index, registry.len())?].clone();
    core.widgets.iter().find_map(|(id, w)| match w {
        NativeWidget::Column(g) | NativeWidget::Row(g) if *g == grid => Some(id.0),
        _ => None,
    })
}

/// THE AXIS THE THREE SCROLL VERBS DRIVE, decided by the target's KIND: a
/// `scroll` target's vertical one, a TABLE target's horizontal one, so no
/// verb needs an axis word (docs/tables-plan.md, the 2026-08-29 overflow
/// ruling).
#[cfg(feature = "harness")]
fn scroll_axis(
    core: &CoreState,
    t: crate::harness::Target,
) -> Option<(ScrollViewer, bool)> {
    if matches!(t.kind, crate::harness::TargetKind::Column) {
        return table_of(core, t, |table| (table.host.clone(), true));
    }
    let i = crate::harness::try_resolve(t.index, core.scrolls.len())?;
    Some((core.scrolls[i].clone(), false))
}

/// A table's stamped rows in the order the TOOLKIT places them — by
/// attached track, never by the registry, because a sort is a MOVE and a
/// creation-order registry cannot see one.
#[cfg(feature = "harness")]
fn table_rows_in_track_order(
    core: &CoreState,
    t: crate::harness::Target,
) -> windows_core::Result<Option<Vec<Grid>>> {
    // THE BAND PANEL, not the container: a windowed table's rows are the
    // scroll host's children (docs/virtualization-plan.md §4), so a walk
    // over the container would find the header and the rule and no row.
    let Some(grid) = table_of(core, t, |table| table.band.clone()) else {
        return Ok(None);
    };
    let children = grid.Children()?;
    let mut rows: Vec<(i32, Grid)> = Vec::new();
    for at in 0..children.Size()? {
        if let Ok(row) = children.GetAt(at)?.cast::<Grid>() {
            if core.rows.iter().any(|r| r == &row) {
                let track = Grid::GetRow(&row.cast::<FrameworkElement>()?)?;
                rows.push((track, row));
            }
        }
    }
    rows.sort_by_key(|(track, _)| *track);
    Ok(Some(rows.into_iter().map(|(_, row)| row).collect()))
}

/// A control's string content, as the header cells carry it.
#[cfg(feature = "harness")]
fn content_string(content: &windows_core::IInspectable) -> windows_core::Result<String> {
    let value: IReference<HSTRING> = content.cast()?;
    Ok(value.Value()?.to_string())
}

/// The WIDTH a container's parent GAVE it — `column_edges`' read, since
/// a table clips across whatever its parent's main axis is. NOT
/// `flex_track` below, which answers along the PARENT's main axis: a
/// column parent's answer here is its own breadth, that one's is a row
/// track's height.
#[cfg(feature = "harness")]
fn assigned_track(core: &CoreState, grid: &Grid) -> windows_core::Result<f64> {
    let element: FrameworkElement = grid.cast()?;
    let Ok(parent) = element.Parent()?.cast::<Grid>() else {
        return grid.ActualWidth();
    };
    if core.columns.iter().any(|g| g == &parent) {
        // A column stacks: every child is offered its whole width.
        let padding = parent.Padding()?;
        return Ok(parent.ActualWidth()? - padding.Left - padding.Right);
    }
    if core.rows.iter().any(|g| g == &parent) {
        let at = Grid::GetColumn(&element)? as u32;
        let defs = parent.ColumnDefinitions()?;
        if at < defs.Size()? {
            return defs.GetAt(at)?.ActualWidth();
        }
    }
    grid.ActualWidth()
}

/// The extent a child DRAWS along one axis of its parent — `vertical` reads
/// height — given the `slot` that parent arranged it in. `ActualWidth` is the
/// USED size, which for a content-sized element is its text and not its box
/// (docs/traps.md: A stretched WinUI TextBlock arranges text-sized), so under
/// a RESOLVED Stretch the box is the slot. An explicit Width/Height outranks
/// Stretch and IS the box, and a Max caps the slot the same way; only a cap
/// can leave a Stretch child short, so no Min is read.
#[cfg(feature = "harness")]
fn drawn_extent(
    element: &FrameworkElement,
    slot: f64,
    vertical: bool,
) -> windows_core::Result<f64> {
    let stretches = if vertical {
        element.VerticalAlignment()? == bindings::Microsoft::UI::Xaml::VerticalAlignment::Stretch
    } else {
        element.HorizontalAlignment()?
            == bindings::Microsoft::UI::Xaml::HorizontalAlignment::Stretch
    };
    if !stretches {
        return if vertical {
            element.ActualHeight()
        } else {
            element.ActualWidth()
        };
    }
    let margin = element.Margin()?;
    let (declared, cap, gutters) = if vertical {
        (
            element.Height()?,
            element.MaxHeight()?,
            margin.Top + margin.Bottom,
        )
    } else {
        (
            element.Width()?,
            element.MaxWidth()?,
            margin.Left + margin.Right,
        )
    };
    let want = if declared.is_nan() {
        (slot - gutters).max(0.0)
    } else {
        declared
    };
    Ok(want.min(cap))
}

/// What a flex parent gave one of its children, along the PARENT's main
/// axis: the track it assigned and the extent the child drew in it.
///
/// `expect_fills` reads it for a WIDGET target and for a grown CONTAINER
/// before its own children are asked anything (tools/scenes/align.steps;
/// the ledger's "a nested SwiftUI container cannot fill its track").
#[cfg(feature = "harness")]
enum FlexTrack {
    In { track: f64, drawn: f64 },
    /// The parent is not one of kaya's flex containers.
    NoParent,
    /// A flex parent, but no track definition holds this child.
    NoTrack,
}

#[cfg(feature = "harness")]
fn flex_track(core: &CoreState, element: &FrameworkElement) -> windows_core::Result<FlexTrack> {
    let Ok(grid) = element.Parent()?.cast::<Grid>() else {
        return Ok(FlexTrack::NoParent);
    };
    // The container's own registry decides the axis, the way reindex
    // decided it when it built the tracks — never the element's shape.
    let vertical = core.columns.iter().any(|g| g == &grid);
    if !vertical && !core.rows.iter().any(|g| g == &grid) {
        return Ok(FlexTrack::NoParent);
    }
    // Measure/arrange are lazy; force them or the first read after
    // mount sees zeros (the child_shares precedent).
    grid.UpdateLayout()?;
    // The track is the definition's RESOLVED extent — measured pixels, never
    // the star weight — and the drawn size is the child's box
    // (`drawn_extent`, which is NOT ActualWidth for a content-sized
    // element).
    if vertical {
        let at = Grid::GetRow(element)? as u32;
        let defs = grid.RowDefinitions()?;
        if at >= defs.Size()? {
            return Ok(FlexTrack::NoTrack);
        }
        let track = defs.GetAt(at)?.ActualHeight()?;
        Ok(FlexTrack::In {
            track,
            drawn: drawn_extent(element, track, true)?,
        })
    } else {
        let at = Grid::GetColumn(element)? as u32;
        let defs = grid.ColumnDefinitions()?;
        if at >= defs.Size()? {
            return Ok(FlexTrack::NoTrack);
        }
        let track = defs.GetAt(at)?.ActualWidth()?;
        Ok(FlexTrack::In {
            track,
            drawn: drawn_extent(element, track, false)?,
        })
    }
}

/// The element a `kind#index` target names, from the per-kind registry every
/// WinUI verb resolves through — creation order, which is what `kind#index`
/// means. `None` is "no such target", never a panic. ONE copy of the
/// registry table: two is the shape that ships one kind wired to the wrong
/// Vec.
#[cfg(feature = "harness")]
fn target_element(
    core: &CoreState,
    target: crate::harness::Target,
) -> windows_core::Result<Option<bindings::Microsoft::UI::Xaml::UIElement>> {
    use crate::harness::{try_resolve, TargetKind as K};
    macro_rules! nth {
        ($reg:expr) => {
            match try_resolve(target.index, $reg.len()) {
                Some(i) => $reg[i].cast()?,
                None => return Ok(None),
            }
        };
    }
    Ok(Some(match target.kind {
        K::Checkbox => nth!(core.checkboxes),
        K::Entry => nth!(core.entries),
        K::Textarea => nth!(core.textareas),
        K::Label => nth!(core.labels),
        K::Slider => nth!(core.sliders),
        K::Row => nth!(core.rows),
        K::Column => nth!(core.columns),
        K::Image => nth!(core.images),
        K::Progress => nth!(core.progresses),
        K::Select => nth!(core.selects),
        K::Radio => nth!(core.radios),
        K::Grid => nth!(core.grids),
        K::Scroll => nth!(core.scrolls),
        K::Canvas => nth!(core.canvases),
        // Buttons live in the registry as CLICK TAGS, not widgets, and the tag
        // is captured in the click closure rather than stored on the Button,
        // so there is no tag->widget link to follow. Both orderings are
        // CREATION order, so the Nth button widget by ascending id is the Nth
        // entry — and the ids must be sorted explicitly, because core.widgets
        // is a HashMap.
        K::Button => {
            if try_resolve(target.index, core.buttons.len()).is_none() {
                return Ok(None);
            }
            let i = crate::harness::resolve(target.index, core.buttons.len());
            let mut ids: Vec<_> = core
                .widgets
                .iter()
                .filter(|(_, w)| matches!(w, NativeWidget::Button { .. }))
                .map(|(id, _)| *id)
                .collect();
            ids.sort_by_key(|id| id.0);
            match ids.get(i).and_then(|id| core.widgets.get(id)) {
                Some(NativeWidget::Button { button, .. }) => button.cast()?,
                _ => return Ok(None),
            }
        }
    }))
}

#[cfg(feature = "harness")]
impl crate::harness::Stage for WinUiStage {
    fn menu_activate(&self, path: &str) {
        let spec = path.to_owned();
        // Resolve SEMANTICALLY against the model tree — the OPEN context menu
        // exclusively while one is presented, the primary window's catalog
        // otherwise — then drive the REAL invoke pipeline. For a context
        // activation: register Closed BEFORE invoking, keep the flyout handle
        // through Closed, and await it before another open may start.
        let wait = Self::on_ui_mut(move |core| {
            // THE HARNESS-ACTIVATION REFRESH, load-bearing beyond a grayed row:
            // Invoke() on a still-disabled item THROWS inside a dispatcher
            // callback — a stowed exception, 0xC000027B, process gone — and
            // focus changes refresh enablement on a DEFERRED tick, so without
            // this a focus-then-activate script races that tick.
            if core.roles_armed {
                refresh_role_enablement(core);
            }
            let (roots, flyout, attachment) = match &core.open_context {
                Some((widget, flyout)) => (
                    core.context_roots.get(widget).cloned().unwrap_or_default(),
                    Some(flyout.clone()),
                    MenuAttachment::Context(*widget),
                ),
                None => (
                    core.menu_windows.get(&0).cloned().unwrap_or_default(),
                    None,
                    MenuAttachment::Window(0),
                ),
            };
            let Some(item) = resolve_menu_path(core, &spec, &roots) else {
                panic!("kaya: no such menu item {spec:?}");
            };
            // The OPEN attachment's own instance: the anchor-qualified
            // key is what makes a stamped row invoke ITS copy — never
            // whichever copy an arbitrary rebuild order built last
            // (the keys ARE the noun; docs/traps.md).
            let Some(native) = core.menu_natives.get(&(attachment, item)).cloned() else {
                // A grouping node whose materialization mints no
                // chrome of its own: nothing to activate (parity with
                // the interpreters' silent grouping arm).
                return Ok(None);
            };
            let closed = match &flyout {
                Some(flyout) => {
                    let (tx, rx) = std::sync::mpsc::channel::<()>();
                    let armed = std::sync::Mutex::new(Some(tx));
                    let handler = bindings::Windows::Foundation::EventHandler::<
                        windows_core::IInspectable,
                    >::new(move |_, _| {
                        if let Some(tx) = armed.lock().unwrap().take() {
                            let _ = tx.send(());
                        }
                        Ok(())
                    });
                    flyout.Closed(&handler)?;
                    Some(rx)
                }
                None => None,
            };
            // Deferred one dispatcher tick: the item's Click handler
            // re-borrows CORE, which this closure holds (the back()
            // precedent). The flyout handle rides the closure so it
            // outlives even the anchor row's destruction — the item's
            // occurrence may remove its stamped anchor before event
            // cleanup runs (docs/traps.md).
            let queue = DispatcherQueue::GetForCurrentThread()?;
            let keep = flyout.clone();
            let handler = DispatcherQueueHandler::new(move || {
                let _keep = &keep;
                invoke_menu_native(&native)
            });
            queue.TryEnqueue(&handler)?;
            Ok(closed)
        });
        if let Some(rx) = wait {
            rx.recv_timeout(std::time::Duration::from_secs(10)).expect(
                "kaya: the context flyout never closed after the activation (Closed did not arrive)",
            );
            Self::on_ui_mut(|core| {
                core.open_context = None;
                Ok(())
            });
        }
    }

    fn context_open(&self, t: crate::harness::Target) {
        // The REAL presentation path: ShowAt on the anchor's own
        // ContextFlyout. ShowAt is a request, not a readiness
        // boundary (docs/traps.md): Opened is registered BEFORE the
        // request and this step does not complete until it arrives —
        // the following menu_activate then acts on a live presenter.
        let opened = Self::on_ui_mut(move |core| {
            // A lingering open menu would let this open overtake its
            // close animation; the scene grammar always activates
            // first, so this is the loud belt, not the path.
            if let Some((_, previous)) = core.open_context.take() {
                let _ = previous.Hide();
            }
            let widget = widget_id_for_target(core, t);
            let flyout = core.context_flyouts.get(&widget).cloned().unwrap_or_else(|| {
                panic!("kaya: no context menu attached to {t:?}")
            });
            let (tx, rx) = std::sync::mpsc::channel::<()>();
            let armed = std::sync::Mutex::new(Some(tx));
            let handler = bindings::Windows::Foundation::EventHandler::<
                windows_core::IInspectable,
            >::new(move |_, _| {
                if let Some(tx) = armed.lock().unwrap().take() {
                    let _ = tx.send(());
                }
                Ok(())
            });
            flyout.Opened(&handler)?;
            let anchor: FrameworkElement = core
                .widgets
                .get(&WidgetId(widget))
                .expect("the anchor widget lives")
                .element()?
                .cast()?;
            flyout.ShowAt(&anchor)?;
            core.open_context = Some((widget, flyout));
            Ok(rx)
        });
        opened
            .recv_timeout(std::time::Duration::from_secs(10))
            .expect("kaya: the context flyout never opened (Opened did not arrive)");
    }

    fn menu_count(&self) -> usize {
        // The REAL bar chrome's top-level count, never the model map
        // (the section_count precedent).
        Self::on_ui_read(|core| {
            Ok(core
                .menubars
                .get(&0)
                .map(|bar| bar.Items()?.Size().map(|n| n as usize))
                .transpose()?
                .unwrap_or(0))
        })
        .unwrap_or(0)
    }

    fn ax(&self, target: crate::harness::Target) -> String {
        //
        // Read UIA's own peer, not kaya's model: FrameworkElementAutomationPeer
        // is what an assistive client sees. Correspondence is by IDENTITY,
        // through WinUI's settable AutomationId.
        Self::on_ui_read(move |core| {
            use bindings::Microsoft::UI::Xaml::Automation::Peers::{
                AutomationHeadingLevel, FrameworkElementAutomationPeer,
            };
            // Resolve the ELEMENT from the per-kind registry, the way every
            // other WinUI verb does (read_label/read_text), with try_resolve
            // so an out-of-range index reports "no such target" instead of
            // panicking inside the UI closure, where it surfaces as an opaque
            // RecvError.
            use crate::harness::{try_resolve, TargetKind as K};
            let element: bindings::Microsoft::UI::Xaml::UIElement =
                match target_element(core, target)? {
                    Some(e) => e,
                    None => return Ok("<no such target>".to_owned()),
                };
            let fe: bindings::Microsoft::UI::Xaml::FrameworkElement = element.cast()?;
            // FromElement returns an EXISTING peer; a plain container (Row and
            // Column are Grids) has none until one is made, so it reported
            // "<not in the accessibility tree>" for a group UIA is perfectly
            // willing to describe. CreatePeerForElement makes one on demand,
            // and falls back to FromElement for controls that carry theirs.
            let peer = match FrameworkElementAutomationPeer::CreatePeerForElement(&fe) {
                Ok(p) => p,
                Err(_) => match FrameworkElementAutomationPeer::FromElement(&fe) {
                    Ok(p) => p,
                    Err(_) => return Ok("<not in the accessibility tree>".to_owned()),
                },
            };
            let kind = peer.GetAutomationControlType()?;
            // THE HEADING ROLE IS A PROPERTY READ, NOT A TYPE READ: a heading
            // is not a control TYPE in UIA — a TextBlock carrying HeadingLevel
            // still reports `Text` — so `ax_role`'s ladder could never see it.
            // `?` rather than a swallowed default, so a failed property read
            // surfaces as `<accessibility read failed>`. The read asks the
            // PEER and never leaves this process: an out-of-process UIA client
            // is barred at the Cargo.toml.
            let role = ax_role(
                peer.GetHeadingLevel()? != AutomationHeadingLevel::None,
                kind,
            );
            if role == UNMAPPED_ROLE {
                // The role the platform published is one kaya has no name for
                // — the finding this verb exists to surface, and the next
                // question is always WHICH one.
                eprintln!("KAYA_AX_TRACE: unmapped UIA control type {kind:?} for {target:?}");
            }
            let name = peer.GetName()?.to_string();
            // A text field with no authored label publishes an EMPTY UIA Name;
            // its content lives on the ValuePattern, the same fallback chain
            // the other platforms take. The two kinds answer through DIFFERENT
            // patterns (TextBox ValuePattern, RichEditBox TextPattern,
            // measured), which does not matter: kaya asks the CONTROL, whose
            // TYPE is `Edit` for both.
            let name = if name.is_empty()
                && matches!(target.kind, K::Entry | K::Textarea)
            {
                match target.kind {
                    K::Entry => try_resolve(target.index, core.entries.len())
                        .map(|i| lf(core.entries[i].Text().map(|t| t.to_string()).unwrap_or_default()))
                        .unwrap_or_default(),
                    _ => try_resolve(target.index, core.textareas.len())
                        .map(|i| {
                            lf(Editable::Textarea(core.textareas[i].clone())
                                .text()
                                .unwrap_or_default())
                        })
                        .unwrap_or_default(),
                }
            } else {
                name
            };
            Ok(format!("{role}/{name}"))
        })
        .unwrap_or_else(|_| "<accessibility read failed>".to_owned())
    }

    /// THE DECORATED RANGES, out of the control's own document model and NOT
    /// the accessibility tree: WinUI's in-process peer for a text control
    /// publishes no Text pattern at all (`GetPattern(Text)` is NULL on both),
    /// so `GetAttributeValue(BackgroundColor)` has no provider here, and the
    /// only route that publishes it is an out-of-process UIA client, barred at
    /// the Cargo.toml (docs/traps.md: UI Automation cannot read the Shell's
    /// file dialog from a guest).
    fn highlights(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            let Some(i) = crate::harness::try_resolve(t.index, core.textareas.len()) else {
                return Ok("<no such target>".to_string());
            };
            let field = core.textareas[i].clone();
            let text = lf(Editable::Textarea(field.clone()).text()?);
            let units = text.encode_utf16().count() as i32;
            Ok(range_spelling(&text, &painted_runs(&field, units)?))
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    /// The selection, from the document model that owns it. A caret is
    /// the empty range and reads as `12:12=`.
    fn selection(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            let Some(i) = crate::harness::try_resolve(t.index, core.textareas.len()) else {
                return Ok("<no such target>".to_string());
            };
            let field = core.textareas[i].clone();
            let text = lf(Editable::Textarea(field.clone()).text()?);
            let selection = field.TextDocument()?.Selection()?;
            let (start, stop) = (selection.StartPosition()?, selection.EndPosition()?);
            Ok(range_spelling(&text, &[(start, stop)]))
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    /// WHETHER A RANGE IS IN THE VIEWPORT — containment, never the viewport
    /// itself, and FROM THE VIEWPORT rather than from a model:
    /// `ITextRange::GetRect` in CLIENT coordinates is where the range sits
    /// relative to what is on screen RIGHT NOW. `AllowOffClient` is what makes
    /// the negative answer real — without it an off-screen range has no
    /// rectangle and the verb could only ever say "visible".
    fn revealed(
        &self, t: crate::harness::Target, range: crate::harness::TextRange,
    ) -> String {
        Self::on_ui_read(move |core| {
            let Some(i) = crate::harness::try_resolve(t.index, core.textareas.len()) else {
                return Ok("<no such target>".to_string());
            };
            let field = core.textareas[i].clone();
            let text = lf(Editable::Textarea(field.clone()).text()?);
            // The verb's range arrives in the protocol's UTF-8 byte
            // offsets; the control counts UTF-16 code units.
            let (Some(start), Some(stop)) = (
                utf16_offset(&text, range.start as usize),
                utf16_offset(&text, range.stop as usize),
            ) else {
                return Ok("<offset is not a character boundary>".to_string());
            };
            let (top, bottom) = range_extent(&field, start, stop)?;
            let viewer = template_scroll(&field)?;
            let (at, viewport) = (viewer.VerticalOffset()?, viewer.ViewportHeight()?);
            // Containment in the viewport the control is actually showing —
            // this platform's spelling of mac's AXVisibleCharacterRange.
            let inside = top >= at - 0.5 && bottom <= at + viewport + 0.5;
            Ok(if inside { "visible" } else { "offscreen" }.to_string())
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    /// AN INPUT METHOD'S COMPOSITION, STARTED THROUGH THE INPUT METHOD'S OWN
    /// MACHINERY (docs/ranges-plan.md D4). Windows has no "insert marked text"
    /// call — a composition belongs to the Text Services Framework — so this
    /// does what a text service does (`tsf_compose`). Inserting the text and
    /// calling it a composition is the very state D4's refusal must
    /// distinguish it from.
    fn compose(&self, t: crate::harness::Target, text: &str) {
        let marked = text.to_owned();
        // The control must have the keyboard focus, or TSF's focused
        // document is somebody else's (or nothing at all).
        let id = Self::on_ui(move |core| {
            let Some(i) = crate::harness::try_resolve(t.index, core.textareas.len()) else {
                return Ok(0u64);
            };
            let field = core.textareas[i].clone();
            let end = Editable::Textarea(field.clone()).text()?.encode_utf16().count() as i32;
            // The composition goes in where the caret is, and a composition
            // parks the caret at the END of its marked text — so the end of
            // the document is where the scene's arithmetic starts
            // (813 bytes + " z" + "nihon" = 820).
            field.Focus(FocusState::Programmatic)?;
            field.TextDocument()?.Selection()?.SetRange(end, end)?;
            Ok(core.textarea_ids[i])
        });
        if id == 0 {
            eprintln!("kaya: compose: no such target");
            return;
        }
        if let Err(trouble) = Self::on_ui(move |_| Ok(tsf_compose(&marked))) {
            eprintln!("kaya: compose: {trouble}");
            return;
        }
        // Blocking, like type_text: the state under test is the
        // composition, and the control saying it started is the only
        // report that it is live.
        for _ in 0..200 {
            if Self::on_ui_read(move |_| Ok(COMPOSING.with_borrow(|live| live.contains(&id))))
                .unwrap_or(false)
            {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        eprintln!(
            "kaya: compose: the composition was started but the control never raised \
             TextCompositionStarted within 1s — D4's refusal keys on that event, so a \
             select_range arriving now would be HONOURED"
        );
    }

    fn ax_hint(&self, target: crate::harness::Target) -> String {
        // UIA's HelpText is the hint slot: "a brief description of the
        // control's purpose", read off the same peer `ax` reads.
        Self::on_ui_read(move |core| {
            use bindings::Microsoft::UI::Xaml::Automation::Peers::FrameworkElementAutomationPeer;
            use crate::harness::{try_resolve, TargetKind as K};
            let element: bindings::Microsoft::UI::Xaml::UIElement = match target.kind {
                K::Checkbox => match try_resolve(target.index, core.checkboxes.len()) {
                    Some(i) => core.checkboxes[i].cast()?,
                    None => return Ok("<no such target>".to_owned()),
                },
                K::Select => match try_resolve(target.index, core.selects.len()) {
                    Some(i) => core.selects[i].cast()?,
                    None => return Ok("<no such target>".to_owned()),
                },
                K::Radio => match try_resolve(target.index, core.radios.len()) {
                    Some(i) => core.radios[i].cast()?,
                    None => return Ok("<no such target>".to_owned()),
                },
                K::Button => {
                    if try_resolve(target.index, core.buttons.len()).is_none() {
                        return Ok("<no such target>".to_owned());
                    }
                    let i = crate::harness::resolve(target.index, core.buttons.len());
                    let mut ids: Vec<_> = core
                        .widgets
                        .iter()
                        .filter(|(_, w)| matches!(w, NativeWidget::Button { .. }))
                        .map(|(id, _)| *id)
                        .collect();
                    ids.sort_by_key(|id| id.0);
                    match ids.get(i).and_then(|id| core.widgets.get(id)) {
                        Some(NativeWidget::Button { button, .. }) => button.cast()?,
                        _ => return Ok("<no such target>".to_owned()),
                    }
                }
                // The root admits a11y_hint on activation kinds only.
                _ => {
                    return Ok("<the hint prop applies to activation kinds only>".to_owned())
                }
            };
            let fe: bindings::Microsoft::UI::Xaml::FrameworkElement = element.cast()?;
            let peer = match FrameworkElementAutomationPeer::CreatePeerForElement(&fe) {
                Ok(p) => p,
                Err(_) => match FrameworkElementAutomationPeer::FromElement(&fe) {
                    Ok(p) => p,
                    Err(_) => return Ok("<not in the accessibility tree>".to_owned()),
                },
            };
            Ok(peer.GetHelpText()?.to_string())
        })
        .unwrap_or_else(|_| "<accessibility read failed>".to_owned())
    }

    fn resize_window(&self, window: u64, width: f64, height: f64) {
        Self::on_ui_mut(move |core| {
            // The REAL resize, through the same DPI-aware path the width and
            // height props drive — and then RE-RUN the arm: changing the size
            // without letting the platform re-decide gates nothing.
            let target = winui_window(core, window)?;
            resize_request(&target, Some(width), Some(height))?;
            // FORCE A LAYOUT PASS before re-running the arm. SetWindowPos
            // returns before XAML has re-measured, so the arm asked for a
            // width that was still the OLD one — it stamped `stacked` while
            // the read, a beat later, said `regular`.
            if let Ok(content) = target.Content() {
                if let Ok(root) = content.cast::<FrameworkElement>() {
                    let _ = root.UpdateLayout();
                }
            }
            refresh_nav(core, window)?;
            Ok(())
        })
    }

    fn split_presentation(&self) -> String {
        Self::on_ui_read(|core| {
            // The class comes from XamlRoot's real size, the same 600 boundary
            // menu_presentation draws; the presentation from the arm that
            // actually ran. UNREADABLE until the element is in a live visual
            // tree, and this verb is asked within milliseconds of launch:
            // `unknown` is a legal class in the grammar for exactly that
            // state, and the harness POLLS. The SAME source the arm used.
            let class = match window_client_width(core, 0) {
                Some(w) if w >= 600.0 => "regular",
                Some(_) => "compact",
                None => "unknown",
            };
            // THE CONTROLS' OWN ANSWER, not a value the arm stamped about
            // itself: Windows decides where one pane becomes two, so at a
            // ceiling of three BOTH controls are folded. A window that never
            // asked for panes has no control, and falls back to the serial
            // arm's stamp.
            let presentation = match (
                core.split_views.get(&0).map(|v| v.Mode()),
                core.inner_splits.get(&0).map(|v| v.Mode()),
            ) {
                (Some(Ok(outer)), Some(Ok(inner))) => {
                    let wide = |m: TwoPaneViewMode| m != TwoPaneViewMode::SinglePane;
                    match (wide(outer), wide(inner)) {
                        (true, true) => "split3",
                        (true, false) | (false, true) => "split",
                        (false, false) => "stacked",
                    }
                }
                (Some(Ok(mode)), None) if mode != TwoPaneViewMode::SinglePane => "split",
                (Some(Ok(_)), None) => "stacked",
                _ => core.split_presentation.get(&0).copied().unwrap_or("stacked"),
            };
            Ok(format!("{class}/{presentation}"))
        })
        // The same fallback menu_presentation uses: a read that cannot reach
        // the UI thread reports `unknown`, and the harness retries.
        .unwrap_or_else(|_| "unknown/stacked".to_owned())
    }

    fn panes_reading(&self) -> String {
        // The nested TwoPaneViews' own Modes when a nest is up; the two-pane
        // worlds keep the derivation, which is exact there.
        Self::on_ui_read(|core| {
            let class = match window_client_width(core, 0) {
                Some(w) if w >= 600.0 => "regular",
                Some(_) => "compact",
                None => "unknown",
            };
            if let Some(positions) = three_pane_positions(core, 0) {
                let spelled = if positions.is_empty() {
                    "-".to_owned()
                } else {
                    positions
                        .iter()
                        .map(u64::to_string)
                        .collect::<Vec<_>>()
                        .join(",")
                };
                return Ok(format!("{class}/{spelled}"));
            }
            let presentation = match core.split_views.get(&0).map(|v| v.Mode()) {
                Some(Ok(mode)) if mode != TwoPaneViewMode::SinglePane => "split",
                Some(Ok(_)) => "stacked",
                _ => core.split_presentation.get(&0).copied().unwrap_or("stacked"),
            };
            let entries = core.nav_stacks.get(&0).map_or(0, |s| s.len());
            Ok(format!(
                "{class}/{}",
                crate::harness::panes_positions(presentation, entries)
            ))
        })
        .unwrap_or_else(|_| "unknown/-".to_owned())
    }

    fn menu_presentation(&self) -> String {
        // XAML has no size-class type; its own adaptive triggers are width
        // thresholds (`MinWindowWidth`), so a width rule IS the platform
        // idiom here. Same 600 boundary as the others.
        Self::on_ui_read(|core| {
            let target = winui_window(core, 0)?;
            let root: FrameworkElement = target.Content()?.cast()?;
            let width = f64::from(root.XamlRoot()?.Size()?.Width);
            let class = if width >= 600.0 { "regular" } else { "compact" };
            // Read off the REAL chrome, like menu_count: a MenuBar with
            // items or nothing. WinUI has only the bar lowering.
            let bar = core
                .menubars
                .get(&0)
                .map(|bar| bar.Items()?.Size().map(|n| n > 0))
                .transpose()?
                .unwrap_or(false);
            Ok(format!("{class}/{}", if bar { "bar" } else { "none" }))
        })
        .unwrap_or_else(|_| "unknown/none".to_owned())
    }

    fn menu_state(&self, path: &str, aspect: crate::harness::MenuAspect) -> String {
        use crate::harness::MenuAspect;
        let path = path.to_owned();
        Self::on_ui_read(move |core| {
            // THE HARNESS *READ* NEEDS THE SAME FRESHNESS THE ACTIVATION HAS.
            // menu_activate and shortcut both refresh before they act; a read
            // that did not answered with whatever enablement the item last
            // had stamped on it, and no scene caught it, because none until
            // undo.steps asserts an enablement that MOVES with no menu
            // traffic in between (typing changes what Edit>Undo can do).
            if core.roles_armed {
                refresh_role_enablement(core);
            }
            // Open-context EXCLUSIVITY: while presented, the context
            // menu owns resolution — a miss reads as the retryable
            // "no such item", never a bar fallback.
            let (roots, attachment) = match &core.open_context {
                Some((widget, _)) => (
                    core.context_roots.get(widget).cloned().unwrap_or_default(),
                    MenuAttachment::Context(*widget),
                ),
                None => (
                    core.menu_windows.get(&0).cloned().unwrap_or_default(),
                    MenuAttachment::Window(0),
                ),
            };
            let Some(item) = resolve_menu_path(core, &path, &roots) else {
                return Ok("no such item".to_owned());
            };
            Ok(match aspect {
                MenuAspect::Enablement => match core.menu_natives.get(&(attachment, item)) {
                    // The REAL item's flag — the rebuild stamps the
                    // inherited AND onto every native, so a backend
                    // that ignored the write must fail here.
                    Some(native) => if native.is_enabled()? {
                        "enabled"
                    } else {
                        "disabled"
                    }
                    .to_owned(),
                    // An inline nested grouping node mints no titled
                    // chrome (mac segment parity).
                    None => "no such item".to_owned(),
                },
                MenuAspect::Checkedness => match core.menu_natives.get(&(attachment, item)) {
                    Some(MenuNative::Toggle(native)) => if native.IsChecked()? {
                        "checked"
                    } else {
                        "unchecked"
                    }
                    .to_owned(),
                    Some(MenuNative::Option(native)) => if native.IsChecked()? {
                        "checked"
                    } else {
                        "unchecked"
                    }
                    .to_owned(),
                    Some(_) => "unchecked".to_owned(),
                    None => "no such item".to_owned(),
                },
                MenuAspect::Value => {
                    // The group's value IS its checked option, read
                    // from the REAL radio rows (the checkmark idiom).
                    let children = core
                        .menu_models
                        .get(&item)
                        .map(|m| m.children.clone())
                        .unwrap_or_default();
                    let mut found = None;
                    for (index, child) in children.iter().enumerate() {
                        if let Some(MenuNative::Option(radio)) =
                            core.menu_natives.get(&(attachment, *child))
                        {
                            if radio.IsChecked()? {
                                found = Some(index);
                                break;
                            }
                        }
                    }
                    match found {
                        Some(index) => format!("value {index}"),
                        None => "no checked option".to_owned(),
                    }
                }
            })
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn menu_symbol(&self, path: &str) -> String {
        let path = path.to_owned();
        // FROM UIA, NEVER FROM THE MODEL: the answer is the name the icon in
        // the REAL item's Icon slot publishes to its automation peer, so a
        // backend that decoded the symbol prop and drew nothing fails this
        // read, and so does one that drew an icon and named it wrong.
        Self::on_ui_read(move |core| {
            // NO REFRESH STEP HERE, unlike menu_state: a symbol changes only
            // through a prop write, which forces the coalesced rebuild before
            // this read can run. Open-context EXCLUSIVITY, as menu_state has
            // it: while a context menu is presented it owns resolution.
            let (roots, attachment) = match &core.open_context {
                Some((widget, _)) => (
                    core.context_roots.get(widget).cloned().unwrap_or_default(),
                    MenuAttachment::Context(*widget),
                ),
                None => (
                    core.menu_windows.get(&0).cloned().unwrap_or_default(),
                    MenuAttachment::Window(0),
                ),
            };
            let Some(item) = resolve_menu_path(core, &path, &roots) else {
                return Ok("no such item".to_owned());
            };
            let Some(native) = core.menu_natives.get(&(attachment, item)) else {
                // An inline nested grouping node mints no chrome of its
                // own (the enablement read's rule).
                return Ok("no such item".to_owned());
            };
            Ok(match native.icon() {
                MenuIcon::Present(icon) => icon_uia_name(&icon),
                // WHAT THIS MEASURED: the item is in the real menu and its
                // icon slot is empty. It deliberately does NOT say whether the
                // app asked for one — this reader cannot tell "no symbol
                // declared" from "declared and never lowered" (CLAUDE.md
                // invariant 3).
                MenuIcon::Empty => "no icon on the menu item".to_owned(),
                // The one honest answer for a top-level bar grouping: WinUI's
                // MenuBarItem has no icon slot at all, so "no icon" here would
                // point the reader at the app instead of the platform.
                MenuIcon::NoSlot => {
                    "a WinUI MenuBarItem has no icon slot (top-level menu)".to_owned()
                }
                MenuIcon::Unreadable(e) => format!("the item's icon slot could not be read: {e}"),
            })
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    /// THE expect_toolbar READ ON WINUI, from three sides so no single mistake
    /// can make all of it agree: the CATALOG's promotion count, the REAL
    /// CommandBar's items and published names, and the REAL MenuBar's
    /// remainder home. ADDRESSED BY WHAT UIA PUBLISHES: an `AppBarButton`'s
    /// name comes from its `Label` (measured on the VM 2026-08-17), so a
    /// lowering that promoted the right items and never labelled them fails
    /// here. The remainder's home is the menu bar, or the read says `none`.
    fn toolbar_chrome(&self) -> String {
        Self::on_ui_read(|core| {
            toolbar_trace(core, 0);
            let promoted: Vec<String> = promoted_items(core, 0)
                .iter()
                .filter_map(|id| core.menu_models.get(id).map(|m| m.label.clone()))
                .collect();
            let (held, buttons) = toolbar_read(core, 0)?;
            let home = toolbar_remainder_home(core, 0)?;
            // IN CATALOG PREORDER, matched greedily against the bar's own
            // order: `found` counts how far the promotion list can be walked
            // through the names the chrome really publishes.
            let mut found = 0;
            for (name, _) in &buttons {
                if found < promoted.len() && name.as_bytes() == promoted[found].as_bytes() {
                    found += 1;
                }
            }
            Ok(format!("{found}/{}/{held}/{home}", promoted.len()))
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    /// THE expect_toolbar_item READ: one aspect of the real `AppBarButton`,
    /// addressed by the name it publishes to UIA. Enablement is `IsEnabled` on
    /// the button, carried by the SAME object whether the bar is showing the
    /// command or the "…" menu is (measured, docs/chrome-plan.md C2); the
    /// symbol is the automation name of the `IconElement` in its `Icon` slot,
    /// never `MenuModel::symbol`. TOTAL, like `menu_state`: every miss is a
    /// sentence naming what was measured, never a panic.
    fn toolbar_item(&self, label: &str, aspect: &str) -> String {
        let label = label.to_owned();
        let aspect = aspect.to_owned();
        Self::on_ui_read(move |core| {
            toolbar_trace(core, 0);
            let (held, buttons) = toolbar_read(core, 0)?;
            let matches: Vec<usize> = buttons
                .iter()
                .enumerate()
                .filter(|(_, (name, _))| name.as_bytes() == label.as_bytes())
                .map(|(index, _)| index)
                .collect();
            let index = match matches[..] {
                [index] => index,
                [] => {
                    let shown: Vec<&str> = buttons.iter().map(|(n, _)| n.as_str()).collect();
                    return Ok(format!(
                        "no toolbar item labelled {label} (the bar holds {held} items; \
                         they publish: {shown:?})"
                    ));
                }
                _ => {
                    return Ok(format!(
                        "{} toolbar buttons publish the name {label}, so which one this \
                         step means is ambiguous",
                        matches.len()
                    ));
                }
            };
            let button = &buttons[index].1;
            if aspect == "enabled" || aspect == "disabled" {
                return Ok(if button.IsEnabled()? { "enabled" } else { "disabled" }.to_owned());
            }
            Ok(match button.Icon() {
                Ok(icon) => icon_uia_name(&icon),
                // The empty slot arrives as a success-coded error, the same
                // rule `MenuIcon::Empty` records: the property returns a null
                // pointer and windows-core turns that into E_POINTER. What
                // this measured is that the button is in the bar and carries
                // no icon — never whether the app declared a symbol
                // (CLAUDE.md invariant 3).
                Err(e) if e.code().is_ok() => {
                    format!("the toolbar button {label} carries no icon")
                }
                Err(e) => format!("the toolbar button {label}'s icon slot could not be read: {e}"),
            })
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn shortcut(&self, spelling: &str) {
        let spec = spelling.to_owned();
        // A chord no catalog action owns is a silent no-op on every
        // platform — gated BEFORE any injection, because keybd_event
        // is OS-GLOBAL and a stray chord could land anywhere
        // (docs/traps.md: WinUI shortcut injection is OS-global).
        let owned = Self::on_ui_read({
            let spec = spec.clone();
            move |core| {
                // Same freshness rule as menu_activate: the chord may land on a
                // role item whose enablement is a deferred tick stale.
                if core.roles_armed {
                    refresh_role_enablement(core);
                }
                Ok(core.menu_shortcuts.contains_key(&spec))
            }
        })
        .unwrap_or(false);
        // A chord no catalog item owns is a SCRIPT error, said out loud. The
        // gate itself is load-bearing (injection is OS-global —
        // docs/traps.md), but a silent return makes a never-pressed key look
        // exactly like a platform that ignored it: that mistake cost eight
        // platform experiments on 2026-07-24, every one of them measuring a
        // keystroke this gate had swallowed.
        assert!(
            owned,
            "kaya: shortcut {spec:?}: no catalog item owns this chord \
             (the leaf kinds that may carry one are action, toggle, and \
             radio option)"
        );
        Self::foreground_guest("shortcut");

        // The REAL KeyboardAccelerator path: the chord goes onto the system
        // input queue; XAML routes it to the accelerator whose default
        // invocation raises the item's own Click.
        let mut mods: Vec<u8> = Vec::new();
        let mut key: Option<u8> = None;
        for part in spec.split('+') {
            match part {
                "primary" => mods.push(0x11), // VK_CONTROL
                "shift" => mods.push(0x10),
                "alt" => mods.push(0x12),
                name => key = virtual_key(name).map(|vk| vk.0 as u8),
            }
        }
        let key = key.expect("a root-validated spelling carries one key");
        const KEYEVENTF_KEYUP: u32 = 0x2;
        unsafe {
            for &m in &mods {
                keybd_event(m, 0, 0, 0);
            }
            keybd_event(key, 0, 0, 0);
            keybd_event(key, 0, KEYEVENTF_KEYUP, 0);
            for &m in mods.iter().rev() {
                keybd_event(m, 0, KEYEVENTF_KEYUP, 0);
            }
        }
    }
    fn click(&self, t: crate::harness::Target) {
        Self::on_ui(move |core| {
                // A click on a TEXT KIND focuses it — what a native click does
                // to a field, and the only way a scene can put focus on a
                // STAMPED copy. Programmatic FocusState, the same one the
                // wire's focus command uses, so is_focused's per-element
                // read sees it.
            match t.kind {
                crate::harness::TargetKind::Entry => {
                    let i = crate::harness::resolve(t.index, core.entries.len());
                    let _ = core.entries[i].Focus(FocusState::Programmatic)?;
                }
                crate::harness::TargetKind::Textarea => {
                    let i = crate::harness::resolve(t.index, core.textareas.len());
                    let _ = core.textareas[i].Focus(FocusState::Programmatic)?;
                }
                _ => {
                    let i = crate::harness::resolve(t.index, core.buttons.len());
                    core.occurrences.send_click_tag(&core.buttons[i]);
                }
            }
            Ok(())
        });
    }

    fn toggle(&self, t: crate::harness::Target, on: bool) {
        Self::on_ui(move |core| {
            let i = crate::harness::resolve(t.index, core.checkboxes.len());
            let boxed: IReference<bool> = PropertyValue::CreateBoolean(on)?.cast()?;
            core.checkboxes[i].SetIsChecked(&boxed)?;
            Ok(())
        });
    }

    fn set_value(&self, t: crate::harness::Target, value: f64) {
        Self::on_ui(move |core| {
            let i = crate::harness::resolve(t.index, core.sliders.len());
            core.sliders[i].SetValue(value)?;
            Ok(())
        });
    }

    /// The real-keystroke typing verb (docs/undo-plan.md A8), to the contract's
    /// six points (crates/kaya/src/harness.rs). What is platform here:
    /// `keybd_event` puts each character on the SYSTEM INPUT QUEUE, so the
    /// field's native undo stack fills as a user's does and a `SetText` would
    /// CLEAR the very history a native-tier scene came to observe; nothing is
    /// addressed, so whatever holds focus receives it; the caret goes to the
    /// END before the first keystroke, because macOS selects a field's whole
    /// contents on focus and ONE script runs on all five lanes; the settle
    /// below blocks until the text has landed, since the next action is
    /// `menu_activate "Edit>Undo"`; this platform merges the WHOLE RUN into
    /// one native step (measured), which is what makes A1's clear at the
    /// episode boundary load-bearing; printable ASCII only, mapped through the
    /// ACTIVE LAYOUT (VkKeyScanW).
    fn type_text(&self, text: &str) {
        let text = text.to_owned();
        // The caret first, and the field's text before the run — both read
        // from the FOCUSED editable, the platform's answer to "who receives
        // this", not kaya's.
        let before = Self::on_ui(|core| {
            let Some(id) = focused_editable_id(core) else {
                return Ok(None);
            };
            let Some(field) = editable_by_id(core, id) else {
                return Ok(None);
            };
            let now = lf(field.text()?);
            let n = now.chars().count() as i32;
            field.set_caret(n)?;
            Ok(Some((id, now)))
        });
        Self::foreground_guest("type");
        const KEYEVENTF_KEYUP: u32 = 0x2;
        for ch in text.chars() {
            let scan = unsafe { VkKeyScanW(ch as u16) };
            assert!(
                scan != -1,
                "kaya: type {text:?}: the active keyboard layout has no key for {ch:?} \
                 (parse admits printable ASCII, which every layout can type)"
            );
            let vk = (scan & 0xff) as u8;
            let shifts = (scan >> 8) & 0x7;
            let mut mods: Vec<u8> = Vec::new();
            if shifts & 1 != 0 {
                mods.push(0x10); // VK_SHIFT
            }
            if shifts & 2 != 0 {
                mods.push(0x11); // VK_CONTROL
            }
            if shifts & 4 != 0 {
                mods.push(0x12); // VK_MENU
            }
            unsafe {
                for &m in &mods {
                    keybd_event(m, 0, 0, 0);
                }
                keybd_event(vk, 0, 0, 0);
                keybd_event(vk, 0, KEYEVENTF_KEYUP, 0);
                for &m in mods.iter().rev() {
                    keybd_event(m, 0, KEYEVENTF_KEYUP, 0);
                }
            }
        }
        // Point 4, and "processed" here means MORE THAN THE CONTROL SHOWING
        // IT: TextChanged is raised asynchronously and the action this verb
        // precedes is `menu_activate "Edit>Undo"`, whose routing asks the
        // LEDGER, so the condition is `banked_text`. Nothing focused is
        // legitimate under the contract, so a following assertion reports it.
        let Some((id, before)) = before else { return };
        let want = format!("{before}{text}");
        for _ in 0..400 {
            let seen = Self::on_ui_read(move |core| Ok(core.banked_text.get(&id).cloned()))
                .unwrap_or(None);
            if seen.as_deref() == Some(want.as_str()) {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        // NOT A PANIC, and not silence either: the keys were injected, so what
        // follows is a real observation of a real state and the scene's own
        // `expect` is the verdict. This line tells the transcript's reader
        // that the verb knew.
        let shown = Self::on_ui_read(move |core| {
            Ok(editable_by_id(core, id)
                .and_then(|field| field.text().ok())
                .map(lf))
        })
        .unwrap_or(None);
        eprintln!(
            "kaya: type {text:?}: the ledger never saw {want:?} within 2s of injection \
             (the field shows {shown:?}) — either the keystrokes went onto the system \
             input queue and something else took them, or the field's TextChanged never \
             reached bank_text_changed"
        );
    }

    fn set_text(&self, t: crate::harness::Target, text: &str) {
        // Normalized on the way IN: the synthesized occurrence below
        // forwards this string to the guest, and CR-bearing input
        // (the harness's \r escape stands in for a paste) must reach
        // guests as LF like every other path.
        let text = lf(text.to_owned());
        // on_ui_MUT, because this verb reaches the undo ledger: it
        // stands in for a user edit and the ledger is core state.
        Self::on_ui_mut(move |core| {
            // The user path, ordered: TextChanged is raised async, so the
            // occurrence is emitted here synchronously and the late raise
            // swallowed (see entry_swallow). The handles are CLONED out of the
            // core — a refcount bump — because the banking below borrows the
            // core mutably.
            let (field, id) = if t.kind == crate::harness::TargetKind::Textarea {
                let i = crate::harness::resolve(t.index, core.textareas.len());
                (
                    Editable::Textarea(core.textareas[i].clone()),
                    core.textarea_ids[i],
                )
            } else {
                let i = crate::harness::resolve(t.index, core.entries.len());
                (Editable::Entry(core.entries[i].clone()), core.entry_ids[i])
            };
            if lf(field.text()?) != text {
                if let Some(swallow) = core.entry_swallow.get(&id) {
                    swallow.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                }
                field.set_text(&text)?;
                // AND THE LEDGER SEES IT FIRST: this verb is a USER EDIT, not
                // an app write, and undo.steps' stamped-row block stands on
                // that. Measured on the VM 2026-08-05 with the bank absent:
                // Edit>Undo took back the ADD and a row's typing was outside
                // the history entirely, this backend being the only one
                // whose set_text silences the control's own change event.
                let _ = bank_text_changed_on(core, id, &text);
                if let Some(tag) = core.entry_tags.get(&id) {
                    core.occurrences.send_text_tag(tag, &text);
                }
            }
            Ok(())
        });
    }

    fn read_label(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            let Some(i) = crate::harness::try_resolve(t.index, core.labels.len()) else {
                return Ok("<no such target>".to_string());
            };
            Ok(core.labels[i].Text()?.to_string())
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn read_text(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            if t.kind == crate::harness::TargetKind::Textarea {
                let Some(i) = crate::harness::try_resolve(t.index, core.textareas.len())
                else {
                    return Ok("<no such target>".to_string());
                };
                return Ok(lf(Editable::Textarea(core.textareas[i].clone()).text()?));
            }
            let Some(i) = crate::harness::try_resolve(t.index, core.entries.len()) else {
                return Ok("<no such target>".to_string());
            };
            Ok(lf(core.entries[i].Text()?.to_string()))
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn image_size(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            let Some(i) = crate::harness::try_resolve(t.index, core.images.len()) else {
                return Ok("<no such target>".to_string());
            };
            // The stored BitmapImage's decoded pixel size; no source (or a
            // source that never decoded) is the placeholder class, "0x0".
            let size = core.images[i]
                .Source()
                .ok()
                .and_then(|source| source.cast::<BitmapImage>().ok())
                .and_then(|bitmap| {
                    Some((bitmap.PixelWidth().ok()?, bitmap.PixelHeight().ok()?))
                });
            Ok(match size {
                Some((w, h)) => format!("{w}x{h}"),
                None => "0x0".into(),
            })
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn is_focused(&self, t: crate::harness::Target) -> bool {
        Self::on_ui_read(move |core| {
            // The element's own FocusState, never FocusManager's global
            // focused element — per-window focus, so parallel tiled
            // legs cannot steal each other's assertion.
            match t.kind {
                crate::harness::TargetKind::Entry => {
                    let Some(i) = crate::harness::try_resolve(t.index, core.entries.len()) else {
                        return Ok(false);
                    };
                    Ok(core.entries[i].FocusState()? != FocusState::Unfocused)
                }
                crate::harness::TargetKind::Textarea => {
                    let Some(i) = crate::harness::try_resolve(t.index, core.textareas.len())
                    else {
                        return Ok(false);
                    };
                    Ok(core.textareas[i].FocusState()? != FocusState::Unfocused)
                }
                other => panic!("kaya: is_focused not wired for {other:?} on winui"),
            }
        }).unwrap_or(false)
    }


    // The table verbs (docs/tables-plan.md): everything below reads what
    // `declare_table` and the pass around it actually built.

    fn columns_presented(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            // THE HEADER'S OWN TEXT, never the declaration: the titles come
            // back off the real controls and the indicator is recovered from
            // the GLYPH one of them is carrying, so a header that never
            // rendered reads empty rather than agreeing with the record.
            let Some(cells) = table_of(core, t, |table| table.cells.clone()) else {
                return Ok(String::new());
            };
            let mut titles = Vec::new();
            let mut indicator = String::new();
            for (column, cell) in cells.iter().enumerate() {
                let shown = content_string(&cell.Content()?)?;
                let title = if let Some(stem) = shown.strip_suffix(TABLE_ASC) {
                    indicator = format!(" ^{column}");
                    stem.to_string()
                } else if let Some(stem) = shown.strip_suffix(TABLE_DESC) {
                    indicator = format!(" v{column}");
                    stem.to_string()
                } else {
                    shown
                };
                titles.push(title);
            }
            Ok(format!("{}{indicator}", titles.join("|")))
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn row_cells(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            // The TOOLKIT's order on both levels — the tracks the rows and
            // cells are actually placed in — because a sort is a MOVE.
            let Some(rows) = table_rows_in_track_order(core, t)? else {
                return Ok("<no such target>".to_string());
            };
            let mut out = Vec::new();
            for row in rows {
                let children = row.Children()?;
                let mut cells: Vec<(i32, String)> = Vec::new();
                for at in 0..children.Size()? {
                    let child = children.GetAt(at)?;
                    if let Ok(block) = child.cast::<TextBlock>() {
                        if core.labels.iter().any(|l| l == &block) {
                            let column = Grid::GetColumn(&block.cast::<FrameworkElement>()?)?;
                            cells.push((column, block.Text()?.to_string()));
                        }
                    }
                }
                cells.sort_by_key(|(column, _)| *column);
                out.push(
                    cells
                        .into_iter()
                        .map(|(_, text)| text)
                        .collect::<Vec<_>>()
                        .join(","),
                );
            }
            Ok(out.join("|"))
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn column_edges(&self, t: crate::harness::Target, want: usize) -> String {
        Self::on_ui_read(move |core| {
            let Some((grid, header, pad, host)) = table_of(core, t, |table| {
                (table.grid.clone(), table.header.clone(), table.pad, table.host.clone())
            }) else {
                return Ok("<no such target>".to_string());
            };
            // Measure/arrange are lazy; force them or the first read
            // after mount sees zeros (the child_shares precedent).
            grid.UpdateLayout()?;
            // CLUSTERS, from REAL placement: every cell's leading edge in the
            // table's own space (kaya's header cells included, since this
            // backend composes the header) through the transform, never
            // through the tracks that were asked for. BY LINE, because the
            // header and a row can end in different places and one global
            // maximum cannot see it.
            let surface: UIElement = grid.cast()?;
            let Some(rows) = table_rows_in_track_order(core, t)? else {
                return Ok("<no such target>".to_string());
            };
            let mut lines: Vec<Grid> = vec![header.clone()];
            lines.extend(rows.iter().cloned());
            let mut edges: Vec<f64> = Vec::new();
            let mut min_start = f64::MAX;
            let mut min_end = f64::MAX;
            let mut max_end = f64::NEG_INFINITY;
            for line in &lines {
                let origin = f64::from(
                    line.cast::<UIElement>()?
                        .TransformToVisual(&surface)?
                        .TransformPoint(Point { X: 0.0, Y: 0.0 })?
                        .X,
                );
                // THIS LINE'S OWN RESOLVED TRACKS, never the header's: a
                // row that arrived after the last `table_stamp` still
                // carries the container defaults, and that is exactly the
                // state ContentUnderfill exists to name.
                let defs = line.ColumnDefinitions()?;
                let spacing = line.ColumnSpacing()?;
                let mut tracks: Vec<(f64, f64)> = Vec::new();
                let mut acc = 0.0;
                for at in 0..defs.Size()? {
                    let width = defs.GetAt(at)?.ActualWidth()?;
                    tracks.push((origin + acc, origin + acc + width));
                    acc += width + spacing;
                }
                let children = line.Children()?;
                let mut boxes: Vec<TableCellBox> = Vec::new();
                for at in 0..children.Size()? {
                    let cell = children.GetAt(at)?;
                    let element: FrameworkElement = cell.cast()?;
                    let ink_start = f64::from(
                        cell.TransformToVisual(&surface)?
                            .TransformPoint(Point { X: 0.0, Y: 0.0 })?
                            .X,
                    );
                    let ink_end = ink_start + element.ActualWidth()?;
                    edges.push(ink_start);
                    min_start = min_start.min(ink_start);
                    max_end = max_end.max(ink_end);
                    // Out of range is `table_floors`' own defensive skip: the
                    // cell contributes no track edge rather than a wrong one,
                    // and a placement the tracks disagree with shows up in
                    // the cluster count.
                    let column = Grid::GetColumn(&element)? as usize;
                    if let Some(&(track_start, track_end)) = tracks.get(column) {
                        boxes.push(TableCellBox {
                            ink_start,
                            ink_end,
                            track_start,
                            track_end,
                        });
                    }
                }
                if let Some(end) = table_line_end(&boxes) {
                    min_end = min_end.min(end);
                }
            }
            if edges.is_empty() {
                return Ok("no cells".to_string());
            }
            if min_end == f64::MAX {
                return Ok("no resolved column tracks on any line".to_owned());
            }
            edges.sort_by(|a, b| a.partial_cmp(b).unwrap());
            let mut clusters: Vec<f64> = Vec::new();
            for &x in &edges {
                if clusters.last().is_none_or(|last| x - last > 2.0) {
                    clusters.push(x);
                }
            }
            if clusters.len() != want {
                let seen: Vec<String> =
                    clusters.iter().map(|x| format!("{}", x.round() as i64)).collect();
                return Ok(format!(
                    "cell edges cluster at [{}], wanted {want} columns",
                    seen.join(",")
                ));
            }
            // THE SPAN HALF, which alignment alone cannot see: a
            // content-hugging table keeps every cluster right while drawing in
            // a corner of its track, so the resolved columns may exceed
            // neither the surface's horizontal viewport nor its padding. The
            // cell edges came out of TransformToVisual, whose origin is the
            // grid's PADDING box, so the pads come off frame and ink both.
            let defs = header.ColumnDefinitions()?;
            let mut drawn = header.ColumnSpacing()? * f64::from(defs.Size()?.saturating_sub(1));
            for at in 0..defs.Size()? {
                drawn += defs.GetAt(at)?.ActualWidth()?;
            }
            // HOW FAR THE SURFACE CAN GO, off the toolkit's own metric: columns
            // past the viewport are the ruling's normal state and convict
            // nothing while the table can scroll to them. `at` is where it
            // stands, added back below so the ink is read in the CONTENT's
            // space — a table measured after a scroll is not convicted of the
            // displacement the reader asked for.
            let (reach, at) = (host.ScrollableWidth()?, host.HorizontalOffset()?);
            let (track, viewport, min_start, min_end, max_end) = table_content_frame(
                pad,
                assigned_track(core, &grid)?,
                grid.ActualWidth()?,
                (min_start + at, min_end + at, max_end + at),
            );
            if track <= 0.0 || viewport <= 0.0 {
                return Ok("no live table viewport geometry".to_owned());
            }
            Ok(table_horizontal_complaint(
                drawn,
                track,
                viewport,
                min_start,
                min_end,
                max_end,
                reach,
            ))
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }


    fn window_band(&self, t: crate::harness::Target) -> String {
        Self::on_ui_settled(move |core| {
            let Some(id) = container_id(core, t) else {
                return Ok("<no such target>".to_string());
            };
            if TABLES.with_borrow(|tables| tables.contains_key(&id)) {
                table_settle(core, id);
                let (first, total) = TABLES
                    .with_borrow(|tables| tables.get(&id).map(|w| (w.first_visible, w.total)))
                    .unwrap_or((0, 0));
                if total > 0 {
                    return Ok(format!("{first} {total}"));
                }
            }
            // A For no tier of this backend windows: every row is
            // realized and the first of them is visible at rest, which
            // is what an unreported window answers too.
            Ok(format!("0 {}", core.child_order.children(WidgetId(id)).len()))
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn scroll_to_row(&self, t: crate::harness::Target, key: &str) -> String {
        let key = key.to_owned();
        Self::on_ui_settled(move |core| {
            let Some(id) = container_id(core, t) else {
                return Ok(format!("no such target {t:?}"));
            };
            let Some((host, band)) = TABLES
                .with_borrow(|tables| tables.get(&id).map(|w| (w.host.clone(), w.band.clone())))
            else {
                return Ok("that For is not a windowed tier on this backend \
                           (docs/virtualization-plan.md §4 windows declared tables here)"
                    .to_owned());
            };
            // The core maps the KEY to an index in the collection's CURRENT
            // order and this tier scrolls that row to the viewport's TOP. A key
            // the collection does not hold is the caller's bug; this sentence
            // names the verb.
            let scene = &mut core.scene;
            let Some(index) =
                crate::fault::guard("scroll_to_row", || scene.scroll_to_row(id, &Value::Str(key.clone())))
            else {
                return Ok(format!("no row carries the key {key:?}"));
            };
            // SETTLE BEFORE MOVING: the viewport count this hands the core has
            // to be a real one. A table whose first layout has not run reports
            // no viewport at all, and the band it asks for is the whole
            // collection (measured on the lane 2026-08-25 — `scroll_to_row
            // r200` carried a count of 300 on a 300-row scene).
            table_settle(core, id);
            let count = TABLES
                .with_borrow(|t| t.get(&id).and_then(|w| w.reported).map(|(_, c)| c))
                .unwrap_or(1)
                .max(1);
            // THE BAND FOLLOWS THE ROW NEXT: the target is unrealized until it
            // does, and the visible range may NOT be re-read in between,
            // because the viewport is still where it was and would band
            // straight back.
            TABLES.with_borrow_mut(|t| {
                if let Some(w) = t.get_mut(&id) {
                    w.reported = Some((index, count));
                    w.anchor = None;
                }
            });
            table_band_to(core, id, (index, count))?;
            band.UpdateLayout()?;
            for _ in 0..TABLE_SETTLE_ROUNDS {
                let measured = table_measure_rows(core, id, &band)?;
                let spaced = table_write_spacers(core, id, &band)?;
                if !measured && !spaced {
                    break;
                }
                band.UpdateLayout()?;
            }
            let (spacer_top, tracks) = band_tracks(&band)?;
            let first = core.scene.window_geometry(id).first;
            let offset = index.saturating_sub(first);
            // Band space to host space (D7), the report's rule verbatim.
            let want = fold_extent(id)
                + spacer_top
                + tracks[..offset.min(tracks.len())].iter().sum::<f64>();
            table_scroll_to(&host, id, want)?;
            // Parked on the ROW, not on the pixel: every correction cycle
            // re-parks it (§2.4, and docs/traps.md "The anchoring race").
            TABLES.with_borrow_mut(|t| {
                if let Some(w) = t.get_mut(&id) {
                    w.anchor = Some(index);
                }
            });
            table_settle(core, id);
            Ok(String::new())
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }
    fn header_click(&self, t: crate::harness::Target, column: u32) {
        // THE HEADER BUTTON'S OWN INVOKE, so the emission comes out of the
        // Click handler a user would have run. The handle is read out and the
        // borrow dropped before the invoke, because the handler it runs reads
        // the same table (the on_ui_bare lesson, one RefCell over).
        let cell = Self::on_ui_read(move |core| {
            Ok(table_of(core, t, |table| {
                table.cells.get(column as usize).cloned()
            })
            .flatten())
        });
        let Ok(Some(cell)) = cell else {
            panic!("kaya: header_click has no column {column} on {t:?}");
        };
        let _ = Self::on_ui_bare(move || {
            use bindings::Microsoft::UI::Xaml::Automation::Peers::{
                ButtonAutomationPeer, FrameworkElementAutomationPeer,
            };
            let peer = FrameworkElementAutomationPeer::CreatePeerForElement(&cell)?;
            let peer: ButtonAutomationPeer = peer.cast()?;
            peer.Invoke()
        });
    }

    fn resolve_id(
        &self,
        kind: crate::harness::TargetKind,
        id: &str,
        keys: Option<&str>,
    ) -> Option<isize> {
        // The a11y_id arm wrote the authored key through
        // AutomationProperties::SetAutomationId, so this reads the
        // backend's own applied prop back off the controls.
        let id = windows_core::HSTRING::from(id);
        let keys = keys.map(str::to_owned);
        Self::on_ui_read(move |core| -> windows_core::Result<Option<isize>> {
            use crate::harness::TargetKind as K;
            use bindings::Microsoft::UI::Xaml::Automation::AutomationProperties;
            fn carries_id<T: windows_core::Interface>(
                widget: &T,
                id: &windows_core::HSTRING,
            ) -> bool {
                use bindings::Microsoft::UI::Xaml::DependencyObject;
                widget
                    .cast::<DependencyObject>()
                    .ok()
                    .and_then(|d| AutomationProperties::GetAutomationId(&d).ok())
                    .map(|got| &got == id)
                    .unwrap_or(false)
            }
            fn find<T: windows_core::Interface>(
                v: &[T],
                id: &windows_core::HSTRING,
            ) -> Option<isize> {
                v.iter()
                    .position(|widget| carries_id(widget, id))
                    .map(|i| i as isize)
            }
            if let Some(keys) = keys.as_deref() {
                if kind == K::Button {
                    // A STAMPED BUTTON BY KEY: the template node off any
                    // copy carrying the authored id, then the copy whose
                    // click tag names that node and these keys
                    // (docs/deferred.md's keyed-target entry, 2026-09-01).
                    let node = core
                        .button_controls
                        .iter()
                        .zip(&core.buttons)
                        .filter(|(control, _)| carries_id(*control, &id))
                        .find_map(|(_, tag)| crate::harness::table_tag_node(tag));
                    let Some(node) = node else {
                        let with_id = core.button_controls.iter().filter(|c| carries_id(*c, &id)).count();
                        eprintln!(
                            "KAYA_DIAG keyed target button@{id}[{keys}] unresolved: {} live, {with_id} carrying the id",
                            core.button_controls.len()
                        );
                        return Ok(None);
                    };
                    return Ok(core
                        .buttons
                        .iter()
                        .position(|tag| crate::harness::table_tag_matches_keys(tag, node, keys))
                        .map(|i| i as isize));
                }
                if kind != K::Column {
                    // The other registries hold controls without their
                    // tags; a keyed target on them is this arm's stated
                    // divergence until they carry both.
                    return Ok(None);
                }
                return TABLES.with_borrow(|tables| {
                    let node = core
                        .columns
                        .iter()
                        .zip(&core.column_ids)
                        .find_map(|(column, widget)| {
                            (core.widgets.contains_key(widget) && carries_id(column, &id))
                                .then(|| tables.get(&widget.0))
                                .flatten()
                                .and_then(|table| crate::harness::table_tag_node(&table.tag))
                        });
                    let Some(node) = node else {
                        return Ok(None);
                    };
                    Ok(core
                        .columns
                        .iter()
                        .zip(&core.column_ids)
                        .position(|(_, widget)| {
                            core.widgets.contains_key(widget)
                                && tables.get(&widget.0).is_some_and(|table| {
                                    crate::harness::table_tag_matches_keys(&table.tag, node, keys)
                                })
                        })
                        .map(|i| i as isize))
                });
            }
            // A DESTROYED WIDGET MAY NOT ANSWER A TARGET — see gtk.rs's
            // twin: the registries are push-only and a windowed row's copy
            // dies on every scroll, so the Column arm (the only kind with
            // an id vector) filters to what `widgets` still holds.
            if kind == K::Column {
                return Ok(core
                    .columns
                    .iter()
                    .zip(&core.column_ids)
                    .position(|(column, widget)| {
                        core.widgets.contains_key(widget) && carries_id(column, &id)
                    })
                    .map(|i| i as isize));
            }
            Ok(match kind {
                // The buttons registry stores click TAGS by design (the stage's
                // click path emits them directly), so there is no control to
                // read an AutomationId off: button@id resolves None HERE
                // ALONE, the dirty read-table's documented-divergence shape.
                K::Button => find(&core.button_controls, &id),
                K::Checkbox => find(&core.checkboxes, &id),
                K::Slider => find(&core.sliders, &id),
                K::Entry => find(&core.entries, &id),
                K::Label => find(&core.labels, &id),
                K::Column => find(&core.columns, &id),
                K::Row => find(&core.rows, &id),
                K::Image => find(&core.images, &id),
                K::Scroll => find(&core.scrolls, &id),
                K::Progress => find(&core.progresses, &id),
                K::Select => find(&core.selects, &id),
                K::Radio => find(&core.radios, &id),
                K::Grid => find(&core.grids, &id),
                K::Textarea => find(&core.textareas, &id),
                K::Canvas => find(&core.canvases, &id),
            })
        })
        .ok()
        .flatten()
    }

    fn child_texts(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            let registry = if matches!(t.kind, crate::harness::TargetKind::Column) {
                &core.columns
            } else {
                &core.rows
            };
            let Some(i) = crate::harness::try_resolve(t.index, registry.len()) else {
                return Ok("<no such target>".to_string());
            };
            let children = registry[i].Children()?;
            // Child order as the toolkit holds it — the registries are
            // creation-ordered and cannot observe a move.
            let mut texts = Vec::new();
            for at in 0..children.Size()? {
                if let Ok(block) = children.GetAt(at)?.cast::<TextBlock>() {
                    if core.labels.iter().any(|l| l == &block) {
                        texts.push(block.Text()?.to_string());
                    }
                }
            }
            Ok(texts.join("|"))
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn child_shares(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            // Kind picks the registry and the definition axis (the runner
            // rejects any other kind before it gets here). The first Windows
            // run of the row assertion caught this method still hard-wired to
            // columns: row#0 resolved against the COLUMNS registry and
            // reported the column's own splits.
            let vertical = matches!(t.kind, crate::harness::TargetKind::Column);
            let registry = if vertical { &core.columns } else { &core.rows };
            let Some(i) = crate::harness::try_resolve(t.index, registry.len()) else {
                return Ok("<no such target>".to_string());
            };
            let grid = &registry[i];
            // Measure/arrange are lazy; force them or the first read
            // after mount sees zeros.
            grid.UpdateLayout()?;
            // The TRACK's resolved extent, not the child's: on a Grid the track
            // is the layout rect, and a child only fills it if it stretches. A
            // TextBlock never does — it reports its text height however tall
            // its row is — so reading children turned an exactly correct 25/75
            // split into 37/63.
            let mut extents = Vec::new();
            if vertical {
                let defs = grid.RowDefinitions()?;
                for at in 0..defs.Size()? {
                    extents.push(defs.GetAt(at)?.ActualHeight()?);
                }
            } else {
                let defs = grid.ColumnDefinitions()?;
                for at in 0..defs.Size()? {
                    extents.push(defs.GetAt(at)?.ActualWidth()?);
                }
            }
            Ok(crate::harness::shares(&extents))
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn container_fills(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            let vertical = matches!(t.kind, crate::harness::TargetKind::Column);
            let registry = if vertical { &core.columns } else { &core.rows };
            let Some(i) = crate::harness::try_resolve(t.index, registry.len()) else {
                return Ok("<no such target>".to_string());
            };
            let grid = &registry[i];
            let table = vertical && table_of(core, t, |_| ()).is_some();
            // The DECLARED gap, recovered by COM identity the way cross_mode
            // recovers the id: summing with the Grid's own
            // RowSpacing/ColumnSpacing would mirror the lowering's write and
            // could never catch it dropped.
            let declared = core
                .widgets
                .iter()
                .find_map(|(wid, w)| match w {
                    NativeWidget::Column(g) | NativeWidget::Row(g) if g == grid => Some(*wid),
                    _ => None,
                })
                .and_then(|wid| core.spacings.get(&wid).copied())
                .unwrap_or(8.0);
            grid.UpdateLayout()?;
            // A GROWN CONTAINER IS A FLEX CHILD TOO, and this clause comes
            // first: its own box must span the track its weight earned before
            // its children can span anything (tools/scenes/align.steps, and
            // the ledger entry "a nested SwiftUI container cannot fill its
            // track"). One-sided like the widget read, and silent where no
            // flex parent holds a track.
            let element: FrameworkElement = grid.cast()?;
            if let FlexTrack::In { track, drawn } = flex_track(core, &element)? {
                if track > 0.0 && drawn < track - 2.0 {
                    return Ok(format!(
                        "draws {}dip of its own {}dip track",
                        drawn.round() as i64,
                        track.round() as i64
                    ));
                }
            }
            // THE BREADTH CLAUSE: a CROSSING container — a row in a column, a
            // column in a row — spans its parent's inner breadth under every
            // align mode, which `reindex`'s crossing stamp is what makes true.
            // Skipped where no crossing flex parent holds it or where that
            // parent has no layout yet.
            if let Ok(parent) = element.Parent()?.cast::<Grid>() {
                let crossing = if vertical { &core.rows } else { &core.columns };
                if crossing.iter().any(|g| g == &parent) {
                    let pad = parent.Padding()?;
                    let (breadth, inner) = if vertical {
                        (
                            grid.ActualHeight()?,
                            parent.ActualHeight()? - pad.Top - pad.Bottom,
                        )
                    } else {
                        (
                            grid.ActualWidth()?,
                            parent.ActualWidth()? - pad.Left - pad.Right,
                        )
                    };
                    if inner > 0.0 && breadth < inner - 2.0 {
                        return Ok(format!(
                            "spans {}dip of its parent's {}dip breadth",
                            breadth.round() as i64,
                            inner.round() as i64
                        ));
                    }
                }
            }
            // A Grid places tracks from the padding edge with
            // RowSpacing-sized gaps between adjacent ones and no slack
            // anywhere else, so the consumed span is the tracks' sum
            // plus the gaps, and slack shows up as the difference to
            // the content box (ActualSize minus Padding).
            let padding = grid.Padding()?;
            let kids = grid.Children()?.Size()?;
            let (inner, sum, gaps, tracks) = if vertical {
                let defs = grid.RowDefinitions()?;
                let mut sum = 0.0;
                for at in 0..defs.Size()? {
                    sum += defs.GetAt(at)?.ActualHeight()?;
                }
                (
                    grid.ActualHeight()? - padding.Top - padding.Bottom,
                    sum,
                    declared * f64::from(defs.Size()?.saturating_sub(1)),
                    defs.Size()?,
                )
            } else {
                let defs = grid.ColumnDefinitions()?;
                let mut sum = 0.0;
                for at in 0..defs.Size()? {
                    sum += defs.GetAt(at)?.ActualWidth()?;
                }
                (
                    grid.ActualWidth()? - padding.Left - padding.Right,
                    sum,
                    declared * f64::from(defs.Size()?.saturating_sub(1)),
                    defs.Size()?,
                )
            };
            // NO VERDICT OUT OF ZEROS: a container the toolkit has not laid out
            // yet would answer "fills" from 0 against 0, and tracks nobody
            // defined would read as a leftover the size of the box. Both are
            // failures here, so the poll retries a transient zero and only a
            // lasting one is reported.
            if inner <= 0.0 {
                return Ok("no container layout recorded".to_owned());
            }
            if tracks == 0 && kids > 0 {
                return Ok(format!("no child tracks recorded ({kids} children, 0 tracks)"));
            }
            let span = sum + gaps;
            Ok(if table && table_content_fits(span, inner) {
                String::new()
            } else if table {
                format!(
                    "children span {}dip inside a {}dip viewport",
                    span.round() as i64,
                    inner.round() as i64
                )
            } else if (span - inner).abs() <= 2.0 {
                String::new()
            } else {
                format!(
                    "children span {}dip of {}dip",
                    span.round() as i64,
                    inner.round() as i64
                )
            })
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn widget_fills(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            let element: FrameworkElement = match target_element(core, t)? {
                Some(e) => e.cast()?,
                None => return Ok("<no such target>".to_owned()),
            };
            // An overflow is not a leftover, so the test is one-sided.
            Ok(match flex_track(core, &element)? {
                FlexTrack::NoParent => "parent is not a flex container".to_owned(),
                FlexTrack::NoTrack => "no track recorded — not a flex child".to_owned(),
                FlexTrack::In { track, drawn } if drawn >= track - 2.0 => String::new(),
                FlexTrack::In { track, drawn } => format!(
                    "draws {}dip of a {}dip track",
                    drawn.round() as i64,
                    track.round() as i64
                ),
            })
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn widget_spans_breadth(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            let element: FrameworkElement = match target_element(core, t)? {
                Some(e) => e.cast()?,
                None => return Ok("<no such target>".to_owned()),
            };
            let Ok(parent) = element.Parent()?.cast::<Grid>() else {
                return Ok("parent is not a flex container".to_owned());
            };
            // The parent's axis from the registries, container_fills'
            // breadth clause's rule: a Grid in `columns` lays out
            // vertically, so its cross axis is width.
            let parent_vertical = if core.columns.iter().any(|g| g == &parent) {
                true
            } else if core.rows.iter().any(|g| g == &parent) {
                false
            } else {
                return Ok("parent is not a flex container".to_owned());
            };
            parent.UpdateLayout()?;
            let pad = parent.Padding()?;
            let (breadth, inner) = if parent_vertical {
                (element.ActualWidth()?, parent.ActualWidth()? - pad.Left - pad.Right)
            } else {
                (element.ActualHeight()?, parent.ActualHeight()? - pad.Top - pad.Bottom)
            };
            if inner <= 0.0 {
                return Ok("no container layout recorded".to_owned());
            }
            Ok(if breadth >= inner - 2.0 {
                String::new()
            } else {
                format!(
                    "spans {}dip of its parent's {}dip breadth",
                    breadth.round() as i64,
                    inner.round() as i64
                )
            })
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn container_axis(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            // The RENDERED axis, read out of the Grid's own definitions:
            // reindex builds tracks on exactly one side and clears the
            // other, so the populated side IS the direction the layout
            // used — never the model's axis map, which would echo the
            // apply arm back (docs/adaptive-layout-plan.md §2).
            let from_columns = matches!(t.kind, crate::harness::TargetKind::Column);
            let registry = if from_columns { &core.columns } else { &core.rows };
            let Some(i) = crate::harness::try_resolve(t.index, registry.len()) else {
                return Ok("<no such target>".to_string());
            };
            let grid = registry[i].clone();
            grid.UpdateLayout()?;
            if grid.ActualWidth()? <= 0.0 && grid.ActualHeight()? <= 0.0 {
                return Ok("no container layout recorded".to_owned());
            }
            let rows = grid.RowDefinitions()?.Size()?;
            let cols = grid.ColumnDefinitions()?.Size()?;
            Ok(match (rows > 0, cols > 0) {
                (true, false) => "vertical".to_owned(),
                (false, true) => "horizontal".to_owned(),
                (false, false) => "no container layout recorded".to_owned(),
                (true, true) => format!("<both axes have tracks: {rows} rows, {cols} columns>"),
            })
        })
        .unwrap_or_else(|e| format!("<winui read failed: {e:?}>"))
    }

    fn fold_state(&self, child: crate::harness::Target, table: Option<crate::harness::Target>) -> String {
        Self::on_ui_read(move |core| {
            // Measured off the TREE, both halves (D7): the child's element is
            // (or is not) inside the table's wrap — the scrolling side — never
            // the model map alone, which would echo the Fold op. Column
            // children only: the id registry this read rides is the columns',
            // and every fold this rule can produce folds a container.
            if !matches!(child.kind, crate::harness::TargetKind::Column) {
                return Ok("<the fold read speaks column children only>".to_owned());
            }
            let Some(child_id) = crate::harness::try_resolve(child.index, core.columns.len())
                .map(|i| core.column_ids[i])
            else {
                return Ok("<no such child target>".to_owned());
            };
            let Some(element) = core.widgets.get(&child_id).map(|w| w.element()) else {
                return Ok("<no such child widget>".to_owned());
            };
            let element = element?;
            let Some(want) = table else {
                return Ok(if core.folded_into.contains_key(&child_id.0) {
                    "folded"
                } else {
                    "not folded"
                }
                .to_owned());
            };
            if !matches!(want.kind, crate::harness::TargetKind::Column) {
                return Ok("<the fold target is not a column>".to_owned());
            }
            let Some(i) = crate::harness::try_resolve(want.index, core.columns.len()) else {
                return Ok("<no such table target>".to_owned());
            };
            let table_id = core.column_ids[i].0;
            let held = TABLES.with_borrow(|tables| -> windows_core::Result<bool> {
                let Some(t) = tables.get(&table_id) else {
                    return Ok(false);
                };
                let children = t.wrap.Children()?;
                let mut at = 0u32;
                children.IndexOf(&element, &mut at)
            })?;
            Ok(match (core.folded_into.get(&child_id.0), held) {
                (Some(&tid), true) if tid == table_id => "folded".to_owned(),
                (None, _) => "not folded".to_owned(),
                _ => "stamped folded, but rendered outside that table's viewport".to_owned(),
            })
        })
        .unwrap_or_else(|e| format!("<winui read failed: {e:?}>"))
    }

    fn cross_mode(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            let vertical = matches!(t.kind, crate::harness::TargetKind::Column);
            let registry = if vertical { &core.columns } else { &core.rows };
            let Some(i) = crate::harness::try_resolve(t.index, registry.len()) else {
                return Ok("<no such target>".to_string());
            };
            let grid = registry[i].clone();
            grid.UpdateLayout()?;
            let padding = grid.Padding()?;
            let (inner, origin) = if vertical {
                (grid.ActualWidth()? - padding.Left - padding.Right, padding.Left)
            } else {
                (grid.ActualHeight()? - padding.Top - padding.Bottom, padding.Top)
            };
            // The registry holds the Grid; the children live in
            // child_order under its WidgetId — recovered by COM
            // identity, the registries being creation-ordered clones.
            let id = core
                .widgets
                .iter()
                .find_map(|(id, w)| match w {
                    NativeWidget::Column(g) | NativeWidget::Row(g) if *g == grid => Some(*id),
                    _ => None,
                })
                .expect("registry grids live in the widget table");
            let order = core.child_order.children(id);
            let mut rects: Vec<(f64, f64)> = Vec::new();
            let mut baselines: Vec<f64> = Vec::new();
            for child in order {
                let Some(widget) = core.widgets.get(child) else {
                    continue;
                };
                let element: FrameworkElement = widget.element()?.cast()?;
                let at = element
                    .TransformToVisual(&grid)?
                    .TransformPoint(bindings::Windows::Foundation::Point { X: 0.0, Y: 0.0 })?;
                // A content-sized element ARRANGES TEXT-SIZED UNDER STRETCH
                // (docs/traps.md: A stretched WinUI TextBlock arranges
                // text-sized), so the child's BOX under resolved Stretch is
                // the slot, read from the RESOLVED alignment — the lowering's
                // own output, and loud on regression.
                let (start, extent) = if vertical {
                    if element.HorizontalAlignment()?
                        == bindings::Microsoft::UI::Xaml::HorizontalAlignment::Stretch
                    {
                        (0.0, inner)
                    } else {
                        (f64::from(at.X) - origin, element.ActualWidth()?)
                    }
                } else {
                    if element.VerticalAlignment()?
                        == bindings::Microsoft::UI::Xaml::VerticalAlignment::Stretch
                    {
                        (0.0, inner)
                    } else {
                        (f64::from(at.Y) - origin, element.ActualHeight()?)
                    }
                };
                rects.push((start, extent));
                if !vertical {
                    let baseline = match widget {
                        NativeWidget::Label(text) => Some(text.BaselineOffset()?),
                        NativeWidget::Button { caption, .. }
                        | NativeWidget::Checkbox { caption, .. } => {
                            let inner_at = caption
                                .TransformToVisual(&element)?
                                .TransformPoint(bindings::Windows::Foundation::Point {
                                    X: 0.0,
                                    Y: 0.0,
                                })?;
                            Some(f64::from(inner_at.Y) + caption.BaselineOffset()?)
                        }
                        _ => None,
                    };
                    if let Some(b) = baseline {
                        baselines.push(start + b);
                    }
                }
            }
            if rects.is_empty() {
                return Ok("no children".to_owned());
            }
            // STRETCH FIRST, and alone: spanning geometry is DEGENERATE — a
            // child at (0, inner) satisfies start, center AND end — so a
            // stretched container could never classify by elimination. All
            // children spanning IS stretch; the positional modes classify
            // only a container with a non-spanning child, and the
            // separability burden stays the scene's (tools/scenes/align.steps).
            if rects.iter().all(|r| r.0.abs() <= 2.0 && (r.1 - inner).abs() <= 2.0) {
                return Ok("stretch".to_owned());
            }
            // Multi-match is ambiguity, and ambiguity fails loudly: a
            // first-match answer lets an unseparated scene pass while proving
            // nothing.
            let mut matches = Vec::new();
            if rects.iter().all(|r| r.0.abs() <= 2.0) {
                matches.push("start");
            }
            if rects.iter().all(|r| ((2.0 * r.0 + r.1) - inner).abs() <= 4.0) {
                matches.push("center");
            }
            if rects.iter().all(|r| ((r.0 + r.1) - inner).abs() <= 2.0) {
                matches.push("end");
            }
            if !vertical
                && baselines.len() >= 2
                && baselines.iter().all(|b| (b - baselines[0]).abs() <= 2.0)
            {
                matches.push("baseline");
            }
            Ok(match matches.as_slice() {
                [one] => (*one).to_owned(),
                // A baseline-looking row reading mixed is usually the
                // recording, not the geometry — name the recorded
                // count in the verdict.
                [] => {
                    let recorded = if vertical {
                        String::new()
                    } else {
                        format!("; {} baselines recorded", baselines.len())
                    };
                    format!("mixed (cross rects {rects:?} in {inner}dip{recorded})")
                }
                many => format!("ambiguous ({})", many.join("|")),
            })
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn window_title(&self, window: u64) -> String {
        Self::on_ui_read(move |core| Ok(winui_window(core, window)?.Title()?.to_string()))
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn window_content_size(&self, window: u64) -> (f64, f64) {
        Self::on_ui_read(move |core| {
            // The XamlRoot's size IS the client area in DIP — the
            // same notion root_fills reads.
            let target = winui_window(core, window)?;
            let root: FrameworkElement = target.Content()?.cast()?;
            let area = root.XamlRoot()?.Size()?;
            Ok((f64::from(area.Width), f64::from(area.Height)))
        }).unwrap_or((f64::NAN, f64::NAN))
    }

    fn window_dirty(&self, window: u64) -> bool {
        // THE REAL OS CAPTION, not core.window_dirty (D5): a read of the flag
        // this backend just stored would agree with itself. `Window::Title()`
        // follows the OS caption rather than caching what kaya set, measured
        // by rewriting the HWND caption from a SECOND PROCESS
        // (docs/probes/dirty-probe-windows.md §5). UNREADABLE IS NOT CLEAN, so
        // this returns bool with no third answer and refuses out loud.
        let caption = <Self as crate::harness::Stage>::window_title(self, window);
        assert!(
            !caption.starts_with("<unreadable"),
            "kaya: the dirty read could not see window {window}'s caption \
             ({caption}) — on Windows the caption IS the affordance, and \
             an unreadable one is a broken read, not a clean window"
        );
        caption.starts_with(DIRTY_MARK)
    }

    fn close_window(&self, window: u64) {
        Self::on_ui(move |core| {
            // The REAL chrome path: WM_CLOSE through the subclass, so
            // the veto grammar fires exactly as a user click would.
            // Posted, not sent — the WNDPROC re-enters CORE, and a
            // held borrow here would abort.
            let target = winui_window(core, window)?;
            let native: IWindowNative = windows_core::Interface::cast(&target)?;
            let hwnd = native.window_handle()?;
            unsafe {
                PostMessageW(hwnd, WM_CLOSE, 0, 0);
            }
            Ok(())
        })
    }

    fn window_count(&self) -> usize {
        Self::on_ui(move |core| Ok(1 + core.aux_windows.len()))
    }

    fn alert_title(&self, window: u64) -> Option<String> {
        Self::on_ui_read(move |core| {
            let Some(live) = core.live_alert.as_ref() else {
                return Ok(None);
            };
            if live.window != window {
                return Ok(None);
            }
            // Present-gated: the stored handle answers before the popup is
            // actually open, and an expect_alert that passed then let
            // alert_choose press a not-yet-interactive dialog (docs/traps.md:
            // Scripted settles were hiding four real WinUI bugs, (4)).
            // IsLoaded flips when the dialog enters the tree.
            if !live.dialog.IsLoaded()? {
                return Ok(None);
            }
            // The REAL dialog object's Title, never the request's
            // copy (boxed at present time; unbox through
            // IPropertyValue).
            let title: IReference<HSTRING> = live.dialog.Title()?.cast()?;
            Ok(Some(title.Value()?.to_string()))
        }).unwrap_or(None)
    }

    fn choose_alert(&self, choice: u32) {
        use bindings::Microsoft::UI::Xaml::Automation::Peers::{
            ButtonAutomationPeer, FrameworkElementAutomationPeer,
        };
        use bindings::Microsoft::UI::Xaml::Media::VisualTreeHelper;
        // THE HANDLE UNDER THE BORROW, THE PRESS WITHOUT IT. Both calls
        // below can complete `ShowAsync` synchronously — measured for
        // `Hide()` on a dialog that never finished loading — and that
        // completion takes a MUTABLE core borrow, so driving them from
        // inside `on_ui` aborts the process (see `on_ui_bare`).
        let live = Self::on_ui(move |core| {
            Ok(core
                .live_alert
                .as_ref()
                .map(|live| (live.dialog.clone(), live.actions)))
        });
        let Some((dialog, actions)) = live else {
            return;
        };
        if choice != crate::wire::ALERT_CHOICE_CANCEL && choice as usize >= actions {
            return;
        }
        let asked = Self::on_ui_bare(move || {
            if choice == crate::wire::ALERT_CHOICE_CANCEL {
                // The REAL dismissal path: Hide() completes ShowAsync
                // with None exactly as Esc or the close button does.
                dialog.Hide()?;
                return Ok(true);
            }
            // The REAL press: the open dialog lives in the popup
            // layer; find its template button by part name and drive
            // its automation peer's Invoke — the click pipeline a
            // user's press runs (WinUI exposes no direct press).
            let part = if choice == 0 {
                "PrimaryButton"
            } else {
                "SecondaryButton"
            };
            let xaml_root = dialog.XamlRoot()?;
            let popups = VisualTreeHelper::GetOpenPopupsForXamlRoot(&xaml_root)?;
            for i in 0..popups.Size()? {
                let popup = popups.GetAt(i)?;
                let child: UIElement = popup.Child()?;
                if let Some(button) = find_template_button(&child, part)? {
                    let peer = FrameworkElementAutomationPeer::CreatePeerForElement(&button)?;
                    let peer: ButtonAutomationPeer = peer.cast()?;
                    peer.Invoke()?;
                    return Ok(true);
                }
            }
            Ok(false)
        })
        .unwrap_or(false);
        if !asked {
            return;
        }
        // AND WAIT FOR IT TO ACTUALLY GO (CLAUDE.md invariant 1). `Hide()` and
        // `Invoke()` only ASK; `ShowAsync`'s completion runs capi::alert_retire,
        // and until it lands the one live slot is still taken, so the app's
        // NEXT alert walks into "alert N is already live" (measured 2026-08-10,
        // the editor leg). The observable is capi's SLOT, a plain Mutex the
        // harness thread reads directly, and the stronger condition.
        let deadline = std::time::Instant::now() + crate::harness::POLL_DEADLINE;
        loop {
            if !crate::capi::alert_is_live() {
                return;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "kaya: the alert was answered but never resolved — its \
                 ShowAsync completion has not run, so the core still holds \
                 it in the one live slot and the next alert this app shows \
                 will abort the process"
            );
            std::thread::sleep(crate::harness::POLL_INTERVAL);
        }
    }

    fn entry_count(&self, window: u64) -> usize {
        Self::on_ui(move |core| Ok(core.nav_stacks.get(&window).map_or(0, Vec::len)))
    }

    fn back(&self, window: u64) {
        use bindings::Microsoft::UI::Xaml::Automation::Peers::{
            ButtonAutomationPeer, FrameworkElementAutomationPeer,
        };
        Self::on_ui(move |core| {
            // The REAL affordance: invoke the back bar's button
            // through its automation peer — the click pipeline a
            // user's press runs. Deferred one dispatcher tick: the
            // click handler re-borrows CORE, which this closure
            // holds.
            let Some(&top) = core.nav_stacks.get(&window).and_then(|s| s.last()) else {
                return Ok(());
            };
            let Some(back) = core
                .nav_entries
                .get(&top)
                .and_then(|e| e.back_button.clone())
            else {
                return Ok(());
            };
            // A COLLAPSED button is not an affordance. The automation
            // peer invokes it regardless of visibility, so without this
            // the harness could pop where the split arm has hidden the
            // bar, and the two-pane back rule would pass a test the
            // screen does not satisfy.
            let probe: UIElement = back.cast()?;
            if probe.Visibility()? != Visibility::Visible {
                return Ok(());
            }
            let queue = DispatcherQueue::GetForCurrentThread()?;
            let handler = DispatcherQueueHandler::new(move || {
                let peer = FrameworkElementAutomationPeer::CreatePeerForElement(&back)?;
                let peer: ButtonAutomationPeer = peer.cast()?;
                peer.Invoke()
            });
            queue.TryEnqueue(&handler)?;
            Ok(())
        })
    }

    fn progress_state(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            let Some(i) = crate::harness::try_resolve(t.index, core.progresses.len()) else {
                return Ok("<no such target>".to_string());
            };
            let bar = &core.progresses[i];
            // The REAL control's state, never a model copy.
            Ok(if bar.IsIndeterminate()? {
                "indeterminate".to_string()
            } else {
                format!("{}%", (bar.Value()? * 100.0).round() as i64)
            })
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn grid_columns(&self, t: crate::harness::Target, want: usize) -> String {
        Self::on_ui_read(move |core| {
            let Some(i) = crate::harness::try_resolve(t.index, core.grids.len()) else {
                return Ok("<no such target>".to_string());
            };
            let grid = &core.grids[i];
            // Geometry, never the model's columns copy: each cell's
            // leading edge in the grid's own space via
            // TransformToVisual; the distinct clusters ARE the
            // columns.
            let children = grid.Children()?;
            let mut edges: Vec<f64> = Vec::new();
            for k in 0..children.Size()? {
                let cell: UIElement = children.GetAt(k)?;
                let transform = cell.TransformToVisual(&grid.cast::<UIElement>()?)?;
                let origin = transform.TransformPoint(bindings::Windows::Foundation::Point {
                    X: 0.0,
                    Y: 0.0,
                })?;
                edges.push(f64::from(origin.X));
            }
            if edges.is_empty() {
                return Ok("no cells".to_string());
            }
            edges.sort_by(|a, b| a.partial_cmp(b).unwrap());
            let mut clusters = 0;
            let mut last = f64::MIN;
            for x in edges {
                if clusters == 0 || x - last > 2.0 {
                    clusters += 1;
                    last = x;
                }
            }
            Ok(if clusters == want {
                String::new()
            } else {
                format!("{clusters} column edges, wanted {want}")
            })
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn choose(&self, t: crate::harness::Target, index: usize) {
        Self::on_ui(move |core| {
            // The REAL selection route per kind: SetSelectedIndex
            // raises SelectionChanged exactly as a native pick does
            // (the quiet guard is off here), the slider's SetValue
            // stance.
            if t.kind == crate::harness::TargetKind::Radio {
                let i = crate::harness::resolve(t.index, core.radios.len());
                core.radios[i].SetSelectedIndex(index as i32)?;
                return Ok(());
            }
            let i = crate::harness::resolve(t.index, core.selects.len());
            core.selects[i].SetSelectedIndex(index as i32)?;
            Ok(())
        });
    }

    fn selected_label(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            if t.kind == crate::harness::TargetKind::Radio {
                // The REAL control's state: the selected row's string
                // out of the group's own Items vector.
                let Some(i) = crate::harness::try_resolve(t.index, core.radios.len()) else {
                    return Ok("<no such target>".to_string());
                };
                let group = &core.radios[i];
                let index = group.SelectedIndex()?;
                if index < 0 {
                    return Ok(String::new());
                }
                let value: IReference<HSTRING> =
                    windows_core::Interface::cast(&group.Items()?.GetAt(index as u32)?)?;
                return Ok(value.Value()?.to_string());
            }
            let Some(i) = crate::harness::try_resolve(t.index, core.selects.len()) else {
                return Ok("<no such target>".to_string());
            };
            let combo = &core.selects[i];
            // The REAL control's state: the selected row's string
            // content out of the ComboBox's items (see
            // select_options for why content is a string).
            let index = combo.SelectedIndex()?;
            if index < 0 {
                return Ok(String::new());
            }
            let item: ComboBoxItem =
                windows_core::Interface::cast(&combo.Items()?.GetAt(index as u32)?)?;
            let value: IReference<HSTRING> =
                windows_core::Interface::cast(&item.Content()?)?;
            Ok(value.Value()?.to_string())
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn scroll_overflow(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            let Some((viewer, columns)) = scroll_axis(core, t) else {
                return Ok("<no such target>".to_string());
            };
            // Measure/arrange are lazy; force them or the first read
            // after mount answers about a surface nothing laid out
            // (column_edges' own first line).
            viewer.UpdateLayout()?;
            // The toolkit's own metrics: the scrollable extent IS the
            // overflow (extent minus viewport).
            if columns {
                Ok(if viewer.ScrollableWidth()? > 2.0 {
                    String::new()
                } else {
                    format!(
                        "columns {} in viewport {}",
                        viewer.ExtentWidth()?,
                        viewer.ViewportWidth()?
                    )
                })
            } else {
                Ok(if viewer.ScrollableHeight()? > 2.0 {
                    String::new()
                } else {
                    format!(
                        "content {} in viewport {}",
                        viewer.ExtentHeight()?,
                        viewer.ViewportHeight()?
                    )
                })
            }
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn scroll_end(&self, t: crate::harness::Target) {
        Self::on_ui(move |core| {
            let Some((viewer, columns)) = scroll_axis(core, t) else {
                panic!("kaya: scroll_end on {t:?}, which scrolls nowhere");
            };
            viewer.UpdateLayout()?;
            // The REAL scrolling API: ChangeView is what scrollbars
            // and touch panning drive. The columns' arm takes the
            // ANIMATION-FREE overload, because the header travels on
            // the layout pass this call causes (`table_columns_track`)
            // and an animated glide would leave it behind per frame.
            if columns {
                viewer.ChangeViewWithOptionalAnimation(
                    &offset_ref(viewer.ScrollableWidth()?)?,
                    None::<&IReference<f64>>,
                    None::<&IReference<f32>>,
                    true,
                )?;
            } else {
                viewer.ChangeView(
                    None::<&IReference<f64>>,
                    &offset_ref(viewer.ScrollableHeight()?)?,
                    None::<&IReference<f32>>,
                )?;
            }
            Ok(())
        })
    }

    fn scroll_at_end(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            let Some((viewer, columns)) = scroll_axis(core, t) else {
                return Ok("<no such target>".to_string());
            };
            viewer.UpdateLayout()?;
            if columns {
                let short = viewer.ScrollableWidth()? - viewer.HorizontalOffset()?;
                return Ok(if short.abs() <= 2.0 {
                    String::new()
                } else {
                    format!(
                        "columns stand at {} of {}",
                        viewer.HorizontalOffset()?,
                        viewer.ScrollableWidth()?
                    )
                });
            }
            let short = viewer.ScrollableHeight()? - viewer.VerticalOffset()?;
            Ok(if short.abs() <= 2.0 {
                String::new()
            } else {
                format!(
                    "content bottom {} vs viewport {}",
                    viewer.VerticalOffset()? + viewer.ViewportHeight()?,
                    viewer.ExtentHeight()?
                )
            })
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn file_dialog_state(&self) -> Option<(String, Vec<String>)> {
        // The REAL dialog, read through the shell's own view — never this
        // backend's record of what it asked for. NOT over UI Automation,
        // which cannot be used against this dialog at all (see
        // sample_folder_view for the measured stack), and NOT through
        // on_ui_read either: the picker is a #32770 the shell owns, not a
        // XAML object, and it runs on its own thread.
        match sample_dialog() {
            Some(sampler::Sampled::Open(directory, rows)) => Some((directory, rows)),
            // A SAVE dialog is live, or none is. Either way no PICKER is,
            // and that is what this observation answers — the variant is
            // what keeps a save dialog's directory from satisfying
            // `expect_file_dialog` with an empty row list.
            _ => None,
        }
    }

    fn save_dialog_state(&self) -> Option<(String, String)> {
        match sample_dialog() {
            Some(sampler::Sampled::Save(directory, name)) => Some((directory, name)),
            _ => None,
        }
    }

    /// Type a name into the live save dialog's file-name box.
    ///
    /// POSTED KEYSTROKES, never `SendMessage`, whose input-synchronous call
    /// gets its COM callouts refused with a NONCONTINUABLE
    /// `RPC_E_CANTCALLOUT_ININPUTSYNCCALL`, fatal under a JVM. EM_SETSEL(0, -1)
    /// first, so the first character REPLACES the suggested name. VERIFIED IN
    /// A LOOP: the FIRST burst into a fresh save dialog's name box is
    /// DISCARDED and only repeating fixes it (docs/probes/save-winui.md).
    fn set_save_name(&self, name: &str) {
        for _ in 0..40 {
            let Some(dialog) = live_dialog() else { return };
            if let Some(edit) = dialog_control(dialog, ID_SAVE_FILENAME, "Edit") {
                unsafe { PostMessageW(edit, EM_SETSEL, 0, -1) };
                for ch in name.encode_utf16() {
                    unsafe { PostMessageW(edit, WM_CHAR, ch as usize, 1) };
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
            if let Some(sampler::Sampled::Save(_, got)) = sample_dialog() {
                if got == name {
                    return;
                }
            }
        }
    }

    /// Press the live save dialog's own Save or Cancel, and see the press
    /// through — including the confirmation Windows may put in front of it.
    /// `FOS_OVERWRITEPROMPT` is in the DEFAULT options (measured `0x880a`) and
    /// this backend keeps it, so a second `#32770` titled "Confirm Save As"
    /// can appear, whose Buttons carry ID 0 and are found by class plus
    /// caption (docs/probes/save-probe-windows.md §B.3). LEAVING IT UNANSWERED
    /// DOES NOT FAIL, IT WEDGES: `Show()` never returns.
    fn confirm_save(&self, save: bool) {
        // The picker's loop, verbatim in shape: press, then wait for the
        // dialog to GO, because a press that lands before the dialog is
        // interactive is swallowed with no error anywhere.
        for _ in 0..40 {
            let Some(dialog) = live_dialog() else { return };
            let id = if save { ID_OK } else { ID_CANCEL };
            if let Some(button) = dialog_control(dialog, id, "Button") {
                unsafe { PostMessageW(button, BM_CLICK, 0, 0) };
            }
            for _ in 0..10 {
                std::thread::sleep(std::time::Duration::from_millis(50));
                if save {
                    answer_overwrite_prompt(dialog);
                }
                if !file_dialog_is_up() {
                    return;
                }
            }
        }
    }

    fn choose_file(&self, name: Option<&str>) {
        // POSTED, NEVER SENT: a SendMessage would put the receiving thread
        // into an input-synchronous call, whose COM callouts Windows refuses
        // with RPC_E_CANTCALLOUT_ININPUTSYNCCALL, fatal under a JVM
        // (sample_folder_view). The observable is the dialog GOING AWAY: a
        // press that lands before the list is interactive is swallowed with no
        // error anywhere.
        for _ in 0..40 {
            let Some(dialog) = live_dialog() else { return };
            match name {
                // Named in the dialog's own file-name box rather than by
                // hit-testing a row: the rows are DirectUI items, not windows,
                // so there is nothing to click. Typed a character at a time
                // because WM_SETTEXT carries a pointer, and only SendMessage
                // marshals one.
                Some(file) => {
                    if let Some(edit) = dialog_control(dialog, ID_FILENAME, "Edit") {
                        unsafe { PostMessageW(edit, EM_SETSEL, 0, -1) };
                        for ch in file.encode_utf16() {
                            unsafe { PostMessageW(edit, WM_CHAR, ch as usize, 1) };
                        }
                    }
                    if let Some(ok) = dialog_control(dialog, ID_OK, "Button") {
                        unsafe { PostMessageW(ok, BM_CLICK, 0, 0) };
                    }
                }
                // Cancel is the empty list, faithfully: IDCANCEL,
                // pressed on the dialog's own button.
                None => {
                    if let Some(cancel) = dialog_control(dialog, ID_CANCEL, "Button") {
                        unsafe { PostMessageW(cancel, BM_CLICK, 0, 0) };
                    }
                }
            }
            for _ in 0..10 {
                std::thread::sleep(std::time::Duration::from_millis(50));
                if !file_dialog_is_up() {
                    return;
                }
            }
        }
    }

    /// The foreign WRITER: Windows PowerShell 5.1 as a child of this process,
    /// because its children share the ONE real clipboard where an ssh-spawned
    /// tool would get a per-connection window station (measured,
    /// docs/clipboard-plan.md §6). 5.1 and never pwsh, where the whole
    /// clipboard cmdlet surface vanishes silently, so the script asserts the
    /// edition and polls Contains* before printing KAYA_SEEDED.
    fn clipboard_seed(&self, kind: &str, argument: &str) {
        let script = match kind {
            "text" => format!(
                "Set-Clipboard -Value '{a}'; \
                 foreach ($i in 1..50) {{ if ((Get-Clipboard -Raw) -eq '{a}') {{ 'KAYA_SEEDED'; exit }} ; Start-Sleep -Milliseconds 100 }}; 'KAYA_SEED_LOST'",
                a = ps_quote(argument)
            ),
            "html" => format!(
                "Add-Type -AssemblyName PresentationCore; \
                 Set-Clipboard -Value '{a}' -AsHtml; \
                 foreach ($i in 1..50) {{ if ([Windows.Clipboard]::ContainsText([Windows.TextDataFormat]::Html)) {{ 'KAYA_SEEDED'; exit }}; Start-Sleep -Milliseconds 100 }}; 'KAYA_SEED_LOST'",
                a = ps_quote(argument)
            ),
            "image" => format!(
                // Raw PNG bytes under the "PNG" registered format, the same
                // shape wl-copy -t image/png seeds on linux. The MemoryStream
                // form writes EXACT bytes; a plain string or object would
                // ride WPF's serialized-object path that only PowerShell can
                // read back.
                "Add-Type -AssemblyName PresentationCore; \
                 $b = [IO.File]::ReadAllBytes('{a}'); \
                 $ms = New-Object IO.MemoryStream (,$b); \
                 [Windows.Clipboard]::SetData('PNG', $ms); \
                 foreach ($i in 1..50) {{ if ([Windows.Clipboard]::ContainsData('PNG')) {{ 'KAYA_SEEDED'; exit }}; Start-Sleep -Milliseconds 100 }}; 'KAYA_SEED_LOST'",
                a = ps_quote(argument)
            ),
            "files" => format!(
                "Add-Type -AssemblyName PresentationCore; \
                 Set-Clipboard -LiteralPath '{a}'; \
                 foreach ($i in 1..50) {{ if ([Windows.Clipboard]::ContainsFileDropList()) {{ 'KAYA_SEEDED'; exit }}; Start-Sleep -Milliseconds 100 }}; 'KAYA_SEED_LOST'",
                a = ps_quote(argument)
            ),
            custom => panic!(
                "kaya: clipboard_seed cannot write {custom:?} from outside the app — \
                 no stock tool writes an app-defined format, and a helper kaya wrote \
                 would be foreign in name only"
            ),
        };
        let out = run_powershell(&script);
        assert!(
            out.contains("KAYA_SEEDED"),
            "kaya: clipboard_seed {kind} never appeared on the clipboard: {out}"
        );
    }

    /// The foreign READER, per kind: text via Get-Clipboard -Raw; html via
    /// PresentationCore's GetText(Html) — NEVER Get-Clipboard -TextFormatType,
    /// which decodes the UTF-8 payload with the ANSI code page and corrupts
    /// non-ASCII irreversibly; an image as its DECODED size through GDI+ (both
    /// stock decoders accept a bad IDAT CRC, so the strict-decoder property
    /// lives on the linux lane alone); files as the first basename.
    fn clipboard_read(&self, kind: &str) -> String {
        match kind {
            "text" => lf(run_powershell(
                "$t = Get-Clipboard -Raw; if ($null -ne $t) { $t }",
            ))
            .trim_end_matches('\n')
            .to_owned(),
            "html" => {
                let raw = run_powershell(
                    "Add-Type -AssemblyName PresentationCore; \
                     [Windows.Clipboard]::GetText([Windows.TextDataFormat]::Html)",
                );
                parse_cf_html(raw.as_bytes()).unwrap_or_default()
            }
            "image" => run_powershell(
                "Add-Type -AssemblyName PresentationCore; Add-Type -AssemblyName System.Drawing; \
                 $ms = [Windows.Clipboard]::GetData('PNG'); \
                 if ($ms) { try { $i = [System.Drawing.Image]::FromStream($ms); \"$($i.Width)x$($i.Height)\" } catch { \"<$($ms.Length) bytes of PNG that GDI+ rejects>\" } }",
            )
            .trim()
            .to_owned(),
            "files" => run_powershell(
                "$fd = Get-Clipboard -Format FileDropList; \
                 if ($fd) { ($fd | Select-Object -First 1).Name }",
            )
            .trim()
            .to_owned(),
            custom => run_powershell(&format!(
                "Add-Type -AssemblyName PresentationCore; \
                 $ms = [Windows.Clipboard]::GetData('{}'); \
                 if ($ms) {{ $b = New-Object byte[] $ms.Length; [void]$ms.Read($b, 0, $ms.Length); [Text.Encoding]::UTF8.GetString($b) }}",
                ps_quote(custom)
            ))
            .trim_end_matches("\r\n")
            .trim_end_matches('\n')
            .to_owned(),
        }
    }

    fn goto_directory(&self, path: &str) {
        // ARMED, NOT SET: a dialog reads its folder when it is shown, so
        // this stores it and the apply arm applies it — the same shape
        // as GTK and the SwiftUI interpreter, for the same reason.
        let path = path.to_owned();
        Self::on_ui(move |core| {
            *core.pending_dialog_dir.borrow_mut() = Some(path.clone());
            Ok(())
        });
    }

    fn alert_count(&self) -> usize {
        Self::on_ui(move |core| Ok(usize::from(core.live_alert.is_some())))
    }

    fn typeface(&self) -> String {
        // THE RESOLVED FAMILY, ON A PLATFORM THAT CANNOT NAME IT: three routes
        // to the name are dead (docs/styling/typeface-winui.md §2) —
        // `FontFamily.Source` is the request handed back, `FontNameAttribute`
        // needs a Text pattern the in-process peer does not publish, and an
        // out-of-process UIA client is barred at crates/kaya/Cargo.toml. So
        // the read is what the text system DID with a pinned string.
        Self::on_ui_read(move |core| {
            let brand = brand_typeface();
            // Pending layout is forced first: a measurement taken with layout
            // outstanding is the previous pass's answer. IT IS NOT A SETTLE — a
            // Control carries its FontFamily DP DEFAULT until the implicit
            // style is applied a later turn of the pump (the first poll saw
            // `Segoe UI Variable`, the second Georgia) — and the race runs ONE
            // WAY, so a read that says Georgia is not a lucky early sample.
            let root: FrameworkElement = core.window.Content()?.cast()?;
            root.UpdateLayout()?;
            // The reference the whole read turns on: what a family this machine
            // cannot have looks like after XAML has laid it out.
            let absent = typeface_fingerprint(TYPEFACE_ABSENT)?;
            let mut views: Vec<(String, String)> = Vec::new();
            let mut any_fell_back = false;
            let mut claimed_of_first = String::new();
            for (kind, sources) in [
                ("label", typeface_sources_of_blocks(&core.labels)?),
                ("entry", typeface_sources_of_controls(&core.entries)?),
                ("textarea", typeface_sources_of_controls(&core.textareas)?),
            ] {
                for (i, claimed) in sources.into_iter().enumerate() {
                    if claimed_of_first.is_empty() {
                        claimed_of_first = claimed.clone();
                    }
                    let measured = typeface_fingerprint(&claimed)?;
                    any_fell_back |= measured == absent;
                    views.push((
                        format!("{kind}#{i}"),
                        typeface_resolved(&claimed, measured, absent)?,
                    ));
                    if trace_enabled() {
                        eprintln!("kaya: winui typeface: {kind}#{i} asks {claimed:?} -> {measured:?}");
                    }
                }
            }
            if trace_enabled() {
                eprintln!(
                    "kaya: winui typeface: brand={brand:?} absent-fingerprint={absent:?} views={views:?}"
                );
            }
            if views.is_empty() {
                return Ok("<no text views to read>".to_owned());
            }
            let first = views[0].1.clone();
            if views.iter().any(|(_, name)| *name != first) {
                return Ok(format!(
                    "views disagree: {}",
                    views
                        .iter()
                        .map(|(where_, name)| format!("{where_}={name}"))
                        .collect::<Vec<_>>()
                        .join(", ")
                ));
            }
            // THE NOTE IS ONLY EVER FAILURE TEXT, attached under one
            // condition: a brand was DECLARED and the text system did not use
            // it. A brandless app resolving to the platform's own face gets
            // the bare name; a branded app that fell back gets the name plus
            // the measurement that says which half broke.
            match brand {
                Some(source) if any_fell_back => Ok(typeface_fallback_note(
                    &first,
                    &source,
                    &typeface_availability(&source)?,
                    typeface_family_of(&claimed_of_first),
                )),
                _ => Ok(first),
            }
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    /// THE PICTURE THE SHELL WILL DRAW, in pixels, off the HWND
    /// (docs/app-identity-plan.md I8). Reading `TitleBar.IconSource` back is
    /// an ECHO — it hands over the same object kaya just stored, so sixteen
    /// zero bytes would read identically to a real PNG — while `WM_GETICON`
    /// is answered out of USER32's own per-window state, so these four
    /// samples prove the CONVERSION.
    fn app_icon(&self) -> String {
        Self::on_ui_read(move |core| {
            let target = winui_window(core, 0)?;
            let hwnd = windows_core::Interface::cast::<IWindowNative>(&target)
                .ok()
                .and_then(|n: IWindowNative| n.window_handle().ok())
                .unwrap_or(0);
            if hwnd == 0 {
                return Ok("<no hwnd: the window is not materialized>".to_owned());
            }
            Ok(window_icon_samples(hwnd))
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    /// The canonical raster, asked of the CORE (docs/canvas-plan.md §7.1)
    /// — every backend answers the same way, because the point is that
    /// five platforms' libkaya drew the same picture.
    fn canvas_probe(&self, target: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            let Some(i) = crate::harness::try_resolve(target.index, core.canvas_ids.len()) else {
                return Ok(format!("<this window holds {} canvases>", core.canvas_ids.len()));
            };
            Ok(core
                .scene
                .canvas_probe(WidgetId(core.canvas_ids[i]))
                .unwrap_or_else(|| "<the core holds no drawing for this canvas>".to_owned()))
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    /// WHICH SIZE the raster is, asked of the CORE like the probe above
    /// (docs/canvas-plan.md §3.2.1): the two numbers being compared were
    /// produced on opposite sides of the boundary — the TRACK is what
    /// this backend measured and reported, the VIEWBOX is what the guest
    /// declared. It is the only canvas read a size policy can move.
    fn canvas_raster_shape(&self, target: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            let Some(i) = crate::harness::try_resolve(target.index, core.canvas_ids.len()) else {
                return Ok(format!("<this window holds {} canvases>", core.canvas_ids.len()));
            };
            Ok(core
                .scene
                .canvas_raster_shape(WidgetId(core.canvas_ids[i]))
                .unwrap_or_else(|| "<the core holds no drawing for this canvas>".to_owned()))
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    /// ADVANCE THE FRAME CLOCK by the core's own deterministic step
    /// (§15.4). The step is the CORE's — `next_harness_frame` — so a
    /// leg's frame count is one number in all three harnesses, and no
    /// wall clock reaches a tick under the harness.
    fn frame(&self) {
        Self::on_ui_mut(|core| {
            let time = crate::capi::harness_frame_time();
            let ticks = crate::fault::guard("driving a frame", || core.scene.frame(time))
                .unwrap_or_default();
            for occ in ticks {
                core.occurrences.send(occ);
            }
            Ok(())
        })
    }

    /// THE BLIT, out of DWM's print of this window's composited content
    /// (docs/canvas-plan.md §7.2) — the only canvas read that fails when the
    /// buffer never reached the platform's image object OR reached it
    /// swizzled. NOT `RenderTargetBitmap`, whose `GetPixelsAsync` hands back
    /// a NULL buffer under S_OK on a display-only adapter (docs/traps.md);
    /// `PrintWindow` is synchronous and leaves nothing outstanding. Every
    /// angle-bracketed answer says what it MEASURED (invariant 3).
    fn canvas_ink(&self, target: crate::harness::Target, points: &str) -> String {
        let points = points.to_owned();
        Self::on_ui_read(move |core| {
            // THE APPEARANCE RIDES THE ANSWER (§6): the display raster
            // uses the platform's mode and kaya's palette has two, so a
            // bare colour string would be a frozen expectation quietly
            // depending on the host's appearance setting. THE SAME
            // READING the presentation report sends.
            let dark = core
                .window
                .Content()
                .ok()
                .and_then(|root| windows_core::Interface::cast::<FrameworkElement>(&root).ok())
                .and_then(|element| element.ActualTheme().ok())
                .is_some_and(|theme| theme == ElementTheme::Dark);
            let mode = if dark { "dark" } else { "light" };
            let wanted = crate::harness::probe_points(&points);
            if wanted.is_empty() {
                return Ok(format!("<no probe points in {points:?}>"));
            }
            let Some(i) = crate::harness::try_resolve(target.index, core.canvases.len()) else {
                return Ok(format!("<this window holds {} canvases>", core.canvases.len()));
            };
            let image = core.canvases[i].clone();
            let element: FrameworkElement = windows_core::Interface::cast(&image)?;
            let (w, h) = (element.ActualWidth()?, element.ActualHeight()?);
            if w < 1.0 || h < 1.0 {
                return Ok(format!("<the canvas laid out at {w}x{h}>"));
            }
            let at = placement(core, &image)?;
            match grab_canvas(&at) {
                Ok(grab) => Ok(format!("{mode} {}", sample_grab(&grab, &wanted))),
                Err(why) => Ok(format!(
                    "<the {}x{} canvas at {},{} inside a {}x{} window (scale {}) could not be \
                     printed: {why}>",
                    at.w, at.h, at.ox, at.oy, at.win_w, at.win_h, at.scale
                )),
            }
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn inset(&self) -> String {
        Self::on_ui_read(move |core| {
            // MEASURED from real layout, never read back from the
            // model: Grid.Padding shifts the first child's visual
            // offset inside the root by exactly the inset
            // (docs/styling-plan.md D3).
            let root: FrameworkElement = core.window.Content()?.cast()?;
            root.UpdateLayout()?;
            // The mounted root is a Grid for the container kinds and a
            // ScrollViewer for a scroll-rooted scene (the portfolio
            // dashboard): the read broke on the cast alone before the scroll
            // arm existed, the same hole as the padding stamp's.
            let child: UIElement = if let Ok(grid) = root.cast::<Grid>() {
                grid.Children()?.GetAt(0)?
            } else if let Ok(viewer) = root.cast::<ScrollViewer>() {
                viewer.Content()?.cast()?
            } else {
                return Ok("<the window content is neither a Grid nor a ScrollViewer>".into());
            };
            let transform = child.TransformToVisual(&root)?;
            let origin = transform
                .TransformPoint(bindings::Windows::Foundation::Point { X: 0.0, Y: 0.0 })?;
            // The root's one Padding carries the root CONTAINER's own inset too
            // when it declares one (container_padding — WinUI has a single
            // Padding where SwiftUI and Compose nest two boxes), and that
            // number belongs to the other read.
            let own = core
                .mounted_roots
                .get(&0)
                .and_then(|id| core.container_insets.get(id))
                .copied()
                .unwrap_or(0.0);
            let x = (f64::from(origin.X) - own).round() as i64;
            let y = (f64::from(origin.Y) - own).round() as i64;
            Ok(if x == y {
                format!("{x}")
            } else {
                format!("{x}x{y} (axes disagree)")
            })
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn container_inset(&self, target: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            // The walk `inset` does, one level down: a Grid's Padding offsets
            // its first track, so the first child's arranged origin inside its
            // container IS the container's inset. MEASURED, never Padding
            // read back out of the property the apply arm wrote — a read-back
            // would pass with no lowering. Through target_element, so a
            // target that is not a container is refused rather than measured.
            let Some(element) = target_element(core, target)? else {
                return Ok("<no such target>".to_owned());
            };
            let Ok(grid) = element.cast::<Grid>() else {
                return Ok(format!("{:?} is not a container", target.kind));
            };
            grid.UpdateLayout()?;
            let children = grid.Children()?;
            if children.Size()? == 0 {
                return Ok("<no children to measure against>".to_owned());
            }
            // NOT THE CARD, which is a table's first child and carries a
            // NEGATIVE margin of the card interior (TABLE_CARD_XAML): it
            // is arranged at the guest's own inset, and reading it here
            // would report that inset plus the card's padding.
            let card = TABLES.with_borrow(|tables| {
                tables.values().find(|t| t.grid == grid).map(|t| t.card.clone())
            });
            let mut at = 0u32;
            if let Some(card) = card {
                let mut found = 0u32;
                if children.IndexOf(&card, &mut found)?.into() {
                    at = found + 1;
                }
            }
            if at >= children.Size()? {
                return Ok("<no children to measure against>".to_owned());
            }
            let child = children.GetAt(at)?;
            let origin = child
                .TransformToVisual(&grid)?
                .TransformPoint(bindings::Windows::Foundation::Point { X: 0.0, Y: 0.0 })?;
            // A child's own margin rides in that origin and is not the
            // container's padding: a baseline row lifts its children with
            // top margins (baseline_compensate), which would otherwise
            // read as an inset nobody declared.
            let margin = child.cast::<FrameworkElement>()?.Margin()?;
            // And a mounted root's Padding carries the WINDOW inset as
            // well (container_padding), which is `inset`'s number rather
            // than this one's.
            let root = core.mounted_roots.values().any(|id| {
                matches!(
                    core.widgets.get(id),
                    Some(
                        NativeWidget::Column(g)
                        | NativeWidget::Row(g)
                        | NativeWidget::Grid2D(g)
                    ) if *g == grid
                )
            });
            let window_term = if root { core.inset } else { 0.0 };
            // AND A DECLARED TABLE'S CARD INTERIOR, which rides this same
            // Padding (container_padding): the guest declared the inset,
            // not the card, so the card's own term comes back off or this
            // verb answers `inset + 12` for every table.
            let card_term = TABLES.with_borrow(|tables| {
                if tables.values().any(|t| t.grid == grid) {
                    TABLE_CARD_PAD
                } else {
                    0.0
                }
            });
            let x = (f64::from(origin.X) - margin.Left - window_term - card_term).round() as i64;
            let y = (f64::from(origin.Y) - margin.Top - window_term - card_term).round() as i64;
            Ok(if x == y {
                format!("{x}")
            } else {
                format!("{x}x{y} (axes disagree)")
            })
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn root_fills(&self) -> String {
        Self::on_ui_read(move |core| {
            // The mounted root is the window's Content; the content
            // island (XamlRoot) is the framework's own notion of the
            // area handed to it.
            let root: FrameworkElement = core.window.Content()?.cast()?;
            root.UpdateLayout()?;
            let area = root.XamlRoot()?.Size()?;
            let (width, height) = (root.ActualWidth()?, root.ActualHeight()?);
            // Within one device-independent pixel: rounding is not a hug.
            Ok(
                if (width - area.Width as f64).abs() <= 1.0
                    && (height - area.Height as f64).abs() <= 1.0
                {
                    String::new()
                } else {
                    format!(
                        "{}x{}dip inside {}x{}dip",
                        width as i64, height as i64, area.Width as i64, area.Height as i64,
                    )
                },
            )
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn sections_presentation(&self, window: u64) -> String {
            // THE CONTROL'S OWN ANSWER, the way split_presentation asks
            // TwoPaneView for its Mode: a mirror written beside the
            // SetPaneDisplayMode call would agree with that call by
            // construction and could never fail. It measures where the pane
            // is PUT, not where it landed — enough to tell the two arms
            // apart, and it catches a window whose nav was never built.
        Self::on_ui_read(move |core| {
            let Some(nav) = core.section_navs.get(&window) else {
                // Never a default arm: this window has no sections
                // chrome at all, and the harness polls.
                return Ok(format!("no sections chrome on window#{window}"));
            };
            Ok(match nav.PaneDisplayMode()? {
                NavigationViewPaneDisplayMode::Top => "bar".to_owned(),
                // Every LEFT spelling is the design's `sidebar`: the compact
                // rail and the minimal hamburger are the same leading-edge
                // pane in less width. The arm asks for plain Left today, so
                // those two are here for a later adaptive arm.
                NavigationViewPaneDisplayMode::Left
                | NavigationViewPaneDisplayMode::LeftCompact
                | NavigationViewPaneDisplayMode::LeftMinimal => "sidebar".to_owned(),
                // Auto is the control's construction default and neither arm
                // sets it, so a nav still wearing one never reached
                // SetPaneDisplayMode.
                NavigationViewPaneDisplayMode::Auto => "pane display mode auto".to_owned(),
                other => format!("pane display mode {}", other.0),
            })
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn section_count(&self) -> usize {
        // The REAL switcher's item collection, never the section map.
        Self::on_ui_read(|core| {
            Ok(core
                .section_navs
                .get(&0)
                .map(|nav| nav.MenuItems()?.Size().map(|n| n as usize))
                .transpose()?
                .unwrap_or(0))
        })
        .unwrap_or(0)
    }

    fn active_section_title(&self) -> String {
        // The selected item's OWN content string — the platform's
        // selection state, not the model mirror.
        Self::on_ui_read(|core| {
            use windows_core::Interface;
            let Some(nav) = core.section_navs.get(&0) else {
                return Ok(String::new());
            };
            let Ok(selected) = nav.SelectedItem() else {
                return Ok(String::new());
            };
            let Ok(item) = selected.cast::<NavigationViewItem>() else {
                return Ok(String::new());
            };
            let Ok(content) = item.Content() else {
                return Ok(String::new());
            };
            let Ok(text) = content.cast::<IReference<HSTRING>>() else {
                return Ok(String::new());
            };
            Ok(text.Value()?.to_string())
        })
        .unwrap_or_default()
    }

    fn section_symbol(&self, title: &str) -> String {
        let title = title.to_owned();
        // THE ICON THE REAL ITEM CARRIES — the automation name of the
        // IconElement in the NavigationViewItem's own Icon slot, never
        // `WinSection::symbol` beside it. The item's OWN uia name is its
        // Content, i.e. the title, so the two halves come off two different
        // properties of the same real element. EVERY WINDOW, in id order:
        // the sections scene's sidebar rows live in an aux window.
        Self::on_ui_read(move |core| {
            use windows_core::Interface;
            let mut windows: Vec<u64> = core.section_navs.keys().copied().collect();
            windows.sort_unstable();
            let mut seen: Vec<String> = Vec::new();
            for window in windows {
                let Some(nav) = core.section_navs.get(&window) else {
                    continue;
                };
                let items = nav.MenuItems()?;
                for i in 0..items.Size()? {
                    let Ok(item) = items.GetAt(i)?.cast::<NavigationViewItem>() else {
                        continue;
                    };
                    let Ok(content) = item.Content() else { continue };
                    let Ok(text) = content.cast::<IReference<HSTRING>>() else {
                        continue;
                    };
                    let got = text.Value()?.to_string();
                    if got != title {
                        seen.push(got);
                        continue;
                    }
                    return Ok(match item.Icon() {
                        Ok(icon) => icon_uia_name(&icon),
                        // The empty slot arrives as a success-coded error (the
                        // `MenuIcon::Empty` rule). What this measured is that
                        // the row is in the real switcher and carries no icon
                        // — never whether the app declared a symbol, which
                        // this reader cannot tell it from.
                        Err(e) if e.code().is_ok() => {
                            format!("the section row {title} carries no icon")
                        }
                        Err(e) => {
                            format!("the section row {title}'s icon slot could not be read: {e}")
                        }
                    });
                }
            }
            Ok(format!(
                "no section row is titled {title:?} (the switchers carry: {seen:?})"
            ))
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn select_section(&self, index: usize) {
        // The user's route: reconcile, move the switcher under the
        // swallow counter, and emit exactly once — the synchronous-
        // emit pattern set_text uses (SelectionChanged raises async).
        Self::on_ui_mut(move |core| {
            let ids = core.sections.get(&0).cloned().unwrap_or_default();
            let Some(&sid) = ids.get(index) else { return Ok(()) };
            if core.selected_sections.get(&0) == Some(&sid) {
                return Ok(());
            }
            core.selected_sections.insert(0, sid);
            core.scene
                .user_selected_section(WindowId(0), WindowId(sid));
            nav_set_selected(core, 0, sid)?;
            show_section_pane(core, 0, sid)?;
            core.occurrences.send(Occurrence::SectionSelected {
                window: WindowId(0),
                section: WindowId(sid),
            });
            Ok(())
        });
    }

    fn finish(&self, code: i32, verdict: &str) {
        // THE APARTMENT GUARD, on the path every scene in every language
        // leaves by. A first-chance RPC_E_DISCONNECTED means some apartment
        // in this process closed while the Shell still held proxies into it —
        // the defect `dialog_apartment` describes — and four of the five
        // guest runtimes swallow it without a mark, so the scene has to look.
        let disconnects = COM_DISCONNECTS.load(std::sync::atomic::Ordering::Relaxed);
        let synthesized;
        let (code, verdict) = if code == 0 && disconnects > 0 {
            synthesized = format!(
                "KAYA_SELFTEST: FAILED ({disconnects} first-chance RPC_E_DISCONNECTED \
                 (0x80010108) — a COM apartment closed while the Shell still held \
                 proxies into it; see dialog_apartment in crates/kaya/src/winui/mod.rs)"
            );
            (1, synthesized.as_str())
        } else {
            (code, verdict)
        };
        if code == 0 {
            println!("{verdict}");
        } else {
            eprintln!("{verdict}");
        }
        // THE HOP IS THE EXIT (docs/traps.md: exit() is not final on Windows):
        // the orderly path is ExitProcess, which TERMINATES the grace's own
        // threads before the loader shutdown it then wedges in — seven dialog
        // legs held ~60s past their verdict with no grace sentence. The
        // verdict is out; request_exit stays the non-harness close path.
        Self::on_ui(move |_| -> windows_core::Result<()> {
            crate::harness::harness_exit(code)
        });
    }
}


/// The widget id behind a harness target, recovered by COM identity from the
/// creation-ordered registry. Context anchors in the scenes are labels;
/// other kinds join as scenes demand them — an unwired kind fails loudly.
// Harness-only, like GTK's context_anchor_id: its sole caller is the
// Stage impl and it speaks harness types.
#[cfg(feature = "harness")]
fn widget_id_for_target(core: &CoreState, t: crate::harness::Target) -> u64 {
    match t.kind {
        crate::harness::TargetKind::Label => {
            let i = crate::harness::resolve(t.index, core.labels.len());
            let block = core.labels[i].clone();
            core.widgets
                .iter()
                .find_map(|(id, w)| match w {
                    NativeWidget::Label(l) if *l == block => Some(id.0),
                    _ => None,
                })
                .expect("registry labels live in the widget table")
        }
        // ACCESSIBILITY needs every kind, not just the Label this function was
        // written for, so returning 0 makes the caller report "no such
        // target" — a panic here is raised inside the UI closure and surfaces
        // as an opaque `RecvError`. NOT YET RESOLVED: the remaining kinds need
        // real lookups; Button and Checkbox are STRUCT variants and
        // core.buttons holds tags rather than widgets.
        _ => 0,
    }
}

/// Depth-first search for the ContentDialog template button with the
/// given part name (PrimaryButton/SecondaryButton) under an element —
/// how the runner presses the REAL button (see choose_alert).
fn find_template_button(
    element: &UIElement,
    part: &str,
) -> windows_core::Result<Option<Button>> {
    use bindings::Microsoft::UI::Xaml::Media::VisualTreeHelper;
    if let Ok(button) = element.cast::<Button>() {
        if let Ok(fe) = element.cast::<FrameworkElement>() {
            if fe.Name()?.to_string() == part {
                return Ok(Some(button));
            }
        }
    }
    let count = VisualTreeHelper::GetChildrenCount(element)?;
    for i in 0..count {
        let child = VisualTreeHelper::GetChild(element, i)?;
        if let Ok(child) = child.cast::<UIElement>() {
            if let Some(found) = find_template_button(&child, part)? {
                return Ok(Some(found));
            }
        }
    }
    Ok(None)
}

/// What `ax` answers when the platform published a role kaya's closed set
/// has no name for. Named because two places need it: the ladder that
/// returns it and the trace that reports it.
#[cfg(feature = "harness")]
const UNMAPPED_ROLE: &str = "unknown";

/// THE ROLE HALF OF THE `ax` VERB, as a pure function of the two things UIA
/// answered with. `heading` comes FIRST, which is the whole reason this is a
/// function rather than an inline ladder: UIA has no heading control type,
/// so a heading TextBlock reports `Text` and a type-first ladder would
/// answer `label` for every heading kaya declares. The compiler cannot see
/// that ordering, so `mod tests` below does.
#[cfg(feature = "harness")]
fn ax_role(heading: bool, kind: AutomationControlType) -> &'static str {
    if heading {
        // Spelled the way every other backend spells it,
        // `heading/<the label's text>` — ONE word for all nine levels,
        // because a shared scene cannot freeze a per-platform level ladder
        // (docs/styling-plan.md D4).
        "heading"
    } else if kind == AutomationControlType::Button {
        "button"
    } else if kind == AutomationControlType::CheckBox {
        "checkbox"
    } else if kind == AutomationControlType::Edit {
        "field"
    } else if kind == AutomationControlType::Text {
        "label"
    } else if kind == AutomationControlType::Slider {
        "slider"
    } else if kind == AutomationControlType::Image {
        "image"
    } else if kind == AutomationControlType::ProgressBar {
        "progress"
    } else if kind == AutomationControlType::ComboBox {
        // The chooser, spelled `combobox` in the closed set:
        // AXPopUpButton on macOS, a UIButton owning a menu on iOS,
        // Role.DropdownList on Compose, ComboBox here and on AT-SPI.
        "combobox"
    } else if kind == AutomationControlType::Group
        || kind == AutomationControlType::Pane
        || kind == AutomationControlType::List
    {
        // NORMALIZED to the coarsest container role every platform publishes:
        // UIA distinguishes Group, Pane and List (a RadioButtons group is a
        // List here), and the closed set has one name for "a container an
        // assistive client steps into".
        "group"
    } else {
        UNMAPPED_ROLE
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// THE DEFERRED RE-STAMP PUTS EVERY CHILD ON THE TRACK THE EAGER ONE DID,
    /// once per container per batch. `reindex` rebuilds every track and
    /// re-writes every sibling's index, so running it per AddChild made N
    /// appends N^2/2 WinRT round trips — 4.7s for 2,500 rows, 77.6s for
    /// 10,000, choking at 12,000
    /// (docs/measurements/choke-windows-2026-08-24.txt).
    #[test]
    fn the_deferred_rebuild_places_every_child_where_the_eager_one_did() {
        use std::collections::BTreeMap;

        // A plain column and a declared table, whose rows sit two tracks
        // down. Children: a b c d under the column, r0 r1 r2 under the
        // table.
        const COLUMN: WidgetId = WidgetId(1);
        const TABLE: WidgetId = WidgetId(2);
        let (a, b, c, d) = (WidgetId(10), WidgetId(11), WidgetId(12), WidgetId(13));
        let (r0, r1, r2) = (WidgetId(20), WidgetId(21), WidgetId(22));

        #[derive(Clone, Copy, Debug)]
        enum Edit {
            /// AddChild.
            Append(WidgetId, WidgetId),
            /// MoveChild.
            Place(WidgetId, WidgetId, Option<WidgetId>),
            /// Destroy, on a child.
            Detach(WidgetId),
            /// The `grow` prop: the ORDER does not move and the track's
            /// size does, so the container is marked through the child's
            /// parent — the lookup that replaced a scan over every
            /// container.
            Grow(WidgetId),
            /// Destroy, on the container itself.
            Forget(WidgetId),
        }

        /// The container this edit re-stamps, which is what the eager arm
        /// passed to `reindex` on the spot.
        fn edit(order: &mut ChildOrder, e: Edit) -> Option<WidgetId> {
            match e {
                Edit::Append(parent, child) => {
                    order.append(parent, child);
                    Some(parent)
                }
                Edit::Place(parent, child, before) => {
                    order.place(parent, child, before);
                    Some(parent)
                }
                Edit::Detach(child) => order.detach(child),
                Edit::Grow(child) => {
                    let parent = order.parent_of(child);
                    if let Some(parent) = parent {
                        order.mark(parent);
                    }
                    parent
                }
                Edit::Forget(container) => {
                    order.forget(container);
                    None
                }
            }
        }

        /// `reindex`'s placement, without its COM half.
        fn stamp(
            into: &mut BTreeMap<u64, Vec<(u64, i32)>>,
            order: &ChildOrder,
            container: WidgetId,
        ) {
            let head = if container == TABLE { 1 } else { 0 };
            into.insert(
                container.0,
                order
                    .children(container)
                    .iter()
                    .enumerate()
                    .map(|(at, child)| (child.0, track_of(at, head)))
                    .collect(),
            );
        }

        use Edit::*;
        let script: [&[Edit]; 6] = [
            // The build.
            &[
                Append(COLUMN, a),
                Append(COLUMN, b),
                Append(COLUMN, c),
                Append(TABLE, r0),
                Append(TABLE, r1),
                Append(TABLE, r2),
            ],
            // A sort: a move and nothing else.
            &[Place(COLUMN, c, Some(a)), Place(TABLE, r2, Some(r0))],
            // A removal and nothing else.
            &[Detach(a), Detach(r0)],
            // A weight, which moves no child and re-sizes a track.
            &[Grow(b), Grow(r1)],
            // The shape a For's update really has.
            &[
                Append(COLUMN, d),
                Detach(b),
                Place(COLUMN, d, Some(c)),
                Append(TABLE, r0),
                Detach(r2),
                Place(TABLE, r0, Some(r1)),
            ],
            // A marked container destroyed inside its own batch: the mark
            // goes with it, so the flush does not chase a dead Grid.
            &[Grow(r1), Forget(TABLE)],
        ];
        let want: [&[(u64, &[(u64, i32)])]; 6] = [
            &[(1, &[(10, 0), (11, 1), (12, 2)]), (2, &[(20, 1), (21, 2), (22, 3)])],
            &[(1, &[(12, 0), (10, 1), (11, 2)]), (2, &[(22, 1), (20, 2), (21, 3)])],
            &[(1, &[(12, 0), (11, 1)]), (2, &[(22, 1), (21, 2)])],
            &[(1, &[(12, 0), (11, 1)]), (2, &[(22, 1), (21, 2)])],
            &[(1, &[(13, 0), (12, 1)]), (2, &[(20, 1), (21, 2)])],
            &[(1, &[(13, 0), (12, 1)]), (2, &[(20, 1), (21, 2)])],
        ];
        // ONE re-stamp per container per batch — the whole point, and the
        // number the eager arm got wrong: 6, 2, 2, 2, 6 edits against
        // these. The last batch re-stamps NOTHING: its one marked
        // container was destroyed before the boundary.
        let want_restamps: [&[u64]; 6] = [&[1, 2], &[1, 2], &[1, 2], &[1, 2], &[1, 2], &[]];

        let mut eager_order = ChildOrder::default();
        let mut deferred_order = ChildOrder::default();
        let mut eager: BTreeMap<u64, Vec<(u64, i32)>> = BTreeMap::new();
        let mut deferred: BTreeMap<u64, Vec<(u64, i32)>> = BTreeMap::new();
        for (n, batch) in script.iter().enumerate() {
            for e in *batch {
                if let Some(container) = edit(&mut eager_order, *e) {
                    stamp(&mut eager, &eager_order, container);
                }
            }
            for e in *batch {
                edit(&mut deferred_order, *e);
            }
            let mut restamped: Vec<u64> = Vec::new();
            while let Some(container) = deferred_order.next_due() {
                stamp(&mut deferred, &deferred_order, container);
                restamped.push(container.0);
            }
            assert_eq!(
                deferred, eager,
                "batch {n} places a child on a different track than the eager \
                 re-stamp did — a structural change that did not mark its \
                 container leaves the batch's boundary with nothing to rebuild"
            );
            let frozen: BTreeMap<u64, Vec<(u64, i32)>> = want[n]
                .iter()
                .map(|(container, tracks)| (*container, tracks.to_vec()))
                .collect();
            assert_eq!(deferred, frozen, "batch {n} does not place children where it must");
            assert_eq!(
                restamped, want_restamps[n],
                "batch {n} re-stamped the wrong containers, or one of them twice — \
                 an append that re-stamps per child is the N^2 this replaced"
            );
        }
        // The destroyed container's children stop naming it: a stale
        // reverse entry would send the next `grow` on one of them at a
        // dead Grid.
        assert_eq!(deferred_order.parent_of(r0), None);
        assert_eq!(deferred_order.parent_of(r1), None);
        println!("batches: 6, edits: 20, re-stamps: 10");
    }

    /// THE SPACER IDENTITY (docs/virtualization-plan.md §4): top spacer +
    /// the realized band + bottom spacer IS the collection's extent, and
    /// the band's first row sits exactly at the core's offset. Both
    /// numbers come from the core; this holds the one arithmetic step
    /// this tier performs on them.
    #[test]
    fn the_two_spacers_span_exactly_what_the_band_does_not() {
        // 15,000 uniform 28dip rows, a 40-row band starting at row 7,500.
        let (extent, offset, banded) = (15_000.0 * 28.0, 7_500.0 * 28.0, 40.0 * 28.0);
        let (top, bottom) = band_spacers(offset, extent, banded);
        assert_eq!(top, offset, "the band's first row sits where the core says");
        assert_eq!(top + banded + bottom, extent, "and the scrollbar spans the collection");
        // At the top and at the end the spacer that has nothing to span
        // is zero, not a gap and not a negative track.
        assert_eq!(band_spacers(0.0, 280.0, 280.0), (0.0, 0.0));
        assert_eq!(band_spacers(252.0, 280.0, 28.0), (252.0, 0.0));
        // A correction that lands between the geometry read and the
        // layout can make the band measure more than the extent below it;
        // a negative track is not a thing to reserve.
        assert_eq!(band_spacers(100.0, 200.0, 150.0), (100.0, 0.0));
    }

    /// WHAT `expect_window` COMPARES is the FIRST VISIBLE row, read off the
    /// band's own tracks — not the band's first, which carries a viewport of
    /// overscan above it. A viewport parked in a SPACER has no row to read,
    /// so the tier answers with the collection's mean row, says it is an
    /// estimate, and reads real tracks next cycle; with NEITHER viewport nor
    /// extent it measured nothing and answers `None`.
    #[test]
    fn the_first_visible_row_is_read_off_the_band_then_estimated() {
        let geometry = |first: usize, count: usize| crate::scene::WindowGeometry {
            first,
            count,
            total: 1_000,
            offset: first as f64 * 20.0,
            extent: 20_000.0,
            anchor_shift: 0.0,
            corrected: false,
        };
        // A band of 30 rows from 100, viewport 200dip (10 rows) parked on
        // row 110 — one viewport of overscan above it.
        let tracks = vec![20.0; 30];
        let g = geometry(100, 30);
        assert_eq!(table_visible_rows(&g, g.offset, &tracks, 2_200.0, 200.0), Some((110, 10)));
        // The band's own first row, when the viewport is at its top.
        assert_eq!(table_visible_rows(&g, g.offset, &tracks, 2_000.0, 200.0), Some((100, 10)));
        // Half a row of overlap still counts as visible at both edges.
        assert_eq!(table_visible_rows(&g, g.offset, &tracks, 2_010.0, 200.0), Some((100, 11)));
        // VARIABLE HEIGHTS: the tracks are read, never a pitch.
        let varied = vec![10.0, 60.0, 10.0, 10.0];
        let g = geometry(0, 4);
        assert_eq!(table_visible_rows(&g, 0.0, &varied, 0.0, 70.0), Some((0, 2)));
        assert_eq!(table_visible_rows(&g, 0.0, &varied, 70.0, 20.0), Some((2, 2)));
        // Parked in a spacer: no track intersects, so the mean answers.
        let g = geometry(0, 0);
        assert_eq!(table_visible_rows(&g, 0.0, &[], 10_000.0, 200.0), Some((500, 10)));
        // NEITHER a viewport nor an extent: nothing was measured, and
        // nothing is reported. A band with rows in it reaches here too —
        // that is the case the doubling rode in on.
        let bare = |count: usize| crate::scene::WindowGeometry {
            first: 0,
            count,
            total: 1_000,
            offset: 0.0,
            extent: 0.0,
            anchor_shift: 0.0,
            corrected: false,
        };
        assert_eq!(table_visible_rows(&bare(0), 0.0, &[], 0.0, 0.0), None);
        assert_eq!(table_visible_rows(&bare(128), 0.0, &[20.0; 128], 0.0, 0.0), None);
        // A live viewport whose collection has still measured nothing is
        // the same admission: the mean does not exist yet.
        assert_eq!(table_visible_rows(&bare(128), 0.0, &[], 0.0, 400.0), None);
        // AND THE OTHER HALF: a collection that HAS been measured, in a
        // tier with no viewport (never laid out, or a minimized window).
        // The mean exists, so an arm that guarded on the mean alone
        // would divide a zero viewport by it and invent a ONE-ROW
        // visible range — tearing the band down to two rows on a
        // measurement nobody made.
        let measured = crate::scene::WindowGeometry {
            first: 0,
            count: 128,
            total: 1_000,
            offset: 0.0,
            extent: 20_000.0,
            anchor_shift: 0.0,
            corrected: false,
        };
        assert_eq!(table_visible_rows(&measured, 0.0, &[20.0; 128], 0.0, 0.0), None);
        // An empty collection realizes nothing — and THAT is measured.
        let empty = crate::scene::WindowGeometry {
            first: 0,
            count: 0,
            total: 0,
            offset: 0.0,
            extent: 0.0,
            anchor_shift: 0.0,
            corrected: false,
        };
        assert_eq!(table_visible_rows(&empty, 0.0, &[], 0.0, 400.0), Some((0, 0)));
    }

    /// THE FIXPOINT THE REPORT LOOP RESTS ON, driven against the CORE's own
    /// band arithmetic. `RowWindow::band` adds an overscan to every report, so
    /// a cycle answering with the realized band's own count hands the core a
    /// band twice the size and the next cycle doubles again (docs/traps.md:
    /// The band that fed itself). NO SCENE CAN FAIL THIS: a tier that
    /// realizes every row answers every windowing observable correctly and
    /// just does it slowly (docs/virtualization-plan.md §5).
    #[test]
    fn a_report_may_not_be_the_band_it_was_given() {
        let total = 15_000;
        let mut window = crate::rowwindow::RowWindow::default();
        window.plant_seed(128);
        assert_eq!(window.band(total), 0..128, "the seed bounds the first fill");
        // Seven cycles of the pre-layout state the lane measured: no
        // viewport, no extent, and whatever the band currently holds.
        for cycle in 0..7 {
            let band = window.band(total);
            let geometry = crate::scene::WindowGeometry {
                first: band.start,
                count: band.len(),
                total,
                offset: 0.0,
                extent: 0.0,
                anchor_shift: 0.0,
                corrected: false,
            };
            let tracks = vec![0.0; band.len()];
            let visible = table_visible_rows(&geometry, 0.0, &tracks, 0.0, 0.0);
            assert_eq!(
                visible, None,
                "cycle {cycle}: a cycle that measured nothing reported \
                 {visible:?}, and the core bands a report with an overscan \
                 on it — so THAT is the next cycle's band"
            );
            if let Some((first, count)) = visible {
                window.report(first, count);
            }
        }
        assert_eq!(
            window.band(total),
            0..128,
            "seven unmeasured cycles left the seed's band untouched"
        );
        // And the amplification this holds shut, stated as arithmetic so
        // the number in the sentence above is checked and not recalled:
        // one report of the band's own count IS a doubling.
        let mut fed = crate::rowwindow::RowWindow::default();
        fed.report(0, 128);
        assert_eq!(fed.band(total), 0..256);
        fed.report(0, 256);
        assert_eq!(fed.band(total), 0..512);
    }

    /// THE FOUR LINKS OF THE REPORT LOOP, HELD STATICALLY — because no scene
    /// can fail one of them. Measured 2026-08-25 with the perturbation
    /// watched: delete the range report from `table_report_once` and
    /// windowed.steps, portfolio.steps and varied.steps ALL STAY GREEN, since
    /// every scroll is `scroll_to_row`, which bands at its own call site
    /// (docs/virtualization-plan.md §5).
    #[test]
    fn every_link_of_the_report_loop_is_still_wired() {
        const SRC: &str = include_str!("mod.rs");

        /// One top-level function's body, from `fn NAME(` to the closing
        /// brace in column 0.
        fn body(name: &str) -> &'static str {
            let head = format!("\nfn {name}(");
            let start = SRC.find(&head).unwrap_or_else(|| panic!("no top-level fn {name}"));
            let end = SRC[start + 1..].find("\n}\n").expect("unterminated fn") + start + 1;
            &SRC[start..end]
        }

        /// One method's body, from `fn NAME(` to the closing brace at the
        /// impl's own indent.
        fn method(name: &str) -> &'static str {
            let head = format!("\n    fn {name}(");
            let start = SRC.find(&head).unwrap_or_else(|| panic!("no method {name}"));
            let end = SRC[start + 1..].find("\n    }\n").expect("unterminated method") + start + 1;
            &SRC[start..end]
        }

        let clauses: [(&str, &str, &str); 7] = [
            // The band panel's own two tracks, built by the ONE thing
            // that places a Column's children.
            ("reindex", body("reindex"), "def.SetHeight(spacer(*top))"),
            ("reindex ", body("reindex"), "def.SetHeight(spacer(*bottom))"),
            // The range report (§3.2): the band follows what is on screen.
            ("table_report_once", body("table_report_once"), "table_band_to(core, id, visible)"),
            // The verify half (§3.4): the realized rows' measured extents.
            ("table_measure_rows", body("table_measure_rows"), "core.scene.rows_measured(id, first, &tracks)"),
            // The spacers (§4): the core's own offset and what is left
            // below it, written onto the band panel's two tracks.
            ("table_write_spacers", body("table_write_spacers"), "defs.GetAt(0)?.SetHeight(pixel(top))"),
            ("table_write_spacers ", body("table_write_spacers"), "defs.GetAt(n - 1)?.SetHeight(pixel(bottom))"),
            // The anchor (§2.4): scroll_to_row parks a ROW, and the
            // re-park inside the report cycle is what follows it through
            // a correction.
            ("table_report_once ", body("table_report_once"), "table_scroll_to(&host, id, want)"),
        ];
        for (what, text, call) in clauses {
            assert!(
                text.contains(call),
                "{what} no longer calls `{call}` — the row window's report loop \
                 has a link missing, and NO SCENE CAN SEE IT"
            );
        }
        // scroll_to_row's own two halves: band by index, then park.
        let scroll = method("scroll_to_row");
        for call in ["table_band_to(core, id, (index, count))", "w.anchor = Some(index)"] {
            assert!(
                scroll.contains(call),
                "the scroll_to_row verb no longer calls `{call}`"
            );
        }
        println!("report-loop links held: {} clauses + 2", clauses.len());
    }

    #[test]
    fn table_viewport_rejects_overflow() {
        assert!(table_content_fits(102.0, 100.0));
        assert!(!table_content_fits(102.1, 100.0));
    }

    /// SIX CAUSES, SIX SENTENCES, and the precedence between them; both sides
    /// of every 2.0 boundary are pinned, because that slack is what keeps a
    /// subpixel arrange from reddening a correct table. ColumnsUnreachable is
    /// the measured case this exists for: a table overflowing a 300dip
    /// viewport printed "cells span 290dip inside a 300dip viewport". The two
    /// UNDERFILL directions are held too (docs/deferred.md), after a table
    /// starting 40dip inside its viewport read RED on Linux and GREEN here.
    #[test]
    fn table_horizontal_issue_convicts_one_cause() {
        use TableHorizontalIssue as Issue;
        // A table that CANNOT scroll its columns is the default here,
        // which is what every claim written before the 2026-08-29 ruling
        // assumed; the ruling's own cases below pass a real reach.
        let issue = |d: f64, t: f64, v: f64, s: f64, e: f64, m: f64| {
            table_horizontal_issue(d, t, v, s, e, m, 0.0)
        };
        let say = |d: f64, t: f64, v: f64, s: f64, e: f64, m: f64| {
            table_horizontal_complaint(d, t, v, s, e, m, 0.0)
        };
        // drawn, track, viewport, min_start, min_end, max_end — a table
        // filling its track and its viewport, every line flush inside:
        // silent.
        assert_eq!(issue(100.0, 100.0, 100.0, 0.0, 100.0, 100.0), None);
        assert_eq!(say(100.0, 100.0, 100.0, 0.0, 100.0, 100.0), "");

        // Every sentence below is read off six PAIRWISE DISTINCT
        // numbers, so an arm that prints the wrong one of the six is a
        // red rather than a coincidence.
        assert_eq!(issue(98.0, 100.0, 100.0, 0.0, 98.0, 98.0), None);
        assert_eq!(
            issue(97.9, 100.0, 100.0, 0.0, 97.9, 97.9),
            Some(Issue::TrackUnderfill)
        );
        assert_eq!(
            say(80.0, 120.0, 100.0, 0.0, 70.0, 75.0),
            "draws 80dip of a 120dip track"
        );

        assert_eq!(issue(102.0, 100.0, 100.0, 0.0, 100.0, 100.0), None);
        assert_eq!(
            issue(102.1, 100.0, 100.0, 0.0, 100.0, 100.0),
            Some(Issue::ColumnsUnreachable)
        );
        assert_eq!(
            say(140.0, 120.0, 100.0, 0.0, 105.0, 110.0),
            "columns resolve to 140dip in a 100dip viewport that scrolls 0dip"
        );

        assert_eq!(issue(100.0, 100.0, 100.0, 2.0, 100.0, 100.0), None);
        assert_eq!(
            issue(100.0, 100.0, 100.0, 2.1, 100.0, 100.0),
            Some(Issue::ContentLeftUnderfill)
        );
        assert_eq!(
            say(98.0, 99.0, 100.0, 40.0, 130.0, 140.0),
            "cells start at 40dip inside a 100dip viewport"
        );

        assert_eq!(issue(100.0, 100.0, 100.0, -2.0, 100.0, 100.0), None);
        assert_eq!(
            issue(100.0, 100.0, 100.0, -2.1, 100.0, 100.0),
            Some(Issue::ContentLeftOverflow)
        );
        assert_eq!(
            say(98.0, 99.0, 100.0, -40.0, 85.0, 90.0),
            "cells start at -40dip outside a 100dip viewport"
        );

        assert_eq!(issue(100.0, 100.0, 100.0, 0.0, 98.0, 100.0), None);
        assert_eq!(
            issue(100.0, 100.0, 100.0, 0.0, 97.9, 100.0),
            Some(Issue::ContentUnderfill)
        );
        assert_eq!(
            say(98.0, 99.0, 100.0, 0.0, 70.0, 95.0),
            "draws 70dip of a 100dip viewport"
        );

        assert_eq!(issue(100.0, 100.0, 100.0, 0.0, 100.0, 102.0), None);
        assert_eq!(
            issue(100.0, 100.0, 100.0, 0.0, 100.0, 102.1),
            Some(Issue::ContentUnreachable)
        );
        assert_eq!(
            say(98.0, 99.0, 100.0, 0.0, 105.0, 140.0),
            "cells end at 140dip past a 100dip viewport that scrolls 0dip"
        );

        // THE RULING'S OWN CASE (docs/tables-plan.md): columns wider than the
        // track are what a scrolling table looks like, and they convict only
        // where the surface cannot reach them.
        let reach = table_horizontal_issue;
        assert_eq!(
            reach(160.0, 100.0, 100.0, 0.0, 160.0, 160.0, 60.0),
            None,
            "a table that can scroll to its last column is correct"
        );
        assert_eq!(
            reach(160.0, 100.0, 100.0, 0.0, 160.0, 160.0, 40.0),
            Some(Issue::ColumnsUnreachable),
            "20dip of columns nothing can scroll to is the defect"
        );
        assert_eq!(
            reach(160.0, 100.0, 100.0, 0.0, 160.0, 160.0, 0.0),
            Some(Issue::ColumnsUnreachable),
            "a clipping table is the pre-ruling behaviour and is refused"
        );
        // The INK clause takes the same reach: cells legitimately run
        // that far past the viewport and not one dip further.
        assert_eq!(reach(100.0, 100.0, 100.0, 0.0, 100.0, 142.0, 40.0), None);
        assert_eq!(
            reach(100.0, 100.0, 100.0, 0.0, 100.0, 142.1, 40.0),
            Some(Issue::ContentUnreachable)
        );
        assert_eq!(
            table_horizontal_complaint(140.0, 120.0, 100.0, 0.0, 105.0, 110.0, 7.0),
            "columns resolve to 140dip in a 100dip viewport that scrolls 7dip"
        );
        assert_eq!(
            table_horizontal_complaint(98.0, 99.0, 100.0, 0.0, 105.0, 140.0, 7.0),
            "cells end at 140dip past a 100dip viewport that scrolls 7dip"
        );

        // PRECEDENCE where several hold at once, which is the ordinary
        // case: the root is reported, never its symptom. Track, then the
        // LEADING edge, then the trailing one — one order in all four
        // backends (gtk.rs's `TableHorizontalIssue`).
        assert_eq!(
            issue(80.0, 100.0, 100.0, -40.0, 60.0, 200.0),
            Some(Issue::TrackUnderfill)
        );
        assert_eq!(
            issue(140.0, 100.0, 100.0, 0.0, 60.0, 140.0),
            Some(Issue::ColumnsUnreachable)
        );
        // A table displaced at its leading edge also ends in the wrong
        // place, both ways round: the end is the symptom either way.
        assert_eq!(
            issue(100.0, 100.0, 100.0, 40.0, 60.0, 60.0),
            Some(Issue::ContentLeftUnderfill)
        );
        assert_eq!(
            issue(100.0, 100.0, 100.0, -40.0, 60.0, 140.0),
            Some(Issue::ContentLeftOverflow)
        );
        // A line that ends SHORT outranks another line that ends long —
        // the header-versus-rows split is the root, the spill its
        // symptom.
        assert_eq!(
            issue(100.0, 100.0, 100.0, 0.0, 60.0, 140.0),
            Some(Issue::ContentUnderfill)
        );

        // The reproduction: 310dip of columns in a 300dip viewport, ink
        // from 5 to 295 — a 290dip span that reads compliant.
        assert_eq!(
            issue(310.0, 300.0, 300.0, 5.0, 290.0, 295.0),
            Some(Issue::ColumnsUnreachable)
        );
        assert_eq!(
            say(310.0, 300.0, 300.0, 5.0, 290.0, 295.0),
            "columns resolve to 310dip in a 300dip viewport that scrolls 0dip"
        );
    }

    /// THE FIELD'S OWN GEOMETRY, from the windows lane that convicted every
    /// table-bearing leg on 2026-08-25 (docs/deferred.md): a 508dip viewport,
    /// two 250dip tracks 8dip apart, and a row whose text stops at 289. The
    /// line ENDS at 508 and its INK ends at 289, and the whole failure was
    /// reading the second number for the first, so both are pinned here.
    #[test]
    fn table_line_end_reads_the_track_not_the_ink() {
        use TableHorizontalIssue as Issue;
        // A table that fits needs no reach (the ruling's own cases are
        // in the truth table above).
        let issue = |d: f64, t: f64, v: f64, s: f64, e: f64, m: f64| {
            table_horizontal_issue(d, t, v, s, e, m, 0.0)
        };
        let say = |d: f64, t: f64, v: f64, s: f64, e: f64, m: f64| {
            table_horizontal_complaint(d, t, v, s, e, m, 0.0)
        };
        // Column 0: track 0..250, a 40dip label. Column 1: track
        // 258..508, a 31dip label — 289 is where its ink stops.
        let line = [
            TableCellBox { ink_start: 0.0, ink_end: 40.0, track_start: 0.0, track_end: 250.0 },
            TableCellBox {
                ink_start: 258.0,
                ink_end: 289.0,
                track_start: 258.0,
                track_end: 508.0,
            },
        ];
        assert_eq!(table_line_end(&line), Some(508.0));
        assert_eq!(table_line_end(&[]), None);
        // The ink basis, computed here so the number the lane printed is
        // on the record beside the one that replaced it.
        let ink_end = line.iter().fold(f64::NEG_INFINITY, |far, cell| far.max(cell.ink_end));
        assert_eq!(ink_end, 289.0);

        // A LINE WHOSE INK ENDS SHORT WHILE ITS TRACKS SPAN IS CORRECT.
        // This is the case the host taught us and no arithmetic could:
        // min_end from the track is silent, max_end from the ink is too,
        // because ink stopping early is what a text cell does.
        assert_eq!(issue(508.0, 508.0, 508.0, 0.0, 508.0, ink_end), None);
        assert_eq!(say(508.0, 508.0, 508.0, 0.0, 508.0, ink_end), "");

        // And the same table under the OLD basis — the exact sentence
        // every table-bearing windows leg printed.
        assert_eq!(
            issue(508.0, 508.0, 508.0, 0.0, ink_end, ink_end),
            Some(Issue::ContentUnderfill)
        );
        assert_eq!(
            say(508.0, 508.0, 508.0, 0.0, ink_end, ink_end),
            "draws 289dip of a 508dip viewport"
        );

        // The gutter this instrument is FOR still convicts: rows 16dip
        // narrower than the pinned header because a scrollbar reserved
        // its width. The tracks are what shrank, so the track basis sees
        // it — which is the half a global maximum could never do.
        assert_eq!(
            issue(508.0, 508.0, 508.0, 0.0, 492.0, ink_end),
            Some(Issue::ContentUnderfill)
        );
    }

    /// A PADDED CARD CONVICTS NOTHING (docs/deferred.md's table-card entry):
    /// the card's interior rides the CONTAINER's Padding, so it is `pad` —
    /// the number `column_edges` already takes off the frame AND the ink —
    /// and a cell edge cannot move because both sides of every comparison
    /// move together. The second half is the one that would ship silently: a
    /// frame that FORGETS the subtraction convicts every padded table.
    #[test]
    fn a_padded_card_convicts_nothing() {
        use TableHorizontalIssue as Issue;
        let issue = |d: f64, t: f64, v: f64, s: f64, e: f64, m: f64| {
            table_horizontal_issue(d, t, v, s, e, m, 0.0)
        };
        // The field's own numbers with a 12dip card: a 508dip grid, ink
        // and tracks starting at the padding edge and ending 12 short of
        // the far one.
        let (pad, outer) = (TABLE_CARD_PAD, 508.0);
        let inner = outer - 2.0 * pad;
        let (track, viewport, min_start, min_end, max_end) =
            table_content_frame(pad, outer, outer, (pad, outer - pad, outer - pad));
        assert_eq!((track, viewport, min_start), (inner, inner, 0.0));
        assert_eq!((min_end, max_end), (inner, inner));
        assert_eq!(issue(inner, track, viewport, min_start, min_end, max_end), None);

        // THE BASIS THAT FORGETS: the same live geometry read straight
        // out of the toolkit, with no pad taken off anything.
        assert_eq!(
            issue(inner, outer, outer, pad, outer - pad, outer - pad),
            Some(Issue::TrackUnderfill)
        );
        // And with the frame corrected but the INK left in the padding
        // box — the half a partial fix would leave behind.
        assert_eq!(
            issue(inner, track, viewport, pad, outer - pad, outer - pad),
            Some(Issue::ContentLeftUnderfill)
        );
    }

    /// One theme dictionary's markup, from its key to its close.
    fn section(xaml: &str, key: &str) -> String {
        let at = xaml
            .find(&format!("x:Key=\"{key}\""))
            .unwrap_or_else(|| panic!("no {key} theme dictionary in {xaml}"));
        let rest = &xaml[at..];
        let close = rest
            .find("</ResourceDictionary>")
            .expect("a theme dictionary closes");
        rest[..close].to_owned()
    }

    /// THE CROSS-READ, WHICH IS THIS ARM'S ONE LANDMINE: Fluent's stop names
    /// say how light the SHADE is, not which theme owns it, so the LIGHT
    /// theme reads `SystemAccentColorDark1` and the DARK theme
    /// `SystemAccentColorLight2`. Backwards brands one appearance and leaves
    /// the user's accent in the other, and no read-back in this process can
    /// catch it. Each stop is pinned to the WORD the core derived for it.
    #[test]
    fn the_stops_are_crossed_and_carry_the_word_their_consumer_wants() {
        let accent = crate::brand::derive(0x3584E4, None, None);
        let xaml = brand_dictionary(&accent);
        let light = section(&xaml, "Light");
        let dark = section(&xaml, "Dark");
        let entry = |stop: &str, rgb: u32| format!("x:Key=\"{stop}\">#FF{rgb:06X}<");
        for (which, dict, wants, forbidden) in [
            (
                "Light",
                &light,
                vec![
                    entry("SystemAccentColorDark1", accent.light.fill),
                    entry("SystemAccentColorDark2", accent.light.standalone),
                    entry("SystemAccentColorDark3", accent.light.hover),
                ],
                "SystemAccentColorLight",
            ),
            (
                "Dark",
                &dark,
                vec![
                    entry("SystemAccentColorLight2", accent.dark.fill),
                    entry("SystemAccentColorLight3", accent.dark.standalone),
                    entry("SystemAccentColorLight1", accent.dark.hover),
                ],
                "SystemAccentColorDark",
            ),
        ] {
            for want in wants {
                assert!(
                    dict.contains(&want),
                    "the {which} theme dictionary is missing {want}\n{dict}"
                );
            }
            assert!(
                !dict.contains(forbidden),
                "the {which} theme dictionary writes a {forbidden}* stop — the \
                 cross-read is inverted, which brands one appearance and leaves \
                 the other on the user's system accent\n{dict}"
            );
        }
    }

    /// THE ORDERING NO COMPILER CAN SEE. UIA publishes no heading control
    /// type: the styling pass's heading is a TextBlock whose peer answers
    /// `AutomationControlType::Text` either way, so the ONLY evidence is the
    /// HeadingLevel property and the ladder must consult it first — get that
    /// backwards and every heading reads `label/Sections` where
    /// tools/scenes/styling.steps froze `heading/Sections`.
    /// (`AutomationControlType::Header` is a table's header, not this.)
    #[test]
    #[cfg(feature = "harness")]
    fn a_heading_outranks_the_control_type_its_peer_reports() {
        assert_eq!(ax_role(true, AutomationControlType::Text), "heading");
        // The same element with the role absent. The two calls differ in
        // the property alone, which is the entire claim.
        assert_eq!(ax_role(false, AutomationControlType::Text), "label");
    }

    /// THE REST OF THE LADDER, PINNED BECAUSE THE HEADING BRANCH WAS INSERTED
    /// AT THE TOP OF IT. Every word here is bytes in a shared scene's
    /// expected string (tools/scenes/*.steps, compared byte-for-byte across
    /// all eight languages), so a dropped or re-spelled arm is a matrix
    /// failure on a lane this machine cannot run. The three container types
    /// collapsing to one word is deliberate.
    #[test]
    #[cfg(feature = "harness")]
    fn the_closed_role_set_is_what_each_uia_type_answers() {
        for (kind, want) in [
            (AutomationControlType::Button, "button"),
            (AutomationControlType::CheckBox, "checkbox"),
            (AutomationControlType::Edit, "field"),
            (AutomationControlType::Text, "label"),
            (AutomationControlType::Slider, "slider"),
            (AutomationControlType::Image, "image"),
            (AutomationControlType::ProgressBar, "progress"),
            (AutomationControlType::ComboBox, "combobox"),
            (AutomationControlType::Group, "group"),
            (AutomationControlType::Pane, "group"),
            (AutomationControlType::List, "group"),
        ] {
            assert_eq!(ax_role(false, kind), want, "{kind:?} answered the wrong role");
            // And the heading property outranks every one of them — stated
            // across the whole table, because "consult the property first" is
            // a claim about the ladder and not about one arm of it.
            assert_eq!(ax_role(true, kind), "heading", "{kind:?} swallowed the heading");
        }
        // A type kaya has no word for reports as such, so the trace in
        // `ax` fires and names it. Window is one the framework really
        // does publish.
        assert_eq!(ax_role(false, AutomationControlType::Window), UNMAPPED_ROLE);
    }

    /// The vendored font the typeface scene ships, compiled in so these
    /// tests measure a REAL name table on whatever machine runs them
    /// (guests/assets/fonts/sora-wght.ttf, OFL — the README beside it).
    #[cfg(feature = "harness")]
    const VENDORED_FONT: &[u8] = include_bytes!("../../../../guests/assets/fonts/sora-wght.ttf");

    /// THE ROUND TRIP: what `register_font_blob` WRITES, the harness read must
    /// be able to resolve BACK to that file. It shipped unable to — the read
    /// asked the system font collection about a per-app font file's family,
    /// whose answer is "no" on a machine where everything worked, so all five
    /// windows typeface legs failed with the font rendering correctly on
    /// screen (2026-08-16). Both directions run here for real.
    #[test]
    #[cfg(feature = "harness")]
    fn the_blob_route_can_be_read_back_off_its_own_file() {
        let source = register_font_blob(VENDORED_FONT)
            .expect("the vendored font registers on any machine with DirectWrite");
        assert_eq!(
            typeface_family_of(&source),
            "Sora",
            "the vendored font's name table is what names the source: {source}"
        );
        let availability =
            typeface_availability(&source).expect("the availability read does not fail");
        assert!(
            availability.available(),
            "the file this process just wrote did not answer for its own family: {}",
            availability.measured()
        );
        // The sentence a PASSING view prints is the bare family, and
        // that is what tools/scenes/typeface.steps compares against.
        assert_eq!(
            typeface_resolved(&source, (1, 1), (2, 2)).expect("the read does not fail"),
            "Sora",
            "a source whose file declares its family must print the BARE name"
        );
        // AND REGISTERING AGAINST A FILE THIS PROCESS HAS ALREADY OPENED
        // STILL WORKS. The read above left the font MAPPED, and Windows
        // refuses to overwrite a mapped file (os error 1224) — so a
        // second registration used to fail, which on the lane is a
        // second guest sharing one app directory panicking at startup.
        assert_eq!(
            register_font_blob(VENDORED_FONT).expect("a re-registration reuses the file"),
            source,
            "the second registration must name the same file, not fail on the mapped one"
        );
        println!("available: Sora {}", availability.measured());
    }

    /// A source whose file is NOT THERE, said as its own sentence. The
    /// blob route's file lives beside the executable and nothing stops a
    /// deploy, an installer or a cleaner from removing it while XAML —
    /// which has the face open — goes on laying text out in it.
    #[test]
    #[cfg(feature = "harness")]
    fn a_source_whose_file_is_gone_says_that_and_not_something_about_the_machine() {
        let source = "ms-appx:///kaya-fonts/brand-000000000000dead.ttf#Sora";
        let availability = typeface_availability(source).expect("the availability read does not fail");
        assert!(!availability.available());
        let said = availability.measured();
        assert!(
            said.contains("could not be read") && said.contains("brand-000000000000dead.ttf"),
            "the missing-file sentence must name the file it looked for: {said}"
        );
        assert!(
            said.contains("it is not there"),
            "a file that is ABSENT says so — DirectWrite's own message cannot tell \
             absent from unavailable, and the two send a reader to different places: {said}"
        );
        assert!(
            !said.contains("font families"),
            "a per-app file's absence must never be reported as the system \
             collection's answer: {said}"
        );
        let sentence = typeface_resolved(source, (1, 1), (2, 2)).expect("the read does not fail");
        println!("missing: {sentence}");
        println!(
            "missing (note): {}",
            typeface_fallback_note("Segoe UI", source, &availability, "Segoe UI")
        );
    }

    /// A source whose file declares SOMEBODY ELSE'S family — the bytes
    /// under the name are not the font the source says they are. A
    /// distinct sentence from the one above, because the two send a
    /// reader to opposite places.
    #[test]
    #[cfg(feature = "harness")]
    fn a_source_whose_file_declares_another_family_names_both() {
        let source = register_font_blob(VENDORED_FONT).expect("the vendored font registers");
        let (path, _) = typeface_source_parts(&source);
        let lying = format!("{}#Palatino", path.expect("the blob route names a file"));
        let availability =
            typeface_availability(&lying).expect("the availability read does not fail");
        assert!(!availability.available());
        let said = availability.measured();
        assert!(
            said.contains("declares the family Sora"),
            "the mismatch sentence must name what the file really declares: {said}"
        );
        let sentence = typeface_resolved(&lying, (1, 1), (2, 2)).expect("the read does not fail");
        assert!(
            sentence.starts_with("Palatino (XAML lays it out, but it"),
            "the mismatch answer names the family that was asked for: {sentence}"
        );
        println!("mismatch: {sentence}");
        println!(
            "mismatch (note): {}",
            typeface_fallback_note("Segoe UI", &lying, &availability, "Segoe UI")
        );
    }

    /// AND THE BARE-NAME ARM IS UNCHANGED: a source with no `#` is still the
    /// system font collection's question, both ways round — an installed
    /// family still prints its bare name, and a family nobody has still gets
    /// the sentence that says so.
    #[test]
    #[cfg(feature = "harness")]
    fn a_bare_family_is_still_the_system_collections_question() {
        let installed =
            typeface_availability("Segoe UI").expect("the availability read does not fail");
        assert!(
            installed.available(),
            "Segoe UI is on every Windows this tree supports: {}",
            installed.measured()
        );
        assert_eq!(
            typeface_resolved("Segoe UI", (1, 1), (2, 2)).expect("the read does not fail"),
            "Segoe UI"
        );
        println!("bare, installed: Segoe UI {}", installed.measured());

        let nobodys =
            typeface_availability(TYPEFACE_ABSENT).expect("the availability read does not fail");
        assert!(!nobodys.available());
        let sentence =
            typeface_resolved(TYPEFACE_ABSENT, (1, 1), (2, 2)).expect("the read does not fail");
        assert!(
            sentence.contains("font families"),
            "a bare family nobody has is still answered by the collection: {sentence}"
        );
        println!("bare, absent: {sentence}");
        println!(
            "bare, absent (note): {}",
            typeface_fallback_note("Segoe UI", TYPEFACE_ABSENT, &nobodys, "Segoe UI")
        );
    }

    /// The two keys this lowering must NEVER write (tools/check-accent.py holds
    /// the same rule): `SystemAccentColor`, the documented-but-broken route of
    /// microsoft-ui-xaml#6394 that no control fill reads, and a `HighContrast`
    /// (or fallback `Default`) dictionary, which would override the
    /// framework's own contrast arm re-pointing every accent brush at
    /// `SystemColor*`.
    #[test]
    fn the_brand_writes_neither_the_bare_accent_nor_a_contrast_theme() {
        let xaml = brand_dictionary(&crate::brand::derive(0x3584E4, None, None));
        for forbidden in [
            "x:Key=\"SystemAccentColor\"",
            "x:Key=\"HighContrast\"",
            "x:Key=\"Default\"",
        ] {
            assert!(
                !xaml.contains(forbidden),
                "the brand dictionary writes {forbidden}\n{xaml}"
            );
        }
    }
}
