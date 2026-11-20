package com.trackensure.screenshare.android

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Test-run diagnostics: logcat plus batches to the Mac's `POST /log` (logs/poc.log), like the iOS app. */
object DiagLog {
    /** Mac address to send logs to; null until server discovery finds it (lines are buffered meanwhile). */
    @Volatile var host: String? = null

    /** Unsent lines; capped at 2000 so an unreachable Mac cannot grow memory without bound. */
    private val pending = ArrayList<String>()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val time = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)

    // One background loop sends the buffer every second instead of one request per line.
    init {
        scope.launch {
            while (true) {
                delay(1000)
                flush()
            }
        }
    }

    /** Writes [message] to logcat and queues it for the Mac. */
    fun log(tag: String, message: String) {
        val line = synchronized(time) { "${time.format(Date())} [$tag] $message" }
        Log.i("ScreenSharePoC", line)
        synchronized(pending) {
            pending += line
            if (pending.size > 2000) pending.subList(0, pending.size - 2000).clear()
        }
    }

    /** Posts the queued lines; on any failure puts them back at the front so order is kept for the next try. */
    private fun flush() {
        val target = host ?: return
        val lines = synchronized(pending) {
            if (pending.isEmpty()) return
            ArrayList(pending).also { pending.clear() }
        }
        val ok = runCatching {
            val connection = URL("http://$target:8080/log").openConnection() as HttpURLConnection
            connection.requestMethod = "POST"
            connection.connectTimeout = 3000
            connection.readTimeout = 3000
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            val body = JSONObject().put("source", "android").put("lines", JSONArray(lines)).toString()
            connection.outputStream.use { it.write(body.toByteArray()) }
            connection.responseCode == 204
        }.getOrDefault(false)
        if (!ok) synchronized(pending) { pending.addAll(0, lines) }
    }
}
