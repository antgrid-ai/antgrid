import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show RpcException;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_chip.dart';
import '../design/widgets/ab_confirm_dialog.dart';
import '../design/widgets/ab_empty_state.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_inline_banner.dart';
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_segmented.dart';
import '../launcher/host_control_client.dart';
import '../models/scheduler.dart';
import '../models/session_target.dart';
import '../navigation/nav_controller.dart';
import '../navigation/nav_location.dart';
import '../providers/scheduler.dart';
import '../providers/sessions.dart';
import '../providers/ui_attention_providers.dart';
import '../util/detached.dart';
import '../utils/platform_utils.dart';
import '../widgets/drawer_entry_row.dart' show activateDrawerEntryById;
import '../widgets/scheduler/schedule_editor.dart';

class SchedulerScreen extends ConsumerStatefulWidget {
  const SchedulerScreen({super.key, this.onOpenDrawer});
  final VoidCallback? onOpenDrawer;
  @override
  ConsumerState<SchedulerScreen> createState() => _SchedulerScreenState();
}

class _SchedulerScreenState extends ConsumerState<SchedulerScreen> {
  SchedulerSnapshot? _snapshot;
  String? _error;
  String? _actionError;
  bool _loading = true;
  bool _busy = false;
  bool _runsTab = false;
  bool _editing = false;
  AgentSchedule? _editedSchedule;
  int _generation = 0;
  int? _refreshToken;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      detached('Scheduler', 'scheduler refresh failed', _refresh);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) detached('Scheduler', 'scheduler load failed', _refresh);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!mounted || _busy || _refreshToken != null) return;
    final generation = ++_generation;
    _refreshToken = generation;
    final request = ref.read(schedulerRequestProvider);
    try {
      final snapshot = await SchedulerSnapshot.load(request);
      if (!mounted || generation != _generation) return;
      setState(() {
        _snapshot = snapshot;
        _error = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = schedulerError(error);
        _loading = false;
      });
    } finally {
      if (_refreshToken == generation) _refreshToken = null;
    }
  }

  bool get _writable =>
      ref.read(schedulerConnectedProvider) &&
      !_loading &&
      !_busy &&
      _error == null &&
      _snapshot?.capabilities.supported == true;

  Future<void> _act(String method, Map<String, dynamic> params) async {
    if (!_writable) return;
    final request = ref.read(schedulerRequestProvider);
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      await request(method, params);
      if (!mounted || generation != _generation) return;
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _actionError = 'Action failed: $error');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _busy = false);
        await _refresh();
      }
    }
  }

  Future<void> _delete(AgentSchedule schedule) async {
    final machine = ref.read(schedulerTargetProvider);
    final confirmed = await AbConfirmDialog.show(
      context: context,
      title: 'Delete schedule',
      body:
          'Stop future occurrences of "${schedule.name}"? Run history, sessions, branch and worktree are retained. An active run will continue.',
      confirmLabel: 'Delete schedule',
      destructive: true,
    );
    if (!mounted ||
        !confirmed ||
        machine != ref.read(schedulerTargetProvider)) {
      return;
    }
    await _act('scheduler.delete', {'id': schedule.id});
  }

  Future<void> _open(ScheduleRun run) async {
    final sessionId = run.sessionId;
    if (sessionId == null) return;
    final container = ref.container;
    final machine = container.read(schedulerTargetProvider);
    final generation = ++_generation;
    final target = machine == null
        ? LocalProject(run.projectId)
        : RemoteProject(machineUuid: machine, projectId: run.projectId);
    container.read(pendingActiveSessionIdProvider.notifier).set(sessionId);
    final opened = await activateDrawerEntryById(
      context,
      container,
      target.registrationId,
    );
    if (!mounted ||
        machine != container.read(schedulerTargetProvider) ||
        generation != _generation) {
      return;
    }
    if (!opened) {
      container.read(pendingActiveSessionIdProvider.notifier).set(null);
      if (mounted) {
        setState(
          () => _error =
              'Project unavailable. Open the project on the target machine first.',
        );
      }
      return;
    }
    container
        .read(workbenchSurfaceProvider.notifier)
        .set(WorkbenchSurface.workspace);
    container
        .read(navControllerProvider.notifier)
        .commit(
          NavLocation(
            target: target,
            surface: WorkbenchSurface.workspace,
            sessionId: sessionId,
          ),
        );
  }

  @override
  Widget build(BuildContext context) {
    final connected = ref.watch(schedulerConnectedProvider);
    final machine = ref.watch(schedulerTargetProvider);
    final machines = ref.watch(schedulerMachinesProvider);
    ref.listen(schedulerTargetProvider, (_, _) {
      _generation++;
      _refreshToken = null;
      setState(() {
        _snapshot = null;
        _error = null;
        _actionError = null;
        _loading = true;
        _busy = false;
        _editing = false;
      });
      detached('Scheduler', 'machine change failed', _refresh);
    });
    final snapshot = _snapshot;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(AbTokens.space12),
          child: Wrap(
            spacing: AbTokens.space8,
            runSpacing: AbTokens.space8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (isMobilePlatform && widget.onOpenDrawer != null)
                AbIconButton(
                  icon: AbIcons.menu,
                  tooltip: 'Open drawer',
                  onTap: widget.onOpenDrawer,
                ),
              Text(
                'Scheduler',
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontLg,
                  fontWeight: FontWeight.w600,
                ),
              ),
              AbSegmented<bool>(
                segments: const [
                  AbSegment(value: false, label: 'Schedules'),
                  AbSegment(value: true, label: 'Runs'),
                ],
                selected: _runsTab,
                onSelect: (value) => setState(() {
                  _runsTab = value;
                  _editing = false;
                }),
              ),
              AbIconButton(
                icon: AbIcons.refresh,
                tooltip: 'Refresh scheduler',
                onTap: _busy
                    ? null
                    : () => detached('Scheduler', 'refresh failed', _refresh),
              ),
              AbButton(
                label: 'Create schedule',
                onTap:
                    _writable &&
                        snapshot!.projects.isNotEmpty &&
                        snapshot.capabilities.agents.isNotEmpty
                    ? () => setState(() {
                        _editing = true;
                        _editedSchedule = null;
                      })
                    : null,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AbTokens.space12),
          child: Wrap(
            spacing: AbTokens.space6,
            runSpacing: AbTokens.space6,
            children: [
              for (final entry in machines.entries)
                AbChip.choice(
                  label: entry.value,
                  selected: entry.key == (machine ?? 'local'),
                  onTap: () => ref
                      .read(schedulerMachineProvider.notifier)
                      .set(entry.key),
                ),
            ],
          ),
        ),
        const SizedBox(height: AbTokens.space8),
        AbInlineBanner(
          text:
              'The target desktop app must remain open. Each run starts a fresh conversation; schedule worktrees are reused. Completed means the prompt turn ended.',
          color: context.antgrid.textMuted,
        ),
        if (_error != null)
          AbInlineBanner(text: _error!, color: context.antgrid.error),
        if (!_loading && !connected && _error == null)
          AbInlineBanner(
            text: 'Machine disconnected. Writes are disabled.',
            color: context.antgrid.textMuted,
          ),
        if (_actionError != null)
          AbInlineBanner(text: _actionError!, color: context.antgrid.error),
        if (snapshot?.capabilities.error != null)
          AbInlineBanner(
            text: snapshot!.capabilities.error!,
            color: snapshot.capabilities.supported
                ? context.antgrid.warning
                : context.antgrid.error,
          ),
        Expanded(
          child: _loading
              ? const Center(
                  child: AbLoading(message: 'Connecting to scheduler…'),
                )
              : snapshot == null
              ? AbEmptyState(
                  title: machines.isEmpty
                      ? 'No connected machines'
                      : 'Machine unavailable',
                  subtitle: _error,
                )
              : !snapshot.capabilities.supported
              ? const AbEmptyState(
                  title: 'Scheduler unavailable',
                  subtitle:
                      'Upgrade the target bridge and keep its desktop app open to run schedules.',
                )
              : _editing
              ? ScheduleEditor(
                  key: ValueKey(
                    '${machine ?? 'local'}:${_editedSchedule?.id ?? 'new'}',
                  ),
                  snapshot: snapshot,
                  schedule: _editedSchedule,
                  request: ref.watch(schedulerRequestProvider),
                  writable: _writable,
                  onClose: () => setState(() => _editing = false),
                  onSaved: () {
                    setState(() => _editing = false);
                    detached(
                      'Scheduler',
                      'refresh after save failed',
                      _refresh,
                    );
                  },
                )
              : _runsTab
              ? _runs(snapshot)
              : _schedules(snapshot),
        ),
      ],
    );
  }

  Widget _schedules(SchedulerSnapshot snapshot) {
    if (snapshot.schedules.isEmpty) {
      return const AbEmptyState(
        title: 'No schedules',
        subtitle: 'Create a schedule to submit a saved prompt on this machine.',
      );
    }
    return ListView(
      padding: const EdgeInsets.all(AbTokens.space12),
      children: [
        for (final schedule in snapshot.schedules)
          _card([
            Text(
              schedule.name,
              style: AbTokens.sansStyle(fontWeight: FontWeight.w600),
            ),
            Text(
              '${_projectName(snapshot, schedule.projectId)} · ${schedule.enabled ? 'Enabled' : 'Paused'}',
              style: AbTokens.sansStyle(color: context.antgrid.textSecondary),
            ),
            Text(
              '${schedule.cron} · ${schedule.timezone}',
              style: AbTokens.monoStyle(fontSize: AbTokens.fontSm),
            ),
            Text(
              'Next: ${schedule.enabled ? schedulerTime(schedule.nextOccurrence) : 'Paused'} · Last: ${_lastResult(snapshot, schedule)}',
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontSm,
                color: context.antgrid.textMuted,
              ),
            ),
            Wrap(
              spacing: AbTokens.space6,
              runSpacing: AbTokens.space6,
              children: [
                AbButton(
                  label: 'Edit',
                  compact: true,
                  onTap: _writable
                      ? () => setState(() {
                          _editing = true;
                          _editedSchedule = schedule;
                        })
                      : null,
                ),
                AbButton(
                  label: schedule.enabled ? 'Pause' : 'Resume',
                  compact: true,
                  onTap: _writable
                      ? () => detached(
                          'Scheduler',
                          'pause failed',
                          () => _act('scheduler.update', {
                            'id': schedule.id,
                            'patch': {'enabled': !schedule.enabled},
                          }),
                        )
                      : null,
                ),
                AbButton(
                  label: 'Run now',
                  compact: true,
                  onTap: _writable
                      ? () => detached(
                          'Scheduler',
                          'run now failed',
                          () => _act('scheduler.runNow', {'id': schedule.id}),
                        )
                      : null,
                ),
                AbButton(
                  label: 'Delete',
                  compact: true,
                  onTap: _writable
                      ? () => detached(
                          'Scheduler',
                          'delete failed',
                          () => _delete(schedule),
                        )
                      : null,
                ),
              ],
            ),
          ]),
      ],
    );
  }

  Widget _runs(SchedulerSnapshot snapshot) {
    if (snapshot.runs.isEmpty) return const AbEmptyState(title: 'No runs yet');
    return ListView(
      padding: const EdgeInsets.all(AbTokens.space12),
      children: [
        for (final run in snapshot.runs)
          _card([
            Text(
              snapshot.schedules
                      .where((s) => s.id == run.scheduleId)
                      .firstOrNull
                      ?.name ??
                  run.scheduleName ??
                  'Deleted schedule (${run.scheduleId})',
              style: AbTokens.sansStyle(fontWeight: FontWeight.w600),
            ),
            Text(
              '${schedulerStatus(run.status)} · ${schedulerTime(run.occurrenceAt)}',
              style: AbTokens.sansStyle(),
            ),
            Text(
              '${run.trigger} · Duration: ${run.duration == null ? '—' : '${run.duration!.inSeconds}s'}',
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontSm,
                color: context.antgrid.textMuted,
              ),
            ),
            if (run.reason != null)
              Text(
                run.reason!,
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontSm,
                  color: context.antgrid.textSecondary,
                ),
              ),
            Wrap(
              spacing: AbTokens.space6,
              runSpacing: AbTokens.space6,
              children: [
                if (run.sessionId != null)
                  AbButton(
                    label: 'Open session',
                    compact: true,
                    onTap: _writable
                        ? () => detached(
                            'Scheduler',
                            'open session failed',
                            () => _open(run),
                          )
                        : null,
                  ),
                if (run.active)
                  AbButton(
                    label: 'Stop run',
                    compact: true,
                    onTap: _writable
                        ? () => detached(
                            'Scheduler',
                            'stop run failed',
                            () => _act('scheduler.stop', {'id': run.id}),
                          )
                        : null,
                  ),
              ],
            ),
          ]),
      ],
    );
  }

  Widget _card(List<Widget> children) => Container(
    margin: const EdgeInsets.only(bottom: AbTokens.space8),
    padding: const EdgeInsets.all(AbTokens.space12),
    decoration: BoxDecoration(
      color: context.antgrid.bgSurface,
      border: Border.all(color: context.antgrid.borderSubtle),
      borderRadius: AbTokens.borderRadius5,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AbTokens.space6,
      children: children,
    ),
  );
}

String _projectName(SchedulerSnapshot snapshot, String id) =>
    snapshot.projects.where((p) => p.projectId == id).firstOrNull?.name ?? id;
String _lastResult(SchedulerSnapshot snapshot, AgentSchedule schedule) =>
    schedulerStatus(
      snapshot.runs
              .where((r) => r.scheduleId == schedule.id)
              .firstOrNull
              ?.status ??
          schedule.lastResult ??
          'Never run',
    );
String schedulerTime(DateTime? instant) => instant == null
    ? '—'
    : instant
          .toUtc()
          .toIso8601String()
          .replaceFirst('T', ' ')
          .replaceFirst('.000Z', ' UTC');
String schedulerStatus(String status) => switch (status) {
  'preparing' => 'Preparing',
  'running' => 'Running',
  'needs-input' => 'Needs input',
  'completed' => 'Completed',
  'failed' => 'Failed',
  'interrupted' => 'Interrupted',
  'skipped' => 'Skipped',
  _ => status,
};
String schedulerError(Object error) {
  final code = error is RpcException
      ? error.code
      : error is HostControlException
      ? error.code
      : '';
  if (const {
    'E_UNKNOWN_METHOD',
    'UNKNOWN_VERB',
    'UNKNOWN_TYPE',
    'INVALID_REQUEST',
  }.contains(code)) {
    return 'Upgrade the target bridge to use Scheduler.';
  }
  return 'Machine unavailable or scheduler request failed: $error';
}
