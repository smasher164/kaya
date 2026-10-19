package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaApp.Tint;

/** The grounds scene from the JVM — guests/rust/grounds.rs, tools/scenes/grounds.steps. */
public final class Grounds {
    public static void app() {
        KayaApp app = new KayaApp();
        byte[] art;
        try (KayaApp.Asset a = KayaApp.asset("covers/cover-600.jpg")) {
            art = a.bytes();
        }
        KayaApp.Color colour = KayaApp.imageDominant(art).orElseThrow(
                () -> new IllegalStateException("the cover decodes"));
        app.build(tx -> {
            tx.window(0).title("grounds").size(480.0, 560.0).inset(0.0);
            KayaApp.Signal<String> title = tx.signal("Kind of Blue");
            KayaApp.Signal<String> artist = tx.signal("Miles Davis · 1959");
            KayaApp.Signal<String> name = tx.signal("Miles Davis");
            KayaApp.Signal<String> plain = tx.signal("Plain");
            tx.mount(tx.column(root -> {
                tx.column(hero -> {
                    tx.row(scrim -> {
                        tx.label(name);
                    }).filled(Tint.OVERLAY).a11yId("scrim");
                }).inset(24).groundImage(art).a11yId("hero");
                tx.column(header -> {
                    tx.heading(title).a11yId("title");
                    tx.caption(artist);
                }).inset(24).groundGradient(colour).a11yId("header");
                tx.column(column -> {
                    tx.label(plain);
                }).inset(24).a11yId("plain");
            }).spacing(12));
            return null;
        });
        app.dispatchLoop();
    }

    private Grounds() {}
}
