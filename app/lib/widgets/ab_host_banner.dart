import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_inline_banner.dart';
import '../launcher/host_controller.dart';
import '../providers/control_plane.dart' show hostControllerProvider;
import '../providers/host_status.dart';
import '../util/ab_log.dart';
import '../utils/platform_utils.dart';

/// Inline notice for the LOCAL bridge host dying under us. Renders nothing
/// while the host is healthy (or intentionally stopped), so the healthy path
/// costs no layout.
///
/// Without this the desktop user has no signal at all: recovery is lazy (the
/// next `ensureHost`), so a crashed bridge looks like an app that has simply
/// stopped responding.
class AbHostBanner extends ConsumerStatefulWidget {
  const AbHostBanner({super.key});

  @override
  ConsumerState<AbHostBanner> createState() => _AbHostBannerState();
}

class _AbHostBannerState extends ConsumerState<AbHostBanner> {
  bool _retrying = false;

  Future<void> _retry() async {
    setState(() => _retrying = true);
    try {
      await ref.read(hostControllerProvider).retryNow();
    } catch (e) {
      // The failed status the controller publishes carries the reason; nothing
      // to add here.
      AbLog.warn('AbHostBanner', 'manual retry failed', fields: {'error': '$e'});
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Mobile never spawns a local host — the phase would sit at idle forever.
    if (isMobilePlatform) return const SizedBox.shrink();

    final status = ref.watch(hostStatusProvider).value;
    final phase = status?.phase;
    // Stay mounted while a manual retry is in flight: retryNow() moves the
    // phase to `starting` within a microtask, and unmounting on that would
    // hide the banner for the whole (up to 30s) spawn window — reading as
    // "the button did nothing".
    final visible = _retrying ||
        phase == HostPhase.restarting ||
        phase == HostPhase.failed;
    if (!visible) return const SizedBox.shrink();

    final failed = phase == HostPhase.failed && !_retrying;
    final colors = context.antgrid;
    final text = _retrying
        ? 'Restarting the local bridge…'
        : failed
            ? (status?.detail ?? 'The local bridge stopped.')
            : 'Local bridge stopped — restarting'
                '${(status?.attempt ?? 0) > 0 ? ' (attempt ${status!.attempt})' : ''}…';

    return AbInlineBanner(
      text: text,
      color: failed ? colors.error : colors.warning,
      trailing: (failed || _retrying)
          ? AbButton(
              label: _retrying ? 'Restarting…' : 'Restart bridge',
              compact: true,
              onTap: _retrying ? null : _retry,
            )
          : null,
    );
  }
}
