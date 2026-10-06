import 'package:flutter/foundation.dart';

enum UpdateCheckStatus {
  upToDate,
  available,
  restartReady,
  downloading,
  unsupported,
  failed,
}

@immutable
class UpdateCheckResult {
  const UpdateCheckResult(
    this.status, {
    this.version,
    this.candidateId,
    this.message,
  });

  final UpdateCheckStatus status;
  final String? version;
  final String? candidateId;
  final String? message;

  bool get actionable =>
      status == UpdateCheckStatus.available ||
      status == UpdateCheckStatus.restartReady;

  static const upToDate = UpdateCheckResult(UpdateCheckStatus.upToDate);
  static const failed = UpdateCheckResult(UpdateCheckStatus.failed);
  static const unsupported = UpdateCheckResult(
    UpdateCheckStatus.unsupported,
    message:
        'Updates are not supported by this build. Install a released '
        'build from the platform store or download page to receive updates.',
  );
}
