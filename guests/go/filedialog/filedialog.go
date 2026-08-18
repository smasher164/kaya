// The filedialog conformance scene, Go port — the picker's
// request/result grammar and the capability it hands back (DESIGN.md,
// File dialogs). The guest reads what it was given with an ORDINARY
// *os.File, so the assertion fails unless a real descriptor came back
// carrying the real file.
//
// THE READ RUNS OFF THE APP THREAD, which is what Open tells every caller
// to do: it blocks. The worker PARKS between reading and posting, so a
// guest that read inline is caught by the script and one that did the
// work on the app thread wedges everything after.
//
// See guests/rust/filedialog.rs and tools/scenes/filedialog.steps.
package filedialog

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strconv"

	kaya "dev.kaya/bindings/go"
)

// sceneRoot is the directory the picker and this guest can BOTH see, and
// it is not temp everywhere: an Android provider cannot see an app's
// private storage and iOS's picker cannot see its container, so each
// phone names the place its own file browser reaches.
//
// A GUEST ASKS KAYA FOR PLATFORM LOCATIONS, NEVER GO'S SNAPSHOT: in
// kaya's Android artifact Go's copy of the environment is empty forever.
// os.TempDir is legal only as the fallback of a function that branches on
// runtime.GOOS and asks kaya.Env — tools/check-go-env.sh holds exactly
// that shape, and its header carries the measurement.
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
	return os.TempDir()
}

func App() *kaya.App {
	app := kaya.NewApp()

	// The pid keeps parallel legs from colliding, and the script names the
	// same place the same way ($TMP/kaya-picked-$PID).
	dir := filepath.Join(sceneRoot(), "kaya-picked-"+strconv.Itoa(os.Getpid()))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		panic("failed to make the scene's directory: " + err.Error())
	}
	// THE DECOY IS LOAD-BEARING and sorts before "picked": a picker asked to
	// Open with nothing selected completes with the only file in the
	// directory (docs/traps.md).
	if err := os.WriteFile(filepath.Join(dir, "picked.txt"), []byte("picked bytes"), 0o644); err != nil {
		panic("failed to write the file: " + err.Error())
	}
	if err := os.WriteFile(filepath.Join(dir, "decoy.txt"), []byte("decoy"), 0o644); err != nil {
		panic("failed to write the decoy: " + err.Error())
	}

	// The release channel: the app goroutine closes it, the worker waits on
	// the receive, and close never blocks.
	release := make(chan struct{})

	var status kaya.Signal[string]
	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("filedialog")
		status = tx.Signal("no file")

		picked := func(tx *kaya.Tx, files []kaya.PickedFile) {
			if len(files) == 0 {
				// The empty list IS cancel.
				tx.Write(status, "cancelled")
				return
			}
			go func() {
				// THE CLAIM: the handle crossed a goroutine boundary, and it is redeemed
				// and read with Go's own file API on the goroutine that received it.
				text := ""
				f, _, err := files[0].Open(kaya.FileModeRead)
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
				// Parks holding the result, standing in for the tail of a slow transfer.
				<-release
				count := len(files)
				app.Post(func(tx *kaya.Tx) {
					tx.Write(status, fmt.Sprintf("%d %s", count, text))
				})
			}()
			// The handler RETURNED without reading.
			tx.Write(status, "reading")
		}

		tx.Mount(tx.Column(func() {
			tx.Label(status).A11yID("status") // label#0
			tx.Button("open", func(tx *kaya.Tx) { // button#0
				// ADVISORY on every platform: a default view, never a guarantee.
				tx.PickFiles().Filter("Text", "txt").OnResult(picked).Show()
			})
			tx.Button("open one", func(tx *kaya.Tx) { // button#1
				tx.PickFile().Filter("Text", "txt").OnResult(picked).Show()
			})
			tx.Button("release", func(tx *kaya.Tx) { // button#2
				close(release)
			})
		}))
	})

	return app
}
