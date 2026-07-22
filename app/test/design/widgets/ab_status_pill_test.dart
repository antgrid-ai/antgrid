import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/ab_status_pill.dart';

import '../test_harness.dart';

void main() {
  testWidgets('renders label and dot for each status', (tester) async {
    for (final status in AbAgentStatus.values) {
      await pumpAntgrid(tester, AbStatusPill(status: status, label: 'x'));
      expect(find.text('x'), findsOneWidget);
    }
  });

  testWidgets('idle uses muted neutral color', (tester) async {
    await pumpAntgrid(
      tester,
      const AbStatusPill(status: AbAgentStatus.idle, label: 'Idle'),
    );
    final txt = tester.widget<Text>(find.text('Idle'));
    expect(txt.style?.color, const Color(0xFF61656D));
  });
}
