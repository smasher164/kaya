package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;

/**
 * The segmented control scene from the JVM — guests/rust/segmented.rs,
 * tools/scenes/segmented.steps, docs/segmented-plan.md §5.
 */
public final class Segmented {
    @KayaGen(key = "String")
    record Habit(String name, double cadence) {}

    private static final String[] PERIODS = {"Day", "Week", "Month"};
    private static final KayaApp.Segment[] VIEWS = {
        new KayaApp.Segment("Info", KayaApp.Symbol.INFO),
        new KayaApp.Segment("Edit", KayaApp.Symbol.EDIT),
    };
    private static final String[] CADENCES = {"Daily", "Weekly"};

    public static void app() {
        KayaApp app = new KayaApp();
        int[] heard = {0};

        app.build(tx -> {
            tx.window(0).title("segmented");
            KayaApp.Signal<Double> period = tx.signal(0.0);
            KayaApp.Signal<String> periodText = tx.signal("period: Day");
            KayaApp.Signal<String> heardText = tx.signal("heard: 0");
            KayaApp.Signal<String> viewText = tx.signal("view: Edit");
            KayaApp.Signal<String> cadenceText = tx.signal("cadence: -");
            var habits = HabitKaya.collection(tx);

            tx.mount(tx.column(col -> {
                tx.segmented(PERIODS, period, (t, index) -> {
                    heard[0]++;
                    t.write(period, (double) index);
                    t.write(periodText, "period: " + PERIODS[index]);
                    t.write(heardText, "heard: " + heard[0]);
                }).a11yId("period").a11yLabel("Period");
                tx.label(periodText);
                tx.label(heardText);
                tx.button("Reset", t -> {
                    t.write(period, 0.0);
                    t.write(periodText, "period: Day");
                }).a11yId("reset");
                tx.segmentedSymbols(VIEWS, 1, (t, index) ->
                        t.write(viewText, "view: " + VIEWS[index].name()))
                        .a11yId("view").a11yLabel("View");
                tx.label(viewText);
                tx.label(cadenceText);
                for (var row : HabitKaya.rows(tx, habits)) {
                    row.label(row.name);
                    KayaApp.Node cadence = row.segmented(CADENCES, row.cadence);
                    row.setA11yId(cadence, "cadence");
                    app.onValueChanged(cadence, (t, keys, v) ->
                            t.write(cadenceText, "cadence " + keys.get(0) + ": "
                                    + CADENCES[(int) v]));
                }
            }));

            habits.insert(tx, "read", new Habit("read", 1.0));
            habits.insert(tx, "walk", new Habit("walk", 0.0));
            return null;
        });

        app.dispatchLoop();
    }

    private Segmented() {}
}
