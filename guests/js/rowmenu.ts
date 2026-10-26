// The row menu scene (tools/scenes/rowmenu.steps; docs/media-player-plan.md
// M26). Canonical semantics in guests/rust/rowmenu.rs.

import * as kaya from "kaya-gui";

const Entry = kaya.record({ title: String, mark: String }, "Entry");
type EntryRow = kaya.RowHandle<kaya.Fields<typeof Entry.schema>>;

const app = new kaya.App();

function onStar(row: EntryRow): void {
  const on = row.mark === "Star";
  row.mark = on ? "Unstar" : "Star";
  status.set(`${on ? "starred" : "unstarred"} ${row.key}`);
}

function onPin(row: EntryRow): void {
  const on = row.mark === "Pin";
  row.mark = on ? "Unpin" : "Pin";
  status.set(`${on ? "pinned" : "unpinned"} ${row.key}`);
}

function onOpen(row: EntryRow): void {
  status.set(`opened ${row.key}`);
}

const { status } = app.window({ title: "rowmenu" }, () => {
  const status = kaya.signal("ready");
  const notes = kaya.collection(Entry);
  const files = kaya.collection(Entry);
  const [noteMenu, star] = kaya.contextCatalog((catalog) => {
    const star = kaya.item("Star", { onActivate: onStar });
    kaya.separator();
    kaya.item("Open", { onActivate: onOpen });
    return [catalog, star] as const;
  });
  const [fileMenu, pin] = kaya.contextCatalog((catalog) => {
    const pin = kaya.item("Pin", { onActivate: onPin });
    kaya.separator();
    kaya.item("Open", { onActivate: onOpen });
    return [catalog, pin] as const;
  });

  kaya.column(() => {
    kaya.label({ bind: status });
    for (const note of notes) {
      kaya.row((line) => {
        line.a11yId("note").contextMenu(noteMenu).contextLabel(star, note.mark);
        kaya.label({ bind: note.title });
      });
    }
    for (const file of files.columns(["Name"], { grow: 1 })) {
      kaya.row((line) => {
        line.a11yId("file").contextMenu(fileMenu).contextLabel(pin, file.mark);
        kaya.label({ bind: file.title });
      });
    }
  });
  for (const [key, title, mark] of [
    ["a", "apples", "Star"],
    ["b", "bread", "Unstar"],
  ] as const) {
    notes.insert(key, Entry({ title, mark }));
  }
  for (const [key, title, mark] of [
    ["x", "x.txt", "Pin"],
    ["y", "y.txt", "Unpin"],
  ] as const) {
    files.insert(key, Entry({ title, mark }));
  }
  return { status };
});

app.run();
