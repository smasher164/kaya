package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;
import dev.kaya.KayaWire;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.concurrent.CountDownLatch;

/**
 * The filedialog conformance scene from the JVM — the picker's
 * request/result grammar and the capability it hands back (DESIGN.md,
 * File dialogs). See guests/rust/filedialog.rs and
 * tools/scenes/filedialog.steps.
 *
 * <p>The Java binding builds a {@link java.io.FileDescriptor} from JNI:
 * reflecting into its private field throws on JDK 17 and would force
 * every kaya application to launch with --add-opens
 * (docs/file-dialogs-plan.md §6f).
 *
 * <p>THE READ RUNS OFF THE APP THREAD — open blocks. The worker MUST be
 * a daemon thread: a parked non-daemon thread keeps the JVM alive,
 * which turns a FAILING run into a timeout instead of a report. It
 * parks between reading and posting, so a guest that read inline fails
 * {@code expect label#0 "reading"}.
 */
final class FileDialog {
    private FileDialog() {}

    static void app() {
        KayaApp app = new KayaApp();

        // TMPDIR FIRST, java.io.tmpdir only as the Windows fallback:
        // Java's java.io.tmpdir ignores TMPDIR on macOS
        // (docs/traps.md, "java.io.tmpdir").
        String tmp = System.getenv("TMPDIR");
        if (tmp == null || tmp.isEmpty()) {
            tmp = System.getProperty("java.io.tmpdir");
        }
        // THE PHONE USES THE SHARED COLLECTION, and must: no document
        // provider publishes an app's private storage, so a picker
        // aimed at temp opens on Recent instead — the Clipboard guest
        // draws the same line, for the same reader-outside-the-app
        // reason.
        if (System.getProperty("java.specification.vendor", "")
                .contains("Android")) {
            String ext = System.getenv("EXTERNAL_STORAGE");
            tmp = (ext == null || ext.isEmpty() ? "/sdcard" : ext) + "/Documents";
        }
        Path dir = Paths.get(tmp, "kaya-picked-" + pid());
        try {
            Files.createDirectories(dir);
            // The decoy MUST sort before the picked file (docs/traps.md,
            // "Pressing Open with nothing selected still returns a
            // file"), so a backend that skips selection gets the wrong
            // one and fails the byte assertion too.
            Files.write(dir.resolve("picked.txt"),
                    "picked bytes".getBytes(StandardCharsets.UTF_8));
            Files.write(dir.resolve("decoy.txt"),
                    "decoy".getBytes(StandardCharsets.UTF_8));
        } catch (IOException e) {
            throw new RuntimeException("failed to make the scene's files", e);
        }

        CountDownLatch release = new CountDownLatch(1);

        app.build(tx -> {
            tx.window(0).title("filedialog");
            KayaApp.Signal<String> status = tx.signal("no file");
            tx.mount(tx.column(() -> {
                tx.label(status).a11yId("status"); // label#0
                tx.button("open", inner -> // button#0
                        inner.pickFiles()
                                .filter("Text", "txt")
                                .onResult((t, files) -> picked(app, status, release, t, files))
                                .show());
                tx.button("open one", inner -> // button#1
                        inner.pickFile()
                                .filter("Text", "txt")
                                .onResult((t, files) -> picked(app, status, release, t, files))
                                .show());
                tx.button("release", inner -> release.countDown()); // button#2
            }));
        });

        app.dispatchLoop();
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

    private static void picked(
            KayaApp app,
            KayaApp.Signal<String> status,
            CountDownLatch release,
            KayaApp.Tx tx,
            java.util.List<KayaApp.PickedFile> files) {
        if (files.isEmpty()) {
            // The empty list IS cancel.
            tx.write(status, "cancelled");
            return;
        }
        Thread worker = new Thread(() -> {
            String text;
            try {
                KayaApp.Opened opened = files.get(0).open(KayaWire.FILE_MODE_READ);
                try (InputStream in = opened.stream()) {
                    text = new String(in.readAllBytes(), StandardCharsets.UTF_8);
                }
            } catch (IOException e) {
                text = "open failed: " + e.getMessage();
            }
            // Parks holding the result: work on the app thread could
            // never process the release click, and would deadlock.
            try {
                release.await();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return;
            }
            int count = files.size();
            String read = text;
            app.post(inner -> inner.write(status, count + " " + read));
        }, "filedialog-reader");
        worker.setDaemon(true);
        worker.start();
        // The handler RETURNED without reading.
        tx.write(status, "reading");
    }
}
