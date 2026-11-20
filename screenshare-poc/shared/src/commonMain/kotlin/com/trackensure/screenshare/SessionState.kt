/* States of one support session as seen by the driver app; owned by SessionController. */
package com.trackensure.screenshare

/** Idle → Requested → Streaming → Ended, with Ended → Idle via SessionController.reset or a new request. */
sealed interface SessionState {
    /** No session and no pending request. */
    data object Idle : SessionState

    /** Support asked; waiting for the driver's Accept / Decline until [deadlineMillis]. */
    data class Requested(val supportName: String, val mode: CaptureMode, val deadlineMillis: Long) : SessionState

    /**
     * Driver accepted; the screen is being shared.
     * [paused] means capture is temporarily off (app backgrounded, device locked, phone call),
     * [controlRequested] means support asked for control and the driver has not answered yet,
     * [controlEnabled] means support's control commands are executed.
     */
    data class Streaming(
        val mode: CaptureMode,
        val paused: Boolean,
        val controlRequested: Boolean,
        val controlEnabled: Boolean,
    ) : SessionState

    /** Session is over; [reason] is shown to the driver. */
    data class Ended(val reason: String) : SessionState
}
