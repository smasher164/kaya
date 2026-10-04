// The capture scene, C# port (docs/capture-plan.md): a camera and a
// microphone in one object, a preview, and the frames and samples the app's
// own code is handed on kaya's capture thread. See guests/rust/capture.rs,
// tools/scenes/capture.steps and capture_denied.steps.

using System.Collections.Generic;

static class CaptureScene
{
    const string Camera1 = "kaya-synthetic-camera-1";
    const string Camera2 = "kaya-synthetic-camera-2";
    const string Microphone1 = "kaya-synthetic-microphone-1";
    const string Microphone2 = "kaya-synthetic-microphone-2";

    static string StateLine(CaptureReading r) => r.State switch
    {
        CaptureState.Running => $"running {r.Width}x{r.Height}@{r.FrameRate}",
        CaptureState.Failed => "failed " + (r.Failure?.Name() ?? ""),
        CaptureState.Interrupted => "interrupted " + (r.Interruption?.Name() ?? ""),
        _ => r.State.Name(),
    };

    static string Evidence(string? frames, int? chunk) =>
        (frames is null ? "app frames none" : "app frames " + frames) + ", "
        + (chunk is int n ? $"app chunks of {n}" : "app chunks none");

    public static void Run()
    {
        var app = new KayaApp();

        var (labels, call, missing) = app.Build(tx =>
        {
            tx.Window(title: "capture", width: 520, height: 640);
            var labels = new List<Signal>();
            foreach (var s in new[] { "devices", "permissions", "idle", Evidence(null, null), "idle" })
                labels.Add(tx.Signal(s));
            var call = tx.Capture(camera: Camera1, microphone: Microphone1, size: (600, 400),
                frameRate: 30);
            var missing = tx.Capture(camera: "no-such-camera");
            tx.Mount(tx.Column(root =>
            {
                foreach (var label in labels) tx.Label(bind: label); // label#0..#4
                var buttons = tx.Row(buttons =>
                {
                    tx.Button("Ask camera", t => t.RequestPermission(CaptureKind.Camera)); // button#0
                    tx.Button("Start", t => t.StartCapture(call));                         // button#1
                    tx.Button("Switch", t =>                                               // button#2
                    {
                        t.SetCamera(call, Camera2);
                        t.SetMicrophone(call, Microphone2);
                        t.SetCaptureSize(call, 1280, 720);
                        t.SetFrameRate(call, 15);
                    });
                    tx.Button("Mute", t => t.SetMuted(call, true));             // button#3
                    tx.Button("Camera off", t => t.SetCamera(call, null));      // button#4
                    tx.Button("Stop", t => t.StopCapture(call));                // button#5
                    tx.Button("Open missing", t => t.StartCapture(missing));    // button#6
                    return buttons;
                });
                tx.SetWrap(buttons, true);
                var view = tx.Video(call);                            // video#0
                tx.SetA11yLabel(view, "Self view");
                return root;
            }));
            tx.WatchCaptureDevices(true);
            return (labels, call, missing);
        });

        app.OnCaptureDevices((t, devices) =>
        {
            var parts = new List<string>();
            foreach (var d in devices)
            {
                var s = $"{d.Kind.Name()} {d.Id}";
                if (d.Kind == CaptureKind.Camera) s += " " + d.Facing.Name();
                if (d.Preferred) s += " preferred";
                parts.Add(s);
            }
            t.Write(labels[0], string.Join("; ", parts));
        });
        app.OnPermission((t, _, _) => t.Write(labels[1],
            $"camera {app.Permission(CaptureKind.Camera).Name()}, "
            + $"microphone {app.Permission(CaptureKind.Microphone).Name()}"));
        app.OnCaptureState(call, (t, r) => t.Write(labels[2], StateLine(r)));
        app.OnCaptureState(missing, (t, r) => t.Write(labels[4], StateLine(r)));

        // The app's own code on kaya's capture thread: it checks what it was
        // handed and posts what it saw, as a call's encoder would read it.
        var seen = new object();
        string? frames = null;
        int? chunk = null;
        app.OnCaptureFrame(call, f =>
        {
            bool whole = f.Y.Length >= f.YStride * f.Height
                && f.UV.Length >= f.UVStride * ((f.Height + 1) / 2)
                && f.YStride >= f.Width && f.UVStride >= f.Width;
            string? size = whole ? $"{f.Width}x{f.Height}" : null;
            lock (seen)
            {
                if (frames == size) return;
                frames = size;
                var line = Evidence(frames, chunk);
                app.Post(t => t.Write(labels[3], line));
            }
        });
        app.OnCaptureSamples(call, (samples, _) =>
        {
            lock (seen)
            {
                if (chunk != null) return;
                chunk = samples.Length;
                var line = Evidence(frames, chunk);
                app.Post(t => t.Write(labels[3], line));
            }
        });

        System.Environment.Exit(app.Run());
    }
}
