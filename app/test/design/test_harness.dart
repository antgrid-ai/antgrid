import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/theme_presets.dart';

/// Pumps [child] inside a MaterialApp configured with the antgrid palette.
Future<void> pumpAntgrid(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark().copyWith(
        extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
      ),
      home: Scaffold(body: Center(child: child)),
    ),
  );
}
