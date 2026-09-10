import 'dart:async';
import 'dart:io';

import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/session_bus/session_bus_carrier.dart';
import 'package:antgrid/session_bus/session_bus_links.dart';
import 'package:antgrid/util/ab_log.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _localProject = 'p-local';
const _localSession = 's-local';
const _peerMachine = 'm-peer';
const _peerProject = 'p-peer';
const _peerReg = '$_peerMachine.$_peerProject';

/// Records the channel too — the carrier must hand a frame on whatever channel
/// it arrived on, and [FakeAgentTransport.sent] alone cannot see that.
class _ChannelTransport extends FakeAgentTransport {
  final List<({Map<String, dynamic> json, String channel})> outbound = [];

  @override
  Future<void> send(
    Map<String, dynamic> message, {
    String channel = 'control',
  }) async {
    outbound.add((json: message, channel: channel));
    await super.send(message, channel: channel);
  }
}

Map<String, dynamic> _outbound({String type = 'session-bus:post'}) => {
  'type': type,
  'contextId': 'ctx-1',
  'from': const {
    'machineId': 'm-local',
    'projectId': _localProject,
    'sessionId': _localSession,
  },
  'to': const {
    'machineId': _peerMachine,
    'projectId': _peerProject,
    'sessionId': 's-peer',
  },
};

Map<String, dynamic> _inbound({
  String type = 'session-bus:ack',
  String toProject = _localProject,
  String toSession = _localSession,
  String context = 'ctx-1',
}) => {
  'type': type,
  'contextId': context,
  'from': const {
    'machineId': _peerMachine,
    'projectId': _peerProject,
    'sessionId': 's-peer',
  },
  'to': {
    'machineId': 'm-local',
    'projectId': toProject,
    'sessionId': toSession,
  },
};

class _Harness {
  _Harness({
    Duration cooldown = kSessionBusAttachRetryCooldown,
    Duration idle = kSessionBusLinkIdle,
  }) {
    registry = ProjectSessionRegistry(
      localCap: 10,
      relayCap: 10,
      onEvict: (_) async {},
    );
    container = ProviderContainer(
      overrides: [
        localDeviceUuidProvider.overrideWith((ref) => 'm-local'),
        projectSessionRegistryProvider.overrideWith(
          () => ProjectSessionRegistryController(registry),
        ),
        sessionBusAttachCooldownProvider.overrideWithValue(cooldown),
        sessionBusLinkIdleProvider.overrideWithValue(idle),
        sessionBusLocalSessionsProvider.overrideWith(
          (ref, id) => localSessions[id] ?? const <String>{},
        ),
        agentTransportForProvider.overrideWith((ref, id) async {
          reads.add(id);
          final gate = gates[id];
          if (gate != null) await gate.future;
          return transports[id];
        }),
      ],
    );
    addTearDown(container.dispose);
  }

  late final ProjectSessionRegistry registry;
  late final ProviderContainer container;
  final Map<String, _ChannelTransport> transports = {};
  final Map<String, Set<String>> localSessions = {
    _localProject: {_localSession},
  };

  /// Ids whose transport resolution is held open, so a test can decide what
  /// happens WHILE a dial is in flight.
  final Map<String, Completer<void>> gates = {};
  final List<String> reads = [];

  _ChannelTransport transport(String id) =>
      transports.putIfAbsent(id, _ChannelTransport.new);

  /// What a host restart looks like from here: the old transport is gone and
  /// the provider hands out a fresh one under the same id.
  ///
  /// The invalidate is the restart's other half, not test scaffolding — the
  /// transport family is not `autoDispose`, so a re-dial reads the SAME closed
  /// transport back until something invalidates it, which is exactly what
  /// `host_status.dart` does when the host it belongs to goes.
  _ChannelTransport replaceTransport(String id) {
    final fresh = transports[id] = _ChannelTransport();
    container.invalidate(agentTransportForProvider(id));
    return fresh;
  }

  /// Seeds the demand a frame would otherwise create, for the tests that are
  /// about what an EXISTING leg does.
  void reachPeer() => container
      .read(sessionBusLinksProvider.notifier)
      .reach(_peerMachine, _peerProject);

  void openLocal() => registry.touch(_localProject, isLocal: true);

  void start() => container.listen(
    sessionBusCarrierProvider,
    (_, _) {},
    fireImmediately: true,
  );

  SessionBusCarrierStatus get status =>
      container.read(sessionBusCarrierProvider);

  Future<void> settle() async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Waits past a shrunken window, then settles — for the tests that are about
  /// a re-dial or an expiry rather than a first attach.
  Future<void> cool() async {
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await settle();
  }
}

void main() {
  test('an open local project attaches its loopback leg and nothing else', () async {
    final h = _Harness();
    h.transport(_localProject);
    h.openLocal();
    h.start();
    await h.settle();

    expect(h.status.attachedLocal, 1);
    expect(
      h.status.attachedPeers,
      0,
      reason: 'nothing has been addressed, so no peer socket is held',
    );
    expect(h.registry.pinnedProjects, isEmpty);
  });

  test('a closed local project dials nothing', () async {
    final h = _Harness();
    h.transport(_localProject);
    h.start();
    await h.settle();

    expect(
      h.reads,
      isEmpty,
      reason:
          'resolving a cold local project spawns a bridge and an agent; the '
          'sending bridge holds the frames until the user opens it',
    );
    expect(h.status.attachedLocal, 0);
  });

  test('a frame for an unlegged peer attaches a leg and carries it', () async {
    final h = _Harness();
    final local = h.transport(_localProject);
    final peer = h.transport(_peerReg);
    h.openLocal();
    h.start();
    await h.settle();
    expect(h.status.attachedPeers, 0);

    final frame = _outbound();
    frame['payload'] = {'anUnknownFutureField': 42};
    local.emitJson(frame);
    await h.settle();

    expect(h.reads, contains(_peerReg));
    expect(h.status.attachedPeers, 1);
    expect(h.status.links, 1);
    expect(h.registry.pinnedProjects, {_peerReg});
    expect(
      peer.outbound.single.json,
      same(frame),
      reason:
          'the frame that asked for the leg is the one that opens the '
          'exchange; the sending bridge has already dropped its copy',
    );
    expect(peer.outbound.single.channel, 'control');
    expect(local.outbound, isEmpty);
    expect(h.status.toPeer, 1);
  });

  test('forwards a peer frame back to the loopback owner', () async {
    final h = _Harness();
    final local = h.transport(_localProject);
    final peer = h.transport(_peerReg);
    h.openLocal();
    h.reachPeer();
    h.start();
    await h.settle();

    peer.emitJson(_inbound());
    await h.settle();

    expect(local.outbound, hasLength(1));
    expect(local.outbound.single.json['type'], 'session-bus:ack');
    expect(h.status.toLocal, 1);
    expect(peer.outbound, isEmpty);
  });

  test('a frame for a session no open project carries is refused', () async {
    final h = _Harness();
    final local = h.transport(_localProject);
    final peer = h.transport(_peerReg);
    h.openLocal();
    h.reachPeer();
    h.start();
    await h.settle();

    peer.emitJson(_inbound(toSession: 's-nobody-has'));
    await h.settle();

    expect(local.outbound, isEmpty);
    expect(h.status.refused, 1);
    expect(h.status.toLocal, 0);
  });

  // Outbound holds a frame for a leg that does not exist yet; inbound refusing
  // in the same window would be the asymmetry that loses frames, since the
  // sending bridge was told this one left the moment its owner socket took it
  // and nothing on either machine retries.
  test('an inbound frame is held while its local leg is still dialling', () async {
    final h = _Harness();
    final local = h.transport(_localProject);
    final peer = h.transport(_peerReg);
    h.gates[_localProject] = Completer<void>();
    h.openLocal();
    h.reachPeer();
    h.start();
    await h.settle();
    expect(h.status.attachedLocal, 0, reason: 'the dial is still in flight');

    peer.emitJson(_inbound());
    await h.settle();
    expect(
      h.status.refused,
      0,
      reason: 'the project is open and carries the session; only its leg is late',
    );
    expect(local.outbound, isEmpty);

    h.gates[_localProject]!.complete();
    await h.settle();

    expect(local.outbound, hasLength(1));
    expect(h.status.toLocal, 1);
  });

  test('a held buffer over its cap keeps the newest frames', () async {
    final h = _Harness();
    final local = h.transport(_localProject);
    final peer = h.transport(_peerReg);
    h.gates[_localProject] = Completer<void>();
    h.openLocal();
    h.reachPeer();
    h.start();
    await h.settle();

    for (var i = 0; i <= kSessionBusHeldPerLeg; i++) {
      peer.emitJson(_inbound(context: 'ctx-$i'));
    }
    await h.settle();
    h.gates[_localProject]!.complete();
    await h.settle();

    expect(local.outbound, hasLength(kSessionBusHeldPerLeg));
    expect(
      local.outbound.first.json['contextId'],
      'ctx-1',
      reason: 'the oldest turn went, never the one the other agent is waiting on',
    );
    expect(local.outbound.last.json['contextId'], 'ctx-$kSessionBusHeldPerLeg');
    expect(h.status.dropped, 1);
  });

  test('ordinary project traffic on the same transport is untouched', () async {
    final h = _Harness();
    final local = h.transport(_localProject);
    final peer = h.transport(_peerReg);
    h.openLocal();
    h.reachPeer();
    h.start();
    await h.settle();

    local.emit('terminal:output', {'data': 'hi'});
    local.emit('session:updated');
    await h.settle();

    expect(peer.outbound, isEmpty);
    expect(h.status.refused, 0);
    expect(h.status.dropped, 0);
  });

  test('a leg nothing has carried on is dropped and unpinned', () async {
    final h = _Harness(idle: const Duration(milliseconds: 20));
    h.transport(_localProject);
    h.transport(_peerReg);
    h.openLocal();
    h.reachPeer();
    h.start();
    await h.settle();
    expect(h.status.attachedPeers, 1);

    await h.cool();

    expect(h.status.links, 0);
    expect(h.status.attachedPeers, 0);
    expect(
      h.status.attachedLocal,
      1,
      reason: 'the local leg belongs to an open project, not to a link',
    );
    expect(h.registry.pinnedProjects, isEmpty);
  });

  test('a leg that ends is re-attached to its replacement', () async {
    // Shrunk, not removed: the re-dial a closed leg is owed goes through the
    // same throttle as any other, and the real one is seconds long.
    final h = _Harness(cooldown: const Duration(milliseconds: 20));
    final local = h.transport(_localProject);
    final peer = h.transport(_peerReg);
    h.openLocal();
    h.reachPeer();
    h.start();
    await h.settle();
    expect(h.status.attachedLocal, 1);

    // A host restart: `host_status.dart` invalidates the transport, whose
    // dispose closes the stream this leg is listening to. Neither the links nor
    // the open set moves when a socket dies under a live exchange, so nothing
    // but the leg's own end can ask for the replacement.
    await local.dispose();
    final restarted = h.replaceTransport(_localProject);
    await h.cool();

    expect(h.status.attachedLocal, 1);

    restarted.emitJson(_outbound());
    await h.settle();
    expect(peer.outbound, hasLength(1));
    expect(h.status.toPeer, 1);
  });

  test('a dial that lands after the leg went idle attaches nothing', () async {
    final h = _Harness(idle: const Duration(milliseconds: 20));
    h.transport(_localProject);
    final peer = h.transport(_peerReg);
    h.gates[_peerReg] = Completer<void>();
    h.openLocal();
    h.reachPeer();
    h.start();
    await h.settle();
    expect(h.status.attachedPeers, 0, reason: 'the peer dial is still in air');

    // Expired mid-dial: an in-flight attach is not in the leg map yet, so the
    // reconcile the expiry runs has nothing to drop.
    await h.cool();
    h.gates[_peerReg]!.complete();
    await h.settle();

    expect(h.status.attachedPeers, 0);
    expect(h.registry.pinnedProjects, isEmpty);

    peer.emitJson(_inbound());
    await h.settle();
    expect(h.status.toLocal, 0, reason: 'a detached leg hears nothing at all');
  });

  test('a frame for a machine with no transport is dropped, not refused', () async {
    final h = _Harness();
    final local = h.transport(_localProject);
    h.openLocal();
    // No transport registered for the peer: the override answers null, which is
    // what a machine that is offline looks like.
    h.start();
    await h.settle();

    local.emitJson(_outbound());
    await h.settle();

    expect(h.status.attachedPeers, 0);
    expect(h.status.dropped, 1);
    expect(h.status.refused, 0);
  });

  // The counters answer a test; a log line answers the person holding a bridge
  // that has been told 182 times that a frame left. Both silences below cost an
  // afternoon of state-file archaeology to find once.
  group('what the carrier says out loud', () {
    late Directory tmp;
    late String logPath;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bus_carrier_log_');
      logPath = '${tmp.path}/app.log';
      AbLog.configureForTest(logPath);
    });
    tearDown(() {
      AbLog.dispose();
      tmp.deleteSync(recursive: true);
    });

    Future<String> logText() async {
      await AbLog.flush();
      final f = File(logPath);
      return f.existsSync() ? f.readAsStringSync() : '';
    }

    test('a frame with nowhere to go names the leg it wanted', () async {
      final h = _Harness();
      final local = h.transport(_localProject);
      h.openLocal();
      h.start();
      await h.settle();

      local.emitJson(_outbound());
      await h.settle();

      final text = await logText();
      expect(text, contains('no leg for addressed member'));
      expect(text, contains(_peerReg));
    });

    test('a refusal names the fact that was missing', () async {
      final h = _Harness();
      h.transport(_localProject);
      final peer = h.transport(_peerReg);
      h.openLocal();
      h.reachPeer();
      h.start();
      await h.settle();

      peer.emitJson(_inbound(toSession: 's-nobody-has'));
      await h.settle();

      final text = await logText();
      expect(text, contains('refused bus frame'));
      expect(
        text,
        contains('s-nobody-has'),
        reason:
            'a refusal with no cause is a dead end: the sending bridge has '
            'already been told the frame left',
      );
    });

    test('a session addressed by another project is carried, and said once', () async {
      final h = _Harness();
      final local = h.transport(_localProject);
      final peer = h.transport(_peerReg);
      h.openLocal();
      h.reachPeer();
      h.start();
      await h.settle();

      // What the other machine stores when it addressed a different project
      // entry for the same tree — a managed worktree opened in its own right
      // hashes to an id of its own. Two of them, because the warning is latched.
      for (var i = 0; i < 2; i++) {
        peer.emitJson(_inbound(toProject: 'p-some-other-checkout'));
        await h.settle();
      }

      expect(h.status.toLocal, 2, reason: 'the session id is what addresses it');
      expect(h.status.refused, 0);
      expect(local.outbound, hasLength(2));

      final text = await logText();
      expect(text, contains('this app holds the session under a project'));
      expect(text, contains('p-some-other-checkout'));
      expect(
        'this app holds the session'.allMatches(text).length,
        1,
        reason: 'latched per session, not written per frame',
      );
    });
  });
}
