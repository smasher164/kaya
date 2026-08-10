package kaya

// THE ENTRY-POINT CONTRACT, pinned rather than described.
//
// Two properties, both of which are invisible to every compiler and
// unreachable from the matrix:
//
//  1. App.Run BLOCKS UNTIL THE APP IS OVER ON EVERY PLATFORM, including
//     Android. This is the wart kaya refuses: Gio's app.Main "blocks
//     forever" on the desktops and "returns immediately" on Android and
//     iOS, so one call means two things and every line after it is live
//     on one host and dead on another. Nothing in the matrix can catch a
//     regression here, because the whole validation APK ends in
//     App.Serve rather than App.Run.
//  2. WHICH FUNCTION IS THE APP on Android — a registration if the guest
//     made one, otherwise the app's own `main` reached by
//     //go:linkname. The attach entry that decides cannot be called off
//     Android and the linkname does not exist there, so the rule is
//     factored out into androidEntry precisely so a test on this host
//     can drive it.
//
// These run in `go test dev.kaya/bindings/go`, which tools/check-abort.sh
// runs, which tools/gates.sh runs, which tools/validate-mac.sh runs
// whole. The structural half — that the android arm compiles at all and
// that the linkname resolves and is REFERENCED — is
// tools/check-targets.sh's go-android clause.

import (
	"runtime"
	"testing"
	"time"
)

// settle is how long a "did it come back?" assertion waits before
// believing the answer. Generous on purpose: a false PASS here would be
// the test not noticing a regression, and a false FAIL would be a
// flake, so the cost of waiting is the cheaper mistake.
const settle = 250 * time.Millisecond

// TestRunBlocksWhereTheOSOwnsTheEntry is the Android arm. Run must not
// come back while the dispatch loop is running, and must run it on the
// CALLING goroutine — that goroutine is the locked OS thread the attach
// entry made, and the occurrence ring has exactly one consumer.
func TestRunBlocksWhereTheOSOwnsTheEntry(t *testing.T) {
	var app App
	release := make(chan struct{})
	serving := make(chan struct{})
	returned := make(chan int, 1)

	go func() {
		returned <- app.runWith(true, func() {
			close(serving)
			<-release
		}, func() int {
			// kaya_run is a hard panic on Android
			// (crates/kaya/src/capi.rs). Reaching it would mean the
			// hosted arm tried to take a process entry it was never
			// given.
			t.Error("the hosted arm entered the core loop; Android has no process entry to give it")
			return 7
		})
	}()

	<-serving
	select {
	case <-returned:
		t.Fatal("Run came back while the app was still serving — this is Gio's app.Main wart, " +
			"and it is the one thing this arm exists to not do")
	case <-time.After(settle):
	}
	close(release)
	select {
	case code := <-returned:
		if code != 0 {
			t.Fatalf("hosted Run answered %d; there is no process to hand a status to, so it answers 0", code)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Run never came back after the dispatch loop ended")
	}
}

// TestHostedRunServesOnTheCallingGoroutine proves the same-goroutine
// part directly rather than by inference. A panic unwinds ONE
// goroutine: if the hosted arm ran serve where it is supposed to, the
// recover below sees it. If it had spawned one instead, the panic would
// be unrecovered and take the whole test binary down — which is a
// failure too, just a louder one.
func TestHostedRunServesOnTheCallingGoroutine(t *testing.T) {
	var app App
	defer func() {
		switch r := recover(); r {
		case "serve-ran-here":
		case nil:
			t.Fatal("no panic reached this goroutine: the hosted arm did not run serve on it")
		default:
			t.Fatalf("unexpected panic %v", r)
		}
	}()
	app.runWith(true, func() { panic("serve-ran-here") }, func() int {
		t.Error("the hosted arm entered the core loop")
		return 0
	})
	t.Fatal("runWith returned normally; serve did not run on this goroutine")
}

// TestRunBlocksWhereTheGuestOwnsTheEntry is the desktop and iOS arm.
// The two halves run concurrently — the dispatch loop on a second
// goroutine, the core on the caller's thread — and Run waits for BOTH.
// Waiting for the dispatch loop is not decoration: the core loop
// returning is the shutdown, and a Run that raced past it would let the
// guest's `os.Exit` run while the loop was still draining.
func TestRunBlocksWhereTheGuestOwnsTheEntry(t *testing.T) {
	var app App
	releaseServe := make(chan struct{})
	releaseCore := make(chan struct{})
	serving := make(chan struct{})
	returned := make(chan int, 1)

	go func() {
		returned <- app.runWith(false, func() {
			close(serving)
			<-releaseServe
		}, func() int {
			<-releaseCore
			return 3
		})
	}()

	<-serving // the loop is on its own goroutine, concurrent with the core
	close(releaseCore)
	select {
	case <-returned:
		t.Fatal("Run came back with the dispatch loop still running")
	case <-time.After(settle):
	}
	close(releaseServe)
	select {
	case code := <-returned:
		if code != 3 {
			t.Fatalf("Run answered %d, not the core's exit code 3", code)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Run never came back after both halves ended")
	}
}

// TestHostedEntryIsAndroidAndNothingElse keeps the selector honest from
// the other side. hostedEntry decides which arm above is compiled, and
// it is a constant, so a wrong answer is not a bug that shows up
// somewhere — it is every Go guest on this host losing its process
// entry, or Android calling kaya_run and panicking inside the core.
func TestHostedEntryIsAndroidAndNothingElse(t *testing.T) {
	if hostedEntry != (runtime.GOOS == "android") {
		t.Fatalf("hostedEntry is %v on GOOS=%s", hostedEntry, runtime.GOOS)
	}
	if hostedEntry {
		t.Fatalf("these tests run on the desktops; GOOS=%s should own its own entry", runtime.GOOS)
	}
}

// TestAndroidEntryPrefersARegistration pins the rule attach uses to
// decide what to boot. The order is load-bearing in one direction only:
// guests/go/cmd registers an app AND carries `func main() {}`, because
// -buildmode=c-shared demands a main package and one library cannot
// have thirty-one mains — so a linkname that won would boot an empty
// function and the whole Android lane would go dark.
func TestAndroidEntryPrefersARegistration(t *testing.T) {
	// WHICH ONE RAN, not which one it looks like: func values are not
	// comparable in Go, and a code-pointer comparison would be reading
	// the answer through reflection when the question is behavioural.
	var ran string
	registered := func() { ran = "registration" }
	viaLinkname := func() func() { return func() { ran = "main.main" } }

	app, fromMain := androidEntry(registered, viaLinkname)
	if app == nil || fromMain {
		t.Fatalf("a registration must win over main.main (got fromMain=%v)", fromMain)
	}
	ran = ""
	app()
	if ran != "registration" {
		t.Fatalf("attach would boot %q, not the registered app", ran)
	}

	app, fromMain = androidEntry(nil, viaLinkname)
	if app == nil || !fromMain {
		t.Fatalf("with no registration the app's own main must be used (got fromMain=%v)", fromMain)
	}
	ran = ""
	app()
	if ran != "main.main" {
		t.Fatalf("attach would boot %q, not the app's own main", ran)
	}

	// The `!android` reality: guestMain has no linkname to answer with,
	// so there is nothing to boot and attach says so rather than
	// starting a nil.
	app, fromMain = androidEntry(nil, func() func() { return nil })
	if app != nil || fromMain {
		t.Fatalf("with neither source there is no app (got app!=nil=%v fromMain=%v)", app != nil, fromMain)
	}
	if guestMain() != nil {
		t.Fatalf("guestMain answered non-nil on GOOS=%s; the linkname is android-only", runtime.GOOS)
	}
}
