package dev.kaya.milestone0kt;

import dev.kaya.KayaRing;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.reflect.Field;

/**
 * Milestone 0 through the direct ring tier: the JVM reads the occurrence
 * ring with its own atomics. JNI is crossed only to start the core, to
 * wait on an empty ring, and to send commands; the data path is pure
 * Java. Record layout as declared in kaya.h: header {u32 size, u16 kind,
 * u16 flags}, payload inline, little-endian, 8-byte aligned.
 *
 * The formulation is plain absolute loads/stores plus explicit fences
 * (Unsafe.loadFence after the tail read = acquire; Unsafe.storeFence
 * before the head write = release; both documented as the C11
 * atomic_thread_fence equivalents). ART leaves no other correct option
 * for foreign memory: its byte-buffer-view VarHandle path truncates a
 * direct buffer's address to 32 bits in the interpreter
 * (var_handle.cc), and its Unsafe (Object, long) volatile accessors are
 * heap-field-only — a null base faults because the offset goes through a
 * 32-bit MemberOffset. Both were found the hard way; see DESIGN.md.
 *
 * Unsafe is not in the SDK stubs, so it is loaded reflectively once and
 * its methods bound as MethodHandles; invokeExact is
 * signature-polymorphic, so the per-record path stays free of boxing
 * and reflection.
 */
final class Milestone0 {
    private static final int BUTTON_CLICKED = 1; // KAYA_OCCURRENCE_BUTTON_CLICKED
    private static final long LABEL = 2;         // KAYA_WIDGET_LABEL

    private static final MethodHandle GET_INT;     // (long) -> int
    private static final MethodHandle GET_SHORT;   // (long) -> short
    private static final MethodHandle GET_LONG;    // (long) -> long
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
            GET_LONG = lookup.unreflect(unsafeClass.getMethod("getLong", long.class)).bindTo(unsafe);
            PUT_INT = lookup
                    .unreflect(unsafeClass.getMethod("putInt", long.class, int.class))
                    .bindTo(unsafe);
            LOAD_FENCE = lookup.unreflect(unsafeClass.getMethod("loadFence")).bindTo(unsafe);
            STORE_FENCE = lookup.unreflect(unsafeClass.getMethod("storeFence")).bindTo(unsafe);
        } catch (ReflectiveOperationException e) {
            throw new ExceptionInInitializerError(e);
        }
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
                long widgetId = (long) GET_LONG.invokeExact(at + 8);
                count++;
                KayaRing.setText(LABEL, "Clicked " + count + " times");
            }
            h += size;
            STORE_FENCE.invokeExact(); // release: record reads complete before the hand-back
            PUT_INT.invokeExact(headAddr, h);
        }
    }

    private Milestone0() {}
}
