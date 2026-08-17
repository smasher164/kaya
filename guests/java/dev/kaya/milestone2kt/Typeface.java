package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The typeface conformance scene from the JVM (docs/styling-plan.md
 * Slice 2b): the brand typeface swaps the FAMILY and leaves the
 * platform's ramp alone.
 *
 * <p>One call is the whole surface — a family name, plus the
 * per-platform rows a lane needs — and everything after it is ordinary
 * widgets, which is the claim the scene makes: a typeface is chrome, so
 * the field still takes text and the button still fires. What it does
 * NOT do is name a size anywhere. Sizes, weights and metrics stay the
 * platform's; the role tier is what carries emphasis ({@code
 * Role.HEADING} on the title label below), and that is exactly what
 * makes a family swap safe.
 *
 * <p>WHY A BUNDLED FONT, and why no per-platform row: the reasoning is
 * in guests/rust/typeface.rs's doc comment, which is the canonical note
 * for this scene. In short, the scene requests the VENDORED font's bytes
 * so the resolved family is one string on every lane and no platform's
 * fallback can equal it. The {@code font} argument of the three-argument
 * {@code brandTypeface} is Java's spelling of the blob form; the {@code
 * platforms} map is what a name-based app would reach for instead, and
 * this scene needs none.
 *
 * <p>The byte-frozen contract is tools/scenes/typeface.steps.
 */
final class Typeface {
    // The fold: widget-owned state arrives as occurrences, and the app's
    // copy is this field rather than a widget read.
    private static String draft = "";

    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            // BEFORE THE FIRST MOUNT, per the set-once wall: brand is
            // identity, not state, and a backend never sees a typeface
            // it would have to un-apply.
            //
            // THE VENDORED BYTES, then the family they carry: the blob
            // registers with the platform's app-font machinery and the
            // "Sora" request resolves to it — register-then-resolve, the
            // same call a brand book's licensed font would make.
            //
            // Files.readAllBytes(Paths.get(..)), not Path.of or
            // InputStream.readAllBytes: this guest is compiled for
            // Android too, where the modules here set minSdk 26 — java.nio
            // .file arrived at 26, while Path.of needs 34 and the stream
            // overload 33.
            String fontPath = System.getenv("KAYA_FONT_FILE");
            if (fontPath == null || fontPath.isEmpty()) {
                fontPath = "guests/assets/fonts/sora-wght.ttf";
            }
            byte[] font;
            try {
                font = java.nio.file.Files.readAllBytes(
                        java.nio.file.Paths.get(fontPath));
            } catch (java.io.IOException e) {
                throw new IllegalStateException(
                        "kaya: the typeface scene needs the vendored font at "
                                + fontPath + " (set KAYA_FONT_FILE or run from"
                                + " the repo root): " + e, e);
            }
            tx.brandTypeface("Sora", null, font);
            tx.window(0).title("typeface").size(480.0, 360.0);
            KayaApp.Signal<String> heading = tx.signal("typeface");
            KayaApp.Signal<String> status = tx.signal("ready");

            tx.mount(tx.column(() -> {
                // The heading's text style OVERRIDES the root font, so
                // this label is the one a root-only lowering leaves in
                // the system face. expect_ax resolves it through its
                // authored id, the a11y scene's discipline.
                tx.label(heading).role(KayaApp.Role.HEADING).a11yId("title"); // label#0
                tx.label(status); // label#1
                // A FIELD AND A TEXTAREA, because they are the two views
                // the observation reads (NSTextField and NSTextView on
                // this platform) and they arrive by DIFFERENT routes:
                // the field inherits the root font, the textarea names
                // its own ramp rung and takes the swap explicitly. A
                // scene with one of them could not tell a half-applied
                // lowering from a whole one.
                tx.entry((t, text) -> draft = text); // entry#0
                tx.textarea(); // textarea#0
                tx.button("Go", t -> t.write(status, "clicked " + draft)); // button#0
            }));
        });

        app.dispatchLoop();
    }

    private Typeface() {}
}
