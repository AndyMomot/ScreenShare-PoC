package com.trackensure.screenshare

sealed interface SessionState {
    data object Idle : SessionState

    /** Support asked; waiting for the driver's Accept / Decline until [deadlineMillis]. */
    data class Requested(val supportName: String, val mode: CaptureMode, val deadlineMillis: Long) : SessionState

    data class Streaming(
        val mode: CaptureMode,
        val paused: Boolean,
        val controlRequested: Boolean,
        val controlEnabled: Boolean,
    ) : SessionState

    data class Ended(val reason: String) : SessionState
}
