package com.trackensure.screenshare

/**
 * Platform side of a session: transport, capture and command execution.
 * iOS implements it in Swift (LiveKit + ReplayKit / ScreenCaptureKit), Android in Kotlin.
 */
interface ScreenShareEngine {
    /** Sends JSON text to the support page; [reliable] false allows the transport to drop it (lossy, low latency). */
    fun sendMessage(json: String, reliable: Boolean)
    /** Starts publishing the screen in the given [mode]; called once the driver accepts. */
    fun startCapture(mode: CaptureMode)
    /** Stops publishing video; called when the session ends. */
    fun stopCapture()
    /** Draws the support pointer at normalized ([x], [y]) on the driver's screen. */
    fun showPointer(x: Double, y: Double)

    /** Executes a command on screen; returns null on success or a short failure reason. */
    fun execute(command: ControlCommand): String?
}
