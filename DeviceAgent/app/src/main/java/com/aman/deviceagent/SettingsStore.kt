package com.aman.deviceagent

import android.content.Context
import android.content.SharedPreferences

object SettingsStore {

    private const val PREFS = "agent"

    fun get(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    var port: Int
        get() = get(App.app).getInt("port", 8766)
        set(v) = get(App.app).edit().putInt("port", v).apply()

    var token: String
        get() = get(App.app).getString("token", "").orEmpty()
        set(v) = get(App.app).edit().putString("token", v).apply()

    var pcUrl: String
        get() = get(App.app).getString("pcUrl", "http://0.0.0.0:8765").orEmpty()
        set(v) = get(App.app).edit().putString("pcUrl", v).apply()

    var notifyToPc: Boolean
        get() = get(App.app).getBoolean("notifyToPc", false)
        set(v) = get(App.app).edit().putBoolean("notifyToPc", v).apply()

    var startOnBoot: Boolean
        get() = get(App.app).getBoolean("startOnBoot", true)
        set(v) = get(App.app).edit().putBoolean("startOnBoot", v).apply()

    var phoneName: String
        get() = get(App.app).getString("phoneName", "").orEmpty()
        set(v) = get(App.app).edit().putString("phoneName", v).apply()

    var reportSec: Int
        get() = get(App.app).getInt("reportSec", 15)
        set(v) = get(App.app).edit().putInt("reportSec", v).apply()

    var autoRearm: Boolean
        get() = get(App.app).getBoolean("autoRearm", true)
        set(v) = get(App.app).edit().putBoolean("autoRearm", v).apply()
}

object App {
    lateinit var app: android.app.Application
}