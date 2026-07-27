import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_icons.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_inline_banner.dart';
import '../providers/relay_error_banner.dart';

/// Inline relay-error banner. Renders nothing when there is no active
/// [RelayErrorBanner] state — sized to zero so it has no layout impact.
class AbBanner extends ConsumerWidget {
  const AbBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = ref.watch(relayErrorBannerProvider);
    if (b == null) return const SizedBox.shrink();
    return AbInlineBanner(
      text: '${b.code}: ${b.message}',
      color: context.antgrid.error,
      trailing: AbIconButton(
        icon: AbIcons.close,
        onTap: () => ref.read(relayErrorBannerProvider.notifier).set(null),
      ),
    );
  }
}
