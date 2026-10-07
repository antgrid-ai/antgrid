import 'package:antgrid/design/ab_icons.dart';
import 'package:antgrid/design/widgets/ab_toast.dart';
import 'package:antgrid/navigation/nav_console.dart';
import 'package:antgrid/providers/app_toaster.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/demo_harness.dart';

void main() {
  test('the toaster is disposed with its container, and a late show is a '
      'silent no-op', () {
    final container = ProviderContainer();
    final toaster = container.read(appToasterProvider);
    var notified = 0;
    toaster.addListener(() => notified++);

    container.dispose();

    expect(() => toaster.addListener(() {}), throwsFlutterError);
    expect(() => toaster.showMessage('Reply landed'), returnsNormally);
    expect(
      () => toaster.show(const AbToast(icon: AbIcons.info, title: 'Late')),
      returnsNormally,
    );
    expect(toaster.clear, returnsNormally);
    expect(notified, 0);
  });

  // Callers that hold a container rather than a context (the Handler arm flow)
  // reach the app's host only if main.dart hands it this provider's toaster; a
  // host owning a private one would drop every such toast with no error.
  testWidgets('the real app renders a toast shown on the provider', (
    tester,
  ) async {
    final container = await pumpDemoApp(tester);

    container.read(appToasterProvider).showMessage('From the provider');
    await tester.pump();

    expect(find.text('From the provider'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });

  // The driver reaches the console's command field with a real tap, and a card
  // anchored bottom-right would otherwise sit over it.
  testWidgets('a showing toast leaves the nav console command field tappable', (
    tester,
  ) async {
    kNavConsoleEnabled = true;
    addTearDown(() => kNavConsoleEnabled = false);
    const command = ValueKey('ab.nav.command');
    final container = await pumpDemoApp(tester, size: const Size(1200, 800));

    container.read(appToasterProvider).showMessage('Over the console?');
    await tester.pump();
    expect(find.text('Over the console?'), findsOneWidget);

    await tester.tap(find.byKey(command));
    await tester.pump();

    final editable = find.descendant(
      of: find.byKey(command),
      matching: find.byType(EditableText),
    );
    expect(tester.widget<EditableText>(editable).focusNode.hasFocus, isTrue);
    await tester.pump(const Duration(seconds: 4));
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
