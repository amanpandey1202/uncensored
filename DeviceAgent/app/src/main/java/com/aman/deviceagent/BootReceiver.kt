package com.aman.deviceagent

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        if (!SettingsStore.startOnBoot) return
        try { Rearm.rearm(context) } catch (_: Exception) { }
        val i = Intent(context, AgentService::class.java)
        try {
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(i) else context.startService(i)
        } catch (_: Exception) { /* startForegroundService from background can throw; retry is harmless */ }
    }
}