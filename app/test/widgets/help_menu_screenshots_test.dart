import 'dart:io';
import 'dart:ui' as ui;

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/providers/app_version.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/providers/subscription.dart';
import 'package:antgrid/services/auth_service.dart';
import 'package:antgrid/update/update_check_result.dart';
import 'package:antgrid/update/update_install_controller.dart';
import 'package:antgrid/update/update_strategy.dart';
import 'package:antgrid/widgets/account_footer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/update_fakes.dart';

// Opt-in artifact export: flutter test --dart-define=UPDATE_HELP_SCREENSHOTS=true
// test/widgets/help_menu_screenshots_test.dart. Fonts are loaded from the app
// bundle and the host system; output comes from the actual Flutter widgets.
void main() {
  for (final mobile in [false, true]) {
    testWidgets(
      'render ${mobile ? 'mobile' : 'desktop'} Help and update dialog',
      (tester) async {
        useInMemoryPrefs();
        debugDisableShadows = false;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = mobile
            ? const Size(340, 460)
            : const Size(600, 360);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.runAsync(() async {
          await (FontLoader(AbTokens.fontMono)..addFont(
                rootBundle.load('assets/fonts/JetBrainsMonoNL-Regular.ttf'),
              ))
              .load();
          final sans = File('C:/Windows/Fonts/segoeui.ttf');
          if (await sans.exists()) {
            final bytes = await sans.readAsBytes();
            await (FontLoader(
              AbTokens.fontSans,
            )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
          }
        });
        final key = GlobalKey();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              currentUserProvider.overrideWith(
                (_) async => CurrentUser(
                  userId: 'sample',
                  email: 'review@antgrid.ai',
                  tier: 'pro',
                ),
              ),
              subscriptionProvider.overrideWith((_) async => null),
              pricingCatalogProvider.overrideWith((_) async => null),
              appVersionLabelProvider.overrideWith((_) async => 'dev build'),
              updateStrategyProvider.overrideWithValue(
                FakeUpdateStrategy(
                  result: const UpdateCheckResult(
                    UpdateCheckStatus.available,
                    version: '2.0.0',
                  ),
                )..action = mobile ? 'Update' : 'Install & restart',
              ),
              updateInstallControllerProvider.overrideWith(
                SpyUpdateInstallController.new,
              ),
            ],
            child: RepaintBoundary(
              key: key,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: buildAbTheme(),
                home: const Scaffold(
                  body: Align(
                    alignment: Alignment.bottomLeft,
                    child: SizedBox(width: 280, child: AccountFooter()),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byType(AccountFooter));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Help'));
        await tester.pumpAndSettle();

        Future<void> export(String suffix) async {
          await tester.runAsync(() async {
            final boundary =
                key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 2);
            try {
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                '../docs/screenshots/help-submenu/${mobile ? 'mobile' : 'desktop'}$suffix.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }

        await export('');
        await tester.ensureVisible(find.text('Check for updates…'));
        await tester.tap(find.text('Check for updates…'));
        await tester.pumpAndSettle();
        await export('-update');
        expect(tester.takeException(), isNull);
        debugDisableShadows = true;
      },
      skip: !const bool.fromEnvironment('UPDATE_HELP_SCREENSHOTS'),
      variant: TargetPlatformVariant.only(
        mobile ? TargetPlatform.android : TargetPlatform.windows,
      ),
    );
  }
}
