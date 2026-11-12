// The rich document on WinUI (docs/rich-document-plan.md §11): paragraph
// formats, the drawn list markers, the keys offered to the core, the
// clipboard's RTF and HTML, and the text colour picker. THE MARKERS ARE DRAWN,
// NOT TOM LISTS: TOM cannot spell kaya's per-level bullets (measured,
// docs/measurements/richdoc-winui-2026-11-11.md §2).

use super::*;
use bindings::Microsoft::UI::Xaml::Controls::{
    Canvas, TextControlCopyingToClipboardEventArgs,
    TextControlCuttingToClipboardEventArgs,
};
use bindings::Microsoft::UI::Text::ParagraphAlignment;

/// One list level's step, in TOM points: a list item's text sits one step in
/// from its level, a plain paragraph's at its level (the Mac arm's 24 pt).
pub(super) const LIST_INDENT_STEP: f32 = 24.0;
/// The gap between a marker's trailing edge and the item's text.
pub(super) const MARKER_GAP: f64 = 6.0;
/// A checklist item's box: the CheckBox template's own glyph square.
const CHECK_SIZE: f64 = 20.0;

pub(super) struct Overlay {
    canvas: Canvas,
    content: FrameworkElement,
}

/// One marker as the overlay placed it: the record `expect_markers` reads.
#[derive(Clone)]
#[cfg_attr(not(feature = "harness"), allow(dead_code))]
pub(super) struct Drawn {
    pub start: u64,
    pub level: u32,
    pub text: String,
    pub check: Option<CheckBox>,
    pub element: UIElement,
}

thread_local! {
    static OVERLAYS: RefCell<HashMap<u64, Overlay>> = RefCell::new(HashMap::new());
    /// The core's markers as last read, so a scroll or a resize places them
    /// again without the core.
    static WANTED: RefCell<HashMap<u64, Vec<(crate::richdoc::Marker, Option<crate::richdoc::ItemPlace>)>>> = RefCell::new(HashMap::new());
    static DRAWN: RefCell<HashMap<u64, Vec<Drawn>>> = RefCell::new(HashMap::new());
    /// Set while the overlay writes a box's state, so its Checked and
    /// Unchecked are not taken as a user's click.
    static PLACING: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    /// Widgets whose markers wait for a dispatcher turn (`markers_dirty`).
    static DIRTY: RefCell<BTreeSet<u64>> = RefCell::new(BTreeSet::new());
    /// The text colour picker per widget, and the colour it showed when it
    /// opened (a close that moved nothing is no act).
    static TEXT_COLOR: RefCell<HashMap<u64, (Flyout, ColorPicker, bindings::Windows::UI::Color)>> =
        RefCell::new(HashMap::new());
}

// ---- paragraph formats ------------------------------------------------

/// A paragraph's left indent, in points: a list item one step in from its
/// level, a plain paragraph at its level, a quote's indent on top.
pub(super) fn paragraph_left(attrs: &BTreeMap<String, String>) -> f32 {
    let level = attrs.get("indent").and_then(|v| v.parse::<u32>().ok()).unwrap_or(0) as f32;
    let list = if attrs.contains_key("list") { 1.0 } else { 0.0 };
    let quote = if attrs.get("block").map(String::as_str) == Some("quote") { RICH_QUOTE_INDENT } else { 0.0 };
    (level + list) * LIST_INDENT_STEP + quote
}

fn paragraph_alignment(attrs: &BTreeMap<String, String>) -> ParagraphAlignment {
    match attrs.get("align").map(String::as_str) {
        Some("center") => ParagraphAlignment::Center,
        Some("end") => ParagraphAlignment::Right,
        Some("justify") => ParagraphAlignment::Justify,
        _ => ParagraphAlignment::Left,
    }
}

/// THE PARAGRAPH LAYER, from each paragraph's own attributes
/// (`richdoc::para_attrs`: its first byte, an empty one's terminator, the empty
/// final one's state) and never from a segment's: a terminator's runs are not
/// its paragraph's. Every paragraph touching `from..=to`.
pub(super) fn paragraph_formats(
    field: &RichEditBox, text: &str, runs: &[TextRun], from: usize, to: usize,
) -> windows_core::Result<()> {
    let doc = field.TextDocument()?;
    let state = crate::richdoc::final_state(text, runs);
    for para in crate::richdoc::paragraphs(text) {
        if para.end < from || para.start > to {
            continue;
        }
        let attrs = crate::richdoc::para_attrs(runs, &para, &state);
        let Some(at) = utf16_offset(text, para.start) else { continue };
        let range = doc.GetRange(at, at)?;
        let format = range.ParagraphFormat()?;
        format.SetIndents(0.0, paragraph_left(&attrs), 0.0)?;
        format.SetAlignment(paragraph_alignment(&attrs))?;
        range.SetParagraphFormat(&format)?;
    }
    Ok(())
}

/// A run's `color`, as this page draws it: the stored colour on a light
/// page, `brand::ink_for_dark` of it on a dark one (RD5).
pub(super) fn drawn_color(attrs: &BTreeMap<String, String>, dark: bool) -> Option<bindings::Windows::UI::Color> {
    let rgb = crate::richdoc::parse_color(attrs.get("color")?).ok()?;
    let rgb = if dark { crate::brand::ink_for_dark(rgb) } else { rgb };
    Some(bindings::Windows::UI::Color { A: 255, R: (rgb >> 16) as u8, G: (rgb >> 8) as u8, B: rgb as u8 })
}

// ---- the drawn markers ------------------------------------------------

/// The overlay over the control's template, made once the template exists.
fn overlay(field: &RichEditBox, widget: u64) -> windows_core::Result<Option<(Canvas, FrameworkElement)>> {
    if let Some(found) = OVERLAYS.with_borrow(|map| map.get(&widget).map(|o| (o.canvas.clone(), o.content.clone()))) {
        return Ok(Some(found));
    }
    use bindings::Microsoft::UI::Xaml::Media::VisualTreeHelper;
    let element: UIElement = field.cast()?;
    if VisualTreeHelper::GetChildrenCount(&element)? == 0 {
        return Ok(None);
    }
    let Ok(root) = VisualTreeHelper::GetChild(&element, 0)?.cast::<Grid>() else {
        return Ok(None);
    };
    let Some(content) = named_descendant(&element, "ContentElement")? else {
        return Ok(None);
    };
    let canvas = Canvas::new()?;
    let placed: FrameworkElement = canvas.cast()?;
    let cell: FrameworkElement = content.clone();
    Grid::SetRow(&placed, Grid::GetRow(&cell)?)?;
    Grid::SetRowSpan(&placed, Grid::GetRowSpan(&cell)?.max(1))?;
    Grid::SetColumn(&placed, Grid::GetColumn(&cell)?)?;
    Grid::SetColumnSpan(&placed, Grid::GetColumnSpan(&cell)?.max(1))?;
    root.Children()?.Append(&placed.cast::<UIElement>()?)?;
    if let Ok(viewer) = content.cast::<ScrollViewer>() {
        viewer.ViewChanged(&EventHandler::<bindings::Microsoft::UI::Xaml::Controls::ScrollViewerViewChangedEventArgs>::new(
            move |_, _| {
                place_later(widget);
                Ok(())
            },
        ))?;
    }
    canvas.SizeChanged(&bindings::Microsoft::UI::Xaml::SizeChangedEventHandler::new(move |_, _| {
        place_later(widget);
        Ok(())
    }))?;
    // THE TEXT MOVES WITHOUT THE CANVAS: a Padding write (the Writing Mode
    // measure, code_surface.rs apply_measure) re-lays the text presenter
    // inside an unchanged box, so its own size change places the markers
    // again (the review capture, 2026-11-11: every marker 80 px left of its
    // text).
    if let Some(text_view) = presenter(&content).and_then(|p| p.cast::<FrameworkElement>().ok()) {
        text_view.SizeChanged(&bindings::Microsoft::UI::Xaml::SizeChangedEventHandler::new(move |_, _| {
            place_later(widget);
            Ok(())
        }))?;
    }
    OVERLAYS.with_borrow_mut(|map| {
        map.insert(widget, Overlay { canvas: canvas.clone(), content: content.clone() });
    });
    Ok(Some((canvas, content)))
}

/// The text presenter inside the template's ScrollViewer: TOM's client
/// coordinates are its own (the 2026-08-06 trap: they do not move with the
/// viewport, and this element does).
fn presenter(content: &FrameworkElement) -> Option<UIElement> {
    let viewer = content.cast::<ScrollViewer>().ok()?;
    viewer.Content().ok()?.cast::<UIElement>().ok()
}

/// A TOM client rectangle in `to`'s coordinates.
fn client_rect_in(
    field: &RichEditBox, content: &FrameworkElement, to: &UIElement, at: i32, len: i32,
) -> windows_core::Result<Option<(f64, f64, f64, f64)>> {
    let mut rect = bindings::Windows::Foundation::Rect::default();
    let mut hit = 0i32;
    field.TextDocument()?.GetRange(at, at + len)?.GetRect(
        PointOptions::ClientCoordinates | PointOptions::AllowOffClient,
        &mut rect,
        &mut hit,
    )?;
    let Some(from) = presenter(content) else { return Ok(None) };
    let origin = from.TransformToVisual(to)?.TransformPoint(Point { X: rect.X, Y: rect.Y })?;
    Ok(Some((f64::from(origin.X), f64::from(origin.Y), f64::from(rect.Width), f64::from(rect.Height))))
}

/// One character range's TOM rectangle in the control's own coordinates
/// (`expect_text_ink`'s read), or None before the template has run.
#[cfg(feature = "harness")]
pub(super) fn char_rect(
    field: &RichEditBox, widget: u64, at: i32, len: i32,
) -> windows_core::Result<Option<(f64, f64, f64, f64)>> {
    let Some((_, content)) = overlay(field, widget)? else { return Ok(None) };
    let to: UIElement = field.cast()?;
    client_rect_in(field, &content, &to, at, len)
}

/// Marks a widget's markers for a redraw on a later dispatcher turn: the
/// core's mirror can be ahead of the control inside a transaction, and the
/// draw reads both.
pub(super) fn markers_dirty(widget: u64) {
    let first = DIRTY.with_borrow_mut(|set| {
        let first = set.is_empty();
        set.insert(widget);
        first
    });
    if !first {
        return;
    }
    let Some(dispatcher) = DISPATCHER.get() else { return };
    let handler = DispatcherQueueHandler::new(|| {
        let widgets: Vec<u64> = DIRTY.with_borrow_mut(std::mem::take).into_iter().collect();
        CORE.with(|slot| {
            let Ok(borrowed) = slot.try_borrow() else {
                for w in &widgets {
                    markers_dirty(*w);
                }
                return;
            };
            let Some(core) = borrowed.as_ref() else { return };
            for widget in widgets {
                if let Err(e) = draw_markers(core, widget) {
                    eprintln!("kaya: winui could not draw a rich document's markers: {}", e.message());
                }
            }
        });
        Ok(())
    });
    let _ = dispatcher.0.TryEnqueue(&handler);
}

/// The core's markers read and drawn, when the control holds the text the
/// core numbered.
pub(super) fn draw_markers(core: &CoreState, widget: u64) -> windows_core::Result<()> {
    let Some(field) = textarea_by_id(core, widget) else { return Ok(()) };
    if !rich_is_on(widget) {
        WANTED.with_borrow_mut(|m| m.remove(&widget));
        return place(&field, widget);
    }
    let text = lf(Editable::Textarea(field.clone()).text()?);
    if core.scene.rich_text(WidgetId(widget)) != Some(text.as_str()) {
        return Ok(());
    }
    let places = core.scene.rich_item_places(WidgetId(widget)).unwrap_or_default();
    let markers = core
        .scene
        .rich_markers(WidgetId(widget))
        .unwrap_or_default()
        .into_iter()
        .map(|m| {
            let place = places.iter().find(|p| p.start == m.start).cloned();
            (m, place)
        })
        .collect();
    WANTED.with_borrow_mut(|m| m.insert(widget, markers));
    place(&field, widget)
}

fn place_later(widget: u64) {
    let Some(dispatcher) = DISPATCHER.get() else { return };
    let handler = DispatcherQueueHandler::new(move || {
        let field = CORE.with(|slot| {
            let borrowed = slot.try_borrow().ok()?;
            textarea_by_id(borrowed.as_ref()?, widget)
        });
        if let Some(field) = field {
            if let Err(e) = place(&field, widget) {
                eprintln!("kaya: winui could not place a rich document's markers: {}", e.message());
            }
        }
        Ok(())
    });
    let _ = dispatcher.0.TryEnqueue(&handler);
}

/// THE DRAW: one TextBlock per bullet or number, right-aligned `MARKER_GAP`
/// before the item's first character, and a CheckBox per checklist item; the
/// record is written from the same loop.
fn place(field: &RichEditBox, widget: u64) -> windows_core::Result<()> {
    let Some((canvas, content)) = overlay(field, widget)? else {
        return Ok(());
    };
    let markers = WANTED.with_borrow(|m| m.get(&widget).cloned().unwrap_or_default());
    let text = lf(Editable::Textarea(field.clone()).text()?);
    let (size, face) = rich_base_face(field)?;
    let children = canvas.Children()?;
    children.Clear()?;
    let to: UIElement = canvas.cast()?;
    let mut drawn = Vec::with_capacity(markers.len());
    PLACING.with(|p| p.set(true));
    let placed = (|| -> windows_core::Result<()> {
        for (marker, place) in &markers {
            let Some(at) = utf16_offset(&text, marker.start as usize) else { continue };
            let len = i32::from(marker.start < text.len() as u64);
            let Some((x, y, _, h)) = client_rect_in(field, &content, &to, at, len)? else { continue };
            let h = if h > 0.0 { h } else { f64::from(size) * 1.33 };
            let right = x - MARKER_GAP;
            if marker.text == "[ ]" || marker.text == "[x]" {
                let check = CheckBox::new()?;
                check.SetMinWidth(0.0)?;
                check.SetMinHeight(0.0)?;
                check.SetWidth(CHECK_SIZE)?;
                check.SetHeight(CHECK_SIZE)?;
                check.SetPadding(Thickness { Left: 0.0, Top: 0.0, Right: 0.0, Bottom: 0.0 })?;
                check.SetIsTabStop(false)?;
                check.SetAllowFocusOnInteraction(false)?;
                let checked = marker.text == "[x]";
                check.SetIsChecked(&PropertyValue::CreateBoolean(checked)?.cast::<IReference<bool>>()?)?;
                let start = marker.start;
                let toggled = field.clone();
                let handler = RoutedEventHandler::new(move |_, _| {
                    if !PLACING.with(|p| p.get()) {
                        box_clicked(&toggled, widget, start);
                    }
                    Ok(())
                });
                check.Checked(&handler)?;
                check.Unchecked(&handler)?;
                let (left, top) = (right - CHECK_SIZE, y + (h - CHECK_SIZE) / 2.0);
                let element: UIElement = check.cast()?;
                name_item(&element, place.as_ref())?;
                Canvas::SetLeft(&element, left)?;
                Canvas::SetTop(&element, top)?;
                children.Append(&element)?;
                // THE RECORD IS READ BACK OFF THE ELEMENT, so a box drawn in the
                // wrong state reads as that state.
                let shown = check.IsChecked().ok().and_then(|v| v.Value().ok()).unwrap_or(false);
                drawn.push(Drawn {
                    start: marker.start,
                    level: marker.level,
                    text: if shown { "[x]" } else { "[ ]" }.to_owned(),
                    check: Some(check),
                    element: element.clone(),
                });
                continue;
            }
            let block = TextBlock::new()?;
            block.SetText(&HSTRING::from(marker.text.as_str()))?;
            block.SetFontSize(f64::from(size) * 96.0 / 72.0)?;
            block.SetFontFamily(&FontFamily::CreateInstanceWithName(&HSTRING::from(face.as_str()))?)?;
            let element: UIElement = block.cast()?;
            name_item(&element, place.as_ref())?;
            element.Measure(bindings::Windows::Foundation::Size { Width: f32::INFINITY, Height: f32::INFINITY })?;
            let width = f64::from(element.DesiredSize()?.Width);
            let (left, top) = (right - width, y);
            Canvas::SetLeft(&element, left)?;
            Canvas::SetTop(&element, top)?;
            children.Append(&element)?;
            drawn.push(Drawn {
                start: marker.start,
                level: marker.level,
                text: block.Text()?.to_string(),
                check: None,
                element: element.clone(),
            });
        }
        // Clipped to the viewport the text scrolls in, so a marker scrolled
        // out of it is not drawn over the control's border.
        let clip = RectangleGeometry::new()?;
        clip.SetRect(bindings::Windows::Foundation::Rect {
            X: 0.0,
            Y: 0.0,
            Width: canvas.ActualWidth()? as f32,
            Height: canvas.ActualHeight()? as f32,
        })?;
        canvas.SetClip(&clip)?;
        Ok(())
    })();
    PLACING.with(|p| p.set(false));
    DRAWN.with_borrow_mut(|map| map.insert(widget, drawn));
    placed
}

/// RD19 (docs/rich-document-plan.md §11): Narrator meets a drawn marker as
/// its item's account and place in the list, never as the bare glyph.
fn name_item(element: &UIElement, place: Option<&crate::richdoc::ItemPlace>) -> windows_core::Result<()> {
    use bindings::Microsoft::UI::Xaml::Automation::AutomationProperties as A;
    let Some(place) = place else { return Ok(()) };
    let at: bindings::Microsoft::UI::Xaml::DependencyObject = element.cast()?;
    A::SetName(&at, &HSTRING::from(place.said.as_str()))?;
    A::SetPositionInSet(&at, place.position as i32)?;
    A::SetSizeOfSet(&at, place.size as i32)?;
    A::SetLevel(&at, place.level as i32)
}

/// The record `expect_markers` reads, spelled as the core spells its own.
#[cfg(feature = "harness")]
pub(super) fn drawn_spelling(widget: u64) -> String {
    DRAWN.with_borrow(|map| {
        map.get(&widget)
            .map(|drawn| {
                drawn
                    .iter()
                    .map(|d| format!("{}:{} {}", d.start, d.level, d.text))
                    .collect::<Vec<_>>()
                    .join("|")
            })
            .unwrap_or_default()
    })
}

/// The drawn markers' elements, for `expect_markers`' placement read.
#[cfg(feature = "harness")]
pub(super) fn drawn_elements(widget: u64) -> Vec<(u64, String, UIElement)> {
    DRAWN.with_borrow(|map| {
        map.get(&widget)
            .map(|d| d.iter().map(|d| (d.start, d.text.clone(), d.element.clone())).collect())
            .unwrap_or_default()
    })
}

/// The drawn box of the item starting at `start`, for `click_marker`.
#[cfg(feature = "harness")]
pub(super) fn drawn_box(widget: u64, start: u64) -> Option<CheckBox> {
    DRAWN.with_borrow(|map| map.get(&widget)?.iter().find(|d| d.start == start)?.check.clone())
}

#[cfg(feature = "harness")]
pub(super) fn drawn_starts(widget: u64) -> Vec<u64> {
    DRAWN.with_borrow(|map| map.get(&widget).map(|d| d.iter().map(|d| d.start).collect()).unwrap_or_default())
}

/// A checklist box's click, offered to the core as the toggle key at the
/// item's first byte; the box shows the core's state again either way.
fn box_clicked(field: &RichEditBox, widget: u64, start: u64) {
    if !offer_key(field, widget, crate::capi::KAYA_TEXT_KEY_CHECK, Some(start)) {
        place_later(widget);
    }
}

pub(super) fn forget(widget: u64) {
    OVERLAYS.with_borrow_mut(|m| m.remove(&widget));
    WANTED.with_borrow_mut(|m| m.remove(&widget));
    DRAWN.with_borrow_mut(|m| m.remove(&widget));
    TEXT_COLOR.with_borrow_mut(|m| m.remove(&widget));
}

// ---- keys ---------------------------------------------------------------

/// The selection in bytes, and the text it is in.
fn selection_bytes(field: &RichEditBox) -> windows_core::Result<Option<(String, u64, u64)>> {
    let text = lf(Editable::Textarea(field.clone()).text()?);
    let selection = field.TextDocument()?.Selection()?;
    let (a, b) = (selection.StartPosition()?, selection.EndPosition()?);
    Ok(match (byte_offset(&text, a), byte_offset(&text, b)) {
        (Some(a), Some(b)) => Some((text, a as u64, b as u64)),
        _ => None,
    })
}

/// A key (or a box's click) offered to the core before the control acts on
/// it (docs/rich-document-plan.md §11, Keys); true when the core took it, its
/// act already applied and its occurrences sent. A mirror behind the control
/// (an edit whose TextChanged is still in flight) is never asked: the key is
/// the platform's.
pub(super) fn offer_key(field: &RichEditBox, widget: u64, key: u32, at: Option<u64>) -> bool {
    let Ok(Some((text, mut start, mut end))) = selection_bytes(field) else { return false };
    if let Some(at) = at {
        (start, end) = (at, at);
    }
    CORE.with(|slot| {
        let Ok(mut borrowed) = slot.try_borrow_mut() else {
            eprintln!("KAYA_DIAG rich key {key} on widget {widget} arrived inside a CORE borrow, so the control acts on it");
            return false;
        };
        let Some(core) = borrowed.as_mut() else { return false };
        let id = WidgetId(widget);
        if core.scene.rich_text(id) != Some(text.as_str()) {
            return false;
        }
        if !core.scene.rich_key(id, key, start, end) {
            return false;
        }
        let ops = core.scene.take_rich_ops();
        deliver_rich_ops(core, ops);
        send_scene_asks(core);
        markers_dirty(widget);
        true
    })
}

/// Return, Backspace, Tab and Shift+Tab offered to the core in the
/// tunnelling PreviewKeyDown, which sees each of them before the control
/// (measured, docs/measurements/richdoc-winui-2026-11-11.md §3).
pub(super) fn watch_keys(field: &RichEditBox, widget: u64) -> windows_core::Result<()> {
    let keyed = field.clone();
    let element: UIElement = field.cast()?;
    element.PreviewKeyDown(&KeyEventHandler::new(move |_, args| {
        let Some(args) = args.as_ref() else { return Ok(()) };
        if args.Handled()? || !rich_is_on(widget) || composing_now(widget) {
            return Ok(());
        }
        const VK_SHIFT: i32 = 0x10;
        const VK_CONTROL: i32 = 0x11;
        let shift = modifier_down(VK_SHIFT);
        if modifier_down(VK_CONTROL) {
            return Ok(());
        }
        let key = match args.Key()? {
            VirtualKey::Enter if !shift && !SUBMITS.with_borrow(|s| s.contains(&widget)) => {
                crate::capi::KAYA_TEXT_KEY_RETURN
            }
            VirtualKey::Back if !shift => crate::capi::KAYA_TEXT_KEY_BACKSPACE,
            VirtualKey::Tab if shift => crate::capi::KAYA_TEXT_KEY_SHIFT_TAB,
            VirtualKey::Tab => crate::capi::KAYA_TEXT_KEY_TAB,
            _ => return Ok(()),
        };
        if offer_key(&keyed, widget, key, None) {
            #[cfg(feature = "harness")]
            KEYS_TAKEN.with(|n| n.set(n.get() + 1));
            args.SetHandled(true)?;
        }
        Ok(())
    }))?;
    Ok(())
}

#[cfg(feature = "harness")]
thread_local! {
    /// Keys the core took, so `type`'s wait for a Return's newline knows the
    /// key was swallowed.
    pub(super) static KEYS_TAKEN: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

// ---- the clipboard ---------------------------------------------------

const RTF_FORMAT: &str = "Rich Text Format";
const HTML_FORMAT: &str = "HTML Format";

/// A rich textarea's copy: the plain text, RTF and CF_HTML, written from the
/// core's mirror (`Scene::rich_copy`). Answers whether it wrote; a collapsed
/// selection writes nothing, as the platform's own copy.
pub(super) fn copy(core: &CoreState, field: &RichEditBox, widget: u64) -> windows_core::Result<bool> {
    let Some((text, start, end)) = selection_bytes(field)? else { return Ok(false) };
    if start == end {
        return Ok(false);
    }
    let id = WidgetId(widget);
    let rtf = core.scene.rich_copy(id, start, end, false);
    let html = core.scene.rich_copy(id, start, end, true);
    let plain = text[start as usize..end as usize].replace('\n', "\r\n");
    clip_open_retry()?;
    unsafe { windows::Win32::System::DataExchange::EmptyClipboard()? };
    let wrote: windows_core::Result<()> = (|| {
        if let Some(rtf) = &rtf {
            let mut bytes = rtf.as_bytes().to_vec();
            bytes.push(0);
            clip_set_bytes(clip_register(RTF_FORMAT), &bytes)?;
        }
        if let Some(html) = &html {
            clip_set_bytes(clip_register(HTML_FORMAT), &build_cf_html(html))?;
        }
        clip_set_bytes(CF_UNICODETEXT, &clip_utf16z(&plain))
    })();
    unsafe { windows::Win32::System::DataExchange::CloseClipboard()? };
    wrote?;
    Ok(true)
}

/// Copy, then the selection taken out through the control, which reports
/// the deletion as an edit.
pub(super) fn cut(core: &CoreState, field: &RichEditBox, widget: u64) -> windows_core::Result<()> {
    if copy(core, field, widget)? {
        selection_range(&field.TextDocument()?)?.SetText(&HSTRING::new())?;
    }
    Ok(())
}

/// Whether the clipboard offers a flavour a rich paste reads.
pub(super) fn paste_available() -> bool {
    clip_available(CF_UNICODETEXT)
        || clip_available(clip_register(RTF_FORMAT))
        || clip_available(clip_register(HTML_FORMAT))
}

/// The clipboard's RTF and HTML, read in one open.
fn rich_flavours() -> (Option<Vec<u8>>, Option<String>) {
    let (rtf_format, html_format) = (clip_register(RTF_FORMAT), clip_register(HTML_FORMAT));
    if clip_open_retry().is_err() {
        return (None, None);
    }
    let rtf = clip_available(rtf_format).then(|| clip_get_bytes(rtf_format)).flatten().map(|mut b| {
        if let Some(nul) = b.iter().position(|&c| c == 0) {
            b.truncate(nul);
        }
        b
    });
    let html = clip_available(html_format).then(|| clip_get_bytes(html_format)).flatten().and_then(|b| parse_cf_html(&b));
    unsafe {
        let _ = windows::Win32::System::DataExchange::CloseClipboard();
    }
    (rtf, html)
}

/// A rich textarea's paste: RTF, then HTML, through the core's normaliser,
/// which arms the runs for the edit this insertion reports; the plain paste
/// when neither reads as text. Named a paste before the insertion.
pub(super) fn paste(core: &mut CoreState, field: &RichEditBox, widget: u64) -> windows_core::Result<()> {
    let (rtf, html) = rich_flavours();
    #[cfg(feature = "harness")]
    crate::vtrace::note("rich.paste", format_args!(
        "widget={widget} rtf_bytes={:?} html={:?}",
        rtf.as_ref().map(Vec::len),
        html.as_deref(),
    ));
    let id = WidgetId(widget);
    core.scene.set_text_edit_source(id, crate::wire::EDIT_SOURCE_PASTE as u32);
    match core.scene.rich_paste(id, rtf.as_deref(), html.as_deref()) {
        Some(plain) => selection_range(&field.TextDocument()?)?.SetText(&HSTRING::from(plain)),
        None => Editable::Textarea(field.clone()).paste_from_clipboard(),
    }
}

/// The control's own copy and cut doors (Ctrl+C, Ctrl+X, the context
/// menu), taken for a rich textarea; a plain one keeps the platform's.
pub(super) fn watch_clipboard(field: &RichEditBox, widget: u64) -> windows_core::Result<()> {
    let copying = field.clone();
    field.CopyingToClipboard(&TypedEventHandler::<RichEditBox, TextControlCopyingToClipboardEventArgs>::new(
        move |_, args| {
            if !rich_is_on(widget) {
                return Ok(());
            }
            let Some(args) = args.as_ref() else { return Ok(()) };
            args.SetHandled(true)?;
            let field = copying.clone();
            rich_scene("copying rich text", move |core| {
                if let Err(e) = copy(core, &field, widget) {
                    eprintln!("kaya: winui rich copy failed: {}", e.message());
                }
            });
            Ok(())
        },
    ))?;
    let cutting = field.clone();
    field.CuttingToClipboard(&TypedEventHandler::<RichEditBox, TextControlCuttingToClipboardEventArgs>::new(
        move |_, args| {
            if !rich_is_on(widget) {
                return Ok(());
            }
            let Some(args) = args.as_ref() else { return Ok(()) };
            args.SetHandled(true)?;
            let field = cutting.clone();
            rich_scene("cutting rich text", move |core| {
                if let Err(e) = cut(core, &field, widget) {
                    eprintln!("kaya: winui rich cut failed: {}", e.message());
                }
            });
            Ok(())
        },
    ))?;
    Ok(())
}

/// THE FOCUSED STATE DRAWS EVERY COLOURED RUN AT ITS BRUSH'S ALPHA: the
/// template's Focused state sets the text to TextControlForegroundFocused,
/// #E4000000 under Light, and a `color` run then reads back off the window at
/// 89% of its value (measured on the lane 2026-11-11: #016FEF drew #1C7EF1,
/// the same in the bare-control probe, docs/measurements/richdoc-winui-2026-11-11.md
/// §6). So a rich textarea's own resources hold the text brushes OPAQUE, the
/// Light ink the colour #E4000000 already composites to over the page. Set
/// before the template is applied, the only time lightweight styling takes;
/// a Foreground write afterwards rewrites every run's colour (#6908's class).
const OPAQUE_TEXT_BRUSHES: &str = "<ResourceDictionary \
    xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" \
    xmlns:x=\"http://schemas.microsoft.com/winfx/2006/xaml\">\
  <ResourceDictionary.ThemeDictionaries>\
    <ResourceDictionary x:Key=\"Light\">\
      <SolidColorBrush x:Key=\"TextControlForeground\" Color=\"#FF1B1B1B\"/>\
      <SolidColorBrush x:Key=\"TextControlForegroundPointerOver\" Color=\"#FF1B1B1B\"/>\
      <SolidColorBrush x:Key=\"TextControlForegroundFocused\" Color=\"#FF1B1B1B\"/>\
    </ResourceDictionary>\
    <ResourceDictionary x:Key=\"Dark\">\
      <SolidColorBrush x:Key=\"TextControlForeground\" Color=\"#FFFFFFFF\"/>\
      <SolidColorBrush x:Key=\"TextControlForegroundPointerOver\" Color=\"#FFFFFFFF\"/>\
      <SolidColorBrush x:Key=\"TextControlForegroundFocused\" Color=\"#FFFFFFFF\"/>\
    </ResourceDictionary>\
  </ResourceDictionary.ThemeDictionaries>\
</ResourceDictionary>";

pub(super) fn opaque_ink(field: &RichEditBox) -> windows_core::Result<()> {
    let loaded = bindings::Microsoft::UI::Xaml::Markup::XamlReader::Load(&HSTRING::from(OPAQUE_TEXT_BRUSHES))?;
    field.SetResources(&loaded.cast::<bindings::Microsoft::UI::Xaml::ResourceDictionary>()?)
}

// ---- the theme --------------------------------------------------------

/// microsoft-ui-xaml #6908, measured: a theme switch rewrites every run's
/// foreground (docs/measurements/richdoc-winui-2026-11-11.md §5), so the
/// whole display is derived again a turn later, the dark map with it.
pub(super) fn watch_theme(field: &RichEditBox, widget: u64) -> windows_core::Result<()> {
    let themed = field.clone();
    let element: FrameworkElement = field.cast()?;
    element.ActualThemeChanged(&TypedEventHandler::<FrameworkElement, windows_core::IInspectable>::new(
        move |_, _| {
            redraw_later(&themed, widget);
            Ok(())
        },
    ))?;
    Ok(())
}

/// The whole display derived again a dispatcher turn later: after a theme
/// change, and after the template's first load, whose text brush rewrites
/// every run's colour as a theme change does (measured: the seeded #016FEF
/// run read #1B1B1B on the lane until this ran).
pub(super) fn redraw_later(field: &RichEditBox, widget: u64) {
    let field = field.clone();
    let Some(dispatcher) = DISPATCHER.get() else { return };
    let handler = DispatcherQueueHandler::new(move || {
        if !rich_is_on(widget) {
            return Ok(());
        }
        let text = lf(Editable::Textarea(field.clone()).text()?);
        let runs = rich_table(widget);
        if let Err(e) = rich_restyle(&field, widget, &text, &runs, 0, text.len()) {
            eprintln!("kaya: winui could not draw a rich document again: {}", e.message());
        }
        place_later(widget);
        Ok(())
    });
    let _ = dispatcher.0.TryEnqueue(&handler);
}

// ---- the text colour picker ------------------------------------------

pub(super) fn dark_now(field: &RichEditBox) -> bool {
    matches!(field.ActualTheme(), Ok(ElementTheme::Dark))
}

/// The `text_color` command: WinUI's ColorPicker in a flyout over the
/// textarea, showing the selection's colour as this page draws it (or the
/// automatic ink). The commit is the flyout's close, as the colour picker
/// kind's (docs/color-picker-plan.md §5).
pub(super) fn present_text_color(core: &mut CoreState, widget: u64) -> windows_core::Result<()> {
    let Some(field) = textarea_by_id(core, widget) else { return Ok(()) };
    let made = TEXT_COLOR.with_borrow(|m| m.get(&widget).map(|(f, p, _)| (f.clone(), p.clone())));
    let (flyout, picker) = match made {
        Some(made) => made,
        None => {
            let picker = ColorPicker::new()?;
            picker.SetIsHexInputVisible(true)?;
            picker.SetIsMoreButtonVisible(false)?;
            picker.SetIsAlphaEnabled(false)?;
            let flyout = Flyout::new()?;
            flyout.SetShouldConstrainToRootBounds(false)?;
            flyout.SetContent(&picker)?;
            let closing = field.clone();
            flyout.Closed(&EventHandler::<windows_core::IInspectable>::new(move |_, _| {
                let field = closing.clone();
                rich_scene("committing a text colour", move |core| commit_text_color(core, &field, widget));
                Ok(())
            }))?;
            TEXT_COLOR.with_borrow_mut(|m| {
                m.insert(widget, (flyout.clone(), picker.clone(), bindings::Windows::UI::Color::default()));
            });
            (flyout, picker)
        }
    };
    let dark = dark_now(&field);
    let shown = match selection_bytes(&field)? {
        Some((_, start, _)) => drawn_color(&rich_attrs_at(&rich_table(widget), start as usize), dark),
        None => None,
    }
    .or(rich_palette(&field).text)
    .unwrap_or(bindings::Windows::UI::Color { A: 255, R: 0, G: 0, B: 0 });
    let shown = bindings::Windows::UI::Color { A: 255, ..shown };
    picker.SetColor(shown)?;
    TEXT_COLOR.with_borrow_mut(|m| {
        if let Some(slot) = m.get_mut(&widget) {
            slot.2 = shown;
        }
    });
    flyout.ShowAt(&field.cast::<FrameworkElement>()?)
}

/// The flyout closed: a colour that moved is the widget's own `color` act
/// over its selection, stored through `ink_from_dark` when the page is dark.
fn commit_text_color(core: &mut CoreState, field: &RichEditBox, widget: u64) {
    let Some((_, picker, shown)) = TEXT_COLOR.with_borrow(|m| m.get(&widget).cloned()) else { return };
    let Ok(picked) = picker.Color() else { return };
    if (picked.R, picked.G, picked.B) == (shown.R, shown.G, shown.B) {
        return;
    }
    let rgb = (u32::from(picked.R) << 16) | (u32::from(picked.G) << 8) | u32::from(picked.B);
    let stored = if dark_now(field) { crate::brand::ink_from_dark(rgb) } else { rgb };
    if let Some(trouble) = rich_format_selection(core, widget, "color", &format!("#{stored:06X}"), false) {
        eprintln!("kaya: winui text colour refused: {trouble}");
    }
}

/// The presented picker of a widget, for `pick_text_color`.
#[cfg(feature = "harness")]
pub(super) fn text_color_surface(widget: u64) -> Option<(Flyout, ColorPicker)> {
    TEXT_COLOR.with_borrow(|m| m.get(&widget).map(|(f, p, _)| (f.clone(), p.clone())))
}

