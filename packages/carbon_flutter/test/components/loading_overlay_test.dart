import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

Widget _tree(bool loading, FocusNode node, VoidCallback onPressed) => SizedBox(
  width: 200,
  height: 100,
  child: CarbonLoadingOverlay(
    loading: loading,
    child: CarbonButton(label: 'In', focusNode: node, onPressed: onPressed),
  ),
);

void main() {
  testWidgets('hides covered controls from assistive technology', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final node = FocusNode();
    addTearDown(node.dispose);
    var count = 0;
    await pumpCarbon(tester, _tree(false, node, () => count++));
    expect(find.semantics.byLabel('In'), findsOneWidget);
    await pumpCarbon(tester, _tree(true, node, () => count++));
    expect(find.semantics.byLabel('In'), findsNothing);
    await pumpCarbon(tester, _tree(false, node, () => count++));
    expect(find.semantics.byLabel('In'), findsOneWidget);
    expect(count, 0);
    handle.dispose();
  });

  testWidgets('returns focus to the control that held it', (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    await pumpCarbon(tester, _tree(false, node, () {}));
    node.requestFocus();
    await tester.pump();
    await pumpCarbon(tester, _tree(true, node, () {}));
    expect(node.hasFocus, isFalse);
    await pumpCarbon(tester, _tree(false, node, () {}));
    await tester.pump();
    expect(node.hasFocus, isTrue);
  });

  testWidgets('does not steal focus it never took', (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    await pumpCarbon(tester, _tree(false, node, () {}));
    await pumpCarbon(tester, _tree(true, node, () {}));
    await pumpCarbon(tester, _tree(false, node, () {}));
    await tester.pump();
    expect(node.hasFocus, isFalse);
  });
}
