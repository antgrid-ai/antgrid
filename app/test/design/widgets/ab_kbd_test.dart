import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/ab_kbd.dart';

import '../test_harness.dart';

void main() {
  testWidgets('renders single key', (tester) async {
    await pumpAntgrid(tester, const AbKbd('⌘'));
    expect(find.text('⌘'), findsOneWidget);
  });

  testWidgets('renders grouped keys', (tester) async {
    await pumpAntgrid(tester, const AbKbdGroup(['⌘', 'K']));
    expect(find.text('⌘'), findsOneWidget);
    expect(find.text('K'), findsOneWidget);
  });
}
