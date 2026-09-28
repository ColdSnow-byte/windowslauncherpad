import 'dart:convert';
import 'dart:io';

/// 图标来源模式。
enum IconSourceMode {
  /// 自动扫描系统已安装应用（默认）。
  scan,

  /// 只展示用户手动添加的图标。
  manual,
}

/// 用户手动添加的一个图标。
class CustomIcon {
  const CustomIcon({
    required this.id,
    required this.name,
    required this.target,
    this.fromFile = false,
  });

  /// 稳定标识：文件路径，或扫描得到的应用 id。
  final String id;

  /// 展示名称。
  final String name;

  /// 启动目标（文件路径或 AUMID）。
  final String target;

  /// 是否由「浏览文件」添加。
  final bool fromFile;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'target': target,
        'fromFile': fromFile,
      };

  factory CustomIcon.fromJson(Map<String, dynamic> json) => CustomIcon(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        target: json['target'] as String? ?? '',
        fromFile: json['fromFile'] as bool? ?? false,
      );

  static CustomIcon? tryParse(Object? value) {
    if (value is! Map) return null;
    final icon = CustomIcon.fromJson(Map<String, dynamic>.from(value));
    return icon.id.isEmpty ? null : icon;
  }
}

/// 启动台的图标来源配置。
class SourceConfig {
  const SourceConfig({
    this.mode = IconSourceMode.scan,
    this.custom = const <CustomIcon>[],
  });

  final IconSourceMode mode;
  final List<CustomIcon> custom;

  SourceConfig copyWith({IconSourceMode? mode, List<CustomIcon>? custom}) =>
      SourceConfig(
        mode: mode ?? this.mode,
        custom: custom ?? this.custom,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': 1,
        'mode': mode.name,
        'custom': custom.map((e) => e.toJson()).toList(),
      };

  factory SourceConfig.fromJson(Map<String, dynamic> json) {
    final rawMode = json['mode'] as String?;
    final list = <CustomIcon>[];
    final rawCustom = json['custom'];
    if (rawCustom is List) {
      for (final entry in rawCustom) {
        final icon = CustomIcon.tryParse(entry);
        if (icon != null) list.add(icon);
      }
    }
    return SourceConfig(
      mode: rawMode == IconSourceMode.manual.name
          ? IconSourceMode.manual
          : IconSourceMode.scan,
      custom: list,
    );
  }
}

/// `sources.json` 的读写。主窗口与设置窗口共用这个文件做同步。
class SourceConfigStore {
  const SourceConfigStore._();

  static File fileOf(String dataDir) => File(
        '$dataDir${Platform.pathSeparator}sources.json',
      );

  static Future<SourceConfig> load(String dataDir) async {
    try {
      final file = fileOf(dataDir);
      if (!await file.exists()) return const SourceConfig();
      final text = await file.readAsString();
      // 容忍外部编辑器写入的 UTF-8 BOM
      final cleaned = text.replaceFirst('\uFEFF', '').trim();
      if (cleaned.isEmpty) return const SourceConfig();
      final decoded = jsonDecode(cleaned);
      if (decoded is! Map) return const SourceConfig();
      return SourceConfig.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return const SourceConfig();
    }
  }

  static Future<void> save(String dataDir, SourceConfig config) async {
    try {
      final file = fileOf(dataDir);
      await file.writeAsString(jsonEncode(config.toJson()), flush: true);
    } catch (_) {}
  }
}
