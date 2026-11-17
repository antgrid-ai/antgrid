import 'dart:io';

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show MaterialPageRoute, Scaffold;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../navigation/nav_controller.dart';
import '../navigation/nav_location.dart';
import '../providers/agent_transport.dart';
import '../providers/auth.dart';
import '../providers/subscription.dart';
import '../providers/sessions.dart';
import '../providers/ui_attention_providers.dart';
import '../screens/sign_in_screen.dart';
import '../screens/upgrade_screen.dart';
import '../billing/pricing_visibility.dart';
import '../util/detached.dart';
import 'auth_status_pill.dart';
import 'drawer/drawer_chrome_row.dart';
import 'drawer/drawer_metrics.dart';
import 'help_menu.dart';
import 'sign_out_action.dart';

/// Drawer-footer account affordance.
///
/// Three render states:
///   - Loading or not signed in → "Sign in" CTA.
///   - `currentUserProvider` returns a user, email, tier tag, and account menu.
class AccountFooter extends ConsumerStatefulWidget {
  const AccountFooter({super.key});

  @override
  ConsumerState<AccountFooter> createState() => _AccountFooterState();
}

class _AccountFooterState extends ConsumerState<AccountFooter> {
  final _menuFocus = FocusNode();
  final _menu = CarbonPopupController();

  // Where the Help submenu's "Share logs" sheet anchors on iPad. Captured when
  // the menu opens, because the entries are built before the row has a size.
  Rect? _shareOrigin;

  @override
  void initState() {
    super.initState();
    _menu.addListener(_syncOpen);
  }

  @override
  void dispose() {
    _menu
      ..removeListener(_syncOpen)
      ..dispose();
    _menuFocus.dispose();
    super.dispose();
  }

  void _syncOpen() {
    if (mounted) setState(() {});
  }

  void _toggleMenu() {
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      _shareOrigin = box.localToGlobal(Offset.zero) & box.size;
    }
    _menuFocus.requestFocus();
    _menu.toggle();
  }

  @override
  Widget build(BuildContext context) {
    final userAsync = ref.watch(currentUserProvider);
    final subscription = ref.watch(subscriptionProvider).value;
    ref.watch(pricingCatalogProvider);
    final user = userAsync.value;
    final tier = subscription?.tier ?? user?.tier;
    final showUpgrade =
        kPricingSurfacesEnabled && user != null && tier == 'free';
    final t = CarbonTheme.of(context);
    // The pill renders nothing for a promotional grant (TEMP-PROMO), so its
    // trailing gap must go with it.
    final showTier = user != null && !user.promotional;

    return CarbonMenu(
      controller: _menu,
      preferAbove: true,
      minWidth: _menuWidth,
      maxWidth: _menuWidth,
      restoreFocus: _menuFocus,
      entries: [
        CarbonMenuItem(label: 'App settings…', onPressed: _openSettings),
        helpMenu(
          context: context,
          ref: ref,
          shareOrigin: _shareOrigin,
          returnFocus: _menuFocus,
        ),
        if (showUpgrade)
          CarbonMenuItem(label: 'Upgrade to Pro…', onPressed: _openUpgrade),
        if (user != null)
          CarbonMenuItem(label: 'Sign out', onPressed: _logOut),
        if (user == null)
          CarbonMenuItem(label: 'Sign in', onPressed: _openSignIn),
      ],
      child: DrawerChromeRow(
        focusNode: _menuFocus,
        icon: user != null ? CarbonIcons.user : CarbonIcons.login,
        label: user != null ? user.email : 'Sign in',
        semanticLabel: user != null && showTier
            ? '${user.email}, ${tierLabel(user)}'
            : null,
        expanded: _menu.isOpen,
        onPressed: _toggleMenu,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showTier) ...[
              const SizedBox(width: CarbonSpacing.spacing03),
              AuthStatusPill(user),
            ],
            SizedBox.square(
              dimension: drawerRailCell(t),
              child: Center(
                child: CarbonIcon(
                  CarbonIcons.chevronUp,
                  color: t.colors.iconSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // The drawer's width less a gutter on each side, so the menu reads as part
  // of the panel it rises from.
  static const double _menuWidth =
      kDrawerPanelWidth - 2 * CarbonSpacing.spacing03;

  void _openSignIn() {
    if (!mounted) return;
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SignInScreen()));
  }

  void _openSettings() {
    if (!mounted) return;
    ref
        .read(workbenchSurfaceProvider.notifier)
        .set(WorkbenchSurface.appSettings);
    ref
        .read(navControllerProvider.notifier)
        .commit(
          NavLocation(
            target: ref.read(selectedTargetProvider),
            surface: WorkbenchSurface.appSettings,
            sessionId: ref.read(activeSessionIdProvider),
          ),
        );
    final scaffold = Scaffold.maybeOf(context);
    if (scaffold?.isDrawerOpen ?? false) {
      Navigator.of(context).pop();
    }
  }

  void _logOut() {
    if (!mounted) return;
    detached(
      'AccountFooter',
      'sign out',
      () => confirmAndHardSignOut(context, ref),
    );
  }

  void _openUpgrade() {
    if (!mounted) return;
    final container = ref.container;
    final scaffold = Scaffold.maybeOf(context);
    final scaffoldContext = scaffold?.context;
    if (scaffold?.isDrawerOpen ?? false) {
      Navigator.of(context).pop();
    }
    final targetContext = scaffoldContext ?? context;
    detached('AccountFooter', 'open upgrade', () async {
      if (!targetContext.mounted) return;
      if (Platform.isIOS || Platform.isAndroid) {
        await openUpgrade(targetContext, container);
      } else {
        await openUpgradeInBrowser(container);
      }
    });
  }
}
