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

@Serializable @SerialName("accept") data object MsgAccept : Message
@Serializable @SerialName("decline") data class MsgDecline(val reason: String) : Message

/** Either side ends the session; [by] is "driver" or "support". */
@Serializable @SerialName("end") data class MsgEnd(val by: String) : Message

/** Driver → support: what the support page should show (streaming, paused, control on/off). */
@Serializable @SerialName("status")
data class MsgStatus(val state: String, val controlEnabled: Boolean) : Message

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

@Serializable @SerialName("tap")
data class CmdTap(override val id: Long, val x: Double, val y: Double) : ControlCommand

@Serializable @SerialName("swipe")
data class CmdSwipe(
    override val id: Long,
    val x1: Double, val y1: Double,
    val x2: Double, val y2: Double,
    val ms: Long = 300,
) : ControlCommand

@Serializable @SerialName("text")
data class CmdText(override val id: Long, val value: String) : ControlCommand

@Serializable @SerialName("back")
data class CmdBack(override val id: Long) : ControlCommand

@Serializable
enum class CaptureMode {
    @SerialName("app") APP,
    @SerialName("device") DEVICE,
}

object MessageCodec {
    private val json = Json {
        classDiscriminator = "type"
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    fun encode(message: Message): String = json.encodeToString(Message.serializer(), message)

    /** Returns null for malformed or unknown messages instead of throwing across the iOS boundary. */
    fun decode(text: String): Message? =
        runCatching { json.decodeFromString(Message.serializer(), text) }.getOrNull()
}
