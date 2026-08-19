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
 * The bytes half of an Android clip: `ClipData.Item` carries no byte
 * array at any API level (docs/clipboard-plan.md §7 finding 2), so
 * kaya's image, custom-format and file representations ride
 * `content://` URIs and this is the provider behind them.
 *
 * FROM DISK, NEVER FROM MEMORY. The clip outlives this process — a
 * paste after kaya has died starts it again and asks for the bytes, so
 * a `HashMap` filled at copy time would answer an empty clipboard with
 * no error anywhere.
 *
 * NO THREAD AFFINITY: providers are called on binder threads, from
 * whatever process pasted, so nothing here touches the interpreter's
 * model or the main looper.
 */
class KayaClipProvider : ContentProvider() {
    override fun onCreate() = true

    /**
     * SystemUI asks this across the process boundary after every copy,
     * so it stays a couple of file reads. The custom id is served
     * VERBATIM from its sidecar — nothing on this path validates or
     * normalizes a mime type, so nothing here may either.
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
     * The payload, and the WHOLE read path: a consumer's
     * `openInputStream` reaches `openTypedAssetFile`, whose default
     * short-circuits to `openAssetFile` and then to this. The typed
     * pair would only be needed to serve alternate representations of
     * one URI, and one kaya URI is one representation.
     */
    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
        val file = fileFor(uri) ?: return null
        // Refused rather than silently served read-only: a read-only
        // descriptor handed to a caller that asked to write is a write
        // that vanishes.
        if (mode != "r") {
            throw FileNotFoundException(
                "kaya: $uri is a clipboard payload and readable only, not $mode",
            )
        }
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    /** OpenableColumns: how a consumer asks a pasted file its display
     * name. The answer is the one the interpreter stored beside the
     * bytes. */
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

    // Read-only: the interpreter writes payloads straight into [dir].
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
     * A slot as an INT, with every file name below re-rendered from it,
     * so a path segment cannot name a file outside [dir]. A traversal
     * attempt is not sanitized — it fails to parse.
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
         * PER APPLICATION ID, never a constant: both validation APKs
         * install on the same emulator, and two packages declaring one
         * authority is INSTALL_FAILED_CONFLICTING_PROVIDER on the
         * second install (docs/handoff-clipboard.md). The manifest says
         * `${applicationId}.clip` and this must keep computing it.
         */
        fun authority(context: Context): String = context.packageName + ".clip"

        /**
         * App-private cache, which the platform may reclaim between
         * runs — correct, because the system clears the clip itself
         * (one hour, since Android 13). Created on demand.
         */
        fun dir(context: Context): File =
            File(context.cacheDir, "kaya-clip").apply { mkdirs() }

        fun uri(context: Context, path: String): Uri =
            Uri.parse("content://" + authority(context) + path)

        /** The image payload's URI — one image per clip. */
        fun imageUri(context: Context): Uri = uri(context, "/$IMAGE")

        /** Custom format [slot]'s URI, in the clip's own order. */
        fun customUri(context: Context, slot: Int): Uri = uri(context, "/$CUSTOM/$slot")

        /** File [slot]'s URI, in the clip's own order. */
        fun fileUri(context: Context, slot: Int): Uri = uri(context, "/$FILE/$slot")

        /** PNG — the one image type kaya's protocol carries. */
        fun imagePayload(context: Context): File = File(dir(context), "$IMAGE.png")

        fun customPayload(context: Context, slot: Int): File =
            File(dir(context), "$CUSTOM-$slot.bin")

        /**
         * Custom format [slot]'s id — the mime string [getType] answers
         * with. Beside the bytes rather than in the URI, because the id
         * is the guest's arbitrary string.
         */
        fun customMimeSidecar(context: Context, slot: Int): File =
            File(dir(context), "$CUSTOM-$slot.mime")

        fun filePayload(context: Context, slot: Int): File = File(dir(context), "$FILE-$slot")

        /** File [slot]'s display name, which OpenableColumns answers. */
        fun fileNameSidecar(context: Context, slot: Int): File =
            File(dir(context), "$FILE-$slot.name")

        /**
         * Forget the last clip's payloads — the writer calls this
         * before laying a new one down. The platform never says a clip
         * was replaced, so a shorter clip would otherwise leave a
         * richer one's slots on disk.
         */
        fun clear(context: Context) {
            dir(context).listFiles()?.forEach { it.delete() }
        }
    }
}
