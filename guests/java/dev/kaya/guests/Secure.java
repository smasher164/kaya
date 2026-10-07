package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;

/**
 * The secure field scene from the JVM — guests/rust/secure.rs,
 * tools/scenes/secure.steps (docs/secure-entry-plan.md §5): a password
 * field whose text the app receives whole and answers only as a length and
 * a match, a clear button, and a stamped field per account whose edits
 * name the row.
 */
public final class Secure {
    @KayaGen(key = "String")
    record SecureAccount(String name) {}

    private static final String PASSWORD = "Zq7vKeXw9pLm";

    private static String status(String text) {
        int n = text.codePointCount(0, text.length());
        if (n == 0) {
            return "empty";
        }
        return text.equals(PASSWORD) ? n + " characters, match" : n + " characters, no match";
    }

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            var accounts = SecureAccountKaya.collection(tx);
            KayaApp.Signal<String> statusText = tx.signal("empty");
            KayaApp.Signal<String> sentText = tx.signal("sent: -");
            KayaApp.Signal<String> pinText = tx.signal("pin: -");

            tx.mount(tx.column(col -> {
                KayaApp.Widget password = tx.secureField((t, text) -> t.write(statusText, status(text)))
                        .placeholder("Password").a11yId("password").a11yLabel("Password");
                app.onSubmitted(password, (t, text) -> t.write(sentText, "sent: " + status(text)));
                tx.label(statusText).a11yId("status");
                tx.label(sentText).a11yId("sent");
                KayaApp.Widget clear = tx.button("Clear").a11yId("clear");
                app.onClick(clear, t -> t.clear(password));
                tx.label(pinText).a11yId("pin_status");
                for (var row : SecureAccountKaya.rows(tx, accounts)) {
                    row.label(row.name);
                    KayaApp.Node pin = row.secureField();
                    row.setA11yId(pin, "pin");
                    app.onChange(pin, (t, keys, text) ->
                            t.write(pinText, "pin " + keys.get(0) + ": "
                                    + text.codePointCount(0, text.length())));
                }
            }));

            accounts.insert(tx, "a", new SecureAccount("a"));
            accounts.insert(tx, "b", new SecureAccount("b"));
            return null;
        });

        app.dispatchLoop();
    }

    private Secure() {}
}
