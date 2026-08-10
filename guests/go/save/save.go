// The save conformance scene, Go port — the ROUND TRIP an editor
// actually walks (docs/save-plan.md D5): open a file, save back to it,
// save AS a new destination, then reopen both and prove the bytes are
// where they belong.
//
// WHAT THIS PROVES, and why none of it is about a dialog closing:
//
//  1. Save-back works. Writing through the handle the OPEN picker handed
//     over — the thing DESIGN.md has claimed since the picker landed and
//     that no scene, leg or test had ever driven. The claim rested on
//     reading the code.
//  2. A save destination is openable at all. A save dialog on the
//     desktops answers with a name for a file NOBODY HAS MADE (measured
//     on macOS: exists=false after a clean Save), so opening it would
//     fail with "no such file" for a file the user just named. The core's
//     save destination creates; docs/save-plan.md D1 is the decision and
//     this scene is where it shows.
//  3. The two files stay different. The last step reopens BOTH handles
//     and reports both contents, so a save-as that quietly wrote back
//     into the ORIGINAL — the plausible bug, since the guest is holding
//     two handles that look alike — fails here and nowhere else.
//  4. Cancel is nothing, and the dialog id retires. The scene shows a
//     save dialog, cancels it, and shows another. A cancel that leaked
//     the live slot would panic on the second show.
//
// EVERY STATUS IS A READ-BACK OFF THE DISK, never what the guest hoped
// it wrote: write, close, reopen through the handle, read with an
// ordinary *os.File. A write that returned nil and landed nowhere is
// exactly the failure "save" has, and only reopening can see it. THE
// BYTES ARE THE ASSERTION AND THE NAME NEVER IS — Android's SAF appends
// an extension matching the mime type at creation, so a scene that
// compared names would be asserting one platform's filing habits.
//
// THE WORK RUNS OFF THE APP GOROUTINE, which is what PickedFile.Open
// tells every caller to do: it blocks, and a cloud provider may download
// the whole file first. A guest that did this inline would contradict
// its own binding's doc. The parking dance that PROVES the goroutine hop
// belongs to the filedialog scene and is not repeated here — this one
// owns the round trip.
//
// NO EXTENSIONS ON THE NAMES, deliberately. A save panel publishes its
// name field with a known extension HIDDEN when the user's Finder
// preference says so, which would make expect_save_dialog read the stem
// on one machine and the whole name on another. And NO FILTER ON THE
// SAVE REQUEST: with an allowed type set, NSSavePanel appends the first
// extension to an extension-less name, so the destination would not be
// the one the harness typed.
//
// See guests/rust/save.rs and tools/scenes/save.steps — the script is
// shared verbatim by every lane and every language, so these strings are
// byte-frozen.
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

// sceneRoot is the directory the picker and the guest can BOTH see. The
// filedialog scene's Rust module note carries the reasoning for each
// platform: an Android provider cannot see an app's private storage,
// iOS's picker cannot see its container, and the desktops just use temp.
//
// A runtime switch rather than the per-platform files the Rust guest
// uses, because runtime.GOOS is a compile-time constant in Go: the dead
// arms fold away, and — the point — every arm is compiled and vetted on
// the mac lane instead of only on the platform that selects it.
//
// kaya.Env AND NOT os.Getenv, which is the one spelling nothing catches
// at compile time: a c-shared library loaded by System.loadLibrary never
// sees an envp, so Go's view of the environment is EMPTY on Android
// forever while C's getenv reads the live one (bindings/go/runtime.go,
// tools/check-go-env.sh — which caught this file).
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
	// os.TempDir is Go's own answer to "where is temp", which is what
	// makes guest and harness agree on $TMP without either consulting
	// the other — reading an environment variable directly would be a
	// guess about the platform instead (measured, the hard way, in the
	// Python port). Desktop-only by construction: the two arms above
	// return before it, so Go's empty Android environment never decides
	// where this scene's files go.
	return os.TempDir()
}

// saveDir is the scene's own directory. The pid keeps parallel legs from
// colliding, and the script names it the same way ($TMP/kaya-save-$PID)
// because guest and interpreter are one process.
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
		// THE FAILURE D1 EXISTS TO PREVENT reaches the label verbatim:
		// without the create, a save destination cannot be opened at all
		// and this is the sentence the harness prints.
		return "save failed: " + err.Error()
	}
	if _, err := f.Write([]byte(text)); err != nil {
		f.Close()
		return "write failed: " + err.Error()
	}
	// CLOSED BEFORE THE REOPEN, so what comes back is the file's and not
	// a buffer's.
	if err := f.Close(); err != nil {
		return "close failed: " + err.Error()
	}
	return readBack(file)
}

// App builds the scene and hands it back ready to be served (the Go
// guests' one entry package picks it out of guests/go/cmd/scenes.go).
func App() *kaya.App {
	app := kaya.NewApp()

	// The file the scene opens, written before anything is shown, plus
	// the decoy the picker needs: with ONE file in the directory a dialog
	// completes with it when nothing is selected, so file_choose would
	// pass on a backend that never selected anything. "decoy" sorts
	// first, so that backend gets the WRONG file and its five bytes fail
	// the byte assertion too.
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

	// The two capabilities the scene carries: the file the user OPENED,
	// and the destination the user later NAMED. Held as handles, never as
	// paths — LocalPath is empty on both phones, so a scene that reopened
	// by path would be a desktop-only scene.
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
						// The empty list IS cancel.
						tx.Write(status, "open cancelled")
						return
					}
					opened := files[0]
					source = &opened
					work(func() string { return "opened " + readBack(opened) })
				}).Show()
			})

			tx.Button("save", func(tx *kaya.Tx) { // button#1
				// SAVE-BACK NEEDS NO DIALOG. The user already chose this
				// file, and the handle they chose it with is writable —
				// the claim this step exists to drive.
				if source == nil {
					panic("kaya: the save scene opens a file before it saves one")
				}
				file := *source
				work(func() string { return "saved " + writeBack(file, "second draft") })
			})

			tx.Button("save as", func(tx *kaya.Tx) { // button#2
				// "copy" is the name the dialog OPENS with; the harness
				// types over it the way a user would, which is what a
				// save dialog is for.
				tx.SaveFile("copy").OnResult(func(tx *kaya.Tx, file *kaya.PickedFile) {
					if file == nil {
						// CANCEL IS NIL. Nothing was named, so nothing is
						// written and no destination is remembered.
						tx.Write(status, "save cancelled")
						return
					}
					named := *file
					destination = &named
					work(func() string { return "saved " + writeBack(named, "third draft") })
				}).Show()
			})

			tx.Button("reopen", func(tx *kaya.Tx) { // button#3
				// BOTH, in order: the file that was opened must still
				// hold the save-back, and the destination must hold the
				// save-as. A save that went to the wrong handle passes
				// every earlier step and fails here.
				if source == nil || destination == nil {
					panic("kaya: the save scene opens a file and saves as before it reopens")
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
