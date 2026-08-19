package dev.kaya;

/**
 * The desktop JVM transport: the ring statics KayaApp is written
 * against, plus the desktop bootstrap pair.
 *
 * <p>attach() must be called right after loading the library — it
 * registers everything else. run() is kaya_run: the calling thread
 * becomes the UI loop and returns only at quit, so call it from main
 * with the scene thread already spawned, and on macOS launch the JVM
 * with -XstartOnFirstThread (AppKit accepts no thread but the
 * process's first).
 *
 * <p>dev.kaya.KayaRing exists twice by design — this class on the
 * desktops, the Kotlin one in android/kaya, whose attach takes an
 * Activity anchor and which has no run. Coverage across the two is
 * tools/check-jni.sh.
 */
public final class KayaRing {
    /** Register everything else (the one name-resolved entry). */
    public static native void attach();

    /** kaya_run: the calling thread becomes the UI loop. */
    public static native int run();

    /**
     * Redeem a picked file: returns a {@link java.io.FileDescriptor}
     * the caller owns, with {@code seekable[0]} set to 1 when it
     * supports random access.
     *
     * <p>Why JNI and not reflection: docs/file-dialogs-plan.md §6f.
     *
     * <p>BLOCKS, possibly for a long time — a cloud provider may
     * download the file before it answers — so call it from a thread you
     * chose and post the result back.
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
     * <p>Both JVMs carry this: the ANSWER differs between them, so a
     * desktop-only entry would leave Android unable to ask. Guests call
     * {@code KayaApp.capabilities()}, never this.
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
     * spelled with {@code /}, as UTF-8 bytes. 0 is the MISS, and the
     * caller raises with the sentence {@link #assetMissSentence} hands it.
     *
     * <p>BYTES AND NOT A STRING: JNI's string calls speak MODIFIED
     * UTF-8, so a name outside ASCII would reach the resolver as
     * something other than what the guest typed.
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
