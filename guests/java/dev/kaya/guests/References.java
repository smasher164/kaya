package dev.kaya.guests;

import dev.kaya.KayaApp;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

/**
 * The references scene from the JVM — guests/rust/references.rs,
 * tools/scenes/references.steps (docs/restoration-plan.md SR11, SR12): a
 * picked file's durable reference rides the session store across a
 * relaunch and redeems for its bytes; a foreign token and a deleted file
 * are refused by name.
 */
public final class References {
    /** The bytes a token redeems for, or the refusal's branch; the sentence
     * goes to stderr, where the leg log keeps it. */
    private static String readBack(String token) {
        try {
            KayaApp.Redeemed redeemed = KayaApp.redeem(token);
            try (InputStream in = redeemed.file().open(KayaApp.FileMode.READ).stream()) {
                return "redeemed: " + new String(in.readAllBytes(), StandardCharsets.UTF_8);
            }
        } catch (KayaApp.ReferenceException refused) {
            System.err.println("references: " + refused.getMessage());
            return refused.refusal();
        } catch (IOException e) {
            return "open failed: " + e.getMessage();
        }
    }

    public static void app() {
        String tmp = KayaApp.env("TMPDIR");
        if (tmp == null || tmp.isEmpty()) {
            tmp = System.getProperty("java.io.tmpdir");
        }
        // The phone's shared collection, FileDialog.java's reason.
        if (System.getProperty("java.specification.vendor", "").contains("Android")) {
            String ext = KayaApp.env("EXTERNAL_STORAGE");
            tmp = (ext == null || ext.isEmpty() ? "/sdcard" : ext) + "/Documents";
        }
        Path dir = Paths.get(tmp, "kaya-refs-" + FileDialog.pid());
        try {
            Files.createDirectories(dir);
            Files.write(dir.resolve("picked.txt"), "picked bytes".getBytes(StandardCharsets.UTF_8));
            Files.write(dir.resolve("decoy.txt"), "decoy".getBytes(StandardCharsets.UTF_8));
        } catch (IOException e) {
            throw new RuntimeException("failed to make the scene's files", e);
        }

        KayaApp app = new KayaApp();
        KayaApp.SessionHandle session = KayaApp.session();
        String saved = session.getString("doc", "");

        app.build(tx -> {
            tx.window(0).title("references");
            KayaApp.Signal<String> status = tx.signal(saved.isEmpty() ? "no reference" : "redeeming");
            java.util.function.Consumer<String> reader = token -> {
                Thread worker = new Thread(() -> {
                    String said = readBack(token);
                    app.post(inner -> inner.write(status, said));
                }, "references-reader");
                worker.setDaemon(true);
                worker.start();
            };
            tx.mount(tx.column(col -> {
                tx.label(status).a11yId("status");
                tx.button("pick", inner -> app.observe(inner.pickFile()
                        .filter("Text", "txt")
                        .showFuture().thenAccept(files -> app.build(t -> {
                            if (files.isEmpty()) {
                                t.write(status, "cancelled");
                                return;
                            }
                            try {
                                session.setString("doc", files.get(0).reference());
                                session.setString("dir", dir.toString());
                                t.write(status, "minted");
                            } catch (KayaApp.ReferenceException refused) {
                                System.err.println("references: " + refused.getMessage());
                                t.write(status, refused.refusal());
                            }
                        })))).a11yId("pick");
                tx.button("foreign", inner -> reader.accept("kaya-ref1:beos:AAAA:00000000"))
                        .a11yId("foreign");
                tx.button("delete", inner -> {
                    try {
                        Files.deleteIfExists(Paths.get(session.getString("dir", ""), "picked.txt"));
                    } catch (IOException ignored) {
                        // The read below names what is left.
                    }
                    reader.accept(saved);
                }).a11yId("delete");
            }));
            if (!saved.isEmpty()) {
                reader.accept(saved);
            }
        });

        app.dispatchLoop();
    }
}
