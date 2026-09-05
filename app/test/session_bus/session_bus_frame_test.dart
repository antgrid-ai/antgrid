import 'package:antgrid/session_bus/session_bus_frame.dart';
import 'package:flutter_test/flutter_test.dart';

const _lead = {
  'machineId': 'm-lead',
  'projectId': 'p-lead',
  'sessionId': 's-lead',
};
const _peer = {
  'machineId': 'm-peer',
  'projectId': 'p-peer',
  'sessionId': 's-peer',
};

Map<String, dynamic> _frame({
  String type = 'session-bus:assign',
  Map<String, dynamic> from = _lead,
  Map<String, dynamic> to = _peer,
}) => {'type': type, 'from': from, 'to': to, 'contextId': 'ctx-1'};

const _allowedPeers = {'m-peer/p-peer/s-peer'};
const _allowedLeads = {'p-lead/s-lead'};

BusForward _classify(
  Map<String, dynamic> json, {
  required bool fromLead,
  String? localMachineId = 'm-lead',
  Set<String> peers = _allowedPeers,
  Set<String> leads = _allowedLeads,
}) => classifyBusFrame(
  json: json,
  fromLead: fromLead,
  localMachineId: localMachineId,
  allowedPeerKeys: peers,
  allowedLeadKeys: leads,
);

void main() {
  group('frame vocabulary', () {
    test('recognizes exactly the seven bridge types', () {
      expect(kSessionBusTypes, hasLength(7));
      for (final type in kSessionBusTypes) {
        expect(isSessionBusFrame({'type': type}), isTrue);
      }
      expect(isSessionBusFrame({'type': 'session:updated'}), isFalse);
      expect(isSessionBusFrame(const {}), isFalse);
    });

    test('endpoints decode, and a malformed one decodes to null', () {
      final from = busFrom(_frame())!;
      expect(from.key, 'm-lead/p-lead/s-lead');
      expect(from.registrationId, 'm-lead.p-lead');
      expect(busTo(_frame())!.key, 'm-peer/p-peer/s-peer');

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
    test('a lead frame addressed to a known member goes to the peer', () {
      expect(_classify(_frame(), fromLead: true), BusForward.toPeer);
    });

    test('a peer frame addressed to a carried lead goes to the lead', () {
      expect(
        _classify(_frame(from: _peer, to: _lead), fromLead: false),
        BusForward.toLead,
      );
    });

    test('every one of the seven types routes', () {
      for (final type in kSessionBusTypes) {
        expect(
          _classify(_frame(type: type), fromLead: true),
          BusForward.toPeer,
          reason: type,
        );
      }
    });

    test('a non-bus frame is refused rather than forwarded blind', () {
      expect(
        _classify(_frame(type: 'terminal:output'), fromLead: true),
        BusForward.refuse,
      );
    });

    test('a frame missing either endpoint is refused', () {
      final noTo = _frame()..remove('to');
      expect(_classify(noTo, fromLead: true), BusForward.refuse);
      final noFrom = _frame()..remove('from');
      expect(_classify(noFrom, fromLead: false), BusForward.refuse);
    });

    test(
      'a lead frame addressed to a machine that is not a member is refused',
      () {
        expect(
          _classify(
            _frame(
              to: const {
                'machineId': 'm-other',
                'projectId': 'p-peer',
                'sessionId': 's-peer',
              },
            ),
            fromLead: true,
          ),
          BusForward.refuse,
        );
      },
    );

    test('a lead frame from a session this leg does not carry is refused', () {
      expect(
        _classify(_frame(), fromLead: true, leads: const {'p-lead/s-other'}),
        BusForward.refuse,
        reason:
            'the delivering loopback carries one lead session; another lead on '
            'the same bridge must not be routable through it',
      );
    });

    test('a peer frame addressed to another machine is refused', () {
      expect(
        _classify(
          _frame(from: _peer, to: _lead),
          fromLead: false,
          localMachineId: 'm-someone-else',
        ),
        BusForward.refuse,
      );
    });

    test('an unresolved local machine id still routes a reply', () {
      // The project+session halves of `to` remain the substantive guard, and a
      // carrier whose own uuid has not resolved must not silently drop replies.
      expect(
        _classify(
          _frame(from: _peer, to: _lead),
          fromLead: false,
          localMachineId: null,
        ),
        BusForward.toLead,
      );
    });

    test('a peer frame from a released member is refused', () {
      expect(
        _classify(
          _frame(from: _peer, to: _lead),
          fromLead: false,
          peers: const {},
        ),
        BusForward.refuse,
      );
    });

    test('direction is not inferred from the frame', () {
      // The same frame arriving on the wrong leg is refused: `fromLead` is the
      // delivering transport's fact, and a peer must not be able to claim it.
      expect(_classify(_frame(), fromLead: false), BusForward.refuse);
    });
  });

  test('busLeadKey is machine-free', () {
    expect(busLeadKey('p', 's'), 'p/s');
  });
}
