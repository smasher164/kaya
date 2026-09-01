// The text-ranges conformance scene, JS port: the three primitives an
// editor cannot write for itself — HIGHLIGHT a set of ranges, SELECT one,
// REVEAL one — driven by a search this file writes in six lines.
//
// kaya ships no find engine, no find bar and no regex dialect
// (docs/ranges-plan.md §3): what to decorate is the app's question.
//
// THE OFFSETS ARE UTF-8 BYTE OFFSETS, WHICH IS WHY THE SEARCH RUNS OVER A
// `Buffer` AND NOT OVER THE STRING — `String.indexOf` counts UTF-16 code
// units, so the two disagree on this document. The rule and the numbers
// are in `highlightRanges`' doc comment (bindings/js/kaya/index.ts); the
// document opens with a CJK word so a guest that mixed the units
// decorates six characters early and the frozen offsets say so.
//
// Canonical semantics in guests/rust/ranges.rs; the byte-frozen contract
// in tools/scenes/ranges.steps.

import * as kaya from "kaya-gui";

const app = new kaya.App();

// BYTE-IDENTICAL to guests/rust/ranges.rs's DOC: the scene's frozen
// offsets are positions in THESE bytes. Three occurrences of `alpha` and
// nothing else containing it; forty short lines, so the last match is
// below a 240x96 viewport and REVEAL has something to do.
const DOC = `line 00: 日本語 preface
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
line 39: the last line`;

const NEEDLE = "alpha";

// The app's own copy, which is the ONLY authority on what the offsets
// mean. It advances on every edit.
let doc = DOC;

/** The whole search: literal, forward, non-overlapping, over the UTF-8
 * BYTES, so what it yields is already kaya's unit. */
function findAll(text: string, needle: string): [number, number][] {
  const data = Buffer.from(text, "utf8");
  const hit = Buffer.from(needle, "utf8");
  const hits: [number, number][] = [];
  let at = data.indexOf(hit);
  while (at >= 0) {
    hits.push([at, at + hit.length]);
    at = data.indexOf(hit, at + hit.length);
  }
  return hits;
}

function onEdit(text: string): void {
  // kaya has ALREADY dropped the decorations (D2: a declared set is
  // bound to the text it was declared against); this is the app
  // agreeing, not being told.
  doc = text;
  status.set("0 matches");
}

function onFind(): void {
  const hits = findAll(doc, NEEDLE);
  editor.highlightRanges(hits);
  // The second match, so a leg can tell the selection apart from "the
  // first thing found".
  if (hits.length > 1) editor.selectRange(hits[1]!);
  status.set(`${hits.length} matches`);
}

function onRevealLast(): void {
  const hits = findAll(doc, NEEDLE);
  if (hits.length > 0) editor.revealRange(hits[hits.length - 1]!);
}

function onFocusEditor(): void {
  editor.focus();
}

function onSelectFirst(): void {
  const hits = findAll(doc, NEEDLE);
  if (hits.length > 0) editor.selectRange(hits[0]!);
}

let status!: kaya.Signal<string>;
let editor!: kaya.Widget;

app.window({ title: "ranges" }, () => {
  status = kaya.signal("0 matches");
  kaya.column(() => {
    // The a11y id is REQUIRED, not decoration: every range assertion
    // reads the platform's accessibility tree and finds this control
    // by that id.
    editor = kaya.textarea({ onChange: onEdit }); // textarea#0
    editor.a11yId("doc").a11yLabel("Document").setText(DOC);
    kaya.label({ bind: status }); // label#0
    kaya.row(() => {
      kaya.button("find", { onClick: onFind }); // button#0
      kaya.button("reveal last", { onClick: onRevealLast }); // button#1
      kaya.button("focus editor", { onClick: onFocusEditor }); // button#2
      kaya.button("select first", { onClick: onSelectFirst }); // button#3
    });
  });
});

app.run();
