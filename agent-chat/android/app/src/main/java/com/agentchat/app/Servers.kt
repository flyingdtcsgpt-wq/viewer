package com.agentchat.app

import android.content.Context
import android.net.Uri
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/** 등록한 PC(서버) 하나: 주소(http://100.x.x.x:8790/)와 토큰, 보여 줄 이름 */
data class Server(val name: String, val base: String, val token: String) {
    fun toJson(): JSONObject = JSONObject().put("name", name).put("base", base).put("token", token)
    /** 웹 화면을 열 주소. #t= 로 토큰을 넘기면 화면이 받아 저장하고 주소에서 지운다 */
    fun startUrl(hash: String = ""): String = base + "#t=" + Uri.encode(token) + (if (hash.isNotEmpty()) "&go=" + Uri.encode(hash) else "")

    companion object {
        fun fromJson(o: JSONObject) = Server(o.optString("name"), o.optString("base"), o.optString("token"))

        /** QR / 붙여넣은 주소 "http://IP:포트/#t=토큰" 을 읽는다 */
        fun parse(text: String): Server? {
            val t = text.trim()
            val uri = runCatching { Uri.parse(t) }.getOrNull() ?: return null
            if (uri.scheme != "http" && uri.scheme != "https") return null
            val host = uri.host ?: return null
            val frag = uri.encodedFragment ?: ""
            val token = frag.split('&').firstOrNull { it.startsWith("t=") }?.substring(2)?.let { Uri.decode(it) } ?: return null
            if (token.length < 8) return null
            val port = if (uri.port > 0) ":${uri.port}" else ""
            val base = "${uri.scheme}://$host$port/"
            return Server("$host$port", base, token)
        }
    }
}

object Servers {
    private const val PREF = "servers"

    fun all(ctx: Context): MutableList<Server> {
        val raw = ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE).getString("list", "[]") ?: "[]"
        val arr = runCatching { JSONArray(raw) }.getOrDefault(JSONArray())
        return MutableList(arr.length()) { Server.fromJson(arr.getJSONObject(it)) }
    }

    fun save(ctx: Context, list: List<Server>) {
        val arr = JSONArray()
        list.forEach { arr.put(it.toJson()) }
        ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE).edit().putString("list", arr.toString()).apply()
    }

    /** 같은 주소면 바꾸고, 새 주소면 맨 앞에 넣는다 */
    fun add(ctx: Context, s: Server) {
        val list = all(ctx).filterNot { it.base == s.base }.toMutableList()
        list.add(0, s)
        save(ctx, list)
        setCurrent(ctx, s.base)
    }

    fun remove(ctx: Context, base: String) {
        save(ctx, all(ctx).filterNot { it.base == base })
        if (currentBase(ctx) == base) setCurrent(ctx, "")
    }

    fun rename(ctx: Context, base: String, name: String) {
        save(ctx, all(ctx).map { if (it.base == base) it.copy(name = name) else it })
    }

    fun currentBase(ctx: Context): String = ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE).getString("current", "") ?: ""
    fun setCurrent(ctx: Context, base: String) {
        ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE).edit().putString("current", base).apply()
    }
    fun current(ctx: Context): Server? {
        val b = currentBase(ctx)
        return all(ctx).firstOrNull { it.base == b } ?: all(ctx).firstOrNull()
    }
    fun byBase(ctx: Context, base: String): Server? = all(ctx).firstOrNull { it.base == base }
}

/** 아주 작은 HTTP GET (토큰 붙여서). 실패하면 null */
object Http {
    /** "100.101.5.7", "my-pc", "my-pc:8790", "http://…" → "http://주소:포트/" */
    fun baseOf(addr: String): String? {
        var a = addr.trim().removeSuffix("/")
        if (a.isEmpty()) return null
        a = a.replace(Regex("^https?://"), "").substringBefore('/').substringBefore('#')
        if (a.isEmpty() || a.any { it.isWhitespace() }) return null
        if (!a.contains(':')) a += ":8790"
        return "http://$a/"
    }

    /** PC 주소 + 6자리 코드 → 서버(토큰). 실패하면 이유를 담은 예외 */
    fun pair(base: String, code: String): Server {
        val c = URL(base + "api/pair").openConnection() as HttpURLConnection
        c.connectTimeout = 8000
        c.readTimeout = 8000
        c.requestMethod = "POST"
        c.doOutput = true
        c.setRequestProperty("Content-Type", "application/json")
        try {
            c.outputStream.use { it.write(JSONObject().put("code", code).toString().toByteArray(Charsets.UTF_8)) }
            val ok = c.responseCode == 200
            val body = (if (ok) c.inputStream else c.errorStream)?.bufferedReader(Charsets.UTF_8)?.readText().orEmpty()
            val o = runCatching { JSONObject(body) }.getOrDefault(JSONObject())
            if (!ok) throw IllegalStateException(o.optString("error").ifBlank { "오류 ${c.responseCode}" })
            val host = o.optString("host").ifBlank { Uri.parse(base).authority ?: base }
            return Server(host, base, o.getString("token"))
        } finally {
            c.disconnect()
        }
    }

    fun get(server: Server, path: String, timeoutMs: Int = 8000): JSONObject? = runCatching {
        val c = URL(server.base + path.trimStart('/')).openConnection() as HttpURLConnection
        c.connectTimeout = timeoutMs
        c.readTimeout = timeoutMs
        c.setRequestProperty("Authorization", "Bearer " + server.token)
        try {
            if (c.responseCode != 200) return@runCatching null
            JSONObject(c.inputStream.bufferedReader(Charsets.UTF_8).readText())
        } finally {
            c.disconnect()
        }
    }.getOrNull()
}
