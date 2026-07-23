package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;
import dev.kaya.KayaWire;

/**
 * The sections conformance scene from the JVM: two peer roots in the
 * primary window's section set — presentation context, not
 * lifecycle. The archive pane folds onSelected into a visit count,
 * pinning the echo doctrine from both sides: the user's switch emits
 * (the harness drives the real switcher), while the feed button's
 * programmatic selectSection moves the selection silently. The count
 * surviving switch round trips proves retention. See
 * guests/rust/sections.rs and tools/scenes/sections.steps.
 */
final class Sections {
    private static final long FEED = 7;
    private static final long ARCHIVE = 8;

    private static int visitCount = 0;

    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            // One construct carries the window's attributes (the
            // unification rule). The hint is ADVISORY: `bar` is each
            // desktop's horizontal spelling and the phones' physics
            // regardless — no observable rides on it.
            tx.window(0)
                    .title("sections")
                    .sectionsPresentation(KayaWire.SECTIONS_PRESENTATION_BAR);
            KayaApp.Signal<String> visits = tx.signal("archive: 0 visits");

            long feed = tx.addSection(FEED).title("Feed").id();
            long archive = tx.addSection(ARCHIVE)
                    .title("Archive")
                    .onSelected(inner -> {
                        visitCount++;
                        inner.write(visits, "archive: " + visitCount + " visits");
                    })
                    .id();

            KayaApp.Widget feedRoot = tx.column(() -> {
                KayaApp.Signal<String> ready = tx.signal("feed ready");
                tx.label(ready); // label#0
                tx.button("to archive", inner -> { // button#0
                    // Programmatic selection: configuration, no echo
                    // — onSelected must NOT fire (the scene asserts
                    // the count holds).
                    inner.selectSection(ARCHIVE);
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
