// 안드로이드 에뮬레이터 캡처용 드라이버
// 앱이 보낸 화면 · 음성 파일을 shots-android/shots 에 저장한다. 테스트가 실패해도 받은 것은 저장한다.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';
import 'package:integration_test/common.dart';

Future<void> main() async {
  final driver = await FlutterDriver.connect();
  final json = await driver.requestData(null, timeout: const Duration(minutes: 40));
  await driver.close();
  final response = Response.fromJson(json);
  final files = (response.data?['files'] as Map?) ?? const {};
  final dir = Directory('shots-android/shots')..createSync(recursive: true);
  for (final e in files.entries) {
    File('${dir.path}/${e.key}').writeAsBytesSync(base64Decode(e.value as String));
  }
  stdout.writeln('DRIVER saved ${files.length} files, allTestsPassed=${response.allTestsPassed}');
  if (!response.allTestsPassed) {
    stdout.writeln('DRIVER failures: ${response.formattedFailureDetails}');
  }
  exit(response.allTestsPassed ? 0 : 1);
}
