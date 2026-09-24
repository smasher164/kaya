package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;

/**
 * The scroll-to scene from the JVM — guests/rust/scrollto.rs,
 * tools/scenes/scrollto.steps. The app scrolls a list of messages to a
 * row by key (docs/scroll-to-plan.md), opening at the newest one before
 * the first layout, jumping to one on a click, staying put on a key no
 * row holds, and following its own send.
 */
public final class ScrollTo {
    @KayaGen(key = "String")
    record Message(String text) {}

    public static void app() {
        KayaApp app = new KayaApp();
        int[] sent = {60};
        KayaApp.Widget[] list = new KayaApp.Widget[1];

        app.build(tx -> {
            var messages = MessageKaya.collection(tx);
            KayaApp.Signal<String> count = tx.signal("60 messages");

            tx.mount(tx.column(col -> {
                tx.label(count).a11yId("count"); // label#0
                tx.row(bar -> {
                    tx.button("jump", t -> t.scrollToRow(list[0], "m10"))
                            .a11yId("jump"); // button#0
                    tx.button("nowhere", t -> t.scrollToRow(list[0], "m999"))
                            .a11yId("nowhere"); // button#1
                    tx.button("send", t -> {
                        sent[0]++;
                        messages.insert(t, "m" + sent[0],
                                new Message("message " + sent[0]));
                        t.write(count, sent[0] + " messages");
                        t.scrollToRow(list[0], "m" + sent[0]);
                    }).a11yId("send"); // button#2
                });
                tx.scroll(box -> { // scroll#0
                    // The For's own container, which scrollToRow
                    // addresses (docs/scroll-to-plan.md S1).
                    var rows = MessageKaya.rows(tx, messages);
                    list[0] = rows.handle;
                    for (var row : rows) {
                        row.label(row.text);
                    }
                    list[0].a11yId("messages");
                }).grow(1);
            }));

            for (int i = 1; i <= 60; i++) {
                messages.insert(tx, "m" + i, new Message("message " + i));
            }
            tx.scrollToRow(list[0], "m60");
            return null;
        });

        app.dispatchLoop();
    }

    private ScrollTo() {}
}
