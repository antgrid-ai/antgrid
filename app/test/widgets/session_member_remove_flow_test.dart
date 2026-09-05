// Removing a machine from a session deletes its session on its own machine and
// then releases the membership on the lead. The release is the half that cannot
// be left half-done: by the time it runs the peer's session is already gone, so
// a lead that keeps the record pins a project whose session no longer exists —
// and this flow is the only UI that can clear it.
import 'dart:async';

import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/session_member_remove_flow.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

const _leadId = 'lead-proj';
const _leadSessionId = 'sess-lead';
const _peerRegistrationId = 'machine-studio.app';
const _peer = SessionMemberRef(
  machineId: 'machine-studio',
  projectId: 'app',
  sessionId: 'sess-peer',
  machineLabel: 'Studio',
  projectLabel: 'app',
);

Map<String, dynamic> _sessionJson(String id) => {
  'id': id,
  'name': id,
  'createdAt': 1,
  'lastUsedAt': 1,
  'archived': false,
  'running': false,
};

List<Map<String, dynamic>> _ofType(FakeAgentTransport t, String type) =>
    t.sent.where((m) => m['type'] == type).toList();

void _answer(FakeAgentTransport t, Map<String, dynamic> request) {
  t.emit('session:result', {
    'requestId': request['requestId'],
    'ok': true,
    'session': _sessionJson(request['sessionId'] as String),
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(useInMemoryPrefs);

  Future<({FakeAgentTransport lead, FakeAgentTransport peer})> startRemoval(
    WidgetTester tester,
  ) async {
    final leadTransport = FakeAgentTransport();
    final peerTransport = FakeAgentTransport();
    final cache = await CachedSessionsStore.open();
    addTearDown(cache.close);

    ProjectSession build(String id, FakeAgentTransport t, bool isLocal) {
      final s = ProjectSession(
        projectId: id,
        transport: t,
        mode: isLocal ? ProjectSessionMode.local : ProjectSessionMode.relay,
        cachedSessionsStore: cache,
        onClose: () async => await t.dispose(),
      );
      addTearDown(s.close);
      return s;
    }

    final sessions = {
      _leadId: build(_leadId, leadTransport, true),
      _peerRegistrationId: build(_peerRegistrationId, peerTransport, false),
    };

    late BuildContext host;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          selectedTargetProvider.overrideWith(
            () => ValueController<SessionTarget?>(const LocalProject(_leadId)),
          ),
          localDeviceUuidProvider.overrideWith((ref) async => 'local-uuid'),
          projectSessionProvider.overrideWith(
            (ref, id) async => sessions[id]!,
          ),
        ],
        child: MaterialApp(
          theme: buildAbTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) {
                host = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(host);
    for (final id in sessions.keys) {
      await container.read(projectSessionProvider(id).future);
      container
          .read(projectSessionRegistryProvider.notifier)
          .touch(id, isLocal: id == _leadId);
    }

    unawaited(
      confirmAndRemoveMember(
        host,
        container,
        leadRegistrationId: _leadId,
        leadSessionId: _leadSessionId,
        peer: _peer,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    return (lead: leadTransport, peer: peerTransport);
  }

  testWidgets('a release nobody answers is reported and can be retried', (
    tester,
  ) async {
    final env = await startRemoval(tester);

    _answer(env.peer, _ofType(env.peer, 'session:delete').single);
    await tester.pumpAndSettle();

    expect(_ofType(env.lead, 'session:member-release'), hasLength(1));

    // Nothing answers it. `PendingReply` raises a `TimeoutException`, which is
    // not a `SessionOperationException` — the case that used to escape the
    // flow entirely and leave the user with no dialog and a member still on
    // screen.
    await tester.pump(const Duration(seconds: 20));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not remove Studio'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    final releases = _ofType(env.lead, 'session:member-release');
    expect(releases, hasLength(2));
    _answer(env.lead, {
      'requestId': releases.last['requestId'],
      'sessionId': _leadSessionId,
    });
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not remove'), findsNothing);
  });

  testWidgets('a refused release can be left alone', (tester) async {
    final env = await startRemoval(tester);

    _answer(env.peer, _ofType(env.peer, 'session:delete').single);
    await tester.pumpAndSettle();

    env.lead.emit('session:result', {
      'requestId': _ofType(env.lead, 'session:member-release').single['requestId'],
      'ok': false,
      'errorCode': 'NOT_A_MEMBER',
      'error': 'that machine is not in this session',
    });
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not remove Studio'), findsOneWidget);
    await tester.tap(find.text('Leave it'));
    await tester.pumpAndSettle();

    // Nothing further is sent — the user said to stop.
    expect(_ofType(env.lead, 'session:member-release'), hasLength(1));
  });
}
