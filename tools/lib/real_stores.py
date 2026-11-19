"""The user's REAL stores for a kaya app id, read so a run can prove it wrote
none of them (docs/traps.md, a gate wrote the user's real session store).

Every root an app's own store lives under (prefs, data, session, reference
ledger) on the host this runs on, filtered to `dev.kaya*` entries and the
domains AppKit names after a mac leg's bare executable; a lane bundle's
`.lane` domain is the harness's scratch by name and is left out. A
`.selftest` suite is NOT: the scratch store lives in the scratch tree
(crates/kaya/src/prefs.rs scratch_domain), so one here is a leak. A snapshot is {path: (kind, size, mtime_ns)}, a preference plist's by
its parsed content instead, since cfprefsd rewrites one whose content a run
left as it found it (the mac lane's windowmem sentinel plants and removes a
key by design; docs/traps.md, AppKit's frame autosave); `moved` names what a
run created, changed or removed.
"""

import hashlib
import os
import pathlib
import plistlib
import sys

PREFIX = "dev.kaya"


def roots(env=None, platform=None):
    env = os.environ if env is None else env
    platform = sys.platform if platform is None else platform
    home = pathlib.Path(env.get("HOME") or "~").expanduser()
    if platform == "darwin":
        return [home / "Library/Application Support", home / "Library/Preferences"]
    if platform.startswith("win"):
        return [pathlib.Path(env[k]) for k in ("LOCALAPPDATA", "APPDATA") if env.get(k)]

    def xdg(var, fallback):
        return pathlib.Path(env[var]) if env.get(var) else home / fallback

    return [xdg("XDG_STATE_HOME", ".local/state"), xdg("XDG_DATA_HOME", ".local/share"),
            xdg("XDG_CONFIG_HOME", ".config")]


def _entry(path):
    try:
        st = path.lstat()
    except OSError:
        return None
    kind = "dir" if path.is_dir() and not path.is_symlink() else "file"
    if kind == "file" and path.suffix == ".plist":
        try:
            with open(path, "rb") as f:
                content = repr(sorted(plistlib.load(f).items()))
            return ("plist", hashlib.sha256(content.encode()).hexdigest(), 0)
        except (OSError, plistlib.InvalidFileException, ValueError):
            pass
    return (kind, 0 if kind == "dir" else st.st_size, 0 if kind == "dir" else st.st_mtime_ns)


def scratch_bundle(name):
    """A lane bundle's own domain (packaging/mac.py LANE_SUFFIX), scratch by name."""
    from packaging.mac import LANE_SUFFIX
    stem = name[:-len(".plist")] if name.endswith(".plist") else name
    return stem.endswith(LANE_SUFFIX)


def executable_domains():
    """The plist names AppKit gives a mac leg run as a bare executable: every
    guest stem, its OCaml `.exe`, kaya-go and the four hosts (lanes/mac.py
    give_lane_identity is what keeps them from being written)."""
    import lanes.mac as lane
    stems = {lane.guest_stem(scene) for _name, scene, _lang in lane.legs()}
    names = stems | {f"{s}.exe" for s in stems} | {"kaya-go"} | set(lane.HOSTS.values())
    return {f"{n}.plist" for n in names}


def watched(name, exe_domains):
    if name in exe_domains:
        return True
    return name.startswith(PREFIX) and not scratch_bundle(name)


def snapshot(under=None):
    seen = {}
    exe_domains = executable_domains()
    for root in roots() if under is None else under:
        try:
            tops = [p for p in root.iterdir() if watched(p.name, exe_domains)]
        except OSError:
            continue
        for top in tops:
            entry = _entry(top)
            if entry is None:
                continue
            seen[str(top)] = entry
            if entry[0] != "dir":
                continue
            for dirpath, dirs, files in os.walk(top):
                for name in dirs + files:
                    p = pathlib.Path(dirpath) / name
                    e = _entry(p)
                    if e is not None:
                        seen[str(p)] = e
    return seen


class LegWatch:
    """The wall per leg on a lane that runs legs side by side (validate-mac,
    run-leg): a store that moved by a leg's end is named with every leg that
    ran since the last look, the one ending first."""

    def __init__(self):
        import threading
        self.lock = threading.Lock()
        self.snap = snapshot()
        self.running = set()
        self.since = set()
        self.refused = []

    def began(self, name):
        with self.lock:
            self.running.add(name)
            self.since.add(name)

    def ended(self, name):
        with self.lock:
            self.running.discard(name)
            now = snapshot()
            changes = moved(self.snap, now)
            if changes:
                self.snap = now
                beside = sorted(self.since - {name})
                self.refused.append(refusal(
                    f"{name}" + (f" (or {', '.join(beside)}, which ran since the last look)"
                                 if beside else ""), changes))
            self.since = set(self.running)


def moved(before, after):
    out = []
    for path in sorted(set(before) | set(after)):
        was, now = before.get(path), after.get(path)
        if was == now:
            continue
        what = "created" if was is None else "removed" if now is None else "changed"
        out.append(f"{what} {path}")
    return out


def refusal(who, changes):
    """The sentence a run prints when it touched a real store: what moved, and
    the one thing it cannot tell (a kaya app run by hand meanwhile)."""
    shown = "; ".join(changes[:8]) + (f"; and {len(changes) - 8} more" if len(changes) > 8 else "")
    return (f"{who} CHANGED THE USER'S REAL kaya STORE: {shown}. Tests, gates and lanes "
            f"write only the harness's scratch (KAYA_SELFTEST, docs/traps.md, a gate wrote "
            f"the user's real session store); this check cannot tell that from a kaya app "
            f"run by hand during the run. Remove what was created once the cause is fixed")
