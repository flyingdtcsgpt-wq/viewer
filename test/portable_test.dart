import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_shelf/services/portable.dart';

void main() {
  test('휴대용 모드 설정 파일: 저장하고 다시 읽기', () async {
    final dir = Directory.systemTemp.createTempSync('arari_portable');
    Portable.root = dir.path;
    final a = await Prefs.open();
    await a.setString('name', '아라리');
    await a.setInt('n', 3);
    await a.setBool('on', true);
    await a.setDouble('size', 1.5);
    await a.setStringList('list', ['가', '나']);
    await a.remove('none');
    await Future<void>.delayed(const Duration(milliseconds: 600)); // 모아서 쓰기 기다림
    expect(File('${dir.path}/settings.json').existsSync(), isTrue);

    final b = await Prefs.open();
    expect(b.getString('name'), '아라리');
    expect(b.getInt('n'), 3);
    expect(b.getBool('on'), isTrue);
    expect(b.getDouble('size'), 1.5);
    expect(b.getStringList('list'), ['가', '나']);
    expect(b.all().length, 5);

    // 깨진 파일은 옆에 두고 빈 설정으로 시작
    File('${dir.path}/settings.json').writeAsStringSync('{broken');
    final c = await Prefs.open();
    expect(c.getString('name'), isNull);
    expect(File('${dir.path}/settings.json.broken').existsSync(), isTrue);
    Portable.root = null;
  });
}
