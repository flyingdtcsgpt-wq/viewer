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
            constraints: BoxConstraints(maxWidth: setup ? 420 : 720),
            child: Card(
              color: setup ? null : Colors.transparent,
              elevation: setup ? null : 0,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Center(child: Text('MEDIASHELF', style: TextStyle(color: Color(0xFFE50914), fontSize: 34, fontWeight: FontWeight.w900, letterSpacing: 2))),
                  const SizedBox(height: 16),
                  Text(
                    setup ? '처음 사용합니다. 관리자 계정을 만드세요.' : '누가 보고 있나요?',
                    textAlign: TextAlign.center,
                    style: setup ? text.bodyLarge : text.headlineMedium,
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
                    // 넷플릭스풍 프로필 선택
                    Wrap(spacing: 20, runSpacing: 20, alignment: WrapAlignment.center, children: [
                      for (final (i, u) in state.users.indexed)
                        _Profile(
                          user: u,
                          color: _profileColors[i % _profileColors.length],
                          selected: _picked?.id == u.id,
                          onTap: () {
                            setState(() {
                              _picked = u;
                              _error = null;
                              _pw.clear();
                            });
                            if (!u.hasPassword) _login(state); // 비밀번호 없는 사용자는 바로 입장
                          },
                        ),
                    ]),
                    const SizedBox(height: 20),
                    if (_picked?.hasPassword ?? false)
                      TextField(
                        controller: _pw,
                        obscureText: true,
                        autofocus: true,
                        decoration: InputDecoration(labelText: '${_picked!.name} 비밀번호', border: const OutlineInputBorder()),
                        onSubmitted: (_) => _login(state),
                      ),
                  ],
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ),
                  const SizedBox(height: 20),
                  if (setup || (_picked?.hasPassword ?? false) || _busy)
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

const _profileColors = [
  Color(0xFFE50914),
  Color(0xFF1F80E0),
  Color(0xFFF5C518),
  Color(0xFF2EBD59),
  Color(0xFF9B59B6),
  Color(0xFFFF7A00),
];

/// 프로필 한 칸: 큰 색 사각형 + 이름
class _Profile extends StatefulWidget {
  final AppUser user;
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  const _Profile({required this.user, required this.color, required this.selected, required this.onTap});
  @override
  State<_Profile> createState() => _ProfileState();
}

class _ProfileState extends State<_Profile> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final active = _hover || widget.selected;
    final size = MediaQuery.sizeOf(context).width < 600 ? 96.0 : 128.0;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Column(children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: widget.color,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: active ? Colors.white : Colors.transparent, width: 3),
            ),
            alignment: Alignment.center,
            child: Stack(alignment: Alignment.center, children: [
              Text(
                widget.user.name.characters.first.toUpperCase(),
                style: TextStyle(color: Colors.white, fontSize: size * 0.45, fontWeight: FontWeight.w800),
              ),
              if (widget.user.isAdmin)
                const Positioned(right: 6, bottom: 6, child: Icon(Icons.admin_panel_settings, color: Colors.white70, size: 20)),
              if (widget.user.hasPassword)
                const Positioned(left: 6, bottom: 6, child: Icon(Icons.lock, color: Colors.white70, size: 18)),
            ]),
          ),
          const SizedBox(height: 8),
          Text(
            widget.user.name,
            style: TextStyle(color: active ? Theme.of(context).colorScheme.onSurface : Colors.grey, fontSize: 16),
          ),
        ]),
      ),
    );
  }
}
