import 'dart:typed_data';

import 'package:arariflex/services/image_size.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// 그림 크기를 파일 머리만 읽어 알아내기 (이어 보기의 자리 높이)
void main() {
  final pic = img.Image(width: 300, height: 120);

  test('PNG · JPEG · GIF · BMP', () {
    expect(ImageSize.parse(img.encodePng(pic)), (300, 120));
    expect(ImageSize.parse(img.encodeJpg(pic)), (300, 120));
    expect(ImageSize.parse(img.encodeGif(pic)), (300, 120));
    expect(ImageSize.parse(img.encodeBmp(pic)), (300, 120));
  });

  test('JPEG 회전 표시(EXIF 6: 90° 돌림)면 가로 · 세로를 바꾼다', () {
    final b = BytesBuilder()
      ..add([0xFF, 0xD8])
      // APP1 Exif: MM, IFD0 에 방향(0x0112) = 6
      ..add([0xFF, 0xE1, 0x00, 0x22])
      ..add('Exif'.codeUnits)
      ..add([0, 0])
      ..add([0x4D, 0x4D, 0x00, 0x2A, 0, 0, 0, 8])
      ..add([0x00, 0x01])
      ..add([0x01, 0x12, 0x00, 0x03, 0, 0, 0, 1, 0x00, 0x06, 0, 0])
      ..add([0, 0, 0, 0])
      // SOF0: 높이 100, 가로 200
      ..add([0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x64, 0x00, 0xC8, 0x03, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1])
      ..add(List.filled(16, 0));
    expect(ImageSize.parse(b.toBytes()), (100, 200));
  });

  test('WebP (VP8X 머리)', () {
    final b = Uint8List(40);
    b.setAll(0, 'RIFF'.codeUnits);
    b.setAll(8, 'WEBP'.codeUnits);
    b.setAll(12, 'VP8X'.codeUnits);
    // 가로 1920 → 1919, 세로 1080 → 1079 (3바이트, 작은 쪽 먼저)
    b.setAll(24, [1919 & 0xFF, (1919 >> 8) & 0xFF, 0, 1079 & 0xFF, (1079 >> 8) & 0xFF, 0]);
    expect(ImageSize.parse(b), (1920, 1080));
  });

  test('모르는 형식 · 너무 짧으면 null', () {
    expect(ImageSize.parse(Uint8List(10)), isNull);
    expect(ImageSize.parse(Uint8List.fromList(List.filled(64, 7))), isNull);
  });
}
