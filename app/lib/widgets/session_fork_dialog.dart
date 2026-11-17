import 'dart:async';

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../design/widgets/ab_agent_mark.dart';
import 'ab_status_helpers.dart' show agentsCheckingCopy, agentsUnlistedCopy;
import 'carbon_choice_tile.dart';

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
/// Two choice tiles rather than a confirmation's opt-in toggle: a toggle is for
/// a second consequence the user may accept alongside the primary one, and this
/// is not a consequence to accept but the choice itself. Both alternatives, and
/// what each does to uncommitted work, have to be legible without touching
/// anything.
///
/// [context] must sit under a Carbon scope.
///
/// [isolatedSource] is what "this workspace" MEANS, and it changes the promise
/// rather than the wording: sharing an isolated session's checkout puts two
/// agents somewhere only they can see, while sharing a main-tree session's puts
/// the fork where every ordinary session already lives.
///
/// The agent list appears whenever [source] is given, which a caller does only
/// for a bridge that can hand off to another agent: against any other, offering
/// the list would fork silently into the same one. Whether a session can hand
/// off is known up front and whether its machine has another agent is not, so
/// the list never waits on [targets] to exist; the dialog opens at once and
/// the agents fill in when [targets] answers.
Future<SessionForkChoice?> promptSessionFork(
  BuildContext context, {
  required bool isolatedSource,
  SessionForkTarget? source,
  Future<List<SessionForkTarget>>? targets,
}) {
  // The dialog attaches its handler when it first builds; a route that never
  // does would leave a failed lookup to the zone as an uncaught error.
  targets?.ignore();
  return showCarbonModal<SessionForkChoice>(
    context,
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
    if (answer == null) return agentsCheckingCopy;
    if (answer.failed) return agentsUnlistedCopy;
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
  Widget _agentList(CarbonThemeData t) {
    final note = _agentNote;
    return Column(
      key: const Key('fork-agent-selector'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CarbonContainedList(
          label: null,
          variant: CarbonContainedListVariant.disclosed,
          children: [
            for (final agent in _known)
              CarbonContainedListRow(
                title: agent.label,
                selected: agent.tool == _tool,
                leading: AbAgentMark(
                  toolKey: agent.tool,
                  label: agent.label,
                  size: t.iconSize,
                  color: t.colors.iconSecondary,
                ),
                onPressed: () => setState(() => _tool = agent.tool),
              ),
          ],
        ),
        if (note != null) ...[
          const SizedBox(height: CarbonSpacing.spacing02),
          Text(
            note,
            style: t.typography.label.copyWith(color: t.colors.textSecondary),
          ),
        ],
      ],
    );
  }

  /// What a pick does to the user's work, in one line. Whether uncommitted
  /// changes come along is the one thing a user cannot see by looking, so every
  /// choice says it.
  String _consequence(String workspace) => switch (workspace) {
    forkWorkspaceCurrent when widget.isolatedSource =>
      'Same files as this session, uncommitted changes included.',
    forkWorkspaceCurrent => 'Your main directory, uncommitted changes included.',
    _ => 'Starts from the last commit, without uncommitted changes.',
  };

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    final label = t.typography.label.copyWith(color: t.colors.textSecondary);
    return CarbonModal(
      title: 'Fork session',
      size: CarbonModalSize.xs,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_showAgentRow) ...[
            Text('Agent', style: label),
            const SizedBox(height: CarbonSpacing.spacing03),
            _agentList(t),
            const SizedBox(height: CarbonSpacing.spacing05),
          ],
          Text('Workspace', style: label),
          const SizedBox(height: CarbonSpacing.spacing03),
          Wrap(
            spacing: CarbonSpacing.spacing03,
            runSpacing: CarbonSpacing.spacing03,
            children: [
              for (final (value, name) in const [
                (forkWorkspaceCurrent, 'This workspace'),
                (forkWorkspaceCopy, 'New workspace'),
              ])
                CarbonChoiceTile(
                  label: name,
                  detail: _consequence(value),
                  selected: _workspace == value,
                  onPressed: () => setState(() => _workspace = value),
                ),
            ],
          ),
        ],
      ),
      actions: [
        CarbonModalAction(
          label: 'Cancel',
          kind: CarbonButtonKind.secondary,
          onPressed: _cancel,
        ),
        CarbonModalAction(
          label: _crossAgent ? 'Continue' : 'Fork',
          onPressed: _confirm,
        ),
      ],
    );
  }
}
