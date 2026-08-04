import 'package:flutter/widgets.dart';

import 'ab_tokens.dart';

/// Single source that keeps [AbTokens.activeWeightOffset] in sync with the
/// ambient devicePixelRatio. Insert once, high in the tree. Reads DPR (which it
/// depends on, so it rebuilds when the window moves to another display) and sets
/// the ambient offset before descendants build their text styles.
///
/// The bump is off at present — [AbTokens.lowDprThreshold] is 0, so this always
/// resolves to 0. Kept wired up so re-enabling is one constant, and so the
/// offset is still reset when a window moves between displays.
class AbTextDensity extends StatelessWidget {
  const AbTextDensity({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    AbTokens.activeWeightOffset = dpr < AbTokens.lowDprThreshold ? 1 : 0;
    return child;
  }
}
