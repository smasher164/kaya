// The drag-and-drop scene: THE ROOT IS A ROW, so column#0 is the
// reorderable For's container (tools/scenes/dnd.steps, docs/dnd-plan.md D1, D8).
//     KAYA_SELFTEST=dnd node guests/js/dnd.ts

import { mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import * as kaya from "kaya-gui";

const Item = kaya.record({ title: String }, "Item");

const app = new kaya.App();

const NOTE_ID = "dev.kaya/note";

// The file the scene drops as a FOREIGN source (D6), written by the guest
// at $TMP/kaya-dnd-$PID/dropped.txt — the picker and clipboard scenes'
// convention.
const droppedDir = join(tmpdir(), `kaya-dnd-${process.pid}`);
mkdirSync(droppedDir, { recursive: true });
writeFileSync(join(droppedDir, "dropped.txt"), "dropped bytes", { encoding: "utf-8" });

function readBack(file: kaya.PickedFile): string {
  try {
    // The addon reads over the platform handle (docs/js-plan.md §6).
    return new TextDecoder().decode(file.read());
  } catch (e) {
    return `open failed: ${e instanceof Error ? e.message : String(e)}`;
  }
}

function onDropped(name: string, target: kaya.Signal<string>, d: kaya.Dropped): void {
  const op = d.operation ?? "none";
  if (d.clip instanceof kaya.Representation.Text) {
    dropStatus.set(`${name} got text ${d.clip.text} (${op})`);
    target.set(d.clip.text);
  } else if (d.clip instanceof kaya.Representation.Custom) {
    dropStatus.set(`${name} got ${d.clip.id} ${d.clip.bytes.length} bytes (${op})`);
  } else if (d.clip instanceof kaya.Representation.Files) {
    // A dropped file IS a picked file (D6): read it back through the same
    // table the picker fills.
    const said = d.clip.files.map((f) => `${f.name} ${readBack(f)}`).join(", ");
    dropStatus.set(`${name} got ${said} (${op})`);
  } else {
    dropStatus.set(`${name} got other (${op})`);
  }
  // A same-app MOVE removes its original in the same batch (D2).
  if (d.operation === kaya.OP_MOVE) {
    sourceText.set("moved out");
    source.draggable();
  }
}

function onDragEnded(op: string | null): void {
  dragStatus.set(`drag ended ${op ?? "none"}`);
}

// A stamped handler receives the ROW, not the key (docs/js-plan.md §4).
function onItemDropped(row: kaya.RowHandle<string>, d: kaya.Dropped): void {
  const op = d.operation ?? "none";
  if (d.clip instanceof kaya.Representation.Text) {
    dropStatus.set(`item ${row.key} got text ${d.clip.text} (${op})`);
  } else {
    dropStatus.set(`item ${row.key} got other (${op})`);
  }
}

function nodeDragEnded(what: string): (row: kaya.RowHandle<string>, op: string | null) => void {
  return (row, op) => {
    dragStatus.set(`${what} ${row.key} drag ended ${op ?? "none"}`);
  };
}

function onReorder(d: kaya.Dropped): void {
  // The moved row's key rides as the kaya-private custom representation;
  // the anchor is the row it landed on (D8).
  if (!(d.clip instanceof kaya.Representation.Custom)) return;
  const moved = new TextDecoder().decode(d.clip.bytes);
  const anchor = d.anchor[0];
  if (anchor === undefined) return;
  if (d.before) items.moveBefore(moved, anchor as kaya.Key);
  else items.moveAfter(moved, anchor as kaya.Key);
}

let items!: kaya.Collection<kaya.Fields<typeof Item.schema>, kaya.Row<typeof Item.schema>>;
let source!: kaya.Widget;
let dropStatus!: kaya.Signal<string>;
let dragStatus!: kaya.Signal<string>;
let sourceText!: kaya.Signal<string>;

app.window({ title: "dnd" }, () => {
  items = kaya.collection(Item);
  const items2 = kaya.collection(Item);
  dropStatus = kaya.signal("no drop yet");
  dragStatus = kaya.signal("no drag yet");
  sourceText = kaya.signal("hello");
  const textTarget = kaya.signal("text target");
  const noteTarget = kaya.signal("note target");
  const filesTarget = kaya.signal("files target");
  kaya.row(() => {
    for (const item of items.rows({ reorderable: true, onDrop: onReorder, a11yId: "rows" })) {
      kaya.label({ bind: item.title }).a11yId("row").onDragEnded(nodeDragEnded("row"));
    }
    kaya.column(() => {
      source = kaya.label({ bind: sourceText }); // label#0
      source
        .draggable({ text: "hello", custom: { [NOTE_ID]: new TextEncoder().encode("note!") }, operations: [kaya.OP_COPY, kaya.OP_MOVE] })
        .onDragEnded(onDragEnded);
      kaya
        .label({ bind: textTarget }) // label#1
        .accepts(kaya.ACCEPT_TEXT)
        .dropTarget(kaya.OP_COPY)
        .onDrop((d: kaya.Dropped) => onDropped("text target", textTarget, d));
      kaya
        .label({ bind: noteTarget }) // label#2
        .accepts(NOTE_ID)
        .dropTarget(kaya.OP_COPY, kaya.OP_MOVE)
        .onDrop((d: kaya.Dropped) => onDropped("note target", noteTarget, d));
      kaya
        .label({ bind: filesTarget }) // label#3
        .accepts(kaya.ACCEPT_FILES)
        .dropTarget(kaya.OP_COPY)
        .onDrop((d: kaya.Dropped) => onDropped("files target", filesTarget, d));
      kaya.label({ bind: dropStatus }); // label#4
      kaya.label({ bind: dragStatus }); // label#5
    });
    // THE TEMPLATE ZONE (docs/dnd-plan.md §4): every stamped item is a
    // text destination, and its payload IS the row's own field —
    // resolved per copy and re-declared when the field changes.
    for (const item of items2.rows({ a11yId: "items" })) {
      kaya
        .label({ bind: item.title })
        .a11yId("item")
        .accepts(kaya.ACCEPT_TEXT)
        .dropTarget(kaya.OP_COPY)
        .draggable({ text: item.title, operations: [kaya.OP_COPY] })
        .onDrop(onItemDropped)
        .onDragEnded(nodeDragEnded("item"));
    }
    // The bound payload follows the row's record (§4).
    kaya.button("rename y", { onClick: () => items2.update("y", Item({ title: "yy" })) }); // button#0
  });
  for (const key of ["a", "b", "c"]) {
    items.insert(key, Item({ title: key }));
  }
  for (const key of ["x", "y"]) {
    items2.insert(key, Item({ title: key }));
  }
});

app.run();
