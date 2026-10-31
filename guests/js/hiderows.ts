// The hidden-rows scene (tools/scenes/hiderows.steps; docs/hidden-plan.md).
// Canonical semantics in guests/rust/hiderows.rs.

import * as kaya from "kaya-gui";

const Note = kaya.record({ title: String, unmatched: Boolean }, "Note");
const File = kaya.record({ name: String, size: String, unmatched: Boolean }, "File");

const NOTES = ["alpha", "beta", "gamma"];

function fileName(i: number): string {
  return `file ${String(i).padStart(3, "0")}`;
}

const app = new kaya.App();

function findNotes(query: string): void {
  for (const title of NOTES) notes.patch(title, { unmatched: !title.includes(query) });
}

function findFiles(query: string): void {
  for (let i = 0; i < 300; i++) files.patch(fileName(i), { unmatched: !fileName(i).includes(query) });
}

const { notes, files } = app.window({ title: "hiderows" }, () => {
  const notes = kaya.collection(Note);
  const files = kaya.collection(File);
  const two = kaya.signal(false);

  kaya.column(() => {
    kaya.search({ placeholder: "Find notes", onChange: findNotes }).a11yId("find_notes");
    for (const note of notes.rows({ a11yId: "notes" })) {
      kaya.row((line) => {
        line.hidden(note.unmatched);
        kaya.label({ bind: note.title });
        kaya.entry().a11yId("note");
      });
    }
    kaya.grid(2, (tiles) => {
      tiles.a11yId("tiles");
      kaya.label("one");
      kaya.label("two").hidden(two);
      kaya.label("three");
    });
    kaya.checkbox("Hide two", { onToggle: (on: boolean) => two.set(on) }).a11yId("hide_two");
    kaya.search({ placeholder: "Find files", onChange: findFiles }).a11yId("find_files");
    for (const file of files.columns(["Name", "Size"], { grow: 1, a11yId: "files" })) {
      kaya.row((line) => {
        line.hidden(file.unmatched);
        kaya.label({ bind: file.name });
        kaya.label({ bind: file.size });
      });
    }
  });

  for (const title of NOTES) notes.insert(title, Note({ title, unmatched: false }));
  for (let i = 0; i < 300; i++) files.insert(fileName(i), File({ name: fileName(i), size: `${i} KB`, unmatched: false }));
  return { notes, files };
});

app.run();
