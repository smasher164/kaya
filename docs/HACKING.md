# Hacking on kaya — workflows and recipes

Companion to CLAUDE.md/AGENTS.md (operating rules) and DESIGN.md (the
architecture). This file is the how-to layer: the recipes that repeat.

## Repo map (the load-bearing paths)

- `crates/kaya/src/` — the core: `spec.rs` (the protocol as data, the
  root document), `protocol.rs` (in-memory enums), `wire.rs` (byte
  codecs), `scene.rs` (the reducer + validation), `capi.rs` (C ABI +
  KAYA_ constants with const-asserts), `app.rs` (the Rust guest API),
  `harness.rs` (the scene-script interpreter + Stage trait), one file
  per backend (`appkit.rs`, `gtk.rs`, `uikit.rs`, `winui/`,
  `android.rs`), `swiftui_host.rs` (the vtable the SwiftUI dylib gets),
  `ring.rs` (the occurrence ring).
- `swift/KayaSwiftUI.swift`, `android/kaya/.../KayaCompose.kt` — the two
  interpreter backends (own their node trees across the C ABI).
- `tools/kaya-bindgen/` — emits the 8 generated wire files
  (bindings/<lang>/...wire...) from spec.rs.
- `bindings/<lang>/` — per-language: generated wire file + hand-written
  runtime + layer-3 surface.
- `cmd/kaya-gen`, `tools/java-processor`, `tools/kaya-csgen`,
  `tools/kaya-swift-gen` — the KayaGen generators (record/sum surfaces
  from guest type declarations), driven by `tools/gen-guests.sh`.
- `guests/<lang>/` — the example scenes, one project per language.
- `tools/scenes/*.steps` — the shared scene scripts (embedded into Rust
  backends via include_str!; env/intent-delivered to the interpreters).
- `tools/checks/` + `tools/check-*.sh` — the gate layer.

## The regeneration workflow (any spec.rs change)

1. Edit `crates/kaya/src/spec.rs` (records, enums, PROPS). The spec
   hash moves automatically.
2. `cargo test -p kaya` — the pin tables (`tx_kinds_match_wire`,
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
7. Layer-3 constructors in all 8 bindings (check-sugar-surface
   enforces once the kind lands in the generated wire.py).
8. Gallery scene: extend tools/scenes/gallery.steps + every language's
   gallery guest. Scene strings byte-identical everywhere.
9. The full validation ladder.

Interactive widgets additionally follow the occurrence machinery: spec
`payload:` field, tag bytes at create, per-backend emit through the
control's own event path (programmatic mutation must re-fire the change
path on toolkits where it is silent: AppKit, UIKit; it is automatic on
GTK, WinUI, Android).

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

- macOS: `tools/validate-mac.sh` (KAYA_JOBS=n for pool width, =1 for
  serial; KAYA_RECORD=1 for recording mode). Legs open real windows.
- Linux: `tools/validate-linux.sh` (docker; X11 + Wayland rings;
  container builds use a separate target dir — never share mac build
  artifacts with the container).
- iOS: `tools/ios/run-sim.sh` (env reaches the app via SIMCTL_CHILD_*).
- Android: `tools/android/run-emulator.sh` (env via intent extras;
  scripts fold newlines to `;` for transport — comments are stripped
  first; verdicts read from logcat; on FAIL the runner dumps
  AndroidRuntime:E — crashes are otherwise hidden by the tag filter).
- Windows: `tools/deploy-win.sh <user@host> [rust|python|go|all]` — the
  UTM VM (default akhil@192.168.64.2; auto-starts it; the VM drops ICMP
  so probe via ssh, which `tools/probe-env.sh` does for every platform).
- Scene selection everywhere: KAYA_SELFTEST=<scene>; backend selection:
  KAYA_BACKEND=swiftui/compose with the respective dylib env vars — see
  validate-mac.sh for the exact patterns.

## Multi-agent work

The breadth phases (same change across 8 bindings or 7 backends)
parallelize well: give each agent a disjoint file tree, the green
reference implementation to study, exact verification commands with
expected verbatim output, and the constraint list of files it must not
touch. The gate layer catches what an agent misses — that is what it is
for. After parallel work lands, one consolidation pass re-runs all
gates against the final tree (each agent verified against a moving one).
