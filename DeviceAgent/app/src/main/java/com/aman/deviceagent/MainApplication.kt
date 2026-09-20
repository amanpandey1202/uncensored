package com.aman.deviceagent

import android.app.Application

class MainApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        App.app = this
    }
}