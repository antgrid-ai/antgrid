import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_adaptive_sheet.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_icon_button.dart';
import '../../design/widgets/ab_inline_banner.dart';
import '../../design/widgets/ab_multiline_field.dart';
import '../../design/widgets/ab_segmented.dart';
import '../../design/widgets/ab_select_sheet.dart';
import '../../design/widgets/ab_separator.dart';
import '../../models/task.dart';
import '../../providers/agent_catalog.dart';
import '../../providers/focused_tools.dart';
import '../../providers/new_session_picker.dart';
import '../../providers/task_launcher.dart';
import '../../providers/tasks.dart';
import '../../services/sessions_service.dart';
import '../../util/detached.dart';
import '../session_start_refusal.dart';
import 'task_provenance_view.dart';

/// The launch sheet for [task].
///
/// Every start goes through it, imported task or not: the user must see what
/// the agent will be told, and in which project, before it is told.
Future<void> showTaskLaunchSheet(BuildContext context, Task task) {
  // Reset from the tap that opens the sheet, not from the sheet's own
  // initState: initState runs inside the tree's build phase, which is the one
  // place a provider write is forbidden.
  resetTaskLaunchForm(ProviderScope.containerOf(context, listen: false));
  return showAbAdaptiveSheet<void>(
    context,
    child: _TaskLaunchSheet(task: task),
  );
}

class _TaskLaunchSheet extends ConsumerStatefulWidget {
  const _TaskLaunchSheet({required this.task});

  final Task task;

  @override
  ConsumerState<_TaskLaunchSheet> createState() => _TaskLaunchSheetState();
}

class _TaskLaunchSheetState extends ConsumerState<_TaskLaunchSheet> {
  final _prompt = TextEditingController();
  var _submitting = false;

  /// The last failure, and whether trying again is the right answer. A refusal
  /// is the bridge's considered "no"; a timeout is no answer at all, and the
  /// two must not read the same.
  String? _failure;
  var _retryable = false;

  @override
  void initState() {
    super.initState();
    _prompt.text = taskLaunchBrief(widget.task);
  }

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _pickAgent() async {
    // Read, not watch: the tool advert costs a control-plane round trip (a
    // loopback `tools:list` for a local project), and the sheet must not pay it
    // just to render a label.
    final wire =
        (await ref.read(focusedMachineToolsProvider.future)).labels;
    final catalog = ref.read(agentCatalogProvider);
    if (!mounted) return;
    final keys = <String>{...wire.keys, ...catalog.keys};
    final picked = await showAbSelect<String>(
      context,
      title: 'Agent',
      single: true,
      emptyMessage: 'This machine has not said what it can run',
      options: [
        const AbSelectOption(
          value: '',
          label: 'Project default',
          detail: 'Whatever antgrid.yaml configures',
        ),
        for (final key in keys)
          AbSelectOption(
            value: key,
            label: newSessionAgentLabel(KnownAgent(key), wire, catalog),
          ),
      ],
      selected: {ref.read(taskLaunchToolProvider) ?? ''},
    );
    final choice = picked?.firstOrNull;
    if (choice == null || !mounted) return;
    ref
        .read(taskLaunchToolProvider.notifier)
        .set(choice.isEmpty ? null : choice);
  }

  Future<void> _start() async {
    final launcher = ref.read(taskLauncherProvider);
    if (launcher == null || _submitting) return;
    if (launcher.unavailableReason(widget.task) != null) return;
    // The field is the source of truth; the provider is only the handoff to
    // [TaskLauncher.start], whose signature carries the task and nothing else.
    ref.read(taskLaunchPromptProvider.notifier).set(_prompt.text);
    setState(() {
      _submitting = true;
      _failure = null;
    });
    try {
      await launcher.start(widget.task);
      if (mounted) Navigator.of(context).pop();
    } on SessionOperationException catch (error) {
      // The refusal is shown HERE, not as a snack bar: this sheet has no
      // composer behind it, and a session cap reached is the most ordinary
      // failure on this path — letting it escape makes it an unhandled async
      // error with nothing on screen.
      if (!mounted) return;
      setState(() {
        _failure = sessionStartRefusalCopy(error.errorCode, error.message);
        _retryable = false;
        _submitting = false;
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _failure =
            'The agent didn’t answer. The session may still be coming up — '
            'try again in a moment.';
        _retryable = true;
        _submitting = false;
      });
    } catch (_) {
      // The arm `session_delete_flow.dart` established: a disposed service or a
      // dead transport is neither a refusal worth quoting nor something to
      // leave as an unhandled async error. Without it `_submitting` never
      // clears, and the sheet sits on a spinner with nothing on screen to say
      // the start failed.
      if (!mounted) return;
      setState(() {
        _failure = 'Antgrid couldn’t start the session. Try again.';
        _retryable = true;
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.antgrid;
    final task = widget.task;
    final launcher = ref.watch(taskLauncherProvider);
    final blocked = launcher?.unavailableReason(task);
    final isolationReady = ref.watch(taskLaunchIsolationReadyProvider);
    final isolated = ref.watch(taskLaunchIsolatedProvider) && isolationReady;
    final tool = ref.watch(taskLaunchToolProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AbTokens.space12,
            AbTokens.space8,
            AbTokens.space8,
            AbTokens.space8,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Start session',
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontSm,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                task.ref,
                style: AbTokens.monoStyle(
                  fontSize: AbTokens.fontXs,
                  color: palette.textMuted,
                ),
              ),
              const SizedBox(width: AbTokens.space8),
              AbIconButton(
                icon: AbIcons.close,
                tooltip: 'Close',
                onTap: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        const AbSeparator.horizontal(),
        if (blocked != null)
          AbInlineBanner(text: blocked, color: palette.warning),
        if (_failure != null)
          AbInlineBanner(
            text: _failure!,
            color: palette.error,
            trailing: _retryable
                ? AbButton(
                    label: 'Try again',
                    compact: true,
                    onTap: () => detached('tasks', 'retry task launch', _start),
                  )
                : null,
          ),
        Padding(
          padding: const EdgeInsets.all(AbTokens.space12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _target(context),
              const SizedBox(height: AbTokens.space12),
              Row(
                children: [
                  AbButton(
                    label: tool == null
                        ? 'Project default'
                        : newSessionAgentLabel(
                            KnownAgent(tool),
                            null,
                            ref.watch(agentCatalogProvider),
                          ),
                    compact: true,
                    leading: const AbIcon(
                      AbIcons.terminal,
                      size: AbTokens.iconButtonGlyph,
                    ),
                    onTap: () => detached('tasks', 'pick agent', _pickAgent),
                  ),
                  const SizedBox(width: AbTokens.space8),
                  AbSegmented<bool>(
                    selected: isolated,
                    segments: [
                      AbSegment(
                        value: true,
                        label: 'Isolated',
                        enabled: isolationReady,
                        // Covers both states this cell has when disabled: the
                        // capability answer is still in flight, or it came back
                        // no. Naming only the second would be a false sentence
                        // for as long as a cold or remote project takes to
                        // answer.
                        disabledReason:
                            'Antgrid has not confirmed this project can run '
                            'isolated sessions.',
                      ),
                      const AbSegment(value: false, label: 'Shared'),
                    ],
                    onSelect: (v) =>
                        ref.read(taskLaunchIsolatedProvider.notifier).set(v),
                  ),
                ],
              ),
              const SizedBox(height: AbTokens.space12),
              if (!task.isLocal) ...[
                TaskProvenanceNotice(task: task),
                const SizedBox(height: AbTokens.space8),
              ],
              AbMultilineField(
                controller: _prompt,
                minLines: 4,
                maxLines: 12,
                hintText: 'What the agent is told first.',
              ),
              const SizedBox(height: AbTokens.space12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      isolated
                          ? 'Runs on its own branch, off this project’s '
                                'checkout.'
                          : 'Runs in this project’s checkout, alongside '
                                'everything else in it.',
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontXxs,
                        color: palette.textMuted,
                      ),
                    ),
                  ),
                  AbButton(
                    label: 'Cancel',
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: AbTokens.space8),
                  AbButton(
                    label: _submitting ? 'Starting…' : 'Start',
                    variant: AbButtonVariant.primary,
                    onTap: _submitting || blocked != null || launcher == null
                        ? null
                        : () => detached('tasks', 'start task session', _start),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// The project the session lands in, spelled out.
  ///
  /// A task's `projectId` addresses the ACCOUNT's project and cannot be
  /// resolved to a local checkout, so this is the open project and nothing
  /// cleverer. Showing it is what keeps that honest instead of merely
  /// plausible.
  Widget _target(BuildContext context) {
    final palette = context.antgrid;
    final label = ref.watch(focusedProjectLabelProvider);
    final detail = ref.watch(focusedProjectDetailProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'In ${label ?? 'no open project'}',
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontXs,
            fontWeight: FontWeight.w600,
            color: palette.textPrimary,
          ),
        ),
        if (detail != null) ...[
          const SizedBox(height: AbTokens.space4),
          Text(
            detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AbTokens.monoStyle(
              fontSize: AbTokens.fontXxs,
              color: palette.textMuted,
            ),
          ),
        ],
        const SizedBox(height: AbTokens.space4),
        Text(
          'A task isn’t tied to a checkout — the session is created in the '
          'project you have open.',
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontXxs,
            color: palette.textMuted,
          ),
        ),
      ],
    );
  }
}
