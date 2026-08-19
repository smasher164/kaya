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

    /**
     * Redeem a picked file: returns a {@link java.io.FileDescriptor}
     * the caller owns, with {@code seekable[0]} set to 1 when it
     * supports random access.
     *
     * NATIVE BECAUSE JAVA HAS NO OTHER WAY. There is no public API for
     * wrapping a descriptor, and the obvious route is closed: reflecting
     * into {@code FileDescriptor}'s private {@code fd} throws
     * {@code InaccessibleObjectException} on JDK 17, since java.base is
     * not open. Reaching it would force every kaya application to launch
     * with {@code --add-opens java.base/java.io=ALL-UNNAMED} — a demand
     * a binding has no business making of its users.
     *
     * JNI has no such restriction, and this is measured rather than
     * assumed (docs/file-dialogs-plan.md §6f): the native side builds
     * the descriptor through the public no-arg constructor and sets the
     * field with SetIntField, with NO flags of any kind.
     *
     * BLOCKS, possibly for a long time — a cloud provider may download
     * the file before it answers — so call it from a thread you chose
     * and post the result back.
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
     * by the generated decoder, never by a guest.
     *
     * A blob arriving in an OCCURRENCE is a handle into a table with no
     * boundary that retires one, unlike the apply channel's batch-local
     * index, so the decoder lets go of it while decoding and no handle
     * ever reaches an app.
     */
    public static native byte[] occurrenceBlob(long handle);

    /**
     * Open an asset by name — a relative path under the asset root,
     * spelled with {@code /}, as UTF-8 bytes. 0 is the MISS, and the
     * caller raises with the sentence {@link #assetMissSentence} hands it.
     *
     * <p>BYTES AND NOT A STRING, because JNI's string calls speak
     * MODIFIED UTF-8: a name outside ASCII would reach the resolver as
     * something other than what the guest typed.
     *
     * <p>The same entry both JVMs carry, because the JVM guest tier is
     * one tier — a directory beside the program on the desktops, the
     * APK's own {@code assets/} on Android, and neither class knows
     * which route it got.
     */
    public static native long assetOpen(byte[] name);

    /** An open asset's bytes: one copy out of core memory. */
    public static native byte[] assetBytes(long handle);

    /**
     * Register an open asset's bytes into the pending blob table and
     * return the handle a record carries. The bytes never enter the
     * JVM's heap — this is the redemption a font or an icon takes.
     */
    public static native long assetBlob(long handle);

    /** Drop an open asset; idempotent, so a double release is a no-op. */
    public static native void assetRelease(long handle);

    /**
     * Why {@code assetOpen(name)} would answer 0, as UTF-8 bytes; empty
     * means the name resolves. The sentence has ONE author (the core),
     * so every language raises the same words.
     */
    public static native byte[] assetMissSentence(byte[] name);

    private KayaRing() {}
}
