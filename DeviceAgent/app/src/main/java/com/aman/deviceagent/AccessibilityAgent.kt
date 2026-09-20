package com.aman.deviceagent

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Context
import android.graphics.Path
import android.view.accessibility.AccessibilityEvent

object AccessibilityHolder {
    var instance: AccessibilityAgent? = null
}

class AccessibilityAgent : AccessibilityService() {

    @Volatile
    var lastPackage: String = ""

    override fun onServiceConnected() {
        super.onServiceConnected()
        AccessibilityHolder.instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event?.packageName != null) lastPackage = event.packageName.toString()
    }

    override fun onInterrupt() {}

    override fun onUnbind(intent: android.content.Intent?): Boolean {
        AccessibilityHolder.instance = null
        return super.onUnbind(intent)
    }

    fun doGlobal(action: Int): Boolean = try { performGlobalAction(action) } catch (e: Exception) { false }

    // Fire a gesture (tap / swipe). Returns true if the gesture was accepted.
    fun fire(gesture: GestureDescription): Boolean = try { dispatchGesture(gesture, null, null) } catch (e: Exception) { false }

    companion object {

        fun tap(x: Float, y: Float): GestureDescription {
            val p = Path().apply { moveTo(x, y) }
            return GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(p, 0, 80))
                .build()
        }

        fun swipe(x1: Float, y1: Float, x2: Float, y2: Float, durMs: Long): GestureDescription {
            val p = Path().apply { moveTo(x1, y1); lineTo(x2, y2) }
            return GestureDescription.Builder()
                .addStroke(GestureDescription.StrokeDescription(p, 0, durMs))
                .build()
        }
    }
}