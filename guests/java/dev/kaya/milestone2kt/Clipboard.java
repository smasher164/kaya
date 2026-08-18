package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;
import dev.kaya.KayaWire;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

/**
 * The clipboard conformance scene from the JVM — one clip in several
 * representations, and the privileged read that takes one back
 * (DESIGN.md, Clipboard; docs/clipboard-plan.md). Canonical semantics
 * in guests/rust/clipboard.rs; the byte-frozen contract in
 * tools/scenes/clipboard.steps.
 *
 * <p>EVERY ASSERTION CROSSES A PROCESS BOUNDARY: a check where kaya
 * reads what kaya wrote parses its own malformed header happily. The
 * custom format is the one exception, since no stock tool writes an
 * app-defined type.
 *
 * <p>THE IMAGE IS ASSERTED AS A DECODED SIZE, never as bytes: every
 * host re-encodes freely, so a byte count differs per lane for one
 * picture.
 */
final class Clipboard {
    private Clipboard() {}

    /**
     * A 4x4 PNG, spelled out rather than generated: the scene asserts
     * "4x4" through a foreign decoder, so the picture has to be a real
     * encoded image whose size is knowable from the script.
     */
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

    /**
     * The app-defined format's id: reverse-DNS and SPACE-FREE, because
     * it reaches every platform's own registry verbatim (a UTI, a
     * RegisterClipboardFormat name, a target atom, a MIME type).
     */
    private static final String NOTE_ID = "dev.kaya/note";

    /**
     * NO QUOTES IN THE PAYLOAD: the step grammar's escapes are \n, \r
     * and \\ in all three interpreters, with no \", so a quoted byte
     * could not be spelled in the expectation.
     */
    private static final byte[] NOTE_BYTES = "note=1".getBytes(StandardCharsets.UTF_8);

    static void app() {
        KayaApp app = new KayaApp();

        // TMPDIR FIRST, java.io.tmpdir only as the Windows fallback:
        // Java's java.io.tmpdir ignores TMPDIR on macOS
        // (docs/traps.md, "java.io.tmpdir").
        String tmp = System.getenv("TMPDIR");
        if (tmp == null || tmp.isEmpty()) {
            tmp = System.getProperty("java.io.tmpdir");
        }
        // THE PHONES USE THE SHARED COLLECTION, and must: the outside
        // reader is another app, which cannot see this one's cache.
        // The interpreter expands $TMP the same way, so a guest writing
        // to the cache dir instead kills the seed. A JVM guest has no
        // cfg(), so Android is detected by the vendor string.
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

            // kaya has no selection API, which is why copy of a
            // selection has to be a command at all.
            KayaApp.MenuItem edit = win.menu("Edit");
            edit.item("Cut").role(KayaApp.ROLE_CUT);
            edit.item("Copy").role(KayaApp.ROLE_COPY);
            edit.item("Paste").role(KayaApp.ROLE_PASTE);

            KayaApp.Signal<String> status = tx.signal("ready");
            // Declared out here rather than in the column body because
            // the seeding insert below runs AFTER the mount, and a
            // local inside the lambda could not be reached from there.
            KayaApp.Signal<String> rowStatus = tx.signal("");
            KayaApp.Collection notes = tx.collection();

            tx.mount(tx.column(() -> {
                tx.label(status).a11yId("status"); // label#0
                tx.button("copy", inner -> { // button#0
                    // ONE CLIP, FOUR REPRESENTATIONS: kaya derives none
                    // of them from any other, and the wire order is
                    // kaya's rather than this chain's.
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

                // Declares what it takes, so a paste lands in the hook.
                fields[0] = tx.entry().accepts(KayaApp.ACCEPT_TEXT).a11yId("rich"); // entry#0
                app.onPaste(fields[0], (t, clip) -> {
                    if (clip instanceof KayaApp.Representation.Text text) {
                        t.write(status, "pasted " + text.value());
                        return;
                    }
                    t.write(status, "pasted " + clip);
                });

                // Declares nothing, so the platform's own insertion
                // happens and the ordinary change path reports it.
                fields[1] = tx.entry().a11yId("plain"); // entry#1

                // The same two doors on a STAMPED copy. The accept list
                // must be declared on the TEMPLATE: every backend hands
                // the gesture to the platform when the focused widget's
                // accept list is empty, so a node hook without it is
                // registered, dispatched and unable to fire
                // (docs/tpl-props-plan.md §1).
                tx.label(rowStatus).a11yId("row-status"); // label#1
                for (var row : notes.rows()) {
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
            // Seeded after the mount: the copy stamps from a template
            // that is already closed.
            tx.insert(notes, "r1", "");
        });

        app.dispatchLoop();
    }

    private static void answered(
            KayaApp app,
            KayaApp.Signal<String> status,
            KayaApp.Tx tx,
            KayaApp.Representation clip) {
        // EMPTY IS THE UNIVERSAL NO: denied, unfocused, absent or not
        // accepted are indistinguishable, and the platforms decline to
        // say which.
        if (clip == null) {
            tx.write(status, "empty");
            return;
        }
        // INSTANCEOF PATTERNS RATHER THAN A PATTERN SWITCH: switching
        // over a sealed interface is a preview feature until JDK 21,
        // and this file is compiled at 17.
        if (clip instanceof KayaApp.Representation.Text text) {
            tx.write(status, "text " + text.value());
        } else if (clip instanceof KayaApp.Representation.Html html) {
            tx.write(status, "html " + html.value());
        } else if (clip instanceof KayaApp.Representation.Custom custom) {
            tx.write(status, "custom " + custom.id() + " "
                    + new String(custom.bytes(), StandardCharsets.UTF_8));
        } else if (clip instanceof KayaApp.Representation.Image image) {
            // Straight back out, so a foreign DECODER makes the
            // assertion.
            tx.copy().image(image.bytes()).send();
            tx.write(status, "image");
        } else if (clip instanceof KayaApp.Representation.Files files) {
            if (files.value().isEmpty()) {
                tx.write(status, "files none");
                return;
            }
            KayaApp.PickedFile file = files.value().get(0);
            Thread worker = new Thread(() -> {
                // OFF THE APP THREAD: open blocks, and a pasted file is
                // a picked one arriving through a second door.
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
            // The worker MUST be a daemon: a parked non-daemon thread
            // keeps the JVM alive, which never shows on a passing run
            // and turns a FAILING one into a timeout, not a report.
            worker.setDaemon(true);
            worker.start();
            tx.write(status, "reading");
        }
    }

    /**
     * This process's id, without NAMING {@code ProcessHandle}: the same
     * file is compiled into the Android APK, whose SDK has no such
     * class, so naming it is a compile error there. Reached
     * reflectively; /proc/self answers directly on linux and Android.
     */
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
