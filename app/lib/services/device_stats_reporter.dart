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
/// Sent on every agent handshake, on the same trigger as `push:register`
/// (`PushMessagingService`): the warm-set listener never re-fires for a
/// session that merely reconnects, so each session also gets a handshake
/// listener. Free RAM moves by the second and the bridge pushes nothing back,
/// so a connected session is also re-told every [interval]; each send re-reads
/// the stats, and the bridge stamps it, which is what keeps the roster's
/// "last seen" current for a device that stays connected.
class DeviceStatsReporter {
  DeviceStatsReporter({
    Future<DeviceStats> Function()? read,
    this.interval = defaultInterval,
  }) : _read = read ?? readOwnDeviceStats;

  static const defaultInterval = Duration(seconds: 15);

  final Future<DeviceStats> Function() _read;
  final Duration interval;

  /// The handshake each session was last told about, so a status change that
  /// is not a new handshake sends nothing.
  final Expando<AgentHello> _sent = Expando<AgentHello>();
  final Set<ProjectSession> _watched = {};
  Timer? _tick;

  void watch(Iterable<ProjectSession> sessions) {
    for (final s in sessions) {
      // A local agent shares this machine; its roster has no row for us.
      if (s.mode != ProjectSessionMode.relay) continue;
      if (!_watched.add(s)) continue;
      void onStatus() => unawaited(_maybeSend(s));
      s.status.addListener(onStatus);
      onStatus();
    }
    _tick ??= Timer.periodic(interval, (_) => _resendAll());
  }

  void dispose() {
    _tick?.cancel();
    _tick = null;
    _watched.clear();
  }

  void _resendAll() {
    _watched.removeWhere((s) => s.isClosed);
    for (final s in _watched) {
      final hello = s.status.value.agentHello;
      if (hello == null || s.isDown) continue;
      unawaited(_send(s, hello));
    }
  }

  Future<void> _maybeSend(ProjectSession s) async {
    // A send before the handshake lands is silently dropped by the transport.
    final hello = s.status.value.agentHello;
    if (hello == null || identical(_sent[s], hello)) return;
    _sent[s] = hello;
    await _send(s, hello);
  }

  Future<void> _send(ProjectSession s, AgentHello hello) async {
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
