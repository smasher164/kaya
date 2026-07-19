// The uniform-abort guard, JVM shape: the Java runtime is ring-only
// (no desktop native harness), so this check is pure JVM — no
// transaction with records ever commits, because submitIfAny would
// call into KayaRing's natives. Every mutating transaction aborts and
// the committed ones are read-only (empty record list, nothing
// submits), which makes the shape weaker than the desktop checks:
// rollback and propagation are pinned, a shipped post-abort commit is
// not. The dispatch wrapper and the derived registry are private to
// KayaApp, so the boundary test covers the rollback and both stay
// compile-visible only.
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
//     tools/checks/java-abort/AbortCheck.java
//   java -cp /tmp/java-abort-check AbortCheck

import dev.kaya.KayaApp;
import java.util.function.Consumer;

public final class AbortCheck {
    public static void main(String[] args) {
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

        System.out.println("java abort check: OK");
    }
}
