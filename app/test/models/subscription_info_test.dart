import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/subscription_info.dart';

void main() {
  group('SubscriptionInfo.fromMeJson planSlug', () {
    test('maps pro_yearly plan_id UUID', () {
      final info = SubscriptionInfo.fromMeJson({
        'tier': 'pro',
        'subscription': {
          'plan_id': '00000000-0000-4000-8000-000000000002',
          'status': 'active',
          'provider': 'paddle',
        },
      });
      expect(info.planSlug, 'pro_yearly');
    });

    test('maps pro_lifetime plan_id UUID', () {
      final info = SubscriptionInfo.fromMeJson({
        'tier': 'pro',
        'subscription': {
          'plan_id': '00000000-0000-4000-8000-000000000003',
          'status': 'active',
        },
      });
      expect(info.planSlug, 'pro_lifetime');
    });

    test('does not infer lifetime when current_period_end is null', () {
      final info = SubscriptionInfo.fromMeJson({
        'tier': 'pro',
        'subscription': {
          'plan_id': '00000000-0000-4000-8000-000000000002',
          'status': 'active',
          'current_period_end': null,
        },
      });
      expect(info.planSlug, 'pro_yearly');
    });

    test('detects trial from plan_id UUID', () {
      final info = SubscriptionInfo.fromMeJson({
        'tier': 'trial',
        'subscription': {
          'plan_id': '00000000-0000-4000-8000-000000000004',
          'status': 'active',
        },
      });
      expect(info.planSlug, 'trial');
    });

    test('detects trial from trialing status when plan_id missing', () {
      final info = SubscriptionInfo.fromMeJson({
        'tier': 'trial',
        'subscription': {'status': 'trialing'},
      });
      expect(info.planSlug, 'trial');
    });

    test('returns null planSlug for free tier', () {
      final info = SubscriptionInfo.fromMeJson({
        'tier': 'free',
        'subscription': {
          'plan_id': '00000000-0000-4000-8000-000000000001',
          'status': 'active',
        },
      });
      expect(info.planSlug, isNull);
      expect(info.isPro, isFalse);
    });
  });

  group('SubscriptionInfo.fromMeJson promotional', () {
    test('reads top-level promotional flag', () {
      final info = SubscriptionInfo.fromMeJson({
        'tier': 'pro',
        'promotional': true,
        'subscription': {
          'plan_id': '00000000-0000-4000-8000-000000000002',
          'status': 'active',
        },
      });
      expect(info.promotional, isTrue);
    });

    test('falls back to nested subscription.promotional', () {
      final info = SubscriptionInfo.fromMeJson({
        'tier': 'pro',
        'subscription': {
          'plan_id': '00000000-0000-4000-8000-000000000002',
          'status': 'active',
          'promotional': true,
        },
      });
      expect(info.promotional, isTrue);
    });

    test('defaults to false when absent', () {
      final info = SubscriptionInfo.fromMeJson({
        'tier': 'pro',
        'subscription': {
          'plan_id': '00000000-0000-4000-8000-000000000002',
          'status': 'active',
        },
      });
      expect(info.promotional, isFalse);
    });
  });

  group('requiresCrossPlatformBillingDialog', () {
    SubscriptionInfo pro({required String provider}) => SubscriptionInfo(
      tier: 'pro',
      provider: provider,
      planSlug: 'pro_yearly',
    );

    test('returns false when provider is null', () {
      expect(
        requiresCrossPlatformBillingDialog(
          SubscriptionInfo(tier: 'pro', planSlug: 'pro_yearly'),
          null,
          onIos: true,
          onAndroid: false,
        ),
        isFalse,
      );
    });

    test('returns false for web-billed subscription on mobile', () {
      expect(
        requiresCrossPlatformBillingDialog(
          pro(provider: 'paddle'),
          null,
          onIos: false,
          onAndroid: true,
        ),
        isFalse,
      );
    });

    test('returns true for App Store subscription on Android', () {
      expect(
        requiresCrossPlatformBillingDialog(
          pro(provider: 'app_store'),
          null,
          onIos: false,
          onAndroid: true,
        ),
        isTrue,
      );
    });

    test('returns false for App Store subscription on iOS', () {
      expect(
        requiresCrossPlatformBillingDialog(
          pro(provider: 'app_store'),
          null,
          onIos: true,
          onAndroid: false,
        ),
        isFalse,
      );
    });

    test('returns true for Play Store subscription on iOS', () {
      expect(
        requiresCrossPlatformBillingDialog(
          pro(provider: 'play_store'),
          null,
          onIos: true,
          onAndroid: false,
        ),
        isTrue,
      );
    });

    test('returns false for Play Store subscription on Android', () {
      expect(
        requiresCrossPlatformBillingDialog(
          pro(provider: 'play_store'),
          null,
          onIos: false,
          onAndroid: true,
        ),
        isFalse,
      );
    });
  });
}
