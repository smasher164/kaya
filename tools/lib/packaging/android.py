"""The Android arm: the APK's launcher mipmaps (packaging-plan P6).

android/build.gradle.kts copied the declared file into one unqualified
`mipmap/` and let the platform stretch it (an unqualified mipmap is
mdpi, and a 320dpi device doubles it). The densities are RESAMPLED from
the declared source now — 48/72/96/144/192, the launcher's 48dp slot at
each scale — and there is no unqualified copy, because every device
matches one of the five and a default at the source's own size would be
a megapixel of dead weight in the package.

Gradle only packages what this wrote; tools/android/run-emulator.py runs
it at the one assemble funnel and the lane hashes the packaged bytes
against this module's own answer right after.
"""

import pathlib
import shutil

from . import mark
from .identity import load

# The resource name gradle's manifest points at, and the entry
# run-emulator.py reads back out of the APK.
MARK_RESOURCE = "kaya_mark.png"
# dp buckets and the launcher's 48dp icon at each.
DENSITIES = (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144),
             ("xxxhdpi", 192))
# MEASURED 2026-09-08: AAPT2 STAMPS A QUALIFIED DIRECTORY WITH THE API
# LEVEL ITS QUALIFIER WAS INTRODUCED AT, so `mipmap-hdpi` on disk is
# `res/mipmap-hdpi-v4` inside the package. A byte check keyed on the
# SOURCE name finds nothing there and reports a missing launcher icon
# for a build that packaged one correctly (docs/traps.md).
QUALIFIER_API = "v4"


def rendered(root):
    """[(source res dir, dir inside the APK, the bytes)].

    ONE ANSWER for both sides: `write_res` writes exactly this and
    run-emulator's `apk_icon_verify` hashes exactly this out of the
    package, so the check cannot drift from what the arm wrote.
    """
    declared = load(root)
    source = declared.icon_path.read_bytes()
    return [(f"mipmap-{bucket}",
             f"mipmap-{bucket}-{QUALIFIER_API}",
             mark.resample(source, px))
            for bucket, px in DENSITIES]


def apk_entries(root):
    """{entry inside the APK: the bytes that belong there}."""
    return {f"res/{packaged}/{MARK_RESOURCE}": data
            for _source, packaged, data in rendered(root)}


def write_res(root, out_dir):
    """Write the mipmap set under `out_dir` (an Android res directory)
    and return the paths written.

    CLEARED FIRST: AGP's resource merge is incremental over this
    directory, so a density this arm stopped writing stays in the
    package forever otherwise — measured 2026-09-08, when the
    unqualified `mipmap/` this arm dropped was still inside the APK two
    builds later."""
    out = pathlib.Path(out_dir)
    shutil.rmtree(out, ignore_errors=True)
    written = []
    for source, _packaged, data in rendered(root):
        path = out / source / MARK_RESOURCE
        mark.write(path, data)
        written.append(path)
    return written
