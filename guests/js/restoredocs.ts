// The restored shape (tools/scenes/restoredocs.steps,
// docs/restoration-plan.md SR9): each document's title and text live in its
// own session scope, and act two recreates the documents the last launch
// left, takes each scope back, and selects the active one.

import * as kaya from "kaya-gui";

const app = new kaya.App();

let documents: readonly number[] = [10, 11, 12];
let active = 0;
const primary = kaya.restoredWindows().find((w) => w.id === 0);
if (primary !== undefined) {
  documents = primary.documents;
  active = primary.activeDocument;
} else {
  ["a", "b", "c"].forEach((title, i) => kaya.documentSession(documents[i]!).setString("title", title));
}

app.window({ title: "restoredocs", width: 640, height: 420 }, () => undefined);

for (const id of documents) {
  const scope = kaya.documentSession(id);
  const title = scope.getString("title", "untitled");
  app.addDocument(id, { title, restore: id }, () => {
    const caption = kaya.signal(`${title} body`);
    kaya.column(() => {
      kaya.label({ bind: caption }).a11yId(`caption-${title}`);
      kaya.entry({ onChange: (text: string) => scope.setString("body", text) })
        .a11yId(`body-${title}`)
        .setText(scope.getString("body", ""));
      kaya.button("recall", {
        onClick: () => caption.set(`${kaya.documentSession(id).getString("title", "untitled")} body`),
      }).a11yId(`recall-${title}`);
    });
  });
}

if (active !== 0) app.build(() => kaya.selectDocument(active));

app.run();
