import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:windowslauncherpad/src/model/layout_store.dart';
import 'package:windowslauncherpad/src/native/win_api.dart';
import 'package:windowslauncherpad/src/state/launcher_controller.dart';
import 'package:windowslauncherpad/src/ui/launchpad_screen.dart';

/// 应用根：负责引导加载（数据目录、应用清单、壁纸）与全屏切换。
class LauncherApp extends StatefulWidget {
  const LauncherApp({super.key});

  @override
  State<LauncherApp> createState() => _LauncherAppState();
}

class _LauncherAppState extends State<LauncherApp> {
  LauncherController? _controller;
  ui.Image? _wallpaperImage;
  String _wallpaperPath = '';
  bool _fullscreenApplied = false;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  @override
  void dispose() {
    _controller?.dispose();
    _wallpaperImage?.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    // 1) 布局存储
    final dir = await WinApi.dataDir();
    final store = await LayoutStore.open(dir);

    // 2) 控制器 + 后台枚举应用
    final controller = LauncherController(store: store);
    unawaited(controller.bootstrap());

    // 3) 壁纸
    _wallpaperPath = await WinApi.wallpaper();
    _wallpaperImage = await _decodeWallpaper(_wallpaperPath);

    if (!mounted) {
      controller.dispose();
      return;
    }
    setState(() => _controller = controller);

    // 4) 窗口铺满整个屏幕（覆盖任务栏），并置前
    if (!_fullscreenApplied) {
      _fullscreenApplied = true;
      await WinApi.setFullscreen(true);
    }

    // 5) 常驻系统托盘 + 全局热键，收起后仍在后台待命
    await WinApi.initTray();
  }

  /// 壁纸只用于重度模糊，因此直接解码成小图，代价极低。
  Future<ui.Image?> _decodeWallpaper(String path) async {
    if (path.isEmpty) return null;
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 720);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '启动台',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.transparent,
        fontFamily: 'Segoe UI',
      ),
      // liquid_glass_widgets 不依赖 Material，需要一层透明 Material 提供文字样式；
      // 再显式关闭下划线，避免继承到 WidgetsApp 的调试文本样式。
      builder: (context, child) => Material(
        type: MaterialType.transparency,
        child: DefaultTextStyle(
          style: const TextStyle(
            decoration: TextDecoration.none,
            color: Colors.white,
            fontSize: 14,
          ),
          child: child ?? const SizedBox.shrink(),
        ),
      ),
      home: controller == null
          ? const _BootScreen()
          : LaunchpadScreen(
              controller: controller,
              wallpaperPath: _wallpaperPath,
              wallpaperImage: _wallpaperImage,
            ),
    );
  }
}

class _BootScreen extends StatelessWidget {
  const _BootScreen();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF1B2733), Color(0xFF2C2338)],
        ),
      ),
      child: Center(
        child: Text(
          '正在启动…',
          style: TextStyle(color: Color(0xB3FFFFFF), fontSize: 15),
        ),
      ),
    );
  }
}
