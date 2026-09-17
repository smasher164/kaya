package kaya

// F1 (the idiom pass, 2026-09-16): Role, Align, Axis, Appearance and
// Symbol are named types now, so a guest that hands one family's
// constant to another's setter is a Go compile error rather than a
// silently-accepted int64. The guard lives in the type system, so the
// only place to watch it fire is a real `go build` of guest-shaped code
// importing this package — a scratch module, replaced onto this repo.
import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func probeModule(t *testing.T, source string) (string, error) {
	t.Helper()
	wd, err := os.Getwd() // bindings/go
	if err != nil {
		t.Fatal(err)
	}
	repoRoot := filepath.Dir(filepath.Dir(wd))
	dir := t.TempDir()
	goMod := "module idiomprobe\n\ngo 1.27\n\nrequire dev.kaya v0.0.0\n\nreplace dev.kaya => " + repoRoot + "\n"
	if err := os.WriteFile(filepath.Join(dir, "go.mod"), []byte(goMod), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "probe.go"), []byte(source), 0o644); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("go", "build", ".")
	cmd.Dir = dir
	// cmd.Environ() rather than os.Environ(): tools/check-go-env.py.
	cmd.Env = append(cmd.Environ(), "GOFLAGS=-mod=mod")
	out, err := cmd.CombinedOutput()
	return string(out), err
}

const familyMismatchSource = `package main

import kaya "dev.kaya/bindings/go"

func main() {
	var w kaya.Widget
	w.Role(kaya.AlignCenter)
}
`

// A CONTROL, run first: the same shape with a same-family constant must
// build clean, or a probe failing for the wrong reason (a bad go.mod, a
// missing dependency) would read as the wall firing.
const familyMatchSource = `package main

import kaya "dev.kaya/bindings/go"

func main() {
	var w kaya.Widget
	w.Role(kaya.RoleHeading)
}
`

func TestAWrongFamilyConstantDoesNotCompile(t *testing.T) {
	if out, err := probeModule(t, familyMatchSource); err != nil {
		t.Fatalf("the control (Role on kaya.RoleHeading) did not build: %v\n%s", err, out)
	}
	out, err := probeModule(t, familyMismatchSource)
	if err == nil {
		t.Fatalf("w.Role(kaya.AlignCenter) built clean — the named-type wall F1 added is not there:\n%s", out)
	}
	if !strings.Contains(out, "cannot use kaya.AlignCenter") || !strings.Contains(out, "kaya.Align") ||
		!strings.Contains(out, "kaya.Role") {
		t.Fatalf("w.Role(kaya.AlignCenter) was refused for a reason other than the family "+
			"mismatch this guards — wanted \"cannot use kaya.AlignCenter\" naming both "+
			"kaya.Align and kaya.Role:\n%s", out)
	}
	t.Logf("watched refusing: w.Role(kaya.AlignCenter) — %s", strings.TrimSpace(out))
}

// F2: RecordCollection.Get is SumCollection.Get's comma-ok, present and
// absent, replacing the hand-rolled linear scan richrows.go carried.
type idiomNote struct{ Title string }

func TestRecordCollectionGetPresentAndAbsent(t *testing.T) {
	app := NewApp()
	var notes RecordCollection[string, idiomNote]
	app.Build(func(tx *Tx) {
		notes = CollectionOf[string, idiomNote](tx)
		notes.Insert(tx, "a", idiomNote{Title: "first"})
	})
	app.Build(func(tx *Tx) {
		got, ok := notes.Get(tx, "a")
		if !ok || got.Title != "first" {
			t.Fatalf("Get(%q) = %+v, %v, want {first} true", "a", got, ok)
		}
		if got, ok := notes.Get(tx, "gone"); ok || got != (idiomNote{}) {
			t.Fatalf("Get(%q) = %+v, %v, want the zero value and false", "gone", got, ok)
		}
	})
}
