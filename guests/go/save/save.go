// The save round trip (tools/scenes/save.steps). THE BYTES ARE THE
// ASSERTION AND THE NAME NEVER IS, and no name carries an extension.
package save

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"

	kaya "dev.kaya/bindings/go"
)

// sceneRoot is not temp everywhere: neither phone's picker can see an app's
// private storage. kaya.Env, never os.Getenv (tools/check-go-env.py).
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
	// Desktop-only: the arms above return before Go's empty environment.
	return os.TempDir()
}

// The script names the same place the same way ($TMP/kaya-save-$PID).
func saveDir() string {
	return filepath.Join(sceneRoot(), "kaya-save-"+strconv.Itoa(os.Getpid()))
}

// readBack reopens a handle through kaya.
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

// writeBack reports what the FILE says afterwards. FileModeWrite truncates
// and the destination only adds the create.
func writeBack(file kaya.PickedFile, text string) string {
	f, _, err := file.Open(kaya.FileModeWrite)
	if err != nil {
		// Without the create a save destination cannot be opened
		// (docs/save-plan.md D1).
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

// strays is what else the directory holds, as Go lists it: a temporary
// file the save left would show here. The scene's three names are left
// out (Android's scoped storage hides `final`, which the provider made,
// from this app's listing), and so is the mac panel's `.DS_Store`.
func strays() string {
	entries, _ := os.ReadDir(saveDir())
	names := []string{}
	for _, e := range entries {
		switch e.Name() {
		case "decoy", "draft", "final", ".DS_Store":
		default:
			names = append(names, e.Name())
		}
	}
	if len(names) == 0 {
		return "nothing else in the folder"
	}
	sort.Strings(names)
	return "also " + strings.Join(names, " ")
}

// safeSave is the safe save (docs/rich-document-plan.md §4.1), read back.
func safeSave(file kaya.PickedFile, text string) string {
	if err := file.Save([]byte(text)); err != nil {
		return "safe save failed: " + err.Error()
	}
	return "safe saved " + readBack(file) + "; " + strays()
}

func App() *kaya.App {
	app := kaya.NewApp()

	// The decoy sorts first: a dialog with ONE file completes with it having
	// selected nothing (docs/traps.md).
	dir := saveDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		panic("failed to make the scene's directory: " + err.Error())
	}
	if err := os.WriteFile(filepath.Join(dir, "draft"), []byte("the first draft"), 0o644); err != nil {
		panic("failed to write the file: " + err.Error())
	}
	if err := os.WriteFile(filepath.Join(dir, "decoy"), []byte("decoy"), 0o644); err != nil {
		panic("failed to write the decoy: " + err.Error())
	}

	// HANDLES and never paths: LocalPath is empty on both phones.
	var source *kaya.PickedFile
	var destination *kaya.PickedFile

	var status kaya.Signal[string]
	// Off the app goroutine, because Open blocks.
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
				// NO FILTER: the scene's names have no extensions to match.
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
				// No dialog: the chosen handle is writable. A nil one gets its
				// OWN sentence, never a panic (docs/deferred.md, save-jvm).
				if source == nil {
					tx.Write(status, "nothing open to save")
					return
				}
				file := *source
				work(func() string { return "saved " + writeBack(file, "second draft") })
			})

			tx.Button("save as", func(tx *kaya.Tx) { // button#2
				// The name the dialog OPENS with; the harness types over it.
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
				// A save through the wrong handle fails only here.
				if source == nil || destination == nil {
					tx.Write(status, "nothing to reopen")
					return
				}
				first, second := *source, *destination
				work(func() string {
					return fmt.Sprintf("reopened %s %s", readBack(first), readBack(second))
				})
			})

			tx.Button("safe save", func(tx *kaya.Tx) { // button#4
				// LONGER over the source's "second draft".
				if source == nil {
					tx.Write(status, "nothing open to save")
					return
				}
				file := *source
				work(func() string { return safeSave(file, "the fourth draft, the longest of them") })
			})

			tx.Button("safe save as", func(tx *kaya.Tx) { // button#5
				// SHORTER over the destination's "third draft".
				if destination == nil {
					tx.Write(status, "nothing to reopen")
					return
				}
				file := *destination
				work(func() string { return safeSave(file, "fifth") })
			})
		}))
	})

	return app
}
