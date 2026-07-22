import 'package:flutter/material.dart';

import '../design/ab_colors.dart';
import '../design/widgets/ab_chip.dart';
import '../services/auth_service.dart';

/// Small status chip rendered in the agent panel header and drawer footer
/// showing the app user's subscription tier:
///   - promotional grant (unpurchased) → amber "FREE", regardless of tier
///   - `tier == 'pro'` (real subscription) → accent "PRO"
///   - else (trial / unknown) → amber tier label, defaulting to "TRIAL"
class AuthStatusPill extends StatelessWidget {
  final CurrentUser? user;
  const AuthStatusPill(this.user, {super.key});

  @override
  Widget build(BuildContext context) {
    if (user == null) return const SizedBox.shrink();
    // TEMP-PROMO: hide the real "PRO" tier while the account only has a
    // temporary, unpurchased grant — grep "TEMP-PROMO" repo-wide for every
    // related spot. Delete this branch (and CurrentUser.promotional) once
    // payment integration ships.
    if (user!.promotional) {
      return AbChip.system(label: 'FREE', color: Colors.amber.shade400);
    }
    final label = user!.tier?.toUpperCase() ?? 'TRIAL';
    final color = user!.tier == 'pro'
        ? context.antgrid.accent
        : Colors.amber.shade400;
    return AbChip.system(label: label, color: color);
  }
}
