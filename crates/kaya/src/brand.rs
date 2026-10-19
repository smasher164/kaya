//! The brand-accent derivation (docs/styling-plan.md D1): one seed hex
//! in, per-appearance VALUES out, computed here once so no backend
//! re-derives. Packed 0xRRGGBB u32s, the wire's color word.

/// One appearance's derived values, all packed sRGB.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DerivedAccent {
    pub fill: u32,
    pub on_fill: u32,
    pub standalone: u32,
    pub hover: u32,
    pub pressed: u32,
}

/// Both appearances, from one request. `seed` rides along for Material,
/// which derives a full role scheme from the seed itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BrandAccent {
    pub seed: u32,
    pub light: DerivedAccent,
    pub dark: DerivedAccent,
}

/// The whole derivation. `light_override`/`dark_override` are D1's
/// optional per-appearance author values, used AS that appearance's
/// starting color and still clamped: an authored override may not
/// enter the danger band either.
pub fn derive(seed: u32, light_override: Option<u32>, dark_override: Option<u32>) -> BrandAccent {
    BrandAccent {
        seed,
        light: derive_one(light_override.unwrap_or(seed), Appearance::Light),
        dark: derive_one(dark_override.unwrap_or(seed), Appearance::Dark),
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Appearance {
    Light,
    Dark,
}

/// The band inside which SwiftUI's and Material's foreground rules
/// disagree (L* 60..76.1). No fill kaya produces may rest here.
const BAND_LO: f64 = 60.0;
const BAND_HI: f64 = 76.1;

fn derive_one(rgb: u32, appearance: Appearance) -> DerivedAccent {
    let lstar = cie_lstar(rgb);
    // The clamp aims PAST the band edge, not at it: u8 quantization landed
    // an aimed-at-60 fill at L* 60.2 on the property sweep's first run
    // (seed ffffff). Half a unit clear survives rounding; the correction
    // loop covers the cases the margin cannot prove away.
    let fill = match appearance {
        // Light: clamp DOWN below the band floor, the native-matching
        // line (WinUI's Dark1 stop sits at L* 46).
        Appearance::Light => {
            if lstar > BAND_LO {
                let mut target = BAND_LO - 0.5;
                let mut fill = set_lstar(rgb, target);
                while cie_lstar(fill) > BAND_LO && target > 0.0 {
                    target -= 0.5;
                    fill = set_lstar(rgb, target);
                }
                fill
            } else {
                rgb
            }
        }
        // Dark: a fill INSIDE the band is pushed up past it (the Material
        // tone-80 / WinUI Light2 model); below the band it is left alone.
        Appearance::Dark => {
            if lstar >= BAND_LO && lstar < BAND_HI {
                let mut target = BAND_HI + 0.5;
                let mut fill = set_lstar(rgb, target);
                while cie_lstar(fill) < BAND_HI && target < 100.0 {
                    target += 0.5;
                    fill = set_lstar(rgb, target);
                }
                fill
            } else {
                rgb
            }
        }
    };
    let fill_l = cie_lstar(fill);
    let on_fill = if fill_l < BAND_LO { 0xFFFFFF } else { 0x000000 };
    // libadwaita's standalone rule verbatim, in Oklab lightness.
    let standalone = match appearance {
        Appearance::Light => clamp_oklab_l_max(rgb, 0.5),
        Appearance::Dark => clamp_oklab_l_min(rgb, 0.85),
    };
    // Darker in light, lighter in dark — every platform's own direction.
    let (d_hover, d_pressed) = match appearance {
        Appearance::Light => (-4.0, -8.0),
        Appearance::Dark => (4.0, 8.0),
    };
    DerivedAccent {
        fill,
        on_fill,
        standalone,
        hover: shift_lstar(fill, d_hover),
        pressed: shift_lstar(fill, d_pressed),
    }
}

/// docs/styling-pass-plan.md Y2: the dark appearance's white text passes
/// 4.5:1 at or below this L*, the light appearance's black text far above
/// 4.5:1 at or above the other.
pub(crate) const GRADIENT_DARK_MAX_LSTAR: f64 = 48.0;
pub(crate) const GRADIENT_LIGHT_MIN_LSTAR: f64 = 75.0;

/// A gradient ground's top stop in each appearance, from one data colour:
/// `(light, dark)`, packed 0xRRGGBB (docs/styling-pass-plan.md Y2).
pub fn gradient_tops(rgb: u32) -> (u32, u32) {
    let rgb = rgb & 0xFF_FFFF;
    let lstar = cie_lstar(rgb);
    let dark = if lstar > GRADIENT_DARK_MAX_LSTAR {
        let mut target = GRADIENT_DARK_MAX_LSTAR - 0.5;
        let mut top = set_lstar(rgb, target);
        while cie_lstar(top) > GRADIENT_DARK_MAX_LSTAR && target > 0.0 {
            target -= 0.5;
            top = set_lstar(rgb, target);
        }
        top
    } else {
        rgb
    };
    let light = if lstar < GRADIENT_LIGHT_MIN_LSTAR {
        let mut target = GRADIENT_LIGHT_MIN_LSTAR + 0.5;
        let mut top = lift_keeping_chroma(rgb, target);
        while cie_lstar(top) < GRADIENT_LIGHT_MIN_LSTAR && target < 100.0 {
            target += 0.5;
            top = lift_keeping_chroma(rgb, target);
        }
        top
    } else {
        rgb
    };
    (light, dark)
}

/// Y2's light top: L* lifted to `target` at the seed's Oklab hue and chroma,
/// the chroma given up only where the sRGB gamut ends.
fn lift_keeping_chroma(rgb: u32, target: f64) -> u32 {
    let (l0, a, b) = oklab(rgb);
    let at = |l: f64| {
        let full = oklab_linear(l, a, b);
        if in_gamut(full) {
            return full;
        }
        let (mut lo, mut hi) = (0.0f64, 1.0f64);
        for _ in 0..40 {
            let mid = (lo + hi) / 2.0;
            if in_gamut(oklab_linear(l, a * mid, b * mid)) {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        oklab_linear(l, a * lo, b * lo)
    };
    let lstar_of = |(r, g, b): (f64, f64, f64)| {
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
        if y <= 216.0 / 24389.0 {
            y * 24389.0 / 27.0
        } else {
            116.0 * y.cbrt() - 16.0
        }
    };
    let (mut lo, mut hi) = (l0, 1.0f64);
    for _ in 0..40 {
        let mid = (lo + hi) / 2.0;
        if lstar_of(at(mid)) < target {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    let (r, g, b) = at(hi);
    pack(delinearize(r.max(0.0)), delinearize(g.max(0.0)), delinearize(b.max(0.0)))
}

fn in_gamut((r, g, b): (f64, f64, f64)) -> bool {
    [r, g, b].iter().all(|c| (-1e-9..=1.0 + 1e-9).contains(c))
}

/// Oklab (Björn Ottosson's matrices) of a packed sRGB colour: (L, a, b).
fn oklab(rgb: u32) -> (f64, f64, f64) {
    let (r, g, b) = srgb_channels(rgb);
    let (lr, lg, lb) = (linearize(r), linearize(g), linearize(b));
    let l = (0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb).cbrt();
    let m = (0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb).cbrt();
    let s = (0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb).cbrt();
    (
        0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    )
}

/// Linear sRGB of an Oklab colour, unclamped, so a caller can see the gamut.
fn oklab_linear(l: f64, a: f64, b: f64) -> (f64, f64, f64) {
    let l_ = (l + 0.3963377774 * a + 0.2158037573 * b).powi(3);
    let m_ = (l - 0.1055613458 * a - 0.0638541728 * b).powi(3);
    let s_ = (l - 0.0894841775 * a - 1.2914855480 * b).powi(3);
    (
        4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_,
        -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_,
        -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_,
    )
}

/// WCAG's contrast ratio of two packed sRGB colours.
#[cfg(test)]
pub fn contrast_ratio(a: u32, b: u32) -> f64 {
    let (la, lb) = (rel_luminance(a), rel_luminance(b));
    let (hi, lo) = if la > lb { (la, lb) } else { (lb, la) };
    (hi + 0.05) / (lo + 0.05)
}

fn srgb_channels(rgb: u32) -> (f64, f64, f64) {
    (
        ((rgb >> 16) & 0xFF) as f64 / 255.0,
        ((rgb >> 8) & 0xFF) as f64 / 255.0,
        (rgb & 0xFF) as f64 / 255.0,
    )
}

fn pack(r: f64, g: f64, b: f64) -> u32 {
    let q = |x: f64| (x.clamp(0.0, 1.0) * 255.0).round() as u32;
    (q(r) << 16) | (q(g) << 8) | q(b)
}

fn linearize(c: f64) -> f64 {
    if c <= 0.04045 {
        c / 12.92
    } else {
        ((c + 0.055) / 1.055).powf(2.4)
    }
}

fn delinearize(c: f64) -> f64 {
    if c <= 0.0031308 {
        c * 12.92
    } else {
        1.055 * c.powf(1.0 / 2.4) - 0.055
    }
}

fn rel_luminance(rgb: u32) -> f64 {
    let (r, g, b) = srgb_channels(rgb);
    0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
}

/// CIE L* from relative luminance — Material's "tone", within rounding.
pub fn cie_lstar(rgb: u32) -> f64 {
    let y = rel_luminance(rgb);
    if y <= 216.0 / 24389.0 {
        y * 24389.0 / 27.0
    } else {
        116.0 * y.cbrt() - 16.0
    }
}

fn lstar_to_y(lstar: f64) -> f64 {
    if lstar <= 8.0 {
        lstar * 27.0 / 24389.0
    } else {
        ((lstar + 16.0) / 116.0).powi(3)
    }
}

/// Re-light a color to a target L* by scaling in linear space. Darkening
/// preserves chromaticity exactly; lightening blends toward white.
fn set_lstar(rgb: u32, target: f64) -> u32 {
    let y = rel_luminance(rgb).max(1e-6);
    let ty = lstar_to_y(target);
    let (r, g, b) = srgb_channels(rgb);
    let (lr, lg, lb) = (linearize(r), linearize(g), linearize(b));
    if ty <= y {
        let k = ty / y;
        pack(delinearize(lr * k), delinearize(lg * k), delinearize(lb * k))
    } else {
        let k = (ty - y) / (1.0 - y);
        pack(
            delinearize(lr + (1.0 - lr) * k),
            delinearize(lg + (1.0 - lg) * k),
            delinearize(lb + (1.0 - lb) * k),
        )
    }
}

fn shift_lstar(rgb: u32, delta: f64) -> u32 {
    set_lstar(rgb, (cie_lstar(rgb) + delta).clamp(0.0, 100.0))
}

/// Oklab lightness (Björn Ottosson's matrices), for the standalone rule.
pub fn oklab_l(rgb: u32) -> f64 {
    let (r, g, b) = srgb_channels(rgb);
    let (lr, lg, lb) = (linearize(r), linearize(g), linearize(b));
    let l = 0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb;
    let m = 0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb;
    let s = 0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb;
    0.2104542553 * l.cbrt() + 0.7936177850 * m.cbrt() - 0.0040720468 * s.cbrt()
}

fn clamp_oklab_l_max(rgb: u32, max: f64) -> u32 {
    // The search's 20 iterations are far past u8 precision.
    if oklab_l(rgb) <= max {
        return rgb;
    }
    search_oklab(rgb, max)
}

fn clamp_oklab_l_min(rgb: u32, min: f64) -> u32 {
    if oklab_l(rgb) >= min {
        return rgb;
    }
    search_oklab(rgb, min)
}

fn search_oklab(rgb: u32, target: f64) -> u32 {
    let (mut lo, mut hi) = (0.0f64, 100.0f64);
    let mut best = rgb;
    for _ in 0..20 {
        let mid = (lo + hi) / 2.0;
        let candidate = set_lstar(rgb, mid);
        best = candidate;
        if oklab_l(candidate) < target {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    best
}

#[cfg(test)]
mod tests {
    use super::*;

    /// No fill, in either appearance, from any seed, rests inside the
    /// danger band. Swept over the whole hue circle: the failure mode is a
    /// specific (hue, lightness) pair nobody hand-picks.
    #[test]
    fn no_fill_ever_rests_in_the_danger_band() {
        for rgb in sweep() {
            let a = derive(rgb, None, None);
            for (which, fill) in [("light", a.light.fill), ("dark", a.dark.fill)] {
                let l = cie_lstar(fill);
                assert!(
                    !(BAND_LO < l && l < BAND_HI),
                    "kaya: seed {rgb:06x} produced a {which} fill {fill:06x} at \
                     L* {l:.1}, inside the {BAND_LO}..{BAND_HI} band where the \
                     platforms' foreground rules disagree"
                );
            }
        }
    }

    /// SwiftUI's luminance-0.5 flip and Material's tone-60 flip give
    /// the same answer as on_fill on every fill kaya produces.
    #[test]
    fn on_fill_agrees_with_both_platform_rules_on_every_produced_fill() {
        for rgb in sweep() {
            let a = derive(rgb, None, None);
            for d in [a.light, a.dark] {
                let swiftui = if rel_luminance(d.fill) < 0.5 { 0xFFFFFF } else { 0x000000 };
                let material = if cie_lstar(d.fill) < 60.0 { 0xFFFFFF } else { 0x000000 };
                assert_eq!(d.on_fill, swiftui, "fill {:06x} vs the SwiftUI rule", d.fill);
                assert_eq!(d.on_fill, material, "fill {:06x} vs the Material rule", d.fill);
            }
        }
    }

    /// libadwaita's rule: at most 0.5 Oklab L in light, at least 0.85 in
    /// dark (small tolerance for u8 quantization).
    #[test]
    fn standalone_obeys_the_libadwaita_clamp() {
        for rgb in sweep() {
            let a = derive(rgb, None, None);
            assert!(
                oklab_l(a.light.standalone) <= 0.5 + 0.01,
                "light standalone {:06x} above the clamp",
                a.light.standalone
            );
            assert!(
                oklab_l(a.dark.standalone) >= 0.85 - 0.01,
                "dark standalone {:06x} below the clamp",
                a.dark.standalone
            );
        }
    }

    /// An authored per-appearance override is still clamped.
    #[test]
    fn overrides_are_clamped_too() {
        // #76B9ED is the research's named failure: L* ~71, mid-band.
        let a = derive(0x224488, Some(0x76B9ED), Some(0x76B9ED));
        for (which, fill) in [("light", a.light.fill), ("dark", a.dark.fill)] {
            let l = cie_lstar(fill);
            assert!(
                !(BAND_LO < l && l < BAND_HI),
                "{which} override fill {fill:06x} rests in the band at L* {l:.1}"
            );
        }
    }

    /// Grey has no hue to preserve and must still derive cleanly: the
    /// division-by-luminance path has a 1e-6 floor, so no NaN.
    #[test]
    fn achromatic_and_extreme_seeds_derive() {
        for rgb in [0x000000, 0xFFFFFF, 0x808080, 0x000001] {
            let a = derive(rgb, None, None);
            assert!(a.light.on_fill == 0xFFFFFF || a.light.on_fill == 0x000000);
            assert!(a.dark.on_fill == 0xFFFFFF || a.dark.on_fill == 0x000000);
        }
    }

    /// 8 of 9 GNOME accents and both Apple blues take white — the
    /// empirical anchor for the on_fill threshold.
    #[test]
    fn the_platform_pairings_reproduce() {
        // libadwaita 1.7 accent-bg values: blue, teal, green, orange,
        // red, pink, purple, slate.
        let white_takers = [
            0x3584E4, 0x2190A4, 0x3A944A, 0xED5B00, 0xE62D42, 0xD56199, 0x9141AC, 0x6F8396,
        ];
        for rgb in white_takers {
            assert_eq!(
                derive(rgb, None, None).light.on_fill,
                0xFFFFFF,
                "{rgb:06x} should take white"
            );
        }
        // Adwaita yellow, the one raw value that takes black: kaya's
        // clamp drops its fill below L* 60, so here it takes white.
        assert_eq!(derive(0xC88800, None, None).light.on_fill, 0xFFFFFF);
        // Apple's two blues (light/dark system blue).
        assert_eq!(derive(0x007AFF, None, None).light.on_fill, 0xFFFFFF);
        assert_eq!(derive(0x0A84FF, None, None).light.on_fill, 0xFFFFFF);
    }

    /// docs/styling-pass-plan.md Y2: from any colour, the dark top passes
    /// 4.5:1 for white text and the light top for black, a colour already
    /// inside both clamps is untouched, and the dark top keeps its hue.
    #[test]
    fn gradient_tops_hold_the_text_contrast_and_the_hue() {
        for rgb in sweep() {
            let (light, dark) = gradient_tops(rgb);
            assert!(
                contrast_ratio(dark, 0xFFFFFF) >= 4.5,
                "{rgb:06x}: dark top {dark:06x} gives white {:.2}:1",
                contrast_ratio(dark, 0xFFFFFF)
            );
            assert!(
                contrast_ratio(light, 0x000000) >= 4.5,
                "{rgb:06x}: light top {light:06x} gives black {:.2}:1",
                contrast_ratio(light, 0x000000)
            );
            let l = cie_lstar(rgb);
            if l <= GRADIENT_DARK_MAX_LSTAR {
                assert_eq!(dark, rgb, "{rgb:06x} is dark enough already");
            }
            if l >= GRADIENT_LIGHT_MIN_LSTAR {
                assert_eq!(light, rgb, "{rgb:06x} is light enough already");
            }
            let (r, g, b) = srgb_channels(rgb);
            let chroma = r.max(g).max(b) - r.min(g).min(b);
            if chroma > 0.3 && cie_lstar(dark) > 20.0 {
                let hue = |c: u32| {
                    let (r, g, b) = srgb_channels(c);
                    let (lr, lg, lb) = (linearize(r), linearize(g), linearize(b));
                    let sum = lr + lg + lb;
                    (lr / sum, lg / sum)
                };
                let (a, b2) = (hue(rgb), hue(dark));
                assert!(
                    (a.0 - b2.0).abs() < 0.02 && (a.1 - b2.1).abs() < 0.02,
                    "{rgb:06x} -> {dark:06x} moved its chromaticity {a:?} -> {b2:?}"
                );
            }
        }
    }

    /// docs/styling-pass-plan.md Y2 and docs/media-player-plan.md M15's first
    /// 2026-10-18 ruling: the light top is the seed lifted to the floor, not
    /// past it, at the seed's Oklab hue and chroma, giving chroma up only
    /// where the sRGB gamut ends, so a rose stays a pale rose.
    #[test]
    fn the_light_top_keeps_the_seeds_hue_and_chroma() {
        let polar = |c: u32| {
            let (_, a, b) = oklab(c);
            (a.hypot(b), b.atan2(a).to_degrees())
        };
        let on_gamut_edge = |c: u32| {
            let ch = [(c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF];
            ch.iter().any(|&v| v <= 1 || v >= 254)
        };
        let mut checked = 0;
        for rgb in sweep() {
            if cie_lstar(rgb) >= GRADIENT_LIGHT_MIN_LSTAR {
                continue;
            }
            let (light, _) = gradient_tops(rgb);
            let l = cie_lstar(light);
            assert!(l < GRADIENT_LIGHT_MIN_LSTAR + 1.5, "{rgb:06x}: light top {light:06x} at L* {l:.2}, lifted past the floor");
            let ((c0, h0), (c1, h1)) = (polar(rgb), polar(light));
            assert!(
                c1 >= c0 - 0.006 || on_gamut_edge(light),
                "{rgb:06x}: light top {light:06x} gave up chroma {c0:.3} -> {c1:.3} inside the gamut"
            );
            if c0 > 0.03 && c1 > 0.03 {
                let dh = ((h1 - h0 + 540.0) % 360.0 - 180.0).abs();
                assert!(dh < 4.0, "{rgb:06x}: light top {light:06x} moved its hue {h0:.1} -> {h1:.1}");
                checked += 1;
            }
        }
        assert!(checked > 300, "the hue clause read {checked} seeds");
        let rose = 0x673946;
        let (light, _) = gradient_tops(rose);
        let ((c0, _), (c1, _)) = (polar(rose), polar(light));
        assert!(c1 >= c0 - 0.006 && c1 > 0.05, "{rose:06x} -> {light:06x}: chroma {c0:.3} -> {c1:.3}, a grey");
    }

    /// The mid-stops hold the ratio too: an sRGB mix toward the mac's dark
    /// ground never brightens past its brighter end (§7's 11.6:1 to 15.2:1).
    #[test]
    fn gradient_mid_stops_hold_white_text() {
        let ground = 0x1E1E1E_u32;
        for rgb in sweep() {
            let (_, dark) = gradient_tops(rgb);
            let (r0, g0, b0) = srgb_channels(dark);
            let (r1, g1, b1) = srgb_channels(ground);
            for t in [0.25, 0.5, 0.75] {
                let mix = pack(r0 + (r1 - r0) * t, g0 + (g1 - g0) * t, b0 + (b1 - b0) * t);
                assert!(contrast_ratio(mix, 0xFFFFFF) >= 4.5, "{rgb:06x} mix {t} {mix:06x}");
            }
        }
        assert_eq!(gradient_tops(0x5B2A86).1, 0x5B2A86);
    }

    /// 12 hues x 3 saturations x 20 lightness steps, plus the u8 corners.
    fn sweep() -> Vec<u32> {
        let mut out = vec![0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF];
        for h in 0..12 {
            for s in [0.25, 0.6, 1.0] {
                for v in 1..=20 {
                    out.push(hsv(h as f64 * 30.0, s, v as f64 / 20.0));
                }
            }
        }
        out
    }

    fn hsv(h: f64, s: f64, v: f64) -> u32 {
        let c = v * s;
        let x = c * (1.0 - ((h / 60.0) % 2.0 - 1.0).abs());
        let m = v - c;
        let (r, g, b) = match (h / 60.0) as u32 % 6 {
            0 => (c, x, 0.0),
            1 => (x, c, 0.0),
            2 => (0.0, c, x),
            3 => (0.0, x, c),
            4 => (x, 0.0, c),
            _ => (c, 0.0, x),
        };
        pack(r + m, g + m, b + m)
    }
}
