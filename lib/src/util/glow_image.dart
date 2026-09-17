import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 预先把「图标剪影 → 纯色填充 → 高斯模糊」烘焙成一张 GPU 位图。
///
/// 这样做的好处：
/// * 运行时每个图标只需一次 `drawImageRect`（加色混合），不需要逐帧 `saveLayer` + 模糊；
/// * 使用 [ui.Picture.toImageSync] 生成，不做 GPU 回读，因此可以在加载队列里
///   一口气为上百个图标生成柔光而不会阻塞帧。
ui.Image buildGlowImage(
  ui.Image source,
  Color color, {
  double blurFactor = 0.055,
  double padFactor = 0.42,
}) {
  final srcW = source.width;
  final srcH = source.height;
  final longSide = math.max(srcW, srcH);
  final sigma = longSide * blurFactor;
  final padX = (srcW * padFactor).round();
  final padY = (srcH * padFactor).round();
  final outW = srcW + padX * 2;
  final outH = srcH + padY * 2;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final bounds = Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble());

  // 外层：整体高斯模糊
  canvas.saveLayer(
    bounds,
    Paint()
      ..imageFilter = ui.ImageFilter.blur(
        sigmaX: sigma,
        sigmaY: sigma,
        tileMode: ui.TileMode.decal,
      ),
  );

  // 内层：把图标的所有不透明像素替换成目标颜色（保留 alpha 形状）
  canvas.saveLayer(bounds, Paint());
  canvas.translate(padX.toDouble(), padY.toDouble());
  canvas.drawImage(
    source,
    Offset.zero,
    Paint()..filterQuality = FilterQuality.medium,
  );
  canvas.drawRect(
    Rect.fromLTWH(0, 0, srcW.toDouble(), srcH.toDouble()),
    Paint()
      ..color = color
      ..blendMode = BlendMode.srcIn,
  );
  canvas.restore();

  canvas.restore();

  final picture = recorder.endRecording();
  // toImageSync：立即返回，由引擎按需光栅化，避免每张图都等待 GPU 回读。
  final image = picture.toImageSync(outW, outH);
  picture.dispose();
  return image;
}
