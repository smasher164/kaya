package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The adaptive conformance scene from the JVM
 * (KAYA_SELFTEST=adaptive) — see guests/rust/adaptive.rs for the
 * rationale and tools/scenes/adaptive.steps for the byte-frozen
 * contract. row@dash flips by a HANDLER (D2's user-driven toggle);
 * row@narrow carries the DECLARED breakpoint (D3), which the handler
 * never touches.
 */
public final class Adaptive {
    private static boolean vertical;

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            // Explicit size: the desktop start must sit ABOVE the
            // breakpoint's threshold so the scene's resize half crosses
            // it both ways deterministically.
            tx.window(0).title("adaptive").size(900.0, 600.0);
            KayaApp.Signal<String> alpha = tx.signal("alpha");
            KayaApp.Signal<String> longer = tx.signal("a longer label");
            KayaApp.Signal<String> steady = tx.signal("steady");

            // Java lambdas cannot assign captured locals, so a handle
            // declared inside a container body comes back out through a
            // one-slot array.
            KayaApp.Widget[] dash = new KayaApp.Widget[1];

            tx.mount(tx.column(() -> {
                dash[0] = tx.row(() -> { // row#0: the flip subject.
                    tx.label(alpha); // label#0
                    tx.label(longer); // label#1
                }).a11yId("dash");
                // column#1: the control group — its axis answers the
                // creation kind's own and never moves.
                tx.column(() -> {
                    tx.label(steady); // label#2
                }).a11yId("steady");
                tx.button("flip", t -> { // button#0
                    vertical = !vertical;
                    t.setAxis(dash[0],
                        vertical ? KayaApp.Axis.VERTICAL : KayaApp.Axis.HORIZONTAL);
                });
                // row#1: the BREAKPOINT subject (D3) — declared data,
                // core-evaluated.
                tx.row(() -> {
                    KayaApp.Signal<String> one = tx.signal("one");
                    KayaApp.Signal<String> two = tx.signal("a wider two");
                    tx.label(one); // label#3
                    tx.label(two); // label#4
                }).a11yId("narrow").stackWhen(KayaApp.SizeClass.COMPACT);
            }));
            return null;
        });

        app.dispatchLoop();
    }

    private Adaptive() {}
}
