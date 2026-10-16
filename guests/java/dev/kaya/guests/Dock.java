package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaApp.Fit;
import dev.kaya.KayaApp.Shape;

/** The dock scene from the JVM — guests/rust/dock.rs, tools/scenes/dock.steps. */
public final class Dock {
    public static void app() {
        KayaApp app = new KayaApp();
        byte[] art;
        try (KayaApp.Asset a = KayaApp.asset("covers/cover-600.jpg")) {
            art = a.bytes();
        }
        app.build(tx -> {
            KayaApp.Signal<Boolean> playing = tx.signal(true);
            tx.window(0).title("dock").size(720.0, 480.0).dock(40, root -> {
                tx.when(playing, t -> {
                    KayaApp.Node bar = t.row(() -> {
                        KayaApp.Node image = t.image(art);
                        t.setFit(image, Fit.COVER);
                        t.setMaxWidth(image, 40);
                        t.setMaxHeight(image, 40);
                        t.setShape(image, Shape.ROUNDED);
                        t.column(() -> {
                            t.label("Blue in Green");
                            t.caption("Miles Davis");
                        });
                        t.setA11yId(t.slider(0.0, 1.0, 0.4), "progress");
                        t.setA11yId(t.button("Pause"), "pause");
                    });
                    t.setA11yId(bar, "bar");
                });
            });
            KayaApp.Signal<String> library = tx.signal("Library");
            tx.mount(tx.column(root -> {
                tx.label(library);
                tx.button("stop", t -> t.write(playing, false)).a11yId("stop");
                tx.button("play", t -> t.write(playing, true)).a11yId("play");
            }));
            return null;
        });
        app.dispatchLoop();
    }

    private Dock() {}
}
