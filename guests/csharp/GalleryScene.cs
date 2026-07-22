// The gallery scene from C#: a row with a checkbox and its status
// label, a row with a slider and its volume label, and a row with two
// images (a valid PNG and deliberately invalid bytes). The controls
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
            var pos = tx.Signal(0.5);

            tx.Mount(tx.Column(() =>
            {
                tx.Row(() =>
                {
                    tx.Checkbox("urgent", onToggle: (t, isChecked) =>
                        t.Write(status, $"urgent: {(isChecked ? "true" : "false")}"));
                    tx.Label(bind: status);
                });
                tx.Row(() =>
                {
                    // Integer percent, so every language's formatting
                    // agrees.
                    tx.Slider(0.0, 1.0, bind: pos, onChange: (t, value) =>
                        t.Write(volume, $"volume: {(int)System.Math.Round(value * 100)}%"));
                    tx.Label(bind: volume);
                    // The programmatic write: fans out to the control
                    // and must NOT come back as a volume occurrence.
                    tx.Button("quarter", onClick: t => t.Write(pos, 0.25));
                });
                tx.Row(() =>
                {
                    // The content-buffer row: a valid 2x2 PNG decodes
                    // and reports its size, and deliberately invalid
                    // bytes read 0x0 — decode failure is the
                    // placeholder class, never a crash, on every
                    // backend.
                    tx.Image(TestPng);
                    tx.Image(System.Text.Encoding.ASCII.GetBytes("not an image"));
                });
            }));
        });

        System.Environment.Exit(app.Run());
    }

    // A 2x2 RGB PNG (red/green over blue/white), 75 bytes: the first
    // binary asset, embedded as source per the include_str! doctrine —
    // scenes carry their inputs, no runtime file I/O.
    static readonly byte[] TestPng =
    {
        137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
        0, 0, 0, 2, 0, 0, 0, 2, 8, 2, 0, 0, 0, 253, 212, 154, 115, 0,
        0, 0, 18, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192, 192, 0,
        194, 12, 255, 129, 0, 0, 31, 238, 5, 251, 11, 217, 104, 139, 0,
        0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
    };
}
