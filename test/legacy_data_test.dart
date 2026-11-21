import 'dart:io';

import 'package:arariflex/services/legacy_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 예전 이름 때의 데이터 폴더를 새 자리로 옮기기 (PC)
void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('arari_legacy'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Directory make(String rel, {String db = 'old'}) {
    final d = Directory(p.join(tmp.path, rel))..createSync(recursive: true);
    File(p.join(d.path, 'library.db')).writeAsStringSync(db);
    File(p.join(d.path, 'shared_preferences.json')).writeAsStringSync('{"flutter.viewerFit":1}');
    Directory(p.join(d.path, 'covers')).createSync();
    File(p.join(d.path, 'covers', '1.jpg')).writeAsStringSync('cover');
    return d;
  }

  test('예전 폴더의 서재 · 설정 · 표지가 새 자리로 온다', () async {
    final old = make(p.join('com.mediashelf', 'ARARIFlex'));
    final now = Directory(p.join(tmp.path, 'ARARIFlex', 'ARARIFlex'))..createSync(recursive: true);
    // 막 켜며 생긴 빈 설정 파일이 있어도 예전 설정으로 바뀐다
    File(p.join(now.path, 'shared_preferences.json')).writeAsStringSync('{}');

    final moved = await LegacyData.moveInto(now, [old.path, p.join(tmp.path, 'com.mediashelf', 'media_shelf')]);
    expect(moved, old.path);
    expect(File(p.join(now.path, 'library.db')).readAsStringSync(), 'old');
    expect(File(p.join(now.path, 'shared_preferences.json')).readAsStringSync(), contains('viewerFit'));
    expect(File(p.join(now.path, 'covers', '1.jpg')).existsSync(), true);
    expect(old.existsSync(), false); // 비운 예전 폴더는 치운다
    expect(Directory(p.join(tmp.path, 'com.mediashelf')).existsSync(), false);
  });

  test('새 자리에 이미 서재가 있으면 건드리지 않는다', () async {
    final old = make(p.join('com.mediashelf', 'ARARIFlex'));
    final now = make(p.join('ARARIFlex', 'ARARIFlex'), db: 'new');
    expect(await LegacyData.moveInto(now, [old.path]), isNull);
    expect(File(p.join(now.path, 'library.db')).readAsStringSync(), 'new');
    expect(File(p.join(old.path, 'library.db')).existsSync(), true);
  });

  test('예전 폴더가 없으면 아무 일도 없다', () async {
    final now = Directory(p.join(tmp.path, 'ARARIFlex', 'ARARIFlex'))..createSync(recursive: true);
    expect(await LegacyData.moveInto(now, [p.join(tmp.path, 'com.mediashelf', 'ARARIFlex')]), isNull);
    expect(now.listSync(), isEmpty);
  });
}
