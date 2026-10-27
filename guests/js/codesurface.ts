// The code surface scene (tools/scenes/codesurface.steps,
// docs/code-surface-plan.md): a textarea that numbers its lines, the
// platform's monospaced face, a family the app picks from the platform's
// list, a family the platform lacks, and a label at twice the platform's size.
//     KAYA_SELFTEST=codesurface node guests/js/codesurface.ts

import * as kaya from "kaya-gui";

// Forty lines; the third wraps at every lane's width.
const lines = [
  "// codesurface",
  "fn main() {",
  "    let note = \"this line is long on purpose, so that the textarea wraps it onto a second row " +
    "and the gutter has a continuation to leave unnumbered, the way every editor does\";",
];
for (let i = 4; i < 40; i++) lines.push(`    let value_${String(i).padStart(2, "0")} = ${i} * 2;`);
lines.push("}");
const DOC = lines.join("\n");
const END = new TextEncoder().encode(DOC).length;

const app = new kaya.App();

function onEnd(): void {
  code.focus();
  code.selectRange([END, END]);
  code.revealRange([END, END]);
}

kaya.onFontFamilies((families) => {
  const ordered = families.every((name, i) => i === 0 || families[i - 1]! < name);
  listed.set(families.length === 0 ? "families: none"
    : ordered ? "families: listed, unique, in order" : "families: out of order");
  if (families.length > 0) picked.family(families[0]!);
});

const { code, listed, picked } = app.window({ title: "codesurface" }, () => {
  const listed = kaya.signal("families: -");
  let code!: kaya.Widget;
  let picked!: kaya.Widget;
  kaya.column(() => {
    code = kaya.textarea().lineNumbers().monospaced().a11yId("code").setText(DOC);
    kaya.textarea().a11yId("plain").setText("plain text\nin the app's face");
    kaya.label("let x = 1;").monospaced().a11yId("mono");
    kaya.entry().monospaced().a11yId("mono_entry").setText("let y = 2;");
    kaya.label("missing").family("Kaya No Such Family").monospaced().a11yId("missing");
    kaya.label("Big").textScale(2).a11yId("big");
    kaya.label("Plain").a11yId("plain_label");
    kaya.label({ bind: listed }).a11yId("families");
    picked = kaya.label("picked").a11yId("picked");
    kaya.row(() => {
      kaya.button("end", { onClick: onEnd }).a11yId("end");
      kaya.button("fonts", { onClick: () => kaya.listFontFamilies() }).a11yId("fonts");
    });
  });
  return { code, listed, picked };
});

app.run();
