package kaya

// The brand typeface's guards (docs/styling-plan.md Slice 2b).
//
// NOTHING HERE READS THE TYPEFACE BACK THROUGH THE API THAT WROTE IT:
// every platform's font API renders SOMETHING for a family it does not
// have, so an echo is the one answer always available and never
// meaningful. Two surfaces answer instead — the WIRE BYTES decoded out
// of the queued record, and THE APPLY STREAM out of the batch a real
// pump produced. Whether the platform actually swapped is
// expect_typeface's question on a real lane (tools/scenes/typeface.steps).

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
// The tx record and the apply record carry the SAME body, written by one
// function (crates/kaya/src/wire.rs's write_typeface). They differ in
// one word: the tx side's second u32 is reserved, the apply side's
// carries WHICH platform the core was compiled for.

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
	// The pairs are FLAT, tag then family, counted as VALUES — an odd
	// count is a mangled record, not a half-written row.
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

// A real font would prove less: the core never parses these bytes, so
// what this can prove is that the CHANNEL carries every one of them.
// Whether a real font registers is each backend's own probe.
var typefaceFontBytes = func() []byte {
	b := make([]byte, 1024)
	for i := range b {
		b[i] = byte(i * 7)
	}
	return b
}()

// One call is one record, whatever it is given: a record per override
// would die on the root's set-once wall, on a branded app's first frame.
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
		// Author order is wire order, and it is observable: a lowering
		// takes the FIRST row it matches.
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
			// The slot is ALWAYS written, so the field count never
			// varies: an absent font rides as an empty string and the
			// mask alone says which it is.
			if c.blob {
				if body.font.tag != ValueBlob || body.font.i64 == 0 {
					t.Errorf("font slot shipped as tag %d handle %d, want a live blob handle", body.font.tag, body.font.i64)
				}
			} else if body.font.tag != ValueStr || body.font.str != "" {
				t.Errorf("font slot shipped as tag %d %q, want an empty string", body.font.tag, body.font.str)
			}
		})
	}
	// The family rides where it says it does — checked apart from the
	// table, so a decoder reading the wrong field cannot agree by
	// reading nothing.
	if body := decodeTypeface(typefaceRecord(t, func(tx *Tx) {
		tx.BrandTypeface("Georgia", PlatformFamily(PlatformIos, "Palatino"))
	})); body.family != "Georgia" {
		t.Errorf("family shipped as %q, want \"Georgia\"", body.family)
	}
}

// Two fonts in one call is the one thing the wire cannot say: there is
// a single blob slot, so last-wins would drop one with no error.
func TestBrandTypefaceRefusesTwoFonts(t *testing.T) {
	defer func() {
		r := recover()
		if r == nil {
			t.Fatal("two font overrides in one call were accepted — one font vanished silently")
		}
		if !strings.Contains(fmt.Sprint(r), "two fonts (FontBytes/FontAsset)") {
			t.Fatalf("panicked with %v, want the duplicate-font sentence", r)
		}
	}()
	app := NewApp()
	app.Build(func(tx *Tx) {
		tx.BrandTypeface("Inter", FontBytes(typefaceFontBytes), FontBytes([]byte("other")))
	})
}

// ---- the real-root half ------------------------------------------

// The tag this host's core stamps into the apply record, derived from
// Go's own idea of the platform rather than from the record being
// checked. Zero means "not a platform this test runs on".
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
		app.Build(func(tx *Tx) {
			tx.BrandTypeface("Georgia")
			mount(tx)
		})
	case "full":
		// Every part of the grammar at once.
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
		// Must be a SECOND transaction: the wall reads mounted_windows,
		// so the mount has to have been APPLIED, which is what the pump
		// between these two Builds does.
		app.Build(mount)
		rootprobe.Pump()
		app.Build(func(tx *Tx) { tx.BrandTypeface("Georgia") })
	case "empty-family":
		app.Build(func(tx *Tx) {
			tx.BrandTypeface("")
			mount(tx)
		})
	case "unknown-platform":
		// Go spells the vocabulary as int constants, so a caller can hand
		// it a number that is not in it; the root refuses. The zero
		// TypefaceOverride lands here too, so Go must not drop one.
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

// reportTypefaceApply says what a BACKEND would receive, in measured
// terms only: the font's bytes are fetched back out of the core's blob
// table rather than assumed to be the slice this process sent.
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
	// cmd.Environ() rather than os.Environ(): tools/check-go-env.py.
	cmd.Env = append(cmd.Environ(), "KAYA_TYPEFACE_TRAP="+trap)
	out, err := cmd.CombinedOutput()
	if ctx.Err() != nil {
		t.Fatalf("typeface trap %q never finished: the pump blocked, so the root applied nothing", trap)
	}
	return string(out), err
}

// Each case runs in a re-exec because a root refusal ends the process, not a
// Go panic. The ALIVE cases carry as much weight as the dead ones, and
// `full` more than either: it is the only place that reads the request
// as a LOWERING will get it.
func TestTheRootIsTheTypefaceWall(t *testing.T) {
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
