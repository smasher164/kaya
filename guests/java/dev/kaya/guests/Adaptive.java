package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The adaptive scene from the JVM — guests/rust/adaptive.rs,
 * tools/scenes/adaptive.steps.
 */
public final class Adaptive {
    private static boolean vertical;

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            // Above the breakpoint, so the resize half crosses it both ways.
            tx.window(0).title("adaptive").size(900.0, 600.0);
            KayaApp.Signal<String> alpha = tx.signal("alpha");
            KayaApp.Signal<String> longer = tx.signal("a longer label");
            KayaApp.Signal<String> steady = tx.signal("steady");

            // Java lambdas cannot assign captured locals.
            KayaApp.Widget[] dash = new KayaApp.Widget[1];

            tx.mount(tx.column(() -> {
                dash[0] = tx.row(() -> { // row#0: the flip subject.
                    tx.label(alpha); // label#0
                    tx.label(longer); // label#1
                }).a11yId("dash");
                // column#1: the control group, whose axis never moves.
                tx.column(() -> {
                    tx.label(steady); // label#2
                }).a11yId("steady");
                tx.button("flip", t -> { // button#0
                    vertical = !vertical;
                    t.setAxis(dash[0],
                        vertical ? KayaApp.Axis.VERTICAL : KayaApp.Axis.HORIZONTAL);
                });
                // row#1: the breakpoint subject, which no handler touches.
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
