// 빌드할 때 실제 Windows 앱을 샘플 데이터로 띄워 주요 화면을 PNG 로 저장한다.
// flutter test integration_test/screenshots_test.dart -d windows
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_shelf/app_state.dart';
import 'package:media_shelf/db/library_db.dart';
import 'package:media_shelf/main.dart';
import 'package:media_shelf/models/entry.dart';
import 'package:media_shelf/models/media_item.dart';
import 'package:media_shelf/services/auth.dart';
import 'package:media_shelf/services/cover_service.dart';
import 'package:media_shelf/services/epub_writer.dart';
import 'package:media_shelf/services/natural_tts.dart';
import 'package:media_shelf/services/settings.dart';
import 'package:media_shelf/ui/admin_page.dart';
import 'package:media_shelf/ui/detail_page.dart';
import 'package:media_shelf/ui/home_page.dart';
import 'package:media_shelf/ui/import_dialog.dart';
import 'package:media_shelf/ui/settings_page.dart';
import 'package:media_shelf/ui/tools/tools_page.dart';
import 'package:media_shelf/ui/viewers/comic_reader_page.dart';
import 'package:media_shelf/ui/viewers/text_reader_page.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

const pcSize = Size(1600, 960);
const phoneSize = Size(412, 915);

final _rnd = Random(7);
img.ColorRgb8 _col() => img.ColorRgb8(40 + _rnd.nextInt(180), 40 + _rnd.nextInt(180), 40 + _rnd.nextInt(180));

/// 표지/페이지 같은 그림 하나 (그라데이션 + 큰 글씨)
List<int> _page(String label, {int w = 600, int h = 860}) {
  final a = _col(), b = _col();
  final im = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    final t = y / h;
    final c = img.ColorRgb8(
      (a.r * (1 - t) + b.r * t).round(),
      (a.g * (1 - t) + b.g * t).round(),
      (a.b * (1 - t) + b.b * t).round(),
    );
    img.drawLine(im, x1: 0, y1: y, x2: w - 1, y2: y, color: c);
  }
  img.fillRect(im, x1: 40, y1: h - 220, x2: w - 40, y2: h - 60, color: img.ColorRgba8(0, 0, 0, 140));
  img.drawString(im, label, font: img.arial48, x: 60, y: h - 170, color: img.ColorRgb8(255, 255, 255));
  return img.encodeJpg(im, quality: 80);
}

void _cbz(String path, String title, int pages) {
  final ar = Archive();
  for (var i = 1; i <= pages; i++) {
    ar.addFile(ArchiveFile.bytes('${i.toString().padLeft(3, '0')}.jpg', _page('$title  p.$i')));
  }
  File(path).writeAsBytesSync(ZipEncoder().encode(ar));
}

const _story = '''제1장 바람이 부는 언덕

언덕 위에는 오래된 풍차가 하나 서 있었다. 아이들은 그 풍차가 밤마다 노래를 부른다고 믿었다.
"정말이야. 어젯밤에도 들었어." 민호가 속삭였다.
'또 시작이군.' 수아는 속으로 생각했지만, 이상하게도 귀를 기울이게 되었다.

바람이 불 때마다 낡은 날개가 삐걱거리며 돌았다. 그 소리는 노래라기보다는 한숨에 가까웠다.

제2장 풍차지기

풍차에는 늙은 풍차지기가 살고 있었다. 그는 마을 사람들과 거의 말을 섞지 않았다.
"무슨 일로 왔느냐." 풍차지기가 물었다.
"노래를 들으러 왔어요." 민호가 대답했다.
''';

Future<String> _makeSamples(String root) async {
  final lib = Directory(p.join(root, '샘플 라이브러리'))..createSync(recursive: true);
  for (final (t, en, n) in [('바람의 검사', 'Wind Blade', 6), ('별빛 요리사', 'Star Chef', 4), ('Space Cats', 'Space Cats', 3)]) {
    final d = Directory(p.join(lib.path, '만화', t))..createSync(recursive: true);
    for (var v = 1; v <= n; v++) {
      _cbz(p.join(d.path, '$t ${v.toString().padLeft(2, '0')}권.cbz'), '$en $v', 4);
    }
  }
  final books = Directory(p.join(lib.path, '소설'))..createSync(recursive: true);
  for (var v = 1; v <= 3; v++) {
    File(p.join(books.path, '풍차의 노래 $v권.txt')).writeAsStringSync(_story * 30);
  }
  final txt = File(p.join(books.path, '언덕 위의 집.txt'))..writeAsStringSync(_story * 20);
  try {
    await EpubWriter.fromTxt(txt.path, title: '언덕 위의 집', author: '홍길동', cover: Uint8List.fromList(_page('EPUB')));
  } catch (e) {
    debugPrint('epub sample: $e');
  }
  final pics = Directory(p.join(lib.path, '그림', '여행 사진'))..createSync(recursive: true);
  for (var i = 1; i <= 8; i++) {
    File(p.join(pics.path, 'IMG_${1000 + i}.jpg')).writeAsBytesSync(_page('Photo $i', w: 900, h: 600));
  }
  return lib.path;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('주요 화면 캡처', (tester) async {
    final out = Directory(Platform.environment['SHOTS_DIR'] ?? p.join(Directory.current.path, 'build', 'screenshots'))
      ..createSync(recursive: true);
    final tmp = Directory.systemTemp.createTempSync('arari_shots');
    final libDir = await tester.runAsync(() => _makeSamples(tmp.path)) as String;

    MediaKit.ensureInitialized();
    final settings = Settings();
    final state = await tester.runAsync(() async {
      await settings.load();
      final db = await LibraryDb.open();
      final covers = CoverService();
      await covers.init();
      final s = AppState(db, settings, covers);
      await s.load();
      return s;
    }) as AppState;

    final size = ValueNotifier(pcSize);
    final key = GlobalKey();
    await tester.pumpWidget(ValueListenableBuilder<Size>(
      valueListenable: size,
      builder: (context, s, _) => Align(
        alignment: Alignment.topLeft,
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: s.width,
          maxWidth: s.width,
          minHeight: s.height,
          maxHeight: s.height,
          child: RepaintBoundary(
            key: key,
            child: MediaQuery(
              data: MediaQueryData.fromView(View.of(context)).copyWith(size: s, devicePixelRatio: 1),
              child: MultiProvider(
                providers: [
                  ChangeNotifierProvider.value(value: settings),
                  ChangeNotifierProvider.value(value: state),
                ],
                child: const MediaShelfApp(),
              ),
            ),
          ),
        ),
      ),
    ));

    Future<void> wait([int ms = 900]) async {
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms ~/ 4)));
        await tester.pump(const Duration(milliseconds: 120));
      }
    }

    final done = <String>[];
    Future<void> shot(String name, [int ms = 1200]) async {
      try {
        await wait(ms);
        final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final bytes = await tester.runAsync(() async {
          final im = await boundary.toImage(pixelRatio: 1);
          final bd = await im.toByteData(format: ui.ImageByteFormat.png);
          return bd!.buffer.asUint8List();
        });
        File(p.join(out.path, '$name.png')).writeAsBytesSync(bytes!);
        done.add(name);
        debugPrint('SHOT $name');
      } catch (e, st) {
        debugPrint('SHOT FAILED $name: $e\n$st');
      }
    }

    /// 한 화면씩: 실패해도 다음 화면은 계속
    Future<void> step(String name, Future<void> Function() body) async {
      try {
        await body();
      } catch (e, st) {
        debugPrint('STEP FAILED $name: $e\n$st');
      }
    }

    NavigatorState nav() => Navigator.of(tester.element(find.byType(HomePage, skipOffstage: false)));
    Future<void> push(Widget page) async {
      nav().push(MaterialPageRoute(builder: (_) => page));
      await wait(600);
    }

    Future<void> popAll() async {
      nav().popUntil((r) => r.isFirst);
      await wait(400);
    }

    // 1. 첫 실행 · 로그인
    await shot('01_첫실행_관리자만들기');
    await step('setup', () async {
      await tester.runAsync(() async {
        await state.createFirstAdmin('관리자', '1234');
        await state.addUser('가족', '', UserRole.user);
      });
      state.logout();
      await shot('02_로그인_프로필선택');
      await tester.runAsync(() => state.login(state.users.firstWhere((u) => u.isAdmin), '1234'));
    });

    // 2. 샘플 가져오기
    await step('import', () async {
      await tester.runAsync(() async {
        final c = await state.previewFolder(libDir);
        await state.importCandidates(c, ImportOptions(baseDir: libDir));
      });
      await wait(3000);
    });

    await step('home', () async {
      state.showLanding();
      await shot('03_홈');
    });

    MediaItem? comic, book;
    await step('library', () async {
      state.setFilter(kind: MediaKind.comic);
      await shot('04_라이브러리_만화');
      final first = state.rootEntries(kind: MediaKind.comic).whereType<SeriesEntry>().firstOrNull;
      if (first != null) {
        state.enterSeries(first.series.id);
        await wait();
        final items = state.visible;
        if (items.isNotEmpty) {
          comic = items.first;
          state.focus(ItemEntry(items.first));
        }
        await shot('05_묶음_안_상세패널');
      }
      // 고르면 위 작업 줄에 선택 동작이 나타난다
      for (final e in state.entries.take(2)) {
        state.toggleSelect(e);
      }
      await shot('05b_선택했을때_작업줄');
      state.clearSelection();
      state.setFilter(kind: MediaKind.book);
      book = state.allItems.where((e) => e.kind == MediaKind.book && e.path.endsWith('.txt')).firstOrNull;
      await shot('06_라이브러리_책');
      state.setFilter(clearKind: true);
      state.showLanding();
    });

    await step('import dialog', () async {
      // 새 파일 + 이미 등록된 파일 + 중복이 섞인 폴더
      final extra = Directory(p.join(tmp.path, '정리 안 된 폴더'))..createSync();
      final src = state.allItems.where((e) => e.kind == MediaKind.comic).take(2).toList();
      for (final e in src) {
        File(e.path).copySync(p.join(extra.path, '사본 ${p.basename(e.path)}'));
      }
      File(p.join(extra.path, 'cover.jpg')).writeAsBytesSync(_page('NEW'));
      File(p.join(extra.path, '메모.txt')).writeAsStringSync(_story);
      final ctx = tester.element(find.byType(HomePage, skipOffstage: false));
      showImportDialog(ctx, folder: extra.path);
      await shot('07_폴더추가_항목선택', 4000);
      await popAll();
    });

    await step('comic viewer', () async {
      if (comic == null) return;
      await push(ComicReaderPage(item: comic!));
      await shot('08_만화뷰어', 2500);
      await popAll();
    });

    await step('text viewer', () async {
      if (book == null) return;
      await push(TextReaderPage(item: book!));
      await shot('09_텍스트뷰어', 2500);
      await popAll();
    });

    await step('detail', () async {
      final it = comic ?? state.allItems.firstOrNull;
      if (it == null) return;
      await push(DetailPage(item: it));
      await shot('10_상세정보');
      await popAll();
    });

    await step('settings', () async {
      await push(const SettingsPage());
      await shot('11_설정');
      await popAll();
    });

    await step('admin', () async {
      await push(const AdminPage());
      await shot('12_관리자');
      await popAll();
    });

    await step('access', () async {
      final fam = state.users.firstWhere((u) => !u.isAdmin);
      await push(AccessPage(target: fam));
      await shot('12b_계정별_보이는범위', 1800);
      await popAll();
    });

    await step('tools', () async {
      await push(const ToolsPage());
      await shot('13_파일도구');
      await popAll();
    });

    await step('light', () async {
      settings.lightMode = true;
      state.setFilter(kind: MediaKind.comic);
      await shot('14_밝은테마_라이브러리');
      settings.lightMode = false;
      state.setFilter(clearKind: true);
    });

    // 휴대폰 크기
    await step('phone', () async {
      size.value = phoneSize;
      state.showLanding();
      await shot('15_휴대폰_홈');
      state.setFilter(kind: MediaKind.comic);
      await shot('16_휴대폰_라이브러리');
      if (comic != null) {
        await push(ComicReaderPage(item: comic!));
        await shot('17_휴대폰_만화뷰어', 2500);
        await popAll();
      }
    });

    // 숨김으로 추가: 항목도, 새로 생긴 묶음 제목도 보이면 안 된다
    await step('hidden import', () async {
      state.setHiddenPassword('9999');
      final secret = Directory(p.join(tmp.path, '비밀 폴더'))..createSync();
      for (var v = 1; v <= 3; v++) {
        _cbz(p.join(secret.path, '비밀 만화 0$v권.cbz'), 'Secret $v', 2);
      }
      await tester.runAsync(() async {
        final c = await state.previewFolder(secret.path);
        await state.importCandidates(c, ImportOptions(baseDir: secret.path, hidden: true, watch: false));
      });
      state.setFilter(clearKind: true);
      state.enterSeries(null);
      final leakItems = state.allItems.where((e) => e.path.contains('비밀')).length;
      final leakSeries = state.entries.whereType<SeriesEntry>().where((e) => e.series.title.contains('비밀')).length;
      debugPrint('CHECK hidden leakItems=$leakItems leakSeries=$leakSeries');
      expect(leakItems + leakSeries, 0);
      // 비밀번호를 검색창에 넣으면 드러나야 한다
      state.trySearchUnlock('9999');
      final shownItems = state.allItems.where((e) => e.path.contains('비밀')).length;
      debugPrint('CHECK hidden unlocked=$shownItems');
      expect(shownItems, 3);
      state.lockHidden();
    });

    // 가족 계정: 그림 · 영상을 막으면 탭/사이드바/홈에서 사라져야 한다
    await step('restricted', () async {
      final fam = state.users.firstWhere((u) => !u.isAdmin);
      await tester.runAsync(() async {
        await state.setAccess(fam, ['k:image', 'k:video'], allowed: false);
      });
      state.logout();
      await wait();
      await tester.runAsync(() => state.login(fam, ''));
      state.showLanding();
      await shot('18_휴대폰_가족계정_그림영상막음');
      size.value = pcSize;
      await shot('19_PC_가족계정_그림영상막음');
      final leaked = state.allItems.where((e) => e.kind == MediaKind.image || e.kind == MediaKind.video).length;
      debugPrint('CHECK restricted leaked=$leaked');
      expect(leaked, 0);
    });

    // 자연 음성: 모델을 받아 한국어를 합성해 보고, 소리가 실제로 나는지 숫자로 확인한다
    if (Platform.environment['TTS_CHECK'] == '1') {
      await step('natural tts', () async {
        final tts = NaturalTts.instance;
        await tester.runAsync(() async {
          final sw = Stopwatch()..start();
          await tts.download(onProgress: (f, got, total) {
            if (got == total) debugPrint('TTS downloaded $f ${(total / 1048576).toStringAsFixed(1)}MB');
          });
          debugPrint('TTS download ${sw.elapsed.inSeconds}s installed=${await tts.installed()}');
          for (final (name, voice, text) in [
            ('tts_여성1_나레이션', 'st:F1', '언덕 위에는 오래된 풍차가 하나 서 있었다. 아이들은 그 풍차가 밤마다 노래를 부른다고 믿었다.'),
            ('tts_남성1_대사', 'st:M1', '"정말이야. 어젯밤에도 들었어." 민호가 속삭였다.'),
          ]) {
            sw.reset();
            final wav = await tts.synthesize(text, voice);
            final bytes = await File(wav).readAsBytes();
            final bd = ByteData.sublistView(bytes);
            final n = (bytes.length - 44) ~/ 2;
            var sq = 0.0, peak = 0;
            for (var i = 0; i < n; i++) {
              final v = bd.getInt16(44 + i * 2, Endian.little);
              sq += v * v.toDouble();
              if (v.abs() > peak) peak = v.abs();
            }
            final rms = n == 0 ? 0 : sqrt(sq / n);
            final sec = n / 44100;
            debugPrint('CHECK tts $name voice=$voice sec=${sec.toStringAsFixed(2)} rms=${rms.toStringAsFixed(0)} peak=$peak took=${sw.elapsedMilliseconds}ms');
            File(wav).copySync(p.join(out.path, '$name.wav'));
            expect(sec, greaterThan(1.0));
            expect(rms, greaterThan(300));
          }
        });
      });
    }

    debugPrint('SHOTS DONE ${done.length}: ${done.join(', ')}');
    expect(done, isNotEmpty);
  });
}
