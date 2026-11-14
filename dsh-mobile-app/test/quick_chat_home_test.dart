import 'dart:convert';

import 'package:dsh_mobile_app/api.dart';
import 'package:dsh_mobile_app/models.dart';
import 'package:dsh_mobile_app/screens/chat_screen.dart';
import 'package:dsh_mobile_app/screens/home_screen.dart';
import 'package:dsh_mobile_app/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Catalog _catalogWith({
  String agentPreset = 'standard',
  String permissionPreset = 'danger-full-access',
}) =>
    Catalog.fromJson({
      'models': [
        {
          'provider': 'cpa',
          'id': 'deepseek-v4.1-flash-1017',
          'name': 'DeepSeek Flash',
        },
      ],
      'agentPresets': [
        {'id': 'standard', 'name': '标准模式', 'description': ''},
      ],
      'permissionPresets': [
        {'id': 'workspace-write', 'name': '工作区写入', 'description': ''},
        {'id': 'danger-full-access', 'name': '完全访问', 'description': ''},
      ],
      'defaults': {
        'agentPreset': agentPreset,
        'permissionPreset': permissionPreset,
      },
    });

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('buildQuickSessionPayload', () {
    test('默认权限为 danger-full-access 时自动携带 confirmDanger: true', () {
      final store = AppStore()
        ..workspaces = [
          {'id': 'ws-1', 'path': '/home/redmi/workspace', 'title': 'workspace'},
          {'id': 'ws-2', 'path': '/home/redmi/other', 'title': 'other'},
        ]
        ..workspacePath = '/home/redmi/other';
      final payload = buildQuickSessionPayload(
        store: store,
        catalog: _catalogWith(
          agentPreset: 'ptc',
          permissionPreset: 'danger-full-access',
        ),
      );
      expect(payload['preset'], 'ptc');
      expect(payload['cwd'], '/home/redmi/other');
      expect(payload['permissionPreset'], 'danger-full-access');
      expect(payload['confirmDanger'], true);
    });

    test('普通权限不附带 confirmDanger，overrideDir 优先于 store.workspacePath', () {
      final store = AppStore()
        ..workspaces = [
          {'id': 'ws-1', 'path': '/home/redmi/workspace', 'title': 'workspace'},
        ];
      final payload = buildQuickSessionPayload(
        store: store,
        catalog: _catalogWith(permissionPreset: 'workspace-write'),
        overrideDir: '/home/redmi/custom',
      );
      expect(payload['cwd'], '/home/redmi/custom');
      expect(payload['permissionPreset'], 'workspace-write');
      expect(payload.containsKey('confirmDanger'), isFalse);
    });
  });

  group('HomeScreen 打开即聊流程', () {
    testWidgets('首页输入消息直接静默建会话并跳转 ChatScreen 发送', (tester) async {
      final recorded = <Map<String, dynamic>>[];
      var sentText = '';
      var failCreate = false;
      final client = Api(
        client: MockClient((request) async {
          if (request.url.path == '/m/api/sessions' &&
              request.method == 'GET') {
            return http.Response(
              jsonEncode({'ok': true, 'sessions': <Object>[]}),
              200,
            );
          }
          if (request.url.path == '/m/api/sessions' &&
              request.method == 'POST') {
            if (failCreate) {
              return http.Response(
                jsonEncode({'error': 'boom', 'detail': 'create failed'}),
                500,
              );
            }
            recorded.add(jsonDecode(request.body) as Map<String, dynamic>);
            return http.Response(
              jsonEncode({'ok': true, 'sessionId': 'sess-quick-1'}),
              200,
            );
          }
          if (request.url.path == '/m/api/send') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            sentText = body['text'] as String? ?? '';
            return http.Response(
              jsonEncode({'ok': true, 'messageId': 'msg-1'}),
              200,
            );
          }
          if (request.url.path == '/m/api/history') {
            return http.Response(
              jsonEncode({'ok': true, 'events': <Object>[], 'hasMore': false}),
              200,
            );
          }
          if (request.url.path == '/m/api/queue') {
            return http.Response(
              jsonEncode({'ok': true, 'rows': <Object>[]}),
              200,
            );
          }
          if (request.url.path == '/m/api/todos') {
            return http.Response(
              jsonEncode({'ok': true, 'todos': <Object>[]}),
              200,
            );
          }
          if (request.url.path == '/m/api/session-config') {
            return http.Response(
              jsonEncode({'ok': true, 'config': <String, dynamic>{}}),
              200,
            );
          }
          return http.Response(jsonEncode({'ok': true}), 200);
        }),
      )
        ..baseUrl = 'http://quick.test'
        ..path = '/m'
        ..token = '';

      final store = AppStore()
        ..catalog = _catalogWith()
        ..workspaces = [
          {'id': 'ws-1', 'path': '/home/redmi/workspace', 'title': 'workspace'},
        ];
      var newChatRequested = false;
      store.onNewChatRequested = () => newChatRequested = true;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeScreen(
              store: store,
              apiClient: client,
              onOpenSession: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      // 1. 失败时保留草稿
      failCreate = true;
      await tester.enterText(
        find.byKey(const ValueKey('home-quick-composer-input')),
        '先帮我看下日志',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('home-quick-composer-send')));
      await tester.pumpAndSettle();
      expect(recorded, isEmpty);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('home-quick-composer-input')),
            )
            .controller!
            .text,
        '先帮我看下日志',
      );

      // 2. 成功时静默建会话（带 confirmDanger: true）并进 ChatScreen 发送
      failCreate = false;
      await tester.tap(find.byKey(const ValueKey('home-quick-composer-send')));
      await tester.pumpAndSettle();

      expect(recorded, hasLength(1));
      expect(recorded.first['permissionPreset'], 'danger-full-access');
      expect(recorded.first['confirmDanger'], true);
      expect(recorded.first['cwd'], '/home/redmi/workspace');
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(sentText, '先帮我看下日志');

      // 3. ChatScreen 顶部新对话图标可触发返回并聚焦
      await tester.tap(find.byIcon(Icons.add_comment_outlined));
      await tester.pumpAndSettle();
      expect(newChatRequested, isTrue);
      expect(find.byType(HomeScreen), findsOneWidget);
    });
  });
}
