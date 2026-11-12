//! The `.kdoc` file (docs/rich-document-plan.md §4, RD8, RD9, RD13): JSON
//! paragraphs of spans, one codec for nine bindings.

use std::collections::BTreeMap;

use serde_json::Value as Json;

use super::{
    PARA_PREFIX, canonical_value, final_state, is_extension, is_kept_name, is_para_key, is_paragraph_attr, normalize_runs, para_attrs,
    paragraph_names, paragraphs, structure_refusal,
};
use crate::protocol::TextRun;

pub(crate) const VERSION: u64 = 1;
pub(crate) const MEDIA_TYPE: &str = "application/vnd.kaya.document+json";

/// The inline marks in the order a file spells them; extensions follow by name.
const INLINE_ORDER: &[&str] = &["bold", "italic", "underline", "strike", "code", "link", "color"];
const FLAGS: &[&str] = &["bold", "italic", "underline", "strike", "code"];

/// A document read from a file: its text and runs, and why it may only be
/// read when it carries what this kaya cannot keep through an edit.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Read {
    pub text: String,
    pub runs: Vec<TextRun>,
    /// The top-level members this kaya does not know, as one JSON object's
    /// text, "" when there are none (RD17 A).
    pub extra: String,
    pub read_only: Option<String>,
}

/// The members a `.kdoc`'s top level spells for kaya itself.
const DOCUMENT_KEYS: &[&str] = &["kaya", "version", "requires", "paragraphs", "history"];

fn json_string(out: &mut String, s: &str) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

/// A kept name's value: text that is JSON is written as itself, anything
/// else as a string; `kept_value` is the reading half, so a file's value goes
/// back out unchanged.
fn extension_value(out: &mut String, value: &str) {
    match serde_json::from_str::<Json>(value) {
        Ok(_) => out.push_str(value),
        Err(_) => json_string(out, value),
    }
}

/// A kept name's value from the file: a string is its text unless that text
/// would read back as JSON (`"7"`, `"true"`), which keeps its quotes.
fn kept_value(v: &Json) -> String {
    match v {
        Json::String(s) if serde_json::from_str::<Json>(s).is_err() => s.clone(),
        other => other.to_string(),
    }
}

fn mark_value(out: &mut String, name: &str, value: &str) {
    if FLAGS.contains(&name) {
        out.push_str("true");
    } else if is_extension(name) {
        extension_value(out, value);
    } else {
        json_string(out, value);
    }
}

/// `extra`'s members, or why it is not the unknown top level of a document.
fn extra_members(extra: &str) -> Result<serde_json::Map<String, Json>, String> {
    if extra.is_empty() {
        return Ok(serde_json::Map::new());
    }
    let Ok(Json::Object(members)) = serde_json::from_str::<Json>(extra) else {
        return Err(format!("the document's extra is {extra:?}, and it is a JSON object's text or empty"));
    };
    if let Some(key) = members.keys().find(|k| DOCUMENT_KEYS.contains(&k.as_str())) {
        return Err(format!("the document's extra carries {key:?}, which the file spells for kaya itself"));
    }
    Ok(members)
}

/// The document as a `.kdoc`, or why it cannot be one: the same walls
/// set_rich_text holds (a vocabulary name or a kept name, a canonical value,
/// paragraph attributes over whole paragraphs, RD2's scope), and `extra`
/// written back as the top-level members it holds.
pub fn write(text: &str, runs: &[TextRun], extra: &str) -> Result<String, String> {
    let members = extra_members(extra)?;
    for run in runs {
        let known = crate::wire::RICH_ATTRS.iter().any(|(_, n)| *n == run.name);
        if !known && !is_kept_name(&run.name) {
            return Err(format!(
                "{:?} is not a kaya attribute, an app's dotted name nor a {PARA_PREFIX} paragraph key",
                run.name
            ));
        }
        if run.range.start > run.range.end || run.range.end as usize > text.len() {
            return Err(format!("the {} run {}..{} is outside the {}-byte text", run.name, run.range.start, run.range.end, text.len()));
        }
        for at in [run.range.start as usize, run.range.end as usize] {
            if !text.is_char_boundary(at) {
                return Err(format!("the {} run's byte {at} is inside a character", run.name));
            }
        }
        if known {
            match canonical_value(&run.name, &run.value) {
                Ok(Some(v)) if v == run.value => {}
                Ok(Some(v)) => return Err(format!("the {} run spells {:?}, which is {v:?} in kaya's one spelling", run.name, run.value)),
                Ok(None) => return Err(format!("the {} run's {:?} is the attribute's absence; drop the run", run.name, run.value)),
                Err(why) => return Err(why),
            }
        }
    }
    let runs = normalize_runs(runs.to_vec());
    let state = final_state(text, &runs);
    if let Some(why) = structure_refusal(text, &runs, &state) {
        return Err(why);
    }
    let mut out = String::new();
    out.push_str("{\n  \"kaya\": \"document\",\n  \"version\": 1,\n  \"requires\": [],\n");
    for (key, value) in &members {
        out.push_str("  ");
        json_string(&mut out, key);
        out.push_str(": ");
        out.push_str(&value.to_string());
        out.push_str(",\n");
    }
    out.push_str("  \"paragraphs\": [\n");
    let paras = paragraphs(text);
    let names = paragraph_names(&runs);
    for (i, para) in paras.iter().enumerate() {
        out.push_str("    {");
        let attrs = para_attrs(&runs, para, &state);
        for name in &names {
            if let Some(value) = attrs.get(name) {
                match name.strip_prefix(PARA_PREFIX) {
                    Some(key) => {
                        json_string(&mut out, key);
                        out.push_str(": ");
                        extension_value(&mut out, value);
                    }
                    None => {
                        json_string(&mut out, name);
                        out.push_str(": ");
                        match name.as_str() {
                            "indent" | "start" => out.push_str(value),
                            "checked" => out.push_str("true"),
                            _ => json_string(&mut out, value),
                        }
                    }
                }
                out.push_str(", ");
            }
        }
        out.push_str("\"spans\": [");
        let spans = spans_of(text, &runs, para.start, para.end);
        for (j, (piece, marks)) in spans.iter().enumerate() {
            if j > 0 {
                out.push_str(", ");
            }
            out.push('[');
            json_string(&mut out, piece);
            if !marks.is_empty() {
                out.push_str(", {");
                for (k, (name, value)) in ordered(marks).into_iter().enumerate() {
                    if k > 0 {
                        out.push_str(", ");
                    }
                    json_string(&mut out, name);
                    out.push_str(": ");
                    mark_value(&mut out, name, value);
                }
                out.push('}');
            }
            out.push(']');
        }
        out.push_str("]}");
        if i + 1 < paras.len() {
            out.push(',');
        }
        out.push('\n');
    }
    out.push_str("  ]\n}\n");
    Ok(out)
}

fn ordered(marks: &BTreeMap<String, String>) -> Vec<(&str, &str)> {
    let mut out: Vec<(&str, &str)> = INLINE_ORDER
        .iter()
        .filter_map(|n| marks.get(*n).map(|v| (*n, v.as_str())))
        .collect();
    out.extend(marks.iter().filter(|(n, _)| !INLINE_ORDER.contains(&n.as_str())).map(|(n, v)| (n.as_str(), v.as_str())));
    out
}

/// `start..end` cut at every inline run's edge, each piece with its marks.
pub(crate) fn spans_of(text: &str, runs: &[TextRun], start: usize, end: usize) -> Vec<(String, BTreeMap<String, String>)> {
    let mut cuts = vec![start, end];
    for run in runs.iter().filter(|r| !is_paragraph_attr(&r.name)) {
        for at in [run.range.start as usize, run.range.end as usize] {
            if at > start && at < end {
                cuts.push(at);
            }
        }
    }
    cuts.sort_unstable();
    cuts.dedup();
    let mut out: Vec<(String, BTreeMap<String, String>)> = Vec::new();
    for pair in cuts.windows(2) {
        let (a, b) = (pair[0], pair[1]);
        let marks: BTreeMap<String, String> = super::attrs_at(runs, a).into_iter().filter(|(n, _)| !is_paragraph_attr(n)).collect();
        match out.last_mut() {
            Some((piece, last)) if *last == marks => piece.push_str(&text[a..b]),
            _ => out.push((text[a..b].to_owned(), marks)),
        }
    }
    out
}

fn kind_name(v: &Json) -> &'static str {
    match v {
        Json::Null => "null",
        Json::Bool(_) => "a boolean",
        Json::Number(_) => "a number",
        Json::String(_) => "a string",
        Json::Array(_) => "an array",
        Json::Object(_) => "an object",
    }
}

/// A paragraph attribute's value from the file, in the run's spelling.
fn paragraph_value(name: &str, v: &Json, index: usize) -> Result<Option<String>, String> {
    let raw = match (name, v) {
        ("indent" | "start", Json::Number(n)) => match n.as_u64() {
            Some(n) => n.to_string(),
            None => return Err(format!("paragraph {index}'s {name} is {n}, not a whole number")),
        },
        ("checked", Json::Bool(true)) => crate::protocol::FLAG_VALUE.to_owned(),
        ("checked", Json::Bool(false)) => return Ok(None),
        ("block" | "list" | "align", Json::String(s)) => s.clone(),
        (_, other) => return Err(format!("paragraph {index}'s {name} is {}, which is not how a file spells it", kind_name(other))),
    };
    canonical_value(name, &raw).map_err(|why| format!("paragraph {index}: {why}"))
}

fn mark_from(name: &str, v: &Json, index: usize) -> Result<Option<String>, String> {
    if is_extension(name) {
        return Ok(Some(kept_value(v)));
    }
    let raw = match (name, v) {
        (n, Json::Bool(true)) if FLAGS.contains(&n) => crate::protocol::FLAG_VALUE.to_owned(),
        (n, Json::Bool(false)) if FLAGS.contains(&n) => return Ok(None),
        ("link" | "color", Json::String(s)) => s.clone(),
        (_, other) => return Err(format!("paragraph {index}'s {name} mark is {}, which is not how a file spells it", kind_name(other))),
    };
    canonical_value(name, &raw).map_err(|why| format!("paragraph {index}: {why}"))
}

struct ParaIn {
    attrs: BTreeMap<String, String>,
    spans: Vec<(String, BTreeMap<String, String>)>,
}

/// A `.kdoc` read: refused in one sentence when it is not one, or names a
/// newer major version; READ-ONLY, naming what, when it carries a name this
/// kaya cannot keep through an edit (RD8, and the interim of RD17).
pub fn read(bytes: &[u8]) -> Result<Read, String> {
    let root: Json = serde_json::from_slice(bytes).map_err(|e| format!("the file is not JSON: {e}"))?;
    let Json::Object(root) = root else {
        return Err(format!("the file is {}, and a kaya document is an object", kind_name(&root)));
    };
    if root.get("kaya") != Some(&Json::String("document".to_owned())) {
        return Err("the file is not a kaya document: it has no \"kaya\": \"document\" key".to_owned());
    }
    let version = match root.get("version") {
        Some(Json::Number(n)) if n.as_u64().is_some_and(|v| v >= 1) => n.as_u64().expect("checked"),
        other => return Err(format!("the document's version is {}, and it is a whole number from 1", other.map_or("missing", kind_name))),
    };
    if version > VERSION {
        return Err(format!("the document is version {version}, newer than the version {VERSION} this kaya reads"));
    }
    let mut lacks: Vec<String> = Vec::new();
    match root.get("requires") {
        None => {}
        Some(Json::Array(names)) => {
            for name in names {
                match name {
                    Json::String(s) => lacks.push(format!("it requires {s:?}")),
                    other => return Err(format!("a requires entry is {}, and each is a name", kind_name(other))),
                }
            }
        }
        Some(other) => return Err(format!("requires is {}, and it is a list of names", kind_name(other))),
    }
    let extra: serde_json::Map<String, Json> =
        root.iter().filter(|(k, _)| !DOCUMENT_KEYS.contains(&k.as_str())).map(|(k, v)| (k.clone(), v.clone())).collect();
    let extra = if extra.is_empty() { String::new() } else { Json::Object(extra).to_string() };
    let Some(Json::Array(list)) = root.get("paragraphs") else {
        return Err("the document has no paragraphs list".to_owned());
    };
    let mut paras: Vec<ParaIn> = Vec::new();
    for (index, p) in list.iter().enumerate() {
        let Json::Object(p) = p else {
            return Err(format!("paragraph {index} is {}, and a paragraph is an object", kind_name(p)));
        };
        let mut attrs = BTreeMap::new();
        let mut spans = Vec::new();
        for (key, v) in p {
            if key == "spans" {
                let Json::Array(items) = v else {
                    return Err(format!("paragraph {index}'s spans is {}, and it is a list", kind_name(v)));
                };
                for item in items {
                    let Json::Array(pair) = item else {
                        return Err(format!("a span of paragraph {index} is {}, and a span is [text] or [text, marks]", kind_name(item)));
                    };
                    let (Some(Json::String(piece)), 1..=2) = (pair.first(), pair.len()) else {
                        return Err(format!("a span of paragraph {index} is not [text] or [text, marks]"));
                    };
                    if piece.contains('\n') || piece.contains('\r') {
                        return Err(format!("a span of paragraph {index} holds a line break, and a paragraph is one line"));
                    }
                    let mut marks = BTreeMap::new();
                    if let Some(m) = pair.get(1) {
                        let Json::Object(m) = m else {
                            return Err(format!("a span of paragraph {index} has marks that are {}, not an object", kind_name(m)));
                        };
                        for (name, value) in m {
                            let known = crate::wire::RICH_ATTRS.iter().any(|(_, n)| *n == name.as_str()) && !is_paragraph_attr(name);
                            if !known && !is_extension(name) {
                                lacks.push(format!("it carries the mark {name:?}"));
                                continue;
                            }
                            if let Some(value) = mark_from(name, value, index)? {
                                marks.insert(name.clone(), value);
                            }
                        }
                    }
                    if !piece.is_empty() {
                        spans.push((piece.clone(), marks));
                    }
                }
            } else if is_paragraph_attr(key) {
                if let Some(value) = paragraph_value(key, v, index)? {
                    attrs.insert(key.clone(), value);
                }
            } else {
                let name = format!("{PARA_PREFIX}{key}");
                if is_para_key(&name) {
                    attrs.insert(name, kept_value(v));
                } else {
                    lacks.push(format!("it carries the paragraph key {key:?}"));
                }
            }
        }
        if let Some(why) = super::scope_refusal(index, &attrs) {
            return Err(why);
        }
        paras.push(ParaIn { attrs, spans });
    }
    if paras.is_empty() {
        paras.push(ParaIn { attrs: BTreeMap::new(), spans: Vec::new() });
    }
    let (text, runs) = assemble(&paras);
    lacks.dedup();
    let read_only = (!lacks.is_empty()).then(|| {
        format!("this kaya cannot keep everything in the document through an edit: {}", lacks.join("; "))
    });
    Ok(Read { text, runs, extra, read_only })
}

/// The text and runs, newlines carried the canonical way (§11): an empty
/// paragraph's attributes on its terminator; a newline between two paragraphs
/// carries a paragraph attribute both hold, or the empty final paragraph's,
/// and an inline mark the bytes on both sides of it hold.
fn assemble(paras: &[ParaIn]) -> (String, Vec<TextRun>) {
    let mut text = String::new();
    let mut runs: Vec<TextRun> = Vec::new();
    let mut bounds: Vec<(usize, usize)> = Vec::new();
    for (i, para) in paras.iter().enumerate() {
        let start = text.len();
        for (piece, marks) in &para.spans {
            let at = text.len();
            text.push_str(piece);
            for (name, value) in marks {
                runs.push(TextRun::new(at as u64, text.len() as u64, name, value));
            }
        }
        let end = text.len();
        bounds.push((start, end));
        if start < end {
            for (name, value) in &para.attrs {
                runs.push(TextRun::new(start as u64, end as u64, name, value));
            }
        }
        if i + 1 < paras.len() {
            text.push('\n');
        }
    }
    let last = paras.len() - 1;
    for i in 0..last {
        let newline = bounds[i].1 as u64;
        let (p, q) = (&paras[i], &paras[i + 1]);
        let p_empty = bounds[i].0 == bounds[i].1;
        let q_final_empty = i + 1 == last && bounds[last].0 == bounds[last].1;
        let carried: BTreeMap<&String, &String> = if p_empty {
            p.attrs.iter().collect()
        } else if q_final_empty {
            q.attrs.iter().collect()
        } else {
            q.attrs.iter().filter(|(n, v)| p.attrs.get(*n) == Some(*v)).collect()
        };
        for (name, value) in carried {
            runs.push(TextRun::new(newline, newline + 1, name, value));
        }
        if let (Some((_, before)), Some((_, after))) = (p.spans.last(), q.spans.first()) {
            for (name, value) in before {
                if after.get(name) == Some(value) {
                    runs.push(TextRun::new(newline, newline + 1, name, value));
                }
            }
        }
    }
    (text, normalize_runs(runs))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(start: u64, end: u64, name: &str, value: &str) -> TextRun {
        TextRun::new(start, end, name, value)
    }

    fn spelled(runs: &[TextRun]) -> String {
        runs.iter().map(|r| format!("{}:{} {}={}", r.range.start, r.range.end, r.name, r.value)).collect::<Vec<_>>().join("|")
    }

    #[test]
    fn every_attribute_round_trips() {
        let text = "Notes\nA walk has no plan.\nmap\nwater, more\nread\nend";
        let runs = normalize_runs(vec![
            run(0, 5, "block", "heading1"),
            run(8, 12, "italic", "true"),
            run(13, 17, "bold", "true"),
            run(16, 20, "underline", "true"),
            run(6, 25, "align", "center"),
            run(26, 41, "list", "bullet"),
            run(30, 41, "indent", "1"),
            run(37, 41, "color", "#C4554D"),
            run(42, 46, "list", "check"),
            run(42, 46, "checked", "true"),
            run(47, 50, "strike", "true"),
            run(47, 50, "code", "true"),
            run(47, 50, "link", "https://kaya.dev/a?b=\"c\""),
            run(48, 50, "com.example.comment", "{\"id\":7}"),
        ]);
        let file = write(text, &runs, "").expect("writes");
        let back = read(file.as_bytes()).expect("reads");
        assert_eq!(back.read_only, None);
        assert_eq!(back.text, text);
        assert_eq!(spelled(&back.runs), spelled(&runs), "file:\n{file}");
        assert_eq!(write(&back.text, &back.runs, "").unwrap(), file);
    }

    #[test]
    fn the_plan_example_reads_and_writes_the_same_bytes() {
        let file = "{\n  \"kaya\": \"document\",\n  \"version\": 1,\n  \"requires\": [],\n  \"paragraphs\": [\n    {\"block\": \"heading1\", \"spans\": [[\"Notes on walking\"]]},\n    {\"spans\": [[\"A good walk has \"], [\"no plan\", {\"italic\": true}], [\" beyond the first turning.\"]]},\n    {\"list\": \"bullet\", \"spans\": [[\"a map you can fold with one hand\"]]},\n    {\"list\": \"bullet\", \"indent\": 1, \"spans\": [[\"water, and \"], [\"more\", {\"color\": \"#C4554D\"}], [\" than you think\"]]},\n    {\"list\": \"check\", \"checked\": true, \"spans\": [[\"something to read\"]]}\n  ]\n}\n";
        let back = read(file.as_bytes()).expect("reads");
        assert_eq!(back.read_only, None);
        assert_eq!(write(&back.text, &back.runs, "").unwrap(), file);
        assert!(spelled(&back.runs).contains("list=bullet"));
    }

    #[test]
    fn empty_paragraphs_keep_their_attributes() {
        let text = "a\n\nb\n";
        let runs = normalize_runs(vec![run(0, 5, "list", "bullet"), run(2, 3, "indent", "1")]);
        let file = write(text, &runs, "").unwrap();
        assert!(file.contains("{\"list\": \"bullet\", \"indent\": 1, \"spans\": []}"), "{file}");
        let back = read(file.as_bytes()).unwrap();
        assert_eq!(back.text, text);
        assert_eq!(spelled(&back.runs), spelled(&runs));
    }

    #[test]
    fn a_newer_major_version_is_refused_naming_both() {
        let why = read(br#"{"kaya": "document", "version": 2, "paragraphs": []}"#).unwrap_err();
        assert_eq!(why, "the document is version 2, newer than the version 1 this kaya reads");
        assert!(read(b"[1]").unwrap_err().contains("is an array"));
        assert!(read(br#"{"version": 1}"#).unwrap_err().contains("not a kaya document"));
    }

    #[test]
    fn a_required_name_opens_read_only_naming_it() {
        let got = read(br#"{"kaya": "document", "version": 1, "requires": ["com.example.comments"], "paragraphs": [{"spans": [["hi"]]}]}"#).unwrap();
        assert_eq!(got.text, "hi");
        assert!(got.read_only.unwrap().contains("it requires \"com.example.comments\""));
    }

    #[test]
    fn unknown_names_are_kept_or_named() {
        let got = read(br#"{"kaya": "document", "version": 1, "paragraphs": [{"spans": [["hi", {"com.example.note": "x", "bold": true}]]}]}"#).unwrap();
        assert_eq!(got.read_only, None);
        assert_eq!(spelled(&got.runs), "0:2 bold=true|0:2 com.example.note=x");
        let newer = read(br#"{"kaya": "document", "version": 1, "paragraphs": [{"spans": [["hi", {"highlight": "mint"}]]}]}"#).unwrap();
        assert!(newer.read_only.unwrap().contains("the mark \"highlight\""));
        let history = read(br#"{"kaya": "document", "version": 1, "history": "AAAA", "paragraphs": [{"spans": []}]}"#).unwrap();
        assert_eq!((history.read_only, history.extra.as_str()), (None, ""));
        let stray = read(br#"{"kaya": "document", "version": 1, "paragraphs": [{"spans": [["hi", {"para:x.y": true}]]}]}"#).unwrap();
        assert!(stray.read_only.unwrap().contains("the mark \"para:x.y\""), "a para: name is never a mark");
    }

    /// RD17 A: paragraph keys ride para: runs and the top level's unknown
    /// members ride extra, so the file is editable and writes them back.
    #[test]
    fn unknown_paragraph_and_document_keys_are_kept() {
        let file = "{\n  \"kaya\": \"document\",\n  \"version\": 1,\n  \"requires\": [],\n  \"com.example.theme\": {\"page\":\"sepia\"},\n  \"embeds\": [],\n  \"paragraphs\": [\n    {\"list\": \"bullet\", \"com.example.pinned\": true, \"embed\": \"e1\", \"spans\": [[\"a\"]]},\n    {\"com.example.n\": \"7\", \"com.example.s\": \"x\", \"spans\": []},\n    {\"spans\": [[\"b\"]]}\n  ]\n}\n";
        let got = read(file.as_bytes()).unwrap();
        assert_eq!(got.read_only, None);
        assert_eq!(got.extra, r#"{"com.example.theme":{"page":"sepia"},"embeds":[]}"#);
        assert_eq!(
            spelled(&got.runs),
            "0:1 list=bullet|0:1 para:com.example.pinned=true|0:1 para:embed=e1|2:3 para:com.example.n=\"7\"|2:3 para:com.example.s=x"
        );
        assert_eq!(write(&got.text, &got.runs, &got.extra).unwrap(), file);
        assert!(write("a", &[], r#"{"version": 2}"#).unwrap_err().contains("spells for kaya itself"));
        assert!(write("a", &[], "[1]").unwrap_err().contains("JSON object's text"));
        assert!(write("ab\nc", &[run(1, 4, "para:com.example.pinned", "true")], "").unwrap_err().contains("does not cover paragraph 0"));
        assert!(write("a", &[run(0, 1, "para:list", "bullet")], "").unwrap_err().contains("para: paragraph key"));
    }

    #[test]
    fn a_malformed_document_is_refused_in_one_sentence() {
        assert!(read(br#"{"kaya": "document", "version": 1, "paragraphs": [{"block": "heading1", "list": "bullet", "spans": []}]}"#)
            .unwrap_err()
            .contains("a heading1 and a list item"));
        assert!(read(br#"{"kaya": "document", "version": 1, "paragraphs": [{"spans": [["a\nb"]]}]}"#).unwrap_err().contains("line break"));
        assert!(read(br#"{"kaya": "document", "version": 1, "paragraphs": [{"indent": 9, "spans": []}]}"#).unwrap_err().contains("not an indent"));
        assert!(write("ab", &[run(0, 1, "list", "bullet")], "").unwrap_err().contains("does not cover paragraph 0"));
        assert!(write("ab", &[run(0, 2, "color", "#abcdef")], "").unwrap_err().contains("#ABCDEF"));
    }
}
