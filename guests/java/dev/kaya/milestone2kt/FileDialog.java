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
 * File dialogs).
 *
 * <p>WHAT THIS PROVES, and why it goes all the way to the bytes: the
 * design's whole claim is that kaya hands over a CAPABILITY and never
 * moves the data. So the guest does not assert that a dialog closed —
 * it opens the handle it was given, reads the file with an ORDINARY
 * InputStream, and writes what it read into a signal.
 *
 * <p>JAVA IS THE ONE LANGUAGE WITH NO PUBLIC WAY TO WRAP A DESCRIPTOR,
 * and this scene is what exercises the route that works: the binding
 * builds a {@link java.io.FileDescriptor} from JNI, because reflecting
 * into its private field throws on JDK 17 and would force every kaya
 * application to launch with --add-opens (docs/file-dialogs-plan.md
 * §6f). From here it is an ordinary stream.
 *
 * <p>THE READ RUNS OFF THE APP THREAD, which is what open tells every
 * caller to do: it blocks, and a cloud provider may download the whole
 * file before it returns. The parking is a plain CountDownLatch and the
 * worker a plain DAEMON thread. kaya supplies no waiting primitive and
 * should not: the point is that a guest uses its own language's
 * concurrency and hands back only the result. The daemon flag matters —
 * a parked non-daemon thread keeps the JVM alive, which never shows on
 * a passing run and turns a FAILING one into a timeout instead of a
 * report. The worker PARKS between reading and posting,
 * and only a click releases it, so a guest that read inline is caught
 * by {@code expect label#0 "reading"} and one that did the work on the
 * app thread wedges everything after.
 *
 * <p>See guests/rust/filedialog.rs and tools/scenes/filedialog.steps.
 */
final class FileDialog {
    private FileDialog() {}

    static void app() {
        KayaApp app = new KayaApp();

        // TMPDIR FIRST, AND JAVA IS THE ONLY HALF THAT NEEDS SAYING SO.
        // Every other language's "where is temp" honours the TMPDIR
        // environment variable — Rust's std::env::temp_dir, Python's
        // tempfile.gettempdir, Go's os.TempDir, .NET's
        // Path.GetTempPath — and so the interpreter and the guest land
        // on the same directory without either consulting the other.
        // Java's `java.io.tmpdir` does NOT: on macOS the JDK sets it
        // from the per-user Darwin temp dir and ignores TMPDIR
        // entirely, so this guest wrote its files to /var/folders/...
        // while the picker was aimed at the shell's temp. Measured —
        // the scene's own "does not exist" guard caught it on the first
        // run. On Windows there is no TMPDIR and java.io.tmpdir is the
        // right answer, which is why it stays as the fallback.
        String tmp = System.getenv("TMPDIR");
        if (tmp == null || tmp.isEmpty()) {
            tmp = System.getProperty("java.io.tmpdir");
        }
        Path dir = Paths.get(tmp, "kaya-picked-" + pid());
        try {
            Files.createDirectories(dir);
            // THE DECOY IS LOAD-BEARING: with one file in the
            // directory, pressing Open with nothing selected returns
            // that file, so `file_choose picked.txt` would pass on a
            // backend that ignored the name entirely. Measured on GTK.
            // "decoy" sorts before "picked", so a backend that skips
            // selection gets the WRONG file, and its five bytes fail
            // the byte assertion as well as the name.
            Files.write(dir.resolve("picked.txt"),
                    "picked bytes".getBytes(StandardCharsets.UTF_8));
            Files.write(dir.resolve("decoy.txt"),
                    "decoy".getBytes(StandardCharsets.UTF_8));
        } catch (IOException e) {
            throw new RuntimeException("failed to make the scene's files", e);
        }

        // The release gate: the app thread counts down, the worker
        // awaits. A handler that blocked handing this over would fail
        // the very claim being tested, so countDown does not wait.
        CountDownLatch release = new CountDownLatch(1);

        app.build(tx -> {
            tx.window(0).title("filedialog");
            KayaApp.Signal<String> status = tx.signal("no file");
            tx.mount(tx.column(() -> {
                tx.label(status).a11yId("status"); // label#0
                tx.button("open", inner -> // button#0
                        // ADVISORY on every platform: a default view,
                        // never a guarantee, so a guest still validates
                        // what it got — which is what the read does.
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
     * This process's id, without naming {@code ProcessHandle}.
     *
     * THE SAME FILE IS COMPILED INTO THE ANDROID VALIDATION APK, whose
     * SDK has no {@code java.lang.ProcessHandle} at all — naming it is a
     * compile error there, not a runtime one, so the desktop route has
     * to be reached reflectively. Linux and Android both answer the
     * question directly: {@code /proc/self} is a symlink named by the
     * pid, and resolving it needs nothing special.
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
            // The empty list IS cancel. Nothing to read, so no worker
            // and no release.
            tx.write(status, "cancelled");
            return;
        }
        Thread worker = new Thread(() -> {
            // THE CLAIM, and it is made HERE rather than in the handler
            // on purpose: the handle crossed a thread boundary, and it
            // is redeemed and read with Java's own stream API on the
            // thread that received it. kaya is not in this data path.
            String text;
            try {
                KayaApp.Opened opened = files.get(0).open(KayaWire.FILE_MODE_READ);
                try (InputStream in = opened.stream()) {
                    text = new String(in.readAllBytes(), StandardCharsets.UTF_8);
                }
            } catch (IOException e) {
                text = "open failed: " + e.getMessage();
            }
            // Parks holding the result, standing in for the tail of a
            // slow transfer. Were this work running on the app thread,
            // the release click could never be processed and the whole
            // scene would deadlock — the point.
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
