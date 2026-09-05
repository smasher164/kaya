package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;

import java.util.Locale;

/**
 * The sliders scene from the JVM — guests/rust/sliders.rs,
 * tools/scenes/sliders.steps, docs/slider-plan.md.
 */
public final class Sliders {
    @KayaGen(key = "String")
    record Track(String name, double level) {}

    // The harness's own slider spelling (crates/kaya/src/harness.rs).
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
            KayaApp.Signal<String> levelText = tx.signal("value: 50");
            KayaApp.Signal<String> commitText = tx.signal("commits: 0");
            KayaApp.Signal<String> volumeText = tx.signal("volume: 0.5");
            KayaApp.Signal<String> rowText = tx.signal("row: none");
            KayaApp.Signal<Double> pos = tx.signal(50.0);
            var tracks = TrackKaya.collection(tx);

            tx.mount(tx.column(() -> {
                tx.label(levelText); // label#0
                tx.label(commitText); // label#1
                tx.label(volumeText); // label#2
                tx.label(rowText); // label#3
                KayaApp.Widget master = tx.slider(0.0, 100.0, pos,
                                (t, v) -> t.write(levelText, "value: " + spelled(v)))
                        .step(5.0).tickSpacing(25.0)
                        .a11yId("master").a11yLabel("Level"); // slider#0
                app.onValueCommitted(master, (t, v) -> {
                    commits[0]++;
                    t.write(commitText, "commits: " + commits[0]);
                });
                tx.slider(0.0, 1.0, 0.5,
                                (t, v) -> t.write(volumeText, "volume: " + spelled(v)))
                        .tickSpacing(0.25).a11yLabel("Volume"); // slider#1
                // A programmatic write must NOT echo a value or a commit.
                tx.button("reset", t -> t.write(pos, 25.0)); // button#0
                for (var row : TrackKaya.rows(tx, tracks)) {
                    row.label(row.name);
                    KayaApp.Node level = row.slider(0.0, 100.0, row.level);
                    row.setStep(level, 10.0);
                    row.setA11yId(level, "level");
                    app.onValueCommitted(level, (t, keys, v) ->
                            t.write(rowText, "row " + keys.get(0) + ": " + spelled(v)));
                }
            }));

            tracks.insert(tx, "a", new Track("a", 70.0));
            tracks.insert(tx, "b", new Track("b", 20.0));
            return null;
        });

        app.dispatchLoop();
    }

    private Sliders() {}
}
