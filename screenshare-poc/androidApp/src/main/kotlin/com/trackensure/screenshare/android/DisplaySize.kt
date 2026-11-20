package com.trackensure.screenshare.android

import android.content.Context
import android.os.Build
import android.util.DisplayMetrics
import android.view.WindowManager

/**
 * Full size of the default display in pixels, bars included. The capture frame and the remote-control
 * gestures both use this one function, so a click on the support page maps to the same point the frame shows.
 */
internal fun fullDisplaySize(context: Context): Pair<Int, Int> {
    val windowManager = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
    return if (Build.VERSION.SDK_INT >= 30) {
        windowManager.maximumWindowMetrics.bounds.let { it.width() to it.height() }
    } else {
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION") windowManager.defaultDisplay.getRealMetrics(metrics)
        metrics.widthPixels to metrics.heightPixels
    }
}
