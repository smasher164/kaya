package kaya

// docs/styling-plan.md slice 1. Nothing here reads a styling write back
// through the API that made it — every platform's accent read-back lies. The
// re-exec: a root refusal ends the process, not a Go panic (fault.rs).

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

// seed, mask, light, dark: four u32s after the 8-byte frame header.
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

// A record per override would die on the root's set-once wall, on a branded
// app's first frame.
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
		// The zero value is "unstated": an AccentOverride nobody filled
		// brands with the seed rather than with black.
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

// Last-wins would shadow a brand book's real value with no error.
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

// The KIND is read out of the create_widget that minted the widget: the claim
// is "a label wearing that role", and half of it is the widget kind.
func sugarRole(t *testing.T, build func(*Tx)) setProp {
	t.Helper()
	app := NewApp()
	kinds := map[uint64]uint32{}
	var roles []setProp
	app.Build(func(tx *Tx) {
		build(tx)
		for _, rec := range tx.records {
			switch recKind(rec) {
			case txCreateWidget:
				kinds[binary.LittleEndian.Uint64(rec[8:])] = binary.LittleEndian.Uint32(rec[16:])
			case txSetProperty:
				if p := decodeSetProp(t, rec); p.prop == PropRole {
					roles = append(roles, p)
				}
			}
		}
	})
	if len(roles) != 1 {
		t.Fatalf("the sugar queued %d role writes, want exactly 1", len(roles))
	}
	if k := kinds[roles[0].widget]; k != KindLabel {
		t.Fatalf("the role rode on kind %d, want label (%d)", k, KindLabel)
	}
	return roles[0]
}

type sugarRec struct{ Title string }

type sugarNote struct{ Body string }

type sugarTodo struct{ Body string }

// The ROLE NUMBER is what nothing else in this binding reads back, so a
// heading spelling caption's 4 would ship.
func TestHeadingAndCaptionSugarIsALabelWearingItsRole(t *testing.T) {
	tplRows := func(body func(Row)) func(*Tx) {
		return func(tx *Tx) {
			for row := range tx.Rows(tx.Collection()).All() {
				body(row)
			}
		}
	}
	recRows := func(body func(RecordCollection[string, sugarRec], *Tpl)) func(*Tx) {
		return func(tx *Tx) {
			c := CollectionOf[string, sugarRec](tx)
			for row := range tx.Rows(c.Collection).All() {
				body(c, row.Tpl)
			}
		}
	}
	sumRows := func(body func(SumCase[string, sugarNote])) func(*Tx) {
		return func(tx *Tx) {
			c := SumOf[string, any](tx, sugarNote{}, sugarTodo{})
			for row := range tx.Rows(c.Collection).All() {
				c.Case[sugarNote](row.Tpl, body)
				c.Case[sugarTodo](row.Tpl, func(SumCase[string, sugarTodo]) {})
			}
		}
	}
	title := func(r *sugarRec) *string { return &r.Title }
	body := func(n *sugarNote) *string { return &n.Body }

	for _, c := range []struct {
		name  string
		want  int64
		build func(*Tx)
	}{
		{"Tx.HeadingText", RoleHeading, func(tx *Tx) { tx.HeadingText("Sections") }},
		{"Tx.Heading", RoleHeading, func(tx *Tx) { tx.Heading(tx.Signal("t")) }},
		{"Tx.CaptionText", RoleCaption, func(tx *Tx) { tx.CaptionText("Sections") }},
		{"Tx.Caption", RoleCaption, func(tx *Tx) { tx.Caption(tx.Signal("t")) }},
		{"Tpl.HeadingText", RoleHeading, tplRows(func(r Row) { r.HeadingText("Sections") })},
		{"Tpl.HeadingBound", RoleHeading, tplRows(func(r Row) { r.HeadingBound(r.Value()) })},
		{"Tpl.CaptionText", RoleCaption, tplRows(func(r Row) { r.CaptionText("Sections") })},
		{"Tpl.CaptionBound", RoleCaption, tplRows(func(r Row) { r.CaptionBound(r.Value()) })},
		{"Row.Heading", RoleHeading, tplRows(func(r Row) { r.Heading(r.Value()) })},
		{"Row.Caption", RoleCaption, tplRows(func(r Row) { r.Caption(r.Value()) })},
		{"RecordCollection.Heading", RoleHeading,
			recRows(func(c RecordCollection[string, sugarRec], tp *Tpl) { c.Heading(tp, title) })},
		{"RecordCollection.Caption", RoleCaption,
			recRows(func(c RecordCollection[string, sugarRec], tp *Tpl) { c.Caption(tp, title) })},
		{"SumCase.HeadingText", RoleHeading,
			sumRows(func(sc SumCase[string, sugarNote]) { sc.HeadingText("Sections") })},
		{"SumCase.Heading", RoleHeading,
			sumRows(func(sc SumCase[string, sugarNote]) { sc.Heading(body) })},
		{"SumCase.CaptionText", RoleCaption,
			sumRows(func(sc SumCase[string, sugarNote]) { sc.CaptionText("Sections") })},
		{"SumCase.Caption", RoleCaption,
			sumRows(func(sc SumCase[string, sugarNote]) { sc.Caption(body) })},
	} {
		t.Run(c.name, func(t *testing.T) {
			got := sugarRole(t, c.build)
			if got.source != SourceConst || got.tag != ValueI64 || got.i64 != c.want {
				t.Errorf("%s recorded %+v, want a const i64 role %d", c.name, got, c.want)
			}
		})
	}
}

// ---- the real-root half ------------------------------------------

// stylingTrap returns only when the root ALLOWED the scene.
func stylingTrap(trap string) {
	app := NewApp()
	app.Build(func(tx *Tx) {
		switch trap {
		case "role-on-label":
			// Destructive is an ACTION's emphasis; a label presses nothing.
			tx.Mount(tx.Column(func() { tx.LabelText("Sections").Role(RoleDestructive) }))
		case "role-on-button":
			tx.Mount(tx.Column(func() {
				tx.LabelText("Sections").Role(RoleHeading)
				tx.Button("Delete", nil).Role(RoleDestructive)
				tx.Button("Save", nil).Role(RoleProminent)
			}))
		case "role-unknown":
			// Go spells the vocabulary as int constants, so a caller can hand
			// it a number that is not in it.
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
	// cmd.Environ() rather than os.Environ(): tools/check-go-env.py.
	cmd.Env = append(cmd.Environ(), "KAYA_STYLING_TRAP="+trap)
	out, err := cmd.CombinedOutput()
	if ctx.Err() != nil {
		t.Fatalf("styling trap %q never finished: the pump blocked, so the root applied nothing", trap)
	}
	return string(out), err
}

// The ALIVE cases carry as much weight as the dead ones: a Role chain
// that emitted nothing would sail through every dead case too, so the
// pairing is what tells "the root refuses this" from "nothing was sent".
func TestTheRootIsTheStylingWall(t *testing.T) {
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
		{"role-unknown", true, "9 is not a role (destructive=1, prominent=2, heading=3, caption=4, plain=5)"},
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
