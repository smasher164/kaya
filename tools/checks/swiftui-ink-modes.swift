// THE INK VERB'S PER-MODE COMPARE, measured — compiled INTO the
// interpreter's own module by tools/check-canvas-blit.py and run as an
// executable.
//
// WHY A PROBE AND NOT A LEG. `expect_ink`'s answer names the appearance
// the HOST is in, so one mac leg exercises exactly one of the two arms:
// on a light-mode machine the dark arm is never evaluated, and on a
// dark-mode machine the light one is not. Every lane before 2026-08-27
// ran light, which is precisely how a light-only frozen string reached a
// dark host and reddened a scene nobody had touched. Forcing the host's
// appearance to cover the other arm would write the user's own system
// settings, so both arms are driven HERE, against the interpreter's real
// kayaInkForMode / kayaInkMatches, on whatever machine runs the gate.
//
// The string below is tools/scenes/canvas.steps' own, byte for byte; the
// per-mode values are the core's, derived by canvas.rs's
// the_scene_probe_points_are_opaque_and_pinned.

import Foundation

@main
enum KayaInkModesProbe {
    /// The scene's frozen expectation, verbatim.
    static let want = "light FFFFFF/D2E3F7 dark 16181C/2B3B4F"

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        var failures = 0

        func expect(_ name: String, _ got: Bool) {
            if !got {
                print("swiftui-ink-modes: FAIL — \(name)")
                failures += 1
            }
        }
        func matches(_ got: String, _ why: String) {
            expect("\(got) must MATCH \(want) — \(why)", kayaInkMatches(got, want))
        }
        func refuses(_ got: String, _ why: String) {
            expect("\(got) must NOT match \(want) — \(why)", !kayaInkMatches(got, want))
        }

        // --- The selector itself. ---------------------------------------
        expect("kayaInkForMode finds the light half",
            kayaInkForMode(want, "light") == "FFFFFF/D2E3F7")
        expect("kayaInkForMode finds the dark half",
            kayaInkForMode(want, "dark") == "16181C/2B3B4F")
        expect("kayaInkForMode has no answer for a mode the string omits",
            kayaInkForMode(want, "sepia") == nil)

        // --- Both modes, exact. -----------------------------------------
        matches("light FFFFFF/D2E3F7", "the core's own light bytes")
        matches("dark 16181C/2B3B4F", "the core's own dark bytes")

        // --- Both modes, the MEASURED window reads. ---------------------
        // A macOS window's backing store carries the display's profile,
        // so the sampled bytes sit within ±1 of the core's.
        matches("light FFFFFF/D2E2F7", "the mac's measured light read (2026-08-26)")
        matches("dark 17181D/2B3A4F", "the mac's measured dark read (2026-08-27)")

        // --- Both modes, every channel at the tolerance edge. -----------
        for got in [
            "light FEFFFF/D2E3F7", "light FFFEFF/D2E3F7", "light FFFFFE/D2E3F7",
            "light FFFFFF/D1E3F7", "light FFFFFF/D2E2F7", "light FFFFFF/D2E3F6",
        ] {
            matches(got, "one unit away in light")
        }
        for got in [
            "dark 15181C/2B3B4F", "dark 16171C/2B3B4F", "dark 16181B/2B3B4F",
            "dark 16181C/2A3B4F", "dark 16181C/2B3A4F", "dark 16181C/2B3B4E",
        ] {
            matches(got, "one unit away in dark")
        }

        // --- Both modes, one past the edge. -----------------------------
        for got in [
            "light FDFFFF/D2E3F7", "light FFFFFF/D0E3F7", "light FFFFFF/D2E5F7",
        ] {
            refuses(got, "two units away in light")
        }
        for got in [
            "dark 14181C/2B3B4F", "dark 16181C/293B4F", "dark 16181C/2B3D4F",
        ] {
            refuses(got, "two units away in dark")
        }

        // --- THE WRONG MODE'S VALUES, which is the defect that shipped. --
        // Every one of these bytes appears in `want`; only the pairing is
        // wrong. A matcher that ignored the mode word, or that compared
        // against whichever half it read first, passes these.
        refuses("dark FFFFFF/D2E3F7",
            "the LIGHT palette measured under a dark appearance — the canvas "
                + "rendering light in a dark window, which is the bug this closes")
        refuses("light 16181C/2B3B4F",
            "the dark palette measured under a light appearance")

        // --- A mode the expectation does not name. ----------------------
        refuses("sepia FFFFFF/D2E3F7", "a mode the string never names")

        // --- Shapes that must reach the failure text whole. -------------
        for got in [
            "<no canvas canvas@chart>", "light FFFFFF", "light FFFFFF/D2E3F7/D2E3F7",
            "light FFFFFF/D2E3F", "light FFFFFF/D2E3FZ", "",
        ] {
            refuses(got, "a diagnostic or malformed answer")
        }

        if failures == 0 {
            print("swiftui-ink-modes: OK — both modes' arms, the two measured "
                + "window reads, both tolerance edges, and the wrong-mode pairing refused")
        }
        exit(failures == 0 ? 0 : 1)
    }
}
