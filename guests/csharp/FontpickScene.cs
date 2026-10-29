// The font picker scene, C# port: guests/rust/fontpick.rs,
// tools/scenes/fontpick.steps (docs/font-picker-plan.md §7).

static class FontpickScene
{
    static readonly string[] Mono = ["Menlo", "DejaVu Sans Mono", "Cascadia Mono", "Consolas",
        "Courier New", "Droid Sans Mono", "monospace"];
    const string Doc = "bold run, italic run, plain run";

    static string Words(int weight, bool italic, int width) =>
        $"{weight} {(italic ? "italic" : "upright")} {width}";

    static (int, int, int)? LightFamily(IReadOnlyList<FontFace> faces)
    {
        var upright = faces.Where(f => !f.Italic && f.Width == 5).Select(f => f.Weight).ToList();
        var italic = faces.Where(f => f.Italic && f.Width == 5).Select(f => f.Weight).ToList();
        if (upright.Count < 3 || !upright.Contains(700)) return null;
        int light = upright.FirstOrDefault(w => w < 400 && italic.Contains(w));
        if (light == 0) return null;
        for (int i = 1; i < upright.Count; i++)
            if (upright[i - 1] >= 500 && upright[i] > upright[i - 1] + 1)
                return (light, upright[i - 1], upright[i]);
        return null;
    }

    static int? UprightOnly(IReadOnlyList<FontFace> faces)
    {
        if (faces.Count == 0 || faces.Any(f => f.Italic)) return null;
        foreach (var f in faces)
            if (f.Width == 5) return f.Weight;
        return null;
    }

    public static void Run()
    {
        var app = new KayaApp();
        Signal ready = default, pick = default, picked = default;
        var want = new Signal[6];
        Widget exact = default, between = default, synth = default, doc = default, chosen = default;

        var queue = new List<string>();
        (string Family, (int L, int A, int B) Faces)? light = null;
        (string Family, int Weight)? plain = null;
        string? mono = null;
        FontChoice? asked = null;

        void Next(Tx t)
        {
            var next = queue[^1];
            queue.RemoveAt(queue.Count - 1);
            t.ListFontFaces(next);
        }

        app.OnFontFamilies((t, families) =>
        {
            mono = Mono.FirstOrDefault(m => families.Contains(m));
            queue = families.Reverse().ToList();
            if (mono != null) queue.Add(mono);
            if (queue.Count > 0) Next(t);
        });

        app.OnFontFaces((t, family, faces) =>
        {
            if (family == mono && asked == null)
            {
                var face = faces.FirstOrDefault(f => f.Weight == 700 && !f.Italic && f.Width == 5)
                    ?? faces.FirstOrDefault();
                if (face != null) asked = new FontChoice(family, face.Weight, face.Italic, face.Width);
            }
            if (light == null && LightFamily(faces) is { } l) light = (family, l);
            if (plain == null && UprightOnly(faces) is { } w) plain = (family, w);
            if (light == null || plain == null)
            {
                if (queue.Count > 0) Next(t);
                else t.Write(ready, "faces: none suit");
                return;
            }
            var (lf, (lw, a, b)) = light.Value;
            var (pf, pw) = plain.Value;
            t.SetFamily(exact, lf);
            t.SetFontWeight(exact, lw);
            t.SetFamily(between, lf);
            t.SetFontWeight(between, a + (b - a) / 2);
            t.SetFamily(synth, pf);
            t.SetFontWeight(synth, pw);
            t.SetFontItalic(synth, true);
            t.SetFamily(doc, lf);
            t.SetFontWeight(doc, lw);
            t.SetDocument(doc, new Document(Doc).Bold(TextRange.In(Doc, 0, 4)).Italic(TextRange.In(Doc, 10, 6)));
            t.Write(want[0], Words(lw, false, 5));
            t.Write(want[1], Words(b, false, 5));
            t.Write(want[2], $"{Words(pw, true, 5)} synthesized");
            t.Write(want[3], Words(700, false, 5));
            t.Write(want[4], Words(lw, true, 5));
            if (asked is { } c)
            {
                t.Write(pick, $"{Words(c.Weight, c.Italic, c.Width)} {c.Family}");
                t.Write(want[5], Words(c.Weight, c.Italic, c.Width));
            }
            t.Write(ready, "faces: found");
        });

        void OnChosen(Tx t, FontChoice? c)
        {
            if (c == null)
            {
                t.Write(picked, "picked: cancelled");
                return;
            }
            t.SetFamily(chosen, c.Family);
            t.SetFontWeight(chosen, c.Weight);
            t.SetFontItalic(chosen, c.Italic);
            t.SetFontWidth(chosen, c.Width);
            t.Write(picked, c == asked ? "picked: as asked" : $"picked: {Words(c.Weight, c.Italic, c.Width)} {c.Family}");
        }

        app.Build(tx =>
        {
            tx.Window(title: "fontpick");
            ready = tx.Signal("faces: -");
            for (int i = 0; i < want.Length; i++) want[i] = tx.Signal("-");
            pick = tx.Signal("-");
            picked = tx.Signal("picked: -");
            tx.Mount(tx.Column(root =>
            {
                tx.SetA11yId(tx.Label(bind: ready), "ready");
                exact = tx.Label("Exact");
                tx.SetA11yId(exact, "exact");
                between = tx.Label("Between");
                tx.SetA11yId(between, "between");
                synth = tx.Label("Slanted");
                tx.SetA11yId(synth, "synth");
                doc = tx.Textarea(rich: true);
                tx.SetA11yId(doc, "doc");
                chosen = tx.Label("Chosen");
                tx.SetA11yId(chosen, "chosen");
                string[] ids = ["want_exact", "want_between", "want_synth", "want_bold", "want_italic", "want_pick"];
                for (int i = 0; i < ids.Length; i++) tx.SetA11yId(tx.Label(bind: want[i]), ids[i]);
                tx.SetA11yId(tx.Label(bind: pick), "pick");
                tx.SetA11yId(tx.Label(bind: picked), "picked");
                tx.Row(_ =>
                {
                    tx.SetA11yId(tx.Button("faces", onClick: t => t.ListFontFamilies()), "faces");
                    var open = tx.Button("pick", onClick: t =>
                        t.ChooseFont(codeOnly: true, faces: true, initial: asked, onResult: OnChosen));
                    tx.SetA11yId(open, "pick_button");
                });
                return root;
            }));
        });
        Environment.Exit(app.Run());
    }
}
