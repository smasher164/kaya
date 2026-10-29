// Document tabs on Windows (docs/doctabs-plan.md §3): a TabView used as the
// tab ROW in the caption (Q9; Notepad's and Windows Terminal's shape), the
// active document's root shown below it beside the shared regions; a tab
// dropped outside, or the tab's Move to New Window, is a new kaya window (§1.2).
// Toolkit events are queued and drained on a dispatcher turn with CORE
// borrowed, since kaya's own calls raise some of them while CORE is held.

use super::*;
use bindings::Microsoft::UI::Xaml::Controls::{
    FontIconSource, MenuFlyout, MenuFlyoutItem, SelectionChangedEventHandler, TabView, TabViewItem,
    TabViewTabCloseRequestedEventArgs, TabViewTabDragCompletedEventArgs, TabViewTabDroppedOutsideEventArgs,
};

pub(super) struct DocPage {
    pub window: u64,
    pub item: TabViewItem,
    pub root: Option<UIElement>,
    pub title: String,
    pub dirty: bool,
    pub intercept: bool,
}

pub(super) struct WinTabs {
    pub view: TabView,
    pub host: Grid,
    pub slots: [Grid; 3],
}

#[derive(Default)]
pub(super) struct Docs {
    pub pages: HashMap<u64, DocPage>,
    pub order: HashMap<u64, Vec<u64>>,
    pub active: HashMap<u64, u64>,
    pub tabs: HashMap<u64, WinTabs>,
    pub regions: HashMap<u64, (u64, u32)>,
    pub new_document: HashMap<u64, bool>,
}

enum DocEvent {
    Selected(u64),
    Close(u64),
    Reordered(u64),
    TearOut(u64),
    NewDocument(u64),
    CloseWindow(u64),
}

thread_local! {
    static EVENTS: RefCell<Vec<DocEvent>> = const { RefCell::new(Vec::new()) };
    static PENDING: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    static DOC_WINDOWS: RefCell<BTreeSet<u64>> = const { RefCell::new(BTreeSet::new()) };
    /// The documents window the user is in, by kaya's account (the GTK arm's
    /// rule: a window a tear-out activates need not report it at once).
    static FRONT: std::cell::Cell<Option<u64>> = const { std::cell::Cell::new(None) };
    static POINTER_IN_ROW: RefCell<BTreeSet<u64>> = const { RefCell::new(BTreeSet::new()) };
}

/// TabView keeps a closed tab's neighbours at their widths, and its scroll
/// buttons up, until the pointer leaves the row (Edge's close-under-the-pointer
/// behaviour), so a close the pointer did not make left arrows over a row with
/// room (docs/traps.md, the WinUI tab row's scroll buttons). Away from the
/// pointer kaya has the row re-fill: a TabWidthMode change re-runs its width pass.
fn reflow(window: u64, view: &TabView) -> windows_core::Result<()> {
    use bindings::Microsoft::UI::Xaml::Controls::TabViewWidthMode;
    if POINTER_IN_ROW.with_borrow(|set| set.contains(&window)) {
        return Ok(());
    }
    view.SetTabWidthMode(TabViewWidthMode::SizeToContent)?;
    view.SetTabWidthMode(TabViewWidthMode::Equal)
}

fn enqueue(event: DocEvent) {
    EVENTS.with_borrow_mut(|q| q.push(event));
    if !PENDING.with(|p| p.replace(true)) {
        schedule_drain();
    }
}

fn schedule_drain() {
    if let Some(dispatcher) = DISPATCHER.get() {
        let handler = DispatcherQueueHandler::new(|| {
            drain();
            Ok(())
        });
        let _ = dispatcher.0.TryEnqueue(&handler);
    }
}

fn drain() {
    PENDING.with(|p| p.set(false));
    let ran = CORE.with(|cell| {
        let Ok(mut core) = cell.try_borrow_mut() else { return false };
        let Some(core) = core.as_mut() else { return true };
        for event in EVENTS.with_borrow_mut(std::mem::take) {
            if let Err(e) = handle(core, event) {
                eprintln!("kaya: winui document tabs: {}", e.message());
            }
        }
        true
    });
    if !ran && !PENDING.with(|p| p.replace(true)) {
        schedule_drain();
    }
}

/// WM_CLOSE on a window with documents closes its documents, asked once.
pub(super) fn native_close(id: u64) -> bool {
    if DOC_WINDOWS.with_borrow(|set| set.contains(&id)) {
        enqueue(DocEvent::CloseWindow(id));
        return true;
    }
    false
}

fn doc_of(item: &windows_core::IInspectable) -> Option<u64> {
    let item: TabViewItem = item.cast().ok()?;
    item.Tag().ok()?.cast::<IReference<u64>>().ok()?.Value().ok()
}

fn string_of(value: &windows_core::IInspectable) -> String {
    value
        .cast::<IReference<HSTRING>>()
        .and_then(|v| v.Value())
        .map(|s| s.to_string())
        .unwrap_or_default()
}

fn star(value: f64, unit: GridUnitType) -> windows_core::Result<GridLength> {
    Ok(GridLength { Value: value, GridUnitType: unit })
}

pub(super) fn ensure_tabs(core: &mut CoreState, window: u64) -> windows_core::Result<()> {
    if core.docs.tabs.contains_key(&window) {
        return Ok(());
    }
    require_control_resources("this window holds documents");
    let view = TabView::new()?;
    view.SetIsAddTabButtonVisible(core.docs.new_document.get(&window).copied().unwrap_or(false))?;
    view.SetCanReorderTabs(true)?;
    view.PointerEntered(&PointerEventHandler::new(move |_, _| {
        POINTER_IN_ROW.with_borrow_mut(|set| set.insert(window));
        Ok(())
    }))?;
    view.PointerExited(&PointerEventHandler::new(move |_, _| {
        POINTER_IN_ROW.with_borrow_mut(|set| set.remove(&window));
        Ok(())
    }))?;
    view.SetCanDragTabs(true)?;
    view.SetVerticalAlignment(bindings::Microsoft::UI::Xaml::VerticalAlignment::Bottom)?;
    view.SetHorizontalAlignment(HorizontalAlignment::Stretch)?;
    let footer = Grid::new()?;
    footer.SetMinWidth(CAPTION_TAB_DRAG)?;
    view.SetTabStripFooter(&footer)?;
    // The caption's content presenter centres what it holds
    // (TitleBarContentHorizontalAlignment); a tab row spans the slot.
    view.Loaded(&RoutedEventHandler::new(|sender, _| {
        use bindings::Microsoft::UI::Xaml::Media::VisualTreeHelper;
        let Some(sender) = sender.as_ref() else { return Ok(()) };
        let mut at = VisualTreeHelper::GetParent(&sender.cast::<bindings::Microsoft::UI::Xaml::DependencyObject>()?).ok();
        while let Some(node) = at {
            if let Ok(fe) = node.cast::<FrameworkElement>() {
                if fe.Name()? == "PART_ContentPresenter" {
                    fe.SetHorizontalAlignment(HorizontalAlignment::Stretch)?;
                    fe.SetVerticalAlignment(bindings::Microsoft::UI::Xaml::VerticalAlignment::Stretch)?;
                    break;
                }
            }
            at = VisualTreeHelper::GetParent(&node).ok();
        }
        Ok(())
    }))?;
    view.SelectionChanged(&SelectionChangedEventHandler::new(move |_, _| {
        enqueue(DocEvent::Selected(window));
        Ok(())
    }))?;
    view.TabCloseRequested(&TypedEventHandler::<TabView, TabViewTabCloseRequestedEventArgs>::new(
        move |_, args| {
            if let Some(args) = args.as_ref() {
                if let Some(doc) = doc_of(&args.Tab()?.cast()?) {
                    enqueue(DocEvent::Close(doc));
                }
            }
            Ok(())
        },
    ))?;
    view.AddTabButtonClick(&TypedEventHandler::<TabView, windows_core::IInspectable>::new(move |_, _| {
        enqueue(DocEvent::NewDocument(window));
        Ok(())
    }))?;
    view.TabDroppedOutside(&TypedEventHandler::<TabView, TabViewTabDroppedOutsideEventArgs>::new(
        move |_, args| {
            if let Some(args) = args.as_ref() {
                if let Some(doc) = doc_of(&args.Tab()?.cast()?) {
                    enqueue(DocEvent::TearOut(doc));
                }
            }
            Ok(())
        },
    ))?;
    view.TabDragCompleted(&TypedEventHandler::<TabView, TabViewTabDragCompletedEventArgs>::new(
        move |_, _| {
            enqueue(DocEvent::Reordered(window));
            Ok(())
        },
    ))?;

    let outer = Grid::new()?;
    let rows = outer.RowDefinitions()?;
    for (value, unit) in [(1.0, GridUnitType::Star), (1.0, GridUnitType::Auto)] {
        let row = RowDefinition::new()?;
        row.SetHeight(star(value, unit)?)?;
        rows.Append(&row)?;
    }
    let middle = Grid::new()?;
    let cols = middle.ColumnDefinitions()?;
    for (value, unit) in [(1.0, GridUnitType::Auto), (1.0, GridUnitType::Star), (1.0, GridUnitType::Auto)] {
        let col = ColumnDefinition::new()?;
        col.SetWidth(star(value, unit)?)?;
        cols.Append(&col)?;
    }
    let slots = [Grid::new()?, Grid::new()?, Grid::new()?];
    let host = Grid::new()?;
    Grid::SetColumn(&slots[0].cast::<FrameworkElement>()?, 0)?;
    Grid::SetColumn(&host.cast::<FrameworkElement>()?, 1)?;
    Grid::SetColumn(&slots[1].cast::<FrameworkElement>()?, 2)?;
    middle.Children()?.Append(&slots[0].cast::<UIElement>()?)?;
    middle.Children()?.Append(&host.cast::<UIElement>()?)?;
    middle.Children()?.Append(&slots[1].cast::<UIElement>()?)?;
    Grid::SetRow(&middle.cast::<FrameworkElement>()?, 0)?;
    Grid::SetRow(&slots[2].cast::<FrameworkElement>()?, 1)?;
    outer.Children()?.Append(&middle.cast::<UIElement>()?)?;
    outer.Children()?.Append(&slots[2].cast::<UIElement>()?)?;
    ensure_shell(core, window)?;
    set_window_content(core, window, &outer.cast::<UIElement>()?)?;
    DOC_WINDOWS.with_borrow_mut(|set| set.insert(window));
    if FRONT.with(|f| f.get()).is_none() {
        FRONT.with(|f| f.set(Some(window)));
    }
    core.docs.tabs.insert(window, WinTabs { view, host, slots });
    // THE ROW GOES INTO THE CAPTION (Q9), which refresh_toolbar mints for a
    // window with documents whether or not it promotes anything.
    refresh_toolbar(core, window)
}

/// The empty caption a tab row keeps for dragging the window: the
/// `TitleBar` control's own minimum drag region (TitleBarMinDragRegionWidth's
/// library value), held by the tab strip's footer, which Equal-width tabs
/// would otherwise take.
const CAPTION_TAB_DRAG: f64 = 48.0;

/// The tab row a window's caption carries, if it carries one.
pub(super) fn caption_row(titlebar: &TitleBar) -> Option<TabView> {
    titlebar.Content().ok()?.cast().ok()
}

/// The parts of a tab row that take clicks, so the caption's passthrough
/// rects leave the footer, and the caption beyond it, to the drag.
pub(super) fn row_click_parts(view: &TabView) -> windows_core::Result<Vec<FrameworkElement>> {
    let root: UIElement = view.cast()?;
    let mut parts = Vec::new();
    for name in ["TabListView", "AddButton"] {
        if let Some(part) = named_descendant(&root, name)? {
            if part.Visibility()? == Visibility::Visible {
                parts.push(part);
            }
        }
    }
    Ok(parts)
}

pub(super) fn add_document(core: &mut CoreState, window: u64, doc: u64) -> windows_core::Result<()> {
    ensure_tabs(core, window)?;
    let item = TabViewItem::new()?;
    item.SetHeader(&PropertyValue::CreateString(&HSTRING::new())?)?;
    item.SetTag(&PropertyValue::CreateUInt64(doc)?)?;
    // The tab's own menu (GNOME's HIG asks for the same two): a keyboard and
    // harness door that is not a drag.
    let flyout = MenuFlyout::new()?;
    for (label, close) in [("Move to New Window", false), ("Close", true)] {
        let entry = MenuFlyoutItem::new()?;
        entry.SetText(&HSTRING::from(label))?;
        entry.Click(&RoutedEventHandler::new(move |_, _| {
            enqueue(if close { DocEvent::Close(doc) } else { DocEvent::TearOut(doc) });
            Ok(())
        }))?;
        flyout.Items()?.Append(&entry.cast::<bindings::Microsoft::UI::Xaml::Controls::MenuFlyoutItemBase>()?)?;
    }
    item.SetContextFlyout(&flyout)?;
    let tabs = &core.docs.tabs[&window];
    tabs.view.TabItems()?.Append(&item.cast::<windows_core::IInspectable>()?)?;
    reflow(window, &tabs.view)?;
    let first = core.docs.order.get(&window).is_none_or(|o| o.is_empty());
    core.docs.pages.insert(doc, DocPage { window, item: item.clone(), root: None, title: String::new(), dirty: false, intercept: false });
    core.docs.order.entry(window).or_default().push(doc);
    if first {
        core.docs.active.insert(window, doc);
        core.docs.tabs[&window].view.SetSelectedItem(&item.cast::<windows_core::IInspectable>()?)?;
    }
    Ok(())
}

/// The active document's root in the window's host, and the caption title.
fn show_active(core: &mut CoreState, window: u64) -> windows_core::Result<()> {
    let Some(tabs) = core.docs.tabs.get(&window) else { return Ok(()) };
    let children = tabs.host.Children()?;
    let active = core.docs.active.get(&window).copied();
    let record = active.and_then(|d| core.docs.pages.get(&d));
    // THE ROOT ALREADY SHOWN STAYS PUT: a re-parented root loses focus, and a
    // title or mark refresh on every keystroke took the caret out of the
    // buffer mid-word (measured on the editor's tabs leg, 2026-10-28).
    let shown = match record.and_then(|r| r.root.as_ref()) {
        Some(root) => children.Size()? == 1 && children.GetAt(0)? == *root,
        None => children.Size()? == 0,
    };
    if !shown {
        children.Clear()?;
        if let Some(root) = record.and_then(|r| r.root.as_ref()) {
            unparent_element(root)?;
            children.Append(root)?;
        }
    }
    super::refresh_caption(core, window)
}

/// XAML refuses an element with a parent (docs/traps.md): a document's root
/// leaves the host before another window's host takes it.
fn unparent_element(element: &UIElement) -> windows_core::Result<()> {
    let fe: FrameworkElement = element.cast()?;
    if let Ok(parent) = fe.Parent() {
        if let Ok(panel) = parent.cast::<bindings::Microsoft::UI::Xaml::Controls::Panel>() {
            let children = panel.Children()?;
            let mut at = 0u32;
            if children.IndexOf(element, &mut at)? {
                children.RemoveAt(at)?;
            }
        }
    }
    Ok(())
}

pub(super) fn select_document(core: &mut CoreState, window: u64, doc: u64) -> windows_core::Result<()> {
    core.docs.active.insert(window, doc);
    if let (Some(tabs), Some(record)) = (core.docs.tabs.get(&window), core.docs.pages.get(&doc)) {
        tabs.view.SetSelectedItem(&record.item.cast::<windows_core::IInspectable>()?)?;
    }
    FRONT.with(|f| f.set(Some(window)));
    show_active(core, window)?;
    winui_window(core, window)?.Activate()
}

pub(super) fn close_document(core: &mut CoreState, doc: u64) -> windows_core::Result<()> {
    forget(core, doc, false)
}

pub(super) fn set_prop(core: &mut CoreState, doc: u64, prop: crate::protocol::DocumentProp, value: &Value) -> windows_core::Result<()> {
    use crate::protocol::DocumentProp;
    let Some(record) = core.docs.pages.get_mut(&doc) else { return Ok(()) };
    match (prop, value) {
        (DocumentProp::Title, Value::Str(s)) => {
            record.title = s.clone();
            record.item.SetHeader(&PropertyValue::CreateString(&HSTRING::from(&**s))?)?;
        }
        (DocumentProp::Tooltip, Value::Str(s)) => {
            bindings::Microsoft::UI::Xaml::Controls::ToolTipService::SetToolTip(
                &record.item,
                &PropertyValue::CreateString(&HSTRING::from(&**s))?,
            )?;
        }
        (DocumentProp::Dirty, Value::Bool(b)) => {
            record.dirty = *b;
            // The unsaved mark is the tab's glyph, never its header text,
            // which the harness and the app's strings read byte for byte.
            if *b {
                let glyph = FontIconSource::new()?;
                glyph.SetGlyph(&HSTRING::from("\u{25CF}"))?;
                // A TEXT FACE THAT CARRIES THE DOT: an unset family resolves to
                // Segoe Fluent Icons, which has no U+25CF and drew a missing-glyph
                // box (the review page's capture, 2026-10-28).
                glyph.SetFontFamily(&bindings::Microsoft::UI::Xaml::Media::FontFamily::CreateInstanceWithName(
                    &HSTRING::from("Segoe UI"),
                )?)?;
                record.item.SetIconSource(&glyph)?;
            } else {
                record.item.SetIconSource(None::<&bindings::Microsoft::UI::Xaml::Controls::IconSource>)?;
            }
        }
        (DocumentProp::InterceptClose, Value::Bool(b)) => record.intercept = *b,
        (p, v) => panic!("kaya: document prop {p:?} with {v:?} (the core validates both)"),
    }
    let window = record.window;
    if core.docs.active.get(&window) == Some(&doc) {
        show_active(core, window)?;
    }
    Ok(())
}

pub(super) fn set_new_document(core: &mut CoreState, window: u64, on: bool) -> windows_core::Result<()> {
    core.docs.new_document.insert(window, on);
    if let Some(tabs) = core.docs.tabs.get(&window) {
        tabs.view.SetIsAddTabButtonVisible(on)?;
    }
    Ok(())
}

pub(super) fn add_region(core: &mut CoreState, window: u64, region: u64, edge: u32) {
    core.docs.regions.insert(region, (window, edge));
}

/// A mount into a document or a region; false when the surface is neither.
pub(super) fn mount(core: &mut CoreState, surface: u64, element: &UIElement) -> windows_core::Result<bool> {
    if let Some(record) = core.docs.pages.get_mut(&surface) {
        record.root = Some(element.clone());
        let window = record.window;
        if core.docs.active.get(&window) == Some(&surface) {
            show_active(core, window)?;
        }
        winui_window(core, window)?.Activate()?;
        return Ok(true);
    }
    if let Some((window, edge)) = core.docs.regions.get(&surface).copied() {
        let Some(tabs) = core.docs.tabs.get(&window) else { return Ok(true) };
        let slot = &tabs.slots[(edge as usize).saturating_sub(1).min(2)];
        let children = slot.Children()?;
        children.Clear()?;
        children.Append(element)?;
        return Ok(true);
    }
    Ok(false)
}

fn forget(core: &mut CoreState, doc: u64, user: bool) -> windows_core::Result<()> {
    let Some(record) = core.docs.pages.remove(&doc) else { return Ok(()) };
    let window = record.window;
    if let Some(tabs) = core.docs.tabs.get(&window) {
        let items = tabs.view.TabItems()?;
        let mut at = 0u32;
        if items.IndexOf(&record.item.cast::<windows_core::IInspectable>()?, &mut at)? {
            items.RemoveAt(at)?;
            reflow(window, &tabs.view)?;
        }
    }
    if let Some(order) = core.docs.order.get_mut(&window) {
        order.retain(|d| *d != doc);
    }
    if user {
        core.scene.user_closed_document(WindowId(doc));
        core.occurrences.send(Occurrence::DocumentClosed { document: WindowId(doc) });
    }
    if core.docs.active.get(&window) == Some(&doc) {
        core.docs.active.remove(&window);
        let next = core.docs.tabs.get(&window).and_then(|t| t.view.SelectedItem().ok()).and_then(|i| doc_of(&i));
        if let Some(next) = next.filter(|n| core.docs.pages.contains_key(n)).or_else(|| core.docs.order.get(&window).and_then(|o| o.first().copied())) {
            core.docs.active.insert(window, next);
        }
    }
    if core.docs.order.get(&window).is_none_or(|o| o.is_empty()) {
        emptied(core, window)
    } else {
        show_active(core, window)
    }
}

/// A window left with no documents closes (Q2); the process ends when no
/// window holds documents (§1.2).
fn emptied(core: &mut CoreState, window: u64) -> windows_core::Result<()> {
    DOC_WINDOWS.with_borrow_mut(|set| set.remove(&window));
    core.docs.tabs.remove(&window);
    core.docs.order.remove(&window);
    let others = core.docs.order.values().any(|o| !o.is_empty());
    if window == 0 {
        if others {
            core.window.AppWindow()?.Hide()?;
        } else {
            request_exit(0);
        }
        return Ok(());
    }
    core.tearing_down.insert(window);
    if let Some(native) = core.aux_windows.remove(&window) {
        let _ = native.Close();
    }
    core.tearing_down.remove(&window);
    core.occurrences.send(Occurrence::WindowClosed { window: WindowId(window) });
    Ok(())
}

fn handle(core: &mut CoreState, event: DocEvent) -> windows_core::Result<()> {
    match event {
        DocEvent::Selected(window) => {
            let Some(tabs) = core.docs.tabs.get(&window) else { return Ok(()) };
            let Some(doc) = tabs.view.SelectedItem().ok().and_then(|i| doc_of(&i)) else { return Ok(()) };
            if core.docs.active.get(&window) == Some(&doc) || !core.docs.pages.contains_key(&doc) {
                return Ok(());
            }
            core.docs.active.insert(window, doc);
            core.scene.user_selected_document(WindowId(window), WindowId(doc));
            core.occurrences.send(Occurrence::DocumentSelected { window: WindowId(window), document: WindowId(doc) });
            show_active(core, window)
        }
        DocEvent::Close(doc) => user_close(core, doc),
        DocEvent::NewDocument(window) => {
            core.occurrences.send(Occurrence::NewDocumentRequested { window: WindowId(window) });
            Ok(())
        }
        DocEvent::Reordered(window) => {
            let Some(tabs) = core.docs.tabs.get(&window) else { return Ok(()) };
            let items = tabs.view.TabItems()?;
            let now: Vec<u64> = (0..items.Size()?).filter_map(|i| items.GetAt(i).ok().and_then(|it| doc_of(&it))).collect();
            let was = core.docs.order.get(&window).cloned().unwrap_or_default();
            for (doc, at) in crate::scene::reorder_moves(&was, &now) {
                core.scene.user_moved_document(WindowId(doc), WindowId(window), at);
                core.occurrences.send(Occurrence::DocumentMoved { document: WindowId(doc), window: WindowId(window), index: at });
            }
            core.docs.order.insert(window, now);
            Ok(())
        }
        DocEvent::TearOut(doc) => tear_out(core, doc),
        DocEvent::CloseWindow(window) => {
            let docs = core.docs.order.get(&window).cloned().unwrap_or_default();
            if docs.iter().any(|d| core.docs.pages.get(d).is_some_and(|r| r.intercept)) {
                core.occurrences.send(Occurrence::DocumentsCloseRequested {
                    window: WindowId(window),
                    documents: docs.into_iter().map(WindowId).collect(),
                });
                return Ok(());
            }
            for doc in docs {
                forget(core, doc, true)?;
            }
            Ok(())
        }
    }
}

/// The user's close of one document (its tab's x, its menu, the harness).
fn user_close(core: &mut CoreState, doc: u64) -> windows_core::Result<()> {
    let Some(record) = core.docs.pages.get(&doc) else { return Ok(()) };
    if record.intercept {
        core.occurrences.send(Occurrence::DocumentCloseRequested { document: WindowId(doc) });
        return Ok(());
    }
    forget(core, doc, true)
}

/// A tab out of its window: a new kaya window the core names (§1.2).
fn tear_out(core: &mut CoreState, doc: u64) -> windows_core::Result<()> {
    let Some(source) = core.docs.pages.get(&doc).map(|r| r.window) else { return Ok(()) };
    if core.docs.order.get(&source).is_some_and(|o| o.len() < 2) {
        return Ok(());
    }
    let window = core.scene.user_detached_documents(WindowId(source), &[WindowId(doc)]).0;
    create_aux_window(core, window)?;
    ensure_tabs(core, window)?;
    let record = core.docs.pages.get_mut(&doc).expect("checked above");
    let item = record.item.clone();
    record.window = window;
    if let Some(tabs) = core.docs.tabs.get(&source) {
        let items = tabs.view.TabItems()?;
        let mut at = 0u32;
        if items.IndexOf(&item.cast::<windows_core::IInspectable>()?, &mut at)? {
            items.RemoveAt(at)?;
            reflow(source, &tabs.view)?;
        }
    }
    if let Some(order) = core.docs.order.get_mut(&source) {
        order.retain(|d| *d != doc);
    }
    if core.docs.active.get(&source) == Some(&doc) {
        core.docs.active.remove(&source);
        if let Some(next) = core.docs.order.get(&source).and_then(|o| o.first().copied()) {
            core.docs.active.insert(source, next);
            if let (Some(tabs), Some(r)) = (core.docs.tabs.get(&source), core.docs.pages.get(&next)) {
                tabs.view.SetSelectedItem(&r.item.cast::<windows_core::IInspectable>()?)?;
            }
        }
    }
    show_active(core, source)?;
    core.docs.tabs[&window].view.TabItems()?.Append(&item.cast::<windows_core::IInspectable>()?)?;
    reflow(window, &core.docs.tabs[&window].view)?;
    core.docs.tabs[&window].view.SetSelectedItem(&item.cast::<windows_core::IInspectable>()?)?;
    core.docs.order.insert(window, vec![doc]);
    core.docs.active.insert(window, doc);
    show_active(core, window)?;
    FRONT.with(|f| f.set(Some(window)));
    winui_window(core, window)?.Activate()?;
    core.occurrences.send(Occurrence::DocumentsDetached {
        source: WindowId(source),
        window: WindowId(window),
        documents: vec![WindowId(doc)],
    });
    Ok(())
}

// --- The harness's reads and drives (docs/doctabs-plan.md §4): the tab row's
// own items, headers and selection. The drives take the user's route and
// emit through the same handlers (the select_section precedent).

pub(super) fn active_window(core: &CoreState) -> Option<u64> {
    FRONT
        .with(|f| f.get())
        .filter(|w| core.docs.tabs.contains_key(w))
        .or_else(|| core.docs.tabs.keys().min().copied())
}

fn items_of(view: &TabView) -> Vec<TabViewItem> {
    let Ok(items) = view.TabItems() else { return Vec::new() };
    (0..items.Size().unwrap_or(0)).filter_map(|i| items.GetAt(i).ok()?.cast().ok()).collect()
}

fn header(item: &TabViewItem) -> String {
    item.Header().map(|h| string_of(&h)).unwrap_or_default()
}

pub(super) fn titles(core: &CoreState) -> Option<Vec<String>> {
    let window = active_window(core)?;
    Some(items_of(&core.docs.tabs.get(&window)?.view).iter().map(header).collect())
}

pub(super) fn active_title(core: &CoreState) -> Option<String> {
    let window = active_window(core)?;
    let selected = core.docs.tabs.get(&window)?.view.SelectedItem().ok()?;
    Some(header(&selected.cast().ok()?))
}

fn find(core: &CoreState, title: &str) -> Option<(u64, TabViewItem)> {
    core.docs.tabs.iter().find_map(|(w, tabs)| items_of(&tabs.view).into_iter().find(|i| header(i) == title).map(|i| (*w, i)))
}

fn shown(core: &CoreState) -> String {
    let all: Vec<String> = core.docs.tabs.values().flat_map(|t| items_of(&t.view).iter().map(header).collect::<Vec<_>>()).collect();
    format!("tabs: {}", all.join(", "))
}

pub(super) fn dirty(core: &CoreState, title: &str) -> Result<bool, String> {
    let Some((_, item)) = find(core, title) else { return Err(format!("no tab titled {title:?} ({})", shown(core))) };
    Ok(item.IconSource().is_ok())
}

pub(super) fn select(core: &mut CoreState, title: &str) -> Result<(), String> {
    let Some((window, item)) = find(core, title) else { return Err(format!("no tab titled {title:?} ({})", shown(core))) };
    let doc = item.Tag().ok().and_then(|t| t.cast::<IReference<u64>>().ok()).and_then(|r| r.Value().ok());
    let Some(doc) = doc else { return Err(format!("the tab {title:?} carries no document id")) };
    FRONT.with(|f| f.set(Some(window)));
    let _ = winui_window(core, window).and_then(|w| w.Activate());
    if core.docs.active.get(&window) == Some(&doc) {
        return Ok(());
    }
    core.docs.active.insert(window, doc);
    let _ = core.docs.tabs[&window].view.SetSelectedItem(&item.cast::<windows_core::IInspectable>().map_err(|e| e.message())?);
    core.scene.user_selected_document(WindowId(window), WindowId(doc));
    core.occurrences.send(Occurrence::DocumentSelected { window: WindowId(window), document: WindowId(doc) });
    show_active(core, window).map_err(|e| e.message())
}

fn doc_titled(core: &CoreState, title: &str) -> Result<u64, String> {
    let Some((_, item)) = find(core, title) else { return Err(format!("no tab titled {title:?} ({})", shown(core))) };
    item.Tag().ok().and_then(|t| t.cast::<IReference<u64>>().ok()).and_then(|r| r.Value().ok()).ok_or_else(|| format!("the tab {title:?} carries no document id"))
}

pub(super) fn close(core: &mut CoreState, title: &str) -> Result<(), String> {
    let doc = doc_titled(core, title)?;
    user_close(core, doc).map_err(|e| e.message())
}

pub(super) fn press_plus(core: &mut CoreState) -> Result<(), String> {
    let Some(window) = active_window(core) else { return Err("no window holds documents".into()) };
    if !core.docs.tabs[&window].view.IsAddTabButtonVisible().unwrap_or(false) {
        return Err("no + is drawn (is new_document armed?)".into());
    }
    core.occurrences.send(Occurrence::NewDocumentRequested { window: WindowId(window) });
    Ok(())
}

pub(super) fn move_out(core: &mut CoreState, title: &str) -> Result<(), String> {
    let doc = doc_titled(core, title)?;
    tear_out(core, doc).map_err(|e| e.message())
}

pub(super) fn close_native(core: &mut CoreState) -> Result<(), String> {
    let Some(window) = active_window(core) else { return Err("no window holds documents".into()) };
    handle(core, DocEvent::CloseWindow(window)).map_err(|e| e.message())
}

/// Empty when the front window's tab row is where Q9 puts it and shows only
/// what it needs: inside the frame's caption band, its tabs and "+" taking
/// clicks while its footer drags the window (HTCAPTION), and its scroll
/// buttons drawn only while the tabs at their minimum width do not fit.
/// Otherwise what was measured.
#[cfg(feature = "harness")]
pub(super) fn row_report(core: &CoreState) -> String {
    let Some(window) = active_window(core) else { return String::new() };
    row_measure(core, window).unwrap_or_else(|e| format!("window {window}'s tab row could not be read: {}", e.message()))
}

#[cfg(feature = "harness")]
fn row_measure(core: &CoreState, window: u64) -> windows_core::Result<String> {
    const HTCLIENT: isize = 1;
    const HTCAPTION: isize = 2;
    use bindings::Windows::Foundation::Rect;
    let Some(tabs) = core.docs.tabs.get(&window) else { return Ok(String::new()) };
    let view = &tabs.view;
    let Some(titlebar) = core.window_titlebars.get(&window) else {
        return Ok(format!("window {window} holds documents and has no caption TitleBar, so its tab row is not in the caption"));
    };
    if caption_row(titlebar).as_ref() != Some(view) {
        return Ok(format!("window {window}'s tab row is not its caption TitleBar's content"));
    }
    let target = winui_window(core, window)?;
    let band = f64::from(target.AppWindow()?.TitleBar()?.Height()?);
    let scale = view.XamlRoot()?.RasterizationScale()?;
    let Some(hwnd) = window_hwnd(core, window) else { return Ok(format!("window {window} has no HWND")) };
    let client = client_origin(hwnd);
    // A point of an element, in screen pixels, and the element's box in the
    // client area's pixels.
    let place = |element: &FrameworkElement| -> windows_core::Result<Option<(Rect, (i32, i32))>> {
        let (w, h) = (element.ActualWidth()?, element.ActualHeight()?);
        if w <= 0.0 || h <= 0.0 {
            return Ok(None);
        }
        let b = element
            .TransformToVisual(None::<&UIElement>)?
            .TransformBounds(Rect { X: 0.0, Y: 0.0, Width: w as f32, Height: h as f32 })?;
        let px = Rect {
            X: (f64::from(b.X) * scale) as f32,
            Y: (f64::from(b.Y) * scale) as f32,
            Width: (f64::from(b.Width) * scale) as f32,
            Height: (f64::from(b.Height) * scale) as f32,
        };
        let centre = (
            client.x + (f64::from(px.X) + f64::from(px.Width) / 2.0).round() as i32,
            client.y + (f64::from(px.Y) + f64::from(px.Height) / 2.0).round() as i32,
        );
        Ok(Some((px, centre)))
    };
    let mut wrong = Vec::new();
    let row: FrameworkElement = view.cast()?;
    let Some((at, _)) = place(&row)? else { return Ok(format!("window {window}'s tab row is not arranged")) };
    let (top, bottom) = (f64::from(at.Y), f64::from(at.Y) + f64::from(at.Height));
    if top < -0.5 || bottom > band + 0.5 {
        wrong.push(format!("the tab row spans y {top:.0}..{bottom:.0} px, outside the frame's caption band 0..{band:.0} px"));
    }
    let items = items_of(view);
    // The selected tab, which the row keeps scrolled into view.
    if let Some(selected) = view.SelectedItem().ok().and_then(|i| i.cast::<FrameworkElement>().ok()) {
        if let Some((_, (x, y))) = place(&selected)? {
            let ht = nc_hit(hwnd, x, y);
            if ht != HTCLIENT {
                wrong.push(format!("the selected tab answers hit test {ht} at its centre ({x},{y}), not HTCLIENT"));
            }
        }
    }
    let root: UIElement = view.cast()?;
    if let Some(add) = named_descendant(&root, "AddButton")?.filter(|a| a.Visibility().ok() == Some(Visibility::Visible)) {
        if let Some((_, (x, y))) = place(&add)? {
            let ht = nc_hit(hwnd, x, y);
            if ht != HTCLIENT {
                wrong.push(format!("the \"+\" answers hit test {ht} at its centre ({x},{y}), not HTCLIENT"));
            }
        }
    }
    match view.TabStripFooter().ok().and_then(|f| f.cast::<FrameworkElement>().ok()) {
        Some(footer) => match place(&footer)? {
            Some((_, (x, y))) => {
                let ht = nc_hit(hwnd, x, y);
                if ht != HTCAPTION {
                    let mut win = super::Rect::default();
                    // SAFETY: a live HWND with a stack RECT.
                    unsafe { GetWindowRect(hwnd, &mut win) };
                    let mut runs: Vec<(i32, i32, isize)> = Vec::new();
                    for sx in (win.left + 1..win.right - 1).step_by(4) {
                        let h = nc_hit(hwnd, sx, y);
                        match runs.last_mut() {
                            Some(run) if run.2 == h => run.1 = sx,
                            _ => runs.push((sx, sx, h)),
                        }
                    }
                    wrong.push(format!(
                        "the empty caption after the tabs answers hit test {ht} at ({x},{y}), not HTCAPTION, so it does not drag the window (window {}..{}, client origin {}, along y={y}: {})",
                        win.left,
                        win.right,
                        client.x,
                        runs.iter().map(|(a, b, h)| format!("{a}..{b}={h}")).collect::<Vec<_>>().join(" ")
                    ));
                }
            }
            None => wrong.push("the tab row's footer, its empty caption, is not arranged".into()),
        },
        None => wrong.push("the tab row has no footer, so no empty caption is left to drag".into()),
    }
    // DRAWN, not merely Visible: the scroll viewer hides its buttons by
    // collapsing a panel above them.
    let shown = |name: &str| -> windows_core::Result<bool> {
        use bindings::Microsoft::UI::Xaml::Media::VisualTreeHelper;
        let Some(button) = named_descendant(&root, name)? else { return Ok(false) };
        if button.ActualWidth()? <= 0.0 {
            return Ok(false);
        }
        let mut at: Option<bindings::Microsoft::UI::Xaml::DependencyObject> = Some(button.cast()?);
        while let Some(node) = at {
            if let Ok(el) = node.cast::<UIElement>() {
                if el.Visibility()? != Visibility::Visible || el.Opacity()? <= 0.0 {
                    return Ok(false);
                }
                if el == root {
                    return Ok(true);
                }
            }
            at = VisualTreeHelper::GetParent(&node).ok();
        }
        Ok(false)
    };
    let arrows = shown("ScrollDecreaseButton")? || shown("ScrollIncreaseButton")?;
    if arrows {
        let least = theme_resource::<IReference<f64>>("TabViewItemMinWidth").and_then(|v| v.Value()).unwrap_or(0.0);
        let widths: Vec<f64> = items.iter().map(|i| i.ActualWidth().unwrap_or(0.0)).collect();
        if widths.iter().any(|w| *w > least + 0.5) {
            wrong.push(format!(
                "the scroll buttons are drawn over {} tab(s) {:?} DIP wide, wider than their {least} DIP minimum, so the row has room it is scrolling instead of using",
                widths.len(),
                widths.iter().map(|w| w.round()).collect::<Vec<_>>()
            ));
        }
    }
    Ok(wrong.join("; "))
}
