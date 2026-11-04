# ARARIFlex 개발 노트

새 채팅(또는 다른 개발자)이 이어서 작업할 때 이 파일부터 읽는다.
마지막 갱신: 2026-11-02 · 버전 0.5.0 (pubspec `0.5.0+5`, `lib/version.dart`)

---

## 1. 한눈에 보기

| 항목 | 내용 |
|---|---|
| 앱 이름 | **ARARIFlex** (아라리플렉스). 붙여 쓴다. 포인트 색은 빨강 `#E50914` |
| 무엇 | 책(TXT·EPUB·PDF) · 만화(CBZ·ZIP·CBR·RAR·7Z) · 그림 · 영상을 관리하고 보는 개인 라이브러리 |
| 기술 | Flutter / Dart 3.13+, Flutter ≥ 3.47 (stable) |
| 순서 | **Windows 먼저 → Android → iOS/macOS** |
| 저장소 | https://github.com/flyingdtcsgpt-wq/viewer (공개, 브랜치 `main`) |
| 패키지 이름 | Dart `media_shelf`, 조직 `com.mediashelf` (예전 이름 MediaShelf 의 흔적, 바꾸지 말 것: DB · 설정 경로가 바뀜) |
| 빌드 | GitHub Actions 만 사용 (개발 컨테이너에 Flutter 없음). push 하면 Windows 설치파일 생성 |
| 사용자 | 한국어 사용자. 답변 · UI · 주석 모두 **한국어** |

## 2. 빌드 · 배포 (CI)

`.github/workflows/build.yml`

- **windows** 잡 (push 마다)
  1. `flutter create --platforms=windows .` 로 플랫폼 폴더 생성 (저장소에는 windows/ android/ 폴더가 없다)
  2. `tool/patch_windows.py`: 창 제목 `ARARIFlex`, 기본 크기 1600×960, WebView2 플러그인용 CMake 정의
     `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS`
  3. 아이콘 `tool/icons_windows.yaml` (flutter_launcher_icons)
  4. `flutter analyze lib test` (오류만 실패), `flutter test`
  5. `flutter build windows --release`
  6. 7-Zip(빌드 머신의 Program Files 에서 복사), VC++ 런타임 DLL, `THIRD_PARTY_NOTICES.txt` 동봉
  7. Inno Setup `installer/media_shelf.iss` → `dist/ARARIFlex-<ver>-windows-setup.exe` + 포터블 zip
  8. Artifact `ARARIFlex-windows`. 태그 `v*` 면 Releases 에 게시 (태그 생성은 사용자가 직접)
- **screenshots** 잡 (push 마다, 실패해도 전체는 통과)
  - `integration_test/screenshots_test.dart` 를 실제 Windows 앱으로 실행 (`flutter test ... -d windows`)
  - 샘플 만화/소설/그림을 만들어 가져오고 21개 화면 캡처 (PC 1600×960, 휴대폰 412×915, 밝은 테마)
  - 자동 검사(로그에 `CHECK ...`): 숨김 추가 누출 없음, 계정별 종류 제한 누출 없음, 공유 서버 HTTP 권한,
    자연 음성 모델 받기 + 한국어 합성(길이 · 음량), Windows OCR(영어; 서버엔 한국어 인식기 없음)
  - 결과 PNG · WAV 를 **`screenshots` 브랜치**로 강제 push → https://github.com/flyingdtcsgpt-wq/viewer/tree/screenshots
- **android** 잡: 태그 또는 수동 실행(workflow_dispatch) 때만
  - `tool/patch_android.py`: 권한, 앱 이름, MainActivity 의 `mediashelf/storage` 채널(모든 파일 접근), 서명
  - Secrets `ANDROID_KEYSTORE_BASE64/PASSWORD/KEY_ALIAS` 가 있으면 정식 서명, 없으면 debug 키
  - ABI 별 APK (`…-android.apk` = arm64, `…-android-old32bit.apk`)

개발 환경 메모
- 이 개발 컨테이너에서는 Flutter 를 돌리지 않는다 → 코드 수정 → push → CI 로그로 확인.
- CI 결과 확인 스크립트(대화 중 만든 것): run 을 sha 로 찾아 끝날 때까지 기다리고 `error -`, `CHECK`, `STEP FAILED` 줄만 출력.
- Artifact zip 은 컨테이너에서 못 받는다(blob 호스트 차단) → 그래서 캡처는 `screenshots` 브랜치로 올린다.
- huggingface.co 도 컨테이너에선 차단, CI 러너에선 됨.

## 3. 폴더 구조

```
lib/
  main.dart                 앱 시작, 테마(appTheme), brandRed, 네이티브 라이선스 등록
  app_state.dart            ★ 중심 상태(ChangeNotifier): 항목·묶음·사용자·숨김·접근권한·가져오기·스캔
  version.dart              appVersion
  db/library_db.dart        SQLite (sqflite / Windows 는 sqflite_common_ffi). DB v5
  models/                   media_item(MediaKind), series(SeriesStatus), entry(그리드 칸, SeriesStats)
  services/
    settings.dart           SharedPreferences 래퍼 (모든 설정 키)
    auth.dart               AppUser, PBKDF2 비밀번호
    cover_service.dart      표지 만들기/캐시 (EPUB·PDF·압축·영상 썸네일)
    organizer.dart          정리 규칙 경로, 복사/이동(moveFile: 실패 시 되돌림)
    series_parser.dart      파일명 → 제목/권수, 외전 판별
    archive_tools.dart      압축 정리 · 이름 바꾸기 · 표지 넣기 (archive 4.x)
    ext_archive.dart        RAR/7Z: 동봉 7-Zip(tools/7zip/7z.exe) 또는 tar 로 한 쪽씩 꺼내기(PageLoader)
    epub_book.dart / epub_writer.dart / text_document.dart   EPUB 읽기, TXT→EPUB, 텍스트 문서 모델
    metadata_service.dart   카카오·네이버·Google Books·Open Library
    ai_service.dart         Claude API (선택, 키 필요)
    share_server.dart       같은 Wi-Fi 공유: Web + OPDS, 기본 인증, 접속자별 접근 규칙(AccessView)
    tts_service.dart        소리 내어 읽기: Windows System.Speech(PowerShell) + 자연 음성 재생(media_kit)
    natural_tts.dart        ★ Supertonic 3 (ONNX Runtime) 자연 음성 합성, 모델 받기/가져오기
    ocr_service.dart        ★ Windows.Media.Ocr (PowerShell 5.1 + WinRT) 글자 인식, 그림 타일링
    speakers.dart           대사 화자 찾기(규칙 기반) — "…" 민호가 속삭였다
    storage_permission.dart Android 모든 파일 접근 (네이티브 채널)
  ui/
    home_page.dart          PC: 위 작업 줄(_TopActionBar) / 사이드바 / 목록 / 상세 / 상태 막대. 폰: 하단 탭
    landing_view.dart       홈(넷플릭스풍 배너 + 가로 줄), HoverZoom
    browser.dart            격자/표/카드 목록, 경로 막대, 상세 패널, 상태 막대, 메뉴
    series_widgets.dart     묶음 카드, 묶음 편집, 선택 막대, 묶음 고르기
    cover_tile.dart         책 카드, CoverImage(없으면 TitleCover)
    brand.dart              appName, ArariLogo, TitleCover(제목 색 표지)
    import_dialog.dart      ★ 폴더/파일 추가 창 (목록 선택, 중복, 추가 방식, 묶기, 숨김)
    login_page.dart         첫 실행 관리자 만들기, 프로필 선택, 비밀번호 초기화(_ResetView)
    admin_page.dart         사용자 관리, 숨김 비밀번호, AccessPage(폴더·종류·묶음·작품 권한)
    settings_page.dart      설정 9개 분류(일반 … 읽어주기 음성(_Voice) … 정보)
    share_page.dart, history_page.dart, detail_page.dart, batch_editor_page.dart, metadata_search_dialog.dart, ai_chat_sheet.dart
    tools/                  파일 도구, 표지 이미지 편집기
    viewers/                comic / text(TXT·EPUB) / epub_original(WebView2) / pdf / image / video, viewer_chrome(도구줄 부품),
                            read_aloud.dart(쪽 단위 읽어주기 막대), open_item.dart(종류별 뷰어 열기)
integration_test/screenshots_test.dart   CI 화면 캡처 + 자동 검사
test/                       단위 테스트 (auth, series_parser, speakers, widget)
tool/                       patch_windows.py, patch_android.py, 아이콘 설정
installer/media_shelf.iss   Inno Setup
THIRD_PARTY_NOTICES.txt     라이선스 고지 (UTF-8 BOM 유지)
docs/                       DEV_NOTES.md(이 파일), MANUAL.md(사용 설명서)
```

## 4. 핵심 설계

### 데이터
- 항목(MediaItem): 경로, 종류, 제목, 권수, 표지 경로, 진행률(사용자별은 user_progress), hidden, storage(reference/managed)
- 묶음(Series): 트리(parentId). 권수/전체 권수, 연재 상태. `LibraryTree` 가 보이는 항목으로 색인
- 사용자: users 표. 관리자/사용자. 사용자별 열람 기록 · 진행률
- 접근 제한: `denied` 표에 문자열 키 — `s:<묶음id>`, `i:<항목id>`, `f:<라이브러리 폴더 경로>`, `k:<book|comic|image|video>`
  - `AppState.canSeeItem/canSeeSeries` = 로그인 + 접근 허용 + (숨김 해제 상태 또는 숨김 아님)
  - 폴더·종류 제한이 있으면 볼 권이 없는 묶음도 감춘다(`_computeSeriesAccess`)
  - 공유 서버는 `accessFor(user)` → `AccessView` 로 같은 규칙을 다른 사용자에게 적용
- 숨김: 항목/묶음 hidden + Windows 숨김 속성. 숨김 비밀번호를 검색창에 입력하면 해제, 앱 닫으면 다시 잠김
- 설정: SharedPreferences (`Settings`), 관리자 공통. 책별 인물 목소리 `spk_<bookId>`

### 가져오기 (import)
`previewFolder/previewFiles` → `ImportCandidate` 목록(새 항목/이미 등록/중복 의심: 크기 + 앞 256KB SHA-1)
→ `importCandidates(picked, ImportOptions)`
- 모드: reference(원본 연결) / copy / move (정리 규칙 `organizePattern`, 실패 시 파일 되돌림)
- 묶기: auto(파일명) / folderTree / wholeFolder(묶음 하나, 잡동사니 폴더) / none
- hidden: 등록 순간부터 숨김, 새로 생긴 묶음도 숨김
- watch: 라이브러리 폴더로 등록 (겹치는 안쪽 폴더는 합침)
- 한 번에 하나만 (scanning 플래그)

### 비밀번호 초기화
데이터 폴더(`getApplicationSupportDirectory`, Windows 는 보통 `%APPDATA%\com.mediashelf\media_shelf`)에
`RESET_PASSWORD.txt` 가 있으면 로그인 화면이 초기화 화면으로 바뀐다. 끝나면 파일 삭제.

### 소리 내어 읽기
- `TtsService.speak(text, voice, rate)`: voice 가 `st:F1` 처럼 `st:` 로 시작하면 자연 음성, 아니면 Windows 음성
- 자연 음성: `NaturalTts.synthesize` → WAV 임시 파일 → media_kit Player 재생
  - 모델: Hugging Face `supertone-oss-archive/supertonic-3` revision `aafc6e32416a594460b32413efc49d7fe4ce6d46`
    `onnx/{tts.json, unicode_indexer.json, duration_predictor, text_encoder, vector_estimator, vocoder}.onnx`(약 380MB)
    + `voice_styles/{F1..F5,M1..M5}.json` → `<데이터 폴더>/voices/supertonic-3/`
  - 추론은 Supertonic 공식 Flutter 예제(MIT) 이식: 한글 자모 분해 → 길이 예측 → 텍스트 인코더 → 8단계 잡음 제거 → vocoder,
    길이만큼 자르고 문장 사이 0.3초. 44.1kHz
  - 합성은 한 줄로 직렬화(`_queue`), 다음 문장 미리 만들기(`prefetch`), 사용자가 멈추면 미리 만들기 취소(`_epoch`)
  - 멈춤/다시 읽기 경쟁: `TtsService._gen`, 뷰어 쪽 `_ttsRun` / ReadAloudBar `_run`
  - `failed` 가 true 일 때만 오류 표시 (멈춤과 구분)
- 텍스트 뷰어: 문단을 서술(0) / 대사(1, "…") / 속마음(2, '…') 으로 나눔. 대사는 `Speakers.speakerAt` 로 화자를 찾고
  책별 인물 목소리가 있으면 그 목소리
- PDF/만화/그림: `ReadAloudBar` (쪽 단위). PDF 는 `page.loadText()`, 글자가 15자 미만이면 2600px 로 그려 OCR
- OCR: PowerShell 스크립트(BOM UTF-8, `%TEMP%\arari_ocr_v2.ps1`)가 WinRT OcrEngine 사용. 그림은 PNG 로 바꾸고
  2600px 넘으면 줄이거나 80px 겹치게 잘라서 넘김. 한국어 인식기가 없으면 다른 언어로 읽고 `OcrService.koreanMissing` 안내

## 5. 지켜야 할 것 (사용자 요구 · 결정 사항)
- 앱 이름은 **ARARIFlex** 붙여쓰기, 로고는 코드로 그린 `ArariLogo`(ARARI + 빨간 기울임 Flex + 물결 + 첫 A 안 재생 ▶)
  — 원본 로고 PNG 를 받으면 교체 예정
- 만화 기본 넘김: **오른쪽→왼쪽으로 밀면 다음 쪽** (사용자 요청)
- 삭제는 항상 "목록에서만 / 원본 파일까지" 물어본다
- 무료 로컬 우선, 안 되면 저렴한 API 를 선택 옵션으로
- 오프라인 PC 설치 가능해야 함: 코덱(FFmpeg via libmpv) · 7-Zip · VC++ 런타임 동봉, 모델은 폴더에서 가져오기 지원
- 라이선스 고지 포함 (THIRD_PARTY_NOTICES.txt + 앱 안 라이선스 화면). Supertonic 모델은 OpenRAIL-M, 앱에 넣지 않음
- 하지 말 것(권한 거부됨): 태그/릴리스 직접 만들기, GitHub Secrets 쓰기, 컨테이너에서 Flutter 내려받아 실행

## 6. 알려진 한계 · 다음 할 일
- 한국어 OCR 은 CI 에서 검증 못 함(서버 Windows 에 인식기 없음). 실제 한국어 Windows 에서 확인 필요
- 만화 말풍선 OCR 은 읽는 순서가 틀릴 수 있음(시험 기능)
- EPUB 편집기, TXT → PDF(한글 글꼴을 넣어야 함), AI 화질 향상은 만들지 않기로 하고 도구 목록에서 뺐다 (11-04)
- 공유 서버는 HTTP(암호화 없음) — 같은 Wi-Fi 전용

## 7. 작업 이력 요약
- 11-01: v0.2 첫 구조(뷰어 4종, CI), 묶음 트리, 로그인·사용자별 기록·관리자 권한·숨김, 넷플릭스풍 디자인, Android 모든 파일 접근, 서명
- 11-02 오전: v0.3 BookManager 풍 PC 화면, 만화/텍스트/PDF 뷰어 개편, 설정 창, 메타데이터 통합 검색 · 일괄 편집, 파일 도구,
  공유 서버(Web/OPDS), TTS, RAR/7Z(동봉 7-Zip), 영상 자막/음성 트랙, EPUB 원본 스타일(WebView2)
- v0.4: 표지 편집기, TXT→EPUB. 이름 변경 → ARARIFlex, 가져오기 창(목록 선택 · 중복 · 복사/이동 · 묶기 · 숨김), 비밀번호 초기화
- UI 자동 캡처 도입 후 개선: 작업 줄 정리, 만든 표지, 카드 크기, 뷰어 색, 계정별 폴더/종류 권한, 휴대폰 탭
- v0.5: 자연 음성(Supertonic), PDF/그림/만화 읽어주기(OCR), 인물별 목소리, 공유 서버 계정 권한, 리뷰 2회분 버그 수정

## 8. Android 작업 메모
- CI: `android` 잡이 push 마다 APK 빌드 (안드로이드 다듬는 동안). `android-screens` 잡이 에뮬레이터(API 34, x86_64)에서
  `flutter drive --driver=test_driver/integration_test.dart --target=integration_test/screenshots_test.dart` 실행
  → 앱이 `binding.reportData` 로 PNG/WAV 를 base64 로 보내고 드라이버가 `shots-android/shots` 에 저장 → `screenshots-android` 브랜치
  (flutter test 는 끝나면 앱을 지워서 기기 안 파일을 못 꺼냄)
- 에뮬레이터 확인 결과: 자연 음성(Supertonic) 정상(7.9초 음성 7.5초), ML Kit 한국어 OCR 정확("언덕 위에는 오래된 풍차가 하나 서 있었다."),
  숨김 · 계정 권한 · 공유 서버 검사 모두 통과
- 기기 음성: `tool/patch_android.py` 가 MainActivity 에 `mediashelf/tts` 채널(TextToSpeech) 추가. 음성 이름은 `and:<name>|<locale>|local/net`
  (flutter_tts 는 Windows 빌드에 nuget 이 필요해서 쓰지 않음). 매니페스트 `<queries>` 에 TTS_SERVICE 필요(Android 11+)
- OCR: google_mlkit_text_recognition + 앱 gradle 에 `text-recognition-korean` 추가. R8 이 안 쓰는 중국어/일본어/데바나가리 클래스를
  찾지 못해 실패 → `proguard-rules.pro` 에 -dontwarn
- "ARARIFlex 로 열기": VIEW 인텐트 필터 + `mediashelf/open` 채널(`takeFile`, `opened`). content:// 는 files/opened 로 복사.
  Dart 는 `AppState.requestOpen` → HomePage 의 `_ExternalOpener` 가 라이브러리에 원본 연결로 넣고 연다
- RAR/7Z 는 안드로이드에서 아직 못 엶(7-Zip 실행 파일이 없음) → 뷰어가 안내 문구를 보여 줌
- 모든 파일 접근: `mediashelf/storage` 채널 (폴더 추가 때만 요청)
- 열기 인텐트 검수 반영: 책·만화 MIME 만 받음(이미지·영상·octet-stream 제외), 복사는 백그라운드 스레드, `opened/<이름+크기 해시>/이름`
  (덮어쓰기 · 재복사 방지, .part → rename), launchMode singleTask, 최근 앱에서 다시 열 때(FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) 무시,
  확장자 없으면 MIME 으로, 계정이 막힌 종류면 추가하지 않음
- TTS: 4000자 제한 → 3500자 단위로 나눠 읽기, 응답 없음 대비 타임아웃, 엔진 초기화 실패 시 다음에 재시도
- 에뮬레이터에서 integration test 의 tap 은 히트 테스트가 안 맞음(캡처용 OverflowBox 구조) → 화면 상태는 생성자 옵션
  (`TextReaderPage(readAloud: true)`, `ImageViewerPage(readAloud: true)`)으로 연다
- 확인됨(에뮬레이터): 기기 음성 72개, 한국어 기기 음성 읽기 성공, 자연 음성, ML Kit 한국어 OCR, 권한 · 숨김 · 공유 서버
- APK 크기: arm64 약 88MB (libmpv · ONNX Runtime · ML Kit 한국어 모델 · PDFium 포함)

## 9. macOS · iOS · 태블릿 메모
- 최소 버전: **macOS 14 / iOS 16** (flutter_onnxruntime podspec 요구). `tool/patch_apple.py macos|ios` 가 Podfile · pbxproj 최소 버전,
  Info.plist / 엔타이틀먼트를 고친다. 아이콘: `tool/icons_macos.yaml`, `tool/icons_ios.yaml`
- macOS: 샌드박스 끔(아무 폴더 읽기 · tar · say 실행). 창 1440×900. 서명 없음 → 첫 실행 Control+클릭 열기. 산출물 zip + dmg
- iOS: 서명 없는 IPA(`flutter build ios --no-codesign` → Payload zip). 설치는 Sideloadly/AltStore.
  라이브러리 = 앱 Documents(UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace 로 파일 앱에 "ARARIFlex" 폴더),
  `AppState._setupIosLibrary` 가 라이브러리 폴더로 등록하고 앱 업데이트로 컨테이너 경로가 바뀌면 저장된 경로를 옮긴다.
  켤 때 · 돌아올 때(AppLifecycleListener) 다시 스캔. "폴더 추가"는 안내 창, "파일 추가"는 Documents 로 복사
- 네이티브: `packages/arari_native` (로컬 플러그인, sharedDarwinSource) — `mediashelf/ocr`(Vision, ko-KR/en-US),
  `mediashelf/tts`(AVSpeechSynthesizer, iOS 에서 사용; macOS 는 기존 `say`). 음성 이름 `ios:<identifier>|<lang>|local|<name>`
- 안드로이드 OCR 도 플러그인 대신 MainActivity 의 `mediashelf/ocr` 채널(ML Kit 한국어)로 통일 (ML Kit iOS pod 는 애플 실리콘 시뮬레이터에서 문제)
- CI: `macos` 잡(빌드 + `flutter test -d macos` 캡처 → `screenshots-macos` 브랜치), `ios` 잡(빌드 + 아이폰 · 아이패드 시뮬레이터
  `flutter drive` 캡처 → `screenshots-ios` 브랜치)
- 확인됨(맥 러너): Vision 한국어 OCR 정확, macOS 음성 194개 · 읽기 성공, 권한 · 숨김 · 공유 서버 통과.
  고친 버그: macOS 첫 자연 음성 때 임시 폴더가 없어 실패 → 만들고 쓰기
- 태블릿: 캡처 크기 1194×834(가로, PC 배치) · 834×1194(세로, 휴대폰 배치). 세로 배너 높이를 화면 높이로 제한

## 10. 휴대용 모드 · PaddleOCR · Kokoro (11-03)
- 휴대용: `lib/services/portable.dart`. 앱 옆 `arariflex_data` 가 있으면 `PathProviderPlatform.instance` 를 바꿔 support/documents/cache 를
  그 폴더로 (DB · 표지 · 모델 전부 자동으로 따라옴). 설정은 `Prefs` 추상화 → 휴대용이면 `arariflex_data/settings.json`(300ms 모아 쓰기, 깨지면 .broken).
  `Portable.makePortable` 이 지금 데이터 + 설정을 복사. 포터블 zip 은 CI 에서 빈 `arariflex_data`(README.txt) 를 넣어 만든다(설치판엔 없음)
- PaddleOCR: `lib/services/paddle_ocr.dart`. HF `monkt/paddleocr-onnx` 파일 목록에서 이름으로 고름 → 실제 경로
  `detection/v5/det.onnx`, `languages/korean/rec.onnx`, `languages/korean/dict.txt` (models/paddleocr/{det,rec}.onnx, dict.txt).
  DB 검출(긴 변 960, BGR, ImageNet 정규화, 임계 0.3/0.6, unclip 1.6, 연결요소 → 축정렬 상자) → 높이 48 인식 → CTC(0=blank, 끝 공백).
  Windows 에서 설치돼 있으면 Windows OCR 보다 먼저. CI: 영어 Windows 에서 한국어 문장 정확, 1.8초
- Kokoro: `lib/services/kokoro_tts.dart`. GitHub release `thewh1teagle/kokoro-onnx` model-files-v1.1 의 `kokoro-v1.0.onnx` + `voices-v1.0.bin`(npz).
  **int8 은 CPU 에서 15배 느려서(4.7초 음성 14초) fp32 만 받는다** (0.9초). 입력 tokens/input_ids [1,n+2] (0 패딩), style = voice[n-1] [1,256], speed [1].
  출력은 이름에 wav/audio 가 든 것 (길이 출력도 있음). 발음: eSpeak NG `--ipa -v en-us --stdin` → Kokoro 어휘(178)만 남김.
  eSpeak NG 는 CI 가 GitHub release msi 를 풀어 `tools/espeak-ng` 에 동봉 (GPL-3, 별도 프로그램). `ESPEAK_NG_PATH` 환경변수로 덮어쓰기 가능.
  음성 이름 `kk:af_heart`, 미국(a) · 영국(b) 28가지. 한글이 섞인 글에 Kokoro 를 고르면 `st:F1` 로 바꿔 읽음
- 소리 내어 읽기 범위: 소설만 (TXT · EPUB · PDF). 만화 · 그림 뷰어에서는 뺐다 (사용자 요청)

## 11. 큰 서재 성능 · 취침 타이머 · 오디오북 · 파일 도구 (11-04)
- 성능: `AppState._rev`(데이터 판) 마다 파생값을 `_memo` 로 한 번만 계산, 보기만 바뀌면 `_viewChanged()`(캐시 유지).
  권한은 `_DenyIndex`(O(1)), DB 는 WAL · 색인 · 묶음 트랜잭션(`insertMany/updateMany/deleteMany`), 표지는 isolate 에서 480px.
  CI "scale" 단계(2만 항목 · 2천 묶음): 목록 85ms(두 번째 0ms) · 전체 선택 38ms · 5천 개 이동 0.27초 · 전부 삭제 1.1초
- 취침 타이머: `text_reader_page.dart` `_setSleep/_sleepDue` (분, 또는 -1 = 다음 차례 블록 앞에서 멈춤)
- 화면 꺼도 읽기(안드로이드): `BackgroundReading`(`mediashelf/bg`) → `ReadAloudService`(foreground mediaPlayback + 알림 + PARTIAL_WAKE_LOCK 6시간).
  읽기 · 오디오북 만들기 시작에 start, 멈춤 · 끝 · 실패 · dispose 에 stop
- 오디오북: `lib/services/audiobook.dart`
  - `AudiobookMaker.make`: 부분(장)마다 `plan(문단)` → (글, 음성, 속도) 조각 → `AudioRender.toWav` → `pcmFromWav`(어떤 WAV 든 24kHz 모노 16비트로) →
    `NNN 제목.wav.part` 에 이어 쓰기(조각 사이 0.12초, 문단 사이 0.35초) → 머리 길이 채움 → `.wav` → `encodeM4a` 성공하면 `.m4a`.
    이미 `.m4a/.wav` 가 있으면 건너뜀(이어 만들기). 범위 밖 장은 빈 자리로 넘겨 번호가 늘 같다. 끝에 `제목.m3u8`
  - 글 → WAV: 모델 음성(`st:`/`kk:`)은 `TtsService.renderModel`; Windows 기기 음성은 PowerShell 하나를 띄워 두고 JSON 한 줄씩(`_WinVoices`,
    System.Speech `SetOutputToWaveFile` 24kHz); macOS `say -o --data-format=LEI16@24000`; 안드로이드 `TextToSpeech.synthesizeToFile`(`mediashelf/tts` render);
    iOS `AVSpeechSynthesizer.write` → AVAudioFile(`arari_native`)
  - WAV → M4A: Windows `MediaTranscoder`(PowerShell `.ps1`, AAC 96kbps 모노), 안드로이드 MediaCodec AAC-LC 64kbps + MediaMuxer,
    macOS · iOS AVAudioFile AAC 64kbps (`mediashelf/audio` encodeM4a). 실패하면 WAV 그대로
  - 화면: `lib/ui/viewers/audiobook_dialog.dart` (범위 · 형식 · 위치 → 진행 창, 멈춤, 결과)
- PDF → 텍스트: `lib/services/pdf_text.dart`. 글자 15자 이상 쪽은 PDF 글, 아니면 2600px PNG 로 그려 6쪽씩 묶어 `OcrService.recognizeFiles`.
  `joinPages`: 쪽 위아래 2줄 중 쪽 번호 · 여러 쪽(≥3, ≥30%)에 되풀이되는 짧은 줄(숫자 무시) 제거, 문장부호로 안 끝나면 다음 줄과 이음,
  `chapterRe` 줄(제1장 …)은 따로 → EPUB 목차. PDF 뷰어 읽어주기도 `PdfText.pageText` 를 같이 씀
- 이미지 → PDF: `lib/services/image_pdf.dart` 직접 쓰는 PDF 1.4 (JPEG 는 DCTDecode 로 그대로, 그 밖은 JPEG 로, 쪽 너비 595pt).
  만화는 `ZipPages`(일꾼 isolate) 로 한 쪽씩 읽어 파일로 바로 씀
- 파일 도구: `lib/services/file_tools.dart` — `shrinkZip`(그림만 다시 만들고 나머지는 압축된 채로 옮김, 확장자가 바뀌면 이름 겹침 방지),
  `shrinkImageFile`(형식 유지), `optimizeEpub`(mimetype 맨 앞 무압축, 그림 이름 유지, 글은 deflate 9, 안 줄면 원본 유지),
  `splitPdf/mergePdf`(pdfrx `PdfDocument.createNew` + `pages` + `encodePdf`). 진행 상황은 isolate → SendPort.
  isolate 로 보내는 함수는 `_run` 처럼 따로 만든다(같은 자리의 화면 콜백이 같이 보내지지 않게)
- 화면: `lib/ui/tools/convert_tool_pages.dart`, `archive_tool_pages.dart`(`ToolRunner` 공통, `PdfToTextPage`), `tools_page.dart` 목록
- CI 확인: integration_test 의 `audiobook`(가짜 음성으로 표본 수 정확히 · 이어 만들기 · 실제 기기 음성 · M4A), `pdf text`(쪽 합치기 규칙 ·
  그림으로 만든 스캔 PDF 를 글자 인식), `file tools`(CBZ PNG→JPEG 1600px, EPUB 표지 1200px · mimetype 맨 앞, PDF 4쪽 → 2+2 → 합쳐 4)

## 12. 인물 목소리 · 배경음 (11-04 오후)
- 화자 찾기 `speakers.dart`: 한국어 규칙 + 영어 규칙(`said Holmes` / `Holmes said` / `Mr. Holmes asked` / 앞 지문 `Watson turned … and said,`).
  영어 이름은 호칭 · 앞 보통 낱말(Then …)을 떼고 성으로 묶음(`_cleanEn`). `scan` 도 영어를 셈
- 주고받기 `Speakers.alternate(back)`: back = 앞 문단부터 거꾸로 (화자 | null | ''(대사 없음), 대사만인가).
  가장 가까운 알려진 화자 X 가 짝수 칸 앞이면 X, 홀수 칸이면 그 앞의 다른 화자 Y. 대사 없는 문단 · 화자 모르는 서술 섞인 문단에서 멈춤.
  뷰어 `_whoSays` 는 지문에서 못 찾고 문단이 대사만일 때 앞 10문단을 본다 (`_infoOf` 캐시)
- 자동 배역 `Speakers.autoVoice(name, ranked, pool)`: 말한 횟수 순위 % pool, 순위 밖은 이름 해시. pool = `_castPool`
  (영어 책이면 Kokoro, 아니면 Supertonic, 남녀 번갈아, 서술 · 대사 · 속마음 음성 제외). 사용자가 정한 `speakerVoices` 가 먼저
- 책 분석 `_prepareCast` → static `_analyze`(isolate): 인물 순위, 영어 책(라틴 > 한글×3), 작은따옴표 대사(영어 + ' 여는 수 > " 의 2배)
  — isolate 로 보내는 함수는 static 에서 만든다 (State 가 같이 보내지지 않게)
- 작은따옴표 정규식은 낱말 안 줄임표(don't)를 피함: `(?<![A-Za-z0-9])['‘]…['’](?![A-Za-z])`
- `TtsService.normalize`: ... → …, Mr./Mrs./Dr./Prof. … 풀어 쓰기, `St. 대문자` → Saint, 그 밖 `St.` → Street, `No. 숫자` → Number, e.g./i.e./etc.
  speak · prefetch · renderModel · AudioRender.toWav 모두 같은 함수를 거침 (미리 만들기 키가 맞도록)
- 목소리가 바뀌는 조각 사이 220ms 쉼 (뷰어 읽기)
- 배경음 `ambient.dart`: 22.05kHz 30초 WAV 를 isolate 에서 만들어 `<지원 폴더>/ambient/<종류>_v1.wav` 에 저장, media_kit `PlaylistMode.single` 반복,
  0.8초 커지기 · 0.6초 줄이기. 빗소리 = 분홍 잡음 고역 + 빗방울, 파도 = 갈색 잡음 × 느린 너울, 벽난로 = 갈색 + 타닥 소리. 끝 1초를 처음과 겹쳐 이음새 없앰.
  설정 `ttsBgm`(종류 또는 파일 경로) · `ttsBgmVolume`. 시작/멈춤은 BackgroundReading 옆에서 같이 부름 (오디오북 만들기에는 안 깔림)
- 오디오북 `single`: 장 WAV 를 만든 뒤 44바이트 머리 뒤 데이터를 이어 `책 제목.wav` → M4A, 장 파일은 지움. 이어 만들기는 장 WAV 가 남아 있을 때만
- 오디오북 부분은 문단마다 블록 번호(`AudiobookPart.blocks`)를 가져 내보내기에서도 주고받기 추론이 같다 (`plan(text, block)`)

## 13. WebDAV · HTTPS · QR · AI 화자 (11-04 밤) — PC · 안드로이드 집중
- CI: macos · ios 잡은 태그 · 릴리스 · 수동 실행 때만 (`if:`), package 는 windows · android 만 성공하면 만든다
- 공유 서버 `/dav/` (`share_server.dart` `_dav · davChildren · davResolve`): 읽기 전용, 폴더 = 묶음 트리, 이름 겹치면 ` (id)`.
  파일은 `_send`(Range) 로. 권한은 웹 · OPDS 와 같은 `AccessView`
- HTTPS: `share_cert.dart` (basic_utils 로 RSA 2048 + 자체 서명, isolate 에서), `start(port, https:)` → `bindSecure`. 설정 `shareHttps`
- QR: `qr_flutter` `QrImageView` (웹 · WebDAV 주소)
- WebDAV 받기: `webdav_client.dart`(list · walk · download · parse — `namespaceUri: '*'` 로 접두어 무관, 전체 주소 href 도 처리),
  화면 `webdav_import.dart` → `showImportDialog(files:)`. 설정 `davServers`(비밀번호 빼고)
- AI 화자: `ai_service.dart dialogueSpeakers`, `ai_speakers.dart`(묶음 · 저장 · 이어서), 뷰어 `_aiSpk` 를 `_whoSays` · `_infoOf` 에서 규칙 다음에.
  기기 안 LLM 은 정확도 · 속도 · 용량 때문에 보류(DEV 판단)
