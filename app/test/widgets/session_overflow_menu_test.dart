// The session kebab's membership section, on both breakpoints.
//
// Pumped through the real [AgentPanel] rather than the menu widget alone:
// which header mounts the kebab is half of what these assert, and the kebab
// itself is unconditional on both — it always offers mode and Handler, with
// membership actions layered in only when the session has any to offer.
import 'package:antgrid/design/widgets/ab_menu.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/widgets/agent_panel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

const _localUuid = 'local-device-uuid';
const _peerUuid = 'peer-machine-uuid';
const _leadProjectId = 'lead-proj';

SessionMemberRef _leadRef() => const SessionMemberRef(
  machineId: _localUuid,
  projectId: _leadProjectId,
  sessionId: 'sess-lead',
  machineLabel: 'This machine',
);

SessionEntry _lead({int members = 0}) => SessionEntry(
  id: 'sess-lead',
  name: 'Trace the leak',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: true,
  mode: 'chat',
  members: [
    for (var i = 0; i < members; i++)
      SessionMember(
        ref: SessionMemberRef(
          machineId: 'peer-$i',
          projectId: 'peer-proj',
          sessionId: 'sess-peer-$i',
        ),
        joinedAt: 1,
      ),
  ],
);

SessionEntry _peer() => SessionEntry(
  id: 'sess-peer',
  name: 'Trace the leak',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: true,
  mode: 'chat',
  memberOf: SessionMemberOf(ref: _leadRef(), joinedAt: 1),
);

Future<void> _pump(
  WidgetTester tester, {
  required SessionEntry session,
  required SessionTarget target,
  required Size size,
  required TargetPlatform platform,
}) async {
  debugDefaultTargetPlatformOverride = platform;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final stores = await buildTestStoreOverrides();
  addTearDown(stores.close);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...stores.overrides,
        selectedTargetProvider.overrideWith(
          () => ValueController<SessionTarget?>(target),
        ),
        activeSessionProvider.overrideWithValue(session),
        activeSessionIdProvider.overrideWith(() => ValueController(session.id)),
        localDeviceUuidProvider.overrideWith((ref) async => _localUuid),
        accountAgentsProvider.overrideWith(
          (_) async => const <InventoryAgent>[],
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: AgentPanel())),
    ),
  );
  await tester.pump();
  await tester.pump();
  debugDefaultTargetPlatformOverride = null;
}

/// Never `pumpAndSettle`: the agent panel keeps a pulsing status animation up
/// for the whole test, so settling never arrives.
Future<void> _openKebab(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Session options'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

AbLiveMenuRow _row(WidgetTester tester, String label) => tester
    .widgetList<AbLiveMenuRow>(find.byType(AbLiveMenuRow))
    .firstWhere((r) => r.label == label);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(useInMemoryPrefs);

  group('desktop', () {
    testWidgets('a local lead session offers Add machine and not Remove', (
      tester,
    ) async {
      await _pump(
        tester,
        session: _lead(),
        target: const LocalProject(_leadProjectId),
        size: const Size(1000, 800),
        platform: TargetPlatform.macOS,
      );

      expect(find.byType(AgentBar), findsOneWidget);
      await _openKebab(tester);

      expect(find.text('Add machine'), findsOneWidget);
      expect(find.text('Remove from session'), findsNothing);
    });

    testWidgets(
      'the desktop kebab carries mode and Handler alongside membership',
      (tester) async {
        // Both breakpoints now open the same menu — the mode switch and the
        // Handler row are no longer inline on this bar, so the kebab is the
        // one place a mouse session reaches them, same as on a phone.
        await _pump(
          tester,
          session: _lead(),
          target: const LocalProject(_leadProjectId),
          size: const Size(1000, 800),
          platform: TargetPlatform.macOS,
        );
        await _openKebab(tester);

        expect(find.text('Switch to Terminal'), findsOneWidget);
        expect(find.text('Arm Handler'), findsOneWidget);
        expect(find.text('Add machine'), findsOneWidget);
      },
    );

    testWidgets(
      'a session on another machine still offers mode and Handler, without membership',
      (tester) async {
        // The carrier is the app on the lead's own machine (D7), so a lead
        // the user is only watching from here has nothing to add a machine
        // to — but the kebab itself is unconditional, so mode and Handler
        // stay reachable regardless.
        await _pump(
          tester,
          session: _lead(),
          target: const RemoteProject(
            machineUuid: _peerUuid,
            projectId: 'watched-proj',
          ),
          size: const Size(1000, 800),
          platform: TargetPlatform.macOS,
        );

        expect(find.byTooltip('Session options'), findsOneWidget);
        await _openKebab(tester);

        expect(find.text('Switch to Terminal'), findsOneWidget);
        expect(find.text('Arm Handler'), findsOneWidget);
        expect(find.text('Add machine'), findsNothing);
        expect(find.text('Remove from session'), findsNothing);
      },
    );

    testWidgets('a full session keeps Add machine, disabled', (tester) async {
      await _pump(
        tester,
        session: _lead(members: kMaxSessionMembers),
        target: const LocalProject(_leadProjectId),
        size: const Size(1000, 800),
        platform: TargetPlatform.macOS,
      );
      await _openKebab(tester);

      expect(find.text('Add machine'), findsOneWidget);
      expect(_row(tester, 'Add machine').enabled, isFalse);
    });

    testWidgets('a peer tab offers Remove from session and not Add', (
      tester,
    ) async {
      await _pump(
        tester,
        session: _peer(),
        target: const RemoteProject(
          machineUuid: _peerUuid,
          projectId: 'peer-proj',
        ),
        size: const Size(1000, 800),
        platform: TargetPlatform.macOS,
      );
      await _openKebab(tester);

      expect(find.text('Remove from session'), findsOneWidget);
      expect(find.text('Add machine'), findsNothing);
    });
  });

  group('mobile', () {
    testWidgets('the phone kebab carries membership under its own rows', (
      tester,
    ) async {
      await _pump(
        tester,
        session: _lead(),
        target: const LocalProject(_leadProjectId),
        size: const Size(400, 800),
        platform: TargetPlatform.android,
      );
      await _openKebab(tester);

      // The phone folds the session's own controls in here too, so membership
      // has to sit alongside them rather than replace them.
      expect(find.text('Arm Handler'), findsOneWidget);
      expect(find.text('Add machine'), findsOneWidget);
      expect(find.text('Remove from session'), findsNothing);
    });

    testWidgets('a peer tab offers Remove from session', (tester) async {
      await _pump(
        tester,
        session: _peer(),
        target: const RemoteProject(
          machineUuid: _peerUuid,
          projectId: 'peer-proj',
        ),
        size: const Size(400, 800),
        platform: TargetPlatform.android,
      );
      await _openKebab(tester);

      expect(find.text('Remove from session'), findsOneWidget);
      expect(find.text('Add machine'), findsNothing);
    });
  });
}
