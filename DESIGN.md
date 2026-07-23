# kaya design notes

Status (2026-07-23): the architecture is settled and implemented — eight
guest-language bindings over the C floor, one backend per platform
(SwiftUI on macOS and iOS, Compose on Android, GTK4 on Linux, WinUI 3 on
Windows; ratified 2026-07-20), and a shared scene suite validated
concurrently across the five-platform matrix. This document records
decisions as they were made, so some passages describe backends that were
later deleted (AppKit, UIKit, Android Views); their lessons stand, and the
current roster is stated where it was ratified (the "One backend per
platform" bullet in the threading section) and below.

kaya is a cross-platform GUI library that wraps each platform's native
widgets behind a single API. This document records the architectural
decisions, the reasoning behind them, and the alternatives that were
rejected. Where a decision looks unusual, the rejected-alternatives section
explains what it was tested against.

## Premise and constraints

1. Native widgets, not custom drawing. kaya creates and manages real
   platform widgets (SwiftUI views, WinUI controls, `GtkWidget`, Compose
   nodes). Flutter, egui, and Slint make the opposite bet and draw every
   pixel themselves.
2. Multi-language bindings are a primary requirement. The stable API is a
   C ABI, and bindings (Python, JS, Go, JVM, and so on) must be thin and
   mechanical. This constraint drives more of the architecture than any
   other.
3. "Native" means the platform supports the toolkit, not that the toolkit
   ships in the OS with a C ABI. WPF and WinUI count as native on Windows,
   and reaching a toolkit through a managed runtime bridge (JNI on Android,
   hostfxr for .NET) is acceptable. Backend selection is a question of
   engineering economics rather than purity.
4. Each platform flows like itself. Cross-platform pixel identity is a
   non-goal: identical kaya code may lay out differently on each platform,
   and that is intended behavior. See the layout section.

## Platform backends

The current roster is one backend per platform (ratified 2026-07-20): the
SwiftUI interpreter on macOS and iOS (one Swift file serves both), Compose
on Android, GTK4 on Linux, WinUI 3 on Windows. The native AppKit, UIKit,
and Android Views backends were built and validated first and then
deleted; where SwiftUI/Compose cannot express a semantic, the interpreter
drops down per widget through the platform's sanctioned interop
(NSViewRepresentable / UIViewRepresentable / AndroidView), intersection-
first, each drop-down recorded with its conformance scene. The table
below keeps each platform's bring-up record, including the deleted
backends, because the lessons in it still pay.

| Platform | Backend | Notes |
|----------|---------|-------|
| macOS    | SwiftUI interpreter (shared with iOS, see the iOS row). AppKit was the original first backend — fastest iteration loop for development — and is deleted; the interpreter's NSButton bridge is the standing per-widget drop-down. | First platform brought up. |
| iOS      | SwiftUI (the one Apple backend). UIKit was a first-class backend from milestone 0 through the roster ratification (2026-07-20) and is deleted. | SwiftUI exposes no object model — views are compile-time generic value types — so unlike Android's JNI route a SwiftUI backend is an interpreter written in Swift mapping kaya's scene onto SwiftUI declarations. The alignment is unusually good: kaya signal maps to an @Observable property, `When` to `if`, `For` to `ForEach`, templates to view builders, and SwiftUI's source-of-truth model is exactly kaya's core-owned signals, so the shim is closer to transliteration than translation (SwiftUI's own diff is what native apps pay anyway). The payoff is the SwiftUI-only surface: WidgetKit, the current design language, each year's newest controls. The friction is at the imperative edges — `focus()` via @FocusState, `scrollTo()` via ScrollViewReader, ref handles in a value-typed world, UIViewRepresentable escapes for the IME contract — each mappable, each bespoke. The SwiftUI backend (tools/swiftui) is a milestone-0 leg validated alongside everything else: the scene as SwiftUI speaking the protocol over the presentation-side C API — kaya_emit_* for occurrences out of action closures, and a blocking kaya_next_commands pump (the mirror of kaya_next_occurrence; no polling, no callbacks) hopping to the main actor to write @Observable state, with SwiftUI's invalidation as the render path. It passes the self-test in the iOS Simulator and natively on macOS from the same Swift file — one presentation layer serves both Apple platforms. Critically, the validated composition is the product scenario: the unchanged milestone-0 examples drive it via runtime backend selection — all four guest languages on macOS, and on iOS the Rust example's own main is the bundle executable with the SwiftUI dylib loaded from inside the bundle (the rust-swiftui leg). No app logic is written in Swift anywhere; app developers shipping on Apple platforms do not write Swift. This also establishes the guest-language-backend contract in miniature: the presentation-side C API is the same protocol with the roles swapped, exclusive with kaya_run per process. The imperative edges (focus, scrollTo, ref handles) get measured as real widgets arrive, per feature, breadth-first like every other backend. A backend written in Swift is fine — the Android backend will carry Kotlin/Java shim components regardless; backends may be thick, bindings must stay thin. The general pattern stands: every platform has a language-locked declarative layer (SwiftUI, Compose) over an object-model layer (UIKit, Android Views); kaya v1 validates both layers on Apple platforms (UIKit/AppKit and SwiftUI), and the object-model layer elsewhere. The milestone-0 skeleton passes in the simulator, validated from Rust and from Swift over the C ABI (swiftc imports kaya.h directly via -import-objc-header — zero re-declarations; Swift's C interop is free, so the function floor is already optimal and the direct-ring tier buys nothing there). iOS specifics: UIApplicationMain never returns, the delegate reaches its channel ends through a slot, the self-test exits the process (legitimate: on iOS kaya is the process), sendActionsForControlEvents drives the real action path, and simulator builds are unsigned — tools/ios/run-sim.sh boots, installs, launches with SIMCTL_CHILD_ env, and screenshots via simctl. It shares most of the AppKit bridge layer and has the same protocols where it matters: `UITextInput` for IME, UIKit accessibility, Core Animation compositing, and pull-based `UITableView` virtualization. The platform-specific wrinkle is the suspension lifecycle ("save state now"), which falls into the occurrence-plus-deadline class. Building and deploying to a device from a Linux host is feasible with xtool-style SwiftPM cross-compilation; the Simulator still requires macOS. |
| Windows  | WinUI 3 via `windows-rs`/COM, with no bridge language needed. The bet is validated: the milestone-0 skeleton (window, button, label, ring round trip) runs on Windows 11 ARM from pure Rust. Bindings are generated by windows-bindgen from the App SDK winmd (tools/winui-bindgen); a plain `Application` with no subclass suffices, with the scene built from a deferred dispatcher callback; `DispatcherQueue::TryEnqueue` is the doorbell; the bootstrap DLL is loaded dynamically (`MddBootstrapInitialize2`). All milestone-0 validations pass in the VM with clean exit codes: Rust exe, Python over the function floor, and two direct-ring consumers — Go (llvm-mingw cgo against the msvc-ABI dll) and C# (P/Invoke for the calls, `Volatile.Read`/`Write` on the ring), which together validate the exposed ring layout from both an unmanaged-FFI and a managed runtime. Shutdown lessons, learned the hard way: exit goes through `Application::Exit`; after `Start` returns, XAML COM references must be leaked rather than dropped (Rust TLS destructors run during process exit on Windows and releasing into the dead apartment is an access violation); `MddBootstrapShutdown` must be called while the process is healthy or `Microsoft.UI.Xaml.dll` crashes during `DLL_PROCESS_DETACH` in hosted processes; and `kaya_run` returns the exit code rather than exiting, because a library must not tear down its host process — hosts join their app thread before exiting (a daemon thread re-entering CPython during finalization crashes). WinUI requires an interactive desktop session, so SSH-driven runs go through a `schtasks /it` task, which matters for CI later. Win32 common controls remain the fallback but are no longer expected to be needed. WPF is possible later through hostfxr and a C# shim. |
| Linux    | GTK4 via gtk4-rs. Linux has no OS-native toolkit; GTK is the conventional stand-in. The milestone-0 skeleton runs the same architecture: `glib::idle_add` (g_idle_add) is the doorbell, the clicked signal feeds the occurrence sink, and the self-test drives the real signal path via `emit_clicked`. GTK teardown is orderly (none of WinUI's exit ceremony); the process exit code flows through `run_core` like the other backends. The backend contains no display-protocol-specific code; GTK4's GDK backends provide both X11 and Wayland, and validation exercises both — seven language suites (the usual four, plus C itself over the function floor, plus OCaml and Haskell on the direct ring) run under Xvfb (X11) and under headless Weston (Wayland) in a Debian container (tools/validate-linux.sh), unattended, since Linux has no interactive-session constraint. |
| Android  | Jetpack Compose (the SwiftUI sibling and the one Android backend). The platform-views-over-JNI backend (jni-rs) was validated alongside it from milestone 0 and is deleted; the JNI hosting shape below is unchanged. | Hosting is fully inverted — stricter than iOS, which at least requires a native executable: Zygote forks the process, ActivityThread owns main, and code enters at Activity.onCreate. So the milestone-0 packaging is a cdylib, not a bin: `kaya::android_main!(app)` exports the one JNI entry (`dev.kaya.Kaya.attach` — every Android app is the attach shape, and the shell spells it out), a minimal Kotlin Activity loads the library and calls `Kaya.attach(this)` on the UI thread, and the native side builds the scene, spawns the app thread, and returns the thread to the Looper. The same app logic file serves the bin platforms and this leg (examples/milestone2_android.rs is a two-line repackaging of milestone2.rs). The backend drives android.widget through JNI; its Kotlin half is three small classes (the entry declaration plus click-listener and Runnable shims) whose natives are registered with RegisterNatives rather than resolved by name, so the guest library's only name-based export is the entry. The doorbell is a posted no-data Runnable through runOnUiThread; kaya's env-based switches keep one spelling because the Activity maps KAYA_* intent extras to environment variables (`am start --ez KAYA_SELFTEST true` is this platform's `KAYA_SELFTEST=1 ./app`). Lessons that cost a debugging session each: never hold a lock across a JNI call that can dispatch back into native code (performClick reaches the click handler synchronously on the same thread — the handler uses its own clone of the occurrence sink, the same shape as a GTK signal closure); and exit through `_exit`, because libc exit runs atexit handlers that destroy HWUI's mutexes while its render threads still run. The Compose backend mirrors the SwiftUI one move for move — kaya signal to snapshot state (`mutableStateOf`, recomposition renders), occurrences out of onClick, commands through a blocking kaya_next_commands pump hopping to the UI thread — over the same presentation-side C API, reached through registered JNI natives (KayaPresent) since Kotlin cannot call C directly; it is the one Android backend, driving the unchanged Rust example as the guest, exactly like the SwiftUI leg on Apple. The JVM is the platform's direct-ring validation, and it surfaced two ART bugs the hard way: ART's byte-buffer-view VarHandle path truncates a direct buffer's native address to 32 bits in the interpreter (var_handle.cc casts the address through uint32_t), so the canonical VarHandle-over-NewDirectByteBuffer idiom faults on any real heap address; and ART's Unsafe (Object, long) volatile accessors are heap-field-only — a null base goes through a 32-bit MemberOffset and faults — so the OpenJDK null-base absolute-address idiom does not exist either. The formulation that works, and the one the Java guest ships: Unsafe absolute plain loads/stores plus explicit loadFence/storeFence (documented in libcore as the C11 atomic_thread_fence equivalents), bound once as MethodHandles (Unsafe is absent from the SDK stubs) and invoked through invokeExact so the per-record path stays free of boxing and reflection. When ART fixes the VarHandle truncation, the fence formulation can be swapped for acquire/release views (API 33+); the fence formulation itself only needs MethodHandles, API 26+. Either way the tier is the same as desktop Go and C#: direct reads on the data path, functions only for waiting and for commands. Validation runs headless in the emulator (tools/android/run-emulator.sh): SDK, NDK, emulator, JDK, and Gradle all come from nix (androidenv, license accepted declaratively), three suites — rust (Views), jvm (Java over the ring), compose — with verdicts read from logcat (stdout goes nowhere in an app process; android_logger + log-panics route Rust output there) and screenshots via screencap. Python and Go guests are deferred to the packaging milestone: interpreted and compiled guests on Android need binding bootstrap (briefcase, gomobile), which is its own subject. |

Raw Win32 common controls have no layout system at all (`WM_SIZE` and
manual pixel placement). That is an additional argument for WinUI, because
the layout strategy below assumes each backend has a real native layout
engine.

## Core object model

- The core owns a retained tree of widget records. Each record owns its
  native handle (`GtkWidget *`, a WinUI element; on the interpreter
  backends the native node lives interpreter-side and the record is its
  authority).
- Widgets are identified by slotmap-style generational ids (slot index plus
  generation), never by pointers. Generations exist to catch the ABA
  problem: a stale id whose slot was reused must be detectably dead rather
  than wrongly alive. They are not a leak-prevention mechanism; leaks are
  prevented by removal bookkeeping. Ids cross FFI easily, and foreign
  languages will hold stale handles, so with generational ids a stale
  handle is a catchable error instead of use-after-free undefined behavior
  in someone's runtime. Multi-language bindings are the strongest argument
  for generational ids. (As shipped, the generation half never became
  necessary: ids are guest-allocated monotone u64 counters, never
  reused, so ABA cannot arise and a stale id is simply absent from the
  registry — the same catchable-error property by a cheaper route. The
  generational scheme returns only if id reuse ever does.)
- Removing a widget must release its native handle and cascade to
  descendants, and this has to be reconciled with the fact that native
  toolkits destroy the children of a destroyed parent on their own. This
  bookkeeping, not the choice of arena, is where leak and double-free bugs
  live.
- All native-widget manipulation happens on the platform main thread, which
  the core owns. In Rust this is enforced at compile time with `!Send`
  handle types internally.

## API layers

The only true boundary is the ring protocol, and everything crossing it is
data. The C ABI is not the interface; it is how foreign languages reach the
rings. The published, stable contracts are the protocol itself and the
command vocabularies. Versioning follows Wayland's model of per-vocabulary
version negotiation: each vocabulary (widget set, layout, transforms, IME
contract, and so on) advertises a version, bindings bind at the minimum
they support, opcodes are additive-only and never repurposed, and an
unknown opcode fails at submission with an error record rather than a
silent no-op. (Negotiation is the at-release plan; pre-release, churn
is free and the shipped mechanism is simpler: everything regenerates
in lockstep from spec.rs, `kaya_spec_hash` asserts the lockstep at
attach, pin tables freeze the wire constants, opcodes are already
additive-only, and the one capability that exists — aux windows —
rides a `kaya_capabilities` bit, the seed of the eventual handshake.)

The boundary is two-tier, on io_uring's model. Functions are the portable
floor: any language calls them and never thinks about memory ordering.
Languages with real atomics (Go, JVM, C#) may instead consume the
occurrence ring directly: a setup call hands out the layout once (data
pointer, capacity, head and tail pointers, the io_sqring_offsets pattern),
the data path is lock-free loads and stores in the guest language, and a
blocking function covers only the empty-ring case, like io_uring_enter.
This tier exists because per-call FFI cost is not uniform: a C call is
nanoseconds from Python's perspective, but cgo is expensive enough that Go
libraries for io_uring reimplement the ring protocol rather than wrap
liburing. The ring control layout (head, tail, capacity, record header) is
therefore frozen ABI, small and io_uring-precedented; record vocabularies
stay versioned as before. Commands travel through functions in both tiers,
since a transaction commits as one call and the boundary cost never
multiplies per record.

Design principle: the public surface is the performance ceiling. No binding
should ever need to bypass the public API to build something faster. The
API is allowed to be verbose or awkward, because language bindings can
paper over ergonomics; they must never have to paper over performance. It
follows that the surface must be mechanism (a substrate frameworks compile
onto) rather than policy (a framework worldview that bindings would route
around).

### Internal widget core (not exposed over C)

The retained tree of generational-id widget records and its imperative
mutation layer are internal Rust. Writing to a bound signal is a property
set whose target was declared up front, so signals subsume public property
sets, and `When`, `For`, and instantiate subsume public structural edits.
A public retained C API would therefore be a second, redundant way to do
everything. Keeping it internal also means the mutation-sequencing
invariants (preserving focus across reorders, detaching before reattaching)
stay private code paths driven only by our own operators, and the surface
that has to be hardened shrinks from "any command sequence any binding
might emit" to "what our operators emit". The in-process Rust crate may
build typed layers against crate-internal APIs. Platform-specific escape
hatches ("hand me the raw `NSView`") are a native extension mechanism on
the main thread, outside the protocol. Exposing a retained C API later
would be a compatible addition, while retracting one is impossible, so it
starts closed.

### The reactive surface (the public API)

Signals, bindings, structural operators, templates, and one-shot commands
(`focus()`, `close()`, `scrollTo()`, instantiate and dispose of root
instances), all as protocol records.

**Signal graph.** Signals live in the core. The guest pays one ring record
per write; propagation runs at Rust speed on the fast side. This is what
fixes the cost structure for dynamic languages: there is no guest-side
dependency bookkeeping at all.

**Property bindings** connect a signal to a widget property.

**Structural operators.** `When` mounts and unmounts a template instance
from a boolean signal; `For` drives a container's children from a keyed
collection signal. `When` controls existence (instances are created and
destroyed, state included), while the `hidden` property controls space.
The name is `When` rather than `Show` or `If` for two reasons: "Show"
collides conceptually with `hidden` (Vue ships both `v-if` and `v-show`,
and which to use is a perennial question), and lowercase `if` cannot be
written in snake_case bindings, which breaks the rule that tutorials should
translate line for line between languages. `When` is the prop name Solid
uses and is idiomatic in every casing convention.

`For` contains the irreducible kernel of diffing: keyed reconciliation
scoped to collections, written once in the core, which is also where the
mutation-sequencing knowledge lives. Solid's operator set is evidence that
this pair is sufficient. Fine-grained reactivity never eliminated diffing;
it confined diffing to the one place where structure follows data.

Collections come in two flavors. Inline: the full keyed list is the signal
value, and `For` instantiates every child. Virtual: the signal value is a
manifest (total count plus key schema, which is also what answers
accessibility aggregate queries), and row data lives in the row window.
The native virtualized widget pulls row N; the core stamps the row template
and binds its slots to row-scoped signals backed by the window's data for
that key; the demand slot determines which rows are materialized. Platform
cell recycling maps to rebinding an existing template instance to a
different row's signals, an identity switch with no re-instantiation.

**Windows are a scene layer, not a widget kind.** A window has no parent
layout (the OS and the user position it), its lifecycle differs in kind
(close is a request — an occurrence with a fail-safe default, per the
decision vocabulary), and three of the five backends refuse the
identification at the type level (NSWindow is not an NSView, WinUI's
Window is not a UIElement, and on mobile the surface is the OS's to give,
as the Android attach shape demonstrates). GTK and Qt unified window and
widget and it fits only them; Flutter assumed one implicit surface and
spent years retrofitting desktop multi-window; SwiftUI's scene layer
(WindowGroup above View) is the modern answer and the one kaya adopts:
windows get their own id space and their own small vocabulary —
create_window, mount targets, SetTitle/Present/Close commands,
CloseRequested/Resized occurrences — designed in full when multi-window
arrives (it also carries dialogs and modality). Until then the core
provides one implicit window, reachable as mount target 0: a default,
never an assumption. Window-scoped properties (title, size) never become
widget properties in the interim.

`When` is implemented as the degenerate `For` over a collection of zero or
one items. The operator set is a complete basis: a conditional and a map
over structure. Additions expected later under the escalation policy:
`Portal` (a subtree rendered as a platform overlay or popup, which menus
and tooltips will probably force during the first backend) and `Switch` as
sugar over chained `When`s.

**Templates are inert and authored by functions.** The sole authoring model
is a component function: it takes slot proxies as parameters, returns a
node description, and runs once, at record time, not per state change.
This is Solid's model. `When` and `For` take these functions; a reusable
component is a function bound to a name; a standalone "template object"
exists only as the internal recorded artifact and the serialized form. The
slot schema is the function signature: parameter names and types, validated
at record time. A declared schema also lets the row window store rows in a
fixed layout in the arena rather than in generic maps. Nodes may carry a
ref marker, in which case instantiation reports a per-instance handle for
one-shot commands. There are no widget mirror reads: widget-owned state
(an entry's text) reaches the app as occurrences it folds into its own
model, so the model stays the single source and nothing eventual sits on
a read path.

There is one trap: closures invite the Flutter intuition that the function
re-runs on every state change. As a guardrail, the recorder flags any
model read (a collection iterated, a draft consulted) inside a recording
scope with an error telling the author to bind a signal or take a slot as
a parameter.

The encoding at the C ABI is a builder API (`begin_node`, `set_prop`,
`bind_slot`, `end_node`). Templates are small and built rarely, so the
encoding optimizes for binding simplicity. The builder records into the
canonical serialized form, and submitting a prebuilt buffer is equally
legal; that is the path server-driven UI and tooling use. (As shipped,
the prebuilt-buffer path became the only path: every binding's
generated layer 1 writes the canonical records directly and the
builder functions were never needed — the C floor guests spell the
records out by hand, which is the floor's documentation role.) Node properties
are constants or slot references. Templates nest, so `When`/`For` branches
can be anonymous fragments.

**Bound properties are constants or signal references, nothing else.**
Display values such as strings and colors are derived app-side in the guest
language, for two reasons. The app is already awake when it mutates its own
state, so deriving there adds no round trip. And localization and
pluralization have to live in the guest's i18n tooling regardless. All
state at rest is core-owned signals; the guest is the transition function;
bare guest values exist only in flight between being computed and being
written.

A reserved escalation path exists for the one real customer: bindings whose
source is fast-side state (a label showing a slider's live percentage,
parallax, a character counter against an uncontrolled field). It is a
closed, non-composable set of binding transforms: `linear` (a·x+b),
`select`, and `format`, admitted individually when a real artifact
demonstrates the need. They are flat descriptors with no nesting, so there
is no grammar and nothing that can grow into a language, which was the fate
of XSLT, JSP EL, and Angular expressions. v1 ships none of them; identity
bindings only. Server-driven UI and visual tooling are the one future force
that would legitimately reopen core-side expressions, since there the "app"
is a network away or absent, and every industrial server-driven UI system
has grown an expression system. Per-vocabulary versioning makes that an
additive, consumer-scoped decision for later.

**Core-to-core bindings.** Signals sourced from core state (scroll offset
driving a transform, hover driving a highlight) propagate entirely on the
fast side and keep updating at full rate during an app stall.

### Guest frameworks

Guest frameworks compile onto the reactive surface rather than around it.
A Svelte-style compiler binds a signal per dynamic property at build time
and emits signal writes; a Solid-style runtime does the same at runtime;
Xilem-style typed Rust views (`build`/`rebuild`, `FnMut(&mut State)`
handlers) sit on crate-internal APIs. None of them needs its own
reconciler. Whole-tree diffing (React-style UI as a function of state) can
be built as an optional library on top of templates and signals, but it is
not the core's declarative primitive.

Python's sugar is JAX-style tracing: `for t in todos:` traces to `For` via
`__iter__`, and comparisons overload into binding-maintained derived
signals. `if` on a signal raises an error pointing to `kaya.when`, because
Python cannot overload statement branching; this is the same wall that gave
JAX `lax.cond` and pandas its "truth value is ambiguous" error.

Per-language sugar is thin and idiomatic per binding. Hiding the core API's
verbosity is the binding's job.

## Binding conventions

**Window attributes ride the window construct.** Every binding has
one construct for a window's attributes — a prop chain (`tx.window(0)
.title(...)`), a named-argument call (`tx.Window(title: ...)`), a
labeled function, a config list, or a scope, per the language's idiom
— and the PRIMARY window's construct accepts exactly the
created-window construct's attribute set (title, width/height,
veto_close, sections_presentation, the close handlers). The one
asymmetry left is semantic: the primary has no creation or
destruction moment, because the process owns it. No window attribute
lives as a loose function outside the construct — there are no
shortcuts (`window_title` retired 2026-07-22; ratified). A
props-only primary construct is legal and mounts nothing — the
sections shape, where the switcher IS the window content.

**Line separators.** Guest-visible text uses LF (`\n`) as its line
separator on every platform — occurrence payloads, harness reads, and
scene output strings are compared byte-for-byte across all languages,
so a backend's private convention must never escape. WinUI's TextBox
stores every break as a bare CR (its Rich Edit heritage); GTK's views
store pasted CR/CRLF verbatim; SwiftUI and Compose own their model
text outright. Each backend therefore normalizes at its natural
boundary: WinUI and GTK wherever widget text escapes toward the guest,
SwiftUI and Compose wherever text is written into the model. The
steps grammar's `\r` escape exists to prove this — the textarea scene
drives CR-bearing text through the user path and asserts LF comes
back, on every platform.

**String comparison.** String observations compare Unicode scalar
sequences — implemented as code-unit equality in each comparator's
native encoding, with both operands of any one comparison always in
the same encoding. The wire is well-formed UTF-8, so every
implementation computes the same predicate. No normalization, no
canonical equivalence, no locale collation, anywhere: Swift is the
one language whose default `==` adds canonical equivalence, so its
interpreter compares `utf8` views (kayaBytesEqual). Ill-formed
platform text (a lone surrogate in a UTF-16 language) cannot reach a
comparison — the FFI boundary repairs it before it exists to kaya.

A cross-language style guide is a versioned deliverable due before v1. The
rules that keep bindings mutually recognizable have to be written down
somewhere; Wayland ships protocol conventions for the same reason. Settled
rules so far:

- **Only the user's act emits; a property write is configuration.**
  Interactive widgets are uncontrolled: the widget owns its state and
  reports each USER change as an occurrence. A programmatic property
  write (a const set at build, a signal write fanning out later)
  moves the control but never echoes an occurrence, on every backend
  — without that rule, a handler that writes back a different value
  than it received ping-pongs through the native change event
  forever, and only on the platforms whose toolkits raise the event
  for programmatic writes (GTK, WinUI — both carry an apply-side
  quiet guard for exactly this). COMMANDS are the deliberate
  exception: a command acts like the user (clear empties the field
  through the entry's own text_changed("") path — the entry scene's
  second-add round depends on that echo), so it emits on every
  platform. The harness stage's direct writes are the user path by
  definition. The gallery scene's quarter button is the standing
  negative test: a programmatic write with the assertion that the
  fold did NOT run (ratified 2026-07-22).

- Construction-prop spellings, ratified per language family after a
  survey of each ecosystem's dominant GUI idiom (2026-07-20; grow and
  spacing are the first two props riding them):
  **chains** where the ecosystem builds by fluent methods — Rust
  (`tx.row(|tx| ...).grow(2.0).spacing(12.0)`, an ephemeral proxy
  reborrowing the transaction: where Go and Java police a chain
  outside its build with a runtime panic, Rust's borrow checker
  rejects it at compile time, and `.id()` ends the chain when a
  handle must outlive it), Go (`tx.Column(...).Spacing(12)`), Java
  (`tx.column(() -> {...}).spacing(12.0)`);
  **named/labeled arguments** where the language has them — Swift
  (`row(grow: 2, spacing: 12)`), Python (`row(grow=2, spacing=12)`),
  C# (`Row(..., spacing: 12)`), OCaml
  (`row ~grow:2.0 ~spacing:12.0 [ ... ] ()`, the lablgtk idiom — every
  constructor takes `?grow`, containers add `?spacing`, and the
  trailing `()` is the realization marker: apply it to create the
  widget where you stand, omit it and the partial application is a
  pure `unit -> widget` thunk, the child form containers take in
  lists. The taste the scenes settled into: a creator with any
  argument applied sits bare in a child list —
  `button ~text:"Add" ~on_click:on_add` — because applying a labeled
  argument commits the optionals and leaves exactly `unit -> widget`,
  so the thunking is invisible in the common case; a creator with NO
  argument applied is expectation-dependent — OCaml discards leading
  optionals only where the expected type is already known, so a bare
  `spacer` typechecks inline in a container's list literal but the
  same list factored into a `let` fails ("the first argument is
  labeled ?grow, but an unlabeled argument was expected") — so the
  scenes spell it `spacer ~grow:1.0`: apply an argument or eta-wrap,
  the expectation-independent forms (see docs/traps.md); and a
  widget realized early because handlers need its
  handle (`let field = entry ~on_change:h ()`, then `clear field` /
  `focus field` in the add handler) re-enters a child list through
  `w`, the inert-thunk wrapper (`let w wid () = wid`) — the container
  merely attaches it. For/When ride the same convention: `each c
  body` is the child form for a body that keeps no handles — the
  common case once handlers co-located at their constructors — while
  `for_each c body ()` forces in place when the body's result
  carries handles out (a per-copy collection, a template button),
  the live For slotting back in via `w`; and a template body
  realizes its root for effect even when nothing keeps the handle
  (`let _ = column [ ... ] () in`). The Tpl submodule repeats the
  whole convention over `unit -> node` thunks with its own `w`.
  Scenes run direct-style over an ambient transaction, no binding
  operators — the let*/decl reader is deleted, and the eager-children
  first cut was rejected because OCaml evaluates list literals
  right-to-left: thunked lists only allocate closures, and the
  container realizes them itself, left to right, `List.iter`'s
  SPECIFIED order — so document order is structural, never
  evaluation-order trivia; see docs/traps.md);
  **attr lists over a closed GADT** in Haskell
  (`row [Grow 2, Spacing 12] [ ... ]`, `labelBound probe [Grow 1]` —
  one name for both arities via lucid's Term idiom:
  equality-constrained result-directed instances, MPTC +
  FlexibleInstances + GADTs + DataKinds. `Attr (c :: WClass)` indexes
  props by widget class, so container-only props on a leaf are type
  errors before they are scene errors anywhere; the closed GADT means
  the attr vocabulary IS kaya's (no forged config actions), and
  applyAttr's total match makes a prop without its interpreter arm a
  compile failure — the type-level twin of the capi completeness
  tripwire). Dynamic setters (`set_grow`,
  `SetSpacing`, ...) remain the uniform second path in all eight.
  The spelling varies by idiom; the observable semantics never do.
- A canonical method vocabulary for derived signals: `eq`, `ne`, `lt`,
  `fmt`, and so on, method-shaped in every language (`count.eq(0)`,
  `count.Eq(0)`). Documentation leads with the methods so that tutorials
  translate line for line. Operator overloading (Python's `count == 0`) is
  optional per-language sugar, and its sharp edges get documented:
  hijacking `__eq__` breaks naive hashing and identity comparison, the
  familiar SQLAlchemy and pandas trade-off. Python, C#, and Swift wear
  the operator clothes today (signals keep identity hashing; in C#,
  reference checks use `is null`, which bypasses user operators); Java
  and Go have no operator overloading, and Haskell's `(==)` pins its
  return type to Bool — its idiomatic form would be dotted operators,
  the esqueleto precedent, when a scene wants them. Statement
  iteration (`for t in todos:` tracing to a For) needs
  statement-shaped construction: Python has it via with-block
  containers, Swift via result-builder containers (whose children
  collect through an ambient frame precisely so a for-in row trace can
  plant its For between siblings), and Haskell's do-notation is past
  the wall by construction. Go, C#, and Java joined via container
  auto-parenting: containers take their body as a closure (func() /
  Action / Runnable) and parent everything declared inside it through
  an ambient stack (0 the template-root sentinel, so template bodies
  still root themselves and a cross-zone add_child stays structurally
  impossible; a For/When parents into the enclosing scope with its
  add_child deferred past template_end; parents are created before
  their bodies run). Creation order is observable (kind#N harness
  names) and derivable, never per-language trivia: statement-shaped
  construction is parent-first (Python, Swift, Go, C#, Java, and Rust
  — whose containers are the egui shape, `tx.column(|tx| { … })`, the
  &mut reborrow standing in for the ambient statics the GC languages
  need), OCaml is parent-first too (its child lists hold PARTIALLY
  APPLIED creators — every creator ends in `()`, and omitting that
  unit leaves a pure `unit -> widget` thunk the container realizes
  left to right after creating itself; eager child lists were
  rejected because OCaml evaluates list literals right-to-left, see
  docs/traps.md), and expression trees are children-first (Haskell —
  arguments evaluate before the call). The shared .steps scripts may
  therefore target containers only through the blessed column#0 (the
  For container the root-is-a-row convention keeps unique) —
  tools/check-steps.sh gates it. That put their iteration mechanisms in reach: Go's
  range-over-func (post-break control makes the close structural —
  the strongest form), C#'s duck-typed foreach (no IEnumerable, so
  LINQ never appears on a collection at record time; the enumerator's
  Dispose closes on break), and Java's one-shot Iterable (break
  caught at submit). Rust's `for mut row in todos.rows(&mut tx)` is
  the strongest of all: the single-yield iterator moves the &mut Tx
  into the row, whose Drop closes the template — RAII, so the close is
  break- AND panic-safe, and while the row lives the transaction is
  statically unreachable except through it (the template-zone
  discipline enforced by the borrow checker; a unit test pins the
  break case). The varargs and slice container forms are gone — one
  construction style per language. Rust's comparison operators stay
  method-shaped when needed: PartialEq pins `==` to bool, the same
  wall as Haskell's Eq. Rust's handler model is the Msg tier — the
  occurrence-side twin of the sum eliminators: the guest declares its
  event vocabulary as an enum, registers each widget's mapping beside
  the widget (an enum tuple constructor is already the mapper:
  `msgs.on_change(field, Msg::Draft)`), and folds one exhaustive
  match. The registry converts runtime identity into the enum's tag —
  match dispatches on tags, and identifier patterns bind rather than
  compare, so guard-free dispatch requires reifying "which widget"
  into variants; the same reasoning that rejected sequential case
  calls for templates rejects per-widget closure registration here.
  Two compiler checks fall out that no other binding has: match
  totality (every declared event handled) and dead_code (a variant no
  widget produces is "never constructed"). The raw occurrence loop
  stays the documented floor (the entry and milestone2 scenes), and
  the Xilem-style co-located-closure tier is expressible on top of
  Messages by instantiating M as a boxed command — the reverse
  construction does not exist, which is why Messages is the
  primitive. Derived signals are maintained
  by the binding, recomputed at write time and batched into the same
  transaction; the core never knows about them. A derived signal's source
  can also be a collection — `todos.derive(|items| ...)` — recomputed
  after every mutation of the live-zone instance from the binding's own
  model copy (never a core read): the items-left label updates itself,
  and no handler carries a "remember to also write the status" line.
  The compute is pure presentation, entries in, one value out; deriveds
  hang off root handles, since a stamped copy's instance has no
  live-zone signal to feed.
- Values in handlers, signals in templates. Collection mirrors read a
  binding-maintained snapshot of what the guest wrote, which is correct
  in transition code and a frozen-branch bug in template position;
  statically typed bindings enforce the template half at compile time,
  since `When` takes a `Signal[bool]` and not a `bool`, and dynamic
  bindings check at record time. Signals expose no read at all —
  collections are the model, signals are the render pipe, and reading
  back a written signal invites round-tripping app state through the
  UI. Widget-owned state never grows a
  read: an entry's text arrives as change occurrences the app folds
  into its own model (the uncontrolled widget stays the authority;
  the app keeps its draft), so nothing eventual ever sits on a read
  path and the model stays the single source.
- Handlers receive their transaction, explicitly as in Go
  (`func(tx *Tx)`) or ambiently as in Python. The surface varies per
  language; the semantics are fixed by the protocol's rule that a handler
  is a transaction.
- Components are functions taking slot proxies and returning node
  descriptions, run once to record. Reuse is function reuse.
- Pick one property-configuration style per language (functional options
  or config structs; Go UI DSLs have gone both ways) and do not mix them
  within a binding.
- One constructor name per widget; the argument's type picks the source.
  A property binds to an *addressable source* — the protocol's closed
  union of constant, signal, and (in template position) element field.
  That union is a protocol fact, not binding sugar, so the binding
  surfaces it as one name rather than a name per source:
  `label("hi")`, `label(count_text)`, `label(Todo::title())` are the
  same constructor, and a name like `label_field` would wrongly imply
  field binding is a different operation instead of a different address.
  Each language reaches for its own mechanism — trait-bounded
  conversions in Rust (`impl Into<TplSource<K>>`), overloads in C#,
  Java, and Swift, a union type-set constraint on a generic method in
  Go, a type class per prop type in Haskell, labelled optional
  arguments in OCaml — and the mechanism stays compile-checked: a bool
  source on a text prop is a type error everywhere, matching the
  scene's own validation. The union does not grow a guest-variable arm;
  by the no-reads doctrine a plain guest value is a constant at record
  time, and anything live must be a signal or a field.
- A patch is recorded writes, never a diff. The multi-field mutation
  surface (`todos.patch(tx, key).done(true).title("x")`) lowers each
  setter call to one update_field — the guest's calls are already the
  exact list of changed fields, so no binding ever clones the current
  record and compares (a diff pays a copy plus per-field comparisons —
  Mirror walks in Swift, deep string clones in Rust — to infer what the
  call sites stated). Where the binding owns code generation the
  setters are per-field and named (the derive's builder in Rust, the
  ppx's optional labelled arguments in OCaml — Python's kwargs patch
  with static types); elsewhere a set-chain over the selector vocabulary
  (`.Set(x => x.Done, true)`, `.set(\.done, checked)`,
  `patch todos key [set (field @"done" @Todo) checked]`). Selector
  resolution is cached per field — reflection walks, key-path probes,
  and lambda probes run once per declaration site, never per event —
  and update_field remains the explicit single-write floor.
- Reordering is a mutation, not widget surgery: every binding surfaces
  collection_move as four verbs on the collection handle —
  `move_before(key, anchor)` and `move_to_end(key)` mirror the wire
  op's two forms, and `move_to_front(key)` / `move_after(key, anchor)`
  are sugar the binding lowers to the same op through its own model
  (the current first key; the anchor's successor, or the end when the
  anchor is last). The DOM shipped `insertBefore`-only and every layer
  above it grew `after()` — the binding tier is where that belongs,
  because the model answers the successor query without a protocol or
  backend surface change. The model's copy reorders in the same call,
  so `items()` reads the new order back and first/last queries stay
  honest across moves. Semantics are the scene's, enforced at the call
  site (the earliest check in the system): a missing key or anchor
  fails loudly — never a fallback — and an order-preserving move
  (before itself, after itself, already in place) is a no-op that
  ships nothing. Handlers ask the model which key is first or last —
  they never count widgets — and the wire delta stays keys-only.
- One-shot commands are the third arm of the ownership rule, and the
  rule decides the mechanism everywhere: app-owned state travels as
  props and deltas (retained, replayable); widget-owned state comes
  back as occurrences the app folds; and the app's momentary crossings
  into state it does not own — clear an entry, focus a widget, later
  scrollTo — are commands: one `widget_command` record riding the
  ordinary transaction, so the insert and the clear beside it commit
  atomically or not at all. A command is fire-and-forget wire data —
  no state at rest, nothing recorded, nothing replayed on instance
  rebuild — and the widget stays authoritative, answering through its
  normal occurrence path (a clear arrives back as text_changed with
  empty text, through the same delegate a keystroke uses; backends
  whose programmatic mutation is silent re-fire the change path
  explicitly). The vocabulary is one enum row per verb, closed under
  the same admission policy as the binding transforms: each verb
  admitted by a real artifact (clear and focus by the entry form;
  scrollTo waits for a long list), never speculatively — and never a
  general call-a-method escape hatch, which is the door to the
  imperative API this design exists to avoid. Addressing splits the
  failure modes: a live-zone target can only vanish by the guest's own
  hand, so a command on a missing or wrong-kinded live widget fails
  loudly at the call site like any misuse; instance-addressed commands
  (when scrollTo brings key-path targets) get the silent no-op
  instead, because a stamped copy legitimately vanishes under rebuild
  and racing a teardown is not a bug (the Elm precedent: focus on a
  vanished node is a defined outcome, not an error). Bindings surface
  commands on the live widget handle or transaction (`entry.clear()`,
  `tx.focus(field)`), live zone only — a template node has no command
  surface, structurally, since a blueprint has nothing to clear.
- The record-time mirror-read guard: inside a template scope (a For
  body, a When body, a row trace) every binding-mediated model read —
  items, count, get, iteration — fails loudly, in every binding. The
  template records once and replays; a read would bake today's value
  into the blueprint as silently dead data, the Flutter-intuition trap
  (Solid, this model's source, ships a lint for the identical seam).
  Writes in a template were always loud (the scene rejects them at
  declaration); reads never reach the scene, so the binding is the
  only place — and the earliest — to catch them. The static-wall
  languages get the guard from their types: Rust's `for_each` holds
  the transaction exclusively for the body's extent (a template read
  is a borrow error, pinned by compile_fail doc-tests), and Haskell's
  reads are Build-typed where template bodies are Tpl-typed with no
  lift between them (pinned by a must-not-compile fixture). The
  closure languages — where the body can lexically capture the outer
  transaction and no type can stop it — carry a runtime template-depth
  counter, armed by For, When, and the trace alike (the For-only
  openFors stack is not the guard's state: When pushes nothing there),
  and reset on transaction abort so a surviving app never inherits a
  poisoned zone. `derive` remains the sanctioned read — it reads in
  order to register recomputation, and is the fix the guard's error
  names, along with binding a signal or taking the element's field.
  The honest residue: only binding-mediated reads are catchable — a
  plain host variable in a template is an indistinguishable constant
  in every language and framework, and stays governed by the
  convention (values in handlers, signals in templates). Python's
  `window()` block additionally arms the guard for its whole extent:
  that construct is declaration-only sugar whose contract is
  recording; bindings without the construct have nothing to diverge
  from.
- One abort semantics in every binding, idiom deciding only the
  spelling: a handler abort at the transaction boundary restores the
  binding's model and signal mirrors from a journal (or by purity,
  where the transaction is pure state), ships nothing — commands and
  derived-signal registrations dying with the record buffer — and
  propagates; the binding-owned dispatch loop then catches, logs, and
  goes on to the next occurrence, so one buggy handler never takes the
  app down. What a language cannot catch (Swift's traps, VM-fatal
  errors, an unrecovered Go runtime abort) stays process-fatal
  everywhere, uniformly. Rust is the one structural exception: its
  binding owns no dispatch loop (the occurrence match is guest
  surface), so the tx boundary's Drop-rollback is where its uniformity
  lives and loop survival is the guest's own choice. Every binding
  carries the same negative test — abort mid-handler: mirror restored,
  nothing shipped, next dispatch works (tools/check-abort.sh).

## Layout

Decision: ride the platform's native layout engines. Nearly every shipped
cross-platform-native framework (React Native with Yoga, Xamarin.Forms,
MAUI, wxWidgets, SWT) did its own layout math and absolutely positioned
native views. That record reflects a goal kaya does not have:
pixel-consistent layout across platforms. Given that each platform should
flow like itself, mapping a deliberately small layout vocabulary onto the
native engines is the coherent choice.

- Vocabulary: horizontal/vertical stack (spacing, alignment, grow
  weights), grid, and spacer. These map to `NSStackView`/`NSGridView`,
  XAML `StackPanel`/`Grid`, `GtkBox`/`GtkGrid`, and
  `LinearLayout`/`GridLayout`.
- An escape hatch exists for per-platform layout attributes that don't
  generalize.

Normalize semantics but not metrics: API constructs must mean the same
thing everywhere, while the numbers the platforms produce (control sizes,
spacing, wrap points, baselines) stay platform-flavored. Two backends
render the same tree differently and both look right — that is the
system working, the way one document takes different stylesheets.

A corollary for implementers, learned the hard way while landing `grow`:
**take over a native container's layout only where the toolkit cannot
express the semantics, and only in the containers that ask for it.** The
first cut installed a custom layout on *every* GtkBox and *every* SwiftUI
stack, which routed scenes that never used a weight through kaya's
arithmetic and discarded whatever those toolkits do idiomatically —
pixel-consistency by the back door, the very goal this section rejects.
Both are now lazy: GtkBox keeps GTK's layout until a child in that box
actually grows, and VStack/HStack stay VStack/HStack until one of their
children does.

The known normalization worklist:

- `hidden` means collapsed (occupies no space) everywhere. GTK collapses,
  AppKit reserves space, XAML distinguishes Collapsed from Hidden.
- The mounted root fills its window. Nothing does this "by
  construction" except AppKit (the root IS the contentView) — every
  other backend needed the normalization stated explicitly, and two of
  them shipped hugging before a recording caught it: GTK (a child obeys
  its own align and sat in a corner), then UIKit (pinned top+leading to
  dodge distribution=.fill's balloon; the fix pins all four safe-area
  edges and hands the balloon to per-container trailing fillers, since
  UIStackView has no gravity distribution), then Compose (a Column
  wraps its width even when weights fill its height; the root takes
  fillMaxSize). A hugging root leaves no free space anywhere in the
  tree, so every grow weight silently divides nothing — and the share
  verb cannot see it, because shares are percentages of the children's
  sum, which is total-invariant. `expect_root_fills` in the grow scene
  is the gate; the class does not get a fourth instance.
- Spacing normalized to one default and one prop. Settled: 8 units
  between adjacent children on the main axis unless the container's
  `spacing` prop (F64, DIP, finite non-negative — nonsense dies at the
  root like grow's) says otherwise; no leading or trailing gap either
  way. GTK and WinUI carry native per-container spacing (Box spacing,
  Grid Row/ColumnSpacing); SwiftUI and Compose thread the node's value
  into their stacks and flex layouts. `expect_fills` gates the prop
  (children + gaps must span the content box); shares are gap-blind by
  design.
- A normalized root inset. Settled: every backend applies 16 units
  INSIDE the mounted root — AppKit stack edge insets, GTK CSS padding
  on the `.kaya-root` class, UIKit layout margins, WinUI
  `Grid.Padding`, Android `setPadding` (density-scaled: it takes
  pixels), SwiftUI `.padding(16)` wrapping the offer reader, Compose
  `.padding(16.dp)` before the offer reader. Inside is load-bearing:
  padding sits within the root's own extent, so the root still fills
  its offered area and `expect_root_fills` stays strict — a margin
  outside the root would shrink it and turn the inset into a
  root-fills waiver. The desktop window default is likewise one
  number, 540×330 — SwiftUI's existing default, adopted by AppKit,
  GTK, and WinUI in the same slice, sized so the grow scene's
  smallest track stays ~63pt, clear of GTK's 34pt control minimum.
- Alignment normalized to one container-level enum prop (ratified
  2026-07-20). `align` sets where children sit on the container's
  CROSS axis: `start` (the default — today's leading/top), `center`,
  `end`, `stretch` (child breadth = content breadth), and `baseline`
  (rows only: first text baselines coincide; children without a text
  baseline align by their bottom edge, the CSS replaced-element rule;
  a column baseline is rejected at the root, the spacing-on-a-label
  class). Deliberately the intersection vocabulary — container-level
  like SwiftUI's `VStack(alignment:)` and Flutter's
  `crossAxisAlignment`; a per-child `align_self` override and
  main-axis distribution (`justify`) are deferred until something
  knocks. The control-in-track ruling that makes align compose: a
  child's BOX fills its main-axis grow track (flex-item semantics,
  CSS/Flutter; GTK and WinUI already do this natively — the
  interpreters' cells are normalized to match), and `align` then
  governs the cross axis of that box uniformly. First enum-valued
  prop: `align` rides the wire as I64 with spec-enum constants
  (`ALIGN_START`..`ALIGN_BASELINE`) generated into every wire file;
  bindings expose each language's native enum through the ratified
  prop spellings. Gate: `expect_aligned <container> "<mode>"` — the
  Stage classifies child cross-placement from geometry (starts,
  centers, ends, or breadths coincide, ±2) and baseline mode asserts
  the text children's baselines agree via each toolkit's real query
  (WinUI TextBlock.BaselineOffset walks, Compose alignment lines,
  SwiftUI baseline dimensions) — except GTK, where per-child
  allocated baselines are not comparable across widget kinds, so the
  observation is PARTICIPATION (baselines allocated only under
  baseline mode; agreement is GTK's own, the root_fills precedent of
  per-platform notions). The scene asserts center and baseline —
  the two modes whose separability it constructs (a tall no-baseline
  image whose bottom sits on the baseline); start rides every other
  scene's geometry, and end/stretch have live classification arms
  with the recordings as their visual record until a scene earns
  them.
- A dressed control floor (ratified 2026-07-21). Every control the
  vocabulary ships renders as a credible native control on every
  backend with zero styling calls — there is no styling API to call.
  Dress is backend normalization, exactly like spacing and the root
  inset: fixes live in the backends, the protocol does not move.
  Per-platform chrome differences are the Zen Garden point (one scene,
  five native skins), so "dressed" is judged per platform: a control
  is dressed when a native user would read it as a real control, not
  as unstyled text or invisible chrome. The two failures the survey
  found: iOS's automatic button style (borderless blue text — the
  bordered style supplies the chrome) and, deeper, macOS buttons
  truncating their own captions under non-Apple hosts — see "The
  button that measured borderless" in Case analyses; the fix is an
  honest AppKit bridge, not styling. Dress must not change layout
  semantics: the same geometry gates (fills, shares, aligned,
  root-fills) re-prove after any dress change, and the recordings
  stay the judge of the chrome itself. A styling API stays out of
  scope for v1; the binding style guide documents flavor, it does not
  program it.
- A defined overflow policy. Platforms variously clip silently, refuse to
  shrink windows, or break constraints by priority.
- Grow distribution normalized to explicit weights. Settled when `grow`
  landed: weight 0 is natural size, and the positive-weight children
  divide the *leftover* main-axis space in proportion to their weights,
  their own natural sizes not entering the division — the contract CSS
  states as `flex-basis: 0`, and the one Compose `Modifier.weight`, XAML
  star sizing, and Android `layout_weight` (at a 0 main-axis size)
  already implement. Those three get it for free — on WinUI a
  `Grid` whose tracks are `Auto` for the natural-size children and
  `Star(w)` for the growers *is* the contract, which is why the
  row/column containers are Grids and not StackPanels (a StackPanel has
  no per-child weight at all). The other FOUR toolkits have no weight
  concept whatsoever and must construct it: AppKit and UIKit express the
  ratios as pairwise Auto Layout constraints between growers, GTK4 needs
  a custom `GtkLayoutManager`, and SwiftUI a custom `Layout`. Each of
  those four offers a near-miss that looks like the answer and is not —
  content-hugging priority on the Apple stacks and `layoutPriority` on
  SwiftUI are *ordinal* (who stretches first, not by how much), while
  GTK's `hexpand` and SwiftUI's `.frame(maxWidth: .infinity)` are
  *boolean* (split the remainder equally). Reaching for any of them
  yields a 1:3 that renders differently on every platform. (SwiftUI's
  Slider is additionally the lone control with no natural main-axis
  size at all — unconstrained it swallows whatever a stack offers — so
  the interpreter stands in 200pt as its weight-0 natural width and
  lifts the cap for growers, whose extent is the track KayaFlex
  assigned.)
- Height-for-width (wrapping labels in stacks) gets dedicated conformance
  tests from day one; it is the most notorious cross-engine divergence.
- One logical coordinate unit, with defined fractional-scale rounding.
- Leading/trailing rather than left/right in the API; platform RTL
  mirroring does the rest.
- macOS alignment rects (frame versus visual bounds) are handled in the
  backend.

Process: a conformance gallery app with canonical scenes per layout
scenario, run on every backend and compared side by side. Divergences get
sorted into "semantics: normalize in the backend" or "metrics: document as
platform flavor". The gallery doubles as the permanent regression suite.

## Presentation contexts

Ratified 2026-07-21, resolving open question #4. A scene root is pure
content — widgets, ids, props, events, the whole existing grammar —
and it is deliberately ignorant of what hosts it. The host is one of a
small taxonomy of PRESENTATION CONTEXTS. This is the position view
controllers occupy natively (a UIViewController does not know whether
it is pushed, presented, or a window's root; likewise a fragment or
composable on Android, an NSViewController on macOS): content that
containers host. One grammar inside a context — the tree never forks
by host — and per-context lifecycle grammar outside:

- **Windows** are PARALLEL: top-level surfaces that coexist, with the
  user switching between them. Their lifecycle verb is CLOSE, and it
  is app-vetoable (the CloseRequested request/confirm class settled in
  Case analyses; winit, Tauri, and Electron converged on the shape).
- **Modal presentations** are TRANSIENT: parent-bound, blocking their
  parent, producing a result. Their lifecycle verb is DISMISS, and the
  cancel path is one uniform semantic slot with per-platform spelling:
  Esc on the desktops, the back gesture on Android, Cancel/swipe on
  iOS.
- **Navigation entries** are SERIAL: a stack of roots inside one
  surface, exactly one visible. Their lifecycle verb is POP, and on
  the mobile platforms it is user-sovereign (Android's predictive back
  exists precisely to stop apps stalling it).

The three grammars are never mixed. A window is not a push; a dialog
is not a window; back never touches windows. Android's own history is
the strongest witness: classic Android conflated surface with
navigation frame (multi-screen apps were multi-activity apps riding
the task back stack), and the platform spent a decade migrating to the
single-activity architecture — one surface, a NavController stack of
destinations inside it. The ecosystem un-conflated the concepts; the
vocabulary starts un-conflated.

### Windows (phase 4)

What "window" means diverges at the root: on the desktops the app
COMMANDS surfaces (NSWindow, AppWindow, GtkWindow — create, title,
size, close), while on mobile the app at most REQUESTS them (the
user-facing unit on iOS is the UIWindowScene, which an app can ask to
activate but never size or place; Android's analog is the Activity,
with multi-window entirely system-managed). Even among desktops the
command model has a hole: a Wayland client cannot position its own
windows — the compositor owns placement. SwiftUI's scene architecture
is the prior art for bridging this: WindowGroup is a DECLARATION of
what may exist, and each platform materializes it (N windows on
macOS, scenes on iPadOS, exactly one on iPhone). kaya adopts the
declaration/request principle:

- **The primary surface exists everywhere and already does** — it is
  what `kaya::run` mounts today; milestone 1 reserved mount target 0
  for it. Phase 4 makes it explicit and gives it props. `title` is
  uniform, with materialization documented as platform flavor: the
  title bar on the desktops, UIScene.title on iOS (the app switcher
  and Stage Manager show it), the Activity task label on Android.
  Initial size is an ADVISORY REQUEST on every platform — not a
  mobile carve-out but the truth everywhere, since a tiling window
  manager on Linux overrides it too; defining it as a request keeps
  one semantics instead of "guaranteed on desktop, ignored on
  mobile". **Position is not in the vocabulary.** Wayland alone
  kills it, and mobile buries it; a verb that two platforms must
  silently drop is not a verb.
- **Auxiliary windows are a capability, not a universal.** Desktop
  hosts have them; phone hosts do not, and reinterpreting "create
  window" as a navigation push would silently produce a different
  application (parallel surfaces became serial screens — the
  uniform-semantics fork the invariants forbid). The host advertises
  `aux_windows` in the handshake (the spec-hash pump's table has the
  slot), and creating an auxiliary window on a non-capable host is a
  deterministic scene error — the column-baseline precedent: the
  carve-out itself stated uniformly, failing loudly at the root.
- **Close** inherits the settled veto class unchanged: the core
  defaults to staying open, emits CloseRequested, and the app later
  issues close() if it agrees. The handlers bind to the WINDOW at its
  declaration (2026-07-22, completing the handlers-scope-to-their-
  creator rule after alerts and navigation): on_close_requested and
  on_closed ride create_window per language idiom — Rust registers
  per-id on Messages — and no app-global window handler exists;
  window_closed's registration is one-shot and retires with its
  window, taking the close registration with it.
- **Back never touches windows.** At the primary surface's root the
  back gesture belongs to the system (leave the app); kaya offers no
  interception in v1. An app that wants back to mean something must
  have given the vocabulary something poppable — a dialog now, a
  navigation entry someday.

### Modal presentations — alerts (landed) and root-hosting modals (later)

The modal tier splits in two, because the platforms' own dialogs do:

- **Alerts** (LANDED) are pure vocabulary objects — title, message, buttons in;
  a result event out; NO scene root inside. This is deliberate
  dressed-floor discipline: UIAlertController, NSAlert, ContentDialog,
  AdwMessageDialog, and Compose's AlertDialog are canonically
  title+message+buttons, and modeling alerts this way means every
  platform presents its real dialog rather than a styled window.
  Whether a dialog IS a window is platform-inconsistent trivia
  (NSAlert and GTK dialogs are windows; ContentDialog is an in-window
  XAML overlay; UIAlertController is a presented view controller) —
  which is precisely why the vocabulary models the uniform semantics
  (modal, parent-bound, result-bearing) and not the windowhood.

  The landed shape. One atomic SHOW_ALERT request, window-scoped
  (0 = the primary; NSAlert presents as that window's sheet,
  ContentDialog on its XamlRoot, gtk::AlertDialog transient for it,
  the phones over their one surface — alerts are the first context
  every host has natively, so there is no capability gate). It
  carries title, message, 0..=2 action labels — the platform floor:
  ContentDialog's three slots are two actions plus close, and the
  strictest platform sets the floor — plus a REQUIRED cancel label:
  the cancel slot always exists because every platform has a native
  dismissal (Esc, back, outside tap, the cancel button itself) and
  ALL of them resolve to it; no binding invents a default label (no
  hidden English in the floor). The one answer is ALERT_RESULT
  {alert, choice}: an action index, or the deliberately-not-an-index
  cancel sentinel (u32::MAX; -1 in the JVM's int spelling). The
  result handler binds to the REQUEST, never to the app — the
  widget-handler precedent (a click handler attaches at its button):
  closure languages take on_result at the show call, Rust registers
  per-id (msgs.on_alert on the id show() returns), the registration
  retires with its one answer, and ids are binding-allocated like
  widget ids — so guests carry no correlation plumbing, and the
  ledgered multi-alert relaxation needs no API change. The confirm
  scene makes the association VISIBLE: two different dialogs from
  two buttons (delete, two actions; eject, one — which also keeps
  the single-action wire arm live), each bound to its own handler,
  so the eject statuses can only come from the eject registration —
  no switch, no id inspection, in any language. One
  alert may be live per process — ContentDialog throws on a second
  per root — and a second show while one lives is a loud guest
  error; the id retires when the result fires, and the liveness slot
  lives in capi's process singleton because show is applied
  scene-side while the result arrives presentation-side (the one
  state both ends share). The request/result grammar has no
  programmatic dismiss in v1; that, per-window alert concurrency,
  and >2 actions are ledgered relaxations, each waiting on a real
  need.
- **Root-hosting modals** (sheets, content dialogs) — a presentation
  context hosting an arbitrary scene root — come later, reusing the
  same mount-target machinery windows introduce.

### Navigation (ratified 2026-07-21)

A stack of scene roots inside one surface, exactly one visible; the
lifecycle verb is POP. The two questions that kept this out of phase
4 are answered:

- **The stack lives in the protocol, core-owned.** Back-sovereignty
  forces it: predictive back on Android means the SYSTEM drives the
  pop, including rendering the covered screen mid-gesture, and a
  guest-owned stack would put a guest round-trip in front of that
  animation — the stall predictive back exists to eliminate. The core
  owns per-window entry stacks; each backend hands its native
  navigator real state (SwiftUI `NavigationStack(path:)`, the Compose
  back dispatcher, a GTK/WinUI content stack) and reports the pop as
  an occurrence after the fact. Bindings mirror the stack the way
  they mirror mounted windows; guests carry no stack of their own.
- **Entries are retained until popped.** A pushed-under root stays
  alive — its widget ids remain valid, the guest can keep mutating a
  covered root (a list screen updating behind its detail screen is
  the canonical case), and predictive back has something real to
  peek at. Pop destroys the popped entry's tree exactly as
  destroy_window forgets its mounted tree: ids are never reused, so
  stale targets fail loudly. Covered = retained, popped = gone — one
  rule, both directions, no platform divergence.

The vocabulary. Entries share the surface-id namespace with windows —
one binding-side allocator, and `mount {window, root}` keeps its
shape; the target's domain grows from "windows" to "surfaces"
(generalize the TARGET of mount, not the tree):

- `push_entry {window, entry}`: push a new entry onto `window`'s
  stack (entry ids are guest-allocated in the shared surface
  namespace, below the internal bit — the create_window discipline).
  Materializes covered/incoming; mounting a root into it presents it
  — the create-hidden/mount-presents grammar windows already have.
- `pop_entry {window}`: programmatic pop of the top entry. Popping an
  empty stack is a loud scene error.
- `entry_popped {entry}`: the user's back affordance popped an entry
  natively — informational and post-fact, the window_closed
  precedent; the core's stack has already reconciled by the time it
  fires. A programmatic pop_entry does not echo here: its caller
  already knows (the destroy_window discipline — bindings fold their
  mirror at the call site).
- **Entry props are their own typed table** (`ENTRY_PROPS`: `title`,
  `intercept_back`), with a set_entry_prop duo mirroring
  set_window_prop — deliberately NOT the window-prop table plus
  runtime applicability checks. The tables are spec facts and the
  emitters' typed setters are the point: a wrong-surface prop dies at
  compile time in every binding rather than at the scene. `title`
  feeds the back affordance (the iOS back-button label, the desktop
  headers).
- **Back interception is the close-veto class transplanted.**
  `intercept_back` (Bool, default off), per entry: off = the platform
  pops natively with its full predictive animation; on = the back
  affordance emits `back_requested {entry}` and nothing pops until
  the app answers with pop_entry. This is Android's own model —
  OnBackPressedCallback is declared-ahead enablement, not
  veto-at-gesture-time — so an armed interception taking over the
  gesture is the platform's semantics, not a kaya carve-out; iOS
  spells armed as disarming the swipe recognizer, the desktops route
  the back button's click to the occurrence. POP stays user-sovereign
  except where the app explicitly armed the same opt-in class windows
  use for close.
- **Navigation handlers bind to the ENTRY, never to the app** — the
  request-bound alert precedent, ratified for entries 2026-07-22: the
  push site knows what popping ITS screen means, so the popped and
  back-requested handlers ride the push (chain methods, named
  arguments, or config-list attrs per language; Rust registers per-id
  on Messages, its alert spelling) and no guest ever inspects an
  entry id. entry_popped's registration is one-shot — an entry pops
  at most once (ids never reused) — and retires with the pop, taking
  the entry's back registration with it; back_requested's fires per
  request while armed. Registrations on programmatically-popped
  entries go inert harmlessly, the widget-handler discipline (click
  handlers on destroyed widgets are the precedent). App-global
  navigation handlers do not exist — and as of 2026-07-22 neither do
  app-global WINDOW handlers (see Close above): every lifecycle
  callback in the vocabulary now binds to the entity that creates it.
- **No capability gate** — the deliberate contrast with aux_windows:
  every host materializes a serial stack natively (Android's
  predictive back, iOS swipe-back, and on the desktops the
  header/toolbar back button — the System Settings /
  AdwNavigationView / NavigationView pattern), so there is nothing to
  advertise and nothing to reject.
- **Window-scoped from day one; no nesting.** push_entry carries
  `window`, so a stack inside a desktop auxiliary window costs
  nothing extra (the System Settings shape); phones only have surface
  0 anyway. One stack per window; entries cannot host stacks in v1.
- **Multi-pop is binding sugar, and the batch is the animation.**
  pop_to_root()/pop(n) lower to N pop_entry records in ONE
  transaction — the bindings know the depth from their mirror, and
  the transaction is already the protocol's atomic unit. The
  materialization obligation, stated here so it is not rediscovered
  as a bug: backends animate the NET stack change per applied batch,
  never per op. The platforms' own pop-to-root APIs
  (popToRootViewController, path.removeLast(k), popBackStack) exist
  precisely so a multi-pop plays one transition; per-op animation
  would be the observable divergence.

Harness: expect_entries, a `back` action verb driving the real
affordance per platform, and entry-targeted expect_title — all four
layers in both interpreters from the start, per the
interpreter-backend doctrine.

### Sections (tabs) — ratified 2026-07-22

Tabs are a presentation context, not a widget: a fixed-ish,
app-declared set of PEER roots inside one surface, user-switched, all
retained — and the first grammar with no destruction semantics at
all. Switching is SELECTION, not lifecycle.

The ratified shape:

- **Sections are surfaces.** `add_section(window, section)` declares a
  section into a window; section ids share the guest-allocated
  surface namespace with windows and navigation entries, and `mount`
  targets them like any surface. The set is append-only (the
  select-options precedent): nothing removes a section, because this
  grammar has no destruction verbs by design. Every section's root is
  retained while covered — a signal write to a hidden section is
  observable on switch-back.
- **Selection follows the echo doctrine.** The user's switch emits
  `section_selected(section)`; a programmatic `select_section` is
  configuration and never echoes. Bindings register the handler
  per-section at declaration (`on_selected` riding `add_section`) —
  handlers scope to their creator.
- **SECTION_PROPS** (the ENTRY_PROPS pattern): `title` (Str) and
  `icon` (Blob, the blob channel — a tab bar without icons is not the
  platform's real thing).
- **Presentation is a WINDOW prop**, `sections_presentation`
  (enum: `auto | bar | sidebar`), declared beside the sections it
  presents — scoped to the hosting window (the GROUP is the unit; no
  platform mixes per-section presentations), never app-global, and
  ADVISORY per the width/height precedent: honored where the platform
  has the idiom, resolved to the nearest thing otherwise, ignored on
  the phones where physics decides (bottom bar regardless).
  `auto` resolves to each platform's dominant sections idiom:
  the bottom tab bar on iOS (TabView) and Android (M3 NavigationBar),
  toolbar tabs on macOS (TabView), NavigationView left on Windows,
  the header-bar switcher on GTK (GtkStackSwitcher over GtkStack).
  `bar` resolves to the horizontal spelling (macOS toolbar tabs,
  NavigationView top mode, header switcher); `sidebar` to
  NavigationSplitView / NavigationView left / GtkStackSidebar.
- **Navigation stacks become per-surface.** Sections are surfaces and
  push_entry targets a surface, so pushing INTO a section falls out
  of the same generalization mount made; each section carries its own
  stack, and the back affordance routes to the ACTIVE section's
  stack. Back never switches sections — at stack-empty it does the
  platform default.
- **Observations**: `expect_sections N` (count from the real
  control), `expect_section "title"` (the ACTIVE section's title from
  the platform's own selection state), `select_section` driven
  through the real switcher, and a retention assertion (write to a
  covered section, switch, observe). No capability gate — every
  platform has a sections idiom.

Deliberately excluded, reaffirmed: DOCUMENT tabs (browser/editor
user-created, closable, reorderable tabs). Those are window
management — their verb is CLOSE, their count is dynamic, they drag
between windows — and belong to the windows grammar if kaya ever
wants them; conflating them with sections would poison both grammars
the way window-as-push would have poisoned navigation.

### Protocol shape

`mount(root)` today is the degenerate case — mount into the one
implicit primary window, target 0. Phase 4 generalizes the TARGET of
mount, not the tree: the spec grows presentation-context objects and
their lifecycle events, additively. The widget vocabulary, the eight
bindings' scene construction, and the geometry gates do not move.

## Threading model and protocol

- The invariant, uniform across platforms: exactly one UI thread runs all
  native-widget code and the core's dispatcher; app logic runs on a
  separate thread; the only bridge between them is the transport below.
  What varies per platform is who provides the UI thread. On macOS and iOS
  it must be the actual process main thread (thread 0), so the core takes
  over `main()` and kaya hosts the language runtime. Windows and GTK bind
  the UI to whichever thread creates the windows and pumps events, so the
  core takes the thread that calls `run()`, main by convention. Android
  inverts the hosting: the OS owns the process entry and the Looper main
  thread, so the core attaches its dispatcher to that thread instead of
  owning it. The hosting relationship flips there; the threading
  invariant does not. The entry points are named by loop ownership.
  `run` (kaya::run, kaya_run): kaya owns the loop — one call from main,
  the seamless default on every platform where the process is yours.
  `attach`: the host owns the loop — kaya adds its scene on the host's
  UI thread and returns the thread; the doorbell needs no host
  cooperation because every platform has a post-to-main-loop primitive
  (GCD's main queue, DispatcherQueue, g_idle_add, runOnUiThread). Attach
  exists today only where it is mandatory: Android, where the anchor is
  explicit as Android context always is — the shell Activity calls
  `Kaya.attach(this)` (answered by the android_main! expansion; the
  return value says whether kaya presented or a guest-side backend like
  Compose should be mounted), or `KayaRing.attach(this)` when the JVM
  app is itself the guest — so every Android app validates the shape by
  construction. The desktop JVM guest tier reuses the KayaRing NAME but
  not the attach SHAPE: `dev.kaya.KayaRing.attach()` on a desktop only
  registers the natives (the one name-resolved export; jvm.rs), and the
  loop entry remains `KayaRing.run()` — kaya_run itself, the calling
  thread becoming the UI loop exactly like every C guest's main. On
  macOS that thread must be the process's first, so the launcher
  carries `-XstartOnFirstThread` — the JVM's spelling of the thread-0
  requirement above. dev.kaya.KayaRing therefore exists twice by
  design: Kotlin in android/kaya (Activity-anchored attach, no run),
  Java in bindings/java-desktop (anchorless attach, run) — KayaApp is
  written against the shared ring statics and never sees which twin
  loaded; native registration matches name+signature against whichever
  class is present, so drift dies loudly at attach on that platform. A general-purpose anchorless `kaya_attach` for desktop
  embedders (plugin UIs, tool windows in a host app) was prototyped and
  passed against real foreign hosts — a Swift AppKit app, a Swift UIKit
  app in the Simulator, a C program running a GLib loop — then removed:
  the one platform that requires attach cannot use an anchorless C entry
  (the Activity must be passed, which only JNI can carry), no desktop
  embedder exists yet, and under breadth-first validation an uncalled
  entry would tax every future feature with three more suites. The shape
  is proven; it returns when an embedder does. Mounting into a
  host-provided parent view is likewise deferred (where the scene lives,
  not who owns the loop).
- App logic runs on its own thread. The contract is minimal: some
  blockable thread runs the guest loop, because occurrence consumption
  blocks by design; either side may provide the thread. Native guests
  (Rust, C, Swift) run on any thread — a host-spawned thread calling a
  blocking guest entry is equivalent to the guest spawning its own
  (a guest staticlib can equally spawn internally behind one C entry, as
  the retired Swift-shell leg demonstrated). Managed runtimes prefer providing their own thread,
  for attachment reasons rather than correctness: JNI requires
  AttachCurrentThread for foreign threads, Go code runs on goroutines
  behind a cgo handshake, Python requires PyGILState on foreign threads.
- The hosting scaffolding differs per platform and per composition — who
  owns main (the core on desktop, UIApplicationMain on iOS, @main on the
  SwiftUI leg, the OS on Android), who starts the backend, who spawns the
  guest — and none of it is the app developer's concern. The app is
  exactly one thing on every platform: a loop consuming occurrences and
  writing commands. Scaffolding is provided by kaya or generated by its
  distribution tooling.
- Distinct from thread provisioning is runtime boot, and guest languages
  fall into three classes. No runtime (Rust, C, Swift): link and call the
  entry symbol. Self-booting on load (Go via c-archive constructors, .NET
  NativeAOT, GraalVM native-image): the same, effectively. Embedded
  interpreters (CPython, JVM via libjvm, .NET via hostfxr): the VM must
  be created and configured when the language does not own the process.
  Two canonical compositions cover everything: guest-hosts (the language
  owns the process and calls a run entry — the desktop Python/Go/C# legs,
  and Python hosting the SwiftUI backend via kaya_swiftui_run, since
  @main is compiler sugar over the callable App.main()) and shell-hosts
  (a native shell owns main and calls one guest entry symbol on a
  blockable thread — the SwiftUI + Rust-guest leg). Which composition
  applies is determined by the platform's launch model, not by the
  backend technology. iOS's constraint, stated precisely: the OS execs
  the native executable named in the bundle, so the process entry must be
  a compiled binary — which is indistinguishable from guest-hosts for
  compiled guests (the UIKit leg's bundle executable is milestone2.rs's
  main, and the rust-swiftui leg validates a Rust entry dispatching to
  the SwiftUI backend dlopen'd from inside the bundle), and means
  interpreted guests need their binding's native bootstrap as main. On
  desktop either composition works with any backend.
- One backend per platform (ratified 2026-07-20): the SwiftUI
  interpreter on macOS and iOS, Compose on Android, GTK4 on Linux,
  WinUI3 on Windows. The native AppKit, UIKit, and Android Views
  backends are deleted; where SwiftUI/Compose cannot express a
  semantic, the interpreter drops down per widget through the
  platform's sanctioned interop (NSViewRepresentable /
  UIViewRepresentable / AndroidView) — the protocol never names a
  toolkit, observable semantics stay uniform, intersection-first, and
  each drop-down is recorded here with its conformance scene. Today's
  widget vocabulary needs none.
- Nothing crosses the boundary synchronously: no callbacks, no unbounded
  rendezvous. All communication reduces to two primitives plus an arena.
  - Logs: lock-free SPSC rings for ordered, lossless, consumed-once
    traffic. Occurrences flow out; commands and signal-write transactions
    flow in, with begin/end markers applied atomically at a frame boundary
    so there are no torn multi-signal states. A handler is a transaction:
    the binding runtime wraps each dispatched occurrence batch in an
    implicit transaction committed when the handler returns, so handlers
    are atomic without any effort from the author. Explicit transactions
    exist only for writes outside handlers, such as timers and background
    completions. Records have a fixed header (u32 size, u16 channel/type,
    u16 flags), 8-byte alignment, and variable-length payloads inline.
    Overflow grows by chained segments; the producer is never blocked and
    no record is dropped. (Chained growth is still to build: the shipped
    ring is fixed-capacity and a full ring fails loudly — ring.rs marks
    segment growth as pending, and no scene has yet filled a ring.) The
    core reads the app's consumer cursor
    directly, so stall detection ("log undrained for N seconds") requires
    no protocol.
  - Slots: seqlock cells for keep-latest traffic, one per channel. A write
    is an overwrite and no queue exists; watchers get an optional
    coalesced wake record, at most one pending per slot. Present state,
    demand, and the app-readable widget-state mirror are all slots: one
    mechanism in three roles.
  - A shared-memory arena for bulk payloads (row batches, pixel surfaces,
    audio, templates), referenced by offset and length. Its v1
    realization is the blob table: kaya_blob_register copies bytes once
    into core-owned refcounted memory and returns a handle the next
    submitted transaction references (handles are consumed by one
    submit — register per transaction); every record stream carries the
    8-byte handle, never payload bytes, so no fixed buffer anywhere
    bounds a payload's size. Reclamation is the refcount: scene state
    (a signal's current value, a collection record's field) holds
    references, restamps re-read without re-upload, and the last drop
    frees — there is no guest-visible free, and an unreferenced
    registration dies at its submit boundary, so the leak class is
    closed by construction. The guest's own buffer is never part of the
    count: the register copy is the ownership boundary (the
    kaya_submit stance), and the guest frees its bytes whenever it
    likes. Presentation-side, the pump publishes a batch-local table
    (fetch by handle, decode within the batch). The offset+length
    arena form returns when the row window and audio need it.

The invariant: every question the platform asks synchronously must be
answerable from state already on the fast (core) side. Events can express
anything, but they cannot arrive back inside the platform's stack frame.

### Traffic taxonomy

Channels are classified by direction, shape, and loss policy.

Core to app (reports of the past, statements of need):

- Occurrence log: clicks, key presses, close requests, lifecycle. Ordered,
  lossless, consumed exactly once. Occurrences originating inside a `For`
  instance carry the instance handle and row key, so per-row handlers
  receive their row identity without per-row closure state.
- Present-state slots: mouse position, scroll offset, geometry during
  resize, widget values. Keep-latest; coalescing is the correct semantics
  for this traffic, not a degraded mode. The same slots double as the
  readable mirror: the app reads current widget state on demand without
  blocking anyone. Uncontrolled inputs are read at decision points instead
  of tracking keystrokes, the way HTML forms work.
- Demand slots: state about the future, such as "the viewport now needs
  rows 300 through 350" or "a frame at 800x600 is needed". Keep-latest;
  supersession is overwrite, so cancellation costs nothing. Each demand is
  paired with a proceed-default (placeholder rows, a scaled stale frame).
  Demand aggregates naturally: a fling coalesces into one range update,
  which is cheaper than per-cell callback pulls.

App to core (content for the future, rules for the gaps):

- Command log: one-shot imperatives such as `close()`, `focus()`,
  `scrollTo()`.
- Content buffers: templates and signal writes (keep-latest per signal),
  row data, drawn frames and display lists, audio samples. The slow side
  works ahead of demand and the freshest data wins (sequential-ahead for
  media). The audio ring is the limiting case, with perfectly predictable
  demand; the row window is the same mechanism with imperfect prediction;
  a placeholder is the visual analogue of an underrun.
- Vocabularies: pre-pushed rules that let the core answer questions during
  app-thread gaps. Validation masks, shortcut tables, accepted drop types
  and operations, declared list counts, closability, accessibility
  annotations as node properties. A vocabulary is a compressed buffer of
  pre-computed answers. The escalation policy: ship the pure event
  protocol first, and add a vocabulary only when a default-now-correct-
  later artifact proves unacceptable. Each addition changes what the core
  answers during the gap, not the shape of the API.

### Answering strategies and the blocking policy

Every synchronous platform question is answered in exactly one of three
ways:

1. From pre-pushed state or a vocabulary (preferred).
2. Default now, correct later: a placeholder cell patched on arrival;
   staying open until an app-initiated `close()` (the request/confirm
   pattern); claiming a key unhandled and re-dispatching it.
3. A bounded wait: park the platform's pull until a deadline, then fall
   back to option 2.

The blocking policy:

- Bounded waits on content are always allowed. Lateness there is cosmetic
  (rows arrive a frame late) and the semantics are identical. In the
  healthy case the round trip is microseconds and the fulfillment lands
  before paint, so no placeholder is ever visible and the behavior matches
  the callback world. Placeholders are the degradation mode, not the
  normal experience.
- Bounded waits on decisions are allowed only when the expiry default is
  fail-safe and retryable. The drop verdict qualifies: on expiry the drop
  is rejected and the drag snaps back, an idiom users already know. A wait
  is never allowed where expiry silently commits an irreversible branch;
  accepting a "move" drop causes the source to delete the original.
- Unbounded waits are prohibited. Any finite deadline, however generous,
  provides three structural guarantees that fail only at infinity:
  deadlock immunity (every wait cycle becomes a one-deadline artifact), OS
  watchdog safety (an unpumped main thread earns "Not Responding", the
  beachball, or an accessibility "busy" state), and a cap on priority
  inversion (a parked user-interactive main thread inherits the app
  thread's QoS, and futex/condvar parks do not donate priority).
  Finiteness also keeps UI liveness a property of the architecture instead
  of a discipline: "keep the app thread responsive" is "don't block the
  main thread" renamed, and abolishing that rule is why the second thread
  exists. Deadlines are per-channel tuning, not architecture.
- Stall diagnostics come free from the transport: the core reads the app's
  log-consumer cursor, and "undrained for N seconds" is the health signal.
  An earlier draft had a Wayland-style liveness ping; the cursor made it
  redundant. The UI does not need app liveness to stay live.

## Case analyses

Each of these was worked through as a stress test of the model before the
model was accepted.

**Virtualized lists.** Native list virtualization is pull-based and
synchronous (`cellForRowAt`, `RecyclerView`). The core holds a materialized
row window, answers pulls from it, publishes viewport demand, and the app
refills ahead of the viewport. In the healthy case fulfillment lands in the
same frame, because the core drains fulfillments before the paint/commit
point; placeholders appear on a teleport or an app stall. React Native ran
this experiment in the other direction: its original async-only bridge
produced the well-known blank-cells problem, later fixed by adding
synchronous JSI. RN had neither fast-side state nor control of the protocol
boundary; kaya has both.

**Window close and the veto class.** Request/confirm: the core defaults to
staying open, emits `CloseRequested`, and the app later issues `close()` if
it agrees. No response is required and there are no correlation ids. winit,
Tauri, and Electron all converged on this shape.

**Drag and drop.** Hover acceptance is answered from a pre-pushed
vocabulary of accepted types and operations, which matches platform
convention anyway, since fetching drag content mid-hover is discouraged
everywhere. Dynamic hover policy is app-updated state; staleness there
mislabels a cursor badge, which is cosmetic. The drop verdict is a bounded
wait whose expiry rejects the drop and snaps the drag back, a fail-safe and
retryable default. Source-side data provision (`IDataObject::GetData`,
pasteboard promises) is demand with a generous deadline; the blocked party
is the receiving process, and platforms have long normalized slow
providers. A side benefit: app logic keeps running inside the drag and
resize modal loops that stall single-threaded apps.

**Accessibility.** Native widgets are the accessibility tree, and they
answer VoiceOver, UIA, and AT-SPI from retained core state, so the app is
not in the answer path at all. Custom-drawn frameworks pay a permanent tax
building semantics trees by hand; wrapping native widgets gets this for
free. Accessibility also stays fully live during app stalls, where a
classic app's stalled main thread reads as "busy" to VoiceOver. The
remainders: virtualized rows outside the window are demand with a generous
deadline (assistive clients tolerate seconds); custom-content annotations
ride the submitted tree; assistive actions are ordinary occurrences.

**Custom drawing.** The compositor model: the app renders into retained
surfaces (`CALayer`/IOSurface, DirectComposition swap chains, Wayland
buffers) on its own schedule, and the core displays the latest completed
frame. WPF (no paint callback, a retained drawing tree) and Chromium
(rasterizer and compositor in different processes) are existence proofs.
Interactive resize is the stress point. A bounded micro-wait for the
matching-size frame covers it, which is what browsers do internally, and
display-list submission does better by letting the core re-rasterize at
any size without an app round trip; only content whose layout depends on
size still needs the app. The degradation is momentarily stale, scaled
content during a violent resize, the same as browsers. Decision: v1 ships
pixel surfaces only, passed as platform surface handles (IOSurface, DXGI
shared handles, dmabuf), so shipping pixels means passing a handle rather
than copying. Display lists are v2 and adopt Vello's scene encoding rather
than inventing a format.

**IME composition.** Input methods hold a mid-keystroke conversation with
the focused field: they set and update preedit text, read surrounding text,
query the composition rectangle to place the candidate window, and commit.
The platform protocols span the whole synchrony spectrum:
`NSTextInputClient` is fully synchronous; Windows TSF uses `ITextStoreACP`
document locks but has an asynchronous grant path; Android
`InputConnection` is cross-process with timeouts, and a slow app returns
`null` to the IME; Wayland `zwp_text_input_v3` is pure asynchronous state
sync, with pushed surrounding text and cursor rectangle and preedit/commit
events.

For native text widgets, the platform's own controls implement the IME
protocol against their internal buffers, so the app is not in the
conversation at all, the same dividend as accessibility. This does force
one new protocol rule: composition is a transaction. The core, which knows
composition is active, queues app-originated mutations and defers
vocabulary filtering until the commit. This makes the classic
clobbered-preedit bug class (garbled CJK input in controlled inputs)
impossible rather than merely discouraged.

For custom text editors (app-drawn), the app fulfills an IME contract of
three state channels: a windowed text mirror around the cursor, the
selection, and the cursor/composition rectangle. The core implements the
platform protocols against that mirror, and IME edits stream back as
occurrences. The contract adds no mechanism; the three channels are
ordinary app-written signals on the editor widget, and only the convention
is named. The contract has the same shape as Wayland text-input v3, and
Chromium demonstrates it at scale, implementing TSF and
`NSTextInputClient` in the browser process against text mirrored from the
renderer process. Degradations, which apply to custom editors only: preedit
repaint lags an app stall like any canvas content; the candidate window
trails a stale cursor rectangle (cosmetic, and inherent to Wayland's design
as well); reconversion context is limited to the mirror window (IMEs
degrade gracefully with partial context, and browsers ship partial TSF
stores). Contract details: the mirror is the paragraph around the cursor
capped at 4 KB, which is Wayland's cap and far above Android's defaults;
TSF synchronous-only lock demands beyond the mirror receive a partial
store; core-composited preedit for custom editors is deferred to v2
alongside display lists.

**Audio.** The render callback is hard real-time and can never be an event
delivered to the app thread, in any architecture: an SDL-style callback
into a garbage-collected language glitches on the first collection. The
constraint comes from physics and garbage collectors, not from this
protocol. Professional audio practice already forbids callbacks into
application logic from the real-time thread and runs on lock-free rings,
which is this protocol independently invented decades earlier. Decision:
the core owns the real-time callback (Rust, RT-safe) and drains a sample
ring the app fills ahead of playback (20 to 100 ms ahead; an underrun
produces silence). Synthesis is served by a declarative node-graph
vocabulary, which is Web Audio's answer to the same problem, and a native
DSP module serves as the escape hatch for genuinely low-latency work:
pushed code rather than pushed state, in the manner of AudioWorklet.

**The button that measured borderless and drew bezeled.** The mac
align scene shipped a button rendering "t…" for "tick" while its twin
rendered "mid" in full. Every plausible suspect was A/B-innocent: the
baseline alignmentGuide hook, live resize (deterministic recompute),
baseline-vs-center row alignment, the tall no-baseline image. A
pass-through Layout probe finally showed the mechanism: SwiftUI's own
Button answered `sizeThatFits(.unspecified)` with its *borderless*
metrics (38×20 for a 13pt caption) while drawing the *bezeled*
control (52×32), so every consumer of the measurement — the stock
HStack's ideal, KayaFlex's tracks — inherited the lie, proposed the
row its lying ideal back, and the bezel overflowed its slot until the
caption ellipsized. The trigger is the host process, not the view
tree: SwiftUI 26 resolves its design generation from the main
executable's `LC_BUILD_VERSION` — the SDK field specifically, not the
deployment target (verified: minos 14.0 with sdk 26.5 takes the
modern, honest path) — and a pre-26 SDK stamp lands in a
compatibility path whose Button measurement table disagrees with its
own renderer. A plain cargo build against a current Xcode SDK stamps
current and never sees this; the affected population is binaries
LINKED against old SDKs — pinned-SDK environments like our own nix
shell (everything it links stamps 14.4), and the vendor-prebuilt
launchers that host guest runtimes in the wild: JDK launcher stubs
and the jpackage apps that inherit them (zulu stamps 11.3), conda
pythons, PyInstaller-class bootloaders, .NET apphosts. A standalone
twenty-line app reproduces it at `-target arm64-apple-macos14.0` and
is honest built native. The floor
consequence was worse than one truncation. An audit of every leg's
host binary showed the nix shell links everything against its pinned
SDK — python3, go, dotnet, ocaml, rust all stamp 14.4, the zulu JDK
11.3 — so our own suite hit the lie uniformly (and, silver lining,
exercises the compatibility generation daily). But the stamp belongs
to whoever built the host binary, and in the wild that is the runtime
vendor: on this same machine Apple's /usr/bin/python3 stamps 26.5.
Before the fix, button geometry would therefore diverge BY HOST
RUNTIME — same dylib, same machine, two answers depending on which
language's runtime mounted the scene. The fix follows from the diagnosis: bridge the macOS button
to `NSButton` via NSViewRepresentable and answer sizing with
`fittingSize` — an AppKit control cannot disagree with itself, in
either design generation, under any host stamp — On iOS the story inverted under the probe: SwiftUI's Button is
honest there at every proposal (.unspecified included, in kaya's own
26.5 generation), and the naive `.bordered` dress wrapped captions
because of a kaya-side interaction — the flex cell's alignment frame
PLACES a child by re-proposing it its own fitted ideal, and under an
exactly-ideal proposal HStack's fair-share division shortchanges the
button (the division asks it before the label releases its surplus),
which conforms by wrapping. That re-proposal was the `KayaCell`
class — and it had two members: the outer fill-and-align frame AND
the inner stretch frame (a constraint-less `.frame` places the same
way), so deleting one just moved the squeeze down a layer. The
custom cell layout now proposes the full cell at placement, folds
stretch in, and explicitly queries the child's `.top` guide — the
alignmentGuide recording closures only run when a guide is queried,
and the deleted frames had been the accidental querier. iOS keeps
SwiftUI's Button in the bordered dress. The
macOS bridge is permanent, and not for lack of looking for a way
out: in a compat-stamped process every dressed style — automatic,
bordered, borderedProminent — lays out at the same borderless 38x20
while the AppKit bridge paints 52x32 over it (kaya-free repro; even
a GeometryReader reads the 38x20 layout box under the bezel), and in
the modern generation all three are honest. There is no style,
control size, or wrapper that escapes the compat table; only the
control that measures itself does.
The control assay (probe every vocabulary control both ways) cleared
the rest: entry, label, image, slider, and checkbox measure what they
draw; the knob and focus-ring spill are decoration outside the layout
rect, not lies about it.

## Rejected alternatives

- Classical synchronous callbacks. Reentrancy is a standing bug class, app
  logic is welded to the main thread, and every binding needs FFI callback
  machinery. The callbacks that survive any attempted purge (data pulls,
  paint, input filtering, audio) are precisely the synchronous,
  latency-critical, reentrancy-prone ones, the worst things to expose
  across a language boundary.
- The SDL-style hybrid, mostly events plus a handful of callbacks. It
  keeps nearly all the FFI pain, since the surviving callbacks are the
  hard ones, while adding the queue machinery anyway. Reversibility is
  asymmetric: a narrow opt-in same-thread hook can be added compatibly
  later if a wall is hit, whereas a callback shipped in v1 is a permanent
  contract that welds the threading model into every binding. So v1 ships
  zero callbacks.
- Unbounded cross-thread rendezvous. For identical, disciplined code it
  actually beats the callback world on freeze behavior, with fewer and
  shorter freezes, but it loses to bounded blocking at every point on the
  curve. Unboundedness re-imports main-thread discipline under a new name,
  opens a deadlock class that a deadline closes, trips OS watchdogs, and
  inherits priority inversion. The structural guarantees hold for every
  finite deadline and fail only at infinity, so an infinite deadline is
  not the limit of a generous one. Its failures are also unattributable
  (emergent and timing-dependent), whereas callback-world slowness shows
  up in a profiler pointing at the slow handler. Answering from fast-side
  state is the only arrangement that makes the discipline structural
  rather than conventional.
- Deadline-bounded waits on decisions without fail-safe defaults. They
  produce load-dependent semantics, such as a close veto that works only
  when the machine is idle: heisenbugs written into the platform contract.
- Pure polling, with no events at all. Occurrences don't sample: counters
  lose ordering, and flag-clearing reinvents interrupt-status handshakes.
  Efficient polling requires block-until-changed, which is an event. A
  polling cadence burns battery or adds latency. The idea amounts to
  walking back the invention of the interrupt. Its lasting contribution to
  this design: much upstream traffic is state-shaped, which is where the
  keep-latest slots and the readable mirror came from.
- An own layout engine over absolutely positioned native widgets. This is
  the industry-standard choice, and it was rejected because it serves a
  goal kaya renounces, pixel consistency across platforms. It should be
  revisited only if pixel consistency ever becomes a requirement; that
  requirement, not implementation pain, is what would flip the decision.
- A whole-tree core reconciler as the primary declarative API. The
  original design: submit a full view-tree description and the core diffs
  it against the previous submission. Rejected once the bypass incentive
  became clear. A whole-tree reconciler is policy, one framework's
  worldview of re-render-and-diff, and performance-minded bindings
  (compile-time reactive, signal-based, typed-view) would route around it
  to the imperative layer, contradicting the ceiling principle. It was
  replaced by the signal substrate, which those same strategies compile
  onto instead. What the reconciler provided survives: day-one usability
  for new bindings (signals plus templates is an even lower floor),
  UI-as-data tooling (inert templates), and the sequencing reference
  (inside `For`). Whole-tree diffing remains buildable as an optional
  library on top.
- A public retained-mode C API ("level 0"). Superseded by the reactive
  surface once it became clear that signals subsume property sets and that
  `When`, `For`, and instantiate subsume structural edits, leaving the
  retained C API as a second, redundant way to do everything. Redundant
  public surface is where misuse lives. Internalizing it shrinks the
  hardening burden to the sequences our own operators emit. The
  reversibility asymmetry applies here too: exposing it later is additive,
  retracting it is impossible.
- A core-side expression vocabulary (format, arithmetic, comparison, and
  select evaluated in the core). Killed by three observations. First, for
  app-sourced state the app is already awake when the source changes, so
  app-side derivation adds no round trip, and the motivating example was
  hollow. Second, real display strings need localization and
  pluralization, which must live in the guest's i18n tooling; a core
  `format()` that cannot pluralize works in demos and fails in shipping
  apps. Third, it cannot be adopted transparently, since a Python f-string
  evaluates eagerly, so it would be a second visible way to compute things
  in every binding. It survives only as the flat transform escalation
  path, and as a future consumer-scoped decision if server-driven UI
  arrives.
- Raw Win32 common controls as the primary Windows backend. Dated look and
  no layout engine, which undermines the ride-native-layout strategy. Kept
  as a fallback.

## Degradation modes

When the app thread stalls, these are the accepted behaviors. Each is the
graceful counterpart of what would be a frozen UI in a callback
architecture.

| Situation | Degradation |
|-----------|-------------|
| List teleport, or a stall during a fling | Placeholder rows, patched on arrival |
| Violent interactive resize | Stale frame scaled or cropped, for at most one deadline |
| Drop verdict misses its deadline | Drop rejected; drag snaps back (retryable) |
| Stale hover policy | Wrong cursor badge until the next refresh (cosmetic) |
| Audio ring underrun | Dropout (prevented by buffering ahead) |
| Custom-editor preedit during an app stall | Repaint lags until the app resumes (native widgets unaffected) |
| Candidate window with a stale cursor rectangle | Placed at the trailing position (cosmetic) |
| App thread stalled entirely | UI still scrolls, resizes, and answers accessibility; occurrences queue |

## v1 scope and delivery process

The widget set is minimal by policy, 15 items:

- Structure: Window, VStack, HStack, Spacer, ScrollView
- Display: Label, Image
- Controls: Button, Checkbox, Entry (single-line, uncontrolled), Slider,
  Dropdown (select-only)
- Collections: List (virtualized, `For`-driven; the widget the protocol
  machinery exists to serve)
- Chrome: MenuBar (carries the declarative shortcut policy), Alert

Selection criteria: (a) needed by the archetype apps, meaning a todo-class
app, a settings dialog, and a data browser; (b) a native peer exists on
every v1 platform; (c) machinery coverage, meaning every protocol subsystem
is validated by at least one widget. List covers the row window and demand;
Image covers content buffers; MenuBar covers policies; Slider and Entry
cover state slots and uncontrolled state; Button and Checkbox cover
occurrences; the containers cover native layout.

Two decisions inside the set: item-holding widgets (Dropdown, later
RadioGroup) hold items plus a selection signal and never expose child
items, because platform grouping semantics are a trap; and there is no
Table, because a multi-column row is a row template with an HBox inside
List.

The first-admissions queue, post-v1 and in rough order: Grid (forms will
demand cross-row alignment), TextArea, Canvas (with the surface-handle
transport), Tabs, RadioGroup, ProgressBar, ContextMenu, file dialogs,
Separator, Splitter, Table, Tree, and date/time pickers. Tooltips return as
a plain property. (Half this queue was pulled forward and landed in v1
during the 2026-07-22 widget run: Grid, TextArea, Tabs — as sections,
a presentation context rather than a widget — RadioGroup as radio,
ProgressBar, plus Select and Spacer which never sat in the queue.
Still ahead: Canvas, ContextMenu, file dialogs, Separator, Splitter,
Table, Tree, date/time pickers.) Not core: webview (a separate crate, if ever), rich text
(after display lists), and the audio implementation (designed above,
scheduled when an app needs it).

Delivery is breadth-first by policy: every widget or feature is validated
on all v1 platforms before the next one begins, so parity is enforced per
feature rather than reconstructed per backend afterward.

- Milestone 0 is a skeleton on every platform (window, event loop, Button,
  and one occurrence round trip), brought up in the order already chosen:
  AppKit, WinUI, GTK, UIKit, Android. "Backend order" means the skeleton
  bring-up sequence, not completed backends. Each skeleton is validated
  three times: from Rust, from a function-floor language over the C ABI
  (Python via ctypes), and from a direct-ring language (Go via its own
  atomics), since the multi-language boundary is the point of the library
  and the two boundary tiers are both contract. Android substitutes the
  platform's own managed runtime for the foreign guests — Java over the
  direct ring, the unchanged Rust example behind the one JNI entry —
  since packaging interpreted and compiled guests into an APK is the
  binding-bootstrap subject, deferred with it. The guest roster has since
  grown past the original three: C# (direct ring from a managed runtime),
  C itself, Java (Android), and OCaml — the first of the languages the
  GUI world has historically left behind, which are much of the reason
  the library exists. OCaml rides the direct ring tier, the way
  ocaml-uring binds the real io_uring: pure OCaml has no ordered access
  to foreign memory (OCaml 5's Atomic covers OCaml-heap cells only), so
  a Bigarray carries the data path — record parsing compiles to inline
  loads, byte-wise through the char kind because int32/int64 Bigarray
  elements box and would allocate per read — and two one-line noalloc C
  stubs carry the acquire/release cursor accesses as bare calls. ctypes
  covers the rest of the boundary, with the blocking calls releasing
  the runtime lock. Haskell joins on the same tier with less friction:
  Storable peeks inline to real loads, `ccall unsafe` imports make the
  same two cursor stubs bare calls (GHC's own Addr# atomics are the
  wrong shape: read/write are Word-sized only — mixed-size against the
  producer's 4-byte atomics — the 32-bit primop is CAS-only, and all
  are full-barrier), and `ccall safe` releases the capability around
  the blocking entries. Haskell also earns its slot for what comes
  after milestone 0: its binding is the natural place to try monadic
  sugar over the structural operators — do-notation across When and For
  templates — once the reactive surface lands. A minimal C surface
  exists for this (`kaya_run`, `kaya_next_occurrence`,
  `kaya_occurrence_ring`, `kaya_wait_occurrences`, `kaya_submit`;
  header generated with cbindgen), and occurrences already travel the
  real byte-record ring; milestone 1 replaced the ad-hoc set-text call
  with the full transaction record vocabulary.
- Milestone 1 is the reactive substrate: signals, scene-as-data, and one
  live binding, proven by re-expressing the milestone-0 scene through the
  new surface — the same window, button, and label, but the scene arrives
  as records and the label's text is a signal binding written from the
  app thread. Structural operators (`When`, `For`) wait for milestone 2;
  the substrate earns them. The wire decisions, settled in design:
  creation is a record, not a function — the guest writes
  create_signal/create_widget records with guest-allocated ids (per-type
  id spaces, a monotonic counter in each binding; unique by construction,
  the core fails loud on collisions as a broken-binding tripwire), so
  creating N things costs zero boundary crossings and composes into one
  atomic mount. The transaction is a buffer and one call commits it: the
  guest builds a byte blob of records (the same framing as the occurrence
  ring — one vocabulary document, two transports) and submits it with a
  single call; no second shared ring, so the write path demands no
  atomics from any language — the weakest FFI story gets the full
  surface, and bindings reduce to serializers plus counters (mechanical
  enough to generate from the vocabulary later). A transaction applies
  atomically on the UI thread, last-write-wins per signal within a batch,
  batches in submission order. The milestone-1 vocabulary: create_signal,
  write_signal, create_widget (kinds Column, Button, Label), set_property
  (value is a constant or a signal reference, nothing else — the binding
  rule made wire-concrete; text only for now), add_child (append-only;
  keyed insertion arrives with For), and mount, whose window target is
  reserved now with 0 as the implicit default window (see "Windows are a
  scene layer"). There are no signal reads: the flow is unidirectional —
  occurrences up as a lossless log, state down as keep-latest writes, the
  app a fold over the first producing the second. The app's own variables
  are the source of truth; a signal only holds what the app wrote, so
  read-modify-write has nothing to read, UI-originated state arrives as
  occurrences, and signals are a render pipe, not a state bus. This is
  where framework history points: the systems that shipped architectural
  two-way binding (WPF, Cocoa bindings, AngularJS) retreated from it one
  by one, and the survivors' "two-way" syntax (v-model, SwiftUI Binding,
  Svelte bind:) is compile-time sugar over property-down/event-up with a
  single owner — sugar kaya bindings can offer identically, with the core
  never knowing. The no-callback protocol had already foreclosed true
  two-way (the core cannot write guest memory); no-reads makes the
  surface match. Backends stay dumb appliers: the command enum grows
  Create/SetProp/AddChild/Mount variants, the same doorbell drains them,
  and signal writes resolve core-side through the signal-to-binding index
  into targeted SetProp ops — no backend grows a diff, a reconciler, or a
  subscription system, and the presentation-side pump (SwiftUI, Compose)
  receives the already-resolved op stream as records. Occurrence
  subscription/filtering is deferred: every click emits at milestone 1;
  the log is cheap. The milestone-0 examples migrate rather than fork —
  kaya_set_text and the fixed widget-id constants leave the C surface,
  replaced by kaya_submit plus the vocabulary — and the definition of
  done is the same validation matrix, green, with the scene as data.
- Milestone 2 is the structural operators: `When` and `For`, the scene
  growing and shrinking as a function of data. `For` binds a collection —
  a core-side ordered key→value table, the sibling of a signal, from its
  own guest-allocated id space — and the guest changes it with delta
  records (insert/update/remove), never snapshots. The rejected
  alternative was a list-valued signal: replace semantics destroy the
  information about what changed, forcing the core to reconstruct it by
  diffing, which needs element identity anyway and relocates the
  reconciler we refuse everywhere else. Deltas carry the intent, cost
  O(change) instead of O(n), and keep "nobody diffs" true end to end; a
  binding can still offer assign-a-list as sugar by diffing guest-side,
  where the old list is plain program data. Signals and collections split
  by update algebra, not reactivity: a signal's writes are replacements
  and coalesce (keep-latest), a collection's ops are edits, ordered,
  never coalesced. The right analogy is event sourcing or a database log
  — single writer, FIFO, state as the fold — not CRDTs, whose machinery
  answers a concurrent multi-writer convergence problem this protocol
  does not have. Keys are domain identity: Value-typed, chosen by the
  guest, unique per collection instance (a duplicate insert fails loud;
  update stays explicit), legitimately reusable after removal. Ids answer
  "which of the things you created," keys answer "which of your data" —
  ids are variable names, a static population whose associations are
  fixed when the code is written; keys are dictionary keys, a dynamic
  population named by the data itself. That is why occurrences return
  keys: the guest indexes its own model directly and no id-to-datum
  table exists in any guest. Template bodies are declarations, not
  creations: the For/When record opens a template scope, the records
  inside describe a blueprint, and nothing renders until data arrives.
  Template nodes take their own id space, so a widget id always names
  exactly one live widget. An instance — the copy stamped per entry — is
  named (template node, key path), one key per enclosing For; the
  variable length is the address's intrinsic dimensionality (a depth-2
  widget has two degrees of freedom), encoded once as a length-prefixed
  sequence of values and shared by occurrences and collection ops.
  Alternatives weighed: core-minted instance ids need a return channel
  the protocol doesn't have and don't survive rebuilds; positional paths
  are nth-child fragility; guest-minted flat handles work — the classic
  retained-mode answer, DOM references and toolkit pointers — but
  handles suit APIs that can return them, mandate runtime translation
  tables in every guest, read as opaque integers in a record dump, and
  name individuals where these instances are positions in a determined
  structure. Hashing or interning paths are compatible compressions if
  addresses ever run hot, not different semantics. A collection declared
  inside a template is itself a blueprint: each stamp gets a fresh
  instance, born empty, destroyed with its copy, addressed in writes by
  the same key path (insert into C at [g], key, value) — nesting costs
  one encoding and is handled now, not deferred. Templates bind props
  through a third source, element (the entry's value), alongside const
  and signal; ordinary signal bindings still work inside a template. The
  up-only rule: key paths appear in occurrences going up and in
  collection ops going down, and a path-addressed widget-property write
  will never exist — an instance must remain a pure function of template
  plus entry, so the core may destroy and re-stamp any copy at any time
  (a When toggling above it, virtualization later) with nothing lost;
  state that lives only in the widget tree is the bug class the rule
  deletes. This is also where the no-reads posture pays against the DOM
  comparison: DOM addresses are queries against a tree that other agents
  populate, kaya addresses are names computed from the guest's own
  writes — the tree holds no information the guest didn't put there, and
  the one genuine source of new information, user action, arrives pushed
  as an occurrence carrying its path. When is For over a zero-or-one
  collection wired to a Bool signal: false to true stamps the template,
  true to false unstamps, a rebuild each time (SwiftUI-if semantics);
  hide-without-forgetting is a future visible prop, not a second When.
  Scope: elements are scalars at milestone 2 — record values with field
  projection, and sum-typed elements dispatching per-variant templates,
  wait for milestone 3, where multi-field rows make them real; there is
  no list value ever (a sequence as content is a collection); order is
  insertion order until a move says otherwise: collection_move
  repositions an entry before an anchor entry (or at the end), keys,
  never indices — order is data, and an index would race the very
  deltas that change it. On the apply side it lands as move_child, the
  one structural op that edits a container's child order in place. Definition of
  done, as always: a scene exercising both operators — a nested For with
  per-group items and a When toggle — green on the full matrix from
  every guest.
- Milestone 3 is records and field projection: collection elements grow
  from scalars to fixed-shape records, so a todo is `{title, done}` and a
  template binds `title` to a label's text and `done` to a checkbox's
  checked. Every collection declares a schema at creation — an ordered
  list of value types, nothing else — and a scalar collection is the
  one-field case, not a separate mode. The rejected alternative was an
  optional schema (schema-less collections keeping milestone-2 semantics
  beside typed ones): that bifurcation is permanent — every later
  collection feature, reorder ops, sum types, virtualization, would need
  semantics and tests in both modes — and it leaves scalar element
  bindings unchecked forever, while mandatory schemas complete the typing
  story: with the For's collection known and the collection's schema
  known, an element binding is validated at template declaration (field
  index in bounds, field type against the property's type), earlier than
  any other write in the system. Field names never travel: the wire
  carries positional values and type tags, and names live in the binding
  that declared them, because nothing core-side ever resolves one — the
  invariant to preserve is that no hot path anywhere resolves a name;
  the scene's checks are an array-bounds test and a type-tag compare.
  Self-describing records (names on the wire) were rejected as pure
  inspectability with real cost: strings in every insert, a second
  encoding to validate, and the C floor wants indexes anyway. There is
  deliberately no record value type: a schema'd insert is N trailing
  values, positionally matched, and `Value::Record` waits for the
  feature that actually needs a record *as a value* — nested fields or
  sum-typed payloads — because adding it early means dead
  encode/decode/reject paths in every binding (keys in paths must reject
  it, signals cannot hold it) with negative tests for each. Projection
  is one integer: the element source in a template property gains a
  field index (scalar collections use field 0), and stamping resolves
  `record[field]`. Mutation gains one op, update_field(collection, path,
  key, field, value): a single field's delta, so toggling `done` never
  resends `title`, and only bindings on that field re-resolve — the
  O(change) doctrine applied within an entry. Keys stay separate from
  the record on the wire; lifting a named field to the key
  (`collection(key="id")`) is binding sugar at insert time. Guest-side,
  the language's own record declaration is the single source of truth:
  a Python dataclass, a Rust #[derive(KayaGen)] struct, a Haskell Generic
  deriving, an OCaml ppx, a C#/Java record class, a Go tagged struct, a
  Swift prototype — the binding derives the wire schema, the
  conversions, and a set of field tokens from that one declaration, so
  schema, insert order, and indexes cannot drift (the same
  single-source move as the spec-driven emitters, applied to app
  types). Field tokens are first-class typed projections (index plus
  value kind, `Todo::DONE : Field<Bool>`) and exist because two sites
  have no record instance to translate: binding a field in template
  position, and updating one field of one entry — in static languages
  they make prop/field type agreement a compile error, the third
  agreeing layer above the scene's declaration-time check and the
  setters' signatures. Fields whose type the wire cannot carry (a
  handler in the record) are guest-only: they live in the guest's model
  — which stores native records; the patch-producing fold means reads
  never translate, and translation happens once per mutation, outbound
  — and never reach the wire. Derives target the encoder, not a value
  tree: record framing and type tags are compile-time constants, so an
  insert is a constant prefix plus spliced payloads, the shape the
  generated property setters already have; dynamic languages precompile
  per-field encoder closures at declaration. Guests run at occurrence
  rate, not frame rate, so this is discipline rather than necessity —
  but it is cheap discipline, pinned by a benchmark leg rather than
  review vigilance. Definition of done: the appendix's todo scene —
  entry, add button, a For of checkbox-plus-label rows, items-left
  label, field-level toggle updates — green on the full matrix from
  every guest.
- Sum-typed elements complete milestone 3: a collection's schema is one
  ordered field-type list per variant of the element sum, and a record
  collection is the one-variant case, exactly as a scalar collection is
  the one-field case — the same degeneracy move, so nothing bifurcates
  and every existing scene stays valid. Variants are indices; variant
  names live in the bindings, like field names, preserving "no hot path
  resolves a name". Entries carry their discriminant: insert and update
  state it ahead of the fields, the core stores it with the record, and
  an update whose variant differs from the stored one tears down that
  entry's stamped copy and restamps it in place from the new
  constructor's case — the When-toggle rebuild applied per entry, which
  the reproducibility rule already licenses. update_field can never
  change a constructor; the whole record necessarily travels when one
  does. Inside a For over a sum, variant_case records split the
  template into one blueprint per constructor. The declaration as a
  whole is an eliminator, and it is checked *total* at template_end:
  the failure a missing case would otherwise cause is data-dependent —
  the first insert of the unlucky constructor, in production, after the
  fourth variant was added and one of three Fors wasn't extended — so
  the check runs at declaration, the earliest point in the system, and
  declaring an empty case is the explicit way to render a constructor
  as nothing. Element bindings inside case v validate against variant
  v's schema: the record milestone's declaration-time guarantee, per
  constructor. Field-type-level sums (a field whose type is itself a
  union) remain future — that is the feature that would finally summon
  Value::Record; element-level sums encode flat behind their tag.
  Guest-side, the language's own sum is the declaration — a Rust enum
  under #[derive(KayaGen)] (shape decides product or sum, like
  derive(Debug)), a sealed interface of records in Java, an abstract
  record family in C#, an OCaml variant, a Haskell sum via Generic, a
  Swift enum with associated values, a Python union of dataclasses, a
  Go sealed marker interface over structs. The template declaration is
  an eliminator and the binding surfaces it as one: a record of arms,
  one named arm per constructor (`PostCases { note: .., todo: .. }`),
  because a product of arm functions *is* the case analysis — so
  wherever the language checks record literals or interface
  implementations for completeness (Rust struct literals, a sealed
  visitor interface in Java/C#, a record of functions in Haskell),
  template totality is a compile error, and the scene's
  declaration-time check remains the backstop for the languages that
  cannot. Sequential per-case builder calls were rejected for exactly
  the gap they leave: each call is a single-variant handler, and only
  the runtime assembles them into a total match. The convergence
  target, per language: the named, completeness-checked record of arms
  wherever the language's metaprogramming can mint one. The marker is
  ONE NAME in every language that has one — KayaGen — and the marked
  declaration's shape decides what derives: a product type is a record
  (factory, typed field tokens, a named-setter patch, and the typed
  row surface — the record template's arm, tokens plus the
  constructors that consume them, no probes at bind time), a sum type
  is a sum (factory, the compile-total eliminator, and one refined
  patch per constructor: asTodo re-eliminates at call time in the
  language's own refinement idiom — comma-ok, ?., Optional, optional
  chaining — so a stale occurrence folds into nothing, with the
  witnessed update underneath). Rust
  (`#[derive(KayaGen)]`) and OCaml (`[@@deriving kaya_gen]`) derive
  natively at compile time; four generators cover the rest, each
  reading the guest's own declaration (the type is the schema; nothing
  is restated) and emitting a checked-in file that tools/gen-guests.sh
  regenerates and holds fresh in the gates. Go's ceiling is
  structural: struct literals are open — an omitted field is a nil
  func, not an error — so its compile-total form is what cmd/kaya-gen
  (a `//go:generate … kaya-gen -type T` directive, the stringer
  tradition; interface = sum, struct = record) emits: a positional
  function with one parameter per constructor, every argument
  required, the literals' parameter types standing as the arm labels.
  Java's annotation processor (tools/java-processor, on `@KayaGen`;
  sealed interface = sum, record = record) generates the staged
  builder — the Immutables idiom for named-and-required; Derive4J
  generates ADT eliminators the same way — where each stage's return
  type offers exactly the next constructor's arm and only the final
  arm yields the widget; records get exact-index field tokens and the
  named-setter patch. C#'s generator (tools/kaya-csgen, Roslyn syntax
  trees over `[KayaGen]` records — abstract = sum, plain = record — a
  standalone CLI rather than an in-build analyzer, so guests stay
  NuGet-free and the VM build compiles plain sources; dunet is the
  in-build precedent) emits an eliminator with one required delegate
  parameter per constructor, named arguments at the call site, and the
  same record surface. Swift's (tools/kaya-swift-gen, swift-syntax
  over `: KayaGen` conformances — an empty marker protocol; enum =
  sum, struct = record — the CasePaths shape, as a CLI rather than a
  macro so guests stay bare swiftc) emits the runtime conformance in a
  generated extension (KayaSumElement's prototypes and
  init(variant:values:), KayaRecord's prototype and init(values:) —
  nothing hand-written), typed field tokens in place of label strings,
  and an eliminator with one required labeled parameter per
  constructor. The typed-token arms product (`Arm<Note>(…)`,
  `arm(Note.class, …)`, prototype tokens) remains the floor the
  generated surfaces compile down to, still checked complete at
  declaration, never later. (TypeScript's
  ts-pattern marks the no-codegen ceiling — type-level union
  subtraction down to `never` — which none of these type systems can
  express; declaration-time checking is the honest floor without
  codegen.)
  Mutation is
  match-refined: a field write on a sum is reachable only through a
  case analysis of the model's current entry, whose arm hands back a
  handle refined to that constructor's fields. Never through a claimed
  tag — a claim is a dynamic cast — and the refinement must be fresh at
  write time because occurrences queue: a handler co-located in one
  constructor's case can run after the guest has already converted the
  entry, and re-eliminating at write time makes the stale arm simply
  not run, the fold-if-applicable answer to that race. The wire's
  update_field still carries the discriminant, as a *witness* of that
  match rather than a claim: the scene asserts it against the stored
  tag, turning every field delta into a consistency check between the
  binding's hand-written model and the core's table — the drift class
  that bit the move ops, structurally guarded at the op where drifting
  would otherwise write a type-correct field of the wrong constructor.
  Definition of done: the feed scene — notes and todos in one
  collection, one case per constructor, a promote handler exercising
  the variant-change restamp, a toggle through the refined patch, a
  derived signal folding over the sum — green on the full matrix from
  every guest.
- The conformance gallery is the definition of done. A widget is admitted
  when its scene passes on every platform, and the scene list grows one
  widget at a time, seeded by the layout-normalization worklist scenes.
- Lowest-common-denominator disputes surface at admission time, while the
  widget's semantics are being normalized across all platforms at once,
  before any single backend's assumptions harden into the API.

## Open questions

The architectural questions raised during design (transport formats,
template encoding, the expression set, `For` with the row window, the
display-list plan, the versioning model, IME contract details, binding and
backend order) are resolved and folded into the sections above. What
remains is implementation-scale:

1. The binding style guide: expand the conventions section into the
   versioned deliverable it commits to. (The former slot-syntax question
   dissolved, since the slot schema is the component function's
   signature.)
2. Shared-arena reclamation: resolved — refcount, shipped with the
   blob channel and the Image widget (see the transport section's blob
   table). The generation alternative lost: the Arc already tracks the
   only fact a generation scheme would approximate, and a stuck
   consumer pins one blob, never an epoch.
3. The Vello scene-encoding subset for v2 display lists (arrives with
   Canvas, after v1).
4. The window vocabulary: resolved — see "Presentation contexts"
   (ratified 2026-07-21). Windows, modal presentations, and navigation
   are three context types with three unmixed lifecycle grammars;
   phase 4 implements windows (primary props, capability-gated
   auxiliaries, the close veto class), alerts landed next, and
   navigation is ratified (core-owned stacks, retained-until-popped
   entries, the intercept_back veto transplant — see the section);
   sections landed too (ratified 2026-07-22, see "Sections (tabs)");
   root-hosting modals remain recorded as future. Milestone 1's
   reserved mount target 0 remains the implicit primary window.

The v1 widget set and the gallery scene list are covered in "v1 scope and
delivery process"; the scene list grows per widget admission.

## Appendix: the shape of an app (Python sugar)

All state at rest is core-owned; the guest language is the transition
function. Bare guest values, like the f-string below, exist only in flight.

```python
app        = kaya.App("Todos")
todos      = app.collection(key="id")   # keyed collection signal
items_left = app.signal("")

def todo_row(row):                      # component function; runs once, at record time
    with kaya.hbox(spacing=8):          # slot schema = the function signature
        kaya.checkbox(checked=row.done, on_toggle=row.toggle)
        kaya.label(text=row.title, grow=1)

with app.window(title="Todos"):
    with kaya.vbox(spacing=12):
        # Uncontrolled: the widget owns its text and reports edits as
        # occurrences; the app folds them into its own state. No read-back.
        entry = kaya.entry(on_change=set_draft)
        kaya.button("Add", on_click=lambda: add(entry))
        kaya.for_each(todos, todo_row)              # For(collection, component fn)
        kaya.label(text=items_left)                 # bound (signal ref)
        kaya.label(text="Todos")                    # constant

draft = ""                                          # plain app state, fed by occurrences

def set_draft(text):
    global draft
    draft = text

def add(entry):
    with app.transaction():                         # atomic multi-signal write
        todos.append({"id": kaya.key(), "title": draft,  # the app's own state
                      "done": False, "toggle": toggle})
        entry.clear()                               # one-shot command
        set_draft("")
        n = sum(1 for t in todos if not t["done"])
        items_left.set(f"{n} item left" if n == 1 else f"{n} items left")

app.run()
```

`kaya.label(text=items_left)` lowers to three builder calls at the C ABI
(`begin_node`, `bind`, `end_node`). The `with` sugar, the tracer, and the
derived-signal helpers are binding-side and invisible below the ABI.

## Practical notes

- The wire format is declared, not described: `KayaRecordHeader` and the
  per-kind record structs (`KayaRecordButtonClicked`, …) are `#[repr(C)]`
  types in the crate, exported through kaya.h (cbindgen needs them in the
  export include list, since no function signature references them, and
  needs constants to be literals — path-valued consts are silently
  dropped, so compile-time asserts pin them to the ring's values). Direct
  consumers cast into the ring instead of bit-twiddling; the Go example
  includes kaya.h, the C# example mirrors the structs.
- `tools/validate-mac.sh` runs all four suites natively on macOS (Rust,
  Python, Go, C# — the .NET SDK is in the flake); the same four run in
  the Windows VM via `tools/deploy-win.sh` and in a Linux container via
  `tools/validate-linux.sh` (Debian + GTK4 + Xvfb; builds happen inside
  the container against its GTK, into target-linux/).
- Binding order: the Rust crate exists by construction (in-process, no
  C ABI). Python is the first foreign binding. It is the slowest guest
  language and has no build-step culture, so it exercises the signal
  substrate exactly as designed, and its GUI options are an underserved
  area. Further bindings are unordered for now.
- The crate name `kaya` is reserved on crates.io (placeholder v0.0.0,
  published 2026-07-12, empty lib). The `repository` field has been added
  to `crates/kaya/Cargo.toml`; add a crate-level README before the next
  publish.
- Toolchain policy: one C toolchain family, LLVM/clang, hardcoded on every
  platform. Supporting multiple C compilers is a non-goal. kaya has no
  C or C++ sources (`windows-rs` and `objc2` generate pure Rust), so the
  C compiler only surfaces in build scripts, linking, and the validation
  suite's cgo. On Windows this means the msvc ABI without the MSVC
  compiler: cargo-xwin drives clang-cl and lld-link against Microsoft's
  own SDK import libraries. The gnu/MinGW ABI is avoided deliberately
  (WinRT import-lib coverage lags, and PDB debugging assumes msvc). The
  flake pins the Rust toolchain with the Windows msvc targets via
  rust-overlay and carries cargo-xwin plus the validation languages.
  Windows CRT policy (settled after trying full `+crt-static` first):
  hybrid linkage via the `static_vcruntime` crate in build.rs — static
  vcruntime, dynamic UCRT. vcruntime is not an OS contract (it arrives
  with the VC++ redist), so it is linked in; the UCRT ships with Windows
  10+ and stays dynamic so the OS keeps servicing it. The crate applies
  to release builds only, which sets the deployment rule: release
  artifacts are self-contained and are what gets deployed or shipped;
  debug builds import vcruntime140.dll and are for machines that have
  it. Verified under clang-cl/lld-link (cargo-xwin), so this coexists
  with the clang-everywhere policy — "requires the MSVC toolchain" in
  that crate's docs means the msvc target family, not cl.exe.
  Alternatives weighed: full static CRT (works, but freezes the UCRT
  copy against OS servicing); the gnu/MinGW target (rejected above on
  ABI grounds); bundling vcruntime140.dll or requiring the redist
  (rejected — reintroduces install steps). One hygiene rule either way,
  already satisfied by the protocol's construction: CRT-owned resources
  (FILE*, memory freed by the other side) never cross the ABI.
- Windows testing runs in a UTM Windows 11 ARM VM on the Apple hypervisor
  (target `aarch64-pc-windows-msvc`), following the portsh playbook
  (~/Projects/portsh/docs/windows-vm.md): OpenSSH server in the guest,
  key auth, artifacts pushed with scp and driven over ssh, VM
  snapshotted once configured. Cross-compile on the host with
  cargo-xwin; the guest only runs binaries and the Python/Go validation
  suite. Automation notes from the first run: `utmctl start` /
  `utmctl exec` (SYSTEM-level guest agent) can bring the VM and sshd up
  headlessly; GUI processes cannot run in the SSH service session, so
  tests run in the console user's session via `schtasks /create /it`
  plus `schtasks /run`, with output redirected to a file and read back.
  `tools/deploy-win.sh user@host [--provision] [rust|python|go|csharp|all]`
  packages the whole flow: artifact push, per-suite scheduled tasks
  (`tools/guest/*.cmd`, CRLF enforced via .gitattributes), output
  polling. The Windows App Runtime installer is a one-time provision
  (`--provision`); Python, Go, and an llvm-mingw ucrt-aarch64 toolchain
  (cgo's C compiler, per the clang-everywhere policy) are one-time winget
  or unzip installs, listed in the script header.
- macOS development needs no Xcode, either the GUI or `xcodebuild`. The
  macOS build links via `objc2` against the SDK from the Command Line
  Tools or nixpkgs' apple-sdk, the SwiftUI interpreter dylib compiles
  with the toolchain's plain `swiftc`, and `cargo run` launches unbundled
  binaries directly, which is sufficient for the conformance gallery. A
  minimal `.app` bundle (scripted, or via `cargo-bundle`) is needed only
  for bundle-identity features: the app-menu name, `Info.plist` behaviors,
  TCC prompts, notifications. Distribution eventually needs the standard
  CLI tail of `codesign` (Developer ID), `notarytool`, `stapler`, and
  `spctl`, plus a one-time GUI certificate setup.
