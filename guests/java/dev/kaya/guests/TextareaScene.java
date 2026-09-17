package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The textarea scene from the JVM — guests/rust/textarea.rs,
 * tools/scenes/textarea.steps.
 */
public final class TextareaScene {
    private record Scene(KayaApp.Signal<String> lines, KayaApp.Widget editor,
            KayaApp.Widget clear) {}

    /** Java lambdas cannot assign captured locals. */
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

            var built = tx.column(col -> {
                KayaApp.Widget editor = tx.textarea();
                tx.label(lines);
                KayaApp.Widget clear = tx.button("clear");
                return new Scene(lines, editor, clear);
            });
            tx.mount(built.id());
            return built.value();
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
