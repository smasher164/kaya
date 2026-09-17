// The textarea conformance scene (tools/scenes/textarea.steps).

import * as kaya from "kaya-gui";

const app = new kaya.App();

function count(text: string): string {
  return text === "" ? "0 lines" : `${text.split("\n").length} lines`;
}

function onEdit(text: string): void {
  lines.set(count(text));
}

function onClear(): void {
  editor.clear();
  editor.focus();
}

const { lines, editor } = app.window({ title: "textarea" }, () => {
  const lines = kaya.signal("0 lines");
  let editor!: kaya.Widget;
  kaya.column(() => {
    editor = kaya.textarea({ onChange: onEdit });
    kaya.label({ bind: lines });
    kaya.button("clear", { onClick: onClear });
  });
  return { lines, editor };
});

app.run();
