// The text-ranges scene (tools/scenes/ranges.steps). THE OFFSETS ARE UTF-8
// BYTE OFFSETS, which is why the search runs over a `Buffer`.

import * as kaya from "kaya-gui";

const app = new kaya.App();

// BYTE-IDENTICAL to guests/rust/ranges.rs's DOC: the frozen offsets are of
// THESE bytes, and the last match must sit below the viewport.
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

// The ONLY authority on what the offsets mean; it advances on every edit.
let doc = DOC;

/** Over the UTF-8 BYTES, so what it yields is already kaya's unit. */
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
  // kaya has ALREADY dropped the decorations on this edit.
  doc = text;
  status.set("0 matches");
}

function onFind(): void {
  const hits = findAll(doc, NEEDLE);
  editor.highlightRanges(hits);
  // The SECOND match, so a leg can tell it from the first.
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
    // Every range assertion finds this control by its authored id.
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
