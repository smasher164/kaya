// The formatter door and the catalog, C# port — guests/rust/format.rs,
// tools/scenes/format.steps.

static class FormatScene
{
    public static void Run()
    {
        var app = new KayaApp();
        Kaya.Catalog("format");
        var d = new DateOnly(2026, 9, 7);
        var t = new TimeOnly(8, 30);

        app.Build(tx =>
        {
            // Fourteen labels and a row: taller than the default window, which
            // GTK would otherwise let the root overflow (expect_root_fills).
            tx.Window(title: "format", width: 540, height: 560);
            void Label(string text) => tx.Label(bind: tx.Signal(text));
            tx.Mount(tx.Column(root =>
            {
                Label(Kaya.Fmt.Date(d, Length.Short)); // label#0
                Label(Kaya.Fmt.Date(d, Length.Medium)); // label#1
                Label(Kaya.Fmt.Date(d, Length.Long)); // label#2
                Label(Kaya.Fmt.Time(t, Length.Short)); // label#3
                Label(Kaya.Fmt.DateTime(d, t, Length.Medium)); // label#4
                Label(Kaya.Fmt.Number(1234567.891)); // label#5
                Label(Kaya.Fmt.Percent(0.256)); // label#6
                Label(Kaya.Fmt.Currency(1234567.89, "USD")); // label#7
                Label(Kaya.Tr("items", ("count", 1))); // label#8
                Label(Kaya.Tr("items", ("count", 3))); // label#9
                Label(Kaya.Tr("greeting", ("name", "Ada"))); // label#10
                tx.Row(row =>
                {
                    Label("first"); // label#11
                    tx.Spacer();
                    Label("last"); // label#12
                }); // row#0
                Label(Kaya.Fmt.Locale().Tag); // label#13
                return root;
            }));
        });

        System.Environment.Exit(app.Run());
    }
}
