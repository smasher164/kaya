// Document tabs on GNOME (docs/doctabs-plan.md §3): one AdwTabView and
// AdwTabBar per window with documents, the shared regions beside the view, a
// tear-out a new kaya window (§1.2). Every toolkit signal is queued and
// drained on an idle with CORE borrowed, since the same signals fire from
// kaya's own calls while CORE is already borrowed.

use super::*;
use adw::prelude::*;

/// One document's page: the box the mount fills, and its props.
pub(super) struct DocPage {
    pub window: u64,
    pub page: gtk4::Box,
    pub title: String,
    pub tooltip: String,
    pub dirty: bool,
    pub intercept: bool,
}

/// One window's tab machinery and its region slots.
pub(super) struct WinTabs {
    pub view: adw::TabView,
    pub slots: [gtk4::Box; 3],
    pub plus: gtk4::Button,
}

/// One shared region: its window, its edge (1 leading, 2 trailing, 3 bottom).
pub(super) struct Region {
    pub window: u64,
    pub edge: u32,
}

#[derive(Default)]
pub(super) struct Docs {
    pub pages: HashMap<u64, DocPage>,
    pub order: HashMap<u64, Vec<u64>>,
    pub active: HashMap<u64, u64>,
    pub tabs: HashMap<u64, WinTabs>,
    pub regions: HashMap<u64, Region>,
    pub new_document: HashMap<u64, bool>,
    /// Windows the toolkit made for a tear-out, by their source window.
    pub tearouts: HashMap<u64, u64>,
    /// Documents closing for the app (no echo) and for a window's own close.
    pub closing_quiet: std::collections::HashSet<u64>,
    pub closing_user: std::collections::HashSet<u64>,
}

enum DocEvent {
    Selected(adw::TabView),
    Close(adw::TabView, adw::TabPage),
    Attached(adw::TabView, adw::TabPage, i32),
    Reordered(adw::TabView, adw::TabPage, i32),
    Detached(adw::TabView),
    CloseWindow(u64),
}

thread_local! {
    static EVENTS: RefCell<Vec<DocEvent>> = const { RefCell::new(Vec::new()) };
    static PENDING: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    /// The windows whose native close is a documents close (§1.5).
    static DOC_WINDOWS: RefCell<std::collections::HashSet<u64>> = RefCell::new(Default::default());
    static QUIET: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    /// The documents window the user is in, by kaya's own account: the last
    /// one activated, presented or torn out. A wayland compositor need not
    /// activate a window a tear-out presents, so is-active alone cannot say.
    static FRONT: std::cell::Cell<Option<u64>> = const { std::cell::Cell::new(None) };
}

fn bring_front(window: u64) {
    FRONT.with(|f| f.set(Some(window)));
}

fn enqueue(event: DocEvent) {
    EVENTS.with_borrow_mut(|q| q.push(event));
    if !PENDING.with(|p| p.replace(true)) {
        glib::idle_add_local_once(drain);
    }
}

fn drain() {
    PENDING.with(|p| p.set(false));
    let ran = CORE.with(|cell| {
        let Ok(mut core) = cell.try_borrow_mut() else { return false };
        let Some(core) = core.as_mut() else { return true };
        for event in EVENTS.with_borrow_mut(std::mem::take) {
            handle(core, event);
        }
        true
    });
    if !ran && !PENDING.with(|p| p.replace(true)) {
        glib::idle_add_local_once(drain);
    }
}

/// The window's native close is the documents' close, asked in one go.
pub(super) fn native_close(id: u64) -> bool {
    if DOC_WINDOWS.with_borrow(|set| set.contains(&id)) {
        enqueue(DocEvent::CloseWindow(id));
        return true;
    }
    false
}

fn doc_of(page: &adw::TabPage) -> Option<u64> {
    page.child().widget_name().strip_prefix("kaya-doc-")?.parse().ok()
}

fn window_of(core: &CoreState, view: &adw::TabView) -> Option<u64> {
    core.docs.tabs.iter().find(|(_, t)| &t.view == view).map(|(w, _)| *w)
}

fn quietly<T>(f: impl FnOnce() -> T) -> T {
    let was = QUIET.with(|q| q.replace(true));
    let out = f();
    QUIET.with(|q| q.set(was));
    out
}

/// The window's tabs, made on its first document.
pub(super) fn ensure_tabs(core: &mut CoreState, window: u64) {
    if core.docs.tabs.contains_key(&window) {
        return;
    }
    let view = adw::TabView::new();
    view.set_hexpand(true);
    view.set_vexpand(true);
    let bar = adw::TabBar::new();
    bar.set_view(Some(&view));
    view.connect_selected_page_notify(|view| {
        if !QUIET.with(|q| q.get()) {
            enqueue(DocEvent::Selected(view.clone()));
        }
    });
    view.connect_close_page(|view, page| {
        enqueue(DocEvent::Close(view.clone(), page.clone()));
        glib::Propagation::Stop
    });
    view.connect_page_attached(|view, page, at| enqueue(DocEvent::Attached(view.clone(), page.clone(), at)));
    view.connect_page_reordered(|view, page, at| {
        enqueue(DocEvent::Reordered(view.clone(), page.clone(), at))
    });
    view.connect_page_detached(|view, _, _| enqueue(DocEvent::Detached(view.clone())));
    view.connect_create_window(move |view| {
        CORE.with(|cell| {
            let mut core = cell.try_borrow_mut().ok()?;
            let core = core.as_mut()?;
            let source = window_of(core, view)?;
            Some(tear_out_window(core, source))
        })
    });
    // GNOME's per-tab menu (developer.gnome.org/hig/patterns/nav/tabs.html):
    // Move to New Window and Close, on the page the menu was opened for.
    let menu = gio::Menu::new();
    menu.append(Some("Move to New Window"), Some("doctab.move"));
    menu.append(Some("Close"), Some("doctab.close"));
    view.set_menu_model(Some(&menu));
    let chosen: Rc<RefCell<Option<adw::TabPage>>> = Rc::new(RefCell::new(None));
    view.connect_setup_menu({
        let chosen = chosen.clone();
        move |_, page| *chosen.borrow_mut() = page.cloned()
    });
    let actions = gio::SimpleActionGroup::new();
    let move_action = gio::SimpleAction::new("move", None);
    move_action.connect_activate({
        let chosen = chosen.clone();
        let view = view.downgrade();
        move |_, _| {
            if let (Some(page), Some(view)) = (chosen.borrow().clone(), view.upgrade()) {
                move_to_new_window(&view, &page);
            }
        }
    });
    let close_action = gio::SimpleAction::new("close", None);
    close_action.connect_activate({
        let view = view.downgrade();
        move |_, _| {
            if let (Some(page), Some(view)) = (chosen.borrow().clone(), view.upgrade()) {
                view.close_page(&page);
            }
        }
    });
    actions.add_action(&move_action);
    actions.add_action(&close_action);
    view.insert_action_group("doctab", Some(&actions));

    let slots = [
        gtk4::Box::new(gtk4::Orientation::Vertical, 0),
        gtk4::Box::new(gtk4::Orientation::Vertical, 0),
        gtk4::Box::new(gtk4::Orientation::Horizontal, 0),
    ];
    for slot in &slots {
        slot.set_visible(false);
    }
    let middle = gtk4::Box::new(gtk4::Orientation::Horizontal, 0);
    middle.append(&slots[0]);
    middle.append(&view);
    middle.append(&slots[1]);
    middle.set_vexpand(true);
    let outer = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    outer.append(&bar);
    outer.append(&middle);
    outer.append(&slots[2]);

    // The "+" in the header bar's start, GNOME Text Editor's place for it.
    let plus = gtk4::Button::from_icon_name("tab-new-symbolic");
    plus.set_tooltip_text(Some("New Tab"));
    plus.set_visible(core.docs.new_document.get(&window).copied().unwrap_or(false));
    {
        let sink = core.occurrences.clone();
        plus.connect_clicked(move |_| sink.send(Occurrence::NewDocumentRequested { window: WindowId(window) }));
    }
    if let Some(header) = core.header_bars.get(&window) {
        header.pack_start(&plus);
    }
    set_window_content(core, window, Some(outer.upcast_ref()));
    DOC_WINDOWS.with_borrow_mut(|set| set.insert(window));
    if let Some(native) = gtk_window_read(core, window) {
        native.connect_is_active_notify(move |native| {
            if native.is_active() {
                bring_front(window);
            }
        });
    }
    if FRONT.with(|f| f.get()).is_none() {
        bring_front(window);
    }
    core.docs.tabs.insert(window, WinTabs { view, slots, plus });
}

/// A native window for a tear-out: a new kaya window the core names, with
/// its own tabs. The app hears documents_detached once the page lands.
fn tear_out_window(core: &mut CoreState, source: u64) -> adw::TabView {
    let window = core.scene.user_detached_documents(WindowId(source), &[]).0;
    create_aux_window(core, window);
    ensure_tabs(core, window);
    core.docs.tearouts.insert(window, source);
    if let Some(native) = core.aux_windows.get(&window) {
        native.present();
    }
    bring_front(window);
    core.docs.tabs[&window].view.clone()
}

/// Move a page into a new window, as the tab menu's Move to New Window does.
pub(super) fn move_to_new_window(view: &adw::TabView, page: &adw::TabPage) {
    let view = view.clone();
    let page = page.clone();
    glib::idle_add_local_once(move || {
        let target = CORE.with(|cell| {
            let mut core = cell.try_borrow_mut().ok()?;
            let core = core.as_mut()?;
            let source = window_of(core, &view)?;
            Some(tear_out_window(core, source))
        });
        if let Some(target) = target {
            view.transfer_page(&page, &target, 0);
        }
    });
}

pub(super) fn add_document(core: &mut CoreState, window: u64, doc: u64) {
    ensure_tabs(core, window);
    let page = gtk4::Box::new(gtk4::Orientation::Vertical, 0);
    page.set_widget_name(&format!("kaya-doc-{doc}"));
    page.set_hexpand(true);
    page.set_vexpand(true);
    let tabs = &core.docs.tabs[&window];
    let first = tabs.view.n_pages() == 0;
    quietly(|| tabs.view.append(&page));
    core.docs.pages.insert(
        doc,
        DocPage { window, page, title: String::new(), tooltip: String::new(), dirty: false, intercept: false },
    );
    core.docs.order.entry(window).or_default().push(doc);
    if first {
        core.docs.active.insert(window, doc);
    }
    refresh_header(core, window);
}

fn tab_page(core: &CoreState, doc: u64) -> Option<(adw::TabView, adw::TabPage)> {
    let record = core.docs.pages.get(&doc)?;
    let view = core.docs.tabs.get(&record.window)?.view.clone();
    let page = view.page(&record.page);
    Some((view, page))
}

pub(super) fn select_document(core: &mut CoreState, window: u64, doc: u64) {
    if let Some((view, page)) = tab_page(core, doc) {
        quietly(|| view.set_selected_page(&page));
    }
    core.docs.active.insert(window, doc);
    if let Some(native) = gtk_window_read(core, window) {
        native.present();
    }
    bring_front(window);
    refresh_header(core, window);
}

pub(super) fn close_document(core: &mut CoreState, doc: u64) {
    if let Some((view, page)) = tab_page(core, doc) {
        core.docs.closing_quiet.insert(doc);
        view.close_page(&page);
    }
}

pub(super) fn set_prop(core: &mut CoreState, doc: u64, prop: crate::protocol::DocumentProp, value: &Value) {
    use crate::protocol::DocumentProp;
    let Some(record) = core.docs.pages.get_mut(&doc) else { return };
    match (prop, value) {
        (DocumentProp::Title, Value::Str(s)) => record.title = s.clone(),
        (DocumentProp::Tooltip, Value::Str(s)) => record.tooltip = s.clone(),
        (DocumentProp::Dirty, Value::Bool(b)) => record.dirty = *b,
        (DocumentProp::InterceptClose, Value::Bool(b)) => record.intercept = *b,
        (p, v) => panic!("kaya: document prop {p:?} with {v:?} (the core validates both)"),
    }
    let window = record.window;
    if let Some((_, page)) = tab_page(core, doc) {
        let record = &core.docs.pages[&doc];
        page.set_title(&record.title);
        page.set_tooltip(&record.tooltip);
        // The unsaved mark is the page's indicator, never its title, which
        // the harness and the app's strings read byte for byte.
        if record.dirty {
            page.set_indicator_icon(Some(&gio::ThemedIcon::new("document-modified-symbolic")));
            page.set_indicator_tooltip("Unsaved changes");
        } else {
            page.set_indicator_icon(gio::Icon::NONE);
        }
    }
    refresh_header(core, window);
}

pub(super) fn set_new_document(core: &mut CoreState, window: u64, on: bool) {
    core.docs.new_document.insert(window, on);
    if let Some(tabs) = core.docs.tabs.get(&window) {
        tabs.plus.set_visible(on);
    }
}

pub(super) fn add_region(core: &mut CoreState, window: u64, region: u64, edge: u32) {
    core.docs.regions.insert(region, Region { window, edge });
}

/// A mount into a document or a region; false when the surface is neither.
pub(super) fn mount(core: &mut CoreState, surface: u64, root: &gtk4::Widget) -> bool {
    if let Some(record) = core.docs.pages.get(&surface) {
        while let Some(old) = record.page.first_child() {
            record.page.remove(&old);
        }
        root.set_hexpand(true);
        root.set_vexpand(true);
        record.page.append(root);
        return true;
    }
    if let Some(region) = core.docs.regions.get(&surface) {
        let Some(tabs) = core.docs.tabs.get(&region.window) else { return true };
        let slot = &tabs.slots[(region.edge as usize).saturating_sub(1).min(2)];
        while let Some(old) = slot.first_child() {
            slot.remove(&old);
        }
        slot.append(root);
        slot.set_visible(true);
        return true;
    }
    false
}

/// The window's title and unsaved mark follow its active document (§1.4).
fn refresh_header(core: &mut CoreState, window: u64) {
    let Some(doc) = core.docs.active.get(&window).copied() else { return };
    let Some(record) = core.docs.pages.get(&doc) else { return };
    let (title, dirty) = (record.title.clone(), record.dirty);
    if let Some(native) = gtk_window_read(core, window) {
        native.set_title(Some(&title));
    }
    if let Some(marker) = core.dirty_markers.get(&window) {
        marker.set_visible(dirty);
    }
}

fn forget(core: &mut CoreState, doc: u64, user: bool) {
    let Some(record) = core.docs.pages.remove(&doc) else { return };
    let window = record.window;
    if let Some(order) = core.docs.order.get_mut(&window) {
        order.retain(|d| *d != doc);
    }
    if user {
        core.scene.user_closed_document(WindowId(doc));
        core.occurrences.send(Occurrence::DocumentClosed { document: WindowId(doc) });
    }
    if core.docs.active.get(&window) == Some(&doc) {
        core.docs.active.remove(&window);
        if let Some(tabs) = core.docs.tabs.get(&window) {
            if let Some(page) = tabs.view.selected_page().filter(|p| doc_of(p) != Some(doc)) {
                if let Some(next) = doc_of(&page) {
                    core.docs.active.insert(window, next);
                }
            }
        }
    }
    if core.docs.order.get(&window).is_none_or(|o| o.is_empty()) {
        emptied(core, window);
    } else {
        refresh_header(core, window);
    }
}

/// A window left with no documents closes (Q2); the process ends when no
/// window holds documents (§1.2).
fn emptied(core: &mut CoreState, window: u64) {
    DOC_WINDOWS.with_borrow_mut(|set| set.remove(&window));
    core.docs.tabs.remove(&window);
    core.docs.order.remove(&window);
    let others = core.docs.order.values().any(|o| !o.is_empty());
    if window == 0 {
        if others {
            core.window.set_visible(false);
        } else {
            core.window.destroy();
        }
        return;
    }
    if let Some(native) = core.aux_windows.remove(&window) {
        native.destroy();
    }
    core.occurrences.send(Occurrence::WindowClosed { window: WindowId(window) });
}

fn handle(core: &mut CoreState, event: DocEvent) {
    match event {
        DocEvent::Selected(view) => {
            let Some(window) = window_of(core, &view) else { return };
            let Some(doc) = view.selected_page().and_then(|p| doc_of(&p)) else { return };
            if core.docs.active.get(&window) == Some(&doc) || !core.docs.pages.contains_key(&doc) {
                return;
            }
            core.docs.active.insert(window, doc);
            core.scene.user_selected_document(WindowId(window), WindowId(doc));
            core.occurrences.send(Occurrence::DocumentSelected { window: WindowId(window), document: WindowId(doc) });
            refresh_header(core, window);
        }
        DocEvent::Close(view, page) => {
            let Some(doc) = doc_of(&page) else {
                view.close_page_finish(&page, true);
                return;
            };
            if core.docs.closing_quiet.remove(&doc) {
                view.close_page_finish(&page, true);
                forget(core, doc, false);
                return;
            }
            let user_window_close = core.docs.closing_user.remove(&doc);
            let armed = core.docs.pages.get(&doc).is_some_and(|r| r.intercept);
            if armed && !user_window_close {
                view.close_page_finish(&page, false);
                core.occurrences.send(Occurrence::DocumentCloseRequested { document: WindowId(doc) });
                return;
            }
            view.close_page_finish(&page, true);
            forget(core, doc, true);
        }
        DocEvent::Attached(view, page, at) => {
            let (Some(window), Some(doc)) = (window_of(core, &view), doc_of(&page)) else { return };
            let Some(record) = core.docs.pages.get_mut(&doc) else { return };
            let from = record.window;
            if from == window {
                return;
            }
            record.window = window;
            if let Some(order) = core.docs.order.get_mut(&from) {
                order.retain(|d| *d != doc);
            }
            let order = core.docs.order.entry(window).or_default();
            let at = (at.max(0) as usize).min(order.len());
            order.insert(at, doc);
            core.docs.active.insert(window, doc);
            core.scene.user_moved_document(WindowId(doc), WindowId(window), at as u32);
            if core.docs.tearouts.get(&window) == Some(&from) {
                core.docs.tearouts.remove(&window);
                core.occurrences.send(Occurrence::DocumentsDetached {
                    source: WindowId(from),
                    window: WindowId(window),
                    documents: vec![WindowId(doc)],
                });
            } else {
                core.occurrences.send(Occurrence::DocumentMoved {
                    document: WindowId(doc),
                    window: WindowId(window),
                    index: at as u32,
                });
            }
            refresh_header(core, window);
            if core.docs.active.get(&from) == Some(&doc) {
                core.docs.active.remove(&from);
            }
            if core.docs.order.get(&from).is_none_or(|o| o.is_empty()) {
                emptied(core, from);
            }
        }
        DocEvent::Reordered(view, page, at) => {
            let (Some(window), Some(doc)) = (window_of(core, &view), doc_of(&page)) else { return };
            let order = core.docs.order.entry(window).or_default();
            order.retain(|d| *d != doc);
            let at = (at.max(0) as usize).min(order.len());
            order.insert(at, doc);
            core.scene.user_moved_document(WindowId(doc), WindowId(window), at as u32);
            core.occurrences.send(Occurrence::DocumentMoved {
                document: WindowId(doc),
                window: WindowId(window),
                index: at as u32,
            });
        }
        DocEvent::Detached(_) => {}
        DocEvent::CloseWindow(window) => {
            let docs = core.docs.order.get(&window).cloned().unwrap_or_default();
            if docs.iter().any(|d| core.docs.pages.get(d).is_some_and(|r| r.intercept)) {
                core.occurrences.send(Occurrence::DocumentsCloseRequested {
                    window: WindowId(window),
                    documents: docs.into_iter().map(WindowId).collect(),
                });
                return;
            }
            for doc in docs {
                if let Some((view, page)) = tab_page(core, doc) {
                    core.docs.closing_user.insert(doc);
                    view.close_page(&page);
                }
            }
        }
    }
}

// --- The harness's reads and drives (docs/doctabs-plan.md §4): the tab
// view's own pages and selection, never kaya's maps.

/// The documents window the user is in: the active native one, else the
/// first that holds documents.
pub(super) fn active_window(core: &CoreState) -> Option<u64> {
    let mut windows: Vec<u64> = core.docs.tabs.keys().copied().collect();
    windows.sort();
    FRONT
        .with(|f| f.get())
        .filter(|w| core.docs.tabs.contains_key(w))
        .or_else(|| windows.iter().copied().find(|w| gtk_window_read(core, *w).is_some_and(|n| n.is_active())))
        .or_else(|| windows.first().copied())
}

fn pages_of(view: &adw::TabView) -> Vec<adw::TabPage> {
    (0..view.n_pages()).map(|i| view.nth_page(i)).collect()
}

pub(super) fn titles(core: &CoreState) -> Option<Vec<String>> {
    let window = active_window(core)?;
    let view = &core.docs.tabs.get(&window)?.view;
    Some(pages_of(view).iter().map(|p| p.title().to_string()).collect())
}

pub(super) fn active_title(core: &CoreState) -> Option<String> {
    let window = active_window(core)?;
    core.docs.tabs.get(&window)?.view.selected_page().map(|p| p.title().to_string())
}

fn find(core: &CoreState, title: &str) -> Option<(u64, adw::TabView, adw::TabPage)> {
    core.docs.tabs.iter().find_map(|(w, tabs)| {
        pages_of(&tabs.view)
            .into_iter()
            .find(|p| p.title() == title)
            .map(|p| (*w, tabs.view.clone(), p))
    })
}

fn shown(core: &CoreState) -> String {
    let all: Vec<String> = core
        .docs
        .tabs
        .values()
        .flat_map(|t| pages_of(&t.view).into_iter().map(|p| p.title().to_string()))
        .collect();
    format!("tabs: {}", all.join(", "))
}

pub(super) fn dirty(core: &CoreState, title: &str) -> Result<bool, String> {
    let Some((_, _, page)) = find(core, title) else {
        return Err(format!("no tab titled {title:?} ({})", shown(core)));
    };
    Ok(page.indicator_icon().is_some())
}

pub(super) fn select(core: &CoreState, title: &str) -> Result<(), String> {
    let Some((window, view, page)) = find(core, title) else {
        return Err(format!("no tab titled {title:?} ({})", shown(core)));
    };
    if let Some(native) = gtk_window_read(core, window) {
        native.present();
    }
    bring_front(window);
    view.set_selected_page(&page);
    Ok(())
}

pub(super) fn close(core: &CoreState, title: &str) -> Result<(), String> {
    let Some((_, view, page)) = find(core, title) else {
        return Err(format!("no tab titled {title:?} ({})", shown(core)));
    };
    view.close_page(&page);
    Ok(())
}

pub(super) fn press_plus(core: &CoreState) -> Result<(), String> {
    let Some(window) = active_window(core) else { return Err("no window holds documents".into()) };
    let plus = &core.docs.tabs[&window].plus;
    if !plus.is_visible() {
        return Err("no + is drawn (is new_document armed?)".into());
    }
    plus.emit_clicked();
    Ok(())
}

pub(super) fn move_out(core: &CoreState, title: &str) -> Result<(), String> {
    let Some((_, view, page)) = find(core, title) else {
        return Err(format!("no tab titled {title:?} ({})", shown(core)));
    };
    move_to_new_window(&view, &page);
    Ok(())
}

pub(super) fn close_native(core: &CoreState) -> Result<(), String> {
    let Some(window) = active_window(core) else { return Err("no window holds documents".into()) };
    let Some(native) = gtk_window_read(core, window) else {
        return Err(format!("window#{window} has no native window"));
    };
    native.close();
    Ok(())
}
