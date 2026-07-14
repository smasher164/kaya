package dev.kaya

import android.view.View

/**
 * Translates a click into an occurrence on the native side; never calls
 * app code. The backend's equivalent of AppKit target-action or a GTK
 * signal handler.
 */
class KayaClickListener(private val widgetId: Long) : View.OnClickListener {
    override fun onClick(v: View) = nativeClick(widgetId)

    private external fun nativeClick(widgetId: Long)
}
