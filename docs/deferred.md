# Deferred work ledger

The running inventory of punted items. Check things off here as they
land; add new deferrals with enough context that a future contributor
(human or agent) can pick them up cold. DESIGN.md's open-questions
section is the architectural counterpart; this is the working list.
Landed history lives in git; this file only carries what is still open.
(Pruned 2026-07-23: the grow/spacing/align, dressed-floor, window,
scroll/nav breadth, matrix-speed, and backend-roster sagas landed and
moved to git history; their traps live in docs/traps.md.)

## Next milestones (in rough priority order)

- **The versioned binding style guide** (DESIGN open question #1) — the
  current milestone. Construction-prop spellings were RATIFIED
  2026-07-20 after the ecosystem survey (chains: Rust/Go/Java; named
  args: Swift/Python/C#/OCaml; config lists: Haskell — see DESIGN's
  Binding conventions), and OCaml's ambient-transaction spelling was
  RATIFIED 2026-07-22 (direct style over an ambient tx ref, curried
  children ending in `()` — see Binding conventions and docs/traps.md's
  right-to-left entry). Still open here:
  - ratify per-language tiers;
  - ambient-transaction spellings for the remaining languages;
  - container SCOPING for layout props — typed row/column contexts
    making an orphan `grow` a compile error (the ambient languages'
    nullary container bodies cannot express a receiver without a
    redesign, which is why this waited for the style-guide phase);
  - Rust's chained `.grow()` construction form (rides an ephemeral
    borrow-checked proxy handle);
  - the eq/ne/fmt derived-signal vocabulary beyond Python;
  - blob-signal ergonomics parity (Go has typed Signal[[]byte]; others
    wrap handles manually);
  - decision gate for deleting the probe/reflection selector floor that
    the KayaGen generators superseded;
  - optional static analyzers (Roslyn for C# is the plausible one;
    go/analysis; ErrorProne — never load-bearing, the runtime guards
    are the floor);
  - whatever the guide ratifies for multi-window ergonomics.
- **Window vocabulary** remainder (the rest LANDED through the
  window/panels/confirm/nav/sections scenes): presentation styles
  beyond the primary set (utility panels, always-on-top).
- The stock stacks' nil-frames are re-proposers too, in theory. A
  constraint-less `.frame` around a stock stack's child still places
  by re-proposing the child's fitted size; today every stock-branch
  child is a control (idempotent under its own size) or a container
  whose squeeze no scene constructs, so nothing observable fails. A
  KayaStretchCell replacement was attempted in the dressed-floor
  slice and RETREATED: a custom Layout does not forward alignment
  guides (baseline rows classified "mixed") and its guide-forwarding
  overloads SIGTRAPed the gallery leg — a correct replacement must
  forward guides for real, and per doctrine the failure wants a
  CONSTRUCTED failing scene (stock column in stock column with a
  bordered-button row) before the next fix attempt.
- An `expect_honest` gate: measured-vs-drawn self-agreement per
  control. The dressed-floor hunts exposed two symptom shapes the
  geometry gates are structurally blind to — a control whose caption
  wraps or truncates still classifies and fills correctly (the
  "tic/k" wrap shipped through two 18/18 iOS runs). Both shapes share
  one observable: the control's DRAWN box diverges from its honest
  ideal (wrapped pill 42.67x56.33 vs ideal 51.67x34.33; a compat-mac
  liar diverges the other way). Design: record each control's
  answered ideal (sizeThatFits(.unspecified) — stable like a font
  metric, so the recording trap does not apply) alongside the
  existing drawn-geometry readers, and a verb compares them under
  ample space. Interpreters first (the historic miss layer), then the
  native backends' analogs. Caveat named by the mac experiments: in
  a compat-stamped process the SwiftUI-side layout box and the AppKit
  PAINT disagree while both SwiftUI numbers agree — catching that
  class needs the AppKit frame walked, which the bridge already
  makes moot for buttons; scope the first cut to SwiftUI-side
  self-agreement.
- The suite runners screenshot AFTER teardown. run-emulator's
  android-shot-*.png and run-sim's leg captures race app exit and
  mostly record the home screen (207KB of wallpaper, byte-identical
  across legs) — useless as visual evidence and confusing next to
  real stills. Move the capture to before the final step/exit, or
  drop it and keep the recording pipeline as the visual record.
- The C floor's grow/layout scenes, out on purpose: the floor
  documents the explicit wire; a separate exercise. (Map for the next
  layout prop, from grow's landing: native weights on WinUI — `Grid`
  star sizing — and Compose — `Modifier.weight`; constructed on GTK4
  — a custom `GtkLayoutManager` — and SwiftUI — a custom `Layout`.)
- STANDING CONSTRAINT — do not bump the flake SDK without preserving
  a compat-generation leg. The nix shell links every non-swift leg
  binary against its pinned SDK (audit 2026-07-21: python3/go/dotnet/
  ocaml/rust 14.4, zulu JDK 11.3), so those legs exercise SwiftUI 26's
  COMPATIBILITY design generation, while the swift mac guests compile
  against the system toolchain and exercise the modern generation —
  both covered on purpose. Vendor audit (2026-07-21, official
  binaries, LC_BUILD_VERSION sdk field): .NET host 10.0.10 = 15.5,
  .NET 11-preview.6 = 15.5, apphost stub = 15.5; zulu jre 21/25 =
  13.3, Temurin 21 = 14.2, Oracle JDK 25 = 14.5. No vendor ships a
  ≥26 stamp; nixpkgs' darwin `openjdk17` IS repackaged zulu (no
  source-built lever). The compat generation is where the Button
  measurement bug class lives and is a permanent first-class citizen;
  the native-kit button bridges are load-bearing indefinitely, not
  transitional.

## Protocol / core

- **A stable identifier prop (`test_id`, doubling as the accessibility
  identifier)** — Akhil's instinct, 2026-07-20: harness scripts should
  address widgets by the same authored key on every platform, not by
  `kind#index`. Positional targets exist only because they were free
  (the per-kind driving registries already existed); an authored key
  flowing over the wire dissolves the creation-order instability
  entirely — containers freely addressable, no unique-by-convention
  discipline, no check-steps container lint, and the layout scene's
  rows become assertable instead of observation-only. Frame it as the
  accessibility identifier (accessibilityIdentifier / testTag /
  resource-id are the platform mappings) so it is a real product
  surface with the harness as first consumer, not test plumbing on the
  production wire. Cost: a Prop in spec.rs (hash moves, everything
  regenerates), a name→widget map in the backends + 2 interpreters,
  and a steps migration. TRIGGER: the first scene that needs to assert
  on a container the uniqueness convention cannot name — the layout
  scene already qualifies whenever its rows deserve assertions.

- scrollTo + ref markers (per-instance handles): brings the first
  instance-addressed command (TemplateNodeId + key path target) and the
  silent vanished-target no-op (live-zone commands fail loudly; stamped
  copies legitimately vanish under rebuild). Wants a long-list scene —
  which pairs with row-window virtualization for For.
- Horizontal scroll axis: an axis enum prop — decide when a scene
  needs it (the scroll depth ledger's remaining item).
- Command completion observability (awaitable commands — the Compose
  scrollToItem precedent); command payloads (a set_text command awaits
  an autofill-shaped artifact). Admission policy: each verb needs a
  real artifact.
- Value::Record — waits for nested fields or field-level sum payloads.
- Nesting depth >2 validation; typed keys in collection schemas.
- Occurrence growth: subscription/filtering (every click emits today),
  suspension lifecycle (Android), CloseRequested.
- Vello scene-encoding subset (open question #3) — arrives with Canvas,
  post-v1, on the surface-handle transport (pixel surfaces as
  IOSurface/DXGI/dmabuf handles; the blob channel is the byte-copy arm,
  Canvas is the zero-copy arm).
- Blob follow-ups: dedup on repeated registration (needs an artifact);
  kaya_blob_from_file/mmap escalation (needs an artifact showing the
  register copy matters — decode dominates by an order of magnitude).

## Bindings / ergonomics

- Component functions as the reusable named unit (Solid's model, slot
  proxies = the function signature) — mostly ratification for the
  typed languages; Python validates at record time.
- Switch sugar (app-level one-of-N over a signal; sum-typed elements
  already cover collection rows) — wants the comparison vocabulary
  first.
- Template-declared collection escape to handlers (`group.items` via
  the element proxy) — flagged, undesigned; wait for a motivating
  scene.
- Portal (platform overlays; protocol + backend work).
- OCaml effect-handler ambience (true Python-style ambient
  transactions; runtime-only scoping errors — OCaml has no effect
  typing).
- Binding-maintained mirrors (todos-iterable style shadow state).
- Navigation sugar remainder from the nav breadth slice: (1)
  pop_to_root/pop(n) sugar + the binding stack mirrors it needs;
  (2) signal-bound entry titles have wire + scene + fan-out but no
  binding sugar.

## Testing / infrastructure

- Nothing checks that a scene is actually RUN by a suite: check-steps
  validates script well-formedness and scene REGISTRATION (harness.rs),
  but a scene can still exist, be registered, and be exercised nowhere.
  Packaging notes for whoever adds the next scene: iOS needs a bundle
  per example in run-sim.sh; Android has ONE apk whose guest
  (guests/rust/milestone2_android.rs) is a scene selector keyed on
  KAYA_SELFTEST, so a new scene needs a `mod` + match arm there;
  Windows needs a tools/guest/run_<scene>_<lang>.cmd plus
  build/scp/verify/kill entries in deploy-win.sh.
- Per-binding EMISSION checks (kaya_app_checks.py-style — assert the
  records a construction emits) in every language, not just Python.
  The motivating miss: the Swift binding's containerOf ACCEPTED
  construction-time `spacing:` but never applied it (one commit's
  worth of silently dropped writes) — and no gate could see it,
  because the interpreter's render and its fills observation share
  the node state a wire-dropped write never reaches; recordings were
  the only gate for that class.
- The WinUI bindings have no regeneration gate:
  crates/kaya/src/winui/bindings.rs comes from tools/winui-bindgen, but
  unlike gen-header/gen-bindings/gen-guests there is no `--check`
  proving the checked-in file matches the generator — a hand edit (or a
  filter change without regeneration) goes unnoticed until the next
  regeneration clobbers it. deploy-win compiling the file is the only
  gate today, and it proves compilability, not provenance.
- Mount-transaction focus negative test: the Focus command now
  defers until the element is loaded/mapped on WinUI/GTK (the
  materialization class, traps.md), but no scene issues focus IN the
  mount tx — the entry scene focuses from the add fold, long after
  load. The class fix is structural; the missing gate is a scene (or
  an entry-scene opening step) that focuses at mount and asserts
  expect_focused, proving the deferral on all platforms.
- resize_window harness verb (Akhil asked 2026-07-22): backends
  reflow natively on user resize but the matrix never drives one —
  add a verb that resizes the REAL window then re-asserts
  root_fills/shares/fills, making reflow-under-resize a matrix fact.
  Also the place to watch WinUI's known interactive-resize flicker
  (platform-level; we already avoid the transparent-background worst
  case — keep WinAppSDK current).
- The macOS `back` verb drives the path binding (GTK/WinUI/Compose
  drive real chrome; mac needs a stable handle on NavigationStack's
  private toolbar button).
- Ergonomic: a `kaya::park(&ctx)` keep-alive primitive for static
  (handler-less) scenes, so they don't reach for `Messages::<()>` just
  to block until Shutdown (see traps.md).
- Android recording anchors flake under load: one todos-rust leg
  failed extraction with "anchor implausible (leg spans
  -10106..-6353ms)" — screenrecord buffered its start ~10s, the
  kill-minus-duration arithmetic drifted by that much, and the
  plausibility guard rightly refused to fabricate stills (the scene
  itself passed; a rerun was clean). One transient in dozens of runs,
  but the class is structural: if it recurs, Android earns a
  content-anchored scheme the way iOS earned its appearance-flip
  fiducial — the arithmetic anchor is the last one left.
- bench-encode blob leg: register+reference throughput with an MB/s
  floor, so payload-path structural regressions trip at gate time.
  (Adding it means a second phase in each language's encode_bench
  program + floors in tools/bench-encode.sh — keep it separate from
  the existing rec/s floors, which would otherwise deflate.)
- Matrix speed, remaining (diminishing returns): a real swiftmodule
  for the Swift bindings; a Windows VM with more cores.
- Windows entry follow-ups: IME contract notes for mobile; the WinUI
  text-flyout-open path is untested.
- Select follow-ons, each waiting on a REAL need: a template
  (For-body) select only gets the stateless index checks — the
  option-count upper bound is live-widget-only (the count map keys
  on live ids); option disabling; multi-select (a different control
  on every platform — checkable menu items, list boxes — probably a
  separate kind); signal-bound OPTION LABELS work today (label text
  binding fans out to the rows), but signal-bound option LISTS
  (dynamic add) are append-only via add_child with no remove.
- Canvas widget (Akhil, 2026-07-22; post-style-guide, before webview):
  a drawing surface. The viable shape is a DISPLAY LIST — the guest
  transmits drawing commands (paths, fills, strokes, transforms, text
  runs) as data; core retains it as a prop; backends replay it into
  the native surface (SwiftUI Canvas, Compose DrawScope, GTK4
  DrawingArea/cairo; WinUI needs Win2D CanvasControl — a new NuGet
  dependency and packaging payload). Callback-per-frame immediate
  mode is REJECTED (8-language FFI churn, divergent frame timing).
  The slippery slope is the op vocabulary (gradients, blend modes,
  images, text shaping) — start with a deliberately minimal op set.
  Pointer-event occurrences on the canvas are a further deferral
  inside this one.
- Webview widget (Akhil, 2026-07-22; deferred furthest — the
  framework inside it is the entire web platform): minimal uniform
  surface is load-URL/load-HTML plus a navigation-requested veto
  (fits the existing veto grammar). The hard parts are the four
  embedders (WKWebView, WebView2, Android WebView, WebKitGTK) whose
  JS-bridge/cookie/permission models diverge, and distribution
  (WebView2 Evergreen runtime, webkit2gtk distro variance) — both
  land on the packaging milestone. A user-facing native-view escape
  hatch is NOT the default answer (breaks the cross-platform promise
  per-widget, forces per-platform guest code).
- Packaging: at-release items — Hackage/opam publication, Go vanity
  import path (akhil.cc/kaya + go-import meta; dev.kaya is
  unpublishable), Maven publication under cc.akhil, npm kaya-gui after
  account recovery; a LICENSE decision before any real release;
  trusted publishing (OIDC) on nuget/PyPI/npm when releases start.
  Android Python/Go guests need binding bootstrap (briefcase/gomobile).
  Swift SPM packaging needs a modulemap target.
  APP-DISTRIBUTION PAYLOADS (Akhil, 2026-07-22): a user who imports
  kaya and ships an app must get every runtime artifact the platform
  needs, per platform, without reading our runbooks. The inventory
  the suites already prove out: WINDOWS — resources.pri beside the
  PROCESS exe (the pri-adjacency rule in traps.md; for dll-hosted
  languages the packaging story must place it beside the interpreter
  or ship an apphost), the WindowsAppRuntime bootstrap dll, and
  kaya.dll on PATH; MAC — libkaya.dylib plus the SwiftUI interpreter
  dylib (KAYA_SWIFTUI_LIB or dyld-adjacent); iOS — both inside the
  bundle (the run-sim make_bundle recipe is the spec); ANDROID —
  libkaya.so in jniLibs + the Kotlin interpreter classes; LINUX —
  libkaya.so with the GTK backend compiled in. Each language's
  package should carry or fetch these so `pip install kaya-gui` /
  `go get` / `cargo add` yields a runnable, distributable app —
  wheels with platform tags, cargo build-script asset embedding,
  gradle AAR, etc. This is the packaging milestone's acceptance
  test: a fresh machine, one package-manager install, one binary
  handed to a friend.
- Alert relaxations, each waiting on a REAL need, none speculative:
  programmatic dismissal (a guest-side cancel verb — rare; adds a
  second retire path to a grammar whose whole point is ONE),
  per-window alert concurrency (the process-wide one-live-alert
  floor is ContentDialog's per-root rule spelled strictly; relaxing
  means per-window slots and a WinUI carve-out), and a third-plus
  action (the platform floor is ContentDialog's two-actions-plus-
  close; more means a custom row on WinUI — no longer the dressed
  floor).
- Swift guests on Linux and Windows. Upstream swift.org toolchains
  exist for both, but neither pinned world (docker image, VM) carries
  one, and the swift SURFACE is already fully proven — typecheck on
  two Apple targets plus 11 live mac legs and the iOS suite. The
  value would be backend×language matrix breadth, not new surface
  proof; take it only if a real swift-on-linux/windows user appears.
- Node.js guest (the roster's first async surface): Node first;
  function-floor tier via N-API (V8 pointer compression forbids
  external ArrayBuffers over native memory — no direct ring);
  main thread blocks in kaya_run, app logic in a worker; layer 3 wants
  for-await occurrence iteration.
- Arena offset+length form (row batches, audio) — returns when the row
  window and audio land; the blob table is its v1 realization.
- Attach/embedding tooling rework (parked at milestone 0).
