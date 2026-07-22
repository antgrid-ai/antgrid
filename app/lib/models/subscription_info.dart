class SubscriptionInfo {
  SubscriptionInfo({
    required this.tier,
    this.accountId,
    this.provider,
    this.planSlug,
    this.promotional = false,
  });

  final String tier;
  final String? accountId;
  final String? provider;
  final String? planSlug;

  /// True when [tier] is a temporary, unpurchased promo grant (in-app
  /// purchases aren't live yet) rather than a real subscription.
  final bool promotional;

  bool get isPro => tier != 'free';

  factory SubscriptionInfo.fromMeJson(Map<String, dynamic> json) {
    final tier = json['tier'] as String? ?? 'free';
    final sub = json['subscription'] as Map<String, dynamic>?;
    final provider =
        json['subscription_provider'] as String? ?? sub?['provider'] as String?;
    final promotional =
        json['promotional'] as bool? ?? sub?['promotional'] as bool? ?? false;
    return SubscriptionInfo(
      tier: tier,
      accountId: json['account_id'] as String?,
      provider: provider,
      planSlug: _planSlugFromSubscription(sub, tier),
      promotional: promotional,
    );
  }
}

/// Stable plan UUIDs from web `PLAN_UUID` — `/subscriptions/me` returns these as
/// `subscription.plan_id`, not slugs.
const _planIdToSlug = {
  '00000000-0000-4000-8000-000000000001': 'free',
  '00000000-0000-4000-8000-000000000002': 'pro_yearly',
  '00000000-0000-4000-8000-000000000003': 'pro_lifetime',
  '00000000-0000-4000-8000-000000000004': 'trial',
};

const _knownPlanSlugs = {'free', 'trial', 'pro_yearly', 'pro_lifetime'};

String? _planSlugFromSubscription(Map<String, dynamic>? sub, String tier) {
  if (tier == 'free') return null;
  if (sub == null) return null;

  final planId = sub['plan_id'] as String?;
  if (planId != null && planId.isNotEmpty) {
    if (_knownPlanSlugs.contains(planId)) return planId;
    final mapped = _planIdToSlug[planId];
    if (mapped != null) return mapped;
  }

  final status = sub['status'] as String?;
  if (status == 'trialing') return 'trial';
  final trialEndsRaw = sub['trial_ends_at'] as String?;
  if (trialEndsRaw != null) {
    final trialEnds = DateTime.tryParse(trialEndsRaw);
    if (trialEnds != null && trialEnds.isAfter(DateTime.now().toUtc())) {
      return 'trial';
    }
  }

  // Paid tier without a resolvable plan_id — yearly is the safe default (never
  // infer lifetime from a missing current_period_end; many yearly subs omit it).
  if (status == 'active' || tier == 'pro') return 'pro_yearly';
  return null;
}

class PricingPlan {
  PricingPlan({
    required this.slug,
    required this.label,
    required this.sessionLimit,
    this.priceDisplay,
    required this.recurring,
    required this.trial,
  });

  final String slug;
  final String label;
  final int sessionLimit;
  final String? priceDisplay;
  final bool recurring;
  final bool trial;

  factory PricingPlan.fromJson(Map<String, dynamic> json) {
    return PricingPlan(
      slug: json['slug'] as String,
      label: json['label'] as String,
      sessionLimit: json['session_limit'] as int,
      priceDisplay: json['price_display'] as String?,
      recurring: json['recurring'] as bool? ?? false,
      trial: json['trial'] as bool? ?? false,
    );
  }
}

class PricingCatalog {
  PricingCatalog({
    required this.plans,
    this.currentPlanSlug,
    this.trialDays = 7,
    this.yearlyPriceDisplay,
  });

  final List<PricingPlan> plans;
  final String? currentPlanSlug;
  final int trialDays;
  final String? yearlyPriceDisplay;

  PricingPlan? planBySlug(String slug) {
    for (final plan in plans) {
      if (plan.slug == slug) return plan;
    }
    return null;
  }

  PricingCatalog copyWithCurrentPlan(String? slug) {
    return PricingCatalog(
      plans: plans,
      currentPlanSlug: slug,
      trialDays: trialDays,
      yearlyPriceDisplay: yearlyPriceDisplay,
    );
  }

  factory PricingCatalog.fromPlansJson(
    Map<String, dynamic> json, {
    String? currentPlanSlug,
  }) {
    final plansRaw = json['plans'] as List<dynamic>? ?? [];
    final plans = plansRaw
        .map((e) => PricingPlan.fromJson(e as Map<String, dynamic>))
        .toList();
    String? yearly;
    for (final plan in plans) {
      if (plan.slug == 'pro_yearly') {
        yearly = plan.priceDisplay;
        break;
      }
    }
    return PricingCatalog(
      plans: plans,
      currentPlanSlug: currentPlanSlug,
      trialDays: 7,
      yearlyPriceDisplay: yearly,
    );
  }
}

String? resolveSubscriptionProvider(
  SubscriptionInfo? info,
  PricingCatalog? catalog,
) {
  final provider = info?.provider;
  if (provider == null || provider.isEmpty) return null;
  return provider;
}

bool hasActivePaidPlan(SubscriptionInfo? info, PricingCatalog? catalog) {
  if (info?.isPro == true) return true;
  final current = catalog?.currentPlanSlug ?? info?.planSlug;
  return current != null && current != 'free';
}

bool isWebBillingProvider(String provider) =>
    provider == 'paddle' || provider == 'razorpay';

bool isAppStoreBillingProvider(String provider) => provider == 'app_store';

bool isPlayStoreBillingProvider(String provider) => provider == 'play_store';

/// Whether an active subscription must be changed outside this app on this OS.
///
/// No [provider] ⇒ pricing page. Known store [provider] on the wrong OS ⇒
/// manage dialog for that purchase channel.
bool requiresCrossPlatformBillingDialog(
  SubscriptionInfo? info,
  PricingCatalog? catalog, {
  required bool onIos,
  required bool onAndroid,
}) {
  final provider = resolveSubscriptionProvider(info, catalog);
  if (provider == null) return false;
  if (isWebBillingProvider(provider)) return false;
  if (!hasActivePaidPlan(info, catalog)) return false;
  if (isAppStoreBillingProvider(provider)) return !onIos;
  if (isPlayStoreBillingProvider(provider)) return !onAndroid;
  return false;
}

String crossPlatformManageUrl({
  required String provider,
  required String licenseApiUrl,
  String playPackageName = 'ai.antgrid.app',
}) {
  if (isWebBillingProvider(provider)) {
    final base = licenseApiUrl.replaceAll(RegExp(r'/+$'), '');
    return '$base/dashboard';
  }
  if (isAppStoreBillingProvider(provider)) {
    return 'https://apps.apple.com/account/subscriptions';
  }
  if (isPlayStoreBillingProvider(provider)) {
    return 'https://play.google.com/store/account/subscriptions'
        '?package=${Uri.encodeComponent(playPackageName)}';
  }
  final base = licenseApiUrl.replaceAll(RegExp(r'/+$'), '');
  return '$base/dashboard';
}

String crossPlatformDialogTitle(String provider) {
  if (isWebBillingProvider(provider)) return 'Manage subscription on the web';
  if (isAppStoreBillingProvider(provider)) {
    return 'Manage subscription in the App Store';
  }
  if (isPlayStoreBillingProvider(provider)) {
    return 'Manage subscription in Google Play';
  }
  return 'Manage subscription';
}
