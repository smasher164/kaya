// The Go guests' one entry package: a scene table, and two tails that
// differ only in who owns `main` (main_desktop.go, main_android.go).
//
// ONE ARTIFACT CARRIES EVERY SCENE, ON EVERY PLATFORM, and the leg
// names the one it wants in KAYA_SELFTEST. Android forced the shape and
// the desktops keep it because it is better there too:
//
//   - Android has no choice. `-buildmode=c-shared` produces one .so per
//     main package, and the shell picks its library at load time — so
//     thirty-one scene guests would be thirty-one c-shared libraries in
//     one APK, measured at 2.6 MB each, ~83 MB of native code on top of
//     libkaya's 30 MB (docs/go-mobile-plan.md D3 step 3; scratchpad
//     go-android-compose.md §6.3 B priced it).
//   - The desktops used to link thirty-two binaries per lane, 84 MB of
//     target/go-guests, because each scene owned a `main`. They were
//     the same program with a different last line.
//
// So the scenes are LIBRARIES — one directory each, package named for
// the scene, `App()` handing back a built app — and this package is the
// only `main` in the tree beside guests/go/encodebench, which is a
// benchmark rather than a scene.
package main

import (
	kaya "dev.kaya/bindings/go"

	"dev.kaya/guests/go/a11y"
	"dev.kaya/guests/go/a11yrows"
	"dev.kaya/guests/go/align"
	"dev.kaya/guests/go/background"
	"dev.kaya/guests/go/clipboard"
	"dev.kaya/guests/go/commands"
	"dev.kaya/guests/go/confirm"
	"dev.kaya/guests/go/dirty"
	"dev.kaya/guests/go/editor"
	"dev.kaya/guests/go/entry"
	"dev.kaya/guests/go/feed"
	"dev.kaya/guests/go/filedialog"
	"dev.kaya/guests/go/gallery"
	"dev.kaya/guests/go/grid"
	"dev.kaya/guests/go/grow"
	"dev.kaya/guests/go/layout"
	"dev.kaya/guests/go/menus"
	"dev.kaya/guests/go/milestone2"
	"dev.kaya/guests/go/nav"
	"dev.kaya/guests/go/panels"
	"dev.kaya/guests/go/progress"
	"dev.kaya/guests/go/radio"
	"dev.kaya/guests/go/ranges"
	"dev.kaya/guests/go/reorder"
	"dev.kaya/guests/go/save"
	"dev.kaya/guests/go/scroll"
	"dev.kaya/guests/go/sections"
	selectscene "dev.kaya/guests/go/select"
	"dev.kaya/guests/go/split"
	"dev.kaya/guests/go/stall"
	"dev.kaya/guests/go/styling"
	"dev.kaya/guests/go/textarea"
	"dev.kaya/guests/go/todos"
	"dev.kaya/guests/go/typeface"
	"dev.kaya/guests/go/undo"
	"dev.kaya/guests/go/window"
)

// defaultScene is what an EMPTY KAYA_SELFTEST means on a desktop, and
// nowhere else — main_desktop.go is the only caller and states the
// asymmetry; main_android.go refuses an empty name instead, for a
// reason that is true only there.
//
// "1" is milestone2's name for a historical reason worth keeping: the
// selftest flag's original spelling, from before the value doubled as a
// scene selector. The Rust and JVM guests spell it the same way, and
// the legs pass it.
const defaultScene = "1"

// scenes is what this artifact carries, keyed by the name the leg
// passes in KAYA_SELFTEST. A TABLE RATHER THAN A SWITCH, because it is
// data: the legs arm adds a leg by finding its name here, and a gate
// can read one key per line without parsing Go.
//
// EVERY SCENE THE GO TREE HAS IS IN IT, including the ones a given host
// cannot run. That is the JVM host's stated rule
// (android/milestone2kt/.../MainActivity.kt:83-87) and it is the right
// one for the same reason: a scene registered but unsupported dies on
// the capability gate that rejects it — create_window for `window` and
// `panels`, resize_window for `split` — naming the thing it could not
// do. A scene left OUT would die in pick() instead, saying the artifact
// does not carry it, which is a true sentence about the wrong subject.
// WHETHER A LEG RUNS ONE IS NOT THIS TABLE'S QUESTION:
// tools/check-stubs.sh reads the backend, never a selector.
var scenes = map[string]func() *kaya.App{
	"1":          milestone2.App,
	"a11y":       a11y.App,
	"a11yrows":   a11yrows.App,
	"align":      align.App,
	"background": background.App,
	"clipboard":  clipboard.App,
	"commands":   commands.App,
	"confirm":    confirm.App,
	"dirty":      dirty.App,
	// THE FORCING ARTIFACT (docs/editor-plan.md): not a conformance
	// scene but an APP, carried here like every other because a scene is
	// how the matrix owns it — byte-frozen output compared across
	// platforms, and a leg wherever it can run.
	"editor":     editor.App,
	"entry":      entry.App,
	"feed":       feed.App,
	"filedialog": filedialog.App,
	"gallery":    gallery.App,
	"grid":       grid.App,
	"grow":       grow.App,
	"layout":     layout.App,
	// One app behind both list-detail scripts, the shape the Rust and
	// JVM hosts already have: `split` drives resize_window and is
	// desktop-only, `listdetail` is the bare invariant at whatever
	// width the device picked.
	"listdetail": split.App,
	"menus":      menus.App,
	"nav":        nav.App,
	"panels":     panels.App,
	"progress":   progress.App,
	"radio":      radio.App,
	"ranges":     ranges.App,
	"reorder":    reorder.App,
	"save":       save.App,
	"scroll":     scroll.App,
	"sections":   sections.App,
	"select":     selectscene.App,
	"split":      split.App,
	"stall":      stall.App,
	"styling":    styling.App,
	"textarea":   textarea.App,
	"todos":      todos.App,
	"typeface":   typeface.App,
	"undo":       undo.App,
	"window":     window.App,
}

// pick is the half of the selector both hosts share: a name that is not
// in the table is a WIRING BUG, and it dies here naming itself.
//
// It used to run milestone2 instead, on both the Go and the JVM APK,
// and that is a silent wrong scene: the leg launches, a scene runs
// happily, and every step of the script the runner asked for fails
// against labels from a scene nobody selected. The EMPTY name is the
// arm the two tails answer differently, so it is theirs, not this
// function's.
func pick(scene string) func() *kaya.App {
	build, carried := scenes[scene]
	if !carried {
		panic("kaya: no scene named " + scene + " in this artifact — the runner " +
			"asked for a leg the guest does not carry")
	}
	return build
}
