#!/usr/bin/env python3
"""Print a scene's script as the Linux lane runs it: tools/scenes/<scene>.steps
with this lane's MODS drops taken out (tools/lib/lanes/linux.py), one step
per line, for the leg's KAYA_SELFTEST_SCRIPT. Every dropped step is named on
stderr; a refused drop exits 1 with the shared grammar's sentence.

    tools/linux/scene-mods.py <scene>
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "tools/lib"))
import scene_cut  # noqa: E402
from lanes import linux as lane  # noqa: E402


def main(argv):
    if len(argv) != 1:
        print("usage: tools/linux/scene-mods.py <scene>", file=sys.stderr)
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
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
