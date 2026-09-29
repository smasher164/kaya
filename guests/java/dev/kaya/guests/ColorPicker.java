package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaApp.Color;
import dev.kaya.KayaGen;

/**
 * The colour picker scene from the JVM — guests/rust/colorpicker.rs,
 * tools/scenes/colorpicker.steps, docs/color-picker-plan.md.
 */
public final class ColorPicker {
    @KayaGen(key = "String")
    record Swatch(String name, Color fill) {}

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            KayaApp.Signal<String> titleText = tx.signal("color: none");
            KayaApp.Signal<String> glazeText = tx.signal("alpha: none");
            KayaApp.Signal<String> rowText = tx.signal("row: none");
            KayaApp.Signal<Color> titleColor = tx.signal(Color.fromHex(0x336699FF));
            var swatches = SwatchKaya.collection(tx);

            tx.mount(tx.column(col -> {
                tx.label(titleText);
                tx.label(glazeText);
                tx.label(rowText);
                tx.colorPicker(titleColor, (t, c) -> t.write(titleText, "color: " + c))
                        .a11yId("title").a11yLabel("Title colour");
                tx.colorPicker(Color.fromHex(0x26A269FF), (t, c) -> t.write(glazeText, "alpha: " + c))
                        .alpha(true).a11yLabel("Glaze");
                // Must NOT come back as a title colour.
                tx.button("reset", t -> t.write(titleColor, Color.fromHex(0x3584E4FF)));
                for (var row : SwatchKaya.rows(tx, swatches)) {
                    row.label(row.name);
                    row.setA11yId(row.colorPicker(row.fill, (t, key, c) ->
                            t.write(rowText, "row " + key + ": " + c)), "fill");
                }
            }));

            swatches.insert(tx, "a", new Swatch("a", Color.fromHex(0xE66100FF)));
            swatches.insert(tx, "b", new Swatch("b", Color.fromHex(0xF6D32DFF)));
            return null;
        });

        app.dispatchLoop();
    }

    private ColorPicker() {}
}
