import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:arariflex/services/backup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 백업 암호: 암호를 건 zip 을 알아보고, 맞는 암호로만 풀리는지 (백업 파일과 같은 방법으로 만든다)
void main() {
  late Directory tmp;
  final db = Uint8List.fromList([...'SQLite format 3'.codeUnits, 0, for (var i = 0; i < 5000; i++) i & 0xff]);
  setUp(() => tmp = Directory.systemTemp.createTempSync('arari_bk'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  String make(String name, String? password) {
    final out = p.join(tmp.path, name);
    final enc = ZipFileEncoder(password: password)..create(out, level: 6);
    enc.addArchiveFile(ArchiveFile.string('manifest.json', '{"items":3}'));
    enc.addArchiveFile(ArchiveFile.bytes('library.db', db));
    enc.closeSync();
    return out;
  }

  Uint8List? read(String zip, String? password) {
    final input = InputFileStream(zip);
    try {
      return ZipDecoder().decodeStream(input, password: password).findFile('library.db')?.content;
    } finally {
      input.closeSync();
    }
  }

  test('암호가 걸렸는지 알아본다', () async {
    expect(await Backup.isLocked(make('plain.zip', null)), false);
    expect(await Backup.isLocked(make('locked.zip', '비밀 1234')), true);
    expect(await Backup.isLocked(p.join(tmp.path, '없는 파일.zip')), false);
  });

  test('암호 없이 만든 것은 그대로 풀린다', () {
    expect(read(make('plain.zip', null), null), db);
  });

  test('맞는 암호로 풀린다', () {
    expect(read(make('locked.zip', '비밀 1234'), '비밀 1234'), db);
  });

  test('틀린 암호로는 서재를 얻지 못한다', () {
    final zip = make('locked.zip', '비밀 1234');
    Uint8List? got;
    try {
      got = read(zip, '다른 암호');
    } catch (_) {
      got = null; // 풀다가 멈춰도 된다
    }
    expect(got == null || !_same(got, db), true);
  });
}

bool _same(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
