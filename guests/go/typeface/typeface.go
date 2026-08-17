// The typeface conformance scene from Go (docs/styling-plan.md Slice
// 2b): the brand typeface swaps the FAMILY and leaves the platform's
// ramp alone.
//
// One call is the whole surface — a family name, plus the per-platform
// rows a lane needs — and everything after it is ordinary widgets, which
// is the claim the scene makes: a typeface is chrome, so the field still
// takes text and the button still fires. What it does NOT do is name a
// size anywhere. Sizes, weights and metrics stay the platform's; the
// role tier is what carries emphasis (RoleHeading on the title label
// below), and that is exactly what makes a family swap safe.
//
// WHY A BUNDLED FONT, and why no kaya.PlatformFamily row: the reasoning
// is in guests/rust/typeface.rs's doc comment, which is the canonical
// note for this scene. In short, the scene requests the VENDORED font's
// bytes so the resolved family is one string on every lane and no
// platform's fallback can equal it. kaya.FontBytes is Go's spelling of
// the blob form; kaya.PlatformFamily is what a name-based app would
// reach for instead, and this scene needs none.
//
// The byte-frozen contract is tools/scenes/typeface.steps.
package typeface

import (
	"fmt"
	"os"

	kaya "dev.kaya/bindings/go"
)

// App builds the scene and hands it back ready to be served.
//
// THE TAIL IS THE ONLY THING THAT DIFFERS BY PLATFORM, and it differs
// because the hosting does: a desktop or iOS guest owns the process
// main thread and lends it to kaya (guests/go/cmd/main_desktop.go),
// while on Android the OS owns main and kaya starts the guest on a
// thread of its own (guests/go/cmd/main_android.go). Both tails are
// one package over one scene table, so everything above them — the
// transaction, the handlers, the strings — is compiled into every
// platform's artifact from these bytes.
func App() *kaya.App {
	app := kaya.NewApp()

	var status kaya.Signal[string]
	// The fold: widget-owned state arrives as occurrences, and the app's
	// copy is this variable rather than a widget read.
	draft := ""

	app.Build(func(tx *kaya.Tx) {
		// BEFORE THE FIRST MOUNT, per the set-once wall: brand is
		// identity, not state, and a backend never sees a typeface it
		// would have to un-apply.
		// THE VENDORED BYTES, then the family they carry: the blob
		// registers with the platform's app-font machinery and the
		// "Sora" request resolves to it — register-then-resolve, the
		// same call a brand book's licensed font would make.
		//
		// kaya.Env, never os.Getenv: this package is compiled into the
		// Android artifact too, where Go's copy of the environment is
		// empty forever (bindings/go/runtime.go, tools/check-go-env.sh).
		fontPath := kaya.Env("KAYA_FONT_FILE")
		if fontPath == "" {
			fontPath = "guests/assets/fonts/sora-wght.ttf"
		}
		font, err := os.ReadFile(fontPath)
		if err != nil {
			panic(fmt.Sprintf(
				"kaya: the typeface scene needs the vendored font at %s "+
					"(set KAYA_FONT_FILE or run from the repo root): %v",
				fontPath, err))
		}
		tx.BrandTypeface("Sora", kaya.FontBytes(font))
		tx.Window(0).Title("typeface").Size(480, 360)

		heading := tx.Signal("typeface")
		status = tx.Signal("ready")

		tx.Mount(tx.Column(func() {
			// The heading's text style OVERRIDES the root font, so this
			// label is the one a root-only lowering leaves in the system
			// face. expect_ax resolves it through its authored id, the
			// a11y scene's discipline.
			tx.Label(heading).Role(kaya.RoleHeading).A11yID("title") // label#0
			tx.Label(status)                                         // label#1
			// A FIELD AND A TEXTAREA, because they are the two views the
			// observation reads (NSTextField and NSTextView on this
			// platform) and they arrive by DIFFERENT routes: the field
			// inherits the root font, the textarea names its own ramp
			// rung and takes the swap explicitly. A scene with one of
			// them could not tell a half-applied lowering from a whole
			// one.
			tx.Entry(func(tx *kaya.Tx, text string) { // entry#0
				draft = text
			})
			tx.Textarea(nil)                    // textarea#0
			tx.Button("Go", func(tx *kaya.Tx) { // button#0
				tx.Write(status, "clicked "+draft)
			})
		}))
	})

	return app
}
