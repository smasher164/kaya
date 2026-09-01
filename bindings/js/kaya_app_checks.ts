// Tier-1 negative and bookkeeping checks against the real JS binding,
// bindings/python/kaya_app_checks.py's twin. The core is never entered:
// submits are routed into a list through runtime.hooks and the process
// exits.
//
// RUN IN A WORKER, DELIBERATELY: importing kaya-gui on the main thread
// surrenders it to kaya_run (runtime.ts), so this file spawns itself as
// the app-thread worker and imports the binding there — the shape every
// guest already has, minus the platform loop.

import { Worker, isMainThread } from "node:worker_threads";

// Type-only, so the import is erased and nothing surrenders the main thread.
import type * as K from "./kaya/index.ts";
import type * as W from "./kaya/wire.ts";

if (isMainThread) {
  const worker = new Worker(new URL(import.meta.url), { workerData: { kayaAppThread: true } });
  worker.on("exit", (code) => process.exit(code));
  worker.on("error", (err) => {
    console.error(err);
    process.exit(1);
  });
} else {
  const kaya: typeof K = await import("./kaya/index.ts");
  const runtime = await import("./kaya/runtime.ts");
  const wire: typeof W = kaya.wire;

  const failures: string[] = [];
  function check(name: string, ok: boolean): void {
    console.log((ok ? "PASS " : "FAIL ") + name);
    if (!ok) failures.push(name);
  }
  function throws(fn: () => void, pattern: RegExp): boolean {
    try {
      fn();
      return false;
    } catch (e) {
      return pattern.test(e instanceof Error ? e.message : String(e));
    }
  }

  const shipped: Uint8Array[][] = [];
  runtime.hooks.submit = (records) => shipped.push([...records]);

  const app = new kaya.App();
  const Todo = kaya.record({ title: String, done: Boolean }, "Todo");
  const Note = kaya.record({ text: String }, "Note");
  type TodoFields = K.Fields<typeof Todo.schema>;

  // ---------------------------------------------------------- the scope
  let items!: K.Collection<string, K.Element>;
  let todos!: K.Collection<TodoFields, K.Row<typeof Todo.schema>>;
  let field!: K.Widget;
  let count!: K.Signal<number>;
  const ids: number[] = [];
  app.window(() => {
    const s = kaya.signal(1);
    check("signals expose no read", !("value" in s) && !("get" in s));
    const derived = s.eq(2);
    check("eq derives a boolean signal", derived instanceof kaya.Signal);

    items = kaya.collection();
    check("forEach rejects instance handles", throws(() => kaya.forEach(items.at("g1") as never, () => {}), /drop the \.at/));
    ids.push(kaya.column(() => {
      ids.push(kaya.forEach(items, (el) => {
        check("guard trips in template", throws(() => items.size, /freeze this branch/));
        ids.push(kaya.label({ bind: el }).id);
      }).id);
      const cond = kaya.signal(true);
      ids.push(kaya.when(cond, () => {
        check("guard trips in a When body", throws(() => items.items(), /freeze this branch/));
        ids.push(kaya.label("empty").id);
      }).id);
      field = kaya.entry({});
      ids.push(field.id);
    }).id);
    todos = kaya.collection(Todo);
    count = kaya.signal(0);
    check("a signal's number is an F64 on the wire", (() => {
      const rec = wire.tx_create_signal(99, 0);
      const [v] = wire.parse_value(rec, 16);
      return new DataView(rec.buffer, rec.byteOffset).getUint32(16, true) === wire.VALUE_F64 && v === 0;
    })());
  });
  check("the window scope shipped one transaction", shipped.length === 1);

  // ONE ID SPACE: a template node draws from the WIDGET counter, so the
  // ids minted above form one contiguous run.
  const sorted = [...ids].sort((a, b) => a - b);
  check("one id space for widgets and nodes", sorted.every((id, i) => id === sorted[0]! + i) && ids.length === 6);

  // -------------------------------------------------------- the model
  app.build(() => {
    const k1 = todos.insertFresh(Todo({ title: "a", done: false }));
    const k2 = todos.insertFresh(Todo({ title: "b", done: false }));
    check("insertFresh mints 1, 2", k1 === 1 && k2 === 2);
    todos.insert(7, Todo({ title: "c", done: true }));
    check("an explicit key at or above the counter carries it up", todos.insertFresh(Todo({ title: "d", done: false })) === 8);
    check("a wrong-typed field is refused at insert", throws(() => todos.insert("x", { title: 3, done: false } as unknown as TodoFields), /title is a string field/));
    todos.patch(1, { done: true });
    check("patch mutates the model in place", todos.get(1)!.done === true);
    check("patch refuses a field the record lacks", throws(() => todos.patch(1, { nope: 1 } as unknown as Partial<TodoFields>), /no wire field/));
    todos.moveToFront(8);
    check("moveToFront reorders the mirror", todos.keys()[0] === 8);
    todos.moveAfter(1, 7);
    check("moveAfter reorders the mirror", JSON.stringify(todos.keys()) === JSON.stringify([8, 2, 7, 1]));
    todos.moveToEnd(8);
    check("moveToEnd reorders the mirror", todos.keys().at(-1) === 8);
    check("a move of a missing key throws", throws(() => todos.moveBefore(99, 1), /missing key/));
    todos.change((d) => {
      d.set(2, Todo({ title: "b2", done: true }));
      d.delete(7);
    });
    check("a draft's set updates and delete removes", todos.get(2)!.title === "b2" && !todos.has(7) && todos.size === 3);
  });

  // The key rule, read off the shipped bytes: an integer key is an I64
  // (docs/js-plan.md §4). header 8 + u64 collection 8 + the empty path's
  // values header 8 = the key at 24.
  const inserts = shipped.at(-1)!.filter((r) => new DataView(r.buffer, r.byteOffset).getUint16(4, true) === wire.TX_COLLECTION_INSERT);
  const keyTags = inserts.map((r) => [new DataView(r.buffer, r.byteOffset).getUint32(24, true), wire.parse_value(r, 24)[0]] as const);
  check("an integer key rides as an I64", inserts.length === 4 && keyTags.every(([tag]) => tag === wire.VALUE_I64) && keyTags.some(([, v]) => v === 7));

  // ------------------------------------------------------------ abort
  const before = todos.items().map(([k, v]) => [k, v.title, v.done]);
  const countBefore = shipped.length;
  const dispatch = (app as unknown as { _dispatch: (fn: () => void) => void })._dispatch.bind(app);
  const quiet = console.error;
  console.error = () => {};
  dispatch(() => {
    todos.insertFresh(Todo({ title: "ghost", done: false }));
    count.set(5);
    todos.remove(1);
    throw new Error("abort mid-handler");
  });
  console.error = quiet;
  const after = todos.items().map(([k, v]) => [k, v.title, v.done]);
  check("an abort restores the collection mirror", JSON.stringify(after) === JSON.stringify(before));
  check("an abort restores the signal mirror", (count as unknown as { _mirror: number })._mirror === 0);
  check("an abort ships nothing", shipped.length === countBefore);
  dispatch(() => {
    todos.patch(2, { done: false });
  });
  check("the next dispatch works", shipped.length === countBefore + 1 && todos.get(2)!.done === false);
  check("a spent fresh key stays spent after an abort", (() => {
    let key = 0;
    app.build(() => {
      key = todos.insertFresh(Todo({ title: "e", done: false }));
    });
    return key === 10;
  })());

  // ------------------------------------------------ template discipline
  check("a break leaves the For open and the transaction refuses it", throws(() => {
    app.window(() => {
      kaya.column(() => {
        for (const _t of todos) {
          break;
        }
      });
    });
  }, /template never closed/));
  check("the zone state is reset after the refusal", !throws(() => app.build(() => { kaya.label("live"); }), /./));
  check("a sum's for-of is refused", throws(() => {
    app.window(() => {
      const feed = kaya.collection([Note, Todo]);
      kaya.column(() => {
        for (const _p of feed) {
          /* never */
        }
      });
    });
  }, /case arms/));

  // ----------------------------------------------------------- liveness
  check("no ambient transaction names app.post and the await", throws(() => kaya.label("x"), /app\.post.*first await|first await.*app\.post/s));

  // ------------------------------------------------------------ the sum
  app.build(() => {
    const feed = kaya.collection([Note, Todo]);
    feed.insert("a", Note({ text: "one" }));
    feed.insert("b", Todo({ title: "two", done: false }));
    check("a sum patch witnesses the current constructor", throws(() => feed.patch("a", { done: true } as never), /no wire field/));
    check("a plain object is refused in a sum", throws(() => feed.insert("c", { text: "x" } as never), /not a constructor of this collection's union/));
    check("instanceof tells the variants apart", feed.get("a") instanceof Note && feed.get("b") instanceof Todo);
  });

  // ------------------------------------------------------- size policy
  app.build(() => {
    check("two size policies at once are refused", throws(() => kaya.canvas([10, 10], { fixed: true, onDraw: () => {} }), /ONE size policy/));
  });
  check("a template canvas refuses a size policy by name", throws(() => {
    app.window(() => {
      kaya.column(() => {
        for (const _t of todos) {
          kaya.canvas([10, 10], { fixed: true });
        }
      });
    });
  }, /LIVE-ZONE declaration/));

  // ------------------------------------------------------------ undoable
  app.build(() => {
    kaya.label("x");
    kaya.undoable("step");
    check("a second undoable is refused", throws(() => kaya.undoable("again"), /already an undo group/));
    check("an empty undo label is refused", throws(() => kaya.undoable(""), /needs a name/));
  });
  const last = shipped.at(-1)!;
  check("the undo marker is the batch's first record", new DataView(last[0]!.buffer, last[0]!.byteOffset).getUint16(4, true) === wire.TX_UNDO_GROUP);

  // --------------------------------------------- the empty a11y label
  app.build(() => {
    const n = shipped.length;
    field.a11yLabel("");
    void n;
  });
  check("an empty a11y label passes through for the root's wall", (() => {
    const recs = shipped.at(-1)!;
    return recs.length === 1 && new DataView(recs[0]!.buffer, recs[0]!.byteOffset).getUint16(4, true) === wire.TX_SET_PROPERTY;
  })());

  // ------------------------------------------------- shortcut spelling
  const accept: [string, string][] = [
    ["primary+s", "primary+s"],
    ["PRIMARY+S", "primary+s"],
    ["Primary+Shift+S", "primary+shift+s"],
    ["shift+primary+s", "primary+shift+s"],
    ["alt+shift+f5", "shift+alt+f5"],
    ["ALT+ENTER", "alt+enter"],
    ["primary+alt+0", "primary+alt+0"],
    ["enter", "enter"],
    ["f12", "f12"],
    ["escape", "escape"],
    ["shift+s", "shift+s"],
    ["q", "q"],
  ];
  check("the shortcut canonicalizer accepts the reference table", accept.every(([i, want]) => wire.canonicalize_shortcut(i) === want));
  const reject = ["", "primary + s", " primary+s", "ctrl+s", "cmd+s", "option+p", "primary+primary+s", "primary+", "+s", "primary++s", "primary+s+k", "s+primary", "primary", "primary+esc", "primary+f13", "primary+ss", "primary-s"];
  check("the shortcut canonicalizer rejects the reference table", reject.every((i) => throws(() => wire.canonicalize_shortcut(i), /shortcut/)));

  // ----------------------------------------------------- undo absorption
  // An OCC_UNDONE record built by hand (wire.rs undo_body): window, four
  // run lengths, the label, then one flat values tail — one restored
  // entry and one order.
  function valueBytes(v: W.WireValue): Uint8Array {
    // Borrow the generated encoder through a record whose body is one
    // value: tx_write_signal(id, value) = header(8) + u64(8) + value.
    return wire.tx_write_signal(0, v).subarray(16);
  }
  function packUndo(windowId: number, label: string, entries: [number, K.Key[], K.Key, [number, W.WireValue[]] | null][], orders: [number, K.Key[], K.Key[]][], signals: [number, W.WireValue][]): Uint8Array {
    const flat: W.WireValue[] = [];
    for (const [id, v] of signals) flat.push(new wire.I64(id), v);
    for (const [coll, path, key, state] of entries) {
      const body: W.WireValue[] = [...path.map(keyOf), keyOf(key), ...(state ? state[1] : [])];
      flat.push(new wire.I64(5 + body.length), new wire.I64(coll), new wire.I64(state ? 1 : 0), new wire.I64(state ? state[0] : 0), new wire.I64(path.length), ...body);
    }
    for (const [coll, path, keys] of orders) {
      const body = [...path.map(keyOf), ...keys.map(keyOf)];
      flat.push(new wire.I64(3 + body.length), new wire.I64(coll), new wire.I64(path.length), ...body);
    }
    const parts: Uint8Array[] = [];
    const head = new Uint8Array(24);
    const hv = new DataView(head.buffer);
    hv.setUint32(0, windowId % 4294967296, true);
    hv.setUint32(4, Math.floor(windowId / 4294967296), true);
    hv.setUint32(8, signals.length, true);
    hv.setUint32(12, 0, true);
    hv.setUint32(16, entries.length, true);
    hv.setUint32(20, orders.length, true);
    parts.push(head, valueBytes(label));
    const countHead = new Uint8Array(8);
    new DataView(countHead.buffer).setUint32(0, flat.length, true);
    parts.push(countHead, ...flat.map(valueBytes));
    const body = parts.reduce((n, p) => n + p.length, 0);
    const out = new Uint8Array(8 + body + ((8 - (body % 8)) % 8));
    const ov = new DataView(out.buffer);
    ov.setUint32(0, out.length, true);
    ov.setUint16(4, wire.OCC_UNDONE, true);
    let at = 8;
    for (const p of parts) {
      out.set(p, at);
      at += p.length;
    }
    return out;
  }
  function keyOf(k: K.Key): W.WireValue {
    return typeof k === "number" ? new wire.I64(k) : k;
  }
  const collId = (todos as unknown as { _id: number })._id;
  const onOccurrence = (app as unknown as { _onOccurrence: (o: W.Occurrence) => void })._onOccurrence.bind(app);
  let undoneLabel = "";
  app.build(() => {
    app.window({ onUndone: (label) => { undoneLabel = label; } });
  });
  const restored = packUndo(0, "add e", [[collId, [], 10, null], [collId, [], 2, [0, ["b-restored", true]]]], [[collId, [], [1, 8, 2]]], [[count.id, 42]]);
  onOccurrence(wire.parse_occurrence(restored));
  check("an undo removes the entry the restored state lacks", !todos.has(10));
  check("an undo rewrites a restored entry in place", todos.get(2)!.title === "b-restored" && todos.get(2)!.done === true);
  check("an undo reorders the mirror by the payload's list", JSON.stringify(todos.keys().slice(0, 3)) === JSON.stringify([1, 8, 2]));
  check("an undo moves the signal cache", (count as unknown as { _mirror: number })._mirror === 42);
  check("the onUndone handler fires with the label", undoneLabel === "add e");

  if (failures.length > 0) {
    console.log(`kaya_app_checks: ${failures.length} FAILED`);
    process.exit(1);
  }
  console.log("kaya_app_checks: OK");
  process.exit(0);
}
