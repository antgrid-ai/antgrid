import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../design/ab_colors.dart';
import '../design/ab_icons.dart';
import '../design/ab_tokens.dart';
import '../design/widgets/ab_adaptive_sheet.dart';
import '../design/widgets/ab_branch_pill.dart';
import '../design/widgets/ab_chip.dart';
import '../design/widgets/ab_dialog.dart';
import '../design/widgets/ab_empty_state.dart';
import '../design/widgets/ab_list_row.dart';
import '../design/widgets/ab_loading.dart';
import '../design/widgets/ab_section_header.dart';
import '../design/widgets/ab_tooltip.dart';
import '../models/ab_message.dart';
import '../models/agent_work_status.dart';
import '../providers/session_bus_inbox.dart';
import '../util/relative_time.dart';
import 'agent_work_status_dot.dart';

const _kDirectoryRequest = 'session-bus:directory';
const _kDirectoryResult = 'session-bus:directory:result';

/// Longer than the mailbox reads, because this one has a git spawn behind it:
/// the bridge probes a branch per project sharing the repo key before it can
/// answer, which is why it runs the read off its own message switch.
const _kDirectoryReadTimeout = Duration(seconds: 20);

const _uuid = Uuid();

/// What a session is doing, as the directory ranks it. Three ranks, narrower
/// than the work status beside it: a directory row is scanned, not diagnosed.
enum SessionDirectoryActivity {
  running,
  idle,
  stopped;

  /// Null for a word this build has not learned. Nothing falls back to
  /// [stopped]: a session a newer bridge described in a way this one cannot
  /// read is a session of unknown state, and printing "stopped" would be an
  /// answer rather than an omission.
  static SessionDirectoryActivity? fromWire(Object? raw) => switch (raw) {
    'running' => running,
    'idle' => idle,
    'stopped' => stopped,
    _ => null,
  };

  String get label => switch (this) {
    running => 'running',
    idle => 'idle',
    stopped => 'stopped',
  };
}

/// One addressable session, exactly as the owning machine described it.
@immutable
class SessionDirectoryEntry {
  const SessionDirectoryEntry({
    required this.machineId,
    required this.machineLabel,
    required this.projectId,
    required this.projectLabel,
    required this.sessionId,
    required this.title,
    required this.branch,
    required this.activity,
    required this.workStatus,
    required this.lastActiveAt,
    required this.canReply,
  });

  /// Null in local mode, where no frame can leave the machine to need one — so
  /// it is compared against [SessionDirectory.machineId] rather than tested for
  /// null to decide which group a row belongs in.
  final String? machineId;

  /// Omitted for a row this machine built itself; stamped by the asking side
  /// onto a row that arrived from a peer.
  final String? machineLabel;
  final String projectId;
  final String? projectLabel;
  final String sessionId;
  final String title;
  final String? branch;
  final SessionDirectoryActivity? activity;
  final AgentWorkStatus? workStatus;
  final int lastActiveAt;

  /// Whether this session's agent can be messaged back, decided by the machine
  /// that OWNS the session. Rendered as it arrives and never re-derived here:
  /// the answer depends on the agent registry of the bridge running that
  /// session, so a local recomputation would compile against any tool string
  /// and go wrong the moment two machines run different versions.
  final bool canReply;

  static SessionDirectoryEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final projectId = json['projectId'];
    final sessionId = json['sessionId'];
    final title = json['title'];
    if (projectId is! String || sessionId is! String || title is! String) {
      return null;
    }
    final lastActiveAt = json['lastActiveAt'];
    return SessionDirectoryEntry(
      machineId: json['machineId'] is String
          ? json['machineId'] as String
          : null,
      machineLabel: json['machineLabel'] is String
          ? json['machineLabel'] as String
          : null,
      projectId: projectId,
      projectLabel: json['projectLabel'] is String
          ? json['projectLabel'] as String
          : null,
      sessionId: sessionId,
      title: title,
      branch: json['branch'] is String ? json['branch'] as String : null,
      activity: SessionDirectoryActivity.fromWire(json['activity']),
      workStatus: AgentWorkStatus.fromWire(json['workStatus']),
      lastActiveAt: lastActiveAt is num ? lastActiveAt.toInt() : 0,
      canReply: json['canReply'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SessionDirectoryEntry &&
      other.machineId == machineId &&
      other.machineLabel == machineLabel &&
      other.projectId == projectId &&
      other.projectLabel == projectLabel &&
      other.sessionId == sessionId &&
      other.title == title &&
      other.branch == branch &&
      other.activity == activity &&
      other.workStatus == workStatus &&
      other.lastActiveAt == lastActiveAt &&
      other.canReply == canReply;

  @override
  int get hashCode => Object.hash(
    machineId,
    machineLabel,
    projectId,
    projectLabel,
    sessionId,
    title,
    branch,
    activity,
    workStatus,
    lastActiveAt,
    canReply,
  );
}

/// One machine's own read outcome, as `machines[]` reported it
/// (`bridge/src/session-bus/remote-directory.ts`'s `ReachMachine`).
///
/// Decoded once here so the footer counts every machine exactly once — a
/// machine can be BOTH past its row TTL and refused/unreachable at the same
/// time (the bridge's own doc on `RemoteDirectoryCache.view` says a refused
/// peer's backoff outlasts that TTL by design), and summing a staleness count
/// with an unanswered count derived from the same array double-counts it.
typedef ReachMachineStatus = ({String machineId, String status, int ageMs});

/// Why the remote half of an answer is what it is.
///
/// Carried on every success, not only a partial one: a signal that shows up
/// only when something went wrong teaches a reader to take its absence for
/// completeness, and "there is nobody else" is the one wrong thing a directory
/// can say.
///
/// [scope] and [why] stay bare strings for the same reason a refusal code does
/// — the bridge's vocabulary can gain a word this build has not learned, and a
/// reader that dropped the frame over one would turn a new state into silence.
@immutable
class SessionDirectoryReach {
  const SessionDirectoryReach({
    required this.scope,
    this.why,
    this.staleMachines = 0,
    this.notConnected = 0,
    this.machines = const [],
  });

  final String scope;
  final String? why;

  /// Machines this cache still holds a row for, but whose age is past the
  /// bridge's row TTL — reported as its own fact, never folded into
  /// [machines]' own unanswered count (see [ReachMachineStatus]).
  final int staleMachines;
  final int notConnected;

  /// Every machine the read named, once each.
  final List<ReachMachineStatus> machines;

  static SessionDirectoryReach? fromJson(Object? json) {
    if (json is! Map) return null;
    final scope = json['scope'];
    if (scope is! String) return null;
    final rawMachines = json['machines'];
    return SessionDirectoryReach(
      scope: scope,
      why: json['why'] is String ? json['why'] as String : null,
      staleMachines: json['staleMachines'] is num
          ? (json['staleMachines'] as num).toInt()
          : 0,
      notConnected: json['notConnected'] is num
          ? (json['notConnected'] as num).toInt()
          : 0,
      machines: <ReachMachineStatus>[
        if (rawMachines is List)
          for (final m in rawMachines)
            if (m is Map && m['machineId'] is String)
              (
                machineId: m['machineId'] as String,
                status: m['status'] is String
                    ? m['status'] as String
                    : 'unreachable',
                ageMs: m['ageMs'] is num ? (m['ageMs'] as num).toInt() : 0,
              ),
      ],
    );
  }
}

/// One directory read's whole answer, refusals included.
///
/// A refusal is a VALUE here rather than a thrown error, and deliberately: a
/// provider that fails is retried on a backoff, and each retry of this one is
/// another directory read with a git spawn per project behind it. A project
/// with no remote would answer the same refusal forever while spawning
/// processes to do it.
@immutable
class SessionDirectory {
  const SessionDirectory({
    required this.sessions,
    required this.truncated,
    required this.reach,
    required this.machineId,
    this.refusal,
  });

  const SessionDirectory.refused(SessionBusRefusal this.refusal)
    : sessions = const <SessionDirectoryEntry>[],
      truncated = 0,
      reach = null,
      machineId = null;

  final List<SessionDirectoryEntry> sessions;

  /// Rows the bridge's bound dropped.
  final int truncated;
  final SessionDirectoryReach? reach;

  /// The answering machine's own id — null in local mode. The only thing that
  /// separates a local row from a remote one.
  final String? machineId;

  /// Why there is no answer. Never collapsed into an empty list: "nobody else
  /// is here" and "this project cannot be addressed at all" are different
  /// facts, and only one of them is something the user can fix.
  final SessionBusRefusal? refusal;
}

/// The addressable set for [sessionId], read from the focused project's bridge.
///
/// A one-shot read rather than a subscription: the directory is what the user
/// asked to see the moment they opened the panel, and re-reading it under them
/// would reorder rows they are still scanning. Closing and reopening the panel
/// is the refresh.
final sessionDirectoryProvider = FutureProvider.autoDispose
    .family<SessionDirectory, String>((ref, sessionId) async {
      final channel = ref.watch(sessionBusChannelProvider);
      if (channel == null) {
        // Neither refusal this file authors carries a code — this one and the
        // timeout: the bridge refused nothing, it was never asked or never
        // answered, and borrowing one of its codes would put words in its
        // mouth.
        return const SessionDirectory.refused(
          SessionBusRefusal(
            message:
                'This project is not connected, so there is nothing to read '
                'the directory from.',
          ),
        );
      }

      final requestId = _uuid.v4();
      final answer = Completer<SessionDirectory>();
      // The result frame carries no session id — every session on this project
      // answers on one stream — so the request id is the only correlation
      // there is.
      final sub = channel.frames.listen((json) {
        if (json['type'] != _kDirectoryResult) return;
        if (json['requestId'] != requestId) return;
        if (answer.isCompleted) return;
        final error = json['error'];
        if (error is String) {
          answer.complete(
            SessionDirectory.refused(
              SessionBusRefusal(
                message: error,
                code: json['code'] is String ? json['code'] as String : null,
              ),
            ),
          );
          return;
        }
        final rows = json['sessions'];
        final truncated = json['truncated'];
        answer.complete(
          SessionDirectory(
            sessions: <SessionDirectoryEntry>[
              if (rows is List)
                for (final row in rows) ?SessionDirectoryEntry.fromJson(row),
            ],
            truncated: truncated is num ? truncated.toInt() : 0,
            reach: SessionDirectoryReach.fromJson(json['reach']),
            machineId: json['machineId'] is String
                ? json['machineId'] as String
                : null,
          ),
        );
      });
      try {
        await channel.send(
          createAbMessage(_kDirectoryRequest, {
            'requestId': requestId,
            'sessionId': sessionId,
          }),
        );
        return await answer.future.timeout(_kDirectoryReadTimeout);
      } on TimeoutException {
        return const SessionDirectory.refused(
          SessionBusRefusal(message: 'The bridge did not answer in time.'),
        );
      } finally {
        await sub.cancel();
      }
    }, name: 'sessionDirectory');

/// Opens the Directory over [context], which must outlive any popup the caller
/// dismissed on the way in.
Future<void> showSessionDirectory(
  BuildContext context, {
  required String sessionId,
}) {
  return showAbAdaptiveSheet<void>(
    context,
    child: SessionDirectoryPanel(sessionId: sessionId),
  );
}

/// The other sessions working on this repository: what each is doing, and
/// whether its agent can answer.
///
/// Informational, and deliberately so. Every row here belongs to a session with
/// its own human, and no row offers a way to reach that human — asking another
/// session for something is its own agent's verb, decided by the agent on the
/// far side. There is no cross-session queue on this surface and none may be
/// added.
class SessionDirectoryPanel extends ConsumerWidget {
  const SessionDirectoryPanel({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final directory = ref.watch(sessionDirectoryProvider(sessionId));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: abDialogTitlePadding,
          child: abDialogTitle(
            'Sessions on this repository',
            onClose: () => Navigator.of(context).pop(),
          ),
        ),
        Flexible(
          child: directory.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(AbTokens.space24),
              child: AbLoading(message: 'Reading the directory'),
            ),
            // Reached only by something unforeseen: a refusal and a silent
            // bridge both come back as an answer, so this is not the refusal
            // path.
            error: (_, _) => const Padding(
              padding: EdgeInsets.all(AbTokens.space16),
              child: AbEmptyState.error(
                title: 'The directory could not be read.',
              ),
            ),
            data: (d) => _DirectoryBody(directory: d),
          ),
        ),
      ],
    );
  }
}

class _DirectoryBody extends StatelessWidget {
  const _DirectoryBody({required this.directory});

  final SessionDirectory directory;

  @override
  Widget build(BuildContext context) {
    final refusal = directory.refusal;
    if (refusal != null) {
      return Padding(
        padding: const EdgeInsets.all(AbTokens.space16),
        // Verbatim: a refusal is authored where it was decided, and a code this
        // build has not learned still arrives with words that mean something.
        child: AbEmptyState.error(title: refusal.message),
      );
    }
    final note = _reachNote(directory);
    if (directory.sessions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AbTokens.space16),
        child: AbEmptyState(
          icon: AbIcons.list,
          title: 'No other sessions on this repository',
          subtitle: note,
        ),
      );
    }

    // Local first, per the surface's own rule, and within each group the
    // bridge's order is kept as it arrived: the sort is objective and belongs
    // to the side that can check every key it sorts on.
    final local = <SessionDirectoryEntry>[];
    final remote = <String?, List<SessionDirectoryEntry>>{};
    for (final row in directory.sessions) {
      if (row.machineId == directory.machineId) {
        local.add(row);
      } else {
        remote.putIfAbsent(row.machineId, () => []).add(row);
      }
    }

    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: AbTokens.space12),
      children: [
        if (local.isNotEmpty) ..._group('This machine', local),
        for (final entry in remote.entries)
          ..._group(
            entry.value.first.machineLabel ?? entry.key ?? 'Another machine',
            entry.value,
            // A machine label is a name the user could type, unlike the fixed
            // category word above it.
            mono: entry.value.first.machineLabel != null || entry.key != null,
          ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AbTokens.space12,
              AbTokens.space8,
              AbTokens.space12,
              0,
            ),
            child: Text(
              note,
              style: AbTokens.sansStyle(
                fontSize: AbTokens.fontXxs,
                color: context.antgrid.textMuted,
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _group(
    String label,
    List<SessionDirectoryEntry> rows, {
    bool mono = false,
  }) => [
    Padding(
      padding: const EdgeInsets.only(
        top: AbTokens.space12,
        bottom: AbTokens.space4,
      ),
      child: AbSectionHeader(label: label, count: rows.length, mono: mono),
    ),
    for (final row in rows) _DirectoryRow(row: row),
  ];
}

/// What the read could NOT see, as one line. Null when it saw everything —
/// this is the exception the row list cannot state for itself, not a running
/// commentary on a healthy answer.
String? _reachNote(SessionDirectory directory) {
  final parts = <String>[];
  final reach = directory.reach;
  if (reach != null && reach.scope == 'machine') {
    parts.add(switch (reach.why) {
      'remote-access-off' => 'Only this machine: remote access is off here.',
      'no-carrier' =>
        'Only this machine: nothing is connected to carry a network read.',
      'no-machine-id' => 'Only this machine: it has no machine id yet.',
      _ => 'Only this machine.',
    });
  } else if (reach != null) {
    // Each machine counted once: `machines[]` is authoritative per machine, so
    // reading its status directly — rather than summing a separate staleness
    // count over the same array — is what keeps a machine that is both stale
    // and refused from being counted twice.
    final missed =
        reach.notConnected +
        reach.machines.where((m) => m.status != 'answered').length;
    if (missed > 0) {
      parts.add(
        missed == 1
            ? '1 machine could not be read.'
            : '$missed machines could not be read.',
      );
    }
    if (reach.staleMachines > 0) {
      parts.add(
        reach.staleMachines == 1
            ? "1 machine's rows are out of date."
            : "${reach.staleMachines} machines' rows are out of date.",
      );
    }
  }
  if (directory.truncated > 0) {
    parts.add(
      directory.truncated == 1
          ? '1 more session did not fit.'
          : '${directory.truncated} more sessions did not fit.',
    );
  }
  return parts.isEmpty ? null : parts.join(' ');
}

class _DirectoryRow extends StatelessWidget {
  const _DirectoryRow({required this.row});

  final SessionDirectoryEntry row;

  @override
  Widget build(BuildContext context) {
    final palette = context.antgrid;
    final status = row.workStatus;
    final meta = <String>[
      if (row.activity != null) row.activity!.label,
      if (row.lastActiveAt > 0)
        relativeTime(DateTime.fromMillisecondsSinceEpoch(row.lastActiveAt)),
    ].join(' · ');

    return AbListRow(
      key: Key('session-directory-row-${row.sessionId}'),
      // Reserved even when the status is unknown, so a column of titles stays
      // a column rather than stepping in and out by a dot's width.
      leading: SizedBox(
        width: AbTokens.dotSizeSm,
        child: status == null
            ? null
            : AbTooltip(
                message: _workStatusNotice(status),
                triggerMode: TooltipTriggerMode.tap,
                child: AgentWorkStatusDot(status: status),
              ),
      ),
      subtitleMaxLines: 2,
      title: Text(row.title),
      subtitle: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: AbTokens.space6,
        runSpacing: AbTokens.space4,
        children: [
          if (row.branch != null) AbBranchPill(branch: row.branch!),
          if (row.projectLabel != null)
            Text(
              row.projectLabel!,
              style: AbTokens.monoStyle(
                fontSize: AbTokens.fontXxs,
                color: palette.textMuted,
              ),
            ),
          if (meta.isNotEmpty) Text(meta),
        ],
      ),
      // Only the negative is stated. A row that says nothing is a peer, which
      // is the ordinary case; the one worth a chip is the agent that will be
      // heard and can never answer, so it is listed as reachable rather than
      // offered as a conversation that fails on the first reply.
      trailing: row.canReply
          ? null
          : AbTooltip(
              message:
                  'This agent can be told something, but its vendor has no way '
                  'to send a reply back.',
              triggerMode: TooltipTriggerMode.tap,
              child: AbChip.system(
                label: 'RECEIVE-ONLY',
                color: palette.textMuted,
              ),
            ),
    );
  }
}

/// Sentence form of a work status, for a dot that carries the fact with no
/// label beside it.
String _workStatusNotice(AgentWorkStatus status) => switch (status) {
  AgentWorkStatus.working => 'Working.',
  AgentWorkStatus.attention => 'Waiting on its own user.',
  AgentWorkStatus.unread => 'Answered, and nobody has opened it yet.',
  AgentWorkStatus.done => 'Finished.',
  AgentWorkStatus.error => 'Stopped on an error.',
};
