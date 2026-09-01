import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/terminal_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    useInMemoryPrefs();
  });

  Future<ProjectSession> newSession(
    FakeAgentTransport t, {
    String projectId = 'p',
  }) async {
    final cache = await CachedSessionsStore.open();
    return ProjectSession(
      projectId: projectId,
      transport: t,
      mode: ProjectSessionMode.local,
      cachedSessionsStore: cache,
      onClose: () async => await t.dispose(),
    );
  }

  test('terminal:size updates tab cols/rows/driverClientId', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = TerminalService.fromSession(session);

    // Arrange: seed a running tab 't1' via agent:status (status tier).
    t.emit('agent:status', {
      'projectId': 'p',
      'terminals': [
        {
          'id': 't1',
          'terminalId': 't1',
          'name': 'Terminal 1',
          'running': true,
          'cols': 80,
          'rows': 24,
        },
      ],
    });
    await Future<void>.delayed(Duration.zero);

    expect(svc.currentState.tabs['t1'], isNotNull);
    expect(svc.currentState.tabs['t1']!.cols, 80);

    // Act: feed a terminal:size status json through the status tier.
    t.emit('terminal:size', {
      'terminalId': 't1',
      'cols': 100,
      'rows': 30,
      'driverClientId': 'other',
    });
    await Future<void>.delayed(Duration.zero);

    // Assert: service has applied the authoritative size.
    final tab = svc.currentState.tabs['t1'];
    expect(tab, isNotNull);
    expect(tab!.cols, 100);
    expect(tab.rows, 30);
    expect(tab.driverClientId, 'other');

    await svc.dispose();
    await session.close();
  });

  test(
    'terminal:size from another driver cancels pending local resize',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setClientId('desktop');

      t.emit('agent:status', {
        'projectId': 'p',
        'terminals': [
          {
            'id': 't1',
            'terminalId': 't1',
            'name': 'Terminal 1',
            'running': true,
            'cols': 120,
            'rows': 30,
            'driverClientId': 'desktop',
          },
        ],
      });
      await Future<void>.delayed(Duration.zero);

      svc.sendResize('t1', 121, 30, baseDriverClientId: 'desktop');
      t.emit('terminal:size', {
        'terminalId': 't1',
        'cols': 50,
        'rows': 40,
        'driverClientId': 'mobile',
      });
      await Future<void>.delayed(const Duration(milliseconds: 150));

      final resizes = t.sent
          .where((m) => m['type'] == 'terminal:resize')
          .toList();
      expect(resizes, isEmpty);

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'terminal:size from the observed base driver keeps pending claim',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = TerminalService.fromSession(session);
      svc.setClientId('mobile');

      t.emit('agent:status', {
        'projectId': 'p',
        'terminals': [
          {
            'id': 't1',
            'terminalId': 't1',
            'name': 'Terminal 1',
            'running': true,
            'cols': 120,
            'rows': 30,
            'driverClientId': 'desktop',
          },
        ],
      });
      await Future<void>.delayed(Duration.zero);

      svc.sendResize('t1', 50, 40, baseDriverClientId: 'desktop');
      t.emit('terminal:size', {
        'terminalId': 't1',
        'cols': 120,
        'rows': 30,
        'driverClientId': 'desktop',
      });
      await Future<void>.delayed(const Duration(milliseconds: 150));

      final resizes = t.sent
          .where((m) => m['type'] == 'terminal:resize')
          .toList();
      expect(resizes, isNotEmpty);
      expect(resizes.last['clientId'], 'mobile');
      expect(resizes.last['baseDriverClientId'], 'desktop');

      await svc.dispose();
      await session.close();
    },
  );

  test('agent:status clears stale driverClientId when omitted', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = TerminalService.fromSession(session);

    t.emit('agent:status', {
      'projectId': 'p',
      'terminals': [
        {
          'id': 't1',
          'terminalId': 't1',
          'name': 'Terminal 1',
          'running': true,
          'cols': 120,
          'rows': 30,
          'driverClientId': 'desktop',
        },
      ],
    });
    await Future<void>.delayed(Duration.zero);
    expect(svc.currentState.tabs['t1']?.driverClientId, 'desktop');

    t.emit('agent:status', {
      'projectId': 'p',
      'terminals': [
        {
          'id': 't1',
          'terminalId': 't1',
          'name': 'Terminal 1',
          'running': true,
          'cols': 80,
          'rows': 24,
        },
      ],
    });
    await Future<void>.delayed(Duration.zero);

    expect(svc.currentState.tabs['t1']?.driverClientId, isNull);

    await svc.dispose();
    await session.close();
  });

  // The two paths where `sendResize` returns true and the frame it armed is
  // then thrown away. The caller books the size on that `true`, so its gate is
  // shut against a geometry the PTY never received; only a `sizeEpoch` bump
  // reopens it, and nothing else in the system can detect the disagreement.
  test('a queued resize discarded by another driver bumps sizeEpoch', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = TerminalService.fromSession(session);
    svc.setClientId('desktop');

    t.emit('agent:status', {
      'projectId': 'p',
      'terminals': [
        {
          'id': 't1',
          'terminalId': 't1',
          'name': 'Terminal 1',
          'running': true,
          'cols': 120,
          'rows': 30,
          'driverClientId': 'desktop',
        },
      ],
    });
    await Future<void>.delayed(Duration.zero);
    final before = svc.currentState.tabs['t1']!.sizeEpoch;

    // Nothing queued: the frame is authoritative news, not a cancellation, and
    // the caller has no booking to retire.
    t.emit('terminal:size', {
      'terminalId': 't1',
      'cols': 90,
      'rows': 30,
      'driverClientId': 'mobile',
    });
    await Future<void>.delayed(Duration.zero);
    expect(svc.currentState.tabs['t1']!.sizeEpoch, before);

    expect(
      svc.sendResize('t1', 121, 30, baseDriverClientId: 'desktop'),
      isTrue,
    );
    t.emit('terminal:size', {
      'terminalId': 't1',
      'cols': 50,
      'rows': 40,
      'driverClientId': 'mobile',
    });
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(t.sent.where((m) => m['type'] == 'terminal:resize'), isEmpty);
    expect(
      svc.currentState.tabs['t1']!.sizeEpoch,
      before + 1,
      reason: 'the queued frame was destroyed, so the booking must be retired',
    );

    await svc.dispose();
    await session.close();
  });

  test('a resize the debounce itself discards bumps sizeEpoch', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = TerminalService.fromSession(session);
    svc.setClientId('mobile');

    t.emit('agent:status', {
      'projectId': 'p',
      'terminals': [
        {
          'id': 't1',
          'terminalId': 't1',
          'name': 'Terminal 1',
          'running': true,
          'cols': 120,
          'rows': 30,
          'driverClientId': 'desktop',
        },
      ],
    });
    await Future<void>.delayed(Duration.zero);
    final before = svc.currentState.tabs['t1']!.sizeEpoch;

    expect(svc.sendResize('t1', 50, 40, baseDriverClientId: 'desktop'), isTrue);
    // A THIRD device takes the terminal, announced on the status tier rather
    // than as a `terminal:size` — so the cancellation above never runs and the
    // armed timer survives to reject itself against the new driver.
    t.emit('agent:status', {
      'projectId': 'p',
      'terminals': [
        {
          'id': 't1',
          'terminalId': 't1',
          'name': 'Terminal 1',
          'running': true,
          'cols': 120,
          'rows': 30,
          'driverClientId': 'tablet',
        },
      ],
    });
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(t.sent.where((m) => m['type'] == 'terminal:resize'), isEmpty);
    expect(
      svc.currentState.tabs['t1']!.sizeEpoch,
      before + 1,
      reason: 'the debounce dropped the frame long after sendResize answered',
    );

    await svc.dispose();
    await session.close();
  });
}
