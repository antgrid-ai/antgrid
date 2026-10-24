import 'dart:async';

import '../models/ab_message.dart';
import '../models/agent_hello.dart';
import '../models/device_stats.dart';
import '../project/project_session.dart';
import '../util/ab_log.dart';
import '../util/device_id.dart';
import 'device_stats_reader.dart';

/// Tells each remote machine this device's model, RAM and storage, so its
/// desktop device roster can show them.
///
/// Sent on every agent handshake, on the same trigger as `push:register`
/// (`PushMessagingService`): the warm-set listener never re-fires for a
/// session that merely reconnects, so each session also gets a handshake
/// listener. Free RAM moves by the second and the bridge pushes nothing back,
/// so a connected machine is also re-told every [interval]; the bridge stamps
/// each report, which is what keeps the roster's "last seen" current for a
/// device that stays connected.
///
/// The periodic re-tell goes once per MACHINE, not per project session: the
/// bridge files every report under the one peer the machine's connection
/// belongs to, so a second project on the same machine only repeats it.
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
  bool _paused = false;

  /// One read shared by every send that asks while it is in flight, so a
  /// reconnect handshaking several sessions at once reads the OS once.
  Future<DeviceStats>? _reading;

  void watch(Iterable<ProjectSession> sessions) {
    for (final s in sessions) {
      // A local agent shares this machine; its roster has no row for us.
      if (s.mode != ProjectSessionMode.relay) continue;
      if (!_watched.add(s)) continue;
      void onStatus() => unawaited(_maybeSend(s));
      s.status.addListener(onStatus);
      onStatus();
    }
    if (!_paused) _startTicking();
  }

  /// Stops the periodic re-tell while the app is backgrounded: nobody reads a
  /// roster for a device that is not in use, and each tick wakes the radio.
  void pause() {
    _paused = true;
    _tick?.cancel();
    _tick = null;
  }

  /// Resumes the re-tell, reporting at once so the roster is current again
  /// rather than one [interval] later.
  void resume() {
    if (!_paused) return;
    _paused = false;
    _startTicking();
    _resendAll();
  }

  void dispose() {
    _tick?.cancel();
    _tick = null;
    _watched.clear();
  }

  void _startTicking() {
    _tick ??= Timer.periodic(interval, (_) => _resendAll());
  }

  void _resendAll() {
    _watched.removeWhere((s) => s.isClosed);
    final machines = <String>{};
    for (final s in _watched) {
      final hello = s.status.value.agentHello;
      if (hello == null || s.isDown) continue;
      if (!machines.add(baseDeviceUuid(s.projectId))) continue;
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

  Future<DeviceStats> _readShared() =>
      _reading ??= _read().whenComplete(() => _reading = null);

  Future<void> _send(ProjectSession s, AgentHello hello) async {
    try {
      final stats = await _readShared();
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
