import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';

/// 라이브러리에 대해 자유롭게 묻는 AI 사서 (예: "읽지 않은 SF 추천해줘")
void showAiChat(BuildContext context) {
  final state = context.read<AppState>();
  if (!state.ai.enabled) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('설정에서 Claude API 키를 넣으면 AI 도우미를 쓸 수 있습니다.')),
    );
    return;
  }
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 760),
    builder: (_) => const _AiChat(),
  );
}

class _AiChat extends StatefulWidget {
  const _AiChat();
  @override
  State<_AiChat> createState() => _AiChatState();
}

class _AiChatState extends State<_AiChat> {
  final _c = TextEditingController();
  final _log = <(bool, String)>[]; // (isUser, text)
  bool _busy = false;

  Future<void> _send() async {
    final q = _c.text.trim();
    if (q.isEmpty || _busy) return;
    final state = context.read<AppState>();
    setState(() {
      _log.add((true, q));
      _busy = true;
      _c.clear();
    });
    try {
      final a = await state.ai.chat(q, state.allItems);
      setState(() => _log.add((false, a)));
    } catch (e) {
      setState(() => _log.add((false, '오류: $e')));
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(children: [
          const ListTile(leading: Icon(Icons.auto_awesome), title: Text('AI 사서')),
          Expanded(
            child: ListView(padding: const EdgeInsets.all(12), children: [
              for (final (user, text) in _log)
                Align(
                  alignment: user ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.all(10),
                    constraints: const BoxConstraints(maxWidth: 560),
                    decoration: BoxDecoration(
                      color: user ? scheme.primaryContainer : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: SelectableText(text),
                  ),
                ),
              if (_busy) const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator()),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _c,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                hintText: '예) 내 책 중 판타지 시리즈만 정리해줘',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(icon: const Icon(Icons.send), onPressed: _send),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
