//! The clipboard's rich flavours (docs/rich-document-plan.md §7, RD12 as
//! amended): RTF and HTML written from a document, and one normaliser that
//! reads either back into kaya's vocabulary and drops everything else.

use std::collections::BTreeMap;

use super::{final_state, is_paragraph_attr, normalize_runs, para_attrs, paragraphs};
use crate::protocol::TextRun;

/// A copied range as its own document: the text and the runs clipped to it.
pub(crate) fn slice(text: &str, runs: &[TextRun], start: usize, end: usize) -> (String, Vec<TextRun>) {
    let piece = text[start..end].to_owned();
    let runs = runs
        .iter()
        .filter_map(|r| {
            let a = (r.range.start as usize).max(start);
            let b = (r.range.end as usize).min(end);
            (a < b).then(|| TextRun::new((a - start) as u64, (b - start) as u64, &r.name, &r.value))
        })
        .collect();
    (piece, normalize_runs(runs))
}

const TWIPS_PER_LEVEL: u32 = 720;

fn heading_size(block: &str) -> Option<u32> {
    match block {
        "heading1" => Some(38),
        "heading2" => Some(32),
        "heading3" => Some(28),
        _ => None,
    }
}

fn rtf_text(out: &mut String, s: &str) {
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '{' => out.push_str("\\{"),
            '}' => out.push_str("\\}"),
            '\t' => out.push_str("\\tab "),
            c if (' '..='~').contains(&c) => out.push(c),
            c => {
                let mut units = [0u16; 2];
                for unit in c.encode_utf16(&mut units) {
                    out.push_str(&format!("\\u{}?", *unit as i16));
                }
            }
        }
    }
}

const BULLET_LEVELS: [u32; 3] = [8226, 9702, 9642];
const BOX: u32 = 9744;
const BOX_CHECKED: u32 = 9745;

fn rtf_list_table(out: &mut String) {
    out.push_str("{\\*\\listtable");
    for (id, kind) in [(1, "bullet"), (2, "numbered"), (3, "check")] {
        out.push_str(&format!("{{\\list\\listtemplateid{id}\\listhybrid"));
        for level in 0..9u32 {
            let li = TWIPS_PER_LEVEL * (level + 1);
            let (nfc, text, numbers) = match kind {
                "numbered" => {
                    let nfc = [0, 4, 2][(level % 3) as usize];
                    (nfc, format!("\\'02\\'0{level}.;"), "\\'01;".to_owned())
                }
                "check" => (23, format!("\\'01\\uc0\\u{BOX} ;"), String::new()),
                _ => (23, format!("\\'01\\uc0\\u{} ;", BULLET_LEVELS[(level % 3) as usize]), String::new()),
            };
            out.push_str(&format!(
                "{{\\listlevel\\levelnfc{nfc}\\levelnfcn{nfc}\\leveljc0\\leveljcn0\\levelfollow0\\levelstartat1\\levelspace360\\levelindent0{{\\leveltext {text}}}{{\\levelnumbers{numbers}}}\\fi-360\\li{li}\\lin{li} }}"
            ));
        }
        out.push_str(&format!("{{\\listname ;}}\\listid{id}}}"));
    }
    out.push_str("}\n{\\*\\listoverridetable");
    for id in 1..=3 {
        out.push_str(&format!("{{\\listoverride\\listid{id}\\listoverridecount0\\ls{id}}}"));
    }
    out.push_str("}\n");
}

/// The document as RTF 1.9: automatic ink is `\cf0`, colours a `\colortbl`,
/// lists `\listtable` with each item's `\listtext`, a link a HYPERLINK field.
/// A quote or code block rides a `{\*\kayablock}` group other readers skip.
pub(crate) fn rtf_write(text: &str, runs: &[TextRun]) -> String {
    let runs = normalize_runs(runs.to_vec());
    let state = final_state(text, &runs);
    let mut colors: Vec<u32> = Vec::new();
    for run in runs.iter().filter(|r| r.name == "color") {
        if let Ok(rgb) = super::parse_color(&run.value) {
            if !colors.contains(&rgb) {
                colors.push(rgb);
            }
        }
    }
    let mut out = String::from("{\\rtf1\\ansi\\ansicpg1252\\uc1\\deff0\n{\\fonttbl{\\f0\\fswiss\\fcharset0 Helvetica;}{\\f1\\fmodern\\fcharset0 Menlo;}}\n{\\colortbl;");
    for rgb in &colors {
        out.push_str(&format!("\\red{}\\green{}\\blue{};", rgb >> 16, (rgb >> 8) & 0xFF, rgb & 0xFF));
    }
    out.push_str("}\n");
    rtf_list_table(&mut out);
    let paras = paragraphs(text);
    let marks = super::markers(text, &runs, &state);
    for (i, para) in paras.iter().enumerate() {
        let attrs = para_attrs(&runs, para, &state);
        let block = attrs.get("block").map(String::as_str).unwrap_or("body");
        let level: u32 = attrs.get("indent").and_then(|v| v.parse().ok()).unwrap_or(0);
        out.push_str("\\pard");
        let list = attrs.get("list").map(String::as_str);
        match list {
            Some(kind) => {
                let ls = match kind { "numbered" => 2, "check" => 3, _ => 1 };
                let li = TWIPS_PER_LEVEL * (level + 1);
                out.push_str(&format!("\\li{li}\\fi-360\\ls{ls}\\ilvl{level}"));
            }
            None if block == "quote" => out.push_str(&format!("\\li{}", TWIPS_PER_LEVEL * (level + 1))),
            None if level > 0 => out.push_str(&format!("\\li{}", TWIPS_PER_LEVEL * level)),
            None => {}
        }
        match attrs.get("align").map(String::as_str) {
            Some("center") => out.push_str("\\qc"),
            Some("end") => out.push_str("\\qr"),
            Some("justify") => out.push_str("\\qj"),
            _ => {}
        }
        if let Some(n) = block.strip_prefix("heading") {
            let n: u32 = n.parse().unwrap_or(1);
            out.push_str(&format!("\\outlinelevel{}", n - 1));
        }
        out.push(' ');
        if matches!(block, "quote" | "code_block") {
            out.push_str(&format!("{{\\*\\kayablock {block}}}"));
        }
        if let Some(start) = attrs.get("start") {
            out.push_str(&format!("{{\\*\\kayastart {start}}}"));
        }
        if list.is_some() {
            let marker = marks.iter().find(|m| m.start as usize == para.start).map(|m| m.text.as_str()).unwrap_or("");
            let shown = match marker {
                "[x]" => char::from_u32(BOX_CHECKED).expect("box").to_string(),
                "[ ]" => char::from_u32(BOX).expect("box").to_string(),
                other => other.to_owned(),
            };
            out.push_str("{\\listtext\\tab ");
            rtf_text(&mut out, &shown);
            out.push_str("\\tab }");
        }
        for (piece, marks) in super::kdoc::spans_of(text, &runs, para.start, para.end) {
            let mut words = String::new();
            if let Some(size) = heading_size(block) {
                words.push_str(&format!("\\fs{size}\\b"));
            }
            if marks.contains_key("bold") {
                words.push_str("\\b");
            }
            if marks.contains_key("italic") {
                words.push_str("\\i");
            }
            if marks.contains_key("underline") {
                words.push_str("\\ul");
            }
            if marks.contains_key("strike") {
                words.push_str("\\strike");
            }
            if marks.contains_key("code") || block == "code_block" {
                words.push_str("\\f1");
            }
            if let Some(Ok(rgb)) = marks.get("color").map(|v| super::parse_color(v)) {
                let index = colors.iter().position(|c| *c == rgb).expect("collected") + 1;
                words.push_str(&format!("\\cf{index}"));
            }
            let mut group = if words.is_empty() { "{".to_owned() } else { format!("{{{words} ") };
            rtf_text(&mut group, &piece);
            group.push('}');
            match marks.get("link") {
                Some(url) => {
                    out.push_str("{\\field{\\*\\fldinst{HYPERLINK \"");
                    rtf_text(&mut out, &url.replace('"', "%22"));
                    out.push_str("\"}}{\\fldrslt ");
                    out.push_str(&group);
                    out.push_str("}}");
                }
                None => out.push_str(&group),
            }
        }
        if i + 1 < paras.len() {
            out.push_str("\\par\n");
        }
    }
    out.push_str("}\n");
    out
}

fn html_escape(out: &mut String, s: &str) {
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            c => out.push(c),
        }
    }
}

/// The document as an HTML fragment: headings, quotes, code blocks, nested
/// lists, a checklist item's box as a disabled checkbox, colour as a span.
pub(crate) fn html_write(text: &str, runs: &[TextRun]) -> String {
    let runs = normalize_runs(runs.to_vec());
    let state = final_state(text, &runs);
    let mut out = String::from("<meta charset=\"utf-8\">");
    let mut open_lists: Vec<&'static str> = Vec::new();
    let mut in_quote = false;
    for para in paragraphs(text) {
        let attrs = para_attrs(&runs, &para, &state);
        let block = attrs.get("block").map(String::as_str).unwrap_or("body");
        let level: usize = attrs.get("indent").and_then(|v| v.parse().ok()).unwrap_or(0);
        let list = attrs.get("list").map(String::as_str);
        let want: usize = if list.is_some() { level + 1 } else { 0 };
        while open_lists.len() > want {
            out.push_str(&format!("</{}>", open_lists.pop().expect("open")));
        }
        if let Some(kind) = list {
            let tag = if kind == "numbered" { "ol" } else { "ul" };
            if open_lists.len() == want && open_lists.last() != Some(&tag) {
                out.push_str(&format!("</{}>", open_lists.pop().expect("open")));
            }
            while open_lists.len() < want {
                if open_lists.len() + 1 == want && tag == "ol" {
                    match attrs.get("start") {
                        Some(start) => out.push_str(&format!("<ol start=\"{start}\">")),
                        None => out.push_str("<ol>"),
                    }
                } else if kind == "check" && open_lists.len() + 1 == want {
                    out.push_str("<ul style=\"list-style:none\">");
                } else {
                    out.push_str(&format!("<{tag}>"));
                }
                open_lists.push(tag);
            }
        }
        if (block == "quote") != in_quote && open_lists.is_empty() {
            out.push_str(if in_quote { "</blockquote>" } else { "<blockquote>" });
            in_quote = !in_quote;
        }
        let tag = if list.is_some() {
            "li"
        } else {
            match block {
                "heading1" => "h1",
                "heading2" => "h2",
                "heading3" => "h3",
                "code_block" => "pre",
                _ => "p",
            }
        };
        let mut style = String::new();
        match attrs.get("align").map(String::as_str) {
            Some("center") => style.push_str("text-align:center;"),
            Some("end") => style.push_str("text-align:end;"),
            Some("justify") => style.push_str("text-align:justify;"),
            _ => {}
        }
        if list.is_none() && level > 0 {
            style.push_str(&format!("margin-left:{}px;", level * 40));
        }
        if style.is_empty() {
            out.push_str(&format!("<{tag}>"));
        } else {
            out.push_str(&format!("<{tag} style=\"{style}\">"));
        }
        if list == Some("check") {
            out.push_str(if attrs.contains_key("checked") {
                "<input type=\"checkbox\" disabled checked> "
            } else {
                "<input type=\"checkbox\" disabled> "
            });
        }
        let spans = super::kdoc::spans_of(text, &runs, para.start, para.end);
        if spans.is_empty() && tag != "li" {
            out.push_str("<br>");
        }
        for (piece, marks) in spans {
            let mut open = String::new();
            let mut close = Vec::new();
            if let Some(url) = marks.get("link") {
                open.push_str("<a href=\"");
                html_escape(&mut open, url);
                open.push_str("\">");
                close.push("</a>");
            }
            if let Some(color) = marks.get("color") {
                open.push_str(&format!("<span style=\"color:{color}\">"));
                close.push("</span>");
            }
            for (name, tag) in [("bold", "b"), ("italic", "i"), ("underline", "u"), ("strike", "s"), ("code", "code")] {
                if marks.contains_key(name) {
                    open.push_str(&format!("<{tag}>"));
                    close.push(match tag { "b" => "</b>", "i" => "</i>", "u" => "</u>", "s" => "</s>", _ => "</code>" });
                }
            }
            out.push_str(&open);
            html_escape(&mut out, &piece);
            for c in close.iter().rev() {
                out.push_str(c);
            }
        }
        out.push_str(&format!("</{tag}>"));
    }
    while let Some(tag) = open_lists.pop() {
        out.push_str(&format!("</{tag}>"));
    }
    if in_quote {
        out.push_str("</blockquote>");
    }
    out
}

/// What a reader collects: paragraphs of styled pieces, then [`finish`].
#[derive(Default)]
struct Builder {
    text: String,
    runs: Vec<TextRun>,
    para_start: usize,
    paras: Vec<(usize, usize, BTreeMap<String, String>)>,
}

impl Builder {
    fn push(&mut self, s: &str, marks: &BTreeMap<String, String>) {
        if s.is_empty() {
            return;
        }
        let at = self.text.len();
        self.text.push_str(s);
        for (name, value) in marks {
            self.runs.push(TextRun::new(at as u64, self.text.len() as u64, name, value));
        }
    }

    fn end_para(&mut self, attrs: BTreeMap<String, String>) {
        self.paras.push((self.para_start, self.text.len(), attrs));
        self.text.push('\n');
        self.para_start = self.text.len();
    }

    /// A collapsed space at a paragraph's end is not text.
    fn trim_space(&mut self) {
        if self.has_content() && self.text.ends_with(' ') {
            self.text.pop();
            let len = self.text.len() as u64;
            self.runs.retain(|r| r.range.start < len);
            for r in &mut self.runs {
                r.range.end = r.range.end.min(len);
            }
        }
    }

    fn has_content(&self) -> bool {
        self.text.len() > self.para_start
    }

    /// The paragraph attributes over each paragraph's text (an empty one's on
    /// its terminator), the final newline dropped, RD2's scope enforced by
    /// letting a heading or code block win over a list.
    fn finish(mut self, last: BTreeMap<String, String>) -> (String, Vec<TextRun>) {
        let start = self.para_start;
        self.paras.push((start, self.text.len(), last));
        while self.paras.len() > 1 && self.paras.last().is_some_and(|(a, b, _)| a == b) {
            self.paras.pop();
            self.text.pop();
        }
        let mut kept: Vec<BTreeMap<String, String>> = Vec::new();
        for (a, b, attrs) in &self.paras {
            let mut attrs = attrs.clone();
            let block = attrs.get("block").cloned().unwrap_or_default();
            if block.starts_with("heading") || block == "code_block" {
                attrs.remove("list");
            }
            if attrs.get("list").map(String::as_str) != Some("check") {
                attrs.remove("checked");
            }
            if attrs.get("list").map(String::as_str) != Some("numbered") {
                attrs.remove("start");
            }
            if attrs.get("block").is_some_and(|b| b.starts_with("heading")) && a < b {
                self.runs.retain(|r| !(r.name == "bold" && r.range.start >= *a as u64 && r.range.end <= *b as u64));
            }
            let (a, b) = if a == b { (*a, (*a + 1).min(self.text.len())) } else { (*a, *b) };
            if a < b {
                for (name, value) in &attrs {
                    self.runs.push(TextRun::new(a as u64, b as u64, name, value));
                }
            }
            kept.push(attrs);
        }
        let last = self.paras.len() - 1;
        let inline = normalize_runs(self.runs.clone());
        for i in 0..last {
            let (pa, pb, _) = self.paras[i];
            let (qa, qb, _) = self.paras[i + 1];
            if pa == pb {
                continue;
            }
            let newline = pb as u64;
            let q_final_empty = i + 1 == last && qa == qb;
            for (name, value) in &kept[i + 1] {
                if q_final_empty || kept[i].get(name) == Some(value) {
                    self.runs.push(TextRun::new(newline, newline + 1, name, value));
                }
            }
            if qa < qb {
                let before = super::attrs_at(&inline, pb - 1);
                let after = super::attrs_at(&inline, qa);
                for (name, value) in before.iter().filter(|(n, _)| !is_paragraph_attr(n)) {
                    if after.get(name) == Some(value) {
                        self.runs.push(TextRun::new(newline, newline + 1, name, value));
                    }
                }
            }
        }
        let len = self.text.len() as u64;
        let runs = self
            .runs
            .into_iter()
            .filter(|r| r.range.start < len)
            .map(|r| TextRun { range: r.range.start..r.range.end.min(len), ..r })
            .collect();
        (self.text, normalize_runs(runs))
    }
}

/// A colour a paste keeps: explicit black is the page's own ink, so it is
/// automatic, and so is anything that is not opaque sRGB.
fn kept_color(rgb: u32) -> Option<String> {
    (rgb != 0).then(|| format!("#{rgb:06X}"))
}

#[derive(Clone, Copy, PartialEq)]
enum Dest {
    Text,
    Skip,
    FontTable,
    ColorTable,
    ExpandedColorTable,
    ListTable,
    ListOverrideTable,
    ListText,
    FieldInstruction,
    KayaBlock,
    KayaStart,
}

#[derive(Clone)]
struct Group {
    dest: Dest,
    bold: bool,
    italic: bool,
    underline: bool,
    strike: bool,
    font: i32,
    color: i32,
    uc: i32,
    field_result: bool,
}

#[derive(Default, Clone)]
struct ParaProps {
    li: i32,
    align: Option<&'static str>,
    ls: Option<i32>,
    ilvl: i32,
    outline: Option<i32>,
    kaya_block: Option<String>,
    kaya_start: Option<String>,
}

enum Tok {
    Open,
    Close,
    Word(String, Option<i32>),
    Sym(u8),
    Hex(u8),
    Byte(u8),
}

fn rtf_tokens(bytes: &[u8]) -> Vec<Tok> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'{' => {
                out.push(Tok::Open);
                i += 1;
            }
            b'}' => {
                out.push(Tok::Close);
                i += 1;
            }
            b'\\' if i + 1 < bytes.len() => {
                let c = bytes[i + 1];
                if c.is_ascii_alphabetic() {
                    let mut j = i + 1;
                    while j < bytes.len() && bytes[j].is_ascii_alphabetic() {
                        j += 1;
                    }
                    let word = String::from_utf8_lossy(&bytes[i + 1..j]).into_owned();
                    let mut k = j;
                    if k < bytes.len() && (bytes[k] == b'-' || bytes[k].is_ascii_digit()) {
                        k += 1;
                        while k < bytes.len() && bytes[k].is_ascii_digit() {
                            k += 1;
                        }
                    }
                    let param = std::str::from_utf8(&bytes[j..k]).ok().and_then(|s| s.parse::<i32>().ok());
                    if k < bytes.len() && bytes[k] == b' ' {
                        k += 1;
                    }
                    out.push(Tok::Word(word, param));
                    i = k;
                } else if c == b'\'' {
                    let hex = std::str::from_utf8(&bytes[i + 2..(i + 4).min(bytes.len())]).ok().and_then(|h| u8::from_str_radix(h, 16).ok());
                    if let Some(h) = hex {
                        out.push(Tok::Hex(h));
                    }
                    i += 4;
                } else {
                    out.push(Tok::Sym(c));
                    i += 2;
                }
            }
            b'\r' | b'\n' => i += 1,
            b => {
                out.push(Tok::Byte(b));
                i += 1;
            }
        }
    }
    out
}

/// Windows-1252's upper half, for `\'hh` under `\ansicpg1252`.
fn cp1252(b: u8) -> char {
    const HIGH: [u16; 32] = [
        0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD,
        0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178,
    ];
    match b {
        0x80..=0x9F => char::from_u32(HIGH[(b - 0x80) as usize] as u32).unwrap_or('\u{FFFD}'),
        b => b as char,
    }
}

fn is_mono_font(name: &str, family_modern: bool) -> bool {
    let n = name.to_ascii_lowercase();
    family_modern || ["courier", "menlo", "monaco", "consolas", "mono", "jetbrains"].iter().any(|m| n.contains(m))
}

/// RTF in, kaya's vocabulary out: bold, italic, underline, strike, a
/// monospace face as code, a colour (black and Apple's text colours are
/// automatic), a HYPERLINK field as a link; paragraphs with lists (`\ls` and
/// `\ilvl` through the list table, a checklist through its box), an indent
/// from `\li`, alignment, a heading from `\outlinelevel`, and kaya's own
/// `{\*\kayablock}`. Everything else is dropped.
pub(crate) fn rtf_read(bytes: &[u8]) -> (String, Vec<TextRun>) {
    let toks = rtf_tokens(bytes);
    let base = Group { dest: Dest::Text, bold: false, italic: false, underline: false, strike: false, font: -1, color: 0, uc: 1, field_result: false };
    let mut stack: Vec<Group> = Vec::new();
    let mut g = base.clone();
    let mut b = Builder::default();
    let mut para = ParaProps::default();
    let mut fonts: BTreeMap<i32, bool> = BTreeMap::new();
    let mut font_index = 0;
    let mut font_modern = false;
    let mut font_name = String::new();
    let mut colors: Vec<Option<u32>> = Vec::new();
    let mut color_rgb = (0i32, 0i32, 0i32, false);
    let mut expanded: Vec<Option<Option<u32>>> = Vec::new();
    let mut expanded_entry: Option<Option<u32>> = None;
    let mut css: Vec<i32> = Vec::new();
    let mut lists: BTreeMap<i32, Vec<&'static str>> = BTreeMap::new();
    let mut list_levels: Vec<&'static str> = Vec::new();
    let mut override_list = 0;
    let mut overrides: BTreeMap<i32, i32> = BTreeMap::new();
    let mut listtext = String::new();
    let mut fldinst = String::new();
    let mut link: Option<String> = None;
    let mut kaya_word = String::new();
    let mut skip_chars = 0i32;
    let mut pending_star = false;
    let mut first_numbered_at: BTreeMap<i32, bool> = BTreeMap::new();

    let marks_of = |g: &Group, fonts: &BTreeMap<i32, bool>, colors: &[Option<u32>], link: &Option<String>| {
        let mut m = BTreeMap::new();
        let flag = crate::protocol::FLAG_VALUE.to_owned();
        if g.bold {
            m.insert("bold".to_owned(), flag.clone());
        }
        if g.italic {
            m.insert("italic".to_owned(), flag.clone());
        }
        if g.strike {
            m.insert("strike".to_owned(), flag.clone());
        }
        if fonts.get(&g.font).copied().unwrap_or(false) {
            m.insert("code".to_owned(), flag.clone());
        }
        match (g.field_result, link) {
            (true, Some(url)) => {
                m.insert("link".to_owned(), url.clone());
            }
            _ => {
                if g.underline {
                    m.insert("underline".to_owned(), flag.clone());
                }
                if let Some(Some(rgb)) = colors.get(g.color as usize) {
                    if let Some(c) = kept_color(*rgb) {
                        m.insert("color".to_owned(), c);
                    }
                }
            }
        }
        m
    };

    let para_attrs_of = |p: &ParaProps, lists: &BTreeMap<i32, Vec<&'static str>>, overrides: &BTreeMap<i32, i32>, listtext: &str| -> BTreeMap<String, String> {
        let mut a = BTreeMap::new();
        if let Some(level) = p.outline.filter(|l| (0..9).contains(l)) {
            a.insert("block".to_owned(), format!("heading{}", (level + 1).min(3)));
        }
        if let Some(block) = &p.kaya_block {
            if block == "quote" || block == "code_block" {
                a.insert("block".to_owned(), block.clone());
            }
        }
        if let Some(ls) = p.ls {
            let level = p.ilvl.clamp(0, 8);
            let kind = overrides
                .get(&ls)
                .and_then(|id| lists.get(id))
                .and_then(|levels| levels.get(level as usize).copied())
                .unwrap_or("bullet");
            let boxed = listtext.contains('\u{2610}') || listtext.contains('\u{2611}');
            let kind = if boxed { "check" } else { kind };
            a.insert("list".to_owned(), kind.to_owned());
            if listtext.contains('\u{2611}') {
                a.insert("checked".to_owned(), crate::protocol::FLAG_VALUE.to_owned());
            }
            if level > 0 {
                a.insert("indent".to_owned(), level.to_string());
            }
        } else {
            let base = if a.get("block").map(String::as_str) == Some("quote") { TWIPS_PER_LEVEL as i32 } else { 0 };
            let level = ((p.li - base).max(0) + TWIPS_PER_LEVEL as i32 / 2) / TWIPS_PER_LEVEL as i32;
            if level > 0 {
                a.insert("indent".to_owned(), level.min(8).to_string());
            }
        }
        if let Some(align) = p.align {
            a.insert("align".to_owned(), align.to_owned());
        }
        a
    };

    let mut i = 0;
    while i < toks.len() {
        let tok = &toks[i];
        i += 1;
        match tok {
            Tok::Open => {
                stack.push(g.clone());
                if g.dest == Dest::ListText || g.dest == Dest::Skip {
                    continue;
                }
            }
            Tok::Close => {
                let leaving = g.dest;
                match leaving {
                    Dest::FontTable if !font_name.is_empty() || font_modern => {}
                    Dest::FieldInstruction => {
                        if let Some(rest) = fldinst.trim().strip_prefix("HYPERLINK") {
                            let url = rest.split('"').nth(1).map(str::to_owned);
                            link = url.filter(|u| !u.is_empty());
                        }
                    }
                    Dest::KayaBlock => para.kaya_block = Some(kaya_word.trim().to_owned()),
                    Dest::KayaStart => para.kaya_start = Some(kaya_word.trim().to_owned()),
                    _ => {}
                }
                let was_result = g.field_result;
                g = stack.pop().unwrap_or_else(|| base.clone());
                if was_result && !g.field_result {
                    link = None;
                }
            }
            Tok::Word(word, param) => {
                let p = *param;
                let on = p != Some(0);
                if pending_star {
                    pending_star = false;
                    g.dest = match word.as_str() {
                        "expandedcolortbl" => {
                            expanded.clear();
                            Dest::ExpandedColorTable
                        }
                        "listtable" => Dest::ListTable,
                        "listoverridetable" => Dest::ListOverrideTable,
                        "fldinst" => {
                            fldinst.clear();
                            Dest::FieldInstruction
                        }
                        "kayablock" => {
                            kaya_word.clear();
                            Dest::KayaBlock
                        }
                        "kayastart" => {
                            kaya_word.clear();
                            Dest::KayaStart
                        }
                        _ => Dest::Skip,
                    };
                    continue;
                }
                if g.dest == Dest::Skip {
                    continue;
                }
                match (g.dest, word.as_str()) {
                    (Dest::FontTable, "f") => {
                        font_index = p.unwrap_or(0);
                        font_modern = false;
                        font_name.clear();
                    }
                    (Dest::FontTable, "fmodern") => font_modern = true,
                    (Dest::ColorTable, "red") => color_rgb = (p.unwrap_or(0), color_rgb.1, color_rgb.2, true),
                    (Dest::ColorTable, "green") => color_rgb = (color_rgb.0, p.unwrap_or(0), color_rgb.2, true),
                    (Dest::ColorTable, "blue") => color_rgb = (color_rgb.0, color_rgb.1, p.unwrap_or(0), true),
                    (Dest::ExpandedColorTable, "cssrgb" | "csgray") => {
                        css.clear();
                        expanded_entry = Some(None);
                    }
                    (Dest::ExpandedColorTable, "c") => css.push(p.unwrap_or(0)),
                    (Dest::ExpandedColorTable, "cname") => expanded_entry = Some(None),
                    (Dest::ListTable, "list") => list_levels.clear(),
                    (Dest::ListTable, "levelnfc") => list_levels.push(match p.unwrap_or(0) {
                        23 | 255 => "bullet",
                        _ => "numbered",
                    }),
                    (Dest::ListTable, "listid") => {
                        lists.insert(p.unwrap_or(0), std::mem::take(&mut list_levels));
                    }
                    (Dest::ListOverrideTable, "listid") => override_list = p.unwrap_or(0),
                    (Dest::ListOverrideTable, "ls") => {
                        overrides.insert(p.unwrap_or(0), override_list);
                    }
                    (Dest::ListTable | Dest::ListOverrideTable | Dest::FontTable | Dest::ColorTable | Dest::ExpandedColorTable, _) => {}
                    (_, "fonttbl") => g.dest = Dest::FontTable,
                    (_, "colortbl") => {
                        colors.clear();
                        g.dest = Dest::ColorTable;
                    }
                    (_, "listtext") => {
                        listtext.clear();
                        g.dest = Dest::ListText;
                    }
                    (_, "stylesheet" | "info" | "pict" | "object" | "header" | "footer" | "footnote" | "themedata" | "colorschememapping" | "latentstyles" | "datastore" | "xmlnstbl" | "rsidtbl" | "generator" | "mmathPr" | "pgdsctbl" | "operator" | "nonshppict") => {
                        g.dest = Dest::Skip
                    }
                    (_, "fldrslt") => g.field_result = true,
                    (_, "par" | "line" | "sect" | "page") => {
                        let attrs = para_attrs_of(&para, &lists, &overrides, &listtext);
                        if let (Some(ls), Some("numbered")) = (para.ls, attrs.get("list").map(String::as_str)) {
                            let first = first_numbered_at.insert(ls * 16 + para.ilvl, true).is_none();
                            let n = listtext.trim().trim_end_matches(['.', ')']).parse::<u64>().ok();
                            let mut attrs = attrs;
                            if let Some(start) = para.kaya_start.clone() {
                                attrs.insert("start".to_owned(), start);
                            } else if first && n.is_some_and(|n| n > 1) {
                                attrs.insert("start".to_owned(), n.expect("some").to_string());
                            }
                            b.end_para(attrs);
                        } else {
                            if attrs.get("list").is_none() {
                                first_numbered_at.clear();
                            }
                            b.end_para(attrs);
                        }
                        listtext.clear();
                        para.kaya_start = None;
                    }
                    (_, "pard") => {
                        para = ParaProps::default();
                    }
                    (_, "plain") => {
                        g.bold = false;
                        g.italic = false;
                        g.underline = false;
                        g.strike = false;
                        g.font = -1;
                        g.color = 0;
                    }
                    (_, "b") => g.bold = on,
                    (_, "i") => g.italic = on,
                    (_, "ul") => g.underline = on,
                    (_, "ulnone") => g.underline = false,
                    (_, "strike" | "striked") => g.strike = on,
                    (_, "f") => g.font = p.unwrap_or(0),
                    (_, "cf") => g.color = p.unwrap_or(0),
                    (_, "uc") => g.uc = p.unwrap_or(1),
                    (_, "li") => para.li = p.unwrap_or(0),
                    (_, "ql") => para.align = None,
                    (_, "qc") => para.align = Some("center"),
                    (_, "qr") => para.align = Some("end"),
                    (_, "qj") => para.align = Some("justify"),
                    (_, "ls") => para.ls = p,
                    (_, "ilvl") => para.ilvl = p.unwrap_or(0),
                    (_, "outlinelevel") => para.outline = p,
                    (_, "tab") => {
                        if g.dest == Dest::ListText {
                            listtext.push('\t');
                        } else if g.dest == Dest::Text {
                            b.push("\t", &marks_of(&g, &fonts, &colors, &link));
                        }
                    }
                    (_, "u") => {
                        let unit = p.unwrap_or(0);
                        let unit = if unit < 0 { (unit + 65536) as u32 } else { unit as u32 };
                        let c = if (0xD800..0xDC00).contains(&unit) {
                            let mut j = i;
                            let mut skipped = 0;
                            while skipped < g.uc && j < toks.len() && matches!(toks[j], Tok::Byte(_) | Tok::Hex(_)) {
                                j += 1;
                                skipped += 1;
                            }
                            match toks.get(j) {
                                Some(Tok::Word(w, Some(lo))) if w == "u" => {
                                    let lo = if *lo < 0 { (*lo + 65536) as u32 } else { *lo as u32 };
                                    i = j + 1;
                                    char::from_u32(0x10000 + ((unit - 0xD800) << 10) + (lo - 0xDC00)).unwrap_or('\u{FFFD}')
                                }
                                _ => '\u{FFFD}',
                            }
                        } else {
                            char::from_u32(unit).unwrap_or('\u{FFFD}')
                        };
                        let mut buf = [0u8; 4];
                        let s = c.encode_utf8(&mut buf);
                        match g.dest {
                            Dest::Text => b.push(s, &marks_of(&g, &fonts, &colors, &link)),
                            Dest::ListText => listtext.push_str(s),
                            Dest::FieldInstruction => fldinst.push_str(s),
                            _ => {}
                        }
                        skip_chars = g.uc;
                    }
                    _ => {}
                }
            }
            Tok::Sym(c) => {
                if g.dest == Dest::Skip {
                    continue;
                }
                match c {
                    b'*' => pending_star = true,
                    b'\n' | b'\r' => {
                        let attrs = para_attrs_of(&para, &lists, &overrides, &listtext);
                        b.end_para(attrs);
                        listtext.clear();
                    }
                    b'\\' | b'{' | b'}' => {
                        let s = (*c as char).to_string();
                        match g.dest {
                            Dest::Text => b.push(&s, &marks_of(&g, &fonts, &colors, &link)),
                            Dest::FieldInstruction => fldinst.push_str(&s),
                            _ => {}
                        }
                    }
                    b'~' if g.dest == Dest::Text => b.push("\u{a0}", &marks_of(&g, &fonts, &colors, &link)),
                    _ => {}
                }
            }
            Tok::Hex(h) | Tok::Byte(h) => {
                let hex = matches!(tok, Tok::Hex(_));
                if skip_chars > 0 {
                    skip_chars -= 1;
                    continue;
                }
                let c = if hex { cp1252(*h) } else { *h as char };
                match g.dest {
                    Dest::Text => {
                        let mut buf = [0u8; 4];
                        b.push(c.encode_utf8(&mut buf), &marks_of(&g, &fonts, &colors, &link));
                    }
                    Dest::ListText => listtext.push(c),
                    Dest::FieldInstruction => fldinst.push(c),
                    Dest::KayaBlock | Dest::KayaStart => kaya_word.push(c),
                    Dest::FontTable => {
                        if c == ';' {
                            fonts.insert(font_index, is_mono_font(&font_name, font_modern));
                            font_name.clear();
                            font_modern = false;
                        } else {
                            font_name.push(c);
                        }
                    }
                    Dest::ColorTable if c == ';' => {
                        colors.push(color_rgb.3.then(|| ((color_rgb.0 as u32) << 16) | ((color_rgb.1 as u32) << 8) | color_rgb.2 as u32));
                        color_rgb = (0, 0, 0, false);
                    }
                    Dest::ExpandedColorTable if c == ';' => {
                        let entry = match (expanded_entry.take(), css.len()) {
                            (Some(_), 3) => Some(Some(css.iter().fold(0u32, |acc, v| (acc << 8) | ((*v as f64 / 100000.0 * 255.0).round().clamp(0.0, 255.0) as u32)))),
                            (Some(_), 1) => {
                                let v = (css[0] as f64 / 100000.0 * 255.0).round().clamp(0.0, 255.0) as u32;
                                Some(Some((v << 16) | (v << 8) | v))
                            }
                            (Some(_), _) => Some(None),
                            (None, _) => None,
                        };
                        css.clear();
                        expanded.push(entry);
                    }
                    _ => {}
                }
            }
        }
        if g.dest != Dest::ExpandedColorTable && !expanded.is_empty() {
            for (index, entry) in expanded.drain(..).enumerate() {
                if let (Some(slot), Some(value)) = (colors.get_mut(index), entry) {
                    *slot = value;
                }
            }
        }
    }
    let last = para_attrs_of(&para, &lists, &overrides, &listtext);
    b.finish(last)
}

fn entity(name: &str) -> Option<char> {
    if let Some(num) = name.strip_prefix('#') {
        let n = match num.strip_prefix(['x', 'X']) {
            Some(hex) => u32::from_str_radix(hex, 16).ok()?,
            None => num.parse().ok()?,
        };
        return char::from_u32(n);
    }
    Some(match name {
        "amp" => '&',
        "lt" => '<',
        "gt" => '>',
        "quot" => '"',
        "apos" => '\'',
        "nbsp" => '\u{a0}',
        "ndash" => '\u{2013}',
        "mdash" => '\u{2014}',
        "lsquo" => '\u{2018}',
        "rsquo" => '\u{2019}',
        "ldquo" => '\u{201C}',
        "rdquo" => '\u{201D}',
        "hellip" => '\u{2026}',
        "bull" => '\u{2022}',
        "copy" => '\u{a9}',
        "reg" => '\u{ae}',
        "trade" => '\u{2122}',
        _ => return None,
    })
}

fn decode_entities(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(at) = rest.find('&') {
        out.push_str(&rest[..at]);
        let tail = &rest[at + 1..];
        match tail.find(';').filter(|end| *end <= 10).and_then(|end| entity(&tail[..end]).map(|c| (c, end))) {
            Some((c, end)) => {
                out.push(c);
                rest = &tail[end + 1..];
            }
            None => {
                out.push('&');
                rest = tail;
            }
        }
    }
    out.push_str(rest);
    out
}

/// `#RGB`, `#RRGGBB`, `rgb(r, g, b)`, `rgba(…)` and the CSS names a paste
/// commonly carries; None for anything else.
fn css_color(v: &str) -> Option<u32> {
    let v = v.trim().to_ascii_lowercase();
    if let Some(hex) = v.strip_prefix('#') {
        return match hex.len() {
            3 => {
                let n = u32::from_str_radix(hex, 16).ok()?;
                let (r, g, b) = ((n >> 8) & 0xF, (n >> 4) & 0xF, n & 0xF);
                Some((r * 17) << 16 | (g * 17) << 8 | b * 17)
            }
            6 | 8 => u32::from_str_radix(&hex[..6], 16).ok(),
            _ => None,
        };
    }
    if let Some(inner) = v.strip_prefix("rgba(").or_else(|| v.strip_prefix("rgb(")).and_then(|r| r.strip_suffix(')')) {
        let parts: Vec<f64> = inner.split([',', ' ', '/']).filter(|p| !p.is_empty()).filter_map(|p| p.trim().parse::<f64>().ok()).collect();
        if parts.len() >= 3 {
            let q = |x: f64| x.round().clamp(0.0, 255.0) as u32;
            return Some(q(parts[0]) << 16 | q(parts[1]) << 8 | q(parts[2]));
        }
        return None;
    }
    Some(match v.as_str() {
        "black" | "windowtext" => 0x000000,
        "red" => 0xFF0000,
        "green" => 0x008000,
        "blue" => 0x0000FF,
        "gray" | "grey" => 0x808080,
        "orange" => 0xFFA500,
        "purple" => 0x800080,
        "brown" => 0xA52A2A,
        "navy" => 0x000080,
        "maroon" => 0x800000,
        "teal" => 0x008080,
        "olive" => 0x808000,
        "white" => 0xFFFFFF,
        _ => return None,
    })
}

fn style_of(attrs: &str) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    if let Some(style) = attr(attrs, "style") {
        for decl in style.split(';') {
            if let Some((k, v)) = decl.split_once(':') {
                out.insert(k.trim().to_ascii_lowercase(), v.trim().to_ascii_lowercase());
            }
        }
    }
    out
}

fn attr(attrs: &str, name: &str) -> Option<String> {
    let lower = attrs.to_ascii_lowercase();
    let mut from = 0;
    while let Some(at) = lower[from..].find(name) {
        let at = from + at;
        let before_ok = at == 0 || lower.as_bytes()[at - 1].is_ascii_whitespace();
        let rest = lower[at + name.len()..].trim_start();
        if before_ok && rest.starts_with('=') {
            let offset = attrs.len() - rest.len() + 1;
            let value = attrs[offset..].trim_start();
            let (quote, body) = match value.chars().next() {
                Some(q @ ('"' | '\'')) => (Some(q), &value[1..]),
                _ => (None, value),
            };
            let end = match quote {
                Some(q) => body.find(q).unwrap_or(body.len()),
                None => body.find(|c: char| c.is_whitespace() || c == '>').unwrap_or(body.len()),
            };
            return Some(decode_entities(&body[..end]));
        }
        if before_ok && (rest.is_empty() || rest.starts_with(|c: char| c.is_whitespace() || c == '/' || c == '>')) {
            return Some(String::new());
        }
        from = at + name.len();
    }
    None
}

#[derive(Clone, Default)]
struct HtmlStyle {
    marks: BTreeMap<String, String>,
}

/// HTML in, kaya's vocabulary out; the Windows clipboard's CF_HTML header is
/// read for its fragment first. Paragraphs come from block elements and
/// `<br>`, lists from `<ul>`/`<ol>` nesting (a checkbox makes a checklist
/// item), headings from `<h1>`-`<h6>`, a quote from `<blockquote>`, a code
/// block from `<pre>`; marks from the tags and the `style` they carry.
pub(crate) fn html_read(source: &str) -> (String, Vec<TextRun>) {
    let source = cf_html_fragment(source);
    let flag = crate::protocol::FLAG_VALUE.to_owned();
    let mut b = Builder::default();
    let mut styles: Vec<(String, HtmlStyle)> = vec![(String::new(), HtmlStyle::default())];
    let mut lists: Vec<(&'static str, Option<u64>, u64)> = Vec::new();
    let mut quote = 0;
    let mut pre = 0;
    let mut heading: Option<String> = None;
    let mut align: Vec<Option<&'static str>> = Vec::new();
    let mut margin: Vec<usize> = Vec::new();
    let mut skip = 0;
    let mut item: Option<BTreeMap<String, String>> = None;
    let mut space_pending = false;

    let para_now = |lists: &[(&'static str, Option<u64>, u64)], quote: i32, pre: i32, heading: &Option<String>, align: &[Option<&'static str>], margin: &[usize], item: &Option<BTreeMap<String, String>>| {
        let mut a = item.clone().unwrap_or_default();
        if let Some(h) = heading {
            a.insert("block".to_owned(), h.clone());
        } else if pre > 0 {
            a.insert("block".to_owned(), "code_block".to_owned());
        } else if quote > 0 {
            a.insert("block".to_owned(), "quote".to_owned());
        }
        if item.is_some() {
            if lists.len() > 1 {
                a.insert("indent".to_owned(), (lists.len() - 1).min(8).to_string());
            }
        } else {
            let level: usize = margin.iter().sum();
            if level > 0 {
                a.insert("indent".to_owned(), level.min(8).to_string());
            }
        }
        if let Some(Some(al)) = align.iter().rev().find(|a| a.is_some()) {
            a.insert("align".to_owned(), (*al).to_owned());
        }
        a
    };

    let mut rest: &str = &source;
    while !rest.is_empty() {
        if let Some(after) = rest.strip_prefix("<!--") {
            rest = after.find("-->").map_or("", |end| &after[end + 3..]);
            continue;
        }
        if rest.starts_with('<') {
            let end = rest.find('>').unwrap_or(rest.len() - 1);
            let inner = &rest[1..end];
            rest = &rest[(end + 1).min(rest.len())..];
            if inner.starts_with('!') || inner.starts_with('?') {
                continue;
            }
            let closing = inner.starts_with('/');
            let body = inner.trim_start_matches('/');
            let name_end = body.find(|c: char| c.is_whitespace() || c == '/').unwrap_or(body.len());
            let name = body[..name_end].to_ascii_lowercase();
            let attrs = &body[name_end..];
            if matches!(name.as_str(), "head" | "style" | "script" | "title" | "template") {
                if closing {
                    skip -= 1;
                } else if !inner.ends_with('/') {
                    skip += 1;
                }
                continue;
            }
            if skip > 0 {
                continue;
            }
            let block = matches!(
                name.as_str(),
                "p" | "div" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6" | "blockquote" | "pre" | "li" | "ul" | "ol" | "table" | "tr" | "section" | "article" | "header" | "footer"
            );
            if block || name == "br" {
                let at_br = name == "br";
                if pre == 0 {
                    b.trim_space();
                }
                if at_br || b.has_content() {
                    let attrs_now = para_now(&lists, quote, pre, &heading, &align, &margin, &item);
                    b.end_para(attrs_now);
                    if item.is_some() {
                        item = Some(item.take().unwrap_or_default().into_iter().filter(|(n, _)| n == "list").collect());
                    }
                }
                space_pending = false;
            }
            if closing {
                match name.as_str() {
                    "ul" | "ol" => {
                        lists.pop();
                        item = None;
                    }
                    "li" => item = None,
                    "blockquote" => quote -= 1,
                    "pre" => pre -= 1,
                    "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => heading = None,
                    _ => {}
                }
                if block && !matches!(name.as_str(), "ul" | "ol" | "li") {
                    align.pop();
                    margin.pop();
                }
                if let Some(pos) = styles.iter().rposition(|(n, _)| *n == name) {
                    styles.truncate(pos.max(1));
                }
                continue;
            }
            let css = style_of(attrs);
            match name.as_str() {
                "ul" | "ol" => {
                    let start = attr(attrs, "start").and_then(|s| s.parse().ok());
                    lists.push((if name == "ol" { "numbered" } else { "bullet" }, start, 0));
                    continue;
                }
                "li" => {
                    let (kind, start, count) = lists.last().copied().unwrap_or(("bullet", None, 0));
                    let mut a = BTreeMap::new();
                    a.insert("list".to_owned(), kind.to_owned());
                    if kind == "numbered" && count == 0 {
                        if let Some(s) = start.filter(|s| *s > 1) {
                            a.insert("start".to_owned(), s.to_string());
                        }
                    }
                    if let Some(last) = lists.last_mut() {
                        last.2 += 1;
                    }
                    item = Some(a);
                    continue;
                }
                "input" => {
                    if attr(attrs, "type").is_some_and(|t| t.eq_ignore_ascii_case("checkbox")) {
                        if let Some(a) = item.as_mut() {
                            a.insert("list".to_owned(), "check".to_owned());
                            if attr(attrs, "checked").is_some() {
                                a.insert("checked".to_owned(), flag.clone());
                            }
                        }
                    }
                    continue;
                }
                "blockquote" => quote += 1,
                "pre" => pre += 1,
                "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => {
                    let n: u32 = name[1..].parse().unwrap_or(1);
                    heading = Some(format!("heading{}", n.min(3)));
                }
                "br" | "img" | "hr" | "meta" | "link" => continue,
                _ => {}
            }
            if block {
                align.push(match css.get("text-align").map(String::as_str) {
                    Some("center") => Some("center"),
                    Some("right" | "end") => Some("end"),
                    Some("justify") => Some("justify"),
                    _ => None,
                });
                let px = css
                    .get("margin-left")
                    .or_else(|| css.get("padding-left"))
                    .and_then(|v| {
                        if let Some(px) = v.strip_suffix("px") {
                            px.trim().parse::<f64>().ok()
                        } else {
                            v.strip_suffix("em").and_then(|em| em.trim().parse::<f64>().ok()).map(|em| em * 16.0)
                        }
                    })
                    .unwrap_or(0.0);
                margin.push(if name == "blockquote" { 0 } else { (px / 40.0).round().max(0.0) as usize });
            }
            let mut style = styles.last().map(|(_, s)| s.clone()).unwrap_or_default();
            let m = &mut style.marks;
            match name.as_str() {
                "b" | "strong" => {
                    m.insert("bold".to_owned(), flag.clone());
                }
                "i" | "em" | "cite" => {
                    m.insert("italic".to_owned(), flag.clone());
                }
                "u" | "ins" => {
                    m.insert("underline".to_owned(), flag.clone());
                }
                "s" | "strike" | "del" => {
                    m.insert("strike".to_owned(), flag.clone());
                }
                "code" | "tt" | "kbd" | "samp" => {
                    m.insert("code".to_owned(), flag.clone());
                }
                "a" => {
                    if let Some(href) = attr(attrs, "href").filter(|h| !h.is_empty()) {
                        m.insert("link".to_owned(), href);
                    }
                }
                "font" => {
                    if let Some(c) = attr(attrs, "color").and_then(|c| css_color(&c)) {
                        match kept_color(c) {
                            Some(c) => m.insert("color".to_owned(), c),
                            None => m.remove("color"),
                        };
                    }
                }
                _ => {}
            }
            if let Some(w) = css.get("font-weight") {
                if w == "bold" || w == "bolder" || w.parse::<u32>().is_ok_and(|n| n >= 600) {
                    m.insert("bold".to_owned(), flag.clone());
                } else if w == "normal" || w.parse::<u32>().is_ok_and(|n| n < 600) {
                    m.remove("bold");
                }
            }
            if let Some(s) = css.get("font-style") {
                if s == "italic" || s == "oblique" {
                    m.insert("italic".to_owned(), flag.clone());
                } else if s == "normal" {
                    m.remove("italic");
                }
            }
            for key in ["text-decoration", "text-decoration-line"] {
                if let Some(d) = css.get(key) {
                    if d.contains("underline") {
                        m.insert("underline".to_owned(), flag.clone());
                    }
                    if d.contains("line-through") {
                        m.insert("strike".to_owned(), flag.clone());
                    }
                    if d.contains("none") {
                        m.remove("underline");
                        m.remove("strike");
                    }
                }
            }
            if let Some(c) = css.get("color").and_then(|c| css_color(c)) {
                match kept_color(c) {
                    Some(c) => m.insert("color".to_owned(), c),
                    None => m.remove("color"),
                };
            }
            if css.get("font-family").is_some_and(|f| is_mono_font(f, f.contains("monospace"))) {
                m.insert("code".to_owned(), flag.clone());
            }
            styles.push((name, style));
            continue;
        }
        let end = rest.find('<').unwrap_or(rest.len());
        let raw = decode_entities(&rest[..end]);
        rest = &rest[end..];
        if skip > 0 {
            continue;
        }
        let mut marks = styles.last().map(|(_, s)| s.marks.clone()).unwrap_or_default();
        if marks.contains_key("link") {
            marks.remove("underline");
            marks.remove("color");
        }
        if pre > 0 {
            let mut lines = raw.split('\n').peekable();
            while let Some(line) = lines.next() {
                b.push(&line.replace('\r', ""), &marks);
                if lines.peek().is_some() {
                    let a = para_now(&lists, quote, pre, &heading, &align, &margin, &item);
                    b.end_para(a);
                }
            }
            continue;
        }
        let mut piece = String::new();
        for c in raw.chars() {
            if c.is_whitespace() && c != '\u{a0}' {
                if !space_pending && (b.has_content() || !piece.is_empty()) {
                    piece.push(' ');
                }
                space_pending = true;
            } else {
                space_pending = false;
                piece.push(if c == '\u{a0}' { ' ' } else { c });
            }
        }
        b.push(&piece, &marks);
    }
    if pre == 0 {
        b.trim_space();
    }
    let last = para_now(&lists, quote, pre, &heading, &align, &margin, &item);
    b.finish(last)
}

/// CF_HTML's header names the fragment's byte offsets; anything else is the
/// HTML itself.
fn cf_html_fragment(source: &str) -> String {
    if !source.starts_with("Version:") {
        return source.to_owned();
    }
    let offset = |key: &str| -> Option<usize> {
        source.lines().find_map(|l| l.strip_prefix(key)).and_then(|v| v.trim().parse::<usize>().ok())
    };
    match (offset("StartHTML:"), offset("EndHTML:")) {
        (Some(a), Some(z)) if a <= z && z <= source.len() && source.is_char_boundary(a) && source.is_char_boundary(z) => source[a..z].to_owned(),
        _ => source.to_owned(),
    }
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

    fn sample() -> (String, Vec<TextRun>) {
        let text = "Walks\nA good walk h\u{e4}s no plan.\nmap\nwater\nread\nquiet\nend";
        let runs = normalize_runs(vec![
            run(0, 5, "block", "heading1"),
            run(13, 17, "bold", "true"),
            run(18, 22, "italic", "true"),
            run(23, 25, "underline", "true"),
            run(6, 31, "align", "center"),
            run(32, 41, "list", "bullet"),
            run(36, 41, "indent", "1"),
            run(38, 41, "color", "#C4554D"),
            run(42, 46, "list", "check"),
            run(42, 46, "checked", "true"),
            run(47, 52, "block", "quote"),
            run(53, 56, "strike", "true"),
            run(53, 56, "link", "https://kaya.dev/"),
        ]);
        (text.to_owned(), runs)
    }

    #[test]
    fn rtf_round_trips_the_vocabulary() {
        let (text, runs) = sample();
        let rtf = rtf_write(&text, &runs);
        let (back, back_runs) = rtf_read(rtf.as_bytes());
        assert_eq!(back, text, "rtf:\n{rtf}");
        assert_eq!(spelled(&back_runs), spelled(&runs), "rtf:\n{rtf}");
    }

    #[test]
    fn html_round_trips_the_vocabulary() {
        let (text, runs) = sample();
        let html = html_write(&text, &runs);
        let (back, back_runs) = html_read(&html);
        assert_eq!(back, text, "html:\n{html}");
        assert_eq!(spelled(&back_runs), spelled(&runs), "html:\n{html}");
    }

    #[test]
    fn numbered_lists_keep_their_start_both_ways() {
        let text = "a\nb";
        let runs = normalize_runs(vec![run(0, 3, "list", "numbered"), run(0, 1, "start", "4")]);
        let (t, r) = rtf_read(rtf_write(text, &runs).as_bytes());
        assert_eq!((t.as_str(), spelled(&r)), (text, spelled(&runs)));
        let (t, r) = html_read(&html_write(text, &runs));
        assert_eq!((t.as_str(), spelled(&r)), (text, spelled(&runs)));
    }

    /// The Cocoa writer's own output (textutil on macOS 26.6.2, recorded in
    /// docs/rich-document-plan.md §11): its `\` line ends, its list table,
    /// and its expanded colour table's sRGB over the calibrated entry.
    #[test]
    fn apples_rtf_reads_as_kaya_vocabulary() {
        let rtf = br#"{\rtf1\ansi\ansicpg1252\cocoartf2870
\cocoatextscaling0\cocoaplatform0{\fonttbl\f0\froman\fcharset0 Times-Roman;\f1\froman\fcharset0 Times-Bold;}
{\colortbl;\red255\green255\blue255;\red0\green0\blue0;\red181\green64\blue60;\red0\green0\blue233;
}
{\*\expandedcolortbl;;\cssrgb\c0\c0\c0;\cssrgb\c76863\c33333\c30196;\cssrgb\c0\c0\c93333;
}
{\*\listtable{\list\listtemplateid1\listhybrid{\listlevel\levelnfc23\levelnfcn23\leveljc0\leveljcn0\levelfollow0\levelstartat0\levelspace360\levelindent0{\*\levelmarker \{disc\}}{\leveltext\leveltemplateid1\'01\uc0\u8226 ;}{\levelnumbers;}\fi-360\li720\lin720 }{\listlevel\levelnfc23\levelnfcn23\leveljc0\leveljcn0\levelfollow0\levelstartat0\levelspace360\levelindent0{\*\levelmarker \{circle\}}{\leveltext\leveltemplateid2\'01\uc0\u9702 ;}{\levelnumbers;}\fi-360\li1440\lin1440 }{\listname ;}\listid1}
{\list\listtemplateid2\listhybrid{\listlevel\levelnfc0\levelnfcn0\leveljc0\leveljcn0\levelfollow0\levelstartat1\levelspace360\levelindent0{\*\levelmarker \{decimal\}}{\leveltext\leveltemplateid101\'01\'00;}{\levelnumbers\'01;}\fi-360\li720\lin720 }{\listname ;}\listid2}}
{\*\listoverridetable{\listoverride\listid1\listoverridecount0\ls1}{\listoverride\listid2\listoverridecount0\ls2}}
\deftab720
\pard\pardeftab720\sa240\partightenfactor0

\f0\fs24 \cf0 \expnd0\expndtw0\kerning0
\outl0\strokewidth0 \strokec2 Title\
\pard\tx220\tx720\pardeftab720\li720\fi-720\partightenfactor0
\ls1\ilvl0\cf0 \kerning1\expnd0\expndtw0 \outl0\strokewidth0 {\listtext	\uc0\u8226 	}\expnd0\expndtw0\kerning0
\outl0\strokewidth0 \strokec2 one\
\ls1\ilvl0\kerning1\expnd0\expndtw0 \outl0\strokewidth0 {\listtext	\uc0\u8226 	}\expnd0\expndtw0\kerning0
\outl0\strokewidth0 \strokec2 two\
\pard\tx940\tx1440\pardeftab720\li1440\fi-1440\partightenfactor0
\ls1\ilvl1\cf0 \kerning1\expnd0\expndtw0 \outl0\strokewidth0 {\listtext	\uc0\u9702 	}\expnd0\expndtw0\kerning0
\outl0\strokewidth0 \strokec2 deep\
\pard\tx220\tx720\pardeftab720\li720\fi-720\partightenfactor0
\ls2\ilvl0\cf0 \kerning1\expnd0\expndtw0 \outl0\strokewidth0 {\listtext	1	}\expnd0\expndtw0\kerning0
\outl0\strokewidth0 \strokec2 first\
\ls2\ilvl0\kerning1\expnd0\expndtw0 \outl0\strokewidth0 {\listtext	2	}\expnd0\expndtw0\kerning0
\outl0\strokewidth0 \strokec2 second\
\pard\pardeftab720\sa240\qc\partightenfactor0
\cf3 \strokec3 red\cf0 \strokec2  
\f1\b bold
\f0\b0  {\field{\*\fldinst{HYPERLINK "https://kaya.dev/"}}{\fldrslt \cf4 \ul \ulc4 \strokec4 link}}\
}"#;
        let (text, runs) = rtf_read(rtf);
        assert_eq!(text, "Title\none\ntwo\ndeep\nfirst\nsecond\nred bold link");
        assert_eq!(
            spelled(&runs),
            "6:18 list=bullet|14:18 indent=1|19:31 list=numbered|32:45 align=center|32:35 color=#C4554D|36:40 bold=true|41:45 link=https://kaya.dev/"
        );
    }

    #[test]
    fn google_docs_wrapper_bold_is_not_bold_and_black_is_automatic() {
        let html = r#"<meta charset="utf-8"><b style="font-weight:normal;" id="docs-internal-guid-1"><p dir="ltr"><span style="color:#000000;font-weight:700">Hi</span><span style="color:#000000"> there</span></p><ul><li><p>one</p></li><li><p>two</p></li></ul></b>"#;
        let (text, runs) = html_read(html);
        assert_eq!(text, "Hi there\none\ntwo");
        assert_eq!(spelled(&runs), "0:2 bold=true|9:16 list=bullet");
    }

    #[test]
    fn cf_html_reads_its_fragment() {
        let body = "<html><body><!--StartFragment--><p><i>x</i></p><!--EndFragment--></body></html>";
        let header_len = "Version:0.9\r\nStartHTML:0000000000\r\nEndHTML:0000000000\r\n".len();
        let source = format!("Version:0.9\r\nStartHTML:{:010}\r\nEndHTML:{:010}\r\n{body}", header_len, header_len + body.len());
        let (text, runs) = html_read(&source);
        assert_eq!((text.as_str(), spelled(&runs)), ("x", "0:1 italic=true".to_owned()));
    }
}
