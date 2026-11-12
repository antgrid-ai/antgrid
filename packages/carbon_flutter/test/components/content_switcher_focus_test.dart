import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const _withNull = <CarbonOption<String?>>[
  CarbonOption(value: null, label: 'All'),
  CarbonOption(value: 'a', label: 'Alpha'),
  CarbonOption(value: 'b', label: 'Beta'),
];

bool _focused(WidgetTester tester, String label) =>
    Focus.of(tester.element(find.text(label))).hasPrimaryFocus;

class _Host extends StatefulWidget {
  const _Host();

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  String? value = 'b';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const CarbonButton(label: 'Before', onPressed: _noop),
        CarbonContentSwitcher<String?>(
          options: _withNull,
          value: value,
          activation: CarbonActivationMode.manual,
          onChanged: (v) => setState(() => value = v),
        ),
        const CarbonButton(label: 'After', onPressed: _noop),
      ],
    );
  }
}

void _noop() {}

void main() {
  testWidgets('a segment whose value is null can hold the tab stop', (
    tester,
  ) async {
    await pumpCarbon(tester, const _Host());
    await tester.tap(find.text('Beta'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pump();
    expect(_focused(tester, 'All'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(_focused(tester, 'After'), isTrue);
  });
}
