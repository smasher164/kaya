//go:build android

// The app's own `main`, reached from a library. This file is the whole
// mechanism behind kaya's single-main.go Go app on Android, and it is
// four lines of it.
//
// THE PROBLEM. `go build -buildmode=c-shared` requires exactly one main
// package and then NEVER CALLS its main: the process entry belongs to
// Zygote and ActivityThread, the library is pulled in by
// System.loadLibrary, and the only symbols anything can call are the cgo
// //export ones. Go keeps `main.main` in the library — the runtime's own
// `runtime.main` still references it (runtime/proc.go pulls it with
// `//go:linkname main_main main.main` and returns early instead of
// calling it under `isarchive || islibrary`) — but nothing on the JVM
// side has any way to name it.
//
// THE FIX, and it is not kaya's invention. `//go:linkname` on a BODYLESS
// declaration is a pull: it makes the linker resolve this package's
// `mainMain` to the symbol `main.main`, which is the app's own main
// function, in a package this one does not and cannot import. Gio does
// exactly this in gioui.org/app/runmain.go and states the problem in the
// same words ("Android only supports non-Java programs as c-shared
// libraries. Unfortunately, Go does not run a program's main function in
// library mode"); golang.org/x/mobile resolves the same symbol with
// `dlsym(RTLD_DEFAULT, "main.main")` at load time instead, which trades a
// build-time failure for a run-time one.
//
// WHY A FUNC VALUE RATHER THAN A CALL. guestMain hands back `mainMain`
// as a value and android.go calls it through that value. Gio's runmain.go
// carries the reason as a comment on the identical line — "Indirect call,
// since the linker does not know the address of main when laying down
// this package" — and the shape is worth keeping even if a modern linker
// would cope: the call site (android.go) is UNTAGGED and type-checked by
// every `go build` on every platform, which is only possible if what it
// names is an ordinary func value with a `!android` counterpart.
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
// by tools/check-targets.sh, which cross-compiles this package for
// android/arm64 AND LINKS a single-main fixture against it on every gate
// sweep — a real compile of the real arm, which is more than type
// checking would have given.
package kaya

// The blank import is what licenses //go:linkname in this file. Nothing
// here calls into unsafe; the directive is a compiler/linker instruction
// and the import is its permit.
import _ "unsafe"

// mainMain is the app's own main function. Bodyless on purpose: the
// linker fills it in from `main.main`. (A bodyless declaration compiles
// here because the package has cgo files, so `go build` does not pass
// -complete to the compiler.)
//
//go:linkname mainMain main.main
func mainMain()

// guestMain hands the attach entry the app's own main to run when no
// guest registered one. Its `!android` twin (mainmain_other.go) answers
// nil, so android.go's call site type-checks on every platform.
//
// DELETING THIS FILE IS A BUILD FAILURE, not a silent fallback: the
// twin's build tag is `!android`, so an android build with this file
// gone has no guestMain at all and stops at "undefined: guestMain".
// That is the property tools/check-targets.sh's go-android clause
// watches, and it is why the two halves are a function pair rather than
// a package variable one of them assigns.
func guestMain() func() { return mainMain }
