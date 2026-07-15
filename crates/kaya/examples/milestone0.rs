//! The milestone-2 scene: the structural operators live.
//!
//! A driver button steps the app through data changes; a status label
//! (signal-bound) reports what happened; a When shows a banner while
//! "extras" is on; a For over groups nests a For over items, each item
//! carrying a remove button whose click comes back as a template node
//! plus key path — which the app answers by removing that entry, the
//! screen following the data.
//!
//! The selftest (in each backend) clicks the driver twice, then the most
//! recently stamped remove button, and expects the status label to read
//! "removed g2/a".

use kaya::{Occurrence, Prop, Value, WidgetKind};

pub(crate) fn app(ctx: kaya::AppCtx) {
    let mut tx = ctx.begin();
    let status = tx.signal("step 0");
    let extras = tx.signal(false);

    let column = tx.widget(WidgetKind::Column);
    let step = tx.widget(WidgetKind::Button);
    tx.set(step, Prop::Text, "step");
    let status_label = tx.widget(WidgetKind::Label);
    tx.bind(status_label, Prop::Text, status);

    let banner = tx.when(extras, |t| {
        let label = t.widget(WidgetKind::Label);
        t.set(label, Prop::Text, "extras on");
    });

    let groups = tx.collection();
    let mut items_slot = None;
    let mut remove_slot = None;
    let group_list = tx.for_each(groups, |t| {
        let group_column = t.widget(WidgetKind::Column);
        let name = t.widget(WidgetKind::Label);
        t.bind_element(name, Prop::Text, 0);
        t.add_child(group_column, name);

        let items = t.collection();
        let item_list = t.for_each(items, |t| {
            let row = t.widget(WidgetKind::Column);
            let text = t.widget(WidgetKind::Label);
            t.bind_element(text, Prop::Text, 0);
            let remove = t.widget(WidgetKind::Button);
            t.set(remove, Prop::Text, "remove");
            t.add_child(row, text);
            t.add_child(row, remove);
            remove_slot = Some(remove);
        });
        t.add_child(group_column, item_list);
        items_slot = Some(items);
    });

    tx.add_child(column, step);
    tx.add_child(column, status_label);
    tx.add_child(column, banner);
    tx.add_child(column, group_list);
    tx.mount(column);
    tx.commit();

    let items = items_slot.unwrap();
    let remove_button = remove_slot.unwrap();

    let mut steps = 0u32;
    let mut extras_on = false;
    loop {
        match ctx.next() {
            Occurrence::ButtonClicked { id } if id == step => {
                steps += 1;
                let mut tx = ctx.begin();
                match steps {
                    1 => {
                        tx.insert(groups, "g1", "Work");
                        tx.insert_at(items, &["g1".into()], "a", "send report");
                        tx.insert_at(items, &["g1".into()], "b", "buy milk");
                        extras_on = true;
                    }
                    2 => {
                        tx.insert(groups, "g2", "Home");
                        tx.insert_at(items, &["g2".into()], "a", "water plants");
                        tx.update(groups, "g1", "Office");
                        extras_on = false;
                    }
                    _ => {}
                }
                tx.write(extras, extras_on);
                tx.write(status, format!("step {steps}"));
                tx.commit();
            }
            Occurrence::InstanceButtonClicked { node, path } if node == remove_button => {
                let [Value::Str(group), Value::Str(item)] = &path[..] else {
                    panic!("remove click carries [group, item], got {path:?}");
                };
                let text = format!("removed {group}/{item}");
                let mut tx = ctx.begin();
                tx.remove_at(items, &[path[0].clone()], path[1].clone());
                tx.write(status, text);
                tx.commit();
            }
            Occurrence::ButtonClicked { .. } | Occurrence::InstanceButtonClicked { .. } => {}
            Occurrence::Shutdown => break,
        }
    }
}

fn main() {
    kaya::run(app)
}
