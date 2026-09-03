// ONE ID SPACE, Java arm: a template node draws from the WIDGET counter
// (DESIGN.md, Binding conventions). Run from AbortCheck, on ITS app and
// FIRST, so the run starts at 1 — one App per process is KayaApp's own
// rule, so this fixture cannot make one. IN PACKAGE dev.kaya because
// Widget.id and Node.id are package-private.
package dev.kaya;

import java.util.function.Consumer;

public final class IdSpaceCheck {
    private IdSpaceCheck() {}

    public static void run(KayaApp app) {
        long[] ids = new long[4];
        // Pure JVM, this fixture's rule: a mutating transaction may never
        // commit, and a minted id is spent whether or not its tx ships.
        Consumer<KayaApp.Tx> mint = tx -> {
            ids[0] = tx.widget(KayaWire.KIND_LABEL).id;
            KayaApp.Collection entries = tx.collection();
            // The For's own container is a live widget; the node is inside.
            KayaApp.Rows<KayaApp.Widget, KayaApp.Row> rows = tx.rows(entries);
            ids[1] = rows.handle.id;
            for (KayaApp.Row row : rows) {
                ids[2] = row.label("cell").id;
            }
            ids[3] = tx.widget(KayaWire.KIND_LABEL).id;
            throw new RuntimeException("handler bug");
        };
        try {
            app.build(mint);
        } catch (RuntimeException e) {
            if (!"handler bug".equals(e.getMessage())) {
                throw e;
            }
        }
        // THE CONTIGUOUS RUN IS THE ASSERTION, not inequality — a private
        // node counter restarted at 1 sits under the live ids an app has
        // already spent and passes a `!=` while being exactly the defect.
        if (ids[0] != 1 || ids[1] != 2 || ids[2] != 3 || ids[3] != 4) {
            throw new AssertionError("widget/node ids " + ids[0] + "," + ids[1]
                    + "," + ids[2] + "," + ids[3] + " — want 1,2,3,4 from one counter");
        }
    }
}
