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

/// The most colours a palette answers, whatever `n` asks for.
pub(crate) const PALETTE_MAX: usize = 16;
/// Bits per channel of the palette's histogram.
const PALETTE_BITS: u32 = 5;

/// One of a picture's main colours and the fraction of its opaque-enough
/// pixels that colour stands for.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PaletteColor {
    pub color: crate::Color,
    pub share: f64,
}

fn palette_memo() -> &'static Mutex<HashMap<(u64, usize), Option<Vec<(u32, f64)>>>> {
    static MEMO: OnceLock<Mutex<HashMap<(u64, usize), Option<Vec<(u32, f64)>>>>> = OnceLock::new();
    MEMO.get_or_init(|| Mutex::new(HashMap::new()))
}

/// A PNG or JPEG's main colours, at most `n` (and at most 16),
/// largest share first, or None for bytes that do not decode
/// (docs/media-player-plan.md M15).
pub fn image_palette(bytes: &[u8], n: usize) -> Option<Vec<PaletteColor>> {
    palette_rgb(bytes, n).map(|found| {
        found
            .into_iter()
            .map(|(rgb, share)| PaletteColor {
                color: crate::Color::rgb((rgb >> 16) as u8, (rgb >> 8) as u8, rgb as u8),
                share,
            })
            .collect()
    })
}

/// The packed (0xRRGGBB, share) answer, memoized by the bytes' content and `n`.
pub(crate) fn palette_rgb(bytes: &[u8], n: usize) -> Option<Vec<(u32, f64)>> {
    let k = n.min(PALETTE_MAX);
    let key = (content_hash(bytes), k);
    if let Some(hit) = palette_memo().lock().unwrap().get(&key) {
        return hit.clone();
    }
    let answer = crate::reader::decode_straight(bytes).map(|(_, _, rgba)| palette_of(&rgba, k));
    let mut m = palette_memo().lock().unwrap();
    if m.len() >= MEMO_CAP {
        m.clear();
    }
    m.insert(key, answer.clone());
    answer
}

#[derive(Clone, Copy, Default)]
struct Bin {
    n: u64,
    s: [u64; 3],
    q: [u64; 3],
}

impl Bin {
    fn add(&mut self, o: &Bin) {
        self.n += o.n;
        for c in 0..3 {
            self.s[c] += o.s[c];
            self.q[c] += o.q[c];
        }
    }

    /// The summed squared distance of the pixels from their mean, in whole
    /// units: integer arithmetic, so every platform answers the same split.
    fn sse(&self) -> u128 {
        if self.n == 0 {
            return 0;
        }
        let n = u128::from(self.n);
        (0..3).map(|c| (n * u128::from(self.q[c]) - u128::from(self.s[c]).pow(2)) / n).sum()
    }
}

/// A box's best cut: the squared error it removes and the two halves.
fn best_cut(bins: &[Bin], members: &[u32]) -> Option<(u128, Vec<u32>, Vec<u32>)> {
    let mut whole = Bin::default();
    for &i in members {
        whole.add(&bins[i as usize]);
    }
    let before = whole.sse();
    let shift = |axis: usize| PALETTE_BITS * (2 - axis as u32);
    let mask = (1u32 << PALETTE_BITS) - 1;
    let mut best: Option<(u128, usize, usize)> = None;
    let mut orders: [Vec<u32>; 3] = [Vec::new(), Vec::new(), Vec::new()];
    for (axis, order) in orders.iter_mut().enumerate() {
        *order = members.to_vec();
        order.sort_by_key(|&i| ((i >> shift(axis)) & mask, i));
        let mut left = Bin::default();
        for cut in 1..order.len() {
            left.add(&bins[order[cut - 1] as usize]);
            let here = (order[cut - 1] >> shift(axis)) & mask;
            let next = (order[cut] >> shift(axis)) & mask;
            if here == next {
                continue;
            }
            let mut right = whole;
            right.n -= left.n;
            for c in 0..3 {
                right.s[c] -= left.s[c];
                right.q[c] -= left.q[c];
            }
            let after = left.sse() + right.sse();
            if best.is_none_or(|(b, _, _)| after < b) {
                best = Some((after, axis, cut));
            }
        }
    }
    best.map(|(after, axis, cut)| {
        let order = std::mem::take(&mut orders[axis]);
        let (l, r) = order.split_at(cut);
        (before.saturating_sub(after), l.to_vec(), r.to_vec())
    })
}

/// The main colours of straight RGBA8, at most `k`: a 2^15-bin histogram of
/// the opaque-enough pixels, cut greedily, each cut the plane that removes
/// the most squared error, until `k` boxes or no box holds two bins. Each
/// box answers its pixels' rounded mean and its share; largest first.
pub(crate) fn palette_of(rgba: &[u8], k: usize) -> Vec<(u32, f64)> {
    let k = k.min(PALETTE_MAX);
    if k == 0 {
        return Vec::new();
    }
    let side = 1usize << PALETTE_BITS;
    let mut bins = vec![Bin::default(); side * side * side];
    let drop = 8 - PALETTE_BITS;
    let mut total = 0u64;
    for p in rgba.chunks_exact(4) {
        if p[3] < 128 {
            continue;
        }
        let i = ((usize::from(p[0]) >> drop) << (2 * PALETTE_BITS))
            | ((usize::from(p[1]) >> drop) << PALETTE_BITS)
            | (usize::from(p[2]) >> drop);
        let bin = &mut bins[i];
        bin.n += 1;
        for c in 0..3 {
            let v = u64::from(p[c]);
            bin.s[c] += v;
            bin.q[c] += v * v;
        }
        total += 1;
    }
    if total == 0 {
        return Vec::new();
    }
    let members: Vec<u32> = (0..bins.len() as u32).filter(|&i| bins[i as usize].n > 0).collect();
    let mut boxes = vec![(best_cut(&bins, &members), members)];
    while boxes.len() < k {
        let pick = boxes
            .iter()
            .enumerate()
            .filter_map(|(i, (cut, _))| cut.as_ref().map(|(gain, ..)| (i, *gain)))
            .max_by_key(|&(i, gain)| (gain, std::cmp::Reverse(i)));
        let Some((i, _)) = pick else { break };
        let (cut, _) = std::mem::replace(&mut boxes[i], (None, Vec::new()));
        let (_, left, right) = cut.expect("the picked box has a cut");
        boxes[i] = (best_cut(&bins, &left), left);
        boxes.push((best_cut(&bins, &right), right));
    }
    let mut out: Vec<(u32, u64)> = boxes
        .iter()
        .map(|(_, members)| {
            let mut sum = Bin::default();
            for &i in members {
                sum.add(&bins[i as usize]);
            }
            let c = |s: u64| ((s + sum.n / 2) / sum.n) as u32;
            ((c(sum.s[0]) << 16) | (c(sum.s[1]) << 8) | c(sum.s[2]), sum.n)
        })
        .collect();
    out.sort_by_key(|&(rgb, n)| (std::cmp::Reverse(n), rgb));
    out.into_iter().map(|(rgb, n)| (rgb, n as f64 / total as f64)).collect()
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

    fn shares(found: &[(u32, f64)]) -> Vec<(u32, u32)> {
        found.iter().map(|&(rgb, share)| (rgb, (share * 1000.0).round() as u32)).collect()
    }

    #[test]
    fn a_palette_answers_each_main_colour_with_its_share_largest_first() {
        let rgba = picture(&[(0x7A2E9C, 700), (0x1F8F3A, 200), (0xF0F0F0, 100)]);
        assert_eq!(shares(&palette_of(&rgba, 6)), [(0x7A2E9C, 700), (0x1F8F3A, 200), (0xF0F0F0, 100)]);
        let two = picture(&[(0x2040C0, 400), (0xC03020, 600)]);
        assert_eq!(shares(&palette_of(&two, 6)), [(0xC03020, 600), (0x2040C0, 400)]);
        assert_eq!(shares(&palette_of(&two, 1)), [(0x803660, 1000)]);
    }

    #[test]
    fn a_grey_picture_answers_greys_and_an_empty_one_nothing() {
        let ramp: Vec<(u32, usize)> = (0..16u32).map(|i| (i * 16 * 0x010101, 10 + i as usize)).collect();
        let found = palette_of(&picture(&ramp), 6);
        assert_eq!(found.len(), 6);
        for &(rgb, _) in &found {
            let (r, g, b) = ((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);
            assert!(r == g && g == b, "{rgb:06x} is not a grey");
        }
        let sum: f64 = found.iter().map(|&(_, s)| s).sum();
        assert!((sum - 1.0).abs() < 1e-9, "shares sum to {sum}");
        assert!(palette_of(&[9, 9, 9, 0, 9, 9, 9, 0], 6).is_empty());
        assert!(palette_of(&picture(&[(0x808080, 4)]), 0).is_empty());
    }

    #[test]
    fn the_same_pixels_answer_the_same_palette_to_the_bit() {
        let rgba: Vec<u8> = (0..200u32 * 200)
            .flat_map(|i| {
                let (x, y) = (i % 200, i / 200);
                let mut h = u64::from(i).wrapping_mul(0x9E37_79B9_7F4A_7C15);
                h ^= h >> 29;
                let noise = (h & 0x1F) as u32;
                [(x + noise) as u8, (y + noise / 2) as u8, ((x * y) / 160 + noise) as u8, 255]
            })
            .collect();
        let first = palette_of(&rgba, PALETTE_MAX + 4);
        assert_eq!(first.len(), PALETTE_MAX);
        assert_eq!(palette_of(&rgba, PALETTE_MAX), first);
        let bits: Vec<(u32, u64)> = first.iter().map(|&(rgb, s)| (rgb, s.to_bits())).collect();
        let again: Vec<(u32, u64)> = palette_of(&rgba, PALETTE_MAX).iter().map(|&(rgb, s)| (rgb, s.to_bits())).collect();
        assert_eq!(bits, again);
        let pinned: u64 = first.iter().fold(0xcbf2_9ce4_8422_2325, |h, &(rgb, s)| {
            (h ^ u64::from(rgb) ^ s.to_bits()).wrapping_mul(0x0100_0000_01b3)
        });
        eprintln!("palette of the generated picture: {:06x?} fingerprint {pinned:016x}", first.iter().map(|p| p.0).collect::<Vec<_>>());
        assert_eq!(pinned, PINNED_FINGERPRINT);
    }

    const PINNED_FINGERPRINT: u64 = 0x79a4_272b_f65d_5c16;

    #[test]
    fn real_art_answers_a_palette_and_undecodable_bytes_nothing() {
        assert_eq!(palette_rgb(b"not an image", 6), None);
        let art = &crate::assets::read("covers/cover-600.jpg").expect("the cover resolves")[..];
        let decoded = std::time::Instant::now();
        let (_, _, rgba) = crate::reader::decode_straight(art).expect("the generated cover decodes");
        let decode = decoded.elapsed();
        let started = std::time::Instant::now();
        let found = palette_of(&rgba, 6);
        let cost = started.elapsed();
        assert_eq!(found.len(), 6);
        assert!(found.windows(2).all(|w| w[0].1 >= w[1].1), "largest share first");
        let sum: f64 = found.iter().map(|&(_, s)| s).sum();
        assert!((sum - 1.0).abs() < 1e-9, "shares sum to {sum}");
        assert_eq!(palette_rgb(art, 6), Some(found.clone()), "the decoded path answers the same");
        let colours: Vec<String> = found.iter().map(|&(rgb, s)| format!("{rgb:06x}@{s:.3}")).collect();
        eprintln!("image_palette on cover-600.jpg: {} in {cost:?} (decode {decode:?})", colours.join(" "));
    }
}
