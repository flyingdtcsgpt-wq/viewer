import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:arariflex/services/remote.dart';
import 'package:arariflex/services/webdav_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TempPaths extends PathProviderPlatform {
  _TempPaths(this.dir);
  final String dir;
  @override
  Future<String?> getTemporaryPath() async => dir;
}

/// NAS 받지 않고 보기: 주소 다루기, 나눠 받기(Range)로 ZIP · 큰 파일 읽기, 로그인
void main() {
  group('주소', () {
    const path = 'http://192.168.0.10:5005/home/만화/코난 01.cbz';
    test('앞부분 · 서버 안 경로', () {
      expect(Remote.isRemote(path), true);
      expect(Remote.isRemote('/storage/emulated/0/a.cbz'), false);
      expect(Remote.originOf(path), 'http://192.168.0.10:5005');
      expect(Remote.serverPath(path), '/home/만화/코난 01.cbz');
    });
    test('요청할 주소는 한글 · 빈칸을 주소 꼴로', () {
      final u = Remote.uri(path);
      expect(u.toString(), 'http://192.168.0.10:5005/home/%EB%A7%8C%ED%99%94/%EC%BD%94%EB%82%9C%2001.cbz');
      expect(u.pathSegments.last, '코난 01.cbz');
    });
    test('연결한 폴더 찾기 · 이름', () {
      Remote.folders = const [NasFolder(url: 'http://192.168.0.10:5005/home/만화')];
      expect(Remote.folderOf(path)?.url, 'http://192.168.0.10:5005/home/만화');
      expect(Remote.folderOf('http://192.168.0.10:5005/home/만화책/a.cbz'), isNull); // 이름이 비슷한 옆 폴더는 아니다
      expect(Remote.folders.first.label, '만화');
      expect(const NasFolder(url: 'http://nas.local:5005').label, 'nas.local');
      Remote.folders = const [];
    });
    test('설정에 저장했다 읽기', () {
      const a = NasAccount(origin: 'https://nas:5006', user: '나', insecure: true);
      final back = NasAccount.decode(NasAccount.encode([a])).single;
      expect([back.origin, back.user, back.insecure], [a.origin, a.user, true]);
      expect(NasFolder.decode('깨진 값'), isEmpty);
    });
  });

  group('나눠 받기 (작은 NAS 흉내)', () {
    late HttpServer server;
    late String base;
    final big = Uint8List.fromList([for (var i = 0; i < 900000; i++) (i * 7 + i ~/ 300) & 0xff]);
    late Uint8List zipBytes;
    var requests = 0;
    var bytesSent = 0;

    setUpAll(() async {
      final a = Archive()
        ..addFile(ArchiveFile.bytes('코난/002.jpg', Uint8List.fromList(List.filled(5000, 2))))
        ..addFile(ArchiveFile.bytes('코난/001.jpg', Uint8List.fromList(List.filled(3000, 1))))
        ..addFile(ArchiveFile.noCompress('코난/010.jpg', big.length, big))
        ..addFile(ArchiveFile.string('설명.txt', '가나다'));
      zipBytes = ZipEncoder().encodeBytes(a);
      final files = {'/만화/코난 01.cbz': zipBytes, '/큰 파일.bin': big};
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((req) async {
        final res = req.response;
        if (req.headers.value(HttpHeaders.authorizationHeader) != 'Basic ${base64.encode(utf8.encode('나:비밀'))}') {
          res.statusCode = 401;
          return res.close();
        }
        final data = files[Uri.decodeFull(req.uri.path)];
        if (data == null) {
          res.statusCode = 404;
          return res.close();
        }
        requests++;
        res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        final range = req.headers.value(HttpHeaders.rangeHeader);
        if (req.method == 'HEAD') {
          res.contentLength = data.length;
          return res.close();
        }
        if (range != null) {
          final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
          final s = int.parse(m.group(1)!), e = int.parse(m.group(2)!).clamp(0, data.length - 1);
          res.statusCode = 206;
          res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $s-$e/${data.length}');
          res.contentLength = e - s + 1;
          bytesSent += e - s + 1;
          res.add(Uint8List.sublistView(data, s, e + 1));
        } else {
          res.contentLength = data.length;
          bytesSent += data.length;
          res.add(data);
        }
        await res.close();
      });
      Remote.accounts = [NasAccount(origin: base, user: '나')];
      Remote.password = (_) => '비밀';
    });
    tearDownAll(() async {
      Remote.reset();
      await server.close(force: true);
    });

    test('ZIP: 목차와 그 쪽만 받아서 연다', () async {
      requests = 0;
      bytesSent = 0;
      final z = await RemoteZip.openPath('$base/만화/코난 01.cbz');
      expect(z.images.map((e) => e.name).toList(), ['코난/001.jpg', '코난/002.jpg', '코난/010.jpg']); // 쪽 순서 (숫자로)
      final first = await z.read(z.images.first);
      expect(first.length, 3000);
      expect(first.every((b) => b == 1), true);
      // 900KB 짜리 그림은 받지 않았다
      expect(bytesSent, lessThan(100000), reason: '받은 양 $bytesSent');
      final last = await z.read(z.images.last);
      expect(last, big);
      expect(requests, lessThan(8), reason: '요청 $requests 번');
    });

    test('큰 파일을 덩어리로 받아 아무 위치나 읽기 (PDF 엔진이 쓰는 방식)', () async {
      final size = await Remote.size('$base/큰 파일.bin');
      expect(size, big.length);
      final r = RemoteReader('$base/큰 파일.bin', size!, block: 64 * 1024);
      final buf = Uint8List(100000);
      expect(await r.read(buf, 300000, 100000), 100000);
      expect(buf, Uint8List.sublistView(big, 300000, 400000));
      // 파일 끝을 넘으면 남은 만큼만
      expect(await r.read(buf, big.length - 10, 100), 10);
    });

    test('통째로 받아 임시 보관 (TXT · EPUB 처럼 작은 것), 두 번째는 받지 않는다', () async {
      final tmp = Directory.systemTemp.createTempSync('arari_nas_cache');
      PathProviderPlatform.instance = _TempPaths(tmp.path);
      Remote.debugLog = (m) => print('NAS $m'); // 멈추면 어느 단계인지 보이게
      try {
        final f = await Remote.cache('$base/큰 파일.bin').timeout(const Duration(seconds: 20));
        expect(File(f).readAsBytesSync(), big);
        final before = requests;
        final again = await Remote.cache('$base/큰 파일.bin', size: big.length).timeout(const Duration(seconds: 20));
        expect(again, f);
        expect(requests, before); // 이미 받은 것
        // 크기를 모를 때 (HEAD 로 묻는다)
        final z = await Remote.cache('$base/만화/코난 01.cbz').timeout(const Duration(seconds: 20));
        expect(File(z).lengthSync(), zipBytes.length);
      } finally {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('있는지 · 없는지 · 비밀번호가 틀리면', () async {
      expect(await Remote.exists('$base/만화/코난 01.cbz'), true);
      expect(await Remote.exists('$base/없는 파일.cbz'), false);
      Remote.password = (_) => '틀림';
      await expectLater(Remote.range('$base/큰 파일.bin', 0, 10), throwsA(isA<WebDavError>()));
      Remote.password = (_) => '비밀';
    });
  });
}
