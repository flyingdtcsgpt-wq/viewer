import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/natural_tts.dart';
import '../../services/ocr_service.dart';
import '../../services/settings.dart';
import '../../services/tts_service.dart';
import 'viewer_chrome.dart';

/// 쪽 단위 소리 내어 읽기 (PDF · 만화 · 그림)
///
/// [textOf] 가 쪽의 글을 돌려준다 (PDF 글자, 없으면 글자 인식).
/// 다 읽으면 [goTo] 로 다음 쪽으로 넘기고 이어서 읽는다.
class ReadAloudBar extends StatefulWidget {
  final int pageCount;
  final int Function() currentPage; // 0 부터
  final Future<String> Function(int page) textOf;
  final void Function(int page) goTo;
  final VoidCallback onClose;
  const ReadAloudBar({
    super.key,
    required this.pageCount,
    required this.currentPage,
    required this.textOf,
    required this.goTo,
    required this.onClose,
  });

  @override
  State<ReadAloudBar> createState() => _ReadAloudBarState();
}

class _ReadAloudBarState extends State<ReadAloudBar> {
  final _tts = TtsService();
  final Map<int, Future<String>> _texts = {};
  List<String> _voices = [];
  bool _speaking = false;
  int _run = 0; // 멈추거나 다시 시작하면 바뀜 (이전 읽기 루프 중단)
  String _status = '';

  @override
  void initState() {
    super.initState();
    TtsService.voices().then((v) {
      if (mounted) setState(() => _voices = v);
    });
  }

  @override
  void dispose() {
    _run++;
    _tts.dispose();
    super.dispose();
  }

  Future<String> _text(int page) => _texts.putIfAbsent(page, () async {
        try {
          return await widget.textOf(page);
        } catch (e) {
          _texts.remove(page);
          rethrow;
        }
      });

  /// 문장 단위로 나누되 너무 짧은 조각은 붙인다
  static List<String> _sentences(String text) {
    final out = <String>[];
    for (final para in text.split(RegExp(r'\n+'))) {
      var cur = '';
      for (final s in para.split(RegExp(r'(?<=[.!?。？！])\s+'))) {
        final t = s.trim();
        if (t.isEmpty) continue;
        if (cur.isEmpty) {
          cur = t;
        } else if (cur.length + t.length < 160) {
          cur = '$cur $t';
        } else {
          out.add(cur);
          cur = t;
        }
      }
      if (cur.isNotEmpty) out.add(cur);
    }
    return out;
  }

  Future<void> _play() async {
    final run = ++_run;
    final s = context.read<Settings>();
    setState(() => _speaking = true);
    var page = widget.currentPage();
    while (mounted && run == _run && page < widget.pageCount) {
      setState(() => _status = '${page + 1}쪽 글자 읽는 중…');
      String text;
      try {
        text = await _text(page);
      } on OcrUnavailable catch (e) {
        _fail(e.message);
        return;
      } catch (e) {
        text = '';
      }
      if (!mounted || run != _run) return;
      // 다음 쪽 글도 미리 (글자 인식은 몇 초 걸린다)
      if (page + 1 < widget.pageCount) _text(page + 1).ignore();
      final parts = _sentences(text);
      if (parts.isEmpty) {
        setState(() => _status = '${page + 1}쪽에서 글자를 찾지 못해 넘어갑니다');
      } else {
        setState(() => _status = '${page + 1}쪽 읽는 중');
        for (var k = 0; k < parts.length; k++) {
          if (k + 1 < parts.length) _tts.prefetch(parts[k + 1], voice: s.ttsVoice, rate: s.ttsRate);
          final ok = await _tts.speak(parts[k], voice: s.ttsVoice, rate: s.ttsRate);
          if (!mounted || run != _run) return;
          if (!ok) {
            if (_tts.failed) _fail('음성을 재생하지 못했습니다. 다른 음성을 골라 보세요.');
            return;
          }
        }
      }
      page++;
      if (page < widget.pageCount) widget.goTo(page);
    }
    if (mounted && run == _run) {
      setState(() {
        _speaking = false;
        _status = '끝까지 읽었습니다';
      });
    }
  }

  void _fail(String msg) {
    if (!mounted) return;
    setState(() {
      _speaking = false;
      _status = msg;
    });
  }

  Future<void> _stop() async {
    _run++;
    setState(() {
      _speaking = false;
      _status = '';
    });
    await _tts.stop();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Settings>();
    const speeds = [-4, -2, 0, 2, 4, 6];
    return Material(
      color: const Color(0xF0222222),
      elevation: 8,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, runSpacing: 6, children: [
            ToolGroup([
              ToolBtn(
                icon: _speaking ? Icons.pause : Icons.play_arrow,
                tooltip: _speaking ? '멈춤' : '이 쪽부터 읽기',
                active: _speaking,
                onTap: () => _speaking ? _stop() : _play(),
              ),
              ToolBtn(
                icon: Icons.skip_next,
                tooltip: '다음 쪽부터',
                onTap: () async {
                  await _stop();
                  final n = widget.currentPage() + 1;
                  if (n < widget.pageCount) {
                    widget.goTo(n);
                    Future.delayed(const Duration(milliseconds: 300), () {
                      if (mounted) _play();
                    });
                  }
                },
              ),
            ]),
            PopupMenuButton<int>(
              tooltip: '속도',
              color: toolBg,
              onSelected: (v) => s.ttsRate = v,
              itemBuilder: (_) => [
                for (final r in speeds)
                  PopupMenuItem(value: r, child: Text('${(1 + r * 0.1).toStringAsFixed(1)}x', style: const TextStyle(color: Colors.white))),
              ],
              child: ToolGroup([ToolBtn(label: '${(1 + s.ttsRate * 0.1).toStringAsFixed(1)}x', tooltip: '속도')]),
            ),
            DropdownButton<String>(
              dropdownColor: toolBg,
              value: _voices.contains(s.ttsVoice) ? s.ttsVoice : null,
              hint: const Text('기본 음성', style: TextStyle(color: Colors.white70)),
              style: const TextStyle(color: Colors.white),
              items: [for (final v in _voices) DropdownMenuItem(value: v, child: Text(TtsService.label(v)))],
              onChanged: (v) => s.ttsVoice = v ?? '',
            ),
            IconButton(
              tooltip: '닫기',
              onPressed: () async {
                await _stop();
                widget.onClose();
              },
              icon: const Icon(Icons.close, color: Colors.white54),
            ),
          ]),
          if (_status.isNotEmpty) Text(_status, style: const TextStyle(color: Colors.white70, fontSize: 12)),
          if (_voices.isNotEmpty && !_voices.any(NaturalTts.isNatural))
            const Text('자연스러운 음성은 설정 › 읽어주기 음성에서 받을 수 있습니다', style: TextStyle(color: Colors.white38, fontSize: 11)),
        ]),
      ),
    );
  }
}
