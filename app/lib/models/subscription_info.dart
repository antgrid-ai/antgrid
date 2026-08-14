class SubscriptionInfo {
  SubscriptionInfo({
    required this.tier,
    this.accountId,
    this.provider,
    this.planSlug,
    this.promotional = false,
    this.role,
    this.seats,
    this.seatsUsed,
  });

  final String tier;
  final String? accountId;
  final String? provider;
  final String? planSlug;

  /// True when [tier] is a temporary, unpurchased promo grant (in-app
  /// purchases aren't live yet) rather than a real subscription.
  final bool promotional;

  /// The signed-in user's capacity on the account they bill against —
  /// `owner` or `member`.
  ///
  /// Null when the server predates the field or could not read the stored
  /// value. A role we don't know must never read as ownership, so this stays
  /// unset rather than defaulting: a server that never sends it would
  /// otherwise make every member look like an owner.
  final String? role;

  /// Seats purchased on the billing account, and how many are occupied.
  ///
  /// Null when the server predates them — never 0, which a caller would read
  /// as a real count of none.
  final int? seats;
  final int? seatsUsed;

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
      role: _asString(json['role']),
      // The server mirrors `seats` onto the subscription object as well as the
      // top level; either shape parses so neither placement is load-bearing.
      seats: _asCount(json['seats'] ?? sub?['seats']),
      seatsUsed: _asCount(json['seats_used'] ?? sub?['seats_used']),
    );
  }
}

/// Role and seat counts are descriptive extras, while [SubscriptionInfo.tier]
/// off the same payload decides what the app may do — so an unexpected value
/// in one of them degrades to "not reported" instead of failing the whole
/// parse and leaving the app with no subscription at all.
String? _asString(Object? raw) => raw is String ? raw : null;

/// JSON delivers a count as `1` or `1.0` depending on the encoder, so it goes
/// through `num` rather than casting straight to `int`.
int? _asCount(Object? raw) => raw is num ? raw.toInt() : null;

/// Stable plan UUIDs from web `PLAN_UUID` — `/subscriptions/me` returns these as
/// `subscription.plan_id`, not slugs.
const _planIdToSlug = {
  '00000000-0000-4000-8000-000000000001': 'free',
  '00000000-0000-4000-8000-000000000002': 'pro_yearly',
  '00000000-0000-4000-8000-000000000004': 'trial',
  '00000000-0000-4000-8000-000000000005': 'enterprise',
};

const _knownPlanSlugs = {'free', 'trial', 'pro_yearly', 'enterprise'};

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

  // A tier that names a plan slug outright answers for itself. Enterprise is
  // the case that needs it: sold by contract, it must never resolve to a slug a
  // card can buy, which is what the paid default below would hand it.
  if (_knownPlanSlugs.contains(tier)) return tier;

  // Paid tier without a resolvable plan_id — yearly is the only plan a card can
  // buy, so it is the safe guess for one we could not name.
  if (status == 'active' || tier == 'pro') return 'pro_yearly';
  return null;
}

class PricingPlan {
  PricingPlan({
    required this.slug,
    required this.label,
    required this.workerLimit,
    this.maxSeats,
    this.priceDisplay,
    required this.recurring,
    required this.trial,
  });

  final String slug;
  final String label;

  /// How many machines the plan may run an agent on. Counted per person, so a
  /// team does not pool them.
  final int workerLimit;

  /// Seats the plan may be bought for, or null for a plan whose seat count is
  /// a contract term (Enterprise) — and null too on a server that predates the
  /// field, which is why nothing may read it as a real ceiling of zero.
  final int? maxSeats;
  final String? priceDisplay;
  final bool recurring;
  final bool trial;

  factory PricingPlan.fromJson(Map<String, dynamic> json) {
    // `session_limit` is the retired name for this field. The server mirrors
    // both for one release so an app built either side of the rename parses;
    // drop the fallback once no deployed relay/web emits the old key.
    final limit = json['worker_limit'] ?? json['session_limit'];
    return PricingPlan(
      slug: json['slug'] as String,
      label: json['label'] as String,
      workerLimit: (limit as num).toInt(),
      maxSeats: _asCount(json['max_seats']),
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
