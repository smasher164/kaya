package dev.kaya

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns

/**
 * A picked document's durable reference on Android (docs/restoration-plan.md
 * SR11 to SR13): the platform's persisted URI grant, counted by the
 * platform's own list, so the safe save's temporary grant is never in it.
 * Each answer is `<branch>:<text>`, read by crates/kaya/src/reference.rs.
 */
object KayaReferences {
    private const val CAP = 128
    private const val BOTH =
        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION

    @JvmStatic
    fun mint(context: Context, uri: String): String {
        val resolver = context.contentResolver
        val target = Uri.parse(uri)
        val held = resolver.persistedUriPermissions
        if (held.none { it.uri == target } && held.size >= CAP) return "cap:${held.size}"
        return try {
            resolver.takePersistableUriPermission(target, BOTH)
            "ok:"
        } catch (_: SecurityException) {
            try {
                resolver.takePersistableUriPermission(target, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                "ok:"
            } catch (e: SecurityException) {
                "revoked:the platform refused a lasting grant for $uri (${e.message})"
            }
        }
    }

    @JvmStatic
    fun redeem(context: Context, uri: String): String {
        val resolver = context.contentResolver
        val target = Uri.parse(uri)
        val provider = resolver.acquireUnstableContentProviderClient(target)
            ?: return "gone:no installed provider answers ${target.authority}"
        provider.close()
        if (resolver.persistedUriPermissions.none { it.uri == target && it.isReadPermission }) {
            return "revoked:this app holds no lasting grant for $uri any more"
        }
        return try {
            val fd = resolver.openFileDescriptor(target, "r")
                ?: return "gone:the provider answered no descriptor for $uri"
            fd.close()
            val name = resolver.query(target, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
            "ok:${name ?: target.lastPathSegment ?: ""}"
        } catch (e: java.io.FileNotFoundException) {
            "missing:the provider no longer has $uri (${e.message})"
        } catch (e: SecurityException) {
            "revoked:the provider refused $uri (${e.message})"
        }
    }

    @JvmStatic
    fun forget(context: Context, uri: String): String {
        val target = Uri.parse(uri)
        val held = context.contentResolver.persistedUriPermissions.firstOrNull { it.uri == target }
            ?: return "ok:"
        var flags = 0
        if (held.isReadPermission) flags = flags or Intent.FLAG_GRANT_READ_URI_PERMISSION
        if (held.isWritePermission) flags = flags or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        context.contentResolver.releasePersistableUriPermission(target, flags)
        return "ok:"
    }
}
