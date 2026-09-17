import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:windowslauncherpad/src/app.dart';
import 'package:windowslauncherpad/src/native/win_api.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 预热液态玻璃着色器，避免首帧出现白闪。
  await LiquidGlassWidgets.initialize(enablePerformanceMonitor: false);

  // 初始化 Rust 桥（Win32 能力）。
  await WinApi.init();

  runApp(
    LiquidGlassWidgets.wrap(
      child: const LauncherApp(),
      // 启动台始终是深色场景，让玻璃按深色取色。
      brightnessResolver: (_) => Brightness.dark,
      adaptiveQuality: true,
    ),
  );
}
