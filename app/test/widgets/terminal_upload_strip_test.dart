import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/widgets/attach_progress.dart';
import 'package:antgrid/widgets/terminal_upload_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('leads with the status, so a long name cannot push it off', (
    tester,
  ) async {
    const name = 'screenshot-2026-11-05-at-16.52.49-from-the-phone.png';
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAbTheme(),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: TerminalUploadStrip(progress: AttachProgress.staging(name)),
          ),
        ),
      ),
    );

    final text = tester.widget<Text>(find.textContaining(name));
    expect(text.data, startsWith('uploading…'));
    expect(text.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
  });
}
