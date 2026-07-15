# kaya design notes

Status: the architecture is settled; there is no implementation yet.

kaya is a cross-platform GUI library that wraps each platform's native
widgets behind a single API. This document records the architectural
decisions, the reasoning behind them, and the alternatives that were
rejected. Where a decision looks unusual, the rejected-alternatives section
explains what it was tested against.

## Premise and constraints

1. Native widgets, not custom drawing. kaya creates and manages real
   platform widgets (`NSView`, WinUI controls, `GtkWidget`, Android views).
   Flutter, egui, and Slint make the opposite bet and draw every pixel
   themselves.
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

| Platform | Backend | Notes |
|----------|---------|-------|
| macOS    | AppKit; plus the SwiftUI backend (shared with iOS, see the iOS row) as a first-class leg. | First backend, since it has the fastest iteration loop for development. |
| iOS      | UIKit and SwiftUI, both first-class backends validated from milestone 0 onward. | SwiftUI exposes no object model — views are compile-time generic value types — so unlike Android's JNI route a SwiftUI backend is an interpreter written in Swift mapping kaya's scene onto SwiftUI declarations. The alignment is unusually good: kaya signal maps to an @Observable property, `When` to `if`, `For` to `ForEach`, templates to view builders, and SwiftUI's source-of-truth model is exactly kaya's core-owned signals, so the shim is closer to transliteration than translation (SwiftUI's own diff is what native apps pay anyway). The payoff is the SwiftUI-only surface: WidgetKit, the current design language, each year's newest controls. The friction is at the imperative edges — `focus()` via @FocusState, `scrollTo()` via ScrollViewReader, ref handles in a value-typed world, UIViewRepresentable escapes for the IME contract — each mappable, each bespoke. The SwiftUI backend (tools/swiftui) is a milestone-0 leg validated alongside everything else: the scene as SwiftUI speaking the protocol over the presentation-side C API — kaya_emit_* for occurrences out of action closures, and a blocking kaya_next_commands pump (the mirror of kaya_next_occurrence; no polling, no callbacks) hopping to the main actor to write @Observable state, with SwiftUI's invalidation as the render path. It passes the self-test in the iOS Simulator and natively on macOS from the same Swift file — one presentation layer serves both Apple platforms. Critically, the validated composition is the product scenario: the unchanged milestone-0 examples drive it via runtime backend selection — all four guest languages on macOS, and on iOS the Rust example's own main is the bundle executable with the SwiftUI dylib loaded from inside the bundle (the rust-swiftui leg). No app logic is written in Swift anywhere; app developers shipping on Apple platforms do not write Swift. This also establishes the guest-language-backend contract in miniature: the presentation-side C API is the same protocol with the roles swapped, exclusive with kaya_run per process. The imperative edges (focus, scrollTo, ref handles) get measured as real widgets arrive, per feature, breadth-first like every other backend. A backend written in Swift is fine — the Android backend will carry Kotlin/Java shim components regardless; backends may be thick, bindings must stay thin. The general pattern stands: every platform has a language-locked declarative layer (SwiftUI, Compose) over an object-model layer (UIKit, Android Views); kaya v1 validates both layers on Apple platforms (UIKit/AppKit and SwiftUI), and the object-model layer elsewhere. The milestone-0 skeleton passes in the simulator, validated from Rust and from Swift over the C ABI (swiftc imports kaya.h directly via -import-objc-header — zero re-declarations; Swift's C interop is free, so the function floor is already optimal and the direct-ring tier buys nothing there). iOS specifics: UIApplicationMain never returns, the delegate reaches its channel ends through a slot, the self-test exits the process (legitimate: on iOS kaya is the process), sendActionsForControlEvents drives the real action path, and simulator builds are unsigned — tools/ios/run-sim.sh boots, installs, launches with SIMCTL_CHILD_ env, and screenshots via simctl. It shares most of the AppKit bridge layer and has the same protocols where it matters: `UITextInput` for IME, UIKit accessibility, Core Animation compositing, and pull-based `UITableView` virtualization. The platform-specific wrinkle is the suspension lifecycle ("save state now"), which falls into the occurrence-plus-deadline class. Building and deploying to a device from a Linux host is feasible with xtool-style SwiftPM cross-compilation; the Simulator still requires macOS. |
| Windows  | WinUI 3 via `windows-rs`/COM, with no bridge language needed. The bet is validated: the milestone-0 skeleton (window, button, label, ring round trip) runs on Windows 11 ARM from pure Rust. Bindings are generated by windows-bindgen from the App SDK winmd (tools/winui-bindgen); a plain `Application` with no subclass suffices, with the scene built from a deferred dispatcher callback; `DispatcherQueue::TryEnqueue` is the doorbell; the bootstrap DLL is loaded dynamically (`MddBootstrapInitialize2`). All milestone-0 validations pass in the VM with clean exit codes: Rust exe, Python over the function floor, and two direct-ring consumers — Go (llvm-mingw cgo against the msvc-ABI dll) and C# (P/Invoke for the calls, `Volatile.Read`/`Write` on the ring), which together validate the exposed ring layout from both an unmanaged-FFI and a managed runtime. Shutdown lessons, learned the hard way: exit goes through `Application::Exit`; after `Start` returns, XAML COM references must be leaked rather than dropped (Rust TLS destructors run during process exit on Windows and releasing into the dead apartment is an access violation); `MddBootstrapShutdown` must be called while the process is healthy or `Microsoft.UI.Xaml.dll` crashes during `DLL_PROCESS_DETACH` in hosted processes; and `kaya_run` returns the exit code rather than exiting, because a library must not tear down its host process — hosts join their app thread before exiting (a daemon thread re-entering CPython during finalization crashes). WinUI requires an interactive desktop session, so SSH-driven runs go through a `schtasks /it` task, which matters for CI later. Win32 common controls remain the fallback but are no longer expected to be needed. WPF is possible later through hostfxr and a C# shim. |
| Linux    | GTK4 via gtk4-rs. Linux has no OS-native toolkit; GTK is the conventional stand-in. The milestone-0 skeleton runs the same architecture: `glib::idle_add` (g_idle_add) is the doorbell, the clicked signal feeds the occurrence sink, and the self-test drives the real signal path via `emit_clicked`. GTK teardown is orderly (none of WinUI's exit ceremony); the process exit code flows through `run_core` like the other backends. The backend contains no display-protocol-specific code; GTK4's GDK backends provide both X11 and Wayland, and validation exercises both — seven language suites (the usual four, plus C itself over the function floor, plus OCaml and Haskell on the direct ring) run under Xvfb (X11) and under headless Weston (Wayland) in a Debian container (tools/validate-linux.sh), unattended, since Linux has no interactive-session constraint. |
| Android  | Platform views over a JNI bridge (jni-rs), plus a Jetpack Compose backend as the SwiftUI sibling, both validated at milestone 0. | Hosting is fully inverted — stricter than iOS, which at least requires a native executable: Zygote forks the process, ActivityThread owns main, and code enters at Activity.onCreate. So the milestone-0 packaging is a cdylib, not a bin: `kaya::android_main!(app)` exports the one JNI entry (`dev.kaya.Kaya.attach` — every Android app is the attach shape, and the shell spells it out), a minimal Kotlin Activity loads the library and calls `Kaya.attach(this)` on the UI thread, and the native side builds the scene, spawns the app thread, and returns the thread to the Looper. The same app logic file serves the bin platforms and this leg (examples/milestone0_android.rs is a two-line repackaging of milestone0.rs). The backend drives android.widget through JNI; its Kotlin half is three small classes (the entry declaration plus click-listener and Runnable shims) whose natives are registered with RegisterNatives rather than resolved by name, so the guest library's only name-based export is the entry. The doorbell is a posted no-data Runnable through runOnUiThread; kaya's env-based switches keep one spelling because the Activity maps KAYA_* intent extras to environment variables (`am start --ez KAYA_SELFTEST true` is this platform's `KAYA_SELFTEST=1 ./app`). Lessons that cost a debugging session each: never hold a lock across a JNI call that can dispatch back into native code (performClick reaches the click handler synchronously on the same thread — the handler uses its own clone of the occurrence sink, the same shape as a GTK signal closure); and exit through `_exit`, because libc exit runs atexit handlers that destroy HWUI's mutexes while its render threads still run. The Compose backend mirrors the SwiftUI one move for move — kaya signal to snapshot state (`mutableStateOf`, recomposition renders), occurrences out of onClick, commands through a blocking kaya_next_commands pump hopping to the UI thread — over the same presentation-side C API, reached through registered JNI natives (KayaPresent) since Kotlin cannot call C directly; runtime backend selection (KAYA_BACKEND=compose) picks it with the unchanged Rust example as the guest, exactly like the rust-swiftui leg. The JVM is the platform's direct-ring validation, and it surfaced two ART bugs the hard way: ART's byte-buffer-view VarHandle path truncates a direct buffer's native address to 32 bits in the interpreter (var_handle.cc casts the address through uint32_t), so the canonical VarHandle-over-NewDirectByteBuffer idiom faults on any real heap address; and ART's Unsafe (Object, long) volatile accessors are heap-field-only — a null base goes through a 32-bit MemberOffset and faults — so the OpenJDK null-base absolute-address idiom does not exist either. The formulation that works, and the one the Java guest ships: Unsafe absolute plain loads/stores plus explicit loadFence/storeFence (documented in libcore as the C11 atomic_thread_fence equivalents), bound once as MethodHandles (Unsafe is absent from the SDK stubs) and invoked through invokeExact so the per-record path stays free of boxing and reflection. When ART fixes the VarHandle truncation, the fence formulation can be swapped for acquire/release views (API 33+); the fence formulation itself only needs MethodHandles, API 26+. Either way the tier is the same as desktop Go and C#: direct reads on the data path, functions only for waiting and for commands. Validation runs headless in the emulator (tools/android/run-emulator.sh): SDK, NDK, emulator, JDK, and Gradle all come from nix (androidenv, license accepted declaratively), three suites — rust (Views), jvm (Java over the ring), compose — with verdicts read from logcat (stdout goes nowhere in an app process; android_logger + log-panics route Rust output there) and screenshots via screencap. Python and Go guests are deferred to the packaging milestone: interpreted and compiled guests on Android need binding bootstrap (briefcase, gomobile), which is its own subject. |

Raw Win32 common controls have no layout system at all (`WM_SIZE` and
manual pixel placement). That is an additional argument for WinUI, because
the layout strategy below assumes each backend has a real native layout
engine.

## Core object model

- The core owns a retained tree of widget records. Each record owns its
  native handle (`NSView *`, WinUI element, `GtkWidget *`).
- Widgets are identified by slotmap-style generational ids (slot index plus
  generation), never by pointers. Generations exist to catch the ABA
  problem: a stale id whose slot was reused must be detectably dead rather
  than wrongly alive. They are not a leak-prevention mechanism; leaks are
  prevented by removal bookkeeping. Ids cross FFI easily, and foreign
  languages will hold stale handles, so with generational ids a stale
  handle is a catchable error instead of use-after-free undefined behavior
  in someone's runtime. Multi-language bindings are the strongest argument
  for generational ids.
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
silent no-op.

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
mirror reads and one-shot commands.

There is one trap: closures invite the Flutter intuition that the function
re-runs on every state change. As a guardrail, the recorder flags any
mirror read (`.value()`) inside a recording scope with an error telling the
author to bind the signal or take it as a parameter.

The encoding at the C ABI is a builder API (`begin_node`, `set_prop`,
`bind_slot`, `end_node`). Templates are small and built rarely, so the
encoding optimizes for binding simplicity. The builder records into the
canonical serialized form, and submitting a prebuilt buffer is equally
legal; that is the path server-driven UI and tooling use. Node properties
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

A cross-language style guide is a versioned deliverable due before v1. The
rules that keep bindings mutually recognizable have to be written down
somewhere; Wayland ships protocol conventions for the same reason. Settled
rules so far:

- A canonical method vocabulary for derived signals: `eq`, `ne`, `lt`,
  `fmt`, and so on, method-shaped in every language (`count.eq(0)`,
  `count.Eq(0)`). Documentation leads with the methods so that tutorials
  translate line for line. Operator overloading (Python's `count == 0`) is
  optional per-language sugar, and its sharp edges get documented:
  hijacking `__eq__` breaks naive hashing and identity comparison, the
  familiar SQLAlchemy and pandas trade-off. Derived signals are maintained
  by the binding, recomputed at write time and batched into the same
  transaction; the core never knows about them.
- Values in handlers, signals in templates. `.value()` reads a mirror
  snapshot, which is correct in transition code and a frozen-branch bug in
  template position. Statically typed bindings enforce this at compile
  time, since `When` takes a `Signal[bool]` and not a `bool`; dynamic
  bindings check at record time.
- Handlers receive their transaction, explicitly as in Go
  (`func(tx *Tx)`) or ambiently as in Python. The surface varies per
  language; the semantics are fixed by the protocol's rule that a handler
  is a transaction.
- Components are functions taking slot proxies and returning node
  descriptions, run once to record. Reuse is function reuse.
- Pick one property-configuration style per language (functional options
  or config structs; Go UI DSLs have gone both ways) and do not mix them
  within a binding.

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
spacing, wrap points, baselines) stay platform-flavored. The known
normalization worklist:

- `hidden` means collapsed (occupies no space) everywhere. GTK collapses,
  AppKit reserves space, XAML distinguishes Collapsed from Hidden.
- A defined overflow policy. Platforms variously clip silently, refuse to
  shrink windows, or break constraints by priority.
- Grow distribution normalized to explicit weights.
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
  construction. A general-purpose anchorless `kaya_attach` for desktop
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
  compiled guests (the UIKit leg's bundle executable is milestone0.rs's
  main, and the rust-swiftui leg validates a Rust entry dispatching to
  the SwiftUI backend dlopen'd from inside the bundle), and means
  interpreted guests need their binding's native bootstrap as main. On
  desktop either composition works with any backend.
- Backends are runtime-selectable: KAYA_BACKEND=swiftui routes both
  kaya::run and kaya_run to the SwiftUI backend (environment selection is
  the interim mechanism — fine on desktop and via SIMCTL_CHILD_ in the
  simulator, but real iOS devices don't pass user environment to apps, so
  the shipping mechanism becomes an Info.plist key or compiled-in
  configuration), so the unchanged milestone-0 examples run against
  either backend — validated for all four guest languages on macOS and
  for the Rust example on iOS. The dylib handoff taught a structural lesson: a
  guest-language backend must receive the host's functions as an
  explicit vtable (KayaHostApi, passed to kaya_swiftui_run) rather than
  bind kaya symbols through the dynamic linker, because hosts may carry
  kaya statically (a Rust executable) or load it RTLD_LOCAL (ctypes),
  and a process can otherwise end up with two kaya instances talking
  past each other. The vtable pins the live instance by construction
  and is the seed of the guest-language-backend contract. Class-3
  runtimes in a shell-hosted app get a bootstrap owned by their binding,
  written once, conforming to the entry contract and owning VM boot and
  thread discipline internally; PyInstaller's bootloader and BeeWare's
  briefcase are the precedents, and CPython officially supports iOS as of
  3.13 (PEP 730). App developers see none of this in any composition.
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
    no record is dropped. The core reads the app's consumer cursor
    directly, so stall detection ("log undrained for N seconds") requires
    no protocol.
  - Slots: seqlock cells for keep-latest traffic, one per channel. A write
    is an overwrite and no queue exists; watchers get an optional
    coalesced wake record, at most one pending per slot. Present state,
    demand, and the app-readable widget-state mirror are all slots: one
    mechanism in three roles.
  - A shared-memory arena for bulk payloads (row batches, pixel surfaces,
    audio, templates), referenced by offset and length.

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
a plain property. Not core: webview (a separate crate, if ever), rich text
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
  insertion order, reorder ops are future vocabulary. Definition of
  done, as always: a scene exercising both operators — a nested For with
  per-group items and a When toggle — green on the full matrix from
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
2. Shared-arena reclamation: a generation or refcount scheme for bulk
   payloads.
3. The Vello scene-encoding subset for v2 display lists (arrives with
   Canvas, after v1).
4. The window vocabulary, in full: create_window and per-window mount
   targets, lifecycle (CloseRequested and the veto default, Present,
   Close), sizing and titles, dialogs and modality, and the per-platform
   capability story for mobile (where the primary surface is OS-given
   and extra windows range from real to unsupported). Milestone 1
   reserves the mount target with 0 as the implicit default window so
   none of this breaks the wire when it lands.

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
  AppKit backend links via `objc2` against the SDK from the Command Line
  Tools or nixpkgs' apple-sdk, and `cargo run` launches unbundled AppKit
  binaries directly, which is sufficient for the conformance gallery. A
  minimal `.app` bundle (scripted, or via `cargo-bundle`) is needed only
  for bundle-identity features: the app-menu name, `Info.plist` behaviors,
  TCC prompts, notifications. Distribution eventually needs the standard
  CLI tail of `codesign` (Developer ID), `notarytool`, `stapler`, and
  `spctl`, plus a one-time GUI certificate setup.
