// The sheet scene (tools/scenes/sheet.steps; docs/sheet-plan.md §6): a
// sheet opened from a button and closed through the platform's cancel
// path, the same sheet with the dismiss veto armed, a child sheet chained
// over it, and a programmatic dismiss that echoes nothing.

import * as kaya from "kaya-gui";

const app = new kaya.App();

const TASK = 11;
const DETAILS = 12;

function onDraft(text: string): void {
  draft.set(`draft: ${text}`);
}

function dismissed(): void {
  status.set("dismissed");
}

function dismissAsked(): void {
  // Nothing has gone; the app keeps the sheet up and says so.
  status.set("dismiss requested");
}

function detailsDismissed(): void {
  status.set("details dismissed");
}

function openDetails(): void {
  app.sheet(DETAILS, { title: "details", parent: TASK, onDismissed: detailsDismissed }, () => {
    const caption = kaya.signal("more about it");
    kaya.column(() => {
      kaya.label({ bind: caption }); // the newest label
    });
  });
  status.set("details open");
}

function done(): void {
  // Programmatic: no sheet_dismissed follows, so "done" stays.
  kaya.dismissSheet(TASK);
  status.set("done");
}

function openTask(armed: boolean): void {
  const opts: kaya.SheetOptions = {
    title: "new task",
    detent: "medium",
    interceptDismiss: armed,
    onDismissed: dismissed,
  };
  if (armed) opts.onDismissRequested = dismissAsked;
  app.sheet(TASK, opts, () => {
    const caption = kaya.signal("what needs doing?");
    kaya.column(() => {
      kaya.label({ bind: caption }); // label#1
      kaya.entry({ onChange: onDraft }); // entry#0
      kaya.label({ bind: draft }); // label#2
      kaya.button("details", { onClick: openDetails }); // button#2
      kaya.button("done", { onClick: done }); // button#3
    });
  });
  status.set("open");
  draft.set("draft: none");
}

const { status, draft } = app.window({ title: "sheet" }, () => {
  const status = kaya.signal("closed");
  const draft = kaya.signal("draft: none");
  kaya.column(() => {
    kaya.label({ bind: status }); // label#0
    kaya.button("new task", { onClick: () => openTask(false) }); // button#0
    kaya.button("new task, armed", { onClick: () => openTask(true) }); // button#1
  });
  return { status, draft };
});

app.run();
