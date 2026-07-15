package dev.kaya

import android.text.Editable
import android.text.TextWatcher

/**
 * Translates an entry edit into an occurrence on the native side; never
 * calls app code. The uncontrolled contract's Android half: the widget
 * owns its text and reports each change, programmatic setText included
 * (which is what lets the selftest type like a user). The sibling of
 * [KayaClickListener].
 */
class KayaTextWatcher(private val widgetId: Long) : TextWatcher {
    override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}

    override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}

    override fun afterTextChanged(s: Editable?) = nativeTextChanged(widgetId, s?.toString() ?: "")

    private external fun nativeTextChanged(widgetId: Long, text: String)
}
