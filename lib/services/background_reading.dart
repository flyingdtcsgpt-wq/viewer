import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 안드로이드: 소리 내어 읽는 동안 알림을 띄우고 앱이 잠들지 않게 한다 (화면을 꺼도 계속 읽기)
class BackgroundReading {
  BackgroundReading._();
  static const _ch = MethodChannel('arariflex/bg');
  static bool _on = false;
  static String _title = '';

  static Future<void> start(String title) async {
    // 이미 켜져 있어도 제목이 바뀌었으면 알림을 고친다 (다음 권으로 이어 읽을 때)
    if (!Platform.isAndroid || (_on && title == _title)) return;
    _on = true;
    _title = title;
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

/// 안드로이드: 뷰어가 열려 있는 동안 화면이 꺼지지 않게 (여러 뷰어가 겹쳐도 마지막 것이 닫힐 때 푼다)
class ScreenAwake {
  ScreenAwake._();
  static const _ch = MethodChannel('arariflex/bg');
  static int _holds = 0;

  static void hold() {
    if (++_holds == 1) _set(true);
  }

  static void release() {
    if (_holds > 0 && --_holds == 0) _set(false);
  }

  static void _set(bool on) {
    if (!Platform.isAndroid) return;
    _ch.invokeMethod('keepScreen', {'on': on}).catchError((_) => null);
  }
}

/// 볼륨 버튼으로 쪽 넘기기에 쓰는 단축키 (안드로이드에서 설정을 켰을 때만)
Map<ShortcutActivator, VoidCallback> volumeKeyBindings(bool enabled, void Function(int dir) turn) => !Platform.isAndroid || !enabled
    ? const {}
    : {
        const SingleActivator(LogicalKeyboardKey.audioVolumeDown): () => turn(1),
        const SingleActivator(LogicalKeyboardKey.audioVolumeUp): () => turn(-1),
      };
