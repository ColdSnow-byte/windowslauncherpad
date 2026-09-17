import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:windowslauncherpad/src/model/launcher_item.dart';
import 'package:windowslauncherpad/src/state/icon_repository.dart';
import 'package:windowslauncherpad/src/ui/app_icon_visual.dart';

/// 入场曲线：快速逼近目标，收尾阶段叠加几次衰减振荡，形成「回弹」手感。
class SettleCurve extends Curve {
  const SettleCurve({this.amplitude = 0.16, this.bounces = 3});

  final double amplitude;
  final int bounces;

  @override
  double transform(double t) {
    final clamped = t.clamp(0.0, 1.0);
    final base = Curves.easeOutCubic.transform(clamped);
    const start = 0.52;
    if (clamped <= start) return base;
    final u = (clamped - start) / (1 - start);
    final decay = (1 - u) * (1 - u);
    final osc = math.sin(u * math.pi * 2 * bounces) * amplitude * decay;
    return base + osc;
  }
}

/// 网格几何信息。
class GridLayout {
  const GridLayout({
    required this.columns,
    required this.rows,
    required this.cellWidth,
    required this.cellHeight,
    required this.iconSize,
    required this.top,
    required this.pageWidth,
  });

  final int columns;
  final int rows;
  final double cellWidth;
  final double cellHeight;
  final double iconSize;
  final double top;
  final double pageWidth;

  int get perPage => math.max(1, columns * rows);

  /// 计算某个序号所在的页 / 行 / 列。
  (int page, int row, int col) slotOf(int index) {
    final page = index ~/ perPage;
    final slot = index % perPage;
    return (page, slot ~/ columns, slot % columns);
  }
}

/// 搜索时被过滤掉、正在淡出的项（保留其旧位置，避免跳动）。
class GhostEntry {
  const GhostEntry({
    required this.item,
    required this.page,
    required this.row,
    required this.col,
  });

  final LauncherItem item;
  final int page;
  final int row;
  final int col;
}

/// 网格的交互状态（由外层持有并传入）。
class GridInteraction {
  const GridInteraction({
    required this.hoveredRef,
    required this.draggingRef,
    required this.mergeTargetRef,
    required this.jiggle,
    required this.jiggleAnimation,
  });

  final String? hoveredRef;
  final String? draggingRef;
  final String? mergeTargetRef;
  final bool jiggle;
  final Animation<double>? jiggleAnimation;
}

/// 网格向外抛出的回调。
class GridCallbacks {
  const GridCallbacks({
    required this.onHover,
    required this.onActivate,
    required this.onContextMenu,
    required this.onDragStarted,
    required this.onDragUpdate,
    required this.onDragEnded,
    required this.onTargetEnter,
    required this.onTargetMove,
    required this.onTargetLeave,
    required this.onDropped,
  });

  final void Function(String? ref) onHover;
  final void Function(LauncherItem item) onActivate;
  final void Function(LauncherItem item, Offset globalPosition) onContextMenu;
  final void Function(String ref) onDragStarted;
  final void Function(String ref, Offset globalPosition) onDragUpdate;
  final void Function(String ref) onDragEnded;
  final void Function(String dragRef, String targetRef) onTargetEnter;
  final void Function(String targetRef, Offset globalPosition) onTargetMove;
  final void Function(String targetRef) onTargetLeave;
  final void Function(String dragRef, String targetRef) onDropped;
}

/// 启动台网格：一个扁平的 Stack，所有页共处同一坐标平面，
/// 用整体平移实现翻页，用 [AnimatedPositioned] 实现搜索时图标「飞向新位置」。
class LaunchpadGrid extends StatelessWidget {
  const LaunchpadGrid({
    super.key,
    required this.items,
    required this.ghosts,
    required this.layout,
    required this.icons,
    required this.interaction,
    required this.callbacks,
    required this.intro,
    required this.renderedPages,
  });

  final List<LauncherItem> items;
  final List<GhostEntry> ghosts;
  final GridLayout layout;
  final IconRepository icons;
  final GridInteraction interaction;
  final GridCallbacks callbacks;
  final Animation<double> intro;

  /// 需要渲染的页索引集合（通常为当前页 ±1）。
  final Set<int> renderedPages;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];

    // 以网格中心为锚点：每个格子记录它相对中心的方向与归一化距离，
    // 入场时沿该方向从画面外「飞入」，距离越远出发越晚，形成向中心汇聚的观感。
    final centerX = (layout.columns - 1) / 2 * layout.cellWidth;
    final centerY = (layout.rows - 1) / 2 * layout.cellHeight;
    final radius = math.max(1.0, math.sqrt(centerX * centerX + centerY * centerY));

    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final (page, row, col) = layout.slotOf(i);
      if (!renderedPages.contains(page)) continue;

      final tx = col * layout.cellWidth - centerX;
      final ty = row * layout.cellHeight - centerY;
      final len = math.max(1.0, math.sqrt(tx * tx + ty * ty));
      // 起点：沿径向推到画面外
      final flyFrom = Offset(
        tx / len * 360 + tx * 0.45,
        ty / len * 360 + ty * 0.45,
      );
      // 归一化距离：0 = 正中心，1 = 最外圈
      final dist01 = (len / radius).clamp(0.0, 1.0);

      children.add(
        AnimatedPositioned(
          key: ValueKey<String>('item:${item.ref}'),
          duration: const Duration(milliseconds: 380),
          curve: Curves.easeOutCubic,
          left: page * layout.pageWidth + col * layout.cellWidth,
          top: layout.top + row * layout.cellHeight,
          width: layout.cellWidth,
          height: layout.cellHeight,
          child: LaunchpadTile(
            item: item,
            assets: _assetsFor(item),
            layout: layout,
            interaction: interaction,
            callbacks: callbacks,
            intro: intro,
            staggerIndex: i,
            flyFrom: flyFrom,
            dist01: dist01,
          ),
        ),
      );
    }

    // 搜索结果被过滤掉的项：短暂保留在原位并淡出，避免「啪」地消失。
    for (final ghost in ghosts) {
      if (!renderedPages.contains(ghost.page)) continue;
      children.add(
        AnimatedPositioned(
          key: ValueKey<String>('ghost:${ghost.item.ref}'),
          duration: const Duration(milliseconds: 380),
          curve: Curves.easeOutCubic,
          left: ghost.page * layout.pageWidth + ghost.col * layout.cellWidth,
          top: layout.top + ghost.row * layout.cellHeight,
          width: layout.cellWidth,
          height: layout.cellHeight,
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 1, end: 0),
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOut,
            builder: (context, t, child) => Opacity(
              opacity: t,
              child: Transform.scale(scale: 0.6 + 0.4 * t, child: child),
            ),
            child: LaunchpadTile(
              item: ghost.item,
              assets: _assetsFor(ghost.item),
              layout: layout,
              interaction: const GridInteraction(
                hoveredRef: null,
                draggingRef: null,
                mergeTargetRef: null,
                jiggle: false,
                jiggleAnimation: null,
              ),
              callbacks: callbacks,
              intro: intro,
              staggerIndex: 0,
              inert: true,
            ),
          ),
        ),
      );
    }

    return Stack(clipBehavior: Clip.none, children: children);
  }

  /// 读取图标；缺失时就地补一次请求（幂等），保证任何被渲染的格子最终都会有图标。
  List<IconAsset?> _assetsFor(LauncherItem item) {
    if (item.isFolder) {
      return item.children.map((a) => _assetOf(a.id)).toList();
    }
    return <IconAsset?>[_assetOf(item.app!.id)];
  }

  IconAsset? _assetOf(String appId) {
    final asset = icons.peek(appId);
    if (asset == null) icons.request(appId, (_) {});
    return asset;
  }
}

/// 单个图标磁贴：悬停放大、彩色柔光增强、长按拖拽、右键菜单、抖动编辑。
class LaunchpadTile extends StatefulWidget {
  const LaunchpadTile({
    super.key,
    required this.item,
    required this.assets,
    required this.layout,
    required this.interaction,
    required this.callbacks,
    required this.intro,
    required this.staggerIndex,
    this.flyFrom = Offset.zero,
    this.dist01 = 0,
    this.inert = false,
  });

  /// 入场起点相对终点的位移（沿网格中心径向朝外）。
  final Offset flyFrom;

  /// 距网格中心的归一化距离（0 = 中心，1 = 最外圈），用于错峰。
  final double dist01;

  final LauncherItem item;
  final List<IconAsset?> assets;
  final GridLayout layout;
  final GridInteraction interaction;
  final GridCallbacks callbacks;
  final Animation<double> intro;
  final int staggerIndex;

  /// 淡出中的幽灵项，不响应交互。
  final bool inert;

  @override
  State<LaunchpadTile> createState() => _LaunchpadTileState();
}

class _LaunchpadTileState extends State<LaunchpadTile> {
  bool _hovered = false;

  bool get _isDragging => widget.interaction.draggingRef == widget.item.ref;
  bool get _isMergeTarget =>
      widget.interaction.mergeTargetRef == widget.item.ref;
  bool get _isActiveHover => _hovered && !_isDragging;

  static const Curve _settle = SettleCurve();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.intro,
      builder: (context, child) {
        // 外圈晚一点出发，形成向中心汇聚的层次感
        final delay = widget.dist01 * 0.22;
        final t = ((widget.intro.value - delay) / (1 - delay)).clamp(0.0, 1.0);

        // 带衰减振荡的收尾 -> 「回弹几下」
        final settle = _settle.transform(t);
        final fade = Curves.easeOut.transform((t * 1.8).clamp(0.0, 1.0));
        final remaining = 1 - settle;

        return Opacity(
          opacity: fade,
          child: Transform.translate(
            offset: widget.flyFrom * remaining,
            child: Transform.scale(
              // 起点更大，像是从镜头前方落回原位
              scale: 1 + 0.85 * remaining * remaining,
              child: child,
            ),
          ),
        );
      },
      child: _buildTileBody(context),
    );
  }

  Widget _buildTileBody(BuildContext context) {
    final layout = widget.layout;
    final item = widget.item;

    final baseGlow = _isMergeTarget ? 2.0 : (_isActiveHover ? 1.7 : 1.0);
    final scale = _isMergeTarget ? 1.16 : (_isActiveHover ? 1.13 : 1.0);

    Widget icon = item.isFolder
        ? FolderPreview(
            assets: widget.assets,
            size: layout.iconSize,
            glowStrength: baseGlow,
          )
        : AppIconVisual(
            asset: widget.assets.isEmpty ? null : widget.assets.first,
            size: layout.iconSize,
            glowStrength: baseGlow,
            fallbackLabel: item.name,
          );

    icon = AnimatedScale(
      scale: scale,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutBack,
      child: icon,
    );

    if (_isMergeTarget) {
      icon = Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: layout.iconSize * 1.22,
            height: layout.iconSize * 1.22,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.14),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.55),
                width: 1.5,
              ),
            ),
          ),
          icon,
        ],
      );
    }

    Widget label = Text(
      item.name,
      maxLines: 2,
      textAlign: TextAlign.center,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: (layout.iconSize * 0.135).clamp(11.0, 17.0),
        height: 1.15,
        decoration: TextDecoration.none,
        color: Colors.white.withValues(alpha: _isActiveHover ? 1.0 : 0.92),
        fontWeight: FontWeight.w500,
        shadows: const <Shadow>[
          Shadow(color: Color(0xB3000000), blurRadius: 7, offset: Offset(0, 1)),
        ],
      ),
    );

    if (_isActiveHover && !widget.interaction.jiggle) {
      label = Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(7),
        ),
        child: label,
      );
    }

    Widget body = Padding(
      padding: EdgeInsets.symmetric(horizontal: layout.cellWidth * 0.04),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          icon,
          SizedBox(height: layout.iconSize * 0.1),
          label,
        ],
      ),
    );

    if (_isDragging) {
      body = Opacity(opacity: 0.22, child: body);
    }

    // 抖动编辑模式：图标与文字一起轻微摇摆
    final jiggleAnim = widget.interaction.jiggleAnimation;
    if (widget.interaction.jiggle && jiggleAnim != null) {
      final phase = (fnv1a64(item.ref).hashCode % 1000) / 1000.0 * math.pi * 2;
      body = AnimatedBuilder(
        animation: jiggleAnim,
        builder: (context, child) => Transform.rotate(
          angle: 0.026 * math.sin(jiggleAnim.value * math.pi * 2 + phase),
          child: child,
        ),
        child: body,
      );
    }

    if (widget.inert) return IgnorePointer(child: body);

    return _wrapDragAndDrop(body);
  }

  Widget _wrapDragAndDrop(Widget body) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        setState(() => _hovered = true);
        widget.callbacks.onHover(widget.item.ref);
      },
      onExit: (_) {
        setState(() => _hovered = false);
        widget.callbacks.onHover(null);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.callbacks.onActivate(widget.item),
        onSecondaryTapDown: (details) =>
            widget.callbacks.onContextMenu(widget.item, details.globalPosition),
        child: DragTarget<String>(
          onWillAcceptWithDetails: (details) {
            if (details.data == widget.item.ref) return false;
            widget.callbacks.onTargetEnter(details.data, widget.item.ref);
            return true;
          },
          onMove: (details) =>
              widget.callbacks.onTargetMove(widget.item.ref, details.offset),
          onLeave: (_) => widget.callbacks.onTargetLeave(widget.item.ref),
          onAcceptWithDetails: (details) =>
              widget.callbacks.onDropped(details.data, widget.item.ref),
          builder: (context, candidate, rejected) {
            return LongPressDraggable<String>(
              data: widget.item.ref,
              delay: const Duration(milliseconds: 420),
              dragAnchorStrategy: pointerDragAnchorStrategy,
              maxSimultaneousDrags: 1,
              onDragStarted: () => widget.callbacks.onDragStarted(widget.item.ref),
              onDragUpdate: (details) =>
                  widget.callbacks.onDragUpdate(widget.item.ref, details.globalPosition),
              onDragEnd: (_) => widget.callbacks.onDragEnded(widget.item.ref),
              onDraggableCanceled: (_, _) =>
                  widget.callbacks.onDragEnded(widget.item.ref),
              feedback: _DragFeedback(item: widget.item, assets: widget.assets, layout: widget.layout),
              childWhenDragging: Opacity(opacity: 0.001, child: body),
              child: body,
            );
          },
        ),
      ),
    );
  }
}

/// 拖拽时跟随指针的浮起图标。
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({
    required this.item,
    required this.assets,
    required this.layout,
  });

  final LauncherItem item;
  final List<IconAsset?> assets;
  final GridLayout layout;

  @override
  Widget build(BuildContext context) {
    final size = layout.iconSize * 1.14;
    return Material(
      type: MaterialType.transparency,
      child: Transform.translate(
        offset: Offset(-size / 2, -size * 0.62),
        child: SizedBox(
          width: size * 1.4,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Transform.scale(
                scale: 1.04,
                child: item.isFolder
                    ? FolderPreview(assets: assets, size: size, glowStrength: 2.2)
                    : AppIconVisual(
                        asset: assets.isEmpty ? null : assets.first,
                        size: size,
                        glowStrength: 2.2,
                        fallbackLabel: item.name,
                      ),
              ),
              const SizedBox(height: 8),
              Text(
                item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  shadows: <Shadow>[
                    Shadow(color: Color(0xB3000000), blurRadius: 8),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
