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
 * (DESIGN.md, Clipboard; docs/clipboard-plan.md).
 *
 * <p>EVERY ASSERTION CROSSES A PROCESS BOUNDARY, which is the whole
 * design of this scene. kaya's representation set is closed because the
 * LOWERINGS are the hard part — CF_HTML's mandatory offset header,
 * Android's content:// URI for an image, CF_HDROP's double-NUL struct —
 * and a check where kaya reads what kaya wrote parses its own malformed
 * header perfectly happily. That is not merely less coverage: it is a
 * check that cannot fail for the reason the design exists.
 *
 * <p>THE ONE EXCEPTION IS THE CUSTOM FORMAT, deliberately. No stock
 * tool on any platform writes an app-defined type, so the guest copies
 * one and reads it back, with the foreign reader confirming from
 * outside that the bytes really are there under that id.
 *
 * <p>THE IMAGE IS ASSERTED AS A DECODED SIZE, never as bytes: every
 * host re-encodes freely between image types, so a byte count would be
 * a different number on every lane for one picture.
 *
 * <p>Canonical semantics in guests/rust/clipboard.rs; the byte-frozen
 * contract in tools/scenes/clipboard.steps.
 */
final class Clipboard {
    private Clipboard() {}

    /**
     * A 4x4 PNG, spelled out rather than generated: the scene asserts
     * "4x4" through a foreign decoder, so the picture has to be a real
     * encoded image whose size is knowable from the script. Written to
     * disk for the seeding tool AND handed to copy as bytes — the same
     * picture both ways.
     */
    private static final byte[] PIXEL_PNG = {
        (byte) 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // signature
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR length + type
        0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, // 4 x 4
        0x08, 0x02, 0x00, 0x00, 0x00, 0x26, (byte) 0x93, 0x09, // 8-bit rgb + crc
        0x29, 0x00, 0x00, 0x00, 0x1C, 0x49, 0x44, 0x41, // IDAT length + type
        0x54, 0x18, 0x57, 0x63, (byte) 0xFC, (byte) 0xCF, (byte) 0xC0, (byte) 0xF0,
        (byte) 0x9F, (byte) 0x81, (byte) 0xE1, 0x3F, 0x03, (byte) 0xC3, 0x7F, 0x06,
        (byte) 0x86, (byte) 0xFF, 0x0C, 0x0C, (byte) 0xFF, 0x19, 0x18, (byte) 0xFE,
        0x33, 0x30, 0x00, 0x00, 0x3D, (byte) 0x94, 0x07, (byte) 0xF9,
        (byte) 0x8A, 0x2C, (byte) 0xEA, (byte) 0x84, 0x00, 0x00, 0x00, 0x00, // IEND length
        0x49, 0x45, 0x4E, 0x44, (byte) 0xAE, 0x42, 0x60, (byte) 0x82, // IEND + crc
    };

    /**
     * The app-defined format's id: reverse-DNS and space-free, because
     * it reaches every platform's own registry VERBATIM — a UTI on
     * Apple, RegisterClipboardFormat on Windows, a target atom on X11
     * and Wayland, a MIME type on Android.
     */
    private static final String NOTE_ID = "dev.kaya.note";

    /**
     * NO QUOTES IN THE PAYLOAD, and the reason is the script rather
     * than the clipboard: the step grammar's escapes are \n, \r and \\
     * in all three interpreters, with no \", so a quoted byte could not
     * be spelled in the expectation.
     */
    private static final byte[] NOTE_BYTES = "note=1".getBytes(StandardCharsets.UTF_8);

    static void app() {
        KayaApp app = new KayaApp();

        // TMPDIR FIRST, AND JAVA IS THE ONLY HALF THAT NEEDS SAYING SO.
        // Every other language's "where is temp" honours the TMPDIR
        // environment variable, and so the interpreter and the guest
        // land on the same directory without either consulting the
        // other. Java's `java.io.tmpdir` does NOT: on macOS the JDK
        // sets it from the per-user Darwin temp dir and ignores TMPDIR
        // entirely. Measured by the filedialog scene, the hard way. On
        // Windows there is no TMPDIR and java.io.tmpdir is the right
        // answer, which is why it stays as the fallback.
        String tmp = System.getenv("TMPDIR");
        if (tmp == null || tmp.isEmpty()) {
            tmp = System.getProperty("java.io.tmpdir");
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

            // THE GESTURE LAYER'S DECLARATION, and an app writes nothing
            // else for it: the Paste command lowers to the platform's
            // own, acts on whatever is focused, and works out its own
            // enablement. kaya has no selection API, which is exactly
            // why copy of a selection has to be a command rather than
            // something an app assembles out of the data layer.
            KayaApp.MenuItem edit = win.menu("Edit");
            edit.item("Cut").role(KayaApp.ROLE_CUT);
            edit.item("Copy").role(KayaApp.ROLE_COPY);
            edit.item("Paste").role(KayaApp.ROLE_PASTE);

            KayaApp.Signal<String> status = tx.signal("ready");

            tx.mount(tx.column(() -> {
                tx.label(status).a11yId("status"); // label#0
                tx.button("copy", inner -> { // button#0
                    // ONE CLIP, FOUR REPRESENTATIONS. kaya derives none
                    // of them from any other: whether list bullets
                    // survive html-to-text is this app's decision, so
                    // it spells out both. The order they go on the wire
                    // is kaya's, not this chain's — descending
                    // richness, which is preference order on every host
                    // that has one.
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

                // DECLARES WHAT IT TAKES, so a paste lands in the hook
                // and this app decides what to do with it.
                fields[0] = tx.entry().accepts("text").a11yId("rich"); // entry#0
                app.onPaste(fields[0], (t, clip) -> {
                    // THE SAME SHAPE THE READ ANSWERS WITH, and free
                    // where the read is not: a gesture is its own
                    // authorisation, so no platform charges a prompt.
                    if (clip instanceof KayaApp.Representation.Text text) {
                        t.write(status, "pasted " + text.value());
                        return;
                    }
                    t.write(status, "pasted " + clip);
                });

                // DECLARES NOTHING, so the platform's own insertion
                // happens and the field's ordinary change path reports
                // it — which is what a plain text editor gets for free.
                fields[1] = tx.entry().a11yId("plain"); // entry#1
            }));
        });

        app.dispatchLoop();
    }

    private static void answered(
            KayaApp app,
            KayaApp.Signal<String> status,
            KayaApp.Tx tx,
            KayaApp.Representation clip) {
        // EMPTY IS THE UNIVERSAL NO, and the guest does not try to tell
        // its four causes apart — denied, unfocused, absent, or nothing
        // this read accepted. The platforms deliberately decline to say.
        if (clip == null) {
            tx.write(status, "empty");
            return;
        }
        // INSTANCEOF PATTERNS RATHER THAN A PATTERN SWITCH: the switch
        // over a sealed interface is a preview feature until JDK 21,
        // and this file is compiled at 17 — by the desktop typecheck
        // and by the Android APK, which shares it.
        if (clip instanceof KayaApp.Representation.Text text) {
            tx.write(status, "text " + text.value());
        } else if (clip instanceof KayaApp.Representation.Html html) {
            tx.write(status, "html " + html.value());
        } else if (clip instanceof KayaApp.Representation.Custom custom) {
            tx.write(status, "custom " + custom.id() + " "
                    + new String(custom.bytes(), StandardCharsets.UTF_8));
        } else if (clip instanceof KayaApp.Representation.Image image) {
            // STRAIGHT BACK OUT, because the assertion that matters is
            // a foreign DECODER's: the byte count differs per host for
            // one picture, and the decoded size does not.
            tx.copy().image(image.bytes()).send();
            tx.write(status, "image");
        } else if (clip instanceof KayaApp.Representation.Files files) {
            if (files.value().isEmpty()) {
                tx.write(status, "files none");
                return;
            }
            KayaApp.PickedFile file = files.value().get(0);
            Thread worker = new Thread(() -> {
                // OFF THE APP THREAD, which is what open documents: it
                // blocks, and a pasted file is no different from a
                // picked one — it IS a picked one, the same capability
                // arriving through a second door.
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
            // The daemon flag matters: a parked non-daemon thread keeps
            // the JVM alive, which never shows on a passing run and
            // turns a FAILING one into a timeout instead of a report.
            worker.setDaemon(true);
            worker.start();
            tx.write(status, "reading");
        }
    }

    /**
     * This process's id, without naming {@code ProcessHandle}.
     *
     * THE SAME FILE IS COMPILED INTO THE ANDROID VALIDATION APK, whose
     * SDK has no {@code java.lang.ProcessHandle} at all — naming it is
     * a compile error there, not a runtime one, so the desktop route
     * has to be reached reflectively. Linux and Android both answer the
     * question directly: {@code /proc/self} is a symlink named by the
     * pid.
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
