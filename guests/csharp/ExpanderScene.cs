// The expander scene, C# port — guests/rust/expander.rs,
// tools/scenes/expander.steps.

[KayaGen]
record Section(string Name, bool Open);

static class ExpanderScene
{
    static string Word(bool open) => open ? "open" : "closed";

    public static void Run()
    {
        var app = new KayaApp();
        var heard = 0;
        var opens = new System.Collections.Generic.Dictionary<string, bool> { ["s01"] = true };

        app.Build(tx =>
        {
            tx.Window(title: "expander", width: 520, height: 860);
            var state = tx.Signal("details: closed");
            var heardText = tx.Signal("heard: 0");
            var typed = tx.Signal("name: -");
            var rowsText = tx.Signal("rows: -");
            var inside = tx.Signal("Inside the body");
            var sections = SectionKaya.Collection(tx);

            tx.Mount(tx.Column(root =>
            {
                var details = tx.Expander("Details", d =>
                {
                    var name = tx.Entry(onChange: (t, text) => t.Write(typed, $"name: {text}"));
                    tx.SetPlaceholder(name, "Name");
                    tx.SetA11yId(name, "name");
                    tx.SetA11yId(tx.Label(bind: inside), "inside");
                    return d;
                }, summary: "One field", symbol: Symbol.Info, onToggle: (t, open) =>
                {
                    heard++;
                    t.Write(state, $"details: {Word(open)}");
                    t.Write(heardText, $"heard: {heard}");
                });
                tx.SetA11yId(details, "details");
                tx.SetA11yId(tx.Label(bind: state), "state");
                tx.SetA11yId(tx.Label(bind: heardText), "heard");
                tx.SetA11yId(tx.Label(bind: typed), "typed");
                tx.Row(_ =>
                {
                    tx.SetA11yId(tx.Button("Show", t =>
                    {
                        t.SetExpanded(details, true);
                        t.Write(state, "details: open");
                    }), "show");
                    tx.SetA11yId(tx.Button("Hide", t =>
                    {
                        t.SetExpanded(details, false);
                        t.Write(state, "details: closed");
                    }), "hide");
                });
                tx.Column(form =>
                {
                    tx.SetA11yId(form, "form");
                    tx.Labeled("Sort", _ => tx.SetA11yId(tx.Select(new[] { "Due", "Name" }), "sort"));
                    tx.Expander("Advanced", advanced =>
                    {
                        tx.SetA11yId(advanced, "advanced");
                        tx.Labeled("Hide badge", _ => tx.SetA11yId(tx.Checkbox(""), "badge"));
                        tx.Labeled("Keep completed", _ => tx.SetA11yId(tx.Checkbox(""), "keep"));
                    });
                });
                tx.SetA11yId(tx.Label(bind: rowsText), "rows");
                tx.SetA11yId(tx.Button("Rebuild", t =>
                {
                    t.Remove(sections.Collection, "s00");
                    sections.Insert(t, "s00", new Section("Section 0", opens.GetValueOrDefault("s00")));
                    t.Write(rowsText, "rebuilt s00");
                }), "rebuild");
                tx.Column(_ =>
                {
                    foreach (var row in sections.Rows())
                    {
                        var node = row.Expander(row.Name, row.Open, () => row.Label(row.Name),
                            (t, keys, open) =>
                            {
                                var key = (string)keys[0];
                                opens[key] = open;
                                SectionKaya.Patch(t, sections, key).Open(open);
                                t.Write(rowsText, $"sec {key}: {Word(open)}");
                            });
                        row.SetA11yId(node, "sec");
                    }
                });
                return root;
            }));

            for (var i = 0; i < 3; i++)
            {
                sections.Insert(tx, $"s{i:00}", new Section($"Section {i}", i == 1));
            }
        });

        System.Environment.Exit(app.Run());
    }
}
