import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design/widgets/ab_toast.dart';
import '../../models/agent_work_status.dart';
import '../../models/memory.dart';
import '../../providers/providers.dart';
import '../../services/sessions_service.dart';
import '../../util/detached.dart';

/// [context] must sit under an `AbCarbonScope`: the modal route takes its theme
/// and density from the presenting context.
Future<void> showMemoryRestart(
  BuildContext context, {
  required MemoryTarget target,
  required List<MemorySessionWithoutMemory> sessions,
}) => showCarbonModal<void>(
  context,
  builder: (_) => MemoryRestartSheet(target: target, sessions: sessions),
);

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

enum _Outcome {
  restarted,
  unchanged,
  failed,

  /// The session was left stopped. Retrying would only meet the bridge's
  /// "not running" no-op and read as up to date, so the row is locked and its
  /// instruction stays on screen.
  stopped,
}

class _RowResult {
  const _RowResult(this.text, this.outcome);

  final String text;
  final _Outcome outcome;

  bool get ok =>
      outcome == _Outcome.restarted || outcome == _Outcome.unchanged;
  bool get locked => outcome != _Outcome.failed;
}

const _restarted = _RowResult('Restarted.', _Outcome.restarted);
const _alreadyFine = _RowResult(
  'Already up to date. Nothing was restarted.',
  _Outcome.unchanged,
);
const _unreachable = _RowResult(
  "Couldn't reach this project.",
  _Outcome.failed,
);
const _noAnswer = _RowResult(
  'No answer from the machine. Check the session before retrying.',
  _Outcome.failed,
);

_RowResult _classify(SessionRestartResult r) {
  if (r.ok) return r.restarted ? _restarted : _alreadyFine;
  return switch (r.errorCode) {
    'MEMORY_OFF' => const _RowResult(
      'Memory was turned off. Nothing was restarted.',
      _Outcome.failed,
    ),
    'SCHEDULED_RUN' => const _RowResult(
      'A scheduled run is in progress. Its next run will use Memory.',
      _Outcome.failed,
    ),
    'TEARDOWN_TIMEOUT' => const _RowResult(
      "Didn't shut down in time. It's stopped; start it again.",
      _Outcome.stopped,
    ),
    'RESTART_FAILED' => const _RowResult(
      "Shut down but didn't start again. It's stopped; start it again.",
      _Outcome.stopped,
    ),
    _ => const _RowResult(
      "Couldn't restart. Nothing was changed.",
      _Outcome.failed,
    ),
  };
}

// Not the shared workStatusLabel: here the words answer whether a restart
// would interrupt the session, and "Unread" does not.
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
  late final Set<String> _ticked = {
    for (final s in widget.sessions)
      if (s.workStatus == AgentWorkStatus.done ||
          s.workStatus == AgentWorkStatus.unread)
        _rowKey(s),
  };
  final Map<String, _RowResult> _results = {};
  bool _running = false;

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
      _ticked.forEach(_results.remove);
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
          if (answers[i].locked) _ticked.remove(key);
        }
      });
    }
    if (!mounted) return;
    setState(() => _running = false);
    // Over every result, not just this run's: a stopped row from an earlier
    // attempt still owes the user its instruction.
    if (!_results.values.every((r) => r.ok)) return;
    final restarted = _results.values
        .where((r) => r.outcome == _Outcome.restarted)
        .length;
    final noops = _results.length - restarted;
    showAbToast(
      context,
      '${restarted == 1 ? 'Restarted 1 session.' : 'Restarted $restarted sessions.'}'
      '${noops > 0 ? ' $noops already had Memory.' : ''}',
    );
    Navigator.of(context).pop();
  }

  Widget _row(MemorySessionWithoutMemory s) {
    final t = CarbonTheme.of(context);
    final key = _rowKey(s);
    final ticked = _ticked.contains(key);
    final result = _results[key];
    final restarting = _running && ticked && result == null;
    final locked = result?.locked ?? false;
    final helper = t.typography.helper.copyWith(color: t.colors.textSecondary);
    return Padding(
      key: ValueKey(key),
      padding: const EdgeInsetsDirectional.symmetric(
        horizontal: CarbonSpacing.spacing05,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: CarbonCheckbox(
              value: ticked,
              onChanged: _running || locked ? null : (_) => _toggle(key),
              label: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    s.name,
                    style: t.typography.body.copyWith(
                      color: t.colors.textPrimary,
                    ),
                  ),
                  if (result != null)
                    Text(
                      result.text,
                      style: result.ok
                          ? helper
                          : helper.copyWith(color: t.colors.textError),
                    )
                  else ...[
                    Text(
                      '${s.projectLabel} · ${_statusLabel(s.workStatus)}',
                      style: helper,
                    ),
                    if (ticked && _isBusy(s.workStatus))
                      Text(
                        "Restarting interrupts what it's doing now.",
                        style: helper,
                      ),
                  ],
                ],
              ),
            ),
          ),
          if (!s.resumable) ...[
            const SizedBox(width: CarbonSpacing.spacing03),
            const CarbonTag(
              label: 'Starts a new conversation',
              size: CarbonTagSize.small,
            ),
          ],
          if (restarting) ...[
            const SizedBox(width: CarbonSpacing.spacing03),
            const CarbonInlineLoading(status: CarbonInlineLoadingStatus.active),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    final count = _ticked.length;
    return CarbonModal(
      title: 'Restart to use Memory',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            "These sessions were already running when Memory was turned on, so they can't use it. Restarting resumes each conversation with Memory.",
            style: t.typography.body.copyWith(color: t.colors.textSecondary),
          ),
          const SizedBox(height: CarbonSpacing.spacing05),
          CarbonLayerSurface(
            border: true,
            child: Builder(
              builder: (context) {
                final rule = CarbonTheme.of(
                  context,
                ).borderSubtle(CarbonLayer.of(context));
                return Column(
                  children: [
                    for (final (i, s) in widget.sessions.indexed) ...[
                      if (i > 0)
                        SizedBox(
                          height: CarbonBorders.hairline,
                          child: ColoredBox(color: rule),
                        ),
                      _row(s),
                    ],
                  ],
                );
              },
            ),
          ),
        ],
      ),
      actions: [
        CarbonModalAction(
          label: 'Cancel',
          kind: CarbonButtonKind.secondary,
          onPressed: () => Navigator.of(context).pop(),
        ),
        CarbonModalAction(
          label: _running
              ? 'Restarting…'
              : count == 1
              ? 'Restart 1 session'
              : 'Restart $count sessions',
          onPressed: _running || count == 0
              ? null
              : () => detached('Memory', 'restart failed', _restart),
        ),
      ],
    );
  }
}
