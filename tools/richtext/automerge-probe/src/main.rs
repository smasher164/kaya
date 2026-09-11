//! The automerge benchmark for docs/rich-text-plan.md's protocol: a model
//! of kaya's rich mirror (text + runs, the widget's own inheritance rule)
//! beside an automerge 0.11 document in kaya's unit, driven by the plan's
//! messages — text_edited / text_formatted up, apply_edit down — through
//! local typing, toolbar acts, two peers editing concurrently and merging,
//! multi-byte text, the caret transform against automerge's own cursors,
//! and the cost per edit. `cargo run --release` prints the record.

use automerge::marks::{ExpandMark, Mark};
use automerge::transaction::Transactable;
use automerge::{Automerge, ChangeHash, ObjType, PatchAction, ReadDoc, ScalarValue, TextEncoding, ROOT};
use automerge::iter::Span;
use std::collections::BTreeMap;
use std::time::Instant;

// ---------------------------------------------------------------- kaya's side

/// One attribute run: a half-open byte range and its attributes.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct Run { start: usize, end: usize, attrs: BTreeMap<String, String> }

/// The plan's `text_edited`: offsets into the text BEFORE the edit; runs
/// cover `inserted` only (relative to it).
#[derive(Clone, Debug)]
struct Edit { start: usize, end: usize, inserted: String, runs: Vec<(usize, usize, BTreeMap<String, String>)> }

/// kaya's mirror, as the core would hold it for a rich textarea: the text
/// plus per-byte attributes (a run list normalized on demand). The
/// INHERITANCE RULE the widget applies to typed text, stated once: an
/// insertion inherits the inline attributes of the byte before it, except
/// a link, which never grows by typing (Peritext's "after" anchor).
#[derive(Clone, Default)]
struct Mirror { text: String, attrs: Vec<BTreeMap<String, String>> }

impl Mirror {
    fn runs(&self) -> Vec<Run> {
        let mut out: Vec<Run> = Vec::new();
        let mut i = 0;
        while i < self.attrs.len() {
            let a = &self.attrs[i];
            let mut j = i + 1;
            while j < self.attrs.len() && &self.attrs[j] == a { j += 1; }
            if !a.is_empty() { out.push(Run { start: i, end: j, attrs: a.clone() }); }
            i = j;
        }
        out
    }
    fn assert_boundaries(&self, start: usize, end: usize) {
        assert!(start <= end && end <= self.text.len(), "range {start}..{end} outside {}", self.text.len());
        assert!(self.text.is_char_boundary(start) && self.text.is_char_boundary(end), "range {start}..{end} splits a code point");
    }
    /// The widget's own act: the user typed/pasted `inserted` over `start..end`.
    /// Produces the text_edited the widget would publish (runs from the
    /// inheritance rule, or the given explicit runs, e.g. bold toggled off).
    fn user_edit(&mut self, start: usize, end: usize, inserted: &str, explicit: Option<BTreeMap<String, String>>) -> Edit {
        self.assert_boundaries(start, end);
        let inherited = explicit.unwrap_or_else(|| {
            if start == 0 { BTreeMap::new() } else {
                let mut a = self.attrs[start - 1].clone(); a.remove("link"); a
            }
        });
        let edit = Edit { start, end, inserted: inserted.to_string(), runs: if inserted.is_empty() || inherited.is_empty() { vec![] } else { vec![(0, inserted.len(), inherited.clone())] } };
        self.apply(&edit);
        edit
    }
    /// The plan's apply_edit (a remote edit) and the second half of user_edit.
    fn apply(&mut self, e: &Edit) {
        self.assert_boundaries(e.start, e.end);
        let mut new_attrs: Vec<BTreeMap<String, String>> = vec![BTreeMap::new(); e.inserted.len()];
        for (s, t, a) in &e.runs { for k in *s..*t { new_attrs[k] = a.clone(); } }
        self.text.replace_range(e.start..e.end, &e.inserted);
        self.attrs.splice(e.start..e.end, new_attrs);
    }
    /// The plan's text_formatted: a toolbar act over a range.
    fn format(&mut self, start: usize, end: usize, name: &str, value: Option<&str>) {
        self.assert_boundaries(start, end);
        for k in start..end { match value { Some(v) => { self.attrs[k].insert(name.to_string(), v.to_string()); } None => { self.attrs[k].remove(name); } } }
    }
    /// The caret transform the plan states (R5): unchanged before, shifted
    /// after, a caret at the edit's start ends AFTER the insertion.
    fn transform_caret(caret: usize, e: &Edit) -> usize {
        if caret < e.start { caret }
        else if caret >= e.end { caret - (e.end - e.start) + e.inserted.len() }
        else { e.start + e.inserted.len() }
    }
}

// ------------------------------------------------------------- the bridge

fn scalar(v: &str) -> ScalarValue { if v == "true" { ScalarValue::Boolean(true) } else { ScalarValue::Str(v.into()) } }
fn scalar_str(v: &ScalarValue) -> Option<String> {
    match v { ScalarValue::Boolean(true) => Some("true".into()), ScalarValue::Boolean(false) | ScalarValue::Null => None, ScalarValue::Str(s) => Some(s.to_string()), other => Some(format!("{other:?}")) }
}

/// automerge's runs in kaya's shape, from spans().
fn am_runs<R: ReadDoc>(doc: &R, text: &automerge::ObjId) -> (String, Vec<Run>) {
    let mut s = String::new(); let mut runs = Vec::new();
    for span in doc.spans(text).expect("spans") {
        if let Span::Text { text: t, marks } = span {
            let start = s.len(); s.push_str(&t);
            let mut attrs = BTreeMap::new();
            if let Some(m) = marks { for (k, v) in m.iter() { if let Some(v) = scalar_str(v) { attrs.insert(k.to_string(), v); } } }
            if !attrs.is_empty() { runs.push(Run { start, end: s.len(), attrs }); }
        }
    }
    // merge adjacent equal runs, as the mirror's runs() does
    let mut merged: Vec<Run> = Vec::new();
    for r in runs { if let Some(last) = merged.last_mut() { if last.end == r.start && last.attrs == r.attrs { last.end = r.end; continue; } } merged.push(r); }
    (s, merged)
}

/// The app's bridge for a local text_edited: splice with the patch log on,
/// read what automerge's expand rules put on the inserted text from the
/// splice's OWN patch (no document walk), then make the inserted range
/// carry EXACTLY the widget's runs (mark what the widget says, unmark what
/// automerge expanded on its own). Expand policy is the app's: `After` for
/// inline styles (typing grows them), `None` for links.
fn bridge_edit(doc: &mut Automerge, text: &automerge::ObjId, e: &Edit) {
    let success = doc.transact_and_log_patches::<_, _, automerge::AutomergeError>(|tx| {
        tx.splice_text(text, e.start, (e.end - e.start) as isize, &e.inserted)
    }).expect("splice");
    if e.inserted.is_empty() { return; }
    let mut patch_log = success.patch_log;
    let mut have: Vec<BTreeMap<String, String>> = vec![BTreeMap::new(); e.inserted.len()];
    for p in doc.make_patches(&mut patch_log) {
        if let PatchAction::SpliceText { index, value, marks } = p.action {
            let len = value.make_string().len();
            let mut attrs = BTreeMap::new();
            if let Some(m) = marks { for (k, v) in m.iter() { if let Some(v) = scalar_str(v) { attrs.insert(k.to_string(), v); } } }
            for k in index.max(e.start)..(index + len).min(e.start + e.inserted.len()) { have[k - e.start] = attrs.clone(); }
        }
    }
    let mut want: Vec<BTreeMap<String, String>> = vec![BTreeMap::new(); e.inserted.len()];
    for (s, t, a) in &e.runs { for k in *s..*t { want[k] = a.clone(); } }
    if have == want { return; }
    doc.transact::<_, _, automerge::AutomergeError>(|tx| {
        let names: std::collections::BTreeSet<String> = have.iter().chain(want.iter()).flat_map(|m| m.keys().cloned()).collect();
        for name in names {
            let mut i = 0;
            while i < e.inserted.len() {
                let w = want[i].get(&name).cloned(); let h = have[i].get(&name).cloned();
                let mut j = i + 1;
                while j < e.inserted.len() && want[j].get(&name) == w.as_ref() && have[j].get(&name) == h.as_ref() { j += 1; }
                if w != h {
                    let expand = if name == "link" { ExpandMark::None } else { ExpandMark::After };
                    match w {
                        Some(v) => tx.mark(text, Mark::new(name.clone(), scalar(&v), e.start + i, e.start + j), expand)?,
                        None => tx.unmark(text, &name, e.start + i, e.start + j, expand)?,
                    }
                }
                i = j;
            }
        }
        Ok(())
    }).expect("reconcile");
}

fn bridge_format(doc: &mut Automerge, text: &automerge::ObjId, start: usize, end: usize, name: &str, value: Option<&str>) {
    let expand = if name == "link" { ExpandMark::None } else { ExpandMark::After };
    doc.transact::<_, _, automerge::AutomergeError>(|tx| {
        match value { Some(v) => tx.mark(text, Mark::new(name.to_string(), scalar(v), start, end), expand), None => tx.unmark(text, name, start, end, expand) }
    }).expect("bridge_format");
}

/// automerge's patches since `before`, turned into the plan's DOWN messages
/// and applied to the mirror: SpliceText -> apply_edit(insert with runs),
/// DeleteSeq -> apply_edit(delete), Mark -> format.
fn apply_patches(mirror: &mut Mirror, doc: &Automerge, text_obj: &automerge::ObjId, before: &[ChangeHash], caret: &mut usize, log: &mut Vec<String>) {
    let after = doc.get_heads();
    for p in doc.diff(before, &after) {
        if &p.obj != text_obj { continue; }
        match p.action {
            PatchAction::SpliceText { index, value, marks } => {
                let s = value.make_string();
                let mut attrs = BTreeMap::new();
                if let Some(m) = marks { for (k, v) in m.iter() { if let Some(v) = scalar_str(v) { attrs.insert(k.to_string(), v); } } }
                let e = Edit { start: index, end: index, inserted: s.clone(), runs: if attrs.is_empty() { vec![] } else { vec![(0, s.len(), attrs)] } };
                *caret = Mirror::transform_caret(*caret, &e);
                log.push(format!("apply_edit insert @{index} {:?}", s));
                mirror.apply(&e);
            }
            PatchAction::DeleteSeq { index, length } => {
                let e = Edit { start: index, end: index + length, inserted: String::new(), runs: vec![] };
                *caret = Mirror::transform_caret(*caret, &e);
                log.push(format!("apply_edit delete {index}..{}", index + length));
                mirror.apply(&e);
            }
            PatchAction::Mark { marks } => {
                for m in marks {
                    let v = scalar_str(m.value());
                    log.push(format!("format {}..{} {}={:?}", m.start, m.end, m.name(), v));
                    mirror.format(m.start, m.end, m.name(), v.as_deref());
                }
            }
            other => log.push(format!("other patch: {other:?}")),
        }
    }
}

fn check(label: &str, mirror: &Mirror, doc: &Automerge, text: &automerge::ObjId) -> bool {
    let (s, runs) = am_runs(doc, text);
    let ok = s == mirror.text && runs == mirror.runs();
    println!("{} {label}: text {:?} runs {:?}", if ok { "OK  " } else { "DIFF" }, mirror.text, mirror.runs());
    if !ok { println!("     automerge: text {s:?} runs {runs:?}"); }
    ok
}

fn new_doc() -> (Automerge, automerge::ObjId) {
    let mut doc = Automerge::new_with_encoding(TextEncoding::Utf8CodeUnit);
    let text = doc.transact::<_, _, automerge::AutomergeError>(|tx| tx.put_object(ROOT, "text", ObjType::Text)).expect("text object").result;
    (doc, text)
}

fn main() {
    let mut all = true;
    println!("== automerge 0.11.0, TextEncoding::Utf8CodeUnit, against kaya's mirror model ==");

    // 1. LOCAL TYPING AND TOOLBAR ACTS
    let (mut doc, text) = new_doc();
    let mut m = Mirror::default();
    let e = m.user_edit(0, 0, "Hello world", None); bridge_edit(&mut doc, &text, &e);
    all &= check("typed", &m, &doc, &text);
    m.format(6, 11, "bold", Some("true")); bridge_format(&mut doc, &text, 6, 11, "bold", Some("true"));
    all &= check("bold world", &m, &doc, &text);
    let e = m.user_edit(11, 11, " again", None); bridge_edit(&mut doc, &text, &e);   // inherits bold
    all &= check("typed at the bold end (inherits)", &m, &doc, &text);
    let e = m.user_edit(17, 17, "!", Some(BTreeMap::new())); bridge_edit(&mut doc, &text, &e); // bold toggled off before typing
    all &= check("typed with bold off (unmark reconciles expand)", &m, &doc, &text);
    m.format(0, 5, "link", Some("https://kaya.dev")); bridge_format(&mut doc, &text, 0, 5, "link", Some("https://kaya.dev"));
    let e = m.user_edit(5, 5, "?", None); bridge_edit(&mut doc, &text, &e);          // link never grows by typing
    all &= check("typed at the link end (does not inherit)", &m, &doc, &text);
    let e = m.user_edit(6, 12, "", None); bridge_edit(&mut doc, &text, &e);           // delete " world"
    all &= check("deleted across a run boundary", &m, &doc, &text);
    m.format(0, 3, "link", None); bridge_format(&mut doc, &text, 0, 3, "link", None);
    all &= check("link removed on part of its run", &m, &doc, &text);

    // 2. MULTI-BYTE: emoji, CJK, combining marks — every offset a byte
    let (mut doc, text) = new_doc(); let mut m = Mirror::default();
    let e = m.user_edit(0, 0, "héllo 👋 世界 e\u{301}", None); bridge_edit(&mut doc, &text, &e);
    let bold_start = "héllo ".len(); let bold_end = bold_start + "👋".len();
    m.format(bold_start, bold_end, "bold", Some("true")); bridge_format(&mut doc, &text, bold_start, bold_end, "bold", Some("true"));
    all &= check("multi-byte bold on the emoji", &m, &doc, &text);
    let e = m.user_edit(bold_end, bold_end, "🎉", None); bridge_edit(&mut doc, &text, &e);
    all &= check("multi-byte typed after the emoji (inherits bold)", &m, &doc, &text);
    let bad = doc.transact::<_, _, automerge::AutomergeError>(|tx| tx.mark(&text, Mark::new("bold".into(), ScalarValue::Boolean(true), 1, 2), ExpandMark::After));
    println!("     a mark splitting 'é' (byte 1..2): automerge says {:?} (kaya refuses it before lowering)", bad.err().map(|e| format!("{e:?}")));

    // 3. TWO PEERS, CONCURRENT EDITS, MERGE -> apply_edit stream; caret against automerge's cursor
    let (mut a, text_a) = new_doc(); let mut ma = Mirror::default();
    let e = ma.user_edit(0, 0, "The quick brown fox", None); bridge_edit(&mut a, &text_a, &e);
    let mut b = a.fork(); let text_b = text_a.clone(); let mut mb = ma.clone();
    // A: bolds "quick", types at the end. B: inserts "very " before "quick", italicizes "fox".
    let before_a = a.get_heads();
    ma.format(4, 9, "bold", Some("true")); bridge_format(&mut a, &text_a, 4, 9, "bold", Some("true"));
    let e = ma.user_edit(19, 19, " jumps", None); bridge_edit(&mut a, &text_a, &e);
    let e = mb.user_edit(4, 4, "very ", None); bridge_edit(&mut b, &text_b, &e);
    mb.format(16, 19, "italic", Some("true")); bridge_format(&mut b, &text_b, 16, 19, "italic", Some("true"));
    // A's local caret sits after "quick" (byte 9); automerge's cursor is the oracle
    let mut caret_a = 9usize;
    let cursor = a.get_cursor(&text_a, caret_a, None).expect("cursor");
    let heads_before_merge = a.get_heads();
    a.merge(&mut b).expect("merge");
    let mut log = Vec::new();
    apply_patches(&mut ma, &a, &text_a, &heads_before_merge, &mut caret_a, &mut log);
    for l in &log { println!("     A took: {l}"); }
    all &= check("A after merging B", &ma, &a, &text_a);
    let oracle = a.get_cursor_position(&text_a, &cursor, None).expect("cursor position");
    println!("{} caret transform: kaya {caret_a}, automerge's cursor {oracle}", if caret_a == oracle { "OK  " } else { "DIFF" });
    all &= caret_a == oracle;
    let _ = before_a;
    // B takes A's changes the same way
    let heads_b = b.get_heads(); b.merge(&mut a).expect("merge"); let mut caret_b = 0; let mut log = Vec::new();
    apply_patches(&mut mb, &b, &text_b, &heads_b, &mut caret_b, &mut log);
    all &= check("B after merging A", &mb, &b, &text_b);
    println!("     peers agree: {}", ma.text == mb.text && ma.runs() == mb.runs());
    all &= ma.text == mb.text && ma.runs() == mb.runs();

    // 4. A REMOTE INSERT EXACTLY AT THE LOCAL CARET (R5's association)
    let (mut a, text_a) = new_doc(); let mut ma = Mirror::default();
    let e = ma.user_edit(0, 0, "ab", None); bridge_edit(&mut a, &text_a, &e);
    let mut b = a.fork(); let text_b = text_a.clone(); let mut mb = ma.clone();
    let e = mb.user_edit(1, 1, "XYZ", None); bridge_edit(&mut b, &text_b, &e);
    let mut caret = 1usize; let cursor = a.get_cursor(&text_a, caret, None).expect("cursor");
    let heads = a.get_heads(); a.merge(&mut b).expect("merge"); let mut log = Vec::new();
    apply_patches(&mut ma, &a, &text_a, &heads, &mut caret, &mut log);
    let oracle = a.get_cursor_position(&text_a, &cursor, None).expect("pos");
    println!("{} remote insert at the caret: text {:?}, kaya caret {caret}, automerge cursor (MoveCursor::After) {oracle}", if caret == oracle { "OK  " } else { "DIFF" }, ma.text);
    all &= caret == oracle;

    // 5. COST PER EDIT on a 50 KB document: splice + reconcile (spans walk) vs splice alone
    let (mut doc, text) = new_doc(); let mut m = Mirror::default();
    let base: String = "The quick brown fox jumps over the lazy dog. ".repeat(1100);
    let e = m.user_edit(0, 0, &base, None); bridge_edit(&mut doc, &text, &e);
    for k in 0..40 { let s = k * 1200; m.format(s, s + 50, "bold", Some("true")); bridge_format(&mut doc, &text, s, s + 50, "bold", Some("true")); }
    let n = 2000; let mut pos = 100usize; let t0 = Instant::now();
    for i in 0..n {
        pos = (pos + 37 * (i + 1)) % (m.text.len() - 10); while !m.text.is_char_boundary(pos) { pos += 1; }
        let e = m.user_edit(pos, pos, "x", None); bridge_edit(&mut doc, &text, &e);
    }
    let per = t0.elapsed().as_secs_f64() * 1000.0 / n as f64;
    let t1 = Instant::now();
    for i in 0..n { pos = (pos + 41 * (i + 1)) % (m.text.len() - 10); while !m.text.is_char_boundary(pos) { pos += 1; }
        doc.transact::<_, _, automerge::AutomergeError>(|tx| tx.splice_text(&text, pos, 0, "y")).unwrap(); m.text.insert(pos, 'y'); m.attrs.insert(pos, m.attrs[pos.saturating_sub(1)].clone()); }
    let per_splice = t1.elapsed().as_secs_f64() * 1000.0 / n as f64;
    let t2 = Instant::now(); let _ = am_runs(&doc, &text); let spans_ms = t2.elapsed().as_secs_f64() * 1000.0;
    println!("     cost on a {} KB document with 40 bold runs: bridged edit (splice + reconcile from its own patch) {per:.3}ms; splice alone {per_splice:.3}ms; one spans() walk {spans_ms:.3}ms", m.text.len() / 1024);
    let (s, _) = am_runs(&doc, &text); println!("     after 4000 edits the texts agree: {}", s == m.text);
    all &= s == m.text;

    println!("== {} ==", if all { "EVERY CHECK AGREED" } else { "DISAGREEMENTS ABOVE" });
    std::process::exit(if all { 0 } else { 1 });
}
