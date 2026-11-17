// The session kebab, on both breakpoints.
//
// Pumped through the real [AgentPanel] rather than the menu widget alone:
// which header mounts the kebab is half of what these assert, and the kebab
// itself is unconditional on both — the mode switch and the Handler row are
// always in it, whatever the session is or where it runs. The Messages row is
// the one that is not, and the group at the bottom is what holds it to that.

import 'dart:async';

import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/providers.dart'
    show
        TerminalClipboardActions,
        handlerStateProvider,
        terminalClipboardActionsProvider;
import 'package:antgrid/providers/session_mode.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/widgets/agent_panel.dart';
import 'package:antgrid/widgets/session_overflow_menu.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

const _localUuid = 'local-device-uuid';
const _peerUuid = 'peer-machine-uuid';
const _leadProjectId = 'lead-proj';

SessionEntry _session({String mode = 'chat'}) => SessionEntry(
  id: 'sess-lead',
  name: 'Trace the leak',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: true,
  mode: mode,
);

/// A Handler snapshot with one escalation waiting on a session other than the
/// focused `sess-lead`.
HandlerState _siblingWaiting() => const HandlerState.initial().copyWith(
  sessions: {
    'sess-other': HandlerSessionState(
      terminalId: 'sess-other',
      runState: HandlerRunState.needsYou,
      pendingEscalations: 1,
      armedAt: 1,
      goal: 'ship it',
      backlog: [],
      escalations: [],
    ),
  },
  escalations: [
    HandlerEscalation(
      escalationId: 'sess-other-1',
      terminalId: 'sess-other',
      question: 'q',
      reasoning: 'r',
      draftReply: 'd',
      urgency: 'normal',
      at: 1,
    ),
  ],
);

Future<void> _pump(
  WidgetTester tester, {
  required SessionEntry session,
  required SessionTarget target,
  required Size size,
  required TargetPlatform platform,
  TerminalClipboardActions? clipboard,
  HandlerState? handler,
  PendingSessionMode? pendingMode,
  GlobalKey<NavigatorState>? navigatorKey,
  Widget home = const Scaffold(body: AgentPanel()),
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
        if (handler != null)
          handlerStateProvider.overrideWith((ref) => Stream.value(handler)),
        if (pendingMode != null)
          pendingSessionModeProvider.overrideWith(
            () => ValueController<PendingSessionMode?>(pendingMode),
          ),
        if (clipboard != null)
          terminalClipboardActionsProvider.overrideWith(
            () => ValueController<TerminalClipboardActions?>(clipboard),
          ),
      ],
      child: MaterialApp(
        navigatorKey: navigatorKey,
        home: home,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  debugDefaultTargetPlatformOverride = null;
}

/// Never `pumpAndSettle`: the agent panel keeps a pulsing status animation up
/// for the whole test, so settling never arrives.
Future<void> _openKebab(WidgetTester tester) async {
  await tester.tap(find.byType(CarbonOverflowMenu));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(useInMemoryPrefs);

  group('carbon kebab', () {
    testWidgets('is a Carbon overflow menu on both breakpoints', (tester) async {
      await _pump(
        tester,
        session: _session(),
        target: const LocalProject(_leadProjectId),
        size: const Size(400, 800),
        platform: TargetPlatform.android,
      );
      expect(
        find.descendant(
          of: find.byType(SessionOverflowButton),
          matching: find.byType(CarbonOverflowMenu),
        ),
        findsOneWidget,
      );
    });

    testWidgets('every row keeps its order and copy', (tester) async {
      await _pump(
        tester,
        session: _session(),
        target: const LocalProject(_leadProjectId),
        size: const Size(400, 800),
        platform: TargetPlatform.android,
        handler: _siblingWaiting(),
        clipboard: TerminalClipboardActions(
          selectText: () {},
          paste: () {},
          copyHostClipboard: () => () {},
          attach: () => () {},
        ),
      );
      await _openKebab(tester);

      final labels = [
        'Switch to Terminal',
        'Arm Handler',
        'Answer another session',
        'Attach file',
        'Select text',
        'Paste',
        'Copy host clipboard',
      ];
      final tops = [
        for (final l in labels) tester.getTopLeft(find.text(l)).dy,
      ];
      expect(tops, orderedEquals([...tops]..sort()));
      expect(tops.toSet().length, labels.length);
    });

    Finder brandDot() => find.descendant(
      of: find.byType(SessionOverflowButton),
      matching: find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            w.child is SizedBox &&
            (w.child as SizedBox).width == CarbonSpacing.spacing03 &&
            (w.child as SizedBox).height == CarbonSpacing.spacing03,
      ),
    );

    testWidgets('no brand dot while no sibling waits', (tester) async {
      await _pump(
        tester,
        session: _session(),
        target: const LocalProject(_leadProjectId),
        size: const Size(400, 800),
        platform: TargetPlatform.android,
      );
      expect(brandDot(), findsNothing);
    });

    testWidgets('the brand dot shows while a sibling waits', (tester) async {
      await _pump(
        tester,
        session: _session(),
        target: const LocalProject(_leadProjectId),
        size: const Size(400, 800),
        platform: TargetPlatform.android,
        handler: _siblingWaiting(),
      );
      expect(brandDot(), findsOneWidget);
      final fill =
          (tester.widget<DecoratedBox>(brandDot()).decoration as BoxDecoration)
              .color;
      expect(
        {
          CarbonThemeData.forBrightness(Brightness.light).colors.backgroundBrand,
          CarbonThemeData.forBrightness(Brightness.dark).colors.backgroundBrand,
        },
        contains(fill),
      );
      // Painted outside layout: the trigger keeps one icon button's width.
      final trigger = find.descendant(
        of: find.byType(SessionOverflowButton),
        matching: find.byType(CarbonButton),
      );
      expect(
        tester.getSize(trigger).width,
        CarbonTheme.of(tester.element(trigger)).minTarget,
      );
    });

    testWidgets('a row runs its action without popping the page beneath', (
      tester,
    ) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      final calls = <String>[];
      // One AgentPanel only: its sheet-host GlobalKey is container-wide, so a
      // second panel in the tree would collide with it.
      await _pump(
        tester,
        session: _session(),
        target: const LocalProject(_leadProjectId),
        size: const Size(400, 800),
        platform: TargetPlatform.android,
        navigatorKey: navigatorKey,
        home: const Scaffold(key: Key('beneath'), body: SizedBox()),
        clipboard: TerminalClipboardActions(
          selectText: () => calls.add('select'),
          paste: () => calls.add('paste'),
          copyHostClipboard: () => null,
          attach: () => null,
        ),
      );
      unawaited(
        navigatorKey.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) =>
                const Scaffold(key: Key('pushed-page'), body: AgentPanel()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      await _openKebab(tester);
      await tester.tap(find.text('Paste'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(calls, ['paste']);
      expect(find.byKey(const Key('pushed-page')), findsOneWidget);
      expect(find.byType(CarbonOverflowMenu), findsOneWidget);
      expect(navigatorKey.currentState!.canPop(), isTrue);
    });

    testWidgets('a disabled mode row exposes its reason on tap', (
      tester,
    ) async {
      // A terminal session whose machine has not said the agent can chat.
      await _pump(
        tester,
        session: _session(mode: 'terminal'),
        target: const LocalProject(_leadProjectId),
        size: const Size(400, 800),
        platform: TargetPlatform.android,
      );
      await _openKebab(tester);

      expect(find.text('Switch to Chat UI'), findsOneWidget);
      // Either reason (capability unknown, or known unsupported) names chat
      // sessions; which one applies depends on what the machine has reported.
      expect(find.textContaining('chat sessions'), findsNothing);
      await tester.tap(find.text('Switch to Chat UI'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('chat sessions'), findsOneWidget);
      // The tap did not start a flip: no confirm dialog opened.
      expect(find.text('Switch to chat?'), findsNothing);
    });

    testWidgets('a flip in flight disables the mode row with a reason', (
      tester,
    ) async {
      await _pump(
        tester,
        session: _session(),
        target: const LocalProject(_leadProjectId),
        size: const Size(400, 800),
        platform: TargetPlatform.android,
        pendingMode: const PendingSessionMode(
          sessionId: 'sess-lead',
          mode: 'terminal',
        ),
      );
      await _openKebab(tester);

      // The pending target is already the rendered mode, so the row offers
      // the way back.
      await tester.tap(find.text('Switch to Chat UI'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Switching mode…'), findsOneWidget);
      expect(find.text('Switch to chat?'), findsNothing);
    });
  });

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

      expect(find.byType(CarbonOverflowMenu), findsOneWidget);
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
