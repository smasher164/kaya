package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaWire;

/**
 * The sections scene from the JVM — guests/rust/sections.rs,
 * tools/scenes/sections.steps.
 */
public final class Sections {
    private static final long FEED = 7;
    private static final long ARCHIVE = 8;
    // The SIDEBAR arm rides an AUX WINDOW opened only from the desktop tail's
    // click, so createWindow never runs where the capability is absent.
    private static final long LIBRARY = 1;
    private static final long SHELVES = 2;
    private static final long LOANS = 3;

    private static int visitCount = 0;

    public static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            tx.window(0)
                    .title("sections")
                    .sectionsPresentation(KayaWire.SECTIONS_PRESENTATION_BAR);
            KayaApp.Signal<String> visits = tx.signal("archive: 0 visits");

            // A symbol names a CONCEPT (docs/styling-plan.md D6).
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
