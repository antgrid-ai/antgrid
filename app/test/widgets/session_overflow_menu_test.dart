// The session kebab, on both breakpoints.
//
// Pumped through the real [AgentPanel] rather than the menu widget alone:
// which header mounts the kebab is half of what these assert, and the kebab
// itself is unconditional on both — the mode switch and the Handler row are
// always in it, whatever the session is or where it runs. The Messages row is
// the one that is not, and the group at the bottom is what holds it to that.
import 'dart:async';

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
import 'package:antgrid/widgets/session_inbox_panel.dart';
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

/// Drive one arrival end to end: the push, the read it triggers, and the
/// answer.
///
/// Called with the MENU OPEN, and that is not incidental. Nothing outside the
/// menu reads a session's mailbox any more, so nothing is subscribed to push at
/// until the kebab is opened — which is the whole shape of "no indication":
/// mail moves a surface only while someone is looking at one.
Future<void> _mailArrives(
  WidgetTester tester,
  _FakeBusChannel channel, {
  required int posts,
}) async {
  channel.emit({'type': 'session-bus:arrived', 'sessionId': 'sess-lead'});
  await tester.pump();
  channel.emit({
    'type': 'session-bus:inbox:result',
    'requestId': channel.pendingRequestId,
    'posts': [for (var i = 0; i < posts; i++) _inboxPost('m$i')],
    'dropped': 0,
  });
  await tester.pump();
}

/// One parked post, as the bridge answers a peek.
Map<String, dynamic> _inboxPost(String messageId) => {
  'messageId': messageId,
  'threadId': 't-1',
  'contextId': 'ctx-1',
  'at': 1700000000000,
  'from': {
    'machineId': 'm-other',
    'projectId': 'p-other',
    'sessionId': 's-other',
  },
  'summary': 'same 401 on token refresh?',
  'text': const <String>['line one'],
  'artifacts': const <Map<String, dynamic>>[],
};

/// A bus channel whose hydrator stays silent — the honest stand-in for a bridge
/// that has answered nothing yet — and which records what was asked of it, so a
/// test can answer the read an arrival push triggers.
class _FakeBusChannel implements SessionBusChannel {
  final _frames = StreamController<Map<String, dynamic>>.broadcast();
  final sent = <Map<String, dynamic>>[];

  @override
  Stream<Map<String, dynamic>> get frames => _frames.stream;

  @override
  Future<void> send(Map<String, dynamic> message) async => sent.add(message);

  @override
  Future<void> hydrate(String key, Future<void> Function() run) async {}

  @override
  void unhydrate(String key) {}

  void emit(Map<String, dynamic> frame) => _frames.add(frame);

  /// The id of the read still waiting for an answer.
  String get pendingRequestId =>
      sent.lastWhere((m) => m['type'] == 'session-bus:inbox')['requestId']
          as String;

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

    testWidgets('mail lights nothing — the bus is agent-to-agent', (
      tester,
    ) async {
      final channel = await pumpWithBus(tester);
      await _openKebab(tester);
      await _mailArrives(tester, channel, posts: 1);

      // The mail is demonstrably there — the row that opens it is in the menu —
      // and still nothing calls for the user. Nobody is blocked on them: the
      // dot is an escalation's alone, and the button says only what it opens.
      expect(find.text('Messages'), findsOneWidget);
      expect(find.byKey(const Key('session-attention-dot')), findsNothing);
      expect(find.byTooltip('Session options'), findsOneWidget);
    });
  });

  // The kebab is the ONLY door to the mailbox sheet: nothing announces a peer's
  // mail, so this row is what a person opens when they want to look.
  group('the Messages row', () {
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

    testWidgets('is absent while the session has never been on the bus', (
      tester,
    ) async {
      await pumpWithBus(tester);
      await _openKebab(tester);

      // A row promising a sheet with nothing in it is worse than no row: the
      // two things it exists for — discards, and an outbound receipt — cannot
      // be reached for a session the bus has never touched.
      expect(find.text('Messages'), findsNothing);
      // The kebab itself is up, so the absence above is an answer rather than
      // a menu that failed to open.
      expect(find.text('Arm Handler'), findsOneWidget);
    });

    testWidgets('appears once the session has bus traffic', (tester) async {
      final channel = await pumpWithBus(tester);
      await _openKebab(tester);
      await _mailArrives(tester, channel, posts: 2);

      expect(find.text('Messages'), findsOneWidget);
    });

    // Latching: the read that empties the mailbox is the AGENT's and can land
    // at any moment, including while the menu is open and the user is reaching
    // for this row.
    testWidgets('survives the agent emptying the mailbox', (tester) async {
      final channel = await pumpWithBus(tester);
      await _openKebab(tester);
      await _mailArrives(tester, channel, posts: 1);
      expect(find.text('Messages'), findsOneWidget);

      await _mailArrives(tester, channel, posts: 0);

      expect(find.text('Messages'), findsOneWidget);
    });

    testWidgets('opens the sheet for this session', (tester) async {
      final channel = await pumpWithBus(tester);
      await _openKebab(tester);
      await _mailArrives(tester, channel, posts: 1);

      await tester.tap(find.text('Messages'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final panel = tester.widget<SessionInboxPanel>(
        find.byType(SessionInboxPanel),
      );
      expect(panel.sessionId, 'sess-lead');
    });
  });
}
