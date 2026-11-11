import 'dart:convert';

import 'package:flutter/foundation.dart';
import '../models/media_item.dart';
import 'portable.dart';

class Settings extends ChangeNotifier {
  late Prefs _p;

  /// 위젯 밖(뷰어 고르기 등)에서 설정을 읽을 때
  static late Settings instance;

  Future<void> load() async {
    _p = await Prefs.open();
    instance = this;
  }

  /// 지금 설정 값 전부 (휴대용으로 옮길 때)
  Map<String, Object?> exportAll() => _p.all();

  /// EPUB 표시 방식: true = 원본 스타일(출판사 CSS 그대로, Windows), false = 읽기 최적화
  bool get epubOriginal => _p.getBool('epubOriginal') ?? false;
  set epubOriginal(bool v) => _set(() => _p.setBool('epubOriginal', v));
  String epubPosition(int itemId) => _p.getString('epubpos_$itemId') ?? '0:0';
  void setEpubPosition(int itemId, String v) => _p.setString('epubpos_$itemId', v);

  /// 등록한 라이브러리 폴더들 (경로 · 별칭 · 그룹, 순서 유지)
  List<LibraryFolder> get libraryFolders {
    final raw = _p.getString('libraryFolders');
    if (raw == null) {
      // 예전 버전: 경로 목록만 있었음
      return (_p.getStringList('watchFolders') ?? []).map((e) => LibraryFolder(e)).toList();
    }
    return (jsonDecode(raw) as List).map((e) => LibraryFolder.fromJson(e as Map<String, dynamic>)).toList();
  }

  set libraryFolders(List<LibraryFolder> v) => _set(() => _p.setString('libraryFolders', jsonEncode(v.map((e) => e.toJson()).toList())));

  List<String> get watchFolders => libraryFolders.map((e) => e.path).toList();
  set watchFolders(List<String> v) {
    final old = {for (final f in libraryFolders) f.path: f};
    libraryFolders = [for (final p in v) old[p] ?? LibraryFolder(p)];
  }

  // ---------- 메타데이터 검색 소스 ----------
  /// 소스 이름: kakao, naver, google, openlibrary
  bool sourceEnabled(String name) => _p.getBool('src_$name') ?? true;
  void setSourceEnabled(String name, bool v) => _set(() => _p.setBool('src_$name', v));
  String get naverId => _p.getString('naverId') ?? '';
  set naverId(String v) => _set(() => _p.setString('naverId', v));
  String get naverSecret => _p.getString('naverSecret') ?? '';
  set naverSecret(String v) => _set(() => _p.setString('naverSecret', v));

  /// 이동/복사 대상 라이브러리 폴더 (managed 모드)
  /// iOS 앱 Documents 경로 (업데이트로 바뀌었는지 알려고)
  String? get iosDocs => _p.getString('iosDocs');
  set iosDocs(String? v) => _set(() => v == null ? _p.remove('iosDocs') : _p.setString('iosDocs', v));
  String? get libraryRoot => _p.getString('libraryRoot');
  set libraryRoot(String? v) =>
      _set(() => v == null ? _p.remove('libraryRoot') : _p.setString('libraryRoot', v));

  StorageMode get defaultStorage =>
      StorageMode.values.byName(_p.getString('defaultStorage') ?? StorageMode.reference.name);
  set defaultStorage(StorageMode v) => _set(() => _p.setString('defaultStorage', v.name));

  /// managed 모드에서 true = 이동, false = 복사
  bool get moveFiles => _p.getBool('moveFiles') ?? false;
  set moveFiles(bool v) => _set(() => _p.setBool('moveFiles', v));

  /// 정리 규칙. 사용 가능: {kind} {author} {series} {title} {year}
  String get organizePattern => _p.getString('organizePattern') ?? '{kind}/{author}/{title}';
  set organizePattern(String v) => _set(() => _p.setString('organizePattern', v));

  /// 메타데이터 / AI 키 (선택)
  String get kakaoKey => _p.getString('kakaoKey') ?? '';
  set kakaoKey(String v) => _set(() => _p.setString('kakaoKey', v));
  String get googleBooksKey => _p.getString('googleBooksKey') ?? '';
  set googleBooksKey(String v) => _set(() => _p.setString('googleBooksKey', v));
  String get aiKey => _p.getString('aiKey') ?? '';
  set aiKey(String v) => _set(() => _p.setString('aiKey', v));
  String get aiModel => _p.getString('aiModel') ?? 'claude-haiku-5-5';
  set aiModel(String v) => _set(() => _p.setString('aiModel', v));

  double get coverSize => _p.getDouble('coverSize') ?? 210;
  set coverSize(double v) => _set(() => _p.setDouble('coverSize', v));

  /// 기본은 어두운(넷플릭스풍) 화면. 켜면 밝은 화면
  bool get lightMode => _p.getBool('lightMode') ?? false;
  set lightMode(bool v) => _set(() => _p.setBool('lightMode', v));

  // ---------- 텍스트 뷰어 ----------
  double get readerFontSize => _p.getDouble('readerFontSize') ?? 18;
  set readerFontSize(double v) => _set(() => _p.setDouble('readerFontSize', v));
  double get readerLineHeight => _p.getDouble('readerLineHeight') ?? 1.8;
  set readerLineHeight(double v) => _set(() => _p.setDouble('readerLineHeight', v));
  double get readerParagraphGap => _p.getDouble('readerParagraphGap') ?? 0.6;
  set readerParagraphGap(double v) => _set(() => _p.setDouble('readerParagraphGap', v));
  double get readerMaxWidth => _p.getDouble('readerMaxWidth') ?? 760;
  set readerMaxWidth(double v) => _set(() => _p.setDouble('readerMaxWidth', v));
  /// 0 흰색, 1 세피아, 2 회색, 3 검정
  int get readerTheme => _p.getInt('readerTheme') ?? 0;
  set readerTheme(int v) => _set(() => _p.setInt('readerTheme', v));

  // ---------- 만화 뷰어 ----------
  /// 0 한 쪽, 1 두 쪽(펼침), 2 세로 스크롤(웹툰)
  int get comicMode => _p.getInt('comicMode') ?? 0;
  set comicMode(int v) => _set(() => _p.setInt('comicMode', v));
  /// 넘김 방향. false(기본) = 손가락을 오른쪽→왼쪽으로 밀면 다음 쪽 (일반 책),
  /// true = 왼쪽→오른쪽으로 밀면 다음 쪽 (일본 만화식)
  bool get comicRtl => _p.getBool('pageRtl') ?? false;
  set comicRtl(bool v) => _set(() => _p.setBool('pageRtl', v));

  // ---------- 뷰어 설정 (BookManager 스타일) ----------
  /// 페이지 맞춤: 0 가로, 1 높이, 2 전체(기본), 3 원본 크기
  int get viewerFit => _p.getInt('viewerFit') ?? 2;
  set viewerFit(int v) => _set(() => _p.setInt('viewerFit', v));
  /// 아래 슬라이드 탐색 바(썸네일 줄) 표시
  bool get viewerSlider => _p.getBool('viewerSlider') ?? true;
  set viewerSlider(bool v) => _set(() => _p.setBool('viewerSlider', v));
  /// 배경: false 단색, true 몰입형(현재 쪽 색으로 흐리게)
  bool get viewerImmersive => _p.getBool('viewerImmersive') ?? true;
  set viewerImmersive(bool v) => _set(() => _p.setBool('viewerImmersive', v));
  /// 좌/우 방향키: true 읽기방향에 자연스럽게, false 항상 왼쪽=이전
  bool get viewerArrowNatural => _p.getBool('viewerArrowNatural') ?? true;
  set viewerArrowNatural(bool v) => _set(() => _p.setBool('viewerArrowNatural', v));
  /// 넘김효과: 0 없음, 1 슬라이드, 2 페이드, 3 책 넘김
  int get viewerEffect => _p.getInt('viewerEffect') ?? 1;
  set viewerEffect(int v) => _set(() => _p.setInt('viewerEffect', v));

  void resetViewer() {
    for (final k in ['viewerFit', 'viewerSlider', 'viewerImmersive', 'viewerArrowNatural', 'viewerEffect', 'comicMode', 'comicCoverAlone', 'pageRtl']) {
      _p.remove(k);
    }
    notifyListeners();
  }

  // ---------- 소리 내어 읽기 ----------
  String get ttsVoice => _p.getString('ttsVoice') ?? '';
  set ttsVoice(String v) => _set(() => _p.setString('ttsVoice', v));
  String get ttsDialogueVoice => _p.getString('ttsDialogueVoice') ?? '';
  set ttsDialogueVoice(String v) => _set(() => _p.setString('ttsDialogueVoice', v));
  String get ttsThoughtVoice => _p.getString('ttsThoughtVoice') ?? '';
  set ttsThoughtVoice(String v) => _set(() => _p.setString('ttsThoughtVoice', v));
  int get ttsRate => _p.getInt('ttsRate') ?? 0;
  set ttsRate(int v) => _set(() => _p.setInt('ttsRate', v));
  /// 큰따옴표 안 = 대사, 작은따옴표 안 = 속마음 으로 나눠 다른 음성
  bool get ttsSplit => _p.getBool('ttsSplit') ?? false;
  set ttsSplit(bool v) => _set(() => _p.setBool('ttsSplit', v));

  /// 목소리를 정하지 않은 인물에게도 자동으로 서로 다른 목소리 (책 끝까지 같은 목소리)
  bool get ttsAutoCast => _p.getBool('ttsAutoCast') ?? true;
  set ttsAutoCast(bool v) => _set(() => _p.setBool('ttsAutoCast', v));
  /// 화자가 안 적힌 주고받는 대사는 앞의 두 사람을 번갈아
  bool get ttsAlternate => _p.getBool('ttsAlternate') ?? true;
  set ttsAlternate(bool v) => _set(() => _p.setBool('ttsAlternate', v));
  /// 배경음: '' 끔, 'rain' · 'waves' · 'fire' · 'white' · 'pink' · 'brown', 또는 소리 파일 경로
  String get ttsBgm => _p.getString('ttsBgm') ?? '';
  set ttsBgm(String v) => _set(() => _p.setString('ttsBgm', v));
  int get ttsBgmVolume => _p.getInt('ttsBgmVolume') ?? 25;
  set ttsBgmVolume(int v) => _set(() => _p.setInt('ttsBgmVolume', v.clamp(0, 100)));

  /// 공유 서버를 HTTPS 로 (자체 서명 인증서)
  bool get shareHttps => _p.getBool('shareHttps') ?? false;
  set shareHttps(bool v) => _set(() => _p.setBool('shareHttps', v));

  /// WebDAV · NAS 서버 목록 [{name, url, user}] (비밀번호는 저장하지 않음)
  List<Map<String, String>> get davServers {
    try {
      return [for (final m in jsonDecode(_p.getString('davServers') ?? '[]') as List) Map<String, String>.from(m as Map)];
    } catch (_) {
      return [];
    }
  }

  set davServers(List<Map<String, String>> v) => _set(() => _p.setString('davServers', jsonEncode(v)));

  /// 책마다 인물별 목소리 { 이름: 음성 }
  Map<String, String> speakerVoices(int bookId) {
    final raw = _p.getString('spk_$bookId');
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map<String, dynamic>).map((k, v) => MapEntry(k, v as String));
    } catch (_) {
      return {};
    }
  }

  void setSpeakerVoices(int bookId, Map<String, String> m) =>
      _set(() => m.isEmpty ? _p.remove('spk_$bookId') : _p.setString('spk_$bookId', jsonEncode(m)));

  /// 사용자마다 "보던 작품 · 읽는 중" 에서 뺀 항목 { 항목 id: 뺀 시각(ms) }. 그 뒤에 다시 열면 저절로 돌아온다
  Map<int, int> continueOff(int userId) {
    final raw = _p.getString('cwOff_$userId');
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map<String, dynamic>).map((k, v) => MapEntry(int.parse(k), (v as num).toInt()));
    } catch (_) {
      return {};
    }
  }

  void setContinueOff(int userId, Map<int, int> m) =>
      _set(() => m.isEmpty ? _p.remove('cwOff_$userId') : _p.setString('cwOff_$userId', jsonEncode(m.map((k, v) => MapEntry('$k', v)))));

  // ---------- 공유 서버 ----------
  /// 공용 아이디로 접속했을 때 적용할 앱 사용자 (없으면 -1 = 숨김만 빼고 전부)
  int get shareAsUser => _p.getInt('shareAsUser') ?? -1;
  set shareAsUser(int v) => _set(() => _p.setInt('shareAsUser', v));
  int get sharePort => _p.getInt('sharePort') ?? 8079;
  set sharePort(int v) => _set(() => _p.setInt('sharePort', v));
  String get shareUser => _p.getString('shareUser') ?? 'user';
  set shareUser(String v) => _set(() => _p.setString('shareUser', v));
  String get sharePassword => _p.getString('sharePassword') ?? '';
  set sharePassword(String v) => _set(() => _p.setString('sharePassword', v));

  /// 본문 글꼴: 0 기본, 1 명조, 2 고딕
  int get readerFont => _p.getInt('readerFont') ?? 0;
  set readerFont(int v) => _set(() => _p.setInt('readerFont', v));

  /// 하이라이트: 항목별 "색번호|문장" 목록
  List<(int, String)> highlights(int itemId) => (_p.getStringList('hl_$itemId') ?? []).map((e) {
        final i = e.indexOf('|');
        return (int.tryParse(e.substring(0, i)) ?? 0, e.substring(i + 1));
      }).toList();
  void addHighlight(int itemId, int color, String text) {
    final l = _p.getStringList('hl_$itemId') ?? [];
    l.add('$color|$text');
    _set(() => _p.setStringList('hl_$itemId', l));
  }

  void removeHighlight(int itemId, String text) {
    final l = (_p.getStringList('hl_$itemId') ?? []).where((e) => e.substring(e.indexOf('|') + 1) != text).toList();
    _set(() => _p.setStringList('hl_$itemId', l));
  }

  /// 책갈피 (항목별 쪽 번호 목록)
  List<int> bookmarks(int itemId) => (_p.getStringList('bm_$itemId') ?? []).map(int.parse).toList();
  void toggleBookmark(int itemId, int page) {
    final b = bookmarks(itemId);
    b.contains(page) ? b.remove(page) : b.add(page);
    b.sort();
    _set(() => _p.setStringList('bm_$itemId', b.map((e) => '$e').toList()));
  }

  /// 화면 왼쪽/오른쪽을 눌러 쪽 넘기기
  bool get tapToTurn => _p.getBool('tapToTurn') ?? true;
  set tapToTurn(bool v) => _set(() => _p.setBool('tapToTurn', v));
  bool get comicCoverAlone => _p.getBool('comicCoverAlone') ?? true;
  set comicCoverAlone(bool v) => _set(() => _p.setBool('comicCoverAlone', v));

  // ---------- 이미지 / 영상 ----------
  int get slideshowSeconds => _p.getInt('slideshowSeconds') ?? 4;
  set slideshowSeconds(int v) => _set(() => _p.setInt('slideshowSeconds', v));
  /// 영상: GPU(하드웨어) 디코딩
  bool get videoHwdec => _p.getBool('videoHwdec') ?? true;
  set videoHwdec(bool v) => _set(() => _p.setBool('videoHwdec', v));
  double get subtitleSize => _p.getDouble('subtitleSize') ?? 36;
  set subtitleSize(double v) => _set(() => _p.setDouble('subtitleSize', v));
  double get videoRate => _p.getDouble('videoRate') ?? 1.0;
  set videoRate(double v) => _set(() => _p.setDouble('videoRate', v));

  /// 스캔/가져오기 후 파일명으로 시리즈 자동 묶기
  bool get autoGroup => _p.getBool('autoGroup') ?? true;
  set autoGroup(bool v) => _set(() => _p.setBool('autoGroup', v));

  /// 숨김 목록 비밀번호 (해시만 저장)
  String get hiddenPwHash => _p.getString('hiddenPwHash') ?? '';
  String get hiddenPwSalt => _p.getString('hiddenPwSalt') ?? '';
  void setHiddenPw(String hash, String salt) {
    _p.setString('hiddenPwHash', hash);
    _p.setString('hiddenPwSalt', salt);
    notifyListeners();
  }

  /// 마지막으로 로그인한 사용자 (로그인 화면에서 미리 선택)
  int? get lastUserId => _p.getInt('lastUserId');
  set lastUserId(int? v) => _set(() => v == null ? _p.remove('lastUserId') : _p.setInt('lastUserId', v));

  /// 목록 보기 방식: 0 표, 1 격자(기본), 2 카드 목록
  int get viewMode => _p.getInt('viewMode') ?? 1;
  set viewMode(int v) => _set(() => _p.setInt('viewMode', v));

  /// 아래 상세 패널 펼침
  bool get detailOpen => _p.getBool('detailOpen') ?? true;
  set detailOpen(bool v) => _set(() => _p.setBool('detailOpen', v));

  void _set(Future<bool> Function() f) {
    f();
    notifyListeners();
  }
}

/// 라이브러리 폴더 하나: 실제 경로 + 화면에 보일 이름 + 묶을 그룹
class LibraryFolder {
  final String path;
  String alias;
  String group;
  LibraryFolder(this.path, {this.alias = '', this.group = ''});

  String get name {
    if (alias.isNotEmpty) return alias;
    final parts = path.split(RegExp(r'[\\/]')).where((e) => e.isNotEmpty);
    return parts.isEmpty ? path : parts.last;
  }

  Map<String, dynamic> toJson() => {'path': path, 'alias': alias, 'group': group};
  factory LibraryFolder.fromJson(Map<String, dynamic> m) =>
      LibraryFolder(m['path'] as String, alias: m['alias'] as String? ?? '', group: m['group'] as String? ?? '');
}
