// The remote half of the session directory, app side: what the desktop learns
// by PEEKING peer capability cards, and how that gets shaped into one push to
// the local bridge's `session-bus:remote-directory` loopback verb
// (`bridge/src/host-server.ts`, `bridge/src/session-bus/remote-directory.ts`).
//
// Everything in this file is pure Dart — no Riverpod, no widget. The pump
// widget (`remote_directory_pump.dart`) owns exactly two things this file
// cannot: the `Timer` and the `ref.read`/`ref.listenManual` calls that supply
// this file's inputs. Every decision about WHEN to push, WHOM to ask, and HOW
// to classify an answer lives here so it can be tested without one.
import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart'
    show RpcException;

import '../launcher/host_control_client.dart'
    show HostControlException, RemoteDirectoryAck;
import '../services/account_agents_api.dart' show InventoryAgent;
import '../services/control_plane_client.dart'
    show ControlPlaneClient, MachineSessionRow;

/// The push IS the heartbeat (`docs/session-messaging.md` §5.3: "being
/// pushed to is what proves a carrier exists"): the bridge's `lastPushAt` is
/// what proves this machine's carrier is alive, so an unchanged snapshot is
/// re-sent at this cadence regardless.
const Duration kRemoteDirectoryHeartbeat = Duration(seconds: 30);

/// Floor between two OFF-cadence pushes (a socket opening/closing, an
/// unserved read) — also the pump's own poll interval, so a burst of
/// triggers cannot fire faster than this.
const Duration kRemoteDirectoryMinSpacing = Duration(seconds: 5);

/// Cadence substituted for the heartbeat while a read went unserved: an agent
/// asked for a repo this machine had not reported on yet.
const Duration kRemoteDirectoryFastTick = Duration(seconds: 5);

/// How long the fast tick stays in effect after the LAST unserved read.
const Duration kRemoteDirectoryFastWindow = Duration(seconds: 60);

/// Per-machine capability-card ask, below the 10s `AgentTransport.request`
/// default so N peers cannot stack past one tick.
const Duration kRemoteDirectoryPerMachineTimeout = Duration(seconds: 6);

/// A timeout/send-failure/malformed reply is retried soon — it may be a blip.
const Duration kRemoteDirectoryUnreachableBackoff = Duration(seconds: 60);

/// A switch flipped off is a human decision, not a blip, so a refused machine
/// is asked far less often than one that merely failed to answer.
const Duration kRemoteDirectoryRefusedBackoff = Duration(minutes: 5);

/// A peer that answered without a `sessions` key cannot begin carrying one
/// without restarting its bridge, which drops the socket that made it a
/// candidate — and [RemoteMachineTracker.prune] clears this the moment that
/// happens. So the only ask that could ever return something new is already
/// preceded by a reset, and every ask before it is spent for an answer that
/// cannot change: on an old bridge each one runs the whole seen catalog
/// through `readCapabilityCard`, at two git spawns per project.
const Duration kRemoteDirectoryNoCardBackoff = Duration(hours: 1);

/// Consecutive `BAD_REQUEST` answers required before [RemoteDirectoryPumpEngine]
/// latches the local pump off. `control-listener.ts` returns the same code for
/// EVERY `ControlRequestSchema` rejection, not only an unrecognised verb — so a
/// single occurrence this app's own payload triggered (a bad clamp, a future
/// field this build doesn't set right) must not read as "this bridge predates
/// the verb" and kill the directory feature until the next bridge restart. A
/// bridge that genuinely lacks the verb fails every cycle, so it still latches
/// within a few heartbeats; a payload bug gets a bounded number of retries
/// instead of a permanent kill.
const int kRemoteDirectoryLatchThreshold = 3;

/// Rows one peer's card may contribute to a push, mirroring the bridge's own
/// `MAX_MACHINE_CARD_ROWS` (`session-bus/constants.ts`). The wire schema
/// (`control-protocol.ts`) admits far more as a DoS ceiling, not a business
/// rule, but staying under the PRODUCT cap here means a peer answering more
/// sessions than either bound — a newer bridge, or simply a wrong one — cannot
/// turn this machine's own push into a `BAD_REQUEST` that latches the pump off
/// over a peer neither side is misbehaving toward. Keep in lockstep with the
/// bridge constant.
const int kRemoteDirectoryMaxRowsPerMachine = 40;

/// Machines one push may describe, mirroring the bridge's own
/// `MAX_REMOTE_DIRECTORY_MACHINES`. Same reasoning as
/// [kRemoteDirectoryMaxRowsPerMachine]: trimming here changes nothing about
/// which machines end up in the mirror (the bridge slices to the same bound),
/// only who pays the wire bytes for the overflow.
const int kRemoteDirectoryMaxMachinesPerPush = 8;

/// What one candidate machine turned out to be, this cycle. Four members,
/// deliberately never collapsed into one another: a caller that cannot tell
/// "the peer said no" from "nobody answered" from "it has nothing running"
/// renders every one of them as the same "nobody else is there".
sealed class RemoteMachineOutcome {
  const RemoteMachineOutcome();

  /// Wire value for `session-bus:remote-directory`'s `machines[].outcome`
  /// (`control-protocol.ts`).
  String get wireValue => switch (this) {
    RemoteMachineRows() => 'rows',
    RemoteMachineNoCard() => 'no-card',
    RemoteMachineRefused() => 'refused',
    RemoteMachineUnreachable() => 'unreachable',
  };
}

/// The peer answered. [rows] may legitimately be empty — that is an honest
/// "nobody else is on this repo" and must never be read the same as
/// [RemoteMachineNoCard].
final class RemoteMachineRows extends RemoteMachineOutcome {
  const RemoteMachineRows({required this.rows, required this.truncated});
  final List<MachineSessionRow> rows;
  final int truncated;
}

/// The peer's card carried no `sessions` key at all — a bridge old enough to
/// predate `includeSessions`. Its repo half still answers elsewhere; only the
/// session half is dark, and that is a DIFFERENT fact from "it has none".
final class RemoteMachineNoCard extends RemoteMachineOutcome {
  const RemoteMachineNoCard();
}

/// The peer's own remote-access switch is off
/// (`RpcException('NOT_ALLOWED')`). Named, never silently absent.
final class RemoteMachineRefused extends RemoteMachineOutcome {
  const RemoteMachineRefused();
}

/// No live client to peek, or the ask did not complete at all — a timeout, a
/// send failure, or a reply this build could not parse. This machine cannot
/// tell any of those apart from "gone", so they share one bucket.
final class RemoteMachineUnreachable extends RemoteMachineOutcome {
  const RemoteMachineUnreachable();
}

/// Peek-then-ask ONE candidate machine. Never dials: [client] must already be
/// the `.value` peek of `controlPlaneClientForProvider` (see
/// [collectRemoteMachineReports]) — a null client (no live socket to peek)
/// classifies as [RemoteMachineUnreachable] with no RPC attempted at all,
/// exactly like a peer that failed to answer one.
Future<RemoteMachineOutcome> classifyMachine(
  ControlPlaneClient? client,
  List<String> repoKeys, {
  Duration timeout = kRemoteDirectoryPerMachineTimeout,
}) async {
  if (client == null) return const RemoteMachineUnreachable();
  try {
    final card = await client.capabilityCard(
      repoKeys: repoKeys.isEmpty ? null : repoKeys,
      includeSessions: true,
      timeout: timeout,
    );
    final sessions = card.sessions;
    if (sessions == null) return const RemoteMachineNoCard();
    return RemoteMachineRows(
      rows: sessions,
      truncated: card.sessionsTruncated,
    );
  } on RpcException catch (e) {
    if (e.code == 'NOT_ALLOWED') return const RemoteMachineRefused();
    // A bridge old enough to lack this method, or new enough to disagree on
    // its params, cannot say whether it has sessions — that is a DIFFERENT
    // fact from "did not answer", and reporting it as unreachable would arm
    // the short retry backoff against a machine no future ask can fix.
    if (e.code == 'E_UNKNOWN_METHOD' || e.code == 'E_BAD_PARAMS') {
      return const RemoteMachineNoCard();
    }
    return const RemoteMachineUnreachable();
  } catch (_) {
    // A malformed reply (`BAD_RESPONSE`) or anything else this build cannot
    // read — the peer is as good as gone for this cycle.
    return const RemoteMachineUnreachable();
  }
}

/// One machine's report for this push cycle — the wire row
/// `session-bus:remote-directory`'s `machines[]` carries, plus what produced
/// it. Every human-readable field on [MachineSessionRow] (title, branch,
/// labels) is ANOTHER agent's text riding through this machine on its way to
/// a third one; nothing here cleans it; sanitizeRow on the far bridge
/// (`remote-directory.ts`) is the only place that happens, deliberately.
final class RemoteMachineReport {
  const RemoteMachineReport({
    required this.machineId,
    this.machineLabel,
    required this.observedAt,
    required this.outcome,
  });

  final String machineId;
  final String? machineLabel;

  /// Epoch millis when THIS report was captured — not when the local bridge
  /// ingests it, and not refreshed while [RemoteMachineTracker] is serving a
  /// backed-off machine from cache. A refused or unreachable machine is
  /// resent on every heartbeat during its backoff window; stamping "now" on
  /// each resend would make a check this pump has not actually repeated look
  /// freshly reconfirmed to the far mirror, which reads this field to judge
  /// staleness for every outcome, not only [RemoteMachineRows].
  final int observedAt;
  final RemoteMachineOutcome outcome;

  Map<String, dynamic> toWire() {
    final o = outcome;
    final allRows = o is RemoteMachineRows
        ? o.rows
        : const <MachineSessionRow>[];
    // Clamp to the PRODUCT cap, not the wire schema's looser DoS ceiling: a
    // peer's own row count is untrusted input, and folding the overflow into
    // `truncated` (rather than dropping it silently) keeps the count honest
    // even though this machine, not the peer, is what trimmed it.
    final overflow = allRows.length > kRemoteDirectoryMaxRowsPerMachine
        ? allRows.length - kRemoteDirectoryMaxRowsPerMachine
        : 0;
    final rows = overflow == 0
        ? allRows
        : allRows.sublist(0, kRemoteDirectoryMaxRowsPerMachine);
    final reportedTruncated = o is RemoteMachineRows ? o.truncated : 0;
    // `ControlRequestSchema` requires `truncated >= 0`; a peer misreporting a
    // negative count must not 400 the whole push over one hostile field.
    final truncated = (reportedTruncated < 0 ? 0 : reportedTruncated) + overflow;
    return {
      'machineId': machineId,
      if (machineLabel != null) 'machineLabel': machineLabel,
      'observedAt': observedAt,
      'outcome': outcome.wireValue,
      'rows': [for (final r in rows) _rowToWire(r)],
      'truncated': truncated,
    };
  }
}

/// Bound the reports going out on the wire to
/// [kRemoteDirectoryMaxMachinesPerPush] — the same product cap the bridge
/// itself enforces by slicing (`RemoteDirectoryCache.replace`), so trimming
/// here changes nothing about which machines end up in the mirror, only who
/// pays the wire bytes for the overflow. [RemoteDirectoryCycleResult.reports]
/// still carries every machine this cycle actually asked or cached — this
/// clamp applies only to the wire payload built from it.
List<RemoteMachineReport> clampReportsForWire(
  List<RemoteMachineReport> reports,
) => reports.length <= kRemoteDirectoryMaxMachinesPerPush
    ? reports
    : reports.sublist(0, kRemoteDirectoryMaxMachinesPerPush);

/// One [MachineSessionRow] as `RemoteDirectoryRowSchema`
/// (`session-bus/remote-directory.ts`) expects it. Sent as-is, unsanitised —
/// the far bridge's `sanitizeRow` is the only place a row is actually
/// checked (`control-protocol.ts`'s comment on this verb is explicit that a
/// strict schema HERE would 400 the whole push over one hostile field).
Map<String, dynamic> _rowToWire(MachineSessionRow r) => {
  'repoKey': r.repoKey,
  'projectId': r.projectId,
  if (r.projectLabel != null) 'projectLabel': r.projectLabel,
  'sessionId': r.sessionId,
  'title': r.title,
  'branch': r.branch,
  if (r.activity != null) 'activity': r.activity!.name,
  if (r.workStatus != null) 'workStatus': r.workStatus!.name,
  'lastActiveAt': r.lastActiveAt,
  'canReply': r.canReply,
};

/// Candidate machines for this cycle: every open control-plane socket minus
/// this machine's own. [openControlPlaneIds] is already bare machine ids
/// only (v3: one connection per machine), so no dotted project id can ever
/// appear here.
Set<String> remoteDirectoryCandidates(
  Iterable<String> openControlPlaneIds,
  String? localUuid,
) => openControlPlaneIds.where((id) => id != localUuid).toSet();

/// Account machines that are neither this one nor an open [candidates] entry
/// — the honest "not asked" count the reach sentence needs. Reads a CACHED
/// inventory only: this must never itself trigger the inventory's network
/// pull, or a pump tick would cost an HTTP request every cycle.
int remoteDirectoryNotConnectedCount(
  Iterable<InventoryAgent> inventory,
  String? localUuid,
  Set<String> candidates,
) => inventory
    .map((a) => a.deviceUuid)
    .where((id) => id != localUuid && !candidates.contains(id))
    .length;

/// The label to travel on a pushed row — machineName wins over the account
/// display name, the same order `_machineLabelFor`
/// (`providers/new_session_action.dart`) resolves it for the start status
/// line, so a machine reads the same name wherever the app names it. Null
/// (omitted on the wire) rather than the bare uuid: every row already carries
/// the uuid as `machineId`.
String? remoteDirectoryMachineLabel(
  Iterable<InventoryAgent> inventory,
  String uuid,
) {
  for (final agent in inventory) {
    if (agent.deviceUuid != uuid) continue;
    final name = agent.machineName?.trim();
    if (name != null && name.isNotEmpty) return name;
    final display = agent.displayName.trim();
    return display.isEmpty ? null : display;
  }
  return null;
}

/// Per-machine ask backoff and last-known-report cache. A machine that just
/// refused or timed out is not re-asked on every heartbeat — but it is still
/// named in every push, from cache, with its ORIGINAL `observedAt`, so the
/// far mirror ages its rows out on its own TTL rather than this reading as a
/// fresh, still-silent answer every 30s.
class RemoteMachineTracker {
  RemoteMachineTracker({
    this.unreachableBackoff = kRemoteDirectoryUnreachableBackoff,
    this.refusedBackoff = kRemoteDirectoryRefusedBackoff,
    this.noCardBackoff = kRemoteDirectoryNoCardBackoff,
  });

  final Duration unreachableBackoff;
  final Duration refusedBackoff;
  final Duration noCardBackoff;

  final Map<String, RemoteMachineReport> _last = {};
  final Map<String, DateTime> _nextAskAt = {};

  /// Whether [uuid] should be asked fresh right now, rather than reported
  /// from [cached].
  bool shouldAsk(String uuid, DateTime now) {
    final next = _nextAskAt[uuid];
    return next == null || !now.isBefore(next);
  }

  RemoteMachineReport? cached(String uuid) => _last[uuid];

  /// Record a fresh ask's result and arm (or clear) that machine's backoff.
  void record(String uuid, RemoteMachineReport report, DateTime now) {
    _last[uuid] = report;
    final backoff = switch (report.outcome) {
      RemoteMachineRefused() => refusedBackoff,
      RemoteMachineUnreachable() => unreachableBackoff,
      RemoteMachineNoCard() => noCardBackoff,
      RemoteMachineRows() => null,
    };
    if (backoff == null) {
      _nextAskAt.remove(uuid);
    } else {
      _nextAskAt[uuid] = now.add(backoff);
    }
  }

  /// Drop bookkeeping for machines no longer candidates (closed socket,
  /// released control plane) — otherwise a machine that left never stops
  /// occupying a slot here.
  void prune(Set<String> stillCandidates) {
    _last.removeWhere((k, _) => !stillCandidates.contains(k));
    _nextAskAt.removeWhere((k, _) => !stillCandidates.contains(k));
  }
}

/// What peeking one candidate's control-plane client provider found this
/// tick. Kept separate from a bare `ControlPlaneClient?`: a provider still
/// building has not been asked anything, and collapsing that into "no client"
/// would classify it [RemoteMachineUnreachable] and arm a retry backoff
/// against an answer no RPC ever produced.
sealed class RemoteClientPeek {
  const RemoteClientPeek();
}

/// The provider has not settled — still building, or nothing has watched it
/// into existence yet. This cycle skips the machine entirely: no RPC, no
/// report, no backoff. A later tick, once the provider resolves, asks it for
/// real.
final class RemoteClientPending extends RemoteClientPeek {
  const RemoteClientPending();
}

/// The provider settled, with [client] to ask or null when this machine
/// genuinely has no live client (an offline target, or the dial itself
/// failed) — either way, a real answer this cycle got, worth classifying and
/// worth backing off on if it says nothing useful.
final class RemoteClientResolved extends RemoteClientPeek {
  const RemoteClientResolved(this.client);
  final ControlPlaneClient? client;
}

/// One collection cycle over every candidate: peek (never dial) each
/// machine's control-plane client via [peekClient], classify it, and consult
/// [tracker] so a backed-off machine is reported from cache instead of
/// re-asked. [peekClient] must never resolve or await a provider — a
/// [RemoteClientPending] answer costs this cycle nothing but the machine's
/// place in the push.
Future<List<RemoteMachineReport>> collectRemoteMachineReports({
  required Set<String> candidates,
  required RemoteClientPeek Function(String uuid) peekClient,
  required List<String> repoKeys,
  required Iterable<InventoryAgent> inventory,
  required RemoteMachineTracker tracker,
  required DateTime now,
  Duration timeout = kRemoteDirectoryPerMachineTimeout,
}) async {
  final nowMs = now.millisecondsSinceEpoch;
  final reports = await Future.wait(
    candidates.map((uuid) async {
      if (!tracker.shouldAsk(uuid, now)) {
        final cached = tracker.cached(uuid);
        if (cached != null) return cached;
      }
      final peek = peekClient(uuid);
      if (peek is RemoteClientPending) return null;
      final client = (peek as RemoteClientResolved).client;
      final outcome = await classifyMachine(client, repoKeys, timeout: timeout);
      final report = RemoteMachineReport(
        machineId: uuid,
        machineLabel: remoteDirectoryMachineLabel(inventory, uuid),
        observedAt: nowMs,
        outcome: outcome,
      );
      tracker.record(uuid, report, now);
      return report;
    }),
  );
  tracker.prune(candidates);
  return reports.whereType<RemoteMachineReport>().toList();
}

/// The heartbeat/fast-tick clock a push cycle consults. Pure and
/// wall-clock-free (every `now` is passed in) so the pump's `Timer` owns only
/// the polling itself.
class RemoteDirectoryCadence {
  RemoteDirectoryCadence({
    this.heartbeat = kRemoteDirectoryHeartbeat,
    this.minSpacing = kRemoteDirectoryMinSpacing,
    this.fastTick = kRemoteDirectoryFastTick,
    this.fastWindow = kRemoteDirectoryFastWindow,
  });

  final Duration heartbeat;
  final Duration minSpacing;
  final Duration fastTick;
  final Duration fastWindow;

  DateTime? _lastPush;
  DateTime? _fastUntil;

  void notePush(DateTime now) => _lastPush = now;

  /// Feed the ack's `unservedReads`: a positive count means an agent asked
  /// for a repo this machine had not reported on, so the next stretch of
  /// ticks runs at [fastTick] instead of [heartbeat].
  void noteAck(int unservedReads, DateTime now) {
    if (unservedReads > 0) _fastUntil = now.add(fastWindow);
  }

  /// Whether a HEARTBEAT push is due — true unconditionally before the first
  /// push (bootstrap: an empty first push, see [RemoteDirectoryPumpEngine.maybeRunCycle]).
  bool heartbeatDue(DateTime now) {
    final last = _lastPush;
    if (last == null) return true;
    final until = _fastUntil;
    final interval = (until != null && now.isBefore(until))
        ? fastTick
        : heartbeat;
    return now.difference(last) >= interval;
  }

  /// Whether an OFF-cadence trigger (a socket change, a registry change) may
  /// push right now, or must wait out [minSpacing] since the last push.
  bool triggerDue(DateTime now) {
    final last = _lastPush;
    return last == null || now.difference(last) >= minSpacing;
  }
}

/// One completed cycle, for a caller that wants to observe it (tests, mostly
/// — nothing in the app renders the pump's own status today).
class RemoteDirectoryCycleResult {
  const RemoteDirectoryCycleResult({required this.reports, required this.ack});
  final List<RemoteMachineReport> reports;
  final RemoteDirectoryAck ack;
}

/// Everything the pump decides, minus reading providers and owning a `Timer`.
/// The widget resolves each input via a `ref.read` peek and hands it here;
/// this class owns timing, backoff, the wire push, and the ack — the widget
/// itself owns only the `Timer` and the `ref.listenManual` wiring.
class RemoteDirectoryPumpEngine {
  RemoteDirectoryPumpEngine({RemoteDirectoryCadence? cadence, RemoteMachineTracker? tracker})
    : cadence = cadence ?? RemoteDirectoryCadence(),
      tracker = tracker ?? RemoteMachineTracker();

  final RemoteDirectoryCadence cadence;
  final RemoteMachineTracker tracker;

  List<String> _wantedRepoKeys = const [];
  List<String> get wantedRepoKeys => _wantedRepoKeys;

  /// Set once [kRemoteDirectoryLatchThreshold] consecutive pushes answer
  /// `BAD_REQUEST` — the local bridge predates this verb. Recorded against
  /// the control port it happened on: a `BAD_REQUEST` says nothing about a
  /// FUTURE bridge process, only this one, so [maybeRunCycle] clears it (and
  /// the streak) the moment the port names a different process.
  int? _latchedControlPort;
  bool get isLatched => _latchedControlPort != null;

  /// Consecutive `BAD_REQUEST` answers on the current control port — reset by
  /// any other outcome. See [kRemoteDirectoryLatchThreshold] for why this
  /// engine does not latch on the first one.
  int _consecutiveBadRequests = 0;

  /// Whether this engine has ever completed a push. Gates the bootstrap
  /// shortcut below — never reset by a failed push, only by one the bridge
  /// actually received (a successful ack, or a `BAD_RESPONSE` — see below).
  bool _everPushed = false;

  /// Run one cycle if due; a no-op (returns null) if not — including while
  /// latched off against [controlPort]. [pushFn] is the loopback POST itself
  /// (`HostControlClient.pushRemoteDirectory`); every other input here is a
  /// peek, never a dial.
  ///
  /// The very FIRST call always pushes, with `machines: []` and no candidate
  /// asked — this machine's own carrier proof (`lastPushAt`) must not wait
  /// out N peers' 6s timeouts before it exists at all. It deliberately does
  /// not consume [cadence]'s heartbeat slot, so the very next due check still
  /// finds a real cycle due — "the second cycle fetches" happens on the next
  /// poll tick, not a full heartbeat later.
  Future<RemoteDirectoryCycleResult?> maybeRunCycle({
    required DateTime now,
    required bool triggered,
    required int controlPort,
    required Set<String> candidates,
    required String? localUuid,
    required RemoteClientPeek Function(String uuid) peekClient,
    required Iterable<InventoryAgent> inventory,
    required Future<RemoteDirectoryAck> Function(
      List<Map<String, dynamic>> machines,
      int notConnected,
    )
    pushFn,
  }) async {
    if (_latchedControlPort != null && _latchedControlPort != controlPort) {
      _latchedControlPort = null;
      _consecutiveBadRequests = 0;
    }
    if (_latchedControlPort != null) return null;

    final bootstrap = !_everPushed;
    final due = bootstrap
        ? true
        : (triggered ? cadence.triggerDue(now) : cadence.heartbeatDue(now));
    if (!due) return null;

    final reports = bootstrap
        ? const <RemoteMachineReport>[]
        : await collectRemoteMachineReports(
            candidates: candidates,
            peekClient: peekClient,
            repoKeys: _wantedRepoKeys,
            inventory: inventory,
            tracker: tracker,
            now: now,
          );
    final notConnected = remoteDirectoryNotConnectedCount(
      inventory,
      localUuid,
      candidates,
    );
    if (!bootstrap) cadence.notePush(now);
    try {
      final ack = await pushFn(
        [for (final r in clampReportsForWire(reports)) r.toWire()],
        notConnected,
      );
      _wantedRepoKeys = ack.wantedRepoKeys;
      _everPushed = true;
      _consecutiveBadRequests = 0;
      cadence.noteAck(ack.unservedReads, now);
      return RemoteDirectoryCycleResult(reports: reports, ack: ack);
    } on HostControlException catch (e) {
      if (e.code == 'BAD_RESPONSE') {
        // The POST reached the bridge and was accepted (`ok:true`) — only
        // the reply body didn't parse, a hand-mirrored-contract drift
        // downstream of delivery. Exit bootstrap all the same: repeating an
        // empty `machines: []` REPLACE every tick because the ack couldn't
        // be read is worse than moving on with the last-known
        // `wantedRepoKeys` and letting cadence govern the next push as usual.
        _everPushed = true;
        _consecutiveBadRequests = 0;
        return null;
      }
      if (e.code == 'BAD_REQUEST') {
        _consecutiveBadRequests++;
        if (_consecutiveBadRequests >= kRemoteDirectoryLatchThreshold) {
          _latchedControlPort = controlPort;
        }
      } else {
        _consecutiveBadRequests = 0;
      }
      return null;
    } catch (_) {
      // Transport error / dead host between peek and push — retried on the
      // next due cycle, matching the reaper's dead-host tolerance elsewhere.
      _consecutiveBadRequests = 0;
      return null;
    }
  }
}
