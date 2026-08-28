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

run_java() {
    if java -version >/dev/null 2>&1; then
        java "$@"
    else
        nix shell nixpkgs#jdk17 -c java "$@"
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

# A RECORD HAS NO SIZE CEILING, and this one is RUN rather than
# compiled — the only clause in this file that is. The encoder's buffer
# was a fixed ByteBuffer.allocate(4096), which capped every java record:
# 4064 characters in any text prop, 252 wire values in a drawing
# (docs/deferred.md, java-record-ceiling). Nothing else in the tree can
# see it — no scene sets a 4KB label, and the ceiling is a THROW, so a
# compile check is blind to it by construction.
mkdir -p "$TMP/big"
cat >"$TMP/big/LargeRecordCheck.java" <<'PROBE'
import dev.kaya.KayaWire;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** Encode past the old ceiling and read it back. The sizes are the
 * MEASURED ones: 4064 characters was the largest text prop the fixed
 * 4096-byte buffer could hold, so 4065 is the first that threw. */
public final class LargeRecordCheck {
    private static void check(boolean ok, String what) {
        if (!ok) {
            System.out.println("large-record: FAIL — " + what);
            System.exit(1);
        }
    }

    private static String text(int chars) {
        StringBuilder sb = new StringBuilder(chars);
        for (int i = 0; i < chars; i++) sb.append((char) ('a' + (i % 26)));
        return sb.toString();
    }

    /** The framing every record shares: a u32 size that IS the length,
     * the kind, and a body padded to 8. */
    private static ByteBuffer framed(byte[] rec, short kind, String what) {
        ByteBuffer b = ByteBuffer.wrap(rec).order(ByteOrder.LITTLE_ENDIAN);
        check(b.getInt(0) == rec.length,
                what + ": size field " + b.getInt(0) + " but " + rec.length + " bytes");
        check(b.getShort(4) == kind, what + ": wrong record kind");
        check(rec.length % 8 == 0, what + ": body not padded to 8");
        return b;
    }

    /** txSetText is {header, u64 widget, u32 prop, u32 source, value}. */
    private static void roundTripText(int chars) {
        String want = text(chars);
        byte[] rec = KayaWire.txSetText(7L, want);
        ByteBuffer b = framed(rec, KayaWire.TX_KIND_SET_PROPERTY, chars + "-char text");
        check(b.getLong(8) == 7L, chars + "-char text: widget id");
        int[] cursor = { 24 };
        Object back = KayaWire.parseValue(rec, b, cursor);
        check(want.equals(back), chars + "-char text: did not round-trip");
        check(cursor[0] == rec.length, chars + "-char text: value did not fill the record");
    }

    public static void main(String[] args) {
        roundTripText(2);
        roundTripText(4064);
        roundTripText(4065);
        roundTripText(100000);

        // {header, u64 widget, value vb_w, value vb_h, u32 count,
        //  u32 path_len, {u32 n, u32 reserved, n values}} — ops from 64.
        int n = 20000;
        Object[] ops = new Object[n];
        for (int i = 0; i < n; i++) ops[i] = (long) i;
        byte[] rec = KayaWire.txSetDrawing(9L, 100.0, 50.0, n, 0, ops);
        ByteBuffer b = framed(rec, KayaWire.TX_KIND_SET_DRAWING, n + "-value drawing");
        check(b.getLong(8) == 9L, "drawing: widget id");
        check(b.getInt(48) == n, "drawing: op count");
        check(b.getInt(52) == 0, "drawing: path_len");
        check(b.getInt(56) == n, "drawing: value count");
        int[] cursor = { 64 };
        for (int i = 0; i < n; i++) {
            Object v = KayaWire.parseValue(rec, b, cursor);
            check(v instanceof Long && (Long) v == i, "drawing: op " + i + " did not round-trip");
        }
        check(cursor[0] == rec.length, "drawing: ops did not fill the record");

        System.out.println("large-record: OK — a " + rec.length + "-byte drawing and a"
                + " 100000-character text prop encoded and round-tripped");
    }

    private LargeRecordCheck() {}
}
PROBE

if run_javac -encoding UTF-8 -cp "$TMP/classes" -d "$TMP/bigclasses" \
        "$TMP/big/LargeRecordCheck.java"; then
    :
else
    echo "java-typecheck: FAIL — the large-record exerciser did not compile."
    exit 1
fi

if run_java -cp "$TMP/classes:$TMP/bigclasses" LargeRecordCheck; then
    :
else
    echo "java-typecheck: FAIL — a record past 4096 bytes did not encode and" \
        "round-trip. KayaWire's encode buffer must GROW (the Enc wrapper in" \
        "tools/kaya-bindgen/src/java.rs); a fixed ByteBuffer caps every record," \
        "which is a text prop of 4064 characters and a drawing of 252 values."
    exit 1
fi

# ITS WATCHED NEGATIVE. The growth is removed from a COPY — never the
# tree (the perturb-from-copy rule) — the substitution is COUNTED, and
# the same exerciser is required to throw for the RIGHT reason. Without
# this the clause above only shows the encoder works, not that the
# growth is what makes it work.
mkdir -p "$TMP/fixedwire"
cp bindings/java/dev/kaya/*.java "$TMP/fixedwire/"
before="$(shasum -a 256 bindings/java/dev/kaya/KayaWire.java)"

doctored=$(python3 - "$TMP/fixedwire/KayaWire.java" <<'PY'
import io, re, sys

path = sys.argv[1]
src = io.open(path, encoding="utf-8").read()
# The whole body of Enc.at, replaced by a buffer that never grows —
# which is the pre-fix fixed ByteBuffer.allocate(4096) exactly. The
# closing brace is anchored at EIGHT spaces: the `if (need < 0)` block
# inside the body closes at twelve, and a lazier pattern would doctor
# that instead and still print 1.
body = re.compile(
    r"( *private ByteBuffer at\(int extra\) \{\n).*?(\n        \}\n)", re.S)
src, n = body.subn(r"\1            return b;\2", src)
io.open(path, "w", encoding="utf-8").write(src)
print(n)
PY
)
echo "java-typecheck: ceiling negative doctored $doctored site(s)"
if [ "$doctored" != "1" ]; then
    echo "java-typecheck: FAIL — the ceiling negative doctored $doctored sites," \
        "not 1. It patches Enc.at's body in a copy of KayaWire.java; if that" \
        "method was renamed or reshaped the negative measured NOTHING and this" \
        "gate has been passing vacuously."
    exit 1
fi

if run_javac -encoding UTF-8 -d "$TMP/fixedclasses" \
        bindings/java-desktop/dev/kaya/KayaRing.java \
        "$TMP/fixedwire"/*.java; then
    :
else
    echo "java-typecheck: FAIL — the doctored copy did not compile, so the" \
        "ceiling negative proved nothing. Enc.at's body must be replaceable by" \
        "\`return b;\` on its own."
    exit 1
fi

if run_java -cp "$TMP/fixedclasses:$TMP/bigclasses" LargeRecordCheck \
        >"$TMP/ceiling.log" 2>&1; then
    echo "java-typecheck: FAIL — the large-record exerciser PASSED against an" \
        "encode buffer that cannot grow. It is therefore not exercising the" \
        "ceiling, and the clause above is green for some other reason."
    exit 1
fi
if grep -q "BufferOverflowException" "$TMP/ceiling.log"; then
    :
else
    echo "java-typecheck: FAIL — the doctored encoder failed, but NOT with" \
        "BufferOverflowException, so the negative did not watch the ceiling." \
        "What it printed:"
    cat "$TMP/ceiling.log"
    exit 1
fi

# The tree is untouched by the perturbation above — asserted, not assumed.
if printf '%s\n' "$before" | shasum -a 256 -c --status; then
    :
else
    echo "java-typecheck: FAIL — bindings/java/dev/kaya/KayaWire.java changed" \
        "during the ceiling negative. It must only ever doctor the copy in" \
        "\$TMP."
    exit 1
fi

# ONE APP PER PROCESS, AND THE REFUSAL MADE TO PRINT (docs/deferred.md's
# mount entry). kaya's core is a process-global singleton, so two Apps
# mint ids from two counters into one scene and the core dies on the
# first collision — a crash three removes from the mistake. NOTHING ELSE
# REACHES IT: no guest builds two, and on Android kaya starts the app
# thread itself (KayaRing.startGuest), so the platform's own relaunch can
# no longer produce a second entry either — the shape this replaced, where
# the JVM shell spawned the thread, died in requireAppThread naming a
# THREAD rather than the cause (measured on the android lane 2026-08-27).
mkdir -p "$TMP/once"
cat >"$TMP/once/BuildOnceCheck.java" <<'PROBE'
import dev.kaya.KayaApp;

/** A second App in one process is refused, and the sentence says why.
 * Compiled and RUN by tools/java-typecheck.sh. */
public final class BuildOnceCheck {
    private static void check(boolean ok, String what) {
        if (!ok) {
            System.out.println("build-once: FAIL — " + what);
            System.exit(1);
        }
    }

    public static void main(String[] args) {
        new KayaApp();
        try {
            new KayaApp();
            check(false, "a second App in one process was accepted");
        } catch (IllegalStateException e) {
            check(e.getMessage() != null
                            && e.getMessage().contains("a second App in this process"),
                    "the refusal did not name a second App: " + e.getMessage());
        }
        System.out.println("build-once: OK — a second App is refused, by its own sentence");
    }

    private BuildOnceCheck() {}
}
PROBE

if run_javac -encoding UTF-8 -cp "$TMP/classes" -d "$TMP/onceclasses" \
        "$TMP/once/BuildOnceCheck.java"; then
    :
else
    echo "java-typecheck: FAIL — the build-once exerciser did not compile."
    exit 1
fi

if run_java -cp "$TMP/classes:$TMP/onceclasses" BuildOnceCheck; then
    :
else
    echo "java-typecheck: FAIL — a second KayaApp in one process was not refused," \
        "or was refused by a sentence that does not name the cause. kaya's core is" \
        "a process-global singleton (docs/deferred.md's mount entry); two Apps mint" \
        "ids from two counters and the core dies on the first collision."
    exit 1
fi

# ITS WATCHED NEGATIVE, the ceiling clause's shape one file over: the
# latch is removed from a COPY of the binding — never the tree — the
# substitution is COUNTED, and the same exerciser is required to report
# that a second App got through. Without this the clause above only shows
# that the probe runs.
mkdir -p "$TMP/unlatched"
cp bindings/java/dev/kaya/*.java "$TMP/unlatched/"
appbefore="$(shasum -a 256 bindings/java/dev/kaya/KayaApp.java)"
unlatched=$(python3 - "$TMP/unlatched/KayaApp.java" <<'PY'
import io
import re
import sys

path = sys.argv[1]
src = io.open(path, encoding="utf-8").read()
src, n = re.subn(r"if \(BUILT\.getAndSet\(true\)\) \{", "if (false) {", src)
io.open(path, "w", encoding="utf-8").write(src)
print(n)
PY
)
echo "java-typecheck: build-once negative unlatched $unlatched constructor(s)"
if [ "$unlatched" != "1" ]; then
    echo "java-typecheck: FAIL — the build-once negative unlatched $unlatched" \
        "constructors, not 1. It rewrites KayaApp's BUILT test in a copy; if that" \
        "latch moved, the refusal above has been watched by NOTHING."
    exit 1
fi

if run_javac -encoding UTF-8 -d "$TMP/unlatchedclasses" \
        bindings/java-desktop/dev/kaya/KayaRing.java "$TMP/unlatched"/*.java; then
    :
else
    echo "java-typecheck: FAIL — the unlatched KayaApp copy did not compile."
    exit 1
fi

if run_java -cp "$TMP/unlatchedclasses:$TMP/onceclasses" BuildOnceCheck \
        >"$TMP/unlatched.log" 2>&1; then
    echo "java-typecheck: FAIL — the build-once exerciser PASSED against a KayaApp" \
        "whose latch was removed. It is therefore not exercising the latch, and the" \
        "clause above is green for some other reason."
    exit 1
fi
if grep -q "a second App in one process was accepted" "$TMP/unlatched.log"; then
    :
else
    echo "java-typecheck: FAIL — the unlatched copy failed, but NOT by accepting a" \
        "second App, so the negative did not watch the latch. What it printed:"
    cat "$TMP/unlatched.log"
    exit 1
fi

if printf '%s\n' "$appbefore" | shasum -a 256 -c --status; then
    :
else
    echo "java-typecheck: FAIL — bindings/java/dev/kaya/KayaApp.java changed during" \
        "the build-once negative. It must only ever doctor the copy in \$TMP."
    exit 1
fi

echo "java-typecheck: OK"
