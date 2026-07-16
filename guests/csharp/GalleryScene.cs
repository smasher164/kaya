// The gallery scene from C#: a row with a checkbox and its status
// label, and a row with a slider and its volume label. Both controls
// own their state and report each change; the app answers by writing
// the paired signal — the entry's uncontrolled contract, with a bool
// and a double.
//
// Build the library first (cargo build), then:
//     KAYA_SELFTEST=gallery KAYA_LIB=target/debug/libkaya.dylib \
//         dotnet run --project guests/csharp

static class GalleryScene
{
    public static void Run()
    {
        var app = new KayaApp();

        // The construction sugar: constructors carry their handlers,
        // containers take their children, and the build body reads as
        // the tree.
        app.Build(tx =>
        {
            var status = tx.Signal("urgent: false");
            var volume = tx.Signal("volume: 50%");

            tx.Mount(tx.Column(
                tx.Row(
                    tx.Checkbox("urgent", onToggle: (t, isChecked) =>
                        t.Write(status, $"urgent: {(isChecked ? "true" : "false")}")),
                    tx.Label(bind: status)),
                tx.Row(
                    // Integer percent, so every language's formatting
                    // agrees.
                    tx.Slider(0.0, 1.0, 0.5, (t, value) =>
                        t.Write(volume, $"volume: {(int)System.Math.Round(value * 100)}%")),
                    tx.Label(bind: volume))));
        });

        System.Environment.Exit(app.Run());
    }
}
