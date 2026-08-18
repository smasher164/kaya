//go:build android

// The Android tail: the OS owns main, so the guest registers here and
// kaya starts it when the shell Activity attaches
// (bindings/go/android.go).
//
// AN init() RATHER THAN main(): `go build -buildmode=c-shared` requires
// exactly one main package and then NEVER CALLS its main — the only
// callable symbols are the cgo exported ones — so a guest that registered
// in main would register nothing.

package main

import (
	kaya "dev.kaya/bindings/go"
)

func init() { kaya.AndroidMain(androidApp) }

// Never called: -buildmode=c-shared has no process entry. It exists
// because the toolchain demands a main package.
func main() {}

func androidApp() {
	// kaya.Env AND NEVER os.Getenv: os.Getenv answers "" here forever, on
	// every leg, because a loaded library never sees an envp.
	// tools/check-go-env.sh's header carries the measurement.
	scene := kaya.Env("KAYA_SELFTEST")
	if scene == "" {
		// AN EMPTY NAME IS ITS OWN ARM, and the only run-time wall
		// against the rule above: it is exactly what the wrong spelling
		// produces here, so it cannot also mean the default scene.
		panic("kaya: KAYA_SELFTEST is empty. On Android that is what " +
			"os.Getenv answers no matter what the host set — Go's copy of " +
			"the environment is filled at process entry, which a loaded " +
			"library never sees. Read it with kaya.Env (C's live getenv). " +
			"If the spelling is already kaya.Env, then the shell really " +
			"did not set it: the leg passes --es KAYA_SELFTEST <scene> and " +
			"MainActivity maps KAYA_* extras through Os.setenv.")
	}
	pick(scene)().Serve()
}
