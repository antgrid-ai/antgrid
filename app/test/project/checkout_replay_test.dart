import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/project/project_message_classification.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

/// The connect-time `state.snapshot` replay for an isolated checkout, as the
/// bridge emits it: one `agent:status` stamped with the checkout id.
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

void main() {
  setUp(useInMemoryPrefs);

  Future<ProjectSession> openSession(FakeAgentTransport t) async {
    final cache = await CachedSessionsStore.open();
    return ProjectSession(
      projectId: 'p1',
      transport: t,
      mode: ProjectSessionMode.relay,
      cachedSessionsStore: cache,
      onClose: () async => t.dispose(),
    );
  }

  group('checkout durable replay', () {
    test(
      'a status replayed before the session list still builds the tab',
      () async {
        final t = FakeAgentTransport();
        final session = await openSession(t);
        addTearDown(session.close);

        // state.snapshot replay: lands while only the `main` bundle exists.
        t.emit('agent:status', _statusFor('wt1', 's1'));
        await Future<void>.delayed(Duration.zero);

        // session:list:result is what creates the `wt1` bundle — a full round
        // trip later.
        t.emit('session:list:result', {
          'sessions': [_sessionRow('s1', 'wt1')],
        });
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        final tabs = session
            .servicesForCheckout('wt1')
            .terminalService
            .currentState
            .tabs;
        expect(
          tabs.keys,
          contains('s1'),
          reason:
              'the late bundle must be seeded with the replayed status; '
              'without it the session sits on "waiting for agent" forever',
        );
      },
    );

    test('the replay does not leak across checkouts', () async {
      final t = FakeAgentTransport();
      final session = await openSession(t);
      addTearDown(session.close);

      t.emit('agent:status', _statusFor('wt1', 's1'));
      await Future<void>.delayed(Duration.zero);

      expect(
        session.servicesForCheckout('wt2').terminalService.currentState.tabs,
        isEmpty,
      );
      expect(
        session.terminalService.currentState.tabs,
        isEmpty,
        reason: 'main must not absorb another checkout\'s terminals',
      );
    });

    test('only the latest frame per type is retained', () async {
      final t = FakeAgentTransport();
      final session = await openSession(t);
      addTearDown(session.close);

      t.emit('agent:status', _statusFor('wt1', 'stale'));
      t.emit('agent:status', _statusFor('wt1', 'fresh'));
      await Future<void>.delayed(Duration.zero);

      final services = session.servicesForCheckout('wt1');
      await Future<void>.delayed(Duration.zero);
      expect(services.terminalService.currentState.tabs.keys, ['fresh']);
    });

    test('heavy-tier frames seed a late subscriber too', () async {
      final t = FakeAgentTransport();
      final session = await openSession(t);
      addTearDown(session.close);

      t.emit('tree:full', {
        'checkoutId': 'wt1',
        'projectId': 'p1',
        'root': <String, dynamic>{
          'name': 'wt1',
          'path': '',
          'type': 'directory',
          'children': <dynamic>[],
        },
      });
      await Future<void>.delayed(Duration.zero);

      final seen = <String>[];
      final sub = session
          .checkoutHeavyStream('wt1')
          .listen((json) => seen.add(json['type'] as String));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(seen, contains('tree:full'));
    });

    test('a swept checkout stops seeding new subscribers', () async {
      final t = FakeAgentTransport();
      final session = await openSession(t);
      addTearDown(session.close);

      t.emit('agent:status', _statusFor('wt1', 's1'));
      t.emit('session:list:result', {
        'sessions': [_sessionRow('s1', 'wt1')],
      });
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      t.emit('session:list:result', {'sessions': <dynamic>[]});
      await Future<void>.delayed(Duration.zero);
      expect(session.existingServicesForCheckout('wt1'), isNotNull);
      t.emit('session:list:result', {'sessions': <dynamic>[]});
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(session.existingServicesForCheckout('wt1'), isNull);

      final revived = session.servicesForCheckout('wt1');
      await Future<void>.delayed(Duration.zero);
      expect(revived.terminalService.currentState.tabs, isEmpty);
    });

    test(
      'a recreated obsolete bundle is released on the next listing',
      () async {
        final t = FakeAgentTransport();
        final session = await openSession(t);
        addTearDown(session.close);

        t.emit('session:list:result', {'sessions': <dynamic>[]});
        await Future<void>.delayed(Duration.zero);
        session.servicesForCheckout('deleted');
        t.emit('session:list:result', {'sessions': <dynamic>[]});
        await Future<void>.delayed(Duration.zero);
        expect(session.existingServicesForCheckout('deleted'), isNull);

        session.servicesForCheckout('deleted');
        t.emit('control:result', {
          'ok': false,
          'checkoutId': 'deleted',
          'error': {'code': 'UNKNOWN_CHECKOUT', 'message': 'Deleted'},
        });
        await Future<void>.delayed(Duration.zero);
        expect(session.existingServicesForCheckout('deleted'), isNull);
      },
    );

    test('checkout refusal needs an authoritative absent listing', () async {
      final t = FakeAgentTransport();
      final session = await openSession(t);
      addTearDown(session.close);
      final original = session.servicesForCheckout('wt1');

      void refuse(String id) => t.emit('control:result', {
        'ok': false,
        'checkoutId': id,
        'error': {'code': 'UNKNOWN_CHECKOUT', 'message': 'Deleted'},
      });

      refuse('wt1');
      await Future<void>.delayed(Duration.zero);
      expect(session.existingServicesForCheckout('wt1'), same(original));

      t.emit('session:list:result', {
        'sessions': [_sessionRow('s1', 'wt1')],
      });
      await Future<void>.delayed(Duration.zero);
      refuse('wt1');
      refuse('main');
      await Future<void>.delayed(Duration.zero);
      expect(session.existingServicesForCheckout('wt1'), same(original));
      expect(session.existingServicesForCheckout('main'), isNotNull);

      t.emit('session:list:result', {'sessions': <dynamic>[]});
      await Future<void>.delayed(Duration.zero);
      t.emit('control:result', {
        'ok': true,
        'checkoutId': 'wt1',
        'error': {'code': 'UNKNOWN_CHECKOUT', 'message': 'Deleted'},
      });
      await Future<void>.delayed(Duration.zero);
      expect(session.existingServicesForCheckout('wt1'), same(original));
      refuse('wt1');
      await Future<void>.delayed(Duration.zero);
      expect(session.existingServicesForCheckout('wt1'), isNull);
    });

    test(
      'a checkout returning before the sweep retains its services',
      () async {
        final t = FakeAgentTransport();
        final session = await openSession(t);
        addTearDown(session.close);
        final original = session.servicesForCheckout('wt1');
        t.emit('session:list:result', {'sessions': <dynamic>[]});
        await Future<void>.delayed(Duration.zero);
        t.emit('session:updated', {
          'sessions': [_sessionRow('s1', 'wt1')],
        });
        await Future<void>.delayed(Duration.zero);
        t.emit('session:list:result', {
          'sessions': [_sessionRow('s1', 'wt1')],
        });
        await Future<void>.delayed(Duration.zero);
        expect(session.existingServicesForCheckout('wt1'), same(original));
      },
    );

    test('loading changes cannot advance a checkout sweep', () async {
      final t = FakeAgentTransport();
      final session = await openSession(t);
      addTearDown(session.close);
      final original = session.servicesForCheckout('wt1');
      t.emit('session:list:result', {'sessions': <dynamic>[]});
      await Future<void>.delayed(Duration.zero);

      final listing = session.sessionsService.requestList();
      await Future<void>.delayed(Duration.zero);
      expect(session.existingServicesForCheckout('wt1'), same(original));
      t.emit('session:list:result', {
        'requestId': t.sent.lastWhere(
          (message) => message['type'] == 'session:list',
        )['requestId'],
        'sessions': <dynamic>[],
      });
      await listing;
      await Future<void>.delayed(Duration.zero);
      expect(session.existingServicesForCheckout('wt1'), isNull);
    });

    test('sweeping releases active hydrators before reconnect', () async {
      final t = FakeAgentTransport();
      final session = await openSession(t);
      addTearDown(session.close);
      session.setActiveCheckouts({'wt1'});
      t.emit('session:list:result', {'sessions': <dynamic>[]});
      await Future<void>.delayed(Duration.zero);
      t.emit('session:list:result', {'sessions': <dynamic>[]});
      await Future<void>.delayed(Duration.zero);
      expect(session.activeCheckouts, isNot(contains('wt1')));

      t.clearSent();
      t.redriveHydrators();
      await Future<void>.delayed(Duration.zero);
      expect(
        t.sent.where((message) => message['checkoutId'] == 'wt1'),
        isEmpty,
      );
      await session.close();
    });

    test('a checkout with only retained replay is swept too', () async {
      final t = FakeAgentTransport();
      final session = await openSession(t);
      addTearDown(session.close);
      t.emit('agent:status', _statusFor('wt1', 's1'));
      t.emit('session:list:result', {'sessions': <dynamic>[]});
      await Future<void>.delayed(Duration.zero);
      t.emit('session:list:result', {'sessions': <dynamic>[]});
      await Future<void>.delayed(Duration.zero);

      final revived = session.servicesForCheckout('wt1');
      await Future<void>.delayed(Duration.zero);
      expect(revived.terminalService.currentState.tabs, isEmpty);
    });

    test('kCheckoutDurableReplayTypes are all checkout-variable', () {
      expect(
        kCheckoutDurableReplayTypes.difference(kCheckoutVariableMessageTypes),
        isEmpty,
        reason:
            'a durable type that never carries checkoutId would be '
            'replayed to the wrong bundle',
      );
    });
  });
}
