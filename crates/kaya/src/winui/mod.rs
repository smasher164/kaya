//! WinUI 3 backend: an interpreter of resolved apply-ops.
//!
//! Same architecture as the AppKit backend: the core owns the UI thread
//! and the XAML dispatcher; the button's Click handler pushes an
//! occurrence and never calls app code; commands come back on their own
//! channel; DispatcherQueue::TryEnqueue is the doorbell (the GCD
//! equivalent), carrying no data.
//!
//! This backend is the de-risking experiment for "WinUI 3 from Rust via
//! COM, no XAML files, no C#". Known uncertainty, to be settled in the
//! VM: whether creating the window from a plain `Application` (no
//! subclass, UI built from a dispatcher callback after `Start`) is
//! sufficient, or whether `IApplicationOverrides` composition is needed
//! for `OnLaunched`.

#[allow(
    non_snake_case,
    non_camel_case_types,
    non_upper_case_globals,
    dead_code,
    clippy::all
)]
mod bindings;

use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::c_void;
use std::sync::mpsc::Receiver;
use std::sync::OnceLock;

use windows_core::{HSTRING, Interface as _};

use bindings::Microsoft::UI::Dispatching::{DispatcherQueue, DispatcherQueueHandler};
// The WINDOW's own caption height, which is a windowing fact and not a
// XAML one: the `TitleBar` control sizes its own band and leaves the
// system's caption buttons where they were (microsoft-ui-xaml#9863), so
// the two halves of one band are reconciled here or nowhere.
use bindings::Microsoft::UI::Windowing::TitleBarHeightOption;
use bindings::Microsoft::UI::Xaml::Controls::{
    AppBarButton, Button, CheckBox, ColumnDefinition, ComboBox, ComboBoxItem, CommandBar,
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
// The RichEdit text object model: the textarea's control keeps its text,
// its undo stack and its clipboard verbs on a document object rather
// than on itself (docs/textarea-foundation-plan.md, the windows arm).
// The text ranges ride the same model — `PointOptions` is reveal's
// placement and the viewport read's coordinate space, `TextConstants`
// carries the background an UNPAINTED run wears
// (docs/ranges-plan.md D1).
use bindings::Microsoft::UI::Text::{PointOptions, TextConstants, TextGetOptions, TextSetOptions};
use bindings::Windows::Foundation::{Point, TypedEventHandler};
// The caption title's two text properties are vtable pads in this
// backend's bindings, so the one element that needs them is parsed from
// markup rather than constructed — `caption_title_text` carries the whole
// reason, including the bindgen entry that would retire this import.
use bindings::Microsoft::UI::Xaml::Markup::XamlReader;
use bindings::Microsoft::UI::Xaml::Input::KeyboardAccelerator;
use bindings::Windows::System::{VirtualKey, VirtualKeyModifiers};
use bindings::Microsoft::UI::Xaml::{
    GridLength, GridUnitType, HorizontalAlignment, Style, Thickness, Visibility,
};
// The styling pass's two resource types (docs/styling-plan.md D4): a
// role lowers to a keyed Style (`AccentButtonStyle`,
// `SubtitleTextBlockStyle`) or to a keyed Brush
// (`SystemFillColorCriticalBrush`), both looked up out of the
// framework's own dictionary rather than constructed here.
use bindings::Microsoft::UI::Xaml::Media::Brush;
// The brand typeface's one type (docs/styling-plan.md Slice 2b). Every
// FontFamily member was a vtable PAD until the bindgen filter learned
// this name — see tools/winui-bindgen's entry for it.
use bindings::Microsoft::UI::Xaml::Media::FontFamily;
// The accessibility read's control-type vocabulary, at module scope
// because `ax_role` names it in its signature — that function is the
// pure half of the `ax` verb, split out so the role ladder can be tested
// where nobody can run WinUI. Gated with the read itself: a shipped app
// carries no scene interpreter.
#[cfg(feature = "harness")]
use bindings::Microsoft::UI::Xaml::Automation::Peers::AutomationControlType;
use bindings::Microsoft::UI::Xaml::Media::Imaging::BitmapImage;
use bindings::Windows::Foundation::{IReference, PropertyValue};
use bindings::Windows::Storage::Streams::{DataWriter, InMemoryRandomAccessStream};
use bindings::Microsoft::UI::Xaml::{
    Application, ApplicationInitializationCallback, FocusState, FrameworkElement,
    RoutedEventHandler, UIElement, UnhandledExceptionEventHandler, Window,
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
    // The caption TextBlock is the button's text surface.
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
    /// (docs/textarea-foundation-plan.md). RichEditBox and not TextBox
    /// because TextBox cannot express an attributed run at all — it has
    /// no document object and no per-range formatting, only the one
    /// selection — so the widget that the ranges era must colour is the
    /// one the textarea sits on now. Nothing kaya's textarea contract
    /// promises moves with it: string in, string out, text_changed
    /// through the uncontrolled fold, and every opinion the RichEdit
    /// engine carries pinned off in `pin_plain_text`.
    Textarea(RichEditBox),
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
        }
    }

    /// The editable behind a text widget, if this is one.
    ///
    /// ONE PLACE THAT KNOWS WHICH KINDS ARE EDITABLE, so the apply arms
    /// name the pair once instead of spelling `Entry | Textarea` beside
    /// every operation that works on both (the shape `Editable` exists
    /// to keep honest — see it).
    fn editable(&self) -> Option<Editable> {
        match self {
            NativeWidget::Entry(field) => Some(Editable::Entry(field.clone())),
            NativeWidget::Textarea(field) => Some(Editable::Textarea(field.clone())),
            _ => None,
        }
    }
}

/// AN ORDINARY RANGE OVER WHATEVER THE SELECTION COVERS — the shape
/// every textarea mutation takes, and it cost a crash to learn.
///
/// MEASURED ON THE VM, 2026-08-06, five builds deep into a bisection.
/// A `ITextSelection` obtained from `TextDocument().Selection()` is fine
/// to READ (positions, story length) and fine to MOVE (`SetRange`), and
/// the harness's `type` verb does both on every run. But MUTATING THE
/// DOCUMENT THROUGH IT — `Selection().SetText(..)` after a real Ctrl+V —
/// produced the correct text and then killed the process at teardown
/// with an access violation (0xC0000005), reproducibly, on every run.
/// The same insertion through `GetRange(start, end)` — the identical
/// span, read off that same selection — exits cleanly, as does a
/// whole-document `SetText`. Deferring the mutation a dispatcher tick
/// did NOT help, which is how the selection object rather than the
/// paste's re-entrancy was identified as the cause.
///
/// So the rule this file states once, here: READ the selection, MUTATE
/// a range. The cut and copy arms take the same shape by analogy rather
/// than by their own measurement — they mutate through the same object,
/// the cost of the range is one COM hop, and a second spelling of a rule
/// that already crashed once is not worth the saving.
fn selection_range(
    doc: &bindings::Microsoft::UI::Text::RichEditTextDocument,
) -> windows_core::Result<bindings::Microsoft::UI::Text::ITextRange> {
    let selection = doc.Selection()?;
    let (start, end) = (selection.StartPosition()?, selection.EndPosition()?);
    doc.GetRange(start, end)
}

/// THE TWO NATIVE EDITABLES, BEHIND ONE CONTRACT.
///
/// The entry is a `TextBox` and the textarea a `RichEditBox`, and the
/// second is not a drop-in for the first: it has no `Text` property and
/// none of TextBox's editing commands — every one of them lives on its
/// `TextDocument` (docs/textarea-foundation-plan.md, the windows arm's
/// measured table). Both are the SAME widget to the undo ledger, the
/// clipboard roles, the menu-role enablement and the harness, which is
/// why the two spellings are named ONCE, here, rather than at the
/// fourteen call sites that used to hold a bare `TextBox`.
///
/// THE POINT IS THAT THEY CANNOT DRIFT. Before the swap, entry and
/// textarea were the same native type and every shared path got the
/// uniform behaviour for free; a second `if kind == Textarea` at each
/// site would have handed that guarantee back. Adding an operation
/// means adding it here, for both, or it does not compile.
#[derive(Clone)]
enum Editable {
    Entry(TextBox),
    Textarea(RichEditBox),
}

impl Editable {
    /// The text AS THE CONTROL STORES IT — CR line breaks, no trailing
    /// paragraph mark. Callers apply `lf` on the way to the guest,
    /// exactly as they did when both were TextBoxes.
    ///
    /// `AdjustCrlf` IS A PIN (docs/textarea-foundation-plan.md). A
    /// RichEdit story always ends in a paragraph mark, and
    /// `GetText(None)` hands it out: `set 'abc'` reads back `'abc\r'`,
    /// and after `lf` that is a trailing newline the guest never wrote —
    /// invariant 6 broken (tools/scenes/textarea.steps compares its
    /// strings byte-for-byte on five platforms). Measured on the VM
    /// before it was written, all four cases: with `AdjustCrlf` the read
    /// matches the source exactly, empty string included.
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

    /// `TextSetOptions::None` IS A PIN, and the enum says why: the same
    /// call with `FormatRtf` PARSES the string as a document. A guest
    /// whose textarea text happened to begin `{\rtf1` would then see it
    /// rendered on windows and stored literally on the other four
    /// platforms — measured on the VM 2026-08-06, `{\rtf1 KAYARTF}` set
    /// with `FormatRtf` reads back as `KAYARTF`, and with `None` reads
    /// back whole.
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

    /// The platform's own insertion — for a widget that declared no
    /// accept list, this IS the paste (DESIGN.md's paste split).
    ///
    /// PLAIN TEXT ON BOTH ARMS, which is what makes the swap invisible.
    /// TextBox has nothing but plain text to insert. RichEditBox's own
    /// `ITextRange::Paste(0)` would take the RICHEST format the
    /// clipboard offers — RTF, with its fonts and colours — so the
    /// textarea reads CF_UNICODETEXT itself and sets it as text. The
    /// control's OWN paste routes (Ctrl+V, its context menu) are turned
    /// into this same call by the `Paste` handler `pin_plain_text`
    /// attaches, so no route into a kaya textarea can carry formatting.
    fn paste_from_clipboard(&self) -> windows_core::Result<()> {
        match self {
            Editable::Entry(field) => field.PasteFromClipboard(),
            Editable::Textarea(field) => {
                let Some(text) = clipboard_plain_text() else {
                    return Ok(());
                };
                // `ITextRange::SetText` — TOM's `put_Text`, the setter
                // that takes no options at all, so there is no flag here
                // to get wrong on the one string kaya controls least.
                selection_range(&field.TextDocument()?)?.SetText(&HSTRING::from(text))
            }
        }
    }

    /// Put the caret at `at` (in UTF-16 units), collapsed — what the
    /// harness's `type` verb does before injecting a run of keys.
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
    /// The window content inset (wprop 8, docs/styling-plan.md D3):
    /// stored because the Mount arm stamps it as Grid.Padding and the
    /// harness's `offer` observation subtracts it from the root's
    /// actual size.
    inset: f64,
    /// A CONTAINER's own inset (prop 17, one level down): the declared
    /// number per container, kept because a WinUI Grid has ONE Padding
    /// where SwiftUI and Compose nest two boxes — see
    /// `container_padding`, which is the only thing that writes it.
    container_insets: HashMap<WidgetId, f64>,
    transactions: Receiver<Transaction>,
    scene: Scene,
    occurrences: OccSink,
    /// The directory the next picker opens on.
    ///
    /// ARMED, NOT SET: a dialog reads its folder when it is shown, so
    /// the harness's file_dialog_goto stores it here and the apply arm
    /// applies it. Same shape as GTK and the SwiftUI interpreter, for
    /// the same reason — pointing one already on screen is ignored.
    pending_dialog_dir: RefCell<Option<String>>,
    widgets: HashMap<WidgetId, NativeWidget>,
    // Which grid each widget sits in, for Destroy's detach.
    parents: HashMap<WidgetId, Grid>,
    // Grid places by attached Row/Column index, not by child order, so
    // the logical order has to be tracked here and stamped back onto the
    // children after every structural change. This is also the order the
    // definitions are rebuilt in — one definition per child, carrying
    // that child's grow weight.
    child_order: HashMap<WidgetId, Vec<WidgetId>>,
    grow: HashMap<WidgetId, f64>,
    /// Container align modes (the align spec enum's wire values):
    /// reindex stamps the cross alignment onto every child after any
    /// structural change, so late arrivals are covered by the same
    /// path that keeps Grid indices honest.
    aligns: HashMap<WidgetId, i64>,
    // Per-kind registries in creation order (stamped copies included):
    // the harness names targets as kind#index. Clicks emit the stored
    // tag directly; the other controls fire their real events for the
    // stage's direct writes (SetIsChecked raises Checked, SetText
    // raises TextChanged, SetValue raises ValueChanged) — that is the
    // stage's user path. The APPLY path arms apply_quiet so property
    // writes stay silent (see that field).
    buttons: Vec<Vec<u8>>,
    checkboxes: Vec<CheckBox>,
    labels: Vec<TextBlock>,
    entries: Vec<TextBox>,
    /// Aligned with `entries`: the widget id per registry slot (the
    /// stage indexes by creation order; the maps below key by id).
    entry_ids: Vec<u64>,
    /// TextChanged is raised ASYNCHRONOUSLY, so programmatic text
    /// paths cannot ride it in order: SetProp, the clear command,
    /// and the stage's set_text all bump this counter, write the
    /// text, and (for the emitting paths) send the occurrence
    /// SYNCHRONOUSLY themselves — the late native raise is swallowed
    /// 1:1. User typing bumps nothing and emits through the real
    /// raise. Caught live 2026-07-22: without this, a click's
    /// occurrence OVERTAKES the edit and the guest's add handler
    /// runs on an empty draft.
    entry_swallow: HashMap<u64, std::sync::Arc<std::sync::atomic::AtomicUsize>>,
    entry_tags: HashMap<u64, Vec<u8>>,
    sliders: Vec<Slider>,
    images: Vec<Image>,
    scrolls: Vec<ScrollViewer>,
    progresses: Vec<ProgressBar>,
    selects: Vec<ComboBox>,
    radios: Vec<RadioButtons>,
    grids: Vec<Grid>,
    textareas: Vec<RichEditBox>,
    textarea_ids: Vec<u64>,
    /// Grid layout state: ordered children + column count; both the
    /// adds and the columns prop re-flow the attach positions
    /// (children-first sugars emit adds before the prop).
    grid_children: HashMap<u64, Vec<UIElement>>,
    grid_cols: HashMap<u64, i32>,
    /// Radio plumbing, the select_options shape: label id -> (its
    /// group, its row in the group's Items vector) — option text
    /// updates land with SetAt.
    radio_options: HashMap<u64, (RadioButtons, u32)>,
    /// Option-label plumbing: label widget id -> (its select's
    /// ComboBox, its option row's own TextBlock). A select's label
    /// children are its OPTIONS — ComboBoxItems in the popup, not
    /// standalone widgets — so their SetProp text lands on the row
    /// as STRING content and they leave the harness's label
    /// registry. Strings, never a TextBlock: a UIElement content is
    /// STOLEN into the collapsed box's SelectionBoxItem while its
    /// row is selected (one visual tree), and the row's Content()
    /// reads back null — caught live 2026-07-22 as a null-interface
    /// panic that wedged the dispatcher.
    select_options: HashMap<u64, (ComboBox, ComboBoxItem)>,
    /// Echo guard for EVERY interactive kind: WinUI's change events
    /// (TextChanged, Checked/Unchecked, ValueChanged,
    /// SelectionChanged) cannot tell a user act from a programmatic
    /// write, and only the USER path may emit an occurrence — a
    /// property write is state configuration, never an event
    /// (without this, a handler that writes back a different value
    /// than it received ping-pongs through the native event
    /// forever). Armed around every SetProp write to an interactive
    /// widget. Commands (clear) and the harness stage's direct
    /// writes stay unguarded ON PURPOSE: a command acts like the
    /// user, and both must reach the app through the widget's own
    /// path. Atomic because WinRT event handlers are Send-bound
    /// (they still fire on this thread).
    apply_quiet: std::sync::Arc<std::sync::atomic::AtomicBool>,
    columns: Vec<Grid>,
    rows: Vec<Grid>,
    window: Window,
    /// Auxiliary surfaces by kaya window id (the primary is
    /// `window`); created hidden, presented (Activated) at mount.
    aux_windows: HashMap<u64, Window>,
    /// veto_close per window id (primary included; default false).
    window_veto: HashMap<u64, bool>,
    /// App-initiated teardown bypasses the chrome-close grammar:
    /// Window.Close() rides WM_CLOSE, and without this a veto window
    /// would swallow its own confirmed destruction (and a non-veto
    /// one would report a spurious window_closed).
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
    /// list_detail per window (wprop 6) and the presentation
    /// refresh_nav ACTUALLY rendered — stamped by the arm that ran,
    /// never derived (docs/traps.md).
    list_detail: HashMap<u64, bool>,
    split_presentation: HashMap<u64, &'static str>,
    /// The live list-detail Grid per window, kept so the next render
    /// can release the roots it holds (see release_split).
    split_views: HashMap<u64, TwoPaneView>,
    window_roots: HashMap<u64, UIElement>,
    /// The WIDGET ID of each mounted surface root, by surface (window,
    /// pushed navigation entry or section pane — the Mount arm treats
    /// the three alike). `window_roots` keeps the same relation as
    /// elements, for the window mounts only; this one is what tells
    /// `container_padding` which containers carry the window inset in
    /// their own Padding.
    mounted_roots: HashMap<u64, WidgetId>,
    window_titles: HashMap<u64, String>,
    /// Unsaved work per window (wprop 7). Windows publishes no
    /// modified affordance at any layer — the whole App SDK metadata
    /// has no IsModified/IsDirty/HasUnsavedChanges, and UIA's
    /// WindowPattern has none either (scratchpad/dirty-probe-windows.md)
    /// — so the caption IS the chrome here, and this flag is the third
    /// input to the caption composition beside the window's own title
    /// and a covering entry's. Kept as STATE rather than read back out
    /// of the caption string, because the caption is the rendering and
    /// the rendering is not the declaration: the app's title is never
    /// touched (docs/dirty-plan.md D1/D2).
    window_dirty: HashMap<u64, bool>,
    /// Sections (DESIGN.md, Sections): per-window ordered sets, pane
    /// containers by section id, the NavigationView that materializes
    /// the switcher (the platform's own idiom — viable now that the
    /// aggregation outer delegates QI; docs/traps.md), and the
    /// selection mirror. A section's pane swaps between its own root
    /// and its stack's top entry (stacks are per-surface; nav_stacks
    /// keys sections too).
    sections: HashMap<u64, Vec<u64>>,
    section_panes: HashMap<u64, WinSection>,
    section_navs: HashMap<u64, NavigationView>,
    section_items: HashMap<u64, NavigationViewItem>,
    /// The TextChanged lesson applied to the switcher: WinRT raises
    /// SelectionChanged ASYNCHRONOUSLY, so programmatic moves swallow
    /// the late raise via a counter (a flag's guard window closes too
    /// early), and only real user switches reach the handler body.
    section_swallow: HashMap<u64, std::sync::Arc<std::sync::atomic::AtomicUsize>>,
    /// What the CONTROL last showed — a no-op SetSelectedItem raises
    /// nothing, so the swallow only increments on a real move.
    ui_selected_sections: HashMap<u64, u64>,
    selected_sections: HashMap<u64, u64>,
    sections_presentation: HashMap<u64, i64>,
    /// Menus (DESIGN.md, Menus and the command vocabulary): the
    /// retained item model — kind fixed at create, every applicable
    /// prop live. This map is the POST-USER MIRROR (docs/traps.md):
    /// toggle/radio chrome owns the immediate user change, its Click
    /// handler updates checked/value here BEFORE emitting, and every
    /// rebuild starts from it. Items are never destroyed.
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
    /// (attachment, item id) -> its materialized native chrome,
    /// rebuilt with the catalog. Keyed PER ATTACHMENT: a template
    /// context catalog attaches the SAME item ids to every stamped
    /// copy, and the copy's keys ARE the noun (DESIGN.md, Menus) — a
    /// flat per-item map would keep only the last-built copy, in
    /// context_roots' arbitrary iteration order, and the harness
    /// would invoke that anchor's chrome (and emit ITS noun) from
    /// every other row (docs/traps.md). Separators and NESTED radio
    /// groups mint none (the group's options materialize inline —
    /// the checkmark idiom).
    menu_natives: HashMap<(MenuAttachment, u64), MenuNative>,
    /// The window shell (the ratified lowering): the TITLEBAR's Auto row
    /// at the top of a shell Grid, the MenuBar in the Auto row under it,
    /// the window's real content in the Star-row slot beneath both.
    /// Built once per window at the first menubar_append; every content
    /// swap goes through the slot.
    menubars: HashMap<u64, MenuBar>,
    menu_slots: HashMap<u64, Grid>,
    /// The shell Grid itself, kept so the titlebar row can be filled
    /// LATER than the shell is built — a window earns its caption
    /// `TitleBar` and the `CommandBar` inside it only when its catalog
    /// promotes something (docs/chrome-plan.md C2), and a window with no
    /// primaries must keep exactly the tree, and exactly the system
    /// caption, it had before this slice.
    menu_shells: HashMap<u64, Grid>,
    /// The window's REAL toolbar, minted on the first promotion by
    /// `refresh_toolbar`. Absent = this window has no toolbar, which is
    /// a state the harness read reports rather than papers over.
    toolbars: HashMap<u64, CommandBar>,
    /// The window's custom `TitleBar` control — the caption row the
    /// toolbar MERGES INTO (docs/chrome-plan.md C2's WinUI row, revised
    /// 2026-08-17). Minted by the SAME first promotion that mints the
    /// CommandBar and by nothing else: **extended is DERIVED from
    /// toolbar presence**, so a window whose catalog promotes nothing
    /// never has one and keeps the standard system caption it always
    /// had.
    ///
    /// Kept because `refresh_caption` has to reach it — the caption text
    /// it hosts is a SECOND SINK for the composed caption, never a second
    /// author of it (see the doc comment there).
    window_titlebars: HashMap<u64, TitleBar>,
    /// The caption's TITLE TEXT, in the control's CENTRE slot.
    ///
    /// WHY NOT THE CONTROL'S `Title` PROPERTY, which is the obvious
    /// place: the control lays that property out immediately after
    /// `LeftHeader`, and as of the one-band revision `LeftHeader` is the
    /// window's MENU. The first capture of that arrangement is the whole
    /// argument — the band read `File  Edit  View  toolbar`, and the
    /// title was indistinguishable from a fourth menu item. The band the
    /// ruling asks for is menu left, title centre, commands right, and
    /// the control already declares a centred slot for the middle one:
    /// `TitleBarContentHorizontalAlignment` is `Center`
    /// (`TitleBar_themeresources.xaml:97`). This is also the arrangement
    /// Windows' own menu-in-caption applications use — Visual Studio and
    /// the Office apps both centre the document title over a left-hand
    /// menu.
    ///
    /// IT ALSO RETIRES A TRAP RATHER THAN MANAGING IT. `TitleBar` writes
    /// `appWindow.Title` from its own `Title` property, so filling that
    /// property made the control a caption WRITER that had to be fed the
    /// composed string to stop it clobbering the dirty marker. Left empty
    /// from birth, it never writes at all: `UpdateTitle`'s only write is
    /// guarded by a non-empty title and `ResetTitle` fires only on a
    /// non-empty→empty transition (microsoft-ui-xaml @
    /// winui3/release/2.2.0, `TitleBar.cpp:483-516`). One author, and now
    /// no rival.
    window_caption_texts: HashMap<u64, TextBlock>,
    /// (window, item id) -> the promoted action's `AppBarButton`.
    ///
    /// THE WRITE SIDE ONLY, and that is the whole discipline of this
    /// slice: enablement is stamped through this map (here and in
    /// `refresh_role_enablement`, which must reach the button as well as
    /// the menu row — one item, two chrome views), while every harness
    /// READ walks the bar's own `PrimaryCommands`/`SecondaryCommands`
    /// instead. A read through this map would agree with kaya's model no
    /// matter what the window really holds.
    toolbar_buttons: HashMap<(u64, u64), AppBarButton>,
    /// Canonical shortcut spelling -> action item id for the PRIMARY
    /// window's catalog (the harness's target, the sections-precedent
    /// scoping). Gates the shortcut verb: a chord no catalog action
    /// owns is a silent no-op — checked before any OS-global
    /// injection (docs/traps.md). It also DISPATCHES every chord: the
    /// key hook resolves the pressed spelling here (The chord route),
    /// so what the verb gates on and what the app answers cannot
    /// disagree.
    menu_shortcuts: HashMap<String, u64>,
    /// The harness's OPEN context menu: anchor widget id plus the
    /// flyout handle, kept until Closed is awaited (the staged
    /// ShowAt ruling — the anchor row may be destroyed by the very
    /// occurrence the activation emits).
    open_context: Option<(u64, MenuFlyout)>,
    /// Coalesced per drain: any op touching the command surface sets
    /// it; one rebuild follows the batch.
    menus_touched: bool,
    /// Accept lists by widget id (the accepts prop; empty = unset =
    /// absent here). The paste split and Paste's enablement both read
    /// it. The root admits the prop on entries and textareas
    /// (scene.rs), whose identity tags entry_tags already carries.
    accepts: HashMap<u64, String>,
    /// A ROLE surface appeared — an authored role, or a clipboard
    /// surface (accepts / copy / read): the refresh sites consult it, so
    /// the scenes that declare no role at all pay nothing for the
    /// recomputation.
    ///
    /// IT USED TO BE `clipboard_armed`, and the undo roles are why it is
    /// not. Undo's enablement is a live question in a scene that never
    /// touches the clipboard (docs/undo-plan.md D6), so a flag armed by
    /// clipboard traffic alone would leave Edit>Undo showing whatever
    /// enablement it was BORN with — the mac arm's finding 2, one move
    /// over.
    roles_armed: bool,
    /// What the LEDGER has been shown for each field — the last text
    /// `bank_text_changed` handed the core.
    ///
    /// THE `type` VERB'S SETTLE READS IT, and that is the whole reason
    /// it exists (contract point 4: the verb blocks until every
    /// character is "delivered AND processed"). On this backend
    /// TextChanged is raised ASYNCHRONOUSLY, so the CONTROL shows the
    /// typed text a beat before kaya has been told about it — and a
    /// verb that settled on the control alone returns into a
    /// `menu_activate "Edit>Undo"` whose routing then asks a ledger that
    /// has not heard of the last keystroke. MEASURED, as the first
    /// windows leg of this scene: the undo took the STAR GROUP instead
    /// of the typing, one entry too deep, and the field kept the text
    /// the user had just typed.
    banked_text: HashMap<u64, String>,
    /// Q2's LEDGER-QUIET BRACKET (docs/undo-plan.md §3, the "report it
    /// once" rule): field id -> the text a native undo THIS BACKEND
    /// ROUTED left in the widget, recorded when the sample was taken.
    ///
    /// A BRACKET AND NOT A FLAG-WITH-A-TIMER, for the reason the mac arm
    /// reached from the opposite premise and this one MEASURED: a routed
    /// `TextBox.Undo()` raises the control's ordinary TextChanged a
    /// runloop turn LATER (7ms in the probe, `inside_undo_call=false`),
    /// long after a boolean set and cleared around the call would be
    /// gone. Matching the sampled TEXT is exact, needs no clock, and
    /// self-clears — the entry is consumed by the edit it was written
    /// for. Only the BANKING is suppressed; the occurrence still reaches
    /// the app, because the field is uncontrolled and a native undo is
    /// an edit like any other from the app's side.
    ledger_quiet: HashMap<u64, String>,
}

// ---- Text ranges: the two pieces of state that CANNOT live in
// ---- CoreState (docs/ranges-plan.md D2, D4)
//
// Both are written by CONTROL EVENT HANDLERS — TextChanged for the
// first, TextCompositionStarted/Ended for the second — and a handler
// that touched `CORE` would be one synchronous raise away from aborting
// the process. `CORE.with_borrow_mut` PANICS on a live borrow, the
// harness's own `set_text` writes the control from inside `on_ui_mut`
// (which holds that borrow — the reason `bank_text_changed_on` exists
// as a second door), and a panic crossing a dispatcher callback aborts
// rather than unwinds. The existing TextChanged handler is safe only
// because its swallow test returns BEFORE it reaches the core; D2's
// compare has to run on every raise, swallowed or not, so it cannot
// stand behind that test.
//
// Thread-local rather than static: every one of these paths is the UI
// thread, and a `RefCell` says so where a `Mutex` would only imply it.

thread_local! {
    /// D2'S CLEAR-ON-EDIT, THIS BACKEND'S SPELLING: the widget's text at
    /// the moment a highlight set was declared over it. The rule is that
    /// painted offsets were validated against the text they are painted
    /// on, so a set survives exactly as long as this string is still
    /// what the control holds; any edit — a keystroke, a programmatic
    /// write, a native undo — makes it stale and `drop_stale_highlights`
    /// unpaints everything with nothing said.
    ///
    /// THE COMPARE IS AGAINST THE TEXT AND NOT AGAINST THE EVENT, which
    /// is why this holds a string rather than a generation number.
    /// TextChanged is raised ASYNCHRONOUSLY here, so a transaction that
    /// writes new text and declares ranges over it — the obvious
    /// spelling, and the one the core's same-batch text read exists to
    /// serve — has its TextChanged land AFTER the highlight. A backend
    /// that dropped on the event would destroy every set declared in the
    /// same batch as a write; one that compares the text sees the string
    /// it just recorded and leaves the set alone.
    ///
    /// AND IT IS NOT BELT-AND-BRACES FOR THE PLATFORM'S OWN BEHAVIOUR.
    /// Rich Edit anchors character formatting to the TEXT, not to
    /// offsets: an insertion before a painted run MOVES the run
    /// (measured, range-probe-windows.md §5 — a run painted at 20-30
    /// read back at 25-35 after a five-character insert at 0), and text
    /// typed at either edge of a run INHERITS its background. Tracking
    /// is exactly what D2 refuses to ship, so without this compare a
    /// stale set would keep painting, drifting and growing, until the
    /// app happened to declare something else.
    static HIGHLIGHT_TEXT: RefCell<HashMap<u64, String>> = RefCell::new(HashMap::new());

    /// Widgets with a LIVE INPUT-METHOD COMPOSITION, from the control's
    /// own `TextCompositionStarted`/`TextCompositionEnded` (D4). The
    /// only party that can know this is the control: a composition is on
    /// no kaya channel and never will be, so a `select_range` arriving
    /// mid-word is a race the app cannot see and must not lose.
    static COMPOSING: RefCell<std::collections::HashSet<u64>> =
        RefCell::new(std::collections::HashSet::new());
}

/// One section's materialized state: the pane Grid (the mount
/// target), its title, its own mounted root, and the hosting window.
struct WinSection {
    window: u64,
    pane: Grid,
    title: String,
    /// The SEMANTIC ICON (0 = none). Retained because the switcher's
    /// item is minted lazily by `refresh_sections` — a section can be
    /// given its symbol before its NavigationViewItem exists — and
    /// re-read there.
    symbol: i64,
    root: Option<UIElement>,
}

/// One navigation entry: a pushed scene root, retained while covered
/// (the wrapper Grid holds it), destroyed at pop. The wrapper's top
/// row is the backend-owned back bar — WinUI's back affordance here;
/// visible only while the entry is on screen by construction.
struct WinNavEntry {
    window: u64,
    title: String,
    /// The close-veto class transplanted to POP.
    intercept_back: bool,
    wrapper: Option<Grid>,
    back_button: Option<Button>,
}

/// The live alert's identity and its REAL dialog object.
struct WinLiveAlert {
    window: u64,
    actions: usize,
    dialog: ContentDialog,
}

/// One menu item's retained state (the post-user mirror; see
/// CoreState::menu_models). `primary` is the CHROME-promotion hint
/// (DESIGN.md, "Chrome promotion and `primary`") and IS read here now:
/// `promoted_items` filters this catalog by it and `refresh_toolbar`
/// makes each one an `AppBarButton` in the window's `CommandBar`
/// (docs/chrome-plan.md C2).
struct MenuModel {
    kind: MenuItemKind,
    label: String,
    enabled: bool,
    checked: bool,
    value: f64,
    primary: bool,
    /// A standard-command role from the closed vocabulary ("" =
    /// none). PLACEMENT is inert here (no dress-owned application
    /// menu), but the clipboard roles change BEHAVIOR: activation
    /// performs the command on the focused widget, and enablement
    /// folds in role_enabled (refresh_role_enablement).
    role: String,
    shortcut: String,
    /// The SEMANTIC ICON (spec enum "symbol"; 0 = none). Retained for
    /// the same reason label and shortcut are: `rebuild_menus` builds
    /// every native from this model, so a symbol that lived only on the
    /// old chrome would vanish at the next unrelated prop write. It is
    /// NOT what the harness reads — `menu_symbol` asks the materialized
    /// item, so a lowering that dropped this value still fails.
    symbol: i64,
    children: Vec<u64>,
    parent: Option<u64>,
}

/// An item's materialized WinUI chrome, per the ratified 1:1 lowering:
/// MenuBarItem for a top-level grouping node (a bar-level radio_group
/// included — its options inline under the group's own title),
/// MenuFlyoutSubItem for a nested menu, and the three leaf item kinds.
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
    /// [`icon_uia_name`]. Never the model: a backend that decoded the
    /// symbol prop and drew nothing has to fail the assertion, and the
    /// only way to guarantee that is to ask the materialized item.
    fn icon(&self) -> MenuIcon {
        let slot: &dyn IconSlot = match self {
            // The top-level bar grouping has no icon slot at all in
            // WinUI, so its symbol is dropped rather than drawn — a
            // fact this backend states rather than dresses up. The mac
            // arm does put one on its bar holders; that divergence is a
            // platform's missing affordance, not a semantic difference,
            // and the read below names it.
            MenuNative::Bar(_) => return MenuIcon::NoSlot,
            MenuNative::Sub(i) => i,
            MenuNative::Action(i) => i,
            MenuNative::Toggle(i) => i,
            MenuNative::Option(i) => i,
        };
        match slot.icon_element() {
            Ok(icon) => MenuIcon::Present(icon),
            // AN UNSET Icon IS AN `Err` WHOSE HRESULT SAYS SUCCESS, and
            // that sentence is the whole reason this returns four cases
            // instead of an Option. The property call itself returns
            // S_OK with a NULL pointer; windows-core's `Type::from_abi`
            // turns a null interface pointer into `Error::empty()`,
            // whose `code()` is `HRESULT(0)` — NOT `E_POINTER`, which is
            // what `Interface::cast` uses for its own null case and what
            // this arm was first written against. So EMPTY is "the call
            // succeeded and there is no icon", and only a genuine
            // failure HRESULT means the slot could not be read.
            //
            // Read out of windows-core 0.62.2 (src/type.rs's
            // InterfaceType `from_abi`) and windows-result 0.4.1
            // (`S_EMPTY_ERROR`, whose `code()` reports 0), because this
            // backend's host is not reachable from a mac and a branch
            // nobody can make print is a guess about a state nobody has
            // reached (CLAUDE.md invariant 3). Against E_POINTER the
            // Empty arm was DEAD, and every icon-less item would have
            // reported an unreadable slot with an empty message —
            // a sentence blaming a failure that did not happen.
            Err(e) if e.code().is_ok() => MenuIcon::Empty,
            Err(e) => MenuIcon::Unreadable(e),
        }
    }
}

// --- The semantic icon vocabulary: the FLUENT column -------------------
//
// An app names a CONCEPT (`Symbol::Copy`) and this backend draws
// Windows' own glyph for it. Every identifier in the table below was
// taken from styling/symbols-fluent.md and NONE of it from memory: that
// report extracted 1413 codepoint/name pairs out of the Segoe Fluent
// Icons catalog mechanically, parsed the shipped font's cmap to prove
// each codepoint resolves to a real glyph, and RENDERED the candidates
// to check the shapes. The shape check is not ceremony — it is what
// caught `Error` (U+E783) being a circle with an EXCLAMATION MARK
// rather than the circle-X the name promises. kaya's v1 vocabulary has
// no `error` concept, so no row here uses it, but `warning` sits one
// glyph away and a future reader "fixing" it to the same-named glyph
// would ship the collision.
//
// TWO ROUTES, BOTH REQUIRED. `Symbol` is an enum of stable API names —
// preferred, because kaya then never writes a codepoint — but it covers
// only a subset of the font, and three of kaya's twenty concepts (info,
// warning, lock) have NO member at all. Those three can only be spelled
// as codepoints through `FontIcon`. Neither route sets a FontFamily:
// both resolve through the `SymbolThemeFontFamily` theme resource,
// which is also what makes the Windows 10 story free — that resource
// falls back to Segoe MDL2 Assets there, and all the codepoints kaya
// uses are in that catalog too (33/33, checked mechanically).
//
// THE MEMBER NAMES ARE NOT THE GLYPH NAMES, and three of them bite:
//   * `Symbol::Find` IS the magnifier whose catalog name is `Search`.
//     There is no `Symbol::Search`. (`Symbol::Zoom` is a DIFFERENT
//     magnifier meaning zoom — not search.)
//   * `Symbol::Setting` is SINGULAR, though the Fluent catalog names
//     the glyph `Settings`. Spelling it from the glyph name does not
//     compile.
//   * `Symbol::Back`/`Forward` are full ARROWS, not chevrons, which is
//     the Windows convention for navigation — the concept kaya's back
//     and forward name. The chevron spellings (U+E76B/U+E76C) have no
//     enum member and belong to a disclosure affordance, not to this.
// One more that is a choice rather than a trap: `star` takes
// `OutlineStar` because `SolidStar` is its obvious sibling for a set
// state later, while `Symbol::Favorite` is a mere duplicate of
// OutlineStar (same U+E734).
//
// WHAT IS NOT ESTABLISHED: whether Windows mirrors the back/forward
// arrows under a right-to-left layout. The catalog report makes no
// claim either way and nothing here has been run on an RTL system, so
// this comment does not make one — the concepts are direction-relative
// by kaya's definition (crates/kaya/src/app.rs), and proving the
// mirroring is a separate measurement on the Windows lane.
enum FluentIcon {
    /// Route 1: a `Symbol` enum member — 17 of the 20 concepts.
    Member(bindings::Microsoft::UI::Xaml::Controls::Symbol),
    /// Route 2: a Segoe Fluent Icons codepoint, for the three concepts
    /// the enum never got.
    Glyph(&'static str),
}

/// The Fluent spelling of a concept. EXHAUSTIVE ON PURPOSE: a 21st
/// entry in the vocabulary fails the windows build right here, naming
/// the file that has to grow, rather than compiling into an icon that
/// silently never draws.
const fn fluent_icon(symbol: crate::app::Symbol) -> FluentIcon {
    use bindings::Microsoft::UI::Xaml::Controls::Symbol as Fluent;
    use crate::app::Symbol as S;
    match symbol {
        S::Add => FluentIcon::Member(Fluent::Add),
        S::Remove => FluentIcon::Member(Fluent::Remove),
        // The trash can (U+E74D), distinct from Remove's single minus
        // stroke — kaya draws the same distinction.
        S::Delete => FluentIcon::Member(Fluent::Delete),
        S::Edit => FluentIcon::Member(Fluent::Edit),
        // The bare checkmark. `Completed` (U+E930) is the circled one,
        // for a status rather than an action.
        S::Done => FluentIcon::Member(Fluent::Accept),
        // The general-purpose X. `ChromeClose` is the heavier X for
        // window close buttons, deliberately not used for in-content
        // dismissal.
        S::Close => FluentIcon::Member(Fluent::Cancel),
        S::Search => FluentIcon::Member(Fluent::Find),
        S::Settings => FluentIcon::Member(Fluent::Setting),
        S::Refresh => FluentIcon::Member(Fluent::Refresh),
        // The three with no enum member — FontIcon or nothing.
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

/// THE COMPILE-TIME PIN, and it is what makes the array above safe to
/// hand-write. Position by position, `SYMBOL_ORDER[i]`'s wire id must
/// equal `wire::SYMBOLS[i]`'s — the table the spec pins name-by-name
/// and id-by-id (`symbol_names_match_the_spec_enum`). So a 21st concept
/// in the spec fails to build here until this array grows, a renumbered
/// concept fails here, and a repeated or misplaced entry fails here as
/// well, since the ids are distinct. `const`, not a test: it is on
/// `cargo check --target …-windows-msvc`, which is a gate the fast
/// sweep already runs, rather than on a suite this backend's host has
/// to be present to run.
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

/// The concept a wire value names, or None for the unset slot (0) — and
/// for anything else, which the root already refused at declare time,
/// so it can only mean this backend and the core disagree.
fn symbol_from_wire(value: i64) -> Option<crate::app::Symbol> {
    SYMBOL_ORDER
        .into_iter()
        .find(|s| i64::from(symbol_wire(*s)) == value)
}

/// The platform icon for a wire symbol value, carrying THE SEMANTIC
/// NAME as its UIA name.
///
/// The name is not decoration. An icon that carries meaning has to say
/// what it means to an assistive client, and on this platform that is
/// `AutomationProperties.Name` on the icon element — the same property
/// the a11y label rides for every other widget here. It is also this
/// slice's OBSERVATION CHANNEL: `menu_symbol` reads it back off the
/// live element's automation peer, which works precisely because it is
/// the surface a screen-reader user gets. Reading kaya's own model
/// instead would agree with itself no matter what was drawn.
///
/// The name comes from `wire::symbol_name` — the spec's own table —
/// rather than from a string typed here, so a renamed concept cannot
/// mean one thing to the harness and another to the icon.
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
            // SymbolThemeFontFamily, which is the theme resource that
            // also carries the Windows 10 fallback. Naming a font here
            // would opt out of both.
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

/// The controls with an `Icon` slot, as one surface.
///
/// WinUI puts `Icon` on each class separately with no common base, so
/// without this the lowering would be five copies of the same three
/// lines and the read another five. The impl list is also the honest
/// statement of WHICH kinds have the slot: `MenuBarItem` is absent
/// because it has none — 243 members in the pinned metadata, `Title`
/// and `Items` among them and no `Icon` anywhere.
trait IconSlot {
    fn set_icon_element(&self, icon: &IconElement) -> windows_core::Result<()>;
    /// `Err` for an EMPTY slot as much as for a failure: the property
    /// returns a null pointer when nothing is set, and windows-core
    /// turns that into `E_POINTER`. Callers that need to tell the two
    /// apart compare the code (see [`MenuIcon`]).
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

// THE WINUI 3 HIERARCHY IS NOT THE UWP ONE, and this list is where it
// shows. Under UWP `ToggleMenuFlyoutItem` derives from
// MenuFlyoutItemBase and has no icon at all; in the pinned WinUI 2.2.1
// metadata it derives from `MenuFlyoutItem`, so the checkable kind and
// the radio option inherit the slot. Read from the metadata, not from
// the UWP documentation a search finds first.
// AppBarButton joins the list for the toolbar (docs/chrome-plan.md C2):
// a promoted action's button takes the SAME IconElement the item's menu
// row takes, from the same `symbol_icon`, which is why the toolbar
// needed no icon code of its own and why its symbol read is the menu's
// read one control over.
icon_slot!(
    MenuFlyoutItem,
    ToggleMenuFlyoutItem,
    RadioMenuFlyoutItem,
    MenuFlyoutSubItem,
    NavigationViewItem,
    AppBarButton,
);

/// Stamp a concept onto a control's icon slot. One place, so every kind
/// that HAS a slot gets identical treatment and an unset symbol is
/// simply no icon (the `attach_accelerator` precedent).
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

/// The semantic name an icon element publishes to UIA — the read half
/// of [`symbol_icon`], and the one place that walks from an element to
/// its automation peer for this purpose.
///
/// TOTAL: every failure is a short description of WHAT WAS MEASURED,
/// never a panic and never a guess (CLAUDE.md invariant 3). The three
/// answers are distinguishable on purpose — an element with no peer, a
/// peer with an empty name, and a name — because they fail for
/// different reasons and the reader chases the sentence.
fn icon_uia_name(icon: &IconElement) -> String {
    let Ok(fe) = icon.cast::<bindings::Microsoft::UI::Xaml::FrameworkElement>() else {
        return "the icon element is not a FrameworkElement".to_owned();
    };
    uia_name(&fe, "the icon")
}

/// The name any live element publishes to UIA — what an assistive client
/// hears — or a short description of which of the three ways the read
/// failed. `what` names the thing being read so the sentence says what
/// it measured ("the icon", "the toolbar button Save").
///
/// EXTRACTED FROM [`icon_uia_name`] BY THE TOOLBAR ARM, which asks the
/// same question of an `AppBarButton` that the menu symbol read asks of
/// an `IconElement`; the icon's three sentences are unchanged
/// word-for-word.
///
/// TOTAL: every failure is a short description of WHAT WAS MEASURED,
/// never a panic and never a guess (CLAUDE.md invariant 3). The three
/// answers are distinguishable on purpose — an element with no peer, a
/// peer with an empty name, and a name — because they fail for
/// different reasons and the reader chases the sentence.
fn uia_name(fe: &FrameworkElement, what: &str) -> String {
    use bindings::Microsoft::UI::Xaml::Automation::Peers::FrameworkElementAutomationPeer;
    // CreatePeerForElement first, FromElement second — the `ax` read's
    // ladder, and for its measured reason: an element with no peer
    // class of its own (a Grid there, an icon here) has no peer until
    // one is made, and FromElement alone reported such elements absent
    // from a tree UIA is perfectly willing to describe.
    let peer = match FrameworkElementAutomationPeer::CreatePeerForElement(fe) {
        Ok(p) => p,
        Err(_) => match FrameworkElementAutomationPeer::FromElement(fe) {
            Ok(p) => p,
            // Same success-coded-error rule as MenuIcon::Empty: a NULL
            // peer means the element genuinely has none, while a
            // failure HRESULT means the call itself broke. The `ax`
            // read collapses both into one sentence; they are different
            // states and this one keeps them apart.
            Err(e) if e.code().is_ok() => {
                return format!("{what} has no automation peer")
            }
            Err(e) => return format!("{what}'s automation peer could not be made: {e}"),
        },
    };
    // An element with no name publishes the EMPTY string, not an error:
    // HSTRING is a clone type, so a null handle arrives as `Ok("")`
    // (windows-core 0.62.2 src/type.rs, the CloneType `from_abi`) —
    // which is why the empty case is a match guard here and not another
    // error arm.
    match peer.GetName() {
        Ok(name) if name.is_empty() => {
            // A real defect this read can see: kaya's lowering always
            // sets the name, so an icon without one was built somewhere
            // else or by a path that dropped it.
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
// outer (KayaOuter) answers its own interfaces and forwards the rest
// delegate QI to the inner, so Application::Current() — whose identity
// is the outer — cannot be cast back to Application. Everything the
// backend needs goes through this handle instead. UI thread only.
thread_local! {
    static APP: RefCell<Option<Application>> = const { RefCell::new(None) };
}

fn request_exit(code: i32) {
    // First writer wins, and it is not a nicety: Application.Exit()
    // closes the window, which fires Closed, which calls back in here
    // with 0. A plain store therefore overwrote a failing verdict's 1
    // with the close handler's 0 microseconds later, and every failing
    // Windows leg exited 0 — the suite greps EXIT=0, so a FAILED scene
    // reported PASS. Whoever decides the outcome first owns it; a
    // window closing afterwards is a consequence of that decision, not
    // a new one.
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
/// from any thread. The enqueued closure carries no data.
pub(crate) fn ring_doorbell() {
    if let Some(dispatcher) = DISPATCHER.get() {
        let handler = DispatcherQueueHandler::new(|| {
            drain_transactions();
            Ok(())
        });
        let _ = dispatcher.0.TryEnqueue(&handler);
    }
}

/// Recompute the clipboard roles' enablement ONE TICK LATER. The
/// callers are event handlers that can fire while CORE is borrowed —
/// a Focus() inside apply raises GotFocus, and the WNDPROC re-enters
/// CORE by construction — so neither may borrow here and now (the
/// close_window precedent). The tick defers past whatever borrow is
/// live.
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

fn drain_transactions() {
    CORE.with_borrow_mut(|core| {
        let Some(core) = core.as_mut() else { return };
        while let Ok(tx) = core.transactions.try_recv() {
            for op in core.scene.apply(tx) {
                apply(core, op).expect("kaya: applying an op failed");
            }
        }
        // ONE coalesced menu-chrome rebuild per drain, from the
        // post-user mirror. Quiet-armed as a belt: constructing and
        // stamping native items must never read as user activation
        // (the echo doctrine).
        if core.menus_touched {
            core.menus_touched = false;
            core.apply_quiet
                .store(true, std::sync::atomic::Ordering::Relaxed);
            let rebuilt = rebuild_menus(core);
            core.apply_quiet
                .store(false, std::sync::atomic::Ordering::Relaxed);
            rebuilt.expect("kaya: rebuilding the menu chrome failed");
        }
    });
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
/// non-core types (TextCommandBarFlyout inside TextBox's built-in
/// style, everything in XamlControlsResources) through an
/// IXamlMetadataProvider it obtains by QIing the Application object —
/// normally the subclass the XAML compiler generates. Without one,
/// deferred theme XAML fail-fasts the process
/// (STOWED_EXCEPTION_80004005 ... XamlSchemaContext::
/// GetTypeInfoProvider — microsoft-ui-xaml discussions #7357/#8151).
///
/// HAND-ROLLED, not #[implement]: the Application is composed via COM
/// aggregation with this object as the outer, and the AGGREGATION
/// CONTRACT requires the outer's QueryInterface to forward every IID
/// it does not implement to the inner's non-delegating IUnknown.
/// windows-core's #[implement] answers unknown IIDs with
/// E_NOINTERFACE instead, which made Application.Current() — an
/// identity QI for IApplication — fail 0x80004002, and every control
/// that consults it at runtime stow-crashed the process
/// (NavigationView's ResourceAccessor was the first; docs/traps.md).
///
/// Layout is three vtable slots at fixed offsets (identity /
/// IApplicationOverrides / IXamlMetadataProvider); the thunks recover
/// the object by subtracting the slot index. Lifetime is the process
/// (the framework holds the Application forever), so AddRef/Release
/// are counters in name only.
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

/// Recover the object from a slot's `this` pointer.
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
/// require_control_resources.
///
/// A process-global rather than CoreState, because the merge happens in
/// OnLaunched — before any transaction, and therefore before CORE holds
/// anything a menu apply could consult.
static CONTROL_RESOURCES: OnceLock<Result<(), String>> = OnceLock::new();

/// Refuse to build chrome whose default style lives in the resources
/// this process could not load, and SAY SO.
///
/// THE FAILURE THIS REPLACES, measured 2026-08-05 (todos_go /
/// todos_csharp, matrix, twice): the tiering below is right — most
/// templates resolve locally and a host without the pri must keep
/// working — but "log and continue" left the process to walk into a
/// bare `RaiseFailFastException` LATER, on a layout tick, with no
/// message. The dump's stack is
/// `DefaultStyles::GetDefaultStyleByTypeName` (0x800f1000) under
/// `CControl::EnterImpl` under `CLayoutManager::UpdateLayout`: XAML
/// realizing a MenuBarItem into the tree, asking for its built-in
/// style, and finding none. The guest had already served six harness
/// steps by then, so the crash pointed at the step that happened to be
/// running rather than at the menu — it cost this arm a dump and a
/// controlled substitution to say what the first line of the log
/// already knew.
///
/// The menu surface is where the wall goes because it is where the
/// dependency enters: a window MenuBar (ensure_menu_shell), a context
/// MenuFlyout (ensure_context_flyout) and the toolbar's CommandBar
/// (refresh_toolbar) are the three places kaya mints chrome from this
/// dictionary, and each is reached the first time an app declares the
/// thing — the most basic thing an app can do that provokes the
/// failure. The toolbar joined the list with C2 (docs/chrome-plan.md):
/// CommandBar, AppBarButton and — since the 2026-08-17 revision put the
/// bar in the caption row — TitleBar are MUX types whose default styles
/// live in the same framework dictionary as the menu's. Note that the
/// TitleBar arrives through the SAME call: one promotion mints all
/// three, so there is exactly one gate in front of the whole set.
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
    // Merge the framework's control resources once, at launch: a
    // code-only app has no App.xaml to do it, and while most control
    // templates happen to resolve without the merge, ProgressBar's
    // was the first to hit a missing theme key. The merge is TIERED
    // because it cannot always load: XamlControlsResources resolves
    // through ms-appx, which needs the exe-adjacent resources.pri —
    // present for the scene executables, structurally absent for
    // dll-hosted guests without the pri-adjacency runners. Where the
    // real merge fails, kaya logs, RECORDS THE REASON, and continues —
    // continuing is correct (every control whose template resolves
    // locally still works, which is most of them), but the recorded
    // reason is what turns the eventual death into a sentence rather
    // than a hex code (require_control_resources).
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
/// aggregation outer: the returned instance is the framework object,
/// identity QIs route to the outer (which answers
/// IXamlMetadataProvider and forwards the rest to the inner — see
/// KayaOuter). The outer and the inner reference live for the process
/// lifetime, matching the Application itself.
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

/// The Padding a container Grid must carry: the inset the container
/// itself declares (prop 17), plus the WINDOW inset when it is a
/// mounted surface root (wprop 8).
///
/// WinUI folds two boxes into one. SwiftUI and Compose NEST the window
/// inset — a padding on the window's content — around the container's
/// own `.padding(node.inset)`; a WinUI Grid has a single Padding, and a
/// mounted root's is already where the window inset lands. So a root's
/// Padding is the SUM, which is the same visual the nesting backends
/// produce, and the two harness reads take the other number back off
/// (`inset` reads the window's, `container_inset` a container's own).
/// Every writer goes through here — the prop's arm, the mount, the
/// window prop's restamp — so none of them can drop the other's term;
/// before this, the mount overwrote the container's inset with the
/// window's and nothing said so.
fn container_padding(core: &CoreState, id: WidgetId) -> f64 {
    let own = core.container_insets.get(&id).copied().unwrap_or(0.0);
    let root = core.mounted_roots.values().any(|&r| r == id);
    own + if root { core.inset } else { 0.0 }
}

/// Write [`container_padding`] onto a container. Not a container (or
/// destroyed): nothing to stamp.
fn stamp_container_padding(core: &CoreState, id: WidgetId) -> windows_core::Result<()> {
    let Some(NativeWidget::Column(grid) | NativeWidget::Row(grid) | NativeWidget::Grid2D(grid)) =
        core.widgets.get(&id)
    else {
        return Ok(());
    };
    let pad = container_padding(core, id);
    grid.SetPadding(Thickness {
        Left: pad,
        Top: pad,
        Right: pad,
        Bottom: pad,
    })
}

/// Rebuild one grid's track definitions and restamp its children's
/// attached indices.
///
/// A Grid does not lay out by child order the way a StackPanel does: a
/// child sits wherever its attached Grid.Row/Grid.Column says, and two
/// children with the same index overlap silently rather than erroring.
/// So the logical order kaya maintains has to be written back after
/// every structural change — add, move, or destroy — and the whole set
/// is rebuilt rather than patched, because inserting in the middle
/// shifts every later child's index anyway.
///
/// The track sizes carry the layout contract directly: `Auto` for a
/// weight-0 child (natural size) and `Star(w)` for a grower. WinUI's
/// star sizing already means "divide what is left after the Auto tracks
/// in proportion to the star values", which is exactly [`Prop::Grow`],
/// so unlike AppKit and GTK there is no arithmetic to do here — only the
/// weights to hand over.
/// Re-attach a 2D grid's children row-major per its current column
/// count, with one Auto track per row/column — called when children
/// or the columns prop arrive, in either order.
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

fn reindex(core: &CoreState, parent: WidgetId) -> windows_core::Result<()> {
    let (grid, vertical) = match core.widgets.get(&parent) {
        Some(NativeWidget::Column(g)) => (g.clone(), true),
        Some(NativeWidget::Row(g)) => (g.clone(), false),
        // Destroyed, or never a container: nothing to place.
        _ => return Ok(()),
    };
    let empty = Vec::new();
    let order = core.child_order.get(&parent).unwrap_or(&empty);

    if vertical {
        let defs = grid.RowDefinitions()?;
        defs.Clear()?;
        for child in order {
            let def = RowDefinition::new()?;
            def.SetHeight(track(core.grow.get(child).copied().unwrap_or(0.0)))?;
            defs.Append(&def)?;
        }
    } else {
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
        // The attached setters take a FrameworkElement, one step down
        // from the UIElement the widget table hands out; every widget
        // kaya creates is one.
        let element: FrameworkElement = widget.element()?.cast()?;
        let index = index as i32;
        if vertical {
            Grid::SetRow(&element, index)?;
        } else {
            Grid::SetColumn(&element, index)?;
        }
        // THE TEXTAREA'S LAYOUT FLOOR, AND THE ONE PLACE `grow` REACHES
        // IT. 240x96 is the size all four backends declare, and on the
        // other three it is a MINIMUM their layout stretches from
        // (GTK's `set_size_request`, this arm's own MinWidth). The
        // HEIGHT could not be one here — WinUI measures a control in an
        // Auto row against infinite height and gives it whatever it
        // asks for, so a 40-line document asked for 758 pixels and got
        // them — and an explicit Height is the only thing that bounds
        // it. It also OUTRANKS the star row's Stretch, which is how an
        // editor asking for a full-window buffer with grow(1) got 96dip
        // inside a correct 126dip track, with expect_shares (which
        // reads the definition) passing all the way.
        //
        // So the explicit height is what a NON-GROWER keeps, and a
        // grower on THIS grid's main axis trades it for the floor plus
        // Stretch. Main axis only: a grower in a ROW divides width, and
        // its height is align's business — releasing it there would
        // hand the wart straight back.
        if let NativeWidget::Textarea(field) = widget {
            let grows = vertical && core.grow.get(child).copied().unwrap_or(0.0) > 0.0;
            field.SetMinHeight(if grows { 96.0 } else { 0.0 })?;
            field.SetHeight(if grows { f64::NAN } else { 96.0 })?;
        }
        // Cross placement from the container's align mode. WinUI's
        // own default is Stretch; kaya's normalized default is start,
        // stamped explicitly so the two never drift. Baseline (rows
        // only) stamps Top here and gets its margin compensation
        // after the pass below — WinUI has no native baseline
        // alignment. One carve-out, the BREADTH rule: a nested
        // container whose main axis crosses its parent spans the
        // parent's breadth (a row in a column is as wide as the
        // column — the rule WinUI's Stretch default used to satisfy
        // for free, and the first stamped run broke: the grow row
        // hugged and split 31/69 of its own natural width).
        let crossing = matches!(
            (widget, vertical),
            (NativeWidget::Row(_), true) | (NativeWidget::Column(_), false)
        );
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
                // The caption sits inside the control; its baseline in
                // the CONTROL's space is its offset there plus its own
                // BaselineOffset.
                let at = caption
                    .TransformToVisual(&element)?
                    .TransformPoint(bindings::Windows::Foundation::Point { X: 0.0, Y: 0.0 })?;
                Some(f64::from(at.Y) + caption.BaselineOffset()?)
            }
            // No text baseline: the bottom-edge rule — the child's
            // baseline IS its bottom (the CSS replaced-element rule),
            // so a tall image drags the common baseline down and the
            // text children lift to meet it. Text-only compensation
            // aligned label to checkbox at ~14dip and left the image
            // at the top — geometrically indistinguishable from
            // start, which is exactly how the first Windows run
            // failed.
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

/// One child's track: natural size, or a share of the leftover.
fn track(weight: f64) -> GridLength {
    if weight > 0.0 {
        GridLength {
            Value: weight,
            GridUnitType: GridUnitType::Star,
        }
    } else {
        // Auto and not `*`: a weight-0 child takes its natural size and
        // takes no part in the division, which is what makes the growers'
        // shares come out of the leftover rather than the whole.
        GridLength {
            Value: 0.0,
            GridUnitType: GridUnitType::Auto,
        }
    }
}

/// A user-driven back on the window's top entry: an
/// intercept_back-armed top emits back_requested and nothing pops
/// (the veto class); an unarmed top pops here, reconciles the
/// core-owned stack post-fact, and reports entry_popped.
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
/// caption. Measured on Notepad 11.2606.15.0, which captions a modified
/// document `*<doc> - Notepad` and a clean one `<doc> - Notepad`
/// (scratchpad/dirty-probe-windows.md §4). Not trailing, not a bullet:
/// four other candidates round-tripped and rendered legibly, and this
/// is the one Windows apps actually use.
///
/// Notepad's *visible* mark is a dot in its own tab strip, because it
/// draws its own title bar; the asterisk still lives in the HWND
/// caption for the taskbar, Alt+Tab and automation. kaya draws a plain
/// system caption, so for kaya the caption string is both.
const DIRTY_MARK: &str = "*";

/// The caption a window SHOULD be showing, composed: the covering nav
/// entry's title if the stack has one, else the window's own, with the
/// dirty marker in front when the app has declared unsaved work.
///
/// THE DECLARED TITLE IS NEVER TOUCHED (docs/dirty-plan.md D1). The
/// marker is composed HERE, on the way to the OS, so `core.window_titles`
/// keeps exactly the bytes the app wrote and a title update while dirty
/// re-composes rather than dropping the mark. Qt's `[*]` placeholder —
/// a marker spelled inside the app's own title string — is the named
/// rejection; kaya's scene titles are byte-compared across five
/// platforms, so the declared string has to stay identical everywhere
/// while the chrome diverges.
///
/// THE MARKER RIDES THE CAPTION, not the window's own title string, so
/// a covering nav entry keeps it. That is the question the probe left
/// open (§1) and this is the answer with a reason: `dirty` is a
/// property of the WINDOW, and macOS — the one platform with a real
/// API — draws its dot on the window's close button regardless of what
/// the title bar currently reads. A marker that vanished on a nav push
/// would be a different observable semantics on this backend alone.
fn window_caption(core: &CoreState, window: u64) -> String {
    let title = core
        .nav_stacks
        .get(&window)
        .and_then(|s| s.last())
        .and_then(|id| core.nav_entries.get(id))
        .map(|e| e.title.clone())
        .unwrap_or_else(|| core.window_titles.get(&window).cloned().unwrap_or_default());
    if core.window_dirty.get(&window).copied().unwrap_or(false) {
        format!("{DIRTY_MARK}{title}")
    } else {
        title
    }
}

/// THE ONE CAPTION WRITER. Every `Window::SetTitle` in this backend
/// past the pre-app placeholder in `setup()` goes through here, and it
/// is the structural half of the dirty lowering: the composition has
/// one place to happen instead of four places to be forgotten.
///
/// It used to be four. `SetWindowProp`/Title tested `covered` and
/// wrote the window's own; `refresh_nav`'s split arm and both serial
/// arms each recomputed the same thing and wrote it again. The probe
/// costed a title-composed marker at exactly that: five sites, each of
/// which has to apply it or the mark blinks out on a nav push, a pop,
/// or a split-mode change (scratchpad/dirty-probe-windows.md §1). The
/// answer is not four disciplined call sites, it is one.
///
/// Idempotent by construction — it derives the whole caption from
/// state, so calling it after ANY of the three inputs moves (the
/// window's title, the nav stack, the dirty flag) is always correct
/// and never needs to know which one moved.
///
/// TWO SINKS, STILL ONE AUTHOR (the 2026-08-17 titlebar revision). A
/// promoted window draws its own caption text, so the composed string
/// goes to the window AND to the TextBlock in the caption's centre slot.
/// Two places it is DISPLAYED; one place it is decided.
///
/// AND THE CONTROL IS NOT ONE OF THEM, which is deliberate.
/// `TitleBar::UpdateTitle` does
/// `if (currentTitle != titleText) { appWindow.Title(titleText); }`
/// (microsoft-ui-xaml @ winui3/release/2.2.0,
/// `src/controls/dev/TitleBar/TitleBar.cpp:505-513`) — so a `TitleBar`
/// whose `Title` property is filled is a caption WRITER in its own
/// right, and the first casualty of two writers is the dirty marker,
/// silently, since `Stage::window_dirty` reads the live `Window::Title()`
/// and asks whether it starts with `*`. The property is left empty from
/// birth and the text is drawn by `window_caption_texts` instead: the
/// rival writer is not managed, it never exists.
fn refresh_caption(core: &CoreState, window: u64) -> windows_core::Result<()> {
    let caption = HSTRING::from(window_caption(core, window));
    let target = winui_window(core, window)?;
    target.SetTitle(&caption)?;
    if let Some(text) = core.window_caption_texts.get(&window) {
        text.SetText(&caption)?;
    }
    Ok(())
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

    // ADAPTIVE LIST-DETAIL (DESIGN.md). Both halves: the app asked
    // (wprop 6) and the window IS regular — the same 600 boundary the
    // other backends draw, read from XamlRoot's real size the way
    // menu_presentation already does.
    //
    // A two-column Grid rather than TwoPaneView: the semantic is
    // side-by-side panes, and WinUI's adaptive triggers ARE width
    // thresholds anyway. Same call GTK and Compose made — the
    // idiomatic wrapper is a ledger item, not a blocker.
    // Whichever arm is about to run, the previous split render must let
    // go of the roots first.
    release_split(core, window)?;
    let wants_split = core.list_detail.get(&window).copied().unwrap_or(false);
    //
    // SHORT-CIRCUITED on wants_split, and that matters: propagating the
    // read unconditionally made every nav scene fail, because a window
    // reconciling before its first mount legitimately has no content to
    // measure. The one remaining fallback is that case and says so —
    // no content is not a failed reading, it is nothing to lay out.
    let measured = window_client_width(core, window);
    if std::env::var("KAYA_SPLIT_TRACE").is_ok() {
        eprintln!(
            "KAYA_SPLIT_TRACE: window={window} wants_split={wants_split} \
             measured={measured:?} entries={}",
            core.nav_stacks.get(&window).map(|s| s.len()).unwrap_or(0)
        );
    }
    // NO width test here any more. TwoPaneView decides where one pane
    // becomes two, off its own MinWideModeWidth, and kaya no longer
    // draws that line: the app declares list-detail and the platform
    // says how it presents. The old `>= 600` was a number kaya invented
    // and then graded itself against.
    //
    // No `top.is_some()` either: an empty stack on a wide window shows
    // the leading pane and an EMPTY trailing one, the same as every
    // other backend. Semantics are never a backend's call.
    if wants_split {
        let base = core.window_roots.get(&window).cloned();
        let detail = top
            .and_then(|id| core.nav_entries.get(&id))
            .and_then(|e| e.wrapper.clone());
        if let Some(base) = base {
            let view = TwoPaneView::new()?;
            view.SetWideModeConfiguration(TwoPaneViewWideModeConfiguration::LeftRight)?;
            // Leading pane sized, trailing pane takes the rest — see
            // protocol::leading_pane_width. TwoPaneView's OWN default is
            // two equal panes, because it was built for dual-SCREEN
            // devices where each pane is a display; for list-detail on
            // one screen that is the down-the-middle split no platform
            // actually ships, so the proportion stays ours.
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
            // Which pane survives the collapse: the detail once the
            // stack has one, else the list. This is TwoPaneView's
            // spelling of libadwaita's show-content, and it is the only
            // stack fact the control is told.
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
            // WITH AN EMPTY STACK THE WINDOW KEEPS ITS OWN TITLE. This
            // used to fall back to the empty string, which is a window
            // with no title at all — the serial arm's None branch below
            // has always used window_titles for exactly this case, and
            // the split arm simply did not. Caught on macOS, where the
            // title bar is read for real and AppKit substitutes the
            // PROCESS NAME for an empty one (2026-07-27). Both arms now
            // ask window_caption, which is that fallback written once.
            refresh_caption(core, window)?;
            // The back bar follows the CONTROL's mode, now and every
            // time Windows changes it. Mode is decided during layout, so
            // reading it here alone would read the value from before
            // this pane arrangement existed — the measuring-what-you-are-
            // about-to-replace trap that cost this backend a day.
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
    // The serial arm stamps too.
    core.split_presentation.insert(window, "stacked");

    match top.and_then(|id| core.nav_entries.get(&id)) {
        Some(entry) => {
            // Collapsed: the entry COVERS the leading pane, so back
            // means something again and its bar comes back. The split
            // arm above hid it; this is the other half, and both arms
            // must write it or the state is derived-by-default in one.
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
    // Both arms end the same way — the covering entry's title or the
    // window's own, marker composed in — so the caption is written
    // once, after the content, rather than once per arm.
    refresh_caption(core, window)
}

/// Fill a navigation entry at mount: the wrapper Grid is the
/// backend's chrome — an auto-height back bar (the back affordance;
/// its click runs the SAME user-pop path a pointer press does) over
/// a star-height row holding the entry's root.
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

/// Assemble the window's sections chrome: a NavigationView — the
/// platform's own idiom, viable now that the aggregation outer
/// delegates QI (docs/traps.md) — whose items are the sections
/// (string content, the ComboBox content-stealing trap) and whose
/// Content is the active pane. Built ONCE and grown incrementally
/// (XAML refuses re-parenting); a hint change is just
/// SetPaneDisplayMode — Left for auto/`sidebar` (the ratified
/// Windows default), Top for `bar`. SelectionChanged is the USER
/// route, guarded by the swallow COUNTER (it raises async; the
/// entry_swallow pattern): unguarded raises reconcile the core and
/// emit.
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
                // A programmatic move's late raise: swallow it — the
                // model and emit were handled synchronously at the
                // set (the entry_swallow pattern).
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
                // borrow (the back-button precedent).
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
    // Grow incrementally: an item per section not yet appended (add
    // order; the set is append-only by grammar).
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
        // The switcher entry's icon rides its OWN slot, not the
        // content, so the title stays a plain string and the
        // content-stealing trap above stays shut.
        apply_symbol(&item, core.section_panes[sid].symbol)?;
        nav.MenuItems()?.Append(&item)?;
        core.section_items.insert(*sid, item);
    }
    let hint = core
        .sections_presentation
        .get(&window)
        .copied()
        .unwrap_or(0);
    // The number comes from the spec's enum rather than a literal:
    // renumber `sections_presentation` and every generated surface
    // moves while a hand-typed 1 would quietly start meaning `sidebar`.
    // Nothing mirrors this decision for the harness — the observation
    // reads the property back off the live control, below.
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
/// SelectionChanged raise (counter, not flag) and skip no-op moves,
/// which raise nothing and would leave the counter armed against a
/// future real switch.
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

/// WinUI's editable controls store every line break as a bare CR: text
/// SET with LF reads back with CR. TextBox does it out of its Rich Edit
/// heritage; the textarea's RichEditBox IS Rich Edit, and does the same.
/// The wire and every other backend speak LF, and guest-visible strings
/// are compared byte-for-byte across languages, so CR is normalized to
/// LF at every point where that text escapes toward the guest
/// (occurrence payloads, harness reads) or is compared against guest
/// text (the quiet-set and set_text guards — an unnormalized compare
/// never matches multi-line text and re-sets on every write).
///
/// THE TRAILING PARAGRAPH MARK IS A SEPARATE PROBLEM AND IS NOT SOLVED
/// HERE: a RichEdit story always ends in one, and `lf` would faithfully
/// turn it into a newline no guest ever wrote. `Editable::text` reads
/// with `TextGetOptions::AdjustCrlf`, which drops it, so what arrives
/// here is already the entry's shape.
fn lf(s: String) -> String {
    if s.contains('\r') {
        s.replace("\r\n", "\n").replace('\r', "\n")
    } else {
        s
    }
}

/// KAYA_WINUI_NAV_PROBE: wrap the primary mount in a NavigationView
/// ("bare" = no items; anything else adds two string items). The
/// stowed-E_NOINTERFACE bisection instrument (docs/traps.md): it
/// answers whether the control is viable in THIS hosting shape at
/// all, independent of kaya's sections machinery.
fn nav_probe_wrap(element: &UIElement) -> windows_core::Result<UIElement> {
    use bindings::Microsoft::UI::Xaml::Controls::{NavigationView, NavigationViewItem};
    let level = std::env::var("KAYA_WINUI_NAV_PROBE").unwrap_or_default();
    if level.is_empty() {
        return Ok(element.clone());
    }
    eprintln!("kaya: NAV PROBE armed ({level})");
    // The aggregation hypothesis: NavigationView's ResourceAccessor
    // consults Application.Current at runtime; with the outer
    // discarding the inner, identity QIs for IApplication die
    // E_NOINTERFACE. Reproduce the exact lookup it would make.
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
//
// One item vocabulary, two anchors. The WINDOW anchor is a real
// in-window MenuBar in its own Auto row of the window shell Grid; the
// WIDGET/NODE anchor is a MenuFlyout set as the element's
// ContextFlyout. Echo doctrine: ONE dispatch path — chrome clicks,
// the KeyboardAccelerator route, and harness verbs all land in
// menu_user_activate and emit; programmatic set_menu_prop writes
// mutate the model silently in the apply arm and the rebuild restamps
// the chrome from that mirror.

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
/// byte-for-byte (the shared-scene contract). The path walks the
/// SEMANTIC tree: a grouping root's label is a path segment whether or
/// not materialization mints a titled row — an inline nested
/// radio_group has none, yet "View>Sort>Date" must still land on Date.
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

/// Build the window shell at the first menubar_append (the ratified
/// lowering): a Grid whose FIRST Auto row is the TITLEBAR's, whose
/// second Auto row holds the MenuBar, and whose Star row is the content
/// slot every later mount/nav/sections swap fills. Built ONCE and grown
/// through rebuilds; any content the window already presents moves into
/// the slot (detached by the SetContent swap first — XAML refuses
/// re-parenting; docs/traps.md).
///
/// THE TITLEBAR ROW IS DECLARED HERE AND FILLED ELSEWHERE, deliberately.
/// An Auto row with no child measures zero, so every window whose
/// catalog promotes nothing keeps precisely the geometry it had before
/// the toolbar slice — which is the property that lets this row exist in
/// EVERY windowed scene's shell without moving a single other leg's
/// measurements. `refresh_toolbar` mints the `TitleBar` into it on the
/// first promotion.
///
/// THE MENUBAR IS BORN IN ROW 1 AND MAY LEAVE IT (the 2026-08-17 one-band
/// revision). A window that promotes an action wears one band: the menu
/// migrates into that window's `TitleBar.LeftHeader` and this row goes
/// EMPTY, which is to say it measures zero and the separate menu row is
/// gone. A window that promotes nothing has no caption control to migrate
/// into and keeps its menu here, under the system caption — the same
/// derivation ("extended is derived from toolbar presence") seen from the
/// menu's side. `rehost_menubar` owns both directions and is the only
/// place the bar changes parents.
fn ensure_menu_shell(core: &mut CoreState, window: u64) -> windows_core::Result<()> {
    use windows_core::Interface as _;
    if core.menubars.contains_key(&window) {
        return Ok(());
    }
    // The MenuBar's items are realized by a LAYOUT PASS, not by the
    // append below, which is why the failure this guards used to land
    // milliseconds later on a dispatcher tick and read as a defect in
    // whatever step was running.
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

/// THE CAPTION BAND'S METRICS, and every one of them is the platform's
/// own number read out of the pinned controls' theme resources
/// (microsoft-ui-xaml @ winui3/release/2.2.0). kaya invents none of them
/// and exposes none of them: they exist because two runs of buttons —
/// the system's caption cluster and the app's promoted commands — have
/// to sit in ONE band, and the first version of this arm put them in two.
///
/// THE MAINTAINER'S WORDS FOR THAT VERSION, kept because they are the
/// acceptance test: "the toolbar icons are on the same row as the
/// close/minimize/expand, but they are aligned and sized completely
/// differently. they look like you just randomly threw them onto the
/// middle of the screen." Measured, that was 68x48 command cells centred
/// 9 DIP below a 46x32 system cluster.
///
/// `CAPTION_COMMAND_CELL` — the width one promoted command occupies.
/// `AppBarButton`'s own default is 68 (`DefaultAppBarButtonStyle`'s
/// `<Setter Property="Width" Value="68"/>`), which is a TOOLBAR metric:
/// it is sized for a strip of its own, where the label sits under the
/// icon. In a caption band the cell is square and its side is the band —
/// `AppBarThemeCompactHeight` (48), the same resource the CommandBar's
/// own "…" overflow button takes for its `MinHeight`, so the run of
/// cells is uniform including the affordance kaya does not mint.
const CAPTION_COMMAND_CELL: f64 = 48.0;

/// The theme key holding the height an `AppBarButton`'s own template is
/// laid out for, which is NOT the height of the row it sits in.
///
/// WHAT IT REPAIRS, measured (scratchpad/chrome/winui-clip.md §2). An
/// `AppBarButton` in a CLOSED CommandBar is put in the `Compact` visual
/// state, which sets its pointer-over visual's margin to
/// `AppBarButtonInnerBorderCompactMargin` = **2,6,2,22**
/// (`AppBarButton_themeresources.xaml:119,150`). Those 22 DIP are the
/// collapsed label's row. On a button of `AppBarThemeMinHeight` — 64 —
/// the hover border is y 6..42, 36 tall, centre 24, and
/// `AppBarButtonContentViewboxCollapsedMargin` = 0,16,0,2 puts the 16 DIP
/// icon at y 16..32, centre 24: concentric, which is the arrangement those
/// two margins were written together for.
///
/// THE CAPTION ROW IS 48, and that is what breaks it. The `TitleBar`
/// control's expanded row is 48 (`AppBarThemeCompactHeight` is the same
/// 48), so the button is MEASURED against 48 and arranged 48 while both
/// margins stay absolute: the hover border becomes `48 - 6 - 22` = 20 DIP
/// tall, still top-aligned at 6, and its bottom edge cuts across the
/// button's own icon at y 26 with six rows of glyph drawn below it on bare
/// background. That is the maintainer's "the grey box on hover of the
/// command buttons is also cut off" (2026-08-18) — and it is not a clip:
/// pixel-measured, the box's edge profile is symmetric top and bottom, so
/// it is a COMPLETE rounded rect that is 16 DIP too short.
///
/// SO THE BUTTON IS GIVEN THE HEIGHT ITS OWN TEMPLATE ASSUMES, read out of
/// the dictionary rather than written here, and the CommandBar's own clip
/// takes the empty label row back off: `LayoutRoot`'s `Grid.Clip` is
/// `TemplateSettings.ClipRect`, the closed bar's compact height, so the
/// 64 DIP button is clipped to the 48 DIP band for RENDERING AND FOR
/// HIT-TESTING both. Measured after: `Root` 48x64, hover border 44x36 at
/// y 6..42, and UIA still publishes each button as 48x48 — the clip, seen
/// from outside.
///
/// The `MoreButton` beside them needs none of this: `EllipsisButton` is
/// written for 48 outright (`MinHeight` = `AppBarThemeCompactHeight`,
/// margin `AppBarEllipsisButtonInnerBorderMargin` = 2,6,6,6 → 40x36
/// centred), which is why its hover box was the right shape all along and
/// its neighbours' were not.
const CAPTION_COMMAND_BUTTON_BOX_KEY: &str = "AppBarThemeMinHeight";

/// The width of the drag strip between the promoted commands and the
/// system's minimize/maximize/close, in DIP.
///
/// WHAT OWNS THAT GAP, read off the template rather than guessed. The
/// `TitleBar` control's template is a twelve-column Grid
/// (`scratchpad/chrome/TitleBar-v220.xaml:168-193`). Column 9 is
/// `PART_RightHeaderPresenter`, where kaya's `CommandBar` lives, and it
/// carries no margin and no padding — neither in the template nor from
/// this backend. Column 11 is `RightPaddingColumn`, which the control
/// overwrites every layout with `AppWindowTitleBar.RightInset()`
/// (`TitleBar.cpp:466-478`), so it is exactly the system caption
/// cluster's own width. Between them sits column 10, which holds NO
/// template child at all and whose whole width is
/// `TitleBarMinDragRegionWidth` — 48 in the library's dictionary
/// (`TitleBar_themeresources.xaml:85`). Measured on the lane before this
/// constant existed: rightmost command's right edge 812, leftmost system
/// button 860, gap 48 to the pixel. The gap is that column and nothing
/// else.
///
/// WHY 48 IS THE WRONG NUMBER HERE. The column is a MINIMUM DRAG REGION:
/// it exists so that a caption whose slots are full still leaves the user
/// somewhere to grab. In this band that job is already done many times
/// over, and the control's own source says why. `UpdateInteractableElementsList`
/// (`TitleBar.cpp:753-811`) punches the Left and Right header presenters
/// out WHOLE, but for `Content` it recurses through
/// `FindInteractableElements`, which only punches out elements that are
/// `Control`s and enabled (`TitleBar.cpp:1026-1038`). kaya's Content is a
/// bare `TextBlock`, and `TextBlock` derives from `FrameworkElement`, not
/// from `Control` — so nothing in column 8 is ever punched out, and
/// column 8 is `Width="*"`. Every pixel between the menu and the commands
/// is drag surface; on the measured 946-wide window that is a strip about
/// 450 px across, with the title drawn in the middle of it. Column 10 is
/// belt-and-suspenders, and 48 DIP of it is a caption button's worth of
/// nothing next to commands the maintainer asked to read as one family
/// with the system cluster.
///
/// WHERE 8 COMES FROM. It is the gap this band ALREADY draws between two
/// caption-hosted controls, measured on the same run as the 48 above:
/// the `MenuBar` items in `LeftHeader` sit 8 apart (`MenuBarItemMargin`
/// is 4,4,4,4, `MenuBar_themeresources.xaml:44-46`), and the `TitleBar`
/// dictionary spells the same number for the gap after the title
/// (`TitleBarTitleMargin` = 0,0,8,0, `TitleBar_themeresources.xaml:93`).
/// So the strip is not a new metric: it is the band's existing
/// element-to-element gap, applied once more, at the one place that was
/// still using a reserve-a-whole-button number.
///
/// WHAT THE STRIP IS FOR AT 8, stated honestly because the number is
/// small: it is SEPARATION, not the drag affordance. A user who reaches
/// for the overflow "…" must not be one rounding error away from Close.
/// The drag affordance is column 8, which is measured above and which
/// the lane drags by. 0 would be defensible for dragging and is not
/// defensible for that neighbour.
const CAPTION_DRAG_STRIP: f64 = 8.0;

/// Write `CAPTION_DRAG_STRIP` into the application's resource dictionary
/// under the `TitleBar` control's own key.
///
/// THIS IS THE PLATFORM'S OWN MECHANISM, not a workaround. Every metric
/// in that template is a `{ThemeResource}` lookup, and a lookup from
/// inside a control template walks out to `Application.Resources` before
/// it reaches the framework's dictionaries. Overriding a theme key in the
/// app dictionary is what an App.xaml would spell as
///
/// ```xml
/// <Application.Resources>
///   <ResourceDictionary>
///     <ResourceDictionary.MergedDictionaries>
///       <XamlControlsResources/>
///     </ResourceDictionary.MergedDictionaries>
///     <x:Double x:Key="TitleBarMinDragRegionWidth">8</x:Double>
///   </ResourceDictionary>
/// </Application.Resources>
/// ```
///
/// kaya is a code-only app with no App.xaml (`outer_on_launched` merges
/// `XamlControlsResources` by hand for the same reason), so this is that
/// same document written through the same object. A DIRECT entry rather
/// than another merged dictionary, deliberately: a dictionary's own keys
/// are searched before any of its merged ones, so this wins regardless of
/// what else is appended later — `apply_brand` appends after launch and
/// the ordering rule in its doc comment does not have to be re-derived
/// here. The value is a boxed `f64`, which is byte-for-byte what the
/// library's own `<x:Double>` becomes at runtime, so the `GridLength`
/// conversion on the far side sees exactly what it sees today.
///
/// CALLED AT THE MINT, BEFORE THE FIRST `TitleBar` EXISTS, and that
/// placement is load-bearing: a resource VALUE changed after a tree is
/// built does not re-flow it (the same rule `apply_brand`'s doc comment
/// records — Microsoft's own theme editor cycles `RequestedTheme` to
/// force it). The mint arm runs exactly once per promoted window and is
/// the same chokepoint `require_control_resources` guards, so there is no
/// path to a `TitleBar` that skips it.
///
/// THE READ-BACK PROVES THE DICTIONARY ANSWERS, AND ONLY THAT. `Insert`
/// on a `ResourceDictionary` returns whether it replaced an existing key,
/// which says nothing about whether the value arrived, so the value is
/// read back through the same `Lookup` the rest of this module uses. What
/// that cannot prove is that the CONTROL consumed it: column 10's width
/// is not readable without a layout pass, and there is none here. That
/// half is measured on the lane instead, by reading the gap between the
/// last command and the first caption button off UIA — 48 before this
/// function existed, 8 after (`scratchpad/chrome/winui-caption-gap.md`).
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
    /// deliberately touches no core state: the layout callback that reads
    /// it runs inside `refresh_toolbar`'s own `RecomputeDragRegions`, which
    /// holds the `CORE` borrow.
    static CAPTION_GEOMETRY_ARMED: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// The height an `AppBarButton`'s own template is laid out for, read out
/// of the theme dictionary rather than written down here.
///
/// A MISSING KEY IS FATAL AND SAYS SO. The number is not a preference this
/// backend could fall back from: `CAPTION_COMMAND_BUTTON_BOX_KEY`'s whole
/// documentation is the arithmetic that ties this value to
/// `AppBarButtonInnerBorderCompactMargin`'s 22 and
/// `AppBarButtonContentViewboxCollapsedMargin`'s 16, and a guess would put
/// the hover visual back across the icon with nothing to notice it.
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
/// the arrangement XAML actually produced.
///
/// WHY A POST-CONDITION AND NOT A GATE. Both failures this checks for are
/// SILENT and no scene can see either: a hover visual sitting 16 DIP above
/// the icon it belongs to, and an overflow glyph with a row shaved off its
/// dots, are pixels. Every harness read here goes through the button
/// OBJECTS — `expect_toolbar_item` resolves a UIA name, `menu_state` reads
/// a flag — and all of those answer the same whether or not the button is
/// drawing itself correctly. The two writes that place them
/// (`button.SetHeight`, `apply_caption_ellipsis_box`) are also both the
/// kind that fail QUIETLY: a `{ThemeResource}` written after the template
/// is applied is simply ignored, and a height that stops being written
/// leaves a button that still measures 48x48 to UIA. So the wall is a
/// measurement of the ARRANGEMENT, on the path every promoted window runs.
///
/// IT RUNS AFTER A LAYOUT, WHICH IS WHY IT IS DEFERRED. `refresh_toolbar`
/// arms it and the caption's own `LayoutUpdated` fires it, because the
/// rebuild may be adding the bar to the tree for the first time and there
/// is nothing arranged to measure yet. An unarranged pass leaves it armed
/// rather than passing vacuously — a check that answers "0x0, fine" is the
/// census that read nothing and agreed with everything.
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
        // No promoted commands: nothing in this band to measure.
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
         scratchpad/chrome/winui-clip.md). A box of the library's size means \
         the write did not reach the control — the usual cause is ordering: a \
         {{ThemeResource}} is resolved when the template is applied, so \
         apply_caption_ellipsis_box has to run BEFORE the CommandBar exists, \
         which is why it is welded into mint_caption_titlebar."
    );

    // EVERY PROMOTED COMMAND'S HOVER VISUAL IS CONCENTRIC WITH ITS ICON.
    // Found by the names the AppBarButton template gives them: a button's
    // `Root` is the node carrying both.
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
    // this check exists to refuse: it means the walk did not find the
    // template parts, not that the geometry is right.
    let buttons = VisualTreeHelper::GetChildrenCount(&header)?;
    if buttons > 0 && checked == 0 {
        return Ok(false);
    }
    Ok(true)
}

/// The one place a `TitleBar` is constructed, so that the one ordering it
/// depends on cannot be got wrong.
///
/// THE FAILURE THIS EXISTS FOR IS SILENT, and it is the same shape as the
/// one the previous revision measured for a menu that never reached the
/// caption. `apply_caption_drag_strip` writes a `{ThemeResource}` value,
/// and a theme resource is resolved when the template is applied — write
/// it afterwards and the control keeps the library's 48, the band gets a
/// caption button's worth of dead space back, and NOTHING FAILS: no
/// harness verb reads a template column's width (there is no such concept
/// on the other four backends, so there is no uniform read to add), the
/// toolbar and menus scenes pass unchanged, and the only witness is a
/// screenshot somebody has to think to take.
///
/// Two adjacent statements whose order matters is not a guard — a
/// refactor reorders them without reading either comment. One function
/// that does both, called from one site, is: the ordering is now a
/// property of these three lines instead of a property of
/// `refresh_toolbar`'s statement order.
///
/// WHAT WOULD FINISH THE WALL and is not in this arm's file list: a
/// census in `tools/` that `TitleBar::new()` appears in this module only
/// inside this function. That is the clause which survives someone adding
/// a second caption; it is noted in
/// `scratchpad/chrome/winui-caption-gap.md` for the maintainer rather
/// than left to memory.
fn mint_caption_titlebar() -> windows_core::Result<TitleBar> {
    apply_caption_drag_strip()?;
    apply_caption_ellipsis_box()?;
    TitleBar::new()
}

/// The height of the box the CommandBar's "…" glyph is drawn in, in DIP.
///
/// WHY THIS EXISTS, measured (scratchpad/chrome/winui-clip.md §1-2). The
/// CommandBar template draws its overflow affordance as
///
/// ```xml
/// <FontIcon x:Name="EllipsisIcon" FontSize="20" Glyph="&#xE712;"
///           Height="{ThemeResource AppBarExpandButtonCircleDiameter}" />
/// ```
///
/// (`scratchpad/chrome/v220-CommandBar_themeresources.xaml:839`) and that
/// resource is **3** in the shipped dictionary — a key whose name is ONE
/// DOT'S DIAMETER used as the whole icon's height. So a 20 DIP glyph is
/// arranged in a 3 DIP box: read off the live tree, `EllipsisIcon` is
/// `20.0x3.0` with its own TextBlock `20.0x20.0` centred on it and hanging
/// 8.5 DIP out of it top and bottom. Only what falls inside the 3 DIP box
/// is painted.
///
/// WHAT THAT COSTS ON THE GLASS, pixel-measured at 1:1 (dpi 96): each dot
/// renders with an anti-aliased TOP row, two full rows, and then nothing —
/// two byte-identical full rows followed by pure white, which is not a
/// shape any font draws. With the box opened to the glyph's own type size
/// the same three dots render FOUR rows and the new bottom row is the
/// exact mirror of the top. One anti-aliased row of every dot was being
/// cut off, and the glyph sat half a pixel low as well; it now centres on
/// the band like every other icon in the row.
///
/// 20 IS THE GLYPH'S OWN FONT SIZE, the literal three lines up in the same
/// element. The box is the type size the icon is drawn at, which is the
/// smallest honest answer to "how tall is this icon"; kaya invents no
/// number here any more than it does for the drag strip.
const CAPTION_ELLIPSIS_ICON_BOX: f64 = 20.0;

/// Give the CommandBar's "…" a box its own glyph fits in.
///
/// Written through `Application.Resources` under the platform's own key —
/// the same lightweight-styling route, with the same timing rule, as
/// `apply_caption_drag_strip`: a `{ThemeResource}` is resolved when the
/// template is applied, so this has to be in the dictionary BEFORE the
/// `CommandBar` exists. That is why it is welded into
/// `mint_caption_titlebar` beside its sibling rather than left as a
/// statement someone can move.
///
/// SCOPED IN PRACTICE THOUGH THE KEY IS GLOBAL: `CommandBar::new()` is
/// called in exactly one place in this backend (`refresh_toolbar`), kaya
/// exposes no CommandBar widget kind, so the only bar this can reach is
/// the caption's own.
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
/// header, in DIP.
///
/// IT IS `CAPTION_DRAG_STRIP`'S NUMBER, for `CAPTION_DRAG_STRIP`'S REASON:
/// 8 is the gap this band already draws between two of its own elements —
/// `MenuBarItemMargin` is 4,4,4,4 so the menu's items sit 8 apart
/// (`MenuBar_themeresources.xaml:44-46`), and the `TitleBar` dictionary
/// spells the same 8 for the gap after its own title
/// (`TitleBarTitleMargin` = 0,0,8,0, `TitleBar_themeresources.xaml:93`).
///
/// A FLOOR IS NEEDED ONLY BECAUSE THE TITLE MOVED. Centred in the CONTENT
/// SLOT — the arrangement this backend shipped until 2026-08-17 — the title
/// could never approach a header: the slot is the space between them and
/// the middle of it is as far from both as a point can be. Centred on the
/// WINDOW it can, whenever one header outweighs the other, and on a narrow
/// window it would cross one. So the floor is the band's existing rhythm
/// applied once more rather than a new metric, exactly like the strip.
const CAPTION_TITLE_GAP: f64 = 8.0;

/// How far the arranged title may sit from the centre this backend asked
/// for before `center_caption_title`'s post-condition calls it a defect, in
/// DIP.
///
/// IT IS NOT THE ACCEPTANCE FIGURE, and the difference is the point. The
/// acceptance is 1 PHYSICAL PIXEL, measured off UIA by the probe that sits
/// beside this file — `title-centre-probe.sh`, which drives
/// `title-centre-probe.ps1` against a live guest on the VM and prints one
/// line per geometry. This is the in-process
/// wall, and what it exists to catch is a MODEL that stopped being true —
/// a centring that was removed, a slot that is no longer the element this
/// code measures, a header whose extent moved without a layout pass. Every
/// one of those is tens of pixels wrong (the arrangement this replaces was
/// 63 px off), so a generous tolerance still catches all of them, while a
/// tight one would risk aborting a shipped app over XAML's own layout
/// rounding — which is up to half a physical pixel, and is the ONLY
/// discrepancy that can legitimately appear here.
const CAPTION_TITLE_TOLERANCE: f64 = 1.5;

/// The `TitleBar` template's name for the element that occupies column 8 —
/// the caption's content slot, and the one thing that says where the space
/// between the two headers begins and ends
/// (`scratchpad/chrome/TitleBar-v220.xaml:262-266`).
const CAPTION_CONTENT_SLOT_PART: &str = "PART_ContentPresenterGrid";

/// What the last centring pass asked for, and the geometry it asked it
/// from. One entry per promoted window; dropped with the window.
///
/// EVERY FIELD BUT `centre` IS AN INPUT, and that is what makes the
/// post-condition safe to run: if this pass measures exactly what the last
/// pass measured, then the arrangement in front of this code IS the one
/// the last pass's margin produced, and the achieved centre may be compared
/// with the asked-for one. If ANY input moved — a live resize, a menu that
/// grew, a title that changed — the comparison is skipped for that pass,
/// because the layout in front of us is then the answer to a question
/// nobody asked any more.
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
    /// A THREAD-LOCAL RATHER THAN `CoreState`, and it is the same rule the
    /// text-range state at the top of this file records: this map is
    /// written from a XAML LAYOUT CALLBACK, and a callback that touched
    /// `CORE` would be one synchronous raise away from aborting the
    /// process — `CORE.with_borrow_mut` panics on a live borrow, and
    /// `refresh_toolbar` holds exactly that borrow while it calls
    /// `RecomputeDragRegions`, which forces a synchronous layout. The
    /// centring reads nothing from the core (a `TitleBar` can be asked for
    /// its own headers and its own content), so the one thing it must
    /// remember lives here instead.
    static CAPTION_TITLE_AIM: RefCell<HashMap<u64, CaptionTitleAim>> =
        RefCell::new(HashMap::new());
}

/// The caption's title `TextBlock`, minted with the two text properties the
/// clamp depends on.
///
/// WHY MARKUP AND NOT `TextBlock::new()`. `TextTrimming` and `TextWrapping`
/// are vtable PADS in this backend's generated bindings — the filter in
/// `tools/winui-bindgen` has never named them, and that file is outside
/// this arm's file list — so there is no setter to call. `XamlReader` is
/// the platform's own parser and the values it writes are LOCAL VALUES,
/// which beat a style's setters in XAML's property precedence; that
/// matters, because `CaptionTextBlockStyle` inherits `BaseTextBlockStyle`,
/// whose `TextWrapping` is `Wrap` and whose `TextTrimming` is `None`. The
/// template's own `PART_TitleText` writes exactly these two attributes on
/// top of exactly this style (`TitleBar-v220.xaml:238-242`), which is the
/// control telling us the style does not supply them.
///
/// WHAT THEY BUY, and it is not decoration: a title clamped into a span
/// narrower than the text must give way SOMEWHERE. `Wrap` gives way by
/// growing a second line inside a 48 DIP band; `None` gives way by cutting
/// the last glyph in half. `NoWrap` + `CharacterEllipsis` gives way by
/// saying so, which is the only one of the three a reader can act on.
///
/// `HorizontalAlignment` is `Stretch`, which is the default and is written
/// anyway because `center_caption_title` depends on it: the title fills the
/// box its presenter gives it, and that box is its own measured width (or
/// `MaxWidth`, when the clamp has narrowed it), so the rect UIA publishes
/// is never wider than the ink by more than a rounded pixel. Under `Center`
/// the ink would float inside a box a fraction wider, and the rect the
/// probe reads a centre from would not be the rect this code aimed.
///
/// THE FLAG FOR THE COORDINATOR: the cleaner home for those two properties
/// is two members in the bindgen filter, after which this function is
/// `TextBlock::new()` and two setters. It is written this way because
/// `tools/` is not in this arm's file list, not because markup is better.
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

/// THE TITLE CENTRES ON THE WINDOW, not on the space left over between the
/// headers — the maintainer's ruling of 2026-08-17, and VS Code's rule:
/// "if we're doing the one bar thing we have to commit and fully go with
/// vscode's behavior".
///
/// WHAT IT REPLACES, and why the previous answer was not good enough. The
/// `TitleBar` template puts the Content presenter in column 8 and centres
/// it there (`TitleBar-v220.xaml:262-272`, `HorizontalAlignment` =
/// `{ThemeResource TitleBarContentHorizontalAlignment}` = Center), so the
/// title lands in the middle of the space BETWEEN the menu and the
/// commands. That space is not the window: the right side carries the
/// commands, the drag strip and the system's caption cluster while the left
/// carries only the menu, and the title came out 83 px left of the window's
/// centre in the toolbar scene (63 after the strip shrank to 8). Two
/// previous arms recorded that as the platform's answer and left it. It
/// reads as a title that missed.
///
/// HOW IT AIMS: A BIAS THAT COSTS NO SIZE, PLUS ONE MEASURED CORRECTION.
/// The margin written is `(d, 0, -d, 0)`. Its two halves cancel in the
/// title's DESIRED size — which is the whole point, see the ratchet below —
/// while its arranged box moves by `d`, so `d` is pure position. The width
/// is a separate property, `MaxWidth`, because that one genuinely must not
/// enter the desired size either.
///
/// AND `d` IS CORRECTED, NOT PREDICTED: `d += wanted x - measured x`. Both
/// terms are read (the second off the live tree), so no model of the
/// template's arithmetic can be wrong here, and the correction converges in
/// ONE step rather than iterating, because the presenter's own position
/// does not depend on `d` — the bias cancels out of everything the layout
/// uses to place the presenter. The wanted x is snapped to the physical
/// pixel grid first, since XAML arranges there (`UseLayoutRounding`); an
/// off-grid target would be rounded by the layout, re-measured as an error,
/// and corrected forever.
///
/// THE RATCHET, WHICH IS THE REASON FOR ALL OF THAT, and it was measured on
/// the lane rather than feared. The obvious spelling of "put the title
/// HERE" is a margin pair that carves the wanted rect out of the slot:
/// `Left = x - slot0`, `Right = slot1 - (x + width)`. It aims perfectly —
/// drift 0 at every width — and it makes the title's desired width equal
/// the SLOT's width, because a margin is part of what an element asks for.
/// That travels: the star column asks for it, the template's Grid asks for
/// it, the window's content asks for it, and a window whose content asks
/// for 1098 DIP does not lay out again when it is dragged narrower. The
/// measured symptom was a band frozen at its widest, with the title, the
/// menu and the commands all where the widest window had left them, and NOT
/// ONE further layout pass to notice — the caption stopped following its
/// own window and nothing anywhere failed.
///
/// EVERY NUMBER IT USES IS MEASURED OFF THE LIVE TREE. The band's width is
/// the control's own `ActualWidth` (the `TitleBar` fills the shell's top
/// row, so it is the window's client width). The slot is the title's
/// GRANDPARENT — `PART_ContentPresenter`'s own parent is
/// `PART_ContentPresenterGrid`, the element that occupies column 8 — read
/// by transform and `ActualWidth` rather than reconstructed from
/// `TitleBarLeftHeaderPaddingWidth` and the insets, so no theme constant
/// can go stale underneath it. The headers are `LeftHeader()` and
/// `RightHeader()`, which are the menu and the command bar themselves. The
/// title's untrimmed width comes from measuring it against an infinite
/// constraint, which is the only reading that does not already have this
/// function's own clamp folded into it.
///
/// THE CLAMP. The title may not come nearer either header than
/// `CAPTION_TITLE_GAP`, and it may not leave the slot on the left (the
/// control's own left-header padding column already holds 14 DIP there, so
/// the slot's edge is the stricter bound — both are computed and the
/// stricter wins). When the ideal position would cross either bound the
/// title is pushed back to it, and when the span itself is narrower than
/// the text the text is given the span and ellipsizes inside it. The order
/// matters: a title never overlaps a header, and never disappears rather
/// than shortening.
///
/// THE HOOK IS `LayoutUpdated`, and it is the honest one. The geometry
/// moves for four different reasons — the window resizes, the menu's items
/// change, the promoted command set changes (including the `CommandBar`'s
/// OWN dynamic overflow, which kaya never hears about), and the caption
/// text changes — and every one of them is a layout pass by definition,
/// while only three of them are anything kaya calls a function for. It is
/// also the hook the control itself uses for the same class of problem:
/// `AutoRefreshDragRegions` subscribes to `Content()`'s `LayoutUpdated`
/// (microsoft-ui-xaml @ winui3/release/2.2.0, `TitleBar.cpp:603-606`).
/// That subscription is also why this function does not touch the drag
/// regions: the Content IS the title, so a margin written here raises the
/// event the control is already listening to, and the rects are recomputed
/// by the control on the pass that follows. (The title contributes nothing
/// to those rects in any case — `FindInteractableElements` punches out only
/// `Control`s, and a `TextBlock` is not one; see `CAPTION_DRAG_STRIP`.)
///
/// IT CONVERGES, AND THE REASON IS STRUCTURAL RATHER THAN A LIMIT. Nothing
/// this function measures depends on what it writes: column 8 is `Width="*"`
/// so the slot's span does not follow the title's margin, and the headers
/// are in their own columns. The margin is therefore a pure function of
/// geometry the title cannot influence, so the second pass computes the
/// same `Thickness`, writes nothing, and the layout settles. A version that
/// inferred the slot's centre from the title's own arranged position would
/// have layout rounding in its feedback path and could oscillate forever;
/// this one has no feedback path at all.
///
/// THE POST-CONDITION IS THE WALL — see `CaptionTitleAim`. The failure this
/// arm can have is the silent kind: delete the write and the title goes
/// back to the slot's centre, every scene still passes (no harness verb
/// reads a caption's geometry, and there is no uniform read to add — the
/// other four backends draw their own band), and the only witness is a
/// screenshot somebody has to think to take. So the arrangement is checked
/// against what was asked for, on every pass whose inputs have not moved
/// since the pass that asked. Measured with the write deleted: it fires.
fn center_caption_title(window: u64, titlebar: &TitleBar) -> windows_core::Result<()> {
    let band = titlebar.ActualWidth()?;
    if band <= 0.0 {
        // Before the first arrange, and while the caption is collapsed
        // (the promotion emptied), there is no geometry to read. The pass
        // that follows the next arrange does the work.
        return Ok(());
    }
    let Ok(title) = titlebar.Content().and_then(|content| content.cast::<TextBlock>()) else {
        return Ok(());
    };
    let title_fe: FrameworkElement = title.cast()?;
    let within: UIElement = titlebar.cast()?;

    // THE SLOT, BY THE NAME THE TEMPLATE GIVES IT.
    // `PART_ContentPresenter` centres the title inside itself, so the
    // presenter is not the slot; the slot is the element carrying
    // `Grid.Column="8"`, which the template calls
    // `PART_ContentPresenterGrid` (`TitleBar-v220.xaml:262-266`).
    //
    // NOT BY WALKING UP FROM THE TITLE, and that is measured rather than
    // preferred: `FrameworkElement.Parent` is the LOGICAL parent and it
    // is NULL here — a `TemplateBinding` to `TitleBar.Content` puts the
    // element in a presenter without giving it a logical parent, so the
    // first version of this function read `Err` and silently centred
    // nothing (the lane measured the title still 63 px left of the
    // window's centre, with no error anywhere).
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
             (scratchpad/chrome/TitleBar-v220.xaml:262-266) and it is the only \
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
    // nothing on the left to collide with, and one with no command bar
    // ends its content slot where the drag strip begins.
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

    // WHERE THE TITLE IS NOW, and by how much this code already moved it.
    // The bias is written as `(d, -d)`, so reading `Left` reads `d`.
    let bias = title.Margin()?.Left;
    let origin = element_origin_x(&title_fe, &within)?;
    let width = title.ActualWidth()?;

    // THE SPAN THE TITLE MAY OCCUPY. The slot's own edge is the stricter
    // bound on the left (the control's left-header padding column already
    // holds 14 DIP there) and keeping inside it is not only manners: an
    // element biased out of its slot is at the mercy of whatever the
    // template clips.
    let span0 = slot0.max(left_edge + CAPTION_TITLE_GAP);
    let span1 = right_edge.min(slot1) - CAPTION_TITLE_GAP;
    let available = (span1 - span0).max(0.0);

    // The window's centre, which is the whole ruling in one expression,
    // then the clamp, then the pixel grid.
    let scale = title.RasterizationScale()?.max(1.0);
    let ideal = band / 2.0 - width / 2.0;
    // DOES IT FIT AT ALL? On a window narrow enough, or under a menu wide
    // enough, the span between the headers is smaller than the title's own
    // floor — a `TextBlock` will ellipsize down to one "…" and no further,
    // and `MaxWidth` cannot take it below that. Measured on the menus scene
    // at 540 DIP: a 9 DIP slot and a 19.5 DIP ellipsis.
    let fits = width < available;
    let x = if fits {
        ideal.max(span0).min(span1 - width)
    } else {
        // NOTHING TO CENTRE, SO CHOOSE WHICH SIDE OVERFLOWS. The right edge
        // is pinned its 8 DIP clear of the commands and the overflow goes
        // LEFT, into the control's own left-header padding column, which is
        // empty — where overflowing right would put an ellipsis under a
        // button. Written as one branch rather than as `max(span0)` followed
        // by `min(span1 - width)`, which silently produces this same number
        // by having the second clamp undo the first.
        span1 - width
    };
    // SNAPPED TO A WHOLE PHYSICAL PIXEL, and that is what keeps the
    // correction below a one-step move instead of a feedback loop. XAML
    // arranges on the pixel grid (`UseLayoutRounding`), so an off-grid
    // target would be rounded by the layout and re-corrected by the next
    // pass, forever.
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
    // THE POST-CONDITION SAYS NOTHING ABOUT A TITLE THAT DOES NOT FIT, and
    // that is the honesty rule rather than a convenience. Below its own
    // floor the title's arranged width is no longer the width its box was
    // given, so `origin + width / 2` is not the centre of anything this
    // code chose, and an assertion about it would be an assertion about the
    // font's ellipsis metrics. Measured before it was gated: the menus
    // scene, whose menu leaves a 9 DIP slot, aborted five legs on a 4 DIP
    // disagreement that no aim could have removed.
    if fits && previous == Some(aim) {
        // Every input is what the previous pass measured, so the
        // arrangement in front of us is that pass's margin, arranged. It
        // is the only moment at which the achieved centre can honestly be
        // compared with the asked-for one.
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

/// The shell Grid's rows, named because two functions have to agree
/// about them and a bare `1` in each is how they stop agreeing.
///
/// THE TITLEBAR IS THE TOP ROW, not a strip under the caption. That is
/// the 2026-08-17 revision in one line: the promoted commands ride IN
/// the caption row (the Files/Terminal/Settings shell), so the row that
/// holds them has to be above the MenuBar and flush with the top of the
/// window, which is what `ExtendsContentIntoTitleBar` makes available.
const TITLEBAR_ROW: i32 = 0;
const MENUBAR_ROW: i32 = 1;
const TOOLBAR_CONTENT_ROW: i32 = 2;

/// The window's PROMOTED actions, in catalog preorder — the promotion
/// list, computed from the model.
///
/// `action` items only, and `primary` is the whole rule: this is the
/// same filter every other backend's promotion applies (the mac arm's
/// `kayaPromotedActions`, the GTK arm's `promoted_items`), because
/// uniform binding semantics is a statement about what an app declares,
/// not about what each host's chrome happens to be able to draw.
///
/// NO CAPACITY *k* IS APPLIED HERE, and that is measured rather than
/// chosen: a WinUI `CommandBar` has DYNAMIC OVERFLOW ON BY DEFAULT — it
/// moves primary commands into its own "…" menu at width breakpoints
/// (docs/chrome-plan.md C2's WinUI row) — so the number of buttons this
/// window can show is a question the platform answers per resize.
/// Trimming the list here would be kaya answering it once, wrongly,
/// with a constant. The phones apply a k because their bars have none.
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

/// THE PROMOTION (docs/chrome-plan.md C2's WinUI row): the window's
/// primary catalog actions as real `AppBarButton`s in its `CommandBar`,
/// appended to `PrimaryCommands` in catalog preorder — and the bar rides
/// IN THE WINDOW'S CAPTION ROW, not in a strip below it.
///
/// THE 2026-08-17 REVISION, and it is a mount-point decision, nothing
/// else. The first lowering hung the stock `CommandBar` in its own Auto
/// row under the MenuBar; the capture
/// (`scratchpad/chrome/cap-toolbar-windows.png`) showed what the
/// research already implied — a sparse third strip with a standard
/// caption above it is not the shell Windows 11 ships. Files, Terminal
/// and Settings MERGE the command surface into the title bar, and the
/// research's own §5 named the move exactly: "on Windows the genre is
/// decided by the bar's PARENT, not by a style on the bar. The same
/// `CommandBar` object, moved from row 0 of the shell Grid into the
/// title bar, becomes the Files-app look." So the SAME object moved,
/// and no knob was added anywhere: `Microsoft.UI.Xaml.Controls.TitleBar`
/// (WASDK 1.7+, Microsoft's recommended custom-caption path per
/// `Window.SetTitleBar`'s own remarks) goes in the shell's top row, the
/// bar goes in its `RightHeader`, and `Window.ExtendsContentIntoTitleBar`
/// makes the row the real caption.
///
/// EXTENDED IS DERIVED FROM TOOLBAR PRESENCE — the ledger's rule, and
/// the reason this branch is inside `refresh_toolbar` and nowhere else.
/// A window whose catalog promotes nothing never reaches here past the
/// early return, never mints a `TitleBar`, never has
/// `ExtendsContentIntoTitleBar` written, and keeps precisely the
/// standard system caption it had before this slice. There is no app
/// surface for "extended" and no knob to set: promoting an action is the
/// whole declaration.
///
/// ONE BAND, which is the 2026-08-17 revision's second half. The window
/// wears exactly one horizontal band of chrome and everything the app
/// declared is in it: the MENU migrates out of its own row into
/// `LeftHeader` (`rehost_menubar`), the title is the control's own, the
/// commands are right in `RightHeader`. The menu's row is left empty, and
/// an empty Auto row measures zero — so "the separate menu row is
/// deleted" is a fact about the geometry and not only about the picture.
///
/// THE HEIGHT IS DERIVED, AND NOW BOTH HALVES OF THE BAND ARE TOLD.
/// `TitleBar::UpdateHeight` goes to the compact state (32px) when
/// Content, LeftHeader and RightHeader are ALL null and to the expanded
/// state (48px) otherwise (microsoft-ui-xaml @ winui3/release/2.2.0,
/// `src/controls/dev/TitleBar/TitleBar.cpp:493`, heights from
/// `TitleBar_themeresources.xaml:77-78`). Filling the slots is what makes
/// the caption tall, and kaya still writes no height on the control.
///
/// BUT THE CONTROL DOES NOT TELL THE WINDOW, and that omission is what
/// the first version of this arm shipped: the XAML band went to 48 while
/// the system's caption buttons stayed in their standard 32 band, so two
/// runs of buttons shared one row with their centres 9 DIP apart. That is
/// upstream microsoft-ui-xaml#9863, and the app-side answer is
/// `AppWindowTitleBar.PreferredHeightOption` — written here as `Tall`
/// exactly when this window's caption is extended and `Standard` when the
/// promotion empties. Same derivation `ExtendsContentIntoTitleBar`
/// follows, both directions, same path, no knob, no app surface.
///
/// WHAT KAYA WRITES IS THE LIST, THE BAND, AND NOTHING ELSE. The
/// transparent bar that takes the window's own surface, the 20px→16px
/// icon rescaling, the "…" affordance, the dynamic overflow at width
/// breakpoints, the label hidden while the bar is closed and re-laid
/// beside the icon in the overflow — every one of those is still the
/// default of having the control (measured against the pinned WinUI 2.2.1
/// metadata and the 2.2.0 theme resources, scratchpad/chrome/
/// toolbar-winui.md §3). The one metric written per button is
/// `CAPTION_COMMAND_CELL`; that constant carries why a 68px toolbar cell
/// is the wrong cell in a caption band and where 48 comes from. Restyling
/// the platform's control to the platform's OWN caption metrics is
/// lowering fidelity, not a styling knob — it is the difference between
/// commands that are part of the caption and commands dropped onto it.
///
/// THE DRAG REGIONS ARE THE CONTROL'S JOB, and the reason to use the
/// control at all: C1's recorded failure mode for a custom caption is
/// "a window nobody can drag". `TitleBar` computes the passthrough rects
/// itself — `UpdateInteractableElementsList` collects the back button,
/// the pane toggle, the Content subtree and THE RIGHT HEADER AREA WHOLE
/// (TitleBar.cpp:798-806), and `UpdateDragRegion` hands them to
/// `InputNonClientPointerSource` — so the bar's slot is clickable and
/// everything left of it drags the window.
///
/// `AutoRefreshDragRegions` IS SET AND IS NOT SUFFICIENT ALONE, which is
/// measured in the control's source rather than assumed: the automatic
/// refresh subscribes to `Content()`'s `LayoutUpdated` and only that
/// (TitleBar.cpp:603-606, and :843-849 on re-subscribe), so a bar living
/// in `RightHeader` gets no automatic recompute when its own width
/// changes — which it does on every catalog rebuild, as buttons come and
/// go. `RecomputeDragRegions()` is therefore called at the end of every
/// rebuild below; it forces a synchronous layout first, so the rects it
/// publishes are the ones the bar actually occupies.
///
/// SECONDARY COMMANDS STAY EMPTY, and that is this backend's one
/// deviation from the research's shape — the same deviation, for the
/// same reason, that the GTK arm records. `SecondaryCommands` was to be
/// the catalog remainder's home; this window already has exactly one,
/// because `rebuild_menus` renders THE WHOLE CATALOG into a real
/// `MenuBar` one row above (`ensure_menu_shell`). Filling the overflow
/// with those same rows would be a second copy of them, 48px below
/// their own menu bar. So the remainder's home is `menubar`, read from
/// the real bar by `toolbar_remainder_home` rather than asserted.
///
/// NO SECOND KEYBOARD ACCELERATOR, and this is the one hazard the
/// research named that a lowering can walk into by being thorough:
/// `attach_accelerator` already installs the chord on the item's
/// `MenuFlyoutItem`, and a second `KeyboardAccelerator` on a second
/// element is a SECOND HANDLER for one key. The button therefore takes
/// no accelerator at all. (WinUI's dress-only property for drawing the
/// chord text on a command is `KeyboardAcceleratorTextOverride`, which
/// takes a rendered string like "Ctrl+S"; kaya has no such renderer —
/// `accelerator_chord` maps the canonical spelling to enums — so
/// nothing is written there rather than a guess being formatted.)
fn refresh_toolbar(core: &mut CoreState, window: u64) -> windows_core::Result<()> {
    let promoted = promoted_items(core, window);
    if promoted.is_empty() && !core.toolbars.contains_key(&window) {
        // A window that never promotes anything never mints a bar, so
        // its tree is exactly what it was before this slice.
        return Ok(());
    }
    let bar = match core.toolbars.get(&window) {
        Some(bar) => bar.clone(),
        None => {
            // AT MINT, NOT AT FIRST LAYOUT: a CommandBar whose template
            // cannot resolve its theme keys fail-fasts the process on a
            // dispatcher tick, milliseconds after the step that caused
            // it (docs/traps.md; the wall's own docstring records the
            // dump this cost when MenuBarItem did it). CommandBar,
            // AppBarButton and TitleBar are the same shape of control as
            // the ones already on that list — MUX types whose default
            // styles live in the framework dictionary the merge brings
            // in.
            require_control_resources("this window promotes an action into its toolbar");
            // EXTENDED IS DERIVED FROM TOOLBAR PRESENCE, and this is the
            // wall that says so on a path nobody can avoid — every
            // caption this backend ever mints runs this line.
            //
            // IT IS HERE BECAUSE NOTHING ELSE CATCHES IT, measured: with
            // the early return above deleted, every menu-bearing window
            // takes an extended caption it never asked for, and
            // `commands_rust`, `todos_rust`, `clipboard_rust`,
            // `undo_rust`, `window_rust`, `styling_rust` and
            // `toolbar_rust` ALL PASSED — seven green legs over a window
            // wearing chrome no app declared. No harness verb reads
            // "is this caption extended" (there is no such concept on
            // the other four backends, so there is no uniform read to
            // add), so the shared scenes structurally cannot see it.
            //
            // The assertion is what a scene would have said if it could:
            // a window whose catalog promotes nothing has no business
            // owning a custom title bar.
            assert!(
                !promoted.is_empty(),
                "kaya: winui: window {window} reached the caption mint with \
                 an EMPTY promotion list. `extended` is derived from toolbar \
                 presence (docs/chrome-plan.md C2's WinUI row): a window that \
                 promotes nothing keeps the system caption, and minting a \
                 TitleBar here would give it chrome no app declared."
            );
            let Some(shell) = core.menu_shells.get(&window).cloned() else {
                // No shell means no menubar_append has run, and the
                // promotion bit only ever reaches items that are in a
                // window's catalog — so there is nothing to promote and
                // nowhere to put it.
                return Ok(());
            };
            let target = winui_window(core, window)?;

            // THE TITLE IS NOT WRITTEN HERE, and the control's own
            // `Title` property is never written at all. A caption
            // composed in two places is the five-writer defect
            // docs/dirty-plan.md D2 was written about, and a filled
            // `Title` makes the control one of the writers (see
            // refresh_caption). The mint puts an EMPTY TextBlock in the
            // centre slot and the ONE writer fills it, below, on this
            // rebuild and on every later one.
            let titlebar = mint_caption_titlebar()?;
            let tb_el: FrameworkElement = titlebar.cast()?;
            Grid::SetRow(&tb_el, TITLEBAR_ROW)?;
            shell.Children()?.Append(&titlebar.cast::<UIElement>()?)?;

            // THE CAPTION TEXT, in the control's centre slot, wearing the
            // control's own caption type. `CaptionTextBlockStyle` is the
            // key `PART_TitleText` itself uses (`TitleBar-v220.xaml:238`),
            // so the title is the platform's caption type at the
            // platform's caption size — no font, no size, no colour
            // chosen here.
            let caption_text = caption_title_text()?;
            titlebar.SetContent(&caption_text.cast::<UIElement>()?)?;
            core.window_caption_texts.insert(window, caption_text);

            // THE TITLE CENTRES ON THE WINDOW, and this is the hook that
            // keeps it there — see `center_caption_title` for why
            // `LayoutUpdated` is the one event that cannot miss a reason
            // the geometry moved.
            //
            // A WEAK REFERENCE, for two reasons that both bite. A strong
            // one would be a cycle — the control holds the delegate and
            // the delegate would hold the control — and this backend's
            // delegates are not tracked by XAML's reference tracker, so
            // the caption of every closed window would leak. And
            // `EventHandler::new` demands `Send`, which a projected XAML
            // interface is not and `Weak` is.
            //
            // IT TOUCHES NO CORE STATE, deliberately, and the rule is the
            // one the text-range thread-locals at the top of this file
            // record: a layout callback that borrowed `CORE` would abort
            // the process the first time it fired inside `refresh_toolbar`
            // — which holds that borrow while it calls
            // `RecomputeDragRegions`, and that forces a synchronous
            // layout. A `TitleBar` can be asked for its own headers and
            // its own content, so the callback needs nothing else.
            let weak_titlebar = titlebar.downgrade()?;
            let recentre = EventHandler::<windows_core::IInspectable>::new(move |_, _| {
                match weak_titlebar.upgrade() {
                    Some(titlebar) => {
                        center_caption_title(window, &titlebar)?;
                        // The armed post-condition, fired on the first pass
                        // that has something arranged to measure. Costs one
                        // bool test on every other pass.
                        if CAPTION_GEOMETRY_ARMED.get() && assert_caption_command_geometry(&titlebar)? {
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
            // title bar, you must first set ExtendsContentIntoTitleBar
            // to true… If ExtendsContentIntoTitleBar is false, the call
            // to SetTitleBar does not have any effect."
            // (Window.SetTitleBar remarks, windows-app-sdk-2.0). Swap
            // these two lines and the window silently keeps its system
            // caption with a second one drawn under it.
            target.SetExtendsContentIntoTitleBar(true)?;
            target.SetTitleBar(&tb_el)?;

            core.window_titlebars.insert(window, titlebar);
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
        // THE CAPTION CELL. The only metric this arm writes, and it is
        // written because the button's own default is a metric for a
        // different place — see CAPTION_COMMAND_CELL. Everything else
        // about the button, including its height, comes from the closed
        // CommandBar it sits in.
        button.SetWidth(CAPTION_COMMAND_CELL)?;
        // THE CAPTION CELL'S OTHER HALF, and the second metric this arm
        // writes: the height the button's OWN template is laid out for,
        // read out of the theme dictionary. See
        // CAPTION_COMMAND_BUTTON_BOX_KEY for why a 48 DIP row makes a
        // 64 DIP button draw its hover visual across its own icon, and
        // why the CommandBar's own clip is what keeps the extra 16 out
        // of the client area.
        button.SetHeight(caption_command_button_box()?)?;
        // THE LABEL IS THE BUTTON'S NAME, not decoration: a closed
        // CommandBar draws icons only (it overwrites each button's
        // IsCompact as it opens and closes), so `Label` is what the
        // overflow row shows and what the button publishes to UIA — the
        // sentence a Narrator user hears, and the address
        // `expect_toolbar_item "Save"` resolves through.
        button.SetLabel(&HSTRING::from(&*label))?;
        apply_symbol(&button, symbol)?;
        button.SetIsEnabled(enabled)?;
        let attachment = MenuAttachment::Window(window);
        let handler = RoutedEventHandler::new(move |_, _| {
            // ONE DISPATCH PATH (the module's echo doctrine): a toolbar
            // click is the same activation a menu click is, so it lands
            // in the same function and emits the same occurrence.
            menu_user_activate(id, attachment);
            Ok(())
        });
        button.Click(&handler)?;
        primary.Append(&button.cast::<ICommandBarElement>()?)?;
        core.toolbar_buttons.insert((window, id), button);
    }
    // An emptied promotion list leaves the bar in the tree with nothing
    // in it; a CommandBar with no commands still measures 48px, so it
    // is collapsed instead — and so is the caption row it rides in, and
    // the window goes back to the system caption. THE WHOLE EXTENDED
    // STATE FOLLOWS THE ONE NUMBER, in both directions, because
    // "extended is derived from toolbar presence" has to be as true on
    // the way down as on the way up.
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
        // recomputation for no reason. Written only when it moves.
        if target.ExtendsContentIntoTitleBar()? != extended {
            target.SetExtendsContentIntoTitleBar(extended)?;
        }
        // THE SYSTEM'S HALF OF THE BAND, derived from the same number.
        // The XAML control sizes itself; the caption BUTTONS are the
        // window's, and this is the only thing that moves them. Read
        // before write for the same reason as the line above.
        let caption = target.AppWindow()?.TitleBar()?;
        let wanted = if extended {
            TitleBarHeightOption::Tall
        } else {
            TitleBarHeightOption::Standard
        };
        if caption.PreferredHeightOption()? != wanted {
            caption.SetPreferredHeightOption(wanted)?;
        }
        // ONE BAND: the menu rides in the caption exactly while there is
        // a caption to ride in, and goes back to its own row when the
        // promotion empties. Before RecomputeDragRegions, deliberately —
        // the move changes LeftHeader's extent, and the rects published
        // below have to be the ones the bar ends up occupying.
        rehost_menubar(core, window, extended)?;
        // ARM THE GEOMETRY POST-CONDITION. It cannot run here: this
        // rebuild may be the one that puts the bar in the tree, so there
        // is nothing arranged yet to measure. The caption's own
        // LayoutUpdated fires it on the first pass that has.
        CAPTION_GEOMETRY_ARMED.set(true);
        // The bar's width just changed and it lives in RightHeader,
        // which the control's automatic refresh does not watch (see the
        // doc comment). Without this the passthrough rects describe the
        // PREVIOUS set of buttons: the window would still drag, and the
        // buttons under the stale hole would be the wrong ones. The menu
        // has the same problem for the same reason — the control watches
        // `Content`'s LayoutUpdated and neither header's.
        titlebar.RecomputeDragRegions()?;
        // THE ONE CAPTION WRITER FILLS THE CONTROL'S TITLE, here and on
        // every rebuild. Idempotent by construction (it derives the
        // whole caption from state), so a rebuild that changed only the
        // button set rewrites the same string and the control's own
        // `appWindow.Title` write is a no-op.
        refresh_caption(core, window)?;
    }
    Ok(())
}

/// THE MENU'S PARENT IS DERIVED, exactly like the caption it moves into.
/// A window that promotes an action wears ONE band, and the menu is part
/// of it: the same `MenuBar` object leaves its shell row and becomes the
/// caption's `LeftHeader`. When the promotion empties, it goes back. A
/// window that never promotes has no caption control to migrate into and
/// never leaves the row — which is "extended is derived from toolbar
/// presence" read from the menu's side.
///
/// THE SAME OBJECT MOVES, which is the whole reason this is a mount-point
/// change and not a rebuild. Every harness read of the menus — the item
/// walk, `expect_menu`, the enablement reads — goes through
/// `core.menubars`, and that map still holds the bar it always held. A
/// menu that was rebuilt into a different control would have to prove all
/// of that again; a menu that changed parents proves it by being the same
/// pointer.
///
/// XAML REFUSES RE-PARENTING AND DOES NOT WARN. Appending an element that
/// still has a parent takes a non-unwinding panic through the XAML layer
/// and ABORTS THE PROCESS (`release_split`'s docstring records the same
/// trap from the split arm). So each direction detaches before it
/// attaches, and the state is read off the tree rather than tracked
/// beside it — `IndexOf` on the shell's own children is the question
/// "where is this bar right now", and a bookkeeping bool would be a
/// second answer that can disagree.
///
/// THE MENU STAYS CLICKABLE IN THE CAPTION, and that is not a hope:
/// `TitleBar::UpdateInteractableElementsList` pushes the whole
/// `PART_LeftHeaderPresenter` area onto the passthrough list whenever
/// `LeftHeader()` is non-null (microsoft-ui-xaml @ winui3/release/2.2.0,
/// `src/controls/dev/TitleBar/TitleBar.cpp:849-858`), and
/// `UpdateDragRegion` hands those rects to `InputNonClientPointerSource`.
/// The rects are only as fresh as the last recompute, which is why the
/// caller does this move BEFORE `RecomputeDragRegions`. Proved by
/// clicking, not by reading: the menus legs open `File` in the caption.
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
    // A window with no caption control has nowhere else to put it. This
    // is the shape EVERY non-promoting window has, so it is a branch and
    // not an assumption.
    let in_caption = in_caption && titlebar.is_some();
    match (in_caption, in_row, titlebar) {
        (true, true, Some(titlebar)) => {
            children.RemoveAt(at)?;
            titlebar.SetLeftHeader(&bar_el)?;
        }
        (false, false, titlebar) => {
            if let Some(titlebar) = titlebar {
                titlebar.SetLeftHeader(None::<&UIElement>)?;
            }
            Grid::SetRow(&bar_fe, MENUBAR_ROW)?;
            children.Append(&bar_el)?;
        }
        // Already where it belongs. Idempotent because this runs on
        // EVERY catalog rebuild, and a move that re-ran would detach and
        // re-attach a live control for nothing.
        _ => {}
    }

    // THE POST-CONDITION, AND IT IS A WALL BECAUSE NOTHING ELSE IS ONE.
    // MEASURED, not feared: with `SetLeftHeader` deleted from the arm
    // above — one substitution, printed and asserted — the bar is
    // detached from its row and attached to nothing, the window shows NO
    // MENU AT ALL, and `menus_rust` PASSED (2s).
    //
    // The reason is structural and worth stating where the next reader
    // will be: every menu question this backend answers goes through
    // `core.menubars` (the bar OBJECT) or `core.menu_natives` (the item
    // objects). `menu_presentation` asks the bar how many Items it
    // holds; `menu_state` asks a MenuFlyoutItem for its flag; activation
    // invokes that same item. Not one of them asks whether the bar is in
    // a TREE, and no harness verb could ask it uniformly — the question
    // "where does this window's menu live" has no answer on the other
    // four backends. So the shared scenes structurally cannot see this,
    // exactly as they could not see an unearned extended caption
    // (`refresh_toolbar`'s mint carries that sibling assertion), and the
    // check goes here, on the path every promoted window runs.
    let wanted_here: Option<windows_core::IUnknown> = titlebar
        .and_then(|titlebar| titlebar.LeftHeader().ok())
        .and_then(|hosted| hosted.cast::<windows_core::IUnknown>().ok());
    let in_caption_now = wanted_here == Some(bar.cast::<windows_core::IUnknown>()?);
    let in_row_now = children.IndexOf(&bar_el, &mut at)?;
    assert!(
        in_caption_now == in_caption && in_row_now == !in_caption,
        "kaya: winui: window {window}'s MenuBar ended a rebuild somewhere \
         other than where the one-band derivation puts it. Wanted {}; \
         found caption={in_caption_now} row={in_row_now}. A promoted \
         window's menu rides in its TitleBar's LeftHeader and every other \
         window's rides in the shell's MENUBAR_ROW; a bar in NEITHER is \
         invisible, and no scene can say so — the menu reads walk \
         core.menubars and core.menu_natives, which answer the same \
         whether or not the bar is in a tree.",
        if in_caption {
            "the caption's LeftHeader"
        } else {
            "the shell's menu row"
        }
    );
    Ok(())
}

/// What the window's REAL toolbar holds: how many items are in it, and
/// the addressable buttons among them with the name each one publishes
/// to UIA.
///
/// WALKED FROM THE BAR'S OWN COLLECTIONS, never from `toolbar_buttons`:
/// the question every toolbar verb asks is whether the promotion reached
/// the chrome, and kaya's own map answers "yes" whether or not it did.
/// BOTH collections are walked because the button object is the same
/// object wherever it sits (the measured freebie in C2's WinUI row) — so
/// a reading that looked only at `PrimaryCommands` would go blind the
/// day this backend fills the overflow.
///
/// NOTE WHAT THIS CANNOT SEE, and it is the honest limit of a CommandBar
/// read: dynamic overflow moves a primary command into the "…" menu at a
/// width breakpoint WITHOUT moving it between collections (it flips the
/// button's `IsInOverflow`), so "in the chrome" here means in the bar's
/// command list — which is what `expect_toolbar`'s invariant is about —
/// and never "wide enough to be showing right now", which is the
/// platform's business and changes with the user's window size.
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
                // An item that is not a button — a separator, say — is
                // an item the chrome holds and not one this read can
                // address. Counted, not named.
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
/// `MenuBar` with real items in it (`rebuild_menus` puts the WHOLE
/// catalog there). `none` the moment that stops being true, which is the
/// answer that would fail the step rather than quietly claiming a home
/// the window does not have.
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
/// bar at every toolbar step. The mac arm's probe, one platform over —
/// it is how the two questions this arm could not answer by reading the
/// framework's closed sources were settled (what an `AppBarButton`
/// publishes as its UIA name with `Label` set and `Content` null, and
/// which enablement surface a disable actually moves). Kept, because the
/// next reader will have the same two questions.
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
/// shell's slot when the window carries a bar, straight onto the
/// Window otherwise. Keeps the mount/nav/sections paths one mechanism.
/// The window's client width in DIP, read from the WINDOW rather than
/// from whatever element currently occupies it.
///
/// This started out reading `Content().XamlRoot().Size()`, which is
/// what menu_presentation does — and that is safe there because the
/// menu arm never REPLACES the content. The list-detail arm does
/// exactly that, so measuring the content to decide what the content
/// should be is circular: the trace showed `measured` alternating
/// between Some(900.0) and None as the tree was swapped underneath the
/// reading.
///
/// The mechanism is DOCUMENTED, not a quirk: a UIElement's XamlRoot is
/// null until it is parented into a live tree, and returns its
/// parent's once it is. So an element mid-reparent legitimately has no
/// XamlRoot, and anything measuring through it reads null exactly when
/// the arm needs an answer. GetClientRect answers about the WINDOW —
/// what a size class is a property of — and is available before XAML
/// has laid anything out.
/// What to do with the live file dialog: read it back, or drive it.
#[cfg(feature = "harness")]
/// Is the Shell's file dialog on screen? Plain Win32, no COM.
///
/// THE GONE-CHECK MUST NOT WALK THE DIALOG. `choose_file` presses Open
/// and then asks whether the dialog left, and asking that through UI
/// Automation means enumerating a tree that is being torn down at that
/// exact moment: uiautomationcore raises RPC_E_DISCONNECTED, COM
/// surfaces it as a STRUCTURED EXCEPTION rather than a failed HRESULT,
/// and the JVM's process-wide handler turns that into a FATAL error
/// report. The java leg died there while the other four merely raced
/// unseen — the same event, escalated by one runtime and swallowed by
/// the rest.
///
/// Existence is a window question, so it is asked of the window
/// manager. EnumWindows cannot fault on a dead provider because it
/// never speaks to one.
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
///
/// WHY THERE IS ANYTHING TO ANSWER: `FOS_OVERWRITEPROMPT` is in the save
/// dialog's DEFAULT options (measured `0x880a`) and this backend keeps it,
/// because clearing it would make Windows the only platform that replaces
/// a file without asking. Unanswered, `Show()` NEVER RETURNS — the
/// apartment thread stays in its nested modal loop, `file_save` reports
/// "the dialog is still up" twenty seconds later, and the leg's real
/// failure is invisible behind that.
///
/// FOUND BY IDENTITY, NOT BY CAPTION AND NOT BY SHAPE. Measured
/// (scratchpad/save-probe-windows.md §B.3): the prompt is a SECOND
/// top-level `#32770` whose 17 descendants are a `DirectUIHWND` plus
/// `CtrlNotifySink`-wrapped Buttons **with id 0** — so no id lookup finds
/// anything and `dialog_control` is useless here. Matching its caption
/// ("Confirm Save As") would make the answer stop working on a Windows
/// that speaks anything else; matching its shape would risk taking the
/// SAVE DIALOG for the prompt mid-teardown and pressing an unknown
/// button. The caller already knows which window it pressed Save on, so
/// the prompt is simply "the other one".
///
/// THE FIRST VISIBLE BUTTON, and the failure mode of guessing wrong is the
/// safe one: measured enumeration order is `"&Yes"` then `"&No"`, and
/// pressing No CANCELS the save — the destination never arrives and the
/// leg fails loudly — rather than overwriting something quietly.
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
    // scene cannot reach here (it saves to a name in a per-pid directory
    // nobody has made), so a log line is the only thing that distinguishes
    // "the prompt never came up" from "the answer did nothing".
    eprintln!(
        "kaya: answered the save dialog's overwrite prompt {:?} with {:?}",
        window_text(hunt.found),
        window_text(press.found)
    );
    unsafe { PostMessageW(press.found, BM_CLICK, 0, 0) };
}

/// ASK THE LIVE DIALOG WHAT IT IS SHOWING, then wait briefly for its own
/// thread to answer. Every dialog observation goes through here, so the
/// two readers differ only in which variant they accept.
///
/// The bounded wait is not the assertion's: `expect_file_dialog` and
/// `expect_save_dialog` are themselves retries, so a slow first sample
/// costs one more lap rather than a failure.
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
/// interfaces rather than through UI Automation.
///
/// UIA IS THE THING THAT MUST NOT HAPPEN, and moving the client out of
/// process could never have fixed it, because the fault is on the
/// PROVIDER side — inside this process. Measured stack, bottom up:
/// USER32 dispatches a message, DirectUI (DUI70) handles it, and while
/// handling it uiautomationcore raises an automation event to whatever
/// client has attached, which needs an outgoing COM call. Windows
/// refuses one from a thread dispatching an input-synchronous call and
/// raises RPC_E_CANTCALLOUT_ININPUTSYNCCALL (0x8001010d) — flagged
/// NONCONTINUABLE, so no handler may dismiss it. COM catches it and
/// carries on; four runtimes never notice; HotSpot's vectored exception
/// handler on windows-aarch64 sees the same first-chance event and
/// reports a fatal error. So MERELY ATTACHING A UIA CLIENT makes this
/// dialog fatal to a JVM, and nothing on the client side can help —
/// which is why a helper process was built, measured, and thrown away.
///
/// The dialog is ours, created in this process, so the shell will
/// simply say what its view holds: IServiceProvider ->
/// SID_STopLevelBrowser -> IShellBrowser -> the active IShellView ->
/// IFolderView -> its items. No automation client, no WM_GETOBJECT, no
/// event notifications, no exception.
///
/// SAMPLED ON THE DIALOG'S OWN THREAD, because the dialog is an STA
/// object and belongs to the thread that created it. The harness thread
/// posts a request to a message-only window living on that thread and
/// reads the answer out of a mutex; nothing crosses an apartment.
#[cfg(feature = "harness")]
mod sampler {
    use std::sync::Mutex;

    /// The message-only window on the dialog's thread, 0 when no dialog
    /// is up.
    pub(crate) static WINDOW: std::sync::atomic::AtomicIsize =
        std::sync::atomic::AtomicIsize::new(0);

    /// WHICH DIALOG THIS SAMPLE CAME OFF, carried in the type rather
    /// than left to the reader to assume.
    ///
    /// One process may have one live file dialog (capi::file_dialog_shown
    /// panics on a second) and this backend has one sampler window, so
    /// the picker's reader and the save dialog's reader share a slot. A
    /// pair of strings would have let either read the other's answer —
    /// `expect_file_dialog` would find a save dialog's directory with an
    /// empty row list and merely say "wanted these rows", and
    /// `expect_save_dialog` would take a picker's directory and its first
    /// row as a name. The variant makes each reader's `None` mean "no
    /// dialog OF MINE is live", which is what both callers already do
    /// with it. Same rule the mac arm spells as two computed panel
    /// readers asking the TYPE of one slot.
    #[derive(Clone)]
    pub(crate) enum Sampled {
        /// A picker: the directory it is browsing, and every row its view
        /// is displaying.
        Open(String, Vec<String>),
        /// A save dialog: the directory it is browsing, and the text
        /// currently in its file-name box. NEVER ROWS — a save dialog's
        /// browser is not what the scene reads, and the platform whose
        /// save panel publishes none at all is the reason the observation
        /// is shaped this way in every backend (harness.rs,
        /// Stage::save_dialog_state).
        Save(String, String),
    }

    /// The last sample. Cleared when a dialog opens, so a stale answer
    /// can never satisfy an assertion about a new one.
    pub(crate) static VIEW: Mutex<Option<Sampled>> = Mutex::new(None);
    /// WM_APP: "sample now". pub(crate) and not pub: cbindgen scrapes
    /// public constants into the C header regardless of the privacy of
    /// the module holding them, and this is an internal detail of one
    /// backend rather than part of the ABI.
    pub(crate) const SAMPLE: u32 = 0x8000;
}

/// A shell-allocated wide string, read and RELEASED. Every `PWSTR` the
/// Shell answers with is CoTaskMemAlloc'd and belongs to the caller, and
/// these reads sit inside a poll — an assertion samples the dialog tens
/// of times — so the release is per-sample rather than per-dialog.
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
        // PARENTRELATIVEFORUI is WHAT THE USER SEES, which is what
        // every other backend reports and what the shared scene
        // compares byte for byte. It honours Explorer's HideFileExt,
        // so the deploy still has to set that to 0 — the same guard
        // as before, for the same reason.
        rows.push(take_pwstr(unsafe {
            item.GetDisplayName(SIGDN_PARENTRELATIVEFORUI)?
        })?);
    }
    Ok(sampler::Sampled::Open(directory, rows))
}

/// The save dialog's observation: where it is browsing, and THE NAME IT
/// WOULD SAVE UNDER.
///
/// `IFileDialog::GetFileName` and not the file-name Edit's text, though
/// both were on the table and the control is right there (id 1001, class
/// `Edit`, measured — scratchpad/save-probe-windows.md §B.3). Reading the
/// control would mean `WM_GETTEXT`, whose lParam is a POINTER: only
/// `SendMessage` marshals one, and a send is what puts the receiving
/// thread into the input-synchronous call that makes this dialog fatal to
/// a JVM (see `sample_folder_view`). The send would be safe HERE, from
/// the dialog's own thread, and that is exactly the kind of "safe in this
/// one caller" reasoning that stops being true when someone moves the
/// call. The Shell's own accessor asks no id and sends no message.
///
/// IT IS A LIVE READ, not the echo of `SetFileName` — the leg is the
/// proof: `file_dialog_name final` types over the suggested `copy` with
/// posted `WM_CHAR`s, and the very next step asserts the field reads
/// `final`. Posted messages leave a thread's queue in the order they
/// entered it, so the characters are dispatched before the SAMPLE that
/// follows them, and a stale accessor would fail that assertion with
/// `save dialog names "copy", wanted "final"`.
#[cfg(feature = "harness")]
fn sample_save_state(
    dialog: &windows::Win32::UI::Shell::IFileSaveDialog,
) -> windows_core::Result<sampler::Sampled> {
    let directory = sample_folder(dialog)?;
    let name = take_pwstr(unsafe { dialog.GetFileName()? })?;
    Ok(sampler::Sampled::Save(directory, name))
}

/// Sample whichever dialog is live, on ITS thread. A failed read leaves
/// the previous answer alone rather than publishing a half one: the
/// callers poll, and `open_sampler` is what clears the slot.
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

/// A control of the dialog by its classic id and class. The ids were
/// confirmed against the real dialog by tools/win/dialogprobe rather
/// than taken from documentation: 1 is Open, 2 is Cancel, and 1148 is
/// the file-name box, which is an Edit inside a ComboBoxEx32 that
/// shares its id.
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
/// The SAVE dialog's file-name box, and it is a DIFFERENT CONTROL — not
/// the same id in a different place. Measured in one session against both
/// dialogs (scratchpad/save-probe-windows.md §B.3): the save dialog has no
/// id 1148 at all, and `dialog_control(dialog, 1148, "Edit")` answers
/// nothing, which is a SILENT no-op rather than an error. Its box is id
/// 1001, class `Edit` — and the class half of the lookup is load-bearing
/// here, because id 1001 is ALSO the address bar (`ToolbarWindow32`) in
/// both dialogs.
#[cfg(feature = "harness")]
const ID_SAVE_FILENAME: i32 = 1001;
#[cfg(feature = "harness")]
const WM_CHAR: u32 = 0x0102;
#[cfg(feature = "harness")]
const EM_SETSEL: u32 = 0x00B1;
#[cfg(feature = "harness")]
const BM_CLICK: u32 = 0x00F5;

/// The WNDCLASSW the sampler window registers. Hand-declared beside
/// the user32 calls this file already names, rather than by enabling
/// Win32_UI_WindowsAndMessaging for one struct.
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
/// It lives on the DIALOG'S thread, because that is the only thread
/// allowed to touch an STA object, and it is a window rather than a
/// channel because that thread is inside a modal Show() loop — a loop
/// that pumps the thread's queue and so dispatches to this window
/// without knowing anything about it. Nothing here crosses an
/// apartment, which is the entire point.
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

/// The dialog the sampler is holding, and WHICH KIND IT IS. The two are
/// separate COM interfaces — `IFileOpenDialog` and `IFileSaveDialog`,
/// siblings under `IFileDialog` rather than one deriving from the other,
/// so unlike AppKit's panels there is no single type to hold and ask
/// about later.
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
    // any one dialog and that is fine.
    unsafe { RegisterClassW(&wc) };
    // HWND_MESSAGE is -3: no screen presence, no z-order, nothing but a
    // queue endpoint.
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

/// Show the Shell's common item dialog and return (name, path) per
/// file. Runs on the dialog apartment's thread; see `dialog_apartment`.
///
/// The empty vector IS cancel: Show() answers ERROR_CANCELLED, which is
/// not an error condition to report but the platform's way of saying the
/// selection was empty.
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
        // WHICH CALL FAILED, not merely that one did: a bare
        // "The parameter is incorrect" from a chain of six COM calls
        // names nothing, and the first run cost a deploy cycle to learn
        // that much.
        let mut stage = "CoCreateInstance";
        let result = (|| -> windows_core::Result<()> {
            let dialog: IFileOpenDialog =
                CoCreateInstance(&FileOpenDialog, None, CLSCTX_INPROC_SERVER)?;

            stage = "GetOptions";
            let mut options = dialog.GetOptions()?;
            // FORCEFILESYSTEM keeps the answer to things that HAVE a
            // path: the design hands back a capability the guest opens
            // with its own file API, and a virtual shell item has
            // nothing to open.
            options |= FOS_FORCEFILESYSTEM;
            if multiple {
                options |= FOS_ALLOWMULTISELECT;
            }
            stage = "SetOptions";
            dialog.SetOptions(options)?;

            // ADVISORY on every platform (DESIGN.md): a default view,
            // never a guarantee. The HSTRINGs must outlive SetFileTypes,
            // which borrows their pointers.
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

            // The armed directory, applied HERE because that is the only
            // moment it is read.
            if let Some(dir) = folder {
                let wide = HSTRING::from(dir);
                stage = "SHCreateItemFromParsingName";
                let item: IShellItem =
                    SHCreateItemFromParsingName(windows_core::PCWSTR(wide.as_ptr()), None)?;
                stage = "SetFolder";
            dialog.SetFolder(&item)?;
            }

            // The sampler lives exactly as long as the modal loop:
            // stood up immediately before Show, taken down the instant
            // it returns (below, outside this closure, because cancel
            // leaves through the `?`).
            #[cfg(feature = "harness")]
            open_sampler(LiveDialog::Open(dialog.clone()));

            stage = "Show";
            // NO OWNER, and that is not laziness. Show() disables its
            // owner and waits on the owner's input queue, and this runs
            // on a thread that is not the UI thread — so passing the
            // app window blocks inside Show() before the dialog is ever
            // created. Measured: the thread entered Show and never
            // returned, and UI Automation reported no #32770 anywhere on
            // the desktop.
            //
            // Modality is not lost by this. kaya already allows exactly
            // one live file dialog per process (capi::file_dialog_shown
            // panics on a second), which is the guarantee the vocabulary
            // actually makes.
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
        // OUTSIDE THE CLOSURE, because Show() answers cancel with an
        // Err that leaves it early — a teardown inside would run on the
        // happy path only, and the harness would go on posting into a
        // queue nobody pumps.
        #[cfg(feature = "harness")]
        close_sampler();
        // A cancelled dialog returns ERROR_CANCELLED from Show(); the
        // empty vector already says that, so nothing is logged for it.
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
/// pointed at, or nothing for cancel. Runs on the dialog apartment's
/// thread, exactly as the picker does.
///
/// `IFileSaveDialog` AND NOT `FileSavePicker`, measured
/// (scratchpad/save-probe-windows.md §B.1) rather than assumed, and the
/// first charge is the one that decides it: the WinRT picker's
/// `SetSuggestedStartLocation` takes a `PickerLocationId` — an ENUM of
/// well-known folders — so it cannot be aimed at `<temp>/kaya-save-<pid>`
/// at all, which is precisely the charge `PresentFileDialog` already
/// records against `FileOpenPicker`. Three more: a non-packaged desktop
/// app must hand it an owner HWND; the documentation says the
/// `Windows.Storage.Pickers` APIs "don't work when apps run as
/// administrator", and every leg on this lane runs `schtasks /rl highest`;
/// and it is async, so it wants a pump on the STA rather than the blocking
/// modal `Show()` this thread already runs. Microsoft's own documented
/// remedy for a desktop app is the call sequence below.
///
/// IT CREATES NOTHING, measured three times with three names:
/// `exists_after_show=false` every one. So the path handed back names a
/// file that is not there, and the ONE thing that will ever create it is
/// the core's `SaveDestination::open` (docs/save-plan.md D1). This
/// function must not "help" by touching the file system — Android and iOS
/// hand back a document that exists, mac/linux/windows hand back a name,
/// and the core is where those two are made one behaviour.
///
/// THE OVERWRITE PROMPT STAYS ON. `FOS_OVERWRITEPROMPT` is in the save
/// dialog's default options (measured: `0x880a`), and clearing it would
/// make Windows the one platform that replaces a file without asking —
/// NSSavePanel prompts too. What that costs is a second window the harness
/// has to answer, and `Stage::confirm_save` answers it; leaving it
/// unanswered does not fail, it WEDGES, because `Show()` never returns.
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
        // WHICH CALL FAILED, not merely that one did — the picker's rule,
        // and it cost a deploy cycle there.
        let mut stage = "CoCreateInstance";
        let result = (|| -> windows_core::Result<()> {
            let dialog: IFileSaveDialog =
                CoCreateInstance(&FileSaveDialog, None, CLSCTX_INPROC_SERVER)?;

            stage = "GetOptions";
            let mut options = dialog.GetOptions()?;
            // FORCEFILESYSTEM for the picker's reason: the guest is handed
            // a capability it opens with its own file API, and a virtual
            // shell item has no path to open. The defaults this ORs into
            // (OVERWRITEPROMPT, NOREADONLYRETURN, PATHMUSTEXIST,
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
                // THE SAME EXTENSION RULE THE OTHER DESKTOP HAS. With
                // `allowedContentTypes` set, NSSavePanel completes an
                // extension-less name with the first allowed extension;
                // SetDefaultExtension is how this platform spells that, so
                // a filtered save answers the same shape of name on both
                // (measured: typing `bare` under a `txt` filter answers
                // `bare.txt`). Only under a filter — with none there is no
                // extension to be the default, and the shared scene sends
                // none for exactly that reason (docs/save-plan.md, and
                // scratchpad/save-depth.md §8: a completed name would be
                // read back by `expect_save_dialog` on one platform and
                // not another).
                stage = "SetDefaultExtension";
                dialog.SetDefaultExtension(&HSTRING::from(filters[0].1.as_str()))?;
            }

            // THE NAME THE DIALOG OPENS WITH — advisory, like the filters:
            // the user renames it, and the guest reads back the name it
            // GOT rather than the one it asked for.
            stage = "SetFileName";
            dialog.SetFileName(&HSTRING::from(suggested_name))?;

            // The armed directory, applied HERE because that is the only
            // moment it is read.
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
            // NO OWNER, and for the measured reason at `file_dialog_show`:
            // Show() waits on its owner's input queue, and this is not the
            // UI thread, so passing the app window blocks before the
            // dialog is ever created. One live file dialog per process is
            // the guarantee kaya actually makes.
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

/// How many times the Shell has been caught calling into an apartment
/// this process had already closed. THE HARNESS FAILS THE SCENE ON A
/// NON-ZERO COUNT (see `Stage::finish`).
///
/// It is a count and not a print because the failure it names is
/// SILENT IN FOUR LANGUAGES OUT OF FIVE. Measured 2026-08-03 on the
/// windows lane, per-dialog apartments, 5 runs each with this handler
/// armed: rust raised 0x80010108 on 2 of 5 runs and PASSED all five;
/// java raised it on 3 of 5 and died on exactly those three. Only the
/// JVM notices, because its top-level filter reports any exception
/// code as a fatal VM error even on a thread it does not own — so
/// leaving the detection to a runtime's temperament leaves it to luck.
static COM_DISCONNECTS: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
/// KAYA_WINUI_SEH_PROBE: also name every COM/RPC first-chance code and
/// the thread it landed on, for the next investigation.
static PROBE_VERBOSE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// A VECTORED handler is the only place in this process that can see
/// these: they run ahead of every frame-based `__except`, and the one
/// that matters here is swallowed by combase before any other code
/// gets a look. It decides nothing — always EXCEPTION_CONTINUE_SEARCH
/// — it only counts.
unsafe extern "system" fn seh_probe(info: *mut ExceptionPointers) -> i32 {
    use std::sync::atomic::Ordering::Relaxed;
    const CONTINUE_SEARCH: i32 = 0;
    const RPC_E_DISCONNECTED: u32 = 0x8001_0108;
    let code = unsafe { (*(*info).record).code };
    if code == RPC_E_DISCONNECTED {
        COM_DISCONNECTS.fetch_add(1, Relaxed);
    }
    // FACILITY_RPC's HRESULT range. C++ throws (0xE06D7363) and the
    // loader's own breakpoints are noise for this question. Printing
    // is opt-in: a handler that takes stderr's lock runs on threads
    // this process does not own.
    if PROBE_VERBOSE.load(Relaxed) && code & 0xFFFF_0000 == 0x8001_0000 {
        eprintln!(
            "kaya: first-chance COM exception {code:#010x} on thread {}",
            unsafe { GetCurrentThreadId() }
        );
    }
    CONTINUE_SEARCH
}

/// Armed for every harness build, because that is the build being
/// TESTED and the guard is worthless if someone has to remember it. A
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

/// WHICH DIALOG, and everything that differs between the two. The
/// picker's `multiple` and the save dialog's `suggested_name` are each
/// meaningless to the other, so they sit in the variant rather than
/// beside a flag: a save request PHYSICALLY CANNOT carry "name two
/// destinations", which is the same guarantee `kaya_emit_save_dialog_result`
/// makes on the answering side by taking ONE locator rather than an array
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
/// AN EVENT AND NOT A POSTED MESSAGE, for two reasons. Posting needs
/// the thread's id, so the caller would have to WAIT for the thread to
/// come up — on the UI thread, inside apply, which is the one place
/// this backend must never block (the app-thread stall detector exists
/// for exactly that). And a thread message is discarded by any modal
/// loop that dispatches it, which is what a picker runs. An auto-reset
/// event needs nobody to exist yet and cannot be swallowed: signalled
/// before the wait, it satisfies the wait immediately.
static DIALOG_DOORBELL: OnceLock<isize> = OnceLock::new();

fn dialog_doorbell() -> isize {
    *DIALOG_DOORBELL
        .get_or_init(|| unsafe { CreateEventW(std::ptr::null(), 0, 0, std::ptr::null()) })
}

/// The ONE STA the pickers live in, for the life of the process.
///
/// WHY IT IS SHARED AND NEVER TORN DOWN, measured 2026-08-03 on the
/// windows lane. A thread per dialog called CoUninitialize the moment
/// Show() returned, and CoUninitialize "forces all RPC connections on
/// the thread to close" — its own documentation, which also says it
/// belongs "on application shutdown, as the last call made to the COM
/// library". The Shell's own workers are still calling back into this
/// apartment at that moment (comdlg32 -> combase -> RPCRT4 ->
/// RaiseException), so RPCRT4 raised RPC_E_DISCONNECTED (0x80010108)
/// on a thread nobody in this process owns. Every runtime absorbed it
/// but the JVM, whose top-level filter reports ANY exception code as a
/// fatal VM error even on a thread it does not own: filedialog_java
/// passed 2 of 10 while filedialog_rust passed 10 of 10 ON THE SAME
/// BUILD, which is why this read as flake for the four milestones it
/// shipped in.
///
/// THE GRACE PERIOD WAS MEASURED AND REJECTED. Keeping the per-dialog
/// thread pumping before the uninit, java, 15 runs each: 5ms -> 13/15
/// (both failures carried exactly one 0x80010108), 50ms -> 15/15,
/// 250ms -> 15/15. So the safe margin is somewhere under 50ms on an
/// idle 6-core VM and unknown anywhere else — a race won by margin,
/// not a fix. This shape has no race to win: with no CoUninitialize
/// there is no forced disconnect, and the same 15 runs raised zero
/// COM first-chance exceptions of any kind.
///
/// Nor is it a kaya invention. A real app's picker runs on a thread
/// whose apartment outlives it by the whole session; Chromium gives
/// its shell dialogs a dedicated COM STA task runner rather than a
/// thread per dialog.
///
/// It PUMPS while idle rather than blocking on the queue, because
/// those same Shell workers reach into this apartment by posting to
/// it; a thread that owns an STA and does not dispatch is a thread
/// other people's calls hang on.
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
                // NO CoUninitialize ANYWHERE BELOW, deliberately, and
                // no way out of this loop: the apartment ends with the
                // process. That is the whole fix.
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
/// ONE ANSWERING PATH FOR BOTH, and that is docs/save-plan.md D2 landing
/// here: the save dialog answers on the picker's result grammar, so the
/// occurrence, the live slot and the retire gate are the picker's and only
/// the request differed. What is NOT shared is the source each registers,
/// and that is the whole of D1 on this platform — a picked file exists, a
/// destination does not, so the picker registers a `PathSource` (whose
/// open would answer ERROR_FILE_NOT_FOUND for a file the dialog just
/// named) and the save dialog registers a `SaveDestination` (whose open
/// creates). The backend hands over the locator UNCHANGED and creates
/// nothing itself.
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
    // Cancel is the EMPTY LIST, faithfully: Show() returns
    // ERROR_CANCELLED and no platform can confirm an empty selection,
    // so there is no sentinel to invent (DESIGN.md, File dialogs). The
    // save dialog spells the same thing as `Option::None`, which is why
    // its arm above iterates an Option rather than a Vec.
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

/// Show or hide the covered entry's back bar according to the CONTROL's
/// mode.
///
/// The back affordance belongs to an entry that is covering something.
/// TwoPaneView is what decides whether the detail covers the list or
/// sits beside it, so the affordance follows its Mode rather than a
/// width kaya measured for itself. Called once when the arm builds the
/// view and again from ModeChanged, because Mode is settled during
/// layout and not before.
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
/// A UIElement lives in exactly ONE Children collection, and appending
/// a parented one does not warn the way GTK does — it takes a
/// non-unwinding panic through the XAML layer and ABORTS the process.
/// The split Grid is the only container that keeps a root outside the
/// window's own content path, so emptying it is the whole job.
fn release_split(core: &mut CoreState, window: u64) -> windows_core::Result<()> {
    if let Some(view) = core.split_views.remove(&window) {
        // TwoPaneView holds its panes as PROPERTIES, not in a Children
        // collection, so emptying it means nulling both. Same reason as
        // before: a UIElement lives in exactly one parent, and handing a
        // still-parented one to the next view aborts the process.
        view.SetPane1(None::<&UIElement>)?;
        view.SetPane2(None::<&UIElement>)?;
    }
    Ok(())
}

/// Let go of whatever the WINDOW itself is currently showing. The
/// split Grid is not the only holder: on the FIRST split render the
/// base root is still the window's own content, and appending it to
/// the Grid then fails with "Element is already the child of another
/// element" — which arrives as a non-unwinding panic and takes the
/// process with it.
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

/// One real MenuFlyout per context anchor, set as the element's
/// ContextFlyout (the platform's own right-click route); its items
/// rebuild from the attached roots with the catalog.
fn ensure_context_flyout(core: &mut CoreState, widget: u64) -> windows_core::Result<()> {
    if core.context_flyouts.contains_key(&widget) {
        return Ok(());
    }
    // At ATTACH, not at first show: a flyout whose styles are missing
    // dies on the user's first right-click, and "it crashes when a user
    // does the thing" is the failure mode this whole guard exists to
    // stop being the first report.
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
/// `primary`/`shift`/`alt` order, one key) onto the accelerator
/// enums. `primary` = Control on Windows. The same key table feeds
/// the verb's keybd_event injection, so matching is by construction.
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

/// One closed key floor (DESIGN.md, Menus) onto Windows.System
/// VirtualKey values. `escape` never arrives — the root rejects every
/// spelling of it.
fn virtual_key(name: &str) -> Option<VirtualKey> {
    match name {
        "enter" => return Some(VirtualKey(0x0D)),
        "delete" => return Some(VirtualKey(0x2E)),
        "left" => return Some(VirtualKey(0x25)),
        "up" => return Some(VirtualKey(0x26)),
        "right" => return Some(VirtualKey(0x27)),
        "down" => return Some(VirtualKey(0x28)),
        // The punctuation set onto the OEM keys. VK_OEM_* are defined
        // by POSITION on the US layout, which is exactly what the
        // canonical names denote.
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

/// Rebuild every window bar and context flyout from the model — which
/// IS the post-user mirror, so a rebuild forced by an unrelated prop
/// write preserves the user's toggle/radio state (docs/traps.md). Also
/// re-derives the shortcut table. Coalesced per drain (menus_touched).
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
            // NO SYMBOL HERE, AND IT IS THE PLATFORM'S GAP, NOT AN
            // OVERSIGHT: MenuBarItem has no Icon slot in the pinned
            // metadata (Title and Items, 243 members, no Icon), so a
            // symbol declared on a top-level grouping cannot be drawn
            // on this host. It is dropped rather than approximated, and
            // `menu_symbol` reports exactly that for a bar path instead
            // of the "no icon" that would blame the app.
            // A bar-level radio_group is a top-level menu whose
            // options use the checkmark idiom — the same inline
            // materialization, one level up (the mac segment's shape).
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
        // Every LEAF command may carry a chord — a checkable item and
        // one option of a group as readily as a plain action. This
        // table also GATES the shortcut verb, so a kind missing here is
        // a chord the harness silently never presses.
        if !m.shortcut.is_empty() && m.kind.takes_shortcut() {
            core.menu_shortcuts.insert(m.shortcut.clone(), id);
        }
    }
    // THE TOOLBAR REBUILDS WITH THE CATALOG, from the same mirror and in
    // the same pass: `primary`, `label`, `symbol` and `enabled` all
    // arrive as prop writes that set `menus_touched`, and every
    // structural mutation lands here too, so this is the one place that
    // sees them all (docs/chrome-plan.md C2: the promotion is recomputed
    // on every catalog mutation).
    let shells: Vec<u64> = core.menu_shells.keys().copied().collect();
    for window in shells {
        refresh_toolbar(core, window)?;
    }
    // The rebuild stamped STRUCTURAL enablement alone onto the fresh
    // natives, which would un-gray a role item whose clipboard half
    // says no — the role factor goes back on top.
    if core.roles_armed {
        refresh_role_enablement(core);
    }
    Ok(())
}

/// Materialize one child list into a flyout item vector, 1:1 per the
/// ratified lowering. Every leaf's Click routes to the shared
/// dispatch carrying ITS OWN attachment — the noun resolves from
/// that anchor at dispatch time (the SwiftUI parity rule), so no
/// rebuild order can cross the stamped copies' nouns. Every native
/// is stamped with the inherited AND of enablement and keyed under
/// its attachment.
/// Attach a chord to a native item — every LEAF command may carry one
/// (a checkable item and one option of a group as readily as a plain
/// action). The accelerator is DRESS, not dispatch: WinUI draws the
/// chord text beside the item from it, and the key hook above eats the
/// keystroke before any default action of it can run (see The chord
/// route for the measurement that moved dispatch there).
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
    // The default action is a UI Automation pattern lookup — Invoke,
    // else Toggle, else Selection — and it is dead code from this
    // backend's side now: the hook consumes the key first, so the
    // lookup never runs. It is recorded because it is what the split
    // route rested on, and what a future reader tempted to hand chords
    // back to XAML would have to re-establish.
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
                // The checkable kind takes an icon like any other leaf,
                // because in WinUI 3 it descends from MenuFlyoutItem
                // (see the IconSlot impl list) — the UWP class it is
                // usually confused with has no slot at all.
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
                // Inline with the platform's checkmark idiom: the
                // options join the enclosing vector directly
                // (RadioMenuFlyoutItem.GroupName per radio group);
                // the GROUP mints no chrome of its own here.
                for (index, &option) in children.iter().enumerate() {
                    // EACH OPTION'S OWN symbol, never the group's: the
                    // group mints no chrome here, so there is nothing
                    // for its symbol to ride, and reusing it would put
                    // one concept on every option.
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
// EVERY chord this catalog owns dispatches from here. The hook is
// THREAD-scoped (never global): it watches this UI thread's key-downs,
// matches the canonical spelling against the same catalog table the
// verb gates on, performs the state change the platform would have
// performed, and consumes only a chord this catalog owns — so the
// accelerator route cannot double-fire behind it.
//
// It used to serve ONE kind. ToggleMenuFlyoutItem is the one leaf kind
// whose KeyboardAccelerator WinUI never matches: measured on the VM,
// with the chord genuinely injected, a plain command's accelerator
// fires (Invoke pattern), one option of a group fires (SelectionItem
// pattern), and a checkable command's does nothing — not the pattern,
// not an explicit Invoked handler, not a copy on the MenuBar or on the
// content Grid, and not a collapsed companion item. So the checkable
// kind came here and the other two rode the platform.
//
// THAT SPLIT WAS A RACE, and what it raced was how far behind the UI
// thread had fallen — which is exactly what the chord BEFORE it put
// there. Measured 2026-08-03, commands scene, one leg 16 times: the
// group-option chord (primary+2, the accelerator route) landed 67ms
// and 81ms after the preceding chord's activation in the two runs that
// passed, and within 42ms in all fourteen that failed. Failed means
// LOST, not late: no Click, no occurrence, and nothing for the
// harness's five seconds of polling to find, while the same chord
// fires normally seconds later. The hook saw every one of those
// keystrokes and resolved every one against menu_shortcuts — right
// item, right kind, modifiers correct at message-retrieval time — so
// the chord was always in the window and only the platform's dispatch
// of it went missing. A scene that presses one chord, waits for its
// occurrence and presses the next walks into that window by
// construction, which is why it read as an intermittent WinUI-only
// failure of the step AFTER a menu mutation.
//
// The whole point of this route is that it does not depend on XAML's
// input pipeline having caught up: the message-time key state is read
// as the message is retrieved, and the answer comes from kaya's own
// table. The accelerators stay attached for the chord TEXT WinUI draws
// beside each item, which is all they are now for.
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
                // A disabled item is INERT, exactly as native chrome
                // leaves it — the chord is still this catalog's, so it
                // is eaten rather than sprayed at whatever is behind.
                //
                // WHICH IS WHY THE UNDO ROUTING LIVES ON THIS PATH
                // (docs/undo-plan.md §1.1, measured on a TextBox and
                // true of either editable): a focused field never sees
                // Ctrl+Z once this catalog owns the chord —
                // the hook returns 1 and the WM_KEYDOWN never reaches
                // XAML — so native text undo would die in every field of
                // the app if dispatch alone happened here. It does not:
                // `menu_user_activate` below performs the undo role, and
                // that role ASKS THE FOCUSED FIELD FIRST
                // (perform_undo_role -> undo_route -> CanUndo). The
                // eaten chord is answered by the same tier the key would
                // have reached, plus the ledger the key could not.
                if enabled {
                    // The native owns the immediate user change, exactly
                    // as it does for a click; menu_user_activate mirrors
                    // from it and emits. EXHAUSTIVE over the kind: a new
                    // leaf kind that may carry a chord fails to COMPILE
                    // here rather than reaching a catch-all that leaves
                    // its chord dispatching nothing.
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
                            // One option of a group: checking it is what
                            // the platform's own Select() does, and the
                            // shared GroupName clears the sibling.
                            MenuItemKind::RadioOption => {
                                if let Some(MenuNative::Option(native)) = native {
                                    native.SetIsChecked(true)?;
                                }
                            }
                            // A plain command owns no state of its own.
                            MenuItemKind::Action => {}
                            // Not leaf kinds: menu_shortcuts holds only
                            // what takes_shortcut admits, and the rebuild
                            // is the one writer.
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

/// THE user dispatch path: chrome clicks, the KeyboardAccelerator
/// route, and harness verbs all land here. Fires from the message
/// loop, never under an apply borrow. Mirrors FIRST (the
/// post-user-mirror rule), then emits with the item's identity and
/// the noun of the attachment whose copy fired — resolved HERE, at
/// dispatch, from that anchor (the SwiftUI parity rule: the keys ARE
/// the noun, so the noun can only come from the copy's own anchor).
/// Disabled items — the inherited AND — stay inert, exactly as
/// native chrome leaves them.
fn menu_user_activate(item: u64, attachment: MenuAttachment) {
    CORE.with_borrow_mut(|core| {
        let Some(core) = core.as_mut() else { return };
        // Echo doctrine belt: no programmatic write path raises Click
        // on these controls (the MENU PROBE verifies), but if one
        // ever did, the apply guard keeps it quiet.
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
        // intersection half lives on the native's IsEnabled, which
        // this route does not consult — so it is recomputed here, the
        // same freshness rule the harness activation applies (the mac
        // finding, docs/clipboard-plan.md §3).
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
                // A GESTURE ROLE PERFORMS RATHER THAN REPORTS: the item
                // is the platform's own command acting on the focused
                // widget, so no menu occurrence goes up (the rule every
                // arm shares; DESIGN.md — gestures are commands).
                //
                // UNDO FIRST, and not by accident: an undo is not a
                // clipboard command (the mac arm splits the same two
                // functions the same way), and this is the ONE dispatch
                // both the chord hook and the harness activation reach,
                // so the routing cannot be true on one path and absent
                // on the other.
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
                // The native control owns the immediate user change
                // (it flipped IsChecked before raising Click): mirror
                // from the REAL control first — the firing copy's own
                // native, by its attachment key — then emit; a later
                // rebuild starts from this mirror (docs/traps.md).
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
                // Re-selecting the selected option is not a change and
                // emits nothing, exactly as the platform's own change
                // route behaves (the choice contract).
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
            // Grouping nodes and separators have no activation; native
            // chrome opens or ignores them.
            _ => {}
        }
    });
}

/// The harness's REAL invoke route (the ContentDialog precedent): the
/// item's automation peer, cast to the provider pattern it exposes —
/// Invoke for plain/radio items, Toggle for toggle items. The peer
/// pipeline runs the control's own OnInvoke, which raises the same
/// Click a pointer press does. Grouping chrome has no activation.
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


/// The PREMISE the peer-invoke route rests on, checked once per process
/// — not flag-gated, because a silent change here is a dead harness
/// activation or a checkmark that never moves.
///
/// [`invoke_menu_native`] asks an item's automation peer for Invoke
/// FIRST and falls back to Toggle, which is the platform's own
/// priority. `MenuFlyoutItem` has Invoke, so a plain command activates
/// through it; `ToggleMenuFlyoutItem` does NOT, so a checkable command
/// reaches Toggle and its checkmark moves. A future WinUI that changed
/// either answer would silently reroute the harness's activation — an
/// item that cannot be invoked at all, or a toggle invoked instead of
/// toggled — so the premise fails loudly here rather than as a scene
/// that stopped observing anything.
///
/// The CHORD route no longer rests on any of this: every chord this
/// catalog owns dispatches from the thread key hook and is consumed
/// there, so no accelerator's default action runs (see The chord
/// route).
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

/// KAYA_WINUI_MENU_PROBE: the flag-gated instrument (the
/// KAYA_WINUI_NAV_PROBE pattern) answering this backend's two menu
/// behavior questions in-band, on detached canary items:
/// (1) echo doctrine — programmatic IsChecked writes must not raise
/// Click; (2) the peer-invoke route must raise Click on an item whose
/// flyout has never opened (the bar-activation mechanism). Runs once,
/// at the first rebuild.
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

// ---------------------------------------------------------------------
// Clipboard (DESIGN.md, Clipboard; docs/clipboard-plan.md §6 for what
// this platform was measured to charge — tools/win/clipprobe).
//
// CLASSIC WIN32, DELIBERATELY. WinRT DataTransfer's SetContent is
// documented to work "only when the application is in the foreground",
// which a matrix leg cannot promise; its custom-format bridge to Win32
// atoms is documented only in the read direction; and its content dies
// with the process unless flushed. Classic SetClipboardData has none
// of those charges — measured: five formats set in one open outlive
// the setter's exit and read back byte-exact through stock PowerShell,
// and RegisterClipboardFormatW carries the ratified slashed custom id
// VERBATIM (atom name reads back "dev.kaya/note").
//
// Reads are synchronous pulls here, so "answered exactly once" needs
// no async bridge on this backend: the arm chooses the richest
// offered∩accepted format off the ENUMERATED offer and reads it in
// one open.
// ---------------------------------------------------------------------

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

/// One format's bytes, inside an already-open clipboard. GlobalSize
/// may exceed the written length (the allocator rounds up), so
/// self-delimiting formats must trust their own delimiters; a custom
/// format's bytes are whatever the allocation says, which is the
/// platform's own grammar for them.
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

/// CF_UNICODETEXT and nothing else, with the clipboard opened and
/// closed around it — the read behind the textarea's plain-text paste
/// pin (`Editable::paste_from_clipboard`, `pin_plain_text`).
///
/// NOT `materialize_clipboard`, deliberately: that one answers the
/// RICHEST representation an accept list takes, and this is the path
/// for a widget that declared no accept list at all, where the platform
/// itself would have inserted. What TextBox inserts there is plain
/// text, so this is what the textarea inserts too.
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
            // The lf boundary, same as every other read here: clipboard
            // text is CRLF by Windows convention and the control
            // re-normalizes on the way in.
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

/// CF_HTML with 10-digit fixed-width offsets. Fixed width is what
/// makes the header length a CONSTANT rather than a fixpoint; pad
/// while computing but print unpadded and every offset is silently
/// short. Microsoft's own doc example is arithmetically wrong (its
/// fragment offsets mix two relative bases) — this construction is
/// verified byte-exact against a worked example and round-trips
/// through PresentationCore's own reader (tools/win/clipprobe).
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

/// The read side's equal and opposite parser: kaya's html
/// representation is the raw fragment, so a CF_HTML payload — whose
/// header kaya may not have written — is sliced by its own
/// StartFragment/EndFragment BYTE offsets. Proven against a foreign
/// header with different padding than ours (PowerShell 5.1's -AsHtml
/// pads to 9 digits with trailing spaces; digits-then-stop parses
/// both).
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
        // An ANSI list is legal but nothing modern writes one; a
        // foreign ANSI writer would surface here as an empty answer
        // rather than mojibake.
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

/// Choose the RICHEST representation the clipboard offers that the
/// accept list takes, read exactly that one, and answer — None for no
/// intersection, the universal no. Shared by the privileged read and
/// the declared-paste delivery, because the two differ in their
/// trigger and never in what they can materialize. Descending clip
/// value — custom (accept-list order), files, image, html, text — the
/// canonical order (§1).
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
                    // The picker's capability arriving through the
                    // second door: the same registration the file
                    // dialog result makes, so kaya_open_picked
                    // redeems a pasted file identically.
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
                // The lf boundary: clipboard text is CRLF by Windows
                // convention, guest strings are LF everywhere.
                R::Text(lf(String::from_utf16_lossy(&units)))
            });
        }
        None
    })();
    unsafe { windows::Win32::System::DataExchange::CloseClipboard()? };
    Ok(answer)
}

/// The focused editable widget, if any: the root admits `accepts` on
/// entries and textareas alone (scene.rs), and each control IS its own
/// focus target here — no GtkText delegation to walk.
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

/// RICH-CAPABLE CONTROL, PLAIN-TEXT CONTRACT — the pins, in one place,
/// with their read-back (docs/textarea-foundation-plan.md).
///
/// The textarea's control can express attributed runs, which is why the
/// ranges milestone can be cheap; it must express NONE of them today.
/// RichEditBox's defaults are the opposite of what kaya wants — measured
/// on the VM before this was written — so each one is set, and each one
/// is READ BACK:
///
/// - `ClipboardCopyFormat` defaults to `AllFormats`, so a copy out of a
///   kaya textarea would put RTF on the clipboard beside the text and a
///   paste in would take formatting. `PlainText` is the entry's
///   behaviour, which TextBox has no way not to have.
/// - `DisabledFormattingAccelerators` defaults to `None`, which does
///   NOT mean "no accelerators" — it means none are disabled, so
///   Ctrl+B/I/U actively bold, italicize and underline the user's text
///   inside a kaya textarea. `All` is the pin; the chords then either
///   reach kaya's own keyboard hook (where a menu carries them) or do
///   nothing at all.
/// - The control's OWN paste routes — Ctrl+V and its context menu —
///   bypass every kaya path, so the `Paste` event is cancelled and kaya
///   inserts the clipboard's plain text itself. `ClipboardCopyFormat`
///   governs the COPY side only; without this handler, RTF still
///   arrives by the two doors the user has.
///
/// THE READ-BACK IS THE GUARD, and it is deliberately a panic on a path
/// nobody can avoid: every scene that builds a textarea runs this line.
/// A pin someone deletes — or one a future App SDK refuses — fails the
/// FIRST textarea leg with a sentence, rather than shipping a control
/// with opinions kaya never agreed to. That is the failure mode this
/// milestone is named after.
///
/// Two more pins are not properties and live at their chokepoints
/// instead: the read's `TextGetOptions::AdjustCrlf` (`Editable::text`,
/// watched by the textarea scene itself) and the write's
/// `TextSetOptions::None` (`Editable::set_text` — `FormatRtf` in that
/// slot renders a guest's `{\rtf1`-shaped string as a document).
///
/// SPELL-CHECK AND TEXT PREDICTION ARE NOT PINNED, on purpose. Both
/// controls carry `IsSpellCheckEnabled` and `IsTextPredictionEnabled`
/// with the same defaults (measured: True on both), so they are not
/// opinions the swap introduces — they are the entry's existing
/// behaviour, and turning them off HERE would be the divergence.
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
        // Then paste what the entry would have pasted. INLINE, and
        // through a range rather than through the live selection — see
        // `selection_range`, whose measurement started right here.
        //
        // The swallow counter is deliberately not bumped: a paste acts
        // like the user, and the control's TextChanged is the report
        // (the same rule the role's paste arm states).
        pasting.paste_from_clipboard()
    });
    field.Paste(&paste_handler)?;

    // AND NOW ASK THE CONTROL WHAT IT ACTUALLY HAS.
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

/// D7/A1's clear, in this platform's one available spelling.
///
/// MEASURED A NO-OP ON THE ENTRY, AND CALLED ANYWAY (§1.1, re-verified
/// by the undo arm's probe: CanUndo true -> SetText -> false -> explicit
/// clear -> false). Setting `TextBox.Text` resets the control's undo
/// buffer by itself, so D7's semantics already hold on Windows before
/// any code is added. NOT MEASURED ON THE TEXTAREA'S RichEditBox, whose
/// undo stack is the RichEdit engine's rather than the XAML control's —
/// which is precisely why the call is not skipped anywhere: this is the
/// lever that makes the rule hold whether or not the write happens to.
/// The call costs one COM hop on a path that already crosses COM, it
/// makes the uniform rule visible and greppable beside GTK's
/// begin/end_irreversible_action and Compose's undoState.clearHistory(),
/// and it is the ONLY lever left if a future WinUI stops resetting on
/// the Text setter — WinUI 3 having already dropped WPF's
/// IsUndoEnabled, which had exactly these semantics (A5). A guard that
/// is redundant today is cheap; finding out later that the redundancy
/// was carrying the rule is not.
///
/// A3 IS THE CALLER'S: every call site sits inside a text-DIFFERS
/// branch, because an app that mirrors a field into a signal and writes
/// it back would otherwise lose the user's native history on every
/// keystroke.
fn clear_native_undo(field: &Editable) {
    if let Err(e) = field.clear_undo_redo_history() {
        eprintln!("kaya: winui ClearUndoRedoHistory failed: {}", e.message());
    }
}

// ---- Text ranges (docs/ranges-plan.md D1-D5) ------------------------
//
// The three primitives on the one widget that can carry them. TextBox
// cannot express a decorated run AT ALL — no document object, no
// per-range formatting, one selection and one selection colour, proved
// twice by the probe (the complete 120-method metadata surface and live
// reflection agreed) — which is why the textarea foundation moved to
// RichEditBox and why these arms are cheap now.
//
// OFFSETS ARRIVE NATIVE AND ARE NEVER CONVERTED HERE. An `ApplyOp`
// carries a `NativeRange`, which the core built by converting UTF-8 byte
// offsets into THIS backend's unit against the text it validated them
// on; Rich Edit's character positions are UTF-16 code units, so a lowered
// range is used as it stands. The only offset arithmetic in this file is
// in the READING direction, where the harness's spelling is defined in
// the protocol's byte offsets (`range_spelling` below).
//
// AND THE LINE BREAK DOES NOT MOVE THEM, which is the fact worth writing
// down because its GTK sibling is the opposite. A Rich Edit story stores
// every line break as a single CR where kaya's text has a single LF, so
// the counts agree 1:1 and `lf()` shifts nothing. (GTK's buffer stores a
// pasted CRLF as two characters and every range after one lands early.)

/// The background a declared range wears. Rich Edit's background is
/// opaque — `ITextCharacterFormat` has no alpha channel of its own —
/// so this is the flattened equivalent of the mac arm's 55%-yellow over
/// white rather than a second opinion about what a highlight looks like.
const HIGHLIGHT_BACKGROUND: bindings::Windows::UI::Color = bindings::Windows::UI::Color {
    A: 255,
    R: 255,
    G: 241,
    B: 143,
};

/// The textarea behind a widget id, or None if this id is not one.
///
/// TEXTAREA ONLY, and the core already refused anything else at the one
/// chokepoint (scene.rs: "text ranges are a TEXTAREA surface"), so this
/// answering None means the widget vanished between the transaction and
/// its apply — the same race every other arm here tolerates.
fn textarea_by_id(core: &CoreState, id: u64) -> Option<RichEditBox> {
    core.textarea_ids
        .iter()
        .position(|&t| t == id)
        .map(|i| core.textareas[i].clone())
}

/// One background write: get the range, take its format COPY, set the
/// colour, assign the copy back. Four COM hops, and the round trip is
/// not optional — `ITextRange::CharacterFormat` hands out a snapshot,
/// so a colour set on it changes nothing until it is assigned.
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
/// character formatting on this control (measured, range-probe-windows.md
/// §5: new text takes the ambient format, and a probe that painted eight
/// characters red ended up with an 80,513-pixel red document after one
/// re-set). The clear is one range write and the batch pays for it.
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
    // Batched unconditionally: measured 2.2x faster per range (96µs ->
    // 44µs) and it keeps the clear below from being a visible flash of
    // undecorated text before the new set lands.
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
    // ALWAYS, even on the failure above: an unmatched
    // BatchDisplayUpdates leaves the control's rendering suspended for
    // the rest of the process, which would turn one failed paint into a
    // window that stops updating at all.
    doc.ApplyDisplayUpdates()?;
    painted
}

/// D2, ENFORCED WHERE THE EDIT ARRIVES. Called from the textarea's
/// TextChanged BEFORE the swallow test, so it sees every edit whatever
/// its origin — a keystroke, a paste, kaya's own write, a native undo.
///
/// The compare is against the recorded text, never against the event:
/// see HIGHLIGHT_TEXT for why that distinction is the whole design.
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
///
/// THE READ GOES TO THE DOCUMENT MODEL, not to kaya's bookkeeping, and
/// that is the difference between a test and a tautology: delete the
/// paint and this answers `""` while HIGHLIGHT_TEXT still remembers
/// everything. It is NOT the accessibility tree, which is what the mac
/// arm reads and what this arm would prefer — WinUI's in-process
/// automation peer for a text control publishes no Text pattern at all
/// (`RichEditBoxAutomationPeer` declares exactly one interface in the
/// SDK metadata, and live reflection agreed: `GetPattern(Text)` is
/// NULL), and the only route that does publish it is an out-of-process
/// UIA CLIENT, which is the file-dialog era's crash class and is barred
/// at the Cargo.toml. So this reads the layer underneath: Rich Edit's
/// own model of what it is rendering.
///
/// A run is "painted" when its background is not the platform's own
/// `AutoColor` sentinel — the value an untouched run carries — rather
/// than when it matches kaya's colour, so a clear that wrote the WRONG
/// colour reads as still-painted instead of silently passing.
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

/// WHERE A RANGE SITS IN THE DOCUMENT: its top and bottom edge, in the
/// same units the control's ScrollViewer counts.
///
/// `ITextRange::GetRect` NAMES ITS OPTION `ClientCoordinates` AND MEANS
/// DOCUMENT COORDINATES on this control, which is the fact the whole
/// reveal arm turns on. Measured on the VM 2026-08-06: the last match of
/// a 40-line document reported Y=689 with the viewport at offset 0 AND
/// with it at 625 — the rectangle did not move, because the Rich Edit
/// engine renders into a surface that the XAML ScrollViewer slides, and
/// the engine's coordinates are the surface's. So a viewport question
/// is answered by combining this with the ScrollViewer's offset, never
/// by the rectangle alone.
///
/// `ITextRange::ScrollIntoView` — the call the reveal arm makes — does
/// move the XAML ScrollViewer (measured: offset 0 -> 625 of 662 for the
/// last match of a 40-line document), so the two coordinate systems have
/// to be combined for the read even though the write needs only one.
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
/// Windows has no "insert marked text" call: AppKit has `setMarkedText`,
/// UIKit has `setMarkedText:selectedRange:`, Android has
/// `InputConnection.setComposingText`, and Windows has an ARCHITECTURE —
/// compositions belong to TSF, which owns the focused document and hands
/// text services a write lock to work inside. So this does what a text
/// service does, in the app's own process and on its own UI thread: take
/// the focused context, run an edit session on it, start a composition
/// over the caret, and write the marked text into the composition's
/// range. Nothing is committed; the control raises
/// `TextCompositionStarted` and the text sits in the document as
/// UNCOMMITTED composition text, which is the state D4's refusal exists
/// for.
///
/// (Injecting keystrokes was never an option: an IME converts what it is
/// given — a Japanese IME turns "nihon" into kana — so the marked string
/// would not be the string the frozen scene expects, and the VM has no
/// IME installed to convert it with. Inserting the text as ordinary
/// content would prove nothing: it is exactly the state the refusal must
/// be able to tell a composition apart from.)
///
/// THE COMPOSITION IS DELIBERATELY LEFT OPEN. `ITfComposition` is parked
/// in a thread-local rather than dropped, so the marked text stays marked
/// for the rest of the scene — a composition that ended on the way out of
/// this function would leave committed text and a passing D4 assertion
/// that proved nothing.
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
        // The thread manager is a per-thread singleton, so this is a
        // handle to the one WinUI's input stack already activated rather
        // than a second manager.
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
                // THE COMPOSITION RANGE COMES FROM `ITfInsertAtSelection`
                // rather than from `GetSelection`, which is the pattern
                // Microsoft's own TSF sample uses
                // (Win7Samples/winui/tsf/tsfmark): a query-only insert
                // asks the TEXT STORE where text would go, which is the
                // range a composition may cover, where the selection is
                // only where the caret is. Stated as the sample's
                // authority and not as a measurement — what the VM
                // measured is the SINK (see KayaCompositionSink), which
                // is what E_INVALIDARG was actually about.
                let inserter: ITfInsertAtSelection = inside.cast()?;
                let at = inserter.InsertTextAtSelection(ec, TF_IAS_QUERYONLY, &[])?;
                let composition = composer.StartComposition(ec, &at, &sink)?;
                let range = composition.GetRange()?;
                range.SetText(ec, 0, &marked)?;
                // A COMPOSITION PARKS THE CARET AT THE END OF ITS MARKED
                // TEXT — every platform's convention, and the number the
                // frozen scene asserts.
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
        // SYNCHRONOUS FIRST so the composition is live before this
        // returns, ASYNC as the fallback — and the fallback is keyed on
        // the GRANT, not on the call. `RequestEditSession` answers twice:
        // the call's own HRESULT (did TSF understand the request) and
        // `phrSession` (was the lock given), and a refused sync request
        // comes back as a SUCCESSFUL call carrying a failed grant.
        // Measured on the VM 2026-08-06: the sync request is answered
        // E_INVALIDARG — a synchronous lock is the document owner's
        // privilege and this client is not it — while the async request
        // is granted and the composition appears.
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

/// TSF's edit session, hand-rolled — one method over `IUnknown`, and the
/// same nominal-refcount shape as `KayaOuter` above (a process-lifetime
/// object that is never released). The alternative is the `implement`
/// macro, which would add a proc-macro dependency to every kaya build
/// for one harness verb.
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
            // SAID HERE AND NOT AT THE CALL SITE, because an
            // ASYNCHRONOUS grant runs this body long after the caller
            // returned: a failure the caller reported would be a
            // failure nobody ever hears about.
            eprintln!("kaya: the composition edit session failed: {}", e.message());
            e.code()
        }
    };
    *session.outcome.borrow_mut() = Some(outcome);
    code
}

/// TSF'S COMPOSITION SINK — the object a composition reports its own
/// termination to. Documented as optional, and NOT optional in practice:
/// `StartComposition` with a NULL sink answers E_INVALIDARG on this
/// Windows build (measured on the VM 2026-08-06, twice, with the
/// composition range obtained both ways). Microsoft's own TSF sample
/// passes its text service here, so the sample is right and the
/// reference page is optimistic.
///
/// One method beyond IUnknown, and nothing to do in it: the harness's
/// composition is ended by the process exiting.
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
    // Nothing to unwind: the composition the harness starts lives until
    // the scene's process does.
    windows_core::HRESULT(0)
}

#[cfg(feature = "harness")]
thread_local! {
    /// The open composition, parked so it outlives the edit session that
    /// started it. Dropping it here would be the one thing that must not
    /// happen: the marked text has to stay marked for the assertion that
    /// follows.
    static LIVE_COMPOSITION: RefCell<Option<windows::Win32::UI::TextServices::ITfComposition>> =
        const { RefCell::new(None) };
}

/// A set of platform ranges in the harness's spelling:
/// `<start>:<end>=<covered text>` per range, `|`-joined, ascending.
///
/// THE COVERED TEXT IS NOT DECORATION. Offsets alone would make this
/// read the exact inverse of the lowering's own conversion, so two
/// symmetric mistakes would cancel and the leg would pass while the
/// highlight covered the wrong characters. The covered text has no
/// arithmetic in it — the string is sliced with the range the platform
/// is actually holding — so the two halves cannot be wrong together.
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

/// EPISODE BANKING (docs/undo-plan.md §3), on the way past.
///
/// Every user edit of a text field is shown to the ledger before the
/// occurrence goes to the app: the run of edits on one field between
/// clears is ONE ledger entry, opened by the first event and extended by
/// each one after. The core owns all of that; the backend contributes
/// the two facts only it can see — WHICH FIELD, and whether it is
/// FOCUSED (an event on an unfocused field closes the episode as it
/// stands).
///
/// FROM A USER EDIT, WHICHEVER WAY IT ARRIVED — the control's own
/// TextChanged (a real keystroke, a real paste) and the harness's
/// `set_text`, which stands in for one. The APP's programmatic writes do
/// not come through here: they bump the swallow counter and the core
/// absorbs them from the apply ops (`Scene::absorb_text_writes`), which
/// is the site that cannot be bypassed by a sixth write path.
///
/// `with_borrow_mut` and not a deferred hop, deliberately: a bank that
/// landed a tick later could arrive AFTER the routing question that
/// depends on it, which is the silent class this milestone exists to
/// close. The borrow is safe because this backend's TextChanged is
/// raised ASYNCHRONOUSLY — the fact the swallow counters already stand
/// on, and re-measured for a routed `Undo()` by this arm's probe
/// (`inside_undo_call=false` on every raise).
fn bank_text_changed(id: u64, text: &str) -> bool {
    CORE.with_borrow_mut(|core| {
        let Some(core) = core.as_mut() else { return false };
        bank_text_changed_on(core, id, text)
    })
}

/// The same banking with the core ALREADY BORROWED — the harness's
/// `set_text` runs inside `on_ui_mut`, and taking `CORE` again there
/// would panic on the live borrow rather than bank.
///
/// ONE BODY, TWO DOORS: the rule about what the ledger is told must not
/// be spelled twice, or the two spellings drift and only one of them is
/// the one a scene exercises — which is exactly the state this function
/// was extracted to end (the harness path told the ledger nothing at
/// all, and a stamped row's typing was outside the history on this
/// backend alone).
fn bank_text_changed_on(core: &mut CoreState, id: u64, text: &str) -> bool {
    // A RAISE THAT CARRIES NO TEXT CHANGE IS NOT A TEXT CHANGE, and on
    // THIS control that is not a theoretical case: a RichEditBox raises
    // TextChanged for a CHARACTER FORMAT write as readily as for a
    // keystroke, so `highlight_ranges` — a background colour and not one
    // character — comes back through the same event as an edit.
    //
    // MEASURED, and it is a FEEDBACK LOOP rather than a stray event
    // (2026-08-10, the editor's first windows leg): the app folds
    // text_changed and re-declares its find set from the fold, so
    // kaya's paint raised TextChanged, the raise reached the app as an
    // edit, the app re-declared, and the pair ran at ~260 round trips a
    // second for the whole 180-second leg. Every one of that leg's six
    // failures was downstream of it — the UI thread never went idle, so
    // the find bar's own keystrokes sat on the queue for a minute, a
    // ContentDialog never reached `IsLoaded`, and the app's match count
    // was overwritten by the next spurious fold before anything could
    // read it.
    //
    // The compare is against what THIS HANDLER LAST SAW on the control
    // (`banked_text`), never against the core's model of the field: the
    // core is told about kaya's own writes through `absorb_text_writes`,
    // so comparing there would also silence the echo of a routed native
    // undo — the one programmatic write whose report the app is
    // REQUIRED to hear (§3a).
    //
    // Answers whether the guest should be told, so the one rule lives in
    // the one place both handlers already call.
    if core.banked_text.get(&id).map(String::as_str) == Some(text) {
        return false;
    }
    // THE LEDGER HAS BEEN SHOWN THIS TEXT, whichever way the next
    // few lines go: a quiet echo was reported through
    // `note_native_undo` and an ordinary edit is banked below, and
    // the `type` verb's settle is asking "has kaya seen it", not
    // "which path did it take".
    core.banked_text.insert(id, text.to_owned());
    // Q2's ledger-quiet bracket: this edit is the echo of a native
    // undo THIS BACKEND ROUTED, and `note_native_undo` already
    // reported it with the backend's own sample. Banking it again
    // would restate the walk's position as a new high-water and
    // erase the walk the redo side needs.
    if core.ledger_quiet.get(&id).map(String::as_str) == Some(text) {
        core.ledger_quiet.remove(&id);
        // The APP still hears it: a routed native undo is an edit like
        // any other from the guest's side (§3a), and only the ledger's
        // second look is suppressed.
        return true;
    }
    let focused = focused_editable_id(core) == Some(id);
    let window = ledger_window(core);
    core.scene
        .note_text_changed(window, WidgetId(id), text, focused);
    true
}

/// A4's ONE named query — "can the focused widget undo?" — answered in
/// this platform's vocabulary and asked nowhere else in this file.
///
/// D6 already named four hard-coded role filters as silent-failure
/// sites; a fifth expression of this same question is the shape A4
/// exists to refuse. The core's `route_undo` consumes the answer.
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

/// THE LEDGER'S WINDOW, in one named place.
///
/// §3's ledger is per window, and this backend cannot name a widget's
/// window: it keeps no widget-to-window map (roots and titles are keyed
/// by window, children are not), and every other window-scoped decision
/// here already stands on the primary — the chord hook dispatches
/// `MenuAttachment::Window(0)`, and the harness resolves menu paths
/// against `menu_windows[&0]`. §1.1 recorded the same gap from the
/// probe's side ("Not measured: multi-window and auxiliary-window
/// fields"). So the assumption is stated ONCE, here, rather than spelled
/// five times: typing in an auxiliary window banks into the primary's
/// ledger. When aux windows grow one, this function is the single site
/// that changes.
fn ledger_window(_core: &CoreState) -> WindowId {
    WindowId(0)
}

/// Where an undo would go RIGHT NOW.
///
/// ASKED ONCE AND USED TWICE — enablement and activation are the same
/// question (D6: "enablement is that same question, computed live at
/// activation exactly as paste's offer∩accepts is"), and `Nothing` IS
/// what a disabled Edit>Undo means.
///
/// AND THE ANSWER IS THE CORE'S, not this layer's. What the backend
/// contributes is the pair only it can see — what is focused, and
/// whether that field's own stack has anything (A4's named query above)
/// — and the ledger decides against them. A second routing rule written
/// here would be a fifth hard-coded predicate of exactly the kind D6
/// records as the silent-failure shape.
fn undo_route(core: &CoreState) -> crate::scene::UndoRoute {
    core.scene.route_undo(
        ledger_window(core),
        focused_editable_id(core).map(WidgetId),
        focused_can_undo(core),
    )
}

/// Redo's twin. On the frontier episode redo stays NATIVE while the
/// episode is partly undone — the platform still holds those steps, and
/// taking them back coarsely would throw away granularity the user can
/// see. That judgement is the ledger's too; this asks with `CanRedo`.
fn redo_route(core: &CoreState) -> crate::scene::UndoRoute {
    core.scene.route_redo(
        ledger_window(core),
        focused_editable_id(core).map(WidgetId),
        focused_can_redo(core),
    )
}

/// Whether a role's command can act right now; a non-role item answers
/// true and pays nothing. THE SAME RULE AS THE OTHER ARMS
/// (kayaRoleEnabled, gtk's role_enabled): paste is the INTERSECTION of
/// what the clipboard offers and what the focused widget accepts — a
/// widget that declared NOTHING still pastes (the platform inserts), so
/// an undeclared target enables on the text offer alone. Cut and copy
/// need a focused editable. Undo and redo ask the ROUTE, which is the
/// same call their activation makes, so the two cannot drift (A4).
/// IsClipboardFormatAvailable needs no open, so this is cheap enough
/// for every refresh site.
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

/// Recompute the role items' enablement onto the REAL chrome.
/// THE MAC FINDING, spelled WinUI (docs/clipboard-plan.md §3):
/// enablement is the intersection of what the clipboard offers and
/// what the focused widget accepts, and both move long after the bar
/// was built. menu_user_activate refuses a disabled item natively, so
/// this runs wherever enablement can change hands: a role or accepts
/// list lands, a copy goes out, the clipboard or the focus changes,
/// the coalesced rebuild restamps structural enablement — and before
/// a harness activation OR READ.
///
/// THE ROLE SET IS ONE OF D6's FOUR RECORDED SILENT-FAILURE SITES
/// (docs/undo-plan.md, and tools/check-roles.sh's third clause holds it
/// open): an item whose role is outside this `matches!` never has its
/// enablement recomputed at all, and on this backend a disabled item is
/// refused by BOTH the invoke pipeline and the chord hook — so a role
/// missing here is a command nothing can activate. It must name every
/// gesture role in MENU_ROLES.
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
        // ONE ITEM, TWO CHROME VIEWS: a promoted role item has a toolbar
        // button as well as a menu row, and the role factor moves with no
        // catalog traffic at all (a clipboard offer changes, Undo's route
        // changes), so a button left out of this loop would keep the
        // enablement the last REBUILD stamped on it — the exact "the
        // chrome kept its own copy" defect the scene's round trip exists
        // to catch, arriving only for role items.
        for ((_, button_id), button) in &core.toolbar_buttons {
            if *button_id == id {
                let _ = button.SetIsEnabled(on);
            }
        }
    }
}

/// Perform an UNDO role. Answers whether it WAS one, so a clipboard
/// role and then a plain action fall through behind it.
///
/// SPLIT FROM THE CLIPBOARD PERFORM ON PURPOSE, the way the mac arm
/// splits it: an undo is not a clipboard command, it answers from two
/// tiers rather than one, and tools/check-roles.sh reads the UNION of
/// this file's `perform_*_role` functions for exactly this reason.
///
/// THIS IS ALSO WHERE THE CHORD LANDS. §1.1's measured finding is that
/// kaya's thread-scoped keyboard hook STEALS Ctrl+Z from a focused
/// TextBox the moment `MenuRole::Undo` carries the chord — the menu
/// fires and the field never sees the key, and a DISABLED item eats it
/// just as dead. So the routing cannot sit beside the dispatch; it has
/// to BE the dispatch. `key_hook` resolves the chord and calls
/// `menu_user_activate`, which calls this, so the hook's own path
/// answers the native tier — and the accelerator stays attached as
/// dress, so the menu keeps drawing "Ctrl+Z" and agrees with the
/// field's own context menu (P4).
fn perform_undo_role(core: &mut CoreState, role: &str) -> bool {
    match role {
        "undo" => {
            match undo_route(core) {
                crate::scene::UndoRoute::Native => native_walk(core, false),
                crate::scene::UndoRoute::Core => core_walk(core, false),
                // Inert, and it says so in the chrome: enablement IS
                // this route (role_enabled), recomputed live.
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

/// How many native records ONE Edit>Undo may spend looking for the text
/// to move (`native_walk`). A BOUND AND NOT A `while`: the walk runs on
/// the UI thread, so a stack that never satisfies the condition has to
/// stop and SAY SO rather than spin the window into a hang.
const NATIVE_WALK_LIMIT: usize = 64;

/// THE NATIVE TIER, and THE RECONCILIATION SAMPLE with it (§3).
///
/// The core walks its frontier episode backwards from three facts — the
/// field, the text the walk landed on, and whether the field can still
/// undo — and the backend's job is to take that sample at the one moment
/// it is true. MEASURED on this platform (the arm's probe, §1 of the
/// arm record): the text and `CanUndo` read the instant `Undo()` returns
/// are already final, so the sample is synchronous here. That is the
/// opposite of macOS, where SwiftUI syncs the model a turn later — which
/// is why the sample is taken from the CONTROL in both arms.
///
/// AND §3a's QUESTION IS ANSWERED "YES" HERE, so this function does NOT
/// report the text change itself. `TextBox.Undo()` raises the control's
/// ordinary TextChanged 7ms later (measured), which is the very event
/// the entry's handler rides, so the app hears the edit through the
/// channel it always hears edits through. Only the LEDGER would hear it
/// twice, and `ledger_quiet` is the bracket that stops it.
///
/// The textarea's `TextDocument().Undo()` is the same shape asked of a
/// different object, and the same bracket covers it: whether the
/// RichEdit engine raises TextChanged one turn later or none at all,
/// `ledger_quiet` is keyed on the TEXT the walk landed on, so an echo
/// that arrives is absorbed and one that never comes costs nothing.
///
/// THE THIRD FACT IS `CanUndo` IN BOTH DIRECTIONS, deliberately. It is
/// not "did this walk have more to give" — it is the core's test for the
/// one case A1's clear is meant to make unreachable: a platform that
/// coalesced ACROSS the episode's start and can no longer walk back to
/// the before-image. A redo reporting `CanRedo` there would answer false
/// at the end of a forward walk and send the core backwards.
fn native_walk(core: &mut CoreState, redo: bool) {
    // NO FOCUSED EDITABLE, NO WALK. Routing only answers Native where a
    // focused field reported CanUndo, so this cannot fire on the
    // ratified path — and a missing field must not read as the empty
    // string, which would wipe the episode through the sample.
    let Some(id) = focused_editable_id(core) else {
        return;
    };
    let Some(field) = editable_by_id(core, id) else {
        return;
    };
    // ONE Edit>Undo IS ONE TEXT STEP, and on this control the stack
    // holds records that move no text at all. Rich Edit records a
    // CharacterFormat write like any other change, so a `highlight_ranges`
    // declaration — kaya's own paint, which no user asked for — sits on
    // top of the user's typing. MEASURED (2026-08-10, the editor leg):
    // `Undo()` returned with the text byte-identical, `CanUndo` still
    // true, and the keystroke the user wanted back still in the document.
    //
    // kaya's undo means the user's last EDIT, so the walk spends records
    // until the text moves. It cannot overshoot: the loop stops at the
    // FIRST record that moves the text, which is exactly one text step.
    let start = lf(field.text().unwrap_or_default());
    let mut called: windows_core::Result<()>;
    let mut spent = 0usize;
    loop {
        called = if redo { field.redo() } else { field.undo() };
        spent += 1;
        if called.is_err() || lf(field.text().unwrap_or_default()) != start {
            break;
        }
        // The text has not moved and the stack has nothing left to
        // spend: the episode is exhausted, which the sample below
        // reports and `note_native_undo` finishes coarsely.
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
    // Usually nothing comes back — the walk already happened in the
    // widget. The exception is the exhausted-mid-episode case above,
    // which finishes the job coarsely and reports like any core undo.
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

/// The restore, then the report — IN THAT ORDER, which is the same rule
/// the presentation-side entry point states (capi.rs's `with_undo_scene`:
/// the ops are queued in front of the pump before the occurrence goes
/// out). The occurrence is what makes the app apply its own transaction,
/// and that transaction must not overtake the restore it is reacting to.
/// Here the ops are applied outright rather than queued, because this
/// backend IS the pump and holds the scene.
fn deliver_undo(core: &mut CoreState, ops: Vec<ApplyOp>, occurrence: Occurrence) {
    for op in ops {
        apply(core, op).expect("kaya: applying an undo op failed");
    }
    // The chrome an undo restored may have changed what the roles can do
    // (a restored row, a moved focus), and the item that fired is about
    // to be asked again.
    if core.roles_armed {
        refresh_role_enablement(core);
    }
    core.occurrences.send(occurrence);
}

/// Perform a clipboard role on the focused widget. Answers whether it
/// WAS one, so a plain action falls through to its own dispatch.
///
/// THE PASTE SPLIT (DESIGN.md): a widget that DECLARED what it
/// accepts takes the content itself — the same materialization walk
/// as the privileged read, delivered to the paste hook — while one
/// that declared nothing gets the platform's own insertion
/// (`Editable::paste_from_clipboard` — TextBox's own
/// PasteFromClipboard for an entry, the same plain text set on the
/// selection for a textarea) and its ordinary change path reports the
/// result. The swallow counter is NOT bumped for that insertion: a
/// paste acts like the user, and the field's TextChanged is the report.
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
                // A paste that delivered nothing is not an occurrence
                // (the read owns the empty answer).
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

/// THE BRAND ACCENT, AS A THEME DICTIONARY OF STOPS
/// (docs/styling-plan.md D1).
///
/// WHAT THIS OVERRIDES AND WHY IT IS NOT `SystemAccentColor`. The Fluent
/// control styles never read `SystemAccentColor` for a control fill.
/// They read the DERIVED STOPS the XAML core injects beside it —
/// `SystemAccentColorDark1..3` and `SystemAccentColorLight1..3` — and
/// WHICH stop depends on the theme, CROSSED: the LIGHT theme reads the
/// DARK stops and the DARK theme reads the LIGHT ones (Fluent's names
/// say how light the SHADE is, not which theme owns it). Read out of
/// `CommonStyles/Common_themeresources_any.xaml`:
/// `AccentFillColorDefaultBrush` is `SystemAccentColorDark1` under
/// `Light` and `SystemAccentColorLight2` under `Default`. So an app that
/// writes `SystemAccentColor` alone changes the text-selection highlight
/// and NOTHING ELSE — the confirmed silent near-no-op of
/// microsoft-ui-xaml#6394, which the live theming docs still publish as
/// the answer, and which is the worst diagnostic shape there is: it
/// looks like it half worked, so the author concludes the VALUE is wrong
/// rather than the KEY.
///
/// THE SECONDARY AND TERTIARY TIERS COME FOR FREE. Fluent expresses the
/// pointer-over and pressed fills as the SAME stop at opacity 0.9 / 0.8,
/// and its accent border as a two-stop gradient of fixed alphas over the
/// stop. Overriding the stops recomputes all of them; overriding the
/// derived brushes instead would make kaya reproduce Fluent's opacity
/// ladder, and those brushes are reached through `StaticResource`
/// ALIASES, which resolve once at load. The stops are referenced with
/// `{ThemeResource}` — that is the difference, and it is why the stop
/// route is the one this arm takes.
///
/// LIGHT AND DARK ONLY, NEVER HighContrast. Under a contrast theme the
/// framework's own `HighContrast` dictionary re-points every accent
/// brush at `SystemColor*`, which is a documented accessibility
/// contract ("Do not hard-code colors in HighContrast"). kaya writes no
/// HighContrast entry, so the brand simply stops applying there — the
/// yield is the platform's own, and that is D2's "a platform may let
/// its user override the request" with the user speaking through their
/// contrast theme.
///
/// MARKUP AND NOT THE OBJECT MODEL, and the reason is mechanical rather
/// than stylistic: a stop's key holds a `Windows.UI.Color`, a WinRT
/// STRUCT, and inserting one into `ResourceDictionary.ThemeDictionaries`
/// through the projection would need that struct boxed as
/// `IReference<Color>`. C#'s projection boxes value types for you;
/// `windows-core` does not, and `PropertyValue` has no `CreateColor`
/// (its factories stop at the primitives, Point, Size and Rect). The
/// XAML parser is what boxes a `<Color>` element, so `XamlReader.Load`
/// is not a preference here — it is the only route from Rust that can
/// put a Color under a Color key. It is also the shape every documented
/// example takes.
fn brand_dictionary(accent: &crate::brand::BrandAccent) -> String {
    // THE MAPPING, stop by stop. kaya's core derives per appearance
    // {fill, on_fill, standalone, hover, pressed}; Fluent's ramp is
    // three stops per appearance with fixed consumers. The pairing is by
    // CONSUMER, never by position in a ramp:
    //
    //   Light dictionary (what the LIGHT theme reads — the Dark stops):
    //     Dark1 <- light.fill       AccentFillColorDefault/Secondary/
    //                               Tertiary (the filled button, plus
    //                               its 0.9/0.8 states), and
    //                               AccentTextFillColorTertiary.
    //     Dark2 <- light.standalone AccentTextFillColorPrimary: accent
    //                               COLOURED TEXT on a neutral surface,
    //                               which is exactly the word the core
    //                               derives separately because a fill's
    //                               number is the wrong number for text.
    //     Dark3 <- light.hover      AccentTextFillColorSecondary, whose
    //                               consumer is HyperlinkButtonForeground
    //                               PointerOver — an interaction tier,
    //                               and DARKER, which is the direction
    //                               kaya's light ramp already takes.
    //
    //   Dark dictionary (what the DARK theme reads — the Light stops):
    //     Light2 <- dark.fill       the same fill family, plus
    //                               SystemFillColorAttention.
    //     Light3 <- dark.standalone AccentTextFillColorPrimary AND
    //                               Secondary both read Light3 here.
    //     Light1 <- dark.hover      NOTHING in the framework's dictionary
    //                               reads Light1 — said plainly so the
    //                               next reader does not go looking for
    //                               its effect. It is written because a
    //                               HALF-overridden ramp is the trap one
    //                               level down: a stop left at the system
    //                               value paints the USER's accent beside
    //                               kaya's brand in any consumer this
    //                               table has not enumerated.
    //
    // `on_fill` is not written: Fluent hard-codes the accent foreground
    // (`TextOnAccentFillColorPrimaryBrush` is #FFFFFF under Light and
    // #000000 under Default) rather than deriving it, which is the very
    // agreement D1's danger-band clamp exists to guarantee — the core
    // already promises white below L* 60 and black at or above it, so
    // kaya's word and Fluent's constant say the same thing and nothing
    // needs writing. `pressed` reaches no stop either: this platform
    // derives its pressed fill as the fill stop at opacity 0.8, so a
    // separate pressed COLOUR has nowhere to land.
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
/// APPENDED LAST, AND THAT IS THE WHOLE ORDERING RULE: merged
/// dictionaries are searched in REVERSE order, so kaya's entry must go
/// in after `XamlControlsResources` (which `outer_on_launched` merges at
/// launch) or the framework's own stops would keep winning.
///
/// ONCE, BEFORE ANY WIDGET EXISTS. The core emits `SetBrand` before the
/// first mount and refuses a second write, which is what makes this
/// safe: changing a resource VALUE at runtime does NOT refresh a WinUI
/// tree — Microsoft's own theme editor cycles `RequestedTheme` to force
/// it — so a brand that could arrive late would need a visible re-theme
/// to take. Arriving before the first control is created, every
/// `{ThemeResource}` resolves against kaya's stops the first time it is
/// asked.
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
        // No `if let Some` fallback here, deliberately: an absent
        // Application would make this a silently unbranded app, which is
        // the failure the whole arm is written against. Ops are applied
        // on the UI thread, which is the thread `setup` puts the
        // Application in, so None is not a state this can reach.
        let app = app
            .as_ref()
            .expect("apply runs on the UI thread, where the Application lives");
        app.Resources()?.MergedDictionaries()?.Append(&dictionary)
    })
}

/// One theme resource, by key, or the error the framework answered with.
///
/// `Application.Current.Resources` is the lookup ROOT: it searches the
/// application dictionary, then the merged ones in reverse order, then
/// their theme dictionaries — which is how a framework key like
/// `AccentButtonStyle` (defined in XamlControlsResources) is reached
/// from code with no XAML scope of our own.
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
// scratchpad/styling/typeface-winui.md (the resource census) and
// typeface-winui-arm.md (the lane measurements).
// ---------------------------------------------------------------------

// The brand typeface's `FontFamily` SOURCE for this process, or `None`
// for a brandless app.
//
// A SOURCE STRING RATHER THAN A FAMILY NAME, because XAML's grammar
// here is wider than a name: `Georgia` is one spelling, a
// comma-separated FALLBACK LIST is another (Fluent's own
// `SymbolThemeFontFamily` is `'Segoe Fluent Icons,Segoe MDL2 Assets'`),
// and `<path>#<family>` names a face that is not installed at all —
// which is how a font BLOB reaches this platform (`register_font_blob`).
// Everything here writes the source verbatim and lets XAML parse it;
// only the harness read splits it apart again, to say which family the
// text system ended up with.
//
// THREAD-LOCAL AND NOT A `CoreState` FIELD: widgets are built on the UI
// thread inside `apply`, where `CoreState` is already mutably borrowed
// by the caller, and `text_block` is called from exactly there. Same
// thread, same lifetime, no second borrow.
thread_local! {
    static BRAND_TYPEFACE: RefCell<Option<String>> = const { RefCell::new(None) };
}

fn brand_typeface() -> Option<String> {
    BRAND_TYPEFACE.with_borrow(|source| source.clone())
}

/// Every `TextBlock` this backend makes — and the only place one is made.
///
/// THE PAIR THAT CANNOT SPLIT, and it is the guard this arm needed most.
/// Two separate ways a TextBlock misses the brand, both invisible (the
/// app renders; one piece of text is quietly in the system face):
///
///   * A plain kaya label is a bare TextBlock under Grids, with no
///     Control anywhere above it and — measured — no implicit style at
///     all (0 keyless `TargetType="TextBlock"` Styles in the shipped
///     Fluent dictionary). It inherits nothing, so the resource override
///     that re-points 58 CONTROL styles cannot reach it. Only a local
///     write can.
///   * Every step of the Fluent type ramp is `BasedOn`
///     `BaseTextBlockStyle`, which hard-codes the LITERAL string
///     `XamlAutoFontFamily` as a Setter value — not a `{ThemeResource}`
///     reference, so there is no key to redefine and no resource write
///     that reaches it. kaya's `heading` role applies
///     `SubtitleTextBlockStyle`, so under a resource-only lowering every
///     heading in every kaya app would keep the system font while
///     everything around it moved.
///
/// So the write does not sit BESIDE the style application, where the
/// next author has to remember it. It sits in the constructor, and the
/// style arms cannot take it back: in XAML's dependency-property
/// precedence a LOCAL value outranks a Style setter whatever order the
/// two arrive in, so `SetStyle` afterwards changes the size and weight
/// and leaves the family alone. That is exactly Slice 2b's rule — the
/// family moves, the ramp does not — falling out of the precedence
/// instead of being maintained by hand.
///
/// What is left unguarded is a fifth `TextBlock::new()` appearing
/// somewhere else; there are four callers today and all four are here.
/// A grep gate would seal it (see this arm's report) — the type system
/// cannot, because `TextBlock::new` is a generated projection method.
fn text_block() -> windows_core::Result<TextBlock> {
    let block = TextBlock::new()?;
    if let Some(source) = brand_typeface() {
        block.SetFontFamily(&FontFamily::CreateInstanceWithName(&HSTRING::from(source))?)?;
    }
    Ok(block)
}

/// The app-level dictionary that re-points the CONTROL ramp.
///
/// FOUR KEYS, AND A FIFTH THAT MUST NEVER JOIN THEM. `XamlAutoFontFamily`
/// reaches Fluent's controls through `ContentControlThemeFontFamily`,
/// referenced as `{ThemeResource}` by 58 keyed Styles plus the implicit
/// ones — every control kaya renders is in that list (Button, TextBox,
/// RichEditBox, CheckBox, RadioButton, ComboBox, Slider, ToolTip, the
/// list items…). A `{ThemeResource}` reference re-resolves against the
/// lookup chain, so an app dictionary that redefines the key wins; this
/// is the same mechanism `apply_brand` uses for the six accent stops,
/// with the same ordering rule (appended LAST, because merged
/// dictionaries are searched in REVERSE).
///
/// `KeyTipFontFamily`, `PivotHeaderItemFontFamily` and
/// `PivotTitleFontFamily` are the same `XamlAutoFontFamily` value behind
/// three more keys. They are written for the accent arm's
/// half-overridden-ramp reason: a stop left at the framework value paints
/// the platform's own choice beside kaya's brand in any consumer this
/// table did not enumerate.
///
/// **`SymbolThemeFontFamily` is NOT here and may never be.** Its value is
/// `'Segoe Fluent Icons,Segoe MDL2 Assets'` — the icon glyph family, read
/// by 16 Styles and 80 template sites, deliberately left unset by the
/// icons slice so glyphs resolve on Windows 10 as well as 11. A typeface
/// lowering that swept "every FontFamily resource" would turn every icon
/// in the app into a box, and the failure would look like an icons bug.
///
/// MARKUP RATHER THAN THE OBJECT MODEL, unlike what the type would
/// allow: `FontFamily` is a runtime class, so `ResourceDictionary::Insert`
/// could box it where a `Color` could not — but `ResourceDictionary` has
/// no projected constructor in the generated bindings, and this is the
/// exact markup form Microsoft's own `generic.xaml` uses for these four
/// keys. One proven route (the accent's) beats two.
fn typeface_dictionary(source: &str) -> String {
    // XML-escaped: a family name is app data, and `&` or `<` in one
    // would otherwise be a parse failure in kaya's own markup rather
    // than a bad request. `#` and spaces need nothing.
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

/// A font BLOB, made nameable to XAML — and every part of this is
/// measured, because three of the four obvious routes silently do
/// nothing (typeface-winui-arm.md §3).
///
/// WHAT DOES NOT WORK, each tried on the lane and each failing by
/// rendering the fallback with no error anywhere:
///   * An ABSOLUTE filesystem path, `C:\dir\face.ttf#Family` — the
///     spelling the probe report proposed. XAML ignores it.
///   * A `file:///C:/dir/face.ttf#Family` URI. Same.
///   * `AddFontResourceExW`, private OR session-wide. It RETURNS 1, the
///     font really is in this process's GDI table, and XAML still
///     resolves the family to the fallback — GDI's table is not the
///     collection XAML asks. (The session-wide form would also be a GUI
///     library writing to the user's machine, which kaya will not do.)
///   * A custom DirectWrite collection
///     (`CreateInMemoryFontFileLoader`) — not tried on the lane and not
///     worth trying: `FontFamily` has no API that accepts a collection,
///     so it would produce a font this process can measure and no
///     control can render.
///
/// WHAT WORKS is a file under the APP ROOT, referenced by an
/// app-relative or `ms-appx:///` path. Measured, all four spellings
/// resolving to the same laid-out width: `ms-appx:///face.ttf#Family`,
/// `/face.ttf#Family`, `face.ttf#Family`, `sub/face.ttf#Family`. For an
/// unpackaged app — which every kaya guest is — that root is the
/// directory holding the executable, so the bytes are written there and
/// named with the URI form, which is the one that says out loud which
/// namespace is being addressed.
///
/// The family name comes OUT OF THE BYTES, never from the request:
/// DirectWrite opens the file and reports what the face declares
/// (measured: `Chalkduster` for a face this machine does not have
/// installed). That is register-then-resolve, the same shape as
/// CTFontManager on Apple, and it is why a blob that is not a font fails
/// HERE with the bytes in hand rather than three layers later as a
/// silent fallback.
///
/// TWO LIMITS THIS ROUTE HAS, stated rather than discovered later:
/// the app directory must be writable (an app installed under Program
/// Files is not), and for a DLL-HOSTED guest — python, go, csharp, java
/// — `current_exe` is the HOST interpreter's binary, so the app root is
/// its directory and not kaya's. Neither is measured, because no guest
/// in this tree ships font bytes yet; both are in docs/deferred.md.
#[allow(dead_code)] // reachable only through a guest that ships font bytes
fn register_font_blob(bytes: &[u8]) -> Result<String, String> {
    // NAMED BY CONTENT, not by process: two guests running side by side
    // on one desktop (the lane runs four) that ship the same font write
    // the same bytes to the same path, and two that ship different fonts
    // cannot collide. It also means a rerun reuses the file instead of
    // littering the app directory once per launch.
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
    // WRITTEN ONLY IF IT IS NOT ALREADY THERE, and that is a correctness
    // rule rather than a saving. A font file that some process has open
    // is MEMORY-MAPPED — DirectWrite maps it, and XAML keeps it mapped
    // for as long as it can lay text out in it — and Windows refuses to
    // overwrite a mapped file: `os error 1224`, "the requested operation
    // cannot be performed on a file with a user-mapped section open".
    // The name is this content's hash, so anything already at that path
    // with these exact bytes IS the file this function would write, and
    // rewriting it buys nothing while risking that refusal — which the
    // caller turns into a panic, on a lane that runs four guests at once
    // with two of them sharing one app directory. Measured 2026-08-16:
    // a second registration in one process failed with 1224 against the
    // file the first had just opened.
    if std::fs::read(&path).map(|there| there == bytes).unwrap_or(false) {
        // Nothing to do: the bytes on disk are the bytes asked for.
    } else {
        std::fs::write(&path, bytes)
            .map_err(|e| format!("{} could not be written: {e}", path.display()))?;
    }
    // The family name comes out of the FILE, through the one reader this
    // arm has — the same one the harness read runs backwards over the
    // path below, so what is written and what is checked cannot drift.
    let family = font_file_family(&path).map_err(|why| {
        format!(
            "{}: {why} (from the {} bytes the guest shipped)",
            path.display(),
            bytes.len()
        )
    })?;
    // The APP-ROOT namespace, not the filesystem one: `ms-appx:///`
    // is what XAML resolves, and the absolute path this function
    // just wrote to is what it silently ignores.
    Ok(format!("ms-appx:///{FONT_DIR}/{name}#{family}"))
}

/// The one directory `register_font_blob` writes into, and therefore the
/// one segment the source it hands back names. Written once because the
/// harness read resolves that source back to this file
/// (`typeface_availability`): a second spelling of this name is a reader
/// that quietly stops finding what the writer wrote.
const FONT_DIR: &str = "kaya-fonts";

/// The directory an UNPACKAGED app's `ms-appx:///` namespace resolves
/// to: the one holding this process's executable
/// (`register_font_blob`'s header carries the measurement, and the
/// dll-hosted caveat — for python, go, csharp and java this is the HOST
/// interpreter's directory, which is exactly where XAML looks for that
/// process too).
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
/// DirectWrite opens the file and reports what the face says it is; the
/// request never gets a vote (measured: `Chalkduster` for a face this
/// machine does not have installed). Both directions of the blob route
/// go through here — `register_font_blob` to NAME the file it just
/// wrote, and the harness read to check that the file a source points at
/// still declares that name — so a font this process cannot read is one
/// failure with one spelling rather than two.
///
/// THE MESSAGES NAME NO PATH. Both callers already have the file in hand
/// and both print it, and a sentence that names it twice reads as two
/// files (measured, in the first sentence this printed on the VM).
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
/// ONCE, BEFORE ANY WIDGET EXISTS — `apply_brand`'s wall for
/// `apply_brand`'s measured reason: changing a resource VALUE at runtime
/// does not re-theme a live WinUI tree. The core's set-once and
/// pre-mount refusals are what make that safe, and they are also what
/// lets `text_block` read a thread-local instead of walking the tree
/// afterwards.
fn apply_typeface(req: &crate::protocol::TypefaceRequest) -> windows_core::Result<()> {
    // WHICH ROW IS MINE, asked the way every Rust-native backend asks it:
    // the request carries per-platform families and `this_platform()` is
    // the compiler's own answer for the target this core was built for.
    // A binding could not answer it (the JVM says "Linux" on Android); a
    // lowering IS its platform.
    let family = req.family_for(crate::wire::this_platform());
    let source = match &req.font {
        Some(blob) => match register_font_blob(&blob.0) {
            Ok(source) => source,
            // REFUSED LOUDLY, and this is the one place in the arm that
            // panics: bytes that are not a usable font would otherwise
            // fall through to the family NAME and render as the platform
            // default — a silent fallback, which is the single failure
            // this whole slice exists to make impossible.
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

/// A family name no machine can have, and the reference the whole
/// typeface read turns on: whatever XAML lays this out in IS the
/// fallback, measured rather than named.
#[cfg(feature = "harness")]
const TYPEFACE_ABSENT: &str = "KayaNoSuchFamily-9x";

/// The pinned string every fingerprint lays out — ascenders, descenders,
/// and a wide/narrow pair, so a serif and a sans cannot collide by
/// accident. Measured at 24pt because the discrimination scales with the
/// size and nothing else depends on it.
#[cfg(feature = "harness")]
const TYPEFACE_PROBE_TEXT: &str = "Hxg Wi1lIm";

/// A XAML `FontFamily` source, split into the two things a reader can
/// ask about: the FILE it points into, if it points into one, and the
/// family it names.
///
/// The grammar has three forms and only one of them is a bare name:
/// `path#Family` points into a file (the blob route — this is exactly
/// what `register_font_blob` hands back), and a comma-separated list is
/// a fallback chain, whose FIRST entry is the one a reader means.
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

/// What XAML's own text stack makes of one family source: the laid-out
/// WIDTH of a pinned string and the BASELINE it put under it, in 1/64ths
/// so a float never decides an equality.
///
/// OFF THE TREE, deliberately. The probe must carry the family under
/// test and nothing else — a real widget's extent depends on its text,
/// and no two of kaya's widgets share one — so this measures a
/// throwaway block whose text, size and family are all pinned. It is
/// still XAML doing the work: the same text stack, the same font
/// resolution, the same DirectWrite underneath. (Measured: an
/// unparented TextBlock measures for real; the numbers below are not
/// zeroes.)
///
/// WIDTH AND BASELINE, NOT WIDTH AND HEIGHT, and the difference is a
/// measurement rather than taste. `DesiredSize.Height` is the LINE BOX,
/// which XAML computes differently for a family it resolved than for one
/// it fell back on: the unknown family `KayaNoSuchFamily-9x` and
/// `Segoe UI` lay the same string out to the same width, 7872/64ths, and
/// to line boxes of 1856 and 2048 — same glyphs, two different boxes. A
/// height-based fingerprint therefore reports that the fallback is not
/// the face it plainly is. `BaselineOffset` is an ASCENT, which comes
/// off the face, so it agrees with the width about which font ran.
#[cfg(feature = "harness")]
fn typeface_fingerprint(source: &str) -> windows_core::Result<(i64, i64)> {
    // Through the factory, so this file keeps ONE TextBlock construction
    // site; the probe then names its own family over the brand's, which
    // is a local value replacing a local value.
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

/// The `FontFamily.Source` each TextBlock is asking for.
///
/// This is the ECHO half and it is not the answer — it is the QUESTION
/// the fingerprint then settles. For a Label it reports the local write
/// `text_block` made; for a Control it reports what the implicit style
/// resolved `ContentControlThemeFontFamily` to, which is a read of the
/// resource lookup rather than of kaya's own variable.
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

/// What ONE view ended up with, said in the strongest terms its
/// measurements support and no stronger.
///
/// Three answers, and the reason there are three is a MEASUREMENT rather
/// than caution (typeface-winui-arm.md §2b): XAML's family lookup and
/// DirectWrite's disagree. `Segoe UI Variable` — this SDK's default
/// `Control.FontFamily` — is NOT in the system font collection, and XAML
/// still lays it out differently from a family nobody has. So
/// DirectWrite's presence answer is something this read REPORTS; it is
/// never the verdict. The verdict is always the fingerprint, which is
/// XAML's own text stack answering about XAML's own string.
///
///   * measured == the unknown-family fingerprint → the view fell back,
///     and the name of what it fell back TO is the one thing DirectWrite
///     can say honestly here.
///   * measured differs, and the family is AVAILABLE by the route its
///     source names → the name is a face this process really has and
///     XAML laid it out as its own thing. This is the only answer that
///     is a bare family name, and it is the one a passing scene compares
///     against.
///   * measured differs, and the family is NOT available by that route →
///     XAML resolved a string this process cannot account for. Saying
///     the bare name would claim more than was measured, so the sentence
///     says exactly what happened.
///
/// WHICH ROUTE, and this is the part that shipped wrong. A per-app font
/// file's family is NEVER in the system font collection — that is what
/// "per-app" means — so asking the collection about the blob route's
/// family answers "no" on a machine where everything worked, and the
/// scene could never pass (measured 2026-08-16: all five windows
/// typeface legs failed with "Sora (XAML lays it out, but it is not one
/// of this machine's 81 font families)" while XAML was laying Sora out).
/// The honest presence question follows the SOURCE: a bare name asks the
/// system collection, a `path#family` source asks the FILE's own name
/// table (`typeface_availability`).
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
        // TWO INDEPENDENT MEASUREMENTS AGREE, which is what makes the
        // bare name printable: the file's own name table (or the system
        // collection) says this family is here, and XAML's own layout
        // says it laid out something other than the fallback.
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
/// and `measured` says which one, because a reader who cannot tell
/// "nobody has this font" from "the file we wrote is gone" from "the
/// file is somebody else's font" chases the wrong one (CLAUDE.md
/// invariant 3).
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
    /// caller has just named — so both readers of this (the per-view
    /// answer and the fallen-back note) print the same measurement in
    /// their own sentence and cannot drift apart.
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
/// use it, and this says which half broke.
///
/// It takes the SAME `TypefaceAvailability` the per-view answer takes,
/// and prints it with the same vocabulary, because the two sentences
/// answer one question about one source — and the read shipped with them
/// disagreeing: this one asked the system collection about a per-app
/// font file's family, which is a question with a permanent "no" in it
/// (see `typeface_resolved`).
///
/// `asks_for` is the family the first view is really asking for, which
/// is the other half of "the lowering did not reach the view".
#[cfg(feature = "harness")]
fn typeface_fallback_note(
    first: &str,
    source: &str,
    availability: &TypefaceAvailability,
    asks_for: &str,
) -> String {
    let wanted = typeface_family_of(source);
    if availability.available() {
        // The brand's face is REALLY here — the system collection lists
        // it, or the per-app file this process wrote still declares it —
        // and the view still did not get it, so what broke is between
        // the request and the view rather than the font itself.
        format!(
            "{first} ({wanted} {}, so the lowering did not reach the view — it asks for \
             {asks_for})",
            availability.measured()
        )
    } else {
        format!("{first} ({wanted} {})", availability.measured())
    }
}

/// The presence question, asked the way the source spells it.
///
/// For a `path#family` source this is the INVERSE of what
/// `register_font_blob` wrote: the `ms-appx:///` path resolves back
/// under the app root — the same directory that function wrote into —
/// and the file there is opened with the same reader that named it
/// (`font_file_family`). Nothing here consults the system collection,
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
        // The app root is unnameable (a process that cannot name its own
        // executable). That is a measurement too, and it is not "the
        // font is missing".
        Err(why) => {
            return Ok(TypefaceAvailability::FileUnreadable {
                file: path.to_owned(),
                why,
            })
        }
    };
    let shown = file.display().to_string();
    // IS IT THERE AT ALL is asked separately, because DirectWrite cannot
    // answer it: its open failure says the file "does not exist or is
    // unavailable" — one sentence for two states a reader would chase
    // differently. The filesystem answers the first half exactly.
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
/// `register_font_blob`'s write, run backwards.
///
/// All four spellings XAML resolves are app-root-relative
/// (`ms-appx:///face.ttf`, `/face.ttf`, `face.ttf`, `sub/face.ttf`;
/// register_font_blob's header carries the measurement), so the inverse
/// is: drop the `ms-appx://` scheme and any leading separator, then join
/// the app root. An absolute path is left alone — XAML does not resolve
/// one, but a reader that silently re-rooted it would print a sentence
/// about a file nobody named.
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
    // machine's is `\`: joining the whole string produces a path that
    // WORKS and READS as two conventions in one line, and the reader of
    // a failure sentence should see the path they would type.
    let mut file = app_root()?;
    for segment in rest.split(['/', '\\']).filter(|s| !s.is_empty()) {
        file.push(segment);
    }
    Ok(file)
}

/// Is this family on this machine at all, and out of how many?
///
/// `IDWriteFontCollection::FindFamilyName` against the SYSTEM collection
/// — the one binary question about fonts that has an honest single-call
/// answer on Windows. It is what separates "the app asked for a family
/// nobody has" from "the family is here and the lowering missed it", and
/// those two failures look identical in every other observation.
///
/// IT ANSWERS FOR BARE-NAME SOURCES ONLY (`typeface_availability`): a
/// font this process registered from bytes is not in the system
/// collection and never will be, so asking this about one measures
/// nothing about it.
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

/// The name of the face an unresolvable family actually renders in —
/// NAMED by DirectWrite and CONFIRMED by XAML's own measurement.
///
/// THIS NUMBER MAY NOT BE A CONSTANT IN THIS TREE. Microsoft has never
/// documented WinUI 3's fallback family (microsoft-ui-xaml#10709, opened
/// August 2025, still unanswered by maintainers); it differs between
/// WinUI 2 and 3 (#9247); and it differs for UNPACKAGED apps by locale
/// (#8360) — which is kaya's case. So it is a property of the lane image,
/// and the arm measures it at run time instead of shipping a guess. The
/// obvious guess would have been wrong twice over: `Segoe UI Variable` is
/// not an installed family at all, only its Text and Display siblings
/// are.
///
/// TWO INDEPENDENT MEASUREMENTS, and the second is what makes the first
/// safe to print. `IDWriteFontFallback::MapCharacters` names the font it
/// mapped the text to, off the FONT rather than off the request. But that
/// is DirectWrite answering DirectWrite's question, and XAML resolves
/// family names its own way — measured here: DirectWrite maps
/// `Segoe UI Variable` to `Segoe UI` while XAML lays it out in something
/// 3% narrower (its `Text` sibling). So DirectWrite PROPOSES the name and
/// XAML's own layout confirms or refuses it; an unconfirmed name is
/// exactly the confident-wrong sentence a reader would chase, so it is
/// not printed as a name at all.
///
/// THE CONFIRMATION IS THE WIDTH ALONE, and that is a measurement rather
/// than a weakening. An unresolved family does not get the fallback
/// FACE's line metrics: measured on the lane, `KayaNoSuchFamily-9x` and
/// `Segoe UI` lay the same string out to the same 7872/64ths of width —
/// the same glyphs, from the same face — while their baselines are 1382
/// and 1658. 1382/64 is 21.6pt at a 24pt size, exactly 0.9em, which is
/// a synthetic ascent XAML uses when it never resolved a family, where
/// Segoe UI's own ascent is 1.079em. So the ADVANCES say which face drew
/// the glyphs and the BASELINE says whether the family resolved at all;
/// asking the fallback to match on both would be asking it to be
/// something it definitionally is not.
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
/// Latin text — what `MapCharacters` reads its input through. Nothing
/// here is a policy decision; the interface simply has five members.
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
                    // Uncontrolled: the field owns its text; TextChanged
                    // reports each edit (programmatic SetText included,
                    // which is what lets the selftest type like a user)
                    // with the entry's identity tag, and the app folds
                    // it into its own model.
                    //
                    // Two prerequisites, both VM-proven (2026-07-15):
                    // MRT init needs an exe-adjacent resources.pri (the
                    // deploy ships tools/guest/minimal-resources.pri),
                    // and the built-in template's deferred theme XAML
                    // needs the composed Application's metadata provider
                    // (see KayaOuter below) — without it the XAML
                    // parser fail-fasts (0xC000027B) resolving
                    // TextCommandBarFlyout. The minimal template keeps
                    // the widget free of chrome resources kaya doesn't
                    // ship.
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
                        // occurrence synchronously (or, for SetProp,
                        // deliberately not at all) — this late raise
                        // is its shadow. See entry_swallow.
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
                        // The ledger sees it BEFORE the app does (§3) —
                        // and it is also the party that decides whether
                        // anything happened at all (see the no-change
                        // guard there).
                        if bank_text_changed(bank_id, &text) {
                            sink.send_text_tag(&handler_tag, &text);
                        }
                        Ok(())
                    });
                    field.TextChanged(&handler)?;
                    // Paste's enablement is the offer/accepts
                    // intersection AT THE FOCUSED WIDGET, so focus
                    // moving hands it over — deferred a tick, because
                    // a programmatic Focus() inside apply raises this
                    // while CORE is borrowed.
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
                    // Grid and not StackPanel: a StackPanel sizes every
                    // child to its natural extent along the stacking axis
                    // and has no per-child weight of any kind, so
                    // proportional grow is not merely awkward there but
                    // unrepresentable. Grid's star sizing *is* the
                    // contract — a definition of Star(w) takes w/Σw of
                    // what is left after the Auto definitions — so the
                    // weights map across with no arithmetic of our own.
                    //
                    // The cost is that Grid places by attached Row/Column
                    // index rather than by child order, so every
                    // structural change has to restamp them (see
                    // reindex).
                    let grid = Grid::new()?;
                    // Uniform layout default: 8-unit gap between adjacent
                    // children, matching every other backend. Grid spells
                    // it per axis; only the stacking one applies, since
                    // the cross axis holds a single track.
                    grid.SetRowSpacing(8.0)?;
                    core.columns.push(grid.clone());
                    NativeWidget::Column(grid)
                }
                WidgetKind::Row => {
                    let grid = Grid::new()?;
                    grid.SetColumnSpacing(8.0)?;
                    core.rows.push(grid.clone());
                    NativeWidget::Row(grid)
                }
                WidgetKind::Checkbox => {
                    // The box owns its checked bit; Checked/Unchecked
                    // report each flip with the box's identity tag.
                    // WinUI raises them for programmatic SetIsChecked
                    // too — the USER/programmatic split rides
                    // apply_quiet (see that field). The caption is the
                    // CheckBox's content, the same shape as Button.
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
                    // Uncontrolled, like the entry: the slider owns its
                    // position; ValueChanged reports each move with its
                    // identity tag. (WinUI raises it for programmatic
                    // SetValue too, which is what lets the selftest
                    // drag like a user.)
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
                    // The tag is the click's identity, emitted verbatim;
                    // this backend never learns what it means.
                    let tag = tag.expect("buttons carry a click tag");
                    core.buttons.push(tag.clone());
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
                    // The vertical scroll viewport over its ONE child
                    // (the scene enforces the count): ScrollViewer,
                    // the platform's own machinery — ScrollableHeight
                    // and VerticalOffset are the observation sources
                    // and ChangeView the API scroll_end drives.
                    let viewer = ScrollViewer::new()?;
                    // Vertical-only v1: no horizontal scrolling, ever.
                    viewer.SetHorizontalScrollMode(ScrollMode::Disabled)?;
                    viewer.SetHorizontalScrollBarVisibility(ScrollBarVisibility::Disabled)?;
                    viewer.SetVerticalScrollMode(ScrollMode::Enabled)?;
                    core.scrolls.push(viewer.clone());
                    NativeWidget::Scroll(viewer)
                }
                WidgetKind::Progress => {
                    // Display-only, like Label: no tag, no handler.
                    // RangeBase's default span is 0..100; kaya's
                    // fraction contract is 0..=1, set explicitly.
                    let bar = ProgressBar::new()?;
                    bar.SetMinimum(0.0)?;
                    bar.SetMaximum(1.0)?;
                    core.progresses.push(bar.clone());
                    NativeWidget::Progress(bar)
                }
                WidgetKind::Textarea => {
                    // The multi-line editor: a RichEditBox with
                    // AcceptsReturn, PINNED TO PLAIN TEXT — the entry's
                    // exact contract, including the swallow counters
                    // (TextChanged is raised async; entry_swallow /
                    // entry_tags are id-keyed and kind-agnostic, so the
                    // plumbing is shared).
                    //
                    // THE CONTROL IS RICH-CAPABLE AND THE CONTRACT IS
                    // NOT (docs/textarea-foundation-plan.md): every
                    // opinion the RichEdit engine carries is pinned off
                    // in `pin_plain_text`, which also READS ITS PINS
                    // BACK — so a deleted pin is a panic at the first
                    // textarea a scene builds, not a divergence that
                    // ships.
                    let field = RichEditBox::new()?;
                    field.SetAcceptsReturn(true)?;
                    field.SetMinWidth(240.0)?;
                    // A TEXTAREA IS A VIEWPORT ONTO A DOCUMENT, NOT A
                    // DOCUMENT-SHAPED HOLE IN THE LAYOUT — 96 tall, and
                    // the control's own ScrollViewer moves the text
                    // inside it. A MINIMUM alone is not that: WinUI
                    // measures a control in an Auto row against infinite
                    // height and gives it whatever it asks for, so a
                    // textarea with a 40-line document asked for 758
                    // pixels and got them (measured on the VM
                    // 2026-08-06). Nothing scrolled, because nothing
                    // overflowed.
                    //
                    // THE OTHER TWO DESKTOP BACKENDS ALREADY SAY 240x96
                    // — the SwiftUI arm's `.frame(width: 240, height: 96)`
                    // and the GTK arm's `set_size_request(240, 96)` on the
                    // scroller — so this is the third spelling of one
                    // size, not a new opinion. The ranges scene is what
                    // found the divergence: `reveal_range` has nothing to
                    // do in a control that is as tall as its text, and
                    // `expect_revealed ... offscreen` cannot be true
                    // there, on any platform whose textarea grows.
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
                    // discipline — only the delegate type differs, and
                    // neither arm reads the args.
                    let ranges_field = field.clone();
                    let handler = RoutedEventHandler::new(move |_, _| {
                        // D2 FIRST, AND ABOVE THE SWALLOW TEST
                        // (docs/ranges-plan.md D2). A declared highlight
                        // set dies with the text it was declared
                        // against, whatever moved that text — a
                        // keystroke, a paste, kaya's own write, a native
                        // undo — and the swallow counter's whole job is
                        // to hide the last of those from the app. A
                        // clear-on-edit that stood below it would leave
                        // a programmatic write painting a stale set,
                        // which on this control means a set that DRIFTS
                        // with the edit and GROWS when the user types at
                        // its edge.
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
                        // The ledger sees it BEFORE the app does (§3) —
                        // and it is also the party that decides whether
                        // anything happened at all. THIS control is why
                        // that guard exists: a CharacterFormat write
                        // raises TextChanged here, so `highlight_ranges`
                        // would otherwise report an edit the document
                        // never had.
                        if bank_text_changed(bank_id, &text) {
                            sink.send_text_tag(&handler_tag, &text);
                        }
                        Ok(())
                    });
                    field.TextChanged(&handler)?;
                    // D4'S PREMISE, WIRED TO THE ONLY PARTY THAT KNOWS
                    // IT. An input method's composition is live in this
                    // control and on no kaya channel; these two events
                    // are how the control says so, and the select_range
                    // arm reads the answer. They fire for a real IME and
                    // for the harness's `compose` alike, because both go
                    // through the same text store.
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
                    // The 2D layout contract on WinUI's own Grid with
                    // Auto tracks: columns take their natural width,
                    // aligned across rows by the toolkit itself.
                    let grid = Grid::new()?;
                    core.grid_children.insert(id.0, Vec::new());
                    core.grid_cols.insert(id.0, 1);
                    core.grids.push(grid.clone());
                    NativeWidget::Grid2D(grid)
                }
                WidgetKind::Radio => {
                    // The choice contract inline: RadioButtons — the
                    // platform's own group control (string items
                    // render as radio rows). Same quiet-guard stance
                    // as the ComboBox: SelectionChanged cannot tell a
                    // user pick from SetSelectedIndex.
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
                    // The dressed floor: ComboBox — the select's
                    // label children are its OPTIONS, ComboBoxItems
                    // in the popup (see AddChild). Uncontrolled like
                    // the slider for USER picks; programmatic writes
                    // ride the quiet guard because SelectionChanged
                    // cannot tell the two apart.
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
                    // Display-only, like Label: no tag, no handler. The
                    // source arrives as a SetProp blob and decodes
                    // there. Code-only construction, no XAML.
                    let image = Image::new()?;
                    core.images.push(image.clone());
                    NativeWidget::Image(image)
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
            let panel = match core.widgets.get(&parent).expect("scene validated the id") {
                NativeWidget::Column(panel) | NativeWidget::Row(panel) => panel.clone(),
                _ => panic!("kaya: move_child parent is not a container"),
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
            // The Children collection is now in the new order, but on a
            // Grid that collection does not place anything — without the
            // restamp below the move would be invisible, which is
            // precisely what expect_order exists to catch.
            let order = core.child_order.entry(parent).or_default();
            order.retain(|&id| id != child);
            match before {
                Some(anchor) => {
                    let at = order
                        .iter()
                        .position(|&id| id == anchor)
                        .expect("kaya: move_child anchor not among siblings");
                    order.insert(at, child);
                }
                None => order.push(child),
            }
            reindex(core, parent)?;
        }
        ApplyOp::Destroy { id } => {
            // A destroyed anchor takes its context attachment with it
            // (menu ITEMS are never destroyed; the anchor map entries
            // are): a For-row removal must not leave the harness's
            // open-menu pointer dangling. The Stage's activation keeps
            // its own flyout handle through Closed (the staged
            // ruling), so dropping these is safe mid-activation.
            if core.context_roots.remove(&id.0).is_some() {
                core.context_nouns.remove(&id.0);
                core.context_flyouts.remove(&id.0);
                // The dead copy's native instances leave the map too
                // (GTK's Destroy arm parity: it retains item actions
                // against the removed attachment's instances). A
                // For-row removal forces no rebuild, and a detached
                // item still raises Click through its automation peer
                // — the menu probe proves it — so a surviving entry
                // would stay invoke-capable with the dead row's noun
                // until some unrelated menu mutation rebuilt the map.
                purge_context_natives(&mut core.menu_natives, id.0);
                if core.open_context.as_ref().is_some_and(|(w, _)| *w == id.0) {
                    core.open_context = None;
                }
            }
            let widget = core.widgets.remove(&id).expect("scene validated the id");
            core.grow.remove(&id);
            core.child_order.remove(&id);
            if let Some(panel) = core.parents.remove(&id) {
                let children = panel.Children()?;
                let mut index = 0u32;
                if children.IndexOf(&widget.element()?, &mut index)? {
                    children.RemoveAt(index)?;
                }
                // Find the parent by its grid, since only the grid was
                // stored; the surviving siblings all shift up a track.
                let parent = core
                    .child_order
                    .iter()
                    .find(|(_, order)| order.contains(&id))
                    .map(|(&parent, _)| parent);
                if let Some(parent) = parent {
                    core.child_order
                        .entry(parent)
                        .or_default()
                        .retain(|&child| child != id);
                    reindex(core, parent)?;
                }
            }
        }
        ApplyOp::SetWindowProp { window, prop, value } => {
            let target = winui_window(core, window.0)?;
            match (prop, &value) {
                (WindowProp::Title, Value::Str(title)) => {
                    // The window's OWN title, stored EXACTLY as the app
                    // wrote it; while a navigation entry covers it the
                    // entry's title shows, and this one comes back at
                    // pop. The dirty marker is not stored with it — the
                    // composition happens on the way to the OS
                    // (window_caption), so the declared string stays the
                    // app's own bytes (docs/dirty-plan.md D1).
                    core.window_titles.insert(window.0, title.clone());
                    // No `covered` test any more: the caption writer
                    // derives which title shows from the stack itself,
                    // so a covered window re-writes the entry's title
                    // (the same bytes already there) instead of skipping.
                    refresh_caption(core, window.0)?;
                }
                (WindowProp::Inset, Value::F64(units)) => {
                    // LAYOUT, not appearance (docs/styling-plan.md D3):
                    // store it, restamp the mounted roots' padding if any
                    // exist (a pre-mount write is the normal case and the
                    // Mount arm reads the store).
                    core.inset = *units;
                    // Through container_padding and the roots the mount
                    // recorded, rather than straight onto the window's
                    // Content: that Padding also carries the root
                    // container's OWN inset (prop 17) when it declares
                    // one, and a bare write here would drop it. It also
                    // reaches the roots Content is not — a pushed entry's
                    // and an auxiliary window's — which the mount stamps
                    // and this arm used to miss.
                    let roots: Vec<WidgetId> = core.mounted_roots.values().copied().collect();
                    for id in roots {
                        stamp_container_padding(core, id)?;
                    }
                }
                (WindowProp::Dirty, Value::Bool(on)) => {
                    // WINDOWS PUBLISHES NO MODIFIED AFFORDANCE — not in
                    // WinUI, not in the Windows App SDK metadata (all 28
                    // .winmd scanned: the only hits are InteractionTracker
                    // inertia modifiers), not in UIA's WindowPattern. The
                    // caption is the entire surface, and the taskbar shows
                    // nothing either on Windows 11's icons-only default.
                    // So the lowering is the caption, and it is composed
                    // rather than stored (D2).
                    //
                    // ShutdownBlockReasonCreate is the one Win32 API that
                    // NAMES unsaved work, and it is deliberately not used:
                    // it draws no chrome at all, it only changes what the
                    // shell says at shutdown. That is a different feature
                    // wearing this one's word.
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
                (WindowProp::ListDetail, Value::Bool(on)) => {
                    core.list_detail.insert(window.0, *on);
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
        }
        ApplyOp::DestroyWindow { window } => {
            core.window_veto.remove(&window.0);
            core.tearing_down.insert(window.0);
            if let Some(aux) = core.aux_windows.remove(&window.0) {
                // Close() on an already-chrome-closed window errors;
                // the grammar makes destroy the reconciliation, so
                // tolerate it.
                let _ = aux.Close();
            }
            core.tearing_down.remove(&window.0);
            // A destroyed window takes its navigation stack with it.
            for entry in core.nav_stacks.remove(&window.0).unwrap_or_default() {
                core.nav_entries.remove(&entry);
            }
            // ... and its sections, each with ITS stack (the one way
            // a section dies).
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
            // ... and its menu shell/catalog registration (the item
            // MODELS stay — items are never destroyed).
            core.menu_windows.remove(&window.0);
            core.menubars.remove(&window.0);
            core.menu_slots.remove(&window.0);
            core.menu_shells.remove(&window.0);
            core.toolbars.remove(&window.0);
            core.window_titlebars.remove(&window.0);
            core.window_caption_texts.remove(&window.0);
            // The centring's post-condition state goes with the caption it
            // was about (`CaptionTitleAim`). It lives outside CoreState
            // because a layout callback writes it, so it is dropped here
            // by hand rather than by the same line as the maps above.
            CAPTION_TITLE_AIM.with_borrow_mut(|aims| {
                aims.remove(&window.0);
            });
            core.toolbar_buttons.retain(|(w, _), _| *w != window.0);
        }
        ApplyOp::PushEntry { window, entry } => {
            // Materializes covered/incoming: on the stack now, the
            // mount fills and presents it.
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
            // Append-only: a pane joins the window's NavigationView;
            // the mount fills it. First added is selected (mirrored
            // from the core).
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
            // Programmatic and QUIET: the switcher moves under the
            // swallow counter (SelectionChanged raises ASYNC — the
            // echo doctrine, the entry_swallow spelling).
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
                // NavigationView's own Icon slot, the platform's idiom
                // for a switcher entry. Stamped onto the live item when
                // there is one; `refresh_sections` stamps it on the
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
        // chrome to ONE coalesced rebuild per drain (menus_touched) —
        // the rebuild starts from the post-user mirror by
        // construction (docs/traps.md).
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
                // and stay QUIET (the echo doctrine): the rebuild
                // restamps the native state and no Click fires on a
                // programmatic set (the MENU PROBE's first canary).
                MenuProp::Checked => model.checked = crate::protocol::prop_bool(&value),
                MenuProp::Value => model.value = crate::protocol::prop_f64(&value),
                // The phone-promotion hint, INERT on desktop by the
                // ratified design — stored, never materialized here.
                MenuProp::Primary => model.primary = crate::protocol::prop_bool(&value),
                MenuProp::Shortcut => {
                    model.shortcut = crate::protocol::prop_str(&value).to_owned();
                }
                // Icons dress phone promotion; native Windows menu
                // rows carry no icon in this lowering (the section
                // Icon precedent: accepted, day-one slot).
                MenuProp::Icon => {}
                // PLACEMENT is a request this host has nowhere to
                // honor — no dress-owned application menu — so the
                // item stays exactly where the app declared it
                // (DESIGN.md, Menus). BEHAVIOR is not: a clipboard
                // role's activation performs the standard command on
                // the focused widget, and its enablement is the
                // offer/accepts intersection, so the role is recorded
                // and the role items resync now.
                // THE SEMANTIC ICON (docs/styling-plan.md D6). Retained
                // and drawn by the coalesced rebuild, like the label
                // and the chord; `menu_symbol` still reads the
                // materialized item rather than this copy.
                MenuProp::Symbol => {
                    model.symbol = match &value {
                        Value::I64(v) => *v,
                        other => unreachable!("kaya: symbol wants I64, the root passed {other:?}"),
                    }
                }
                MenuProp::Role => {
                    model.role = crate::protocol::prop_str(&value).to_owned();
                    // AN AUTHORED ROLE IS ITSELF THE ARMING. Undo's
                    // enablement moves in a scene that never touches the
                    // clipboard, so the flag cannot be clipboard traffic
                    // any more (see `roles_armed`).
                    core.roles_armed = true;
                    refresh_role_enablement(core);
                }
            }
            core.menus_touched = true;
        }

        ApplyOp::Copy(clip) => {
            core.roles_armed = true;
            // Five formats in ONE open, descending clip value —
            // custom, files, image, html, text — the canonical order
            // (§1), which is preference (first-set) order on this
            // host. EmptyClipboard makes this process the owner;
            // classic SetClipboardData is immediate rendering, so the
            // content outlives the process with no Flush of any kind
            // (measured, tools/win/clipprobe).
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
                    // Raw bytes under the "PNG" registered format —
                    // the Firefox/clip convention, byte-exact both
                    // ways (measured). CF_DIB is a deliberate cut: it
                    // would mean decoding the PNG here, and the
                    // closed set's image is ENCODED BYTES everywhere.
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
            // Answered exactly once; None IS an answer — the
            // universal no (denied, absent, unfocused and
            // nothing-accepted alike). Win32 reads are synchronous
            // pulls, so no async bridge lives here.
            let clip = materialize_clipboard(&accepting)?;
            core.occurrences.send(Occurrence::ClipboardResult { request, clip });
        }
        // A1: a core undo group committed, so the focused editable's
        // native history goes with it (the episode was banked before the
        // clear, so nothing is lost but granularity).
        //
        // THIS IS THE KEYSTONE (§3): every episode begins with an EMPTY
        // native stack, so the native stack can never reach past the
        // current episode's start, "ask the focused text first" IS "ask
        // the most recent first", and the interleave the literature
        // calls selective undo becomes unconstructible rather than
        // merely unlikely. It is load-bearing on THIS lane in a way the
        // plan did not anticipate: WinUI coalesces a whole typing run
        // into ONE native step (measured), so without the clear a single
        // Ctrl+Z would walk back past the group.
        //
        // TARGETLESS BY DESIGN — the record carries a window and no
        // widget, because the core does not know what is focused and
        // this backend does.
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
            // A DECLARATION THAT CHANGES NOTHING WRITES NOTHING, and
            // on this control that is not a micro-optimization: every
            // paint goes through `clear_highlights`, which is a
            // CharacterFormat write over the whole story, and a
            // CharacterFormat write RAISES TextChanged and lands on the
            // control's own undo stack. An app that re-declares from its
            // text_changed fold — which is what a find bar is — therefore
            // paid a spurious edit report and a spurious undo record for
            // every keystroke, with an empty set and nothing painted.
            let painted = HIGHLIGHT_TEXT.with_borrow(|map| map.contains_key(&id.0));
            if ranges.is_empty() && !painted {
                return Ok(());
            }
            paint_highlights(&field, &ranges)?;
            // D2's compare needs the text these offsets were validated
            // against, and the control is holding it RIGHT NOW: a text
            // write earlier in this same batch has already landed (the
            // ops are applied in order, and the core read its own
            // batch's writes to validate against exactly this string).
            //
            // AN EMPTY DECLARATION LEAVES NO ENTRY: nothing is painted,
            // so there is no stale set for a later edit to drop — and an
            // entry kept here would send `drop_stale_highlights` into
            // `clear_highlights` on the next keystroke, which is the very
            // write the branch above exists to avoid.
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
            // D4, AND THIS BACKEND IS THE ONLY PARTY THAT CAN ENFORCE IT.
            // An input-method composition is live in the control and on
            // no kaya channel, so the core cannot know and the app
            // cannot avoid the race: the same app code is correct at
            // 10:00:00.000 and "wrong" four milliseconds later. Moving
            // the selection now would end the composition and commit the
            // user's half-typed word into the document — data loss
            // shaped like a feature, and it would shift every later
            // offset by the committed length. Refused as a no-op under a
            // named reason, never a panic: the app wrote correct code
            // and lost a race with a human being.
            if COMPOSING.with_borrow(|live| live.contains(&id.0)) {
                eprintln!("kaya: select_range refused: ime_composition (widget {})", id.0);
                return Ok(());
            }
            field
                .TextDocument()?
                .Selection()?
                .SetRange(range.start as i32, range.stop as i32)?;
        }
        ApplyOp::SetTypeface(req) => {
            // TWO ROUTES, BECAUSE THE PLATFORM HAS TWO KINDS OF TEXT and
            // no single write reaches both: the CONTROLS take the family
            // from `ContentControlThemeFontFamily`, which an app-level
            // dictionary can redefine, while a TextBlock takes it from a
            // local value only. See `typeface_dictionary` and
            // `text_block` for which failure each one is against.
            apply_typeface(&req)?;
        }
        ApplyOp::SetBrand { accent } => {
            // VALUES IN, VALUES OUT: the core derived the eleven words
            // (crates/kaya/src/brand.rs) and this arm re-derives none of
            // them — no opacity ladder, no foreground rule, no second
            // opinion about what "lighter" means. See `brand_dictionary`
            // for which word lands in which stop and why.
            apply_brand(&accent)?;
        }
        ApplyOp::RevealRange { id, range } => {
            let Some(field) = textarea_by_id(core, id.0) else {
                return Ok(());
            };
            // `PointOptions::None` is the MINIMUM scroll that brings the
            // range into view, which is every other backend's semantics
            // (AppKit's scrollRangeToVisible, GTK's scroll_to_iter). The
            // enum's other placements are opinions about where on screen
            // a revealed range should sit, and kaya has none: the verb
            // asserts containment, never the viewport.
            //
            // A scroll disturbs neither the selection nor a composition,
            // so reveal has no refusal arm and needs none.
            field
                .TextDocument()?
                .GetRange(range.start as i32, range.stop as i32)?
                .ScrollIntoView(PointOptions::None)?;
        }
        ApplyOp::PresentSaveDialog(spec) => {
            // The Shell's SAVE dialog — the picker's presentation with the
            // multiplicity flag replaced by a name, on the SAME apartment,
            // the SAME queue and doorbell, and the same one-live-dialog
            // rule. See `file_save_show` for why it is IFileSaveDialog and
            // not the WinRT FileSavePicker, and why it hands back a path
            // to a file that does not exist.
            // THE WINDOW IS AN APPLY-SIDE CERTAINTY and stays one now
            // that the resolver is total: same-batch ordering means the
            // create reached this backend first, so a miss here is a
            // core bug and dies naming it. Only the WinRT casts below
            // are tolerated (hwnd 0 = an unowned dialog).
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
                // The SAME armed directory the picker reads, taken the
                // same way: `file_dialog_goto` arms one slot and whichever
                // dialog presents next consumes it, because a dialog reads
                // its folder only at presentation.
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
            // The Shell's common item dialog, which is what Windows
            // means by a file picker.
            //
            // NOT FileOpenPicker, and the reason is the scene: its
            // SuggestedStartLocation is a PickerLocationId ENUM of
            // well-known folders, so it cannot be pointed at
            // <temp>/kaya-picked-<pid> at all. IFileOpenDialog::SetFolder
            // takes any shell item. DESIGN.md anticipated this shape —
            // "honorable on four platforms and not the fifth" — and it
            // decides the API rather than being worked around.
            //
            // ON THE DIALOG APARTMENT'S THREAD, because Show() is modal
            // and runs a nested message loop. Blocking the UI thread
            // inside apply would stall the dispatcher for as long as the
            // picker is up, and this scene exists to prove the app stays
            // alive while a pick is outstanding. The owner HWND still
            // makes it modal to the user; only kaya's thread is spared.
            // ONE apartment serves every dialog and outlives them all —
            // see `dialog_apartment` for the failure that shape fixes.
            // The window is an apply-side certainty (see the save arm);
            // only the WinRT casts are tolerated.
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
            // ShowAsync completion is the ONE emit site — Primary/
            // Secondary map to action indices, everything else
            // (Esc, the close button, Hide) completes as None = the
            // cancel slot — routed through capi::alert_resolved, the
            // shared retire path.
            // The one resolver, so the miss says what it measured; the
            // `?` carries it to apply's caller, which panics naming it.
            let host = winui_window(core, spec.window.0)?;
            // A dialog needs the host's LIVE XamlRoot, and a guest
            // can request one within milliseconds of launch — before
            // the content island exists (caught live 2026-07-22 the
            // moment the settles stopped hiding it: the expect
            // aborted the UI thread). Not ready yet: re-enqueue this
            // whole present on the dispatcher and let the queue load
            // the content first; the harness's expect_alert retries
            // until the dialog is really up.
            let root_live = host
                .Content()
                .and_then(|c| {
                    let root: FrameworkElement = windows_core::Interface::cast(&c)?;
                    root.XamlRoot()
                })
                .is_ok();
            if !root_live {
                // Re-present when the root actually loads — its
                // Loaded event is the platform's own "the island is
                // up" signal. (A dispatcher self-re-enqueue loop
                // STARVES the queue that would do the loading; a
                // timer is a guess. This is backend-internal — the
                // harness's uniform mechanism stays bounded polling.)
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
                    // The result must ride THIS backend's sink (the
                    // guest listens there); capi::alert_retire is
                    // only the liveness gate.
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
                let parent = core
                    .child_order
                    .iter()
                    .find(|(_, order)| order.contains(&id))
                    .map(|(&parent, _)| parent);
                if let Some(parent) = parent {
                    reindex(core, parent)?;
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
                    // An option label's text lands on its ComboBox
                    // row too, as string content (see select_options
                    // for why never a TextBlock) — or its radio row.
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
                    // ONE ARM FOR BOTH, still: entry and textarea sit on
                    // different native types now, and `Editable` is what
                    // keeps that from becoming two spellings of one rule.
                    let field = widget.editable().expect("the arm matched a text widget");
                    // Quiet: a property write is configuration, not a
                    // user edit — and TextChanged is raised async, so
                    // the flag is a counter (see entry_swallow).
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
                    // A programmatic write is quiet (uniform
                    // semantics: only the user path emits).
                    core.apply_quiet
                        .store(true, std::sync::atomic::Ordering::Relaxed);
                    let write = combo.SetSelectedIndex(v as i32);
                    core.apply_quiet
                        .store(false, std::sync::atomic::Ordering::Relaxed);
                    write?;
                }
                // THE UNIVERSAL PROPS. Every other arm keys on a
                // (kind, prop) pair; these name something every element
                // has, so they match the prop alone.
                //
                // AutomationProperties is UIA's setter side: AutomationId
                // is the automation identifier (never spoken) and Name is
                // what a screen reader says. Unlike GTK, WinUI publishes a
                // settable identifier, so the harness read below matches
                // by identity rather than by ordinal.
                (w, Prop::A11yId, Value::Str(id)) => {
                    let element = w.element()?;
                    bindings::Microsoft::UI::Xaml::Automation::AutomationProperties::SetAutomationId(
                        &element,
                        &windows_core::HSTRING::from(id.as_str()),
                    )?;
                }
                // Empty means unset, and unset stays untouched: UIA
                // derives a control's name from its content, and writing
                // "" would SILENCE it.
                (w, Prop::A11yLabel, Value::Str(label)) if !label.is_empty() => {
                    let element = w.element()?;
                    bindings::Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(
                        &element,
                        &windows_core::HSTRING::from(label.as_str()),
                    )?;
                }
                // The HINT: UIA's HelpText, the slot for what acting on
                // the control does. Empty means unset, like the name.
                (w, Prop::A11yHint, Value::Str(hint)) if !hint.is_empty() => {
                    let element = w.element()?;
                    bindings::Microsoft::UI::Xaml::Automation::AutomationProperties::SetHelpText(
                        &element,
                        &windows_core::HSTRING::from(hint.as_str()),
                    )?;
                }
                // ACCEPTANCE IS PER-WIDGET (DESIGN.md, Clipboard):
                // the list drives the paste split and Paste's
                // enablement. Kind-agnostic like the universal props
                // — the root already restricted it to editables and
                // validated the string. Empty means unset, the
                // universal prop rule.
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
                    reflow_grid(core, id.0)?;
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
                (NativeWidget::Column(grid), Prop::Spacing, Value::F64(gap)) => {
                    // A column's children stack as rows; the gap is the
                    // row spacing (expect_fills reads it back live).
                    grid.SetRowSpacing(gap)?;
                }
                (
                    NativeWidget::Column(_) | NativeWidget::Row(_) | NativeWidget::Grid2D(_),
                    Prop::Inset,
                    Value::F64(pad),
                ) => {
                    // A container's own padding, one level down from the
                    // window inset (docs/styling-plan.md D3). One arm for
                    // all three container kinds because all three ARE
                    // Grids here — Column and Row are star-sized Grids so
                    // that `grow` can be a track weight — and Padding is
                    // the same property on each. Stored and stamped
                    // through container_padding: on a mounted root this
                    // Padding carries the window inset too.
                    core.container_insets.insert(id, pad);
                    stamp_container_padding(core, id)?;
                }
                (NativeWidget::Column(_), Prop::Align, Value::I64(mode))
                | (NativeWidget::Row(_), Prop::Align, Value::I64(mode)) => {
                    core.aligns.insert(id, mode);
                    reindex(core, id)?;
                }
                (NativeWidget::Row(grid), Prop::Spacing, Value::F64(gap)) => {
                    grid.SetColumnSpacing(gap)?;
                }
                (NativeWidget::Slider(slider), Prop::Min, Value::F64(v)) => {
                    slider.SetMinimum(v)?;
                }
                (NativeWidget::Slider(slider), Prop::Max, Value::F64(v)) => {
                    slider.SetMaximum(v)?;
                }
                (NativeWidget::Image(image), Prop::Source, Value::Blob(blob)) => {
                    // Encoded bytes in, native decode: the bytes go
                    // through an InMemoryRandomAccessStream (via
                    // DataWriter) into a BitmapImage. SetSource is the
                    // synchronously-callable path on the UI thread;
                    // the one async hop is DataWriter.StoreAsync,
                    // blocked on .join() — an in-memory store completes
                    // promptly, but this friction is why runtime
                    // verification happens on the VM. Any failure
                    // (decode included) leaves the placeholder — no
                    // Source, image_size reads 0x0 — never a panic.
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
                // roles, each lowered to the platform's OWN emphasis and
                // never to a colour or a size kaya picked. The legal
                // (kind, role) pairs sit in the PATTERNS, so a role on a
                // kind it does not fit falls to this match's catch-all
                // and dies naming the prop and the value — the root
                // already refused it at declare time, in its own words,
                // and this is the second wall rather than the first.
                (NativeWidget::Button { button, .. }, Prop::Role, Value::I64(2)) => {
                    // PROMINENT — the one-primary-action affordance, and
                    // on this platform it is first class: a single keyed
                    // Style in CommonStyles/Button_themeresources.xaml.
                    // Its background is `AccentFillColorDefaultBrush` and
                    // its foreground `TextOnAccentFillColorPrimaryBrush`,
                    // which is to say it is painted by the accent stops
                    // the brand lowering wrote — nothing here picks a
                    // colour, and a brandless app gets the user's
                    // Windows accent, which is the correct default.
                    button.SetStyle(&theme_resource::<Style>("AccentButtonStyle")?)?;
                }
                (NativeWidget::Button { caption, .. }, Prop::Role, Value::I64(1)) => {
                    // DESTRUCTIVE, AND FLUENT SHIPS NO DESTRUCTIVE
                    // BUTTON. The complete set of keyed Button styles is
                    // DefaultButtonStyle, AccentButtonStyle and the two
                    // navigation-back ones; there is no
                    // DestructiveButtonStyle, no DangerButtonStyle, no
                    // CriticalButtonStyle. Fluent expresses
                    // destructiveness through DIALOG STRUCTURE — "all
                    // dialogs should have a safe, non-destructive
                    // action" — rather than through a red button.
                    //
                    // What the platform DOES have is a severity palette:
                    // `SystemFillColorCritical*` is what InfoBar paints
                    // an error with. So kaya's lowering is the
                    // platform's own critical colour on the button's
                    // TEXT, with the button chrome left standard. That is
                    // a choice among expressible options rather than a
                    // capability limit, and it is written down here
                    // rather than pretending this toolkit has an
                    // affordance it does not (D4).
                    //
                    // ON THE CAPTION, NOT ON THE BUTTON: the framework's
                    // Button template re-points the content presenter's
                    // Foreground in its PointerOver and Pressed states,
                    // so a value set on the control would show in the
                    // resting state alone. A role is not a state — it is
                    // what the button MEANS — and the caption is the
                    // text surface this backend owns, so a local value
                    // there is what carries the colour across the
                    // framework's own state changes.
                    caption.SetForeground(&theme_resource::<Brush>(
                        "SystemFillColorCriticalBrush",
                    )?)?;
                }
                (NativeWidget::Label(label), Prop::Role, Value::I64(3)) => {
                    // THE HEADING ROLE IS TWO FACTS AT ONCE, the same two
                    // every backend lowers it to: the platform's heading
                    // TEXT TIER and the platform's heading ACCESSIBLE
                    // fact. Neither implies the other here — a style
                    // changes no UIA property, and HeadingLevel changes
                    // no pixel — so both are written, and a scene that
                    // reads only the second is reading the half that
                    // Narrator users depend on.
                    //
                    // THE ACCESSIBLE FACT IS UIA's OWN HeadingLevel, the
                    // property that gives real heading NAVIGATION (a
                    // client's next-heading command finds it). The two
                    // things it is not: `SetLevel` is a different UIA
                    // property — an item's depth in a hierarchy — and
                    // `SetLocalizedControlType` would only make Narrator
                    // SAY "heading" while navigation still skipped it,
                    // which is a lie in the shape of a fix.
                    //
                    // `Level2` and not `HeadingLevel2`: the enum's
                    // members are `None`, `Level1`..`Level9`
                    // (bindings.rs, generated from the vendored
                    // Microsoft.UI.Xaml.winmd — the docs' `HeadingLevel1`
                    // spelling is the UWP `Windows.UI.Xaml` one). Level 2
                    // and not 1 for the reason every backend picks the
                    // section tier: the window itself is the document's
                    // level 1, and a kaya heading heads a section inside
                    // it.
                    bindings::Microsoft::UI::Xaml::Automation::AutomationProperties::SetHeadingLevel(
                        label,
                        bindings::Microsoft::UI::Xaml::Automation::Peers::AutomationHeadingLevel::Level2,
                    )?;
                    // THE TEXT TIER IS A STYLE KEY, NEVER A FONT SIZE.
                    // `SubtitleTextBlockStyle` is Fluent's own
                    // section-heading step of the XAML type ramp
                    // (BasedOn BaseTextBlockStyle like every other step),
                    // so the size, weight and line height are the
                    // platform's scale — picking numbers out of that
                    // ramp is exactly what D4's ceiling refuses.
                    label.SetStyle(&theme_resource::<Style>("SubtitleTextBlockStyle")?)?;
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
                reflow_grid(core, parent.0)?;
                return Ok(());
            }
            // A radio's label children are its OPTIONS: string rows
            // of the group's Items vector (strings render as radio
            // rows; the label's SetProp text lands with SetAt), and
            // the label leaves the harness's label registry.
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
            // A select's label children are its OPTIONS: ComboBoxItems
            // in the popup, never children of a panel. The row gets
            // its own TextBlock (the label's SetProp text lands on
            // both), the label's native TextBlock stays unparented,
            // and the label leaves the harness's label registry —
            // options are the select's data, so they must not shift
            // every later label's index.
            if let NativeWidget::Select(combo) =
                core.widgets.get(&parent).expect("scene validated the id")
            {
                let combo = combo.clone();
                let item = ComboBoxItem::new()?;
                if let NativeWidget::Label(label) =
                    core.widgets.get(&child).expect("scene validated the id")
                {
                    // The row initializes from the label's CURRENT
                    // text: children-first sugars (OCaml, Haskell)
                    // set the text BEFORE this AddChild (the GTK
                    // empty-row lesson); SetProp covers later writes.
                    item.SetContent(&PropertyValue::CreateString(&label.Text()?)?)?;
                    let label = label.clone();
                    core.labels.retain(|x| x != &label);
                }
                combo.Items()?.Append(&item)?;
                core.select_options.insert(child.0, (combo, item));
                return Ok(());
            }
            let panel = match core.widgets.get(&parent).expect("scene validated the id") {
                NativeWidget::Column(panel) | NativeWidget::Row(panel) => panel.clone(),
                _ => panic!("kaya: add_child parent is not a container"),
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
            }
            core.parents.insert(child, panel);
            core.child_order.entry(parent).or_default().push(child);
            // A new child means a new track and a shifted set of indices.
            reindex(core, parent)?;
        }
        ApplyOp::Mount { window, root } => {
            let widget = core.widgets.get(&root).expect("scene validated the id");
            // Both handles are taken here, under the widget borrow: a
            // WinRT handle is refcounted and outlives the map it came
            // from, which is what lets the stamp below take the core
            // state mutably.
            let element = widget.element()?;
            let panel = match widget {
                NativeWidget::Column(panel) | NativeWidget::Row(panel) => Some(panel.clone()),
                _ => None,
            };
            if let Some(panel) = panel {
                // The normalized root inset — now the window's OWN
                // (wprop 8, docs/styling-plan.md D3), 16 unless the app
                // says otherwise, INSIDE the root (Grid.Padding is
                // inside ActualSize, so the root still fills its island
                // and expect_root_fills holds). Recorded as a mounted
                // root FIRST, because the same Padding also carries this
                // container's own inset when it declares one and
                // container_padding is what adds the two.
                core.mounted_roots.insert(window.0, root);
                stamp_container_padding(core, root)?;
                // Baseline compensation needs REAL text metrics,
                // and at apply time the grid has never had a true
                // layout pass (a detached or just-attached measure
                // reads zeros — margins came out ~0 and the row
                // classified start on the first two Windows runs).
                // Loaded fires after the first real layout; the
                // one-shot re-runs reindex for every
                // baseline-aligned container with live metrics.
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
            }
            // The target is a SURFACE: a navigation entry presents
            // in-window (the push already stacked it; the mount fills
            // it), the primary is the window's own root, an auxiliary
            // presents its window.
            if core.section_panes.contains_key(&window.0) {
                // A section presents in-window: added to the set
                // already; the mount fills its pane. BUT THE WINDOW IT
                // SITS IN MAY BE AN AUXILIARY NOTHING HAS PRESENTED: a
                // sections window mounts into its SECTIONS and never
                // into a root, so the "Mounting presents" Activate
                // below could not fire for it and CreateWindow's
                // materializes-hidden became permanent — a window the
                // app opened and the user never saw, with every
                // observation still passing. The section's mount is
                // that window's presentation moment (the same hole the
                // mac depth found, 2026-08-15).
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
                    // A command ACTS LIKE THE USER, and its echo must
                    // stay ORDERED with what follows — TextChanged is
                    // raised async, so the echo is emitted here
                    // synchronously and the late raise is swallowed
                    // (see entry_swallow).
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
                    // The materialization class (see traps.md): an
                    // element not yet in the live tree cannot take
                    // focus, and the call's bool would be discarded —
                    // a mount-tx focus would silently drop. Not
                    // loaded yet: one-shot re-run from the element's
                    // own Loaded, the alert/baseline pattern.
                    let element = widget.element()?;
                    let fe: FrameworkElement = windows_core::Interface::cast(&element)?;
                    if fe.IsLoaded()? {
                        let _ = element.Focus(FocusState::Programmatic)?;
                    } else {
                        // One-shot (the alert pattern): Loaded
                        // re-fires on every re-attach, and a stale
                        // handler must not steal focus later.
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
// The bootstrap DLL ships next to the executable; it locates the installed
// Windows App Runtime and wires it into the process. Loaded dynamically so
// kaya needs no import lib from the NuGet package.

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
    // NO CoUninitialize IS DECLARED HERE, and that is the fix rather
    // than an omission: the one apartment this process opens for
    // pickers is meant to end with the process. `dialog_apartment`
    // carries the measurement.
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
    // back once it is ready; the callback runs on the UI thread. Building
    // the core is deferred through the dispatcher so it runs after the
    // launch sequence completes.
    let callback = ApplicationInitializationCallback::new(move |_params| {
        // XAML forwards render-loop errors to CoreApplication; with no
        // handler there, RoReportUnhandledError fail-fasts the process
        // (0xC000027B) — a channel Application.UnhandledException never
        // sees. This app has one known, survivable error on that
        // channel: deferred theme XAML (the built-in TextBox style)
        // cannot instantiate without an IXamlMetadataProvider, which a
        // code-only Application does not have. Propagate() rethrows the
        // stowed HRESULT here, marking it observed; we log it and the
        // control proceeds with its local (minimal) style.
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
        // The aggregation contract, asserted where it can fail loudly:
        // Application.Current() is an identity QI for IApplication
        // through the OUTER — if the outer ever stops delegating
        // unknown IIDs to the inner, every control that consults
        // Current at runtime (NavigationView's ResourceAccessor was
        // the first found) stow-crashes minutes later with a bare
        // E_NOINTERFACE instead of failing here, at the source
        // (docs/traps.md, the aggregation trap).
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
                // Keep the process alive: backends are appliers, and
                // the exceptions seen here in practice are resource
                // lookups for control chrome (flyouts) that unpackaged
                // apps resolve imperfectly. Logged, never silent.
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
    // destructors still run during process::exit on Windows (TLS
    // callbacks), and releasing XAML COM objects into the dead apartment
    // is an access violation. Announce shutdown, then leak the COM
    // references; the process reclaims everything anyway.
    CORE.with_borrow_mut(|core| {
        if let Some(core) = core.take() {
            core.occurrences.send(Occurrence::Shutdown);
            std::mem::forget(core);
        }
    });
    // Unwind the App Runtime while the process is still healthy; leaving
    // it for DLL_PROCESS_DETACH crashes inside Microsoft.UI.Xaml.dll in
    // hosted processes (observed with python.exe).
    bootstrap_shutdown();
    EXIT_CODE.load(std::sync::atomic::Ordering::Relaxed)
}

// Receiver<Transaction> is !Sync, and the WinRT callback signature forces
// the closure to be Fn + Send. The receiver crosses into the UI thread
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
// (IWindowNative, one method past IUnknown). The generated bindings
// do not project AppWindow, and Win32 placement via the HWND is all
// recording mode needs.
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
        // Paste's enablement moves when the clipboard does, and the
        // system's own change signal is WM_CLIPBOARDUPDATE — a
        // format listener, not the ancient viewer chain. Registered
        // on every kaya window; the deferred refresh no-ops in
        // scenes that never armed the clipboard.
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

    /// The gone-check's three entries, declared here beside the rest
    /// rather than by enabling Win32_UI_WindowsAndMessaging: this file
    /// already names the handful of user32 calls it needs, and the
    /// feature would pull a very large surface for three.
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
    // The shortcut verb's REAL dispatch: foreground the guest and put
    // the chord on the system input queue, so XAML's own
    // KeyboardAccelerator machinery routes it (docs/traps.md: the
    // injection is OS-global; menu legs run serially for exactly this
    // reason).
    fn SetForegroundWindow(hwnd: isize) -> i32;
    fn GetForegroundWindow() -> isize;
    /// The clipboard-change signal Paste's enablement follows
    /// (WM_CLIPBOARDUPDATE to every registered listener). Raw beside
    /// its WNDPROC consumers, matching this block's convention.
    fn AddClipboardFormatListener(hwnd: isize) -> i32;
    fn keybd_event(vk: u8, scan: u8, flags: u32, extra: usize);
    /// The `type` verb's character-to-keystroke mapping, asked of the
    /// ACTIVE KEYBOARD LAYOUT rather than hard-coded: the low byte is
    /// the virtual key, the high byte the shift state (bit 0 shift,
    /// bit 1 control, bit 2 alt). A table of our own would be a US
    /// layout wearing a platform's name — `!` and `"` do not live on
    /// the same keys everywhere — and the verb's contract is printable
    /// ASCII, not a keycap set.
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

    /// The harness's own calls: the sampler window that lets it ask an
    /// STA object a question from another thread, and the posts that
    /// drive the dialog. EVERY ONE IS GATED, because WndClassW is, and
    /// a shipped app carries none of this — check-targets builds both
    /// feature configurations for exactly this reason.
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

/// Every window this process is really holding, for the sentence
/// below: `#0, #1`. A resolver miss prints WHAT IT SAW — the two
/// causes it cannot tell apart are "the id is wrong" and "the apply
/// has not run yet", and the live list is the evidence that separates
/// them for the reader (an id that never appears is a typo; one that
/// appears a moment later was a race).
fn live_windows(core: &CoreState) -> String {
    let mut ids: Vec<u64> = std::iter::once(0).chain(core.aux_windows.keys().copied()).collect();
    ids.sort_unstable();
    ids.iter()
        .map(|id| format!("#{id}"))
        .collect::<Vec<_>>()
        .join(", ")
}

/// A window by kaya id — TOTAL, because window materialization is
/// asynchronous and a harness read racing the apply is the normal
/// state of affairs, not a bug.
///
/// This used to `expect("scene validated the window id")`, and that
/// comment's assumption was exactly the bug: the scene DID validate
/// the id, but `create_window` reaches this backend as an apply, so a
/// read that arrives first found nothing and killed the process.
/// Measured 2026-08-16: two windows legs died that way (five on linux)
/// when a scene asserted on an aux window without a count barrier.
///
/// The error is what makes the read RETRYABLE: `on_ui_read` hands it
/// back to the harness, which turns it into a non-match and polls
/// again (that function's doc comment is the same rule, one layer up).
/// Actions and applies go through `on_ui`/`on_ui_mut`, which panic on
/// an error — from the HARNESS thread, where a panic can unwind — so
/// the apply-side wall the ledger asked for is still there, and now it
/// names what it measured.
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

/// The advisory size request's Win32 materialization: DIP -> physical
/// via the window's DPI, applied to the CLIENT area (the request is a
/// content size) by carrying the current chrome delta onto the outer
/// frame. A request, never a guarantee — the shell keeps the last
/// word (DESIGN.md, Presentation contexts).
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
    // THE ONE CAPTION WRITE THAT DOES NOT GO THROUGH refresh_caption,
    // and it cannot: CORE does not exist yet — this is the placeholder
    // the window wears between materializing and the app's first
    // transaction. Nothing is declared at this point, so there is no
    // dirty flag to compose and no title to preserve; the app's own
    // title replaces this through the writer a moment later.
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

    // Closing the window exits the app, matching the AppKit backend's
    // terminate-after-last-window-closed behavior.
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
    // KAYA_SELFTEST. The feature is off by default so users do not
    // ship the scene interpreter, which means a runner that forgets
    // `--features harness` would otherwise start the app, run no
    // steps, print no verdict, and hang until its timeout — the
    // silent-no-op shape this repo keeps paying for. Fail loudly
    // instead, naming the fix.
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
            transactions: tx_rx,
            scene: Scene::new(),
            occurrences: occ_tx,
            pending_dialog_dir: RefCell::new(None),
            widgets: HashMap::new(),
            parents: HashMap::new(),
            buttons: Vec::new(),
            checkboxes: Vec::new(),
            labels: Vec::new(),
            entries: Vec::new(),
            entry_ids: Vec::new(),
            entry_swallow: HashMap::new(),
            entry_tags: HashMap::new(),
            sliders: Vec::new(),
            images: Vec::new(),
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
            rows: Vec::new(),
            child_order: HashMap::new(),
            grow: HashMap::new(),
            aligns: HashMap::new(),
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
            list_detail: HashMap::new(),
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

/// The harness stage: WinUI's native calls, each hopping to the
/// dispatcher. Programmatic SetIsChecked/SetText/SetValue raise the
/// real event paths; clicks emit the button's stored tag, the same
/// bytes the pointer path would.
/// PowerShell single-quoted literal: the only escape is '' for '.
#[cfg(feature = "harness")]
fn ps_quote(s: &str) -> String {
    s.replace('\'', "''")
}

/// The foreign clipboard tool's one entry: powershell.exe, PINNED —
/// pwsh silently lacks the entire clipboard cmdlet surface this lane
/// uses (-AsHtml, -LiteralPath, -Format, -TextFormatType), so the
/// edition is asserted INSIDE the script; a future shell swap fails
/// loudly here instead of reading empty (the guard, not a memory).
/// Runs on the harness thread — a child process on the app thread
/// would trip the stall watchdog.
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

    /// The observation flavor: a read that errors mid-materialization
    /// (a null Content cast before the first layout, a not-yet-live
    /// XamlRoot) is a RETRYABLE miss for the harness's bounded polls,
    /// never a panic — a panic here either kills the harness thread
    /// or, worse, aborts the process when it crosses a dispatcher
    /// callback (caught live 2026-07-22: window/grow/panels legs
    /// fail-fasted or hung the moment the settles stopped hiding the
    /// materialization window). Actions keep on_ui: their targets are
    /// proven by a preceding expect, so an error there IS a bug.
    /// Foreground the guest and CONFIRM it before injecting anything.
    ///
    /// SHARED BY THE TWO VERBS THAT PUT REAL KEYS ON THE SYSTEM INPUT
    /// QUEUE — `shortcut` and `type` — because the queue is OS-GLOBAL
    /// and the failure it protects against is the same for both:
    /// keystrokes landing in whatever window happens to be frontmost.
    /// Failing to take the foreground fails the leg LOUDLY rather than
    /// spraying input at a bystander. (A bounded confirmation poll, not
    /// a lifecycle sleep.)
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
                // An ACTIVE MENU categorically blocks SetForegroundWindow
                // — "no menus are active" is one of the documented
                // preconditions, so retrying and the ALT tap below can
                // never win against an open Start menu. ESC dismisses it.
                // This is not hypothetical: an unattended run on
                // 2026-07-25 lost two legs to a Start menu left open by
                // an earlier wedged run, which held the foreground until
                // something else happened to dismiss it. Nothing about
                // that required a human at the VM.
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

    /// THE UI THREAD WITHOUT THE CORE — for a call that must not be
    /// running inside a `CORE` borrow when it completes.
    ///
    /// `on_ui`, `on_ui_mut` and `on_ui_read` all hand their closure a
    /// borrow that lives for the whole dispatched call. A WinRT call
    /// that completes SYNCHRONOUSLY inside one then re-enters `CORE`
    /// from its completion handler and aborts the process, because a
    /// panic crossing a dispatcher callback cannot unwind:
    ///
    ///   panicked at winui/mod.rs: RefCell already borrowed
    ///   panic in a function that cannot unwind
    ///
    /// MEASURED on the VM 2026-08-10 (the editor leg): `ContentDialog::
    /// Hide()` on a dialog that never finished loading completes
    /// `ShowAsync` right there, and `ShowAsync`'s completion takes the
    /// mutable borrow. WinRT handles are refcounted, so the shape that
    /// works is: read what you need under a borrow, drop it, drive the
    /// control here.
    fn on_ui_bare<T: Send + 'static>(
        f: impl FnOnce() -> windows_core::Result<T> + Send + 'static,
    ) -> windows_core::Result<T> {
        let (tx, rx) = std::sync::mpsc::channel();
        let dispatcher = DISPATCHER.get().expect("the dispatcher is up");
        let cell = std::sync::Mutex::new(Some((f, tx)));
        let handler = DispatcherQueueHandler::new(move || {
            if let Some((f, tx)) = cell.lock().unwrap().take() {
                let _ = tx.send(f());
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

/// The element a `kind#index` target names, from the per-kind registry
/// every WinUI verb resolves through — creation order, which is what
/// `kind#index` means. `None` is "no such target", never a panic.
///
/// It was `ax`'s inline match until `widget_fills` needed the same
/// answer. Two copies of a fourteen-arm registry table is exactly the
/// shape that ships one kind wired to the wrong Vec (the row-versus-
/// column misresolution child_shares shipped is the same class), so
/// there is one.
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
        // Buttons live in the registry as CLICK TAGS, not widgets, and
        // the tag is captured in the click closure rather than stored
        // on the Button — so there is no tag->widget link to follow.
        // Both orderings are CREATION order though: core.buttons is a
        // push-order Vec and WidgetId is assigned in sequence, so the
        // Nth button widget by ascending id is the Nth entry. The ids
        // must be sorted explicitly: core.widgets is a HashMap and its
        // iteration order is arbitrary.
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
        // Resolve SEMANTICALLY against the model tree — the OPEN
        // context menu exclusively while one is presented, the
        // primary window's catalog otherwise — then drive the REAL
        // invoke pipeline on the materialized item. For a context
        // activation the staged ruling applies: register Closed
        // BEFORE invoking, keep the flyout handle through Closed, and
        // await it before another open may start. No sleeps.
        let wait = Self::on_ui_mut(move |core| {
            // THE HARNESS-ACTIVATION REFRESH (the mac finding, §3),
            // and here it is load-bearing beyond a grayed row: the
            // invoke pipeline goes through the item's automation
            // peer, and Invoke() on a still-disabled item THROWS
            // inside a dispatcher callback — a stowed exception,
            // 0xC000027B, process gone. Focus changes refresh
            // enablement on a DEFERRED tick, so without this a
            // focus-then-activate script races that tick (measured:
            // the clipboard scene's first Edit>Paste, rust leg).
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
        // is what an assistive client (Narrator, an automation harness)
        // sees. Correspondence is by IDENTITY — WinUI publishes a
        // settable AutomationId, unlike GTK where none exists below 4.22
        // and the read has to match by ordinal.
        Self::on_ui_read(move |core| {
            use bindings::Microsoft::UI::Xaml::Automation::Peers::{
                AutomationHeadingLevel, FrameworkElementAutomationPeer,
            };
            // Resolve the ELEMENT from the per-kind registry, the way
            // every other WinUI verb does (read_label/read_text), with
            // try_resolve so an out-of-range index reports "no such
            // target" instead of panicking. The earlier version reused
            // widget_id_for_target, which serves context_open and
            // handles Label ONLY — every other kind hit its panic!,
            // inside the UI closure, surfacing as an opaque RecvError.
            use crate::harness::{try_resolve, TargetKind as K};
            let element: bindings::Microsoft::UI::Xaml::UIElement =
                match target_element(core, target)? {
                    Some(e) => e,
                    None => return Ok("<no such target>".to_owned()),
                };
            let fe: bindings::Microsoft::UI::Xaml::FrameworkElement = element.cast()?;
            // FromElement returns an EXISTING peer; a plain container
            // (Row/Column are Grids) has none until one is made, so it
            // reported "<not in the accessibility tree>" for a group
            // that UIA is perfectly willing to describe. CreatePeerForElement
            // makes one on demand — the same thing UIA does when a
            // client walks the tree — and falls back to FromElement for
            // controls that already carry theirs.
            let peer = match FrameworkElementAutomationPeer::CreatePeerForElement(&fe) {
                Ok(p) => p,
                Err(_) => match FrameworkElementAutomationPeer::FromElement(&fe) {
                    Ok(p) => p,
                    Err(_) => return Ok("<not in the accessibility tree>".to_owned()),
                },
            };
            let kind = peer.GetAutomationControlType()?;
            // THE HEADING ROLE IS A PROPERTY READ, NOT A TYPE READ. A
            // heading is not a control TYPE in UIA — a TextBlock carrying
            // HeadingLevel still reports `Text` — so `ax_role`'s ladder
            // could never see it, and `None` is what an unmarked element
            // answers. `?` rather than a swallowed default on purpose: a
            // failed property read must surface as
            // `<accessibility read failed>`, never as the confident wrong
            // answer "this is an ordinary label".
            //
            // AND THIS READ IS WEAKER THAN ITS SIBLINGS, said plainly
            // rather than left for someone to discover. It asks the PEER,
            // which is the provider side and not kaya's model —
            // `GetHeadingLevelCore` is the method a peer subclass
            // overrides and what a client receives. But it does not leave
            // this process, where GTK's read crosses the AT-SPI bus and
            // Compose's crosses into a published AccessibilityNodeInfo.
            // An out-of-process UIA client is barred at the Cargo.toml
            // (`highlights` below says what that costs and why), so this
            // is the strongest read available here: it proves the
            // property reaches the peer, not that a client in another
            // process would hear it.
            let role = ax_role(
                peer.GetHeadingLevel()? != AutomationHeadingLevel::None,
                kind,
            );
            if role == UNMAPPED_ROLE {
                // The role the platform published is one kaya has no
                // name for — the finding this verb exists to surface,
                // and the next question is always WHICH one, so it goes
                // to the log rather than costing a VM round-trip.
                eprintln!("KAYA_AX_TRACE: unmapped UIA control type {kind:?} for {target:?}");
            }
            let name = peer.GetName()?.to_string();
            // A text field with no authored label publishes an EMPTY
            // UIA Name — its content lives on the ValuePattern, and
            // that value is what a screen reader speaks for it. The
            // same fallback chain the other platforms take (macOS
            // description -> title -> AXValue; GTK name -> AT-SPI Text
            // content), so `field/<its text>` reads the same
            // everywhere. The control's own text IS the value its peer
            // serves; reading it here stays inside the platform's own
            // property surface.
            //
            // THE TWO KINDS ANSWER THROUGH DIFFERENT PATTERNS NOW, and
            // this read is why it does not matter: a TextBox peer
            // publishes ValuePattern and a RichEditBox peer publishes
            // TextPattern instead (measured), but kaya asks the CONTROL,
            // not the pattern, so `field/<text>` is the same string on
            // both. The control TYPE the peer reports is `Edit` for
            // both, so the role half is unmoved as well.
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

    /// THE DECORATED RANGES, out of the control's own document model.
    ///
    /// NOT THE ACCESSIBILITY TREE, and that is a measured limit rather
    /// than a preference: WinUI's in-process automation peer for a text
    /// control publishes no Text pattern at all, so
    /// `GetAttributeValue(BackgroundColor)` — the read the plan named —
    /// has no provider to answer it in this process. The SDK metadata
    /// and live reflection agree (`RichEditBoxAutomationPeer` declares
    /// one interface, `IRichEditBoxAutomationPeer`, where
    /// `ButtonAutomationPeer` declares `IInvokeProvider` beside its own;
    /// `GetPattern(Text)` returns NULL on both text controls). The only
    /// route that does publish it is an out-of-process UIA CLIENT, which
    /// is barred at the Cargo.toml and for good reason — attaching one
    /// makes the Shell's file dialog fatal to the java leg. So this
    /// reads the layer beneath the peer: Rich Edit's own model of what
    /// it is rendering, which is still the platform answering and still
    /// fails when the lowering is deleted.
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

    /// WHETHER A RANGE IS IN THE VIEWPORT — containment, never the
    /// viewport itself.
    ///
    /// FROM THE VIEWPORT AND NOT FROM A MODEL: `ITextRange::GetRect` in
    /// CLIENT coordinates is where the range sits relative to what is on
    /// screen RIGHT NOW, so it moves when the control scrolls and stays
    /// put when the text does not. `AllowOffClient` is what makes the
    /// negative answer real — without it an off-screen range has no
    /// rectangle to report and the verb could only ever say "visible".
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
            // Containment in the viewport the control is actually
            // showing — the ScrollViewer's window onto the document,
            // which is this platform's spelling of mac's
            // AXVisibleCharacterRange.
            let inside = top >= at - 0.5 && bottom <= at + viewport + 0.5;
            Ok(if inside { "visible" } else { "offscreen" }.to_string())
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    /// AN INPUT METHOD'S COMPOSITION, STARTED THROUGH THE INPUT
    /// METHOD'S OWN MACHINERY (docs/ranges-plan.md D4).
    ///
    /// Windows has no "insert marked text" call the way AppKit and UIKit
    /// do: a composition here belongs to the Text Services Framework,
    /// and the only honest way to reach the state is to do what a text
    /// service does — take the focused document's context, run an edit
    /// session on it, start a composition over the caret and write the
    /// text into that composition's range. The text is then DISPLAYED
    /// and UNCOMMITTED, the control raises `TextCompositionStarted`, and
    /// `select_range` must refuse to run over it.
    ///
    /// The alternative — inserting the text and calling it a composition
    /// — would prove nothing about D4: it is the very state the refusal
    /// is supposed to distinguish from.
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
            // The composition goes in where the caret is, and a
            // composition parks the caret at the END of its marked text
            // — so the end of the document is where the scene's
            // arithmetic starts (813 bytes + " z" + "nihon" = 820).
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
            // The REAL resize, through the same DPI-aware path the
            // width/height props drive — and then RE-RUN the arm, which
            // is the point: changing the size without letting the
            // platform re-decide gates nothing.
            let target = winui_window(core, window)?;
            resize_request(&target, Some(width), Some(height))?;
            // FORCE A LAYOUT PASS before re-running the arm. SetWindowPos
            // returns before XAML has re-measured, so the arm asked for
            // a width that was still the OLD one — it stamped `stacked`
            // while the read, running a beat later, said `regular`. The
            // two disagreeing about the same instant is the signature of
            // reading a tree mid-update.
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
        // on_ui_read, like menu_presentation: a pure read of the UI
        // thread's own state, with no mutation to sequence.
        Self::on_ui_read(|core| {
            // The class comes from XamlRoot's real size, the same 600
            // boundary menu_presentation draws; the presentation from
            // the arm that actually ran.
            //
            // UNREADABLE until the element is in a live visual tree,
            // and this verb is asked within milliseconds of launch.
            // `unknown` is a legal class in the grammar for exactly
            // that state, and the harness POLLS — reporting it lets the
            // bounded retry pick up the real reading a frame later.
            // Propagating the error instead killed the leg, which is
            // not what "not yet" deserves.
            // The SAME source the arm used: an assertion measuring
            // differently from the lowering can disagree with it about
            // one instant, which is how this leg failed with the arm
            // saying stacked and the read saying regular.
            let class = match window_client_width(core, 0) {
                Some(w) if w >= 600.0 => "regular",
                Some(_) => "compact",
                None => "unknown",
            };
            // THE CONTROL'S OWN ANSWER, not a value the arm stamped
            // about itself. Windows decides where one pane becomes two,
            // so the only honest reading of which presentation happened
            // is to ask the control. A window that never asked for
            // list-detail has no control, and falls back to the serial
            // arm's stamp.
            let presentation = match core.split_views.get(&0).map(|v| v.Mode()) {
                Some(Ok(mode)) if mode != TwoPaneViewMode::SinglePane => "split",
                Some(Ok(_)) => "stacked",
                _ => core.split_presentation.get(&0).copied().unwrap_or("stacked"),
            };
            Ok(format!("{class}/{presentation}"))
        })
        // The same fallback menu_presentation uses: a read that cannot
        // reach the UI thread reports `unknown`, and the harness's
        // bounded retry asks again.
        .unwrap_or_else(|_| "unknown/stacked".to_owned())
    }

    fn menu_presentation(&self) -> String {
        // XAML has no size-class type; its own adaptive triggers are
        // width thresholds (`MinWindowWidth`), so a width rule IS the
        // platform idiom here. Same 600 boundary as the others, read
        // off the real root's ActualWidth in effective pixels.
        Self::on_ui_read(|core| {
            // The XamlRoot's size is the client area in DIP — the same
            // notion window_content_size and root_fills read, so the
            // 600 boundary means the same thing here as elsewhere.
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
            // THE HARNESS *READ* NEEDS THE SAME FRESHNESS THE
            // ACTIVATION HAS. menu_activate and shortcut both refresh
            // before they act; this read did not, so it answered with
            // whatever enablement the item last had stamped on it — and
            // no scene caught it, because none until undo.steps asserts
            // an enablement that MOVES with no menu traffic in between
            // (typing changes what Edit>Undo can do). The mac arm hit
            // exactly this from the other side, where NSMenu.update()
            // validated nothing (§3a's second finding).
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
        // FROM UIA, NEVER FROM THE MODEL. The answer is the name the
        // icon in the REAL item's Icon slot publishes to its automation
        // peer — what an assistive client hears — so a backend that
        // decoded the symbol prop and drew nothing fails this read, and
        // so does one that drew an icon and named it wrong.
        Self::on_ui_read(move |core| {
            // NO REFRESH STEP HERE, unlike menu_state, and the
            // difference is deliberate: that read re-derives role
            // enablement because a clipboard role's enablement MOVES
            // with no menu traffic at all. A symbol changes only
            // through a prop write, which sets menus_touched and forces
            // the coalesced rebuild before this read can run — both are
            // on the UI thread, so there is no interleaving.
            //
            // Open-context EXCLUSIVITY, exactly as menu_state has it:
            // while a context menu is presented it owns resolution, and
            // a miss reads as the retryable "no such item" rather than
            // falling back to the bar.
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
                // WHAT THIS MEASURED: the item is in the real menu and
                // its icon slot is empty. It deliberately does NOT say
                // whether the app asked for one — this reader cannot
                // tell "no symbol declared" from "declared and never
                // lowered", and a diagnostic may only print what it
                // measured (CLAUDE.md invariant 3).
                MenuIcon::Empty => "no icon on the menu item".to_owned(),
                // The one honest answer for a top-level bar grouping:
                // WinUI's MenuBarItem has no icon slot at all, so this
                // is a statement about the PLATFORM, and saying "no
                // icon" here would point the reader at the app instead.
                MenuIcon::NoSlot => {
                    "a WinUI MenuBarItem has no icon slot (top-level menu)".to_owned()
                }
                MenuIcon::Unreadable(e) => format!("the item's icon slot could not be read: {e}"),
            })
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    /// THE expect_toolbar READ ON WINUI, from three different sides so no
    /// single mistake can make all of it agree: the CATALOG says how many
    /// actions this window promotes, the REAL CommandBar says how many
    /// items it holds and which of them publish the promoted names, and
    /// the REAL MenuBar says whether the remainder has a home.
    ///
    /// ADDRESSED BY WHAT UIA PUBLISHES, which is this backend's existing
    /// discipline (`menu_symbol` reads the icon's automation name rather
    /// than the symbol prop beside it). An `AppBarButton`'s published
    /// name comes from its `Label` — MEASURED on the VM 2026-08-17 with
    /// `KAYA_WINUI_TOOLBAR_TRACE`, because `AppBarButton` lives in the
    /// closed dxaml half of the framework and the answer cannot be read
    /// out of the public sources. So a lowering that promoted the right
    /// items and never labelled them fails here, with the sentence naming
    /// what the bar really carries.
    ///
    /// THE REMAINDER'S HOME IS THE MENU BAR, and that is a repo fact
    /// rather than a preference: `rebuild_menus` renders the WHOLE
    /// catalog into a real `MenuBar` one row above this bar, so every
    /// unpromoted action is already reachable and one home is all there
    /// is. The research's shape put the remainder in `SecondaryCommands`;
    /// filling it would be a second copy of those rows 48px under their
    /// own menu bar. (The GTK arm deviates identically, for the identical
    /// reason, and the macOS arm answers `menubar` because its catalog is
    /// in NSApp's main menu. If this backend's menu lowering ever stops
    /// being a bar, the read says `none` until the overflow is filled.)
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
            // order: `found` counts how far the promotion list can be
            // walked through the names the chrome really publishes.
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

    /// THE expect_toolbar_item READ: one aspect of the real
    /// `AppBarButton`, addressed by the name it publishes to UIA.
    ///
    /// ENABLEMENT IS `IsEnabled` ON THE BUTTON, and this platform is the
    /// easy one: it is an ordinary `Control` property, it is what the
    /// promotion writes, and the SAME object carries it whether the bar
    /// is showing the command or the "…" menu is (measured freebie,
    /// docs/chrome-plan.md C2's WinUI row) — unlike macOS, where
    /// `NSToolbarItem.isEnabled` does not move at all and the arm has to
    /// go to the accessibility tree. The scene's round trip is what
    /// proves it is not the menu read in disguise: two trees, one item.
    ///
    /// THE SYMBOL IS THE ICON THE BUTTON REALLY CARRIES — the automation
    /// name of the `IconElement` in its `Icon` slot, which is `menu_symbol`'s
    /// read one control over, and never `MenuModel::symbol` beside it. A
    /// promotion that drew no icon reads as exactly that.
    ///
    /// TOTAL, like `menu_state`: every miss is a short sentence naming
    /// what was measured and a retryable non-match, never a panic.
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
                // The empty slot arrives as a success-coded error, the
                // same rule `MenuIcon::Empty` records: the property
                // returns a null pointer and windows-core turns that
                // into E_POINTER. What this measured is that the button
                // is in the bar and carries no icon at all — it says
                // nothing about whether the app declared a symbol,
                // because this reader cannot tell that from a symbol
                // that was never lowered (CLAUDE.md invariant 3).
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
        // (docs/traps.md: menu legs run serially for this verb).
        let owned = Self::on_ui_read({
            let spec = spec.clone();
            move |core| {
                // Same freshness rule as menu_activate: the chord may
                // land on a role item whose enablement is a deferred
                // tick stale.
                if core.roles_armed {
                    refresh_role_enablement(core);
                }
                Ok(core.menu_shortcuts.contains_key(&spec))
            }
        })
        .unwrap_or(false);
        // A chord no catalog item owns is a SCRIPT error, said out
        // loud. The gate itself is load-bearing (injection is
        // OS-global — docs/traps.md), but a silent return makes a
        // never-pressed key look exactly like a platform that ignored
        // it: that mistake cost eight platform experiments on
        // 2026-07-24, every one of them measuring a keystroke this
        // gate had swallowed.
        assert!(
            owned,
            "kaya: shortcut {spec:?}: no catalog item owns this chord \
             (the leaf kinds that may carry one are action, toggle, and \
             radio option)"
        );
        Self::foreground_guest("shortcut");

        // The REAL KeyboardAccelerator path: the chord goes onto the
        // system input queue; XAML routes it to the accelerator whose
        // default invocation raises the item's own Click — the SAME
        // menu_activated the direct activation emits.
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
            // A click on a TEXT KIND focuses it — what a native click
            // does to a field, and the only way a scene can put focus
            // on a STAMPED copy (no instance-addressed focus command
            // exists for a guest to call). Programmatic FocusState, the
            // same one the wire's focus command uses (:8606), so
            // is_focused's per-element read sees it.
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

    /// The real-keystroke typing verb (docs/undo-plan.md A8). This
    /// backend has not reached the undo slice, and a keystroke is
    /// exactly where a stand-in would lie: a text write here would look
    /// like typing and would CLEAR the native history the scene came to
    /// observe, turning a missing arm into a passing leg.
    /// The real-keystroke typing verb (docs/undo-plan.md A8), to the
    /// contract's six points (crates/kaya/src/harness.rs).
    ///
    /// 1. THE PLATFORM'S OWN INPUT PATH: `keybd_event` puts each
    ///    character on the SYSTEM INPUT QUEUE, the same call the
    ///    `shortcut` verb uses and the same queue kaya's own chord hook
    ///    watches — so the field's native undo stack fills exactly as a
    ///    user's typing fills it. A `SetText` here would look like typing
    ///    and would CLEAR the very history a native-tier scene exists to
    ///    observe (§1.1's harness consequence).
    /// 2. WHATEVER HOLDS FOCUS RECEIVES IT: nothing is addressed. The
    ///    keys go on the queue and Windows routes them; kaya looks the
    ///    focused field up only to place the caret and to know when the
    ///    text has landed.
    /// 3. IT APPENDS: the caret goes to the END with nothing selected
    ///    before the first keystroke. MEASURED FREE ON THIS LANE (a
    ///    programmatic Focus() leaves the caret where it was and selects
    ///    nothing, and the selection move spends no undo step and raises
    ///    no TextChanged) — and done anyway, because macOS selects a
    ///    field's whole contents on focus and ONE script is compared
    ///    byte-for-byte on all five lanes.
    /// 4. IT BLOCKS UNTIL THE TEXT HAS LANDED: the settle below polls
    ///    the CONTROL until it shows the full string. An action is not
    ///    retried, and the action that follows this one in the scene is
    ///    `menu_activate "Edit>Undo"` — a race there reads as a broken
    ///    undo rather than a missed keystroke.
    /// 5. NO SYNTHETIC COALESCING: one key-down/key-up pair per
    ///    character, in order. Whether the platform merges them into one
    ///    native step is the platform's business — and on this one it
    ///    merges the WHOLE RUN (measured), which is why A1's clear at
    ///    the episode boundary is load-bearing here.
    /// 6. PRINTABLE ASCII ONLY: `parse` refuses anything else, and the
    ///    per-character mapping is asked of the ACTIVE LAYOUT
    ///    (VkKeyScanW) rather than hard-coded.
    fn type_text(&self, text: &str) {
        let text = text.to_owned();
        // The caret first, and the field's text before the run — both
        // read from the FOCUSED editable, which is the platform's answer
        // to "who receives this", not kaya's.
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
        // Point 4, and on this backend "processed" means MORE THAN THE
        // CONTROL SHOWING IT. TextChanged is raised asynchronously, so
        // the widget holds the typed text a beat before kaya has been
        // told — and the action this verb exists to precede is
        // `menu_activate "Edit>Undo"`, whose routing asks the LEDGER.
        // Settling on the control alone is how the first windows leg of
        // this scene undid the star group instead of the typing.
        //
        // So the condition is the ledger's own view of the field
        // (`banked_text`, written beside every `note_text_changed`),
        // which is exactly "every character delivered AND processed"
        // spelled in the vocabulary of a backend whose change events
        // are async. Nothing focused is legitimate under the contract
        // ("the keys go where the platform sends them"), so there is
        // nothing to wait for and a following assertion reports it.
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
        // NOT A PANIC, and not silence either: the keys were injected,
        // so what follows is a real observation of a real state, and the
        // scene's own `expect` is the verdict. This line is what tells
        // whoever reads the transcript that the verb knew.
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
            // The user path, ordered: TextChanged is raised async, so
            // the occurrence is emitted here synchronously and the
            // late raise swallowed — a following click can never
            // overtake the edit (see entry_swallow).
            //
            // The handles are CLONED out of the core (WinRT objects are
            // refcounted, so this is a refcount bump): the banking below
            // borrows the core mutably, and a reference into `entries`
            // held across it would not compile.
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
                // AND THE LEDGER SEES IT FIRST, exactly as it does for a
                // keystroke (§3's banking, and the same order the
                // TextChanged handler uses: bank, then tell the app).
                //
                // THIS VERB IS A USER EDIT, not an app write. It writes
                // the node's own text and emits the ordinary occurrence
                // with the widget's identity tag, so the ledger must see
                // what typing produces — undo.steps' stamped-row block
                // stands on exactly that, a stamped copy having no way
                // to be focused and therefore no way to be typed into.
                // The swallow above is what makes the call NECESSARY
                // here rather than duplicated: it silences the async
                // raise that would otherwise carry this edit into
                // `bank_text_changed` a tick later.
                //
                // MEASURED ON THE VM (2026-08-05) before it was
                // written: with the bank absent, the occurrence still
                // reached the guest carrying the copy's (node, path)
                // identity — the scene's notes label read `notes 3=ha`
                // — while the ledger's frontier stayed the enclosing
                // group, so Edit>Undo took back the ADD and a row's
                // typing was outside the history entirely. The tag, the
                // core's resolution of it and the focus flag were all
                // identical to mac's; only the banking call was
                // missing. This backend was the only one with the
                // split, because it is the only one whose set_text
                // silences the control's own change event: mac banks
                // inside `kaya_emit_text_changed` and GTK from the
                // widget's `changed`.
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
            // The stored BitmapImage's decoded pixel size; no source
            // (or a source that never decoded) is the placeholder
            // class, "0x0".
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
            // Kind picks the registry and the definition axis (the
            // runner rejects any other kind before it gets here). The
            // first Windows run of the row assertion caught this method
            // still hard-wired to columns: row#0 resolved against the
            // COLUMNS registry and reported the column's own splits —
            // the registry-misresolution class, one backend short of a
            // clean sweep.
            let vertical = matches!(t.kind, crate::harness::TargetKind::Column);
            let registry = if vertical { &core.columns } else { &core.rows };
            let Some(i) = crate::harness::try_resolve(t.index, registry.len()) else {
                return Ok("<no such target>".to_string());
            };
            let grid = &registry[i];
            // Measure/arrange are lazy; force them or the first read
            // after mount sees zeros.
            grid.UpdateLayout()?;
            // The TRACK's resolved extent, not the child's: on a Grid
            // the track is the layout rect, and a child only fills it
            // if it stretches. A TextBlock never does — it reports its
            // text height however tall its row is — so reading children
            // turned an exactly correct 25/75 split into 37/63. Same
            // trap as AppKit's alignment rect and GTK's CSS box, in its
            // third dialect.
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
            grid.UpdateLayout()?;
            // A Grid places tracks from the padding edge with
            // RowSpacing-sized gaps between adjacent ones and no slack
            // anywhere else, so the consumed span is the tracks' sum
            // plus the gaps, and slack shows up as the difference to
            // the content box (ActualSize minus Padding).
            let padding = grid.Padding()?;
            let (inner, sum, gaps) = if vertical {
                let defs = grid.RowDefinitions()?;
                let mut sum = 0.0;
                for at in 0..defs.Size()? {
                    sum += defs.GetAt(at)?.ActualHeight()?;
                }
                (
                    grid.ActualHeight()? - padding.Top - padding.Bottom,
                    sum,
                    grid.RowSpacing()? * f64::from(defs.Size()?.saturating_sub(1)),
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
                    grid.ColumnSpacing()? * f64::from(defs.Size()?.saturating_sub(1)),
                )
            };
            let span = sum + gaps;
            Ok(if (span - inner).abs() <= 2.0 {
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
            // The container's own registry decides the axis, the way
            // reindex decided it when it built the tracks — never the
            // element's shape.
            let Ok(grid) = element.Parent()?.cast::<Grid>() else {
                return Ok("parent is not a flex container".to_owned());
            };
            let vertical = core.columns.iter().any(|g| g == &grid);
            if !vertical && !core.rows.iter().any(|g| g == &grid) {
                return Ok("parent is not a flex container".to_owned());
            }
            // Measure/arrange are lazy; force them or the first read
            // after mount sees zeros (the child_shares precedent).
            grid.UpdateLayout()?;
            let (track, drawn) = if vertical {
                let at = Grid::GetRow(&element)? as u32;
                let defs = grid.RowDefinitions()?;
                if at >= defs.Size()? {
                    return Ok("no track recorded — not a flex child".to_owned());
                }
                (defs.GetAt(at)?.ActualHeight()?, element.ActualHeight()?)
            } else {
                let at = Grid::GetColumn(&element)? as u32;
                let defs = grid.ColumnDefinitions()?;
                if at >= defs.Size()? {
                    return Ok("no track recorded — not a flex child".to_owned());
                }
                (defs.GetAt(at)?.ActualWidth()?, element.ActualWidth()?)
            };
            // The track is the definition's resolved extent and the
            // drawn size is the control's own — the same distinction
            // child_shares makes when it reads definitions rather than
            // children, and the gap between them is exactly where a
            // control with an explicit Height sat: 96dip inside a
            // correct 126dip star row, every share passing. An overflow
            // is not a leftover, so the test is one-sided.
            Ok(if drawn >= track - 2.0 {
                String::new()
            } else {
                format!(
                    "draws {}dip of a {}dip track",
                    drawn.round() as i64,
                    track.round() as i64
                )
            })
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
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
            let empty = Vec::new();
            let order = core.child_order.get(&id).unwrap_or(&empty);
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
                let (start, extent) = if vertical {
                    (f64::from(at.X) - origin, element.ActualWidth()?)
                } else {
                    (f64::from(at.Y) - origin, element.ActualHeight()?)
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
            // Multi-match is ambiguity, and ambiguity fails loudly
            // — a first-match answer lets an unseparated scene pass
            // while proving nothing (the separability lesson, made
            // structural).
            let mut matches = Vec::new();
            if rects.iter().all(|r| (r.1 - inner).abs() <= 2.0) {
                matches.push("stretch");
            }
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
        // THE REAL OS CAPTION, not core.window_dirty (D5). The failure
        // under test is a lowering that never reached the window, and a
        // read of the flag this backend just stored would agree with
        // itself and prove nothing.
        //
        // Window::Title() is the honest channel here, MEASURED rather
        // than assumed: the probe held a window open, rewrote its HWND
        // caption with SetWindowTextW from a SECOND PROCESS, and the
        // in-guest harness read the rewritten string back — so this
        // getter follows the OS caption and is not a XAML-side cache of
        // what kaya last set (scratchpad/dirty-probe-windows.md §5).
        //
        // UNREADABLE IS NOT CLEAN. window_title answers an error with
        // "<unreadable: ...>", which does not start with the marker and
        // would therefore pass every `expect_dirty false` in the scene
        // — a clean-window assertion satisfied because the read broke.
        // This returns bool and has no third answer, so it refuses out
        // loud instead, the way the macOS arm refuses on an unreadable
        // AXEdited.
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
            // Present-gated: the stored handle answers before the
            // popup is actually open, and an expect_alert that
            // passed then let alert_choose press a not-yet-
            // interactive dialog — the press dropped silently and
            // the alert never retired (caught live 2026-07-22).
            // IsLoaded flips when the dialog enters the tree, i.e.
            // when the popup is really up and pressable.
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
        // AND WAIT FOR IT TO ACTUALLY GO, which is what makes this verb
        // mean the same thing here as it does on every other backend
        // (CLAUDE.md invariant 1 — the idiom decides the spelling, never
        // the semantics; gtk.rs's choose_alert waits for the same thing
        // in GTK's vocabulary).
        //
        // `Hide()` and `Invoke()` only ASK. `ShowAsync`'s completion is
        // what runs capi::alert_retire, and until it lands the one live
        // slot is still taken — so an app that shows its NEXT alert from
        // any other path walks into "alert N is already live" and the
        // process aborts. MEASURED 2026-08-10, the editor leg: File>New's
        // alert is cancelled and the window's close_requested shows the
        // second one one millisecond later. That abort took the whole
        // run's verdict with it, and the scene before it had already
        // passed `expect_alert` against the FIRST dialog, still up.
        //
        // THE OBSERVABLE IS capi's SLOT, not this backend's `live_alert`,
        // and the difference is what makes the wait possible at all: the
        // slot is a plain Mutex the harness thread reads directly, while
        // every route into `CoreState` here holds a RefCell borrow that
        // the completion itself needs (`capi::alert_is_live` says this in
        // full). It is also the STRONGER condition — this backend clears
        // `live_alert` first and retires second.
        //
        // A stuck alert dies LOUDLY: a silent give-up would leave the
        // next expect_alert reading the wrong dialog and passing. The
        // same two numbers every other observation gets, because this is
        // a wait for an observable to settle and has no business
        // inventing a second deadline.
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
            let Some(i) = crate::harness::try_resolve(t.index, core.scrolls.len()) else {
                return Ok("<no such target>".to_string());
            };
            let viewer = &core.scrolls[i];
            // The toolkit's own metrics: ScrollableHeight is the
            // overflow itself (extent minus viewport).
            let scrollable = viewer.ScrollableHeight()?;
            Ok(if scrollable > 2.0 {
                String::new()
            } else {
                format!(
                    "content {} in viewport {}",
                    viewer.ExtentHeight()?,
                    viewer.ViewportHeight()?
                )
            })
        })
        .unwrap_or_else(|e| format!("<unreadable: {e}>"))
    }

    fn scroll_end(&self, t: crate::harness::Target) {
        Self::on_ui(move |core| {
            let i = crate::harness::resolve(t.index, core.scrolls.len());
            let viewer = &core.scrolls[i];
            // The REAL scrolling API: ChangeView is what scrollbars
            // and touch panning drive.
            let target = viewer.ScrollableHeight()?;
            let offset: IReference<f64> = PropertyValue::CreateDouble(target)?.cast()?;
            viewer.ChangeView(
                None::<&IReference<f64>>,
                &offset,
                None::<&IReference<f32>>,
            )?;
            Ok(())
        })
    }

    fn scroll_at_end(&self, t: crate::harness::Target) -> String {
        Self::on_ui_read(move |core| {
            let Some(i) = crate::harness::try_resolve(t.index, core.scrolls.len()) else {
                return Ok("<no such target>".to_string());
            };
            let viewer = &core.scrolls[i];
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
        // The REAL dialog, read through the shell's own view — never
        // this backend's record of what it asked for. A picker aimed at
        // the wrong place, or filtered down to nothing, presents
        // perfectly and is useless.
        //
        // NOT over UI Automation, which cannot be used against this
        // dialog at all: attaching any automation client makes the
        // shell's DirectUI raise event notifications during message
        // dispatch, each one an outgoing COM call that Windows refuses
        // and turns into a NONCONTINUABLE structured exception. See
        // sample_folder_view for the measured stack.
        //
        // NOT through on_ui_read either: the picker is a #32770 the
        // shell owns, not a XAML object, and it runs on its own thread.
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
    /// THE SAME POSTED KEYSTROKES `choose_file` USES, and posted for the
    /// same measured reason: a `SendMessage` puts the dialog's thread into
    /// an input-synchronous call, and everything in this dialog calls out
    /// over COM while handling messages — the file-name box is backed by
    /// shell autocomplete. Windows refuses those callouts with a
    /// NONCONTINUABLE `RPC_E_CANTCALLOUT_ININPUTSYNCCALL`, which is fatal
    /// under a JVM.
    ///
    /// EM_SETSEL(0, -1) FIRST, so the first character REPLACES the
    /// suggested name instead of joining it. Without it the field would
    /// read `copyfinal` and the read-back below would say so.
    ///
    /// POSTED AND THEN VERIFIED, IN A LOOP, and that loop is not caution —
    /// it is the whole difference between this working and this silently
    /// not. MEASURED 2026-08-09 on the lane VM: the FIRST burst of
    /// characters a process posts into a freshly created save dialog's
    /// name box is DISCARDED. Same window, same control (the log carried
    /// one `dialog=0xd50584 edit=Some(1967526)` for both attempts), the
    /// field still reading `"copy"` 50ms later; the identical burst on the
    /// second attempt landed at once. It is not a readiness race that
    /// waiting fixes — a 3000ms `settle` before a single post failed
    /// exactly the same way. Only repeating works.
    ///
    /// THE SHARED SCENE CANNOT SEE THIS, which is why it was found with a
    /// scratch script and is written down here. `save.steps` shows a save
    /// dialog, CANCELS it, and types into the second one — so the single
    /// post that this loop replaces passed the leg while a guest that put
    /// up ONE save dialog and typed into it would have saved under the
    /// SUGGESTED name, every byte assertion still green and pointing at
    /// the wrong file. That is precisely the failure
    /// `expect_save_dialog`'s name half exists to catch, hiding one dialog
    /// upstream of where the scene looks.
    ///
    /// The other two dialog actions were already shaped this way —
    /// `choose_file` and `confirm_save` both post-and-check until the
    /// dialog goes — so this was the one single-shot action in the
    /// backend. Silent to the scene either way: `expect_save_dialog` is
    /// still what asserts the name.
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
    /// through — including the confirmation Windows may put in front of
    /// it.
    ///
    /// THE OVERWRITE PROMPT IS THE REASON THIS IS NOT `choose_file` WITH
    /// TWO IDS. `FOS_OVERWRITEPROMPT` is in the save dialog's DEFAULT
    /// options (measured `0x880a`), and this backend keeps it, because
    /// clearing it would make Windows the only platform that replaces a
    /// file without asking. When it fires, the answer is a SECOND
    /// top-level `#32770` titled "Confirm Save As" — and it is not a
    /// classic dialog: its 17 descendants are a `DirectUIHWND` plus
    /// `CtrlNotifySink`-wrapped Buttons WITH ID 0, so no id lookup finds
    /// anything (measured, scratchpad/save-probe-windows.md §B.3). Class
    /// plus caption does, and `BM_CLICK` on the "&Yes" button dismisses
    /// it.
    ///
    /// LEAVING IT UNANSWERED DOES NOT FAIL, IT WEDGES: `Show()` never
    /// returns, the apartment thread stays inside its nested modal loop
    /// for the rest of the process's life, and the leg dies on a timeout
    /// with a modal window still on the desktop. That is the one failure
    /// shape a windows lane must not have.
    ///
    /// The shared scene never overwrites — it saves to a name in a
    /// per-pid directory that nobody has made — so this arm is not covered
    /// by the leg and cannot be, the script being byte-frozen across five
    /// platforms. It was driven by hand on the VM instead
    /// (scratchpad/save-winui.md §5).
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
        // POSTED, NEVER SENT. A SendMessage puts the receiving thread
        // into an input-synchronous call, and everything in this dialog
        // calls out over COM while handling messages — the file-name box
        // is backed by shell autocomplete, the buttons drive the shell
        // view. Windows refuses those callouts and raises
        // RPC_E_CANTCALLOUT_ININPUTSYNCCALL, which is fatal under a JVM
        // (sample_folder_view). Posting queues the message and returns,
        // leaving the dialog's thread in no special state at all.
        //
        // The observable is the dialog GOING AWAY, so that is what this
        // waits for rather than a return code: a press that lands before
        // the list is interactive is swallowed with no error anywhere,
        // and the leg would fail three steps later on an assertion about
        // the guest.
        for _ in 0..40 {
            let Some(dialog) = live_dialog() else { return };
            match name {
                // Named in the dialog's own file-name box rather than by
                // hit-testing a row: the rows are DirectUI items, not
                // windows, so there is nothing to click. Typed a
                // character at a time because WM_SETTEXT carries a
                // pointer, and only SendMessage marshals one.
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

    /// The foreign WRITER: Windows PowerShell 5.1 as a child of this
    /// process — the guest runs in the interactive session (deploy-win
    /// launches through schtasks /it), so its children share the ONE
    /// real clipboard; an ssh-spawned tool would get a per-connection
    /// window station with a clipboard of its own (measured,
    /// docs/clipboard-plan.md §6). 5.1 and never pwsh: -AsHtml,
    /// -LiteralPath, -Format and -TextFormatType all vanish silently
    /// there — the script asserts the edition rather than assuming.
    ///
    /// AND IT WAITS UNTIL THE CONTENT IS REALLY THERE (the osascript
    /// lesson, §3): the script polls the pasteboard's own Contains*
    /// after writing and prints KAYA_SEEDED only when the seed is
    /// visible; a seed that does not verify makes everything after it
    /// race.
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
                // Raw PNG bytes under the \"PNG\" registered format —
                // the same shape wl-copy -t image/png seeds on linux:
                // the seed writes the type the arm reads, and the
                // MemoryStream form writes EXACT bytes (a plain
                // string or object would ride WPF's serialized-object
                // path that only PowerShell can read back).
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

    /// The foreign READER, per kind: text via Get-Clipboard -Raw;
    /// html via PresentationCore's GetText(Html) — NEVER Get-Clipboard
    /// -TextFormatType, which decodes the UTF-8 payload with the ANSI
    /// code page and corrupts non-ASCII irreversibly — with the
    /// CF_HTML fragment sliced out host-side by the same parser the
    /// arm uses; an image as its DECODED size through GDI+ (a real
    /// foreign decode of the PNG bytes, though a lenient one: both
    /// stock decoders accept a bad IDAT CRC, so the strict-decoder
    /// property lives on the linux lane alone — measured); files as
    /// the first entry's basename (pbpaste parity); custom as the
    /// exact bytes via GetData's MemoryStream.
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
        // THE RESOLVED FAMILY, ON A PLATFORM THAT CANNOT NAME IT.
        //
        // Four routes to the name were costed and three are dead here
        // (scratchpad/styling/typeface-winui.md §2, measured):
        //   * `FontFamily.Source` is the request handed back. It answers
        //     "did my write land on the object", never "did the text
        //     system find that font" — the read Slice 2b forbids.
        //   * UIA's `FontNameAttribute` needs the Text pattern, and
        //     WinUI's in-process automation peer for a text control
        //     publishes none (`GetPattern(Text)` is NULL on both text
        //     controls — this backend measured that for the a11y read
        //     and wrote it down at the background-colour arm).
        //   * An out-of-process UIA client is barred at
        //     crates/kaya/Cargo.toml, deliberately: it kills the java
        //     leg through the Shell's file dialog.
        // So the name is not readable. What IS readable is what the text
        // system DID, and that is the read this uses: lay a pinned
        // string out in XAML's own text stack and take its measured
        // extent. Two numbers for one string are a fingerprint of the
        // face that really rendered, and — unlike every name route — a
        // fallback cannot fake them.
        //
        // THE ROUTES IT COVERS, and they are different mechanisms rather
        // than three views of one: a Label is a bare TextBlock carrying
        // a LOCAL family (`text_block`), while an Entry and a Textarea
        // are Controls whose family arrives through the implicit style's
        // `ContentControlThemeFontFamily` — the app-dictionary override.
        // A lowering that lost either would show up here as a
        // disagreement rather than as a pass, which is the shape that
        // caught a deleted root font on the mac arm.
        Self::on_ui_read(move |core| {
            let brand = brand_typeface();
            // Pending layout is forced before anything is measured, for
            // the reason every extent read in this file does it: a
            // measurement taken with layout outstanding is the previous
            // pass's answer.
            //
            // IT IS NOT A SETTLE, AND THAT WAS MEASURED RATHER THAN
            // ASSUMED. A Control carries its FontFamily DP DEFAULT until
            // the implicit style is applied, and that happens on a later
            // turn of the message pump than this: with `UpdateLayout` in
            // place the first poll still saw the entry asking for
            // `Segoe UI Variable` (this SDK's default) and the second saw
            // Georgia. What covers the window is the verb's own bounded
            // retry — and the RACE ONLY RUNS ONE WAY, which is what makes
            // that safe: the transient is the UNBRANDED default and the
            // settled state is the brand, so a read that says Georgia
            // cannot be a lucky early sample.
            let root: FrameworkElement = core.window.Content()?.cast()?;
            root.UpdateLayout()?;
            // The reference the whole read turns on: what a family this
            // machine cannot have looks like after XAML has laid it out.
            // Every route that measures the same as this one fell back.
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
            // THE NOTE IS ONLY EVER FAILURE TEXT, and it is attached
            // under one condition: a brand was DECLARED and the text
            // system did not use it. A brandless app resolving to the
            // platform's own face is the right answer and gets the bare
            // name; a branded app that fell back gets the name plus the
            // one measurement that says which half broke. Both branches
            // print numbers this process went and got.
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

    fn inset(&self) -> String {
        Self::on_ui_read(move |core| {
            // MEASURED from real layout, never read back from the
            // model: Grid.Padding shifts the first child's visual
            // offset inside the root by exactly the inset
            // (docs/styling-plan.md D3).
            let root: FrameworkElement = core.window.Content()?.cast()?;
            root.UpdateLayout()?;
            let grid: Grid = root.cast()?;
            let child: UIElement = grid.Children()?.GetAt(0)?;
            let transform = child.TransformToVisual(&root)?;
            let origin = transform
                .TransformPoint(bindings::Windows::Foundation::Point { X: 0.0, Y: 0.0 })?;
            // The root's one Padding carries the root CONTAINER's own
            // inset too, when it declares one (container_padding — WinUI
            // has a single Padding where SwiftUI and Compose nest two
            // boxes), and that number belongs to the other read. The
            // primary window's root is the one Content holds; zero
            // unless a scene puts an inset on it, which leaves this
            // exactly what it measured.
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
            // The walk `inset` does, one level down: a Grid's Padding
            // offsets its first track, so the first child's arranged
            // origin inside its container IS the container's inset.
            // MEASURED, never Padding read back out of the property the
            // apply arm wrote — a read-back would pass with no lowering
            // at all.
            //
            // Through target_element because that is the one registry
            // table (a second copy is how row#0 once resolved against
            // the columns), and a target that is not a container is
            // refused rather than measured: the runner does not screen
            // the kind for this step the way it does for expect_order.
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
            let child = children.GetAt(0)?;
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
            let x = (f64::from(origin.X) - margin.Left - window_term).round() as i64;
            let y = (f64::from(origin.Y) - margin.Top - window_term).round() as i64;
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
        // TwoPaneView for its Mode: the pane position IS a property of
        // the live NavigationView, so the honest reading of which arm
        // rendered is to ask the control. A mirror written beside the
        // SetPaneDisplayMode call would agree with that call by
        // construction and could never fail — the declared-prop trap
        // one indirection along.
        //
        // WHAT IT MEASURES: where the pane is PUT, not where it landed
        // — enough to tell the two arms apart, and it also catches a
        // window whose nav was never built and a hint change that never
        // re-ran the arm, which is this verb's whole failure class.
        Self::on_ui_read(move |core| {
            let Some(nav) = core.section_navs.get(&window) else {
                // Never a default arm: this window has no sections
                // chrome at all, and the harness polls.
                return Ok(format!("no sections chrome on window#{window}"));
            };
            Ok(match nav.PaneDisplayMode()? {
                NavigationViewPaneDisplayMode::Top => "bar".to_owned(),
                // Every LEFT spelling is the design's `sidebar`: the
                // compact rail and the minimal hamburger are the same
                // leading-edge pane in less width. The arm asks for
                // plain Left today, so those two are unreached; they
                // are here so a later adaptive arm reads correctly
                // rather than falling into the unnamed branch.
                NavigationViewPaneDisplayMode::Left
                | NavigationViewPaneDisplayMode::LeftCompact
                | NavigationViewPaneDisplayMode::LeftMinimal => "sidebar".to_owned(),
                // Auto is the control's construction default and
                // neither arm sets it, so a nav still wearing one never
                // reached SetPaneDisplayMode. Only the mode itself is
                // printed — that is what was read.
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
        // IconElement in the NavigationViewItem's own Icon slot, which
        // is `toolbar_item`'s read one control over (both go through
        // `icon_slot!`, so the switcher needed no icon code of its own),
        // and never `WinSection::symbol` beside it.
        //
        // The item's OWN uia name is its Content, i.e. the title — the
        // AppBarButton finding one control over — so the two halves of
        // this read come off two different properties of the same real
        // element and neither is kaya's copy.
        //
        // EVERY WINDOW, in id order: the sections scene's sidebar rows
        // live in an aux window (`Left` pane display mode there, `Top`
        // in the primary — one control, both arms).
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
                        // The empty slot arrives as a success-coded
                        // error (the `MenuIcon::Empty` rule): the
                        // property returns a null pointer and
                        // windows-core turns that into E_POINTER. What
                        // this measured is that the row is in the real
                        // switcher and carries no icon at all — it says
                        // nothing about whether the app declared a
                        // symbol, which this reader cannot tell it from.
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
        // THE APARTMENT GUARD, on the path every scene in every
        // language leaves by. A first-chance RPC_E_DISCONNECTED means
        // some apartment in this process closed while the Shell still
        // held proxies into it — the defect `dialog_apartment`
        // describes — and four of the five guest runtimes swallow it
        // without a mark, so the scene has to be the one that looks.
        // A green scene that raised one is not a green scene.
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
        // request_exit reads the UI thread's APP; hop before asking.
        Self::on_ui(move |_| {
            request_exit(code);
            Ok(())
        });
    }
}


/// The widget id behind a harness target, recovered by COM identity
/// from the creation-ordered registry (the cross_mode precedent).
/// Context anchors in the scenes are labels; other kinds join as
/// scenes demand them — an unwired kind fails loudly, never silently
/// (the is_focused stance).
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
        // ACCESSIBILITY needs every kind, not just the Label this
        // function was written for (it served context_open, which is
        // label-only). a11y_id/a11y_label are universal props, so
        // Stage::ax can target anything.
        //
        // The arm below used to be `panic!` for every non-Label kind,
        // which is how the WinUI accessibility read died on its first
        // live run (2026-07-25) — inside the UI closure, so the
        // dispatcher surfaced it as an opaque `RecvError` rather than
        // the message. Returning 0 makes the caller report "no such
        // target", which is a legible failure instead of a crash.
        //
        // NOT YET RESOLVED: the remaining kinds need real lookups.
        // Button and Checkbox are STRUCT variants ({ button, caption }
        // / { check, caption }), and core.buttons holds tags rather
        // than widgets, so this wants the same resolution the other
        // WinUI verbs use rather than a hand-rolled scan.
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

/// THE ROLE HALF OF THE `ax` VERB, as a pure function of the two things
/// UIA answered with — nothing else in `ax` can be reached off Windows,
/// and this part is where the ordering bug lives.
///
/// `heading` comes FIRST and that is the whole reason this is a function
/// rather than an inline ladder: UIA has no heading control type, so a
/// heading TextBlock reports `Text`, and a ladder that consulted the type
/// first would answer `label` for every heading kaya declares — a wrong
/// answer that looks exactly like a right one. The compiler cannot see
/// that ordering, so `mod tests` below does.
///
/// Gated with the `Stage` impl that calls it: a shipped app carries no
/// scene interpreter, so it carries no accessibility read either.
#[cfg(feature = "harness")]
fn ax_role(heading: bool, kind: AutomationControlType) -> &'static str {
    if heading {
        // Spelled the way every other backend spells it,
        // `heading/<the label's text>` — ONE word for all nine levels,
        // because the closed set names the ROLE and a shared scene
        // cannot freeze a per-platform level ladder
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
        // NORMALIZED to the coarsest container role every platform
        // publishes. UIA distinguishes Group, Pane and List (a
        // RadioButtons group is a List here); the closed set has one
        // name for "a container an assistive client steps into",
        // because that is all a shared scene can assert.
        "group"
    } else {
        UNMAPPED_ROLE
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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

    /// THE CROSS-READ, WHICH IS THIS ARM'S ONE LANDMINE. Fluent's stop
    /// names say how light the SHADE is, not which theme owns it: the
    /// LIGHT theme reads `SystemAccentColorDark1` and the DARK theme
    /// reads `SystemAccentColorLight2`. Getting it backwards produces an
    /// app that is branded in one appearance and the user's system
    /// accent in the other — a bug nobody sees until they flip the OS
    /// setting, and one no read-back in this process can catch, because
    /// the dictionary reads back exactly what was written either way.
    ///
    /// Each stop is also pinned to the WORD the core derived for it, so
    /// the consumer-by-consumer pairing in `brand_dictionary` cannot
    /// drift into "some accent-ish colour in some accent-ish slot".
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

    /// THE ORDERING NO COMPILER CAN SEE, and the one this arm is most
    /// likely to lose.
    ///
    /// UIA publishes no heading control type. The styling pass's heading
    /// is a TextBlock, and its peer answers
    /// `AutomationControlType::Text` whether or not the role was applied
    /// — so the ONLY evidence a heading exists is the HeadingLevel
    /// property, and the ladder has to consult it before the type. Get
    /// that backwards and every heading reads `label/Sections` where
    /// tools/scenes/styling.steps froze `heading/Sections`: a wrong
    /// answer shaped exactly like a right one, from a verb whose whole
    /// job is to be believed.
    ///
    /// (`AutomationControlType::Header` is NOT the heading and is not a
    /// route out of this — it is the header of a table, list or tree.)
    #[test]
    #[cfg(feature = "harness")]
    fn a_heading_outranks_the_control_type_its_peer_reports() {
        assert_eq!(ax_role(true, AutomationControlType::Text), "heading");
        // The same element with the role absent. The two calls differ in
        // the property alone, which is the entire claim.
        assert_eq!(ax_role(false, AutomationControlType::Text), "label");
    }

    /// THE REST OF THE LADDER, PINNED BECAUSE THE HEADING BRANCH WAS
    /// INSERTED AT THE TOP OF IT. Every word here is bytes in a shared
    /// scene's expected string (tools/scenes/*.steps, compared
    /// byte-for-byte across all eight languages), so a dropped or
    /// re-spelled arm is a matrix failure on a lane this machine cannot
    /// run. The three container types collapsing to one word is
    /// deliberate, not an oversight.
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
            // And the heading property outranks every one of them —
            // stated across the whole table rather than at `Text` alone,
            // because "consult the property first" is a claim about the
            // ladder and not about one arm of it.
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

    /// THE ROUND TRIP, which is the whole defect in one assertion: what
    /// `register_font_blob` WRITES, the harness read must be able to
    /// resolve BACK to that file. It shipped unable to — the read asked
    /// the system font collection about a per-app font file's family, a
    /// question whose answer is "no" on a machine where everything
    /// worked, so all five windows typeface legs failed with the font
    /// rendering correctly on screen (2026-08-16).
    ///
    /// Both directions run here for real: the file is written, DirectWrite
    /// names it, the `ms-appx:///` source is parsed, the path is resolved
    /// back under the app root, and the file's own name table is read.
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

    /// AND THE BARE-NAME ARM IS UNCHANGED: a source with no `#` is still
    /// the system font collection's question, both ways round. This is
    /// the arm the fix must not have weakened — an installed family
    /// still prints its bare name, and a family nobody has still gets
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

    /// The two keys this lowering must NEVER write, each for its own
    /// reason. `SystemAccentColor` is the documented-but-broken route of
    /// microsoft-ui-xaml#6394: no control fill reads it, so an app that
    /// writes it changes the text-selection highlight and nothing else.
    /// A `HighContrast` (or fallback `Default`) dictionary would override
    /// the framework's own contrast arm, which re-points every accent
    /// brush at `SystemColor*` — a documented accessibility contract
    /// ("Do not hard-code colors in HighContrast").
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
