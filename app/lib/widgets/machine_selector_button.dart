import 'package:flutter/widgets.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_status_tone.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_menu.dart';
import '../design/widgets/ab_status_dot.dart';
import '../util/detached.dart';

/// Header button that names the machine a surface is showing and opens a menu
/// to switch. Provider-free so Scheduler and Memory share it: callers own the
/// demo guard, the same-id no-op and their own `mounted` check.
class MachineSelectorButton extends StatelessWidget {
  const MachineSelectorButton({
    super.key,
    required this.machines,
    required this.currentId,
    required this.name,
    required this.connected,
    required this.wide,
    required this.onPicked,
  });

  final Map<String, String> machines;
  final String currentId;
  final String name;
  final bool connected;
  final bool wide;
  final ValueChanged<String> onPicked;

  void _open(BuildContext anchor) => detached('MachineSelector', 'menu failed', () async {
    final rect = abMenuAnchorRect(anchor);
    if (rect == null) return;
    final picked = await showAbMenu<String>(
      context: anchor,
      anchorRect: rect,
      entries: [
        for (final entry in machines.entries)
          AbMenuItem(
            label: entry.value,
            value: entry.key,
            icon: entry.key == currentId ? AbIcons.check : null,
          ),
      ],
    );
    if (picked != null && anchor.mounted) onPicked(picked);
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: AbTokens.space24 * (wide ? 10 : 6)),
      child: Builder(
        builder: (anchor) => Semantics(
          label: 'Machine: $name, change',
          button: true,
          excludeSemantics: true,
          onTap: () => _open(anchor),
          child: AbButton(
            label: name,
            wrapLabel: true,
            maxLines: 1,
            leading: AbStatusDot(
              tone: connected ? AbStatusTone.success : AbStatusTone.muted,
            ),
            trailing: AbIcon(
              AbIcons.chevronDown,
              size: AbTokens.fontSm,
              color: context.antgrid.textMuted,
            ),
            onTap: () => _open(anchor),
          ),
        ),
      ),
    );
  }
}
