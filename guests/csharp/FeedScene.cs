// The feed scene from C#: sum-typed elements, end to end. The abstract
// record is the sum, its derived records the constructors; the
// template hands the core a product of typed arms (checked complete at
// declaration, and again by the scene), and handlers eliminate with
// C#'s own pattern matching — a refinement the witnessed UpdateField
// checks rather than trusts, so a stale occurrence folds into nothing.
//
//     KAYA_SELFTEST=feed KAYA_LIB=target/debug/libkaya.dylib \
//         dotnet run --project guests/csharp

using System.Linq;

// The whole scene lives in its own namespace: the one guest binary
// hosts every scene, and todos already owns the bare Todo.
namespace Feed;

// The abstract record is the sum; the derived records its
// constructors, each one's primary constructor its schema. kaya-csgen
// reads this declaration and generates PostKaya: the collection
// factory and the compile-total EachSum eliminator.
[KayaGen]
abstract record Post;
record Note(string Text) : Post;
record Todo(string Title, bool Done) : Post;

static class FeedScene
{
    public static void Run()
    {
        var app = new KayaApp();

        app.Build(tx =>
        {
            var feed = PostKaya.Collection(tx);
            var doneCount = feed.Derive(tx, items =>
                $"{items.Count(e => e.Value is Todo { Done: true })} done");

            tx.Mount(tx.Row(() =>
            {
                tx.Button("promote", t =>
                {
                    // The first note, promoted to a finished todo: the
                    // model is asked which entry is a Note, and the
                    // update's new constructor restamps that key's
                    // copy in place.
                    foreach (var entry in feed.Items(t))
                    {
                        if (entry.Value is Note note)
                        {
                            feed.Update(t, entry.Key, new Todo(note.Text, true));
                            break;
                        }
                    }
                });
                tx.Label(bind: doneCount);
                // The generated eliminator: one required delegate per
                // constructor, so a missing arm is a missing argument
                // — a compile error. The names are named arguments.
                PostKaya.EachSum(tx, feed,
                    note: (t, note) =>
                    {
                        note.Label(t, x => x.Text);
                    },
                    todo: (t, todo) => t.Row(() =>
                    {
                        todo.Checkbox(t, x => x.Done, (t2, keys, isChecked) =>
                        {
                            // The generated refined patch: ?. is the
                            // refinement, re-eliminated at write time
                            // (a stale occurrence folds into null),
                            // and the update stays witnessed
                            // underneath.
                            PostKaya.AsTodo(t2, feed, keys[0])?.Done(isChecked);
                        });
                        todo.Label(t, x => x.Title);
                    }));
            }));

            feed.Insert(tx, "a", new Note("jot one"));
            feed.Insert(tx, "b", new Todo("buy milk", false));
            feed.Insert(tx, "c", new Note("jot two"));
        });

        System.Environment.Exit(app.Run());
    }
}
