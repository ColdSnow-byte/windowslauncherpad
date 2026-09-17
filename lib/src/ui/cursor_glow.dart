import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 跟随鼠标的白色柔光层。
///
/// 位置用指数平滑做「轻微拖尾」，移动越快亮度越高；静止时自动停掉 Ticker。
class CursorGlowLayer extends StatefulWidget {
  const CursorGlowLayer({
    super.key,
    required this.child,
    this.radius = 180,
    this.enabled = true,
  });

  final Widget child;
  final double radius;
  final bool enabled;

  @override
  State<CursorGlowLayer> createState() => _CursorGlowLayerState();
}

class _CursorGlowLayerState extends State<CursorGlowLayer>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  final ValueNotifier<Offset> _render = ValueNotifier<Offset>(Offset.zero);
  final ValueNotifier<double> _intensity = ValueNotifier<double>(0);

  /// 拖尾历史（最近若干个位置）。
  final ValueNotifier<List<Offset>> _trail =
      ValueNotifier<List<Offset>>(const <Offset>[]);

  Offset _target = Offset.zero;
  double _speed = 0;
  Duration _lastTick = Duration.zero;
  bool _pointerInside = false;

  @override
  void initState() {
    super.initState();
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _render.dispose();
    _intensity.dispose();
    _trail.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final dt = _lastTick == Duration.zero
        ? 1 / 60
        : ((elapsed - _lastTick).inMicroseconds / 1e6).clamp(0.001, 0.05);
    _lastTick = elapsed;

    final k = 1 - math.exp(-19 * dt);
    final next = Offset.lerp(_render.value, _target, k)!;
    final delta = (next - _render.value).distance;
    _speed = _speed * 0.86 + (delta / dt) * 0.14;

    if ((next - _render.value).distanceSquared > 0.01) {
      _render.value = next;
    }

    // 移动越快越亮，静止后回落到基础亮度
    final targetI = !_pointerInside
        ? 0.0
        : (0.62 + (_speed / 2600).clamp(0.0, 0.38));
    final ni = _intensity.value + (targetI - _intensity.value) * (1 - math.exp(-9 * dt));
    if ((ni - _intensity.value).abs() > 0.001) _intensity.value = ni;

    final trail = List<Offset>.of(_trail.value);
    if (trail.isEmpty || (trail.first - next).distance > 7) {
      trail.insert(0, next);
      if (trail.length > 10) trail.removeLast();
      _trail.value = trail;
    } else {
      trail[0] = next;
      _trail.value = trail;
    }
  }

  void _updateTarget(Offset local) {
    _target = local;
    if (!_pointerInside) {
      _pointerInside = true;
      _render.value = local;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerHover: (event) => _updateTarget(event.localPosition),
      onPointerMove: (event) => _updateTarget(event.localPosition),
      onPointerDown: (event) => _updateTarget(event.localPosition),
      onPointerSignal: (_) {},
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _CursorGlowPainter(
                    position: _render,
                    intensity: _intensity,
                    trail: _trail,
                    radius: widget.radius,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CursorGlowPainter extends CustomPainter {
  _CursorGlowPainter({
    required this.position,
    required this.intensity,
    required this.trail,
    required this.radius,
  }) : super(repaint: Listenable.merge(<Listenable>[position, intensity, trail]));

  final ValueListenable<Offset> position;
  final ValueListenable<double> intensity;
  final ValueListenable<List<Offset>> trail;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final i = intensity.value;
    if (i <= 0.01) return;

    final pos = position.value;
    final r = radius * (0.86 + 0.22 * i);

    // 拖尾：依次衰减的柔和光点
    final t = trail.value;
    for (var idx = 1; idx < t.length; idx++) {
      final f = (1 - idx / t.length);
      final alpha = 0.055 * i * f * f;
      if (alpha < 0.004) continue;
      _drawGlow(canvas, t[idx], r * (0.75 + 0.25 * f), alpha);
    }

    // 主光晕
    _drawGlow(canvas, pos, r, 0.34 * i);

    // 核心亮点
    final coreR = r * 0.16;
    canvas.drawCircle(
      pos,
      coreR,
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = RadialGradient(
          colors: <Color>[
            Colors.white.withValues(alpha: 0.5 * i),
            Colors.white.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromCircle(center: pos, radius: coreR)),
    );
  }

  void _drawGlow(Canvas canvas, Offset center, double r, double alpha) {
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = RadialGradient(
          colors: <Color>[
            Colors.white.withValues(alpha: alpha),
            Colors.white.withValues(alpha: alpha * 0.55),
            Colors.white.withValues(alpha: alpha * 0.18),
            Colors.white.withValues(alpha: 0.0),
          ],
          stops: const <double>[0.0, 0.24, 0.55, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: r)),
    );
  }

  @override
  bool shouldRepaint(_CursorGlowPainter oldDelegate) =>
      oldDelegate.radius != radius;
}
