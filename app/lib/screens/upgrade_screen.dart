import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_panel_header.dart';
import '../analytics/events.dart';
import '../models/subscription_info.dart';
import '../providers/analytics.dart';
import '../providers/auth.dart';
import '../providers/subscription.dart';
import '../dialogs/remote_upgrade_dialog.dart';

const _proYearlyFeatures = [
  'Up to {workers} workers',
  'Unlimited terminal sessions',
  'File explorer & git viewer',
  'Browser preview tunneling',
  'E2E encrypted — zero-knowledge relay',
  'Priority support',
];

const _proLifetimeFeatures = [
  'Everything in Pro Yearly',
  'Lifetime updates',
  'No renewal fees',
  'Up to {workers} workers',
  'E2E encrypted — zero-knowledge relay',
  'Community support',
];

class UpgradeScreen extends ConsumerStatefulWidget {
  const UpgradeScreen({super.key, this.onClose});

  /// When set (root pricing gate), invoked instead of [Navigator.pop].
  final VoidCallback? onClose;

  @override
  ConsumerState<UpgradeScreen> createState() => _UpgradeScreenState();
}

class _UpgradeScreenState extends ConsumerState<UpgradeScreen> {
  @override
  void initState() {
    super.initState();
    // Fire the view event once per mount — build() can run many times per frame
    // and must stay side-effect free.
    ref.read(analyticsServiceProvider)?.track(AnalyticsEvents.pricingViewed);
  }

  @override
  Widget build(BuildContext context) {
    final catalogAsync = ref.watch(pricingCatalogProvider);

    return Scaffold(
      backgroundColor: context.antgrid.bgDeepest,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AbPanelHeader(
              title: 'PRICING',
              actions: [
                AbIconButton(
                  icon: AbIcons.close,
                  tooltip: 'Close',
                  onTap: widget.onClose ?? () => Navigator.of(context).pop(),
                ),
              ],
            ),
            Expanded(
              child: catalogAsync.when(
                loading: () => const Center(child: AbLoading()),
                error: (e, _) => _ErrorState(
                  message: e.toString(),
                  onRetry: () => ref.invalidate(pricingCatalogProvider),
                ),
                data: (catalog) => _PricingBody(catalog: catalog),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Active subscription that must be managed on another platform (not this OS).
bool requiresCrossPlatformBillingOnDevice(
  SubscriptionInfo? info,
  PricingCatalog? catalog,
) {
  return requiresCrossPlatformBillingDialog(
    info,
    catalog,
    onIos: Platform.isIOS,
    onAndroid: Platform.isAndroid,
  );
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AbTokens.space16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              style: AbTokens.sansStyle(color: context.antgrid.error),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AbTokens.space12),
            AbButton(label: 'Retry', onTap: onRetry),
          ],
        ),
      ),
    );
  }
}

class _PricingBody extends StatelessWidget {
  const _PricingBody({required this.catalog});

  final PricingCatalog? catalog;

  @override
  Widget build(BuildContext context) {
    final catalog = this.catalog;
    if (catalog == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AbTokens.space16),
          child: Text(
            'Could not load pricing.',
            style: AbTokens.sansStyle(color: context.antgrid.textSecondary),
          ),
        ),
      );
    }

    final trialPlan = catalog.planBySlug('trial');
    final yearlyPlan = catalog.planBySlug('pro_yearly');
    final lifetimePlan = catalog.planBySlug('pro_lifetime');
    final yearlyDisplay =
        yearlyPlan?.priceDisplay ?? catalog.yearlyPriceDisplay ?? '';

    return ListView(
      padding: const EdgeInsets.all(AbTokens.space16),
      children: [
        const _PricingHeader(),
        if (trialPlan != null) ...[
          const SizedBox(height: AbTokens.space24),
          _FreeTrialBanner(
            catalog: catalog,
            trialPlan: trialPlan,
            yearlyDisplay: yearlyDisplay,
          ),
        ],
        const SizedBox(height: AbTokens.space24),
        if (yearlyPlan != null)
          _ProYearlyCard(plan: yearlyPlan, price: yearlyDisplay),
        if (yearlyPlan != null && lifetimePlan != null)
          const SizedBox(height: AbTokens.space16),
        if (lifetimePlan != null)
          _ProLifetimeCard(
            plan: lifetimePlan,
            price: lifetimePlan.priceDisplay ?? '',
          ),
      ],
    );
  }
}

class _PricingCta extends StatelessWidget {
  const _PricingCta({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Opacity(
      opacity: 0.4,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: AbTokens.space16,
          vertical: AbTokens.space12,
        ),
        decoration: BoxDecoration(
          color: p.bgSurface,
          border: Border.all(color: p.borderDefault),
          borderRadius: AbTokens.borderRadius8,
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontSm,
            fontWeight: FontWeight.w500,
            color: p.textMuted,
          ),
        ),
      ),
    );
  }
}

class _PricingHeader extends StatelessWidget {
  const _PricingHeader();

  @override
  Widget build(BuildContext context) {
    final antgrid = context.antgrid;
    return Column(
      children: [
        Text(
          'Simple, honest pricing',
          textAlign: TextAlign.center,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontDisplayMd,
            fontWeight: FontWeight.w700,
            color: antgrid.textPrimary,
          ),
        ),
        const SizedBox(height: AbTokens.space12),
        Text(
          'Monitor and control your AI coding agents from anywhere. '
          'E2E encrypted, zero-knowledge relay.',
          textAlign: TextAlign.center,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontSm,
            color: antgrid.textSecondary,
            height: 1.45,
          ),
        ),
      ],
    );
  }
}

class _FreeTrialBanner extends StatelessWidget {
  const _FreeTrialBanner({
    required this.catalog,
    required this.trialPlan,
    required this.yearlyDisplay,
  });

  final PricingCatalog catalog;
  final PricingPlan trialPlan;
  final String yearlyDisplay;

  String _firstChargeDate() {
    final d = DateTime.now().toUtc().add(Duration(days: catalog.trialDays));
    return d.toIso8601String().substring(0, 10);
  }

  @override
  Widget build(BuildContext context) {
    final antgrid = context.antgrid;

    return Opacity(
      opacity: 0.6,
      child: Container(
        padding: const EdgeInsets.all(AbTokens.space16),
        decoration: BoxDecoration(
          color: antgrid.bgSurface,
          border: Border.all(color: antgrid.borderDefault),
          borderRadius: AbTokens.borderRadius8,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: AbTokens.space8,
              runSpacing: AbTokens.space8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const _PlanBadge(label: 'FREE TRIAL'),
                Text(
                  '${catalog.trialDays}-day trial',
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontXs,
                    color: antgrid.textMuted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AbTokens.space8),
            Text(
              '${catalog.trialDays}-day free trial, then $yearlyDisplay/year',
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontLg,
                fontWeight: FontWeight.w600,
                color: antgrid.textPrimary,
              ),
            ),
            const SizedBox(height: AbTokens.space6),
            Text(
              'Add your card to start. Up to ${trialPlan.workerLimit} workers '
              'during the trial. Your card won\'t be charged until ${_firstChargeDate()} '
              '— cancel anytime before then to avoid the $yearlyDisplay/year charge. '
              'Subscription renews automatically unless canceled.',
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontSm,
                color: antgrid.textSecondary,
                height: 1.45,
              ),
            ),
            const SizedBox(height: AbTokens.space16),
            const _PricingCta(label: 'Coming soon'),
          ],
        ),
      ),
    );
  }
}

class _PlanBadge extends StatelessWidget {
  const _PlanBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space8,
        vertical: AbTokens.space2,
      ),
      decoration: BoxDecoration(
        color: p.accent,
        borderRadius: AbTokens.borderRadius3,
      ),
      child: Text(
        label.toUpperCase(),
        style: AbTokens.monoStyle(
          fontSize: AbTokens.fontXs,
          fontWeight: FontWeight.w700,
          color: p.accentForeground,
        ),
      ),
    );
  }
}

class _ProYearlyCard extends StatelessWidget {
  const _ProYearlyCard({required this.plan, required this.price});

  final PricingPlan plan;
  final String price;

  @override
  Widget build(BuildContext context) {
    return _PlanCard(
      title: plan.label,
      price: price,
      priceSuffix: '/ year',
      priceNote: 'Renews annually.',
      features: _proYearlyFeatures,
      workers: plan.workerLimit,
    );
  }
}

class _ProLifetimeCard extends StatelessWidget {
  const _ProLifetimeCard({required this.plan, required this.price});

  final PricingPlan plan;
  final String price;

  @override
  Widget build(BuildContext context) {
    return _PlanCard(
      title: plan.label,
      price: price,
      priceSuffix: 'one-time',
      priceNote: 'Pay once, use forever.',
      features: _proLifetimeFeatures,
      workers: plan.workerLimit,
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.title,
    required this.price,
    required this.priceSuffix,
    required this.priceNote,
    required this.features,
    required this.workers,
  });

  final String title;
  final String price;
  final String priceSuffix;
  final String priceNote;
  final List<String> features;
  final int workers;

  @override
  Widget build(BuildContext context) {
    final antgrid = context.antgrid;

    return Opacity(
      opacity: 0.6,
      child: Container(
        padding: const EdgeInsets.all(AbTokens.space16),
        decoration: BoxDecoration(
          color: antgrid.bgSurface,
          border: Border.all(color: antgrid.borderDefault),
          borderRadius: AbTokens.borderRadius8,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXl,
                fontWeight: FontWeight.w700,
                color: antgrid.textPrimary,
              ),
            ),
            const SizedBox(height: AbTokens.space12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  price,
                  style: AbTokens.monoStyle(
                    fontSize: AbTokens.fontDisplayLg,
                    fontWeight: FontWeight.w700,
                    color: antgrid.textPrimary,
                  ),
                ),
                const SizedBox(width: AbTokens.space4),
                Text(
                  priceSuffix,
                  style: AbTokens.monoStyle(
                    fontSize: AbTokens.fontSm,
                    color: antgrid.textMuted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AbTokens.space6),
            Text(
              priceNote,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: antgrid.textMuted,
              ),
            ),
            _FeatureList(items: features, workers: workers),
            const SizedBox(height: AbTokens.space24),
            const _PricingCta(label: 'Coming soon'),
          ],
        ),
      ),
    );
  }
}

class _FeatureList extends StatelessWidget {
  const _FeatureList({required this.items, required this.workers});

  final List<String> items;
  final int workers;

  @override
  Widget build(BuildContext context) {
    final antgrid = context.antgrid;
    return Padding(
      padding: const EdgeInsets.only(top: AbTokens.space16),
      child: Column(
        children: [
          for (final item in items) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: AbIcon(AbIcons.check, size: 14, color: antgrid.accent),
                ),
                const SizedBox(width: AbTokens.space10),
                Expanded(
                  child: Text(
                    item.replaceAll('{workers}', workers.toString()),
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontSm,
                      color: antgrid.textSecondary,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AbTokens.space10),
          ],
        ],
      ),
    );
  }
}

typedef NativeUpgradePlatformCheck = bool Function();

bool defaultNativeUpgradePlatformCheck() =>
    Platform.isIOS || Platform.isAndroid;

/// Overridable in tests — [defaultNativeUpgradePlatformCheck] in production.
final nativeUpgradePlatformProvider = Provider<bool>(
  (ref) => defaultNativeUpgradePlatformCheck(),
);

Future<bool> maybeShowCrossPlatformBillingDialog(
  BuildContext context,
  ProviderContainer ref, {
  SubscriptionInfo? info,
  PricingCatalog? catalog,
}) async {
  if (!requiresCrossPlatformBillingOnDevice(info, catalog)) return false;
  final provider = resolveSubscriptionProvider(info, catalog);
  if (provider == null) return false;
  if (!context.mounted) return true;
  await showCrossPlatformBillingDialog(
    context,
    provider: provider,
    licenseApiUrl: ref.read(licenseApiUrlProvider),
  );
  return true;
}

/// Takes the container, not a `WidgetRef`: the invalidates below run after the
/// upgrade route pops, long after the widget that opened it may have gone.
Future<void> openUpgrade(
  BuildContext context,
  ProviderContainer ref, {
  NativeUpgradePlatformCheck? platformCheck,
}) async {
  final useNative = platformCheck != null
      ? platformCheck()
      : ref.read(nativeUpgradePlatformProvider);
  if (useNative) {
    SubscriptionInfo? info;
    PricingCatalog? catalog;
    try {
      info = await ref.read(subscriptionProvider.future);
      catalog = await ref.read(pricingCatalogProvider.future);
    } catch (_) {
      info = null;
      catalog = null;
    }
    if (!context.mounted) return;
    if (await maybeShowCrossPlatformBillingDialog(
      context,
      ref,
      info: info,
      catalog: catalog,
    )) {
      return;
    }
    if (!context.mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const UpgradeScreen()));
    ref.invalidate(currentUserProvider);
    ref.invalidate(subscriptionProvider);
    ref.invalidate(pricingCatalogProvider);
    return;
  }
  await openUpgradeInBrowser(ref);
}

// ============================================================================
// TEMP-PROMO: disabled for the promotional release — grep "TEMP-PROMO" repo-
// wide to find every related spot (backend grant logic + this UI).
//
// Every account currently gets full Pro access for free while in-app
// purchases aren't live (see ensureDefaultSubscription in
// web/src/models/subscription.ts). So the real, working pricing/checkout UI
// below — subscriptionProvider-driven current-plan detection, the
// active-plan/promotional banner, and the actual checkout() wiring (mobile
// toast + desktop openUpgradeInBrowser) — is kept here as comments instead
// of deleted, and the static always-"Coming soon" cards above are shown
// instead.
//
// TO RESTORE ONCE PAYMENT INTEGRATION SHIPS:
//   1. Delete the static replacement above this marker: _proYearlyFeatures /
//      _proLifetimeFeatures through _FeatureList (everything from
//      `const _proYearlyFeatures` down to just above this marker).
//   2. Select everything below this marker and strip the leading "// " from
//      each line (most editors: select + "toggle line comment").
//   3. In web/src/routes/ui.tsx's `/pricing` handler and web/src/ui/pricing.tsx,
//      do the matching restore — see the "TEMP-PROMO" comments there.
//   4. Delete this marker block itself (down through the end of this file).
//   5. Run `cd app && flutter analyze && flutter test` to confirm nothing
//      still depends on the promo-only code paths.
// ============================================================================
// import 'dart:io';
//
// import 'package:flutter/material.dart';
// import 'package:flutter_riverpod/flutter_riverpod.dart';
//
// import '../design/ab_colors.dart';
// import '../design/ab_icons.dart';
// import '../design/ab_tokens.dart';
// import '../design/widgets/ab_button.dart';
// import '../design/widgets/ab_toast.dart';
// import '../design/widgets/ab_focus_ring.dart';
// import '../design/widgets/ab_icon.dart';
// import '../design/widgets/ab_icon_button.dart';
// import '../design/widgets/ab_loading.dart';
// import '../design/widgets/ab_panel_header.dart';
// import '../analytics/events.dart';
// import '../models/subscription_info.dart';
// import '../providers/analytics.dart';
// import '../providers/auth.dart';
// import '../providers/subscription.dart';
// import '../dialogs/remote_upgrade_dialog.dart';
//
// const _proYearlyFeatures = [
//   'Up to {workers} workers',
//   'Unlimited terminal sessions',
//   'File explorer & git viewer',
//   'Browser preview tunneling',
//   'E2E encrypted — zero-knowledge relay',
//   'Priority support',
// ];
//
// const _proLifetimeFeatures = [
//   'Everything in Pro Yearly',
//   'Lifetime updates',
//   'No renewal fees',
//   'Up to {workers} workers',
//   'E2E encrypted — zero-knowledge relay',
//   'Community support',
// ];
//
// class UpgradeScreen extends ConsumerStatefulWidget {
//   const UpgradeScreen({super.key, this.onClose});
//
//   /// When set (root pricing gate), invoked instead of [Navigator.pop].
//   final VoidCallback? onClose;
//
//   @override
//   ConsumerState<UpgradeScreen> createState() => _UpgradeScreenState();
// }
//
// class _UpgradeScreenState extends ConsumerState<UpgradeScreen> {
//   @override
//   void initState() {
//     super.initState();
//     // Fire the view event once per mount — build() can run many times per frame
//     // and must stay side-effect free.
//     ref.read(analyticsServiceProvider)?.track(AnalyticsEvents.pricingViewed);
//   }
//
//   @override
//   Widget build(BuildContext context) {
//     final subscriptionAsync = ref.watch(subscriptionProvider);
//     final catalogAsync = ref.watch(pricingCatalogProvider);
//
//     return Scaffold(
//       backgroundColor: context.antgrid.bgDeepest,
//       body: SafeArea(
//         child: Column(
//           crossAxisAlignment: CrossAxisAlignment.stretch,
//           children: [
//             AbPanelHeader(
//               title: 'PRICING',
//               actions: [
//                 AbIconButton(
//                   icon: AbIcons.close,
//                   tooltip: 'Close',
//                   onTap: widget.onClose ?? () => Navigator.of(context).pop(),
//                 ),
//               ],
//             ),
//             Expanded(
//               child: subscriptionAsync.when(
//                 loading: () => const Center(child: AbLoading()),
//                 error: (e, _) => _ErrorState(
//                   message: e.toString(),
//                   onRetry: () {
//                     ref.invalidate(subscriptionProvider);
//                     ref.invalidate(pricingCatalogProvider);
//                   },
//                 ),
//                 data: (info) => catalogAsync.when(
//                   loading: () => const Center(child: AbLoading()),
//                   error: (e, _) => _ErrorState(
//                     message: e.toString(),
//                     onRetry: () {
//                       ref.invalidate(subscriptionProvider);
//                       ref.invalidate(pricingCatalogProvider);
//                     },
//                   ),
//                   data: (catalog) =>
//                       _PricingBody(info: info, catalog: catalog),
//                 ),
//               ),
//             ),
//           ],
//         ),
//       ),
//     );
//   }
// }
//
// /// Active subscription that must be managed on another platform (not this OS).
// bool requiresCrossPlatformBillingOnDevice(
//   SubscriptionInfo? info,
//   PricingCatalog? catalog,
// ) {
//   return requiresCrossPlatformBillingDialog(
//     info,
//     catalog,
//     onIos: Platform.isIOS,
//     onAndroid: Platform.isAndroid,
//   );
// }
//
// class _ErrorState extends StatelessWidget {
//   const _ErrorState({required this.message, required this.onRetry});
//
//   final String message;
//   final VoidCallback onRetry;
//
//   @override
//   Widget build(BuildContext context) {
//     return Center(
//       child: Padding(
//         padding: const EdgeInsets.all(AbTokens.space16),
//         child: Column(
//           mainAxisSize: MainAxisSize.min,
//           children: [
//             Text(
//               message,
//               style: AbTokens.monoStyle(color: context.antgrid.error),
//               textAlign: TextAlign.center,
//             ),
//             const SizedBox(height: AbTokens.space12),
//             AbButton(label: 'Retry', onTap: onRetry),
//           ],
//         ),
//       ),
//     );
//   }
// }
//
// class _PricingBody extends ConsumerWidget {
//   const _PricingBody({
//     required this.info,
//     required this.catalog,
//   });
//
//   final SubscriptionInfo? info;
//   final PricingCatalog? catalog;
//
//   @override
//   Widget build(BuildContext context, WidgetRef ref) {
//     final catalog = this.catalog;
//     // In-app purchases aren't wired up on iOS/Android yet, and this pricing
//     // screen is only ever shown on mobile
//     final isMobile = ref.watch(nativeUpgradePlatformProvider);
//     void checkout(String planSlug) {
//       if (isMobile) {
//         _showComingSoonToast(context);
//         return;
//       }
//       openUpgradeInBrowser(ref, planId: planSlug);
//     }
//     if (catalog == null) {
//       return Center(
//         child: Padding(
//           padding: const EdgeInsets.all(AbTokens.space16),
//           child: Column(
//             mainAxisSize: MainAxisSize.min,
//             children: [
//               Text(
//                 'Could not load pricing.',
//                 style: AbTokens.monoStyle(color: context.antgrid.textSecondary),
//               ),
//               const SizedBox(height: AbTokens.space12),
//               AbButton(
//                 label: 'Retry',
//                 onTap: () {
//                   ref.invalidate(subscriptionProvider);
//                   ref.invalidate(pricingCatalogProvider);
//                 },
//               ),
//             ],
//           ),
//         ),
//       );
//     }
//
//     final current = catalog.currentPlanSlug;
//     final hasActivePlan = current != null;
//     final showTrialBanner = current != 'pro_yearly' && current != 'pro_lifetime';
//     final trialPlan = catalog.planBySlug('trial');
//     final yearlyPlan = catalog.planBySlug('pro_yearly');
//     final lifetimePlan = catalog.planBySlug('pro_lifetime');
//     final yearlyDisplay =
//         yearlyPlan?.priceDisplay ?? catalog.yearlyPriceDisplay ?? '';
//     final activePlanLabel = _activePlanLabel(
//       yearlyPlan,
//       lifetimePlan,
//       trialPlan,
//       current,
//     );
//
//     return ListView(
//       padding: const EdgeInsets.all(AbTokens.space16),
//       children: [
//         const _PricingHeader(),
//         if (hasActivePlan) ...[
//           const SizedBox(height: AbTokens.space16),
//           _ActivePlanBanner(planLabel: activePlanLabel),
//         ],
//         if (trialPlan != null && showTrialBanner) ...[
//           const SizedBox(height: AbTokens.space24),
//           _FreeTrialBanner(
//             catalog: catalog,
//             trialPlan: trialPlan,
//             yearlyDisplay: yearlyDisplay,
//             isCurrent: current == 'trial',
//             isDisabled: hasActivePlan,
//             onCheckout: hasActivePlan ? null : () => checkout('trial'),
//           ),
//         ],
//         const SizedBox(height: AbTokens.space24),
//         if (yearlyPlan != null)
//           _ProYearlyCard(
//             plan: yearlyPlan,
//             price: yearlyDisplay,
//             isCurrent: current == 'pro_yearly',
//             isDisabled: hasActivePlan && current != 'pro_yearly',
//             onCheckout: hasActivePlan && current != 'pro_yearly'
//                 ? null
//                 : () => checkout('pro_yearly'),
//           ),
//         if (yearlyPlan != null && lifetimePlan != null)
//           const SizedBox(height: AbTokens.space16),
//         if (lifetimePlan != null)
//           _ProLifetimeCard(
//             plan: lifetimePlan,
//             price: lifetimePlan.priceDisplay ?? '',
//             isCurrent: current == 'pro_lifetime',
//             isDisabled: hasActivePlan && current != 'pro_lifetime',
//             onCheckout: hasActivePlan && current != 'pro_lifetime'
//                 ? null
//                 : () => checkout('pro_lifetime'),
//           ),
//       ],
//     );
//   }
//
//   String? _activePlanLabel(
//     PricingPlan? yearlyPlan,
//     PricingPlan? lifetimePlan,
//     PricingPlan? trialPlan,
//     String? current,
//   ) {
//     return switch (current) {
//       'pro_yearly' => yearlyPlan?.label ?? 'Pro Yearly',
//       'pro_lifetime' => lifetimePlan?.label ?? 'Pro Lifetime',
//       'trial' => trialPlan?.label ?? 'Trial',
//       _ => info?.isPro == true ? 'Pro' : null,
//     };
//   }
// }
//
// class _PlanBadge extends StatelessWidget {
//   const _PlanBadge({required this.label});
//
//   final String label;
//
//   @override
//   Widget build(BuildContext context) {
//     final p = context.antgrid;
//     return Container(
//       padding: const EdgeInsets.symmetric(
//         horizontal: AbTokens.space8,
//         vertical: AbTokens.space2,
//       ),
//       decoration: BoxDecoration(
//         color: p.accent,
//         borderRadius: AbTokens.borderRadius3,
//       ),
//       child: Text(
//         label.toUpperCase(),
//         style: AbTokens.monoStyle(
//           fontSize: AbTokens.fontXs,
//           fontWeight: FontWeight.w700,
//           color: p.accentForeground,
//         ),
//       ),
//     );
//   }
// }
//
// class _PricingCta extends StatefulWidget {
//   const _PricingCta({required this.label, this.onTap});
//
//   final String label;
//   final VoidCallback? onTap;
//
//   @override
//   State<_PricingCta> createState() => _PricingCtaState();
// }
//
// class _PricingCtaState extends State<_PricingCta> {
//   bool _hovered = false;
//   bool _focused = false;
//
//   @override
//   Widget build(BuildContext context) {
//     final p = context.antgrid;
//     final enabled = widget.onTap != null;
//
//     Widget button = Container(
//       width: double.infinity,
//       padding: const EdgeInsets.symmetric(
//         horizontal: AbTokens.space16,
//         vertical: AbTokens.space12,
//       ),
//       decoration: BoxDecoration(
//         color: enabled && _hovered ? p.bgElevated : p.bgSurface,
//         border: Border.all(color: p.borderDefault),
//         borderRadius: AbTokens.borderRadius8,
//       ),
//       alignment: Alignment.center,
//       child: Text(
//         enabled ? '${widget.label} →' : widget.label,
//         style: AbTokens.monoStyle(
//           fontSize: AbTokens.fontSm,
//           fontWeight: FontWeight.w500,
//           color: enabled ? p.textPrimary : p.textMuted,
//         ),
//       ),
//     );
//
//     if (!enabled) {
//       return Opacity(opacity: 0.4, child: button);
//     }
//
//     return FocusableActionDetector(
//       mouseCursor: SystemMouseCursors.click,
//       onShowFocusHighlight: (v) {
//         if (_focused != v) setState(() => _focused = v);
//       },
//       onShowHoverHighlight: (v) {
//         if (_hovered != v) setState(() => _hovered = v);
//       },
//       actions: {
//         ActivateIntent: CallbackAction<ActivateIntent>(
//           onInvoke: (_) {
//             widget.onTap?.call();
//             return null;
//           },
//         ),
//       },
//       child: GestureDetector(
//         onTap: widget.onTap,
//         child: AbFocusRing(
//           focused: _focused,
//           borderRadius: AbTokens.borderRadius8,
//           child: button,
//         ),
//       ),
//     );
//   }
// }
//
// class _PricingHeader extends StatelessWidget {
//   const _PricingHeader();
//
//   @override
//   Widget build(BuildContext context) {
//     final antgrid = context.antgrid;
//     return Column(
//       children: [
//         Text(
//           'Simple, honest pricing',
//           textAlign: TextAlign.center,
//           style: AbTokens.monoStyle(
//             fontSize: AbTokens.fontDisplayMd,
//             fontWeight: FontWeight.w700,
//             color: antgrid.textPrimary,
//           ),
//         ),
//         const SizedBox(height: AbTokens.space12),
//         Text(
//           'Monitor and control your AI coding agents from anywhere. '
//           'E2E encrypted, zero-knowledge relay.',
//           textAlign: TextAlign.center,
//           style: AbTokens.sansStyle(
//             fontSize: AbTokens.fontSm,
//             color: antgrid.textSecondary,
//             height: 1.45,
//           ),
//         ),
//       ],
//     );
//   }
// }
//
// class _ActivePlanBanner extends StatelessWidget {
//   const _ActivePlanBanner({required this.planLabel});
//
//   final String? planLabel;
//
//   @override
//   Widget build(BuildContext context) {
//     final antgrid = context.antgrid;
//     final headline = planLabel != null
//         ? 'You\'re on $planLabel'
//         : 'Your plan is active';
//     return Container(
//       padding: const EdgeInsets.all(AbTokens.space12),
//       decoration: BoxDecoration(
//         color: antgrid.bgSurface,
//         border: Border.all(color: antgrid.accent.withAlpha(80)),
//         borderRadius: AbTokens.borderRadius8,
//       ),
//       child: Column(
//         crossAxisAlignment: CrossAxisAlignment.stretch,
//         children: [
//           Text(
//             headline,
//             style: AbTokens.monoStyle(
//               fontSize: AbTokens.fontSm,
//               fontWeight: FontWeight.w600,
//               color: antgrid.textPrimary,
//             ),
//           ),
//           const SizedBox(height: AbTokens.space6),
//           Text(
//             'You already have full access. Plan changes aren\'t available here.',
//             style: AbTokens.sansStyle(
//               fontSize: AbTokens.fontSm,
//               color: antgrid.textSecondary,
//               height: 1.45,
//             ),
//           ),
//         ],
//       ),
//     );
//   }
// }
//
// class _FreeTrialBanner extends StatelessWidget {
//   const _FreeTrialBanner({
//     required this.catalog,
//     required this.trialPlan,
//     required this.yearlyDisplay,
//     required this.isCurrent,
//     required this.isDisabled,
//     this.onCheckout,
//   });
//
//   final PricingCatalog catalog;
//   final PricingPlan trialPlan;
//   final String yearlyDisplay;
//   final bool isCurrent;
//   final bool isDisabled;
//   final VoidCallback? onCheckout;
//
//   String _firstChargeDate() {
//     final d = DateTime.now().toUtc().add(Duration(days: catalog.trialDays));
//     return d.toIso8601String().substring(0, 10);
//   }
//
//   @override
//   Widget build(BuildContext context) {
//     final antgrid = context.antgrid;
//     final borderColor = isCurrent ? antgrid.accent : antgrid.borderDefault;
//     final opacity = isDisabled && !isCurrent ? 0.6 : 1.0;
//
//     return Opacity(
//       opacity: opacity,
//       child: Container(
//         padding: const EdgeInsets.all(AbTokens.space16),
//         decoration: BoxDecoration(
//           color: antgrid.bgSurface,
//           border: Border.all(color: borderColor),
//           borderRadius: AbTokens.borderRadius8,
//         ),
//         child: Column(
//           crossAxisAlignment: CrossAxisAlignment.stretch,
//           children: [
//             Wrap(
//               spacing: AbTokens.space8,
//               runSpacing: AbTokens.space8,
//               crossAxisAlignment: WrapCrossAlignment.center,
//               children: [
//                 if (isCurrent)
//                   const _PlanBadge(label: 'CURRENT PLAN')
//                 else
//                   const _PlanBadge(label: 'FREE TRIAL'),
//                 Text(
//                   '${catalog.trialDays}-day trial',
//                   style: AbTokens.monoStyle(
//                     fontSize: AbTokens.fontXs,
//                     color: antgrid.textMuted,
//                   ),
//                 ),
//               ],
//             ),
//             const SizedBox(height: AbTokens.space8),
//             Text(
//               '${catalog.trialDays}-day free trial, then $yearlyDisplay/year',
//               style: AbTokens.monoStyle(
//                 fontSize: AbTokens.fontLg,
//                 fontWeight: FontWeight.w600,
//                 color: antgrid.textPrimary,
//               ),
//             ),
//             const SizedBox(height: AbTokens.space6),
//             Text(
//               isCurrent
//                   ? 'Your trial is active with up to ${trialPlan.workerLimit} workers.'
//                   : 'Add your card to start. Up to ${trialPlan.workerLimit} workers '
//                       'during the trial. Your card won\'t be charged until ${_firstChargeDate()} '
//                       '— cancel anytime before then to avoid the $yearlyDisplay/year charge. '
//                       'Subscription renews automatically unless canceled.',
//               style: AbTokens.sansStyle(
//                 fontSize: AbTokens.fontSm,
//                 color: antgrid.textSecondary,
//                 height: 1.45,
//               ),
//             ),
//             const SizedBox(height: AbTokens.space16),
//             if (isCurrent)
//               const _PricingCta(label: 'Current plan', onTap: null)
//             else if (isDisabled)
//               _PricingCta(
//                 label: 'Start ${catalog.trialDays}-day trial',
//                 onTap: null,
//               )
//             else
//               _PricingCta(
//                 label: 'Start ${catalog.trialDays}-day trial',
//                 onTap: onCheckout,
//               ),
//             const SizedBox(height: AbTokens.space8),
//             Text(
//               isCurrent
//                   ? 'You\'re on this plan.'
//                   : isDisabled
//                   ? ''
//                   : '$yearlyDisplay/year · Renews automatically · Cancel anytime',
//               textAlign: TextAlign.center,
//               style: AbTokens.monoStyle(
//                 fontSize: AbTokens.fontXs,
//                 color: antgrid.textMuted,
//                 height: 1.4,
//               ),
//             ),
//           ],
//         ),
//       ),
//     );
//   }
// }
//
// class _ProYearlyCard extends StatelessWidget {
//   const _ProYearlyCard({
//     required this.plan,
//     required this.price,
//     required this.isCurrent,
//     required this.isDisabled,
//     this.onCheckout,
//   });
//
//   final PricingPlan plan;
//   final String price;
//   final bool isCurrent;
//   final bool isDisabled;
//   final VoidCallback? onCheckout;
//
//   @override
//   Widget build(BuildContext context) {
//     return _PlanCard(
//       title: plan.label,
//       price: price,
//       priceSuffix: '/ year',
//       priceNote: 'Renews annually.',
//       features: _proYearlyFeatures,
//       workers: plan.workerLimit,
//       isCurrent: isCurrent,
//       isDisabled: isDisabled,
//       recommended: false,
//       ctaLabel: 'Get Pro Yearly',
//       ctaFooter: '$price/year · Renews automatically · Cancel anytime',
//       onCheckout: onCheckout,
//     );
//   }
// }
//
// class _ProLifetimeCard extends StatelessWidget {
//   const _ProLifetimeCard({
//     required this.plan,
//     required this.price,
//     required this.isCurrent,
//     required this.isDisabled,
//     this.onCheckout,
//   });
//
//   final PricingPlan plan;
//   final String price;
//   final bool isCurrent;
//   final bool isDisabled;
//   final VoidCallback? onCheckout;
//
//   @override
//   Widget build(BuildContext context) {
//     return _PlanCard(
//       title: plan.label,
//       price: price,
//       priceSuffix: 'one-time',
//       priceNote: 'Pay once, use forever.',
//       features: _proLifetimeFeatures,
//       workers: plan.workerLimit,
//       isCurrent: isCurrent,
//       isDisabled: isDisabled,
//       recommended: !isCurrent && !isDisabled,
//       ctaLabel: 'Get Lifetime Access',
//       ctaFooter: 'One-time payment · No subscription',
//       onCheckout: onCheckout,
//     );
//   }
// }
//
// class _PlanCard extends StatelessWidget {
//   const _PlanCard({
//     required this.title,
//     required this.price,
//     required this.priceSuffix,
//     required this.priceNote,
//     required this.features,
//     required this.workers,
//     required this.isCurrent,
//     required this.isDisabled,
//     required this.recommended,
//     required this.ctaLabel,
//     required this.ctaFooter,
//     this.onCheckout,
//   });
//
//   final String title;
//   final String price;
//   final String priceSuffix;
//   final String priceNote;
//   final List<String> features;
//   final int workers;
//   final bool isCurrent;
//   final bool isDisabled;
//   final bool recommended;
//   final String ctaLabel;
//   final String ctaFooter;
//   final VoidCallback? onCheckout;
//
//   @override
//   Widget build(BuildContext context) {
//     final antgrid = context.antgrid;
//     final borderColor = isCurrent
//         ? antgrid.accent
//         : recommended
//         ? antgrid.accent
//         : antgrid.borderDefault;
//     final opacity = isDisabled && !isCurrent ? 0.6 : 1.0;
//
//     return Opacity(
//       opacity: opacity,
//       child: Container(
//         padding: const EdgeInsets.all(AbTokens.space16),
//         decoration: BoxDecoration(
//           color: antgrid.bgSurface,
//           border: Border.all(color: borderColor),
//           borderRadius: AbTokens.borderRadius8,
//         ),
//         child: Column(
//           crossAxisAlignment: CrossAxisAlignment.stretch,
//           children: [
//             Wrap(
//               spacing: AbTokens.space8,
//               runSpacing: AbTokens.space8,
//               crossAxisAlignment: WrapCrossAlignment.center,
//               children: [
//                 Text(
//                   title,
//                   style: AbTokens.monoStyle(
//                     fontSize: AbTokens.fontXl,
//                     fontWeight: FontWeight.w700,
//                     color: antgrid.textPrimary,
//                   ),
//                 ),
//                 if (isCurrent)
//                   const _PlanBadge(label: 'CURRENT')
//                 else if (recommended)
//                   const _PlanBadge(label: 'RECOMMENDED'),
//               ],
//             ),
//             const SizedBox(height: AbTokens.space12),
//             Row(
//               crossAxisAlignment: CrossAxisAlignment.baseline,
//               textBaseline: TextBaseline.alphabetic,
//               children: [
//                 Text(
//                   price,
//                   style: AbTokens.monoStyle(
//                     fontSize: AbTokens.fontDisplayLg,
//                     fontWeight: FontWeight.w700,
//                     color: antgrid.textPrimary,
//                   ),
//                 ),
//                 const SizedBox(width: AbTokens.space4),
//                 Text(
//                   priceSuffix,
//                   style: AbTokens.monoStyle(
//                     fontSize: AbTokens.fontSm,
//                     color: antgrid.textMuted,
//                   ),
//                 ),
//               ],
//             ),
//             const SizedBox(height: AbTokens.space6),
//             Text(
//               priceNote,
//               style: AbTokens.monoStyle(
//                 fontSize: AbTokens.fontXs,
//                 color: antgrid.textMuted,
//               ),
//             ),
//             _FeatureList(items: features, workers: workers),
//             const SizedBox(height: AbTokens.space24),
//             if (isCurrent)
//               const _PricingCta(label: 'Current plan', onTap: null)
//             else if (isDisabled)
//               _PricingCta(label: ctaLabel, onTap: null)
//             else
//               _PricingCta(label: ctaLabel, onTap: onCheckout),
//             const SizedBox(height: AbTokens.space12),
//             Text(
//               isCurrent ? 'You\'re on this plan.' : ctaFooter,
//               textAlign: TextAlign.center,
//               style: AbTokens.monoStyle(
//                 fontSize: AbTokens.fontXs,
//                 color: antgrid.textMuted,
//                 height: 1.4,
//               ),
//             ),
//           ],
//         ),
//       ),
//     );
//   }
// }
//
// class _FeatureList extends StatelessWidget {
//   const _FeatureList({required this.items, required this.workers});
//
//   final List<String> items;
//   final int workers;
//
//   @override
//   Widget build(BuildContext context) {
//     final antgrid = context.antgrid;
//     return Padding(
//       padding: const EdgeInsets.only(top: AbTokens.space16),
//       child: Column(
//         children: [
//           for (final item in items) ...[
//             Row(
//               crossAxisAlignment: CrossAxisAlignment.start,
//               children: [
//                 Padding(
//                   padding: const EdgeInsets.only(top: 2),
//                   child: AbIcon(
//                     AbIcons.check,
//                     size: 14,
//                     color: antgrid.accent,
//                   ),
//                 ),
//                 const SizedBox(width: AbTokens.space10),
//                 Expanded(
//                   child: Text(
//                     item.replaceAll('{workers}', workers.toString()),
//                     style: AbTokens.sansStyle(
//                       fontSize: AbTokens.fontSm,
//                       color: antgrid.textSecondary,
//                       height: 1.4,
//                     ),
//                   ),
//                 ),
//               ],
//             ),
//             const SizedBox(height: AbTokens.space10),
//           ],
//         ],
//       ),
//     );
//   }
// }
//
// void _showComingSoonToast(BuildContext context) {
//   showAbToastOverlay(
//     context,
//     toast: AbToast(
//       icon: AbIcons.info,
//       title: 'Coming soon',
//       description: 'In-app purchases are not available yet.',
//       iconColor: context.antgrid.accent,
//     ),
//   );
// }
//
// typedef NativeUpgradePlatformCheck = bool Function();
//
// bool defaultNativeUpgradePlatformCheck() => Platform.isIOS || Platform.isAndroid;
//
// /// Overridable in tests — [defaultNativeUpgradePlatformCheck] in production.
// final nativeUpgradePlatformProvider = Provider<bool>(
//   (ref) => defaultNativeUpgradePlatformCheck(),
// );
//
// Future<bool> maybeShowCrossPlatformBillingDialog(
//   BuildContext context,
//   WidgetRef ref, {
//   SubscriptionInfo? info,
//   PricingCatalog? catalog,
// }) async {
//   if (!requiresCrossPlatformBillingOnDevice(info, catalog)) return false;
//   final provider = resolveSubscriptionProvider(info, catalog);
//   if (provider == null) return false;
//   if (!context.mounted) return true;
//   await showCrossPlatformBillingDialog(
//     context,
//     provider: provider,
//     licenseApiUrl: ref.read(licenseApiUrlProvider),
//   );
//   return true;
// }
//
// Future<void> openUpgrade(
//   BuildContext context,
//   WidgetRef ref, {
//   NativeUpgradePlatformCheck? platformCheck,
// }) async {
//   final useNative = platformCheck != null
//       ? platformCheck()
//       : ref.read(nativeUpgradePlatformProvider);
//   if (useNative) {
//     SubscriptionInfo? info;
//     PricingCatalog? catalog;
//     try {
//       info = await ref.read(subscriptionProvider.future);
//       catalog = await ref.read(pricingCatalogProvider.future);
//     } catch (_) {
//       info = null;
//       catalog = null;
//     }
//     if (!context.mounted) return;
//     if (await maybeShowCrossPlatformBillingDialog(
//       context,
//       ref,
//       info: info,
//       catalog: catalog,
//     )) {
//       return;
//     }
//     if (!context.mounted) return;
//     await Navigator.of(context).push(
//       MaterialPageRoute<void>(builder: (_) => const UpgradeScreen()),
//     );
//     ref.invalidate(currentUserProvider);
//     ref.invalidate(subscriptionProvider);
//     ref.invalidate(pricingCatalogProvider);
//     return;
//   }
//   await openUpgradeInBrowser(ref);
// }
