import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show RpcException;
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../design/ab_carbon.dart';
import '../constants/breakpoints.dart';
import '../design/widgets/ab_agent_mark.dart';
import '../launcher/host_control_client.dart';
import '../models/scheduler.dart';
import '../models/session_target.dart';
import '../navigation/nav_controller.dart';
import '../navigation/nav_location.dart';
import '../demo/demo_identity.dart';
import '../providers/account_machines.dart';
import '../providers/demo_mode.dart';
import '../providers/scheduler.dart';
import '../providers/agent_catalog.dart' show agentLabelsProvider;
import '../providers/scheduler_drafts.dart';
import '../providers/scheduler_timezone.dart';
import '../providers/sessions.dart';
import '../providers/ui_attention_providers.dart';
import '../util/detached.dart';
import '../utils/platform_utils.dart';
import '../widgets/carbon_machine_selector.dart';
import '../widgets/drawer_entry_row.dart' show activateDrawerEntryById;
import '../widgets/scheduler/schedule_editor.dart';
import '../widgets/scheduler/scheduler_format.dart';
import '../widgets/scheduler/scheduler_lanes.dart';
import '../widgets/scheduler/scheduler_run_squares.dart';
import '../widgets/scheduler/scheduler_runs_view.dart';
import '../widgets/scheduler/scheduler_status_glyph.dart';
import '../widgets/ab_status_helpers.dart' show caughtErrorCopy;
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
  // A context under the Carbon scope; this State's own sits above it.
  BuildContext? _scoped;

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
    // With no machine there is nothing to ask, and the failed request would put
    // an error in front of a first-run user; the empty state explains instead.
    if (ref.read(schedulerMachinesProvider).isEmpty) {
      if (_loading) setState(() => _loading = false);
      return;
    }
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
        setState(
          () => _actionError =
              "That didn't work. ${schedulerError(error, machineName: _machineName)}",
        );
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _busy = false);
        await _refresh();
      }
    }
  }

  Future<void> _delete(AgentSchedule schedule) async {
    // The modal needs a context under the Carbon scope; this State's own sits
    // above it and would resolve a default theme.
    final scoped = _scoped;
    if (scoped == null || !scoped.mounted) return;
    final machine = ref.read(schedulerTargetProvider);
    final confirmed =
        await showCarbonModal<bool>(
          scoped,
          builder: (dialog) => CarbonModal.confirmation(
            title: 'Delete schedule',
            body: Text(
              "\"${schedule.name}\" won't run again. Its runs, sessions and worktree stay. A run in progress finishes.",
            ),
            danger: true,
            secondary: CarbonModalAction(
              label: 'Cancel',
              autofocus: true,
              onPressed: () => Navigator.of(dialog).pop(false),
            ),
            primary: CarbonModalAction(
              label: 'Delete schedule',
              onPressed: () => Navigator.of(dialog).pop(true),
            ),
          ),
        ) ??
        false;
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
    return machines[ref.read(schedulerTargetProvider) ?? kLocalMachineKey] ??
        'this machine';
  }

  CarbonThemeData get _t => CarbonTheme.of(_scoped!);

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
    final machineName = machines[machine ?? kLocalMachineKey] ?? 'this machine';
    final noMachine = machines.isEmpty;
    return AbCarbonScope(
      child: Builder(
        builder: (scoped) {
          _scoped = scoped;
          final t = CarbonTheme.of(scoped);
          return ColoredBox(
            color: t.colors.background,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= kMediumBreakpoint;
                final inset = wide
                    ? CarbonSpacing.spacing06
                    : CarbonSpacing.spacing05;
                Widget banner(Widget notification) => Padding(
                  padding: EdgeInsets.fromLTRB(
                    inset,
                    CarbonSpacing.spacing02,
                    inset,
                    CarbonSpacing.spacing03,
                  ),
                  child: notification,
                );
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // A narrow editor is a page of its own with its own
                    // breadcrumb.
                    if (!(_editing && !wide))
                      _header(
                        wide: wide,
                        machines: machines,
                        machine: machine ?? kLocalMachineKey,
                        machineName: machineName,
                        connected: connected,
                        onNew: _newScheduleTap(
                          snapshot,
                          machine,
                          localTimezone,
                        ),
                      ),
                    if (_error != null && !noMachine)
                      banner(
                        CarbonNotification(
                          kind: CarbonNotificationKind.error,
                          subtitle: _error!,
                        ),
                      ),
                    if (!_loading && !connected && _error == null && !noMachine)
                      banner(
                        CarbonNotification(
                          subtitle:
                              '$machineName is offline. Changes are paused until it reconnects.',
                        ),
                      ),
                    if (_actionError != null)
                      // Keyed by text so a new failure is announced again.
                      banner(
                        CarbonNotification(
                          key: ValueKey(_actionError),
                          kind: CarbonNotificationKind.error,
                          subtitle: _actionError!,
                        ),
                      ),
                    if (_feedbackRun case final run?)
                      banner(
                        CarbonNotification(
                          key: ValueKey('${run.id}:${run.status}'),
                          kind: switch (schedulerRunTone(
                            run.status,
                            trigger: run.trigger,
                          )) {
                            SchedulerRunTone.error =>
                              CarbonNotificationKind.error,
                            SchedulerRunTone.success =>
                              CarbonNotificationKind.success,
                            SchedulerRunTone.attention ||
                            SchedulerRunTone.warning =>
                              CarbonNotificationKind.warning,
                            SchedulerRunTone.active ||
                            SchedulerRunTone.muted =>
                              CarbonNotificationKind.info,
                          },
                          subtitle: run.status == 'skipped'
                              ? 'Run skipped: ${run.reason ?? 'No reason supplied by the machine'}'
                              : '${schedulerRunStatusWord(run.status, trigger: run.trigger)}${run.reason == null ? '' : ': ${run.reason}'}',
                          action: CarbonNotificationAction(
                            label: 'View run',
                            onPressed: () => _viewRun(run),
                          ),
                        ),
                      ),
                    if (snapshot?.capabilities.error != null)
                      banner(
                        CarbonNotification(
                          kind: snapshot!.capabilities.supported
                              ? CarbonNotificationKind.warning
                              : CarbonNotificationKind.error,
                          subtitle: snapshot.capabilities.error!,
                        ),
                      ),
                    Expanded(
                      child: noMachine
                          ? _emptyState(
                              icon: CarbonIcons.calendar,
                              title: 'Connect a machine to schedule tasks',
                              subtitle:
                                  'Schedules run on your computer, in the Antgrid '
                                  'desktop app, at the times you set. Connect it to '
                                  'create and manage them here.',
                              // The one Scheduler a machine-less viewer can use:
                              // an App Review iPad has no machine. The
                              // container, not ref, because entering swaps this
                              // screen out.
                              action: CarbonButton(
                                label: kDemoEntryLabel,
                                onPressed: () =>
                                    enterDemoScheduler(ref.container),
                              ),
                            )
                          : _loading
                          ? const Center(
                              child: CarbonLoading(
                                message: 'Loading schedules…',
                              ),
                            )
                          : snapshot == null
                          ? _emptyState(
                              title: 'Machine unavailable',
                              subtitle: _error,
                              // A phone signed in to an account whose only
                              // machine is offline has no other way to see the
                              // Scheduler work. Desktop is left alone: its
                              // local host is a different failure.
                              action: isMobilePlatform
                                  ? CarbonButton(
                                      label: kDemoEntryLabel,
                                      onPressed: () =>
                                          enterDemoScheduler(ref.container),
                                    )
                                  : null,
                            )
                          : !snapshot.capabilities.supported
                          ? _emptyState(
                              title: 'Scheduler unavailable',
                              subtitle:
                                  'Update Antgrid on $machineName to use the scheduler.',
                            )
                          : _editing
                          ? ScheduleEditor(
                              key: ValueKey(
                                '${machine ?? kLocalMachineKey}:${_editedSchedule?.id ?? 'new'}',
                              ),
                              snapshot: snapshot,
                              machineId: machine ?? kLocalMachineKey,
                              schedule: _editedSchedule,
                              request: ref.watch(schedulerRequestProvider),
                              writable: _writable,
                              showBreadcrumb: !wide,
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
            ),
          );
        },
      ),
    );
  }

  /// Scrolls from anywhere in the pane, so the wheel never lands on a dead
  /// margin beside the centred column.
  Widget _emptyState({
    CarbonIcons? icon,
    required String title,
    String? subtitle,
    Widget? action,
  }) {
    final t = _t;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(CarbonSpacing.spacing06),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: CarbonSpacing.spacing09 * 8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  spacing: CarbonSpacing.spacing03,
                  children: [
                    if (icon != null)
                      CarbonIcon(
                        icon,
                        size: CarbonSpacing.spacing07,
                        color: t.colors.iconSecondary,
                      ),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: t.typography.heading.copyWith(
                        color: t.colors.textPrimary,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle,
                        textAlign: TextAlign.center,
                        style: t.typography.body.copyWith(
                          color: t.colors.textSecondary,
                        ),
                      ),
                    if (action != null)
                      Padding(
                        padding: const EdgeInsets.only(
                          top: CarbonSpacing.spacing03,
                        ),
                        child: action,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  VoidCallback? _newScheduleTap(
    SchedulerSnapshot? snapshot,
    String? machine,
    AsyncValue<String?> localTimezone,
  ) {
    final hasDraft = ref.read(schedulerDraftsProvider).containsKey((
      machine: machine ?? kLocalMachineKey,
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
    final t = _t;
    final title = Text(
      'Scheduler',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      // Never smaller than the section titles the tables below carry.
      style: (t.isTouch ? t.typography.headingLarge : t.typography.title)
          .copyWith(color: t.colors.textPrimary),
    );
    final switcher = CarbonContentSwitcher<bool>(
      expand: !wide,
      size: CarbonContentSwitcherSize.small,
      options: const [
        CarbonOption<bool>(value: false, label: 'Schedules'),
        CarbonOption<bool>(value: true, label: 'Runs'),
      ],
      value: _runsTab,
      onChanged: (value) => setState(() {
        _runsTab = value;
        _editing = false;
        _runScheduleId = null;
      }),
    );
    final machineButton = machines.isEmpty
        ? null
        : CarbonMachineSelector(
            machines: machines,
            currentId: machine,
            name: machineName,
            connected: connected,
            wide: wide,
            onPicked: _pickMachine,
          );
    final refresh = CarbonButton.iconOnly(
      icon: const CarbonIcon(CarbonIcons.renew),
      semanticLabel: 'Refresh',
      onPressed: _busy
          ? null
          : () => detached('Scheduler', 'refresh failed', _refresh),
    );
    if (wide) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          CarbonSpacing.spacing06,
          CarbonSpacing.spacing05,
          CarbonSpacing.spacing06,
          CarbonSpacing.spacing04,
        ),
        // Two groups that share a line when they fit; in a narrow pane (an
        // iPad beside the sidebar, large text) the actions wrap below the
        // title instead of overflowing.
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: CarbonSpacing.spacing04,
          runSpacing: CarbonSpacing.spacing03,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              spacing: CarbonSpacing.spacing04,
              children: [
                // While editing, the screen title becomes the editor's way
                // back, so the name appears once, above the schedule's own
                // title.
                if (_editing)
                  CarbonBreadcrumb(
                    items: [
                      CarbonBreadcrumbItem(
                        label: 'Scheduler',
                        onPressed: () => setState(() => _editing = false),
                      ),
                    ],
                  )
                else
                  title,
                if (!_editing) switcher,
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              spacing: CarbonSpacing.spacing04,
              children: [
                // A long machine name gives way before the actions do.
                if (machineButton != null) Flexible(child: machineButton),
                refresh,
                if (!_editing)
                  CarbonButton(
                    label: 'New schedule',
                    icon: const CarbonIcon(CarbonIcons.add),
                    onPressed: onNew,
                  ),
              ],
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
            CarbonSpacing.spacing03,
            CarbonSpacing.spacing03,
            CarbonSpacing.spacing03,
            CarbonSpacing.spacing02,
          ),
          child: Row(
            spacing: CarbonSpacing.spacing02,
            children: [
              if (isMobilePlatform && widget.onOpenDrawer != null)
                CarbonButton.iconOnly(
                  icon: const CarbonIcon(CarbonIcons.menu),
                  semanticLabel: 'Open drawer',
                  onPressed: widget.onOpenDrawer,
                )
              else
                const SizedBox(width: CarbonSpacing.spacing03),
              Expanded(child: title),
              if (machineButton != null) Flexible(child: machineButton),
              CarbonButton.iconOnly(
                icon: const CarbonIcon(CarbonIcons.add),
                semanticLabel: 'New schedule',
                kind: CarbonButtonKind.primary,
                onPressed: onNew,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            CarbonSpacing.spacing05,
            CarbonSpacing.spacing02,
            CarbonSpacing.spacing05,
            CarbonSpacing.spacing04,
          ),
          child: SizedBox(width: double.infinity, child: switcher),
        ),
      ],
    );
  }

  void _pickMachine(String id) {
    // The selection outlives the demo: a 'local' pick made in the sample would
    // leave a phone's real Scheduler target null after exit.
    if (!mounted || ref.read(demoModeProvider)) return;
    ref.read(machinePickProvider.notifier).set(id);
  }

  Widget _schedules(SchedulerSnapshot snapshot, bool wide) {
    final drafts = ref.read(schedulerDraftsProvider);
    final machine = ref.read(schedulerTargetProvider) ?? kLocalMachineKey;
    final deletedDrafts = drafts.entries.where(
      (entry) =>
          entry.key.machine == machine &&
          entry.key.scheduleId != null &&
          !snapshot.schedules.any((s) => s.id == entry.key.scheduleId),
    );
    if (snapshot.schedules.isEmpty && deletedDrafts.isEmpty) {
      return _emptyState(
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

    final zoneLabel = 'Times in $viewerZone';
    final restLabel = 'Paused and finished (${rest.length})';

    Widget table(
      List<AgentSchedule> schedules, {
      String? title,
      String? description,
    }) => CarbonDataTable(
      title: title,
      description: description,
      columns: const [
        CarbonDataTableColumn(label: '', width: _statusColumnWidth),
        CarbonDataTableColumn(label: 'Schedule', flex: 24),
        CarbonDataTableColumn(label: 'Repeats', flex: 12),
        CarbonDataTableColumn(label: 'Next run', flex: 11),
        CarbonDataTableColumn(label: 'Recent runs', width: _recentRunsWidth),
        CarbonDataTableColumn(
          label: 'Active',
          width: _actionsWidth,
          align: CarbonDataTableAlign.end,
        ),
      ],
      rows: [
        for (final s in schedules) _scheduleRow(snapshot, s, now, viewerZone),
      ],
    );

    Widget list(List<AgentSchedule> schedules, String label) =>
        CarbonContainedList(
          label: label,
          children: [
            for (final s in schedules) _phoneRow(snapshot, s, now, viewerZone),
          ],
        );

    final padding = wide
        ? const EdgeInsets.fromLTRB(
            CarbonSpacing.spacing06,
            CarbonSpacing.spacing02,
            CarbonSpacing.spacing06,
            CarbonSpacing.spacing06,
          )
        : const EdgeInsets.fromLTRB(
            CarbonSpacing.spacing05,
            0,
            CarbonSpacing.spacing05,
            CarbonSpacing.spacing05,
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
          spacing: wide ? CarbonSpacing.spacing05 : CarbonSpacing.spacing04,
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
            if (!stripShown && listed.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: CarbonSpacing.spacing02,
                ),
                child: _label(zoneLabel),
              ),
            if (listed.isNotEmpty)
              wide
                  ? table(listed, description: stripShown ? null : zoneLabel)
                  : list(listed, zoneLabel),
            if (rest.isNotEmpty)
              wide ? table(rest, title: restLabel) : list(rest, restLabel),
            for (final entry in deletedDrafts)
              CarbonNotification(
                subtitle:
                    'Deleted schedule draft: ${entry.value.values['name']}',
                action: CarbonNotificationAction(
                  label: 'Open retained draft',
                  onPressed: () => setState(() {
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
              ),
          ],
        ),
      ],
    );
  }

  Widget _label(
    String value, {
    Color? color,
    bool mono = false,
    bool small = true,
    int maxLines = 1,
  }) {
    final t = _t;
    final style = mono
        ? t.typography.code
        : small
        ? t.typography.helper
        : t.typography.label;
    return Text(
      value,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: style.copyWith(color: color ?? t.colors.textSecondary),
    );
  }

  // Both table widths include the 32px cell padding the table adds.
  static const _statusColumnWidth =
      SchedulerStatusGlyph.extent + CarbonSpacing.spacing07;
  // Fits Open session, Stop, the toggle and the menu on one line in the
  // common case; the cell's Wrap takes anything wider to a second line rather
  // than starving the text columns.
  static const _actionsWidth = 288.0;
  // Fixed so a desktop row always shows the full ten-run history; as a share
  // of the leftover width it dropped the oldest square at common sizes.
  static const _recentRunsWidth =
      SchedulerRunSquares.fullWidth + 2 * CarbonSpacing.spacing05;

  bool _hasDraft(AgentSchedule s) =>
      ref.read(schedulerDraftsProvider).containsKey((
        machine: ref.read(schedulerTargetProvider) ?? kLocalMachineKey,
        scheduleId: s.id,
      ));

  String? _by(AgentSchedule s) {
    final who =
        s.editedBySessionName ?? s.authorSessionName ?? s.authorSessionId;
    return who == null ? null : 'by $who';
  }

  List<Widget> _badges(SchedulerSnapshot snapshot, AgentSchedule s) {
    final mode = s.mode == 'chat' && s.chatMode != null
        ? snapshot.capabilities.chatModes[s.agentId]
                  ?.where((m) => m.id == s.chatMode)
                  .firstOrNull
                  ?.name ??
              s.chatMode
        : null;
    final by = _by(s);
    return [
      ?(mode == null ? null : CarbonTag(label: mode, size: CarbonTagSize.small)),
      if (s.approvalPolicy == 'bypass')
        const CarbonTag(
          label: 'Bypass',
          color: CarbonTagColor.red,
          size: CarbonTagSize.small,
        ),
      if (s.workspace == 'worktree' && s.baseBranch != null)
        CarbonTag(
          label: s.baseBranch!,
          color: CarbonTagColor.outline,
          size: CarbonTagSize.small,
          icon: const CarbonIcon(CarbonIcons.branch),
        ),
      if (_hasDraft(s))
        const CarbonTag(
          label: 'Draft',
          color: CarbonTagColor.blue,
          size: CarbonTagSize.small,
        ),
      ?(by == null ? null : _label(by)),
    ];
  }

  String _agentLabel(String agentId) =>
      ref.read(agentLabelsProvider)[agentId] ?? agentId;

  Widget _identity(SchedulerSnapshot snapshot, AgentSchedule s) {
    final t = _t;
    final label = _agentLabel(s.agentId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: CarbonSpacing.spacing02,
      children: [
        CarbonLink(label: s.name, onPressed: () => _editSchedule(s)),
        Wrap(
          spacing: CarbonSpacing.spacing03,
          runSpacing: CarbonSpacing.spacing02,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            AbAgentMark(
              toolKey: s.agentId,
              label: label,
              size: t.iconSize,
              color: t.colors.iconSecondary,
            ),
            _label('$label · ${_projectName(snapshot, s.projectId)}'),
            ..._badges(snapshot, s),
          ],
        ),
      ],
    );
  }

  String _stateWord(ScheduleRun? active, bool resting, bool finished) {
    if (resting) return finished ? 'Finished' : 'Paused';
    return switch (active?.status) {
      'needs-input' => 'Needs input',
      'running' || 'preparing' => 'Running',
      _ => 'Idle',
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
    final c = _t.colors;
    if (active != null) {
      final attention = active.status == 'needs-input';
      return (
        main: schedulerActiveRunLine(active, now),
        sub: attention
            ? null
            : active.trigger == 'manual'
            ? 'Started with Run now'
            : schedulerTrigger(active.trigger),
        color: attention ? schedulerAttentionTextColor(_t) : c.supportInfo,
        mono: false,
      );
    }
    if (oneOff == SchedulerOneOffState.finished) {
      return (
        main: schedulerOneOffOutcome(s, snapshot.runs),
        sub: null,
        color: c.textSecondary,
        mono: false,
      );
    }
    if (oneOff == SchedulerOneOffState.pausedPassed) {
      return (
        main: 'Time passed',
        sub: null,
        color: c.textSecondary,
        mono: false,
      );
    }
    if (!s.enabled) {
      return (main: 'Paused', sub: null, color: c.textSecondary, mono: false);
    }
    final next = s.nextOccurrence ?? s.runAt;
    if (next == null) {
      return (main: '—', sub: null, color: c.textSecondary, mono: true);
    }
    final wall = schedulerWallCompact(next, viewerZone, now);
    return (
      main: schedulerRelative(next, now),
      sub: s.timezone == viewerZone ? wall : '$wall your time',
      color: c.textPrimary,
      mono: true,
    );
  }

  CarbonDataTableRow _scheduleRow(
    SchedulerSnapshot snapshot,
    AgentSchedule s,
    DateTime now,
    String viewerZone,
  ) {
    final c = _t.colors;
    final active = schedulerActiveRun(snapshot.runs, s.id);
    final last = schedulerLastOccurrence(snapshot.runs, s.id);
    final oneOff = s.isOneOff ? schedulerOneOffState(s, now) : null;
    final finished = oneOff == SchedulerOneOffState.finished;
    final resting = !s.enabled || finished;
    final detail = [
      ?schedulerRepeatsDetail(s, viewerZone),
      if (snapshot.capabilities.supportsCatchUp)
        ?schedulerCatchUpBadge(s.catchUp),
    ].join(' · ');
    final next = _nextCell(snapshot, s, active, oneOff, now, viewerZone);
    final recent = schedulerRecentRuns(snapshot.runs, s.id);
    return CarbonDataTableRow(
      key: ValueKey('scheduler-schedule-${s.id}'),
      cells: [
        SchedulerStatusGlyph.schedule(
          active: active,
          resting: resting,
          semanticLabel: _stateWord(active, resting, finished),
        ),
        _identity(snapshot, s),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: CarbonSpacing.spacing02,
          children: [
            _label(
              schedulerRepeats(s),
              small: false,
              color: resting ? c.textSecondary : c.textPrimary,
            ),
            if (detail.isNotEmpty)
              _label(detail, mono: schedulerRepeats(s) == 'Custom'),
          ],
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: CarbonSpacing.spacing02,
          children: [
            _label(
              next.main,
              small: false,
              color: next.color,
              mono: next.mono,
              maxLines: 2,
            ),
            if (next.sub != null) _label(next.sub!),
          ],
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: CarbonSpacing.spacing03,
          children: [
            if (recent.isNotEmpty) SchedulerRunSquares(runs: recent),
            _label(
              last == null
                  ? schedulerNoRunsYet
                  : schedulerLastRunLine(last, now),
            ),
          ],
        ),
        _actions(snapshot, s, active, oneOff),
      ],
    );
  }

  Widget _actions(
    SchedulerSnapshot snapshot,
    AgentSchedule s,
    ScheduleRun? active,
    SchedulerOneOffState? oneOff,
  ) {
    final finished = oneOff == SchedulerOneOffState.finished;
    final needsNewTime =
        finished || oneOff == SchedulerOneOffState.pausedPassed;
    // A Wrap, not a Row: the cell narrows with the window and the controls
    // must drop to a second line rather than overflow.
    return Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: CarbonSpacing.spacing02,
      runSpacing: CarbonSpacing.spacing02,
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
            kind: CarbonButtonKind.primary,
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
          CarbonToggle(
            value: s.enabled,
            small: true,
            hideStateText: true,
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
        CarbonOverflowMenu(
          entries: _scheduleEntries(s),
          enabled: _writable,
          size: CarbonButtonSize.small,
          semanticLabel: 'Actions for ${s.name}',
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
    final t = _t;
    return CarbonLayerSurface(
      padding: const EdgeInsets.all(CarbonSpacing.spacing05),
      child: Row(
        spacing: CarbonSpacing.spacing03,
        children: [
          CarbonIcon(CarbonIcons.calendar, color: t.colors.iconSecondary),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: CarbonSpacing.spacing02,
              children: [
                Text.rich(
                  TextSpan(
                    style: t.typography.body.copyWith(
                      color: t.colors.textPrimary,
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
                        style: t.typography.code.copyWith(
                          color: t.colors.textPrimary,
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
    final t = _t;
    return CarbonLayerSurface(
      border: true,
      padding: const EdgeInsets.all(CarbonSpacing.spacing05),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: CarbonSpacing.spacing04,
        children: [
          Row(
            spacing: CarbonSpacing.spacing04,
            children: [
              const SchedulerStatusGlyph.run(SchedulerRunTone.attention),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: CarbonSpacing.spacing02,
                  children: [
                    Text(
                      s.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.typography.heading.copyWith(
                        color: t.colors.textPrimary,
                      ),
                    ),
                    _label(
                      schedulerActiveRunLine(run, now),
                      color: schedulerAttentionTextColor(t),
                    ),
                  ],
                ),
              ),
            ],
          ),
          _action(
            run.sessionId == null ? 'View run' : 'Open session',
            s.name,
            () => _openOrView(run),
            kind: CarbonButtonKind.primary,
            expand: true,
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
    // Keyed outside the context menu: an unkeyed menu keeps its open state by
    // list position, so a poll that moves a row above would leave the open
    // menu showing, and acting on, the schedule that slid into its slot.
    return CarbonContextMenu(
      key: ValueKey('scheduler-schedule-${s.id}'),
      entries: _scheduleEntries(s, phone: true, active: active),
      enabled: _writable,
      child: CarbonContainedListRow(
        title: s.name,
        secondary: '$repeats · ${next.main}',
        leading: SchedulerStatusGlyph.schedule(active: active, resting: resting),
        onPressed: () => _editSchedule(s),
        actions: [
          if (recent.isNotEmpty && !resting) SchedulerMiniBars(runs: recent),
          CarbonOverflowMenu(
            entries: _scheduleEntries(s, phone: true, active: active),
            enabled: _writable,
            semanticLabel: 'Actions for ${s.name}',
          ),
        ],
      ),
    );
  }

  Widget _action(
    String label,
    String name,
    Future<void> Function() action, {
    String? display,
    CarbonButtonKind kind = CarbonButtonKind.ghost,
    bool expand = false,
  }) => CarbonButton(
    label: display ?? label,
    semanticLabel: '$label for $name',
    kind: kind,
    size: expand ? null : CarbonButtonSize.small,
    expand: expand,
    onPressed: _writable
        ? () => detached('Scheduler', 'action failed', action)
        : null,
  );

  void _editSchedule(AgentSchedule schedule) => setState(() {
    _editing = true;
    _editedSchedule = schedule;
  });

  List<CarbonMenuEntry> _scheduleEntries(
    AgentSchedule schedule, {
    bool phone = false,
    ScheduleRun? active,
  }) {
    final machine = ref.read(schedulerTargetProvider);
    final needsNewTime =
        schedule.isOneOff &&
        const {
          SchedulerOneOffState.finished,
          SchedulerOneOffState.pausedPassed,
        }.contains(schedulerOneOffState(schedule, DateTime.now()));
    // Entries are built long before one is chosen, so a machine switch or a
    // lost connection in between must be caught when the item fires.
    VoidCallback guarded(String what, Future<void> Function() run) => () {
      if (!mounted || machine != ref.read(schedulerTargetProvider)) return;
      if (!_writable) return;
      detached('Scheduler', what, run);
    };
    return [
      CarbonMenuGroup(
        label: schedule.name,
        children: [
          // Phone rows have no inline buttons, so the run controls live here.
          if (phone && active == null)
            CarbonMenuItem(
              label: 'Run now',
              icon: const CarbonIcon(CarbonIcons.play),
              onPressed: guarded(
                'run failed',
                () => _act('scheduler.runNow', {'id': schedule.id}),
              ),
            ),
          if (phone && active != null) ...[
            if (active.sessionId != null)
              CarbonMenuItem(
                label: 'Open session',
                onPressed: guarded('open failed', () => _open(active)),
              )
            else
              CarbonMenuItem(
                label: 'View run',
                onPressed: guarded('view failed', () async => _viewRun(active)),
              ),
            CarbonMenuItem(
              label: 'Stop run',
              onPressed: guarded(
                'stop failed',
                () => _act('scheduler.stop', {'id': active.id}),
              ),
            ),
          ],
          CarbonMenuItem(
            label: needsNewTime ? 'Set a new time' : 'Edit',
            icon: const CarbonIcon(CarbonIcons.edit),
            onPressed: guarded('edit failed', () async => _editSchedule(schedule)),
          ),
          // Resuming a one-off whose time has passed is refused by the bridge;
          // the new-time editor is the only way back.
          if (!needsNewTime)
            CarbonMenuItem(
              label: schedule.enabled ? 'Pause' : 'Resume',
              onPressed: guarded(
                'pause failed',
                () => _act('scheduler.update', {
                  'id': schedule.id,
                  'patch': {'enabled': !schedule.enabled},
                }),
              ),
            ),
          CarbonMenuItem(
            label: 'Delete',
            icon: const CarbonIcon(CarbonIcons.trashCan),
            kind: CarbonMenuItemKind.danger,
            onPressed: guarded('delete failed', () => _delete(schedule)),
          ),
        ],
      ),
    ];
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
      onEditSchedule: _editSchedule,
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
  // The request provider's own messages are written for the user.
  if (error is StateError) return error.message;
  return caughtErrorCopy(error, "Couldn't reach the scheduler on $machineName.");
}

