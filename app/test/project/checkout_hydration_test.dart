// Activation-gated checkout hydration (D-B1/D-B2).
//
// A bundle is built eagerly for every checkout with a session — the
// notification aggregators in providers.dart fan in over every bundle, and
// nothing else would ever construct one for a session that has never been
// focused. But construction is not a pull: the heavy per-checkout hydrators
// (tree, config, preview snapshot, terminal frames) and the focus-resume
// re-drives that repeat them on every foreground only fire for a checkout
// [ProjectSession.setActiveCheckouts] has named. Nine managed checkouts used
// to put nine trees (and nine of everything else) on the wire at once on
// every bind; only the checkout actually on screen should.
//
// `git:sync-status` stays eager (it feeds drawer/status chrome for every
// checkout, not just the focused one) and is asserted on throughout so a
// gate that accidentally silenced it would not read as "activation working".

import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

Map<String, dynamic> _sessionRow(String id, String checkoutId) => {
  'id': id,
  'name': 'PR review',
  'checkoutId': checkoutId,
  'mode': 'terminal',
  'running': true,
  'archived': false,
  'createdAt': 1,
  'lastUsedAt': 1,
};

Map<String, dynamic> _statusFor(String checkoutId, String terminalId) => {
  'checkoutId': checkoutId,
  'projectId': 'p1',
  'terminals': [
    {
      'terminalId': terminalId,
      'name': 'PR review',
      'running': true,
      'type': 'agent',
      'cols': 80,
      'rows': 24,
    },
  ],
  'services': <dynamic>[],
};

Future<ProjectSession> _openSession(FakeAgentTransport t) async {
  final cache = await CachedSessionsStore.open();
  return ProjectSession(
    projectId: 'p1',
    transport: t,
    mode: ProjectSessionMode.relay,
    cachedSessionsStore: cache,
    onClose: () async => t.dispose(),
  );
}

List<Map<String, dynamic>> _sentOf(
  FakeAgentTransport t,
  String type, {
  String? checkoutId,
}) => t.sent.where((m) {
  return m['type'] == type &&
      (checkoutId == null || m['checkoutId'] == checkoutId);
}).toList();

const _heavyTypes = [
  'file:tree:snapshot:request',
  'config:read',
  'preview:snapshot:request',
  'terminal:subscribe',
];

/// Fires exactly one [MessageRouter.focusResumed] edge — the recipe every
/// resume-driven test in the suite shares.
Future<void> _resume(ProjectSession session) async {
  session.setLifecyclePaused(true);
  await Future<void>.delayed(Duration.zero);
  session.setLifecyclePaused(false);
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(useInMemoryPrefs);

  test('nothing active pulls only the eager sync state', () async {
    final t = FakeAgentTransport();
    final session = await _openSession(t);
    addTearDown(session.close);

    t.emit('session:list:result', {
      'sessions': [
        _sessionRow('sA', 'A'),
        _sessionRow('sB', 'B'),
        _sessionRow('sC', 'C'),
      ],
    });
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(_sentOf(t, 'file:tree:snapshot:request'), isEmpty);
    expect(_sentOf(t, 'config:read'), isEmpty);
    expect(_sentOf(t, 'preview:snapshot:request'), isEmpty);
    expect(_sentOf(t, 'git:sync-status').map((m) => m['checkoutId']).toSet(), {
      'main',
      'A',
      'B',
      'C',
    });
  });

  test('activating a checkout pulls only its own heavy hydrators', () async {
    final t = FakeAgentTransport();
    final session = await _openSession(t);
    addTearDown(session.close);

    t.emit('session:list:result', {
      'sessions': [_sessionRow('sA', 'A'), _sessionRow('sB', 'B')],
    });
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // Discovered before activation, so its own discovery pull is discarded by
    // clearSent below rather than counted as an activation pull.
    t.emit('agent:status', _statusFor('A', 'a1'));
    t.emit('agent:status', _statusFor('B', 'b1'));
    await Future<void>.delayed(Duration.zero);
    t.clearSent();

    session.setActiveCheckouts({'A'});
    await Future<void>.delayed(Duration.zero);

    for (final type in _heavyTypes) {
      expect(_sentOf(t, type, checkoutId: 'A'), hasLength(1), reason: type);
      expect(_sentOf(t, type, checkoutId: 'B'), isEmpty, reason: type);
      expect(_sentOf(t, type, checkoutId: 'main'), isEmpty, reason: type);
    }
  });

  test('re-establishment redrives only the active checkout\'s heavy '
      'hydrators', () async {
    final t = FakeAgentTransport();
    final session = await _openSession(t);
    addTearDown(session.close);

    t.emit('session:list:result', {
      'sessions': [
        _sessionRow('sA', 'A'),
        _sessionRow('sB', 'B'),
        _sessionRow('sC', 'C'),
      ],
    });
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    t.emit('agent:status', _statusFor('A', 'a1'));
    await Future<void>.delayed(Duration.zero);

    session.setActiveCheckouts({'A'});
    await Future<void>.delayed(Duration.zero);
    t.clearSent();

    t.setEstablished(false);
    t.clearSent();
    t.setEstablished(true);
    await Future<void>.delayed(Duration.zero);

    for (final type in _heavyTypes) {
      expect(_sentOf(t, type, checkoutId: 'A'), hasLength(1), reason: type);
      expect(_sentOf(t, type, checkoutId: 'B'), isEmpty, reason: type);
      expect(_sentOf(t, type, checkoutId: 'C'), isEmpty, reason: type);
    }
    expect(_sentOf(t, 'git:sync-status').map((m) => m['checkoutId']).toSet(), {
      'main',
      'A',
      'B',
      'C',
    });
  });

  test('switching the active checkout moves the heavy pulls with it', () async {
    final t = FakeAgentTransport();
    final session = await _openSession(t);
    addTearDown(session.close);

    t.emit('session:list:result', {
      'sessions': [_sessionRow('sA', 'A'), _sessionRow('sB', 'B')],
    });
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    session.setActiveCheckouts({'A'});
    await Future<void>.delayed(Duration.zero);
    t.clearSent();

    session.setActiveCheckouts({'B'});
    await Future<void>.delayed(Duration.zero);

    expect(
      _sentOf(t, 'file:tree:snapshot:request', checkoutId: 'B'),
      hasLength(1),
    );
    expect(_sentOf(t, 'file:tree:snapshot:request', checkoutId: 'A'), isEmpty);

    t.clearSent();
    t.redriveHydrators();
    await Future<void>.delayed(Duration.zero);

    final pulls = _sentOf(t, 'file:tree:snapshot:request');
    expect(pulls, isNotEmpty);
    expect(pulls.every((m) => m['checkoutId'] == 'B'), isTrue);
  });

  test(
    'a checkout activated before its bundle exists comes up active',
    () async {
      final t = FakeAgentTransport();
      final session = await _openSession(t);
      addTearDown(session.close);

      session.setActiveCheckouts({'A'});
      await Future<void>.delayed(Duration.zero);

      expect(session.existingServicesForCheckout('A')!.isActive, isTrue);
      expect(
        _sentOf(t, 'file:tree:snapshot:request', checkoutId: 'A'),
        hasLength(1),
      );

      // The list arrives after — servicesForCheckout must return the SAME
      // (already active) bundle rather than recreating and re-pulling it.
      t.emit('session:list:result', {
        'sessions': [_sessionRow('sA', 'A')],
      });
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        _sentOf(t, 'file:tree:snapshot:request', checkoutId: 'A'),
        hasLength(1),
      );
    },
  );

  test(
    'an id only the list will later introduce is activated on arrival',
    () async {
      final t = FakeAgentTransport();
      final session = await _openSession(t);
      addTearDown(session.close);

      session.setActiveCheckouts({'A', 'D'});
      await Future<void>.delayed(Duration.zero);

      expect(
        _sentOf(t, 'file:tree:snapshot:request', checkoutId: 'D'),
        hasLength(1),
      );

      t.emit('session:list:result', {
        'sessions': [_sessionRow('sA', 'A')],
      });
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      t.emit('session:list:result', {
        'sessions': [_sessionRow('sA', 'A'), _sessionRow('sD', 'D')],
      });
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(session.existingServicesForCheckout('D')!.isActive, isTrue);
      expect(
        _sentOf(t, 'file:tree:snapshot:request', checkoutId: 'D'),
        hasLength(1),
      );
    },
  );

  test('activate and deactivate are each idempotent', () async {
    final t = FakeAgentTransport();
    final session = await _openSession(t);
    addTearDown(session.close);

    t.emit('session:list:result', {
      'sessions': [_sessionRow('sA', 'A')],
    });
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final bundle = session.servicesForCheckout('A');
    t.clearSent();

    bundle.activate();
    bundle.activate();
    await Future<void>.delayed(Duration.zero);
    expect(
      _sentOf(t, 'file:tree:snapshot:request', checkoutId: 'A'),
      hasLength(1),
    );

    bundle.deactivate();
    bundle.deactivate();

    t.clearSent();
    t.redriveHydrators();
    await Future<void>.delayed(Duration.zero);
    expect(_sentOf(t, 'file:tree:snapshot:request', checkoutId: 'A'), isEmpty);
  });

  test('deactivation leaves service state intact', () async {
    final t = FakeAgentTransport();
    final session = await _openSession(t);
    addTearDown(session.close);

    t.emit('session:list:result', {
      'sessions': [_sessionRow('sA', 'A')],
    });
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    t.emit('agent:status', _statusFor('A', 'a1'));
    await Future<void>.delayed(Duration.zero);

    final bundle = session.servicesForCheckout('A');
    bundle.activate();
    await Future<void>.delayed(Duration.zero);

    t.emit('file:tree:snapshot', {
      'checkoutId': 'A',
      'seq': 1,
      'tree': {
        'name': 'A',
        'path': '',
        'type': 'directory',
        'children': <dynamic>[],
      },
    });
    await Future<void>.delayed(Duration.zero);

    expect(bundle.fileService.currentState.root, isNotNull);
    expect(bundle.terminalService.currentState.tabs.keys, contains('a1'));

    bundle.deactivate();

    expect(bundle.fileService.currentState.root, isNotNull);
    expect(bundle.terminalService.currentState.tabs.keys, contains('a1'));
  });

  test('focus-resume re-pulls only the active checkout', () async {
    final t = FakeAgentTransport();
    final session = await _openSession(t);
    addTearDown(session.close);

    t.emit('session:list:result', {
      'sessions': [_sessionRow('sA', 'A'), _sessionRow('sB', 'B')],
    });
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    t.emit('agent:status', _statusFor('A', 'a1'));
    t.emit('agent:status', _statusFor('B', 'b1'));
    await Future<void>.delayed(Duration.zero);

    session.setActiveCheckouts({'A'});
    await Future<void>.delayed(Duration.zero);
    t.clearSent();

    await _resume(session);

    for (final type in [
      'file:tree:snapshot:request',
      'preview:snapshot:request',
      'terminal:subscribe',
    ]) {
      expect(_sentOf(t, type, checkoutId: 'A'), isNotEmpty, reason: type);
      expect(_sentOf(t, type, checkoutId: 'B'), isEmpty, reason: type);
      expect(_sentOf(t, type, checkoutId: 'main'), isEmpty, reason: type);
    }
  });
}
