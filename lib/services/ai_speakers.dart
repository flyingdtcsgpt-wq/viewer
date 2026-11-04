import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'ai_service.dart';

/// AI(Claude API, 선택)로 찾은 대사 화자 { 블록 번호: 이름 } — 책마다 파일로 남겨 다시 묻지 않는다
///
/// 규칙("○○가 말했다")으로 못 찾은 대사에 쓴다. 순서: 사용자가 정한 목소리 > 규칙 > AI > 주고받기 > 대사 목소리.
/// 기기 안 작은 언어 모델로 하는 방법도 검토했으나, 쓸 만한 정확도의 모델은 1GB 넘고 PC CPU 로 책 한 권에 몇 시간이 걸려
/// 저렴한 API 를 선택 사항으로 두었다.
class AiSpeakers {
  AiSpeakers._();

  static Future<File> _file(int bookId) async {
    final d = Directory(p.join((await getApplicationSupportDirectory()).path, 'ai_speakers'));
    await d.create(recursive: true);
    return File(p.join(d.path, '$bookId.json'));
  }

  static Future<Map<int, String>> load(int bookId) async {
    try {
      final f = await _file(bookId);
      if (!await f.exists()) return {};
      final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return {for (final e in (m['speakers'] as Map<String, dynamic>).entries) int.parse(e.key): e.value as String};
    } catch (_) {
      return {};
    }
  }

  static Future<void> save(int bookId, Map<int, String> m) async {
    final f = await _file(bookId);
    await f.writeAsString(jsonEncode({
      'version': 1,
      'speakers': {for (final e in m.entries) '${e.key}': e.value},
    }));
  }

  static Future<void> clear(int bookId) async {
    final f = await _file(bookId);
    if (await f.exists()) await f.delete();
  }

  /// 묻는 묶음: 대사가 있는 문단을 포함해 약 [budget] 자씩 이어진 문단 덩어리 (앞뒤 흐름이 보이게)
  static List<List<(int, String)>> windows(List<(int, String)> paras, bool Function(String) hasDialogue, {int budget = 6000}) {
    final out = <List<(int, String)>>[];
    var cur = <(int, String)>[];
    var n = 0;
    var any = false;
    for (final (i, t) in paras) {
      final cut = t.length > 500 ? '${t.substring(0, 500)}…' : t;
      cur.add((i, cut));
      n += cut.length;
      any |= hasDialogue(t);
      if (n >= budget) {
        if (any) out.add(cur);
        // 다음 묶음도 앞 두 문단을 이어서 보이게
        cur = cur.length > 2 ? cur.sublist(cur.length - 2) : <(int, String)>[];
        n = cur.fold(0, (a, b) => a + b.$2.length);
        any = false;
      }
    }
    if (any) out.add(cur);
    return out;
  }

  /// 책 전체 분석. 이미 분석한 문단은 건너뛴다 (멈췄다가 이어서)
  static Future<Map<int, String>> analyze({
    required int bookId,
    required AiService ai,
    required List<(int, String)> paras,
    required bool Function(String) hasDialogue,
    required List<String> known,
    void Function(int done, int total)? onProgress,
    bool Function()? cancelled,
  }) async {
    final result = await load(bookId);
    final todo = windows(paras, hasDialogue).where((w) => w.any((e) => hasDialogue(e.$2) && !result.containsKey(e.$1))).toList();
    final names = [...known];
    for (var i = 0; i < todo.length; i++) {
      if (cancelled?.call() ?? false) break;
      final text = todo[i].map((e) => '[${e.$1}] ${e.$2}').join('\n');
      final got = await ai.dialogueSpeakers(text, names);
      final allowed = {for (final e in todo[i]) e.$1};
      for (final e in got.entries) {
        if (!allowed.contains(e.key)) continue;
        result[e.key] = e.value;
        if (!names.contains(e.value)) names.add(e.value);
      }
      await save(bookId, result); // 묶음마다 저장 (중간에 멈춰도 남음)
      onProgress?.call(i + 1, todo.length);
    }
    return result;
  }

  /// 대략 쓰는 양 (입력 글자 수 → 토큰 어림)
  static int estimateTokens(List<(int, String)> paras, bool Function(String) hasDialogue) =>
      windows(paras, hasDialogue).fold(0, (a, w) => a + w.fold(0, (b, e) => b + e.$2.length)) * 2 ~/ 3 + 400;
}
