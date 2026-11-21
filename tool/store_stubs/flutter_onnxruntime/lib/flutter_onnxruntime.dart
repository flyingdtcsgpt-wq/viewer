/// 플레이스토어판 빌드용 빈 껍데기 (tool/patch_android.py --store 가 pubspec_overrides.yaml 로 바꿔 끼운다).
///
/// 진짜 flutter_onnxruntime 과 같은 이름 · 모양만 갖추고, 부르면 "지원하지 않음" 오류를 낸다.
/// 플레이스토어판은 읽어주기(자연 음성) · 글자 인식 화면이 없어 실제로 불리지 않는다.
/// 앱 코드가 쓰는 범위가 늘어나면 여기에도 같은 이름을 더해야 플레이스토어판이 빌드된다.
library;

Never _no() => throw UnsupportedError('이 판에는 ONNX 런타임이 들어 있지 않습니다');

class OnnxRuntime {
  Future<OrtSession> createSession(String modelPath) async => _no();
}

class OrtSession {
  List<String> get inputNames => _no();
  List<String> get outputNames => _no();
  Future<Map<String, OrtValue>> run(Map<String, OrtValue> inputs) async => _no();
  Future<void> close() async {}
}

class OrtValue {
  static Future<OrtValue> fromList(dynamic data, List<int> shape) async => _no();
  List<int> get shape => _no();
  Future<List<dynamic>> asFlattenedList() async => _no();
  Future<void> dispose() async {}
}
