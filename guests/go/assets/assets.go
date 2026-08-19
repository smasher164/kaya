// The assets conformance scene from Go (docs/assets-plan.md, ratified
// 2026-08-18). The byte-frozen contract is tools/scenes/assets.steps.
//
// THIS ONE PROVES THE BYTES. asset(name) has two redemptions and the
// typeface scene already covers the other — a font whose bytes go from
// the core's read straight to the platform's font API and never enter
// Go's heap. Here the guest IS the consumer: it copies the mark out with
// Bytes() and hands them to an Image, and the platform's own decoder
// answers 64x64 off the real view.
//
// THE MISS IS A QUESTION, NOT A recover(). AssetMissSentence answers the
// same sentence Tx.Asset would panic with, without panicking, and that
// is the only shape nine languages share: Swift's raise is fatalError,
// which traps rather than unwinding, so a Swift sibling cannot catch its
// own miss. Go could recover here and deliberately does not — one shape
// for the observation, in every language.
//
// LINE 1 ONLY. Line 2 of that sentence names the place the core resolved
// and the route that chose it, which a bundle, a device directory and a
// repo checkout spell three different ways; line 1 is the same
// everywhere, so it is the line a scene can freeze.
package assets

import (
	"fmt"
	"strings"

	kaya "dev.kaya/bindings/go"
)

const (
	// The asset that is deliberately not there. A LEGAL name —
	// relative, /-spelled, one component deep — so what comes back is
	// the census sentence and not a name-fault one.
	missingName = "icons/nope.png"

	// The one the mark is under, and the one the census must list.
	markName = "icons/kaya-mark.png"

	// The large asset: 111400 bytes, so a reader that truncated into a
	// fixed buffer shows up here rather than passing quietly.
	fontName = "fonts/sora-wght.ttf"
)

// firstLine is the census half of the sentence. Empty in, empty out.
func firstLine(sentence string) string {
	if at := strings.IndexByte(sentence, '\n'); at >= 0 {
		return sentence[:at]
	}
	return sentence
}

func App() *kaya.App {
	app := kaya.NewApp()

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("assets").Size(480, 360)

		mark := tx.Asset(markName)
		defer mark.Close()
		font := tx.Asset(fontName)
		defer font.Close()

		census := firstLine(tx.AssetMissSentence(missingName))
		verdict := "no complaint"
		if complaint := tx.AssetMissSentence(fontName); complaint != "" {
			// Never reached on a healthy lane, and it shows the
			// sentence rather than a word about it: a failure here has
			// to say what was measured.
			verdict = firstLine(complaint)
		}

		title := tx.Signal("assets")
		found := tx.Signal(census)
		// %d renders a Go int with no separator and no padding, on
		// every platform and under every environment.
		sizes := tx.Signal(fmt.Sprintf("%s: %d bytes, %s", fontName, font.Len(), verdict))

		tx.Mount(tx.Column(func() {
			tx.Label(title) // label#0
			// THE BYTES, not the blob handle: this scene is the
			// consumer, so what reaches the decoder is what Bytes()
			// handed back.
			tx.Image(mark.Bytes()) // image#0
			tx.Label(found)        // label#1
			tx.Label(sizes)        // label#2
		}))
	})

	return app
}
