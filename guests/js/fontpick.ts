// The font picker scene, JS port: guests/rust/fontpick.rs,
// tools/scenes/fontpick.steps (docs/font-picker-plan.md §7).
//     KAYA_SELFTEST=fontpick node guests/js/fontpick.ts

import * as kaya from "kaya-gui";

const MONO = ["Menlo", "DejaVu Sans Mono", "Cascadia Mono", "Consolas", "Courier New",
  "Droid Sans Mono", "monospace"];
const DOC = "bold run, italic run, plain run";

function words(weight: number, italic: boolean, width: number): string {
  return `${weight} ${italic ? "italic" : "upright"} ${width}`;
}

function lightFamily(faces: readonly kaya.FontFace[]): [number, number, number] | null {
  const upright = faces.filter((f) => !f.italic && f.width === 5).map((f) => f.weight);
  const italic = faces.filter((f) => f.italic && f.width === 5).map((f) => f.weight);
  if (upright.length < 3 || !upright.includes(700)) return null;
  const light = upright.find((w) => w < 400 && italic.includes(w));
  if (light === undefined) return null;
  for (let i = 1; i < upright.length; i++) {
    const a = upright[i - 1]!;
    const b = upright[i]!;
    if (a >= 500 && b > a + 1) return [light, a, b];
  }
  return null;
}

function uprightOnly(faces: readonly kaya.FontFace[]): number | null {
  if (faces.length === 0 || faces.some((f) => f.italic)) return null;
  return faces.find((f) => f.width === 5)?.weight ?? null;
}

function noBold(faces: readonly kaya.FontFace[]): boolean {
  return faces.length > 0 && faces.every((f) => f.weight < 600);
}

function same(a: kaya.FontChoice | null, b: kaya.FontChoice): boolean {
  return a !== null && a.family === b.family && a.weight === b.weight && a.italic === b.italic
    && a.width === b.width;
}

const app = new kaya.App();
let queue: string[] = [];
let light: [string, [number, number, number]] | null = null;
let plain: [string, number] | null = null;
let boldless: string | null = null;
let mono: string | null = null;
let asked: kaya.FontChoice | null = null;

kaya.onFontFamilies((families) => {
  mono = MONO.find((m) => families.includes(m)) ?? null;
  queue = [...families].reverse();
  if (mono !== null) queue.push(mono);
  const next = queue.pop();
  if (next !== undefined) kaya.listFontFaces(next);
});

kaya.onFontFaces((family, faces) => {
  if (family === mono && asked === null) {
    const face = faces.find((f) => f.weight === 700 && !f.italic && f.width === 5) ?? faces[0];
    if (face !== undefined) asked = { family, weight: face.weight, italic: face.italic, width: face.width };
  }
  if (light === null) {
    const l = lightFamily(faces);
    if (l !== null) light = [family, l];
  }
  if (plain === null) {
    const p = uprightOnly(faces);
    if (p !== null) plain = [family, p];
  }
  if (boldless === null && noBold(faces)) boldless = family;
  if (light === null || plain === null || boldless === null) {
    const next = queue.pop();
    if (next !== undefined) kaya.listFontFaces(next);
    else ready.set("faces: none suit");
    return;
  }
  const [lf, [lw, a, b]] = light;
  const [pf, pw] = plain;
  exact.family(lf).fontWeight(lw);
  between.family(lf).fontWeight(a + Math.floor((b - a) / 2));
  synth.family(pf).fontWeight(pw).fontItalic(true);
  heavy.family(boldless).fontWeight(700);
  doc.family(lf).fontWeight(lw);
  doc.setDocument(new kaya.Document(DOC).bold([0, 4]).italic([10, 16]));
  want[0]!.set(words(lw, false, 5));
  want[1]!.set(words(b, false, 5));
  want[2]!.set(`${words(pw, true, 5)} synthesized`);
  want[3]!.set(words(700, false, 5));
  want[4]!.set(words(lw, true, 5));
  want[6]!.set(`${words(700, false, 5)} synthesized`);
  if (asked !== null) {
    pick.set(`${words(asked.weight, asked.italic, asked.width)} ${asked.family}`);
    want[5]!.set(words(asked.weight, asked.italic, asked.width));
  }
  ready.set("faces: found");
});

function onChosen(c: kaya.FontChoice | null): void {
  if (c === null) {
    picked.set("picked: cancelled");
    return;
  }
  chosen.family(c.family).fontWeight(c.weight).fontItalic(c.italic).fontWidth(c.width);
  picked.set(same(asked, c) ? "picked: as asked" : `picked: ${words(c.weight, c.italic, c.width)} ${c.family}`);
}

function onPick(): void {
  kaya.chooseFont({ codeOnly: true, faces: true, ...(asked !== null ? { initial: asked } : {}), onResult: onChosen });
}

const { ready, want, pick, picked, exact, between, synth, heavy, doc, chosen } = app.window({ title: "fontpick" }, () => {
  const ready = kaya.signal("faces: -");
  const want = [0, 1, 2, 3, 4, 5, 6].map(() => kaya.signal("-"));
  const pick = kaya.signal("-");
  const picked = kaya.signal("picked: -");
  let exact!: kaya.Widget;
  let between!: kaya.Widget;
  let synth!: kaya.Widget;
  let heavy!: kaya.Widget;
  let doc!: kaya.Widget;
  let chosen!: kaya.Widget;
  kaya.column(() => {
    kaya.label({ bind: ready }).a11yId("ready");
    exact = kaya.label("Exact").a11yId("exact");
    between = kaya.label("Between").a11yId("between");
    synth = kaya.label("Slanted").a11yId("synth");
    heavy = kaya.entry().a11yId("heavy").setText("Heavy");
    doc = kaya.textarea({ rich: true }).a11yId("doc");
    chosen = kaya.label("Chosen").a11yId("chosen");
    ["want_exact", "want_between", "want_synth", "want_bold", "want_italic", "want_pick", "want_heavy"].forEach((id, i) => {
      kaya.label({ bind: want[i]! }).a11yId(id);
    });
    kaya.label({ bind: pick }).a11yId("pick");
    kaya.label({ bind: picked }).a11yId("picked");
    kaya.row(() => {
      kaya.button("faces", { onClick: () => kaya.listFontFamilies() }).a11yId("faces");
      kaya.button("pick", { onClick: onPick }).a11yId("pick_button");
    });
  });
  return { ready, want, pick, picked, exact, between, synth, heavy, doc, chosen };
});

app.run();
