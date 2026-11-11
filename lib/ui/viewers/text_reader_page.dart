import 'dart:isolate';
import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../models/media_item.dart';
import '../../services/settings.dart';
import '../../services/text_document.dart';
import '../../services/ai_speakers.dart';
import '../../services/ambient.dart';
import '../../services/background_reading.dart';
import '../../services/kokoro_tts.dart';
import '../../services/natural_tts.dart';
import '../../services/speakers.dart';
import '../../services/tts_service.dart';
import '../cover_tile.dart';
import 'audiobook_dialog.dart';
import 'epub_original_page.dart';
import 'open_item.dart';
import 'viewer_chrome.dart';

/// TXT / EPUB 뷰어 — BookManager 스타일
/// 왼쪽: 목차·하이라이트·검색 / 위: 도구줄 / 오른쪽: 뷰어 설정 / 아래: 장(章) 줄
///
/// 긴 소설(수 MB)도 빠르게 열리도록 문단 단위로 지연 렌더링한다.
/// 특정 위치로 이동할 때는 "기준 블록(anchor)"을 바꿔서 그 블록부터 그리는 방식(center sliver).
class TextReaderPage extends StatefulWidget {
  final MediaItem item;
  /// 읽어주기 막대를 연 채로 시작
  final bool readAloud;
  const TextReaderPage({super.key, required this.item, this.readAloud = false});

  @override
  State<TextReaderPage> createState() => _TextReaderPageState();
}

class ReaderTheme {
  final String name;
  final Color bg, fg;
  const ReaderTheme(this.name, this.bg, this.fg);
}

const readerThemes = [
  ReaderTheme('원본', Color(0xFFFAFAFA), Color(0xFF222222)),
  ReaderTheme('다크', Color(0xFF1E1E1E), Color(0xFFDDDDDD)),
  ReaderTheme('블랙', Color(0xFF000000), Color(0xFFB0B0B0)),
  ReaderTheme('종이', Color(0xFFF3EEE3), Color(0xFF333333)),
  ReaderTheme('세피아', Color(0xFFF4ECD8), Color(0xFF5B4636)),
  ReaderTheme('화이트', Color(0xFFFFFFFF), Color(0xFF111111)),
  ReaderTheme('그린', Color(0xFFE3EEDC), Color(0xFF2E3B2C)),
];

/// 하이라이트 색 (마지막은 밑줄)
const hlColors = [Color(0xFFFFD54F), Color(0xFF81C784), Color(0xFF64B5F6), Color(0xFFF48FB1), Color(0xFFB39DDB)];

class _TextReaderPageState extends State<TextReaderPage> {
  final _viewKey = GlobalKey();
  final _ctrl = ScrollController();
  final _alive = <int, BuildContext>{}; // 화면에 붙어 있는 블록들
  final _focus = FocusNode();
  final _searchCtrl = TextEditingController();

  TextDocument? _doc;
  Object? _error;
  int _anchor = 0;
  Key _centerKey = UniqueKey();
  int _current = 0;
  Timer? _saveTimer;

  bool _left = false; // 왼쪽 목차 패널
  int _leftTab = 0; // 0 목차, 1 하이라이트, 2 검색결과
  bool _right = false; // 오른쪽 설정 패널
  bool _chrome = true;
  bool _fullscreen = false;
  bool _selectMode = false; // 글자 선택(하이라이트) 모드
  String _selected = '';
  List<(int, String)> _hits = [];

  // 소리 내어 읽기
  final _tts = TtsService();
  late bool _ttsPanel = widget.readAloud;
  bool _speaking = false;
  int? _ttsBlock;
  List<String> _voices = [];

  late final AppState _app = context.read<AppState>();

  MediaItem get item => widget.item;
  int get _count => _doc?.blocks.length ?? 0;
  double get _progress => _count <= 1 ? 1 : _current / (_count - 1);

  @override
  void initState() {
    super.initState();
    _app; // dispose 에서 context 를 쓰지 않도록 미리 잡아둔다
    _left = WidgetsBinding.instance.platformDispatcher.views.first.physicalSize.width /
            WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio >=
        1200; // 넓은 화면이면 처음부터 목차를 연다
    _load();
  }

  Future<void> _load() async {
    try {
      final doc = await TextDocument.load(item.path);
      if (!mounted) return;
      final saved = int.tryParse(item.position ?? '') ?? 0;
      setState(() {
        _doc = doc;
        _anchor = saved.clamp(0, doc.blocks.isEmpty ? 0 : doc.blocks.length - 1);
        _current = _anchor;
      });
      _prepareCast();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    if (_doc != null && _count > 0) {
      _app.saveProgress(item, '$_current', _progress).then((_) => _app.refresh());
    }
    if (_fullscreen) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _speaking = false;
    _sleepTick?.cancel();
    BackgroundReading.stop();
    Ambient.stop();
    _tts.dispose();
    _ctrl.dispose();
    _focus.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  // ---------------- 위치 ----------------

  void _jumpTo(int block) {
    if (_count == 0) return;
    setState(() {
      _anchor = block.clamp(0, _count - 1);
      _current = _anchor;
      _centerKey = UniqueKey();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_ctrl.hasClients) _ctrl.jumpTo(0);
    });
    _scheduleSave();
  }

  /// 화면 맨 위에 걸친 블록 번호 계산
  void _updateCurrent() {
    final view = _viewKey.currentContext?.findRenderObject() as RenderBox?;
    if (view == null || !view.attached) return;
    final top = view.localToGlobal(Offset.zero).dy + 8;
    int? best;
    double bestY = double.infinity;
    _alive.forEach((index, ctx) {
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) return;
      final y = box.localToGlobal(Offset.zero).dy;
      if (y + box.size.height > top && y < bestY) {
        bestY = y;
        best = index;
      }
    });
    if (best != null && best != _current) {
      setState(() => _current = best!);
      _scheduleSave();
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 1), () => _app.saveProgress(item, '$_current', _progress));
  }

  void _page(int dir) {
    if (!_ctrl.hasClients) return;
    final pos = _ctrl.position;
    final target = (pos.pixels + dir * pos.viewportDimension * 0.9).clamp(pos.minScrollExtent, pos.maxScrollExtent);
    _ctrl.animateTo(target, duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
  }

  int get _tocIndex {
    final toc = _doc?.toc ?? const <TocEntry>[];
    var cur = -1;
    for (var i = 0; i < toc.length; i++) {
      if (toc[i].block <= _current) cur = i;
    }
    return cur;
  }

  void _chapter(int d) {
    final toc = _doc?.toc ?? const <TocEntry>[];
    if (toc.isEmpty) return;
    final t = (_tocIndex + d).clamp(0, toc.length - 1);
    _jumpTo(toc[t].block);
  }

  void _toggleFullscreen() {
    setState(() {
      _fullscreen = !_fullscreen;
      _chrome = !_fullscreen;
    });
    SystemChrome.setEnabledSystemUIMode(_fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
  }

  void _search(String q) {
    final query = q.trim().toLowerCase();
    if (query.isEmpty || _doc == null) return;
    final hits = <(int, String)>[];
    final blocks = _doc!.blocks;
    for (var i = 0; i < blocks.length && hits.length < 500; i++) {
      final t = blocks[i].text;
      if (t == null) continue;
      final at = t.toLowerCase().indexOf(query);
      if (at < 0) continue;
      final from = (at - 30).clamp(0, t.length);
      final to = (at + query.length + 50).clamp(0, t.length);
      hits.add((i, '${from > 0 ? '…' : ''}${t.substring(from, to)}${to < t.length ? '…' : ''}'));
    }
    setState(() {
      _hits = hits;
      _leftTab = 2;
      _left = true;
    });
  }

  // ---------------- 소리 내어 읽기 ----------------

  /// 문단을 (종류, 글) 로 나눈다: 0 일반, 1 대사("…"), 2 속마음('…')
  /// 작은따옴표는 낱말 안의 줄임표(don't, it's)와 헷갈리지 않게 낱말 밖에서 열고 닫힐 때만
  static final _quoteRe = RegExp(r'''([“"「『][^”"」』]+[”"」』])|((?<![A-Za-z0-9])[‘'][^’']+[’'](?![A-Za-z]))''');

  List<(int, String)> _segments(String text, bool split) {
    if (!split) return [(0, text)];
    final out = <(int, String)>[];
    var pos = 0;
    // 영국식 영어 원서는 작은따옴표가 대사
    final single = _singleDialogue ? 1 : 2;
    for (final m in _quoteRe.allMatches(text)) {
      if (m.start > pos) out.add((0, text.substring(pos, m.start)));
      out.add((m.group(1) != null ? 1 : single, m.group(0)!));
      pos = m.end;
    }
    if (pos < text.length) out.add((0, text.substring(pos)));
    return out.where((e) => e.$2.trim().isNotEmpty).toList();
  }

  // 취침 타이머: 정한 시각이 되거나(분) 지금 장이 끝나면 읽기를 멈춘다
  DateTime? _sleepAt;
  int? _sleepAfterBlock; // 이 블록 앞에서 멈춤 (다음 장 시작)
  Timer? _sleepTick;

  void _setSleep(int minutes) {
    _sleepTick?.cancel();
    setState(() {
      _sleepAt = null;
      _sleepAfterBlock = null;
      if (minutes > 0) {
        _sleepAt = DateTime.now().add(Duration(minutes: minutes));
        // 남은 시간 표시를 1분마다 고침
        _sleepTick = Timer.periodic(const Duration(seconds: 30), (_) {
          if (mounted) setState(() {});
        });
      } else if (minutes == -1) {
        final toc = _doc?.toc ?? const <TocEntry>[];
        final at = _ttsBlock ?? _current;
        _sleepAfterBlock = toc.map((t) => t.block).where((b) => b > at).firstOrNull ?? _count;
      }
    });
  }

  String get _sleepLabel {
    if (_sleepAfterBlock != null) return '장 끝';
    final at = _sleepAt;
    if (at == null) return '';
    final left = at.difference(DateTime.now()).inMinutes + 1;
    return '$left분';
  }

  /// 취침 시각이 지났거나 장이 끝났으면 true (그리고 타이머를 끈다)
  bool _sleepDue(int block) {
    final due = (_sleepAt != null && DateTime.now().isAfter(_sleepAt!)) || (_sleepAfterBlock != null && block >= _sleepAfterBlock!);
    if (due) {
      _sleepTick?.cancel();
      _sleepAt = null;
      _sleepAfterBlock = null;
    }
    return due;
  }

  int _ttsRun = 0; // 새로 읽기 시작하거나 멈추면 바뀜 (이전 읽기 루프는 그만둔다)

  /// 한 문단의 읽기 계획: (글, 음성, 속도)
  List<(String, String, int)> _plan(String text, Settings s, {int? block}) {
    final segs = _segments(text, s.ttsSplit);
    final cast = s.ttsSplit ? s.speakerVoices(item.id!) : const <String, String>{};
    final pool = s.ttsSplit && s.ttsAutoCast ? _castPool(s) : const <String>[];
    String voiceOf(int k) {
      switch (segs[k].$1) {
        case 1:
          // 대사: 화자 → 정해 둔 인물 목소리, 없으면 자동 배역 (같은 인물은 책 끝까지 같은 목소리)
          final who = _whoSays(segs, k, s, block);
          final v = who == null ? null : (cast[who] ?? Speakers.autoVoice(who, _ranked ?? const [], pool));
          if (v != null) return v;
          return s.ttsDialogueVoice.isNotEmpty ? s.ttsDialogueVoice : s.ttsVoice;
        case 2:
          return s.ttsThoughtVoice.isNotEmpty ? s.ttsThoughtVoice : s.ttsVoice;
        default:
          return s.ttsVoice;
      }
    }

    return [
      for (var k = 0; k < segs.length; k++) (segs[k].$2, voiceOf(k), s.ttsRate + (segs[k].$1 == 2 ? -2 : 0)), // 속마음은 조금 느리게
    ];
  }

  // ---- 책 분석 (인물 순위 · 영어 책인가 · 작은따옴표가 대사인가) ----
  List<(String, int)>? _found; // 말한 횟수 순 인물 (규칙 + AI)
  List<(String, int)> _ruleFound = const []; // 규칙으로만 찾은 인물
  List<String>? _ranked;
  bool _english = false;
  bool _singleDialogue = false;
  Future<void>? _castJob;
  final Map<int, (String?, bool)> _paraInfo = {}; // 블록 → (화자, 대사만인가)
  Map<int, String> _aiSpk = {}; // AI 가 찾은 화자 (선택, 블록 → 이름)
  double? _bgmDrag; // 배경음 볼륨 막대를 끄는 중인 값

  Future<void> _prepareCast() => _castJob ??= () async {
        final doc = _doc;
        if (doc == null) return;
        final texts = [for (final b in doc.blocks) if (!b.isImage) b.text ?? ''];
        final r = await _analyze(texts);
        final ai = await AiSpeakers.load(item.id!);
        if (!mounted) return;
        setState(() {
          _aiSpk = ai;
          _ruleFound = r.$1;
          _found = _mergeAi(r.$1, ai);
          _ranked = [for (final (n, _) in _found!) n];
          _english = r.$2;
          _singleDialogue = r.$3;
          _paraInfo.clear();
        });
      }();

  /// 책 분석은 따로 도는 일꾼에서. static 이라야 화면 객체(State)가 같이 보내지지 않는다
  static Future<(List<(String, int)>, bool, bool)> _analyze(List<String> texts) => Isolate.run(() {
        var ko = 0, en = 0, dq = 0, sq = 0;
        final open = RegExp(r'''(?<![A-Za-z0-9])['‘](?=[A-Z])''');
        for (final t in texts.take(400)) {
          ko += RegExp(r'[가-힣]').allMatches(t).length;
          en += RegExp(r'[A-Za-z]').allMatches(t).length;
          dq += RegExp(r'["“]').allMatches(t).length;
          sq += open.allMatches(t).length;
        }
        final english = en > 200 && en > ko * 3;
        return (Speakers.scan(texts), english, english && sq > dq * 2 && sq > 10);
      });

  /// 규칙으로 찾은 인물 목록에 AI 가 찾은 인물 · 횟수를 더한다
  static List<(String, int)> _mergeAi(List<(String, int)> found, Map<int, String> ai) {
    final c = {for (final (n, k) in found) n: k};
    for (final n in ai.values) {
      c[n] = (c[n] ?? 0) + 1;
    }
    return c.entries.map((e) => (e.key, e.value)).toList()..sort((a, b) => b.$2.compareTo(a.$2));
  }

  /// 블록 하나의 (화자, 대사만인가). 대사 없는 문단은 화자 ''
  (String?, bool) _infoOf(int i) => _paraInfo[i] ??= () {
        final b = _doc!.blocks[i];
        final t = b.text ?? '';
        if (b.isImage || t.trim().isEmpty) return ('', false);
        final segs = _segments(t, true);
        final who = Speakers.paragraphSpeaker(segs);
        return (who == null ? _aiSpk[i] : who, Speakers.dialogueOnly(segs));
      }();

  /// 대사 [k] 를 누가 말했나: 지문에서, 없으면 (대사만인 문단이면) 앞 문단들과 주고받기로
  String? _whoSays(List<(int, String)> segs, int k, Settings s, int? block) {
    final who = Speakers.speakerAt(segs, k) ?? (block == null ? null : _aiSpk[block]);
    if (who != null || !s.ttsAlternate || block == null || block < 1 || _doc == null || !Speakers.dialogueOnly(segs)) return who;
    return Speakers.alternate([for (var j = block - 1; j >= 0 && j >= block - 10; j--) _infoOf(j)]);
  }

  /// 자동 배역에 쓸 목소리: 영어 책이면 Kokoro, 아니면 자연 음성(남녀 번갈아). 서술 · 대사 · 속마음 목소리는 뺀다
  List<String> _castPool(Settings s) {
    final avoid = {s.ttsVoice, s.ttsDialogueVoice, s.ttsThoughtVoice};
    List<String> pick(bool Function(String) f) => _voices.where(f).where((v) => !avoid.contains(v)).toList();
    var pool = _english ? pick(KokoroTts.isKokoro) : <String>[];
    if (pool.isEmpty) pool = pick(NaturalTts.isNatural);
    if (pool.isEmpty) return const [];
    String gender(String v) {
      final id = v.substring(v.indexOf(':') + 1);
      if (KokoroTts.isKokoro(v)) return id.length > 1 ? id[1] : '?';
      return id.isEmpty ? '?' : id[0].toLowerCase();
    }

    final m = pool.where((v) => gender(v) == 'm').toList(), f = pool.where((v) => gender(v) == 'f').toList();
    final rest = pool.where((v) => gender(v) != 'm' && gender(v) != 'f').toList();
    return [
      for (var i = 0; i < (m.length > f.length ? m.length : f.length); i++) ...[if (i < m.length) m[i], if (i < f.length) f[i]],
      ...rest,
    ];
  }

  Future<void> _ttsPlay({int? from}) async {
    if (_doc == null) return;
    final run = ++_ttsRun;
    final s = context.read<Settings>();
    setState(() {
      _speaking = true;
      _ttsBlock = from ?? _ttsBlock ?? _current;
    });
    bool alive() => mounted && _speaking && run == _ttsRun;
    await _prepareCast();
    if (!alive()) return;
    BackgroundReading.start(item.title); // 화면을 꺼도 계속 (안드로이드)
    Ambient.start(s.ttsBgm, s.ttsBgmVolume); // 배경음 (켜 두었으면)
    while (alive() && _ttsBlock! < _count) {
      final i = _ttsBlock!;
      if (_sleepDue(i)) {
        await _ttsStop();
        return;
      }
      final b = _doc!.blocks[i];
      _showBlock(i);
      if (!b.isImage && (b.text ?? '').trim().isNotEmpty) {
        final plan = _plan(b.text!, s, block: i);
        // 다음 문단 첫 덩어리도 미리 만들어 두면 문단 사이가 덜 끊긴다
        final nextBlock = i + 1 < _count ? _doc!.blocks[i + 1] : null;
        final nextFirst = nextBlock == null || nextBlock.isImage ? null : _plan(nextBlock.text ?? '', s, block: i + 1).firstOrNull;
        for (var k = 0; k < plan.length; k++) {
          final (seg, voice, rate) = plan[k];
          final ahead = k + 1 < plan.length ? plan[k + 1] : nextFirst;
          if (ahead != null) _tts.prefetch(ahead.$1, voice: ahead.$2, rate: ahead.$3);
          final done = await _tts.speak(seg, voice: voice, rate: rate);
          if (!alive()) return;
          if (!done) {
            if (_tts.failed) _ttsFailed();
            return;
          }
          // 서술 ↔ 대사 ↔ 다른 인물로 목소리가 바뀔 때 짧게 숨을 고른다
          if (k + 1 < plan.length && plan[k + 1].$2 != voice) {
            await Future<void>.delayed(const Duration(milliseconds: 220));
            if (!alive()) return;
          }
        }
      }
      if (!alive()) return;
      setState(() => _ttsBlock = i + 1);
    }
    if (mounted && run == _ttsRun) {
      setState(() => _speaking = false);
      BackgroundReading.stop();
      Ambient.stop();
    }
  }

  /// 책에서 말하는 인물을 찾아 인물마다 목소리 정하기
  Future<void> _castDialog(Settings s) async {
    final doc = _doc;
    if (doc == null) return;
    // 큰 책은 몇 초 걸릴 수 있어 화면이 멈추지 않게 따로 센다 (한 번만)
    await _prepareCast();
    if (!mounted) return;
    final found = _found ?? const <(String, int)>[];
    final cast = Map<String, String>.from(s.speakerVoices(item.id!));
    // 예전에 정했지만 이번에 못 찾은 이름도 보여 준다
    final names = [...found.map((e) => e.$1), ...cast.keys.where((k) => !found.any((f) => f.$1 == k))];
    final counts = {for (final (n, c) in found) n: c};
    final add = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('인물별 목소리'),
          content: SizedBox(
            width: 520,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('대사 앞뒤의 "○○가 말했다" · "said Holmes" 같은 문장으로 누가 말했는지 찾습니다. '
                  '목소리를 고르지 않은 인물은 자동으로 서로 다른 목소리를 붙이고, 책 끝까지 같은 목소리로 읽습니다.',
                  style: TextStyle(fontSize: 12)),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('고르지 않은 인물은 자동 배역'),
                value: s.ttsAutoCast,
                onChanged: (v) => setD(() => s.ttsAutoCast = v),
              ),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('화자가 안 적힌 주고받는 대사는 앞의 두 사람이 번갈아'),
                value: s.ttsAlternate,
                onChanged: (v) {
                  setD(() => s.ttsAlternate = v);
                },
              ),
              const SizedBox(height: 8),
              if (names.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('말하는 인물을 찾지 못했습니다. 아래에서 이름을 직접 넣을 수 있습니다.')),
              Flexible(
                child: ListView(shrinkWrap: true, children: [
                  for (final n in names)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.person),
                      title: Text(n),
                      subtitle: counts[n] == null ? null : Text('대사 ${counts[n]}번'),
                      trailing: DropdownButton<String>(
                        value: _voices.contains(cast[n]) ? cast[n] : '',
                        items: [
                          DropdownMenuItem(
                            value: '',
                            child: Text(() {
                              final a = s.ttsAutoCast ? Speakers.autoVoice(n, _ranked ?? const [], _castPool(s)) : null;
                              return a == null ? '대사 목소리' : '자동 · ${TtsService.label(a)}';
                            }()),
                          ),
                          for (final v in _voices) DropdownMenuItem(value: v, child: Text(TtsService.label(v))),
                        ],
                        onChanged: (v) => setD(() => (v == null || v.isEmpty) ? cast.remove(n) : cast[n] = v),
                      ),
                    ),
                ]),
              ),
              Row(children: [
                Expanded(child: TextField(controller: add, decoration: const InputDecoration(hintText: '인물 이름 직접 추가'))),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: () {
                    final n = add.text.trim();
                    if (n.isEmpty || names.contains(n)) return;
                    setD(() {
                      names.add(n);
                      add.clear();
                    });
                  },
                ),
              ]),
            ]),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                s.setSpeakerVoices(item.id!, cast); // 고른 목소리는 먼저 저장
                Navigator.pop(ctx);
                await _aiAnalyze(s);
                if (mounted) _castDialog(s);
              },
              child: Text(_aiSpk.isEmpty ? 'AI 로 화자 분석' : 'AI 분석 이어서 · 다시'),
            ),
            if (s.ttsAutoCast)
              TextButton(
                // 자동으로 붙은 목소리를 그대로 고정 (그 뒤 하나씩 바꾸기 쉽게)
                onPressed: () => setD(() {
                  final pool = _castPool(s);
                  for (final n in names) {
                    final a = Speakers.autoVoice(n, _ranked ?? const [], pool);
                    if (a != null) cast.putIfAbsent(n, () => a);
                  }
                }),
                child: const Text('자동 배역 고정'),
              ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
            FilledButton(
              onPressed: () {
                s.setSpeakerVoices(item.id!, cast);
                Navigator.pop(ctx);
              },
              child: const Text('저장'),
            ),
          ],
        ),
      ),
    );
    add.dispose();
  }

  /// AI(Claude API)로 화자를 못 찾은 대사까지 분석 (선택, 요금이 조금 든다). 결과는 책마다 저장
  Future<void> _aiAnalyze(Settings s) async {
    final doc = _doc;
    if (doc == null) return;
    final ai = _app.ai;
    if (!ai.enabled) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('AI 화자 분석'),
          content: const Text('규칙("○○가 말했다")으로 못 찾은 대사를 AI 가 앞뒤 흐름을 보고 누가 말했는지 찾아 줍니다.\n\n'
              '설정 › AI 도우미에 Claude API 키를 넣으면 쓸 수 있습니다. 책 한 권(30만 자)에 보통 수백 원 안팎이 듭니다. '
              '기기 안 AI 모델로는 정확도와 속도가 부족해(1GB 넘는 모델, 책 한 권에 몇 시간) 넣지 않았습니다.'),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('확인'))],
        ),
      );
      return;
    }
    final paras = [
      for (var i = 0; i < doc.blocks.length; i++)
        if (!doc.blocks[i].isImage && (doc.blocks[i].text ?? '').trim().isNotEmpty) (i, doc.blocks[i].text!.trim()),
    ];
    bool hasDialogue(String t) => _segments(t, true).any((e) => e.$1 == 1);
    final tokens = AiSpeakers.estimateTokens(paras, hasDialogue);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('AI 로 화자 분석'),
        content: Text('대사가 있는 부분을 Claude API(${s.aiModel})에 보내 누가 말했는지 묻습니다.\n'
            '보내는 양: 약 ${(tokens / 1000).round()}천 토큰${_aiSpk.isEmpty ? '' : ' (이미 분석한 곳은 건너뜀)'}.\n'
            '책 글이 Anthropic 서버로 전송됩니다. 결과는 이 기기에만 저장됩니다.'),
        actions: [
          if (_aiSpk.isNotEmpty)
            TextButton(
              onPressed: () async {
                await AiSpeakers.clear(item.id!);
                if (ctx.mounted) Navigator.pop(ctx, true);
              },
              child: const Text('처음부터 다시'),
            ),
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('분석')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    var stop = false;
    final prog = ValueNotifier<(int, int)>((0, 0));
    Object? err;
    BuildContext? dctx;
    final job = AiSpeakers.analyze(
      bookId: item.id!,
      ai: ai,
      paras: paras,
      hasDialogue: hasDialogue,
      known: _ranked ?? const [],
      onProgress: (d, n) => prog.value = (d, n),
      cancelled: () => stop,
    ).then<void>((r) => _aiSpk = r, onError: (Object e) => err = e);
    // 진행 창은 꼭 한 번만 닫는다 (창이 다시 그려져도 두 번 닫아 뷰어까지 닫히지 않게)
    var closed = false, popped = false;
    void close() {
      final c = dctx;
      if (popped || c == null || !c.mounted) return;
      popped = true;
      Navigator.of(c).pop();
    }

    job.whenComplete(() {
      closed = true;
      close();
    });
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        dctx = ctx;
        if (closed) WidgetsBinding.instance.addPostFrameCallback((_) => close());
        return AlertDialog(
          title: const Text('AI 화자 분석 중'),
          content: ValueListenableBuilder<(int, int)>(
            valueListenable: prog,
            builder: (_, v, _) => Column(mainAxisSize: MainAxisSize.min, children: [
              LinearProgressIndicator(value: v.$2 == 0 ? null : v.$1 / v.$2),
              const SizedBox(height: 8),
              Text(v.$2 == 0 ? '보내는 중…' : '${v.$1} / ${v.$2} 묶음'),
            ]),
          ),
          actions: [TextButton(onPressed: () => stop = true, child: const Text('멈춤'))],
        );
      },
    );
    await job;
    prog.dispose();
    if (!mounted) return;
    setState(() {
      _paraInfo.clear();
      _found = _mergeAi(_ruleFound, _aiSpk);
      _ranked = [for (final (n, _) in _found!) n];
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(err != null ? 'AI 분석 실패: $err' : 'AI 가 대사 ${_aiSpk.length}곳의 화자를 찾았습니다${stop ? ' (멈춤 — 다시 누르면 이어서)' : ''}'),
    ));
  }

  void _ttsFailed() {
    BackgroundReading.stop();
    Ambient.stop();
    setState(() => _speaking = false);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('음성을 만들지 못했습니다. 설정 › 읽어주기 음성에서 음성 파일을 확인하거나 다른 음성을 고르세요.')));
  }

  Future<void> _ttsStop({bool reset = false}) async {
    _ttsRun++;
    BackgroundReading.stop();
    Ambient.stop();
    setState(() {
      _speaking = false;
      if (reset) _ttsBlock = null;
    });
    await _tts.stop();
  }

  void _ttsSkip(int d) {
    final next = ((_ttsBlock ?? _current) + d).clamp(0, _count - 1);
    final wasSpeaking = _speaking;
    _ttsRun++; // 지금 읽기 루프는 그만두게
    _tts.stop();
    setState(() => _ttsBlock = next);
    if (wasSpeaking) {
      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted) _ttsPlay(from: next);
      });
    } else {
      _showBlock(next);
    }
  }

  /// 읽는 문단이 화면에 보이게
  void _showBlock(int i) {
    final ctx = _alive[i];
    if (ctx != null && ctx.mounted) {
      Scrollable.ensureVisible(ctx, alignment: 0.25, duration: const Duration(milliseconds: 250));
    } else {
      _jumpTo(i);
    }
    _current = i;
    _scheduleSave();
  }

  Widget _ttsBar(Settings s) {
    if (!TtsService.supported) {
      return const Padding(padding: EdgeInsets.all(12), child: Text('이 기기에서는 아직 읽어주기를 쓸 수 없습니다', style: TextStyle(color: Colors.white)));
    }
    if (_voices.isEmpty) {
      TtsService.voices().then((v) {
        if (mounted && v.isNotEmpty) setState(() => _voices = v);
      });
    }
    DropdownButton<String> voicePick(String value, ValueChanged<String> onChanged, String hint) => DropdownButton<String>(
          dropdownColor: toolBg,
          value: _voices.contains(value) ? value : null,
          hint: Text(hint, style: const TextStyle(color: Colors.white70)),
          style: const TextStyle(color: Colors.white),
          items: [for (final v in _voices) DropdownMenuItem(value: v, child: Text(TtsService.label(v)))],
          onChanged: (v) => onChanged(v ?? ''),
        );
    const speeds = [-4, -2, 0, 2, 4, 6];
    return Material(
      color: const Color(0xF0222222),
      elevation: 8,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, runSpacing: 4, children: [
            ToolGroup([
              ToolBtn(icon: Icons.skip_previous, tooltip: '이전 문단', onTap: () => _ttsSkip(-1)),
              ToolBtn(
                icon: _speaking ? Icons.pause : Icons.play_arrow,
                tooltip: _speaking ? '멈춤' : '읽기 시작',
                active: _speaking,
                onTap: () => _speaking ? _ttsStop() : _ttsPlay(),
              ),
              ToolBtn(icon: Icons.stop, tooltip: '정지', onTap: () => _ttsStop(reset: true)),
              ToolBtn(icon: Icons.skip_next, tooltip: '다음 문단', onTap: () => _ttsSkip(1)),
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
            PopupMenuButton<int>(
              tooltip: '취침 타이머',
              color: toolBg,
              onSelected: _setSleep,
              itemBuilder: (_) => [
                for (final (m, t) in const [(0, '끄기'), (15, '15분 뒤'), (30, '30분 뒤'), (45, '45분 뒤'), (60, '1시간 뒤'), (90, '1시간 30분 뒤'), (-1, '이 장이 끝나면')])
                  PopupMenuItem(value: m, child: Text(t, style: const TextStyle(color: Colors.white))),
              ],
              child: ToolGroup([
                ToolBtn(
                  icon: Icons.bedtime,
                  label: _sleepLabel.isEmpty ? null : _sleepLabel,
                  tooltip: '취침 타이머',
                  active: _sleepLabel.isNotEmpty,
                ),
              ]),
            ),
            PopupMenuButton<String>(
              tooltip: '배경음',
              color: toolBg,
              onSelected: (v) async {
                if (v == '#file') {
                  final r = await FilePicker.pickFiles(type: FileType.audio, dialogTitle: '배경음으로 쓸 소리 파일');
                  final path = r.firstOrNull?.path;
                  if (path == null) return;
                  v = path;
                }
                s.ttsBgm = v;
                if (_speaking) v.isEmpty ? Ambient.stop() : Ambient.start(v, s.ttsBgmVolume);
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: '', child: Text('배경음 끄기', style: TextStyle(color: Colors.white))),
                for (final (k, l) in Ambient.kinds)
                  PopupMenuItem(value: k, child: Text('${s.ttsBgm == k ? '✓ ' : ''}$l', style: const TextStyle(color: Colors.white))),
                const PopupMenuItem(value: '#file', child: Text('내 소리 파일 고르기…', style: TextStyle(color: Colors.white))),
              ],
              child: ToolGroup([ToolBtn(icon: Icons.music_note, tooltip: '배경음 · ${Ambient.label(s.ttsBgm)}', active: s.ttsBgm.isNotEmpty)]),
            ),
            const SizedBox(width: 6),
            voicePick(s.ttsVoice, (v) => s.ttsVoice = v, '기본 음성'),
            IconButton(onPressed: () => setState(() => _ttsPanel = false), icon: const Icon(Icons.close, color: Colors.white54)),
          ]),
          if (s.ttsBgm.isNotEmpty)
            Row(children: [
              const Icon(Icons.music_note, color: Colors.white54, size: 16),
              const SizedBox(width: 4),
              Flexible(child: Text('배경음 · ${Ambient.label(s.ttsBgm)}', style: const TextStyle(color: Colors.white70, fontSize: 12), overflow: TextOverflow.ellipsis)),
              SizedBox(
                width: 160,
                child: Slider(
                  value: _bgmDrag ?? s.ttsBgmVolume.toDouble(),
                  max: 100,
                  // 끄는 동안은 소리만 바꾸고, 놓을 때 한 번 저장
                  onChanged: (v) {
                    setState(() => _bgmDrag = v);
                    Ambient.setVolume(v.round());
                  },
                  onChangeEnd: (v) {
                    s.ttsBgmVolume = v.round();
                    setState(() => _bgmDrag = null);
                  },
                ),
              ),
            ]),
          Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, runSpacing: 4, children: [
            Checkbox(value: s.ttsSplit, onChanged: (v) => s.ttsSplit = v ?? false),
            const Text('큰따옴표=대사, 작은따옴표=속마음 다른 음성으로', style: TextStyle(color: Colors.white70, fontSize: 12)),
          ]),
          if (s.ttsSplit)
            Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, runSpacing: 4, children: [
              const Text('대사  ', style: TextStyle(color: Colors.white70)),
              voicePick(s.ttsDialogueVoice, (v) => s.ttsDialogueVoice = v, '기본과 같음'),
              const SizedBox(width: 12),
              const Text('속마음  ', style: TextStyle(color: Colors.white70)),
              voicePick(s.ttsThoughtVoice, (v) => s.ttsThoughtVoice = v, '기본과 같음'),
              const SizedBox(width: 12),
              TextButton.icon(
                onPressed: () => _castDialog(s),
                icon: const Icon(Icons.groups, size: 18),
                label: Text('인물별 목소리${s.speakerVoices(item.id!).isEmpty ? '' : ' (${s.speakerVoices(item.id!).length})'}'),
              ),
            ]),
          TextButton.icon(
            onPressed: _doc == null
                ? null
                : () async {
                    if (_speaking) await _ttsStop();
                    await _prepareCast();
                    if (!mounted || _doc == null) return;
                    await showAudiobookExport(context,
                        title: item.title, doc: _doc!, currentBlock: _ttsBlock ?? _current, rate: s.ttsRate, plan: (t, block) => _plan(t, s, block: block < 0 ? null : block));
                  },
            icon: const Icon(Icons.library_music, size: 18),
            label: const Text('오디오북으로 저장 (장마다 소리 파일)'),
          ),
          if (_english && !KokoroTts.isKokoro(s.ttsVoice))
            if (_voices.any(KokoroTts.isKokoro))
              TextButton.icon(
                onPressed: () => s.ttsVoice = _voices.contains('${KokoroTts.prefix}af_heart')
                    ? '${KokoroTts.prefix}af_heart'
                    : _voices.firstWhere(KokoroTts.isKokoro),
                icon: const Icon(Icons.translate, size: 18),
                label: const Text('영어 책입니다 — Kokoro 영어 성우로 읽기'),
              )
            else if (KokoroTts.platformOk)
              const Text('영어 책입니다. 설정 › 읽어주기 · 글자 인식에서 Kokoro 영어 성우(28가지)를 받으면 더 자연스럽습니다',
                  style: TextStyle(color: Colors.white54, fontSize: 11)),
          if (_voices.isEmpty)
            const Text('음성 목록을 읽는 중… (Windows 설정 → 시간 및 언어 → 음성 에서 한국어 음성을 추가할 수 있습니다)',
                style: TextStyle(color: Colors.white38, fontSize: 11))
          else if (!_voices.any(NaturalTts.isNatural))
            const Text('사람 같은 자연스러운 음성(무료 · 오프라인)은 설정 › 읽어주기 음성에서 받을 수 있습니다',
                style: TextStyle(color: Colors.white54, fontSize: 11)),
        ]),
      ),
    );
  }

  String? get _fontFamily => switch (context.read<Settings>().readerFont) {
        1 => Platform.isWindows ? 'Batang' : 'serif',
        2 => Platform.isWindows ? 'Malgun Gothic' : 'sans-serif',
        _ => null,
      };

  // ---------------- 화면 ----------------

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Settings>();
    final theme = readerThemes[s.readerTheme.clamp(0, readerThemes.length - 1)];
    final wide = MediaQuery.sizeOf(context).width >= 900;

    Widget body;
    if (_error != null) {
      body = Center(child: Text('열 수 없습니다: $_error', style: TextStyle(color: theme.fg)));
    } else if (_doc == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_count == 0) {
      body = Center(child: Text('내용이 없습니다', style: TextStyle(color: theme.fg)));
    } else {
      body = _buildText(s, theme);
    }

    final page = Container(
      color: theme.bg,
      child: Column(children: [
        Expanded(
          child: Stack(children: [
            Positioned.fill(child: body),
            if (_ttsPanel) Positioned(top: 8, left: 8, right: 8, child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720), child: _ttsBar(s)))),
          ]),
        ),
        if (_chrome && s.viewerSlider && (_doc?.toc.isNotEmpty ?? false)) _chapterStrip(),
      ]),
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.pageDown): () => _page(1),
        const SingleActivator(LogicalKeyboardKey.space): () => _page(1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _page(s.comicRtl ? -1 : 1),
        const SingleActivator(LogicalKeyboardKey.pageUp): () => _page(-1),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _page(s.comicRtl ? 1 : -1),
        const SingleActivator(LogicalKeyboardKey.space, shift: true): () => _page(-1),
        const SingleActivator(LogicalKeyboardKey.home): () => _jumpTo(0),
        const SingleActivator(LogicalKeyboardKey.end): () => _jumpTo(_count - 1),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () => setState(() {
              _left = true;
              _leftTab = 2;
            }),
        const SingleActivator(LogicalKeyboardKey.keyF): _toggleFullscreen,
        const SingleActivator(LogicalKeyboardKey.keyB): () => s.toggleBookmark(item.id!, _current),
        const SingleActivator(LogicalKeyboardKey.equal, control: true): () => s.readerFontSize = (s.readerFontSize + 1).clamp(12, 40),
        const SingleActivator(LogicalKeyboardKey.minus, control: true): () => s.readerFontSize = (s.readerFontSize - 1).clamp(12, 40),
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_right || (_left && !wide)) {
            setState(() => _right = _left = false);
          } else if (_fullscreen) {
            _toggleFullscreen();
          } else {
            Navigator.maybePop(context);
          }
        },
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: Scaffold(
          backgroundColor: viewerBg,
          body: SafeArea(
            child: Column(children: [
              if (_chrome) _topBar(s, wide),
              Expanded(
                child: wide
                    ? Row(children: [
                        if (_left) _leftPanel(s, theme),
                        Expanded(child: page),
                        if (_right) _settingsPanel(s),
                      ])
                    : Stack(children: [
                        Positioned.fill(child: page),
                        // 좁은 화면: 패널을 위에 겹쳐서
                        if (_left) Positioned(left: 0, top: 0, bottom: 0, child: Material(elevation: 8, child: _leftPanel(s, theme))),
                        if (_right) Positioned(right: 0, top: 0, bottom: 0, child: Material(elevation: 8, child: _settingsPanel(s))),
                      ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  // ---------- 위 도구줄 ----------
  Widget _topBar(Settings s, bool wide) {
    final marked = s.bookmarks(item.id!).contains(_current);
    final toc = _doc?.toc ?? const <TocEntry>[];
    return Container(
      color: const Color(0xFF141414),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          // 다른 뷰어와 같은 자리: 왼쪽 끝 = 닫기
          IconButton(
            style: IconButton.styleFrom(backgroundColor: toolActive),
            tooltip: '닫기 (Esc)',
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: () => Navigator.maybePop(context),
          ),
          const SizedBox(width: 6),
          IconButton(
            style: IconButton.styleFrom(backgroundColor: _left ? toolActive.withValues(alpha: 0.6) : toolBg),
            tooltip: '목차 · 하이라이트 · 검색',
            icon: const Icon(Icons.toc, color: Colors.white),
            onPressed: () => setState(() => _left = !_left),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(item.fileName,
                overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
          ),
          const SizedBox(width: 8),
          Text(
            toc.isEmpty ? '${(_progress * 100).toStringAsFixed(1)}%' : '${_tocIndex + 1} / ${toc.length} · ${(_progress * 100).round()}%',
            style: const TextStyle(color: Colors.white60, fontSize: 12),
          ),
          NextVolumeButton(item: item),
          // 휴대폰: 도구줄이 화면 밖으로 넘쳐도 읽어주기는 바로 누를 수 있게
          if (!wide) ...[
            IconButton(
              tooltip: '소리 내어 읽기',
              icon: Icon(Icons.record_voice_over, color: _ttsPanel || _speaking ? toolActive : Colors.white),
              onPressed: () => setState(() => _ttsPanel = !_ttsPanel),
            ),
          ],
        ]),
        const SizedBox(height: 4),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          reverse: wide,
          child: Row(children: [
            ToolGroup([
              ToolBtn(icon: Icons.keyboard_double_arrow_left, tooltip: '이전 장', onTap: toc.isEmpty ? null : () => _chapter(-1), enabled: toc.isNotEmpty),
              ToolBtn(icon: Icons.keyboard_double_arrow_right, tooltip: '다음 장', onTap: toc.isEmpty ? null : () => _chapter(1), enabled: toc.isNotEmpty),
            ]),
            ToolGroup([
              ToolBtn(icon: Icons.chevron_left, tooltip: '이전 화면 (PgUp)', onTap: () => _page(-1)),
              ToolBtn(icon: Icons.chevron_right, tooltip: '다음 화면 (PgDn)', onTap: () => _page(1)),
            ]),
            ToolGroup([
              ToolBtn(icon: Icons.text_decrease, tooltip: '글자 작게 (Ctrl -)', onTap: () => s.readerFontSize = (s.readerFontSize - 1).clamp(12, 40)),
              ToolBtn(label: '${(s.readerFontSize / 18 * 100).round()}%', tooltip: '글자 크기'),
              ToolBtn(icon: Icons.text_increase, tooltip: '글자 크게 (Ctrl +)', onTap: () => s.readerFontSize = (s.readerFontSize + 1).clamp(12, 40)),
            ]),
            ToolGroup([
              ToolBtn(
                icon: Icons.border_color,
                label: '선택',
                tooltip: '글자 선택 → 하이라이트 · 복사 · 검색',
                active: _selectMode,
                onTap: () => setState(() => _selectMode = !_selectMode),
              ),
            ]),
            ToolGroup([
              ToolBtn(label: 'TTS', tooltip: '소리 내어 읽기', active: _ttsPanel || _speaking, onTap: () => setState(() => _ttsPanel = !_ttsPanel)),
            ]),
            ToolGroup([
              ToolBtn(icon: Icons.manage_search, tooltip: '책에서 찾기 (Ctrl+F)', onTap: () => setState(() {
                    _left = true;
                    _leftTab = 2;
                  })),
            ]),
            ToolGroup([
              ToolBtn(
                icon: marked ? Icons.bookmark : Icons.bookmark_border,
                tooltip: '책갈피 (B)',
                active: marked,
                onTap: () => s.toggleBookmark(item.id!, _current),
              ),
            ]),
            ToolGroup([ToolBtn(icon: _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen, tooltip: '전체화면 (F)', onTap: _toggleFullscreen)]),
            ToolGroup([
              ToolBtn(
                icon: Icons.help_outline,
                tooltip: '단축키',
                onTap: () => showViewerHelp(context, const [
                  ('← → / PgUp PgDn', '한 화면씩 넘기기'),
                  ('Space / Shift+Space', '다음 / 이전 화면'),
                  ('Home / End', '처음 / 끝'),
                  ('Ctrl + / Ctrl -', '글자 크게 / 작게'),
                  ('Ctrl+F', '책에서 찾기'),
                  ('F', '전체화면'),
                  ('B', '책갈피'),
                  ('Esc', '패널 닫기 · 나가기'),
                ]),
              ),
            ]),
            ToolGroup([ToolBtn(icon: Icons.settings, tooltip: '뷰어 설정', active: _right, onTap: () => setState(() => _right = !_right))]),
          ]),
        ),
      ]),
    );
  }

  // ---------- 본문 ----------
  Widget _buildText(Settings s, ReaderTheme theme) {
    final blocks = _doc!.blocks;
    final base = TextStyle(fontSize: s.readerFontSize, height: s.readerLineHeight, color: theme.fg, fontFamily: _fontFamily);
    final screenH = MediaQuery.sizeOf(context).height;
    final hls = s.highlights(item.id!);

    Widget itemAt(int i) => _BlockItem(
          key: ValueKey(i),
          index: i,
          registry: _alive,
          child: i == _ttsBlock && (_speaking || _ttsPanel)
              ? DecoratedBox(
                  // 지금 읽는 문단
                  decoration: BoxDecoration(color: toolActive.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(4)),
                  child: _renderBlock(blocks[i], base, s, theme, screenH, hls),
                )
              : _renderBlock(blocks[i], base, s, theme, screenH, hls),
        );

    return LayoutBuilder(builder: (context, c) {
      final hPad = ((c.maxWidth - s.readerMaxWidth) / 2).clamp(20.0, double.infinity);
      Widget list = NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n is ScrollEndNotification) _updateCurrent();
          return false;
        },
        child: CustomScrollView(
          key: _viewKey,
          controller: _ctrl,
          center: _centerKey,
          slivers: [
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: hPad),
              sliver: SliverList(delegate: SliverChildBuilderDelegate((_, i) => itemAt(_anchor - 1 - i), childCount: _anchor)),
            ),
            SliverPadding(
              key: _centerKey,
              padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 24),
              sliver: SliverList(delegate: SliverChildBuilderDelegate((_, i) => itemAt(_anchor + i), childCount: blocks.length - _anchor)),
            ),
            // 글 끝: 다음 권으로 자연스럽게 (없으면 "다음 권이 없습니다")
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 40, 16, screenH * 0.4),
                child: Center(child: VolumeEndCard(item: item)),
              ),
            ),
          ],
        ),
      );

      // 선택 모드: 글자를 끌어서 고르면 하이라이트 메뉴
      if (_selectMode) {
        return SelectionArea(
          onSelectionChanged: (c) => _selected = c?.plainText ?? '',
          contextMenuBuilder: (ctx, state) => AdaptiveTextSelectionToolbar(
            anchors: state.contextMenuAnchors,
            children: [_SelectionMenu(onPick: (action, color) => _onSelectionAction(action, color, state))],
          ),
          child: list,
        );
      }

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) {
          final x = d.localPosition.dx / c.maxWidth;
          final next = s.comicRtl ? -1 : 1;
          if (s.tapToTurn && x < 0.25) {
            _page(-next);
          } else if (s.tapToTurn && x > 0.75) {
            _page(next);
          } else {
            setState(() => _chrome = !_chrome);
          }
        },
        onHorizontalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if (v.abs() < 250) return;
          _page((v < 0) != s.comicRtl ? 1 : -1);
        },
        child: list,
      );
    });
  }

  void _onSelectionAction(String action, int color, SelectableRegionState state) {
    final text = _selected.trim();
    state.hideToolbar();
    if (text.isEmpty) return;
    final s = context.read<Settings>();
    switch (action) {
      case 'hl':
        for (final line in text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty)) {
          s.addHighlight(item.id!, color, line);
        }
      case 'copy':
        Clipboard.setData(ClipboardData(text: text));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('복사했습니다')));
      case 'search':
        _searchCtrl.text = text;
        _search(text);
      case 'ai':
        _askAi(text);
    }
    state.clearSelection();
  }

  Future<void> _askAi(String text) async {
    if (!_app.ai.enabled) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('설정에서 Claude API 키를 넣으면 뜻풀이·번역을 쓸 수 있습니다')));
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('AI 뜻풀이 / 번역'),
        content: SizedBox(
          width: 480,
          child: FutureBuilder<String>(
            future: _app.ai.chat('다음 문장의 뜻을 쉽게 풀이하고, 외국어면 한국어로 번역해줘:\n"$text"', const []),
            builder: (_, snap) => snap.hasData
                ? SingleChildScrollView(child: SelectableText(snap.data!))
                : snap.hasError
                    ? Text('실패: ${snap.error}')
                    : const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('닫기'))],
      ),
    );
  }

  Widget _renderBlock(TextBlock b, TextStyle base, Settings s, ReaderTheme theme, double screenH, List<(int, String)> hls) {
    final gap = s.readerFontSize * s.readerParagraphGap;
    if (b.isImage) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: gap),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: screenH * 0.85),
          child: Image.memory(b.image!, fit: BoxFit.contain, errorBuilder: (_, _, _) => const SizedBox()),
        ),
      );
    }
    final text = b.text ?? '';
    if (text.trim().isEmpty) return SizedBox(height: gap + s.readerFontSize * 0.6);
    if (b.heading > 0) {
      const scale = [1.0, 1.6, 1.45, 1.3, 1.15, 1.1, 1.05];
      return Padding(
        padding: EdgeInsets.only(top: gap * 2, bottom: gap * 1.5),
        child: Text(text, style: base.copyWith(fontSize: s.readerFontSize * scale[b.heading], fontWeight: FontWeight.bold, height: 1.4)),
      );
    }
    final rich = Text.rich(_highlighted(text, base, hls));
    final t = Padding(padding: EdgeInsets.only(bottom: gap), child: rich);
    if (!b.quote) return t;
    return Container(
      margin: EdgeInsets.only(bottom: gap),
      padding: const EdgeInsets.only(left: 12),
      decoration: BoxDecoration(border: Border(left: BorderSide(color: theme.fg.withValues(alpha: 0.4), width: 3))),
      child: Text.rich(_highlighted(text, base.copyWith(fontStyle: FontStyle.italic), hls)),
    );
  }

  /// 저장된 하이라이트 문장이 이 문단에 있으면 색칠
  TextSpan _highlighted(String text, TextStyle base, List<(int, String)> hls) {
    final ranges = <(int, int, int)>[]; // start, end, color
    for (final (color, h) in hls) {
      if (h.length < 2) continue;
      var from = 0;
      while (true) {
        final at = text.indexOf(h, from);
        if (at < 0) break;
        ranges.add((at, at + h.length, color));
        from = at + h.length;
      }
    }
    if (ranges.isEmpty) return TextSpan(text: text, style: base);
    ranges.sort((a, b) => a.$1.compareTo(b.$1));
    final spans = <TextSpan>[];
    var pos = 0;
    for (final (st, en, color) in ranges) {
      if (st < pos) continue;
      if (st > pos) spans.add(TextSpan(text: text.substring(pos, st)));
      spans.add(TextSpan(
        text: text.substring(st, en),
        style: color >= hlColors.length
            ? const TextStyle(decoration: TextDecoration.underline, decorationThickness: 2)
            : TextStyle(backgroundColor: hlColors[color].withValues(alpha: 0.45)),
      ));
      pos = en;
    }
    if (pos < text.length) spans.add(TextSpan(text: text.substring(pos)));
    return TextSpan(style: base, children: spans);
  }

  // ---------- 아래 장(章) 줄 ----------
  Widget _chapterStrip() {
    final toc = _doc!.toc;
    final cur = _tocIndex;
    return Container(
      height: 86,
      color: const Color(0xFF141414),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        itemCount: toc.length,
        itemBuilder: (_, i) {
          final on = i == cur;
          return GestureDetector(
            onTap: () => _jumpTo(toc[i].block),
            child: Container(
              width: 120,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: on ? toolActive.withValues(alpha: 0.25) : toolBg,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: on ? toolActive : Colors.white12, width: on ? 2 : 1),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${i + 1}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Expanded(
                  child: Text(toc[i].title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 11)),
                ),
              ]),
            ),
          );
        },
      ),
    );
  }

  // ---------- 왼쪽 패널 ----------
  Widget _leftPanel(Settings s, ReaderTheme theme) {
    final toc = _doc?.toc ?? const <TocEntry>[];
    final hls = s.highlights(item.id!);
    final marks = s.bookmarks(item.id!);
    final cur = _tocIndex;
    final blocks = _doc?.blocks ?? const <TextBlock>[];

    Widget tab(int i, String label) => Expanded(
          child: Material(
            color: _leftTab == i ? toolActive : toolBg,
            child: InkWell(
              onTap: () => setState(() => _leftTab = i),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(label, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        );

    Widget list;
    switch (_leftTab) {
      case 0:
        list = toc.isEmpty
            ? const Center(child: Text('목차를 찾지 못했습니다', style: TextStyle(color: Colors.white54)))
            : ListView.builder(
                itemCount: toc.length,
                itemBuilder: (_, i) => Material(
                  color: i == cur ? toolActive.withValues(alpha: 0.3) : Colors.transparent,
                  child: ListTile(
                    dense: true,
                    title: Text(toc[i].title, style: const TextStyle(color: Colors.white)),
                    trailing: Text('${(toc[i].block / blocks.length.clamp(1, 1 << 30) * 100).round()}%',
                        style: const TextStyle(color: Colors.white38, fontSize: 11)),
                    onTap: () => _jumpTo(toc[i].block),
                  ),
                ),
              );
      case 1:
        list = ListView(children: [
          if (marks.isNotEmpty) ...[
            const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('책갈피', style: TextStyle(color: Colors.white54))),
            for (final m in marks)
              ListTile(
                dense: true,
                leading: const Icon(Icons.bookmark, color: Colors.redAccent, size: 18),
                title: Text(
                  m < blocks.length ? (blocks[m].text ?? '(그림)') : '$m',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () => _jumpTo(m),
                trailing: IconButton(
                  icon: const Icon(Icons.close, size: 16, color: Colors.white38),
                  onPressed: () => s.toggleBookmark(item.id!, m),
                ),
              ),
          ],
          const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('하이라이트', style: TextStyle(color: Colors.white54))),
          if (hls.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('도구줄의 "선택"을 켜고 글자를 끌어 고르면 색을 칠할 수 있습니다.', style: TextStyle(color: Colors.white38)),
            ),
          for (final (color, text) in hls)
            ListTile(
              dense: true,
              leading: Icon(color >= hlColors.length ? Icons.format_underline : Icons.circle,
                  size: 14, color: color >= hlColors.length ? Colors.white : hlColors[color]),
              title: Text(text, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white)),
              onTap: () {
                final at = blocks.indexWhere((b) => (b.text ?? '').contains(text));
                if (at >= 0) _jumpTo(at);
              },
              trailing: IconButton(
                icon: const Icon(Icons.close, size: 16, color: Colors.white38),
                onPressed: () => s.removeHighlight(item.id!, text),
              ),
            ),
        ]);
      default:
        list = _hits.isEmpty
            ? const Center(child: Text('위 칸에 찾을 말을 넣고 Enter', style: TextStyle(color: Colors.white54)))
            : ListView.builder(
                itemCount: _hits.length,
                itemBuilder: (_, i) => ListTile(
                  dense: true,
                  title: Text(_hits[i].$2, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white)),
                  onTap: () => _jumpTo(_hits[i].$1),
                ),
              );
    }

    return Container(
      width: 320,
      color: const Color(0xFF1C1C1C),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.all(14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 64, height: 92, child: ClipRRect(borderRadius: BorderRadius.circular(4), child: CoverImage(item: item))),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                  ),
                  InkWell(onTap: () => setState(() => _left = false), child: const Icon(Icons.close, color: Colors.white54, size: 20)),
                ]),
                if (item.author != null) Text(item.author!, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 8),
                SizedBox(
                  height: 36,
                  child: TextField(
                    controller: _searchCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    onSubmitted: _search,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '책에서 찾기',
                      hintStyle: const TextStyle(color: Colors.white38),
                      filled: true,
                      fillColor: Colors.black26,
                      prefixIcon: const Icon(Icons.search, size: 18, color: Colors.white54),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
                    ),
                  ),
                ),
              ]),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Row(children: [tab(0, '목차'), tab(1, '하이라이트'), tab(2, '검색결과')]),
          ),
        ),
        const SizedBox(height: 6),
        Expanded(child: list),
      ]),
    );
  }

  // ---------- 오른쪽 뷰어 설정 ----------
  Widget _settingsPanel(Settings s) => ViewerSettingsPanel(
        onClose: () => setState(() => _right = false),
        children: [
          if (item.extension == '.epub' && Platform.isWindows) ...[
            SegmentRow<bool>(
              title: 'EPUB 표시 방식',
              value: false,
              onChanged: (v) {
                if (!v) return;
                s.epubOriginal = true;
                Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => EpubOriginalPage(item: item)));
              },
              options: const [(true, Icons.menu_book, '원본 스타일'), (false, Icons.tune, '읽기 최적화')],
            ),
            const Text('원본 스타일: 출판사가 만든 글꼴·배치·그림 그대로. 읽기 최적화: 앱 테마·글꼴·하이라이트·TTS.',
                style: TextStyle(color: Colors.white38, fontSize: 12)),
            const Divider(color: Colors.white12, height: 28),
          ],
          const PanelSection('읽기'),
          const Text('테마', style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 3.4,
            children: [
              for (var i = 0; i < readerThemes.length; i++)
                Material(
                  color: toolBg,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(color: s.readerTheme == i ? toolActive : Colors.white12, width: s.readerTheme == i ? 2 : 1),
                  ),
                  child: InkWell(
                    onTap: () => s.readerTheme = i,
                    child: Row(children: [
                      const SizedBox(width: 12),
                      Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(colors: [readerThemes[i].bg, readerThemes[i].bg, readerThemes[i].fg, readerThemes[i].fg], stops: const [0, 0.5, 0.5, 1]),
                          border: Border.all(color: Colors.white38),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(readerThemes[i].name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          SegmentRow<int>(
            title: '글꼴',
            value: s.readerFont,
            onChanged: (v) => s.readerFont = v,
            options: const [(0, null, '기본'), (1, null, '명조'), (2, null, '고딕')],
          ),
          _slider('글자 크기', s.readerFontSize, 12, 40, (v) => s.readerFontSize = v, digits: 0),
          _slider('줄 간격', s.readerLineHeight, 1.2, 2.6, (v) => s.readerLineHeight = v),
          _slider('문단 간격', s.readerParagraphGap, 0, 1.5, (v) => s.readerParagraphGap = v),
          _slider('본문 폭', s.readerMaxWidth, 420, 1600, (v) => s.readerMaxWidth = v, digits: 0),
          const Divider(color: Colors.white12, height: 28),
          const PanelSection('넘기기'),
          SegmentRow<bool>(
            title: '읽기방향 (좌우 밀기·방향키)',
            value: s.comicRtl,
            onChanged: (v) => s.comicRtl = v,
            options: const [(false, Icons.east, '왼쪽에서 오른쪽'), (true, Icons.west, '오른쪽에서 왼쪽')],
          ),
          SegmentRow<bool>(
            title: '화면 좌우 눌러 넘기기',
            value: s.tapToTurn,
            onChanged: (v) => s.tapToTurn = v,
            options: const [(true, null, '켜기'), (false, null, '끄기')],
          ),
          SegmentRow<bool>(
            title: '아래 장 탐색 바',
            value: s.viewerSlider,
            onChanged: (v) => s.viewerSlider = v,
            options: const [(true, Icons.view_carousel, '표시'), (false, Icons.visibility_off, '숨기기')],
          ),
          Text('인코딩: ${_doc?.encoding ?? '-'}', style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      );

  Widget _slider(String label, double value, double min, double max, ValueChanged<double> onChanged, {int digits = 1}) => Row(children: [
        SizedBox(width: 72, child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13))),
        Expanded(child: Slider(value: value.clamp(min, max), min: min, max: max, onChanged: onChanged)),
        SizedBox(width: 40, child: Text(value.toStringAsFixed(digits), style: const TextStyle(color: Colors.white70))),
      ]);
}

/// 글자를 고르면 나오는 메뉴: 색 5가지 + 밑줄 / 복사 / 책에서 검색 / AI 뜻풀이
class _SelectionMenu extends StatelessWidget {
  final void Function(String action, int color) onPick;
  const _SelectionMenu({required this.onPick});

  @override
  Widget build(BuildContext context) => Material(
        color: const Color(0xFF2B2B2B),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              for (var i = 0; i < hlColors.length; i++)
                IconButton(
                  tooltip: '하이라이트',
                  icon: Icon(Icons.circle, color: hlColors[i]),
                  onPressed: () => onPick('hl', i),
                ),
              IconButton(
                tooltip: '밑줄',
                icon: const Icon(Icons.format_underline, color: Colors.white),
                onPressed: () => onPick('hl', hlColors.length),
              ),
            ]),
            Row(mainAxisSize: MainAxisSize.min, children: [
              _btn(Icons.content_copy, '복사', () => onPick('copy', 0)),
              _btn(Icons.search, '검색', () => onPick('search', 0)),
              _btn(Icons.translate, 'AI 뜻풀이', () => onPick('ai', 0)),
            ]),
          ]),
        ),
      );

  Widget _btn(IconData icon, String label, VoidCallback f) => InkWell(
        onTap: f,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Column(children: [
            Icon(icon, color: Colors.white, size: 20),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 11)),
          ]),
        ),
      );
}

/// 화면에 붙어 있는 동안 자신의 위치를 registry 에 등록
class _BlockItem extends StatefulWidget {
  final int index;
  final Map<int, BuildContext> registry;
  final Widget child;
  const _BlockItem({super.key, required this.index, required this.registry, required this.child});

  @override
  State<_BlockItem> createState() => _BlockItemState();
}

class _BlockItemState extends State<_BlockItem> {
  @override
  void initState() {
    super.initState();
    widget.registry[widget.index] = context;
  }

  @override
  void dispose() {
    if (identical(widget.registry[widget.index], context)) widget.registry.remove(widget.index);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
