// The session kebab, on both breakpoints.
//
// Pumped through the real [AgentPanel] rather than the menu widget alone:
// which header mounts the kebab is half of what these assert, and the kebab
// itself is unconditional on both — the mode switch and the Handler row are
// always in it, whatever the session is or where it runs. The Messages row is
// the one that is not, and the group at the bottom is what holds it to that.

import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/providers.dart'
    show TerminalClipboardActions, terminalClipboardActionsProvider;
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

SessionEntry _session() => SessionEntry(
  id: 'sess-lead',
  name: 'Trace the leak',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: true,
  mode: 'chat',
);

Future<void> _pump(
  WidgetTester tester, {
  required SessionEntry session,
  required SessionTarget target,
  required Size size,
  required TargetPlatform platform,
  TerminalClipboardActions? clipboard,
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
        if (clipboard != null)
          terminalClipboardActionsProvider.overrideWith(
            () => ValueController<TerminalClipboardActions?>(clipboard),
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(useInMemoryPrefs);

  group('terminal clipboard rows', () {
    testWidgets('a published terminal adds select, paste and host copy', (
      tester,
    ) async {
      final calls = <String>[];
      await _pump(
        tester,
        session: _session(),
        target: const LocalProject(_leadProjectId),
        size: const Size(400, 800),
        platform: TargetPlatform.android,
        clipboard: TerminalClipboardActions(
          selectText: () => calls.add('select'),
          paste: () => calls.add('paste'),
          copyHostClipboard: () =>
              () => calls.add('host'),
          attach: () =>
              () => calls.add('attach'),
        ),
      );
      await _openKebab(tester);

      expect(find.text('Attach file'), findsOneWidget);
      expect(find.text('Select text'), findsOneWidget);
      expect(find.text('Paste'), findsOneWidget);
      expect(find.text('Copy host clipboard'), findsOneWidget);

      await tester.tap(find.text('Paste'));
      await tester.pump();
      expect(calls, ['paste']);
      // The popup closes on the way.
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Paste'), findsNothing);
    });

    testWidgets('the desktop kebab carries them too', (tester) async {
      await _pump(
        tester,
        session: _session(),
        target: const LocalProject(_leadProjectId),
        size: const Size(1400, 900),
        platform: TargetPlatform.windows,
        clipboard: TerminalClipboardActions(
          selectText: () {},
          paste: () {},
          copyHostClipboard: () => () {},
          attach: () => () {},
        ),
      );
      await _openKebab(tester);

      expect(find.text('Attach file'), findsOneWidget);
      expect(find.text('Select text'), findsOneWidget);
      expect(find.text('Paste'), findsOneWidget);
      expect(find.text('Copy host clipboard'), findsOneWidget);
    });

    testWidgets('no host clipboard leaves only select and paste', (
      tester,
    ) async {
      await _pump(
        tester,
        session: _session(),
        target: const LocalProject(_leadProjectId),
        size: const Size(400, 800),
        platform: TargetPlatform.android,
        clipboard: TerminalClipboardActions(
          selectText: () {},
          paste: () {},
          copyHostClipboard: () => null,
          attach: () => null,
        ),
      );
      await _openKebab(tester);

      expect(find.text('Select text'), findsOneWidget);
      expect(find.text('Copy host clipboard'), findsNothing);
      expect(find.text('Attach file'), findsNothing);
    });

    testWidgets('nothing published adds no rows', (tester) async {
      await _pump(
        tester,
        session: _session(),
        target: const LocalProject(_leadProjectId),
        size: const Size(400, 800),
        platform: TargetPlatform.android,
      );
      await _openKebab(tester);

      expect(find.text('Select text'), findsNothing);
      expect(find.text('Paste'), findsNothing);
    });
  });

  group('desktop', () {
    testWidgets('the desktop kebab carries mode and Handler', (tester) async {
      // Both breakpoints now open the same menu — the mode switch and the
      // Handler row are no longer inline on this bar, so the kebab is the
      // one place a mouse session reaches them, same as on a phone.
      await _pump(
        tester,
        session: _session(),
        target: const LocalProject(_leadProjectId),
        size: const Size(1000, 800),
        platform: TargetPlatform.macOS,
      );

      expect(find.byType(AgentBar), findsOneWidget);
      await _openKebab(tester);

      expect(find.text('Switch to Terminal'), findsOneWidget);
      expect(find.text('Arm Handler'), findsOneWidget);
      expect(find.text('Messages'), findsNothing);
    });

    testWidgets('a session on another machine still offers mode and Handler', (
      tester,
    ) async {
      // The kebab is unconditional: nothing about it is derived from where the
      // session runs, so a session the user is only watching from here reaches
      // mode and Handler exactly as a local one does.
      await _pump(
        tester,
        session: _session(),
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
      expect(find.text('Messages'), findsNothing);
    });
  });

  group('mobile', () {
    testWidgets('the phone kebab carries the session\'s own rows', (
      tester,
    ) async {
      await _pump(
        tester,
        session: _session(),
        target: const LocalProject(_leadProjectId),
        size: const Size(400, 800),
        platform: TargetPlatform.android,
      );
      await _openKebab(tester);

      expect(find.text('Switch to Terminal'), findsOneWidget);
      expect(find.text('Arm Handler'), findsOneWidget);
      expect(find.text('Messages'), findsNothing);
    });
  });

}
