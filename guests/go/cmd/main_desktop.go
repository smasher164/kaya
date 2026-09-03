//go:build !android

// The desktop and iOS tail: the guest OWNS the process main thread.
// `!android` because Android is the one host where the OS owns the entry.

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
	// kaya.Env AND NEVER os.Getenv, uniformly with the Android tail.
	scene := kaya.Env("KAYA_SELFTEST")
	if scene == "" {
		// An empty name PANICS on Android (main_android.go says why).
		scene = defaultScene
	}
	os.Exit(pick(scene)().Run())
}
