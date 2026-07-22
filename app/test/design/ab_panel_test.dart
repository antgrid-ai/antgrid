import 'package:antgrid/design/widgets/ab_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('showAbPanel shows live content and pops with a value', (
    tester,
  ) async {
    String? result;
    late BuildContext anchorCtx;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) {
              anchorCtx = ctx;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );

    final future = showAbPanel<String>(
      context: anchorCtx,
      anchorRect: const Rect.fromLTWH(10, 10, 100, 24),
      builder: (ctx) => GestureDetector(
        onTap: () => Navigator.of(ctx).pop('picked'),
        child: const Text('panel row'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('panel row'), findsOneWidget);

    await tester.tap(find.text('panel row'));
    await tester.pumpAndSettle();
    result = await future;
    expect(result, 'picked');
  });

  testWidgets('tap-outside dismisses with null', (tester) async {
    late BuildContext anchorCtx;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) {
              anchorCtx = ctx;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    final future = showAbPanel<String>(
      context: anchorCtx,
      anchorRect: const Rect.fromLTWH(10, 10, 100, 24),
      builder: (_) => const Text('panel row'),
    );
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(390, 590)); // outside the panel
    await tester.pumpAndSettle();
    expect(await future, isNull);
  });
}
