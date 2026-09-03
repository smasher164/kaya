package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The textarea conformance scene from the JVM. See
 * guests/rust/textarea.rs and tools/scenes/textarea.steps.
 */
public final class TextareaScene {
    private record Scene(KayaApp.Signal<String> lines, KayaApp.Widget editor,
            KayaApp.Widget clear) {}

    private static String count(String text) {
        if (text.isEmpty()) {
            return "0 lines";
        }
        int n = text.split("\n", -1).length;
        if (text.endsWith("\n")) {
            n -= 1;
        }
        return n + " lines";
    }

    public static void app() {
        KayaApp app = new KayaApp();

        Scene scene = app.build(tx -> {
            tx.window(0).title("textarea");
            KayaApp.Signal<String> lines = tx.signal("0 lines");

            // Java lambdas cannot assign captured locals, so handles
            // declared inside a container body come back out through
            // one-slot arrays.
            KayaApp.Widget[] editor = new KayaApp.Widget[1];
            KayaApp.Widget[] clear = new KayaApp.Widget[1];
            tx.mount(tx.column(() -> {
                editor[0] = tx.textarea();
                tx.label(lines);
                clear[0] = tx.button("clear");
            }));
            return new Scene(lines, editor[0], clear[0]);
        });

        app.onChange(scene.editor(), (t, text) -> t.write(scene.lines(), count(text)));
        app.onClick(scene.clear(), t -> {
            t.clear(scene.editor());
            t.focus(scene.editor());
        });

        app.dispatchLoop();
    }

    private TextareaScene() {}
}
