import 'dart:typed_data';

import 'package:windowslauncherpad/src/rust/api/launcher.dart' as rust;
import 'package:windowslauncherpad/src/rust/api/tray.dart' as rust_tray;
import 'package:windowslauncherpad/src/rust/frb_generated.dart';

/// 未经解码的图标位图。
class WinIconBitmap {
  const WinIconBitmap({
    required this.width,
    required this.height,
    required this.rgba,
  });

  final int width;
  final int height;
  final Uint8List rgba;
}

/// 对 Rust 侧 Win32 能力的薄封装，负责把 `Result` 转成可空/异常语义。
class WinApi {
  WinApi._();

  static Future<void> init() => RustLib.init();

  /// 启动后台托盘与全局热键（Ctrl+Alt+Space）。
  static Future<void> initTray() async {
    try {
      await rust_tray.initTray();
    } catch (_) {}
  }

  /// 枚举开始菜单中的应用。
  static Future<List<rust.AppEntry>> listApps() async {
    try {
      return await rust.listApps();
    } catch (_) {
      return const <rust.AppEntry>[];
    }
  }

  /// 提取应用图标；失败返回 null（调用方使用占位图标）。
  static Future<WinIconBitmap?> loadIcon(String id) async {
    try {
      final b = await rust.loadIcon(id: id);
      return WinIconBitmap(width: b.width, height: b.height, rgba: b.rgba);
    } catch (_) {
      return null;
    }
  }

  static Future<bool> launchApp(String id) async {
    try {
      await rust.launchApp(id: id);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 在资源管理器中定位应用文件。
  static Future<void> revealInExplorer(String id) async {
    try {
      await rust.revealInExplorer(id: id);
    } catch (_) {}
  }

  /// 无边框全屏（覆盖任务栏）。
  static Future<void> setFullscreen(bool enabled) async {
    try {
      await rust.setFullscreen(enabled: enabled);
    } catch (_) {}
  }

  static Future<void> quit() async {
    try {
      await rust.quitApp();
    } catch (_) {}
  }

  /// 隐藏窗口，进程留在后台（热启动）。
  static Future<void> hide() async {
    try {
      await rust.hideWindow();
    } catch (_) {}
  }

  /// 窗口是否可见（判断是否已被托盘/热键重新呼出）。
  static Future<bool> isWindowVisible() async {
    try {
      return await rust.isWindowVisible();
    } catch (_) {
      return true;
    }
  }

  /// 从后台重新显示窗口。
  static Future<void> show() async {
    try {
      await rust.showWindow();
    } catch (_) {}
  }

  /// 当前桌面壁纸文件路径，可能为空。
  static Future<String> wallpaper() async {
    try {
      return await rust.desktopWallpaper();
    } catch (_) {
      return '';
    }
  }

  /// 用于持久化布局与图标缓存的目录。
  static Future<String> dataDir() async {
    try {
      return await rust.dataDir();
    } catch (_) {
      return '';
    }
  }
}
