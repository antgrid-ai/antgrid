import 'package:flutter/material.dart' show Dialog, Navigator, showDialog;
import 'package:flutter/widgets.dart';

import '../design/ab_colors.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_dialog.dart';
import '../design/widgets/ab_kbd.dart';
import 'app_shortcuts.dart';

/// Every shortcut on this platform, as a dialog over whatever is on screen.
Future<void> showShortcutsSheet(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const ShortcutsSheet());

class ShortcutsSheet extends StatelessWidget {
  const ShortcutsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(AbTokens.space16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              abDialogTitle(
                'Keyboard shortcuts',
                onClose: () => Navigator.of(context).pop(),
              ),
              const SizedBox(height: AbTokens.space12),
              const Flexible(
                child: SingleChildScrollView(child: ShortcutList()),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Every shortcut on this platform, grouped — rendered from
/// [appShortcutChords] so it can never list a key that does nothing. Shared by
/// [ShortcutsSheet] and the Keyboard shortcuts settings section, so the two can
/// never disagree.
///
/// Does not scroll itself: the dialog wraps it in a scroll view, and the
/// settings screen is already one.
class ShortcutList extends StatelessWidget {
  const ShortcutList({super.key, this.query = ''});

  /// Keeps only commands whose label contains this, ignoring case. Groups left
  /// empty by it are dropped rather than shown as bare headers.
  final String query;

  @override
  Widget build(BuildContext context) {
    final apple = isApplePlatform();
    final chords = appShortcutChords();
    final c = context.antgrid;
    final needle = query.trim().toLowerCase();
    bool shown(AppCommand command) =>
        (chords[command]?.isNotEmpty ?? false) &&
        (needle.isEmpty || command.label.toLowerCase().contains(needle));

    final groups = [
      for (final group in AppCommandGroup.values)
        (
          group: group,
          commands: [
            for (final command in AppCommand.values)
              if (command.group == group && shown(command)) command,
          ],
        ),
    ].where((g) => g.commands.isNotEmpty);

    if (groups.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AbTokens.space12),
        child: Text(
          'No shortcut matches "${query.trim()}".',
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontSm,
            color: c.textMuted,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final g in groups) ...[
          Padding(
            padding: const EdgeInsets.only(
              top: AbTokens.space12,
              bottom: AbTokens.space4,
            ),
            child: Text(
              g.group.label.toUpperCase(),
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: c.textMuted,
                letterSpacing: 0.6,
              ),
            ),
          ),
          for (final command in g.commands)
            _ShortcutRow(
              label: command.label,
              chords: chords[command]!,
              apple: apple,
              focusedOnly: chords[command]!.every(
                (chord) => chord.reach == ChordReach.local,
              ),
            ),
        ],
      ],
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({
    required this.label,
    required this.chords,
    required this.apple,
    required this.focusedOnly,
  });

  final String label;
  final List<KeyChord> chords;
  final bool apple;

  /// Bound only inside the area that owns it (a file, a panel, a dialog), so
  /// pressing it elsewhere does nothing — said on the row so that is not
  /// mistaken for a broken key.
  final bool focusedOnly;

  /// Below this the keys drop under the label: a key group is a fixed-width
  /// row of caps (Ctrl+Shift+Enter is four), and sharing a phone-width row
  /// with the label squeezes it past what it can shrink to.
  static const double _stackBelow = 420;

  @override
  Widget build(BuildContext context) {
    final c = context.antgrid;
    final text = Text.rich(
      TextSpan(
        text: label,
        children: [
          if (focusedOnly)
            TextSpan(
              text: '  when focused',
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXs,
                color: c.textMuted,
              ),
            ),
        ],
      ),
      style: AbTokens.sansStyle(
        fontSize: AbTokens.fontSm,
        color: c.textPrimary,
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AbTokens.space4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stacked = constraints.maxWidth < _stackBelow;
          final keys = Wrap(
            alignment: stacked ? WrapAlignment.start : WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: AbTokens.space6,
            runSpacing: AbTokens.space4,
            children: [
              for (var i = 0; i < chords.length; i++) ...[
                if (i > 0)
                  Text(
                    'or',
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontXs,
                      color: c.textMuted,
                    ),
                  ),
                AbKbdGroup(chords[i].keyCaps(apple: apple)),
              ],
            ],
          );
          if (stacked) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                text,
                const SizedBox(height: AbTokens.space4),
                keys,
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: text),
              const SizedBox(width: AbTokens.space12),
              keys,
            ],
          );
        },
      ),
    );
  }
}
