//! The listdetail conformance scene: the SAME app as the split scene,
//! run where the HOST — not the script — picks the window's width.
//!
//! There is deliberately no app logic here. split.rs is the guest; the
//! scenes differ only in what they may assert, because a phone or
//! tablet cannot drive `resize_window` (the system owns those
//! surfaces; DESIGN.md, Windows) and so cannot run the split scene at
//! all. Writing a second copy of the app would let the two drift, and
//! the claim both scenes make is precisely that the guest does not
//! change with the form factor.
//!
//! split.rs's own `fn main` comes along as a private function of the
//! module and is never linked as an entry point, which is what the
//! allow below is for (the milestone2_android precedent).
#![allow(dead_code)]

mod split;

fn main() {
    kaya::run(|ctx| split::app_titled(ctx, "listdetail"))
}
