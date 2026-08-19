//! The assets conformance scene (docs/assets-plan.md, ratified
//! 2026-08-18). The byte-frozen contract is tools/scenes/assets.steps.
//!
//! THE BYTES REDEMPTION, THROUGH A REAL SURFACE. `asset(name)` has two
//! redemptions and the typeface scene already proves the other one: a
//! font handed to kaya whose bytes never enter the guest. This scene is
//! the one that proves `bytes()` — the guest IS the consumer here, it
//! hands the vendored mark's bytes to an Image, and the platform's own
//! decoder answers 64x64 off the real view. A truncation, a wrong file
//! or a resolution rule that found the wrong root cannot survive that.
//!
//! AND THE MISS, WITHOUT UNWINDING. The sentence a miss raises is also
//! readable as a total query, and that is the only shape all nine share
//! — the C floor catches nothing at all (docs/deferred.md, the assets
//! entry).
//!
//! LINE 1 ONLY. The sentence is two lines on purpose: the first names
//! the asset, the rule and the CENSUS of what the package carries, and
//! is the same on five platforms; the second names the resolved place
//! and the route that chose it, which a bundle, a device directory and
//! a repo checkout spell three different ways. A cross-platform
//! expectation can hold the first and never the second.

/// The asset that is deliberately not there. A name that is LEGAL —
/// relative, `/`-spelled, one component deep — so the sentence under
/// test is the census one and not a name-fault one.
const MISSING: &str = "icons/nope.png";

/// The one the mark is under, and the one the census must list.
const MARK: &str = "icons/kaya-mark.png";

/// The large asset: 111400 bytes, so a reader that truncated into a
/// fixed buffer is visible here rather than passing quietly.
const FONT: &str = "fonts/sora-wght.ttf";

pub(crate) fn app(ctx: kaya::AppCtx) {
    ctx.apply(|tx| {
        tx.window(kaya::DEFAULT_WINDOW).title("assets").size(480.0, 360.0);

        let mark = tx.asset(MARK);
        let font = tx.asset(FONT);

        let miss = tx.asset_miss_sentence(MISSING);
        let first = miss.lines().next().unwrap_or("").to_owned();
        let complaint = tx.asset_miss_sentence(FONT);
        let verdict = if complaint.is_empty() {
            "no complaint".to_owned()
        } else {
            // Never reached on a healthy lane, and it prints the
            // sentence rather than a word about it: a failure here has
            // to say what was measured.
            complaint.lines().next().unwrap_or("").to_owned()
        };

        let title = tx.signal("assets");
        let census = tx.signal(first);
        let sizes = tx.signal(format!("{FONT}: {} bytes, {verdict}", font.len()));

        let root = tx
            .column(|tx| {
                tx.label(title); // label#0
                // THE BYTES, not the blob handle: this scene is the
                // consumer, and what reaches the platform's decoder is
                // what `bytes()` handed back.
                tx.image(mark.bytes()); // image#0
                tx.label(census); // label#1
                tx.label(sizes); // label#2
            })
            .id();
        tx.mount(root);
    });

    loop {
        ctx.next();
    }
}

fn main() {
    kaya::run(app)
}
