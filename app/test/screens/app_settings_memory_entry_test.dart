import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/models/memory.dart';
import 'package:antgrid/providers/demo_mode.dart';
import 'package:antgrid/providers/memory_surface.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';
import 'package:antgrid/screens/app_settings_screen.dart';
import 'package:antgrid/services/app_settings_service.dart';

import '../helpers/prefs_test_mock.dart';

Future<ProviderContainer> _pump(WidgetTester tester, {bool demo = false}) async {
  useInMemoryPrefs();
  final prefs = await openAppSettingsPrefs();
  final service = AppSettingsService(prefs, AppSettings.fromPrefs(prefs));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appSettingsServiceProvider.overrideWith(() => service)],
      child: MaterialApp(theme: buildAbTheme(), home: const AppSettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(AppSettingsScreen)),
  );
  if (demo) {
    container.read(demoModeProvider.notifier).set(true);
    await tester.pumpAndSettle();
  }
  return container;
}

void main() {
  testWidgets('on iOS the entry opens the selected machine memory', (
    tester,
  ) async {
    final container = await _pump(tester);
    container
        .read(memoryViewProvider.notifier)
        .set(MemoryView(const MemoryTarget.machine(machineId: 'm1')));

    await tester.ensureVisible(find.text('Manage machine memory'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manage machine memory'));
    await tester.pumpAndSettle();

    expect(container.read(workbenchSurfaceProvider), WorkbenchSurface.memory);
    expect(container.read(memoryViewProvider).target, isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('the sample project hides the entry', (tester) async {
    await _pump(tester, demo: true);
    expect(find.text('Manage machine memory'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
