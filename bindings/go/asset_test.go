package kaya

// The asset surface's guards (docs/assets-plan.md, ratified
// 2026-08-18), pinned where a lane already walks: tools/check-abort.sh
// runs `go test dev.kaya/bindings/go` on every desktop lane, so these
// run with no GUI and no window.
//
// WHAT THIS FILE CAN ASK. The asset root these tests resolve is the
// repo's own (crates/kaya/src/assets.rs's compile-time default), so the
// vendored font is here and its byte count is a fact. What it cannot
// ask is whether a bundled or packaged root resolves — that is a
// question about a .app and an APK, and the lanes ask it.
//
// AND THE MISS SENTENCE IS NOT WRITTEN HERE, in either sense: this file
// neither spells it nor asserts a spelling of its own. It asserts that
// the panic carries the CORE's sentence byte for byte, which is the
// property the nine bindings share — one author for the diagnostic.

import (
	"bytes"
	"fmt"
	"io"
	"strings"
	"testing"
)

// The vendored font's byte count, the same fact crates/kaya/src/assets.rs
// pins on its own side. Asserted again here because a truncated read
// would otherwise reach a scene as a font the platform silently declines
// to register — the whole failure mode this surface exists inside.
const vendoredFontBytes = 111400

func openFont(t *testing.T) *Asset {
	t.Helper()
	var asset *Asset
	app := NewApp()
	app.Build(func(tx *Tx) {
		asset = tx.Asset("fonts/sora-wght.ttf")
	})
	if asset == nil {
		t.Fatal("tx.Asset answered nil without panicking — a miss must raise")
	}
	return asset
}

// THE THREE WAYS OF READING AGREE, and the count is the file's.
func TestAssetReadsTheFileTheBuildShipped(t *testing.T) {
	font := openFont(t)
	defer font.Close()

	if got := font.Len(); got != vendoredFontBytes {
		t.Errorf("Len is %d, want %d — a short read reaches a backend as a font that will not register", got, vendoredFontBytes)
	}
	if got := font.Name(); got != "fonts/sora-wght.ttf" {
		t.Errorf("Name is %q, want the name it was opened with", got)
	}
	raw := font.Bytes()
	if len(raw) != vendoredFontBytes {
		t.Fatalf("Bytes is %d long, want %d", len(raw), vendoredFontBytes)
	}
	read, err := io.ReadAll(font.Reader())
	if err != nil {
		t.Fatalf("an in-memory reader failed: %v", err)
	}
	if !bytes.Equal(read, raw) {
		t.Error("Reader is not the asset's bytes")
	}
	// The reader is a COPY, which is what makes it safe to hold past the
	// Close: a guest that keeps the reader keeps its own memory.
	if _, err := font.Reader().Seek(0, io.SeekStart); err != nil {
		t.Errorf("the reader does not seek: %v", err)
	}
}

// A MISS PANICS WITH THE CORE'S SENTENCE, byte for byte. The binding
// writes no prose of its own, so a Go guest and a Haskell guest are
// handed the same words and one scene can freeze them.
func TestAMissingAssetPanicsWithTheCoresSentence(t *testing.T) {
	want := assetMissSentence("fonts/nope.ttf")
	if want == "" {
		t.Fatal("the core says fonts/nope.ttf resolves — this test cannot ask its question")
	}
	// The census is the half a truncating reader would lose, so it is
	// asserted on the way in rather than assumed.
	if !strings.Contains(want, "fonts/sora-wght.ttf") {
		t.Errorf("the core's sentence carries no census of what IS there: %q", want)
	}

	defer func() {
		r := recover()
		if r == nil {
			t.Fatal("a missing asset returned instead of raising")
		}
		got := fmt.Sprint(r)
		if got != want {
			t.Errorf("panicked with\n%q\nwant the core's sentence verbatim\n%q", got, want)
		}
	}()
	app := NewApp()
	app.Build(func(tx *Tx) {
		tx.Asset("fonts/nope.ttf")
	})
}

// THE WALLS ARE THE CORE'S, reached through this surface: a name that
// climbs out of the root is refused before any filesystem is touched.
func TestAssetRefusesANameThatEscapesTheRoot(t *testing.T) {
	defer func() {
		r := recover()
		if r == nil {
			t.Fatal("a name with `..` in it resolved")
		}
		if got := fmt.Sprint(r); !strings.Contains(got, "climbs out of the asset root") {
			t.Errorf("panicked with %q, want the escape sentence", got)
		}
	}()
	app := NewApp()
	app.Build(func(tx *Tx) {
		tx.Asset("../../Cargo.toml")
	})
}

// CLOSING IS IDEMPOTENT and a closed asset says so rather than
// answering nil — an empty answer would be indistinguishable from an
// asset with no bytes, except that none can have any (the core refuses a
// zero-byte asset at the open).
func TestAClosedAssetRefusesToRead(t *testing.T) {
	font := openFont(t)
	font.Close()
	font.Close() // idempotent: the core's release is, so this is

	defer func() {
		r := recover()
		if r == nil {
			t.Fatal("a closed asset answered Bytes")
		}
		if got := fmt.Sprint(r); !strings.Contains(got, "closed asset") {
			t.Errorf("panicked with %q, want the closed-asset sentence", got)
		}
	}()
	font.Bytes()
}

// FontAsset REACHES THE WIRE AS THE BLOB FORM, and it is the same
// record FontBytes produces: mask bit 0 set, a live handle in the font
// slot. The route differs (the core's own bytes, no copy through Go),
// what a backend receives does not.
func TestFontAssetShipsTheBlobForm(t *testing.T) {
	font := openFont(t)
	defer font.Close()

	body := decodeTypeface(typefaceRecord(t, func(tx *Tx) {
		tx.BrandTypeface("Sora", FontAsset(font))
	}))
	if body.mask != 1 {
		t.Errorf("mask shipped as %d, want 1 — bit 0 is the whole of \"a font blob rides\"", body.mask)
	}
	if body.family != "Sora" {
		t.Errorf("family shipped as %q, want \"Sora\"", body.family)
	}
	if body.font.tag != ValueBlob || body.font.i64 == 0 {
		t.Errorf("font slot shipped as tag %d handle %d, want a live blob handle", body.font.tag, body.font.i64)
	}

	// TWO REDEMPTIONS ARE TWO REGISTRATIONS, which is the pending
	// table's existing lifetime and not a quirk: a handle is consumed by
	// one submit, so an asset used in two transactions must mint two.
	second := decodeTypeface(typefaceRecord(t, func(tx *Tx) {
		tx.BrandTypeface("Sora", FontAsset(font))
	}))
	if second.font.i64 == body.font.i64 {
		t.Errorf("both transactions carried blob handle %d — the second submit would drain a handle the first already consumed", body.font.i64)
	}
}

// AppIdentityAsset is the same declaration as AppIdentity by the asset
// route: bit 0 set, a live handle where the picture would be.
func TestAppIdentityAssetShipsTheBlobForm(t *testing.T) {
	mark := openMark(t)
	defer mark.Close()

	var found []byte
	app := NewApp()
	app.Build(func(tx *Tx) {
		tx.AppIdentityAsset("Aurora Notes", mark)
		for _, r := range tx.records {
			if recKind(r) == txSetAppIdentity {
				found = r
			}
		}
	})
	if found == nil {
		t.Fatal("AppIdentityAsset queued no record at all")
	}
	r := &reader{b: found, at: 8}
	mask := r.u32()
	r.u32() // reserved
	name := r.value()
	icon := r.value()
	if mask != 1 {
		t.Errorf("mask shipped as %d, want 1", mask)
	}
	if name.tag != ValueStr || name.str != "Aurora Notes" {
		t.Errorf("name shipped as tag %d %q", name.tag, name.str)
	}
	if icon.tag != ValueBlob || icon.i64 == 0 {
		t.Errorf("icon slot shipped as tag %d handle %d, want a live blob handle", icon.tag, icon.i64)
	}
}

func openMark(t *testing.T) *Asset {
	t.Helper()
	var asset *Asset
	app := NewApp()
	app.Build(func(tx *Tx) {
		asset = tx.Asset("icons/kaya-mark.png")
	})
	return asset
}

// THE NIL CASE IS CAUGHT AT THE CONSTRUCTOR, where the caller's mistake
// is, rather than as a nil dereference inside the redemption.
func TestFontAssetRefusesNothing(t *testing.T) {
	defer func() {
		r := recover()
		if r == nil {
			t.Fatal("FontAsset(nil) was accepted — the request would carry an empty blob")
		}
		if got := fmt.Sprint(r); !strings.Contains(got, "FontAsset got no asset") {
			t.Errorf("panicked with %q", got)
		}
	}()
	FontAsset(nil)
}
