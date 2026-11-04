import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:basic_utils/basic_utils.dart' show CryptoUtils, X509Utils, RSAPrivateKey, RSAPublicKey;
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 공유 서버 HTTPS 용 자체 서명 인증서 (처음 한 번 만들어 두고 계속 씀, 10년)
///
/// 공인 인증서가 아니라서 브라우저가 처음 한 번 "안전하지 않음" 경고를 띄운다 → "고급 › 계속" 으로 들어가면 된다.
/// 같은 Wi-Fi 안에서 오가는 내용(비밀번호 · 파일)을 엿볼 수 없게 하는 것이 목적이다.
class ShareCert {
  ShareCert._();

  static Future<Directory> _dir() async {
    final d = Directory(p.join((await getApplicationSupportDirectory()).path, 'share_tls'));
    await d.create(recursive: true);
    return d;
  }

  /// (인증서 PEM, 개인키 PEM). 없으면 만든다 (RSA 2048, 몇 초 걸림 — 따로 도는 일꾼에서)
  static Future<(String, String)> load() async {
    final d = await _dir();
    final cert = File(p.join(d.path, 'cert.pem')), key = File(p.join(d.path, 'key.pem'));
    if (await cert.exists() && await key.exists()) return (await cert.readAsString(), await key.readAsString());
    final made = await Isolate.run(_make);
    await cert.writeAsString(made.$1);
    await key.writeAsString(made.$2);
    return made;
  }

  static (String, String) _make() {
    final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
    final priv = pair.privateKey as RSAPrivateKey, pub = pair.publicKey as RSAPublicKey;
    final csr = X509Utils.generateRsaCsrPem({'CN': 'ARARIFlex', 'O': 'ARARIFlex'}, priv, pub);
    final cert = X509Utils.generateSelfSignedCertificate(priv, csr, 3650, serialNumber: '${DateTime.now().millisecondsSinceEpoch}');
    return (cert, CryptoUtils.encodeRSAPrivateKeyToPem(priv));
  }

  static Future<SecurityContext> context() async {
    final (cert, key) = await load();
    return SecurityContext()
      ..useCertificateChainBytes(utf8.encode(cert))
      ..usePrivateKeyBytes(utf8.encode(key));
  }

  /// 인증서 지문 앞부분 (휴대폰 경고 화면의 지문과 같은지 확인용)
  static Future<String> fingerprint() async {
    final (cert, _) = await load();
    final b64 = cert.split('\n').where((l) => !l.startsWith('-----')).join();
    final h = sha256.convert(base64.decode(b64)).bytes;
    return [for (final b in h.take(8)) b.toRadixString(16).padLeft(2, '0').toUpperCase()].join(':');
  }

  /// 새 인증서로 바꾸기
  static Future<void> reset() async {
    final d = await _dir();
    for (final n in ['cert.pem', 'key.pem']) {
      final f = File(p.join(d.path, n));
      if (await f.exists()) await f.delete();
    }
  }
}
