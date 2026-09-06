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
                // grid@sheet: three columns regular, one compact (D6.2).
                tx.grid(3, () -> {
                    for (String text : new String[] {"c1", "c2", "c3", "c4", "c5", "c6"}) {
                        tx.label(tx.signal(text)); // label#5..#10
                    }
                }).a11yId("sheet").columnsWhen(KayaApp.SizeClass.COMPACT, 1);
                // grid@fit: no count, a 240-point floor, the WIDTH decides
                // (docs/layout-knobs-plan.md §3). Buttons, so the label
                // ordinals above stay put.
                tx.grid(3, () -> {
                    tx.button("f1"); // button#1
                    tx.button("f2");
                    tx.button("f3");
                }).columnsAuto(240.0).a11yId("fit");
            }));
            return null;
        });

        app.dispatchLoop();
    }

    private Adaptive() {}
}
