import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../models/media_item.dart';
import '../services/settings.dart';
import '../services/storage_permission.dart';
import '../services/webdav_client.dart';
import 'browser.dart' show fileSize;
import 'import_dialog.dart';

/// NAS · WebDAV 에서 가져오기: 서버에 접속해 폴더를 둘러보고, 고른 파일을 이 기기로 받아 서재에 넣는다
Future<void> openWebDavImport(BuildContext context) =>
    Navigator.push(context, MaterialPageRoute(builder: (_) => const WebDavImportPage()));

class WebDavImportPage extends StatefulWidget {
  const WebDavImportPage({super.key});
  @override
  State<WebDavImportPage> createState() => _WebDavImportPageState();
}

class _WebDavImportPageState extends State<WebDavImportPage> {
  late final Settings _s = context.read<Settings>();
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pw = TextEditingController();
  bool _insecure = false;

  WebDavClient? _client;
  String _path = '/';
  List<DavEntry> _entries = [];
  final Set<String> _picked = {}; // 고른 파일 · 폴더 경로
  bool _busy = false;
  String _status = '';
  bool _stop = false;
  double? _progress;

  @override
  void dispose() {
    for (final c in [_name, _url, _user, _pw]) {
      c.dispose();
    }
    super.dispose();
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  static bool _wanted(DavEntry e) => !e.dir && kindForPath(e.name) != null;

  Future<void> _connect() async {
    var url = _url.text.trim();
    if (url.isEmpty) return _toast('주소를 넣으세요 (예: https://192.168.0.10:5006/books)');
    if (!url.startsWith('http')) url = 'http://$url';
    final c = WebDavClient(url, user: _user.text.trim(), password: _pw.text, insecure: _insecure);
    setState(() => _busy = true);
    try {
      final list = await c.list(c.base.path);
      // 잘 되면 서버 목록에 저장 (비밀번호는 저장하지 않음)
      final servers = _s.davServers.where((m) => m['url'] != url).toList()
        ..insert(0, {'name': _name.text.trim().isEmpty ? Uri.parse(url).host : _name.text.trim(), 'url': url, 'user': _user.text.trim(), 'insecure': '$_insecure'});
      _s.davServers = servers.take(10).toList();
      setState(() {
        _client = c;
        _path = c.base.path;
        _entries = list;
        _picked.clear();
      });
    } catch (e) {
      _toast('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(String path) async {
    final c = _client;
    if (c == null) return;
    setState(() => _busy = true);
    try {
      final list = await c.list(path);
      setState(() {
        _path = path;
        _entries = list;
      });
    } catch (e) {
      _toast('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _parent {
    final t = _path.replaceAll(RegExp(r'/+$'), '');
    final i = t.lastIndexOf('/');
    return i <= 0 ? '/' : '${t.substring(0, i)}/';
  }

  bool get _atTop => _client == null || _path.replaceAll(RegExp(r'/+$'), '') == _client!.base.path.replaceAll(RegExp(r'/+$'), '');

  Future<String> _defaultTarget() async {
    final host = _client?.base.host ?? 'webdav';
    if (_s.libraryRoot != null && _s.libraryRoot!.isNotEmpty) return p.join(_s.libraryRoot!, 'NAS', host);
    if (Platform.isAndroid) {
      if (await hasAllFilesAccess()) return '/storage/emulated/0/Download/ARARIFlex/$host';
      return p.join(((await getExternalStorageDirectory()) ?? await getApplicationDocumentsDirectory()).path, 'NAS', host);
    }
    return p.join((await getApplicationDocumentsDirectory()).path, 'ARARIFlex 받은 파일', host);
  }

  Future<void> _download() async {
    final c = _client;
    if (c == null || _picked.isEmpty) return;
    var target = await _defaultTarget();
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('이 기기로 받기'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('고른 파일을 아래 폴더에 받은 뒤, 서재에 넣는 창(묶기 · 숨김 등)을 엽니다. 서버의 폴더 구조는 그대로 둡니다.'),
            const SizedBox(height: 10),
            SelectableText(target, style: const TextStyle(fontSize: 12)),
            TextButton(
              onPressed: () async {
                final d = await FilePicker.getDirectoryPath(dialogTitle: '받을 폴더');
                if (d != null) set(() => target = d);
              },
              child: const Text('다른 폴더'),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('받기')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _stop = false;
      _progress = null;
      _status = '받을 파일을 찾는 중…';
    });
    final got = <String>[];
    var failed = 0;
    try {
      final files = <DavEntry>[];
      for (final x in _picked) {
        if (x.endsWith('/')) {
          files.addAll(await c.walk(x, _wanted, cancelled: () => _stop));
        } else {
          final e = _entries.where((e) => e.path == x).firstOrNull;
          if (e != null) files.add(e);
        }
      }
      final base = c.base.path.replaceAll(RegExp(r'/+$'), '');
      final total = files.fold<int>(0, (a, e) => a + e.size);
      var doneBytes = 0;
      for (var i = 0; i < files.length && !_stop; i++) {
        final e = files[i];
        // 서버의 폴더 구조를 그대로 (맨 위 주소 아래부터)
        var rel = e.path.startsWith(base) ? e.path.substring(base.length) : e.path;
        rel = rel.split('/').where((x) => x.isNotEmpty).map((x) => x.replaceAll(RegExp(r'[<>:"|?*]'), '_')).join(Platform.pathSeparator);
        final to = p.join(target, rel);
        if (await File(to).exists() && await File(to).length() == e.size && e.size > 0) {
          got.add(to); // 이미 받은 것
          doneBytes += e.size;
          continue;
        }
        try {
          await c.download(e, to, cancelled: () => _stop, onProgress: (g, t) {
            if (!mounted) return;
            setState(() {
              _status = '${i + 1} / ${files.length} · ${e.name} · ${fileSize(g)}${t > 0 ? ' / ${fileSize(t)}' : ''}';
              _progress = total > 0 ? ((doneBytes + g) / total).clamp(0.0, 1.0) : (i + (t > 0 ? g / t : 0)) / files.length;
            });
          });
          got.add(to);
        } catch (err) {
          if (_stop) break;
          failed++;
        }
        doneBytes += e.size;
      }
    } catch (e) {
      _toast('$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progress = null;
          _status = '받음 ${got.length}개${failed > 0 ? ' · 실패 $failed개' : ''}${_stop ? ' · 멈춤' : ''}';
        });
      }
    }
    if (got.isNotEmpty && mounted) await showImportDialog(context, files: got);
  }

  Widget _form() {
    final saved = _s.davServers;
    return ListView(padding: const EdgeInsets.all(16), children: [
      const Text('시놀로지 · 큐냅 · 아이피타임 NAS, 클라우드(WebDAV 지원), 다른 PC 의 ARARIFlex 공유 서버에서 책 · 만화 · 영상을 받아 옵니다.'),
      const SizedBox(height: 4),
      Text('예) 시놀로지: https://NAS주소:5006/폴더 · ARARIFlex: http(s)://PC주소:포트/dav/', style: Theme.of(context).textTheme.bodySmall),
      if (saved.isNotEmpty) ...[
        const SizedBox(height: 12),
        const Text('저장한 서버', style: TextStyle(fontWeight: FontWeight.bold)),
        for (final m in saved)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.dns),
            title: Text(m['name'] ?? m['url'] ?? ''),
            subtitle: Text('${m['url']}${(m['user'] ?? '').isEmpty ? '' : ' · ${m['user']}'}'),
            onTap: () => setState(() {
              _name.text = m['name'] ?? '';
              _url.text = m['url'] ?? '';
              _user.text = m['user'] ?? '';
              _insecure = m['insecure'] == 'true';
              _pw.clear();
            }),
            trailing: IconButton(
              tooltip: '목록에서 지우기',
              icon: const Icon(Icons.close),
              onPressed: () => setState(() => _s.davServers = saved.where((x) => x['url'] != m['url']).toList()),
            ),
          ),
      ],
      const SizedBox(height: 12),
      TextField(controller: _name, decoration: const InputDecoration(labelText: '이름 (선택)', border: OutlineInputBorder(), isDense: true)),
      const SizedBox(height: 10),
      TextField(
        controller: _url,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(labelText: '주소', hintText: 'https://192.168.0.10:5006/books', border: OutlineInputBorder(), isDense: true),
      ),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: TextField(controller: _user, decoration: const InputDecoration(labelText: '아이디', border: OutlineInputBorder(), isDense: true))),
        const SizedBox(width: 10),
        Expanded(
          child: TextField(controller: _pw, obscureText: true, decoration: const InputDecoration(labelText: '비밀번호', border: OutlineInputBorder(), isDense: true)),
        ),
      ]),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('인증서 확인 안 함'),
        subtitle: const Text('NAS · ARARIFlex 가 직접 만든 인증서(HTTPS)를 쓸 때. 집 안 네트워크에서만 켜세요'),
        value: _insecure,
        onChanged: (v) => setState(() => _insecure = v),
      ),
      const SizedBox(height: 8),
      FilledButton.icon(onPressed: _busy ? null : _connect, icon: const Icon(Icons.login), label: Text(_busy ? '연결 중…' : '연결')),
    ]);
  }

  Widget _browser() {
    final files = _entries.where(_wanted).toList();
    return Column(children: [
      ListTile(
        leading: IconButton(
          tooltip: '위 폴더',
          icon: const Icon(Icons.arrow_upward),
          onPressed: _busy || _atTop ? null : () => _open(_parent),
        ),
        title: Text(Uri.decodeFull(_path), maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('${_client!.base.host} · 폴더 ${_entries.where((e) => e.dir).length} · 파일 ${files.length}'),
        trailing: TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                    final all = files.every((e) => _picked.contains(e.path));
                    for (final e in files) {
                      all ? _picked.remove(e.path) : _picked.add(e.path);
                    }
                  }),
          child: const Text('이 폴더 파일 모두'),
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: ListView(children: [
          for (final e in _entries)
            if (e.dir)
              ListTile(
                leading: Checkbox(
                  value: _picked.contains(e.path),
                  onChanged: _busy ? null : (v) => setState(() => v! ? _picked.add(e.path) : _picked.remove(e.path)),
                ),
                title: Text(e.name),
                subtitle: const Text('폴더 · 고르면 안의 파일 전부'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _busy ? null : () => _open(e.path),
              )
            else if (_wanted(e))
              CheckboxListTile(
                value: _picked.contains(e.path),
                onChanged: _busy ? null : (v) => setState(() => v! ? _picked.add(e.path) : _picked.remove(e.path)),
                title: Text(e.name),
                subtitle: Text(fileSize(e.size)),
              ),
        ]),
      ),
      if (_busy && _progress != null) LinearProgressIndicator(value: _progress),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
        child: Row(children: [
          Expanded(child: Text(_status.isEmpty ? '고른 것 ${_picked.length}개' : _status, maxLines: 2)),
          if (_busy && _progress != null) TextButton(onPressed: () => setState(() => _stop = true), child: const Text('멈춤')),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _busy || _picked.isEmpty ? null : _download,
            icon: const Icon(Icons.download),
            label: Text('받아서 서재에 넣기 (${_picked.length})'),
          ),
        ]),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('NAS · WebDAV 에서 가져오기'),
          actions: [
            if (_client != null)
              TextButton(
                onPressed: _busy ? null : () => setState(() => _client = null),
                child: const Text('다른 서버'),
              ),
          ],
        ),
        body: _client == null ? _form() : _browser(),
      );
}
