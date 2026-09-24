package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;

/**
 * The submit scene from the JVM — guests/rust/submit.rs,
 * tools/scenes/submit.steps. Return in an entry, a search field and a
 * {@code submits} textarea publishes the field's text
 * (docs/submit-plan.md); a plain textarea's Return is its newline. The
 * app writes each submit into one label.
 */
public final class Submit {
    @KayaGen(key = "String")
    record SubmitThread(String title) {}

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            var threads = SubmitThreadKaya.collection(tx);
            KayaApp.Signal<String> sent = tx.signal("sent: -");

            tx.mount(tx.column(col -> {
                tx.label(sent).a11yId("sent"); // label#0
                KayaApp.Widget name =
                        tx.entry().placeholder("Name").a11yId("name"); // entry#0
                app.onSubmitted(name, (t, text) -> t.write(sent, "sent: " + text));
                KayaApp.Widget find =
                        tx.search().placeholder("Search").a11yId("find"); // search#0
                app.onSubmitted(find, (t, text) -> t.write(sent, "sent: " + text));
                KayaApp.Widget plain = tx.textarea().a11yId("plain"); // textarea#0
                app.onSubmitted(plain, (t, text) -> t.write(sent, "sent: " + text));
                KayaApp.Widget compose =
                        tx.textarea().submits().a11yId("compose"); // textarea#1
                app.onSubmitted(compose, (t, text) -> t.write(sent, "sent: " + text));
                for (var row : SubmitThreadKaya.rows(tx, threads)) {
                    row.label(row.title);
                    KayaApp.Node reply = row.entry();
                    row.setA11yId(reply, "reply");
                    app.onSubmitted(reply, (t, keys, text) ->
                            t.write(sent, "sent: " + keys.get(0) + ": " + text));
                }
            }));

            threads.insert(tx, "r1", new SubmitThread("First"));
            threads.insert(tx, "r2", new SubmitThread("Second"));
            return null;
        });

        app.dispatchLoop();
    }

    private Submit() {}
}
