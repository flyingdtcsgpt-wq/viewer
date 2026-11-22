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
| 패키지 이름 | Dart `arariflex`, 조직 `com.arariflex`. 안드로이드 패키지: 전체판 `com.arariflex.full` · 플레이스토어판 `com.arariflex.app`(`tool/patch_android.py`). Windows 실행 파일 `ARARIFlex.exe`, 데이터 `%APPDATA%\ARARIFlex\ARARIFlex`(`tool/patch_windows.py` 가 파일 정보의 회사 · 제품 이름을 정한다). 0.6 까지의 옛 이름 → 아래 17절 |
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
  7. Inno Setup `installer/arariflex.iss` → `dist/ARARIFlex-<ver>-windows-setup.exe` + 포터블 zip
  8. Artifact `ARARIFlex-windows`. 태그 `v*` 면 Releases 에 게시 (태그 생성은 사용자가 직접)
- **screenshots** 잡 (push 마다, 실패해도 전체는 통과)
  - `integration_test/screenshots_test.dart` 를 실제 Windows 앱으로 실행 (`flutter test ... -d windows`)
  - 샘플 만화/소설/그림을 만들어 가져오고 21개 화면 캡처 (PC 1600×960, 휴대폰 412×915, 밝은 테마)
  - 자동 검사(로그에 `CHECK ...`): 숨김 추가 누출 없음, 계정별 종류 제한 누출 없음, 공유 서버 HTTP 권한,
    자연 음성 모델 받기 + 한국어 합성(길이 · 음량), Windows OCR(영어; 서버엔 한국어 인식기 없음)
  - 결과 PNG · WAV 를 **`screenshots` 브랜치**로 강제 push → https://github.com/flyingdtcsgpt-wq/viewer/tree/screenshots
- **android** 잡: 태그 또는 수동 실행(workflow_dispatch) 때만
  - `tool/patch_android.py`: 권한, 앱 이름, MainActivity 의 `arariflex/storage` 채널(모든 파일 접근), 서명
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
installer/arariflex.iss   Inno Setup
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
데이터 폴더(`getApplicationSupportDirectory`, Windows 는 `%APPDATA%\ARARIFlex\ARARIFlex`)에
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
- 삭제는 항상 "목록에서만 제거 / 파일까지 삭제" 를 물어본다 (지워질 파일 위치 · 개수 · 용량 표시. 플레이스토어판은 파일 삭제 한 가지)
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
- 기기 음성: `tool/patch_android.py` 가 MainActivity 에 `arariflex/tts` 채널(TextToSpeech) 추가. 음성 이름은 `and:<name>|<locale>|local/net`
  (flutter_tts 는 Windows 빌드에 nuget 이 필요해서 쓰지 않음). 매니페스트 `<queries>` 에 TTS_SERVICE 필요(Android 11+)
- OCR: google_mlkit_text_recognition + 앱 gradle 에 `text-recognition-korean` 추가. R8 이 안 쓰는 중국어/일본어/데바나가리 클래스를
  찾지 못해 실패 → `proguard-rules.pro` 에 -dontwarn
- "ARARIFlex 로 열기": VIEW 인텐트 필터 + `arariflex/open` 채널(`takeFile`, `opened`). content:// 는 files/opened 로 복사.
  Dart 는 `AppState.requestOpen` → HomePage 의 `_ExternalOpener` 가 라이브러리에 원본 연결로 넣고 연다
- RAR/7Z 는 안드로이드에서 아직 못 엶(7-Zip 실행 파일이 없음) → 뷰어가 안내 문구를 보여 줌
- 모든 파일 접근: `arariflex/storage` 채널 (폴더 추가 때만 요청)
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
- 네이티브: `packages/arari_native` (로컬 플러그인, sharedDarwinSource) — `arariflex/ocr`(Vision, ko-KR/en-US),
  `arariflex/tts`(AVSpeechSynthesizer, iOS 에서 사용; macOS 는 기존 `say`). 음성 이름 `ios:<identifier>|<lang>|local|<name>`
- 안드로이드 OCR 도 플러그인 대신 MainActivity 의 `arariflex/ocr` 채널(ML Kit 한국어)로 통일 (ML Kit iOS pod 는 애플 실리콘 시뮬레이터에서 문제)
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
- 화면 꺼도 읽기(안드로이드): `BackgroundReading`(`arariflex/bg`) → `ReadAloudService`(foreground mediaPlayback + 알림 + PARTIAL_WAKE_LOCK 6시간).
  읽기 · 오디오북 만들기 시작에 start, 멈춤 · 끝 · 실패 · dispose 에 stop
- 오디오북: `lib/services/audiobook.dart`
  - `AudiobookMaker.make`: 부분(장)마다 `plan(문단)` → (글, 음성, 속도) 조각 → `AudioRender.toWav` → `pcmFromWav`(어떤 WAV 든 24kHz 모노 16비트로) →
    `NNN 제목.wav.part` 에 이어 쓰기(조각 사이 0.12초, 문단 사이 0.35초) → 머리 길이 채움 → `.wav` → `encodeM4a` 성공하면 `.m4a`.
    이미 `.m4a/.wav` 가 있으면 건너뜀(이어 만들기). 범위 밖 장은 빈 자리로 넘겨 번호가 늘 같다. 끝에 `제목.m3u8`
  - 글 → WAV: 모델 음성(`st:`/`kk:`)은 `TtsService.renderModel`; Windows 기기 음성은 PowerShell 하나를 띄워 두고 JSON 한 줄씩(`_WinVoices`,
    System.Speech `SetOutputToWaveFile` 24kHz); macOS `say -o --data-format=LEI16@24000`; 안드로이드 `TextToSpeech.synthesizeToFile`(`arariflex/tts` render);
    iOS `AVSpeechSynthesizer.write` → AVAudioFile(`arari_native`)
  - WAV → M4A: Windows `MediaTranscoder`(PowerShell `.ps1`, AAC 96kbps 모노), 안드로이드 MediaCodec AAC-LC 64kbps + MediaMuxer,
    macOS · iOS AVAudioFile AAC 64kbps (`arariflex/audio` encodeM4a). 실패하면 WAV 그대로
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

## 14. 검토 뒤 고친 것 · 더한 것 (11-15)
- **"다 봄" 판정 버그**: 만화 `_progress` 가 화면 첫 쪽 기준이라 두 장 보기 · 짧은 만화가 100% 가 안 됐고, 권 끝에서 1.0 으로 저장해도 dispose 가 다시 낮췄다
  → 지금 화면의 마지막 쪽 기준. 웹툰은 맨 아래 닿으면 마지막 쪽. 소설은 맨 위 문단 기준이라 끝까지 내려도 97% 쯤 → 마지막 문단 아래 끝이 화면 안이면 `_atEnd` = 100%
  (짧은 글은 처음 그린 뒤 한 번 확인), 다 읽은 책을 다시 열어도 앞으로 돌아가지 않으면 100% 유지(`_wasFinished`). 영상은 남은 시간 ≤ 6%(최대 3분)면 100%,
  다 본 영상은 처음부터 재생하고 1분 안에 닫으면 저장하지 않음
- **보던 목록**: `AppState.barelyOpened`(영상 < 1분 · 만화 쪽 < 2 · PDF ≤ 2쪽 · 글 블록 < 10 & < 2%, 단 10% 넘게 봤으면 아님) 은 `isInProgress` 에서 제외(설정 `continueSkipBrief`).
  `_nextUp`: 묶음마다 가장 최근에 다 본 권의 다음 권 { id: 앞 권 본 시각 } — 읽다 만 권이 있는 묶음 · 60일 지난 묶음 제외, 뺀 기록(`cwOff`)이 앞 권 본 시각 이후면 숨김(설정 `continueNextUp`)
- 권 끝 카드에서 한 번 더 넘기면 다음 권(`_turn`/`_go`), 카드 위 밀기 처리. `CoverTile` 에 `corner`(× 자리) · `note`("다음 권")
- 여러 개 읽음/안 읽음: `markFinishedMany` + `db.saveProgressMany` (마지막 본 날 · 열람 기록은 안 건드림)
- 안드로이드: `ScreenAwake.hold/release`(`arariflex/bg` keepScreen → FLAG_KEEP_SCREEN_ON, 뷰어 init/dispose), `volumeKeyBindings`(audioVolumeDown/Up 을 CallbackShortcuts 에 넣으면 눌림이 소비돼 음량이 안 바뀜; TTS 중에는 뺀다)
- **백업 · 복원** `lib/services/backup.dart`: `create`(DB 는 `VACUUM INTO`, 안 되면 체크포인트 뒤 복사 → zip: manifest · settings · library.db · ai_speakers · covers),
  `stage`(zip 확인 뒤 `<지원>/restore_pending/`), `applyPending`(main 에서 설정 · DB 열기 전: 지금 DB → library.before-restore.db, 표지 · 설정 덮어쓰기,
  데이터 폴더가 달라졌으면 `restore_fix.json`), `fixAfterRestore`(DB 연 뒤 표지 경로 고침). 휴대용 모드는 settings.json 을 바로 씀. 복원 뒤 `exit(0)`
- 읽어주기 막대 배경 불투명(휴대폰에서 본문이 비침), 상세 화면에 읽은 정도 · 읽음 표시, 홈 줄(`rootEntries`) 판마다 캐시
- 읽어주기 이어 읽기: `_ttsPlay` 가 끝까지 가면 `ttsContinueNext` 이고 다음 권이 TXT/EPUB 일 때 `TextReaderPage(next, readAloud, autoPlay, sleepAt)` 로 바꿔 넣음.
  넘어갈 때는 `_handover` 로 알림 · 배경음을 끄지 않는다(다음 화면의 start 와 앞 화면 dispose 의 stop 순서가 엇갈려 꺼지지 않게)

## 15. 플레이스토어판 · 사용법 안내 · 제스처 (11-21)
- **판 나누기**: 코드는 하나, `lib/edition.dart` 의 `kStore`(`--dart-define=ARARI_STORE=true`). 플레이스토어판은 만화 · 책 · 영상만, 계정 없이 바로(`_setupStoreLibrary`),
  서재 = 앱 전용 `Android/data/com.arariflex.app/files/ARARIFlex`(저장소 권한 없음). 넣기는 SAF(`saf.dart` · `store_import.dart`) · 공유 받기 · USB.
  켤 때 · 돌아올 때(15초 간격) 조용히 훑어 새 파일을 올리고, 폴더에서 사라진 파일과 빈 묶음은 목록에서 뺀다(`scanFolders` 의 kStore 갈래, `_dropEmptySeries`).
  광고는 `ads.dart`(배너 + 앱 열기, 동의 창). 자세한 것은 `docs/store/PLAY_RELEASE.md`
- **플레이스토어판 빌드에서 빼는 것**: ML Kit(MainActivity 의 OCR 부분을 `patch_android.py --store` 가 들어냄), ONNX 런타임(`tool/store_stubs/flutter_onnxruntime` 빈 껍데기를
  `pubspec_overrides.yaml` 로 바꿔 끼움 — 플러그인이 켜질 때 네이티브를 바로 불러서 `.so` 만 빼면 죽는다). CI 가 APK 에 `libonnxruntime · libmlkit` 이 있으면 실패 처리
- **릴리스가 켜자마자 죽던 문제**: 광고 SDK 가 끌고 온 WorkManager 의 `WorkDatabase_Impl` 생성자를 R8 이 지움 → proguard keep. 두 판 모두 해당.
  CI `android-smoke` 가 두 판의 릴리스 APK 를 에뮬레이터에서 켜 30초 버티는지 본다 (디버그 빌드로 도는 화면 캡처 테스트는 R8 문제를 못 잡는다)
- **Windows ONNX 런타임**: 플러그인이 GitHub 릴리스에서 받는데 그 주소가 404 → CI 가 NuGet `Microsoft.ML.OnnxRuntime` 에서 받아 플러그인이 찾는 폴더 구조로 풀어 둔다(같은 1.28 계열)
- **만화 뷰어 제스처**: 탭 · 밀기 · 두 번 탭을 `Listener` 로 직접 판단(GestureDetector 의 인식기가 InteractiveViewer 와 같은 손가락을 두고 다퉈 두 손가락 확대가 씹히던 문제).
  두 손가락이 닿은 손짓은 확대만, 확대 중 한 번 탭은 무시, 두 번 탭 = 그 자리 확대 ↔ 원래 크기. 터치 기기의 가로/높이 맞춤은 안쪽 스크롤 없이 InteractiveViewer 가 이동을 맡는다(`constrained: false`).
  마우스 휠은 InteractiveViewer 가 못 건드리게(`scaleFactor: 1e9`) 하고 직접: 휠 = 쪽 넘김, Ctrl+휠 = `_wheelZoom`, 확대 중 휠 = `_moveZoomed` (전에는 휠을 위로 굴리면 이전 쪽 대신 확대가 됐다)
- **권 끝**: `open_item.dart askNextVolume`(창) · `showViewerToast`("마지막 권입니다"). 세 뷰어의 "끝에서 한 번 더" 가 모두 이것을 부른다
- **사용법 안내** `ui/guide.dart`: `GuideAtStart` 로 홈을 감싸 처음 뜰 때 표시, `Settings.guideHidden`. 화면 캡처 테스트는 `guideHidden = true` 로 끄고 따로 띄워 찍는다.
  뷰어 도움말 `showViewerHelp(keys, touch:)` — 터치 기기는 손가락 조작을 먼저
- 영상: `MaterialVideoControlsTheme` 으로 좌우 두 번 탭 10초 이동(기본값은 꺼짐), 위쪽 단추가 넘치지 않게 정보 · 조작법은 ⋮ 안으로
- **눈 보호 · 어두운 화면** (`viewer_chrome.dart`): `EyeCare` 가 뷰어 본문을 `ColorFilter.matrix` 로 감싼다(초록 · 파랑을 줄이고 전체를 어둡게 — 검은색은 그대로라 색 막을 덮는 방식처럼 뿌옇지 않다).
  설정 `eyeCare · eyeCareWarm · eyeCareDim` 은 책 · 만화 · PDF 공통. PDF 어두운 화면은 `invertKeepHue`(밝기만 뒤집고 색상 유지) + 바탕색을 미리 밝게.
  켜고 끌 때 안쪽 뷰어가 다시 만들어지지 않게 `StableFilter`(GlobalKey 로 감싼 자식)를 쓴다. 책은 `Settings.toggleReaderDark`(밝은 쪽은 마지막 테마 기억), 위쪽 줄에 줄 간격 − / +
- **검토 뒤 고친 것 (11-21)**
  - 가져오기: 진행 창이 일보다 늦게 떠서 영영 안 닫히던 경우 → 창이 스스로 닫힌다(`_ProgressDialog`, 위에 다른 화면이 있어도 `removeRoute`).
    "옮기기"는 다 넘어온 것(크기)을 확인한 뒤에만 원본을 지우고, 이름 · 크기가 같아 건너뛴 파일의 원본은 지우지 않는다. 크기를 모르는 파일은 같은 파일로 보지 않는다.
    끝나면 `rescanWhenFree`(돌던 훑기가 끝난 뒤 다시 훑기)로 서재에 올린다. 폴더 권한은 `releaseFolder` 로 돌려주고, `.part` 조각은 켤 때 치운다
  - 공유: 최근 앱 목록에서 다시 열 때 예전 공유가 되살아나지 않게(`FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY`), 글자 · 링크만 공유되면 알려 줌(`takeShared` null = 공유 아님 / 빈 목록 = 파일 없음),
    확장자 없는 이름은 MIME 으로 붙임, 원본 지우기는 별도 스레드
  - 광고: `static final` 초기값은 처음 읽을 때 정해져 "켠 지 몇 초 안" 조건이 늘 참이던 것 → `start()` 에서 시각을 잡는다. `Ads.canInterrupt`(홈에 아무것도 안 떠 있을 때만)로
    뷰어 · 안내 창 위에는 전면 광고를 띄우지 않는다. 동의 창에 시간 제한을 두지 않는다. 배너는 큰 적응형 대신 작은 띠(높이 50~90)
  - 권 끝 창: → ← 는 뷰어의 읽는 방향을 따르고(`rightIsNext`), ↑ ↓ PgUp PgDn 도 넘기기. Space · Enter 는 초점 있는 단추
  - 만화: 원래 크기로 돌아올 때 쪽 밖으로 나가지 않게(`_Measure` 로 잰 쪽 크기), 원본 크기 맞춤에서는 두 번 탭 확대를 하지 않음(탭이 먹통이 되던 문제),
    맞춤 · 보기 방식을 바꾸면 확대 · 이동 초기화, 살짝(1.08배 미만) 확대된 채 남으면 원래 크기로, 밀던 화면을 멈추는 탭은 쪽 넘김으로 보지 않음, 쪽을 넘긴 뒤 0.4초는 관성으로 새 쪽이 밀리지 않게
  - 읽어주기로 다음 권에 넘어갈 때 위에 뜬 창을 먼저 닫음
  - 플레이스토어판 휴대폰 홈: 위쪽 줄이 넘쳐 검색 칸이 잘리던 것 → 좁으면 돋보기 단추
- **TXT 목차 규칙** `text_document.dart isChapterTitle`(전에는 `chapterRe`): `[0-9]+\s*[장화]\b` 의 `\b` 가 한글에는 맞지 않아(영문 · 숫자 기준 경계) "1화" · "12장" 이 목차에 안 잡혔다.
  → 뒤에 글자가 바로 붙지 않는지를 직접 보고(`(?![0-9A-Za-z가-힣])`), 꾸밈 기호를 떼고, 문장으로 끝나는 줄은 빼고, 모양을 넓혔다(N부 · N권 · N편 · #N · Ep. · Part · 후기 · 서문 · 第N章 …). `test/chapter_title_test.dart`
- **만화 스크롤(웹툰) 보기 다시 씀**: 전에는 `ListView` + 못 읽은 쪽은 1×1 그림(정사각 자리) → 그림이 불려 오거나 메모리에서 내려갈 때마다 쪽 높이가 바뀌어 보던 자리가 튀고,
  이어 보기는 높이를 모르는 채 `ensureVisible` 해서 엉뚱한 곳(거의 맨 위)에 떨어졌다. 또 `_initialDone` 처리가 화면을 다시 그릴 때(탭) 한 번 더 돌아 지금 쪽 맨 위로 튀었다.
  → `CustomScrollView(center:)` 로 시작 쪽(`_vAnchor`)을 기준으로 위 · 아래에 이어 붙임(`_vRestart`), 쪽 비율을 기억(`_aspect`, `_Measure`)해 자리 고정,
  지금 쪽은 화면이 그려진 뒤에 계산(`_trackVertical`)해 저장. 아래 탐색 줄(썸네일)을 스크롤 보기에서도 보여 주고 누르면 그 쪽에서 다시 시작. 위로 넘기기는 `minScrollExtent` 까지

## 16. 한 손 보기 · 화면 점검에서 고친 것 (11-21 밤)
- **누를 때 다음 쪽**: `Settings.tapHand`(0 읽는 방향대로 · 1 오른손잡이 · 2 왼손잡이) → `tapLeftIsNext`. 만화 `_tapSide`, 책 `onTapUp`, PDF `onGeneralTap` 이 모두 이 값을 본다. 밀어 넘기기는 손잡이와 무관(읽는 방향)
- **전체화면** `viewer_chrome.dart setViewerFullscreen`: PC 는 `media_kit_video` 의 `defaultEnterNativeFullscreen`(창을 화면 전체로), 터치 기기는 `immersiveSticky`.
  PDF 는 화면을 눌러 메뉴를 되살릴 길이 없었다 → `FullscreenExitBtn`(오른쪽 위) + `PopScope`(뒤로 = 전체화면 끝내기) + 터치 기기는 `onGeneralTap` 으로 가운데 = 메뉴, 가장자리 = 쪽 넘김.
  책은 글자 선택 모드일 때만 끝내기 단추를 보인다(그때는 탭을 `SelectionArea` 가 가져간다)
- **PDF 배율 표시**: `PdfViewerController` 는 `ValueListenable<Matrix4>` → `ListenableBuilder` 로 감싸 두 손가락 · 휠 확대도 따라간다 (`value` 는 붙기 전에 읽으면 죽으므로 `isReady` 를 본다)
- **만화 스크롤 보기**: 읽는 방향(오른쪽→왼쪽)을 따지지 않는다(`_rtl`). 듣지 않는 것(맞춤 · 배율 · 커버 · 넘김효과 · 눌러 넘기기 · 방향키 설정)은 도구줄 · ⚙ 에서 숨기고, 조작법도 스크롤용을 따로 보여 준다.
  "화면 폭에 꽉 채우기" 는 `viewerFit` 을 덮어쓰지 않게 `scrollWide` 로 따로 두고, 화면이 900 보다 넓을 때만 보인다
- **높이 맞춤에서 밀어 넘기기** `_swipeTurns`: 쪽이 화면보다 넓지 않거나, 손가락을 댈 때 이미 그쪽 끝(`_downTx`)이면 쪽 넘김. 원본 크기 · 확대 중은 끌기 = 움직이기 그대로
- **가로 태블릿** `browser.dart tapEntry`: `desktop && !touchDevice` 일 때만 "한 번 = 고르기, 두 번 = 열기". 터치는 넓은 화면이어도 한 번 = 열기, 길게 = 고르기(표 · 카드 목록에도 `onLong`), 두 번 탭 인식기를 달지 않아 눌림이 기다리지 않는다.
  `toggleSelect` 가 `focusedKey` 도 옮겨 아래 상세 칸이 방금 고른 것을 보여 준다. 위 작업 줄에 읽음 표시, …(더보기)에 다시 스캔 · 새 묶음 · 중복/누락
- **EPUB 원본 스타일 ↔ 읽기 최적화**: 원본 스타일은 자리를 `e장:비율` 로 저장(`item.position`), 읽기 최적화는 문단 번호. 예전에는 둘 다 숫자만 써서 바꾸면 엉뚱한 곳이 열렸다.
  `TextDocument.spineStarts`(장 파일마다 시작 문단) + `blockOfSpine` · `spineOfBlock` 으로 서로 바꾼다 (`test/epub_position_test.dart`)
- **읽음 표시(하나)**: `markFinished` 가 `saveProgress` 를 불러 마지막으로 본 날짜와 열람 기록이 생기던 것 → `markFinishedMany` 와 같은 길로
- **뷰어 설정 초기화** `resetViewer({all})`: 만화 ⚙ 는 그 패널의 것만, 설정 › 뷰어는 그 화면의 것 전부(눌러 넘기기 · 손잡이 · 눈 보호 · 그림 보기 · 영상 · 화면 켜 두기 등)
- **비밀번호 초기화 파일(안드로이드)**: 앱 안쪽 폴더는 사용자가 못 보므로 `getExternalStorageDirectory()`(Android/data/…/files)에서 찾는다
- 그 밖: RAR · 7Z 를 휴대폰에서 누르면 안내 창(`openItem`), 가져오기 창 처음 값이 설정 › 파일 처리를 따름, 슬라이드쇼 간격 설정 + 그동안 화면 켜 두기, 정렬 · 하위 묶음 포함은 듣지 않는 화면에서 흐리게,
  안내서 `_storeTopics(wide)` · `_fullTopics(touch, wide)`(가로 태블릿용 문구), 손가락 기기에서는 풍선말의 단축키 표시를 뺀다(`ToolBtn._keyHint`), 플레이스토어판 왼쪽 목록에서 "그림" 숨김, 파일 도구의 같은 화면 두 칸을 하나로
- **확인 못 한 것**: PC 전체화면(창 넓히기)과 실제 손가락 조작(밀기 · 두 손가락)은 CI 에서 눌러 볼 수 없다. PDF 의 눌러 넘기기는 화면 캡처 테스트가 처리기를 직접 불러 확인한다(`CHECK pdf`)

## 17. 이름 정리 (11-21 밤): 옛 이름을 모두 ARARIFlex 로
- 처음 만들 때의 이름이 패키지 · 폴더 · 채널에 남아 사용자에게도 보였다(안드로이드 `Android/data/…` 폴더, Windows 실행 파일 · `%APPDATA%` 폴더). 전부 바꿨다:
  Dart 패키지 `arariflex`, `flutter create --org com.arariflex --project-name arariflex`, 채널 `arariflex/…`, OPDS id `urn:arariflex:…`, 설치 스크립트 `installer/arariflex.iss`
- **안드로이드 전체판** 패키지 `com.arariflex.full`(`patch_android.py FULL_ID`. 코드 자리 namespace 는 `com.arariflex.arariflex`). 패키지가 다르면 다른 앱이라 예전 것(0.6 이하)을 덮어 깔지 않고 따로 깔린다.
  앱 안쪽 데이터는 건너 옮길 수 없다 → 예전 앱에서 설정 › 정보 › 백업, 새 앱에서 복원, 그 뒤 예전 앱 삭제. 플레이스토어판(`com.arariflex.app`)은 그대로
- **Windows**: `patch_windows.py` 가 실행 파일 이름(`BINARY_NAME` → `ARARIFlex.exe`)과 파일 정보(CompanyName · ProductName = ARARIFlex)를 정한다. path_provider 는 이 둘로 데이터 폴더를 만든다 → `%APPDATA%\ARARIFlex\ARARIFlex`.
  예전 폴더(`%APPDATA%\com.mediashelf\ARARIFlex`, 더 예전 `…\media_shelf`)는 `LegacyData.migrate`(main 에서 설정 · DB 를 열기 전)가 통째로 옮긴다. 새 자리에 이미 서재가 있으면 건드리지 않는다(`test/legacy_data_test.dart`).
  설치 프로그램은 AppId 가 같아 그대로 덮어 깔리고, 예전 실행 파일 `media_shelf.exe` 는 `[InstallDelete]` 로 지운다
- **그대로 둔 것 하나**: 서명 키의 별칭(`ANDROID_KEY_ALIAS` = mediashelf). 키 파일 안에 든 키의 이름표라 사용자에게 보이지 않고, 바꾸려면 키 파일과 Secrets 를 새로 만들어야 한다(서명 자체는 달라지지 않는다)
- 고칠 때 볼 곳: 생성된 틀에 기대는 치환은 못 찾으면 빌드를 멈추게 했다(`sub1`, `assert`) — flutter 가 틀을 바꾸면 조용히 옛 이름으로 돌아가지 않게

## 18. 플레이스토어판 폴더 연결 (11-22): 내 폴더 · SD 카드를 복사 없이
- **왜**: 앱 전용 폴더(`Android/data/…`)는 기기의 파일 앱에서 보이지 않고 앱을 지우면 함께 지워진다. "모든 파일 접근" 은 뷰어 앱에 허용되지 않는다 →
  시스템 폴더 선택 창(`ACTION_OPEN_DOCUMENT_TREE`)으로 고른 폴더의 지속 권한을 쥐고 그 자리에서 읽는다
- **경로는 그대로 실제 경로**: 고른 폴더의 문서 이름 `primary:Comics` · `1234-5678:만화` 에서 `/storage/emulated/0/Comics` · `/storage/1234-5678/만화` 를 얻어(`treeInfo`) DB · 목록에는 이 경로를 쓴다
  → 제목 · 확장자 · 시리즈 묶기 · 폴더별 보기가 손대지 않고 동작. 기기 저장공간 · SD · USB(`com.android.externalstorage.documents`)만 연결할 수 있다
- **읽기**: 그 경로를 `File` 로 열 수는 없다(권한 없음). `Linked.ref(path)` → 네이티브 `openFd`(tree + 상대 경로 → 문서 주소 → `ParcelFileDescriptor.detachFd`) → `FileRef(path, fd, size)`.
  `fd_file.dart`: `FdReader`(FFI `pread64`), archive 용 `ReaderHandle`(`InputFileStream.withFileHandle`), `FileRef.input() · readAllSync() · reader()`. isolate 로 넘길 수 있다.
  **파일 번호는 만든 쪽이 한 번만 닫는다**(`Linked.use` 또는 `ZipPages.close` · PDF 뷰어 dispose). `/proc/self/fd/N` 으로 다시 여는 꼼수는 권한에 걸려 안 된다
  - 표지 · 쪽수 · EPUB 정보(`cover_service.dart`), 만화 쪽(`zip_pages.dart`), TXT · EPUB(`text_document.dart`): `FileRef`
  - PDF: 표지는 `PdfDocument.openCustom`, 뷰어는 `PdfViewer.custom`(읽기 함수가 요청한 만큼 꼭 채워야 한다 → `FdReader.readAt` 이 끝까지 읽는다). 뷰어를 닫고 3초 뒤 파일 번호를 닫는다
  - 영상: `Media(content://…)`(media_kit 이 직접 연다), 썸네일은 `srcFileUri: true`
- **훑기** `_scanLinked`: `scanTree`(ok = 끝까지 다 봤는가) → 새 파일 등록, 사라진 파일은 **ok 일 때만** 목록에서 뺀다. 폴더를 읽을 수 없으면(`treeInfo.alive` 가 false: SD 카드를 뺌 · 권한 풀림)
  `offlineLinked` 에 넣고 아무것도 빼지 않는다 — 읽던 위치를 잃지 않게. `checkMissing` 은 연결한 폴더의 파일을 보지 않는다(경로로는 늘 "없음" 으로 나온다)
- **삭제**: `Linked.delete`(`DocumentsContract.deleteDocument`). 복사본이 아니라 실제 파일이므로 삭제 창에 따로 경고
- 연결 목록은 `Settings.linkedFolders`(tree · path · name), 실행 중에는 `Linked.folders`. 새 폴더가 예전 연결 폴더를 품으면 합친다
- **확인한 것 / 못 한 것**: 파일 번호로 읽기(통째 · 압축 · PDF)는 에뮬레이터 점검 `CHECK fd`, 경로 계산 · 압축 다리는 `test/linked_test.dart`.
  폴더 선택 창 · 지속 권한 · SD 카드 · 영상 재생은 자동으로 못 본다 → 실제 기기에서 확인

## 19. 백업: 암호 · 자동 · 플레이스토어판 (11-22)
- `Backup.create(password:)` → `ZipFileEncoder(password:)`(AES, 안의 파일 전부). `Backup.isLocked` 는 zip 첫 머리표의 암호화 표시(6번째 바이트의 1)를 본다.
  `stage(zip, password:)`: 암호가 걸렸는데 없으면 "암호를 넣어 주세요", 풀다 실패하거나 DB 머리표가 아니면 "암호가 맞지 않습니다" (`test/backup_password_test.dart`)
- 암호는 `Settings.backupPassword`(이 기기에만. `exportForBackup` 이 백업에 넣을 설정에서 뺀다) — 자동 백업에도 쓴다
- `Backup.auto`: 7일에 한 번 표지 없이, `ARARIFlex-자동백업-날짜.zip`, 자기가 만든 것 중 최근 4개만. main 에서 화면을 띄우고 20초 뒤.
  기본값: 플레이스토어판 켬 · 전체판 끔(계정 · API 키가 들어가므로)
- 저장 위치 `Backup.defaultDir`: 안드로이드 `Download/ARARIFlex 백업`. 안드로이드 11+ 는 권한 없이도 Download 아래에 자기 파일을 만들 수 있다(다시 깐 뒤에는 그 파일의 주인이 아니라 경로로 못 읽는다 → 복원은 파일 선택 창으로).
  못 쓰면 수동 백업은 "저장 위치 고르기" 창으로 넘어간다
- **다시 깐 뒤 연결한 폴더**: 설정은 복원되지만 폴더 권한은 사라진다 → `offlineLinked`. 같은 폴더를 다시 고르면 `linkFolder` 가 권한만 되살리고 다시 훑는다(경로가 같아 읽던 위치가 그대로)
- 다음에 할 것(실기기에서 폴더 연결 확인 뒤): 앱 폴더의 파일을 내 폴더로 옮기기(파일까지 백업), 플레이스토어판 그림(가족 사진), NAS

## 20. NAS 바로 보기 (11-22): 받지 않고 그 자리에서 — 세 판 모두
- **경로**: NAS 파일은 서재에 풀어 쓴 주소 그대로 넣는다 `http://192.168.0.10:5005/home/만화/코난 01.cbz` (`Remote.isRemote`). 요청할 때만 `Remote.uri` 로 주소 꼴로 바꾼다.
  계정은 주소 앞부분(`originOf`)마다 `Settings.nasAccounts`, 비밀번호는 `nasPw_<origin>`(이 기기에만, `exportForBackup` 에서 뺌). 연결 폴더는 `Settings.nasFolders` → `Remote.folders`
- **읽기** (`services/remote.dart`)
  - 만화 ZIP: `RemoteZip` — 끝 64KB 에서 목차 끝(EOCD, ZIP64 포함)을 찾고 목차를 읽은 뒤, 쪽마다 그 파일의 머리+내용만 Range 로 받아 푼다(0 = 그대로, 8 = `ZLibDecoder(raw: true)`).
    이름은 UTF-8 표시 → UTF-8, 없으면 UTF-8 시도 후 CP949. `ZipPages.open` 이 NAS 면 `_RemotePages`, 서버가 Range 를 무시하면(200) `RangeUnsupported` → 통째로 받아 보통 길로
  - PDF: `RemoteReader`(256KB 덩어리, 48개 기억) → `PdfViewer.custom` · `PdfDocument.openCustom`. pdfrx 는 읽기 함수가 비동기여도 된다(PDFium 쪽 스레드가 기다린다)
  - 영상: `Media(주소, httpHeaders: Basic)`, 자체 서명 인증서면 mpv `tls-verify=no`. 영상 표지는 아직 없음
  - TXT · EPUB · RAR · 그림 · 다른 앱으로 열기: `Remote.cache`(임시 폴더 nas_cache, 2GB 넘으면 오래된 것부터 지움) → `Linked.ref` · `Linked.localCopy`
  - 그림 보기: `RemoteImage`(ImageProvider)
- 연결은 주소마다 `HttpClient` 하나를 돌려 쓴다(keep-alive, 4개까지 동시). 401 은 "NAS 아이디 · 비밀번호" 오류로
- **훑기** `_scanNas`: `WebDavClient.walk`(폴더마다 PROPFIND Depth 1) → 새 파일 등록(표지: ZIP 첫 그림 · PDF 첫 쪽 · EPUB 은 받아서), 사라진 파일은 목록에서 뺀다.
  연결할 수 없으면 `offlineNas` 에 넣고 아무것도 빼지 않는다. `rescanAll` 은 10분에 한 번만 NAS 를 훑는다(플레이스토어판은 돌아올 때마다 훑으므로), `rescanNas` 는 바로
- **안전장치**: `Linked.external`(연결 폴더 · NAS)인 파일은 `checkMissing` · OS 숨김 속성 · 탐색기 열기에서 뺀다. 지우기는 WebDAV DELETE(읽기 전용 서버면 실패 → 목록에 남김).
  공유 서버는 NAS 항목을 내보내지 않는다(이 기기에 파일이 없고, 서로 물고 도는 것을 막음). 파일 도구도 NAS 항목은 뺀다. 폴더별 보기는 NAS 주소면 `/` 로 자른다(Windows)
- **점검**: `test/remote_test.dart`(작은 Range 서버로 ZIP 목차 · 쪽만 받기 · 덩어리 읽기 · 로그인), 통합 `CHECK nas`(우리 공유 서버를 NAS 로 연결 → 훑기 · 표지 · 만화 쪽 · PDF · TXT · 뷰어 · 끊기)
- **권한**: 인터넷만. 안드로이드 17(API 37) 을 목표로 올릴 때 집 안 주소 접속에 `ACCESS_LOCAL_NETWORK`(근처 기기 묶음, 실행 중 허용) 를 처음 연결할 때 물어야 한다

