#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

# The media suite's local server (docs/media-plan.md §7a): guests/assets/media
# over HTTP with Range, never the internet. Started and stopped by a lane
# through tools/lib/media_server.py. Range is load-bearing: AVPlayer refuses a
# server that ignores it (-11850, docs/probes/media-suite-2026-09-29.md).

import argparse
import http.server
import os
import re
import select
import socket
import threading
import time

FAMILY = ROOT / "guests" / "assets" / "media"

TYPES = {
    ".m3u8": "application/vnd.apple.mpegurl",
    ".mpd": "application/dash+xml",
    ".m4s": "video/iso.segment",
    ".ts": "video/mp2t",
    ".vtt": "text/vtt",
    ".mp4": "video/mp4",
    ".mov": "video/quicktime",
    ".webm": "video/webm",
    ".ogg": "audio/ogg",
    ".m4a": "audio/mp4",
    ".mp3": "audio/mpeg",
    ".flac": "audio/flac",
    ".wav": "audio/wav",
}

RANGE = re.compile(r"^bytes=(\d*)-(\d*)$")

# A file under this prefix is answered one byte every TRICKLE_S: no
# platform's transport times out (media3 reads with 8 s, souphttpsrc 15 s),
# and no open finishes within the bound — the media_timeout scene's source
# (docs/media-plan.md §7c). A server that never answered was measured failing
# `network` on GStreamer before the bound.
TRICKLE = "/trickle/"
TRICKLE_S = 2.0


OPEN = 0
OPEN_LOCK = threading.Lock()


def stamp():
    now = time.time()
    ms = int(now * 1000)
    return f"{ms} " + time.strftime("%H:%M:%S", time.localtime(now)) + f".{ms % 1000:03d}"


class Handler(http.server.BaseHTTPRequestHandler):
    """Every line carries unix ms and the client's address, and a request is
    logged when it ARRIVES and again when its body has been written, with the
    connection's open and close around them: a request with no `sent` line
    is one this server never finished (docs/traps.md, the WinUI adaptive
    pipeline that goes idle)."""

    protocol_version = "HTTP/1.1"

    def say(self, text):
        client = f"{self.client_address[0]}:{self.client_address[1]}"
        sys.stderr.write(f"media-server: {stamp()} {client} {text}\n")
        sys.stderr.flush()

    def log_message(self, fmt, *args):
        self.say(fmt % args)

    def setup(self):
        global OPEN
        super().setup()
        self.served = 0
        with OPEN_LOCK:
            OPEN += 1
            n = OPEN
        self.say(f"open ({n} connections open)")

    def finish(self):
        global OPEN
        try:
            super().finish()
        finally:
            with OPEN_LOCK:
                OPEN -= 1
                n = OPEN
            self.say(f"close after {self.served} request(s) ({n} connections open)")

    def handle(self):
        try:
            super().handle()
        except (ConnectionResetError, BrokenPipeError) as e:
            self.say(f"connection ended by the client: {type(e).__name__}")

    def _file(self):
        name = self.path.split("?", 1)[0].lstrip("/")
        if not name or "/" in name or name.startswith("."):
            return None
        f = FAMILY / name
        return f if f.is_file() else None

    def _head(self, send_body):
        f = self._file()
        if f is None:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        data = f.read_bytes()
        size = len(data)
        start, end, status = 0, size - 1, 200
        rng = self.headers.get("Range")
        if rng:
            m = RANGE.match(rng.strip())
            if not m or (not m.group(1) and not m.group(2)):
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if m.group(1):
                start = int(m.group(1))
                end = min(int(m.group(2)), size - 1) if m.group(2) else size - 1
            else:
                start = max(0, size - int(m.group(2)))
            if start >= size or start > end:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            status = 206
        body = data[start:end + 1]
        began = time.monotonic()
        self.say(f"request {self.command} {self.path} range {rng or '-'}")
        self.send_response(status)
        self.send_header("Content-Type", TYPES.get(f.suffix, "application/octet-stream"))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(len(body)))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if send_body:
            self.wfile.write(body)
        self.served += 1
        self.say(f"sent {self.command} {self.path} {status} {len(body) if send_body else 0} bytes "
                 f"in {(time.monotonic() - began) * 1000:.0f} ms")

    def _trickle(self, send_body):
        """The file the rest of the path names, Range honoured, its body one
        byte per TRICKLE_S; the log says when the client let go, which is the
        backend's teardown seen from here."""
        self.path = "/" + self.path[len(TRICKLE):]
        f = self._file()
        if f is None:
            self._head(send_body)
            return
        data = f.read_bytes()
        start, end = 0, len(data) - 1
        m = RANGE.match((self.headers.get("Range") or "").strip())
        if m and m.group(1):
            start = int(m.group(1))
            end = min(int(m.group(2)), end) if m.group(2) else end
        body = data[start:end + 1]
        self.say(f"request {self.command} {TRICKLE}{self.path[1:]} range "
                 f"{self.headers.get('Range') or '-'}: trickled, a byte per {TRICKLE_S:.0f} s")
        self.send_response(206 if m else 200)
        self.send_header("Content-Type", TYPES.get(f.suffix, "application/octet-stream"))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(len(body)))
        if m:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
        self.end_headers()
        began = time.time()
        sent = 0
        try:
            while send_body and sent < len(body):
                self.wfile.write(body[sent:sent + 1])
                self.wfile.flush()
                sent += 1
                ready, _, _ = select.select([self.connection], [], [], TRICKLE_S)
                if ready and not self.connection.recv(1, socket.MSG_PEEK):
                    raise ConnectionResetError("the client closed the connection")
        except OSError as e:
            self.say(f"trickled {self.path} closed by the client after "
                     f"{time.time() - began:.1f} s, {sent} byte(s): {type(e).__name__}")
            self.close_connection = True
            return
        self.served += 1
        self.say(f"trickled {self.path} whole, {sent} byte(s) in {time.time() - began:.1f} s")

    def do_GET(self):
        if self.path.startswith(TRICKLE):
            self._trickle(True)
        else:
            self._head(True)

    def do_HEAD(self):
        if self.path.startswith(TRICKLE):
            self._trickle(False)
        else:
            self._head(False)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8765)
    args = ap.parse_args()
    server = http.server.ThreadingHTTPServer((args.bind, args.port), Handler)
    print(f"media-server: {stamp()} serving {FAMILY} on http://{args.bind}:{args.port} "
          f"pid {os.getpid()}", flush=True)
    server.serve_forever()


main()
