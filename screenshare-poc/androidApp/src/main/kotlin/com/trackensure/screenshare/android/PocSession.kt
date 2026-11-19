package com.trackensure.screenshare.android

import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import com.trackensure.screenshare.CaptureMode
import com.trackensure.screenshare.ControlCommand
import com.trackensure.screenshare.ScreenShareEngine
import com.trackensure.screenshare.SessionController
import com.trackensure.screenshare.SessionState
import io.livekit.android.LiveKit
import io.livekit.android.events.RoomEvent
import io.livekit.android.events.collect
import io.livekit.android.room.Room
import io.livekit.android.room.track.DataPublishReliability
import io.livekit.android.room.track.LocalVideoTrackOptions
import io.livekit.android.room.track.VideoCaptureParameter
import io.livekit.android.room.track.screencapture.ScreenCaptureParams
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL

/**
 * Process-wide session: the LiveKit room, the shared session rules and the link to the Mac.
 * Lives outside the Activity so the session keeps running while another app is in front.
 */
object PocSession : ScreenShareEngine {
    enum class Link { SEARCHING, CONNECTING, ONLINE, RECONNECTING, OFFLINE }

    private val scope = MainScope()
    private lateinit var app: Context
    private lateinit var room: Room
    lateinit var controller: SessionController
        private set

    private val _link = MutableStateFlow(Link.SEARCHING)
    val link: StateFlow<Link> = _link
    private val _log = MutableStateFlow<List<String>>(emptyList())
    val log: StateFlow<List<String>> = _log
    val state: StateFlow<SessionState> get() = controller.state

    /** Set by the visible Activity: asks the system for screen capture consent. */
    var requestProjection: ((CaptureMode) -> Unit)? = null

    private var host: String? = null
    private var joining: Job? = null
    private var retry = 0
    private var started = false

    val isEmulator: Boolean
        get() = Build.FINGERPRINT.contains("generic") || Build.HARDWARE.contains("ranchu") ||
            Build.PRODUCT.contains("sdk") || Build.MODEL.contains("Emulator")

    fun start(context: Context) {
        if (started) return
        started = true
        app = context.applicationContext
        room = LiveKit.create(app)
        controller = SessionController(this)
        DiagLog.log("app", "launch · ${Build.MANUFACTURER} ${Build.MODEL} Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})${if (isEmulator) " · emulator" else ""}")

        scope.launch { room.events.collect { onRoomEvent(it) } }
        scope.launch {
            controller.state.collect { state ->
                log("session → $state")
                if (state is SessionState.Ended) {
                    delay(3000)
                    controller.reset()
                }
            }
        }
        findServer()
    }

    // MARK: server

    /** The emulator reaches the Mac at 10.0.2.2; a real phone finds it through the Bonjour announcement. */
    private fun findServer() {
        if (isEmulator) {
            serverFound("10.0.2.2", "emulator host alias")
            return
        }
        val nsd = app.getSystemService(Context.NSD_SERVICE) as NsdManager
        nsd.discoverServices("_screensharepoc._tcp", NsdManager.PROTOCOL_DNS_SD, object : NsdManager.DiscoveryListener {
            override fun onServiceFound(service: NsdServiceInfo) {
                @Suppress("DEPRECATION")
                nsd.resolveService(service, object : NsdManager.ResolveListener {
                    override fun onServiceResolved(info: NsdServiceInfo) {
                        val txt = info.attributes["host"]?.let { String(it) }
                        @Suppress("DEPRECATION")
                        val address = txt ?: info.host?.hostAddress ?: return
                        scope.launch { serverFound(address, info.serviceName) }
                    }
                    override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) = log("resolve failed: $errorCode")
                })
            }
            override fun onServiceLost(service: NsdServiceInfo) = log("server announcement gone")
            override fun onDiscoveryStarted(serviceType: String) = log("looking for the support server…")
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) = log("discovery failed: $errorCode")
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
        })
    }

    private fun serverFound(address: String, name: String) {
        log("found $name at $address")
        if (host == address && _link.value == Link.ONLINE) return
        host = address
        DiagLog.host = address
        join()
    }

    private fun join() {
        val target = host ?: return
        if (joining?.isActive == true || room.state != Room.State.DISCONNECTED) return
        _link.value = Link.CONNECTING
        joining = scope.launch {
            try {
                val token = withContext(Dispatchers.IO) {
                    val connection = URL("http://$target:8080/token?identity=${if (isEmulator) "driver-android-emu" else "driver-android"}&name=Driver&room=demo")
                        .openConnection() as HttpURLConnection
                    connection.connectTimeout = 5000
                    connection.readTimeout = 5000
                    connection.inputStream.bufferedReader().readText()
                }
                room.connect("ws://$target:7880", token)
                retry = 0
            } catch (e: Exception) {
                log("join failed: ${e.message}")
                scheduleRetry()
            }
        }
    }

    private fun scheduleRetry() {
        _link.value = Link.OFFLINE
        val seconds = listOf(1, 2, 4, 8, 10)[retry.coerceAtMost(4)]
        retry++
        scope.launch {
            delay(seconds * 1000L)
            join()
        }
    }

    private fun onRoomEvent(event: RoomEvent) {
        when (event) {
            is RoomEvent.Connected -> { _link.value = Link.ONLINE; log("online") }
            is RoomEvent.Reconnecting -> { _link.value = Link.RECONNECTING; log("reconnecting") }
            is RoomEvent.Reconnected -> { _link.value = Link.ONLINE; log("reconnected") }
            is RoomEvent.Disconnected -> {
                log("disconnected: ${event.reason}")
                val state = controller.state.value
                if (state is SessionState.Streaming || state is SessionState.Requested) controller.endByDriver()
                scheduleRetry()
            }
            is RoomEvent.DataReceived -> {
                val text = String(event.data)
                if (!text.contains("\"pointer\"")) log("← $text")
                controller.onRemoteMessage(text)
            }
            else -> Unit
        }
    }

    // MARK: ScreenShareEngine (called by the shared SessionController on the main thread)

    override fun sendMessage(json: String, reliable: Boolean) {
        log("→ $json")
        scope.launch {
            room.localParticipant.publishData(
                json.toByteArray(),
                if (reliable) DataPublishReliability.RELIABLE else DataPublishReliability.LOSSY,
            )
        }
    }

    override fun startCapture(mode: CaptureMode) {
        val ask = requestProjection
        if (ask == null) {
            log("no visible screen to ask for capture consent → ending")
            controller.endByDriver()
            return
        }
        log("asking for capture consent ($mode)")
        ask(mode)
    }

    /** Result of the system consent dialog; null when the driver cancelled it. */
    fun onProjectionResult(data: Intent?) {
        if (data == null) {
            log("capture consent cancelled → ending")
            controller.endByDriver()
            return
        }
        scope.launch {
            try {
                // At most 1280 on the long side, 15 fps, in the display's own proportions: a frame of
                // another shape gets black bars, and the support's clicks would land off target.
                val (width, height) = frameSize(1280)
                room.screenShareTrackCaptureDefaults = LocalVideoTrackOptions(
                    isScreencast = true,
                    // LiveKit takes the long side first and turns it to the display's orientation itself;
                    // no output crop, the virtual display already has the right shape.
                    captureParams = VideoCaptureParameter(maxOf(width, height), minOf(width, height), 15, adaptOutputToDimensions = false),
                )
                log("capture size ${width}×$height")
                val ok = room.localParticipant.setScreenShareEnabled(
                    true,
                    ScreenCaptureParams(data, notificationId = 7, notification = sharingNotification(), onStop = {
                        scope.launch {
                            log("system stopped the screen capture → ending")
                            if (controller.state.value is SessionState.Streaming) controller.endByDriver()
                        }
                    }),
                )
                log(if (ok) "capture started" else "capture did not start")
                if (!ok) controller.endByDriver()
            } catch (e: Exception) {
                log("capture failed: ${e.message}")
                controller.endByDriver()
            }
        }
    }

    private fun frameSize(longSide: Int): Pair<Int, Int> {
        val windowManager = app.getSystemService(Context.WINDOW_SERVICE) as android.view.WindowManager
        val (w, h) = if (Build.VERSION.SDK_INT >= 30) {
            windowManager.maximumWindowMetrics.bounds.let { it.width() to it.height() }
        } else {
            val metrics = android.util.DisplayMetrics()
            @Suppress("DEPRECATION") windowManager.defaultDisplay.getRealMetrics(metrics)
            metrics.widthPixels to metrics.heightPixels
        }
        val scale = longSide.toDouble() / maxOf(w, h)
        fun even(v: Double) = (v / 2).toInt() * 2
        return even(w * scale) to even(h * scale)
    }

    /** Android requires a visible notification while the screen is captured; tapping it opens the app. */
    private fun sharingNotification(): Notification {
        val open = PendingIntent.getActivity(
            app, 0, Intent(app, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(app, SHARING_CHANNEL)
            .setSmallIcon(android.R.drawable.presence_video_online)
            .setContentTitle("Support is viewing your screen")
            .setContentText("Open the app to end the session or turn control off")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    override fun stopCapture() {
        scope.launch {
            runCatching { room.localParticipant.setScreenShareEnabled(false) }
            log("capture stopped")
            // Publishing a new screen track on the same connection fails in LiveKit Android ("order of m-lines
            // in subsequent offer doesn't match"), so the next session never gets video. Rejoin with a clean
            // connection after every session.
            log("rejoining for a clean next session")
            retry = 0
            room.disconnect()
        }
    }

    override fun showPointer(x: Double, y: Double) {
        ControlService.instance?.showPointer(x, y)
    }

    override fun execute(command: ControlCommand): String? {
        val service = ControlService.instance
            ?: return "remote control is off on the phone (Settings → Accessibility → ScreenShare PoC)"
        val failure = service.execute(command)
        log("exec $command → ${failure ?: "ok"}")
        return failure
    }

    fun log(line: String) {
        DiagLog.log("app", line)
        _log.value = (listOf(line) + _log.value).take(200)
    }
}
