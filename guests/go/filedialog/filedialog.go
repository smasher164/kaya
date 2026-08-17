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
// they are the same process, and both compute the place from the same
// rule (`sceneRoot` below, and the interpreter's `$TMP` expansion).
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
// it is not the temp directory everywhere.
//
// A GUEST ASKS KAYA FOR PLATFORM LOCATIONS, NEVER THE LANGUAGE
// RUNTIME'S SNAPSHOT (ratified 2026-08-17). This file used to argue the
// opposite — that `os.TempDir` is "Go's own answer to where is temp",
// which is what makes guest and interpreter agree without either
// consulting the other, and that reading an environment variable would
// be a guess about the platform. That argument lost, and the thing that
// beat it was measured rather than reasoned: in a `-buildmode=c-shared`
// library — kaya's Android artifact — Go's runtime never sees an envp,
// because the .so is LOADED and not exec'd. Go's copy of the
// environment is empty forever there, while C's getenv(3) reads the
// live `environ` the host wrote (docs/go-mobile-plan.md D2). Every Go
// API that answers "where is X" out of that copy answers out of an
// empty map: `os.TempDir` returns its hardcoded "/tmp", which is not a
// place an Android app may write. Nothing errors; the scene just puts
// its files where nothing looks.
//
// So each arm names the place that platform's file browser can actually
// reach, and each asks the HOST through kaya.Env:
//
//	android  a provider cannot see an app's private storage, so the
//	         shared Documents collection is the one directory both
//	         halves can have (EXTERNAL_STORAGE, set in every app
//	         process; /sdcard if a device ever omits it).
//	ios      the document picker browses providers and cannot see the
//	         app container, but the app's own Documents directory IS
//	         browsable — the bundle declares UIFileSharingEnabled and
//	         LSSupportsOpeningDocumentsInPlace (tools/ios/Info.plist.in).
//	         HOME is the container in every iOS process.
//	desktop  temp, which is what `$TMP` expands to in the scene script
//	         (crates/kaya/src/harness.rs, swift/KayaSwiftUI.swift).
//
// The desktop arm keeps os.TempDir DELIBERATELY, and it is not the
// defect above: the two arms before it return first, so Go's empty
// Android environment never decides where this scene's files go, and on
// a desktop the guest owns main and Go's copy is the host's. That is
// also the shape tools/check-go-env.sh now enforces — os.TempDir is
// legal only as the fallback of a function that branches on
// runtime.GOOS and asks kaya for the mobile locations; a bare one, the
// spelling this file shipped until today, is red.
//
// A runtime switch rather than per-platform files, the editor guest's
// reasoning: runtime.GOOS is a compile-time constant, so the dead arms
// fold away, and every arm is compiled and vetted on the mac lane
// instead of only on the platform that selects it. The same carve-out
// in the other guests' spellings: guests/rust/filedialog.rs
// `scene_root`, guests/go/clipboard/clipboard.go `sceneRoot`.
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

	// The pid keeps parallel legs from colliding, and the script names
	// the same place the same way ($TMP/kaya-picked-$PID).
	dir := filepath.Join(sceneRoot(), "kaya-picked-"+strconv.Itoa(os.Getpid()))
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

	return app
}
