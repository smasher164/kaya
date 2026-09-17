package kaya

// A STAMPED COPY'S DOCUMENT IS A FIELD OF ITS ROW (docs/rich-text-plan.md
// §19), headless: the field travels as a Blob carrying ONE value list,
// and a copy's act folds into the ROW through the same fold the live
// mirror uses. No core, no library — a bare App is the model.

import (
	"bytes"
	"testing"
)

type note struct {
	Title string
	Body  Document
}

// The bytes the wire rules spell — {u32 count, u32 reserved}, then per
// value {u32 tag, u32 len, payload, padded to 8} — for
// NewDocument("ab").Mark(0,1,"bold","true").Mark(1,2,"link","u"): nine
// values, the text and four per run. Written out here rather than
// encoded, so this compares the encoder with the protocol and not with
// itself; bindings/python/kaya_app_checks.py and
// bindings/js/kaya_app_checks.ts freeze the same 152 bytes.
var referenceDocumentBlob = []byte{
	0x09, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
	0x61, 0x62, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00,
	0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
	0x62, 0x6f, 0x6c, 0x64, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
	0x74, 0x72, 0x75, 0x65, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00,
	0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00,
	0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
	0x6c, 0x69, 0x6e, 0x6b, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
	0x75, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
}

func seeded() Document {
	return NewDocument("ab").Mark(0, 1, "bold", "true").Mark(1, 2, "link", "u")
}

func TestADocumentFieldIsABlobOfTheWireRulesList(t *testing.T) {
	if tag, ok := wireTag(documentType); !ok || tag != ValueBlob {
		t.Fatalf("a Document field's schema tag is (%d, %v), want (%d, true)", tag, ok, ValueBlob)
	}
	if got := documentBlob(seeded()); !bytes.Equal(got, referenceDocumentBlob) {
		t.Errorf("documentBlob gave %d bytes\n%v\nwant %d\n%v",
			len(got), got, len(referenceDocumentBlob), referenceDocumentBlob)
	}
	// The record encoder reaches the same bytes through the field's own
	// schema slot, which is the path a row insert takes.
	info := recordInfoOf[note]()
	if info.schema[1] != ValueBlob {
		t.Fatalf("note.Body is schema tag %d, want %d", info.schema[1], ValueBlob)
	}
}

// rowModel is one collection instance holding one note under key "a",
// with the template node bound to its Body field.
func rowModel() (*App, uint64) {
	a := &App{
		documents:     make(map[uint64]Document),
		documentBinds: make(map[uint64]documentBind),
		model:         make(map[uint64][]*instance),
	}
	a.model[7] = []*instance{{entries: []Entry{{Key: "a", Value: note{Title: "a", Body: seeded()}}}}}
	a.documentBinds[3] = documentBind{collection: 7, field: 1}
	return a, 3
}

func TestARowsFieldTakesTheFoldTheLiveMirrorTakes(t *testing.T) {
	a, node := rowModel()
	live := mirror()
	live.seedDocument(one.id, seeded())

	inserted := []TextRun{{Range: TextRange{Start: 0, End: 1}, Name: "code", Value: "true"}}
	live.absorbEdit(one.id, 1, 1, "X", inserted)
	a.foldRowDocument(node, []any{"a"}, func(doc *Document) {
		foldEdit(doc, 1, 1, "X", inserted)
	})
	got := a.model[7][0].entries[0].Value.(note).Body
	want := live.documents[one.id]
	if got.Text != want.Text || spellRuns(got.Runs) != spellRuns(want.Runs) {
		t.Errorf("the row's field folded to %q %q, the live mirror to %q %q",
			got.Text, spellRuns(got.Runs), want.Text, spellRuns(want.Runs))
	}

	live.absorbFormat(one.id, 0, 3, "bold", "true", false)
	a.foldRowDocument(node, []any{"a"}, func(doc *Document) {
		foldFormat(doc, 0, 3, "bold", "true", false)
	})
	got = a.model[7][0].entries[0].Value.(note).Body
	if spellRuns(got.Runs) != spellRuns(live.documents[one.id].Runs) {
		t.Errorf("the row's field formatted to %q, the live mirror to %q",
			spellRuns(got.Runs), spellRuns(live.documents[one.id].Runs))
	}
}

func TestAGoneRowHasNoFieldToFoldInto(t *testing.T) {
	a, node := rowModel()
	before := a.model[7][0].entries[0].Value.(note).Body
	// A row that left, an instance that never existed, and a node bound
	// to nothing: each is silent, none is a fault.
	a.foldRowDocument(node, []any{"gone"}, func(doc *Document) { doc.Text = "moved" })
	a.foldRowDocument(node, []any{"deep", "a"}, func(doc *Document) { doc.Text = "moved" })
	a.foldRowDocument(node+1, []any{"a"}, func(doc *Document) { doc.Text = "moved" })
	after := a.model[7][0].entries[0].Value.(note).Body
	if after.Text != before.Text || spellRuns(after.Runs) != spellRuns(before.Runs) {
		t.Errorf("a fold with no row to land in moved the model to %q %q",
			after.Text, spellRuns(after.Runs))
	}
}
