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
 * new destination, reopen both.
 *
 * <p>WHAT THIS PROVES ON THIS LANGUAGE, beyond what guests/rust/save.rs
 * proves for every lane: until this milestone the Java binding wrapped
 * EVERY mode's descriptor in a {@code FileInputStream}, so no Java app
 * could write to a file the user picked, on any platform
 * (docs/save-plan.md D3, defect 1). The save-back step below is the
 * first line of Java in the tree that writes through a picked handle,
 * and with the old binding it fails at {@code sink()} before a byte
 * reaches the file.
 *
 * <p>EVERY ASSERTION IS A READ-BACK OFF THE DISK, never what this guest
 * hoped it wrote: each status is the file reopened through the handle
 * kaya gave it and read with an ORDINARY java.io stream. A write that
 * returned without throwing and landed nowhere is exactly the failure
 * "save" has, and only reopening can see it. The reopen is through the
 * HANDLE and never through {@code localPath}, which is empty on both
 * phones.
 *
 * <p>THE WORK RUNS OFF THE APP THREAD, which is what {@code open} tells
 * every caller to do: it blocks, and a cloud provider may download the
 * whole file first. Plain daemon threads, and the answer goes back
 * through {@code post} — kaya supplies no waiting primitive and should
 * not. The daemon flag matters: a parked non-daemon thread keeps the JVM
 * alive, which never shows on a passing run and turns a FAILING one into
 * a timeout instead of a report. The parking dance that PROVES the hop
 * belongs to the filedialog scene and is not repeated here.
 *
 * <p>NO EXTENSIONS ON ANY NAME and NO FILTER ON EITHER REQUEST, both
 * deliberately: a save panel publishes its name field with a known
 * extension hidden per the user's Finder preference, and with
 * {@code allowedContentTypes} set it APPENDS the first allowed extension
 * to an extension-less name — either way the harness would read a name
 * this guest did not ask for, on some machines only.
 *
 * <p>See guests/rust/save.rs and tools/scenes/save.steps.
 */
final class Save {
    private Save() {}

    /**
     * The two capabilities the scene carries: the file the user OPENED
     * and the destination the user later NAMED.
     *
     * <p>Held as HANDLES, never as paths — the phones have no re-openable
     * path at all. Held in an object rather than in two locals because a
     * lambda captures values, and these are written by one handler and
     * read by another; every access below is on the app thread.
     */
    private static final class Handles {
        KayaApp.PickedFile source;
        KayaApp.PickedFile destination;
    }

    static void app() {
        KayaApp app = new KayaApp();

        // The file the scene opens, written before anything is shown,
        // plus the decoy the picker needs: with ONE file in the
        // directory a dialog completes with it when nothing is
        // selected, so `file_choose draft` would pass on a backend that
        // never selected anything. "decoy" sorts first, so that backend
        // gets the WRONG file and its five bytes fail the byte
        // assertion too.
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
                        // NO FILTER, and the save request below carries
                        // none either — see the class note.
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
                    // SAVE-BACK NEEDS NO DIALOG. The user already chose
                    // this file, and the handle they chose it with is
                    // writable — the claim this step exists to drive,
                    // and the one the Java binding used to break for
                    // every app.
                    KayaApp.PickedFile file = held.source;
                    work(app, status,
                            () -> "saved " + writeBack(file, "second draft"));
                });
                tx.button("save as", inner -> // button#2
                        // The suggested name the dialog OPENS with; the
                        // scene types over it, which is what a save
                        // dialog is for.
                        inner.saveFile("copy")
                                .onResult((t, file) -> {
                                    if (file == null) {
                                        // Cancel. Nothing was named, so
                                        // nothing is written and no
                                        // destination is remembered.
                                        t.write(status, "save cancelled");
                                        return;
                                    }
                                    held.destination = file;
                                    work(app, status,
                                            () -> "saved " + writeBack(file, "third draft"));
                                })
                                .show());
                tx.button("reopen", inner -> { // button#3
                    // BOTH, in order: the file that was opened must
                    // still hold the save-back, and the destination must
                    // hold the save-as. A save that went to the wrong
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

    /** Run one file job off the app thread and post what it says into
     * the status signal. */
    private static void work(
            KayaApp app, KayaApp.Signal<String> status, Supplier<String> job) {
        Thread worker = new Thread(() -> {
            String text = job.get();
            app.post(tx -> tx.write(status, text));
        }, "save-worker");
        worker.setDaemon(true);
        worker.start();
    }

    /** Read a handle back through kaya with Java's own stream API. THE
     * READ-BACK IS THE ASSERTION in every step of this scene. */
    private static String readBack(KayaApp.PickedFile file) {
        try (KayaApp.Opened opened = file.open(KayaWire.FILE_MODE_READ)) {
            return new String(opened.stream().readAllBytes(), StandardCharsets.UTF_8);
        } catch (IOException e) {
            return "open failed: " + e.getMessage();
        }
    }

    /** Write through a handle and report what the file says AFTERWARDS.
     *
     * <p>FILE_MODE_WRITE truncates, on a picked file and on a save
     * destination alike — the destination only adds the create. The
     * stream is closed before the reopen, so the bytes read back are the
     * FILE's and not a buffer's. */
    private static String writeBack(KayaApp.PickedFile file, String bytes) {
        try (KayaApp.Opened opened = file.open(KayaWire.FILE_MODE_WRITE)) {
            opened.sink().write(bytes.getBytes(StandardCharsets.UTF_8));
        } catch (IOException e) {
            // THE FAILURE D1 EXISTS TO PREVENT reaches the label
            // verbatim: without the core's create, a save destination
            // answers "No such file or directory" here.
            return "save failed: " + e.getMessage();
        }
        return readBack(file);
    }

    /**
     * Where the scene's files live: {@code <temp>/kaya-save-<pid>}, the
     * same directory the interpreter expands {@code $TMP/kaya-save-$PID}
     * to, with no runner in between (guest and interpreter are one
     * process).
     *
     * <p>TMPDIR FIRST, AND JAVA IS THE ONLY GUEST THAT NEEDS SAYING SO:
     * every other language's "where is temp" honours the TMPDIR
     * environment variable, while Java's {@code java.io.tmpdir} does not
     * — on macOS the JDK sets it from the per-user Darwin temp dir and
     * ignores TMPDIR entirely. On Windows there is no TMPDIR and
     * java.io.tmpdir is the right answer, which is why it stays as the
     * fallback. THE PHONES USE THE SHARED COLLECTION instead, exactly as
     * guests/rust/save.rs does: a document provider cannot see an app's
     * private storage. A JVM guest has no cfg(), so Android is detected
     * by the specification vendor.
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
}
