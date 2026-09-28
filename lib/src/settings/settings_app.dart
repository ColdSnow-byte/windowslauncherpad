import 'dart:async';
import 'dart:io' as io;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:windowslauncherpad/src/model/source_config.dart';
import 'package:windowslauncherpad/src/native/win_api.dart';
import 'package:windowslauncherpad/src/rust/api/launcher.dart' as rust;

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.dataDir, this.onDone});

  final String dataDir;

  /// 点「完成」时回调（由宿主负责收起设置页）。
  final VoidCallback? onDone;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  SourceConfig _config = const SourceConfig();
  bool _loading = true;
  bool _saving = false;
  bool _dragging = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final config = await SourceConfigStore.load(widget.dataDir);
    if (!mounted) return;
    setState(() {
      _config = config;
      _loading = false;
    });
  }

  Future<void> _persist(SourceConfig next, {String? status}) async {
    setState(() {
      _config = next;
      _saving = true;
      _status = status;
    });
    await SourceConfigStore.save(widget.dataDir, next);
    if (!mounted) return;
    setState(() => _saving = false);
  }

  void _setMode(IconSourceMode mode) {
    if (_config.mode == mode) return;
    unawaited(_persist(_config.copyWith(mode: mode), status: '已切换来源模式'));
  }

  Future<void> _addFromInstalled() async {
    final apps = await WinApi.listApps();
    if (!mounted) return;
    final picked = await showDialog<List<rust.AppEntry>>(
      context: context,
      builder: (context) => _AppPickerDialog(apps: apps, already: _config.custom),
    );
    if (picked == null || picked.isEmpty) return;

    final added = List<CustomIcon>.of(_config.custom);
    final existing = added.map((e) => e.id).toSet();
    for (final app in picked) {
      if (existing.contains(app.id)) continue;
      added.add(
        CustomIcon(
          id: app.id,
          name: app.name,
          target: app.target.isEmpty ? app.id : app.target,
        ),
      );
    }
    await _persist(
      _config.copyWith(custom: added),
      status: '已添加 ${added.length - _config.custom.length} 个图标',
    );
  }

  /// 拖入的文件 / 文件夹 → 图标列表（可一次拖入多个）。
  Future<void> _addDroppedPaths(List<String> paths) async {
    final collected = <String>[];
    for (final path in paths) {
      final type = io.FileSystemEntity.typeSync(path, followLinks: false);
      if (type == io.FileSystemEntityType.directory) {
        await _collectFromDirectory(path, collected);
      } else if (type == io.FileSystemEntityType.file) {
        collected.add(path);
      }
    }
    if (collected.isEmpty) {
      if (mounted) setState(() => _status = '拖入的内容里没有可用的程序');
      return;
    }
    await _mergeCustom(collected);
  }

  static const Set<String> _launchableExtensions = <String>{
    '.exe', '.lnk', '.bat', '.cmd', '.url', '.msc', '.ps1',
  };

  /// 文件夹只往下扫一层，避免拖入 Program Files 时炸出几百个图标。
  Future<void> _collectFromDirectory(
    String dir,
    List<String> out, {
    int depth = 0,
  }) async {
    const int maxDepth = 1;
    const int maxItems = 60;
    try {
      await for (final entity
          in io.Directory(dir).list(followLinks: false)) {
        if (out.length >= maxItems) return;
        if (entity is io.File) {
          final dot = entity.path.lastIndexOf('.');
          if (dot < 0) continue;
          if (_launchableExtensions.contains(
            entity.path.substring(dot).toLowerCase(),
          )) {
            out.add(entity.path);
          }
        } else if (entity is io.Directory && depth < maxDepth) {
          await _collectFromDirectory(entity.path, out, depth: depth + 1);
        }
      }
    } catch (_) {}
  }

  /// 把一批路径并入手动列表并落盘。
  Future<void> _mergeCustom(List<String> paths) async {
    final added = List<CustomIcon>.of(_config.custom);
    final existing = added.map((e) => e.id).toSet();
    var count = 0;
    for (final path in paths) {
      if (existing.contains(path)) continue;
      existing.add(path);
      added.add(
        CustomIcon(
          id: path,
          name: _baseName(path),
          target: path,
          fromFile: true,
        ),
      );
      count++;
    }
    if (count == 0) {
      if (mounted) setState(() => _status = '这些项目已经在列表里了');
      return;
    }
    // 拖入即视为要用手动模式，否则加进来也看不见
    await _persist(
      _config.copyWith(mode: IconSourceMode.manual, custom: added),
      status: '已添加 $count 个图标',
    );
  }

  Future<void> _addFromFile() async {
    final paths = await WinApi.pickFiles();
    if (!mounted || paths.isEmpty) return;

    final added = List<CustomIcon>.of(_config.custom);
    final existing = added.map((e) => e.id).toSet();
    for (final path in paths) {
      if (existing.contains(path)) continue;
      added.add(
        CustomIcon(
          id: path,
          name: _baseName(path),
          target: path,
          fromFile: true,
        ),
      );
    }
    await _persist(
      _config.copyWith(custom: added),
      status: '已添加 ${added.length - _config.custom.length} 个图标',
    );
  }

  static String _baseName(String path) {
    final normalized = path.replaceAll('/', r'\');
    final index = normalized.lastIndexOf(r'\');
    final name = index < 0 ? normalized : normalized.substring(index + 1);
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }

  void _remove(int index) {
    final list = List<CustomIcon>.of(_config.custom)..removeAt(index);
    unawaited(_persist(_config.copyWith(custom: list)));
  }

  void _move(int index, int delta) {
    final target = index + delta;
    if (target < 0 || target >= _config.custom.length) return;
    final list = List<CustomIcon>.of(_config.custom);
    final item = list.removeAt(index);
    list.insert(target, item);
    unawaited(_persist(_config.copyWith(custom: list)));
  }

  Future<void> _rename(int index) async {
    final controller = TextEditingController(text: _config.custom[index].name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(controller: controller, autofocus: true),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    final list = List<CustomIcon>.of(_config.custom);
    final old = list[index];
    list[index] = CustomIcon(
      id: old.id,
      name: name,
      target: old.target,
      fromFile: old.fromFile,
    );
    unawaited(_persist(_config.copyWith(custom: list)));
  }

  void _close() => widget.onDone?.call();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _buildHeader(),
                const Divider(height: 1),
                Expanded(
                  child: DropTarget(
                    onDragEntered: (_) => setState(() => _dragging = true),
                    onDragExited: (_) => setState(() => _dragging = false),
                    onDragDone: (detail) {
                      setState(() => _dragging = false);
                      unawaited(
                        _addDroppedPaths(
                          detail.files.map((f) => f.path).toList(),
                        ),
                      );
                    },
                    child: Stack(
                      children: <Widget>[
                        Positioned.fill(child: _buildBody()),
                        if (_dragging)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: Container(
                                margin: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.06),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.55),
                                    width: 2,
                                  ),
                                ),
                                alignment: Alignment.center,
                                child: const Text(
                                  '松手即可加入启动台（支持多个文件 / 文件夹）',
                                  style: TextStyle(fontSize: 13),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                _buildFooter(),
              ],
            ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            '图标展示方式',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            '选择启动台里显示哪些图标。两种模式各自独立，随时可以切换回来。',
            style: TextStyle(fontSize: 12.5, color: Colors.white.withValues(alpha: 0.6)),
          ),
          const SizedBox(height: 16),
          SegmentedButton<IconSourceMode>(
            segments: const <ButtonSegment<IconSourceMode>>[
              ButtonSegment<IconSourceMode>(
                value: IconSourceMode.scan,
                label: Text('自动扫描'),
                icon: Icon(Icons.auto_awesome_rounded, size: 17),
              ),
              ButtonSegment<IconSourceMode>(
                value: IconSourceMode.manual,
                label: Text('手动添加'),
                icon: Icon(Icons.playlist_add_rounded, size: 17),
              ),
            ],
            selected: <IconSourceMode>{_config.mode},
            onSelectionChanged: (selection) => _setMode(selection.first),
          ),
          const SizedBox(height: 12),
          Text(
            _config.mode == IconSourceMode.scan
                ? '自动扫描：枚举开始菜单中的全部已安装应用，共 100+ 项。'
                : '手动添加：只显示下面这个列表中的图标，顺序即启动台中的顺序。',
            style: TextStyle(
              fontSize: 12.5,
              color: Colors.white.withValues(alpha: 0.72),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_config.mode == IconSourceMode.scan) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              Icons.auto_awesome_rounded,
              size: 44,
              color: Colors.white.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 14),
            Text(
              '当前使用自动扫描',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.75)),
            ),
            const SizedBox(height: 6),
            Text(
              '切到「手动添加」即可自行挑选图标',
              style: TextStyle(
                fontSize: 12.5,
                color: Colors.white.withValues(alpha: 0.45),
              ),
            ),
          ],
        ),
      );
    }

    if (_config.custom.isEmpty) {
      return Center(
        child: Text(
          '还没有添加任何图标，点下方按钮开始添加',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
        ),
      );
    }

    return Scrollbar(
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: _config.custom.length,
        itemBuilder: (context, index) {
          final icon = _config.custom[index];
          return Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              leading: CircleAvatar(
                radius: 17,
                backgroundColor: Colors.white.withValues(alpha: 0.1),
                child: Text(
                  '${index + 1}',
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
              title: Text(icon.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                icon.target,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  IconButton(
                    tooltip: '上移',
                    icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 19),
                    onPressed: index == 0 ? null : () => _move(index, -1),
                  ),
                  IconButton(
                    tooltip: '下移',
                    icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 19),
                    onPressed: index == _config.custom.length - 1
                        ? null
                        : () => _move(index, 1),
                  ),
                  IconButton(
                    tooltip: '重命名',
                    icon: const Icon(Icons.edit_rounded, size: 17),
                    onPressed: () => _rename(index),
                  ),
                  IconButton(
                    tooltip: '移除',
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    onPressed: () => _remove(index),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildFooter() {
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Row(
        children: <Widget>[
          FilledButton.icon(
            onPressed: _config.mode == IconSourceMode.manual
                ? () => unawaited(_addFromFile())
                : null,
            icon: const Icon(Icons.folder_open_rounded, size: 18),
            label: const Text('浏览文件…'),
          ),
          const SizedBox(width: 10),
          OutlinedButton.icon(
            onPressed: _config.mode == IconSourceMode.manual
                ? () => unawaited(_addFromInstalled())
                : null,
            icon: const Icon(Icons.apps_rounded, size: 18),
            label: const Text('从已安装应用添加'),
          ),
          const SizedBox(width: 14),
          if (_saving)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (_status != null)
            Text(
              _status!,
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withValues(alpha: 0.55),
              ),
            ),
          const Spacer(),
          TextButton(onPressed: _close, child: const Text('完成')),
        ],
      ),
    );
  }
}

/// 从自动扫描到的应用里挑选。
class _AppPickerDialog extends StatefulWidget {
  const _AppPickerDialog({required this.apps, required this.already});

  final List<rust.AppEntry> apps;
  final List<CustomIcon> already;

  @override
  State<_AppPickerDialog> createState() => _AppPickerDialogState();
}

class _AppPickerDialogState extends State<_AppPickerDialog> {
  final TextEditingController _search = TextEditingController();
  final Set<String> _selected = <String>{};
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.already.map((e) => e.id).toSet();
    final filtered = widget.apps
        .where((a) => !existing.contains(a.id))
        .where((a) => _query.isEmpty || a.name.toLowerCase().contains(_query))
        .toList();

    return AlertDialog(
      title: const Text('从已安装应用添加'),
      content: SizedBox(
        width: 480,
        height: 460,
        child: Column(
          children: <Widget>[
            TextField(
              controller: _search,
              autofocus: true,
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search_rounded, size: 18),
                hintText: '搜索应用',
              ),
              onChanged: (value) =>
                  setState(() => _query = value.trim().toLowerCase()),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(child: Text('没有匹配的应用'))
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final app = filtered[index];
                        final checked = _selected.contains(app.id);
                        return CheckboxListTile(
                          dense: true,
                          value: checked,
                          title: Text(
                            app.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onChanged: (value) => setState(() {
                            if (value == true) {
                              _selected.add(app.id);
                            } else {
                              _selected.remove(app.id);
                            }
                          }),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.pop(
                    context,
                    widget.apps.where((a) => _selected.contains(a.id)).toList(),
                  ),
          child: Text('添加 ${_selected.length} 个'),
        ),
      ],
    );
  }
}
