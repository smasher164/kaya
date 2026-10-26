package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;

/**
 * The tooltips scene from the JVM — guests/rust/tooltips.rs,
 * tools/scenes/tooltips.steps, docs/tooltip-plan.md.
 */
public final class Tooltips {
    @KayaGen(key = "String")
    record Account(String name, String note) {}

    private static final String STATEMENTS = "Every statement since March";

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0).title("tooltips");
            KayaApp.Signal<String> nameHelp =
                tx.signal("Your full name as it appears on the card");
            var accounts = AccountKaya.collection(tx);

            KayaApp.Widget settings = tx.column(col -> {
                tx.button("Save", t -> t.write(nameHelp, "Your name, as saved"))
                        .help("Saves the draft to disk").a11yId("save"); // button#0
                tx.button("Discard")
                        .help("Throws the draft away")
                        .a11yHint("discard every change")
                        .a11yId("discard"); // button#1
                tx.button("Clear").help("").a11yId("clear"); // button#2
                tx.entry().help(nameHelp).a11yId("fullname"); // entry#0
                tx.slider(0.0, 1.0, 0.5, null)
                        .help("How loud the preview plays")
                        .a11yId("volume"); // slider#0
                tx.label(STATEMENTS).maxLines(1).maxWidth(80).a11yId("cut"); // label#0
                tx.label(STATEMENTS).maxLines(1).a11yId("whole"); // label#1
                for (var row : AccountKaya.rows(tx, accounts)) {
                    KayaApp.Node label = row.label(row.name);
                    row.setHelp(label, row.note);
                    row.setA11yId(label, row.name);
                }
            });
            settings.help("The settings for this account").a11yId("settings"); // column#0
            tx.mount(settings);

            accounts.insert(tx, "a",
                new Account("a", "The first account, opened in March"));
            accounts.insert(tx, "b",
                new Account("b", "The second account, opened in May"));
            return null;
        });

        app.dispatchLoop();
    }

    private Tooltips() {}
}
