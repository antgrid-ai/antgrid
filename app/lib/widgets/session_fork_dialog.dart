import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show Dialog, Navigator, showDialog;

import '../design/ab_colors.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_dialog.dart';
import '../design/widgets/ab_segmented.dart';

/// The two workspaces a fork can run in, spelled the way `session:fork` spells
/// them, so nothing has to translate between the control the user touched and
/// the frame it produces.
const String forkWorkspaceCopy = 'copy';
const String forkWorkspaceCurrent = 'current';

/// Asks which workspace a fork of this session should run in. Returns
/// [forkWorkspaceCopy] or [forkWorkspaceCurrent], or null if the user
/// cancelled or dismissed.
///
/// A segmented control rather than [AbConfirmDialog]'s opt-in toggle: that
/// toggle is documented for "a second consequence the user may accept alongside
/// the primary one — never for restating the primary action", and this is not a
/// consequence to accept but the choice itself. Both alternatives have to be
/// legible without touching anything, which is what [AbSegmented] exists for.
///
/// [isolatedSource] is what "this workspace" MEANS, and it changes the promise
/// rather than the wording: sharing an isolated session's checkout puts two
/// agents somewhere only they can see, while sharing a main-tree session's puts
/// the fork where every ordinary session already lives.
Future<String?> promptSessionFork(
  BuildContext context, {
  required bool isolatedSource,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _SessionForkDialog(isolatedSource: isolatedSource),
  );
}

class _SessionForkDialog extends StatefulWidget {
  const _SessionForkDialog({required this.isolatedSource});

  final bool isolatedSource;

  @override
  State<_SessionForkDialog> createState() => _SessionForkDialogState();
}

class _SessionForkDialogState extends State<_SessionForkDialog> {
  // The workspace nothing else is standing in. A fork that lands beside a
  // running agent is the answer the user has to ask for.
  String _workspace = forkWorkspaceCopy;

  void _cancel() => Navigator.of(context).pop();
  void _confirm() => Navigator.of(context).pop(_workspace);

  /// The consequence of the CURRENT pick, stated as what happens to the user's
  /// work rather than as what Antgrid does. The uncommitted-changes clause is
  /// the one thing here a user cannot recover by looking, so it is a sentence
  /// of its own and not a subordinate clause.
  String get _consequence => switch (_workspace) {
    forkWorkspaceCurrent when widget.isolatedSource =>
      'Both sessions work in this one directory at the same time — the same '
          'files, the same branch, the same commits.',
    forkWorkspaceCurrent =>
      'The fork works in your main directory, alongside every other session '
          'there — the same files, the same branch.',
    _ when widget.isolatedSource =>
      'A workspace of its own, taken from this session\'s last commit. Work '
          'you have not committed stays here and the fork never sees it.',
    _ =>
      'A workspace of its own, taken from your last commit. Work you have not '
          'committed stays in your main directory and the fork never sees it.',
  };

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
              abDialogTitle('Fork session', onClose: _cancel),
              const SizedBox(height: AbTokens.space12),
              Text(
                'The fork picks the conversation up where this session left '
                'it, and runs in:',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontSm,
                  color: context.antgrid.textSecondary,
                ),
              ),
              const SizedBox(height: AbTokens.space12),
              // Left-aligned rather than stretched: [AbSegmented]'s own Row is
              // `mainAxisSize.min`, so the surrounding Column's stretch hands it
              // tight constraints it cannot use — a border box wider than its
              // cells at best, and a fractional overflow at worst.
              Align(
                alignment: Alignment.centerLeft,
                child: AbSegmented<String>(
                  segments: const [
                    AbSegment(
                      value: forkWorkspaceCopy,
                      label: 'New workspace',
                    ),
                    AbSegment(
                      value: forkWorkspaceCurrent,
                      label: 'This workspace',
                    ),
                  ],
                  selected: _workspace,
                  onSelect: (v) => setState(() => _workspace = v),
                ),
              ),
              const SizedBox(height: AbTokens.space8),
              Text(
                _consequence,
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXs,
                  color: context.antgrid.textMuted,
                ),
              ),
              const SizedBox(height: AbTokens.space16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  AbButton(label: 'Cancel', onTap: _cancel),
                  const SizedBox(width: AbTokens.space8),
                  AbButton(
                    label: 'Fork',
                    variant: AbButtonVariant.primary,
                    onTap: _confirm,
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
