import 'package:flutter_test/flutter_test.dart';
import 'package:arariflex/services/text_document.dart';

/// EPUB 을 "원본 스타일"(장 번호 + 장 안에서의 비율) ↔ "읽기 최적화"(문단 번호)로 바꿔 볼 때 읽던 자리가 이어지는지
void main() {
  final blocks = [for (var i = 0; i < 100; i++) TextBlock.text('p$i')];
  // 장 0 = 문단 0~9, 장 1 = 비어 있음, 장 2 = 10~59, 장 3 = 60~99
  final doc = TextDocument(blocks, const [], 'EPUB', spineStarts: const [0, 10, 10, 60]);

  test('장:비율 → 문단 번호', () {
    expect(doc.blockOfSpine(0, 0), 0);
    expect(doc.blockOfSpine(1, 0.5), 10); // 빈 장은 다음 장의 처음
    expect(doc.blockOfSpine(2, 0.5), 35);
    expect(doc.blockOfSpine(3, 1.0), 99); // 끝을 넘지 않는다
    expect(doc.blockOfSpine(9, 0), 60); // 없는 장 번호는 마지막 장
  });

  test('문단 번호 → 장:비율', () {
    expect(doc.spineOfBlock(0), (0, 0.0));
    expect(doc.spineOfBlock(35), (2, 0.5));
    expect(doc.spineOfBlock(99).$1, 3);
  });

  test('갔다가 돌아와도 같은 자리', () {
    for (final b in [0, 7, 10, 42, 60, 99]) {
      final (c, r) = doc.spineOfBlock(b);
      expect(doc.blockOfSpine(c, r), b, reason: '문단 $b');
    }
  });

  test('TXT (장 정보 없음)', () {
    final txt = TextDocument(blocks, const [], 'UTF-8');
    expect(txt.blockOfSpine(3, 0.5), 0);
    expect(txt.spineOfBlock(40), (0, 0.0));
  });
}
