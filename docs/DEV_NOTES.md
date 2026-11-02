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
- Android: 자연 음성(ONNX)·OCR(ML Kit) 미구현 → 진행 중 (8장)
- PDF 나누기/합치기, EPUB 편집기, WebDAV, 휴대폰 연동(QR), 이미지 해상도 변경 도구
- 공유 서버는 HTTP(암호화 없음) — 같은 Wi-Fi 전용

## 7. 작업 이력 요약
- 11-01: v0.2 첫 구조(뷰어 4종, CI), 묶음 트리, 로그인·사용자별 기록·관리자 권한·숨김, 넷플릭스풍 디자인, Android 모든 파일 접근, 서명
- 11-02 오전: v0.3 BookManager 풍 PC 화면, 만화/텍스트/PDF 뷰어 개편, 설정 창, 메타데이터 통합 검색 · 일괄 편집, 파일 도구,
  공유 서버(Web/OPDS), TTS, RAR/7Z(동봉 7-Zip), 영상 자막/음성 트랙, EPUB 원본 스타일(WebView2)
- v0.4: 표지 편집기, TXT→EPUB. 이름 변경 → ARARIFlex, 가져오기 창(목록 선택 · 중복 · 복사/이동 · 묶기 · 숨김), 비밀번호 초기화
- UI 자동 캡처 도입 후 개선: 작업 줄 정리, 만든 표지, 카드 크기, 뷰어 색, 계정별 폴더/종류 권한, 휴대폰 탭
- v0.5: 자연 음성(Supertonic), PDF/그림/만화 읽어주기(OCR), 인물별 목소리, 공유 서버 계정 권한, 리뷰 2회분 버그 수정

## 8. Android 작업 메모 (진행 중)
(아래에 계속 추가)
