//! The accessibility conformance scene: the universal props read back
//! out of the PLATFORM'S OWN tree rather than kaya's model. The
//! byte-frozen contract is tools/scenes/a11y.steps.
//!
//! Two rules any edit here must keep. EVERY WIDGET KIND appears, or a
//! universal prop is proven only by grep. And there is exactly ONE
//! container of each container kind: creation order legitimately
//! differs per language, so `row#0` names the same widget everywhere
//! only while there is one row (tools/check-steps.sh).

pub(crate) fn app(ctx: kaya::AppCtx) {
    // The keep-alive idiom: docs/deferred.md wants a `park` primitive.
    let msgs = kaya::Messages::<()>::new();
    ctx.apply(|tx| {
        let status = tx.signal("Ready");
        let cell_name = tx.signal("Name");
        let cell_value = tx.signal("Ada");
        let feed_item = tx.signal("Item");

        let root = tx.column(|tx| {
            // Caption-bearing controls: identified, deliberately NOT
            // labelled, so the platform must speak the caption. The hint
            // is a verb phrase (VoiceOver speaks it as written; TalkBack
            // prefixes "double tap to").
            tx.button("Save").a11y_id("save").a11y_hint("save the draft");
            tx.checkbox("Details").a11y_id("details").a11y_hint("show more detail");
            tx.button("Reset").a11y_id("reset");
            tx.label(status).a11y_id("status");
            // Caption-less controls: an app MUST name these.
            tx.entry().a11y_id("name").a11y_label("Full name");
            tx.textarea().a11y_id("notes").a11y_label("Notes");
            tx.slider(0.0, 1.0, 0.5).a11y_id("volume").a11y_label("Volume");
            tx.progress(0.25).a11y_id("loading").a11y_label("Loading");
            tx.image(&TEST_PNG[..]).a11y_id("logo").a11y_label("Logo");
            tx.select(&["Red", "Green"], 0).a11y_id("color").a11y_label("Color");
            tx.radio(&["Small", "Large"], 0).a11y_id("size").a11y_label("Size");
            // NAMING a container declares it a group, and its children
            // must stay individually reachable — one semantics, four
            // very different backend spellings (DESIGN.md; the SwiftUI
            // trap is docs/traps.md's `children: .contain`).
            tx.grid(2, |tx| {
                tx.label(cell_name);
                tx.label(cell_value);
            })
            .a11y_id("cells")
            .a11y_label("Cells");
            tx.scroll(|tx| {
                tx.label(feed_item);
            })
            .a11y_id("feed")
            .a11y_label("Feed");
            tx.row(|tx| {
                tx.button("Cancel").a11y_id("cancel");
                tx.button("OK").a11y_id("ok");
            })
            .a11y_id("actions")
            .a11y_label("Actions");
        })
        .a11y_id("form")
        .a11y_label("Form")
        .id();
        tx.mount(root);
    });

    while msgs.next(&ctx).is_some() {}
}

fn main() {
    kaya::run(app)
}

/// A 2x2 RGB PNG (red/green over blue/white), 75 bytes. Embedded as
/// source: scenes carry their inputs, no runtime file I/O.
const TEST_PNG: [u8; 75] = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 2, 0, 0, 0, 2, 8, 2, 0, 0, 0, 253, 212, 154, 115, 0, 0, 0, 18, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192, 192, 0, 194, 12, 255, 129, 0, 0, 31, 238, 5, 251, 11, 217, 104, 139, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130];
