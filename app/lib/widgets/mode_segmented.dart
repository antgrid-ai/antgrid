import 'package:flutter/widgets.dart';

import '../design/ab_icons.dart';
import '../design/widgets/ab_segmented.dart';

/// Session-mode segmented control ([ CHAT | TERMINAL ]): both options always
/// visible, the selected cell accented.
///
/// One widget for two surfaces — the New Session composer picks the mode a
/// session starts in, `SessionModeControl` switches an open one — so a user who
/// picked "Chat" at create time meets the same control when switching rather
/// than learning the same concept twice.
class ModeSegmented extends StatelessWidget {
  const ModeSegmented({
    super.key,
    required this.keyPrefix,
    required this.mode,
    required this.onChanged,
    this.chatEnabled = true,
    this.chatDisabledReason,
    this.enabled = true,
    this.showIcons = true,
  });

  /// Prefix for the cell keys (`<prefix>-chip` / `-chat` / `-terminal`) so the
  /// two mount points stay separately addressable.
  final String keyPrefix;

  /// Displayed selection: `'chat'` or `'terminal'`.
  final String mode;

  final ValueChanged<String> onChanged;

  /// Whether Chat is reachable for this agent at all. False greys the Chat cell
  /// and carries [chatDisabledReason]; it never hides the control — a missing
  /// conversation is what hides it, and the two causes must not look alike.
  final bool chatEnabled;

  final String? chatDisabledReason;

  /// False while a switch is in flight: both cells go inert so a second tap
  /// can't queue a second flip. Carries no reason — the user just tapped.
  final bool enabled;

  /// Icons are garnish (labels always render); tight rows drop them first.
  final bool showIcons;

  @override
  Widget build(BuildContext context) {
    return AbSegmented<String>(
      key: Key('$keyPrefix-chip'),
      segments: [
        AbSegment(
          key: Key('$keyPrefix-chat'),
          value: 'chat',
          label: 'Chat',
          icon: showIcons ? AbIcons.comment : null,
          enabled: enabled && chatEnabled,
          disabledReason: chatEnabled ? null : chatDisabledReason,
        ),
        AbSegment(
          key: Key('$keyPrefix-terminal'),
          value: 'terminal',
          label: 'Terminal',
          icon: showIcons ? AbIcons.terminal : null,
          enabled: enabled,
        ),
      ],
      selected: mode,
      onSelect: onChanged,
    );
  }
}
