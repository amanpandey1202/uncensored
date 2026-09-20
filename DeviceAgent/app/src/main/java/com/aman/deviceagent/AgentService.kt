package com.aman.deviceagent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.speech.tts.TextToSpeech
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean

object TtsHolder {
    var holder: TextToSpeech? = null
}

class AgentService : Service() {

    companion object {
        val tts: TextToSpeech? get() = TtsHolder.holder
        @Volatile var port: Int = 0

        fun initTts(ctx: Context) {  // spare a main-thread TTS instance
            if (TtsHolder.holder != null) return
            TtsHolder.holder = TextToSpeech(ctx.applicationContext) { status ->
                if (status == TextToSpeech.SUCCESS) {
                    @Suppress("DEPRECATION")
                    TtsHolder.holder?.setLanguage(Locale.getDefault())
                }
            }
        }

        fun request(ctx: Context) {
            val i = Intent(ctx, AgentService::class.java)
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
        }
    }

    private var serverThread: Thread? = null
    private val running = AtomicBoolean(false)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        makeChannel()
        startInForeground()
        startServer()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        makeChannel()
        startInForeground()
        if (serverThread == null || !running.get()) startServer()
        return START_STICKY
    }

    private fun makeChannel() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel("agent", "Agent", NotificationManager.IMPORTANCE_LOW)
        )
    }

    private fun startInForeground() {
        val n = Notification.Builder(this, "agent")
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setContentTitle("DeviceAgent active")
            .setContentText("Command server on port ${SettingsStore.port}")
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(1, n)
        }
    }

    private fun startServer() {
        initTts(this)
        val port = SettingsStore.port
        Companion.port = port
        running.set(true)
        serverThread = Thread {
            try {
                val ss = ServerSocket(port)
                ss.reuseAddress = true
                while (running.get()) {
                    val sock: Socket = try { ss.accept() } catch (e: Exception) { break }
                    try { handle(sock) } catch (_: Exception) { } finally {
                        try { sock.close() } catch (_: Exception) { }
                    }
                }
                try { ss.close() } catch (_: Exception) { }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }.also { it.isDaemon = true; it.start() }
    }

    private fun handle(sock: Socket) {
        val rdr = BufferedReader(InputStreamReader(sock.getInputStream(), StandardCharsets.UTF_8))
        val first = rdr.readLine() ?: return
        val target = first.split(' ', limit = 3).getOrNull(1) ?: return

        // Read and discard headers; remember X-Token for auth.
        var xToken: String? = null
        var h = rdr.readLine()
        while (!h.isNullOrEmpty()) {
            val idx = h.indexOf(':')
            if (idx > 0 && h.substring(0, idx).trim().equals("X-Token", true)) {
                xToken = h.substring(idx + 1).trim()
            }
            h = rdr.readLine()
        }

        val qIdx = target.indexOf('?')
        val path = if (qIdx >= 0) target.substring(0, qIdx) else target
        val rawQuery = if (qIdx >= 0) target.substring(qIdx + 1) else null
        val q = parseQuery(rawQuery)

        if (path == "/shot" || path == "/shot.png") {
            val want = SettingsStore.token
            if (want.isNotBlank() && (q["token"] ?: xToken ?: "") != want) { respond(sock, 403, "ERR forbidden"); return }
            val png = CommandRunner.screenshotPng(this)
            if (png == null) respond(sock, 400, "ERR screenshot unavailable") else respondBytes(sock, png)
            return
        }

        val (code, body) = route(path, q, xToken)
        if (code == 998 && body is ByteArray) respondBytes(sock, body)
        else respond(sock, code, body.toString())
    }

    private fun respondBytes(sock: Socket, bytes: ByteArray) {
        try {
            val out = sock.getOutputStream()
            val head = buildString {
                append("HTTP/1.1 200 OK\r\n")
                append("Content-Type: image/png\r\n")
                append("Content-Length: ${bytes.size}\r\n")
                append("Connection: close\r\n\r\n")
            }
            out.write(head.toByteArray(StandardCharsets.UTF_8))
            out.write(bytes)
            out.flush()
        } catch (_: Exception) { }
    }

    private fun route(path: String, q: Map<String, String>, xToken: String?): Pair<Int, Any> {
        return when (path) {
            "/ping" -> 200 to "pong"
            "/", "/info" -> 200 to ("DeviceAgent 1.0\nport=${SettingsStore.port}")
            "/api" -> {
                val want = SettingsStore.token
                if (want.isNotBlank() && (q["token"] ?: xToken ?: "") != want) {
                    403 to "ERR forbidden"
                } else {
                    val action = q["action"]
                    if (action.isNullOrEmpty()) 400 to "ERR missing action"
                    else 200 to CommandRunner.run(this, action, q)
                }
            }
            "/shot", "/shot.png" -> {
                val want = SettingsStore.token
                if (want.isNotBlank() && (q["token"] ?: xToken ?: "") != want) {
                    403 to "ERR forbidden"
                } else {
                    val png = CommandRunner.screenshotPng(this)
                    if (png == null) 400 to "ERR screenshot unavailable (accessibility + Android 11+ required)"
                    else 998 to png
                }
            }
            else -> 404 to "ERR not found"
        }
    }

    private fun parseQuery(raw: String?): Map<String, String> {
        val out = HashMap<String, String>()
        if (raw.isNullOrBlank()) return out
        for (pair in raw.split("&")) {
            val kv = pair.split("=", limit = 2)
            val k = URLDecoder.decode(kv[0], "UTF-8")
            val v = if (kv.size > 1) URLDecoder.decode(kv[1], "UTF-8") else ""
            out[k] = v
        }
        return out
    }

    private fun respond(sock: Socket, code: Int, text: String) {
        val reason = when (code) {
            200 -> "OK"
            400 -> "Bad Request"
            403 -> "Forbidden"
            404 -> "Not Found"
            500 -> "Internal Server Error"
            else -> "Status"
        }
        val bytes = text.toByteArray(StandardCharsets.UTF_8)
        val head = buildString {
            append("HTTP/1.1 $code $reason\r\n")
            append("Content-Type: text/plain; charset=utf-8\r\n")
            append("Content-Length: ${bytes.size}\r\n")
            append("Connection: close\r\n\r\n")
        }
        val out = sock.getOutputStream()
        out.write(head.toByteArray(StandardCharsets.UTF_8))
        out.write(bytes)
        out.flush()
    }

    override fun onDestroy() {
        running.set(false)
        try { serverThread?.interrupt() } catch (_: Exception) { }
        serverThread = null
        super.onDestroy()
    }
}