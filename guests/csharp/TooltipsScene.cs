// The tooltips scene, C# port — guests/rust/tooltips.rs,
// tools/scenes/tooltips.steps, docs/tooltip-plan.md.

[KayaGen]
record Account(string Name, string Note);

static class TooltipsScene
{
    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            var nameHelp = tx.Signal("Your full name as it appears on the card");
            var accounts = AccountKaya.Collection(tx);

            var settings = tx.Column(() =>
            {
                var save = tx.Button("Save",                            // button#0
                    onClick: inner => inner.Write(nameHelp, "Your name, as saved"));
                tx.SetHelp(save, "Saves the draft to disk");
                tx.SetA11yId(save, "save");
                var discard = tx.Button("Discard");                     // button#1
                tx.SetHelp(discard, "Throws the draft away");
                tx.SetA11yHint(discard, "discard every change");
                tx.SetA11yId(discard, "discard");
                var name = tx.Entry();                                  // entry#0
                tx.SetHelp(name, nameHelp);
                tx.SetA11yId(name, "fullname");
                var volume = tx.Slider(0.0, 1.0, 0.5);                  // slider#0
                tx.SetHelp(volume, "How loud the preview plays");
                tx.SetA11yId(volume, "volume");
                foreach (var row in accounts.Rows())
                {
                    var label = row.Label(row.Name);
                    row.SetHelp(label, row.Note);
                    row.SetA11yId(label, row.Name);
                }
            });
            tx.SetHelp(settings, "The settings for this account");       // column#0
            tx.SetA11yId(settings, "settings");
            tx.Mount(settings);

            accounts.Insert(tx, "a",
                new Account("a", "The first account, opened in March"));
            accounts.Insert(tx, "b",
                new Account("b", "The second account, opened in May"));
        });

        System.Environment.Exit(app.Run());
    }
}
