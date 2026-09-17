import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// macOS 启动台背景：桌面壁纸经过重度模糊 + 提升饱和度 + 泛光，再整体压暗。
///
/// 性能考量：模糊与泛光**只在壁纸变化时烘焙一次**，并且烘焙到 1/4 分辨率的小图上。
/// 运行时每帧只做一次 `drawImageRect` 放大绘制，渲染树里不再有全屏 `saveLayer`。
class WallpaperBackdrop extends StatefulWidget {
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
  State<WallpaperBackdrop> createState() => _WallpaperBackdropState();
}

class _WallpaperBackdropState extends State<WallpaperBackdrop> {
  /// 烘焙分辨率相对屏幕的缩放比例。
  static const double _scale = 0.25;

  ui.Image? _baked;
  Size? _bakedFor;

  @override
  void dispose() {
    _baked?.dispose();
    super.dispose();
  }

  void _ensureBaked(Size screen) {
    final source = widget.wallpaperImage;
    if (source == null) {
      if (_baked != null) {
        _baked?.dispose();
        _baked = null;
        _bakedFor = null;
      }
      return;
    }
    final target = Size(
      (screen.width * _scale).roundToDouble().clamp(64, 1024),
      (screen.height * _scale).roundToDouble().clamp(64, 1024),
    );
    if (_baked != null && _bakedFor == target) return;
    _baked?.dispose();
    _baked = _bake(source, target);
    _bakedFor = target;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _ensureBaked(constraints.biggest);
        final baked = _baked;
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            const _FallbackGradient(),
            if (baked != null)
              Positioned.fill(
                child: RepaintBoundary(
                  child: CustomPaint(painter: _BakedBackdropPainter(baked)),
                ),
              )
            else if (widget.wallpaperPath.isNotEmpty)
              Positioned.fill(
                child: _FileWallpaper(path: widget.wallpaperPath),
              ),
            ColoredBox(color: Colors.black.withValues(alpha: widget.dim)),
            const _Vignette(),
          ],
        );
      },
    );
  }

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

  /// 把两层模糊 + 泛光合成到一张小图上（只在壁纸或屏幕尺寸变化时执行）。
  static ui.Image _bake(ui.Image source, Size target) {
    final w = target.width.toInt();
    final h = target.height.toInt();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final dst = Rect.fromLTWH(0, 0, target.width, target.height);
    final src = _srcCover(
      Size(source.width.toDouble(), source.height.toDouble()),
      target,
    );

    // 主层：中等模糊 + 提升饱和度
    canvas.saveLayer(
      dst,
      Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: 11,
          sigmaY: 11,
          tileMode: TileMode.decal,
        )
        ..colorFilter = ColorFilter.matrix(_saturationMatrix(1.45)),
    );
    canvas.drawImageRect(
      source,
      src,
      dst,
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();

    // 泛光层：重度模糊 + 加色混合
    canvas.saveLayer(
      dst,
      Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: 30,
          sigmaY: 30,
          tileMode: TileMode.decal,
        )
        ..colorFilter = ColorFilter.matrix(_saturationMatrix(2.1))
        ..color = const Color.fromRGBO(0, 0, 0, 0.5)
        ..blendMode = BlendMode.plus,
    );
    canvas.drawImageRect(
      source,
      src,
      dst,
      Paint()..filterQuality = FilterQuality.low,
    );
    canvas.restore();

    final picture = recorder.endRecording();
    final image = picture.toImageSync(w, h);
    picture.dispose();
    return image;
  }
}

class _BakedBackdropPainter extends CustomPainter {
  const _BakedBackdropPainter(this.image);

  final ui.Image image;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_BakedBackdropPainter oldDelegate) =>
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
