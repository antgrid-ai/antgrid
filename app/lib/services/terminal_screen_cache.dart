import '../models/ab_message.dart';
import '../project/perf_recorder.dart';

/// Shared across warm projects; visible frames are owned by their services.
class TerminalScreenCache {
  TerminalScreenCache({this.maxScreens = 16, this.maxBytes = 16 << 20});

  final int maxScreens;
  final int maxBytes;
  final _frames = <(Object, String), TerminalFrameMessage>{};
  int bytes = 0;
  int get length => _frames.length;
  void _recordSize() {
    perfRecorder.setTerminalDemandGauge('hiddenScreens', length);
    perfRecorder.setTerminalDemandGauge('hiddenScreenBytes', bytes);
  }

  // Dart may retain two bytes per UTF-16 code unit, even for ASCII payloads.
  int _size(TerminalFrameMessage frame) =>
      2 *
          (frame.ansi.length +
              frame.runId.length +
              frame.attachmentId.length +
              frame.terminalId.length +
              frame.id.length) +
      256;

  bool contains(Object owner, String id) => _frames.containsKey((owner, id));

  TerminalFrameMessage? take(Object owner, String id) {
    final frame = _frames.remove((owner, id));
    if (frame != null) bytes -= _size(frame);
    _recordSize();
    return frame;
  }

  void put(Object owner, String id, TerminalFrameMessage frame) {
    take(owner, id);
    final size = _size(frame);
    if (size > maxBytes) return;
    _frames[(owner, id)] = frame;
    bytes += size;
    while (_frames.length > maxScreens || bytes > maxBytes) {
      final key = _frames.keys.first;
      take(key.$1, key.$2);
    }
    _recordSize();
  }

  void removeOwner(Object owner) {
    for (final key
        in _frames.keys.where((key) => identical(key.$1, owner)).toList()) {
      take(key.$1, key.$2);
    }
  }
}
