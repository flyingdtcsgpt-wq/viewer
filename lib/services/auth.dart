import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// 비밀번호는 원문을 저장하지 않고 PBKDF2-HMAC-SHA256 (솔트 + 2만 회 반복) 해시만 저장한다.
class PasswordHash {
  static const _iterations = 20000;

  static String newSalt() {
    final r = Random.secure();
    return base64Encode(List<int>.generate(16, (_) => r.nextInt(256)));
  }

  static String hash(String password, String salt) {
    final hmac = Hmac(sha256, utf8.encode(password));
    final block = Uint8List.fromList([...base64Decode(salt), 0, 0, 0, 1]);
    var u = hmac.convert(block).bytes;
    final out = Uint8List.fromList(u);
    for (var i = 1; i < _iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < out.length; j++) {
        out[j] ^= u[j];
      }
    }
    return base64Encode(out);
  }

  /// 타이밍 공격을 피하는 비교
  static bool verify(String password, String salt, String expected) {
    final a = utf8.encode(hash(password, salt));
    final b = utf8.encode(expected);
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

enum UserRole { admin, user }

class AppUser {
  int? id;
  String name;
  UserRole role;
  String pwHash; // 빈 문자열이면 비밀번호 없음
  String salt;
  DateTime createdAt;

  AppUser({
    this.id,
    required this.name,
    this.role = UserRole.user,
    this.pwHash = '',
    this.salt = '',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  bool get isAdmin => role == UserRole.admin;
  bool get hasPassword => pwHash.isNotEmpty;

  void setPassword(String pw) {
    if (pw.isEmpty) {
      pwHash = '';
      salt = '';
    } else {
      salt = PasswordHash.newSalt();
      pwHash = PasswordHash.hash(pw, salt);
    }
  }

  bool check(String pw) => !hasPassword || PasswordHash.verify(pw, salt, pwHash);

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'name': name,
        'role': role.name,
        'pw_hash': pwHash,
        'salt': salt,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  factory AppUser.fromMap(Map<String, Object?> m) => AppUser(
        id: m['id'] as int?,
        name: m['name'] as String,
        role: UserRole.values.asNameMap()[m['role']] ?? UserRole.user,
        pwHash: m['pw_hash'] as String? ?? '',
        salt: m['salt'] as String? ?? '',
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
      );
}

/// 열람 기록 한 줄: 언제 열어서 어디까지 봤는지
class HistoryRecord {
  final int id;
  final int itemId;
  final DateTime openedAt;
  final DateTime? closedAt;
  final double progress;
  final String? position;
  const HistoryRecord(this.id, this.itemId, this.openedAt, this.closedAt, this.progress, this.position);

  factory HistoryRecord.fromMap(Map<String, Object?> m) => HistoryRecord(
        m['id'] as int,
        m['item_id'] as int,
        DateTime.fromMillisecondsSinceEpoch(m['opened_at'] as int),
        m['closed_at'] == null ? null : DateTime.fromMillisecondsSinceEpoch(m['closed_at'] as int),
        (m['progress'] as num?)?.toDouble() ?? 0,
        m['position'] as String?,
      );
}
