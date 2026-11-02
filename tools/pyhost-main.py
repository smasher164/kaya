"""The python-host entry on BOTH phone platforms, staged as app/main.py:
one bundle carries every python scene — the Android APK's
one-artifact-many-scenes pattern — and KAYA_SELFTEST names the guest
file (docs/python-mobile-plan.md §D6)."""
import os
import pathlib
import runpy

scene = os.environ.get("KAYA_SELFTEST", "")
here = pathlib.Path(__file__).resolve().parent
guest = here / f"{scene or 'portfolio'}.py"
if not guest.is_file():
    raise SystemExit(
        f'kaya: no scene named "{scene}" in this guest; the runner asked for a leg it does not carry'
    )
runpy.run_path(str(guest), run_name="__main__")
