import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 跟随鼠标的白色柔光层。
///
/// 性能考量：径向渐变**只烘焙一次**成贴图，之后每帧只做几次 `drawImageRect`，
/// 避免每帧重建 `Gradient` 对象；同时把光点数量压到 4 个、半径收敛，
/// 让每帧需要做混合的像素面积降到原来的 1/5 左右。
class CursorGlowLayer extends StatefulWidget {
  const CursorGlowLayer({
    super.key,
    required this.child,
    this.radius = 150,
    this.enabled = true,
  });

  final Widget child;
  final double radius;
  final bool enabled;

  @override
  State<CursorGlowLayer> createState() => _CursorGlowLayerState();
}

class _CursorGlowLayerState extends State<CursorGlowLayer> {
  /// 拖尾采样点数（越多越平滑，也越贵）。
  static const int _trailPoints = 4;

  /// 位置采样的最小间距，避免每个像素都触发重绘。
  static const double _trailStep = 14;

  /// 柔光刷新间隔：33ms ≈ 30fps。柔光是纯模糊，看不出帧率差，
  /// 但出帧数减半意味着 GPU 合成开销减半。
  static const Duration _frameInterval = Duration(milliseconds: 33);

  Timer? _timer;
  int _lastMicros = 0;

  final ValueNotifier<Offset> _render = ValueNotifier<Offset>(Offset.zero);
  final ValueNotifier<double> _intensity = ValueNotifier<double>(0);
  final ValueNotifier<List<Offset>> _trail = ValueNotifier<List<Offset>>(
    const <Offset>[],
  );

  ui.Image? _sprite;

  Offset _target = Offset.zero;
  double _speed = 0;
  bool _pointerInside = false;

  @override
  void initState() {
    super.initState();
    _sprite = _bakeGlowSprite(256);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sprite?.dispose();
    _render.dispose();
    _intensity.dispose();
    _trail.dispose();
    super.dispose();
  }

  /// 把「白 -> 透明」的径向渐变烘焙成一张方形贴图。
  static ui.Image _bakeGlowSprite(int size) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final radius = size / 2;
    final center = Offset(radius, radius);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: <Color>[
            Colors.white.withValues(alpha: 1.0),
            Colors.white.withValues(alpha: 0.52),
            Colors.white.withValues(alpha: 0.16),
            Colors.white.withValues(alpha: 0.0),
          ],
          stops: const <double>[0.0, 0.24, 0.55, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: radius)),
    );
    final picture = recorder.endRecording();
    final image = picture.toImageSync(size, size);
    picture.dispose();
    return image;
  }

  void _tick(Timer timer) {
    final now = DateTime.now().microsecondsSinceEpoch;
    final dt = _lastMicros == 0
        ? _frameInterval.inMicroseconds / 1e6
        : ((now - _lastMicros) / 1e6).clamp(0.001, 0.08);
    _lastMicros = now;

    final k = 1 - math.exp(-19 * dt);
    final next = Offset.lerp(_render.value, _target, k)!;
    final moved = (next - _render.value).distance;
    _speed = _speed * 0.86 + (moved / dt) * 0.14;
    if (moved > 0.05) _render.value = next;

    final targetIntensity = !_pointerInside
        ? 0.0
        : (0.62 + (_speed / 2600).clamp(0.0, 0.38));
    final nextIntensity =
        _intensity.value +
        (targetIntensity - _intensity.value) * (1 - math.exp(-9 * dt));
    if ((nextIntensity - _intensity.value).abs() > 0.002) {
      _intensity.value = nextIntensity;
    }

    final trail = _trail.value;
    if (trail.isEmpty || (trail.first - next).distance > _trailStep) {
      final updated = List<Offset>.of(trail);
      updated.insert(0, next);
      if (updated.length > _trailPoints) {
        updated.removeRange(_trailPoints, updated.length);
      }
      _trail.value = updated;
    }

    // 灯灭即停表：鼠标停下后不再请求 vsync，
    // 否则应用会一直以 60fps 出帧，GPU 白天空转。
    final settled =
        (next - _target).distance < 0.4 &&
        (nextIntensity - _intensity.value).abs() < 0.001 &&
        _speed < 6;
    if (settled) {
      _speed = 0;
      _timer?.cancel();
      _timer = null;
    }
  }

  /// 鼠标一有动静就启动刷新；静止后 [_tick] 会自动停表，出帧随之归零。
  void _wake() {
    if (_timer != null) return;
    _lastMicros = 0;
    _timer = Timer.periodic(_frameInterval, _tick);
  }

  void _updateTarget(Offset local) {
    _target = local;
    if (!_pointerInside) {
      _pointerInside = true;
      _render.value = local;
    }
    _wake();
  }

  void _onPointerExit() {
    _pointerInside = false;
    _wake();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    // 关键：柔光只画在鼠标附近的一个小方块里，
    // 而不是整屏铺一层 —— 每帧需要重新光栅化的面积因此小一个数量级。
    final box = widget.radius * 3.0;

    return MouseRegion(
      opaque: false,
      onExit: (_) => _onPointerExit(),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerHover: (event) => _updateTarget(event.localPosition),
        onPointerMove: (event) => _updateTarget(event.localPosition),
        onPointerDown: (event) => _updateTarget(event.localPosition),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            widget.child,
            ValueListenableBuilder<Offset>(
              valueListenable: _render,
              builder: (context, position, _) => Positioned(
                left: position.dx - box / 2,
                top: position.dy - box / 2,
                width: box,
                height: box,
                child: IgnorePointer(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: _CursorGlowPainter(
                        sprite: _sprite,
                        position: _render,
                        intensity: _intensity,
                        trail: _trail,
                        radius: widget.radius,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CursorGlowPainter extends CustomPainter {
  _CursorGlowPainter({
    required this.sprite,
    required this.position,
    required this.intensity,
    required this.trail,
    required this.radius,
  }) : super(
         repaint: Listenable.merge(<Listenable>[position, intensity, trail]),
       );

  final ui.Image? sprite;
  final ValueListenable<Offset> position;
  final ValueListenable<double> intensity;
  final ValueListenable<List<Offset>> trail;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final image = sprite;
    final i = intensity.value;
    if (image == null || i <= 0.02) return;

    final pos = position.value;
    final r = radius * (0.86 + 0.22 * i);
    final src = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );

    // 绘制区是一个跟随鼠标的小方块，坐标换算到方块内部
    final local = Offset(size.width / 2, size.height / 2);

    canvas.save();
    canvas.clipRect(Offset.zero & size);

    void blit(Offset center, double glowRadius, double alpha) {
      if (alpha < 0.006) return;
      final rect = Rect.fromCircle(center: center, radius: glowRadius);
      if (!rect.overlaps(Offset.zero & size)) return;
      canvas.drawImageRect(
        image,
        src,
        rect,
        Paint()
          ..filterQuality = FilterQuality.low
          ..color = Colors.white.withValues(alpha: alpha.clamp(0.0, 1.0)),
      );
    }

    // 拖尾：依次衰减（相对主光点做偏移）
    final points = trail.value;
    for (var index = 1; index < points.length; index++) {
      final fade = 1 - index / points.length;
      blit(
        local + (points[index] - pos),
        r * (0.72 + 0.2 * fade),
        0.05 * i * fade * fade,
      );
    }

    // 主光晕
    blit(local, r, 0.34 * i);
    // 核心亮点
    blit(local, r * 0.22, 0.34 * i);

    canvas.restore();
  }

  @override
  bool shouldRepaint(_CursorGlowPainter oldDelegate) =>
      oldDelegate.radius != radius || oldDelegate.sprite != sprite;
}
