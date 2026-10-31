import 'dart:async';

import 'package:antgrid/connection/supervisor_state.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/models/memory.dart';
import 'package:antgrid/providers/control_plane.dart';
import 'package:antgrid/providers/memory.dart';
import 'package:antgrid/providers/supervisor_status.dart';
import 'package:antgrid/screens/memory_screen.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/widgets/memory/memory_record_details.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_agent_transport.dart';
import '../helpers/toast_host.dart';

const _remote = MemoryTarget.machine(machineId: 'm', label: 'Remote');

Map<String, dynamic> _status({String search = 'ready'}) => {
  'available': true,
  'enabled': true,
  'paused': false,
  'project_paused': false,
  'search_status': search,
  'recovery_status': 'ready',
  'pending_operations': 0,
};

final _record = <String, dynamic>{
  'id': 'memory-1',
  'content': 'Original memory',
  'memory_type': 'note',
  'scope': 'project',
  'project_id': 'antgrid',
  'evidence': <String>[],
  'source': {'actor': 'app'},
  'lifecycle': 'active',
  'created_at': 1,
  'updated_at': 1,
};

Map<String, dynamic> _answer(Map<String, dynamic>? p) => switch (p?['op']) {
  'status' => _status(),
  'get' => {'record': _record},
  'save' => {'id': 'memory-2'},
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

void _size(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('a status change while editing keeps the typed text', (
    tester,
  ) async {
    _size(tester, const Size(390, 844));
    final statusCtrl = StreamController<SupervisorStatus?>.broadcast();
    addTearDown(statusCtrl.close);
    var gets = 0;
    final fake = FakeAgentTransport()
      ..requestHandler = (method, params) async {
        if (params?['op'] == 'get') gets++;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return _answer(params);
      };
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          supervisorStatusProvider(
            'm',
          ).overrideWith((ref) => statusCtrl.stream),
          controlPlaneClientForProvider(
            'm',
          ).overrideWith((ref) async => ControlPlaneClient(transport: fake)),
        ],
        child: MaterialApp(
          theme: buildAbTheme(),
          home: const MemoryRecordDetails(target: _remote, id: 'memory-1'),
        ),
      ),
    );
    statusCtrl.add(const Climbing(ConnRung.coords));
    await tester.pumpAndSettle();
    expect(find.text('Original memory'), findsOneWidget);
    expect(gets, 1);
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, 'MY TYPED FIX');
    await tester.pump();
    statusCtrl.add(const Connected());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.byType(EditableText), findsWidgets);
    await tester.pumpAndSettle();
    expect(find.text('MY TYPED FIX'), findsOneWidget);
    expect(find.text('Save changes'), findsOneWidget);
    expect(gets, 1);
  });

  test('request providers do not outlive their page or build a session', () async {
    final container = ProviderContainer(
      overrides: [
        supervisorStatusProvider('m').overrideWith((ref) => Stream.value(null)),
      ],
    );
    addTearDown(container.dispose);
    const q = (target: _remote, filter: MemoryFilter(), offset: 0);
    final sub = container.listen(memoryPageProvider(q), (_, _) {});
    await container.pump();
    sub.close();
    await container.pump();
    await container.pump();
    expect(container.exists(memoryPageProvider(q)), isFalse);
    expect(container.exists(memoryRequestProvider(_remote)), isFalse);
  });

  testWidgets('Reconnect and retry redials a failed machine connection', (
    tester,
  ) async {
    _size(tester, const Size(1280, 820));
    var dials = 0;
    final fake = FakeAgentTransport()
      ..requestHandler = (method, params) => _answer(params);
    final container = ProviderContainer(
      overrides: [
        supervisorStatusProvider('m').overrideWith((ref) => Stream.value(null)),
        controlPlaneClientForProvider('m').overrideWith((ref) async {
          dials++;
          if (dials == 1) throw StateError('first dial failed');
          return ControlPlaneClient(transport: fake);
        }),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildAbTheme(),
          home: const MemoryScreen(target: _remote),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(dials, 1);
    await tester.tap(find.text('Reconnect and retry'));
    await tester.pumpAndSettle();
    expect(dials, 2);
    expect(find.text('Original memory'), findsWidgets);
  });

  testWidgets('a machine that is not connected says so, not that storage failed', (
    tester,
  ) async {
    _size(tester, const Size(1280, 820));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          supervisorStatusProvider('m').overrideWith((ref) => Stream.value(null)),
          controlPlaneClientForProvider('m').overrideWith((ref) async => null),
        ],
        child: MaterialApp(
          theme: buildAbTheme(),
          home: const MemoryScreen(target: _remote),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text("This machine isn't connected. Connect it to see its memories."),
      findsOneWidget,
    );
    expect(find.text('Reconnect and retry'), findsOneWidget);
    expect(find.textContaining("Memory storage couldn't be opened"), findsNothing);
  });

  testWidgets('a conflicting save explains itself and retries with one key', (
    tester,
  ) async {
    _size(tester, const Size(390, 844));
    final saves = <Map<String, dynamic>>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          memoryRequestProvider(_remote).overrideWithValue((request) async {
            if (request['op'] == 'save') {
              saves.add(request);
              throw const MemoryException('CORRECTION_CONFLICT', 'raw words');
            }
            return _answer(request);
          }),
        ],
        child: MaterialApp(
          theme: buildAbTheme(),
          builder: abToastHostBuilder,
          home: const MemoryRecordDetails(target: _remote, id: 'memory-1'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, 'A better memory');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Someone edited this memory first.'), findsOne);
    expect(find.textContaining('raw words'), findsNothing);
    expect(saves, hasLength(1));
    final save = saves.single['save'] as Map;
    expect(save['supersedes'], 'memory-1');

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(saves, hasLength(2));
    expect(saves.last['operation_key'], saves.first['operation_key']);
  });
}
