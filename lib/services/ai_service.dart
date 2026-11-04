import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/media_item.dart';
import 'settings.dart';

/// (선택) AI 도우미 — Claude API 키를 설정에 넣으면 활성화
/// 1) 지저분한 파일명 → 제목/저자/시리즈/권수 추출
/// 2) 태그/장르 추천
/// 3) 줄거리 요약 / 자유 질문
class AiService {
  final Settings settings;
  AiService(this.settings);

  bool get enabled => settings.aiKey.isNotEmpty;

  Future<String> _ask(String system, String user, {int maxTokens = 800}) async {
    final res = await http.post(
      Uri.parse('https://api.anthropic.com/v1/messages'),
      headers: {
        'x-api-key': settings.aiKey,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
      },
      body: jsonEncode({
        'model': settings.aiModel,
        'max_tokens': maxTokens,
        'system': system,
        'messages': [
          {'role': 'user', 'content': user}
        ],
      }),
    );
    if (res.statusCode != 200) {
      throw Exception('AI 요청 실패 (${res.statusCode}): ${res.body}');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    return (data['content'] as List).where((b) => b['type'] == 'text').map((b) => b['text']).join();
  }

  Map<String, dynamic> _json(String text) {
    final m = RegExp(r'\{[\s\S]*\}').firstMatch(text);
    return m == null ? {} : jsonDecode(m.group(0)!) as Map<String, dynamic>;
  }

  /// 소설 대사 화자: [numbered] 는 "[블록번호] 문단" 줄들. 돌려줌 { 블록번호: 이름 } (모르면 빠짐)
  Future<Map<int, String>> dialogueSpeakers(String numbered, List<String> known) async {
    final text = await _ask(
      '너는 소설 편집자다. 문단마다 큰따옴표(또는 「」) 대사를 누가 말했는지 앞뒤 흐름으로 판단한다. 반드시 JSON 객체만 출력한다.',
      '아래는 소설의 연속된 문단이다. 각 줄 맨 앞 [숫자] 는 문단 번호다.\n'
          '대사가 있는 문단마다 그 대사를 말한 인물 이름을 {"번호": "이름"} 으로 답해. 한 문단에 여러 사람이 말하면 처음 말한 사람.\n'
          '이름은 본문에 나온 표기 그대로(영어 소설이면 성만, 예: Holmes). 알려진 인물: ${known.take(40).join(', ')}\n'
          '확실하지 않으면 그 번호는 빼라. 대사가 없는 문단도 빼라.\n\n$numbered',
      maxTokens: 1500,
    );
    final m = _json(text);
    return {
      for (final e in m.entries)
        if (int.tryParse(e.key) != null && e.value is String && (e.value as String).trim().isNotEmpty) int.parse(e.key): (e.value as String).trim(),
    };
  }

  /// 파일명에서 메타데이터 추정. 반환 키: title, author, series, volume, query
  Future<Map<String, dynamic>> parseFileName(String fileName) async {
    final text = await _ask(
      '너는 전자책/만화/영상 파일명을 분석하는 도우미다. 반드시 JSON 객체만 출력한다.',
      '다음 파일명에서 정보를 추출해 {"title":"","author":"","series":"","volume":null,"query":""} 형태로 답해. '
          'query 는 온라인 도서 검색에 쓸 가장 좋은 검색어. 모르면 빈 문자열.\n파일명: $fileName',
    );
    return _json(text);
  }

  /// 시리즈 정보: total(전체 권/화 수), status(ongoing/completed/hiatus/unknown), author, description
  Future<Map<String, dynamic>> seriesInfo(String title, {required bool isVideo}) async {
    final text = await _ask(
      '너는 만화·소설·애니메이션·영화 시리즈 정보를 아는 사서다. 반드시 JSON 객체만 출력한다. 확실하지 않으면 null.',
      '"$title" (${isVideo ? '영상: 애니/드라마/영화' : '책: 만화/소설'}) 의 정보를 '
          '{"total": 전체 ${isVideo ? '화(편)' : '권'} 수 또는 null, "status": "ongoing"|"completed"|"hiatus"|"unknown", '
          '"author": "작가/감독" 또는 "", "description": "한두 문장 소개"} 로 답해. 한국 정발 기준.',
    );
    return _json(text);
  }

  Future<List<String>> suggestTags(MediaItem item) async {
    final text = await _ask(
      '너는 개인 서재 정리 도우미다. 반드시 JSON 객체만 출력한다.',
      '다음 항목에 어울리는 한국어 태그(장르/주제) 3~6개를 {"tags":[...]} 로 답해.\n'
          '종류: ${kindLabel(item.kind)}\n제목: ${item.title}\n저자: ${item.author ?? ''}\n'
          '설명: ${(item.description ?? '').substring(0, (item.description ?? '').length.clamp(0, 1500))}',
    );
    return ((_json(text)['tags'] as List?) ?? []).map((e) => e.toString()).toList();
  }

  Future<String> chat(String question, List<MediaItem> context) {
    final list = context.take(200).map((e) => '- [${kindLabel(e.kind)}] ${e.title} / ${e.author ?? ''} / 태그:${e.tags.join(',')}').join('\n');
    return _ask(
      '너는 사용자의 개인 라이브러리(책·만화·그림·영상)를 도와주는 사서다. 한국어로 간결하게 답한다.',
      '내 라이브러리 일부:\n$list\n\n질문: $question',
      maxTokens: 1500,
    );
  }
}
