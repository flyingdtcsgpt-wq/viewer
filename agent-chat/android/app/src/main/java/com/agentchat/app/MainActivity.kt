package com.agentchat.app

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.webkit.JavascriptInterface
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning

/**
 * 화면 하나: PC 의 Agent Chat 웹 화면을 꽉 차게 띄운다(WebView).
 * PC 목록(QR 로 추가 · 직접 입력 · 길게 눌러 삭제)은 그 위에 겹쳐 보여 준다.
 */
class MainActivity : Activity() {
    companion object {
        @Volatile var visible = false
    }

    private lateinit var root: FrameLayout
    private var web: WebView? = null
    private var serversView: View? = null
    private var loaded: Server? = null
    private var fileCallback: ValueCallback<Array<Uri>>? = null
    private val pickFiles = 7301
    private val night get() = (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
    private val fg get() = if (night) Color.parseColor("#E8EAEF") else Color.parseColor("#16181D")
    private val muted get() = if (night) Color.parseColor("#9AA1AD") else Color.parseColor("#6B7280")
    private val bg get() = if (night) Color.parseColor("#111318") else Color.parseColor("#F5F6F8")

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        root = FrameLayout(this)
        root.setBackgroundColor(bg)
        setContentView(root)
        fitInsets()
        handle(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handle(intent)
    }

    private fun handle(i: Intent?) {
        val base = i?.getStringExtra("base")
        val go = i?.getStringExtra("go") ?: ""
        val s = base?.let { Servers.byBase(this, it) } ?: Servers.current(this)
        if (s == null) showServers() else open(s, go)
    }

    @Deprecated("Activity 결과")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != pickFiles) { super.onActivityResult(requestCode, resultCode, data); return }
        val cb = fileCallback ?: return
        fileCallback = null
        if (resultCode != RESULT_OK || data == null) { cb.onReceiveValue(null); return }
        val clip = data.clipData
        val uris = if (clip != null) Array(clip.itemCount) { clip.getItemAt(it).uri } else data.data?.let { arrayOf(it) }
        cb.onReceiveValue(uris)
    }

    override fun onResume() { super.onResume(); visible = true }
    override fun onPause() { super.onPause(); visible = false }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        val w = web
        when {
            serversView != null && loaded != null -> hideServers()
            w != null && serversView == null && w.canGoBack() -> w.goBack()
            else -> @Suppress("DEPRECATION") super.onBackPressed()
        }
    }

    // 상태 표시줄 · 키보드 만큼 비켜서 그린다 (Android 15 의 전체 화면 그리기 대응)
    private fun fitInsets() {
        root.setOnApplyWindowInsetsListener { v, insets ->
            if (Build.VERSION.SDK_INT >= 30) {
                val i = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.ime() or WindowInsets.Type.displayCutout())
                v.setPadding(i.left, i.top, i.right, i.bottom)
                WindowInsets.CONSUMED
            } else {
                @Suppress("DEPRECATION")
                v.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop, insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
                @Suppress("DEPRECATION")
                insets.consumeSystemWindowInsets()
            }
        }
        if (Build.VERSION.SDK_INT >= 30 && !night) {
            window.insetsController?.setSystemBarsAppearance(
                WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,
                WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS,
            )
        }
    }

    // ---------------- 웹 화면 ----------------
    private fun open(s: Server, go: String) {
        Servers.setCurrent(this, s.base)
        hideServers()
        val w = web ?: makeWeb().also { web = it; root.addView(it, 0, FrameLayout.LayoutParams(-1, -1)) }
        if (loaded?.base == s.base && go.isNotEmpty()) {
            w.evaluateJavascript("location.hash=" + org.json.JSONObject.quote(go), null)
        } else {
            w.clearHistory()
            w.loadUrl(s.startUrl(go))
        }
        loaded = s
        // PC 이름을 받아 목록 이름으로 (처음에는 IP:포트)
        if (s.name == Uri.parse(s.base).authority) {
            Thread {
                val host = Http.get(s, "api/info")?.optString("host").orEmpty()
                if (host.isNotBlank()) Servers.rename(this, s.base, host)
            }.start()
        }
    }

    private fun makeWeb(): WebView {
        val w = WebView(this)
        w.setBackgroundColor(bg)
        with(w.settings) {
            javaScriptEnabled = true
            domStorageEnabled = true
            databaseEnabled = true
            setSupportZoom(false)
            textZoom = 100
        }
        w.addJavascriptInterface(Bridge(), "AgentChatApp")
        // 사진 · 파일 첨부: 웹의 <input type=file> 을 안드로이드 파일 고르기로
        w.webChromeClient = object : WebChromeClient() {
            override fun onShowFileChooser(view: WebView, cb: ValueCallback<Array<Uri>>, params: FileChooserParams): Boolean {
                fileCallback?.onReceiveValue(null)
                fileCallback = cb
                val pick = Intent(Intent.ACTION_GET_CONTENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                    putExtra(Intent.EXTRA_ALLOW_MULTIPLE, params.mode == FileChooserParams.MODE_OPEN_MULTIPLE)
                }
                return try {
                    startActivityForResult(Intent.createChooser(pick, "첨부할 파일"), pickFiles)
                    true
                } catch (e: Exception) {
                    fileCallback = null
                    false
                }
            }
        }
        w.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, req: WebResourceRequest): Boolean {
                val base = loaded?.base ?: return false
                val url = req.url.toString()
                if (url.startsWith(base)) return false
                // 답변 속 링크는 브라우저로
                runCatching { startActivity(Intent(Intent.ACTION_VIEW, req.url)) }
                return true
            }

            override fun onReceivedError(view: WebView, req: WebResourceRequest, err: android.webkit.WebResourceError) {
                if (req.isForMainFrame) showOffline(err.description?.toString() ?: "")
            }
        }
        return w
    }

    private fun showOffline(why: String) {
        val s = loaded ?: return
        val html = """
            <html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
            <body style="font-family:sans-serif;background:${hex(bg)};color:${hex(fg)};padding:24px">
            <h2>PC 에 연결하지 못했습니다</h2>
            <p>${s.name}<br><small>${s.base}</small></p>
            <p style="color:${hex(muted)}">PC 가 켜져 있고 Agent Chat 서버가 실행 중인지,
            밖에서라면 휴대폰의 Tailscale 이 켜져 있는지 확인하세요.<br><small>$why</small></p>
            <p><button onclick="location.href='${s.startUrl()}'" style="font-size:16px;padding:10px 18px">다시 연결</button>
            <button onclick="AgentChatApp.servers()" style="font-size:16px;padding:10px 18px">PC 목록</button></p>
            </body></html>
        """.trimIndent()
        web?.loadDataWithBaseURL(null, html, "text/html", "utf-8", null)
    }

    private fun hex(c: Int) = String.format("#%06X", 0xFFFFFF and c)

    // ---------------- PC 목록 ----------------
    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

    private fun showServers() {
        hideServers()
        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(24), dp(20), dp(24))
        }
        col.addView(TextView(this).apply {
            text = "PC 목록"; textSize = 24f; setTypeface(typeface, Typeface.BOLD); setTextColor(fg)
        })
        col.addView(TextView(this).apply {
            text = "PC 에서 Agent Chat 을 설치한 뒤 시작 메뉴의 \"Agent Chat 휴대폰 연결\" 을 열고 QR 을 찍거나, 거기 보이는 PC 주소와 숫자 코드를 넣으세요."
            setTextColor(muted); textSize = 14f; setPadding(0, dp(6), 0, dp(16))
        })
        val list = Servers.all(this)
        if (list.isEmpty()) {
            col.addView(TextView(this).apply { text = "등록된 PC 가 없습니다."; setTextColor(muted); setPadding(0, dp(8), 0, dp(16)) })
        }
        for (s in list) {
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(14), dp(12), dp(14), dp(12))
                setBackgroundColor(if (night) Color.parseColor("#1A1D24") else Color.WHITE)
                isClickable = true
                setOnClickListener { open(s, "") }
                setOnLongClickListener { confirmRemove(s); true }
            }
            row.addView(TextView(this).apply {
                text = (if (s.base == Servers.currentBase(this@MainActivity)) "● " else "") + s.name
                textSize = 17f; setTextColor(fg); setTypeface(typeface, Typeface.BOLD)
            })
            row.addView(TextView(this).apply { text = s.base; textSize = 13f; setTextColor(muted) })
            col.addView(row, LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(8) })
        }
        col.addView(TextView(this).apply {
            text = if (list.isEmpty()) "" else "길게 누르면 삭제"; textSize = 12f; setTextColor(muted); setPadding(0, 0, 0, dp(16))
        })
        col.addView(button("QR 스캔으로 PC 추가", true) { scan() })
        col.addView(button("숫자 코드로 PC 추가", false) { pairDialog() })
        col.addView(button("주소 붙여넣기", false) { manual() })
        if (loaded != null) col.addView(button("닫기", false) { hideServers() })

        val scroll = ScrollView(this).apply { setBackgroundColor(bg); addView(col) }
        serversView = scroll
        root.addView(scroll, FrameLayout.LayoutParams(-1, -1))
    }

    private fun button(label: String, primary: Boolean, onClick: () -> Unit) = Button(this).apply {
        text = label
        isAllCaps = false
        textSize = 16f
        if (primary) { setBackgroundColor(Color.parseColor("#2F6FED")); setTextColor(Color.WHITE) }
        setOnClickListener { onClick() }
        layoutParams = LinearLayout.LayoutParams(-1, dp(52)).apply { bottomMargin = dp(10) }
        gravity = Gravity.CENTER
    }

    private fun hideServers() {
        serversView?.let { root.removeView(it) }
        serversView = null
    }

    private fun confirmRemove(s: Server) {
        AlertDialog.Builder(this)
            .setTitle("${s.name} 삭제")
            .setMessage("이 PC 를 목록에서 지울까요?")
            .setPositiveButton("삭제") { _, _ ->
                Servers.remove(this, s.base)
                if (loaded?.base == s.base) { loaded = null; web?.loadUrl("about:blank") }
                showServers()
            }
            .setNegativeButton("취소", null)
            .show()
    }

    private fun scan() {
        GmsBarcodeScanning.getClient(this).startScan()
            .addOnSuccessListener { b -> added(b.rawValue ?: "") }
            .addOnFailureListener { e -> toast("스캔을 못 했습니다: ${e.message}. 주소 직접 입력을 쓰세요.") }
    }

    private fun manual() {
        val input = EditText(this).apply {
            hint = "http://100.x.x.x:8790/#t=토큰"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            setSingleLine(true)
        }
        val box = FrameLayout(this).apply { setPadding(dp(20), dp(8), dp(20), 0); addView(input) }
        AlertDialog.Builder(this)
            .setTitle("PC 주소")
            .setMessage("PC 의 연결 화면에서 \"주소 복사\" 한 것을 붙여 넣으세요 (토큰 포함).")
            .setView(box)
            .setPositiveButton("추가") { _, _ -> added(input.text.toString()) }
            .setNegativeButton("취소", null)
            .show()
    }

    /** PC 연결 화면의 "PC 주소" 와 "연결 코드 6자리" 로 추가 */
    private fun pairDialog() {
        val prefs = getSharedPreferences("servers", MODE_PRIVATE)
        val addr = EditText(this).apply {
            hint = "PC 주소 (예: 100.101.5.7)"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            setSingleLine(true)
            setText(prefs.getString("lastAddr", ""))
        }
        val code = EditText(this).apply {
            hint = "연결 코드 6자리"
            inputType = InputType.TYPE_CLASS_NUMBER
            setSingleLine(true)
        }
        val box = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(8), dp(20), 0)
            addView(addr); addView(code)
        }
        AlertDialog.Builder(this)
            .setTitle("숫자 코드로 PC 추가")
            .setMessage("PC 에서 시작 메뉴 → Agent Chat 휴대폰 연결 을 열면 PC 주소와 코드가 보입니다.")
            .setView(box)
            .setPositiveButton("연결") { _, _ ->
                val base = Http.baseOf(addr.text.toString())
                val digits = code.text.toString().filter { it.isDigit() }
                if (base == null || digits.length != 6) { toast("PC 주소와 숫자 6자리를 넣으세요"); return@setPositiveButton }
                prefs.edit().putString("lastAddr", addr.text.toString().trim()).apply()
                toast("연결하는 중…")
                Thread {
                    val r = runCatching { Http.pair(base, digits) }
                    runOnUiThread {
                        r.onSuccess { s ->
                            Servers.add(this, s)
                            loaded = null
                            open(s, "")
                        }.onFailure { e ->
                            toast("연결 못 함: ${e.message ?: e.javaClass.simpleName}" +
                                if (e is java.io.IOException) "\nPC 주소 · Tailscale · PC 서버가 켜져 있는지 확인하세요" else "")
                        }
                    }
                }.start()
            }
            .setNegativeButton("취소", null)
            .show()
    }

    private fun added(text: String) {
        val s = Server.parse(text)
        if (s == null) { toast("Agent Chat 주소가 아닙니다 (http://…/#t=토큰 형식)"); return }
        val old = Servers.byBase(this, s.base)
        Servers.add(this, if (old != null) s.copy(name = old.name) else s)
        loaded = null
        open(Servers.byBase(this, s.base) ?: s, "")
    }

    private fun toast(t: String) = Toast.makeText(this, t, Toast.LENGTH_LONG).show()

    private fun askNotifications() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    /** 웹 화면(JavaScript)에서 부르는 것들 */
    inner class Bridge {
        /** 이 세션이 끝나면 알려 달라 (앱을 내려놓아도) */
        @JavascriptInterface
        fun watch(agent: String, id: String, title: String) {
            val s = loaded ?: return
            if (agent != "claude" && agent != "codex") return
            runOnUiThread {
                askNotifications()
                runCatching { WatchService.start(this@MainActivity, s.base, agent, id, title) }
            }
        }

        @JavascriptInterface
        fun servers() = runOnUiThread { showServers() }

        @JavascriptInterface
        fun isApp(): Boolean = true
    }
}

