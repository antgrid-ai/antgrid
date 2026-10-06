import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/scheduler.dart';
import '../widgets/scheduler/scheduler_format.dart';
import 'auth.dart';
import 'scheduler.dart';

typedef SchedulerDraftKey = ({String machine, String? scheduleId});

class SchedulerDraft {
  SchedulerDraft({
    required Map<String, dynamic> values,
    required Map<String, dynamic> initialSaved,
    required this.frequency,
    required this.time,
    this.workspaceCreated = false,
    this.checkoutId,
  }) : values = Map.unmodifiable(values),
       initialSaved = Map.unmodifiable(initialSaved);

  final Map<String, dynamic> values;
  final Map<String, dynamic> initialSaved;
  final String frequency;
  final String time;
  final bool workspaceCreated;
  final String? checkoutId;
  bool get dirty =>
      !mapEquals(values, initialSaved) ||
      frequency != schedulerFrequency(initialSaved['cron'] as String) ||
      time != schedulerPresetTime(initialSaved['cron'] as String);
  bool changedSince(AgentSchedule schedule) =>
      !mapEquals(initialSaved, schedule.settings()) ||
      workspaceCreated != schedule.workspaceCreated ||
      checkoutId != schedule.checkoutId;

  SchedulerDraft edit(
    Map<String, dynamic> values,
    String frequency,
    String time,
  ) => SchedulerDraft(
    values: values,
    initialSaved: initialSaved,
    frequency: frequency,
    time: time,
    workspaceCreated: workspaceCreated,
    checkoutId: checkoutId,
  );

  SchedulerDraft keepChanges(AgentSchedule saved) => SchedulerDraft(
    values: values,
    initialSaved: saved.settings(),
    frequency: frequency,
    time: time,
    workspaceCreated: saved.workspaceCreated,
    checkoutId: saved.checkoutId,
  );

  factory SchedulerDraft.start(
    SchedulerSnapshot snapshot,
    AgentSchedule? schedule,
  ) {
    final values =
        schedule?.settings() ??
        {
          'name': '',
          'prompt': '',
          'projectId': snapshot.projects.first.projectId,
          'agentId': snapshot.capabilities.agents.first.agentId,
          'mode': snapshot.capabilities.agents.first.modes.first,
          'workspace': snapshot.projects.first.isGitRepository
              ? 'worktree'
              : 'shared',
          'approvalPolicy': 'default',
          'enabled': true,
          'cron': '0 9 * * *',
          'timezone': snapshot.capabilities.timezone,
        };
    return SchedulerDraft(
      values: values,
      initialSaved: values,
      frequency: schedulerFrequency(values['cron'] as String),
      time: schedulerPresetTime(values['cron'] as String),
      workspaceCreated: schedule?.workspaceCreated ?? false,
      checkoutId: schedule?.checkoutId,
    );
  }
}

final schedulerDraftsProvider =
    NotifierProvider<SchedulerDrafts, Map<SchedulerDraftKey, SchedulerDraft>>(
      SchedulerDrafts.new,
    );

/// Prompts live only in this account's running app session.
class SchedulerDrafts extends Notifier<Map<SchedulerDraftKey, SchedulerDraft>> {
  String? _account;
  @override
  Map<SchedulerDraftKey, SchedulerDraft> build() {
    _account = ref.read(currentUserProvider).value?.userId;
    ref.listen(currentUserProvider, (_, next) {
      if (!next.hasValue || next.isLoading) return;
      final account = next.value?.userId;
      if (account == null || (_account != null && account != _account)) clear();
      _account = account;
    });
    return const {};
  }

  SchedulerDraft open(
    SchedulerDraftKey key,
    SchedulerSnapshot snapshot,
    AgentSchedule? schedule,
  ) {
    final existing = state[key];
    if (existing != null) return existing;
    final draft = SchedulerDraft.start(snapshot, schedule);
    put(key, draft);
    return draft;
  }

  void put(SchedulerDraftKey key, SchedulerDraft draft) =>
      state = {...state, key: draft};
  void remove(SchedulerDraftKey key) => state = {...state}..remove(key);
  void removeIfCurrent(SchedulerDraftKey key, SchedulerDraft draft) {
    if (identical(state[key], draft)) remove(key);
  }

  void clear() => state = const {};
}
