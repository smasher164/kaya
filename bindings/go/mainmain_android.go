//go:build android

// The app's own `main`, reached from a library: `-buildmode=c-shared`
// keeps `main.main` in the .so and never calls it, so the binding pulls
// it with a //go:linkname. Reasoning: docs/go-mobile-plan.md §D3.
//
// WHY THIS FILE IS BUILD-TAGGED, when android.go deliberately is not.
// It was MEASURED that the tag is not forced: an untagged bodyless
// `func mainMain()` with this directive links clean in a darwin
// `-buildmode=exe` and an android `-buildmode=c-shared` alike. It is
// tagged because untagged would make EVERY consumer of this binding, on
// every platform, need a `main.main` at link time — an invisible
// constraint imposed on all five platforms for one platform's benefit.
// The cost of the tag is the hole android.go names: nothing compiles
// this file until somebody cross-builds for Android. That hole is closed
// by tools/check-targets.py, which cross-compiles this package for
// android/arm64 AND LINKS a single-main fixture against it on every gate
// sweep — a real compile of the real arm, which is more than type
// checking would have given.
package kaya

// The blank import is what licenses //go:linkname in this file.
import _ "unsafe"

// mainMain is the app's own main function. Bodyless on purpose: the
// linker fills it in from `main.main`.
//
//go:linkname mainMain main.main
func mainMain()

// guestMain hands the attach entry the app's own main to run when no
// guest registered one; its `!android` twin answers nil. Deleting this
// file is a build failure ("undefined: guestMain"), which is the
// property tools/check-targets.py's go-android clause watches.
func guestMain() func() { return mainMain }
