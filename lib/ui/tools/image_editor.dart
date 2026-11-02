import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

/// 이미지 편집 (표지): 자르기 · 회전 · 반전 · 밝기/대비/채도 · 흑백
/// 결과는 JPG 바이트. 취소하면 null.
Future<Uint8List?> showImageEditor(BuildContext context, Uint8List bytes) =>
    showDialog<Uint8List>(context: context, barrierDismissible: false, builder: (_) => _ImageEditor(bytes));

class _Edit {
  int turns = 0; // 90도 단위 회전
  bool flipH = false, flipV = false;
  Rect crop = const Rect.fromLTWH(0, 0, 1, 1); // 회전·반전 후 이미지 기준 비율
  double brightness = 1, contrast = 1, saturation = 1;
  bool gray = false;
}

/// 무거운 계산은 별도 isolate 에서
Uint8List _apply((Uint8List, int, bool, bool, Rect, double, double, double, bool) a) {
  final (bytes, turns, fh, fv, crop, br, ct, sat, gray) = a;
  var im = img.decodeImage(bytes)!;
  if (turns % 4 != 0) im = img.copyRotate(im, angle: 90 * (turns % 4));
  if (fh) im = img.flipHorizontal(im);
  if (fv) im = img.flipVertical(im);
  final x = (crop.left * im.width).round().clamp(0, im.width - 1);
  final y = (crop.top * im.height).round().clamp(0, im.height - 1);
  final w = (crop.width * im.width).round().clamp(1, im.width - x);
  final h = (crop.height * im.height).round().clamp(1, im.height - y);
  if (x != 0 || y != 0 || w != im.width || h != im.height) im = img.copyCrop(im, x: x, y: y, width: w, height: h);
  if (br != 1 || ct != 1 || sat != 1) im = img.adjustColor(im, brightness: br, contrast: ct, saturation: sat);
  if (gray) im = img.grayscale(im);
  return img.encodeJpg(im, quality: 92);
}

class _ImageEditor extends StatefulWidget {
  final Uint8List bytes;
  const _ImageEditor(this.bytes);
  @override
  State<_ImageEditor> createState() => _ImageEditorState();
}

class _ImageEditorState extends State<_ImageEditor> {
  final _e = _Edit();
  Size? _size; // 원본 크기
  int _tab = 0;
  double? _ratio; // null = 자유
  bool _busy = false;
  String _handle = '';

  @override
  void initState() {
    super.initState();
    ui.decodeImageFromList(widget.bytes, (im) {
      if (mounted) setState(() => _size = Size(im.width.toDouble(), im.height.toDouble()));
    });
  }

  /// 회전 후 크기
  Size get _shown => _e.turns.isOdd ? Size(_size!.height, _size!.width) : _size!;

  void _setRatio(double? r) {
    setState(() {
      _ratio = r;
      if (r == null) return;
      // 가운데에 가능한 크게
      final s = _shown;
      final imgRatio = s.width / s.height;
      double w = 1, h = 1;
      if (r > imgRatio) {
        h = imgRatio / r;
      } else {
        w = r / imgRatio;
      }
      _e.crop = Rect.fromLTWH((1 - w) / 2, (1 - h) / 2, w, h);
    });
  }

  void _rotate(int d) => setState(() {
        _e.turns = (_e.turns + d) % 4;
        _e.crop = const Rect.fromLTWH(0, 0, 1, 1);
      });

  Rect _fit(Size box) {
    final s = _shown;
    final scale = (box.width / s.width) < (box.height / s.height) ? box.width / s.width : box.height / s.height;
    final w = s.width * scale, h = s.height * scale;
    return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
  }

  // 색 미리보기 (실제 저장은 image 패키지로)
  List<double> get _matrix {
    final b = (_e.brightness - 1) * 255, c = _e.contrast, t = (1 - c) * 128;
    final s = _e.gray ? 0.0 : _e.saturation;
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final sr = (1 - s) * lr, sg = (1 - s) * lg, sb = (1 - s) * lb;
    return [
      (sr + s) * c, sg * c, sb * c, 0, b + t,
      sr * c, (sg + s) * c, sb * c, 0, b + t,
      sr * c, sg * c, (sb + s) * c, 0, b + t,
      0, 0, 0, 1, 0,
    ];
  }

  Widget _preview() => LayoutBuilder(builder: (context, c) {
        final box = Size(c.maxWidth, c.maxHeight);
        final r = _fit(box);
        final crop = Rect.fromLTWH(r.left + _e.crop.left * r.width, r.top + _e.crop.top * r.height, _e.crop.width * r.width, _e.crop.height * r.height);

        void start(Offset p) {
          const hit = 26.0;
          String h = '';
          if ((p - crop.topLeft).distance < hit) h = 'tl';
          if ((p - crop.topRight).distance < hit) h = 'tr';
          if ((p - crop.bottomLeft).distance < hit) h = 'bl';
          if ((p - crop.bottomRight).distance < hit) h = 'br';
          if (h.isEmpty && crop.contains(p)) h = 'move';
          _handle = h;
        }

        void update(Offset d) {
          if (_handle.isEmpty) return;
          final dx = d.dx / r.width, dy = d.dy / r.height;
          var c = _e.crop;
          double l = c.left, t = c.top, rr = c.right, b = c.bottom;
          switch (_handle) {
            case 'move':
              l += dx;
              t += dy;
              rr += dx;
              b += dy;
              final w = c.width, hh = c.height;
              l = l.clamp(0.0, 1 - w);
              t = t.clamp(0.0, 1 - hh);
              rr = l + w;
              b = t + hh;
            case 'tl':
              l += dx;
              t += dy;
            case 'tr':
              rr += dx;
              t += dy;
            case 'bl':
              l += dx;
              b += dy;
            case 'br':
              rr += dx;
              b += dy;
          }
          l = l.clamp(0.0, 1.0);
          t = t.clamp(0.0, 1.0);
          rr = rr.clamp(0.0, 1.0);
          b = b.clamp(0.0, 1.0);
          if (rr - l < 0.05 || b - t < 0.05) return;
          c = Rect.fromLTRB(l, t, rr, b);
          // 비율 고정이면 높이를 너비에 맞춘다
          if (_ratio != null && _handle != 'move') {
            final s = _shown;
            final hNorm = (c.width * s.width / _ratio!) / s.height;
            c = _handle.startsWith('t') ? Rect.fromLTRB(c.left, (c.bottom - hNorm).clamp(0.0, 1.0), c.right, c.bottom) : Rect.fromLTWH(c.left, c.top, c.width, hNorm.clamp(0.05, 1 - c.top));
          }
          setState(() => _e.crop = c);
        }

        return GestureDetector(
          onPanStart: (d) => start(d.localPosition),
          onPanUpdate: (d) => update(d.delta),
          child: Stack(children: [
            Positioned.fromRect(
              rect: r,
              child: ColorFiltered(
                colorFilter: ColorFilter.matrix(_matrix),
                // 저장할 때와 같은 순서: 회전한 다음 뒤집기
                child: Transform.scale(
                  scaleX: _e.flipH ? -1 : 1,
                  scaleY: _e.flipV ? -1 : 1,
                  child: RotatedBox(quarterTurns: _e.turns, child: Image.memory(widget.bytes, fit: BoxFit.fill)),
                ),
              ),
            ),
            // 자른 밖은 어둡게
            Positioned.fill(child: CustomPaint(painter: _Shade(r, crop))),
            // 모서리 손잡이
            for (final p in [crop.topLeft, crop.topRight, crop.bottomLeft, crop.bottomRight])
              Positioned(left: p.dx - 7, top: p.dy - 7, child: Container(width: 14, height: 14, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle))),
          ]),
        );
      });

  @override
  Widget build(BuildContext context) {
    if (_size == null) return const Dialog(child: SizedBox(width: 200, height: 200, child: Center(child: CircularProgressIndicator())));
    final s = _shown;
    final outW = (s.width * _e.crop.width).round(), outH = (s.height * _e.crop.height).round();
    final size = MediaQuery.sizeOf(context);

    Widget presetBtn(String label, double? r) => OutlinedButton(
          style: OutlinedButton.styleFrom(
            backgroundColor: _ratio == r && !(r == null && label == '원본') ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.3) : null,
          ),
          onPressed: () => label == '원본' ? setState(() => _e.crop = const Rect.fromLTWH(0, 0, 1, 1)) : _setRatio(r),
          child: Text(label),
        );

    Widget slider(String label, double v, ValueChanged<double> f) => Row(children: [
          SizedBox(width: 50, child: Text(label)),
          Expanded(child: Slider(min: 0.3, max: 2.0, value: v, onChanged: (x) => setState(() => f(x)))),
          SizedBox(width: 40, child: Text('${(v * 100).round()}%')),
        ]);

    final controls = switch (_tab) {
      0 => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 6, runSpacing: 6, children: [
            presetBtn('원본', null),
            presetBtn('자유', null),
            presetBtn('1:1', 1),
            presetBtn('4:3', 4 / 3),
            presetBtn('3:2', 3 / 2),
            presetBtn('2:3', 2 / 3),
            presetBtn('3:4', 3 / 4),
            presetBtn('16:9', 16 / 9),
          ]),
          const SizedBox(height: 12),
          const Text('사진 위를 끌거나 모서리를 움직여 자를 영역을 정하세요.', style: TextStyle(fontSize: 12)),
        ]),
      1 => Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(onPressed: () => _rotate(1), icon: const Icon(Icons.rotate_right), label: const Text('90° 회전')),
          OutlinedButton.icon(onPressed: () => _rotate(3), icon: const Icon(Icons.rotate_left), label: const Text('반대로 90°')),
          OutlinedButton.icon(onPressed: () => setState(() => _e.flipH = !_e.flipH), icon: const Icon(Icons.flip), label: const Text('좌우 반전')),
          OutlinedButton.icon(
              onPressed: () => setState(() => _e.flipV = !_e.flipV),
              icon: const RotatedBox(quarterTurns: 1, child: Icon(Icons.flip)),
              label: const Text('상하 반전')),
        ]),
      _ => Column(children: [
          slider('밝기', _e.brightness, (v) => _e.brightness = v),
          slider('대비', _e.contrast, (v) => _e.contrast = v),
          slider('채도', _e.saturation, (v) => _e.saturation = v),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('흑백'), value: _e.gray, onChanged: (v) => setState(() => _e.gray = v)),
        ]),
    };

    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: size.width.clamp(0, 1300).toDouble(),
        height: size.height * 0.88,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Text('이미지 편집', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const Spacer(),
              Text('결과 크기 · $outW × $outH px', style: const TextStyle(fontSize: 12)),
              IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
            ]),
            Row(children: [
              for (final (i, l) in const [(0, '자르기'), (1, '회전 · 반전'), (2, '효과')])
                Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(label: Text(l), selected: _tab == i, onSelected: (_) => setState(() => _tab = i))),
            ]),
            const Divider(),
            Expanded(
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 300, child: SingleChildScrollView(child: controls)),
                const VerticalDivider(),
                Expanded(child: Container(color: Colors.black, child: _preview())),
              ]),
            ),
            const SizedBox(height: 10),
            Row(children: [
              const Text('편집 결과는 새 표지에 반영됩니다. 원본 그림 파일은 그대로입니다.', style: TextStyle(fontSize: 12)),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() {
                  final f = _Edit();
                  _e
                    ..turns = f.turns
                    ..flipH = false
                    ..flipV = false
                    ..crop = f.crop
                    ..brightness = 1
                    ..contrast = 1
                    ..saturation = 1
                    ..gray = false;
                  _ratio = null;
                }),
                child: const Text('모두 재설정'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () async {
                        setState(() => _busy = true);
                        // isolate 로는 값만 넘긴다 (State 를 넘기면 안 됨)
                        final args = (widget.bytes, _e.turns, _e.flipH, _e.flipV, _e.crop, _e.brightness, _e.contrast, _e.saturation, _e.gray);
                        final out = await Isolate.run(() => _apply(args));
                        if (context.mounted) Navigator.pop(context, out);
                      },
                child: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('적용'),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _Shade extends CustomPainter {
  final Rect image, crop;
  _Shade(this.image, this.crop);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Path()
      ..addRect(image)
      ..addRect(crop)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(p, Paint()..color = Colors.black54);
    canvas.drawRect(crop, Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);
    // 3등분 안내선
    final g = Paint()..color = Colors.white38;
    for (var i = 1; i < 3; i++) {
      canvas.drawLine(Offset(crop.left + crop.width * i / 3, crop.top), Offset(crop.left + crop.width * i / 3, crop.bottom), g);
      canvas.drawLine(Offset(crop.left, crop.top + crop.height * i / 3), Offset(crop.right, crop.top + crop.height * i / 3), g);
    }
  }

  @override
  bool shouldRepaint(_Shade old) => old.crop != crop || old.image != image;
}
