// The drag-and-drop scene: THE ROOT IS A ROW, so column#0 is the
// reorderable For's container (tools/scenes/dnd.steps, docs/dnd-plan.md D1, D8).
//     KAYA_SELFTEST=dnd node guests/js/dnd.ts

import * as kaya from "kaya-gui";

const Item = kaya.record({ title: String }, "Item");

const app = new kaya.App();

const NOTE_ID = "dev.kaya/note";

function onDropped(name: string, target: kaya.Signal<string>, d: kaya.Dropped): void {
  const op = d.operation ?? "none";
  if (d.clip instanceof kaya.Representation.Text) {
    dropStatus.set(`${name} got text ${d.clip.text} (${op})`);
    target.set(d.clip.text);
  } else if (d.clip instanceof kaya.Representation.Custom) {
    dropStatus.set(`${name} got ${d.clip.id} ${d.clip.bytes.length} bytes (${op})`);
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
  dropStatus = kaya.signal("no drop yet");
  dragStatus = kaya.signal("no drag yet");
  sourceText = kaya.signal("hello");
  const textTarget = kaya.signal("text target");
  const noteTarget = kaya.signal("note target");
  const filesTarget = kaya.signal("files target");
  kaya.row(() => {
    for (const item of items.rows({ reorderable: true, onDrop: onReorder })) {
      kaya.label({ bind: item.title }).a11yId("row");
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
        .dropTarget(kaya.OP_COPY);
      kaya.label({ bind: dropStatus }); // label#4
      kaya.label({ bind: dragStatus }); // label#5
    });
  });
  for (const key of ["a", "b", "c"]) {
    items.insert(key, Item({ title: key }));
  }
});

app.run();
