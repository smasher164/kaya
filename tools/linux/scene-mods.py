#!/usr/bin/env python3
"""Print a scene's script as the Linux lane runs it: tools/scenes/<scene>.steps
with this lane's MODS drops taken out and its appends added
(tools/lib/lanes/linux.py), one step per line, for the leg's KAYA_SELFTEST_SCRIPT. Every dropped step is named on
stderr; a refused drop exits 1 with the shared grammar's sentence.

    tools/linux/scene-mods.py <scene>
    tools/linux/scene-mods.py --protocols <scene>

The second form prints the session protocols the scene's legs run on, and
names on stderr each one the lane table (WAYLAND_ONLY) leaves out.
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tools/lib"))
import scene_cut  # noqa: E402
from lanes import linux as lane  # noqa: E402


def protocols(scene):
    why = lane.WAYLAND_ONLY.get(scene)
    if why is None:
        print("x11 wayland")
        return 0
    print(f"scene-mods: {scene}: NOT RUN on x11 ({why})", file=sys.stderr)
    print("wayland")
    return 0


def main(argv):
    if len(argv) == 2 and argv[0] == "--protocols":
        return protocols(argv[1])
    if len(argv) != 1:
        print("usage: tools/linux/scene-mods.py [--protocols] <scene>", file=sys.stderr)
        return 2
    scene = argv[0]
    path = ROOT / f"tools/scenes/{scene}.steps"
    lines = [" ".join(line.split()) for line in
             path.read_text(encoding="utf-8").splitlines()
             if line.strip() and not line.lstrip().startswith("#")]
    try:
        scene_cut.drop_block_selftest()
        lines, taken = scene_cut.drop_blocks(lines, lane.MODS.get(scene, {}).get("drop", ()))
    except (ValueError, AssertionError) as e:
        print(f"scene-mods: {path}: {e}", file=sys.stderr)
        return 1
    for why, gone in taken:
        for line in gone:
            print(f"scene-mods: NOT RUN on this host ({why}): {line}", file=sys.stderr)
    appended = [" ".join(step.split()) for step in
                lane.MODS.get(scene, {}).get("append", "").split(";") if step.strip()]
    for line in appended:
        print(f"scene-mods: appended on this lane: {line}", file=sys.stderr)
    lines += appended
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
