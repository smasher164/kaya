#![allow(dead_code)]

include!("host.rs");

host! {
    background = "../background.rs",
    reorder = "../reorder.rs",
    panels = "../panels.rs",
    scroll = "../scroll.rs",
    search = "../search.rs",
    colorpicker = "../colorpicker.rs",
    codesurface = "../codesurface.rs",
    menus = "../menus.rs",
    filedialog = "../filedialog.rs",
    styling = "../styling.rs",
    dnd = "../dnd.rs",
    format = "../format.rs",
    grounds = "../grounds.rs",
    restore = "../restore.rs",
    tasks = "../tasks.rs",
    mountfocus = "../mountfocus.rs",
    ownundo = "../ownundo.rs",
}
