package com.aman.deviceagent

import android.Manifest
import android.app.admin.DevicePolicyManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Color
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.AudioManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.view.Display
import android.view.accessibility.AccessibilityNodeInfo
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

object CommandRunner {

    fun run(ctx: Context, action: String, p: Map<String, String>): String {
        return try {
            when (action) {
                "ping" -> "pong DeviceAgent 1.0"
                "battery" -> battery(ctx)
                "screen" -> screen(ctx)
                "wifi" -> wifi(ctx)
                "state" -> state(ctx)
                "fg" -> foreground()
                "screenshot" -> screenshot(ctx)
                "screenshot_raw" -> {
                    val b = screenshotPng(ctx)
                    if (b != null) "OK bytes=${b.size}" else "ERR screenshot failed"
                }
                "tap" -> tap(ctx, p)
                "swipe" -> swipe(ctx, p)
                "type" -> type(ctx, p)
                "key" -> key(p)
                "home" -> doGlobal(GLOBAL_HOME)
                "back" -> doGlobal(GLOBAL_BACK)
                "recents" -> doGlobal(GLOBAL_RECENTS)
                "notifications" -> doGlobal(GLOBAL_NOTIFICATIONS)
                "quick" -> doGlobal(GLOBAL_QUICK_SETTINGS)
                "torch" -> torch(ctx, p)
                "vol" -> volume(ctx, p)
                "vibrate" -> vibrate(ctx, p)
                "speak" -> speak(ctx, p)
                "notify" -> notify(ctx, p)
                "open" -> open(ctx, p)
                "lock" -> lock(ctx)
                "clipboard" -> clipboard(ctx, p)
                "rearm" -> if (Rearm.rearm(ctx)) "OK rearmed" else "ERR rearm failed (grant WRITE_SECURE_SETTINGS via adb)"
                else -> "ERR unknown action"
            }
        } catch (e: Exception) {
            "ERR ${e.javaClass.simpleName}: ${e.message}"
        }
    }

    // ----- state queries ----------------------------------------------------

    private fun battery(ctx: Context): String {
        val b = ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = b?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = b?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
        return "battery:${(level * 100) / scale}%"
    }

    private fun screen(ctx: Context): String {
        val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
        return "screen:${if (pm.isInteractive) "ON" else "OFF"}"
    }

    private fun foreground(): String {
        val a = AccessibilityHolder.instance
        return if (a == null) "fg:ERR accessibility not enabled" else "fg:${a.lastPackage}"
    }

    private fun state(ctx: Context): String {
        return listOf(battery(ctx), screen(ctx), wifi(ctx), foreground()).joinToString("\n")
    }

    private fun wifi(ctx: Context): String {
        val wm = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as android.net.wifi.WifiManager
        val ci = wm.connectionInfo
        val ssid = ci.ssid?.removeSurrounding("\"")
        return "wifi:${if (!ssid.isNullOrBlank()) ssid else "no-wifi"}"
    }

    // ----- accessibility actions ---------------------------------------------

    private val acc: AccessibilityAgent?
        get() = AccessibilityHolder.instance

    private const val GLOBAL_HOME = android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_HOME
    private const val GLOBAL_BACK = android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK
    private const val GLOBAL_RECENTS = android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_RECENTS
    private const val GLOBAL_NOTIFICATIONS = android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_NOTIFICATIONS
    private const val GLOBAL_QUICK_SETTINGS = android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_QUICK_SETTINGS

    private fun doGlobal(a: Int): String {
        val ok = acc?.doGlobal(a) ?: return "ERR accessibility not enabled"
        return if (ok) "OK" else "ERR global action rejected"
    }

    private fun tap(ctx: Context, p: Map<String, String>): String {
        val x = p["x"]?.toFloatOrNull() ?: return "ERR missing x"
        val y = p["y"]?.toFloatOrNull() ?: return "ERR missing y"
        val a = acc ?: return "ERR accessibility not enabled"
        return if (a.fire(AccessibilityAgent.tap(x, y))) "OK tap $x,$y" else "ERR gesture rejected"
    }

    private fun swipe(ctx: Context, p: Map<String, String>): String {
        val x1 = p["x1"]?.toFloatOrNull() ?: return "ERR missing x1"
        val y1 = p["y1"]?.toFloatOrNull() ?: return "ERR missing y1"
        val x2 = p["x2"]?.toFloatOrNull() ?: p["x"]?.toFloatOrNull() ?: return "ERR missing x2"
        val y2 = p["y2"]?.toFloatOrNull() ?: p["y"]?.toFloatOrNull() ?: return "ERR missing y2"
        val ms = p["ms"]?.toLongOrNull() ?: 300
        val a = acc ?: return "ERR accessibility not enabled"
        return if (a.fire(AccessibilityAgent.swipe(x1, y1, x2, y2, ms))) "OK swipe" else "ERR gesture rejected"
    }

    private fun type(ctx: Context, p: Map<String, String>): String {
        val text = p["text"] ?: return "ERR missing text"
        val a = acc ?: return "ERR accessibility not enabled"
        val root = a.rootInActiveWindow ?: return "ERR no window"
        val target = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: findEditable(root)
        if (target == null) {
            // fallback: set clipboard (usually the app has a paste option)
            setClipboard(ctx, text)
            return "OK clipboard set (paste manually) - no editable field found"
        }
        val b = Bundle().apply { putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text) }
        return if (target.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, b)) "OK typed" else "ERR set-text rejected"
    }

    private fun findEditable(n: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        if (n.isEditable && n.isEnabled) return n
        for (i in 0 until n.childCount) {
            val child = n.getChild(i) ?: continue
            val r = findEditable(child)
            child.recycle()
            if (r != null) return r
        }
        return null
    }

    private fun key(p: Map<String, String>): String {
        val name = (p["name"] ?: p["code"] ?: "").lowercase().replace("_", ".")
        return when (name) {
            "home" -> doGlobal(GLOBAL_HOME)
            "back" -> doGlobal(GLOBAL_BACK)
            "recents" -> doGlobal(GLOBAL_RECENTS)
            "notif", "notifications" -> doGlobal(GLOBAL_NOTIFICATIONS)
            "quick", "quicksettings" -> doGlobal(GLOBAL_QUICK_SETTINGS)
            else -> "ERR key '$name' unsupported (no root: only home/back/recents/notifications/quick)"
        }
    }

    // ----- screenshots -------------------------------------------------------

    private fun screenshot(ctx: Context): String {
        if (Build.VERSION.SDK_INT < 30) return "ERR needs Android 11+"
        val a = acc ?: return "ERR accessibility not enabled (enable it in settings first)"

        val latch = CountDownLatch(1)
        var result = "OK"

        a.takeScreenshot(
            Display.DEFAULT_DISPLAY,
            ctx.mainExecutor,
            object : android.accessibilityservice.AccessibilityService.TakeScreenshotCallback {
                override fun onSuccess(screenshot: android.accessibilityservice.AccessibilityService.ScreenshotResult) {
                    try {
                        val hb = screenshot.hardwareBuffer
                        val wrapped = Bitmap.wrapHardwareBuffer(hb, screenshot.colorSpace)
                        val bmp = wrapped?.copy(Bitmap.Config.ARGB_8888, false) ?: run {
                            hb.close()
                            result = "ERR failed to copy screenshot"
                            latch.countDown()
                            return
                        }
                        val dir = File(ctx.getExternalFilesDir(null), "screenshots").apply { mkdirs() }
                        val name = "shot_${System.currentTimeMillis()}.png"
                        File(dir, name).outputStream().use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
                        hb.close()
                        result = "OK ${dir.absolutePath}/$name"
                    } catch (e: Exception) {
                        result = "ERR save: ${e.message}"
                    }
                    latch.countDown()
                }

                override fun onFailure(errorCode: Int) {
                    result = "ERR screenshot code=$errorCode"
                    latch.countDown()
                }
            }
        )

        return if (latch.await(10, TimeUnit.SECONDS)) result else "ERR screenshot timeout"
    }

    // Same capture but returns the raw PNG bytes - used by the /shot endpoint so
    // the PC can pull a live screen over the internet without adb/scrcpy.
    fun screenshotPng(ctx: Context): ByteArray? {
        if (Build.VERSION.SDK_INT < 30) return null
        val a = acc ?: return null

        val latch = CountDownLatch(1)
        var bytes: ByteArray? = null

        a.takeScreenshot(
            Display.DEFAULT_DISPLAY,
            ctx.mainExecutor,
            object : android.accessibilityservice.AccessibilityService.TakeScreenshotCallback {
                override fun onSuccess(screenshot: android.accessibilityservice.AccessibilityService.ScreenshotResult) {
                    try {
                        val hb = screenshot.hardwareBuffer
                        val wrapped = Bitmap.wrapHardwareBuffer(hb, screenshot.colorSpace)
                        val bmp = wrapped?.copy(Bitmap.Config.ARGB_8888, false)
                        if (bmp != null) {
                            val bos = java.io.ByteArrayOutputStream()
                            bmp.compress(Bitmap.CompressFormat.PNG, 100, bos)
                            bytes = bos.toByteArray()
                            bmp.recycle()
                        }
                        hb.close()
                    } catch (_: Exception) { }
                    latch.countDown()
                }

                override fun onFailure(errorCode: Int) { latch.countDown() }
            }
        )

        return if (latch.await(10, TimeUnit.SECONDS)) bytes else null
    }

    // ----- hardware / ui -----------------------------------------------------

    private fun torch(ctx: Context, p: Map<String, String>): String {
        if (ctx.checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED)
            return "ERR camera permission not granted"
        val on = p["on"] != "0"
        val cm = ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val id = try {
            cm.cameraIdList.firstOrNull {
                try { cm.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK }
                catch (e: Exception) { false }
            } ?: cm.cameraIdList.firstOrNull() ?: return "ERR no camera"
        } catch (e: Exception) { return "ERR ${e.message}" }
        try {
            cm.setTorchMode(id, on)
            return "OK torch $on"
        } catch (e: Exception) {
            return "ERR ${e.message}"
        }
    }

    private fun volume(ctx: Context, p: Map<String, String>): String {
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        when (p["cmd"] ?: p["action"]) {
            "up" -> { am.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_RAISE, 0); return "OK volume up" }
            "down" -> { am.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_LOWER, 0); return "OK volume down" }
        }
        val lvl = p["level"]?.toIntOrNull() ?: return "ERR missing level"
        am.setStreamVolume(AudioManager.STREAM_MUSIC, lvl.coerceIn(0, max), 0)
        return "OK volume $lvl"
    }

    private fun vibrate(ctx: Context, p: Map<String, String>): String {
        val ms = p["ms"]?.toLongOrNull() ?: 1000
        val v = ctx.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
        if (Build.VERSION.SDK_INT >= 26) v.vibrate(VibrationEffect.createOneShot(ms, VibrationEffect.DEFAULT_AMPLITUDE))
        else @Suppress("DEPRECATION") v.vibrate(ms)
        return "OK vibrate $ms"
    }

    private fun speak(ctx: Context, p: Map<String, String>): String {
        val text = p["text"] ?: return "ERR missing text"
        val tts = AgentService.tts
        if (tts == null) {
            AgentService.initTts(ctx) // will pick it up on the next call a second later
            return "ERR TTS initializing, retry in 1s"
        }
        val id = "speak${System.currentTimeMillis()}"
        val r = tts.speak(text, android.speech.tts.TextToSpeech.QUEUE_FLUSH, null, id)
        return if (r == android.speech.tts.TextToSpeech.SUCCESS) "OK speak" else "ERR tts busy"
    }

    private fun notify(ctx: Context, p: Map<String, String>): String {
        val title = p["title"] ?: "DeviceAgent"
        val msg = p["msg"] ?: ""
        val nm = ctx.getSystemService(android.app.NotificationManager::class.java)
        val ch = android.app.NotificationChannel("phone-events", "Phone events", android.app.NotificationManager.IMPORTANCE_DEFAULT)
        nm.createNotificationChannel(ch)
        val n = android.app.Notification.Builder(ctx, "phone-events")
            .setSmallIcon(android.R.drawable.ic_menu_info_details)
            .setContentTitle(title)
            .setContentText(msg)
            .setAutoCancel(true)
            .build()
        nm.notify((System.currentTimeMillis() % Int.MAX_VALUE).toInt(), n)
        return "OK notify"
    }

    private fun open(ctx: Context, p: Map<String, String>): String {
        val target = p["url"] ?: p["pkg"] ?: return "ERR missing url or pkg"
        val intent = if (target.startsWith("http")) {
            Intent(Intent.ACTION_VIEW, Uri.parse(target)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        } else {
            ctx.packageManager.getLaunchIntentForPackage(target)
            ?: return "ERR package not installed: $target"
        }
        ctx.startActivity(intent)
        return "OK open $target"
    }

    private fun lock(ctx: Context): String {
        val dpm = ctx.getSystemService(android.app.admin.DevicePolicyManager::class.java)
        val cn = ComponentName(ctx, AgentDeviceAdmin::class.java)
        return if (dpm.isAdminActive(cn)) { dpm.lockNow(); "OK locked" }
        else "ERR device-admin not active (activate in the app)"
    }

    private fun clipboard(ctx: Context, p: Map<String, String>): String {
        val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val cmd = p["cmd"] ?: p["action"]
        return when (cmd) {
            "get", "read" -> cm.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(ctx)?.toString() ?: "ERR empty"
            "set", "write" -> { setClipboard(ctx, p["text"] ?: ""); "OK set" }
            else -> "ERR usage: clipboard?cmd=get | clipboard?cmd=set&text=..."
        }
    }

    private fun setClipboard(ctx: Context, text: String) {
        val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        cm.setPrimaryClip(ClipData.newPlainText("agent", text))
    }
}