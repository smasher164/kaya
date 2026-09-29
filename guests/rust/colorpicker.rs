//! The colour picker scene (tools/scenes/colorpicker.steps;
//! docs/color-picker-plan.md §5): an opaque picker bound to a signal so
//! button#0 can write it PROGRAMMATICALLY (the echo negative), a picker that
//! allows translucency, and a stamped picker bound to a row's own Color field.

use kaya::PathKey;

#[derive(kaya::KayaGen, Clone, Debug, PartialEq)]
struct Swatch {
    name: String,
    fill: kaya::Color,
}

#[derive(Clone)]
enum Msg {
    Title(kaya::Color),
    Glaze(kaya::Color),
    RowFill(kaya::Path, kaya::Color),
    Reset,
}

pub(crate) fn app(ctx: kaya::AppCtx) {
    let msgs = kaya::Messages::new();
    let (title_text, glaze_text, row_text, title_sig, fill_node) = ctx.apply(|tx| {
        let title_text = tx.signal("color: none");
        let glaze_text = tx.signal("alpha: none");
        let row_text = tx.signal("row: none");
        let title_sig = tx.signal(kaya::Color::from_hex(0x3366_99FF));
        let swatches = tx.collection::<Swatch>();
        let mut fill_node: Option<kaya::TemplateNodeId> = None;
        let root = tx
            .column(|tx| {
                tx.label(title_text); // label#0
                tx.label(glaze_text); // label#1
                tx.label(row_text); // label#2
                let title = tx
                    .color_picker_bound(title_sig) // color_picker#0
                    .a11y_label("Title colour")
                    .id();
                tx.a11y_id(title, "title");
                msgs.on_color(title, Msg::Title);
                let glaze = tx
                    .color_picker(kaya::Color::from_hex(0x26A2_69FF)) // color_picker#1
                    .alpha(true)
                    .a11y_label("Glaze")
                    .id();
                msgs.on_color(glaze, Msg::Glaze);
                let reset = tx.button("reset").id(); // button#0
                msgs.on_click(reset, Msg::Reset);
                for mut row in swatches.rows(tx) {
                    row.label(Swatch::name());
                    let picker = row.color_picker(Swatch::fill());
                    row.a11y_id(picker, "fill");
                    fill_node = Some(picker);
                }
            })
            .id();
        tx.mount(root);
        tx.insert(&swatches, "a", Swatch { name: "a".into(), fill: kaya::Color::from_hex(0xE661_00FF) });
        tx.insert(&swatches, "b", Swatch { name: "b".into(), fill: kaya::Color::from_hex(0xF6D3_2DFF) });
        let fill_node = fill_node.expect("swatches template declared a row colour picker");
        (title_text, glaze_text, row_text, title_sig, fill_node)
    });
    msgs.on_color_node(fill_node, Msg::RowFill);

    while let Some(msg) = msgs.next(&ctx) {
        match msg {
            Msg::Title(picked) => ctx.apply(|tx| {
                tx.write(title_text, format!("color: {picked}"));
            }),
            Msg::Glaze(picked) => ctx.apply(|tx| {
                tx.write(glaze_text, format!("alpha: {picked}"));
            }),
            Msg::RowFill(path, picked) => ctx.apply(|tx| {
                tx.write(row_text, format!("row {}: {picked}", path.key::<String>(0)));
            }),
            // Must NOT come back as a Title occurrence.
            Msg::Reset => ctx.apply(|tx| {
                tx.write(title_sig, kaya::Color::from_hex(0x3584_E4FF));
            }),
        }
    }
}

fn main() {
    kaya::run(app)
}
