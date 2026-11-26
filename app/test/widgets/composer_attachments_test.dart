import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/widgets/transcript/composer/composer_attachments.dart';
import 'package:flutter/material.dart';

void main() {
  group('appendAttachmentPaths', () {
    test('no paths → text unchanged', () {
      expect(appendAttachmentPaths('hello', const []), 'hello');
    });
    test('appends one line per path after a blank line', () {
      expect(
        appendAttachmentPaths('fix this', const ['/a/b.png', '/a/c.txt']),
        'fix this\n\nAttached file: /a/b.png\nAttached file: /a/c.txt',
      );
    });
    test('attachments-only send: empty text yields just the block', () {
      expect(
        appendAttachmentPaths('', const ['/a/b.png']),
        'Attached file: /a/b.png',
      );
    });
  });

  group('ComposerAttachmentChips', () {
    Widget host(
      List<ComposerAttachment> attachments, {
      void Function(ComposerAttachment)? onRemove,
      void Function(ComposerAttachment)? onRetry,
    }) {
      return MaterialApp(
        theme: buildAbTheme(),
        home: Scaffold(
          body: ComposerAttachmentChips(
            attachments: attachments,
            onRemove: onRemove ?? (_) {},
            onRetry: onRetry ?? (_) {},
          ),
        ),
      );
    }

    testWidgets('renders progress while uploading', (tester) async {
      final a = ComposerAttachment(fileName: 'photo.png', bytes: Uint8List(1))
        ..progress = 0.42;
      await tester.pumpWidget(host([a]));
      expect(find.textContaining('photo.png'), findsOneWidget);
      expect(find.textContaining('42%'), findsOneWidget);
    });

    testWidgets('done chip shows name and remove works', (tester) async {
      final a = ComposerAttachment(fileName: 'photo.png', bytes: null)
        ..status = AttachmentStatus.done
        ..path = '/x/photo.png';
      ComposerAttachment? removed;
      await tester.pumpWidget(host([a], onRemove: (x) => removed = x));
      await tester.tap(find.byTooltip('Remove attachment'));
      expect(removed, same(a));
    });

    testWidgets('error chip exposes retry', (tester) async {
      final a = ComposerAttachment(fileName: 'photo.png', bytes: Uint8List(1))
        ..status = AttachmentStatus.error;
      ComposerAttachment? retried;
      await tester.pumpWidget(host([a], onRetry: (x) => retried = x));
      expect(find.textContaining('failed'), findsOneWidget);
      await tester.tap(find.byTooltip('Retry upload'));
      expect(retried, same(a));
    });

    testWidgets('empty list renders nothing', (tester) async {
      await tester.pumpWidget(host(const []));
      expect(find.byType(ComposerAttachmentChips), findsOneWidget);
      // no chips content
      expect(find.textContaining('%'), findsNothing);
    });
  });
}
