// 안드로이드 에뮬레이터 캡처용 드라이버: 앱이 보낸 화면 · 음성 파일을 shots-android/shots 에 저장
import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(responseDataCallback: (data) async {
      final files = (data?['files'] as Map?) ?? const {};
      final dir = Directory('shots-android/shots')..createSync(recursive: true);
      for (final e in files.entries) {
        File('${dir.path}/${e.key}').writeAsBytesSync(base64Decode(e.value as String));
      }
      stdout.writeln('DRIVER saved ${files.length} files');
    });
