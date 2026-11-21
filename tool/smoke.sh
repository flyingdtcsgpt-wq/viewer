#!/bin/bash
# CI: 릴리스 APK 를 에뮬레이터에서 실제로 켜 보고 화면을 찍는다. 켜진 채로 버티지 못하면 실패.
# 사용법: tool/smoke.sh <패키지> <store|full>
pkg=$1; edition=$2
apk=build/app/outputs/flutter-apk/app-release.apk
mkdir -p smoke
adb install -r "$apk"
adb logcat -c
adb shell monkey -p "$pkg" -c android.intent.category.LAUNCHER 1
sleep 30
echo "SMOKE pid=$(adb shell pidof "$pkg" | tr -d '\r')"
adb exec-out screencap -p > smoke/1_first_screen.png || true

if [ "$edition" = store ] && [ -n "$(adb shell pidof "$pkg" | tr -d '\r')" ]; then
  # 켤 때 뜨는 사용법 안내를 닫고 빈 서재 화면
  adb shell input keyevent 4
  sleep 3
  adb exec-out screencap -p > smoke/2_home_empty.png || true
  # PC 에서 USB 로 넣은 것처럼 ARARIFlex 폴더에 직접 넣는다 → 앱에 돌아오면 저절로 나타나야 한다
  python3 - <<'PY'
import zipfile
with zipfile.ZipFile('sample.cbz', 'w') as z:
    for i in range(3):
        z.write('assets/icon/icon.png', f'{i:03d}.png')
PY
  adb push sample.cbz "/sdcard/Android/data/$pkg/files/ARARIFlex/Sample Comic 01.cbz" || echo "SMOKE push failed"
  adb shell input keyevent 3
  sleep 18
  adb shell monkey -p "$pkg" -c android.intent.category.LAUNCHER 1
  sleep 12
  adb exec-out screencap -p > smoke/3_after_usb_copy.png || true
  echo "SMOKE folder:"; adb shell ls -la "/sdcard/Android/data/$pkg/files/ARARIFlex/" || true
fi

adb logcat -d > smoke-logcat.txt || true
grep -nE "FATAL|E AndroidRuntime|F DEBUG|Abort message|Process $pkg.*died|Force finishing" smoke-logcat.txt | head -60 || true
if [ -z "$(adb shell pidof "$pkg" | tr -d '\r')" ]; then
  echo "::error::$edition 판이 켜진 채로 버티지 못했습니다 (smoke-logcat.txt 확인)"
  exit 1
fi
