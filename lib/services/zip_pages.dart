import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../models/media_item.dart';
import 'archive_tools.dart';

/// 압축 만화(CBZ · ZIP)의 쪽을 화면 쪽이 아니라 따로 도는 일꾼(isolate)에서 꺼낸다.
/// 압축 파일은 한 번만 열어 두고, 쪽을 달라는 대로 풀어서 보낸다 (큰 파일 · 느린 드라이브에서도 화면이 멈추지 않음).
class ZipPages {
  ZipPages._(this.names, this._send, this._iso, this._replies);

  /// 그림 이름들 (자연 정렬, 쪽 순서)
  final List<String> names;
  final SendPort _send;
  final Isolate _iso;
  final ReceivePort _replies;
  final Map<int, Completer<Uint8List?>> _wait = {};
  int _next = 0;
  bool _closed = false;

  static Future<ZipPages> open(String path) async {
    final replies = ReceivePort();
    final first = Completer<(SendPort, List<String>)>();
    final iso = await Isolate.spawn(_worker, (path, replies.sendPort));
    ZipPages? self;
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
      return self = ZipPages._(names, send, iso, replies);
    } catch (e) {
      iso.kill();
      replies.close();
      rethrow;
    }
  }

  /// [i] 번째 쪽 그림 데이터
  Future<Uint8List?> read(int i) {
    if (_closed || i < 0 || i >= names.length) return Future.value(null);
    final id = _next++;
    final c = _wait[id] = Completer<Uint8List?>();
    _send.send((id, i));
    return c.future;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final c in _wait.values) {
      if (!c.isCompleted) c.complete(null);
    }
    _wait.clear();
    _iso.kill(priority: Isolate.immediate);
    _replies.close();
  }
}

void _worker((String, SendPort) args) {
  final (path, reply) = args;
  InputFileStream? input;
  try {
    input = InputFileStream(path);
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
