import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../services/auth.dart';

/// 첫 실행이면 관리자 만들기, 아니면 사용자 선택 + 비밀번호
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _name = TextEditingController();
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();
  AppUser? _picked;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    final last = state.settings.lastUserId;
    _picked = state.users.where((u) => u.id == last).firstOrNull ?? state.users.firstOrNull;
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await f();
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final setup = state.needsSetup;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Icon(Icons.local_library, size: 56),
                  const SizedBox(height: 8),
                  Text('MediaShelf', textAlign: TextAlign.center, style: text.headlineSmall),
                  const SizedBox(height: 4),
                  Text(
                    setup ? '처음 사용합니다. 관리자 계정을 만드세요.' : '사용자를 고르고 로그인하세요.',
                    textAlign: TextAlign.center,
                    style: text.bodyMedium,
                  ),
                  const SizedBox(height: 24),
                  if (setup) ...[
                    TextField(
                      controller: _name,
                      decoration: const InputDecoration(labelText: '관리자 아이디', border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _pw,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '비밀번호', border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _pw2,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '비밀번호 확인', border: OutlineInputBorder()),
                      onSubmitted: (_) => _setup(state),
                    ),
                  ] else ...[
                    Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
                      for (final u in state.users)
                        ChoiceChip(
                          avatar: Icon(u.isAdmin ? Icons.admin_panel_settings : Icons.person, size: 18),
                          label: Text(u.name),
                          selected: _picked?.id == u.id,
                          onSelected: (_) => setState(() {
                            _picked = u;
                            _error = null;
                          }),
                        ),
                    ]),
                    const SizedBox(height: 16),
                    if (_picked?.hasPassword ?? false)
                      TextField(
                        controller: _pw,
                        obscureText: true,
                        autofocus: true,
                        decoration: const InputDecoration(labelText: '비밀번호', border: OutlineInputBorder()),
                        onSubmitted: (_) => _login(state),
                      ),
                  ],
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _busy ? null : () => setup ? _setup(state) : _login(state),
                    child: _busy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(setup ? '관리자 만들고 시작' : '로그인'),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _setup(AppState state) {
    if (_name.text.trim().isEmpty) return setState(() => _error = '아이디를 입력하세요');
    if (_pw.text.length < 4) return setState(() => _error = '관리자 비밀번호는 4자 이상');
    if (_pw.text != _pw2.text) return setState(() => _error = '비밀번호가 서로 다릅니다');
    _run(() => state.createFirstAdmin(_name.text, _pw.text));
  }

  void _login(AppState state) {
    final u = _picked;
    if (u == null) return;
    _run(() async {
      final ok = await state.login(u, _pw.text);
      if (!ok) {
        _pw.clear();
        throw '비밀번호가 틀렸습니다';
      }
    });
  }
}
