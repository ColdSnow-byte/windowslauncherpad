import 'package:windowslauncherpad/src/rust/api/launcher.dart';

/// 启动台中的一个格子：要么是单个应用，要么是一个文件夹。
class LauncherItem {
  const LauncherItem._({
    required this.ref,
    required this.name,
    required this.app,
    required this.children,
    required this.folderId,
    this.customId,
  });

  /// 用户手动添加的图标（可能是任意文件，未必在系统应用清单里）。
  factory LauncherItem.custom({
    required String id,
    required String name,
  }) =>
      LauncherItem._(
        ref: 'c:$id',
        name: name,
        app: null,
        children: const <AppEntry>[],
        folderId: null,
        customId: id,
      );

  /// 单个应用。
  factory LauncherItem.app(AppEntry app) => LauncherItem._(
        ref: 'a:${app.id}',
        name: app.name,
        app: app,
        children: const <AppEntry>[],
        folderId: null,
      );

  /// 文件夹。
  factory LauncherItem.folder({
    required String folderId,
    required String name,
    required List<AppEntry> children,
  }) =>
      LauncherItem._(
        ref: 'f:$folderId',
        name: name,
        app: null,
        children: children,
        folderId: folderId,
      );

  /// 稳定引用：`a:<应用 id>` 或 `f:<文件夹 id>`。
  final String ref;
  final String name;
  final AppEntry? app;
  final List<AppEntry> children;
  final String? folderId;

  /// 手动添加的图标对应的标识（普通应用为 null）。
  final String? customId;

  bool get isFolder => folderId != null;
  bool get isCustom => customId != null;

  /// 应用 id（文件夹返回 null）。
  String? get appId => app?.id;

  /// 取图标 / 启动统一使用的标识。
  String get launchId => app?.id ?? customId ?? folderId ?? ref;

  /// 文件夹内应用数量。
  int get badgeCount => children.length;

  @override
  String toString() => 'LauncherItem($ref, $name)';
}

/// 从引用字符串解析出应用 id。
String appRefOf(String appId) => 'a:$appId';

/// 从引用字符串解析出文件夹 id。
String folderRefOf(String folderId) => 'f:$folderId';
