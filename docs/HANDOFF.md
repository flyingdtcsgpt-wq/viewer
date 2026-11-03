# ARARIFlex 이어서 개발하기 (인수인계서)

다른 컴퓨터 · 다른 개발자 · 다른 AI 도구로 이어서 개발할 때 필요한 것을 모았습니다.

## 0. 받은 묶음 안에 있는 것

| 파일 | 내용 |
|---|---|
| `ARARIFlex-src/` | 소스코드 전체 (이 저장소) |
| `ARARIFlex-history.bundle` | git 전체 기록 (커밋 70여 건). `git clone ARARIFlex-history.bundle ARARIFlex` 로 기록째 복원 |
| `docs/MANUAL.md` | 사용 설명서 (설치 · 기능 · 자주 묻는 것) |
| `docs/DEV_NOTES.md` | 개발 노트 (설계 · 결정 이유 · 플랫폼별 메모 · 알려진 한계) |
| `docs/SOURCE_GUIDE.md` | 소스 설명서 (파일마다 하는 일) |
| `docs/CHANGELOG.md` | 개발 내역서 (모든 변경 날짜순) |
| `docs/HANDOFF.md` | 이 문서 |

설치 파일(Windows · 안드로이드 · 맥 · 아이폰)은 GitHub Actions 의 **ARARIFlex-all-in-one** Artifact 에 함께 들어 있습니다 (5장).

## 1. AI 도구로 이어서 할 때 첫 말

> 이 저장소는 ARARIFlex (Flutter, 책 · 만화 · 그림 · 영상 라이브러리 앱) 입니다.
> 먼저 `docs/DEV_NOTES.md`, `docs/SOURCE_GUIDE.md` 를 읽고, 5장 "지켜야 할 것"을 따르세요.
> 답변 · 화면 글자 · 주석은 한국어로. 고친 뒤 GitHub Actions 결과(로그의 `CHECK` 줄, 캡처 브랜치)로 확인하세요.

## 2. 개발 환경

| 대상 | 필요한 것 |
|---|---|
| 공통 | Flutter stable 3.47 이상 (Dart 3.13 이상), Git, Python 3 (패치 스크립트) |
| Windows | Visual Studio 2022 "C++ 데스크톱 개발", (설치파일) Inno Setup 6 |
| Android | Android Studio (SDK, JDK 17) |
| macOS · iOS | 맥, Xcode 16 이상, CocoaPods (`brew install cocoapods`). 실제 기기 설치는 Apple ID 서명 |

저장소에는 `windows/ android/ macos/ ios/` 폴더가 **없습니다**. 매번 `flutter create` 로 만들고 패치 스크립트로 고칩니다
(Flutter 버전이 바뀌어도 깨지지 않게 하려는 것).

## 3. 직접 빌드하기

```bash
git clone https://github.com/flyingdtcsgpt-wq/viewer.git ARARIFlex
cd ARARIFlex
flutter pub get
```

**Windows**
```bash
flutter create --platforms=windows --org com.mediashelf --project-name media_shelf .
python tool/patch_windows.py
dart run flutter_launcher_icons -f tool/icons_windows.yaml
flutter run -d windows            # 개발 실행
flutter build windows --release   # build/windows/x64/runner/Release
```
RAR/7Z 와 영어 성우를 쓰려면 `Release/tools/7zip/7z.exe`(7-Zip), `Release/tools/espeak-ng/espeak-ng.exe`(eSpeak NG)를 넣습니다
(CI 가 하는 일: `.github/workflows/build.yml` 의 Fetch eSpeak NG · Bundle 단계 참고).

**Android**
```bash
flutter create --platforms=android --org com.mediashelf --project-name media_shelf .
python3 tool/patch_android.py
dart run flutter_launcher_icons -f tool/icons_android.yaml
flutter build apk --release --split-per-abi
```
정식 서명: `android/key.properties` + `android/app/release.p12` (CI 는 Secrets `ANDROID_KEYSTORE_BASE64 / ANDROID_KEYSTORE_PASSWORD / ANDROID_KEY_ALIAS`).

**macOS**
```bash
flutter create --platforms=macos --org com.mediashelf --project-name media_shelf .
flutter pub get
python3 tool/patch_apple.py macos
dart run flutter_launcher_icons -f tool/icons_macos.yaml
flutter build macos --release
```

**iPhone · iPad**
```bash
flutter create --platforms=ios --org com.mediashelf --project-name media_shelf .
flutter pub get
python3 tool/patch_apple.py ios
dart run flutter_launcher_icons -f tool/icons_ios.yaml
flutter build ios --release --no-codesign      # 서명은 Xcode 나 Sideloadly 로
```

**검사**
```bash
flutter analyze lib test
flutter test                                              # 단위 테스트
flutter test integration_test/screenshots_test.dart -d windows   # 화면 캡처 + 검사 (SHOTS_DIR, TTS_CHECK=1 환경변수)
```

## 4. 모델 · 외부 프로그램 (앱에 넣지 않고 받는 것)

| 무엇 | 받는 곳 | 저장 위치(데이터 폴더 안) | 라이선스 |
|---|---|---|---|
| 자연 음성 Supertonic 3 (약 380MB) | huggingface.co/supertone-oss-archive/supertonic-3 (revision `aafc6e32…`) `onnx/*`, `voice_styles/*` | `voices/supertonic-3/` | OpenRAIL-M |
| 한국어 글자 인식 PaddleOCR (약 20MB) | huggingface.co/monkt/paddleocr-onnx `detection/v5/det.onnx`, `languages/korean/rec.onnx`, `languages/korean/dict.txt` | `models/paddleocr/` | Apache 2.0 |
| 영어 성우 Kokoro (약 340MB) | github.com/thewh1teagle/kokoro-onnx releases `model-files-v1.1`: `kokoro-v1.0.onnx`, `voices-v1.0.bin` | `models/kokoro/` | Apache 2.0 |
| eSpeak NG (Windows 동봉) | github.com/espeak-ng/espeak-ng releases (msi) | 앱 폴더 `tools/espeak-ng/` | GPL-3 |
| 7-Zip (Windows 동봉) | 7-zip.org | 앱 폴더 `tools/7zip/` | LGPL + unRAR |

데이터 폴더: Windows `%APPDATA%\com.mediashelf\media_shelf`, 휴대용 모드면 앱 옆 `arariflex_data`.
인터넷 없는 PC: 위 파일을 받아 설정 화면의 "폴더에서 가져오기", 또는 휴대용 폴더째 복사.

## 5. CI (GitHub Actions) 결과 보는 곳

- 저장소 Actions → 맨 위 실행 → Artifacts
  - `ARARIFlex-all-in-one`: 모든 설치파일 + 소스 + 문서 한 번에
  - `ARARIFlex-windows`(설치판 · 포터블 zip), `ARARIFlex-android`, `ARARIFlex-macos`, `ARARIFlex-ios`
- 화면 캡처 브랜치: `screenshots`(Windows · 태블릿 크기), `screenshots-android`, `screenshots-macos`, `screenshots-ios`
- 검사 로그: screenshots 잡의 "Capture screens" 단계에서 `CHECK` 로 시작하는 줄

## 5-1. 배포 페이지(Releases)에 올리기 (로그인 없이 받기 · 영구 보관)
1. 저장소 → 오른쪽 **Releases** → **Draft a new release**
2. **Choose a tag** 에 `v0.5.0` 입력 → "Create new tag" → 제목 `ARARIFlex 0.5.0` → **Publish release**
3. 약 40분 뒤 그 배포 페이지에 Windows · 안드로이드 · 맥 · 아이폰 설치파일, 소스, git 기록, 문서가 자동으로 올라옵니다.
   (Actions 의 Artifacts 는 로그인해야 받을 수 있고 90일 뒤 지워집니다)

## 6. 다음 할 일 후보
- 휴대폰에서 RAR · 7Z 만화 열기
- PDF 나누기 · 합치기, EPUB 편집기, WebDAV, 휴대폰 연동(QR)
- AI 로 화자 찾기(규칙으로 못 찾은 대사), 원본 로고 PNG 교체
- 맥 · 아이폰 정식 서명/배포(유료 Apple 개발자 계정 필요)
