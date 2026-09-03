// Android's attach surface for a Go guest: the JNI entry a shim Activity
// calls on the UI thread, and the two ways it learns what to boot — a
// registration (AndroidMain) or the app's own `main` (mainmain_android.go,
// docs/go-mobile-plan.md §D3). THE SYMBOL NAME IS THE WHOLE CONTRACT with
// KayaGo.kt: the short JNI name carries no argument mangling, so exactly
// ONE native `attach`. NOT BUILD-TAGGED, so every build type-checks this.
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

// androidApp is written once from an init(); androidAttached is the
// build-once latch, read and written inside attach. No lock either way:
// loadLibrary, which finishes every package init, happens-before the
// onCreate that attaches, and every onCreate runs on the one UI thread.
var (
	androidApp      func()
	androidAttached bool
)

// AndroidMain names the function kaya boots when the shim Activity
// attaches; only a library carrying SEVERAL apps needs it, since an
// ordinary app writes one main.go and kaya finds its main
// (docs/go-mobile-plan.md §D3). Call it from an init(), not from main:
// `-buildmode=c-shared` never calls the library's main, so a
// registration there registers nothing. `app` ends in App.Run().
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
func androidEntry(registered func(), fromMainMain func() func()) (app func(), fromMain bool) {
	if registered != nil {
		return registered, false
	}
	app = fromMainMain()
	return app, app != nil
}

// Java_dev_kaya_KayaGo_attach is Android's entry, called by the shim
// Activity from onCreate ON THE UI THREAD: it starts the guest on its
// own thread and returns this one to the Looper. The three JNI arguments
// are unused — a JNIEnv belongs to the thread it was handed to.
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
		// A LATER onCreate RE-ATTACHES ONLY (docs/deferred.md's mount
		// entry, ruled 2026-08-27): the guest is the PROCESS's and the
		// Activity is only the current window.
		return presentGuest
	}
	// The stale-artifact guard rides kaya_run on the desktops and so
	// never runs here; the APK's jniLibs only ever accumulates.
	checkSpec()
	androidAttached = true
	go func() {
		defer androidReport()
		// The app thread must be a REAL OS THREAD: it parks inside a C
		// call (kaya_wait_occurrences) and the ring is single-consumer.
		// The ONLY LockOSThread on this host: a package init here runs on
		// the library's main goroutine, which exits when initialization
		// finishes and takes the locked thread with it.
		runtime.LockOSThread()
		app()
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
