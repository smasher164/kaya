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
		// The only run-time wall against the rule above.
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
