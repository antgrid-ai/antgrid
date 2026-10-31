import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_chip.dart';
import '../../design/widgets/ab_dialog.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_list_row.dart';
import '../../design/widgets/ab_loading.dart';
import '../../design/widgets/ab_scrollbar.dart';
import '../../design/widgets/ab_separator.dart';
import '../../design/widgets/ab_toast.dart';
import '../../models/agent_work_status.dart';
import '../../models/memory.dart';
import '../../providers/providers.dart';
import '../../services/sessions_service.dart';
import '../../util/detached.dart';
import '../agent_work_status_dot.dart';
import '../session_mode_control.dart'
    show kRestartFailedError, kTeardownTimeoutError;

/// Restarts sessions that were already running when Memory was turned on, which
/// is the only way their agents gain it.
///
/// The ticks are advisory: a busy session starts unticked so an interrupt is
/// never the default, but the user may tick it. The bridge re-checks every
/// restart, so a list that went stale between the status answer and the tap
/// costs a no-op, not an interrupted agent.
class MemoryRestartSheet extends ConsumerStatefulWidget {
  const MemoryRestartSheet({
    super.key,
    required this.target,
    required this.sessions,
  });

  final MemoryTarget target;
  final List<MemorySessionWithoutMemory> sessions;

  @override
  ConsumerState<MemoryRestartSheet> createState() => _MemoryRestartSheetState();
}

class _RowResult {
  const _RowResult(
    this.text, {
    this.ok = false,
    this.restarted = false,
    this.stopped = false,
  });

  final String text;
  final bool ok;
  final bool restarted;

  /// The session was left stopped. Retrying would only meet the bridge's
  /// "not running" no-op and read as up to date, so the row is locked and its
  /// instruction stays on screen.
  final bool stopped;
}

const _restarted = _RowResult('Restarted.', ok: true, restarted: true);
const _alreadyFine = _RowResult(
  'Already up to date. Nothing was restarted.',
  ok: true,
);
const _unreachable = _RowResult("Couldn't reach this project.");
const _noAnswer = _RowResult(
  'No answer from the machine. Check the session before retrying.',
);

_RowResult _classify(SessionRestartResult r) {
  if (r.ok) return r.restarted ? _restarted : _alreadyFine;
  final error = r.error ?? '';
  return switch (r.errorCode) {
    'MEMORY_OFF' => const _RowResult(
      'Memory was turned off. Nothing was restarted.',
    ),
    'SCHEDULED_RUN' => const _RowResult(
      'A scheduled run is in progress. Its next run will use Memory.',
    ),
    _ when error.contains(kTeardownTimeoutError) => const _RowResult(
      "Didn't shut down in time. It's stopped; start it again.",
      stopped: true,
    ),
    _ when error.contains(kRestartFailedError) => const _RowResult(
      "Shut down but didn't start again. It's stopped; start it again.",
      stopped: true,
    ),
    _ => const _RowResult("Couldn't restart. Nothing was changed."),
  };
}

String _statusLabel(AgentWorkStatus? status) => switch (status) {
  AgentWorkStatus.done => 'Idle',
  AgentWorkStatus.unread => 'Finished',
  AgentWorkStatus.working => 'Working',
  AgentWorkStatus.attention => 'Needs you',
  AgentWorkStatus.error => 'Error',
  null => 'Running',
};

bool _isBusy(AgentWorkStatus? status) =>
    status == AgentWorkStatus.working || status == AgentWorkStatus.attention;

String _rowKey(MemorySessionWithoutMemory s) => '${s.projectId}/${s.sessionId}';

class _MemoryRestartSheetState extends ConsumerState<MemoryRestartSheet> {
  final _scroll = ScrollController();
  late final Set<String> _ticked = {
    for (final s in widget.sessions)
      if (s.workStatus == AgentWorkStatus.done ||
          s.workStatus == AgentWorkStatus.unread)
        _rowKey(s),
  };
  final Map<String, _RowResult> _results = {};
  bool _running = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _toggle(String key) {
    setState(() {
      if (!_ticked.remove(key)) _ticked.add(key);
    });
  }

  Future<_RowResult> _restartOne(SessionsService service, String id) async {
    try {
      return _classify(await service.restartForMemory(id));
    } catch (_) {
      // A reply timeout and a torn-down service both land here: either way the
      // restart's outcome is unknown, which is not the same as refused.
      return _noAnswer;
    }
  }

  Future<void> _restart() async {
    if (_running || _ticked.isEmpty) return;
    // Taken before any await: the sheet may be closed while a restart is still
    // in flight, and `ref` is unusable from then on.
    final container = ProviderScope.containerOf(context, listen: false);
    final target = widget.target;
    final groups = <String, List<MemorySessionWithoutMemory>>{};
    for (final s in widget.sessions) {
      if (_ticked.contains(_rowKey(s))) {
        groups.putIfAbsent(s.registrationId(target), () => []).add(s);
      }
    }
    setState(() {
      _running = true;
      // A retried row must show progress, not its previous failure.
      for (final rows in groups.values) {
        for (final s in rows) {
          _results.remove(_rowKey(s));
        }
      }
    });
    // One project at a time bounds churn in the app's warm-project LRU.
    for (final MapEntry(key: registrationId, value: rows) in groups.entries) {
      // Closing the sheet cancels the rest of the run: later projects would
      // otherwise be restarted after the user said Cancel.
      if (!mounted) return;
      final service = await warmServiceFor(
        container,
        registrationId,
        (s) => s.sessionsService,
        timeout: const Duration(seconds: 20),
      );
      final answers = service == null
          ? [for (final _ in rows) _unreachable]
          : await Future.wait([
              for (final s in rows) _restartOne(service, s.sessionId),
            ]);
      if (!mounted) return;
      setState(() {
        for (final (i, s) in rows.indexed) {
          final key = _rowKey(s);
          _results[key] = answers[i];
          if (answers[i].ok || answers[i].stopped) _ticked.remove(key);
        }
      });
    }
    if (!mounted) return;
    setState(() => _running = false);
    // Over every result, not just this run's: a stopped row from an earlier
    // attempt still owes the user its instruction.
    if (!_results.values.every((r) => r.ok)) return;
    final restarted = _results.values.where((r) => r.restarted).length;
    final noops = _results.values.where((r) => r.ok && !r.restarted).length;
    showAbToast(
      context,
      '${restarted == 1 ? 'Restarted 1 session.' : 'Restarted $restarted sessions.'}'
      '${noops > 0 ? ' $noops already had Memory.' : ''}',
    );
    Navigator.of(context).pop();
  }

  Widget _row(MemorySessionWithoutMemory s) {
    final colors = context.antgrid;
    final key = _rowKey(s);
    final ticked = _ticked.contains(key);
    final result = _results[key];
    final restarting = _running && ticked && result == null;
    final locked = (result?.ok ?? false) || (result?.stopped ?? false);
    return AbListRow(
      key: ValueKey(key),
      leading: Semantics(
        checked: ticked,
        child: AbIcon(
          ticked ? AbIcons.circleCheck : AbIcons.circle,
          size: AbTokens.fontBody,
          color: ticked ? colors.accent : colors.textMuted,
        ),
      ),
      title: Text(s.name, style: AbTokens.sansStyle(fontSize: AbTokens.fontMd)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (result != null)
            Text(
              result.text,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontSm,
                color: result.ok ? colors.textSecondary : colors.error,
              ),
            )
          else ...[
            Text(
              '${s.projectLabel} · ${_statusLabel(s.workStatus)}',
              style: AbTokens.sansStyle(fontSize: AbTokens.fontSm),
            ),
            if (ticked && _isBusy(s.workStatus))
              Text(
                "Restarting interrupts what it's doing now.",
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontSm,
                  color: colors.textSecondary,
                ),
              ),
          ],
        ],
      ),
      subtitleMaxLines: 3,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!s.resumable) ...[
            const AbChip.label(label: 'Starts a new conversation'),
            const SizedBox(width: AbTokens.space8),
          ],
          if (restarting)
            const AbLoading()
          else if (s.workStatus case final status?)
            AgentWorkStatusDot(status: status),
        ],
      ),
      onTap: _running || locked ? null : () => _toggle(key),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.antgrid;
    final count = _ticked.length;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: abDialogTitlePadding.copyWith(bottom: AbTokens.space8),
          child: abDialogTitle(
            'Restart to use Memory',
            onClose: () => Navigator.of(context).pop(),
          ),
        ),
        const AbSeparator.horizontal(),
        Flexible(
          child: AbScrollbar(
            controller: _scroll,
            child: SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.all(AbTokens.space16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    "These sessions were already running when Memory was turned on, so they can't use it. Restarting resumes each conversation with Memory.",
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontMd,
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: AbTokens.space16),
                  Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: colors.borderDefault),
                      borderRadius: AbTokens.borderRadius5,
                    ),
                    child: Column(
                      children: [
                        for (final (i, s) in widget.sessions.indexed) ...[
                          if (i > 0) const AbSeparator.horizontal(),
                          _row(s),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const AbSeparator.horizontal(),
        Padding(
          padding: const EdgeInsets.all(AbTokens.space12),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: AbTokens.space8,
            runSpacing: AbTokens.space8,
            children: [
              AbButton(
                label: 'Cancel',
                onTap: () => Navigator.of(context).pop(),
              ),
              AbButton(
                label: _running
                    ? 'Restarting…'
                    : count == 1
                    ? 'Restart 1 session'
                    : 'Restart $count sessions',
                variant: AbButtonVariant.primary,
                onTap: _running || count == 0
                    ? null
                    : () => detached('Memory', 'restart failed', _restart),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
