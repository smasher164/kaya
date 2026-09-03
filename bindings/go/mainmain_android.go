//go:build android

// The app's own `main`, reached from a library: `-buildmode=c-shared`
// keeps `main.main` in the .so and never calls it, so the binding pulls
// it with a //go:linkname (docs/go-mobile-plan.md §D3). The build tag is
// deliberate, not forced: untagged, every consumer on every platform
// would need a `main.main` at link time. Nothing compiles this file off
// Android; tools/check-targets.py's go-android clause covers that.
package kaya

// The blank import is what licenses //go:linkname in this file.
import _ "unsafe"

// mainMain is the app's own main function. Bodyless on purpose: the
// linker fills it in from `main.main`.
//
//go:linkname mainMain main.main
func mainMain()

// guestMain hands the attach entry the app's own main to run when no
// guest registered one; its `!android` twin answers nil.
func guestMain() func() { return mainMain }
