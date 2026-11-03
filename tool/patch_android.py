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
             "application/vnd.comicbook+zip"]  # RAR 은 폰에서 못 열어 다른 앱으로 넘기므로 받지 않는다
    datas = "".join(f'                <data android:mimeType="{m}"/>\n' for m in mimes)
    view = ('            <intent-filter>\n'
            '                <action android:name="android.intent.action.VIEW"/>\n'
            '                <category android:name="android.intent.category.DEFAULT"/>\n'
            '                <data android:scheme="content"/>\n'
            '                <data android:scheme="file"/>\n' + datas +
            '            </intent-filter>\n')
    i = xml.index("</intent-filter>") + len("</intent-filter>\n")
    xml = xml[:i] + view + xml[i:]
    # 파일 관리자에서 열어도 앱이 하나만 뜨게 (두 번째 엔진 · DB 동시 사용 방지)
    xml = re.sub(r'android:launchMode="\w+"', 'android:launchMode="singleTask"', xml, count=1)
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
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions

class MainActivity : FlutterActivity() {{
    private var pending: MethodChannel.Result? = null

    // ---- 다른 앱(파일 관리자)에서 연 파일 ----
    private var openChannel: MethodChannel? = null

    /// content:// 은 앱 폴더(files/opened)로 복사해서 실제 경로를 돌려준다
    private fun fileFromIntent(i: Intent): String? {{
        val uri = i.data ?: return null
        if (uri.scheme == "file") return uri.path
        return try {{
            var name = ""
            var size = -1L
            contentResolver.query(uri, null, null, null, null)?.use {{ c ->
                if (c.moveToFirst()) {{
                    val ni = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                    val si = c.getColumnIndex(android.provider.OpenableColumns.SIZE)
                    if (ni >= 0) name = c.getString(ni) ?: ""
                    if (si >= 0 && !c.isNull(si)) size = c.getLong(si)
                }}
            }}
            name = name.replace(Regex("[\\\\/:*?\\"<>|]"), "_").trim()
            if (name.isEmpty() || name == "." || name == "..") name = "file"
            // 확장자가 없으면 파일 종류(MIME)로 붙인다 (메신저 · 다운로드 앱은 이름만 줄 때가 많다)
            if (!name.contains('.')) {{
                val ext = android.webkit.MimeTypeMap.getSingleton().getExtensionFromMimeType(contentResolver.getType(uri))
                if (ext != null) name = "$name.$ext"
            }}
            // 같은 이름의 다른 파일이 덮어쓰지 않게: 이름 + 크기로 폴더를 나눈다 (같은 파일이면 다시 복사하지 않음)
            val key = Integer.toHexString((name + "|" + size).hashCode())
            val dir = java.io.File(java.io.File(filesDir, "opened"), key).apply {{ mkdirs() }}
            val out = java.io.File(dir, name)
            if (out.exists() && (size < 0 || out.length() == size)) return out.absolutePath
            val tmp = java.io.File(dir, "$name.part")
            contentResolver.openInputStream(uri)?.use {{ input -> tmp.outputStream().use {{ input.copyTo(it) }} }} ?: return null
            if (!tmp.renameTo(out)) {{ tmp.delete(); return null }}
            out.absolutePath
        }} catch (e: Exception) {{ null }}
    }}

    /// 복사는 오래 걸릴 수 있으니 따로 돌리고 결과만 화면 스레드로
    private fun fileFromIntentAsync(i: Intent, done: (String?) -> Unit) {{
        Thread {{
            val p = fileFromIntent(i)
            runOnUiThread {{ done(p) }}
        }}.start()
    }}

    override fun onNewIntent(newIntent: Intent) {{
        super.onNewIntent(newIntent)
        setIntent(newIntent)
        if (newIntent.action == Intent.ACTION_VIEW) {{
            fileFromIntentAsync(newIntent) {{ path -> if (path != null) openChannel?.invokeMethod("opened", path) }}
            newIntent.action = Intent.ACTION_MAIN
        }}
    }}

    private val recognizer by lazy {{ TextRecognition.getClient(KoreanTextRecognizerOptions.Builder().build()) }}

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
            if (ttsReady != true) {{
                // 실패하면 다음에 다시 시도할 수 있게 비운다
                runOnUiThread {{
                    tts?.shutdown(); tts = null; ttsReady = null
                    ttsWaiting.toList().forEach {{ it(false) }}
                    ttsWaiting.clear()
                }}
            }}
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
                    // 최근 앱 목록에서 다시 열면 예전 "열기" 요청이 다시 오므로 무시
                    val fromHistory = i != null && (i.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0
                    if (i?.action == Intent.ACTION_VIEW && !fromHistory) {{
                        i.action = Intent.ACTION_MAIN
                        fileFromIntentAsync(i) {{ path -> result.success(path) }}
                    }} else {{
                        result.success(null)
                    }}
                }}
                else -> result.notImplemented()
            }}
        }}
        // 글자 인식: ML Kit 한국어 (기기 안에서 처리)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mediashelf/ocr").setMethodCallHandler {{ call, result ->
            if (call.method != "recognize") {{ result.notImplemented(); return@setMethodCallHandler }}
            val path = call.argument<String>("path")
            if (path == null) {{ result.success(""); return@setMethodCallHandler }}
            try {{
                val image = InputImage.fromFilePath(this, Uri.fromFile(java.io.File(path)))
                recognizer.process(image)
                    .addOnSuccessListener {{ r ->
                        // 위에서 아래, 같은 줄이면 왼쪽부터
                        val blocks = r.textBlocks.sortedWith(compareBy({{ (it.boundingBox?.top ?: 0) / 20 }}, {{ it.boundingBox?.left ?: 0 }}))
                        result.success(blocks.joinToString("\\n") {{ it.text }})
                    }}
                    .addOnFailureListener {{ e -> result.error("ocr", e.message, null) }}
            }} catch (e: Exception) {{
                result.error("ocr", e.message, null)
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
    implementation("com.google.mlkit:text-recognition:16.0.1")
}
"""
    gradle.write_text(g, encoding="utf-8")
print("mlkit korean added")

# ---- R8: 쓰지 않는 ML Kit 언어(중국어·일본어·데바나가리)는 없어도 된다 ----
rules = Path("android/app/proguard-rules.pro")
rules.write_text("""-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-keep class ai.onnxruntime.** { *; }
""", encoding="utf-8")
g = gradle.read_text(encoding="utf-8")
if "proguard-rules.pro" not in g:
    g = g.replace('signingConfig = if (keystorePropertiesFile.exists())',
                  'proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")\n            signingConfig = if (keystorePropertiesFile.exists())', 1)
    assert "proguard-rules.pro" in g
    gradle.write_text(g, encoding="utf-8")
print("proguard rules added")
