package com.aman.deviceagent

import android.Manifest
import android.app.Activity
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.provider.Settings
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast

class MainActivity : Activity() {

    private lateinit var portEdit: EditText
    private lateinit var tokenEdit: EditText
    private lateinit var pcUrlEdit: EditText
    private lateinit var notifyCheck: CheckBox
    private lateinit var bootCheck: CheckBox
    private lateinit var statusText: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val dp = resources.displayMetrics.density
        fun dpd(v: Int) = (v * dp).toInt()

        val scroll = ScrollView(this)
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dpd(16), dpd(16), dpd(16), dpd(16))
        }
        scroll.addView(col)

        fun label(t: String) = TextView(this).apply {
            text = t
            textSize = 18f
            setPadding(0, dpd(10), 0, dpd(2))
        }
        fun hint(t: String) = TextView(this).apply {
            text = t
            textSize = 12f
            alpha = 0.6f
        }

        col.addView(TextView(this).apply { text = "DeviceAgent"; textSize = 24f })

        // --- agent server ---
        col.addView(label("Agent port"))
        portEdit = EditText(this).apply {
            isSingleLine = true
            inputType = android.text.InputType.TYPE_CLASS_NUMBER
            setText(SettingsStore.port.toString())
        }
        col.addView(portEdit)
        hint("TCP port the agent listens on (bridge-settings.txt agent-port column, default 8766).")

        col.addView(label("Bearer token"))
        tokenEdit = EditText(this).apply {
            isSingleLine = true
            setText(SettingsStore.token)
        }
        col.addView(tokenEdit)
        hint("Leave blank to allow anyone on your network. Set the same value as in bridge-settings.txt TOKEN.")

        col.addView(label("PC bridge URL"))
        pcUrlEdit = EditText(this).apply {
            isSingleLine = true
            setText(SettingsStore.pcUrl)
        }
        col.addView(pcUrlEdit)
        hint("Used by the notification proxy. Default = your PC (Tailscale).")

        // --- toggles ---
        notifyCheck = CheckBox(this).apply {
            text = "Forward notifications to the PC"
            isChecked = SettingsStore.notifyToPc
        }
        bootCheck = CheckBox(this).apply {
            text = "Start agent on device boot"
            isChecked = SettingsStore.startOnBoot
        }
        col.addView(notifyCheck)
        col.addView(bootCheck)

        // --- actions ---
        fun actionBtn(t: String, fn: (Button) -> Unit) = Button(this).apply {
            text = t
            setOnClickListener { fn(this) }
        }

        col.addView(actionBtn("Save") {
            saveSettings()
            toast("Settings saved")
        })
        col.addView(actionBtn("Start agent") {
            saveSettings()
            AgentService.request(this)
            refreshStatus()
            toast("Agent starting on port ${SettingsStore.port}")
        })
        col.addView(actionBtn("Stop agent") {
            stopService(Intent(this, AgentService::class.java))
            refreshStatus()
            toast("Agent stopped")
        })

        col.addView(actionBtn("Enable accessibility (recommended)") { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) })
        col.addView(actionBtn("Enable notification listener") { startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)) })
        col.addView(actionBtn("Grant camera (torch)") {
            if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(arrayOf(Manifest.permission.CAMERA), 700)
            } else toast("Camera already granted")
        })
        col.addView(actionBtn("Activate device admin (lock)") {
            val dpm = getSystemService(DevicePolicyManager::class.java)
            val cn = ComponentName(this, AgentDeviceAdmin::class.java)
            if (!dpm.isAdminActive(cn)) {
                startActivity(Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN).apply {
                    putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, cn)
                    putExtra(DevicePolicyManager.EXTRA_ADD_EXPLANATION, "Allows the agent to lock this phone remotely.")
                })
            } else toast("Device admin already active")
        })

        col.addView(actionBtn("Open agent command log") {
            showStatusDialog()
        })

        statusText = TextView(this).apply {
            setPadding(0, dpd(16), 0, 0)
            textSize = 13f
        }
        col.addView(statusText)

        setContentView(scroll)
    }

    override fun onResume() {
        super.onResume()
        refreshStatus()
    }

    private fun refreshStatus() {
        val running = serviceExists()
        statusText.text = "Status: ${if (running) "RUNNING on port ${AgentService.port}" else "STOPPED"}\n" +
            "Accessibility: ${if (AccessibilityHolder.instance != null) "ON" else "off"}\n" +
            "Notify proxy: ${if (SettingsStore.notifyToPc) "ON" else "off"}"
    }

    private fun serviceExists(): Boolean {
        val running = (getSystemService(android.app.ActivityManager::class.java))
            .getRunningServices(Int.MAX_VALUE).any { it.service.className == AgentService::class.java.name }
        return running
    }

    private fun saveSettings() {
        SettingsStore.port = portEdit.text.toString().toIntOrNull()?.coerceIn(1024, 65535) ?: 8766
        SettingsStore.token = tokenEdit.text.toString().trim()
        SettingsStore.pcUrl = pcUrlEdit.text.toString().trim()
        SettingsStore.notifyToPc = notifyCheck.isChecked
        SettingsStore.startOnBoot = bootCheck.isChecked
    }

    private fun showStatusDialog() {
        val sb = StringBuilder()
        sb.append("Agent port   : ${SettingsStore.port}\n")
        sb.append("PC bridge URL: ${SettingsStore.pcUrl}\n")
        sb.append("token set    : ${if (SettingsStore.token.isEmpty()) "no" else "yes"}\n")
        sb.append("notify->PC   : ${SettingsStore.notifyToPc}\n")
        val d = android.app.AlertDialog.Builder(this).setTitle("Status").setMessage(sb).setPositiveButton("OK", null).create()
        d.show()
    }

    private fun toast(m: String) = Toast.makeText(this, m, Toast.LENGTH_SHORT).show()
}