// The save conformance scene, Go port — the ROUND TRIP an editor actually
// walks (docs/save-plan.md D5): open a file, save back to it, save AS a
// new destination, then reopen BOTH and prove the bytes are where they
// belong.
//
// EVERY STATUS IS A READ-BACK OFF THE DISK, never what the guest hoped it
// wrote. THE BYTES ARE THE ASSERTION AND THE NAME NEVER IS, because
// Android's SAF appends an extension matching the mime type at creation.
//
// NO EXTENSIONS ON THE NAMES AND NO FILTER ON THE SAVE REQUEST, both
// deliberate: a save panel hides a known extension when the user's Finder
// preference says so, and with an allowed type set NSSavePanel appends
// the first extension to an extension-less name (docs/deferred.md).
//
// See guests/rust/save.rs and tools/scenes/save.steps.
package save

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strconv"

	kaya "dev.kaya/bindings/go"
)

// sceneRoot is the directory the picker and the guest can BOTH see: an
// Android provider cannot see an app's private storage and iOS's picker
// cannot see its container, so each phone names the place its own file
// browser reaches. A runtime switch rather than per-platform files,
// because runtime.GOOS is a compile-time constant — every arm is compiled
// and vetted on the mac lane.
//
// kaya.Env AND NOT os.Getenv — tools/check-go-env.py's header carries the
// measurement and the rule, and this is a file it caught.
func sceneRoot() string {
	switch runtime.GOOS {
	case "android":
		root := kaya.Env("EXTERNAL_STORAGE")
		if root == "" {
			root = "/sdcard"
		}
		return filepath.Join(root, "Documents")
	case "ios":
		return filepath.Join(kaya.Env("HOME"), "Documents")
	}
	// Desktop-only by construction: the two arms above return first, so
	// Go's empty Android environment never decides where these files go.
	return os.TempDir()
}

// saveDir is the scene's own directory. The pid keeps parallel legs from
// colliding, and the script names it the same way ($TMP/kaya-save-$PID).
func saveDir() string {
	return filepath.Join(sceneRoot(), "kaya-save-"+strconv.Itoa(os.Getpid()))
}

// readBack reopens a handle through kaya and reads it with Go's own file
// API. THE READ-BACK IS THE ASSERTION in every step of this scene.
func readBack(file kaya.PickedFile) string {
	f, _, err := file.Open(kaya.FileModeRead)
	if err != nil {
		return "open failed: " + err.Error()
	}
	defer f.Close()
	b, err := io.ReadAll(f)
	if err != nil {
		return "read failed: " + err.Error()
	}
	return string(b)
}

// writeBack writes through a handle and reports what the FILE says
// afterwards. FileModeWrite truncates, on a picked file and on a save
// destination alike — the destination only adds the create.
func writeBack(file kaya.PickedFile, text string) string {
	f, _, err := file.Open(kaya.FileModeWrite)
	if err != nil {
		// THE FAILURE docs/save-plan.md D1 EXISTS TO PREVENT reaches the
		// label verbatim: without the create, a save destination cannot
		// be opened.
		return "save failed: " + err.Error()
	}
	if _, err := f.Write([]byte(text)); err != nil {
		f.Close()
		return "write failed: " + err.Error()
	}
	// CLOSED BEFORE THE REOPEN, so what comes back is the file's.
	if err := f.Close(); err != nil {
		return "close failed: " + err.Error()
	}
	return readBack(file)
}

func App() *kaya.App {
	app := kaya.NewApp()

	// THE DECOY IS LOAD-BEARING and sorts first: with ONE file in a
	// directory a dialog completes with it when nothing was selected, so
	// file_choose would pass on a backend that never selected anything
	// (docs/traps.md).
	dir := saveDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		panic("failed to make the scene's directory: " + err.Error())
	}
	if err := os.WriteFile(filepath.Join(dir, "draft"), []byte("first draft"), 0o644); err != nil {
		panic("failed to write the file: " + err.Error())
	}
	if err := os.WriteFile(filepath.Join(dir, "decoy"), []byte("decoy"), 0o644); err != nil {
		panic("failed to write the decoy: " + err.Error())
	}

	// The two capabilities the scene carries, held as HANDLES and never
	// as paths: LocalPath is empty on both phones, so a scene that
	// reopened by path would be a desktop-only scene.
	var source *kaya.PickedFile
	var destination *kaya.PickedFile

	var status kaya.Signal[string]
	// Every file operation runs on a goroutine of the guest's own,
	// because Open blocks; the answer comes back through Post.
	work := func(job func() string) {
		go func() {
			text := job()
			app.Post(func(tx *kaya.Tx) { tx.Write(status, text) })
		}()
	}

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("save")
		status = tx.Signal("no file")

		tx.Mount(tx.Column(func() {
			tx.Label(status).A11yID("status") // label#0

			tx.Button("open", func(tx *kaya.Tx) { // button#0
				// NO FILTER, so the dialog shows the extension-less names
				// this scene deliberately uses.
				tx.PickFile().OnResult(func(tx *kaya.Tx, files []kaya.PickedFile) {
					if len(files) == 0 {
						tx.Write(status, "open cancelled")
						return
					}
					opened := files[0]
					source = &opened
					work(func() string { return "opened " + readBack(opened) })
				}).Show()
			})

			tx.Button("save", func(tx *kaya.Tx) { // button#1
				// SAVE-BACK NEEDS NO DIALOG: the user already chose this
				// file, and the handle they chose it with is writable.
				// A nil handle is an open that never landed — its
				// OWN sentence, never a panic: a crashed guest masks
				// the real failure (docs/deferred.md, save-jvm WATCH).
				if source == nil {
					tx.Write(status, "nothing open to save")
					return
				}
				file := *source
				work(func() string { return "saved " + writeBack(file, "second draft") })
			})

			tx.Button("save as", func(tx *kaya.Tx) { // button#2
				// "copy" is the name the dialog OPENS with; the harness
				// types over it the way a user would.
				tx.SaveFile("copy").OnResult(func(tx *kaya.Tx, file *kaya.PickedFile) {
					if file == nil {
						tx.Write(status, "save cancelled")
						return
					}
					named := *file
					destination = &named
					work(func() string { return "saved " + writeBack(named, "third draft") })
				}).Show()
			})

			tx.Button("reopen", func(tx *kaya.Tx) { // button#3
				// BOTH, in order: a save that went to the wrong handle
				// passes every earlier step and fails here.
				// The nil guard, same reason as save's.
				if source == nil || destination == nil {
					tx.Write(status, "nothing to reopen")
					return
				}
				first, second := *source, *destination
				work(func() string {
					return fmt.Sprintf("reopened %s %s", readBack(first), readBack(second))
				})
			})
		}))
	})

	return app
}
