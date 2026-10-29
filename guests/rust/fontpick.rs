//! The font picker scene (tools/scenes/fontpick.steps, docs/font-picker-plan.md
//! §7): the guest reads the platform's families and faces, sets a face exactly,
//! between two weights and slanted on a family with no italic, composes Bold
//! and Italic over a light document, and opens the picker for code fonts with
//! faces, applying the answer.

use kaya::{FontChoice, FontFace, NamedFace};

/// The monospaced families the scene picks from, the first one installed.
const MONO: [&str; 7] =
    ["Menlo", "DejaVu Sans Mono", "Cascadia Mono", "Consolas", "Courier New", "Droid Sans Mono", "monospace"];

const DOC: &str = "bold run, italic run, plain run";

fn words(face: FontFace) -> String {
    format!("{} {} {}", face.weight, if face.italic { "italic" } else { "upright" }, face.width)
}

/// A family with a light upright face that has an italic, a 700, and two
/// upright weights at or above 500 with a weight between them: the light
/// and the pair, or None.
fn light_family(faces: &[NamedFace]) -> Option<(u16, u16, u16)> {
    let upright: Vec<u16> = faces.iter().filter(|f| !f.face.italic && f.face.width == 5).map(|f| f.face.weight).collect();
    let italic: Vec<u16> = faces.iter().filter(|f| f.face.italic && f.face.width == 5).map(|f| f.face.weight).collect();
    if upright.len() < 3 || !upright.contains(&700) {
        return None;
    }
    let light = *upright.iter().find(|w| **w < 400 && italic.contains(w))?;
    let pair = upright.windows(2).find(|p| p[0] >= 500 && p[1] > p[0] + 1)?;
    Some((light, pair[0], pair[1]))
}

/// A family with no slanted face at all, and its first upright weight.
fn upright_only(faces: &[NamedFace]) -> Option<u16> {
    if faces.is_empty() || faces.iter().any(|f| f.face.italic) {
        return None;
    }
    faces.iter().find(|f| f.face.width == 5).map(|f| f.face.weight)
}

#[derive(Clone)]
enum Msg {
    Find,
    Families(Vec<String>),
    Faces(String, Vec<NamedFace>),
    Pick,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let s = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("fontpick");
        let sig = |tx: &mut kaya::Tx, v: &str| tx.signal(v.to_string());
        let ready = sig(tx, "faces: -");
        let want = [sig(tx, "-"), sig(tx, "-"), sig(tx, "-"), sig(tx, "-"), sig(tx, "-"), sig(tx, "-")];
        let pick = sig(tx, "-");
        let picked = sig(tx, "picked: -");
        let (root, ids) = tx
            .column(|tx| {
                tx.label(ready).a11y_id("ready");
                let text = sig(tx, "Exact");
                let exact = tx.label(text).a11y_id("exact").id();
                let text = sig(tx, "Between");
                let between = tx.label(text).a11y_id("between").id();
                let text = sig(tx, "Slanted");
                let synth = tx.label(text).a11y_id("synth").id();
                let doc = tx.textarea().rich().a11y_id("doc").id();
                let text = sig(tx, "Chosen");
                let chosen = tx.label(text).a11y_id("chosen").id();
                for (signal, id) in want.iter().zip(["want_exact", "want_between", "want_synth", "want_bold", "want_italic", "want_pick"]) {
                    tx.label(*signal).a11y_id(id);
                }
                tx.label(pick).a11y_id("pick");
                tx.label(picked).a11y_id("picked");
                tx.row(|tx| {
                    let find = tx.button("faces").a11y_id("faces").id();
                    msgs.on_click(find, Msg::Find);
                    let open = tx.button("pick").a11y_id("pick_button").id();
                    msgs.on_click(open, Msg::Pick);
                });
                [exact, between, synth, doc, chosen]
            })
            .into_parts();
        tx.mount(root);
        (ready, want, pick, picked, ids)
    });
    let (ready, want, pick, picked, [exact, between, synth, doc, chosen]) = s;
    msgs.on_font_families(|families| Msg::Families(families.to_vec()));
    msgs.on_font_faces(|family, faces| Msg::Faces(family.to_owned(), faces.to_vec()));

    let mut queue: Vec<String> = Vec::new();
    let mut light: Option<(String, (u16, u16, u16))> = None;
    let mut plain: Option<(String, u16)> = None;
    let mut mono: Option<String> = None;
    let mut asked: Option<FontChoice> = None;
    let tasks = ctx.tasks();
    while let Some(msg) = tasks.next(&msgs) {
        match msg {
            Msg::Find => ctx.apply(|tx| tx.list_font_families()),
            Msg::Families(families) => {
                mono = MONO.iter().find(|m| families.iter().any(|f| f == *m)).map(|m| m.to_string());
                queue = families.into_iter().rev().collect();
                if let Some(m) = &mono {
                    queue.push(m.clone());
                }
                if let Some(next) = queue.pop() {
                    ctx.apply(|tx| tx.list_font_faces(next));
                }
            }
            Msg::Faces(family, faces) => {
                if Some(&family) == mono.as_ref() && asked.is_none() {
                    let face = faces
                        .iter()
                        .map(|f| f.face)
                        .find(|f| *f == FontFace { weight: 700, italic: false, width: 5 })
                        .or_else(|| faces.first().map(|f| f.face));
                    if let Some(face) = face {
                        asked = Some(FontChoice { family: family.clone(), face });
                    }
                }
                if light.is_none() {
                    light = light_family(&faces).map(|l| (family.clone(), l));
                }
                if plain.is_none() {
                    plain = upright_only(&faces).map(|w| (family.clone(), w));
                }
                if light.is_none() || plain.is_none() {
                    match queue.pop() {
                        Some(next) => ctx.apply(|tx| tx.list_font_faces(next)),
                        None => ctx.apply(|tx| tx.write(ready, "faces: none suit".to_string())),
                    }
                    continue;
                }
                let (lf, (lw, a, b)) = light.clone().unwrap();
                let (pf, pw) = plain.clone().unwrap();
                let face = |weight, italic| FontFace { weight, italic, width: 5 };
                ctx.apply(|tx| {
                    tx.family(exact, lf.as_str());
                    tx.font_weight(exact, lw);
                    tx.family(between, lf.as_str());
                    tx.font_weight(between, a + (b - a) / 2);
                    tx.family(synth, pf.as_str());
                    tx.font_weight(synth, pw);
                    tx.font_italic(synth, true);
                    tx.family(doc, lf.as_str());
                    tx.font_weight(doc, lw);
                    tx.set_document(doc, &kaya::Document::new(DOC).bold(0..4).italic(10..16));
                    tx.write(want[0], words(face(lw, false)));
                    tx.write(want[1], words(face(b, false)));
                    tx.write(want[2], format!("{} synthesized", words(face(pw, true))));
                    tx.write(want[3], words(face(700, false)));
                    tx.write(want[4], words(face(lw, true)));
                    if let Some(c) = &asked {
                        tx.write(pick, format!("{} {}", words(c.face), c.family));
                        tx.write(want[5], words(c.face));
                    }
                    tx.write(ready, "faces: found".to_string());
                });
            }
            Msg::Pick => {
                let asked = asked.clone();
                tasks.spawn(async move |app| {
                    let mut request = app.choose_font().code_only(true).faces(true);
                    if let Some(c) = &asked {
                        request = request.initial(c);
                    }
                    let answer = request.await;
                    app.apply(|tx| match answer {
                        None => tx.write(picked, "picked: cancelled".to_string()),
                        Some(c) => {
                            tx.family(chosen, c.family.as_str());
                            tx.font_weight(chosen, c.face.weight);
                            tx.font_italic(chosen, c.face.italic);
                            tx.font_width(chosen, c.face.width);
                            let said = if Some(&c) == asked.as_ref() {
                                "picked: as asked".to_string()
                            } else {
                                format!("picked: {} {}", words(c.face), c.family)
                            };
                            tx.write(picked, said);
                        }
                    });
                });
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
