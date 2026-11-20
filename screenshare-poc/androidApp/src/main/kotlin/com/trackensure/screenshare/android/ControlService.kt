package com.trackensure.screenshare.android

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Context
import android.content.Intent
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import com.trackensure.screenshare.CmdBack
import com.trackensure.screenshare.CmdSwipe
import com.trackensure.screenshare.CmdTap
import com.trackensure.screenshare.CmdText
import com.trackensure.screenshare.ControlCommand

/**
 * Remote control through the public accessibility API: real gestures anywhere on the device
 * (other apps, system screens, dialogs, web content), text into the focused field, global Back.
 * The driver turns it on once in Settings → Accessibility; it acts only on commands that the shared
 * session rules let through (session running and control allowed).
 */
class ControlService : AccessibilityService() {

    companion object {
        /** The running service, or null while the driver has it turned off; PocSession reaches it through this. */
        @Volatile var instance: ControlService? = null
            private set
    }

    private var pointer: PointerView? = null
    /** Main-thread handler used to hide the pointer after a pause in pointer moves. */
    private val main = Handler(Looper.getMainLooper())

    override fun onServiceConnected() {
        instance = this
        DiagLog.log("control", "accessibility service connected")
    }

    override fun onUnbind(intent: Intent?): Boolean {
        instance = null
        removePointer()
        DiagLog.log("control", "accessibility service disconnected")
        return super.onUnbind(intent)
    }

    // The service only acts on commands; it does not need to react to accessibility events.
    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit
    override fun onInterrupt() = Unit

    /** Returns null when the command was carried out, otherwise a short reason. */
    fun execute(command: ControlCommand): String? {
        val (width, height) = screenSize()
        return when (command) {
            is CmdTap -> {
                val x = (command.x * width).toFloat()
                val y = (command.y * height).toFloat()
                DiagLog.log("control", "tap at (${x.toInt()}, ${y.toInt()}) of ${width}×$height")
                // A tap is a stroke of a single point held for 60 ms.
                gesture(Path().apply { moveTo(x, y) }, 60, command.id)
            }
            is CmdSwipe -> {
                val path = Path().apply {
                    moveTo((command.x1 * width).toFloat(), (command.y1 * height).toFloat())
                    lineTo((command.x2 * width).toFloat(), (command.y2 * height).toFloat())
                }
                DiagLog.log("control", "swipe ${command.ms} ms")
                gesture(path, command.ms.coerceIn(50, 2000), command.id)
            }
            is CmdText -> typeText(command.value)
            is CmdBack -> if (performGlobalAction(GLOBAL_ACTION_BACK)) null else "back failed"
            else -> "unsupported command"
        }
    }

    /**
     * Dispatches one stroke. The result only says whether the system accepted the gesture;
     * it is performed asynchronously, so a later cancellation is just logged.
     */
    private fun gesture(path: Path, durationMs: Long, commandId: Long): String? {
        val stroke = GestureDescription.StrokeDescription(path, 0, durationMs)
        val gesture = GestureDescription.Builder().addStroke(stroke).build()
        val accepted = dispatchGesture(gesture, object : GestureResultCallback() {
            override fun onCancelled(gestureDescription: GestureDescription?) {
                DiagLog.log("control", "gesture cancelled by the system")
                // The command was already acknowledged as accepted; correct it for the support page.
                PocSession.reportLateFailure(commandId, "gesture cancelled by the system")
            }
        }, null)
        return if (accepted) null else "gesture rejected"
    }

    /**
     * ACTION_SET_TEXT replaces the whole field, so the new text is appended to the current content.
     * A field showing only its hint counts as empty, otherwise the hint would be kept as text.
     */
    private fun typeText(value: String): String? {
        val node = rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            ?: return "no focused text field (tap a field first)"
        val current = if (Build.VERSION.SDK_INT >= 26 && node.isShowingHintText) "" else node.text?.toString().orEmpty()
        val arguments = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, current + value)
        }
        val ok = node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)
        DiagLog.log("control", "text into ${node.className} (${node.viewIdResourceName ?: "no id"}) → $ok")
        return if (ok) null else "the field refused the text"
    }

    /** Full display size: MediaProjection captures the whole display, bars included. */
    private fun screenSize(): Pair<Int, Int> = fullDisplaySize(this)

    // MARK: pointer — an accessibility overlay draws over every app without the "draw over apps" permission.

    /** Adds the overlay on first use, moves the dot and hides it 1.5 s after the last move. */
    fun showPointer(x: Double, y: Double) {
        val view = pointer ?: PointerView(this).also { view ->
            val params = WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.MATCH_PARENT,
                WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT,
            )
            (getSystemService(Context.WINDOW_SERVICE) as WindowManager).addView(view, params)
            pointer = view
        }
        val (width, height) = screenSize()
        view.move((x * width).toFloat(), (y * height).toFloat())
        main.removeCallbacksAndMessages(null)
        main.postDelayed({ view.move(null, null) }, 1500)
    }

    /** Removes the overlay window when the service is unbound. */
    private fun removePointer() {
        pointer?.let { runCatching { (getSystemService(Context.WINDOW_SERVICE) as WindowManager).removeView(it) } }
        pointer = null
    }

    /** Full-screen, untouchable view that draws one red dot; null coordinates hide it. */
    private class PointerView(context: Context) : View(context) {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.argb(200, 255, 59, 48) }
        private var px: Float? = null
        private var py: Float? = null

        fun move(x: Float?, y: Float?) {
            px = x; py = y
            invalidate()
        }

        override fun onDraw(canvas: Canvas) {
            val x = px ?: return
            val y = py ?: return
            // The overlay may start below the status bar; draw in screen coordinates.
            val location = IntArray(2).also { getLocationOnScreen(it) }
            canvas.drawCircle(x - location[0], y - location[1], 28f, paint)
        }
    }
}
