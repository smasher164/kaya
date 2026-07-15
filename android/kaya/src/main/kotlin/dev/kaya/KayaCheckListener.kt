package dev.kaya

import android.widget.CompoundButton

/**
 * Translates a checkbox flip into an occurrence on the native side;
 * never calls app code. The uncontrolled contract's toggle half: the
 * box owns its checked bit and reports each change, programmatic
 * setChecked included (which is what lets the selftest click like a
 * user). The sibling of [KayaClickListener] and [KayaTextWatcher].
 */
class KayaCheckListener(private val widgetId: Long) : CompoundButton.OnCheckedChangeListener {
    override fun onCheckedChanged(buttonView: CompoundButton, isChecked: Boolean) =
        nativeCheckedChanged(widgetId, isChecked)

    private external fun nativeCheckedChanged(widgetId: Long, isChecked: Boolean)
}
