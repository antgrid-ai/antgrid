import 'file_service.dart';

/// One feature's lease, rebound when its checkout changes.
class TreeInterest {
  FileService? _service;
  void update(FileService? service, bool interested) {
    final next = interested ? service : null;
    if (identical(next, _service)) return;
    _service?.setTreeInterest(this, false);
    _service = next;
    next?.setTreeInterest(this, true);
  }

  void dispose() => update(null, false);
}
