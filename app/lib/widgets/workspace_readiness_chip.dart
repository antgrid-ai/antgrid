import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_carbon.dart';
import '../design/ab_status_tone.dart';
import '../project/checkout_readiness.dart';
import '../providers/checkout_readiness.dart';
import 'ab_status_helpers.dart';
import 'carbon_status_dot.dart';

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

    return AbCarbonScope(
      child: Padding(
        padding: const EdgeInsetsDirectional.only(
          start: CarbonSpacing.spacing03,
        ),
        // Medium, not small: a small tag does not draw its leading glyph.
        child: CarbonTag(
          label: label,
          color: _tagColor(tone),
          icon: _ToneDot(tone: tone),
        ),
      ),
    );
  }
}

CarbonTagColor _tagColor(AbStatusTone tone) => switch (tone) {
  AbStatusTone.danger => CarbonTagColor.red,
  AbStatusTone.success => CarbonTagColor.green,
  AbStatusTone.info => CarbonTagColor.blue,
  AbStatusTone.warning => CarbonTagColor.warmGray,
  _ => CarbonTagColor.gray,
};

/// The tag's glyph. Drawn in the tone's support colour because a tag's own
/// palette has no way to carry one.
class _ToneDot extends StatelessWidget {
  const _ToneDot({required this.tone});

  final AbStatusTone tone;

  @override
  Widget build(BuildContext context) {
    final c = CarbonTheme.of(context).colors;
    final color = switch (tone) {
      AbStatusTone.danger => c.supportError,
      AbStatusTone.success => c.supportSuccess,
      AbStatusTone.info => c.supportInfo,
      AbStatusTone.warning => c.supportWarning,
      _ => c.iconDisabled,
    };
    return CarbonStatusDot(key: const Key('readiness-dot'), color: color);
  }
}
