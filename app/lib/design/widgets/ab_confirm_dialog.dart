import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show Dialog, Navigator, showDialog;

import '../ab_icons.dart';
import '../ab_tokens.dart';
import '../ab_colors.dart';
import 'ab_button.dart';
import 'ab_icon_button.dart';
import 'ab_text_field.dart';

class AbConfirmDialog extends StatefulWidget {
  final String title;
  final String body;
  final String confirmLabel;
  final String cancelLabel;
  final bool destructive;

  /// When set, the confirm button stays disabled until the user types this exact
  /// word into a confirmation field — the type-to-confirm guard for destructive,
  /// irreversible actions.
  final String? confirmWord;

  const AbConfirmDialog({
    super.key,
    required this.title,
    required this.body,
    required this.confirmLabel,
    this.cancelLabel = 'Cancel',
    this.destructive = false,
    this.confirmWord,
  });

  /// Shows the dialog. Returns `true` if the user confirmed.
  static Future<bool> show({
    required BuildContext context,
    required String title,
    required String body,
    required String confirmLabel,
    String cancelLabel = 'Cancel',
    bool destructive = false,
    String? confirmWord,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AbConfirmDialog(
        title: title,
        body: body,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        destructive: destructive,
        confirmWord: confirmWord,
      ),
    );
    return result == true;
  }

  @override
  State<AbConfirmDialog> createState() => _AbConfirmDialogState();
}

class _AbConfirmDialogState extends State<AbConfirmDialog> {
  TextEditingController? _controller;
  late bool _confirmed;

  @override
  void initState() {
    super.initState();
    // No confirm word → button enabled from the start.
    _confirmed = widget.confirmWord == null;
    if (widget.confirmWord != null) {
      _controller = TextEditingController()
        ..addListener(() {
          final ok = _controller!.text.trim() == widget.confirmWord;
          if (ok != _confirmed) setState(() => _confirmed = ok);
        });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Padding(
          padding: const EdgeInsets.all(AbTokens.space16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: AbTokens.sansStyle(fontSize: AbTokens.fontBody),
                    ),
                  ),
                  AbIconButton(
                    icon: AbIcons.close,
                    onTap: () => Navigator.of(context).pop(false),
                  ),
                ],
              ),
              const SizedBox(height: AbTokens.space12),
              Text(
                widget.body,
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontSm,
                  color: context.antgrid.textSecondary,
                ),
              ),
              if (controller != null) ...[
                const SizedBox(height: AbTokens.space12),
                Text(
                  'Type ${widget.confirmWord} to confirm.',
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontXs,
                    color: context.antgrid.textMuted,
                  ),
                ),
                const SizedBox(height: AbTokens.space8),
                AbTextField(
                  controller: controller,
                  hintText: widget.confirmWord,
                  autofocus: true,
                ),
              ],
              const SizedBox(height: AbTokens.space16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  AbButton(
                    label: widget.cancelLabel,
                    onTap: () => Navigator.of(context).pop(false),
                  ),
                  const SizedBox(width: AbTokens.space8),
                  AbButton(
                    label: widget.confirmLabel,
                    color: widget.destructive
                        ? context.antgrid.error
                        : context.antgrid.accent,
                    onTap: _confirmed
                        ? () => Navigator.of(context).pop(true)
                        : null,
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
