# ARARIFlex (아라리플렉스)

책(EPUB · PDF · TXT), 만화(CBZ · ZIP · CBR · RAR · 7Z), 그림, 영상을 한 곳에서 관리하고 읽는 개인 라이브러리 앱.
**Windows 를 먼저** 완성하고, 같은 코드로 Android → iOS/macOS 순서로 넓힌다. (Flutter)

## 문서
- **설계 사양서(처음부터 다시 만들 수 있는 설계도)**: [docs/SPEC.md](docs/SPEC.md)
- 사용 설명서: [docs/MANUAL.md](docs/MANUAL.md)
- 개발 노트(구조 · 설계 · 결정 · CI): [docs/DEV_NOTES.md](docs/DEV_NOTES.md)
- 이어서 개발하기(빌드 방법 · 모델 받는 곳 · 인수인계): [docs/HANDOFF.md](docs/HANDOFF.md)
- 소스 설명서(파일마다 하는 일): [docs/SOURCE_GUIDE.md](docs/SOURCE_GUIDE.md)
- 개발 내역서(모든 변경 날짜순): [docs/CHANGELOG.md](docs/CHANGELOG.md)

## 받기
GitHub Actions 가 push 할 때마다 Windows · Android(휴대폰/태블릿) · macOS · iPhone/iPad 를 빌드한다.
저장소의 **Actions → 최신 실행 → Artifacts** 에서 `ARARIFlex-all-in-one`(모든 설치파일 + 소스 + 문서) 을 받는다.
GitHub 웹에서 Releases → 새 릴리스(`v0.6.0` 같은 태그)를 게시하면 같은 파일이 Releases 에 올라가 로그인 없이 받을 수 있다.

## 주요 기능 (0.6.0)
| 분야 | 기능 |
|---|---|
| 서재 | 책 · 만화 · 그림 · 영상 한 곳에, 라이브러리 폴더(그룹 · 별칭), 가져오기 창(골라 추가 · 중복 표시 · 연결/복사/이동 · 정리 규칙), 누락 검사, 2만 권에서도 빠름 |
| 묶음 | 파일명으로 시리즈 자동 묶기(01권 · 제3권 · v05 · S02E03 · 10.5권), 몇 단계든 중첩, 외전 · 극장판은 대표 아래, 보유/전체 권수 · 연재 상태 · 누락 권수 |
| 화면 | PC: 작업 줄 · 사이드바 · 격자/표/카드 · 상세 패널 · 상태 막대, 넷플릭스풍 홈, 휴대폰: 서랍 + 아래 탭, 태블릿 가로/세로, 어두운/밝은 테마 |
| 계정 | 관리자 · 가족 계정, 사용자마다 읽은 위치 · 기록, 폴더 · 종류 · 묶음 · 작품 단위 접근 권한, 숨김(검색창에 비밀번호) |
| 뷰어 | 만화(한장 · 두장 · 웹툰 · 방향 · 효과 · 썸네일 · 책갈피), TXT/EPUB(목차 · 하이라이트 · 검색 · 테마 · 글꼴 · AI 뜻풀이), PDF, 그림(슬라이드쇼), 영상(이어보기 · 자막 · 음성 트랙 · 배속 · A-B 반복) |
| 소리 내어 읽기 (소설만) | 기기 안 AI 음성(Supertonic 한국어 10종 · Kokoro 영어 28종) · 기기 음성, 서술 · 대사 · 속마음 다른 목소리, **인물별 목소리**(한국어 · 영어 화자 찾기, 자동 배역, 주고받는 대사), 취침 타이머, 화면 꺼도 계속(안드로이드), 배경음(빗소리 · 파도 · 벽난로 · 잡음 · 내 파일), 스캔 PDF 는 글자 인식으로 |
| 오디오북 | 지금 고른 목소리 그대로 장마다 / 한 파일로 M4A · WAV, 이어 만들기, 재생 목록 |
| 글자 인식 | Windows PaddleOCR 한국어 → Windows OCR, 안드로이드 ML Kit, 애플 Vision |
| 파일 도구 | 텍본 정리 · 인코딩, TXT → EPUB, **PDF → 텍스트(스캔본 OCR)**, **이미지 → PDF**, **PDF 나누기 · 합치기**, 압축 구조 정리 · 내부 파일명 · 표지, **이미지 해상도 변경**, **EPUB 용량 최적화**, 메타데이터 일괄 |
| 메타데이터 | 카카오 · 네이버 · Google Books · Open Library 통합 검색, EPUB 안 정보 자동, AI 원제 찾기(선택) |
| 공유 서버 | 같은 Wi-Fi 에서 웹 · OPDS, 앱 계정 권한 그대로, 숨김 제외 |
| 휴대용 | 앱 옆 `arariflex_data` 폴더 하나로 USB 에 담아 다른 PC 에서 그대로 |
| 오프라인 | 코덱 · 7-Zip · 런타임 · 발음기 동봉, AI 모델은 한 번 받거나 폴더에서 가져오기 |

## 개발
```bash
flutter create --platforms=windows,android --org com.mediashelf --project-name media_shelf .
flutter pub get
flutter run -d windows
```
플랫폼 폴더는 CI 에서 `flutter create` 로 만들고 `tool/patch_windows.py`, `tool/patch_android.py` 로 다듬는다.

## 화면 확인
빌드할 때마다 실제 Windows 앱을 샘플 데이터로 띄워 주요 화면을 찍고, 숨김 · 계정 권한 · 공유 서버 · 자연 음성 · 글자 인식을 자동으로 검사한다.
결과 화면과 음성 샘플은 저장소의 `screenshots` 브랜치에 올라간다.

## 다음 할 일 (선택)
- WebDAV · 휴대폰 앱 연동(QR), 공유 서버 HTTPS
- 한국어 Windows 실기에서 Windows OCR · 기기 음성 오디오북 확인 (CI 서버는 영어 Windows)
