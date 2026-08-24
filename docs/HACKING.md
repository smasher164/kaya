# Hacking on kaya — workflows and recipes

Companion to CLAUDE.md/AGENTS.md (operating rules) and DESIGN.md (the
architecture). This file is the how-to layer: the recipes that repeat.

## Repo map (the load-bearing paths)

- `crates/kaya/src/` — the core: `spec.rs` (the protocol as data, the
  root document), `protocol.rs` (in-memory enums), `wire.rs` (byte
  codecs), `scene.rs` (the reducer + validation), `capi.rs` (C ABI +
  KAYA_ constants with const-asserts), `app.rs` (the Rust guest API),
  `harness.rs` (the scene-script interpreter + Stage trait), one file
  per backend (`gtk.rs`, `winui/`, the SwiftUI/Compose interpreters,
  `android.rs`), `swiftui_host.rs` (the vtable the SwiftUI dylib gets),
  `ring.rs` (the occurrence ring).
- `swift/KayaSwiftUI.swift` and
  `android/kaya/src/main/kotlin/dev/kaya/KayaCompose.kt` — the two
  interpreter backends (own their node trees across the C ABI).
- `tools/kaya-bindgen/` — emits the 8 generated wire files
  (bindings/<lang>/...wire...) from spec.rs.
- `bindings/<lang>/` — per-language: generated wire file + hand-written
  runtime + layer-3 surface.
- `cmd/kaya-gen`, `tools/java-processor`, `tools/kaya-csgen`,
  `tools/kaya-swift-gen` — the KayaGen generators (record/sum surfaces
  from guest type declarations), driven by `tools/gen-guests.sh`.
- `guests/<lang>/` — the example scenes, one project per language.
- `tools/scenes/*.steps` — the shared scene scripts. TWO transports, no
  registry: `KAYA_SELFTEST_SCRIPT` carries the script's TEXT (the
  interpreters need this — an iOS bundle or an Android intent shares no
  filesystem with the runner), and otherwise the Rust backends read
  `$KAYA_SCENES_DIR/<scene>.steps` FROM DISK at run time. Editing a
  .steps file needs no rebuild; only the default directory is baked in.
  deploy-win ships tools/scenes to the VM and points KAYA_SCENES_DIR at
  it; the linux container points it at the mount.
- `tools/checks/` + `tools/check-*.sh` — the gate layer.

## The regeneration workflow (any spec.rs change)

1. Edit `crates/kaya/src/spec.rs` (records, enums, PROPS). The spec
   hash moves automatically.
2. `cargo test -p kaya --features harness --locked` — the pin tables
   (`tx_kinds_match_wire`,
   `apply_and_occurrence_kinds_match_wire`, `enums_match_wire`,
   `c_abi_constants_cover_the_spec`, round-trips) fail until
   protocol.rs / wire.rs / capi.rs carry matching arms and constants.
   The compiler's non-exhaustive-match errors are the checklist —
   follow them.
3. `tools/gen-header.sh` (kaya.h via cbindgen), `tools/gen-bindings.sh`
   (the 8 wire files). `cargo build --lib` so the dylib carries the new
   hash — every runtime asserts hash agreement at load, so stale
   artifacts fail loudly rather than decoding garbage.
4. If guest-visible record/sum surfaces changed: `tools/gen-guests.sh`.
   Commit generators together with their outputs (the `--check` form
   diffs against git HEAD).

## Adding a widget (the conformance-gallery recipe)

The slider and image commits are the worked examples. The ~30 touchpoints:

1. spec.rs: kind row (+ prop rows with PropKind; + occurrence row ONLY
   if interactive — display-only widgets like Label/Image have none).
2. protocol.rs/wire.rs/capi.rs: enums, constants, codec arms,
   const-asserts (compiler-driven).
3. scene.rs: `check_prop` (prop→kind), `prop_value_type` (prop→value
   type); tag creation arm if interactive.
4. Each Rust backend: NativeWidget variant, view() upcast, registry
   Vec, create arm, SetProp arms, Stage observation if the harness
   needs one.
5. Both interpreters: constants, scene-collect arm, apply/SetProp arm,
   render, step-verb arm (check-verbs enforces the constants).
6. harness.rs: TargetKind + parse arm + Stage method (make observation
   methods NO-DEFAULT so backends fail to compile rather than silently
   skip) + MockStage + grammar tests.
7. Layer-3 constructors in all 8 bindings, in BOTH construction zones —
   the LIVE one an app builds in its build closure and the TEMPLATE one
   inside a collection's prototype row (check-sugar-surface enforces
   both once the kind lands in the generated wire.py; the template half
   is the python census tools/tpl-surfaces.py).
8. Gallery scene: extend tools/scenes/gallery.steps + every language's
   gallery guest. Scene strings byte-identical everywhere.
9. The full validation ladder.

Interactive widgets additionally follow the occurrence machinery: spec
`payload:` field, tag bytes at create, per-backend emit through the
control's own event path. The echo doctrine (ratified 2026-07-22,
DESIGN's Binding conventions): only the user's act emits — a property
write is configuration and NEVER echoes (GTK and WinUI arm an
apply_quiet guard around every interactive SetProp, because their
native change events cannot tell user from programmatic); commands
(clear) act like the user and DO emit. The gallery scene's quarter
button + signal-bound slider is the standing negative test.

## The blob channel (bulk payloads)

Payload bytes live once in core memory (`kaya_blob_register` — one
copy; refcounted `Arc`); every record stream carries 8-byte handles
only. Handles are consumed by ONE submit — re-register per transaction
that references the bytes (bindings do this automatically at encode
time for record fields). Pump-side handles are batch-local; interpreters
prefetch blob bytes on the pump thread before UI dispatch. The guest's
own buffer is never part of the refcount and may be freed the moment
register returns. Blobs are content, never identity — they cannot be
collection keys. See DESIGN.md's transport section for the doctrine.

## Suites and platforms

- The whole matrix: `tools/validate-all.sh` — all five platform lanes run
  CONCURRENTLY by default. When Android finishes, one `nice -n 10` gate
  sweep starts and overlaps any longer lanes still running; the per-lane
  ceilings below are the live budgets. `--serial` is for single-lane
  benchmarking, contention-free debugging, or recording mode. Per-lane
  logs print for any FAIL.
- macOS: `tools/validate-mac.sh` (KAYA_JOBS=n for pool width, =1 for
  serial; KAYA_RECORD=1 for recording mode). Legs open real windows.
- Linux: `tools/validate-linux.sh` (docker; X11 + Wayland rings;
  container builds use a separate target dir — never share mac build
  artifacts with the container). After touching `gtk.rs`, reach first
  for `tools/check-gtk.sh` — a `cargo check` in the cached image, the
  compile rung `check-targets.sh` cannot provide for GTK. Every bug in
  the first flex-layout-manager cut needed the container to surface;
  this is the cheap version of that trip.
- iOS: `tools/ios/run-sim.sh` (env reaches the app via SIMCTL_CHILD_*).
  On every dedicated pool phone, preparation enumerates exact
  `dev.kaya.` bundle ids, uninstalls that finite list through `simctl`,
  then warms and probes LocalStorage before any leg. Do not keep an
  unrelated `dev.kaya.*` app on those UDIDs.
- Android: `tools/android/run-emulator.sh` (env via intent extras;
  scripts fold newlines to `;` for transport — comments are stripped
  first; verdicts read from logcat; on FAIL the runner dumps
  AndroidRuntime:E — crashes are otherwise hidden by the tag filter).
- Windows: `tools/deploy-win.sh <user@host> [--provision]
  [rust|python|go|csharp|java|all|<scene>_<lang>]` — the
  UTM VM (default akhil@192.168.64.2; auto-starts it; the VM drops ICMP
  so probe via ssh, which `tools/probe-env.sh` does for every platform).
- The accessibility scene is the one leg with an environment
  requirement of its own: GTK publishes an accessibility tree only
  under `GTK_A11Y=atspi` with a session bus and the AT-SPI launcher
  running, so the Linux legs go through `tools/linux/a11y-leg.sh`,
  which builds that session per leg and tears it down with it. It is
  per-leg because exported lane-wide it timed out eleven legs that
  never asked for accessibility. `tools/linux/atspi_probe.py` walks the
  bus by hand when a role or name needs measuring rather than guessing.
- The matrix enforces PER-LANE DURATION CEILINGS, not just the doctrine
  in CLAUDE.md's invariant 8: tools/validate-all.sh fails a lane that
  exceeds its budget with "DURATION ANOMALY" even when every leg passed
  (today gates 490s, mac 560s, linux 470s, windows 520s, ios 540s,
  android 310s — the live numbers are validate-all.sh's per-lane
  `case`, and each one carries the measurement that set it). A lane
  that slows by this much changed in KIND — look for work added to every
  leg before assuming load. Raise a ceiling in validate-all.sh only with
  a reason.
- `DEPTH_SCENES` is the tier for a scene wired RUST-ONLY during a depth
  slice: it builds and runs the rust example without demanding the other
  languages' guests, which SCENES membership does. check-steps enforces
  the difference (a scene in SCENES whose per-language guests do not
  exist fails loudly). It is NOT empty today — validate-mac.sh carries
  the current membership, and a scene graduates out of it into SCENES in
  the commit that gives every language a guest.
- Traces, all env-gated and permanent: `KAYA_AX_TRACE` dumps the REAL
  accessibility tree (gtk.rs, winui/mod.rs and KayaSwiftUI.swift all
  honour it — this is the tool for the class that cost most of a day),
  `KAYA_WINUI_TRACE` prints every WinUI op before applying it,
  `KAYA_MENU_TRACE` proved the iPadOS menu-build laziness, and
  `KAYA_WINUI_NAV_PROBE` / `KAYA_WINUI_MENU_PROBE` isolate those two
  subsystems.
- Pool widths: `KAYA_JOBS` (mac/linux legs), `KAYA_ANDROID_EMUS`
  (emulators, default 4), `KAYA_IOS_SIMS` (simulators, default 3),
  `KAYA_WIN_JOBS` (windows legs, default 4). `tools/probe-env.sh
  --warm` boots the simulator, emulator and VM instead of only
  reporting them.
- Scene selection everywhere: KAYA_SELFTEST=<scene> names the SCRIPT,
  never the app — two scenes can share one guest, and `split` and
  `listdetail` do. KAYA_SCENES_DIR overrides where the .steps files are
  read from (set by the windows and linux runners, which run the guest
  away from the source tree). There is no
  backend selection — the roster is one backend per platform
  (KAYA_BACKEND is gone); what remains is locating the SwiftUI
  interpreter dylib (KAYA_SWIFTUI_LIB — see validate-mac.sh for the
  exact pattern).

## Layout forensics (when a share assertion fails)

A failing `expect_shares` prints the shares it computed, which cannot
tell you whether the LAYOUT is wrong or the MEASUREMENT is (both have
happened; the second more often — see the layout-rect trap and the
axis-hardwired misreads in docs/traps.md). Get ground truth before
touching layout code:

- **Any platform with stills**: measure the recording still against the
  arithmetic — a pixel run at exactly `share × extent + gap` proves the
  tracks; the drawn control hugging inside its track is normal.
- **Android, live bounds**: uiautomator before the selftest exits —
  ```
  S=emulator-5554   # adb -s: the pool runs KAYA_ANDROID_EMUS (default 4) emulators
  # KAYA_SELFTEST_SCRIPT is REQUIRED, not optional: with KAYA_SELFTEST
  # set and no script the interpreter logs FAILED and calls
  # finishAndRemoveTask, so the app is gone before the dump. (This is
  # run-emulator's scene_script: comments stripped, newlines folded to
  # `;`, since intent extras cannot carry a newline.)
  SCRIPT=$(grep -v '^#' tools/scenes/grow.steps | tr '\n' ';')
  adb -s $S shell am force-stop dev.kaya.milestone2
  adb -s $S shell "am start -n dev.kaya.milestone2/.MainActivity \
      --es KAYA_SELFTEST grow --es KAYA_SELFTEST_SCRIPT \"'$SCRIPT'\" \
      && sleep 0.3 && uiautomator dump /sdcard/kaya-dump.xml"
  adb -s $S pull /sdcard/kaya-dump.xml
  ```
  The one-shell `&&` chain matters: the selftest exits the app within
  a couple of seconds of launch — tighter still since bounded-retry
  expects replaced the settle floors — and a host-side round trip
  plus a ~1.5s dump loses the race. Node bounds
  in the XML are the allocated tracks. `text=` precedes `class=` in
  the dump's attribute order.
- **iOS/macOS**: the pixel measurement above, or expect_shares against
  a throwaway env script — every backend reads KAYA_SELFTEST_SCRIPT
  when it is set, so no rebuild is involved on any of them).

## The fast inner loop (KAYA_FAST=1)

    KAYA_FAST=1 tools/gates.sh             # the gate sweep alone, cached
    tools/gates.sh                         # the gate sweep alone, always
    KAYA_FAST=1 tools/validate-mac.sh      # gates + every leg, cached gates
    tools/validate-mac.sh                  # everything, always — the ladder's rung 3

`tools/gates.sh` is the sweep: it builds what the gates read and then
runs every one of them, refusing a verdict unless the number that ran
equals the number it declared. validate-mac calls it and holds no gate
list of its own.

Most of those gates are keyed on a declared input set — which ones is
the `keyed` field in tools/gates.sh's list, and the sets themselves are
tools/build-id.sh's GATES table. (No count here on purpose: this
paragraph said "sixteen" for long enough to be wrong by three, which is
the same drift tools/check-gates.sh now refuses between the sweep and
CLAUDE.md.) Under KAYA_FAST=1 a gate whose inputs are unchanged since it
last PASSED prints `CACHED (<key>)` and is skipped. Measured on a warm
tree, 2026-08-20 at 41 gates: 148s cold, 23s warm with 28 gates keyed —
the artifact gates joined the keyed set the same day, on sources plus
the artifact's EMBEDDED build-id (build-id.sh's ARTIFACT_GATES), and
gen-guests' restore now hands byte-identical files their old mtimes
back so a sweep no longer relinks libkaya for nothing.

A FULL sweep RECORDS its passes too (never consults — the matrix's
answer still comes from the gates alone), so the first KAYA_FAST run
after any full sweep is already warm. Before 2026-08-20 only fast runs
recorded, and a day of full sweeps warmed nothing.

What the keys actually buy is not the all-cached case — it is that
different work re-runs different gates. Measured 2026-07-28, when 16
gates were keyed; read the ratios, not the denominator:

| edit | gates that re-run |
|---|---|
| a Kotlin file | 6 of 16 (not the cross-compile, not either typechecker) |
| a Rust backend file | 8 of 16 (not the gradle gates, not swift-typecheck) |
| a Python binding file | 5 of 16 |

`swift-typecheck` surviving a `gtk.rs` edit is the point: it is keyed on
`crates/kaya/include/` — the INTERFACE — not on `crates/`. That is sound
only because the header is a checked-in artifact whose freshness is
itself gated by `gen-header`, which IS keyed on all of crates/. Key a
downstream gate on an interface, and something must be guarding that
interface; here it is.

THE ARTIFACT-READING GATES ARE KEYED ON THE ARTIFACT TOO: check-abort,
check-wheel, check-empty-child, check-pane-ladder and check-table-tier
mix the built file's embedded build id into their source key, so an
unchanged source tree beside a different target/ cannot reuse the old
answer. check-build-id alone must never be keyed: caching the staleness
gate is the defect it exists to find. Other gates are unkeyed for their
own reasons — check-case's inputs are every tracked path, check-keyed is
the cache's own gate — and each states that reason beside itself in
tools/gates.sh's list, where check-keyed also insists it be non-empty.

Adding a gate to the cache means adding its input set to GATES. Name
DIRECTORIES, not files. The asymmetry is the whole safety argument:
naming too much costs a re-run nobody notices, naming too little hands
back a PASS about code that changed.

## "Is this artifact built from my tree?" (tools/build-id.sh)

libkaya carries a marker naming the sources it was compiled from — a
hash over crates/, Cargo.toml and Cargo.lock, baked in by build.rs and
readable straight out of the file.

    tools/build-id.sh core                      # what this tree hashes to
    tools/build-id.sh --verify target/debug/libkaya.dylib

A STALE verdict names both ids and means the build that should have
refreshed that file did not run, or failed with its exit status masked.
Every lane verifies what it runs or ships (android verifies the COPY in
jniLibs, so the copy is covered too; deploy-win verifies before the scp,
because a stale dll that reaches the VM is stale on a machine where
nothing local can see it). Reach for it by hand the moment a result
disagrees with the code in front of you — that is cheaper than the
alternative, which historically was half a day.

THREE COMPONENTS carry a marker, each keyed on its own sources plus the
interface it compiles against:

    tools/build-id.sh core                       # libkaya
    tools/build-id.sh swiftui                    # swift/ + kaya.h
    tools/build-id.sh compose                    # android/kaya/src + bindings/java
    tools/build-id.sh --verify --component swiftui target/swiftui/libkaya_swiftui.dylib
    tools/build-id.sh --verify --component compose  …/milestone2-debug.apk

`--component` defaults to `core`. The prefix is the same for all three
on purpose: a file carrying the WRONG component's marker then reads as
the mismatch it is, rather than as "no build id". An apk is a zip, so
the verifier reads its dex members — the string is not visible in the
raw file, and which classes*.dex it lands in is not stable.

The one thing it does NOT tell you: it fingerprints INPUTS, so a
matching id does not promise two byte-identical binaries.

## Multi-agent work

The breadth phases (same change across 8 bindings, or across the 4
backends' 5 platform lanes) parallelize well: give each agent a disjoint file tree, the green
reference implementation to study, exact verification commands with
expected verbatim output, and the constraint list of files it must not
touch. The gate layer catches what an agent misses — that is what it is
for. After parallel work lands, one consolidation pass re-runs all
gates against the final tree (each agent verified against a moving one).
