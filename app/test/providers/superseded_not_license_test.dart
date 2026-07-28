// SUPERSEDED must never render as a license revocation ("re-activate")
// condition — it just means a newer instance of ourselves took over the
// socket (design §6.3 epoch arbitration). The authoritative classification
// (RelayLicenseErrorCode.fromWire('SUPERSEDED') is null, and
// ConnectionSupervisor.noteRelayError blocks it as `superseded`, never
// `deviceRevoked`) is pinned at the package level in
// relay_service_reconnect_test.dart / connection_supervisor_test.dart; this
// test proves the app's connection-state surface — what the workspace boot
// screen and `agentReachabilityProvider` actually read — treats a SUPERSEDED
// disconnect exactly like any other non-license disconnect, and that it can
// never reach the one UI flag that DOES mean "re-authenticate"
// (`authRevokedBannerProvider`, which only local-transport `auth_revoked`
// events flip).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';

import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/relay_connection.dart';
import 'package:antgrid/providers/value_controller.dart';

class _FakeManager extends RelayConnectionManager {
  _FakeManager(this._conn) : super(crypto: CryptoService());
  final RelayConnection _conn;

  @override
  RelayConnection connectionFor(String machineDeviceId) => _conn;
  @override
  RelayConnection? peek(String machineDeviceId) => _conn;
}

class _SettableRelay extends RelayService {
  _SettableRelay() : super(crypto: CryptoService());
  AppState _state = const AppState();

  @override
  AppState get currentState => _state;

  @override
  Stream<AppState> get stateStream => Stream<AppState>.empty();

  void push(AppState s) => _state = s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a SUPERSEDED disconnect is read by agentReachabilityProvider the SAME '
      'as any other non-license disconnect, and never flips '
      'authRevokedBannerProvider', () async {
    final relay = _SettableRelay();
    final conn = RelayConnection(
      machineDeviceId: 'M',
      crypto: CryptoService(),
      relayOverride: relay,
    );
    addTearDown(conn.dispose);

    final container = ProviderContainer(
      overrides: [
        relayConnectionManagerProvider.overrideWithValue(_FakeManager(conn)),
        selectedTargetProvider.overrideWith(
          () => ValueController(const RemoteTarget.legacy('M')),
        ),
      ],
    );
    addTearDown(container.dispose);

    // Baseline: ordinary retryable disconnect (e.g. AGENT_OFFLINE mid-flow).
    relay.push(
      const AppState(
        connectionState: RelayConnectionState.disconnected,
        errorCode: 'AGENT_OFFLINE',
      ),
    );
    final baseline = container.read(agentReachabilityProvider);

    // SUPERSEDED — same connectionState (disconnected), different code.
    relay.push(
      const AppState(
        connectionState: RelayConnectionState.disconnected,
        errorCode: 'SUPERSEDED',
      ),
    );
    // agentReachabilityProvider maps on `connectionState` alone; every
    // disconnected state — regardless of code — must classify identically
    // (never a distinct "license" bucket).
    final supersededReach = container.read(agentReachabilityProvider);
    expect(
      supersededReach,
      baseline,
      reason:
          'SUPERSEDED must not carve out special (license-like) '
          'reachability handling',
    );
    expect(supersededReach, isNot(AgentReachability.online));

    expect(
      RelayLicenseErrorCode.fromWire('SUPERSEDED'),
      isNull,
      reason:
          'SUPERSEDED must never parse as a license error code — '
          'the type the app would need to render "re-activate" UI',
    );

    expect(
      container.read(authRevokedBannerProvider),
      isFalse,
      reason:
          'only a local-transport auth_revoked event flips this — a '
          'relay SUPERSEDED must never trip it',
    );
  });
}
