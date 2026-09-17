import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// 兜底柔光颜色（图标本身无彩色时使用）。
const Color kNeutralGlow = Color(0xFFB9C2CC);

/// 从 RGBA 位图中提取一个「有代表性且适合发光」的主色。
///
/// 思路：把像素量化到 16³ 直方图，按「饱和度² × 明度适中性 × alpha」加权，
/// 选出权重最高的色格；再对落入该色格的像素求平均，得到更准确的颜色。
/// 最后把颜色往高饱和、适中明度方向推，使其作为柔光足够醒目。
Color glowColorFromRgba(Uint8List rgba, {int alphaThreshold = 48}) {
  final weights = Float32List(4096);
  final sumR = Float64List(4096);
  final sumG = Float64List(4096);
  final sumB = Float64List(4096);
  final counts = Uint32List(4096);

  var bestWeight = 0.0;
  var bestIndex = -1;

  for (var i = 0; i + 3 < rgba.length; i += 4) {
    final a = rgba[i + 3];
    if (a < alphaThreshold) continue;

    final r = rgba[i];
    final g = rgba[i + 1];
    final b = rgba[i + 2];

    final rf = r / 255.0;
    final gf = g / 255.0;
    final bf = b / 255.0;
    final maxC = math.max(rf, math.max(gf, bf));
    final minC = math.min(rf, math.min(gf, bf));
    final sat = maxC <= 0.0 ? 0.0 : (maxC - minC) / maxC;
    final lum = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf;

    // 明度太暗或太亮的颜色做柔光都不好看，用钟形权重压制。
    final lumWeight = 1.0 - ((lum - 0.55).abs() / 0.62).clamp(0.0, 1.0);

    final w = sat * sat * lumWeight * (a / 255.0);
    if (w <= 0.0) continue;

    final idx = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4);
    weights[idx] += w;
    sumR[idx] += r;
    sumG[idx] += g;
    sumB[idx] += b;
    counts[idx]++;

    if (weights[idx] > bestWeight) {
      bestWeight = weights[idx];
      bestIndex = idx;
    }
  }

  if (bestIndex < 0 || counts[bestIndex] == 0) return kNeutralGlow;

  final c = counts[bestIndex];
  final raw = Color.fromARGB(
    255,
    (sumR[bestIndex] / c).round().clamp(0, 255),
    (sumG[bestIndex] / c).round().clamp(0, 255),
    (sumB[bestIndex] / c).round().clamp(0, 255),
  );

  return _boostForGlow(raw);
}

/// 把颜色推向更适合做柔光的状态：高一档饱和度、略高明度。
Color _boostForGlow(Color color) {
  final hsl = HSLColor.fromColor(color);
  final isNeutral = hsl.saturation < 0.12;
  return hsl
      .withSaturation(isNeutral ? 0.08 : (hsl.saturation * 1.25).clamp(0.0, 1.0))
      .withLightness(isNeutral ? 0.78 : hsl.lightness.clamp(0.52, 0.72))
      .toColor();
}

/// 在两个颜色之间做可空插值，`t = 0` 返回 [a]。
Color lerpGlow(Color a, Color b, double t) =>
    Color.lerp(a, b, t.clamp(0.0, 1.0)) ?? a;
