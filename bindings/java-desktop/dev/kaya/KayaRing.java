package dev.kaya;

/**
 * The desktop JVM transport: the same ring statics the Kotlin
 * KayaRing exposes on Android — KayaApp is written against exactly
 * this surface and never sees which platform provided it — plus the
 * desktop bootstrap pair. attach() is the one name-resolved native
 * (call it right after loading the library; it registers everything
 * else, jvm.rs's single-entry doctrine). run() is kaya_run: the
 * calling thread becomes the UI loop and it returns only at quit,
 * with the exit code. Call run() from main, with the scene thread
 * already spawned — and on macOS launch the JVM with
 * -XstartOnFirstThread, because AppKit accepts no thread but the
 * process's first.
 *
 * Twin-class contract: dev.kaya.KayaRing exists twice by design —
 * this class on the desktops, the Kotlin one in android/kaya (its
 * attach takes the Activity anchor Android requires; run does not
 * exist there because Android owns the loop). The rust side registers
 * natives by name+signature against whichever class loaded it, so
 * drift on either side dies loudly at attach, on that platform.
 */
public final class KayaRing {
    /** Register the natives (the one name-resolved entry). */
    public static native void attach();

    /** kaya_run: the calling thread becomes the UI loop. */
    public static native int run();

    /** One transaction as encoded records — kaya_submit's spelling. */
    public static native void submit(byte[] tx);

    public static native long dataAddress();

    public static native long headAddress();

    public static native long tailAddress();

    public static native int capacity();

    public static native long specHash();

    public static native boolean waitOccurrences();

    /**
     * One copy of the encoded bytes into core-owned memory, returning
     * the u64 handle the next submit from this guest consumes —
     * kaya_blob_register's spelling.
     */
    public static native long blobRegister(byte[] data);

    private KayaRing() {}
}
