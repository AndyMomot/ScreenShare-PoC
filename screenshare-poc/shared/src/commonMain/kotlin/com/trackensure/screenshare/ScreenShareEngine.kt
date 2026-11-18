package com.trackensure.screenshare

/**
 * Platform side of a session: transport, capture and command execution.
 * iOS implements it in Swift (LiveKit + ReplayKit / ScreenCaptureKit), Android in Kotlin.
 */
interface ScreenShareEngine {
    fun sendMessage(json: String, reliable: Boolean)
    fun startCapture(mode: CaptureMode)
    fun stopCapture()
    fun showPointer(x: Double, y: Double)

    /** Executes a command on screen; returns null on success or a short failure reason. */
    fun execute(command: ControlCommand): String?
}
