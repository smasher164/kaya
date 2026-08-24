#!/usr/bin/env bash

kaya_flake="$(cd "$(dirname "$0")/.." && cat flake.nix flake.lock | shasum -a 256 | cut -c1-12)"
if [ "${KAYA_DEV_SHELL:-}" != "$kaya_flake" ]; then
    if [ -z "${KAYA_DEV_SHELL:-}" ]; then
        echo "$0: not inside the dev shell — run this under \`nix develop\`" >&2
    else
        echo "$0: dev shell is stale — the flake changed since it was entered; re-enter \`nix develop\`" >&2
    fi
    exit 1
fi
# Compile-check the Java binding and every guest against the real
# desktop KayaRing (bindings/java-desktop). Globbed, not listed: a
# hand-maintained file list here once skipped three scenes silently.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

run_javac() {
    # `javac -version` rather than `command -v`: macOS ships a stub
    # javac that exists on PATH but errors without a JDK installed.
    if javac -version >/dev/null 2>&1; then
        javac "$@"
    else
        nix shell nixpkgs#jdk17 -c javac "$@"
    fi
}

TMP="$(mktemp -d)"
# javac drops a `javac.<stamp>.args` in the CURRENT DIRECTORY on some
# diagnostic paths — measured 2026-08-24 against "method forEach in class
# RowSurface cannot be applied to given types", no crash involved. The
# sources are relative, so the compiler runs at the repo root and the
# debris lands in the working tree; the gate that invoked it takes it
# away, on every exit path.
trap 'rm -rf "$TMP"; rm -f "$ROOT"/javac.*.args' EXIT

# THE NESTED-TABLE EXERCISER, this language's answer to Rust's
# doc-tests (docs/tables-plan.md, dynamic tables). No Java guest
# declares a table inside a row template yet, so without this the
# spelling would ship compiled by nothing. Both surfaces are here: the
# expression form's Tpl and the for-statement form's RowSurface.
mkdir -p "$TMP/probe"
cat >"$TMP/probe/NestedTableCheck.java" <<'PROBE'
import dev.kaya.KayaApp;
import dev.kaya.KayaRecords;

/** A table per row: the header bar declared on a nested For, one sort
 * handler for every stamped copy, and a re-declaration that names ONE
 * copy by its keys. Compiled by tools/java-typecheck.sh, never run. */
public final class NestedTableCheck {
    private static final String[] TITLES = { "Symbol", "Value" };
    private static final KayaRecords.Field<String> CELL = KayaRecords.fieldAt(0);

    /** The expression form: forEach hands back the template node. */
    static void expressionForm(KayaApp app) {
        app.build(tx -> {
            KayaApp.Collection accounts = tx.collection();
            KayaApp.Stamped<KayaApp.Widget, KayaApp.Node> outer =
                    tx.forEach(accounts, account -> {
                        // The nested collection is declared INSIDE the
                        // template scope (the own-scope wall).
                        KayaApp.Collection positions = account.collection();
                        KayaApp.Node table = account.forEach(positions, row -> {
                            row.row(() -> {
                                row.label(CELL);
                                row.label(CELL);
                            });
                        });
                        account.setGrow(table, 1);
                        account.columns(table, TITLES, KayaApp.Sort.none());
                        return table;
                    });
            tx.mount(outer.handle);
            KayaApp.Node table = outer.out;
            // The handler scopes to the For that made it, and the copy's
            // key path comes back with the column, so the re-declaration
            // moves THIS copy's arrow and no sibling's.
            app.onSort(table, (t, keys, column) -> {
                t.columnsAt(table, keys, TITLES, KayaApp.Sort.asc(column));
            });
            return null;
        });
    }

    /** The for-statement form, over the same façade a generated row
     * surface inherits. */
    static void statementForm(KayaApp app) {
        app.build(tx -> {
            KayaApp.Collection accounts = tx.collection();
            KayaApp.Node[] table = new KayaApp.Node[1];
            tx.mount(tx.column(() -> {
                for (KayaApp.Row account : accounts.rows()) {
                    account.label(account.value());
                    KayaApp.Collection positions = account.collection();
                    table[0] = account.forEach(positions, row -> {
                        row.row(() -> {
                            row.label(CELL);
                            row.label(CELL);
                        });
                    });
                    account.columns(table[0], TITLES, KayaApp.Sort.none());
                }
            }));
            app.onSort(table[0], (t, keys, column) -> {
                t.columnsAt(table[0], keys, TITLES, KayaApp.Sort.desc(column));
            });
            return null;
        });
    }

    private NestedTableCheck() {}
}
PROBE

if run_javac -encoding UTF-8 -d "$TMP/classes" \
    bindings/java-desktop/dev/kaya/KayaRing.java \
    bindings/java/dev/kaya/*.java \
    guests/java/dev/kaya/milestone2kt/*.java \
    guests/java-desktop/dev/kaya/milestone2kt/Main.java \
    "$TMP/probe/NestedTableCheck.java"; then
    :
else
    echo "java-typecheck: FAIL"
    exit 1
fi

# ITS NEGATIVE, the compile_fail doc-test's shape: a nested sort handler
# that drops the copy's key path must not compile. Without this the
# exerciser above only proves the surface EXISTS — not that the key path
# is part of the message.
cat >"$TMP/probe/NestedTableDropsPath.java" <<'PROBE'
import dev.kaya.KayaApp;

public final class NestedTableDropsPath {
    static void cannotDropThePath(KayaApp app, KayaApp.Node table) {
        app.onSort(table, (tx, column) -> { });
    }

    private NestedTableDropsPath() {}
}
PROBE

if run_javac -encoding UTF-8 -cp "$TMP/classes" -d "$TMP/rejected" \
        "$TMP/probe/NestedTableDropsPath.java" >"$TMP/rejected.log" 2>&1; then
    echo "java-typecheck: FAIL — a nested onSort that DROPS the stamped copy's" \
        "key path compiled. The handler must take (Tx, List<Object> keys, int" \
        "column): without the keys a re-declaration cannot name the copy that" \
        "was clicked (docs/tables-plan.md)."
    exit 1
fi

echo "java-typecheck: OK"
