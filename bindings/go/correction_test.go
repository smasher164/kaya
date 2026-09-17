package kaya

// The correction slice (the idiom review, 2026-09-17): the typed
// vocabularies a guest passes, the range a run carries, the boolean a
// flag attribute is on both sides, and the typed collection's own
// Remove/Count. Headless — no core, no library.

import (
	"strings"
	"testing"
)

// G1/X1: the four vocabularies that shipped as untyped constants are
// named types with String(), like the five beside them.
func TestVocabulariesAreNamedTypes(t *testing.T) {
	for _, c := range []struct {
		got  string
		want string
	}{
		{AlertChoiceAction0.String(), "action0"},
		{AlertChoiceCancel.String(), "cancel"},
		{NotificationOutcomeActivated.String(), "activated"},
		{NotificationOutcomeRefused.String(), "refused"},
		{FileModeRead.String(), "read"},
		{FileModeReadWrite.String(), "read_write"},
		{SectionsPresentationSidebar.String(), "sidebar"},
	} {
		if c.got != c.want {
			t.Fatalf("a vocabulary spelled itself %q, wanted %q", c.got, c.want)
		}
	}
	// A number outside the vocabulary names its own type rather than
	// passing for a member.
	if got := FileMode(9).String(); got != "FileMode(9)" {
		t.Fatalf("an unknown file mode spelled itself %q", got)
	}
}

// X2: a run, an edit and a format carry a RANGE, and a flag attribute is
// a bool on both sides.
func TestFlagIsABoolOnBothSides(t *testing.T) {
	doc := NewDocument("abcd").Flag(0, 2, "italic", true).Link(2, 4, "https://kaya.dev")
	if len(doc.Runs) != 2 {
		t.Fatalf("the bool mark left %d run(s)", len(doc.Runs))
	}
	if !doc.Runs[0].IsFlag() || doc.Runs[0].Value != "true" {
		t.Fatalf("a bool mark did not reach the wire as its flag string (%q)", doc.Runs[0].Value)
	}
	if doc.Runs[1].IsFlag() {
		t.Fatal("a valued attribute read back as a flag")
	}
	if doc.Runs[0].Range != (TextRange{Start: 0, End: 2}) {
		t.Fatalf("a run does not carry its own span: %+v", doc.Runs[0].Range)
	}
	if Replace(1, 3, "x").Range != (TextRange{Start: 1, End: 3}) {
		t.Fatal("an edit does not carry its own span")
	}
	if !Insert(3, "x").Flag(0, 1, "code", true).Runs[0].IsFlag() {
		t.Fatal("an edit's bool mark did not read back as a flag")
	}
}

// X2/S3: a span the CORE sent with its ends out of order is refused BY
// NAME. No scene reaches it — the core always sends ordered spans.
func TestReversedSpanIsRefusedNamingTheRecord(t *testing.T) {
	defer func() {
		said, ok := recover().(string)
		if !ok {
			t.Fatal("a reversed span was NOT refused")
		}
		if !strings.Contains(said, "text_edited carries 5..3, a reversed span") {
			t.Fatalf("the refusal did not name the record and both ends: %q", said)
		}
	}()
	decodedSpan("text_edited", 5, 3)
}

// G2: the untyped floor is no longer one exported field away, and the
// typed collection completes — Remove and Count beside the rest.
func TestTypedCollectionRemovesAndCounts(t *testing.T) {
	type note struct{ Title string }
	app := NewApp()
	var notes RecordCollection[string, note]
	app.Build(func(tx *Tx) {
		notes = CollectionOf[string, note](tx)
		notes.Insert(tx, "a", note{Title: "one"})
		notes.Insert(tx, "b", note{Title: "two"})
	})
	app.Build(func(tx *Tx) {
		if n := notes.Count(tx); n != 2 {
			t.Fatalf("Count read %d, wanted 2", n)
		}
		notes.Remove(tx, "a")
		if n := notes.Count(tx); n != 1 {
			t.Fatalf("Count after Remove read %d, wanted 1", n)
		}
		if _, ok := notes.Get(tx, "a"); ok {
			t.Fatal("the removed entry is still in the model")
		}
		if notes.Handle().id == 0 {
			t.Fatal("Handle answered no collection")
		}
	})
}
