package com.trackensure.screenshare.android

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager

const val SHARING_CHANNEL = "screen-sharing"

class PocApp : Application() {
    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(SHARING_CHANNEL, "Screen sharing", NotificationManager.IMPORTANCE_LOW)
        )
        PocSession.start(this)
    }
}
