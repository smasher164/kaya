#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

# docs/traps.md: GTK hand capture hid a failed build and reused an old image.

import argparse
import math
import os
import re
import shlex
import subprocess
import tempfile
import time


def checked(stage, command, **kwargs):
    print(f"shot-gtk: {stage}: {shlex.join(command)}", flush=True)
    result = subprocess.run(command, cwd=ROOT, check=False, **kwargs)
    if result.returncode != 0:
        raise RuntimeError(f"{stage} exited {result.returncode}: {shlex.join(command)}")


def image_bytes(path):
    blob = path.read_bytes()
    if len(blob) < 1000 or not blob.startswith(b"\x89PNG\r\n\x1a\n"):
        raise RuntimeError(f"{path}: expected a PNG of at least 1000 bytes; got {len(blob)} bytes")
    return blob


def capture(scene, out, crop, settle):
    target = ROOT / "target-linux"
    checked("build", ["cargo", "build", "-p", "kaya", "--features", "harness",
                      "--locked", "--lib", "--example", scene],
            env=dict(os.environ, CARGO_TARGET_DIR=str(target)))
    checked("build verification", ["python3", "tools/build-id.py", "--verify",
                                   str(target / "debug/libkaya.so")])
    raw = out.with_name("root.png")
    with open(out.with_name("guest.log"), "wb") as log:
        guest = subprocess.Popen([str(target / "debug/examples" / scene)], cwd=ROOT,
                                 env=dict(os.environ, KAYA_SELFTEST=scene),
                                 stdout=log, stderr=subprocess.STDOUT)
        try:
            time.sleep(settle)
            rc = guest.poll()
            if rc is not None:
                raise RuntimeError(f"{scene} exited {rc} before the screenshot")
            checked("screenshot", ["import", "-window", "root", str(raw)])
            rc = guest.poll()
            if rc is not None:
                raise RuntimeError(f"{scene} exited {rc} during the screenshot")
            image_bytes(raw)
            cut = ["-crop", f"{crop}+0+0"] if crop else ["-trim"]
            checked("crop", ["convert", str(raw), *cut, "+repage", str(out)])
            image_bytes(out)
        finally:
            if guest.poll() is None:
                guest.terminate()
                try:
                    guest.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    guest.kill()
                    guest.wait(timeout=5)
            else:
                guest.wait()


def photograph(args, out, script):
    transcript = out.with_name(out.name + ".log")
    print(f"shot-gtk: transcript {transcript}", flush=True)
    with tempfile.TemporaryDirectory(prefix="kaya-shot-gtk-") as directory:
        scratch = pathlib.Path(directory)
        env = ["-e", "KAYA_DEV_SHELL", "-e", f"KAYA_SELFTEST_SCRIPT={script}"]
        if args.layout:
            cfg = scratch / "config/gtk-4.0"
            cfg.mkdir(parents=True)
            (cfg / "settings.ini").write_text(
                f"[Settings]\ngtk-decoration-layout={args.layout}\n", encoding="utf-8")
            env += ["-e", "XDG_CONFIG_HOME=/capture/config"]
        options = ["--crop", args.crop] if args.crop else []
        with open(transcript, "wb") as log:
            try:
                result = subprocess.run(
                    ["timeout", "300", "docker", "run", "--rm", "--init",
                     "-v", f"{ROOT}:/work", "-v", f"{scratch}:/capture", *env,
                     "-w", "/work", "kaya-linux", "xvfb-run", "-a", "python3",
                     "/work/tools/linux/shot-gtk.py", args.scene, "/capture/crop.png",
                     "--in-container", "--settle-seconds", str(args.settle_seconds),
                     *options], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=False)
            finally:
                guest_log = scratch / "guest.log"
                if guest_log.exists():
                    log.write(b"\nshot-gtk: guest output follows\n")
                    log.write(guest_log.read_bytes())
        if result.returncode != 0:
            raise RuntimeError(f"container exited {result.returncode}; read {transcript}")
        out.write_bytes(image_bytes(scratch / "crop.png"))


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("scene")
    ap.add_argument("out")
    ap.add_argument("--layout")
    ap.add_argument("--hold-after", type=int, default=0,
                    help="the step line after which the scene is held (0: at the start)")
    ap.add_argument("--crop", help="WxH from the top-left; default trims to the kaya window")
    ap.add_argument("--settle-seconds", type=float, default=6.0)
    ap.add_argument("--in-container", action="store_true", help=argparse.SUPPRESS)
    args = ap.parse_args(argv)
    if args.crop and not re.fullmatch(r"[1-9][0-9]*x[1-9][0-9]*", args.crop):
        ap.error("--crop must be positive WxH")
    if not math.isfinite(args.settle_seconds) or args.settle_seconds < 0:
        ap.error("--settle-seconds must be finite and nonnegative")
    steps_path = ROOT / "tools/scenes" / f"{args.scene}.steps"
    if not steps_path.is_file():
        ap.error(f"no such scene {steps_path}")
    lines = [line for line in steps_path.read_text(encoding="utf-8").splitlines()
             if line.strip() and not line.startswith("#")]
    if args.hold_after < 0 or args.hold_after > len(lines):
        ap.error(f"--hold-after {args.hold_after} is past the scene's {len(lines)} steps")
    held = lines[:args.hold_after] + ["settle 20000"]
    if args.hold_after == 0:
        first = next((line for line in lines if line.startswith("expect")), None)
        if first:
            held = [first, "settle 20000"]
    out = pathlib.Path(args.out).resolve()
    try:
        out.parent.mkdir(parents=True, exist_ok=True)
        if args.in_container:
            capture(args.scene, out, args.crop, args.settle_seconds)
        else:
            photograph(args, out, "\n".join(held) + "\n")
    except (OSError, RuntimeError) as error:
        print(f"shot-gtk: {error}", file=sys.stderr)
        return 1
    print(f"shot-gtk: {args.scene} -> {out} ({out.stat().st_size} bytes; "
          f"layout {args.layout or 'the fallback'}); VIEW IT before it is published")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
