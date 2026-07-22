import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_icon_button.dart';
import '../providers/relay_error_banner.dart';

/// Inline relay-error banner. Renders nothing when there is no active
/// [RelayErrorBanner] state — sized to zero so it has no layout impact.
class AbBanner extends ConsumerWidget {
  const AbBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = ref.watch(relayErrorBannerProvider);
    if (b == null) return const SizedBox.shrink();
    return Container(
      color: context.antgrid.bgElevated,
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space12,
        vertical: AbTokens.space8,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${b.code}: ${b.message}',
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: context.antgrid.error,
              ),
            ),
          ),
          AbIconButton(
            icon: AbIcons.close,
            onTap: () =>
                ref.read(relayErrorBannerProvider.notifier).set(null),
          ),
        ],
      ),
    );
  }
}
