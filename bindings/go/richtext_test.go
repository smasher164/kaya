package kaya

// The rich mirror's fold, headless: the binding's Document must answer
// exactly what the core's own does (docs/rich-text-plan.md R1,
// crates/kaya/src/app.rs AppCtx::absorb_edit / absorb_format /
// normalize_runs). No core, no library — a bare App is the mirror.

import (
	"fmt"
	"strings"
	"testing"
)

func spellRuns(runs []TextRun) string {
	parts := make([]string, 0, len(runs))
	for _, run := range runs {
		if run.Value == "true" {
			parts = append(parts, fmt.Sprintf("%d:%d %s", run.Start, run.End, run.Name))
			continue
		}
		parts = append(parts, fmt.Sprintf("%d:%d %s=%s", run.Start, run.End, run.Name, run.Value))
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
			[]TextRun{{0, 10, "bold", "true"}, {4, 6, "bold", "true"}},
			"0:10 bold"},
		{"adjacent and equal merge",
			[]TextRun{{0, 4, "bold", "true"}, {4, 8, "bold", "true"}},
			"0:8 bold"},
		{"adjacent and DIFFERENT do not merge",
			[]TextRun{{0, 4, "block", "heading1"}, {4, 8, "block", "heading2"}},
			"0:4 block=heading1|4:8 block=heading2"},
		{"a later value wins over the range it covers",
			[]TextRun{{0, 8, "block", "heading1"}, {2, 4, "block", "quote"}},
			"0:2 block=heading1|2:4 block=quote|4:8 block=heading1"},
		{"two attributes over one range are two runs, ordered by name",
			[]TextRun{{0, 4, "link", "u"}, {0, 4, "bold", "true"}},
			"0:4 bold|0:4 link=u"},
		{"an empty run is dropped",
			[]TextRun{{3, 3, "bold", "true"}, {0, 2, "bold", "true"}},
			"0:2 bold"},
		{"ordered by start, then by name",
			[]TextRun{{6, 8, "italic", "true"}, {0, 2, "bold", "true"}, {0, 2, "italic", "true"}},
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
	a.absorbEdit(one.id, 2, 3, "XYZ", []TextRun{{1, 2, "code", "true"}})
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
	c.absorbEdit(one.id, 40, 60, "fresh", []TextRun{{0, 5, "bold", "true"}})
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
	a.absorbEdit(one.id, e.Start, e.End, e.Inserted, e.Runs)
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
	a.absorbEdit(one.id, 29, 29, "x", []TextRun{{0, 1, "block", "heading2"}})
	step("0:17 block=heading1|8:11 italic|12:17 link=" + link +
		"|18:30 block=heading2")
	a.absorbEdit(one.id, 30, 30, "y",
		[]TextRun{{0, 1, "block", "heading2"}, {0, 1, "bold", "true"}})
	step("0:17 block=heading1|8:11 italic|12:17 link=" + link +
		"|18:31 block=heading2|30:31 bold")

	// button#6's prefix: the app's document takes it at once.
	p := Insert(0, "> ")
	a.absorbEdit(one.id, p.Start, p.End, p.Inserted, p.Runs)
	step("2:19 block=heading1|10:13 italic|14:19 link=" + link +
		"|20:33 block=heading2|32:33 bold")

	// THE SPLICE IS IN BYTES: the é puts byte 6 after the first word and
	// UTF-16 index 6 inside the second.
	if got, want := a.Document(one).Text,
		"> Héllo, big world\nSecond linexy"; got != want {
		t.Errorf("text %q, want %q", got, want)
	}
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
