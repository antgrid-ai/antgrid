import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:antgrid/analytics/crash_reporting.dart';

void main() {
  test(
    'scrubber removes file paths and prompt-like content from the message',
    () {
      final event = SentryEvent(
        message: SentryMessage(
          'Failed reading C:/Users/me/project/secret.dart',
        ),
        breadcrumbs: [Breadcrumb(message: 'opened /home/me/repo/notes.md')],
      );
      final scrubbed = scrubCrashEvent(event)!;
      expect(scrubbed.message?.formatted ?? '', isNot(contains('secret.dart')));
      expect(scrubbed.message?.formatted ?? '', isNot(contains('C:/Users')));
      final crumbs =
          scrubbed.breadcrumbs?.map((b) => b.message ?? '').join() ?? '';
      expect(crumbs, isNot(contains('notes.md')));
    },
  );

  // C1: exception .value is a primary leak vector (e.g. FileSystemException
  // carrying a full path in its message).
  test('scrubber redacts paths in exception values (C1)', () {
    final event = SentryEvent(
      exceptions: [
        SentryException(
          type: 'FileSystemException',
          value: 'Cannot open /home/me/project/secret.dart: No such file',
        ),
      ],
    );
    final scrubbed = scrubCrashEvent(event)!;
    final value = scrubbed.exceptions?.first.value ?? '';
    expect(value, isNot(contains('/home/me/project')));
    expect(value, isNot(contains('secret.dart')));
    expect(value, contains('<redacted-path>'));
    // Non-path text is preserved.
    expect(value, contains('Cannot open'));
  });

  // C2: breadcrumb .data map — string values are redacted, non-string
  // values (e.g. ints) are left untouched.
  test(
    'scrubber redacts string values in breadcrumb data, preserves non-strings (C2)',
    () {
      final event = SentryEvent(
        breadcrumbs: [
          Breadcrumb(
            message: 'nav',
            data: {'route': '/home/me/repo/notes.md', 'count': 3},
          ),
        ],
      );
      final scrubbed = scrubCrashEvent(event)!;
      final data = scrubbed.breadcrumbs!.first.data!;
      expect(data['route'], isNot(contains('/home/me/repo')));
      expect(data['route'], contains('<redacted-path>'));
      // Non-string value must survive intact.
      expect(data['count'], equals(3));
    },
  );

  // I1: stack-frame absPath can expose the machine/user path prefix.
  test('scrubber redacts absPath on stack frames (I1)', () {
    final event = SentryEvent(
      exceptions: [
        SentryException(
          type: 'StateError',
          value: 'Bad state',
          stackTrace: SentryStackTrace(
            frames: [
              SentryStackFrame(
                absPath: 'C:/Users/me/project/lib/secret.dart',
                fileName: 'secret.dart',
                function: 'myFunction',
                lineNo: 42,
              ),
            ],
          ),
        ),
      ],
    );
    final scrubbed = scrubCrashEvent(event)!;
    final frame = scrubbed.exceptions!.first.stackTrace!.frames.first;
    expect(frame.absPath, isNot(contains('C:/Users/me')));
    expect(frame.absPath, contains('<redacted-path>'));
    // fileName (bare basename from our own source) is preserved.
    expect(frame.fileName, equals('secret.dart'));
    // Other frame metadata is not lost.
    expect(frame.function, equals('myFunction'));
    expect(frame.lineNo, equals(42));
  });

  // M1: a breadcrumb with a null message must stay null, not become "".
  test(
    'scrubber preserves null breadcrumb message as null, not empty string (M1)',
    () {
      final event = SentryEvent(
        breadcrumbs: [Breadcrumb(message: null, category: 'navigation')],
      );
      final scrubbed = scrubCrashEvent(event)!;
      expect(scrubbed.breadcrumbs!.first.message, isNull);
    },
  );

  // The crashing isolate is attached as a THREAD before beforeSend runs; its
  // stacktrace carries the same paths/source as exceptions and must be scrubbed.
  test(
    'scrubber redacts thread stacktrace paths and drops source snippets',
    () {
      final event = SentryEvent(
        threads: [
          SentryThread(
            id: 1,
            crashed: true,
            stacktrace: SentryStackTrace(
              frames: [
                SentryStackFrame(
                  absPath: 'C:/Users/me/project/lib/secret.dart',
                  fileName: 'secret.dart',
                  contextLine: 'final key = loadFrom("/home/me/secret");',
                  preContext: ['above /home/me/a.dart'],
                  postContext: ['below'],
                  lineNo: 7,
                ),
              ],
            ),
          ),
        ],
      );
      final scrubbed = scrubCrashEvent(event)!;
      final frame = scrubbed.threads!.first.stacktrace!.frames.first;
      expect(frame.absPath, contains('<redacted-path>'));
      expect(frame.absPath, isNot(contains('C:/Users/me')));
      // Raw source snippets are dropped entirely, not redacted.
      expect(frame.contextLine, isNull);
      expect(frame.preContext, isEmpty);
      expect(frame.postContext, isEmpty);
      expect(frame.fileName, equals('secret.dart'));
    },
  );

  // Even on the scrubbed exceptions path, source snippets must be dropped.
  test('scrubber drops contextLine/pre/postContext on exception frames', () {
    final event = SentryEvent(
      exceptions: [
        SentryException(
          type: 'StateError',
          value: 'bad',
          stackTrace: SentryStackTrace(
            frames: [
              SentryStackFrame(
                absPath: '/home/me/x.dart',
                contextLine: 'secret source line',
                preContext: ['a'],
                postContext: ['b'],
                lineNo: 1,
              ),
            ],
          ),
        ),
      ],
    );
    final frame = scrubCrashEvent(
      event,
    )!.exceptions!.first.stackTrace!.frames.first;
    expect(frame.contextLine, isNull);
    expect(frame.preContext, isEmpty);
    expect(frame.postContext, isEmpty);
  });

  // `vars` (local variable values captured per frame) is a content vector the
  // 9.x SDK adds; the frame rebuild must drop it entirely, not redact it.
  test('scrubber drops per-frame local variables (vars)', () {
    final event = SentryEvent(
      exceptions: [
        SentryException(
          type: 'StateError',
          value: 'bad',
          stackTrace: SentryStackTrace(
            frames: [
              SentryStackFrame(
                absPath: '/home/me/x.dart',
                lineNo: 1,
                vars: {'apiKey': 'sk-secret', 'path': '/home/me/secret'},
              ),
            ],
          ),
        ),
      ],
    );
    final json = scrubCrashEvent(
      event,
    )!.exceptions!.first.stackTrace!.frames.first.toJson();
    expect(json.containsKey('vars'), isFalse);
  });

  // Breadcrumb data is redacted recursively — nested maps/lists, not just
  // top-level string values (http/navigation breadcrumbs nest URLs).
  test('scrubber redacts nested string values in breadcrumb data', () {
    final event = SentryEvent(
      breadcrumbs: [
        Breadcrumb(
          message: 'http',
          data: {
            'request': {'url': 'https://x/home/me/repo/notes.md'},
            'tags': ['/home/me/a', 42],
          },
        ),
      ],
    );
    final data = scrubCrashEvent(event)!.breadcrumbs!.first.data!;
    final nested = data['request'] as Map;
    expect(nested['url'], contains('<redacted-path>'));
    expect(nested['url'], isNot(contains('/home/me')));
    final list = data['tags'] as List;
    expect(list[0], contains('<redacted-path>'));
    expect(list[1], equals(42)); // non-string preserved
  });

  // A map can be keyed by a path/URL (e.g. a "files opened" breadcrumb); the
  // key itself must be redacted, not just the value.
  test('scrubber redacts path-like map keys in breadcrumb data', () {
    final event = SentryEvent(
      breadcrumbs: [
        Breadcrumb(
          message: 'files',
          data: {
            '/home/me/repo/secret.dart': 'opened',
            'nested': {'/home/me/other.dart': 1},
          },
        ),
      ],
    );
    final data = scrubCrashEvent(event)!.breadcrumbs!.first.data!;
    expect(data.keys, contains('<redacted-path>'));
    expect(data.keys.join(), isNot(contains('/home/me')));
    final nested = data['nested'] as Map;
    expect(nested.keys, contains('<redacted-path>'));
    expect(nested.keys.join(), isNot(contains('/home/me')));
  });

  // transaction/serverName/extra are content-bearing, so the scrubber must
  // replace them with a redacted value in place — never leave them untouched.
  test('scrubber neutralizes transaction, serverName, and extra', () {
    final event = SentryEvent(
      transaction: '/project/secret//home/me/x.dart',
      serverName: 'my-laptop.local',
      // ignore: deprecated_member_use
      extra: {'path': '/home/me/secret', 'n': 5},
    );
    final scrubbed = scrubCrashEvent(event)!;
    expect(scrubbed.transaction, contains('<redacted-path>'));
    expect(scrubbed.serverName, equals('<redacted-host>'));
    // ignore: deprecated_member_use
    final extra = scrubbed.extra!;
    expect(extra['path'], contains('<redacted-path>'));
    expect(extra['path'], isNot(contains('/home/me')));
    expect(extra['n'], equals(5));
  });

  // HTTP request context (url/query/headers/cookies/body) is dropped wholesale.
  test('scrubber drops the HTTP request context', () {
    final event = SentryEvent(
      request: SentryRequest(
        url: 'https://x/home/me',
        cookies: 'sid=secret',
        headers: {'Authorization': 'Bearer secret'},
      ),
    );
    final json = scrubCrashEvent(event)!.toJson();
    expect(json.containsKey('request'), isFalse);
  });
}
