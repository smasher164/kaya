// Document tabs on Windows (docs/doctabs-plan.md §3): a TabView used as the
// tab ROW (Windows Terminal's shape) above the window's content, the active
// document's root shown below it beside the shared regions; a tab dropped
// outside, or the tab's Move to New Window, is a new kaya window (§1.2).
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
    view.SetCanDragTabs(true)?;
    view.SetVerticalAlignment(bindings::Microsoft::UI::Xaml::VerticalAlignment::Top)?;
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
    for (value, unit) in [(1.0, GridUnitType::Auto), (1.0, GridUnitType::Star), (1.0, GridUnitType::Auto)] {
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
    Grid::SetRow(&view.cast::<FrameworkElement>()?, 0)?;
    Grid::SetRow(&middle.cast::<FrameworkElement>()?, 1)?;
    Grid::SetRow(&slots[2].cast::<FrameworkElement>()?, 2)?;
    outer.Children()?.Append(&view.cast::<UIElement>()?)?;
    outer.Children()?.Append(&middle.cast::<UIElement>()?)?;
    outer.Children()?.Append(&slots[2].cast::<UIElement>()?)?;
    set_window_content(core, window, &outer.cast::<UIElement>()?)?;
    DOC_WINDOWS.with_borrow_mut(|set| set.insert(window));
    if FRONT.with(|f| f.get()).is_none() {
        FRONT.with(|f| f.set(Some(window)));
    }
    core.docs.tabs.insert(window, WinTabs { view, host, slots });
    Ok(())
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
    children.Clear()?;
    let active = core.docs.active.get(&window).copied();
    if let Some(record) = active.and_then(|d| core.docs.pages.get(&d)) {
        if let Some(root) = &record.root {
            unparent_element(root)?;
            children.Append(root)?;
        }
        let title = record.title.clone();
        let dirty = record.dirty;
        winui_window(core, window)?.SetTitle(&HSTRING::from(if dirty { format!("*{title}") } else { title }))?;
    }
    Ok(())
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
