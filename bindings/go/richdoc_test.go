package kaya

import (
	"strings"
	"testing"
)

// The .kdoc pair is the core's (docs/rich-document-plan.md RD13): Go writes
// the bytes Rust writes, and reads them back into the same runs.
func TestKdocRoundTripsThroughTheCore(t *testing.T) {
	doc := NewDocument("Walks\nmap\nwater").
		Block(0, 5, Heading1).
		List(6, 15, ListBullet).
		Indent(10, 15, 1).
		Color(10, 15, "#c4554d")
	file := string(doc.ToKdoc())
	if !strings.Contains(file, `{"list": "bullet", "indent": 1, "spans": [["water", {"color": "#C4554D"}]]}`) {
		t.Fatalf("the file:\n%s", file)
	}
	back, err := FromKdoc([]byte(file))
	if err != nil || back.ReadOnly != "" {
		t.Fatalf("read back: %v %q", err, back.ReadOnly)
	}
	if string(back.Document.ToKdoc()) != file {
		t.Fatalf("a second write differs:\n%s", back.Document.ToKdoc())
	}
	if _, err := FromKdoc([]byte(`{"kaya": "document", "version": 2, "paragraphs": []}`)); err == nil ||
		err.Error() != "the document is version 2, newer than the version 1 this kaya reads" {
		t.Fatalf("a newer version: %v", err)
	}
	unknown, err := FromKdoc([]byte(`{"kaya": "document", "version": 1, "com.example.theme": {"page": "sepia"}, "paragraphs": [{"com.example.pinned": true, "spans": [["Pinned"]]}]}`))
	if err != nil || unknown.ReadOnly != "" || unknown.Document.Extra != `{"com.example.theme":{"page":"sepia"}}` ||
		len(unknown.Document.Runs) != 1 || unknown.Document.Runs[0].Name != "para:com.example.pinned" {
		t.Fatalf("RD17 A: an unknown top level rides Extra and a paragraph key a para: run: %v %+v", err, unknown)
	}
	again, err := FromKdoc(unknown.Document.ToKdoc())
	if err != nil || !again.Document.Equal(unknown.Document) || again.Document.Equal(Document{Text: "Pinned", Runs: unknown.Document.Runs}) {
		t.Fatalf("RD17 A: Extra writes back and is part of equality: %v %+v", err, again)
	}
}

// A ranged paragraph act snaps to whole paragraphs in the app's own fold, as
// the core snaps it (docs/rich-document-plan.md §11).
func TestARangedListActSnapsToParagraphs(t *testing.T) {
	if !paragraphAttr("list") || paragraphAttr("color") {
		t.Fatal("the paragraph attributes are block, list, indent, checked, start and align")
	}
	for name, want := range map[string]bool{"para:com.example.pinned": true, "para:embed": true, "para:para:x": true,
		"para:": false, "para:spans": false, "para:list": false, "com.example.pinned": false} {
		if paragraphAttr(name) != want {
			t.Fatalf("paragraphAttr(%q) is %t, and crates/kaya/src/richdoc.rs is_para_key says %t", name, !want, want)
		}
	}
	a := mirror()
	a.seedDocument(one.id, Document{Text: "ab", Extra: `{"a.b":1}`})
	a.absorbEdit(one.id, 2, 2, "c", nil)
	if a.Document(one).Extra != `{"a.b":1}` {
		t.Fatal("the fold leaves Extra alone")
	}
	if !absentValue("list", "none") || !absentValue("indent", "0") || absentValue("list", "bullet") {
		t.Fatal("none and 0 are absences")
	}
	if canonicalValue("color", "#abcdef") != "#ABCDEF" {
		t.Fatal("a colour has one spelling")
	}
}
