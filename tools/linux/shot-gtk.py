#!/usr/bin/env python3
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "lib"))
from kaya_gate import ROOT, dev_shell_or_die

dev_shell_or_die()

# PHOTOGRAPH ONE SCENE'S WINDOW ON GTK, the lane's own way (docs/gtk-chrome.md,
# docs/HACKING.md's Hand tools table): the scene's rust example runs in the
# lane's container under Xvfb with its steps held by a settle, an optional
# GTK settings file is injected through XDG_CONFIG_HOME (`--layout` names a
# gtk-decoration-layout, e.g. appmenu:close for GNOME's look), the root
# window is shot and the kaya window cropped out. Without --layout the
# capture shows kaya's own fallback for a session with no settings.
#
#   tools/linux/shot-gtk.py <scene> <out.png> [--layout L] [--hold-after N]
#                           [--crop WxH] [--settle-seconds S]

import argparse
import subprocess
import tempfile

ap = argparse.ArgumentParser()
ap.add_argument("scene")
ap.add_argument("out")
ap.add_argument("--layout", default=None)
ap.add_argument("--hold-after", type=int, default=0,
                help="the step line after which the scene is held (0: at the start)")
ap.add_argument("--crop", default=None,
                help="WxH from the top-left; default trims the root window to the kaya window")
ap.add_argument("--settle-seconds", type=float, default=6.0)
args = ap.parse_args()

steps_path = ROOT / "tools/scenes" / f"{args.scene}.steps"
if not steps_path.exists():
    print(f"shot-gtk: no such scene {steps_path}", file=sys.stderr)
    sys.exit(2)
lines = [line for line in steps_path.read_text(encoding="utf-8").splitlines()
         if line.strip() and not line.startswith("#")]
if args.hold_after < 0 or args.hold_after > len(lines):
    print(f"shot-gtk: --hold-after {args.hold_after} is past the scene's "
          f"{len(lines)} steps", file=sys.stderr)
    sys.exit(2)
held = lines[:args.hold_after] + ["settle 20000"]
if args.hold_after == 0 and not any(line.startswith("expect") for line in held):
    # The harness refuses a script with no expects; the first expect of
    # the scene is enough to hold it at its start.
    first = next((line for line in lines if line.startswith("expect")), None)
    if first:
        held = [first, "settle 20000"]
script = "\n".join(held) + "\n"

example = f"/work/target-linux/debug/examples/{args.scene}"
out = pathlib.Path(args.out).resolve()
out.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="kaya-shot-gtk-") as scratch:
    scratch = pathlib.Path(scratch)
    mounts = ["-v", f"{ROOT}:/work"]
    env = ["-e", f"KAYA_SELFTEST_SCRIPT={script}"]
    if args.layout:
        cfg = scratch / "config/gtk-4.0"
        cfg.mkdir(parents=True)
        (cfg / "settings.ini").write_text(
            f"[Settings]\ngtk-decoration-layout={args.layout}\n", encoding="utf-8")
        mounts += ["-v", f"{scratch / 'config'}:/kaya-config"]
        env += ["-e", "XDG_CONFIG_HOME=/kaya-config"]
    # THE EXAMPLE IS BUILT FIRST, on the lane's own target dir: a hand tool
    # runs what it built, never last lane's binary (docs/traps.md
    # 2026-09-14, the go leg that ran last build's label).
    cut = (f"-crop {args.crop}+0+0 +repage" if args.crop else "-trim +repage")
    inner = (
        f"cd /work && export CARGO_TARGET_DIR=/work/target-linux && "
        f"cargo build -p kaya --features harness --locked --example {args.scene} "
        f"2>&1 | tail -1 && "
        f"xvfb-run -a bash -c \"KAYA_SELFTEST={args.scene} {example} "
        f"> /work/target-linux/shot-gtk.log 2>&1 & sleep {args.settle_seconds}; "
        f"import -window root /work/target-linux/shot-gtk.png; kill %1\" 2>/dev/null; "
        f"convert /work/target-linux/shot-gtk.png {cut} /work/target-linux/shot-gtk-crop.png"
    )
    rc = subprocess.run(
        ["timeout", "300", "docker", "run", "--rm", *mounts, *env, "kaya-linux",
         "bash", "-c", inner], cwd=ROOT, check=False).returncode
    if rc != 0:
        print(f"shot-gtk: the container run failed (rc {rc})", file=sys.stderr)
        sys.exit(1)
crop = ROOT / "target-linux/shot-gtk-crop.png"
if not crop.exists() or crop.stat().st_size < 1000:
    print("shot-gtk: no photograph came back — read target-linux/shot-gtk.log",
          file=sys.stderr)
    sys.exit(1)
out.write_bytes(crop.read_bytes())
print(f"shot-gtk: {args.scene} -> {out} ({out.stat().st_size} bytes; "
      f"layout {args.layout or 'the fallback'}); VIEW IT before it is published")
