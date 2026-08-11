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
            tx.window(0).title("textarea");
            KayaApp.Signal<String> lines = tx.signal("0 lines");

            // Java lambdas cannot assign captured locals, so the two
            // handles the registrations below need come back out of the
            // container body through one-slot arrays (Entry.java's
            // idiom, and Undo.java's). The tally label needs no handle
            // at all: it follows the signal.
            //
            // This scene used to attach its three children by hand — an
            // empty tx.column(() -> {}) and three tx.addChild calls —
            // while the container sugar that parents everything declared
            // in its body sat unused (invariant 5). The same records
            // either way, the same ids in the same order; only each
            // attachment moves, next to the child it attaches. The
            // haskell and ocaml ports were converted in c20b9c2 and this
            // one was missed, because addChild is not a widget-kind
            // spelling and the floor rules of the day read only two
            // carve-out scenes.
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
