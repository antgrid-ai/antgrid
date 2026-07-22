import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/ab_icons.dart';
import 'package:antgrid/design/widgets/ab_menu.dart';

import '../test_harness.dart';

void main() {
  testWidgets('renders header and items', (tester) async {
    var deleted = false;
    await pumpAntgrid(
      tester,
      AbMenu(
        header: 'Session · refactor-auth-flow',
        items: [
          AbMenuItem(
            label: 'Export transcript',
            icon: AbIcons.arrowDown,
            shortcut: '⌘E',
            onTap: () {},
          ),
          const AbMenuDivider(),
          AbMenuItem(
            label: 'Delete session',
            icon: AbIcons.trash,
            shortcut: '⌫',
            danger: true,
            onTap: () => deleted = true,
          ),
        ],
      ),
    );
    expect(find.text('SESSION · REFACTOR-AUTH-FLOW'), findsOneWidget);
    expect(find.text('Export transcript'), findsOneWidget);
    await tester.tap(find.text('Delete session'));
    expect(deleted, isTrue);
  });
}
