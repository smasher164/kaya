//go:build android

// The Android tail: the OS owns main, so the guest is registered here
// and STARTED by kaya when the shell Activity attaches
// (android/milestone2go/.../MainActivity.kt -> KayaGo.attach ->
// bindings/go/android.go).
//
// AN init() RATHER THAN main(), and that is not a style choice.
// `go build -buildmode=c-shared` requires exactly one main package and
// then NEVER CALLS its main — the only callable symbols are the cgo
// //export ones. A guest that registered in main would register nothing,
// and attach would panic saying so.
//
// THE SCENE TABLE IS SHARED WITH THE DESKTOP TAIL (scenes.go), and the
// APK carries every scene in it — one .so, thirty-one scenes, the leg
// naming one. This file and main_desktop.go are the same package and
// differ in exactly two things: who owns the entry, and what an EMPTY
// KAYA_SELFTEST means.

package main

import (
	kaya "dev.kaya/bindings/go"
)

func init() { kaya.AndroidMain(androidApp) }

// Never called: -buildmode=c-shared has no process entry. It exists
// because the toolchain demands a main package, and a main package
// demands a main.
func main() {}

// androidApp is the whole guest on this host: one artifact carries
// every scene, the leg names one through KAYA_SELFTEST, and the app
// runs it on the thread kaya started.
func androidApp() {
	// kaya.Env AND NEVER os.Getenv, and this line is the reason the
	// milestone exists. Go's runtime fills its environment from the
	// envp handed to the PROCESS ENTRY; a library that System.loadLibrary
	// pulled into a running app never saw one, so os.Getenv answers ""
	// here forever while C's getenv reads the live environ the shell
	// wrote with Os.setenv. It works on iOS — Go owns main there — so
	// the natural build order tests the broken spelling where it is not
	// broken. tools/check-go-env.sh is the static half of this rule; the
	// empty arm below is the run-time half.
	scene := kaya.Env("KAYA_SELFTEST")
	if scene == "" {
		// AN EMPTY NAME IS ITS OWN ARM, and it is the ONLY run-time wall
		// against the whole failure class above. The desktop tail lets an
		// empty string mean the default scene, because there it means
		// somebody launched the app by hand. Here it is what a WRONG
		// SPELLING looks like — os.Getenv returns exactly this, on every
		// leg, forever — so refusing it separately is what turns "ran
		// the wrong scene and failed every step for the wrong reason"
		// into "died naming the cause".
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
