import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show RpcException;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_colors.dart';
import '../constants/breakpoints.dart';
import '../design/ab_icons.dart';
import '../design/ab_status_tone.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_button.dart';
import '../design/widgets/ab_confirm_dialog.dart';
import '../design/widgets/ab_empty_state.dart';
import '../design/widgets/ab_agent_mark.dart';
import '../design/widgets/ab_branch_pill.dart';
import '../design/widgets/ab_icon_button.dart';
import '../design/widgets/ab_icon.dart';
import '../design/widgets/ab_menu.dart';
import '../design/widgets/ab_section_header.dart';
import '../design/widgets/ab_status_dot.dart';
import '../design/widgets/ab_switch.dart';
import '../design/widgets/ab_inline_banner.dart';
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_segmented.dart';
import '../launcher/host_control_client.dart';
import '../models/scheduler.dart';
import '../models/session_target.dart';
import '../navigation/nav_controller.dart';
import '../navigation/nav_location.dart';
import '../providers/agent_catalog.dart';
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
import '../widgets/scheduler/scheduler_lanes.dart';
import '../widgets/scheduler/scheduler_run_squares.dart';
import '../widgets/scheduler/scheduler_runs_view.dart';
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
        _error = schedulerError(error, machineName: _machineName);
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
          "\"${schedule.name}\" won't run again. Its runs, sessions and worktree stay. A run in progress finishes.",
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

  String get _machineName {
    final machines = ref.read(schedulerMachinesProvider);
    return machines[ref.read(schedulerTargetProvider) ?? 'local'] ??
        'this machine';
  }

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
    final machineName = machines[machine ?? 'local'] ?? 'this machine';
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= kMediumBreakpoint;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!(_editing && !wide))
              _header(
                wide: wide,
                machines: machines,
                machine: machine ?? 'local',
                machineName: machineName,
                connected: connected,
                onNew: _newScheduleTap(snapshot, machine, localTimezone),
              ),
            if (_error != null)
              AbInlineBanner(text: _error!, color: context.antgrid.error),
            if (!_loading && !connected && _error == null)
              AbInlineBanner(
                text:
                    '$machineName is offline. Changes are paused until it reconnects.',
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
                            : '${schedulerRunStatusWord(run.status, trigger: run.trigger)}${run.reason == null ? '' : ': ${run.reason}'}',
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
                      child: AbLoading(message: 'Loading schedules…'),
                    )
                  : snapshot == null
                  ? AbEmptyState(
                      title: machines.isEmpty
                          ? 'No connected machines'
                          : 'Machine unavailable',
                      subtitle: _error,
                    )
                  : !snapshot.capabilities.supported
                  ? AbEmptyState(
                      title: 'Scheduler unavailable',
                      subtitle:
                          'Update Antgrid on $machineName to use the scheduler.',
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
                  ? _runs(snapshot, wide)
                  : _schedules(snapshot, wide),
            ),
          ],
        );
      },
    );
  }

  VoidCallback? _newScheduleTap(
    SchedulerSnapshot? snapshot,
    String? machine,
    AsyncValue<String?> localTimezone,
  ) {
    final hasDraft = ref.read(schedulerDraftsProvider).containsKey((
      machine: machine ?? 'local',
      scheduleId: null,
    ));
    final ready =
        _writable &&
        (!localTimezone.isLoading || hasDraft) &&
        ((snapshot!.projects.isNotEmpty &&
                snapshot.capabilities.agents.isNotEmpty) ||
            hasDraft);
    if (!ready) return null;
    return () => setState(() {
      _editing = true;
      _editedSchedule = null;
    });
  }

  Widget _header({
    required bool wide,
    required Map<String, String> machines,
    required String machine,
    required String machineName,
    required bool connected,
    required VoidCallback? onNew,
  }) {
    final p = context.antgrid;
    final title = Text(
      'Scheduler',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AbTokens.sansStyle(
        fontSize: AbTokens.fontLg,
        fontWeight: FontWeight.w600,
      ),
    );
    final segmented = AbSegmented<bool>(
      expand: !wide,
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
    );
    void openMachineMenu(BuildContext anchor) => detached(
      'Scheduler',
      'machine menu failed',
      () => _machineMenu(anchor, machines, machine),
    );
    final machineButton = machines.isEmpty
        ? null
        : ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: AbTokens.space24 * (wide ? 10 : 6),
            ),
            child: Builder(
              builder: (anchor) => Semantics(
                label: 'Machine: $machineName, change',
                button: true,
                excludeSemantics: true,
                onTap: () => openMachineMenu(anchor),
                child: AbButton(
                  label: machineName,
                  wrapLabel: true,
                  maxLines: 1,
                  leading: AbStatusDot(
                    tone: connected ? AbStatusTone.success : AbStatusTone.muted,
                  ),
                  trailing: AbIcon(
                    AbIcons.chevronDown,
                    size: AbTokens.fontSm,
                    color: p.textMuted,
                  ),
                  onTap: () => openMachineMenu(anchor),
                ),
              ),
            ),
          );
    final refresh = AbIconButton(
      icon: AbIcons.refresh,
      tooltip: 'Refresh',
      onTap: _busy
          ? null
          : () => detached('Scheduler', 'refresh failed', _refresh),
    );
    if (wide) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          AbTokens.space24,
          AbTokens.space16,
          AbTokens.space24,
          AbTokens.space12,
        ),
        child: Row(
          spacing: AbTokens.space12,
          children: [
            title,
            if (!_editing) segmented,
            const Spacer(),
            ?machineButton,
            refresh,
            if (!_editing)
              AbButton(
                label: 'New schedule',
                variant: AbButtonVariant.primary,
                fontSize: AbTokens.fontMd,
                fontWeight: FontWeight.w600,
                leading: AbIcon(
                  AbIcons.add,
                  size: AbTokens.iconButtonGlyph,
                  color: p.accentForeground,
                ),
                onTap: onNew,
              ),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AbTokens.space8,
            AbTokens.space8,
            AbTokens.space8,
            AbTokens.space4,
          ),
          child: Row(
            spacing: AbTokens.space4,
            children: [
              if (isMobilePlatform && widget.onOpenDrawer != null)
                AbIconButton(
                  icon: AbIcons.menu,
                  tooltip: 'Open drawer',
                  onTap: widget.onOpenDrawer,
                )
              else
                const SizedBox(width: AbTokens.space8),
              Expanded(child: title),
              if (machineButton != null) Flexible(child: machineButton),
              AbIconButton(
                icon: AbIcons.add,
                tooltip: 'New schedule',
                tone: AbIconButtonTone.accent,
                onTap: onNew,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AbTokens.space16,
            AbTokens.space4,
            AbTokens.space16,
            AbTokens.space12,
          ),
          child: SizedBox(width: double.infinity, child: segmented),
        ),
      ],
    );
  }

  Future<void> _machineMenu(
    BuildContext anchor,
    Map<String, String> machines,
    String current,
  ) async {
    final rect = abMenuAnchorRect(anchor);
    if (rect == null) return;
    final picked = await showAbMenu<String>(
      context: anchor,
      anchorRect: rect,
      entries: [
        for (final entry in machines.entries)
          AbMenuItem(
            label: entry.value,
            value: entry.key,
            icon: entry.key == current ? AbIcons.check : null,
          ),
      ],
    );
    if (!mounted || picked == null) return;
    ref.read(schedulerMachineProvider.notifier).set(picked);
  }

  Widget _schedules(SchedulerSnapshot snapshot, bool wide) {
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
        subtitle: 'Send a saved prompt to an agent on a timer.',
      );
    }
    final now = DateTime.now();
    final viewerZone =
        ref.read(schedulerLocalTimezoneProvider).value ??
        snapshot.capabilities.timezone;
    bool resting(AgentSchedule s) =>
        !s.enabled ||
        (s.isOneOff &&
            schedulerOneOffState(s, now) == SchedulerOneOffState.finished);
    final live = [
      for (final s in snapshot.schedules)
        if (!resting(s)) s,
    ];
    final rest = [
      for (final s in snapshot.schedules)
        if (resting(s)) s,
    ];
    final p = context.antgrid;

    Widget group(List<AgentSchedule> schedules, {required bool muted}) =>
        Container(
          decoration: BoxDecoration(
            color: p.bgSurface,
            border: Border.all(color: p.borderDefault),
            borderRadius: AbTokens.borderRadius8,
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (wide && !muted) _tableHeader(),
              for (final (i, s) in schedules.indexed)
                _divided(
                  divider: i > 0 || (wide && !muted),
                  child: wide
                      ? _scheduleRow(snapshot, s, now, viewerZone)
                      : _phoneRow(snapshot, s, now, viewerZone),
                ),
            ],
          ),
        );

    final padding = wide
        ? const EdgeInsets.fromLTRB(
            AbTokens.space24,
            AbTokens.space4,
            AbTokens.space24,
            AbTokens.space24,
          )
        : const EdgeInsets.fromLTRB(
            AbTokens.space16,
            0,
            AbTokens.space16,
            AbTokens.space16,
          );
    final summary = schedulerHorizonSummary(snapshot.schedules, now);
    final attention = [
      for (final s in live)
        if (schedulerActiveRun(snapshot.runs, s.id) case final run?
            when run.status == 'needs-input')
          (schedule: s, run: run),
    ];
    // The strip carries the viewer's zone itself; with no strip, say it here.
    final stripShown =
        wide && schedulerLanes(snapshot.schedules, now).lanes.isNotEmpty;
    // The attention card already stands for these on the phone.
    final listed = wide
        ? live
        : [
            for (final s in live)
              if (!attention.any((a) => a.schedule.id == s.id)) s,
          ];
    return ListView(
      padding: padding,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: wide ? AbTokens.space16 : AbTokens.space12,
          children: [
            if (wide)
              SchedulerLaneStrip(
                schedules: snapshot.schedules,
                now: now,
                viewerZone: viewerZone,
              )
            else ...[
              if (summary.next case final next?) _nextCard(next, summary, now),
              for (final item in attention)
                _attentionCard(item.schedule, item.run, now),
            ],
            if (!stripShown)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AbTokens.space4,
                ),
                child: _label('Times in $viewerZone'),
              ),
            if (listed.isNotEmpty) group(listed, muted: false),
            if (rest.isNotEmpty) ...[
              AbSectionHeader(
                label: 'Paused and finished',
                count: rest.length,
                padding: const EdgeInsets.only(
                  left: AbTokens.space4,
                  top: AbTokens.space4,
                ),
              ),
              group(rest, muted: true),
            ],
            for (final entry in deletedDrafts)
              _card([
                _label('Deleted schedule draft: ${entry.value.values['name']}'),
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
        ),
      ],
    );
  }

  Widget _divided({required bool divider, required Widget child}) =>
      DecoratedBox(
        decoration: BoxDecoration(
          border: divider
              ? Border(top: BorderSide(color: context.antgrid.borderDefault))
              : null,
        ),
        child: child,
      );

  Widget _label(
    String value, {
    double size = AbTokens.fontSm,
    Color? color,
    FontWeight weight = FontWeight.normal,
    bool mono = false,
    int maxLines = 1,
  }) {
    final c = color ?? context.antgrid.textSecondary;
    return Text(
      value,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: mono
          ? AbTokens.monoStyle(fontSize: size, color: c, fontWeight: weight)
          : AbTokens.sansStyle(fontSize: size, color: c, fontWeight: weight),
    );
  }

  static const _actionsWidth = 344.0;

  Widget _tableHeader() {
    Widget cell(String label, int flex) => Expanded(
      flex: flex,
      child: AbSectionHeader(label: label, padding: EdgeInsets.zero),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space16,
        vertical: AbTokens.space8,
      ),
      child: Row(
        spacing: AbTokens.space16,
        children: [
          const SizedBox(width: AbTokens.dotSizeMd),
          cell('Schedule', 24),
          cell('Repeats', 12),
          cell('Next run', 11),
          cell('Recent runs', 12),
          const SizedBox(
            width: _actionsWidth,
            child: Align(
              alignment: Alignment.centerRight,
              child: IntrinsicWidth(
                child: AbSectionHeader(
                  label: 'Active',
                  padding: EdgeInsets.zero,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _hasDraft(AgentSchedule s) =>
      ref.read(schedulerDraftsProvider).containsKey((
        machine: ref.read(schedulerTargetProvider) ?? 'local',
        scheduleId: s.id,
      ));

  String? _by(AgentSchedule s) {
    final who =
        s.editedBySessionName ?? s.authorSessionName ?? s.authorSessionId;
    return who == null ? null : 'by $who';
  }

  Widget _badge(String label, {Color? color}) {
    final p = context.antgrid;
    final c = color ?? p.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space6,
        vertical: AbTokens.space2,
      ),
      decoration: BoxDecoration(
        border: Border.all(
          color: color == null ? p.borderStrong : c.withValues(alpha: 0.45),
        ),
        borderRadius: AbTokens.borderRadius3,
      ),
      child: Text(
        label,
        style: AbTokens.sansStyle(
          fontSize: AbTokens.fontXs,
          fontWeight: FontWeight.w500,
          color: c,
        ),
      ),
    );
  }

  List<Widget> _badges(SchedulerSnapshot snapshot, AgentSchedule s) {
    final p = context.antgrid;
    final mode = s.mode == 'chat' && s.chatMode != null
        ? snapshot.capabilities.chatModes[s.agentId]
                  ?.where((m) => m.id == s.chatMode)
                  .firstOrNull
                  ?.name ??
              s.chatMode
        : null;
    final by = _by(s);
    return [
      ?(mode == null ? null : _badge(mode)),
      if (s.approvalPolicy == 'bypass') _badge('Bypass', color: p.warning),
      if (s.workspace == 'worktree' && s.baseBranch != null)
        AbBranchPill(branch: s.baseBranch!),
      if (_hasDraft(s)) _badge('Draft', color: p.unread),
      ?(by == null ? null : _badge(by)),
    ];
  }

  String _agentLabel(String agentId) =>
      ref.read(agentCatalogProvider)[agentId]?.label ?? agentId;

  Widget _identity(SchedulerSnapshot snapshot, AgentSchedule s, bool muted) {
    final p = context.antgrid;
    final label = _agentLabel(s.agentId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AbTokens.space4,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _editSchedule(s),
          child: _label(
            s.name,
            size: AbTokens.fontBody,
            weight: FontWeight.w600,
            color: muted ? p.textSecondary : p.textPrimary,
          ),
        ),
        Wrap(
          spacing: AbTokens.space6,
          runSpacing: AbTokens.space4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            AbAgentMark(toolKey: s.agentId, label: label),
            _label('$label · ${_projectName(snapshot, s.projectId)}'),
            ..._badges(snapshot, s),
          ],
        ),
      ],
    );
  }

  Widget _statusDot(ScheduleRun? active, AgentSchedule s, bool resting) {
    if (resting) {
      return const AbStatusDot(
        tone: AbStatusTone.disabled,
        size: AbDotSize.md,
        style: AbDotStyle.hollow,
      );
    }
    return switch (active?.status) {
      'needs-input' => const AbStatusDot(
        tone: AbStatusTone.warning,
        size: AbDotSize.md,
        pulse: true,
      ),
      'running' || 'preparing' => const AbStatusDot(
        tone: AbStatusTone.info,
        size: AbDotSize.md,
        pulse: true,
      ),
      _ => const AbStatusDot(tone: AbStatusTone.agentIdle, size: AbDotSize.md),
    };
  }

  String _zoneCity(String zone) => zone.split('/').last.replaceAll('_', ' ');

  ({String main, String? sub, Color color, bool mono}) _nextCell(
    SchedulerSnapshot snapshot,
    AgentSchedule s,
    ScheduleRun? active,
    SchedulerOneOffState? oneOff,
    DateTime now,
    String viewerZone,
  ) {
    final p = context.antgrid;
    if (active != null) {
      final attention = active.status == 'needs-input';
      return (
        main: schedulerActiveRunLine(active, now),
        sub: attention
            ? null
            : active.trigger == 'manual'
            ? 'Started with Run now'
            : schedulerTrigger(active.trigger),
        color: attention ? p.warning : p.accent,
        mono: false,
      );
    }
    if (oneOff == SchedulerOneOffState.finished) {
      return (
        main: schedulerOneOffOutcome(s, snapshot.runs),
        sub: null,
        color: p.textSecondary,
        mono: false,
      );
    }
    if (oneOff == SchedulerOneOffState.pausedPassed) {
      return (
        main: 'Time passed',
        sub: null,
        color: p.textSecondary,
        mono: false,
      );
    }
    if (!s.enabled) {
      return (main: 'Paused', sub: null, color: p.textSecondary, mono: false);
    }
    final next = s.nextOccurrence ?? s.runAt;
    if (next == null) {
      return (main: '—', sub: null, color: p.textSecondary, mono: true);
    }
    final wall = schedulerWallCompact(next, viewerZone, now);
    return (
      main: schedulerRelative(next, now),
      sub: s.timezone == viewerZone ? wall : '$wall your time',
      color: p.textPrimary,
      mono: true,
    );
  }

  Widget _scheduleRow(
    SchedulerSnapshot snapshot,
    AgentSchedule s,
    DateTime now,
    String viewerZone,
  ) {
    final p = context.antgrid;
    final active = schedulerActiveRun(snapshot.runs, s.id);
    final last = schedulerLastOccurrence(snapshot.runs, s.id);
    final oneOff = s.isOneOff ? schedulerOneOffState(s, now) : null;
    final resting = !s.enabled || oneOff == SchedulerOneOffState.finished;
    final detail = [
      ?schedulerRepeatsDetail(s, viewerZone),
      if (snapshot.capabilities.supportsCatchUp)
        ?schedulerCatchUpBadge(s.catchUp),
    ].join(' · ');
    final next = _nextCell(snapshot, s, active, oneOff, now, viewerZone);
    final recent = schedulerRecentRuns(snapshot.runs, s.id);
    final attention = active?.status == 'needs-input';
    return Container(
      key: ValueKey('scheduler-schedule-${s.id}'),
      color: attention ? p.warning.withValues(alpha: 0.05) : null,
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space16,
        vertical: AbTokens.space12,
      ),
      child: Row(
        spacing: AbTokens.space16,
        children: [
          _statusDot(active, s, resting),
          Expanded(flex: 24, child: _identity(snapshot, s, resting)),
          Expanded(
            flex: 12,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: AbTokens.space4,
              children: [
                _label(
                  schedulerRepeats(s),
                  size: AbTokens.fontMd,
                  color: resting ? p.textSecondary : p.textPrimary,
                ),
                if (detail.isNotEmpty)
                  _label(
                    detail,
                    size: AbTokens.fontXs,
                    mono: schedulerRepeats(s) == 'Custom',
                  ),
              ],
            ),
          ),
          Expanded(
            flex: 11,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: AbTokens.space4,
              children: [
                _label(
                  next.main,
                  size: AbTokens.fontMd,
                  color: next.color,
                  weight: FontWeight.w500,
                  mono: next.mono,
                ),
                if (next.sub != null) _label(next.sub!, size: AbTokens.fontXs),
              ],
            ),
          ),
          Expanded(
            flex: 12,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: AbTokens.space6,
              children: [
                if (recent.isNotEmpty) SchedulerRunSquares(runs: recent),
                _label(
                  last == null
                      ? schedulerNoRunsYet
                      : schedulerLastRunLine(last, now),
                  size: AbTokens.fontXs,
                ),
              ],
            ),
          ),
          SizedBox(
            width: _actionsWidth,
            child: _actions(snapshot, s, active, oneOff),
          ),
        ],
      ),
    );
  }

  Widget _actions(
    SchedulerSnapshot snapshot,
    AgentSchedule s,
    ScheduleRun? active,
    SchedulerOneOffState? oneOff,
  ) {
    final p = context.antgrid;
    final finished = oneOff == SchedulerOneOffState.finished;
    final needsNewTime =
        finished || oneOff == SchedulerOneOffState.pausedPassed;
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      spacing: AbTokens.space6,
      children: [
        if (active == null) ...[
          _action(
            'Run now',
            s.name,
            () => _act('scheduler.runNow', {'id': s.id}),
          ),
        ] else if (active.status == 'needs-input') ...[
          _action(
            active.sessionId == null ? 'View run' : 'Open session',
            s.name,
            () => _openOrView(active),
            color: p.warning,
          ),
          _action(
            'Stop run',
            s.name,
            () => _act('scheduler.stop', {'id': active.id}),
            display: 'Stop',
          ),
        ] else ...[
          _action(
            active.sessionId == null ? 'View run' : 'Open',
            s.name,
            () => _openOrView(active),
          ),
          _action(
            'Stop run',
            s.name,
            () => _act('scheduler.stop', {'id': active.id}),
            display: 'Stop',
          ),
        ],
        if (needsNewTime)
          _action('Set a new time', s.name, () async => _editSchedule(s)),
        if (!finished)
          AbSwitch(
            value: s.enabled,
            semanticLabel: 'Active: ${s.name}',
            onChanged: _writable && !needsNewTime
                ? (value) => detached(
                    'Scheduler',
                    'toggle failed',
                    () => _act('scheduler.update', {
                      'id': s.id,
                      'patch': {'enabled': value},
                    }),
                  )
                : null,
          ),
        Builder(
          builder: (anchor) => Semantics(
            label: 'More actions for ${s.name}',
            child: AbIconButton(
              icon: AbIcons.more,
              tooltip: 'Actions for ${s.name}',
              onTap: _writable
                  ? () => detached(
                      'Scheduler',
                      'menu failed',
                      () => _scheduleMenu(anchor, s),
                    )
                  : null,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _openOrView(ScheduleRun run) async {
    if (run.sessionId == null) {
      _viewRun(run);
    } else {
      await _open(run);
    }
  }

  Widget _nextCard(
    SchedulerLane next,
    ({int runs, bool capped, SchedulerLane? next}) summary,
    DateTime now,
  ) {
    final p = context.antgrid;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space14,
        vertical: AbTokens.space12,
      ),
      decoration: BoxDecoration(
        color: p.bgSurface,
        border: Border.all(color: p.borderDefault),
        borderRadius: AbTokens.borderRadius8,
      ),
      child: Row(
        spacing: AbTokens.space10,
        children: [
          AbIcon(AbIcons.calendar, color: p.textSecondary),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: AbTokens.space2,
              children: [
                Text.rich(
                  TextSpan(
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontMd,
                      color: p.textPrimary,
                    ),
                    children: [
                      const TextSpan(text: 'Next: '),
                      TextSpan(
                        text: next.schedule.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const TextSpan(text: ' '),
                      TextSpan(
                        text: schedulerRelative(next.dots.first, now),
                        style: AbTokens.monoStyle(
                          fontSize: AbTokens.fontMd,
                          color: p.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
                _label(
                  '${summary.runs}${summary.capped ? '+' : ''} runs in the next 24 hours',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _attentionCard(AgentSchedule s, ScheduleRun run, DateTime now) {
    final p = context.antgrid;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AbTokens.space14,
        vertical: AbTokens.space12,
      ),
      decoration: BoxDecoration(
        color: p.warning.withValues(alpha: 0.06),
        border: Border.all(color: p.warning.withValues(alpha: 0.35)),
        borderRadius: AbTokens.borderRadius8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: AbTokens.space10,
        children: [
          Row(
            spacing: AbTokens.space10,
            children: [
              const AbStatusDot(
                tone: AbStatusTone.warning,
                size: AbDotSize.md,
                pulse: true,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: AbTokens.space2,
                  children: [
                    _label(
                      s.name,
                      size: AbTokens.fontBody,
                      weight: FontWeight.w600,
                      color: p.textPrimary,
                    ),
                    _label(schedulerActiveRunLine(run, now), color: p.warning),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(
            height: AbTokens.tapTargetMin,
            child: _action(
              run.sessionId == null ? 'View run' : 'Open session',
              s.name,
              () => _openOrView(run),
              color: p.warning,
              expand: true,
            ),
          ),
        ],
      ),
    );
  }

  Widget _phoneRow(
    SchedulerSnapshot snapshot,
    AgentSchedule s,
    DateTime now,
    String viewerZone,
  ) {
    final p = context.antgrid;
    final active = schedulerActiveRun(snapshot.runs, s.id);
    final oneOff = s.isOneOff ? schedulerOneOffState(s, now) : null;
    final resting = !s.enabled || oneOff == SchedulerOneOffState.finished;
    final next = _nextCell(snapshot, s, active, oneOff, now, viewerZone);
    final zone = schedulerZoneNote(s.timezone, viewerZone);
    final repeats = [
      schedulerRepeats(s),
      if (zone != null) _zoneCity(zone),
    ].join(' ');
    final recent = schedulerRecentRuns(snapshot.runs, s.id);
    return Builder(
      key: ValueKey('scheduler-schedule-${s.id}'),
      builder: (anchor) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _editSchedule(s),
        onLongPress: _writable
            ? () => detached(
                'Scheduler',
                'menu failed',
                () => _scheduleMenu(anchor, s, phone: true, active: active),
              )
            : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: AbTokens.tapTargetMin + AbTokens.space16,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AbTokens.space14,
              vertical: AbTokens.space10,
            ),
            child: Row(
              spacing: AbTokens.space12,
              children: [
                _statusDot(active, s, resting),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: AbTokens.space2,
                    children: [
                      _label(
                        s.name,
                        size: AbTokens.fontBody,
                        weight: FontWeight.w600,
                        color: resting ? p.textSecondary : p.textPrimary,
                      ),
                      Text.rich(
                        TextSpan(
                          style: AbTokens.sansStyle(
                            fontSize: AbTokens.fontSm,
                            color: p.textSecondary,
                          ),
                          children: [
                            TextSpan(text: '$repeats · '),
                            TextSpan(
                              text: next.main,
                              style: TextStyle(color: next.color),
                            ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (recent.isNotEmpty && !resting)
                  SchedulerMiniBars(runs: recent),
                Builder(
                  builder: (button) => AbIconButton(
                    icon: AbIcons.more,
                    tooltip: 'Actions for ${s.name}',
                    onTap: _writable
                        ? () => detached(
                            'Scheduler',
                            'menu failed',
                            () => _scheduleMenu(
                              button,
                              s,
                              phone: true,
                              active: active,
                            ),
                          )
                        : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _action(
    String label,
    String name,
    Future<void> Function() action, {
    String? display,
    Color? color,
    bool expand = false,
  }) => Semantics(
    label: '$label for $name',
    button: true,
    enabled: _writable,
    excludeSemantics: true,
    onTap: _writable
        ? () => detached('Scheduler', 'action failed', action)
        : null,
    child: AbButton(
      label: display ?? label,
      compact: true,
      color: color,
      expand: expand,
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
    AgentSchedule schedule, {
    bool phone = false,
    ScheduleRun? active,
  }) async {
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
        // Phone rows have no inline buttons, so the run controls live here.
        if (phone && active == null)
          const AbMenuItem(label: 'Run now', value: 'run', icon: AbIcons.start),
        if (phone && active != null) ...[
          if (active.sessionId != null)
            const AbMenuItem(label: 'Open session', value: 'open')
          else
            const AbMenuItem(label: 'View run', value: 'view'),
          const AbMenuItem(label: 'Stop run', value: 'stop'),
        ],
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
      case 'run':
        await _act('scheduler.runNow', {'id': schedule.id});
      case 'open':
        await _open(active!);
      case 'view':
        _viewRun(active!);
      case 'stop':
        await _act('scheduler.stop', {'id': active!.id});
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

  Widget _runs(SchedulerSnapshot snapshot, bool wide) {
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
    return SchedulerRunsView(
      runs: runs,
      schedules: snapshot.schedules,
      projects: snapshot.projects,
      viewerZone:
          ref.read(schedulerLocalTimezoneProvider).value ??
          snapshot.capabilities.timezone,
      now: DateTime.now(),
      compact: !wide,
      enabled: _writable,
      agentLabel: _agentLabel,
      scheduleId: _runScheduleId,
      onScheduleFilter: (id) => setState(() {
        _runScheduleId = id;
        if (id == null) _focusedRunId = null;
      }),
      focusedRunId: _focusedRunId,
      onOpenSession: (run) =>
          detached('Scheduler', 'open failed', () => _open(run)),
      onStop: (run) => detached(
        'Scheduler',
        'stop failed',
        () => _act('scheduler.stop', {'id': run.id}),
      ),
    );
  }

  Widget _card(List<Widget> children) => Container(
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

String schedulerError(
  Object error, {
  String machineName = 'the target machine',
}) {
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
    return 'Update Antgrid on $machineName to use the scheduler.';
  }
  return 'Machine unavailable or scheduler request failed: $error';
}
