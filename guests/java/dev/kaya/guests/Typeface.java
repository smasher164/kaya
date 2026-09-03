package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The typeface scene from the JVM — guests/rust/typeface.rs,
 * tools/scenes/typeface.steps.
 */
public final class Typeface {
    private static String draft = "";

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            // BEFORE THE FIRST MOUNT, per the set-once wall; the close is safe
            // once brandTypeface has registered the bytes.
            try (KayaApp.Asset font = KayaApp.asset("fonts/sora-wght.ttf")) {
                tx.brandTypeface("Sora", null, font);
            }
            tx.window(0).title("typeface").size(480.0, 360.0);
            KayaApp.Signal<String> heading = tx.signal("typeface");
            KayaApp.Signal<String> status = tx.signal("ready");

            tx.mount(tx.column(() -> {
                // The heading's text style OVERRIDES the root font: a root-only
                // lowering leaves this label in the system face.
                tx.label(heading).role(KayaApp.Role.HEADING).a11yId("title"); // label#0
                tx.label(status); // label#1
                // A FIELD AND A TEXTAREA, because they take the swap by
                // DIFFERENT routes.
                tx.entry((t, text) -> draft = text); // entry#0
                tx.textarea(); // textarea#0
                tx.button("Go", t -> t.write(status, "clicked " + draft)); // button#0
            }));
        });

        app.dispatchLoop();
    }

    private Typeface() {}
}
