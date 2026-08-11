//! The grow conformance scene: the one place the layout contract is
//! asserted rather than looked at.
//!
//! The shape is dictated by what can be checked identically on seven
//! backends. Absolute geometry is a *metric*, which DESIGN leaves
//! platform-flavored — a button is not the same height on GTK and
//! AppKit and never will be — so a size assertion could never be shared
//! byte-for-byte the way every other expect is. A *share* is semantics,
//! and a container holding nothing but growers splits weight/Σweight
//! exactly, whatever its children measure and whatever the container
//! itself measures. Hence: every child of every asserted container is a
//! grower.
//!
//! One column and one row, because container targets index by creation
//! order, which legitimately differs per language (statement-shaped
//! construction is parent-first, expression trees children-first). A
//! sole container of each kind is the same widget everywhere; a second
//! would make `column#0`/`row#0` mean different things on different
//! platforms. The observation scene next door keeps deeper nesting and
//! stays unasserted for exactly that reason.
//!
//! The row asserts the HORIZONTAL contract — before it existed, a
//! backend that grew only columns would have passed the whole matrix.
//!
//! And the textarea asserts the OTHER HALF OF THE SAME CONTRACT: that
//! the widget which was handed a track actually takes it. A share is
//! read off the TRACK on three of the four backends (SwiftUI's cell
//! frame, WinUI's RowDefinition, Compose's weighted cell) — deliberately,
//! since a control that hugs inside its track is platform flavor a
//! byte-compared assertion could never carry — so a widget with a
//! HARD-CODED size splits its container exactly right and renders wrong.
//! It shipped twice that way: a slider capped at 200pt drew a 1:3 row as
//! 38/62, and a textarea frozen at 240x96 gave an editor asking for a
//! full-window buffer a small box on macOS, iOS and Windows at once,
//! with every share assertion green. `expect_fills textarea#0` is the
//! observation that sees it; the textarea is the widget it rides on
//! because a fixed natural size is exactly the shape that hides there.

pub(crate) fn app(ctx: kaya::AppCtx) {
    // No event vocabulary: this scene registers no handlers, so the
    // message type is unit.
    let msgs = kaya::Messages::<()>::new();
    ctx.apply(|tx| {
        let probe = tx.signal("grow probe");
        let one = tx.signal("one");

        let root = tx.column(|tx| {
            // Column weights 1, 2, 1 — a 25/50/25 split, none of them
            // equal to an even division of three, so an implementation
            // that splits equally (the boolean expand-flag behaviour
            // most toolkits default to) fails here rather than passing
            // by luck.
            //
            // Every share stays clear of every platform's control
            // minimums, or the scene measures the minimums instead of
            // the contract: the window is 540x330 on the desktops and
            // the root insets 16, so the column's ~250pt divide
            // ~63/126/63. The BINDING minimum is now the textarea's
            // declared 96pt floor (240x96 on every backend — GTK's
            // size request, WinUI's MinHeight, the SwiftUI frame), and
            // its 126pt track clears it by 30; the row's 63pt track
            // clears GTK's 34pt minimum button height by 29.
            tx.label(probe).grow(1.0); // label#0
            // THE WIDGET THAT MUST TAKE ITS TRACK, and the weight that
            // makes room for it. A textarea's natural size is a FIXED
            // BOX on every backend, which is the shape that ignores a
            // track without anything noticing: expect_fills reads what
            // it drew, expect_shares reads what it was given, and only
            // the pair can tell them apart.
            tx.textarea().grow(2.0); // textarea#0
            // The horizontal contract: one row whose children split
            // its WIDTH 1:3. Its own weight makes it a grower like its
            // siblings, keeping the column pure. Width tracks are roomy
            // — 25/75 of ~496pt (508 minus the 12-unit gap set below)
            // is 124 and 372 — because height was the scarce axis, not
            // width.
            // The spacing prop's conformance exercise rides the chain:
            // a non-default gap on the asserted row, so expect_fills
            // (children + gaps span the content box) fails on any
            // backend that ignores the write and keeps its 8-unit
            // default.
            tx.row(|tx| {
                tx.label(one).grow(1.0); // label#1
                tx.button("three").grow(3.0);
            })
            .grow(1.0)
            .spacing(12.0);
        })
        .id();
        tx.mount(root);
    });

    // No handlers: the controls exist for their sizes, not their
    // events — the textarea included, which is why it is declared
    // without one. The loop blocks on recv, keeping the app alive until
    // the harness finishes observing and sends Shutdown.
    while msgs.next(&ctx).is_some() {}
}

fn main() {
    kaya::run(app)
}
