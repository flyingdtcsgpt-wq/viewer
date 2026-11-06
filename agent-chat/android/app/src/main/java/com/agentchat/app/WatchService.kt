package com.agentchat.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import java.util.concurrent.ConcurrentHashMap

/**
 * 폰에서 시킨 작업(또는 PC 에서 돌던 작업)이 끝날 때까지 PC 서버에 몇 초마다 물어보고,
 * 끝나면 알림을 띄운 뒤 스스로 꺼진다. 지켜볼 것이 없으면 돌지 않는다.
 */
class WatchService : Service() {
    private class Watch(val base: String, val agent: String, val id: String, var title: String) {
        val since = System.currentTimeMillis()
        var sawBusy = false
        var fails = 0
    }

    private val watches = ConcurrentHashMap<String, Watch>()
    @Volatile private var worker: Thread? = null

    companion object {
        private const val CH_WATCH = "watch"
        private const val CH_DONE = "done"
        private const val ONGOING_ID = 1

        fun start(ctx: Context, base: String, agent: String, id: String, title: String) {
            val i = Intent(ctx, WatchService::class.java)
                .putExtra("base", base).putExtra("agent", agent).putExtra("id", id).putExtra("title", title)
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CH_WATCH, "작업 지켜보기", NotificationManager.IMPORTANCE_MIN))
        nm.createNotificationChannel(NotificationChannel(CH_DONE, "작업 끝 알림", NotificationManager.IMPORTANCE_HIGH))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val base = intent?.getStringExtra("base")
        val agent = intent?.getStringExtra("agent")
        val id = intent?.getStringExtra("id")
        if (base != null && agent != null && id != null) {
            val key = "$base|$agent:$id"
            watches.getOrPut(key) { Watch(base, agent, id, intent.getStringExtra("title") ?: "") }
        }
        goForeground()
        if (watches.isEmpty()) { stopSelfNow(); return START_NOT_STICKY }
        if (worker?.isAlive != true) worker = Thread(::loop, "watch").also { it.start() }
        return START_NOT_STICKY
    }

    private fun goForeground() {
        val n = Notification.Builder(this, CH_WATCH)
            .setSmallIcon(R.drawable.ic_stat)
            .setContentTitle("작업 지켜보는 중")
            .setContentText(if (watches.size <= 1) watches.values.firstOrNull()?.title ?: "" else "${watches.size}개")
            .setContentIntent(openIntent(null))
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 29) startForeground(ONGOING_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        else startForeground(ONGOING_ID, n)
    }

    private fun loop() {
        var idleRounds = 0
        while (watches.isNotEmpty()) {
            for ((base, group) in watches.values.groupBy { it.base }) {
                val server = Servers.byBase(this, base)
                val json = server?.let { Http.get(it, "api/sessions?limit=80") }
                if (json == null) {
                    // PC 가 꺼졌거나 연결이 끊김: 10분 동안 안 되면 그만
                    group.forEach { w -> if (++w.fails > 200) watches.remove(key(w)) }
                    continue
                }
                val arr = json.optJSONArray("sessions")
                for (w in group) {
                    w.fails = 0
                    var found: org.json.JSONObject? = null
                    if (arr != null) for (i in 0 until arr.length()) {
                        val o = arr.getJSONObject(i)
                        if (o.optString("agent") == w.agent && o.optString("id") == w.id) { found = o; break }
                    }
                    val f = found
                    val busy = if (f == null) false else f.optBoolean("busy", f.optBoolean("running") || f.optBoolean("active"))
                    if (f != null && f.optString("title").isNotBlank()) w.title = f.optString("title")
                    val age = System.currentTimeMillis() - w.since
                    when {
                        busy -> w.sawBusy = true
                        w.sawBusy -> { watches.remove(key(w)); done(w, f?.optString("preview").orEmpty(), f?.optString("error").orEmpty()) }
                        age > 45_000 -> watches.remove(key(w)) // 시작도 안 했으면 그만
                    }
                    if (age > 6 * 3600_000L) watches.remove(key(w))
                }
            }
            if (watches.isEmpty()) break
            if (++idleRounds % 10 == 0) runCatching { goForeground() }
            Thread.sleep(3000)
        }
        stopSelfNow()
    }

    private fun key(w: Watch) = "${w.base}|${w.agent}:${w.id}"

    private fun done(w: Watch, preview: String, error: String) {
        if (MainActivity.visible) return // 화면을 보고 있으면 알림 안 함
        val n = Notification.Builder(this, CH_DONE)
            .setSmallIcon(R.drawable.ic_stat)
            .setContentTitle((if (error.isNotBlank()) "실패: " else "끝: ") + w.title.ifBlank { w.agent })
            .setContentText(error.ifBlank { preview })
            .setStyle(Notification.BigTextStyle().bigText(error.ifBlank { preview }))
            .setContentIntent(openIntent(w))
            .setAutoCancel(true)
            .build()
        runCatching { getSystemService(NotificationManager::class.java).notify(key(w).hashCode(), n) }
    }

    private fun openIntent(w: Watch?): PendingIntent {
        val i = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (w != null) i.putExtra("base", w.base).putExtra("go", "#/s/${w.agent}/${w.id}")
        return PendingIntent.getActivity(this, w?.let { key(it).hashCode() } ?: 0, i,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    @Synchronized
    private fun stopSelfNow() {
        // 그 사이에 새로 지켜볼 것이 들어왔으면 계속
        if (watches.isNotEmpty()) {
            if (worker?.isAlive != true || Thread.currentThread() == worker) worker = Thread(::loop, "watch").also { it.start() }
            return
        }
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE) else @Suppress("DEPRECATION") stopForeground(true)
        stopSelf()
    }
}
