import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../billing/billing_api.dart';
import '../models/subscription_info.dart';
import 'auth.dart';

final subscriptionServiceProvider = Provider<BillingApi>((ref) {
  final auth = ref.watch(authServiceProvider);
  return BillingApi(
    licenseApiUrl: ref.watch(licenseApiUrlProvider),
    cookieProvider: () => auth.storage.readCookie(),
  );
});

final subscriptionProvider = FutureProvider<SubscriptionInfo?>((ref) async {
  final user = await ref.watch(currentUserProvider.future);
  if (user == null) return null;
  return ref.read(subscriptionServiceProvider).fetchSubscriptionInfo();
});

final pricingCatalogProvider = FutureProvider<PricingCatalog?>((ref) async {
  final user = await ref.watch(currentUserProvider.future);
  if (user == null) return null;
  final info = await ref.watch(subscriptionProvider.future);
  final api = ref.read(subscriptionServiceProvider);
  final catalog = await api.fetchPricingCatalog(info: info);
  if (catalog == null) return null;
  return catalog.copyWithCurrentPlan(info?.planSlug);
});

/// Prefetch subscription + pricing after sign-in so pricing opens warm.
/// [subscriptionProvider] / [pricingCatalogProvider] already no-op when signed out.
void prefetchSubscriptionCache(dynamic ref) {
  unawaited(ref.read(subscriptionProvider.future));
  unawaited(ref.read(pricingCatalogProvider.future));
}
