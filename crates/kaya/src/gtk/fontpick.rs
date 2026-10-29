//! The face and the font picker on GNOME (docs/font-picker-plan.md): Pango's
//! installed faces, matched by the core's CSS rule, GtkFontDialog, and the
//! reads the harness takes off what Pango resolved.

use super::*;
use crate::protocol::{FontChoice, FontFace};
use gtk4::glib::translate::{FromGlib, IntoGlib};
use gtk4::pango;

/// An installed family by its name, as Pango lists it on this display.
pub(super) fn pango_family(name: &str) -> Option<pango::FontFamily> {
    if name.is_empty() {
        return None;
    }
    gtk4::Label::new(None).pango_context().list_families().into_iter().find(|f| f.name().eq_ignore_ascii_case(name))
}

/// The portable three of a Pango description: the weight, any slope, and the
/// stretch as the OpenType width class.
pub(super) fn face_of(desc: &pango::FontDescription) -> FontFace {
    FontFace {
        weight: desc.weight().into_glib().clamp(1, 1000) as u16,
        italic: desc.style() != pango::Style::Normal,
        width: (desc.stretch().into_glib() + 1).clamp(1, 9) as u8,
    }
}

/// A description asking for `family` at `face`.
pub(super) fn desc_of(family: &str, face: FontFace) -> pango::FontDescription {
    let mut desc = pango::FontDescription::new();
    desc.set_family(family);
    desc.set_weight(unsafe { pango::Weight::from_glib(i32::from(face.weight)) });
    desc.set_style(if face.italic { pango::Style::Italic } else { pango::Style::Normal });
    desc.set_stretch(unsafe { pango::Stretch::from_glib(i32::from(face.width) - 1) });
    desc
}

/// A family's installed faces with their names: Pango also lists the faces
/// it would synthesize (DejaVu Sans' Italic, measured), which are not
/// installed and are dropped.
pub(super) fn real_faces(family: &pango::FontFamily) -> Vec<(FontFace, String)> {
    family
        .list_faces()
        .iter()
        .filter(|f| !f.is_synthesized())
        .map(|f| (face_of(&f.describe()), f.face_name().to_string()))
        .collect()
}

/// list_font_faces (docs/font-picker-plan.md §4.4).
pub(super) fn list_font_faces(core: &mut CoreState, family: &str) {
    let lines: Vec<String> = pango_family(family)
        .map(|f| real_faces(&f))
        .unwrap_or_default()
        .into_iter()
        .map(|(face, name)| format!("{}\t{}\t{}\t{name}", face.weight, u8::from(face.italic), face.width))
        .collect();
    core.occurrences.send(Occurrence::FontFaces {
        family: family.to_owned(),
        faces: crate::capi::font_face_list(&lines.join("\n")),
    });
}

/// A code font for the picker: Pango's monospace flag AND the Latin it is
/// for, since Pango calls Noto Color Emoji monospace (measured) and it has no
/// letters.
pub(super) fn code_family(family: &pango::FontFamily) -> bool {
    if !family.is_monospace() {
        return false;
    }
    let context = gtk4::Label::new(None).pango_context();
    let mut desc = pango::FontDescription::new();
    desc.set_family(&family.name());
    context.load_font(&desc).is_some_and(|font| font.has_char('M') && font.has_char('i'))
}

/// The CSS stretch keyword for an OpenType width class.
pub(super) fn stretch_keyword(width: u8) -> &'static str {
    [
        "ultra-condensed",
        "extra-condensed",
        "condensed",
        "semi-condensed",
        "normal",
        "semi-expanded",
        "expanded",
        "extra-expanded",
        "ultra-expanded",
    ][usize::from(width.clamp(1, 9)) - 1]
}

/// PRESENT_FONT_DIALOG: GtkFontDialog over the window, a family alone or,
/// with faces, a family and a face from choose_font, whose size row is shown
/// and ignored (Q6, RULED). Answered once, its id retired first.
pub(super) fn present(core: &mut CoreState, spec: crate::protocol::FontDialogSpec) {
    let parent = gtk_window(core, spec.window.0);
    let title = "Font".to_owned();
    let dialog = gtk4::FontDialog::builder().title(&title).modal(true).build();
    if spec.code_only {
        let filter = gtk4::CustomFilter::new(|item| {
            let family = item
                .downcast_ref::<pango::FontFamily>()
                .cloned()
                .or_else(|| item.downcast_ref::<pango::FontFace>().and_then(|f| f.family().into()));
            family.as_ref().is_some_and(code_family)
        });
        dialog.set_filter(Some(&filter));
    }
    *core.live_font_dialog.borrow_mut() = Some(title);
    let live = core.live_font_dialog.clone();
    let sink = core.occurrences.clone();
    let id = spec.dialog;
    let answer = move |choice: Option<FontChoice>| {
        *live.borrow_mut() = None;
        crate::capi::file_dialog_retire(id.0);
        sink.send(Occurrence::FontDialogResult { dialog: id, choice });
    };
    if spec.faces {
        let initial = (!spec.family.is_empty()).then(|| {
            desc_of(&spec.family, FontFace { weight: spec.weight, italic: spec.italic, width: spec.width })
        });
        dialog.choose_font(Some(&parent), initial.as_ref(), None::<&gtk4::gio::Cancellable>, move |result| {
            answer(result.ok().and_then(|desc| {
                let family = desc.family()?.to_string();
                Some(FontChoice { family, face: face_of(&desc) })
            }));
        });
    } else {
        let initial = pango_family(&spec.family);
        dialog.choose_family(Some(&parent), initial.as_ref(), None::<&gtk4::gio::Cancellable>, move |result| {
            answer(result.ok().map(|family| {
                let faces: Vec<FontFace> = real_faces(&family).into_iter().map(|(f, _)| f).collect();
                FontChoice {
                    family: family.name().to_string(),
                    face: FontFace::matched(&faces, FontFace::REGULAR).unwrap_or(FontFace::REGULAR),
                }
            }));
        });
    }
}

/// The face Pango resolved for a description: the installed face it found,
/// and what fontconfig synthesizes over it. A synthesized slope resolves to
/// NO face (measured: DejaVu Sans Oblique, face None), so the installed face
/// under it is the family's own match.
#[cfg(feature = "harness")]
pub(super) fn drawn(font: &pango::Font) -> Result<crate::harness::DrawnFace, String> {
    let desc = font.describe();
    let asked = face_of(&desc);
    let family = desc.family().map(|f| f.to_string()).unwrap_or_default();
    let (face, detail) = match font.face() {
        Some(face) if !face.is_synthesized() => (face_of(&face.describe()), format!("{} {}", family, face.face_name())),
        _ => {
            let faces: Vec<FontFace> =
                pango_family(&family).map(|f| real_faces(&f).into_iter().map(|(f, _)| f).collect()).unwrap_or_default();
            let under = FontFace::matched(&faces, asked).ok_or_else(|| format!("{family} lists no installed face"))?;
            (under, format!("{} with no installed face for {}", desc, crate::harness::face_words_text(
                &crate::harness::FaceWords { face: asked, synthesized: false })))
        }
    };
    Ok(crate::harness::DrawnFace {
        family,
        face,
        synthetic_italic: asked.italic && !face.italic,
        synthetic_bold: asked.weight >= 600 && face.weight < 600,
        detail,
    })
}

/// Whether a family draws Latin at one advance: ten i's and ten M's laid
/// out as wide, in that family and no fallback.
#[cfg(feature = "harness")]
pub(super) fn measured_fixed_pitch(family: &str) -> bool {
    let context = gtk4::Label::new(None).pango_context();
    let mut desc = pango::FontDescription::new();
    desc.set_family(family);
    desc.set_size(12 * pango::SCALE);
    let width = |text: &str| {
        let layout = pango::Layout::new(&context);
        layout.set_font_description(Some(&desc));
        layout.set_text(text);
        let used = layout.iter().run().map(|run| run.item().analysis().font().describe().family().map(|f| f.to_string()));
        (layout.pixel_size().0, used.flatten())
    };
    let (narrow, a) = width("iiiiiiiiii");
    let (wide, b) = width("MMMMMMMMMM");
    // A fontconfig alias (Monospace) lists only synthesized faces (measured)
    // and draws in the family it names, so its run reports that family.
    let alias = pango_family(family).is_some_and(|f| f.list_faces().iter().all(|face| face.is_synthesized()));
    let same = |f: Option<String>| f.is_some_and(|f| alias || f.eq_ignore_ascii_case(family));
    same(a) && same(b) && (narrow - wide).abs() <= 1
}

/// The open picker's window: GtkFontDialog's own GtkFontChooserDialog, the one
/// visible while kaya's request is live.
#[cfg(feature = "harness")]
pub(super) fn dialog_window(core: &CoreState) -> Option<gtk4::Window> {
    core.live_font_dialog.borrow().as_ref()?;
    gtk4::Window::list_toplevels()
        .into_iter()
        .filter_map(|w| w.downcast::<gtk4::Window>().ok())
        .find(|w| w.is_visible() && w.type_().name() == "GtkFontChooserDialog")
}

#[cfg(feature = "harness")]
fn descendants(widget: &gtk4::Widget, out: &mut Vec<gtk4::Widget>) {
    out.push(widget.clone());
    let mut child = widget.first_child();
    while let Some(c) = child {
        descendants(&c, out);
        child = c.next_sibling();
    }
}

/// The families the open picker's list shows, off its list view's model.
#[cfg(feature = "harness")]
pub(super) fn listed_families(window: &gtk4::Window) -> Result<Vec<String>, String> {
    let mut all = Vec::new();
    descendants(window.upcast_ref(), &mut all);
    let list = all
        .iter()
        .filter_map(|w| w.downcast_ref::<gtk4::ListView>())
        .find(|l| l.is_mapped())
        .ok_or("the picker shows no list")?;
    let model = list.model().ok_or("the picker's list has no model")?;
    let mut names = Vec::new();
    for i in 0..model.n_items() {
        let Some(item) = model.item(i) else { continue };
        let family = item
            .downcast_ref::<pango::FontFamily>()
            .cloned()
            .or_else(|| item.downcast_ref::<pango::FontFace>().and_then(|f| f.family().into()));
        if let Some(family) = family {
            let name = family.name().to_string();
            if !names.contains(&name) {
                names.push(name);
            }
        }
    }
    Ok(names)
}

/// Choose in the open picker: its chooser set to the font, then its own OK;
/// or its Cancel.
#[cfg(feature = "harness")]
#[allow(deprecated)]
pub(super) fn pick(window: &gtk4::Window, choice: Option<&FontChoice>) -> Result<(), String> {
    let dialog = window.downcast_ref::<gtk4::Dialog>().ok_or("the picker is not a GtkDialog")?;
    let Some(choice) = choice else {
        dialog.response(gtk4::ResponseType::Cancel);
        return Ok(());
    };
    let mut all = Vec::new();
    descendants(window.upcast_ref(), &mut all);
    let chooser = all
        .iter()
        .find_map(|w| w.dynamic_cast_ref::<gtk4::FontChooser>().cloned())
        .ok_or("the picker holds no font chooser")?;
    let family = pango_family(&choice.family).ok_or_else(|| format!("{} is not installed", choice.family))?;
    if chooser.level().contains(gtk4::FontChooserLevel::STYLE) {
        let faces = real_faces(&family);
        let (face, name) = faces
            .iter()
            .find(|(f, _)| *f == choice.face)
            .ok_or_else(|| format!("{} has no face {}", choice.family, crate::harness::face_words_text(
                &crate::harness::FaceWords { face: choice.face, synthesized: false })))?;
        let mut desc = desc_of(&choice.family, *face);
        desc.set_size(12 * pango::SCALE);
        let _ = name;
        chooser.set_font_desc(&desc);
    } else {
        let mut desc = pango::FontDescription::new();
        desc.set_family(&family.name());
        chooser.set_font_desc(&desc);
    }
    dialog.response(gtk4::ResponseType::Ok);
    Ok(())
}
