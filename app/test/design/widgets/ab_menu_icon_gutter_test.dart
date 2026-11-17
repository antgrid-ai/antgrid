import 'package:antgrid/design/ab_icons.dart';
import 'package:antgrid/design/widgets/ab_menu.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_harness.dart';

double _labelLeft(WidgetTester tester, String label) =>
    tester.getTopLeft(find.text(label)).dx;

void main() {
  testWidgets('an unticked choice lines up with the ticked one', (
    tester,
  ) async {
    await pumpAntgrid(
      tester,
      const AbMenu(
        items: [
          AbMenuItem(label: 'Laptop', value: 'm1', icon: AbIcons.check),
          AbMenuItem(label: 'Studio', value: 'm2'),
        ],
      ),
    );
    expect(_labelLeft(tester, 'Studio'), _labelLeft(tester, 'Laptop'));
  });

  testWidgets('a menu with no icons keeps its labels at the row edge', (
    tester,
  ) async {
    await pumpAntgrid(
      tester,
      const AbMenu(
        items: [
          AbMenuItem(label: 'Laptop', value: 'm1', icon: AbIcons.check),
          AbMenuItem(label: 'Studio', value: 'm2'),
        ],
      ),
    );
    final withGutter = _labelLeft(tester, 'Studio');

    await pumpAntgrid(
      tester,
      const AbMenu(
        items: [
          AbMenuItem(label: 'Laptop', value: 'm1'),
          AbMenuItem(label: 'Studio', value: 'm2'),
        ],
      ),
    );
    expect(_labelLeft(tester, 'Studio'), lessThan(withGutter));
  });
}
