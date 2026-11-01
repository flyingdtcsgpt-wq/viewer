import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/media_item.dart';
import '../services/settings.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Settings>();
    final admin = context.watch<AppState>().isAdmin; // 라이브러리/키 설정은 관리자만
    return Scaffold(
      appBar: AppBar(title: const Text('설정')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(padding: const EdgeInsets.all(16), children: [
            if (admin) ...[
            const _Header('라이브러리'),
            ListTile(
              title: const Text('라이브러리 폴더 (정리 대상)'),
              subtitle: Text(s.libraryRoot ?? '지정 안 됨'),
              trailing: const Icon(Icons.folder),
              onTap: () async {
                final d = await FilePicker.getDirectoryPath(dialogTitle: '라이브러리 폴더 선택');
                if (d != null) s.libraryRoot = d;
              },
            ),
            ListTile(
              title: const Text('파일 가져올 때 기본 동작'),
              trailing: SegmentedButton<StorageMode>(
                segments: const [
                  ButtonSegment(value: StorageMode.reference, label: Text('원본 참조')),
                  ButtonSegment(value: StorageMode.managed, label: Text('폴더로 정리')),
                ],
                selected: {s.defaultStorage},
                onSelectionChanged: (v) => s.defaultStorage = v.first,
              ),
            ),
            SwitchListTile(
              title: const Text('정리 시 이동 (끄면 복사)'),
              value: s.moveFiles,
              onChanged: (v) => s.moveFiles = v,
            ),
            _TextSetting(
              label: '정리 규칙',
              help: '{kind} {author} {series} {title} {year} 사용 가능. 예) {kind}/{author}/{series}/{title}',
              value: s.organizePattern,
              onSave: (v) => s.organizePattern = v,
            ),
            SwitchListTile(
              title: const Text('시리즈 자동 묶기'),
              subtitle: const Text('스캔/가져오기 후 "명탐정 코난 01권" 같은 파일명을 보고 묶음으로 정리'),
              value: s.autoGroup,
              onChanged: (v) => s.autoGroup = v,
            ),
            const _Header('스캔 폴더'),
            for (final f in s.watchFolders)
              ListTile(
                dense: true,
                title: Text(f),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => s.watchFolders = s.watchFolders.where((e) => e != f).toList(),
                ),
              ),
            const _Header('책 정보 검색'),
            _TextSetting(
              label: 'Kakao REST API 키 (한국 도서 검색, 선택)',
              help: 'developers.kakao.com 에서 무료 발급',
              value: s.kakaoKey,
              obscure: true,
              onSave: (v) => s.kakaoKey = v,
            ),
            _TextSetting(
              label: 'Google Books API 키 (선택)',
              help: '없어도 동작하지만 하루 요청 한도가 낮습니다',
              value: s.googleBooksKey,
              obscure: true,
              onSave: (v) => s.googleBooksKey = v,
            ),
            const _Header('AI 도우미 (선택)'),
            _TextSetting(
              label: 'Claude API 키',
              help: 'console.anthropic.com 에서 발급. 비워두면 AI 기능이 숨겨집니다.',
              value: s.aiKey,
              obscure: true,
              onSave: (v) => s.aiKey = v,
            ),
            _TextSetting(label: 'AI 모델', help: '예) claude-haiku-5-5 (저렴/빠름), claude-sonnet-5-5', value: s.aiModel, onSave: (v) => s.aiModel = v),
            ],
            const _Header('화면'),
            SwitchListTile(title: const Text('다크 모드'), value: s.darkMode, onChanged: (v) => s.darkMode = v),
          ]),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}

class _TextSetting extends StatefulWidget {
  final String label;
  final String? help;
  final String value;
  final bool obscure;
  final ValueChanged<String> onSave;
  const _TextSetting({required this.label, this.help, required this.value, this.obscure = false, required this.onSave});

  @override
  State<_TextSetting> createState() => _TextSettingState();
}

class _TextSettingState extends State<_TextSetting> {
  late final _c = TextEditingController(text: widget.value);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: TextField(
          controller: _c,
          obscureText: widget.obscure,
          onSubmitted: widget.onSave,
          onTapOutside: (_) => widget.onSave(_c.text.trim()),
          decoration: InputDecoration(labelText: widget.label, helperText: widget.help, border: const OutlineInputBorder()),
        ),
      );
}
