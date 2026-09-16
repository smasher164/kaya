// The rich rows scene (tools/scenes/richrows.steps): a rich textarea per
// stamped ROW whose document is a FIELD of the row
// (docs/rich-text-plan.md §19). The app writes a copy's document by
// patching its row, and a copy's own act folds into the row the app
// reads back.
//     KAYA_SELFTEST=richrows node guests/js/richrows.ts

import * as kaya from "kaya-gui";

const Note = kaya.record({ title: String, body: kaya.Document }, "Note");
type NoteFields = kaya.Fields<typeof Note.schema>;

const app = new kaya.App();

/** The core's spelling of runs (`expect_runs`), so the row's field and
 * the core's mirror are compared as one string. */
function spell(runs: readonly kaya.Run[]): string {
  return runs.map((run) => (run.value === "true" ? `${run.start}:${run.end} ${run.name}` : `${run.start}:${run.end} ${run.name}=${run.value}`)).join("|");
}

// The row's field already carries the copy's act when this fires: the app
// reads the row, never the widget.
function onActed(note: kaya.RowHandle<NoteFields>): void {
  last.set(`${String(note.key)}: ${spell(note.body.runs)}`);
}

let notes!: kaya.Collection<NoteFields, kaya.Row<typeof Note.schema>>;
let last!: kaya.Signal<string>;
let view!: kaya.Signal<string>;

app.window({ title: "richrows" }, () => {
  notes = kaya.collection(Note);
  last = kaya.signal("");
  view = kaya.signal("");
  kaya.column(() => {
    kaya.label({ bind: last }); // label#0
    kaya.label({ bind: view }); // label#1
    kaya.row(() => {
      kaya.button("patch b", {
        onClick: () => {
          notes.patch("b", { body: new kaya.Document("Patched").mark([0, 7], "italic", "true") });
        },
      });
      kaya.button("read a", {
        onClick: () => {
          const note = notes.get("a")!;
          view.set(`${note.body.text} | ${spell(note.body.runs)}`);
        },
      });
    });
    for (const note of notes) {
      kaya.column(() => {
        kaya.label({ bind: note.title });
        kaya.textarea({ document: note.body, onEdit: onActed, onFormat: onActed }).a11yId("body");
      });
    }
  });
  notes.insert("a", Note({ title: "a", body: new kaya.Document("Héllo world").mark([0, 6], "bold", "true") }));
  notes.insert("b", Note({ title: "b", body: new kaya.Document("Second note").mark([7, 11], "link", "https://kaya.dev") }));
});

app.run();
