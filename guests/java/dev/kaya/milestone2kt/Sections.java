package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;
import dev.kaya.KayaWire;

/**
 * The sections conformance scene from the JVM: two peer roots in the
 * primary window's section set. The visit count pins the echo doctrine
 * from both sides — the user's switch emits, a programmatic
 * selectSection does not. See guests/rust/sections.rs and
 * tools/scenes/sections.steps.
 */
final class Sections {
    private static final long FEED = 7;
    private static final long ARCHIVE = 8;
    // The SIDEBAR arm lives in an AUX WINDOW, opened only from the
    // desktop tail's click: the phone runners cut that tail, so
    // createWindow never runs where the capability is absent.
    // Reachability is the gate — no capability read needed.
    private static final long LIBRARY = 1;
    private static final long SHELVES = 2;
    private static final long LOANS = 3;

    private static int visitCount = 0;

    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0)
                    .title("sections")
                    .sectionsPresentation(KayaWire.SECTIONS_PRESENTATION_BAR);
            KayaApp.Signal<String> visits = tx.signal("archive: 0 visits");

            // Symbols are CONCEPTS, drawn per platform: SF Symbols
            // spells HOME `house`, and no shared asset would be legal
            // anyway (docs/styling-plan.md D6).
            long feed = tx.addSection(FEED).title("Feed")
                    .symbol(KayaApp.Symbol.HOME)
                    .id();
            long archive = tx.addSection(ARCHIVE)
                    .title("Archive")
                    .symbol(KayaApp.Symbol.STAR)
                    .onSelected(inner -> {
                        visitCount++;
                        inner.write(visits, "archive: " + visitCount + " visits");
                    })
                    .id();

            KayaApp.Widget feedRoot = tx.column(() -> {
                KayaApp.Signal<String> ready = tx.signal("feed ready");
                tx.label(ready); // label#0
                tx.button("to archive", inner -> { // button#0
                    // Programmatic selection: onSelected must NOT fire.
                    inner.selectSection(ARCHIVE);
                });
                tx.button("open library", inner -> { // button#1
                    inner.createWindow(LIBRARY)
                            .title("library")
                            .sectionsPresentation(KayaWire.SECTIONS_PRESENTATION_SIDEBAR);
                    long shelves = inner.addSectionIn(LIBRARY, SHELVES)
                            .title("Shelves")
                            .symbol(KayaApp.Symbol.SEARCH)
                            .id();
                    long loans = inner.addSectionIn(LIBRARY, LOANS)
                            .title("Loans")
                            .symbol(KayaApp.Symbol.LOCK)
                            .id();

                    KayaApp.Widget shelvesRoot = inner.column(() -> {
                        KayaApp.Signal<String> shelvesReady = inner.signal("shelves ready");
                        inner.label(shelvesReady); // label#2
                    });
                    inner.mountIn(shelves, shelvesRoot);

                    KayaApp.Widget loansRoot = inner.column(() -> {
                        KayaApp.Signal<String> loansReady = inner.signal("loans ready");
                        inner.label(loansReady); // label#3
                    });
                    inner.mountIn(loans, loansRoot);
                });
            });
            tx.mountIn(feed, feedRoot);

            KayaApp.Widget archiveRoot = tx.column(() -> {
                tx.label(visits); // label#1
            });
            tx.mountIn(archive, archiveRoot);
            return visits;
        });

        app.dispatchLoop();
    }

    private Sections() {}
}
