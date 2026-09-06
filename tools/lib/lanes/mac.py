"""The mac lane's tables — ONE source of truth for the legs the runner
derives and the gates census (docs/runner-conversion-plan.md §2, stage
4: validate-mac). Plain data on the win/ios/android modules' model: no
I/O at import, no dev-shell guard.

One backend (the SwiftUI interpreter), eight hosted languages plus the
C floor, ~350 legs. ORDER is the queue itself: scene groups with their
language order (the order VARIES per scene and is data — dirty carries
no java leg at all, styling puts swift fourth), drain barriers as
explicit entries, the three panel view modes as entries between the
filedialog groups, and the serial families (save, clipboard, undo,
editor — one leg per drain pair, each for a measured reason recorded
at the runner's sites) as single-language groups between drains.

The runner is tools/validate-mac.py; check-steps, check-staging,
check-appearance, check-stubs and tools/lib/scene-features.py import
this instead of regexing the shell body.

THE PER-LANGUAGE GUEST BUILDS LIVE HERE TOO, one copy, called and never
copied: validate-mac.py runs all seven pooled and tools/run-leg.py runs
the one its leg needs under --build. They do I/O when CALLED, never at
import, so every census above still imports this module for its tables
alone.
"""

import re
import shutil
import subprocess
import threading

# THE scene list: the mechanical per-scene surfaces derive from it —
# the cargo --example flags, the rust-guest staging, build_swift's
# sweep. Order preserved from the shell body's one line.
SCENES = [
    "background", "stall", "milestone2", "entry", "gallery", "todos",
    "reorder", "feed", "grow", "layout", "align", "window", "panels",
    "confirm", "nav", "split", "panes", "table", "scroll", "progress",
    "select", "radio", "grid", "textarea", "sections", "menus",
    "commands", "a11y", "a11yrows", "filedialog", "clipboard", "undo",
    "dirty", "ranges", "save", "styling", "toolbar", "identity",
    "assets", "sizepolicy", "adaptive", "pickers", "sliders",
    "tooltips",
]
# Depth-slice scenes: a rust example + steps exist, the language sweep
# has not landed — built and run rust-only until their guests arrive,
# when they move into SCENES.
DEPTH_SCENES = ["typeface", "windowed", "canvas", "dnd", "tasks"]
# The C-floor scenes THIS LANE RUNS (guests/c/Makefile keeps the whole
# list; this is the SCENES= override build_c passes, and check-steps'
# sweep_c_floor reads it from the other side).
C_SCENES = ["undo", "dirty", "ranges", "save", "a11yrows", "styling",
            "assets"]

# The nine hosted languages in their DEFAULT group order; a group
# that deviates spells its own order in ORDER below. js is the ninth
# binding (docs/js-plan.md), python's ambient twin, and rides every
# group python rides.
LANGS = ("rust", "python", "go", "csharp", "ocaml", "haskell", "swift",
        "java", "js")

# Scene -> the guest STEM its scene-named launchers run, where the two
# differ: the listdetail legs run split's guests (a scene selects a
# SCRIPT, never an app). editor/portfolio/varied are single-language
# apps whose launchers already name the right artifact.
GUEST_STEM = {"listdetail": "split"}

# The dark half of expect_ink's frozen string, one leg instead of a
# lane re-run (tools/check-appearance.py holds the leg here): canvas's
# script and binary under KAYA_APPEARANCE=dark.
DARK_LEG = ("canvasdark-rust-swiftui", "canvas", "rust")

# The apps and depth scenes hand-queued OUTSIDE SCENES/DEPTH_SCENES
# (each would otherwise derive a cargo --example that does not exist):
# editor is a GO app by design, portfolio and varied are PYTHON alone.
HAND_QUEUED = {"editor": "go", "portfolio": "python", "varied": "python"}

# The queue, in run order. Entries:
#   (scene, (lang, ...))    a group: script export + one leg per lang
#   ("drain",)              the pool barrier
#   ("panel_mode", n, name) rotate the machine-wide file-panel view mode
#   ("panel_check",)        the modes-run census + restore
#   ("dark_leg",)           the canvasdark leg (DARK_LEG above)
# The single-language groups between drains ARE the serial families, each
# with its reason at the group.
ORDER = [
    ("milestone2", LANGS),
    ("entry", LANGS),
    ("gallery", LANGS),
    ("todos", LANGS),
    ("reorder", LANGS),
    ("feed", LANGS),
    ("grow", LANGS),
    ("drain",),
    ("window", LANGS),
    ("panels", LANGS),
    ("nav", LANGS),
    ("split", LANGS),
    ("panes", LANGS),
    ("table", LANGS),
    ("listdetail", LANGS),
    ("background", LANGS),
    # The eight filedialog legs SPLIT ACROSS THE THREE PANEL VIEW
    # MODES, a drain before each mode because a mode is set for
    # whatever is running, not for a leg.
    ("drain",),
    ("panel_mode", 1, "columns"),
    ("filedialog", ("rust", "python", "go")),
    ("drain",),
    ("panel_mode", 2, "list"),
    ("filedialog", ("csharp", "ocaml", "haskell")),
    ("drain",),
    ("panel_mode", 3, "icons"),
    ("filedialog", ("swift", "java", "js")),
    ("drain",),
    ("panel_check",),
    # EACH SAVE LEG ALONE BETWEEN DRAINS: macOS shares a save panel's
    # last directory as a user preference across every process
    # (measured 2026-08-10).
    ("save", ("rust",)),
    ("drain",),
    ("save", ("java",)),
    ("drain",),
    ("save", ("python",)),
    ("drain",),
    ("save", ("go",)),
    ("drain",),
    ("save", ("swift",)),
    ("drain",),
    ("save", ("haskell",)),
    ("drain",),
    ("save", ("csharp",)),
    ("drain",),
    ("save", ("ocaml",)),
    ("drain",),
    ("save", ("c",)),
    ("drain",),
    ("save", ("js",)),
    ("drain",),
    # The text editor: go alone by design, alone between drains (real
    # panels, real keys).
    ("editor", ("go",)),
    ("drain",),
    ("portfolio", ("python",)),
    ("drain",),
    ("varied", ("python",)),
    ("drain",),
    ("windowed", ("rust",)),
    ("drain",),
    # The task manager: a RUST app by design (docs/tasks-plan.md §0).
    ("tasks", ("rust",)),
    ("drain",),
    ("adaptive", LANGS),
    ("drain",),
    ("a11yrows", (*LANGS, "c")),
    ("drain",),
    ("styling", ("rust", "python", "go", "swift", "csharp", "ocaml",
                 "haskell", "java", "js", "c")),
    ("drain",),
    ("typeface", ("rust",)),
    ("drain",),
    ("canvas", ("rust",)),
    ("drain",),
    ("dnd", LANGS),
    ("pickers", LANGS),
    ("sliders", LANGS),
    ("tooltips", LANGS),
    ("drain",),
    ("dark_leg",),
    ("drain",),
    ("sizepolicy", LANGS),
    ("drain",),
    ("toolbar", ("rust", "python", "go", "swift", "csharp", "ocaml",
                 "haskell", "java", "js")),
    ("drain",),
    ("identity", ("rust", "python", "go", "swift", "csharp", "ocaml",
                  "haskell", "java", "js")),
    ("drain",),
    ("assets", ("rust", "python", "go", "swift", "csharp", "ocaml",
                "haskell", "java", "js", "c")),
    ("drain",),
    # EACH CLIPBOARD LEG ALONE BETWEEN DRAINS: one system clipboard
    # per session (check-steps pins the drain/run/drain bracket).
    ("clipboard", ("rust",)),
    ("drain",),
    ("clipboard", ("python",)),
    ("drain",),
    ("clipboard", ("go",)),
    ("drain",),
    ("clipboard", ("swift",)),
    ("drain",),
    ("clipboard", ("csharp",)),
    ("drain",),
    ("clipboard", ("ocaml",)),
    ("drain",),
    ("clipboard", ("haskell",)),
    ("drain",),
    ("clipboard", ("java",)),
    ("drain",),
    ("clipboard", ("js",)),
    ("drain",),
    # EACH UNDO LEG ALONE BETWEEN DRAINS: the type verb delivers real
    # keystrokes.
    ("undo", ("rust",)),
    ("drain",),
    ("undo", ("python",)),
    ("drain",),
    ("undo", ("go",)),
    ("drain",),
    ("undo", ("c",)),
    ("drain",),
    ("undo", ("haskell",)),
    ("drain",),
    ("undo", ("swift",)),
    ("drain",),
    ("undo", ("csharp",)),
    ("drain",),
    ("undo", ("ocaml",)),
    ("drain",),
    ("undo", ("java",)),
    ("drain",),
    ("undo", ("js",)),
    ("drain",),
    ("scroll", LANGS),
    ("progress", LANGS),
    ("select", LANGS),
    ("radio", LANGS),
    ("grid", LANGS),
    ("textarea", LANGS),
    ("sections", LANGS),
    ("menus", LANGS),
    ("a11y", LANGS),
    ("commands", LANGS),
    ("stall", LANGS),
    ("confirm", LANGS),
    # NO JAVA LEG in the dirty group — real coverage, not an
    # oversight (the sugar's java arm has no dirty guest yet); order
    # follows the per-binding commentary at the runner's site.
    ("dirty", ("rust", "python", "ocaml", "c", "go", "haskell",
               "swift", "csharp", "js")),
    ("ranges", ("rust", "python", "c", "csharp", "go", "java",
                "haskell", "swift", "ocaml", "js")),
    ("align", LANGS),
    ("drain",),
    ("layout", LANGS),
    ("drain",),
]


def leg_name(scene, lang):
    """milestone2's legs ARE the unprefixed originals."""
    if scene == "milestone2":
        return f"{lang}-swiftui"
    return f"{scene}-{lang}-swiftui"


def guest_stem(scene):
    """The artifact stem a scene-named launcher runs."""
    return GUEST_STEM.get(scene, scene)


def legs():
    """Every leg as (name, scene, lang), queue order."""
    out = []
    for entry in ORDER:
        if entry[0] == "dark_leg":
            name, scene, lang = DARK_LEG
            out.append((name, scene, lang))
        elif entry[0] not in ("drain", "panel_mode", "panel_check"):
            scene, langs = entry
            out.extend((leg_name(scene, lang), scene, lang)
                       for lang in langs)
    return out


def blocks():
    """Leg names grouped between drains — the serial families are the
    single-leg blocks."""
    out = [[]]
    for entry in ORDER:
        if entry[0] == "drain":
            if out[-1]:
                out.append([])
        elif entry[0] == "dark_leg":
            out[-1].append(DARK_LEG[0])
        elif entry[0] not in ("panel_mode", "panel_check"):
            scene, langs = entry
            out[-1].extend(leg_name(scene, lang) for lang in langs)
    if not out[-1]:
        out.pop()
    return out


def wired_scenes():
    """The scenes some leg runs — the gates' census surface."""
    return {scene for _name, scene, _lang in legs()}


# THE LEG'S COMMAND AND SCRIPT, one copy: validate-mac.py runs the roster
# through these and run-leg.py runs ONE leg by hand through the same two
# (docs/traps.md, 2026-09-01 — a hand-spelled env ran a stale interpreter).
KAYA_LIB_LANGS = ("csharp", "ocaml", "java")
RUST_GUESTS = "target/rust-guests"
CS_GUEST = "guests/csharp/bin/Debug/net10.0/kaya-guests.dll"


def leg_argv(scene, lang, hs_bin):
    """The guest command for one leg; `hs_bin(stem)` resolves a Haskell
    binary (cabal list-bin) so this module does no I/O of its own."""
    stem = guest_stem(scene)
    if lang == "rust":
        return [f"{RUST_GUESTS}/{stem}"]
    if lang == "python":
        return ["python3", f"guests/python/{stem}.py"]
    if lang == "js":
        return ["node", f"guests/js/{stem}.ts"]
    if lang == "go":
        return ["target/go-guests/kaya-go"]
    if lang == "csharp":
        return ["dotnet", "exec", CS_GUEST]
    if lang == "ocaml":
        return [f"_build/default/guests/ocaml/{stem}.exe"]
    if lang == "haskell":
        return [hs_bin(stem)]
    if lang == "swift":
        return [f"target/swift-guests/{stem}"]
    if lang == "java":
        return ["java", "-XstartOnFirstThread", "-cp",
                "target/java-guests", "dev.kaya.guests.Main"]
    if lang == "c":
        return [f"target/c-guests/{stem}"]
    raise ValueError(lang)


def scene_script(root, scene):
    """The scene script's TEXT for the interpreter's environment, comments
    stripped: some transports fold newlines into `;`, and a leading
    comment must not swallow the folded script. Newlines are kept."""
    lines = [line for line in
             (root / f"tools/scenes/{scene}.steps").read_text(
                 encoding="utf-8").splitlines()
             if not line.startswith("#")]
    return "\n".join(lines)


def leg_env(root, scene, lang, appearance=""):
    """Per-leg env, never a persisting export (the shell's one
    KAYA_SELFTEST_SCRIPT export once ran another scene's steps)."""
    env = {"KAYA_SELFTEST": "1" if scene == "milestone2" else scene,
           "KAYA_SELFTEST_SCRIPT": scene_script(root, scene),
           "KAYA_SWIFTUI_LIB": str(root / "target/swiftui/libkaya_swiftui.dylib")}
    if lang in KAYA_LIB_LANGS:
        env["KAYA_LIB"] = str(root / "target/debug/libkaya.dylib")
    if lang == "python":
        env["PYTHONPATH"] = str(root / "bindings/python")
    if appearance:
        env["KAYA_APPEARANCE"] = appearance
    return env


# ------------------------------------------------------- the guest builds
# ONE COPY OF EVERY BUILD (docs/deferred.md's run-leg entry): the lane
# builds all seven pooled, a hand run builds the one language its leg
# needs, and neither can drift into building it a different way.

def _run(argv, log, **kw):
    """One build command. `log` is a path opened in APPEND mode, or None
    to stream to this process's own stdout — the hand run watches its
    build, the lane keeps a per-language log to print on failure."""
    if log is None:
        return subprocess.run(argv, check=False, **kw)
    with open(log, "a", encoding="utf-8") as f:
        return subprocess.run(argv, check=False, stdout=f,
                              stderr=subprocess.STDOUT, **kw)


def build_ocaml(root, log=None):
    # --root . BECAUSE DUNE WALKS UP: run from a git worktree under
    # the repo, a bare `dune build` builds the PARENT checkout
    # (measured 2026-08-28).
    return _run(["dune", "build", "--root", "."], log, cwd=root)


def build_haskell(root, log=None):
    return _run(["cabal", "build", "all",
                 f"--extra-lib-dirs={root}/target/debug",
                 f"--ghc-options=-L{root}/target/debug "
                 f"-optl-Wl,-rpath,{root}/target/debug", "-v0"],
                log, cwd=root / "guests/haskell")


def build_csharp(root, log=None):
    # dotnet run rebuilds per invocation; build once, legs exec it.
    return _run(["dotnet", "build", "--nologo", "-v", "q",
                 "guests/csharp/kaya-guests.csproj"], log, cwd=root)


def build_go(root, log=None):
    # ONE BINARY FOR EVERY SCENE: guests/go/cmd imports every scene
    # library and picks one from KAYA_SELFTEST. encodebench is
    # guest-only and a benchmark, its own main package.
    (root / "target/go-guests").mkdir(parents=True, exist_ok=True)
    rc = _run(["go", "build", "-o", "target/go-guests/kaya-go",
               "dev.kaya/guests/go/cmd"], log, cwd=root)
    if rc.returncode != 0:
        return rc
    return _run(["go", "build", "-o", "target/go-guests/encodebench",
                 "dev.kaya/guests/go/encodebench"], log, cwd=root)


def build_swift(root, log=None):
    """The same bindings the iOS bundles compile, linked against
    libkaya.dylib. swiftc allows top-level code only in a file named
    main.swift, so each scene gets its own staging dir and the
    compiles pool. DEPTH_SCENES too: a depth slice's guests arrive one
    language at a time, and the file test decides — a scene whose
    Swift guest has not landed is skipped, not a build failure."""
    (root / "target/swift-guests").mkdir(parents=True, exist_ok=True)
    procs = []
    for guest in [*SCENES, *DEPTH_SCENES]:
        src = root / f"guests/swift/{guest}.swift"
        if not src.is_file():
            continue
        stage = root / f"target/swift-guests/.stage-{guest}"
        shutil.rmtree(stage, ignore_errors=True)
        stage.mkdir(parents=True)
        shutil.copy2(src, stage / "main.swift")
        companions = []
        if (root / f"guests/swift/{guest}+Kaya.swift").is_file():
            companions = [f"guests/swift/{guest}+Kaya.swift"]
        blog = open(stage / "build.log", "w", encoding="utf-8")
        p = subprocess.Popen(
            ["bash", "-c",
             'source "$1/tools/lib/swift-toolchain.sh" && shift && '
             'kaya_swiftc "$@"', "_", str(root),
             "-import-objc-header", "crates/kaya/include/kaya.h",
             "bindings/swift/KayaWire.swift",
             "bindings/swift/KayaApp.swift",
             "bindings/swift/KayaRecords.swift",
             "bindings/swift/KayaSums.swift",
             *companions, str(stage / "main.swift"),
             "-L", "target/debug", "-lkaya",
             "-Xlinker", "-rpath", "-Xlinker",
             f"{root}/target/debug",
             "-o", f"target/swift-guests/{guest}"],
            stdout=blog, stderr=blog, cwd=root)
        procs.append((guest, stage, p, blog))
    rc = 0
    for guest, stage, p, blog in procs:
        failed = p.wait() != 0
        blog.close()
        if failed:
            rc = 1
            text = (stage / "build.log").read_text(encoding="utf-8",
                                                   errors="replace")
            if log is None:
                print(text, end="")
            else:
                with open(log, "a", encoding="utf-8") as out:
                    out.write(text)
    for stage in (root / "target/swift-guests").glob(".stage-*"):
        shutil.rmtree(stage, ignore_errors=True)
    return subprocess.CompletedProcess([], rc)


def build_c(root, log=None):
    # THE C FLOOR, THE SCENES THIS LANE ACTUALLY RUNS: C_SCENES, which
    # check-steps' sweep_c_floor reads from the other side — a guest
    # built here and run nowhere is false coverage.
    return _run(["make", "-C", "guests/c",
                 f"SCENES={' '.join(C_SCENES)}",
                 f"TARGET_DIR={root}/target/debug",
                 f"OUT={root}/target/c-guests"], log, cwd=root)


def build_java(root, log=None):
    # The shared binding + the desktop transport + every scene + the
    # Main selector, one javac.
    shutil.rmtree(root / "target/java-guests", ignore_errors=True)
    (root / "target/java-guests").mkdir(parents=True)
    srcs = ["bindings/java-desktop/dev/kaya/KayaRing.java",
            *sorted(str(p.relative_to(root))
                    for p in (root / "bindings/java/dev/kaya"
                              ).glob("*.java")),
            *sorted(str(p.relative_to(root))
                    for p in (root / "guests/java/dev/kaya/guests"
                              ).glob("*.java"))]
    return _run(["javac", "-encoding", "UTF-8", "-d",
                 "target/java-guests", *srcs], log, cwd=root)


# The COMPILED languages, in the order the lane starts them. rust is not
# here: its example is built and staged per leg (validate-mac stages the
# whole set up front, run-leg one stem every run). python and js run from
# source, so their binding is always the tree's.
GUEST_BUILDS = {
    "ocaml": build_ocaml,
    "haskell": build_haskell,
    "csharp": build_csharp,
    "go": build_go,
    "swift": build_swift,
    "java": build_java,
    "c": build_c,
}

# THE SPEC A STAGED GUEST WAS BUILT AGAINST. A compiled guest carries the
# wire hash its binding was generated from and refuses a library speaking
# another one, so a guest staged before a spec move dies at LAUNCH naming
# both hashes (docs/traps.md, 2026-09-06). Nothing on disk said which spec
# the staged tree came from, so a hand run could only learn it by watching
# the panic; every build that succeeds writes it here instead.
SPEC_STAMPS = "target/guest-specs"


def spec_hash(root):
    """The tree's protocol fingerprint out of the generated C header, or
    None if the header does not declare one. bindings/c/kaya_wire.h is the
    right file to ask: gen-bindings.py writes every binding's copy from
    the same spec in one pass, and tools/gen-bindings.py --check is a gate,
    so the header and the nine bindings cannot disagree."""
    text = (root / "bindings/c/kaya_wire.h").read_text(encoding="utf-8")
    m = re.search(r"^#define KAYA_SPEC_HASH\s+(0x[0-9a-fA-F]+)", text, re.M)
    return m.group(1) if m else None


def spec_stamp(root, lang):
    return root / SPEC_STAMPS / f"{lang}.spec"


def stamp_spec(root, lang):
    """Record the spec this build compiled against. Called only after a
    build returned 0 — a stamp over a failed build is the stale artifact
    with a fresh label on it. An unreadable header stamps NOTHING and
    still says so: spec_stamp_problem reads the header first, so the
    missing stamp is never the sentence the reader gets."""
    got = spec_hash(root)
    if got is None:
        return
    p = spec_stamp(root, lang)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(got + "\n", encoding="utf-8")


def spec_stamp_problem(root, lang):
    """None, or the sentence refusing to run a staged guest that is not
    this tree's spec. THREE causes, THREE sentences, each printing only
    what it measured (CLAUDE.md invariant 3)."""
    if lang not in GUEST_BUILDS:
        return None
    want = spec_hash(root)
    if want is None:
        return (f"bindings/c/kaya_wire.h declares no KAYA_SPEC_HASH, so "
                f"nothing here can say which protocol the staged {lang} "
                f"guest speaks. Run tools/gen-bindings.py — the header is "
                f"generated, and every binding's copy moves with it.")
    p = spec_stamp(root, lang)
    if not p.is_file():
        return (f"nothing recorded which spec the staged {lang} guest was "
                f"built against ({SPEC_STAMPS}/{lang}.spec is not there), "
                f"and this tree's bindings/c/kaya_wire.h says {want}. A "
                f"guest staged before a spec move dies at launch with "
                f"`library speaks spec {want}, this binding was generated "
                f"from <older>`. Re-run with --build.")
    got = p.read_text(encoding="utf-8").strip()
    if got != want:
        return (f"the staged {lang} guest was built against spec {got} and "
                f"this tree's bindings/c/kaya_wire.h says {want}: it would "
                f"die at launch with `library speaks spec {want}, this "
                f"binding was generated from {got}`. Re-run with --build.")
    return None


def build_guests(root, langs, log_dir=None):
    """The named languages' builds, POOLED (measured 2026-07-22: 29-38s
    serial, bounded by the slowest language pooled). Each writes
    `<log_dir>/<lang>.log`, or streams to stdout when log_dir is None.
    Returns {lang: returncode}, with 1 for a build whose thread died."""
    rc = {}
    threads = []
    for lang in langs:
        fn = GUEST_BUILDS[lang]
        log = (log_dir / f"{lang}.log") if log_dir is not None else None

        def go(lang=lang, fn=fn, log=log):
            got = fn(root, log).returncode
            if got == 0:
                stamp_spec(root, lang)
            rc[lang] = got

        t = threading.Thread(target=go)
        t.start()
        threads.append(t)
    for t in threads:
        t.join()
    return {lang: rc.get(lang, 1) for lang in langs}


_HS_BINS = {}


def hs_bin(root, name):
    """A Haskell guest's binary, cached — cabal takes ~0.4s to answer and
    the lane asks once per haskell leg."""
    key = (str(root), name)
    if key not in _HS_BINS:
        got = subprocess.run(["cabal", "list-bin", name, "-v0"],
                             cwd=root / "guests/haskell",
                             stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, check=False,
                             text=True, encoding="utf-8", errors="replace")
        _HS_BINS[key] = got.stdout.strip()
    return _HS_BINS[key]

