import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:arariflex/services/fd_file.dart';
import 'package:arariflex/services/linked.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 연결한 폴더 (플레이스토어판): 경로 계산과, 경로 대신 "아무 위치나 읽기" 로 압축을 푸는 다리
void main() {
  group('연결한 폴더의 경로', () {
    const inner = LinkedFolder(tree: 'content://x/tree/primary%3AComics', path: '/storage/emulated/0/Comics');
    const sd = LinkedFolder(tree: 'content://x/tree/1234-5678%3A%EB%A7%8C%ED%99%94', path: '/storage/1234-5678/만화', name: '');
    setUp(() => Linked.folders = [inner, sd]);
    tearDown(() => Linked.folders = const []);

    test('어느 폴더의 파일인지', () {
      expect(Linked.of('/storage/emulated/0/Comics/코난/01.cbz'), inner);
      expect(Linked.of('/storage/1234-5678/만화/a.zip'), sd);
      expect(Linked.of('/storage/emulated/0/Comics'), inner);
      // 이름이 비슷한 옆 폴더는 아니다
      expect(Linked.of('/storage/emulated/0/Comics2/a.cbz'), isNull);
      expect(Linked.has('/storage/emulated/0/Android/data/com.arariflex.app/files/ARARIFlex/만화/a.cbz'), false);
    });

    test('폴더 기준 상대 경로', () {
      expect(Linked.rel(inner, '/storage/emulated/0/Comics/코난/01.cbz'), '코난/01.cbz');
      expect(Linked.rel(inner, '/storage/emulated/0/Comics'), '');
    });

    test('SD 카드 · 이름', () {
      expect(inner.removable, false);
      expect(sd.removable, true);
      expect(sd.label, '만화');
    });

    test('설정에 저장했다 읽기', () {
      final back = LinkedFolder.decode(LinkedFolder.encode([inner, sd]));
      expect(back.map((e) => e.path), [inner.path, sd.path]);
      expect(back.map((e) => e.tree), [inner.tree, sd.tree]);
      expect(LinkedFolder.decode(null), isEmpty);
      expect(LinkedFolder.decode('깨진 값'), isEmpty);
    });

    test('연결한 폴더 밖의 파일은 경로 그대로 읽는다', () async {
      final r = await Linked.ref('/somewhere/else/a.txt');
      expect(r.fd, isNull);
      expect(r.path, '/somewhere/else/a.txt');
    });
  });

  group('아무 위치나 읽기로 압축 풀기', () {
    late Directory tmp;
    late String zipPath;
    final big = Uint8List.fromList([for (var i = 0; i < 300000; i++) (i * 31 + i ~/ 7) & 0xff]); // 읽기 묶음(64KB)을 여러 번 넘는 크기
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('arari_linked');
      zipPath = p.join(tmp.path, 'a.cbz');
      final a = Archive()
        ..addFile(ArchiveFile.bytes('001.jpg', Uint8List.fromList(List.filled(1000, 7))))
        ..addFile(ArchiveFile.bytes('002.jpg', big))
        ..addFile(ArchiveFile.string('글.txt', '가나다'));
      File(zipPath).writeAsBytesSync(ZipEncoder().encodeBytes(a));
    });
    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('경로로 푼 것과 같다', () {
      final input = InputFileStream.withFileHandle(ReaderHandle(RafReader(zipPath)));
      try {
        final zip = ZipDecoder().decodeStream(input);
        expect(zip.files.map((f) => f.name).toList(), ['001.jpg', '002.jpg', '글.txt']);
        expect(zip.findFile('002.jpg')!.content, big);
        expect(zip.findFile('001.jpg')!.content.length, 1000);
      } finally {
        input.closeSync();
      }
    });

    test('보통 파일의 FileRef', () {
      final ref = FileRef(zipPath);
      expect(ref.readAllSync(), File(zipPath).readAsBytesSync());
      final input = ref.input();
      try {
        expect(ZipDecoder().decodeStream(input).files.length, 3);
      } finally {
        input.closeSync();
      }
      final rd = ref.reader();
      final buf = Uint8List(4);
      expect(rd.readAt(0, buf, 4), 4);
      expect(buf, [0x50, 0x4b, 0x03, 0x04]); // ZIP 머리표
      expect(rd.readAt(rd.length - 2, buf, 4), 2); // 파일 끝에서는 남은 만큼만
      rd.close();
      ref.close(); // 보통 파일은 닫을 것이 없다
    });
  });
}
