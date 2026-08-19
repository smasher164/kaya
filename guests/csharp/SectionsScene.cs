// The sections conformance scene, C# port: two peer roots in the
// primary window's section set. The archive pane folds onSelected into
// a visit count, pinning the echo doctrine from both sides — a user's
// switch emits, a programmatic SelectSection does not. See
// guests/rust/sections.rs and tools/scenes/sections.steps.

static class SectionsScene
{
    const ulong Feed = 7;
    const ulong Archive = 8;
    // The SIDEBAR half, in an AUX WINDOW so one shared scene covers both
    // arms. It opens from a handler only the desktop tail's click
    // reaches, so CreateWindow never runs where the capability is absent.
    const ulong Library = 1;
    const ulong Shelves = 2;
    const ulong Loans = 3;

    public static void Run()
    {
        var app = new KayaApp();

        int visitCount = 0;
        Signal visits = default;
        app.Build(tx =>
        {
            tx.Window(title: "sections",
                sectionsPresentation: KayaWire.SectionsPresentationBar);
            visits = tx.Signal("archive: 0 visits");

            // A symbol names a CONCEPT; each platform draws it from its
            // own set (docs/styling-plan.md D6).
            tx.AddSection(Feed, title: "Feed", symbol: Symbol.Home);
            tx.AddSection(Archive, title: "Archive", symbol: Symbol.Star,
                onSelected: inner =>
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
                    // Programmatic: onSelected must NOT fire.
                    inner.SelectSection(Archive);
                });
                tx.Button("open library", onClick: inner => // button#1
                {
                    inner.CreateWindow(Library, title: "library",
                        sectionsPresentation: KayaWire.SectionsPresentationSidebar);
                    inner.AddSection(Shelves, title: "Shelves",
                        symbol: Symbol.Search, window: Library);
                    inner.AddSection(Loans, title: "Loans",
                        symbol: Symbol.Lock, window: Library);

                    var shelvesRoot = inner.Column(() =>
                    {
                        var ready = inner.Signal("shelves ready");
                        inner.Label(bind: ready); // label#2
                    });
                    inner.MountIn(Shelves, shelvesRoot);
                    var loansRoot = inner.Column(() =>
                    {
                        var ready = inner.Signal("loans ready");
                        inner.Label(bind: ready); // label#3
                    });
                    inner.MountIn(Loans, loansRoot);
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
