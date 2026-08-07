// Android's attach surface for a Go guest: the JNI entry a shim
// Activity calls on the UI thread, and the registration that names what
// it boots.
//
// THE HOSTING IS INVERTED HERE and that is the only reason this file
// exists. On the desktops and iOS the guest owns main and lends it to
// kaya (App.Run -> kaya_run). Android has no native process entry —
// Zygote forks the process and ActivityThread owns main — so kaya_run
// is a hard panic there (crates/kaya/src/capi.rs:815-818) and the app
// enters at Activity.onCreate. The Activity calls in, kaya starts the
// guest on a thread of its own, and the UI thread goes straight back to
// the Looper. Nothing about the guest's own code changes: kaya's guest
// has never run on the UI thread on any platform (DESIGN.md:2332-2334),
// it runs on its own blockable thread and talks to the interface
// through a byte transport.
//
// THE CONTRACT WITH THE KOTLIN SIDE, in full, because the shim lives in
// android/ and this file is what it has to match — KayaRing.kt's own
// shape, one line longer:
//
//	object KayaGo {
//	    @JvmStatic external fun attach(activity: Activity): Int
//	}
//
// resolved BY NAME out of the guest's own .so, which is why the symbol
// is spelled Java_dev_kaya_KayaGo_attach here and why it lives in the
// binding rather than in each guest — a name the guest could retype is
// a name that can drift from the class that declares it, and the
// failure is an UnsatisfiedLinkError on a device rather than anything a
// gate could see.
//
// Three details that decide whether the two sides meet:
//
//   - `object` + `@JvmStatic` makes it a STATIC method on
//     dev.kaya.KayaGo, so JNI passes (JNIEnv*, jclass, jobject
//     activity). An instance method would pass (JNIEnv*, jobject this,
//     jobject activity) — the same three pointers, so either resolves,
//     but static is what KayaRing does and what the doc below assumes.
//   - The short symbol name carries NO argument mangling, so the class
//     must declare exactly one native `attach`. An overload makes both
//     unresolvable until the names carry their signatures.
//   - jint is int32_t and JNICALL is empty on Android, so the JNI
//     signature IS (void*, void*, void*) -> int32_t at the ABI. cgo's
//     plain spelling below is that, and no jni.h is involved anywhere.
//
// The shim's four lines, in order, and every one of them load-bearing:
//
//	System.loadLibrary("kaya")     // libkaya.so, from jniLibs
//	System.loadLibrary("<guest>")  // the Go c-shared .so; Go's ELF
//	                               // constructors run here and the Go
//	                               // runtime boots on a thread it makes
//	KayaRing.attach(this)          // registers the KayaPresent natives
//	                               // the Compose pump needs; it takes
//	                               // NO core ends, so the occurrence
//	                               // sink stays OccSink::Ring — which
//	                               // is exactly what a direct-ring
//	                               // consumer like Go wants
//	KayaCompose.mount(this)        // the interpreter and its pump
//	KayaGo.attach(this)            // HERE
//
// That is the JVM guest's shape with one line changed, which is the
// whole point: android/milestone2kt/.../MainActivity.kt:29-90 already
// does loadLibrary + KayaRing.attach + KayaCompose.mount and then
// starts the guest on a thread it makes (`Thread(scene, "kaya-app")`).
// A Go guest cannot be started by `new Thread` because the JVM has no
// way to call a Go function, so the thread is started on the Go side
// and the JNI entry is what asks for it.
//
// THIS FILE IS NOT BUILD-TAGGED, deliberately. A //go:build android
// constraint would mean nothing compiles this surface until somebody
// cross-builds for Android, and cfg-gated code that no ordinary build
// compiles is precisely the hole tools/check-targets.sh exists to
// patch on the Rust side ("a trait method missed in gtk.rs alone used
// to survive every fast gate and die in the matrix"). Untagged, every
// `go build` of every Go guest on every platform type-checks it, which
// is the most basic thing anyone does here. The cost is one dead
// exported symbol in the desktop and iOS binaries.
package kaya

/*
// DELIBERATELY EMPTY. A file carrying //export has its preamble copied
// into two generated C files, so it may contain declarations only —
// never a definition. Nothing here needs either: the JNI types are
// spelled in Go below.
*/
import "C"

import (
	"runtime"
	"unsafe"
)

// presentGuest is attach's answer to the Kotlin side's "who presents?"
// — always the Compose interpreter, because there is one backend per
// platform. The mirror of PRESENT_GUEST in crates/kaya/src/android.rs.
const presentGuest int32 = 1

// The guest's app function and whether a thread is already running it.
// Written once from an init(), read once from the UI thread inside
// attach, so no lock: Go finishes every package init while the library
// is loading, and loadLibrary happens-before the onCreate that attaches.
var (
	androidApp      func()
	androidAttached bool
)

// AndroidMain names the function kaya boots when the shim Activity
// attaches. Call it from an init() in the guest's main package:
//
//	func init() { kaya.AndroidMain(app) }
//	func main() {}  // never called: -buildmode=c-shared has no entry
//
// AN init() RATHER THAN main() IS NOT A STYLE CHOICE. `go build
// -buildmode=c-shared` requires exactly one main package and then never
// calls its main — the only callable symbols are the cgo //export ones
// — so a guest that did its registration in main would register
// nothing and attach would find no app.
//
// `app` runs on the app thread and does exactly what a desktop guest's
// main does minus the process exit: build the scene, register the
// handlers, and end in App.Serve(). It is the same function shape the
// JVM guest hands `new Thread(...)` (guests/java/.../Milestone2.java's
// `static void app()`, ending in app.dispatchLoop()).
func AndroidMain(app func()) {
	if app == nil {
		panic("kaya: AndroidMain was handed a nil app")
	}
	androidApp = app
}

// Java_dev_kaya_KayaGo_attach is Android's entry, called by the shim
// Activity from onCreate ON THE UI THREAD. It starts the guest on a
// thread of its own and RETURNS THAT THREAD to the Looper — the
// host-owns-the-loop shape every Android app has by construction.
//
// It answers with who presents, the same jint Kaya.attach answers, but
// the shim has already mounted by then and does not branch on it: the
// order above is the JVM guest's PROVEN one (mount, then start the
// guest), and the value is a fingerprint rather than a decision. Both
// orders work — a transaction submitted before the pump exists waits in
// the channel — and this is the one that is green in the matrix today.
//
// The three JNI arguments are accepted and unused. kaya's Android
// anchor — the JavaVM and the global reference to dev.kaya.KayaPresent,
// which a thread attached later cannot resolve for itself — was already
// taken by KayaRing.attach on this same thread
// (crates/kaya/src/android.rs:107-118), so there is nothing left here
// for a Go guest to capture, and capturing a JNIEnv would be wrong
// anyway: a JNIEnv belongs to the thread it was handed to, and this one
// is about to go back to the Looper.
//
//export Java_dev_kaya_KayaGo_attach
func Java_dev_kaya_KayaGo_attach(env, class, activity unsafe.Pointer) int32 {
	// Named and discarded, the way crates/kaya/src/android.rs:85 spells
	// the same thing (`let _ = &activity;`): the arguments are part of
	// the contract even where this tier has no use for them.
	_, _, _ = env, class, activity
	if androidApp == nil {
		panic("kaya: no app registered — a Go guest for Android calls " +
			"kaya.AndroidMain(app) from an init(), because -buildmode=c-shared " +
			"never calls main")
	}
	if androidAttached {
		// A SECOND GUEST WOULD BE SILENT AND WRONG: it would build the
		// scene again over the top of the first one and consume the same
		// single-consumer occurrence ring from two threads. Android
		// re-runs onCreate on a configuration change, so this is
		// reachable by rotating the device — the Activity has to survive
		// that itself (android:configChanges, or a process-scoped
		// holder), and kaya says so rather than quietly doubling.
		panic("kaya: already attached — onCreate ran twice (a configuration " +
			"change recreates the Activity); the shell must not attach a " +
			"second time")
	}
	// The stale-artifact guard, which on the desktops rides kaya_run and
	// therefore never runs here. It is worth MORE on Android than
	// anywhere else: the APK's jniLibs is a checked-in directory that
	// only ever accumulates, so a libkaya.so from another tree is the
	// easy mistake, and the ring records would decode against the wrong
	// constants with nothing to say about it.
	checkSpec()
	androidAttached = true
	app := androidApp
	go func() {
		// The app thread is a REAL OS THREAD, locked for the same reason
		// every other language's is: it parks inside a C call
		// (kaya_wait_occurrences -> a pthread condvar) and the ring is
		// single-consumer. Locking also keeps any later JNI work on one
		// thread rather than scattering AttachCurrentThread across the
		// runtime's Ms.
		runtime.LockOSThread()
		app()
	}()
	return presentGuest
}
