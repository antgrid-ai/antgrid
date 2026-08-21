// app/test/widgets/viewer_header_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/ab_icon_button.dart';
import 'package:antgrid/widgets/viewer_header.dart';

void main() {
  testWidgets('renders filename and size, fires close', (tester) async {
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: buildViewerHeader(
            fileName: 'logo.svg',
            size: 2048,
            onClose: () => closed = true,
          ),
        ),
      ),
    );
    expect(find.text('logo.svg'), findsOneWidget);
    expect(find.text('2.0 KB'), findsOneWidget);
    // Tap the close button by its widget type — AbIconButton avoids Material
    // ripples, so do NOT match on InkWell.
    await tester.tap(find.byType(AbIconButton));
    await tester.pump();
    expect(closed, isTrue);
  });
}
