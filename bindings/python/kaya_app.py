"""kaya's idiomatic surface for Python: the structural core.

Three jobs, layered over the runtime (kaya) and the generated wire
vocabulary (kaya_wire):

- id allocation: signals, widgets, collections, and template nodes come
  from per-space counters behind typed handles, so no app hand-numbers
  the four id spaces;
- template scoping: `with tx.for_each(c) as t:` and `with
  tx.when(sig) as t:` bracket the blueprint records, and the nested
  builder allocates from the template-node space — declaring and
  instantiating stay visibly different things;
- occurrence dispatch: handlers register per button (live or template
  node); the app loop routes each click, unpacking the stamped copy's
  key path into handler arguments. The core never calls into the guest
  — dispatch runs on the app thread after it pulls from the ring; the
  no-callback protocol holds.

Per-widget constructors and typed property setters (the generated skin)
arrive when the widget vocabulary grows; until then the structural core
exposes the generic widget(kind) plus the text helpers.

The milestone-2 scene, in this surface:

    app = App()
    with app.build() as tx:
        status = tx.signal("step 0")
        column = tx.widget(KIND_COLUMN)
        step = tx.widget(KIND_BUTTON)
        tx.set_text(step, "step")
        ...
        tx.mount(column)

    @app.on_click(step)
    def _(tx):
        tx.write(status, "clicked")

    sys.exit(app.run())
"""

import threading

import kaya
import kaya_wire as wire


class Signal:
    def __init__(self, id):
        self.id = id


class Widget:
    """A live widget: exactly one thing on screen."""

    def __init__(self, id):
        self.id = id


class Node:
    """A template node: a blueprint entry, stamped per collection entry.
    Never on screen by itself; clicks on its copies arrive with the
    copy's key path."""

    def __init__(self, id):
        self.id = id


class Collection:
    def __init__(self, id):
        self.id = id


class _Builder:
    """Declaration ops shared by the live zone (Tx) and template scopes
    (Tpl); the subclass decides which id space widgets come from."""

    def __init__(self, app, records):
        self._app = app
        self._records = records

    def _make_widget(self):
        raise NotImplementedError

    def widget(self, kind):
        handle = self._make_widget()
        self._records.append(wire.tx_create_widget(handle.id, kind))
        return handle

    def set_text(self, widget, text):
        self._records.append(wire.tx_set_text(widget.id, text))

    def bind_text(self, widget, signal):
        self._records.append(wire.tx_bind_text(widget.id, signal.id))

    def add_child(self, parent, child):
        self._records.append(wire.tx_add_child(parent.id, child.id))

    def collection(self):
        handle = Collection(self._app._next("collection"))
        self._records.append(wire.tx_create_collection(handle.id))
        return handle

    def for_each(self, collection):
        """A For over `collection`; use as `with tx.for_each(c) as t:` —
        the block declares the template. The For itself is `t.node`."""
        return _TplScope(self, wire.tx_create_for, collection.id)

    def when(self, signal):
        """A When over a Bool signal; same scoping as for_each."""
        return _TplScope(self, wire.tx_create_when, signal.id)


class Tx(_Builder):
    """One transaction: everything queued between `with app.build() as
    tx:` entering and exiting applies atomically."""

    def _make_widget(self):
        return Widget(self._app._next("widget"))

    def signal(self, initial):
        handle = Signal(self._app._next("signal"))
        self._records.append(wire.tx_create_signal(handle.id, initial))
        return handle

    def write(self, signal, value):
        self._records.append(wire.tx_write_signal(signal.id, value))

    def insert(self, collection, key, value, path=()):
        self._records.append(
            wire.tx_collection_insert(collection.id, list(path), key, value)
        )

    def update(self, collection, key, value, path=()):
        self._records.append(
            wire.tx_collection_update(collection.id, list(path), key, value)
        )

    def remove(self, collection, key, path=()):
        self._records.append(wire.tx_collection_remove(collection.id, list(path), key))

    def mount(self, root):
        """Mount into the default window; per-window targets arrive with
        the window vocabulary."""
        self._records.append(wire.tx_mount(0, root.id))


class Tpl(_Builder):
    """A template body: the same declaration vocabulary, template-node
    ids, plus element bindings. `node` is the For/When itself."""

    def __init__(self, app, records, node):
        super().__init__(app, records)
        self.node = node

    def _make_widget(self):
        return Node(self._app._next("node"))

    def bind_text_element(self, widget, level=0):
        self._records.append(wire.tx_bind_text_element(widget.id, level))


class _TplScope:
    def __init__(self, parent, opener, target_id):
        self._parent = parent
        self._opener = opener
        self._target_id = target_id

    def __enter__(self):
        app = self._parent._app
        if isinstance(self._parent, Tpl):
            node = Node(app._next("node"))
        else:
            node = Widget(app._next("widget"))
        self._parent._records.append(self._opener(node.id, self._target_id))
        return Tpl(app, self._parent._records, node)

    def __exit__(self, exc_type, exc, tb):
        if exc_type is None:
            self._parent._records.append(wire.tx_template_end())
        return False


class _TxScope:
    def __init__(self, app):
        self._app = app

    def __enter__(self):
        self._tx = Tx(self._app, [])
        return self._tx

    def __exit__(self, exc_type, exc, tb):
        if exc_type is None and self._tx._records:
            kaya.submit(*self._tx._records)
        return False


class App:
    def __init__(self):
        self._counters = {"signal": 0, "widget": 0, "collection": 0, "node": 0}
        self._widget_handlers = {}
        self._node_handlers = {}

    def _next(self, space):
        self._counters[space] += 1
        return self._counters[space]

    def build(self):
        """A transaction scope: `with app.build() as tx:` queues records
        and submits them atomically on exit."""
        return _TxScope(self)

    def on_click(self, target):
        """Register a click handler (decorator). For a live Widget the
        handler receives a fresh Tx; for a template Node it also
        receives the stamped copy's keys, outermost first. The Tx
        auto-submits when the handler returns."""

        def register(fn):
            if isinstance(target, Node):
                self._node_handlers[target.id] = fn
            else:
                self._widget_handlers[target.id] = fn
            return fn

        return register

    def _dispatch_loop(self):
        while occurrence := kaya.next_occurrence():
            ident, keys = occurrence
            if keys:
                handler = self._node_handlers.get(ident)
            else:
                handler = self._widget_handlers.get(ident)
            if handler is None:
                continue
            with self.build() as tx:
                handler(tx, *keys)

    def run(self):
        """Enter the core on the calling thread (must be the process
        main thread), dispatching occurrences on the app thread; returns
        the exit code."""
        app_thread = threading.Thread(target=self._dispatch_loop)
        app_thread.start()
        code = kaya.run()
        app_thread.join()
        return code
