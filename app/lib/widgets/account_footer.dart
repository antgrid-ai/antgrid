import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_menu.dart';
import '../navigation/nav_controller.dart';
import '../navigation/nav_location.dart';
import '../providers/agent_transport.dart';
import '../providers/auth.dart';
import '../providers/subscription.dart';
import '../providers/sessions.dart';
import '../providers/ui_attention_providers.dart';
import '../screens/sign_in_screen.dart';
import '../screens/upgrade_screen.dart';
import 'auth_status_pill.dart';
import 'sign_out_action.dart';

/// Drawer-footer account affordance.
///
/// Three render states:
///   - Loading or not signed in → "Sign in" CTA.
///   - `currentUserProvider` returns a user, email, tier pill, and account menu.
class AccountFooter extends ConsumerWidget {
  const AccountFooter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userAsync = ref.watch(currentUserProvider);
    final subscription = ref.watch(subscriptionProvider).value;
    ref.watch(pricingCatalogProvider);
    final user = userAsync.value;
    final tier = subscription?.tier ?? user?.tier;
    final showUpgrade = user != null && tier == 'free';
    final tone = context.antgrid.textSecondary;

    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: context.antgrid.borderSubtle)),
      ),
      child: Builder(
        builder: (rowCtx) => InkWell(
          hoverColor: context.antgrid.bgElevated,
          onTap: () => _showMenu(
            rowCtx,
            ref,
            signedIn: user != null,
            showUpgrade: showUpgrade,
          ),
          onLongPress: () => _showMenu(
            rowCtx,
            ref,
            signedIn: user != null,
            showUpgrade: showUpgrade,
          ),
          child: SizedBox(
            height: AbTokens.commandTrayHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AbTokens.space16),
              child: Row(
                children: [
                  AbIcon(
                    user != null ? AbIcons.account : AbIcons.signIn,
                    size: 12,
                    color: tone,
                  ),
                  const SizedBox(width: AbTokens.space10),
                  Expanded(
                    child: Text(
                      user != null ? user.email : 'Sign in',
                      style: AbTokens.monoStyle(
                        fontSize: AbTokens.fontXs,
                        color: tone,
                        letterSpacing: 0.2,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (user != null) ...[
                    AuthStatusPill(user),
                    const SizedBox(width: AbTokens.space8),
                  ],
                  AbIcon(
                    AbIcons.chevronRight,
                    size: 10,
                    color: context.antgrid.textMuted,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openSignIn(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SignInScreen()));
  }

  void _openSettings(BuildContext context, WidgetRef ref) {
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

  Future<void> _logOut(BuildContext context, WidgetRef ref) =>
      confirmAndHardSignOut(context, ref);

  Future<void> _openUpgrade(BuildContext context, WidgetRef ref) async {
    final scaffold = Scaffold.maybeOf(context);
    final scaffoldContext = scaffold?.context;
    if (scaffold?.isDrawerOpen ?? false) {
      Navigator.of(context).pop();
    }
    final targetContext = scaffoldContext ?? context;
    if (!targetContext.mounted) return;
    if (Platform.isIOS || Platform.isAndroid) {
      await openUpgrade(targetContext, ref);
    } else {
      await openUpgradeInBrowser(ref);
    }
  }

  Future<void> _showMenu(
    BuildContext anchor,
    WidgetRef ref, {
    required bool signedIn,
    required bool showUpgrade,
  }) async {
    final context = anchor;
    final box = anchor.findRenderObject() as RenderBox;
    final overlay = Overlay.of(anchor).context.findRenderObject() as RenderBox;
    final gearTopLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final bounds = MenuBoundsScope.maybeOf(anchor);
    // Inside the drawer scope: spread the menu across the full drawer
    // width by faking an anchor rect that spans bounds.left+pad → right,
    // and asking for a width equal to (bounds.width - 2 * pad). The
    // layout delegate's own edgePad (8) keeps inner breathing room, so
    // we mirror that here to get symmetric gutters.
    const pad = 8.0;
    final useBounds = bounds != null;
    final anchorRect = useBounds
        ? Rect.fromLTWH(
            bounds.left + pad,
            gearTopLeft.dy,
            bounds.width - 2 * pad,
            box.size.height,
          )
        : gearTopLeft & box.size;
    final menuWidth = useBounds ? bounds.width - 2 * pad : 200.0;
    final selected = await showAbMenu<_AccountMenu>(
      context: anchor,
      anchorRect: anchorRect,
      // Footer sits at the drawer bottom — open above the gear.
      preferred: AbMenuPlacement.above,
      width: menuWidth,
      bounds: bounds,
      entries: [
        const AbMenuItem(
          label: 'App settings…',
          value: _AccountMenu.settings,
          icon: AbIcons.settings,
        ),
        if (showUpgrade)
          const AbMenuItem(
            label: 'Upgrade to Pro…',
            value: _AccountMenu.upgrade,
            icon: AbIcons.shield,
          ),
        if (signedIn)
          const AbMenuItem(label: 'Sign out', value: _AccountMenu.logout),
        if (!signedIn)
          const AbMenuItem(label: 'Sign in', value: _AccountMenu.signIn),
      ],
    );
    switch (selected) {
      case _AccountMenu.settings:
        if (context.mounted) _openSettings(context, ref);
        break;
      case _AccountMenu.upgrade:
        if (context.mounted) await _openUpgrade(context, ref);
        break;
      case _AccountMenu.logout:
        if (context.mounted) await _logOut(context, ref);
        break;
      case _AccountMenu.signIn:
        if (context.mounted) _openSignIn(context);
        break;
      case null:
        break;
    }
  }
}

enum _AccountMenu { settings, upgrade, logout, signIn }
