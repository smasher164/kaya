// Tier-1 negative and bookkeeping checks against the real JS binding,
// bindings/python/kaya_app_checks.py's twin. The core is never entered.
//
// RUN IN A WORKER, DELIBERATELY: importing kaya-gui on the main thread
// surrenders it to kaya_run (runtime.ts), so this file spawns itself as
// the app-thread worker and imports the binding there.

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
  // THE IMPLICIT TRANSACTION (docs/js-plan.md §4): one continuation, one
  // batch, committed by a microtask; app.commit() ends one early.
  check("a widget declared outside every scope is refused naming the scope", throws(() => kaya.label("x"), /scene scope.*container/s));
  shipped.length = 0;
  count.set(5);
  count.set(6);
  check("a mutation outside a handler ships nothing until the continuation ends", shipped.length === 0);
  await Promise.resolve();
  check("one continuation is one batch", shipped.length === 1 && shipped[0]!.length === 2);
  shipped.length = 0;
  count.set(7);
  await app.commit();
  count.set(8);
  await Promise.resolve();
  check("await app.commit() ends the batch and the rest is the next one", shipped.length === 2 && shipped[0]!.length === 1 && shipped[1]!.length === 1);
  count.set(9);
  check("a widget cannot ride the implicit transaction", throws(() => kaya.label("x"), /scene scope.*container/s));
  await Promise.resolve();
  shipped.length = 0;
  count.set(10);
  app.build(() => count.set(11));
  check("a scope opened over a pending implicit transaction commits it first", shipped.length === 2 && shipped[0]!.length === 1);
  await Promise.resolve();

  // ------------------------------------------------------- row handles
  // A stamped handler receives the ROW, whose assignment is the patch
  // (docs/js-plan.md §4). The occurrence is packed by hand: the click tag
  // family is ident, path_len, the keys, then the payload.
  function packStamped(kind: number, ident: number, keys: K.Key[], payload: W.WireValue | null): Uint8Array {
    const parts: Uint8Array[] = keys.map((k) => valueBytes(keyOf(k)));
    if (payload !== null) parts.push(valueBytes(payload));
    const body = parts.reduce((n, b) => n + b.length, 0);
    const out = new Uint8Array(24 + body + ((8 - ((24 + body) % 8)) % 8));
    const ov = new DataView(out.buffer);
    ov.setUint32(0, out.length, true);
    ov.setUint16(4, kind, true);
    ov.setBigUint64(8, BigInt(ident), true);
    ov.setUint32(16, keys.length, true);
    let at = 24;
    for (const b of parts) {
      out.set(b, at);
      at += b.length;
    }
    return out;
  }
  const fire = (app as unknown as { _onOccurrence: (o: W.Occurrence) => void })._onOccurrence.bind(app);
  // Declared without initializers: an initializer would narrow them to
  // null for the rest of the flow, since the assignments are in closures.
  let seen: K.RowHandle<TodoFields> | undefined;
  let box!: K.Widget;
  let seenItem: K.RowHandle<string> | undefined;
  let itemButton!: K.Widget;
  // A template is record time only, so the second For sites live in a
  // scene scope of their own.
  app.window(() => {
    items.insert("z", "zed");
    kaya.column(() => {
      for (const todo of todos) {
        kaya.row(() => {
          box = kaya.checkbox({ checked: todo.done, onToggle: (row: K.RowHandle<TodoFields>, checked: boolean) => { seen = row; row.done = checked; } });
        });
      }
      for (const item of items) {
        itemButton = kaya.button({ bind: item, onClick: (row: K.RowHandle<string>) => { seenItem = row; } });
      }
    });
  });
  shipped.length = 0;
  fire(wire.parse_occurrence(packStamped(wire.OCC_TOGGLED, box.id, [2], false)));
  const viaHandle = shipped.pop()!;
  app.build(() => todos.patch(2, { done: false }));
  const viaPatch = shipped.pop()!;
  check("a stamped handler receives the row, and assigning a field IS the patch", seen !== undefined && seen.key === 2 && viaHandle.length === 1 && JSON.stringify([...viaHandle[0]!]) === JSON.stringify([...viaPatch[0]!]));
  check("the row handle reads the model's copy", seen!.title === todos.get(2)!.title && seen!.exists === true && seen!.path.length === 0);
  check("the row handle is an instance of its record type", (seen as unknown) instanceof Todo && !((seen as unknown) instanceof Note));
  check("a misspelled field on a row handle is refused naming the fields", throws(() => { (seen as unknown as Record<string, unknown>)["donee"] = true; }, /no field donee.*title, done/s));
  check("the row handle enumerates its fields", JSON.stringify(Object.keys(seen!)) === JSON.stringify(["title", "done"]) && "done" in seen!);
  app.build(() => todos.remove(2));
  check("a row that left the collection reads undefined and exists false", seen!.exists === false && seen!.done === undefined);
  fire(wire.parse_occurrence(packStamped(wire.OCC_BUTTON_CLICKED, itemButton.id, ["z"], null)));
  check("a scalar row's handle carries value and key", seenItem !== undefined && seenItem.key === "z" && seenItem.value === "zed");
  shipped.length = 0;
  app.build(() => { seenItem!.value = "zee"; });
  check("assigning a scalar row's value is the update", items.get("z") === "zee" && shipped.length === 1);

  // ------------------------------------------------------------ the tag
  let formatted!: K.Signal<string>;
  shipped.length = 0;
  app.build(() => { formatted = kaya.fmt`n=${count} of ${"k"}`; });
  const created = shipped.pop()!;
  check("kaya.fmt makes a derived string signal over its signals", (formatted as unknown as { _mirror: string })._mirror === "n=11 of k" && created.length === 1);
  app.build(() => count.set(12));
  const wrote = shipped.pop()!;
  check("a formatted signal recomputes when an interpolated signal moves", (formatted as unknown as { _mirror: string })._mirror === "n=12 of k" && wrote.length === 2);
  check("fmt refuses a plain call", throws(() => (kaya.fmt as unknown as (s: string) => unknown)("x"), /template tag/));
  check("fmt refuses a row's field", throws(() => app.window(() => { kaya.column(() => { for (const todo of todos) { kaya.fmt`${todo.title}`; } }); }), /bound with/));

  // ----------------------------------------------------- promise dialogs
  let promised: Promise<number> | null = null;
  app.build(() => { promised = kaya.showAlert({ title: "t", message: "m", actions: ["A"], cancel: "C" }); });
  const alertId = (app as unknown as { _counters: { alert: number } })._counters.alert;
  const alertBytes = new Uint8Array(24);
  const av = new DataView(alertBytes.buffer);
  av.setUint32(0, 24, true);
  av.setUint16(4, wire.OCC_ALERT_RESULT, true);
  av.setBigUint64(8, BigInt(alertId), true);
  av.setUint32(16, 1, true);
  shipped.length = 0;
  fire(wire.parse_occurrence(alertBytes));
  const choice = await promised!;
  count.set(choice + 100);
  await Promise.resolve();
  // Two records: the write, and the formatted signal above recomputing.
  check("showAlert without onResult is a promise of the choice, and its continuation is a transaction", choice === 1 && shipped.length === 1 && shipped[0]!.length === 2);

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

  // ----------------------------------------------------------- help
  // HELP PACKS THE GENERATED SETTER'S OWN BYTES, in BOTH zones
  // (docs/tooltip-plan.md T1) — compared against wire.ts rather than
  // read field by field, because an expectation copied out of the
  // binding agrees with the binding whatever the prop number does.
  const asBytes = (r: Uint8Array | undefined): string => (r === undefined ? "<absent>" : JSON.stringify([...r]));
  let helpSig!: K.Signal<string>;
  shipped.length = 0;
  app.build(() => {
    helpSig = kaya.signal("Your full name as it appears on the card");
    field.help("Saves the draft to disk");
    field.help(helpSig);
    field.help("");
  });
  const helpRecs = shipped.pop()!;
  check("a live help packs tx_set_help's own bytes", helpRecs.length === 4 && asBytes(helpRecs[1]) === asBytes(wire.tx_set_help(field.id, "Saves the draft to disk")));
  check("and a live help from a Signal packs tx_bind_help's", asBytes(helpRecs[2]) === asBytes(wire.tx_bind_help(field.id, helpSig.id)));
  // The root's wall is the one that refuses it (crates/kaya/src/scene.rs,
  // empty_help_dies_at_declare): a binding that dropped it as a no-op
  // would leave the root nothing to refuse.
  check("an empty help passes through for the root's wall", asBytes(helpRecs[3]) === asBytes(wire.tx_set_help(field.id, "")));

  let sourcedHelp!: K.Widget;
  let constHelp!: K.Widget;
  shipped.length = 0;
  app.window(() => {
    kaya.column(() => {
      for (const todo of todos) {
        sourcedHelp = kaya.label({ bind: todo.title }).help(todo.title);
        constHelp = kaya.label({ bind: todo.title }).help("Opened in March");
      }
    });
  });
  const tplRecs = shipped.pop()!;
  check("a stamped help packs tx_bind_help_element's own bytes", tplRecs.some((r) => asBytes(r) === asBytes(wire.tx_bind_help_element(sourcedHelp.id, 0, 0))));
  check("and a constant stamped help packs tx_set_help's", tplRecs.some((r) => asBytes(r) === asBytes(wire.tx_set_help(constHelp.id, "Opened in March"))));

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

  // ------------------------------------------------- the drag surface
  // (docs/dnd-plan.md D1, D3, §4). THE TEMPLATE ZONE: one handle serves
  // both zones, so the declaration is the same chain on a template node
  // — every stamped copy is born with it — and the KEYED form names one
  // copy after its insert.
  const kindOfRec = (r: Uint8Array): number => new DataView(r.buffer, r.byteOffset).getUint16(4, true);
  const firstStr = (r: Uint8Array, at: number): string | null => {
    const view = new DataView(r.buffer, r.byteOffset);
    if (view.getUint32(at + 8, true) !== wire.VALUE_STR) return null;
    const size = view.getUint32(at + 12, true);
    return new TextDecoder().decode(r.subarray(at + 16, at + 16 + size));
  };
  shipped.length = 0;
  let dndNode = 0;
  let dndHandle!: ReturnType<typeof kaya.label>;
  app.window(() => {
    kaya.column(() => {
      for (const _t of todos) {
        dndHandle = kaya
          .label("x")
          .accepts(kaya.ACCEPT_TEXT)
          .draggable({ text: "hi" })
          .dropTarget(kaya.OP_COPY)
          .onDrop(() => {})
          .onDragEnded(() => {});
        dndNode = dndHandle.id;
      }
    });
  });
  check("a template node is a drag source with a CONSTANT payload", (() => {
    const recs = shipped.at(-1)!.filter((r) => kindOfRec(r) === wire.TX_SET_DRAG_SOURCE);
    if (recs.length !== 1) return false;
    const view = new DataView(recs[0]!.buffer, recs[0]!.byteOffset);
    return Number(view.getBigUint64(8, true)) === dndNode && view.getUint32(32, true) === 0;
  })());
  check("a template node is a drop target for every copy", (() => {
    const recs = shipped.at(-1)!.filter((r) => kindOfRec(r) === wire.TX_SET_DROP_TARGET);
    if (recs.length !== 1) return false;
    const view = new DataView(recs[0]!.buffer, recs[0]!.byteOffset);
    return Number(view.getBigUint64(8, true)) === dndNode && view.getUint32(20, true) === 0;
  })());
  // THE REGISTRY IS ADDITIVE ACROSS OCCURRENCE KINDS (docs/traps.md): a
  // node is a drop target AND a drag source, so the second registration
  // must not replace the first.
  check("a node carries a drop handler AND a drag_ended one", (() => {
    const nodes = (app as unknown as { _nodeHandlers: Map<string, unknown> })._nodeHandlers;
    return nodes.has(`${wire.OCC_DROPPED}:${dndNode}`) && nodes.has(`${wire.OCC_DRAG_ENDED}:${dndNode}`);
  })());
  // THE ELEMENT-BOUND PAYLOAD (docs/dnd-plan.md §4, ruled 2026-09-03): a
  // representation IS the row's own field, the way `label({ bind: row.title })`
  // binds — the slot carries `level << 32 | field` and the `bound` mask names
  // it, so every stamped copy resolves its own.
  const valuesOf = (r: Uint8Array, at: number): unknown[] => {
    const count = new DataView(r.buffer, r.byteOffset).getUint32(at, true);
    const out: unknown[] = [];
    let off = at + 8;
    for (let i = 0; i < count; i++) {
      const [v, next] = wire.parse_value(r, off);
      out.push(v);
      off = next;
    }
    return out;
  };
  shipped.length = 0;
  let boundHandle!: ReturnType<typeof kaya.label>;
  let boundField!: K.FieldRef;
  app.window(() => {
    kaya.column(() => {
      for (const t of todos) {
        boundField = t.title as unknown as K.FieldRef;
        boundHandle = kaya.label({ bind: t.title }).draggable({
          text: t.title,
          custom: { "dev.kaya/note": new TextEncoder().encode("note!") },
          operations: [kaya.OP_COPY],
        });
      }
    });
  });
  check("a bound drag payload names its slots in the mask", (() => {
    const recs = shipped.at(-1)!.filter((r) => kindOfRec(r) === wire.TX_SET_DRAG_SOURCE);
    if (recs.length !== 1) return false;
    // Canonical slots: the custom id 0, its bytes 1, then text 2.
    return new DataView(recs[0]!.buffer, recs[0]!.byteOffset).getUint32(36, true) === 1 << 2;
  })());
  check("a bound slot carries level << 32 | field, its neighbours untouched", (() => {
    const recs = shipped.at(-1)!.filter((r) => kindOfRec(r) === wire.TX_SET_DRAG_SOURCE);
    if (recs.length !== 1) return false;
    const values = valuesOf(recs[0]!, 40);
    return values.length === 3 && values[0] === "dev.kaya/note" && values[2] === 0;
  })());
  app.build(() => {
    // A SIGNAL HAS NO ROW: refused by name rather than coerced to a repr
    // on every stamped copy.
    check(
      "a drag payload bound to a signal is refused by name",
      throws(() => kaya.label("x").draggable({ text: kaya.signal("s") as unknown as string }), /cannot be a signal/),
    );
    // THE KEYED FORM NAMES ONE COPY, whose payload is resolved already.
    check(
      "a row's field on the keyed form is refused by name",
      throws(() => boundHandle.draggableAt(["k"], { text: boundField }), /already resolved/),
    );
    // A LIVE WIDGET HAS NO ROW: the field was minted by the tracer above.
    check(
      "a live widget's drag payload cannot bind a row's field",
      throws(() => kaya.label("x").draggable({ text: boundField }), /has no row/),
    );
  });
  // THE KEYED FORM: after the row's insert, one copy by (node, keys).
  shipped.length = 0;
  app.build(() => {
    dndHandle.draggableAt(["y"], { text: "y", operations: [kaya.OP_COPY] });
    dndHandle.dropTargetAt(["y"], kaya.OP_COPY);
  });
  check("draggableAt carries the copy's keys before the payload", (() => {
    const recs = shipped.at(-1)!.filter((r) => kindOfRec(r) === wire.TX_SET_DRAG_SOURCE);
    if (recs.length !== 1) return false;
    return new DataView(recs[0]!.buffer, recs[0]!.byteOffset).getUint32(32, true) === 1 && firstStr(recs[0]!, 40) === "y";
  })());
  check("dropTargetAt carries the copy's keys", (() => {
    const recs = shipped.at(-1)!.filter((r) => kindOfRec(r) === wire.TX_SET_DROP_TARGET);
    if (recs.length !== 1) return false;
    return new DataView(recs[0]!.buffer, recs[0]!.byteOffset).getUint32(20, true) === 1 && firstStr(recs[0]!, 24) === "y";
  })());
  // AND A LIVE WIDGET HAS NO KEYS: the keyed form names one stamped copy.
  app.build(() => {
    check("draggableAt on a live widget is refused by name", throws(() => kaya.label("x").draggableAt(["k"], { text: "hi" }), /names ONE STAMPED COPY/));
    check("dropTargetAt on a live widget is refused by name", throws(() => kaya.label("x").dropTargetAt(["k"], kaya.OP_COPY), /names ONE STAMPED COPY/));
  });
  app.build(() => {
    // LINK AND ASK ARE REFUSED (D3), and the word is named in the refusal.
    check("an operation outside copy and move is refused by name", throws(() => kaya.label("x").draggable({ text: "hi", operations: ["link"] }), /"link" is not a drag operation/));
    shipped.length = 0;
    // AN EMPTY CHAIN WITHDRAWS: no representation, so no operation mask
    // either — which is what a same-app move's removal sends.
    kaya.label("x").draggable();
  });
  check("an empty drag chain withdraws the declaration", (() => {
    const recs = shipped.at(-1)!.filter((r) => new DataView(r.buffer, r.byteOffset).getUint16(4, true) === wire.TX_SET_DRAG_SOURCE);
    if (recs.length !== 1) return false;
    const view = new DataView(recs[0]!.buffer, recs[0]!.byteOffset);
    return view.getUint32(16, true) === 0 && view.getUint32(28, true) === 0;
  })());
  // THE REORDERABLE FOR: the declaration lands on the For's own
  // container, and so does the landing handler (D8).
  shipped.length = 0;
  let dndFor = 0;
  app.window(() => {
    kaya.column(() => {
      for (const _t of todos.rows({ reorderable: true, onDrop: () => {} })) {
        kaya.label("row");
      }
    });
  });
  check("a reorderable For declares set_reorderable on its own container", (() => {
    const recs = shipped.at(-1)!;
    const kindOf = (r: Uint8Array): number => new DataView(r.buffer, r.byteOffset).getUint16(4, true);
    const fors = recs.filter((r) => kindOf(r) === wire.TX_CREATE_FOR);
    const reord = recs.filter((r) => kindOf(r) === wire.TX_SET_REORDERABLE);
    if (fors.length === 0 || reord.length !== 1) return false;
    dndFor = Number(new DataView(fors[0]!.buffer, fors[0]!.byteOffset).getBigUint64(8, true));
    const view = new DataView(reord[0]!.buffer, reord[0]!.byteOffset);
    return Number(view.getBigUint64(8, true)) === dndFor && view.getUint32(16, true) === 1;
  })());
  check("and its landing handler lands in the widget table", (app as unknown as { _widgetHandlers: Map<string, unknown> })._widgetHandlers.has(`${wire.OCC_DROPPED}:${dndFor}`));

  // ------------------------------------------------- the pickers (D2/D10)
  // A PLAIN OBJECT CANNOT BE GIVEN VALIDITY BY A TYPE, so the packing site
  // is the wall: `dateParts`/`timeParts` are the only route onto the wire
  // (a constructor argument, a signal write, a record field) and each
  // refusal names the component (docs/datetime-plan.md D2).
  const PickerTask = kaya.record({ title: String, due: kaya.CivilDate, at: kaya.CivilTime, seq: kaya.Int }, "PickerTask");
  let pickers!: K.Collection<K.Fields<typeof PickerTask.schema>, K.Row<typeof PickerTask.schema>>;
  app.build(() => {
    check("a date picker's month 13 is refused by name", throws(() => kaya.datePicker({ value: { year: 2026, month: 13, day: 1 } }), /month 13, which is not a month/));
    check("February 30 is refused by name", throws(() => kaya.datePicker({ value: { year: 2026, month: 2, day: 30 } }), /day 30, which 2026-02 does not have/));
    check("February 29 stands in a leap year", !throws(() => kaya.datePicker({ value: { year: 2024, month: 2, day: 29 } }), /./));
    check("and falls in a century that is not one", throws(() => kaya.datePicker({ value: { year: 1900, month: 2, day: 29 } }), /day 29, which 1900-02 does not have/));
    check("a date picker's value that is not a civil date is refused by name", throws(() => kaya.datePicker({ value: 20260904 as unknown as K.CivilDate }), /is a civil date \{year, month, day\}/));
    check("a date picker's bound that is not a date is refused by name", throws(() => kaya.datePicker({ value: { year: 2026, month: 9, day: 4 }, min: { year: 2026, month: 0, day: 1 } }), /min_date has month 0/));
    check("a time picker's hour 24 is refused by name", throws(() => kaya.timePicker({ value: { hour: 24, minute: 0 } }), /hour 24, which is not an hour/));
    check("a time picker's minute 60 is refused by name", throws(() => kaya.timePicker({ value: { hour: 10, minute: 60 } }), /minute 60, which is not a minute/));
    pickers = kaya.collection(PickerTask);
  });
  check("a Date field and a Time field take the I64 slot", (() => {
    const spec = (pickers as unknown as { _variants: { schema: number[] }[] })._variants[0]!;
    return JSON.stringify(spec.schema) === JSON.stringify([wire.VALUE_STR, wire.VALUE_I64, wire.VALUE_I64, wire.VALUE_I64]);
  })());
  app.build(() => {
    pickers.insert("a", PickerTask({ title: "a", due: { year: 2026, month: 11, day: 20 }, at: { hour: 9, minute: 5 }, seq: 3 }));
    check("a record's date field is refused by name when it is not one", throws(() => pickers.insert("b", PickerTask({ title: "b", due: { year: 2026, month: 2, day: 30 }, at: { hour: 0, minute: 0 }, seq: 0 })), /PickerTask.due has day 30/));
  });
  check("the model holds the record's own civil date and time", (() => {
    const row = pickers.get("a")!;
    return row.due.year === 2026 && row.due.month === 11 && row.due.day === 20 && row.at.hour === 9 && row.at.minute === 5;
  })());
  // THE TEMPLATE ZONE: an Int field and a CivilDate field share the I64
  // tag, so only the SCHEMA TOKEN can tell them apart.
  app.window(() => {
    kaya.column(() => {
      for (const row of pickers.rows()) {
        check("a template date picker over an Int field is refused by name", throws(() => kaya.datePicker({ value: row.seq }), /binds a kaya.CivilDate field/));
        check("a template time picker over a date field is refused by name", throws(() => kaya.timePicker({ value: row.due }), /binds a kaya.CivilTime field/));
        kaya.datePicker({ value: row.due });
      }
    });
  });

  // ------------------------------------ the slider's numbers and commit
  // (docs/slider-plan.md S1, S2, S5.) The two props must pack as the
  // generated setters do, and value_committed must reach `onCommit`
  // ALONE — one occurrence kind per handler, live and stamped, or a
  // scrub writes the model on every pixel.
  const Track = kaya.record({ name: String, level: Number }, "Track");
  let sliderTracks!: K.Collection<K.Fields<typeof Track.schema>, K.Row<typeof Track.schema>>;
  let bar!: K.Widget;
  let stampedBar!: K.Widget;
  const sliderMoves: number[] = [];
  const sliderCommits: number[] = [];
  const sliderRowCommits: [K.Key, number][] = [];
  shipped.length = 0;
  app.window(() => {
    sliderTracks = kaya.collection(Track);
    kaya.column(() => {
      bar = kaya.slider({
        value: 50, min: 0, max: 100, step: 5, tickSpacing: 25,
        onChange: (v: number) => sliderMoves.push(v),
        onCommit: (v: number) => sliderCommits.push(v),
      });
      for (const track of sliderTracks) {
        stampedBar = kaya.slider({
          value: track.level, min: 0, max: 100, step: 10,
          onCommit: (row: K.RowHandle<K.Fields<typeof Track.schema>>, v: number) => sliderRowCommits.push([row.key, v]),
        });
      }
    });
  });
  const sliderRecords = shipped[0]!.map((r) => JSON.stringify([...r]));
  check("a slider's step packs as the generated setter does", sliderRecords.includes(JSON.stringify([...wire.tx_set_step(bar.id, 5)])));
  check("a slider's tickSpacing packs as the generated setter does", sliderRecords.includes(JSON.stringify([...wire.tx_set_tick_spacing(bar.id, 25)])));
  check("a stamped slider's step packs as the generated setter does", sliderRecords.includes(JSON.stringify([...wire.tx_set_step(stampedBar.id, 10)])));
  app.build(() => { sliderTracks.insert("b", Track({ name: "b", level: 20 })); });
  fire(wire.parse_occurrence(packStamped(wire.OCC_VALUE_COMMITTED, bar.id, [], 35)));
  fire(wire.parse_occurrence(packStamped(wire.OCC_VALUE_CHANGED, bar.id, [], 40)));
  fire(wire.parse_occurrence(packStamped(wire.OCC_VALUE_COMMITTED, stampedBar.id, ["b"], 40)));
  check("a value_committed occurrence reaches onCommit and NOT onChange", JSON.stringify(sliderCommits) === "[35]" && JSON.stringify(sliderMoves) === "[40]");
  check("a stamped value_committed hands the row over first", JSON.stringify(sliderRowCommits) === JSON.stringify([["b", 40]]));

  if (failures.length > 0) {
    console.log(`kaya_app_checks: ${failures.length} FAILED`);
    process.exit(1);
  }
  console.log("kaya_app_checks: OK");
  process.exit(0);
}
