import 'dart:convert';
import 'dart:io';

import 'package:antgrid/util/ab_log.dart';
import 'package:antgrid/util/external_url.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('openableTerminalHyperlink', () {
    test('accepts web links', () {
      expect(openableTerminalHyperlink('https://example.com'), isNotNull);
      expect(openableTerminalHyperlink('http://example.com/a?b=1'), isNotNull);
      expect(openableTerminalHyperlink('HTTPS://Example.com'), isNotNull);
    });

    // The whole point of returning the Uri: whatever cleared the scheme check
    // is what gets launched. Handing the raw string on instead let a padded URI
    // reach `Uri.parse`, which rejects leading whitespace outright and folds
    // trailing whitespace into the host.
    test(
      'normalizes what it accepts, so the checked URI is the opened one',
      () {
        expect(
          openableTerminalHyperlink('  https://example.com  ').toString(),
          'https://example.com',
        );
        expect(
          openableTerminalHyperlink('https://example.com\n').toString(),
          'https://example.com',
        );
        expect(
          openableTerminalHyperlink('\thttps://example.com/a?b=1').toString(),
          'https://example.com/a?b=1',
        );
        // Every accepted URI must survive a re-parse, since that is what the
        // launcher does to it.
        for (final raw in <String>[
          '  https://example.com  ',
          'https://example.com\n',
          'HTTPS://Example.com',
        ]) {
          final target = openableTerminalHyperlink(raw)!;
          expect(Uri.parse(target.toString()), target);
        }
      },
    );

    // An OSC 8 payload is written by whatever runs in the terminal, so these
    // are reachable by any program that can print, on a single tap.
    test('refuses non-web schemes', () {
      expect(openableTerminalHyperlink('file:///etc/passwd'), isNull);
      expect(openableTerminalHyperlink('mailto:a@b.com'), isNull);
      expect(openableTerminalHyperlink('javascript:alert(1)'), isNull);
      expect(openableTerminalHyperlink('antgrid://open/project'), isNull);
      expect(openableTerminalHyperlink('vscode://file/C:/secret'), isNull);
    });

    test('refuses schemeless and hostless input', () {
      expect(openableTerminalHyperlink(''), isNull);
      expect(openableTerminalHyperlink('example.com'), isNull);
      expect(openableTerminalHyperlink('https://'), isNull);
      expect(openableTerminalHyperlink('/etc/passwd'), isNull);
    });
  });

  group('openTerminalHyperlink', () {
    late Directory tmp;
    late String logPath;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('hyperlink_');
      logPath = '${tmp.path}/app.log';
      AbLog.configureForTest(logPath);
    });
    tearDown(() {
      AbLog.dispose();
      tmp.deleteSync(recursive: true);
    });

    // The predicate group above covers the decision; these cover what the app
    // DOES with it — the SnackBar, the launch, and the swallowed throw are the
    // only behaviour this function adds, and none of it is reachable from a
    // pure test.
    Future<BuildContext> pumpHost(WidgetTester tester) async {
      late BuildContext captured;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                captured = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      return captured;
    }

    const refusal = 'Only http and https links open from the terminal.';

    testWidgets('launches the normalized URI, silently', (tester) async {
      final context = await pumpHost(tester);
      final launched = <String>[];

      await openTerminalHyperlink(
        context,
        '  https://example.com/a?b=1  ',
        open: (_, url) async => launched.add(url),
      );
      await tester.pump();

      expect(launched, <String>['https://example.com/a?b=1']);
      expect(find.text(refusal), findsNothing);
    });

    testWidgets('refuses a non-web scheme visibly and launches nothing', (
      tester,
    ) async {
      final context = await pumpHost(tester);
      var launched = 0;

      await openTerminalHyperlink(
        context,
        'file:///etc/passwd',
        open: (_, _) async => launched++,
      );
      await tester.pump();

      expect(launched, 0);
      // A log line alone would leave a refused tap indistinguishable from a
      // tap that never registered.
      expect(find.text(refusal), findsOneWidget);
    });

    testWidgets('swallows an unexpected throw into the log', (tester) async {
      final context = await pumpHost(tester);

      // runAsync, not the fake clock: AbLog's flush is real file I/O, and a
      // future waiting on the disk never completes inside a widget test's
      // FakeAsync zone.
      await tester.runAsync(() async {
        // Must not rethrow: the terminal view discards this future, so an
        // escape reaches PlatformDispatcher.onError as a fatal.
        await openTerminalHyperlink(
          context,
          'https://example.com',
          open: (_, _) async => throw StateError('launcher exploded'),
        );
        await AbLog.flush();
      });

      final line =
          jsonDecode(
                File(
                  logPath,
                ).readAsLinesSync().firstWhere((l) => l.trim().isNotEmpty),
              )
              as Map<String, dynamic>;
      expect(line['component'], 'TerminalView');
      expect(line['error'], contains('launcher exploded'));
    });
  });
}
