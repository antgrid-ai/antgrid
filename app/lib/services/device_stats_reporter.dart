import 'dart:async';

import '../models/ab_message.dart';
import '../models/agent_hello.dart';
import '../models/device_stats.dart';
import '../project/project_session.dart';
import '../util/ab_log.dart';
import 'device_stats_reader.dart';

/// Tells each remote machine this device's model, RAM and storage, so its
/// desktop device roster can show them.
///
/// Sent once per agent handshake, on the same trigger as `push:register`
/// (`PushMessagingService`): the warm-set listener never re-fires for a
/// session that merely reconnects, so each session also gets a handshake
/// listener. The stats are re-read for every send, so a reconnect refreshes
/// what the machine shows.
class DeviceStatsReporter {
  DeviceStatsReporter({Future<DeviceStats> Function()? read})
    : _read = read ?? readOwnDeviceStats;

  final Future<DeviceStats> Function() _read;

  /// The handshake each session was last told about, so a status change that
  /// is not a new handshake sends nothing.
  final Expando<AgentHello> _sent = Expando<AgentHello>();
  final Expando<bool> _watched = Expando<bool>();

  void watch(Iterable<ProjectSession> sessions) {
    for (final s in sessions) {
      // A local agent shares this machine; its roster has no row for us.
      if (s.mode != ProjectSessionMode.relay) continue;
      if (_watched[s] == true) continue;
      _watched[s] = true;
      void onStatus() => unawaited(_maybeSend(s));
      s.status.addListener(onStatus);
      onStatus();
    }
  }

  Future<void> _maybeSend(ProjectSession s) async {
    // A send before the handshake lands is silently dropped by the transport.
    final hello = s.status.value.agentHello;
    if (hello == null || identical(_sent[s], hello)) return;
    _sent[s] = hello;
    try {
      final stats = await _read();
      if (stats.isEmpty) return;
      await s.send(createAbMessage('device:stats', stats.toWire()));
    } catch (e) {
      // Un-mark so the next handshake retries this one.
      if (identical(_sent[s], hello)) _sent[s] = null;
      AbLog.warn(
        'DeviceStatsReporter',
        'device:stats failed',
        fields: {'projectId': s.projectId, 'error': '$e'},
      );
    }
  }
}
