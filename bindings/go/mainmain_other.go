//go:build !android

// The `!android` half of the main.main pull (mainmain_android.go).
package kaya

func guestMain() func() { return nil }
