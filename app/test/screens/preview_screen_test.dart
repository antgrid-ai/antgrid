import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/preview_models.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/design/widgets/ab_loading.dart';
import 'package:antgrid/screens/preview_screen.dart';
import 'package:antgrid/widgets/send_capture_to_agent.dart';

void main() {
  Widget buildTestWidget({required AsyncValue<PreviewState> previewState}) {
    return ProviderScope(
      overrides: [
        previewStateProvider.overrideWith(
          (ref) => Stream.value(previewState.value ?? const PreviewState()),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: PreviewScreen())),
    );
  }

  group('PreviewScreen', () {
    testWidgets('shows empty state when no ports detected', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

      await tester.pumpWidget(
        buildTestWidget(previewState: const AsyncData(PreviewState())),
      );
      await tester.pump();

      expect(find.text('Open a Preview'), findsOneWidget);

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('shows port list when ports available', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

      final state = PreviewState(
        ports: [
          const PortInfo(port: 3000, processName: 'node'),
          const PortInfo(port: 8080, label: 'vite'),
        ],
      );

      await tester.pumpWidget(buildTestWidget(previewState: AsyncData(state)));
      await tester.pump();

      expect(find.text('Port 3000'), findsOneWidget);
      expect(find.text('Port 8080'), findsOneWidget);
      expect(find.text('node'), findsOneWidget);
      expect(find.text('vite'), findsOneWidget);

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('marks https ports in the port list', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

      final state = PreviewState(
        ports: [
          const PortInfo(port: 3000, processName: 'node'),
          const PortInfo(port: 8443, label: 'vite', scheme: 'https'),
        ],
      );

      await tester.pumpWidget(buildTestWidget(previewState: AsyncData(state)));
      await tester.pump();

      // http is the norm and stays unmarked; https is called out.
      expect(find.text('node'), findsOneWidget);
      expect(find.text('vite · https'), findsOneWidget);

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('shows loading when preview state is loading', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

      await tester.pumpWidget(
        buildTestWidget(previewState: const AsyncLoading()),
      );

      expect(find.byType(AbLoading), findsOneWidget);

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('shows empty state on Windows when no ports', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      await tester.pumpWidget(
        buildTestWidget(previewState: const AsyncData(PreviewState())),
      );
      await tester.pump();

      expect(find.text('Open a Preview'), findsOneWidget);

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('shows empty state on Linux when no ports', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;

      await tester.pumpWidget(
        buildTestWidget(previewState: const AsyncData(PreviewState())),
      );
      await tester.pump();

      expect(find.text('Open a Preview'), findsOneWidget);

      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('formatPickedElement', () {
    test('formats a full payload', () {
      final text = formatPickedElement({
        'tag': 'button',
        'id': 'submit',
        'classes': ['btn', 'btn-primary'],
        'text': 'Submit',
        'html': '<button id="submit" class="btn btn-primary">Submit</button>',
        'selector': '//*[@id="submit"]',
      });

      expect(text, contains('<button id="submit" class="btn btn-primary">'));
      expect(text, contains('Selector: //*[@id="submit"]'));
      expect(text, contains('Text: "Submit"'));
      expect(text, contains('HTML: <button'));
    });

    test('omits id/class/text lines gracefully when absent', () {
      final text = formatPickedElement({
        'tag': 'div',
        'classes': <String>[],
        'text': '',
        'html': '<div></div>',
        'selector': '//div[1]',
      });

      expect(text, contains('<div>'));
      expect(text, isNot(contains('id=')));
      expect(text, isNot(contains('class=')));
      expect(text, isNot(contains('Text:')));
    });

    test('treats wrong-type fields as absent instead of throwing', () {
      final text = formatPickedElement({
        'tag': 123,
        'id': 456,
        'classes': 'not-a-list',
        'text': null,
        'selector': null,
      });

      expect(text, contains('<element>'));
      expect(text, contains('Selector: (unknown)'));
    });

    test('handles a completely empty payload', () {
      expect(() => formatPickedElement(const {}), returnsNormally);
    });

    test('re-caps an oversized field defensively', () {
      final text = formatPickedElement({
        'tag': 'p',
        'text': 'x' * 1000,
        'selector': '//p[1]',
      });

      final textLine = text
          .split('\n')
          .firstWhere((l) => l.startsWith('Text:'));
      expect(textLine.length, lessThan(600));
      expect(textLine, contains('…'));
    });
  });

  group('formatScreenshotAttachment', () {
    test('wraps the staged path as an attachment line', () {
      expect(
        formatScreenshotAttachment(r'C:\proj\.antgrid\uploads\shot.png'),
        r'Attached file: C:\proj\.antgrid\uploads\shot.png',
      );
    });
  });

  group('pickedRegion', () {
    test('reads the rect and the viewport it was measured in', () {
      final region = pickedRegion(const {
        'rect': {'x': 10, 'y': 20.5, 'width': 100, 'height': 40},
        'viewport': {'width': 1200, 'height': 800},
      });
      expect(region, isNotNull);
      expect(region!.rect, const Rect.fromLTWH(10, 20.5, 100, 40));
      expect(region.viewport, const Size(1200, 800));
    });

    test('a payload with no rect falls back to the whole viewport', () {
      expect(pickedRegion(const {'tag': 'div'}), isNull);
    });

    test('a zero-area box is treated as absent, not cropped to nothing', () {
      expect(
        pickedRegion(const {
          'rect': {'x': 0, 'y': 0, 'width': 0, 'height': 40},
          'viewport': {'width': 1200, 'height': 800},
        }),
        isNull,
      );
    });

    test('wrong-typed fields are absent rather than throwing', () {
      expect(
        pickedRegion(const {
          'rect': {'x': 'nope', 'y': 0, 'width': 10, 'height': 10},
          'viewport': {'width': 1200, 'height': 800},
        }),
        isNull,
      );
      expect(pickedRegion(const {'rect': 5, 'viewport': 6}), isNull);
    });
  });

  group('parsePreviewTarget', () {
    test('a bare port defaults to http and the root path', () {
      expect(parsePreviewTarget('3000'), (3000, 'http', '/'));
    });

    test('a scheme-prefixed bare port keeps the scheme', () {
      expect(parsePreviewTarget('https://3000'), (3000, 'https', '/'));
    });

    test('localhost:port with a path preserves it', () {
      expect(parsePreviewTarget('localhost:3000/dashboard'), (
        3000,
        'http',
        '/dashboard',
      ));
    });

    test('a full link with scheme, host, and path preserves all three', () {
      expect(parsePreviewTarget('http://localhost:3000/dashboard?x=1#top'), (
        3000,
        'http',
        '/dashboard?x=1#top',
      ));
    });

    test('127.0.0.1 is accepted the same as localhost', () {
      expect(parsePreviewTarget('127.0.0.1:5173/docs'), (
        5173,
        'http',
        '/docs',
      ));
    });

    test('a bare port followed by a path with no host prefix works', () {
      expect(parsePreviewTarget('3000/foo'), (3000, 'http', '/foo'));
    });

    test('an external hostname is rejected — this previews your dev server, '
        'not the open web', () {
      expect(parsePreviewTarget('example.com'), isNull);
      expect(parsePreviewTarget('example.com:3000'), isNull);
      expect(parsePreviewTarget('https://example.com'), isNull);
    });

    test('free text that is neither a port nor a link is rejected', () {
      expect(parsePreviewTarget('hello world'), isNull);
      expect(parsePreviewTarget(''), isNull);
      expect(parsePreviewTarget('localhost'), isNull);
    });

    test('an out-of-range port is rejected', () {
      expect(parsePreviewTarget('70000'), isNull);
      expect(parsePreviewTarget('0'), isNull);
    });
  });
}
