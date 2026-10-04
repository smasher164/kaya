"""The capture (tools/scenes/capture.steps, capture_denied.steps;
docs/capture-plan.md): a camera and a microphone in one object, a preview,
and the frames and samples the app's own code is handed on kaya's capture
thread. Under the harness the devices are kaya's synthetic ones; the
`capture_denied` scene answers the camera's prompt no."""

import sys
import threading
from dataclasses import dataclass

import kaya

CAMERA_1 = "kaya-synthetic-camera-1"
CAMERA_2 = "kaya-synthetic-camera-2"
MICROPHONE_1 = "kaya-synthetic-microphone-1"
MICROPHONE_2 = "kaya-synthetic-microphone-2"

app = kaya.App()


def state_line(r):
    if r.state == kaya.CaptureState.RUNNING:
        return f"running {r.width}x{r.height}@{r.frame_rate}"
    if r.state == kaya.CaptureState.FAILED:
        return f"failed {r.failure or ''}"
    if r.state == kaya.CaptureState.INTERRUPTED:
        return f"interrupted {r.interruption or ''}"
    return str(r.state)


def evidence(frames, chunk):
    seen = "app frames none" if frames is None else f"app frames {frames[0]}x{frames[1]}"
    heard = "app chunks none" if chunk is None else f"app chunks of {chunk}"
    return f"{seen}, {heard}"


def device_line(devices):
    parts = []
    for d in devices:
        s = f"{d.kind} {d.id}"
        if d.kind == kaya.CaptureKind.CAMERA:
            s += f" {d.facing}"
        if d.preferred:
            s += " preferred"
        parts.append(s)
    return "; ".join(parts)


def permission_line():
    camera = kaya.permission(kaya.CaptureKind.CAMERA)
    microphone = kaya.permission(kaya.CaptureKind.MICROPHONE)
    return f"camera {camera}, microphone {microphone}"


# The app's own code on kaya's capture thread: it checks what it was handed
# and posts what it saw, as a call's encoder would read it.
@dataclass
class Seen:
    frames: tuple[int, int] | None = None
    chunk: int | None = None


seen_lock = threading.Lock()
seen = Seen()
chunk_posted = threading.Event()


def on_frame(f):
    whole = (len(f.y) >= f.y_stride * f.height
             and len(f.uv) >= f.uv_stride * ((f.height + 1) // 2)
             and f.y_stride >= f.width and f.uv_stride >= f.width)
    size = (f.width, f.height) if whole else None
    with seen_lock:
        if seen.frames != size:
            seen.frames = size
            line = evidence(seen.frames, seen.chunk)
            app.post(labels[3].set, line)


def on_samples(chunk, _at):
    if chunk_posted.is_set():
        return
    chunk_posted.set()
    with seen_lock:
        seen.chunk = len(chunk)
        line = evidence(seen.frames, seen.chunk)
        app.post(labels[3].set, line)


def on_switch():
    call.set_camera(CAMERA_2)
    call.set_microphone(MICROPHONE_2)
    call.set_size(1280.0, 720.0)
    call.set_frame_rate(15.0)


def on_wide_cover():
    view.aspect(16, 9)
    view.fit(kaya.Fit.COVER)


with app.window("capture", width=520.0, height=640.0):
    labels = [kaya.signal(s) for s in
              ("devices", "permissions", "idle", evidence(None, None), "idle")]
    call = kaya.capture(camera=CAMERA_1, microphone=MICROPHONE_1,
                        size=(600.0, 400.0), frame_rate=30.0,
                        on_state=lambda r: labels[2].set(state_line(r)),
                        on_frame=on_frame, on_samples=on_samples)
    missing = kaya.capture(camera="no-such-camera",
                           on_state=lambda r: labels[4].set(state_line(r)))
    with kaya.column():
        for label in labels:
            kaya.label(bind=label)                                   # label#0..#4
        with kaya.row() as buttons:
            buttons.wrap(True)
            kaya.button("Ask camera", on_click=lambda: kaya.request_permission(
                kaya.CaptureKind.CAMERA))                                # button#0
            kaya.button("Start", on_click=call.start)                    # button#1
            kaya.button("Switch", on_click=on_switch)                    # button#2
            kaya.button("Mute", on_click=lambda: call.set_muted(True))   # button#3
            kaya.button("Camera off", on_click=lambda: call.set_camera(None))  # button#4
            kaya.button("Stop", on_click=call.stop)                      # button#5
            kaya.button("Open missing", on_click=missing.start)          # button#6
            kaya.button("Wide cover", on_click=on_wide_cover)            # button#7
            kaya.button("Wide contain", on_click=lambda: view.fit(kaya.Fit.CONTAIN))  # button#8
        view = kaya.video(capture=call).a11y_label("Self view")      # video#0
    kaya.watch_capture_devices(True)

kaya.on_capture_devices(lambda devices: labels[0].set(device_line(devices)))
kaya.on_permission(lambda _kind, _permission: labels[1].set(permission_line()))

sys.exit(app.run())
