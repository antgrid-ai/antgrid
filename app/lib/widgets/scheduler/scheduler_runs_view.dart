import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';

import '../../design/widgets/ab_agent_mark.dart';
import '../../models/scheduler.dart';
import 'scheduler_format.dart';
import 'scheduler_status_glyph.dart';

enum _RunFilter { all, failed, catchUp }

bool _isCatchUp(ScheduleRun r) =>
    r.trigger == 'catch-up' || r.trigger == 'missed';

bool _matches(_RunFilter f, ScheduleRun r) => switch (f) {
  _RunFilter.all => true,
  _RunFilter.failed => r.status == 'failed',
  _RunFilter.catchUp => _isCatchUp(r),
};

String _filterLabel(_RunFilter f) => switch (f) {
  _RunFilter.all => 'All',
  _RunFilter.failed => 'Failed',
  _RunFilter.catchUp => 'Catch-up',
};

// Column widths of the desktop table; each includes the table's own cell
// padding.
const double _statusColumn = 148;
const double _timeColumn = 84;
const double _triggerColumn = 112;
const double _durationColumn = 96;
// Fits Stop with Open session, or Open session with Details, on one line.
const double _actionsColumn = 304;
const double _detailLabelWidth = 128;

/// Runs of the schedules on one machine, grouped by day. Every time is shown
/// once, in [viewerZone]; the day lives in the group header.
class SchedulerRunsView extends StatefulWidget {
  const SchedulerRunsView({
    super.key,
    required this.runs,
    required this.schedules,
    required this.projects,
    required this.viewerZone,
    required this.now,
    required this.compact,
    required this.enabled,
    required this.agentLabel,
    required this.scheduleId,
    required this.onScheduleFilter,
    required this.focusedRunId,
    required this.onOpenSession,
    required this.onStop,
    required this.onEditSchedule,
  });

  final List<ScheduleRun> runs;
  final List<AgentSchedule> schedules;
  final List<SchedulerProject> projects;
  final String viewerZone;
  final DateTime now;
  final bool compact;

  /// False while the machine cannot take actions; Stop and Open session show
  /// disabled instead of silently ignoring a tap.
  final bool enabled;
  final String Function(String agentId) agentLabel;
  final String? scheduleId;
  final ValueChanged<String?> onScheduleFilter;
  final String? focusedRunId;
  final void Function(ScheduleRun) onOpenSession;
  final void Function(ScheduleRun) onStop;

  /// Opens a live schedule's editor. A deleted schedule has none to open, so
  /// its name stays plain text.
  final void Function(AgentSchedule) onEditSchedule;

  @override
  State<SchedulerRunsView> createState() => _SchedulerRunsViewState();
}

class _SchedulerRunsViewState extends State<SchedulerRunsView> {
  _RunFilter _filter = _RunFilter.all;
  final Set<String> _expanded = {};

  DateTime _when(ScheduleRun r) => r.startedAt ?? r.occurrenceAt;

  AgentSchedule? _schedule(ScheduleRun r) =>
      widget.schedules.where((s) => s.id == r.scheduleId).firstOrNull;

  String _name(ScheduleRun r) =>
      _schedule(r)?.name ??
      r.scheduleName ??
      'Deleted schedule (${r.scheduleId})';

  String? _project(ScheduleRun r) => widget.projects
      .where((p) => p.projectId == r.projectId)
      .firstOrNull
      ?.name;

  List<ScheduleRun> _sorted() {
    final runs = [...widget.runs]..sort((a, b) => _when(b).compareTo(_when(a)));
    return runs;
  }

  List<MapEntry<String, List<ScheduleRun>>> _groups(List<ScheduleRun> runs) {
    final byDay = <String, List<ScheduleRun>>{};
    for (final r in runs) {
      byDay
          .putIfAbsent(
            schedulerDayKey(_when(r), widget.viewerZone),
            () => <ScheduleRun>[],
          )
          .add(r);
    }
    final groups = byDay.entries.toList();
    final focused = widget.focusedRunId;
    if (focused == null) return groups;
    // A run opened from a schedule may be days old; keep it at the top so the
    // highlight is not below the fold.
    final at = groups.indexWhere((g) => g.value.any((r) => r.id == focused));
    if (at < 0) return groups;
    final group = groups.removeAt(at);
    group.value.sort(
      (a, b) => a.id == focused
          ? -1
          : b.id == focused
          ? 1
          : 0,
    );
    return [group, ...groups];
  }

  void _toggle(ScheduleRun r) => setState(() {
    if (!_expanded.add(r.id)) _expanded.remove(r.id);
  });

  Widget _toolbar(CarbonThemeData t, List<ScheduleRun> all) {
    final filterName = widget.scheduleId == null
        ? 'All schedules'
        : widget.schedules
                  .where((s) => s.id == widget.scheduleId)
                  .firstOrNull
                  ?.name ??
              'Schedule';
    final schedules = [...widget.schedules]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final zone = Text(
      'Times in ${widget.viewerZone}',
      style: t.typography.helper.copyWith(color: t.colors.textSecondary),
    );
    final chips = Wrap(
      spacing: CarbonSpacing.spacing03,
      runSpacing: CarbonSpacing.spacing02,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final f in _RunFilter.values)
          CarbonTag(
            key: ValueKey('scheduler-runs-filter-${f.name}'),
            label:
                '${_filterLabel(f)} ${all.where((r) => _matches(f, r)).length}',
            selected: _filter == f,
            // Single select: a tap on the chosen tag asks to clear it, and a
            // null callback would make the tag inert and shrink its footprint.
            onSelectedChanged: (on) {
              if (on) setState(() => _filter = f);
            },
          ),
        CarbonMenuButton(
          key: const ValueKey('scheduler-runs-schedule-filter'),
          label: filterName,
          kind: CarbonButtonKind.ghost,
          size: CarbonButtonSize.small,
          maxLines: 1,
          semanticLabel: 'Filter by schedule',
          entries: [
            CarbonMenuRadioGroup<String>(
              value: widget.scheduleId ?? '',
              options: [
                const CarbonOption(value: '', label: 'All schedules'),
                for (final s in schedules)
                  CarbonOption(value: s.id, label: s.name),
              ],
              onChanged: (v) => widget.onScheduleFilter(v.isEmpty ? null : v),
            ),
          ],
        ),
      ],
    );
    if (widget.compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: CarbonSpacing.spacing03,
        children: [chips, zone],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      spacing: CarbonSpacing.spacing04,
      children: [
        Expanded(child: chips),
        zone,
      ],
    );
  }

  Widget _note(CarbonThemeData t, String text, double padding) => Padding(
    padding: EdgeInsets.all(padding),
    child: Center(
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: t.typography.body.copyWith(color: t.colors.textSecondary),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final t = CarbonTheme.of(context);
    final all = _sorted();
    final shown = all.where((r) => _matches(_filter, r)).toList();
    final showToolbar = all.isNotEmpty || widget.scheduleId != null;
    final padding = widget.compact
        ? CarbonSpacing.spacing04
        : CarbonSpacing.spacing05;
    return ListView(
      padding: EdgeInsets.all(padding),
      children: [
        if (showToolbar)
          Padding(
            padding: const EdgeInsets.only(bottom: CarbonSpacing.spacing05),
            child: _toolbar(t, all),
          ),
        if (all.isEmpty)
          _note(t, schedulerNoRunsHint, CarbonSpacing.spacing07)
        else if (shown.isEmpty)
          _note(t, 'No runs match this filter', CarbonSpacing.spacing05)
        else
          for (final group in _groups(shown))
            Padding(
              key: ValueKey('scheduler-runs-day-${group.key}'),
              padding: EdgeInsets.only(
                bottom: widget.compact
                    ? CarbonSpacing.spacing05
                    : CarbonSpacing.spacing06,
              ),
              child: _day(t, group),
            ),
      ],
    );
  }

  Widget _day(CarbonThemeData t, MapEntry<String, List<ScheduleRun>> group) {
    final header = schedulerDayHeader(
      _when(group.value.first),
      widget.viewerZone,
      widget.now,
    );
    if (widget.compact) {
      return CarbonContainedList(
        label: header,
        children: [for (final r in group.value) _tile(t, r)],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: CarbonSpacing.spacing03,
      children: [
        Semantics(
          header: true,
          child: Text(
            header,
            style: t.typography.heading.copyWith(color: t.colors.textPrimary),
          ),
        ),
        CarbonDataTable(
          columns: const [
            CarbonDataTableColumn(label: 'Status', width: _statusColumn),
            CarbonDataTableColumn(label: 'Schedule'),
            CarbonDataTableColumn(label: 'Time', width: _timeColumn),
            CarbonDataTableColumn(label: 'Trigger', width: _triggerColumn),
            CarbonDataTableColumn(
              label: 'Duration',
              width: _durationColumn,
              align: CarbonDataTableAlign.end,
            ),
            CarbonDataTableColumn(
              label: '',
              width: _actionsColumn,
              align: CarbonDataTableAlign.end,
            ),
          ],
          rows: [for (final r in group.value) _tableRow(t, r)],
        ),
      ],
    );
  }

  Duration? _elapsed(ScheduleRun r) {
    final start = r.startedAt;
    // A missed or skipped record never ran, so it has no end to measure to.
    if (start == null || (!r.active && r.finishedAt == null)) return null;
    return (r.finishedAt ?? widget.now).difference(start);
  }

  String? _sub(ScheduleRun r) {
    final schedule = _schedule(r);
    final parts = <String>[
      if (schedule != null) widget.agentLabel(schedule.agentId),
      ?_project(r),
      if (_isCatchUp(r) && r.missedCount != null)
        '${schedulerMissedLabel(r.missedCount)} while closed'
      else if (!_isCatchUp(r) && r.reason != null)
        r.reason!,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  Widget _status(CarbonThemeData t, ScheduleRun r) {
    final indicator = CarbonIconIndicator(
      kind: schedulerRunIndicator(r.status, trigger: r.trigger),
      label: schedulerRunStatusWord(r.status, trigger: r.trigger),
    );
    if (r.status != 'needs-input') return indicator;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: CarbonSpacing.spacing01,
      children: [
        indicator,
        Padding(
          // Under the label, past the glyph and its gap.
          padding: EdgeInsetsDirectional.only(
            start: t.iconSize + CarbonSpacing.spacing03,
          ),
          child: Text(
            schedulerWaiting(_when(r), widget.now),
            style: t.typography.helper.copyWith(color: t.colors.textSecondary),
          ),
        ),
      ],
    );
  }

  Widget _title(CarbonThemeData t, ScheduleRun r) {
    final schedule = _schedule(r);
    final sub = _sub(r);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: CarbonSpacing.spacing01,
      children: [
        if (schedule != null)
          CarbonLink(
            label: _name(r),
            onPressed: () => widget.onEditSchedule(schedule),
          )
        else
          Text(
            _name(r),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t.typography.heading.copyWith(color: t.colors.textPrimary),
          ),
        if (schedule != null || sub != null)
          Row(
            spacing: CarbonSpacing.spacing02,
            children: [
              if (schedule != null)
                AbAgentMark(
                  toolKey: schedule.agentId,
                  label: widget.agentLabel(schedule.agentId),
                  size: t.iconSize,
                  color: t.colors.iconSecondary,
                ),
              if (sub != null)
                Flexible(
                  child: Text(
                    sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.typography.helper.copyWith(
                      color: t.colors.textSecondary,
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }

  Widget _time(CarbonThemeData t, ScheduleRun r) => CarbonTooltip(
    message: schedulerUtcLabel(_when(r)),
    child: Text(
      schedulerClock(_when(r), widget.viewerZone),
      style: t.typography.code.copyWith(color: t.colors.textPrimary),
    ),
  );

  Widget _action(
    ScheduleRun r, {
    required Key key,
    required String label,
    required void Function(ScheduleRun) onTap,
    required CarbonButtonKind kind,
    Widget? icon,
  }) {
    return CarbonButton(
      key: key,
      label: label,
      kind: kind,
      size: CarbonButtonSize.small,
      icon: icon,
      semanticLabel: '$label for ${_name(r)}',
      onPressed: widget.enabled ? () => onTap(r) : null,
    );
  }

  Widget _actions(ScheduleRun r, {bool details = false}) {
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: CarbonSpacing.spacing03,
      runSpacing: CarbonSpacing.spacing03,
      children: [
        if (r.active)
          _action(
            r,
            key: ValueKey('scheduler-run-stop-${r.id}'),
            label: 'Stop',
            onTap: widget.onStop,
            kind: CarbonButtonKind.dangerGhost,
          ),
        if (r.sessionId != null)
          _action(
            r,
            key: ValueKey('scheduler-run-open-${r.id}'),
            label: 'Open session',
            onTap: widget.onOpenSession,
            // Needs-input is the one state a person must act on.
            kind: r.status == 'needs-input'
                ? CarbonButtonKind.primary
                : CarbonButtonKind.ghost,
            icon: const CarbonIcon(CarbonIcons.launch),
          ),
        if (details) _detailsToggle(r),
      ],
    );
  }

  Widget _detailsToggle(ScheduleRun r) {
    final open = _expanded.contains(r.id);
    return CarbonButton(
      label: 'Details',
      kind: CarbonButtonKind.ghost,
      size: CarbonButtonSize.small,
      expanded: open,
      icon: CarbonIcon(open ? CarbonIcons.chevronUp : CarbonIcons.chevronDown),
      onPressed: () => _toggle(r),
    );
  }

  String _trigger(ScheduleRun r) =>
      // The status cell already carries the wait, and a missed record's status
      // word and sub-line already say Missed.
      r.trigger == 'missed' ? '' : schedulerTrigger(r.trigger);

  String _duration(ScheduleRun r) =>
      r.status == 'needs-input' ? '—' : schedulerDurationPadded(_elapsed(r));

  CarbonDataTableRow _tableRow(CarbonThemeData t, ScheduleRun r) {
    final hasActions = r.active || r.sessionId != null || _isCatchUp(r);
    final open = _expanded.contains(r.id);
    return CarbonDataTableRow(
      key: ValueKey('scheduler-run-${r.id}'),
      selected: r.id == widget.focusedRunId,
      expansion: _isCatchUp(r) && open ? _details(t, r) : null,
      cells: [
        _status(t, r),
        _title(t, r),
        _time(t, r),
        Text(_trigger(r)),
        Text(
          _duration(r),
          style: t.typography.code.copyWith(color: t.colors.textSecondary),
        ),
        if (hasActions)
          _actions(r, details: _isCatchUp(r))
        else
          const SizedBox.shrink(),
      ],
    );
  }

  Widget _tile(CarbonThemeData t, ScheduleRun r) {
    final level = CarbonLayer.of(context);
    final focused = r.id == widget.focusedRunId;
    final hasActions = r.active || r.sessionId != null;
    final open = _expanded.contains(r.id);
    final line = r.active
        ? schedulerActiveRunLine(r, widget.now)
        : schedulerRunStatusWord(r.status, trigger: r.trigger);
    final trigger = _trigger(r);
    return DecoratedBox(
      key: ValueKey('scheduler-run-${r.id}'),
      decoration: BoxDecoration(
        color: focused ? t.layerSelected(level) : t.layer(level),
        border: Border(
          bottom: BorderSide(
            color: t.borderSubtle(level),
            width: CarbonBorders.hairline,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: CarbonSpacing.spacing05,
          vertical: CarbonSpacing.spacing04,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: CarbonSpacing.spacing03,
          children: [
            Row(
              spacing: CarbonSpacing.spacing03,
              children: [
                SchedulerStatusGlyph.run(r.status, trigger: r.trigger),
                Expanded(
                  child: Text(
                    line,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.typography.heading.copyWith(
                      color: t.colors.textPrimary,
                    ),
                  ),
                ),
                _time(t, r),
              ],
            ),
            _title(t, r),
            // Wraps: neither text can shrink, and at large text on a narrow
            // phone the pair is wider than the row.
            Wrap(
              spacing: CarbonSpacing.spacing03,
              children: [
                if (trigger.isNotEmpty)
                  Text(
                    trigger,
                    style: t.typography.helper.copyWith(
                      color: t.colors.textSecondary,
                    ),
                  ),
                if (!r.active && _elapsed(r) != null)
                  Text(
                    _duration(r),
                    style: t.typography.code.copyWith(
                      color: t.colors.textSecondary,
                    ),
                  ),
              ],
            ),
            if (hasActions) _actions(r),
            if (_isCatchUp(r)) _detailsToggle(r),
            if (_isCatchUp(r) && open) _details(t, r),
          ],
        ),
      ),
    );
  }

  Widget _details(CarbonThemeData t, ScheduleRun r) {
    final zone = r.timezone ?? _schedule(r)?.timezone ?? widget.viewerZone;
    final labelStyle = t.typography.label.copyWith(
      color: t.colors.textSecondary,
    );
    final valueStyle = t.typography.control.copyWith(
      color: t.colors.textPrimary,
    );
    final monoValue = t.typography.code.copyWith(color: t.colors.textPrimary);
    final why =
        r.reason ??
        (r.trigger == 'missed'
            ? 'Antgrid was not open when this was due.'
            : 'Antgrid opened after a missed time, so the latest one was run.');
    final until = r.missedUntil;
    final missedSpan = until != null && until != r.occurrenceAt;
    final rows = <(String, Widget)>[
      ('Why', Text(why, style: valueStyle)),
      (
        'Missed',
        Text.rich(
          TextSpan(
            style: valueStyle,
            children: [
              TextSpan(
                text: schedulerWallCompact(
                  r.occurrenceAt,
                  widget.viewerZone,
                  widget.now,
                ),
                style: monoValue,
              ),
              if (missedSpan) ...[
                const TextSpan(text: ' to '),
                TextSpan(
                  text: schedulerWallCompact(
                    until,
                    widget.viewerZone,
                    widget.now,
                  ),
                  style: monoValue,
                ),
              ],
              if (r.missedCount != null)
                TextSpan(text: ' · ${schedulerMissedLabel(r.missedCount)}'),
            ],
          ),
        ),
      ),
      if (schedulerZoneNote(zone, widget.viewerZone) != null)
        (
          'Schedule time',
          Text(
            '${schedulerClock(r.occurrenceAt, zone)} $zone',
            style: monoValue,
          ),
        ),
      if (r.sessionId != null)
        (
          'Session',
          CarbonLink(
            label:
                '${_name(r)} · ${r.sessionId!.substring(0, r.sessionId!.length < 4 ? r.sessionId!.length : 4)}',
            onPressed: widget.enabled ? () => widget.onOpenSession(r) : null,
          ),
        ),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: CarbonSpacing.spacing02),
      child: CarbonLayerSurface(
        border: true,
        padding: const EdgeInsets.all(CarbonSpacing.spacing05),
        child: widget.compact
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: CarbonSpacing.spacing03,
                children: [
                  for (final (label, value) in rows)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label, style: labelStyle),
                        value,
                      ],
                    ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: CarbonSpacing.spacing03,
                children: [
                  for (final (label, value) in rows)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: CarbonSpacing.spacing05,
                      children: [
                        SizedBox(
                          width: _detailLabelWidth,
                          child: Text(label, style: labelStyle),
                        ),
                        Expanded(child: value),
                      ],
                    ),
                ],
              ),
      ),
    );
  }
}
