// The assets conformance scene (tools/scenes/assets.steps). THE MISS IS A
// QUESTION, NOT A `try`, and LINE 1 ONLY: line 2 differs per host.

import * as kaya from "kaya-gui";

// Absent, and deliberately LEGAL, so the miss is the census sentence.
const MISSING = "icons/nope.png";

const MARK = "icons/kaya-mark.png";

// 111400 bytes: a reader that truncated into a fixed buffer shows here.
const FONT = "fonts/sora-wght.ttf";

const app = new kaya.App();

/** The census half of the sentence. */
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
      // Shows the sentence: a failure must say what was measured.
      verdict = firstLine(complaint);
    } else {
      verdict = "no complaint";
    }

    kaya.column(() => {
      kaya.label("assets"); // label#0
      // THE BYTES, not the blob handle.
      kaya.image(mark.bytes()); // image#0
      kaya.label(census); // label#1
      // A number renders with no separator and no padding, everywhere.
      kaya.label(`${FONT}: ${font.length} bytes, ${verdict}`); // label#2
    });
  } finally {
    font.close();
    mark.close();
  }
});

app.run();
