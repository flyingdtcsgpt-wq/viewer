"""flutter create 로 만든 AndroidManifest.xml 에 권한/앱 이름을 넣는다 (CI 에서 실행)."""
import re
from pathlib import Path

path = Path("android/app/src/main/AndroidManifest.xml")
xml = path.read_text(encoding="utf-8")

perms = [
    "android.permission.INTERNET",                 # 책 정보 검색, AI
    "android.permission.READ_EXTERNAL_STORAGE",    # Android 12 이하
    "android.permission.WRITE_EXTERNAL_STORAGE",
    "android.permission.READ_MEDIA_IMAGES",        # Android 13+
    "android.permission.READ_MEDIA_VIDEO",
    "android.permission.MANAGE_EXTERNAL_STORAGE",  # 폴더 전체 스캔 (Android 11+)
]
lines = "".join(f'    <uses-permission android:name="{p}"/>\n' for p in perms if p not in xml)
xml = re.sub(r"(<manifest[^>]*>\n)", r"\1" + lines, xml, count=1)
xml = xml.replace('android:label="media_shelf"', 'android:label="MediaShelf"')
if "requestLegacyExternalStorage" not in xml:
    xml = xml.replace("<application", '<application\n        android:requestLegacyExternalStorage="true"', 1)
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

class MainActivity : FlutterActivity() {{
    private var pending: MethodChannel.Result? = null

    private fun hasAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) Environment.isExternalStorageManager()
        else checkSelfPermission(android.Manifest.permission.READ_EXTERNAL_STORAGE) == android.content.pm.PackageManager.PERMISSION_GRANTED

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {{
        super.configureFlutterEngine(flutterEngine)
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
