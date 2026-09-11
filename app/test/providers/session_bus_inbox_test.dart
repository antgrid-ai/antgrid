// Nothing announces a peer's mail, so the arrival push is the ONLY thing that
// moves a mailbox between reads — and it carries no contents, which makes the
// re-read it triggers load-bearing rather than an optimisation. These pin what
// a widget test cannot: that a read seeds the sheet, and that a push re-reads
// for the session it names and for no other.
import 'dart:async';

import 'package:antgrid/providers/session_bus_inbox.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeChannel implements SessionBusChannel {
  final _frames = StreamController<Map<String, dynamic>>.broadcast();
  final sent = <Map<String, dynamic>>[];
  final hydrators = <String, Future<void> Function()>{};

  @override
  Stream<Map<String, dynamic>> get frames => _frames.stream;

  @override
  Future<void> send(Map<String, dynamic> message) async => sent.add(message);

  @override
  Future<void> hydrate(String key, Future<void> Function() run) async {
    hydrators[key] = run;
    await run();
  }

  @override
  void unhydrate(String key) => hydrators.remove(key);

  void emit(Map<String, dynamic> frame) => _frames.add(frame);

  Future<void> dispose() => _frames.close();

  /// The request id of the nth `session-bus:inbox` this channel was asked to
  /// send.
  String requestIdAt(int index) =>
      sent.where((m) => m['type'] == 'session-bus:inbox').elementAt(index)['requestId']
          as String;

  int get inboxReads =>
      sent.where((m) => m['type'] == 'session-bus:inbox').length;
}

Map<String, dynamic> _post(String messageId, {String? threadId}) => {
  'messageId': messageId,
  'threadId': threadId,
  'contextId': 'ctx-1',
  'at': 1700000000000,
  'from': {
    'machineId': 'm-other',
    'projectId': 'p-other',
    'sessionId': 's-other',
  },
  'summary': 'a summary',
  'text': ['line one', 'line two'],
  'artifacts': const <Map<String, dynamic>>[],
};

ProviderContainer _containerWith(_FakeChannel channel) {
  final container = ProviderContainer(
    overrides: [sessionBusChannelProvider.overrideWithValue(channel)],
  );
  addTearDown(container.dispose);
  addTearDown(channel.dispose);
  return container;
}

void main() {
  test('the read seeds the drop tally and the posts', () async {
    final channel = _FakeChannel();
    final container = _containerWith(channel);

    final sub = container.listen(sessionInboxProvider('s1'), (_, _) {});
    expect(sub.read().loading, isTrue);
    await pumpEventQueue();

    expect(channel.inboxReads, 1);
    expect(channel.sent.single['sessionId'], 's1');

    channel.emit({
      'type': 'session-bus:inbox:result',
      'requestId': channel.requestIdAt(0),
      'posts': [_post('m1'), _post('m2', threadId: 't-9')],
      'dropped': 3,
    });
    await pumpEventQueue();

    final state = sub.read();
    expect(state.dropped, 3);
    expect(state.posts.map((p) => p.messageId), ['m1', 'm2']);
    expect(state.posts.first.threadId, isNull);
    expect(state.posts.last.threadId, 't-9');
    expect(state.posts.first.from.sessionId, 's-other');
    expect(state.posts.first.text, ['line one', 'line two']);
    expect(state.refusal, isNull);
  });

  test('a push re-reads, because it carries nothing to render', () async {
    final channel = _FakeChannel();
    final container = _containerWith(channel);

    final sub = container.listen(sessionInboxProvider('s1'), (_, _) {});
    await pumpEventQueue();
    channel.emit({
      'type': 'session-bus:inbox:result',
      'requestId': channel.requestIdAt(0),
      'posts': [_post('m1')],
      'dropped': 0,
    });
    await pumpEventQueue();
    expect(channel.inboxReads, 1);

    channel.emit({'type': 'session-bus:arrived', 'sessionId': 's1'});
    await pumpEventQueue();

    // The push is a signal, not an answer: without the read it triggers, the
    // sheet would render the connect-time mailbox for the life of the socket.
    expect(channel.inboxReads, 2);
    expect(sub.read().generation, 1);

    channel.emit({
      'type': 'session-bus:inbox:result',
      'requestId': channel.requestIdAt(1),
      'posts': [_post('m1'), _post('m2')],
      'dropped': 0,
    });
    await pumpEventQueue();

    expect(sub.read().posts.map((p) => p.messageId), ['m1', 'm2']);
  });

  test("a push for another session does not re-read this one", () async {
    final channel = _FakeChannel();
    final container = _containerWith(channel);

    final sub = container.listen(sessionInboxProvider('s1'), (_, _) {});
    await pumpEventQueue();
    channel.emit({
      'type': 'session-bus:inbox:result',
      'requestId': channel.requestIdAt(0),
      'posts': const <Map<String, dynamic>>[],
      'dropped': 0,
    });
    await pumpEventQueue();

    channel.emit({'type': 'session-bus:arrived', 'sessionId': 's2'});
    await pumpEventQueue();

    expect(channel.inboxReads, 1);
    expect(sub.read().generation, 0);
  });

  test('a refusal is surfaced, never rendered as an empty mailbox', () async {
    final channel = _FakeChannel();
    final container = _containerWith(channel);

    final sub = container.listen(sessionInboxProvider('s1'), (_, _) {});
    await pumpEventQueue();
    channel.emit({
      'type': 'session-bus:inbox:result',
      'requestId': channel.requestIdAt(0),
      'error': 'This terminal is not a session.',
      'code': 'NOT_MEMBER',
    });
    await pumpEventQueue();

    expect(sub.read().refusal?.code, 'NOT_MEMBER');
    expect(sub.read().refusal.toString(), 'This terminal is not a session.');
    expect(sub.read().loading, isFalse);
  });

  test('a superseded read cannot overwrite the current one', () async {
    final channel = _FakeChannel();
    final container = _containerWith(channel);

    final sub = container.listen(sessionInboxProvider('s1'), (_, _) {});
    await pumpEventQueue();
    final stale = channel.requestIdAt(0);

    await container.read(sessionInboxProvider('s1').notifier).refresh();
    await pumpEventQueue();
    channel.emit({
      'type': 'session-bus:inbox:result',
      'requestId': channel.requestIdAt(1),
      'posts': [_post('fresh')],
      'dropped': 0,
    });
    channel.emit({
      'type': 'session-bus:inbox:result',
      'requestId': stale,
      'posts': const <Map<String, dynamic>>[],
      'dropped': 0,
    });
    await pumpEventQueue();

    expect(sub.read().posts.single.messageId, 'fresh');
  });

  test('a reconnect re-drives the read, so the sheet is not left stale', () async {
    final channel = _FakeChannel();
    final container = _containerWith(channel);

    container.listen(sessionInboxProvider('s1'), (_, _) {});
    await pumpEventQueue();
    expect(channel.hydrators, contains('session-bus:inbox:s1'));

    await channel.hydrators['session-bus:inbox:s1']!();

    expect(channel.inboxReads, 2);
  });

  test('the thread read answers the entries and their receipts', () async {
    final channel = _FakeChannel();
    final container = _containerWith(channel);

    final sub = container.listen(
      sessionBusThreadProvider((sessionId: 's1', threadId: 't-9')),
      (_, _) {},
    );
    await pumpEventQueue();

    final request = channel.sent.firstWhere(
      (m) => m['type'] == 'session-bus:thread',
    );
    expect(request['threadId'], 't-9');
    expect(request['sessionId'], 's1');

    channel.emit({
      'type': 'session-bus:thread:result',
      'requestId': request['requestId'],
      'threadId': 't-9',
      'contextId': 'ctx-1',
      'entries': [
        {
          'direction': 'out',
          'at': 1700000000000,
          'peer': {
            'machineId': 'm-other',
            'projectId': 'p-other',
            'sessionId': 's-other',
          },
          'summary': 'asked',
          'text': ['same 401?'],
          'deliveredAt': 1700000000500,
        },
        {
          'direction': 'in',
          'at': 1700000001000,
          'peer': {
            'machineId': 'm-other',
            'projectId': 'p-other',
            'sessionId': 's-other',
          },
          'summary': 'answered',
          'text': ['yes'],
        },
      ],
    });
    await pumpEventQueue();

    final thread = sub.read().requireValue;
    expect(thread.contextId, 'ctx-1');
    expect(thread.entries.first.outbound, isTrue);
    expect(thread.entries.first.deliveredAt, 1700000000500);
    // Inbound entries carry no receipt, and its absence is not a failure.
    expect(thread.entries.last.outbound, isFalse);
    expect(thread.entries.last.deliveredAt, isNull);
  });

  test('a refused thread answers as data, not a thrown error', () async {
    final channel = _FakeChannel();
    final container = _containerWith(channel);

    final sub = container.listen(
      sessionBusThreadProvider((sessionId: 's1', threadId: 'gone')),
      (_, _) {},
    );
    await pumpEventQueue();
    final request = channel.sent.firstWhere(
      (m) => m['type'] == 'session-bus:thread',
    );

    channel.emit({
      'type': 'session-bus:thread:result',
      'requestId': request['requestId'],
      'threadId': 'gone',
      'error': 'No thread by that name.',
      'code': 'UNKNOWN_PEER',
    });
    await pumpEventQueue();

    // Not `.error`: a thrown SessionBusRefusal or TimeoutException is neither
    // a ProviderException nor an Error, so Riverpod's default retry policy
    // retries it up to 10 times, and every retry sits in AsyncLoading with
    // isReloading true — which `.when` renders as the loading arm, never the
    // error arm, for the whole backoff. Answering as data is what a reader
    // can actually see.
    expect(sub.read().hasError, isFalse);
    final thread = sub.read().requireValue;
    expect(thread.refusal?.code, 'UNKNOWN_PEER');
    expect(thread.refusal.toString(), 'No thread by that name.');
    expect(thread.entries, isEmpty);
  });

  test(
    'a refused thread read never settles into a retried loading state',
    () async {
      final channel = _FakeChannel();
      final container = _containerWith(channel);

      final sub = container.listen(
        sessionBusThreadProvider((sessionId: 's1', threadId: 'gone')),
        (_, _) {},
      );
      await pumpEventQueue();
      final request = channel.sent.firstWhere(
        (m) => m['type'] == 'session-bus:thread',
      );

      channel.emit({
        'type': 'session-bus:thread:result',
        'requestId': request['requestId'],
        'threadId': 'gone',
        'error': 'No thread by that name.',
        'code': 'UNKNOWN_PEER',
      });
      // Long enough to cross the first default retry backoff step (200ms)
      // were this provider still throwing — a reader stuck on "Reading the
      // thread…" through that retry is the bug this pins.
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final value = sub.read();
      expect(value.isLoading, isFalse);
      expect(value.requireValue.refusal?.code, 'UNKNOWN_PEER');
    },
  );
}
