import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:antgrid/widgets/transcript/markdown_body.dart';

void main() {
  setUpAll(() {
    // markdown_widget uses VisibilityDetector which has a debounce timer.
    // Setting updateInterval to zero makes callbacks fire synchronously in
    // tests, preventing the "pending timer" assertion failure on teardown.
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  testWidgets('renders prose text and gives code fences a copy button', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TranscriptMarkdown(
              data: 'hi **bold**\n\n```dart\nfinal x = 1;\n```',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('hi', findRichText: true), findsWidgets);
    expect(find.byTooltip('Copy'), findsOneWidget);
  });
}
