import 'package:antgrid/session_bus/session_bus_frame.dart';
import 'package:flutter_test/flutter_test.dart';

const _here = {
  'machineId': 'm-here',
  'projectId': 'p-here',
  'sessionId': 's-here',
};
const _there = {
  'machineId': 'm-there',
  'projectId': 'p-there',
  'sessionId': 's-there',
};

Map<String, dynamic> _frame({
  String type = 'session-bus:post',
  Map<String, dynamic> from = _here,
  Map<String, dynamic> to = _there,
}) => {'type': type, 'from': from, 'to': to, 'contextId': 'ctx-1'};

const _carried = {'s-here'};

BusRouting _classify(
  Map<String, dynamic> json, {
  String? localMachineId = 'm-here',
  Set<String> carried = _carried,
}) => classifyBusFrame(
  json: json,
  localMachineId: localMachineId,
  localSessionIds: carried,
);

void main() {
  group('frame vocabulary', () {
    test('recognizes exactly the five bridge types', () {
      expect(kSessionBusTypes, {
        'session-bus:post',
        'session-bus:notify',
        'session-bus:fetch',
        'session-bus:fetch:result',
        'session-bus:ack',
      });
      for (final type in kSessionBusTypes) {
        expect(isSessionBusFrame({'type': type}), isTrue);
      }
      expect(
        isSessionBusFrame({'type': 'session-bus:message'}),
        isFalse,
        reason: 'the single message verb was replaced by post and notify',
      );
      expect(isSessionBusFrame({'type': 'session:updated'}), isFalse);
      expect(isSessionBusFrame(const {}), isFalse);
    });

    test('endpoints decode, and a malformed one decodes to null', () {
      final from = busFrom(_frame())!;
      expect(from.key, 'm-here/p-here/s-here');
      expect(from.registrationId, 'm-here.p-here');
      expect(busTo(_frame())!.key, 'm-there/p-there/s-there');

      expect(busTo({'type': 'session-bus:ack'}), isNull);
      expect(busTo({'to': 'not-a-map'}), isNull);
      expect(
        busTo({
          'to': {'machineId': '', 'projectId': 'p', 'sessionId': 's'},
        }),
        isNull,
        reason: 'an empty id addresses nothing and must not route',
      );
    });

    test('endpoint equality is the whole triple', () {
      const a = BusEndpoint(machineId: 'm', projectId: 'p', sessionId: 's');
      expect(
        a,
        const BusEndpoint(machineId: 'm', projectId: 'p', sessionId: 's'),
      );
      expect(
        a,
        isNot(
          const BusEndpoint(machineId: 'm', projectId: 'p', sessionId: 's2'),
        ),
      );
    });
  });

  group('classifyBusFrame', () {
    test('a frame addressed to another machine leaves', () {
      final routing = _classify(_frame());
      expect(routing.forward, BusForward.toPeer);
      expect(routing.because, isNull);
    });

    test('a frame addressed to a session this app carries lands', () {
      expect(
        _classify(_frame(from: _there, to: _here)).forward,
        BusForward.toLocal,
      );
    });

    test('an unlegged peer is not a refusal — it is what asks for a leg', () {
      // Nothing about the outbound clause consults the attached legs: refusing
      // here would make the first frame of every exchange the one that cannot
      // be sent, since the leg does not exist until that frame asks for it.
      expect(
        _classify(
          _frame(
            to: const {
              'machineId': 'm-never-seen',
              'projectId': 'p-never-seen',
              'sessionId': 's-never-seen',
            },
          ),
        ).forward,
        BusForward.toPeer,
      );
    });

    test('every one of the five types routes', () {
      for (final type in kSessionBusTypes) {
        expect(
          _classify(_frame(type: type)).forward,
          BusForward.toPeer,
          reason: type,
        );
      }
    });

    test('a non-bus frame is refused rather than forwarded blind', () {
      final routing = _classify(_frame(type: 'terminal:output'));
      expect(routing.forward, BusForward.refuse);
      expect(routing.because, contains('session-bus'));
    });

    test('a frame missing either endpoint is refused, and says which', () {
      final noTo = _frame()..remove('to');
      expect(_classify(noTo).because, contains('target'));
      final noFrom = _frame()..remove('from');
      expect(_classify(noFrom).because, contains('sender'));
    });

    test('a frame for a session no open project carries names it', () {
      final routing = _classify(
        _frame(
          from: _there,
          to: const {
            'machineId': 'm-here',
            'projectId': 'p-here',
            'sessionId': 's-closed',
          },
        ),
      );
      expect(routing.forward, BusForward.refuse);
      expect(routing.because, contains('s-closed'));
    });

    test('an unresolved local machine id still lands a reply', () {
      // The session set remains the substantive guard, and a carrier whose own
      // uuid has not resolved must not silently drop every reply.
      expect(
        _classify(_frame(from: _there, to: _here), localMachineId: null).forward,
        BusForward.toLocal,
      );
    });

    test('an unresolved local machine id still sends a frame outward', () {
      expect(
        _classify(_frame(), localMachineId: null).forward,
        BusForward.toPeer,
      );
    });

    test('an inbound frame is placed by session, whatever project names it', () {
      // One checkout can be open as more than one project, so the other
      // machine's stored `projectId` for this session is a label the two sides
      // can legitimately disagree on. Matching on it strands the exchange
      // permanently, with every frame refused and nothing said.
      final drifted = _frame(
        from: _there,
        to: const {
          'machineId': 'm-here',
          'projectId': 'a-project-this-app-never-heard-of',
          'sessionId': 's-here',
        },
      );
      expect(_classify(drifted).forward, BusForward.toLocal);
    });
  });
}
