//! The code surface's WinUI arm (docs/code-surface-plan.md G6, M1-M3, S1-S2):
//! the textarea's line-number gutter, a text kind's face and size, and the
//! installed family list.

use std::cell::RefCell;
use std::collections::HashMap;

use super::*;
use bindings::Microsoft::UI::Text::TextRangeUnit;
use bindings::Microsoft::UI::Xaml::Automation::AutomationProperties;
use bindings::Microsoft::UI::Xaml::Automation::Peers::AccessibilityView;
use bindings::Microsoft::UI::Xaml::Controls::{Canvas, Grid, ScrollViewerViewChangedEventArgs};
use bindings::Microsoft::UI::Xaml::Media::VisualTreeHelper;
use bindings::Microsoft::UI::Xaml::{SizeChangedEventHandler, VerticalAlignment};

/// M1's face on this platform: Windows 11's Cascadia Mono, Consolas before it.
pub(super) const MONOSPACE_SOURCE: &str = "Cascadia Mono, Consolas";

#[derive(Default)]
struct Face {
    monospaced: bool,
    family: String,
    scale: f64,
    /// What the control wore before the first override, put back when the
    /// node asks for nothing again.
    before_family: Option<FontFamily>,
    before_size: Option<f64>,
    /// The document's own default character size before the first override
    /// (a textarea's runs are a multiple of it, `rich_base`).
    before_doc_size: Option<f32>,
}

struct Gutter {
    field: RichEditBox,
    canvas: Canvas,
    width: f64,
    base_pad: f64,
    /// What the last pass drew: each number and its row's vertical centre, in
    /// the document's coordinates (`range_extent`'s space).
    drawn: Vec<(u32, f64)>,
}

thread_local! {
    static FACES: RefCell<HashMap<u64, Face>> = RefCell::new(HashMap::new());
    static GUTTERS: RefCell<HashMap<u64, Gutter>> = RefCell::new(HashMap::new());
}

/// The four props' apply arms; true when the prop was one of them.
pub(super) fn set_prop(core: &mut CoreState, id: WidgetId, prop: Prop, value: &Value) -> windows_core::Result<bool> {
    match (prop, value) {
        (Prop::LineNumbers, Value::Bool(on)) => {
            let Some(NativeWidget::Textarea(field)) = core.widgets.get(&id) else {
                panic!("kaya: winui: line_numbers reached a widget that is not a textarea");
            };
            line_numbers(id.0, field, *on)?;
            Ok(true)
        }
        (Prop::Monospaced, Value::Bool(on)) => {
            FACES.with_borrow_mut(|faces| faces.entry(id.0).or_insert_with(fresh).monospaced = *on);
            apply_face(core, id)?;
            Ok(true)
        }
        (Prop::Family, Value::Str(name)) => {
            FACES.with_borrow_mut(|faces| faces.entry(id.0).or_insert_with(fresh).family = name.clone());
            apply_face(core, id)?;
            Ok(true)
        }
        (Prop::TextScale, Value::F64(scale)) => {
            FACES.with_borrow_mut(|faces| faces.entry(id.0).or_insert_with(fresh).scale = *scale);
            apply_face(core, id)?;
            Ok(true)
        }
        _ => Ok(false),
    }
}

fn fresh() -> Face {
    Face { scale: 1.0, ..Face::default() }
}

/// After a label's role restyled it: the size multiple is of the new style's.
pub(super) fn after_role(core: &CoreState, id: WidgetId) -> windows_core::Result<()> {
    if FACES.with_borrow(|faces| faces.contains_key(&id.0)) {
        apply_face(core, id)?;
    }
    Ok(())
}

/// Is this family in the system font collection? (M2's presence check.)
fn installed(family: &str) -> bool {
    use windows::Win32::Graphics::DirectWrite::*;
    unsafe {
        let Ok(factory) = DWriteCreateFactory::<IDWriteFactory>(DWRITE_FACTORY_TYPE_SHARED) else {
            return false;
        };
        let mut collection: Option<IDWriteFontCollection> = None;
        if factory.GetSystemFontCollection(&mut collection, false).is_err() {
            return false;
        }
        let Some(collection) = collection else { return false };
        let wide: Vec<u16> = family.encode_utf16().chain(std::iter::once(0)).collect();
        let mut index = 0u32;
        let mut exists = windows_core::BOOL(0);
        collection.FindFamilyName(windows_core::PCWSTR(wide.as_ptr()), &mut index, &mut exists).is_ok()
            && exists.as_bool()
    }
}

/// The first family of a fallback list that is installed.
fn first_installed(source: &str) -> Option<String> {
    source.split(',').map(str::trim).find(|name| installed(name)).map(str::to_owned)
}

/// The size the platform gives this kind (and a label's role) now: a fresh
/// TextBlock wearing the label's style, the control ramp's theme size for a
/// field (`ControlContentThemeFontSize`).
fn platform_size(widget: &NativeWidget) -> windows_core::Result<f64> {
    match widget {
        NativeWidget::Label { block, .. } => {
            let probe = TextBlock::new()?;
            if let Ok(style) = block.Style() {
                probe.SetStyle(&style)?;
            }
            probe.FontSize()
        }
        _ => Ok(theme_resource::<IReference<f64>>("ControlContentThemeFontSize")
            .and_then(|size| size.Value())
            .unwrap_or(14.0)),
    }
}

/// M1, M2, S1 on one widget, from its recorded state.
fn apply_face(core: &CoreState, id: WidgetId) -> windows_core::Result<()> {
    let Some(widget) = core.widgets.get(&id) else { return Ok(()) };
    let base = platform_size(widget)?;
    FACES.with_borrow_mut(|faces| -> windows_core::Result<()> {
        let Some(face) = faces.get_mut(&id.0) else { return Ok(()) };
        let wanted: Option<String> = if !face.family.is_empty() && installed(&face.family) {
            Some(face.family.clone())
        } else if face.monospaced {
            Some(MONOSPACE_SOURCE.to_owned())
        } else {
            None
        };
        let (current_family, current_size) = match widget {
            NativeWidget::Label { block, .. } => (block.FontFamily()?, block.FontSize()?),
            NativeWidget::Entry(field) => (field.FontFamily()?, field.FontSize()?),
            NativeWidget::Textarea(field) => (field.FontFamily()?, field.FontSize()?),
            _ => panic!("kaya: winui: a face reached a kind that is not a text kind"),
        };
        if face.before_family.is_none() {
            face.before_family = Some(current_family);
            face.before_size = Some(current_size);
        }
        let family = match &wanted {
            Some(source) => FontFamily::CreateInstanceWithName(&HSTRING::from(source.as_str()))?,
            None => face.before_family.clone().expect("captured above"),
        };
        let size = if face.scale != 1.0 { base * face.scale } else { face.before_size.unwrap_or(base) };
        match widget {
            NativeWidget::Label { block, .. } => {
                block.SetFontFamily(&family)?;
                block.SetFontSize(size)?;
            }
            NativeWidget::Entry(field) => {
                field.SetFontFamily(&family)?;
                field.SetFontSize(size)?;
            }
            NativeWidget::Textarea(field) => {
                field.SetFontFamily(&family)?;
                field.SetFontSize(size)?;
                // THE DOCUMENT'S OWN FORMAT TOO: a rich textarea's runs are
                // written against it (`rich_base`), and a plain one's text
                // carries the format it was inserted under.
                let doc = field.TextDocument()?;
                let format = doc.GetDefaultCharacterFormat()?;
                if face.before_doc_size.is_none() {
                    face.before_doc_size = Some(format.Size().unwrap_or(0.0));
                }
                let name = match &wanted {
                    Some(source) => first_installed(source).unwrap_or_else(|| source.split(',').next().unwrap_or("").trim().to_owned()),
                    None => family.Source()?.to_string().split(',').next().unwrap_or("").trim().to_owned(),
                };
                if !name.is_empty() {
                    format.SetName(&HSTRING::from(name.as_str()))?;
                }
                let doc_size = face.before_doc_size.unwrap_or(0.0);
                if doc_size > 0.0 {
                    format.SetSize(doc_size * face.scale as f32)?;
                }
                doc.SetDefaultCharacterFormat(&format)?;
                let text = lf(Editable::Textarea(field.clone()).text()?);
                if rich_is_on(id.0) {
                    rich_restyle(field, id.0, &text, &rich_table(id.0), 0, text.len())?;
                } else if let Some(stop) = utf16_offset(&text, text.len()) {
                    let all = doc.GetRange(0, stop)?;
                    let character = all.CharacterFormat()?;
                    if !name.is_empty() {
                        character.SetName(&HSTRING::from(name.as_str()))?;
                    }
                    if doc_size > 0.0 {
                        character.SetSize(doc_size * face.scale as f32)?;
                    }
                    all.SetCharacterFormat(&character)?;
                }
            }
            _ => {}
        }
        Ok(())
    })?;
    if matches!(widget, NativeWidget::Textarea(_)) {
        redraw(id.0);
    }
    Ok(())
}

/// G1: the gutter on or off. The numbers sit in the RichEditBox's own
/// template, in the scroller's cell, and the box's left padding moves the
/// text past them; installed once the template is there.
fn line_numbers(id: u64, field: &RichEditBox, on: bool) -> windows_core::Result<()> {
    if !on {
        if let Some(gutter) = GUTTERS.with_borrow_mut(|g| g.remove(&id)) {
            let pad = field.Padding()?;
            field.SetPadding(Thickness { Left: gutter.base_pad, ..pad })?;
            if let Ok(parent) = VisualTreeHelper::GetParent(&gutter.canvas).and_then(|p| p.cast::<Grid>()) {
                let children = parent.Children()?;
                let mut index = 0u32;
                if children.IndexOf(&gutter.canvas, &mut index)? {
                    children.RemoveAt(index)?;
                }
            }
        }
        return Ok(());
    }
    if GUTTERS.with_borrow(|g| g.contains_key(&id)) {
        return Ok(());
    }
    if install(id, field).is_err() {
        let field_for_load = field.clone();
        field.Loaded(&RoutedEventHandler::new(move |_, _| {
            if !GUTTERS.with_borrow(|g| g.contains_key(&id)) {
                install(id, &field_for_load)?;
            }
            Ok(())
        }))?;
    }
    Ok(())
}

fn install(id: u64, field: &RichEditBox) -> windows_core::Result<()> {
    let viewer = template_scroll(field)?;
    let parent: Grid = VisualTreeHelper::GetParent(&viewer)?.cast()?;
    let canvas = Canvas::new()?;
    Grid::SetRow(&canvas, Grid::GetRow(&viewer)?)?;
    Grid::SetColumn(&canvas, Grid::GetColumn(&viewer)?)?;
    canvas.SetHorizontalAlignment(HorizontalAlignment::Left)?;
    canvas.SetVerticalAlignment(VerticalAlignment::Stretch)?;
    canvas.SetMargin(viewer.Margin()?)?;
    canvas.SetIsHitTestVisible(false)?;
    AutomationProperties::SetAccessibilityView(&canvas, AccessibilityView::Raw)?;
    parent.Children()?.Append(&canvas)?;
    let base_pad = field.Padding()?.Left;
    GUTTERS.with_borrow_mut(|g| {
        g.insert(id, Gutter { field: field.clone(), canvas, width: 0.0, base_pad, drawn: Vec::new() })
    });
    viewer.ViewChanged(&EventHandler::<ScrollViewerViewChangedEventArgs>::new(move |_, _| {
        redraw(id);
        Ok(())
    }))?;
    field.TextChanged(&RoutedEventHandler::new(move |_, _| {
        redraw(id);
        Ok(())
    }))?;
    field.SizeChanged(&SizeChangedEventHandler::new(move |_, _| {
        redraw(id);
        Ok(())
    }))?;
    redraw(id);
    Ok(())
}

fn redraw(id: u64) {
    GUTTERS.with_borrow_mut(|g| {
        if let Some(gutter) = g.get_mut(&id) {
            if let Err(e) = draw(gutter) {
                if trace_enabled() {
                    eprintln!("kaya: winui gutter {id}: {}", e.message());
                }
            }
        }
    });
}

/// The story as TOM counts positions: every paragraph ends with `\r`.
fn story_units(field: &RichEditBox) -> windows_core::Result<Vec<u16>> {
    let mut story = HSTRING::new();
    field.TextDocument()?.GetText(TextGetOptions::None, &mut story)?;
    Ok(story.to_string().encode_utf16().collect())
}

fn line_of(units: &[u16], at: i32) -> u32 {
    let at = (at.max(0) as usize).min(units.len());
    1 + units[..at].iter().filter(|u| **u == 13).count() as u32
}

/// Where the range [start, start + 1) sits, top and height, in the document's
/// coordinates (`range_extent`'s space, measured 2026-08-06).
fn row_box(doc: &bindings::Microsoft::UI::Text::RichEditTextDocument, start: i32) -> windows_core::Result<(f64, f64)> {
    let mut rect = bindings::Windows::Foundation::Rect::default();
    let mut hit = 0i32;
    doc.GetRange(start, start + 1)?.GetRect(
        PointOptions::ClientCoordinates | PointOptions::AllowOffClient,
        &mut rect,
        &mut hit,
    )?;
    Ok((rect.Y as f64, rect.Height as f64))
}

fn number_block(text: &str, size: f64) -> windows_core::Result<TextBlock> {
    let label = TextBlock::new()?;
    label.SetText(&HSTRING::from(text))?;
    label.SetFontSize(size)?;
    label.SetStyle(&themed_foreground_style("TextBlock", None, "TextFillColorSecondaryBrush")?)?;
    label.Measure(bindings::Windows::Foundation::Size { Width: f32::INFINITY, Height: f32::INFINITY })?;
    Ok(label)
}

/// G2, G3: one pass over the paragraphs in the window, each numbered on its
/// first row.
fn draw(gutter: &mut Gutter) -> windows_core::Result<()> {
    let field = gutter.field.clone();
    let viewer = template_scroll(&field)?;
    let (offset, viewport) = (viewer.VerticalOffset()?, viewer.ViewportHeight()?);
    let units = story_units(&field)?;
    let size = field.FontSize()? * 0.9;
    let lines = units.iter().filter(|u| **u == 13).count().max(1);
    let digits = lines.to_string().len().max(2);
    let digit = number_block("8", size)?.DesiredSize()?.Width as f64;
    let width = (digit * digits as f64 + 14.0).ceil();
    if (width - gutter.width).abs() > 0.5 {
        gutter.width = width;
        gutter.canvas.SetWidth(width)?;
        let pad = field.Padding()?;
        field.SetPadding(Thickness { Left: gutter.base_pad + width, ..pad })?;
    }
    let clip = RectangleGeometry::new()?;
    let pad = field.Padding()?;
    let band = viewport.max(0.0) + pad.Top + pad.Bottom;
    clip.SetRect(bindings::Windows::Foundation::Rect { X: 0.0, Y: 0.0, Width: width as f32, Height: band as f32 })?;
    gutter.canvas.SetClip(&clip)?;
    let children = gutter.canvas.Children()?;
    children.Clear()?;
    gutter.drawn.clear();
    let doc = field.TextDocument()?;
    let window = doc.GetRange(0, 0)?;
    window.Expand(TextRangeUnit::Window)?;
    let (start, end) = (window.StartPosition()?, window.EndPosition()?);
    let pad_top = pad.Top;
    let walk = doc.GetRange(start, start)?;
    walk.StartOf(TextRangeUnit::Paragraph, false)?;
    for _ in 0..4096 {
        let at = walk.StartPosition()?;
        if at > end || at as usize >= units.len() {
            break;
        }
        let (top, height) = row_box(&doc, at)?;
        if top - offset > viewport {
            break;
        }
        // The story's closing mark answers a second paragraph start on the
        // last line (measured 2026-10-27, "40 ·!40"): one number a line.
        if top + height >= offset && gutter.drawn.last().map(|d| d.0) != Some(line_of(&units, at)) {
            let number = line_of(&units, at);
            let label = number_block(&number.to_string(), size)?;
            let measured = label.DesiredSize()?;
            Canvas::SetLeft(&label, width - 6.0 - measured.Width as f64)?;
            // GetRect's client space starts inside the box's Padding, which
            // the template's ScrollViewer carries and the canvas beside it
            // does not (the numbers sat half a row high, captured 2026-10-27).
            Canvas::SetTop(&label, pad_top + top - offset + (height - measured.Height as f64) / 2.0)?;
            children.Append(&label)?;
            gutter.drawn.push((number, top + height / 2.0));
        }
        if walk.Move(TextRangeUnit::Paragraph, 1)? == 0 {
            break;
        }
    }
    Ok(())
}

/// M3: the system collection's family names, through the core's one list.
pub(super) fn list_font_families(core: &CoreState) {
    use windows::Win32::Graphics::DirectWrite::*;
    let names = (|| -> windows_core::Result<Vec<String>> {
        unsafe {
            let factory: IDWriteFactory = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED)?;
            let mut collection: Option<IDWriteFontCollection> = None;
            factory.GetSystemFontCollection(&mut collection, true)?;
            let collection = collection.expect("S_OK carries a collection");
            let mut out = Vec::new();
            for i in 0..collection.GetFontFamilyCount() {
                out.push(localized_string(&collection.GetFontFamily(i)?.GetFamilyNames()?)?);
            }
            Ok(out)
        }
    })()
    .unwrap_or_else(|e| {
        eprintln!("kaya: winui could not list the font families: {}", e.message());
        Vec::new()
    });
    core.occurrences.send(Occurrence::FontFamilies { families: crate::capi::font_family_list(&names.join("\n")) });
}

#[cfg(feature = "harness")]
pub(super) mod read {
    use super::*;

    /// G5: the rows from the display-line walk (`TextRangeUnit::Line`, not the
    /// paragraph walk the gutter draws with) and the numbers the last pass drew.
    pub(in super::super) fn gutter(core: &CoreState, id: u64) -> windows_core::Result<Option<crate::harness::GutterRead>> {
        let Some(NativeWidget::Textarea(field)) = core.widgets.get(&WidgetId(id)) else {
            return Ok(None);
        };
        if !GUTTERS.with_borrow(|g| g.contains_key(&id)) {
            return Ok(None);
        }
        redraw(id);
        let viewer = template_scroll(field)?;
        let (offset, viewport) = (viewer.VerticalOffset()?, viewer.ViewportHeight()?);
        let units = story_units(field)?;
        let doc = field.TextDocument()?;
        let window = doc.GetRange(0, 0)?;
        window.Expand(TextRangeUnit::Window)?;
        let walk = doc.GetRange(window.StartPosition()?, window.StartPosition()?)?;
        walk.StartOf(TextRangeUnit::Line, false)?;
        let inside = |mid: f64| mid >= offset && mid < offset + viewport;
        let mut fragments = Vec::new();
        for _ in 0..4096 {
            let at = walk.StartPosition()?;
            if at as usize >= units.len() {
                break;
            }
            let (top, height) = row_box(&doc, at)?;
            if top - offset > viewport {
                break;
            }
            let repeat = fragments.last().is_some_and(|f: &(f64, f64, u32, bool)| (f.0 - top).abs() < 0.5);
            if inside(top + height / 2.0) && !repeat {
                let first = at == 0 || units[at as usize - 1] == 13;
                fragments.push((top, top + height, line_of(&units, at), first));
            }
            if walk.Move(TextRangeUnit::Line, 1)? == 0 {
                break;
            }
        }
        let labels: Vec<(u32, f64)> = GUTTERS.with_borrow(|g| {
            g.get(&id).map(|gutter| gutter.drawn.clone()).unwrap_or_default()
        });
        Ok(Some(crate::harness::pair_gutter(&fragments, &labels)))
    }

    /// Whether DirectWrite calls an installed family monospaced.
    fn monospaced(family: &str) -> bool {
        use windows::Win32::Graphics::DirectWrite::*;
        unsafe {
            let Ok(factory) = DWriteCreateFactory::<IDWriteFactory>(DWRITE_FACTORY_TYPE_SHARED) else {
                return false;
            };
            let mut collection: Option<IDWriteFontCollection> = None;
            if factory.GetSystemFontCollection(&mut collection, false).is_err() {
                return false;
            }
            let Some(collection) = collection else { return false };
            let wide: Vec<u16> = family.encode_utf16().chain(std::iter::once(0)).collect();
            let mut index = 0u32;
            let mut exists = windows_core::BOOL(0);
            if collection.FindFamilyName(windows_core::PCWSTR(wide.as_ptr()), &mut index, &mut exists).is_err()
                || !exists.as_bool()
            {
                return false;
            }
            collection
                .GetFontFamily(index)
                .and_then(|f| f.GetFirstMatchingFont(DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STRETCH_NORMAL, DWRITE_FONT_STYLE_NORMAL))
                .and_then(|font| font.cast::<IDWriteFont1>())
                .map(|font| font.IsMonospacedFont().as_bool())
                .unwrap_or(false)
        }
    }

    /// M4: the family the control's source resolves to on this machine (the
    /// first installed entry of its list; DirectWrite's own fallback when
    /// none is), its fixed pitch, and the family the app asked for.
    pub(in super::super) fn face(core: &CoreState, id: u64) -> windows_core::Result<Result<crate::harness::FaceRead, String>> {
        let source = match core.widgets.get(&WidgetId(id)) {
            Some(NativeWidget::Label { block, .. }) => block.FontFamily()?.Source()?.to_string(),
            Some(NativeWidget::Entry(field)) => field.FontFamily()?.Source()?.to_string(),
            Some(NativeWidget::Textarea(field)) => {
                let name = field.TextDocument()?.GetDefaultCharacterFormat()?.Name()?.to_string();
                if name.is_empty() { field.FontFamily()?.Source()?.to_string() } else { name }
            }
            _ => return Ok(Err("is not a label, an entry or a textarea".to_owned())),
        };
        let named = source.split(',').map(|s| s.rsplit_once('#').map_or(s, |(_, f)| f).trim().to_owned());
        let family = match named.clone().find(|name| installed(name)) {
            Some(found) => found,
            None => match typeface_directwrite_fallback() {
                Ok(fallback) => fallback,
                Err(e) => return Ok(Err(format!("asks for {source:?}, which no installed family answers and DirectWrite's fallback would not name: {}", e.message()))),
            },
        };
        let asked = FACES.with_borrow(|faces| faces.get(&id).map(|f| f.family.clone()).unwrap_or_default());
        Ok(Ok(crate::harness::FaceRead { monospaced: monospaced(&family), family, asked }))
    }

    /// S3: the control's font size and the platform's for its kind and role.
    pub(in super::super) fn text_size(core: &CoreState, id: u64) -> windows_core::Result<Result<(f64, f64), String>> {
        let Some(widget) = core.widgets.get(&WidgetId(id)) else {
            return Ok(Err("no such widget".to_owned()));
        };
        let size = match widget {
            NativeWidget::Label { block, .. } => block.FontSize()?,
            NativeWidget::Entry(field) => field.FontSize()?,
            NativeWidget::Textarea(field) => field.FontSize()?,
            _ => return Ok(Err("is not a label, an entry or a textarea".to_owned())),
        };
        Ok(Ok((size, platform_size(widget)?)))
    }
}
