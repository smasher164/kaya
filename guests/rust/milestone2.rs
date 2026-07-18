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
//! "removed g2/a, 0 left" — the count read back from the collection
//! model right after the remove, proving the patch-producing fold: the
//! collection is the model, and reads are exactly the writes.

use kaya::{Occurrence, Prop, Value, WidgetKind};

pub(crate) fn app(ctx: kaya::AppCtx) {
    // The construction sugar: constructors carry their props,
    // containers take their children. Handlers stay in the occurrence
    // loop, the Rust idiom; C's guests keep the fully explicit floor.
    let mut tx = ctx.begin();
    let status = tx.signal("step 0");
    let extras = tx.signal(false);

    let step = tx.button("step");
    let status_label = tx.label(status);

    let (banner, ()) = tx.when(extras, |t| {
        let label = t.widget(WidgetKind::Label);
        t.set(label, Prop::Text, "extras on");
    });

    // Handles declared inside a template escape as the body's return
    // value — no side-channel slots.
    let groups = tx.collection::<String>();
    let (group_list, (items, remove_button)) = tx.for_each(&groups, |t| {
        let name = t.widget(WidgetKind::Label);
        t.bind_element(name, Prop::Text, 0);

        let items = t.collection::<String>();
        let (item_list, remove) = t.for_each(&items, |t| {
            let text = t.widget(WidgetKind::Label);
            t.bind_element(text, Prop::Text, 0);
            let remove = t.widget(WidgetKind::Button);
            t.set(remove, Prop::Text, "remove");
            t.column(&[text, remove]);
            remove
        });
        t.column(&[name, item_list]);
        (items, remove)
    });

    let root = tx.column(&[step, status_label, banner, group_list]);
    tx.mount(root);
    tx.commit();

    let mut steps = 0u32;
    let mut extras_on = false;
    loop {
        match ctx.next() {
            Occurrence::ButtonClicked { id } if id == step => {
                steps += 1;
                let mut tx = ctx.begin();
                match steps {
                    1 => {
                        tx.insert(&groups, "g1", "Work");
                        let todos = items.at("g1");
                        tx.insert(&todos, "a", "send report");
                        tx.insert(&todos, "b", "buy milk");
                        extras_on = true;
                    }
                    2 => {
                        tx.insert(&groups, "g2", "Home");
                        tx.insert(&items.at("g2"), "a", "water plants");
                        tx.update(&groups, "g1", "Office");
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
                // The instance handle names the target once; mutation
                // and read hang off the same value. The collection is
                // the model: the count read is the fold of the
                // patches, this one included.
                let todos = items.at(path[0].clone());
                let mut tx = ctx.begin();
                tx.remove(&todos, path[1].clone());
                let left = tx.len(&todos);
                tx.write(status, format!("removed {group}/{item}, {left} left"));
                tx.commit();
            }
            Occurrence::ButtonClicked { .. } | Occurrence::InstanceButtonClicked { .. } => {}
            Occurrence::TextChanged { .. } | Occurrence::InstanceTextChanged { .. } => {}
            Occurrence::Toggled { .. } | Occurrence::InstanceToggled { .. } => {}
            Occurrence::ValueChanged { .. } | Occurrence::InstanceValueChanged { .. } => {}
            Occurrence::Shutdown => break,
        }
    }
}

fn main() {
    kaya::run(app)
}
