import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:windowslauncherpad/src/model/layout_store.dart';
import 'package:windowslauncherpad/src/native/win_api.dart';
import 'package:windowslauncherpad/src/util/color_utils.dart';
import 'package:windowslauncherpad/src/util/glow_image.dart';

/// 一个已就绪的图标：位图 + 主色 + 预先烘焙好的柔光位图。
class IconAsset {
  const IconAsset({
    required this.image,
    required this.glow,
    this.glowImage,
  });

  final ui.Image image;

  /// 图标主色，用于该图标周围的彩色柔光。
  final Color glow;

  /// 已烘焙的柔光剪影（比原图大一圈、含模糊），以加色方式绘制在图标下方。
  final ui.Image? glowImage;
}

/// 图标加载器：内存 → 磁盘 PNG 缓存 → Rust(Win32) 逐级回退。
///
/// 加载流程刻意避开所有 GPU 回读（不使用 `toByteData(png)` 阻塞主流程），
/// 因此上百个图标可以在很短时间内全部就绪；PNG 落盘推迟到空闲时批量补写。
class IconRepository {
  IconRepository({required this.store, this.maxConcurrency = 8});

  final LayoutStore store;
  final int maxConcurrency;

  final Map<String, IconAsset> _memory = <String, IconAsset>{};
  final Set<String> _pending = <String>{};
  final Queue<String> _queue = Queue<String>();

  /// 需要在空闲时补写 PNG 的图标（key → image）。
  final Map<String, ui.Image> _pendingWrites = <String, ui.Image>{};
  bool _flushing = false;

  int _running = 0;
  bool _disposed = false;

  /// 已完成的加载数量，用于「正在整理图标…」进度提示。
  final ValueNotifier<int> loadedCount = ValueNotifier<int>(0);

  /// 图标集合发生变化（节流后），界面据此刷新。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  Timer? _revisionTimer;

  IconAsset? peek(String id) => _memory[id];

  int get total => _memory.length;

  /// 请求加载图标。命中内存时 [onReady] 会同步触发。
  void request(String id, void Function(IconAsset asset) onReady) {
    final cached = _memory[id];
    if (cached != null) {
      onReady(cached);
      return;
    }
    if (_pending.contains(id)) return;
    _pending.add(id);
    _queue.add(id);
    _pump();
  }

  void _pump() {
    if (_disposed) return;
    while (_running < maxConcurrency && _queue.isNotEmpty) {
      final next = _queue.removeFirst();
      _running++;
      _load(next).then((asset) {
        _pending.remove(next);
        _running--;
        if (asset != null && !_disposed) {
          _memory[next] = asset;
          loadedCount.value = _memory.length;
          _scheduleRevision();
        }
        _pump();
        if (_queue.isEmpty && _running == 0) _scheduleIdleFlush();
      });
    }
  }

  Future<IconAsset?> _load(String id) async {
    final key = fnv1a64(id);
    final cachedColor = await _colorFor(key);

    // 1) 磁盘 PNG 缓存
    try {
      final file = store.iconFile(key);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        final image = await _decodePng(bytes);
        if (image != null) {
          return _assemble(
            image,
            cachedColor ?? await _glowFromImage(image, key),
          );
        }
      }
    } catch (_) {}

    // 2) 通过 Rust 调用 Win32 Shell API 提取
    final raw = await WinApi.loadIcon(id);
    if (raw == null || raw.width == 0 || raw.height == 0) return null;

    final glow = cachedColor ?? glowColorFromRgba(raw.rgba);
    if (cachedColor == null) unawaited(_rememberColor(key, glow));

    try {
      final image = await _decodeRgba(raw.rgba, raw.width, raw.height);
      _pendingWrites[key] = image;
      return _assemble(image, glow);
    } catch (_) {
      return null;
    }
  }

  IconAsset _assemble(ui.Image image, Color glow) {
    ui.Image? glowImage;
    try {
      glowImage = buildGlowImage(image, glow);
    } catch (_) {
      glowImage = null;
    }
    return IconAsset(image: image, glow: glow, glowImage: glowImage);
  }

  Future<ui.Image?> _decodePng(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  Future<Color> _glowFromImage(ui.Image image, String key) async {
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return kNeutralGlow;
      final color = glowColorFromRgba(data.buffer.asUint8List());
      await _rememberColor(key, color);
      return color;
    } catch (_) {
      return kNeutralGlow;
    }
  }

  // ── 空闲时补写 PNG 缓存 ───────────────────────────────────────────────────

  void _scheduleIdleFlush() {
    if (_flushing || _pendingWrites.isEmpty || _idleTimer != null) return;
    _idleTimer = Timer(const Duration(milliseconds: 1500), () {
      _idleTimer = null;
      unawaited(_flushPngs());
    });
  }

  Timer? _idleTimer;

  Future<void> _flushPngs() async {
    if (_flushing || _disposed) return;
    _flushing = true;
    try {
      final dir = store.iconCacheDir;
      if (!await dir.exists()) await dir.create(recursive: true);
      while (_pendingWrites.isNotEmpty && !_disposed) {
        final entry = _pendingWrites.entries.first;
        _pendingWrites.remove(entry.key);
        try {
          final file = store.iconFile(entry.key);
          if (await file.exists()) continue;
          final data =
              await entry.value.toByteData(format: ui.ImageByteFormat.png);
          if (data == null) continue;
          await file.writeAsBytes(data.buffer.asUint8List(), flush: false);
        } catch (_) {}
        // 让出事件循环，避免长时间占用
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      _flushing = false;
    }
  }

  // ── 主色缓存：避免每次启动都重新读像素 ────────────────────────────────────

  final Map<String, Color> _colors = <String, Color>{};
  bool _colorsLoaded = false;
  bool _colorsDirty = false;
  Timer? _flushTimer;

  File get _colorFile => File(
      '${store.iconCacheDir.parent.path}${Platform.pathSeparator}icon_colors.json');

  Future<Color?> _colorFor(String key) async {
    if (!_colorsLoaded) {
      _colorsLoaded = true;
      try {
        final f = _colorFile;
        if (await f.exists()) {
          final text = await f.readAsString();
          if (text.trim().isNotEmpty) {
            final decoded = jsonDecode(text);
            if (decoded is Map) {
              decoded.forEach((k, v) {
                if (k is String && v is int) _colors[k] = Color(v);
              });
            }
          }
        }
      } catch (_) {}
    }
    return _colors[key];
  }

  Future<void> _rememberColor(String key, Color color) async {
    _colors[key] = color;
    _colorsDirty = true;
    _flushTimer ??= Timer(const Duration(seconds: 4), () {
      _flushTimer = null;
      unawaited(_flushColors());
    });
  }

  Future<void> _flushColors() async {
    if (!_colorsDirty) return;
    _colorsDirty = false;
    try {
      final map = <String, int>{
        for (final e in _colors.entries) e.key: e.value.toARGB32(),
      };
      await _colorFile.writeAsString(jsonEncode(map), flush: false);
    } catch (_) {}
  }

  /// 节流通知：避免每加载一个图标就整屏重建。
  void _scheduleRevision() {
    _revisionTimer ??= Timer(const Duration(milliseconds: 90), () {
      _revisionTimer = null;
      if (!_disposed) revision.value++;
    });
  }

  void dispose() {
    _disposed = true;
    _revisionTimer?.cancel();
    _idleTimer?.cancel();
    _queue.clear();
    _flushTimer?.cancel();
    unawaited(_flushColors());
    for (final a in _memory.values) {
      a.glowImage?.dispose();
      a.image.dispose();
    }
    _memory.clear();
  }
}

Future<ui.Image> _decodeRgba(Uint8List rgba, int width, int height) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

/// FNV-1a 64 位哈希：把任意应用 id 映射为安全的缓存文件名。
String fnv1a64(String input) {
  var hash = 0xcbf29ce484222325;
  for (final unit in input.codeUnits) {
    hash ^= unit;
    // 截断到 63 位，保证在 Dart 的有符号 64 位整数下始终为正。
    hash = (hash * 0x100000001b3) & 0x7FFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
