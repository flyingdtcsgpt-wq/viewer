import 'package:flutter/material.dart';

/// ARARIFlex 브랜드
const appName = 'ARARIFlex';
const appNameKo = '아라리플렉스';

const brandNavy = Color(0xFF0D1F45);
const brandRed = Color(0xFFE50914);
const brandRedLight = Color(0xFFFF4D5A);
/// 로고 그라데이션 (진한 빨강 → 밝은 빨강)
const brandGradient = LinearGradient(colors: [Color(0xFFB20710), Color(0xFFE50914), Color(0xFFFF4D5A)]);

/// 로고: "ARARI" (첫 A 안에 빨간 재생 ▶) + 빨간 그라데이션 기울임 "Flex" + 빨간 물결 밑줄
class ArariLogo extends StatelessWidget {
  final double size;
  /// 어두운 배경이면 "ARARI" 를 흰색으로
  final bool onDark;
  const ArariLogo({super.key, this.size = 24, this.onDark = true});

  @override
  Widget build(BuildContext context) {
    final navy = onDark ? Colors.white : brandNavy;
    final base = TextStyle(fontSize: size, fontWeight: FontWeight.w900, height: 1.0, letterSpacing: size * 0.02);
    return Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
      Stack(clipBehavior: Clip.none, children: [
        Text('ARARI', style: base.copyWith(color: navy)),
        // 첫 A 안의 재생 버튼
        Positioned(
          left: size * 0.17,
          top: size * 0.42,
          child: ShaderMask(
            shaderCallback: (r) => brandGradient.createShader(r),
            child: Icon(Icons.play_arrow_rounded, size: size * 0.42, color: Colors.white),
          ),
        ),
        // RARI 아래 물결
        Positioned(
          left: size * 0.95,
          right: 0,
          bottom: -size * 0.22,
          height: size * 0.22,
          child: CustomPaint(painter: _Wave()),
        ),
      ]),
      SizedBox(width: size * 0.03), // 붙여 쓰기: ARARIFlex
      ShaderMask(
        shaderCallback: (r) => brandGradient.createShader(r),
        child: Text('Flex', style: base.copyWith(color: Colors.white, fontStyle: FontStyle.italic)),
      ),
    ]);
  }
}

class _Wave extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final path = Path()
      ..moveTo(0, s.height * 0.8)
      ..cubicTo(s.width * 0.3, -s.height * 0.2, s.width * 0.55, s.height * 1.3, s.width, 0);
    canvas.drawPath(
      path,
      Paint()
        ..shader = const LinearGradient(colors: [Color(0xFFB20710), Color(0xFFFF4D5A)]).createShader(Offset.zero & s)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = s.height * 0.45,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
