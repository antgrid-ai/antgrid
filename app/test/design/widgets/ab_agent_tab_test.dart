import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/ab_agent_tab.dart';
import 'package:antgrid/design/widgets/ab_status_pill.dart';

import '../test_harness.dart';

void main() {
  testWidgets('renders glyph and name', (tester) async {
    await pumpAntgrid(
      tester,
      AbAgentTab(
        glyph: 'cc',
        name: 'claude-code',
        status: AbAgentStatus.running,
        duration: '0:42',
        active: true,
        onTap: () {},
        onClose: () {},
      ),
    );
    expect(find.text('cc'), findsOneWidget);
    expect(find.text('claude-code'), findsOneWidget);
    expect(find.text('0:42'), findsOneWidget);
  });

  testWidgets('tap fires onTap', (tester) async {
    var taps = 0;
    await pumpAntgrid(
      tester,
      AbAgentTab(
        glyph: 'cx',
        name: 'codex',
        status: AbAgentStatus.idle,
        active: false,
        onTap: () => taps++,
        onClose: () {},
      ),
    );
    await tester.tap(find.text('codex'));
    expect(taps, 1);
  });
}
