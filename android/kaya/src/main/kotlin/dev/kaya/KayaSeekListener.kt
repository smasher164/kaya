package dev.kaya

import android.widget.SeekBar

/**
 * Translates a slider move into an occurrence on the native side;
 * never calls app code. The uncontrolled contract's numeric half: the
 * bar owns its position and reports each change, programmatic
 * setProgress included (which is what lets the selftest drag like a
 * user). SeekBar is integer-valued; the native side owns the mapping
 * between its fixed 0..10000 progress range and the wire's f64 range.
 * The sibling of [KayaCheckListener].
 */
class KayaSeekListener(private val widgetId: Long) : SeekBar.OnSeekBarChangeListener {
    override fun onProgressChanged(seekBar: SeekBar, progress: Int, fromUser: Boolean) =
        nativeProgressChanged(widgetId, progress)

    override fun onStartTrackingTouch(seekBar: SeekBar) {}

    override fun onStopTrackingTouch(seekBar: SeekBar) {}

    private external fun nativeProgressChanged(widgetId: Long, progress: Int)
}
