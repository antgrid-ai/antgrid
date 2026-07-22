import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/ab_composer.dart';

import '../test_harness.dart';

void main() {
  testWidgets('shows placeholder and attached chips', (tester) async {
    await pumpAntgrid(
      tester,
      AbComposer(
        agentTag: 'claude-code',
        placeholder: 'Ask the agent…',
        attachments: const ['src/auth.ts', 'docs/sessions.md'],
        onSend: (_) {},
        onRemoveAttachment: (_) {},
      ),
    );
    expect(find.text('Ask the agent…'), findsOneWidget);
    expect(find.text('+ src/auth.ts'), findsOneWidget);
    expect(find.text('+ docs/sessions.md'), findsOneWidget);
  });

  testWidgets('Send button fires onSend with current text', (tester) async {
    String? sent;
    await pumpAntgrid(
      tester,
      AbComposer(
        agentTag: 'codex',
        attachments: const [],
        onSend: (t) => sent = t,
        onRemoveAttachment: (_) {},
      ),
    );
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.tap(find.text('Send'));
    expect(sent, 'hello');
    // Verify the field was cleared after send
    expect(find.text('hello'), findsNothing);
  });

  testWidgets('empty text does not fire onSend', (tester) async {
    String? sent;
    await pumpAntgrid(
      tester,
      AbComposer(
        agentTag: 'x',
        attachments: const [],
        onSend: (t) => sent = t,
        onRemoveAttachment: (_) {},
      ),
    );
    await tester.tap(find.text('Send'));
    expect(sent, isNull);
  });
}
