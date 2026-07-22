import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

void main() {
  testWidgets('onCellMetricsChanged reports positive float metrics', (
    tester,
  ) async {
    final controller = GhosttyTerminalController();
    controller.attachExternalTransport(writeBytes: (_) => true);
    double? charWidth;
    double? linePixels;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 300,
            child: GhosttyTerminalView(
              controller: controller,
              fontSize: 14,
              fontFamily: 'monospace',
              onCellMetricsChanged: (cw, lp) {
                charWidth = cw;
                linePixels = lp;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(charWidth, isNotNull);
    expect(linePixels, isNotNull);
    expect(charWidth! > 0, isTrue);
    expect(linePixels! > 0, isTrue);
  });
}
