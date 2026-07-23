package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;

/**
 * The textarea conformance scene from the JVM. See
 * guests/rust/textarea.rs and tools/scenes/textarea.steps.
 */
final class TextareaScene {
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

    static void app() {
        KayaApp app = new KayaApp();

        Scene scene = app.build(tx -> {
            tx.windowTitle("textarea");
            KayaApp.Signal<String> lines = tx.signal("0 lines");

            KayaApp.Widget editor;
            KayaApp.Widget clear;
            KayaApp.Widget column = tx.column(() -> {});
            editor = tx.textarea();
            KayaApp.Widget linesLabel = tx.label(lines);
            clear = tx.button("clear");
            tx.addChild(column, editor);
            tx.addChild(column, linesLabel);
            tx.addChild(column, clear);
            tx.mount(column);
            return new Scene(lines, editor, clear);
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
