package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;
import dev.kaya.KayaRecords;
import dev.kaya.KayaSums;

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
    /** The sealed interface is the sum; the records its constructors. */
    sealed interface Post permits Note, Todo {}

    record Note(String text) implements Post {}

    record Todo(String title, boolean done) implements Post {}

    static void app() {
        KayaApp app = new KayaApp();

        app.build(tx -> {
            KayaSums.SumCollection<String, Post> feed =
                    KayaSums.sumOf(tx, Post.class, Note.class, Todo.class);
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
                    KayaSums.eachSum(tx, feed,
                            feed.arm(Note.class, (t, note) -> {
                                note.label(t, Note::text);
                            }),
                            feed.arm(Todo.class, (t, todo) -> {
                                t.row(
                                        todo.checkbox(t, Todo::done,
                                                (KayaApp.Tx t2, String key, boolean checked) -> {
                                                    // instanceof is the refinement;
                                                    // updateField witnesses it.
                                                    if (feed.get(t2, key) instanceof Todo) {
                                                        feed.updateField(t2, key, Todo.class,
                                                                Todo::done, checked);
                                                    }
                                                }),
                                        todo.label(t, Todo::title));
                            }))));

            feed.insert(tx, "a", new Note("jot one"));
            feed.insert(tx, "b", new Todo("buy milk", false));
            feed.insert(tx, "c", new Note("jot two"));
            return null;
        });

        app.dispatchLoop();
    }

    private Feed() {}
}
