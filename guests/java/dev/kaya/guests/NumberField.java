package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;

import java.util.Locale;

/**
 * The number field scene from the JVM — guests/rust/numberfield.rs,
 * tools/scenes/numberfield.steps, docs/number-field-plan.md.
 */
public final class NumberField {
    @KayaGen(key = "String")
    record Line(String name, double qty) {}

    // The harness's own value spelling (crates/kaya/src/harness.rs).
    private static String spelled(double v) {
        String s = String.format(Locale.ROOT, "%.6f", v);
        while (s.endsWith("0")) {
            s = s.substring(0, s.length() - 1);
        }
        return s.endsWith(".") ? s.substring(0, s.length() - 1) : s;
    }

    public static void app() {
        KayaApp app = new KayaApp();
        int[] commits = {0};

        app.build(tx -> {
            KayaApp.Signal<String> commitText = tx.signal("commits: 0");
            KayaApp.Signal<String> rowText = tx.signal("row: none");
            KayaApp.Signal<Double> amountValue = tx.signal(0.0);
            var lines = LineKaya.collection(tx);

            tx.mount(tx.column(col -> {
                tx.label(commitText).a11yId("commits");
                tx.label(rowText).a11yId("row");
                tx.numberField(amountValue, (t, v) -> {
                            commits[0]++;
                            t.write(commitText, "commits: " + commits[0]);
                        })
                        .min(0.0).max(100.0).step(0.5)
                        .a11yId("amount").a11yLabel("Amount");
                tx.entry().a11yId("note");
                // A programmatic write must NOT come back as a commit.
                tx.button("forty", t -> t.write(amountValue, 40.0)).a11yId("forty");
                for (var row : LineKaya.rows(tx, lines)) {
                    row.label(row.name);
                    KayaApp.Node qty = row.numberField(row.qty);
                    row.setMin(qty, 0.0);
                    row.setA11yId(qty, "qty");
                    app.onValueCommitted(qty, (t, keys, v) ->
                            t.write(rowText, "row " + keys.get(0) + ": " + spelled(v)));
                }
            }));

            lines.insert(tx, "a", new Line("a", 1.0));
            lines.insert(tx, "b", new Line("b", 2.0));
            return null;
        });

        app.dispatchLoop();
    }

    private NumberField() {}
}
