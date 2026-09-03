// The clipboard conformance scene (tools/scenes/clipboard.steps).
// Canonical semantics in guests/rust/clipboard.rs.
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

// A real 4x4 PNG: the scene asserts "4x4" through a FOREIGN decoder.
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

// Reverse-DNS and space-free: it reaches every registry VERBATIM.
const noteID = "dev.kaya/note"

// NO QUOTES IN THE PAYLOAD: the step grammar has no \" escape.
var noteBytes = []byte("note=1")

// sceneRoot is not temp everywhere: on iOS the picker browses PROVIDERS
// and cannot see the container. kaya.Env, never os.Getenv (check-go-env.py).
func sceneRoot() string {
	if runtime.GOOS == "ios" {
		return filepath.Join(kaya.Env("HOME"), "Documents")
	}
	// The SHARED collection: the outside reader is another app, and
	// os.TempDir would answer /data/local/tmp, which this app cannot create.
	if runtime.GOOS == "android" {
		ext := kaya.Env("EXTERNAL_STORAGE")
		if ext == "" {
			ext = "/sdcard"
		}
		return filepath.Join(ext, "Documents")
	}
	return os.TempDir()
}

func App() *kaya.App {
	app := kaya.NewApp()

	// Both halves compute this identically; the pid separates parallel legs.
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
			// EMPTY IS THE UNIVERSAL NO; no platform says which cause.
			case nil:
				tx.Write(status, "empty")
			case kaya.TextClip:
				tx.Write(status, "text "+clip.Text)
			case kaya.HTMLClip:
				tx.Write(status, "html "+clip.HTML)
			case kaya.CustomClip:
				tx.Write(status, fmt.Sprintf("custom %s %s", clip.ID, clip.Bytes))
			case kaya.ImageClip:
				// A foreign DECODER's size: byte counts differ per host.
				tx.Copy().Image(clip.Bytes).Send()
				tx.Write(status, "image")
			case kaya.FilesClip:
				if len(clip.Files) == 0 {
					tx.Write(status, "files none")
					return
				}
				file := clip.Files[0]
				go func() {
					// OFF THE APP GOROUTINE: Open blocks.
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

			rich = tx.Entry(nil).Accepts(kaya.AcceptText).A11yID("rich") // entry#0
			app.OnPaste(rich, func(tx *kaya.Tx, clip kaya.Representation) {
				if text, ok := clip.(kaya.TextClip); ok {
					tx.Write(status, "pasted "+text.Text)
					return
				}
				tx.Write(status, fmt.Sprintf("pasted %v", clip))
			})

			plain = tx.Entry(nil).A11yID("plain") // entry#1

			// On a STAMPED copy the accept list rides the TEMPLATE.
			tx.Label(rowStatus).A11yID("row-status") // label#1
			notes := tx.Collection()
			for row := range tx.Rows(notes).All() {
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
