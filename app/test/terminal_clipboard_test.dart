import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/services/terminal_clipboard_coordinator.dart';
import 'package:antgrid/services/terminal_clipboard_client.dart';
import 'package:antgrid/models/terminal_clipboard_message.dart';
import 'package:antgrid/models/ab_message.dart';

void main() {
  test(
    'delayed grant does not extend ownership beyond the original claim',
    () async {
      const context = (
        checkoutId: 'main',
        terminalId: 't',
        runId: 'run',
        attachmentId: 'attachment',
      );
      var now = 0;
      final writes = <String>[];
      final sent = <Map<String, dynamic>>[];
      final native = Completer<void>();
      final coordinator = TerminalClipboardCoordinator(
        write: (text) async {
          writes.add(text);
          if (text == 'first') await native.future;
        },
      );
      final client = TerminalClipboardClient(
        send: (message) {
          sent.add(message);
          return Future.value();
        },
        connected: () => true,
        coordinator: coordinator,
        now: () => now,
        newId: () => 'request',
      );
      client.contexts['t'] = context;
      client.foreground(Object(), 't');
      final first = coordinator.copyExplicit('first');
      client.beforeInput('t', 'x');
      now = 900;
      client.handle(
        const TerminalClipboardMessage(
          'terminal:clipboard:claimed',
          context,
          'request',
          'claim',
          1,
          5000,
          null,
          null,
          null,
        ),
      );
      now = 4900;
      client.handle(
        const TerminalClipboardMessage(
          'terminal:clipboard:write',
          context,
          null,
          'claim',
          1,
          null,
          'event',
          'expired text',
          null,
        ),
      );
      now = 5001;
      native.complete();
      expect(await first, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(sent.last['outcome'], 'stale');
      expect(writes, ['first']);
      client.dispose();
    },
  );
  test(
    'wire parser validates direction, envelope, outcomes and encoded size',
    () {
      const id = '123e4567-e89b-42d3-a456-426614174000';
      final envelope = <String, dynamic>{
        'id': id,
        'timestamp': 1,
        'type': 'terminal:clipboard:write',
        'checkoutId': 'main',
        'terminalId': 't',
        'runId': id,
        'attachmentId': id,
        'claimId': id,
        'epoch': 1,
        'eventId': id,
        'text': base64.encode(utf8.encode('text')),
      };
      expect(parseAbMessage(envelope), isA<TerminalClipboardMessage>());
      for (final change in <Map<String, dynamic>>[
        {'type': 'terminal:clipboard:claim'},
        {'type': 'terminal:clipboard:result'},
        {'type': 'something:unknown'},
        {'id': 'invalid'},
        {
          'id': {'not': 'a string'},
        },
        {'timestamp': 'invalid'},
        {'timestamp': double.infinity},
        {'metadata': 'a' * (140 * 1024)},
        {'metadata': List.filled(50000, 'x')},
        {'metadata': '\x00' * 25000},
        {'metadata': '界' * 50000},
      ]) {
        expect(
          TerminalClipboardMessage.parse({...envelope, ...change}),
          isNull,
        );
      }
      expect(
        parseAbMessage({
          ...envelope,
          'id': {'invalid': 'value'},
        }),
        isNull,
      );
      final host = {
        ...envelope,
        'type': 'terminal:clipboard:host-text',
        'requestId': id,
      };
      expect(
        TerminalClipboardMessage.parse({...host, 'error': 'failed'}),
        isNull,
      );
      expect(
        TerminalClipboardMessage.parse({
          ...host,
          'text': null,
          'error': 'failed',
        }),
        isA<TerminalClipboardMessage>(),
      );
    },
  );
  test(
    'write acknowledgement waits for native completion and rejects old epoch',
    () async {
      const context = (
        checkoutId: 'main',
        terminalId: 't',
        runId: 'run',
        attachmentId: 'attachment',
      );
      final sent = <Map<String, dynamic>>[];
      final native = Completer<void>();
      final writes = <String>[];
      final coordinator = TerminalClipboardCoordinator(
        write: (text) async {
          writes.add(text);
          await native.future;
        },
      );
      final client = TerminalClipboardClient(
        send: (message) {
          sent.add(message);
          return Future.value();
        },
        connected: () => true,
        coordinator: coordinator,
        now: () => 0,
        newId: () => 'request',
      );
      client.contexts['t'] = context;
      client.foreground(Object(), 't');
      client.beforeInput('t', 'x');
      client.handle(
        const TerminalClipboardMessage(
          'terminal:clipboard:claimed',
          context,
          'request',
          'claim',
          1,
          5000,
          null,
          null,
          null,
        ),
      );
      client.handle(
        const TerminalClipboardMessage(
          'terminal:clipboard:write',
          context,
          null,
          'claim',
          1,
          null,
          'event',
          'copied text',
          null,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(writes, ['copied text']);
      expect(
        sent.where((m) => m['type'] == 'terminal:clipboard:result'),
        isEmpty,
      );
      native.complete();
      await Future<void>.delayed(Duration.zero);
      expect(sent.last['outcome'], 'copied');
      client.handle(
        const TerminalClipboardMessage(
          'terminal:clipboard:write',
          context,
          null,
          'claim',
          2,
          null,
          'next',
          'stale text',
          null,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(sent.last['outcome'], 'stale');
      expect(writes, ['copied text']);
      client.dispose();
    },
  );

  test('queued host reply cannot run after its request deadline', () async {
    const context = (
      checkoutId: 'main',
      terminalId: 't',
      runId: 'run',
      attachmentId: 'attachment',
    );
    var now = 0;
    final native = Completer<void>();
    final writes = <String>[];
    final coordinator = TerminalClipboardCoordinator(
      write: (text) async {
        writes.add(text);
        if (text == 'first') await native.future;
      },
    );
    final client = TerminalClipboardClient(
      send: (_) => Future.value(),
      connected: () => true,
      coordinator: coordinator,
      now: () => now,
      newId: () => 'request',
    );
    client.contexts['t'] = context;
    client.foreground(Object(), 't');
    final first = coordinator.copyExplicit('first');
    await Future<void>.delayed(Duration.zero);
    final host = client.readHost('t');
    client.handle(
      const TerminalClipboardMessage(
        'terminal:clipboard:host-text',
        context,
        'request',
        null,
        null,
        null,
        null,
        'host text',
        null,
      ),
    );
    now = 3001;
    native.complete();
    expect(await first, isTrue);
    expect(await host, isFalse);
    expect(writes, ['first']);
    client.dispose();
  });

  test(
    'opt-out prevents automatic delivery while explicit writes work',
    () async {
      final writes = <String>[];
      final coordinator = TerminalClipboardCoordinator(
        write: (text) async {
          writes.add(text);
        },
      );
      final connection = Object();
      coordinator.register(
        Object(),
        connection,
        't',
        programCopies: true,
        release: () {},
      );
      coordinator.allowed = false;
      expect(
        await coordinator.copyProgram(
          'program',
          connection: connection,
          terminal: 't',
          eventId: 'event',
          valid: () => true,
        ),
        'denied',
      );
      expect(await coordinator.copyExplicit('explicit'), isTrue);
      expect(writes, ['explicit']);
    },
  );
  test('payload validation preserves Unicode and rejects invalid encoding', () {
    expect(
      TerminalClipboardMessage.decodeText(base64.encode(utf8.encode('你好\n🌍'))),
      '你好\n🌍',
    );
    for (final input in [
      '',
      '!!!!',
      '/w==',
      'YQ=',
      'AB==',
      'AA==',
      base64.encode(List.filled(100001, 65)),
    ]) {
      expect(TerminalClipboardMessage.decodeText(input), isNull);
    }
  });

  test(
    'explicit copy wins after in-progress write and invalidates queued programs',
    () async {
      final writes = <String>[];
      final pending = Completer<void>();
      final coordinator = TerminalClipboardCoordinator(
        write: (text) async {
          writes.add(text);
          if (text == 'first') await pending.future;
        },
      );
      final connection = Object();
      coordinator.register(
        Object(),
        connection,
        't',
        programCopies: true,
        release: () {},
      );
      final first = coordinator.copyProgram(
        'first',
        connection: connection,
        terminal: 't',
        eventId: '1',
        valid: () => true,
      );
      await Future<void>.delayed(Duration.zero);
      final stale = coordinator.copyProgram(
        'stale',
        connection: connection,
        terminal: 't',
        eventId: '2',
        valid: () => true,
      );
      final explicit = coordinator.copyExplicit('explicit');
      pending.complete();
      expect(await first, 'copied');
      expect(await stale, 'stale');
      expect(await explicit, isTrue);
      expect(writes, ['first', 'explicit']);
    },
  );

  test(
    'duplicate surfaces cannot copy one event twice and failed writes return failure',
    () async {
      var writes = 0;
      final connection = Object();
      final coordinator = TerminalClipboardCoordinator(
        write: (_) async {
          writes++;
          throw StateError('failure');
        },
      );
      coordinator.register(
        Object(),
        connection,
        't',
        programCopies: true,
        release: () {},
      );
      expect(
        await coordinator.copyProgram(
          'text',
          connection: connection,
          terminal: 't',
          eventId: 'same',
          valid: () => true,
        ),
        'failed',
      );
      expect(
        await coordinator.copyProgram(
          'text',
          connection: connection,
          terminal: 't',
          eventId: 'same',
          valid: () => true,
        ),
        'stale',
      );
      expect(writes, 1);
      expect(await coordinator.copyExplicit('text'), isFalse);
    },
  );

  test(
    'foreground release invalidates a program waiting for the platform',
    () async {
      final pending = Completer<void>();
      final writes = <String>[];
      final owner = Object(), connection = Object();
      final coordinator = TerminalClipboardCoordinator(
        write: (text) async {
          writes.add(text);
          if (text == 'first') await pending.future;
        },
      );
      coordinator.register(
        owner,
        connection,
        't',
        programCopies: true,
        release: () {},
      );
      final first = coordinator.copyExplicit('first');
      await Future<void>.delayed(Duration.zero);
      final next = coordinator.copyProgram(
        'next',
        connection: connection,
        terminal: 't',
        eventId: 'event',
        valid: () => true,
      );
      coordinator.unregister(owner);
      pending.complete();
      expect(await first, isTrue);
      expect(await next, 'stale');
      expect(writes, ['first']);
    },
  );

  test(
    'claim is synchronously sent before input; passive reports do not claim',
    () {
      final sent = <String>[];
      final coordinator = TerminalClipboardCoordinator(write: (_) async {});
      final client = TerminalClipboardClient(
        send: (message) {
          sent.add(message['type'] as String);
          return Future.value();
        },
        connected: () => true,
        coordinator: coordinator,
      );
      client.contexts['t'] = (
        checkoutId: 'main',
        terminalId: 't',
        runId: 'run',
        attachmentId: 'attachment',
      );
      client.foreground(Object(), 't');
      client.beforeInput('t', '\x1b[I');
      client.beforeInput('t', '\x1b[<64;1;1M');
      client.beforeInput('t', '\x1b[<32;1;1M');
      expect(sent, isEmpty);
      client.beforeInput('t', 'keyboard');
      sent.add('terminal:input');
      expect(sent, ['terminal:clipboard:claim', 'terminal:input']);
      client.dispose();
    },
  );
}
