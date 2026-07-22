import 'package:antgrid_relay_client/antgrid_relay_client.dart';

import '../design/ab_status_tone.dart';
import '../models/terminal_models.dart';

/// Maps [RelayConnectionState] to a (tone, label) pair for status surfaces.
(AbStatusTone, String) connectionDisplayInfo(RelayConnectionState state) {
  return switch (state) {
    RelayConnectionState.disconnected => (
      AbStatusTone.disabled,
      'Disconnected',
    ),
    RelayConnectionState.connecting => (AbStatusTone.warning, 'Connecting'),
    RelayConnectionState.authenticating => (
      AbStatusTone.warning,
      'Authenticating',
    ),
    RelayConnectionState.authenticated => (
      AbStatusTone.info,
      'Authenticated',
    ),
    RelayConnectionState.pairing => (AbStatusTone.warning, 'Pairing'),
    RelayConnectionState.paired => (AbStatusTone.success, 'Connected'),
  };
}

/// Maps [TerminalSessionState] to a status tone for the leading dot.
AbStatusTone sessionStateTone(TerminalSessionState state) {
  return switch (state) {
    TerminalSessionState.running => AbStatusTone.success,
    TerminalSessionState.exited => AbStatusTone.danger,
    TerminalSessionState.starting => AbStatusTone.disabled,
  };
}
