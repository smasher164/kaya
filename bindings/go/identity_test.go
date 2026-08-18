package kaya

// The app identity's guards (docs/app-identity-plan.md), pinned where a
// lane already walks: tools/check-abort.sh runs
// `go test dev.kaya/bindings/go` on every desktop lane, so these run with
// no GUI, no window and no icon anywhere on the machine.
//
// AND NOTHING HERE READS THE IDENTITY BACK THROUGH THE API THAT WROTE
// IT — typeface_test.go's doctrine, and the identity is one tier worse:
// every platform draws SOMETHING where an app's mark goes (a generic
// executable, the host process's icon, a monochrome placeholder), so a
// declaration echoed back is the one answer that is always available and
// never means anything. Two surfaces answer instead:
//
//   - the WIRE BYTES the core will consume, decoded out of the queued
//     record;
//   - THE APPLY STREAM on the far side of the root, decoded out of the
//     batch a real pump produced — the declaration as a BACKEND receives
//     it, icon bytes fetched back through the blob table.
//
// Whether the platform DREW it is not a question this file can ask: it
// lives in the window manager, and expect_app_icon on a real lane is
// what asks it (tools/scenes/identity.steps).

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"dev.kaya/bindings/go/internal/rootprobe"
)

// ---- one decoder, both channels ----------------------------------
//
// The tx record and the apply record carry the SAME body — the core
// writes both through one function (crates/kaya/src/wire.rs's
// write_app_identity) precisely so neither side can drift — and unlike
// the typeface's, the second word is reserved on BOTH: a family name has
// to be resolved per platform, a picture does not.

type identityBody struct {
	mask     uint32
	reserved uint32
	name     string
	icon     wireValue
}

// decodeIdentity reads one whole record — header included — as an
// identity body. `reader` and `wireValue` are typeface_test.go's, which
// is the point: one wire walker, so a record shape this file got wrong
// would be wrong there too.
func decodeIdentity(rec []byte) identityBody {
	r := &reader{b: rec, at: 8} // past {u32 size, u16 kind, u16 pad}
	body := identityBody{mask: r.u32(), reserved: r.u32()}
	name := r.value()
	if name.tag != ValueStr {
		panic(fmt.Sprintf("kaya test: the name rode as tag %d, not a string", name.tag))
	}
	body.name = name.str
	body.icon = r.value()
	return body
}

// ---- the wire-byte half ------------------------------------------

// identityRecord submits nothing: it reads the record the binding
// QUEUED, which is what would leave this process.
func identityRecord(t *testing.T, build func(tx *Tx)) []byte {
	t.Helper()
	app := NewApp()
	var found []byte
	app.Build(func(tx *Tx) {
		build(tx)
		for _, r := range tx.records {
			if recKind(r) == txSetAppIdentity {
				if found != nil {
					t.Fatalf("the identity queued more than one record — the root's set-once wall would refuse the second")
				}
				found = r
			}
		}
	})
	if found == nil {
		t.Fatal("AppIdentity queued no record at all — the app would ship nameless and unmarked with no error anywhere")
	}
	return found
}

// A REAL PNG IS NOT NEEDED AND WOULD PROVE LESS. The core never inspects
// these bytes (crates/kaya/src/scene.rs says so, with its reason:
// whether a blob is an image is a question only a platform's decoder can
// answer), so what this file can prove about the blob is that the
// CHANNEL carries it — every byte, from a Go slice to the apply record a
// backend reads. Whether a real picture decodes is each backend's probe,
// on its own platform, against its own image decoder.
var identityIconBytes = func() []byte {
	b := make([]byte, 512)
	for i := range b {
		b[i] = byte(i * 11)
	}
	return b
}()

// ONE CALL IS ONE RECORD, and the mask and the slot are the pair that
// goes silently wrong: the core refuses BOTH directions of a
// disagreement (crates/kaya/src/wire.rs), so a binding that set the bit
// over an empty Str — or wrote a blob under a clear bit — would abort
// the app rather than drop the mark quietly. This reads what the binding
// actually wrote.
func TestAppIdentityPacksOneRecord(t *testing.T) {
	for _, c := range []struct {
		name  string
		build func(tx *Tx)
		mask  uint32
		blob  bool
	}{
		{"name and icon", func(tx *Tx) {
			tx.AppIdentity("Aurora Notes", identityIconBytes)
		}, 1, true},
		{"name only", func(tx *Tx) {
			tx.AppIdentityNamed("Aurora Notes")
		}, 0, false},
	} {
		t.Run(c.name, func(t *testing.T) {
			body := decodeIdentity(identityRecord(t, c.build))
			if body.mask != c.mask {
				t.Errorf("mask shipped as %d, want %d — bit 0 is the whole of \"an icon blob rides\"", body.mask, c.mask)
			}
			if body.reserved != 0 {
				t.Errorf("the reserved word is %d, want 0 — a guest names no platform here, and unlike the typeface the core stamps none on the way out either", body.reserved)
			}
			if body.name != "Aurora Notes" {
				t.Errorf("the name shipped as %q, want \"Aurora Notes\"", body.name)
			}
			// THE SLOT IS ALWAYS WRITTEN, so the record's field count
			// never varies with the payload: an absent icon rides as an
			// empty string, and the mask alone says which it is.
			if c.blob {
				if body.icon.tag != ValueBlob || body.icon.i64 == 0 {
					t.Errorf("icon slot shipped as tag %d handle %d, want a live blob handle", body.icon.tag, body.icon.i64)
				}
			} else if body.icon.tag != ValueStr || body.icon.str != "" {
				t.Errorf("icon slot shipped as tag %d %q, want an empty string", body.icon.tag, body.icon.str)
			}
		})
	}
}

// AN EMPTY SLICE IS NOT THE NAME-ONLY FORM, and this is the clause that
// keeps it from becoming one. `AppIdentity(name, nil)` sets the mask and
// ships zero bytes, so the ROOT refuses it in the sentence every language
// reads; a binding that quietly demoted it to AppIdentityNamed would make
// that wall unreachable from Go alone — invariant-1 divergence hidden
// inside a convenience.
func TestAppIdentityDoesNotDemoteEmptyBytes(t *testing.T) {
	body := decodeIdentity(identityRecord(t, func(tx *Tx) {
		tx.AppIdentity("Aurora Notes", nil)
	}))
	if body.mask != 1 || body.icon.tag != ValueBlob {
		t.Fatalf("nil bytes shipped as mask %d tag %d — Go turned an author error into the name-only form, and the root's empty-blob wall became unreachable here",
			body.mask, body.icon.tag)
	}
}

// ---- the real-root half ------------------------------------------

// identityTrap builds one scene through the ordinary Go sugar and pumps
// it through the root. It returns only when the root ALLOWED the scene.
func identityTrap(trap string) {
	app := NewApp()
	mount := func(tx *Tx) { tx.Mount(tx.Column(func() { tx.LabelText("identity") })) }
	switch trap {
	case "plain":
		// The name-only declaration, which must survive.
		app.Build(func(tx *Tx) {
			tx.AppIdentityNamed("Aurora Notes")
			mount(tx)
		})
	case "full":
		// The identity scene's own opening: a name and a mark.
		app.Build(func(tx *Tx) {
			tx.AppIdentity("Aurora Notes", identityIconBytes)
			mount(tx)
		})
	case "twice":
		app.Build(func(tx *Tx) {
			tx.AppIdentity("Aurora Notes", identityIconBytes)
			tx.AppIdentityNamed("Something Else")
			mount(tx)
		})
	case "after-mount":
		// A SECOND TRANSACTION, and it has to be one: the wall reads
		// mounted_windows, so the mount must have been APPLIED, which is
		// what the pump between these two Builds does. This is the shape
		// a real app gets wrong — declaring from a handler, after the
		// first frame — rather than a mis-ordered build closure.
		app.Build(mount)
		rootprobe.Pump()
		app.Build(func(tx *Tx) { tx.AppIdentityNamed("Aurora Notes") })
	case "empty-name":
		app.Build(func(tx *Tx) {
			tx.AppIdentityNamed("")
			mount(tx)
		})
	case "empty-icon":
		// The mask says a picture rides and no bytes do. Every
		// platform's decoder answers nothing for zero bytes, so this
		// would read exactly like an icon that applied.
		app.Build(func(tx *Tx) {
			tx.AppIdentity("Aurora Notes", nil)
			mount(tx)
		})
	default:
		fmt.Fprintf(os.Stderr, "unknown KAYA_IDENTITY_TRAP: %s\n", trap)
		os.Exit(2)
	}
	batch := rootprobe.PumpBatch()
	if trap == "full" {
		reportIdentityApply(batch)
	}
	fmt.Printf("kaya identity trap %s: THE ROOT ACCEPTED IT (%d command bytes)\n", trap, len(batch))
	os.Exit(0)
}

// reportIdentityApply says what a BACKEND would receive, read out of the
// batch the root produced — in measured terms only: the icon's bytes are
// fetched back out of the core's blob table rather than assumed to be the
// slice this process sent.
func reportIdentityApply(batch []byte) {
	var (
		body    identityBody
		seen    int
		atIndex = -1
		mountAt = -1
	)
	for at, index := 0, 0; at < len(batch); index++ {
		size := int(binary.LittleEndian.Uint32(batch[at:]))
		kind := binary.LittleEndian.Uint16(batch[at+4:])
		switch kind {
		case applySetAppIdentity:
			body = decodeIdentity(batch[at : at+size])
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
		fmt.Printf("kaya identity applied: %d set_app_identity records in the batch, wanted 1\n", seen)
		return
	}
	icon := rootprobe.BlobData(uint64(body.icon.i64))
	order := "after-mount"
	if mountAt < 0 {
		order = "no-mount"
	} else if atIndex < mountAt {
		order = "before-mount"
	}
	fmt.Printf("kaya identity applied: name=%s mask=%d stamp=%d icon=%d bytes sha=%x order=%s\n",
		body.name, body.mask, body.reserved, len(icon), sha256.Sum256(icon), order)
}

func runIdentityTrap(t *testing.T, trap string) (string, error) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestTheRootIsTheIdentityWall$")
	// cmd.Environ() rather than os.Environ(): tools/check-go-env.sh keeps
	// Go's own view of the environment out of this tree entirely (it is
	// empty forever in an Android c-shared guest), and this is the exec
	// package's own spelling of "what the child will inherit, plus this".
	cmd.Env = append(cmd.Environ(), "KAYA_IDENTITY_TRAP="+trap)
	out, err := cmd.CombinedOutput()
	if ctx.Err() != nil {
		t.Fatalf("identity trap %q never finished: the pump blocked, so the root applied nothing", trap)
	}
	return string(out), err
}

// THE WALLS ARE THE ROOT'S, AND THIS IS WHAT PROVES THE GO SURFACE
// REACHES THEM. Each case runs in a re-exec of this binary because a root
// refusal is an abort, not a Go panic: it crosses an extern "C" frame, so
// nothing in this process can recover it.
//
// The ALIVE cases carry as much weight as the dead ones — a binding whose
// AppIdentity emitted nothing would sail through every dead case for the
// emptiest reason — and `full` carries more than either: it is the only
// place that reads the declaration as a LOWERING will get it.
func TestTheRootIsTheIdentityWall(t *testing.T) {
	// LookupEnv is the binding's own reader (through C's getenv), which
	// is the only environment spelling this tree allows anywhere.
	if trap, set := LookupEnv("KAYA_IDENTITY_TRAP"); set && trap != "" {
		identityTrap(trap)
		return
	}
	full := fmt.Sprintf(
		"kaya identity applied: name=Aurora Notes mask=1 stamp=0 icon=%d bytes sha=%x order=before-mount",
		len(identityIconBytes), sha256.Sum256(identityIconBytes))
	for _, c := range []struct {
		trap    string
		refused bool
		want    string
	}{
		{"twice", true, "set_app_identity called twice"},
		{"after-mount", true, "set_app_identity after a mount"},
		{"empty-name", true, "set_app_identity has an empty name"},
		{"empty-icon", true, "set_app_identity carries an EMPTY icon blob"},
		{"plain", false, "THE ROOT ACCEPTED IT"},
		{"full", false, full},
	} {
		t.Run(c.trap, func(t *testing.T) {
			out, err := runIdentityTrap(t, c.trap)
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
