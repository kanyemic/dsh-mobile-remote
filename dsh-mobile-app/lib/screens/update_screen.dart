import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../api.dart';
import '../app_updates.dart';

class UpdateScreen extends StatefulWidget {
  const UpdateScreen({super.key, this.apiClient, this.manifestUrl});
  final Api? apiClient;
  final String? manifestUrl;
  @override
  State<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends State<UpdateScreen> {
  Api get client => widget.apiClient ?? api;
  Map<String, dynamic> status = {};
  bool busy = false;
  bool checkingSelf = false;
  String message = '', appVersion = '', downloadedPath = '';
  String selfMessage = '';
  double? progress;
  PairedAppRelease? release;
  PairedAppRelease? selfRelease;
  int _installedBuild = 0;
  Timer? poll;

  @override
  void initState() {
    super.initState();
    unawaited(
      PackageInfo.fromPlatform()
          .then((info) {
            if (mounted) {
              setState(() {
                appVersion = '${info.version}+${info.buildNumber}';
                _installedBuild = int.tryParse(info.buildNumber) ?? 0;
              });
              unawaited(checkSelfUpdate(silent: true));
            }
          })
          .catchError((_) {}),
    );
    unawaited(refresh());
    poll = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!busy) unawaited(refresh());
    });
  }

  Future<void> checkSelfUpdate({bool silent = false}) async {
    if (checkingSelf) return;
    setState(() {
      checkingSelf = true;
      if (!silent) selfMessage = '';
    });
    try {
      final next = await fetchSelfUpdateRelease(
        client,
        manifestUrl: widget.manifestUrl ?? defaultSelfUpdateManifestUrl,
      );
      if (!mounted) return;
      setState(() {
        selfRelease = next;
        selfMessage = next.build > _installedBuild
            ? '发现新版本 v${next.version}+${next.build}'
            : '当前客户端已是最新版本';
      });
    } catch (error) {
      if (!mounted) return;
      if (!silent) {
        setState(() => selfMessage = '检查自更新失败：$error');
      }
    } finally {
      if (mounted) setState(() => checkingSelf = false);
    }
  }

  Future<void> installSelfApp() async {
    final target = selfRelease;
    if (target == null) return;
    await act(() async {
      final path = await downloadPairedApp(
        client,
        target,
        onProgress: (received, total) {
          if (mounted) setState(() => progress = received / total);
        },
      );
      final result = await launchAppInstaller(path, target);
      if (mounted) {
        setState(() {
          message = updateMessage(result);
          selfMessage = updateMessage(result);
        });
      }
    });
  }

  @override
  void dispose() {
    poll?.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    try {
      final next = await client.getJson('/api/release-update/status');
      if (mounted) setState(() => status = next);
    } catch (error) {
      if (mounted) {
        setState(
          () => message = updateMessage(
            error is ApiException ? error.code : '更新服务暂不可用',
          ),
        );
      }
    }
  }

  Future<void> act(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = '';
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(
          () => message = updateMessage(
            error is ApiException ? error.code : error.toString(),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          progress = null;
        });
      }
    }
  }

  Future<void> operation(String name, Map<String, dynamic> body) async {
    final value = await client.postJson(
      '/api/release-update/$name',
      body,
      timeout: const Duration(minutes: 8),
    );
    if (mounted) setState(() => status = value);
  }

  Future<void> installPlugin() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('安装电脑端插件更新'),
        content: Text(
          status['restartMode'] == 'supervised'
              ? '更新将停止并重新启动电脑端服务。请先完成正在运行的任务。'
              : '更新需要退出并重新启动电脑端 DSH。请先保存工作、结束运行中的任务，再关闭电脑端 DSH。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('准备安装'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await act(
        () => operation('install', {
          'confirmed': true,
          'digest': (status['candidate'] as Map?)?['digest'],
        }),
      );
    }
  }

  Future<void> installApp() async {
    await act(() async {
      release ??= PairedAppRelease.fromJson(
        await client.getJson('/api/release-update/app-info'),
      );
      if (downloadedPath.isEmpty) {
        downloadedPath = await downloadPairedApp(
          client,
          release!,
          onProgress: (received, total) {
            if (mounted) setState(() => progress = received / total);
          },
        );
      }
      final result = await launchAppInstaller(downloadedPath, release!);
      if (mounted) setState(() => message = updateMessage(result));
    });
  }

  @override
  Widget build(BuildContext context) {
    final candidate = status['candidate'] as Map?;
    final logs = status['logs'] as List? ?? [];
    final phase = '${status['phase'] ?? 'idle'}';
    const phases = {
      'idle': '尚未检查',
      'checking': '检查中',
      'available': '检查完成',
      'downloading': '下载中',
      'staged': '更新包已校验',
      'awaiting-restart': '等待电脑端重启',
      'awaiting-exit': '等待电脑端退出',
      'awaiting-start': '插件已安装，请启动电脑端',
      'installing': '安装中',
      'plugin-ready': '电脑端插件已生效',
      'rolled-back': '已恢复旧版本',
      'recovery-required': '需要在电脑端恢复安装',
      'failed': '更新未完成',
    };
    final selfHasUpdate =
        selfRelease != null && selfRelease!.build > _installedBuild;
    return Scaffold(
      appBar: AppBar(title: const Text('检查更新')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '客户端直连自更新',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text('当前版本：App ${appVersion.isEmpty ? "…" : appVersion}'),
                  if (selfRelease != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      '最新可用：v${selfRelease!.version}+${selfRelease!.build} · '
                      '${(selfRelease!.size / (1024 * 1024)).toStringAsFixed(1)} MB',
                    ),
                    if (selfRelease!.notes != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        selfRelease!.notes!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                  if (selfMessage.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      selfMessage,
                      style: TextStyle(
                        color: selfHasUpdate
                            ? Theme.of(context).colorScheme.primary
                            : null,
                        fontWeight: selfHasUpdate ? FontWeight.w600 : null,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  if (selfHasUpdate)
                    FilledButton.icon(
                      key: const ValueKey('self-update-install-btn'),
                      onPressed: busy ? null : installSelfApp,
                      icon: const Icon(Icons.system_update_alt),
                      label: Text(
                        '立即下载并覆盖更新 (v${selfRelease!.version}+${selfRelease!.build})',
                      ),
                    ),
                  if (selfHasUpdate) const SizedBox(height: 8),
                  OutlinedButton(
                    key: const ValueKey('self-update-check-btn'),
                    onPressed: (busy || checkingSelf)
                        ? null
                        : () => checkSelfUpdate(silent: false),
                    child: Text(checkingSelf ? '正在检查…' : '检查客户端新版'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'App $appVersion · 电脑插件 ${status['currentVersion'] ?? client.pluginVersion}',
          ),
          const SizedBox(height: 16),
          Text(phases[phase] ?? phase),
          if (candidate != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '候选插件 ${candidate['version']} · 配对 App ${candidate['appVersionName']}+${candidate['appVersionCode']}',
              ),
            ),
          FilledButton(
            onPressed: busy ? null : () => act(() => operation('check', {})),
            child: const Text('检查更新'),
          ),
          if (candidate?['available'] == true)
            OutlinedButton(
              onPressed: busy
                  ? null
                  : () => act(
                      () => operation('stage', {
                        'confirmed': true,
                        'digest': candidate!['digest'],
                      }),
                    ),
              child: const Text('下载并准备更新'),
            ),
          if (phase == 'staged')
            OutlinedButton(
              onPressed: busy ? null : installPlugin,
              child: const Text('安装电脑端插件'),
            ),
          if (phase == 'plugin-ready')
            OutlinedButton(
              onPressed: busy ? null : installApp,
              child: const Text('下载并安装配对 App'),
            ),
          if (busy) LinearProgressIndicator(value: progress),
          if (message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(message),
            ),
          const SizedBox(height: 16),
          if (logs.isNotEmpty) const Text('更新记录'),
          ...logs.reversed
              .take(20)
              .map(
                (row) => Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    updateMessage((row as Map)['code']),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
