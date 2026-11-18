package com.trackensure.screenshare.android

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.text.InputType
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.trackensure.screenshare.CaptureMode
import com.trackensure.screenshare.SessionState
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

/**
 * The driver's screen: link and session status, consent dialogs, End / Control off,
 * a switch to the accessibility settings for remote control, a field to try typing, and the log.
 */
class MainActivity : Activity() {

    private val scope = MainScope()
    private lateinit var status: TextView
    private lateinit var controlStatus: TextView
    private lateinit var endButton: Button
    private lateinit var controlOffButton: Button
    private lateinit var log: TextView
    private var requestDialog: AlertDialog? = null
    private var controlDialog: AlertDialog? = null
    private var counter = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        PocSession.requestProjection = { mode -> askProjection(mode) }
        setContentView(buildLayout())

        if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)

        scope.launch {
            combine(PocSession.link, PocSession.state) { link, state -> link to state }.collect { (link, state) -> render(link, state) }
        }
        scope.launch { PocSession.log.collect { log.text = it.joinToString("\n") } }
    }

    override fun onResume() {
        super.onResume()
        val on = ControlService.instance != null
        controlStatus.text = if (on) "Remote control service: ON" else "Remote control service: OFF — support can only watch"
        controlStatus.setTextColor(if (on) Color.rgb(52, 199, 89) else Color.rgb(255, 149, 0))
    }

    override fun onDestroy() {
        if (PocSession.requestProjection != null) PocSession.requestProjection = null
        scope.cancel()
        super.onDestroy()
    }

    // MARK: capture consent

    private fun askProjection(mode: CaptureMode) {
        val manager = getSystemService(MediaProjectionManager::class.java)
        val intent = if (Build.VERSION.SDK_INT >= 34) {
            // Device mode: whole screen only. App mode: the system lets the driver pick a single app.
            val config = if (mode == CaptureMode.DEVICE) MediaProjectionConfig.createConfigForDefaultDisplay()
            else MediaProjectionConfig.createConfigForUserChoice()
            manager.createScreenCaptureIntent(config)
        } else {
            manager.createScreenCaptureIntent()
        }
        @Suppress("DEPRECATION")
        startActivityForResult(intent, REQUEST_PROJECTION)
    }

    @Deprecated("Activity result API is enough for a single request here")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_PROJECTION) {
            PocSession.onProjectionResult(if (resultCode == RESULT_OK) data else null)
        }
    }

    // MARK: rendering

    private fun render(link: PocSession.Link, state: SessionState) {
        val linkText = when (link) {
            PocSession.Link.SEARCHING -> "Looking for the support server…"
            PocSession.Link.CONNECTING -> "Connecting…"
            PocSession.Link.ONLINE -> "Support can reach you"
            PocSession.Link.RECONNECTING -> "Reconnecting…"
            PocSession.Link.OFFLINE -> "Offline, retrying"
        }
        val sessionText = when (state) {
            is SessionState.Idle -> ""
            is SessionState.Requested -> "\n${state.supportName} asks to see your screen"
            is SessionState.Streaming -> "\nSupport is viewing · control ${if (state.controlEnabled) "ON" else "off"}"
            is SessionState.Ended -> "\nSession ended: ${state.reason}"
        }
        status.text = linkText + sessionText
        status.setTextColor(if (state is SessionState.Streaming) Color.rgb(255, 59, 48) else Color.DKGRAY)

        val streaming = state as? SessionState.Streaming
        endButton.visibility = if (streaming != null) View.VISIBLE else View.GONE
        controlOffButton.visibility = if (streaming?.controlEnabled == true) View.VISIBLE else View.GONE

        if (state is SessionState.Requested) showRequest(state) else { requestDialog?.dismiss(); requestDialog = null }
        if (streaming?.controlRequested == true) showControlRequest() else { controlDialog?.dismiss(); controlDialog = null }
    }

    private fun showRequest(state: SessionState.Requested) {
        if (requestDialog?.isShowing == true) return
        val what = if (state.mode == CaptureMode.DEVICE) "your whole screen" else "this app"
        requestDialog = AlertDialog.Builder(this)
            .setTitle("${state.supportName} wants to see $what")
            .setMessage("They will see what is on the screen until you end the session. They cannot control anything unless you allow it separately.")
            .setPositiveButton("Accept") { _, _ -> PocSession.log("driver pressed Accept"); PocSession.controller.accept() }
            .setNegativeButton("Decline") { _, _ -> PocSession.log("driver pressed Decline"); PocSession.controller.decline() }
            .setCancelable(false)
            .show()
    }

    private fun showControlRequest() {
        if (controlDialog?.isShowing == true) return
        val serviceOn = ControlService.instance != null
        controlDialog = AlertDialog.Builder(this)
            .setTitle("Support asks to control the screen")
            .setMessage(
                if (serviceOn) "They will be able to tap, scroll and type. You can turn it off at any time."
                else "Remote control is off on this phone. Turn on “ScreenShare PoC remote control” in Accessibility first."
            )
            .setPositiveButton("Allow") { _, _ -> PocSession.log("driver pressed Allow control"); PocSession.controller.grantControl() }
            .setNegativeButton("Deny") { _, _ -> PocSession.log("driver pressed Deny control"); PocSession.controller.denyControl() }
            .apply { if (!serviceOn) setNeutralButton("Open settings") { _, _ -> openAccessibilitySettings() } }
            .setCancelable(false)
            .show()
    }

    private fun openAccessibilitySettings() {
        startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
    }

    // MARK: layout

    private fun buildLayout(): View {
        val padding = (16 * resources.displayMetrics.density).toInt()
        status = TextView(this).apply { textSize = 18f; setTypeface(typeface, Typeface.BOLD) }
        controlStatus = TextView(this).apply { textSize = 14f }
        endButton = button("End session") { PocSession.log("driver pressed End"); PocSession.controller.endByDriver() }
        controlOffButton = button("Control off") { PocSession.log("driver pressed Control off"); PocSession.controller.revokeControl() }
        val counterLabel = TextView(this).apply { text = "Taps: 0"; textSize = 16f }
        log = TextView(this).apply { textSize = 11f; typeface = Typeface.MONOSPACE }

        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(padding, padding, padding, padding)
            addView(TextView(context).apply { text = "ScreenShare PoC · Android"; textSize = 22f; setTypeface(typeface, Typeface.BOLD) })
            addView(status)
            addView(controlStatus)
            addView(endButton)
            addView(controlOffButton)
            addView(button("Remote control settings (Accessibility)") { openAccessibilitySettings() })
            addView(header("Try it"))
            addView(button("Tap me") { counter++; counterLabel.text = "Taps: $counter"; PocSession.log("demo button tapped: $counter") })
            addView(counterLabel)
            addView(EditText(context).apply { hint = "Login" })
            // Android 15+ hides the whole app from screen sharing while a password field is on screen
            // ("App content hidden from screen share for security"), so the field is shown on demand.
            val password = EditText(context).apply {
                hint = "Password"
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
                visibility = View.GONE
            }
            addView(button("Show / hide password field") {
                password.visibility = if (password.visibility == View.GONE) View.VISIBLE else View.GONE
                PocSession.log("password field ${if (password.visibility == View.VISIBLE) "shown" else "hidden"}")
            })
            addView(password)
            addView(header("Log"))
            addView(log)
        }
        return ScrollView(this).apply {
            addView(content)
            setBackgroundColor(Color.WHITE)
            // Edge-to-edge is enforced from Android 15: keep the content clear of the status and nav bars.
            setOnApplyWindowInsetsListener { view, insets ->
                val bars = insets.getInsets(android.view.WindowInsets.Type.systemBars())
                view.setPadding(0, bars.top, 0, bars.bottom)
                insets
            }
        }
    }

    private fun header(text: String) = TextView(this).apply {
        this.text = text
        textSize = 13f
        setTextColor(Color.GRAY)
        setPadding(0, (20 * resources.displayMetrics.density).toInt(), 0, 4)
    }

    private fun button(title: String, onClick: () -> Unit) =
        Button(this).apply { text = title; isAllCaps = false; setOnClickListener { onClick() } }

    private companion object {
        const val REQUEST_PROJECTION = 42
    }
}
