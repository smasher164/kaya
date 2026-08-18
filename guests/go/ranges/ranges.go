// The text-ranges conformance scene, Go port: HIGHLIGHT a set of ranges,
// SELECT one, REVEAL one, driven by a search this file writes in eight
// lines. kaya ships no find engine and no dialect
// (docs/ranges-plan.md §3); what it ships is the half no app can write.
//
// THE OFFSETS ARE GO STRING INDICES. strings.Index yields byte offsets
// and that is what kaya.TextRange holds, so nothing converts anywhere in
// this file. The document OPENS WITH A CJK WORD deliberately: every
// match then sits SIX BYTES further along than it does in UTF-16, the
// unit four of the five backends count, so a backend forwarding kaya's
// byte offsets as its own unit decorates six characters early and the
// frozen offsets say so.
//
// Canonical semantics in guests/rust/ranges.rs; the byte-frozen contract
// in tools/scenes/ranges.steps.
package ranges

import (
	"fmt"
	"strings"

	kaya "dev.kaya/bindings/go"
)

// The document, frozen — byte-identical to the Rust guest's DOC (813
// bytes). Three occurrences of `alpha`; forty short lines, so the last
// match is far below a 240x96 viewport and REVEAL has something to do.
//
// A RAW STRING LITERAL, and the opening backtick is followed immediately
// by `line 00:` — a newline there would be a byte of document.
const document = `line 00: 日本語 preface
line 01: gamma kappa
line 02: alpha beta gamma
line 03: epsilon theta
line 04: zeta nu
line 05: eta zeta
line 06: theta lambda
line 07: iota delta
line 08: kappa iota
line 09: alpha eta theta
line 10: mu eta
line 11: nu mu
line 12: beta epsilon
line 13: gamma kappa
line 14: delta gamma
line 15: epsilon theta
line 16: zeta nu
line 17: eta zeta
line 18: theta lambda
line 19: iota delta
line 20: kappa iota
line 21: lambda beta
line 22: mu eta
line 23: nu mu
line 24: beta epsilon
line 25: gamma kappa
line 26: delta gamma
line 27: epsilon theta
line 28: zeta nu
line 29: eta zeta
line 30: theta lambda
line 31: iota delta
line 32: kappa iota
line 33: lambda beta
line 34: mu eta
line 35: nu mu
line 36: beta epsilon
line 37: alpha iota kappa
line 38: delta gamma
line 39: the last line`

const needle = "alpha"

// THE WHOLE SEARCH: literal, forward, non-overlapping. An editor that
// wants case folding, word boundaries or a regex dialect writes it here,
// in the app.
func findAll(doc, needle string) []kaya.TextRange {
	var hits []kaya.TextRange
	for at := 0; ; {
		i := strings.Index(doc[at:], needle)
		if i < 0 {
			return hits
		}
		hits = append(hits, kaya.TextRange{Start: at + i, End: at + i + len(needle)})
		at += i + len(needle)
	}
}

func App() *kaya.App {
	app := kaya.NewApp()

	// The app's OWN copy of the document, the only authority on what the
	// offsets mean — kaya never reads text back.
	doc := document

	var status kaya.Signal[string]
	var editor kaya.Widget

	app.Build(func(tx *kaya.Tx) {
		tx.Window(0).Title("ranges")
		status = tx.Signal("0 matches")

		tx.Mount(tx.Column(func() {
			// The a11y id is not decoration: every range assertion reads
			// the platform's accessibility tree and finds this control
			// by it.
			editor = tx.Textarea(func(tx *kaya.Tx, text string) {
				doc = text
				// THE SEARCH RESULTS ARE STALE AND THE APP SAYS SO: kaya
				// has already dropped the decorations, because a
				// declared set is bound to the text it was declared
				// against.
				tx.Write(status, "0 matches")
			}).A11yID("doc").A11yLabel("Document")
			tx.SetText(editor, document)

			tx.Label(status) // label#0

			tx.Row(func() {
				tx.Button("find", func(tx *kaya.Tx) { // button#0
					hits := findAll(doc, needle)
					tx.HighlightRanges(editor, hits)
					// The SECOND match, so a leg can tell the selection
					// apart from "the first thing found".
					if len(hits) > 1 {
						tx.SelectRange(editor, hits[1])
					}
					tx.Write(status, fmt.Sprintf("%d matches", len(hits)))
				})
				tx.Button("reveal last", func(tx *kaya.Tx) { // button#1
					if hits := findAll(doc, needle); len(hits) > 0 {
						tx.RevealRange(editor, hits[len(hits)-1])
					}
				})
				tx.Button("focus editor", func(tx *kaya.Tx) { // button#2
					tx.Focus(editor)
				})
				tx.Button("select first", func(tx *kaya.Tx) { // button#3
					if hits := findAll(doc, needle); len(hits) > 0 {
						tx.SelectRange(editor, hits[0])
					}
				})
			})
		}))
	})

	return app
}
