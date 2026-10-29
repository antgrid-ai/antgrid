import 'dart:async';

import 'package:antgrid/connection/supervisor_state.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/models/memory.dart';
import 'package:antgrid/project/project_session_registry.dart';
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
  'content': 'Original finding',
  'memory_type': 'note',
  'scope': 'user',
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
  _ => {
    'results': [_record],
    'has_more': false,
  },
};

void main() {
  testWidgets('a status change while editing keeps the typed correction', (
    tester,
  ) async {
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
    expect(find.text('Original finding'), findsOneWidget);
    expect(gets, 1);
    await tester.tap(find.text('Correct finding'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, 'MY TYPED FIX');
    await tester.pump();
    statusCtrl.add(const Connected());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.byType(EditableText), findsWidgets);
    await tester.pumpAndSettle();
    expect(find.text('MY TYPED FIX'), findsOneWidget);
    expect(find.text('Save correction'), findsOneWidget);
    expect(gets, 1);
  });

  test(
    'request providers do not outlive the snapshot or build a session',
    () async {
      var sessionBuilds = 0;
      final container = ProviderContainer(
        overrides: [
          supervisorStatusProvider(
            'm',
          ).overrideWith((ref) => Stream.value(null)),
          projectSessionProvider('p').overrideWith((ref) async {
            sessionBuilds++;
            throw StateError('no session in test');
          }),
        ],
      );
      addTearDown(container.dispose);
      const q = (target: _remote, query: '', history: false, offset: 0);
      final sub = container.listen(memorySnapshotProvider(q), (_, _) {});
      await container.pump();
      sub.close();
      await container.pump();
      await container.pump();
      expect(container.exists(memorySnapshotProvider(q)), isFalse);
      expect(container.exists(memoryRequestProvider(_remote)), isFalse);

      const project = MemoryTarget.project('p');
      container.read(memoryRequestProvider(project));
      await container.pump();
      expect(sessionBuilds, 0);
      expect(container.exists(projectSessionProvider('p')), isFalse);
    },
  );

  testWidgets('Reconnect and retry redials a failed machine connection', (
    tester,
  ) async {
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
    expect(find.text('Original finding'), findsOneWidget);
  });

  testWidgets('Enter in search while search is unavailable changes nothing', (
    tester,
  ) async {
    final ops = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          memoryRequestProvider(_remote).overrideWithValue((request) async {
            ops.add('${request['op']}');
            if (request['op'] == 'status') return _status(search: 'degraded');
            return _answer(request);
          }),
        ],
        child: MaterialApp(
          theme: buildAbTheme(),
          home: const MemoryScreen(target: _remote),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, 'anything');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Original finding'), findsOneWidget);
    expect(ops, isNot(contains('search')));
  });

  test(
    'an active query with search unavailable is an error, not no results',
    () async {
      final container = ProviderContainer(
        overrides: [
          memoryRequestProvider(_remote).overrideWithValue(
            (request) async =>
                request['op'] == 'status' ? _status(search: 'degraded') : {},
          ),
        ],
      );
      addTearDown(container.dispose);
      const q = (target: _remote, query: 'x', history: false, offset: 0);
      final snapshot = await container.read(memorySnapshotProvider(q).future);
      expect(snapshot.records, isEmpty);
      expect(
        snapshot.resultError,
        isA<MemoryException>().having(
          (e) => e.code,
          'code',
          'SEARCH_UNAVAILABLE',
        ),
      );
    },
  );

  test('evidence lines are trimmed, CRLF-split and stripped of blanks', () {
    expect(parseEvidenceLines('a\r\n  \r\nb'), ['a', 'b']);
    expect(parseEvidenceLines('  x  \n\n'), ['x']);
  });

  testWidgets(
    'more than eight evidence references is refused without a request',
    (tester) async {
      final ops = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            memoryRequestProvider(_remote).overrideWithValue((request) async {
              ops.add('${request['op']}');
              return _answer(request);
            }),
          ],
          child: MaterialApp(
            theme: buildAbTheme(),
            home: const MemoryRecordDetails(target: _remote, id: 'memory-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Correct finding'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(EditableText).at(2),
        List.generate(9, (i) => 'ref-$i').join('\n'),
      );
      await tester.tap(find.text('Save correction'));
      await tester.pumpAndSettle();
      expect(find.text('Up to 8 evidence references'), findsOneWidget);
      expect(ops, isNot(contains('save')));
    },
  );
}
