import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_chip.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_tap_target.dart';
import '../providers/recent_ports.dart';
import '../storage/recent_ports_store.dart';

/// Quick-pick row of ports previously opened for [projectId] — the only
/// manual-entry affordance left in the preview empty state now that its top
/// address bar (see `PreviewScreen`) is where typing a port and hitting
/// Enter actually happens; there is no separate text field, scheme toggle,
/// or dialog duplicating that job here. Renders nothing once there are no
/// remembered ports for the project.
class RecentPortsRow extends ConsumerWidget {
  const RecentPortsRow({
    super.key,
    required this.projectId,
    required this.onSelected,
  });

  final String projectId;
  final void Function(int port, String scheme) onSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = ref.watch(recentPortsProvider(projectId));
    if (recent.isEmpty) return const SizedBox.shrink();
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: AbTokens.space6,
      runSpacing: AbTokens.space6,
      children: [
        for (final entry in recent)
          _RecentPortPill(
            entry: entry,
            onTap: () {
              // Bumps it back to the front of the MRU list, same as opening
              // it fresh via the address bar would.
              ref
                  .read(recentPortsProvider(projectId).notifier)
                  .add(entry.port, entry.scheme);
              onSelected(entry.port, entry.scheme);
            },
            onRemove: () => ref
                .read(recentPortsProvider(projectId).notifier)
                .remove(entry.port),
          ),
      ],
    );
  }
}

class _RecentPortPill extends StatelessWidget {
  final RecentPort entry;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _RecentPortPill({
    required this.entry,
    required this.onTap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    // Show the scheme only when it's https — http is the common default, so
    // tagging every pill would be noise.
    final label = entry.scheme == 'https'
        ? 'https://${entry.port}'
        : '${entry.port}';
    // The chip sets the row height; the forget button rides alongside it.
    return AbCompactTapTargets(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AbChip.toggle(
            label: label,
            selected: false,
            size: AbChipSize.md,
            onTap: onTap,
          ),
          AbIconButton(
            icon: AbIcons.close,
            tone: AbIconButtonTone.muted,
            tooltip: 'Forget port ${entry.port}',
            onTap: onRemove,
          ),
        ],
      ),
    );
  }
}
