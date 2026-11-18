// The references scene (tools/scenes/references.steps,
// docs/restoration-plan.md SR11, SR12): a picked file's durable reference
// rides the session store across a relaunch and redeems for its bytes; a
// foreign token and a deleted file are refused by name.
package references

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"

	kaya "dev.kaya/bindings/go"
)

// readBack answers the bytes a token redeems for, or the refusal's branch;
// the sentence goes to stderr, where the leg log keeps it.
func readBack(token string) string {
	redeemed, err := kaya.Redeem(token)
	var refused *kaya.ReferenceError
	if errors.As(err, &refused) {
		fmt.Fprintf(os.Stderr, "references: %s\n", refused.Message)
		return refused.Refusal
	}
	f, _, err := redeemed.File.Open(kaya.FileModeRead)
	if err != nil {
		return "open failed: " + err.Error()
	}
	defer f.Close()
	bytes, err := io.ReadAll(f)
	if err != nil {
		return "read failed: " + err.Error()
	}
	return "redeemed: " + string(bytes)
}

// sceneRoot is the place the script names as $TMP, per platform.
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

	dir := filepath.Join(sceneRoot(), fmt.Sprintf("kaya-refs-%d", os.Getpid()))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		panic(err)
	}
	for name, body := range map[string]string{"picked.txt": "picked bytes", "decoy.txt": "decoy"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			panic(err)
		}
	}

	session := kaya.Session()
	var saved string
	var status kaya.Signal[string]
	reader := func(token string) {
		go func() {
			said := readBack(token)
			app.Post(func(tx *kaya.Tx) { tx.Write(status, said) })
		}()
	}
	picked := func(tx *kaya.Tx, files []kaya.PickedFile) {
		if len(files) == 0 {
			tx.Write(status, "cancelled")
			return
		}
		token, err := files[0].Reference()
		var refused *kaya.ReferenceError
		if errors.As(err, &refused) {
			fmt.Fprintf(os.Stderr, "references: %s\n", refused.Message)
			tx.Write(status, refused.Refusal)
			return
		}
		session.SetString("doc", token)
		session.SetString("dir", dir)
		tx.Write(status, "minted")
	}

	app.Build(func(tx *kaya.Tx) {
		saved = session.GetString("doc", "")
		tx.Window(0).Title("references")
		first := "no reference"
		if saved != "" {
			first = "redeeming"
		}
		status = tx.Signal(first)
		tx.Mount(tx.Column(func() {
			tx.Label(status).A11yID("status")
			tx.Button("pick", func(tx *kaya.Tx) {
				tx.PickFile().Filter("Text", "txt").OnResult(picked).Show()
			}).A11yID("pick")
			tx.Button("foreign", func(*kaya.Tx) {
				reader("kaya-ref1:beos:AAAA:00000000")
			}).A11yID("foreign")
			tx.Button("delete", func(*kaya.Tx) {
				_ = os.Remove(filepath.Join(session.GetString("dir", ""), "picked.txt"))
				reader(saved)
			}).A11yID("delete")
		}))
		if saved != "" {
			reader(saved)
		}
	})

	return app
}
