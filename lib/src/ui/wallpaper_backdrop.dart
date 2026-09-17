import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// macOS 启动台背景：桌面壁纸经过重度模糊 + 提升饱和度 + 泛光，再整体压暗。
///
/// 用 [CustomPaint] 一次绘制两层（主层 + 加色泛光层），比堆叠 widget 模糊开销低得多，
/// 且整块被 [RepaintBoundary] 包住，静态时只光栅化一次。
class WallpaperBackdrop extends StatelessWidget {
  const WallpaperBackdrop({
    super.key,
    required this.wallpaperPath,
    required this.wallpaperImage,
    this.dim = 0.22,
  });

  final String wallpaperPath;

  /// 已解码的壁纸（由上层预加载，避免切换时闪白）。
  final ui.Image? wallpaperImage;

  /// 额外的压暗程度。
  final double dim;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const _FallbackGradient(),
        if (wallpaperImage != null)
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _WallpaperPainter(wallpaperImage!),
                isComplex: true,
                willChange: false,
              ),
            ),
          )
        else if (wallpaperPath.isNotEmpty)
          Positioned.fill(child: _FileWallpaper(path: wallpaperPath)),
        ColoredBox(color: Colors.black.withValues(alpha: dim)),
        const _Vignette(),
      ],
    );
  }
}

class _WallpaperPainter extends CustomPainter {
  const _WallpaperPainter(this.image);

  final ui.Image image;

  static const List<double> _lum = <double>[0.2126, 0.7152, 0.0722];

  static List<double> _saturationMatrix(double s) {
    final inv = 1 - s;
    return <double>[
      _lum[0] * inv + s, _lum[1] * inv, _lum[2] * inv, 0, 0,
      _lum[0] * inv, _lum[1] * inv + s, _lum[2] * inv, 0, 0,
      _lum[0] * inv, _lum[1] * inv, _lum[2] * inv + s, 0, 0,
      0, 0, 0, 1, 0,
    ];
  }

  /// 计算 cover 模式下应截取的源矩形。
  static Rect _srcCover(Size src, Size dst) {
    final srcAspect = src.width / src.height;
    final dstAspect = dst.width / dst.height;
    if (srcAspect > dstAspect) {
      final w = src.height * dstAspect;
      return Rect.fromLTWH((src.width - w) / 2, 0, w, src.height);
    }
    final h = src.width / dstAspect;
    return Rect.fromLTWH(0, (src.height - h) / 2, src.width, h);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final src = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    // 稍微放大目标矩形，避免模糊在边缘出现半透明收缩
    final dst = (Offset.zero & size).inflate(48);

    // ── 主层：中等模糊 + 提升饱和度 ────────────────────────────────────────
    canvas.saveLayer(
      dst,
      Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: 42,
          sigmaY: 42,
          tileMode: TileMode.decal,
        )
        ..colorFilter = ColorFilter.matrix(_saturationMatrix(1.45)),
    );
    canvas.drawImageRect(
      image,
      _srcCover(src.size, dst.size),
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();

    // ── 泛光层：重度模糊 + 加色混合，还原 macOS 的彩色溢光 ─────────────────
    canvas.saveLayer(
      dst,
      Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: 120,
          sigmaY: 120,
          tileMode: TileMode.decal,
        )
        ..colorFilter = ColorFilter.matrix(_saturationMatrix(2.1))
        ..color = const Color.fromRGBO(0, 0, 0, 0.5)
        ..blendMode = BlendMode.plus,
    );
    canvas.drawImageRect(
      image,
      _srcCover(src.size, dst.size),
      dst,
      Paint()..filterQuality = FilterQuality.low,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WallpaperPainter oldDelegate) =>
      oldDelegate.image != image;
}

/// 壁纸尚未解码完成时的直接文件渲染。
class _FileWallpaper extends StatelessWidget {
  const _FileWallpaper({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return ImageFiltered(
      imageFilter: ui.ImageFilter.blur(
        sigmaX: 40,
        sigmaY: 40,
        tileMode: TileMode.decal,
      ),
      child: Transform.scale(
        scale: 1.15,
        child: Image.file(
          File(path),
          fit: BoxFit.cover,
          filterQuality: FilterQuality.low,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      ),
    );
  }
}

class _FallbackGradient extends StatelessWidget {
  const _FallbackGradient();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            Color(0xFF243447),
            Color(0xFF3A2C4E),
            Color(0xFF12202E),
          ],
        ),
      ),
    );
  }
}

class _Vignette extends StatelessWidget {
  const _Vignette();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          radius: 0.95,
          colors: <Color>[
            Color(0x00000000),
            Color(0x00000000),
            Color(0x40000000),
          ],
          stops: <double>[0.0, 0.62, 1.0],
        ),
      ),
    );
  }
}
