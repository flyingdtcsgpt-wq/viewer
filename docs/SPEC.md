# ARARIFlex 설계 사양서 (처음부터 다시 만들 수 있는 설계도)

> 이 문서만 보고 같은 앱을 새로 만들 수 있도록 **무엇을 · 어떤 규칙으로 · 어떤 구조로** 만드는지 적는다.
> 화면 사용법은 [MANUAL.md](MANUAL.md), 파일별 설명은 [SOURCE_GUIDE.md](SOURCE_GUIDE.md), 결정 이력은 [DEV_NOTES.md](DEV_NOTES.md),
> 빌드 · 인수인계는 [HANDOFF.md](HANDOFF.md). 판: 0.6.0 (2026-11-04)

---

## 0. 한 줄 정의
책(EPUB · PDF · TXT), 만화(CBZ · ZIP · CBR · RAR · CB7 · 7Z), 그림, 영상을 **한 서재**에서 정리하고 읽는 **개인용 오프라인 앱**.
가족 계정마다 보이는 범위를 다르게 하고, 소설은 **기기 안 AI 음성으로 인물마다 다른 목소리**로 읽어 주며 오디오북 파일로도 만든다.

## 1. 지켜야 할 원칙
| 원칙 | 내용 |
|---|---|
| 오프라인 우선 | 인터넷 없이 모든 기본 기능이 돈다. AI 모델 · 코덱 · 압축 도구는 받거나 동봉, 폴더에서 가져오기 지원 |
| 무료 · 로컬 우선 | 유료 API(Claude, 검색 키)는 선택 사항. 없어도 앱이 완전히 동작 |
| 원본 보호 | 원본 파일을 바꾸는 기능은 `.bak` 백업 기본 켬. 삭제는 항상 "목록에서만 / 원본 파일까지" 를 묻는다 |
| 소설만 낭독 | 소리 내어 읽기 · 다중 화자 · 오디오북은 **소설(TXT · EPUB · PDF)** 만. 만화 · 그림 · 영상에는 없음 |
| 같은 인물 같은 목소리 | 남녀를 번갈아 붙이지 않는다. 화자를 알면 그 인물의 고정 목소리, 모르면 "대사" 목소리 |
| 화면이 멈추지 않음 | 무거운 일(압축 풀기 · 표지 · 분석 · 인코딩)은 isolate · 네이티브 스레드에서 |
| 이름 | 앱 이름은 **ARARIFlex** (붙여 씀, 한글 아라리플렉스). 기본 색 빨강 |
| 만화 넘김 | 기본: 오른쪽→왼쪽으로 밀면 다음 쪽 (한국 · 일본 만화) |

## 2. 대상 플랫폼 · 기술
| 항목 | 선택 |
|---|---|
| 언어 · 틀 | Dart 3.13 / Flutter 3.47 이상, 상태 관리 `provider` (`ChangeNotifier`) |
| 플랫폼 | Windows 10/11(1순위), Android 8+(휴대폰 · 태블릿), macOS 14+, iOS/iPadOS 16+ |
| DB | SQLite (`sqflite`, 데스크톱은 `sqflite_common_ffi`), WAL |
| 설정 | `Prefs` 추상화: 보통 SharedPreferences, 휴대용이면 JSON 파일 |
| 문서 | PDF: `pdfrx`(PDFium) / EPUB: 직접 파싱(`archive` + `xml`) / TXT: 인코딩 판별 |
| 영상 · 소리 | `media_kit`(libmpv, FFmpeg 코덱 동봉) |
| 압축 | ZIP/CBZ: `archive`, RAR/7Z: 동봉 7-Zip(Windows) · tar(macOS) |
| 그림 처리 | `image` 패키지 (isolate 안에서) |
| AI 음성 | Supertonic 3 (ONNX, `flutter_onnxruntime`), Kokoro-82M (ONNX + eSpeak NG) |
| 글자 인식 | Windows: PaddleOCR PP-OCRv5 한국어(ONNX) → Windows.Media.Ocr / Android: ML Kit 한국어 / Apple: Vision |
| 네이티브 | Android: Kotlin(MainActivity · 서비스, CI 가 `tool/patch_android.py` 로 생성), Apple: 로컬 플러그인 `packages/arari_native`(Swift) |

## 3. 전체 구조
```
main.dart ─ Portable.init → Settings.load → LibraryDb.open → CoverService.init → AppState.load → runApp
                                                                   │
   ┌────────────────────────── AppState (ChangeNotifier, 앱의 중심) ─┴───────────────────────────┐
   │ 항목/묶음 메모리 목록 · 현재 사용자 · 권한(_DenyIndex) · 숨김 · 보기 상태(탐색 · 정렬 · 선택)   │
   │ 파생값 캐시(_rev 판마다 _memo) · 가져오기/스캔 · 자동 묶기 · 이동/삭제 · 진행률 저장          │
   └──────────────────────────────────────────────────────────────────────────────────────────────┘
        │ db/library_db.dart (SQLite)      │ services/* (파일 · 음성 · 인식 · 서버)    │ ui/* (화면)
```
- **데이터 판 `_rev`**: 데이터가 바뀌면 `notifyListeners()` 가 `_rev++` 하고 파생값 캐시를 비운다. 보기만 바뀌면 `_viewChanged()`(캐시 유지).
- **파생값 캐시 `_memo(key, make)`**: 목록(entries) · 개수 · 태그 · 트리 · id 색인 · 계정별 권한을 판마다 한 번만 계산.
- **진행 알림 `_progress()`**: 스캔 · 가져오기 중 화면 갱신은 0.3초에 한 번.

## 4. 데이터 모델 (SQLite, DB 버전 5)
```sql
items(id PK, path UNIQUE, kind, storage, title, author, publisher, isbn, series, year, description, cover_path,
      tags, rating DEFAULT 0, favorite DEFAULT 0, size DEFAULT 0, added_at, missing DEFAULT 0,
      progress REAL DEFAULT 0, position TEXT, last_opened, series_id, volume REAL, hidden DEFAULT 0, pages)
series(id PK, parent_id, title, author, description, cover_path, total, status, added_at, hidden DEFAULT 0)
users(id PK, name UNIQUE, role, pw_hash, salt, created_at)
user_progress(user_id, item_id, progress, position, last_opened, PK(user_id,item_id))
history(id PK, user_id, item_id, opened_at, closed_at, progress, position)
denied(user_id, target, PK(user_id,target))   -- target: 'i:<항목id>' 's:<묶음id>' 'k:<종류>' 'f:<라이브러리 폴더 경로>'
색인: items(kind) items(title) items(series_id) history(user_id,opened_at) history(item_id) user_progress(item_id) denied(target)
PRAGMA journal_mode=WAL, synchronous=NORMAL. 열람 기록이 5만 줄을 넘으면 사용자마다 최근 5천 줄만 남김
```
- `kind`: book · comic · image · video. `storage`: linked(원본 연결) · copied · moved
- `position`: 뷰어별 위치 문자열 (TXT/EPUB 블록 번호, 만화/PDF 쪽, 영상 ms)
- `volume`: 권/화 번호 실수(10.5 = 번외). `series.status`: ongoing · completed · hiatus
- 여러 줄을 한꺼번에 바꿀 때는 트랜잭션 묶음: `insertMany · updateMany · updateSeriesMany · deleteMany(500개씩) · deleteSeriesMany`

### 확장자
| 종류 | 확장자 |
|---|---|
| 책 | .epub .pdf .txt (.mobi .azw3 .fb2 .djvu 는 목록만, 다른 앱으로 열기) |
| 만화 | .cbz .zip .cbr .rar .cb7 .7z |
| 그림 | .jpg .jpeg .png .gif .webp .bmp .tif .tiff .heic .avif |
| 영상 | .mp4 .mkv .avi .mov .wmv .webm .m4v .ts .flv |

## 5. 기능 사양

### 5.1 서재 (라이브러리)
- **라이브러리 폴더**: 여러 개 등록, 그룹 · 별칭, 오프라인(USB 빠짐) 폴더는 검사에서 제외
- **가져오기 창**: 폴더 추가 → 후보 목록(전체 선택 · 새 항목만 · 종류/경로 필터 · 중복 의심 표시: 같은 크기+이름) →
  추가 방식(원본 연결 / 라이브러리 폴더로 복사 / 이동, 정리 규칙 `{kind}/{author}/{title}`) →
  묶기(파일명으로 시리즈 · 폴더 구조대로 · 폴더 전체를 한 묶음) → "숨김으로 추가"
- **누락 검사**: 파일이 사라지면 `missing` 표시(16개씩 병렬 확인). 다시 나타나면 해제
- **자동 묶기**: 파일명 → (제목, 권수) 규칙 (`series_parser.dart`)
  1. `[..] (..) {..} 【..】` 괄호 내용 제거, `_` → 공백, "1-3권" → "1권"
  2. 차례대로 시도: `S01E02` → `제3권 / 3화 / 3편 / 3부 / 巻 / 話` → `vol. v # ep e ch 숫자` → `제목 숫자`(끝) → `제목숫자`(끝 1~3자리)
  3. 완결 표시 `(완결) [完] complete`, 연재 `(연재중) ongoing`
  4. 정규화 제목(소문자, 공백 · 기호 제거)이 같으면 같은 묶음. 이름이 "대표 제목 + 구분자 + 부제" 이면 파생 묶음(외전 · 극장판)을 대표 아래로
- **묶음(시리즈)**: 몇 단계든 중첩(parent_id), 보유/전체 권수, 상태, 누락 권수, 다음에 읽을 권, 표지
- **모아보기**: 홈 · 즐겨찾기 · 최근 읽음 · 읽는 중 · 다 읽음(≥98%) · 최근 추가 · 누락 권수
- **검색 · 정렬**: 제목/저자/태그 검색(0.2초 늦춰 반영), 정렬(이름 · 추가일 · 최근 열람 · 권수 · 크기 · 평점), 하위 묶음 포함
- **목록 보기**: 격자 / 표 / 카드, 항목 크기 슬라이더, 상세 패널(표지 · 읽기 · 태그 · 정보 표 · 줄거리 · 10점 별점)
- **조작**: 클릭=선택, 더블클릭=열기, Ctrl/Shift=여러 개, 오른쪽 클릭 메뉴(열기 · 다른 앱으로 · 읽음 표시 · 진행 초기화 · 평점 · 즐겨찾기 ·
  메타데이터 · 묶음 정보 · 다른 묶음으로 · 숨기기 · 사용자 접근 · 소리 내어 읽기로 열기 · 탐색기에서 열기 · 삭제 · 전체 선택 · 새로고침)
- **홈 화면**: 큰 배너(표지 없으면 제목으로 만든 표지) + 가로 줄(보던 작품 · 최근 추가 · 종류별 · 즐겨찾기)
- **휴대폰**: 앱바 + 서랍 + 아래 탭(계정에 허용된 종류만). 사이드바 맨 위 묶음은 60개까지 + "모든 묶음 보기"

### 5.2 사용자 · 권한 · 숨김
- 첫 실행: 관리자 만들기. 이후 프로필 고르기(비밀번호 선택). 비밀번호는 PBKDF2-HMAC-SHA256, 솔트 + 2만 회
- 역할: 관리자 / 사용자. 읽은 위치 · 열람 기록은 **사용자마다 따로**
- **접근 권한(관리자)**: 라이브러리 폴더(`f:`) · 종류(`k:`) · 묶음(`s:`, 아래 전부 막힘) · 작품(`i:`) 단위로 막기.
  막힌 것은 목록 · 홈 · 검색 · 기록 · 공유 서버 · 휴대폰 탭 어디에도 안 나온다. 검사는 `_DenyIndex`(집합 · 폴더 접두어 · 묶음 조상 캐시)로 O(1)
- **숨김**: 숨김 비밀번호를 정하고 항목/묶음을 숨김. **검색창에 숨김 비밀번호** 를 넣으면 드러나고 "잠그기"/앱 종료로 다시 숨김.
  Windows 파일 숨김 속성도 같이 바꾼다(바뀐 파일만). 공유 서버에는 절대 안 나옴
- **비밀번호 초기화**: 관리자 비밀번호를 잊으면 복구 절차(MANUAL 13장)

### 5.3 뷰어
| 뷰어 | 기능 |
|---|---|
| 만화(CBZ/ZIP/RAR/7Z) | 한장 · 두장 · 세로 스크롤(웹툰), 맞춤(가로/높이/전체/원본), 확대, 읽기 방향, 표지 단독, 몰입형 배경, 넘김 효과(슬라이드 · 페이드 · 책), 썸네일 줄, 책갈피, 전체화면. ZIP 은 일꾼 isolate 가 한 번 열어 두고 쪽마다 꺼냄(`ZipPages`), RAR/7Z 는 쪽마다 7-Zip |
| TXT/EPUB | 목차 · 하이라이트 · 본문 검색 패널, 테마 7종, 글꼴, 크기 · 줄 간격 · 문단 간격 · 본문 폭, 글자 선택 → 색칠 · 복사 · 검색 · AI 뜻풀이, 장 이동 줄, EPUB 원본 스타일(Windows WebView2), 소리 내어 읽기 |
| PDF | 같은 도구줄, 썸네일 줄, 책갈피, 쪽 단위 소리 내어 읽기(스캔본은 글자 인식) |
| 그림 | 넘기기 · 확대 · 슬라이드쇼 |
| 영상 | 이어보기, 배속, 자막 · 음성 트랙, A-B 반복, 다음 화 자동, 하드웨어 디코딩 설정 |
- 다른 앱(파일 관리자)에서 "ARARIFlex 로 열기" → 로그인 뒤 바로 열기(권한 검사)

### 5.4 소리 내어 읽기 (소설)
**음성 이름 규칙** (앞글자로 엔진을 고름)
| 앞글자 | 엔진 | 비고 |
|---|---|---|
| `st:F1`~`F5`, `M1`~`M5` | Supertonic 3 (한국어 등 31개 언어, 44.1kHz) | 약 380MB, HF `supertone-oss-archive/supertonic-3` @ `aafc6e3…`, OpenRAIL-M |
| `kk:af_heart` 등 28개 | Kokoro-82M (영어, 24kHz) | fp32 모델만(int8 은 CPU 에서 15배 느림), 발음은 eSpeak NG IPA |
| `and:이름\|언어\|local` | 안드로이드 TextToSpeech | |
| `ios:식별자\|…` | AVSpeechSynthesizer | |
| 그 밖 | Windows System.Speech(PowerShell) / macOS `say` | |

**문단 → 조각 나누기** (`_segments`)
- `“…” "…" 「…」 『…』` = 대사(1), `‘…’ '…'`(낱말 밖에서 열고 닫힐 때만) = 속마음(2), 나머지 = 서술(0)
- 영국식 영어 책(작은따옴표 대사가 큰따옴표의 2배 넘게 많으면)은 작은따옴표를 대사로
- 속마음은 속도 −2 (조금 느리게)

**화자 찾기** (`speakers.dart`, 규칙 기반 · 오프라인)
1. 대사 **뒤** 서술: `민호가 속삭였다` (이름 1~6자 + 이/가/은/는/께서 + 24자 안 말하는 동사 약 40개) / `said Holmes` / `Holmes said` / `Mr. Holmes asked`
2. 대사 **앞** 서술: `수아가 고개를 저으며 말했다.` / `Watson turned to me and said,`
3. 이름이 아닌 말 제외(그, 그녀, 남자, 목소리 … / He, She, Then …). 영어 이름은 호칭 · 앞 낱말을 떼고 성으로 묶음(Sherlock Holmes = Holmes)
4. **주고받기**(옵션, 기본 켬): 지문에서 못 찾고 대사만인 문단이면 앞 10문단을 거꾸로 보며, 가장 가까운 알려진 화자 X 가 짝수 칸 앞이면 X,
   홀수 칸이면 그 앞의 다른 화자 Y. 대사 없는 문단 · 화자 모르는 서술 섞인 문단을 만나면 포기(→ "대사" 목소리)
5. **등장인물 목록**(`scan`): 책 전체에서 말하는 장면 횟수 순 (2번 이상, 인물이 적으면 1번도), 최대 30명

**목소리 정하기** (대사 조각)
`사용자가 고른 인물 목소리(책마다 저장)` → `자동 배역(옵션, 기본 켬)` → `"대사" 목소리` → `기본 음성`
- 자동 배역 = 인물 순위 % 목소리 풀. 풀 = 영어 책이면 Kokoro, 아니면 Supertonic, **남녀 번갈아**, 서술 · 대사 · 속마음 음성 제외. 순위 밖 이름은 이름 해시 자리
- "자동 배역 고정" 은 지금 붙은 목소리를 저장(이후 하나씩 바꾸기)

**읽기 흐름**
- 문단마다 계획(글, 음성, 속도) → 다음 조각 · 다음 문단 첫 조각 미리 합성(`prefetch`) → 재생(media_kit) → 다음
- 목소리가 바뀌는 조각 사이 220ms 쉼. Kokoro 에 한글이 오면 `st:F1` 로 바꿔 읽음
- 글 다듬기 `normalize`: `...`→`…`, Mr./Mrs./Dr./Prof./Capt./… 풀어 쓰기, `St. 대문자`→Saint, 그 밖 `St.`→Street, `No. 숫자`→Number, e.g./i.e./etc.
- 멈춤 · 다시 시작 경쟁은 실행 토큰(`_ttsRun`, `_gen`, `_epoch`)으로. `failed` 일 때만 오류 안내(멈춤과 구분)
- **취침 타이머**: 15/30/45/60/90분 또는 "이 장이 끝나면"(다음 차례 블록 앞에서 멈춤). 읽는 위치는 계속 저장
- **화면 꺼도 읽기(안드로이드)**: foreground service(mediaPlayback) + 알림 "소리 내어 읽는 중" + PARTIAL_WAKE_LOCK(최대 6시간)
- **배경음**: 빗소리 · 파도 · 벽난로 · 갈색/분홍/백색 소음(앱이 22.05kHz 30초 소리를 만들어 이음새 없이 반복) 또는 내 소리 파일, 볼륨 0~100, 0.8초 커지기 · 0.6초 줄이기
- 영어 책 + Kokoro 설치됨 → "Kokoro 영어 성우로 읽기" 단추
- PDF: 쪽 단위(`ReadAloudBar`), 글자가 15자 미만인 쪽은 2600px 로 그려 글자 인식

### 5.5 오디오북 저장
- 범위: 책 전체 / 지금 장부터 / 지금 장만. 부분 = 차례(TOC) 한 장(차례 앞 글은 "머리말"), 차례가 없으면 약 2만 자씩
- 조각마다 위와 **같은 계획**(인물 · 주고받기 포함, 블록 번호를 넘겨 같게)으로 WAV 를 만들고 24kHz 모노 16비트로 맞춰 이어 붙임
  (조각 사이 0.12초, 문단 사이 0.35초). 어떤 WAV 든 받음(8/16/24/32비트 정수, 32/64비트 실수, 여러 채널, LIST · FLLR 덩어리)
- 파일 이름 `001 제1장 ….m4a`(번호는 전체 차례 기준이라 범위를 바꿔도 같음) + `책 제목.m3u8`. 또는 **한 파일로 합치기**
- 이어 만들기: 같은 이름 파일이 있으면 건너뜀. 소리가 비거나 실패한 조각은 세고, 12번 잇달아 실패하면 멈추고 안내
- 글 → WAV: 모델 음성(앱 안 추론), Windows 기기 음성(PowerShell 하나를 띄워 두고 줄마다 일, 안 되면 조각마다 새로), macOS `say -o`, 안드로이드 `synthesizeToFile`, iOS `AVSpeechSynthesizer.write`
- WAV → M4A(AAC): Windows Media Foundation `MediaTranscoder`(96kbps 모노), 안드로이드 MediaCodec + MediaMuxer(64kbps), Apple AVAudioFile(64kbps). 못 하면 WAV 그대로
- 저장 위치: PC `음악\ARARIFlex 오디오북\책 제목`, 안드로이드 `Audiobooks/…`(권한 없으면 앱 폴더), iOS 파일 앱 › ARARIFlex
- 진행 창: 몇 번째 장 · % · 만든 소리 길이 · 남은 시간 어림 · 멈춤. 안드로이드는 화면을 꺼도 계속

### 5.6 글자 인식 (OCR)
- Windows: PaddleOCR PP-OCRv5 한국어(HF `monkt/paddleocr-onnx`: `detection/v5/det.onnx`, `languages/korean/rec.onnx`, `dict.txt`, 약 20MB)
  DB 검출(긴 변 960, 임계 0.3/0.6, unclip 1.6) → 높이 48 인식 → CTC. 없으면 Windows.Media.Ocr(PowerShell + WinRT, 한국어 언어팩 필요)
- Android: ML Kit 한국어(기기 안). Apple: Vision(ko-KR, en-US, 정확 모드)
- 긴 그림은 2600px 조각(80px 겹침). 줄 잇기 `tidy`: 문장부호로 안 끝나면 다음 줄과 이음

### 5.7 파일 도구
| 도구 | 규칙 |
|---|---|
| 텍본 정리 · 인코딩 변환 | CP949/UTF-16 → UTF-8, 줄 끝 공백 제거, 빈 줄 3개 이상 → 2개, 줄바꿈 통일 |
| TXT → EPUB | "제1장 · 1화 · Chapter 3 · 프롤로그 …" 줄(40자 이하)로 장 나눔, 장이 하나뿐이고 3000줄 넘으면 3000줄씩, 표지, EPUB3 + toc.ncx |
| PDF → 텍스트 | 쪽 글 15자 이상이면 그대로, 아니면 그려서 6쪽씩 글자 인식. 쪽 위아래 2줄 중 쪽 번호 · 여러 쪽(≥3쪽, ≥30%)에 되풀이되는 40자 이하 줄(숫자 무시) 제거, 문장부호로 안 끝나면 이음, 장 제목 줄은 따로 → TXT 또는 EPUB, 서재에 추가 |
| 이미지 → PDF | 만화 한 권 → PDF, 고른 그림들(이름 순) → PDF 하나. 직접 쓰는 PDF 1.4: JPEG 는 DCTDecode 로 그대로, 나머지는 JPEG 로(투명은 흰 바탕), 쪽 너비 595pt |
| PDF 나누기 · 합치기 | N쪽마다 / 범위 `1-10, 11-`(쉼표 묶음마다 파일) / 여러 PDF 를 끌어서 순서 정해 합치기 (pdfrx `createNew` + `pages` + `encodePdf`) |
| 압축 구조 정리 | 폴더 없애기, 쓰레기 파일(__MACOSX, .DS_Store, Thumbs.db, desktop.ini, ._*) 제거, 이름 겹침 방지 |
| 내부 파일명 변경 | 000/00/0000 번호 또는 유지, 순서 바꾸기 · 빼기 |
| 표지 추가 · 교체 | 그림 파일 · 인터넷 검색 · 책 안 그림, 편집(자르기 · 회전 · 뒤집기 · 밝기 · 대비 · 채도 · 흑백) |
| 이미지 해상도 변경 | 긴 변 1200/1600/2000/2560/그대로, JPEG 품질 70/82/90, 만화 속 PNG·BMP·GIF → JPEG 선택. **더 작아질 때만 바꿈**, 결과 파일이 더 크면 원본 유지 |
| EPUB 용량 최적화 | 안의 JPEG · PNG 줄이기(이름 유지, 형식 유지), 글 · 스타일은 deflate 9, mimetype 맨 앞 무압축, 더 작아질 때만 |
| 메타데이터 일괄 | 여러 권 정보 한 번에, 시리즈 자동 매칭 |
- 일부러 **뺀 것**: EPUB 편집기, TXT → PDF(한글 글꼴을 넣어야 함), AI 화질 향상

### 5.8 메타데이터
- 통합 검색: 카카오 · 네이버 · Google Books · Open Library 동시, 결과 목록 + 상세, 적용할 칸만 고르기, AI 원제 찾기(선택)
- EPUB 안 정보(OPF: 제목 · 저자 · 출판사 · 설명 · ISBN) 자동 읽기, 쪽수(만화 그림 수 · PDF 쪽수) 자동

### 5.9 공유 서버 (같은 Wi-Fi)
| 주소 | 내용 |
|---|---|
| `/` , `/?q=` | 웹 서재(검색) |
| `/s/<묶음id>` | 묶음 안 |
| `/file/<항목id>` | 내려받기 |
| `/cover/<id>`, `/scover/<id>` | 표지 |
| `/opds`, `/opds/s/<id>`, `/opds/search.xml` | OPDS 1.2 (Panels · ComicGlass · KyBook) |
- 기본 인증. **앱 계정 이름 · 비밀번호로 들어오면 그 계정 권한 그대로**, 공용 아이디는 고른 계정과 같은 범위. 숨김은 언제나 빠짐. 접속 로그. HTTP(같은 망 전용)
- 로그인 확인은 해시가 느려서 결과를 잠깐 기억

### 5.10 휴대용 모드 (USB)
- 실행 파일 옆에 `arariflex_data` 폴더가 있으면 지원/문서/캐시 폴더를 모두 그 안으로(`PathProviderPlatform.instance` 교체), 설정은 `settings.json`(300ms 모아 쓰기)
- 설정 › 정보 › "휴대용으로 만들기" 가 지금 데이터를 복사. 설치판(Program Files)은 불가 → 포터블 zip 판 사용

### 5.11 AI 도우미 (선택)
- Claude API 키를 넣으면: 글자 뜻풀이, 원제 찾기, 묶음 정보 채우기. 없으면 메뉴만 숨김

## 6. 화면 배치
| 폭 | 배치 |
|---|---|
| ≥ 840 (PC · 가로 태블릿) | 위 작업 줄 + 왼쪽 사이드바 + 가운데 목록 + 상세 패널 + 아래 상태 막대 |
| < 840 (휴대폰 · 세로 태블릿) | 앱바 + 서랍 + 아래 탭 |
| ≥ 900 | 설정 · 공유 · 메타데이터 · 가져오기 창은 두 칸 |
| ≥ 1200 | 텍스트 뷰어 목차 패널을 처음부터 열기 |
- 설정 9분류: 일반 · 라이브러리* · 파일 처리* · 뷰어 · 메타데이터 검색 및 API* · AI 도우미* · 계정 · 보안 · 읽어주기 · 글자 인식 · 정보 (*관리자만)
- 테마: 어두운(기본) / 밝은. 강조색 빨강, 로고는 코드로 그림(ARARI + 빨간 기울임 Flex + 물결 + A 안 재생 ▶)

## 7. 설정 키 (Prefs)
`libraryFolders watchFolders libraryRoot defaultStorage moveFiles organizePattern autoGroup iosDocs`
`kakaoKey naverId naverSecret googleBooksKey aiKey aiModel`
`coverSize lightMode viewMode detailOpen lastUserId hiddenPwHash hiddenPwSalt`
`readerFont readerFontSize readerLineHeight readerParagraphGap readerMaxWidth readerTheme epubOriginal tapToTurn`
`comicMode comicRtl comicCoverAlone viewerFit viewerSlider viewerImmersive viewerArrowNatural viewerEffect slideshowSeconds`
`videoHwdec subtitleSize videoRate`
`ttsVoice ttsDialogueVoice ttsThoughtVoice ttsRate ttsSplit ttsAutoCast ttsAlternate ttsBgm ttsBgmVolume spk_<책id>(인물 목소리 JSON)`
`shareAsUser sharePort shareUser sharePassword`

## 8. 네이티브 채널
| 채널 | 메서드 | 플랫폼 |
|---|---|---|
| `mediashelf/tts` | voices · speak · stop · **render**(파일로) | Android(Kotlin) · iOS/macOS(Swift) |
| `mediashelf/audio` | encodeM4a(src, dst) | Android · iOS/macOS |
| `mediashelf/ocr` | recognize(path) | Android(ML Kit) · iOS/macOS(Vision) |
| `mediashelf/bg` | start(title) · stop | Android (ReadAloudService) |
| `mediashelf/storage` | hasAllFilesAccess · requestAllFilesAccess | Android |
| `mediashelf/open` | takeFile (다른 앱에서 연 파일, content:// 는 앱 폴더로 복사) | Android |
- Android 권한: INTERNET, READ_EXTERNAL_STORAGE(≤32), MANAGE_EXTERNAL_STORAGE(폴더 등록 때만 요청), FOREGROUND_SERVICE(+MEDIA_PLAYBACK), WAKE_LOCK, POST_NOTIFICATIONS
- macOS 샌드박스 끔(폴더 · 7-Zip · say 사용), iOS 는 파일 앱 공유(UIFileSharingEnabled, LSSupportsOpeningDocumentsInPlace)

## 9. 빌드 · 배포 (GitHub Actions)
| 잡 | 하는 일 |
|---|---|
| windows | analyze(오류 0) · 단위 테스트 · 릴리스 빌드 · 7-Zip/VC++/eSpeak NG 동봉 · Inno Setup 설치파일 + 포터블 zip |
| screenshots | Windows 에서 통합 테스트(샘플 서재로 주요 화면 캡처 + 아래 검사) → `screenshots` 브랜치 |
| android / android-screens | APK(서명) / 에뮬레이터(API 34)에서 같은 통합 테스트 → `screenshots-android` |
| macos / ios | 앱 빌드 / 시뮬레이터 통합 테스트 → `screenshots-macos` · `screenshots-ios` |
| package | 모든 결과 + 소스 + 문서를 한 묶음으로, 릴리스(태그)면 Releases 에 올림 |

## 10. 받아들이는 기준 (통합 테스트 `CHECK`)
| 검사 | 기대값 |
|---|---|
| hidden | 숨긴 것 새어 나감 0, 비밀번호로 3개 드러남 |
| restricted | 막은 계정에 새어 나감 0, 휴대폰 탭에서도 막힘 |
| share | 가족 계정 그림 못 봄 · 손님 봄 · 틀린 비밀번호 401 |
| scale (2만 항목 · 2천 묶음) | 목록 첫 계산 < 150ms · 다시 0ms, 검색 < 100ms, 전체 선택 < 100ms, 5천 개 이동 < 0.5초, 전부 삭제 < 2초 |
| speakers | 영어/한국어 화자 규칙, 주고받기(짝/홀/끊김), 등장인물 목록, 자동 배역, normalize 문장 정확히 같음 |
| ambient | 6가지 배경음 30초, 소리 크기 > 500 |
| audiobook | 가짜 음성으로 표본 수 = 계산값(49200), 파일 이름, 이어 만들기 2개 건너뜀, 한 파일 합치기, 실제 기기 음성, M4A 변환 |
| pdf text | 쪽 합치기 규칙 결과 문자열 정확히 같음, 그림으로 만든 스캔 PDF 4쪽을 글자 인식, 머리글 제거 |
| file tools | CBZ PNG→JPEG 1600px · 크기 줄어듦, EPUB 표지 1200px · mimetype 맨 앞, PDF 4쪽 → 2+2 → 합쳐 4 |
| tts / ocr | 자연 음성 1초 넘고 소리 있음, 영어 OCR "fox", PaddleOCR 한국어 "풍차" |

## 11. 처음부터 만들 때 순서
1. 모델 · DB · `AppState`(판 캐시) · 폴더 스캔 · 표지 → 2. PC 서재 화면 · 묶음 · 자동 묶기 → 3. 뷰어 4종 → 4. 사용자 · 권한 · 숨김 →
5. 가져오기 창 · 파일 도구 → 6. 메타데이터 · 공유 서버 → 7. 소리 내어 읽기(기기 음성 → Supertonic → 화자 → Kokoro) → 8. OCR →
9. 오디오북 · 배경음 · 취침 타이머 → 10. Android(채널 · 서비스) → 11. macOS · iOS(플러그인) → 12. 휴대용 · 패키지 · 통합 테스트
