package kaya

// docs/app-identity-plan.md. Nothing here reads the identity back through the
// API that wrote it — every platform draws SOMETHING where a mark goes; that
// it was DRAWN is expect_app_icon's question (tools/scenes/identity.steps).

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
// The tx and apply records carry the SAME body (crates/kaya/src/wire.rs's
// write_app_identity). Unlike the typeface's, the second word is reserved on
// BOTH.

type identityBody struct {
	mask     uint32
	reserved uint32
	name     string
	icon     wireValue
}

// Over typeface_test.go's wire walker.
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

// identityRecord submits nothing: it reads the record the binding QUEUED,
// which is what would leave this process.
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

// THE DECLARATION CARRIES NOTHING (docs/tasks-s3-plan.md N4): the name, the
// mark and the id are the manifest's, so the tx record's slots ride EMPTY and
// the root fills them. A binding that went on sending values would have them
// silently replaced, which is what the root refuses by name.
func TestAppIdentityShipsAnEmptyDeclaration(t *testing.T) {
	body := decodeIdentity(identityRecord(t, func(tx *Tx) { tx.AppIdentity() }))
	if body.mask != 0 {
		t.Errorf("mask shipped as %d, want 0 — no blob rides a declaration that carries no picture", body.mask)
	}
	if body.reserved != 0 {
		t.Errorf("the reserved word is %d, want 0", body.reserved)
	}
	if body.name != "" {
		t.Errorf("the name shipped as %q, want the empty string — the manifest's name is the root's to fill", body.name)
	}
	// The slot is ALWAYS written, so the field count never varies with the
	// payload: an absent icon rides as an empty string.
	if body.icon.tag != ValueStr || body.icon.str != "" {
		t.Errorf("icon slot shipped as tag %d %q, want an empty string", body.icon.tag, body.icon.str)
	}
}

// ---- the real-root half ------------------------------------------

// identityTrap returns only when the root ALLOWED the scene.
func identityTrap(trap string) {
	app := NewApp()
	mount := func(tx *Tx) { tx.Mount(tx.Column(func() { tx.LabelText("identity") })) }
	switch trap {
	case "full":
		app.Build(func(tx *Tx) {
			tx.AppIdentity()
			mount(tx)
		})
	case "twice":
		app.Build(func(tx *Tx) {
			tx.AppIdentity()
			tx.AppIdentity()
			mount(tx)
		})
	case "after-mount":
		// Must be a SECOND transaction: the wall reads mounted_windows,
		// so the mount has to have been APPLIED, which is what the pump
		// between these two Builds does.
		app.Build(mount)
		rootprobe.Pump()
		app.Build(func(tx *Tx) { tx.AppIdentity() })
	case "half-manifest":
		// THE MANIFEST IS THE DECLARATION NOW, so a manifest missing one
		// of its three keys is the refusal an empty name used to be — and
		// the sentence has to send the reader to the FILE, since the call
		// carries nothing to blame. The root that runs this was pointed at
		// a doctored asset root by runIdentityTrap's own environment.
		app.Build(func(tx *Tx) {
			tx.AppIdentity()
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

// The icon's bytes are fetched back out of the core's blob table rather than
// assumed to be the slice this process sent.
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
	// cmd.Environ() rather than os.Environ(): tools/check-go-env.py.
	cmd.Env = append(cmd.Environ(), "KAYA_IDENTITY_TRAP="+trap)
	if trap == "half-manifest" {
		// A DOCTORED ASSET ROOT, handed to the child through the
		// environment rather than set in-process: the core resolves the
		// root once, and an in-process write races its own read.
		dir := t.TempDir()
		// A STAND-IN PATH: this manifest is doctored to be missing its `id`,
		// and the reader refuses before it opens any picture, so naming the
		// real mark here would be a second copy of the declared path for
		// nothing (tools/check-assets.py, tools/check-app-identity.py C3).
		manifest := "name = \"Aurora Notes\"\nicon = \"bundle/assets/icons/a-mark.png\"\n"
		if err := os.WriteFile(dir+"/identity.toml", []byte(manifest), 0o644); err != nil {
			t.Fatalf("the doctored manifest could not be written: %v", err)
		}
		cmd.Env = append(cmd.Env, "KAYA_ASSET_DIR="+dir)
	}
	out, err := cmd.CombinedOutput()
	if ctx.Err() != nil {
		t.Fatalf("identity trap %q never finished: the pump blocked, so the root applied nothing", trap)
	}
	return string(out), err
}

// Each case runs in a re-exec because a root refusal ends the process, not a
// Go panic. `full` is the only case that reads the declaration as a LOWERING
// will get it.
func TestTheRootIsTheIdentityWall(t *testing.T) {
	if trap, set := LookupEnv("KAYA_IDENTITY_TRAP"); set && trap != "" {
		identityTrap(trap)
		return
	}
	// THE EXPECTED BYTES ARE THE MANIFEST'S MARK, opened through the
	// binding's OWN asset call rather than by path: the resolution rule
	// lives once, in crates/kaya/src/assets.rs (tools/check-assets.py).
	// The declaration carries no picture, so what comes back out of the
	// blob table is whatever identity.toml named.
	markAsset := openMark(t)
	defer markAsset.Close()
	mark := markAsset.Bytes()
	full := fmt.Sprintf(
		"kaya identity applied: name=Aurora Notes mask=1 stamp=0 icon=%d bytes sha=%x order=before-mount",
		len(mark), sha256.Sum256(mark))
	for _, c := range []struct {
		trap    string
		refused bool
		want    string
	}{
		{"twice", true, "set_app_identity called twice"},
		{"after-mount", true, "set_app_identity after a mount"},
		{"half-manifest", true, "declares no `id`"},
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
