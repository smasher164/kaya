package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;

/**
 * The restoration scene from the JVM — guests/rust/restore.rs,
 * tools/scenes/restore.steps (docs/restoration-plan.md SR15): the draft
 * lives in the session store and comes back through the ordinary build;
 * the list's scroll and the text's caret come back on their own.
 */
public final class Restore {
    @KayaGen(key = "String")
    record RestoreLine(String text) {}

    public static void app() {
        KayaApp app = new KayaApp();
        KayaApp.SessionHandle session = KayaApp.session();
        KayaApp.Widget[] list = new KayaApp.Widget[1];
        KayaApp.Widget[] doc = new KayaApp.Widget[1];

        app.build(tx -> {
            tx.window(0).title("restore");
            var lines = RestoreLineKaya.collection(tx);
            KayaApp.Signal<String> launch = tx.signal("launch " + KayaApp.restored());
            tx.mount(tx.column(col -> {
                tx.label(launch);
                KayaApp.Widget field = tx.entry();
                tx.setText(field, session.getString("draft", ""));
                app.onChange(field, (t, text) -> session.setString("draft", text));
                tx.row(bar -> {
                    tx.button("jump", t -> t.scrollToRow(list[0], "m30")).a11yId("jump");
                    tx.button("select", t -> t.selectRange(doc[0], KayaApp.TextRange.ofBytes(4, 9)))
                            .a11yId("select");
                });
                doc[0] = tx.textarea().a11yId("doc");
                tx.setText(doc[0], "the quick brown fox");
                tx.scroll(box -> {
                    var rows = RestoreLineKaya.rows(tx, lines);
                    list[0] = rows.handle;
                    for (var row : rows) {
                        row.label(row.text);
                    }
                    list[0].a11yId("messages");
                }).grow(1).a11yId("list");
            }));
            for (int i = 1; i <= 60; i++) {
                lines.insert(tx, "m" + i, new RestoreLine("message " + i));
            }
        });

        app.dispatchLoop();
    }
}
