package dev.kaya

import android.content.Context

/**
 * The preferences store's Android backing (docs/tasks-s4-plan.md P2, §4),
 * for `crates/kaya/src/prefs_android.rs`. The core names the domain — the
 * app's declared id, or `<id>.selftest` under the harness — and nothing
 * here composes one.
 *
 * TYPE PER KEY, READ WITHOUT A THROW: the core's `get` is untyped, so it
 * asks what is stored AND what type it is. `getAll()` answers both, which
 * is why no typed getter is called here at all — `getString` on a key
 * holding a Long throws ClassCastException, and a caught throw at a JNI
 * boundary is a pending exception waiting to detonate at the next
 * unrelated call.
 *
 * A DOUBLE IS A ONE-ELEMENT STRING SET (docs/tasks-s4-plan.md §4, the
 * ANDROID F64 note): this store's float is 32-bit, so `putFloat` would
 * answer 0.1 back as 0.10000000149011612 while the other four backings
 * answer 0.1 — a silent wrong value. `putLong(doubleToRawLongBits(v))` is
 * exact but reads back as an i64, and a typed get on another type must
 * answer absent. The set is exact in both.
 */
object KayaPrefs {
    /** The value tags the core and this file share, one leading char. */
    private const val TAG_STRING = "s"
    private const val TAG_I64 = "i"
    private const val TAG_F64 = "f"
    private const val TAG_BOOL = "b"

    @JvmStatic
    fun open(context: Context, domain: String) =
        context.getSharedPreferences(domain, Context.MODE_PRIVATE)!!

    /**
     * `<tag><text>` for a key this domain holds, or null for absent and
     * for a value written by something other than kaya (an Int or a Float
     * from another writer, a set that is not one string).
     */
    @JvmStatic
    fun get(context: Context, domain: String, key: String): String? =
        tagged(open(context, domain).all[key])

    /**
     * The type dispatch alone, pure so KayaPrefsTest can watch the
     * absent-on-mismatch rule on the host JVM — no leg reaches a key
     * kaya did not write, and no scene stores a float.
     */
    internal fun tagged(held: Any?): String? =
        when (held) {
            is String -> TAG_STRING + held
            is Long -> TAG_I64 + held.toString()
            is Boolean -> TAG_BOOL + (if (held) "true" else "false")
            is Set<*> -> {
                val one = held.singleOrNull()
                if (one is String) TAG_F64 + one else null
            }
            else -> null
        }

    /**
     * Durable when this returns — `commit()`, never `apply()`
     * (docs/tasks-s4-plan.md P3: a crash a millisecond later loses
     * nothing).
     */
    @JvmStatic
    fun set(context: Context, domain: String, key: String, tag: String, value: String): Boolean {
        val edit = open(context, domain).edit()
        when (tag) {
            TAG_STRING -> edit.putString(key, value)
            TAG_I64 -> edit.putLong(key, value.toLongOrNull() ?: return false)
            TAG_F64 -> edit.putStringSet(key, setOf(value))
            TAG_BOOL -> edit.putBoolean(key, value == "true")
            else -> return false
        }
        return edit.commit()
    }

    @JvmStatic
    fun remove(context: Context, domain: String, key: String): Boolean =
        open(context, domain).edit().remove(key).commit()

    @JvmStatic
    fun clear(context: Context, domain: String): Boolean =
        open(context, domain).edit().clear().commit()
}
