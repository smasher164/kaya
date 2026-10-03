"""The capture legs' synthetic devices on the emulator (docs/capture-plan.md §7).

The CAMERAS are the emulator's own, front and back, each an `imagefile:` of
one flat colour (`camera_images`); the MICROPHONE takes PCM over the
emulator's gRPC `injectAudio` with no host audio device (`injecting`),
the first synthetic microphone's tone on the LEFT channel and the second's
on the RIGHT, one input carrying two synthetic microphones (OPEN B of the
breadth notes). Colours and tones are read out of the core's one table,
crates/kaya/src/capture.rs's SYNTHETIC, never copied. Measurements:
docs/probes/capture-2026-10-01/compose-measured.md.

`with injecting(serial) as feed:` streams from a thread of the runner's own
process until the block ends, then closes the stream and proves the thread
gone; `feed.sentence()` says what the stream did, for a red leg's log. A
minimal HTTP/2 client, since the dev shell has no gRPC library.
"""

import contextlib
import math
import os
import pathlib
import re
import socket
import struct
import threading
import time
import zlib

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
CAPTURE_RS = ROOT / "crates/kaya/src/capture.rs"

RATE = 44_100
PACKET_FRAMES = 441
AMPLITUDE = 0.5
# Each emulator writes its gRPC token into a discovery file of its own
# (measured: the console's ~/.emulator_console_auth_token is refused).
DISCOVERY = pathlib.Path.home() / "Library/Caches/TemporaryItems/avd/running"
PATH = "/android.emulation.control.EmulatorController/injectAudio"
# The pool's gRPC ports: 8554 + the console port's offset.
GRPC_BASE = 8554
CONSOLE_BASE = 5554


def synthetic():
    """The core's SYNTHETIC entries as (id, kind, facing, content) — kind
    and facing the enum's variant names."""
    text = CAPTURE_RS.read_text(encoding="utf-8")
    table = text[text.index("pub(crate) const SYNTHETIC"):]
    table = table[:table.index("];")]
    rows = re.findall(r'id: "([^"]+)",.*?kind: CaptureKind::(\w+),\s*facing: CameraFacing::(\w+),'
                      r'.*?content: (0x[0-9A-Fa-f]+|\d+),', table, re.S)
    out = [(i, k, f, int(c, 0)) for i, k, f, c in rows]
    if len([r for r in out if r[1] == "Camera"]) != 2 or len([r for r in out if r[1] == "Microphone"]) != 2:
        raise RuntimeError(f"emulator_capture: read {out!r} out of {CAPTURE_RS}'s SYNTHETIC, wanted two "
                           f"cameras and two microphones")
    return out


def lane_cameras():
    """{"front": 0xRRGGBB, "back": 0xRRGGBB}: the emulator's front camera
    carries the table's front camera, its back camera the other
    (KayaCapture.kt's kayaLaneDevice)."""
    cams = [r for r in synthetic() if r[1] == "Camera"]
    front = [r for r in cams if r[2] == "Front"]
    if len(front) != 1:
        raise RuntimeError(f"emulator_capture: {len(front)} front cameras in the core's table, wanted 1")
    return {"front": front[0][3], "back": next(r for r in cams if r is not front[0])[3]}


def lane_tones():
    """(left Hz, right Hz): the first synthetic microphone, then the second."""
    mics = [r for r in synthetic() if r[1] == "Microphone"]
    return float(mics[0][3]), float(mics[1][3])


def flat_png(rgb, width=640, height=480):
    """One colour as an 8-bit RGB PNG, the imagefile camera's whole picture."""
    pixel = bytes([(rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF])
    raw = b"".join(b"\x00" + pixel * width for _ in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def camera_images(directory):
    """The two camera pictures written under `directory` (only when their
    bytes moved), as {"front": path, "back": path}."""
    directory = pathlib.Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    out = {}
    for side, rgb in lane_cameras().items():
        path = directory / f"{side}-{rgb:06X}.png"
        png = flat_png(rgb)
        if not path.is_file() or path.read_bytes() != png:
            path.write_bytes(png)
        out[side] = path
    return out


_DATA, _HEADERS, _RST, _SETTINGS, _PING, _GOAWAY, _WINDOW = 0, 1, 3, 4, 6, 7, 8


def grpc_port(serial):
    """The gRPC port the runner gives the emulator on `serial`'s console."""
    return GRPC_BASE + int(serial.removeprefix("emulator-")) - CONSOLE_BASE


def _varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def _field(number, wire, payload):
    key = _varint(number << 3 | wire)
    if wire == 0:
        return key + _varint(payload)
    return key + _varint(len(payload)) + payload


def packet(pcm, first):
    """One AudioPacket of 44.1 kHz stereo s16 LE, the format on the first
    alone and no timestamp: a format and a timestamp on every packet, sent as
    fast as the window allowed, ended the emulator in SIGSEGV after 155-228
    packets (docs/probes/capture-2026-10-01/compose-measured.md)."""
    fmt = _field(1, 0, RATE) + _field(2, 0, 1) + _field(3, 0, 1)
    return (_field(1, 2, fmt) if first else b"") + _field(3, 2, pcm)


def tone(start, frames, hz):
    """`frames` stereo frames from frame `start`: hz[0] left, hz[1] right."""
    out = bytearray()
    for i in range(start, start + frames):
        t = i / RATE
        left = round(AMPLITUDE * 32767 * math.sin(2 * math.pi * hz[0] * t))
        right = round(AMPLITUDE * 32767 * math.sin(2 * math.pi * hz[1] * t))
        out += struct.pack("<hh", left, right)
    return bytes(out)


def _hpack_int(n, prefix_bits, first=0):
    limit = (1 << prefix_bits) - 1
    if n < limit:
        return bytes([first | n])
    out = bytearray([first | limit])
    n -= limit
    while n >= 128:
        out.append(n % 128 + 128)
        n //= 128
    out.append(n)
    return bytes(out)


def _hpack_literal(name, value):
    """A literal header field without indexing, new name, no huffman."""
    n, v = name.encode(), value.encode()
    return b"\x00" + _hpack_int(len(n), 7) + n + _hpack_int(len(v), 7) + v


def _frame(kind, flags, stream, payload):
    return struct.pack(">I", len(payload))[1:] + bytes([kind, flags]) + struct.pack(">I", stream) + payload


class Feed:
    """One injectAudio stream on its own thread."""

    def __init__(self, serial, port, token):
        self.serial = serial
        self.port = port
        self.token = token
        self.packets = 0
        self.refused = None
        self.first_at = None
        self.hz = lane_tones()
        self.ended = None
        self.stop = threading.Event()
        self.window = threading.Condition()
        self.conn_window = 65_535
        self.stream_window = 65_535
        self.sock = None
        self.thread = threading.Thread(target=self._run, name=f"inject-audio-{serial}", daemon=True)

    def sentence(self):
        if getattr(self, "attempts", 1) > 1:
            return f"(call {self.attempts}) " + self._sentence()
        return self._sentence()

    def _sentence(self):
        if self.first_at is not None:
            return (time.strftime("first packet %H:%M:%S", time.localtime(self.first_at))
                    + f".{int(self.first_at % 1 * 1000):03d}, " + self._said())
        return self._said()

    def _said(self):
        if self.ended:
            return (f"inject-audio on {self.serial} (gRPC 127.0.0.1:{self.port}) ended after "
                    f"{self.packets} packet(s): {self.ended}")
        return (f"inject-audio on {self.serial} (gRPC 127.0.0.1:{self.port}) streaming, "
                f"{self.packets} packet(s) of {PACKET_FRAMES} stereo frames sent")

    def _end(self, why):
        if self.ended is None:
            self.ended = why
        with self.window:
            self.window.notify_all()

    def _read(self):
        buf = b""
        while not self.stop.is_set():
            try:
                chunk = self.sock.recv(65_536)
            except OSError as e:
                if not self.stop.is_set():
                    self._end(f"the connection failed reading: {e}")
                return
            if not chunk:
                if not self.stop.is_set():
                    self._end("the emulator closed the connection")
                return
            buf += chunk
            while len(buf) >= 9:
                length = int.from_bytes(buf[:3], "big")
                if len(buf) < 9 + length:
                    break
                kind, flags = buf[3], buf[4]
                stream = int.from_bytes(buf[5:9], "big") & 0x7FFF_FFFF
                body = buf[9:9 + length]
                buf = buf[9 + length:]
                self._on_frame(kind, flags, stream, body)

    def _on_frame(self, kind, flags, stream, body):
        if kind == _SETTINGS and not flags & 1:
            for i in range(0, len(body) - 5, 6):
                ident, value = struct.unpack(">HI", body[i:i + 6])
                if ident == 4:
                    with self.window:
                        self.stream_window += value - 65_535
                        self.window.notify_all()
            self.sock.sendall(_frame(_SETTINGS, 1, 0, b""))
        elif kind == _WINDOW:
            grant = int.from_bytes(body[:4], "big") & 0x7FFF_FFFF
            with self.window:
                if stream == 0:
                    self.conn_window += grant
                else:
                    self.stream_window += grant
                self.window.notify_all()
        elif kind == _PING and not flags & 1:
            self.sock.sendall(_frame(_PING, 1, 0, body))
        elif kind == _RST:
            self._end(f"the emulator reset the stream (HTTP/2 error code {int.from_bytes(body[:4], 'big')})")
        elif kind == _GOAWAY:
            self._end(f"the emulator sent GOAWAY (HTTP/2 error code {int.from_bytes(body[4:8], 'big')})")
        elif kind == _HEADERS and flags & 1:
            said = re.search(rb"grpc-message.([\x20-\x7e]+)", body)
            self.refused = said.group(1).decode() if said else f"undecoded trailers {body[:120]!r}"
            self._end(f"the emulator refused the call: {self.refused}")

    def _send(self, message):
        data = b"\x00" + struct.pack(">I", len(message)) + message
        while data:
            with self.window:
                while (min(self.conn_window, self.stream_window) <= 0 and self.ended is None
                       and not self.stop.is_set()):
                    self.window.wait(0.5)
                if self.ended is not None or self.stop.is_set():
                    return False
                n = min(len(data), self.conn_window, self.stream_window, 16_384)
                self.conn_window -= n
                self.stream_window -= n
            try:
                self.sock.sendall(_frame(_DATA, 0, 1, data[:n]))
            except OSError as e:
                self._end(f"the connection failed writing: {e}")
                return False
            data = data[n:]
        return True

    def _run(self):
        try:
            self.sock = socket.create_connection(("127.0.0.1", self.port), timeout=5)
            self.sock.settimeout(None)
            self.sock.sendall(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" + _frame(_SETTINGS, 0, 0, b""))
            headers = b"".join(_hpack_literal(k, v) for k, v in (
                (":method", "POST"), (":scheme", "http"), (":path", PATH),
                (":authority", f"127.0.0.1:{self.port}"), ("content-type", "application/grpc"),
                ("te", "trailers"), ("authorization", f"Bearer {self.token}")))
            self.sock.sendall(_frame(_HEADERS, 4, 1, headers))
        except OSError as e:
            self._end(f"no gRPC server answered on 127.0.0.1:{self.port}: {e}")
            return
        reader = threading.Thread(target=self._read, name=f"inject-audio-read-{self.serial}", daemon=True)
        reader.start()
        frame = 0
        # Paced on the wall clock, 10 ms a packet: the emulator's queue holds
        # 300 ms, and a schedule that fell a second behind starts again.
        due = time.time()
        while not self.stop.is_set() and self.ended is None:
            if not self._send(packet(tone(frame, PACKET_FRAMES, self.hz), frame == 0)):
                break
            frame += PACKET_FRAMES
            self.packets += 1
            if self.first_at is None:
                self.first_at = time.time()
            due += PACKET_FRAMES / RATE
            now = time.time()
            if due - now > 0:
                self.stop.wait(due - now)
            elif now - due > 1.0:
                due = now
        with contextlib.suppress(OSError):
            self.sock.sendall(_frame(_DATA, 1, 1, b""))
        with contextlib.suppress(OSError):
            self.sock.shutdown(socket.SHUT_RDWR)
        self.sock.close()
        reader.join(5)


def discovery(serial):
    """(gRPC port, token) the emulator on `serial` wrote into its discovery
    file, or (None, why) when no live one names that console port."""
    console = serial.removeprefix("emulator-")
    seen = []
    for ini in sorted(DISCOVERY.glob("pid_*.ini")):
        try:
            os.kill(int(ini.stem.removeprefix("pid_")), 0)
        except (ValueError, OSError):
            continue
        fields = dict(line.split("=", 1) for line in ini.read_text(encoding="utf-8").splitlines() if "=" in line)
        if fields.get("port.serial") != console:
            continue
        seen.append(ini.name)
        if "grpc.port" in fields and "grpc.token" in fields:
            return int(fields["grpc.port"]), fields["grpc.token"]
    if seen:
        return None, f"{', '.join(seen)} under {DISCOVERY} name console {console} with no grpc.port and grpc.token"
    return None, f"no discovery file under {DISCOVERY} names console port {console}"


def start(serial, tries=20):
    """The tone streaming onto `serial`'s microphone, or a Feed whose
    sentence says why not. A call refused while the last stream's
    microphone is still registered is made again: its teardown lags the
    close (measured: the next call refused, the one after taken)."""
    for attempt in range(1, tries + 1):
        port, token = discovery(serial)
        feed = Feed(serial, port or grpc_port(serial), token or "")
        if port is None:
            feed.ended = token
            return feed
        feed.thread.start()
        feed.thread.join(0.4)
        if feed.refused is None or attempt == tries:
            feed.attempts = attempt
            return feed
        stop(feed)
    return feed


def stop(feed):
    """The stream closed and its thread proven gone."""
    feed.stop.set()
    with feed.window:
        feed.window.notify_all()
    if feed.thread.ident is not None:
        feed.thread.join(10)
    if feed.thread.is_alive():
        raise RuntimeError(f"inject-audio on {feed.serial}: the stream's thread outlived its leg")


@contextlib.contextmanager
def injecting(serial):
    """The tone on `serial`'s microphone for the block."""
    feed = start(serial)
    try:
        yield feed
    finally:
        stop(feed)
