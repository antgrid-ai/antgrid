import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Dialog, Navigator, showDialog;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_dialog.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_kbd.dart';
import '../design/widgets/ab_search_field.dart';
import 'app_command_registry.dart';
import 'app_shortcuts.dart';

/// Every shortcut on this platform, as a dialog over whatever is on screen.
Future<void> showShortcutsSheet(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const ShortcutsSheet());

class ShortcutsSheet extends StatefulWidget {
  const ShortcutsSheet({super.key});

  /// From here up the groups split into two columns; a single column of
  /// dozens of rows is a long scroll on a screen with room beside it.
  static const double twoColumnsFrom = 760;

  @override
  State<ShortcutsSheet> createState() => _ShortcutsSheetState();
}

class _ShortcutsSheetState extends State<ShortcutsSheet> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The chord that opened the sheet closes it too. App shortcuts are off
    // while a dialog is up, so without this the key does nothing here.
    return CallbackShortcuts(
      bindings: localShortcutBindings({
        AppCommand.showShortcuts: () => Navigator.of(context).pop(),
      }),
      child: Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920, maxHeight: 680),
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
                const SizedBox(height: AbTokens.space8),
                AbSearchField(
                  controller: _controller,
                  hint: 'Filter by name or key (e.g. "ctrl+k")…',
                  autofocus: true,
                  debounce: null,
                  onChanged: (q) => setState(() => _query = q),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    child: ShortcutList(
                      query: _query,
                      markAvailability: true,
                      twoColumnsFrom: ShortcutsSheet.twoColumnsFrom,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Whether [command] matches [query] — by its label, its group, or its keys'
/// text, so "ctrl+k" finds what Ctrl+K does.
bool shortcutMatches(
  AppCommand command,
  String query, {
  required List<KeyChord> chords,
  required bool apple,
}) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return true;
  if (command.label.toLowerCase().contains(needle)) return true;
  if (command.group.label.toLowerCase().contains(needle)) return true;
  return chords.any(
    (c) => c.label(apple: apple).toLowerCase().contains(needle),
  );
}

/// Every shortcut on a platform, grouped — rendered from [appShortcutChords] so
/// it can never list a key that does nothing. Shared by [ShortcutsSheet] and
/// the Keyboard shortcuts settings page, so the two can never disagree.
///
/// Does not scroll itself: the dialog wraps it in a scroll view, and the
/// settings screen is already one.
class ShortcutList extends ConsumerWidget {
  const ShortcutList({
    super.key,
    this.query = '',
    this.chord,
    this.platform,
    this.markAvailability = false,
    this.twoColumnsFrom,
    this.onEdit,
    this.onReset,
  });

  /// Offers a Change keys button on every rebindable row when set.
  final ValueChanged<AppCommand>? onEdit;

  /// Offers a Back-to-default button on rows the user has rebound when set.
  final ValueChanged<AppCommand>? onReset;

  /// Keeps only commands matching this ([shortcutMatches]). Groups left empty
  /// by it are dropped rather than shown as bare headers.
  final String query;

  /// Keeps only commands bound to this exact chord — the settings page's
  /// "press a shortcut" search.
  final KeyChord? chord;

  /// Whose keys to list; the running platform when null.
  final TargetPlatform? platform;

  /// Dims a command nothing on screen offers right now, so a key that does
  /// nothing here reads as unavailable rather than broken. Only meaningful
  /// over the screen in question — the sheet, not the settings page that
  /// covers it.
  final bool markAvailability;

  /// Width from which the groups are laid out in two columns.
  final double? twoColumnsFrom;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = platform ?? defaultTargetPlatform;
    final apple = isApplePlatform(target);
    final chords = appShortcutChords(target);
    final c = context.antgrid;
    final registry = markAvailability
        ? ref.read(appCommandRegistryProvider)
        : null;
    bool shown(AppCommand command) {
      final bound = chords[command];
      if (bound == null || bound.isEmpty) return false;
      if (chord != null && !bound.contains(chord)) return false;
      return shortcutMatches(command, query, chords: bound, apple: apple);
    }

    final groups = [
      for (final group in AppCommandGroup.values)
        (
          group: group,
          commands: [
            for (final command in AppCommand.values)
              if (command.group == group && shown(command)) command,
          ],
        ),
    ].where((g) => g.commands.isNotEmpty).toList();

    if (groups.isEmpty) {
      final what = chord != null
          ? chord!.label(apple: apple)
          : '"${query.trim()}"';
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AbTokens.space12),
        child: Text(
          'No shortcut matches $what.',
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontSm,
            color: c.textMuted,
          ),
        ),
      );
    }

    Widget group(({AppCommandGroup group, List<AppCommand> commands}) g) =>
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
                range: command.range,
                focusedOnly: chords[command]!.every(
                  (chord) => chord.reach == ChordReach.local,
                ),
                trailing: onEdit == null || !isRebindable(command)
                    ? null
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AbIconButton(
                            icon: AbIcons.edit,
                            tooltip: 'Change keys',
                            onTap: () => onEdit!(command),
                          ),
                          if (onReset != null &&
                              userKeybindings.containsKey(command))
                            AbIconButton(
                              icon: AbIcons.revert,
                              tooltip: 'Back to the default keys',
                              onTap: () => onReset!(command),
                            ),
                        ],
                      ),
                // Only registry-dispatched commands can be asked; a
                // widget-bound one (find in file) is offered by focus alone.
                available:
                    registry == null ||
                    chords[command]!.every(
                      (c) => c.reach == ChordReach.local,
                    ) ||
                    registry.handlerFor(command) != null,
              ),
          ],
        );

    return LayoutBuilder(
      builder: (context, constraints) {
        final split = twoColumnsFrom;
        if (split == null ||
            constraints.maxWidth < split ||
            groups.length < 2) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final g in groups) group(g)],
          );
        }
        // Balanced by row count, groups kept whole and in order.
        final total = groups.fold<int>(0, (n, g) => n + g.commands.length + 1);
        var running = 0;
        var cut = groups.length;
        for (var i = 0; i < groups.length; i++) {
          running += groups[i].commands.length + 1;
          if (running * 2 >= total) {
            cut = i + 1;
            break;
          }
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [for (final g in groups.take(cut)) group(g)],
              ),
            ),
            const SizedBox(width: AbTokens.space24),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [for (final g in groups.skip(cut)) group(g)],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Said beside a chord that the agent's terminal keeps while it has the
/// keyboard; the settings page's intro explains it.
const String kOutsideTerminalNote = 'outside the terminal';

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({
    required this.label,
    required this.chords,
    required this.apple,
    required this.focusedOnly,
    this.range = false,
    this.available = true,
    this.trailing,
  });

  /// Row actions after the keys (the settings page's Change keys).
  final Widget? trailing;

  final String label;
  final List<KeyChord> chords;
  final bool apple;

  /// Shows the first and last of a run of chords (`Ctrl+1 … Ctrl+9`) rather
  /// than all nine.
  final bool range;

  /// Dimmed when false: nothing on screen offers the command right now.
  final bool available;

  /// Bound only inside the area that owns it (a file, a panel, a dialog), so
  /// pressing it elsewhere does nothing — said on the row so that is not
  /// mistaken for a broken key.
  final bool focusedOnly;

  /// Below this the keys drop under the label: a key group is a fixed-width
  /// row of caps (Ctrl+Shift+Enter is four), and sharing a phone-width row
  /// with the label squeezes it past what it can shrink to.
  static const double _stackBelow = 420;

  /// Wider for a row carrying [kOutsideTerminalNote], whose keys are longer
  /// than the label's half of a dialog-width row leaves room for.
  static const double _stackBelowWithNote = 640;

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
    final shownChords = range && chords.length > 2
        ? [chords.first, chords.last]
        : chords;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: AbTokens.space4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final hasNote =
              !focusedOnly &&
              chords.any((chord) => chord.reach == ChordReach.focused);
          final stacked =
              constraints.maxWidth <
              (hasNote ? _stackBelowWithNote : _stackBelow);
          final keys = Wrap(
            alignment: stacked ? WrapAlignment.start : WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: AbTokens.space6,
            runSpacing: AbTokens.space4,
            children: [
              for (var i = 0; i < shownChords.length; i++) ...[
                if (i > 0)
                  Text(
                    range && shownChords.length == 2 ? '…' : 'or',
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontXs,
                      color: c.textMuted,
                    ),
                  ),
                AbKbdGroup(shownChords[i].keyCaps(apple: apple)),
                // A focused chord is the terminal's whenever the agent's
                // terminal has the keyboard, so it is not "anywhere" like its
                // global neighbours on the same row.
                if (!focusedOnly && shownChords[i].reach == ChordReach.focused)
                  Text(
                    kOutsideTerminalNote,
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontXs,
                      color: c.textMuted,
                    ),
                  ),
              ],
            ],
          );
          final actions = trailing;
          if (stacked) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                text,
                const SizedBox(height: AbTokens.space4),
                Row(
                  children: [
                    Expanded(child: keys),
                    ?actions,
                  ],
                ),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: text),
              const SizedBox(width: AbTokens.space12),
              keys,
              if (actions != null) ...[
                const SizedBox(width: AbTokens.space4),
                actions,
              ],
            ],
          );
        },
      ),
    );
    if (available) return row;
    return Opacity(opacity: 0.45, child: row);
  }
}
