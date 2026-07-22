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
class RemoteHostChip extends StatelessWidget {
  final String hostMachineName;
  final String platform;

  const RemoteHostChip({
    super.key,
    required this.hostMachineName,
    required this.platform,
  });

  String get _iconName {
    switch (platform) {
      case 'macos':
      case 'linux':
      case 'windows':
        return AbIcons.deviceDesktop;
      case 'ios':
      case 'android':
        return AbIcons.deviceMobile;
      default:
        return AbIcons.server;
    }
  }

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
              style: AbTokens.monoStyle(fontSize: AbTokens.fontXs, color: antgrid.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
