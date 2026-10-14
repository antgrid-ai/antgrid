import 'package:flutter/material.dart';

import '../design/ab_colors.dart';
import '../design/widgets/ab_chip.dart';
import '../services/auth_service.dart';

/// Small status chip rendered via `AccountFooter` in the drawer, showing the
/// app user's subscription tier:
///   - promotional grant (unpurchased) → nothing, regardless of tier
///   - `tier == 'pro'` (real subscription) → accent "PRO"
///   - else (trial / unknown) → amber tier label, defaulting to "TRIAL"
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
    // No chip at all, because every label is wrong: "PRO" claims a purchase,
    // "FREE" names allowances that aren't in force (the grant carries Pro
    // entitlement), and "BETA" got the iOS build rejected under App Store
    // guideline 2.2 as a pre-release app.
    if (user!.promotional) return const SizedBox.shrink();
    final label = user!.tier?.toUpperCase() ?? 'TRIAL';
    final color = user!.tier == 'pro'
        ? context.antgrid.accent
        : Colors.amber.shade400;
    return AbChip.system(label: label, color: color);
  }
}
