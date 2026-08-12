package kaya

// The styling surface's guards (docs/styling-plan.md slice 1), pinned
// where a lane already walks: tools/check-abort.sh runs
// `go test dev.kaya/bindings/go` on every desktop lane, so these run
// with no GUI, no window and no mac.
//
// AND NOTHING HERE READS A STYLING WRITE BACK THROUGH THE API THAT MADE
// IT — the pass's own doctrine, because every platform's accent
// read-back lies (macOS FB13688723, GTK's AdwStyleManager, WinUI's
// no-op SystemAccentColor write). Two distinct surfaces answer instead:
//
//   - the WIRE BYTES the core will consume, decoded from the queued
//     record: that is what leaves this process, not what the binding
//     believes it queued.
//   - THE REAL ROOT, driven end-to-end. Each trap below builds a scene
//     through the ordinary Go sugar, submits it, and pumps
//     kaya_next_commands so the core's Scene actually applies it. A
//     transaction the root refuses aborts the child process with the
//     root's own sentence on stderr; the parent asserts on the corpse.
//     That is the only way to test a declare-time wall from a binding:
//     a headless queue never reaches the check, and the binding's
//     opinion of the rule is not the rule.

import (
	"context"
	"encoding/binary"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"dev.kaya/bindings/go/internal/rootprobe"
)

// ---- the wire-byte half ------------------------------------------

// brandFields decodes one set_brand_accent record: seed, mask, light,
// dark, four u32s after the 8-byte frame header.
func brandFields(rec []byte) (seed, mask, light, dark uint32) {
	return binary.LittleEndian.Uint32(rec[8:12]),
		binary.LittleEndian.Uint32(rec[12:16]),
		binary.LittleEndian.Uint32(rec[16:20]),
		binary.LittleEndian.Uint32(rec[20:24])
}

func brandRecord(t *testing.T, build func(tx *Tx)) []byte {
	t.Helper()
	app := NewApp()
	var found []byte
	app.Build(func(tx *Tx) {
		build(tx)
		for _, r := range tx.records {
			if recKind(r) == txSetBrandAccent {
				if found != nil {
					t.Fatalf("the accent queued more than one record — the root's set-once wall would refuse the second")
				}
				found = r
			}
		}
	})
	if found == nil {
		t.Fatal("BrandAccent queued no record at all — the app would ship unbranded with no error anywhere")
	}
	return found
}

// ONE CALL IS ONE RECORD, whatever it is given. The override form is
// variadic, so the shape that would be easy to write by accident — one
// record per override — is exactly the shape the root refuses at the
// second one, and it would only ever be seen on a branded app's first
// frame.
func TestBrandAccentPacksOneRecord(t *testing.T) {
	for _, c := range []struct {
		name              string
		build             func(tx *Tx)
		mask, light, dark uint32
	}{
		{"seed only", func(tx *Tx) { tx.BrandAccent(0x3584E4) }, 0, 0, 0},
		{"light", func(tx *Tx) { tx.BrandAccent(0x3584E4, LightAccent(0x1C71D8)) }, 1, 0x1C71D8, 0},
		{"dark", func(tx *Tx) { tx.BrandAccent(0x3584E4, DarkAccent(0x62A0EA)) }, 2, 0, 0x62A0EA},
		{"both", func(tx *Tx) {
			tx.BrandAccent(0x3584E4, DarkAccent(0x62A0EA), LightAccent(0x1C71D8))
		}, 3, 0x1C71D8, 0x62A0EA},
		// The zero value is "unstated", so a caller holding an
		// AccentOverride variable it never filled brands with the seed
		// rather than with black.
		{"zero value", func(tx *Tx) { tx.BrandAccent(0x3584E4, AccentOverride{}) }, 0, 0, 0},
	} {
		t.Run(c.name, func(t *testing.T) {
			seed, mask, light, dark := brandFields(brandRecord(t, c.build))
			if seed != 0x3584E4 {
				t.Errorf("seed shipped as %#06x, want 0x3584e4", seed)
			}
			if mask != c.mask || light != c.light || dark != c.dark {
				t.Errorf("shipped mask=%d light=%#06x dark=%#06x, want mask=%d light=%#06x dark=%#06x",
					mask, light, dark, c.mask, c.light, c.dark)
			}
		})
	}
}

// NAMING EACH OVERRIDE IS THE WHOLE REASON THE FORM IS VARIADIC, and
// last-wins would give that away: two lights in one call is a brand
// book's real value shadowed with no error anywhere.
func TestBrandAccentRefusesTheSameAppearanceTwice(t *testing.T) {
	defer func() {
		r := recover()
		if r == nil {
			t.Fatal("two light overrides in one call were accepted — one of them vanished silently")
		}
		if !strings.Contains(fmt.Sprint(r), "same appearance override twice") {
			t.Fatalf("panicked with %v, want the duplicate-override sentence", r)
		}
	}()
	app := NewApp()
	app.Build(func(tx *Tx) {
		tx.BrandAccent(0x3584E4, LightAccent(0x1C71D8), LightAccent(0x62A0EA))
	})
}

// The chain discipline every construction method carries (Grow's
// precedent): a Role written through a transaction that has already
// shipped is a lost write, not a late one.
func TestRoleOutsideItsBuildTransactionDies(t *testing.T) {
	app := NewApp()
	var label Widget
	app.Build(func(tx *Tx) { label = tx.LabelText("Sections") })
	defer func() {
		if r := recover(); r == nil {
			t.Fatal("Role on a dead transaction was accepted — the write would vanish")
		}
	}()
	label.Role(RoleHeading)
}

// ---- the real-root half ------------------------------------------

// stylingTrap builds one scene through the ordinary sugar and pumps it
// through the root. It returns only when the root ALLOWED the scene.
func stylingTrap(trap string) {
	app := NewApp()
	app.Build(func(tx *Tx) {
		switch trap {
		case "role-on-label":
			// Destructive is an ACTION's emphasis; a label presses
			// nothing. The root names both sides.
			tx.Mount(tx.Column(func() { tx.LabelText("Sections").Role(RoleDestructive) }))
		case "role-on-button":
			// The styling scene's own pairing, which must survive.
			tx.Mount(tx.Column(func() {
				tx.LabelText("Sections").Role(RoleHeading)
				tx.Button("Delete", nil).Role(RoleDestructive)
				tx.Button("Save", nil).Role(RoleProminent)
			}))
		case "role-unknown":
			// Go spells the closed vocabulary as int constants, so a
			// caller can hand it a number that is not in it; the root
			// is what refuses.
			tx.Mount(tx.Column(func() { tx.Button("Delete", nil).Role(9) }))
		case "inset-negative":
			tx.Window(0).Inset(-1)
			tx.Mount(tx.Column(func() { tx.LabelText("Sections") }))
		case "inset-zero":
			// Zero is the point: the editor's full bleed.
			tx.Window(0).Inset(0)
			tx.Mount(tx.Column(func() { tx.LabelText("Sections") }))
		case "brand-twice":
			tx.BrandAccent(0x3584E4)
			tx.BrandAccent(0x62A0EA)
			tx.Mount(tx.Column(func() { tx.LabelText("Sections") }))
		case "brand-overrides":
			// One call, both appearances: if the variadic form shipped
			// a record per override this would die on the set-once
			// wall, which is why the alive case is worth as much as the
			// dead ones.
			tx.BrandAccent(0x3584E4, LightAccent(0x1C71D8), DarkAccent(0x62A0EA))
			tx.Mount(tx.Column(func() { tx.LabelText("Sections") }))
		default:
			fmt.Fprintf(os.Stderr, "unknown KAYA_STYLING_TRAP: %s\n", trap)
			os.Exit(2)
		}
	})
	n := rootprobe.Pump()
	fmt.Printf("kaya styling trap %s: THE ROOT ACCEPTED IT (%d command bytes)\n", trap, n)
	os.Exit(0)
}

func runStylingTrap(t *testing.T, trap string) (string, error) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestTheRootIsTheStylingWall$")
	// cmd.Environ() rather than os.Environ(): tools/check-go-env.sh keeps
	// Go's own view of the environment out of this tree entirely (it is
	// empty forever in an Android c-shared guest), and this is the
	// exec package's own spelling of "what the child will inherit,
	// plus this".
	cmd.Env = append(cmd.Environ(), "KAYA_STYLING_TRAP="+trap)
	out, err := cmd.CombinedOutput()
	if ctx.Err() != nil {
		t.Fatalf("styling trap %q never finished: the pump blocked, so the root applied nothing", trap)
	}
	return string(out), err
}

// THE WALLS ARE THE ROOT'S, AND THIS IS WHAT PROVES THE GO SURFACE
// REACHES THEM. Each case runs in a re-exec of this binary because a
// root refusal is an abort, not a Go panic: it crosses an extern "C"
// frame, so nothing in this process can recover it.
//
// The ALIVE cases carry as much weight as the dead ones. A binding
// whose Role chain emitted nothing would sail through every dead case
// too (nothing to refuse), so the pairing is what distinguishes "the
// root refuses this" from "the binding sends nothing".
func TestTheRootIsTheStylingWall(t *testing.T) {
	// LookupEnv is the binding's own reader (through C's getenv), which
	// is the only environment spelling this tree allows anywhere.
	if trap, set := LookupEnv("KAYA_STYLING_TRAP"); set && trap != "" {
		stylingTrap(trap)
		return
	}
	for _, c := range []struct {
		trap    string
		refused bool
		want    string
	}{
		{"role-on-label", true, "role destructive does not fit Label"},
		{"role-unknown", true, "9 is not a role (destructive=1, prominent=2, heading=3)"},
		{"inset-negative", true, "window inset must be finite and non-negative, got -1"},
		{"brand-twice", true, "set_brand_accent called twice"},
		{"role-on-button", false, "THE ROOT ACCEPTED IT"},
		{"inset-zero", false, "THE ROOT ACCEPTED IT"},
		{"brand-overrides", false, "THE ROOT ACCEPTED IT"},
	} {
		t.Run(c.trap, func(t *testing.T) {
			out, err := runStylingTrap(t, c.trap)
			if c.refused && err == nil {
				t.Fatalf("the root accepted %q — the wall this scene depends on is not there:\n%s", c.trap, out)
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
