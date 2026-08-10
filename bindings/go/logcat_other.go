//go:build !android

// The `!android` half of the panic-visibility pair (logcat_android.go).
//
// Every other platform already shows a Go panic: the guest owns the
// process, fd 2 is a terminal or a lane's log file, and the runtime's
// own text is what the lane reads. There is nothing to add and nothing
// to recover, so this is a no-op — and it must stay one, because a
// deferred recover that did nothing useful would still turn a panic
// into a recovered panic and change what the desktops print.
package kaya

// androidReport does nothing here. It exists so bindings/go/android.go
// stays untagged and type-checked by every `go build` on every
// platform, the same reason guestMain has a twin.
func androidReport() {}
