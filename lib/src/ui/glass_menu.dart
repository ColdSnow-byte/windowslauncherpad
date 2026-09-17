import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// 右键菜单中的一项。
class GlassMenuEntry {
  const GlassMenuEntry({
    required this.label,
    required this.onSelected,
    this.icon,
    this.destructive = false,
    this.isDivider = false,
  });

  const GlassMenuEntry.divider()
      : label = '',
        onSelected = _noop,
        icon = null,
        destructive = false,
        isDivider = true;

  final String label;
  final IconData? icon;
  final VoidCallback onSelected;
  final bool destructive;
  final bool isDivider;

  static void _noop() {}
}

/// 跟随鼠标位置弹出的玻璃右键菜单。
class GlassContextMenu extends StatelessWidget {
  const GlassContextMenu({
    super.key,
    required this.position,
    required this.entries,
    required this.onDismiss,
    this.width = 232,
  });

  final Offset position;
  final List<GlassMenuEntry> entries;
  final VoidCallback onDismiss;
  final double width;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final height = entries.fold<double>(12, (sum, e) => sum + (e.isDivider ? 9 : 38));
    final left = (position.dx).clamp(8.0, (size.width - width - 8).clamp(8.0, double.infinity));
    final top = (position.dy).clamp(8.0, (size.height - height - 8).clamp(8.0, double.infinity));

    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismiss,
            onSecondaryTap: onDismiss,
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          left: left,
          top: top,
          width: width,
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: 1),
            duration: const Duration(milliseconds: 170),
            curve: Curves.easeOutBack,
            builder: (context, t, child) => Transform.scale(
              scale: 0.88 + 0.12 * t,
              alignment: Alignment.topLeft,
              child: Opacity(opacity: t.clamp(0.0, 1.0), child: child),
            ),
            child: AdaptiveGlass(
              shape: const LiquidRoundedSuperellipse(borderRadius: 16),
              // 降级：菜单是小面积浮层，minimal 档已经足够
              quality: GlassQuality.minimal,
              settings: const LiquidGlassSettings(
                blur: 12,
                thickness: 16,
                glassColor: Color(0x3DFFFFFF),
                saturation: 1.2,
                lightIntensity: 0.35,
                whitenStrength: 0.12,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (final e in entries)
                      if (e.isDivider)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          child: Container(
                            height: 1,
                            color: Colors.white.withValues(alpha: 0.18),
                          ),
                        )
                      else
                        _MenuRow(entry: e, onDismiss: onDismiss),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MenuRow extends StatefulWidget {
  const _MenuRow({required this.entry, required this.onDismiss});

  final GlassMenuEntry entry;
  final VoidCallback onDismiss;

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final color = e.destructive
        ? const Color(0xFFFF8A8A)
        : Colors.white.withValues(alpha: 0.95);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          widget.onDismiss();
          e.onSelected();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 38,
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: _hovered
                ? Colors.white.withValues(alpha: 0.2)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            children: <Widget>[
              if (e.icon != null) ...<Widget>[
                Icon(e.icon, size: 16, color: color),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  e.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13.5, color: color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
