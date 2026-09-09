import 'dart:async';

import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../project/project_session_registry.dart';
import '../providers/agent_transport.dart';
import '../providers/device_provisioning.dart';
import '../util/ab_log.dart';
import '../util/detached.dart';
import 'session_bus_frame.dart';
import 'session_bus_links.dart';

const String _kComponent = 'SessionBusCarrier';

/// How long an attach is left alone after the last dial. Links are recomputed
/// by ordinary session traffic, so without this a machine that is simply
/// offline would be re-dialled on every `session:updated` for as long as the
/// membership lasts — and a transport handed back already closed would be
/// re-dialled in a tight loop, since its stream ends the instant it is heard.
const Duration kSessionBusAttachRetryCooldown = Duration(seconds: 10);

/// The cooldown the carrier actually uses, as a provider so a test can shrink
/// it: it bounds how long a leg whose transport ENDED stays gone, and a test
/// pinning that recovery would otherwise have to wait out real seconds.
final sessionBusAttachCooldownProvider = Provider<Duration>(
  (ref) => kSessionBusAttachRetryCooldown,
);

/// What the carrier is doing right now. Counters are cumulative for the app's
/// lifetime and exist so the forwarding decisions are observable — from a test,
/// and from a diagnostics surface — without reaching into private state.
@immutable
class SessionBusCarrierStatus {
  const SessionBusCarrierStatus({
    this.links = 0,
    this.attachedLeads = 0,
    this.attachedPeers = 0,
    this.toPeer = 0,
    this.toLead = 0,
    this.refused = 0,
    this.dropped = 0,
  });

  static const SessionBusCarrierStatus empty = SessionBusCarrierStatus();

  final int links;
  final int attachedLeads;
  final int attachedPeers;

  /// Frames handed from a lead's loopback to a member's relay stream.
  final int toPeer;

  /// Frames handed from a member's relay stream back to the lead's loopback.
  final int toLead;

  /// Frames this app carries no membership for. Expected in small numbers: a
  /// release racing a frame already in flight lands here.
  final int refused;

  /// Frames that were ours to forward but whose addressed leg is not attached.
  /// Not an error — the sending bridge holds the frame and retries — but it is
  /// the difference between "not ours" and "ours, nowhere to put it yet".
  final int dropped;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionBusCarrierStatus &&
          other.links == links &&
          other.attachedLeads == attachedLeads &&
          other.attachedPeers == attachedPeers &&
          other.toPeer == toPeer &&
          other.toLead == toLead &&
          other.refused == refused &&
          other.dropped == dropped;

  @override
  int get hashCode => Object.hash(
    links,
    attachedLeads,
    attachedPeers,
    toPeer,
    toLead,
    refused,
    dropped,
  );
}

class _BusLeg {
  _BusLeg(this.transport, this.sub);
  final AgentTransport transport;
  final StreamSubscription<InboundMessage> sub;
}

/// App-wide relay for `session-bus:*` frames between a lead session's local
/// bridge and the bridges of the machines that are members of it.
///
/// The app is a transport leg and nothing else (spec D7, 4.1): frames are
/// forwarded VERBATIM, never parsed into a model and rebuilt, so a field a
/// later bridge adds survives an older app. Sequencing, acks and retry live
/// entirely in the two bridges; the carrier keeps no task state.
///
/// Lifetime is the app's, not the focused project's — a lead and its member
/// keep talking while the user is looking at a third project — which is why the
/// host widget sits beside the control-plane reaper in `app_shell.dart` rather
/// than anywhere inside the workspace.
class SessionBusCarrier extends Notifier<SessionBusCarrierStatus> {
  final Map<String, _BusLeg> _leads = {};
  final Map<String, _BusLeg> _peers = {};
  final Set<String> _attaching = {};
  final Map<String, DateTime> _lastAttemptAt = {};

  SessionBusLinks _links = SessionBusLinks.empty;

  /// Legs already reported as missing, so a bridge that retries a frame every
  /// second does not write a line every second. Cleared the moment that leg
  /// carries something, so a link that breaks twice is said twice.
  final Set<String> _dropWarned = {};

  /// Lead sessions already reported as addressed by a project id that is not
  /// the one this app reaches them through. Latched per session: the condition
  /// is a permanent property of a stored membership, so it would otherwise be
  /// written on every frame for the life of the session.
  final Set<String> _driftWarned = {};

  /// Lead projects last reported as carrying nothing because they are closed.
  /// Kept so the line is written when the situation CHANGES rather than on
  /// every reconcile — the link set is re-derived by ordinary session traffic.
  Set<String> _idleLeadsWarned = const {};

  Timer? _retry;
  bool _disposed = false;
  bool _reconciling = false;
  bool _dirty = false;
  int _toPeer = 0;
  int _toLead = 0;
  int _refused = 0;
  int _dropped = 0;

  @override
  SessionBusCarrierStatus build() {
    ref.listen(sessionBusLinksProvider, (_, _) => _kick('links'));
    // The warm set decides which lead legs may exist at all (below), so a
    // project opening is as much a reconcile trigger as a membership change.
    ref.listen(projectSessionRegistryProvider, (_, _) => _kick('warm set'));
    ref.onDispose(() {
      _disposed = true;
      _retry?.cancel();
      _retry = null;
      _detachAll();
    });
    // build() must return before the first `state` write, so the first pass is
    // deferred by a microtask rather than run inline.
    detached(_kComponent, 'initial reconcile failed', () async {
      await null;
      _reconcile();
    });
    return SessionBusCarrierStatus.empty;
  }

  void _kick(String why) =>
      detached(_kComponent, 'reconcile after $why failed', () async {
        _reconcile();
      });

  /// Schedules the reconcile that a cooled-down attach is owed.
  ///
  /// Without it the cooldown is a permanent refusal rather than a delay: the
  /// only two reconcile triggers are the link set and the warm set, and neither
  /// changes while a machine is simply not answering. One pending timer at a
  /// time, because it kicks a WHOLE reconcile — which re-arms for whatever is
  /// still throttled — so a second would only duplicate the pass.
  void _armRetry(Duration delay) {
    if (_disposed || _retry != null) return;
    _retry = Timer(delay, () {
      _retry = null;
      _kick('attach retry');
    });
  }

  /// Re-derives both legs and the pin from the current links.
  ///
  /// Re-entrant by construction: the pin write can evict a project, which the
  /// registry listener above turns straight back into a reconcile. Looping on a
  /// dirty flag rather than recursing keeps that to one pass at a time and
  /// terminates, because both the pin write and the attach set settle.
  void _reconcile() {
    if (_disposed) return;
    if (_reconciling) {
      _dirty = true;
      return;
    }
    _reconciling = true;
    try {
      do {
        _dirty = false;
        _reconcileOnce();
      } while (_dirty && !_disposed);
    } finally {
      _reconciling = false;
    }
  }

  void _reconcileOnce() {
    _links = ref.read(sessionBusLinksProvider);
    final warm = ref.read(projectSessionRegistryProvider).toSet();

    // Single writer for the whole pin, in the same pass that owns the legs —
    // the two answer the same question, and splitting them is how a pin outlives
    // the membership that justified it. Both halves: the lead project (local
    // bucket) so the loopback leg survives a cold spell, and the peer project
    // (relay bucket) so its stream — and the transcript a member tab renders
    // off it — is not evicted under a session that is still running.
    ref.read(projectSessionRegistryProvider.notifier).setPinned({
      for (final l in _links.links) ...[l.leadProjectId, l.peerRegistrationId],
    });

    // A lead leg is only ever attached to an ALREADY-open project: resolving
    // the transport for a cold local project spawns a bridge and an agent, so a
    // carrier that opened its own would start every machine's work at app
    // launch. The lead bridge holds undelivered frames and retries, so delivery
    // resumes when the user opens the project.
    final wantedLeads = <String>{
      for (final l in _links.links)
        if (warm.contains(l.leadProjectId)) l.leadProjectId,
    };
    // The peer half is opened rather than waited for: it costs a stream binding
    // on a machine the pin is already holding a socket for, and without it the
    // first `session-bus:assign` of a membership has nowhere to land. Bounded
    // by the open lead projects, so a closed lead dials nothing.
    final wantedPeers = <String>{
      for (final l in _links.links)
        if (wantedLeads.contains(l.leadProjectId)) l.peerRegistrationId,
    };

    // A link whose lead project is closed attaches NOTHING — not the lead leg,
    // and so not the peer leg either — while the lead's own bridge goes on
    // handing frames to this app and being told they left. That is the one
    // failure with no other witness on either side, so it is said here.
    final idleLeads = <String>{
      for (final l in _links.links)
        if (!warm.contains(l.leadProjectId)) l.leadProjectId,
    };
    if (!setEquals(idleLeads, _idleLeadsWarned)) {
      _idleLeadsWarned = idleLeads;
      if (idleLeads.isNotEmpty) {
        AbLog.warn(
          _kComponent,
          'lead project not open — carrying nothing for its members',
          fields: {'leads': idleLeads.join(','), 'links': _links.length},
        );
      }
    }

    _dropLegsOutside(_leads, wantedLeads);
    _dropLegsOutside(_peers, wantedPeers);
    // The throttle is per id and is never cleared on success, so a released
    // membership would leave its timestamp behind for the app's lifetime —
    // and, worse, make the same machine's NEXT join wait out a cooldown that
    // belongs to a session it is no longer in.
    _lastAttemptAt.removeWhere(
      (id, _) => !wantedLeads.contains(id) && !wantedPeers.contains(id),
    );
    // Same reason, one latch further on: a warning left behind for a released
    // member silences the first drop of its next join.
    _dropWarned.removeWhere(
      (id) => !wantedLeads.contains(id) && !wantedPeers.contains(id),
    );
    final leadSessions = {for (final l in _links.links) l.leadSessionId};
    _driftWarned.removeWhere((id) => !leadSessions.contains(id));
    for (final id in wantedLeads) {
      _ensureLeg(id, fromLead: true);
    }
    for (final id in wantedPeers) {
      _ensureLeg(id, fromLead: false);
    }
    _publish();
  }

  void _dropLegsOutside(Map<String, _BusLeg> legs, Set<String> wanted) {
    for (final id in legs.keys.toList()) {
      if (wanted.contains(id)) continue;
      _detach(legs, id);
    }
  }

  void _detach(Map<String, _BusLeg> legs, String id) {
    final leg = legs.remove(id);
    if (leg == null) return;
    detached(_kComponent, 'cancel leg $id failed', () => leg.sub.cancel());
  }

  void _detachAll() {
    _dropLegsOutside(_leads, const {});
    _dropLegsOutside(_peers, const {});
  }

  void _ensureLeg(String id, {required bool fromLead}) {
    final legs = fromLead ? _leads : _peers;
    if (legs.containsKey(id) || _attaching.contains(id)) return;
    final cooldown = ref.read(sessionBusAttachCooldownProvider);
    final last = _lastAttemptAt[id];
    if (last != null) {
      final since = DateTime.now().difference(last);
      if (since < cooldown) {
        _armRetry(cooldown - since);
        return;
      }
    }
    _lastAttemptAt[id] = DateTime.now();
    _attaching.add(id);
    final what = 'attach ${fromLead ? 'lead' : 'peer'} leg $id';
    detached(_kComponent, what, () async {
      try {
        final transport = await ref.read(agentTransportForProvider(id).future);
        if (_disposed || transport == null) return;
        if (legs.containsKey(id)) return;
        final sub = transport.messages.listen(
          (raw) => _onInbound(id, fromLead: fromLead, raw: raw),
          // A transport that ends (host restart, eviction, sign-out) is
          // detached and then DIALLED AGAIN: neither the links nor the warm
          // set moves when a socket dies under a live membership, so nothing
          // else would ever ask for its replacement and the lead bridge would
          // retry into a leg that is gone for good. The dial goes through the
          // same cooldown as any other, which is what keeps a transport handed
          // back already closed — its stream ends the moment it is listened to
          // — from spinning attach/close forever.
          onDone: () {
            _detach(legs, id);
            _kick('leg $id closed');
          },
          onError: (Object e) => AbLog.warn(
            _kComponent,
            'leg stream error',
            fields: {'leg': id, 'error': '$e'},
          ),
        );
        legs[id] = _BusLeg(transport, sub);
      } finally {
        _attaching.remove(id);
        // A whole reconcile, not a publish: a membership can vanish while the
        // dial is in flight, and an in-flight attach lives in `_attaching`,
        // where `_dropLegsOutside` cannot see it — so this is the only pass
        // that can reap a leg attached for a link that no longer exists.
        _reconcile();
      }
    });
  }

  void _onInbound(
    String legId, {
    required bool fromLead,
    required InboundMessage raw,
  }) {
    final json = raw.json;
    if (!isSessionBusFrame(json)) return;

    // Narrowed to the delivering transport: a frame off lead project A's
    // loopback may only reach a member OF A, and a frame off peer P's stream
    // may only reach a lead that P is a member of.
    final relevant = [
      for (final l in _links.links)
        if (fromLead ? l.leadProjectId == legId : l.peerRegistrationId == legId)
          l,
    ];
    final decision = classifyBusFrame(
      json: json,
      fromLead: fromLead,
      localMachineId: ref.read(localDeviceUuidProvider).value,
      allowedPeerKeys: {for (final l in relevant) l.peer.key},
      allowedLeadSessionIds: {for (final l in relevant) l.leadSessionId},
    );

    final to = busTo(json);
    switch (decision) {
      case BusForward.refuse:
        _refused++;
        AbLog.warn(
          _kComponent,
          'refused bus frame',
          fields: {
            'type': json['type'],
            'leg': legId,
            'fromLead': fromLead,
            'to': to?.key,
          },
        );
      case BusForward.toPeer:
        _forward(
          _peers[to!.registrationId],
          raw,
          legId: to.registrationId,
          onSent: () => _toPeer++,
        );
      case BusForward.toLead:
        // The leg comes from the LINK, never from `to.projectId`: that id is
        // whatever project the peer recorded at join time, and one checkout can
        // be open as more than one project, so it names a label rather than a
        // route. `classifyBusFrame` has already established that this leg
        // carries `to.sessionId`, which is what makes the lookup total.
        final lead = relevant.firstWhere((l) => l.leadSessionId == to!.sessionId);
        _noteProjectDrift(lead, to!);
        _forward(
          _leads[lead.leadProjectId],
          raw,
          legId: lead.leadProjectId,
          onSent: () => _toLead++,
        );
    }
    _publish();
  }

  /// Says once that this app holds the lead under a project id the peer does not
  /// address it by.
  ///
  /// Worded from THIS app's side deliberately. The peer's id is the one that
  /// came off a frame the lead's own bridge answered, so it is usually the
  /// correct one and the app's row is the stale alias — a folder picked before
  /// any host was warm keeps the selected path's hash while the bridge folds a
  /// linked worktree into its primary checkout (`reconcileWithHost`,
  /// providers/projects.dart). A reader greps this line precisely when
  /// something is wrong, and pointing them across the wire sends them to the
  /// machine that is right.
  ///
  /// Routing no longer depends on the id, so this changes nothing about
  /// delivery — but a peer's row still RENDERS the id it was given, so the two
  /// sides disagreeing is visible to the other agent even when nothing strands.
  void _noteProjectDrift(SessionBusLink lead, BusEndpoint to) {
    if (to.projectId == lead.leadProjectId) return;
    if (!_driftWarned.add(lead.leadSessionId)) return;
    AbLog.warn(
      _kComponent,
      'this app holds the lead under a project the peer does not address it by '
          '— routed by session instead',
      fields: {
        'session': lead.leadSessionId,
        'addressedByPeer': to.projectId,
        'heldByThisApp': lead.leadProjectId,
      },
    );
  }

  void _forward(
    _BusLeg? leg,
    InboundMessage raw, {
    required String legId,
    required void Function() onSent,
  }) {
    if (leg == null) {
      _dropped++;
      // The sending bridge is told this frame LEFT — accepting it is all the
      // hand-off can report — so this line is the only place either process
      // records that it went nowhere. Without it a bridge retries under a true
      // `sent` forever and no log on either machine says why.
      if (_dropWarned.add(legId)) {
        AbLog.warn(
          _kComponent,
          'no leg for addressed member — frame not carried',
          fields: {'leg': legId, 'type': raw.json['type']},
        );
      }
      return;
    }
    _dropWarned.remove(legId);
    onSent();
    // The same channel it arrived on, and the same map: the app must not decide
    // anything about a frame it is only carrying.
    detached(
      _kComponent,
      'forward ${raw.json['type']} failed',
      () => leg.transport.send(raw.json, channel: raw.channel),
    );
  }

  void _publish() {
    if (_disposed) return;
    state = SessionBusCarrierStatus(
      links: _links.length,
      attachedLeads: _leads.length,
      attachedPeers: _peers.length,
      toPeer: _toPeer,
      toLead: _toLead,
      refused: _refused,
      dropped: _dropped,
    );
  }
}

final sessionBusCarrierProvider =
    NotifierProvider<SessionBusCarrier, SessionBusCarrierStatus>(
      SessionBusCarrier.new,
    );
