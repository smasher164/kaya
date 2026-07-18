package dev.kaya.milestone2kt;

import dev.kaya.KayaGen;
import dev.kaya.KayaApp;
import dev.kaya.KayaRecords;

/**
 * The feed scene from the JVM: sum-typed elements, end to end. The
 * sealed interface is the sum, its permitted records the constructors;
 * the template hands the core a product of typed arms (checked
 * complete at declaration, and again by the scene), and handlers
 * eliminate with instanceof pattern matching — a refinement the
 * witnessed updateField checks rather than trusts, so a stale
 * occurrence folds into nothing.
 */
final class Feed {
    /** The sealed interface is the sum; the records its constructors.
     * The annotation processor reads this declaration and generates
     * PostKaya: the collection factory and the staged eliminator. */
    @KayaGen(key = "String")
    sealed interface Post permits Note, Todo {}

    record Note(String text) implements Post {}

    record Todo(String title, boolean done) implements Post {}

    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            var feed = PostKaya.collection(tx);
            KayaApp.Signal<String> doneCount = feed.derive(tx, items -> {
                int n = 0;
                for (KayaRecords.Entry<String, Post> entry : items) {
                    if (entry.value instanceof Todo todo && todo.done()) {
                        n++;
                    }
                }
                return n + " done";
            });

            tx.mount(tx.row(
                    tx.button("promote", t -> {
                        // The first note, promoted to a finished todo:
                        // the model is asked which entry is a Note,
                        // and the update's new constructor restamps
                        // that key's copy in place.
                        for (KayaRecords.Entry<String, Post> entry : feed.items(t)) {
                            if (entry.value instanceof Note note) {
                                feed.update(t, entry.key, new Todo(note.text(), true));
                                break;
                            }
                        }
                    }),
                    tx.label(doneCount),
                    // The generated staged eliminator: each stage
                    // offers exactly the next constructor's arm, so a
                    // missing arm is a missing method — a compile
                    // error.
                    PostKaya.eachSum(tx, feed)
                            .note((t, note) -> {
                                note.label(t, Note::text);
                            })
                            .todo((t, todo) -> {
                                t.row(
                                        todo.checkbox(t, Todo::done,
                                                (KayaApp.Tx t2, String key, boolean checked) -> {
                                                    // The generated refined patch:
                                                    // the Optional re-eliminates at
                                                    // write time (a stale occurrence
                                                    // folds into the empty), and the
                                                    // update stays witnessed
                                                    // underneath.
                                                    PostKaya.asTodo(t2, feed, key)
                                                            .ifPresent(p -> p.done(checked));
                                                }),
                                        todo.label(t, Todo::title));
                            })));

            feed.insert(tx, "a", new Note("jot one"));
            feed.insert(tx, "b", new Todo("buy milk", false));
            feed.insert(tx, "c", new Note("jot two"));
            return null;
        });

        app.dispatchLoop();
    }

    private Feed() {}
}
