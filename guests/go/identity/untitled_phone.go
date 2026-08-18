//go:build android || ios

// The phone half of the pair (untitled_desktop.go), and it must stay a
// no-op. A phone host rejects create_window AT THE ROOT — the core's own
// cfg, crates/kaya/src/capi.rs — so a guest that built the window here
// would abort before it ever mounted, with the identity already
// declared: measured on an emulator, "kaya: this host has no auxiliary
// windows (KAYA_CAP_AUX_WINDOWS is unset)" then SIGABRT.
//
// THE NAME IS STILL DECLARED AND STILL READ on these hosts; what changes
// is only where it is read FROM. The untitled window is the desktop's
// blank for it; on a phone the reader is the installed package's own
// label (docs/app-identity-plan.md ruling 3), so the runner drops the
// one step that reads the window instead (tools/android/run-emulator.sh's
// scene_script_drop). tools/scenes/identity.steps is byte-frozen and
// shared verbatim — the cut belongs to the runner, never to the scene.
package identity

import (
	kaya "dev.kaya/bindings/go"
)

func mountUntitled(_ *kaya.Tx) {}
