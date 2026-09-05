// The member strip is the workspace's only cross-machine control: pressing a
// tab moves the FOCUSED project and the active session together, which is what
// carries files, git, preview, terminals and the Handler to that machine.
// These tests pin that pair of writes, in both directions.
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/session_members.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/session_member_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

const _kLocalUuid = 'local-machine-uuid';
const _kPeerUuid = 'peer-machine-uuid';
const _kLeadReg = 'lead-proj';
const _kPeerReg = '$_kPeerUuid.peer-proj';

const _kPeerRef = SessionMemberRef(
  machineId: _kPeerUuid,
  projectId: 'peer-proj',
  sessionId: 'sess-peer',
);

const _kLeadRef = SessionMemberRef(
  machineId: _kLocalUuid,
  projectId: 'lead-proj',
  sessionId: 'sess-lead',
);

SessionEntry _lead({bool withMember = true}) => SessionEntry(
  id: 'sess-lead',
  name: 'Trace the leak',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: true,
  members: withMember
      ? const [SessionMember(ref: _kPeerRef, joinedAt: 1)]
      : const [],
);

SessionEntry _peer() => SessionEntry(
  id: 'sess-peer',
  name: 'Trace the leak',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: true,
  memberOf: const SessionMemberOf(ref: _kLeadRef, joinedAt: 1),
);

class _Harness {
  _Harness(this.container, this.leadTransport, this.peerTransport);

  final ProviderContainer container;
  final FakeAgentTransport leadTransport;
  final FakeAgentTransport peerTransport;

  SessionTarget? get target => container.read(selectedTargetProvider);
  String? get activeSessionId => container.read(activeSessionIdProvider);
}

/// Pumps the strip over two projects — a lead on this machine and a peer on
/// another — with both already warm, which is the state the carrier keeps a
/// member's project in for as long as the membership lasts.
Future<_Harness> _pump(
  WidgetTester tester, {
  required SessionTarget initialTarget,
  required String initialSessionId,
  bool withMember = true,
}) async {
  useInMemoryPrefs();
  final stores = await buildTestStoreOverrides();
  addTearDown(stores.close);
  final cache = await CachedSessionsStore.open();
  addTearDown(() => cache.close());

  final leadTransport = FakeAgentTransport();
  final peerTransport = FakeAgentTransport();
  final leadSession = ProjectSession(
    projectId: _kLeadReg,
    transport: leadTransport,
    mode: ProjectSessionMode.local,
    cachedSessionsStore: cache,
    onClose: () async => leadTransport.dispose(),
  );
  final peerSession = ProjectSession(
    projectId: _kPeerReg,
    transport: peerTransport,
    mode: ProjectSessionMode.relay,
    cachedSessionsStore: cache,
    onClose: () async => peerTransport.dispose(),
  );

  late ProviderContainer container;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...stores.overrides,
        selectedTargetProvider.overrideWith(
          () => ValueController<SessionTarget?>(initialTarget),
        ),
        // The base controller, not [ActiveSessionId]: the guard reads the
        // focused project's live session list, which no strip test stands up.
        activeSessionIdProvider.overrideWith(
          () => ValueController<String?>(initialSessionId),
        ),
        // The row the workspace is showing, resolved the way the real provider
        // does — off the focused project AND the active id together, so a tab
        // press moving only one of them cannot look like a success.
        activeSessionOrCachedProvider.overrideWith((ref) {
          final reg = ref.watch(selectedRegistrationIdProvider);
          final id = ref.watch(activeSessionIdProvider);
          if (reg == _kLeadReg && id == 'sess-lead') {
            return _lead(withMember: withMember);
          }
          if (reg == _kPeerReg && id == 'sess-peer') return _peer();
          return null;
        }),
        localDeviceUuidProvider.overrideWith((ref) => _kLocalUuid),
        accountAgentsProvider.overrideWith(
          (ref) => [
            InventoryAgent(
              deviceUuid: _kPeerUuid,
              displayName: 'Studio',
              platform: 'macos',
              ed25519Pub: 'k',
              machineName: 'Studio',
            ),
          ],
        ),
        projectSessionRegistryProvider.overrideWith(() {
          final registry = ProjectSessionRegistry(
            localCap: 4,
            relayCap: 4,
            onEvict: (_) async {},
          );
          registry.touch(_kPeerReg, isLocal: false);
          registry.touch(_kLeadReg, isLocal: true);
          return ProjectSessionRegistryController(registry);
        }),
        projectSessionProvider(_kLeadReg).overrideWith((ref) => leadSession),
        projectSessionProvider(_kPeerReg).overrideWith((ref) => peerSession),
      ],
      child: MaterialApp(
        theme: ThemeData.dark().copyWith(
          extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
        ),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              container = ref.container;
              return const SessionMemberTabs();
            },
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return _Harness(container, leadTransport, peerTransport);
}

bool _announcedFocus(FakeAgentTransport t, String sessionId) => t.sent.any(
  (m) => m['type'] == 'session:focus' && m['sessionId'] == sessionId,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a session working alone renders no strip', (tester) async {
    await _pump(
      tester,
      initialTarget: const LocalProject(_kLeadReg),
      initialSessionId: 'sess-lead',
      withMember: false,
    );
    expect(find.text('This machine'), findsNothing);
    expect(find.text('Studio'), findsNothing);
  });

  testWidgets('a lead lists itself first, then its member', (tester) async {
    await _pump(
      tester,
      initialTarget: const LocalProject(_kLeadReg),
      initialSessionId: 'sess-lead',
    );
    expect(find.text('This machine'), findsOneWidget);
    expect(find.text('Studio'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('This machine')).dx,
      lessThan(tester.getTopLeft(find.text('Studio')).dx),
    );
  });

  testWidgets(
    'pressing a member tab re-targets the project AND the session, and '
    'announces the pick to that machine',
    (tester) async {
      final h = await _pump(
        tester,
        initialTarget: const LocalProject(_kLeadReg),
        initialSessionId: 'sess-lead',
      );

      await tester.tap(find.text('Studio'));
      await tester.pump();
      await tester.pump();

      expect(
        h.target,
        const RemoteProject(machineUuid: _kPeerUuid, projectId: 'peer-proj'),
      );
      expect(h.activeSessionId, 'sess-peer');
      // The announcement is what clears the bridge's unread dot for the session
      // now on screen; a switch that skipped it would leave the peer's dot lit.
      expect(_announcedFocus(h.peerTransport, 'sess-peer'), isTrue);
    },
  );

  testWidgets('the lead tab brings the workspace back to the lead', (
    tester,
  ) async {
    final h = await _pump(
      tester,
      initialTarget: const RemoteProject(
        machineUuid: _kPeerUuid,
        projectId: 'peer-proj',
      ),
      initialSessionId: 'sess-peer',
    );
    // §7.5: the peer's own project renders the whole session, lead first, so
    // "back to the lead" is a fixed place rather than a search.
    expect(find.text('This machine'), findsOneWidget);
    expect(find.text('Studio'), findsOneWidget);

    await tester.tap(find.text('This machine'));
    await tester.pump();
    await tester.pump();

    expect(h.target, const LocalProject(_kLeadReg));
    expect(h.activeSessionId, 'sess-lead');
    expect(_announcedFocus(h.leadTransport, 'sess-lead'), isTrue);
  });

  // Pressing the tab already under view must not restart the whole switch —
  // it would re-announce the focus and churn the project registry for nothing.
  testWidgets('pressing the current tab is inert', (tester) async {
    final h = await _pump(
      tester,
      initialTarget: const LocalProject(_kLeadReg),
      initialSessionId: 'sess-lead',
    );
    h.leadTransport.sent.clear();

    await tester.tap(find.text('This machine'));
    await tester.pump();
    await tester.pump();

    expect(h.target, const LocalProject(_kLeadReg));
    expect(h.leadTransport.sent, isEmpty);
  });
}
