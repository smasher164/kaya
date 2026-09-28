//go:build !android

// The desktop and iOS tail: the guest OWNS the process main thread.
// `!android` because Android is the one host where the OS owns the entry.

package main

import (
	"fmt"
	"os"
	"path/filepath"
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
		scene = bundledScene()
	}
	if len(os.Args) > 1 && os.Args[1] == "--print-scene" {
		fmt.Println(scene)
		return
	}
	os.Exit(pick(scene)().Run())
}

// bundledScene is the scene a per-scene bundle's executable is named after:
// a process the platform starts inherits no KAYA_SELFTEST (docs/traps.md,
// the cold notification reply of 2026-09-27). tools/lib/lanes/mac.py's
// build_go asks every bundle with --print-scene.
func bundledScene() string {
	if exe, err := os.Executable(); err == nil {
		if _, ok := scenes[filepath.Base(exe)]; ok {
			return filepath.Base(exe)
		}
	}
	return defaultScene
}
