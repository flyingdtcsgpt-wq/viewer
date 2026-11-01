# MediaShelf

책(EPUB·PDF·TXT), 만화(CBZ·ZIP·CBR), 그림(JPG·PNG·WEBP 등), 영상(MP4·MKV 등)을 한 곳에서 관리하는 로컬 라이브러리 앱입니다.
**Flutter** 하나의 코드로 Windows → Android → iOS/macOS 순서로 지원합니다.

## 왜 Flutter인가
| 요구사항 | Flutter에서 |
|---|---|
| Windows 먼저, 그다음 Android, Apple | 한 코드베이스로 Windows / Android / iOS / macOS 빌드 |
| 다양한 해상도 | 폭 기준 반응형: 휴대폰(<600) 하단 탭 · 태블릿 접힌 사이드바 · 데스크톱(≥1100) 펼친 사이드바 + 태그 패널 |
| PDF 커버 | `pdfrx` (PDFium) – 전 플랫폼 |
| 영상 썸네일 | `fc_native_video_thumbnail` – Windows/Android/iOS/macOS 네이티브 |
| 로컬 DB | SQLite (`sqflite` + 데스크톱 `sqflite_common_ffi`) |

## 현재 구현된 기능 (v0.1 MVP)
- **폴더 등록 → 하위 폴더까지 자동 스캔** (원본 위치 참조, 파일을 건드리지 않음)
- **파일 가져오기**: 설정에 따라 *원본 참조* 또는 *라이브러리 폴더로 이동/복사*
- **정리 규칙**: `{kind}/{author}/{series}/{title}` 처럼 폴더 구조와 파일명 자동 정리 (이름 충돌 처리, 다른 드라이브면 복사 후 삭제)
- **커버 자동 생성**: EPUB 내장 커버, CBZ/ZIP 첫 이미지, PDF 첫 페이지, 영상 프레임, 이미지는 원본 그대로
- **EPUB 내장 정보 읽기**: 제목·저자·출판사·ISBN·소개
- **인터넷에서 책 정보 가져오기**: Kakao 책 검색(한국 도서, 키 필요) + Google Books + Open Library 동시 검색 → 고르면 정보와 커버를 채움
- **직접 입력/수정**: 제목, 저자, 출판사, ISBN, 시리즈, 연도, 태그, 메모, 별점, 즐겨찾기, 커버 이미지 직접 지정
- **검색·필터·정렬**: 종류별 / 태그 / 즐겨찾기, 제목·저자·태그·파일명 검색
- **중복 / 누락 확인**: 원본이 사라진 항목 표시, 같은 이름+크기 파일 묶기
- **기본 앱으로 열기**, Windows 탐색기에서 위치 열기
- **읽던 위치 자동 저장** → 커버 아래 진행 막대, "이어읽기 / 이어보기", *최근 읽은순* 정렬
- 카드 클릭 = 바로 보기, ⓘ 버튼 / 오른쪽 클릭 / 길게 누르기 = 정보 편집

### 내장 뷰어 (v0.2)
**텍스트 (TXT · EPUB · PDF)**
- TXT 인코딩 자동 감지: UTF-8 / UTF-16 / **CP949(EUC-KR)**
- TXT 목차 자동 인식 ("제1장", "1화", "프롤로그", "Chapter 3" …), EPUB 목차(nav / ncx)
- EPUB 본문 + 삽화, 제목/인용 스타일
- 글자 크기 · 줄 간격 · 문단 간격 · 본문 폭, 테마 4종(흰색/세피아/회색/검정)
- 본문 검색(Ctrl+F), 진행 슬라이더, 화면 좌/우 터치·PgUp/PgDn·Space 로 넘김
- 수 MB 소설도 문단 단위 지연 렌더링 + 별도 스레드에서 읽기라 빠르게 열림
- PDF: 페이지 이동/확대, 마지막 페이지 기억

**그림 · 만화**
- 그림: 좌우 넘기기(현재 목록 기준), 휠/두 손가락 확대, 더블탭 확대, 슬라이드쇼(Space)
- 만화(CBZ/ZIP): 한 쪽 / 두 쪽 펼침(표지 따로) / 세로 스크롤(웹툰), 오른쪽→왼쪽 넘김 전환

**영상**
- media_kit(libmpv) – 대부분 코덱·자막 지원, 전체화면, 키보드 조작
- 이어보기(마지막 위치 복원), 배속 0.5~3x, **A-B 구간 반복**, 이전/다음 영상, 끝나면 다음 영상 자동 재생
- **AI 도우미 (선택)**: Claude API 키를 넣으면
  - 지저분한 파일명 → 제목/저자/시리즈 추출
  - 태그(장르) 추천
  - "AI 사서" 채팅 – 내 라이브러리에 대해 질문
- 다크 모드, 커버 크기 슬라이더

## 실행 방법 (Windows)
준비물: [Flutter SDK](https://docs.flutter.dev/get-started/install/windows/desktop) 최신 stable (3.47 이상), Visual Studio 2022 + "C++를 사용한 데스크톱 개발" 워크로드.

이 폴더에서 처음 한 번 플랫폼 폴더를 생성합니다:

```bash
flutter create --platforms=windows,android,ios,macos --org com.mediashelf .
```

```bash
flutter pub get
```

```bash
flutter run -d windows
```

> 첫 Windows 빌드 때 영상용 libmpv 를 자동으로 내려받으므로 인터넷 연결이 필요합니다.

배포용 빌드: `flutter build windows` → `build\windows\x64\runner\Release\` 폴더 전체를 배포.

## 폴더 구조
```
lib/
  main.dart                  앱 시작, 테마
  app_state.dart             라이브러리 상태 (스캔, 필터, 정리, 중복 확인)
  models/media_item.dart     항목 모델, 지원 확장자
  db/library_db.dart         SQLite
  services/
    cover_service.dart       커버/썸네일 생성 (EPUB·CBZ·PDF·영상)
    metadata_service.dart    Kakao / Google Books / Open Library 검색
    organizer.dart           정리 규칙 → 이동/복사
    ai_service.dart          Claude API 도우미 (선택)
    settings.dart            설정 저장
  ui/
    home_page.dart           반응형 메인 화면 + 그리드
    cover_tile.dart          커버 카드
    detail_page.dart         상세/편집
    metadata_search_dialog.dart
    settings_page.dart
    ai_chat_sheet.dart
    viewers/
      open_item.dart           종류별 뷰어 연결
      text_reader_page.dart    TXT / EPUB
      pdf_reader_page.dart
      image_viewer_page.dart
      comic_reader_page.dart   CBZ / ZIP
      video_player_page.dart
  services/text_document.dart  TXT 인코딩 감지, EPUB → 문단 블록 변환
```

## 로드맵
**1단계 – Windows 완성도**
- 드래그 앤 드롭 가져오기 (`desktop_drop`), 폴더 실시간 감시
- 텍스트: 책갈피 여러 개, 쪽 넘김(페이지) 모드, 글꼴 선택, TTS 읽어주기
- 영상: 출연자/장르 필드, 구간 즐겨찾기 저장, 썸네일 타임라인
- CBR/RAR/7Z 열기 (현재는 시스템 앱으로 넘김), 이미지 폴더를 만화처럼 보기
- 컬렉션(책장), 다중 선택 일괄 편집/일괄 정보 가져오기
- 알라딘 TTB API (국내 도서 정보 보강)

**2단계 – Android**
- 저장소 권한: Android 11+ 에서 임의 폴더 스캔은 `MANAGE_EXTERNAL_STORAGE` 또는 SAF 폴더 접근 필요 (`AndroidManifest.xml`)
- 휴대폰 레이아웃은 이미 대응됨 (하단 탭, 2~3열 그리드)

**3단계 – iOS / macOS**
- iOS는 샌드박스라 "앱으로 가져오기 / 파일 앱 폴더 접근" 방식, macOS는 보안 범위 북마크 필요

**공통 / 이후**
- PC ↔ 휴대폰 라이브러리 동기화 (로컬 Wi-Fi 서버, WebDAV/OPDS)
- AI: 커버 이미지로 책 찾기(비전), 중복 판별, 줄거리 요약
