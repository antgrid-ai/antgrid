import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../services/auth_service.dart';

/// The tier text the tag shows, so the footer's spoken name matches it.
String tierLabel(CurrentUser user) {
  final tier = user.tier;
  return tier == null || tier.isEmpty
      ? 'Trial'
      : '${tier[0].toUpperCase()}${tier.substring(1)}';
}

/// Small status tag rendered via `AccountFooter` in the drawer, showing the
/// app user's subscription tier:
///   - promotional grant (unpurchased) → nothing, regardless of tier
///   - `tier == 'pro'` (real subscription) → blue "Pro"
///   - else (trial / unknown) → outlined tier label, defaulting to "Trial"
class AuthStatusPill extends StatelessWidget {
  final CurrentUser? user;
  const AuthStatusPill(this.user, {super.key});

  @override
  Widget build(BuildContext context) {
    if (user == null) return const SizedBox.shrink();
    // TEMP-PROMO: grep "TEMP-PROMO" repo-wide for every related spot. Delete
    // this branch (and CurrentUser.promotional) once payment integration
    // ships.
    //
    // No tag at all, because every label is wrong: "Pro" claims a purchase,
    // "Free" names allowances that aren't in force (the grant carries Pro
    // entitlement), and "Beta" got the iOS build rejected under App Store
    // guideline 2.2 as a pre-release app.
    if (user!.promotional) return const SizedBox.shrink();
    final tier = user!.tier;
    return CarbonTag(
      label: tierLabel(user!),
      size: CarbonTheme.of(context).isTouch
          ? CarbonTagSize.medium
          : CarbonTagSize.small,
      color: tier == 'pro' ? CarbonTagColor.blue : CarbonTagColor.outline,
    );
  }
}
