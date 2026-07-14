package dev.kaya.milestone0kt;

import dev.kaya.KayaRing;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.reflect.Field;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;

/**
 * Milestone 1 through the direct ring tier: the JVM reads the occurrence
 * ring with its own atomics and answers with packed transaction records
 * through KayaRing.submit. The scene arrives as one transaction; the
 * label's text is a signal binding this guest writes on every click.
 *
 * Ring consumption is unchanged from milestone 0 (Unsafe fenced access on
 * raw addresses; see the git history for the ART findings that shaped
 * it). The transaction side needs no atomics at all: pack records, one
 * submit per batch.
 */
final class Milestone0 {
    private static final int BUTTON_CLICKED = 1; // KAYA_OCCURRENCE_BUTTON_CLICKED

    // KAYA_TX_* record kinds.
    private static final short TX_CREATE_SIGNAL = 1;
    private static final short TX_WRITE_SIGNAL = 2;
    private static final short TX_CREATE_WIDGET = 3;
    private static final short TX_SET_PROPERTY = 4;
    private static final short TX_ADD_CHILD = 5;
    private static final short TX_MOUNT = 6;
    private static final int KIND_COLUMN = 1;
    private static final int KIND_BUTTON = 2;
    private static final int KIND_LABEL = 3;
    private static final int PROP_TEXT = 1;
    private static final int SOURCE_CONST = 0;
    private static final int SOURCE_SIGNAL = 1;
    private static final int VALUE_STR = 4;

    // Guest-allocated ids, counted from 1 per space.
    private static final long SIG_TEXT = 1;
    private static final long W_COLUMN = 1;
    private static final long W_BUTTON = 2;
    private static final long W_LABEL = 3;

    private static final MethodHandle GET_INT;     // (long) -> int
    private static final MethodHandle GET_SHORT;   // (long) -> short
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

    private static ByteBuffer record(ByteBuffer b, short kind, int bodyReserve) {
        // Caller writes the body right after; finish() sets the size.
        b.putInt(0).putShort(kind).putShort((short) 0);
        return b;
    }

    private static void finish(ByteBuffer b, int start) {
        while (b.position() % 8 != 0) b.put((byte) 0);
        b.putInt(start, b.position() - start);
    }

    private static void putString(ByteBuffer b, String s) {
        byte[] utf8 = s.getBytes(StandardCharsets.UTF_8);
        b.putInt(VALUE_STR).putInt(utf8.length).put(utf8);
    }

    private static byte[] finishTx(ByteBuffer b) {
        byte[] out = new byte[b.position()];
        b.flip();
        b.get(out);
        return out;
    }

    private static byte[] sceneTx() {
        ByteBuffer b = ByteBuffer.allocate(1024).order(ByteOrder.LITTLE_ENDIAN);
        int s;

        s = b.position(); record(b, TX_CREATE_SIGNAL, 0).putLong(SIG_TEXT);
        putString(b, "Clicked 0 times"); finish(b, s);

        s = b.position(); record(b, TX_CREATE_WIDGET, 0).putLong(W_COLUMN).putInt(KIND_COLUMN).putInt(0); finish(b, s);
        s = b.position(); record(b, TX_CREATE_WIDGET, 0).putLong(W_BUTTON).putInt(KIND_BUTTON).putInt(0); finish(b, s);
        s = b.position(); record(b, TX_SET_PROPERTY, 0).putLong(W_BUTTON).putInt(PROP_TEXT).putInt(SOURCE_CONST);
        putString(b, "Click me"); finish(b, s);
        s = b.position(); record(b, TX_CREATE_WIDGET, 0).putLong(W_LABEL).putInt(KIND_LABEL).putInt(0); finish(b, s);
        s = b.position(); record(b, TX_SET_PROPERTY, 0).putLong(W_LABEL).putInt(PROP_TEXT).putInt(SOURCE_SIGNAL).putLong(SIG_TEXT); finish(b, s);
        s = b.position(); record(b, TX_ADD_CHILD, 0).putLong(W_COLUMN).putLong(W_BUTTON); finish(b, s);
        s = b.position(); record(b, TX_ADD_CHILD, 0).putLong(W_COLUMN).putLong(W_LABEL); finish(b, s);
        s = b.position(); record(b, TX_MOUNT, 0).putLong(0).putLong(W_COLUMN); finish(b, s);
        return finishTx(b);
    }

    private static byte[] writeTx(String text) {
        ByteBuffer b = ByteBuffer.allocate(320).order(ByteOrder.LITTLE_ENDIAN);
        int s = b.position();
        record(b, TX_WRITE_SIGNAL, 0).putLong(SIG_TEXT);
        putString(b, text);
        finish(b, s);
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

        long count = 0;
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
                count++;
                String noun = count == 1 ? "time" : "times";
                KayaRing.submit(writeTx("Clicked " + count + " " + noun));
            }
            h += size;
            STORE_FENCE.invokeExact(); // release: record reads complete before the hand-back
            PUT_INT.invokeExact(headAddr, h);
        }
    }

    private Milestone0() {}
}
