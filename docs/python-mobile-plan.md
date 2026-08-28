# Python on iOS and Android — the design pass

Status: DESIGN, ratified by the maintainer 2026-08-28: **packaging's
important half is Python on mobile — CPython and the binding embedded
in the iOS and Android app bundles — so the portfolio app can be
finished on all five lanes.** Registry distribution to end users
(platform wheels, pip, maven, opam and the rest) is explicitly
deferred, in the maintainer's words, until "we've ironed out things
about how to distribute all the different components of kaya and how
they're documented and built." The two rulings below (the 3.15 pin,
the entry point by Go precedent) were accepted the same day.

Evidence base: docs/probes/mobilepkg-cpython-2026.md (2026-08-28, all
claims sourced or measured; sizes are `du` output from unpacked
official artifacts, and the iOS `dlopen(NULL)` behavior was measured,
not read). The 2026-08-07 four-arm evidence base it supersedes in part:
docs/probes/mobilepkg-contract.md (whose python and threading arms are
the relevant ones).
The precedent it stands on: docs/go-mobile-plan.md, whose §0 rejected
Python for that slice over "a 36 MB iOS support bundle, a third-party
gradle plugin, and per-module framework packaging" — three costs that
have since collapsed into official python.org artifacts.

## §0 — what the research settled

- **python.org publishes official mobile binaries now.** Android
  embeddable packages since 3.14 stable (~21 MB per ABI, arm64-v8a and
  x86_64 — the emulator ABI is first-class). The iOS XCframework
  (device slice plus a fat arm64/x86_64 simulator slice) ships from the
  3.15 pre-releases; 3.15.0 final is scheduled 2026-10-01. On 3.14,
  iOS still means building the framework yourself or vendoring
  BeeWare's. Both platforms are CPython Tier 3 (PEP 730, PEP 738).
- **No scaffolding tool.** No briefcase, no Chaquopy, no buildozer:
  the official artifacts plus roughly forty lines of glue per
  platform, modelled on CPython's own testbeds. The iOS
  `.so`-to-framework conversion the App Store requires is performed by
  the artifact's own `build_utils.sh` build phase — never hand-rolled.
- **Realistic app payload** after dropping the stdlib's `test/`,
  `idlelib` and `tkinter`: ~20 MB on iOS (framework + stdlib +
  extension frameworks), ~26 MB on Android carrying both ABIs.
- **Threading fits kaya's inversion.** Nothing requires Python to own
  the process main thread; Python's own "main thread" is whichever
  thread initialized it. python-for-android ships the worker-thread
  shape in production. Signal handlers stay uninstalled off the real
  main thread.
- **ctypes is load-bearing and platform-shaped.** On iOS CPython
  itself relies on `dlopen(NULL)`; on Android CPython loads libpython
  by soname and `CDLL(None)` is not the idiom. The sharp measured
  edge: a static archive's symbols reach `dlopen(NULL)` ONLY if the
  archive was linked with `-Wl,-force_load` — a plain `-l` link drops
  every member nothing references, and `dlsym` answers NULL with no
  error anywhere.

## §1 — the decisions

### D1 — the artifact: official python.org, version 3.15, both platforms

One interpreter version everywhere (invariant 6 argues for it — the
scene scripts are byte-compared across lanes, and one CPython is one
set of `repr` behaviors), and 3.15 is the first version whose iOS
artifact python.org builds. Cost accepted: the pre-release rides until
2026-10-01, and the pin moves to final when it lands. Android could
have started on 3.14 stable today; it waits for the shared pin
instead. tools/check-pins.sh's curl clause covers the fetch the moment
a script downloads these by URL: version AND sha256, checked on the
cached path too.

### D2 — the entry point: the Go ruling, generalized (docs/go-mobile-plan.md §D5)

The question is the one Go answered 2026-08-09, and the answer
transfers whole. **A guest's spelling is identical on all five
platforms**: `portfolio.py` ends in the same `run()` everywhere, with
no platform knowledge and no second entry point. **`run()` blocks on
every platform and answers the exit code.** What differs underneath is
only who owned the process entry: on the four desktop platforms the
binding hands the calling thread to `kaya_run` (which must own the
process main thread); on the hosted platforms the HOST owns the loop,
the guest's code is already running on the app thread the host
started, and `run()` parks there as the occurrence consumer until the
core shuts down. The arm is selected by `sys.platform` (`"ios"`,
`"android"` — the official values PEP 730/738 assign), the analogue of
Go's `hostedEntry` constant. The wall stays the core's:
`kaya_run` is a hard panic on hosted platforms (crates/kaya/src/capi.rs),
so the wrong shape fails loudly rather than deadlocking two loops.
kaya refuses Gio's wart here exactly as Go did: one call, one meaning,
no line that is live on one host and dead on another.

### D3 — reaching the core: ctypes, dispatched once, with the force_load wall

The pure-Python binding is unchanged except for the one function that
FINDS the library (bindings/python/kaya/runtime.py `_find_library`):
`CDLL(None)` on iOS (the core is statically linked into the app
executable), `CDLL("libkaya.so")` on Android (the core is already in
jniLibs for the JNI tier; by soname, never `ctypes.util.find_library`,
which searches only /system), the existing KAYA_LIB/path logic
elsewhere. `CDLL`, never `PyDLL`: CDLL releases the GIL around every
foreign call, which is exactly right for calls into the core —
including the parked wait.

THE WALL, per invariant 3: `-Wl,-force_load` on `libkaya.a` in the iOS
link, and a check the build cannot avoid — `nm -gU` of the built app
executable must contain a known kaya export (`kaya_spec_hash`), or the
build fails naming the missing flag. Without it, only the symbols
Swift happens to call survive the link and `CDLL(None)` resolves
nothing, silently. Measured on macOS; PROVEN ON THE SIMULATOR before
anything is built on top (§D6 step 0).

### D4 — hosting the interpreter: a worker thread, signals off

iOS (Swift, off the main thread): `PyPreConfig_InitIsolatedConfig`
with `utf8_mode=1`, `configure_locale=1`, `setenv("LANG", ...)` before
pre-init; `PyConfig_InitIsolatedConfig` with `use_system_logger=1`,
`buffered_stdio=0`, `write_bytecode=0` (the bundle is signed and
read-only), `install_signal_handlers=0` (isolated config's default —
the testbeds re-enable it only for their test suites), `home` and the
three module search paths into the bundle; then import the guest
module. Uncaught-exception routing into the harness's own log stream,
BeeWare's crash-dialog lesson: an uncaught Python exception on iOS is
otherwise invisible to a lane.

Android (Kotlin + one JNI shim, off the main thread): extract
`assets/python` to `filesDir/python` behind a VERSION STAMP (the
testbed's delete-and-re-extract pays the full copy every launch —
invariant 8 says measure, and the stamp makes the cost once-per-
install); `Os.setenv("TMPDIR", cacheDir, false)` (unset below API 33);
`Os.setenv("KAYA_SELFTEST", ...)` from the Intent extras BEFORE
`Py_InitializeFromConfig`. Go's D2 empty-environment trap does NOT
recur here and the reason is stated so nobody re-fears it: Go fills
its environment from the process entry's envp, which a loaded library
never sees, while CPython reads libc's live `environ` at
initialization — setenv-before-init is visible in `os.environ`. The
shim itself is a handful of lines (`PyConfig_InitPythonConfig`, home,
`install_signal_handlers=0`, init, import), added as another
`#[no_mangle]` JNI export on the existing Rust cdylib rather than a
new CMake target.

### D5 — what ships in the bundle

The stdlib MINUS `test/`, `idlelib`, `tkinter`, `turtledemo` (172 of
233 MB on iOS, 37 of 60 MB on Android); a pre-built `__pycache__` for
stdlib and guest alike (iOS never writes bytecode at runtime, so
without it every launch pays full source compilation on a phone CPU);
the pure-Python kaya binding and the guest scenes in the app tree
(`<Resources>/app` on iOS, `assets/python/.../site-packages` on
Android). iOS extension modules go through the artifact's own
"Process Python libraries" phase — the `.fwork` conversion and
per-module codesign are its job, not ours.

### D6 — sequencing: prove the one unproven measurement first

0. **The force_load proof on the simulator.** The research measured
   `CDLL(None)`-reaches-static-archive on macOS; the same Mach-O/dyld
   claim on a real simulator run is step zero, before any plan step
   stands on it.
1. iOS depth slice: interpreter into the existing sim app,
   `portfolio-python` leg green on the sim lane, startup cost
   measured (invariant 8 — if source-compilation or extraction
   dominates leg time, the `__pycache__`/stamp answers land here).
2. Android: the JNI shim + gradle asset split, the same leg green on
   the emulator lane.
3. Fan-out: the portfolio's `IOS_UNWIRED_SCENES`/`ANDROID_UNWIRED_SCENES`
   declarations deleted WITH THEIR NEGATIVES WATCHED, the varied
   scene following, and whatever other Python-only scenes exist at
   that point riding the same rails.

### D7 — what "done" means

Portfolio legs on the iOS and Android lanes running the same shared
scene script as the three desktop lanes, byte-compared, in the
matrix — the app the milestone exists to finish, finished. Not a
demo: legs the lanes demand, that check-steps holds open once the
unwired declarations fall.

## §2 — carried, not part of this milestone

1. **Registry distribution** — wheels that bundle the core per
   platform, pip/maven/opam publication, the loader that finds a
   bundled library. Deferred by the maintainer's ruling at the top of
   this file; nothing here forecloses it.
2. **The CPython finalization hang** — `PyGILState_Ensure` during
   finalization compounding harness.rs's known exit hang was carried
   out of the Go milestone (docs/go-mobile-plan.md §2) and becomes
   live the day an embedded interpreter shuts down inside a host app.
3. **The exit-status shape on hosted platforms**: a parked `run()`
   returns 0 to a caller with no process to hand a status to — Go
   ruled this exact point (§D5's "exit code 0 — there is no process");
   Python inherits the ruling and the note is here so the inheritance
   is visible.
