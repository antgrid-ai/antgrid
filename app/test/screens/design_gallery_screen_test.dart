import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/screens/design_gallery_screen.dart';

void main() {
  testWidgets('design gallery pumps without throwing', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(
          extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
        ),
        home: const DesignGalleryScreen(),
      ),
    );
    await tester.pump();
    expect(find.text('Antgrid'), findsWidgets);
    expect(find.text('DESIGN SYSTEM'), findsOneWidget);
  });
}
