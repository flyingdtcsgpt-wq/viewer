import 'dart:io';
import 'dart:typed_data';

import 'remote.dart';

/// 그림 파일의 가로 · 세로를 파일 머리(앞부분)만 읽어 알아낸다 — 그림을 풀지 않으므로 빠르다.
/// 그림 보기의 "이어 보기" 가 그림을 그리기 전에 자리 높이를 정확히 잡아 두는 데 쓴다
/// (자리 높이가 나중에 바뀌면 빨리 내릴 때 목록 위치가 어긋나 엉뚱한 곳으로 튄다).
class ImageSize {
  ImageSize._();

  /// 세로 / 가로 비율. 모르면 null (HEIC · AVIF 등)
  static Future<double?> aspect(String path) async {
    try {
      final head = await _head(path, 192 * 1024);
      final s = parse(head);
      if (s == null || s.$1 <= 0 || s.$2 <= 0) return null;
      return s.$2 / s.$1;
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List> _head(String path, int n) async {
    if (Remote.isRemote(path)) {
      try {
        return await Remote.range(path, 0, n);
      } on RangeUnsupported {
        return Uint8List(0);
      }
    }
    final raf = await File(path).open();
    try {
      return await raf.read(n);
    } finally {
      await raf.close();
    }
  }

  /// (가로, 세로). JPEG 은 회전 표시(EXIF 방향 5~8)면 가로 · 세로를 바꿔서 — 화면에 보이는 모양 그대로
  static (int, int)? parse(Uint8List b) {
    if (b.length < 30) return null;
    final d = ByteData.sublistView(b);
    // PNG
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      return (d.getUint32(16), d.getUint32(20));
    }
    // GIF
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
      return (d.getUint16(6, Endian.little), d.getUint16(8, Endian.little));
    }
    // BMP
    if (b[0] == 0x42 && b[1] == 0x4D) {
      return (d.getInt32(18, Endian.little).abs(), d.getInt32(22, Endian.little).abs());
    }
    // WebP
    if (_tag(b, 0, 'RIFF') && _tag(b, 8, 'WEBP')) {
      if (_tag(b, 12, 'VP8 ') && b.length >= 30) {
        return (d.getUint16(26, Endian.little) & 0x3FFF, d.getUint16(28, Endian.little) & 0x3FFF);
      }
      if (_tag(b, 12, 'VP8L') && b.length >= 25) {
        final w = 1 + (((b[22] & 0x3F) << 8) | b[21]);
        final h = 1 + (((b[24] & 0x0F) << 10) | (b[23] << 2) | ((b[22] & 0xC0) >> 6));
        return (w, h);
      }
      if (_tag(b, 12, 'VP8X') && b.length >= 30) {
        return (1 + (b[24] | b[25] << 8 | b[26] << 16), 1 + (b[27] | b[28] << 8 | b[29] << 16));
      }
      return null;
    }
    // JPEG
    if (b[0] == 0xFF && b[1] == 0xD8) {
      var i = 2;
      var turn = false;
      while (i + 9 < b.length) {
        if (b[i] != 0xFF) return null;
        final m = b[i + 1];
        if (m == 0xFF) {
          i++; // 채움 바이트
          continue;
        }
        if (m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7)) {
          i += 2;
          continue;
        }
        final len = d.getUint16(i + 2);
        if (m == 0xE1 && _tag(b, i + 4, 'Exif')) turn = _exifTurned(b, i + 10, len - 8);
        // 그림 크기가 적힌 칸 (SOF0~SOF15, 단 C4 · C8 · CC 는 아님)
        if (m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC) {
          final h = d.getUint16(i + 5), w = d.getUint16(i + 7);
          return turn ? (h, w) : (w, h);
        }
        if (m == 0xDA) return null; // 그림 내용이 시작됐는데 크기를 못 찾음
        i += 2 + len;
      }
    }
    return null;
  }

  static bool _tag(Uint8List b, int at, String s) {
    if (at + s.length > b.length) return false;
    for (var k = 0; k < s.length; k++) {
      if (b[at + k] != s.codeUnitAt(k)) return false;
    }
    return true;
  }

  /// EXIF 방향이 5~8 (90° 돌림) 인가
  static bool _exifTurned(Uint8List b, int tiff, int len) {
    try {
      if (tiff + 8 > b.length) return false;
      final le = b[tiff] == 0x49; // II = 작은 쪽 먼저, MM = 큰 쪽 먼저
      final d = ByteData.sublistView(b);
      final e = le ? Endian.little : Endian.big;
      final ifd = tiff + d.getUint32(tiff + 4, e);
      if (ifd + 2 > b.length) return false;
      final n = d.getUint16(ifd, e);
      for (var k = 0; k < n; k++) {
        final at = ifd + 2 + k * 12;
        if (at + 12 > b.length) return false;
        if (d.getUint16(at, e) == 0x0112) {
          final o = d.getUint16(at + 8, e);
          return o >= 5 && o <= 8;
        }
      }
    } catch (_) {}
    return false;
  }
}
