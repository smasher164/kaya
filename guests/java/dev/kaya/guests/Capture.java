package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaApp.CaptureKind;
import dev.kaya.KayaApp.CaptureReading;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * The capture from the JVM — guests/rust/capture.rs,
 * tools/scenes/capture.steps and capture_denied.steps, docs/capture-plan.md.
 */
public final class Capture {
    private static final String CAMERA_1 = "kaya-synthetic-camera-1";
    private static final String CAMERA_2 = "kaya-synthetic-camera-2";
    private static final String MICROPHONE_1 = "kaya-synthetic-microphone-1";
    private static final String MICROPHONE_2 = "kaya-synthetic-microphone-2";

    private static String stateLine(CaptureReading r) {
        return switch (r.state()) {
            case RUNNING -> "running " + r.width() + "x" + r.height() + "@" + r.frameRate();
            case FAILED -> "failed " + r.failure().map(Object::toString).orElse("");
            case INTERRUPTED -> "interrupted " + r.interruption().map(Object::toString).orElse("");
            default -> r.state().toString();
        };
    }

    /** What the app's code on kaya's capture thread has seen. */
    private static final class Seen {
        private String frames = "app frames none";
        private String chunks = "app chunks none";

        synchronized String frames(String now) {
            if (now.equals(frames)) {
                return null;
            }
            frames = now;
            return frames + ", " + chunks;
        }

        synchronized String chunks(int n) {
            chunks = "app chunks of " + n;
            return frames + ", " + chunks;
        }
    }

    public static void app() {
        KayaApp app = new KayaApp();
        List<KayaApp.Signal<String>> labels = new ArrayList<>();
        KayaApp.Capture[] made = new KayaApp.Capture[2];
        app.build(tx -> {
            tx.window(0).title("capture").size(520.0, 640.0);
            for (String s : new String[] {"devices", "permissions", "idle",
                    "app frames none, app chunks none", "idle"}) {
                labels.add(tx.signal(s));
            }
            KayaApp.Capture call = tx.capture().camera(CAMERA_1).microphone(MICROPHONE_1)
                    .size(600.0, 400.0).frameRate(30.0);
            KayaApp.Capture missing = tx.capture().camera("no-such-camera");
            tx.mount(tx.column(col -> {
                for (KayaApp.Signal<String> label : labels) {
                    tx.label(label); // label#0..#4
                }
                tx.video(call).a11yLabel("Self view"); // video#0
                tx.button("Ask camera", t -> t.requestPermission(CaptureKind.CAMERA)); // button#0
                tx.button("Start", t -> t.startCapture(call)); // button#1
                tx.button("Switch", t -> { // button#2
                    t.captureCamera(call, CAMERA_2);
                    t.captureMicrophone(call, MICROPHONE_2);
                    t.captureSize(call, 1280.0, 720.0);
                    t.captureFrameRate(call, 15.0);
                });
                tx.button("Mute", t -> t.captureMuted(call, true)); // button#3
                tx.button("Camera off", t -> t.captureCamera(call, null)); // button#4
                tx.button("Stop", t -> t.stopCapture(call)); // button#5
                tx.button("Open missing", t -> t.startCapture(missing)); // button#6
            }));
            tx.watchCaptureDevices(true);
            made[0] = call;
            made[1] = missing;
            return null;
        });
        KayaApp.Capture call = made[0];
        KayaApp.Capture missing = made[1];
        app.onCaptureDevices((t, devices) -> {
            List<String> line = new ArrayList<>();
            for (KayaApp.CaptureDevice d : devices) {
                String s = d.kind() + " " + d.id();
                if (d.kind() == CaptureKind.CAMERA) {
                    s += " " + d.facing();
                }
                if (d.preferred()) {
                    s += " preferred";
                }
                line.add(s);
            }
            t.write(labels.get(0), String.join("; ", line));
        });
        app.onPermission((t, kind, permission) -> t.write(labels.get(1), "camera "
                + app.permission(CaptureKind.CAMERA) + ", microphone "
                + app.permission(CaptureKind.MICROPHONE)));
        app.onCaptureState(call, (t, r) -> t.write(labels.get(2), stateLine(r)));
        app.onCaptureState(missing, (t, r) -> t.write(labels.get(4), stateLine(r)));

        // The app's own code on kaya's capture thread: it checks what it was
        // handed and posts what it saw, as a call's encoder would read it.
        Seen seen = new Seen();
        KayaApp.Signal<String> shown = labels.get(3);
        app.onCaptureFrame(call, f -> {
            boolean whole = f.y().length >= (long) f.yStride() * f.height()
                    && f.uv().length >= (long) f.uvStride() * ((f.height() + 1) / 2)
                    && f.yStride() >= f.width()
                    && f.uvStride() >= f.width();
            String line = seen.frames(whole ? "app frames " + f.width() + "x" + f.height()
                    : "app frames none");
            if (line != null) {
                app.post(t -> t.write(shown, line));
            }
        });
        AtomicBoolean posted = new AtomicBoolean();
        app.onCaptureSamples(call, (chunk, at) -> {
            if (posted.getAndSet(true)) {
                return;
            }
            String line = seen.chunks(chunk.length);
            app.post(t -> t.write(shown, line));
        });
        app.dispatchLoop();
    }

    private Capture() {}
}
