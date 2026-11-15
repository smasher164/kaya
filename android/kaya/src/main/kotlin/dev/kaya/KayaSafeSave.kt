package dev.kaya

import android.content.Context
import android.content.Intent
import android.net.Uri

/**
 * The ContentResolver half of the safe save (docs/rich-document-plan.md
 * §4.1, crates/kaya/src/safesave.rs). CALLED FROM THE CORE, on whatever
 * thread the guest saved from, with the APPLICATION Context: the next
 * launch's classification runs before any Activity is mounted.
 */
object KayaSafeSave {
    private const val READ_WRITE =
        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION

    /** Step 1: 1 when the app already held a persistable read and write
     * grant on [uri], 0 when kaya took one now, 2 when the provider offers
     * none to take (a pasted or dropped URI). */
    @JvmStatic
    fun takeGrant(context: Context, uri: String): Int {
        val parsed = Uri.parse(uri)
        val resolver = context.contentResolver
        val held = resolver.persistedUriPermissions.any {
            it.uri == parsed && it.isReadPermission && it.isWritePermission
        }
        if (held) return 1
        return try {
            resolver.takePersistableUriPermission(parsed, READ_WRITE)
            0
        } catch (e: SecurityException) {
            2
        }
    }

    @JvmStatic
    fun releaseGrant(context: Context, uri: String) {
        try {
            context.contentResolver.releasePersistableUriPermission(Uri.parse(uri), READ_WRITE)
        } catch (e: SecurityException) {
            // Nothing persisted to release.
        }
    }

    /** `openFileDescriptor(uri, mode)` then `detachFd()`: the descriptor
     * crosses to the core. */
    @JvmStatic
    fun open(context: Context, uri: String, mode: String): Int {
        val pfd = context.contentResolver.openFileDescriptor(Uri.parse(uri), mode)
            ?: throw java.io.IOException("the provider returned no descriptor for $uri")
        return pfd.detachFd()
    }
}
