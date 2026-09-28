//! The scroll-to scene (tools/scenes/scrollto.steps): the app scrolls a
//! list of messages to a row by key (docs/scroll-to-plan.md), opening at
//! the newest one before the first layout, jumping to one on a click,
//! staying put on a key no row holds, and following its own send.

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Message {
    text: String,
}

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Frame {
    name: String,
}

#[derive(Clone, Copy)]
enum Msg {
    Jump,
    Nowhere,
    Send,
    Frame,
    AddFrame,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (messages, list, count, frames, strip) = ctx.apply(|tx| {
        let messages = tx.collection::<Message>();
        let frames = tx.collection::<Frame>();
        let count = tx.signal("60 messages".to_string());
        let mut list = None;
        let mut strip = None;
        let root = tx
            .column(|tx| {
                tx.label(count).a11y_id("count");
                tx.row(|tx| {
                    let jump = tx.button("jump").a11y_id("jump").id();
                    msgs.on_click(jump, Msg::Jump);
                    let nowhere = tx.button("nowhere").a11y_id("nowhere").id();
                    msgs.on_click(nowhere, Msg::Nowhere);
                    let send = tx.button("send").a11y_id("send").id();
                    msgs.on_click(send, Msg::Send);
                    let frame = tx.button("frame").a11y_id("frame").id();
                    msgs.on_click(frame, Msg::Frame);
                    let add = tx.button("add frame").a11y_id("add_frame").id();
                    msgs.on_click(add, Msg::AddFrame);
                });
                tx.scroll(|tx| {
                    // The For's own container is what a scroll_to_row
                    // addresses (docs/scroll-to-plan.md S1): its rows handle
                    // names it.
                    let rows = messages.rows(tx);
                    let inner = rows.id();
                    for mut row in rows {
                        row.label(Message::text());
                    }
                    tx.a11y_id(inner, "messages");
                    list = Some(inner);
                })
                .grow(1.0)
                .a11y_id("list");
                // A filmstrip that runs sideways (docs/hscroll-plan.md): the
                // same scroll_to_row and follows_end, along its own axis.
                tx.scroll(|tx| {
                    let rows = frames.rows(tx);
                    let inner = rows.id();
                    for mut row in rows {
                        row.label(Frame::name());
                    }
                    tx.axis(inner, kaya::Axis::Horizontal);
                    tx.a11y_id(inner, "frames");
                    strip = Some(inner);
                })
                .axis(kaya::Axis::Horizontal)
                .follows_end(true)
                .a11y_id("strip");
            })
            .id();
        tx.mount(root);
        for i in 1..=30 {
            tx.insert(&frames, format!("f{i}"), Frame { name: format!("frame {i}") });
        }
        for i in 1..=60 {
            tx.insert(&messages, format!("m{i}"), Message { text: format!("message {i}") });
        }
        let list = list.expect("the scroll's column was built");
        tx.scroll_to_row(list, "m60".to_string());
        (messages, list, count, frames, strip.expect("the strip was built"))
    });

    let mut sent = 60;
    let mut framed = 30;
    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Jump => ctx.apply(|tx| tx.scroll_to_row(list, "m10".to_string())),
            Msg::Nowhere => ctx.apply(|tx| tx.scroll_to_row(list, "m999".to_string())),
            Msg::Send => {
                sent += 1;
                ctx.apply(|tx| {
                    tx.insert(&messages, format!("m{sent}"), Message { text: format!("message {sent}") });
                    tx.write(count, format!("{sent} messages"));
                    tx.scroll_to_row(list, format!("m{sent}"));
                });
            }
            Msg::Frame => ctx.apply(|tx| tx.scroll_to_row(strip, "f10".to_string())),
            Msg::AddFrame => {
                framed += 1;
                ctx.apply(|tx| {
                    tx.insert(&frames, format!("f{framed}"), Frame { name: format!("frame {framed}") });
                });
            }
        }
    }
}

fn main() {
    kaya::run(app)
}
