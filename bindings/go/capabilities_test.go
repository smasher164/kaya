package kaya

// The capability query's guards (crates/kaya/src/app.rs carries the
// canonical note). These run with no GUI: tools/check-abort.py runs
// `go test dev.kaya/bindings/go` on every desktop lane.
//
// The re-exec shape is identity_test.go's, for its reason: a root
// refusal ends the process, not a Go panic (fault.rs's unwatched exit),
// so nothing in this process can recover it.

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"reflect"
	"strings"
	"testing"
	"time"

	"dev.kaya/bindings/go/internal/rootprobe"
)

// Named booleans and nothing else. Reflection asks the type itself, so
// this covers bits nobody has invented yet.
func TestCapabilitiesAreNamedBooleans(t *testing.T) {
	ct := reflect.TypeOf(Caps{})
	if ct.NumField() == 0 {
		t.Fatal("Caps has no fields at all — a capability surface that says nothing agrees with every host")
	}
	for i := 0; i < ct.NumField(); i++ {
		f := ct.Field(i)
		if f.Type.Kind() != reflect.Bool {
			t.Errorf("Caps.%s is %s, not bool — the raw word is the binding's floor and no guest should ever see it",
				f.Name, f.Type.Kind())
		}
		if !f.IsExported() {
			t.Errorf("Caps.%s is unexported — a flag a guest cannot read is a flag that does not exist", f.Name)
		}
	}
}

// The decode, against the word the core actually handed over.
// capAuxWindows is the header's own KAYA_CAP_AUX_WINDOWS (cgo reads
// kaya.h), so the same wrong number cannot be written twice.
func TestCapabilitiesDecodeTheCoresWord(t *testing.T) {
	bits := capabilityBits()
	if want := bits&capAuxWindows != 0; Capabilities().AuxWindows != want {
		t.Fatalf("AuxWindows is %v where the core's word %#x says %v",
			Capabilities().AuxWindows, bits, want)
	}
	// Catches what a bit test cannot: a symbol that resolved to
	// something other than kaya_capabilities and returns 0.
	if !Capabilities().AuxWindows {
		t.Fatalf("this desktop reports no auxiliary windows (word %#x) — either the core's own arm changed or kaya_capabilities is not the symbol being called",
			bits)
	}
}

// capsTrap builds the one scene the capability governs and pumps it
// through the root. It returns only when the root ALLOWED it.
func capsTrap() {
	app := NewApp()
	app.Build(func(tx *Tx) {
		tx.Mount(tx.Column(func() { tx.LabelText("caps") }))
		// Unconditional on purpose: this process stands in for a guest
		// that ignored the answer.
		untitled := tx.CreateWindow(1).Size(360, 240)
		tx.MountIn(untitled.Id(), tx.Column(func() { tx.LabelText("aux") }))
	})
	batch := rootprobe.PumpBatch()
	fmt.Printf("kaya caps trap: THE ROOT ACCEPTED IT (%d command bytes)\n", len(batch))
	os.Exit(0)
}

// Capabilities inform; walls refuse. The child ignores the answer and
// calls create_window regardless, so the query cannot pass by agreeing
// with itself.
func TestTheCapabilityAnswerAndTheWallAgree(t *testing.T) {
	if trap, set := LookupEnv("KAYA_CAPS_TRAP"); set && trap != "" {
		capsTrap()
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0],
		"-test.run=^TestTheCapabilityAnswerAndTheWallAgree$")
	// cmd.Environ() rather than os.Environ(): tools/check-go-env.py.
	cmd.Env = append(cmd.Environ(), "KAYA_CAPS_TRAP=aux-window")
	out, err := cmd.CombinedOutput()
	if ctx.Err() != nil {
		t.Fatalf("the capability trap never finished: the pump blocked, so the root applied nothing")
	}
	text := string(out)

	if Capabilities().AuxWindows {
		if err != nil {
			t.Fatalf("capabilities() says this host HAS auxiliary windows and the root refused create_window anyway (%v) — a guest that believed the answer would abort one step into its own scene:\n%s",
				err, text)
		}
		if !strings.Contains(text, "THE ROOT ACCEPTED IT") {
			t.Fatalf("the trap exited 0 without the root ever taking the transaction:\n%s", text)
		}
		return
	}
	if err == nil {
		t.Fatalf("capabilities() says this host has NO auxiliary windows and the root took create_window anyway — a guest that believed the answer skipped a window this host would have given it:\n%s",
			text)
	}
	if !strings.Contains(text, "this host has no auxiliary windows") {
		t.Fatalf("the root refused create_window with something other than the capability wall:\n%s", text)
	}
}
