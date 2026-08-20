import 'package:flutter/widgets.dart';

import '../design/ab_icons.dart';
import '../design/widgets/ab_segmented.dart';

/// Session-mode segmented control ([ CHAT | TERMINAL ]): both options always
/// visible, the selected cell accented. Used by the in-session switch
/// (`session_mode_control.dart`), where the session already exists and the mode
/// is a state to flip rather than a choice to make.
///
/// The create-time picker uses a dropdown instead: there, Terminal is the
/// default for every agent and Chat is alpha, so the two are not equals worth
/// the row of a segmented control.
///
/// A greyed cell is how "this agent can't do chat" gets said here; the
/// dropdown says it with a greyed row.
class ModeSegmented extends StatelessWidget {
  const ModeSegmented({
    super.key,
    required this.keyPrefix,
    required this.mode,
    required this.onChanged,
    this.chatEnabled = true,
    this.chatDisabledReason,
    this.enabled = true,
    this.iconOnly = false,
  });

  /// Prefix for the cell keys (`<prefix>-chip` / `-chat` / `-terminal`) so any
  /// mount point stays separately addressable.
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

  /// Header density: glyphs only, the labels demoted to tooltips. See
  /// [AbSegmented.iconOnly].
  final bool iconOnly;

  @override
  Widget build(BuildContext context) {
    return AbSegmented<String>(
      key: Key('$keyPrefix-chip'),
      iconOnly: iconOnly,
      segments: [
        AbSegment(
          key: Key('$keyPrefix-chat'),
          value: 'chat',
          label: 'Chat',
          icon: AbIcons.comment,
          enabled: enabled && chatEnabled,
          disabledReason: chatEnabled ? null : chatDisabledReason,
        ),
        AbSegment(
          key: Key('$keyPrefix-terminal'),
          value: 'terminal',
          label: 'Terminal',
          icon: AbIcons.terminal,
          enabled: enabled,
        ),
      ],
      selected: mode,
      onSelect: onChanged,
    );
  }
}
