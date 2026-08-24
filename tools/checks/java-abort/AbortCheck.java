// The uniform-abort guard, JVM shape. PURE JVM: no transaction with
// records may ever commit here, because submitIfAny would call into
// KayaRing's natives — so every mutating transaction aborts and the
// committed ones are read-only. That makes it weaker than the desktop
// checks: rollback and propagation are pinned, a shipped post-abort
// commit is not.
//
// Compile and run (from the repo root, inside `nix develop`; javac
// resolution mirrors tools/java-typecheck.sh — the KayaRing stub
// stands in for the Android JNI class):
//   javac -d /tmp/java-abort-check \
//     tools/guest/java-stub/dev/kaya/KayaRing.java \
//     bindings/java/dev/kaya/KayaApp.java \
//     bindings/java/dev/kaya/KayaRecords.java \
//     bindings/java/dev/kaya/KayaSums.java \
//     bindings/java/dev/kaya/KayaWire.java \
//     bindings/java/dev/kaya/KayaGen.java \
//     tools/checks/java-abort/dev/kaya/IdSpaceCheck.java \
//     tools/checks/java-abort/AbortCheck.java
//   java -cp /tmp/java-abort-check AbortCheck

import dev.kaya.KayaApp;
import java.util.function.Consumer;

public final class AbortCheck {
    public static void main(String[] args) {
        // First, on its own app, so the id run starts at 1.
        dev.kaya.IdSpaceCheck.run();

        KayaApp app = new KayaApp();
        KayaApp.Collection[] todos = new KayaApp.Collection[1];

        // Abort mid-transaction after mutating: the boundary must
        // restore the model and rethrow (rollback + propagate is the
        // tx boundary's contract; surviving is the dispatch loop's).
        // A body ending in a throw is value-compatible too, so the
        // Consumer/Function overloads tie; the local pins the shape.
        Consumer<KayaApp.Tx> aborting = tx -> {
            todos[0] = tx.collection();
            tx.insert(todos[0], "a", "one");
            tx.insert(todos[0], "b", "two");
            throw new RuntimeException("handler bug");
        };
        boolean propagated = false;
        try {
            app.build(aborting);
        } catch (RuntimeException e) {
            propagated = "handler bug".equals(e.getMessage());
        }
        if (!propagated) {
            throw new AssertionError(
                    "build swallowed the throw — the tx boundary must propagate");
        }
        app.build(tx -> {
            if (tx.count(todos[0]) != 0 || !tx.items(todos[0]).isEmpty()) {
                throw new AssertionError(
                        "abort did not restore the model: " + tx.count(todos[0]) + " entries");
            }
        });

        // The boundary holds across aborts: a second abandoned
        // transaction leaves the restored model untouched.
        Consumer<KayaApp.Tx> abortingAgain = tx -> {
            tx.insert(todos[0], "c", "three");
            throw new RuntimeException("handler bug");
        };
        propagated = false;
        try {
            app.build(abortingAgain);
        } catch (RuntimeException e) {
            propagated = "handler bug".equals(e.getMessage());
        }
        if (!propagated) {
            throw new AssertionError(
                    "build swallowed the second throw — the tx boundary must propagate");
        }
        app.build(tx -> {
            if (tx.count(todos[0]) != 0) {
                throw new AssertionError(
                        "second abort leaked into the model: " + tx.count(todos[0]) + " entries");
            }
        });

        // The record-time mirror-read guard: while a template body is
        // being declared, the model is off-limits — the template records
        // once and replays, so a read baked into it is dead data.
        // Live-zone and build reads stay legal, pinned below.
        Consumer<KayaApp.Tx> guarded = tx -> {
            for (KayaApp.Row row : tx.rows(todos[0])) {
                row.label(row.value());
                boolean threw = false;
                try {
                    tx.items(todos[0]);
                } catch (IllegalStateException e) {
                    threw = e.getMessage().contains("template body");
                }
                if (!threw) {
                    throw new AssertionError("items() inside a For body did not throw");
                }
                threw = false;
                try {
                    tx.count(todos[0]);
                } catch (IllegalStateException e) {
                    threw = e.getMessage().contains("template body");
                }
                if (!threw) {
                    throw new AssertionError("count() inside a For body did not throw");
                }
            }
            // The When arm: openFors tracks Fors only — when() pushes
            // nothing there — so this pins the counter's When arm.
            KayaApp.Signal<Boolean> visible = tx.signal(true);
            tx.when(visible, t -> {
                boolean threw = false;
                try {
                    tx.items(todos[0]);
                } catch (IllegalStateException e) {
                    threw = e.getMessage().contains("template body");
                }
                if (!threw) {
                    throw new AssertionError("items() inside a When body did not throw");
                }
            });
            // After the scope closes, the same transaction reads again.
            if (tx.count(todos[0]) != 0) {
                throw new AssertionError("read after the template scope closed broken");
            }
            throw new RuntimeException("handler bug");
        };
        propagated = false;
        try {
            app.build(guarded);
        } catch (RuntimeException e) {
            propagated = "handler bug".equals(e.getMessage());
        }
        if (!propagated) {
            throw new AssertionError(
                    "the guard transaction did not abort cleanly");
        }
        // A later build-tx read stays legal (read-only, nothing
        // submits): the guard is template-scope only, never build-wide.
        app.build(tx -> {
            if (tx.count(todos[0]) != 0) {
                throw new AssertionError("build-tx read after the guard broken");
            }
        });

        // The menu surface, JVM shape. The record list is private to the
        // Tx, so record-level emission asserts live in the desktop
        // fixtures; what this pins is guard BEHAVIOR — the chain
        // constructs, the binding's ONE shortcut parser rejects aliases
        // at record time, a context chain rejects shortcuts, and an
        // aborted menu transaction propagates.
        KayaApp.MenuItem[] file = new KayaApp.MenuItem[1];
        Consumer<KayaApp.Tx> menuBuild = tx -> {
            file[0] = tx.window(0).menu("File");
            file[0].item("Save").shortcut("PRIMARY+S").onActivate(t -> { });
            KayaApp.MenuItem sort = tx.window(0).radioGroup("Sort");
            sort.option("Name");
            sort.option("Date");
            sort.value(1);

            boolean menuThrew = false;
            try {
                file[0].item("Bad").shortcut("ctrl+s");
            } catch (IllegalArgumentException e) {
                menuThrew = true;
            }
            if (!menuThrew) {
                throw new AssertionError(
                        "an alias shortcut must die in the binding's one parser");
            }

            menuThrew = false;
            try {
                tx.contextMenu(tx.label("noun")).item("Rename").shortcut("primary+r");
            } catch (IllegalStateException e) {
                menuThrew = e.getMessage().contains("context");
            }
            if (!menuThrew) {
                throw new AssertionError("a context item accepted a shortcut");
            }
            throw new RuntimeException("handler bug");
        };
        propagated = false;
        try {
            app.build(menuBuild);
        } catch (RuntimeException e) {
            propagated = "handler bug".equals(e.getMessage());
        }
        if (!propagated) {
            throw new AssertionError("menu abort: build must propagate");
        }
        // The app continues, and the retained handle reopens through
        // tx.menu (append-at-any-time) in a fresh — again aborting,
        // pure JVM — transaction without tripping the closed-chain
        // guard.
        Consumer<KayaApp.Tx> reopen = tx -> {
            tx.menu(file[0]).item("Publish");
            throw new RuntimeException("handler bug");
        };
        propagated = false;
        try {
            app.build(reopen);
        } catch (RuntimeException e) {
            propagated = "handler bug".equals(e.getMessage());
        }
        if (!propagated) {
            throw new AssertionError("menu reopen: build must propagate");
        }

        System.out.println("java abort check: OK");
    }
}
