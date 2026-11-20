package com.trackensure.screenshare

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlin.time.Clock
import kotlin.time.ExperimentalTime

/**
 * Session rules shared by both platforms: the driver must accept, control needs a second consent,
 * the driver can revoke control or end the session at any time, an unanswered request expires.
 *
 * Platform-neutral: all I/O goes through [engine]. [scope] and [now] are injectable so tests can
 * drive the request timeout with a test dispatcher and a fixed clock.
 */
@OptIn(ExperimentalTime::class)
class SessionController(
    private val engine: ScreenShareEngine,
    private val requestTimeoutMillis: Long = DEFAULT_REQUEST_TIMEOUT_MILLIS,
    private val scope: CoroutineScope = MainScope(),
    private val now: () -> Long = { Clock.System.now().toEpochMilliseconds() },
) {
    /** Swift sees no Kotlin default arguments; this is the constructor the iOS app calls. */
    constructor(engine: ScreenShareEngine) : this(engine, DEFAULT_REQUEST_TIMEOUT_MILLIS)

    private val _state = MutableStateFlow<SessionState>(SessionState.Idle)
    /** Current session state; the platform UI renders from it. */
    val state: StateFlow<SessionState> = _state.asStateFlow()

    /** Expires the current request after [requestTimeoutMillis]; cancelled on accept, decline or end. */
    private var timeoutJob: Job? = null

    /** Raw text from the data channel. */
    fun onRemoteMessage(text: String) {
        when (val message = MessageCodec.decode(text) ?: return) {
            is MsgRequest -> onRequest(message)
            is MsgEnd -> finish(reason = "Ended by ${message.by}", notifyRemote = false)
            MsgControlRequest -> updateStreaming { it.copy(controlRequested = true) }
            is MsgPointer -> if (_state.value is SessionState.Streaming) engine.showPointer(message.x, message.y)
            is ControlCommand -> onCommand(message)
            else -> Unit
        }
    }

    /** Driver tapped Accept: switches to Streaming, tells support, starts capture and sends the first status. */
    fun accept() {
        val requested = _state.value as? SessionState.Requested ?: return
        timeoutJob?.cancel()
        _state.value = SessionState.Streaming(
            mode = requested.mode,
            paused = false,
            controlRequested = false,
            controlEnabled = false,
        )
        send(MsgAccept)
        engine.startCapture(requested.mode)
        sendStatus()
    }

    /** Driver tapped Decline while a request is pending. */
    fun decline() {
        if (_state.value !is SessionState.Requested) return
        timeoutJob?.cancel()
        send(MsgDecline("declined"))
        _state.value = SessionState.Ended("Declined")
    }

    /** Driver consented to remote control. */
    fun grantControl() = updateStreaming { it.copy(controlRequested = false, controlEnabled = true) }

    /** Driver refused remote control; viewing continues. */
    fun denyControl() = updateStreaming { it.copy(controlRequested = false) }

    /** Turns control off while viewing continues. */
    fun revokeControl() = updateStreaming { it.copy(controlEnabled = false) }

    /** The platform reports that capture paused (app in background) or resumed. */
    fun setPaused(paused: Boolean) = updateStreaming { it.copy(paused = paused) }

    /** Driver tapped End; support is notified. */
    fun endByDriver() = finish(reason = "Ended by driver", notifyRemote = true)

    /** Lets the UI start over after Ended. */
    fun reset() {
        if (_state.value is SessionState.Ended) _state.value = SessionState.Idle
    }

    /** Swift cannot collect a Kotlin Flow directly; this bridges it to a callback. */
    fun watchState(onChange: (SessionState) -> Unit): Cancellable {
        val job = scope.launch { state.collect { onChange(it) } }
        return Cancellable { job.cancel() }
    }

    /**
     * A new request is honoured only when no session is active, so a second support request
     * cannot hijack a running session. Starts the expiry timer.
     */
    private fun onRequest(message: MsgRequest) {
        val current = _state.value
        if (current !is SessionState.Idle && current !is SessionState.Ended) return
        _state.value = SessionState.Requested(message.supportName, message.mode, now() + requestTimeoutMillis)
        timeoutJob?.cancel()
        timeoutJob = scope.launch {
            delay(requestTimeoutMillis)
            if (_state.value is SessionState.Requested) {
                send(MsgDecline("timeout"))
                _state.value = SessionState.Ended("No answer")
            }
        }
    }

    /**
     * Runs a control command only when the driver has granted control and capture is live.
     * Every command gets an ack (reliable) so the support page can show success or the reason it failed.
     */
    private fun onCommand(command: ControlCommand) {
        val streaming = _state.value as? SessionState.Streaming
        val failure = when {
            streaming == null -> "no session"
            !streaming.controlEnabled -> "control disabled by driver"
            streaming.paused -> "app in background"
            else -> engine.execute(command)
        }
        send(MsgAck(command.id, ok = failure == null, detail = failure), reliable = true)
    }

    /** Common end path; [notifyRemote] is false when support itself ended the session. */
    private fun finish(reason: String, notifyRemote: Boolean) {
        val current = _state.value
        if (current is SessionState.Idle || current is SessionState.Ended) return
        timeoutJob?.cancel()
        if (current is SessionState.Streaming) engine.stopCapture()
        if (notifyRemote) send(MsgEnd("driver"))
        _state.value = SessionState.Ended(reason)
    }

    /** Applies [change] to a Streaming state and publishes a status only if something actually changed. */
    private fun updateStreaming(change: (SessionState.Streaming) -> SessionState.Streaming) {
        val streaming = _state.value as? SessionState.Streaming ?: return
        val updated = change(streaming)
        if (updated == streaming) return
        _state.value = updated
        sendStatus()
    }

    /** Sends one status label to the support page; paused takes priority over a pending control request. */
    private fun sendStatus() {
        val streaming = _state.value as? SessionState.Streaming ?: return
        val label = when {
            streaming.paused -> "paused"
            streaming.controlRequested -> "control_requested"
            else -> "streaming"
        }
        send(MsgStatus(label, streaming.controlEnabled))
    }

    private fun send(message: Message, reliable: Boolean = true) =
        engine.sendMessage(MessageCodec.encode(message), reliable)

    companion object {
        const val DEFAULT_REQUEST_TIMEOUT_MILLIS = 60_000L
    }
}

/** Handle returned to Swift by [SessionController.watchState] to stop observing. */
fun interface Cancellable {
    fun cancel()
}
