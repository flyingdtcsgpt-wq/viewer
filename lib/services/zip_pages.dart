import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../models/media_item.dart';
import 'archive_tools.dart';
import 'fd_file.dart';
import 'linked.dart';
import 'remote.dart';

/// 압축 만화(CBZ · ZIP)의 쪽을 화면 쪽이 아니라 따로 도는 일꾼(isolate)에서 꺼낸다.
/// 압축 파일은 한 번만 열어 두고, 쪽을 달라는 대로 풀어서 보낸다 (큰 파일 · 느린 드라이브에서도 화면이 멈추지 않음).
abstract class ZipPages {
  /// 그림 이름들 (자연 정렬, 쪽 순서)
  List<String> get names;

  /// [i] 번째 쪽 그림 데이터
  Future<Uint8List?> read(int i);

  void close();

  /// 압축 만화 열기. NAS 의 파일이면 통째로 받지 않고 목차와 보는 쪽만 받는다
  static Future<ZipPages> open(String path) async {
    if (Remote.isRemote(path)) {
      try {
        return _RemotePages(await RemoteZip.openPath(path));
      } on RangeUnsupported {
        path = await Remote.cache(path); // 나눠 받기를 못 하는 서버: 통째로 받아서
      }
    }
    return _IsolatePages.open(path);
  }
}

/// NAS 의 압축 만화: 쪽마다 그 그림만 받아 푼다
class _RemotePages implements ZipPages {
  _RemotePages(this._zip) : _images = _zip.images;
  final RemoteZip _zip;
  final List<RemoteZipEntry> _images;
  bool _closed = false;

  @override
  late final List<String> names = [for (final e in _images) e.name]; // (화면을 그릴 때마다 쪽 수를 묻는다 → 한 번만 만든다)

  @override
  Future<Uint8List?> read(int i) async {
    if (_closed || i < 0 || i >= _images.length) return null;
    try {
      return await _zip.read(_images[i]);
    } catch (_) {
      return null;
    }
  }

  @override
  void close() => _closed = true;
}

/// 이 기기 · 연결한 폴더의 압축 만화: 따로 도는 일꾼이 압축을 열어 두고 쪽을 꺼내 준다
class _IsolatePages implements ZipPages {
  _IsolatePages._(this.names, this._send, this._iso, this._replies, this._ref);

  /// 읽는 파일 (연결한 폴더의 파일이면 열어 둔 파일 번호를 쥐고 있다 → close 에서 닫는다)
  final FileRef _ref;

  @override
  final List<String> names;
  final SendPort _send;
  final Isolate _iso;
  final ReceivePort _replies;
  final Map<int, Completer<Uint8List?>> _wait = {};
  int _next = 0;
  bool _closed = false;

  static Future<ZipPages> open(String path) async {
    final ref = await Linked.ref(path); // 연결한 폴더의 파일이면 시스템이 열어 준 파일 번호로 읽는다
    final replies = ReceivePort();
    final first = Completer<(SendPort, List<String>)>();
    final Isolate iso;
    try {
      iso = await Isolate.spawn(_worker, (ref, replies.sendPort));
    } catch (_) {
      ref.close();
      replies.close();
      rethrow;
    }
    _IsolatePages? self;
    replies.listen((msg) {
      if (msg is (SendPort, List<String>)) {
        first.complete(msg);
      } else if (msg is (int, TransferableTypedData?)) {
        final c = self?._wait.remove(msg.$1);
        c?.complete(msg.$2?.materialize().asUint8List());
      } else if (msg is String && !first.isCompleted) {
        first.completeError(msg);
      }
    });
    try {
      final (send, names) = await first.future;
      return self = _IsolatePages._(names, send, iso, replies, ref);
    } catch (e) {
      iso.kill();
      replies.close();
      ref.close();
      rethrow;
    }
  }

  @override
  Future<Uint8List?> read(int i) {
    if (_closed || i < 0 || i >= names.length) return Future.value(null);
    final id = _next++;
    final c = _wait[id] = Completer<Uint8List?>();
    _send.send((id, i));
    return c.future;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final c in _wait.values) {
      if (!c.isCompleted) c.complete(null);
    }
    _wait.clear();
    _iso.kill(priority: Isolate.immediate);
    _replies.close();
    _ref.close();
  }
}

void _worker((FileRef, SendPort) args) {
  final (ref, reply) = args;
  InputFileStream? input;
  try {
    input = ref.input();
    final zip = ZipDecoder().decodeStream(input);
    final files = zip.files.where((f) => f.isFile && imageExts.contains(p.extension(f.name).toLowerCase())).toList()
      ..sort((a, b) => ArchiveTools.natural(a.name, b.name));
    final inbox = ReceivePort();
    reply.send((inbox.sendPort, [for (final f in files) f.name]));
    inbox.listen((msg) {
      if (msg is! (int, int)) return;
      final (id, i) = msg;
      try {
        // writeContent(freeMemory) 는 풀어 둔 데이터를 바로 버린다 (content 는 쪽마다 메모리에 쌓임)
        final out = OutputMemoryStream();
        files[i].writeContent(out);
        final bytes = out.getBytes();
        reply.send((id, TransferableTypedData.fromList([bytes])));
      } catch (_) {
        reply.send((id, null));
      }
    });
  } catch (e) {
    input?.closeSync();
    reply.send('$e');
  }
}
