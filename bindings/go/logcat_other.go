//go:build !android

// The `!android` half of the panic-visibility pair (logcat_android.go).
// Must stay a no-op: a deferred recover here would turn a panic into a
// recovered panic and change what the desktops print.
package kaya

func androidReport() {}
