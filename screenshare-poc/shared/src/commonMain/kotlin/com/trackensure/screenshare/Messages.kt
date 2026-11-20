/*
 * Wire protocol between the driver app and the support web page. Every message is one JSON object
 * whose "type" field names the class (see the @SerialName values); web/index.html builds and parses
 * the same shapes by hand, so renaming a field or a type name here breaks the support page.
 */
package com.trackensure.screenshare

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** Everything that travels between the driver app and the support page over the data channel. */
@Serializable
sealed interface Message

/** Support → driver: asks the driver to start a session. */
@Serializable @SerialName("request")
data class MsgRequest(val supportName: String, val mode: CaptureMode = CaptureMode.APP) : Message

/** Driver → support: the driver accepted the request; video follows. */
@Serializable @SerialName("accept") data object MsgAccept : Message
/** Driver → support: no session; [reason] is "declined" (driver tapped Decline) or "timeout". */
@Serializable @SerialName("decline") data class MsgDecline(val reason: String) : Message

/** Either side ends the session; [by] is "driver" or "support". */
@Serializable @SerialName("end") data class MsgEnd(val by: String) : Message

/** Driver → support: what the support page should show (streaming, paused, control on/off). */
@Serializable @SerialName("status")
data class MsgStatus(val state: String, val controlEnabled: Boolean) : Message

/** Support → driver: asks for remote control; the driver has to grant it separately from viewing. */
@Serializable @SerialName("control_request") data object MsgControlRequest : Message

/** Support → driver: lossy pointer position, normalized 0..1 to the captured frame. */
@Serializable @SerialName("pointer") data class MsgPointer(val x: Double, val y: Double) : Message

/** Driver → support: the result of a control command with the same [id]. */
@Serializable @SerialName("ack")
data class MsgAck(val id: Long, val ok: Boolean, val detail: String? = null) : Message

/** Control commands; coordinates are normalized 0..1 to the captured frame. */
@Serializable
sealed interface ControlCommand : Message {
    val id: Long
}

/** Single tap at ([x], [y]). */
@Serializable @SerialName("tap")
data class CmdTap(override val id: Long, val x: Double, val y: Double) : ControlCommand

/** Straight-line drag from ([x1], [y1]) to ([x2], [y2]) lasting [ms] milliseconds. */
@Serializable @SerialName("swipe")
data class CmdSwipe(
    override val id: Long,
    val x1: Double, val y1: Double,
    val x2: Double, val y2: Double,
    val ms: Long = 300,
) : ControlCommand

/** Types [value] into whatever field currently has focus on the driver's screen. */
@Serializable @SerialName("text")
data class CmdText(override val id: Long, val value: String) : ControlCommand

/** Platform "back" action (system back on Android, the app's own navigation back on iOS). */
@Serializable @SerialName("back")
data class CmdBack(override val id: Long) : ControlCommand

@Serializable
/** What the driver shares: only this app's own UI ([APP]) or the whole device screen ([DEVICE]). */
enum class CaptureMode {
    @SerialName("app") APP,
    @SerialName("device") DEVICE,
}

/** Single place that turns [Message]s into JSON text and back, so both platforms use identical settings. */
object MessageCodec {
    /*
     * "type" matches what the web page sends; unknown keys are ignored so the page can add fields
     * without breaking older apps; defaults are encoded so the page always sees every field.
     */
    private val json = Json {
        classDiscriminator = "type"
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    /** Serializes any [Message] with its "type" discriminator. */
    fun encode(message: Message): String = json.encodeToString(Message.serializer(), message)

    /** Returns null for malformed or unknown messages instead of throwing across the iOS boundary. */
    fun decode(text: String): Message? =
        runCatching { json.decodeFromString(Message.serializer(), text) }.getOrNull()
}
