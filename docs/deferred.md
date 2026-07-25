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

THE NAMED FORCING ARTIFACT IS A **TEXT EDITOR** (Akhil, 2026-07-24).
This is a roadmap-selection decision, not a build order — the editor is
written once enough features exist. Its purpose is to resolve the
admission policy: this ledger is full of items that "wait for an
artifact", and until one is named those triggers cannot fire, so the
items sit unordered. Anything the editor needs is now trigger-SATISFIED
and can be scheduled on its merits; anything it does not need stays
gated. What it forces: file dialogs, clipboard, the edit roles
(cut/copy/paste, currently deferred past `settings`), undo/redo,
dirty-state window titles (the close veto already exists), and find.
Chosen over chat / todo / media on COMPOUNDING — those four features
are wanted by every other candidate app too, whereas media's are wanted
by exactly one, and todo is largely proven already by the `todos`,
`reorder`, and `feed` scenes. Two further reasons: the editor is the
field's standard litmus test for the text/IME stack, which kaya passes
by construction and has never demonstrated; and it forces undo/redo,
which core can offer far more cheaply than any framework that does not
own the state (see the undo note in this file).

- **DEFECT — the iPad menu lowering is wrong as of iPadOS 26**
  (found 2026-07-24). iPadOS 26 gives iPad apps a REAL system menu bar
  (swipe down from the top edge, or hover a trackpad; third-party apps
  populate it) plus real windowing with traffic lights. kaya routes the
  entire catalog into a trailing More overflow on every iOS host:
  `KayaPhoneMenuToolbar` in swift/KayaSwiftUI.swift, gated
  `#if os(iOS)`, promoted primaries in `.primaryAction` plus the More
  `Menu`. So a full command catalog hides behind a phone affordance
  while the platform's own menu bar sits empty. The `menus/first-cut`
  stash has the identical structure — this is not a regression from one
  implementation, it is a shared assumption. Fix rides the form-factor
  milestone below; the iPad arm wants `UIMenuBuilder`.
  THE TRAP WORTH KEEPING: the ledger already carried an iPad item, but
  its trigger was "an artifact running on iPad with a keyboard", framed
  around `UIKeyCommand` HUD exposure — the pre-26 framing, when a
  keyboard was the only route to commands on iPad. That trigger can
  never fire for the thing that now matters (a plain iPad, no keyboard,
  with a menu bar). A trigger written against a platform's CURRENT
  shape expires when the platform moves; triggers naming a platform
  capability need a re-read date, not just an artifact.

- **The iPad menu bar's gate is OWED, and the accessibility milestone
  pays it** (2026-07-25). The lowering LANDED and is confirmed working
  — visually, on an iPad Pro simulator: swipe down and the kaya catalog
  is there in the system menu bar. What is missing is an automated
  observation, and the reason is structural, measured, not assumed:
  the iPadOS menu bar is built LAZILY. `buildMenu(with:)` runs exactly
  ONCE, at launch, with an empty catalog, and never again no matter how
  many times `UIMenuSystem.main.setNeedsRebuild()` is called (traced:
  10 rebuild requests, 1 build). UIKit defers the build until the bar
  is about to be PRESENTED, the bar stays hidden until a swipe or
  hover, and UIKit exposes NO way to present a menu programmatically
  — so a headless scene structurally cannot witness the build.
  CONSEQUENCE, recorded in the code too: on iOS-regular alone, the
  presentation half of `expect_menu_presentation` is ARM-DERIVED — it
  reports the lowering the window selected, not a reading of rendered
  chrome. Every other backend still reads its real chrome. So the verb
  can catch a regression in the ARM CHOICE (which is what the original
  defect was) but NOT one in the build.
  THE FIX, already scheduled: a menu bar is an accessibility element,
  so the AX-tree verb in the accessibility milestone restores an
  independent read. Wire it there rather than inventing bespoke
  machinery. `KAYA_MENU_TRACE=1` is left in the interpreter, env-gated
  — it is what proved the laziness and will be wanted again.

- **Form factor as the adaptivity axis** (DESIGN's "Form factor and
  adaptivity", 2026-07-24). kaya keys adaptivity on PLATFORM —
  compile-time `#if os(iOS)`, and the compact-overflow rule written as
  desktop-vs-phone. The correct axis is the window's size class,
  resolved at runtime, per window. Every backend already has the
  concept and kaya uses none: SwiftUI's horizontal size class,
  Compose's `WindowSizeClass`, libadwaita's `AdwBreakpoint`, WinUI's
  adaptive triggers. Scope: a size-class notion in the core/window
  model, the four backend readings, re-keying the menus compact rule
  off `#if os(iOS)`, and the iPad `UIMenuBuilder` arm. The gate is
  already specified and already in this ledger — `resize_window` drives
  the size-class transition and re-asserts on the far side, which makes
  adaptivity a matrix fact instead of a claim. THE TWO ITEMS MERGE;
  do not schedule `resize_window` separately.

- **Window vocabulary** remainder (the rest LANDED through the
  window/panels/confirm/nav/sections scenes): presentation styles
  beyond the primary set (utility panels, always-on-top).
- **App-developer capability decisions** (raised 2026-07-23; each
  wants a design pass or an explicit v2 verdict, none is speculative
  protocol work):
  - **Styling tier 1 — the successor decision is MADE** (2026-07-24,
    DESIGN's "Brand identity and the styling ceiling"). The v1 stance
    stays zero *arbitrary* styling; what is admitted is two tiers.
    (a) SEMANTIC ROLES — destructive/prominent/plain on buttons,
    title/heading/body/caption on labels — the `role` grammar the
    menus milestone already built, reused verbatim. (b) A BRAND TIER
    of app-level slots (accent, typeface family, icon set), each of
    which every platform already exposes and expects apps to fill.
    Slots may take per-platform VALUES; the vocabulary stays uniform.
    What remains open under this heading, each a design pass:
    - The exact slot list and the four lowerings per slot. Carry the
      WinUI trap into the lowering: `SystemAccentColor` is NOT
      overridable (microsoft-ui-xaml#6394) — override the derived
      `AccentFillColorDefaultBrush` family in `ThemeDictionaries`.
      A lowering that sets `SystemAccentColor` compiles, runs, and is
      silently ignored, so this wants a gate, not a comment.
    - **Semantic icon names.** `icon` is a Blob today (sprop 2 /
      mprop 5), which is the wrong primitive for STANDARD icons: the
      platforms draw the same concept differently, and their symbol
      sets metric-match adjacent text while a blob cannot. Wants a
      small closed name set mapped per backend (SF Symbols / Material
      Symbols / Adwaita names / Fluent). The Blob stays for
      app-specific art. NOT a tinting problem — a single-color raster
      tints fine on all four.
    - **Vector/DPI story for the Blob** (separate from the above): all
      four decoders are raster-only today — `NSImage(data:)`,
      `BitmapFactory.decodeByteArray`, `gdk::Texture::from_bytes`
      (PNG/JPEG per its own comment), `BitmapImage::SetSource`. Android
      cannot be fixed by API choice: `VectorDrawable` needs a compiled
      resource, with no runtime inflate-from-bytes. A PNG shipped at one
      size is soft at 2x/3x and kaya has no multi-resolution story. The
      shape that fits kaya: rasterize SVG IN CORE with `resvg` — one
      renderer, byte-identical output on all five platforms, the same
      doctrine as the shared scene scripts, and it routes around the
      Android limit. Cost: core must learn the target scale factor,
      which it does not know today.
    - Typeface substitution must change the FAMILY only, never the
      scale (Dynamic Type / `sp` both break otherwise), which makes the
      role tier a precondition rather than an alternative.
  - **Accessibility surfacing**: the architecture carries it for free
    (native widgets ARE the accessibility tree, DESIGN's
    Accessibility passage) but nothing PROVES it and apps cannot
    author it: wants an accessibility label/hint prop (the sibling of
    test_id, which is already framed as the accessibility
    identifier) and a harness verb that reads the REAL platform
    accessibility tree (VoiceOver/UIA/AT-SPI) — the gate the claim
    deserves. Rides naturally with the test_id milestone.
  - **Video widget**: unexamined — DESIGN has the surface-handle
    transport (the Canvas zero-copy arm) but no media-playback
    story. The wrap-native bet suggests a Video widget over each
    platform's native player (AVPlayerView / MediaPlayerElement /
    Media3 / GStreamer) before any frame-pushing pipeline.
    Trigger-gated on an artifact app.
  - Audio is NOT listed here: it is designed (core-owned RT callback
    + sample ring + node-graph vocabulary, DESIGN's Audio passage)
    and stays admission-gated on an app that needs it.
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
- **The versioned binding style guide** (DESIGN open question #1) —
  DEPRIORITIZED 2026-07-24 (Akhil): kaya maintains its own bindings, so
  cross-binding consistency comes from one set of hands plus the gates
  (check-sugar-surface, the abort checks, the emission checks), not
  from a document. A style guide is what you write when OUTSIDE
  contributors author bindings; revisit when the library is mature
  enough for that to be true. The per-family spellings stay ratified
  and in force (chains: Rust/Go/Java; named args:
  Swift/Python/C#/OCaml; config lists: Haskell — DESIGN's Binding
  conventions; OCaml's ambient-transaction spelling, 2026-07-22).
  Three items filed under it are NOT style and keep their own standing:
  - **Container scoping for layout props** — typed row/column contexts
    making an orphan `grow` a compile error. A safety guard (types over
    runtime checks), not ergonomics. The ambient languages' nullary
    container bodies cannot express a receiver without a redesign,
    which is why it waited.
  - **Derived-signal vocabulary beyond Python** (eq/ne/fmt) and
    **blob-signal parity** (Go has typed Signal[[]byte]; others wrap
    handles) — capability gaps between bindings, not spelling ones.
  - **Decision gate for deleting the probe/reflection selector floor**
    that the KayaGen generators superseded — debt with a real deletion
    behind it.
  The rest — per-language tiers, ambient-tx spellings for the remaining
  languages, Rust's chained `.grow()`, optional static analyzers,
  multi-window ergonomics — waits for the guide, and the guide waits
  for maturity.
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

- **Undo/redo and session restoration — core-owned, and cheap only
  here** (from the 2026-07-24 survey; TRIGGER SATISFIED by the text
  editor). Every other cross-platform framework bolts undo onto
  application state it does not own; macOS has `NSUndoManager` and the
  other three platforms have nothing portable. kaya owns all state at
  rest and every mutation already arrives as a transaction, so an undo
  stack is a log of objects core materializes anyway. The same
  machinery gives window/session restoration — serialize the core
  scene, not the app's state — which cmyr's ingredient list names and
  nobody enjoys writing. NOT free: the design pass has to answer which
  transactions are undoable, whether an undo re-runs handlers or simply
  applies the inverse transaction, and what happens to occurrences
  emitted during an undo. Do the design pass before any protocol work;
  the machinery being present is not the same as the semantics being
  obvious.
- **The system-integration floor** (from the survey; the editor
  triggers the first three). Four surfaces, native on every platform,
  none previously in this ledger, and collectively what separates a
  demo from an app. In the order real apps need them: **file dialogs**
  — NOT a widget, a presentation context returning a result, i.e. the
  alert grammar with a path instead of a button (DESIGN's admissions
  queue has been corrected); **clipboard** — note it is SYNCHRONOUS on
  mac/Windows and ASYNCHRONOUS on Linux, so the API must be
  async-shaped or it is wrong on one platform, and it is also the
  unblocker for the deferred cut/copy/paste roles; **notifications** —
  the four platform models are close; **drag and drop** — the most
  divergent, and it interacts with window management on both mac and
  Windows. **Printing** sits behind all four and is not editor-forced.
- **Standard commands LANDED 2026-07-24** (the follow-up milestone to
  menus): a chord rides any window-anchored LEAF command rather than
  plain actions alone, the key floor admits eight named punctuation
  keys, and `role` names a standard command with `settings` as its one
  v1 value. DESIGN.md's "Standard commands" and the shortcut policy
  carry the rules; the `commands` scene proves all three in nine
  languages on every lane. Still open, trigger-gated: roles beyond
  `settings`, and punctuation keys beyond the admitted set.
- **Menus follow-ons.** The command vocabulary LANDED 2026-07-24 —
  both anchors, all four backends, all 8 bindings plus the C floor,
  and the menus scene green on every lane. DESIGN.md's "Menus and the
  command vocabulary" is the whole record — the design, the lowering
  per host, and the two platform limits under "Where a platform cannot
  say it". What stayed out is trigger-gated, each trigger
  stated in that section's "Deliberate cuts and admission triggers":
  shared command identity across anchors (the responder-chain/target
  problem), For-stamped items, `bind_field` labels on context items,
  merging authored items into native text-control menus, a GTK
  hamburger presentation hint, item removal, context-item shortcuts,
  role-based standard items (including native Settings placement),
  punctuation shortcut keys, and — only under artifact pressure — a
  toolbar grammar. One follow-on the section does not carry: iOS has
  no hardware-keyboard route to the catalog. The interpreter holds
  the shortcut table (the harness verb drives it, and the scene
  proves the dispatch), but nothing binds it to a real iPad keyboard
  or to the hold-Command HUD — that wants `UIKeyCommand` /
  `UIMenuBuilder`, since the macOS lowering is NSMenu rather than
  SwiftUI `.commands`. TRIGGER (SUPERSEDED 2026-07-24 — see the iPad
  DEFECT entry at the top; iPadOS 26's menu bar is not keyboard-gated,
  so this trigger could never fire for the case that matters): an
  artifact running on iPad with a keyboard. Android's equivalent route
  IS live (each host Activity forwards `dispatchKeyShortcutEvent` into
  the same table).
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
  suspension lifecycle (Android).
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

- Scene-run coverage, the remaining half: check-steps' wired() now
  demands per-runner LEG SIGNATURES (run $scene- / run "$proto"
  $scene- / run_suite ${scene}_), so a scene absent from a runner
  fails the gate — but a grep signature proves WIRING, not execution.
  Nothing yet proves the exact scene × language × platform tuples
  that actually ran and produced verdicts (a runner can still skip
  legs at runtime); an executed-suite manifest compared against the
  expected tuple set is the missing gate.
  Packaging notes for whoever adds the next scene (walked end to end
  by menus, 2026-07-24): on iOS the swift guest rides
  IOS_SWIFT_SCENES — one name, bundle and leg derived — while a rust
  example needs its own build+bundle+queue_leg block; Android has one
  apk PER GUEST TIER, each a scene selector keyed on KAYA_SELFTEST —
  milestone2 (the Rust guest: a new scene needs a `mod` + match arm
  in guests/rust/milestone2_android.rs) and milestone2kt (the JVM
  guest: its MainActivity needs the matching arm) — plus a run_apk
  leg per tier; on Windows the name in deploy-win's SCENES derives
  the cross-build, the scp of exe/python/go sources, and the taskkill
  entries, leaving only a tools/guest/run_<scene>_<lang>.cmd per
  language and the run_suite block. A scene whose guests do not all
  exist yet must NOT join SCENES: the per-language surfaces glob for
  sources and must keep failing loudly for the scenes that do exist.
- Recording stills DRIFT across a long scene: the film and the
  harness transcript are anchored at ONE instant, and their clocks
  then run at different rates, so a step's still is progressively
  earlier than the step. Menus (38 steps, ~2.4s of transcript) is the
  first scene long enough to show it — measured 2026-07-24 on iOS:
  the leg's steps span 2.4s of harness time while the same run
  occupies ~1.3s of film, so `step-38` renders a state from before
  `click button#2`. The film itself is complete (t=31.0s of suite-1
  shows the true final frame: `shared`, Publish promoted, the removed
  row gone) — only the mapping is wrong. Same root cause as the
  "anchor implausible" failures on the busiest simulator, where the
  accumulated drift pushes a leg's span past the film's end and the
  extractor (correctly) refuses. Android has the weaker form: it
  anchors at stop time minus duration, and screenrecord drops its
  buffered tail. Fix direction: calibrate rate, not just offset — two
  fiducials per film, or a per-leg in-band fiducial — rather than
  trusting one anchor across a whole suite. Windows has a third
  variant: `KAYA_RECORD=1 deploy-win … menus_rust` passed the leg and
  then reported "the capturer produced no frames" — the WGC capturer
  never attached to a window that lives about two seconds.
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
- resize_window harness verb (Akhil asked 2026-07-22) — MERGED into the
  form-factor milestone 2026-07-24; the same verb is the size-class
  transition gate, so do not schedule it separately. Backends
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
