package com.trackensure.screenshare

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
/** Session rules of [SessionController], driven through raw JSON exactly as the data channel delivers it. */
class SessionControllerTest {

    /** Records what the controller sends and executes; decodes outgoing JSON so assertions work on typed messages. */
    private class FakeEngine : ScreenShareEngine {
        val sent = mutableListOf<Message>()
        val executed = mutableListOf<ControlCommand>()
        var capturing = false

        override fun sendMessage(json: String, reliable: Boolean) {
            sent += MessageCodec.decode(json)!!
        }
        override fun startCapture(mode: CaptureMode) { capturing = true }
        override fun stopCapture() { capturing = false }
        override fun showPointer(x: Double, y: Double) = Unit
        override fun execute(command: ControlCommand): String? = null.also { executed += command }
    }

    /** Controller on the test's virtual clock, so the request timeout can be advanced instantly. */
    private fun TestScope.controller(engine: FakeEngine) =
        SessionController(engine, requestTimeoutMillis = 1_000, scope = backgroundScope, now = { testScheduler.currentTime })

    private val request = """{"type":"request","supportName":"Support","mode":"app"}"""

    @Test
    fun accept_afterRequest_streamsAndStartsCapture() = runTest {
        val engine = FakeEngine()
        val controller = controller(engine)

        controller.onRemoteMessage(request)
        controller.accept()

        val state = assertIs<SessionState.Streaming>(controller.state.value)
        assertEquals(false, state.controlEnabled)
        assertTrue(engine.capturing)
        assertTrue(MsgAccept in engine.sent)
    }

    @Test
    fun request_withoutAnswer_expiresWithDecline() = runTest {
        val engine = FakeEngine()
        val controller = controller(engine)

        controller.onRemoteMessage(request)
        advanceTimeBy(1_001)
        runCurrent()

        assertIs<SessionState.Ended>(controller.state.value)
        assertTrue(MsgDecline("timeout") in engine.sent)
    }

    @Test
    fun command_beforeControlGranted_isRejected() = runTest {
        val engine = FakeEngine()
        val controller = controller(engine)
        controller.onRemoteMessage(request)
        controller.accept()

        controller.onRemoteMessage("""{"type":"tap","id":7,"x":0.5,"y":0.5}""")

        assertTrue(engine.executed.isEmpty())
        assertEquals(MsgAck(7, ok = false, detail = "control disabled by driver"), engine.sent.last())
    }

    @Test
    fun command_afterControlGranted_isExecutedAndAcked() = runTest {
        val engine = FakeEngine()
        val controller = controller(engine)
        controller.onRemoteMessage(request)
        controller.accept()
        controller.onRemoteMessage("""{"type":"control_request"}""")
        controller.grantControl()

        controller.onRemoteMessage("""{"type":"tap","id":8,"x":0.25,"y":0.75}""")

        assertEquals(listOf<ControlCommand>(CmdTap(8, 0.25, 0.75)), engine.executed)
        assertEquals(MsgAck(8, ok = true), engine.sent.last())
    }

    @Test
    fun revokeControl_keepsViewing() = runTest {
        val engine = FakeEngine()
        val controller = controller(engine)
        controller.onRemoteMessage(request)
        controller.accept()
        controller.grantControl()

        controller.revokeControl()

        val state = assertIs<SessionState.Streaming>(controller.state.value)
        assertEquals(false, state.controlEnabled)
        assertTrue(engine.capturing)
    }

    @Test
    fun endFromSupport_stopsCapture() = runTest {
        val engine = FakeEngine()
        val controller = controller(engine)
        controller.onRemoteMessage(request)
        controller.accept()

        controller.onRemoteMessage("""{"type":"end","by":"support"}""")

        assertIs<SessionState.Ended>(controller.state.value)
        assertEquals(false, engine.capturing)
    }
}
