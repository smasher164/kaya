package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;

/**
 * The reveal toggle scene from the JVM — guests/rust/reveal.rs,
 * tools/scenes/reveal.steps (docs/reveal-plan.md §5): a password field
 * with its own show/hide toggle, the app's own Show and Hide buttons, and a
 * stamped field each row reveals by its own field.
 */
public final class Reveal {
    @KayaGen(key = "String")
    record RevealAccount(String name, boolean shown) {}

    private static final String PASSWORD = "Rv4tNbHy2mQc";

    private static String status(String text) {
        int n = text.codePointCount(0, text.length());
        if (n == 0) {
            return "empty";
        }
        return text.equals(PASSWORD) ? n + " characters, match" : n + " characters, no match";
    }

    private static String shown(boolean on) {
        return on ? "shown" : "hidden";
    }

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            var accounts = RevealAccountKaya.collection(tx);
            KayaApp.Signal<String> statusText = tx.signal("empty");
            KayaApp.Signal<String> sentText = tx.signal("sent: -");
            KayaApp.Signal<String> heardText = tx.signal("heard: -");
            KayaApp.Signal<String> pinText = tx.signal("pin: -");

            tx.mount(tx.column(col -> {
                KayaApp.Widget password = tx.secureField((t, text) -> t.write(statusText, status(text)))
                        .placeholder("Password").contentType(KayaApp.ContentType.PASSWORD).revealable()
                        .a11yId("password").a11yLabel("Password");
                app.onSubmitted(password, (t, text) -> t.write(sentText, "sent: " + status(text)));
                app.onToggle(password, (t, on) -> t.write(heardText, "heard: " + shown(on)));
                tx.label(statusText).a11yId("status");
                tx.label(sentText).a11yId("sent");
                tx.label(heardText).a11yId("heard");
                KayaApp.Widget show = tx.button("Show").a11yId("show");
                app.onClick(show, t -> t.setRevealed(password, true));
                KayaApp.Widget hide = tx.button("Hide").a11yId("hide");
                app.onClick(hide, t -> t.setRevealed(password, false));
                KayaApp.Widget clear = tx.button("Clear").a11yId("clear");
                app.onClick(clear, t -> t.clear(password));
                tx.label(pinText).a11yId("pin_status");
                for (var row : RevealAccountKaya.rows(tx, accounts)) {
                    row.label(row.name);
                    KayaApp.Node pin = row.secureField();
                    row.setA11yId(pin, "pin");
                    row.setRevealable(pin);
                    row.setRevealed(pin, row.shown);
                    app.onChange(pin, (t, keys, text) ->
                            t.write(pinText, "pin " + keys.get(0) + ": "
                                    + text.codePointCount(0, text.length())));
                    app.onToggle(pin, (t, keys, on) ->
                            t.write(pinText, "pin " + keys.get(0) + ": " + shown(on)));
                }
            }));

            accounts.insert(tx, "b", new RevealAccount("b", true));
            return null;
        });

        app.dispatchLoop();
    }

    private Reveal() {}
}
