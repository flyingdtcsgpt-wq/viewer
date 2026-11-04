# ARARIFlex 개발 내역서

모든 변경을 날짜순으로 적었습니다. (git 커밋 기록에서 만듦, 총 88건)
각 줄의 7자리 코드는 커밋 번호입니다. `git show <번호>` 로 그때 바뀐 코드를 볼 수 있습니다.

## 버전 요약

| 버전 | 날짜 | 핵심 |
|---|---|---|
| 0.2 | 2026-11-01 | 첫 구조: 책·만화·그림·영상 뷰어, 묶음(시리즈) 트리, 로그인·사용자별 기록·관리자 권한·숨김, 넷플릭스풍 디자인, 안드로이드 모든 파일 접근 |
| 0.3 | 2026-11-02 | BookManager 풍 PC 화면, 뷰어 개편, 설정 창, 메타데이터 통합 검색·일괄 편집, 파일 도구, 공유 서버(Web/OPDS), TTS, RAR/7Z, 영상 자막 |
| 0.4 | 2026-11-02 | 표지 편집기, TXT→EPUB, 이름 ARARIFlex, 가져오기 창(목록 선택·중복·복사/이동·묶기·숨김), 비밀번호 초기화, 화면 자동 캡처, UI 개선, 계정별 폴더/종류 권한 |
| 0.5 | 2026-11-02~03 | 자연 음성(Supertonic), 소설 PDF 글자 인식 읽기, 인물별 목소리, 공유 서버 계정 권한, 안드로이드 다듬기, 태블릿·맥·아이폰/아이패드, 휴대용 모드, PaddleOCR, Kokoro 영어 성우 |
| 0.6 | 2026-11-04 | 큰 서재 성능(2만 권), 취침 타이머 · 화면 꺼도 읽기, 오디오북 저장(M4A/WAV · 장마다/한 파일), 스캔 PDF → TXT/EPUB, 이미지 → PDF · 해상도 · EPUB 최적화 · PDF 나누기/합치기, 영어 화자 · 주고받기 · 자동 배역, 배경음, 설계 사양서 |

## 전체 변경 기록


### 2026-11-01

- `dc5f0b4` 12:03 — MediaShelf v0.2: library manager with text/image/comic/video viewers and CI build
- `3c38256` 12:21 — Fix CI: own widget test, analyzer warnings
- `229a469` 14:30 — Nested series grouping: auto-group by filename, volume counts, status, selection
- `0fa8d28` 15:10 — Login & per-user history, admin access control, password-protected hidden items, left sidebar, delete confirmation
- `d6feb74` 15:20 — Netflix-style design: dark theme, landing hero and rows, profile picker, hover zoom
- `4f8ba39` 15:27 — Style: null-aware elements
- `138b5ed` 16:04 — Android: request all-files access before scanning; report scan results
- `a222957` 16:11 — Android all-files access via native channel; page direction and tap/swipe page turning
- `210e0a4` 16:19 — v0.2.0: app icon, optional release signing, fewer Android permissions, per-ABI APKs
- `a74c57f` 16:25 — Fix manifest merge: match READ_EXTERNAL_STORAGE maxSdkVersion

### 2026-11-02

- `577e4ce` 08:52 — v0.3.0: BookManager-style desktop layout (action bar, collections sidebar, path bar, grid/table/cards, detail panel, rating dialog, context menu, status bar)
- `8c3d7ff` 08:59 — Clean up analyzer warnings
- `cab36d7` 09:07 — Remove unused variable
- `fad5e21` 09:39 — Comic viewer redesign: toolbar, viewer settings panel, thumbnail strip, fit modes, effects, immersive background, bookmarks
- `34e7583` 10:00 — Text/EPUB viewer redesign: toolbar, TOC/highlight/search panel, 7 themes, fonts, highlights, chapter strip
- `b8f2523` 10:08 — PDF viewer: shared toolbar, thumbnail strip, bookmarks; Android CI only on release/manual
- `fecb910` 10:11 — Settings dialog with categories, library folders (group/alias/order), source toggles, Naver search, library sidebar
- `7ccfee8` 10:13 — Metadata: unified search dialog (list + detail + field picker), batch metadata editor
- `9b6f6f9` 10:16 — File tools: flatten archives, rename inner files, add/replace cover, TXT cleaner
- `1336ca7` 10:18 — Share server: Web browsing + OPDS catalog with basic auth, server log page
- `543dd8a` 10:19 — TTS read-aloud for TXT/EPUB on PC (Windows System.Speech), dialogue/thought voices
- `be146f6` 10:20 — RAR/7Z/CBR comics via built-in tar; Windows window title and default size
- `9039a17` 10:21 — README: current feature set
- `2781527` 10:25 — Fix TTS quote regex and analyzer warnings
- `5385166` 10:34 — Video subtitle/audio track menus, subtitle size & sync, HW decode option; Honeyview-style RAR/7Z with bundled 7-Zip; VC++ runtime and third-party notices
- `9baa00a` 10:40 — CI: take 7-Zip from build machine
- `937d40d` 10:50 — EPUB original-style viewer via WebView2 with local server, TOC, position, zoom
- `862bcfb` 10:52 — v0.4.0: cover image editor (crop/rotate/flip/adjust), TXT to EPUB converter
- `d5041fe` 10:59 — Windows: silence experimental coroutine deprecation for WebView2 plugin
- `9b12bb6` 13:22 — Rebrand to ARARIFlex: logo widget, red icon, installer/window names; import engine (preview, dup check, modes, grouping); mixed-kind bundle badges
- `3828d30` 13:25 — Import dialog with selectable candidate list, overlap/duplicate handling, reference/copy/move, hidden import, bundle grouping; password reset via RESET_PASSWORD.txt
- `e7daa29` 14:20 — CI: capture main screens (PC + phone size) from the real Windows app with sample data
- `7366ed8` 14:28 — Screenshots: fix navigation in capture test, publish images to screenshots branch
- `801e48a` 15:40 — UI: compact top bar (add menu, selection-only actions, more menu), generated title covers, cover-first banner, larger cards, red viewer accent, unified viewer close button, Material cards; per-account access by library folder and media kind
- `8a41930` 17:00 — Phone tabs show only kinds allowed for the account; capture restricted-account screens and assert no leak
- `b5c4550` 17:09 — Fix review findings: import only visible checked items, hidden imports hidden from the start (and their new series), rollback on failed move/copy, single import at a time, dialog error handling, Windows-aware folder overlap, file handle leak, no settings change from dialog, show merged-folder denials
- `3da8c7f` 17:09 — Capture test: verify hidden import does not leak items or series titles
- `3633f56` 17:24 — Natural offline TTS (Supertonic 3 via ONNX Runtime): download/import model, 10 voices, prefetch for smooth reading, voice settings page; CI synthesizes Korean and checks audio
- `57cc16f` 17:37 — Read aloud for PDF (text layer, OCR fallback for scans), comics and images via Windows built-in OCR; shared read-aloud bar; CI OCR check
- `c7555cf` 17:50 — Per-character voices (local speaker detection + per-book cast); share server applies per-account access (app account login or chosen account scope); replace deprecated Radio usage
- `8f65f9f` 17:50 — Capture test: verify share server applies per-account access over HTTP
- `7eb03e4` 17:50 — CI: cap Korean OCR language install at 5 minutes
- `de25ec3` 17:51 — v0.5.0: README for natural voices, OCR read-aloud, import options, per-account access; version bump
- `21a1ea7` 18:00 — Fix review findings: stop/restart races in read-aloud (generations, run tokens), no false error on skip, playback error/timeout, temp WAV cleanup, stale prefetch cancel, ordered model unload, share login cache + fail-closed scope + per-request counts, sturdier OCR script
- `7bd5903` 18:10 — OCR: tell the user when the Korean recognizer is missing; analyzer cleanups; drop slow OCR language install from CI
- `f62c553` 18:45 — Docs: developer notes and user manual
- `cacbe1d` 18:48 — Android: native TTS channel (device voices), ML Kit Korean OCR, build on every push, emulator capture job with voice/OCR checks
- `40a7311` 18:49 — Android: open files from other apps (VIEW intent, content:// copy), clear message for RAR/7Z on phone
- `bcccacb` 18:50 — Capture test: phone read-aloud bars (text and image viewers)
- `9a23fec` 19:03 — Android release: R8 rules for unused ML Kit scripts, keep ONNX Runtime classes
- `234f05d` 19:04 — Android capture: return screenshots and voice samples through the integration test driver
- `8c2b436` 19:27 — Fix notify during widget teardown when closing image/EPUB viewers (found on Android emulator); dev notes for Android
- `82ba3fd` 19:28 — Android capture driver: keep screenshots even when a test fails, print failures
- `bdbc375` 19:41 — Phone: read-aloud button in viewer title row (toolbar overflows), completion status disappears after a few seconds
- `71e5ab3` 19:42 — Capture test: list and try device TTS voices
- `1f5797f` 19:47 — Android review fixes: open-with copies off the UI thread into per-file folders (no overwrite, no re-copy), books/comics only, singleTask, ignore history relaunch, extension from MIME, access check for opened files, opener recovers from errors; TTS chunking/timeouts/init retry; title layout; OCR per-tile errors; capture data reported early
- `e7c9b4c` 20:00 — Open TXT/EPUB straight into read-aloud (context menu), TTS bar wraps on phones, nicer device voice names; capture test opens read-aloud directly
- `d659e8f` 20:11 — Docs: Android usage and notes

### 2026-11-03

- `19517e1` 00:06 — macOS, iPhone/iPad and tablets: Apple native plugin (Vision OCR, AVSpeech voices), Android OCR via native ML Kit channel, iOS library in Files app folder, Apple patch script, macOS/iOS CI builds with simulator/desktop captures, tablet-size screenshots
- `22130df` 00:36 — CI: separate macOS and iOS icon configs
- `c5eae89` 01:04 — Fix macOS natural voice (temp folder may not exist yet); iOS capture writes to app folder and returns files via driver
- `13be7c4` 01:04 — Tablet portrait: cap home banner height
- `9894b63` 01:05 — Docs: macOS, iPhone/iPad and tablet install and notes
- `c0000ff` 05:08 — Portable mode (arariflex_data next to the app holds DB, settings, covers, models; make-portable button; portable zip ships the folder); read-aloud only for novels (removed from comic and image viewers)
- `f67a87d` 05:10 — PaddleOCR Korean (PP-OCRv5 ONNX) for Windows: model download by repo listing / import from folder, DB detection + CTC recognition, used before Windows OCR; settings card; CI check
- `b6cde6f` 05:13 — Kokoro English voices (optional): int8/full model download or import, voices npz, eSpeak NG phonemes, falls back to Korean natural voice for Hangul; bundled eSpeak NG on Windows; settings card; CI checks; notices
- `68014f8` 05:19 — Fix Kokoro voices loader return type
- `5b74e88` 05:29 — Kokoro: pick the audio output by name (model also returns durations)
- `d8fe029` 05:39 — Capture test: measure Kokoro int8 vs full speed
- `c9f1bfe` 05:40 — Unit test: portable settings file
- `65e672b` 05:48 — Kokoro: original model only (int8 is far slower on CPU); docs for portable mode, PaddleOCR, Kokoro, novel-only read-aloud
- `7f8bb4f` 08:12 — Docs: development history, source guide, handoff guide; CI all-in-one package (installers + source + git bundle + docs)
- `fccca99` 08:13 — Docs: refresh development history
- `dfd64aa` 11:24 — CI: creating a GitHub release builds everything and attaches all installers, source, git bundle and docs; handoff note

### 2026-11-04

- `cea5b19` 13:52 — Detail page: human-readable file size
- `380dc9b` 14:05 — Performance for large libraries: per-revision caches (visible items, counts, tags, entries), view-only refresh for selection/navigation/search, debounced search, O(1) hidden/permission checks, throttled scan progress, batched DB writes and deletes, indexes + WAL, history cap, hidden attribute only for changed files, cover cleanup on delete, sidebar series cap, slider saves on release
- `b4a85de` 14:06 — Scale test: 20k items / 2k series timings in CI; DB insertMany
- `47ea7cb` 14:07 — Covers: archive/EPUB/RAR work in isolates, one archive open for page count + cover, 480px JPEG thumbnails (also for photos), cacheWidth on banner and detail panel
- `ff758f6` 14:09 — Faster auto-grouping (title index, prefix search for spin-offs), missing-file check only in scanned folders and skips offline drives, in-memory path index for scans, import preview sort in isolate with parallel size reads and O(n) duplicate check; scale test for auto-grouping
- `b64f525` 14:17 — Faster deep selection (series child index, cached sort keys) and bulk series deletion in one transaction
- `760d5e2` 14:19 — Comic reader: CBZ pages from a background worker that keeps the archive open (no UI freezes on big archives / slow drives) and frees unpacked data per page (memory no longer grows); share server reuses per-account access per revision and looks items up by id; speaker scan off the UI thread
- `5188531` 14:21 — Read-aloud: sleep timer (15-90 min or end of chapter); Android keeps reading with the screen off (foreground service with notification + wake lock)
- `1d5dfeb` 14:43 — Audiobook export: save a novel as per-chapter audio files (M4A or WAV) with the chosen voices, including dialogue/thought/per-character casting; resumes skipped chapters; playlist; Windows/macOS/Android/iOS render and AAC encoders
- `da67f15` 14:54 — Scanned PDF to TXT/EPUB (OCR in batches, page numbers and running headers removed, broken lines joined, chapter lines kept); file tools: image to PDF, image resize, EPUB optimize, PDF split/merge; drop unrealistic placeholder tools; docs
- `982a592` 15:16 — File tools replace an image only when it gets smaller; audiobook treats silent renders as failures; tests use photo-like images and fall back to English for English-only voices
- `3307369` 15:32 — Windows voice-to-file worker: run from a BOM script and write UTF-8 to stdin; tests clean up temp folders best-effort
- `bcfc729` 15:41 — Character voices: English speaker rules, back-and-forth dialogue inference, automatic distinct voices per character, abbreviation/ellipsis normalization, short pauses on voice change, Kokoro hint for English books; generated background sounds with volume; audiobook as one file; tests and docs
- `8831d69` 15:46 — Fix audio file picker result type; Windows voice-to-file falls back to one process per piece with error log; analyzer cleanups (reorder API, context after await, doc comment, imports)
- (다음 커밋) — 설계 사양서(SPEC.md), 기능 목록 정리, 0.6.0
