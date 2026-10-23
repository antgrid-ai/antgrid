import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show Dialog, Navigator, showDialog;

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_dialog.dart';
import '../design/widgets/ab_menu.dart';
import '../design/widgets/ab_segmented.dart';
import '../util/detached.dart';
import 'new_session/environment_menu.dart' show ComposerChip;

/// The two workspaces a fork can run in, spelled the way `session:fork` spells
/// them, so nothing has to translate between the control the user touched and
/// the frame it produces.
const String forkWorkspaceCopy = 'copy';
const String forkWorkspaceCurrent = 'current';

/// What the user chose in the fork dialog. [targetTool] is the agent the fork
/// should run in, or null when the dialog offered no agent choice; it can equal
/// the source's own agent, which the caller must not put on the wire.
class SessionForkChoice {
  const SessionForkChoice({required this.workspace, this.targetTool});

  final String workspace;
  final String? targetTool;
}

/// A tool the fork may continue in: registry key and display label.
typedef SessionForkTarget = ({String tool, String label});

/// Asks which workspace, and optionally which agent, a fork of this session
/// should run in. Returns null if the user cancelled or dismissed.
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
///
/// The agent row appears only when [sourceTool] is known and [targets] is not
/// empty. Both are empty against a bridge that cannot hand off to another
/// agent, where offering the row would fork silently into the same one.
Future<SessionForkChoice?> promptSessionFork(
  BuildContext context, {
  required bool isolatedSource,
  required String? sourceTool,
  required List<SessionForkTarget> targets,
}) {
  return showDialog<SessionForkChoice>(
    context: context,
    builder: (_) => _SessionForkDialog(
      isolatedSource: isolatedSource,
      sourceTool: sourceTool,
      targets: targets,
    ),
  );
}

class _SessionForkDialog extends StatefulWidget {
  const _SessionForkDialog({
    required this.isolatedSource,
    required this.sourceTool,
    required this.targets,
  });

  final bool isolatedSource;
  final String? sourceTool;
  final List<SessionForkTarget> targets;

  @override
  State<_SessionForkDialog> createState() => _SessionForkDialogState();
}

class _SessionForkDialogState extends State<_SessionForkDialog> {
  // The workspace nothing else is standing in. A fork that lands beside a
  // running agent is the answer the user has to ask for.
  String _workspace = forkWorkspaceCopy;

  // A deliberate segment pick outranks the default an agent change implies.
  bool _workspaceTouched = false;

  late String? _tool = widget.sourceTool;

  bool get _showAgentRow =>
      widget.sourceTool != null && widget.targets.isNotEmpty;

  bool get _crossAgent => _showAgentRow && _tool != widget.sourceTool;

  String get _toolLabel {
    for (final t in widget.targets) {
      if (t.tool == _tool) return t.label;
    }
    return _tool ?? '';
  }

  void _cancel() => Navigator.of(context).pop();
  void _confirm() => Navigator.of(context).pop(
    SessionForkChoice(
      workspace: _workspace,
      targetTool: _showAgentRow ? _tool : null,
    ),
  );

  Future<void> _pickAgent(BuildContext chip) async {
    final anchor = abMenuAnchorRect(chip);
    if (anchor == null) return;
    final picked = await showAbMenu<String>(
      context: chip,
      anchorRect: anchor,
      bounds: MenuBoundsScope.maybeOf(chip),
      entries: [
        for (final t in widget.targets)
          AbMenuItem(
            label: t.label,
            value: t.tool,
            icon: t.tool == _tool ? AbIcons.check : null,
          ),
      ],
    );
    if (picked == null || !mounted) return;
    setState(() {
      _tool = picked;
      // Another agent means the work in progress is what is being handed over,
      // so the default follows the agent rather than staying on a checkout the
      // new agent would start without those edits.
      if (!_workspaceTouched) {
        _workspace = picked == widget.sourceTool
            ? forkWorkspaceCopy
            : forkWorkspaceCurrent;
      }
    });
  }

  /// The consequence of the CURRENT pick, stated as what happens to the user's
  /// work rather than as what Antgrid does. The uncommitted-changes clause is
  /// the one thing here a user cannot recover by looking, so it is a sentence
  /// of its own and not a subordinate clause.
  String get _consequence => switch (_workspace) {
    forkWorkspaceCurrent when _crossAgent && widget.isolatedSource =>
      'The new agent continues in this one directory with your uncommitted '
          'changes. Both sessions work in it at the same time — the same '
          'files, the same branch.',
    forkWorkspaceCurrent when _crossAgent =>
      'The new agent continues in this workspace with your uncommitted '
          'changes. Both sessions work in the same files at the same time.',
    forkWorkspaceCurrent when widget.isolatedSource =>
      'Both sessions work in this one directory at the same time — the same '
          'files, the same branch, the same commits.',
    forkWorkspaceCurrent =>
      'The fork works in your main directory, alongside every other session '
          'there — the same files, the same branch.',
    _ when _crossAgent =>
      'The new workspace starts from the last commit; uncommitted changes stay '
          'behind.',
    _ when widget.isolatedSource =>
      'A workspace of its own, taken from this session\'s last commit. Work '
          'you have not committed stays here and the fork never sees it.',
    _ =>
      'A workspace of its own, taken from your last commit. Work you have not '
          'committed stays in your main directory and the fork never sees it.',
  };

  @override
  Widget build(BuildContext context) {
    final subtle = AbTokens.sansStyle(
      fontSize: AbTokens.fontSm,
      color: context.antgrid.textSecondary,
    );
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
              if (_showAgentRow) ...[
                Text('The fork continues in:', style: subtle),
                const SizedBox(height: AbTokens.space8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: ComposerChip(
                    key: const Key('fork-agent-selector'),
                    icon: AbIcons.terminal,
                    label: _toolLabel,
                    onTap: (chip) => detached(
                      'SessionForkDialog',
                      'pick fork agent',
                      () => _pickAgent(chip),
                    ),
                  ),
                ),
                const SizedBox(height: AbTokens.space12),
              ],
              Text(
                _showAgentRow
                    ? 'It picks the conversation up where this session left '
                          'it, and runs in:'
                    : 'The fork picks the conversation up where this session '
                          'left it, and runs in:',
                style: subtle,
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
                  onSelect: (v) => setState(() {
                    _workspace = v;
                    _workspaceTouched = true;
                  }),
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
                    label: _crossAgent ? 'Continue' : 'Fork',
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
