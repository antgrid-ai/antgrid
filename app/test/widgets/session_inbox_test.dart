// The mailbox sheet: what the bus does that neither the terminal nor the
// transcript can show. A `notify` is written into the PTY as a prompt and an
// outbound send is a tool call in the transcript, so what is only here is a
// parked post, the mailbox's own discards, and an outbound entry's receipt.
//
// It is opened from the session kebab (session_overflow_menu_test.dart) and
// nowhere else, never as a tab — so the one property this file guards above all
// is that it reads the session it was GIVEN, not the session in focus.
import 'dart:async';

import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/providers/session_bus_inbox.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/widgets/session_inbox_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _sessionId = 's1';

class _FakeChannel implements SessionBusChannel {
  final _frames = StreamController<Map<String, dynamic>>.broadcast();
  final sent = <Map<String, dynamic>>[];

  @override
  Stream<Map<String, dynamic>> get frames => _frames.stream;

  @override
  Future<void> send(Map<String, dynamic> message) async => sent.add(message);

  @override
  Future<void> hydrate(String key, Future<void> Function() run) => run();

  @override
  void unhydrate(String key) {}

  void emit(Map<String, dynamic> frame) => _frames.add(frame);

  Future<void> dispose() => _frames.close();

  Iterable<Map<String, dynamic>> get reads =>
      sent.where((m) => m['type'] == 'session-bus:inbox');

  String get lastRequestId => reads.last['requestId'] as String;
}

Map<String, dynamic> _post(String messageId) => {
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

/// Pumps [child] against a fake bus channel.
///
/// `activeSessionIdProvider` is overridden with a pre-seeded base controller,
/// as its own doc invites: the production notifier's write guard reads the
/// project's live session list, which no widget test stands up. [focused] is
/// separate from the session under test on purpose — the sheet is routinely
/// opened for a row that is NOT in focus, and defaulting them to the same value
/// would hide a panel that had gone back to reading focus.
Future<_FakeChannel> _pump(
  WidgetTester tester,
  Widget child, {
  String? focused = _sessionId,
}) async {
  final channel = _FakeChannel();
  addTearDown(channel.dispose);
  final container = ProviderContainer(
    overrides: [
      sessionBusChannelProvider.overrideWithValue(channel),
      activeSessionIdProvider.overrideWith(
        () => ValueController<String?>(focused),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData.dark().copyWith(
          extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
        ),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return channel;
}

/// Answers the mailbox read the surface under test made on hydration.
Future<void> _answerRead(
  WidgetTester tester,
  _FakeChannel channel, {
  required int unread,
  int dropped = 0,
}) async {
  channel.emit({
    'type': 'session-bus:inbox:result',
    'requestId': channel.lastRequestId,
    'posts': [for (var i = 0; i < unread; i++) _post('m$i')],
    'dropped': dropped,
  });
  await tester.pumpAndSettle();
}

SessionBusThreadEntry _outEntry({
  String? delivery,
  String? refusedCode,
  int? deliveredAt,
}) => SessionBusThreadEntry(
  outbound: true,
  at: 1700000000000,
  peer: const SessionBusAddress(
    machineId: 'm-other',
    projectId: 'p-other',
    sessionId: 's-other',
  ),
  summary: 'asked',
  text: const ['same 401?'],
  deliveredAt: deliveredAt,
  delivery: delivery,
  refusedCode: refusedCode,
);

void main() {
  group('the thread delivery stamp', () {
    Future<void> pumpEntry(WidgetTester tester, SessionBusThreadEntry e) =>
        tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: ThemeData.dark().copyWith(
                extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
              ),
              home: SizedBox(
                height: 600,
                child: SessionBusThreadEntries(entries: [e]),
              ),
            ),
          ),
        );

    testWidgets('each state renders its text', (tester) async {
      for (final c in const [
        ('held', 'Held'),
        ('relayed', 'Relayed'),
        ('refused', 'Refused'),
        ('delivered', 'Delivered'),
      ]) {
        await pumpEntry(tester, _outEntry(delivery: c.$1));
        expect(find.text(c.$2), findsOneWidget, reason: c.$1);
      }
    });

    testWidgets('delivered with a receipt time shows the time', (
      tester,
    ) async {
      await pumpEntry(
        tester,
        _outEntry(delivery: 'delivered', deliveredAt: 1700000000500),
      );
      expect(find.textContaining('Delivered '), findsOneWidget);
    });

    testWidgets('absent delivery falls back to the receipt', (tester) async {
      await pumpEntry(tester, _outEntry());
      expect(find.text('Sent'), findsOneWidget);
      await pumpEntry(tester, _outEntry(deliveredAt: 1700000000500));
      expect(find.textContaining('Delivered '), findsOneWidget);
    });

    testWidgets('a refusal shows its code beside the label, in mono', (
      tester,
    ) async {
      await pumpEntry(
        tester,
        _outEntry(delivery: 'refused', refusedCode: 'REMOTE_ACCESS_OFF'),
      );
      final stamp = find.text('Refused REMOTE_ACCESS_OFF');
      expect(stamp, findsOneWidget);

      final paragraph = tester.widget<RichText>(
        find.descendant(of: stamp, matching: find.byType(RichText)),
      );
      final families = <String, String?>{};
      paragraph.text.visitChildren((span) {
        if (span is TextSpan && span.text != null) {
          families[span.text!.trim()] = span.style?.fontFamily;
        }
        return true;
      });
      expect(families['Refused'], AbTokens.fontSans);
      expect(families['REMOTE_ACCESS_OFF'], AbTokens.fontMono);
    });

    testWidgets('a code shows only on a refusal', (tester) async {
      await pumpEntry(tester, _outEntry(delivery: 'refused'));
      expect(find.text('Refused'), findsOneWidget);

      await pumpEntry(
        tester,
        _outEntry(delivery: 'held', refusedCode: 'REMOTE_ACCESS_OFF'),
      );
      expect(find.text('Held'), findsOneWidget);
      expect(find.textContaining('REMOTE_ACCESS_OFF'), findsNothing);
    });
  });

  group('the mailbox', () {
    testWidgets('lists an unread post with its sender', (tester) async {
      final channel = await _pump(
        tester,
        const SessionInboxPanel(sessionId: _sessionId),
      );
      await _answerRead(tester, channel, unread: 1);

      expect(find.text('same 401 on token refresh?'), findsOneWidget);
      expect(find.text('p-other · s-other'), findsOneWidget);
    });

    // The whole reason the badge can be the way in. A sheet that read focus
    // would show the WRONG session's mail on every row but the open one, and
    // look completely correct doing it.
    testWidgets('reads the session it was given, not the one in focus', (
      tester,
    ) async {
      final channel = await _pump(
        tester,
        const SessionInboxPanel(sessionId: _sessionId),
        focused: 'some-other-session',
      );

      expect(
        channel.reads.map((m) => m['sessionId']).toSet(),
        {_sessionId},
      );
    });

    // The marking read is the AGENT's: a human glancing at this sheet must not
    // spend a post the agent has not been handed, or it vanishes unseen. The
    // app has no marking verb at all, and this is what keeps it that way.
    testWidgets('reading the panel sends nothing but the peek', (tester) async {
      final channel = await _pump(
        tester,
        const SessionInboxPanel(sessionId: _sessionId),
      );
      await _answerRead(tester, channel, unread: 2);

      expect(
        channel.sent.map((m) => m['type']).toSet(),
        {'session-bus:inbox'},
      );
    });

    // A LIFETIME total on the store, so it must not be worded as a delta —
    // "since you last looked" would re-accuse the mailbox of the same posts on
    // every visit. It must not name "the budget" either: the pair budget
    // refuses a send where its sender can read the refusal, and discards
    // nothing.
    testWidgets('the dropped tally is a running total of the MAILBOX', (
      tester,
    ) async {
      final channel = await _pump(
        tester,
        const SessionInboxPanel(sessionId: _sessionId),
      );
      await _answerRead(tester, channel, unread: 1, dropped: 2);

      expect(
        find.text(
          '2 posts aged out of this mailbox, or were pushed out of it when '
          'it filled.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('budget'), findsNothing);
    });
  });
}
