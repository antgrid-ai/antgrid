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

/// How long an attach is left alone after the last dial. Legs are re-derived by
/// ordinary bus traffic, so without this a machine that is simply offline would
/// be re-dialled on every frame — and a transport handed back already closed
/// would be re-dialled in a tight loop, since its stream ends the instant it is
/// heard.
const Duration kSessionBusAttachRetryCooldown = Duration(seconds: 10);

/// The cooldown the carrier actually uses, as a provider so a test can shrink
/// it: it bounds how long a leg whose transport ENDED stays gone, and a test
/// pinning that recovery would otherwise have to wait out real seconds.
final sessionBusAttachCooldownProvider = Provider<Duration>(
  (ref) => kSessionBusAttachRetryCooldown,
);

/// Frames held for one leg while its dial is in flight.
///
/// Small on purpose: this covers the gap between a frame asking for a leg and
/// that leg existing, not an offline machine. A peer that never answers has its
/// held frames dropped and said out loud rather than accumulated.
const int kSessionBusHeldPerLeg = 16;

/// What the carrier is doing right now. Counters are cumulative for the app's
/// lifetime and exist so the forwarding decisions are observable — from a test,
/// and from a diagnostics surface — without reaching into private state.
@immutable
class SessionBusCarrierStatus {
  const SessionBusCarrierStatus({
    this.links = 0,
    this.attachedLocal = 0,
    this.attachedPeers = 0,
    this.toPeer = 0,
    this.toLocal = 0,
    this.refused = 0,
    this.dropped = 0,
  });

  static const SessionBusCarrierStatus empty = SessionBusCarrierStatus();

  final int links;

  /// Loopback legs: one per local project the user has open.
  final int attachedLocal;

  /// Relay legs: one per machine+project a frame has asked to reach.
  final int attachedPeers;

  /// Frames handed from a local project's loopback out to a peer's stream.
  final int toPeer;

  /// Frames handed from a peer's stream back to a local project's loopback.
  final int toLocal;

  /// Frames this app will not route: not a bus type, no address, or addressed
  /// to a session no open local project carries. Every one of them is a frame
  /// the sending bridge has already been told left, so none is routine — the
  /// warn line names which fact was missing.
  final int refused;

  /// Frames that were ours to forward and whose leg never came up. Distinct
  /// from [refused]: the address was good and the machine was not there.
  final int dropped;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionBusCarrierStatus &&
          other.links == links &&
          other.attachedLocal == attachedLocal &&
          other.attachedPeers == attachedPeers &&
          other.toPeer == toPeer &&
          other.toLocal == toLocal &&
          other.refused == refused &&
          other.dropped == dropped;

  @override
  int get hashCode => Object.hash(
    links,
    attachedLocal,
    attachedPeers,
    toPeer,
    toLocal,
    refused,
    dropped,
  );
}

class _BusLeg {
  _BusLeg(this.transport, this.sub, {required this.local});
  final AgentTransport transport;
  final StreamSubscription<InboundMessage> sub;

  /// A local project's loopback transport, as opposed to a peer's relay stream.
  /// Which side a leg is on decides both directions of the hand-off, so it is
  /// held here rather than re-derived from the shape of the leg's id.
  final bool local;
}

/// App-wide relay for `session-bus:*` frames between the bridges of two
/// machines.
///
/// The app is a transport leg and nothing else (§6.1): frames are forwarded
/// VERBATIM, never parsed into a model and rebuilt, so a field a later bridge
/// adds survives an older app. Threads, receipts and retry live entirely in the
/// two bridges; the carrier keeps no bus state.
///
/// Lifetime is the app's, not the focused project's — two agents keep talking
/// while the user is looking at a third project — which is why the host widget
/// sits beside the control-plane reaper in `app_shell.dart` rather than
/// anywhere inside the workspace.
class SessionBusCarrier extends Notifier<SessionBusCarrierStatus> {
  final Map<String, _BusLeg> _legs = {};
  final Set<String> _attaching = {};
  final Map<String, DateTime> _lastAttemptAt = {};
  final Map<String, List<InboundMessage>> _held = {};

  SessionBusLinks _links = SessionBusLinks.empty;

  /// Legs already reported as missing, so a peer that is offline for an hour
  /// does not write a line per frame. Cleared the moment that leg carries
  /// something, so a link that breaks twice is said twice.
  final Set<String> _dropWarned = {};

  /// (local leg, session) pairs already reported as addressed by a project id
  /// that is not the one this app holds them under. Latched: the condition is a
  /// property of what the other machine stored, so it would otherwise be
  /// written on every frame for the life of the session.
  final Set<(String, String)> _driftWarned = {};

  /// Legs whose buffer has already been reported full. Its own latch rather
  /// than [_warnNoLeg]'s, see [_warnHeldOverflow].
  final Set<String> _overflowWarned = {};

  Timer? _retry;
  bool _disposed = false;
  bool _reconciling = false;
  bool _dirty = false;
  int _toPeer = 0;
  int _toLocal = 0;
  int _refused = 0;
  int _dropped = 0;

  @override
  SessionBusCarrierStatus build() {
    ref.listen(sessionBusLinksProvider, (_, _) => _kick('links'));
    // The open local projects are the legs a frame can arrive on at all, so a
    // project opening is as much a reconcile trigger as a peer being addressed.
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
  /// only two reconcile triggers are the link set and the open-project set, and
  /// neither changes while a machine is simply not answering. One pending timer
  /// at a time, because it kicks a WHOLE reconcile — which re-arms for whatever
  /// is still throttled — so a second would only duplicate the pass.
  void _armRetry(Duration delay) {
    if (_disposed || _retry != null) return;
    _retry = Timer(delay, () {
      _retry = null;
      _kick('attach retry');
    });
  }

  /// Re-derives the legs and the pin from the current links and open projects.
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
    final registry = ref.read(projectSessionRegistryProvider.notifier);

    // Reading a cold local project's transport spawns a bridge and an agent, so
    // the carrier must never open one of its own. The registry is what makes
    // this safe: `projectSessionProvider` touches an id only AFTER its
    // transport resolved, so every id here is already dialled. A closed project
    // has no loopback owner for its bridge to hand a frame to either, so there
    // is nothing to carry for it.
    final wantedLocal = registry.localOpenProjects().toSet();
    final wantedPeers = {for (final l in _links.links) l.registrationId};

    // The peers alone. A relay stream carrying a live exchange must not be
    // evicted under it; a local project is warm because the user opened it, and
    // pinning that here would outlive their interest in it.
    registry.setPinned(wantedPeers);

    final wanted = {...wantedLocal, ...wantedPeers};
    for (final id in _legs.keys.toList()) {
      if (!wanted.contains(id)) _detach(id);
    }
    // The throttle is per id and is never cleared on success, so a peer that
    // goes quiet would leave its timestamp behind for the app's lifetime — and,
    // worse, make its NEXT exchange wait out a cooldown belonging to a finished
    // one.
    _lastAttemptAt.removeWhere((id, _) => !wanted.contains(id));
    for (final id in _held.keys.toList()) {
      if (!wanted.contains(id)) _dropHeld(id, 'the leg is no longer addressed');
    }
    // Same reason, one latch further on: a warning left behind for a released
    // peer silences the first drop of its next exchange.
    _dropWarned.removeWhere((id) => !wanted.contains(id));
    _overflowWarned.removeWhere((id) => !wanted.contains(id));
    _driftWarned.removeWhere((pair) => !wantedLocal.contains(pair.$1));

    for (final id in wantedLocal) {
      _ensureLeg(id, local: true);
    }
    for (final id in wantedPeers) {
      _ensureLeg(id, local: false);
    }
    _publish();
  }

  void _detach(String id) {
    final leg = _legs.remove(id);
    if (leg == null) return;
    detached(_kComponent, 'cancel leg $id failed', () => leg.sub.cancel());
  }

  void _detachAll() {
    for (final id in _legs.keys.toList()) {
      _detach(id);
    }
  }

  void _ensureLeg(String id, {required bool local}) {
    if (_legs.containsKey(id) || _attaching.contains(id)) return;
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
    final what = 'attach ${local ? 'local' : 'peer'} leg $id';
    detached(_kComponent, what, () async {
      try {
        final transport = await ref.read(agentTransportForProvider(id).future);
        if (_disposed) return;
        if (transport == null) {
          // The machine is not reachable. Anything held for it is gone rather
          // than accumulating against a leg that may never come up.
          _dropHeld(id, 'no transport for the addressed machine');
          return;
        }
        if (_legs.containsKey(id)) {
          // A concurrent dial won the race. Anything held arrived while neither
          // attempt had a leg, and the winner's own flush ran before it landed.
          _flushHeld(id);
          return;
        }
        final sub = transport.messages.listen(
          (raw) => _onInbound(id, raw: raw),
          // A transport that ends (host restart, eviction, sign-out) is
          // detached and then DIALLED AGAIN: neither the links nor the open set
          // moves when a socket dies under a live exchange, so nothing else
          // would ever ask for its replacement and the sending bridge would
          // retry into a leg that is gone for good. The dial goes through the
          // same cooldown as any other, which is what keeps a transport handed
          // back already closed — its stream ends the moment it is listened to
          // — from spinning attach/close forever.
          onDone: () {
            _detach(id);
            _kick('leg $id closed');
          },
          onError: (Object e) => AbLog.warn(
            _kComponent,
            'leg stream error',
            fields: {'leg': id, 'error': '$e'},
          ),
        );
        _legs[id] = _BusLeg(transport, sub, local: local);
        _flushHeld(id);
      } finally {
        _attaching.remove(id);
        // A whole reconcile, not a publish: a link can expire while the dial is
        // in flight, and an in-flight attach lives in `_attaching`, where the
        // reconcile's drop pass cannot see it — so this is the only pass that
        // can reap a leg attached for a peer nothing is addressing any more.
        _reconcile();
      }
    });
  }

  /// The session ids each open local project carries, which is what an inbound
  /// frame is placed by.
  ///
  /// Every local project a leg is WANTED for, not only the ones already
  /// attached. A dial is a whole async transport resolution and, after a failed
  /// one, a cooldown on top; the sending bridge was told the frame left the
  /// moment its owner socket took it, so nothing retries. Placing by attached
  /// legs alone would refuse every frame that arrives inside that window — and
  /// refuse it for good, where holding it costs one buffer slot.
  Map<String, Set<String>> _localSessions() => {
    for (final id in ref
        .read(projectSessionRegistryProvider.notifier)
        .localOpenProjects())
      id: ref.read(sessionBusLocalSessionsProvider(id)),
  };

  void _onInbound(String legId, {required InboundMessage raw}) {
    final json = raw.json;
    if (!isSessionBusFrame(json)) return;

    final localMachineId = ref.read(localDeviceUuidProvider).value;
    final byProject = _localSessions();
    final routing = classifyBusFrame(
      json: json,
      localMachineId: localMachineId,
      localSessionIds: {for (final ids in byProject.values) ...ids},
    );

    final to = busTo(json);
    switch (routing.forward) {
      case BusForward.refuse:
        _refused++;
        AbLog.warn(
          _kComponent,
          'refused bus frame',
          fields: {
            'type': json['type'],
            'leg': legId,
            'to': to?.key,
            'because': routing.because,
          },
        );
      case BusForward.toPeer:
        // Demand IS the leg source: a frame naming a machine+project this app
        // holds no leg for is what asks for one. Recorded before the forward so
        // the very first frame of an exchange is held for the leg it opens
        // rather than being the one frame that cannot be sent.
        _reach(to!, localMachineId);
        _forward(to.registrationId, raw);
      case BusForward.toLocal:
        // Sound because `classifyBusFrame` was handed the union of this same
        // snapshot: a toLocal verdict means one of these projects carries the
        // session. `_forward` holds if that project's leg is still dialling.
        final target = byProject.entries
            .firstWhere((e) => e.value.contains(to!.sessionId))
            .key;
        _noteProjectDrift(target, to!);
        // The far side is answering, so its leg is wanted for at least as long
        // as this app takes to hand the reply back.
        _reach(busFrom(json)!, localMachineId);
        _forward(target, raw);
    }
    _publish();
  }

  /// Records a peer address as wanted, unless it names this machine — a
  /// self-addressed leg would dial the relay to reach a bridge already on the
  /// other end of a loopback socket.
  void _reach(BusEndpoint peer, String? localMachineId) {
    if (peer.machineId == localMachineId) return;
    ref
        .read(sessionBusLinksProvider.notifier)
        .reach(peer.machineId, peer.projectId);
  }

  /// Says once that this app holds a session under a project id the other
  /// machine does not address it by.
  ///
  /// Worded from THIS app's side deliberately. The other machine's id came off
  /// a frame that session's own bridge answered, so it is usually the correct
  /// one and this app's row is the stale alias — a folder picked before any
  /// host was warm keeps the selected path's hash while the bridge folds a
  /// linked worktree into its primary checkout (`reconcileWithHost`,
  /// providers/projects.dart). A reader greps this line precisely when
  /// something is wrong, and pointing them across the wire sends them to the
  /// machine that is right.
  ///
  /// Routing does not depend on the id, so this changes nothing about delivery
  /// — but a directory row still RENDERS the id it was given, so the two sides
  /// disagreeing is visible to the other agent even when nothing strands.
  void _noteProjectDrift(String legId, BusEndpoint to) {
    if (to.projectId == legId) return;
    if (!_driftWarned.add((legId, to.sessionId))) return;
    AbLog.warn(
      _kComponent,
      'this app holds the session under a project the other machine does not '
          'address it by — routed by session instead',
      fields: {
        'session': to.sessionId,
        'addressedByPeer': to.projectId,
        'heldByThisApp': legId,
      },
    );
  }

  void _forward(String legId, InboundMessage raw) {
    final leg = _legs[legId];
    if (leg == null) {
      _hold(legId, raw);
      return;
    }
    _dropWarned.remove(legId);
    _overflowWarned.remove(legId);
    if (leg.local) {
      _toLocal++;
    } else {
      _toPeer++;
    }
    // The same channel it arrived on, and the same map: the app must not decide
    // anything about a frame it is only carrying.
    detached(
      _kComponent,
      'forward ${raw.json['type']} failed',
      () => leg.transport.send(raw.json, channel: raw.channel),
    );
  }

  /// Keeps a frame while its leg comes up.
  ///
  /// `LocalListener.deliverToOwner` reports success the moment the owner socket
  /// accepts a frame, so the sending bridge drops it from its held store and
  /// nothing retries. Without this buffer a demand-attached leg would lose the
  /// one frame that asked for it, which is the frame that opens every exchange.
  void _hold(String legId, InboundMessage raw) {
    final held = _held.putIfAbsent(legId, () => <InboundMessage>[]);
    if (held.length >= kSessionBusHeldPerLeg) {
      // The oldest goes, never the arriving frame: what is held is one side of
      // a conversation, and the turn the other agent is waiting on is the last
      // one sent. Keeping the first sixteen would deliver the opening of an
      // exchange and silently swallow the rest of it.
      held.removeAt(0);
      _dropped++;
      _warnHeldOverflow(legId);
    }
    held.add(raw);
  }

  /// Said once per leg, and on its own latch: the leg coming up is a different
  /// event from it never coming up, and an overflow sharing [_warnNoLeg]'s latch
  /// would increment `dropped` with no line anywhere — the silence this whole
  /// family of warnings exists to prevent.
  void _warnHeldOverflow(String legId) {
    if (!_overflowWarned.add(legId)) return;
    AbLog.warn(
      _kComponent,
      'held to the cap while its leg came up — oldest frames dropped',
      fields: {'leg': legId, 'cap': kSessionBusHeldPerLeg},
    );
  }

  void _flushHeld(String legId) {
    final held = _held.remove(legId);
    if (held == null) return;
    for (final raw in held) {
      _forward(legId, raw);
    }
  }

  void _dropHeld(String legId, String why) {
    final held = _held.remove(legId);
    if (held == null || held.isEmpty) return;
    _dropped += held.length;
    _warnNoLeg(legId, why, held.length);
  }

  /// The only place either process records that a frame went nowhere: the
  /// sending bridge was told it left, so without this line it retries under a
  /// true `sent` forever and no log on either machine says why.
  void _warnNoLeg(String legId, String why, int frames) {
    if (!_dropWarned.add(legId)) return;
    AbLog.warn(
      _kComponent,
      'no leg for addressed member — frame not carried',
      fields: {'leg': legId, 'frames': frames, 'why': why},
    );
  }

  void _publish() {
    if (_disposed) return;
    var local = 0;
    var peer = 0;
    for (final leg in _legs.values) {
      if (leg.local) {
        local++;
      } else {
        peer++;
      }
    }
    state = SessionBusCarrierStatus(
      links: _links.length,
      attachedLocal: local,
      attachedPeers: peer,
      toPeer: _toPeer,
      toLocal: _toLocal,
      refused: _refused,
      dropped: _dropped,
    );
  }
}

final sessionBusCarrierProvider =
    NotifierProvider<SessionBusCarrier, SessionBusCarrierStatus>(
      SessionBusCarrier.new,
    );
