import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:windowslauncherpad/src/model/source_config.dart';
import 'package:windowslauncherpad/src/settings/settings_app.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:windowslauncherpad/src/model/launcher_item.dart';
import 'package:windowslauncherpad/src/native/win_api.dart';
import 'package:windowslauncherpad/src/rust/api/launcher.dart';
import 'package:windowslauncherpad/src/state/launcher_controller.dart';
import 'package:windowslauncherpad/src/ui/cursor_glow.dart';
import 'package:windowslauncherpad/src/ui/folder_overlay.dart';
import 'package:windowslauncherpad/src/ui/glass_menu.dart';
import 'package:windowslauncherpad/src/ui/launchpad_grid.dart';
import 'package:windowslauncherpad/src/ui/page_dots.dart';
import 'package:windowslauncherpad/src/ui/wallpaper_backdrop.dart';

/// 一次右键菜单请求。
class _MenuRequest {
  const _MenuRequest(this.item, this.position);

  /// 为 null 表示在空白处右键（弹出全局菜单）。
  final LauncherItem? item;
  final Offset position;
}

/// macOS 风格启动台主界面。
class LaunchpadScreen extends StatefulWidget {
  const LaunchpadScreen({
    super.key,
    required this.controller,
    required this.dataDir,
    required this.wallpaperPath,
    required this.wallpaperImage,
    this.onHidden,
  });

  final LauncherController controller;

  /// 数据目录（与设置窗口共享 `sources.json`）。
  final String dataDir;
  final String wallpaperPath;
  final ui.Image? wallpaperImage;

  /// 窗口被隐藏时回调（用于重置入场动画，让下次呼出重新播放飞入效果）。
  final VoidCallback? onHidden;

  @override
  State<LaunchpadScreen> createState() => _LaunchpadScreenState();
}

class _LaunchpadScreenState extends State<LaunchpadScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  LauncherController get _c => widget.controller;

  // ── 动画 ──────────────────────────────────────────────────────────────────
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1050),
  );
  late final AnimationController _jiggle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  late final AnimationController _pager = AnimationController.unbounded(
    vsync: this,
  );
  late final AnimationController _exit = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  // ── 交互状态 ──────────────────────────────────────────────────────────────
  final TextEditingController _searchText = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'launchpad-search');
  final GlobalKey _viewportKey = GlobalKey();

  String? _hoveredRef;
  String? _dragRef;
  String? _mergeArmedRef;
  String? _mergeCandidateRef;
  Timer? _mergeTimer;
  Timer? _edgeTimer;
  int _edgeDirection = 0;
  Offset? _lastDragPos;
  String _lastEnterKey = '';

  bool _jiggleMode = false;
  int _pageIndex = 0;

  /// 图标来源配置（自动扫描 / 手动添加）。
  SourceConfig _source = const SourceConfig();

  /// 设置页是否展开（在主窗口内承载）。
  bool _settingsOpen = false;
  Timer? _commandTimer;

  /// 当前该展示的顶层格子。
  List<LauncherItem> get _activeItems {
    if (_source.mode == IconSourceMode.manual) {
      return _source.custom
          .map((e) => LauncherItem.custom(id: e.id, name: e.name))
          .toList(growable: false);
    }
    return _c.visibleItems;
  }

  /// 在当前来源模式下做搜索。
  List<LauncherItem> get _searchResults {
    final query = _c.query.trim().toLowerCase();
    if (query.isEmpty) return const <LauncherItem>[];
    final result = <LauncherItem>[];
    for (final item in _activeItems) {
      if (item.isFolder) {
        if (item.name.toLowerCase().contains(query)) {
          result.add(item);
        } else {
          for (final child in item.children) {
            if (child.name.toLowerCase().contains(query)) {
              result.add(LauncherItem.app(child));
            }
          }
        }
      } else if (item.name.toLowerCase().contains(query)) {
        result.add(item);
      }
    }
    return result;
  }

  /// 当前实际渲染的格子（搜索时是结果，否则是全部）。
  List<LauncherItem> get _displayItems =>
      _c.isSearching ? _searchResults : _activeItems;

  _MenuRequest? _menu;
  LauncherItem? _openFolder;
  Rect? _folderOrigin;

  // 搜索过滤时用来淡出的「幽灵项」
  List<GhostEntry> _ghosts = const <GhostEntry>[];
  List<LauncherItem> _prevItems = const <LauncherItem>[];
  GridLayout? _prevLayout;
  Timer? _ghostTimer;
  Timer? _summonTimer;

  GridLayout? _layout;
  double _viewportWidth = 0;
  double _viewportHeight = 0;

  static const double _sidePadding = 78;
  static const double _topArea = 122;
  static const double _bottomArea = 96;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onControllerChanged);
    // 图标是异步逐个就绪的，就绪后需要重绘网格。
    _c.icons.revision.addListener(_onIconsReady);
    _pager.addListener(_onPagerTick);
    _searchText.addListener(_onSearchChanged);
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_globalKeyHandler);

    // 首帧就开始飞入，避免先渲染一帧静止的图标
    _intro.forward();
    _c.preloadIcons();
    unawaited(_loadSource());
    _startCommandWatch();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从后台（托盘/热键）重新呼出窗口时重放飞入动画
    if (state == AppLifecycleState.resumed) replayIntro();
  }

  /// 重新播放入场动画：图标再次从四周飞入并回弹。
  void replayIntro() {
    if (!mounted) return;

    _exit.value = 0;
    _intro.value = 0;
    _gotoPage(0);
    _intro.forward();
    // 重新呼出后把焦点交还搜索框，直接打字即可搜索
    _searchFocus.requestFocus();
    // 设置窗口可能刚改过图标来源，重新读一次配置
    unawaited(_loadSource());
  }

  void _onIconsReady() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_globalKeyHandler);
    WidgetsBinding.instance.removeObserver(this);
    _c.removeListener(_onControllerChanged);
    _c.icons.revision.removeListener(_onIconsReady);
    _pager.dispose();
    _intro.dispose();
    _jiggle.dispose();
    _exit.dispose();
    _searchText.dispose();
    _searchFocus.dispose();
    _mergeTimer?.cancel();
    _edgeTimer?.cancel();
    _ghostTimer?.cancel();
    _summonTimer?.cancel();
    _wheelCooldown?.cancel();
    _commandTimer?.cancel();
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadSource() async {
    final config = await SourceConfigStore.load(widget.dataDir);
    if (!mounted) return;
    setState(() => _source = config);
  }

  /// 托盘「设置…」→ 收起启动台并打开（或复用）设置窗口。
  /// 打开设置页。
  ///
  /// 这里刻意不再另开子窗口：`desktop_multi_window` 的子引擎不注册任何插件，
  /// 导致 `desktop_drop` 的原生拖放目标根本不会创建，桌面拖入必然失效。
  /// 改为在主窗口内承载，并把窗口切回普通窗口形态，观感上仍是一个设置窗口。
  Future<void> _openSettings() async {
    await WinApi.setWindowed(1120, 760);
    if (!mounted) return;
    setState(() => _settingsOpen = true);
  }

  Future<void> _closeSettings() async {
    if (!mounted) return;
    setState(() => _settingsOpen = false);
    await WinApi.setFullscreen(true);
    replayIntro();
  }

  void _startCommandWatch() {
    _commandTimer?.cancel();
    _commandTimer = Timer.periodic(const Duration(milliseconds: 350), (
      timer,
    ) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (await WinApi.takeSettingsRequest()) {
        await _openSettings();
      }
    });
  }

  void _onSearchChanged() {
    _c.setQuery(_searchText.text);
    if (mounted) setState(() {});
  }

  void _onPagerTick() {
    final pageW = _pageWidth;
    if (pageW <= 0) return;
    final page = (_pager.value / pageW)
        .round()
        .clamp(0, math.max(0, _pageCount - 1))
        .toInt();
    if (page != _pageIndex) setState(() => _pageIndex = page);
  }

  // ── 几何计算 ──────────────────────────────────────────────────────────────

  double get _pageWidth => _viewportWidth <= 0 ? 1 : _viewportWidth;

  int get _pageCount {
    final items = _displayItems;
    final perPage = _layout?.perPage ?? 1;
    return math.max(1, (items.length + perPage - 1) ~/ perPage);
  }

  // ── 滚轮翻页 ──────────────────────────────────────────────────────────────

  Timer? _wheelCooldown;

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final dy = event.scrollDelta.dy;
    final dx = event.scrollDelta.dx;
    // 文件夹/右键菜单打开、正在拖拽或正在播放入场动画时忽略滚轮
    if (_openFolder != null || _menu != null || _dragRef != null) return;

    final delta = dy.abs() >= dx.abs() ? dy : dx;
    if (delta.abs() < 1) return;

    // 冷却一下，避免一次快速滚动连跳好几页
    if (_wheelCooldown?.isActive ?? false) return;
    _wheelCooldown = Timer(const Duration(milliseconds: 220), () {});
    _gotoPage(_pageIndex + (delta > 0 ? 1 : -1));
  }

  // ── 翻页 ──────────────────────────────────────────────────────────────────

  void _settlePager(double velocity) {
    final pageW = _pageWidth;
    if (pageW <= 0) return;
    final maxPage = math.max(0, _pageCount - 1);
    final raw = (_pager.value / pageW).clamp(0.0, maxPage.toDouble());
    var target = raw.round();
    if (velocity.abs() > 320) {
      target = velocity > 0 ? raw.floor() : raw.ceil();
    }
    target = target.clamp(0, maxPage);
    _pager.animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 190, damping: 30),
        _pager.value,
        target * pageW,
        velocity,
      ),
    );
  }

  void _gotoPage(int page) {
    final pageW = _pageWidth;
    if (pageW <= 0) return;
    final target = page.clamp(0, math.max(0, _pageCount - 1));
    _pager.animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 190, damping: 30),
        _pager.value,
        target * pageW,
        0,
      ),
    );
  }

  // ── 键盘 ──────────────────────────────────────────────────────────────────

  /// 全局按键处理：不依赖焦点，保证 Esc 任何时候都生效。
  ///
  /// 注意：Windows 下可打印字符在有文本框持焦点时不会派发到这里，
  /// 所以这里只处理 Esc 这类功能键，不做字母快捷键。
  bool _globalKeyHandler(KeyEvent event) {
    if (event is! KeyDownEvent) return false;

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_menu != null) {
        setState(() => _menu = null);
      } else if (_openFolder != null) {
        setState(() => _openFolder = null);
      } else if (_c.isSearching) {
        _searchText.clear();
      } else if (_jiggleMode) {
        _exitJiggle();
      } else {
        // Esc：收起启动台，但保留托盘常驻
        unawaited(_dismiss());
      }
      return true;
    }

    return false;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      final results = _searchResults;
      if (_c.isSearching && results.isNotEmpty) {
        unawaited(_activate(results.first));
        return KeyEventResult.handled;
      }
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowRight &&
        _c.isSearching == false) {
      _gotoPage(_pageIndex + 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft &&
        _c.isSearching == false) {
      _gotoPage(_pageIndex - 1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ── 行为 ──────────────────────────────────────────────────────────────────

  /// 收起启动台：只隐藏窗口，进程常驻后台，下次呼出无需重新扫描。
  Future<void> _dismiss() async {
    await WinApi.hide();
    _exit.value = 0;
    // 复位入场进度：窗口隐藏期间网格保持完全不可见，
    // 这样重新呼出时不会先闪一帧「已就位」的图标再播动画。
    _intro.value = 0;
    widget.onHidden?.call();
    _watchForSummon();
  }

  /// 收起后轮询窗口可见性，一旦被托盘/热键重新呼出就重放飞入动画。
  void _watchForSummon() {
    _summonTimer?.cancel();
    _summonTimer = Timer.periodic(const Duration(milliseconds: 120), (
      timer,
    ) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final visible = await WinApi.isWindowVisible();
      if (visible && mounted) {
        timer.cancel();
        _summonTimer = null;
        replayIntro();
      }
    });
  }

  Future<void> _quit() async {
    await WinApi.setFullscreen(false);
    await WinApi.quit();
  }

  Future<void> _activate(LauncherItem item) async {
    if (item.isFolder) {
      setState(() {
        _openFolder = item;
        _folderOrigin = _tileRect(item);
      });
      return;
    }

    try {
      await _exit.forward();
    } catch (_) {}
    await WinApi.launchApp(item.launchId);
    // 启动后收起启动台，但保留进程以便下次秒开。
    await _dismiss();
    _exit.value = 0;
  }

  void _enterJiggle() {
    if (_jiggleMode) return;
    setState(() => _jiggleMode = true);
    _jiggle.repeat();
  }

  void _exitJiggle() {
    _mergeTimer?.cancel();
    _mergeArmedRef = null;
    _mergeCandidateRef = null;
    if (!_jiggleMode) return;
    _jiggle.stop();
    setState(() => _jiggleMode = false);
  }

  /// 计算某个格子当前在屏幕上的矩形（用于文件夹展开动画的起点）。
  Rect _tileRect(LauncherItem item) {
    final layout = _layout;
    final fallback = Rect.fromCenter(
      center: Offset(_viewportWidth / 2, _viewportHeight / 2),
      width: 120,
      height: 120,
    );
    if (layout == null) return fallback;

    final items = _displayItems;
    final index = items.indexWhere((e) => e.ref == item.ref);
    if (index < 0) return fallback;

    final (page, row, col) = layout.slotOf(index);
    final left =
        -_pager.value +
        _sidePadding +
        col * layout.cellWidth +
        (layout.cellWidth - layout.iconSize) / 2;
    // 网格位于搜索栏下方的 Expanded 内，换算回屏幕坐标需要加上顶部高度。
    final top =
        _topArea +
        layout.top +
        row * layout.cellHeight +
        (layout.cellHeight - layout.iconSize) / 2;
    return Rect.fromLTWH(left, top, layout.iconSize, layout.iconSize);
  }

  // ── 拖拽 ──────────────────────────────────────────────────────────────────

  void _onDragStarted(String ref) {
    _enterJiggle();
    setState(() {
      _dragRef = ref;
      _mergeArmedRef = null;
      _mergeCandidateRef = null;
      _lastEnterKey = '';
    });
  }

  void _onTargetEnter(String dragRef, String targetRef) {
    final key = '$dragRef>$targetRef';
    if (_lastEnterKey != key) {
      _lastEnterKey = key;
      // 实时重排，让图标跟着指针流动
      _c.reorder(dragRef, targetRef);
    }
    _armMergeTimer(targetRef);
  }

  void _onTargetMove(String targetRef, Offset globalPosition) {
    final last = _lastDragPos;
    if (last == null || (globalPosition - last).distance > 22) {
      _lastDragPos = globalPosition;
      _mergeArmedRef = null;
      _armMergeTimer(targetRef);
    }
  }

  void _armMergeTimer(String targetRef) {
    if (_mergeArmedRef == targetRef) return;
    _mergeCandidateRef = targetRef;
    _mergeTimer?.cancel();
    _mergeTimer = Timer(const Duration(milliseconds: 720), () {
      if (!mounted) return;
      if (_mergeCandidateRef != targetRef) return;
      setState(() => _mergeArmedRef = targetRef);
    });
  }

  void _onTargetLeave(String targetRef) {
    if (_mergeCandidateRef == targetRef) {
      _mergeCandidateRef = null;
      _mergeTimer?.cancel();
    }
  }

  void _onDropped(String dragRef, String targetRef) {
    if (_mergeArmedRef == targetRef && dragRef != targetRef) {
      _c.createFolder(dragRef, targetRef);
    }
    _finishDrag();
  }

  void _finishDrag() {
    _mergeTimer?.cancel();
    _edgeTimer?.cancel();
    _edgeDirection = 0;
    _mergeArmedRef = null;
    _mergeCandidateRef = null;
    _lastEnterKey = '';
    if (mounted) {
      setState(() => _dragRef = null);
    }
    // macOS 拖拽结束后会退出编辑模式
    _exitJiggle();
  }

  void _onDragUpdate(String ref, Offset globalPosition) {
    final edge = 130.0;
    var direction = 0;
    if (globalPosition.dx < edge) {
      direction = -1;
    } else if (globalPosition.dx > _pageWidth - edge) {
      direction = 1;
    }
    if (direction == 0) {
      _edgeTimer?.cancel();
      _edgeDirection = 0;
      return;
    }
    if (_edgeDirection == direction) return;
    _edgeDirection = direction;
    _edgeTimer?.cancel();
    // 停在屏幕边缘一会儿就翻页，方便跨页拖拽
    _edgeTimer = Timer(const Duration(milliseconds: 640), () {
      if (!mounted) return;
      _gotoPage(_pageIndex + direction);
      _edgeDirection = 0;
    });
  }

  /// 判断解析出的启动目标是否为真实文件路径。
  bool _looksLikePath(String target) {
    if (target.length < 3) return false;
    final drive = target[0].toUpperCase();
    return drive.codeUnitAt(0) >= 0x41 &&
        drive.codeUnitAt(0) <= 0x5A &&
        target[1] == ':';
  }

  // ── 右键菜单 ──────────────────────────────────────────────────────────────

  List<GlassMenuEntry> _menuEntries(LauncherItem? item) {
    if (item == null) {
      // 空白处右键：全局操作
      return <GlassMenuEntry>[
        GlassMenuEntry(
          label: '重新扫描应用',
          icon: Icons.refresh_rounded,
          onSelected: () => unawaited(_c.refresh()),
        ),
        GlassMenuEntry(
          label: '恢复已隐藏的应用',
          icon: Icons.restore_rounded,
          onSelected: _c.restoreHidden,
        ),
        GlassMenuEntry(
          label: '重置布局',
          icon: Icons.settings_backup_restore_rounded,
          onSelected: _c.resetLayout,
        ),
        const GlassMenuEntry.divider(),
        GlassMenuEntry(
          label: '退出启动台',
          icon: Icons.power_settings_new_rounded,
          destructive: true,
          onSelected: () => unawaited(_quit()),
        ),
      ];
    }
    if (item.isFolder) {
      return <GlassMenuEntry>[
        GlassMenuEntry(
          label: '打开文件夹',
          icon: Icons.folder_open_rounded,
          onSelected: () => _activate(item),
        ),
        GlassMenuEntry(
          label: '解散文件夹',
          icon: Icons.folder_off_rounded,
          onSelected: () => _c.dissolveFolder(item.folderId!),
        ),
        GlassMenuEntry(
          label: '重命名…',
          icon: Icons.edit_rounded,
          onSelected: () => _activate(item),
        ),
        const GlassMenuEntry.divider(),
        GlassMenuEntry(
          label: '从启动台移除',
          icon: Icons.visibility_off_rounded,
          destructive: true,
          onSelected: () => _c.hide(item.ref),
        ),
      ];
    }
    return <GlassMenuEntry>[
      GlassMenuEntry(
        label: '打开',
        icon: Icons.play_arrow_rounded,
        onSelected: () => _activate(item),
      ),
      if (item.app != null &&
          item.app!.kind == AppKind.win32 &&
          _looksLikePath(item.app!.target))
        GlassMenuEntry(
          label: '打开文件所在位置',
          icon: Icons.folder_open_rounded,
          onSelected: () => unawaited(WinApi.revealInExplorer(item.app!.id)),
        ),
      GlassMenuEntry(
        label: '从启动台移除',
        icon: Icons.visibility_off_rounded,
        onSelected: () => _c.hide(item.ref),
      ),
      const GlassMenuEntry.divider(),
      GlassMenuEntry(
        label: '重新扫描应用',
        icon: Icons.refresh_rounded,
        onSelected: () => unawaited(_c.refresh()),
      ),
      GlassMenuEntry(
        label: '恢复已隐藏的应用',
        icon: Icons.restore_rounded,
        onSelected: _c.restoreHidden,
      ),
      GlassMenuEntry(
        label: '重置布局',
        icon: Icons.settings_backup_restore_rounded,
        onSelected: _c.resetLayout,
      ),
    ];
  }

  // ── 构建 ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final items = _displayItems;

    return Focus(
      onKeyEvent: _onKey,
      child: AnimatedBuilder(
        animation: _exit,
        builder: (context, child) {
          final t = Curves.easeInCubic.transform(_exit.value);
          return Opacity(
            opacity: 1 - t,
            child: Transform.scale(scale: 1 + 0.05 * t, child: child),
          );
        },
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            WallpaperBackdrop(
              wallpaperPath: widget.wallpaperPath,
              wallpaperImage: widget.wallpaperImage,
              dim: _c.isSearching ? 0.3 : 0.22,
            ),
            LayoutBuilder(
              builder: (context, constraints) =>
                  _buildContent(context, constraints, items),
            ),
            if (_openFolder != null)
              FolderOverlay(
                key: ValueKey<String>('folder:${_openFolder!.folderId}'),
                folder: _openFolder!,
                origin:
                    _folderOrigin ??
                    Rect.fromCenter(
                      center: Offset(_viewportWidth / 2, _viewportHeight / 2),
                      width: 120,
                      height: 120,
                    ),
                icons: _c.icons,
                onLaunch: (app) => unawaited(_activate(LauncherItem.app(app))),
                onRemoveFromFolder: (appId) =>
                    _c.removeFromFolder(_openFolder!.folderId!, appId),
                onRename: (name) =>
                    _c.renameFolder(_openFolder!.folderId!, name),
                onClose: () => setState(() => _openFolder = null),
              ),
            if (_menu != null)
              GlassContextMenu(
                position: _menu!.position,
                entries: _menuEntries(_menu!.item),
                onDismiss: () => setState(() => _menu = null),
              ),
            // 鼠标白色柔光（最上层，纯加色，不拦截指针）
            if (_settingsOpen)
              Positioned.fill(
                child: ColoredBox(
                  color: const Color(0xFF161A20),
                  child: SettingsPage(
                    dataDir: widget.dataDir,
                    onDone: () => unawaited(_closeSettings()),
                  ),
                ),
              ),
            const Positioned.fill(
              // 半径收小：混合面积与半径平方成正比
              child: CursorGlowLayer(radius: 140, child: SizedBox.expand()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    BoxConstraints constraints,
    List<LauncherItem> items,
  ) {
    final size = Size(constraints.maxWidth, constraints.maxHeight);
    _viewportWidth = size.width;
    _viewportHeight = size.height;

    // ── 自适应网格 ──────────────────────────────────────────────────────────
    final usableW = math.max(240.0, size.width - _sidePadding * 2);
    final usableH = math.max(200.0, size.height - _topArea - _bottomArea);
    final columns = (usableW / 196).floor().clamp(4, 9);
    final rows = (usableH / 178).floor().clamp(2, 6);
    final cellWidth = usableW / columns;
    final cellHeight = usableH / rows;
    final iconSize = math
        .min(cellWidth * 0.66, cellHeight * 0.62)
        .clamp(56.0, 152.0);

    final layout = GridLayout(
      columns: columns,
      rows: rows,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      iconSize: iconSize,
      // 网格所在的 Expanded 已经从搜索栏下方开始，因此这里不再叠加顶部高度。
      top: 0,
      pageWidth: size.width,
    );
    _layout = layout;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _c.setGrid(columns: columns, rows: rows);
    });

    final pageCount = math.max(
      1,
      (items.length + layout.perPage - 1) ~/ layout.perPage,
    );
    _syncGhosts(items, layout);

    final currentPage = (_pager.value / _pageWidth).round().clamp(
      0,
      pageCount - 1,
    );
    final renderedPages = <int>{
      for (var p = currentPage - 1; p <= currentPage + 1; p++)
        if (p >= 0 && p < pageCount) p,
    };

    final grid = SizedBox(
      width: size.width * pageCount,
      height: size.height,
      child: LaunchpadGrid(
        items: items,
        ghosts: _ghosts,
        layout: layout,
        icons: _c.icons,
        interaction: GridInteraction(
          hoveredRef: _hoveredRef,
          draggingRef: _dragRef,
          mergeTargetRef: _mergeArmedRef,
          jiggle: _jiggleMode,
          jiggleAnimation: _jiggle,
        ),
        callbacks: GridCallbacks(
          onHover: (ref) => _hoveredRef = ref,
          onActivate: (item) => unawaited(_activate(item)),
          onContextMenu: (item, pos) =>
              setState(() => _menu = _MenuRequest(item, pos)),
          onDragStarted: _onDragStarted,
          onDragUpdate: _onDragUpdate,
          onDragEnded: (_) => _finishDrag(),
          onTargetEnter: _onTargetEnter,
          onTargetMove: _onTargetMove,
          onTargetLeave: _onTargetLeave,
          onDropped: _onDropped,
        ),
        intro: _intro,
        renderedPages: renderedPages,
      ),
    );

    // 点击空白处收起启动台（图标、搜索框、指示点等会先消费掉自己的点击事件）
    return Listener(
      onPointerSignal: _onPointerSignal,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (_jiggleMode) {
            _exitJiggle();
            return;
          }
          unawaited(_dismiss());
        },
        onSecondaryTapDown: (details) =>
            setState(() => _menu = _MenuRequest(null, details.globalPosition)),
        child: Column(
          children: <Widget>[
            SizedBox(height: _topArea, child: _buildTopBar(size)),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: (details) {
                  if (_dragRef != null) return;
                  _pager.stop();
                },
                onHorizontalDragUpdate: (details) {
                  if (_dragRef != null) return;
                  final max = (_pageCount - 1) * _pageWidth;
                  final next = _pager.value - details.delta.dx;
                  // 越界时用橡皮筋阻尼
                  if (next < 0) {
                    _pager.value = next * 0.35;
                  } else if (next > max) {
                    _pager.value = max + (next - max) * 0.35;
                  } else {
                    _pager.value = next;
                  }
                },
                onHorizontalDragEnd: (details) {
                  if (_dragRef != null) return;
                  final v = details.velocity.pixelsPerSecond.dx;
                  _pager.value = _pager.value.clamp(
                    0.0,
                    math.max(0.0, (_pageCount - 1) * _pageWidth),
                  );
                  _settlePager(-v);
                },
                child: ClipRect(
                  key: _viewportKey,
                  child: AnimatedBuilder(
                    animation: _pager,
                    builder: (context, child) => OverflowBox(
                      alignment: Alignment.topLeft,
                      minWidth: 0,
                      maxWidth: double.infinity,
                      minHeight: 0,
                      maxHeight: double.infinity,
                      child: Transform.translate(
                        offset: Offset(_sidePadding - _pager.value, 0),
                        child: child,
                      ),
                    ),
                    child: grid,
                  ),
                ),
              ),
            ),
            SizedBox(
              height: _bottomArea,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  if (_c.loading)
                    _StatusHint(
                      text: _c.loadingStage.isEmpty ? '正在整理…' : _c.loadingStage,
                    )
                  else if (items.isEmpty)
                    _StatusHint(text: _c.isSearching ? '没有匹配的应用' : '没有可显示的应用'),
                  PageDots(
                    count: pageCount,
                    current: currentPage,
                    onSelect: _gotoPage,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 是否给搜索框套液态玻璃材质（玻璃控件常驻会持续占用 GPU）。
  static const bool _kGlassSearchBar = false;

  Widget _buildSearchField() {
    if (!_kGlassSearchBar) {
      return TextField(
        controller: _searchText,
        focusNode: _searchFocus,
        style: const TextStyle(color: Colors.white, fontSize: 14.5),
        cursorColor: Colors.white,
        decoration: InputDecoration(
          isDense: true,
          hintText: '搜索',
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 34,
            vertical: 12,
          ),
          prefixIcon: Icon(
            Icons.search_rounded,
            size: 18,
            color: Colors.white.withValues(alpha: 0.7),
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 34),
          hintStyle: TextStyle(
            color: Colors.white.withValues(alpha: 0.6),
            fontSize: 14.5,
          ),
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.16),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(22),
            borderSide: BorderSide(
              color: Colors.white.withValues(alpha: 0.22),
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(22),
            borderSide: BorderSide(
              color: Colors.white.withValues(alpha: 0.38),
            ),
          ),
        ),
      );
    }
    return GlassSearchBar(
      controller: _searchText,
      focusNode: _searchFocus,
      placeholder: '搜索',
      autofocus: true,
      showsCancelButton: false,
      height: 44,
      searchIconColor: Colors.white.withValues(alpha: 0.75),
      textStyle: const TextStyle(color: Colors.white, fontSize: 14.5),
      placeholderStyle: TextStyle(
        color: Colors.white.withValues(alpha: 0.6),
        fontSize: 14.5,
      ),
      quality: GlassQuality.minimal,
      settings: const LiquidGlassSettings(
        blur: 12,
        thickness: 16,
        glassColor: Color(0x30FFFFFF),
        saturation: 1.2,
        lightIntensity: 0.35,
      ),
      onChanged: (_) => setState(() {}),
    );
  }

  Widget _buildTopBar(Size size) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(_sidePadding, 34, _sidePadding, 8),
      child: Row(
        children: <Widget>[
          const SizedBox(width: 340),
          Expanded(
            child: Align(
              alignment: Alignment.center,
              child: SizedBox(
                width: 360,
                child: _buildSearchField(),
              ),
            ),
          ),
          SizedBox(
            width: 340,
            child: Align(
              alignment: Alignment.centerRight,
              child: _HintPill(
                text: _jiggleMode ? '拖动图标排序 · 长按合并成文件夹 · 点击空白处收起' : '',
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 记录上一帧的项用于「幽灵淡出」，避免搜索时图标硬切。
  void _syncGhosts(List<LauncherItem> items, GridLayout layout) {
    final currentRefs = items.map((e) => e.ref).toSet();
    final previous = _prevItems;
    final prevLayout = _prevLayout;

    var ghosts = _ghosts;
    if (previous.isNotEmpty && prevLayout != null) {
      final computed = <GhostEntry>[];
      for (var i = 0; i < previous.length; i++) {
        final prev = previous[i];
        if (currentRefs.contains(prev.ref)) continue;
        final (page, row, col) = prevLayout.slotOf(i);
        computed.add(GhostEntry(item: prev, page: page, row: row, col: col));
      }
      if (computed.isNotEmpty) {
        final sameAsCurrent =
            ghosts.length == computed.length &&
            List.generate(
              ghosts.length,
              (i) => ghosts[i].item.ref == computed[i].item.ref,
            ).every((e) => e);
        if (!sameAsCurrent) ghosts = computed;
      } else if (ghosts.isNotEmpty && currentRefs.isNotEmpty) {
        ghosts = const <GhostEntry>[];
      }
    }

    if (!identical(ghosts, _ghosts)) {
      _ghosts = ghosts;
      _ghostTimer?.cancel();
      if (ghosts.isNotEmpty) {
        _ghostTimer = Timer(const Duration(milliseconds: 380), () {
          if (mounted) setState(() => _ghosts = const <GhostEntry>[]);
        });
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _prevItems = items;
      _prevLayout = layout;
    });
  }
}

class _StatusHint extends StatelessWidget {
  const _StatusHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.75),
          fontSize: 13,
        ),
      ),
    );
  }
}

class _HintPill extends StatelessWidget {
  const _HintPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 220),
      opacity: text.isEmpty ? 0 : 1,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.28),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.85),
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}
