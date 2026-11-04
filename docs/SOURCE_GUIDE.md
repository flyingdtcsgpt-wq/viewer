# ARARIFlex 소스 설명서

파일마다 하는 일과 중요한 클래스 · 함수를 적었습니다. 고칠 곳을 찾을 때 이 표부터 보세요.
전체 약 2만 줄 (Dart 1만 8천 줄 + 빌드 스크립트 · Swift · 문서).

> 큰 그림(데이터 구조, 가져오기, 권한, 음성 흐름)은 `DEV_NOTES.md`, 사용법은 `MANUAL.md`, 바뀐 기록은 `CHANGELOG.md`.

---

## 1. 시작과 상태

| 파일 | 줄 | 하는 일 |
|---|---|---|
| `lib/main.dart` | 138 | 앱 시작. 순서: `Portable.init`(휴대용 폴더) → `Settings.load` → `LibraryDb.open` → `CoverService.init` → `AppState.load` → `runApp`. iOS 는 켤 때 · 돌아올 때 다시 스캔, 안드로이드는 "ARARIFlex 로 열기" 채널 연결. `appTheme()`(어두운/밝은 테마) |
| `lib/app_state.dart` | 1791 | ★ 앱의 중심(ChangeNotifier). 아래 표 참고 |
| `lib/version.dart` | 2 | `appVersion` (pubspec.yaml 의 version 과 맞출 것) |

### `AppState` 안의 영역
| 영역 | 주요 멤버 |
|---|---|
| 목록 · 탐색 | `entries`, `visible`, `allItems`, `rootEntries`, `featured`, `enterSeries`, `goUp/goBack/goForward`, `setFilter`, `setQuery`, `setSort`, `setCollection`, `showLanding` |
| 묶음(시리즈) | `LibraryTree`(보이는 항목으로 만든 색인), `createSeries`, `moveItems`, `groupSelected`, `autoGroup`(파일명으로 시리즈), `_nestSpinOffs`(외전을 본편 아래로) |
| 사용자 | `users`, `user`, `createFirstAdmin`, `login`, `logout`, `addUser`, `updateUser`, `deleteUser`, `resetPasswords`(RESET_PASSWORD.txt) |
| 접근 권한 | `denied` 키 `s:`묶음 · `i:`항목 · `f:`폴더 · `k:`종류. `canSeeItem/canSeeSeries`, `canAccessItem`, `_deniedByScope`, `kindAllowed`, `visibleLibraryFolders`, `accessFor(user)` → `AccessView`(공유 서버용) |
| 숨김 | `hasHiddenPassword`, `trySearchUnlock`(검색창에 비밀번호), `lockHidden`, `setHidden`, `_syncOsHidden`(Windows attrib / macOS chflags) |
| 가져오기 | `previewFolder/previewFiles` → `ImportCandidate`(새 항목/등록됨/중복 의심), `importCandidates(picked, ImportOptions)`, `_addFile`(복사·이동 실패 시 되돌림), `_quickHash`(크기+앞 256KB SHA-1), `folderOverlap`, `registerWatchFolder`, `scanFolders`, `rescanAll` |
| 기타 | `requestOpen/itemForExternal`(다른 앱에서 연 파일), `_setupIosLibrary`(iOS Documents 라이브러리, 경로 이전), `share`(공유 서버), `saveProgress`, `beginView`, `historyList`, `applyMetadata`, `organize`, `removeMany`, `checkMissing`, `findDuplicates` |

## 2. 데이터 · 모델

| 파일 | 하는 일 |
|---|---|
| `lib/db/library_db.dart` | SQLite. 표: items, series, users, user_progress, history, denied (DB 버전 5). Windows/맥/리눅스는 `sqflite_common_ffi` |
| `lib/models/media_item.dart` | `MediaItem`(경로 · 종류 · 제목 · 권수 · 표지 · 진행률 · 숨김 …), `MediaKind`(book/comic/image/video), 확장자 목록, `BookMetadata` |
| `lib/models/series.dart` | `Series`(트리: parentId, 전체 권수, `SeriesStatus` 연재중/완결/휴재) |
| `lib/models/entry.dart` | 격자 한 칸 `SeriesEntry/ItemEntry`, 묶음 요약 `SeriesStats`(권수 · 표지 · 종류별 개수) |
| `lib/services/settings.dart` | 모든 설정 값(getter/setter). 저장소는 `Prefs`(보통 SharedPreferences, 휴대용이면 JSON 파일). 책별 인물 목소리 `speakerVoices(bookId)` |
| `lib/services/portable.dart` | 휴대용 모드: `Portable.init`(앱 옆 arariflex_data → PathProvider 교체), `makePortable`, `Prefs` 추상화(`_SharedPrefs`, `_FilePrefs`) |
| `lib/services/auth.dart` | `AppUser`, `PasswordHash`(PBKDF2-SHA256 2만 번), `HistoryRecord` |

## 3. 파일 처리 서비스

| 파일 | 하는 일 |
|---|---|
| `cover_service.dart` | 표지 만들기 · 캐시: EPUB 표지, PDF 첫 쪽, 압축 첫 그림, 영상 썸네일. EPUB 정보 읽기 |
| `organizer.dart` | 정리 규칙(`{kind}/{author}/{title}`) 경로, 복사/이동 `apply`, `moveFile`(다른 드라이브면 복사 후 삭제, 실패 시 되돌림) |
| `series_parser.dart` | 파일명 → 제목 · 권수 ("01권", "제3권", "v05", "S02E03", "10.5권"), 완결 표시, 외전 판별 `isSpinOffOf` |
| `archive_tools.dart` | 압축 정리(평탄화), 안 파일 이름 바꾸기, 표지 넣기, 정크 파일 판별, 자연 정렬 |
| `ext_archive.dart` | RAR/7Z: 동봉 7-Zip(tools/7zip/7z.exe) 또는 tar 로 목록 · 한 쪽씩 꺼내기 `PageLoader`(꿀뷰 방식) |
| `text_document.dart` | TXT(인코딩 판별: UTF-8/16, CP949) · EPUB(HTML) → 문단 블록 + 목차(장 제목 정규식) |
| `epub_book.dart` | EPUB 구조 읽기, 원본 스타일 보기용 로컬 HTTP 서버 |
| `epub_writer.dart` | TXT → EPUB 만들기 (장 자동 나눔, 표지) |
| `metadata_service.dart` | 책 정보 검색: 카카오 · 네이버 · Google Books · Open Library |
| `ai_service.dart` | Claude API (선택, 키 필요): 뜻풀이, 원제 찾기, 묶음 정보 |
| `share_server.dart` | 같은 Wi-Fi 공유: 웹 페이지 · OPDS · 파일 · 표지. 기본 인증, 접속자별 `AccessView`, 로그인 캐시(비밀번호 해시가 느려서) |
| `storage_permission.dart` | 안드로이드 모든 파일 접근 요청 (네이티브 채널 `mediashelf/storage`), `hasAllFilesAccess` |
| `zip_pages.dart` | 만화 압축을 일꾼 isolate 에서 한 번만 열어 두고 쪽을 하나씩 꺼냄 (`writeContent` 로 메모리 바로 비움) |
| `file_tools.dart` | 그림 줄이기(`shrinkZip/shrinkImageFile/shrinkBytes`), `optimizeEpub`, PDF `splitPdf/mergePdf/parseRanges/everyN` |
| `image_pdf.dart` | 그림 → PDF 직접 쓰기 (JPEG 그대로 DCTDecode, 나머지는 JPEG 로), `jpegInfo` |
| `pdf_text.dart` | PDF → 글: 쪽 글 / 스캔 쪽은 그려서 글자 인식(6쪽씩), `joinPages`(쪽 번호 · 머리글 빼기, 줄 잇기, 장 제목 유지) |

## 4. 소리 내어 읽기 · 글자 인식

| 파일 | 하는 일 |
|---|---|
| `tts_service.dart` | ★ 읽기 진입점 `speak(text, voice, rate)`. 음성 이름 앞글자로 엔진 고름: `st:` Supertonic, `kk:` Kokoro, `and:` 안드로이드 기기, `ios:` iOS 기기, 그 밖은 Windows(PowerShell System.Speech) / macOS(`say`). 미리 만들기 `prefetch`, 멈춤 세대 `_gen/_epoch`, `failed`(멈춤과 실패 구분), WAV 재생은 media_kit |
| `natural_tts.dart` | Supertonic 3 (한국어 등 31개 언어, 44.1kHz): 모델 받기/가져오기, 한글 자모 분해 전처리, 4개 ONNX(길이 · 텍스트 · 8단계 잡음 제거 · vocoder), `chunkText`, `wavBytes` |
| `kokoro_tts.dart` | 영어 원서용 Kokoro-82M (24kHz): eSpeak NG 로 발음 기호 → 어휘 178개 → ONNX. voices-v1.0.bin(npz) 읽기. 맨 아래 `kokoroVocab` |
| `speakers.dart` | 대사 화자 찾기(규칙): "…" 민호가 속삭였다 / 민호가 말했다. "…". `speakerAt`, `scan`(등장인물 목록) |
| `ocr_service.dart` | 글자 인식 진입점 `recognizeFiles/recognizeBytes`. Windows: PaddleOCR(있으면) → Windows OCR(PowerShell+WinRT). 안드로이드(ML Kit) · 애플(Vision): 채널 `mediashelf/ocr`. 긴 그림은 2600px 조각(80px 겹침). `tidy`(줄 잇기) |
| `paddle_ocr.dart` | PaddleOCR PP-OCRv5 한국어: 모델 목록에서 골라 받기, DB 검출 → 상자 → 높이 48 인식 → CTC 디코딩 → 줄 합치기 |
| `audiobook.dart` | 오디오북 저장: `AudiobookMaker.make`(장마다 조각 합성 → 24kHz 모노로 이어 붙임 → M4A, 이어 만들기, m3u8), `pcmFromWav`(어떤 WAV 든 변환), `AudioRender`(플랫폼별 글 → WAV · WAV → M4A), `_WinVoices`(PowerShell 하나로 System.Speech 파일 출력) |
| `background_reading.dart` | 안드로이드 화면 꺼도 읽기: `mediashelf/bg` start/stop → `ReadAloudService` |

## 5. 화면 (lib/ui)

| 파일 | 하는 일 |
|---|---|
| `home_page.dart` | 큰 틀. PC(폭 840 이상): `_TopActionBar`(추가 · 선택 동작 · 더보기) + `_Sidebar` + 목록 + 상세 + 상태 막대. 휴대폰: 앱바 + 서랍 + 하단 탭(계정에 허용된 종류만). `_ExternalOpener`(다른 앱에서 연 파일) |
| `landing_view.dart` | 홈: 큰 배너 `_Hero`(표지 없으면 만든 표지), 가로 줄 `_Row`, `HoverZoom` |
| `browser.dart` | 목록 `EntryBrowser`(격자/표/카드), 경로 막대, 상세 패널, 상태 막대, 오른쪽 클릭 메뉴(소리 내어 읽기로 열기 · 탐색기 · 삭제 …) |
| `series_widgets.dart` | 묶음 카드 `SeriesTile`, 묶음 머리 `SeriesHeader`, 선택 막대, `askText`, `pickSeries`, 묶음 편집 |
| `cover_tile.dart` / `brand.dart` | 책 카드 · `CoverImage` / 앱 이름 · `ArariLogo`(코드로 그린 로고) · `TitleCover`(제목 색 표지) |
| `import_dialog.dart` | 폴더/파일 추가 창: 후보 목록 · 필터 · 추가 방식 · 묶기 · 숨김. iOS 안내 `_iosFolderHelp` |
| `login_page.dart` | 첫 관리자 만들기, 프로필 고르기, 비밀번호 초기화 `_ResetView` |
| `admin_page.dart` | 사용자 관리, 숨김 비밀번호, `AccessPage`(폴더 · 종류 · 묶음 · 작품 권한) |
| `settings_page.dart` | 설정 9분류. `_Voice`(자연 음성 받기 · 들어 보기), `_KokoroCard`, `_OcrModelCard`, `_PortableCard`(정보 분류 안) |
| `share_page.dart` | 공유 서버 켜기 · 주소 · 아이디/비밀번호 · 공용 접속 범위 · 로그 |
| `detail_page.dart`, `metadata_search_dialog.dart`, `batch_editor_page.dart` | 상세 정보, 메타데이터 통합 검색, 일괄 편집 |
| `history_page.dart`, `ai_chat_sheet.dart` | 열람 기록, AI 도우미 |
| `tools/tools_page.dart`, `tools/archive_tool_pages.dart`, `tools/convert_tool_pages.dart`, `tools/image_editor.dart` | 파일 도구 목록, 압축 · 텍본 · PDF→텍스트 화면(`ToolRunner` 공통), 이미지→PDF · 해상도 · EPUB 최적화 · PDF 나누기/합치기 화면, 표지 이미지 편집 |

### 뷰어 (lib/ui/viewers)
| 파일 | 하는 일 |
|---|---|
| `open_item.dart` | 종류별 뷰어 고르기 `viewerFor`, `openItem`, 다음 권 버튼 |
| `viewer_chrome.dart` | 공통 도구줄 부품 `ToolGroup/ToolBtn`, 설정 패널, 색 `toolActive`(빨강) |
| `comic_reader_page.dart` | 만화: 한장/두장/스크롤, 맞춤, 방향(기본 오른쪽→왼쪽), 효과, 썸네일, 책갈피, RAR(PageLoader) |
| `text_reader_page.dart` | ★ 소설 TXT/EPUB: 목차/하이라이트/검색, 테마, 글꼴. 읽어주기: `_plan`(서술/대사/속마음 + 인물 목소리), `_ttsPlay`(실행 토큰 `_ttsRun`), 취침 타이머 `_setSleep/_sleepDue`, `_castDialog`(인물별 목소리), `readAloud` 시작 옵션 |
| `audiobook_dialog.dart` | 오디오북으로 저장 창: `audiobookParts`(차례로 나누기), `defaultAudiobookDir`, 진행 · 멈춤 · 결과 |
| `pdf_reader_page.dart` | PDF(pdfrx) + 쪽 단위 읽어주기 `ReadAloudBar`, `_pageText` → `PdfText.pageText` |
| `read_aloud.dart` | 쪽 단위 읽어주기 막대 (PDF 용) |
| `epub_original_page.dart` | EPUB 원본 스타일(Windows WebView2) |
| `image_viewer_page.dart`, `video_player_page.dart` | 그림(슬라이드쇼), 영상(media_kit: 자막 · 음성 트랙 · 배속 · 이어보기) |

## 6. 네이티브 · 빌드

| 파일 | 하는 일 |
|---|---|
| `packages/arari_native/` | 로컬 플러그인(iOS · macOS): `ArariNativePlugin.swift` — Vision 글자 인식 `mediashelf/ocr`, AVSpeech 음성 `mediashelf/tts` |
| `tool/patch_android.py` | `flutter create` 로 만든 android/ 를 고침: 권한, VIEW 인텐트(열기), queries(TTS), launchMode, MainActivity(채널: storage · open · tts · ocr), ML Kit 한국어, R8 규칙, 서명 |
| `tool/patch_apple.py` | macos/ ios/ 를 고침: Podfile · 최소 버전(macOS 14 / iOS 16), 샌드박스 끔(맥), 창 크기, Info.plist(파일 앱 폴더 · 로컬 네트워크 · 백그라운드 오디오) |
| `tool/patch_windows.py` | windows/ 를 고침: 창 제목 · 크기, WebView2 빌드 정의 |
| `tool/icons_*.yaml` | 아이콘 생성 설정 (assets/icon/icon.png) |
| `installer/media_shelf.iss` | Windows 설치파일(Inno Setup) |
| `.github/workflows/build.yml` | CI: windows(설치판 · 포터블 zip, 7-Zip · eSpeak NG · VC++ 동봉), screenshots(Windows 캡처 · 검사), android(APK), android-screens(에뮬레이터), macos(dmg/zip + 캡처), ios(서명 없는 ipa + 시뮬레이터 캡처), package(전체 묶음) |
| `integration_test/screenshots_test.dart` | 실제 앱을 샘플 데이터로 띄워 화면 30장 캡처 + 자동 검사(숨김 누출, 계정 권한, 공유 서버 HTTP, 자연 음성, Kokoro, 기기 음성, OCR, PaddleOCR) |
| `test_driver/integration_test.dart` | 안드로이드 · iOS 캡처 결과를 받아 저장하는 드라이버 |
| `test/*.dart` | 단위 테스트: 비밀번호, 파일명 해석, 화자 찾기 · 문장 나누기, 휴대용 설정, 위젯 |
| `THIRD_PARTY_NOTICES.txt` | 라이선스 고지 (UTF-8 BOM 유지) |
