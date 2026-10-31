"""The windows lane's leg launchers, derived from the roster in
tools/lib/lanes/win.py (docs/deferred.md, the windows launchers were 300
checked-in near-copies). schtasks starts a command line and the leg's
environment has to be set before the guest, so every leg still runs a .cmd;
deploy-win writes them from here into a staging directory and ships them,
and the gates read `text()` rather than a file.

Plain data and string building: no I/O at import, no dev-shell guard.
"""

import media_server

# The per-leg facts that are not the roster's: what a leg sets beyond its
# scene. Keyed by the leg's scene (win.scene_lang).
LOCALES = {"formatde": "de-DE", "formatar": "ar-EG", "numberfieldde": "de-DE",
           "numberfieldar": "ar-EG", "rangertl": "ar-EG", "scrollrtl": "ar-EG",
           "tasksrtl": "ar-EG"}
IDENTITIES = {"music": "identities/music.toml"}
# Python's -P: the script's directory is C:\kaya, where the lane stages
# every guest flat, so a guest that imports a stdlib-shadowed name runs
# without it on sys.path.
PYTHON_ISOLATED = {"music", "netimage_http"}
# The two witnesses start no kaya guest (docs/dnd-plan.md §5 step 7).
WITNESSES = {"dndwitness_rust": "out", "dndforeign_rust": "in"}

PYTHON_RUNTIME_DIR = r"C:\Users\Akhil\AppData\Local\Programs\Python\Python313-arm64"
NODE_DIR = r"C:\kaya\node24\node-v24.19.0-win-arm64"

STATE_HOME = [
    "rem THE LEG'S OWN STATE HOME (docs/tasks-s4-plan.md P7): every act one",
    "rem empties the app's harness tree, so each leg has its own, cleared",
    "rem here and nowhere else.",
]


def _scene(win, leg):
    """(selftest, stem, scene): the scene the leg's script names, the guest
    it runs and the roster's scene."""
    scene, _ = win.scene_lang(leg)
    if leg in win.MILESTONE2_LEGS:
        return "1", "milestone2", scene
    selftest = scene[:-len("dark")] if scene.endswith("dark") and scene != "dark" else scene
    return selftest, win.guest_stem(selftest), scene


def _environment(win, leg, selftest, scene):
    lines = [f"rmdir /s /q C:\\kaya\\legs\\{leg} 2>nul",
             f"mkdir C:\\kaya\\legs\\{leg}\\state 2>nul",
             f"set XDG_STATE_HOME=C:\\kaya\\legs\\{leg}\\state"]
    if media_server.serves(scene):
        lines.append(f"set KAYA_MEDIA_URL=http://{win.MEDIA_HOST}:{media_server.LANE_PORTS['windows']}")
    stem = win.guest_stem(selftest)
    if stem in IDENTITIES:
        lines.append(f"set KAYA_IDENTITY={IDENTITIES[stem]}")
    if scene in LOCALES:
        lines.append(f"set KAYA_LOCALE={LOCALES[scene]}")
    lines += [f"set KAYA_SELFTEST={selftest}",
              f"set KAYA_VERB_TRACE=C:\\kaya\\flightrec\\{leg}-vtrace.txt"]
    return lines


def _out(leg):
    return f"C:\\kaya\\out_{leg}.txt"


def _run(command, leg):
    return [f"{command} > {_out(leg)} 2>&1", f"echo EXIT=%ERRORLEVEL% >> {_out(leg)}"]


def _pri_beside(directory):
    """ms-appx (XamlControlsResources) resolves against the PROCESS exe's
    directory, so the runtime's directory gets kaya's resources.pri."""
    return [f'copy /y C:\\kaya\\resources.pri "{directory}\\resources.pri" >nul']


def _packaged(win, leg):
    scene = win.PACKAGED_LEGS[leg]
    inner = win.packaged_inner(leg)
    return ["@echo off", "cd /d C:\\kaya",
            "rem AN INVOKER THAT FAILS SAYS SO IN THE LEG'S OWN FILE (measured",
            "rem 2026-09-08: a silent one cost the whole 298s deadline).",
            f"powershell -NoProfile -ExecutionPolicy Bypass -File C:\\kaya\\pkg-run.ps1 -AppId {scene} "
            f"-Inner {inner} -Slot \"%KAYA_WIN_SLOT%\" > C:\\kaya\\out_{leg}-invoke.txt 2>&1",
            "if not errorlevel 1 goto :eof",
            f"copy /y C:\\kaya\\out_{leg}-invoke.txt {_out(leg)} >nul",
            f"echo EXIT=1 >> {_out(leg)}"]


def _packaged_inner(win, leg):
    scene = win.PACKAGED_LEGS[leg]
    return (["@echo off",
             "rem %1 the installed package's location, %2 the tile slot. The caller's",
             "rem environment does not cross Invoke-CommandInDesktopPackage, so every",
             "rem KAYA_ variable this leg needs is set HERE (docs/packaging-plan.md P3).",
             "cd /d C:\\kaya"]
            + STATE_HOME + _environment(win, leg, scene, scene)
            + ["set KAYA_WIN_SLOT=%2", "set KAYA_ASSET_DIR="]
            + _run(f'"%~1\\{scene}.exe"', leg))


def _guest(win, leg):
    selftest, stem, scene = _scene(win, leg)
    lang = "rust" if leg == "rust" else win.scene_lang(leg)[1]
    head = ["@echo off", "cd /d C:\\kaya\\cs" if lang == "csharp" else "cd /d C:\\kaya"]
    if scene.endswith("dark") and leg not in win.MILESTONE2_LEGS:
        head.append("set KAYA_APPEARANCE=dark")
    env = STATE_HOME + _environment(win, leg, selftest, scene)
    if lang == "rust":
        return head + env + _run(f"{stem}.exe", leg)
    if lang == "python":
        flag = " -P" if stem in PYTHON_ISOLATED else ""
        return (head + ["set PATH=C:\\kaya;%PATH%", "set PYTHONPATH=C:\\kaya\\bindings\\python"]
                + env + _pri_beside(PYTHON_RUNTIME_DIR) + _run(f"python{flag} C:\\kaya\\{stem}.py", leg))
    if lang == "js":
        return (head + [f"set PATH=C:\\kaya;{NODE_DIR};%PATH%", "set KAYA_LIB=C:\\kaya\\kaya.dll"]
                + env + _run(f"node C:\\kaya\\{stem}.ts", leg))
    if lang == "java":
        return (head + ["set PATH=C:\\kaya;%PATH%"] + env
                + ["for /f \"delims=\" %%J in ('where java') do copy /y C:\\kaya\\resources.pri "
                   "\"%%~dpJresources.pri\" >nul"]
                + _run("java -cp C:\\kaya\\java\\classes dev.kaya.guests.Main", leg))
    if lang == "csharp":
        return (head + ["set PATH=C:\\kaya;%PATH%"] + env + ["set DOTNET_CLI_TELEMETRY_OPTOUT=1",
                "rem Built once at deploy, resources.pri beside the apphost (docs/traps.md,",
                "rem shared build directories cannot be built per-leg)."]
                + _run("C:\\kaya\\cs-out\\kaya-guests.exe", leg))
    if lang == "go":
        exe = f"C:\\kaya\\legs\\{leg}\\{stem}_go.exe"
        return (head + ["for /d %%d in (C:\\kaya\\llvm-mingw-*) do set MINGW=%%d\\bin",
                        "set PATH=C:\\kaya;%MINGW%;C:\\kaya\\go127\\go\\bin;C:\\Program Files\\Go\\bin;%PATH%"]
                + env
                + ["rem One Go link a lane (go-warm); the leg runs a copy under its own name",
                   "rem (docs/traps.md, the Windows Go legs linked the guest once each).",
                   f"copy /y C:\\kaya\\goguest.exe {exe} >nul 2>&1 || goto nocopy"]
                + _pri_beside(f"C:\\kaya\\legs\\{leg}")
                + _run(exe, leg)
                + ["exit /b", ":nocopy",
                   f"echo run_{leg}.cmd: C:\\kaya\\goguest.exe did not copy to {exe}; go-warm builds it, "
                   f"and a running {stem}_go.exe holds the name> {_out(leg)}",
                   f"echo EXIT=1 >> {_out(leg)}"])
    raise ValueError(f"win_launchers: no launcher shape for {leg} ({lang})")


def names(win):
    """Every launcher file a lane run ships: each leg's, and each packaged
    leg's inner one."""
    out = [win.launcher(leg) for leg in win.legs()]
    out += [win.packaged_inner(leg) for leg in win.legs() if leg in win.PACKAGED_LEGS]
    return out


def text(win, name):
    """One launcher's text, CRLF throughout (cmd.exe mis-reads a label in a
    LF-only file past a 512-byte boundary)."""
    if name.startswith("pkg_"):
        lines = _packaged_inner(win, name[len("pkg_"):-len(".cmd")])
    else:
        leg = name[len("run_"):-len(".cmd")]
        if leg not in set(win.legs()):
            raise KeyError(f"win_launchers: no leg {leg} in tools/lib/lanes/win.py")
        if leg in WITNESSES:
            lines = ["@echo off", "cd /d C:\\kaya",
                     f"powershell -NoProfile -ExecutionPolicy Bypass -File C:\\kaya\\dnd-witness.ps1 "
                     f"-Direction {WITNESSES[leg]} > {_out(leg)} 2>&1",
                     f"echo EXIT=%ERRORLEVEL% >> {_out(leg)}"]
        elif leg in win.PACKAGED_LEGS:
            lines = _packaged(win, leg)
        else:
            lines = _guest(win, leg)
    return "\r\n".join(lines) + "\r\n"


def materialize(win, directory):
    """Write every launcher into `directory`; the paths written."""
    directory.mkdir(parents=True, exist_ok=True)
    for stale in directory.glob("*.cmd"):
        stale.unlink()
    written = []
    for name in names(win):
        path = directory / name
        path.write_bytes(text(win, name).encode("ascii"))
        written.append(path)
    return written
