package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The assets conformance scene from the JVM (docs/assets-plan.md,
 * ratified 2026-08-18). The byte-frozen contract is
 * tools/scenes/assets.steps.
 *
 * <p>THIS ONE PROVES THE BYTES. {@code asset(name)} has two redemptions
 * and the typeface scene already covers the other — a font whose bytes go
 * from the core's read straight to the platform and never enter this
 * JVM's heap. Here the guest IS the consumer: it copies the mark out with
 * {@code bytes()} and hands the array to an image, and the platform's own
 * decoder answers 64x64 off the real view.
 *
 * <p>THE MISS IS A QUESTION, NOT A {@code catch}.
 * {@code assetMissSentence} answers the same sentence {@code asset} would
 * throw with, without throwing, and that is the only shape nine languages
 * share: Swift's raise traps rather than unwinding, so a Swift sibling
 * cannot catch its own miss at all.
 *
 * <p>LINE 1 ONLY. Line 2 of that sentence names the place the core
 * resolved and the route that chose it, which a bundle, a device
 * directory and a repo checkout spell three different ways; line 1 is the
 * same everywhere, so it is the line a scene can freeze.
 */
final class Assets {
    /** The one that is deliberately not there — a LEGAL name, so what
     * comes back is the census sentence and not a name-fault one. */
    private static final String MISSING = "icons/nope.png";

    /** The one the mark is under, and the one the census must list. */
    private static final String MARK = "icons/kaya-mark.png";

    /** The large one: 111400 bytes, so a reader that truncated into a
     * fixed buffer shows up here rather than passing quietly. */
    private static final String FONT = "fonts/sora-wght.ttf";

    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0).title("assets").size(480.0, 360.0);

            try (KayaApp.Asset mark = KayaApp.asset(MARK);
                    KayaApp.Asset font = KayaApp.asset(FONT)) {
                String census = firstLine(KayaApp.assetMissSentence(MISSING));
                String complaint = KayaApp.assetMissSentence(FONT);
                String verdict = complaint.isEmpty() ? "no complaint" : firstLine(complaint);

                KayaApp.Signal<String> title = tx.signal("assets");
                KayaApp.Signal<String> found = tx.signal(census);
                // Concatenation rather than String.format: the scene
                // compares this string byte-for-byte against seven other
                // languages, and a default locale is not part of that
                // contract. Integer.toString has no locale to consult.
                KayaApp.Signal<String> sizes = tx.signal(
                        FONT + ": " + font.bytes().length + " bytes, " + verdict);

                tx.mount(tx.column(() -> {
                    tx.label(title); // label#0
                    // THE BYTES, not the blob redemption: this scene is
                    // the consumer, so what reaches the decoder is what
                    // bytes() handed back.
                    tx.image(mark.bytes()); // image#0
                    tx.label(found); // label#1
                    tx.label(sizes); // label#2
                }));
            }
        });

        // Nothing to drive: every observation is a read of the first mount.
        app.dispatchLoop();
    }

    /** The census half of the sentence. Empty in, empty out. */
    private static String firstLine(String sentence) {
        int at = sentence.indexOf('\n');
        return at < 0 ? sentence : sentence.substring(0, at);
    }

    private Assets() {}
}
