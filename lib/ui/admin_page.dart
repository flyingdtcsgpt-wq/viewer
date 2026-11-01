import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models/media_item.dart';
import '../models/series.dart';
import '../services/auth.dart';

/// 관리자: 사용자 관리 · 사용자별 접근 권한 · 숨김 비밀번호
class AdminPage extends StatelessWidget {
  const AdminPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.isAdmin) return const Scaffold(body: Center(child: Text('관리자만 볼 수 있습니다')));
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('관리자')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(padding: const EdgeInsets.all(16), children: [
            Text('사용자', style: text.titleMedium),
            const SizedBox(height: 8),
            for (final u in state.users)
              Card(
                child: ListTile(
                  leading: Icon(u.isAdmin ? Icons.admin_panel_settings : Icons.person),
                  title: Text(u.name + (u.id == state.user?.id ? '  (나)' : '')),
                  subtitle: Text('${u.isAdmin ? '관리자' : '일반 사용자'} · ${u.hasPassword ? '비밀번호 있음' : '비밀번호 없음'}'),
                  trailing: Wrap(children: [
                    if (!u.isAdmin)
                      IconButton(
                        tooltip: '접근 권한',
                        icon: const Icon(Icons.lock_person),
                        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AccessPage(target: u))),
                      ),
                    IconButton(tooltip: '수정', icon: const Icon(Icons.edit), onPressed: () => _editUser(context, u)),
                    if (u.id != state.user?.id)
                      IconButton(tooltip: '삭제', icon: const Icon(Icons.delete_outline), onPressed: () => _deleteUser(context, u)),
                  ]),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: () => _editUser(context, null),
                icon: const Icon(Icons.person_add),
                label: const Text('사용자 추가'),
              ),
            ),
            const Divider(height: 40),
            Text('숨김 목록 비밀번호', style: text.titleMedium),
            const SizedBox(height: 4),
            Text(
              '숨긴 항목은 이 비밀번호를 검색창에 입력하고 Enter 를 눌러야 보입니다. '
              '앱을 닫으면 다시 숨겨집니다. 이 비밀번호를 아는 사용자는 누구나 숨김 목록을 볼 수 있습니다.',
              style: text.bodySmall,
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: Icon(state.hasHiddenPassword ? Icons.lock : Icons.lock_open),
              title: Text(state.hasHiddenPassword ? '설정됨' : '아직 없음 — 숨김 기능을 쓰려면 먼저 정하세요'),
              trailing: FilledButton.tonal(
                onPressed: () => _setHiddenPw(context),
                child: Text(state.hasHiddenPassword ? '변경' : '설정'),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _editUser(BuildContext context, AppUser? u) async {
    final state = context.read<AppState>();
    final name = TextEditingController(text: u?.name);
    final pw = TextEditingController();
    var role = u?.role ?? UserRole.user;
    final isSelf = u?.id == state.user?.id;
    await showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(u == null ? '사용자 추가' : '사용자 수정'),
          content: SizedBox(
            width: 400,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: '아이디')),
              const SizedBox(height: 12),
              TextField(
                controller: pw,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: u == null ? '비밀번호 (비워두면 없이 로그인)' : '새 비밀번호 (비워두면 그대로)',
                ),
              ),
              const SizedBox(height: 12),
              SegmentedButton<UserRole>(
                segments: const [
                  ButtonSegment(value: UserRole.user, label: Text('일반 사용자')),
                  ButtonSegment(value: UserRole.admin, label: Text('관리자')),
                ],
                selected: {role},
                onSelectionChanged: isSelf ? null : (v) => setLocal(() => role = v.first),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
            FilledButton(
              onPressed: () async {
                final n = name.text.trim();
                if (n.isEmpty) return;
                if (state.users.any((x) => x.name == n && x.id != u?.id)) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('이미 있는 아이디입니다')));
                  return;
                }
                if (u == null) {
                  await state.addUser(n, pw.text, role);
                } else {
                  u
                    ..name = n
                    ..role = role;
                  await state.updateUser(u, newPassword: pw.text.isEmpty ? null : pw.text);
                }
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('저장'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteUser(BuildContext context, AppUser u) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('"${u.name}" 삭제'),
        content: const Text('이 사용자의 읽은 위치와 열람 기록도 지워집니다. 라이브러리 파일은 그대로입니다.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('삭제')),
        ],
      ),
    );
    if (ok == true && context.mounted) await context.read<AppState>().deleteUser(u);
  }

  Future<void> _setHiddenPw(BuildContext context) async {
    final a = TextEditingController(), b = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('숨김 목록 비밀번호'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: a, obscureText: true, decoration: const InputDecoration(labelText: '새 비밀번호 (4자 이상)')),
          TextField(controller: b, obscureText: true, decoration: const InputDecoration(labelText: '확인')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
          FilledButton(
            onPressed: () => Navigator.pop(context, a.text.length >= 4 && a.text == b.text),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (!context.mounted) return;
    if (ok == true) {
      context.read<AppState>().setHiddenPassword(a.text);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('숨김 비밀번호를 저장했습니다')));
    } else if (ok == false) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('4자 이상, 두 칸이 같아야 합니다')));
    }
  }
}

/// 사용자 한 명의 접근 권한: 묶음 트리 + 묶음 없는 항목에 켜기/끄기
/// (숨김과는 별개. 막힌 것은 숨김 비밀번호를 알아도 그 사용자에게 보이지 않는다)
class AccessPage extends StatefulWidget {
  final AppUser target;
  const AccessPage({super.key, required this.target});
  @override
  State<AccessPage> createState() => _AccessPageState();
}

class _AccessPageState extends State<AccessPage> {
  Set<String>? _denied;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final d = await context.read<AppState>().deniedOf(widget.target);
    if (mounted) setState(() => _denied = d);
  }

  Future<void> _set(Iterable<String> keys, bool allowed) async {
    await context.read<AppState>().setAccess(widget.target, keys, allowed: allowed);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final denied = _denied;
    final raw = state.rawTree;
    final f = _filter.toLowerCase();

    final rows = <Widget>[];
    void walk(int? parent, int depth, bool parentDenied) {
      final kids = [...?raw.children[parent]]..sort((a, b) => a.title.compareTo(b.title));
      for (final s in kids) {
        final own = denied!.contains('s:${s.id}');
        final blocked = own || parentDenied;
        if (f.isEmpty || state.seriesPath(s.id).toLowerCase().contains(f)) {
          rows.add(_row(
            depth: depth,
            icon: Icons.folder,
            title: s.title,
            subtitle: [if (s.hidden) '숨김', if (parentDenied) '상위 묶음이 막혀 있음'].join(' · '),
            allowed: !blocked,
            enabled: !parentDenied,
            onChanged: (v) => _set(['s:${s.id}'], v),
          ));
        }
        walk(s.id, depth + 1, blocked);
      }
    }

    if (denied != null) {
      walk(null, 0, false);
      final loose = [...?raw.items[null]]..sort((a, b) => a.title.compareTo(b.title));
      final shownLoose = loose.where((e) => f.isEmpty || e.title.toLowerCase().contains(f)).toList();
      if (shownLoose.isNotEmpty) {
        rows.add(const Padding(padding: EdgeInsets.fromLTRB(16, 16, 16, 4), child: Text('묶음 없는 항목')));
        for (final e in shownLoose) {
          rows.add(_row(
            depth: 0,
            icon: _icon(e.kind),
            title: e.title,
            subtitle: e.hidden ? '숨김' : '',
            allowed: !denied.contains('i:${e.id}'),
            enabled: true,
            onChanged: (v) => _set(['i:${e.id}'], v),
          ));
        }
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text('"${widget.target.name}" 접근 권한')),
      body: denied == null
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(children: [
                      Expanded(
                        child: TextField(
                          decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: '찾기'),
                          onChanged: (v) => setState(() => _filter = v),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(onPressed: () => _set(denied.toList(), true), child: const Text('전부 허용')),
                      TextButton(
                        onPressed: () => _set([
                          for (final s in raw.children[null] ?? const <Series>[]) 's:${s.id}',
                          for (final e in raw.items[null] ?? const <MediaItem>[]) 'i:${e.id}',
                        ], false),
                        child: const Text('전부 막기'),
                      ),
                    ]),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text('끄면 이 사용자에게 보이지 않습니다. 묶음을 끄면 그 안의 모든 하위 묶음과 권이 막힙니다.'),
                  ),
                  Expanded(child: ListView(children: rows)),
                ]),
              ),
            ),
    );
  }

  Widget _row({
    required int depth,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool allowed,
    required bool enabled,
    required ValueChanged<bool> onChanged,
  }) =>
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.only(left: 16.0 + depth * 24, right: 16),
        secondary: Icon(icon),
        title: Text(title),
        subtitle: subtitle.isEmpty ? null : Text(subtitle),
        value: allowed,
        onChanged: enabled ? onChanged : null,
      );

  static IconData _icon(MediaKind k) => switch (k) {
        MediaKind.book => Icons.menu_book,
        MediaKind.comic => Icons.auto_stories,
        MediaKind.image => Icons.image,
        MediaKind.video => Icons.movie,
      };
}
