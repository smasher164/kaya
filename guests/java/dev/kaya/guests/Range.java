package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;

import java.util.Locale;

/**
 * The range scene from the JVM — guests/rust/range.rs,
 * tools/scenes/range.steps, docs/range-plan.md.
 */
public final class Range {
    @KayaGen(key = "String")
    record Clip(String name, double trimIn, double trimOut) {}

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
            KayaApp.Signal<String> liveText = tx.signal("live: 2 8");
            KayaApp.Signal<String> commitText = tx.signal("commits: 0");
            KayaApp.Signal<String> volumeText = tx.signal("volume: 0.25");
            KayaApp.Signal<String> clipText = tx.signal("clip: none");
            KayaApp.Signal<Double> low = tx.signal(2.0);
            KayaApp.Signal<Double> high = tx.signal(8.0);
            var clips = ClipKaya.collection(tx);

            tx.mount(tx.column(col -> {
                tx.label(liveText); // label#0
                tx.label(commitText); // label#1
                tx.label(volumeText); // label#2
                tx.label(clipText); // label#3
                KayaApp.Widget trim = tx.range(0.0, 10.0, low, high,
                                (t, l, h) -> t.write(liveText, "live: " + spelled(l) + " " + spelled(h)))
                        .step(0.5).tickSpacing(1.0).minGap(1.0)
                        .a11yId("trim").a11yLabel("Trim")
                        .lowLabel("In").highLabel("Out"); // range#0
                app.onRangeCommitted(trim, (t, l, h) -> {
                    commits[0]++;
                    t.write(commitText, "commits: " + commits[0] + " at " + spelled(l) + " " + spelled(h));
                });
                tx.range(0.0, 10.0, 4.0, 6.0, null)
                        .step(0.5).tickSpacing(1.0).minGap(0.0).a11yLabel("Tie"); // range#1
                tx.slider(0.0, 10.0, 5.0, null).a11yLabel("Playhead"); // slider#0
                tx.slider(0.0, 1.0, 0.25,
                                (t, v) -> t.write(volumeText, "volume: " + spelled(v)))
                        .step(0.25).axis(KayaApp.Axis.VERTICAL)
                        .a11yId("volume").a11yLabel("Volume"); // slider#1
                // Must NOT come back as a move or a commit.
                tx.button("reset", t -> t.write(low, 1.0)); // button#0
                // Crosses a high thumb the user moved; the core clamps it (docs/range-plan.md §3).
                tx.button("late", t -> t.write(low, 6.0)); // button#1
                for (var row : ClipKaya.rows(tx, clips)) {
                    row.label(row.name);
                    KayaApp.Node clip = row.range(0.0, 10.0, row.trimIn, row.trimOut);
                    row.setStep(clip, 0.5);
                    row.setMinGap(clip, 1.0);
                    row.setA11yId(clip, "clip");
                    app.onRangeCommitted(clip, (t, keys, l, h) ->
                            t.write(clipText, "clip " + keys.get(0) + ": " + spelled(l) + " " + spelled(h)));
                }
            }));

            clips.insert(tx, "a", new Clip("a", 1.0, 4.0));
            clips.insert(tx, "b", new Clip("b", 3.0, 7.0));
            return null;
        });

        app.dispatchLoop();
    }

    private Range() {}
}
