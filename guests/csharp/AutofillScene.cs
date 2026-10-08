// The content type scene, C# port — guests/rust/autofill.rs,
// tools/scenes/autofill.steps (docs/autofill-plan.md §5): a sign-in form,
// a sign-up form, a code field and a phone field, each saying what it
// holds; a button that turns the sign-in name into an email address and
// back; and a stamped code field.

[KayaGen]
record AutofillAccount(string Name);

static class AutofillScene
{
    public static void Run()
    {
        var app = new KayaApp();
        var email = false;

        app.Build(tx =>
        {
            var mode = tx.Signal("sign in with a username");
            var accounts = AutofillAccountKaya.Collection(tx);

            tx.Mount(tx.Column(root =>
            {
                var user = tx.Entry(contentType: ContentType.Username);
                tx.SetPlaceholder(user, "Username");
                tx.SetA11yId(user, "user");
                var password = tx.SecureField(contentType: ContentType.Password);
                tx.SetPlaceholder(password, "Password");
                tx.SetA11yId(password, "password");
                tx.SetA11yId(tx.Label(bind: mode), "mode");
                var useEmail = tx.Button("Use email");
                tx.SetA11yId(useEmail, "switch");
                app.OnClick(useEmail, t =>
                {
                    email = !email;
                    if (email)
                    {
                        t.SetContentType(user, ContentType.Email);
                        t.Write(mode, "sign in with an email address");
                    }
                    else
                    {
                        t.SetContentType(user, ContentType.Username);
                        t.Write(mode, "sign in with a username");
                    }
                });
                var emailField = tx.Entry(contentType: ContentType.Email);
                tx.SetPlaceholder(emailField, "Email");
                tx.SetA11yId(emailField, "email");
                var newPassword = tx.SecureField(contentType: ContentType.NewPassword);
                tx.SetPlaceholder(newPassword, "New password");
                tx.SetA11yId(newPassword, "new");
                var code = tx.Entry(contentType: ContentType.OneTimeCode);
                tx.SetPlaceholder(code, "Code");
                tx.SetA11yId(code, "code");
                var phone = tx.Entry(contentType: ContentType.Phone);
                tx.SetPlaceholder(phone, "Phone");
                tx.SetA11yId(phone, "phone");
                var note = tx.Entry();
                tx.SetPlaceholder(note, "Note");
                tx.SetA11yId(note, "note");

                foreach (var row in accounts.Rows())
                {
                    row.Label(row.Name);
                    Node pin = row.SecureField();
                    row.SetContentType(pin, ContentType.OneTimeCode);
                    row.SetA11yId(pin, "pin");
                }
                return root;
            }));

            accounts.Insert(tx, "a", new AutofillAccount("a"));
        });

        System.Environment.Exit(app.Run());
    }
}
