// app/lib/widgets/git_commit_sheet.dart
import 'package:flutter/material.dart';

import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_dialog.dart';
import '../design/widgets/ab_text_field.dart';

/// Commit dialog: a single-line message field, nothing else. What gets
/// committed is decided by staging (Stage/Unstage in the changes list), not
/// here — matching VS Code, where the commit box never re-asks which files.
class GitCommitSheet extends StatefulWidget {
  const GitCommitSheet({super.key, required this.onCommit});

  final void Function(String message) onCommit;

  static Future<void> show({
    required BuildContext context,
    required void Function(String message) onCommit,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => GitCommitSheet(onCommit: onCommit),
    );
  }

  @override
  State<GitCommitSheet> createState() => _GitCommitSheetState();
}

class _GitCommitSheetState extends State<GitCommitSheet> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canCommit => _controller.text.trim().isNotEmpty;

  void _commit() {
    if (!_canCommit) return;
    widget.onCommit(_controller.text.trim());
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
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
                  // setState-ing the whole sheet on every character.
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
