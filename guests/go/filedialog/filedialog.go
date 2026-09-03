// The filedialog scene (tools/scenes/filedialog.steps). THE READ RUNS OFF
// THE APP THREAD, because Open blocks, and the worker PARKS before posting.
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

// Not temp everywhere: neither phone's picker sees private storage, and
// os.TempDir is legal only as this runtime.GOOS switch's fallback.
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

	// The script names the same place the same way ($TMP/kaya-picked-$PID).
	dir := filepath.Join(sceneRoot(), "kaya-picked-"+strconv.Itoa(os.Getpid()))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		panic("failed to make the scene's directory: " + err.Error())
	}
	// The decoy sorts before "picked": Open with nothing selected completes
	// with the only file there (docs/traps.md).
	if err := os.WriteFile(filepath.Join(dir, "picked.txt"), []byte("picked bytes"), 0o644); err != nil {
		panic("failed to write the file: " + err.Error())
	}
	if err := os.WriteFile(filepath.Join(dir, "decoy.txt"), []byte("decoy"), 0o644); err != nil {
		panic("failed to write the decoy: " + err.Error())
	}

	// The app goroutine closes it: close never blocks.
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
				<-release
				count := len(files)
				app.Post(func(tx *kaya.Tx) {
					tx.Write(status, fmt.Sprintf("%d %s", count, text))
				})
			}()
			tx.Write(status, "reading")
		}

		tx.Mount(tx.Column(func() {
			tx.Label(status).A11yID("status") // label#0
			tx.Button("open", func(tx *kaya.Tx) { // button#0
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
