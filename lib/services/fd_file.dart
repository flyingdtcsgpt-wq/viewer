import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';

/// 파일의 아무 위치나 읽기. 보통 파일([RafReader])과, 안드로이드가 열어 준 파일 번호([FdReader])를 같은 모양으로 다룬다.
///
/// 플레이스토어판의 "연결한 폴더" 는 저장소 권한이 없어 경로로는 열 수 없고, 시스템이 열어 준 파일 번호(fd)로만 읽을 수 있다.
/// 압축(만화 · EPUB) · PDF 는 파일 여기저기를 골라 읽어야 하므로 이 모양이 필요하다.
abstract class RandomReader {
  int get length;

  /// [position] 부터 [count] 바이트를 [into] 의 앞에서부터 채운다. 읽은 바이트 수 (파일 끝이면 그보다 적다)
  int readAt(int position, Uint8List into, int count);

  void close();
}

/// 보통 파일 (경로)
class RafReader implements RandomReader {
  RafReader(String path) : _f = File(path).openSync() {
    length = _f.lengthSync();
  }

  final RandomAccessFile _f;
  @override
  late final int length;

  @override
  int readAt(int position, Uint8List into, int count) {
    _f.setPositionSync(position);
    return _f.readIntoSync(into, 0, count);
  }

  @override
  void close() => _f.closeSync();
}

// ---- C 라이브러리 (안드로이드 · 리눅스). 쓸 때 처음 찾으므로 Windows 에서는 건드리지 않는다 ----
final DynamicLibrary _libc = DynamicLibrary.process();
// pread64: 32비트 기기에서도 4GB 넘는 위치를 읽을 수 있다
final int Function(int, Pointer<Uint8>, int, int) _pread =
    _libc.lookupFunction<IntPtr Function(Int32, Pointer<Uint8>, IntPtr, Int64), int Function(int, Pointer<Uint8>, int, int)>('pread64');
final int Function(int) _close = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');
final Pointer<Uint8> Function(int) _malloc =
    _libc.lookupFunction<Pointer<Uint8> Function(IntPtr), Pointer<Uint8> Function(int)>('malloc');
final void Function(Pointer<Uint8>) _free = _libc.lookupFunction<Void Function(Pointer<Uint8>), void Function(Pointer<Uint8>)>('free');

/// 열려 있는 파일 번호를 닫는다 (한 번만. 번호는 곧 다른 파일에 다시 쓰이므로 두 번 닫으면 남의 파일을 닫는다)
void closeFd(int fd) {
  try {
    _close(fd);
  } catch (_) {}
}

/// 시스템이 열어 준 파일 번호로 읽기. 번호의 주인은 [FileRef] 를 받은 쪽이라 여기서는 닫지 않는다.
class FdReader implements RandomReader {
  FdReader(this.fd, this.length);

  final int fd;
  @override
  final int length;

  Pointer<Uint8> _buf = nullptr;
  int _cap = 0;

  @override
  int readAt(int position, Uint8List into, int count) {
    if (count <= 0 || position >= length) return 0;
    if (_cap < count) {
      if (_buf != nullptr) _free(_buf);
      _cap = count < 65536 ? 65536 : count;
      _buf = _malloc(_cap);
      if (_buf == nullptr) {
        _cap = 0;
        throw const FileSystemException('메모리가 모자랍니다');
      }
    }
    var got = 0;
    while (got < count) {
      final n = _pread(fd, _buf + got, count - got, position + got);
      if (n <= 0) break; // 0 = 파일 끝, 음수 = 읽기 오류 (SD 카드를 뺐을 때 등)
      got += n;
    }
    if (got > 0) into.setRange(0, got, _buf.asTypedList(got));
    return got;
  }

  /// 읽는 데 쓴 메모리만 돌려준다 (파일 번호는 닫지 않는다)
  @override
  void close() {
    if (_buf != nullptr) _free(_buf);
    _buf = nullptr;
    _cap = 0;
  }
}

/// archive 패키지(ZIP 풀기)가 [RandomReader] 로 읽게 하는 다리
class ReaderHandle extends AbstractFileHandle {
  ReaderHandle(this.reader);

  final RandomReader reader;
  int _pos = 0;
  bool _open = true;

  @override
  int get position => _pos;
  @override
  set position(int p) => _pos = p;
  @override
  int get length => reader.length;
  @override
  bool get isOpen => _open;
  @override
  bool open({FileAccess mode = FileAccess.read}) => _open = true; // (읽는 쪽이 닫았다 다시 열어도 된다. 파일 번호는 그대로다)
  @override
  Future<void> close() async => closeSync();
  @override
  void closeSync() {
    if (!_open) return;
    _open = false;
    reader.close();
  }

  @override
  int readInto(Uint8List buffer, [int? length]) {
    final n = reader.readAt(_pos, buffer, length ?? buffer.length);
    _pos += n;
    return n;
  }

  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) => throw UnsupportedError('읽기 전용');
}

/// 읽을 파일 하나: 보통 파일(경로)이거나, 연결한 폴더의 파일(열어 둔 파일 번호).
/// 값 두세 개뿐이라 따로 도는 일꾼(isolate)에게 그대로 넘길 수 있다.
///
/// 파일 번호는 이 값을 만든 쪽이 [close] 로 **한 번만** 닫는다 (보통은 [Linked.use] 가 알아서 한다).
class FileRef {
  const FileRef(this.path, [this.fd, this.size = 0]);

  final String path;

  /// 연결한 폴더의 파일이면 열린 파일 번호, 보통 파일이면 null
  final int? fd;

  /// [fd] 로 연 파일의 크기
  final int size;

  RandomReader reader() => fd == null ? RafReader(path) : FdReader(fd!, size);

  /// 압축 풀기용 입력 (다 쓰면 closeSync — 파일 번호는 닫지 않는다)
  InputFileStream input() => fd == null ? InputFileStream(path) : InputFileStream.withFileHandle(ReaderHandle(FdReader(fd!, size)));

  /// 통째로 읽기 (TXT 처럼 작은 파일)
  Uint8List readAllSync() {
    if (fd == null) return File(path).readAsBytesSync();
    final r = FdReader(fd!, size);
    try {
      final out = Uint8List(size);
      final n = r.readAt(0, out, size);
      return n == size ? out : Uint8List.sublistView(out, 0, n);
    } finally {
      r.close();
    }
  }

  void close() {
    final f = fd;
    if (f != null) closeFd(f);
  }
}
