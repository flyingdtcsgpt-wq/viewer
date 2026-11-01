import 'package:flutter_test/flutter_test.dart';
import 'package:media_shelf/services/auth.dart';

void main() {
  test('비밀번호 해시/확인', () {
    final u = AppUser(name: 'a')..setPassword('1234');
    expect(u.hasPassword, isTrue);
    expect(u.pwHash.contains('1234'), isFalse);
    expect(u.check('1234'), isTrue);
    expect(u.check('12345'), isFalse);
    final v = AppUser(name: 'b')..setPassword('1234');
    expect(v.pwHash == u.pwHash, isFalse, reason: '솔트가 달라야 함');
  });

  test('비밀번호 없는 사용자', () {
    final u = AppUser(name: 'kid');
    expect(u.check(''), isTrue);
  });
}
