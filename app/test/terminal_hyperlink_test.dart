import 'dart:convert';
import 'dart:io';

import 'package:antgrid/util/ab_log.dart';
import 'package:antgrid/util/external_url.dart';
import 'package:antgrid/widgets/terminal_hyperlink_sheet.dart';
import 'package:flutter/foundation.dart';
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

  group('terminalHyperlinkLooksDeceptive', () {
    test('catches a host wearing another host as userinfo', () {
      expect(
        terminalHyperlinkLooksDeceptive(
          Uri.parse('https://github.com@evil.example/antgrid/pull/13'),
        ),
        isTrue,
      );
      expect(
        terminalHyperlinkLooksDeceptive(
          Uri.parse('https://user:pw@evil.example/'),
        ),
        isTrue,
      );
    });

    // Both spellings of the same lie: Dart punycodes nothing, so a raw unicode
    // host arrives percent-encoded and an `xn--` check alone would pass it.
    test('catches a homoglyph host, however it was spelled', () {
      expect(
        terminalHyperlinkLooksDeceptive(
          Uri.parse('https://xn--pple-43d.com/login'),
        ),
        isTrue,
      );
      final raw = Uri.parse('https://\u0430pple.com/login');
      expect(raw.host, contains('%'));
      expect(terminalHyperlinkLooksDeceptive(raw), isTrue);
      // A label merely containing the marker is not one starting with it.
      expect(
        terminalHyperlinkLooksDeceptive(Uri.parse('https://myxn--co.com/a')),
        isFalse,
      );
    });

    // The cost of a false positive is a sheet on every ordinary link, which is
    // how a confirmation stops being read at all.
    test('passes ordinary links, ports and case included', () {
      for (final ok in <String>[
        'https://github.com/antgrid-ai/antgrid/pull/13',
        'https://sub.github.com/ok',
        'https://github.com:443/ok',
        'https://gitHUB.com/OK',
        'http://192.168.1.9:8080/admin',
        'http://localhost:3000/',
      ]) {
        expect(
          terminalHyperlinkLooksDeceptive(Uri.parse(ok)),
          isFalse,
          reason: ok,
        );
      }
    });

    // Named so the gap is not mistaken for coverage: only the link's visible
    // text contradicts this one, and that text never reaches the app.
    test('does NOT catch a lookalike that is honestly its own host', () {
      expect(
        terminalHyperlinkLooksDeceptive(
          Uri.parse('https://github.com.evil.example/antgrid'),
        ),
        isFalse,
      );
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
        confirm: (_, _) async => true,
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
          confirm: (_, _) async => true,
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

    // flutter_test reports android by default, so these run on the touch path
    // unless they say otherwise.
    testWidgets(
      'asks before opening on touch, and cancelling launches nothing',
      (tester) async {
        final context = await pumpHost(tester);
        var launched = 0;
        var asked = 0;

        await openTerminalHyperlink(
          context,
          'https://example.com/a',
          open: (_, _) async => launched++,
          confirm: (_, _) async {
            asked++;
            return false;
          },
        );
        await tester.pump();

        expect(asked, 1);
        expect(launched, 0);
      },
    );

    // The sheet's whole job is naming the destination, so it has to be handed
    // the URI that will actually be launched -- not the raw terminal string,
    // which can differ from it.
    testWidgets('asks about the normalized URI, not the raw one', (
      tester,
    ) async {
      final context = await pumpHost(tester);
      Uri? asked;

      await openTerminalHyperlink(
        context,
        '  https://github.com@evil.example/pull/13  ',
        open: (_, _) async {},
        confirm: (_, target) async {
          asked = target;
          return true;
        },
      );
      await tester.pump();

      expect(asked.toString(), 'https://github.com@evil.example/pull/13');
      // The host is what an impostor URL misrepresents, and it is not the half
      // the anchor text advertises.
      expect(asked?.host, 'evil.example');
    });

    testWidgets('desktop opens an ordinary link without asking', (
      tester,
    ) async {
      // Cleared inside the body, not in addTearDown: the framework asserts
      // the foundation debug vars are unset before teardown runs.
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

      final context = await pumpHost(tester);
      final launched = <String>[];
      var asked = 0;

      await openTerminalHyperlink(
        context,
        'https://example.com/a',
        open: (_, url) async => launched.add(url),
        confirm: (_, _) async {
          asked++;
          return true;
        },
      );
      await tester.pump();

      debugDefaultTargetPlatformOverride = null;

      expect(asked, 0);
      expect(launched, <String>['https://example.com/a']);
    });

    testWidgets('desktop still asks when the URI is built to be misread', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

      final context = await pumpHost(tester);
      final launched = <String>[];
      Uri? asked;

      await openTerminalHyperlink(
        context,
        'https://github.com@evil.example/antgrid/pull/13',
        open: (_, url) async => launched.add(url),
        confirm: (_, target) async {
          asked = target;
          return true;
        },
      );
      await tester.pump();

      debugDefaultTargetPlatformOverride = null;

      // An address bar would have shown this too -- and been read as GitHub,
      // which is the whole reason the sheet names the host on its own line.
      expect(asked?.host, 'evil.example');
      expect(launched, <String>[
        'https://github.com@evil.example/antgrid/pull/13',
      ]);
    });

    testWidgets('desktop cancelling a deceptive link launches nothing', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

      final context = await pumpHost(tester);
      var launched = 0;

      await openTerminalHyperlink(
        context,
        'https://xn--pple-43d.com/login',
        open: (_, _) async => launched++,
        confirm: (_, _) async => false,
      );
      await tester.pump();

      debugDefaultTargetPlatformOverride = null;

      expect(launched, 0);
    });
  });

  group('showTerminalHyperlinkSheet', () {
    Future<Future<bool>> open(WidgetTester tester, Uri target) async {
      late Future<bool> answer;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () =>
                    answer = showTerminalHyperlinkSheet(context, target),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      return answer;
    }

    testWidgets('names the host on its own line, and the full URI', (
      tester,
    ) async {
      final answer = await open(
        tester,
        Uri.parse('https://github.com@evil.example/antgrid/pull/13'),
      );

      // The host alone, not merely present somewhere inside the URI: a
      // userinfo prefix is exactly what goes unread when it is not separated.
      expect(find.text('evil.example'), findsOneWidget);
      expect(
        find.text('https://github.com@evil.example/antgrid/pull/13'),
        findsOneWidget,
      );

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await answer, isFalse);
    });

    testWidgets('Open confirms, and a dismiss does not', (tester) async {
      final target = Uri.parse('https://example.com/a');

      var answer = await open(tester, target);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(await answer, isTrue);

      // Dismissing the sheet must read as "no" -- a null from the route would
      // otherwise be one `!` away from launching what the user backed out of.
      answer = await open(tester, target);
      await tester.tapAt(const Offset(400, 20));
      await tester.pumpAndSettle();
      expect(await answer, isFalse);
    });
  });
}
