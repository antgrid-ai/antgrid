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
  testWidgets('every platform links the web account page', (tester) async {
    await _pumpSignedIn(tester);

    expect(find.text('MANAGE PASSWORD'), findsOneWidget);
  }, variant: TargetPlatformVariant.all());
}
