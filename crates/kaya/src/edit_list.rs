//! An ISO BMFF file's picture start, read from its video track's edit list
//! (docs/traps.md, the edit-list entry): Media Foundation ignores `elst`, so
//! the WinUI arm reads it here and moves its clock by it.

/// Where the presentation starts inside the video track's media timeline, in
/// 100 ns units: what Media Foundation's clock reads at the first picture.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Shift(pub(crate) i64);

/// Bytes at an offset; fewer than asked only at the end of the file.
pub(crate) trait ReadAt {
    fn read_at(&mut self, offset: u64, len: usize) -> Result<Vec<u8>, String>;
}

const MOOV_CAP: u64 = 64 << 20;
const TOP_LEVEL: [&[u8; 4]; 8] = [b"ftyp", b"moov", b"mdat", b"free", b"skip", b"wide", b"pdin", b"uuid"];

/// Ok(None): not ISO BMFF, no video track, or a video track whose edit list
/// moves nothing. Err: a file this reader cannot answer for, said in words.
pub(crate) fn video_shift(src: &mut dyn ReadAt) -> Result<Option<Shift>, String> {
    let mut at = 0u64;
    loop {
        let head = src.read_at(at, 16)?;
        if head.len() < 8 {
            return Ok(None);
        }
        let (size, kind, header) = box_header(&head, at)?;
        if !TOP_LEVEL.iter().any(|k| *k == &kind) {
            return if at == 0 { Ok(None) } else { Err(format!("a top-level `{}` box at byte {at}", name(&kind))) };
        }
        if &kind == b"moov" {
            let size = match size {
                Some(size) => size,
                None => return Err("a `moov` box sized to the end of the file".to_owned()),
            };
            if size > MOOV_CAP {
                return Err(format!("a {size}-byte `moov` box, over the {MOOV_CAP}-byte cap"));
            }
            let body = src.read_at(at + header, (size - header) as usize)?;
            if (body.len() as u64) < size - header {
                return Err(format!("the `moov` box at byte {at} runs past the end of the file"));
            }
            return moov_shift(&body);
        }
        match size {
            Some(size) => at += size,
            None => return Ok(None),
        }
    }
}

/// (size, type, header length); size None for a box that runs to the end.
fn box_header(b: &[u8], at: u64) -> Result<(Option<u64>, [u8; 4], u64), String> {
    let small = u32::from_be_bytes(b[0..4].try_into().unwrap()) as u64;
    let kind: [u8; 4] = b[4..8].try_into().unwrap();
    match small {
        0 => Ok((None, kind, 8)),
        1 => {
            let big = b.get(8..16).ok_or_else(|| format!("a 64-bit box size cut short at byte {at}"))?;
            let size = u64::from_be_bytes(big.try_into().unwrap());
            if size < 16 {
                return Err(format!("a `{}` box of {size} bytes at byte {at}", name(&kind)));
            }
            Ok((Some(size), kind, 16))
        }
        n if n < 8 => Err(format!("a `{}` box of {n} bytes at byte {at}", name(&kind))),
        n => Ok((Some(n), kind, 8)),
    }
}

fn name(kind: &[u8; 4]) -> String {
    kind.iter().map(|&c| if c.is_ascii_graphic() { c as char } else { '?' }).collect()
}

fn children(body: &[u8]) -> Result<Vec<([u8; 4], &[u8])>, String> {
    let mut out = Vec::new();
    let mut at = 0usize;
    while at + 8 <= body.len() {
        let (size, kind, header) = box_header(&body[at..], at as u64)?;
        let end = size.map_or(body.len(), |s| at.saturating_add(s as usize));
        if end > body.len() {
            return Err(format!("a `{}` box runs past its parent", name(&kind)));
        }
        out.push((kind, &body[at + header as usize..end]));
        at = end;
    }
    Ok(out)
}

fn child<'a>(body: &'a [u8], kind: &[u8; 4]) -> Result<Option<&'a [u8]>, String> {
    Ok(children(body)?.into_iter().find(|(k, _)| k == kind).map(|(_, b)| b))
}

fn moov_shift(moov: &[u8]) -> Result<Option<Shift>, String> {
    for (kind, trak) in children(moov)? {
        if &kind != b"trak" {
            continue;
        }
        let Some(mdia) = child(trak, b"mdia")? else { continue };
        let Some(hdlr) = child(mdia, b"hdlr")? else { continue };
        if hdlr.get(8..12) != Some(b"vide") {
            continue;
        }
        let Some(edts) = child(trak, b"edts")? else { return Ok(None) };
        let Some(elst) = child(edts, b"elst")? else { return Ok(None) };
        let mdhd = child(mdia, b"mdhd")?.ok_or("a video track with no `mdhd`")?;
        let timescale = match mdhd.first() {
            Some(0) => mdhd.get(12..16),
            Some(1) => mdhd.get(20..24),
            _ => None,
        }
        .map(|b| u32::from_be_bytes(b.try_into().unwrap()))
        .filter(|&t| t > 0)
        .ok_or("a video `mdhd` with no timescale")?;
        let edits = elst_entries(elst)?;
        return match edits.as_slice() {
            [(_, media_time, rate)] if *media_time >= 0 && *rate == 0x0001_0000 => {
                let hns = i128::from(*media_time) * 10_000_000 / i128::from(timescale);
                Ok((hns != 0).then_some(Shift(hns as i64)))
            }
            _ => Err(format!(
                "a video edit list of {} edits ({}); only one edit at normal rate is read",
                edits.len(),
                edits.iter().map(|(d, m, r)| format!("duration {d} media_time {m} rate {r:#x}")).collect::<Vec<_>>().join(", ")
            )),
        };
    }
    Ok(None)
}

/// (segment duration, media time, rate as 16.16).
fn elst_entries(elst: &[u8]) -> Result<Vec<(u64, i64, u32)>, String> {
    let version = *elst.first().ok_or("an empty `elst`")?;
    let count = u32::from_be_bytes(elst.get(4..8).ok_or("an `elst` with no entry count")?.try_into().unwrap());
    let width = if version == 1 { 20 } else { 12 };
    let mut out = Vec::new();
    for i in 0..count as usize {
        let e = elst.get(8 + i * width..8 + (i + 1) * width).ok_or("an `elst` shorter than its entry count")?;
        let (duration, media_time, rest) = if version == 1 {
            (u64::from_be_bytes(e[0..8].try_into().unwrap()), i64::from_be_bytes(e[8..16].try_into().unwrap()), &e[16..20])
        } else {
            (
                u64::from(u32::from_be_bytes(e[0..4].try_into().unwrap())),
                i64::from(i32::from_be_bytes(e[4..8].try_into().unwrap())),
                &e[8..12],
            )
        };
        out.push((duration, media_time, u32::from_be_bytes(rest.try_into().unwrap())));
    }
    Ok(out)
}

/// A file:// URL's path, percent-decoded; `file:///C:/a%20b` is `C:/a b`.
#[cfg_attr(not(target_os = "windows"), allow(dead_code))]
pub(crate) fn file_url_path(url: &str) -> Option<String> {
    let rest = url.strip_prefix("file://")?;
    let rest = rest.strip_prefix('/').filter(|r| r.as_bytes().get(1) == Some(&b':')).unwrap_or(rest);
    let mut bytes = Vec::with_capacity(rest.len());
    let raw = rest.as_bytes();
    let mut i = 0;
    while i < raw.len() {
        if raw[i] == b'%' {
            let hex = std::str::from_utf8(raw.get(i + 1..i + 3)?).ok()?;
            bytes.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            bytes.push(raw[i]);
            i += 1;
        }
    }
    String::from_utf8(bytes).ok()
}

pub(crate) struct LocalFile(pub(crate) std::fs::File);

impl ReadAt for LocalFile {
    fn read_at(&mut self, offset: u64, len: usize) -> Result<Vec<u8>, String> {
        use std::io::{Read, Seek, SeekFrom};
        self.0.seek(SeekFrom::Start(offset)).map_err(|e| format!("seeking to byte {offset}: {e}"))?;
        let mut out = Vec::with_capacity(len);
        (&mut self.0).take(len as u64).read_to_end(&mut out).map_err(|e| format!("reading byte {offset}: {e}"))?;
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Mem(Vec<u8>);
    impl ReadAt for Mem {
        fn read_at(&mut self, offset: u64, len: usize) -> Result<Vec<u8>, String> {
            let start = (offset as usize).min(self.0.len());
            Ok(self.0[start..(start + len).min(self.0.len())].to_vec())
        }
    }

    fn asset(name: &str) -> Vec<u8> {
        crate::assets::read(&format!("media/{name}")).unwrap()
    }

    fn bx(kind: &[u8; 4], body: &[u8]) -> Vec<u8> {
        let mut v = ((body.len() + 8) as u32).to_be_bytes().to_vec();
        v.extend_from_slice(kind);
        v.extend_from_slice(body);
        v
    }

    fn trak(handler: &[u8; 4], timescale: u32, elst: Option<Vec<u8>>) -> Vec<u8> {
        let mut mdhd = vec![0u8; 24];
        mdhd[12..16].copy_from_slice(&timescale.to_be_bytes());
        let mut hdlr = vec![0u8; 24];
        hdlr[8..12].copy_from_slice(handler);
        let mdia = bx(b"mdia", &[bx(b"mdhd", &mdhd), bx(b"hdlr", &hdlr)].concat());
        let mut body = Vec::new();
        if let Some(elst) = elst {
            body.extend(bx(b"edts", &bx(b"elst", &elst)));
        }
        body.extend(mdia);
        bx(b"trak", &body)
    }

    fn elst_v0(entries: &[(u32, i32)]) -> Vec<u8> {
        let mut v = vec![0, 0, 0, 0];
        v.extend((entries.len() as u32).to_be_bytes());
        for (d, m) in entries {
            v.extend(d.to_be_bytes());
            v.extend(m.to_be_bytes());
            v.extend(0x0001_0000u32.to_be_bytes());
        }
        v
    }

    fn file(traks: &[Vec<u8>], moov_last: bool) -> Vec<u8> {
        let ftyp = bx(b"ftyp", b"isom\0\0\x02\0");
        let mdat = bx(b"mdat", &[0u8; 100]);
        let moov = bx(b"moov", &traks.concat());
        if moov_last { [ftyp, mdat, moov].concat() } else { [ftyp, moov, mdat].concat() }
    }

    #[test]
    fn the_suite_clips() {
        assert_eq!(video_shift(&mut Mem(asset("h264_frames.mp4"))), Ok(Some(Shift(800_000))));
        assert_eq!(video_shift(&mut Mem(asset("h264_aac.mp4"))), Ok(None));
        assert_eq!(video_shift(&mut Mem(asset("tone.m4a"))), Ok(None));
        assert_eq!(video_shift(&mut Mem(asset("vp9_opus.webm"))), Ok(None));
    }

    #[test]
    fn shapes() {
        let one = trak(b"vide", 12800, Some(elst_v0(&[(96000, 1024)])));
        assert_eq!(video_shift(&mut Mem(file(std::slice::from_ref(&one), true))), Ok(Some(Shift(800_000))));
        assert_eq!(video_shift(&mut Mem(file(std::slice::from_ref(&one), false))), Ok(Some(Shift(800_000))));
        let audio_first = [trak(b"soun", 48000, Some(elst_v0(&[(96000, 1024)]))), one.clone()];
        assert_eq!(video_shift(&mut Mem(file(&audio_first, true))), Ok(Some(Shift(800_000))));
        let audio_only = [trak(b"soun", 48000, Some(elst_v0(&[(96000, 1024)])))];
        assert_eq!(video_shift(&mut Mem(file(&audio_only, true))), Ok(None));
        let no_edts = [trak(b"vide", 12800, None)];
        assert_eq!(video_shift(&mut Mem(file(&no_edts, true))), Ok(None));
        let empty_then_media = [trak(b"vide", 12800, Some(elst_v0(&[(1000, -1), (96000, 0)])))];
        let err = video_shift(&mut Mem(file(&empty_then_media, true))).unwrap_err();
        assert!(err.contains("2 edits") && err.contains("media_time -1"), "{err}");
        let mut v1 = vec![1, 0, 0, 0, 0, 0, 0, 1];
        v1.extend(96000u64.to_be_bytes());
        v1.extend(2048i64.to_be_bytes());
        v1.extend(0x0001_0000u32.to_be_bytes());
        let version1 = [trak(b"vide", 25600, Some(v1))];
        assert_eq!(video_shift(&mut Mem(file(&version1, true))), Ok(Some(Shift(800_000))));
        assert_eq!(video_shift(&mut Mem(b"\x1aE\xdf\xa3 not a box".to_vec())), Ok(None));
        let mut cut = file(std::slice::from_ref(&one), true);
        cut.truncate(cut.len() - 10);
        assert!(video_shift(&mut Mem(cut)).unwrap_err().contains("past the end"));
    }

    #[test]
    fn file_urls() {
        assert_eq!(file_url_path("file:///C:/a%20b/c.mp4").as_deref(), Some("C:/a b/c.mp4"));
        assert_eq!(file_url_path("file:///Users/a%5Cb/c.mp4").as_deref(), Some("/Users/a\\b/c.mp4"));
        assert_eq!(file_url_path("http://x/c.mp4"), None);
    }
}
