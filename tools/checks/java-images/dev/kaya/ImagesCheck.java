package dev.kaya;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;

/**
 * The Java network images surface (docs/network-images-plan.md N7, N12),
 * run rather than read: patchIf's two drops through the mirror, its one
 * record, its one-statement and thread rules, and RowImages' coalescing,
 * cancellation, error callback and cache. IN PACKAGE dev.kaya so the
 * transaction's records are reachable. Compiled and RUN by
 * tools/java-typecheck.py.
 */
public final class ImagesCheck {
    record Art(String artUrl, byte[] art, KayaApp.ImagePhase phase) {}

    private static void check(boolean ok, String what) {
        if (!ok) {
            System.out.println("images-check: FAIL — " + what);
            System.exit(1);
        }
    }

    @SuppressWarnings("unchecked")
    private static List<byte[]> records(KayaApp.Tx tx) {
        try {
            java.lang.reflect.Field f = KayaApp.Tx.class.getDeclaredField("records");
            f.setAccessible(true);
            return (List<byte[]>) f.get(tx);
        } catch (ReflectiveOperationException e) {
            throw new IllegalStateException(e);
        }
    }

    private static void drainPosted(KayaApp app) throws Exception {
        java.lang.reflect.Method m = KayaApp.class.getDeclaredMethod("drainPosted");
        m.setAccessible(true);
        m.invoke(app);
    }

    private static String thrown(Runnable r) {
        try {
            r.run();
        } catch (IllegalStateException e) {
            return e.getMessage();
        }
        return "";
    }

    public static void main(String[] args) throws Exception {
        String lib = System.getenv("KAYA_LIB");
        if (lib != null) {
            System.load(lib);
        } else {
            System.loadLibrary("kaya");
        }
        KayaRing.attach();

        KayaApp app = new KayaApp();
        KayaApp.claimAppThread();
        @SuppressWarnings("unchecked")
        KayaRecords.Collection<String, Art>[] rows = new KayaRecords.Collection[1];
        @SuppressWarnings("unchecked")
        KayaApp.Signal<String>[] s = new KayaApp.Signal[1];
        app.build((java.util.function.Consumer<KayaApp.Tx>) tx -> {
            rows[0] = KayaRecords.collectionOf(tx, Art.class);
            s[0] = tx.signal("x");
            rows[0].insert(tx, "a", new Art("u/a", new byte[0], KayaApp.ImagePhase.LOADING));
            rows[0].insert(tx, "b", new Art("u/b2", new byte[0], KayaApp.ImagePhase.LOADING));
        });
        KayaRecords.Collection<String, Art> c = rows[0];

        int[] sent = {0};
        app.build((java.util.function.Consumer<KayaApp.Tx>) tx -> {
            c.patchIf(tx, "gone", Art::artUrl, "u/gone").set(Art::art, new byte[] {1})
                    .set(Art::phase, KayaApp.ImagePhase.SHOWN);
            c.patchIf(tx, "b", Art::artUrl, "u/b1").set(Art::art, new byte[] {2})
                    .set(Art::phase, KayaApp.ImagePhase.SHOWN);
            tx.flushPatchIf();
            int before = records(tx).size();
            c.patchIf(tx, "a", Art::artUrl, "u/a").set(Art::art, new byte[] {3})
                    .set(Art::phase, KayaApp.ImagePhase.SHOWN);
            tx.flushPatchIf();
            sent[0] = records(tx).size() - before;
        });
        check(sent[0] == 1, "a two-setter patchIf sent " + sent[0] + " records, want one collection_patch_if");
        app.build((java.util.function.Consumer<KayaApp.Tx>) tx -> {
            check(c.find(tx, "gone").isEmpty(), "a patchIf of a missing row put it in the mirror");
            Art b = c.get(tx, "b");
            check(b.phase() == KayaApp.ImagePhase.LOADING && b.art().length == 0,
                    "a patchIf whose guard moved on wrote the mirror: " + b.phase());
            Art a = c.get(tx, "a");
            check(a.phase() == KayaApp.ImagePhase.SHOWN && a.art().length == 1 && a.art()[0] == 3,
                    "a patchIf whose guard held did not write the mirror: " + a.phase());
        });

        KayaApp.Tx[] held = new KayaApp.Tx[1];
        app.build((java.util.function.Consumer<KayaApp.Tx>) tx -> {
            held[0] = tx;
            c.patchIf(tx, "b", Art::artUrl, "u/b2").set(Art::phase, KayaApp.ImagePhase.FAILED);
        });
        check(records(held[0]).size() == 1,
                "a patchIf that ends its build sent " + records(held[0]).size() + " records, want one");

        String[] late = {""};
        app.build((java.util.function.Consumer<KayaApp.Tx>) tx -> {
            KayaRecords.PatchIf<String, Art> p = c.patchIf(tx, "a", Art::artUrl, "u/a");
            tx.write(s[0], "between");
            late[0] = thrown(() -> p.set(Art::phase, KayaApp.ImagePhase.FAILED));
        });
        check(late[0].contains("one statement"),
                "a set after the chain's record was sent was answered with \"" + late[0] + "\"");

        String[] elsewhere = {""};
        app.build((java.util.function.Consumer<KayaApp.Tx>) tx -> {
            Thread t = new Thread(() -> elsewhere[0] = thrown(() ->
                    c.patchIf(tx, "a", Art::artUrl, "u/a").set(Art::phase, KayaApp.ImagePhase.FAILED)));
            t.start();
            try {
                t.join();
            } catch (InterruptedException e) {
                throw new IllegalStateException(e);
            }
        });
        check(elsewhere[0].contains("belongs to the app thread"),
                "a patchIf from another thread was answered with \"" + elsewhere[0] + "\"");

        // THE HELPER: rows sharing a URL share one fetch, a released row's
        // running fetch is cancelled, a failure is told, a cached URL is
        // written in the same transaction.
        Map<String, Integer> calls = new HashMap<>();
        Map<String, CompletableFuture<byte[]>> futures = new HashMap<>();
        KayaRecords.RowImages.Fetch fetch = url -> {
            calls.merge(url, 1, Integer::sum);
            CompletableFuture<byte[]> f = new CompletableFuture<>();
            futures.put(url, f);
            return f;
        };
        List<String> failed = new ArrayList<>();
        app.build((java.util.function.Consumer<KayaApp.Tx>) tx -> {
            c.insert(tx, "x1", new Art("u/x", new byte[0], KayaApp.ImagePhase.LOADING));
            c.insert(tx, "x2", new Art("u/x", new byte[0], KayaApp.ImagePhase.LOADING));
            c.insert(tx, "bad", new Art("u/bad", new byte[0], KayaApp.ImagePhase.LOADING));
            c.insert(tx, "slow", new Art("u/slow", new byte[0], KayaApp.ImagePhase.LOADING));
        });
        KayaRecords.RowImages<String, Art> images = new KayaRecords.RowImages<>(app, c,
                Art::artUrl, Art::art, Art::phase, fetch)
                .onError((tx, keys, why) -> failed.add(keys.get(0) + ":" + why.getMessage()));
        app.build((java.util.function.Consumer<KayaApp.Tx>) tx -> {
            for (String key : List.of("x1", "x2", "bad", "slow")) {
                images.needed(tx, List.of(key));
            }
        });
        images.released(List.of("slow"));
        check(futures.get("u/slow").isCancelled(),
                "releasing the only row waiting on a running fetch did not cancel it");
        Thread done = new Thread(() -> {
            futures.get("u/x").complete("u/x".getBytes(java.nio.charset.StandardCharsets.UTF_8));
            futures.get("u/bad").completeExceptionally(new java.io.IOException("404"));
        });
        done.start();
        done.join();
        drainPosted(app);
        app.build((java.util.function.Consumer<KayaApp.Tx>) tx -> {
            check(c.get(tx, "x1").phase() == KayaApp.ImagePhase.SHOWN
                            && c.get(tx, "x2").phase() == KayaApp.ImagePhase.SHOWN,
                    "two rows sharing a URL did not both read SHOWN");
            check(c.get(tx, "bad").phase() == KayaApp.ImagePhase.FAILED, "a failed fetch did not write FAILED");
            check(c.get(tx, "slow").phase() == KayaApp.ImagePhase.LOADING,
                    "a released row's cancelled fetch wrote it");
        });
        check(calls.get("u/x") == 1, "two rows sharing a URL made " + calls.get("u/x") + " fetches, want one");
        check(failed.equals(List.of("bad:404")), "the error callback heard " + failed + ", want [bad:404]");
        app.build((java.util.function.Consumer<KayaApp.Tx>) tx -> {
            c.insert(tx, "x3", new Art("u/x", new byte[0], KayaApp.ImagePhase.LOADING));
            images.needed(tx, List.of("x3"));
            check(c.get(tx, "x3").phase() == KayaApp.ImagePhase.SHOWN,
                    "a URL already in the cache was not written in the same transaction");
        });
        check(calls.get("u/x") == 1, "a cached URL was fetched again");
        KayaApp.appThread = null;
        System.out.println("images-check: OK — patchIf drops a missing row and a moved-on guard in the"
                + " mirror, sends one record, refuses a late set and another thread; RowImages shares"
                + " one fetch per URL, cancels a released row's fetch, tells a failure, and serves a"
                + " cached URL in the same transaction");
    }

    private ImagesCheck() {}
}
