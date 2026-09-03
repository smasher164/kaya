// The sections conformance scene (tools/scenes/sections.steps): two peer
// roots in the primary window's section set.

import * as kaya from "kaya-gui";

const app = new kaya.App();

const FEED = 7;
const ARCHIVE = 8;
const LIBRARY = 1;
const SHELVES = 2;
const LOANS = 3;

let visitCount = 0;

function archiveShown(): void {
  visitCount += 1;
  visits.set(`archive: ${visitCount} visits`);
}

function goArchive(): void {
  kaya.selectSection(ARCHIVE);
}

function openLibrary(): void {
  // An aux window, reached only by the desktop tail's click, so the phones
  // never see a createWindow their host rejects.
  kaya.createWindow(LIBRARY);
  app.window({
    windowId: LIBRARY, title: "library",
    sectionsPresentation: kaya.SECTIONS_SIDEBAR,
  });
  app.addSection(SHELVES, { title: "Shelves", symbol: kaya.Symbol.SEARCH, window: LIBRARY }, () => {
    const shelvesReady = kaya.signal("shelves ready");
    kaya.column(() => {
      kaya.label({ bind: shelvesReady }); // label#2
    });
  });
  app.addSection(LOANS, { title: "Loans", symbol: kaya.Symbol.LOCK, window: LIBRARY }, () => {
    const loansReady = kaya.signal("loans ready");
    kaya.column(() => {
      kaya.label({ bind: loansReady }); // label#3
    });
  });
}

let visits!: kaya.Signal<string>;

// With sections the window has no root: NOTHING MOUNTS here.
app.window({ title: "sections", sectionsPresentation: kaya.SECTIONS_BAR }, () => {
  visits = kaya.signal("archive: 0 visits");
});

// SF Symbols are licensed to Apple platforms: no shared asset exists.
app.addSection(FEED, { title: "Feed", symbol: kaya.Symbol.HOME }, () => {
  const ready = kaya.signal("feed ready");
  kaya.column(() => {
    kaya.label({ bind: ready }); // label#0
    kaya.button("to archive", { onClick: goArchive }); // button#0
    kaya.button("open library", { onClick: openLibrary }); // button#1
  });
});

app.addSection(ARCHIVE, { title: "Archive", symbol: kaya.Symbol.STAR, onSelected: archiveShown }, () => {
  kaya.column(() => {
    kaya.label({ bind: visits }); // label#1
  });
});

app.run();
