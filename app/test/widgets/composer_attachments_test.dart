import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/widgets/ab_loading.dart';
import 'package:antgrid/design/widgets/ab_progress_rule.dart';
import 'package:antgrid/widgets/attach_progress.dart';
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

    // Staging covers every wait before a byte moves (reconnecting after the
    // file picker, the loopback transport's (0, total) tick); all bytes sent
    // is the bridge confirming. Only a byte count in between shows a percent.
    for (final (progress, text, fraction) in [
      (null, 'photo.png · uploading…', null),
      (
        const AttachProgress.tick(fileName: 'photo.png', sent: 0, total: 100),
        'photo.png · uploading…',
        null,
      ),
      (
        const AttachProgress.tick(fileName: 'photo.png', sent: 199, total: 200),
        'photo.png 99%',
        0.995,
      ),
      (
        const AttachProgress.tick(fileName: 'photo.png', sent: 42, total: 100),
        'photo.png 42%',
        0.42,
      ),
      (
        const AttachProgress.tick(fileName: 'photo.png', sent: 9, total: 9),
        'photo.png · finishing…',
        null,
      ),
    ]) {
      testWidgets('uploading chip reads "$text"', (tester) async {
        final a = ComposerAttachment(
          fileName: 'photo.png',
          bytes: Uint8List(1),
        );
        if (progress != null) a.progress = progress;
        await tester.pumpWidget(host([a]));
        expect(find.text(text), findsOneWidget);
        expect(find.byType(AbLoadingDot), findsOneWidget);
        final rule = tester.widget<AbProgressRule>(find.byType(AbProgressRule));
        expect(rule.fraction, fraction);
      });
    }

    testWidgets('a chip keeps its height when its upload finishes', (
      tester,
    ) async {
      final a = ComposerAttachment(fileName: 'photo.png', bytes: Uint8List(1));
      await tester.pumpWidget(host([a]));
      double height() =>
          tester.getSize(find.byType(ComposerAttachmentChips)).height;
      final uploading = height();

      a.status = AttachmentStatus.done;
      await tester.pumpWidget(host([a]));

      expect(height(), uploading);
    });

    testWidgets('done chip shows name, no busy state, and remove works', (
      tester,
    ) async {
      final a = ComposerAttachment(fileName: 'photo.png', bytes: null)
        ..status = AttachmentStatus.done
        ..path = '/x/photo.png';
      ComposerAttachment? removed;
      await tester.pumpWidget(host([a], onRemove: (x) => removed = x));
      expect(find.byType(AbLoadingDot), findsNothing);
      expect(find.byType(AbProgressRule), findsNothing);
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
