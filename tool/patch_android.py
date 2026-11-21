"""flutter create 로 만든 AndroidManifest.xml 에 권한/앱 이름을 넣는다 (CI 에서 실행)."""
import os
import re
import sys
from pathlib import Path

# --store: 플레이스토어판 (패키지 com.arariflex.app, 저장소 · 알림 · 백그라운드 권한 없음, 광고)
STORE = "--store" in sys.argv
STORE_ID = "com.arariflex.app"
# 전체판(직접 설치) 패키지. 기기에서는 내장 저장공간/Android/data/<이 이름>/files 로 보인다.
# (0.6 까지는 com.mediashelf.media_shelf 였다. 패키지가 다르면 다른 앱이라, 예전 것을 덮어 깔지 않고 따로 깔린다)
FULL_ID = "com.arariflex.full"
# AdMob 앱 ID: Secrets(ADMOB_APP_ID) 가 없으면 구글 시험용 ID (시험 광고만 나온다)
ADMOB_APP_ID = os.environ.get("ADMOB_APP_ID") or "ca-app-pub-3940256099942544~3347511713"

path = Path("android/app/src/main/AndroidManifest.xml")
xml = path.read_text(encoding="utf-8")

# 꼭 필요한 것만 (권한이 많을수록 보안 앱이 의심한다)
perms = [
    ("android.permission.INTERNET", ""),                                  # 책 정보 검색, AI
    ("android.permission.READ_EXTERNAL_STORAGE", ' android:maxSdkVersion="32"'),  # 안드로이드 12 이하 (open_filex 와 같은 값)
    ("android.permission.MANAGE_EXTERNAL_STORAGE", ""),                   # 폴더 등록 시에만 요청 (11+)
    ("android.permission.FOREGROUND_SERVICE", ""),                        # 화면을 꺼도 소리 내어 읽기
    ("android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK", ""),
    ("android.permission.WAKE_LOCK", ""),
    ("android.permission.POST_NOTIFICATIONS", ""),                        # "읽는 중" 알림
]
if STORE:
    # 플레이스토어판: 인터넷(광고)만. 파일은 사용자가 고른 것만 읽어 앱 폴더로 가져온다(SAF)
    perms = [("android.permission.INTERNET", ""), ("android.permission.ACCESS_NETWORK_STATE", "")]
lines = "".join(f'    <uses-permission android:name="{p}"{extra}/>\n' for p, extra in perms if p not in xml)
xml = re.sub(r"(<manifest[^>]*>\n)", r"\1" + lines, xml, count=1)
# 앱 이름표 (flutter create 는 프로젝트 이름을 그대로 넣는다)
xml, n_label = re.subn(r'android:label="[^"]*"', 'android:label="ARARIFlex"', xml, count=1)
assert n_label == 1, "android:label not found"
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
# 소리 내어 읽는 동안 앱이 멈추지 않게 하는 서비스
if "ReadAloudService" not in xml:
    xml = xml.replace("</application>", '        <service android:name=".ReadAloudService" android:exported="false" android:foregroundServiceType="mediaPlayback"/>\n    </application>', 1)
# 안드로이드 11+ 에서 음성 엔진(TTS)을 찾으려면 queries 에 적어야 한다
if "android.intent.action.TTS_SERVICE" not in xml:
    tts_q = '        <intent>\n            <action android:name="android.intent.action.TTS_SERVICE"/>\n        </intent>\n'
    if "<queries>" in xml:
        xml = xml.replace("<queries>\n", "<queries>\n" + tts_q, 1)
    else:
        xml = xml.replace("</manifest>", "    <queries>\n" + tts_q + "    </queries>\n</manifest>", 1)
# ---- 광고 SDK(google_mobile_ads): 앱 ID 가 없으면 앱이 켜지자마자 죽는다 → 두 판 모두 넣는다 ----
if 'xmlns:tools=' not in xml:
    xml = xml.replace("<manifest ", '<manifest xmlns:tools="http://schemas.android.com/tools" ', 1)
if "com.google.android.gms.ads.APPLICATION_ID" not in xml:
    xml = xml.replace("</application>", f'        <meta-data android:name="com.google.android.gms.ads.APPLICATION_ID" android:value="{ADMOB_APP_ID if STORE else "ca-app-pub-3940256099942544~3347511713"}"/>\n    </application>', 1)
# 플러그인이 덧붙이는 권한 중 쓰지 않는 것은 빼 버린다
drop = ["android.permission.REQUEST_INSTALL_PACKAGES"]
if STORE:
    drop += ["android.permission.READ_EXTERNAL_STORAGE", "android.permission.WRITE_EXTERNAL_STORAGE",
             "android.permission.MANAGE_EXTERNAL_STORAGE", "android.permission.READ_MEDIA_IMAGES",
             "android.permission.READ_MEDIA_VIDEO", "android.permission.READ_MEDIA_AUDIO",
             "android.permission.READ_MEDIA_VISUAL_USER_SELECTED", "android.permission.FOREGROUND_SERVICE",
             "android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK", "android.permission.POST_NOTIFICATIONS",
             "android.permission.RECORD_AUDIO", "android.permission.CAMERA"]  # WAKE_LOCK 은 광고 SDK(WorkManager)가 써서 둔다
else:
    drop += ["com.google.android.gms.permission.AD_ID"]  # 전체판은 광고가 없다
xml = re.sub(r'\s*<uses-permission android:name="(' + "|".join(re.escape(d) for d in drop) + r')"[^>]*/>', "", xml)
xml = re.sub(r"(<manifest[^>]*>\n)", r"\1" + "".join(f'    <uses-permission android:name="{d}" tools:node="remove"/>\n' for d in drop), xml, count=1)
if STORE:
    # 읽어주기 서비스 · 음성 엔진 찾기 빼기
    xml = re.sub(r'\s*<service android:name="\.ReadAloudService"[^>]*/>', "", xml)
    xml = re.sub(r'\s*<intent>\s*<action android:name="android.intent.action.TTS_SERVICE"/>\s*</intent>', "", xml)
    xml = re.sub(r"\s*<queries>\s*</queries>", "", xml)
    # file:// 은 안드로이드 7+ 에서 쓰이지 않는다
    xml = xml.replace('                <data android:scheme="file"/>\n', "")
    # "공유 → ARARIFlex" 로 파일 받기
    if "android.intent.action.SEND" not in xml:
        mimes = ["application/epub+zip", "application/pdf", "text/plain", "application/zip", "application/x-cbz",
                 "application/vnd.comicbook+zip", "application/octet-stream", "video/*"]
        datas = "".join(f'                <data android:mimeType="{m}"/>\n' for m in mimes)
        send = "".join('            <intent-filter>\n'
                       f'                <action android:name="android.intent.action.{a}"/>\n'
                       '                <category android:name="android.intent.category.DEFAULT"/>\n' + datas +
                       '            </intent-filter>\n' for a in ("SEND", "SEND_MULTIPLE"))
        i = xml.index("</intent-filter>") + len("</intent-filter>\n")
        xml = xml[:i] + send + xml[i:]
    # 지울 때 "앱 데이터 보관" 을 물어본다 (ARARIFlex 폴더의 파일을 실수로 잃지 않게)
    if "hasFragileUserData" not in xml:
        xml = xml.replace("<application", '<application android:hasFragileUserData="true"', 1)
path.write_text(xml, encoding="utf-8")
print(xml[:2500])

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
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
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
        if (newIntent.action == Intent.ACTION_SEND || newIntent.action == Intent.ACTION_SEND_MULTIPLE) {{
            val shared = takeShared(newIntent)
            newIntent.action = Intent.ACTION_MAIN
            Thread {{
                // 받을 파일이 없어도(글자 · 링크만 공유) 빈 목록을 보내 앱이 알려 주게 한다
                val out = shared.map {{ describe(it, "") }}
                runOnUiThread {{ safChannel?.invokeMethod("shared", out) }}
            }}.start()
        }}
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

    /// 16비트 PCM WAV(이 앱이 만든 44바이트 머리) → AAC-LC M4A
    private fun encodeM4a(src: String, dst: String): Boolean {{
        java.io.RandomAccessFile(src, "r").use {{ f ->
            val head = ByteArray(44)
            f.readFully(head)
            val hb = java.nio.ByteBuffer.wrap(head).order(java.nio.ByteOrder.LITTLE_ENDIAN)
            val channels = hb.getShort(22).toInt().coerceAtLeast(1)
            val rate = hb.getInt(24)
            val fmt = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, rate, channels)
            fmt.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            fmt.setInteger(MediaFormat.KEY_BIT_RATE, 64000)
            fmt.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
            val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            val muxer = MediaMuxer(dst, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            var started = false
            try {{
                codec.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                codec.start()
                val info = MediaCodec.BufferInfo()
                val buf = ByteArray(8192)
                var track = -1
                var inputDone = false
                var outputDone = false
                var frames = 0L
                while (!outputDone) {{
                    if (!inputDone) {{
                        val ii = codec.dequeueInputBuffer(10000)
                        if (ii >= 0) {{
                            val inBuf = codec.getInputBuffer(ii)!!
                            inBuf.clear()
                            val want = minOf(buf.size, inBuf.remaining()) / (2 * channels) * (2 * channels)
                            val n = f.read(buf, 0, want)
                            val pts = frames * 1000000L / rate
                            if (n <= 0) {{
                                codec.queueInputBuffer(ii, 0, 0, pts, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            }} else {{
                                inBuf.put(buf, 0, n)
                                codec.queueInputBuffer(ii, 0, n, pts, 0)
                                frames += n / (2 * channels)
                            }}
                        }}
                    }}
                    val oi = codec.dequeueOutputBuffer(info, 10000)
                    if (oi == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {{
                        track = muxer.addTrack(codec.outputFormat)
                        muxer.start()
                        started = true
                    }} else if (oi >= 0) {{
                        val out = codec.getOutputBuffer(oi)!!
                        if ((info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) info.size = 0
                        if (info.size > 0 && started) {{
                            out.position(info.offset)
                            out.limit(info.offset + info.size)
                            muxer.writeSampleData(track, out, info)
                        }}
                        codec.releaseOutputBuffer(oi, false)
                        if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) outputDone = true
                    }}
                }}
            }} finally {{
                try {{ codec.stop() }} catch (e: Exception) {{}}
                codec.release()
                try {{ if (started) muxer.stop() }} catch (e: Exception) {{}}
                muxer.release()
            }}
            return started
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
        safChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "arariflex/saf")
        safChannel?.setMethodCallHandler {{ call, result ->
            when (call.method) {{
                "pickFiles" -> {{
                    safPending?.success(null)
                    safPending = result
                    val i = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {{
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                        putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                    }}
                    try {{ startActivityForResult(i, 4720) }} catch (e: Exception) {{ safPending = null; result.success(null) }}
                }}
                "pickFolder" -> {{
                    safPending?.success(null)
                    safPending = result
                    try {{ startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), 4721) }} catch (e: Exception) {{ safPending = null; result.success(null) }}
                }}
                "listTree" -> {{
                    val tree = Uri.parse(call.argument<String>("tree") ?: "")
                    Thread {{
                        val out = try {{ listTree(tree) }} catch (e: Exception) {{ emptyList() }}
                        runOnUiThread {{ result.success(out) }}
                    }}.start()
                }}
                "copy" -> {{
                    val uri = Uri.parse(call.argument<String>("uri") ?: "")
                    val dest = call.argument<String>("dest") ?: ""
                    Thread {{
                        val ok = copyTo(uri, dest)
                        runOnUiThread {{ result.success(ok) }}
                    }}.start()
                }}
                "delete" -> {{
                    val uri = Uri.parse(call.argument<String>("uri") ?: "")
                    Thread {{
                        val ok = try {{ android.provider.DocumentsContract.deleteDocument(contentResolver, uri) }} catch (e: Exception) {{ false }}
                        runOnUiThread {{ result.success(ok) }}
                    }}.start()
                }}
                "releaseFolder" -> {{
                    try {{
                        contentResolver.releasePersistableUriPermission(Uri.parse(call.argument<String>("tree") ?: ""),
                            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                    }} catch (e: Exception) {{}}
                    result.success(null)
                }}
                // ---- 폴더 연결: 고른 폴더를 복사하지 않고 그 자리에서 읽는다 (권한은 pickFolder 가 받아 둔다) ----
                "treeInfo" -> {{
                    val tree = Uri.parse(call.argument<String>("tree") ?: "")
                    Thread {{
                        val out = treeInfo(tree)
                        runOnUiThread {{ result.success(out) }}
                    }}.start()
                }}
                "scanTree" -> {{
                    val tree = Uri.parse(call.argument<String>("tree") ?: "")
                    Thread {{
                        val fail = BooleanArray(1)
                        val files = try {{ listTree(tree, fail) }} catch (e: Exception) {{ fail[0] = true; emptyList() }}
                        runOnUiThread {{ result.success(mapOf("ok" to !fail[0], "files" to files)) }}
                    }}.start()
                }}
                // 읽기용으로 열어 파일 번호(fd)를 넘긴다. 저장소 권한 없이 읽는 유일한 길 (닫기는 받은 쪽이 한다)
                "openFd" -> {{
                    val tree = call.argument<String>("tree")
                    val rel = call.argument<String>("rel") ?: ""
                    val path = call.argument<String>("path")
                    Thread {{
                        val out: Map<String, Any>? = try {{
                            val pfd = if (tree != null) contentResolver.openFileDescriptor(docUri(Uri.parse(tree), rel), "r")
                            else android.os.ParcelFileDescriptor.open(java.io.File(path ?: ""), android.os.ParcelFileDescriptor.MODE_READ_ONLY)
                            if (pfd == null) null else {{
                                val size = pfd.statSize
                                mapOf("fd" to pfd.detachFd(), "size" to size)
                            }}
                        }} catch (e: Exception) {{ null }}
                        runOnUiThread {{ result.success(out) }}
                    }}.start()
                }}
                "docUri" -> {{
                    val out = try {{ docUri(Uri.parse(call.argument<String>("tree") ?: ""), call.argument<String>("rel") ?: "").toString() }} catch (e: Exception) {{ null }}
                    result.success(out)
                }}
                "deleteIn" -> {{
                    val tree = Uri.parse(call.argument<String>("tree") ?: "")
                    val rel = call.argument<String>("rel") ?: ""
                    Thread {{
                        val ok = try {{ rel.isNotEmpty() && android.provider.DocumentsContract.deleteDocument(contentResolver, docUri(tree, rel)) }} catch (e: Exception) {{ false }}
                        runOnUiThread {{ result.success(ok) }}
                    }}.start()
                }}
                // 앱을 "공유 → ARARIFlex" 로 열었을 때 받은 파일 (한 번만)
                "takeShared" -> {{
                    val i = intent
                    // 최근 앱 목록에서 다시 열면 예전 공유 요청이 다시 오므로 무시
                    val fromHistory = i != null && (i.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0
                    if (i == null || fromHistory || (i.action != Intent.ACTION_SEND && i.action != Intent.ACTION_SEND_MULTIPLE)) {{
                        result.success(null) // 공유로 연 것이 아님
                    }} else {{
                        val list = takeShared(i)
                        i.action = Intent.ACTION_MAIN
                        Thread {{
                            val out = list.map {{ describe(it, "") }}
                            runOnUiThread {{ result.success(out) }}
                        }}.start()
                    }}
                }}
                else -> result.notImplemented()
            }}
        }}
        openChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "arariflex/open")
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "arariflex/ocr").setMethodCallHandler {{ call, result ->
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
        // 화면을 꺼도 읽기가 이어지게: 읽기를 시작하면 알림과 함께 서비스를 켜고, 멈추면 끈다
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "arariflex/bg").setMethodCallHandler {{ call, result ->
            val i = Intent(this, ReadAloudService::class.java)
            try {{
                when (call.method) {{
                    "start" -> {{
                        i.putExtra("title", call.argument<String>("title") ?: "")
                        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {{
                            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 4712)
                        }}
                        if (Build.VERSION.SDK_INT >= 26) startForegroundService(i) else startService(i)
                    }}
                    "stop" -> stopService(i)
                    // 읽는 동안 화면이 꺼지지 않게
                    "keepScreen" -> {{
                        if (call.argument<Boolean>("on") == true) window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        else window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }}
                }}
                result.success(true)
            }} catch (e: Exception) {{ result.success(false) }}
        }}
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "arariflex/tts").setMethodCallHandler {{ call, result ->
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
                // 오디오북 저장: 소리 내지 않고 WAV 파일로
                "render" -> withTts {{ ok ->
                    val t = tts
                    if (!ok || t == null) {{ result.success(false); return@withTts }}
                    val name = call.argument<String>("voice") ?: ""
                    val v = if (name.isEmpty()) null else try {{ t.voices?.firstOrNull {{ it.name == name }} }} catch (e: Exception) {{ null }}
                    if (v != null) t.setVoice(v) else t.setLanguage(Locale.KOREAN)
                    t.setSpeechRate((call.argument<Double>("rate") ?: 1.0).toFloat())
                    val id = UUID.randomUUID().toString()
                    ttsPending[id] = result
                    val out = java.io.File(call.argument<String>("path") ?: "")
                    if (t.synthesizeToFile(call.argument<String>("text") ?: "", null, out, id) != TextToSpeech.SUCCESS) {{
                        ttsPending.remove(id)
                        result.success(false)
                    }}
                }}
                "stop" -> {{ ttsStopAll(); result.success(null) }}
                else -> result.notImplemented()
            }}
        }}
        // 오디오북: WAV → M4A(AAC) 로 줄이기 (기기 내장 인코더)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "arariflex/audio").setMethodCallHandler {{ call, result ->
            if (call.method != "encodeM4a") {{ result.notImplemented(); return@setMethodCallHandler }}
            val src = call.argument<String>("src") ?: ""
            val dst = call.argument<String>("dst") ?: ""
            Thread {{
                val ok = try {{ encodeM4a(src, dst) }} catch (e: Exception) {{ false }}
                runOnUiThread {{ result.success(ok) }}
            }}.start()
        }}
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "arariflex/storage").setMethodCallHandler {{ call, result ->
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
        if (requestCode == 4720 || requestCode == 4721) {{
            val r = safPending
            safPending = null
            if (r == null) return
            if (resultCode != RESULT_OK || data == null) {{ r.success(null); return }}
            if (requestCode == 4721) {{
                val tree = data.data ?: run {{ r.success(null); return }}
                // 나중에 원본을 지울 수 있게 (옮기기) 읽기 · 쓰기 권한을 잡아 둔다
                try {{ contentResolver.takePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION) }} catch (e: Exception) {{}}
                r.success(tree.toString())
            }} else {{
                val uris = mutableListOf<Uri>()
                data.clipData?.let {{ c -> for (k in 0 until c.itemCount) uris.add(c.getItemAt(k).uri) }}
                if (uris.isEmpty()) data.data?.let {{ uris.add(it) }}
                Thread {{
                    val out = uris.map {{ describe(it, "") }}
                    runOnUiThread {{ r.success(out) }}
                }}.start()
            }}
        }}
    }}

    // ---- 플레이스토어판 가져오기: 사용자가 고른 파일 · 폴더(Storage Access Framework)를 앱 폴더로 ----
    private var safPending: MethodChannel.Result? = null
    private var safChannel: MethodChannel? = null
    private val sharedUris = mutableListOf<Uri>()

    private fun describe(uri: Uri, rel: String): Map<String, Any> {{
        var name = ""
        var size = -1L
        try {{
            contentResolver.query(uri, null, null, null, null)?.use {{ c ->
                if (c.moveToFirst()) {{
                    val ni = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                    val si = c.getColumnIndex(android.provider.OpenableColumns.SIZE)
                    if (ni >= 0) name = c.getString(ni) ?: ""
                    if (si >= 0 && !c.isNull(si)) size = c.getLong(si)
                }}
            }}
            // 이름에 확장자가 없으면(일부 메신저 · 브라우저) 종류(MIME)로 붙인다
            if (name.isNotEmpty() && !name.contains('.')) {{
                val mime = contentResolver.getType(uri) ?: ""
                val ext = when (mime) {{
                    "application/epub+zip" -> "epub"
                    "application/pdf" -> "pdf"
                    "text/plain" -> "txt"
                    "application/zip" -> "zip"
                    "application/x-cbz", "application/vnd.comicbook+zip" -> "cbz"
                    else -> android.webkit.MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)
                }}
                if (!ext.isNullOrEmpty()) name = name + "." + ext
            }}
        }} catch (e: Exception) {{}}
        return mapOf("uri" to uri.toString(), "name" to name, "size" to size, "rel" to rel)
    }}

    /// 폴더 아래 모든 파일 (하위 폴더 포함). rel = 고른 폴더 기준 상대 폴더
    /// [fail]: 넘기면, 다 보지 못했을 때(읽다 실패 · 너무 많음) fail[0] 을 true 로 한다
    private fun listTree(tree: Uri, fail: BooleanArray? = null): List<Map<String, Any>> {{
        val out = mutableListOf<Map<String, Any>>()
        val rootId = android.provider.DocumentsContract.getTreeDocumentId(tree)
        val todo = ArrayDeque<Pair<String, String>>()
        todo.add(rootId to "")
        val cols = arrayOf(
            android.provider.DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            android.provider.DocumentsContract.Document.COLUMN_MIME_TYPE,
            android.provider.DocumentsContract.Document.COLUMN_SIZE,
        )
        while (todo.isNotEmpty() && out.size < 20000) {{
            val (id, rel) = todo.removeFirst()
            val children = android.provider.DocumentsContract.buildChildDocumentsUriUsingTree(tree, id)
            try {{
                val cur = contentResolver.query(children, cols, null, null, null)
                if (cur == null) fail?.set(0, true)
                cur?.use {{ c ->
                    while (c.moveToNext()) {{
                        val cid = c.getString(0) ?: continue
                        val name = c.getString(1) ?: ""
                        val mime = c.getString(2) ?: ""
                        if (mime == android.provider.DocumentsContract.Document.MIME_TYPE_DIR) {{
                            todo.add(cid to (if (rel.isEmpty()) name else "$rel/$name"))
                        }} else {{
                            val size = if (c.isNull(3)) -1L else c.getLong(3)
                            val doc = android.provider.DocumentsContract.buildDocumentUriUsingTree(tree, cid)
                            out.add(mapOf("uri" to doc.toString(), "name" to name, "size" to size, "rel" to rel))
                        }}
                    }}
                }}
            }} catch (e: Exception) {{ fail?.set(0, true) }}
        }}
        if (todo.isNotEmpty()) fail?.set(0, true)
        return out
    }}

    /// 연결한 폴더(tree) 아래 상대 경로의 문서 주소. 기기 저장공간 · SD 카드의 문서 이름은 "저장소:경로" 꼴이다
    private fun docUri(tree: Uri, rel: String): Uri {{
        val rootId = android.provider.DocumentsContract.getTreeDocumentId(tree)
        val id = if (rel.isEmpty()) rootId else if (rootId.endsWith(":")) rootId + rel else rootId + "/" + rel
        return android.provider.DocumentsContract.buildDocumentUriUsingTree(tree, id)
    }}

    /// 연결한 폴더의 실제 위치와 상태. path 는 기기 저장공간 · SD 카드 · USB 일 때만 (그 밖의 곳은 경로를 알 수 없다)
    private fun treeInfo(tree: Uri): Map<String, Any?> {{
        var path: String? = null
        var alive = false
        var held = false
        try {{
            val id = android.provider.DocumentsContract.getTreeDocumentId(tree)
            if (tree.authority == "com.android.externalstorage.documents" && id.contains(':')) {{
                val vol = id.substringBefore(':')
                val rel = id.substringAfter(':')
                val base = if (vol.equals("primary", true)) Environment.getExternalStorageDirectory().absolutePath else "/storage/" + vol
                path = if (rel.isEmpty()) base else base + "/" + rel
            }}
            held = contentResolver.persistedUriPermissions.any {{ it.uri == tree && it.isReadPermission }}
            val root = android.provider.DocumentsContract.buildDocumentUriUsingTree(tree, id)
            contentResolver.query(root, arrayOf(android.provider.DocumentsContract.Document.COLUMN_DOCUMENT_ID), null, null, null)?.use {{ alive = it.moveToFirst() }}
        }} catch (e: Exception) {{}}
        return mapOf("path" to path, "held" to held, "alive" to alive)
    }}

    private fun copyTo(uri: Uri, dest: String): Boolean {{
        val out = java.io.File(dest)
        out.parentFile?.mkdirs()
        val tmp = java.io.File("$dest.part")
        return try {{
            contentResolver.openInputStream(uri)?.use {{ input -> tmp.outputStream().use {{ input.copyTo(it, 1 shl 16) }} }} ?: return false
            if (out.exists()) out.delete()
            val ok = tmp.renameTo(out)
            if (!ok) tmp.delete() // 받다 만 파일을 남기지 않는다
            ok
        }} catch (e: Exception) {{
            tmp.delete()
            false
        }}
    }}

    private fun takeShared(i: Intent?): List<Uri> {{
        if (i == null) return emptyList()
        val list = mutableListOf<Uri>()
        if (i.action == Intent.ACTION_SEND) {{
            @Suppress("DEPRECATION")
            (i.getParcelableExtra<android.os.Parcelable>(Intent.EXTRA_STREAM) as? Uri)?.let {{ list.add(it) }}
        }} else if (i.action == Intent.ACTION_SEND_MULTIPLE) {{
            @Suppress("DEPRECATION")
            i.getParcelableArrayListExtra<android.os.Parcelable>(Intent.EXTRA_STREAM)?.forEach {{ p -> (p as? Uri)?.let {{ list.add(it) }} }}
        }}
        return list
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
if not STORE and "text-recognition-korean" not in g:  # 플레이스토어판은 글자 인식을 쓰지 않는다 (약 20MB 절약)
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
# 광고 SDK 가 쓰는 WorkManager: Room 이 만든 DB 클래스를 이름으로 찾아 만든다. R8 이 생성자를 지우면 앱이 켜지자마자 죽는다
-keep class * extends androidx.room.RoomDatabase { <init>(...); }
-keep class androidx.work.impl.WorkDatabase_Impl { *; }
# ML Kit(글자 인식) 부품도 이름으로 찾아 만든다 (생성자가 지워지면 글자 인식이 안 된다)
-keep class * implements com.google.firebase.components.ComponentRegistrar { <init>(); }
-keep class com.google.mlkit.**.*Registrar { <init>(); }
""", encoding="utf-8")
g = gradle.read_text(encoding="utf-8")
if "proguard-rules.pro" not in g:
    g = g.replace('signingConfig = if (keystorePropertiesFile.exists())',
                  'proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")\n            signingConfig = if (keystorePropertiesFile.exists())', 1)
    assert "proguard-rules.pro" in g
    gradle.write_text(g, encoding="utf-8")
print("proguard rules added")

# ---- 릴리스 빌드 때 도는 lint 검사 끄기 ----
# 플러그인(url_launcher_android 등)의 lint 가 도구 판 차이로 죽으면 앱 빌드 전체가 실패한다. 배포 빌드에는 필요 없는 검사라 끈다.
g = gradle.read_text(encoding="utf-8")
if "checkReleaseBuilds" not in g:
    g = g.replace("android {", "android {\n    lint {\n        checkReleaseBuilds = false\n        abortOnError = false\n    }", 1)
    gradle.write_text(g, encoding="utf-8")
root_gradle = Path("android/build.gradle.kts")
if root_gradle.exists():
    rg = root_gradle.read_text(encoding="utf-8")
    if "lintVital" not in rg:
        rg += '''
// 플러그인 모듈의 릴리스 lint 도 건너뛴다
subprojects {
    tasks.matching { it.name.startsWith("lintVital") }.configureEach { enabled = false }
}
'''
        root_gradle.write_text(rg, encoding="utf-8")
print("release lint disabled")

# ---- 소리 내어 읽기 서비스 (알림 + 잠깐 깨어 있기) ----
svc = act.parent / "ReadAloudService.kt"
svc.write_text(f"""package {pkg}

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

class ReadAloudService : Service() {{
    private var wake: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {{
        val title = intent?.getStringExtra("title") ?: ""
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {{
            nm.createNotificationChannel(NotificationChannel("read_aloud", "소리 내어 읽기", NotificationManager.IMPORTANCE_LOW))
        }}
        val open = PendingIntent.getActivity(this, 0, packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, "read_aloud") else @Suppress("DEPRECATION") Notification.Builder(this)
        val n = b.setContentTitle("소리 내어 읽는 중")
            .setContentText(title)
            .setSmallIcon(applicationInfo.icon)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 29) startForeground(4713, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        else startForeground(4713, n)
        if (wake == null) {{
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "arariflex:read").apply {{ acquire(6 * 60 * 60 * 1000L) }}
        }}
        return START_NOT_STICKY
    }}

    override fun onDestroy() {{
        wake?.let {{ if (it.isHeld) it.release() }}
        wake = null
        super.onDestroy()
    }}
}}
""", encoding="utf-8")
print("service written", svc)

# ---- 플레이스토어판: 쓰지 않는 네이티브 라이브러리 빼기 (APK 가 40MB 가까이 줄어든다) ----
if STORE:
    # 1) 글자 인식(ML Kit): MainActivity 에서 그 부분을 들어낸다 (위에서 의존성도 넣지 않았다)
    k = act.read_text(encoding="utf-8")
    k = re.sub(r"^import com\.google\.mlkit\..*\n", "", k, flags=re.M)
    k = re.sub(r"^\s*private val recognizer by lazy .*\n", "", k, flags=re.M)
    a, b = k.index("        // 글자 인식: ML Kit 한국어"), k.index("        // 화면을 꺼도 읽기가 이어지게")
    k = k[:a] + k[b:]
    assert "mlkit" not in k and "recognizer" not in k, "OCR 코드가 남았습니다"
    act.write_text(k, encoding="utf-8")
    # 2) ONNX 런타임(자연 음성 · PaddleOCR): 플러그인을 빈 껍데기 패키지로 바꿔 끼운다 → 네이티브 라이브러리가 들어가지 않는다
    Path("pubspec_overrides.yaml").write_text(
        "# tool/patch_android.py --store 가 만든 파일 (플레이스토어판 빌드에만)\n"
        "dependency_overrides:\n  flutter_onnxruntime:\n    path: tool/store_stubs/flutter_onnxruntime\n", encoding="utf-8")
    print("store: ML Kit · ONNX runtime left out")

# ---- 패키지 이름: 전체판 com.arariflex.full · 플레이스토어판 com.arariflex.app ----
# (코드가 들어 있는 자리(namespace)는 flutter create 가 만든 com.arariflex.arariflex 그대로 둔다)
g = gradle.read_text(encoding="utf-8")
APP_ID = STORE_ID if STORE else FULL_ID
g, n = re.subn(r'applicationId\s*=\s*"[^"]+"', f'applicationId = "{APP_ID}"', g, count=1)
assert n == 1, "applicationId not found"
gradle.write_text(g, encoding="utf-8")
print("applicationId", APP_ID)
