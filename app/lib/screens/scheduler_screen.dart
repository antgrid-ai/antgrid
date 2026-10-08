import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show RpcException;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../constants/breakpoints.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_chip.dart';
import '../design/widgets/ab_confirm_dialog.dart';
import '../design/widgets/ab_empty_state.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_menu.dart';
import '../design/widgets/ab_touch_sizing.dart';
import '../design/widgets/ab_inline_banner.dart';
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_segmented.dart';
import '../launcher/host_control_client.dart';
import '../models/scheduler.dart';
import '../models/session_target.dart';
import '../navigation/nav_controller.dart';
import '../navigation/nav_location.dart';
import '../providers/scheduler.dart';
import '../providers/scheduler_drafts.dart';
import '../providers/scheduler_timezone.dart';
import '../providers/sessions.dart';
import '../providers/ui_attention_providers.dart';
import '../util/detached.dart';
import '../utils/platform_utils.dart';
import '../widgets/drawer_entry_row.dart' show activateDrawerEntryById;
import '../widgets/scheduler/schedule_editor.dart';
import '../widgets/scheduler/scheduler_format.dart';
export '../widgets/scheduler/scheduler_format.dart' show schedulerTime;

class SchedulerScreen extends ConsumerStatefulWidget {
  const SchedulerScreen({super.key, this.onOpenDrawer});
  final VoidCallback? onOpenDrawer;
  @override
  ConsumerState<SchedulerScreen> createState() => _SchedulerScreenState();
}

class _SchedulerScreenState extends ConsumerState<SchedulerScreen>
    with WidgetsBindingObserver {
  SchedulerSnapshot? _snapshot;
  String? _error;
  String? _actionError;
  bool _loading = true;
  bool _busy = false;
  bool _runsTab = false;
  bool _editing = false;
  AgentSchedule? _editedSchedule;
  ScheduleRun? _feedbackRun;
  String? _focusedRunId;
  String? _runScheduleId;
  int _generation = 0;
  int? _refreshToken;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ref.invalidate(schedulerLocalTimezoneProvider);
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      detached('Scheduler', 'scheduler refresh failed', _refresh);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) detached('Scheduler', 'scheduler load failed', _refresh);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(schedulerLocalTimezoneProvider);
    }
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
        if (_feedbackRun != null) {
          _feedbackRun =
              snapshot.runs
                  .where((r) => r.id == _feedbackRun!.id)
                  .firstOrNull ??
              _feedbackRun;
          if (!snapshot.runs.any((r) => r.id == _feedbackRun!.id)) {
            _snapshot = SchedulerSnapshot(
              capabilities: snapshot.capabilities,
              projects: snapshot.projects,
              schedules: snapshot.schedules,
              runs: [_feedbackRun!, ...snapshot.runs],
            );
          }
        }
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
      final result = await request(method, params);
      if (!mounted || generation != _generation) return;
      if (method == 'scheduler.runNow' && result['run'] is Map) {
        final run = ScheduleRun.fromJson(
          (result['run'] as Map).cast<String, dynamic>(),
        );
        setState(() {
          _feedbackRun = run;
          final snapshot = _snapshot!;
          _snapshot = SchedulerSnapshot(
            capabilities: snapshot.capabilities,
            projects: snapshot.projects,
            schedules: snapshot.schedules,
            runs: [run, ...snapshot.runs.where((r) => r.id != run.id)],
          );
        });
      }
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

  void _viewRun(ScheduleRun run) => setState(() {
    _runsTab = true;
    _editing = false;
    _runScheduleId = run.scheduleId;
    _focusedRunId = run.id;
  });

  @override
  Widget build(BuildContext context) {
    final connected = ref.watch(schedulerConnectedProvider);
    final machine = ref.watch(schedulerTargetProvider);
    final machines = ref.watch(schedulerMachinesProvider);
    final localTimezone = ref.watch(schedulerLocalTimezoneProvider);
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
        _feedbackRun = null;
        _focusedRunId = null;
        _runScheduleId = null;
      });
      detached('Scheduler', 'machine change failed', _refresh);
    });
    final snapshot = _snapshot;
    ref.watch(schedulerDraftsProvider.select((drafts) => drafts.length));
    return LayoutBuilder(
      builder: (context, constraints) => AbTouchSizing(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!(_editing &&
                isMobilePlatform &&
                (constraints.maxHeight < kCompactBreakpoint ||
                    MediaQuery.viewInsetsOf(context).bottom > 0))) ...[
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
                        _runScheduleId = null;
                      }),
                    ),
                    AbIconButton(
                      icon: AbIcons.refresh,
                      tooltip: 'Refresh scheduler',
                      onTap: _busy
                          ? null
                          : () => detached(
                              'Scheduler',
                              'refresh failed',
                              _refresh,
                            ),
                    ),
                    AbButton(
                      label: 'Create schedule',
                      variant: AbButtonVariant.primary,
                      fontSize: AbTokens.fontBody,
                      fontWeight: FontWeight.w600,
                      leading: AbIcon(
                        AbIcons.add,
                        size: AbTokens.iconButtonGlyph,
                        color: context.antgrid.accentForeground,
                      ),
                      onTap:
                          _writable &&
                              (!localTimezone.isLoading ||
                                  ref.read(schedulerDraftsProvider).containsKey(
                                    (
                                      machine: machine ?? 'local',
                                      scheduleId: null,
                                    ),
                                  )) &&
                              ((snapshot!.projects.isNotEmpty &&
                                      snapshot
                                          .capabilities
                                          .agents
                                          .isNotEmpty) ||
                                  ref.read(schedulerDraftsProvider).containsKey(
                                    (
                                      machine: machine ?? 'local',
                                      scheduleId: null,
                                    ),
                                  ))
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
                padding: const EdgeInsets.symmetric(
                  horizontal: AbTokens.space12,
                ),
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
            ],
            if (_error != null)
              AbInlineBanner(text: _error!, color: context.antgrid.error),
            if (!_loading && !connected && _error == null)
              AbInlineBanner(
                text: 'Machine disconnected. Writes are disabled.',
                color: context.antgrid.textMuted,
              ),
            if (_actionError != null)
              Semantics(
                liveRegion: true,
                child: AbInlineBanner(
                  text: _actionError!,
                  color: context.antgrid.error,
                ),
              ),
            if (_feedbackRun case final run?)
              Padding(
                padding: const EdgeInsets.all(AbTokens.space12),
                child: Wrap(
                  spacing: AbTokens.space8,
                  runSpacing: AbTokens.space8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        run.status == 'skipped'
                            ? 'Run skipped: ${run.reason ?? 'No reason supplied by the machine'}'
                            : '${schedulerStatus(run.status)}${run.reason == null ? '' : ': ${run.reason}'}',
                        style: AbTokens.sansStyle(
                          color: run.status == 'skipped'
                              ? context.antgrid.warning
                              : context.antgrid.textPrimary,
                        ),
                      ),
                    ),
                    AbButton(label: 'View run', onTap: () => _viewRun(run)),
                  ],
                ),
              ),
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
                      machineId: machine ?? 'local',
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
        ),
      ),
    );
  }

  Widget _schedules(SchedulerSnapshot snapshot) {
    final drafts = ref.read(schedulerDraftsProvider);
    final machine = ref.read(schedulerTargetProvider) ?? 'local';
    final deletedDrafts = drafts.entries.where(
      (entry) =>
          entry.key.machine == machine &&
          entry.key.scheduleId != null &&
          !snapshot.schedules.any((s) => s.id == entry.key.scheduleId),
    );
    if (snapshot.schedules.isEmpty && deletedDrafts.isEmpty) {
      return const AbEmptyState(
        title: 'No schedules',
        subtitle: 'Create a schedule to submit a saved prompt on this machine.',
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= kMediumBreakpoint;
        return ListView(
          padding: const EdgeInsets.all(AbTokens.space12),
          children: [
            if (wide)
              _columns([
                _text('Name / Project', strong: true),
                _text('Schedule / Next', strong: true),
                _text('Run state', strong: true),
                _text('Actions', strong: true),
              ]),
            for (final schedule in snapshot.schedules)
              _scheduleRow(snapshot, schedule, wide),
            for (final entry in deletedDrafts)
              _card([
                _text('Deleted schedule draft: ${entry.value.values['name']}'),
                AbButton(
                  label: 'Open retained draft',
                  onTap: () => setState(() {
                    _editing = true;
                    // A draft's runAt may be unparsed wall-clock text, and the
                    // editor restores the time from the draft itself.
                    _editedSchedule = AgentSchedule.fromJson({
                      ...entry.value.values,
                      'runAt': null,
                      'id': entry.key.scheduleId,
                    });
                  }),
                ),
              ]),
          ],
        );
      },
    );
  }

  Widget _text(String value, {bool strong = false, bool muted = false}) =>
      Text(
        value,
        style: AbTokens.sansStyle(
          fontSize: AbTokens.fontSm,
          fontWeight: strong ? FontWeight.w600 : FontWeight.normal,
          color: strong
              ? context.antgrid.textPrimary
              : muted
              ? context.antgrid.textMuted
              : context.antgrid.textSecondary,
        ),
      );

  Widget _columns(List<Widget> cells, {bool inset = true}) => Padding(
    padding: inset ? const EdgeInsets.all(AbTokens.space12) : EdgeInsets.zero,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 3, child: cells[0]),
        const SizedBox(width: AbTokens.space12),
        Expanded(flex: 4, child: cells[1]),
        const SizedBox(width: AbTokens.space12),
        Expanded(flex: 3, child: cells[2]),
        const SizedBox(width: AbTokens.space12),
        Expanded(flex: 3, child: cells[3]),
      ],
    ),
  );

  Widget _scheduleRow(
    SchedulerSnapshot snapshot,
    AgentSchedule schedule,
    bool wide,
  ) {
    final active = schedulerActiveRun(snapshot.runs, schedule.id);
    final last = schedulerLastOccurrence(snapshot.runs, schedule.id);
    final now = DateTime.now();
    final oneOff = schedule.isOneOff
        ? schedulerOneOffState(schedule, now)
        : null;
    final provenance = schedulerProvenance(schedule);
    final identity = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AbTokens.space6,
      children: [
        _text(schedule.name, strong: true),
        _text(
          '${_projectName(snapshot, schedule.projectId)} · ${schedule.enabled ? 'Enabled' : 'Paused'}',
        ),
        if (ref.read(schedulerDraftsProvider).containsKey((
          machine: ref.read(schedulerTargetProvider) ?? 'local',
          scheduleId: schedule.id,
        )))
          _text('Editable draft retained'),
        if (provenance != null) _text(provenance),
      ],
    );
    final timing = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AbTokens.space6,
      children: [
        if (oneOff == null)
          _text(schedulerCadence(schedule.cron!, schedule.timezone))
        else
          _text(
            schedulerOneOffSummary(schedule, snapshot.runs, now),
            muted: oneOff == SchedulerOneOffState.finished,
          ),
        // An older bridge has no catch-up; the parsed default would misdescribe it.
        if (snapshot.capabilities.supportsCatchUp)
          _text(
            oneOff == null
                ? schedulerCatchUpSummary(schedule.catchUp)
                : schedulerOneOffCatchUpSummary(schedule.catchUp),
          ),
        if (oneOff != SchedulerOneOffState.finished)
          _text(
            'Next: ${schedule.enabled ? schedulerLocalTime(schedule.nextOccurrence, ref.read(schedulerLocalTimezoneProvider).value ?? _snapshot?.capabilities.timezone) : 'Paused'}',
          ),
      ],
    );
    final state = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AbTokens.space6,
      children: [
        if (active != null) _runStatus(active, prefix: 'Active run: '),
        if (last != null)
          _text('Last occurrence: ${schedulerStatus(last.status)}'),
        if (active == null && last == null) _text('Never run'),
      ],
    );
    final actions = Wrap(
      spacing: AbTokens.space6,
      runSpacing: AbTokens.space6,
      children: [
        if (active == null)
          _action(
            'Run now',
            schedule.name,
            () => _act('scheduler.runNow', {'id': schedule.id}),
          )
        else ...[
          _action(
            active.sessionId == null ? 'View run' : 'Open session',
            schedule.name,
            () async {
              if (active.sessionId == null) {
                _viewRun(active);
              } else {
                await _open(active);
              }
            },
          ),
          _action(
            'Stop run',
            schedule.name,
            () => _act('scheduler.stop', {'id': active.id}),
          ),
        ],
        if (oneOff == SchedulerOneOffState.finished ||
            oneOff == SchedulerOneOffState.pausedPassed)
          _action('Set a new time', schedule.name, () async => _editSchedule(schedule)),
        Builder(
          builder: (anchor) => Semantics(
            label: 'More actions for ${schedule.name}',
            child: AbIconButton(
              icon: AbIcons.more,
              tooltip: 'Actions for ${schedule.name}',
              onTap: _writable
                  ? () => detached(
                      'Scheduler',
                      'menu failed',
                      () => _scheduleMenu(anchor, schedule),
                    )
                  : null,
            ),
          ),
        ),
      ],
    );
    return _card(
      wide
          ? [
              _columns([identity, timing, state, actions], inset: false),
            ]
          : [identity, timing, state, actions],
    );
  }

  Widget _action(String label, String name, Future<void> Function() action) =>
      Semantics(
        label: '$label for $name',
        button: true,
        enabled: _writable,
        excludeSemantics: true,
        onTap: _writable
            ? () => detached('Scheduler', 'action failed', action)
            : null,
        child: AbButton(
          label: label,
          compact: true,
          onTap: _writable
              ? () => detached('Scheduler', 'action failed', action)
              : null,
        ),
      );

  void _editSchedule(AgentSchedule schedule) => setState(() {
    _editing = true;
    _editedSchedule = schedule;
  });

  Future<void> _scheduleMenu(
    BuildContext anchor,
    AgentSchedule schedule,
  ) async {
    final rect = abMenuAnchorRect(anchor);
    if (rect == null) return;
    final machine = ref.read(schedulerTargetProvider);
    final needsNewTime =
        schedule.isOneOff &&
        const {
          SchedulerOneOffState.finished,
          SchedulerOneOffState.pausedPassed,
        }.contains(schedulerOneOffState(schedule, DateTime.now()));
    final selected = await showAbMenu<String>(
      context: anchor,
      anchorRect: rect,
      header: schedule.name,
      entries: [
        AbMenuItem(
          label: needsNewTime ? 'Set a new time' : 'Edit',
          value: 'edit',
          icon: AbIcons.edit,
        ),
        // Resuming a one-off whose time has passed is refused by the bridge;
        // the new-time editor is the only way back.
        if (!needsNewTime)
          AbMenuItem(
            label: schedule.enabled ? 'Pause' : 'Resume',
            value: 'pause',
          ),
        const AbMenuItem(
          label: 'Delete',
          value: 'delete',
          icon: AbIcons.trash,
          danger: true,
        ),
      ],
    );
    if (!mounted ||
        machine != ref.read(schedulerTargetProvider) ||
        !_writable) {
      return;
    }
    switch (selected) {
      case 'edit':
        _editSchedule(schedule);
      case 'pause':
        await _act('scheduler.update', {
          'id': schedule.id,
          'patch': {'enabled': !schedule.enabled},
        });
      case 'delete':
        await _delete(schedule);
    }
  }

  Widget _runStatus(ScheduleRun run, {String prefix = ''}) {
    final color = switch (run.status) {
      'needs-input' => context.antgrid.warning,
      'failed' => context.antgrid.error,
      'completed' => context.antgrid.success,
      'preparing' || 'running' => context.antgrid.accent,
      _ => context.antgrid.textSecondary,
    };
    final icon = switch (run.status) {
      'needs-input' => AbIcons.bell,
      'failed' => AbIcons.error,
      'completed' => AbIcons.check,
      'preparing' => AbIcons.refresh,
      'running' => AbIcons.start,
      _ => AbIcons.info,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AbIcon(icon, color: color),
        const SizedBox(width: AbTokens.space6),
        Flexible(
          child: Text(
            '$prefix${schedulerStatus(run.status)}',
            style: AbTokens.sansStyle(
              fontSize: AbTokens.fontSm,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
      ],
    );
  }

  Widget _runs(SchedulerSnapshot snapshot) {
    final runs = [
      ...snapshot.runs.where(
        (r) => _runScheduleId == null || r.scheduleId == _runScheduleId,
      ),
    ];
    if (_feedbackRun case final run?
        when !runs.any((r) => r.id == run.id) &&
            (_runScheduleId == null || run.scheduleId == _runScheduleId)) {
      runs.insert(0, run);
    }
    runs.sort(
      (a, b) => a.id == b.id
          ? 0
          : a.id == _focusedRunId
          ? -1
          : b.id == _focusedRunId
          ? 1
          : b.occurrenceAt.compareTo(a.occurrenceAt),
    );
    if (runs.isEmpty) return const AbEmptyState(title: 'No runs yet');
    return ListView(
      padding: const EdgeInsets.all(AbTokens.space12),
      children: [
        if (_runScheduleId != null)
          Padding(
            padding: const EdgeInsets.only(bottom: AbTokens.space8),
            child: AbButton(
              label: 'Show all runs',
              onTap: () => setState(() {
                _runScheduleId = null;
                _focusedRunId = null;
              }),
            ),
          ),
        for (final run in runs) _runCard(snapshot, run),
      ],
    );
  }

  Widget _runCard(SchedulerSnapshot snapshot, ScheduleRun run) {
    final schedule = snapshot.schedules
        .where((s) => s.id == run.scheduleId)
        .firstOrNull;
    final name =
        schedule?.name ??
        run.scheduleName ??
        'Deleted schedule (${run.scheduleId})';
    final zone =
        run.timezone ?? schedule?.timezone ?? snapshot.capabilities.timezone;
    final localZone =
        ref.read(schedulerLocalTimezoneProvider).value ??
        snapshot.capabilities.timezone;
    return _card(
      [
        _text(name, strong: true),
        _runStatus(run),
        _text(schedulerLocalTime(run.occurrenceAt, localZone)),
        if (zone != localZone)
          _text('Schedule time: ${schedulerTime(run.occurrenceAt, zone)}'),
        _text('UTC: ${schedulerTime(run.occurrenceAt)}'),
        if (run.trigger == 'missed') ...[
          _text(schedulerMissedLabel(run.missedCount)),
          // A one-occurrence record's interval is a single instant, already shown above.
          if (run.missedUntil != null && run.missedUntil != run.occurrenceAt)
            _text(
              '${schedulerLocalTime(run.occurrenceAt, localZone)} – ${schedulerLocalTime(run.missedUntil, localZone)}',
            ),
        ] else
          _text(
            '${schedulerTrigger(run.trigger)} · Duration: ${schedulerDuration(run.duration)}',
          ),
        if (run.status == 'completed') _text('The prompt turn ended.'),
        if (run.reason != null) _text(run.reason!),
        Wrap(
          spacing: AbTokens.space6,
          runSpacing: AbTokens.space6,
          children: [
            if (run.sessionId != null)
              _action('Open session', name, () => _open(run)),
            if (run.active)
              _action(
                'Stop run',
                name,
                () => _act('scheduler.stop', {'id': run.id}),
              ),
          ],
        ),
      ],
      highlighted: run.id == _focusedRunId,
      key: ValueKey('scheduler-run-${run.id}'),
    );
  }

  Widget _card(List<Widget> children, {bool highlighted = false, Key? key}) =>
      Container(
        key: key,
        margin: const EdgeInsets.only(bottom: AbTokens.space8),
        padding: const EdgeInsets.all(AbTokens.space12),
        decoration: BoxDecoration(
          color: highlighted
              ? context.antgrid.bgSelected
              : context.antgrid.bgSurface,
          border: Border.all(
            color: highlighted
                ? context.antgrid.accent
                : context.antgrid.borderSubtle,
          ),
          borderRadius: AbTokens.borderRadius5,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: AbTokens.space6,
          children: children,
        ),
      );
}

ScheduleRun? schedulerActiveRun(List<ScheduleRun> runs, String scheduleId) =>
    runs.where((r) => r.scheduleId == scheduleId && r.active).firstOrNull;
ScheduleRun? schedulerLastOccurrence(
  List<ScheduleRun> runs,
  String scheduleId,
) {
  final terminal =
      runs.where((r) => r.scheduleId == scheduleId && !r.active).toList()
        ..sort((a, b) => b.occurrenceAt.compareTo(a.occurrenceAt));
  return terminal.firstOrNull;
}

String _projectName(SchedulerSnapshot snapshot, String id) =>
    snapshot.projects.where((p) => p.projectId == id).firstOrNull?.name ?? id;

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
