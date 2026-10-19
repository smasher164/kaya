// The grounds scene (tools/scenes/grounds.steps; docs/styling-pass-plan.md
// Y2, Y3): an artist header covered by the picture with the name on the
// platform's panel, at the top of a window giving no inset (on a phone it runs
// under the status bar, docs/media-player-plan.md M15), an album header fading
// from the art's own colour into the page, and a column with no ground. See guests/rust/grounds.rs.

import * as kaya from "kaya-gui";

const app = new kaya.App();
const art = kaya.asset("covers/cover-600.jpg").bytes();
const colour = kaya.imageDominant(art);
if (colour === null) throw new Error("the cover decodes");

app.window({ title: "grounds", width: 480, height: 560, inset: 0 }, () => {
  kaya.column({ spacing: 12 }, () => {
    kaya.column({ inset: 24, groundImage: art }, (hero) => {
      hero.a11yId("hero");
      kaya.row({ filled: "overlay" }, (scrim) => {
        scrim.a11yId("scrim");
        kaya.label("Miles Davis");
      });
    });
    kaya.column({ inset: 24, groundGradient: colour }, (header) => {
      header.a11yId("header");
      kaya.heading("Kind of Blue").a11yId("title");
      kaya.caption("Miles Davis · 1959");
    });
    kaya.column({ inset: 24 }, (plain) => {
      plain.a11yId("plain");
      kaya.label("Plain");
    });
  });
});

app.run();
