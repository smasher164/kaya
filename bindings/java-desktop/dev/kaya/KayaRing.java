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

    /**
     * The {@code copy_asset} scene verb, the core's own body, registered on
     * the shared ring list (docs/photo-attach-plan.md §5): "ok\n" or "no\n"
     * and the sentence.
     */
    public static native byte[] copyAsset(byte[] name, byte[] dest);

    /**
     * The app's own writable directory as UTF-8 bytes; EMPTY means none
     * yet (docs/tasks-s4-plan.md §4).
     */
    public static native byte[] appDataDir();

    /**
     * The typed preferences store (docs/tasks-s4-plan.md P2/P3). ABSENT
     * IS A NULL ARRAY and present a one-element one, so a key holding
     * another type reads exactly like a key that is not there — which
     * is the store's own semantics.
     */
    public static native byte[] prefGetString(byte[] key);

    public static native long[] prefGetI64(byte[] key);

    public static native double[] prefGetF64(byte[] key);

    public static native boolean[] prefGetBool(byte[] key);

    public static native void prefSetString(byte[] key, byte[] value);

    public static native void prefSetI64(byte[] key, long value);

    public static native void prefSetF64(byte[] key, double value);

    public static native void prefSetBool(byte[] key, boolean value);

    public static native void prefRemove(byte[] key);

    /**
     * The formatter door and the catalog (docs/compliance-plan.md §3; the
     * kaya_fmt_*, kaya_locale, kaya_direction, kaya_text_scale, kaya_catalog
     * and kaya_tr JNI spellings). A NULL answer from a formatter or tr means
     * the core reported a fault for the input; KayaApp throws naming the call.
     * tr's arguments ride one packed byte array (KayaApp.TrArgs).
     */
    public static native byte[] fmtDate(long packed, long length);
    public static native byte[] fmtDateWeekday(long packed);
    public static native byte[] fmtTime(long packed, long length);
    public static native byte[] fmtTimecode(long frames, long numerator, long denominator, boolean drop);
    public static native long fmtParseTimecode(String text, long numerator, long denominator, boolean drop);
    public static native byte[] fmtDateTime(long date, long time, long length);
    public static native byte[] fmtNumber(double value, int minFractionDigits, int maxFractionDigits, boolean grouping);
    public static native byte[] fmtPercent(double value, int minFractionDigits, int maxFractionDigits, boolean grouping);
    public static native byte[] fmtCurrency(double value, byte[] code);
    public static native byte[] locale();
    public static native int direction();
    public static native double textScale();
    public static native void catalog(byte[] app);
    public static native byte[] tr(byte[] key, byte[] args, int nargs);

    /** kaya_can_play (docs/media-plan.md §8 ruling 1): any thread. */
    public static native boolean canPlay(byte[] mime, byte[] codecs);

    /** kaya_reader_peaks: a finished peaks read's pairs, pair-major i16
     * (min then max per channel); null for none. */
    public static native short[] readerPeaks(long reader, long read);

    /** kaya_image_pixels: a core-held image's premultiplied RGBA8, its
     * size into {@code size[0]} and {@code size[1]}; null for none. */
    public static native byte[] imagePixels(long image, int[] size);

    /** kaya_capture_on_frame / kaya_capture_on_samples: on, the core calls
     * KayaApp.captureFrame / captureSamples for {@code capture} on kaya's
     * capture thread; off drops it. KayaApp holds the app's callbacks. */
    public static native void captureOnFrame(long capture, boolean on);

    public static native void captureOnSamples(long capture, boolean on);

    private KayaRing() {}
}
