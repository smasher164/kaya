// The cards scene (tools/scenes/cards.steps; docs/styling-pass-plan.md Y4): a
// grid of cards that each take a click as a whole and show the platform's
// hover, a library list whose rows the app selects on activation and whose
// play buttons take their symbol from the row, and a card the app adds to the
// built grid (docs/media-player-plan.md M16). See guests/rust/cards.rs.

import * as kaya from "kaya-gui";

const Playlist = kaya.record({ name: String, selected: Boolean, symbol: kaya.Symbol }, "Playlist");

const CARDS = [["card1", "Daily Mix 1"], ["card2", "Daily Mix 2"], ["card3", "Discover Weekly"]] as const;
// The third card is taller, so the row's cards take its height (M16 (1)).
const TALL = "card3";
// Cut at two lines with the platform's ellipsis (M16 (2)).
const BLURB = "Fresh picks every Monday, from the artists you play the most and the ones they listen to";
const LIBRARY = [["p1", "Liked Songs"], ["p2", "Late Night Jazz"], ["p3", "Focus"]] as const;

const app = new kaya.App();

type Row = kaya.RowHandle<kaya.Fields<typeof Playlist.schema>>;

function onOpen(row: Row): void {
  for (const [key] of LIBRARY) library.patch(key, { selected: key === row.key });
}

function onPlay(row: Row): void {
  for (const [key] of LIBRARY) library.patch(key, { symbol: key === row.key ? kaya.Symbol.PAUSE : kaya.Symbol.PLAY });
}

function card(key: string, name: string): void {
  kaya.column({ filled: "neutral", onActivate: () => status.set(`opened: ${name}`) }, (handle) => {
    handle.a11yId(key);
    kaya.label(name);
    kaya.caption("Made for you");
    if (key === TALL) kaya.caption(BLURB, { maxLines: 2 }).a11yId("blurb");
  });
}

const { status, library } = app.window({ title: "cards", width: 520, height: 520 }, () => {
  const status = kaya.signal("opened: none");
  const library = kaya.collection(Playlist);
  // A section hidden by a When and an empty For take no space (M16 (3)).
  const hidden = kaya.signal(false);
  const empty = kaya.collection(Playlist);
  let cards!: kaya.Widget;
  kaya.column({ spacing: 16 }, () => {
    kaya.grid(1, { spacing: 12 }, (grid) => {
      cards = grid;
      for (const [key, name] of CARDS) card(key, name);
    });
    cards.columnsAuto(140).a11yId("cards");
    kaya.button("More", { onClick: () => kaya.within(cards, () => card("card4", "Release Radar")) }).a11yId("more");
    kaya.label({ bind: status }).a11yId("status");
    kaya.when(hidden, () => {
      kaya.label("never shown");
    });
    for (const playlist of empty) {
      kaya.row(() => {
        kaya.label({ bind: playlist.name });
      });
    }
    kaya.label("end").a11yId("end");
    for (const playlist of library) {
      kaya.row(() => {
        kaya.row({ selected: playlist.selected, onActivate: onOpen }, (item) => {
          item.a11yId("lib");
          kaya.label({ bind: playlist.name });
        });
        kaya.button("Play", { symbol: playlist.symbol, onClick: onPlay }).a11yId("go");
      });
    }
  });
  for (const [key, name] of LIBRARY) library.insert(key, Playlist({ name, selected: false, symbol: kaya.Symbol.PLAY }));
  return { status, library };
});

app.run();
