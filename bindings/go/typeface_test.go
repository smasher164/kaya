package kaya

// The brand typeface's guards (docs/styling-plan.md Slice 2b), pinned
// where a lane already walks: tools/check-abort.sh runs
// `go test dev.kaya/bindings/go` on every desktop lane, so these run
// with no GUI, no window and no font installed anywhere.
//
// AND NOTHING HERE READS THE TYPEFACE BACK THROUGH THE API THAT WROTE
// IT — styling_test.go's doctrine, and the typeface is the surface it
// was written for: every platform's font API renders SOMETHING for a
// family it does not have, so a request echoed back is the one answer
// that is always available and never means anything. Two surfaces
// answer instead, neither of them the binding's opinion:
//
//   - the WIRE BYTES the core will consume, decoded out of the queued
//     record;
//   - THE APPLY STREAM on the far side of the root, decoded out of the
//     batch a real pump produced. That is the request as a BACKEND
//     receives it — family, per-platform rows, the core's own platform
//     stamp, and the font bytes fetched back through the blob table —
//     and it is the only place in this process where "what the app
//     asked for" and "what a lowering will act on" are the same object.
//
// The RESOLVED family (did the platform actually swap?) is not a
// question this file can ask: it lives in the text system, and
// expect_typeface on a real lane is what asks it (tools/scenes/
// typeface.steps).

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"testing"
	"time"

	"dev.kaya/bindings/go/internal/rootprobe"
)

// ---- one decoder, both channels ----------------------------------
//
// The tx record and the apply record carry the SAME body — the core
// writes both through one function (crates/kaya/src/wire.rs's
// write_typeface) precisely so neither side can drift — and they differ
// in exactly one word: the tx side's second u32 is reserved (a guest
// cannot name its platform and is never asked to), while the apply
// side's carries WHICH platform the core was compiled for, so a
// lowering picks its row without carrying a copy of the vocabulary.

type wireValue struct {
	tag uint32
	i64 int64  // I64 payload, and a BLOB's handle
	str string // STR payload
}

type platformRow struct {
	tag    int64
	family string
}

type typefaceBody struct {
	mask   uint32
	second uint32
	family string
	rows   []platformRow
	font   wireValue
}

// reader walks one record's bytes. Offsets are relative to the RECORD,
// which is what the 8-byte padding inside values is relative to as well.
type reader struct {
	b  []byte
	at int
}

func (r *reader) u32() uint32 {
	v := binary.LittleEndian.Uint32(r.b[r.at:])
	r.at += 4
	return v
}

func (r *reader) value() wireValue {
	tag, n := r.u32(), int(r.u32())
	start := r.at
	v := wireValue{tag: tag}
	switch tag {
	case ValueI64, ValueBlob:
		v.i64 = int64(binary.LittleEndian.Uint64(r.b[start:]))
	case ValueStr:
		v.str = string(r.b[start : start+n])
	default:
		panic(fmt.Sprintf("kaya test: value tag %d in a typeface record", tag))
	}
	r.at = start + n
	for r.at%8 != 0 {
		r.at++
	}
	return v
}

// decodeTypeface reads one whole record — header included — as a
// typeface body.
func decodeTypeface(rec []byte) typefaceBody {
	r := &reader{b: rec, at: 8} // past {u32 size, u16 kind, u16 pad}
	body := typefaceBody{mask: r.u32(), second: r.u32()}
	family := r.value()
	if family.tag != ValueStr {
		panic(fmt.Sprintf("kaya test: family rode as tag %d, not a string", family.tag))
	}
	body.family = family.str
	// THE PAIRS ARE FLAT, tag then family, counted as VALUES — so an odd
	// count is a mangled record and not a half-written row, which is why
	// the core refuses on the count rather than on the shape.
	flat := int(r.u32())
	r.u32() // reserved
	if flat%2 != 0 {
		panic(fmt.Sprintf("kaya test: %d platform values, which is not pairs", flat))
	}
	for i := 0; i < flat; i += 2 {
		tag, fam := r.value(), r.value()
		if tag.tag != ValueI64 || fam.tag != ValueStr {
			panic(fmt.Sprintf("kaya test: platform pair rode as (%d, %d)", tag.tag, fam.tag))
		}
		body.rows = append(body.rows, platformRow{tag: tag.i64, family: fam.str})
	}
	body.font = r.value()
	return body
}

func (b typefaceBody) rowString() string {
	parts := make([]string, 0, len(b.rows))
	for _, row := range b.rows {
		parts = append(parts, fmt.Sprintf("%d=%s", row.tag, row.family))
	}
	return "[" + strings.Join(parts, " ") + "]"
}

// ---- the wire-byte half ------------------------------------------

// typefaceRecord submits nothing: it reads the record the binding
// QUEUED, which is what would leave this process.
func typefaceRecord(t *testing.T, build func(tx *Tx)) []byte {
	t.Helper()
	app := NewApp()
	var found []byte
	app.Build(func(tx *Tx) {
		build(tx)
		for _, r := range tx.records {
			if recKind(r) == txSetBrandTypeface {
				if found != nil {
					t.Fatalf("the typeface queued more than one record — the root's set-once wall would refuse the second")
				}
				found = r
			}
		}
	})
	if found == nil {
		t.Fatal("BrandTypeface queued no record at all — the app would ship in the platform's own face with no error anywhere")
	}
	return found
}

// A REAL FONT IS NOT NEEDED AND WOULD PROVE LESS. The core never parses
// these bytes (crates/kaya/src/scene.rs says so, with its reason:
// whether a blob is a font is a question only a platform's font manager
// can answer), so what this file can prove about the blob is that the
// CHANNEL carries it — every byte, from a Go slice to the apply record a
// backend reads. Whether a real font registers is each backend's probe,
// on its own platform, against its own font API.
var typefaceFontBytes = func() []byte {
	b := make([]byte, 1024)
	for i := range b {
		b[i] = byte(i * 7)
	}
	return b
}()

// ONE CALL IS ONE RECORD, whatever it is given — the accent's clause,
// and the shape that would be easy to write by accident (a record per
// override) is exactly what the root refuses at the second one, on a
// branded app's first frame and never again.
func TestBrandTypefacePacksOneRecord(t *testing.T) {
	for _, c := range []struct {
		name  string
		build func(tx *Tx)
		mask  uint32
		rows  string
		blob  bool
	}{
		{"family only", func(tx *Tx) { tx.BrandTypeface("Georgia") }, 0, "[]", false},
		{"one platform row", func(tx *Tx) {
			tx.BrandTypeface("Georgia", PlatformFamily(PlatformLinux, "DejaVu Serif"))
		}, 0, "[3=DejaVu Serif]", false},
		// AUTHOR ORDER IS WIRE ORDER, and it is observable: a lowering
		// takes the FIRST row it matches, which is why the root refuses a
		// platform named twice instead of picking one.
		{"two platform rows", func(tx *Tx) {
			tx.BrandTypeface("Georgia",
				PlatformFamily(PlatformWindows, "Segoe UI"),
				PlatformFamily(PlatformLinux, "DejaVu Serif"))
		}, 0, "[4=Segoe UI 3=DejaVu Serif]", false},
		{"font bytes", func(tx *Tx) {
			tx.BrandTypeface("Inter", FontBytes(typefaceFontBytes))
		}, 1, "[]", true},
		{"rows and bytes together", func(tx *Tx) {
			tx.BrandTypeface("Inter",
				PlatformFamily(PlatformMac, "Georgia"),
				FontBytes(typefaceFontBytes))
		}, 1, "[1=Georgia]", true},
	} {
		t.Run(c.name, func(t *testing.T) {
			body := decodeTypeface(typefaceRecord(t, c.build))
			if body.mask != c.mask {
				t.Errorf("mask shipped as %d, want %d — bit 0 is the whole of \"a font blob rides\"", body.mask, c.mask)
			}
			if body.second != 0 {
				t.Errorf("the tx record's second word is %d, want 0 — a guest cannot name its platform and the core stamps that field on the way out", body.second)
			}
			if got := body.rowString(); got != c.rows {
				t.Errorf("platform rows shipped as %s, want %s", got, c.rows)
			}
			// THE SLOT IS ALWAYS WRITTEN, so the record's field count
			// never varies with the payload: an absent font rides as an
			// empty string, and the mask alone says which it is.
			if c.blob {
				if body.font.tag != ValueBlob || body.font.i64 == 0 {
					t.Errorf("font slot shipped as tag %d handle %d, want a live blob handle", body.font.tag, body.font.i64)
				}
			} else if body.font.tag != ValueStr || body.font.str != "" {
				t.Errorf("font slot shipped as tag %d %q, want an empty string", body.font.tag, body.font.str)
			}
		})
	}
	// The family rides where it says it does — checked once, apart from
	// the table, so a decoder that read the wrong field could not agree
	// with every row above by reading nothing.
	if body := decodeTypeface(typefaceRecord(t, func(tx *Tx) {
		tx.BrandTypeface("Georgia", PlatformFamily(PlatformIos, "Palatino"))
	})); body.family != "Georgia" {
		t.Errorf("family shipped as %q, want \"Georgia\"", body.family)
	}
}

// TWO FONTS IN ONE CALL is the one thing the wire cannot say: there is a
// single blob slot, so last-wins would ship one of them and drop the
// other with no error anywhere — and it would be the app's identity that
// vanished. The accent's duplicate-appearance refusal, verbatim.
func TestBrandTypefaceRefusesTwoFonts(t *testing.T) {
	defer func() {
		r := recover()
		if r == nil {
			t.Fatal("two FontBytes in one call were accepted — one font vanished silently")
		}
		if !strings.Contains(fmt.Sprint(r), "two FontBytes") {
			t.Fatalf("panicked with %v, want the duplicate-font sentence", r)
		}
	}()
	app := NewApp()
	app.Build(func(tx *Tx) {
		tx.BrandTypeface("Inter", FontBytes(typefaceFontBytes), FontBytes([]byte("other")))
	})
}

// ---- the real-root half ------------------------------------------

// hostPlatform is the tag this host's core stamps into the apply
// record, derived from Go's own idea of the platform rather than from
// the record it is checking — two independent answers, which is what
// makes the comparison worth making. Zero means "not a platform this
// test runs on", and the stamp goes unasserted there rather than
// guessed.
var hostPlatform = map[string]int64{
	"darwin":  PlatformMac,
	"linux":   PlatformLinux,
	"windows": PlatformWindows,
}[runtime.GOOS]

// typefaceTrap builds one scene through the ordinary Go sugar and pumps
// it through the root. It returns only when the root ALLOWED the scene.
func typefaceTrap(trap string) {
	app := NewApp()
	mount := func(tx *Tx) { tx.Mount(tx.Column(func() { tx.LabelText("typeface") })) }
	switch trap {
	case "plain":
		// The typeface scene's own opening, which must survive.
		app.Build(func(tx *Tx) {
			tx.BrandTypeface("Georgia")
			mount(tx)
		})
	case "full":
		// Every part of the grammar at once: the default family, two
		// per-platform rows and a font blob.
		app.Build(func(tx *Tx) {
			tx.BrandTypeface("Georgia",
				PlatformFamily(PlatformLinux, "DejaVu Serif"),
				PlatformFamily(PlatformWindows, "Segoe UI"),
				FontBytes(typefaceFontBytes))
			mount(tx)
		})
	case "twice":
		app.Build(func(tx *Tx) {
			tx.BrandTypeface("Georgia")
			tx.BrandTypeface("Palatino")
			mount(tx)
		})
	case "after-mount":
		// A SECOND TRANSACTION, and it has to be one: the wall reads
		// mounted_windows, so the mount must have been APPLIED, which is
		// what the pump between these two Builds does. This is the shape
		// a real app gets wrong — branding from a handler, after the
		// first frame — rather than a mis-ordered build closure.
		app.Build(mount)
		rootprobe.Pump()
		app.Build(func(tx *Tx) { tx.BrandTypeface("Georgia") })
	case "empty-family":
		app.Build(func(tx *Tx) {
			tx.BrandTypeface("")
			mount(tx)
		})
	case "unknown-platform":
		// Go spells the closed vocabulary as int constants, so a caller
		// can hand it a number that is not in it; the root is what
		// refuses. The zero TypefaceOverride lands here too, which is why
		// this binding does not quietly drop one.
		app.Build(func(tx *Tx) {
			tx.BrandTypeface("Georgia", PlatformFamily(9, "Nonesuch"))
			mount(tx)
		})
	case "zero-override":
		app.Build(func(tx *Tx) {
			tx.BrandTypeface("Georgia", TypefaceOverride{})
			mount(tx)
		})
	case "platform-twice":
		app.Build(func(tx *Tx) {
			tx.BrandTypeface("Georgia",
				PlatformFamily(PlatformLinux, "DejaVu Serif"),
				PlatformFamily(PlatformLinux, "Liberation Serif"))
			mount(tx)
		})
	case "empty-row-family":
		app.Build(func(tx *Tx) {
			tx.BrandTypeface("Georgia", PlatformFamily(PlatformLinux, ""))
			mount(tx)
		})
	default:
		fmt.Fprintf(os.Stderr, "unknown KAYA_TYPEFACE_TRAP: %s\n", trap)
		os.Exit(2)
	}
	batch := rootprobe.PumpBatch()
	if trap == "full" {
		reportTypefaceApply(batch)
	}
	fmt.Printf("kaya typeface trap %s: THE ROOT ACCEPTED IT (%d command bytes)\n", trap, len(batch))
	os.Exit(0)
}

// reportTypefaceApply says what a BACKEND would receive, read out of the
// batch the root produced — and says it in measured terms only: every
// number below was read from these bytes, including the font's, which
// is fetched back out of the core's blob table rather than assumed to
// be the slice this process sent.
func reportTypefaceApply(batch []byte) {
	var (
		body    typefaceBody
		seen    int
		atIndex = -1
		mountAt = -1
	)
	for at, index := 0, 0; at < len(batch); index++ {
		size := int(binary.LittleEndian.Uint32(batch[at:]))
		kind := binary.LittleEndian.Uint16(batch[at+4:])
		switch kind {
		case applySetTypeface:
			body = decodeTypeface(batch[at : at+size])
			seen++
			atIndex = index
		case applyMount:
			if mountAt < 0 {
				mountAt = index
			}
		}
		at += size
	}
	if seen != 1 {
		fmt.Printf("kaya typeface applied: %d set_typeface records in the batch, wanted 1\n", seen)
		return
	}
	font := rootprobe.BlobData(uint64(body.font.i64))
	order := "after-mount"
	if mountAt < 0 {
		order = "no-mount"
	} else if atIndex < mountAt {
		order = "before-mount"
	}
	fmt.Printf("kaya typeface applied: family=%s rows=%s stamp=%d font=%d bytes sha=%x order=%s\n",
		body.family, body.rowString(), body.second, len(font), sha256.Sum256(font), order)
}

func runTypefaceTrap(t *testing.T, trap string) (string, error) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestTheRootIsTheTypefaceWall$")
	// cmd.Environ() rather than os.Environ(): tools/check-go-env.sh keeps
	// Go's own view of the environment out of this tree entirely (it is
	// empty forever in an Android c-shared guest), and this is the exec
	// package's own spelling of "what the child will inherit, plus this".
	cmd.Env = append(cmd.Environ(), "KAYA_TYPEFACE_TRAP="+trap)
	out, err := cmd.CombinedOutput()
	if ctx.Err() != nil {
		t.Fatalf("typeface trap %q never finished: the pump blocked, so the root applied nothing", trap)
	}
	return string(out), err
}

// THE WALLS ARE THE ROOT'S, AND THIS IS WHAT PROVES THE GO SURFACE
// REACHES THEM. Each case runs in a re-exec of this binary because a
// root refusal is an abort, not a Go panic: it crosses an extern "C"
// frame, so nothing in this process can recover it.
//
// The ALIVE cases carry as much weight as the dead ones — a binding
// whose BrandTypeface emitted nothing would sail through every dead case
// for the emptiest reason — and `full` carries more than either: it is
// the only place that reads the request as a LOWERING will get it.
func TestTheRootIsTheTypefaceWall(t *testing.T) {
	// LookupEnv is the binding's own reader (through C's getenv), which
	// is the only environment spelling this tree allows anywhere.
	if trap, set := LookupEnv("KAYA_TYPEFACE_TRAP"); set && trap != "" {
		typefaceTrap(trap)
		return
	}
	full := fmt.Sprintf(
		"kaya typeface applied: family=Georgia rows=[3=DejaVu Serif 4=Segoe UI] stamp=%d font=%d bytes sha=%x order=before-mount",
		hostPlatform, len(typefaceFontBytes), sha256.Sum256(typefaceFontBytes))
	if hostPlatform == 0 {
		t.Fatalf("no platform tag for GOOS=%s — this test only runs on the desktops the core stamps", runtime.GOOS)
	}
	for _, c := range []struct {
		trap    string
		refused bool
		want    string
	}{
		{"twice", true, "set_brand_typeface called twice"},
		{"after-mount", true, "set_brand_typeface after a mount"},
		{"empty-family", true, "set_brand_typeface has an empty family"},
		{"unknown-platform", true, "names platform 9, which is not in the vocabulary"},
		{"zero-override", true, "names platform 0, which is not in the vocabulary"},
		{"platform-twice", true, "names platform linux twice"},
		{"empty-row-family", true, "empty family for platform linux"},
		{"plain", false, "THE ROOT ACCEPTED IT"},
		{"full", false, full},
	} {
		t.Run(c.trap, func(t *testing.T) {
			out, err := runTypefaceTrap(t, c.trap)
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
