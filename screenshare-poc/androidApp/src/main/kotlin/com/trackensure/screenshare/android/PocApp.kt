/* Application entry point: creates the notification channel and starts the session singleton. */
package com.trackensure.screenshare.android

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager

/** Notification channel for the ongoing "screen is being shared" notification. */
const val SHARING_CHANNEL = "screen-sharing"

/** Starts [PocSession] at process start so the app is reachable by support even before any screen opens. */
class PocApp : Application() {
    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(SHARING_CHANNEL, "Screen sharing", NotificationManager.IMPORTANCE_LOW)
        )
        PocSession.start(this)
    }
}
