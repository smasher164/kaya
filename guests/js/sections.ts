// The sections conformance scene, JS port: two peer roots in the primary
// window's section set — presentation context, not lifecycle. The archive
// pane folds onSelected into a visit count, pinning the echo doctrine
// from both sides: the user's switch emits (the harness drives the real
// switcher), while the feed button's programmatic kaya.selectSection
// moves the selection silently. The count surviving switch round trips
// proves retention. See guests/rust/sections.rs and
// tools/scenes/sections.steps.

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
  // THE SIDEBAR HALF of the presentation enum, in an aux window, so one
  // shared scene covers BOTH arms. Reachability is the gate: only the
  // desktop tail's click lands here, so the phones never see a
  // createWindow their host would reject.
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

// With sections the window has no root of its own — the switcher IS the
// window content — so this body carries only props and the shared signal,
// and NOTHING MOUNTS. The presentation hint is ADVISORY.
app.window({ title: "sections", sectionsPresentation: kaya.SECTIONS_BAR }, () => {
  visits = kaya.signal("archive: 0 visits");
});

// The symbol is SEMANTIC, never an asset (docs/styling-plan.md D6): the
// glyph meaning `home` differs per platform, and SF Symbols are licensed
// to Apple platforms only.
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
