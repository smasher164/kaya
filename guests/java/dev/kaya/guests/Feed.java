package dev.kaya.guests;

import dev.kaya.KayaGen;
import dev.kaya.KayaApp;
import dev.kaya.KayaRecords;

/**
 * The feed scene from the JVM — guests/rust/feed.rs, tools/scenes/feed.steps.
 */
public final class Feed {
    /** The annotation processor reads this and generates PostKaya. */
    @KayaGen(key = "String")
    sealed interface Post permits Note, Todo {}

    record Note(String text) implements Post {}

    record Todo(String title, boolean done) implements Post {}

    public static void app() {
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

            tx.mount(tx.row(() -> {
                tx.button("promote", t -> {
                    for (KayaRecords.Entry<String, Post> entry : feed.items(t)) {
                        if (entry.value instanceof Note note) {
                            feed.update(t, entry.key, new Todo(note.text(), true));
                            break;
                        }
                    }
                });
                tx.label(doneCount);
                PostKaya.eachSum(tx, feed)
                            .note((t, note) -> {
                                note.label(t, Note::text);
                            })
                            .todo((t, todo) -> {
                                t.row(() -> {
                                    todo.checkbox(t, Todo::done,
                                            (KayaApp.Tx t2, String key, boolean checked) -> {
                                                // The refined patch re-eliminates at
                                                // write time: a stale occurrence
                                                // folds into the empty.
                                                PostKaya.asTodo(t2, feed, key)
                                                        .ifPresent(p -> p.done(checked));
                                            });
                                    todo.label(t, Todo::title);
                                });
                            });
            }));

            feed.insert(tx, "a", new Note("jot one"));
            feed.insert(tx, "b", new Todo("buy milk", false));
            feed.insert(tx, "c", new Note("jot two"));
            return null;
        });

        app.dispatchLoop();
    }

    private Feed() {}
}
