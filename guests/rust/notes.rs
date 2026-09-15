//! The notes demo (tools/scenes/notes.steps; docs/rich-text-plan.md §16): a
//! rich textarea with automerge behind it and a headless peer beside it.
//! Every user edit becomes a splice on the local document, every toolbar
//! act a mark, and the peer's changes come back through the merge as
//! apply_edit messages carrying their runs — the probe's bridge
//! (tools/richtext/automerge-probe) on the real widget. The app owns the
//! history (own_undo), which is a walk over automerge's own heads.
//! OFFSETS ARE UTF-8 BYTES, kaya's unit and the document's encoding.

use automerge::{
    ActorId, Automerge, ChangeHash, ObjId, ObjType, PatchAction, ReadDoc, ScalarValue,
    TextEncoding, ROOT,
    iter::Span,
    marks::{ExpandMark, Mark},
    transaction::Transactable,
};
use std::collections::BTreeMap;

#[derive(Clone)]
enum Msg {
    Edited(kaya::Edit),
    Formatted(kaya::Format),
    Peer,
    Undo,
    Redo,
}

struct Doc {
    am: Automerge,
    text: ObjId,
}

impl Doc {
    fn new(actor: &[u8]) -> Doc {
        let mut am = Automerge::new_with_encoding(TextEncoding::Utf8CodeUnit);
        am.set_actor(ActorId::from(actor));
        let text = am
            .transact::<_, _, automerge::AutomergeError>(|tx| {
                tx.put_object(ROOT, "text", ObjType::Text)
            })
            .expect("text object")
            .result;
        Doc { am, text }
    }

    /// The document's runs in the core's spelling, so the app's own view
    /// of the CRDT can be compared with the widget's and the core's.
    fn runs(&self) -> String {
        let mut at = 0usize;
        let mut runs: Vec<(usize, usize, String, String)> = Vec::new();
        for span in self.am.spans(&self.text).expect("spans") {
            if let Span::Text { text, marks } = span {
                let start = at;
                at += text.len();
                if let Some(marks) = marks {
                    for (name, value) in marks.iter() {
                        if let Some(value) = scalar_str(value) {
                            runs.push((start, at, name.to_string(), value));
                        }
                    }
                }
            }
        }
        let mut merged: Vec<(usize, usize, String, String)> = Vec::new();
        for run in runs {
            if let Some(last) = merged.iter_mut().rev().find(|l| l.2 == run.2) {
                if last.1 == run.0 && last.3 == run.3 {
                    last.1 = run.1;
                    continue;
                }
            }
            merged.push(run);
        }
        merged.sort_by(|a, b| (a.0, &a.2).cmp(&(b.0, &b.2)));
        merged
            .into_iter()
            .map(|(s, e, n, v)| if v == "true" { format!("{s}:{e} {n}") } else { format!("{s}:{e} {n}={v}") })
            .collect::<Vec<_>>()
            .join("|")
    }
}

fn scalar(v: &str) -> ScalarValue {
    if v == "true" { ScalarValue::Boolean(true) } else { ScalarValue::Str(v.into()) }
}

fn scalar_str(v: &ScalarValue) -> Option<String> {
    match v {
        ScalarValue::Boolean(true) => Some("true".into()),
        ScalarValue::Boolean(false) | ScalarValue::Null => None,
        ScalarValue::Str(s) => Some(s.to_string()),
        other => Some(format!("{other}")),
    }
}

fn expand_for(name: &str) -> ExpandMark {
    if name == "link" { ExpandMark::None } else { ExpandMark::After }
}

/// A local text_edited: the splice, then the inserted range made to carry
/// EXACTLY the widget's runs — what automerge's expand put there is read
/// from the splice's own patch, never from a document walk.
fn bridge_edit(doc: &mut Doc, edit: &kaya::Edit) {
    let text = doc.text.clone();
    let (start, end) = (edit.start as usize, edit.end as usize);
    let success = doc
        .am
        .transact_and_log_patches::<_, _, automerge::AutomergeError>(|tx| {
            tx.splice_text(&text, start, (end - start) as isize, &edit.inserted)
        })
        .expect("splice");
    if edit.inserted.is_empty() {
        return;
    }
    let len = edit.inserted.len();
    let mut patch_log = success.patch_log;
    let mut have: Vec<BTreeMap<String, String>> = vec![BTreeMap::new(); len];
    for patch in doc.am.make_patches(&mut patch_log) {
        if let PatchAction::SpliceText { index, value, marks } = patch.action {
            let got = value.make_string().len();
            let mut attrs = BTreeMap::new();
            if let Some(marks) = marks {
                for (name, value) in marks.iter() {
                    if let Some(value) = scalar_str(value) {
                        attrs.insert(name.to_string(), value);
                    }
                }
            }
            for k in index.max(start)..(index + got).min(start + len) {
                have[k - start] = attrs.clone();
            }
        }
    }
    let mut want: Vec<BTreeMap<String, String>> = vec![BTreeMap::new(); len];
    for run in &edit.runs {
        for k in run.start as usize..run.end as usize {
            want[k].insert(run.name.clone(), run.value.clone());
        }
    }
    if have == want {
        return;
    }
    doc.am
        .transact::<_, _, automerge::AutomergeError>(|tx| {
            let names: std::collections::BTreeSet<String> =
                have.iter().chain(want.iter()).flat_map(|m| m.keys().cloned()).collect();
            for name in names {
                let mut i = 0;
                while i < len {
                    let w = want[i].get(&name).cloned();
                    let h = have[i].get(&name).cloned();
                    let mut j = i + 1;
                    while j < len && want[j].get(&name) == w.as_ref() && have[j].get(&name) == h.as_ref() {
                        j += 1;
                    }
                    if w != h {
                        match w {
                            Some(v) => tx.mark(
                                &text,
                                Mark::new(name.clone(), scalar(&v), start + i, start + j),
                                expand_for(&name),
                            )?,
                            None => tx.unmark(&text, &name, start + i, start + j, expand_for(&name))?,
                        }
                    }
                    i = j;
                }
            }
            Ok(())
        })
        .expect("reconcile");
}

/// A local text_formatted: one mark or unmark over the act's range.
fn bridge_format(doc: &mut Doc, act: &kaya::Format) {
    let text = doc.text.clone();
    let (start, end) = (act.start as usize, act.end as usize);
    doc.am
        .transact::<_, _, automerge::AutomergeError>(|tx| match &act.value {
            Some(v) => tx.mark(&text, Mark::new(act.name.clone(), scalar(v), start, end), expand_for(&act.name)),
            None => tx.unmark(&text, &act.name, start, end, expand_for(&act.name)),
        })
        .expect("bridge_format");
}

/// The patches between two views of the local document, as the widget's
/// DOWN messages: SpliceText and DeleteSeq become apply_edit with their
/// runs. A Mark patch is a range-addressed format, which the protocol's
/// selection-scoped act cannot carry yet (docs/rich-text-plan.md §16);
/// it is counted and reported until the range lands.
fn patches_to_edits(doc: &Doc, before: &[ChangeHash], after: &[ChangeHash]) -> (Vec<kaya::Edit>, usize) {
    let mut edits = Vec::new();
    let mut marks = 0;
    for patch in doc.am.diff(before, after) {
        if patch.obj != doc.text {
            continue;
        }
        match patch.action {
            PatchAction::SpliceText { index, value, marks: spliced } => {
                let inserted = value.make_string();
                let mut edit = kaya::Edit::insert(index, inserted.clone());
                if let Some(spliced) = spliced {
                    for (name, value) in spliced.iter() {
                        if let Some(value) = scalar_str(value) {
                            edit = edit.mark(0..inserted.len(), name.as_ref(), value);
                        }
                    }
                }
                edits.push(edit);
            }
            PatchAction::DeleteSeq { index, length } => edits.push(kaya::Edit::delete(index..index + length)),
            PatchAction::Mark { .. } => marks += 1,
            _ => {}
        }
    }
    (edits, marks)
}

/// The peer's scripted session, one step per click: an insert before the
/// caret, a deletion before it, a concurrent insert at the caret's own
/// offset (automerge's order by actor decides, the same on every lane).
fn peer_step(peer: &mut Doc, step: usize) -> bool {
    let text = peer.text.clone();
    let op: Box<dyn Fn(&mut automerge::transaction::Transaction<'_>) -> Result<(), automerge::AutomergeError>> =
        match step {
            0 => Box::new(move |tx| tx.splice_text(&text, 0, 0, "Hi, ")),
            1 => Box::new(move |tx| tx.splice_text(&text, 0, 4, "")),
            2 => Box::new(move |tx| {
                let len = tx.text(&text)?.len();
                tx.splice_text(&text, len, 0, "Z")
            }),
            _ => return false,
        };
    peer.am.transact::<_, _, automerge::AutomergeError>(|tx| op(tx)).expect("peer step");
    true
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (status, mirror, editor) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW)
            .title("notes")
            .menu("Edit", |m| {
                let undo = m.item("Undo").role(kaya::MenuRole::Undo).id();
                let redo = m.item("Redo").role(kaya::MenuRole::Redo).id();
                msgs.on_menu_item(undo, Msg::Undo);
                msgs.on_menu_item(redo, Msg::Redo);
            })
            .id();
        let status = tx.signal("peer 0 undo 0 redo 0 marks 0");
        let mirror = tx.signal("");
        let (root, editor) = tx
            .column(|tx| {
                tx.label(status).a11y_id("status"); // label#0
                tx.label(mirror).a11y_id("mirror"); // label#1
                let editor = tx
                    .textarea()
                    .rich()
                    .own_undo()
                    .a11y_id("notes")
                    .a11y_label("Notes")
                    .id(); // textarea#0
                msgs.on_edit(editor, Msg::Edited);
                msgs.on_format(editor, Msg::Formatted);
                let peer = tx.button("peer").id(); // button#0
                msgs.on_click(peer, Msg::Peer);
                editor
            })
            .into_parts();
        tx.mount(root);
        tx.focus(editor);
        (status, mirror, editor)
    });

    let mut local = Doc::new(b"local");
    // ONE document, two actors: a peer is a FORK of the local document, so
    // the text object it edits is the one the widget shows. Two documents
    // each creating "text" at the root merge into two conflicting objects,
    // and the peer's edits land in one the widget never displays.
    let mut peer = Doc { am: local.am.fork().with_actor(ActorId::from(&b"peer!"[..])), text: local.text.clone() };
    // THE APP'S HISTORY: the local document's heads after each of its own
    // steps; undo re-applies the diff back to the previous heads as a NEW
    // change, which is what a CRDT's selective undo is.
    let mut history: Vec<Vec<ChangeHash>> = vec![local.am.get_heads()];
    let mut redo: Vec<Vec<ChangeHash>> = Vec::new();
    let mut step = 0usize;
    let mut marks_pending = 0usize;

    let publish = |tx: &mut kaya::Tx,
                   local: &Doc,
                   history: &[Vec<ChangeHash>],
                   redo: &[Vec<ChangeHash>],
                   step: usize,
                   marks: usize| {
        tx.write(status, format!("peer {step} undo {} redo {} marks {marks}", history.len() - 1, redo.len()));
        tx.write(mirror, local.runs());
        tx.can_undo(editor, history.len() > 1);
        tx.can_redo(editor, !redo.is_empty());
    };

    // Walk the local document from `from` to `to` heads by re-applying the
    // diff as a new change, and mirror every patch onto the widget.
    let walk = |ctx: &kaya::AppCtx, local: &mut Doc, to: &[ChangeHash], marks_pending: &mut usize| {
        let from = local.am.get_heads();
        let (edits, marks) = patches_to_edits(local, &from, to);
        *marks_pending += marks;
        for edit in &edits {
            bridge_edit(local, edit);
            ctx.apply(|tx| tx.apply_edit(editor, edit));
        }
    };

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Edited(edit) => {
                bridge_edit(&mut local, &edit);
                history.push(local.am.get_heads());
                redo.clear();
                ctx.apply(|tx| publish(tx, &local, &history, &redo, step, marks_pending));
            }
            Msg::Formatted(act) => {
                bridge_format(&mut local, &act);
                history.push(local.am.get_heads());
                redo.clear();
                ctx.apply(|tx| publish(tx, &local, &history, &redo, step, marks_pending));
            }
            Msg::Peer => {
                if !peer_step(&mut peer, step) {
                    continue;
                }
                step += 1;
                let before = local.am.get_heads();
                // The peer acted on ITS view, then both sides merge: a step
                // at the local caret's own offset is a true concurrent edit.
                peer.am.merge(&mut local.am).expect("peer merge");
                local.am.merge(&mut peer.am).expect("local merge");
                let after = local.am.get_heads();
                let (edits, marks) = patches_to_edits(&local, &before, &after);
                marks_pending += marks;
                ctx.apply(|tx| {
                    for edit in &edits {
                        tx.apply_edit(editor, edit);
                    }
                });
                history.push(after);
                redo.clear();
                ctx.apply(|tx| publish(tx, &local, &history, &redo, step, marks_pending));
            }
            Msg::Undo => {
                if history.len() < 2 {
                    continue;
                }
                let current = history.pop().expect("a head");
                let target = history.last().expect("a head").clone();
                walk(&ctx, &mut local, &target, &mut marks_pending);
                redo.push(current);
                ctx.apply(|tx| publish(tx, &local, &history, &redo, step, marks_pending));
            }
            Msg::Redo => {
                let Some(target) = redo.pop() else { continue };
                walk(&ctx, &mut local, &target, &mut marks_pending);
                history.push(target);
                ctx.apply(|tx| publish(tx, &local, &history, &redo, step, marks_pending));
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
