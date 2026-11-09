import 'dart:async';

import 'package:antgrid/demo/demo_identity.dart'
    show kDemoEntryLabel, kDemoMachineName;
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/widgets/ab_button.dart';
import 'package:antgrid/design/widgets/ab_inline_banner.dart';
import 'package:antgrid/design/widgets/ab_loading.dart';
import 'package:antgrid/models/memory.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/account_machines.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/providers/demo_mode.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/eager_control_planes.dart';
import 'package:antgrid/providers/memory.dart';
import 'package:antgrid/providers/recent_agents.dart';
import 'package:antgrid/providers/relay_connection.dart';
import 'package:antgrid/providers/scheduler.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/screens/memory_screen.dart';
import 'package:antgrid/services/account_agents_api.dart' show InventoryAgent;
import 'package:antgrid/storage/recent_agents_store.dart';
import 'package:antgrid/widgets/machine_selector_button.dart';
import 'package:antgrid/widgets/memory/memory_edit_form.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show CryptoService;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FixedRecents extends RecentAgentsNotifier {
  _FixedRecents(this.seed);
  final List<RecentAgent> seed;
  @override
  List<RecentAgent> build() => seed;
  void add(RecentAgent a) => state = [...state, a];
}

RecentAgent _recent(String id, String name, DateTime lastConnectedAt) =>
    RecentAgent(
      agentDeviceId: id,
      agentLabel: name,
      agentEd25519Pubkey: 'pub',
      relayUrl: 'wss://relay',
      pairedAt: DateTime.utc(2026),
      lastConnectedAt: lastConnectedAt,
      hostMachineName: name,
    );

final _t0 = DateTime.utc(2026, 1, 1);

final _record = <String, dynamic>{
  'id': 'memory-1',
  'content': 'A retained finding',
  'memory_type': 'note',
  'scope': 'project',
  'project_id': 'antgrid',
  'evidence': <String>[],
  'source': {'actor': 'app'},
  'lifecycle': 'active',
  'created_at': 1,
  'updated_at': 1,
};

Map<String, dynamic> _enabledStatus({List<Object> sessions = const []}) => {
  'available': true,
  'enabled': true,
  'paused': false,
  'project_paused': false,
  'search_status': 'ready',
  'recovery_status': 'ready',
  'pending_operations': 0,
  'sessions_without_memory': sessions,
};

Future<Map<String, dynamic>> _healthy(Map<String, dynamic> request) async =>
    switch (request['op']) {
      'status' => _enabledStatus(),
      'get' => {'record': _record},
      'projects' => {
        'projects': [
          {'project_id': 'antgrid', 'label': 'antgrid', 'memories': 1},
        ],
        'memories': 1,
      },
      _ => {
        'results': [_record],
        'has_more': false,
        'total': 1,
      },
    };

typedef _Connected = NotifierProvider<ValueController<bool>, bool>;

class _Rig {
  _Rig(this.container);
  final ProviderContainer container;
  final requests = <String, List<Map<String, dynamic>>>{};
  final connected = <String, _Connected>{};

  int count(String id, String op) =>
      (requests[id] ?? const []).where((r) => r['op'] == op).length;

  void setConnected(String id, bool value) =>
      container.read(connected[id]!.notifier).set(value);
}

class _Context {
  late BuildContext value;
}

/// [handlers] answers per machine id; a machine without one answers healthy.
Future<(_Rig, _Context)> _mount(
  WidgetTester tester, {
  List<RecentAgent> recents = const [],
  Map<String, bool> connected = const {},
  Map<String, MemoryRequest> handlers = const {},
  Size size = const Size(390, 844),
  bool demo = false,

  /// False leaves this machine's Memory unanswered here, so a step into the
  /// sample reaches the sample's own store.
  bool answerLocal = true,
  Future<List<InventoryAgent>>? pendingAccounts,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // The substituted test font makes the compact selector wider than its box;
  // this file pins machine routing, not geometry.
  final onError = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) return;
    onError?.call(details);
  };
  addTearDown(() => FlutterError.onError = onError);

  final registry = ProjectSessionRegistry(
    localCap: 10,
    relayCap: 30,
    onEvict: (_) async {},
  );
  late final _Rig rig;
  final ids = {
    ...connected.keys,
    for (final r in recents) r.agentDeviceId,
  };
  final connectedProviders = {
    for (final id in ids)
      id: _Connected(() => ValueController(connected[id] ?? true)),
  };
  MemoryRequest recorder(String key, MemoryRequest inner) => (request) {
    rig.requests.putIfAbsent(key, () => []).add(request);
    return inner(request);
  };
  final container = ProviderContainer(
    overrides: [
      projectSessionRegistryProvider.overrideWith(
        () => ProjectSessionRegistryController(registry),
      ),
      selectedRegistrationIdProvider.overrideWithValue('active-project'),
      workbenchSurfaceProvider.overrideWith(
        () => ValueController(WorkbenchSurface.memory),
      ),
      eagerControlPlanesEnabledProvider.overrideWithValue(false),
      if (demo) demoModeProvider.overrideWith(() => ValueController(true)),
      if (!demo) ...[
        recentAgentsProvider.overrideWith(() => _FixedRecents(recents)),
        accountAgentsProvider.overrideWith(
          (ref) => pendingAccounts ?? Future.value(const []),
        ),
        localDeviceUuidProvider.overrideWith((ref) async => null),
      ],
      relayConnectionManagerProvider.overrideWithValue(
        MachineConnectionManager(crypto: CryptoService()),
      ),
      for (final id in ids) ...[
        machineConnectedProvider(
          id,
        ).overrideWith((ref) => ref.watch(connectedProviders[id]!)),
        controlPlaneClientForProvider(id).overrideWith((ref) async => null),
        memoryRequestProvider(
          MemoryTarget.machine(machineId: id),
        ).overrideWithValue(recorder(id, handlers[id] ?? _healthy)),
      ],
      if (answerLocal && !demo)
        memoryRequestProvider(
          const MemoryTarget.machine(),
        ).overrideWithValue(recorder('local', handlers['local'] ?? _healthy)),
    ],
  );
  addTearDown(container.dispose);
  rig = _Rig(container)..connected.addAll(connectedProviders);
  final context = _Context();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAbTheme(),
        home: Builder(
          builder: (c) {
            context.value = c;
            return const MemorySurface();
          },
        ),
      ),
    ),
  );
  return (rig, context);
}

MemoryScreen _screen(WidgetTester tester) =>
    tester.widget<MemoryScreen>(find.byType(MemoryScreen));

void main() {
  final phones = TargetPlatformVariant({
    TargetPlatform.iOS,
    TargetPlatform.android,
  });

  testWidgets('a phone with no machines offers the sample and dials nothing', (
    tester,
  ) async {
    final (rig, _) = await _mount(tester);
    await tester.pumpAndSettle();
    expect(find.text('Connect a machine to manage memories'), findsOneWidget);
    expect(find.text(kDemoEntryLabel), findsOneWidget);
    expect(rig.requests, isEmpty);
    expect(find.byType(AbInlineBanner), findsNothing);
    expect(find.byType(MemoryScreen), findsNothing);
    expect(find.byType(MachineSelectorButton), findsNothing);
  }, variant: phones);

  testWidgets('a phone still loading its inventory shows a spinner only', (
    tester,
  ) async {
    final pending = Completer<List<InventoryAgent>>();
    await _mount(tester, pendingAccounts: pending.future);
    await tester.pump();
    expect(find.byType(AbLoading), findsOneWidget);
    expect(find.text('Connect a machine to manage memories'), findsNothing);
  }, variant: phones);

  testWidgets('the newest recent machine is the default and is latched', (
    tester,
  ) async {
    final (rig, _) = await _mount(
      tester,
      recents: [
        _recent('m1', 'Laptop', _t0),
        _recent('m2', 'Studio', _t0.add(const Duration(hours: 1))),
      ],
    );
    await tester.pumpAndSettle();
    expect(_screen(tester).target.machineId, 'm2');
    expect(find.widgetWithText(AbButton, 'Studio'), findsOneWidget);
    expect(rig.container.read(machinePickProvider), 'm2');
  }, variant: phones);

  testWidgets('a recent added while mounted does not retarget the screen', (
    tester,
  ) async {
    final (rig, _) = await _mount(
      tester,
      recents: [
        _recent('m1', 'Laptop', _t0),
        _recent('m2', 'Studio', _t0.add(const Duration(hours: 1))),
      ],
    );
    await tester.pumpAndSettle();
    final first = tester.state(find.byType(MemoryScreen));

    (rig.container.read(recentAgentsProvider.notifier) as _FixedRecents).add(
      _recent('m3', 'Tablet', DateTime.now().toUtc()),
    );
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(MemoryScreen)), same(first));
    expect(_screen(tester).target.machineId, 'm2');
  }, variant: phones);

  testWidgets('picking the other machine retargets, writes the pick and '
      'clears the project filter', (tester) async {
    final (rig, ctx) = await _mount(
      tester,
      recents: [
        _recent('m1', 'Laptop', _t0),
        _recent('m2', 'Studio', _t0.add(const Duration(hours: 1))),
      ],
    );
    await tester.pumpAndSettle();
    openMemoryScreen(
      ctx.value,
      const MemoryTarget.machine(machineId: 'm2'),
      projectId: 'p1',
    );
    await tester.pumpAndSettle();
    expect(_screen(tester).initialProjectId, 'p1');

    await tester.tap(find.widgetWithText(AbButton, 'Studio'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Laptop'));
    await tester.pumpAndSettle();

    expect(_screen(tester).target.machineId, 'm1');
    expect(_screen(tester).initialProjectId, isNull);
    expect(rig.container.read(machinePickProvider), 'm1');
    expect(rig.container.read(schedulerTargetProvider), 'm1');
  }, variant: phones);

  testWidgets('re-picking the shown machine keeps the screen and its filter', (
    tester,
  ) async {
    final (_, ctx) = await _mount(
      tester,
      recents: [
        _recent('m1', 'Laptop', _t0),
        _recent('m2', 'Studio', _t0.add(const Duration(hours: 1))),
      ],
    );
    await tester.pumpAndSettle();
    openMemoryScreen(
      ctx.value,
      const MemoryTarget.machine(machineId: 'm1'),
      projectId: 'p1',
    );
    await tester.pumpAndSettle();
    final first = tester.state(find.byType(MemoryScreen));

    await tester.tap(find.widgetWithText(AbButton, 'Laptop'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Laptop').last);
    await tester.pumpAndSettle();

    expect(tester.state(find.byType(MemoryScreen)), same(first));
    expect(_screen(tester).initialProjectId, 'p1');
  }, variant: phones);

  testWidgets('the sample project shows its own memories on its own machine', (
    tester,
  ) async {
    final (rig, _) = await _mount(tester, demo: true);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Coupon codes are case-insensitive'),
      findsOneWidget,
    );
    expect(find.widgetWithText(AbButton, kDemoMachineName), findsOneWidget);
    expect(find.textContaining('unavailable'), findsNothing);
    expect(rig.container.exists(accountAgentsProvider), isFalse);
    expect(rig.requests, isEmpty);
  }, variant: phones);

  testWidgets('the no-machine sample button opens the sample on Memory', (
    tester,
  ) async {
    final (rig, _) = await _mount(tester, answerLocal: false);
    await tester.pumpAndSettle();
    await tester.tap(find.text(kDemoEntryLabel));
    await tester.pumpAndSettle();
    expect(rig.container.read(demoModeProvider), isTrue);
    expect(
      rig.container.read(workbenchSurfaceProvider),
      WorkbenchSurface.memory,
    );
    expect(
      find.textContaining('Coupon codes are case-insensitive'),
      findsOneWidget,
    );
  }, variant: phones);

  testWidgets('an offline machine that never answers reads as offline', (
    tester,
  ) async {
    await _mount(
      tester,
      recents: [_recent('m1', 'Laptop', _t0)],
      connected: {'m1': false},
      handlers: {
        'm1': (_) async => throw TimeoutException('dial'),
      },
    );
    await tester.pumpAndSettle();
    expect(find.text('Laptop is offline'), findsOneWidget);
    expect(find.text('Reconnect and retry'), findsOneWidget);
  }, variant: phones);

  testWidgets('FORBIDDEN on a connected remote explains remote access', (
    tester,
  ) async {
    await _mount(
      tester,
      recents: [_recent('m1', 'Laptop', _t0)],
      handlers: {
        'm1': (_) async =>
            throw const MemoryException('FORBIDDEN', 'not allowed'),
      },
    );
    await tester.pumpAndSettle();
    expect(find.text('Memory unavailable'), findsOneWidget);
    expect(find.textContaining('Remote access is off on Laptop'), findsOneWidget);
    expect(find.widgetWithText(AbButton, 'Retry'), findsOneWidget);
    expect(find.text('Reconnect and retry'), findsNothing);
  }, variant: phones);

  testWidgets('a record opened on a phone says when its machine drops', (
    tester,
  ) async {
    final (rig, _) = await _mount(
      tester,
      recents: [_recent('m1', 'Laptop', _t0)],
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('A retained finding'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Back to Memory'), findsOneWidget);
    const banner =
        "Laptop is offline. Changes can't be saved until it reconnects.";
    expect(find.text(banner), findsNothing);

    rig.setConnected('m1', false);
    await tester.pumpAndSettle();
    expect(find.text(banner), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('turning Memory on for a remote machine sends settings there and '
      'then offers the restart review', (tester) async {
    var enabled = false;
    final (rig, _) = await _mount(
      tester,
      recents: [_recent('m1', 'Laptop', _t0)],
      handlers: {
        'm1': (request) async {
          switch (request['op']) {
            case 'status':
              return enabled
                  ? _enabledStatus(
                      sessions: [
                        {'project_id': 'p', 'session_id': 's', 'name': 'One'},
                      ],
                    )
                  : {'available': true, 'enabled': false};
            case 'settings':
              enabled = true;
              return {};
            default:
              return _healthy(request);
          }
        },
      },
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Stored only on Laptop'), findsOneWidget);

    await tester.tap(find.text('Turn on Memory'));
    await tester.pumpAndSettle();

    expect(
      rig.requests['m1'],
      contains(equals({'op': 'settings', 'enabled': true})),
    );
    expect(rig.requests['local'], isNull);
    expect(
      find.textContaining('1 running session started without Memory'),
      findsOneWidget,
    );
  }, variant: phones);

  testWidgets('reconnecting refreshes the machine but keeps an open edit', (
    tester,
  ) async {
    final (rig, _) = await _mount(
      tester,
      recents: [_recent('m1', 'Laptop', _t0)],
      size: const Size(1280, 820),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.byType(MemoryEditForm), findsOneWidget);
    await tester.enterText(
      find
          .descendant(
            of: find.byType(MemoryEditForm),
            matching: find.byType(EditableText),
          )
          .first,
      'MY TYPED FIX',
    );
    await tester.pump();

    rig.setConnected('m1', false);
    await tester.pumpAndSettle();
    expect(
      find.text("Laptop is offline. Changes can't be saved until it reconnects."),
      findsOneWidget,
    );
    final statuses = rig.count('m1', 'status');
    final gets = rig.count('m1', 'get');

    rig.setConnected('m1', true);
    await tester.pumpAndSettle();

    expect(rig.count('m1', 'status'), statuses + 1);
    expect(rig.count('m1', 'get'), gets);
    expect(
      find.descendant(
        of: find.byType(MemoryEditForm),
        matching: find.byWidgetPredicate(
          (w) => w is EditableText && w.controller.text == 'MY TYPED FIX',
        ),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('a status error while offline is retried when the machine '
      'connects, with no tap', (tester) async {
    var failing = true;
    final (rig, _) = await _mount(
      tester,
      recents: [_recent('m1', 'Laptop', _t0)],
      connected: {'m1': false},
      handlers: {
        'm1': (request) async {
          if (request['op'] == 'status' && failing) {
            throw const MemoryException('NOT_CONNECTED', 'offline');
          }
          return _healthy(request);
        },
      },
    );
    await tester.pumpAndSettle();
    expect(find.text('Laptop is offline'), findsOneWidget);
    final before = rig.count('m1', 'status');

    failing = false;
    rig.setConnected('m1', true);
    await tester.pumpAndSettle();

    expect(rig.count('m1', 'status'), greaterThan(before));
    expect(find.text('Laptop is offline'), findsNothing);
    expect(find.text('A retained finding'), findsWidgets);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('desktop defaults to the local machine without latching a pick', (
    tester,
  ) async {
    final (rig, _) = await _mount(
      tester,
      recents: [_recent('m1', 'Laptop', _t0)],
      size: const Size(1280, 820),
    );
    await tester.pumpAndSettle();
    expect(_screen(tester).target.machineId, isNull);
    expect(find.widgetWithText(AbButton, 'Local machine'), findsOneWidget);

    await tester.tap(find.widgetWithText(AbButton, 'Local machine'));
    await tester.pumpAndSettle();
    expect(find.text('Laptop'), findsOneWidget);
    expect(find.text('Local machine'), findsNWidgets(2));
    expect(rig.container.read(machinePickProvider), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
