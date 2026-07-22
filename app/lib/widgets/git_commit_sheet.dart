// app/lib/widgets/git_commit_sheet.dart
import 'package:flutter/material.dart';

import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/ab_colors.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_dialog.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_text_field.dart';

/// Commit sheet: a single-line message field plus a checklist of changed
/// files (all checked by default). "Commit" is enabled only when the message
/// is non-empty and at least one file is selected. Calls [onCommit] with the
/// message and the selected paths, then pops.
class GitCommitSheet extends StatefulWidget {
  const GitCommitSheet({
    super.key,
    required this.changedFiles,
    required this.onCommit,
  });

  /// path -> status code (M/A/D/?).
  final Map<String, String> changedFiles;
  final void Function(String message, List<String> files) onCommit;

  static Future<void> show({
    required BuildContext context,
    required Map<String, String> changedFiles,
    required void Function(String message, List<String> files) onCommit,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) =>
          GitCommitSheet(changedFiles: changedFiles, onCommit: onCommit),
    );
  }

  @override
  State<GitCommitSheet> createState() => _GitCommitSheetState();
}

class _GitCommitSheetState extends State<GitCommitSheet> {
  final _controller = TextEditingController();
  late final Map<String, bool> _selected = {
    for (final p in widget.changedFiles.keys) p: true,
  };

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canCommit =>
      _controller.text.trim().isNotEmpty && _selected.values.any((v) => v);

  void _commit() {
    if (!_canCommit) return;
    final files =
        _selected.entries.where((e) => e.value).map((e) => e.key).toList();
    widget.onCommit(_controller.text.trim(), files);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.changedFiles.entries.toList();
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, maxHeight: 520),
        child: Padding(
          padding: const EdgeInsets.all(AbTokens.space16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 'Commit changes' title is distinct from the 'Commit' button
              // label below so tests (and screen readers) can target the action
              // unambiguously.
              abDialogTitle(
                'Commit changes',
                onClose: () => Navigator.of(context).pop(),
              ),
              const SizedBox(height: AbTokens.space12),
              AbTextField(
                controller: _controller,
                hintText: 'Commit message',
                autofocus: true,
                onSubmitted: (_) => _commit(),
              ),
              const SizedBox(height: AbTokens.space12),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: entries.length,
                  itemBuilder: (context, i) {
                    final path = entries[i].key;
                    final status = entries[i].value;
                    final selected = _selected[path]!;
                    return AbListRow(
                      density: AbRowDensity.sm,
                      horizontalPadding: 0,
                      onTap: () => setState(() => _selected[path] = !selected),
                      leading: AbIcon(
                        selected ? AbIcons.check : AbIcons.close,
                        size: AbTokens.iconButtonGlyph,
                        color: selected
                            ? context.antgrid.accent
                            : context.antgrid.textDisabled,
                      ),
                      title: Text(
                        path,
                        style: AbTokens.monoStyle(fontSize: AbTokens.fontSm),
                      ),
                      trailing: Text(
                        status,
                        style: AbTokens.monoStyle(
                          fontSize: AbTokens.fontXs,
                          color: context.antgrid.textMuted,
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: AbTokens.space16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  AbButton(
                    label: 'Cancel',
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: AbTokens.space8),
                  // Only the message-empty check varies per keystroke; rebuild
                  // just the button off the controller listenable rather than
                  // setState-ing the whole sheet (and its file list) on every
                  // character. Selection toggles still setState (infrequent).
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _controller,
                    builder: (context, _, _) => AbButton(
                      label: 'Commit',
                      variant: AbButtonVariant.primary,
                      onTap: _canCommit ? _commit : null,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
