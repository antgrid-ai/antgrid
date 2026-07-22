import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/ab_cmd_bar.dart';

import '../test_harness.dart';

void main() {
  testWidgets('renders all commands', (tester) async {
    await pumpAntgrid(
      tester,
      AbCmdBar(
        commands: [
          AbCmd(name: 'Build', state: AbCmdState.success, last: '4.2s'),
          AbCmd(name: 'Lint', state: AbCmdState.running, last: '0:08'),
        ],
        onRun: () {},
        onAdd: () {},
      ),
    );
    expect(find.text('Build'), findsOneWidget);
    expect(find.text('Lint'), findsOneWidget);
    expect(find.text('Run'), findsOneWidget);
  });

  testWidgets('tapping a command fires its onTap', (tester) async {
    var taps = 0;
    await pumpAntgrid(
      tester,
      AbCmdBar(
        commands: [
          AbCmd(name: 'Build', state: AbCmdState.idle, onTap: () => taps++),
        ],
        onRun: () {},
        onAdd: () {},
      ),
    );
    await tester.tap(find.text('Build'));
    expect(taps, 1);
  });
}
