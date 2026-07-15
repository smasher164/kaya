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

    public static boolean waitOccurrences() {
        return false;
    }

    private KayaRing() {}
}
