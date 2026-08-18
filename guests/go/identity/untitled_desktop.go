//go:build !android && !ios

// THE UNTITLED WINDOW, on the hosts that have one. It declares no title
// at all rather than an empty one: an empty string is a title an app
// WROTE, and the rule under test is what a window with nothing written
// shows — the blank an app's NAME fills.
//
// THE BUILD TAG IS THE SAME PREDICATE THE CORE KEYS ON
// (crates/kaya/src/capi.rs's kaya_capabilities: the phones' systems own
// surface geometry, so KAYA_CAP_AUX_WINDOWS is unset there and
// create_window is a deterministic scene error), spelled as Go spells a
// per-platform body — the pair-file idiom bindings/go already uses for
// logcat and for main. guests/rust/identity.rs takes the `#[cfg]` form
// of this same predicate; neither can drift from the core, because both
// name the platforms the core names.
package identity

import (
	kaya "dev.kaya/bindings/go"
)

func mountUntitled(tx *kaya.Tx) {
	untitled := tx.CreateWindow(1).Size(360, 240)
	aux := tx.Column(func() {
		caption := tx.Signal("no title of its own")
		tx.Label(caption) // label#2
	})
	tx.MountIn(untitled.Id(), aux)
}
