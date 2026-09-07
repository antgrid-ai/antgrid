import 'dart:async';
import 'dart:io';

import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/device_provisioning.dart';
import 'package:antgrid/session_bus/session_bus_carrier.dart';
import 'package:antgrid/session_bus/session_bus_links.dart';
import 'package:antgrid/util/ab_log.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _leadProject = 'p-lead';
const _leadSession = 's-lead';
const _peerReg = 'm-peer.p-peer';

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

SessionBusLink _link({
  String machineId = 'm-peer',
  String projectId = 'p-peer',
  String sessionId = 's-peer',
}) => SessionBusLink(
  leadProjectId: _leadProject,
  leadSessionId: _leadSession,
  peer: SessionMemberRef(
    machineId: machineId,
    projectId: projectId,
    sessionId: sessionId,
  ),
);

Map<String, dynamic> _busFrame({
  String type = 'session-bus:assign',
  Map<String, dynamic>? from,
  Map<String, dynamic>? to,
}) => {
  'type': type,
  'contextId': 'ctx-1',
  'from':
      from ??
      const {
        'machineId': 'm-lead',
        'projectId': _leadProject,
        'sessionId': _leadSession,
      },
  'to':
      to ??
      const {
        'machineId': 'm-peer',
        'projectId': 'p-peer',
        'sessionId': 's-peer',
      },
};

class _Links extends Notifier<SessionBusLinks> {
  @override
  SessionBusLinks build() => SessionBusLinks.empty;
  void set(List<SessionBusLink> links) => state = SessionBusLinks(links);
}

final _linksSource = NotifierProvider<_Links, SessionBusLinks>(_Links.new);

class _Harness {
  _Harness({
    List<SessionBusLink> links = const [],
    Duration cooldown = kSessionBusAttachRetryCooldown,
  }) {
    registry = ProjectSessionRegistry(
      localCap: 10,
      relayCap: 10,
      onEvict: (_) async {},
    );
    container = ProviderContainer(
      overrides: [
        localDeviceUuidProvider.overrideWith((ref) => 'm-lead'),
        projectSessionRegistryProvider.overrideWith(
          () => ProjectSessionRegistryController(registry),
        ),
        sessionBusLinksProvider.overrideWith((ref) => ref.watch(_linksSource)),
        sessionBusAttachCooldownProvider.overrideWithValue(cooldown),
        agentTransportForProvider.overrideWith((ref, id) async {
          reads.add(id);
          final gate = gates[id];
          if (gate != null) await gate.future;
          return transports[id];
        }),
      ],
    );
    addTearDown(container.dispose);
    container.read(_linksSource.notifier).set(links);
  }

  late final ProjectSessionRegistry registry;
  late final ProviderContainer container;
  final Map<String, _ChannelTransport> transports = {};

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

  void start() => container.listen(
    sessionBusCarrierProvider,
    (_, _) {},
    fireImmediately: true,
  );

  SessionBusCarrierStatus get status =>
      container.read(sessionBusCarrierProvider);

  void setLinks(List<SessionBusLink> links) =>
      container.read(_linksSource.notifier).set(links);

  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Waits past a shrunken attach cooldown, then settles — for the tests that
  /// are about a re-dial rather than a first one.
  Future<void> cool() async {
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await settle();
  }
}

void main() {
  test('attaches both legs and pins both projects for a warm lead', () async {
    final h = _Harness(links: [_link()]);
    h.transport(_leadProject);
    h.transport(_peerReg);
    h.registry.touch(_leadProject, isLocal: true);
    h.start();
    await h.settle();

    expect(h.status.links, 1);
    expect(h.status.attachedLeads, 1);
    expect(h.status.attachedPeers, 1);
    expect(h.registry.pinnedProjects, {_leadProject, _peerReg});
  });

  test('a cold lead project dials nothing', () async {
    final h = _Harness(links: [_link()]);
    h.transport(_leadProject);
    h.transport(_peerReg);
    h.start();
    await h.settle();

    expect(
      h.reads,
      isEmpty,
      reason:
          'resolving a cold local project spawns a bridge and an agent; the '
          'lead bridge holds the frames until the user opens it',
    );
    expect(h.status.attachedLeads, 0);
    expect(h.status.attachedPeers, 0);
    expect(h.registry.pinnedProjects, {
      _leadProject,
      _peerReg,
    }, reason: 'the pin is derived from the membership, not from the legs');
  });

  test('forwards a lead frame verbatim onto the peer stream', () async {
    final h = _Harness(links: [_link()]);
    final lead = h.transport(_leadProject);
    final peer = h.transport(_peerReg);
    h.registry.touch(_leadProject, isLocal: true);
    h.start();
    await h.settle();

    final frame = _busFrame();
    frame['payload'] = {'anUnknownFutureField': 42};
    lead.emitJson(frame);
    await h.settle();

    expect(peer.outbound, hasLength(1));
    expect(peer.outbound.single.json, same(frame));
    expect(peer.outbound.single.channel, 'control');
    expect(lead.outbound, isEmpty);
    expect(h.status.toPeer, 1);
  });

  test('forwards a peer frame back to the loopback owner', () async {
    final h = _Harness(links: [_link()]);
    final lead = h.transport(_leadProject);
    final peer = h.transport(_peerReg);
    h.registry.touch(_leadProject, isLocal: true);
    h.start();
    await h.settle();

    peer.emitJson(
      _busFrame(
        type: 'session-bus:ack',
        from: const {
          'machineId': 'm-peer',
          'projectId': 'p-peer',
          'sessionId': 's-peer',
        },
        to: const {
          'machineId': 'm-lead',
          'projectId': _leadProject,
          'sessionId': _leadSession,
        },
      ),
    );
    await h.settle();

    expect(lead.outbound, hasLength(1));
    expect(lead.outbound.single.json['type'], 'session-bus:ack');
    expect(h.status.toLead, 1);
    expect(peer.outbound, isEmpty);
  });

  test('a frame naming a machine that is not a member is refused', () async {
    final h = _Harness(links: [_link()]);
    final lead = h.transport(_leadProject);
    final peer = h.transport(_peerReg);
    h.registry.touch(_leadProject, isLocal: true);
    h.start();
    await h.settle();

    lead.emitJson(
      _busFrame(
        to: const {
          'machineId': 'm-stranger',
          'projectId': 'p-peer',
          'sessionId': 's-peer',
        },
      ),
    );
    await h.settle();

    expect(peer.outbound, isEmpty);
    expect(h.status.refused, 1);
    expect(h.status.toPeer, 0);
  });

  test('ordinary project traffic on the same transport is untouched', () async {
    final h = _Harness(links: [_link()]);
    final lead = h.transport(_leadProject);
    final peer = h.transport(_peerReg);
    h.registry.touch(_leadProject, isLocal: true);
    h.start();
    await h.settle();

    lead.emit('terminal:output', {'data': 'hi'});
    lead.emit('session:updated');
    await h.settle();

    expect(peer.outbound, isEmpty);
    expect(h.status.refused, 0);
    expect(h.status.dropped, 0);
  });

  test('releasing the last member detaches both legs and unpins', () async {
    final h = _Harness(links: [_link()]);
    final lead = h.transport(_leadProject);
    final peer = h.transport(_peerReg);
    h.registry.touch(_leadProject, isLocal: true);
    h.start();
    await h.settle();
    expect(h.status.attachedPeers, 1);

    h.setLinks(const []);
    await h.settle();

    expect(h.status.links, 0);
    expect(h.status.attachedLeads, 0);
    expect(h.status.attachedPeers, 0);
    expect(h.registry.pinnedProjects, isEmpty);

    lead.emitJson(_busFrame());
    await h.settle();
    expect(peer.outbound, isEmpty);
  });

  test('a leg that ends is re-attached to its replacement', () async {
    // Shrunk, not removed: the re-dial a closed leg is owed goes through the
    // same throttle as any other, and the real one is seconds long.
    final h = _Harness(
      links: [_link()],
      cooldown: const Duration(milliseconds: 20),
    );
    final lead = h.transport(_leadProject);
    final peer = h.transport(_peerReg);
    h.registry.touch(_leadProject, isLocal: true);
    h.start();
    await h.settle();
    expect(h.status.attachedLeads, 1);

    // A host restart: `host_status.dart` invalidates the transport, whose
    // dispose closes the stream this leg is listening to. Neither the links nor
    // the warm set moves, so nothing but the leg's own end can ask for the
    // replacement.
    await lead.dispose();
    final restarted = h.replaceTransport(_leadProject);
    await h.cool();

    expect(h.status.attachedLeads, 1);

    restarted.emitJson(_busFrame());
    await h.settle();
    expect(peer.outbound, hasLength(1));
    expect(h.status.toPeer, 1);
  });

  test('a dial that lands after the last release attaches nothing', () async {
    final h = _Harness(links: [_link()]);
    h.transport(_leadProject);
    final peer = h.transport(_peerReg);
    h.gates[_peerReg] = Completer<void>();
    h.registry.touch(_leadProject, isLocal: true);
    h.start();
    await h.settle();
    expect(h.status.attachedPeers, 0, reason: 'the peer dial is still in air');

    // Removed mid-dial: an in-flight attach is not in the leg map yet, so the
    // reconcile this release runs has nothing to drop.
    h.setLinks(const []);
    await h.settle();

    h.gates[_peerReg]!.complete();
    await h.settle();

    expect(h.status.attachedPeers, 0);
    expect(h.registry.pinnedProjects, isEmpty);

    peer.emitJson(
      _busFrame(
        type: 'session-bus:ack',
        from: const {
          'machineId': 'm-peer',
          'projectId': 'p-peer',
          'sessionId': 's-peer',
        },
        to: const {
          'machineId': 'm-lead',
          'projectId': _leadProject,
          'sessionId': _leadSession,
        },
      ),
    );
    await h.settle();
    expect(h.status.refused, 0, reason: 'a detached leg hears nothing at all');
  });

  test(
    'a frame for an attached member with no peer leg is dropped, not refused',
    () async {
      final h = _Harness(links: [_link()]);
      final lead = h.transport(_leadProject);
      h.registry.touch(_leadProject, isLocal: true);
      // No transport registered for the peer: the override answers null, which is
      // what a machine that is offline looks like.
      h.start();
      await h.settle();

      lead.emitJson(_busFrame());
      await h.settle();

      expect(h.status.attachedPeers, 0);
      expect(h.status.dropped, 1);
      expect(h.status.refused, 0);
    },
  );

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
      final h = _Harness(links: [_link()]);
      final lead = h.transport(_leadProject);
      h.registry.touch(_leadProject, isLocal: true);
      h.start();
      await h.settle();

      lead.emitJson(_busFrame());
      await h.settle();

      final text = await logText();
      expect(text, contains('no leg for addressed member'));
      expect(text, contains(_peerReg));
    });

    test('a lead addressed by another project is carried, and said once', () async {
      final h = _Harness(links: [_link()]);
      final lead = h.transport(_leadProject);
      final peer = h.transport(_peerReg);
      h.registry.touch(_leadProject, isLocal: true);
      h.start();
      await h.settle();

      // What a peer stores when it joined through a different project entry for
      // the same tree — a managed worktree opened in its own right hashes to an
      // id of its own. Two of them, because the warning is latched per session.
      for (var i = 0; i < 2; i++) {
        peer.emitJson(
          _busFrame(
            type: 'session-bus:ack',
            from: const {
              'machineId': 'm-peer',
              'projectId': 'p-peer',
              'sessionId': 's-peer',
            },
            to: const {
              'machineId': 'm-lead',
              'projectId': 'p-some-other-checkout',
              'sessionId': _leadSession,
            },
          ),
        );
        await h.settle();
      }

      expect(h.status.toLead, 2, reason: 'the session id is what addresses it');
      expect(h.status.refused, 0);
      expect(lead.outbound, hasLength(2));

      final text = await logText();
      expect(text, contains('this app holds the lead under a project'));
      expect(text, contains('p-some-other-checkout'));
      expect(
        'this app holds the lead'.allMatches(text).length,
        1,
        reason: 'latched per lead session, not written per frame',
      );
    });

    // The failure with no other witness: the lead's bridge keeps handing frames
    // to this app and being told they left, while a closed lead project means
    // nothing is attached to carry them.
    test('a link whose lead project is closed says nothing is carried', () async {
      final h = _Harness(links: [_link()]);
      h.transport(_leadProject);
      h.start();
      await h.settle();

      expect(h.status.attachedLeads, 0);
      final text = await logText();
      expect(text, contains('lead project not open'));
      expect(text, contains(_leadProject));
    });
  });
}
