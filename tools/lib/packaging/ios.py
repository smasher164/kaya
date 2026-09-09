"""The iOS arm: the bundle's icon family and the launch picture (P6).

The lane assembles the bundle (tools/ios/run-sim.py `make_bundle`); what
moved here is the ICON, which was one copy of the declared file and is
now the sizes the Home Screen actually draws, RESAMPLED from it.

THE 1x ENTRY IS THE DECLARED BYTES AND NOT A RESAMPLE, and the reason is
measured rather than chosen: the SwiftUI interpreter's
`kayaIOSAppIconWhyNot` reads CFBundleIconFiles' FIRST name out of the
bundle and refuses unless those bytes EQUAL the icon the guest sent over
the wire — that equality is what `expect_app_icon` rests on for iOS. So
the 1x file stays byte-equal to the declaration and @2x/@3x carry the
sizes iOS draws the 60pt tile from.
"""

import pathlib

from . import mark
from .identity import load

# The Home Screen's 60pt slot at the two scales a device has.
SCALES = ((2, 120), (3, 180))
# THE LAUNCH SLOT'S PICTURE (docs/tasks-s2-plan.md T4): UILaunchScreen
# draws it centred on the launch colour, so it is a MARK on a ground and
# not a wallpaper. 256 is the size that reads as one on every device the
# lane runs — a third of the narrow side of the smallest phone the pool
# has, and unchanged on the iPad, which is what "centred mark" means.
# The declared source is 1024, so this is a downsample like every other.
LAUNCH_PX = 256


def write_icon_family(root, bundle_dir):
    """Write the bundle's icon family and return the CFBundleIconFiles
    BASE NAME (iOS matches an entry by base name, which is what lets one
    entry stand for the @2x/@3x family)."""
    declared = load(root)
    source = declared.icon_path.read_bytes()
    out = pathlib.Path(bundle_dir)
    out.mkdir(parents=True, exist_ok=True)
    base = pathlib.Path(declared.icon).stem
    mark.write(out / f"{base}.png", source)
    for scale, px in SCALES:
        mark.write(out / f"{base}@{scale}x.png", mark.resample(source, px))
    return base


def launch_image(root):
    """The launch slot's picture, at the size the slot draws it — the
    bytes run-sim puts in the asset catalog and holds the compiled
    rendition equal to."""
    declared = load(root)
    return mark.resample(declared.launch_image_path.read_bytes(), LAUNCH_PX)
