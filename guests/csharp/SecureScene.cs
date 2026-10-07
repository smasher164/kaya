// The secure field scene, C# port — guests/rust/secure.rs,
// tools/scenes/secure.steps (docs/secure-entry-plan.md §5): a password
// field whose text the app receives whole and answers only as a length and
// a match, a clear button, and a stamped field per account whose edits name
// the row.

[KayaGen]
record SecureAccount(string Name);

static class SecureScene
{
    const string Password = "Zq7vKeXw9pLm";

    static string Status(string text)
    {
        int n = text.EnumerateRunes().Count();
        if (n == 0) return "empty";
        return text == Password ? $"{n} characters, match" : $"{n} characters, no match";
    }

    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            var statusText = tx.Signal("empty");
            var sentText = tx.Signal("sent: -");
            var pinText = tx.Signal("pin: -");
            var accounts = SecureAccountKaya.Collection(tx);

            tx.Mount(tx.Column(root =>
            {
                var password = tx.SecureField(
                    onChange: (t, text) => t.Write(statusText, Status(text)),
                    onSubmit: (t, text) => t.Write(sentText, $"sent: {Status(text)}"));
                tx.SetPlaceholder(password, "Password");
                tx.SetA11yId(password, "password");
                tx.SetA11yLabel(password, "Password");
                tx.SetA11yId(tx.Label(bind: statusText), "status");
                tx.SetA11yId(tx.Label(bind: sentText), "sent");
                var clear = tx.Button("Clear");
                tx.SetA11yId(clear, "clear");
                app.OnClick(clear, t => t.Clear(password));
                tx.SetA11yId(tx.Label(bind: pinText), "pin_status");

                foreach (var row in accounts.Rows())
                {
                    row.Label(row.Name);
                    Node pin = row.SecureField(onChange: (t, keys, text) =>
                        t.Write(pinText, $"pin {(string)keys[0]}: {text.EnumerateRunes().Count()}"));
                    row.SetA11yId(pin, "pin");
                }
                return root;
            }));

            accounts.Insert(tx, "a", new SecureAccount("a"));
            accounts.Insert(tx, "b", new SecureAccount("b"));
        });

        System.Environment.Exit(app.Run());
    }
}
