// Android's attach surface for a Go guest: the JNI entry a shim
// Activity calls on the UI thread, and the two ways it learns what to
// boot — a registration (AndroidMain) or the app's own `main`, pulled
// out of the app's package by mainmain_android.go. The hosting is
// inverted here (Android has no native process entry, so kaya_run
// panics and the app enters at onCreate): docs/go-mobile-plan.md §D3.
//
// THE SYMBOL NAME IS THE WHOLE CONTRACT with
// android/kaya/src/main/kotlin/dev/kaya/KayaGo.kt, resolved by name out
// of the guest's own .so; tools/android/run-emulator.sh checks it. The
// short JNI name carries no argument mangling, so that class must
// declare exactly ONE native `attach` — an overload makes both
// unresolvable until the names carry their signatures.
//
// THIS FILE IS NOT BUILD-TAGGED, deliberately: untagged, every `go
// build` on every platform type-checks the attach surface, at the cost
// of one dead exported symbol off Android. Only the `//go:linkname`
// pull had to be tagged, and it lives in mainmain_android.go.
package kaya

/*
// DELIBERATELY EMPTY. A file carrying //export has its preamble copied
// into two generated C files, so it may contain declarations only —
// never a definition.
*/
import "C"

import (
	"runtime"
	"unsafe"
)

// presentGuest mirrors PRESENT_GUEST in crates/kaya/src/android.rs.
const presentGuest int32 = 1

// Written once from an init(), read once from the UI thread inside
// attach, so no lock: Go finishes every package init while the library
// is loading, and loadLibrary happens-before the onCreate that attaches.
var (
	androidApp      func()
	androidAttached bool
)

// AndroidMain names the function kaya boots when the shim Activity
// attaches. Only a library carrying SEVERAL apps needs it (one .so has
// exactly one main.main); an ordinary app writes one main.go and kaya
// finds its main. The two shapes: docs/go-mobile-plan.md §D3.
//
// Call it from an init(), not from main: `-buildmode=c-shared` never
// calls the library's main, so a registration in main registers nothing.
//
//	func init() { kaya.AndroidMain(app) }
//
// `app` runs on the app thread and ends in App.Run().
func AndroidMain(app func()) {
	if app == nil {
		panic("kaya: AndroidMain was handed a nil app")
	}
	androidApp = app
}

// androidEntry answers which function is the app, and whether it came
// from the app's own `main` rather than a registration. A REGISTRATION
// WINS — guests/go/cmd's `main.main` is `func main() {}` beside its
// init's AndroidMain call, so the other order boots an empty function.
// Taking both sources as arguments is what makes the rule testable off
// Android (app_test.go's TestAndroidEntryPrefersARegistration).
func androidEntry(registered func(), fromMainMain func() func()) (app func(), fromMain bool) {
	if registered != nil {
		return registered, false
	}
	app = fromMainMain()
	return app, app != nil
}

// Java_dev_kaya_KayaGo_attach is Android's entry, called by the shim
// Activity from onCreate ON THE UI THREAD. It starts the guest on a
// thread of its own and returns that thread to the Looper.
//
// The three JNI arguments are accepted and unused: KayaRing.attach took
// kaya's Android anchor on this same thread already, and a JNIEnv
// belongs to the thread it was handed to, which is about to go back to
// the Looper.
//
//export Java_dev_kaya_KayaGo_attach
func Java_dev_kaya_KayaGo_attach(env, class, activity unsafe.Pointer) int32 {
	_, _, _ = env, class, activity
	// Every wall below is a panic, and a Go panic on Android is silent
	// unless something logs it first (logcat_android.go).
	defer androidReport()
	app, fromMain := androidEntry(androidApp, guestMain)
	if app == nil {
		// Reachable only where guestMain has no linkname to answer with,
		// i.e. a non-Android build. Kept because this file is untagged.
		panic("kaya: no app to start — an Android guest either registers one " +
			"with kaya.AndroidMain(app) from an init() (a library carrying " +
			"several apps) or lets kaya run its own main (an ordinary app, " +
			"one main.go, no build tags)")
	}
	if androidAttached {
		// Reachable by rotating the device (onCreate re-runs); a second
		// guest would consume the single-consumer ring from two threads.
		panic("kaya: already attached — onCreate ran twice (a configuration " +
			"change recreates the Activity); the shell must not attach a " +
			"second time")
	}
	// The stale-artifact guard rides kaya_run on the desktops and so
	// never runs here; the APK's jniLibs only ever accumulates.
	checkSpec()
	androidAttached = true
	go func() {
		defer androidReport()
		// The app thread must be a REAL OS THREAD: it parks inside a C
		// call (kaya_wait_occurrences) and the ring is single-consumer.
		// This is the ONLY LockOSThread on this host — the desktops get
		// theirs from the binding's init (runtime.go), which is skipped
		// here because a package init runs on the library's main
		// goroutine, and that goroutine exits when initialization
		// finishes, taking the locked thread with it.
		runtime.LockOSThread()
		app()
		// An app that SERVED and then returned quit, which is ordinary.
		// Returning without ever serving is `func main() {}` — a main
		// package whose author expected something else to be the entry
		// — and on Android nothing is watching, so kaya says it.
		if !served.Load() {
			shape := "kaya ran the app's own main (main.main) and it returned " +
				"without serving"
			if !fromMain {
				shape = "the function given to kaya.AndroidMain returned without " +
					"serving"
			}
			panic("kaya: " + shape + " — an Android guest ends in App.Run(), " +
				"which blocks here exactly as it does on every other platform. " +
				"A library that carries several apps registers one with " +
				"kaya.AndroidMain from an init(); an ordinary app writes one " +
				"main.go and lets kaya find its main.")
		}
	}()
	return presentGuest
}
