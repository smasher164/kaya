package dev.kaya;

/**
 * Compile-time stand-in for the real KayaRing (Kotlin, in the Android
 * kaya module): lets tools/java-typecheck.sh compile KayaApp.java and
 * the Java example on any machine, without Gradle or an emulator.
 * Signatures must match dev.kaya.KayaRing exactly; the Android build
 * is the enforcement for the real one.
 */
public final class KayaRing {
    public static void submit(byte[] tx) {}

    public static long dataAddress() {
        return 0;
    }

    public static long headAddress() {
        return 0;
    }

    public static long tailAddress() {
        return 0;
    }

    public static int capacity() {
        return 0;
    }

    public static long specHash() {
        return 0;
    }

    public static boolean waitOccurrences() {
        return false;
    }

    // Stands in for kaya_blob_register: one copy of the encoded bytes
    // into core-owned memory, returning the u64 handle the next submit
    // from this guest consumes (referenced or not). The real Kotlin
    // KayaRing must grow the matching JNI method — deferred to the
    // Android side.
    public static long blobRegister(byte[] data) {
        return 0;
    }

    private KayaRing() {}
}
