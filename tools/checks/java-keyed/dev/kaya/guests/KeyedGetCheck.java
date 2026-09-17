package dev.kaya.guests;

import dev.kaya.KayaApp;
import dev.kaya.KayaRecords;

/**
 * KayaRecords.Collection.get answers the entry a key names, or null for
 * one it does not — and updateField's missing-key refusal, which reads
 * through the same lookup, still names the key. NO NATIVES: every check
 * runs inside one app.build and the build throws its own sentinel before
 * returning, so the transaction rolls back instead of reaching
 * KayaRing.submit (which this exerciser never attaches). Compiled and
 * RUN by tools/java-typecheck.py, in package dev.kaya.guests to reach
 * TodoKaya and Todos.Todo, both package-private.
 */
public final class KeyedGetCheck {
    private static void check(boolean ok, String what) {
        if (!ok) {
            System.out.println("keyed-get: FAIL — " + what);
            System.exit(1);
        }
    }

    private static final class Stop extends RuntimeException {}

    public static void main(String[] args) {
        KayaApp app = new KayaApp();
        try {
            app.build((java.util.function.Consumer<KayaApp.Tx>) tx -> {
                KayaRecords.Collection<Long, Todos.Todo> todos = TodoKaya.collection(tx);
                todos.insert(tx, 1L, new Todos.Todo("first", false));
                todos.insert(tx, 2L, new Todos.Todo("second", true));

                Todos.Todo present = todos.get(tx, 1L);
                check(present != null && present.title().equals("first"),
                        "get(1) did not answer the inserted record: " + present);

                check(todos.get(tx, 9L) == null,
                        "get of a missing key did not answer null");

                boolean refused = false;
                String refusalMessage = "";
                try {
                    todos.updateField(tx, 9L, Todos.Todo::title, "x");
                } catch (IllegalStateException e) {
                    refused = true;
                    refusalMessage = e.getMessage();
                }
                check(refused && refusalMessage.contains("9"),
                        "updateField of a missing key did not refuse naming the key: "
                                + refusalMessage);

                throw new Stop();
            });
        } catch (Stop stop) {
            // Expected: stops the build before it reaches submitIfAny.
        }

        System.out.println("keyed-get: OK — Collection.get answers the inserted "
                + "record for its key and null for a missing one, and updateField's "
                + "missing-key refusal, reading through the same lookup, still names "
                + "the key");
    }

    private KeyedGetCheck() {}
}
