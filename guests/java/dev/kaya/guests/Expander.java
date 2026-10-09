package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaGen;
import java.util.HashMap;
import java.util.Map;

/**
 * The expander scene from the JVM — guests/rust/expander.rs,
 * tools/scenes/expander.steps (docs/expander-plan.md §5).
 */
public final class Expander {
    @KayaGen(key = "String")
    record Section(String name, boolean open) {}

    private static String word(boolean open) {
        return open ? "open" : "closed";
    }

    public static void app() {
        KayaApp app = new KayaApp();
        int[] heard = {0};
        Map<String, Boolean> opens = new HashMap<>(Map.of("s01", true));

        app.build(tx -> {
            tx.window(0).title("expander").size(520, 860);
            KayaApp.Signal<String> state = tx.signal("details: closed");
            KayaApp.Signal<String> heardText = tx.signal("heard: 0");
            KayaApp.Signal<String> typed = tx.signal("name: -");
            KayaApp.Signal<String> rowsText = tx.signal("rows: -");
            KayaApp.Signal<String> inside = tx.signal("Inside the body");
            var sections = SectionKaya.collection(tx);

            tx.mount(tx.column(col -> {
                KayaApp.Widget details = tx.expander("Details", d -> {
                    KayaApp.Widget name = tx.entry().placeholder("Name").a11yId("name");
                    app.onChange(name, (t, text) -> t.write(typed, "name: " + text));
                    tx.label(inside).a11yId("inside");
                }).summary("One field").symbol(KayaApp.Symbol.INFO).a11yId("details");
                app.onToggle(details, (t, open) -> {
                    heard[0]++;
                    t.write(state, "details: " + word(open));
                    t.write(heardText, "heard: " + heard[0]);
                });
                tx.label(state).a11yId("state");
                tx.label(heardText).a11yId("heard");
                tx.label(typed).a11yId("typed");
                tx.row(r -> {
                    KayaApp.Widget show = tx.button("Show").a11yId("show");
                    app.onClick(show, t -> {
                        t.setExpanded(details, true);
                        t.write(state, "details: open");
                    });
                    KayaApp.Widget hide = tx.button("Hide").a11yId("hide");
                    app.onClick(hide, t -> {
                        t.setExpanded(details, false);
                        t.write(state, "details: closed");
                    });
                });
                tx.column(form -> {
                    tx.labeled("Sort", l -> {
                        tx.select(new String[] {"Due", "Name"}, 0, null).a11yId("sort");
                    });
                    tx.expander("Advanced", a -> {
                        tx.labeled("Hide badge", l -> {
                            tx.checkbox("", null).a11yId("badge");
                        });
                        tx.labeled("Keep completed", l -> {
                            tx.checkbox("", null).a11yId("keep");
                        });
                    }).a11yId("advanced");
                }).a11yId("form");
                tx.label(rowsText).a11yId("rows");
                KayaApp.Widget rebuild = tx.button("Rebuild").a11yId("rebuild");
                app.onClick(rebuild, t -> {
                    t.remove(sections.handle, "s00");
                    sections.insert(t, "s00",
                            new Section("Section 0", opens.getOrDefault("s00", false)));
                    t.write(rowsText, "rebuilt s00");
                });
                tx.column(list -> {
                    for (var row : SectionKaya.rows(tx, sections)) {
                        KayaApp.Node node = row.expander(row.name, row.open, () -> row.label(row.name));
                        row.setA11yId(node, "sec");
                        app.onToggle(node, (t, keys, open) -> {
                            String key = (String) keys.get(0);
                            opens.put(key, open);
                            SectionKaya.patch(t, sections, key).open(open);
                            t.write(rowsText, "sec " + key + ": " + word(open));
                        });
                    }
                });
            }));

            for (int i = 0; i < 3; i++) {
                sections.insert(tx, String.format("s%02d", i), new Section("Section " + i, i == 1));
            }
            return null;
        });

        app.dispatchLoop();
    }

    private Expander() {}
}
