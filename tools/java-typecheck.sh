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
# spelling would ship compiled by nothing. Both zones are here: the
# untyped Collection's rows and the generated record surface's.
#
# NO SMUGGLE ANYWHERE IN IT, and that is the point of the shape it
# checks: the nested For is a VALUE the loop is written over, so the
# node its header bar and sort handler name is an ordinary local. The
# callback form could not hand one out of a lambda — this file carried a
# Stamped<Widget, Node> and a one-slot array to get it out.
mkdir -p "$TMP/probe"
cat >"$TMP/probe/NestedTableCheck.java" <<'PROBE'
// IN THE GUESTS' PACKAGE so the generated record surface is in reach:
// the emitted <Rec>Kaya classes are package-private, and the nested
// overload is what this file exists to compile.
package dev.kaya.milestone2kt;

import dev.kaya.KayaApp;
import dev.kaya.KayaRecords;

/** A table per row: the header bar declared on a nested For, one sort
 * handler for every stamped copy, and a re-declaration that names ONE
 * copy by its keys. Compiled by tools/java-typecheck.sh, never run. */
public final class NestedTableCheck {
    private static final String[] TITLES = { "Symbol", "Value" };

    /** The nested For, through the row surface a scalar rows() yields. */
    static void nestedTable(KayaApp app) {
        app.build(tx -> {
            KayaApp.Collection accounts = tx.collection();
            KayaApp.Rows<KayaApp.Widget, KayaApp.Row> outer = tx.rows(accounts);
            for (KayaApp.Row account : outer) {
                account.label(account.value());
                // The nested collection is declared INSIDE the template
                // scope (the own-scope wall).
                KayaApp.Collection positions = account.collection();
                KayaApp.Rows<KayaApp.Node, KayaApp.Row> inner = account.rows(positions);
                for (KayaApp.Row position : inner) {
                    position.row(() -> {
                        position.label(position.value());
                        position.label(position.value());
                    });
                }
                account.setGrow(inner.handle, 1);
                inner.columns(TITLES, KayaApp.Sort.none());
                // The handler scopes to the For that made it, and the
                // copy's key path comes back with the column, so the
                // re-declaration moves THIS copy's arrow and no
                // sibling's.
                app.onSort(inner.handle, (t, keys, column) -> {
                    t.columnsAt(inner.handle, keys, TITLES, KayaApp.Sort.asc(column));
                });
            }
            tx.mount(outer.handle);
            return null;
        });
    }

    /** The same nesting through a GENERATED record surface: the rows
     * value takes the row it is nested in, and hands back that zone's
     * template node.
     *
     * <p>THE COLLECTION IS DECLARED FROM THE ROW, not from the enclosing
     * Tx: a nested collection may only be declared in the template
     * scope, and the zone handle is what says so at the surface rather
     * than by where the call happens to sit (the ledger's
     * nested-record-collection entry). And `at` keeps the element type, so
     * ONE stamped copy's table is filled with records — a
     * KayaApp.Collection there would take a bare Object and the row's
     * named fields would be unreachable. */
    static void nestedRecordTable(KayaApp app) {
        app.build(tx -> {
            KayaApp.Collection accounts = tx.collection();
            for (KayaApp.Row account : tx.rows(accounts)) {
                KayaRecords.Collection<String, Table.TableItem> positions =
                        KayaRecords.collectionOf(account, Table.TableItem.class);
                KayaApp.Rows<KayaApp.Node, TableItemKaya.Row> inner =
                        TableItemKaya.rows(account, positions);
                for (TableItemKaya.Row position : inner) {
                    position.row(() -> {
                        position.label(position.name);
                        position.label(position.size);
                    });
                }
                inner.columns(TITLES, KayaApp.Sort.none());
                app.onSort(inner.handle, (t, keys, column) -> {
                    KayaRecords.Collection<String, Table.TableItem> copy =
                            positions.at(keys.get(0));
                    copy.insert(t, "aapl", new Table.TableItem("AAPL", "10"));
                    copy.updateField(t, "aapl", TableItemKaya.SIZE, "20");
                    t.columnsAt(inner.handle, keys, TITLES, KayaApp.Sort.desc(column));
                });
            }
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
        "was clicked (the tables plan's per-copy identity rule)."
    exit 1
fi

# ITS SIBLING: a rows value carries the handle of the zone it opened in,
# and the TYPE is the wall. A nested For's container is a template Node —
# read as a live Widget it would reach the live onSort, whose handler
# takes no key path, and every stamped copy's header would answer as one.
cat >"$TMP/probe/RowsWrongZone.java" <<'PROBE'
import dev.kaya.KayaApp;

public final class RowsWrongZone {
    static void cannotReadANestedForAsLive(KayaApp.Row account, KayaApp.Collection c) {
        KayaApp.Widget live = account.rows(c).handle;
    }

    private RowsWrongZone() {}
}
PROBE

if run_javac -encoding UTF-8 -cp "$TMP/classes" -d "$TMP/rejected" \
        "$TMP/probe/RowsWrongZone.java" >"$TMP/rejectedzone.log" 2>&1; then
    echo "java-typecheck: FAIL — a NESTED rows value's handle read as a live" \
        "Widget compiled. A For inside a row template declares a template" \
        "node, one stamped container per copy; typing it live would reach the" \
        "live onSort, whose handler has no key path to name a copy with" \
        "(the tables plan's per-copy identity rule)."
    exit 1
fi

echo "java-typecheck: OK"
