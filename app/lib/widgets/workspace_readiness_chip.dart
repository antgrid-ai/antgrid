import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_status_tone.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_status_dot.dart';
import '../project/checkout_readiness.dart';
import '../providers/checkout_readiness.dart';
import 'ab_status_helpers.dart';

/// Always-visible counterpart to the boot screen's phases and the pane-level
/// hydration strip, which are both transient: without this, "is the checkout
/// usable" is answered only on a surface the user has already dismissed.
///
/// Reports [checkoutReadinessProvider] via [readinessDisplayInfo]. Renders
/// nothing at [CheckoutReadiness.ready] — this is an exception reporter, not
/// a permanent badge.
///
/// Belongs inline in a toolbar row, never overlaid on the agent panel: the
/// panel's first child is the agent bar, and a chip floated over its trailing
/// edge both hides and swallows taps on the session controls — the menu, the
/// mode switch and, on a phone, the only route to the overflow — exactly while
/// the checkout is not ready and the user most needs them. It carries its own
/// leading gap so a row that renders it need emit no separator of its own.
class WorkspaceReadinessChip extends ConsumerWidget {
  const WorkspaceReadinessChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final readiness = ref.watch(checkoutReadinessProvider);
    if (readiness == CheckoutReadiness.ready) {
      return const SizedBox.shrink();
    }

    final (tone, label) = readinessDisplayInfo(readiness);
    final color = tone.color(context);

    return Container(
      height: AbTokens.iconButtonBox,
      margin: const EdgeInsets.only(left: AbTokens.space6),
      padding: const EdgeInsets.symmetric(horizontal: AbTokens.space6),
      decoration: BoxDecoration(
        color: color.withAlpha(26),
        borderRadius: AbTokens.borderRadius3,
        border: Border.all(color: color.withAlpha(90)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AbStatusDot(tone: tone, size: AbDotSize.sm),
          const SizedBox(width: AbTokens.space6),
          Text(
            label,
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontXs,
              fontWeight: FontWeight.w500,
              color: color,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}
