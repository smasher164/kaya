//! Milestone 0: a button click makes the round trip from the main thread's
//! occurrence ring to the app thread and back through the command ring.
//!
//! Run with KAYA_SELFTEST=1 to click programmatically and verify the label.

pub(crate) fn app(ctx: kaya::AppCtx) {
    let mut count = 0u64;
    loop {
        match ctx.next() {
            kaya::Occurrence::ButtonClicked { .. } => {
                count += 1;
                ctx.send(kaya::Command::SetText {
                    id: kaya::skeleton::LABEL,
                    text: format!("Clicked {count} times"),
                });
            }
            kaya::Occurrence::Shutdown => break,
        }
    }
}

fn main() {
    kaya::run(app);
}
