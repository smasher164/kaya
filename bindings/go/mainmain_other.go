//go:build !android

// The `!android` half of the main.main pull (mainmain_android.go).
//
// EVERY OTHER PLATFORM GIVES THE GUEST ITS OWN PROCESS ENTRY — mac,
// linux, windows and iOS all run the guest as `-buildmode=exe`, Go owns
// `main`, and `main.main` is called by the runtime the ordinary way. So
// there is nothing to pull here, and pulling anyway would be worse than
// useless: an untagged `//go:linkname mainMain main.main` makes every
// consumer of this binding need a `main.main` at link time, on platforms
// where kaya never calls it.
//
// This file exists so that android.go — which is UNTAGGED, so that every
// `go build` on every platform type-checks the attach surface — has a
// guestMain to name.
package kaya

// guestMain answers nil off Android: there is no second entry point to
// find, because the guest's own main was never taken away from it.
//
// Unreachable in practice rather than merely unused: the only caller is
// Java_dev_kaya_KayaGo_attach, and nothing outside an Android app has
// any way to call that.
func guestMain() func() { return nil }
