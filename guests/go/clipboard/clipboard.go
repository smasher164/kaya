// The clipboard conformance scene, Go port — one clip in several
// representations, and the privileged read that takes one back
// (DESIGN.md, Clipboard; docs/clipboard-plan.md). Canonical semantics in
// guests/rust/clipboard.rs; the byte-frozen contract in
// tools/scenes/clipboard.steps.
package clipboard

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strconv"

	kaya "dev.kaya/bindings/go"
)

// A 4x4 PNG: the scene asserts "4x4" through a FOREIGN decoder, so it has
// to be a real encoded image. Written to disk for the seeding tool AND
// handed to Copy as bytes — the same picture both ways.
var pixelPNG = []byte{
	0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // signature
	0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR length + type
	0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, // 4 x 4
	0x08, 0x02, 0x00, 0x00, 0x00, 0x26, 0x93, 0x09, // 8-bit rgb + crc
	0x29, 0x00, 0x00, 0x00, 0x14, 0x49, 0x44, 0x41, // IDAT length + type
	0x54, 0x78, 0xDA, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
	0x47, 0x48, 0x4C, 0x74, 0xDE, 0x7F, 0x24, 0x00,
	0x00, 0xD2, 0x6F, 0x17, 0xE9, 0x51, 0xBB, 0x23,
	0x2D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
	0x44, 0xAE, 0x42, 0x60, 0x82, // IEND + crc
}

// The app-defined format's id: reverse-DNS and space-free, because it
// reaches every platform's own registry VERBATIM.
const noteID = "dev.kaya/note"

// NO QUOTES IN THE PAYLOAD: the step grammar's escapes are \n, \r and \\
// in all three interpreters, with no \", so a quoted byte could not be
// spelled in the expectation.
var noteBytes = []byte("note=1")

// sceneRoot is where this scene keeps the files an OUTSIDE process has to
// reach, and it is not temp everywhere: on iOS simctl and the document
// picker browse PROVIDERS and cannot see the app container, so the app's
// own Documents directory is the one place both halves can look
// (tools/ios/Info.plist.in is what makes it browsable).
//
// kaya.Env AND NEVER os.Getenv — tools/check-go-env.sh's header carries
// the measurement and the rule.
func sceneRoot() string {
	if runtime.GOOS == "ios" {
		return filepath.Join(kaya.Env("HOME"), "Documents")
	}
	return os.TempDir()
}

func App() *kaya.App {
	app := kaya.NewApp()

	// Both halves compute this identically — guest and interpreter are
	// one process — and the pid keeps parallel legs from colliding.
	dir := filepath.Join(sceneRoot(), "kaya-clip-"+strconv.Itoa(os.Getpid()))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		panic("failed to make the scene's directory: " + err.Error())
	}
	if err := os.WriteFile(filepath.Join(dir, "pixel.png"), pixelPNG, 0o644); err != nil {
		panic("failed to write the picture: " + err.Error())
	}
	if err := os.WriteFile(filepath.Join(dir, "pasted.txt"), []byte("pasted bytes"), 0o644); err != nil {
		panic("failed to write the file: " + err.Error())
	}

	var status, rowStatus kaya.Signal[string]
	app.Build(func(tx *kaya.Tx) {
		win := tx.Window(0).Title("clipboard")

		edit := win.Menu("Edit")
		edit.Item("Cut").Role(kaya.RoleCut)
		edit.Item("Copy").Role(kaya.RoleCopy)
		edit.Item("Paste").Role(kaya.RolePaste)

		status = tx.Signal("ready")
		rowStatus = tx.Signal("")

		answered := func(tx *kaya.Tx, clip kaya.Representation) {
			switch clip := clip.(type) {
			// EMPTY IS THE UNIVERSAL NO, and the guest does not try to
			// tell its four causes apart; the platforms decline to say.
			case nil:
				tx.Write(status, "empty")
			case kaya.TextClip:
				tx.Write(status, "text "+clip.Text)
			case kaya.HTMLClip:
				tx.Write(status, "html "+clip.HTML)
			case kaya.CustomClip:
				tx.Write(status, fmt.Sprintf("custom %s %s", clip.ID, clip.Bytes))
			case kaya.ImageClip:
				// STRAIGHT BACK OUT: the assertion that matters is a
				// foreign DECODER's, because the byte count differs per
				// host for one picture.
				tx.Copy().Image(clip.Bytes).Send()
				tx.Write(status, "image")
			case kaya.FilesClip:
				if len(clip.Files) == 0 {
					tx.Write(status, "files none")
					return
				}
				file := clip.Files[0]
				go func() {
					// OFF THE APP GOROUTINE: Open blocks, and a pasted
					// file is a picked one arriving through a second
					// door.
					text := ""
					f, _, err := file.Open(kaya.FileModeRead)
					if err != nil {
						text = "open failed: " + err.Error()
					} else {
						b, rerr := io.ReadAll(f)
						if rerr != nil {
							text = "read failed: " + rerr.Error()
						} else {
							text = string(b)
						}
						f.Close()
					}
					app.Post(func(tx *kaya.Tx) {
						tx.Write(status, fmt.Sprintf("files %s %s", file.Name, text))
					})
				}()
				tx.Write(status, "reading")
			}
		}

		tx.Mount(tx.Column(func() {
			tx.Label(status).A11yID("status")     // label#0
			tx.Button("copy", func(tx *kaya.Tx) { // button#0
				tx.Copy().
					Text("kaya clip").
					HTML("<b>kaya</b> clip").
					Image(pixelPNG).
					Custom(noteID, noteBytes).
					Send()
				tx.Write(status, "copied")
			})
			tx.Button("read custom", func(tx *kaya.Tx) { // button#1
				tx.ReadClipboard().Custom(noteID).OnResult(answered).Send()
			})
			tx.Button("read text", func(tx *kaya.Tx) { // button#2
				tx.ReadClipboard().Text().OnResult(answered).Send()
			})
			tx.Button("read image", func(tx *kaya.Tx) { // button#3
				tx.ReadClipboard().Image().OnResult(answered).Send()
			})
			tx.Button("read files", func(tx *kaya.Tx) { // button#4
				tx.ReadClipboard().Files().OnResult(answered).Send()
			})

			var rich, plain kaya.Widget
			tx.Button("focus rich", func(tx *kaya.Tx) { // button#5
				tx.Focus(rich)
			})
			tx.Button("focus plain", func(tx *kaya.Tx) { // button#6
				tx.Focus(plain)
			})

			// Declares what it takes, so a paste lands in the hook.
			rich = tx.Entry(nil).Accepts(kaya.AcceptText).A11yID("rich") // entry#0
			app.OnPaste(rich, func(tx *kaya.Tx, clip kaya.Representation) {
				if text, ok := clip.(kaya.TextClip); ok {
					tx.Write(status, "pasted "+text.Text)
					return
				}
				tx.Write(status, fmt.Sprintf("pasted %v", clip))
			})

			// Declares NOTHING, so the platform's own insertion happens
			// and the field's ordinary change path reports it.
			plain = tx.Entry(nil).A11yID("plain") // entry#1

			// THE SAME TWO DOORS ONE TIER DOWN, on a STAMPED copy: the
			// accept list is declared on the TEMPLATE, which is the
			// declaration that turns the node hook on. The row's value is
			// empty because nothing displays it — the stamped entry is
			// uncontrolled, and staying empty through the paste is the
			// assertion.
			tx.Label(rowStatus).A11yID("row-status") // label#1
			notes := tx.Collection()
			for row := range notes.Rows(tx) {
				note := row.Entry() // entry#2, one stamped copy
				row.SetAccepts(note, kaya.AcceptText)
				app.OnPasteNode(note, func(tx *kaya.Tx, keys []any, clip kaya.Representation) {
					if text, ok := clip.(kaya.TextClip); ok {
						tx.Write(rowStatus, "row "+keys[0].(string)+" pasted "+text.Text)
						return
					}
					tx.Write(rowStatus, fmt.Sprintf("row %v pasted %v", keys[0], clip))
				})
			}
			tx.Insert(notes, "r1", "")
		}))
	})

	return app
}
