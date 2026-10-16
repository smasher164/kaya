// The cards scene (tools/scenes/cards.steps; docs/styling-pass-plan.md Y4): a
// grid of cards that each take a click as a whole and show the platform's
// hover, and a library list whose rows the app selects on activation. See
// guests/rust/cards.rs.

import * as kaya from "kaya-gui";

const Playlist = kaya.record({ name: String, selected: Boolean }, "Playlist");

const CARDS = [["card1", "Daily Mix 1"], ["card2", "Daily Mix 2"], ["card3", "Discover Weekly"]] as const;
const LIBRARY = [["p1", "Liked Songs"], ["p2", "Late Night Jazz"], ["p3", "Focus"]] as const;

const app = new kaya.App();

function onOpen(row: kaya.RowHandle<kaya.Fields<typeof Playlist.schema>>): void {
  for (const [key] of LIBRARY) library.patch(key, { selected: key === row.key });
}

const { status, library } = app.window({ title: "cards", width: 520, height: 520 }, () => {
  const status = kaya.signal("opened: none");
  const library = kaya.collection(Playlist);
  kaya.column({ spacing: 16 }, () => {
    kaya.grid(3, { spacing: 12 }, () => {
      for (const [key, name] of CARDS) {
        kaya.column({ filled: "neutral", onActivate: () => status.set(`opened: ${name}`) }, (card) => {
          card.a11yId(key);
          kaya.label(name);
          kaya.caption("Made for you");
        });
      }
    });
    kaya.label({ bind: status }).a11yId("status");
    for (const playlist of library) {
      kaya.row({ selected: playlist.selected, onActivate: onOpen }, (item) => {
        item.a11yId("lib");
        kaya.label({ bind: playlist.name });
      });
    }
  });
  for (const [key, name] of LIBRARY) library.insert(key, Playlist({ name, selected: false }));
  return { status, library };
});

app.run();
