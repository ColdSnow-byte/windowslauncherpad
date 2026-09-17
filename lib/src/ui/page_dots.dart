import 'package:flutter/material.dart';

/// 底部的翻页指示点，样式对齐 macOS 启动台。
class PageDots extends StatelessWidget {
  const PageDots({
    super.key,
    required this.count,
    required this.current,
    required this.onSelect,
  });

  final int count;
  final int current;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    if (count <= 1) return const SizedBox(height: 34);
    return SizedBox(
      height: 34,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List<Widget>.generate(count, (i) {
          final selected = i == current;
          return MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => onSelect(i),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 10),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  width: selected ? 9 : 7,
                  height: selected ? 9 : 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: selected ? 0.95 : 0.38),
                    boxShadow: selected
                        ? <BoxShadow>[
                            BoxShadow(
                              color: Colors.white.withValues(alpha: 0.5),
                              blurRadius: 8,
                            ),
                          ]
                        : null,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
