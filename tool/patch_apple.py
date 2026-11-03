"""flutter create 로 만든 macos/ ios/ 폴더를 ARARIFlex 에 맞게 고친다 (CI 에서 실행).

사용법: python3 tool/patch_apple.py macos   또는   python3 tool/patch_apple.py ios
- 최소 버전: macOS 14 / iOS 16 (자연 음성용 ONNX Runtime 이 요구)
- macOS: 샌드박스 끄기(아무 폴더나 라이브러리로 쓰고, tar · say 를 부르기 위해), 창 크기, 앱 이름
- iOS: 파일 앱에 "ARARIFlex" 폴더 보이기, 같은 Wi-Fi 공유 서버 안내, 화면 잠금 중 소리 내어 읽기
"""
import re
import sys
from pathlib import Path

target = sys.argv[1]
assert target in ("macos", "ios")
root = Path(target)

PODFILE = {
    "macos": """platform :osx, '14.0'

ENV['COCOAPODS_DISABLE_STATS'] = 'true'

project 'Runner', {
  'Debug' => :debug,
  'Profile' => :release,
  'Release' => :release,
}

def flutter_root
  generated_xcode_build_settings_path = File.expand_path(File.join('..', 'Flutter', 'ephemeral', 'Flutter-Generated.xcconfig'), __FILE__)
  unless File.exist?(generated_xcode_build_settings_path)
    raise "#{generated_xcode_build_settings_path} must exist. Run flutter pub get first"
  end
  File.foreach(generated_xcode_build_settings_path) do |line|
    matches = line.match(/FLUTTER_ROOT\\=(.*)/)
    return matches[1].strip if matches
  end
  raise "FLUTTER_ROOT not found"
end

require File.expand_path(File.join('packages', 'flutter_tools', 'bin', 'podhelper'), flutter_root)

flutter_macos_podfile_setup

target 'Runner' do
  use_frameworks!
  flutter_install_all_macos_pods File.dirname(File.realpath(__FILE__))
  target 'RunnerTests' do
    inherit! :search_paths
  end
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_macos_build_settings(target)
    target.build_configurations.each do |config|
      config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '14.0'
    end
  end
end
""",
    "ios": """platform :ios, '16.0'

ENV['COCOAPODS_DISABLE_STATS'] = 'true'

project 'Runner', {
  'Debug' => :debug,
  'Profile' => :release,
  'Release' => :release,
}

def flutter_root
  generated_xcode_build_settings_path = File.expand_path(File.join('..', 'Flutter', 'Generated.xcconfig'), __FILE__)
  unless File.exist?(generated_xcode_build_settings_path)
    raise "#{generated_xcode_build_settings_path} must exist. Run flutter pub get first"
  end
  File.foreach(generated_xcode_build_settings_path) do |line|
    matches = line.match(/FLUTTER_ROOT\\=(.*)/)
    return matches[1].strip if matches
  end
  raise "FLUTTER_ROOT not found"
end

require File.expand_path(File.join('packages', 'flutter_tools', 'bin', 'podhelper'), flutter_root)

flutter_ios_podfile_setup

target 'Runner' do
  use_frameworks!
  flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))
  target 'RunnerTests' do
    inherit! :search_paths
  end
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
    end
  end
end
""",
}

# ---- Podfile (없으면 만들고, 있으면 최소 버전만 고친다) ----
pod = root / "Podfile"
if pod.exists():
    t = pod.read_text(encoding="utf-8")
    t = re.sub(r"^#?\s*platform :(osx|ios), '[\d.]+'", "platform :osx, '14.0'" if target == "macos" else "platform :ios, '16.0'", t, flags=re.M)
    pod.write_text(t, encoding="utf-8")
else:
    pod.write_text(PODFILE[target], encoding="utf-8")
print("Podfile ok")

# ---- Xcode 프로젝트 최소 버전 ----
pbx = root / "Runner.xcodeproj" / "project.pbxproj"
t = pbx.read_text(encoding="utf-8")
if target == "macos":
    t = re.sub(r"MACOSX_DEPLOYMENT_TARGET = [\d.]+;", "MACOSX_DEPLOYMENT_TARGET = 14.0;", t)
else:
    t = re.sub(r"IPHONEOS_DEPLOYMENT_TARGET = [\d.]+;", "IPHONEOS_DEPLOYMENT_TARGET = 16.0;", t)
pbx.write_text(t, encoding="utf-8")
print("deployment target ok")


def plist_set(path: Path, key: str, value_xml: str):
    """Info.plist 의 최상위 dict 에 키를 넣는다 (이미 있으면 값을 바꾼다)."""
    t = path.read_text(encoding="utf-8")
    pat = re.compile(r"(<key>" + re.escape(key) + r"</key>\s*)(<[^>]+/>|<(\w+)>.*?</\3>)", re.S)
    if pat.search(t):
        t = pat.sub(lambda m: m.group(1) + value_xml, t, count=1)
    else:
        i = t.rindex("</dict>")
        t = t[:i] + f"\t<key>{key}</key>\n\t{value_xml}\n" + t[i:]
    path.write_text(t, encoding="utf-8")


if target == "macos":
    # 샌드박스 끄기: 사용자가 고른 아무 폴더나 계속 읽고, tar(RAR) · say(음성) 를 부를 수 있게
    for name in ("DebugProfile.entitlements", "Release.entitlements"):
        p = root / "Runner" / name
        t = p.read_text(encoding="utf-8")
        t = re.sub(r"(<key>com.apple.security.app-sandbox</key>\s*)<true/>", r"\1<false/>", t)
        p.write_text(t, encoding="utf-8")
    info = root / "Runner" / "Configs" / "AppInfo.xcconfig"
    t = info.read_text(encoding="utf-8")
    t = re.sub(r"PRODUCT_NAME = .*", "PRODUCT_NAME = ARARIFlex", t)
    t = re.sub(r"PRODUCT_COPYRIGHT = .*", "PRODUCT_COPYRIGHT = ARARIFlex", t)
    info.write_text(t, encoding="utf-8")
    # 창: 처음 크기 1440×900, 가운데
    win = root / "Runner" / "MainFlutterWindow.swift"
    t = win.read_text(encoding="utf-8")
    if "setContentSize" not in t:
        t = t.replace("self.setFrame(windowFrame, display: true)",
                      "self.setFrame(windowFrame, display: true)\n    self.setContentSize(NSSize(width: 1440, height: 900))\n"
                      "    self.minSize = NSSize(width: 480, height: 600)\n    self.title = \"ARARIFlex\"\n    self.center()")
        win.write_text(t, encoding="utf-8")
    print("macos patched")
else:
    plist = root / "Runner" / "Info.plist"
    plist_set(plist, "CFBundleDisplayName", "<string>ARARIFlex</string>")
    plist_set(plist, "CFBundleName", "<string>ARARIFlex</string>")
    # 파일 앱의 "나의 iPhone › ARARIFlex" 폴더에 책을 넣으면 라이브러리에 들어온다
    plist_set(plist, "UIFileSharingEnabled", "<true/>")
    plist_set(plist, "LSSupportsOpeningDocumentsInPlace", "<true/>")
    plist_set(plist, "NSLocalNetworkUsageDescription", "<string>같은 Wi-Fi 의 다른 기기에서 라이브러리를 보는 공유 서버에 씁니다.</string>")
    plist_set(plist, "UIBackgroundModes", "<array>\n\t\t<string>audio</string>\n\t</array>")
    plist_set(plist, "ITSAppUsesNonExemptEncryption", "<false/>")
    print("ios patched")
