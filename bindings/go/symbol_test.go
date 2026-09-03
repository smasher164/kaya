package kaya

// The semantic-icon surface's guards (docs/styling-plan.md D6). Go
// spells the closed vocabulary as plain int constants, so a caller can
// hand Symbol a number in no vocabulary at all and only the ROOT can say
// so — hence the re-exec shape styling_test.go explains: a headless
// queue never reaches a declare-time wall.

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"dev.kaya/bindings/go/internal/rootprobe"
)

// Every value the root accepts, in wire order. A constant that drifted
// from crates/kaya/src/spec.rs dies here, not as a missing glyph.
var theVocabulary = []int64{
	SymbolAdd, SymbolRemove, SymbolDelete, SymbolEdit, SymbolDone,
	SymbolClose, SymbolSearch, SymbolSettings, SymbolRefresh, SymbolInfo,
	SymbolWarning, SymbolBack, SymbolForward, SymbolMore, SymbolCopy,
	SymbolPaste, SymbolStar, SymbolLock, SymbolPerson, SymbolHome,
}

// The sentence the root prints for a value outside the vocabulary,
// pinned whole so a spec change that grows it reddens this binding too.
const theWholeVocabulary = "is not a symbol — the vocabulary is " +
	"add=1, remove=2, delete=3, edit=4, done=5, close=6, search=7, " +
	"settings=8, refresh=9, info=10, warning=11, back=12, forward=13, " +
	"more=14, copy=15, paste=16, star=17, lock=18, person=19, home=20"

// A Symbol written through a transaction that has already shipped is a
// lost write, not a late one.
func TestMenuSymbolOutsideItsTransactionDies(t *testing.T) {
	app := NewApp()
	var item MenuItem
	app.Build(func(tx *Tx) { item = tx.Window(0).Menu("File").Item("Save") })
	defer func() {
		if r := recover(); r == nil {
			t.Fatal("Symbol on a dead transaction was accepted — the write would vanish")
		}
	}()
	item.Symbol(SymbolDone)
}

// symbolTrap builds one scene through the ordinary sugar and pumps it
// through the root. It returns only when the root ALLOWED the scene.
func symbolTrap(trap string) {
	app := NewApp()
	app.Build(func(tx *Tx) {
		win := tx.Window(0).Title("symbols")
		switch trap {
		case "menu-past-the-end":
			// The next value the vocabulary would take if it grew.
			win.Menu("File").Item("Save").Symbol(21)
		case "menu-zero":
			// The natural "unset" mistake: no symbol has it.
			win.Menu("File").Item("Save").Symbol(0)
		case "menu-negative":
			win.Menu("File").Item("Save").Symbol(-1)
		case "section-past-the-end":
			// The same wall from the other surface.
			tx.AddSection(7).Title("Feed").Symbol(21)
		case "menu-whole-vocabulary":
			// Every value on every kind that takes one. A Symbol that
			// emitted nothing would sail through the dead cases too, so
			// this is what tells those two apart.
			file := win.Menu("File")
			group := win.RadioGroup("Sort")
			for i, s := range theVocabulary {
				file.Item(fmt.Sprintf("action %d", i)).Symbol(s)
				file.Toggle(fmt.Sprintf("toggle %d", i)).Symbol(s)
				file.Menu(fmt.Sprintf("nested %d", i)).Symbol(s)
				group.Option(fmt.Sprintf("option %d", i)).Symbol(s)
			}
		case "section-whole-vocabulary":
			for i, s := range theVocabulary {
				tx.AddSection(uint64(100 + i)).Title(fmt.Sprintf("s%d", i)).Symbol(s)
			}
		case "context-vocabulary":
			// The second construction site for the same item vocabulary
			// (DESIGN.md, Menus).
			catalog := tx.ContextCatalog()
			catalog.Item("Remove").Symbol(SymbolDelete)
			tx.Mount(tx.Column(func() {
				target := tx.LabelText("rename target")
				tx.ContextMenu(target).Item("Rename").Symbol(SymbolEdit)
			}))
			return
		default:
			fmt.Fprintf(os.Stderr, "unknown KAYA_SYMBOL_TRAP: %s\n", trap)
			os.Exit(2)
		}
		tx.Mount(tx.Column(func() { tx.LabelText("symbols") }))
	})
	n := rootprobe.Pump()
	fmt.Printf("kaya symbol trap %s: THE ROOT ACCEPTED IT (%d command bytes)\n", trap, n)
	os.Exit(0)
}

func runSymbolTrap(t *testing.T, trap string) (string, error) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestTheRootIsTheSymbolWall$")
	// cmd.Environ() rather than os.Environ(): tools/check-go-env.py.
	cmd.Env = append(cmd.Environ(), "KAYA_SYMBOL_TRAP="+trap)
	out, err := cmd.CombinedOutput()
	if ctx.Err() != nil {
		t.Fatalf("symbol trap %q never finished: the pump blocked, so the root applied nothing", trap)
	}
	return string(out), err
}

// Each case runs in a re-exec because a root refusal ends the process, not a
// Go panic: it crosses an extern "C" frame and nothing here can recover
// it.
//
// A SYMBOL ON A SEPARATOR IS ABSENT ON PURPOSE: Go's three Separator
// spellings return nothing at all, so `.Separator().Symbol(…)` does not
// compile, which is the stronger guard.
func TestTheRootIsTheSymbolWall(t *testing.T) {
	if trap, set := LookupEnv("KAYA_SYMBOL_TRAP"); set && trap != "" {
		symbolTrap(trap)
		return
	}
	for _, c := range []struct {
		trap    string
		refused bool
		want    string
	}{
		{"menu-past-the-end", true, "21 " + theWholeVocabulary},
		{"menu-zero", true, "0 is not a symbol"},
		{"menu-negative", true, "-1 is not a symbol"},
		{"section-past-the-end", true, "21 " + theWholeVocabulary},
		{"menu-whole-vocabulary", false, "THE ROOT ACCEPTED IT"},
		{"section-whole-vocabulary", false, "THE ROOT ACCEPTED IT"},
		{"context-vocabulary", false, "THE ROOT ACCEPTED IT"},
	} {
		t.Run(c.trap, func(t *testing.T) {
			out, err := runSymbolTrap(t, c.trap)
			if c.refused && err == nil {
				t.Fatalf("the root accepted %q — the wall this vocabulary depends on is not there:\n%s", c.trap, out)
			}
			if !c.refused && err != nil {
				t.Fatalf("the root refused %q, which is legal Go and a legal scene: %v\n%s", c.trap, err, out)
			}
			if !strings.Contains(out, c.want) {
				t.Fatalf("%q answered with something else — wanted %q in:\n%s", c.trap, c.want, out)
			}
		})
	}
}
