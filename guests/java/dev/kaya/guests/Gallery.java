package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The gallery scene from the JVM — guests/rust/gallery.rs,
 * tools/scenes/gallery.steps.
 */
public final class Gallery {
    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            KayaApp.Signal<String> status = tx.signal("urgent: false");
            KayaApp.Signal<String> volume = tx.signal("volume: 50%");
            KayaApp.Signal<Double> pos = tx.signal(0.5);

            tx.mount(tx.column(() -> {
                tx.row(() -> {
                    tx.checkbox("urgent", (t, checked) ->
                            t.write(status, "urgent: " + checked));
                    tx.label(status);
                });
                tx.row(() -> {
                    // Integer percent, so every language's formatting agrees.
                    tx.slider(0.0, 1.0, pos, (t, value) ->
                            t.write(volume, "volume: " + Math.round(value * 100) + "%"));
                    tx.label(volume);
                    // A programmatic write must NOT come back as an occurrence.
                    tx.button("quarter", t -> t.write(pos, 0.25));
                });
                tx.row(() -> {
                    // Invalid bytes on purpose: a decode failure reads 0x0.
                    tx.image(TEST_PNG);
                    tx.image("not an image"
                            .getBytes(java.nio.charset.StandardCharsets.US_ASCII));
                });
            }));
            return null;
        });

        app.dispatchLoop();
    }

    /** A 2x2 RGB PNG, embedded as source. */
    private static final byte[] TEST_PNG = {
        (byte) 137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
        0, 0, 0, 2, 0, 0, 0, 2, 8, 2, 0, 0, 0, (byte) 253, (byte) 212, (byte) 154,
        115, 0, 0, 0, 18, 73, 68, 65, 84, 120, (byte) 156, 99, (byte) 248,
        (byte) 207, (byte) 192, (byte) 192, 0, (byte) 194, 12, (byte) 255,
        (byte) 129, 0, 0, 31, (byte) 238, 5, (byte) 251, 11, (byte) 217, 104,
        (byte) 139, 0, 0, 0, 0, 73, 69, 78, 68, (byte) 174, 66, 96, (byte) 130,
    };

    private Gallery() {}
}
