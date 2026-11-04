import 'dart:io';

import 'package:flutter/services.dart';

/// 안드로이드: 소리 내어 읽는 동안 알림을 띄우고 앱이 잠들지 않게 한다 (화면을 꺼도 계속 읽기)
class BackgroundReading {
  BackgroundReading._();
  static const _ch = MethodChannel('mediashelf/bg');
  static bool _on = false;

  static Future<void> start(String title) async {
    if (!Platform.isAndroid || _on) return;
    _on = true;
    try {
      await _ch.invokeMethod('start', {'title': title});
    } catch (_) {}
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid || !_on) return;
    _on = false;
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
  }
}
