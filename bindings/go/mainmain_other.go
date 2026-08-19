//go:build !android

// The `!android` half of the main.main pull (mainmain_android.go).
// Exists so android.go stays untagged and type-checks on every platform.
package kaya

func guestMain() func() { return nil }
