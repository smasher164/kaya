package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;
import dev.kaya.KayaWire;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.function.Supplier;

/**
 * The save conformance scene from the JVM: the ROUND TRIP an editor
 * walks (docs/save-plan.md D5) — open a file, save back to it, save AS a
 * new destination, reopen both. See guests/rust/save.rs and
 * tools/scenes/save.steps.
 *
 * <p>EVERY ASSERTION IS A READ-BACK OFF THE DISK, through the HANDLE
 * and never through {@code localPath}, which is empty on both phones: a
 * write that returned without throwing and landed nowhere is the
 * failure "save" has, and only reopening can see it.
 *
 * <p>THE WORK RUNS OFF THE APP THREAD — open blocks. The workers MUST
 * be daemon threads: a parked non-daemon thread keeps the JVM alive,
 * which never shows on a passing run and turns a FAILING one into a
 * timeout instead of a report.
 *
 * <p>NO EXTENSIONS ON ANY NAME and NO FILTER ON EITHER REQUEST, both
 * deliberately: a save panel hides a known extension per the user's
 * Finder preference, and with {@code allowedContentTypes} set it
 * APPENDS the first allowed extension to an extension-less name —
 * either way the harness would read a name this guest did not ask for,
 * on some machines only.
 */
final class Save {
    private Save() {}

    /**
     * The file the user OPENED and the destination they later NAMED,
     * held as HANDLES: the phones have no re-openable path at all. In
     * an object rather than two locals because a lambda captures
     * values; every access is on the app thread.
     */
    private static final class Handles {
        KayaApp.PickedFile source;
        KayaApp.PickedFile destination;
    }

    static void app() {
        KayaApp app = new KayaApp();

        // The decoy MUST sort before the file the scene opens
        // (docs/traps.md, "Pressing Open with nothing selected still
        // returns a file"), so a backend that skips selection gets the
        // wrong one and fails the byte assertion too.
        Path dir = sceneDir();
        try {
            Files.createDirectories(dir);
            Files.write(dir.resolve("draft"),
                    "first draft".getBytes(StandardCharsets.UTF_8));
            Files.write(dir.resolve("decoy"),
                    "decoy".getBytes(StandardCharsets.UTF_8));
        } catch (IOException e) {
            throw new RuntimeException("failed to make the scene's files", e);
        }

        Handles held = new Handles();

        app.build(tx -> {
            tx.window(0).title("save");
            KayaApp.Signal<String> status = tx.signal("no file");
            tx.mount(tx.column(() -> {
                tx.label(status).a11yId("status"); // label#0
                tx.button("open", inner -> // button#0
                        inner.pickFile()
                                .onResult((t, files) -> {
                                    if (files.isEmpty()) {
                                        // The empty list IS cancel.
                                        t.write(status, "open cancelled");
                                        return;
                                    }
                                    KayaApp.PickedFile file = files.get(0);
                                    held.source = file;
                                    work(app, status,
                                            () -> "opened " + readBack(file));
                                })
                                .show());
                tx.button("save", inner -> { // button#1
                    // Save-back needs no dialog: the handle the user
                    // chose the file with is writable.
                    KayaApp.PickedFile file = held.source;
                    work(app, status,
                            () -> "saved " + writeBack(file, "second draft"));
                });
                tx.button("save as", inner -> // button#2
                        // The suggested name the dialog OPENS with; the
                        // scene types over it.
                        inner.saveFile("copy")
                                .onResult((t, file) -> {
                                    if (file == null) {
                                        // null IS cancel.
                                        t.write(status, "save cancelled");
                                        return;
                                    }
                                    held.destination = file;
                                    work(app, status,
                                            () -> "saved " + writeBack(file, "third draft"));
                                })
                                .show());
                tx.button("reopen", inner -> { // button#3
                    // BOTH, in order: a save that went to the wrong
                    // handle passes every earlier step and fails here.
                    KayaApp.PickedFile first = held.source;
                    KayaApp.PickedFile second = held.destination;
                    work(app, status, () ->
                            "reopened " + readBack(first) + " " + readBack(second));
                });
            }));
        });

        app.dispatchLoop();
    }

    /** Run one file job off the app thread and post the answer back. */
    private static void work(
            KayaApp app, KayaApp.Signal<String> status, Supplier<String> job) {
        Thread worker = new Thread(() -> {
            String text = job.get();
            app.post(tx -> tx.write(status, text));
        }, "save-worker");
        worker.setDaemon(true);
        worker.start();
    }

    /** Read a handle back with Java's own stream API. */
    private static String readBack(KayaApp.PickedFile file) {
        try (KayaApp.Opened opened = file.open(KayaWire.FILE_MODE_READ)) {
            return new String(opened.stream().readAllBytes(), StandardCharsets.UTF_8);
        } catch (IOException e) {
            return "open failed: " + e.getMessage();
        }
    }

    /** Write through a handle and report what the file says AFTERWARDS.
     *
     * <p>FILE_MODE_WRITE truncates, on a picked file and a save
     * destination alike. The stream is closed before the reopen, so the
     * bytes read back are the FILE's and not a buffer's. */
    private static String writeBack(KayaApp.PickedFile file, String bytes) {
        try (KayaApp.Opened opened = file.open(KayaWire.FILE_MODE_WRITE)) {
            opened.sink().write(bytes.getBytes(StandardCharsets.UTF_8));
        } catch (IOException e) {
            // The message reaches the label verbatim: without the
            // core's create, a save destination answers "No such file
            // or directory" here (docs/save-plan.md D1).
            return "save failed: " + e.getMessage();
        }
        return readBack(file);
    }

    /**
     * Where the scene's files live: {@code <temp>/kaya-save-<pid>}, the
     * same directory the interpreter expands
     * {@code $TMP/kaya-save-$PID} to.
     *
     * <p>TMPDIR FIRST, java.io.tmpdir only as the Windows fallback:
     * Java's java.io.tmpdir ignores TMPDIR on macOS (docs/traps.md,
     * "java.io.tmpdir"). THE PHONES USE THE SHARED COLLECTION — a
     * document provider cannot see an app's private storage — and a JVM
     * guest has no cfg(), so Android is detected by the vendor string.
     */
    private static Path sceneDir() {
        String tmp = System.getenv("TMPDIR");
        if (tmp == null || tmp.isEmpty()) {
            tmp = System.getProperty("java.io.tmpdir");
        }
        if (System.getProperty("java.specification.vendor", "")
                .contains("Android")) {
            String ext = System.getenv("EXTERNAL_STORAGE");
            tmp = (ext == null || ext.isEmpty() ? "/sdcard" : ext) + "/Documents";
        }
        return Paths.get(tmp, "kaya-save-" + pid());
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
