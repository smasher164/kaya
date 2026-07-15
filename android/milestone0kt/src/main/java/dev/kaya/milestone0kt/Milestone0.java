package dev.kaya.milestone0kt;

import dev.kaya.KayaRing;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.reflect.Field;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * The milestone-2 scene through the direct ring tier: the JVM reads the
 * occurrence ring with its own atomics and answers with packed
 * transaction records through KayaRing.submit. The scene declares a When
 * (the extras banner) and a nested For (groups holding items); clicks on
 * stamped remove buttons come back as a template node id plus key path,
 * and the app answers by removing that entry — the screen follows the
 * data.
 *
 * Ring consumption is unchanged from milestone 0 (Unsafe fenced access on
 * raw addresses; see the git history for the ART findings that shaped
 * it). The transaction side needs no atomics at all: pack records, one
 * submit per batch.
 */
final class Milestone0 {
    private static final int BUTTON_CLICKED = 1; // KAYA_OCCURRENCE_BUTTON_CLICKED

    // KAYA_TX_* record kinds and value/source tags.
    private static final short TX_CREATE_SIGNAL = 1;
    private static final short TX_WRITE_SIGNAL = 2;
    private static final short TX_CREATE_WIDGET = 3;
    private static final short TX_SET_PROPERTY = 4;
    private static final short TX_ADD_CHILD = 5;
    private static final short TX_MOUNT = 6;
    private static final short TX_CREATE_COLLECTION = 7;
    private static final short TX_COLLECTION_INSERT = 8;
    private static final short TX_COLLECTION_UPDATE = 9;
    private static final short TX_COLLECTION_REMOVE = 10;
    private static final short TX_CREATE_FOR = 11;
    private static final short TX_CREATE_WHEN = 12;
    private static final short TX_TEMPLATE_END = 13;
    private static final int KIND_COLUMN = 1;
    private static final int KIND_BUTTON = 2;
    private static final int KIND_LABEL = 3;
    private static final int PROP_TEXT = 1;
    private static final int SOURCE_CONST = 0;
    private static final int SOURCE_SIGNAL = 1;
    private static final int SOURCE_ELEMENT = 2;
    private static final int VALUE_BOOL = 1;
    private static final int VALUE_STR = 4;

    // Guest-allocated ids, counted from 1 per space.
    private static final long SIG_STATUS = 1;
    private static final long SIG_EXTRAS = 2;
    private static final long W_COLUMN = 1;
    private static final long W_STEP = 2;
    private static final long W_STATUS = 3;
    private static final long W_WHEN = 4;
    private static final long W_GROUPS = 5;
    private static final long C_GROUPS = 1;
    private static final long C_ITEMS = 2;
    private static final long N_BANNER = 1;
    private static final long N_GROUP_COL = 2;
    private static final long N_GROUP_LBL = 3;
    private static final long N_ITEMS_FOR = 4;
    private static final long N_ITEM_ROW = 5;
    private static final long N_ITEM_TEXT = 6;
    private static final long N_REMOVE = 7;

    private static final MethodHandle GET_INT;     // (long) -> int
    private static final MethodHandle GET_SHORT;   // (long) -> short
    private static final MethodHandle GET_LONG;    // (long) -> long
    private static final MethodHandle GET_BYTE;    // (long) -> byte
    private static final MethodHandle PUT_INT;     // (long, int)
    private static final MethodHandle LOAD_FENCE;  // (): acquire
    private static final MethodHandle STORE_FENCE; // (): release

    static {
        try {
            Class<?> unsafeClass = Class.forName("sun.misc.Unsafe");
            Field theUnsafe = unsafeClass.getDeclaredField("theUnsafe");
            theUnsafe.setAccessible(true);
            Object unsafe = theUnsafe.get(null);
            MethodHandles.Lookup lookup = MethodHandles.lookup();
            GET_INT = lookup.unreflect(unsafeClass.getMethod("getInt", long.class)).bindTo(unsafe);
            GET_SHORT =
                    lookup.unreflect(unsafeClass.getMethod("getShort", long.class)).bindTo(unsafe);
            GET_LONG =
                    lookup.unreflect(unsafeClass.getMethod("getLong", long.class)).bindTo(unsafe);
            GET_BYTE =
                    lookup.unreflect(unsafeClass.getMethod("getByte", long.class)).bindTo(unsafe);
            PUT_INT = lookup
                    .unreflect(unsafeClass.getMethod("putInt", long.class, int.class))
                    .bindTo(unsafe);
            LOAD_FENCE = lookup.unreflect(unsafeClass.getMethod("loadFence")).bindTo(unsafe);
            STORE_FENCE = lookup.unreflect(unsafeClass.getMethod("storeFence")).bindTo(unsafe);
        } catch (ReflectiveOperationException e) {
            throw new ExceptionInInitializerError(e);
        }
    }

    // --- Transaction packing (KAYA_TX_* layouts from kaya.h) ------------

    private static ByteBuffer record(ByteBuffer b, short kind) {
        // Caller writes the body right after; finish() sets the size.
        b.putInt(0).putShort(kind).putShort((short) 0);
        return b;
    }

    private static void finish(ByteBuffer b, int start) {
        while (b.position() % 8 != 0) b.put((byte) 0);
        b.putInt(start, b.position() - start);
    }

    private static void pad(ByteBuffer b) {
        while (b.position() % 8 != 0) b.put((byte) 0);
    }

    // Values are self-padded to 8: they concatenate inside record bodies.
    private static void putString(ByteBuffer b, String s) {
        byte[] utf8 = s.getBytes(StandardCharsets.UTF_8);
        b.putInt(VALUE_STR).putInt(utf8.length).put(utf8);
        pad(b);
    }

    private static void putBool(ByteBuffer b, boolean v) {
        b.putInt(VALUE_BOOL).putInt(1).put((byte) (v ? 1 : 0));
        pad(b);
    }

    /** A key path: {u32 count, u32 reserved, count values}. */
    private static void putPath(ByteBuffer b, String... keys) {
        b.putInt(keys.length).putInt(0);
        for (String k : keys) putString(b, k);
    }

    private static byte[] finishTx(ByteBuffer b) {
        byte[] out = new byte[b.position()];
        b.flip();
        b.get(out);
        return out;
    }

    private static ByteBuffer newTx() {
        return ByteBuffer.allocate(4096).order(ByteOrder.LITTLE_ENDIAN);
    }

    private static void widget(ByteBuffer b, long id, int kind) {
        int s = b.position();
        record(b, TX_CREATE_WIDGET).putLong(id).putInt(kind).putInt(0);
        finish(b, s);
    }

    private static void textConst(ByteBuffer b, long id, String text) {
        int s = b.position();
        record(b, TX_SET_PROPERTY).putLong(id).putInt(PROP_TEXT).putInt(SOURCE_CONST);
        putString(b, text);
        finish(b, s);
    }

    private static void textElement(ByteBuffer b, long id, int level) {
        int s = b.position();
        record(b, TX_SET_PROPERTY).putLong(id).putInt(PROP_TEXT).putInt(SOURCE_ELEMENT)
                .putInt(level).putInt(0);
        finish(b, s);
    }

    private static void twoLongs(ByteBuffer b, short kind, long x, long y) {
        int s = b.position();
        record(b, kind).putLong(x).putLong(y);
        finish(b, s);
    }

    private static void collection(ByteBuffer b, long id) {
        int s = b.position();
        record(b, TX_CREATE_COLLECTION).putLong(id);
        finish(b, s);
    }

    private static void templateEnd(ByteBuffer b) {
        int s = b.position();
        record(b, TX_TEMPLATE_END);
        finish(b, s);
    }

    private static void insert(ByteBuffer b, long coll, String[] at, String key, String value) {
        int s = b.position();
        record(b, TX_COLLECTION_INSERT).putLong(coll);
        putPath(b, at);
        putString(b, key);
        putString(b, value);
        finish(b, s);
    }

    private static void update(ByteBuffer b, long coll, String[] at, String key, String value) {
        int s = b.position();
        record(b, TX_COLLECTION_UPDATE).putLong(coll);
        putPath(b, at);
        putString(b, key);
        putString(b, value);
        finish(b, s);
    }

    private static void remove(ByteBuffer b, long coll, String[] at, String key) {
        int s = b.position();
        record(b, TX_COLLECTION_REMOVE).putLong(coll);
        putPath(b, at);
        putString(b, key);
        finish(b, s);
    }

    private static void writeStr(ByteBuffer b, long sig, String text) {
        int s = b.position();
        record(b, TX_WRITE_SIGNAL).putLong(sig);
        putString(b, text);
        finish(b, s);
    }

    private static void writeBool(ByteBuffer b, long sig, boolean v) {
        int s = b.position();
        record(b, TX_WRITE_SIGNAL).putLong(sig);
        putBool(b, v);
        finish(b, s);
    }

    private static byte[] sceneTx() {
        ByteBuffer b = newTx();
        int s;

        s = b.position(); record(b, TX_CREATE_SIGNAL).putLong(SIG_STATUS);
        putString(b, "step 0"); finish(b, s);
        s = b.position(); record(b, TX_CREATE_SIGNAL).putLong(SIG_EXTRAS);
        putBool(b, false); finish(b, s);

        widget(b, W_COLUMN, KIND_COLUMN);
        widget(b, W_STEP, KIND_BUTTON);
        textConst(b, W_STEP, "step");
        widget(b, W_STATUS, KIND_LABEL);
        s = b.position();
        record(b, TX_SET_PROPERTY).putLong(W_STATUS).putInt(PROP_TEXT).putInt(SOURCE_SIGNAL)
                .putLong(SIG_STATUS);
        finish(b, s);

        // When(extras): a banner label. The scope brackets the blueprint.
        twoLongs(b, TX_CREATE_WHEN, W_WHEN, SIG_EXTRAS);
        widget(b, N_BANNER, KIND_LABEL);
        textConst(b, N_BANNER, "extras on");
        templateEnd(b);

        // For over groups, nesting a For over items.
        collection(b, C_GROUPS);
        twoLongs(b, TX_CREATE_FOR, W_GROUPS, C_GROUPS);
        widget(b, N_GROUP_COL, KIND_COLUMN);
        widget(b, N_GROUP_LBL, KIND_LABEL);
        textElement(b, N_GROUP_LBL, 0);
        twoLongs(b, TX_ADD_CHILD, N_GROUP_COL, N_GROUP_LBL);
        collection(b, C_ITEMS);
        twoLongs(b, TX_CREATE_FOR, N_ITEMS_FOR, C_ITEMS);
        widget(b, N_ITEM_ROW, KIND_COLUMN);
        widget(b, N_ITEM_TEXT, KIND_LABEL);
        textElement(b, N_ITEM_TEXT, 0);
        widget(b, N_REMOVE, KIND_BUTTON);
        textConst(b, N_REMOVE, "remove");
        twoLongs(b, TX_ADD_CHILD, N_ITEM_ROW, N_ITEM_TEXT);
        twoLongs(b, TX_ADD_CHILD, N_ITEM_ROW, N_REMOVE);
        templateEnd(b);
        twoLongs(b, TX_ADD_CHILD, N_GROUP_COL, N_ITEMS_FOR);
        templateEnd(b);

        twoLongs(b, TX_ADD_CHILD, W_COLUMN, W_STEP);
        twoLongs(b, TX_ADD_CHILD, W_COLUMN, W_STATUS);
        twoLongs(b, TX_ADD_CHILD, W_COLUMN, W_WHEN);
        twoLongs(b, TX_ADD_CHILD, W_COLUMN, W_GROUPS);
        twoLongs(b, TX_MOUNT, 0, W_COLUMN); // window 0: the default
        return finishTx(b);
    }

    static void app() {
        try {
            run();
        } catch (Throwable t) {
            // invokeExact declares Throwable; nothing here throws in practice.
            throw new RuntimeException(t);
        }
    }

    private static void run() throws Throwable {
        KayaRing.submit(sceneTx());

        long data = KayaRing.dataAddress();
        long headAddr = KayaRing.headAddress();
        long tailAddr = KayaRing.tailAddress();
        int mask = KayaRing.capacity() - 1;

        int steps = 0;
        int h = (int) GET_INT.invokeExact(headAddr);
        while (true) {
            int t = (int) GET_INT.invokeExact(tailAddr);
            LOAD_FENCE.invokeExact(); // acquire: record reads cannot move above the tail load
            if (h == t) {
                if (!KayaRing.waitOccurrences()) {
                    return; // shutdown
                }
                continue;
            }
            long at = data + (h & mask);
            int size = (int) GET_INT.invokeExact(at);
            short kind = (short) GET_SHORT.invokeExact(at + 4);
            if (kind == BUTTON_CLICKED) {
                // One click record: header, u64 id, u32 path_len, u32
                // pad, then path values.
                long id = (long) GET_LONG.invokeExact(at + 8);
                int pathLen = (int) GET_INT.invokeExact(at + 16);
                List<String> keys = new ArrayList<>();
                long p = at + 24;
                for (int i = 0; i < pathLen; i++) {
                    int vlen = (int) GET_INT.invokeExact(p + 4);
                    byte[] bytes = new byte[vlen];
                    for (int j = 0; j < vlen; j++) {
                        bytes[j] = (byte) GET_BYTE.invokeExact(p + 8 + j);
                    }
                    keys.add(new String(bytes, StandardCharsets.UTF_8));
                    p += 8 + ((vlen + 7) & ~7);
                }
                if (keys.isEmpty() && id == W_STEP) {
                    steps++;
                    ByteBuffer b = newTx();
                    if (steps == 1) {
                        insert(b, C_GROUPS, new String[] {}, "g1", "Work");
                        insert(b, C_ITEMS, new String[] {"g1"}, "a", "send report");
                        insert(b, C_ITEMS, new String[] {"g1"}, "b", "buy milk");
                    } else if (steps == 2) {
                        insert(b, C_GROUPS, new String[] {}, "g2", "Home");
                        insert(b, C_ITEMS, new String[] {"g2"}, "a", "water plants");
                        update(b, C_GROUPS, new String[] {}, "g1", "Office");
                    }
                    writeBool(b, SIG_EXTRAS, steps == 1);
                    writeStr(b, SIG_STATUS, "step " + steps);
                    KayaRing.submit(finishTx(b));
                } else if (keys.size() == 2 && id == N_REMOVE) {
                    String group = keys.get(0);
                    String item = keys.get(1);
                    ByteBuffer b = newTx();
                    remove(b, C_ITEMS, new String[] {group}, item);
                    writeStr(b, SIG_STATUS, "removed " + group + "/" + item);
                    KayaRing.submit(finishTx(b));
                }
            }
            h += size;
            STORE_FENCE.invokeExact(); // release: record reads complete before the hand-back
            PUT_INT.invokeExact(headAddr, h);
        }
    }

    private Milestone0() {}
}
