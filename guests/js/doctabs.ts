// The document-tabs scene (tools/scenes/doctabs.steps; docs/doctabs-plan.md
// §5): three documents, one of them armed against a close, a shared region
// beside them, the "+", and a programmatic select that echoes nothing.

import * as kaya from "kaya-gui";

const app = new kaya.App();

const A = 10;
const B = 11;
const C = 12;
const NOTES = 30;
const NAMES = new Map([[A, "a"], [B, "b"], [C, "c"]]);

let untitled = 0;
let regions = 0;

// THE ONE BUILDER every window's shared region comes from, the first
// window's and a torn-out one's alike (docs/doctabs-plan.md §1.2).
function notes(window: number, region: number): void {
  app.addRegion(region, "leading", { window }, () => {
    kaya.column(() => {
      kaya.label({ bind: status }).a11yId("status");
      kaya.entry().a11yId("note");
      kaya.button("to a", { onClick: () => kaya.selectDocument(A) }).a11yId("first");
    });
  });
}

function mark(): void {
  kaya.setDocumentProp(B, "dirty", true);
  status.set("marked b");
}

async function askClose(): Promise<void> {
  const choice = await kaya.showAlert({
    title: "unsaved changes",
    message: "b has unsaved changes",
    actions: ["Discard"],
    cancel: "Keep Editing",
  });
  if (choice === "cancel") {
    status.set("kept b");
  } else {
    kaya.closeDocument(B);
    status.set("discarded b");
  }
}

function newDocument(): void {
  untitled += 1;
  const name = `untitled ${untitled}`;
  app.addDocument(100 + untitled, { title: name }, () => {
    const caption = kaya.signal(`${name} body`);
    kaya.column(() => {
      kaya.label({ bind: caption });
    });
  });
  kaya.selectDocument(100 + untitled);
  status.set(`new ${name}`);
}

function detached(window: number, documents: number[]): void {
  regions += 1;
  notes(window, 300 + regions);
  status.set(`detached ${documents.map((d) => NAMES.get(d) ?? "untitled").join(" ")}`);
}

const { status } = app.window(
  {
    title: "doctabs", width: 640, height: 420, newDocument: true,
    onNewDocument: newDocument,
    onDocumentsCloseRequested: (documents) => status.set(`asked about ${documents.length}`),
    onDocumentsDetached: detached,
  },
  () => ({ status: kaya.signal("ready") }),
);

for (const [id, name] of NAMES) {
  app.addDocument(id, {
    title: name, tooltip: `/documents/${name}`, interceptClose: id === B,
    onSelected: () => status.set(`selected ${name}`),
    onClosed: () => status.set(`closed ${name}`),
    ...(id === B ? { onCloseRequested: askClose } : {}),
    onMoved: (_window, index) => status.set(`moved ${name} to ${index}`),
  }, () => {
    const caption = kaya.signal(`${name} body`);
    kaya.column(() => {
      kaya.label({ bind: caption }).a11yId(`body-${name}`);
      kaya.entry().a11yId(`field-${name}`);
      if (id === B) kaya.button("mark b", { onClick: mark }).a11yId("mark");
    });
  });
}

app.build(() => notes(0, NOTES));

app.run();
