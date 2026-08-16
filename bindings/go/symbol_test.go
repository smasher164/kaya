package kaya

// The SEMANTIC ICON surface's guards (docs/styling-plan.md D6), pinned
// where a lane already walks: tools/check-abort.sh runs
// `go test dev.kaya/bindings/go` on every desktop lane, so these run
// with no GUI, no window and no mac.
//
// AND NOTHING HERE READS A SYMBOL BACK THROUGH THE API THAT WROTE IT.
// Go spells the closed vocabulary as plain int constants — the Role,
// Align and SectionsPresentation idiom — so a caller can hand Symbol a
// number that is in no vocabulary at all, and only the ROOT can say so.
// Each case below builds a scene through the ordinary Go sugar, submits
// it, and pumps kaya_next_commands so the core's Scene actually applies
// it: a transaction the root refuses aborts the child process with the
// root's own sentence on stderr, and the parent asserts on the corpse.
// The styling_test.go precedent one file over, for the same reason —
// a headless queue never reaches a declare-time wall, and the binding's
// opinion of the rule is not the rule.

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

// theVocabulary is every value the root accepts, in wire order. The
// dead cases below pin the refusal sentence and the alive ones walk the
// whole table through both surfaces, so a constant that drifted from
// crates/kaya/src/spec.rs dies here rather than as a missing glyph.
var theVocabulary = []int64{
	SymbolAdd, SymbolRemove, SymbolDelete, SymbolEdit, SymbolDone,
	SymbolClose, SymbolSearch, SymbolSettings, SymbolRefresh, SymbolInfo,
	SymbolWarning, SymbolBack, SymbolForward, SymbolMore, SymbolCopy,
	SymbolPaste, SymbolStar, SymbolLock, SymbolPerson, SymbolHome,
}

// The sentence the root prints for a value outside the vocabulary. It
// names EVERY value it would have accepted rather than a count, because
// the reader's next question is always "then what may I say?" — and
// pinning the whole list here is what makes a spec change that grows the
// vocabulary red this binding too, instead of silently leaving Go's
// Symbol doc comment listing nineteen of twenty-one names.
const theWholeVocabulary = "is not a symbol — the vocabulary is " +
	"add=1, remove=2, delete=3, edit=4, done=5, close=6, search=7, " +
	"settings=8, refresh=9, info=10, warning=11, back=12, forward=13, " +
	"more=14, copy=15, paste=16, star=17, lock=18, person=19, home=20"

// The chain discipline every construction method carries (Grow's
// precedent, and Role's beside it): a Symbol written through a
// transaction that has already shipped is a lost write, not a late one.
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
			// 21 is the next value the vocabulary would take if it grew,
			// which is exactly the number an app guesses.
			win.Menu("File").Item("Save").Symbol(21)
		case "menu-zero":
			// Zero is the natural "unset" mistake: no symbol has it, and
			// a bare integer slot would have carried it to a backend.
			win.Menu("File").Item("Save").Symbol(0)
		case "menu-negative":
			win.Menu("File").Item("Save").Symbol(-1)
		case "section-past-the-end":
			// The SAME wall from the other surface — one check_symbol in
			// the root serves both, so the menu slot and the section slot
			// cannot answer differently, and this is the Go chain
			// proving it reaches it.
			tx.AddSection(7).Title("Feed").Symbol(21)
		case "menu-whole-vocabulary":
			// Every value, on every kind that takes one. If Symbol
			// emitted nothing, or emitted some OTHER menu prop, the dead
			// cases above would sail through with nothing to refuse —
			// this is the case that tells those two apart.
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
			// The context anchor is a second construction site for the
			// same item vocabulary (DESIGN.md, Menus): the anchor decides
			// the spelling, never the semantics, so a symbol reaches the
			// root from here too.
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
	// cmd.Environ() rather than os.Environ(): tools/check-go-env.sh keeps
	// Go's own view of the environment out of this tree entirely (it is
	// empty forever in an Android c-shared guest), and this is the exec
	// package's own spelling of "what the child will inherit, plus this".
	cmd.Env = append(cmd.Environ(), "KAYA_SYMBOL_TRAP="+trap)
	out, err := cmd.CombinedOutput()
	if ctx.Err() != nil {
		t.Fatalf("symbol trap %q never finished: the pump blocked, so the root applied nothing", trap)
	}
	return string(out), err
}

// THE WALL IS THE ROOT'S, AND THIS IS WHAT PROVES THE GO SURFACE
// REACHES IT. Each case runs in a re-exec of this binary because a root
// refusal is an abort, not a Go panic: it crosses an extern "C" frame,
// so nothing in this process can recover it.
//
// A SYMBOL ON A SEPARATOR IS ABSENT FROM THIS TABLE ON PURPOSE, and its
// absence is not a hole. The root refuses one (crates/kaya/src/scene.rs,
// `symbol_on_a_separator_rejected`), but Go's three Separator spellings
// — MenuItem.Separator, ContextRef.Separator, ContextCatalog.Separator
// — all return nothing at all, so `.Separator().Symbol(…)` does not
// compile. That is the stronger guard of the two, and a trap here could
// only ever test a shape the language already forbids.
func TestTheRootIsTheSymbolWall(t *testing.T) {
	// LookupEnv is the binding's own reader (through C's getenv), which
	// is the only environment spelling this tree allows anywhere.
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
