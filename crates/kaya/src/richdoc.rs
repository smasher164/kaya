//! The rich document's model beyond the textarea's runs
//! (docs/rich-document-plan.md §2 and §11): the paragraph attributes and
//! their scope, each mark's expand rule, the derived list markers, the
//! colour value, the `.kdoc` codec and the clipboard's RTF and HTML.

use std::collections::BTreeMap;

use crate::protocol::TextRun;

pub(crate) mod clip;
pub(crate) mod kdoc;

/// The attributes that cover whole paragraphs (RD1).
pub(crate) const PARAGRAPH_ATTRS: &[&str] = &["block", "list", "indent", "checked", "start", "align"];

/// A paragraph key this kaya does not know, kept as a run (RD17 A).
pub(crate) const PARA_PREFIX: &str = "para:";

pub(crate) fn is_para_key(name: &str) -> bool {
    name.strip_prefix(PARA_PREFIX).is_some_and(|key| !key.is_empty() && key != "spans" && !PARAGRAPH_ATTRS.contains(&key))
}

pub(crate) fn is_paragraph_attr(name: &str) -> bool {
    PARAGRAPH_ATTRS.contains(&name) || is_para_key(name)
}

/// An app's own name (RD8): a reverse-DNS prefix, kept and drawn as nothing.
pub(crate) fn is_extension(name: &str) -> bool {
    name.contains('.') && !name.starts_with(PARA_PREFIX)
}

/// A name outside kaya's vocabulary that every reader keeps: an app's dotted
/// mark or a paragraph key under the reserved prefix.
pub(crate) fn is_kept_name(name: &str) -> bool {
    is_extension(name) || is_para_key(name)
}

/// The paragraph attributes `runs` can hold: kaya's own, then every kept
/// paragraph key among them, by name.
pub(crate) fn paragraph_names(runs: &[TextRun]) -> Vec<String> {
    let mut out: Vec<String> = PARAGRAPH_ATTRS.iter().map(|n| (*n).to_owned()).collect();
    let keys: std::collections::BTreeSet<&str> = runs.iter().map(|r| r.name.as_str()).filter(|n| is_para_key(n)).collect();
    out.extend(keys.into_iter().map(str::to_owned));
    out
}

/// RD7's table: the marks that grow over text typed at their end.
pub(crate) fn expands_at_end(name: &str) -> bool {
    matches!(name, "bold" | "italic" | "underline" | "strike" | "color")
}

/// The Format menu's eight colours (docs/rich-document-plan.md §11): each
/// reads at 4.5:1 on the light page and, through brand::ink_for_dark, on
/// the dark one (brand.rs's test holds both).
pub(crate) const COLOR_PRESETS: &[(&str, u32)] = &[
    ("red", 0xDD1F24),
    ("orange", 0xBA5600),
    ("brown", 0x976814),
    ("green", 0x0D8501),
    ("teal", 0x097E7E),
    ("blue", 0x016FEF),
    ("purple", 0x8F4BE4),
    ("pink", 0xD12387),
];

pub(crate) const MAX_INDENT: u32 = 8;

/// A value's canonical spelling, or why it is refused. A removal spelling
/// (`body`, `none`, `0`, `start`) answers None.
pub(crate) fn canonical_value(name: &str, value: &str) -> Result<Option<String>, String> {
    let one_of = |table: &[(i64, &str)], none: &str| -> Result<Option<String>, String> {
        if value == none {
            return Ok(None);
        }
        if table.iter().any(|(_, n)| *n == value) {
            Ok(Some(value.to_owned()))
        } else {
            let noun = match name {
                "block" => "block kind",
                "list" => "list kind",
                _ => "paragraph alignment",
            };
            Err(format!(
                "{value:?} is not a {noun} — the vocabulary is {}",
                table.iter().map(|(_, n)| *n).collect::<Vec<_>>().join(", ")
            ))
        }
    };
    match name {
        "block" => one_of(crate::wire::BLOCK_KINDS, "body"),
        "list" => one_of(crate::wire::LIST_KINDS, "none"),
        "align" => one_of(crate::wire::PARAGRAPH_ALIGNS, "start"),
        "indent" => match value.parse::<u32>() {
            Ok(0) => Ok(None),
            Ok(n) if n <= MAX_INDENT && value == n.to_string() => Ok(Some(value.to_owned())),
            _ => Err(format!("{value:?} is not an indent — a level is a whole number from 0 to {MAX_INDENT}")),
        },
        "start" => match value.parse::<u64>() {
            Ok(n) if n >= 1 && value == n.to_string() => Ok(Some(value.to_owned())),
            _ => Err(format!("{value:?} is not a list start — it is a whole number from 1")),
        },
        "checked" => {
            if value == crate::protocol::FLAG_VALUE {
                Ok(Some(value.to_owned()))
            } else {
                Err(format!("{value:?} is not a checked value — a checked item is `true`, and unchecked is no run"))
            }
        }
        "color" => parse_color(value).map(|rgb| Some(format!("#{rgb:06X}"))),
        "link" if value.is_empty() => Err("a link names its URL, and this one is empty".to_owned()),
        _ => Ok(Some(value.to_owned())),
    }
}

/// `#RRGGBB`, either case; alpha is refused by name (§5: translucent text has
/// no reading anyone designs for).
pub(crate) fn parse_color(value: &str) -> Result<u32, String> {
    let hex = value.strip_prefix('#').unwrap_or("");
    let digits = hex.chars().all(|c| c.is_ascii_hexdigit());
    if digits && hex.len() == 8 {
        return Err(format!(
            "{value:?} carries alpha {} — a document colour is opaque #RRGGBB",
            &hex[6..]
        ));
    }
    if !(digits && hex.len() == 6) {
        return Err(format!("{value:?} is not a colour — a document colour is #RRGGBB in sRGB"));
    }
    Ok(u32::from_str_radix(hex, 16).expect("six hex digits"))
}

/// One paragraph: its text bytes `start..end` and its terminator, the newline
/// at `end`, when it has one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Para {
    pub start: usize,
    pub end: usize,
    pub terminated: bool,
}

impl Para {
    pub(crate) fn is_empty(&self) -> bool {
        self.start == self.end
    }

    /// The bytes that carry this paragraph's attributes: its text, or its
    /// terminator when it is empty; none for the empty final paragraph.
    pub(crate) fn carrier(&self) -> Option<(usize, usize)> {
        if !self.is_empty() {
            Some((self.start, self.end))
        } else if self.terminated {
            Some((self.start, self.start + 1))
        } else {
            None
        }
    }
}

pub(crate) fn paragraphs(text: &str) -> Vec<Para> {
    let mut out = Vec::new();
    let mut start = 0;
    for (i, b) in text.bytes().enumerate() {
        if b == b'\n' {
            out.push(Para { start, end: i, terminated: true });
            start = i + 1;
        }
    }
    out.push(Para { start, end: text.len(), terminated: false });
    out
}

/// The paragraph `byte` lies in; a byte on a newline is its paragraph's end.
pub(crate) fn para_index(paras: &[Para], byte: usize) -> usize {
    paras.iter().position(|p| byte <= p.end).unwrap_or(paras.len() - 1)
}

pub(crate) fn attrs_at(runs: &[TextRun], byte: usize) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    for run in runs {
        if (run.range.start as usize) <= byte && byte < run.range.end as usize {
            out.insert(run.name.clone(), run.value.clone());
        }
    }
    out
}

/// The paragraph attributes a paragraph holds: from its carrier's first byte,
/// or `final_state` for the empty final paragraph.
pub(crate) fn para_attrs(
    runs: &[TextRun],
    para: &Para,
    final_state: &BTreeMap<String, String>,
) -> BTreeMap<String, String> {
    match para.carrier() {
        Some((start, _)) => attrs_at(runs, start).into_iter().filter(|(n, _)| is_paragraph_attr(n)).collect(),
        None => final_state.iter().filter(|(n, _)| is_paragraph_attr(n)).map(|(n, v)| (n.clone(), v.clone())).collect(),
    }
}

/// What a new paragraph made by Return at a paragraph's END keeps of the one
/// before (R10 generalized): a heading ends, an item's check and start do not
/// carry, the rest continues.
pub(crate) fn continuing(attrs: &BTreeMap<String, String>) -> BTreeMap<String, String> {
    attrs
        .iter()
        .filter(|(n, v)| match n.as_str() {
            "block" => !v.starts_with("heading"),
            "checked" | "start" => false,
            _ => true,
        })
        .map(|(n, v)| (n.clone(), v.clone()))
        .collect()
}

/// The empty final paragraph's attributes when the text ends in a newline:
/// the paragraph attributes that newline carries (§11; Return wrote what
/// continues onto it, so it is the final paragraph's carrier).
pub(crate) fn final_state(text: &str, runs: &[TextRun]) -> BTreeMap<String, String> {
    if !text.ends_with('\n') {
        return BTreeMap::new();
    }
    attrs_at(runs, text.len() - 1).into_iter().filter(|(n, _)| is_paragraph_attr(n)).collect()
}

/// Per attribute: disjoint, sorted, never adjacent-and-equal, a later run
/// winning over an earlier one; by start, then name (scene.rs's mirror form).
pub(crate) fn normalize_runs(runs: Vec<TextRun>) -> Vec<TextRun> {
    let names: std::collections::BTreeSet<String> = runs.iter().map(|r| r.name.clone()).collect();
    let mut out: Vec<TextRun> = Vec::new();
    for name in names {
        let mut painted: Vec<TextRun> = Vec::new();
        for run in runs.iter().filter(|r| r.name == name) {
            if run.range.start >= run.range.end {
                continue;
            }
            let mut kept: Vec<TextRun> = Vec::new();
            for old in painted.drain(..) {
                if old.range.end <= run.range.start || old.range.start >= run.range.end {
                    kept.push(old);
                    continue;
                }
                if old.range.start < run.range.start {
                    kept.push(TextRun { range: old.range.start..run.range.start, ..old.clone() });
                }
                if old.range.end > run.range.end {
                    kept.push(TextRun { range: run.range.end..old.range.end, ..old.clone() });
                }
            }
            kept.push(run.clone());
            painted = kept;
        }
        painted.sort_by_key(|r| r.range.start);
        let mut merged: Vec<TextRun> = Vec::new();
        for run in painted {
            match merged.last_mut() {
                Some(last) if last.range.end == run.range.start && last.value == run.value => {
                    last.range.end = run.range.end;
                }
                _ => merged.push(run),
            }
        }
        out.extend(merged);
    }
    out.sort_by(|a, b| (a.range.start, &a.name).cmp(&(b.range.start, &b.name)));
    out
}

/// RD2's scope: a list only on a body or quote paragraph, `checked` only on a
/// checklist item, `start` only on a numbered one. Why, naming the paragraph.
pub(crate) fn scope_refusal(index: usize, attrs: &BTreeMap<String, String>) -> Option<String> {
    let block = attrs.get("block").map(String::as_str).unwrap_or("body");
    let list = attrs.get("list").map(String::as_str);
    if list.is_some() && !matches!(block, "body" | "quote") {
        return Some(format!(
            "paragraph {index} is a {block} and a list item — a list item is a body or quote \
             paragraph, so take the block off or the list"
        ));
    }
    if attrs.contains_key("checked") && list != Some("check") {
        return Some(format!(
            "paragraph {index} is checked but is not a checklist item (list={})",
            list.unwrap_or("none")
        ));
    }
    if attrs.contains_key("start") && list != Some("numbered") {
        return Some(format!(
            "paragraph {index} carries a list start but is not a numbered item (list={})",
            list.unwrap_or("none")
        ));
    }
    None
}

/// The first paragraph-attribute run that does not cover whole paragraphs, or
/// one paragraph whose attributes break RD2's scope.
pub(crate) fn structure_refusal(
    text: &str,
    runs: &[TextRun],
    final_state: &BTreeMap<String, String>,
) -> Option<String> {
    let paras = paragraphs(text);
    let names = paragraph_names(runs);
    for (i, para) in paras.iter().enumerate() {
        if let Some((start, end)) = para.carrier() {
            for name in &names {
                let first = runs
                    .iter()
                    .find(|r| r.name == *name && r.range.start as usize <= start && start < r.range.end as usize)
                    .map(|r| r.value.as_str());
                let uniform = runs.iter().filter(|r| r.name == *name).all(|r| {
                    let (a, b) = (r.range.start as usize, r.range.end as usize);
                    let overlaps = a < end && b > start;
                    !overlaps || (Some(r.value.as_str()) == first && a <= start && b >= end)
                });
                if !uniform {
                    return Some(format!(
                        "the {name} attribute does not cover paragraph {i} (bytes {start}..{end}) whole — \
                         a paragraph attribute covers whole paragraphs"
                    ));
                }
            }
        }
        if let Some(sentence) = scope_refusal(i, &para_attrs(runs, para, final_state)) {
            return Some(sentence);
        }
    }
    None
}

/// One drawn list marker (§2's Numbering): the paragraph's first byte, its
/// level, and the marker: a bullet, a number, or `[ ]`/`[x]` for a
/// checklist item, which the platform draws as its own box.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Marker {
    pub start: u64,
    pub level: u32,
    pub text: String,
}

const BULLETS: [&str; 3] = ["\u{2022}", "\u{25E6}", "\u{25AA}"];

fn letters(mut n: u64) -> String {
    let mut out = Vec::new();
    while n > 0 {
        n -= 1;
        out.push(b'a' + (n % 26) as u8);
        n /= 26;
    }
    out.reverse();
    String::from_utf8(out).expect("ascii")
}

fn roman(mut n: u64) -> String {
    const TABLE: [(u64, &str); 13] = [
        (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
        (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
    ];
    let mut out = String::new();
    for (value, digits) in TABLE {
        while n >= value {
            out.push_str(digits);
            n -= value;
        }
    }
    out
}

/// The number marker of `n` at `level`: `1.`, `a.`, `i.` and round again.
pub(crate) fn number_marker(n: u64, level: u32) -> String {
    match level % 3 {
        0 => format!("{n}."),
        1 => format!("{}.", letters(n)),
        _ => format!("{}.", roman(n)),
    }
}

/// Every list item's marker, in paragraph order: a numbered item is one more
/// than the previous numbered item at its level in the same unbroken run of
/// list paragraphs, or its `start`; a paragraph that is not a list item ends
/// every run, and an item at a shallower level ends the deeper counts.
pub(crate) fn markers(text: &str, runs: &[TextRun], final_state: &BTreeMap<String, String>) -> Vec<Marker> {
    let mut out = Vec::new();
    let mut counts = [0u64; (MAX_INDENT + 1) as usize];
    for para in paragraphs(text) {
        let attrs = para_attrs(runs, &para, final_state);
        let Some(kind) = attrs.get("list") else {
            counts = [0; (MAX_INDENT + 1) as usize];
            continue;
        };
        let level = attrs.get("indent").and_then(|v| v.parse::<u32>().ok()).unwrap_or(0).min(MAX_INDENT);
        for deeper in counts.iter_mut().skip(level as usize + 1) {
            *deeper = 0;
        }
        let text = match kind.as_str() {
            "numbered" => {
                let n = match attrs.get("start").and_then(|v| v.parse::<u64>().ok()) {
                    Some(start) => start,
                    None => counts[level as usize] + 1,
                };
                counts[level as usize] = n;
                number_marker(n, level)
            }
            "check" => if attrs.contains_key("checked") { "[x]" } else { "[ ]" }.to_owned(),
            _ => BULLETS[(level % 3) as usize].to_owned(),
        };
        out.push(Marker { start: para.start as u64, level, text });
    }
    out
}

/// What assistive technology is told of each list item beyond its text
/// (docs/rich-document-plan.md RD18): the marker (`bullet`, the number as
/// drawn, `checked` or `not checked`), its place among its siblings, and its
/// level past the first. Siblings are the items of one kind at one level in
/// one unbroken run of list paragraphs; a deeper item does not part them, a
/// shallower one or another kind at their level does.
pub(crate) fn item_speech(text: &str, runs: &[TextRun], final_state: &BTreeMap<String, String>) -> Vec<(u64, String)> {
    item_places(text, runs, final_state).into_iter().map(|p| (p.start, p.said)).collect()
}

/// One list item's account for assistive technology: `said` is
/// [`item_speech`]'s string; `position` and `size` its place among its
/// siblings and `level` its depth, all from 1 (RD19's WinUI properties).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ItemPlace {
    pub start: u64,
    pub said: String,
    pub position: usize,
    pub size: usize,
    pub level: u32,
}

pub(crate) fn item_places(text: &str, runs: &[TextRun], final_state: &BTreeMap<String, String>) -> Vec<ItemPlace> {
    let mut items: Vec<(Marker, usize)> = Vec::new();
    let mut run = 0usize;
    let all = markers(text, runs, final_state);
    let mut next = all.iter().peekable();
    for para in paragraphs(text) {
        match next.peek() {
            Some(m) if m.start == para.start as u64 => items.push(((*next.next().expect("peeked")).clone(), run)),
            _ => run += 1,
        }
    }
    let kind = |m: &Marker| match m.text.as_str() {
        "[ ]" | "[x]" => 0,
        t if BULLETS.contains(&t) => 1,
        _ => 2,
    };
    let siblings = |i: usize, step: isize| -> usize {
        let (me, my_run) = (&items[i].0, items[i].1);
        let mut count = 0;
        let mut j = i as isize + step;
        while j >= 0 && (j as usize) < items.len() {
            let (other, other_run) = (&items[j as usize].0, items[j as usize].1);
            if other_run != my_run || other.level < me.level {
                break;
            }
            if other.level == me.level {
                if kind(other) != kind(me) {
                    break;
                }
                count += 1;
            }
            j += step;
        }
        count
    };
    (0..items.len())
        .map(|i| {
            let m = &items[i].0;
            let (before, after) = (siblings(i, -1), siblings(i, 1));
            let word = match m.text.as_str() {
                "[x]" => "checked",
                "[ ]" => "not checked",
                t if BULLETS.contains(&t) => "bullet",
                t => t,
            };
            let (position, size) = (before + 1, before + after + 1);
            let mut said = format!("{word}, {position} of {size}");
            if m.level > 0 {
                said.push_str(&format!(", level {}", m.level + 1));
            }
            ItemPlace { start: m.start, said, position, size, level: m.level + 1 }
        })
        .collect()
}

/// `expect_markers`' spelling: `start:level marker`, `|`-joined.
pub(crate) fn spell_markers(markers: &[Marker]) -> String {
    markers
        .iter()
        .map(|m| format!("{}:{} {}", m.start, m.level, m.text))
        .collect::<Vec<_>>()
        .join("|")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(start: u64, end: u64, name: &str, value: &str) -> TextRun {
        TextRun::new(start, end, name, value)
    }

    #[test]
    fn numbering_counts_per_level_and_restarts_after_a_body_paragraph() {
        let text = "a\nb\nc\nd\ne\nf\ng\nh";
        let runs = vec![
            run(0, 9, "list", "numbered"),
            run(4, 7, "indent", "1"),
            run(12, 13, "list", "numbered"),
            run(14, 15, "list", "bullet"),
            run(14, 15, "indent", "2"),
        ];
        let got = spell_markers(&markers(text, &runs, &BTreeMap::new()));
        assert_eq!(got, "0:0 1.|2:0 2.|4:1 a.|6:1 b.|8:0 3.|12:0 1.|14:2 \u{25AA}");
    }

    #[test]
    fn each_item_is_told_its_marker_place_and_level() {
        let text = "a\nb\nc\nd\ne\nf\ng\nplain\nh";
        let runs = vec![
            run(0, 5, "list", "bullet"),
            run(2, 3, "indent", "1"),
            run(6, 9, "list", "numbered"),
            run(10, 13, "list", "check"),
            run(10, 11, "checked", "true"),
            run(20, 21, "list", "bullet"),
        ];
        let got: Vec<String> = item_speech(text, &runs, &BTreeMap::new()).into_iter().map(|(s, t)| format!("{s}:{t}")).collect();
        assert_eq!(
            got,
            [
                "0:bullet, 1 of 2",
                "2:bullet, 1 of 1, level 2",
                "4:bullet, 2 of 2",
                "6:1., 1 of 2",
                "8:2., 2 of 2",
                "10:checked, 1 of 2",
                "12:not checked, 2 of 2",
                "20:bullet, 1 of 1",
            ]
        );
    }

    /// RD19's WinUI properties: the same places as numbers, from 1.
    #[test]
    fn each_item_place_carries_its_position_size_and_level() {
        let text = "a\nb\nc";
        let runs = vec![run(0, 5, "list", "bullet"), run(2, 3, "indent", "1")];
        let got: Vec<(u64, usize, usize, u32)> =
            item_places(text, &runs, &BTreeMap::new()).into_iter().map(|p| (p.start, p.position, p.size, p.level)).collect();
        assert_eq!(got, [(0, 1, 2, 1), (2, 1, 1, 2), (4, 2, 2, 1)]);
    }

    #[test]
    fn a_start_sets_the_count_and_the_next_item_follows_it() {
        let text = "a\nb";
        let runs = vec![run(0, 3, "list", "numbered"), run(0, 1, "start", "7")];
        assert_eq!(spell_markers(&markers(text, &runs, &BTreeMap::new())), "0:0 7.|2:0 8.");
    }

    #[test]
    fn markers_read_the_final_empty_paragraph_from_its_state() {
        let text = "a\n";
        let runs = vec![run(0, 2, "list", "check"), run(0, 1, "checked", "true")];
        let state: BTreeMap<String, String> = [("list".to_owned(), "check".to_owned())].into();
        assert_eq!(spell_markers(&markers(text, &runs, &state)), "0:0 [x]|2:0 [ ]");
        assert_eq!(number_marker(28, 1), "ab.");
        assert_eq!(number_marker(14, 2), "xiv.");
    }

    #[test]
    fn scope_refuses_a_listed_heading_and_a_stray_check() {
        let state = BTreeMap::new();
        let text = "a\nb";
        let heading = vec![run(0, 1, "block", "heading1"), run(0, 1, "list", "bullet")];
        assert!(structure_refusal(text, &heading, &state).unwrap().contains("a heading1 and a list item"));
        let stray = vec![run(2, 3, "list", "bullet"), run(2, 3, "checked", "true")];
        assert!(structure_refusal(text, &stray, &state).unwrap().contains("is checked but"));
        let partial = vec![run(0, 1, "list", "bullet"), run(2, 3, "indent", "1"), run(0, 2, "align", "center")];
        assert_eq!(structure_refusal(text, &partial, &state), None);
        let cut = vec![run(1, 4, "list", "bullet")];
        assert!(structure_refusal("ab\nc", &cut, &state).unwrap().contains("list attribute does not cover paragraph 0"));
    }

    #[test]
    fn values_have_one_spelling() {
        assert_eq!(canonical_value("color", "#c4554d"), Ok(Some("#C4554D".to_owned())));
        assert!(canonical_value("color", "#C4554D80").unwrap_err().contains("carries alpha 80"));
        assert_eq!(canonical_value("indent", "0"), Ok(None));
        assert!(canonical_value("indent", "9").is_err());
        assert!(canonical_value("indent", "01").is_err());
        assert_eq!(canonical_value("list", "none"), Ok(None));
        assert!(canonical_value("list", "dash").unwrap_err().contains("bullet, numbered, check"));
        assert!(canonical_value("start", "0").is_err());
        assert_eq!(canonical_value("align", "start"), Ok(None));
        assert_eq!(canonical_value("com.example.note", "x"), Ok(Some("x".to_owned())));
    }
}
