package dev.kaya;

/**
 * The desktop JVM transport, plus the desktop bootstrap pair: attach()
 * first, then run(), which returns only at quit. On macOS launch the JVM
 * with -XstartOnFirstThread (AppKit accepts no thread but the process's
 * first). The Kotlin twin in android/kaya is the other half of this
 * class; tools/check-jni.py holds coverage across the two.
 */
public final class KayaRing {
    /** Register everything else (the one name-resolved entry). */
    public static native void attach();

    /** kaya_run: the calling thread becomes the UI loop. */
    public static native int run();

    /**
     * Redeem a picked file (docs/file-dialogs-plan.md §6f): a
     * {@link java.io.FileDescriptor} the caller owns, with
     * {@code seekable[0]} 1 for random access. BLOCKS, possibly for a
     * long time — a cloud provider may download the file first — so call
     * it off the app thread and post the result back.
     */
    public static native java.io.FileDescriptor openPicked(
            long handle, int mode, int[] seekable);

    /** One transaction as encoded records — kaya_submit's spelling. */
    public static native void submit(byte[] tx);

    public static native long dataAddress();

    public static native long headAddress();

    public static native long tailAddress();

    public static native int capacity();

    public static native long specHash();

    /**
     * The host capability word — kaya_capabilities's JNI spelling. A
     * {@code long} because JNI has no unsigned types.
     *
     * <p>Both JVMs carry this; the answer differs between them. Guests
     * call {@code KayaApp.capabilities()}, never this.
     */
    public static native long capabilities();

    public static native boolean waitOccurrences();

    /** Return the app thread from waitOccurrences. Safe from any thread. */
    public static native void wake();

    /**
     * One copy of the encoded bytes into core-owned memory, returning
     * the u64 handle the next submit from this guest consumes —
     * kaya_blob_register's spelling.
     */
    public static native long blobRegister(byte[] data);

    /**
     * Redeem an occurrence blob for its bytes, and release it — called
     * by the generated decoder, never by a guest. Nothing retires an
     * occurrence handle otherwise, so the decoder must release it while
     * decoding.
     */
    public static native byte[] occurrenceBlob(long handle);

    /**
     * Open an asset by name — a relative path under the asset root,
     * spelled with {@code /}, as UTF-8 bytes; 0 is the MISS, and the
     * caller raises with {@link #assetMissSentence}'s sentence. BYTES
     * AND NOT A STRING: JNI's string calls speak MODIFIED UTF-8.
     */
    public static native long assetOpen(byte[] name);

    /** An open asset's bytes: one copy out of core memory. */
    public static native byte[] assetBytes(long handle);

    /**
     * Register an open asset's bytes into the pending blob table and
     * return the handle a record carries. The bytes never enter the
     * JVM's heap.
     */
    public static native long assetBlob(long handle);

    /** Drop an open asset; idempotent, so a double release is a no-op. */
    public static native void assetRelease(long handle);

    /**
     * Why {@code assetOpen(name)} would answer 0, as UTF-8 bytes; empty
     * means the name resolves.
     */
    public static native byte[] assetMissSentence(byte[] name);

    private KayaRing() {}
}
