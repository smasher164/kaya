// The menus conformance scene (tools/scenes/menus.steps). Canonical
// semantics in guests/rust/menus.rs.

import * as kaya from "kaya-gui";

const Task = kaya.record({ title: String }, "Task");

const app = new kaya.App();

function onEnableExport(): void {
  canExport.set(true);
}

function onDetails(on: boolean): void {
  status.set(on ? "details on" : "details off");
}

function onSorted(index: number): void {
  status.set(index === 1 ? "sorted date" : "sorted name");
}

function onSave(): void {
  status.set("saved");
}

function onShare(): void {
  status.set("shared");
}

function onReset(): void {
  // The folds never echo, so these reset the user-state mirror.
  details.set(false);
  sort.set(0);
  status.set("ready");
}

function onRename(): void {
  status.set("renamed");
}

function onRemove(group: kaya.Key, item: kaya.Key): void {
  items.at(group).remove(item);
  status.set(`removed ${group}/${item}`);
}

function onRework(): void {
  share.primary(false);
  file.label("Document");
  file.append(() => {
    kaya.item("Publish", { primary: true, symbol: kaya.Symbol.COPY, onActivate: onShare });
  });
  app.menu("Tools", () => {
    kaya.item("Inspect", { symbol: kaya.Symbol.SEARCH });
  });
}

let status!: kaya.Signal<string>;
let canExport!: kaya.Signal<boolean>;
let details!: kaya.Signal<boolean>;
let sort!: kaya.Signal<number>;
let file!: kaya.MenuItem;
let share!: kaya.MenuItem;
let items!: kaya.Collection<kaya.Fields<typeof Task.schema>, kaya.Row<typeof Task.schema>>;
let groups!: kaya.Collection<string, kaya.Element>;

app.window({ title: "menus" }, () => {
  status = kaya.signal("ready");
  canExport = kaya.signal(false);
  details = kaya.signal(false);
  sort = kaya.signal(0);

  file = app.menu("File", { enabled: canExport }, () => {
    // The vocabulary has no `save` glyph, so `done` is the spelling.
    kaya.item("Save", { symbol: kaya.Symbol.DONE, shortcut: "primary+s", onActivate: onSave });
    kaya.item("Export", { enabled: canExport, symbol: kaya.Symbol.FORWARD });
    share = kaya.item("Share", { primary: true, onActivate: onShare });
  });

  app.menu("View", () => {
    kaya.toggle("Details", { checked: details, symbol: kaya.Symbol.INFO, onToggle: onDetails });
  });

  // Option order IS the index.
  app.radioGroup("Sort", { value: sort, onSelect: onSorted }, () => {
    kaya.option("Name");
    kaya.option("Date");
  });

  groups = kaya.collection();
  const catalog = kaya.contextCatalog(() => {
    kaya.item("Remove", { symbol: kaya.Symbol.DELETE, onActivate: onRemove });
  });

  kaya.column(() => {
    kaya.label({ bind: status }); // label#0
    kaya.button("enable export", { onClick: onEnableExport }); // button#0
    kaya.button("reset menu state", { onClick: onReset }); // button#1
    kaya.button("extend menus", { onClick: onRework }); // button#2

    const targetText = kaya.signal("rename target");
    const target = kaya.label({ bind: targetText }); // label#1
    target.contextMenu(() => {
      kaya.item("Rename", { symbol: kaya.Symbol.EDIT, onActivate: onRename });
    });

    for (const _g of groups) {
      kaya.column(() => {
        items = kaya.collection(Task);
        for (const task of items) {
          const row = kaya.label({ bind: task.title }); // label#2 once g2/a stamps
          row.contextMenu(catalog);
        }
      });
    }
  });
});

// Seed after mount: the stamp path attaches the shared catalog and keys.
app.build(() => {
  groups.insert("g2", "Home");
  items.at("g2").insert("a", Task({ title: "water plants" }));
});

app.run();
