import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:windowslauncherpad/src/model/launcher_item.dart';
import 'package:windowslauncherpad/src/model/layout_store.dart';
import 'package:windowslauncherpad/src/native/win_api.dart';
import 'package:windowslauncherpad/src/rust/api/launcher.dart';
import 'package:windowslauncherpad/src/state/icon_repository.dart';

const int _kLayoutVersion = 1;

/// 启动台的全部状态：应用清单、排序、文件夹、搜索与分页。
class LauncherController extends ChangeNotifier {
  LauncherController({required this.store}) {
    icons = IconRepository(store: store);
  }

  final LayoutStore store;
  late final IconRepository icons;

  // ── 原始数据 ──────────────────────────────────────────────────────────────

  final Map<String, AppEntry> _appById = <String, AppEntry>{};

  /// 顶层顺序，元素为 `a:<appId>` 或 `f:<folderId>`。
  final List<String> _order = <String>[];

  /// 文件夹定义：folderId → 应用 id 列表（首项为封面）。
  final Map<String, List<String>> _folders = <String, List<String>>{};

  /// folderId → 名称。
  final Map<String, String> _folderNames = <String, String>{};

  /// 被用户隐藏的引用与文件夹内应用。
  final Set<String> _hidden = <String>{};
  final Set<String> _hiddenInsideFolder = <String>{};

  bool loading = true;
  String loadingStage = '正在扫描应用…';
  String? error;

  String query = '';
  int columns = 7;
  int rows = 5;

  Timer? _saveTimer;

  // ── 生命周期 ──────────────────────────────────────────────────────────────

  Future<void> bootstrap() async {
    loading = true;
    loadingStage = '正在读取布局…';
    notifyListeners();

    final saved = await store.read();
    if (saved != null) _applySavedLayout(saved);

    loadingStage = '正在扫描应用…';
    notifyListeners();

    final apps = await WinApi.listApps();
    _appById
      ..clear()
      ..addEntries(apps.map((a) => MapEntry(a.id, a)));

    _reconcile(apps);

    loading = false;
    loadingStage = '';
    notifyListeners();
    _scheduleSave();
    // 应用清单确定后再排队加载图标，避免界面先于数据就绪造成竞态。
    preloadIcons();
  }

  /// 把全部应用图标排进加载队列（内部限流，界面可先显示占位符）。
  void preloadIcons() {
    for (final app in _appById.values) {
      icons.request(app.id, (_) {});
    }
  }

  /// 重新扫描系统应用（隐藏项与自定义顺序保持不变）。
  Future<void> refresh() async {
    loadingStage = '正在重新扫描…';
    notifyListeners();
    final apps = await WinApi.listApps();
    _appById
      ..clear()
      ..addEntries(apps.map((a) => MapEntry(a.id, a)));
    _reconcile(apps);
    loadingStage = '';
    notifyListeners();
    _scheduleSave();
    preloadIcons();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    icons.dispose();
    super.dispose();
  }

  // ── 布局读写 ──────────────────────────────────────────────────────────────

  void _applySavedLayout(Map<String, dynamic> json) {
    final order = json['order'];
    if (order is List) {
      _order
        ..clear()
        ..addAll(order.whereType<String>());
    }

    final folders = json['folders'];
    if (folders is Map) {
      folders.forEach((key, value) {
        if (key is! String || value is! Map) return;
        final name = value['name'];
        final apps = value['apps'];
        _folderNames[key] = name is String ? name : '文件夹';
        if (apps is List) {
          _folders[key] = apps.whereType<String>().toList();
        }
      });
    }

    final hidden = json['hidden'];
    if (hidden is List) {
      _hidden
        ..clear()
        ..addAll(hidden.whereType<String>());
    }

    final hiddenInside = json['hiddenInsideFolder'];
    if (hiddenInside is List) {
      _hiddenInsideFolder
        ..clear()
        ..addAll(hiddenInside.whereType<String>());
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': _kLayoutVersion,
        'order': _order,
        'folders': <String, dynamic>{
          for (final e in _folders.entries)
            e.key: <String, dynamic>{
              'name': _folderNames[e.key] ?? '文件夹',
              'apps': e.value,
            },
        },
        'hidden': _hidden.toList(),
        'hiddenInsideFolder': _hiddenInsideFolder.toList(),
      };

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(store.write(toJson()));
    });
  }

  /// 让 `_order` 与新扫描到的应用集合保持一致。
  void _reconcile(List<AppEntry> apps) {
    final validAppIds = apps.map((a) => a.id).toSet();

    // 1) 清理已失效的文件夹成员与空文件夹
    for (final folderId in _folders.keys.toList()) {
      final list = _folders[folderId]!;
      list.removeWhere((id) => !validAppIds.contains(id));
      if (list.isEmpty) {
        _folders.remove(folderId);
        _folderNames.remove(folderId);
        _order.remove(folderRefOf(folderId));
      }
    }

    // 2) 清理失效的顶层引用
    _order.removeWhere((ref) {
      if (ref.startsWith('a:')) {
        return !validAppIds.contains(ref.substring(2));
      }
      if (ref.startsWith('f:')) {
        return !_folders.containsKey(ref.substring(2));
      }
      return true;
    });

    // 3) 已被文件夹收纳 / 已隐藏的应用不应出现在顶层
    final inFolder = <String>{};
    for (final list in _folders.values) {
      inFolder.addAll(list);
    }

    // 4) 新安装的应用追加到末尾
    for (final app in apps) {
      if (_hidden.contains(appRefOf(app.id))) continue;
      if (inFolder.contains(app.id)) continue;
      final ref = appRefOf(app.id);
      if (!_order.contains(ref)) _order.add(ref);
    }

    // 5) 文件夹名兜底
    for (final id in _folders.keys) {
      _folderNames.putIfAbsent(id, () => '文件夹');
    }
  }

  // ── 派生数据 ──────────────────────────────────────────────────────────────

  List<AppEntry> get allApps => _appById.values.toList(growable: false);

  AppEntry? appById(String id) => _appById[id];

  /// 按当前顺序解析出的所有顶层格子（含被隐藏的项，隐藏项会被渲染层跳过）。
  List<LauncherItem> get orderedItems {
    final items = <LauncherItem>[];
    for (final ref in _order) {
      final item = _resolve(ref);
      if (item != null) items.add(item);
    }
    return items;
  }

  LauncherItem? itemByRef(String ref) => _resolve(ref);

  LauncherItem? _resolve(String ref) {
    if (ref.startsWith('a:')) {
      final app = _appById[ref.substring(2)];
      return app == null ? null : LauncherItem.app(app);
    }
    if (ref.startsWith('f:')) {
      final folderId = ref.substring(2);
      final ids = _folders[folderId];
      if (ids == null || ids.isEmpty) return null;
      final children = ids
          .map((id) => _appById[id])
          .whereType<AppEntry>()
          .where((a) => !_hiddenInsideFolder.contains(a.id))
          .toList();
      if (children.isEmpty) return null;
      return LauncherItem.folder(
        folderId: folderId,
        name: _folderNames[folderId] ?? '文件夹',
        children: children,
      );
    }
    return null;
  }

  /// 过滤掉用户隐藏的顶层项。
  List<LauncherItem> get visibleItems {
    final items = orderedItems;
    final result = <LauncherItem>[];
    for (final item in items) {
      final key = item.app?.id ?? item.folderId!;
      if (!item.isFolder && _hidden.contains(appRefOf(key))) continue;
      if (item.isFolder && _hidden.contains(folderRefOf(key))) continue;
      result.add(item);
    }
    return result;
  }

  bool isHidden(String ref) => _hidden.contains(ref);

  /// 搜索结果（macOS 会展开文件夹内的匹配项）。
  List<LauncherItem> get searchResults {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const <LauncherItem>[];
    final result = <LauncherItem>[];
    for (final item in visibleItems) {
      if (item.isFolder) {
        if (item.name.toLowerCase().contains(q)) {
          result.add(item);
        } else {
          for (final child in item.children) {
            if (child.name.toLowerCase().contains(q)) {
              result.add(LauncherItem.app(child));
            }
          }
        }
      } else if (item.name.toLowerCase().contains(q)) {
        result.add(item);
      }
    }
    return result;
  }

  bool get isSearching => query.trim().isNotEmpty;

  int get perPage => math.max(1, columns * rows);

  List<List<LauncherItem>> get pages {
    final source = isSearching ? searchResults : visibleItems;
    if (source.isEmpty) return const <List<LauncherItem>>[<LauncherItem>[]];
    final result = <List<LauncherItem>>[];
    for (var i = 0; i < source.length; i += perPage) {
      result.add(source.sublist(i, math.min(i + perPage, source.length)));
    }
    return result;
  }

  void setGrid({required int columns, required int rows}) {
    if (this.columns == columns && this.rows == rows) return;
    this.columns = columns;
    this.rows = rows;
    notifyListeners();
  }

  // ── 交互操作 ──────────────────────────────────────────────────────────────

  void setQuery(String value) {
    if (query == value) return;
    query = value;
    notifyListeners();
  }

  void clearQuery() {
    if (query.isEmpty) return;
    query = '';
    notifyListeners();
  }

  /// 把 [dragRef] 移动到 [targetRef] 所在的位置（实时重排）。
  void reorder(String dragRef, String targetRef) {
    if (dragRef == targetRef) return;
    final from = _order.indexOf(dragRef);
    final to = _order.indexOf(targetRef);
    if (from < 0 || to < 0) return;
    final item = _order.removeAt(from);
    _order.insert(to.clamp(0, _order.length), item);
    notifyListeners();
    _scheduleSave();
  }

  /// 把两个顶层项合并成一个新文件夹，返回新文件夹引用。
  String createFolder(String refA, String refB) {
    if (refA == refB) return refA;

    // 若其中一个是文件夹，直接把另一个塞进去
    if (refA.startsWith('f:') || refB.startsWith('f:')) {
      final folderRef = refA.startsWith('f:') ? refA : refB;
      final otherRef = folderRef == refA ? refB : refA;
      final folderId = folderRef.substring(2);
      final otherAppId = otherRef.startsWith('a:') ? otherRef.substring(2) : null;
      if (otherAppId != null) {
        _folders.putIfAbsent(folderId, () => <String>[]).add(otherAppId);
        _order.remove(otherRef);
        notifyListeners();
        _scheduleSave();
      }
      return folderRef;
    }

    final idA = refA.substring(2);
    final idB = refB.substring(2);
    final folderId = 'g${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    _folders[folderId] = <String>[idA, idB];
    _folderNames[folderId] = _folderNameFrom(<String>[idA, idB]);

    final indexA = _order.indexOf(refA);
    final indexB = _order.indexOf(refB);
    final insertAt = math.min(
      indexA < 0 ? _order.length : indexA,
      indexB < 0 ? _order.length : indexB,
    );
    _order.remove(refA);
    _order.remove(refB);
    _order.insert(insertAt.clamp(0, _order.length), folderRefOf(folderId));

    notifyListeners();
    _scheduleSave();
    return folderRefOf(folderId);
  }

  String _folderNameFrom(List<String> appIds) {
    if (appIds.isEmpty) return '文件夹';
    final first = _appById[appIds.first];
    if (first == null) return '文件夹';
    final word = first.name.trim().split(RegExp(r'\s+')).first;
    return word.isEmpty ? '文件夹' : word;
  }

  /// 把一个应用从文件夹中取出，放回顶层。
  void removeFromFolder(String folderId, String appId) {
    final list = _folders[folderId];
    if (list == null) return;
    list.remove(appId);
    if (list.isEmpty) {
      _folders.remove(folderId);
      _folderNames.remove(folderId);
      _order.remove(folderRefOf(folderId));
    }
    final ref = appRefOf(appId);
    if (!_order.contains(ref)) _order.add(ref);
    notifyListeners();
    _scheduleSave();
  }

  void moveIntoFolder(String folderId, String appId, {bool front = false}) {
    final list = _folders[folderId];
    if (list == null) return;
    _order.remove(appRefOf(appId));
    list.remove(appId);
    if (front) {
      list.insert(0, appId);
    } else {
      list.add(appId);
    }
    notifyListeners();
    _scheduleSave();
  }

  /// 解散文件夹，把内部应用平铺回原来所在的位置。
  void dissolveFolder(String folderId) {
    final ids = _folders.remove(folderId);
    _folderNames.remove(folderId);
    final ref = folderRefOf(folderId);
    final idx = _order.indexOf(ref);
    if (idx >= 0) _order.removeAt(idx);
    if (ids != null && ids.isNotEmpty) {
      final insertAt = idx < 0 ? _order.length : idx;
      _order.insertAll(insertAt.clamp(0, _order.length), ids.map(appRefOf));
    }
    notifyListeners();
    _scheduleSave();
  }

  void renameFolder(String folderId, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    _folderNames[folderId] = trimmed;
    notifyListeners();
    _scheduleSave();
  }

  /// 从启动台移除某个顶层项。
  void hide(String ref) {
    _hidden.add(ref);
    _order.remove(ref);
    notifyListeners();
    _scheduleSave();
  }

  /// 从启动台移除文件夹内的某个应用。
  void hideInsideFolder(String appId) {
    _hiddenInsideFolder.add(appId);
    for (final list in _folders.values) {
      list.remove(appId);
    }
    notifyListeners();
    _scheduleSave();
  }

  /// 恢复全部被隐藏的应用。
  void restoreHidden() {
    _hidden.clear();
    _hiddenInsideFolder.clear();
    final inFolder = <String>{};
    for (final list in _folders.values) {
      inFolder.addAll(list);
    }
    for (final app in _appById.values) {
      if (inFolder.contains(app.id)) continue;
      final ref = appRefOf(app.id);
      if (!_order.contains(ref)) _order.add(ref);
    }
    notifyListeners();
    _scheduleSave();
  }

  /// 恢复出厂排序（保留应用集合）。
  void resetLayout() {
    _order.clear();
    _folders.clear();
    _folderNames.clear();
    _hidden.clear();
    _hiddenInsideFolder.clear();
    _reconcile(_appById.values.toList());
    notifyListeners();
    _scheduleSave();
  }

  /// 在给定页上把一个格子移动到指定位置（供拖拽落点使用）。
  void moveToIndex(String ref, int index) {
    final from = _order.indexOf(ref);
    if (from < 0) return;
    _order.removeAt(from);
    _order.insert(index.clamp(0, _order.length), ref);
    notifyListeners();
    _scheduleSave();
  }

  /// 根据某一页上的可见顺序重建顶层顺序（用于跨页拖拽）。
  void applyPageOrder(List<LauncherItem> items) {
    final refs = items.map((e) => e.ref).toList();
    _order
      ..removeWhere(refs.contains)
      ..insertAll(0, refs);
    notifyListeners();
    _scheduleSave();
  }
}
