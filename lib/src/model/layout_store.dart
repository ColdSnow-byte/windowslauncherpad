import 'dart:convert';
import 'dart:io';

/// 启动台布局的磁盘持久化（`<数据目录>/layout.json`）。
class LayoutStore {
  LayoutStore._(this._dir);

  final Directory _dir;

  static Future<LayoutStore> open(String dataDir) async {
    final dir = Directory(dataDir.isEmpty ? '.' : dataDir);
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
    } catch (_) {}
    return LayoutStore._(dir);
  }

  File get _layoutFile => File('${_dir.path}${Platform.pathSeparator}layout.json');

  Directory get iconCacheDir =>
      Directory('${_dir.path}${Platform.pathSeparator}icons');

  /// 读取布局；文件不存在或损坏时返回 null。
  Future<Map<String, dynamic>?> read() async {
    try {
      final f = _layoutFile;
      if (!await f.exists()) return null;
      final text = await f.readAsString();
      if (text.trim().isEmpty) return null;
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> write(Map<String, dynamic> data) async {
    try {
      await _layoutFile.writeAsString(jsonEncode(data), flush: true);
    } catch (_) {}
  }

  /// 图标 PNG 缓存文件。
  File iconFile(String key) =>
      File('${iconCacheDir.path}${Platform.pathSeparator}$key.png');
}
