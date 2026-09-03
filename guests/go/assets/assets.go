// The assets conformance scene (tools/scenes/assets.steps). THE MISS IS A
// QUESTION, NOT A recover(), and LINE 1 ONLY: line 2 differs per host.
package assets

import (
	"fmt"
	"strings"

	kaya "dev.kaya/bindings/go"
)

const (
	// Absent, and deliberately LEGAL, so the miss is the census sentence.
	missingName = "icons/nope.png"

	markName = "icons/kaya-mark.png"

	// 111400 bytes: a reader that truncated into a fixed buffer shows here.
	fontName = "fonts/sora-wght.ttf"
)

// firstLine is the census half of the sentence.
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
			// Shows the sentence: a failure must say what was measured.
			verdict = firstLine(complaint)
		}

		title := tx.Signal("assets")
		found := tx.Signal(census)
		// %d renders with no separator and no padding, everywhere.
		sizes := tx.Signal(fmt.Sprintf("%s: %d bytes, %s", fontName, font.Len(), verdict))

		tx.Mount(tx.Column(func() {
			tx.Label(title) // label#0
			// THE BYTES, not the blob handle.
			tx.Image(mark.Bytes()) // image#0
			tx.Label(found)        // label#1
			tx.Label(sizes)        // label#2
		}))
	})

	return app
}
