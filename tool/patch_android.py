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
