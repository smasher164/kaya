// The gallery scene from C#: a row container laying a checkbox and the
// status label side by side. The box owns its checked bit and reports
// each flip through OnToggle; the app answers by writing the status
// signal — the same uncontrolled contract as the entry, with a bool.
//
// Build the library first (cargo build), then:
//     KAYA_SELFTEST=gallery KAYA_LIB=target/debug/libkaya.dylib \
//         dotnet run --project guests/csharp

static class GalleryScene
{
    public static void Run()
    {
        var app = new KayaApp();

        Signal status = default;
        Widget urgent = default;

        app.Build(tx =>
        {
            status = tx.Signal("urgent: false");

            var column = tx.Widget(KayaWire.KindColumn);
            var row = tx.Widget(KayaWire.KindRow);
            urgent = tx.Widget(KayaWire.KindCheckbox);
            tx.SetText(urgent, "urgent");
            var statusLabel = tx.Widget(KayaWire.KindLabel);
            tx.BindText(statusLabel, status);

            tx.AddChild(row, urgent);
            tx.AddChild(row, statusLabel);
            tx.AddChild(column, row);
            tx.Mount(column);
        });

        app.OnToggle(urgent, (tx, isChecked) =>
            tx.Write(status, $"urgent: {(isChecked ? "true" : "false")}"));

        System.Environment.Exit(app.Run());
    }
}
