"""flutter create 로 만든 AndroidManifest.xml 에 권한/앱 이름을 넣는다 (CI 에서 실행)."""
import re
from pathlib import Path

path = Path("android/app/src/main/AndroidManifest.xml")
xml = path.read_text(encoding="utf-8")

# 꼭 필요한 것만 (권한이 많을수록 보안 앱이 의심한다)
perms = [
    ("android.permission.INTERNET", ""),                                  # 책 정보 검색, AI
    ("android.permission.READ_EXTERNAL_STORAGE", ' android:maxSdkVersion="32"'),  # 안드로이드 12 이하 (open_filex 와 같은 값)
    ("android.permission.MANAGE_EXTERNAL_STORAGE", ""),                   # 폴더 등록 시에만 요청 (11+)
]
lines = "".join(f'    <uses-permission android:name="{p}"{extra}/>\n' for p, extra in perms if p not in xml)
xml = re.sub(r"(<manifest[^>]*>\n)", r"\1" + lines, xml, count=1)
xml = xml.replace('android:label="media_shelf"', 'android:label="ARARIFlex"')
# 파일 관리자에서 "ARARIFlex 로 열기"
if "application/epub+zip" not in xml:
    mimes = ["application/epub+zip", "application/pdf", "text/plain", "application/zip", "application/x-cbz",
             "application/vnd.comicbook+zip", "application/octet-stream", "image/*", "video/*"]
    datas = "".join(f'                <data android:mimeType="{m}"/>\n' for m in mimes)
    view = ('            <intent-filter>\n'
            '                <action android:name="android.intent.action.VIEW"/>\n'
            '                <category android:name="android.intent.category.DEFAULT"/>\n'
            '                <data android:scheme="content"/>\n'
            '                <data android:scheme="file"/>\n' + datas +
            '            </intent-filter>\n')
    i = xml.index("</intent-filter>") + len("</intent-filter>\n")
    xml = xml[:i] + view + xml[i:]
# 안드로이드 11+ 에서 음성 엔진(TTS)을 찾으려면 queries 에 적어야 한다
if "android.intent.action.TTS_SERVICE" not in xml:
    tts_q = '        <intent>\n            <action android:name="android.intent.action.TTS_SERVICE"/>\n        </intent>\n'
    if "<queries>" in xml:
        xml = xml.replace("<queries>\n", "<queries>\n" + tts_q, 1)
    else:
        xml = xml.replace("</manifest>", "    <queries>\n" + tts_q + "    </queries>\n</manifest>", 1)
path.write_text(xml, encoding="utf-8")
print(xml[:1500])

# ---- MainActivity: "모든 파일 관리" 권한 확인/요청 채널 ----
import glob
acts = glob.glob("android/app/src/main/kotlin/**/MainActivity.kt", recursive=True)
assert acts, "MainActivity.kt not found"
act = Path(acts[0])
pkg = re.search(r"^package\s+([\w.]+)", act.read_text(encoding="utf-8"), re.M).group(1)
act.write_text(f"""package {pkg}

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.util.Locale
import java.util.UUID

class MainActivity : FlutterActivity() {{
    private var pending: MethodChannel.Result? = null

    // ---- 다른 앱(파일 관리자)에서 연 파일 ----
    private var openChannel: MethodChannel? = null

    /// content:// 은 앱 폴더(files/opened)로 복사해서 실제 경로를 돌려준다
    private fun fileFromIntent(i: Intent): String? {{
        val uri = i.data ?: return null
        if (uri.scheme == "file") return uri.path
        return try {{
            var name = "file"
            contentResolver.query(uri, null, null, null, null)?.use {{ c ->
                val idx = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && c.moveToFirst()) name = c.getString(idx) ?: name
            }}
            name = name.replace(Regex("[\\\\/:*?\\"<>|]"), "_")
            val dir = java.io.File(filesDir, "opened").apply {{ mkdirs() }}
            val out = java.io.File(dir, name)
            contentResolver.openInputStream(uri)?.use {{ input -> out.outputStream().use {{ input.copyTo(it) }} }}
            out.absolutePath
        }} catch (e: Exception) {{ null }}
    }}

    override fun onNewIntent(newIntent: Intent) {{
        super.onNewIntent(newIntent)
        if (newIntent.action == Intent.ACTION_VIEW) {{
            val path = fileFromIntent(newIntent)
            if (path != null) openChannel?.invokeMethod("opened", path)
        }}
    }}

    // ---- 기기 음성(TTS): 소리 내어 읽기 ----
    private var tts: TextToSpeech? = null
    private var ttsReady: Boolean? = null
    private val ttsWaiting = mutableListOf<(Boolean) -> Unit>()
    private val ttsPending = mutableMapOf<String, MethodChannel.Result>()

    private fun finishUtterance(id: String?, ok: Boolean) = runOnUiThread {{ if (id != null) ttsPending.remove(id)?.success(ok) }}

    private fun withTts(f: (Boolean) -> Unit) {{
        val r = ttsReady
        if (r != null) {{ f(r); return }}
        ttsWaiting.add(f)
        if (tts != null) return
        tts = TextToSpeech(this) {{ status ->
            ttsReady = status == TextToSpeech.SUCCESS
            tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {{
                override fun onStart(id: String?) {{}}
                override fun onDone(id: String?) = finishUtterance(id, true)
                @Deprecated("Deprecated in Java")
                override fun onError(id: String?) = finishUtterance(id, false)
                override fun onError(id: String?, code: Int) = finishUtterance(id, false)
                override fun onStop(id: String?, interrupted: Boolean) = finishUtterance(id, false)
            }})
            runOnUiThread {{
                val ok = ttsReady == true
                ttsWaiting.toList().forEach {{ it(ok) }}
                ttsWaiting.clear()
            }}
        }}
    }}

    private fun ttsStopAll() {{
        tts?.stop()
        ttsPending.values.toList().forEach {{ it.success(false) }}
        ttsPending.clear()
    }}

    override fun onDestroy() {{
        ttsStopAll()
        tts?.shutdown()
        tts = null
        super.onDestroy()
    }}

    private fun hasAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) Environment.isExternalStorageManager()
        else checkSelfPermission(android.Manifest.permission.READ_EXTERNAL_STORAGE) == android.content.pm.PackageManager.PERMISSION_GRANTED

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {{
        super.configureFlutterEngine(flutterEngine)
        openChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mediashelf/open")
        openChannel?.setMethodCallHandler {{ call, result ->
            when (call.method) {{
                // 앱을 연 파일 (한 번만 돌려줌)
                "takeFile" -> {{
                    val i = intent
                    val path = if (i?.action == Intent.ACTION_VIEW) fileFromIntent(i) else null
                    i?.action = Intent.ACTION_MAIN
                    result.success(path)
                }}
                else -> result.notImplemented()
            }}
        }}
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mediashelf/tts").setMethodCallHandler {{ call, result ->
            when (call.method) {{
                "voices" -> withTts {{ ok ->
                    if (!ok) {{ result.success(listOf<String>()); return@withTts }}
                    val list = try {{ tts?.voices?.toList() ?: listOf() }} catch (e: Exception) {{ listOf() }}
                    // 한국어 · 영어 음성만 (기기에 따라 수백 개라서), 인터넷이 필요한 것은 뒤로
                    val wanted = list.filter {{ it.locale.language == "ko" || it.locale.language == "en" }}
                        .sortedWith(compareBy({{ it.locale.language != "ko" }}, {{ it.isNetworkConnectionRequired }}, {{ it.name }}))
                    result.success(wanted.map {{ it.name + "|" + it.locale.toLanguageTag() + "|" + (if (it.isNetworkConnectionRequired) "net" else "local") }})
                }}
                "speak" -> withTts {{ ok ->
                    val t = tts
                    if (!ok || t == null) {{ result.success(false); return@withTts }}
                    ttsStopAll()
                    val name = call.argument<String>("voice") ?: ""
                    val v = if (name.isEmpty()) null else try {{ t.voices?.firstOrNull {{ it.name == name }} }} catch (e: Exception) {{ null }}
                    if (v != null) t.setVoice(v) else t.setLanguage(Locale.KOREAN)
                    t.setSpeechRate((call.argument<Double>("rate") ?: 1.0).toFloat())
                    val id = UUID.randomUUID().toString()
                    ttsPending[id] = result
                    if (t.speak(call.argument<String>("text") ?: "", TextToSpeech.QUEUE_FLUSH, null, id) != TextToSpeech.SUCCESS) {{
                        ttsPending.remove(id)
                        result.success(false)
                    }}
                }}
                "stop" -> {{ ttsStopAll(); result.success(null) }}
                else -> result.notImplemented()
            }}
        }}
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mediashelf/storage").setMethodCallHandler {{ call, result ->
            when (call.method) {{
                "hasAllFilesAccess" -> result.success(hasAccess())
                "requestAllFilesAccess" -> {{
                    if (hasAccess()) {{ result.success(true); return@setMethodCallHandler }}
                    pending = result
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {{
                        try {{
                            startActivityForResult(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName")), 4711)
                        }} catch (e: Exception) {{
                            startActivityForResult(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION), 4711)
                        }}
                    }} else {{
                        requestPermissions(arrayOf(android.Manifest.permission.READ_EXTERNAL_STORAGE, android.Manifest.permission.WRITE_EXTERNAL_STORAGE), 4711)
                    }}
                }}
                else -> result.notImplemented()
            }}
        }}
    }}

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {{
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 4711) {{ pending?.success(hasAccess()); pending = null }}
    }}

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {{
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 4711) {{ pending?.success(hasAccess()); pending = null }}
    }}
}}
""", encoding="utf-8")
print("patched", act)

# ---- 정식 서명: android/key.properties 가 있으면 release 키로 서명 (CI 가 Secrets 로 만든다) ----
gradle = Path("android/app/build.gradle.kts")
assert gradle.exists(), "build.gradle.kts not found"
g = gradle.read_text(encoding="utf-8")
if "key.properties" not in g:
    g = "import java.util.Properties\nimport java.io.FileInputStream\n\n" + g
    g = g.replace("android {", """val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }
""", 1)
    g = g.replace('signingConfig = signingConfigs.getByName("debug")',
                  'signingConfig = if (keystorePropertiesFile.exists()) signingConfigs.getByName("release") else signingConfigs.getByName("debug")')
    assert 'getByName("release")' in g
    gradle.write_text(g, encoding="utf-8")
print("gradle signing patched")

# ---- 글자 인식(ML Kit): 한국어 인식 모델을 앱에 넣는다 (플러그인은 compileOnly 로만 둠) ----
g = gradle.read_text(encoding="utf-8")
if "text-recognition-korean" not in g:
    g += """
dependencies {
    implementation("com.google.mlkit:text-recognition-korean:16.0.1")
}
"""
    gradle.write_text(g, encoding="utf-8")
print("mlkit korean added")
