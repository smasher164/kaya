package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The safearea scene from the JVM — guests/rust/safearea.rs,
 * tools/scenes/safearea.steps (docs/safe-area-plan.md A3, A8).
 */
public final class Safearea {
    private static final KayaApp.Viewbox GROUND = new KayaApp.Viewbox(300.0, 200.0);

    private static void ground(KayaApp.Draw d, KayaApp.Viewbox size) {
        d.moveTo(0.0, 0.0)
            .lineTo(size.w(), 0.0)
            .lineTo(size.w(), size.h())
            .lineTo(0.0, size.h())
            .close()
            .fill(KayaApp.Paint.SERIES_FILL, KayaApp.FillRule.NONZERO);
    }

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0).title("safearea").size(420.0, 640.0);
            KayaApp.Signal<String> caption = tx.signal("inset 16");

            tx.mount(tx.column(col -> {
                try (KayaApp.Asset photo = KayaApp.asset("images/photo.jpg")) {
                    tx.image(photo).maxHeight(160.0).bleed().a11yId("picture").a11yLabel("Photo");
                }
                tx.label(caption).a11yId("caption");
                tx.button("No inset", t -> {
                    t.window(0).inset(0.0);
                    t.write(caption, "inset 0");
                }).a11yId("inset");
                tx.button("Fullscreen", t -> {
                    t.window(0).fullscreen(true);
                    t.write(caption, "fullscreen");
                }).a11yId("full");
                tx.canvas(GROUND).grow(1.0).bleed()
                        .a11yId("ground").a11yLabel("Ground")
                        .onDraw((d, size) -> ground(d, size));
            }));
        });

        app.dispatchLoop();
    }

    private Safearea() {}
}
