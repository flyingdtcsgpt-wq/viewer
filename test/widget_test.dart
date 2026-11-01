import 'package:flutter_test/flutter_test.dart';
import 'package:media_shelf/models/media_item.dart';
import 'package:media_shelf/services/organizer.dart';

void main() {
  test('확장자로 종류 판별', () {
    expect(kindForPath('a/b.EPUB'), MediaKind.book);
    expect(kindForPath('a/b.cbz'), MediaKind.comic);
    expect(kindForPath('a/b.webp'), MediaKind.image);
    expect(kindForPath('a/b.mkv'), MediaKind.video);
    expect(kindForPath('a/b.exe'), isNull);
  });

  test('정리 규칙 경로', () {
    final item = MediaItem(path: '/x/소년이 온다.epub', kind: MediaKind.book, title: '소년이 온다', author: '한강');
    final out = Organizer.targetPath('/lib', '{kind}/{author}/{title}', item);
    expect(out.replaceAll('\\', '/'), '/lib/책/한강/소년이 온다.epub');
  });
}
