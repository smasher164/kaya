"""The macOS arm: one .app bundle generator (docs/packaging-plan.md P4).

ONE CODE PATH for the lane and for a shipped bundle. The mac lane's
wrapper (tools/lib/lanes/mac.py `stage_rust`) calls this, so a bundle a
leg runs and a bundle a user would double-click are assembled by the
same lines — a wrapper of its own is how the lane's plist and a real one
drift.

Every rung of the icon set is RESAMPLED FROM THE DECLARED FILE (P2 as
ruled 2026-09-08): the arm knows nothing about what the picture is, and
`sips` is gone from this path — it sized the declared file one rung at a
time out of a source smaller than the set it was filling, which is the
upscale the ruling forbids.
"""

import pathlib
import shutil
import subprocess

from . import mark
from .identity import load

# What iconutil wants, and the size each member is resampled to. Two
# members share a size on purpose — an iconset names a POINT size and a
# scale, and 16x16@2x and 32x32 are the same 32 pixels.
ICONSET = ((16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
           (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
           (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
           (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
           (512, "icon_512x512.png"))
LSREGISTER = ("/System/Library/Frameworks/CoreServices.framework/"
              "Frameworks/LaunchServices.framework/Support/lsregister")


def _run(argv, what):
    done = subprocess.run(argv, capture_output=True, text=True,
                          encoding="utf-8", check=False)
    if done.returncode != 0:
        raise SystemExit(
            f"package mac: {what} failed ({argv[0]} exited "
            f"{done.returncode}): "
            f"{done.stderr.strip() or done.stdout.strip()}")
    return done


def write_icns(source, dest, scratch):
    """The declared picture as an .icns at `dest`, one rung at a time."""
    iconset = scratch / "AppIcon.iconset"
    shutil.rmtree(iconset, ignore_errors=True)
    iconset.mkdir(parents=True)
    for px, member in ICONSET:
        mark.write(iconset / member, mark.resample(source, px))
    dest.parent.mkdir(parents=True, exist_ok=True)
    _run(["iconutil", "-c", "icns", str(iconset), "-o", str(dest)],
         f"assembling the bundle icon into {dest.name}")
    shutil.rmtree(iconset, ignore_errors=True)
    if not dest.is_file():
        raise SystemExit(
            f"package mac: iconutil reported success and wrote no "
            f"{dest} — the bundle would carry the platform's generic "
            f"application icon with nothing saying so")


def url_types(declared):
    """THE APP-LINK SCHEME, out of the declaration (docs/app-links-plan.md
    L1): `CFBundleURLTypes` is what makes LaunchServices hand this bundle
    a `<scheme>://…` URL at all. The scheme comes from the manifest's one
    rule — `[links] scheme`, defaulting to the declared id — so this is
    never a second spelling. The iOS arm writes the same key.
    """
    return ('  <key>CFBundleURLTypes</key>\n'
            '  <array><dict>\n'
            f'    <key>CFBundleURLName</key><string>{declared.id}.link'
            '</string>\n'
            '    <key>CFBundleURLSchemes</key>\n'
            f'    <array><string>{declared.scheme}</string></array>\n'
            '  </dict></array>\n')


def info_plist(declared, executable, accessory):
    """The plist, every value out of the declaration."""
    ui_element = ("  <key>LSUIElement</key><true/>\n" if accessory else "")
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
            '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
            '<plist version="1.0">\n<dict>\n'
            f'  <key>CFBundleExecutable</key><string>{executable}</string>\n'
            f'  <key>CFBundleIdentifier</key><string>{declared.id}</string>\n'
            f'  <key>CFBundleName</key><string>{declared.name}</string>\n'
            f'  <key>CFBundleDisplayName</key>'
            f'<string>{declared.name}</string>\n'
            '  <key>CFBundleIconFile</key><string>AppIcon</string>\n'
            '  <key>CFBundlePackageType</key><string>APPL</string>\n'
            '  <key>CFBundleShortVersionString</key><string>0.0</string>\n'
            + ui_element
            + url_types(declared)
            + '</dict>\n</plist>\n')


def bundle(root, executable, out_dir, *, stem=None, accessory=False,
           register=True):
    """Wrap `executable` in a .app under `out_dir` and return its path.

    A FRESH INODE EVERY TIME, or the kernel kills the guest at exec
    (docs/traps.md, "Code Signature Invalid"). `accessory` adds
    LSUIElement — the lanes' guests are accessory apps and a shipped one
    is not, so the caller says which. `register` tells LaunchServices,
    without which the notification centre answers "Notifications are not
    allowed for this application" (measured 2026-09-08,
    tools/mac/notifyprobe).
    """
    declared = load(root)
    name = stem or pathlib.Path(executable).name
    app = pathlib.Path(out_dir) / f"{name}.app"
    shutil.rmtree(app, ignore_errors=True)
    macos = app / "Contents/MacOS"
    macos.mkdir(parents=True)
    shutil.copy2(executable, macos / name)
    resources = app / "Contents/Resources"
    resources.mkdir()
    write_icns(declared.icon_path.read_bytes(),
               resources / "AppIcon.icns", app / "Contents")
    (app / "Contents/Info.plist").write_text(
        info_plist(declared, name, accessory), encoding="utf-8")
    _run(["codesign", "--force", "--sign", "-", str(app)],
         f"ad-hoc signing {app.name}")
    if register:
        _run([LSREGISTER, "-f", str(app)],
             f"registering {app.name} with LaunchServices")
    return app
