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

    test(
      'retired pro_lifetime UUID resolves to the paid default, not a slug',
      () {
        final info = SubscriptionInfo.fromMeJson({
          'tier': 'pro',
          'subscription': {
            'plan_id': '00000000-0000-4000-8000-000000000003',
            'status': 'active',
          },
        });
        expect(info.planSlug, 'pro_yearly');
      },
    );

    test('resolves pro_yearly when current_period_end is null', () {
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

    test('maps the enterprise plan_id UUID', () {
      final info = SubscriptionInfo.fromMeJson({
        'tier': 'enterprise',
        'subscription': {
          'plan_id': '00000000-0000-4000-8000-000000000005',
          'status': 'active',
          'provider': 'manual',
        },
      });
      expect(info.planSlug, 'enterprise');
    });

    test('an enterprise subscription never resolves to a self-serve slug', () {
      // A contract whose plan_id this build cannot name still must not be
      // reported as the plan a card buys.
      final info = SubscriptionInfo.fromMeJson({
        'tier': 'enterprise',
        'subscription': {'status': 'active', 'provider': 'manual'},
      });
      expect(info.planSlug, 'enterprise');
      expect(info.isPro, isTrue);
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

  group('SubscriptionInfo.fromMeJson role and seats', () {
    // The `/subscriptions/me` body as web sends it, seat fields included.
    Map<String, dynamic> meJson({
      Object? role = 'owner',
      Object? seats = 5,
      Object? seatsUsed = 2,
    }) => {
      'account_id': 'acct-1',
      'tier': 'pro',
      'promotional': false,
      'role': ?role,
      'seats': ?seats,
      'seats_used': ?seatsUsed,
      'subscription': {
        'plan_id': '00000000-0000-4000-8000-000000000002',
        'status': 'active',
        'provider': 'paddle',
        'seats': ?seats,
      },
    };

    test('parses role, seats and seats_used', () {
      final info = SubscriptionInfo.fromMeJson(meJson());
      expect(info.role, 'owner');
      expect(info.seats, 5);
      expect(info.seatsUsed, 2);
    });

    test('reads a member role verbatim', () {
      final info = SubscriptionInfo.fromMeJson(meJson(role: 'member'));
      expect(info.role, 'member');
    });

    test('falls back to nested subscription.seats', () {
      final info = SubscriptionInfo.fromMeJson({
        'tier': 'pro',
        'subscription': {
          'plan_id': '00000000-0000-4000-8000-000000000002',
          'status': 'active',
          'seats': 3,
        },
      });
      expect(info.seats, 3);
    });

    test('reads a seat count delivered as a JSON double', () {
      final info = SubscriptionInfo.fromMeJson(
        meJson(seats: 4.0, seatsUsed: 1.0),
      );
      expect(info.seats, 4);
      expect(info.seatsUsed, 1);
    });

    test(
      'an older server omitting all three parses, leaving the rest intact',
      () {
        final info = SubscriptionInfo.fromMeJson(
          meJson(role: null, seats: null, seatsUsed: null),
        );
        // Unreported, not zero and not an assumed role — a server that never
        // sends `role` must not make every user look like an owner.
        expect(info.role, isNull);
        expect(info.seats, isNull);
        expect(info.seatsUsed, isNull);
        expect(info.tier, 'pro');
        expect(info.accountId, 'acct-1');
        expect(info.provider, 'paddle');
        expect(info.planSlug, 'pro_yearly');
        expect(info.promotional, isFalse);
        expect(info.isPro, isTrue);
      },
    );

    test('an unrecognized role is carried, not rejected', () {
      final info = SubscriptionInfo.fromMeJson(meJson(role: 'billing_admin'));
      expect(info.role, 'billing_admin');
      expect(info.seats, 5);
    });

    test('a wrongly-typed role or seat count degrades to null', () {
      final info = SubscriptionInfo.fromMeJson(
        meJson(role: 7, seats: 'many', seatsUsed: true),
      );
      expect(info.role, isNull);
      expect(info.seats, isNull);
      expect(info.seatsUsed, isNull);
      expect(info.tier, 'pro');
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
