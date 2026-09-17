// The sections scene, C# port — guests/rust/sections.rs,
// tools/scenes/sections.steps.

static class SectionsScene
{
    const ulong Feed = 7;
    const ulong Archive = 8;
    // The SIDEBAR half rides an AUX WINDOW, opened only from the desktop
    // tail's click, so CreateWindow never runs where the capability is absent.
    const ulong Library = 1;
    const ulong Shelves = 2;
    const ulong Loans = 3;

    public static void Run()
    {
        var app = new KayaApp();

        int visitCount = 0;
        var visits = app.Build(tx =>
        {
            tx.Window(title: "sections",
                sectionsPresentation: SectionsPresentation.Bar);
            var visits = tx.Signal("archive: 0 visits");

            // A symbol names a CONCEPT (docs/styling-plan.md D6).
            tx.AddSection(Feed, title: "Feed", symbol: Symbol.Home);
            tx.AddSection(Archive, title: "Archive", symbol: Symbol.Star,
                onSelected: inner =>
                {
                    visitCount++;
                    inner.Write(visits, $"archive: {visitCount} visits");
                });

            var feedRoot = tx.Column(feedRoot =>
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
                        sectionsPresentation: SectionsPresentation.Sidebar);
                    inner.AddSection(Shelves, title: "Shelves",
                        symbol: Symbol.Search, window: Library);
                    inner.AddSection(Loans, title: "Loans",
                        symbol: Symbol.Lock, window: Library);

                    var shelvesRoot = inner.Column(shelvesRoot =>
                    {
                        var ready = inner.Signal("shelves ready");
                        inner.Label(bind: ready); // label#2
                        return shelvesRoot;
                    });
                    inner.MountIn(Shelves, shelvesRoot);
                    var loansRoot = inner.Column(loansRoot =>
                    {
                        var ready = inner.Signal("loans ready");
                        inner.Label(bind: ready); // label#3
                        return loansRoot;
                    });
                    inner.MountIn(Loans, loansRoot);
                });
                return feedRoot;
            });
            tx.MountIn(Feed, feedRoot);

            var archiveRoot = tx.Column(archiveRoot =>
            {
                tx.Label(bind: visits); // label#1
                return archiveRoot;
            });
            tx.MountIn(Archive, archiveRoot);
            return visits;
        });

        System.Environment.Exit(app.Run());
    }
}
