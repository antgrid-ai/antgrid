import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show Dialog, Navigator, showDialog;

import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_dialog.dart';
import '../design/widgets/ab_text_field.dart';

/// Shared, on-design "rename session" prompt. Returns the trimmed new name, or
/// `null` if the user cancelled, dismissed, or left the field empty. The caller
/// decides whether the result is a no-op (e.g. unchanged from the current name).
///
/// Used by both the agent-panel breadcrumb (mobile tap) and the sessions
/// drawer kebab menu — replacing the old private Material `AlertDialog`.
Future<String?> promptSessionRename(BuildContext context, String current) {
  return showDialog<String>(
    context: context,
    builder: (_) => _SessionRenameDialog(current: current),
  );
}

class _SessionRenameDialog extends StatefulWidget {
  final String current;
  const _SessionRenameDialog({required this.current});

  @override
  State<_SessionRenameDialog> createState() => _SessionRenameDialogState();
}

class _SessionRenameDialogState extends State<_SessionRenameDialog> {
  late final TextEditingController _controller =
      TextEditingController.fromValue(
        TextEditingValue(
          text: widget.current,
          selection: TextSelection(
            baseOffset: 0,
            extentOffset: widget.current.length,
          ),
        ),
      );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    Navigator.of(context).pop(name.isEmpty ? null : name);
  }

  void _cancel() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.all(AbTokens.space16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              abDialogTitle('Rename session', onClose: _cancel),
              const SizedBox(height: AbTokens.space12),
              AbTextField(
                controller: _controller,
                autofocus: true,
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: AbTokens.space16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  AbButton(label: 'Cancel', onTap: _cancel),
                  const SizedBox(width: AbTokens.space8),
                  AbButton(
                    label: 'Rename',
                    variant: AbButtonVariant.primary,
                    onTap: _submit,
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
