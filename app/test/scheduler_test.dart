import 'dart:convert';

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/widgets/ab_button.dart';
import 'package:antgrid/design/widgets/ab_icon_button.dart';
import 'package:antgrid/design/widgets/ab_prompt_field.dart';
import 'package:antgrid/launcher/host_control_client.dart';
import 'package:antgrid/models/scheduler.dart';
import 'package:antgrid/navigation/nav_controller.dart';
import 'package:antgrid/navigation/nav_location.dart';
import 'package:antgrid/navigation/nav_serialization.dart';
import 'package:antgrid/providers/demo_mode.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/scheduler.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/widgets/projects_drawer.dart';
import 'package:antgrid/screens/scheduler_screen.dart';
import 'package:antgrid/widgets/scheduler/schedule_editor.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show RpcException;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'helpers/demo_harness.dart';
import 'helpers/fake_agent_transport.dart';

final _connection = NotifierProvider<ValueController<bool>, bool>(
  () => ValueController(true),
);

const _settings = <String, dynamic>{
  'id': 'daily',
  'name': 'Daily review',
  'projectId': 'repo',
  'agentId': 'claude',
  'mode': 'terminal',
  'prompt': 'Review the open changes',
  'approvalPolicy': 'default',
  'workspace': 'worktree',
  'baseBranch': 'main',
  'cron': '0 9 * * *',
  'timezone': 'Asia/Kolkata',
  'enabled': true,
  'nextOccurrence': 1800000000000,
};
const _capabilities = <String, dynamic>{
  'supported': true,
  'timezone': 'Asia/Kolkata',
  'agents': [
    {
      'agentId': 'claude',
      'modes': ['terminal', 'chat'],
    },
  ],
};
const _project = {
  'projectId': 'repo',
  'label': 'Antgrid',
  'isGitRepository': true,
};

class _Host {
  final calls = <({String method, Map<String, dynamic> params})>[];
  bool offline = false;
  String? warning;
  bool activeRun = true;
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    calls.add((method: method, params: params));
    if (offline) throw StateError('Disconnected');
    return switch (method) {
      'scheduler.capabilities' => {
        ..._capabilities,
        if (warning != null) 'error': warning,
      },
      'scheduler.list' => {
        'schedules': [_settings],
        'projects': [_project],
      },
      'scheduler.preview' => {
        'occurrences': List.generate(5, (i) => 1800000000000 + i * 86400000),
      },
      'scheduler.runs' => {
        'runs': [
          if (activeRun)
            {
              'id': 'run',
              'scheduleId': 'daily',
              'projectId': 'repo',
              'status': 'needs-input',
              'trigger': 'cron',
              'occurrenceAt': 1800000000000,
              'startedAt': 1800000000100,
              'sessionId': 'conversation',
              'reason': 'Permission required',
            },
        ],
      },
      _ => {},
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('scheduler deep link and history work without a selected project', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    const loc = NavLocation(surface: WorkbenchSurface.scheduler);
    expect(navLocationToUri(loc).toString(), 'antgrid://nav/scheduler');
    expect(navLocationFromUri(navLocationToUri(loc)), loc);
    final nav = c.read(navControllerProvider.notifier);
    nav.commit(const NavLocation(surface: WorkbenchSurface.newSession));
    nav.applyDeepLink(loc);
    nav.back();
    expect(c.read(workbenchSurfaceProvider), WorkbenchSurface.newSession);
    nav.forward();
    expect(c.read(workbenchSurfaceProvider), WorkbenchSurface.scheduler);
  });

  test(
    'demo scheduler rejects requests before touching host or account providers',
    () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      c.read(demoModeProvider.notifier).set(true);
      expect(c.read(schedulerMachinesProvider), isEmpty);
      await expectLater(
        c.read(schedulerRequestProvider)('scheduler.create', {
          'schedule': _settings,
        }),
        throwsStateError,
      );
    },
  );

  test(
    'loopback uses the owner-token scheduler request and validates result',
    () async {
      final client = HostControlClient(
        port: 1234,
        token: 'owner',
        httpClient: MockClient((req) async {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          expect(req.url.host, '127.0.0.1');
          expect(req.headers['authorization'], 'Bearer owner');
          expect(body['type'], 'scheduler:request');
          expect(body['method'], 'scheduler.preview');
          expect(body['params'], {'cron': '0 9 * * *', 'timezone': 'UTC'});
          return http.Response(
            jsonEncode({
              'id': body['id'],
              'ok': true,
              'type': 'scheduler:request',
              'result': {
                'occurrences': [1800000000000],
              },
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);
      expect(
        await client.schedulerRequest('scheduler.preview', {
          'cron': '0 9 * * *',
          'timezone': 'UTC',
        }),
        {
          'occurrences': [1800000000000],
        },
      );
    },
  );

  test(
    'run states preserve needs input and only active turns occupy a slot',
    () {
      final run = ScheduleRun.fromJson({
        'id': 'r',
        'scheduleId': 's',
        'projectId': 'p',
        'status': 'needs-input',
        'trigger': 'cron',
        'occurrenceAt': 1800000000000,
        'startedAt': 1800000000000,
      });
      expect(run.active, isTrue);
      expect(run.occurrenceAt.isUtc, isTrue);
      expect(schedulerStatus(run.status), 'Needs input');
      expect(
        AgentSchedule.fromJson(
          _settings,
        ).nextOccurrence!.millisecondsSinceEpoch,
        1800000000000,
      );
    },
  );

  test('remote scheduler operations use the generic machine RPC', () async {
    final transport = FakeAgentTransport()
      ..requestHandler = (method, params) => {
        'run': {'id': 'r'},
      };
    final client = ControlPlaneClient(transport: transport);
    addTearDown(client.dispose);
    expect(await client.schedulerRequest('scheduler.runNow', {'id': 'daily'}), {
      'run': {'id': 'r'},
    });
    expect(transport.requests.single.method, 'scheduler.runNow');
    expect(transport.requests.single.params, {'id': 'daily'});
  });

  testWidgets('drawer places Scheduler directly below New Session', (
    tester,
  ) async {
    final container = await demoContainer();
    container.read(demoModeProvider.notifier).set(true);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAbTheme(),
          home: const Scaffold(body: ProjectsDrawer()),
        ),
      ),
    );
    await tester.pump();
    final newSession = find.widgetWithText(AbButton, 'New Session');
    final scheduler = find.widgetWithText(AbButton, 'Scheduler');
    expect(newSession, findsOneWidget);
    expect(scheduler, findsOneWidget);
    expect(
      tester.getBottomLeft(newSession).dy,
      lessThan(tester.getTopLeft(scheduler).dy),
    );
  });

  Future<void> pumpScreen(
    WidgetTester tester,
    SchedulerRequest request, {
    Size size = const Size(1100, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider.overrideWith((ref) async => null),
          schedulerMachinesProvider.overrideWithValue(const {
            'local': 'Local machine',
            'remote': 'Laptop',
          }),
          schedulerTargetProvider.overrideWithValue(null),
          schedulerConnectedProvider.overrideWith(
            (ref) => ref.watch(_connection),
          ),
          schedulerRequestProvider.overrideWithValue(request),
        ],
        child: MaterialApp(
          theme: buildAbTheme(),
          home: const Scaffold(body: SchedulerScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
  }

  testWidgets('schedules expose actions and runs show permissions with stop', (
    tester,
  ) async {
    final host = _Host();
    await pumpScreen(tester, host.request);
    expect(find.text('Daily review'), findsOneWidget);
    expect(find.text('Open session'), findsOneWidget);
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is AbIconButton && w.tooltip == 'Actions for Daily review',
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pause'));
    await tester.pumpAndSettle();
    expect(
      host.calls.any(
        (c) =>
            c.method == 'scheduler.update' &&
            c.params['patch']['enabled'] == false,
      ),
      isTrue,
    );
    await tester.tap(find.text('RUNS'));
    await tester.pumpAndSettle();
    expect(find.text('Permission required'), findsOneWidget);
    expect(find.text('Stop run'), findsOneWidget);
    await tester.tap(find.text('Stop run'));
    await tester.pumpAndSettle();
    expect(
      host.calls.any(
        (c) => c.method == 'scheduler.stop' && c.params['id'] == 'run',
      ),
      isTrue,
    );
  });

  testWidgets(
    'five-second polling disables writes when the machine disappears',
    (tester) async {
      final host = _Host()..activeRun = false;
      await pumpScreen(tester, host.request, size: const Size(400, 800));
      host.offline = true;
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      final runNow = tester.widget<AbButton>(
        find.widgetWithText(AbButton, 'Run now'),
      );
      expect(runNow.onTap, isNull);
      expect(find.textContaining('Disconnected'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('connection lifecycle disables writes before the next poll', (
    tester,
  ) async {
    final host = _Host()..activeRun = false;
    await pumpScreen(tester, host.request);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SchedulerScreen)),
    );
    container.read(_connection.notifier).set(false);
    await tester.pump();
    expect(
      tester.widget<AbButton>(find.widgetWithText(AbButton, 'Run now')).onTap,
      isNull,
    );
    expect(
      find.text('Machine disconnected. Writes are disabled.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'ownership cleanup warning keeps supported schedules manageable',
    (tester) async {
      final host = _Host()
        ..activeRun = false
        ..warning = 'Workspace ownership cleanup pending';
      await pumpScreen(tester, host.request);
      expect(find.text('Workspace ownership cleanup pending'), findsOneWidget);
      expect(find.text('Daily review'), findsOneWidget);
      expect(
        tester.widget<AbButton>(find.widgetWithText(AbButton, 'Run now')).onTap,
        isNotNull,
      );
    },
  );

  testWidgets('older bridges show an upgrade message', (tester) async {
    await pumpScreen(
      tester,
      (method, [params = const {}]) async =>
          throw RpcException('E_UNKNOWN_METHOD', 'Unknown method'),
    );
    expect(find.textContaining('Upgrade the target bridge'), findsWidgets);
  });

  testWidgets(
    'editor uses host previews and retains schedule workspace ownership',
    (tester) async {
      final host = _Host();
      final loaded = await SchedulerSnapshot.load(host.request);
      final locked = AgentSchedule.fromJson({
        ..._settings,
        'workspaceCreated': true,
      });
      final snapshot = SchedulerSnapshot(
        capabilities: loaded.capabilities,
        projects: loaded.projects,
        schedules: [locked],
        runs: loaded.runs,
      );
      tester.view.physicalSize = const Size(1000, 1700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var saved = false;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: buildAbTheme(),
            home: Scaffold(
              body: ScheduleEditor(
                snapshot: snapshot,
                request: host.request,
                writable: true,
                schedule: locked,
                onClose: () {},
                onSaved: () => saved = true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Workspace settings locked'), findsOneWidget);
      expect(find.byType(AbPromptField), findsOneWidget);
      expect(find.text('main'), findsOneWidget);
      await tester.tap(find.text('Weekdays'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(host.calls.last.params['cron'], schedulerPresets['Weekdays']);
      await tester.ensureVisible(find.text('Save schedule'));
      await tester.tap(find.text('Save schedule'));
      await tester.pumpAndSettle();
      expect(saved, isTrue);
      final patch = host.calls.last.params['patch'] as Map;
      expect(patch['cron'], '0 9 * * 1-5');
      expect(patch.containsKey('projectId'), isFalse);
      expect(patch.containsKey('workspace'), isFalse);
      expect(patch.containsKey('baseBranch'), isFalse);
    },
  );
}
