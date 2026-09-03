// The feed scene, C# port — guests/rust/feed.rs, tools/scenes/feed.steps.

using System.Linq;

// Its own namespace: one binary hosts every scene and todos owns the bare Todo.
namespace Feed;

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
                PostKaya.EachSum(tx, feed,
                    note: (t, note) =>
                    {
                        note.Label(t, x => x.Text);
                    },
                    todo: (t, todo) => t.Row(() =>
                    {
                        todo.Checkbox(t, x => x.Done, (t2, keys, isChecked) =>
                        {
                            // `?.` re-eliminates at write time: a stale occurrence
                            // folds into null rather than writing the wrong arm.
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
