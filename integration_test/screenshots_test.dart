// 빌드할 때 실제 Windows 앱을 샘플 데이터로 띄워 주요 화면을 PNG 로 저장한다.
// flutter test integration_test/screenshots_test.dart -d windows
import 'dart:convert';
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
import 'package:media_shelf/services/ambient.dart';
import 'package:media_shelf/services/speakers.dart';
import 'package:media_shelf/services/audiobook.dart';
import 'package:media_shelf/services/auth.dart';
import 'package:media_shelf/services/cover_service.dart';
import 'package:media_shelf/services/epub_writer.dart';
import 'package:media_shelf/services/file_tools.dart';
import 'package:media_shelf/services/image_pdf.dart';
import 'package:media_shelf/services/kokoro_tts.dart';
import 'package:media_shelf/services/natural_tts.dart';
import 'package:media_shelf/services/ocr_service.dart';
import 'package:media_shelf/services/paddle_ocr.dart';
import 'package:media_shelf/services/pdf_text.dart';
import 'package:media_shelf/services/settings.dart';
import 'package:media_shelf/services/tts_service.dart';
import 'package:media_shelf/services/share_cert.dart';
import 'package:media_shelf/services/webdav_client.dart';
import 'package:media_shelf/ui/admin_page.dart';
import 'package:media_shelf/ui/detail_page.dart';
import 'package:media_shelf/ui/home_page.dart';
import 'package:media_shelf/ui/import_dialog.dart';
import 'package:media_shelf/ui/settings_page.dart';
import 'package:media_shelf/ui/tools/tools_page.dart';
import 'package:media_shelf/ui/viewers/comic_reader_page.dart';
import 'package:media_shelf/ui/viewers/text_reader_page.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:path_provider/path_provider.dart';
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
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // 안드로이드: 테스트가 끝나면 앱이 지워지므로 결과 파일은 드라이버로 보낸다 (test_driver/integration_test.dart)
  final files = <String, String>{};
  binding.reportData = {'files': files}; // 테스트가 중간에 멈춰도 그때까지 찍은 것은 보낸다

  testWidgets('주요 화면 캡처', (tester) async {
    // 안드로이드: 앱 내부 files/shots 에 저장 → CI 가 adb run-as 로 꺼낸다
    final out = Platform.isAndroid || Platform.isIOS
        ? Directory(p.join((await tester.runAsync(getApplicationSupportDirectory))!.path, 'shots'))
        : Directory(Platform.environment['SHOTS_DIR'] ?? p.join(Directory.current.path, 'build', 'screenshots'));
    out.createSync(recursive: true);
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
        if (Platform.isAndroid || Platform.isIOS) files['$name.png'] = base64.encode(bytes);
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
      // 휴대폰 화면에서 읽어주기 막대가 넘치지 않는지
      if (book != null) {
        await push(TextReaderPage(item: book!, readAloud: true));
        await wait(1500);
        await shot('17b_휴대폰_텍스트_읽어주기', 1500);
        await popAll();
      }
    });

    // 태블릿 (iPad 11인치 · 안드로이드 태블릿 크기): 가로는 PC 배치, 세로는 휴대폰 배치
    await step('tablet', () async {
      size.value = const Size(1194, 834);
      state.showLanding();
      await shot('20_태블릿_가로_홈');
      state.setFilter(kind: MediaKind.comic);
      await shot('21_태블릿_가로_라이브러리');
      size.value = const Size(834, 1194);
      state.showLanding();
      await shot('22_태블릿_세로_홈');
      if (comic != null) {
        await push(ComicReaderPage(item: comic!));
        await shot('23_태블릿_세로_만화뷰어', 2500);
        await popAll();
      }
      if (book != null) {
        await push(TextReaderPage(item: book!, readAloud: true));
        await shot('24_태블릿_세로_텍스트_읽어주기', 2000);
        await popAll();
      }
      size.value = phoneSize;
      state.setFilter(clearKind: true);
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

    // 영어 원서용 Kokoro (Windows · 발음 엔진이 있을 때)
    if (Platform.isWindows && (Platform.environment['TTS_CHECK'] == '1' || const bool.fromEnvironment('TTS_CHECK'))) {
      await step('kokoro', () async {
        await tester.runAsync(() async {
          final k = KokoroTts.instance;
          debugPrint('CHECK kokoro espeak=${await k.espeakReady()}');
          final ph = await k.phonemize('The quick brown fox.');
          debugPrint('CHECK kokoro phonemes="$ph"');
          final sw = Stopwatch()..start();
          await k.download();
          debugPrint('CHECK kokoro download ${sw.elapsed.inSeconds}s installed=${await k.installed()}');
          final voices = await k.voices();
          debugPrint('CHECK kokoro voices ${voices.length}: ${voices.take(6).map(KokoroTts.label).join(', ')}');
          sw.reset();
          final wav = await k.synthesize('It was a bright cold day in April, and the clocks were striking thirteen.', 'kk:af_heart');
          final bytes = await File(wav).readAsBytes();
          final bd = ByteData.sublistView(bytes);
          final n = (bytes.length - 44) ~/ 2;
          var sq = 0.0;
          for (var i = 0; i < n; i++) {
            final v = bd.getInt16(44 + i * 2, Endian.little);
            sq += v * v.toDouble();
          }
          final rms = n == 0 ? 0 : sqrt(sq / n);
          debugPrint('CHECK kokoro sec=${(n / 24000).toStringAsFixed(2)} rms=${rms.toStringAsFixed(0)} took=${sw.elapsedMilliseconds}ms');
          File(wav).copySync(p.join(out.path, 'tts_kokoro_영어_af_heart.wav'));
          expect(n / 24000, greaterThan(2.0));
          expect(rms, greaterThan(300));
          // 두 번째부터는 모델을 이미 읽었으니 순수 합성 시간
          sw.reset();
          final w2 = await k.synthesize('The quick brown fox jumps over the lazy dog, and then it runs away.', 'kk:am_adam');
          final n2 = ((await File(w2).length()) - 44) ~/ 2;
          debugPrint('CHECK kokoro again sec=${(n2 / 24000).toStringAsFixed(2)} took=${sw.elapsedMilliseconds}ms');
        });
      });
    }

    // 공유 서버: 가족 계정으로 로그인하면 막힌 그림이 안 보여야 하고, 공용 아이디(제한 없음)는 보여야 한다
    await step('share server access', () async {
      await tester.runAsync(() async {
        final fam = state.users.firstWhere((u) => !u.isAdmin);
        await state.updateUser(fam, newPassword: '1111');
        state.share
          ..user = 'guest'
          ..password = 'pw'
          ..asUserId = null;
        await state.share.start(18079);
        Future<String> get(String id, String pw) async {
          final c = HttpClient();
          try {
            final rq = await c.getUrl(Uri.parse('http://127.0.0.1:18079/?q=IMG'));
            rq.headers.set(HttpHeaders.authorizationHeader, 'Basic ${base64.encode(utf8.encode('$id:$pw'))}');
            final rs = await rq.close();
            return '${rs.statusCode} ${await rs.transform(utf8.decoder).join()}';
          } finally {
            c.close(force: true);
          }
        }

        final asFamily = await get(fam.name, '1111');
        final asGuest = await get('guest', 'pw');
        final wrong = await get('guest', 'nope');
        await state.share.stop();
        final famSees = asFamily.contains('IMG_'), guestSees = asGuest.contains('IMG_');
        debugPrint('CHECK share family=${asFamily.substring(0, 3)} seesImages=$famSees guest=${asGuest.substring(0, 3)} seesImages=$guestSees wrong=${wrong.substring(0, 3)}');
        expect(famSees, isFalse);
        expect(guestSees, isTrue);
        expect(wrong.startsWith('401'), isTrue);
      });
    });

    // 보던 목록에서 빼기: 빼면 사라지고, 다시 열면(진행 저장) 돌아온다
    await step('continue list', () async {
      await tester.runAsync(() async {
        final it = state.allItems.firstWhere((e) => e.kind != MediaKind.video);
        await state.saveProgress(it, '1', 0.4);
        state.refresh();
        final before = state.continueWatching.contains(it);
        state.removeFromContinue([it]);
        final afterRemove = state.continueWatching.contains(it);
        final inReading = state.isInProgress(it);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await state.saveProgress(it, '2', 0.45); // 다시 열어서 읽음
        state.refresh();
        final back = state.continueWatching.contains(it);
        debugPrint('CHECK continue before=$before removed=${!afterRemove} reading=$inReading back=$back');
        expect(before, isTrue);
        expect(afterRemove, isFalse);
        expect(inReading, isFalse);
        expect(back, isTrue);
        await state.markFinished(it, false);
      });
    });

    // WebDAV · HTTPS: 우리 서버를 WebDAV 로 둘러보고 받기, 이어받기(Range), 가족 계정 권한, HTTPS(자체 서명), 다른 서버 응답 읽기
    await step('webdav', () async {
      await tester.runAsync(() async {
        final fam = state.users.firstWhere((u) => !u.isAdmin);
        state.share
          ..user = 'guest'
          ..password = 'pw'
          ..asUserId = null;
        await state.share.start(18079);
        try {
          final dav = WebDavClient('http://127.0.0.1:18079/dav/', user: 'guest', password: 'pw');
          final top = await dav.list(dav.base.path);
          final files = await dav.walk(dav.base.path, (e) => kindForPath(e.name) != null);
          files.sort((a, b) => a.size.compareTo(b.size));
          final small = files.firstWhere((e) => e.size > 100);
          final to = p.join((await getTemporaryDirectory()).path, 'dav_get', small.name);
          await dav.download(small, to);
          final orig = state.rawItems.firstWhere((e) => e.fileName == small.name);
          final same = File(to).readAsBytesSync().length == File(orig.path).lengthSync();
          // 이어받기: 앞 10바이트만
          final c = HttpClient();
          final rq = await c.getUrl(dav.uriOf(small.path));
          rq.headers.set(HttpHeaders.authorizationHeader, 'Basic ${base64.encode(utf8.encode('guest:pw'))}');
          rq.headers.set(HttpHeaders.rangeHeader, 'bytes=0-9');
          final rs = await rq.close();
          final part = await rs.fold<List<int>>([], (a, b) => a..addAll(b));
          c.close(force: true);
          final famDav = WebDavClient('http://127.0.0.1:18079/dav/', user: fam.name, password: '1111');
          final famImages = (await famDav.walk(famDav.base.path, (e) => kindForPath(e.name) == MediaKind.image)).length;
          final guestImages = files.where((e) => kindForPath(e.name) == MediaKind.image).length;
          debugPrint('CHECK webdav top=${top.length} dirs=${top.where((e) => e.dir).length} files=${files.length} '
              'got=${small.name} same=$same range=${rs.statusCode}/${part.length} guestImages=$guestImages famImages=$famImages');
          expect(top, isNotEmpty);
          expect(same, isTrue);
          expect(rs.statusCode, 206);
          expect(part.length, 10);
          expect(famImages, 0);
          expect(guestImages, greaterThan(0));
        } finally {
          await state.share.stop();
        }

        // HTTPS: 처음 켤 때 인증서를 만든다
        final sw = Stopwatch()..start();
        await state.share.start(18443, https: true);
        try {
          final made = sw.elapsedMilliseconds;
          final ok = await WebDavClient('https://127.0.0.1:18443/dav/', user: 'guest', password: 'pw', insecure: true).list('/dav/');
          var strictFails = false;
          try {
            await WebDavClient('https://127.0.0.1:18443/dav/', user: 'guest', password: 'pw').list('/dav/');
          } on WebDavError {
            strictFails = true;
          }
          debugPrint('CHECK https start=${made}ms list=${ok.length} strictRejects=$strictFails finger=${await ShareCert.fingerprint()}');
          expect(ok, isNotEmpty);
          expect(strictFails, isTrue);
        } finally {
          await state.share.stop();
        }

        // 다른 서버(시놀로지 · Nextcloud 꼴) 응답 읽기
        final parsed = WebDavClient.parse('''<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">
<d:response><d:href>/books/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
<d:response><d:href>https://nas:5006/books/%EB%A7%8C%ED%99%94/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
<d:response><d:href>/books/a%20b.epub</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>1234</d:getcontentlength></d:prop></d:propstat></d:response>
</d:multistatus>''', '/books/');
        debugPrint('CHECK webdav parse=${parsed.map((e) => '${e.name}|${e.path}|${e.dir}|${e.size}').toList()}');
        expect(parsed.map((e) => (e.name, e.path, e.dir, e.size)).toList(), [('만화', '/books/만화/', true, 0), ('a b.epub', '/books/a b.epub', false, 1234)]);
      });
    });

    // 큰 서재: 2만 권 · 2천 묶음을 넣고 자주 하는 동작의 시간을 잰다 (PC 에서만)
    if (Platform.isWindows || Platform.isMacOS) {
      await step('scale', () async {
        await tester.runAsync(() async {
          final sw = Stopwatch()..start();
          final made = <MediaItem>[];
          final seriesIds = <int>[];
          for (var g = 0; g < 2000; g++) {
            final se = await state.createSeries('큰서재 시리즈 $g');
            seriesIds.add(se.id!);
          }
          for (var i = 0; i < 20000; i++) {
            made.add(MediaItem(
              path: p.join(tmp.path, 'scale', 'big_${i ~/ 10}', '큰서재 $i권.cbz'),
              kind: i % 5 == 0 ? MediaKind.book : MediaKind.comic,
              title: '큰서재 책 $i',
              size: 1000 + i,
            )
              ..seriesId = seriesIds[i % 2000]
              ..volume = (i ~/ 2000 + 1).toDouble());
          }
          await state.db.insertMany(made);
          await state.load();
          debugPrint('CHECK scale insert+load ${sw.elapsedMilliseconds}ms items=${state.rawItems.length}');
          int t(void Function() f) {
            final w = Stopwatch()..start();
            f();
            return w.elapsedMilliseconds;
          }

          state.setFilter(kind: MediaKind.comic);
          final first = t(() => state.entries.length);
          final again = t(() => state.entries.length);
          final counts = t(() {
            for (final k in [null, ...MediaKind.values]) {
              state.count(k);
            }
            for (final c in Collection.values) {
              state.collectionCount(c);
            }
          });
          final e0 = state.entries.first;
          final focus = t(() {
            state.focus(e0);
            state.entries.length;
            state.count(null);
          });
          state.query = '시리즈 19';
          final search = t(() => state.entries.length);
          state.query = '';
          state.selectAll();
          final sel = state.selected.length;
          final selMs = t(() => state.selectedItemsDeep.length);
          state.clearSelection();
          debugPrint('CHECK scale entries first=${first}ms cached=${again}ms counts=${counts}ms focus=${focus}ms search=${search}ms selectAll($sel) items=${selMs}ms');
          // 숨김과 상관없는 대량 이동: 운영체제 숨김 명령을 부르지 않아야 빠르다
          final w = Stopwatch()..start();
          await state.moveItems(made.take(5000), seriesIds.first);
          debugPrint('CHECK scale move5000=${w.elapsedMilliseconds}ms');
          // 가족 계정(제한)으로 보기
          final fam = state.users.firstWhere((u) => !u.isAdmin);
          await state.setAccess(fam, ['k:image', 's:${seriesIds[5]}'], allowed: false);
          final view = await state.accessFor(fam);
          final rv = t(() => state.rawItems.where(view.item).length);
          debugPrint('CHECK scale restricted-pass=${rv}ms');
          state.setFilter(clearKind: true);
          // 묶음 없는 4천 개를 시리즈로 자동 묶기
          final loose = [
            for (var i = 0; i < 4000; i++)
              MediaItem(path: p.join(tmp.path, 'scale', 'loose', '자동묶기 작품 ${i ~/ 10} ${(i % 10 + 1).toString().padLeft(2, '0')}권.cbz'), kind: MediaKind.comic, title: '자동묶기 $i'),
          ];
          await state.db.insertMany(loose);
          await state.load();
          final w3 = Stopwatch()..start();
          final grouped = await state.autoGroup();
          debugPrint('CHECK scale autoGroup4000 moved=$grouped took=${w3.elapsedMilliseconds}ms');
          made.addAll(state.rawItems.where((e) => e.path.contains('${p.separator}loose${p.separator}')));
          // 정리: 큰 서재 항목은 지운다 (다음 단계 화면에 섞이지 않게)
          final w2 = Stopwatch()..start();
          await state.removeMany(items: made, series: [for (final id in seriesIds) ?state.seriesById(id)]);
          debugPrint('CHECK scale remove=${w2.elapsedMilliseconds}ms');
        });
      });
    }

    // 자연 음성: 모델을 받아 한국어를 합성해 보고, 소리가 실제로 나는지 숫자로 확인한다
    if (Platform.environment['TTS_CHECK'] == '1' || const bool.fromEnvironment('TTS_CHECK')) {
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
            if (Platform.isAndroid || Platform.isIOS) files['$name.wav'] = base64.encode(bytes);
            expect(sec, greaterThan(1.0));
            expect(rms, greaterThan(300));
          }
        });
      });
    }

    // 기기(시스템) 음성: 목록을 읽고 한 문장 읽어 본다 (소리 장치가 없으면 실패할 수 있어 기록만)
    await step('system tts', () async {
      await tester.runAsync(() async {
        final v = await TtsService.voices();
        debugPrint('CHECK voices ${v.length}: ${v.take(8).map(TtsService.label).join(', ')}');
        final sys = v.where((x) => !NaturalTts.isNatural(x)).firstOrNull;
        if (sys != null) {
          final ok = await TtsService().speak('안녕하세요. 테스트입니다.', voice: sys).timeout(const Duration(seconds: 40), onTimeout: () => false);
          debugPrint('CHECK system tts voice=${TtsService.label(sys)} ok=$ok');
        }
      });
    });

    // 화자 찾기 · 주고받기 · 영어 약어 · 배경음 (순수 규칙이라 숫자로 정확히 확인)
    await step('speakers', () async {
      await tester.runAsync(() async {
        final got = {
          'en_after': Speakers.after(' said Holmes, smiling.'),
          'en_after2': Speakers.after(' Mr. Holmes asked.'),
          'en_then': Speakers.after(' Then Sherlock Holmes replied quietly.'),
          'en_before': Speakers.before('Watson turned to me and said, '),
          'en_he': Speakers.after(' he said.'),
          'ko_after': Speakers.after(' 민호가 속삭였다.'),
          'ko_before': Speakers.before('수아가 고개를 저으며 말했다. '),
          'alt_even': Speakers.alternate([(null, true), ('민호', false)]),
          'alt_odd': Speakers.alternate([('민호', false), ('수아', false)]),
          'alt_break': Speakers.alternate([('', false), ('민호', false)]),
          'alt_unknown_other': Speakers.alternate([('민호', false)]),
        };
        debugPrint('CHECK speakers $got');
        expect(got, {
          'en_after': 'Holmes',
          'en_after2': 'Holmes',
          'en_then': 'Holmes',
          'en_before': 'Watson',
          'en_he': null,
          'ko_after': '민호',
          'ko_before': '수아',
          'alt_even': '민호',
          'alt_odd': '수아',
          'alt_break': null,
          'alt_unknown_other': null,
        });
        final scan = Speakers.scan([
          '"Come in," said Holmes.',
          '"Thank you," Watson replied.',
          '"Sit down," said Mr. Holmes.',
          '"Of course," said Watson.',
        ]);
        debugPrint('CHECK speakers scan=$scan');
        expect(scan.map((e) => e.$1).toSet(), {'Holmes', 'Watson'});
        final pool = ['st:M1', 'st:F1', 'st:M2'];
        expect(Speakers.autoVoice('Holmes', ['Holmes', 'Watson'], pool), 'st:M1');
        expect(Speakers.autoVoice('Watson', ['Holmes', 'Watson'], pool), 'st:F1');
        final norm = TtsService.normalize('Mr. Holmes met Dr. Watson on Baker St. near St. Paul... No. 5, e.g. here.');
        debugPrint('CHECK normalize "$norm"');
        expect(norm, 'Mister Holmes met Doctor Watson on Baker Street near Saint Paul… Number 5, for example here.');
        for (final (k, _) in Ambient.kinds) {
          final w = Ambient.makeWav(k);
          final pcm = pcmFromWav(w, 22050)!;
          var sq = 0.0;
          for (final v in pcm) {
            sq += v * v.toDouble();
          }
          final rms = sqrt(sq / pcm.length);
          // 이음새: 끝과 처음 표본 차이가 작아야 반복할 때 '딱' 소리가 안 남
          final seam = (pcm.last - pcm.first).abs();
          debugPrint('CHECK ambient $k sec=${pcm.length / 22050} rms=${rms.round()} seam=$seam');
          expect(pcm.length, 22050 * 30);
          expect(rms, greaterThan(500));
        }
      });
    });

    // 오디오북: 가짜 음성으로 이어 붙이기 · 표본률 맞추기 · 이어 만들기를 숫자로 확인하고, 실제 기기 음성과 M4A 변환도 해 본다
    await step('audiobook', () async {
      await tester.runAsync(() async {
        final dir = Directory(p.join((await getTemporaryDirectory()).path, 'ab_test'));
        if (dir.existsSync()) dir.deleteSync(recursive: true);
        dir.createSync(recursive: true);
        // a: 44.1kHz 모노 16비트, b: 22.05kHz 스테레오 16비트 (글자당 0.02초)
        int inFrames(String t, int sr) => (sr * t.length * 0.02).round();
        Future<String?> fake(String text, String voice, int rate) async {
          final sr = voice == 'a' ? 44100 : 22050, ch = voice == 'a' ? 1 : 2;
          final n = inFrames(text, sr);
          final b = ByteData(44 + n * ch * 2);
          void str(int o, String v) {
            for (var i = 0; i < 4; i++) {
              b.setUint8(o + i, v.codeUnitAt(i));
            }
          }
          str(0, 'RIFF');
          b.setUint32(4, 36 + n * ch * 2, Endian.little);
          str(8, 'WAVE');
          str(12, 'fmt ');
          b.setUint32(16, 16, Endian.little);
          b.setUint16(20, 1, Endian.little);
          b.setUint16(22, ch, Endian.little);
          b.setUint32(24, sr, Endian.little);
          b.setUint32(28, sr * ch * 2, Endian.little);
          b.setUint16(32, ch * 2, Endian.little);
          b.setUint16(34, 16, Endian.little);
          str(36, 'data');
          b.setUint32(40, n * ch * 2, Endian.little);
          for (var i = 0; i < n; i++) {
            final v = (sin(i * 2 * pi * 440 / sr) * 12000).round();
            for (var c = 0; c < ch; c++) {
              b.setInt16(44 + (i * ch + c) * 2, v, Endian.little);
            }
          }
          final f = File(p.join(dir.path, 'seg_${DateTime.now().microsecondsSinceEpoch}.wav'));
          await f.writeAsBytes(b.buffer.asUint8List());
          return f.path;
        }

        final parts = [
          AudiobookPart('제1장 시작', ['첫 문단입니다.', '"안녕." 민호가 말했다.']),
          AudiobookPart('제2장: 끝/마무리?', ['두 번째 장.']),
        ];
        List<(String, String, int)> plan(String t, [int block = -1]) => [
              for (final x in t.split('"').where((x) => x.trim().isNotEmpty)) (x, t.startsWith('"') && x == t.split('"')[1] ? 'b' : 'a', 0),
            ];
        var expected = 0;
        for (final pt in parts) {
          for (final para in pt.paragraphs) {
            for (final (x, v, _) in plan(para)) {
              final sr = v == 'a' ? 44100 : 22050;
              expected += (inFrames(x.trim(), sr) * 24000 / sr).floor() + 2880;
            }
            expected += 8400;
          }
        }
        final r = await AudiobookMaker(render: fake).make(parts: parts, outDir: dir.path, bookTitle: '시험 책', compress: false, plan: plan);
        var got = 0;
        for (final f in r.files) {
          final pcm = pcmFromWav(await File(f).readAsBytes(), 24000)!;
          got += pcm.length;
        }
        debugPrint('CHECK audiobook files=${r.files.map(p.basename).join('|')} samples=$got expected=$expected failed=${r.failedPieces} playlist=${r.playlist == null ? '-' : p.basename(r.playlist!)}');
        expect(r.files.map(p.basename).toList(), ['001 제1장 시작.wav', '002 제2장 끝 마무리.wav']);
        expect(got, expected);
        final again = await AudiobookMaker(render: fake).make(parts: parts, outDir: dir.path, bookTitle: '시험 책', compress: false, plan: plan);
        debugPrint('CHECK audiobook resume skipped=${again.skippedParts} files=${again.files.length}');
        expect(again.skippedParts, 2);
        final oneDir = p.join(dir.path, 'one');
        final one = await AudiobookMaker(render: fake).make(parts: parts, outDir: oneDir, bookTitle: '시험 책', compress: false, single: true, plan: plan);
        final onePcm = pcmFromWav(await File(one.files.single).readAsBytes(), 24000)!;
        final left = Directory(oneDir).listSync().map((e) => p.basename(e.path)).toList();
        debugPrint('CHECK audiobook single=${p.basename(one.files.single)} samples=${onePcm.length} left=$left');
        expect(onePcm.length, expected);
        expect(left, ['시험 책.wav']);

        // "지금 장만" + 한 파일: 범위 밖 장(001)은 합치지도 지우지도 않는다
        var exp2 = 0;
        for (final para in parts[1].paragraphs) {
          for (final (x, v, _) in plan(para)) {
            final sr = v == 'a' ? 44100 : 22050;
            exp2 += (inFrames(x.trim(), sr) * 24000 / sr).floor() + 2880;
          }
          exp2 += 8400;
        }
        final onlyDir = p.join(dir.path, 'only');
        await AudiobookMaker(render: fake).make(parts: parts, outDir: onlyDir, bookTitle: '시험 책', compress: false, plan: plan);
        final only = await AudiobookMaker(render: fake).make(
            parts: [AudiobookPart(parts[0].title, const []), parts[1]], outDir: onlyDir, bookTitle: '하나만', compress: false, single: true, plan: plan);
        final onlyPcm = pcmFromWav(await File(only.files.single).readAsBytes(), 24000)!;
        final kept = File(p.join(onlyDir, '001 제1장 시작.wav')).existsSync();
        debugPrint('CHECK audiobook only-chapter samples=${onlyPcm.length} expected=$exp2 kept001=$kept');
        expect(onlyPcm.length, exp2);
        expect(kept, isTrue);

        // 실제 기기 음성 (자연 음성이 없어도 되는 길)
        final v = await TtsService.voices();
        final sys = v.where((x) => !NaturalTts.isNatural(x) && !KokoroTts.isKokoro(x)).firstOrNull;
        if (sys != null) {
          // 영어 전용 음성(서버 Windows 의 David 등)은 한국어를 읽지 못해 빈 소리 → 영어로도 해 본다
          Int16List? pcm;
          String? w;
          for (final t in ['안녕하세요. 오디오북 시험입니다.', 'Hello. This is an audiobook test.']) {
            w = await AudioRender.toWav(t, sys, 0).timeout(const Duration(seconds: 90), onTimeout: () => null);
            pcm = w == null ? null : pcmFromWav(await File(w).readAsBytes(), 24000);
            if ((pcm?.length ?? 0) > 2400) break;
          }
          var sq = 0.0;
          for (final x in pcm ?? Int16List(0)) {
            sq += x * x.toDouble();
          }
          final rms = pcm == null || pcm.isEmpty ? 0 : sqrt(sq / pcm.length);
          if (pcm == null || pcm.isEmpty) debugPrint('CHECK audiobook render log=${AudioRender.lastRenderLog}');
          debugPrint('CHECK audiobook system voice=${TtsService.label(sys)} ok=${w != null} sec=${((pcm?.length ?? 0) / 24000).toStringAsFixed(2)} rms=${rms.round()}');
        } else {
          debugPrint('CHECK audiobook system voice=none');
        }
        await AudioRender.closeWorkers();

        // M4A 로 줄이기 (3초 소리)
        final tone = p.join(dir.path, 'tone.wav');
        await File(tone).writeAsBytes(NaturalTts.wavBytes(
            Float32List.fromList([for (var i = 0; i < 72000; i++) sin(i * 2 * pi * 330 / 24000) * 0.4]), 24000));
        final m4a = p.join(dir.path, 'tone.m4a');
        final ok = await AudioRender.encodeM4a(tone, m4a);
        final size = File(m4a).existsSync() ? File(m4a).lengthSync() : 0;
        final log = AudioRender.lastEncodeLog.replaceAll(RegExp(r'\s+'), ' ');
        debugPrint('CHECK audiobook m4a ok=$ok size=$size wav=${File(tone).lengthSync()} ${log.length > 300 ? log.substring(0, 300) : log}');
        // 정리 (Windows 는 방금 닫은 파일을 잠깐 붙잡고 있을 수 있음)
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
    });

    // 글자 인식: 글을 그림으로 그려 Windows OCR 이 다시 읽어 내는지
    await step('ocr', () async {
      await tester.runAsync(() async {
        final langs = await OcrService.languages();
        debugPrint('CHECK ocr languages=$langs');
        Future<String> render(String name, String text) async {
          final rec = ui.PictureRecorder();
          final c = Canvas(rec);
          c.drawRect(const Rect.fromLTWH(0, 0, 1400, 200), Paint()..color = Colors.white);
          final tp = TextPainter(
            text: TextSpan(text: text, style: const TextStyle(color: Colors.black, fontSize: 44)),
            textDirection: TextDirection.ltr,
          )..layout(maxWidth: 1340);
          tp.paint(c, const Offset(30, 60));
          final im = await rec.endRecording().toImage(1400, 200);
          final bd = await im.toByteData(format: ui.ImageByteFormat.png);
          final path = p.join(tmp.path, '$name.png');
          File(path).writeAsBytesSync(bd!.buffer.asUint8List());
          return path;
        }

        final en = await render('ocr_en', 'The quick brown fox jumps over the lazy dog');
        final ko = await render('ocr_ko', '언덕 위에는 오래된 풍차가 하나 서 있었다');
        final rEn = await OcrService.recognizeFiles([en], lang: 'en');
        debugPrint('CHECK ocr en="${rEn[en]}"');
        try {
          final rKo = await OcrService.recognizeFiles([ko], lang: 'ko');
          debugPrint('CHECK ocr ko="${rKo[ko]}"');
        } catch (e) {
          debugPrint('CHECK ocr ko unavailable: $e');
        }
        expect((rEn[en] ?? '').toLowerCase(), contains('fox'));

        // Windows: 한국어 딥러닝 글자 인식(PaddleOCR) 모델을 받아 같은 그림을 다시 읽는다
        if (Platform.isWindows && (Platform.environment['TTS_CHECK'] == '1' || const bool.fromEnvironment('TTS_CHECK'))) {
          final sw = Stopwatch()..start();
          final picked = await PaddleOcr.instance.pickRemoteFiles();
          debugPrint('CHECK paddle files $picked');
          await PaddleOcr.instance.download();
          debugPrint('CHECK paddle download ${sw.elapsed.inSeconds}s installed=${await PaddleOcr.instance.installed()}');
          sw.reset();
          final r = await OcrService.recognizeFiles([ko, en]);
          debugPrint('CHECK paddle ko="${r[ko]}" en="${r[en]}" took=${sw.elapsedMilliseconds}ms');
          expect(r[ko] ?? '', contains('풍차'));
        }
      });
    });

    // PDF → 텍스트: 글을 그린 그림으로 "스캔 PDF" 를 만들고 (이미지 → PDF), 글자 인식으로 다시 꺼낸다
    await step('pdf text', () async {
      await tester.runAsync(() async {
        // 쪽 합치기 규칙 (쪽 번호 · 머리글 빼기, 끊긴 문장 잇기, 장 제목은 따로)
        final joined = PdfText.joinPages([
          '시험 책\n제1장 바람\n언덕 위에는 오래된\n풍차가 있었다.\n1',
          '시험 책\n아이들은 그 풍차가\n밤마다 노래한다고\n- 2 -',
          '시험 책\n믿었다.\n제2장 밤\n그날 밤은 조용했다.\n3',
          '시험 책\n끝.\n4',
        ]);
        debugPrint('CHECK pdftext join=${jsonEncode(joined)}');
        expect(joined, '제1장 바람\n언덕 위에는 오래된 풍차가 있었다.\n아이들은 그 풍차가 밤마다 노래한다고 믿었다.\n제2장 밤\n그날 밤은 조용했다.\n끝.');

        final dir = Directory(p.join((await getTemporaryDirectory()).path, 'pdf_test'));
        if (dir.existsSync()) dir.deleteSync(recursive: true);
        dir.createSync(recursive: true);
        Future<Uint8List> page(List<String> lines) async {
          final rec = ui.PictureRecorder();
          final c = Canvas(rec);
          c.drawRect(const Rect.fromLTWH(0, 0, 1240, 1754), Paint()..color = Colors.white);
          var y = 120.0;
          for (final l in lines) {
            final tp = TextPainter(
              text: TextSpan(text: l, style: const TextStyle(color: Colors.black, fontSize: 46)),
              textDirection: TextDirection.ltr,
            )..layout(maxWidth: 1100);
            tp.paint(c, Offset(70, y));
            y += 110;
          }
          final im = await rec.endRecording().toImage(1240, 1754);
          final bd = await im.toByteData(format: ui.ImageByteFormat.png);
          return bd!.buffer.asUint8List();
        }

        final pages = [
          await page(['THE TEST BOOK', 'The quick brown fox jumps', 'over the lazy dog.', '', '', '', '', '', '', '', '', '', '', '1']),
          await page(['THE TEST BOOK', 'A small boat sails', 'across the quiet lake.', '', '', '', '', '', '', '', '', '', '', '2']),
          await page(['THE TEST BOOK', 'Every morning the baker', 'sells warm bread.', '', '', '', '', '', '', '', '', '', '', '3']),
          await page(['THE TEST BOOK', 'The end.', '', '', '', '', '', '', '', '', '', '', '', '4']),
        ];
        final pdf = p.join(dir.path, 'scan.pdf');
        final n = await ImagePdf.write(pdf, pages.length, (i) async => pages[i], title: '스캔 시험');
        debugPrint('CHECK imagepdf pages=$n size=${File(pdf).lengthSync()}');
        expect(n, 4);
        final sw = Stopwatch()..start();
        final r = await PdfText.convert(pdf);
        final flat = r.text.replaceAll('\n', ' | ');
        debugPrint('CHECK pdftext pages=${r.pages} ocr=${r.ocrPages} empty=${r.emptyPages} took=${sw.elapsedMilliseconds}ms text="$flat"');
        expect(r.pages, 4);
        expect(r.text.toLowerCase(), contains('fox'));
        expect(r.text.toLowerCase(), contains('bread'));
        // 머리글은 빼야 한다 (글자 인식이 한 쪽에서 다르게 읽을 수 있어 한 번까지는 봐줌)
        expect('TEST BOOK'.allMatches(r.text.toUpperCase()).length, lessThanOrEqualTo(1));
        // 정리 (Windows 는 방금 닫은 파일을 잠깐 붙잡고 있을 수 있음)
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
    });

    // 파일 도구: 만화 그림 줄이기 · EPUB 최적화 · PDF 나누기/합치기
    await step('file tools', () async {
      await tester.runAsync(() async {
        final dir = Directory(p.join((await getTemporaryDirectory()).path, 'tools_test'));
        if (dir.existsSync()) dir.deleteSync(recursive: true);
        dir.createSync(recursive: true);
        img.Image big(int seed) {
          // 사진처럼 잡음이 섞인 그림 (PNG 로는 크고 JPEG 로는 작아지는 실제 만화 · 사진에 가깝게)
          final rnd = Random(seed);
          final im = img.Image(width: 2400, height: 1600);
          for (final px in im) {
            final n = rnd.nextInt(48);
            px
              ..r = (px.x * 200 ~/ 2400 + n + seed * 40) % 256
              ..g = (px.y * 200 ~/ 1600 + n)
              ..b = ((px.x + px.y) ~/ 9 + n) % 256;
          }
          return im;
        }

        // CBZ: PNG 3장 + 글 파일
        final cbz = p.join(dir.path, 'big.cbz');
        final arc = Archive();
        for (var i = 0; i < 3; i++) {
          final b = img.encodePng(big(i), level: 1);
          arc.addFile(ArchiveFile.noCompress('p${i + 1}.png', b.length, b));
        }
        arc.addFile(ArchiveFile.string('info.txt', 'hello'));
        File(cbz).writeAsBytesSync(ZipEncoder().encode(arc));
        final r = await FileTools.shrinkZip(cbz, const ShrinkOptions(maxSide: 1600, quality: 80, toJpeg: true), backup: true);
        final after = ZipDecoder().decodeBytes(File(cbz).readAsBytesSync());
        final names = after.files.map((f) => f.name).toList();
        final first = img.decodeImage(after.findFile('p1.jpg')!.content)!;
        debugPrint('CHECK tools shrinkZip changed=${r.changed}/${r.images} ${r.before}→${r.after} names=$names w=${first.width} bak=${File('$cbz.bak').existsSync()}');
        expect(r.changed, 3);
        expect(r.after, lessThan(r.before));
        expect(names, containsAll(['p1.jpg', 'p2.jpg', 'p3.jpg', 'info.txt']));
        expect(first.width, 1600);

        // EPUB: 큰 표지 → 최적화
        final txt = p.join(dir.path, 'novel.txt');
        File(txt).writeAsStringSync('제1장 시작\n${'가나다라마바사 ' * 400}\n제2장 끝\n끝.');
        final cover = img.encodeJpg(big(9), quality: 95);
        final epub = await EpubWriter.fromTxt(txt, title: '시험', cover: cover);
        final r2 = await FileTools.optimizeEpub(epub, const ShrinkOptions(maxSide: 1200, quality: 80), backup: false);
        final ez = ZipDecoder().decodeBytes(File(epub).readAsBytesSync());
        final coverOut = ez.files.where((f) => f.name.toLowerCase().endsWith('.jpg') || f.name.toLowerCase().endsWith('.jpeg')).first;
        final cw = img.decodeImage(coverOut.content)!.width;
        debugPrint('CHECK tools epub changed=${r2.changed}/${r2.images} ${r2.before}→${r2.after} first=${ez.files.first.name} cover=$cw');
        expect(ez.files.first.name, 'mimetype');
        expect(r2.after, lessThan(r2.before));
        expect(cw, 1200);

        // PDF: 4쪽 → 2쪽씩 나누기 → 다시 합치기
        final pagesJpg = [for (var i = 0; i < 4; i++) img.encodeJpg(img.copyResize(big(i), width: 600), quality: 80)];
        final pdf = p.join(dir.path, 'four.pdf');
        await ImagePdf.write(pdf, 4, (i) async => pagesJpg[i]);
        expect(FileTools.parseRanges('1-2, 3-', 4), [[1, 2], [3, 4]]);
        expect(FileTools.parseRanges('5', 4), isNull);
        // 대시 양옆 띄어쓰기
        expect(FileTools.parseRanges('1 - 2 , 3 ~ 4', 4), [[1, 2], [3, 4]]);
        final parts = await FileTools.splitPdf(pdf, FileTools.everyN(2, 4));
        final counts = <int>[];
        for (final x in parts) {
          final d = await PdfDocument.openFile(x);
          counts.add(d.pages.length);
          d.dispose();
        }
        final merged = p.join(dir.path, 'merged.pdf');
        final n = await FileTools.mergePdf(parts, merged);
        final md = await PdfDocument.openFile(merged);
        final mn = md.pages.length;
        md.dispose();
        debugPrint('CHECK tools pdf split=${parts.map(p.basename).toList()} counts=$counts merged=$n/$mn');
        expect(counts, [2, 2]);
        expect(mn, 4);
        // 정리 (Windows 는 방금 닫은 파일을 잠깐 붙잡고 있을 수 있음)
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
    });

    binding.reportData = {'files': files};
    debugPrint('SHOTS DONE ${done.length}: ${done.join(', ')}');
    expect(done, isNotEmpty);
  });
}
