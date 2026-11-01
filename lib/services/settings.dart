import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';

class Settings extends ChangeNotifier {
  late SharedPreferences _p;

  Future<void> load() async => _p = await SharedPreferences.getInstance();

  /// 등록한 스캔 폴더들
  List<String> get watchFolders => _p.getStringList('watchFolders') ?? [];
  set watchFolders(List<String> v) => _set(() => _p.setStringList('watchFolders', v));

  /// 이동/복사 대상 라이브러리 폴더 (managed 모드)
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

  double get coverSize => _p.getDouble('coverSize') ?? 170;
  set coverSize(double v) => _set(() => _p.setDouble('coverSize', v));

  bool get darkMode => _p.getBool('darkMode') ?? false;
  set darkMode(bool v) => _set(() => _p.setBool('darkMode', v));

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
  bool get comicRtl => _p.getBool('comicRtl') ?? true; // 일본/한국 만화: 오른쪽→왼쪽
  set comicRtl(bool v) => _set(() => _p.setBool('comicRtl', v));
  bool get comicCoverAlone => _p.getBool('comicCoverAlone') ?? true;
  set comicCoverAlone(bool v) => _set(() => _p.setBool('comicCoverAlone', v));

  // ---------- 이미지 / 영상 ----------
  int get slideshowSeconds => _p.getInt('slideshowSeconds') ?? 4;
  set slideshowSeconds(int v) => _set(() => _p.setInt('slideshowSeconds', v));
  double get videoRate => _p.getDouble('videoRate') ?? 1.0;
  set videoRate(double v) => _set(() => _p.setDouble('videoRate', v));

  void _set(Future<bool> Function() f) {
    f();
    notifyListeners();
  }
}
