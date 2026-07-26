//! The accessibility conformance scene: the two universal props
//! (`a11y_id`, `a11y_label`) and the verb that reads them back out of
//! the PLATFORM'S OWN accessibility tree rather than kaya's model.
//!
//! What this scene exists to prove is DESIGN's central claim about the
//! wrap-native bet — that native widgets ARE the accessibility tree, so
//! roles and names are correct without kaya synthesizing anything. It
//! therefore asserts two different things on purpose:
//!
//!   * DERIVED names. The button and checkbox carry an identifier but
//!     NO authored label, so what an assistive client speaks is
//!     whatever the control derived from its own caption. That is the
//!     free-by-construction half, and nothing but a real tree read can
//!     show it.
//!   * AUTHORED names. The entry and the image have no caption to
//!     derive from, which is exactly where an app must supply one.
//!
//! EVERY WIDGET KIND appears here, and exactly one container of each
//! container kind. Both halves of that are deliberate. The props are
//! UNIVERSAL, so a scene that exercised four kinds would leave the
//! other ten proven only by grep (tools/check-universal-props.sh
//! asserts each render arm applies them; this is where the runtime
//! agrees or does not). And one row / one column / one grid / one
//! scroll keeps every container target unambiguous: container creation
//! order legitimately differs per language — statement-shaped
//! construction is parent-first, expression trees are children-first —
//! so `row#0` is a stable name for "the row" only while there is one
//! (tools/check-steps.sh enforces the rule).
//!
//! The byte-frozen contract is tools/scenes/a11y.steps.

pub(crate) fn app(ctx: kaya::AppCtx) {
    // A static scene: nothing here needs a handler, so the message loop
    // exists purely to block until Shutdown (the keep-alive idiom every
    // handler-less scene uses — docs/deferred.md wants a `park`
    // primitive to replace it).
    let msgs = kaya::Messages::<()>::new();
    ctx.apply(|tx| {
        let status = tx.signal("Ready");
        let cell_name = tx.signal("Name");
        let cell_value = tx.signal("Ada");
        let feed_item = tx.signal("Item");

        let root = tx.column(|tx| {
            // Caption-bearing controls: identified, but deliberately
            // NOT labelled. The platform must speak the caption.
            // The HINT rides the activation kinds: what happens when
            // you activate this control, as a verb phrase (VoiceOver
            // speaks it as written; TalkBack prefixes "double tap to").
            tx.button("Save").a11y_id("save").a11y_hint("save the draft");
            tx.checkbox("Details").a11y_id("details").a11y_hint("show more detail");
            tx.button("Reset").a11y_id("reset");
            // A label's caption IS its content, so it derives too.
            tx.label(status).a11y_id("status");
            // Caption-less controls: an app MUST name these, and the
            // tree must report the authored name. A text field, an
            // editor, a slider, a progress bar and an image all draw
            // something with no words in it; that is exactly the case
            // where accessibility is not free and the app has to say
            // what the thing is.
            tx.entry().a11y_id("name").a11y_label("Full name");
            tx.textarea().a11y_id("notes").a11y_label("Notes");
            tx.slider(0.0, 1.0, 0.5).a11y_id("volume").a11y_label("Volume");
            tx.progress(0.25).a11y_id("loading").a11y_label("Loading");
            tx.image(&TEST_PNG[..]).a11y_id("logo").a11y_label("Logo");
            // The two CHOICE kinds. Their options carry their own
            // captions, but the choice itself is unnamed without a
            // label — "Red" says nothing about what is being chosen.
            tx.select(&["Red", "Green"], 0).a11y_id("color").a11y_label("Color");
            tx.radio(&["Small", "Large"], 0).a11y_id("size").a11y_label("Size");
            // A container is a GROUP to an assistive client — the
            // reason these props are universal rather than kind-scoped
            // — and NAMING one is how an app declares it a group.
            // Measured 2026-07-25 on SwiftUI and on Compose: the row
            // reports `group/Actions` while both buttons inside it stay
            // individually reachable.
            //
            // That cost a different step in every backend, because the
            // toolkits disagree about what an UNNAMED container is.
            // SwiftUI must be told the container is its own
            // accessibility element first (`children: .contain`);
            // without that, a label collapses the row into ONE element
            // and hides both buttons — which is what an earlier note
            // here reported as the behaviour of labelling a container.
            // GTK must promote GtkBox's role from GENERIC to Group, and
            // WinUI gives an unnamed Grid no automation peer at all.
            // One semantics, four spellings.
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

/// A 2x2 RGB PNG (red/green over blue/white), 75 bytes: the gallery
/// scene's asset, embedded as source per the include_str! doctrine —
/// scenes carry their inputs, no runtime file I/O.
const TEST_PNG: [u8; 75] = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 2, 0, 0, 0, 2, 8, 2, 0, 0, 0, 253, 212, 154, 115, 0, 0, 0, 18, 73, 68, 65, 84, 120, 156, 99, 248, 207, 192, 192, 0, 194, 12, 255, 129, 0, 0, 31, 238, 5, 251, 11, 217, 104, 139, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130];
