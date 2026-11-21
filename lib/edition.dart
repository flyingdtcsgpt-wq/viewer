/// 판 구분
///
/// - 전체판(기본): PC · 안드로이드(직접 설치) · 맥 · 아이폰. 모든 기능
/// - 플레이스토어판: `flutter build appbundle --dart-define=ARARI_STORE=true`.
///   만화 · 책 · 영상 보기만 남기고(AI · NAS · 공유 서버 · 읽어주기 · 글자 인식 · 파일 도구 · 계정 · 숨김 · 그림 빼기),
///   앱 전용 "ARARIFlex" 폴더 하나를 서재로 쓰며(저장소 권한 없음), 광고가 붙는다.
library;

const bool kStore = bool.fromEnvironment('ARARI_STORE');

/// 플레이스토어판 개인정보 처리방침 주소 (스토어 등록정보에도 같은 주소를 넣는다)
const String privacyPolicyUrl = String.fromEnvironment('PRIVACY_URL',
    defaultValue: 'https://github.com/flyingdtcsgpt-wq/viewer/blob/main/docs/store/PRIVACY.md');
