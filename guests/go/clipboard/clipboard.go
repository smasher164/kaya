// The clipboard conformance scene, Go port — one clip in several
// representations, and the privileged read that takes one back
// (DESIGN.md, Clipboard; docs/clipboard-plan.md).
//
// EVERY ASSERTION CROSSES A PROCESS BOUNDARY, which is the whole design
// of this scene. kaya's representation set is closed because the
// LOWERINGS are the hard part — CF_HTML's mandatory offset header,
// Android's content:// URI for an image, CF_HDROP's double-NUL struct —
// and a check where kaya reads what kaya wrote parses its own malformed
// header perfectly happily. That is not merely less coverage: it is a
// check that cannot fail for the reason the design exists.
//
// THE ONE EXCEPTION IS THE CUSTOM FORMAT, deliberately. No stock tool
// on any platform writes an app-defined type, so the guest copies one
// and reads it back, with the foreign reader confirming from outside
// that the bytes really are there under that id.
//
// THE IMAGE IS ASSERTED AS A DECODED SIZE, never as bytes: every host
// re-encodes freely between image types, so a byte count would be a
// different number on every lane for one picture.
//
// Canonical semantics in guests/rust/clipboard.rs; the byte-frozen
// contract in tools/scenes/clipboard.steps.
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

// A 4x4 PNG, spelled out rather than generated: the scene asserts "4x4"
// through a foreign decoder, so the picture has to be a real encoded
// image whose size is knowable from the script. Written to disk for the
// seeding tool AND handed to Copy as bytes — the same picture both ways.
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
// reaches every platform's own registry VERBATIM — a UTI on Apple,
// RegisterClipboardFormat on Windows, a target atom on X11 and Wayland,
// a MIME type on Android.
const noteID = "dev.kaya/note"

// NO QUOTES IN THE PAYLOAD, and the reason is the script rather than
// the clipboard: the step grammar's escapes are \n, \r and \\ in all
// three interpreters, with no \" — so a quoted byte could not be
// spelled in the expectation.
var noteBytes = []byte("note=1")

// sceneRoot is where this scene keeps the files an OUTSIDE process has
// to reach, and it is not the temp directory everywhere.
//
// On the desktops os.TempDir is Go's OWN answer to "where is temp",
// which is what lets guest and interpreter agree on a path without
// either consulting the other (the filedialog rule).
//
// ON iOS IT IS THE APP'S OWN Documents DIRECTORY INSTEAD, because the
// reader is outside the app: `simctl` and the document picker browse
// PROVIDERS and cannot see another app's private container, so a file
// written to TMPDIR there is written where nothing looks. The bundle's
// UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace
// (tools/ios/Info.plist.in) are what make Documents browsable at all.
// HOME is the app container in every iOS process, so both halves still
// compute the same place from the same rule — the interpreter spells it
// NSHomeDirectory()/Documents (swift/KayaSwiftUI.swift's kayaTempDir).
//
// This is the Go spelling of a carve-out the other guests already have:
// guests/rust/clipboard.rs `#[cfg(target_os = "ios")] fn scene_root`,
// guests/swift/clipboard.swift `#if os(iOS)`. runtime.GOOS is a
// compile-time constant, so the branch not taken is not compiled in.
//
// HOME COMES FROM kaya.Env AND NEVER FROM os.Getenv. os.Getenv would be
// right here today — this branch is iOS, where the guest owns main and
// Go's environment is filled — and wrong the moment the same read is
// copied into an Android arm, where the guest is a loaded .so and Go's
// copy of the environment is empty forever. One spelling everywhere is
// what stops that copy being a defect (docs/go-mobile-plan.md D2;
// tools/check-go-env.sh).
func sceneRoot() string {
	if runtime.GOOS == "ios" {
		return filepath.Join(kaya.Env("HOME"), "Documents")
	}
	return os.TempDir()
}

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

	// Both halves compute this identically, the filedialog rule: guest
	// and interpreter are the same process, so they agree on a path with
	// no runner involvement, and the pid keeps parallel legs from
	// colliding.
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

		// THE GESTURE LAYER'S DECLARATION, and an app writes nothing
		// else for it: the Paste command lowers to the platform's own,
		// acts on whatever is focused, and works out its own enablement.
		// kaya has no selection API, which is exactly why copy of a
		// selection has to be a command rather than something an app
		// assembles out of the data layer.
		edit := win.Menu("Edit")
		edit.Item("Cut").Role(kaya.RoleCut)
		edit.Item("Copy").Role(kaya.RoleCopy)
		edit.Item("Paste").Role(kaya.RolePaste)

		status = tx.Signal("ready")
		rowStatus = tx.Signal("")

		// THE SAME SHAPE THE READ ANSWERS WITH, and free where the read
		// is not: a gesture is its own authorisation, so no platform
		// charges a prompt for this one.
		answered := func(tx *kaya.Tx, clip kaya.Representation) {
			switch clip := clip.(type) {
			// EMPTY IS THE UNIVERSAL NO, and the guest does not try to
			// tell its four causes apart — denied, unfocused, absent, or
			// nothing this read accepted. The platforms deliberately
			// decline to say.
			case nil:
				tx.Write(status, "empty")
			case kaya.TextClip:
				tx.Write(status, "text "+clip.Text)
			case kaya.HTMLClip:
				tx.Write(status, "html "+clip.HTML)
			case kaya.CustomClip:
				tx.Write(status, fmt.Sprintf("custom %s %s", clip.ID, clip.Bytes))
			case kaya.ImageClip:
				// STRAIGHT BACK OUT, because the assertion that matters
				// is a foreign DECODER's: the byte count differs per
				// host for one picture, and the decoded size does not.
				tx.Copy().Image(clip.Bytes).Send()
				tx.Write(status, "image")
			case kaya.FilesClip:
				if len(clip.Files) == 0 {
					tx.Write(status, "files none")
					return
				}
				file := clip.Files[0]
				go func() {
					// OFF THE APP GOROUTINE, which is what Open
					// documents: it blocks, and a pasted file is no
					// different from a picked one — it IS a picked one,
					// the same capability arriving through a second door.
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
				// ONE CLIP, FOUR REPRESENTATIONS. kaya derives none of
				// them from any other: whether list bullets survive
				// html-to-text is this app's decision, so it spells out
				// both. The order they go on the wire is kaya's, not
				// this chain's — descending richness, which is
				// preference order on every host that has one.
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

			// DECLARES WHAT IT TAKES, so a paste lands in the hook and
			// this app decides what to do with it.
			rich = tx.Entry(nil).Accepts(kaya.AcceptText).A11yID("rich") // entry#0
			app.OnPaste(rich, func(tx *kaya.Tx, clip kaya.Representation) {
				if text, ok := clip.(kaya.TextClip); ok {
					tx.Write(status, "pasted "+text.Text)
					return
				}
				tx.Write(status, fmt.Sprintf("pasted %v", clip))
			})

			// DECLARES NOTHING, so the platform's own insertion happens
			// and the field's ordinary change path reports it — which is
			// what a plain text editor gets for free.
			plain = tx.Entry(nil).A11yID("plain") // entry#1

			// THE SAME TWO DOORS ONE TIER DOWN, on a STAMPED copy. The
			// accept list is declared on the TEMPLATE, which is the
			// declaration that turns the node hook on: every backend
			// hands the gesture to the platform when the focused
			// widget's accept list is empty, so before a template could
			// carry one this handler was registered, dispatched and
			// unable to fire (docs/tpl-props-plan.md §1). The copy's own
			// key arrives with the payload — that is what tells an
			// instance paste from a live one.
			//
			// The row's value is empty because nothing displays it: the
			// stamped entry is UNCONTROLLED like its live siblings, and
			// staying empty through the paste is the assertion.
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
