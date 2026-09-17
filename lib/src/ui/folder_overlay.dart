import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:windowslauncherpad/src/model/launcher_item.dart';
import 'package:windowslauncherpad/src/rust/api/launcher.dart';
import 'package:windowslauncherpad/src/state/icon_repository.dart';
import 'package:windowslauncherpad/src/ui/app_icon_visual.dart';

/// 文件夹展开浮层。
///
/// 面板本身尺寸保持不变，仅用 [Transform] 从图标位置缩放展开，
/// 这样玻璃表面的模糊层在动画过程中不会闪烁。
class FolderOverlay extends StatefulWidget {
  const FolderOverlay({
    super.key,
    required this.folder,
    required this.origin,
    required this.icons,
    required this.onLaunch,
    required this.onRemoveFromFolder,
    required this.onRename,
    required this.onClose,
  });

  final LauncherItem folder;

  /// 文件夹图标在屏幕上的矩形（动画起点）。
  final Rect origin;
  final IconRepository icons;
  final void Function(AppEntry app) onLaunch;
  final void Function(String appId) onRemoveFromFolder;
  final void Function(String name) onRename;
  final VoidCallback onClose;

  static const Duration duration = Duration(milliseconds: 320);

  @override
  State<FolderOverlay> createState() => _FolderOverlayState();
}

class _FolderOverlayState extends State<FolderOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: FolderOverlay.duration,
  );
  late final TextEditingController _name = TextEditingController(
    text: widget.folder.name,
  );

  bool _draggingOut = false;

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    await _controller.reverse();
    if (mounted) widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final panelWidth = (screen.width * 0.62).clamp(520.0, 1180.0);
    final panelHeight = (screen.height * 0.66).clamp(360.0, 780.0);
    final target = Rect.fromCenter(
      center: Offset(screen.width / 2, screen.height / 2),
      width: panelWidth,
      height: panelHeight,
    );

    final originCenter = widget.origin.center;
    final localOrigin = originCenter - target.topLeft;
    final startScale = (widget.origin.width / panelWidth).clamp(0.04, 1.0);

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_controller.value);
        final scale = ui.lerpDouble(startScale, 1.0, t)!;
        final contentT =
            ((_controller.value - 0.42) / 0.58).clamp(0.0, 1.0);

        return Stack(
          children: <Widget>[
            // 背景压暗（可点击关闭）
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _close,
                onSecondaryTap: _close,
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.45 * t),
                ),
              ),
            ),
            Positioned.fromRect(
              rect: target,
              child: Transform(
                transform: _scaleAbout(localOrigin, scale),
                child: Opacity(
                  opacity: (t * 1.4).clamp(0.0, 1.0),
                  child: _buildPanel(context, contentT),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildPanel(BuildContext context, double contentT) {
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) {
        setState(() => _draggingOut = true);
        return true;
      },
      onLeave: (_) => setState(() => _draggingOut = false),
      onAcceptWithDetails: (details) {
        setState(() => _draggingOut = false);
        // 从文件夹里拖到面板外部 → 移出文件夹
        widget.onRemoveFromFolder(details.data);
        if (mounted) _close();
      },
      builder: (context, candidate, rejected) {
        return AdaptiveGlass(
          shape: const LiquidRoundedSuperellipse(borderRadius: 34),
          settings: LiquidGlassSettings(
            blur: 30,
            thickness: 30,
            glassColor: Colors.white.withValues(alpha: _draggingOut ? 0.16 : 0.09),
            saturation: 1.35,
            lightIntensity: 0.5,
            whitenStrength: 0.1,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(30, 22, 30, 26),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _buildTitle(contentT),
                const SizedBox(height: 10),
                Expanded(
                  child: Opacity(
                    opacity: contentT,
                    child: _buildAppsGrid(context),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTitle(double contentT) {
    return Opacity(
      opacity: contentT,
      child: Center(
        child: IntrinsicWidth(
          child: TextField(
            controller: _name,
            textAlign: TextAlign.center,
            cursorColor: Colors.white,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: Colors.white,
              shadows: <Shadow>[
                Shadow(color: Color(0x80000000), blurRadius: 6),
              ],
            ),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 6,
              ),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.001),
            ),
            onSubmitted: (value) {
              widget.onRename(value);
              FocusManager.instance.primaryFocus?.unfocus();
            },
          ),
        ),
      ),
    );
  }

  Widget _buildAppsGrid(BuildContext context) {
    final apps = widget.folder.children;
    return GridView.builder(
      padding: const EdgeInsets.symmetric(vertical: 6),
      physics: const BouncingScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        childAspectRatio: 0.92,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
      ),
      itemCount: apps.length,
      itemBuilder: (context, index) {
        final app = apps[index];
        return _FolderAppTile(
          app: app,
          asset: widget.icons.peek(app.id),
          onLaunch: () => widget.onLaunch(app),
        );
      },
    );
  }
}

/// 在 [origin] 处按 [scale] 缩放（以该点为不动点）。
Matrix4 _scaleAbout(Offset origin, double scale) => Matrix4.identity()
  ..setEntry(0, 0, scale)
  ..setEntry(1, 1, scale)
  ..setEntry(0, 3, origin.dx * (1 - scale))
  ..setEntry(1, 3, origin.dy * (1 - scale));

class _FolderAppTile extends StatefulWidget {
  const _FolderAppTile({
    required this.app,
    required this.asset,
    required this.onLaunch,
  });

  final AppEntry app;
  final IconAsset? asset;
  final VoidCallback onLaunch;

  @override
  State<_FolderAppTile> createState() => _FolderAppTileState();
}

class _FolderAppTileState extends State<_FolderAppTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tile = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AnimatedScale(
          scale: _hovered ? 1.12 : 1.0,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutBack,
          child: AppIconVisual(
            asset: widget.asset,
            size: 76,
            glowStrength: _hovered ? 1.7 : 1.0,
            fallbackLabel: widget.app.name,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          widget.app.name,
          maxLines: 2,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12.5,
            color: Colors.white.withValues(alpha: _hovered ? 1 : 0.9),
            shadows: const <Shadow>[
              Shadow(color: Color(0x99000000), blurRadius: 5),
            ],
          ),
        ),
      ],
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onLaunch,
        child: LongPressDraggable<String>(
          data: widget.app.id,
          delay: const Duration(milliseconds: 360),
          dragAnchorStrategy: pointerDragAnchorStrategy,
          feedback: Material(
            type: MaterialType.transparency,
            child: AppIconVisual(
              asset: widget.asset,
              size: 88,
              glowStrength: 2.2,
              fallbackLabel: widget.app.name,
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.2, child: tile),
          child: tile,
        ),
      ),
    );
  }
}
