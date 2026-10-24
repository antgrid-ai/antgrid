import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show Dialog, Navigator, showDialog;

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_agent_mark.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_dialog.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_scrollbar.dart';
import '../design/widgets/ab_segmented.dart';
import '../design/widgets/ab_separator.dart';
import '../design/widgets/ab_touch_sizing.dart';

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

typedef _TargetsAnswer = ({List<SessionForkTarget> targets, bool failed});

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
/// The agent row appears whenever [source] is given, which a caller does only
/// for a bridge that can hand off to another agent: against any other, offering
/// the row would fork silently into the same one. Whether a session can hand
/// off is known up front and whether its machine has another agent is not, so
/// the row never waits on [targets] to exist; the dialog opens at once and
/// the agent list fills in when [targets] answers.
Future<SessionForkChoice?> promptSessionFork(
  BuildContext context, {
  required bool isolatedSource,
  SessionForkTarget? source,
  Future<List<SessionForkTarget>>? targets,
}) {
  // The dialog attaches its handler when it first builds; a route that never
  // does would leave a failed lookup to the zone as an uncaught error.
  targets?.ignore();
  return showDialog<SessionForkChoice>(
    context: context,
    builder: (_) => _SessionForkDialog(
      isolatedSource: isolatedSource,
      source: source,
      targets: targets,
    ),
  );
}

class _SessionForkDialog extends StatefulWidget {
  const _SessionForkDialog({
    required this.isolatedSource,
    required this.source,
    required this.targets,
  });

  final bool isolatedSource;
  final SessionForkTarget? source;
  final Future<List<SessionForkTarget>>? targets;

  @override
  State<_SessionForkDialog> createState() => _SessionForkDialogState();
}

class _SessionForkDialogState extends State<_SessionForkDialog> {
  // A fork usually carries on the work in progress, and a new workspace starts
  // from the last commit without it.
  String _workspace = forkWorkspaceCurrent;

  late String? _tool = widget.source?.tool;

  // Null until [_SessionForkDialog.targets] answers.
  _TargetsAnswer? _answer;

  final _agentScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    final targets = widget.targets;
    if (targets == null) return;
    unawaited(
      targets.then(
        (t) => _answered((targets: t, failed: false)),
        onError: (Object _) => _answered((targets: const [], failed: true)),
      ),
    );
  }

  void _answered(_TargetsAnswer answer) {
    if (mounted) setState(() => _answer = answer);
  }

  @override
  void dispose() {
    _agentScroll.dispose();
    super.dispose();
  }

  bool get _showAgentRow => widget.source != null;

  bool get _crossAgent => _showAgentRow && _tool != widget.source!.tool;

  List<SessionForkTarget> get _known {
    final answer = _answer;
    if (answer == null || answer.failed) return [?widget.source];
    return answer.targets;
  }

  /// Why the list offers no other agent, or null when it offers one. Never
  /// says "this machine": on a phone, the machine in hand is not the one asked.
  String? get _agentNote {
    final answer = _answer;
    if (answer == null) return 'Checking installed agents…';
    if (answer.failed) return "Couldn't list installed agents.";
    if (answer.targets.any((t) => t.tool != widget.source?.tool)) return null;
    return 'No other agent installed.';
  }

  void _cancel() => Navigator.of(context).pop();
  void _confirm() => Navigator.of(context).pop(
    SessionForkChoice(
      workspace: _workspace,
      targetTool: _showAgentRow ? _tool : null,
    ),
  );

  // Inline rather than behind a dropdown: the list is short, picking is one
  // tap, and a lookup still running shows where the answer will land instead
  // of inside a menu the user has to open to find out.
  Widget _agentList(BuildContext context) {
    final colors = context.antgrid;
    final note = _agentNote;
    final touchMin = AbTouchSizing.extentOf(context);
    return Container(
      key: const Key('fork-agent-selector'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        border: Border.all(color: colors.borderDefault),
        borderRadius: AbTokens.borderRadius5,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The one part of the dialog that gives way on a short screen: the
          // workspace choice and the buttons below it must stay in view, and a
          // row cut part-way plus the thumb say the list goes on.
          Flexible(
            child: AbScrollbar(
              controller: _agentScroll,
              child: SingleChildScrollView(
                controller: _agentScroll,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final t in _known)
                      Semantics(
                        inMutuallyExclusiveGroup: true,
                        selected: t.tool == _tool,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(minHeight: touchMin),
                          child: AbListRow(
                            density: AbRowDensity.sm,
                            selected: t.tool == _tool,
                            selectionStyle: AbRowSelection.surface,
                            leading: AbAgentMark(
                              toolKey: t.tool,
                              label: t.label,
                              size: AbTokens.space16,
                              color: t.tool == _tool
                                  ? colors.textPrimary
                                  : null,
                            ),
                            title: Text(t.label),
                            trailing: t.tool == _tool
                                ? AbIcon(
                                    AbIcons.check,
                                    size: AbTokens.iconButtonGlyph,
                                    color: colors.accent,
                                  )
                                : null,
                            onTap: () => setState(() => _tool = t.tool),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (note != null) ...[
            const AbSeparator.horizontal(),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AbTokens.space12,
                vertical: AbTokens.space8,
              ),
              child: Text(
                note,
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontXs,
                  color: colors.textMuted,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// What the CURRENT pick does to the user's work, in one line. Whether
  /// uncommitted changes come along is the one thing a user cannot see by
  /// looking, so every line says it.
  String get _consequence => switch (_workspace) {
    forkWorkspaceCurrent when widget.isolatedSource =>
      "Same files as this session, uncommitted changes included.",
    forkWorkspaceCurrent =>
      'Your main directory, uncommitted changes included.',
    _ => 'Starts from the last commit, without uncommitted changes.',
  };

  @override
  Widget build(BuildContext context) {
    final label = AbTokens.sansStyle(
      fontSize: AbTokens.fontSm,
      fontWeight: FontWeight.w600,
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
                Text('Agent', style: label),
                const SizedBox(height: AbTokens.space6),
                Flexible(child: _agentList(context)),
                const SizedBox(height: AbTokens.space16),
              ],
              Text('Workspace', style: label),
              const SizedBox(height: AbTokens.space6),
              // Left-aligned rather than stretched: [AbSegmented]'s own Row is
              // `mainAxisSize.min`, so the surrounding Column's stretch hands it
              // tight constraints it cannot use — a border box wider than its
              // cells at best, and a fractional overflow at worst.
              Align(
                alignment: Alignment.centerLeft,
                child: AbSegmented<String>(
                  segments: const [
                    AbSegment(
                      value: forkWorkspaceCurrent,
                      label: 'This workspace',
                    ),
                    AbSegment(value: forkWorkspaceCopy, label: 'New workspace'),
                  ],
                  selected: _workspace,
                  onSelect: (v) => setState(() => _workspace = v),
                ),
              ),
              const SizedBox(height: AbTokens.space6),
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
