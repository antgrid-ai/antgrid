import 'package:timezone/timezone.dart' as tz;

import '../demo_cron.dart';
import '../demo_identity.dart';
import 'demo_workspace_fixtures.dart';

const String kDemoSchedulerMachineName = 'Sample machine';

/// Display names for the sample's agents. Kept out of the persisted agent
/// catalog on purpose: the sample must leave nothing on disk.
const Map<String, String> kDemoSchedulerAgentLabels = <String, String>{
  'claude-code': 'Claude Code',
  'codex': 'Codex',
};

const String kDemoScheduleNightlyId = 'demo-schedule-nightly',
    kDemoScheduleNightlyName = 'Nightly test run';
const String kDemoScheduleSmokeId = 'demo-schedule-smoke',
    kDemoScheduleSmokeName = 'Checkout smoke test';
const String kDemoScheduleDepsId = 'demo-schedule-deps',
    kDemoScheduleDepsName = 'Weekly dependency updates';
const String kDemoScheduleReleaseNotesId = 'demo-schedule-release-notes',
    kDemoScheduleReleaseNotesName = 'Draft release notes';
const String kDemoScheduleTagId = 'demo-schedule-tag-release',
    kDemoScheduleTagName = 'Tag the 1.4 release';

/// The one run the finished one-off points at. Pinned because the row's
/// outcome ("Ran · ...") is looked up by this id.
const String kDemoTagReleaseRunId = 'demo-run-tag-release';

// Run lengths vary around a schedule's typical length so the Runs tab does not
// read as a column of identical durations.
const List<double> _kDurationFactors = <double>[
  1.0, 0.85, 1.2, 0.95, 1.1, 0.9, 1.3, 1.05, //
];

/// The length of the [index]th run of a schedule whose runs typically take
/// [typical].
Duration demoRunDuration(Duration typical, int index) => Duration(
  milliseconds: (typical.inMilliseconds * _kDurationFactors[index % _kDurationFactors.length]).round(),
);

/// A schedule as the sample machine holds it. Mutable because the backend
/// edits it in place; callers outside the backend should not keep one.
class DemoScheduleRecord {
  DemoScheduleRecord({
    required this.id,
    required this.name,
    required this.prompt,
    required this.projectId,
    required this.agentId,
    required this.mode,
    required this.approvalPolicy,
    required this.catchUp,
    required this.workspace,
    required this.timezone,
    required this.enabled,
    required this.createdAt,
    required this.updatedAt,
    required this.typical,
    required this.sessionId,
    this.chatMode,
    this.baseBranch,
    this.cron,
    this.runAt,
    this.checkoutId,
    this.workspaceCreated = false,
    this.firedRunId,
    this.firedAt,
    this.deletedAt,
    this.nextOccurrence,
    this.runsMade = 0,
  });

  String id;
  String name;
  String prompt;
  String projectId;
  String agentId;
  String mode;
  String approvalPolicy;
  String catchUp;
  String workspace;
  String timezone;
  bool enabled;
  DateTime createdAt;
  DateTime updatedAt;

  /// How long this schedule's runs usually take, and the sample session each
  /// of them is attached to.
  Duration typical;
  String sessionId;

  String? chatMode;
  String? baseBranch;
  String? cron;
  DateTime? runAt;
  String? checkoutId;
  bool workspaceCreated;
  String? firedRunId;
  DateTime? firedAt;
  DateTime? deletedAt;
  DateTime? nextOccurrence;

  /// Runs created so far, which picks the next run's length from the factor
  /// table.
  int runsMade;

  /// Id with the `demo-schedule-` prefix removed, for naming its runs.
  String get shortName => id.startsWith('demo-schedule-')
      ? id.substring('demo-schedule-'.length)
      : id;

  DemoScheduleRecord copy() => DemoScheduleRecord(
    id: id,
    name: name,
    prompt: prompt,
    projectId: projectId,
    agentId: agentId,
    mode: mode,
    approvalPolicy: approvalPolicy,
    catchUp: catchUp,
    workspace: workspace,
    timezone: timezone,
    enabled: enabled,
    createdAt: createdAt,
    updatedAt: updatedAt,
    typical: typical,
    sessionId: sessionId,
    chatMode: chatMode,
    baseBranch: baseBranch,
    cron: cron,
    runAt: runAt,
    checkoutId: checkoutId,
    workspaceCreated: workspaceCreated,
    firedRunId: firedRunId,
    firedAt: firedAt,
    deletedAt: deletedAt,
    nextOccurrence: nextOccurrence,
    runsMade: runsMade,
  );
}

/// One run as the sample machine holds it. Its status is not stored: the
/// backend derives it from the clock each time the run is read.
class DemoRunRecord {
  DemoRunRecord({
    required this.id,
    required this.scheduleId,
    required this.scheduleName,
    required this.projectId,
    required this.trigger,
    required this.timezone,
    required this.sessionId,
    required this.occurrenceAt,
    required this.startedAt,
    required this.duration,
    this.checkoutId,
    this.stoppedAt,
  });

  final String id;
  final String scheduleId;
  final String scheduleName;
  final String projectId;
  final String trigger;
  final String timezone;
  final String sessionId;
  final String? checkoutId;
  final DateTime occurrenceAt;
  final DateTime startedAt;
  final Duration duration;
  DateTime? stoppedAt;
}

typedef DemoSchedulerSeed = ({
  List<DemoScheduleRecord> schedules,
  List<DemoRunRecord> runs,
});

const String _kPromptNightly =
    'Run the full test suite. If anything fails, find the cause, fix it on '
    'this branch and summarise what changed.';
const String _kPromptSmoke =
    'Walk the checkout flow end to end with the smoke script and report any '
    'step that fails or runs noticeably slower than before.';
const String _kPromptDeps =
    'Check for outdated dependencies, update the safe ones, run the tests and '
    'list anything that needs a manual decision.';
const String _kPromptReleaseNotes =
    'Draft release notes from the merged pull requests since the last tag, '
    'grouped by area, in plain language.';
const String _kPromptTag =
    'Tag the 1.4 release on main and write the tag message from the changelog.';

/// The sample machine's schedules and history, anchored at [anchor] and read in
/// [zone].
///
/// Pure in its inputs, like `demoTranscripts`. Every seeded run has finished by
/// the anchor and every enabled timetable's next occurrence lies after it, so
/// entering the sample never shows a run in progress or one about to start
/// before the viewer has touched anything.
DemoSchedulerSeed demoSchedulerSeed(DateTime anchor, tz.Location zone) {
  final a = anchor.toUtc();
  final zoneName = demoZoneName(zone);
  final schedules = <DemoScheduleRecord>[];
  final runs = <DemoRunRecord>[];

  DateTime nextAfter(String cron, DateTime from) =>
      DemoCron.parse(cron).after(from, zone, count: 1).first;

  // The wall-clock hour containing [instant], as an instant. Rounding in wall
  // time keeps the one-offs on the hour whatever the zone's offset.
  DateTime hourOf(DateTime instant) {
    final local = tz.TZDateTime.from(instant, zone);
    final floored = tz.TZDateTime(
      zone,
      local.year,
      local.month,
      local.day,
      local.hour,
    );
    return DateTime.fromMillisecondsSinceEpoch(
      floored.millisecondsSinceEpoch,
      isUtc: true,
    );
  }

  void seedCronRuns(
    DemoScheduleRecord s, {
    required DateTime from,
    required DateTime to,
    required int limit,
  }) {
    final all = DemoCron.parse(
      s.cron!,
    ).after(from, zone, count: 400).where((o) => !o.isAfter(to)).toList();
    final kept = all.length > limit ? all.sublist(all.length - limit) : all;
    for (var i = 0; i < kept.length; i++) {
      final occ = kept[i];
      final started = occ.add(const Duration(seconds: 1));
      final duration = demoRunDuration(s.typical, i);
      // A run still going at the anchor would be live on entry.
      if (started.add(duration).isAfter(a)) continue;
      runs.add(
        DemoRunRecord(
          id: 'demo-run-${s.shortName}-${occ.millisecondsSinceEpoch}',
          scheduleId: s.id,
          scheduleName: s.name,
          projectId: kDemoProjectId,
          trigger: 'cron',
          timezone: zoneName,
          sessionId: s.sessionId,
          checkoutId: s.workspace == 'worktree' ? s.checkoutId : null,
          occurrenceAt: occ,
          startedAt: started,
          duration: duration,
        ),
      );
      s.runsMade++;
    }
  }

  final nightly = DemoScheduleRecord(
    id: kDemoScheduleNightlyId,
    name: kDemoScheduleNightlyName,
    prompt: _kPromptNightly,
    projectId: kDemoProjectId,
    agentId: 'claude-code',
    mode: 'chat',
    chatMode: 'acceptEdits',
    approvalPolicy: 'default',
    catchUp: 'latest',
    workspace: 'worktree',
    baseBranch: 'main',
    checkoutId: 'nightly-test-run',
    workspaceCreated: true,
    cron: '0 2 * * *',
    timezone: zoneName,
    enabled: true,
    createdAt: a.subtract(const Duration(days: 12)),
    updatedAt: a.subtract(const Duration(days: 12)),
    typical: const Duration(minutes: 4, seconds: 10),
    sessionId: kDemoSessionCartId,
    nextOccurrence: nextAfter('0 2 * * *', a),
  );
  seedCronRuns(
    nightly,
    from: a.subtract(const Duration(days: 10)),
    to: a,
    limit: 10,
  );

  final smoke = DemoScheduleRecord(
    id: kDemoScheduleSmokeId,
    name: kDemoScheduleSmokeName,
    prompt: _kPromptSmoke,
    projectId: kDemoProjectId,
    agentId: 'claude-code',
    mode: 'terminal',
    approvalPolicy: 'default',
    catchUp: 'latest',
    workspace: 'shared',
    workspaceCreated: true,
    cron: '0 * * * *',
    timezone: zoneName,
    enabled: true,
    createdAt: a.subtract(const Duration(days: 2)),
    updatedAt: a.subtract(const Duration(days: 2)),
    typical: const Duration(minutes: 1, seconds: 20),
    sessionId: kDemoSessionCheckoutId,
    nextOccurrence: nextAfter('0 * * * *', a),
  );
  seedCronRuns(
    smoke,
    from: a.subtract(const Duration(hours: 12)),
    to: a,
    limit: 12,
  );

  // Paused a week ago: the stored next occurrence is the one it would have had
  // then, which the bridge also leaves in place on a paused schedule.
  final pausedAt = a.subtract(const Duration(days: 7));
  final deps = DemoScheduleRecord(
    id: kDemoScheduleDepsId,
    name: kDemoScheduleDepsName,
    prompt: _kPromptDeps,
    projectId: kDemoProjectId,
    agentId: 'codex',
    mode: 'terminal',
    approvalPolicy: 'default',
    catchUp: 'skip',
    workspace: 'worktree',
    baseBranch: 'main',
    checkoutId: 'weekly-dependency-updates',
    workspaceCreated: true,
    cron: '0 10 * * 1',
    timezone: zoneName,
    enabled: false,
    createdAt: a.subtract(const Duration(days: 40)),
    updatedAt: pausedAt,
    typical: const Duration(minutes: 6, seconds: 30),
    sessionId: kDemoSessionCartId,
    nextOccurrence: nextAfter('0 10 * * 1', pausedAt),
  );
  seedCronRuns(
    deps,
    from: a.subtract(const Duration(days: 35)),
    to: pausedAt,
    limit: 10,
  );

  final releaseNotes = DemoScheduleRecord(
    id: kDemoScheduleReleaseNotesId,
    name: kDemoScheduleReleaseNotesName,
    prompt: _kPromptReleaseNotes,
    projectId: kDemoProjectId,
    agentId: 'claude-code',
    mode: 'chat',
    chatMode: 'plan',
    approvalPolicy: 'default',
    catchUp: 'latest',
    workspace: 'shared',
    runAt: hourOf(a.add(const Duration(hours: 3))),
    timezone: zoneName,
    enabled: true,
    createdAt: a.subtract(const Duration(days: 1)),
    updatedAt: a.subtract(const Duration(days: 1)),
    typical: const Duration(minutes: 2),
    sessionId: kDemoSessionCheckoutId,
  )..nextOccurrence = hourOf(a.add(const Duration(hours: 3)));

  final tagAt = hourOf(a.subtract(const Duration(hours: 22)));
  final tagStarted = tagAt.add(const Duration(seconds: 1));
  final tag = DemoScheduleRecord(
    id: kDemoScheduleTagId,
    name: kDemoScheduleTagName,
    prompt: _kPromptTag,
    projectId: kDemoProjectId,
    agentId: 'claude-code',
    mode: 'terminal',
    approvalPolicy: 'default',
    catchUp: 'latest',
    workspace: 'shared',
    workspaceCreated: true,
    runAt: tagAt,
    timezone: zoneName,
    enabled: true,
    createdAt: a.subtract(const Duration(days: 3)),
    updatedAt: a.subtract(const Duration(days: 3)),
    typical: const Duration(minutes: 2, seconds: 35),
    sessionId: kDemoSessionCheckoutId,
    firedRunId: kDemoTagReleaseRunId,
    firedAt: tagStarted,
    nextOccurrence: tagAt,
    runsMade: 1,
  );
  runs.add(
    DemoRunRecord(
      id: kDemoTagReleaseRunId,
      scheduleId: tag.id,
      scheduleName: tag.name,
      projectId: kDemoProjectId,
      trigger: 'cron',
      timezone: zoneName,
      sessionId: tag.sessionId,
      occurrenceAt: tagAt,
      startedAt: tagStarted,
      duration: tag.typical,
    ),
  );

  schedules.addAll([nightly, smoke, deps, releaseNotes, tag]);
  return (schedules: schedules, runs: runs);
}
