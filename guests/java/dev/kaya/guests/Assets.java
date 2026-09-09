package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The assets scene from the JVM — guests/rust/assets.rs,
 * tools/scenes/assets.steps.
 */
public final class Assets {
    /** Deliberately absent, and a LEGAL name: the answer is the census sentence. */
    private static final String MISSING = "icons/nope.png";

    private static final String MARK = "icons/kaya-mark.png";

    /**
     * SCENERY, and deliberately tiny: an image widget's intrinsic size drives
     * layout and the DECLARED mark is a user-supplied source of any size
     * (the images/ family's README). The mark is still opened.
     */
    private static final String PICTURE = "images/a11y-logo.png";

    /** 111400 bytes, so a reader that truncated into a fixed buffer shows here. */
    private static final String FONT = "fonts/sora-wght.ttf";

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0).title("assets").size(480.0, 360.0);

            try (KayaApp.Asset mark = KayaApp.asset(MARK);
                    KayaApp.Asset picture = KayaApp.asset(PICTURE);
                    KayaApp.Asset font = KayaApp.asset(FONT)) {
                String census = firstLine(KayaApp.assetMissSentence(MISSING));
                String complaint = KayaApp.assetMissSentence(FONT);
                String verdict = complaint.isEmpty() ? "no complaint" : firstLine(complaint);

                KayaApp.Signal<String> title = tx.signal("assets");
                KayaApp.Signal<String> found = tx.signal(census);
                // Concatenation, not String.format: compared byte-for-byte
                // against eight other languages, with no locale in the contract.
                KayaApp.Signal<String> sizes = tx.signal(
                        MARK + (mark.bytes().length > 0 ? " present, " : " missing, ")
                                + FONT + ": " + font.bytes().length + " bytes, " + verdict);

                tx.mount(tx.column(() -> {
                    tx.label(title); // label#0
                    tx.image(picture.bytes()); // image#0
                    tx.label(found); // label#1
                    tx.label(sizes); // label#2
                }));
            }
        });

        app.dispatchLoop();
    }

    private static String firstLine(String sentence) {
        int at = sentence.indexOf('\n');
        return at < 0 ? sentence : sentence.substring(0, at);
    }

    private Assets() {}
}
