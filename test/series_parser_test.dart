import 'package:flutter_test/flutter_test.dart';
import 'package:media_shelf/models/series.dart';
import 'package:media_shelf/services/series_parser.dart';

void main() {
  void check(String name, String title, double? vol) {
    final r = parseName(name);
    expect((r.title, r.volume), (title, vol), reason: name);
  }

  test('권/화 번호 추출', () {
    check('명탐정 코난 01권.cbz', '명탐정 코난', 1);
    check('명탐정 코난 제103권.zip', '명탐정 코난', 103);
    check('[아오야마 고쇼] 명탐정 코난 v05.cbz', '명탐정 코난', 5);
    check('명탐정코난_012.cbz', '명탐정코난', 12);
    check('One Piece Vol.100.cbz', 'One Piece', 100);
    check('Detective Conan S01E05.mkv', 'Detective Conan', 5);
    check('진격의 거인 S02E03.mp4', '진격의 거인 시즌2', 3);
    check('나 혼자만 레벨업 10.5권.epub', '나 혼자만 레벨업', 10.5);
    check('블레이드 러너 2049.mkv', '블레이드 러너 2049', null);
    check('Code 3.txt', 'Code', 3);
    check('소년이 온다.epub', '소년이 온다', null);
  });

  test('완결 표시', () {
    expect(parseName('드래곤볼 (완결) 42권.cbz').statusHint, SeriesStatus.completed);
  });

  test('외전 판별', () {
    expect(isSpinOffOf('명탐정 코난', '명탐정 코난 제로의 일상'), isTrue);
    expect(isSpinOffOf('명탐정 코난', '명탐정 코난'), isFalse);
    expect(isSpinOffOf('원피스', '원피스타'), isFalse);
  });
}
