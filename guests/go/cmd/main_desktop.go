//go:build !android

// The desktop and iOS tail: the guest OWNS the process main thread and
// lends it to kaya. `!android` rather than a list of the platforms that
// have a main, because that is the real rule — Android is the one host
// where the OS owns the entry (Zygote forks the process, ActivityThread
// owns the Looper) and kaya_run is a hard panic. GOOS=ios reaches this
// file, which is what makes the iOS lane's `-buildmode=exe` guests the
// same shape as the desktops'.
//
// ONE BINARY FOR EVERY SCENE, selected here from the environment. Each
// scene used to own a `main` that named its own library and ignored
// KAYA_SELFTEST entirely, so the mac and linux lanes linked thirty-two
// binaries of the same program. Every leg but one already named its
// scene in the environment; this file is what makes that name the thing
// that decides.

package main

import (
	"os"
	"runtime"

	kaya "dev.kaya/bindings/go"
)

func init() {
	// The core must own the process main thread.
	runtime.LockOSThread()
}

func main() {
	// kaya.Env AND NEVER os.Getenv, uniformly with the Android tail even
	// though Go's own copy of the environment is correct on this host:
	// there is one spelling for reading the environment in this tree and
	// tools/check-go-env.sh holds it, because the platform where the
	// other spelling silently answers "" is the platform where nothing
	// else would notice (docs/go-mobile-plan.md D2).
	scene := kaya.Env("KAYA_SELFTEST")
	if scene == "" {
		// AN EMPTY NAME IS MILESTONE2 HERE, AND A PANIC ON ANDROID, and
		// the asymmetry is deliberate. On a desktop an empty
		// KAYA_SELFTEST means somebody launched the guest by hand — `go
		// run dev.kaya/guests/go/cmd` with nothing set — so it gets the
		// default scene, and the bare `run go-swiftui …` leg (which
		// passes KAYA_SELFTEST=1 through run()) lands on the same one by
		// the table's own key. On Android an empty name is what the
		// WRONG SPELLING PRODUCES — os.Getenv answers "" there no matter
		// what the host set — so main_android.go refuses it instead of
		// defaulting, and says why.
		scene = defaultScene
	}
	os.Exit(pick(scene)().Run())
}
