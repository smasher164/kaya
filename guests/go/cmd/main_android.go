//go:build android

// The Android tail: the OS owns main. AN init() RATHER THAN main(), because
// `-buildmode=c-shared` never calls the main package's main.

package main

import (
	kaya "dev.kaya/bindings/go"
)

func init() { kaya.AndroidMain(androidApp) }

func main() {}

func androidApp() {
	// kaya.Env AND NEVER os.Getenv: a loaded library never sees an envp
	// (tools/check-go-env.py).
	scene := kaya.Env("KAYA_SELFTEST")
	if scene == "" {
		// tools/check-go-env.py holds the kaya.Env rule above.
		scene = defaultScene
	}
	pick(scene)().Serve()
}
