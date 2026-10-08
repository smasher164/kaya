// The reveal toggle scene, C# port — guests/rust/reveal.rs,
// tools/scenes/reveal.steps (docs/reveal-plan.md §5): a password field
// with its own show/hide toggle, the app's own Show and Hide buttons, and a
// stamped field each row reveals by its own field.

[KayaGen]
record RevealAccount(string Name, bool Shown);

static class RevealScene
{
    const string Password = "Rv4tNbHy2mQc";

    static string Status(string text)
    {
        int n = text.EnumerateRunes().Count();
        if (n == 0) return "empty";
        return text == Password ? $"{n} characters, match" : $"{n} characters, no match";
    }

    static string Shown(bool on) => on ? "shown" : "hidden";

    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            var statusText = tx.Signal("empty");
            var sentText = tx.Signal("sent: -");
            var heardText = tx.Signal("heard: -");
            var pinText = tx.Signal("pin: -");
            var accounts = RevealAccountKaya.Collection(tx);

            tx.Mount(tx.Column(root =>
            {
                var password = tx.SecureField(
                    onChange: (t, text) => t.Write(statusText, Status(text)),
                    onSubmit: (t, text) => t.Write(sentText, $"sent: {Status(text)}"),
                    contentType: ContentType.Password,
                    revealable: true,
                    onToggle: (t, on) => t.Write(heardText, $"heard: {Shown(on)}"));
                tx.SetPlaceholder(password, "Password");
                tx.SetA11yId(password, "password");
                tx.SetA11yLabel(password, "Password");
                tx.SetA11yId(tx.Label(bind: statusText), "status");
                tx.SetA11yId(tx.Label(bind: sentText), "sent");
                tx.SetA11yId(tx.Label(bind: heardText), "heard");
                var show = tx.Button("Show");
                tx.SetA11yId(show, "show");
                app.OnClick(show, t => t.SetRevealed(password, true));
                var hide = tx.Button("Hide");
                tx.SetA11yId(hide, "hide");
                app.OnClick(hide, t => t.SetRevealed(password, false));
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
                    row.SetRevealable(pin);
                    row.SetRevealed(pin, row.Shown);
                    app.OnToggle(pin, (t, keys, on) =>
                        t.Write(pinText, $"pin {(string)keys[0]}: {Shown(on)}"));
                }
                return root;
            }));

            accounts.Insert(tx, "b", new RevealAccount("b", true));
        });

        System.Environment.Exit(app.Run());
    }
}
