// The filedialog conformance scene, Go port — the picker's
// request/result grammar and the capability it hands back (DESIGN.md,
// File dialogs).
//
// WHAT THIS PROVES, and why it goes all the way to the bytes: the
// design's whole claim is that kaya hands over a CAPABILITY and never
// moves the data. So the guest does not assert that a dialog closed —
// it opens the handle it was given, reads the file with an ORDINARY
// *os.File, and writes what it read into a signal. `expect label#0
// "1 picked bytes"` therefore fails unless a real descriptor came back
// carrying the real file.
//
// THE FILE IS THE GUEST'S OWN, written before anything is shown, so
// guest and interpreter agree on a path with no runner involvement —
// they are the same process. `os.TempDir` is Go's own answer to "where
// is temp", which is what makes the two halves agree without either
// consulting the other; reading an environment variable directly would
// be a guess about the platform instead (measured, the hard way, in the
// Python port).
//
// THE READ RUNS OFF THE APP THREAD, which is what Open tells every
// caller to do: it blocks, and a cloud provider may download the whole
// file before it returns.
//
// The parking is a plain channel receive on a channel this guest owns,
// and the worker is a plain goroutine. kaya supplies no waiting
// primitive and should not: the point is that a guest uses its own
// language's concurrency and hands back only the result. The worker PARKS between reading and posting,
// and only a click releases it, so a guest that read inline is caught
// by `expect label#0 "reading"` and one that did the work on the app
// thread wedges everything after.
//
// See guests/rust/filedialog.rs and tools/scenes/filedialog.steps.
package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strconv"

	kaya "dev.kaya/bindings/go"
)

func init() {
	runtime.LockOSThread()
}

func main() {
	app := kaya.NewApp()

	dir := filepath.Join(os.TempDir(), "kaya-picked-"+strconv.Itoa(os.Getpid()))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		panic("failed to make the scene's directory: " + err.Error())
	}
	// THE DECOY IS LOAD-BEARING: with one file in the directory,
	// pressing Open with nothing selected returns that file, so
	// `file_choose picked.txt` would pass on a backend that ignored the
	// name entirely. Measured on GTK. "decoy" sorts before "picked", so
	// a backend that skips selection gets the WRONG file, and its five
	// bytes fail the byte assertion as well as the name.
	if err := os.WriteFile(filepath.Join(dir, "picked.txt"), []byte("picked bytes"), 0o644); err != nil {
		panic("failed to write the file: " + err.Error())
	}
	if err := os.WriteFile(filepath.Join(dir, "decoy.txt"), []byte("decoy"), 0o644); err != nil {
		panic("failed to write the decoy: " + err.Error())
	}

	// The release channel: the app goroutine closes it, the worker is
	// waiting on the receive. A handler that blocked handing this over
	// would fail the very claim being tested, and close never blocks.
	release := make(chan struct{})

	var status kaya.Signal[string]
	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("filedialog")
		status = tx.Signal("no file")

		picked := func(tx *kaya.Tx, files []kaya.PickedFile) {
			if len(files) == 0 {
				// The empty list IS cancel. Nothing to read, so no
				// worker and no release.
				tx.Write(status, "cancelled")
				return
			}
			go func() {
				// THE CLAIM, and it is made HERE rather than in the
				// handler on purpose: the handle crossed a goroutine
				// boundary, and it is redeemed and read with Go's own
				// file API on the goroutine that received it. kaya is
				// not in this data path, and Open is documented to
				// block.
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
				// Parks holding the result, standing in for the tail of
				// a slow transfer. Were this work running on the app
				// goroutine, the release click could never be processed
				// and the whole scene would deadlock — the point.
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
				// ADVISORY on every platform: a default view, never a
				// guarantee, so a guest still validates what it got.
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

	os.Exit(app.Run())
}
