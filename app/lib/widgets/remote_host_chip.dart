import 'package:flutter/material.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_icon.dart';

/// Read-only chip shown in the project header when the agent is running on a
/// remote machine (i.e. `project.isLocalFor(localUuid)` is false).
///
/// Displays the host machine name and a platform-appropriate icon. Degrades
/// gracefully to "Remote host" when [hostMachineName] is empty.
///
/// [platform] is null when nothing has said — the machine is known only from
/// the reconnect list, which caches coordinates and not a platform.
class RemoteHostChip extends StatelessWidget {
  final String hostMachineName;
  final String? platform;

  const RemoteHostChip({
    super.key,
    required this.hostMachineName,
    required this.platform,
  });

  /// Unstated reads as desktop, not unknown: every machine that can host an
  /// agent is a desktop-class one, so the server glyph is reserved for a
  /// platform the inventory named and this build does not recognise.
  String get _iconName => switch (platform) {
    'ios' || 'android' => AbIcons.deviceMobile,
    'macos' || 'linux' || 'windows' || null => AbIcons.deviceDesktop,
    _ => AbIcons.server,
  };

  @override
  Widget build(BuildContext context) {
    final antgrid = context.antgrid;
    final label = hostMachineName.isEmpty ? 'Remote host' : hostMachineName;
    return Tooltip(
      message: 'Running on $label',
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AbTokens.space8,
          vertical: AbTokens.space4,
        ),
        decoration: BoxDecoration(
          borderRadius: AbTokens.borderRadius,
          border: Border.all(color: antgrid.textSecondary),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AbIcon(_iconName, size: 12, color: antgrid.textSecondary),
            const SizedBox(width: AbTokens.space4),
            Text(
              label,
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontXs,
                color: antgrid.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
