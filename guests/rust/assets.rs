//! The assets conformance scene (tools/scenes/assets.steps). THE MISS IS A
//! QUERY, WITHOUT UNWINDING, and LINE 1 ONLY: line 2 differs per host.

/// Absent, and deliberately LEGAL, so the miss is the census sentence.
const MISSING: &str = "icons/nope.png";

const MARK: &str = "icons/kaya-mark.png";

/// 111400 bytes: a reader that truncated into a fixed buffer shows here.
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
            // Prints the sentence: a failure must say what was measured.
            complaint.lines().next().unwrap_or("").to_owned()
        };

        let title = tx.signal("assets");
        let census = tx.signal(first);
        let sizes = tx.signal(format!("{FONT}: {} bytes, {verdict}", font.len()));

        let root = tx
            .column(|tx| {
                tx.label(title); // label#0
                // THE BYTES, not the blob handle.
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
