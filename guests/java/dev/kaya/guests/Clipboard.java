package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaWire;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

/**
 * The clipboard scene from the JVM — guests/rust/clipboard.rs,
 * tools/scenes/clipboard.steps.
 */
public final class Clipboard {
    private Clipboard() {}

    /** A 4x4 PNG: a foreign decoder asserts its size, so this must stay
     * a valid encoded image. */
    private static final byte[] PIXEL_PNG = {
        (byte) 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // signature
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR length + type
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, // 4 x 4
        0x08, 0x02, 0x00, 0x00, 0x00, 0x26, (byte) 0x93, 0x09, // 8-bit rgb + crc
        0x29, 0x00, 0x00, 0x00, 0x14, 0x49, 0x44, 0x41, // IDAT length + type
        0x54, 0x78, (byte) 0xDA, 0x63, (byte) 0xF8, (byte) 0xCF, (byte) 0xC0, 0x00,
        0x47, 0x48, 0x4C, 0x74, (byte) 0xDE, 0x7F, 0x24, 0x00,
        0x00, (byte) 0xD2, 0x6F, 0x17, (byte) 0xE9, 0x51, (byte) 0xBB, 0x23,
        0x2D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
        0x44, (byte) 0xAE, 0x42, 0x60, (byte) 0x82, // IEND + crc
};

    /** Reverse-DNS and SPACE-FREE: this id reaches every platform's own
     * registry verbatim. */
    private static final String NOTE_ID = "dev.kaya/note";

    /** NO QUOTES IN THE PAYLOAD: the step grammar's escapes are \n, \r
     * and \\ in all three interpreters, with no \". */
    private static final byte[] NOTE_BYTES = "note=1".getBytes(StandardCharsets.UTF_8);

    public static void app() {
        KayaApp app = new KayaApp();

        // TMPDIR FIRST: java.io.tmpdir ignores it on macOS (docs/traps.md,
        // "java.io.tmpdir").
        String tmp = System.getenv("TMPDIR");
        if (tmp == null || tmp.isEmpty()) {
            tmp = System.getProperty("java.io.tmpdir");
        }
        // THE PHONES USE THE SHARED COLLECTION: the outside reader is another
        // app. No cfg() in a JVM guest, so Android is the vendor string.
        if (System.getProperty("java.specification.vendor", "")
                .contains("Android")) {
            String ext = System.getenv("EXTERNAL_STORAGE");
            tmp = (ext == null || ext.isEmpty() ? "/sdcard" : ext) + "/Documents";
        }
        Path dir = Paths.get(tmp, "kaya-clip-" + pid());
        try {
            Files.createDirectories(dir);
            Files.write(dir.resolve("pixel.png"), PIXEL_PNG);
            Files.write(dir.resolve("pasted.txt"),
                    "pasted bytes".getBytes(StandardCharsets.UTF_8));
        } catch (IOException e) {
            throw new RuntimeException("failed to make the scene's files", e);
        }

        app.build(tx -> {
            KayaApp.WindowRef win = tx.window(0).title("clipboard");

            KayaApp.MenuItem edit = win.menu("Edit");
            edit.item("Cut").role(KayaApp.ROLE_CUT);
            edit.item("Copy").role(KayaApp.ROLE_COPY);
            edit.item("Paste").role(KayaApp.ROLE_PASTE);

            KayaApp.Signal<String> status = tx.signal("ready");
            KayaApp.Signal<String> rowStatus = tx.signal("");
            KayaApp.Collection notes = tx.collection();

            tx.mount(tx.column(() -> {
                tx.label(status).a11yId("status"); // label#0
                tx.button("copy", inner -> { // button#0
                    inner.copy()
                            .text("kaya clip")
                            .html("<b>kaya</b> clip")
                            .image(PIXEL_PNG)
                            .custom(NOTE_ID, NOTE_BYTES)
                            .send();
                    inner.write(status, "copied");
                });
                tx.button("read custom", inner -> // button#1
                        inner.readClipboard().custom(NOTE_ID)
                                .onResult((t, clip) -> answered(app, status, t, clip))
                                .send());
                tx.button("read text", inner -> // button#2
                        inner.readClipboard().text()
                                .onResult((t, clip) -> answered(app, status, t, clip))
                                .send());
                tx.button("read image", inner -> // button#3
                        inner.readClipboard().image()
                                .onResult((t, clip) -> answered(app, status, t, clip))
                                .send());
                tx.button("read files", inner -> // button#4
                        inner.readClipboard().files()
                                .onResult((t, clip) -> answered(app, status, t, clip))
                                .send());

                KayaApp.Widget[] fields = new KayaApp.Widget[2];
                tx.button("focus rich", inner -> inner.focus(fields[0])); // button#5
                tx.button("focus plain", inner -> inner.focus(fields[1])); // button#6

                fields[0] = tx.entry().accepts(KayaApp.ACCEPT_TEXT).a11yId("rich"); // entry#0
                app.onPaste(fields[0], (t, clip) -> {
                    if (clip instanceof KayaApp.Representation.Text text) {
                        t.write(status, "pasted " + text.value());
                        return;
                    }
                    t.write(status, "pasted " + clip);
                });

                fields[1] = tx.entry().a11yId("plain"); // entry#1

                // The accept list must be declared on the TEMPLATE, or the node
                // hook can never fire (docs/tpl-props-plan.md §1).
                tx.label(rowStatus).a11yId("row-status"); // label#1
                for (var row : tx.rows(notes)) {
                    KayaApp.Node note = row.entry(); // entry#2, one stamped copy
                    row.setAccepts(note, KayaApp.ACCEPT_TEXT);
                    app.onPaste(note, (t, keys, clip) -> {
                        if (clip instanceof KayaApp.Representation.Text text) {
                            t.write(rowStatus,
                                    "row " + keys.get(0) + " pasted " + text.value());
                            return;
                        }
                        t.write(rowStatus, "row " + keys.get(0) + " pasted " + clip);
                    });
                }
            }));
            // Seeded after the mount: the copy stamps from a closed template.
            tx.insert(notes, "r1", "");
        });

        app.dispatchLoop();
    }

    private static void answered(
            KayaApp app,
            KayaApp.Signal<String> status,
            KayaApp.Tx tx,
            KayaApp.Representation clip) {
        if (clip == null) {
            tx.write(status, "empty");
            return;
        }
        // instanceof, not a pattern switch: switching over a sealed interface
        // is preview until JDK 21 and this compiles at 17.
        if (clip instanceof KayaApp.Representation.Text text) {
            tx.write(status, "text " + text.value());
        } else if (clip instanceof KayaApp.Representation.Html html) {
            tx.write(status, "html " + html.value());
        } else if (clip instanceof KayaApp.Representation.Custom custom) {
            tx.write(status, "custom " + custom.id() + " "
                    + new String(custom.bytes(), StandardCharsets.UTF_8));
        } else if (clip instanceof KayaApp.Representation.Image image) {
            // Straight back out, so a foreign DECODER makes the assertion.
            tx.copy().image(image.bytes()).send();
            tx.write(status, "image");
        } else if (clip instanceof KayaApp.Representation.Files files) {
            if (files.value().isEmpty()) {
                tx.write(status, "files none");
                return;
            }
            KayaApp.PickedFile file = files.value().get(0);
            Thread worker = new Thread(() -> {
                // OFF THE APP THREAD: open blocks.
                String text;
                try {
                    KayaApp.Opened opened = file.open(KayaWire.FILE_MODE_READ);
                    try (InputStream in = opened.stream()) {
                        text = new String(in.readAllBytes(), StandardCharsets.UTF_8);
                    }
                } catch (IOException e) {
                    text = "open failed: " + e.getMessage();
                }
                String read = text;
                app.post(t -> t.write(status, "files " + file.name() + " " + read));
            }, "clipboard-reader");
            // The worker MUST be a daemon: a parked non-daemon thread keeps the
            // JVM alive and turns a FAILING run into a timeout.
            worker.setDaemon(true);
            worker.start();
            tx.write(status, "reading");
        }
    }

    /** This process's id, without NAMING {@code ProcessHandle}: the Android
     * SDK has no such class, so naming it is a compile error there. */
    private static long pid() {
        try {
            return Long.parseLong(
                    new java.io.File("/proc/self").getCanonicalFile().getName());
        } catch (Exception noProc) {
            // macOS and Windows have no /proc; ask the JDK.
            try {
                Class<?> handle = Class.forName("java.lang.ProcessHandle");
                Object current = handle.getMethod("current").invoke(null);
                return (Long) handle.getMethod("pid").invoke(current);
            } catch (Exception e) {
                throw new IllegalStateException(
                        "kaya: cannot determine this process's id", e);
            }
        }
    }
}
