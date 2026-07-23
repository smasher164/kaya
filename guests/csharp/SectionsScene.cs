// The sections conformance scene, C# port: two peer roots in the
// primary window's section set — presentation context, not
// lifecycle. The archive pane folds onSelected into a visit count,
// pinning the echo doctrine from both sides: the user's switch emits
// (the harness drives the real switcher), while the feed button's
// programmatic SelectSection moves the selection silently. The count
// surviving switch round trips proves retention. See
// guests/rust/sections.rs and tools/scenes/sections.steps.

static class SectionsScene
{
    const ulong Feed = 7;
    const ulong Archive = 8;

    public static void Run()
    {
        var app = new KayaApp();

        int visitCount = 0;
        Signal visits = default;
        app.Build(tx =>
        {
            tx.WindowTitle("sections");
            // The ADVISORY hint, exercised on the wire: `bar` is each
            // desktop's horizontal spelling and the phones' physics
            // regardless — no observable rides on it.
            tx.SectionsPresentation(KayaWire.SectionsPresentationBar);
            visits = tx.Signal("archive: 0 visits");

            tx.AddSection(Feed, title: "Feed");
            tx.AddSection(Archive, title: "Archive", onSelected: inner =>
            {
                visitCount++;
                inner.Write(visits, $"archive: {visitCount} visits");
            });

            var feedRoot = tx.Column(() =>
            {
                var ready = tx.Signal("feed ready");
                tx.Label(bind: ready); // label#0
                tx.Button("to archive", onClick: inner => // button#0
                {
                    // Programmatic selection: configuration, no echo
                    // — onSelected must NOT fire (the scene asserts
                    // the count holds).
                    inner.SelectSection(Archive);
                });
            });
            tx.MountIn(Feed, feedRoot);

            var archiveRoot = tx.Column(() =>
            {
                tx.Label(bind: visits); // label#1
            });
            tx.MountIn(Archive, archiveRoot);
        });

        System.Environment.Exit(app.Run());
    }
}
