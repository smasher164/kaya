package kaya

// The rich mirror's fold, headless: the binding's Document must answer
// exactly what the core's own does (docs/rich-text-plan.md R1,
// crates/kaya/src/app.rs AppCtx::absorb_edit / absorb_format /
// normalize_runs). No core, no library — a bare App is the mirror.

import (
	"bytes"
	"fmt"
	"strings"
	"testing"
)

func spellRuns(runs []TextRun) string {
	parts := make([]string, 0, len(runs))
	for _, run := range runs {
		if run.IsFlag() {
			parts = append(parts, fmt.Sprintf("%d:%d %s", run.Range.Start, run.Range.End, run.Name))
			continue
		}
		parts = append(parts, fmt.Sprintf("%d:%d %s=%s", run.Range.Start, run.Range.End, run.Name, run.Value))
	}
	return strings.Join(parts, "|")
}

func mirror() *App { return &App{documents: make(map[uint64]Document)} }

// The mirror is keyed by widget id, so the test names one directly.
var one = Widget{id: 1}

func TestNormalizeRunsIsTheCoresNormalForm(t *testing.T) {
	for _, c := range []struct {
		name string
		in   []TextRun
		want string
	}{
		{"a same-valued overlap comes back as ONE run: cut, then merged",
			[]TextRun{{TextRange{0, 10}, "bold", "true"}, {TextRange{4, 6}, "bold", "true"}},
			"0:10 bold"},
		{"adjacent and equal merge",
			[]TextRun{{TextRange{0, 4}, "bold", "true"}, {TextRange{4, 8}, "bold", "true"}},
			"0:8 bold"},
		{"adjacent and DIFFERENT do not merge",
			[]TextRun{{TextRange{0, 4}, "block", "heading1"}, {TextRange{4, 8}, "block", "heading2"}},
			"0:4 block=heading1|4:8 block=heading2"},
		{"a later value wins over the range it covers",
			[]TextRun{{TextRange{0, 8}, "block", "heading1"}, {TextRange{2, 4}, "block", "quote"}},
			"0:2 block=heading1|2:4 block=quote|4:8 block=heading1"},
		{"two attributes over one range are two runs, ordered by name",
			[]TextRun{{TextRange{0, 4}, "link", "u"}, {TextRange{0, 4}, "bold", "true"}},
			"0:4 bold|0:4 link=u"},
		{"an empty run is dropped",
			[]TextRun{{TextRange{3, 3}, "bold", "true"}, {TextRange{0, 2}, "bold", "true"}},
			"0:2 bold"},
		{"ordered by start, then by name",
			[]TextRun{{TextRange{6, 8}, "italic", "true"}, {TextRange{0, 2}, "bold", "true"}, {TextRange{0, 2}, "italic", "true"}},
			"0:2 bold|0:2 italic|6:8 italic"},
	} {
		if got := spellRuns(normalizeRuns(c.in)); got != c.want {
			t.Errorf("%s: normalizeRuns gave %q, want %q", c.name, got, c.want)
		}
	}
}

func TestAbsorbEditSplicesRunsTheCoresWay(t *testing.T) {
	a := mirror()
	a.seedDocument(one.id, NewDocument("abcdef").Bold(0, 2).Italic(4, 6))
	// A run the edit falls INSIDE is cut; one before it keeps; one after
	// it shifts; the inserted runs land relative to the edit.
	a.absorbEdit(one.id, 2, 3, "XYZ", []TextRun{{TextRange{1, 2}, "code", "true"}})
	if got, want := a.Document(one).Text, "abXYZdef"; got != want {
		t.Errorf("text %q, want %q", got, want)
	}
	if got, want := spellRuns(a.Document(one).Runs),
		"0:2 bold|3:4 code|6:8 italic"; got != want {
		t.Errorf("runs %q, want %q", got, want)
	}

	// A delete that swallows a run drops it.
	b := mirror()
	b.seedDocument(one.id, NewDocument("abcdef").Bold(2, 4))
	b.absorbEdit(one.id, 1, 5, "", nil)
	if got, want := spellRuns(b.Document(one).Runs), ""; got != want {
		t.Errorf("a swallowed run survived as %q", got)
	}

	// A mirror the edit cannot address is REPLACED, never spliced out of
	// range.
	c := mirror()
	c.seedDocument(one.id, NewDocument("ab").Bold(0, 2))
	c.absorbEdit(one.id, 40, 60, "fresh", []TextRun{{TextRange{0, 5}, "bold", "true"}})
	if got, want := c.Document(one).Text, "fresh"; got != want {
		t.Errorf("out-of-step mirror kept %q, want %q", got, want)
	}
}

func TestAbsorbFormatPutsAndTakesOneAttribute(t *testing.T) {
	a := mirror()
	a.seedDocument(one.id, NewDocument("abcdefgh").Bold(0, 8).Italic(0, 8))
	// Only THIS attribute's runs are clipped.
	a.absorbFormat(one.id, 2, 4, "bold", "", true)
	if got, want := spellRuns(a.Document(one).Runs),
		"0:2 bold|0:8 italic|4:8 bold"; got != want {
		t.Errorf("after unbold: %q, want %q", got, want)
	}
	a.absorbFormat(one.id, 0, 8, "bold", "true", false)
	if got, want := spellRuns(a.Document(one).Runs), "0:8 bold|0:8 italic"; got != want {
		t.Errorf("after re-bold: %q, want %q", got, want)
	}
	// A COLLAPSED range is pending state at the widget and moves nothing
	// here (docs/rich-text-plan.md R4).
	a.absorbFormat(one.id, 3, 3, "strike", "true", false)
	if got, want := spellRuns(a.Document(one).Runs), "0:8 bold|0:8 italic"; got != want {
		t.Errorf("a collapsed format moved the mirror: %q, want %q", got, want)
	}
}

// THE SCENE, REPLAYED: every string tools/scenes/richtext.steps freezes
// for label#1, folded by this binding alone. A device proves the widget
// agrees; this proves the binding does.
func TestMirrorAnswersTheScenesFrozenRuns(t *testing.T) {
	const link = "https://kaya.dev"
	a := mirror()
	seed := NewDocument("Héllo world\nSecond line").
		Bold(0, 6).Link(7, 12, link).Block(13, 24, Heading2)
	a.seedDocument(one.id, seed)
	step := func(want string) {
		t.Helper()
		if got := spellRuns(a.Document(one).Runs); got != want {
			t.Errorf("runs %q, want %q", got, want)
		}
	}
	step("0:6 bold|7:12 link=" + link + "|13:24 block=heading2")

	// click button#1: the app's edit, folded as it is SENT.
	e := Insert(6, ", big").Mark(2, 5, "italic", "true")
	a.absorbEdit(one.id, e.Range.Start, e.Range.End, e.Inserted, e.Runs)
	step("0:6 bold|8:11 italic|12:17 link=" + link + "|18:29 block=heading2")

	// format 12:17 underline, then off.
	a.absorbFormat(one.id, 12, 17, "underline", "true", false)
	step("0:6 bold|8:11 italic|12:17 link=" + link +
		"|12:17 underline|18:29 block=heading2")
	a.absorbFormat(one.id, 12, 17, "underline", "", true)
	step("0:6 bold|8:11 italic|12:17 link=" + link + "|18:29 block=heading2")

	// button#3 unbold over the selected first word, then button#4's block.
	a.absorbFormat(one.id, 0, 6, "bold", "", true)
	step("8:11 italic|12:17 link=" + link + "|18:29 block=heading2")
	a.absorbFormat(one.id, 0, 17, "block", "heading1", false)
	step("0:17 block=heading1|8:11 italic|12:17 link=" + link +
		"|18:29 block=heading2")

	// Typing INHERITS the block, and the merge with the paragraph's own
	// run is what keeps it ONE run.
	a.absorbEdit(one.id, 29, 29, "x", []TextRun{{TextRange{0, 1}, "block", "heading2"}})
	step("0:17 block=heading1|8:11 italic|12:17 link=" + link +
		"|18:30 block=heading2")
	a.absorbEdit(one.id, 30, 30, "y",
		[]TextRun{{TextRange{0, 1}, "block", "heading2"}, {TextRange{0, 1}, "bold", "true"}})
	step("0:17 block=heading1|8:11 italic|12:17 link=" + link +
		"|18:31 block=heading2|30:31 bold")

	// button#6's prefix: the app's document takes it at once.
	p := Insert(0, "> ")
	a.absorbEdit(one.id, p.Range.Start, p.Range.End, p.Inserted, p.Runs)
	step("2:19 block=heading1|10:13 italic|14:19 link=" + link +
		"|20:33 block=heading2|32:33 bold")

	// THE SPLICE IS IN BYTES: the é puts byte 6 after the first word and
	// UTF-16 index 6 inside the second.
	if got, want := a.Document(one).Text,
		"> Héllo, big world\nSecond linexy"; got != want {
		t.Errorf("text %q, want %q", got, want)
	}
}

// AN EDIT CARRIES ITS SOURCE (the review page's ruling 3, 2026-09-14):
// the occurrence's reserved word, mapped through the generated constants
// to this binding's vocabulary, absent on an edit the app builds.
func TestEditSourceNamesMatchTheConstants(t *testing.T) {
	for number, want := range map[uint32]EditSource{
		EditSourceUser:       SourceUser,
		EditSourceImeCommit:  SourceImeCommit,
		EditSourcePaste:      SourcePaste,
		EditSourceNativeUndo: SourceNativeUndo,
		EditSourceDrop:       SourceDrop,
	} {
		if got := editSourceOf(number); got != want {
			t.Errorf("edit source %d is %q, want %q", number, got, want)
		}
	}
	if len(editSources) != 5 {
		t.Errorf("the vocabulary holds %d names, want the wire's 5", len(editSources))
	}
}

func TestEditOfCarriesTheSourceAndAnAppBuiltEditCarriesNone(t *testing.T) {
	tail := []any{uint32(EditSourcePaste), uint64(29), uint64(29), "x",
		int64(0), int64(1), "block", "heading2"}
	e := editOf(tail)
	if e.Source != SourcePaste {
		t.Errorf("a delivered edit's source is %q, want %q", e.Source, SourcePaste)
	}
	if got := fmt.Sprintf("edit %d:%d <%s> %s [%s]", e.Range.Start, e.Range.End, e.Inserted,
		e.Source, spellRuns(e.Runs)); got != "edit 29:29 <x> paste [0:1 block=heading2]" {
		t.Errorf("the guest's line reads %q", got)
	}
	// The zero value, on every edit the app builds.
	for _, built := range []Edit{Insert(6, ", big"), Delete(0, 2), Replace(0, 2, "z"),
		Insert(0, "> ").Mark(0, 1, "bold", "true")} {
		if built.Source != SourceNone {
			t.Errorf("an app-built edit carries source %q, want none", built.Source)
		}
	}
}

// An edit source this build does not know is refused NAMING the number,
// the way every other unknown wire value is.
func TestEditOfRefusesAnUnknownSourceByName(t *testing.T) {
	defer func() {
		said, ok := recover().(string)
		if !ok || !strings.Contains(said, "9") || !strings.Contains(said, "edit source") {
			t.Errorf("an unknown edit source said %v, want the number named", said)
		}
	}()
	editOf([]any{uint32(9), uint64(0), uint64(0), ""})
	t.Error("an unknown edit source was accepted")
}

// A splice that would cut a character in half is the mirror out of step
// with the core, and is answered by taking the core's word for the text.
func TestAbsorbEditRefusesToCutACharacter(t *testing.T) {
	a := mirror()
	a.seedDocument(one.id, NewDocument("Héllo"))
	a.absorbEdit(one.id, 2, 2, "!", nil)
	if got, want := a.Document(one).Text, "!"; got != want {
		t.Errorf("a mid-character splice gave %q, want the replacement %q", got, want)
	}
}

func TestDocumentChainAndAttrAt(t *testing.T) {
	doc := NewDocument("hello").Bold(0, 2).Italic(0, 2).Underline(0, 2).
		Strike(0, 2).Code(0, 2).Link(2, 4, "u").Block(0, 5, Quote)
	if got, want := spellRuns(doc.Runs),
		"0:2 bold|0:2 italic|0:2 underline|0:2 strike|0:2 code|"+
			"2:4 link=u|0:5 block=quote"; got != want {
		t.Errorf("the chain built %q, want %q", got, want)
	}
	if v, ok := doc.AttrAt(1, "bold"); !ok || v != "true" {
		t.Errorf("AttrAt(1, bold) gave %q %v", v, ok)
	}
	if v, ok := doc.AttrAt(4, "link"); ok {
		t.Errorf("AttrAt(4, link) gave %q, want no run (the range is half-open)", v)
	}
	// A chain step never rewrites the document it was called on.
	base := NewDocument("hello").Bold(0, 2)
	_ = base.Italic(2, 4)
	if got := spellRuns(base.Runs); got != "0:2 bold" {
		t.Errorf("a chain step mutated its receiver: %q", got)
	}
}

// The mirror read is a SNAPSHOT, as Rust's ctx.document is a clone: a
// document handed out cannot be written through, and a later fold cannot
// change one already handed out.
func TestDocumentReadIsASnapshot(t *testing.T) {
	a := mirror()
	a.seedDocument(one.id, NewDocument("abcdef").Bold(0, 2))
	held := a.Document(one)
	held.Runs[0].Name = "italic"
	if got := spellRuns(a.Document(one).Runs); got != "0:2 bold" {
		t.Errorf("a write through a handed-out document reached the mirror: %q", got)
	}
	a.absorbFormat(one.id, 2, 4, "code", "true", false)
	if got := spellRuns(held.Runs); got != "0:2 italic" {
		t.Errorf("a later fold changed a document already handed out: %q", got)
	}
}

// THE APP-OWNED UNDO (docs/rich-text-plan.md R6, §14): the declaration is
// the prop, and the two live answers Edit>Undo's enablement reads are the
// other two — nothing else in this binding says so.
func TestOwnUndoAndItsTwoLiveAnswersRideTheProps(t *testing.T) {
	app := NewApp()
	app.Build(func(tx *Tx) {
		owned := tx.Textarea(nil).Rich().OwnUndo()
		plain := tx.Textarea(nil).Rich()
		tx.CanUndo(owned, true)
		tx.CanRedo(owned, false)

		has := func(want []byte) bool {
			for _, rec := range tx.records {
				if bytes.Equal(rec, want) {
					return true
				}
			}
			return false
		}
		if !has(TxSetOwnUndo(owned.id, true)) {
			t.Error("OwnUndo() put no own_undo prop on the wire")
		}
		if has(TxSetOwnUndo(plain.id, true)) {
			t.Error("a plain rich textarea declared own_undo")
		}
		if !has(TxSetCanUndo(owned.id, true)) {
			t.Error("CanUndo(w, true) put no can_undo prop on the wire")
		}
		if !has(TxSetCanRedo(owned.id, false)) {
			t.Error("CanRedo(w, false) put no can_redo prop on the wire")
		}
	})
}

// THE RANGED ACT (docs/rich-text-plan.md §17): a document write, so the
// BYTES say ranged 1 and carry the range, and the app's own fold takes it
// HERE — nothing is echoed back to move it. No scene drives FormatRange,
// so nothing else in this binding reads either half.
func TestRangedActRidesTheBytesAndMovesTheFold(t *testing.T) {
	const para = "Héllo world\nSecond line"
	if len(para) != 24 {
		t.Fatalf("the fixture is %d bytes, so its paragraph offsets mean nothing", len(para))
	}
	app := NewApp()
	app.Build(func(tx *Tx) {
		w := tx.Textarea(nil).Rich()
		has := func(want []byte) bool {
			for _, rec := range tx.records {
				if bytes.Equal(rec, want) {
					return true
				}
			}
			return false
		}

		tx.SetDocument(w, NewDocument(para))
		tx.FormatRange(w, TextRange{Start: 2, End: 5}, "italic", "true")
		tx.UnformatRange(w, TextRange{Start: 0, End: 2}, "bold")
		tx.Format(w, "bold", "true")
		tx.Unformat(w, "link")
		if !has(TxFormatText(w.id, 0, 1, 2, 5, []any{"italic", "true"})) {
			t.Error("FormatRange wrote no ranged 1 record carrying the range's bytes")
		}
		if !has(TxFormatText(w.id, 1, 1, 0, 2, []any{"bold", ""})) {
			t.Error("UnformatRange wrote no ranged 1 removal carrying the range's bytes")
		}
		if !has(TxFormatText(w.id, 0, 0, 0, 0, []any{"bold", "true"})) ||
			!has(TxFormatText(w.id, 1, 0, 0, 0, []any{"link", ""})) {
			t.Error("the SELECTION act did not write ranged 0 with no range — the two acts differ in the bytes alone")
		}
		if got, want := spellRuns(app.Document(w).Runs), "2:5 italic"; got != want {
			t.Errorf("the app's own Document did not take the ranged act as it sent: %q, want %q", got, want)
		}

		// A ranged block act covers the whole paragraphs it touches, as the
		// core snaps it — on the wire and in the fold alike.
		tx.FormatRange(w, TextRange{Start: 14, End: 16}, "block", "heading2")
		if !has(TxFormatText(w.id, 0, 1, 13, 24, []any{"block", "heading2"})) {
			t.Error("a ranged block act did not snap to the paragraph's own bytes on the wire")
		}
		if got, want := spellRuns(app.Document(w).Runs),
			"2:5 italic|13:24 block=heading2"; got != want {
			t.Errorf("the fold did not snap the block to the paragraph: %q, want %q", got, want)
		}

		// `body` is the REMOVAL, on the wire and in the fold.
		tx.FormatRange(w, TextRange{Start: 14, End: 16}, "block", "body")
		if !has(TxFormatText(w.id, 1, 1, 13, 24, []any{"block", ""})) {
			t.Error("a ranged block act with `body` did not write the removal")
		}
		if got, want := spellRuns(app.Document(w).Runs), "2:5 italic"; got != want {
			t.Errorf("`body` left the block run in the fold: %q, want %q", got, want)
		}
	})
}

// A NEGATIVE OFFSET IS THIS BINDING'S OWN WALL (TextRange.check): Go's int
// is signed and the wire's offset is not, so a strings.Index miss would
// reach the core as 2^64-1 under a number the app never wrote.
func TestFormatRangeRefusesANegativeOffsetByName(t *testing.T) {
	defer func() {
		said, ok := recover().(string)
		if !ok || !strings.Contains(said, "FormatRange") || !strings.Contains(said, "-1") {
			t.Errorf("FormatRange on a strings.Index miss said %v, which does not name the verb and the offset", said)
		}
	}()
	NewApp().Build(func(tx *Tx) {
		tx.FormatRange(tx.Textarea(nil).Rich(), TextRange{Start: -1, End: 2}, "bold", "true")
	})
}

// THE NAMED ACTS (docs/rich-text-plan.md §18): sugar and nothing else —
// each writes the record Tx.Format writes under its own name, Link
// carrying the URL where the flags carry "true".
func TestNamedActsWriteTheRecordFormatWrites(t *testing.T) {
	acts := []struct{ verb, name, value string }{
		{"Bold", "bold", "true"},
		{"Italic", "italic", "true"},
		{"Underline", "underline", "true"},
		{"Strike", "strike", "true"},
		{"Code", "code", "true"},
		{"Link", "link", "https://kaya.dev"},
	}
	NewApp().Build(func(tx *Tx) {
		w := tx.Textarea(nil).Rich()
		before := len(tx.records)
		tx.Bold(w)
		tx.Italic(w)
		tx.Underline(w)
		tx.Strike(w)
		tx.Code(w)
		tx.Link(w, "https://kaya.dev")
		got := tx.records[before:]
		if len(got) != len(acts) {
			t.Fatalf("the six named acts wrote %d records, want %d", len(got), len(acts))
		}
		for i, act := range acts {
			want := TxFormatText(w.id, 0, 0, 0, 0, []any{act.name, act.value})
			if !bytes.Equal(got[i], want) {
				t.Errorf("%s(w) wrote %x, want Format(w, %q, %q)'s %x",
					act.verb, got[i], act.name, act.value, want)
			}
		}
	})
}

// THE RICH LABEL (docs/rich-text-plan.md R8, §15): Rich is a Widget method,
// so nothing else in this binding says it reaches a LABEL. The CREATE record
// is read beside the prop, since prop 32 on a textarea proves nothing here.
func TestRichOnALabelDeclaresPropRichOnALabel(t *testing.T) {
	app := NewApp()
	var rich, plain Widget
	var records [][]byte
	app.Build(func(tx *Tx) {
		rich = tx.LabelText("Héllo world, code").Rich()
		plain = tx.LabelText("Héllo world, code")
		records = append(records, tx.records...)
	})
	has := func(want []byte) bool {
		for _, rec := range records {
			if bytes.Equal(rec, want) {
				return true
			}
		}
		return false
	}
	if !has(TxCreateWidget(rich.id, KindLabel)) {
		t.Fatalf("the widget Rich rode on is not a label, so this test proves nothing about R8")
	}
	if !has(TxSetRich(rich.id, true)) {
		t.Errorf("Rich() on a label queued no prop %d record — the label would draw its runs nowhere", PropRich)
	}
	if has(TxSetRich(plain.id, true)) {
		t.Errorf("a plain label carries prop %d", PropRich)
	}
}
