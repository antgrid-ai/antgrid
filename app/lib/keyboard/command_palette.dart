import 'package:flutter/material.dart' show Dialog, Navigator, showDialog;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_kbd.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_search_field.dart';
import '../design/widgets/ab_separator.dart';
import 'app_command_registry.dart';
import 'app_shortcuts.dart';

/// Opens the command palette over whatever is on screen.
///
/// The commands are the ones something offers RIGHT NOW, read once at open:
/// the palette is a dialog, and app shortcuts are off under a dialog, so
/// nothing can change underneath it while it is up.
Future<void> showCommandPalette(BuildContext context, WidgetRef ref) {
  final registry = ref.read(appCommandRegistryProvider);
  final commands = [
    for (final command in AppCommand.values)
      if (command != AppCommand.commandPalette &&
          !command.range &&
          registry.handlerFor(command) != null)
        command,
  ];
  return showDialog<void>(
    context: context,
    builder: (_) => CommandPalette(
      commands: commands,
      // After the pop: a handler that opens its own dialog or moves focus
      // must not do it under the palette's route.
      onRun: (command) => WidgetsBinding.instance.addPostFrameCallback(
        (_) => registry.run(command),
      ),
    ),
  );
}

/// Ranks [command] against [query]: lower is better, null is no match.
///
/// A substring of the label or the group wins over a scattered match, and the
/// shortcut's own text matches too, so "ctrl+k" finds what Ctrl+K does.
int? commandMatchScore(AppCommand command, String query, {bool? apple}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return 0;
  final label = command.label.toLowerCase();
  if (label.startsWith(q)) return 0;
  if (label.contains(q)) return 1;
  if (command.group.label.toLowerCase().contains(q)) return 2;
  final keys = (appShortcutChords()[command] ?? const <KeyChord>[]).map(
    (c) => c.label(apple: apple ?? isApplePlatform()).toLowerCase(),
  );
  if (keys.any((k) => k.contains(q))) return 2;
  var i = 0;
  for (final ch in label.split('')) {
    if (i < q.length && ch == q[i]) i++;
  }
  return i == q.length ? 3 : null;
}

class CommandPalette extends StatefulWidget {
  const CommandPalette({
    super.key,
    required this.commands,
    required this.onRun,
  });

  final List<AppCommand> commands;
  final ValueChanged<AppCommand> onRun;

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  final _controller = TextEditingController();
  final _rowKeys = <AppCommand, GlobalKey>{};
  String _query = '';
  int _selected = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<AppCommand> get _matches {
    final scored =
        [
          for (final (i, command) in widget.commands.indexed)
            if (commandMatchScore(command, _query) case final score?)
              (command: command, score: score, order: i),
        ]..sort((a, b) {
          final byScore = a.score.compareTo(b.score);
          return byScore != 0 ? byScore : a.order.compareTo(b.order);
        });
    return [for (final s in scored) s.command];
  }

  void _move(int delta, int count) {
    if (count == 0) return;
    setState(() => _selected = (_selected + delta) % count);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final matches = _matches;
      if (_selected >= matches.length) return;
      final ctx = _rowKeys[matches[_selected]]?.currentContext;
      if (ctx != null) Scrollable.ensureVisible(ctx, alignment: 0.5);
    });
  }

  void _run(AppCommand command) {
    Navigator.of(context).pop();
    widget.onRun(command);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.antgrid;
    final apple = isApplePlatform();
    final matches = _matches;
    if (_selected >= matches.length) _selected = 0;
    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.fromLTRB(
        AbTokens.space16,
        AbTokens.space24 * 2,
        AbTokens.space16,
        AbTokens.space16,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(AbTokens.space8),
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                      _move(1, matches.length),
                  const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                      _move(-1, matches.length),
                },
                child: AbSearchField(
                  controller: _controller,
                  hint: 'Run a command…',
                  autofocus: true,
                  debounce: null,
                  onChanged: (q) => setState(() {
                    _query = q;
                    _selected = 0;
                  }),
                  onSubmitted: (_) {
                    if (matches.isNotEmpty) _run(matches[_selected]);
                  },
                ),
              ),
            ),
            const AbSeparator.horizontal(),
            if (matches.isEmpty)
              Padding(
                padding: const EdgeInsets.all(AbTokens.space16),
                child: Text(
                  _query.trim().isEmpty
                      ? 'Nothing to run here.'
                      : 'No command matches "${_query.trim()}".',
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontSm,
                    color: c.textMuted,
                  ),
                ),
              )
            else
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    vertical: AbTokens.space4,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (i, command) in matches.indexed)
                        AbListRow(
                          key: _rowKeys.putIfAbsent(command, GlobalKey.new),
                          density: AbRowDensity.sm,
                          selected: i == _selected,
                          selectionStyle: AbRowSelection.surface,
                          hoverable: true,
                          onTap: () => _run(command),
                          title: Text(
                            command.label,
                            style: AbTokens.sansStyle(
                              fontSize: AbTokens.fontSm,
                              color: c.textPrimary,
                            ),
                          ),
                          subtitle: Text(
                            command.group.label,
                            style: AbTokens.sansStyle(
                              fontSize: AbTokens.fontXxs,
                              color: c.textMuted,
                            ),
                          ),
                          trailing: switch (primaryChord(command)) {
                            final chord? => AbKbdGroup(
                              chord.keyCaps(apple: apple),
                            ),
                            null => null,
                          },
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
