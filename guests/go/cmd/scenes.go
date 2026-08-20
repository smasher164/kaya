// The Go guests' one entry package: a scene table, and two tails that
// differ only in who owns `main` (main_desktop.go, main_android.go).
//
// ONE ARTIFACT CARRIES EVERY SCENE, ON EVERY PLATFORM, and the leg names
// the one it wants in KAYA_SELFTEST. Android forces the shape:
// `-buildmode=c-shared` produces one .so per main package
// (docs/go-mobile-plan.md D3). So the scenes are LIBRARIES — one
// directory each, package named for the scene, `App()` handing back a
// built app.
package main

import (
	kaya "dev.kaya/bindings/go"

	"dev.kaya/guests/go/a11y"
	"dev.kaya/guests/go/a11yrows"
	"dev.kaya/guests/go/align"
	"dev.kaya/guests/go/assets"
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
	"dev.kaya/guests/go/identity"
	"dev.kaya/guests/go/layout"
	"dev.kaya/guests/go/menus"
	"dev.kaya/guests/go/milestone2"
	"dev.kaya/guests/go/nav"
	"dev.kaya/guests/go/panels"
	"dev.kaya/guests/go/panes"
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
	"dev.kaya/guests/go/toolbar"
	"dev.kaya/guests/go/typeface"
	"dev.kaya/guests/go/undo"
	"dev.kaya/guests/go/window"
)

// defaultScene is what an EMPTY KAYA_SELFTEST means on a desktop and
// nowhere else; main_android.go refuses an empty name instead. "1" is
// milestone2's name, which the legs all still pass.
const defaultScene = "1"

// scenes is keyed by the name the leg passes in KAYA_SELFTEST. EVERY
// SCENE THE GO TREE HAS IS IN IT, including the ones a given host cannot
// run: an unsupported scene should die on the capability gate that
// rejects it, naming what it could not do, rather than in pick().
var scenes = map[string]func() *kaya.App{
	"1":          milestone2.App,
	"a11y":       a11y.App,
	"a11yrows":   a11yrows.App,
	"align":      align.App,
	"assets":     assets.App,
	"background": background.App,
	"clipboard":  clipboard.App,
	"commands":   commands.App,
	"confirm":    confirm.App,
	"dirty":      dirty.App,
	"editor":     editor.App,
	"entry":      entry.App,
	"feed":       feed.App,
	"filedialog": filedialog.App,
	"gallery":    gallery.App,
	"grid":       grid.App,
	"grow":       grow.App,
	"identity":   identity.App,
	"layout":     layout.App,
	"listdetail": split.App,
	"menus":      menus.App,
	"nav":        nav.App,
	"panels":     panels.App,
	"panes":      panes.App,
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
	"toolbar":    toolbar.App,
	"typeface":   typeface.App,
	"undo":       undo.App,
	"window":     window.App,
}

// pick is the half of the selector both hosts share: a name that is not
// in the table is a WIRING BUG, and it dies here naming itself. The
// EMPTY name is the arm the two tails answer differently.
func pick(scene string) func() *kaya.App {
	build, carried := scenes[scene]
	if !carried {
		panic("kaya: no scene named " + scene + " in this artifact — the runner " +
			"asked for a leg the guest does not carry")
	}
	return build
}
