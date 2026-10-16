//! An image's dominant colour (docs/styling-pass-plan.md Y2): ONE quantizer
//! for nine bindings, so the same art answers the same colour everywhere.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

/// Bins per channel of the coarse histogram.
const LEVELS: u32 = 8;
/// A pixel whose channels spread less than this is a near-grey and does not
/// vote while any coloured pixel does.
const GREY_SPREAD: u8 = 24;
/// The memo's bound; past it the memo starts over.
const MEMO_CAP: usize = 512;

fn memo() -> &'static Mutex<HashMap<u64, Option<u32>>> {
    static MEMO: OnceLock<Mutex<HashMap<u64, Option<u32>>>> = OnceLock::new();
    MEMO.get_or_init(|| Mutex::new(HashMap::new()))
}

fn content_hash(bytes: &[u8]) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::hash::DefaultHasher::new();
    bytes.hash(&mut h);
    h.finish()
}

/// The dominant colour of a PNG or JPEG, opaque, or None for bytes that do
/// not decode.
pub fn image_dominant(bytes: &[u8]) -> Option<crate::Color> {
    dominant_rgb(bytes).map(|rgb| crate::Color::rgb((rgb >> 16) as u8, (rgb >> 8) as u8, rgb as u8))
}

/// The packed 0xRRGGBB answer, memoized by the bytes' content.
pub(crate) fn dominant_rgb(bytes: &[u8]) -> Option<u32> {
    let key = content_hash(bytes);
    if let Some(hit) = memo().lock().unwrap().get(&key) {
        return *hit;
    }
    let answer = crate::reader::decode_straight(bytes).map(|(_, _, rgba)| dominant_of(&rgba));
    let mut m = memo().lock().unwrap();
    if m.len() >= MEMO_CAP {
        m.clear();
    }
    m.insert(key, answer);
    answer
}

/// The mean colour of the largest bin of a LEVELS^3 histogram over the
/// opaque-enough pixels, near-greys dropped while anything else voted.
pub(crate) fn dominant_of(rgba: &[u8]) -> u32 {
    let bins = (LEVELS * LEVELS * LEVELS) as usize;
    let mut colour = vec![(0u64, [0u64; 3]); bins];
    let mut grey = vec![(0u64, [0u64; 3]); bins];
    let step = 256 / LEVELS;
    for p in rgba.chunks_exact(4) {
        if p[3] < 128 {
            continue;
        }
        let (r, g, b) = (p[0], p[1], p[2]);
        let bin = ((u32::from(r) / step) * LEVELS * LEVELS + (u32::from(g) / step) * LEVELS + u32::from(b) / step)
            as usize;
        let spread = r.max(g).max(b) - r.min(g).min(b);
        let table = if spread < GREY_SPREAD { &mut grey } else { &mut colour };
        table[bin].0 += 1;
        table[bin].1[0] += u64::from(r);
        table[bin].1[1] += u64::from(g);
        table[bin].1[2] += u64::from(b);
    }
    let pick = |table: &[(u64, [u64; 3])]| {
        table
            .iter()
            .enumerate()
            .filter(|(_, (n, _))| *n > 0)
            .max_by_key(|(i, (n, _))| (*n, std::cmp::Reverse(*i)))
            .map(|(_, (n, sum))| {
                let c = |s: u64| ((s + n / 2) / n) as u32;
                (c(sum[0]) << 16) | (c(sum[1]) << 8) | c(sum[2])
            })
    };
    pick(&colour).or_else(|| pick(&grey)).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn picture(pixels: &[(u32, usize)]) -> Vec<u8> {
        pixels
            .iter()
            .flat_map(|&(rgb, n)| {
                std::iter::repeat_n([(rgb >> 16) as u8, (rgb >> 8) as u8, rgb as u8, 255], n)
            })
            .flatten()
            .collect()
    }

    #[test]
    fn a_picture_mostly_one_colour_answers_that_colour() {
        let rgba = picture(&[(0x7A2E9C, 700), (0x1F8F3A, 200), (0xF0F0F0, 100)]);
        assert_eq!(dominant_of(&rgba), 0x7A2E9C);
    }

    #[test]
    fn near_greys_lose_to_any_colour_and_a_grey_picture_answers_a_grey() {
        let rgba = picture(&[(0x202020, 900), (0xC03020, 100)]);
        assert_eq!(dominant_of(&rgba), 0xC03020);
        let grey = picture(&[(0x808080, 50)]);
        assert_eq!(dominant_of(&grey), 0x808080);
    }

    #[test]
    fn undecodable_bytes_answer_nothing_and_real_art_answers_its_colour() {
        assert_eq!(dominant_rgb(b"not an image"), None);
        let art = &crate::assets::read("covers/cover-600.jpg").expect("the cover resolves")[..];
        let started = std::time::Instant::now();
        let got = dominant_rgb(art).expect("the generated cover decodes");
        let cost = started.elapsed();
        let (r, g, b) = ((got >> 16) & 0xFF, (got >> 8) & 0xFF, got & 0xFF);
        assert!(r.max(g).max(b) - r.min(g).min(b) >= u32::from(GREY_SPREAD), "{got:06x} is a grey");
        assert_eq!(dominant_rgb(art), Some(got), "memoized");
        eprintln!("image_dominant on cover-600.jpg: {got:06x} in {cost:?}");
    }
}
