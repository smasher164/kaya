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

/// The binding's fold in the core's spelling.
fn spell_fold(runs: &[kaya::Run]) -> String {
    runs.iter()
        .map(|run| {
            if run.value == "true" {
                format!("{}:{} {}", run.start, run.end, run.name)
            } else {
                format!("{}:{} {}={}", run.start, run.end, run.name, run.value)
            }
        })
        .collect::<Vec<_>>()
        .join("|")
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

/// One remote mark: a range-addressed format (docs/rich-text-plan.md §17).
struct MarkAct {
    start: usize,
    end: usize,
    name: String,
    value: Option<String>,
}

/// The patches between two views of the local document, as the widget's
/// DOWN messages: SpliceText and DeleteSeq become apply_edit with their
/// runs, a Mark patch a ranged format act (docs/rich-text-plan.md §16, §17).
fn patches_to_edits(doc: &Doc, before: &[ChangeHash], after: &[ChangeHash]) -> (Vec<kaya::Edit>, Vec<MarkAct>) {
    let mut edits = Vec::new();
    let mut marks = Vec::new();
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
            PatchAction::Mark { marks: set } => {
                for mark in set.iter() {
                    marks.push(MarkAct {
                        start: mark.start,
                        end: mark.end,
                        name: mark.name().to_string(),
                        value: scalar_str(mark.value()),
                    });
                }
            }
            _ => {}
        }
    }
    (edits, marks)
}

/// The marks on the widget, over their ranges, the selection untouched.
fn apply_marks(tx: &mut kaya::Tx, editor: kaya::WidgetId, marks: &[MarkAct]) {
    for mark in marks {
        match &mark.value {
            Some(value) => tx.format_range(editor, mark.start..mark.end, &mark.name, value),
            None => tx.unformat_range(editor, mark.start..mark.end, &mark.name),
        }
    }
}

/// The peer's scripted session, one step per click: an insert before the
/// caret, a deletion before it, a concurrent insert at the caret's own
/// offset (automerge's order by actor decides, the same on every lane), an
/// italic mark over a range the user is not touching, and the bold taken
/// off the first two bytes — the two marks arrive as ranged format acts.
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
            3 => Box::new(move |tx| {
                tx.mark(&text, Mark::new("italic".into(), ScalarValue::Boolean(true), 1, 3), ExpandMark::After)
            }),
            4 => Box::new(move |tx| tx.unmark(&text, "bold", 0, 2, ExpandMark::After)),
            _ => return false,
        };
    peer.am.transact::<_, _, automerge::AutomergeError>(|tx| op(tx)).expect("peer step");
    true
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (status, mirror, fold, editor) = ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW)
            .title("notes")
            .menu("Edit", |m| {
                let undo = m.item("Undo").role(kaya::MenuRole::Undo).id();
                let redo = m.item("Redo").role(kaya::MenuRole::Redo).id();
                msgs.on_menu_item(undo, Msg::Undo);
                msgs.on_menu_item(redo, Msg::Redo);
            })
            .id();
        let status = tx.signal("peer 0 undo 0 redo 0");
        let mirror = tx.signal("");
        let fold = tx.signal("");
        let (root, editor) = tx
            .column(|tx| {
                tx.label(status).a11y_id("status"); // label#0
                tx.label(mirror).a11y_id("mirror"); // label#1
                tx.label(fold).a11y_id("fold"); // label#2: the binding's own Document
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
        (status, mirror, fold, editor)
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
    // A TYPING RUN IS ONE HISTORY ENTRY: consecutive user keystrokes extend
    // the entry they started, the way every editor's undo groups typing —
    // and the only rule that reads the same on a platform that reports one
    // keystroke per edit and on one that folds a typed word into one
    // (WinUI, matrix 13). The edit's source (ruling 3) tells a keystroke
    // from a paste, a drop or an IME commit, each of which starts its own.
    let mut typing_run = false;

    // FOUR VIEWS OF ONE DOCUMENT: the widget's runs and the core's mirror
    // (expect_runs), automerge's spans (label#1), and the binding's own fold
    // (label#2) — the last is what a silent write must move too
    // (docs/rich-text-plan.md §17).
    let publish = |tx: &mut kaya::Tx,
                   local: &Doc,
                   history: &[Vec<ChangeHash>],
                   redo: &[Vec<ChangeHash>],
                   step: usize,
                   folded: String| {
        tx.write(status, format!("peer {step} undo {} redo {}", history.len() - 1, redo.len()));
        tx.write(mirror, local.runs());
        tx.write(fold, folded);
        tx.can_undo(editor, history.len() > 1);
        tx.can_redo(editor, !redo.is_empty());
    };

    // Walk the local document from `from` to `to` heads by re-applying the
    // diff as a new change, and mirror every patch onto the widget.
    let walk = |ctx: &kaya::AppCtx, local: &mut Doc, to: &[ChangeHash]| {
        let from = local.am.get_heads();
        let (edits, marks) = patches_to_edits(local, &from, to);
        for edit in &edits {
            bridge_edit(local, edit);
            ctx.apply(|tx| tx.apply_edit(editor, edit));
        }
        for mark in &marks {
            bridge_format(local, &kaya::Format {
                start: mark.start as u64,
                end: mark.end as u64,
                name: mark.name.clone(),
                value: mark.value.clone(),
            });
        }
        ctx.apply(|tx| apply_marks(tx, editor, &marks));
    };

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Edited(edit) => {
                bridge_edit(&mut local, &edit);
                let keystroke = edit.source == Some(kaya::EditSource::User);
                if keystroke && typing_run {
                    *history.last_mut().expect("a head") = local.am.get_heads();
                } else {
                    history.push(local.am.get_heads());
                }
                typing_run = keystroke;
                redo.clear();
                let folded = spell_fold(&ctx.document(editor).runs);
                ctx.apply(|tx| publish(tx, &local, &history, &redo, step, folded));
            }
            Msg::Formatted(act) => {
                bridge_format(&mut local, &act);
                typing_run = false;
                history.push(local.am.get_heads());
                redo.clear();
                let folded = spell_fold(&ctx.document(editor).runs);
                ctx.apply(|tx| publish(tx, &local, &history, &redo, step, folded));
            }
            Msg::Peer => {
                if !peer_step(&mut peer, step) {
                    continue;
                }
                step += 1;
                typing_run = false;
                let before = local.am.get_heads();
                // The peer acted on ITS view, then both sides merge: a step
                // at the local caret's own offset is a true concurrent edit.
                peer.am.merge(&mut local.am).expect("peer merge");
                local.am.merge(&mut peer.am).expect("local merge");
                let after = local.am.get_heads();
                let (edits, marks) = patches_to_edits(&local, &before, &after);
                ctx.apply(|tx| {
                    for edit in &edits {
                        tx.apply_edit(editor, edit);
                    }
                    apply_marks(tx, editor, &marks);
                });
                history.push(after);
                redo.clear();
                let folded = spell_fold(&ctx.document(editor).runs);
                ctx.apply(|tx| publish(tx, &local, &history, &redo, step, folded));
            }
            Msg::Undo => {
                typing_run = false;
                if history.len() < 2 {
                    continue;
                }
                let current = history.pop().expect("a head");
                let target = history.last().expect("a head").clone();
                walk(&ctx, &mut local, &target);
                redo.push(current);
                let folded = spell_fold(&ctx.document(editor).runs);
                ctx.apply(|tx| publish(tx, &local, &history, &redo, step, folded));
            }
            Msg::Redo => {
                typing_run = false;
                let Some(target) = redo.pop() else { continue };
                walk(&ctx, &mut local, &target);
                history.push(target);
                let folded = spell_fold(&ctx.document(editor).runs);
                ctx.apply(|tx| publish(tx, &local, &history, &redo, step, folded));
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
