// The Java arm's IN-PACKAGE fixtures, for the facts whose instruments are
// package-private: ONE ID SPACE (a template node draws from the WIDGET
// counter — DESIGN.md, Binding conventions), and THE ROW'S DOCUMENT
// (docs/rich-text-plan.md §19). Run from AbortCheck, on ITS app, with
// run() FIRST so the id run starts at 1 — one App per process is
// KayaApp's own rule, so this fixture cannot make one. IN PACKAGE
// dev.kaya because Widget.id, Node.id, documentBlob, foldEdit and
// foldRowDocument are all package-private.
package dev.kaya;

import java.util.List;
import java.util.function.Consumer;

public final class IdSpaceCheck {
    private IdSpaceCheck() {}

    /** The probe record: one String field and one Document field, the
     * shape guests/rust/richrows.rs declares. */
    record Note(String title, KayaApp.Document body) {}

    /** A two-run document's field bytes, written from
     * crates/kaya/src/wire.rs's rules ALONE — write_values is
     * {u32 count, u32 0}, write_value is {u32 tag, u32 len, payload}
     * zero-padded to a multiple of 8, VALUE_I64 is 2 and VALUE_STR is
     * 4 — and NOT from this binding's own encoder. Three bindings
     * compare against this same literal. */
    private static final String BLOB_HEX =
            "09000000000000000400000003000000"
            + "48C3A900000000000200000008000000"
            + "00000000000000000200000008000000"
            + "02000000000000000400000004000000"
            + "626F6C64000000000400000004000000"
            + "74727565000000000200000008000000"
            + "02000000000000000200000008000000"
            + "03000000000000000400000004000000"
            + "6C696E6B000000000400000001000000"
            + "7500000000000000";

    private static String hex(byte[] bytes) {
        StringBuilder out = new StringBuilder();
        for (byte b : bytes) {
            out.append(String.format("%02X", b));
        }
        return out.toString();
    }

    private static String spell(List<KayaApp.TextRun> runs) {
        StringBuilder out = new StringBuilder();
        for (KayaApp.TextRun run : runs) {
            if (out.length() > 0) {
                out.append('|');
            }
            out.append(run.start()).append(':').append(run.stop()).append(' ')
                    .append(run.name()).append('=').append(run.value());
        }
        return out.toString();
    }

    /**
     * A STAMPED COPY'S DOCUMENT IS A ROW FIELD, and NO SCENE CAN SEE
     * EITHER HALF: a copy renders the same picture whatever bytes the
     * field holds, and the fold is the app's own mirror of an act the
     * core already applied.
     *
     * <p>PURE JVM, this fixture's rule: nothing here may reach submit,
     * so the whole probe runs inside ONE transaction that throws, and
     * the wire fields are handed in by hand — encodeField would call
     * KayaRing.blobRegister, which is a native.
     */
    public static void rowDocument(KayaApp app) {
        KayaApp.Document doc = new KayaApp.Document("H\u00e9")
                .mark(KayaApp.TextRange.ofBytes(0, 2), "bold", "true")
                .mark(KayaApp.TextRange.ofBytes(2, 3), "link", "u");
        String got = hex(KayaApp.documentBlob(doc));
        if (!got.equals(BLOB_HEX)) {
            throw new AssertionError("a Document field's blob is\n  " + got
                    + "\nand the wire's rules say\n  " + BLOB_HEX);
        }

        // ONE EDIT, through the ONE fold: the live mirror's answer is
        // the row field's answer.
        List<KayaApp.TextRun> marks = List.of(new KayaApp.TextRun(0, 1, "code", "true"));
        KayaApp.Document live = new KayaApp.Document(doc.text(), doc.runs());
        KayaApp.foldEdit(live, 3, 3, "!", marks);

        Consumer<KayaApp.Tx> probe = tx -> {
            KayaApp.Collection c = tx.collectionWithSchema(
                    new int[] {KayaWire.VALUE_STR, KayaWire.VALUE_BLOB});
            KayaApp.Node[] body = new KayaApp.Node[1];
            for (KayaApp.Row row : tx.rows(c)) {
                body[0] = row.textareaRich(KayaRecords.fieldAt(1));
            }
            tx.insertRecordRaw(c, "a", new Note("a", doc), 0,
                    new Object[] {"a", new KayaWire.BlobHandle(1)});

            app.foldRowDocument(body[0].id, List.of("a"),
                    held -> KayaApp.foldEdit(held, 3, 3, "!", marks));
            List<KayaApp.Entry> entries = tx.items(c);
            if (entries.size() != 1) {
                throw new AssertionError("the row-document probe lost its row");
            }
            Note folded = (Note) entries.get(0).value;
            if (!folded.body().text().equals(live.text())) {
                throw new AssertionError("the row field folded to \"" + folded.body().text()
                        + "\", the live mirror to \"" + live.text() + "\"");
            }
            if (!spell(folded.body().runs()).equals(spell(live.runs()))) {
                throw new AssertionError("the row field's runs are "
                        + spell(folded.body().runs()) + ", the live mirror's "
                        + spell(live.runs()));
            }
            if (!folded.title().equals("a")) {
                throw new AssertionError("the fold rewrote a field the act never named");
            }

            // A ROW THAT IS GONE HAS NO FIELD TO FOLD INTO, and that is
            // not a fault.
            app.foldRowDocument(body[0].id, List.of("gone"),
                    held -> KayaApp.foldEdit(held, 0, 0, "x", List.of()));
            if (tx.items(c).size() != 1) {
                throw new AssertionError("folding into a row that is gone invented one");
            }
            throw new RuntimeException("handler bug");
        };
        try {
            app.build(probe);
        } catch (RuntimeException e) {
            if (!"handler bug".equals(e.getMessage())) {
                throw e;
            }
        }
    }

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
