import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/screens/app_settings_screen.dart';
import 'package:antgrid/services/app_settings_service.dart';
import 'package:antgrid/services/auth_service.dart';

import '../helpers/prefs_test_mock.dart';

Future<void> _pumpSignedIn(WidgetTester tester) async {
  useInMemoryPrefs();
  final prefs = await openAppSettingsPrefs();
  final service = AppSettingsService(prefs, AppSettings.fromPrefs(prefs));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appSettingsServiceProvider.overrideWith(() => service),
        currentUserProvider.overrideWith(
          (ref) => CurrentUser(userId: 'u-1', email: 'a@b.test', tier: 'pro'),
        ),
      ],
      child: MaterialApp(
        theme: buildAbTheme(),
        home: const AppSettingsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('Settings does not contain help or logs on phones', (
      tester,
    ) async {
      await _pumpSignedIn(tester);
      expect(find.text('Share logs'), findsNothing);
      expect(find.text('Help'), findsNothing);
      expect(find.text('Chat with support'), findsNothing);
      expect(find.text('Open log folder'), findsNothing);
    }, variant: TargetPlatformVariant.only(platform));
  }

  testWidgets('Settings does not contain help or logs on desktop', (
    tester,
  ) async {
    await _pumpSignedIn(tester);
    expect(find.text('Open log folder'), findsNothing);
    expect(find.text('Help'), findsNothing);
    expect(find.text('Share logs'), findsNothing);
  }, variant: TargetPlatformVariant.desktop());
}
