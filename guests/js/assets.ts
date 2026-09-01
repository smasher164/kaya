// The assets conformance scene, JS port (docs/assets-plan.md, ratified
// 2026-08-18). The byte-frozen contract is tools/scenes/assets.steps.
//
// THIS ONE PROVES THE BYTES. `asset(name)` has two redemptions and the
// typeface scene already covers the other: a font whose bytes go from the
// core's read straight to the platform and never touch JS. Here the guest
// IS the consumer — it copies the mark out with `bytes()` and hands them
// to an Image, and the platform's own decoder answers 64x64 off the real
// view.
//
// THE MISS IS A QUESTION, NOT A `try`. `assetMissSentence` answers the
// same sentence a miss would throw, without throwing, and that is the
// only shape all nine share — the C floor catches nothing at all
// (docs/deferred.md, the assets entry).
//
// LINE 1 ONLY. The sentence's second line names the place the core
// resolved and the route that chose it, which a bundle, a device
// directory and a repo checkout spell three different ways; the first
// line is the same everywhere, so it is the one a scene can freeze.

import * as kaya from "kaya-gui";

// The asset that is deliberately not there. A LEGAL name — relative,
// `/`-spelled, one component deep — so what comes back is the census
// sentence and not a name-fault one.
const MISSING = "icons/nope.png";

// The one the mark is under, and the one the census must list.
const MARK = "icons/kaya-mark.png";

// The large asset: 111400 bytes, so a reader that truncated into a fixed
// buffer shows up here rather than passing quietly.
const FONT = "fonts/sora-wght.ttf";

const app = new kaya.App();

/** The census half. Empty in, empty out. */
function firstLine(sentence: string): string {
  return sentence.split("\n")[0] ?? "";
}

app.window({ title: "assets", width: 480, height: 360 }, () => {
  const mark = kaya.asset(MARK);
  const font = kaya.asset(FONT);
  try {
    const census = firstLine(kaya.assetMissSentence(MISSING));

    const complaint = kaya.assetMissSentence(FONT);
    let verdict: string;
    if (complaint) {
      // Never reached on a healthy lane, and it shows the sentence
      // rather than a word about it: a failure here has to say what was
      // measured.
      verdict = firstLine(complaint);
    } else {
      verdict = "no complaint";
    }

    kaya.column(() => {
      kaya.label("assets"); // label#0
      // THE BYTES, not the blob handle: this scene is the consumer, so
      // what reaches the decoder is what `bytes()` handed back.
      kaya.image(mark.bytes()); // image#0
      kaya.label(census); // label#1
      // `font.length` is the core's byte count, and JS renders a number
      // with no separator and no padding anywhere.
      kaya.label(`${FONT}: ${font.length} bytes, ${verdict}`); // label#2
    });
  } finally {
    font.close();
    mark.close();
  }
});

app.run();
