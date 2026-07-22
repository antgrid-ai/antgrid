import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/subscription_info.dart';

class BillingApi {
  BillingApi({
    required this.licenseApiUrl,
    required this.cookieProvider,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String licenseApiUrl;
  final Future<String?> Function() cookieProvider;
  final http.Client _http;

  Future<String?> _cookie() => cookieProvider();

  Future<SubscriptionInfo?> fetchSubscriptionInfo() async {
    final cookie = await _cookie();
    if (cookie == null) return null;
    final res = await _http.get(
      Uri.parse('$licenseApiUrl/subscriptions/me'),
      headers: {'cookie': cookie},
    );
    if (res.statusCode != 200) return null;
    return SubscriptionInfo.fromMeJson(
      jsonDecode(res.body) as Map<String, dynamic>,
    );
  }

  Future<PricingCatalog?> fetchPricingCatalog({SubscriptionInfo? info}) async {
    final cookie = await _cookie();
    if (cookie == null) return null;
    final res = await _http.get(
      Uri.parse('$licenseApiUrl/billing/plans'),
      headers: {'cookie': cookie},
    );
    if (res.statusCode != 200) return null;
    return PricingCatalog.fromPlansJson(
      jsonDecode(res.body) as Map<String, dynamic>,
      currentPlanSlug: info?.planSlug,
    );
  }
}
