package dev.kaya

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File
import java.io.FileNotFoundException

/**
 * The bytes half of an Android clip.
 *
 * `ClipData.Item` carries text, html, a `Uri` or an `Intent` and NO
 * byte array at any API level (docs/clipboard-plan.md §7 finding 2), so
 * kaya's image, custom-format and file representations ride `content://`
 * URIs and a consumer resolves them with `ContentResolver.getType` and
 * `openInputStream`. This is the provider behind those URIs: the
 * interpreter writes a clip's payloads into [dir] as it lowers
 * APPLY_COPY, then puts the URIs on the clipboard.
 *
 * FROM DISK, NEVER FROM MEMORY. The clip outlives this process: the
 * clipboard holds only the URI string, the read grant is held by
 * system_server's own permission owner, and a provider is instantiated
 * on demand — so a paste after kaya has died starts this process again
 * and asks for the bytes. A `HashMap` filled at copy time would answer
 * an empty clipboard with no error anywhere.
 *
 * IN THE LIBRARY'S MANIFEST, unlike [KayaHarnessAccessibility]: an
 * image on the clipboard is a product feature every kaya app has, not
 * harness machinery a user's app should not carry.
 *
 * NO THREAD AFFINITY. Providers are called on binder threads, from
 * whatever process pasted; nothing here touches the interpreter's
 * model or the main looper.
 */
class KayaClipProvider : ContentProvider() {
    override fun onCreate() = true

    /**
     * What a consumer asks before it opens anything — and SystemUI asks
     * it across the process boundary after every copy, so it stays a
     * couple of file reads.
     *
     * The custom id is served VERBATIM from the sidecar the interpreter
     * wrote beside the payload: it is the guest's own string (a slash
     * is required, `dev.kaya/note` in the scene) and nothing on this
     * path validates or normalizes a mime type, so nothing here may
     * either.
     */
    override fun getType(uri: Uri): String? {
        val ctx = context ?: return null
        val segments = uri.pathSegments
        val slot = slot(segments)
        return when {
            segments.size == 1 && segments[0] == IMAGE -> "image/png"
            segments.size == 2 && segments[0] == CUSTOM && slot != null ->
                read(customMimeSidecar(ctx, slot))
            segments.size == 2 && segments[0] == FILE && slot != null -> "text/plain"
            else -> null
        }
    }

    /**
     * The payload itself, and the WHOLE read path: a consumer's
     * `openInputStream` reaches `openTypedAssetFile`, whose default
     * short-circuits the any-type filter to `openAssetFile` and then to
     * this. Overriding the typed pair would only be needed to serve
     * alternate representations of one URI, which kaya never does — one
     * URI is one representation.
     */
    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
        val file = fileFor(uri) ?: return null
        // READ-ONLY BY CONSTRUCTION, said rather than silently served:
        // handing back a read-only descriptor to a caller that asked to
        // write is a write that vanishes.
        if (mode != "r") {
            throw FileNotFoundException(
                "kaya: $uri is a clipboard payload and readable only, not $mode",
            )
        }
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    /**
     * OpenableColumns, which is how a consumer asks a pasted file its
     * display name — the same question kaya's own picker answers, and
     * the answer the interpreter stored beside the bytes.
     */
    override fun query(
        uri: Uri,
        projection: Array<String>?,
        selection: String?,
        selectionArgs: Array<String>?,
        sortOrder: String?,
    ): Cursor? {
        val ctx = context ?: return null
        val file = fileFor(uri) ?: return null
        val segments = uri.pathSegments
        val slot = slot(segments)
        val name = when {
            segments.size == 2 && segments[0] == FILE && slot != null ->
                read(fileNameSidecar(ctx, slot)) ?: file.name
            else -> file.name
        }
        val cursor = MatrixCursor(
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
        )
        cursor.addRow(arrayOf<Any>(name, file.length()))
        return cursor
    }

    // Read-only: a clip's payloads are written by the interpreter
    // directly into [dir], never through the resolver.
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<String>?) = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<String>?,
    ) = 0

    /** The payload file a URI names, or null when it names nothing. */
    private fun fileFor(uri: Uri): File? {
        val ctx = context ?: return null
        val segments = uri.pathSegments
        val slot = slot(segments)
        return when {
            segments.size == 1 && segments[0] == IMAGE -> imagePayload(ctx)
            segments.size == 2 && segments[0] == CUSTOM && slot != null ->
                customPayload(ctx, slot)
            segments.size == 2 && segments[0] == FILE && slot != null ->
                filePayload(ctx, slot)
            else -> null
        }
    }

    /**
     * A slot as an INT, and every file name below is re-rendered from
     * it — so a path segment cannot name a file outside [dir]. A
     * traversal attempt is not sanitized, it simply fails to parse.
     */
    private fun slot(segments: List<String>): Int? = segments.getOrNull(1)?.toIntOrNull()

    /** A sidecar's one line, or null when it was never written. */
    private fun read(file: File): String? =
        if (file.isFile) file.readText().trim().ifEmpty { null } else null

    companion object {
        /** The URI path segments — the grammar, spelled once. */
        private const val IMAGE = "image"
        private const val CUSTOM = "custom"
        private const val FILE = "file"

        /**
         * PER APPLICATION ID, and it cannot be a constant. Both
         * validation APKs (dev.kaya.milestone2 and dev.kaya.milestone2kt)
         * are installed on the same emulator, and two installed packages
         * declaring one provider authority is a hard
         * INSTALL_FAILED_CONFLICTING_PROVIDER on the second install —
         * which would break every leg on that device, not only the
         * clipboard's. The manifest says `${applicationId}.clip`; this
         * computes the same string, and both sides must keep saying the
         * same thing.
         */
        fun authority(context: Context): String = context.packageName + ".clip"

        /**
         * Where a clip's payloads live: app-private cache, which the
         * platform may reclaim between runs — correct, because a clip
         * whose bytes are gone is a clip the system also cleared (one
         * hour, since Android 13), and nothing here is the guest's data.
         * Created on demand, since the writer asks first.
         */
        fun dir(context: Context): File =
            File(context.cacheDir, "kaya-clip").apply { mkdirs() }

        /** The URI for one payload path; the three below name them all. */
        fun uri(context: Context, path: String): Uri =
            Uri.parse("content://" + authority(context) + path)

        /** The image payload's URI — one image per clip. */
        fun imageUri(context: Context): Uri = uri(context, "/$IMAGE")

        /** Custom format [slot]'s URI, in the clip's own order. */
        fun customUri(context: Context, slot: Int): Uri = uri(context, "/$CUSTOM/$slot")

        /** File [slot]'s URI, in the clip's own order. */
        fun fileUri(context: Context, slot: Int): Uri = uri(context, "/$FILE/$slot")

        /**
         * The image's bytes, PNG (the one image type kaya's protocol
         * carries, and what a decoder on any lane is handed).
         */
        fun imagePayload(context: Context): File = File(dir(context), "$IMAGE.png")

        /** Custom format [slot]'s bytes. */
        fun customPayload(context: Context, slot: Int): File =
            File(dir(context), "$CUSTOM-$slot.bin")

        /**
         * Custom format [slot]'s id — the mime string [getType] answers
         * with. Beside the bytes rather than in the URI, because the id
         * is the guest's and a URI path segment is not a place to put
         * an arbitrary string.
         */
        fun customMimeSidecar(context: Context, slot: Int): File =
            File(dir(context), "$CUSTOM-$slot.mime")

        /** File [slot]'s bytes. */
        fun filePayload(context: Context, slot: Int): File = File(dir(context), "$FILE-$slot")

        /** File [slot]'s display name, which OpenableColumns answers. */
        fun fileNameSidecar(context: Context, slot: Int): File =
            File(dir(context), "$FILE-$slot.name")

        /**
         * Forget the last clip's payloads. The writer calls this before
         * laying down a new one: the platform never says a clip was
         * replaced, so a shorter clip would otherwise leave a richer
         * one's slots on disk under names the new clip does not
         * advertise.
         */
        fun clear(context: Context) {
            dir(context).listFiles()?.forEach { it.delete() }
        }
    }
}
