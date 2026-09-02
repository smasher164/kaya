// The feed scene: sum-typed elements, end to end. The list of record
// types IS the sum — `kaya.collection([Note, Todo])` declares one variant
// per member, in that order — and forEach yields the eliminator, one
// `cases.case(Ctor, (el) => ...)` per constructor, held to totality at
// declaration. A patch witnesses the entry's current constructor, and a
// field the constructor lacks throws at the call site.
//
// Build the library first (cargo build), then:
//     KAYA_SELFTEST=feed node guests/js/feed.ts

import * as kaya from "kaya-gui";

const Note = kaya.record({ text: String }, "Note");
const Todo = kaya.record({ title: String, done: Boolean }, "Todo");
type Post = kaya.Fields<typeof Note.schema> | kaya.Fields<typeof Todo.schema>;

const app = new kaya.App();

function doneCountText(items: Map<kaya.Key, Post>): string {
  let n = 0;
  for (const p of items.values()) if (p instanceof Todo && p.done) n += 1;
  return `${n} done`;
}

function onPromote(): void {
  // The MODEL is asked which entry is a Note — never the widgets — and
  // the update's new constructor restamps that key's copy in place.
  for (const [key, post] of feed.items()) {
    if (post instanceof Note) {
      feed.update(key, Todo({ title: post.text, done: true }));
      break;
    }
  }
}

function onToggle(post: kaya.RowHandle<Post>, checked: boolean): void {
  // The instanceof as a guard: a row that has left the collection
  // matches no variant, so a stale occurrence folds into nothing.
  if (post instanceof Todo) post.done = checked;
}

let feed!: kaya.Collection<Post, kaya.Cases>;

app.window(() => {
  feed = kaya.collection([Note, Todo]);
  const doneCount = feed.derive(doneCountText);
  kaya.row(() => {
    kaya.button("promote", { onClick: onPromote });
    kaya.label({ bind: doneCount });
    kaya.forEach(feed, (cases) => {
      cases.case(Note, (note) => {
        kaya.label({ bind: note.text });
      });
      cases.case(Todo, (todo) => {
        kaya.row(() => {
          kaya.checkbox({ checked: todo.done, onToggle });
          kaya.label({ bind: todo.title });
        });
      });
    });
  });
  feed.insert("a", Note({ text: "jot one" }));
  feed.insert("b", Todo({ title: "buy milk", done: false }));
  feed.insert("c", Note({ text: "jot two" }));
});

app.run();
