/// Hand mirror of the bridge scheduler API. Dates are host-provided instants;
/// cron evaluation belongs exclusively to the target machine.
class SchedulerAgent {
  final String agentId;
  final List<String> modes;
  const SchedulerAgent({required this.agentId, required this.modes});
  factory SchedulerAgent.fromJson(Map<String, dynamic> json) => SchedulerAgent(
    agentId: json['agentId'] as String,
    modes: (json['modes'] as List).cast<String>(),
  );
}

class SchedulerCapabilities {
  final bool supported;
  final String timezone;
  final List<SchedulerAgent> agents;
  final String? error;
  final bool supportsBaseBranchClear;
  const SchedulerCapabilities({
    required this.supported,
    required this.timezone,
    required this.agents,
    this.error,
    this.supportsBaseBranchClear = false,
  });
  factory SchedulerCapabilities.fromJson(Map<String, dynamic> json) =>
      SchedulerCapabilities(
        supported: json['supported'] == true,
        timezone: json['timezone'] as String? ?? 'UTC',
        agents: schedulerMaps(
          json['agents'],
        ).map(SchedulerAgent.fromJson).toList(),
        error: json['error'] as String?,
        supportsBaseBranchClear: json['supportsBaseBranchClear'] == true,
      );
}

class SchedulerProject {
  final String projectId;
  final String name;
  final bool isGitRepository;
  const SchedulerProject({
    required this.projectId,
    required this.name,
    required this.isGitRepository,
  });
  factory SchedulerProject.fromJson(Map<String, dynamic> json) =>
      SchedulerProject(
        projectId: json['projectId'] as String,
        name:
            json['label'] as String? ??
            json['name'] as String? ??
            json['projectId'] as String,
        isGitRepository: json['isGitRepository'] == true,
      );
}

class AgentSchedule {
  final String id;
  final String name;
  final String projectId;
  final String agentId;
  final String mode;
  final String prompt;
  final String approvalPolicy;
  final String workspace;
  final String? baseBranch;
  final String cron;
  final String timezone;
  final bool enabled;
  final String? checkoutId;
  final bool workspaceCreated;
  final String? authorDeviceId;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;
  final DateTime? nextOccurrence;
  final String? lastResult;
  const AgentSchedule({
    required this.id,
    required this.name,
    required this.projectId,
    required this.agentId,
    required this.mode,
    required this.prompt,
    required this.approvalPolicy,
    required this.workspace,
    this.baseBranch,
    required this.cron,
    required this.timezone,
    required this.enabled,
    this.checkoutId,
    this.workspaceCreated = false,
    this.authorDeviceId,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
    this.nextOccurrence,
    this.lastResult,
  });
  factory AgentSchedule.fromJson(Map<String, dynamic> json) => AgentSchedule(
    id: json['id'] as String,
    name: json['name'] as String,
    projectId: json['projectId'] as String,
    agentId: json['agentId'] as String,
    mode: json['mode'] as String,
    prompt: json['prompt'] as String,
    approvalPolicy: json['approvalPolicy'] as String,
    workspace: json['workspace'] as String,
    baseBranch: json['baseBranch'] as String?,
    cron: json['cron'] as String,
    timezone: json['timezone'] as String,
    enabled: json['enabled'] == true,
    checkoutId: json['checkoutId'] as String?,
    workspaceCreated: json['workspaceCreated'] == true,
    authorDeviceId: json['authorDeviceId'] as String?,
    createdAt: schedulerDate(json['createdAt']),
    updatedAt: schedulerDate(json['updatedAt']),
    deletedAt: schedulerDate(json['deletedAt']),
    nextOccurrence: schedulerDate(json['nextOccurrence']),
    lastResult: json['lastResult'] as String?,
  );
  Map<String, dynamic> settings() => {
    'name': name,
    'projectId': projectId,
    'agentId': agentId,
    'mode': mode,
    'prompt': prompt,
    'approvalPolicy': approvalPolicy,
    'workspace': workspace,
    'baseBranch': ?baseBranch,
    'cron': cron,
    'timezone': timezone,
    'enabled': enabled,
  };
}

class ScheduleRun {
  final String? timezone;
  final String id;
  final String scheduleId;
  final String? scheduleName;
  final String projectId;
  final String status;
  final String trigger;
  final DateTime occurrenceAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final String? reason;
  final String? sessionId;
  final String? runtimeGeneration;
  final String? checkoutId;
  final DateTime? missedUntil;
  const ScheduleRun({
    this.timezone,
    required this.id,
    required this.scheduleId,
    this.scheduleName,
    required this.projectId,
    required this.status,
    required this.trigger,
    required this.occurrenceAt,
    this.startedAt,
    this.finishedAt,
    this.reason,
    this.sessionId,
    this.runtimeGeneration,
    this.checkoutId,
    this.missedUntil,
  });
  bool get active =>
      const {'preparing', 'running', 'needs-input'}.contains(status);
  Duration? get duration => startedAt == null
      ? null
      : (finishedAt ?? DateTime.now()).difference(startedAt!);
  factory ScheduleRun.fromJson(Map<String, dynamic> json) => ScheduleRun(
    timezone: json['timezone'] as String?,
    id: json['id'] as String,
    scheduleId: json['scheduleId'] as String,
    scheduleName: json['scheduleName'] as String?,
    projectId: json['projectId'] as String,
    status: json['status'] as String,
    trigger: json['trigger'] as String,
    occurrenceAt: schedulerDate(json['occurrenceAt'])!,
    startedAt: schedulerDate(json['startedAt']),
    finishedAt: schedulerDate(json['finishedAt']),
    reason: json['reason'] as String?,
    sessionId: json['sessionId'] as String?,
    runtimeGeneration: json['runtimeGeneration'] as String?,
    checkoutId: json['checkoutId'] as String?,
    missedUntil: schedulerDate(json['missedUntil']),
  );
}

DateTime? schedulerDate(Object? raw) => raw is num
    ? DateTime.fromMillisecondsSinceEpoch(raw.toInt(), isUtc: true)
    : raw is String
    ? DateTime.parse(raw)
    : null;
List<Map<String, dynamic>> schedulerMaps(Object? raw) => raw is List
    ? raw.map((e) => (e as Map).cast<String, dynamic>()).toList()
    : const [];
