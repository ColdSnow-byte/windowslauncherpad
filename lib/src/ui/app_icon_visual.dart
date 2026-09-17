import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:windowslauncherpad/src/state/icon_repository.dart';
import 'package:windowslauncherpad/src/util/color_utils.dart';

/// 应用图标的纯视觉呈现：柔光 + 图标本体（或占位符）。
///
/// 柔光使用预先烘焙好的 [IconAsset.glowImage]，运行时只是一次 drawImageRect，
/// 因此几十个图标同屏也不会因为逐帧模糊而掉帧。
class AppIconVisual extends StatelessWidget {
  const AppIconVisual({
    super.key,
    required this.asset,
    required this.size,
    this.glowColor,
    this.glowStrength = 1.0,
    this.fallbackLabel = '',
    this.iconOpacity = 1.0,
  });

  final IconAsset? asset;
  final double size;

  /// 覆盖柔光颜色（未提供时使用图标自身主色）。
  final Color? glowColor;

  /// 柔光强度，0 表示关闭。
  final double glowStrength;

  /// 图标未就绪时显示的占位首字母。
  final String fallbackLabel;
  final double iconOpacity;

  @override
  Widget build(BuildContext context) {
    final a = asset;
    final color = glowColor ?? a?.glow ?? kNeutralGlow;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (a != null && a.glowImage != null && glowStrength > 0.01)
            Positioned.fill(
              child: CustomPaint(
                painter: IconGlowPainter(
                  image: a.glowImage!,
                  strength: glowStrength,
                ),
              ),
            ),
          if (a != null)
            Opacity(
              opacity: iconOpacity,
              child: RawImage(
                image: a.image,
                width: size,
                height: size,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
              ),
            )
          else
            _Placeholder(label: fallbackLabel, size: size, color: color),
        ],
      ),
    );
  }
}

/// 把烘焙好的柔光位图铺满指定区域。
///
/// 画两遍：第一遍正常混合，让图标主色的柔光清晰可见；
/// 第二遍加色混合，制造一点点「发光」的辉光感。
/// 只用加色混合的话，在明亮背景上会直接饱和成白色，失去颜色。
class IconGlowPainter extends CustomPainter {
  const IconGlowPainter({required this.image, required this.strength});

  final ui.Image image;
  final double strength;

  @override
  void paint(Canvas canvas, Size size) {
    if (strength <= 0.01) return;
    final src = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final dst = Offset.zero & size;

    // 1) 彩色柔光本体
    canvas.drawImageRect(
      image,
      src,
      dst,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..color = Colors.white.withValues(
          alpha: (0.95 * strength).clamp(0.0, 1.0),
        ),
    );

    // 2) 加色辉光
    canvas.drawImageRect(
      image,
      src,
      dst,
      Paint()
        ..blendMode = BlendMode.plus
        ..filterQuality = FilterQuality.medium
        ..color = Colors.white.withValues(
          alpha: (0.28 * strength).clamp(0.0, 1.0),
        ),
    );
  }

  @override
  bool shouldRepaint(IconGlowPainter old) =>
      old.image != image || old.strength != strength;
}

/// 图标尚未就绪时的占位：柔和圆角块 + 首字母。
class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.label,
    required this.size,
    required this.color,
  });

  final String label;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final trimmed = label.trim();
    final text = trimmed.isEmpty ? '?' : trimmed.characters.first;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            color.withValues(alpha: 0.42),
            color.withValues(alpha: 0.16),
          ],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
      ),
      alignment: Alignment.center,
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: size * 0.38,
          fontWeight: FontWeight.w600,
          color: Colors.white.withValues(alpha: 0.9),
        ),
      ),
    );
  }
}

/// 文件夹预览：把内部应用的小图标按 3×3 拼在一个圆角玻璃方块里。
class FolderPreview extends StatelessWidget {
  const FolderPreview({
    super.key,
    required this.assets,
    required this.size,
    this.glowStrength = 1.0,
  });

  final List<IconAsset?> assets;
  final double size;
  final double glowStrength;

  @override
  Widget build(BuildContext context) {
    final inner = size * 0.74;
    final first = assets.isEmpty ? null : assets.first;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (first?.glowImage != null && glowStrength > 0.01)
            Positioned.fill(
              child: CustomPaint(
                painter: IconGlowPainter(
                  image: first!.glowImage!,
                  strength: glowStrength * 0.85,
                ),
              ),
            ),
          Container(
            width: inner,
            height: inner,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(inner * 0.26),
              color: Colors.white.withValues(alpha: 0.15),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.3),
              ),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.28),
                  blurRadius: 20,
                  offset: const Offset(0, 7),
                ),
              ],
            ),
            child: Padding(
              padding: EdgeInsets.all(inner * 0.1),
              child: GridView.count(
                crossAxisCount: 3,
                physics: const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.zero,
                mainAxisSpacing: inner * 0.035,
                crossAxisSpacing: inner * 0.035,
                children: List<Widget>.generate(math.max(assets.length, 3), (i) {
                  if (i >= assets.length) return const SizedBox.shrink();
                  final a = assets[i];
                  if (a == null) return const SizedBox.shrink();
                  return RawImage(
                    image: a.image,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.medium,
                  );
                }),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
