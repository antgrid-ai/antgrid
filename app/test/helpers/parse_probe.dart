import 'dart:async';

import 'package:antgrid/models/ab_message.dart';
import 'package:antgrid/project/project_message_classification.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_agent_transport.dart';
import 'fake_project_session.dart';
import 'package:antgrid/project/inbound_frame.dart';

/// A probe frame and the tier the router must deliver it on.
typedef ParseProbeFrame = ({Map<String, dynamic> frame, MessageTier tier});

/// A frame of [type] that [parseAbMessage] cannot read: it casts `id` to a
/// String before it switches on type, so a listener that hands this frame to
/// the parser raises a [TypeError] whatever the type. An `error` field makes
/// the router coerce the frame onto the status tier.
Map<String, dynamic> poisonedFrame(String type, {bool withError = false}) => {
  'type': type,
  'id': 7,
  'timestamp': 0,
  if (withError) 'error': 'refused',
};

ParseProbeFrame heavyProbe(String type) =>
    (frame: poisonedFrame(type), tier: MessageTier.heavy);

ParseProbeFrame statusProbe(String type, {bool withError = false}) => (
  frame: poisonedFrame(type, withError: withError),
  tier: MessageTier.status,
);

/// Observes which frame types one service hands to [parseAbMessage].
///
/// The session is built in a zone that discards uncaught errors, because its
/// own services parse probes too and are not the subject. The service under
/// test is built through [build], whose zone records them: a stream listener
/// reports an uncaught error to the zone it was registered in.
///
/// Errors never cross error zones. A Future created inside either zone that
/// fails is never delivered to an awaiter in the test zone, which hangs
/// instead; `ProjectSession.close` awaits checkout disposals created there, so
/// a probe test that drives session listings can hang on teardown.
class ParseProbe {
  ParseProbe._(this.transport, this.session);

  final FakeAgentTransport transport;
  final ProjectSession session;
  final List<Object> errors = [];
  final Map<MessageTier, Set<String>> _delivered = {
    MessageTier.heavy: <String>{},
    MessageTier.status: <String>{},
  };
  final List<StreamSubscription<InboundFrame>> _taps = [];

  /// The loopback fake by default, so no PreviewService in the session claims
  /// the process-wide PreviewHandoff.
  static Future<ParseProbe> open({FakeAgentTransport? transport}) async {
    final t = transport ?? LocalFakeAgentTransport();
    final session = await runZonedGuarded(
      () => newFakeProjectSession(t),
      (_, _) {},
    )!;
    final probe = ParseProbe._(t, session);
    addTearDown(probe._close);
    // A probe carries no checkoutId, so it lands on main's slices; each slice
    // is a `where` over the project-wide tier, so arriving here is arriving
    // at a project-wide listener too.
    probe._taps
      ..add(
        session
            .checkoutHeavyStream('main')
            .listen(
              (f) => probe._delivered[MessageTier.heavy]!.add(
                '${f.type}',
              ),
            ),
      )
      ..add(
        session
            .checkoutStatusStream('main')
            .listen(
              (f) => probe._delivered[MessageTier.status]!.add(
                '${f.type}',
              ),
            ),
      );
    return probe;
  }

  T build<T>(T Function() body) =>
      runZonedGuarded(body, (error, _) => errors.add(error)) as T;

  Future<void> expectParsed(List<ParseProbeFrame> probes) async {
    await _expectQuiet();
    for (final probe in probes) {
      final type = probe.frame['type'];
      expect(
        await _emit(probe),
        isTrue,
        reason: '$type never reached the ${probe.tier.name} tier',
      );
      expect(
        errors.any((e) => e is TypeError),
        isTrue,
        reason:
            '$type reached the service but was never parsed: '
            'is it missing from the handled-type set?',
      );
    }
  }

  Future<void> expectNeverParsed(List<ParseProbeFrame> probes) async {
    await _expectQuiet();
    for (final probe in probes) {
      final type = probe.frame['type'];
      // A parser that accepted the probe would let this pass on nothing.
      expect(() => parseAbMessage(probe.frame), throwsA(isA<TypeError>()));
      expect(
        await _emit(probe),
        isTrue,
        reason: '$type never reached the ${probe.tier.name} tier',
      );
      expect(
        errors,
        isEmpty,
        reason: '$type was parsed by a service that does not act on it',
      );
    }
  }

  Future<void> _expectQuiet() async {
    await pumpEventQueue();
    expect(errors, isEmpty, reason: 'the service raised before any probe');
  }

  Future<bool> _emit(ParseProbeFrame probe) async {
    errors.clear();
    for (final seen in _delivered.values) {
      seen.clear();
    }
    transport.emitJson(probe.frame);
    await pumpEventQueue();
    return _delivered[probe.tier]!.contains(probe.frame['type']);
  }

  Future<void> _close() async {
    for (final tap in _taps) {
      await tap.cancel();
    }
    await session.close();
  }
}
