import 'package:flutter/widgets.dart';

import '../../design/ab_colors.dart';
import '../../design/ab_icons.dart';
import '../../design/ab_status_tone.dart';
import '../../design/ab_tokens.dart';
import '../../design/widgets/ab_agent_mark.dart';
import '../../design/widgets/ab_button.dart';
import '../../design/widgets/ab_chip.dart';
import '../../design/widgets/ab_disclosure.dart';
import '../../design/widgets/ab_empty_state.dart';
import '../../design/widgets/ab_icon.dart';
import '../../design/widgets/ab_menu.dart';
import '../../design/widgets/ab_section_header.dart';
import '../../design/widgets/ab_separator.dart';
import '../../design/widgets/ab_status_dot.dart';
import '../../design/widgets/ab_tap_target.dart';
import '../../design/widgets/ab_tooltip.dart';
import '../../util/detached.dart';
import '../../models/scheduler.dart';
import 'scheduler_format.dart';

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

// Column widths of the desktop row grid; the detail panel indents by the
// status column so it lines up under the run name.
const double _statusColumn = 148;
const double _timeColumn = 52;
const double _triggerColumn = 84;
const double _durationColumn = 72;
const double _actionsColumn = 208;

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

  Future<void> _pickSchedule(BuildContext anchor) async {
    final rect = abMenuAnchorRect(anchor);
    if (rect == null) return;
    final schedules = [...widget.schedules]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final picked = await showAbMenu<String>(
      context: anchor,
      anchorRect: rect,
      entries: [
        AbMenuItem(
          label: 'All schedules',
          value: '',
          icon: widget.scheduleId == null ? AbIcons.check : null,
        ),
        if (schedules.isNotEmpty) const AbMenuDivider(),
        for (final s in schedules)
          AbMenuItem(
            label: s.name,
            value: s.id,
            icon: widget.scheduleId == s.id ? AbIcons.check : null,
          ),
      ],
    );
    if (picked == null || !mounted) return;
    widget.onScheduleFilter(picked.isEmpty ? null : picked);
  }

  Widget _toolbar(List<ScheduleRun> all) {
    final p = context.antgrid;
    final filterName = widget.scheduleId == null
        ? 'All schedules'
        : widget.schedules
                  .where((s) => s.id == widget.scheduleId)
                  .firstOrNull
                  ?.name ??
              'Schedule';
    final zone = Text(
      'Times in ${widget.viewerZone}',
      style: AbTokens.sansStyle(
        fontSize: AbTokens.fontSm,
        color: p.textSecondary,
      ),
    );
    final chips = Wrap(
      spacing: AbTokens.space8,
      runSpacing: AbTokens.space4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final f in _RunFilter.values)
          AbChip.choice(
            key: ValueKey('scheduler-runs-filter-${f.name}'),
            label:
                '${_filterLabel(f)} ${all.where((r) => _matches(f, r)).length}',
            selected: _filter == f,
            onTap: () => setState(() => _filter = f),
          ),
        Builder(
          builder: (anchor) => AbTapTarget(
            onTap: () => detached(
              'Scheduler',
              'schedule filter failed',
              () => _pickSchedule(anchor),
            ),
            child: Container(
              key: const ValueKey('scheduler-runs-schedule-filter'),
              padding: const EdgeInsets.symmetric(
                horizontal: AbTokens.space10,
                vertical: AbTokens.space4,
              ),
              decoration: BoxDecoration(
                border: Border.all(
                  color: widget.scheduleId == null
                      ? p.borderStrong
                      : p.textSecondary,
                ),
                borderRadius: AbTokens.borderRadius3,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: AbTokens.space6,
                children: [
                  Flexible(
                    child: Text(
                      filterName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AbTokens.sansStyle(
                        fontSize: AbTokens.fontSm,
                        fontWeight: FontWeight.w500,
                        color: widget.scheduleId == null
                            ? p.textSecondary
                            : p.textPrimary,
                      ),
                    ),
                  ),
                  AbIcon(
                    AbIcons.chevronDown,
                    size: AbTokens.fontSm,
                    color: p.textMuted,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
    if (widget.compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: AbTokens.space8,
        children: [chips, zone],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      spacing: AbTokens.space12,
      children: [
        Expanded(child: chips),
        zone,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.antgrid;
    final all = _sorted();
    final shown = all.where((r) => _matches(_filter, r)).toList();
    final showToolbar = all.isNotEmpty || widget.scheduleId != null;
    final padding = widget.compact ? AbTokens.space12 : AbTokens.space16;
    return ListView(
      padding: EdgeInsets.all(padding),
      children: [
        if (showToolbar)
          Padding(
            padding: const EdgeInsets.only(bottom: AbTokens.space12),
            child: _toolbar(all),
          ),
        if (all.isEmpty)
          const AbEmptyState(title: schedulerNoRunsHint)
        else if (shown.isEmpty)
          const AbEmptyState.compact(title: 'No runs match this filter')
        else
          for (final group in _groups(shown))
            Padding(
              key: ValueKey('scheduler-runs-day-${group.key}'),
              padding: const EdgeInsets.only(bottom: AbTokens.space16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: AbTokens.space8,
                children: [
                  AbSectionHeader(
                    label: schedulerDayHeader(
                      _when(group.value.first),
                      widget.viewerZone,
                      widget.now,
                    ),
                    color: p.textSecondary,
                    padding: const EdgeInsets.only(left: AbTokens.space4),
                  ),
                  Container(
                    decoration: BoxDecoration(
                      color: p.bgSurface,
                      border: Border.all(color: p.borderSubtle),
                      borderRadius: AbTokens.borderRadius8,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        for (var i = 0; i < group.value.length; i++) ...[
                          if (i > 0) const AbSeparator.horizontal(),
                          _row(group.value[i]),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  AbStatusTone _tone(SchedulerRunTone t) => switch (t) {
    SchedulerRunTone.active => AbStatusTone.info,
    SchedulerRunTone.attention => AbStatusTone.warning,
    SchedulerRunTone.success => AbStatusTone.success,
    SchedulerRunTone.error => AbStatusTone.danger,
    SchedulerRunTone.muted => AbStatusTone.agentIdle,
    SchedulerRunTone.warning => AbStatusTone.warning,
  };

  Color _wordColor(SchedulerRunTone t) {
    final p = context.antgrid;
    return switch (t) {
      SchedulerRunTone.active => p.accent,
      SchedulerRunTone.attention || SchedulerRunTone.warning => p.warning,
      SchedulerRunTone.error => p.error,
      SchedulerRunTone.success => p.textPrimary,
      SchedulerRunTone.muted => p.textSecondary,
    };
  }

  Duration? _elapsed(ScheduleRun r) {
    final start = r.startedAt;
    // A missed or skipped record never ran, so it has no end to measure to.
    if (start == null || (!r.active && r.finishedAt == null)) return null;
    return (r.finishedAt ?? widget.now).difference(start);
  }

  String? _sub(ScheduleRun r) {
    final parts = <String>[
      ?_project(r),
      if (_isCatchUp(r) && r.missedCount != null)
        '${schedulerMissedLabel(r.missedCount)} while closed'
      else if (!_isCatchUp(r) && r.reason != null)
        r.reason!,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  Widget _status(ScheduleRun r) {
    final tone = schedulerRunTone(r.status, trigger: r.trigger);
    final word = schedulerRunStatusWord(r.status, trigger: r.trigger);
    final since = _when(r);
    return Row(
      spacing: AbTokens.space8,
      children: [
        AbStatusDot(
          tone: _tone(tone),
          style:
              tone == SchedulerRunTone.muted || tone == SchedulerRunTone.warning
              ? AbDotStyle.hollow
              : AbDotStyle.filled,
          pulse: tone == SchedulerRunTone.active,
        ),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                word,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AbTokens.sansStyle(
                  fontSize: AbTokens.fontSm,
                  fontWeight: FontWeight.w600,
                  color: _wordColor(tone),
                ),
              ),
              if (r.status == 'needs-input')
                Text(
                  schedulerWaiting(since, widget.now),
                  style: AbTokens.sansStyle(
                    fontSize: AbTokens.fontXs,
                    color: context.antgrid.textSecondary,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _title(ScheduleRun r) {
    final p = context.antgrid;
    final schedule = _schedule(r);
    final sub = _sub(r);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AbTokens.space2,
      children: [
        Text(
          _name(r),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AbTokens.sansStyle(
            fontSize: AbTokens.fontMd,
            fontWeight: FontWeight.w600,
            color: p.textPrimary,
          ),
        ),
        if (schedule != null || sub != null)
          Row(
            spacing: AbTokens.space6,
            children: [
              if (schedule != null)
                AbAgentMark(
                  toolKey: schedule.agentId,
                  label: widget.agentLabel(schedule.agentId),
                  size: AbTokens.fontSm,
                ),
              if (sub != null)
                Flexible(
                  child: Text(
                    sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontXs,
                      color: p.textSecondary,
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }

  Widget _time(ScheduleRun r) => AbTooltip(
    message: schedulerUtcLabel(_when(r)),
    child: Text(
      schedulerClock(_when(r), widget.viewerZone),
      style: AbTokens.monoStyle(
        fontSize: AbTokens.fontMd,
        color: context.antgrid.textPrimary,
      ),
    ),
  );

  Widget _action(
    ScheduleRun r, {
    required Key key,
    required String label,
    required void Function(ScheduleRun) onTap,
    Color? color,
    Widget? leading,
  }) {
    final tap = widget.enabled ? () => onTap(r) : null;
    return Semantics(
      label: '$label for ${_name(r)}',
      button: true,
      enabled: widget.enabled,
      excludeSemantics: true,
      onTap: tap,
      child: AbButton(
        key: key,
        label: label,
        color: color,
        leading: leading,
        onTap: tap,
      ),
    );
  }

  Widget _actions(ScheduleRun r) {
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: AbTokens.space6,
      runSpacing: AbTokens.space6,
      children: [
        if (r.active)
          _action(
            r,
            key: ValueKey('scheduler-run-stop-${r.id}'),
            label: 'Stop',
            onTap: widget.onStop,
            color: context.antgrid.error,
          ),
        if (r.sessionId != null)
          _action(
            r,
            key: ValueKey('scheduler-run-open-${r.id}'),
            label: 'Open session',
            onTap: widget.onOpenSession,
            leading: AbIcon(
              AbIcons.openExternal,
              size: AbTokens.fontXs,
              color: context.antgrid.textSecondary,
            ),
          ),
      ],
    );
  }

  Widget _row(ScheduleRun r) {
    final p = context.antgrid;
    final focused = r.id == widget.focusedRunId;
    final expandable = _isCatchUp(r);
    final open = _expanded.contains(r.id);
    final hasActions = r.active || r.sessionId != null;
    // The status cell already carries the wait, and a missed record's status
    // word and sub-line already say Missed.
    final trigger = r.trigger == 'missed' ? '' : schedulerTrigger(r.trigger);
    final duration = r.status == 'needs-input'
        ? '—'
        : schedulerDurationPadded(_elapsed(r));
    final dimStyle = AbTokens.sansStyle(
      fontSize: AbTokens.fontSm,
      color: p.textSecondary,
    );
    final durationStyle = AbTokens.monoStyle(
      fontSize: AbTokens.fontSm,
      color: p.textSecondary,
    );

    final Widget header;
    if (widget.compact) {
      final line = r.active
          ? schedulerActiveRunLine(r, widget.now)
          : schedulerRunStatusWord(r.status, trigger: r.trigger);
      final tone = schedulerRunTone(r.status, trigger: r.trigger);
      header = Padding(
        padding: const EdgeInsets.all(AbTokens.space12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: AbTokens.space6,
          children: [
            Row(
              spacing: AbTokens.space8,
              children: [
                AbStatusDot(
                  tone: _tone(tone),
                  style:
                      tone == SchedulerRunTone.muted ||
                          tone == SchedulerRunTone.warning
                      ? AbDotStyle.hollow
                      : AbDotStyle.filled,
                  pulse: tone == SchedulerRunTone.active,
                ),
                Expanded(
                  child: Text(
                    line,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AbTokens.sansStyle(
                      fontSize: AbTokens.fontSm,
                      fontWeight: FontWeight.w600,
                      color: _wordColor(tone),
                    ),
                  ),
                ),
                _time(r),
              ],
            ),
            _title(r),
            Row(
              spacing: AbTokens.space8,
              children: [
                if (trigger.isNotEmpty) Text(trigger, style: dimStyle),
                if (!r.active && _elapsed(r) != null)
                  Text(duration, style: durationStyle),
              ],
            ),
            if (hasActions) _actions(r),
          ],
        ),
      );
    } else {
      header = Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AbTokens.space16,
          vertical: AbTokens.space10,
        ),
        child: Row(
          spacing: AbTokens.space16,
          children: [
            SizedBox(width: _statusColumn, child: _status(r)),
            Expanded(child: _title(r)),
            SizedBox(width: _timeColumn, child: _time(r)),
            SizedBox(
              width: _triggerColumn,
              child: Text(trigger, style: dimStyle),
            ),
            SizedBox(
              width: _durationColumn,
              child: Text(duration, style: durationStyle),
            ),
            SizedBox(
              width: _actionsColumn,
              child: Align(
                alignment: Alignment.centerRight,
                child: hasActions ? _actions(r) : null,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      key: ValueKey('scheduler-run-${r.id}'),
      color: focused ? p.bgSelected : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          if (expandable)
            Padding(
              padding: EdgeInsets.only(
                left: widget.compact
                    ? AbTokens.space12
                    : AbTokens.space16 + _statusColumn + AbTokens.space16,
                right: AbTokens.space16,
                bottom: AbTokens.space8,
              ),
              child: AbDisclosure(
                label: 'Details',
                expanded: open,
                onToggle: () => setState(() {
                  if (!_expanded.add(r.id)) _expanded.remove(r.id);
                }),
                child: _details(r),
              ),
            ),
        ],
      ),
    );
  }

  Widget _details(ScheduleRun r) {
    final p = context.antgrid;
    final zone = r.timezone ?? _schedule(r)?.timezone ?? widget.viewerZone;
    final labelStyle = AbTokens.sansStyle(
      fontSize: AbTokens.fontSm,
      color: p.textSecondary,
    );
    final valueStyle = AbTokens.sansStyle(
      fontSize: AbTokens.fontSm,
      color: p.textPrimary,
    );
    final monoValue = AbTokens.monoStyle(
      fontSize: AbTokens.fontSm,
      color: p.textPrimary,
    );
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
          AbTapTarget(
            onTap: widget.enabled ? () => widget.onOpenSession(r) : null,
            child: Text(
              '${_name(r)} · ${r.sessionId!.substring(0, r.sessionId!.length < 4 ? r.sessionId!.length : 4)}',
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontSm,
                color: p.accent,
              ),
            ),
          ),
        ),
    ];
    return Container(
      margin: const EdgeInsets.only(top: AbTokens.space4),
      padding: const EdgeInsets.all(AbTokens.space12),
      decoration: BoxDecoration(
        color: p.bgDeep,
        border: Border.all(color: p.borderSubtle),
        borderRadius: AbTokens.borderRadius5,
      ),
      child: widget.compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: AbTokens.space8,
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
              spacing: AbTokens.space8,
              children: [
                for (final (label, value) in rows)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: AbTokens.space16,
                    children: [
                      SizedBox(
                        width: _timeColumn + _triggerColumn,
                        child: Text(label, style: labelStyle),
                      ),
                      Expanded(child: value),
                    ],
                  ),
              ],
            ),
    );
  }
}
