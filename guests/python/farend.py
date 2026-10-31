"""The far end of a call (tools/scenes/farend.steps; docs/capture-plan.md §5):
a surface showing the NV12 frames the app submits from its own thread, and a
voice output playing the samples it writes there. The peer is a thread of
the app's, standing in for a transport."""

import array
import math
import sys
import threading
import time

import kaya

app = kaya.App()


def nv12(width, height, rgb):
    """A flat colour as NV12, video-range BT.601."""
    r, g, b = (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF
    y = round(16 + 0.257 * r + 0.504 * g + 0.098 * b)
    u = round(128 - 0.148 * r - 0.291 * g + 0.439 * b)
    v = round(128 + 0.439 * r - 0.368 * g - 0.071 * b)
    return bytes([y]) * (width * height), bytes([u, v]) * (width * height // 4)


class Peer:
    """What the far end sends: a flat colour at a size and a tone (0:
    silence), a frame every 1/15 s and 10 ms of samples every 10 ms."""

    def __init__(self):
        self.lock = threading.Lock()
        self.rgb, self.size, self.hz, self.on = 0x1E5AC8, (640, 480), 660.0, False
        self.thread: threading.Thread | None = None

    def run(self, frames, writer):
        start = time.monotonic()
        sent_frames = sent_samples = 0
        shown = None
        phase = 0.0
        while True:
            with self.lock:
                rgb, (w, h), hz, on = self.rgb, self.size, self.hz, self.on
            if not on:
                return
            elapsed = time.monotonic() - start
            while sent_frames / 15 <= elapsed:
                if shown is None or shown[0] != (rgb, w, h):
                    shown = ((rgb, w, h), *nv12(w, h, rgb))
                frames.submit(kaya.CaptureFrame(w, h, shown[1], w, shown[2], w, int(elapsed * 1e9), 0))
                sent_frames += 1
            while sent_samples / 48000 <= elapsed:
                chunk = array.array("h", [0] * 480)
                step = 2 * math.pi * hz / 48000
                for i in range(480):
                    if hz > 0:
                        chunk[i] = int(math.sin(phase) * 12000)
                    phase = (phase + step) % (2 * math.pi)
                writer.write(chunk)
                sent_samples += 480
            time.sleep(0.005)


peer = Peer()
call = None


def on_route(route, _detail):
    if route in (kaya.VoiceRoute.VOICE, kaya.VoiceRoute.PLAIN, kaya.VoiceRoute.SYNTHETIC):
        line.set("voice playing")
    elif route == kaya.VoiceRoute.FAILED:
        line.set("voice failed")
    else:
        line.set("voice none")


def connect():
    global call
    if call is not None:
        return
    call = kaya.voice(on_route=on_route)
    with peer.lock:
        peer.rgb, peer.size, peer.hz, peer.on = 0x1E5AC8, (640, 480), 660.0, True
    thread = threading.Thread(
        target=peer.run, args=(kaya.surface_frames(view), call.writer()), daemon=True)
    peer.thread = thread
    thread.start()


def change():
    with peer.lock:
        peer.rgb, peer.size, peer.hz = 0xC83C1E, (1280, 720), 440.0


def quiet():
    with peer.lock:
        peer.hz = 0.0


def hang_up():
    global call
    if call is None:
        return
    with peer.lock:
        peer.on = False
    if peer.thread is not None:
        peer.thread.join()
    call.release()
    call = None
    line.set("voice none")


with app.window("far end", width=520.0, height=640.0):
    line = kaya.signal("voice none")
    with kaya.column():
        kaya.label(bind=line)                              # label#0
        with kaya.row():
            kaya.button("Connect", on_click=connect)       # button#0
            kaya.button("Change", on_click=change)         # button#1
            kaya.button("Quiet", on_click=quiet)           # button#2
            kaya.button("Hang up", on_click=hang_up)       # button#3
        view = kaya.surface().a11y_label("Peer")           # surface#0

sys.exit(app.run())
