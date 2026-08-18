// The gallery scene from C#: a checkbox, a slider and two images (a
// valid PNG and deliberately invalid bytes), on the uncontrolled
// contract with a bool and a double.
//
// Build the library first (cargo build), then:
//     KAYA_SELFTEST=gallery KAYA_LIB=target/debug/libkaya.dylib \
//         dotnet run --project guests/csharp

static class GalleryScene
{
    public static void Run()
    {
        var app = new KayaApp();

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
                    // Invalid bytes read 0x0: a decode failure is a
                    // placeholder on every backend, never a crash.
                    tx.Image(TestPng);
                    tx.Image(System.Text.Encoding.ASCII.GetBytes("not an image"));
                });
            }));
        });

        System.Environment.Exit(app.Run());
    }

    // A 2x2 RGB PNG, 75 bytes, embedded as source: a scene carries its
    // inputs and does no runtime file I/O.
    static readonly byte[] TestPng =
    {
        137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
        0, 0, 0, 2, 0, 0, 0, 2, 8, 2, 0, 0, 0, 253, 212, 154, 115, 0,
        0, 0, 18, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192, 192, 0,
        194, 12, 255, 129, 0, 0, 31, 238, 5, 251, 11, 217, 104, 139, 0,
        0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
    };
}
