import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/app_updates.dart';
import 'package:dsh_mobile_app/screens/settings_screen.dart';
import 'package:dsh_mobile_app/screens/update_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const certSha =
      '86bd605c2d61ce64d49b6eaec0f3dec6fbe55913cf26667969743565e8240bdf';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('buildSelfUpdateManifestUri 附带防缓存时间戳并解析 apkUrl/notes', () {
    final uri = buildSelfUpdateManifestUri(cacheBusterMs: 123456);
    expect(uri.toString(), 'https://dsh.kystation.cn/download/app-update.json?t=123456');

    final release = PairedAppRelease.fromJson({
      'packageName': 'com.dsh.remote',
      'versionName': '3.2.4.9',
      'versionCode': 109,
      'size': 1024,
      'sha256': 'a' * 64,
      'certificateSha256': certSha,
      'apkUrl': 'https://dsh.kystation.cn/download/app.apk',
      'notes': '打开即聊 + 自更新',
    });
    expect(release.apkUrl, 'https://dsh.kystation.cn/download/app.apk');
    expect(release.notes, '打开即聊 + 自更新');
  });

  test('fetchSelfUpdateRelease 与 downloadPairedApp 直连下载并校验 SHA-256', () async {
    final payload = utf8.encode('fake-apk-bytes-v102');
    final digest = sha256.convert(payload).toString();
    final tempRoot = await Directory.systemTemp.createTemp('dsh-self-update-');
    addTearDown(() => tempRoot.delete(recursive: true));

    final client = Api(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/app-update.json')) {
          return http.Response(
            jsonEncode({
              'packageName': 'com.dsh.remote',
              'versionName': '3.2.4.2',
              'versionCode': 102,
              'size': payload.length,
              'sha256': digest,
              'certificateSha256': certSha,
              'apkUrl': 'https://dsh.kystation.cn/download/test.apk',
              'notes': '修复与优化',
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (request.url.path.endsWith('/test.apk')) {
          return http.Response.bytes(payload, 200);
        }
        return http.Response('not found', 404);
      }),
    );

    final release = await fetchSelfUpdateRelease(client);
    expect(release.build, 102);

    final progressValues = <double>[];
    final path = await downloadPairedApp(
      client,
      release,
      tempDirProvider: () async => tempRoot,
      onProgress: (r, t) => progressValues.add(r / t),
    );
    expect(File(path).existsSync(), isTrue);
    expect(File(path).readAsBytesSync(), payload);
    expect(progressValues.last, 1.0);

    final badRelease = PairedAppRelease.fromJson({
      'packageName': 'com.dsh.remote',
      'versionName': '3.2.4.2',
      'versionCode': 102,
      'size': payload.length,
      'sha256': '0' * 64,
      'certificateSha256': certSha,
      'apkUrl': 'https://dsh.kystation.cn/download/test.apk',
    });
    await expectLater(
      downloadPairedApp(
        client,
        badRelease,
        tempDirProvider: () async => tempRoot,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  testWidgets('UpdateScreen 自动识别新版并展示覆盖更新按钮', (tester) async {
    PackageInfo.setMockInitialValues(
      appName: 'DSH Remote',
      packageName: 'com.dsh.remote',
      version: '3.2.4.1',
      buildNumber: '101',
      buildSignature: '',
    );
    var remoteCode = 105;
    final client = Api(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/app-update.json')) {
          return http.Response(
            jsonEncode({
              'packageName': 'com.dsh.remote',
              'versionName': '3.2.4.5',
              'versionCode': remoteCode,
              'size': 50 * 1024 * 1024,
              'sha256': 'b' * 64,
              'certificateSha256': certSha,
              'apkUrl': 'https://dsh.kystation.cn/download/next.apk',
              'notes': '支持热自更新',
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return http.Response(jsonEncode({'ok': true, 'phase': 'idle', 'logs': []}), 200);
      }),
    )..baseUrl = 'https://dsh.kystation.cn';

    await tester.pumpWidget(
      MaterialApp(home: UpdateScreen(apiClient: client)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('self-update-install-btn')), findsOneWidget);
    expect(find.textContaining('v3.2.4.5+105'), findsWidgets);
    expect(find.text('支持热自更新'), findsOneWidget);

    remoteCode = 101;
    await tester.tap(find.byKey(const ValueKey('self-update-check-btn')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('self-update-install-btn')), findsNothing);
    expect(find.text('当前客户端已是最新版本'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('SettingsScreen 始终展示检查更新入口', (tester) async {
    PackageInfo.setMockInitialValues(
      appName: 'DSH Remote',
      packageName: 'com.dsh.remote',
      version: '3.2.4.1',
      buildNumber: '101',
      buildSignature: '',
    );
    api.releaseUpdatesSupported = false;
    final store = AppStore();
    await store.loadPrefs();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsScreen(store: store, onReconfigure: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('检查更新'), findsOneWidget);
  });
}
