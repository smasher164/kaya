//! kaya's caption renderer's platform-free half (docs/media-plan.md §3): a
//! sidecar WebVTT file parsed into cues, and which cue is current at a
//! time. Every backend that draws kaya's captions (Apple for a sidecar,
//! Android and GTK at breadth) asks the core here and draws the answer.

/// One cue: shown from `start_ms` up to, not including, `end_ms`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Cue {
    pub start_ms: u64,
    pub end_ms: u64,
    pub text: String,
}

/// A parsed WebVTT file: its cues in file order.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct Captions {
    pub cues: Vec<Cue>,
}

impl Captions {
    /// The WebVTT parser (W3C WebVTT §6.1, the parts a caption file uses):
    /// the `WEBVTT` signature, blocks split by blank lines, a block with no
    /// timing line skipped (NOTE, STYLE and REGION blocks may not contain
    /// `-->`), an optional cue identifier, the timing line,
    /// and the payload with its tags stripped and its character references
    /// decoded. A block whose timing does not parse, or that ends before it
    /// starts, is dropped, as the specification's parser drops it.
    pub(crate) fn parse(text: &str) -> Result<Captions, String> {
        let text = text.strip_prefix('\u{feff}').unwrap_or(text);
        let text = text.replace("\r\n", "\n").replace('\r', "\n");
        let mut lines = text.split('\n');
        let first = lines.next().unwrap_or("");
        let signature_ok = first == "WEBVTT"
            || (first.starts_with("WEBVTT") && matches!(first.as_bytes().get(6), Some(b' ' | b'\t')));
        if !signature_ok {
            return Err(format!("a WebVTT file starts with the line WEBVTT, and this one starts {first:?}"));
        }
        let rest: Vec<&str> = lines.collect();
        let mut cues = Vec::new();
        let mut i = 0;
        // The header's own lines run to the first blank line.
        while i < rest.len() && !rest[i].is_empty() {
            i += 1;
        }
        while i < rest.len() {
            while i < rest.len() && rest[i].trim().is_empty() {
                i += 1;
            }
            let start = i;
            while i < rest.len() && !rest[i].trim().is_empty() {
                i += 1;
            }
            let block = &rest[start..i];
            if block.is_empty() {
                continue;
            }
            let timing_at = usize::from(!block[0].contains("-->") && block.len() > 1);
            let Some((start_ms, end_ms)) = parse_timing(block[timing_at]) else { continue };
            if end_ms <= start_ms {
                continue;
            }
            let payload: Vec<String> = block[timing_at + 1..].iter().map(|l| clean_payload(l)).collect();
            cues.push(Cue { start_ms, end_ms, text: payload.join("\n") });
        }
        Ok(Captions { cues })
    }

    /// THE CUE TIMING: every cue current at `t_ms` (start inclusive, end
    /// exclusive), in file order, one per line; "" between cues.
    pub(crate) fn text_at(&self, t: u64) -> String {
        self.cues
            .iter()
            .filter(|c| c.start_ms <= t && t < c.end_ms)
            .map(|c| c.text.as_str())
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// Every time the current text can change, ascending, once each: the
    /// times a backend watches its clock for.
    pub(crate) fn boundaries(&self) -> Vec<u64> {
        let mut times: Vec<u64> = self.cues.iter().flat_map(|c| [c.start_ms, c.end_ms]).collect();
        times.sort_unstable();
        times.dedup();
        times
    }
}

/// `hh:mm:ss.ttt --> hh:mm:ss.ttt [settings]`, the hours optional.
fn parse_timing(line: &str) -> Option<(u64, u64)> {
    let (from, to) = line.split_once("-->")?;
    let start = parse_timestamp(from.trim())?;
    let end = parse_timestamp(to.split_whitespace().next()?)?;
    Some((start, end))
}

fn parse_timestamp(s: &str) -> Option<u64> {
    let (clock, frac) = s.split_once('.')?;
    if frac.len() != 3 || !frac.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let parts: Vec<&str> = clock.split(':').collect();
    let num = |p: &str, max: Option<u64>| -> Option<u64> {
        if p.is_empty() || !p.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        let n: u64 = p.parse().ok()?;
        match max {
            Some(m) if n > m || p.len() != 2 => None,
            _ => Some(n),
        }
    };
    let (h, m, sec) = match parts.as_slice() {
        [m, s] => (0, num(m, Some(59))?, num(s, Some(59))?),
        [h, m, s] if h.len() >= 2 => (num(h, None)?, num(m, Some(59))?, num(s, Some(59))?),
        _ => return None,
    };
    let ms: u64 = frac.parse().ok()?;
    Some(((h * 60 + m) * 60 + sec) * 1000 + ms)
}

/// A payload line with its markup removed: `<c.x>`, `<i>`, `<v Name>`,
/// `<00:00:01.000>` and the rest go, and `&amp;` `&lt;` `&gt;` `&nbsp;`
/// `&lrm;` `&rlm;` decode.
fn clean_payload(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut rest = line;
    while let Some(open) = rest.find('<') {
        out.push_str(&rest[..open]);
        match rest[open..].find('>') {
            Some(close) => rest = &rest[open + close + 1..],
            None => {
                rest = "";
            }
        }
    }
    out.push_str(rest);
    out.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", "\u{a0}")
        .replace("&lrm;", "\u{200e}")
        .replace("&rlm;", "\u{200f}")
        .replace("&amp;", "&")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn suite() -> Captions {
        let bytes = crate::assets::read("media/captions.vtt").unwrap();
        Captions::parse(&String::from_utf8(bytes).unwrap()).unwrap()
    }

    #[test]
    fn the_suites_sidecar_parses_into_its_two_cues() {
        let c = suite();
        assert_eq!(
            c.cues,
            [
                Cue { start_ms: 0, end_ms: 1000, text: "first cue".into() },
                Cue { start_ms: 1000, end_ms: 2000, text: "second cue".into() },
            ]
        );
    }

    #[test]
    fn a_file_without_the_signature_is_refused() {
        assert!(Captions::parse("00:00.000 --> 00:01.000\nhi\n").is_err());
        assert!(Captions::parse("WEBVTTX\n\n00:00.000 --> 00:01.000\nhi\n").is_err());
        assert!(Captions::parse("\u{feff}WEBVTT - with a title\n\n00:00.000 --> 00:01.000\nhi\n").is_ok());
    }

    #[test]
    fn the_parser_takes_identifiers_settings_markup_and_skips_what_is_not_a_cue() {
        let file = "WEBVTT\r\nKind: captions\r\n\r\nNOTE a comment\r\nspanning lines\r\n\r\nSTYLE\r\n::cue { color: red }\r\n\r\n\
                    intro\r\n00:01:02.500 --> 01:00:00.000 align:start line:10%\r\n<v Roger>Hello &amp; <i>welcome</i>\r\n<c.loud>two</c> &lt;lines&gt;\r\n\r\n\
                    00:00:09.000 --> 00:00:08.000\r\nbackwards\r\n\r\n\
                    00:00:5.000 --> 00:00:06.000\r\nbad timestamp\r\n\r\n\
                    00:00:07.50 --> 00:00:08.000\r\nshort fraction\r\n\r\n\
                    no timing here\r\n";
        let c = Captions::parse(file).unwrap();
        assert_eq!(
            c.cues,
            [Cue { start_ms: 62_500, end_ms: 3_600_000, text: "Hello & welcome\ntwo <lines>".into() }]
        );
    }

    #[test]
    fn the_current_cue_is_start_inclusive_end_exclusive() {
        let c = suite();
        assert_eq!(c.text_at(0), "first cue");
        assert_eq!(c.text_at(500), "first cue");
        assert_eq!(c.text_at(1500), "second cue");
        assert_eq!(c.text_at(999), "first cue");
        assert_eq!(c.text_at(1000), "second cue");
        assert_eq!(c.text_at(2000), "");
        assert_eq!(c.text_at(60_000), "");
    }

    #[test]
    fn overlapping_cues_show_together_and_the_boundaries_are_every_change() {
        let c = Captions::parse(
            "WEBVTT\n\n00:00.000 --> 00:03.000\nlong\n\n00:01.000 --> 00:02.000\nshort\n\n00:01.000 --> 00:03.000\nthird\n",
        )
        .unwrap();
        assert_eq!(c.text_at(1500), "long\nshort\nthird");
        assert_eq!(c.text_at(2500), "long\nthird");
        assert_eq!(c.boundaries(), [0, 1000, 2000, 3000]);
    }
}
