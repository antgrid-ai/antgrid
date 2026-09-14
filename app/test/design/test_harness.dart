import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/theme_presets.dart';

/// Pumps [child] inside a MaterialApp configured with the antgrid palette.
///
/// A `ProviderScope` is required here because this harness is pumped under
/// widely-shared presentational widgets — no single file's ownership covers
/// them all, so a widget converted to a `ConsumerWidget` surfaces a missing
/// scope only in the tests of files nobody who made that change touched.
Future<void> pumpAntgrid(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: ThemeData.dark().copyWith(
          extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
        ),
        home: Scaffold(body: Center(child: child)),
      ),
    ),
  );
}
