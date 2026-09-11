// The session kebab, on both breakpoints.
//
// Pumped through the real [AgentPanel] rather than the menu widget alone:
// which header mounts the kebab is half of what these assert, and the kebab
// itself is unconditional on both — the mode switch, the Handler row and the
// session directory are always in it, whatever the session is or where it runs.
import 'dart:async';

import 'package:antgrid/design/ab_status_tone.dart';
import 'package:antgrid/design/widgets/ab_status_dot.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/providers/session_bus_inbox.dart';
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

/// A bus channel that only pushes. The kebab reads a count and never asks for
/// one, so a hydrator that stayed silent is the honest stand-in for a bridge
/// that has answered nothing yet.
class _FakeBusChannel implements SessionBusChannel {
  final _frames = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get frames => _frames.stream;

  @override
  Future<void> send(Map<String, dynamic> message) async {}

  @override
  Future<void> hydrate(String key, Future<void> Function() run) async {}

  @override
  void unhydrate(String key) {}

  void emit(Map<String, dynamic> frame) => _frames.add(frame);

  Future<void> dispose() => _frames.close();
}

Future<void> _pump(
  WidgetTester tester, {
  required SessionEntry session,
  required SessionTarget target,
  required Size size,
  required TargetPlatform platform,
  SessionBusChannel? busChannel,
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
        if (busChannel != null)
          sessionBusChannelProvider.overrideWithValue(busChannel),
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
    });
  });

  group('the attention dot', () {
    Future<_FakeBusChannel> pumpWithBus(WidgetTester tester) async {
      final channel = _FakeBusChannel();
      addTearDown(channel.dispose);
      await _pump(
        tester,
        session: _session(),
        target: const LocalProject(_leadProjectId),
        size: const Size(1000, 800),
        platform: TargetPlatform.macOS,
        busChannel: channel,
      );
      return channel;
    }

    testWidgets('stays dark while nothing is waiting', (tester) async {
      await pumpWithBus(tester);
      expect(find.byKey(const Key('session-attention-dot')), findsNothing);
    });

    testWidgets('mail lights the one dot the kebab already has', (
      tester,
    ) async {
      final channel = await pumpWithBus(tester);
      channel.emit({
        'type': 'session-bus:unread',
        'sessionId': 'sess-lead',
        'unread': 2,
        'dropped': 0,
      });
      await tester.pump();

      // ONE dot, not a second beside it: the kebab reports that something
      // behind it is waiting, and mail is one more thing that can be.
      final dots = find.byKey(const Key('session-attention-dot'));
      expect(dots, findsOneWidget);
      // Mail blocks nobody, so it takes the dot in its own tone rather than
      // borrowing the one an escalation uses.
      expect(tester.widget<AbStatusDot>(dots).tone, AbStatusTone.unread);
      // The dot cannot carry a number; the button says how many.
      expect(
        find.byTooltip(
          'Session options — 2 unread messages from other sessions',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a count for another session moves nothing', (tester) async {
      final channel = await pumpWithBus(tester);
      channel.emit({
        'type': 'session-bus:unread',
        'sessionId': 'sess-elsewhere',
        'unread': 5,
        'dropped': 0,
      });
      await tester.pump();

      expect(find.byKey(const Key('session-attention-dot')), findsNothing);
      expect(find.byTooltip('Session options'), findsOneWidget);
    });
  });
}
