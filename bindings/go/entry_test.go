package kaya

// The entry-point contract (docs/go-mobile-plan.md §D3): App.Run blocks
// until the app is over on EVERY platform including Android, and
// androidEntry decides which function is the app. Both are invisible to
// every compiler and unreachable from the matrix, which ends in
// App.Serve rather than App.Run. The structural half — the android arm
// compiling and the linkname resolving — is tools/check-targets.py.

import (
	"runtime"
	"testing"
	"time"
)

// How long a "did it come back?" assertion waits before believing it.
const settle = 250 * time.Millisecond

// The Android arm. Run must not come back while the dispatch loop is
// running, and must run it on the CALLING goroutine — that goroutine is
// the locked OS thread attach made, and the ring has one consumer.
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
			// kaya_run is a hard panic on Android (capi.rs).
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

// The same-goroutine part, directly: a panic unwinds ONE goroutine, so
// the recover below sees it only if serve ran here.
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

// The desktop and iOS arm: the dispatch loop on a second goroutine, the
// core on the caller's thread, and Run waits for BOTH — a Run that
// raced past the loop would let the guest's os.Exit run mid-drain.
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

func TestHostedEntryIsAndroidAndNothingElse(t *testing.T) {
	if hostedEntry != (runtime.GOOS == "android") {
		t.Fatalf("hostedEntry is %v on GOOS=%s", hostedEntry, runtime.GOOS)
	}
	if hostedEntry {
		t.Fatalf("these tests run on the desktops; GOOS=%s should own its own entry", runtime.GOOS)
	}
}

// The rule attach uses to decide what to boot. guests/go/cmd registers
// an app AND carries `func main() {}`, so a linkname that won would
// boot an empty function and the whole Android lane would go dark.
func TestAndroidEntryPrefersARegistration(t *testing.T) {
	// Which one RAN: func values are not comparable in Go.
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

	// The `!android` reality: guestMain has no linkname to answer with.
	app, fromMain = androidEntry(nil, func() func() { return nil })
	if app != nil || fromMain {
		t.Fatalf("with neither source there is no app (got app!=nil=%v fromMain=%v)", app != nil, fromMain)
	}
	if guestMain() != nil {
		t.Fatalf("guestMain answered non-nil on GOOS=%s; the linkname is android-only", runtime.GOOS)
	}
}
