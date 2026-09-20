package com.aman.deviceagent

import android.app.Notification
import android.os.Build
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import java.net.URL
import java.net.URLEncoder
import java.util.concurrent.Executors

class NotifyProxy : NotificationListenerService() {

    private val exec = Executors.newSingleThreadExecutor()
    private val lastSent = HashMap<String, Long>()

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (!SettingsStore.notifyToPc) return
        val pc = SettingsStore.pcUrl.trimEnd('/')
        if (pc.isEmpty()) return
        val pkg = sbn.packageName ?: return
        if (pkg == packageName) return // don't echo our own events

        val key = "$pkg|${sbn.id}"
        val now = System.currentTimeMillis()
        val prev = lastSent[key] ?: 0L
        if (now - prev < 8000) return
        lastSent[key] = now
        if (lastSent.size > 500) lastSent.clear()

        val extras = sbn.notification.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: ""
        val from = extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString() ?: pkg

        val url = "$pc/action/notify?from=${enc(from)}&title=${enc(title)}&msg=${enc(text)}"
        exec.execute {
            try {
                URL(url).openStream().use { it.readBytes() }
            } catch (_: Exception) { /* PC not reachable right now - ignore */ }
        }
    }

    override fun onListenerConnected() {
        // Drop throttling state if the service is re-bound
        lastSent.clear()
    }

    private fun enc(s: String): String = URLEncoder.encode(s, "UTF-8").replace("+", "%20")
}