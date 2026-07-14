# kaya — design

Status: design converged on architecture; no implementation yet.

kaya is a cross-platform GUI library that wraps each platform's native widgets:
one API, a native body per platform. This document records the architectural
decisions, the reasoning behind them, and the alternatives that were considered
and rejected. It is the written form of a long design derivation; where a
decision looks unusual, the rejected-alternatives section explains what it was
tested against.

## Premise and constraints

1. **Native widgets, not custom drawing.** kaya creates and manages real
   platform widgets (`NSView`, WinUI controls, `GtkWidget`, Android views).
   This is the opposite bet from Flutter/egui/Slint, which draw every pixel.
2. **Multi-language bindings are first-class.** The stable API is a C ABI.
   Bindings (Python, JS, Go, JVM, …) must be thin and mechanical. This
   constraint drives more of the architecture than any other.
3. **"Native" means platform-supported, not "ships in the OS with a C ABI".**
   WPF and WinUI are native on Windows; reaching a toolkit through a managed
   runtime bridge (JNI on Android, hostfxr for .NET) is acceptable. Backend
   selection is engineering economics, not purity.
4. **Each platform flows like itself.** Cross-platform pixel identity is a
   non-goal. Identical kaya code may lay out differently per platform, and
   that is intended behavior, not a defect. (See Layout.)

## Platform backends

| Platform | Backend | Notes |
|----------|---------|-------|
| macOS    | AppKit  | First backend (fastest iteration loop). |
| iOS      | UIKit   | Natural second Apple target — shares most of the AppKit bridge layer; same protocols where it matters (`UITextInput` for IME, UIKit accessibility, Core Animation compositing, `UITableView` pull-based virtualization). Platform wrinkle: suspension lifecycle ultimatums (occurrence + deadline class). Linux-hosted build/device-deploy is feasible via xtool-style SwiftPM cross-compilation; the Simulator remains macOS-only. |
| Windows  | WinUI 3 preferred, via `windows-rs`/COM — no bridge language needed. **Second backend overall** — deliberately early, to de-risk the least-proven bet (WinUI via COM from Rust) while Win32 fallback is still cheap to take. Win32 common controls as fallback if COM friction proves too high. WPF possible later via hostfxr + C# shim (same shape as the Android bridge). |
| Linux    | GTK (conventional stand-in; Linux has no OS-native toolkit). |
| Android  | Platform views via a JNI bridge. |

Raw Win32 common controls have no layout system at all (`WM_SIZE` and manual
pixel placement), which is an additional argument for WinUI: the layout
strategy below assumes each backend has a real native layout engine.

## Core object model

- **Retained core.** The core owns a retained tree of widget records; each
  record owns its native handle (`NSView *`, WinUI element, `GtkWidget *`).
- **Generational ids as handles.** Widgets are identified by slotmap-style
  ids (slot index + generation), never by pointers. Generations exist to
  catch the ABA problem (a stale id whose slot was reused must be *detectably*
  dead, not wrongly alive) — they are not a leak-prevention mechanism; leaks
  are prevented by removal bookkeeping. Ids cross FFI trivially, and foreign
  languages *will* hold stale handles: with generational ids a stale handle
  is a catchable error rather than use-after-free UB in someone's runtime.
  Multi-language bindings are the strongest argument for generational ids.
- **Destruction cascades.** Removing a widget must release its native handle
  and cascade to descendants, reconciled with the fact that native toolkits
  destroy children of a destroyed parent themselves. This bookkeeping — not
  the arena flavor — is where the leak/double-free bugs live.
- **Main-thread affinity.** All native-widget manipulation happens on the
  platform main thread, which the core owns. In Rust this is enforced at
  compile time (`!Send` handle types internally).

## API layers

**The only true boundary is the ring protocol; everything crossing it is
data.** The C ABI is not the interface — it is how foreign languages reach
the rings. The published, stable contracts are the protocol itself and the
command vocabularies. Versioning follows Wayland's model: **per-vocabulary
version negotiation** — each vocabulary (widget set, layout, transforms,
IME contract, …) advertises a version, bindings bind at the minimum they
support, opcodes are additive-only and never repurposed, and an unknown
opcode fails loudly at submission with an error record, never a silent
no-op.

**Design principle: the public surface is the performance ceiling.** No
binding should ever need to bypass the public API to build something
faster — the fast path *is* the API. It is allowed to be verbose or
awkward; language bindings paper over ergonomics, never over performance.
Consequence: the surface must be mechanism (a substrate frameworks compile
onto), not policy (a framework worldview bindings would route around).

- **Internal widget core — not exposed over C.** The retained tree of
  generational-id widget records and its imperative mutation layer are
  internal Rust. Signals subsume public property-sets (a bound signal
  write *is* a property set with the target declared up front), and
  `When`/`For`/instantiate subsume public structural edits — a public
  retained C API would be a second, redundant way to do everything. Kept
  internal, the mutation-sequencing invariants (focus preservation across
  reorders, detach-before-reattach) are private code paths driven only by
  our own operators, not documentation for strangers; the hardening
  surface shrinks from "any command sequence any binding might emit" to
  "what our operators emit." The in-process Rust crate may build typed
  layers against crate-internal APIs; platform-specific escape hatches
  ("hand me the raw `NSView`") are a native extension mechanism on the
  main thread, outside the protocol. Exposing a retained C API later is a
  compatible addition; retracting one is impossible — start closed.
- **The reactive surface — the public API.** Signals, bindings, structural
  operators, templates, and one-shot commands (`focus()`, `close()`,
  `scrollTo()`, instantiate/dispose of root instances) — all as protocol
  records:
  - **Core-resident signal graph.** Create signal / set value / derive —
    the guest pays per *write* (one ring record); propagation runs at Rust
    speed on the fast side. This is what fixes the dynamic-language cost
    structure: no guest-side dependency bookkeeping at all.
  - **Property bindings**: signal → widget property.
  - **Structural operators**: `When` (boolean signal mounts/unmounts a
    template instance) and `For` (keyed collection signal drives a
    container's children). `When` controls *existence* — instances are
    created and destroyed, state included; the `hidden` property controls
    *space*. (Named `When`, not `Show` or `If`: "Show" collides
    conceptually with `hidden` — Vue ships both `v-if` and `v-show` and
    the confusion is a perennial ecosystem question — while lowercase
    `if` is unwritable in snake_case bindings, violating the
    line-for-line translation rule. `When` is Solid's prop name and
    idiomatic in every casing convention.) `For` contains the irreducible kernel of
    diffing — keyed reconciliation scoped to collections, written once in
    the core, which is also where mutation-sequencing knowledge lives
    (focus preservation across reorders, detach-before-reattach). Solid's
    operator set is the proof of sufficiency; fine-grained reactivity
    never eliminated diffing, it scoped it to the one place structure
    follows data.

    Collections come in two flavors. **Inline**: the full keyed list is
    the signal value; `For` instantiates every child. **Virtual**: the
    signal value is a *manifest* — total count + key schema (also what
    answers accessibility aggregate queries) — and row data lives in the
    row window. The native virtualized widget pulls row N; the core
    stamps the row template and binds its slots to **row-scoped signals**
    backed by the window's data for that key; the demand channel drives
    which rows are materialized. Platform cell recycling maps to
    **rebinding** an existing template instance to a different row's
    signals — identity switch, no re-instantiation.

    `When` is implemented as the degenerate `For` (a collection of zero or
    one). The operator set is a complete basis — `if` + `map` over
    structure. Expected later admissions under the escalation policy:
    `Portal` (subtree rendered as a platform overlay/popup — likely
    triggered by menus and tooltips in the first backend) and `Switch` as
    sugar over chained `When`s.
  - **Inert subtree templates, authored by functions.** The sole
    authoring model is a component function: it takes slot proxies as
    parameters, returns a node description, and runs **once, to record —
    not per state change** ("record, don't render"; Solid's model).
    `When`/`For` take these functions; a reusable component is just a
    function bound to a name; the standalone "template object" exists
    only as the internal recorded artifact and the serialized form.
    **The slot schema is the function signature** — parameter names and
    types, validated at record time — which also lets the row window
    store rows in fixed layout in the arena rather than generic maps.
    Nodes may carry a **ref marker**; instantiation reports a per-instance
    handle for mirror reads and one-shot commands. Guardrail for the one
    trap (closures invite the Flutter re-run intuition): the recorder
    flags any mirror read (`.value()`) inside a recording scope —
    "snapshot in template: bind the signal or take it as a parameter."
    Encoding (decided): the C ABI is a **builder API** (`begin_node` /
    `set_prop` / `bind_slot` / `end_node`) — templates are small and
    built rarely, so the encoding optimizes for binding simplicity. The
    builder records into the canonical serialized form; submitting a
    prebuilt buffer is equally legal (the server-driven UI and tooling
    path). Node properties are constants or slot references; templates
    nest (anonymous fragments for `When`/`For` branches).
  - **Bound properties are constants or signal references — nothing
    else.** Display values (strings, colors) derive app-side, in the guest
    language: the app is already awake when it mutates its own state, so
    deriving there adds no round trip, and localization/pluralization must
    live guest-side anyway. All state at rest is core-owned signals; the
    guest is the transition function — bare guest values exist only in
    flight between computing and writing. Reserved escalation path for the
    one real customer (fast-side-sourced bindings: slider-percent labels,
    parallax, counters against uncontrolled fields): a closed,
    non-composable set of binding *transforms* — `linear` (a·x+b),
    `select`, `format` — admitted individually on demonstrated artifacts.
    Flat descriptors, no nesting, hence no grammar, hence nothing that can
    ratchet toward a language (the fate of XSLT, JSP EL, Angular
    expressions). v1 ships none — identity bindings only. Named future
    force that legitimately reopens core-side expressions: server-driven
    UI and visual tooling, where the "app" is a network away or absent —
    every industrial SDUI system grew an expression system. Per-vocabulary
    versioning makes that a purely additive, consumer-scoped decision
    later.
  - **Core-to-core bindings**: signals sourced from core state (scroll
    offset → transform, hover → highlight) propagate entirely fast-side —
    full-rate updates even mid-app-stall. QML-grade liveness falling out
    of the fast-side-state invariant.
- **Guest frameworks compile onto the reactive surface, not around it.**
  Svelte-style compilers bind a signal per dynamic property at build time
  and emit signal writes; Solid-style runtimes do the same at runtime;
  Xilem-style typed Rust views (`build`/`rebuild`, `FnMut(&mut State)`
  handlers) sit on crate-internal APIs. None needs its own reconciler.
  Whole-tree diffing (React-style UI = f(state)) can be built as an
  optional library on top of templates + signals, but is not the core's
  declarative primitive. Python's ceiling sugar is JAX-style tracing:
  `for t in todos:` traces to `For` via `__iter__`; comparisons overload
  into binding-maintained derived signals (recomputed at write time,
  batched in the same transaction — the core never knows); `if` on a
  signal raises "use `kaya.when`" — Python cannot overload statement
  branching, the same wall that gave JAX `lax.cond` and pandas its
  "truth value is ambiguous" error.
- **Per-language sugar** is thin and idiomatic per binding; verbosity of
  the core API is the binding's problem to hide, by design.

## Binding conventions

A cross-language style guide is a **versioned pre-v1 deliverable** — the
rules that keep bindings mutually recognizable live nowhere else (Wayland
ships protocol conventions for the same reason). The settled rules so far:

- **Canonical method vocabulary for derived signals**: `eq`, `ne`, `lt`,
  `fmt`, … — method-shaped in every language (`count.eq(0)` / `count.Eq(0)`),
  and documentation leads with it, so tutorials translate line-for-line.
  Operator overloading (Python `count == 0`) is optional per-language sugar,
  with the DSL sharp edges documented (hijacked `__eq__` breaks naive
  hashing and identity comparison — the SQLAlchemy/pandas trade).
  Derived signals are binding-maintained: recomputed at write time,
  batched into the same transaction; the core never knows.
- **Values in handlers, signals in templates.** `.value()` reads a mirror
  snapshot — correct in transition code, a frozen-branch bug in template
  position. Statically typed bindings enforce this at compile time
  (`When` takes `Signal[bool]`, not `bool`); dynamic bindings check at
  record time.
- **Handlers receive their transaction** (explicitly, as in Go's
  `func(tx *Tx)`, or ambiently, as in Python) — surface per language,
  semantics fixed by the protocol's handler-=-transaction rule.
- **Components are functions** taking slot proxies, returning node
  descriptions, run once to record. Reuse is function reuse.
- **Pick one property-configuration style per language** (functional
  options vs config structs — Go UI DSLs have gone both ways) and never
  mix within a binding.

## Layout

**Decision: ride the platform's native layout engines.** Nearly every shipped
cross-platform-native framework (React Native/Yoga, Xamarin.Forms, MAUI,
wxWidgets, SWT) did its own layout math and absolutely positioned native
views. That record reflects a goal we explicitly do not have: pixel-consistent
layout across platforms. Given "each platform flows like itself," mapping a
deliberately small layout vocabulary onto native engines is coherent:

- Vocabulary: H/V **stack** (spacing, alignment, grow weights), **grid**,
  **spacer**. Maps to `NSStackView`/`NSGridView`, XAML `StackPanel`/`Grid`,
  `GtkBox`/`GtkGrid`, `LinearLayout`/`GridLayout`.
- Escape hatch for per-platform layout attributes that don't generalize.

**Normalize semantics, not metrics.** API constructs must mean the same thing
everywhere; the numbers platforms produce (control sizes, spacing, wrap
points, baselines) stay platform-flavored. Known normalization worklist:

- `hidden` means *collapsed* (occupies no space) everywhere. (GTK collapses,
  AppKit reserves space, XAML distinguishes Collapsed/Hidden.)
- A defined overflow policy (platforms variously clip silently, refuse to
  shrink windows, or break constraints by priority).
- Grow distribution normalized to explicit weights.
- Height-for-width (wrapping labels in stacks) gets dedicated conformance
  tests from day one — the most notorious cross-engine divergence.
- One logical coordinate unit, with defined fractional-scale rounding.
- Leading/trailing (never left/right) in the API; platform RTL mirroring
  does the rest.
- macOS alignment rects (frame vs visual bounds) handled in the backend.

**Process:** a conformance gallery app — canonical scenes per layout scenario,
run on every backend, eyeballed side by side. Divergences get sorted into
"semantics → normalize in backend" or "metrics → document as platform flavor."
The gallery doubles as the permanent regression suite.

## Threading model and protocol

This is the heart of the design.

- The **core owns the platform main thread** (required to be *the* main
  thread on macOS) and runs the native event loop. kaya hosts the language
  runtime, not the reverse.
- **App logic runs on its own thread** (the language runtime's thread).
- **Nothing crosses the boundary synchronously. No callbacks, no unbounded
  rendezvous.** All communication reduces to **two primitives plus an
  arena**:
  - **Logs** — lock-free SPSC rings for ordered, lossless, consumed-once
    traffic: occurrences out; commands and signal-write transactions in
    (`begin/end` markers, applied atomically at a frame boundary — no torn
    multi-signal states). **Handler = transaction**: the binding runtime
    wraps each dispatched occurrence batch in an implicit transaction,
    committed when the handler returns — atomicity by construction;
    explicit transactions exist only for writes outside handlers (timers,
    background completions). Fixed record header (u32 size, u16 channel/type,
    u16 flags), 8-byte aligned, variable-length payloads inline. Overflow
    grows by chained segments — never block the producer, never drop a
    record. The core reads the app's consumer cursor directly, so stall
    detection ("log undrained for N seconds") requires no protocol.
  - **Slots** — seqlock cells for keep-latest traffic, one per channel: a
    write is an overwrite, no queue exists; watchers get an optional
    coalesced wake record (at most one pending per slot). Present state,
    demand, and the app-readable widget-state mirror are all slots — one
    mechanism, three roles.
  - **Shared-memory arena** for bulk payloads (row batches, pixel surfaces,
    audio, templates), referenced by offset + length.

**The invariant:** every question the platform asks synchronously must be
answerable from state already on the fast (core) side. Events can express
anything, but they cannot arrive back inside the platform's stack frame.

### Traffic taxonomy

Channels are classified by direction × shape × loss policy:

**Core → app** (reports of the past, statements of need):
- **Occurrence log** — clicks, key presses, close-requested, lifecycle.
  Ordered, lossless, consumed exactly once. Occurrences originating inside
  a `For` instance carry the instance handle and row key, so per-row
  handlers receive their row identity without any per-row closure state.
- **Present-state slots** — mouse position, scroll offset, geometry during
  resize, widget values. Keep-latest; coalescing is correct semantics, not
  degradation. The same slots double as the readable mirror: the app reads
  current widget state on demand without blocking anyone — uncontrolled
  inputs are read at decision points instead of tracking keystrokes (the
  HTML-form insight).
- **Demand slots** — state about the future: "viewport now needs rows
  300–350," "need a frame at 800×600." Keep-latest; supersession is
  overwrite, so cancellation costs nothing. Each demand is paired with a
  proceed-default (placeholders, scaled stale frame). Demand aggregates
  naturally (a fling coalesces into one range update — strictly better than
  per-cell callback pulls).

**App → core** (content for the future, rules for the gaps):
- **Command log** — one-shot imperatives: `close()`, `focus()`, `scrollTo()`.
- **Content buffers** — templates and signal writes (keep-latest per
  signal), row data, drawn frames / display lists, audio samples. The slow
  side works *ahead* of demand; freshest wins (or sequential-ahead for
  media). The audio ring is the limiting case (perfectly predictable
  demand); the row window is the same mechanism with imperfect prediction;
  a placeholder is the visual analogue of an underrun.
- **Vocabularies** — pre-pushed rules that let the core answer questions
  during app-thread gaps: validation masks, shortcut tables, accepted drop
  types and operations, declared list counts, closability, a11y annotations
  (as node properties on the submitted tree). A vocabulary is a compressed
  buffer of pre-computed answers. **Escalation policy:** ship the pure event
  protocol first; add a vocabulary only when a default-now-correct-later
  artifact proves unacceptable. Each addition changes what the core answers
  during the gap, not the shape of the API.

### Answering strategies and the blocking policy

Every synchronous platform question is answered by exactly one of:

1. **Pre-pushed state / vocabulary** (preferred).
2. **Default now, correct later** — placeholder cell then patch, stay-open
   then app-initiated `close()` (request/confirm), claim-unhandled then
   re-dispatch.
3. **Bounded wait** — park the platform's pull for a deadline, then fall back
   to (2).

Blocking policy, derived at length:

- **Bounded waits on content are always allowed** — lateness is cosmetic
  (rows a frame late), semantics identical. In the healthy case the round
  trip is microseconds and fulfillment lands before paint: *no placeholder is
  ever visible; behavior converges with the callback world.* Placeholders are
  the degradation mode, not the experience.
- **Bounded waits on decisions are allowed only when the expiry default is
  fail-safe and retryable** — e.g. the drop verdict (expiry ⇒ reject ⇒
  snap-back, a native idiom). Never when expiry silently commits a
  non-reversible branch (a "move" drop deletes the source original).
- **Unbounded waits are prohibited, categorically.** Finiteness — any finite
  deadline, however generous — is what provides: deadlock immunity (every
  wait cycle becomes a one-deadline artifact), OS watchdog safety (unpumped
  main thread ⇒ "Not Responding"/beachball/AX "busy"), a cap on priority
  inversion (a parked user-interactive main thread inherits the app thread's
  QoS; futex/condvar parks do not donate priority), and — critically — it
  keeps UI liveness a property of the architecture rather than a discipline
  ("keep the app thread responsive" is "don't block the main thread"
  renamed, which the second thread exists to abolish). Deadlines are
  per-channel tuning, not architecture.
- Stall diagnostics come free from the transport: the core reads the app's
  log-consumer cursor, and "undrained for N seconds" is the health signal.
  (An earlier draft had a Wayland-style liveness ping; the cursor makes it
  redundant.) The UI does not need app liveness to stay live.

## Case analyses (stress tests the model passed)

- **Virtualized lists.** Native list virtualization is pull-based and
  synchronous (`cellForRowAt`, `RecyclerView`). Core holds a materialized row
  window, answers pulls from it, publishes viewport demand, app refills ahead.
  Same-frame fill in the healthy case (drain fulfillments before the paint/
  commit point); placeholders on teleport or app stall. This was React
  Native's famous failure (blank cells, later fixed by adding sync JSI) — RN
  had neither fast-side state nor control of the protocol boundary; kaya has
  both.
- **Window close / veto class.** Request/confirm: core defaults to staying
  open, emits `CloseRequested`, app later issues `close()`. No response
  required, no correlation ids. (winit/Tauri/Electron converged here.)
- **Drag and drop.** Hover acceptance from a pre-pushed vocabulary (accepted
  types, operations) — matching platform convention, since fetching drag
  content mid-hover is discouraged everywhere. Dynamic hover policy as
  app-updated state (staleness mislabels a cursor badge: cosmetic). Drop
  verdict: bounded wait with expiry ⇒ reject (fail-safe, retryable,
  snap-back is a native idiom). Source-side data provision
  (`IDataObject::GetData`, pasteboard promises): demand with a generous
  deadline — the blocked party is the receiving process and platforms have
  normalized slow providers. Bonus: app logic keeps running inside drag/
  resize modal loops that imprison single-threaded apps.
- **Accessibility.** The architecture's best advertisement: native widgets
  *are* the accessibility tree and answer VoiceOver/UIA/AT-SPI from retained
  core state — the app is not in the answer path, by construction (contrast
  the permanent semantics-tree tax on custom-drawn frameworks). A11y stays
  fully live during app stalls (a classic app's stalled main thread reads as
  "busy" to VoiceOver). Residues: out-of-window virtualized rows = demand
  with generous deadline (AX clients tolerate seconds); custom-content
  annotations ride the submitted tree; assistive actions are ordinary
  occurrences.
- **Custom drawing.** Compositor model: app renders into retained surfaces
  (`CALayer`/IOSurface, DirectComposition + swap chain, Wayland buffers) on
  its own schedule; core displays the latest completed frame. WPF (no paint
  callback, retained drawing tree) and Chromium (cross-*process* rasterizer/
  compositor split) are existence proofs. Interactive resize is the stress
  point: bounded micro-wait for the matching-size frame (what browsers do
  internally), and — better — **display-list submission** lets the core
  re-rasterize at any size with no app round trip; only reflow-dependent
  content still needs the app. Degradation: browser-grade momentary
  stale-scaled content on violent resize. Decided: **v1 ships pixel
  surfaces only**, passed as platform surface handles (IOSurface, DXGI
  shared handles, dmabuf) — handle passing, not copying. Display lists are
  v2, adopting Vello's scene encoding rather than inventing a format.
- **IME composition.** Input methods hold a mid-keystroke conversation with
  the focused field: set/update preedit, read surrounding text, query the
  composition rectangle (candidate window placement), commit. Platform
  protocols span the synchrony spectrum — `NSTextInputClient` (fully
  synchronous), Windows TSF (`ITextStoreACP` document locks, with an async
  grant path), Android `InputConnection` (cross-process with timeouts; slow
  apps return `null` to the IME), Wayland `zwp_text_input_v3` (pure async
  state sync: pushed surrounding text + cursor rect, preedit/commit events).
  For **native text widgets** the platform's own controls implement the IME
  protocol against their internal buffers — the app is not in the
  conversation at all (the accessibility dividend again). New protocol rule
  this forces: **composition is a transaction** — the core (which knows
  composition is active) queues app-originated mutations and defers
  vocabulary filtering until commit, making the classic clobbered-preedit
  bug class (garbled CJK in controlled inputs) impossible by construction.
  For **custom text editors** (app-drawn), the app fulfills an **IME
  contract** of three state channels — windowed text mirror around the
  cursor, selection, cursor/composition rectangle — against which the core
  implements the platform protocols; IME edits stream back as occurrences.
  The contract adds no mechanism — the three channels are ordinary
  app-written signals on the editor widget; only the convention is named.
  The contract is isomorphic to Wayland text-input v3, and Chromium proves
  the shape at scale (browser-process TSF/`NSTextInputClient` answering from
  renderer-mirrored text, across a full process boundary). Degradations
  (custom editors only): preedit repaint lags an app stall like any canvas
  content; candidate window trails a stale cursor rect (cosmetic; inherent
  to Wayland's design too); reconversion context limited to the mirror
  window (IMEs degrade gracefully with partial context; browsers ship
  partial TSF stores). Contract details (decided): the mirror is the
  paragraph around the cursor capped at 4 KB (Wayland's cap; Android's
  defaults are far smaller); TSF sync-only lock demands beyond the mirror
  receive a partial store; core-composited preedit for custom editors is
  deferred to v2 alongside display lists.
- **Audio.** The render callback is hard-real-time and can never be an event
  to the app thread — in *any* architecture (an SDL-style callback into a
  GC'd language glitches on the first collection; the constraint is physics
  and garbage collectors, not the protocol). Pro audio itself forbids
  callbacks into app logic from the RT thread and lives on lock-free rings —
  our protocol, invented independently decades ago. Decision: the **core
  owns the RT callback** (Rust, RT-safe) and drains a sample ring the app
  fills ahead (playback: 20–100 ms ahead; underrun ⇒ silence). Synthesis via
  a declarative node-graph vocabulary (Web Audio's answer), and a native DSP
  module as the escape hatch for real low-latency work (pushed *code*, à la
  AudioWorklet — an escape hatch every framework needs).

## Rejected alternatives

- **Classical synchronous callbacks (all-callback model).** Reentrancy as a
  standing bug class; app logic welded to the main thread; FFI callback
  machinery in every binding — the callbacks that survive any purge (data
  pulls, paint, input filtering, audio) are precisely the synchronous,
  latency-critical, reentrancy-prone ones, i.e. the worst possible things to
  expose across a language boundary.
- **SDL-style hybrid (events + a handful of callbacks).** Keeps nearly all
  the FFI pain (see above) while adding the queue machinery anyway.
  Reversibility is asymmetric: a narrow opt-in same-thread hook can be
  *added* compatibly later if a wall is hit; a callback shipped in v1 is a
  permanent contract that welds the threading model into every binding.
  Start at zero.
- **Unbounded cross-thread rendezvous.** For identical, disciplined code it
  actually beats the callback world on freeze behavior (fewer, shorter
  freezes) — but it loses to *bounded* blocking at every point on the curve:
  unboundedness re-imports main-thread discipline under a new name, opens a
  deadlock class the deadline closes, trips OS watchdogs, and inherits
  priority inversion. ∞ is not the limit of "generous"; it is a qualitative
  cliff. Failure is also unattributable (emergent, timing-dependent) where
  callback-world slowness is locally attributable — and option-1 state
  answering is the only arrangement that makes the discipline *structural*.
- **Deadline-bounded waits on decisions without fail-safe defaults.**
  Load-dependent semantics (the close veto that sometimes works) —
  a heisenbug generator baked into the platform contract.
- **Pure polling / no events at all.** Occurrences don't sample (counters
  lose ordering; flag-clearing reinvents interrupt-status handshakes);
  efficient polling requires block-until-changed, which is an event; polling
  cadence burns battery or adds latency. Walking back the invention of the
  interrupt. Its lasting contribution: much upstream traffic *is*
  state-shaped → keep-latest channels and the readable mirror.
- **Own layout engine over absolutely-positioned native widgets.** The
  industry-standard choice, rejected here because it serves a goal (pixel
  consistency across platforms) that kaya explicitly renounces. Revisit only
  if "make it match across platforms" ever becomes a requirement — that
  requirement, not implementation pain, is what would flip this decision.
- **Whole-tree core reconciler as the primary declarative API.** The
  original level-1 design: submit a full view-tree description, core diffs
  against the previous submission. Rejected once the bypass incentive
  became clear: a whole-tree reconciler is *policy* — one framework's
  worldview (UI = f(state), re-render and diff) — and performance-minded
  bindings (compile-time reactive, signal-based, typed-view) would route
  around it to the imperative layer, contradicting the ceiling principle.
  Replaced by the signal substrate, onto which those same strategies
  compile instead. What the reconciler provided survives:
  day-one usability for new bindings (signals + templates is a lower
  floor), UI-as-data tooling (inert templates), and the sequencing
  reference (inside `For`). Whole-tree diffing remains buildable as an
  optional library atop templates + signals.
- **Public retained-mode C API ("level 0").** Superseded by the reactive
  surface once it became clear signals subsume property-sets and
  `When`/`For`/instantiate subsume structural edits — the retained C API
  was a second, redundant way to do everything, and redundant public
  surface is where misuse lives. Internalizing it shrinks the hardening
  burden to sequences our own operators emit, and the reversibility
  asymmetry applies: exposing later is additive, retracting is impossible.
- **Core-side expression vocabulary.** Proposed as format/arithmetic/
  compare/select evaluated in the core; killed by three observations:
  (1) for app-sourced state the app is already awake when the source
  changes, so app-side derivation adds no round trip — the motivating
  example was hollow; (2) real display strings need localization and
  pluralization, which must live in the guest's i18n tooling — a core
  `format()` that can't pluralize is a demo feature and a shipping trap;
  (3) it cannot be adopted transparently (a Python f-string evaluates
  eagerly), so it would be a second visible way to compute things in
  every binding. Survives only as the flat transform escalation path and
  as a future consumer-scoped decision if server-driven UI arrives.
- **Raw Win32 common controls as the primary Windows backend.** Dated look;
  no layout engine (undermines the ride-native-layout strategy). Retained as
  fallback.

## Degradation modes (accepted, by design)

The tail behavior when the app thread stalls — each the graceful analogue of
a callback-world freeze:

| Situation | Degradation |
|-----------|-------------|
| List teleport / stall during fling | Placeholder rows, patched on arrival |
| Violent interactive resize | Stale frame scaled/cropped for ≤ deadline |
| Drop verdict misses deadline | Drop rejected; drag snaps back (retryable) |
| Stale hover policy | Wrong cursor badge until refresh (cosmetic) |
| Audio ring underrun | Dropout (prevented by buffering ahead) |
| Custom-editor preedit during app stall | Repaint lags until app resumes (native widgets immune) |
| Candidate window with stale cursor rect | Placed at trailing position (cosmetic) |
| App thread stalled entirely | UI scrolls, resizes, stays AX-live; occurrences queue |

## v1 scope and delivery process

**Widget set — minimal by policy (15 items):**

- **Structure**: Window, VStack, HStack, Spacer, ScrollView
- **Display**: Label, Image
- **Controls**: Button, Checkbox, Entry (single-line, uncontrolled),
  Slider, Dropdown (select-only)
- **Collections**: List — virtualized, `For`-driven, the flagship
- **Chrome**: MenuBar (carries the declarative shortcut policy), Alert

Selection criteria: (a) needed by the archetype apps — todo-class,
settings dialog, data browser; (b) native peer on every v1 platform;
(c) machinery coverage — every protocol subsystem validated by at least
one widget: List (row window / demand), Image (content buffers), MenuBar
(policies), Slider + Entry (state slots, uncontrolled state),
Button/Checkbox (occurrences), containers (native layout). Decisions
inside the set: item-holding widgets (Dropdown, later RadioGroup) hold
items + a selection signal, never exposed child items (platform grouping
semantics are a trap); no Table — a multi-column row is a row template
with an `HBox` inside List.

**First-admissions queue (post-v1, rough order):** Grid (forms will
demand cross-row alignment), TextArea, Canvas (+ surface-handle
transport), Tabs, RadioGroup, ProgressBar, ContextMenu, file dialogs,
Separator, Splitter, Table, Tree, date/time pickers. Tooltips return as a
plain property. Not core: webview (separate crate, if ever), rich text
(post-display-lists), audio implementation (designed above; scheduled
when an app needs it).

**Breadth-first delivery (policy):** every widget/feature is validated on
*all* v1 platforms before the next begins — parity is enforced per
feature, not reconstructed per backend afterward.

- Milestone 0 is a skeleton on every platform (window + event loop +
  Button + one occurrence round trip), brought up in the order already
  chosen: AppKit, WinUI, GTK, UIKit, Android. "Backend order" now means
  skeleton bring-up sequence, not completed backends.
- The conformance gallery is the definition of done: a widget is admitted
  when its scene passes on every platform; the scene list accretes one
  widget at a time (seeded by the layout-normalization worklist scenes).
- LCD disputes surface at admission time — while the widget's semantics
  are being normalized across all platforms at once, before any single
  backend's assumptions fossilize into the API.

## Open questions

The former architectural open questions are resolved and folded into their
sections above (transport formats, template encoding, expression set,
`For` × row window, display-list plan, versioning model, IME contract
details, binding and backend order). What genuinely remains is
implementation-scale:

1. **Binding style guide** — expand the conventions section into the
   versioned pre-v1 deliverable it commits to. (The former slot-syntax
   question dissolved: the slot schema is the component function's
   signature.)
2. **Shared-arena reclamation** — generation/refcount scheme for bulk
   payloads.
3. **Vello scene-encoding subset** for v2 display lists (with Canvas,
   post-v1).

(The v1 widget set and the gallery scene list are resolved in "v1 scope
and delivery process" — the scene list accretes per widget admission.)

## Appendix: the shape of an app (Python sugar)

All state at rest is core-owned; the guest language is the transition
function. Bare guest values (the f-string below) exist only in flight.

```python
app        = kaya.App("Todos")
todos      = app.collection(key="id")   # keyed collection signal
items_left = app.signal("")

def todo_row(row):                                  # component = function; runs ONCE
    with kaya.hbox(spacing=8):                      # (records; slot schema = signature)
        kaya.checkbox(checked=row.done, on_toggle=row.toggle)
        kaya.label(text=row.title, grow=1)

with app.window(title="Todos"):
    with kaya.vbox(spacing=12):
        entry = kaya.entry()                        # uncontrolled; core owns its text
        kaya.button("Add", on_click=lambda: add(entry))
        kaya.for_each(todos, todo_row)              # For(collection, component fn)
        kaya.label(text=items_left)                 # bound (signal ref)
        kaya.label(text="Todos")                    # constant

def add(entry):
    with app.transaction():                         # atomic multi-signal write
        todos.append({"id": kaya.key(), "title": entry.text.get(),  # mirror read: local
                      "done": False, "toggle": toggle})
        entry.clear()                               # one-shot command
        n = sum(1 for t in todos if not t["done"])
        items_left.set(f"{n} item left" if n == 1 else f"{n} items left")

app.run()
```

`kaya.label(text=items_left)` lowers to three builder calls at the C ABI
(`begin_node` / `bind` / `end_node`); the `with` sugar, the tracer, and the
derived-signal helpers are binding-side, invisible below the ABI.

## Practical notes

- **Binding order**: the Rust crate exists by construction (in-process, no
  C ABI). **Python is the first foreign binding** — the harshest test of
  the core-side-performance thesis (slowest guest language, no build-step
  culture, so it exercises the signal substrate exactly as designed) and a
  large, underserved audience. Further bindings unordered for now.

- Crate name `kaya` is reserved on crates.io (placeholder v0.0.0, published
  2026-07-12, empty lib). Add `repository` (and a crate-level README) to
  `crates/kaya/Cargo.toml` before the next publish.
- **macOS development needs no Xcode** (GUI or `xcodebuild`): the AppKit
  backend links via `objc2` against the SDK from Command Line Tools or
  nixpkgs' apple-sdk, and `cargo run` launches unbundled AppKit binaries
  directly — sufficient for the conformance gallery. A minimal `.app`
  bundle (scripted or `cargo-bundle`) is needed only for bundle-identity
  features (app-menu name, `Info.plist` behaviors, TCC prompts,
  notifications). Distribution eventually needs the standard CLI tail:
  `codesign` (Developer ID) → `notarytool` → `stapler` → `spctl`, plus a
  one-time GUI certificate setup.
