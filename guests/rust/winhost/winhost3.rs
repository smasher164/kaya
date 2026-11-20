#![allow(dead_code)]

include!("host.rs");

host! {
    entry = "../entry.rs",
    layout = "../layout.rs",
    split = "../split.rs",
    radio = "../radio.rs",
    fullscreen = "../fullscreen.rs",
    autofill = "../autofill.rs",
    safearea = "../safearea.rs",
    commands = "../commands.rs",
    dirty = "../dirty.rs",
    identity = "../identity.rs",
    tooltips = "../tooltips.rs",
    farend = "../farend.rs",
    tracks = "../tracks.rs",
    windowed = "../windowed.rs",
    flexshrink = "../flexshrink.rs",
    badge = "../badge.rs",
    richrows = "../richrows.rs",
}
