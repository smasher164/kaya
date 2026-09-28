package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The fullscreen scene from the JVM — guests/rust/fullscreen.rs,
 * tools/scenes/fullscreen.steps. The app keeps its own copy of the state: a
 * toggle writes {@code !on}, and the user's door moves the copy through
 * onFullscreenChanged.
 */
public final class Fullscreen {
    public static void app() {
        KayaApp app = new KayaApp();
        boolean[] on = {false};
        int[] pinged = {0};

        app.build(tx -> {
            KayaApp.Signal<String> asked = tx.signal("windowed");
            KayaApp.Signal<String> user = tx.signal("no change from the user");
            KayaApp.Signal<String> pings = tx.signal("pings 0");

            tx.window(0).title("fullscreen").onFullscreenChanged((t, now) -> {
                on[0] = now;
                t.write(user, now ? "the user turned fullscreen on" : "the user turned fullscreen off");
            });

            tx.mount(tx.column(col -> {
                tx.label(asked); // label#0
                tx.label(user); // label#1
                tx.label(pings); // label#2
                tx.button("toggle fullscreen", t -> { // button#0
                    on[0] = !on[0];
                    t.window(0).fullscreen(on[0]);
                    t.write(asked, on[0] ? "asked for fullscreen" : "asked for a window");
                });
                tx.button("ping", t -> { // button#1
                    pinged[0] += 1;
                    t.write(pings, "pings " + pinged[0]);
                });
            }));
        });

        app.dispatchLoop();
    }

    private Fullscreen() {}
}
