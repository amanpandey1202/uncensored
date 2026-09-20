package com.aman.deviceagent

import android.content.Context
import android.provider.Settings

// Re-enables adb / wireless debugging without root or Shizuku.
// Needs WRITE_SECURE_SETTINGS, granted once via:
//   adb shell pm grant com.aman.deviceagent android.permission.WRITE_SECURE_SETTINGS
object Rearm {

    @Volatile private var lastOk = 0L

    fun rearm(ctx: Context): Boolean {
        // Idempotent + cheap; run a few times per minute max.
        val now = System.currentTimeMillis()
        if (now - lastOk < 15_000) return true

        val cr = ctx.contentResolver
        var ok = false
        try {
            Settings.Global.putString(cr, "adb_wifi_enabled", "1")
            Settings.Global.putString(cr, "adb_enabled", "1")
            ok = true
        } catch (e: Exception) {
            // WRITE_SECURE_SETTINGS not granted yet - ignore.
        }
        if (ok) lastOk = now
        return ok
    }
}