import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';

import '../design/ab_carbon.dart';

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

  /// `RAM 18.2 / 32.0 GB`, from the host's latest `machine:stats`; null
  /// until a bridge new enough to send one has.
  final String? ram;

  /// Host CPU busy share, 0-100, from the same `machine:stats` as [ram].
  final int? cpuPercent;

  /// Called when the pointer enters the chip: the host reports its load only
  /// on request, and the tooltip it feeds appears on this same hover.
  final VoidCallback? onRequestStats;

  const RemoteHostChip({
    super.key,
    required this.hostMachineName,
    required this.platform,
    this.ram,
    this.cpuPercent,
    this.onRequestStats,
  });

  /// Unstated reads as desktop, not unknown: every machine that can host an
  /// agent is a desktop-class one, so the server glyph is reserved for a
  /// platform the inventory named and this build does not recognise.
  CarbonIcons get _icon => switch (platform) {
    'ios' || 'android' => CarbonIcons.mobile,
    'macos' || 'linux' || 'windows' || null => CarbonIcons.laptop,
    _ => CarbonIcons.serverDns,
  };

  @override
  Widget build(BuildContext context) {
    final label = hostMachineName.isEmpty ? 'Remote host' : hostMachineName;
    return AbCarbonScope(
      child: MouseRegion(
        onEnter: (_) => onRequestStats?.call(),
        child: CarbonTooltip(
          // The title bar is crowded enough; the figure is a hover-only detail.
          message: [
            'Running on $label',
            ?(cpuPercent == null ? null : 'CPU $cpuPercent%'),
            ?ram,
          ].join('\n'),
          child: CarbonTag(
            icon: CarbonIcon(_icon),
            label: label,
            color: CarbonTagColor.outline,
          ),
        ),
      ),
    );
  }
}
