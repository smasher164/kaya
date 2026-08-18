//go:build !android

// The desktop and iOS tail: the guest OWNS the process main thread and
// lends it to kaya. `!android` rather than a list of the platforms that
// have a main, because that is the real rule — Android is the one host
// where the OS owns the entry and kaya_run is a hard panic. GOOS=ios
// reaches this file.
//
// ONE BINARY FOR EVERY SCENE, selected here from the environment.

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
	// though Go's own copy is correct on this host: one spelling in this
	// tree, held by tools/check-go-env.sh.
	scene := kaya.Env("KAYA_SELFTEST")
	if scene == "" {
		// AN EMPTY NAME IS MILESTONE2 HERE AND A PANIC ON ANDROID: on a
		// desktop it means somebody launched the guest by hand, while on
		// Android it is what the WRONG SPELLING produces
		// (main_android.go says so).
		scene = defaultScene
	}
	os.Exit(pick(scene)().Run())
}
