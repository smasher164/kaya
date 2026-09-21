package dev.kaya.guests;

import dev.kaya.KayaApp;

/**
 * The sheet scene from the JVM — guests/rust/sheet.rs, tools/scenes/sheet.steps.
 */
public final class Sheet {
    private static final long TASK = 11;
    private static final long DETAILS = 12;

    public static void app() {
        KayaApp app = new KayaApp();

        KayaApp.Signal<String> status = app.build(tx -> {
            tx.window(0).title("sheet");
            KayaApp.Signal<String> s = tx.signal("closed");
            KayaApp.Signal<String> draft = tx.signal("draft: none");
            tx.mount(tx.column(col -> {
                tx.label(s); // label#0
                tx.button("new task", inner -> openTask(inner, s, draft, false)); // button#0
                tx.button("new task, armed", inner -> openTask(inner, s, draft, true)); // button#1
            }));
            return s;
        });

        if (status == null) throw new IllegalStateException();

        app.dispatchLoop();
    }

    private static void openTask(KayaApp.Tx inner, KayaApp.Signal<String> status,
                                 KayaApp.Signal<String> draft, boolean armed) {
        KayaApp.SheetRef sheet = inner.presentSheet(TASK)
                .title("new task")
                .detent(KayaApp.Detent.MEDIUM)
                .interceptDismiss(armed)
                .onDismissed(tx2 -> tx2.write(status, "dismissed"));
        if (armed) {
            // Nothing has gone; the app keeps the sheet up and says so.
            sheet.onDismissRequested(tx2 -> tx2.write(status, "dismiss requested"));
        }
        KayaApp.Widget body = inner.column(col -> {
            KayaApp.Signal<String> caption = inner.signal("what needs doing?");
            inner.label(caption); // label#1
            inner.entry((tx2, text) -> tx2.write(draft, "draft: " + text)); // entry#0
            inner.label(draft); // label#2
            inner.button("details", tx2 -> { // button#2
                long child = tx2.presentSheetOver(TASK, DETAILS)
                        .title("details")
                        .onDismissed(tx3 -> tx3.write(status, "details dismissed"))
                        .id();
                KayaApp.Widget pane = tx2.column(col2 -> {
                    KayaApp.Signal<String> more = tx2.signal("more about it");
                    tx2.label(more);
                });
                tx2.mountIn(child, pane);
                tx2.write(status, "details open");
            });
            inner.button("done", tx2 -> { // button#3
                // Programmatic: no sheet_dismissed follows, so "done" stays.
                tx2.dismissSheet(TASK);
                tx2.write(status, "done");
            });
        });
        inner.mountIn(sheet.id(), body);
        inner.write(status, "open");
        inner.write(draft, "draft: none");
    }

    private Sheet() {}
}
