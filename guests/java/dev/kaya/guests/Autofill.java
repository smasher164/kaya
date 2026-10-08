package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaApp.ContentType;
import dev.kaya.KayaGen;

/**
 * The content type scene from the JVM — guests/rust/autofill.rs,
 * tools/scenes/autofill.steps (docs/autofill-plan.md §5): a sign-in form,
 * a sign-up form, a code field and a phone field, each saying what it
 * holds; a button that turns the sign-in name into an email address and
 * back; and a stamped code field.
 */
public final class Autofill {
    @KayaGen(key = "String")
    record AutofillAccount(String name) {}

    public static void app() {
        KayaApp app = new KayaApp();
        boolean[] email = {false};

        app.build(tx -> {
            var accounts = AutofillAccountKaya.collection(tx);
            KayaApp.Signal<String> mode = tx.signal("sign in with a username");

            tx.mount(tx.column(col -> {
                KayaApp.Widget user = tx.entry().placeholder("Username")
                        .contentType(ContentType.USERNAME).a11yId("user");
                tx.secureField().placeholder("Password")
                        .contentType(ContentType.PASSWORD).a11yId("password");
                tx.label(mode).a11yId("mode");
                KayaApp.Widget useEmail = tx.button("Use email").a11yId("switch");
                app.onClick(useEmail, t -> {
                    email[0] = !email[0];
                    if (email[0]) {
                        t.setContentType(user, ContentType.EMAIL);
                        t.write(mode, "sign in with an email address");
                    } else {
                        t.setContentType(user, ContentType.USERNAME);
                        t.write(mode, "sign in with a username");
                    }
                });
                tx.entry().placeholder("Email").contentType(ContentType.EMAIL).a11yId("email");
                tx.secureField().placeholder("New password")
                        .contentType(ContentType.NEW_PASSWORD).a11yId("new");
                tx.entry().placeholder("Code").contentType(ContentType.ONE_TIME_CODE).a11yId("code");
                tx.entry().placeholder("Phone").contentType(ContentType.PHONE).a11yId("phone");
                tx.entry().placeholder("Note").a11yId("note");
                for (var row : AutofillAccountKaya.rows(tx, accounts)) {
                    row.label(row.name);
                    KayaApp.Node pin = row.secureField();
                    row.setContentType(pin, ContentType.ONE_TIME_CODE);
                    row.setA11yId(pin, "pin");
                }
            }));

            accounts.insert(tx, "a", new AutofillAccount("a"));
            return null;
        });

        app.dispatchLoop();
    }

    private Autofill() {}
}
