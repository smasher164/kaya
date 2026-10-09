// The expander scene (tools/scenes/expander.steps; docs/expander-plan.md §5).

import * as kaya from "kaya-gui";

const Section = kaya.record({ name: String, open: Boolean }, "Section");

const app = new kaya.App();
let heard = 0;
const opens = new Map<string, boolean>([["s01", true]]);

function word(open: boolean): string {
  return open ? "open" : "closed";
}

function onDetails(open: boolean): void {
  heard += 1;
  state.set(`details: ${word(open)}`);
  heardText.set(`heard: ${heard}`);
}

function onTyped(text: string): void {
  typed.set(`name: ${text}`);
}

function onShow(open: boolean): void {
  details.expanded(open);
  state.set(`details: ${word(open)}`);
}

function onSection(sec: kaya.RowHandle<kaya.Fields<typeof Section.schema>>, open: boolean): void {
  const key = String(sec.key);
  opens.set(key, open);
  sec.open = open;
  rowsText.set(`sec ${key}: ${word(open)}`);
}

function onRebuild(): void {
  sections.remove("s00");
  sections.insert("s00", Section({ name: "Section 0", open: opens.get("s00") ?? false }));
  rowsText.set("rebuilt s00");
}

const { state, heardText, typed, rowsText, details, sections } = app.window({ title: "expander", width: 520, height: 860 }, () => {
  const state = kaya.signal("details: closed");
  const heardText = kaya.signal("heard: 0");
  const typed = kaya.signal("name: -");
  const rowsText = kaya.signal("rows: -");
  const inside = kaya.signal("Inside the body");
  const sections = kaya.collection(Section);
  const details = kaya.column(() => {
    const details = kaya.expander("Details", { summary: "One field", symbol: kaya.Symbol.INFO, onToggle: onDetails }, (details) => {
      details.a11yId("details");
      kaya.entry({ placeholder: "Name", onChange: onTyped }).a11yId("name");
      kaya.label({ bind: inside }).a11yId("inside");
      return details;
    });
    kaya.label({ bind: state }).a11yId("state");
    kaya.label({ bind: heardText }).a11yId("heard");
    kaya.label({ bind: typed }).a11yId("typed");
    kaya.row(() => {
      kaya.button("Show", { onClick: () => onShow(true) }).a11yId("show");
      kaya.button("Hide", { onClick: () => onShow(false) }).a11yId("hide");
    });
    kaya.column((form) => {
      form.a11yId("form");
      kaya.labeled("Sort", () => {
        kaya.select(["Due", "Name"]).a11yId("sort");
      });
      kaya.expander("Advanced", (advanced) => {
        advanced.a11yId("advanced");
        kaya.labeled("Hide badge", () => {
          kaya.checkbox("").a11yId("badge");
        });
        kaya.labeled("Keep completed", () => {
          kaya.checkbox("").a11yId("keep");
        });
      });
    });
    kaya.label({ bind: rowsText }).a11yId("rows");
    kaya.button("Rebuild", { onClick: onRebuild }).a11yId("rebuild");
    kaya.column(() => {
      for (const sec of sections) {
        kaya.expander(sec.name, { expanded: sec.open, onToggle: onSection }, (node) => {
          node.a11yId("sec");
          kaya.label({ bind: sec.name });
        });
      }
    });
    return details;
  });
  for (let i = 0; i < 3; i++) {
    sections.insert(`s0${i}`, Section({ name: `Section ${i}`, open: i === 1 }));
  }
  return { state, heardText, typed, rowsText, details, sections };
});

app.run();
