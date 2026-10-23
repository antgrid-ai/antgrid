import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show RpcException;
import 'package:clock/clock.dart';
import 'package:timezone/timezone.dart' as tz;

import 'demo_cron.dart';
import 'demo_identity.dart';
import 'fixtures/demo_scheduler_fixtures.dart';
import 'fixtures/demo_workspace_fixtures.dart';

/// How long a run reads "Starting" before it is bound to its session.
const Duration kDemoRunPreparing = Duration(seconds: 1);

/// How long a run started with Run now takes. Long enough for a viewer to see
/// it running, short enough to watch it finish.
const Duration kDemoManualRunDuration = Duration(seconds: 20);

const Duration _kPastFloor = Duration(seconds: 60);
const Duration _kLookahead = Duration(hours: 24);
const int _kUpcomingPage = 48;
const int _kKeptRuns = 200;
const Duration _kNewScheduleTypical = Duration(minutes: 2);

const List<({String agentId, List<String> modes})> _kAgents = [
  (agentId: 'claude-code', modes: ['terminal', 'chat']),
  (agentId: 'codex', modes: ['terminal', 'chat']),
];

// Ids and wording follow the claude-code adapter's permission modes
// (packages/antgrid-agents/src/agents/claude-code/permission-modes.ts).
const List<Map<String, String>> _kChatModes = [
  {
    'id': 'default',
    'name': 'Default',
    'description': 'Ask before each tool use',
  },
  {
    'id': 'auto',
    'name': 'Auto',
    'description': 'Model classifier approves or denies tool prompts',
  },
  {
    'id': 'acceptEdits',
    'name': 'Accept edits',
    'description': 'Auto-approve file edits',
  },
  {'id': 'plan', 'name': 'Plan', 'description': 'Read-only planning mode'},
];

const Set<String> _kModelledKeys = {
  'name',
  'prompt',
  'projectId',
  'agentId',
  'mode',
  'approvalPolicy',
  'catchUp',
  'chatMode',
  'workspace',
  'baseBranch',
  'cron',
  'runAt',
  'timezone',
  'enabled',
};

// Fixed for the life of a schedule once its workspace exists.
const Set<String> _kLockedKeys = {'projectId', 'workspace', 'baseBranch'};

/// In-memory stand-in for a machine's scheduler, answering the same verbs and
/// shapes as bridge/src/host-server.ts so the real SchedulerScreen renders it.
///
/// Nothing here starts a timer. A run's status is computed from the clock each
/// time it is read, and due occurrences are turned into runs at the start of
/// each request. A pending `Timer` fails a widget test at teardown, and the
/// screen polls every few seconds anyway, so evaluating lazily on each poll is
/// indistinguishable from a live clock to the viewer.
class DemoSchedulerBackend {
  DemoSchedulerBackend({
    DateTime Function()? now,
    Future<String?> Function()? localTimezone,
  }) : _now = now ?? (() => clock.now()),
       _localTimezone = localTimezone ?? (() async => null);

  final DateTime Function() _now;
  final Future<String?> Function() _localTimezone;

  late tz.Location _zone;
  final List<DemoScheduleRecord> _schedules = [];
  final List<DemoRunRecord> _runs = [];
  int _scheduleSeq = 0;
  int _manualSeq = 0;

  // Memoised so the editor's preview and the screen's first load, which can
  // arrive together, seed once.
  late final Future<void> _ready = _seed();

  DateTime _utcNow() => _now().toUtc();

  Future<void> _seed() async {
    tz.Location? zone;
    try {
      final name = await _localTimezone();
      if (name != null) zone = demoSchedulerZone(name);
    } catch (_) {
      // An unreadable or unknown device zone is not worth an error screen in a
      // sample; UTC is a fine place to read the sample's times from.
    }
    _zone = zone ?? tz.UTC;
    final seed = demoSchedulerSeed(_utcNow(), _zone);
    _schedules.addAll(seed.schedules);
    _runs.addAll(seed.runs);
  }

  /// Same shape as `SchedulerRequest`, so the tear-off IS one.
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    await _ready;
    final now = _utcNow();
    _advance(now);
    switch (method) {
      case 'scheduler.capabilities':
        return _capabilities();
      case 'scheduler.list':
        return _list(now);
      case 'scheduler.runs':
        return _runsList(now, params['scheduleId'] as String?);
      case 'scheduler.preview':
        return _preview(now, params);
      case 'scheduler.create':
        return _create(now, params);
      case 'scheduler.update':
        return _update(now, params);
      case 'scheduler.runNow':
        return _runNow(now, params);
      case 'scheduler.stop':
        return _stop(now, params);
      case 'scheduler.delete':
        return _delete(now, params);
    }
    throw RpcException('E_UNKNOWN_METHOD', 'Unknown scheduler method $method');
  }

  // --- time ---------------------------------------------------------------

  /// The sample machine never sleeps, so every due occurrence becomes a real
  /// run; nothing here is ever missed or skipped.
  void _advance(DateTime now) {
    for (final s in _schedules) {
      if (s.deletedAt != null || !s.enabled) continue;
      if (s.cron != null) {
        final due = s.nextOccurrence;
        if (due != null && !due.isAfter(now)) _fireDueCron(s, due, now);
      } else if (s.runAt != null &&
          s.firedRunId == null &&
          !s.runAt!.isAfter(now)) {
        _fireDueOneOff(s, now);
      }
    }
    for (final s in _schedules) {
      _prune(s.id, now);
    }
  }

  void _fireDueCron(DemoScheduleRecord s, DateTime due, DateTime now) {
    final cron = DemoCron.parse(s.cron!);
    final zone = demoSchedulerZone(s.timezone);
    final floor = now.subtract(_kLookahead);
    final from = due.isAfter(floor) ? due : floor;
    // A day holds at most 1440 minute slots, which bounds the walk.
    final due24 = cron
        .after(from.subtract(const Duration(milliseconds: 1)), zone, count: 1441)
        .where((o) => !o.isAfter(now))
        .toList();
    final latest = due24.length > _kUpcomingPage
        ? due24.sublist(due24.length - _kUpcomingPage)
        : due24;
    for (final occ in latest) {
      final prev = _latestRun(s.id);
      if (prev != null && _activeAt(prev, occ)) continue;
      _addRun(
        s,
        trigger: 'cron',
        occurrenceAt: occ,
        startedAt: occ.add(const Duration(seconds: 1)),
        duration: demoRunDuration(s.typical, s.runsMade),
      );
    }
    s.nextOccurrence = cron.after(now, zone, count: 1).first;
  }

  void _fireDueOneOff(DemoScheduleRecord s, DateTime now) {
    // The bridge defers a one-off while its schedule is still running; it fires
    // on a later poll.
    if (_activeRun(s.id, now) != null) return;
    final run = _addRun(
      s,
      trigger: 'cron',
      occurrenceAt: s.runAt!,
      startedAt: now.isAfter(s.runAt!) ? now : s.runAt!,
      duration: demoRunDuration(s.typical, s.runsMade),
      id: 'demo-run-${s.shortName}-${s.runAt!.millisecondsSinceEpoch}',
    );
    s.firedRunId = run.id;
    s.firedAt = run.startedAt;
  }

  DemoRunRecord _addRun(
    DemoScheduleRecord s, {
    required String trigger,
    required DateTime occurrenceAt,
    required DateTime startedAt,
    required Duration duration,
    String? id,
  }) {
    // The schedule's workspace changes in the same step as the run exists, not
    // when the run binds a second later: the screen refreshes right after Run
    // now, and a workspace field that moved on a later poll would trip an open
    // editor's "changed while you were editing" notice and block its Save.
    s.workspaceCreated = true;
    if (s.workspace == 'worktree' && s.checkoutId == null) {
      s.checkoutId = _slug(s.name);
    }
    final run = DemoRunRecord(
      id: id ?? 'demo-run-${s.shortName}-${occurrenceAt.millisecondsSinceEpoch}',
      scheduleId: s.id,
      scheduleName: s.name,
      projectId: s.projectId,
      trigger: trigger,
      timezone: s.timezone,
      sessionId: s.sessionId,
      checkoutId: s.workspace == 'worktree' ? s.checkoutId : null,
      occurrenceAt: occurrenceAt,
      startedAt: startedAt,
      duration: duration,
    );
    s.runsMade++;
    _runs.add(run);
    return run;
  }

  static String _slug(String name) {
    final slug = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'scheduled-run' : slug;
  }

  DateTime _endOf(DemoRunRecord r) => r.startedAt.add(r.duration);

  bool _active(DemoRunRecord r, DateTime now) =>
      r.stoppedAt == null && now.isBefore(_endOf(r));

  // Whether [r] was still going at [instant] (a stop before it ends the run).
  bool _activeAt(DemoRunRecord r, DateTime instant) {
    final stop = r.stoppedAt;
    if (stop != null && !stop.isAfter(instant)) return false;
    return _endOf(r).isAfter(instant);
  }

  DemoRunRecord? _latestRun(String scheduleId) {
    DemoRunRecord? latest;
    for (final r in _runs) {
      if (r.scheduleId != scheduleId) continue;
      if (latest == null || !r.startedAt.isBefore(latest.startedAt)) {
        latest = r;
      }
    }
    return latest;
  }

  DemoRunRecord? _activeRun(String scheduleId, DateTime now) {
    for (final r in _runs.reversed) {
      if (r.scheduleId == scheduleId && _active(r, now)) return r;
    }
    return null;
  }

  void _prune(String scheduleId, DateTime now) {
    final inactive = _runs
        .where((r) => r.scheduleId == scheduleId && !_active(r, now))
        .toList();
    if (inactive.length <= _kKeptRuns) return;
    inactive.sort((a, b) => a.startedAt.compareTo(b.startedAt));
    final drop = inactive.take(inactive.length - _kKeptRuns).toSet();
    _runs.removeWhere(drop.contains);
  }

  // --- reads --------------------------------------------------------------

  List<Map<String, dynamic>> _projects() => [
    {
      'projectId': kDemoProjectId,
      'label': kDemoDisplayName,
      'isGitRepository': true,
    },
  ];

  Map<String, dynamic> _capabilities() => {
    // There is never an `error` key: any value there renders as an error
    // banner on the Scheduler.
    'supported': true,
    'timezone': demoZoneName(_zone),
    'supportsBaseBranchClear': true,
    'supportsCatchUp': true,
    'supportsOneOff': true,
    'agents': [
      for (final a in _kAgents) {'agentId': a.agentId, 'modes': [...a.modes]},
    ],
    'chatModes': {
      'claude-code': [
        for (final m in _kChatModes) {...m},
      ],
    },
    'projects': _projects(),
  };

  Map<String, dynamic> _list(DateTime now) {
    final live = _schedules.where((s) => s.deletedAt == null).toList();
    return {
      'schedules': [
        for (final s in live)
          if (s.cron != null) _scheduleJson(s, upcoming: _upcoming(s, now)),
      ],
      'oneOffSchedules': [
        for (final s in live)
          if (s.runAt != null) _scheduleJson(s),
      ],
      'projects': _projects(),
    };
  }

  List<int> _upcoming(DemoScheduleRecord s, DateTime now) {
    if (!s.enabled) return const [];
    final horizon = now.add(_kLookahead);
    return DemoCron.parse(s.cron!)
        .after(now, demoSchedulerZone(s.timezone), count: _kUpcomingPage)
        .where((o) => o.isBefore(horizon))
        .map((o) => o.millisecondsSinceEpoch)
        .toList();
  }

  Map<String, dynamic> _scheduleJson(
    DemoScheduleRecord s, {
    List<int>? upcoming,
  }) => {
    'id': s.id,
    'name': s.name,
    'projectId': s.projectId,
    'agentId': s.agentId,
    'mode': s.mode,
    'prompt': s.prompt,
    'approvalPolicy': s.approvalPolicy,
    'catchUp': s.catchUp,
    if (s.chatMode != null) 'chatMode': s.chatMode,
    'workspace': s.workspace,
    if (s.baseBranch != null) 'baseBranch': s.baseBranch,
    if (s.cron != null) 'cron': s.cron,
    if (s.runAt != null) 'runAt': s.runAt!.millisecondsSinceEpoch,
    'timezone': s.timezone,
    'enabled': s.enabled,
    if (s.checkoutId != null) 'checkoutId': s.checkoutId,
    'workspaceCreated': s.workspaceCreated,
    if (s.firedRunId != null) 'firedRunId': s.firedRunId,
    if (s.firedAt != null) 'firedAt': s.firedAt!.millisecondsSinceEpoch,
    'createdAt': s.createdAt.millisecondsSinceEpoch,
    'updatedAt': s.updatedAt.millisecondsSinceEpoch,
    if (s.nextOccurrence != null)
      'nextOccurrence': s.nextOccurrence!.millisecondsSinceEpoch,
    'upcoming': ?upcoming,
  };

  Map<String, dynamic> _runJson(DemoRunRecord r, DateTime now) {
    final end = _endOf(r);
    final String status;
    String? reason;
    DateTime? finishedAt;
    final bool bound;
    final stopped = r.stoppedAt;
    if (stopped != null) {
      status = 'interrupted';
      reason = 'Stopped by user';
      finishedAt = stopped;
      bound = stopped.difference(r.startedAt) >= kDemoRunPreparing;
    } else if (now.difference(r.startedAt) < kDemoRunPreparing) {
      status = 'preparing';
      bound = false;
    } else if (now.isBefore(end)) {
      status = 'running';
      bound = true;
    } else {
      status = 'completed';
      finishedAt = end;
      bound = true;
    }
    return {
      'id': r.id,
      'scheduleId': r.scheduleId,
      'scheduleName': r.scheduleName,
      'projectId': r.projectId,
      'status': status,
      'trigger': r.trigger,
      'timezone': r.timezone,
      'occurrenceAt': r.occurrenceAt.millisecondsSinceEpoch,
      'startedAt': r.startedAt.millisecondsSinceEpoch,
      if (finishedAt != null) 'finishedAt': finishedAt.millisecondsSinceEpoch,
      'reason': ?reason,
      if (bound) 'sessionId': r.sessionId,
      if (bound) 'runtimeGeneration': 'demo',
      if (bound && r.checkoutId != null) 'checkoutId': r.checkoutId,
    };
  }

  Map<String, dynamic> _runsList(DateTime now, String? scheduleId) {
    final picked = _runs
        .where((r) => scheduleId == null || r.scheduleId == scheduleId)
        .toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return {
      'runs': [for (final r in picked) _runJson(r, now)],
    };
  }

  Map<String, dynamic> _preview(DateTime now, Map<String, dynamic> params) {
    final timezone = params['timezone'] is String && params['timezone'] != ''
        ? params['timezone'] as String
        : demoZoneName(_zone);
    if (params.containsKey('runAt')) {
      final at = demoResolveRunAt(params['runAt'], timezone);
      // The bridge only refuses a past time on save. Refusing it here puts the
      // problem beside the time field, instead of behind "Couldn't save the
      // schedule." after the viewer has filled in everything else.
      _requireFuture(at, now);
      return {
        'occurrences': [at.millisecondsSinceEpoch],
      };
    }
    final cron = DemoCron.parse('${params['cron'] ?? ''}');
    return {
      'occurrences': [
        for (final o in cron.after(now, demoSchedulerZone(timezone), count: 5))
          o.millisecondsSinceEpoch,
      ],
    };
  }

  // --- writes -------------------------------------------------------------

  Map<String, dynamic> _create(DateTime now, Map<String, dynamic> params) {
    final raw = params['schedule'];
    if (raw is! Map) {
      throw RpcException('SCHEDULER_ERROR', 'schedule is required');
    }
    final input = <String, Object?>{
      for (final e in raw.entries)
        if (_kModelledKeys.contains(e.key)) e.key as String: e.value,
    };
    final s = DemoScheduleRecord(
      id: 'demo-schedule-${++_scheduleSeq}',
      name: '',
      prompt: '',
      projectId: '',
      agentId: '',
      mode: '',
      approvalPolicy: 'default',
      catchUp: 'latest',
      workspace: '',
      timezone: '',
      enabled: true,
      createdAt: now,
      updatedAt: now,
      typical: _kNewScheduleTypical,
      sessionId: kDemoSessionCheckoutId,
    );
    _apply(s, input);
    if (s.runAt != null) _requireFuture(s.runAt!, now);
    _setNext(s, now);
    _schedules.add(s);
    return {'schedule': _scheduleJson(s)};
  }

  Map<String, dynamic> _update(DateTime now, Map<String, dynamic> params) {
    final current = _find(params['id']);
    if (current == null) {
      throw RpcException('SCHEDULE_NOT_FOUND', 'Schedule no longer exists');
    }
    final rawPatch = params['patch'];
    if (rawPatch is! Map) {
      throw RpcException('SCHEDULER_ERROR', 'patch is required');
    }
    // Once a workspace exists the bridge refuses to move it. The editor already
    // leaves these keys out, so ignoring them is the same answer without a way
    // to turn Save into an error.
    final locked =
        current.workspaceCreated ||
        current.checkoutId != null ||
        _activeRun(current.id, now) != null;
    final patch = <String, Object?>{
      for (final e in rawPatch.entries)
        if (_kModelledKeys.contains(e.key) &&
            !(locked && _kLockedKeys.contains(e.key)))
          e.key as String: e.value,
    };
    final merged = _settingsOf(current);
    for (final e in patch.entries) {
      if (e.value == null) {
        merged.remove(e.key);
      } else {
        merged[e.key] = e.value;
      }
    }
    final namesRunAt = patch['runAt'] != null, namesCron = patch['cron'] != null;
    if (namesRunAt && !namesCron) merged.remove('cron');
    if (namesCron && !namesRunAt) merged.remove('runAt');

    final next = current.copy();
    _apply(next, merged);
    final runAtChanged = next.runAt != current.runAt;
    final resumed = !current.enabled && next.enabled;
    if (next.runAt != null &&
        (runAtChanged || (resumed && current.firedRunId == null))) {
      _requireFuture(next.runAt!, now);
    }
    if (runAtChanged) {
      next.firedRunId = null;
      next.firedAt = null;
    }
    final stale = current.nextOccurrence == null ||
        !current.nextOccurrence!.isAfter(now);
    if (runAtChanged ||
        next.cron != current.cron ||
        next.timezone != current.timezone ||
        resumed ||
        stale) {
      _setNext(next, now);
    }
    next.updatedAt = now;
    _schedules[_schedules.indexOf(current)] = next;
    return {'schedule': _scheduleJson(next)};
  }

  DemoScheduleRecord? _find(Object? id) {
    for (final s in _schedules) {
      if (s.id == id && s.deletedAt == null) return s;
    }
    return null;
  }

  Map<String, Object?> _settingsOf(DemoScheduleRecord s) => {
    'name': s.name,
    'prompt': s.prompt,
    'projectId': s.projectId,
    'agentId': s.agentId,
    'mode': s.mode,
    'approvalPolicy': s.approvalPolicy,
    'catchUp': s.catchUp,
    'chatMode': ?s.chatMode,
    'workspace': s.workspace,
    'baseBranch': ?s.baseBranch,
    'cron': ?s.cron,
    'runAt': ?s.runAt?.millisecondsSinceEpoch,
    'timezone': s.timezone,
    'enabled': s.enabled,
  };

  void _setNext(DemoScheduleRecord s, DateTime now) {
    s.nextOccurrence = s.cron != null
        ? DemoCron.parse(s.cron!)
              .after(now, demoSchedulerZone(s.timezone), count: 1)
              .first
        : s.runAt;
  }

  /// Validates [m], a complete settings map, and writes it onto [s]. Keys the
  /// sample does not model never reach here: refusing them would turn Save
  /// into "Couldn't save the schedule." the day the editor gains a field.
  void _apply(DemoScheduleRecord s, Map<String, Object?> m) {
    String text(String key) {
      final v = m[key];
      if (v is! String || v.trim().isEmpty) {
        throw RpcException('SCHEDULER_ERROR', '$key is required');
      }
      return v;
    }

    String oneOf(String key, Set<String> allowed, String fallback) {
      final v = m[key] ?? fallback;
      if (v is! String || !allowed.contains(v)) {
        throw RpcException(
          'SCHEDULER_ERROR',
          '$key must be one of ${allowed.join(', ')}',
        );
      }
      return v;
    }

    final name = text('name');
    final prompt = text('prompt');
    final projectId = text('projectId');
    final agentId = text('agentId');
    final mode = oneOf('mode', const {'terminal', 'chat'}, '');
    final workspace = oneOf('workspace', const {'shared', 'worktree'}, '');
    final timezone = text('timezone');
    final approvalPolicy = oneOf('approvalPolicy', const {
      'default',
      'bypass',
    }, 'default');
    final catchUp = oneOf('catchUp', const {'latest', 'skip'}, 'latest');
    final enabled = m['enabled'] ?? true;
    if (enabled is! bool) {
      throw RpcException('SCHEDULER_ERROR', 'enabled must be true or false');
    }
    final hasCron = m['cron'] != null, hasRunAt = m['runAt'] != null;
    if (hasCron == hasRunAt) {
      throw RpcException(
        'SCHEDULER_ERROR',
        'Give either cron or runAt, not both and not neither',
      );
    }
    if (projectId != kDemoProjectId) {
      throw RpcException(
        'SCHEDULER_ERROR',
        'Project is unavailable; open it from the desktop first',
      );
    }
    if (!_kAgents.any((a) => a.agentId == agentId && a.modes.contains(mode))) {
      throw RpcException(
        'AGENT_NOT_SCHEDULABLE',
        'That agent cannot run scheduled tasks in $mode mode',
      );
    }
    demoSchedulerZone(timezone);
    final cron = hasCron ? DemoCron.parse('${m['cron']}').expression : null;
    final runAt = hasRunAt ? demoResolveRunAt(m['runAt'], timezone) : null;
    final chatMode = m['chatMode'];
    final baseBranch = m['baseBranch'];

    s
      ..name = name
      ..prompt = prompt
      ..projectId = projectId
      ..agentId = agentId
      ..mode = mode
      ..workspace = workspace
      ..timezone = timezone
      ..approvalPolicy = approvalPolicy
      ..catchUp = catchUp
      ..enabled = enabled
      ..cron = cron
      ..runAt = runAt
      ..chatMode =
          mode == 'chat' && approvalPolicy != 'bypass' && chatMode is String
          ? chatMode
          : null
      ..baseBranch = baseBranch is String && baseBranch.isNotEmpty
          ? baseBranch
          : null;
  }

  void _requireFuture(DateTime at, DateTime now) {
    if (at.isBefore(now.add(_kPastFloor))) {
      throw RpcException(
        'INVALID_RUN_AT',
        'The one-off time has already passed; set a new time.',
      );
    }
  }

  // A run can start or finish between the screen's poll and the viewer's tap,
  // and any refusal here would render as "That didn't work." So these verbs
  // answer the race instead of reporting it.
  Map<String, dynamic> _runNow(DateTime now, Map<String, dynamic> params) {
    final s = _find(params['id']);
    if (s == null) return {};
    final active = _activeRun(s.id, now);
    if (active != null) return {'run': _runJson(active, now)};
    final run = _addRun(
      s,
      trigger: 'manual',
      occurrenceAt: now,
      startedAt: now,
      duration: kDemoManualRunDuration,
      id: 'demo-run-${s.shortName}-m${++_manualSeq}',
    );
    return {'run': _runJson(run, now)};
  }

  Map<String, dynamic> _stop(DateTime now, Map<String, dynamic> params) {
    for (final r in _runs) {
      if (r.id == params['id'] && _active(r, now)) {
        r.stoppedAt = now.isBefore(r.startedAt) ? r.startedAt : now;
      }
    }
    return {};
  }

  Map<String, dynamic> _delete(DateTime now, Map<String, dynamic> params) {
    final s = _find(params['id']);
    if (s == null) return {};
    s
      ..enabled = false
      ..deletedAt = now
      ..updatedAt = now;
    return {};
  }
}
