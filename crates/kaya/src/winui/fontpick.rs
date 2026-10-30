//! The face and the font picker on Windows (docs/font-picker-plan.md):
//! DirectWrite's installed faces, matched by the core's CSS rule, and the
//! kaya-drawn ContentDialog (§4.3: Windows has no font picker of its own).

use std::cell::RefCell;

use super::*;
use crate::protocol::{FontChoice, FontFace};
use bindings::Microsoft::UI::Xaml::Automation::AutomationProperties;
use windows::Win32::Graphics::DirectWrite::*;

fn collection() -> windows_core::Result<IDWriteFontCollection> {
    unsafe {
        let factory: IDWriteFactory = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED)?;
        let mut collection: Option<IDWriteFontCollection> = None;
        factory.GetSystemFontCollection(&mut collection, false)?;
        Ok(collection.expect("S_OK carries a collection"))
    }
}

/// An installed family by its name.
fn family(name: &str) -> Option<IDWriteFontFamily> {
    let collection = collection().ok()?;
    let wide: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();
    let mut index = 0u32;
    let mut exists = windows_core::BOOL(0);
    unsafe {
        collection.FindFamilyName(windows_core::PCWSTR(wide.as_ptr()), &mut index, &mut exists).ok()?;
        if !exists.as_bool() {
            return None;
        }
        collection.GetFontFamily(index).ok()
    }
}

/// The portable three of a DirectWrite font.
fn face_of(font: &IDWriteFont) -> FontFace {
    unsafe {
        FontFace {
            weight: font.GetWeight().0.clamp(1, 1000) as u16,
            italic: font.GetStyle() != DWRITE_FONT_STYLE_NORMAL,
            width: font.GetStretch().0.clamp(1, 9) as u8,
        }
    }
}

/// A family's installed faces and their names. DirectWrite (and WPF over it)
/// lists a SIMULATED oblique beside every real face (measured), which is not
/// installed and is dropped.
fn real_faces(family: &IDWriteFontFamily) -> Vec<(FontFace, String)> {
    let mut out = Vec::new();
    unsafe {
        for i in 0..family.GetFontCount() {
            let Ok(font) = family.GetFont(i) else { continue };
            if font.GetSimulations() != DWRITE_FONT_SIMULATIONS_NONE {
                continue;
            }
            let name = font.GetFaceNames().ok().and_then(|n| localized_string(&n).ok()).unwrap_or_default();
            out.push((face_of(&font), name));
        }
    }
    out
}

pub(super) fn real_faces_named(name: &str) -> Vec<(FontFace, String)> {
    family(name).map(|f| real_faces(&f)).unwrap_or_default()
}

/// A code font: DirectWrite's own fixed-pitch flag on the family's regular
/// face, a symbol font left out (an advance test caught Webdings, measured).
fn code(family: &IDWriteFontFamily) -> bool {
    unsafe {
        family
            .GetFirstMatchingFont(DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STRETCH_NORMAL, DWRITE_FONT_STYLE_NORMAL)
            .ok()
            .is_some_and(|font| {
                !font.IsSymbolFont().as_bool()
                    && font.cast::<IDWriteFont1>().is_ok_and(|f| f.IsMonospacedFont().as_bool())
            })
    }
}

pub(super) fn is_code_family(name: &str) -> bool {
    family(name).as_ref().is_some_and(code)
}

/// list_font_faces (docs/font-picker-plan.md §4.4).
pub(super) fn list_font_faces(core: &CoreState, name: &str) {
    let lines: Vec<String> = real_faces_named(name)
        .into_iter()
        .map(|(face, title)| format!("{}\t{}\t{}\t{title}", face.weight, u8::from(face.italic), face.width))
        .collect();
    core.occurrences.send(Occurrence::FontFaces {
        family: name.to_owned(),
        faces: crate::capi::font_face_list(&lines.join("\n")),
    });
}

/// The families the picker offers, in the core's one order.
fn families(code_only: bool) -> Vec<String> {
    let mut names = Vec::new();
    if let Ok(collection) = collection() {
        unsafe {
            for i in 0..collection.GetFontFamilyCount() {
                let Ok(family) = collection.GetFontFamily(i) else { continue };
                if code_only && !code(&family) {
                    continue;
                }
                if let Ok(name) = family.GetFamilyNames().and_then(|n| localized_string(&n)) {
                    names.push(name);
                }
            }
        }
    }
    crate::capi::font_family_list(&names.join("\n"))
}

/// The family list's height: what the dialog has left after the search,
/// the faces and the preview, between a row and a half and 260 px, so a
/// small window keeps the faces and the preview in view.
const LIST_MIN: f64 = 48.0;
const LIST_MAX: f64 = 260.0;

/// The open picker: its dialog, its rows and what is selected in them.
struct Picker {
    dialog: ContentDialog,
    #[cfg(feature = "harness")]
    layout: Grid,
    #[cfg(feature = "harness")]
    face_scroll: ScrollViewer,
    faces_on: bool,
    rows: Vec<(String, Button)>,
    face_rows: Vec<(FontFace, Button)>,
    face_grid: Grid,
    preview: TextBlock,
    family: Option<String>,
    face: Option<FontFace>,
}

thread_local! {
    static PICKER: RefCell<Option<Picker>> = const { RefCell::new(None) };
}

const PREVIEW: &str = "The quick brown fox jumps over the lazy dog";

fn style_selected(button: &Button, on: bool) -> windows_core::Result<()> {
    let key = if on { "AccentButtonStyle" } else { "DefaultButtonStyle" };
    button.SetStyle(&at(&format!("the theme's {key}"), theme_resource::<Style>(key))?)
}

/// A step's failure named by its call; windows-rs answers a null interface as
/// HRESULT 0, "The operation completed successfully", which names nothing.
fn at<T>(what: &str, result: windows_core::Result<T>) -> windows_core::Result<T> {
    result.map_err(|e| {
        if e.code().is_ok() {
            windows_core::Error::new(windows_core::HRESULT(0x8000_4003u32 as i32), format!("{what} answered null"))
        } else {
            windows_core::Error::new(e.code(), format!("{what}: {}", e.message()))
        }
    })
}

fn text_block(text: &str, family: &str, face: Option<FontFace>) -> windows_core::Result<TextBlock> {
    let block = TextBlock::new()?;
    block.SetText(&HSTRING::from(text))?;
    block.SetFontFamily(&FontFamily::CreateInstanceWithName(&HSTRING::from(family))?)?;
    if let Some(face) = face {
        block.SetFontWeight(bindings::Windows::UI::Text::FontWeight { Weight: face.weight })?;
        block.SetFontStyle(if face.italic { FontStyle::Italic } else { FontStyle::Normal })?;
        block.SetFontStretch(bindings::Windows::UI::Text::FontStretch(i32::from(face.width)))?;
    }
    Ok(block)
}

/// Select a family: its row lit, its faces listed, the preview in it.
fn select_family(name: &str, keep: Option<FontFace>) -> windows_core::Result<()> {
    PICKER.with_borrow_mut(|picker| -> windows_core::Result<()> {
        let Some(picker) = picker.as_mut() else { return Ok(()) };
        for (row, button) in &picker.rows {
            style_selected(button, row == name)?;
        }
        picker.family = Some(name.to_owned());
        let mut faces = real_faces_named(name);
        faces.sort_by(|a, b| a.0.cmp(&b.0));
        let all: Vec<FontFace> = faces.iter().map(|(f, _)| *f).collect();
        let face = keep.and_then(|k| FontFace::matched(&all, k)).or_else(|| FontFace::matched(&all, FontFace::REGULAR));
        picker.face = face;
        let children = picker.face_grid.Children()?;
        children.Clear()?;
        picker.face_rows.clear();
        let columns = picker.face_grid.ColumnDefinitions()?;
        columns.Clear()?;
        if picker.faces_on {
            for (i, (f, title)) in faces.iter().enumerate() {
                let button = Button::new()?;
                button.SetContent(&text_block(title, name, Some(*f))?)?;
                button.SetMargin(Thickness { Left: 0.0, Top: 0.0, Right: 6.0, Bottom: 6.0 })?;
                AutomationProperties::SetName(&button, &HSTRING::from(title.as_str()))?;
                let pick = *f;
                button.Click(&RoutedEventHandler::new(move |_, _| select_face(pick)))?;
                let column = ColumnDefinition::new()?;
                column.SetWidth(GridLength { Value: 1.0, GridUnitType: GridUnitType::Auto })?;
                columns.Append(&column)?;
                Grid::SetColumn(&button, i as i32)?;
                children.Append(&button)?;
                style_selected(&button, Some(*f) == face)?;
                picker.face_rows.push((*f, button));
            }
        }
        picker.preview.SetFontFamily(&FontFamily::CreateInstanceWithName(&HSTRING::from(name))?)?;
        if let Some(face) = face {
            picker.preview.SetFontWeight(bindings::Windows::UI::Text::FontWeight { Weight: face.weight })?;
            picker.preview.SetFontStyle(if face.italic { FontStyle::Italic } else { FontStyle::Normal })?;
        }
        Ok(())
    })
}

fn select_face(face: FontFace) -> windows_core::Result<()> {
    PICKER.with_borrow_mut(|picker| -> windows_core::Result<()> {
        let Some(picker) = picker.as_mut() else { return Ok(()) };
        picker.face = Some(face);
        for (f, button) in &picker.face_rows {
            style_selected(button, *f == face)?;
        }
        picker.preview.SetFontWeight(bindings::Windows::UI::Text::FontWeight { Weight: face.weight })?;
        picker.preview.SetFontStyle(if face.italic { FontStyle::Italic } else { FontStyle::Normal })?;
        picker.preview.SetFontStretch(bindings::Windows::UI::Text::FontStretch(i32::from(face.width)))?;
        Ok(())
    })
}

/// PRESENT_FONT_DIALOG: a ContentDialog of a search box, the families each
/// drawn in itself, the chosen family's faces, a preview line, Cancel and
/// Choose (§4.3). Answered once, from ShowAsync's completion.
pub(super) fn present(core: &mut CoreState, spec: crate::protocol::FontDialogSpec) -> windows_core::Result<()> {
    let host = at("the host window", winui_window(core, spec.window.0))?;
    let root: FrameworkElement = at("the host window's content", host.Content())?.cast()?;
    // docs/traps.md, a ContentDialog presented before the island is live.
    let Ok(xaml_root) = root.XamlRoot() else {
        #[cfg(feature = "harness")]
        crate::vtrace::line("font picker waits for the root's Loaded: its XamlRoot is not live");
        let cell = std::sync::Mutex::new(Some(spec));
        root.Loaded(&RoutedEventHandler::new(move |_, _| {
            if let Some(spec) = cell.lock().unwrap().take() {
                CORE.with_borrow_mut(|core| {
                    let core = core.as_mut().expect("core state initialized");
                    if let Err(e) = present(core, spec) {
                        crate::fault::report(format!("kaya: presenting the font picker once the window loaded failed: {e}"));
                    }
                });
            }
            Ok(())
        }))?;
        return Ok(());
    };
    let dialog = ContentDialog::new()?;
    dialog.SetTitle(&PropertyValue::CreateString(&HSTRING::from("Font"))?)?;
    dialog.SetPrimaryButtonText(&HSTRING::from("Choose"))?;
    dialog.SetCloseButtonText(&HSTRING::from("Cancel"))?;
    dialog.SetDefaultButton(ContentDialogButton::Primary)?;
    let layout = Grid::new()?;
    let rows = layout.RowDefinitions()?;
    for height in [GridUnitType::Auto, GridUnitType::Star, GridUnitType::Auto, GridUnitType::Auto] {
        let row = RowDefinition::new()?;
        row.SetHeight(GridLength { Value: 1.0, GridUnitType: height })?;
        if height == GridUnitType::Star {
            row.SetMinHeight(LIST_MIN)?;
            row.SetMaxHeight(LIST_MAX)?;
        }
        rows.Append(&row)?;
    }
    let search = TextBox::new()?;
    search.SetPlaceholderText(&HSTRING::from("Search"))?;
    AutomationProperties::SetName(&search, &HSTRING::from("Search fonts"))?;
    search.SetMargin(Thickness { Left: 0.0, Top: 0.0, Right: 0.0, Bottom: 8.0 })?;
    let list = Grid::new()?;
    let list_rows = list.RowDefinitions()?;
    let names = families(spec.code_only);
    let mut row_buttons = Vec::new();
    for (i, name) in names.iter().enumerate() {
        let row = RowDefinition::new()?;
        row.SetHeight(GridLength { Value: 1.0, GridUnitType: GridUnitType::Auto })?;
        list_rows.Append(&row)?;
        let button = Button::new()?;
        button.SetContent(&text_block(name, name, None)?)?;
        button.SetHorizontalAlignment(HorizontalAlignment::Stretch)?;
        button.SetHorizontalContentAlignment(HorizontalAlignment::Left)?;
        button.SetMargin(Thickness { Left: 0.0, Top: 0.0, Right: 12.0, Bottom: 2.0 })?;
        AutomationProperties::SetName(&button, &HSTRING::from(name.as_str()))?;
        let pick = name.clone();
        button.Click(&RoutedEventHandler::new(move |_, _| select_family(&pick, None)))?;
        Grid::SetRow(&button, i as i32)?;
        list.Children()?.Append(&button)?;
        row_buttons.push((name.clone(), button));
    }
    let scroll = ScrollViewer::new()?;
    scroll.SetContent(&list)?;
    let face_grid = Grid::new()?;
    face_grid.SetMargin(Thickness { Left: 0.0, Top: 8.0, Right: 0.0, Bottom: 0.0 })?;
    let face_scroll = ScrollViewer::new()?;
    face_scroll.SetHorizontalScrollBarVisibility(ScrollBarVisibility::Auto)?;
    face_scroll.SetVerticalScrollBarVisibility(ScrollBarVisibility::Disabled)?;
    face_scroll.SetHorizontalScrollMode(ScrollMode::Enabled)?;
    face_scroll.SetContent(&face_grid)?;
    let preview = TextBlock::new()?;
    preview.SetText(&HSTRING::from(PREVIEW))?;
    preview.SetFontSize(18.0)?;
    preview.SetTextWrapping(TextWrapping::Wrap)?;
    preview.SetMargin(Thickness { Left: 0.0, Top: 8.0, Right: 0.0, Bottom: 0.0 })?;
    for (i, element) in [
        search.cast::<FrameworkElement>()?,
        scroll.cast::<FrameworkElement>()?,
        face_scroll.cast::<FrameworkElement>()?,
        preview.cast::<FrameworkElement>()?,
    ]
    .iter()
    .enumerate()
    {
        Grid::SetRow(element, i as i32)?;
        layout.Children()?.Append(element)?;
    }
    if !spec.faces {
        face_scroll.SetVisibility(Visibility::Collapsed)?;
    }
    layout.SetMinWidth(420.0)?;
    dialog.SetContent(&layout)?;
    search.TextChanged(&TextChangedEventHandler::new(move |sender, _| {
        let Some(field) = sender.as_ref().and_then(|s| s.cast::<TextBox>().ok()) else { return Ok(()) };
        let needle = field.Text()?.to_string().to_lowercase();
        PICKER.with_borrow(|picker| -> windows_core::Result<()> {
            let Some(picker) = picker.as_ref() else { return Ok(()) };
            for (name, button) in &picker.rows {
                let shown = needle.is_empty() || name.to_lowercase().contains(&needle);
                button.SetVisibility(if shown { Visibility::Visible } else { Visibility::Collapsed })?;
            }
            Ok(())
        })
    }))?;
    dialog.SetXamlRoot(&xaml_root)?;
    PICKER.with_borrow_mut(|picker| {
        *picker = Some(Picker {
            dialog: dialog.clone(),
            #[cfg(feature = "harness")]
            layout: layout.clone(),
            #[cfg(feature = "harness")]
            face_scroll: face_scroll.clone(),
            faces_on: spec.faces,
            rows: row_buttons,
            face_rows: Vec::new(),
            face_grid,
            preview,
            family: None,
            face: None,
        })
    });
    let initial = (!spec.family.is_empty()).then(|| names.iter().find(|n| n.eq_ignore_ascii_case(&spec.family)).cloned()).flatten();
    if let Some(name) = initial {
        let keep = Some(FontFace { weight: spec.weight, italic: spec.italic, width: spec.width });
        at(&format!("selecting the initial family {name}"), select_family(&name, keep))?;
    }
    let sink = core.occurrences.clone();
    let id = spec.dialog;
    let op = at("ContentDialog.ShowAsync", dialog.ShowAsync())?;
    op.SetCompleted(&windows_future::AsyncOperationCompletedHandler::new(
        move |op: windows_core::Ref<'_, windows_future::IAsyncOperation<ContentDialogResult>>, _status| {
            let chosen = op.ok()?.GetResults()? == ContentDialogResult::Primary;
            let picked = PICKER.with_borrow_mut(|picker| picker.take());
            let choice = picked.and_then(|p| {
                if !chosen {
                    return None;
                }
                let family = p.family?;
                let face = if p.faces_on {
                    p.face?
                } else {
                    let all: Vec<FontFace> = real_faces_named(&family).into_iter().map(|(f, _)| f).collect();
                    FontFace::matched(&all, FontFace::REGULAR).unwrap_or(FontFace::REGULAR)
                };
                Some(FontChoice { family, face })
            });
            crate::capi::file_dialog_retire(id.0);
            sink.send(Occurrence::FontDialogResult { dialog: id, choice });
            Ok(())
        },
    ))?;
    Ok(())
}

#[cfg(feature = "harness")]
pub(super) mod read {
    use super::*;
    use bindings::Microsoft::UI::Xaml::Automation::Peers::{ButtonAutomationPeer, FrameworkElementAutomationPeer};

    /// The dialog's own scroller around the picker's content.
    fn dialog_scroller(layout: &Grid) -> windows_core::Result<Option<ScrollViewer>> {
        use bindings::Microsoft::UI::Xaml::Media::VisualTreeHelper;
        let mut at: bindings::Microsoft::UI::Xaml::DependencyObject = layout.cast()?;
        for _ in 0..32 {
            let Ok(parent) = VisualTreeHelper::GetParent(&at) else { return Ok(None) };
            if let Ok(scroller) = parent.cast::<ScrollViewer>() {
                return Ok(Some(scroller));
            }
            at = parent;
        }
        Ok(None)
    }

    /// The picker's faces row and preview that fall below what the dialog
    /// shows without scrolling, or None.
    fn out_of_view(picker: &Picker) -> windows_core::Result<Option<String>> {
        let Some(scroller) = dialog_scroller(&picker.layout)? else {
            return Ok(Some("the picker's content sits in no scroller of the dialog's".to_owned()));
        };
        let viewport = scroller.ViewportHeight()?;
        let mut below = Vec::new();
        let parts: [(&str, FrameworkElement); 2] = [
            ("faces row", picker.face_scroll.cast()?),
            ("preview", picker.preview.cast()?),
        ];
        for (what, element) in parts {
            if what == "faces row" && !picker.faces_on {
                continue;
            }
            let top = element.TransformToVisual(&scroller)?.TransformPoint(Point { X: 0.0, Y: 0.0 })?.Y as f64;
            let bottom = top + element.ActualHeight()?;
            if bottom > viewport + 1.0 {
                below.push(format!("{what} ends at {bottom:.0}"));
            }
        }
        Ok((!below.is_empty()).then(|| {
            format!("the picker's {}, past the {viewport:.0} px the dialog shows", below.join(" and the "))
        }))
    }

    /// The rows the open picker shows, each with DirectWrite's fixed pitch;
    /// an error while its faces row or preview is out of the dialog's view.
    pub(in super::super) fn families() -> windows_core::Result<Result<Option<Vec<crate::harness::ListedFamily>>, String>> {
        PICKER.with_borrow(|picker| -> windows_core::Result<Result<Option<Vec<crate::harness::ListedFamily>>, String>> {
            let Some(picker) = picker.as_ref() else { return Ok(Ok(None)) };
            if !picker.dialog.IsLoaded()? {
                return Ok(Ok(None));
            }
            if let Some(why) = out_of_view(picker)? {
                return Ok(Err(why));
            }
            let mut out = Vec::new();
            for (name, button) in &picker.rows {
                if button.Visibility()? == Visibility::Visible {
                    // DirectWrite's system collection holds installed families only.
                    out.push(crate::harness::ListedFamily {
                        name: name.clone(),
                        fixed: family(name).as_ref().is_some_and(code),
                        alias: false,
                    });
                }
            }
            Ok(Ok(Some(out)))
        })
    }

    fn press(button: &Button) -> windows_core::Result<()> {
        let peer = FrameworkElementAutomationPeer::CreatePeerForElement(button)?;
        let peer: ButtonAutomationPeer = peer.cast()?;
        peer.Invoke()
    }

    /// Drive the picker's own controls: the family's row, the face's, then
    /// the dialog's Choose; or Hide, the close button's path.
    pub(in super::super) fn pick(choice: Option<FontChoice>) -> windows_core::Result<Result<(), String>> {
        let Some((dialog, rows)) = PICKER.with_borrow(|p| p.as_ref().map(|p| (p.dialog.clone(), p.rows.clone())))
        else {
            return Ok(Err("no font picker is open".to_owned()));
        };
        let Some(choice) = choice else {
            dialog.Hide()?;
            return Ok(Ok(()));
        };
        let Some((_, row)) = rows.iter().find(|(name, _)| *name == choice.family) else {
            return Ok(Err(format!("the picker lists no {}", choice.family)));
        };
        press(row)?;
        let faces = PICKER.with_borrow(|p| p.as_ref().map(|p| (p.faces_on, p.face_rows.clone())));
        if let Some((true, face_rows)) = faces {
            let Some((_, button)) = face_rows.iter().find(|(f, _)| *f == choice.face) else {
                return Ok(Err(format!(
                    "{} lists no face {:?} among {:?}",
                    choice.family,
                    choice.face,
                    face_rows.iter().map(|(f, _)| *f).collect::<Vec<_>>()
                )));
            };
            press(button)?;
        }
        use bindings::Microsoft::UI::Xaml::Media::VisualTreeHelper;
        let popups = VisualTreeHelper::GetOpenPopupsForXamlRoot(&dialog.XamlRoot()?)?;
        for i in 0..popups.Size()? {
            let child: UIElement = popups.GetAt(i)?.Child()?;
            if let Some(button) = find_template_button(&child, "PrimaryButton")? {
                press(&button)?;
                return Ok(Ok(()));
            }
        }
        Ok(Err("the picker's Choose button is not in its template".to_owned()))
    }

    /// The face DirectWrite resolves for a family and the props the control
    /// holds: GetFirstMatchingFont, XAML's own matcher, and its simulations.
    pub(in super::super) fn drawn(name: &str, want: FontFace) -> Result<crate::harness::DrawnFace, String> {
        let family = family(name).ok_or_else(|| format!("{name} is not installed"))?;
        unsafe {
            let font = family
                .GetFirstMatchingFont(
                    DWRITE_FONT_WEIGHT(i32::from(want.weight)),
                    DWRITE_FONT_STRETCH(i32::from(want.width)),
                    if want.italic { DWRITE_FONT_STYLE_ITALIC } else { DWRITE_FONT_STYLE_NORMAL },
                )
                .map_err(|e| format!("DirectWrite matched no face of {name}: {}", e.message()))?;
            let simulations = font.GetSimulations();
            let face = face_of(&font);
            let title = font.GetFaceNames().ok().and_then(|n| localized_string(&n).ok()).unwrap_or_default();
            let bold = simulations.0 & DWRITE_FONT_SIMULATIONS_BOLD.0 != 0;
            let oblique = simulations.0 & DWRITE_FONT_SIMULATIONS_OBLIQUE.0 != 0;
            Ok(crate::harness::DrawnFace {
                family: name.to_owned(),
                face: FontFace { italic: face.italic && !oblique, ..face },
                synthetic_italic: oblique,
                synthetic_bold: bold,
                detail: format!("{title}, simulations {}", simulations.0),
            })
        }
    }
}
