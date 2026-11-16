// The layers scene (tools/scenes/layers.steps; docs/layering-plan.md LY13): a
// cover with a badge, a caption on the fade form and a button over it; a
// button with a badge at its trailing end; a button under a veil, an unfilled
// column spanning it with a panel at its centre, that takes its taps until it
// is hidden; a cover with the flat overlay panel; and the log of which handler
// answered each tap. See guests/rust/layers.rs.

import * as kaya from "kaya-gui";

const app = new kaya.App();
const log = ["taps:"];
function answer(word: string): void {
  log.push(word);
  answered.set(log.join(" "));
  if (word === "hide") veiled.set(true);
}

const { answered, veiled } = app.window({ title: "layers", width: 480, height: 860 }, () => {
  const answered = kaya.signal("taps:");
  const veiled = kaya.signal(false);
  kaya.column({ spacing: 16 }, () => {
    kaya.layers({ inset: 8 }, (stack) => {
      stack.a11yId("photostack");
      kaya.image(kaya.asset("covers/cover-600.jpg")).maxWidth(320).a11yLabel("Kind of Blue cover").a11yId("photo");
      kaya.row({ filled: "accent" }, (badge) => {
        badge.place("top_trailing").a11yId("badge");
        kaya.label("3").a11yId("badge_text");
      });
      kaya.row({ filled: "overlay_fade" }, (caption) => {
        caption.place("bottom").a11yId("caption");
        kaya.label("Kind of Blue").a11yId("caption_text");
      });
      kaya.button("Share", { onClick: () => answer("share") }).place(kaya.Place.BOTTOM_TRAILING).a11yId("share");
    });
    kaya.layers((stack) => {
      stack.a11yId("veilstack");
      kaya.button("Press the base button here", { onClick: () => answer("base") }).a11yId("base");
      kaya.column({ align: "center" }, (veil) => {
        veil.fill(true).hidden(veiled).a11yId("busy");
        kaya.row({ filled: "overlay" }, () => {
          kaya.label("Busy");
        });
      });
    });
    kaya.layers((stack) => {
      stack.a11yId("sidestack");
      kaya.button("Open the inbox", { onClick: () => answer("side") }).a11yId("side");
      kaya.row({ filled: "accent" }, (sideBadge) => {
        sideBadge.place("trailing").a11yId("sidebadge");
        kaya.label("5");
      });
    });
    kaya.layers({ inset: 8 }, (stack) => {
      stack.a11yId("flatstack");
      kaya.image(kaya.asset("covers/cover-320.jpg")).maxWidth(200).a11yLabel("Small cover").a11yId("smallphoto");
      kaya.row({ filled: "overlay" }, (flat) => {
        flat.place("top_leading").a11yId("flat");
        kaya.label("Flat panel").a11yId("flat_text");
      });
    });
    kaya.label({ bind: answered }).a11yId("answered");
    kaya.button("Hide the veil", { onClick: () => answer("hide") }).a11yId("hideveil");
  });
  return { answered, veiled };
});

app.run();
