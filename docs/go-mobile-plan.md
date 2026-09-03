# Go on iOS and Android — the design pass

Status: LANDED — iOS 2026-08-07 (`0e35bd8`), Android 2026-08-07
(`19cd5ef`), the one-main.go entry point 2026-08-09 (`aeb135a`). D4's
"done" is met: Go legs on both phone lanes, running the shared scene
scripts. §2's three carried-out findings stay open in docs/deferred.md.

Ratified by the maintainer 2026-08-07: **Go becomes kaya's second
five-platform guest language, before the text editor is written.** The
reason is the editor's own purpose — an editor written in Rust would be
kaya testing itself, sharing the core's language, types and
assumptions, and every place a BINDING is awkward or wrong would stay
invisible. The forcing artifact has to go through a binding.

Evidence base (2026-08-07, four arms, every claim tagged
measured/documented/assumed): docs/probes/mobilepkg-contract.md,
-go.md, -csharp.md, -python.md, -threading.md.

## §0 — what the research settled

- **Coverage at the time**: mac 9 languages, linux 8, windows 5, **iOS 3
  (Rust, Swift, C), Android 2 (Rust, Java)**. Only Rust ran on all
  five, so kaya's uniform-semantics promise was unverified on mobile for
  six languages. Each mobile platform HAD already hosted a second guest
  language — evidence that the rest is tooling, not architecture.
  THIS MILESTONE CLOSED IT FOR GO: both phone lanes carry Go legs now
  (tools/ios/run-sim.py, and android/gohost on the emulator), so
  Go is the second language to run on all five.
- **Threading is not the blocker for any candidate.** The guest has
  never run on the UI thread on any platform: it runs on its own
  blockable thread and talks to the interface through a byte transport.
  kaya does not need the guest to own the event loop, nor C to call
  into the language on a foreign thread — it needs ONE THREAD THAT CAN
  BLOCK INSIDE A C CALL. No FATAL cell in the compatibility matrix.
- **Go already runs on iOS.** Measured: the unmodified
  `guests/go/milestone2`, the real binding, the real `libkaya.a`, the
  real interpreter dylib and the real shared step script produced the
  same verdict string as the Rust and Swift legs on the simulator. Two
  `#cgo` lines were the only change.
- **Android's mechanisms are all measured** in a real app process: a Go
  `c-shared` `.so` loading under the app's linker, a cgo `//export`
  JNI entry called from `onCreate` on the UI thread, spec hashes
  matching, and a Go app goroutine building and submitting a scene on
  its own OS thread with `kaya_next_commands` returning resolved ops.
- **No gomobile.** `go build -buildmode=exe` (iOS) and `-buildmode=
  c-shared` (Android) reach the platforms directly, with no extra tool
  and no extra pin.
- Rejected with reasons: **C#** (iOS proven — 27 of 32 scenes green
  under NativeAOT — but Android's only matching shape is an
  experimental `linux-bionic` NativeAOT library with no android RID, no
  Java interop, and an open async-signal-safety defect);
  **Python** (official on both since 3.13, but a 36 MB iOS support
  bundle, a third-party gradle plugin, and per-module framework
  packaging). Both stay candidates for a LATER second slice, which the
  research says costs far less once this machinery exists.

## §1 — the decisions

### D1 — Go's artifact per platform, and no new tool

iOS: `-buildmode=exe`, the guest owns `main` and calls `kaya_run` on
thread 0 — the shape iOS already uses for Rust and Swift. Android:
`-buildmode=c-shared`, loaded by a shim Activity that attaches and
boots the guest runtime on a thread it starts — the shape the JAVA
guest already uses today (`MainActivity.kt`), generalized.

### D2 — the empty-environment guard (the trap this milestone found)

In a Go `c-shared` library `os.Getenv` is **permanently empty**: Go's
runtime fills its environment from the process entry, which a loaded
library never sees, while C's `getenv` sees the live values. kaya picks
its scene from `KAYA_SELFTEST`, so the idiomatic Go spelling would run
the wrong scene on EVERY Android leg — and the existing
unknown-scene-name panic would not fire, because empty is not unknown,
it is the default arm. **It works on iOS**, where Go owns `main`, so
the natural build order tests the broken call where it is not broken.
The binding therefore exposes the environment through kaya (reading C's
view), the guests use that instead of `os.Getenv`, and a gate keeps
`os.Getenv` out of the guests — watched failing, per invariant 3.

### D3 — sequencing: iOS first (a depth slice), Android second (a small milestone)

iOS is a copy of an existing runner block driving builds that already
work. Android is: the attach surface + the environment guard (the only
design work), then one gradle module and shim Activity with milestone2
green, then the scene-library split, then the leg fan-out. The split is
the long pole because it touches the desktop lanes' invocation shape
and invariant 6's byte-identical strings.

### D5 — the entry point: one main.go for an app, a registration for a library

Ratified 2026-08-09, after reading how Gio and gomobile solve it
(docs/probes/goentry-gio.md §1, goentry-fyne.md §1) and measuring the
mechanism under the toolchain kaya pins.

**An app author writes ONE main.go, with no build tags and no second
entry point**, ending in the same line on all five platforms:

```go
func main() { os.Exit(build().Run()) }
```

The mechanism is Gio's: `-buildmode=c-shared` keeps `main.main` in the
library and never calls it, so the binding reaches into the app's
package for it with a bodyless declaration and a `//go:linkname`
(`bindings/go/mainmain_android.go`), and the JNI attach starts it on the
locked OS thread it already made. Nothing else about the Android story
changes — the Kotlin shell, the Compose interpreter, the ring, the
`kaya.Env` rule and the D2 guard are all untouched.

**kaya refuses Gio's wart.** `app.Main` "blocks forever" on the desktops
and "returns immediately" on Android and iOS, so one call means two
things and every line after it is live on one host and dead on another.
`App.Run` BLOCKS ON EVERY PLATFORM and answers the exit code. What
differs underneath is only who owned the process entry: off Android it
dispatches on a second goroutine and hands the caller's thread to
`kaya_run`; on Android the caller IS the app thread, so it dispatches
there and comes back when the core shuts down (exit code 0 — there is no
process to hand a status to). The arms are selected by
`runtime.GOOS == "android"` as a CONSTANT, so both are type-checked
everywhere and one is compiled. Pinned by tests, not by comment:
`bindings/go/entry_test.go`.

**Two shapes, because one of them has to exist.** `-buildmode=c-shared`
allows exactly one main package per `.so`, so one library has exactly
one `main.main` — and kaya's validation artifact is one library carrying
thirty-one scenes. That artifact registers its entry with
`kaya.AndroidMain` from an `init()` (`guests/go/cmd/main_android.go`); an
ordinary app does not, and gets the linkname. Attach prefers a
registration when both are present, because the registration is a
statement and `main.main` is what every main package has whether it
means anything or not.

**The consequence for the test suite, stated plainly**: the matrix
exercises the REGISTRATION path and cannot exercise the other one.
`tools/check-targets.py`'s go-android clause is what covers the
linkname — it cross-builds a single-main fixture as `-buildmode=c-shared`
on every gate sweep and asserts the attach entry still references the
app's own main.

**`runtime.LockOSThread` moved into the binding** so that a guest's
main.go carries no platform knowledge: an `init()` under
`!hostedEntry` claims the process main thread on the four platforms that
have one, and the Android app thread is locked by the attach entry
instead — a package init there runs on a goroutine that exits when
initialization ends, and would take the thread with it.

**A Go panic on Android reached nobody**, measured the same day: the
runtime writes to fd 2 and exits, an app process has no stderr, and the
whole logcat of a crash was one line saying the process died. Every wall
the Go binding has on this platform is a panic — including D2's
empty-environment guard — so `bindings/go/logcat_android.go` recovers on
kaya's two Android goroutines, writes the message and stack to logcat
under the tag the lane already reads, and re-raises.

### D4 — what "done" means

Go legs on the iOS and Android lanes running the same shared scene
scripts as every other language, byte-compared, in the matrix. Not a
demo: legs the lanes demand, that check-steps holds open if a guest
exists without one.

## §2 — carried out of the research, not part of this milestone

Three guard-shaped findings, recorded in docs/deferred.md:
1. **The handle bindings' liveness check tests `closed` but not the
   thread** (go/app.go, csharp/KayaApp.cs) — a C# `async` handler walks
   straight through it. A live gap in a guard we already rely on, on
   desktop, today.
2. CPython's `PyGILState_Ensure`-during-finalization hang compounds the
   known exit hang in harness.rs.
3. Signal-handler ordering becomes a three-way negotiation (Rust std's
   stack guard, the guest runtime, the host crash reporter) that nobody
   currently owns.
