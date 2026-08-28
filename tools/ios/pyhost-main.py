"""The iOS python-host entry, staged into the bundle as app/main.py:
one bundle carries every python scene — the Android APK's
one-artifact-many-scenes pattern — and KAYA_SELFTEST names the guest
file (docs/python-mobile-plan.md §D6)."""
import os
import pathlib
import runpy

scene = os.environ.get("KAYA_SELFTEST", "")
here = pathlib.Path(__file__).resolve().parent
guest = here / f"{scene}.py"
if not guest.is_file():
    raise SystemExit(
        f"pyhost: no guest for scene {scene!r} at {guest} — stage the "
        "guest in run-sim.sh's IOS_PYTHON_SCENES or fix KAYA_SELFTEST"
    )
runpy.run_path(str(guest), run_name="__main__")
